--[[
    Kards 战斗牌桌 - HUD 面板集合（2026-08-11 拆分 B1）

    从 cl_init.lua（lua/entities/sent_kards_battle_table/cl_init.lua）提取的「HUD 三件套」
    段落（规划 §5 B1 后半）：
      - 卡堆悬停信息面板（段落 #27）：鼠标悬停在任意一方卡堆上时，屏幕四角显示
        双方手牌数 / 卡组剩余数（Think「KardsDeckHoverDetect」检测 + HUDPaint
        「KardsDeckHoverInfo」绘制）
      - 结束回合按钮（段落 #4/#19）：屏幕右侧常驻按钮（Think「KardsEndTurnThink」
        悬停/点击 + HUDPaint「KardsEndTurnHUD」绘制），见本文件末尾
      - 手牌花费颜色（段落 #23）：友方回合且指挥点 ≥ 卡牌花费 → 3D2D 文字黄色，
        否则灰色（do..end 块 + Think「KardsHandCostColorThink」）

    段落自含状态保持本文件文件级 local / do..end 块内 local；共享状态走
    KARDS.BattleState（cl_battle_state.lua）。约定：本文件不新增 cl_init.lua 的
    main chunk 局部槽位压力。
]]

KARDS = KARDS or {}

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- ====================================================================
-- 卡组悬停信息面板（battle 模式）：鼠标悬停在任意一方卡堆上时，屏幕四角显示
-- 双方手牌数 / 卡组剩余数（数据源 = 服务端 SyncBattleCounts 写入的 NW 变量）：
--   我方手牌（屏幕底部偏右）/ 我方卡组剩余（右下角）
--   敌方手牌（屏幕顶部偏右）/ 敌方卡组剩余（左上角）
-- 悬停检测：卡堆 SOLID_NONE 无碰撞，射线不会命中实体——用 BattleCamera 当前视图
-- 射线到卡堆中心的最近距离判定（统一走 KARDS.HitTest，见 cl_hit_test.lua）。
-- 档位实体 6 档同位置（DeckSlotBase），每槽取任一实体位置即可。
-- 2026-08-11：整段（状态 + 函数 + 钩子）包入 do..end 块（迁移自 cl_init.lua 时的原样保留）
-- ——仅引用外层 KARDS.BattleState.inTable / KARDS.BattleState.battleStarted /
-- KARDS.HitTest，无本文件内跨段依赖。
-- ====================================================================
do
local hoverDeckSlot = nil -- 当前悬停的卡堆槽位（1/2；未悬停为 nil）
local seenSlots = {}      -- 每帧每槽只测一次的标记（复用，免每帧建表，2026-10-16 优化）
-- 悬停信息文本缓存（2026-10-16 性能优化）：数值未变时不再重复 format
local deckInfoCache = {
    myHand = -1, myDeck = -1, enHand = -1, enDeck = -1,
    myHandText = "", myDeckText = "", enHandText = "", enDeckText = "",
}
-- 语言切换：数值标记置 -1，强制下帧按新语言重新 format
KARDS.Lang.OnLanguageChanged(function()
    deckInfoCache.myHand = -1
    deckInfoCache.myDeck = -1
    deckInfoCache.enHand = -1
    deckInfoCache.enDeck = -1
end)
hook.Add("Think", "KardsDeckHoverDetect", function()
    hoverDeckSlot = nil
    if not KARDS.BattleState.inTable or not KARDS.BattleState.battleStarted then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    if gui.IsConsoleVisible() or gui.IsGameUIVisible() then return end
    -- 相机射线：统一走抗视差实现（KARDS.HitTest.MouseRay）
    local pos, dir = KARDS.HitTest.MouseRay()
    if not pos then return end
    local bestSlot, bestD = nil, KARDS.HitTest.Radii.DeckPile -- 阈值 14^2（卡堆 7.2×10.8 旋转 45°，中心点容差 14 单位）
    seenSlots[1], seenSlots[2] = false, false
    -- 共享每帧 PMX 列表（KARDS.GetPmxList，cl_init.lua）：同帧只做一次全量扫描
    for _, ent in ipairs(KARDS.GetPmxList()) do
        if IsValid(ent) and KARDS.HitTest.Filters.DeckPile(ent) then
            local slot = ent:GetNWInt("Kards_DeckSlot", 0)
            if slot >= 1 and slot <= 2 and not seenSlots[slot] then
                seenSlots[slot] = true -- 每槽只测一次（6 档实体同位置）
                local _, d = KARDS.HitTest.NearestInRay(pos, dir, { ent }, KARDS.HitTest.Radii.DeckPile)
                if d and d < bestD then
                    bestSlot, bestD = slot, d
                end
            end
        end
    end
    hoverDeckSlot = bestSlot
end)

