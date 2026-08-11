--[[
    Kards 战斗牌桌 - 指挥点 HUD 面板（2026-08-11 拆分 B1）

    从 cl_init.lua（lua/entities/sent_kards_battle_table/cl_init.lua）提取的「指挥点 HUD」
    段（原段落编号 #3 状态/常量 + #24 Think 推进，规划 §5 B1 首项）：
      - 段落自含状态：commandSlots / cpPanelVisible / displayCP / displayCS / cpScroll /
        cpBorder 与 CP_* 常量（原为 cl_init.lua main chunk 顶层 local，占用 200 局部变量槽，
        现为本文件文件级 local，不再占用 cl_init.lua 槽位）
      - 共享状态：KARDS.BattleState.commandPoints / inTable / battleStarted
        （cl_battle_state.lua）
      - 常驻钩子：Think「KardsCommandPointsHUDThink」（数字滚动 + 描边颜色动画推进）、
        HUDPaint「KardsCommandPointsHUD」（左下角友方 / 左上角敌方面板绘制）
      - net 接收器：KardsCommandPoints（服务端 BroadcastCommandPoints，见
        table_session.lua；载荷 = 牌桌 + P1/P2 点数 + P1/P2 槽数，各 16 位）
      - 导出：KARDS.CommandPointsReset()（退出牌桌 / 新对局 reset 块调用）、
        KARDS.CommandPointsApplyBroadcast(p1,p2,s1,s2)（net 接收器主体）

    约定：本文件不新增 cl_init.lua 的 main chunk 局部槽位压力；段落自含状态保持本文件
    文件级 local，共享状态走 KARDS.BattleState（见 cl_battle_state.lua 头注释迁移原则）。
]]

KARDS = KARDS or {}

-- ====================================================================
-- 指挥点 HUD 面板（2026-08-10）：对战开始后左下角（友方）/左上角（敌方）常驻，2026-08-11 起均向屏幕 y 中线平移 CP_MID_SHIFT。
--   面板结构：非软边正方形底（#101010 填充 + #B9B7AD 描边），左半点数大文字
--   （#CC8027），右半分数——分割线上方 K（#CC8027）、下方槽数（#7D7D7D）。
--   动画（点数或槽数变化触发）：数字平滑滚动（十位数缩小字体）+ 矩形描边颜色
--   动画——滚动开始时描边淡入渐变到 #CC8027，滚动结束后淡出渐变回 #B9B7AD。
--   数据源：KARDS.BattleState.commandPoints / commandSlots（服务端 KardsCommandPoints 广播，
--   载荷 = 牌桌 + P1/P2 点数 + P1/P2 槽数，见 table_session.lua BroadcastCommandPoints）。
--   状态推进在 Think 钩子 KardsCommandPointsHUDThink，绘制在 HUDPaint 钩子
--   KardsCommandPointsHUD（见本文件对应章节）。
-- ====================================================================
local commandSlots = { [1] = 0, [2] = 0 } -- 双方指挥点槽数（广播第 3/4 个 16 位）
local cpPanelVisible = false -- HUD 指挥点面板显示开关：首个非 0 指挥点广播（StartFirstTurn
                             -- 广播先手 1 点）置位；开场动画开始前/中（广播恒 0）不显示面板，
                             -- 2026-08-11（动画时双方都不应有指挥点（槽））
