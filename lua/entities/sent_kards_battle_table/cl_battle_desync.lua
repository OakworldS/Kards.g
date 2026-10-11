--[[
    Kards 战斗牌桌客户端模块：测试版不同步恢复（cl_battle_desync.lua，2026-09-13）

    测试版未接入 NetSync 签名同步（sh_sync_stub.lua ClientRequest 空转），防作弊由
    服务端实体层权威校验链承担。当服务端在权威校验中发现结构性分歧（规则门控已过、
    客户端引用的手牌实体/手牌数据在服务端不存在，正常时序不可能发生，见
    table_battledeck.lua OnPlayCard 接入点），定向发送 KardsDesyncNotify：
      1. 本模块显示全屏模糊 + 居中弹窗：标题「错误」，正文
         「服务端与客户端不同步，需要重启客户端」，底部「重启」按钮
         （KARDS.DrawActionButton，与重新调度「确认」按钮同一绘制函数）；
      2. 点击重启 → KardsDesyncReenter 请求本桌全量快照（不释放槽位、不中断对局）；
      3. KardsDesyncSnapshot 到达 → ResetBattleState 后按快照重建本地手牌索引/卡面、
         两支援阵线、前线、回合方、指挥点，世界实体立即落位，关闭弹窗。

    正式版：由 NetSync 签名比对 + 自动全量重同步取代本手动流程（决策记录见
    《战斗系统规划.md》）。

    挂载：cl_init.lua 在 cl_battle_gameover.lua 之后 include 本文件；
          cl_battle_mulligan.lua 重新调度确认按钮改用 KARDS.DrawActionButton。
]]

if not CLIENT then return end

KARDS = KARDS or {}

-- 弹窗状态（非 nil 即显示中）：{ ent = 牌桌实体, rect = 按钮矩形 }
KARDS.Desync = nil

-- 点击沿检测上一帧左键状态
local prevClickLeft = false

-- ====================================================================
-- 通用动作按钮绘制（2026-09-13 整合）：
-- 重新调度「确认」与不同步弹窗「重启」共用同一视觉形式：#BDBCAF 浅灰米色直角
-- 矩形 + SourceHan_Heavy_32 深色文字；鼠标左键在按钮区域按下时背景 #333229、
-- 文字 #C78736。点击沿检测由调用方自行维护（本函数只读当前帧输入，不吃事件）。
--
-- @param x    number 按钮中心 x
-- @param y    number 按钮中心 y
-- @param w    number 宽
-- @param h    number 高
-- @param text string 按钮文字
-- @return boolean held 当前帧是否处于「鼠标悬停且左键按下」状态
-- ====================================================================
function KARDS.DrawActionButton(x, y, w, h, text)
    local mx, my = gui.MouseX(), gui.MouseY()
    local held = input.IsMouseDown(MOUSE_LEFT)
        and mx >= x - w / 2 and mx <= x + w / 2
        and my >= y - h / 2 and my <= y + h / 2
    surface.SetDrawColor(held and Color(51, 50, 41) or Color(189, 188, 175))
    surface.DrawRect(x - w / 2, y - h / 2, w, h)
    draw.SimpleText(text, "SourceHan_Heavy_32", x, y,
        held and Color(199, 135, 54) or Color(16, 16, 16),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    return held
end

--[[
    关闭不同步弹窗（退出牌桌 / 新一场对局 / 对局结算时调用，幂等）。
]]
function KARDS.DesyncReset()
    KARDS.Desync = nil
    prevClickLeft = false
end

-- ====================================================================
-- 全屏模糊（与 cl_battle_gameover.lua 同款盒式模糊近似，独立材质与层数）：
-- 全帧缓冲经动态材质按中心放大层 + 四向偏移层 + 对角偏移层叠加，再压一层黑色
-- 半透明，突出中央弹窗。
-- ====================================================================
local BlurLayers = {
    { dx = 0,  dy = 0,  sx = 1.04, sy = 1.04, a = 160 },
    { dx = -3, dy = 0,  sx = 1.0,  sy = 1.0,  a = 60 },
    { dx = 3,  dy = 0,  sx = 1.0,  sy = 1.0,  a = 60 },
    { dx = 0,  dy = -3, sx = 1.0,  sy = 1.0,  a = 60 },
    { dx = 0,  dy = 3,  sx = 1.0,  sy = 1.0,  a = 60 },
    { dx = -2, dy = -2, sx = 1.02, sy = 1.02, a = 45 },
    { dx = 2,  dy = -2, sx = 1.02, sy = 1.02, a = 45 },
    { dx = -2, dy = 2,  sx = 1.02, sy = 1.02, a = 45 },
    { dx = 2,  dy = 2,  sx = 1.02, sy = 1.02, a = 45 },
}
local DIM_ALPHA = 150 -- 黑色压暗 alpha（比结算层略重，弹窗须可阅读）
local BlurMat = nil

local function GetBlurMat()
    if BlurMat then return BlurMat end
    local tex = render.GetScreenEffectTexture()
    local rtName = tex and tex:GetName() or "_rt_FullFrameFB"
    BlurMat = CreateMaterial("kards_desync_blur", "UnlitGeneric", {
        ["$basetexture"] = rtName,
        ["$ignorez"] = "1",
        ["$translucent"] = "1",
    })
    return BlurMat
end

-- 服务端检测到结构性分歧：弹模糊重启窗（仅当前参战桌；幂等防重复弹）
net.Receive("KardsDesyncNotify", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) then return end
    local inT = KARDS.BattleState.inTable
    if not inT or inT.ent ~= ent then return end
    if KARDS.Desync then return end
    KARDS.Desync = { ent = ent, rect = nil }
end)

