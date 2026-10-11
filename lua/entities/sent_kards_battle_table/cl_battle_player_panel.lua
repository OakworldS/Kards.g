--[[
    Kards 战斗牌桌客户端模块：对局内玩家头像面板（cl_battle_player_panel.lua，2026-10-10）

    职责（用户需求）：对局开始「先手揭晓」序列结束后，在指挥点（槽）面板上移让出的
    角落位置常驻展示玩家头像 + 玩家名（友方左下角、敌方左上角）：
      - 头像：引擎内置 AvatarImage 控件，边长与指挥点面板同尺寸（KARDS.CPAvatarSize），
        位置取 KARDS.CPAvatarRect(slot)（cl_battle_command_points.lua 导出）
      - 玩家名：绘制于头像右侧（字号 32），英文段用 Dday 字体、中文段用思源黑体 Heavy
        （GMod surface 无富文本，按字符类型分段测量 + 依次绘制，见 DrawMixedNameText）
      - 入场（KARDS.PlayerPanelIntro，先手揭晓结束后触发）：头像淡入 + 玩家名自头像
        中心向右滑动到位并同步淡入
      - 退场（KARDS.PlayerPanelOutro，KardsGameOver 结算广播瞬间触发）：头像与玩家名
        同时淡出

    挂载：cl_init.lua include 本文件（cl_battle_command_points.lua 之后，读取其角落布局）。
    数据源：本方取 LocalPlayer()；敌方取 KardsTableBattleStart 参战分支附带的敌方昵称 +
    SteamID64（由 cl_init.lua 存入 KARDS.PlayerPanelData）。观战者不展示（无本方槽位）。
    约定：状态下挂 KARDS.PlayerPanel，不新增 cl_init.lua main chunk 局部槽压力。
]]

KARDS = KARDS or {}

local NAME_SIZE = 32                                  -- 玩家名字号（Dday / SourceHan_Heavy 均已注册 32）
local NAME_FONT_EN = "Dday_" .. NAME_SIZE             -- 英文（ASCII）段字体
local NAME_FONT_ZH = "SourceHan_Heavy_" .. NAME_SIZE  -- 中文（非 ASCII）段字体
local NAME_GAP = 10                                   -- 名字左缘与头像右缘的间距（px）
local INTRO_DUR = 0.6                                 -- 入场时长（秒，头像淡入 / 名字滑动淡入）
local OUTRO_DUR = 0.6                                 -- 退场时长（秒，头像与名字同时淡出）

-- 数据源（cl_init.lua KardsTableBattleStart 参战分支写入；退出 / 新对局经
-- KARDS.ResetBattleState → KARDS.PlayerPanelReset 复位）：{ enemyName, enemySteamID64 }
KARDS.PlayerPanelData = nil

-- 面板状态（进行中非 nil）：
--   { ownAvatar, enemyAvatar, ownName, enemyName,
--     phase = "in"|"out"（入场 / 退场阶段）, phaseStart = 阶段开始 CurTime,
--     alpha = 整体透明度 0..1, slide = 名字滑动进度 0..1（入场 0→1） }
-- 角落归属每帧按当前本方槽位（KARDS.BattleState.inTable.slot）实时计算，与指挥点面板
-- 一致（无对手模式 kards_switch 可切换本方槽位）。
KARDS.PlayerPanel = nil

-- 创建头像面板（引擎内置 AvatarImage：SetPlayer 经 Steamworks 取 SteamID64，
-- 从 Steam CDN 异步下载对应分辨率头像，期间显示默认占位头像；184 = 最高分辨率）
local function MakeAvatar(playerEnt)
    local av = vgui.Create("AvatarImage")
    local size = KARDS.CPAvatarSize or 50
    av:SetSize(size, size)
    av:SetMouseInputEnabled(false)
    av:SetKeyboardInputEnabled(false)
    if IsValid(playerEnt) then av:SetPlayer(playerEnt, 184) end
    return av
end

--[[
    重置头像面板（退出牌桌 / 新对局开始调用，经 KARDS.ResetBattleState；幂等）：
    移除头像控件并清空面板状态与数据源。
]]
function KARDS.PlayerPanelReset()
    local pp = KARDS.PlayerPanel
    if pp then
        if IsValid(pp.ownAvatar) then pp.ownAvatar:Remove() end
        if IsValid(pp.enemyAvatar) then pp.enemyAvatar:Remove() end
    end
    KARDS.PlayerPanel = nil
    KARDS.PlayerPanelData = nil
end

--[[
    入场：先手揭晓序列结束后调用（cl_init.lua KardsFirstTurnReveal 段），幂等。
    仅参战者展示（观战者无本方槽位 → 直接返回）。
]]
function KARDS.PlayerPanelIntro()
    if KARDS.PlayerPanel then return end
    local inT = KARDS.BattleState.inTable
    if not inT then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local data = KARDS.PlayerPanelData or {}
    -- 敌方玩家实体（按 SteamID64 查找；已离开 / 虚拟对手 → nil → 白色矩形兜底）
    local enemyPly = nil
    if data.enemySteamID64 and data.enemySteamID64 ~= "" then
        enemyPly = player.GetBySteamID64(data.enemySteamID64)
    end
    local hasEnemy = IsValid(enemyPly)
    KARDS.PlayerPanel = {
        ownAvatar = MakeAvatar(ply),
        enemyAvatar = hasEnemy and MakeAvatar(enemyPly) or nil,
        ownName = ply:Nick(),
        enemyName = (data.enemyName and data.enemyName ~= "") and data.enemyName or "暂无对手",
        phase = "in",
        phaseStart = CurTime(),
        alpha = 0,
        slide = 0,
    }
