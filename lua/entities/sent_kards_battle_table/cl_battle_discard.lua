--[[
    Kards 战斗牌桌客户端模块：弃牌选择交互（cl_battle_discard.lua，2026-10-06）

    职责：为「弃牌」操作中「手中 / 自选的一张卡」路径提供手牌选择交互（协议见 init.lua
    的 KardsDiscard* 网络字符串注册与服务端 table_discard.lua）。

    交互（2026-10-06 用户规格）：
      1. 收到 KardsDiscardOffer（本方视角）：本方手牌在屏幕视野向上移动（沿卡面法线 z
         抬升 DiscardHandLift），进入可选择状态。
      2. 鼠标左键点击一张手牌选中（再次点击取消），选中卡在卡面上方绘制叠层图标
         （materials/kards/cards/choose.png，与重新调度选定的图相同）；屏幕 UI 在牌上方
         绘制「确认」按钮（KARDS.DrawActionButton，按钮形式与重新调度相同）。
      3. 点击「确认」→ 发送 KardsDiscardChoose（选中手牌序号）→ 服务端续跑数据层。
      4. 收到 KardsDiscardResult：关闭选择 UI（未弃牌/放弃时其余手牌回落；已弃牌时由
         KardsHandCardFlyOut 播放右槽飞出动画，见 cl_battle_mulligan.lua）。

    视角三分（与三选一/抉择同源）：仅本方（inTable.slot == 发起槽）显示交互 UI 与手牌上移；
    对手/观战视角无交互（弃牌离手后由飞出广播统一驱动手牌重排）。

    挂载：cl_init.lua include 本文件（cl_battle_choice.lua 之后）。
]]

if not CLIENT then return end

KARDS = KARDS or {}

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- 手牌上移距离（牌桌局部 z，沿卡面法线抬升）与上移/回落时长（秒）
local DiscardHandLift = 8
local DiscardHandRiseDur = 0.25

-- 常量提示文本尺寸缓存（2026-10-16 性能优化）：字体与文本固定，宽度只需测一次
local discardTipW, discardTipH
-- 语言切换：清空按语言测得的宽度缓存
KARDS.Lang.OnLanguageChanged(function()
    discardTipW, discardTipH = nil, nil
end)

-- 弃牌选择状态（跨 Think / HUDPaint 钩子共享）
KARDS.BattleDiscard = KARDS.BattleDiscard or {
    active     = false, -- 选择进行中（收到 Offer 起、Result 清理止）
    submitted  = false, -- 已提交（等待服务端结算）
    slot       = nil,   -- 发起槽位（1/2）
    view       = nil,   -- 视角 "self" | "enemy" | "spectate"
    viewSlot   = nil,   -- 视角槽位（左右镜像基准）
    tableEnt   = nil,   -- 发起牌桌实体
    ents       = {},    -- 手牌实体（服务端下发顺序，即手牌序号 1..n）
    count      = 0,     -- 手牌张数
    selected   = nil,   -- 已选中的手牌实体（本方，单选）
    prevLeft   = false, -- 左键上一帧状态（上升沿判定）
    confirmRect = nil,  -- 确认按钮屏幕矩形（命中判定用，HUDPaint 内每帧写入）
}

local BD = KARDS.BattleDiscard

-- 清空弃牌选择状态（退出牌桌 / 新对局 / 对局结束 / 选择结束）
function KARDS.BattleDiscardReset()
    BD.active = false
    BD.submitted = false
    BD.slot = nil
    BD.view = nil
    BD.viewSlot = nil
    BD.tableEnt = nil
    BD.ents = {}
    BD.count = 0
    BD.selected = nil
    BD.prevLeft = false
    BD.confirmRect = nil
end

-- 选中卡叠层图标材质（materials/kards/cards/choose.png，与重新调度选定图相同）
local chooseMat = Material("materials/kards/cards/choose.png", "noclamp smooth")