-- 悬停信息标签：黑底半透明圆角 + 白色文字（halign/valign 定位锚点）
local function DrawDeckInfoLabel(text, x, y, halign, valign)
    surface.SetFont("SourceHan_Heavy_32")
    local tw, th = surface.GetTextSize(text)
    local bx = (halign == TEXT_ALIGN_CENTER) and (x - tw / 2 - 8)
        or (halign == TEXT_ALIGN_RIGHT and (x - tw - 16) or x)
    local by = (valign == TEXT_ALIGN_CENTER) and (y - th / 2 - 6)
        or (valign == TEXT_ALIGN_BOTTOM and (y - th - 12) or y)
    draw.RoundedBox(6, bx, by, tw + 16, th + 12, Color(0, 0, 0, 165))
    draw.SimpleText(text, "SourceHan_Heavy_32", x, y, Color(255, 255, 255), halign, valign)
end

-- 悬停任意一方卡堆：四角显示双方手牌 / 卡组剩余（我方 = 本地槽位，敌方 = 另一槽）
hook.Add("HUDPaint", "KardsDeckHoverInfo", function()
    if not hoverDeckSlot or not KARDS.BattleState.inTable or not KARDS.BattleState.battleStarted then return end
    local ent = KARDS.BattleState.inTable.ent
    if not IsValid(ent) then return end
    local mySlot = KARDS.BattleState.inTable.slot
    local enSlot = (mySlot == 1) and 2 or 1
    local myHand = ent:GetNWInt("Kards_HandCount_" .. mySlot, 0)
    local myDeck = ent:GetNWInt("Kards_DeckRemain_" .. mySlot, 0)
    local enHand = ent:GetNWInt("Kards_HandCount_" .. enSlot, 0)
    local enDeck = ent:GetNWInt("Kards_DeckRemain_" .. enSlot, 0)
    -- 数值变化时才重新 format（2026-10-16 性能优化），其余帧直接复用缓存文本
    if myHand ~= deckInfoCache.myHand then
        deckInfoCache.myHand = myHand
        deckInfoCache.myHandText = T("battle.deckinfo.my_hand", myHand)
    end
    if myDeck ~= deckInfoCache.myDeck then
        deckInfoCache.myDeck = myDeck
        deckInfoCache.myDeckText = T("battle.deckinfo.my_deck", myDeck)
    end
    if enHand ~= deckInfoCache.enHand then
        deckInfoCache.enHand = enHand
        deckInfoCache.enHandText = T("battle.deckinfo.enemy_hand", enHand)
    end
    if enDeck ~= deckInfoCache.enDeck then
        deckInfoCache.enDeck = enDeck
        deckInfoCache.enDeckText = T("battle.deckinfo.enemy_deck", enDeck)
    end
    -- 我方（底部）
    DrawDeckInfoLabel(deckInfoCache.myHandText, ScrW() * 0.78, ScrH() - 90,
        TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
    DrawDeckInfoLabel(deckInfoCache.myDeckText, ScrW() - 24, ScrH() - 46,
        TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
    -- 敌方（顶部）
    DrawDeckInfoLabel(deckInfoCache.enHandText, ScrW() * 0.78, 66,
        TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
    DrawDeckInfoLabel(deckInfoCache.enDeckText, 24, 66,
        TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end)
end

-- ====================================================================
-- 结束回合按钮（HUD，2026-08-10）：对战开始（开场动画结束）后屏幕右侧常驻。
--   KARDS.BattleState.battleTurn   = 当前回合槽位（服务端 KardsTurnUpdate 写入；
--                  KARDS.BattleState.battleTurn == KARDS.BattleState.inTable.slot = 友方回合）
--   KARDS.BattleState.endTurnRect  = 按钮矩形（Think 悬停/点击检测与 HUDPaint 绘制共用 EndTurnRect）
--   KARDS.BattleState.endTurnHover = 悬停渐变进度 0..1（友方回合悬停 白灰→黄，离开回退；
--                  敌方回合固定灰、不响应悬停）
-- 显示条件（KardsEndTurnVisible）：进入牌桌且对战已开始且开场动画结束
--（先手揭晓 KARDS.BattleState.reveal 与重新调度 KARDS.BattleState.mulligan 均结束；
-- 开场动画期间不绘制）。
-- 交互：Think 钩子 KardsEndTurnThink 检测左键上升沿点击 → 发 KardsEndTurn
--（服务端权威校验当前回合方后再切换）。
-- ====================================================================
-- 左键上一帧状态（上升沿点击检测用；文件级 local，reset 块经 KARDS.EndTurnReset 复位）
local prevEndTurnLeft = false
local ENDTURN_W, ENDTURN_H = 160, 52 -- 按钮尺寸（px）
local ENDTURN_PAD = 40 -- 距屏幕右边缘内边距（px）
local ENDTURN_HOVER_DUR = 0.15 -- 悬停渐入/离开渐变时长（秒）
-- 友方回合：白灰描边 + 悬停渐变黄色；敌方回合：灰色（不可点击）
local ENDTURN_COLOR_IDLE = Color(210, 210, 210)
local ENDTURN_COLOR_HOVER = Color(255, 210, 60)
local ENDTURN_COLOR_ENEMY = Color(130, 130, 130)
local endTurnColor = Color(255, 255, 255, 255) -- 悬停渐变色的复用对象（2026-10-16 性能优化）

-- 结束回合按钮矩形（屏幕右侧垂直居中）。矩形复用同一张表（2026-10-16 性能优化）：
-- Think / HUDPaint 每帧都会取值，坐标只随屏幕尺寸变化，就地更新即可免去每帧建表
local endTurnRect = { x = 0, y = 0, w = ENDTURN_W, h = ENDTURN_H }
local function EndTurnRect()
    endTurnRect.x = ScrW() - ENDTURN_W - ENDTURN_PAD
    endTurnRect.y = ScrH() / 2 - ENDTURN_H / 2
    return endTurnRect
end

-- 结束回合按钮可见条件：对战开始且开场动画（先手揭晓 + 重新调度）已结束，且非结算中
-- （2026-08-13：对局结算期间隐藏，见 cl_battle_gameover.lua）
local function KardsEndTurnVisible()
    return KARDS.BattleState.inTable ~= nil and KARDS.BattleState.battleStarted
        and KARDS.BattleState.reveal == nil and KARDS.BattleState.mulligan == nil
        and not KARDS.BattleState.gameOver
end

-- 结束回合按钮状态复位（退出牌桌 / 新对局 reset 块调用，原 cl_init.lua reset 块中
-- prevEndTurnLeft 的复位逻辑；endTurnRect/endTurnHover 为 KARDS.BattleState 共享状态，
-- 仍由 reset 块直接复位）
function KARDS.EndTurnReset()
    prevEndTurnLeft = false
end

-- ====================================================================
-- 结束回合按钮交互（每帧，见声明区「结束回合按钮」段）：
--   悬停渐变（仅友方回合：白灰→黄，离开回退；敌方回合固定灰不响应）+ 左键
--   上升沿点击按钮（仅友方回合可点）→ 发 KardsEndTurn（服务端权威校验后切换）。
--   开场动画期间（KardsEndTurnVisible 不满足）按钮不绘制也不响应。
-- ====================================================================
hook.Add("Think", "KardsEndTurnThink", function()
    if not KardsEndTurnVisible() then
        KARDS.BattleState.endTurnHover = 0
        KARDS.BattleState.endTurnRect = nil
        prevEndTurnLeft = false
        return
    end
    local rect = EndTurnRect()
    KARDS.BattleState.endTurnRect = rect
    local mx, my = gui.MouseX(), gui.MouseY()
    local hovered = mx >= rect.x and mx <= rect.x + rect.w
        and my >= rect.y and my <= rect.y + rect.h
    local mine = KARDS.BattleState.battleTurn == KARDS.BattleState.inTable.slot
    -- 悬停渐变进度（离开悬停 / 敌方回合 → 回退到 0）
    local target = (mine and hovered) and 1 or 0
    if KARDS.BattleState.endTurnHover < target then
        KARDS.BattleState.endTurnHover = math.min(KARDS.BattleState.endTurnHover + FrameTime() / ENDTURN_HOVER_DUR, 1)
    elseif KARDS.BattleState.endTurnHover > target then
        KARDS.BattleState.endTurnHover = math.max(KARDS.BattleState.endTurnHover - FrameTime() / ENDTURN_HOVER_DUR, 0)
    end
    -- 左键上升沿点击（仅友方回合可发起结束回合）
    local left = input.IsMouseDown(MOUSE_LEFT)
    if left and not prevEndTurnLeft and mine and hovered then
        KARDS.BattleState.endedTurn = true -- 结束回合：本回合不再拿起手牌（允许悬停）；对方回合开始广播回本方时复位
        KARDS.PlayKardsSound("endturn")
        net.Start("KardsEndTurn")
            net.WriteEntity(KARDS.BattleState.inTable.ent)
        net.SendToServer()
    end
    prevEndTurnLeft = left
end)

-- 结束回合按钮绘制（描边无填充矩形，屏幕右侧；见声明区「结束回合按钮」段）：
--   友方回合：白灰描边 + 文字，悬停渐变到黄色；敌方回合：灰色 + 文字「敌方」
hook.Add("HUDPaint", "KardsEndTurnHUD", function()
    if not KardsEndTurnVisible() then return end
    local rect = KARDS.BattleState.endTurnRect or EndTurnRect()
    local mine = KARDS.BattleState.battleTurn == KARDS.BattleState.inTable.slot
    local col, text
    if mine then
        local t = KARDS.BattleState.endTurnHover
        endTurnColor.r = math.floor(ENDTURN_COLOR_IDLE.r + (ENDTURN_COLOR_HOVER.r - ENDTURN_COLOR_IDLE.r) * t)
        endTurnColor.g = math.floor(ENDTURN_COLOR_IDLE.g + (ENDTURN_COLOR_HOVER.g - ENDTURN_COLOR_IDLE.g) * t)
        endTurnColor.b = math.floor(ENDTURN_COLOR_IDLE.b + (ENDTURN_COLOR_HOVER.b - ENDTURN_COLOR_IDLE.b) * t)
        col = endTurnColor
        text = T("battle.end_turn")
    else
        col = ENDTURN_COLOR_ENEMY
        text = T("battle.enemy")
    end
    -- 描边无填充：内外圈各 1px 组成 2px 边框
    surface.SetDrawColor(col)
    surface.DrawOutlinedRect(rect.x, rect.y, rect.w, rect.h)
    surface.DrawOutlinedRect(rect.x + 1, rect.y + 1, rect.w - 2, rect.h - 2)
    draw.SimpleText(text, "SourceHan_Heavy_32",
        rect.x + rect.w / 2, rect.y + rect.h / 2,
        col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

-- ====================================================================
-- 花费颜色（2026-08-15 阶段四 C8 合并）：手牌卡牌花费颜色
-- （KardsHandCostColorThink）与单位短卡行动花费颜色（KardsUnitActionCostColorThink）
-- 两个同构 Think 合并为 KardsCostColorThink——目标色比较 + 渐变应用收敛为共享工具
-- ApplyCostColor，两迭代骨架（真实手牌 / CardTextOverlay 单位注册表）保留各自判定。
-- 语义与两个独立 Think 等价（均每帧执行，守卫条件合并后行为不变）。
-- 动态颜色系统见 cl_card_text_overlay.lua。
-- ====================================================================
do
local CostColorPlayable = Color(255, 210, 60)  -- 黄色（可打出 / 可行动；与结束回合按钮悬停色一致）
local CostColorLocked = Color(130, 130, 130)   -- 灰色（不可打出 / 行动花费不足；与结束回合按钮敌方色一致）
local CostColorCounter = Color(0, 0, 0)        -- 纯黑（反制激活：花费文字转为黑字，衬黄色矩形，见 cl_card_text_overlay.lua DrawBlockCost）
local CostFadeDur = 0.25                       -- 颜色切换渐变时长（秒）
local costColorTarget = setmetatable({}, { __mode = "k" }) -- 每实体已应用的目标色（weak keys）

-- 目标色比较 + 渐变应用（两 Think 同构核心）：同色不重复设置，避免每帧重启渐变
local function ApplyCostColor(ent, target, key)
    local last = costColorTarget[ent]
    if not last or last.r ~= target.r or last.g ~= target.g or last.b ~= target.b or last.a ~= target.a then
        costColorTarget[ent] = target
        KARDS.CardTextOverlay:SetColor(ent, key, target, CostFadeDur)
    end
end

hook.Add("Think", "KardsCostColorThink", function()
    if not KARDS.BattleState.battleStarted or not KARDS.CardTextOverlay then return end
    -- 手牌卡牌花费：友方回合且本方指挥点 ≥ 该卡卡牌花费 → 黄色（可打出）；
    -- 否则（敌方回合 / 指挥点不足）→ 灰色。仅作用于本方手牌
    -- （KARDS.BattleState.realHandCards[本方槽]；对方/观战手牌卡背无文字叠加，不受影响）
    local slot = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot
    if slot then
        local mine = (KARDS.BattleState.battleTurn == slot)
        local pts = KARDS.BattleState.commandPoints[slot] or 0
        for ent in pairs(KARDS.BattleState.realHandCards[slot]) do
            if not IsValid(ent) then
                costColorTarget[ent] = nil
            else
                local target
                local cost = KARDS.CardTextOverlay:GetCardCost(ent)
                if KARDS.CardTextOverlay.CounterActive and KARDS.CardTextOverlay.CounterActive[ent] then
                    -- 反制激活（M3.4）：花费文字转纯黑，跳过黄 / 灰判定（黄矩形由 DrawBlockCost 绘制）
                    target = CostColorCounter
                elseif mine and cost ~= nil and pts >= cost then
                    target = CostColorPlayable
                else
                    target = CostColorLocked
                end
                ApplyCostColor(ent, target, "cost")
            end
        end
    end
    -- 单位短卡行动花费：小模型单位（basic_card_unit，战场 3D2D 单位模式 _unitMode）——
    -- 归属方当前指挥点 > 该单位行动花费 → 黄色（指挥点充足）；否则 → 灰色。
    -- 归属方取 entry.data.ownerSlot（KardsCardPlayed 注册叠加时写入，见 cl_init.lua）；
    -- 我方/敌方可见单位均按各自归属方指挥点判定（无回合限制，指挥点对时可见）
    if KARDS.BattleState.inTable then
        for ent, entry in pairs(KARDS.CardTextOverlay.Ents) do
            if not IsValid(ent) then
                costColorTarget[ent] = nil
            elseif entry.data and entry.data._unitMode then
                -- 归属方指挥点（entry.data.ownerSlot 缺失时按灰色处理）
                local pts = entry.data.ownerSlot and KARDS.BattleState.commandPoints[entry.data.ownerSlot] or nil
                local actionCost = KARDS.CardView.Read(ent).actionCost
                local target = (pts and pts >= actionCost) and CostColorPlayable or CostColorLocked
                ApplyCostColor(ent, target, "actionCost")
            end
        end
    end
end)
end

-- ====================================================================
-- 反制激活交互（反制系统 M3.2）：反制卡拖出手牌区外松手时切换激活 / 失活状态。
-- 本方客户端表现：卡牌先快后慢上浮 CounterRiseHeight、停留，再平滑还原手牌原位；
-- 提示「反制激活」/「反制失活」；花费文字转纯黑并衬黄色矩形（M3.3 / M3.4）。
-- 该表现仅本方客户端播放（信息隔离：敌方不可见激活动作），服务端以 KardsCounterActive
-- 回执校正乐观显示的状态。调用方见 cl_battle_drag.lua DragRelease（打出分支）。
-- ====================================================================
function KARDS.CounterClientToggle(ent)
    if not IsValid(ent) then return end
    local inTable = KARDS.BattleState.inTable
    if not inTable or not IsValid(inTable.ent) then return end
    local overlay = KARDS.CardTextOverlay
    if not overlay then return end
    local active = not overlay:IsCounterActive(ent) -- 翻转当前状态
    -- 状态视觉（乐观显示；服务端回执到达后以服务端为准）
    overlay:SetCounterActive(ent, active)
    -- 动画：上浮（先快后慢）→ 停留 → 平滑还原（回手牌原位）。起始姿态取卡牌当前
    -- 位置（拖出手牌区外松手处），终点为目标扇形位。
    local dc = KARDS.BattleState.dragCard
    local slot = dc and dc.slot or inTable.slot
    local idx = dc and dc.idx
    if slot and idx and KARDS.HandFanPos and KARDS.HandCount and KARDS.CounterRiseHeight then
        local handPos = KARDS.HandFanPos(slot, idx, KARDS.HandCount(slot))
        local start = ent:GetLocalPos()
        local risen = handPos + Vector(0, 0, KARDS.CounterRiseHeight)
        KARDS.AnimPlayer:Play(ent, {
            { t = 0.00, pos = start },
            { t = 0.15, pos = risen, easing = "easeOut" },  -- 先快后慢上升
            { t = 0.30, pos = risen, easing = "linear" },   -- 停在空中的 0.3 秒节点
            { t = 0.50, pos = handPos, easing = "smooth" }, -- 平滑还原回手牌原位
        }, { group = "counterToggle", noQueue = true })
    end
    -- 提示
    KARDS.BattleHint.Push(active and T("battle.counter.on") or T("battle.counter.off"))
    -- 网络：通知服务端切换（服务端权威处理扣费 / 返还 / 拦截注册 / 注销）
    net.Start("KardsCounterToggle")
        net.WriteEntity(inTable.ent)
        net.WriteEntity(ent)
        net.WriteBool(active)
    net.SendToServer()
end

-- 反制激活状态回执（M3.2）：服务端权威结果 → 校正乐观显示的状态
net.Receive("KardsCounterActive", function()
    local ent = net.ReadEntity()
    local cardEnt = net.ReadEntity()
    local active = net.ReadBool()
    if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent ~= ent then return end
    if not IsValid(cardEnt) or not KARDS.CardTextOverlay then return end
    KARDS.CardTextOverlay:SetCounterActive(cardEnt, active)
end)

-- ====================================================================
-- 友方回合开始提示（2026-10-17）
-- 触发：cl_init.lua 的 KardsTurnUpdate 接收器检测到回合方由敌方切回本方时
--       调用 KARDS.ShowFriendlyTurnHint(ent)。
-- 画面：textUnderground.png 横向渐变横幅 +「友方回合」文字，无独立图标。
-- 色调：文字 #C78736，即重新调度界面「确定」按钮按住时的文字色。
-- 时序：
--   0.00s  横幅线性淡入 0.25s；文字淡入并缩小（1.2→1.0，0.45s）
--   0.30s  文字动画进行到 2/3，屏幕震动（CalcView 叠加 0.35s）
--   1.05s  文字动画结束并停留 0.6s 后，横幅与文字一起淡出 0.30s
-- ====================================================================
do
local bgMat = Material("materials/kards/ui/textUnderground.png", "noclamp smooth")
local textColor = Color(199, 135, 54) -- #C78736：按住「确定」时的文字色

local IMG_FADE = 0.25     -- 横幅淡入时长
local TEXT_FADE = 0.45    -- 文字淡入 + 缩小总时长
local HOLD = 0.60         -- 文字动画结束后的停留时长
local FADE_OUT = 0.30     -- 横幅与文字一起淡出的时长
local SHAKE_AT = TEXT_FADE * 2 / 3 -- 文字动画 2/3 处触发震动
local SHAKE_AMP, SHAKE_DUR = 0.6, 0.35
local FONT_BASE = 60      -- 文字最终字号
local FONT_MIN, FONT_MAX, FONT_STEP = 60, 72, 4 -- 现成 SourceHan_Heavy 档位
local SCALE_FROM = 1.2    -- 文字缩小起点倍率
local TOTAL = TEXT_FADE + HOLD + FADE_OUT

-- 提示文本尺寸缓存（语言切换后文本变化会自然重建）
local sizeCache = {}

local function HintFont(size)
    return "SourceHan_Heavy_" .. size
end

local function MeasureHintText(text)
    local c = sizeCache[text]
    if c then return c.w, c.h end
    -- 按最大字号量横幅，保证缩小动画起始时文字不溢出横幅
    surface.SetFont(HintFont(FONT_MAX))
    local w, h = surface.GetTextSize(text)
    sizeCache[text] = { w = w, h = h }
    return w, h
end

-- 显示友方回合开始提示（重复调用以最新一次为准）
-- @param ent Entity 牌桌实体（离桌/换桌时据此丢弃提示）
function KARDS.ShowFriendlyTurnHint(ent)
    KARDS.BattleState.turnHint = {
        start = CurTime(),
        ent = ent,
        text = T("battle.turn.friendly"),
        shakeFired = false,
    }
end

hook.Add("HUDPaint", "KardsFriendlyTurnHint", function()
    local hint = KARDS.BattleState.turnHint
    if not hint then return end
    local inTable = KARDS.BattleState.inTable
    if not inTable or inTable.ent ~= hint.ent then
        KARDS.BattleState.turnHint = nil
        return
    end
    local now = CurTime()
    local t = now - hint.start
    if t >= TOTAL then
        KARDS.BattleState.turnHint = nil
        return
    end

    -- 文字动画 2/3 处触发屏幕震动（仅一次）
    if not hint.shakeFired and t >= SHAKE_AT then
        hint.shakeFired = true
        if KARDS.BattleCamera then
            KARDS.BattleCamera.Shake = { start = now, endT = now + SHAKE_DUR, amp = SHAKE_AMP }
        end
    end

    -- 横幅线性淡入；文字淡入并缩小（先快后慢）
    local imgAlpha = math.Clamp(t / IMG_FADE, 0, 1)
    local tp = math.Clamp(t / TEXT_FADE, 0, 1)
    local textAlpha = tp
    local ease = 1 - (1 - tp) * (1 - tp)
    local scale = SCALE_FROM + (1 - SCALE_FROM) * ease

    -- 文字动画结束并停留 0.6s 后，横幅与文字一起淡出
    local fadeStart = TEXT_FADE + HOLD
    if t > fadeStart then
        local outAlpha = 1 - (t - fadeStart) / FADE_OUT
        imgAlpha = imgAlpha * outAlpha
        textAlpha = textAlpha * outAlpha
    end

    local w, h = MeasureHintText(hint.text)
    local padX, padY = 40, 18
    local bw, bh = w + padX * 2, h + padY * 2
    local cx, cy = ScrW() / 2, ScrH() / 2

    surface.SetMaterial(bgMat)
    surface.SetDrawColor(255, 255, 255, math.floor(math.Clamp(imgAlpha, 0, 1) * 255))
    surface.DrawTexturedRect(cx - bw / 2, cy - bh / 2, bw, bh)

    -- 缩小以现成 60/64/68/72 四档字号近似，避免运行时新建字体
    local raw = FONT_BASE * scale
    local size = math.floor((raw + FONT_STEP / 2) / FONT_STEP) * FONT_STEP
    size = math.Clamp(size, FONT_MIN, FONT_MAX)
    draw.SimpleText(hint.text, HintFont(size), cx, cy,
        Color(textColor.r, textColor.g, textColor.b, math.floor(math.Clamp(textAlpha, 0, 1) * 255)),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
end