end

--[[
    退场：对局结算广播瞬间调用（cl_battle_gameover.lua net.Receive("KardsGameOver")），
    头像与玩家名同时淡出（幂等）。
]]
function KARDS.PlayerPanelOutro()
    local pp = KARDS.PlayerPanel
    if not pp or pp.phase == "out" then return end
    pp.phase = "out"
    pp.phaseStart = CurTime()
end

--[[
    玩家名混合字体绘制：GMod surface 无富文本，按字节类型把名字切成「ASCII 段 / 非 ASCII
    段」，ASCII 段用 Dday、非 ASCII 段（中文等）用思源黑体 Heavy，逐段测量宽度并依次向右
    绘制。UTF-8 多字节字符的所有字节均 ≥ 128，故按「字节 < 128」分组必落在字符边界。
    @param text string 玩家名
    @param x number 文本左缘 x（随入场滑动动画变化）
    @param y number 文本垂直中心 y
    @param alpha number 透明度 0..255
]]
local function DrawMixedNameText(text, x, y, alpha)
    if alpha <= 0 or not text or text == "" then return end
    local cx, i, n = x, 1, #text
    while i <= n do
        local ascii = string.byte(text, i) < 128
        local j = i + 1
        while j <= n and (string.byte(text, j) < 128) == ascii do j = j + 1 end
        local run = string.sub(text, i, j - 1)
        local font = ascii and NAME_FONT_EN or NAME_FONT_ZH
        surface.SetFont(font)
        draw.SimpleText(run, font, cx, y, Color(255, 255, 255, alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        cx = cx + surface.GetTextSize(run)
        i = j
    end
end

-- ====================================================================
-- 状态推进（Think）：入场 / 退场缓动（smoothstep）推进整体透明度与名字滑动进度；
--   入场完成定格；退场完成移除面板并清空状态。
--   HUD 隐藏（cl_drawhud 0）时隐藏头像控件（vgui 面板不受 cl_drawhud 影响仍会绘制；
--   此时 HUDPaint 不执行，隐藏保持有效）。
-- ====================================================================
hook.Add("Think", "KardsPlayerPanelThink", function()
    local pp = KARDS.PlayerPanel
    if not pp then return end
    -- 面板有效性兜底：头像控件被外部移除 → 清理
    if not IsValid(pp.ownAvatar) or (pp.enemyAvatar ~= nil and not IsValid(pp.enemyAvatar)) then
        KARDS.PlayerPanelReset()
        return
    end
    local hudCvar = GetConVar("cl_drawhud")
    local hudOn = hudCvar and hudCvar:GetBool() or true
    if not hudOn then
        pp.ownAvatar:SetVisible(false)
        if IsValid(pp.enemyAvatar) then pp.enemyAvatar:SetVisible(false) end
        return
    end
    local dur = (pp.phase == "out") and OUTRO_DUR or INTRO_DUR
    local t = math.Clamp((CurTime() - pp.phaseStart) / dur, 0, 1)
    local e = t * t * (3 - 2 * t) -- smoothstep
    if pp.phase == "out" then
        pp.alpha = 1 - e
        pp.slide = 1
        if t >= 1 then KARDS.PlayerPanelReset() end
    else
        pp.alpha = e
        pp.slide = e
    end
end)

-- ====================================================================
-- 绘制（HUDPaint）：角落玩家头像（本方左下 / 敌方左上，位置取 CPAvatarRect）+
--   头像右侧玩家名（入场时自头像中心向右滑动到位并淡入）。
-- ====================================================================
hook.Add("HUDPaint", "KardsPlayerPanelHUD", function()
    local pp = KARDS.PlayerPanel
    local inT = KARDS.BattleState.inTable
    if not pp or not inT then return end
    local ownSlot = inT.slot
    local enemySlot = 3 - ownSlot
    local a = math.Clamp(math.Round(255 * (pp.alpha or 0)), 0, 255)
    for _, side in ipairs({ "own", "enemy" }) do
        local slot = (side == "own") and ownSlot or enemySlot
        local rect = KARDS.CPAvatarRect(slot)
        local av = (side == "own") and pp.ownAvatar or pp.enemyAvatar
        if IsValid(av) then
            av:SetVisible(true)
            av:SetSize(rect.w, rect.h)
            av:SetPos(rect.x, rect.y)
            av:SetAlpha(a)
        else
            -- 敌方缺失（虚拟对手）→ 白色矩形兜底（与头像同尺寸同位置）
            surface.SetDrawColor(255, 255, 255, a)
            surface.DrawRect(rect.x, rect.y, rect.w, rect.h)
        end
        -- 玩家名：入场时自头像中心向右滑动到头像右缘 + 间距（slide 0→1）
        local name = (side == "own") and pp.ownName or pp.enemyName
        local x0 = rect.x + rect.w / 2           -- 起点：头像中心
        local x1 = rect.x + rect.w + NAME_GAP    -- 终点：头像右缘 + 间距
        DrawMixedNameText(name, x0 + (x1 - x0) * (pp.slide or 1), rect.y + rect.h / 2, a)
    end
end)