-- 文字提示渐变背景材质（同重新调度提示横幅，materials/kards/ui/textUnderground.png）
local textUndergroundMat = Material("materials/kards/ui/textUnderground.png", "noclamp smooth")

-- 射线命中一张本方手牌（同三选一 HitPickCard：阈值 10^2）
local function HitDiscardCard()
    local pos, dir = KARDS.HitTest.MouseRay()
    if not pos then return nil end
    return KARDS.HitTest.NearestInRay(pos, dir, BD.ents, KARDS.HitTest.Radii.Candidate)
end

-- 提交弃牌选择（点击「确认」）：选中手牌序号发送服务端
local function SubmitDiscard()
    if not BD.active or BD.submitted or not IsValid(BD.selected) then return end
    if not IsValid(BD.tableEnt) then return end
    local index
    for i = 1, BD.count do
        if BD.ents[i] == BD.selected then index = i break end
    end
    if not index then return end
    BD.submitted = true
    BD.prevLeft = false
    KARDS.PlayKardsSound("click_button") -- 确认按钮点击音效（同重新调度）
    net.Start("KardsDiscardChoose")
        net.WriteEntity(BD.tableEnt)
        net.WriteUInt(index, 8)
    net.SendToServer()
    KARDS.UpdateTableMouse()
end

-- ====================================================================
-- 选择开始：本方手牌上移 + 进入可选择状态
-- ====================================================================
net.Receive("KardsDiscardOffer", function()
    local tableEnt = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local n = net.ReadUInt(8)
    local cnt = math.min(n, 32)
    local ents = {}
    for i = 1, cnt do
        local e = net.ReadEntity()
        ents[i] = IsValid(e) and e or false -- 无效/未传播实体写 false 占位，不留空洞
    end
    if slot ~= 1 and slot ~= 2 then return end
    if not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    -- 视角三分
    local inTable = KARDS.BattleState.inTable
    local mine = inTable and inTable.slot
    local view
    if mine == slot then
        view = "self"
    elseif KARDS.Perspective and KARDS.Perspective.LocalView == nil then
        view = "spectate"
    else
        view = "enemy"
    end
    KARDS.BattleDiscardReset()
    BD.active = true
    BD.slot = slot
    BD.view = view
    BD.viewSlot = (KARDS.Perspective and KARDS.Perspective.LocalView) or slot
    BD.tableEnt = tableEnt
    BD.ents = ents
    BD.count = cnt
    -- 仅本方视角上移手牌并允许选择（其余视角无交互）
    if view == "self" then
        for i = 1, cnt do
            local e = ents[i]
            if IsValid(e) then
                e:SetNoDraw(false)
                -- 卡面法线（父局部 z）抬升：上移过程中 RealHandFacing 因动画未结束跳过，
                -- 动画结束后仅驱动角度、不覆盖位置，抬升保持
                KARDS.AnimPlayer:Play(e, {
                    { t = 0 },
                    { t = DiscardHandRiseDur,
                      pos = e:GetLocalPos() + Vector(0, 0, DiscardHandLift),
                      ang = e:GetLocalAngles(), easing = "cos" },
                }, { group = "discardSelect" })
            end
        end
    end
    KARDS.UpdateTableMouse()
end)

-- ====================================================================
-- 选择结束：关闭选择 UI（未弃牌/放弃时其余手牌回落）
-- ====================================================================
net.Receive("KardsDiscardResult", function()
    local tableEnt = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local chosenIndex = net.ReadUInt(8)
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    if not BD.active or BD.slot ~= slot then return end
    -- 放弃/超时未弃牌：手牌回落（重排回原扇形位，移除抬升）
    -- 已选中弃牌：抬升由 KardsHandCardFlyOut 的右槽飞出接管，其余手牌由该广播重排让位
    if BD.view == "self" and chosenIndex == 0 then
        KARDS.RenumberHand(slot, nil, BD.count)
    end
    KARDS.BattleDiscardReset()
end)