hook.Add("RenderScreenspaceEffects", "KardsDesyncBlur", function()
    if not KARDS.Desync then return end
    render.UpdateScreenEffectTexture()
    local mat = GetBlurMat()
    local w, h = ScrW(), ScrH()
    cam.Start2D()
        surface.SetMaterial(mat)
        for _, layer in ipairs(BlurLayers) do
            surface.SetDrawColor(255, 255, 255, layer.a)
            surface.DrawTexturedRect(-w * (layer.sx - 1) / 2 + layer.dx,
                -h * (layer.sy - 1) / 2 + layer.dy, w * layer.sx, h * layer.sy)
        end
        surface.SetDrawColor(0, 0, 0, DIM_ALPHA)
        surface.DrawRect(0, 0, w, h)
    cam.End2D()
end)

-- 点击沿检测：按下「重启」→ 请求软重进快照（服务端不释放槽位、不中断对局）
hook.Add("Think", "KardsDesyncThink", function()
    local ds = KARDS.Desync
    local left = input.IsMouseDown(MOUSE_LEFT)
    if ds and ds.rect and left and not prevClickLeft then
        local r = ds.rect
        local mx, my = gui.MouseX(), gui.MouseY()
        if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
            if KARDS.PlayKardsSound then KARDS.PlayKardsSound("click_button") end
            net.Start("KardsDesyncReenter")
                net.WriteEntity(ds.ent)
            net.SendToServer()
        end
    end
    prevClickLeft = left
end)

