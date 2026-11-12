--[[
    Kards 战斗牌桌客户端模块：对局结算（cl_battle_gameover.lua）

    职责（readme 7.1 总部）：一方总部防御为非正数时该总部被摧毁 → 数据层判定胜负
    （sh_battlefield.lua CheckHQDestroyed）+ 服务端移除总部实体并广播 KardsGameOver
    （table_battledeck.lua OnGameOver）→ 本文件 net.Receive 接收后播放结算序列：

    时间轴（参战者；观战方无震屏/相机动画）：
      0.0~3.0   结算动画样式（二选一，见 ANIM_STYLE）：
                - 双方屏幕震动（观战方不需要）
                - 摄像头移向本方玩家模型肩后、视野中心瞄定对方玩家模型
      3.0       应用全屏模糊（RenderScreenspaceEffects 绘制全帧缓冲多层偏移近似 +
                黑色半透明矩形覆盖，突出胜负文字）
      3.0~3.6   胜利/失败字样从极大字号缩小到正常字号（保留结算图片接口
                KARDS.GameOverGetBannerImage，后续接图后替代文字绘制——
                图片为正方形，位于胜负文字上方）
      3.6       屏幕底部显示「继续」（动画 3 秒 + 字样缩小 0.6 秒后）
      点击后     屏幕渐变为黑屏 → 退出方退出牌桌（发送 KardsTableExit）→ 取消模糊
                → 淡出到正常视野

    双毁：最早被摧毁方失败由数据层判定，本文件只按 winner/loser 槽位显示。

    挂载：cl_init.lua include 本文件（cl_battle_ops.lua / cl_battle_frontline_symbol.lua
    之后，见加载链注释）。
    约定：常驻钩子/状态挂 KARDS 命名空间（KARDS.GameOver 进行中状态 +
    KARDS.BattleState.gameOver 输入抑制标志 + KARDS.GameOverReset 清理入口），不新增
    cl_init.lua main chunk 局部槽压力。
]]

if not CLIENT then return end

KARDS = KARDS or {}

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- ====================================================================
-- 常量（readme 7.1 结算时间轴；2026-08-13 全部时长 ×3）
-- ====================================================================
local SHAKE_DUR = 3.0        -- 屏幕震动时长（秒；观战方不需要）
local SHAKE_AMP = 3.0        -- 震动幅度（世界单位，CalcView 随机偏移上限；回合切换轻微抖动为 0.6）
local CAM_DUR = 3.0          -- 摄像头移向本方玩家肩后动画时长（秒）
local BLUR_DELAY = 3.0       -- 结算序列开始后多久应用全屏模糊（秒）
local BANNER_DUR = 0.6       -- 胜负字样从极大字号缩小到正常字号时长（秒，自模糊应用起）
-- 「继续」显示时刻（readme 7.1「1.2 秒后屏幕底显示继续」×3 = 3.6 秒）：= 动画 3 秒 +
-- 字样缩小 0.6 秒后（即序列开始 3.6s，字样刚缩小到正常大小）
local CONTINUE_AT = BLUR_DELAY + BANNER_DUR
local FADE_BLACK_DUR = 1.8   -- 点击后屏幕渐变为黑屏时长（秒）
local FADE_OUT_DUR = 1.8     -- 黑屏淡出到正常视野时长（秒）

-- 结算动画样式（readme 7.1「两个动画样式」：屏幕震动 / 摄像头移动 二选一——
-- 使用摄像头震动就不能用摄像头移动，代码内配置）：
--   "shake"  仅屏幕震动（观战方不需要）
--   "camera" 仅摄像头移向本方玩家模型肩后、视野中心瞄定对方玩家模型
local ANIM_STYLE = "camera"