local displayCP = { [1] = 0, [2] = 0 }     -- 点数滚动显示值（浮点，绘制时取整）
local displayCS = { [1] = 0, [2] = 0 }     -- 槽数滚动显示值（浮点，绘制时取整）
local cpScroll = {}  -- 滚动动画 { [slot] = { points = {from,target,start,dur}?, slots = {...}? } }
local cpBorder = {}  -- 描边动画 { [slot] = { phase="in"/"out", from, to, start, dur, cur } }
local CP_BORDER_IDLE = Color(185, 183, 173) -- #B9B7AD 默认描边
local CP_BORDER_HOT  = Color(204, 128, 39)  -- #CC8027 高亮描边
local CP_FILL        = Color(16, 16, 16)     -- #101010 底填充
local CP_NUM_COLOR   = Color(204, 128, 39)   -- #CC8027 点数 / K 文字
local CP_SLOT_COLOR  = Color(125, 125, 125)  -- #7D7D7D 槽数文字与分割线
local CP_W, CP_H = 50, 50                    -- 面板尺寸（px，正方形底；面积=150×150 的 1/3）
local CP_PAD, CP_MID_SHIFT = 40, 40          -- 距屏幕边缘内边距（px）/ 向 y 中线平移距离（px，2026-08-11，可调）
local CP_SCROLL_DUR = 0.3                    -- 数字滚动时长（秒，点数滚动固定）
-- 槽数滚动时长按变动值线性增长（变动值越大时长越久，2026-08-10）：基准 + 每单位
-- 变动额外时长，封顶防过大；曲线 easeInCubic（先慢后快，与点数 easeOutCubic 相对）
local CP_SLOTS_DUR_BASE = 0.25               -- 槽数变动 1 的基准时长（秒）
local CP_SLOTS_DUR_PER = 0.08                -- 每增加 1 变动值额外增加的时长（秒）
local CP_SLOTS_DUR_MAX = 1.0                 -- 槽数滚动时长上限（秒）
local function CPSlotsDur(delta)
    return math.min(CP_SLOTS_DUR_MAX, CP_SLOTS_DUR_BASE + math.max(0, delta) * CP_SLOTS_DUR_PER)
end
local CP_BORDER_IN_DUR = 0.15                -- 描边淡入（与滚动开始同步）
local CP_BORDER_OUT_DUR = 0.3                -- 描边淡出（滚动结束后）

-- 指挥点面板工具函数（HUDPaint 绘制 / Think 推进共用）：

-- 颜色线性插值（t 0..1）
local function CPLerp(t, a, b)
    return Color(
        math.floor(a.r + (b.r - a.r) * t),
        math.floor(a.g + (b.g - a.g) * t),
        math.floor(a.b + (b.b - a.b) * t),
        math.floor(a.a + (b.a - a.a) * t))
end

-- 点数大数字字体：十位数（≥10）缩小字体
local function CPPointsFont(v)
    return v >= 10 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
end

-- 槽数小数字字体：十位数（≥10）缩小字体
local function CPSlotsFont(v)
    return v >= 10 and "SourceHan_Heavy_24" or "SourceHan_Heavy_28"
end

-- 面板矩形：数据槽位 slot（1/2）→ 屏幕位置（友方 = 左下角向中线平移，敌方 = 左上角向中线平移）。
-- 仅在 HUDPaint 内计算（ScrH() 此时有效；Think 不依赖矩形坐标）。
local function CPPanelRect(slot)
    local x = CP_PAD
    local y = (slot == KARDS.BattleState.inTable.slot)
        and (ScrH() - CP_PAD - CP_H - CP_MID_SHIFT) -- 友方：底部上移（向中线）
        or  (CP_PAD + CP_MID_SHIFT)                 -- 敌方：顶部下移（向中线）
    return { x = x, y = y, w = CP_W, h = CP_H }
end

-- 指挥点复位（退出牌桌 / 新对局 reset 块调用，原 cl_init.lua reset 块中
-- commandSlots/displayCP/displayCS/cpScroll/cpBorder/cpPanelVisible 的复位逻辑）
function KARDS.CommandPointsReset()
    commandSlots[1], commandSlots[2] = 0, 0
    displayCP[1], displayCP[2] = 0, 0
    displayCS[1], displayCS[2] = 0, 0
    cpScroll, cpBorder = {}, {}
    cpPanelVisible = false -- 面板显示开关复位（首个非 0 指挥点广播重新置位）
end