-- 弹窗 HUD：居中面板 + 标题「错误」+ 正文 + 「重启」按钮
hook.Add("HUDPaint", "KardsDesyncHUD", function()
    local ds = KARDS.Desync
    if not ds then return end
    local cx = ScrW() / 2
    -- 面板（宽 600：正文一行容纳；标题/正文/按钮纵向排布）
    local pw, ph = 600, 250
    local px, py = cx - pw / 2, ScrH() / 2 - ph / 2
    surface.SetDrawColor(24, 23, 20, 248)
    surface.DrawRect(px, py, pw, ph)
    -- 细边框（与按钮按下态同色 #C78736）
    surface.SetDrawColor(199, 135, 54, 255)
    surface.DrawOutlinedRect(px, py, pw, ph, 2)
    -- 标题
    draw.SimpleText("错误", "SourceHan_Heavy_40", cx, py + 58,
        Color(235, 110, 110), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 正文
    draw.SimpleText("服务端与客户端不同步，需要重启客户端", "SourceHan_Heavy_28", cx, py + 128,
        Color(235, 233, 225), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 重启按钮（与重新调度「确认」同款，160×52）
    local bw, bh = 160, 52
    local bx, by = cx, py + ph - 58
    KARDS.DrawActionButton(bx, by, bw, bh, "重启")
    ds.rect = { x = bx - bw / 2, y = by - bh / 2, w = bw, h = bh }
end)

-- ====================================================================
-- 软重进快照接收：本地清空对局共享状态后按服务端权威快照重建（世界实体均已存在，
-- 只重建本地索引表并立即落位；不播开局/发牌动画，玩家视角无中断）。
-- 载荷写序见 table_session.lua SendDesyncSnapshot。
-- ====================================================================
net.Receive("KardsDesyncSnapshot", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local turnSlot = net.ReadUInt(8)
    -- 本方手牌：实体 + 卡面标识（名/文件/类型）
    local handN = net.ReadUInt(8)
    local hands = {}
    for i = 1, handN do
        local e = net.ReadEntity()
        local name = net.ReadString()
        local fileName = net.ReadString()
        local ctype = net.ReadString()
        hands[i] = { e, name, fileName, ctype }
    end
    -- 两槽支援阵线：slot → { [col] = ent }
    local supports = {}
    for s = 1, 2 do
        local n = net.ReadUInt(8)
        local lay = {}
        for _ = 1, n do
            local col = net.ReadUInt(8)
            local e = net.ReadEntity()
            lay[col] = e
        end
        supports[s] = lay
    end
    -- 前线：归属槽 + 槽位布局
    local flOwner = net.ReadUInt(8)
    local flN = net.ReadUInt(8)
    local frontline = {}
    for _ = 1, flN do
        local col = net.ReadUInt(8)
        local e = net.ReadEntity()
        frontline[col] = e
    end
    local cp1 = net.ReadUInt(16)
    local cp2 = net.ReadUInt(16)
    local cs1 = net.ReadUInt(16)
    local cs2 = net.ReadUInt(16)

    -- 仅当前参战桌本人槽位接受快照（防串桌/串槽写入全局单例）
    local inT = KARDS.BattleState.inTable
    if not inT or inT.ent ~= ent or inT.slot ~= slot then return end
    local BS = KARDS.BattleState

    -- 清空对局共享状态（手牌/布局/指挥点/动画表/单位操作等，与退出/新对局同入口；
    -- inTable 不在其复位范围内，玩家并未离桌）
    KARDS.ResetBattleState()
    BS.battleStarted = true
    -- 回合方（0 = 重新调度窗口，先手回合未开始）
    BS.battleTurn = (turnSlot == 1 or turnSlot == 2) and turnSlot or nil
    -- 重新调度已结束（能收到快照说明对局已开始）：置双方完成态，避免等待横幅
    BS.mulliganStarted = true
    BS.mulliganDoneSlot[1] = true
    BS.mulliganDoneSlot[2] = true

    -- 手牌索引 + 卡面定向表 + 立即落位到本方扇形位（角度/悬停随后由 Think 接管）
    for i, it in ipairs(hands) do
        local e = it[1]
        if IsValid(e) then
            BS.realHandCards[slot][e] = i
            BS.cardFaces[e] = { name = it[2], fileName = it[3], ctype = it[4] }
            local pos, ang = KARDS.HandFanPos(slot, i, #hands)
            e:SetLocalPos(pos)
            e:SetLocalAngles(ang)
        end
    end

    -- 两支援阵线（P1 行 row=1 / P2 行 row=-1，与 KardsFieldLayout 接收器一致）
    for s = 1, 2 do
        local row = (s == 1) and 1 or -1
        for col, e in pairs(supports[s]) do
            BS.fieldLayouts[s][e] = col
            if IsValid(e) then
                e:SetLocalPos(KARDS.FieldPos(supports[s], e, col, row))
            end
        end
    end

    -- 前线（row=0）
    if flOwner == 1 or flOwner == 2 then BS.frontlineOwnerSlot = flOwner end
    for col, e in pairs(frontline) do
        BS.frontlineLayout[e] = col
        if IsValid(e) then
            e:SetLocalPos(KARDS.FieldPos(frontline, e, col, 0))
        end
    end

    -- 指挥点（公开入口：点数 + 槽数，直接落值不播滚动动画）
    if KARDS.CommandPointsApplyBroadcast then
        KARDS.CommandPointsApplyBroadcast(cp1, cp2, cs1, cs2)
    end

    -- 视角保险（软重进期间相机一直由牌桌接管，此处确保本地视角仍是本槽）
    if KARDS.Perspective and KARDS.Perspective.SetLocalView then
        KARDS.Perspective:SetLocalView(slot)
    end

    -- 重建完成：关闭弹窗
    KARDS.DesyncReset()
end)