-- 相机：本方玩家模型肩后（过肩第三人称，2026-08-13：原 BACK_DIST=95 过远且为
-- 背部正后方；改为肩后偏右，越过本方右肩瞄定对方，见下方相机计算）
local SHOULDER_HEIGHT = 58   -- 相机高度（槽位地面之上，世界单位；玩家眼高约 64，肩下微抬）
local BACK_DIST = 62         -- 相机在本方肩后、距肩部水平距离（世界单位）
local SIDE_OFFSET = 26       -- 过肩侧向偏移：肩后向右偏移（过肩视角，非背部正后方）

-- 胜负字样字号（正常 = 库中已注册最大字号 72；极大 = 动态注册的 240）
local BANNER_FONT_NORMAL = 72
local BANNER_FONT_HUGE = 240

-- 全屏模糊近似：把当前帧全帧缓冲（_rt_FullFrameFB，render.UpdateScreenEffectTexture
-- 更新）经动态创建的材质按「中心放大层 + 四向偏移层 + 对角偏移层」叠加绘制
-- （盒式模糊近似，无自定义 shader）。每层 alpha 为叠加权重，总权重 ≈ 0.9
-- （见 KardsGameOverBlur 注释），整体亮度基本不变。材质为 CreateMaterial 动态创建
-- 并绑定 RT（2026-08-13：本机 GMod 缺失官方 pp/final 材质，Material("pp/final")
-- 返回 error 材质 → 全屏紫黑棋盘格，故不再依赖该材质文件）。
local BlurLayers = {
    { dx = 0,    dy = 0,    sx = 1.04, sy = 1.04, a = 160 }, -- 中心：轻微放大 = 柔焦主层
    { dx = -3,   dy = 0,    sx = 1.0,  sy = 1.0,  a = 60 },
    { dx = 3,    dy = 0,    sx = 1.0,  sy = 1.0,  a = 60 },
    { dx = 0,    dy = -3,   sx = 1.0,  sy = 1.0,  a = 60 },
    { dx = 0,    dy = 3,    sx = 1.0,  sy = 1.0,  a = 60 },
    { dx = -2,   dy = -2,   sx = 1.02, sy = 1.02, a = 45 },
    { dx = 2,    dy = -2,   sx = 1.02, sy = 1.02, a = 45 },
    { dx = -2,   dy = 2,    sx = 1.02, sy = 1.02, a = 45 },
    { dx = 2,    dy = 2,    sx = 1.02, sy = 1.02, a = 45 },
}

-- 黑半透明覆盖 alpha（叠加在模糊之上，突出胜负字样；readme 7.1 结算全屏效果
-- 「黑色半透明矩形覆盖 + 模糊」）
local BLUR_DIM_ALPHA = 110

-- ====================================================================
-- 结算状态（进行中非 nil）：
--   KARDS.GameOver = {
--       ent        牌桌实体
--       winner     胜利槽位（1/2）   loser 失败槽位（1/2）
--       ownSlot    本方槽位（参战者；观战者 nil）
--       won        本方是否胜利（参战者判定；观战者恒 false）
--       spectator  是否观战者（无本方槽位 / 非参战槽）
--       start      序列开始 CurTime
--       blur       是否应用全屏模糊
--       continueAt 「继续」显示时刻
--       clickable  可点击（「继续」已显示，等待鼠标）
--       blackPhase 黑屏阶段 "none"|"in"|"out"（点击后渐变黑屏 / 淡出到正常视野）
--       blackStart 当前黑屏阶段开始时刻
--       exitSent   已发送退出请求（服务端 KardsTableExited 到达后由该广播复位相机）
--   }
-- ====================================================================

-- 全帧缓冲材质（动态创建并绑定 _rt_FullFrameFB，首帧懒创建；见 GetBlurMat 注释）
local BlurMat = nil