-- ====================================================================
-- 每帧：状态校验 + 左键选中/确认（仅本方）
-- ====================================================================
hook.Add("Think", "KardsBattleDiscardUpdate", function()
    if not BD.active then return end
    if not IsValid(BD.tableEnt) or not KARDS.BattleState:IsLocalTable(BD.tableEnt) then
        KARDS.BattleDiscardReset()
        return
    end
    KARDS.UpdateTableMouse() -- 牌桌内鼠标恒呼出（同三选一/抉择）
    if BD.view ~= "self" or BD.submitted then
        BD.prevLeft = false
        return
    end
    local hover = HitDiscardCard()
    local left = input.IsMouseDown(MOUSE_LEFT)
    if left and not BD.prevLeft then
        local mX, mY = gui.MouseX(), gui.MouseY()
        local r = BD.confirmRect
        if r and mX >= r.x and mX <= r.x + r.w and mY >= r.y and mY <= r.y + r.h then
            SubmitDiscard()
        elseif IsValid(hover) then
            -- 单选：点同一张取消，否则换选
            BD.selected = (BD.selected == hover) and nil or hover
            KARDS.PlayKardsSound("select_card") -- 选中/取消选择音效（同重新调度）
        end
    end
    BD.prevLeft = left
end)

-- ====================================================================
-- HUD：选中卡叠层图标（3D2D）+ 牌上方「确认」按钮（与重新调度同款）
-- ====================================================================
hook.Add("HUDPaint", "KardsBattleDiscardHUD", function()
    if not BD.active or BD.submitted or BD.view ~= "self" then return end
    -- 被选中的卡：卡面上方（局部 z+0.8）绘制选中图标（角度构造式同重新调度选卡图标）
    local sel = BD.selected
    if IsValid(sel) then
        local dx = sel:GetForward()
        local dy = sel:GetRight()
        local camAng = dx:AngleEx(dx:Cross(-dy))
        cam.Start3D2D(sel:GetPos() + sel:GetUp() * 0.8, camAng, 1)
            surface.SetMaterial(chooseMat)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.DrawTexturedRect(-0.7, -0.7, 1.4, 1.4)
        cam.End3D2D()
    end
    -- 确认按钮：牌上方的屏幕 UI（取手牌最上沿屏幕 y 再上移一段；取不到时回退屏幕中下）
    local topY = nil
    for i = 1, BD.count do
        local e = BD.ents[i]
        if IsValid(e) then
            local sp = e:GetPos():ToScreen()
            if sp.visible then
                local yy = sp.y - 48
                if not topY or yy < topY then topY = yy end
            end
        end
    end
    local y = topY or (ScrH() * 0.72)
    y = math.Clamp(y, 120, ScrH() - 120)
    local x = ScrW() / 2
    local w, h = 160, 52
    BD.confirmRect = { x = x - w / 2, y = y - h / 2, w = w, h = h }
    -- 提示横幅（textUnderground.png 横向渐变背景，包裹提示文字，置于按钮上方 8px）
    local tipText = T("battle.discard.tip")
    local tipFont = "SourceHan_Heavy_36"
    if not discardTipW then
        surface.SetFont(tipFont)
        discardTipW, discardTipH = surface.GetTextSize(tipText)
    end
    local tw, th = discardTipW, discardTipH
    local tipPadX, tipPadY = 28, 12
    local tipW, tipH = tw + tipPadX * 2, th + tipPadY * 2
    local tipY = y - h / 2 - 8 - tipH
    surface.SetMaterial(textUndergroundMat)
    surface.SetDrawColor(255, 255, 255, 255)
    surface.DrawTexturedRect(x - tipW / 2, tipY, tipW, tipH)
    draw.SimpleText(tipText, tipFont, x, tipY + tipH / 2,
        Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 确认按钮（与重新调度确认按钮同款：KARDS.DrawActionButton）
    KARDS.DrawActionButton(x, y, w, h, T("common.confirm"))
end)