-- 指挥点广播落地（net 接收器主体）：写入双方点数/槽数；首个非 0 广播置位面板显示
-- @param p1, p2 number P1/P2 点数
-- @param s1, s2 number P1/P2 槽数
function KARDS.CommandPointsApplyBroadcast(p1, p2, s1, s2)
    KARDS.BattleState.commandPoints[1] = p1
    KARDS.BattleState.commandPoints[2] = p2
    commandSlots[1] = s1
    commandSlots[2] = s2
    -- 首个非 0 广播（StartFirstTurn 广播先手 1 点）：开场动画结束、先手回合开始，
    -- 面板自此显示（动画前/中广播恒 0 面板隐藏，2026-08-11）
    if p1 > 0 or p2 > 0 then cpPanelVisible = true end
end

-- 指挥点广播（服务端 BroadcastCommandPoints，对战开始首回合 / 结束回合 / 打出支付后）：
-- 载荷 = 牌桌 + P1/P2 点数 + P1/P2 槽数（各 16 位）。点数驱动本方手牌卡牌花费 3D2D 文字
-- 颜色（友方回合且指挥点 ≥ 卡牌花费 → 黄色，否则灰色，见 cl_battle_hud.lua
-- KardsHandCostColorThink）；点数/槽数共同驱动本面板动画（KardsCommandPointsHUDThink /
-- KardsCommandPointsHUD，见本文件下方章节）。
net.Receive("KardsCommandPoints", function()
    local ent = net.ReadEntity()
    local p1 = net.ReadUInt(16)
    local p2 = net.ReadUInt(16)
    local s1 = net.ReadUInt(16)
    local s2 = net.ReadUInt(16)
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then
        KARDS.CommandPointsApplyBroadcast(p1, p2, s1, s2)
    end
end)

-- ====================================================================
-- 指挥点 HUD 面板动画驱动（2026-08-10，Think）：推进数字滚动与矩形描边颜色动画。
--   变化检测：KARDS.BattleState.commandPoints / commandSlots（广播目标值）与当前显示目标不一致 →
--   启动对应数字滚动（from = 当前显示值, target = 新值）；点数固定时长
--   CP_SCROLL_DUR，槽数时长按变动值线性增长 CPSlotsDur；曲线统一 easeInCubic
--   （慢后快，2026-08-11 起点数/槽数均为 y 滚动卷帘，见 KardsCommandPointsHUD
--   CPCycleBand）；同时触发描边淡入渐变到 #CC8027；点数与槽数滚动全部结束后
--   描边淡出回 #B9B7AD。本钩子推进的 displayCP/displayCS 仅作为「当前真实值」
--   基准（新滚动 from 的起点），视觉中间帧由绘制端数字带实时计算。
--   绘制见 KardsCommandPointsHUD（HUDPaint）。仅对局内推进；离开对局清空防残留。
-- ====================================================================
hook.Add("Think", "KardsCommandPointsHUDThink", function()
    if not KARDS.BattleState.inTable or not KARDS.BattleState.battleStarted then
        cpScroll, cpBorder = {}, {}
        return
    end
    local now = CurTime()
    for slot = 1, 2 do
        -- 1. 变化检测（显示目标 = 进行中滚动 target，无滚动则当前显示值）
        local anim = cpScroll[slot]
        local curPointsTarget = (anim and anim.points and anim.points.target) or displayCP[slot]
        local curSlotsTarget = (anim and anim.slots and anim.slots.target) or displayCS[slot]
        local changed = false
        if KARDS.BattleState.commandPoints[slot] ~= curPointsTarget then
            if not anim then anim = {} end
            anim.points = { from = displayCP[slot], target = KARDS.BattleState.commandPoints[slot], start = now, dur = CP_SCROLL_DUR }
            changed = true
        end
        if commandSlots[slot] ~= curSlotsTarget then
            if not anim then anim = {} end
            -- 槽数滚动时长按变动值确定（CPSlotsDur：变动值越大时长越久）
            anim.slots = { from = displayCS[slot], target = commandSlots[slot], start = now,
                dur = CPSlotsDur(math.abs(commandSlots[slot] - displayCS[slot])) }
            changed = true
        end
        if anim then cpScroll[slot] = anim end

        -- 2. 变化触发描边淡入（该槽尚无描边动画时）
        if changed and not cpBorder[slot] then
            cpBorder[slot] = { phase = "in", from = CP_BORDER_IDLE, to = CP_BORDER_HOT,
                start = now, dur = CP_BORDER_IN_DUR, cur = CP_BORDER_IDLE }
        end

        -- 3. 滚动推进（点数 / 槽数各自独立；结束定格目标值并移除）
        local ap = anim and anim.points
        if ap then
            local t = (now - ap.start) / ap.dur
            if t >= 1 then
                displayCP[slot] = ap.target
                anim.points = nil
            else
                local e = t ^ 3 -- 慢后快（与绘制卷帘 easeInCubic 一致，2026-08-11）
                displayCP[slot] = ap.from + (ap.target - ap.from) * e
            end
        end
        local as = anim and anim.slots
        if as then
            local t = (now - as.start) / as.dur
            if t >= 1 then
                displayCS[slot] = as.target
                anim.slots = nil
            else
                local e = t ^ 3 -- easeInCubic（先慢后快，2026-08-10 槽数滚动）
                displayCS[slot] = as.from + (as.target - as.from) * e
            end
        end
        -- 无进行中滚动：移除空动画表
        if anim and not anim.points and not anim.slots then
            cpScroll[slot] = nil
        end

        -- 4. 描边推进：淡入完成定格高亮色；点数与槽数滚动全部结束 → 淡出回默认色
        local bd = cpBorder[slot]
        if bd then
            local t = (now - bd.start) / bd.dur
            if t >= 1 then
                bd.cur = bd.to
                if bd.phase == "out" then
                    cpBorder[slot] = nil -- 淡出完成：恢复默认描边
                else
                    bd.phase = "hold" -- 淡入完成：停留高亮，等待滚动全部结束
                end
            else
                bd.cur = CPLerp(t, bd.from, bd.to)
            end
            if bd.phase ~= "out" and not cpScroll[slot] then
                bd.phase = "out"
                bd.from = bd.cur
                bd.to = CP_BORDER_IDLE
                bd.start = now
                bd.dur = CP_BORDER_OUT_DUR
            end
        end
    end
end)