-- 获取全帧缓冲材质（首帧懒创建）。
-- 2026-08-13：本机 GMod 缺失官方材质（garrysmod/materials/pp 目录不存在），
-- Material("pp/final") 返回 error 材质（紫黑棋盘格）→ 全屏紫黑棋盘。
-- 改为 CreateMaterial 动态创建 UnlitGeneric 材质并绑定引擎屏幕效果 RT：
-- RT 名取 render.GetScreenEffectTexture() 的真实注册名（GetName），回退引擎内建名
-- "_rt_FullFrameFB"（与 cl_canvas_editor.lua 绑定 RT 材质同款模式，不依赖材质文件）。
local function GetBlurMat()
    if BlurMat then return BlurMat end
    local tex = render.GetScreenEffectTexture()
    local rtName = tex and tex:GetName() or "_rt_FullFrameFB"
    BlurMat = CreateMaterial("kards_gameover_blur", "UnlitGeneric", {
        ["$basetexture"] = rtName,
        ["$ignorez"] = "1",
        ["$translucent"] = "1",
    })
    return BlurMat
end

-- 鼠标左键上一帧状态（「继续」点击沿检测；结算结束 / 新对局复位）
local prevClickLeft = false

-- 胜负字样可用字号表（库中已注册 2~72；本模块补注册 80~240，见下方补注册循环）
local BannerSizes = {}

-- 补注册结算用大字号（库 sh_fonts.lua 仅注册到 72；同款字体参数保证视觉一致）
do
    for size = BANNER_FONT_HUGE, BANNER_FONT_NORMAL, -16 do
        table.insert(BannerSizes, size)
    end
    table.sort(BannerSizes)
    for _, size in ipairs(BannerSizes) do
        if size > BANNER_FONT_NORMAL then -- 库 sh_fonts.lua 已注册 2~72；本模块只补注册更大字号
            surface.CreateFont("SourceHan_Heavy_" .. size, {
                font = "Source Han Sans SC Heavy", -- 与 Oak_world_Library sh_fonts.lua internal_name 一致
                size = size,
                weight = 900,
                antialias = true,
                extended = true, -- 支持中文
                shadow = false,
            })
        end
    end
end

-- 取最接近目标字号的可用字体标识符（如 "SourceHan_Heavy_160"）。
-- 结果按目标字号做记忆化（2026-10-16 性能优化）：缩放入场动画每帧传入不同的
-- 整数尺寸，重复尺寸直接复用字体名，免去每次线性查找 + 字符串拼接
local bannerFontCache = {}
local function BannerFont(size)
    local cached = bannerFontCache[size]
    if cached then return cached end
    local best = BannerSizes[1]
    local minDiff = math.abs(best - size)
    for _, s in ipairs(BannerSizes) do
        local d = math.abs(s - size)
        if d < minDiff then minDiff, best = d, s end
    end
    cached = "SourceHan_Heavy_" .. best
    bannerFontCache[size] = cached
    return cached
end

--[[
    结算图片接口（readme 7.1「保留结算的胜利或失败的图片接口」）：
    当前为文字实现；后续接入胜利/失败图片时在本函数返回对应 Material 即可。
    绘制规格（见 KardsGameOverHUD）：图片为正方形，位于胜负文字上方
    （边长为当前字号，中心在文字中心上方 1.6 倍字号处），不铺满全屏。
    @param won boolean 是否胜利方结算
    @return Material|nil 结算图片材质（nil = 绘制文字）
]]
function KARDS.GameOverGetBannerImage(won)
    return nil
end

-- 清理结算状态 + 复位输入抑制（GameOverReset / 黑屏淡出完成 / Think 兜底共用，
-- 阶段五 P2 收敛三处重复的「GameOver=nil + gameOver=false + prevClickLeft=false」）
local function ClearGameOver()
    KARDS.GameOver = nil
    KARDS.BattleState.gameOver = false
    prevClickLeft = false
end

--[[
    清理结算状态（新对局 KardsTableBattleStart / 退出牌桌 KardsTableExited 调用，
    见 cl_init.lua 对应接收器；幂等）。
    黑屏动画进行中（blackPhase ~= "none"）时不立即清理——点击退出后黑屏淡出动画
    须由 KardsGameOverThink 推进完成（否则「淡出到正常视野」被瞬断），仅复位输入。
]]
function KARDS.GameOverReset()
    local go = KARDS.GameOver
    if not go then
        ClearGameOver()
        return
    end
    if go.blackPhase ~= "none" then return end
    ClearGameOver()