-- ====================================================================
-- 指挥点 HUD 面板绘制（2026-08-10，HUDPaint）：左下角友方 / 左上角敌方（均向 y 中线平移）。
--   非软边正方形底：#101010 填充 + #B9B7AD 描边（指挥点/槽数变化时描边渐变为
--   #CC8027，滚动结束后淡出恢复，见 KardsCommandPointsHUDThink）；
--   左半点数大文字（#CC8027，十位数缩小字体）；右半分数——分割线上方
--   K（#CC8027）、下方槽数（#7D7D7D）。
--   数字 y 滚动（2026-08-11）：点数/槽数变化时以垂直数字带卷帘滚动——数字带
--   0~24 从下到上递增排列（数字越大越靠下），窗口固定于数字位置，带子整体
--   向下移动（easeInCubic 慢后快），窗口依次显示 from→target。点数裁剪在面板
--   正方形内；槽数裁剪在以槽数几何中心为中心、边长=分割线长度（rw-8）的正方形内。
-- ====================================================================

-- 指挥点 y 滚动数字带绘制（2026-08-11）：预置 0~24 数字带（数字 i 的屏幕 y =
-- cy + (i - v) * h，v = from + (target-from)*e 为窗口当前显示值；数字越大越靠下，
-- 即带子从下到上递增，与用户要求「从0到2 → 2、1、0 从下到上、带子下移」一致），
-- 每格高度 h = 字体高度 + 间距；仅绘制窗口附近可见数字（其余被调用方裁剪区切除）。
-- 由调用方先 render.SetScissorRect 设置裁剪区，本函数结束后保持裁剪状态。
-- @param cx, cy number 窗口中心（数字显示位置）
-- @param font string 数字字体（滚动带内统一，取 from/target 较大者的字体）
-- @param from, target number 起始/目标值（整数，0~24）
-- @param e number 滚动进度 0..1（easeInCubic 已应用）
-- @param color Color 数字颜色
local function CPCycleBand(cx, cy, font, from, target, e, color)
    local h = (draw.GetFontHeight and draw.GetFontHeight(font)) or 48
    h = h + 2 -- 数字带相邻间距（视觉分离，卷帘连续）
    local v = from + (target - from) * e
    local first = math.max(0, math.floor(v) - 1)
    local last = math.min(24, math.ceil(v) + 1)
    for i = first, last do
        draw.SimpleText(tostring(i), font, cx, cy + (i - v) * h,
            color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

hook.Add("HUDPaint", "KardsCommandPointsHUD", function()
    -- cpPanelVisible：开场动画开始前/中不显示面板（广播恒 0），先手回合开始
    --（首个非 0 广播）才显示，2026-08-11
    if not KARDS.BattleState.inTable or not KARDS.BattleState.battleStarted or not cpPanelVisible then return end
    local now = CurTime()
    -- 友方 = 本方槽位（左下角向中线），敌方 = 另一槽位（左上角向中线）
    for _, slot in ipairs({ KARDS.BattleState.inTable.slot, 3 - KARDS.BattleState.inTable.slot }) do
        local rect = CPPanelRect(slot)
        local borderCol = cpBorder[slot] and cpBorder[slot].cur or CP_BORDER_IDLE
        local points = math.floor(displayCP[slot])
        local slots = math.floor(displayCS[slot])
        -- 底填充（非软边正方形）
        surface.SetDrawColor(CP_FILL)
        surface.DrawRect(rect.x, rect.y, rect.w, rect.h)
        -- 描边：内外圈各 1px 合成 2px 边框（同结束回合按钮）
        surface.SetDrawColor(borderCol)
        surface.DrawOutlinedRect(rect.x, rect.y, rect.w, rect.h)
        surface.DrawOutlinedRect(rect.x + 1, rect.y + 1, rect.w - 2, rect.h - 2)

        -- 左半点数：裁剪在面板正方形内，滚动中画数字带、静止画当前值
        local px = rect.x + rect.w * 0.275
        local py = rect.y + rect.h / 2
        local ap = cpScroll[slot] and cpScroll[slot].points
        render.SetScissorRect(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, true)
        if ap then
            local t = math.min((now - ap.start) / ap.dur, 1)
            CPCycleBand(px, py, CPPointsFont(math.max(ap.from, ap.target)),
                ap.from, ap.target, t ^ 3, CP_NUM_COLOR)
        else
            draw.SimpleText(tostring(points), CPPointsFont(points),
                px, py, CP_NUM_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        render.SetScissorRect(0, 0, 0, 0, false)

        -- 右半分数：K + 分割线 + 槽数
        local rx = rect.x + rect.w * 0.55 -- 右半区起点
        local rw = rect.x + rect.w - rx    -- 右半区宽度
        draw.SimpleText("K", "SourceHan_Heavy_24",
            rx + rw / 2, rect.y + rect.h * 0.26,
            CP_NUM_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        surface.SetDrawColor(CP_SLOT_COLOR)
        surface.DrawRect(rx + 4, rect.y + rect.h * 0.5, rw - 8, 2) -- 分割线（2px 加粗）

        -- 槽数：裁剪在以槽数几何中心为中心、边长=分割线长度（rw-8）的正方形内
        --（2026-08-11 用户要求：指挥点槽只能在该正方形内显示）
        local sx = rx + rw / 2
        local sy = rect.y + rect.h * 0.76
        local side = rw - 8
        local clipX, clipY = math.floor(sx - side / 2), math.floor(sy - side / 2)
        render.SetScissorRect(clipX, clipY, clipX + math.max(1, math.floor(side)),
            clipY + math.max(1, math.floor(side)), true)
        local as = cpScroll[slot] and cpScroll[slot].slots
        if as then
            local t = math.min((now - as.start) / as.dur, 1)
            CPCycleBand(sx, sy, CPSlotsFont(math.max(as.from, as.target)),
                as.from, as.target, t ^ 3, CP_SLOT_COLOR)
        else
            draw.SimpleText(tostring(slots), CPSlotsFont(slots),
                sx, sy, CP_SLOT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        render.SetScissorRect(0, 0, 0, 0, false)
    end
end)