end

-- ====================================================================
-- 结算广播接收（服务端 OnGameOver：WriteEntity 牌桌, WriteUInt winner, WriteUInt loser）
-- ====================================================================
net.Receive("KardsGameOver", function()
    local ent = net.ReadEntity()
    local winner = net.ReadUInt(8)
    local loser = net.ReadUInt(8)
    if not IsValid(ent) then return end
    -- 仅本桌相关者处理（参战者 inTable 匹配 / 观战者 spectate 匹配）；幂等
    local inT = KARDS.BattleState.inTable
    local sp = KARDS.BattleState.spectate
    if not ((inT and inT.ent == ent) or (sp and sp.ent == ent)) then return end
    if KARDS.GameOver then return end
    -- 对局已结束：关闭测试版不同步重启弹窗（若残留，结算界面接管屏幕）
    if KARDS.DesyncReset then KARDS.DesyncReset() end
    -- 对局已结束：清空三选一交互（候选实体/动画/悬停态，见 cl_battle_pick.lua）
    if KARDS.BattlePickReset then KARDS.BattlePickReset() end
    -- 对局已结束：清空弃牌选择交互（手牌上移/选中/确认按钮，见 cl_battle_discard.lua）
    if KARDS.BattleDiscardReset then KARDS.BattleDiscardReset() end
    -- 对局已结束（胜负分定）：角落玩家头像面板退场（头像与玩家名同时淡出，
    -- 2026-10-10，见 cl_battle_player_panel.lua）
    if KARDS.PlayerPanelOutro then KARDS.PlayerPanelOutro() end

    local ownSlot = (inT and inT.ent == ent) and inT.slot or nil
    local isParticipant = ownSlot ~= nil and (ownSlot == winner or ownSlot == loser)
    local won = isParticipant and ownSlot == winner

    KARDS.GameOver = {
        ent = ent,
        winner = winner,
        loser = loser,
        ownSlot = ownSlot,
        won = won,
        spectator = not isParticipant,
        start = CurTime(),
        blur = false,
        continueAt = nil,
        clickable = false,
        blackPhase = "none",
        blackStart = 0,
        exitSent = false,
    }
    KARDS.BattleState.gameOver = true -- 输入抑制标志（拖牌/单位操作/结束回合，见各钩子门控）
    -- 冻结进行中的操作（防结算期间继续拖牌/选中单位）
    KARDS.BattleState.dragCard = nil
    KARDS.BattleState.pendingPlayEnt = nil
    if KARDS.UnitOpsReset then KARDS.UnitOpsReset() end

    -- 结算动画样式（readme 7.1「两个动画样式」：二选一，见 ANIM_STYLE——
    -- 使用屏幕震动就不能用摄像头移动；观战方两者都不需要）
    if isParticipant and ANIM_STYLE == "shake" then
        -- 屏幕震动（CalcView 叠加随机偏移，见 cl_battle_camera.lua）
        KARDS.BattleCamera.Shake = { start = CurTime(), endT = CurTime() + SHAKE_DUR, amp = SHAKE_AMP }
    elseif isParticipant and ANIM_STYLE == "camera" then
        -- 摄像头移向本方玩家模型肩后（过肩第三人称），视野中心瞄定对方玩家模型：
        -- 本方模型 = 槽位世界坐标（进入时玩家被移到槽位中心，见 TableSession:Enter）；
        -- 过肩 = 肩位（槽位中心 + 肩高）− 前向（本方→对方）× BACK_DIST + 右向
        -- × SIDE_OFFSET（肩后偏右越过本方右肩，非背部正后方）；朝向 = 对方槽位肩部
        local enemySlot = (ownSlot == 1) and 2 or 1
        local own = ent:GetSlotWorldPos(ownSlot)
        local enemy = ent:GetSlotWorldPos(enemySlot)
        local fwd = (enemy - own):GetNormalized()
        local right = fwd:Cross(Vector(0, 0, 1)):GetNormalized() -- 本方右向（右手系：fwd × up）
        local camPos = own + Vector(0, 0, SHOULDER_HEIGHT) - fwd * BACK_DIST + right * SIDE_OFFSET
        local camAng = (enemy + Vector(0, 0, SHOULDER_HEIGHT) - camPos):Angle()
        local ply = LocalPlayer()
        -- 起点 = 当前相机视图（CalcView 记录；未接管时回退玩家眼睛），CAM_DUR 缓动到肩后
        local fromPos = KARDS.BattleCamera.ViewPos or ply:EyePos()
        local fromAng = KARDS.BattleCamera.ViewAng or ply:EyeAngles()
        KARDS.BattleCamera:SetView(ply, camPos, camAng, 75, CAM_DUR, fromPos, fromAng)
    end
end)

-- ====================================================================
-- 序列推进 Think：模糊应用 / 继续显示 / 点击检测 / 黑屏阶段状态机 / 兜底清理
-- ====================================================================
hook.Add("Think", "KardsGameOverThink", function()
    local go = KARDS.GameOver
    if not go then return end
    local now = CurTime()
    local t = now - go.start

    -- 3.0s 后应用全屏模糊（RenderScreenspaceEffects 钩子按 go.blur 生效）
    if not go.blur and t >= BLUR_DELAY then
        go.blur = true
    end
    -- 序列开始 3.6s 后屏幕底显示「继续」，此后可点击
    if not go.continueAt and t >= CONTINUE_AT then
        go.continueAt = now
        go.clickable = true
    end

    -- 点击「继续」：屏幕渐变为黑屏 → 黑屏完成后退出牌桌 + 取消模糊 + 淡出
    local left = input.IsMouseDown(MOUSE_LEFT)
    if go.clickable and left and not prevClickLeft then
        go.clickable = false
        go.blackPhase = "in"
        go.blackStart = now
    end
    prevClickLeft = left

    -- 黑屏阶段状态机
    if go.blackPhase == "in" then
        local p = (now - go.blackStart) / FADE_BLACK_DUR
        if p >= 1 then
            -- 黑屏完成：退出方退出牌桌（参战者；观战者仅关闭结算界面）
            if go.ownSlot then
                net.Start("KardsTableExit")
                    net.WriteEntity(go.ent)
                net.SendToServer()
                go.exitSent = true
            end
            go.blur = false -- 取消模糊
            go.blackPhase = "out" -- 淡出到正常视野
            go.blackStart = now
        end
    elseif go.blackPhase == "out" then
        local p = (now - go.blackStart) / FADE_OUT_DUR
        if p >= 1 then
            ClearGameOver()
        end
    elseif go.ownSlot and not go.exitSent and not KARDS.BattleState.inTable then
        -- 兜底清理：参战者在等待点击期间离开牌桌（服务端强制退出 / 牌桌销毁）
        ClearGameOver()
    end
end)

-- ====================================================================
-- 全屏模糊（RenderScreenspaceEffects：3D 场景渲染后、HUD 前；观战者也应用）
-- 实现：更新全帧缓冲 → cam.Start2D 下用动态材质（GetBlurMat，绑定 _rt_FullFrameFB）
-- 按 BlurLayers 偏移叠加绘制（盒式模糊近似，无自定义 shader）→ 再叠一层黑色半透明
-- 矩形覆盖（readme 7.1「全屏 = 黑色半透明矩形覆盖 + 模糊」，突出胜负字样）。
-- 每层 alpha 为叠加权重：1 - ∏(1-a) ≈ 1 - 0.4·0.765⁴·0.823⁴ ≈ 0.90（亮度基本不变）。
-- ====================================================================
hook.Add("RenderScreenspaceEffects", "KardsGameOverBlur", function()
    local go = KARDS.GameOver
    if not (go and go.blur) then return end
    render.UpdateScreenEffectTexture() -- 当前帧场景拷入 _rt_FullFrameFB
    local mat = GetBlurMat()
    local w, h = ScrW(), ScrH()
    cam.Start2D()
        surface.SetMaterial(mat)
        for _, layer in ipairs(BlurLayers) do
            surface.SetDrawColor(255, 255, 255, layer.a)
            surface.DrawTexturedRect(-w * (layer.sx - 1) / 2 + layer.dx, -h * (layer.sy - 1) / 2 + layer.dy, w * layer.sx, h * layer.sy)
        end
        -- 黑色半透明矩形覆盖（叠于模糊之上）
        surface.SetDrawColor(0, 0, 0, BLUR_DIM_ALPHA)
        surface.DrawRect(0, 0, w, h)
    cam.End2D()
end)

-- ====================================================================
-- 结算 HUD：胜负字样（放大缩小动画 + 图片接口）/ 「继续」/ 黑屏覆盖
-- ====================================================================
hook.Add("HUDPaint", "KardsGameOverHUD", function()
    local go = KARDS.GameOver
    if not go then return end
    local now = CurTime()
    local t = now - go.start

    -- 胜负字样（模糊应用起 0.6s 从极大字号缩小到正常字号）
    if t >= BLUR_DELAY and go.blackPhase == "none" then
        local tp = math.min(1, (t - BLUR_DELAY) / BANNER_DUR)
        local eased = 1 - (1 - tp) * (1 - tp) * (1 - tp) -- easeOutCubic：先快后慢
        local size = math.floor(BANNER_FONT_HUGE + (BANNER_FONT_NORMAL - BANNER_FONT_HUGE) * eased + 0.5)
        local cx, cy = ScrW() / 2, ScrH() * 0.38
        local mat = KARDS.GameOverGetBannerImage(go.won)
        if mat then
            -- 图片接口：正方形，位于胜负文字上方（边长为当前字号，图片中心在文字
            -- 中心上方 1.6 倍字号处；readme 7.1「图片在胜利或失败文字的上方为正方形」，
            -- 不铺满全屏）
            local s = size
            surface.SetMaterial(mat)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.DrawTexturedRect(cx - s / 2, cy - size * 1.6 - s / 2, s, s)
        else
            local text, color
            if go.spectator then
                text = T("battle.gameover.win_slot", go.winner)
                color = Color(255, 215, 90)
            else
                text = go.won and T("battle.gameover.win") or T("battle.gameover.lose")
                color = go.won and Color(255, 215, 90) or Color(235, 110, 110)
            end
            draw.SimpleTextOutlined(text, BannerFont(size), cx, cy, color,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 3, Color(20, 20, 20, 220))
            -- 观战者补一行失败方提示
            if go.spectator then
                draw.SimpleTextOutlined(T("battle.gameover.lose_slot", go.loser), "SourceHan_Heavy_28", cx, cy + 56,
                    Color(210, 130, 130), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(20, 20, 20, 200))
            end
        end
    end

    -- 屏幕底部「继续」（显示后轻微呼吸提示可点击）
    if go.continueAt and go.blackPhase == "none" then
        local pulse = 200 + math.floor(55 * (math.sin(now * 4) * 0.5 + 0.5))
        draw.SimpleText(T("battle.gameover.continue"), "SourceHan_Heavy_28", ScrW() / 2, ScrH() - 120,
            Color(255, 255, 255, pulse), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- 黑屏覆盖（点击后渐变为黑屏 / 退出后淡出到正常视野；覆盖全部 HUD）
    if go.blackPhase ~= "none" then
        local p = (now - go.blackStart) / (go.blackPhase == "in" and FADE_BLACK_DUR or FADE_OUT_DUR)
        local a = math.floor(255 * (go.blackPhase == "in" and math.min(1, p) or math.max(0, 1 - p)))
        draw.RoundedBox(0, 0, 0, ScrW(), ScrH(), Color(0, 0, 0, a))
    end
end)
