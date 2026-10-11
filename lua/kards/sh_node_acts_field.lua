--[[
    节点解析系统：场域语义动作执行器（action / card / command / extract / headquarter / loop / property）

    自 sh_node_parser.lua 按职责拆分（re.md B-H3）：本文件承载「场域」模板的执行器表。
    各表在文件末尾合并 handlers 进 BaseSemantics 对应条目，
    ExecuteBaseNode（sh_node_parser.lua）经 sem.handlers 分派（行为与原 if/elseif 链一致）。

    跨文件共享（GLua 无跨文件 local）：ReadSlot / EnemyOf 由 sh_node_parser.lua 暴露，
    本文件开头取本地引用；CARD_TYPE_MAP / TakeDeckCards / CloneCard / ResolveCount 为
    card 模板专用，随本文件迁移为文件私有 local。

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_node_semantics.lua 之后）
]]

KARDS = KARDS or {}
KARDS.NodeParser = KARDS.NodeParser or {}

-- 跨文件共享（GLua 无跨文件 local）：主文件（sh_node_parser.lua）已暴露，本文件取本地引用
local ReadSlot = KARDS.NodeParser.ReadSlot
local EnemyOf = KARDS.NodeParser.EnemyOf
local ResolveObjectSlot = KARDS.NodeParser.ResolveObjectSlot -- 对象槽统一解析为对象列表（含数据线连接的对象，2026-08-14 正序逐张语义）

-- 过滤在场的隐蔽单位（非自身）：与 ExecuteBaseNode 对 targets 的统一过滤同规则
-- （2026-08-14：对象槽逐张语义与数据线统一——任何节点效果无法作用到隐蔽的非自身单位；
--   隐蔽状态仅在场单位部署时置位，故不再另查在场）
-- @param ctx     table 执行上下文（含 tableID）
-- @param objects table 正序对象列表
-- @param card    table|nil 效果发起卡牌句柄（自身豁免）
-- @return table 过滤后的对象列表
local function FilterHiddenOnField(ctx, objects, card)
    local st = KARDS.Battle and KARDS.Battle.KeywordStates
        and KARDS.Battle.KeywordStates[ctx.tableID]
    if not st then return objects end
    local out = {}
    for _, o in ipairs(objects) do
        if not (KARDS.KeywordStates.Hidden.Is(st, o) and o ~= card) then
            out[#out + 1] = o
        end
    end
    return out
end

-- 双对象组正序笛卡尔积执行：A 外层 × B 内层，按 (a1b1, a1b2, ..., a2b1, ...) 顺序
-- （如 ab 与 cd 战斗 → ac, ad, bc, bd）；对每对调 fn(a, b)，任一成功置 ok
-- @param listA table 发起方对象列表（正序）
-- @param listB table 目标方对象列表（正序）
-- @param fn    function 单对执行函数（返回 boolean 是否成功）
-- @return boolean 是否有任一对执行成功
local function ForEachPair(listA, listB, fn)
    local ok = false
    for _, a in ipairs(listA) do
        for _, b in ipairs(listB) do
            if fn(a, b) then ok = true end
        end
    end
    return ok
end

-- 前线占领被拒（2026-09-26 缺口 F）：效果拉入前线软失败时广播提示事件，
-- 实体层订阅 FrontlineDenied 后向发起方下发「前线已被敌方占领」提示。
-- @param ctx  table 执行上下文
-- @param card table 效果发起卡牌句柄（发起方槽位取其 GetOwner）
local function FireFrontlineDenied(ctx, card)
    local owner = (card and card.GetOwner) and card:GetOwner() or nil
    KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.FrontlineDenied,
        { player = owner })
end

-- 加入阵线事件（2026-09-26 缺口 F）：逐卡触发，实体层订阅后广播加入动画。
-- 来源是否手牌由实体层经 deck.cardEnt[card] 判定，据此选播手牌下落 / 屏右入场。
-- @param ctx  table 执行上下文
-- @param card table 成功加入阵线的卡牌句柄
local function FireJoinField(ctx, card)
    if not card then return end
    local owner = (card.GetOwner and card:GetOwner()) or nil
    KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.JoinField,
        { player = owner, cards = { card } })
end

-- 单位动作事件（2026-09-26 缺口 G）：一对攻击方与目标方触发攻击冲刺动画广播。
-- 手动路径（点击交战 / 攻击总部）由实体层直接调广播函数，效果路径（节点「交战」「战斗」）
-- 经本事件桥接到同一个广播函数，两条路径表现一致。逐对触发（一对一次动画）。
-- @param ctx table 执行上下文
-- @param src table 攻击方卡牌句柄
-- @param dst table 目标方卡牌句柄
local function FireUnitAction(ctx, src, dst)
    if not src or not dst then return end
    KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.UnitAction,
        { attacker = src, target = dst })
end

-- 手牌回收（2026-09-26 缺口 F）：目标卡在该玩家手牌数组中则移除。
-- 用于「加入战场 / 加入前线」的效果拉入场——手牌来源的卡先离手牌再入场。
-- @param ctx    table 执行上下文
-- @param player string 玩家标识
-- @param card   table 卡牌句柄
-- @return boolean 是否为手牌来源（已移除）
local function RemoveFromHandIfPresent(ctx, player, card)
    if not player or not card then return false end
    local hand = KARDS.Deck:GetHand(ctx.tableID, player)
    if not hand then return false end
    for i = 1, #hand do
        if hand[i] == card then
            table.remove(hand, i)
            return true
        end
    end
    return false
end

-- ====================================================================
-- 语义动作执行器（action 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, targets, item, node)
--   ctx     执行上下文（含 tableID / _T）
--   card    效果发起卡牌句柄（指令卡）
--   targets 受影响卡牌列表（action 模板的 e 输入对象槽）
--   item    语义项（含 act / target / amount 等组件 ID）
--   node    节点实例（经 ReadSlot 读取对象槽卡牌句柄）
local ActionActs = {
    -- 撤退（readme 7.1）：前线单位退回本方支援阵线
    retreat = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimRetreat(t) then ok = true end
        end
        return ok
    end,
    -- 移动(到前线)
    moveToFront = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimMoveToFrontline(t) then
                ok = true
                -- 音效（2026-09-26 缺口 H）：与手动路径 OnUnitMoveFront 一致，移动成功后补播部署音效
                KARDS.Battle:NotifyEventSound(ctx.tableID, "deploy", t)
            end
        end
        return ok
    end,
    -- 交战（与对象槽单位交战；对象槽/数据线统一正序逐张：发起方组 × 目标对象槽组笛卡尔积）
    engage = function(ctx, card, targets, item, node)
        local srcs = targets or {} -- e 输入对象组（ExecuteBaseNode 已过滤隐蔽非自身）
        local dsts = FilterHiddenOnField(ctx, ResolveObjectSlot(ctx, node, item.target), card)
        return ForEachPair(srcs, dsts, function(src, dst)
            -- SimEngage 首返回值为「是否造成伤害」（零伤害时为 false 但交战已成立），
            -- 故用第二返回值 reason 判定前置检查是否通过（非 nil 即交战未成立）
            local res, reason = KARDS.Battle:SimEngage(src, dst)
            if reason == nil then FireUnitAction(ctx, src, dst) end
            return res
        end)
    end,
    -- 战斗（与对象槽单位互扣；对象槽/数据线统一正序逐张：发起方组 × 目标对象槽组笛卡尔积）
    fight = function(ctx, card, targets, item, node)
        local as = targets or {}
        local bs = FilterHiddenOnField(ctx, ResolveObjectSlot(ctx, node, item.target), card)
        return ForEachPair(as, bs, function(a, b)
            local res = KARDS.Battle:SimFight(a, b)
            if res then FireUnitAction(ctx, a, b) end
            return res
        end)
    end,
    -- 加入战场（效果拉入场：支援阵线首个空槽）
    joinBattlefield = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimJoinBattlefield(t) then
                ok = true
                -- 手牌来源回收（2026-09-26 缺口 F）：加入成功后再离手牌（失败则手牌原状），
                -- 计数变更事件照常触发以同步手牌数
                local owner = (t.GetOwner and t:GetOwner()) or nil
                if RemoveFromHandIfPresent(ctx, owner, t) then
                    KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.CountsChanged,
                        { player = owner })
                end
                FireJoinField(ctx, t) -- 加入动画分流（与既有部署动画分离）
            end
        end
        return ok
    end,
    -- 加入前线（效果直接加入前线；前线被敌方占领 → 软失败并向发起方提示）
    joinFrontline = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            local okOne, reason = KARDS.Battle:SimJoinFrontline(t)
            if okOne then
                ok = true
                local owner = (t.GetOwner and t:GetOwner()) or nil
                if RemoveFromHandIfPresent(ctx, owner, t) then
                    KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.CountsChanged,
                        { player = owner })
                end
                FireJoinField(ctx, t)
            elseif reason == "前线已被敌方占领" then
                FireFrontlineDenied(ctx, card)
            end
        end
        return ok
    end,
    -- 压制（readme 7.2.1）：被压制不能移动/攻击
    suppress = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimSuppress(t) then ok = true end
        end
        return ok
    end,
    -- 抑制（readme 7.2.1）：失去所有关键词和效果
    neutralize = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimInhibit(t) then ok = true end
        end
        return ok
    end,
    -- 转换（整体换卡，2026-09-26 缺口 J）：目标卡取卡牌自带「转换目标卡」字段（convertTarget），
    -- 未配置时保持原类型不变，仅记录 convert 刻（既有行为）
    convert = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            local convertTo = (t.GetConvertTarget and t:GetConvertTarget()) or nil
            if KARDS.Battle:SimConvert(t, convertTo) then ok = true end
        end
        return ok
    end,
    -- 修复（恢复 1 防御）
    repair = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimRepair(t, 1) then ok = true end
        end
        return ok
    end,
    -- 控制（转移归属到发起者）
    control = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimControl(t, card:GetOwner()) then ok = true end
        end
        return ok
    end,
    -- 免疫（readme 7.2.1）：免疫单位不受伤
    immune = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimImmune(t) then ok = true end
        end
        return ok
    end,
    -- 情报（readme 7.2.2）：显示敌方 X 张手牌（X = [lib] 槽值；未设置/0 时回退目标词条数值，最多 9）
    intelligence = function(ctx, card, targets, item, node)
        local ok = false
        local amount = tonumber(ReadSlot(node, item.amount)) or 0
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimUseIntel(t, amount) then ok = true end
        end
        return ok
    end,
    -- 造成伤害（amount 为数字槽值）
    dealDamage = function(ctx, card, targets, item, node)
        local amount = tonumber(ReadSlot(node, item.amount)) or 0
        if amount <= 0 then return false end
        for _, t in ipairs(targets) do
            KARDS.Battle:SimDealDamage(card, t, amount)
        end
        return #targets > 0
    end,
    -- 触发关键字效果（target 对象槽 + keyword 关键字槽；对象槽选对象组时正序逐张触发）
    triggerKeyword = function(ctx, card, targets, item, node)
        local kw = ReadSlot(node, item.keyword)
        if not kw then return false end
        local dsts = FilterHiddenOnField(ctx, ResolveObjectSlot(ctx, node, item.target), card)
        local ok = false
        for _, dst in ipairs(dsts) do
            if KARDS.Battle:SimTriggerKeyword(card, dst, tostring(kw)) then ok = true end
        end
        return ok
    end,
    -- 返回手牌（从场上回所有者手牌）
    returnToHand = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimReturnToHand(t) then ok = true end
        end
        return ok
    end,
    -- 召唤单位（unit 对象槽 + zone 选项：1=支援阵线 2=前线；对象槽选对象组时正序逐张召唤）
    summonUnit = function(ctx, card, targets, item, node)
        local zone = ReadSlot(node, item.zone) or 1
        local units = FilterHiddenOnField(ctx, ResolveObjectSlot(ctx, node, item.unit), card)
        local ok = false
        for _, u in ipairs(units) do
            local okOne, reason = KARDS.Battle:SimSummonUnit(card:GetOwner(), u, zone)
            if okOne then
                ok = true
                FireJoinField(ctx, u) -- 召唤入场走加入动画（2026-09-26 缺口 F）
            elseif reason == "前线已被敌方占领" then
                -- 前线被敌方占领：软失败并向发起方提示（2026-09-26 缺口 F）
                FireFrontlineDenied(ctx, card)
            end
        end
        return ok
    end,
    -- 升为老兵（套用老兵外观并触发「升级」开始点）
    elevateToVeteran = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimVeteran(t) then ok = true end
        end
        return ok
    end,
    -- 返回卡组顶（把目标卡放到其所有者牌堆顶，2026-10-04；亡计「返回卡组顶」等）
    -- 来源区移出：仍在场走非死亡移除（SimRemoveFromField "remove"，不触发亡计），
    -- 否则尝试从手牌移除；随后入堆顶（KARDS.Deck:PutOnTop 末项 = 堆顶）。
    returnToDeckTop = function(ctx, card, targets)
        local tableID = ctx.tableID
        local ok = false
        for _, t in ipairs(targets) do
            local owner = (t.GetOwner and t:GetOwner()) or nil
            if owner then
                if KARDS.Battlefield:FindCardZone(tableID, t) then
                    KARDS.Battle:SimRemoveFromField(t, "remove")
                else
                    KARDS.Deck:RemoveFromHand(tableID, owner, t)
                end
                if KARDS.Deck:PutOnTop(tableID, owner, t) then ok = true end
            end
        end
        return ok
    end,
    -- 取消：解除压制
    unsuppress = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimUnsuppress(t) then ok = true end
        end
        return ok
    end,
    -- 取消：解除抑制
    unneutralize = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimUnneutralize(t) then ok = true end
        end
        return ok
    end,
    -- 取消：解除控制
    uncontrol = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimUncontrol(t) then ok = true end
        end
        return ok
    end,
    -- 取消：解除免疫
    unimmune = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimUnimmune(t) then ok = true end
        end
        return ok
    end,
    -- 被消灭（从战场移除）
    destroy = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimRemoveFromField(t, "death") then ok = true end
        end
        return ok
    end,
}

-- ====================================================================
-- 语义动作执行器（card 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, player, item, node)
--   ctx    执行上下文
--   card   效果发起卡牌句柄
--   player 受影响玩家（友方 = 发起者，敌方 = 对方）
--   item   语义项（含 count / position 等组件 ID）
--   node   节点实例

-- 卡牌类型选项 → 卡牌类型（card 模板「单位/指令/反制」下拉选项值）
local CARD_TYPE_MAP = { [1] = "unit", [2] = "command", [3] = "counter_command" }

-- 取卡组指定位置的卡牌（remove=false 时仅窥视不取走）
-- @param tableID    string 牌桌唯一标识符
-- @param player     string 玩家标识
-- @param count      number 张数
-- @param position   number 1=卡组顶(末项) 2=卡组底(首项) 3=随机 4=指定(按类型)
-- @param typeFilter string|nil 卡牌类型筛选（unit/command/counter_command；nil 不过滤）
-- @param remove     boolean 是否从卡组取走（draw/discard/burn 取走；copy/scry 仅窥视）
-- @return table 取出的卡牌列表
local function TakeDeckCards(tableID, player, count, position, typeFilter, remove)
    local deck = KARDS.Deck:GetDeck(tableID, player)
    if not deck then return {} end
    count = math.max(0, math.min(math.floor(count or 1), #deck))
    local picked = {}
    for _ = 1, count do
        local idx
        if position == 2 then
            idx = 1 -- 卡组底（首项）
        elseif position == 3 then
            idx = KARDS.Deck:RandomInt(#deck) -- 随机
        else
            idx = #deck -- 卡组顶（末项）或缺省
        end
        local card = deck[idx]
        if typeFilter and card and card:GetType() ~= typeFilter then
            -- 类型筛选：从对应端向另一端扫描第一张匹配
            local found
            if position == 2 then
                for i = 1, #deck do
                    if deck[i]:GetType() == typeFilter then found = i break end
                end
            else
                for i = #deck, 1, -1 do
                    if deck[i]:GetType() == typeFilter then found = i break end
                end
            end
            if not found then break end
            idx, card = found, deck[found]
        end
        if remove then
            table.remove(deck, idx)
        end
        table.insert(picked, card)
    end
    return picked
end

-- 克隆卡牌（card 模板「复制」用：同属性新建 Mock 卡牌）
-- ID 带 _copy 后缀（实例隔离：卡牌全局变量按 ID 分桶、对象比较按 ID 判等），同时记录
-- 源卡标识 _faceName 作卡面标识——卡面/外观/3D2D 文字/效果链（指向）均按显示名查卡牌
-- 信息，后缀 ID 查不到外观数据会退成白色兜底（2026-09-27 缺口 B 修复）。
-- @param card table 源卡牌句柄
-- @return table 克隆卡牌句柄
local function CloneCard(card)
    local kw = {}
    for _, k in ipairs(card:GetKeywords()) do table.insert(kw, k) end
    local combat = card:GetCombatModifiers()
    local clone = KARDS.CardInterface.CreateMockCard(card:GetID() .. "_copy", card:GetType(), card:GetOwner(), {
        attack = card:GetStat("attack"),
        defense = card:GetStat("defense"),
        cost = card:GetCost(),
        actionCost = card:GetActionCost(),
        unitType = card:GetUnitType(),
        keywords = kw,
        combatModifiers = { outgoing = combat.outgoing, incoming = combat.incoming },
    })
    clone._faceName = card:GetName()
    return clone
end

-- 解析数量槽值：数字字面量 或 "var:<显示名>" 引用（读取被引用变量当前值；槽未设置默认 1）
-- @param ctx    table 执行上下文（ResolveNumberValue 用）
-- @param node   table 节点实例
-- @param compId string 数量槽组件 ID（number_1 / randomCount / specifiedCount 等）
-- @return number 数量（向下取整，保证张数/次数为整数）
local function ResolveCount(ctx, node, compId)
    local raw = ReadSlot(node, compId)
    if raw == nil then return 1 end
    local v = KARDS.NodeParser.ResolveNumberValue(ctx, raw)
    return math.floor(v)
end

local CardActs = {
    -- 抽取：从卡组取 count 张（按位置/类型）加入手牌
    draw = function(ctx, card, player, item, node)
        local count = ResolveCount(ctx, node, item.count)
        local position = ReadSlot(node, item.position) or 1
        -- 类型筛选：指定(4)用 typeSelect，否则用 typeSelectFallback
        local typeSel = (position == item.specifiedIndex) and item.typeSelect or item.typeSelectFallback
        local typeFilter = CARD_TYPE_MAP[ReadSlot(node, typeSel)]
        local drawn = TakeDeckCards(ctx.tableID, player, count, position, typeFilter, true)
        if #drawn > 0 then
            local hand = KARDS.Deck:GetHand(ctx.tableID, player)
            for _, c in ipairs(drawn) do
                table.insert(hand, c)
            end
            -- 一次抽取操作 = 一刻：发起者 = 首张，受影响 = 其余，
            -- 第三部分记录该玩家手牌张数变化（手牌 +N），供事件监测「额外抽牌 = N 张时」匹配
            -- （卡牌效果造成的抽取全部归类为额外抽牌，见 cl_canvas_editor.lua 文案；
            --   与 SimDraw 的回合开始抽牌「draw」区分，两者为反制上的不同事件）
            local targets = {}
            for i = 2, #drawn do
                table.insert(targets, { drawn[i], { "extra_draw" } })
            end
            KARDS.TickLog:Push(ctx.tableID, drawn[1], { "extra_draw" }, targets, nil,
                { { player, "hand", "+" .. #drawn } })
        end
        -- 2026-08-12（调试会话 card-draw-missing 修复）：节点「抽取」与 SimDraw 对齐，
        -- 触发抽牌回调（牌桌实体 OnBattleDraw 广播 → 客户端抽牌动画/手牌落位）。
        -- 修复前：只改服务端手牌 + TickLog，不触发 DrawCallbacks → 服务端抽到牌但
        -- 客户端无广播，视觉上"没抽牌"（证据 P3_draw_done drawn=1 cb=true 但回调未调用）。
        if #drawn > 0 then
            local dcb2 = KARDS.Battle.DrawCallbacks and KARDS.Battle.DrawCallbacks[ctx.tableID]
            if dcb2 then dcb2(player, drawn) end
        end
        return #drawn > 0
    end,
    -- 复制：从卡组位置复制 count 张到手牌（不取走源卡）
    copy = function(ctx, card, player, item, node)
        local count = ResolveCount(ctx, node, item.count)
        local position = ReadSlot(node, item.position) or 1
        local picked = TakeDeckCards(ctx.tableID, player, count, position, nil, false)
        if #picked > 0 then
            local hand = KARDS.Deck:GetHand(ctx.tableID, player)
            local copies = {}
            local overdrawnCards = {} -- 爆牌副本表 [copy] = true（手牌已达上限未入手）
            local overdrawn = 0
            for _, c in ipairs(picked) do
                local copy = CloneCard(c)
                -- 手牌上限检查（2026-09-05）：手牌已满时爆牌——复制仍创建（供 TickLog 追踪）
                -- 但不进手牌，与 Draw 的爆牌语义一致
                if #hand < KARDS.Deck.MAX_HAND then
                    table.insert(hand, copy)
                else
                    overdrawn = overdrawn + 1
                    overdrawnCards[copy] = true
                end
                table.insert(copies, copy)
            end
            local targets = {}
            for i = 2, #copies do
                table.insert(targets, { copies[i], { "copy" } })
            end
            KARDS.TickLog:Push(ctx.tableID, copies[1], { "copy" }, targets, nil,
                { { player, "hand", "+" .. (#copies - overdrawn) } })
            -- 计数变更事件（2026-08-18 规划 C5）：copy 直接改手牌数组（卡组不减），
            -- 无其它同步入口 → 实体层订阅后补 SyncBattleCounts
            KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.CountsChanged, { player = player })
            -- 抽牌动画（2026-09-27 缺口 B 修复）：克隆卡走与抽牌同一条链路——牌桌实体
            -- OnBattleDraw 在卡堆顶生成临时卡实体并广播抽牌动画，落手牌位（本方看卡面，
            -- 对方/观战看卡背；爆牌副本走专属弃牌动画）。第五参数告知本次不消耗卡组
            --（复制只读源卡，卡堆余量/顶卡卡背不变）。
            local dcb = KARDS.Battle.DrawCallbacks and KARDS.Battle.DrawCallbacks[ctx.tableID]
            if dcb then
                local hasOverdraw = false
                for _ in pairs(overdrawnCards) do hasOverdraw = true break end
                dcb(player, copies, hasOverdraw, hasOverdraw and overdrawnCards or nil, true)
            end
        end
        return #picked > 0
    end,
    -- 弃掉（2026-10-06 扩展手牌来源）：position select_7
    --   1=手中（select_8 二级 1=自选的一张卡 → 无值经 SimDiscard 让玩家选择；2=第 number_4 张 → 数值序数）
    --   2=卡组顶 3=卡组底 4=随机 5=指定
    --   手牌来源走战斗系统弃牌入口 KARDS.Battle:SimDiscard（统一钩子 + 弃牌刻 + 「弃牌」开始点效果链）；
    --   卡组来源维持既有逻辑（从卡组取 count 张丢弃，不入任何区；卡组 -N）
    discard = function(ctx, card, player, item, node)
        local position = ReadSlot(node, item.position) or 1
        if position == 1 then -- 手中
            local kind = ReadSlot(node, item.handKind) or 1
            if kind == 2 then -- 第 [lib]：数值序数弃牌
                local ordinal = math.floor(ResolveCount(ctx, node, item.ordinal))
                return KARDS.Battle:SimDiscard(player, nil, ordinal)
            end
            -- 自选的一张卡：无值 → SimDiscard 让玩家选择（经 DiscardCallbacks 进入实体层选择
            -- 会话，玩家点击手牌 +「确认」后回传选中卡；未选择/超时放弃）
            return KARDS.Battle:SimDiscard(player)
        end
        local count = ResolveCount(ctx, node, item.count)
        -- 位置映射（+1 偏移回既有口径）：2=卡组顶→1 3=卡组底→2 4=随机→3 5=指定→4
        local picked = TakeDeckCards(ctx.tableID, player, count, position - 1, nil, true)
        if #picked > 0 then
            local targets = {}
            for i = 2, #picked do
                table.insert(targets, { picked[i], { "discard" } })
            end
            KARDS.TickLog:Push(ctx.tableID, picked[1], { "discard" }, targets, nil,
                { { player, "deck", "-" .. #picked } })
            -- 计数变更事件（2026-08-18 规划 C5）：discard 直接改卡组数组（不入任何区），
            -- 无既有同步入口 → 实体层订阅后补 SyncBattleCounts（卡组余量 NW）
            KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.CountsChanged, { player = player })
            -- 单卡飞出动画（2026-09-26 缺口 E）：节点弃牌从卡堆顶飞向该方视角右侧卡槽
            -- （与抽牌爆牌的左侧槽位表现区分），无「手牌已满」提示
            KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.PileCardRemoved,
                { player = player, cards = picked })
        end
        return #picked > 0
    end,
    -- 开发：从所选开发池（{$} 对象组变量）随机 3 张（允许重复）选 1，复制一份加入手牌，共 count 次
    -- readme 7.2.1：开发 = 从特定卡池（对象(组)）中的随机 3 张牌中选择 1 张，并将其加入手牌
    -- 2026-10-02 用户规格：加入手牌的是「复制一份」，不是抽取（卡组原卡保留、卡组余量不变）
    -- H5 修复（2026-08-08）：开发池 = Varlib 开发池对象组变量（Battle.DevelopPool.*，位置×国籍×
    -- 卡牌类型×单位类型组合，见 sh_varlib.lua GetDevelopPoolCards），由卡组动态筛选，国籍/单位类型/
    -- 本国精英筛选全部生效；不再按「卡组搜索第 1 张」解析。
    develop = function(ctx, card, player, item, node)
        local count = ResolveCount(ctx, node, item.count)
        local poolName = ReadSlot(node, item.pool) -- select_8：{$} 选中的开发池变量显示名
        if type(poolName) ~= "string" or poolName == "" then
            print("[NodeParser] develop: 未选择开发池对象变量（{$} 卡牌对象模式）")
            return false
        end
        -- 显示名 → 路径（预定义开发池组合变量）→ 组合定义；用户自定义 e 对象变量兜底
        local path = ctx._displayIndex and ctx._displayIndex[poolName]
        local def = path and KARDS.VarLib and KARDS.VarLib.ParseDevelopPoolPath(path) or nil
        local deck = KARDS.Deck:GetDeck(ctx.tableID, player)
        local hand = KARDS.Deck:GetHand(ctx.tableID, player)
        if not deck or not hand then return false end
        -- 手牌上限检查（2026-09-05）：手牌已满时静默阻止开发，不消耗卡组、不插入手牌
        if #hand >= KARDS.Deck.MAX_HAND then
            print("[NodeParser] develop: 手牌已满，静默阻止开发")
            return false
        end
        count = math.max(0, count)
        local picked = {}
        for _ = 1, count do
            -- 每次重新筛选卡池（def 为 nil 时兜底用对象组变量值）
            local pool
            if def then
                pool = KARDS.VarLib.GetDevelopPoolCards(ctx.tableID, player, def)
            else
                local obj = KARDS.NodeParser.ResolveObject(ctx, poolName)
                if type(obj) == "table" and #obj > 0 then pool = obj end
            end
            if not pool or #pool == 0 then break end
            -- 候选 = 池中随机 3 张（允许重复）的复制（2026-10-02 用户规格：开发是「复制一份
            -- 加入手牌」，不是抽取）：候选直接用克隆句柄，选中的克隆进手牌，卡组原卡保留。
            -- 克隆走 CloneCard（ID 带 _copy 隔离实例，_faceName 保留源卡卡面标识），于是三选一
            -- 的候选实体与手牌实体登记都挂在克隆句柄上，与服务端映射一致。
            local cand3 = {}
            for i = 1, 3 do
                local src = pool[KARDS.Deck:RandomInt(#pool)]
                cand3[i] = CloneCard(src) or src
            end
            -- 从 3 张中选 1：缺省取第 3 张（等价旧实现三次随机保留末张的结果）；
            -- 选择注入 ctx.specify.developPicker（伪用户控制台三选一用）：
            -- function(3 张候选) -> 选中的卡；返回 false/nil 走缺省
            local pick
            if ctx.specify and type(ctx.specify.developPicker) == "function" then
                pick = ctx.specify.developPicker(cand3)
            end
            if pick == nil or pick == false then pick = cand3[3] end
            table.insert(hand, pick)
            table.insert(picked, pick)
        end
        if #picked == 0 then return false end
        -- 开发刻：发起者 = 首张开发牌，受影响 = 其余；记录玩家手牌 +N（复制不消耗卡组，
        -- 卡组余量不变，故不再记 deck -N）
        local targets = {}
        for i = 2, #picked do
            table.insert(targets, { picked[i], { "develop" } })
        end
        KARDS.TickLog:Push(ctx.tableID, picked[1], { "develop" }, targets, nil,
            { { player, "hand", "+" .. #picked } })
        -- 计数变更事件（2026-08-18 规划 C5）：develop 只改手牌数组（复制入手，卡组不变），
        -- 实体层订阅后补 SyncBattleCounts（手牌数 + 卡组余量 NW，后者本次不变）
        KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.CountsChanged, { player = player })
        return true
    end,
    -- 观星：从卡组顶 count 张选 1 张加入手牌，其余按序移入卡组底（2026-09-26 语义重写，
    -- 原实现仅窥视不改状态）。卡组余量不变，手牌 +1。
    scry = function(ctx, card, player, item, node)
        local count = ResolveCount(ctx, node, item.count)
        local deck = KARDS.Deck:GetDeck(ctx.tableID, player)
        local hand = KARDS.Deck:GetHand(ctx.tableID, player)
        if not deck or not hand then return false end
        -- 手牌上限检查（与 develop L455 一致）：手牌已满时静默阻止观星
        if #hand >= KARDS.Deck.MAX_HAND then
            print("[NodeParser] scry: 手牌已满，静默阻止观星")
            return false
        end
        count = math.min(math.floor(count), #deck)
        if count <= 0 then return false end
        -- 取卡组顶 count 张（末项为卡组顶，sh_deck.lua）
        local cands = {}
        for i = 1, count do cands[i] = deck[#deck - i + 1] end
        -- 从候选中选 1：缺省取顶张；选择注入 ctx.specify.scryPicker（真实玩家三选一
        -- 会话 / 伪用户控制台用）：function(count 张候选) -> 选中的卡；返回 false/nil 走缺省
        local pick
        if ctx.specify and type(ctx.specify.scryPicker) == "function" then
            pick = ctx.specify.scryPicker(cands)
        end
        if pick == nil or pick == false then pick = cands[1] end
        -- 顶 count 张全部取走
        for _ = 1, count do table.remove(deck) end
        table.insert(hand, pick)
        -- 其余按原顺序插回卡组底（原顶第 2 张先插，最终位于原顶第 3 张之下）
        for i = 2, count do
            if cands[i] ~= pick then table.insert(deck, 1, cands[i]) end
        end
        -- 观星刻：发起者 = 选中卡；记录玩家手牌 +1（卡组余量不变）
        KARDS.TickLog:Push(ctx.tableID, pick, { "scry" }, {}, nil, { { player, "hand", "+1" } })
        -- 计数变更事件（与 develop L504 同款）：scry 直接改手牌数组，
        -- 实体层订阅后补 SyncBattleCounts（手牌数 + 卡组余量 NW）
        KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.CountsChanged, { player = player })
        return true
    end,
    -- 爆牌：从卡组顶弃 count 张（卡组 -N）
    burn = function(ctx, card, player, item, node)
        local count = ResolveCount(ctx, node, item.count)
        local picked = TakeDeckCards(ctx.tableID, player, count, 1, nil, true)
        if #picked > 0 then
            local targets = {}
            for i = 2, #picked do
                table.insert(targets, { picked[i], { "burn" } })
            end
            KARDS.TickLog:Push(ctx.tableID, picked[1], { "burn" }, targets, nil,
                { { player, "deck", "-" .. #picked } })
            -- 计数变更事件（2026-08-18 规划 C5）：burn 直接改卡组数组无既有同步入口，
            -- 实体层订阅后补 SyncBattleCounts（卡组余量 NW）
            KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.CountsChanged, { player = player })
            -- 单卡飞出动画（2026-09-26 缺口 E）：节点爆牌从卡堆顶飞向该方视角右侧卡槽，无提示
            KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.PileCardRemoved,
                { player = player, cards = picked })
        end
        return #picked > 0
    end,
    -- 洗切卡组
    shuffleDeck = function(ctx, card, player)
        return KARDS.Deck:Shuffle(ctx.tableID, player)
    end,
    --[[
        洗入（2026-09-26 缺口 D：三来源）
          source 1 = 手牌中（randomKind 随机/指定 + randomCount 张数）
          source 2 = 指定的（specifiedZone 手牌/场上 + specifiedCount 张数）
          source 3 = 凭空生成（genPool {$} 开发池对象组变量 + genCount 张数）

        入口经 ShuffleInto 事件携带 entries（{ card = 句柄, from = 载体来源 }）供实体层
        广播洗入动画。from 编码动画分流所需的载体来源：1 = 手牌实体、2 = 场上单位、
        3 = 凭空生成（source 1 → 1；source 2 且 specifiedZone 1 → 1、2 → 2；source 3 → 3）。

        「手牌中·指定的」（randomKind==2）与指定的手牌（specifiedZone==1）走通用指定操作
        KARDS.Specify.HandCard（选择注入 ctx.specify.handPicker，未来 UI 由选择面板「确定」回调提交）。

        场上单位来源先记入 entries，事件触发后才离场（SimRemoveFromField，reason =
        "shuffle_into"）：事件触发时战场实体仍有效，实体层据此在其原位创建正常卡模型
        动画载体，随后离场销毁（复用缺口 C 打通的 reason 通道）。
    ]]
    shuffleInto = function(ctx, card, player, item, node)
        local source = ReadSlot(node, item.source) or 1
        local hand = KARDS.Deck:GetHand(ctx.tableID, player)
        local entries = {} -- { card = 卡牌句柄, from = 1|2|3 }
        local fieldCards = {} -- 场上单位来源（事件触发后离场）

        -- 从手牌移除一张并洗入卡组（返回是否确为手牌来源）
        local function takeFromHand(c)
            if not hand then return false end
            for i = 1, #hand do
                if hand[i] == c then
                    table.remove(hand, i)
                    KARDS.Deck:InsertRandom(ctx.tableID, player, c)
                    entries[#entries + 1] = { card = c, from = 1 }
                    return true
                end
            end
            return false
        end

        if source == 1 then -- 手牌中
            local kind = ReadSlot(node, item.randomKind) or 1
            local count = ResolveCount(ctx, node, item.randomCount)
            if kind == 2 then -- 手牌中·指定的：指定手牌操作选择
                local chosen = KARDS.Specify.HandCard(ctx.tableID, player, count,
                    ctx.specify and ctx.specify.handPicker)
                -- 指定路径：选中的牌在手牌中逐一匹配移除后随机插入卡组（不在手牌的忽略）
                for _, c in ipairs(chosen) do takeFromHand(c) end
            elseif hand and #hand > 0 then -- 手牌中·随机
                count = math.max(0, math.min(math.floor(count), #hand))
                for _ = 1, count do
                    local c = table.remove(hand, KARDS.Deck:RandomInt(#hand))
                    KARDS.Deck:InsertRandom(ctx.tableID, player, c)
                    entries[#entries + 1] = { card = c, from = 1 }
                end
            end
        elseif source == 3 then -- 凭空生成（复用开发池变量；克隆入卡组，不动原卡与手牌）
            local poolName = ReadSlot(node, item.genPool)
            local count = math.max(0, math.floor(ResolveCount(ctx, node, item.genCount)))
            -- 池解析与 develop 完全同款：显示名 → 路径 → 组合定义，def 为空时回退对象组变量
            local path = ctx._displayIndex and ctx._displayIndex[poolName]
            local def = path and KARDS.VarLib and KARDS.VarLib.ParseDevelopPoolPath(path) or nil
            for _ = 1, count do
                local pool
                if def then
                    pool = KARDS.VarLib.GetDevelopPoolCards(ctx.tableID, player, def)
                else
                    local obj = (type(poolName) == "string")
                        and KARDS.NodeParser.ResolveObject(ctx, poolName) or nil
                    if type(obj) == "table" and #obj > 0 then pool = obj end
                end
                if not pool or #pool == 0 then break end
                local c = CloneCard(pool[KARDS.Deck:RandomInt(#pool)])
                if c then
                    KARDS.Deck:InsertRandom(ctx.tableID, player, c)
                    entries[#entries + 1] = { card = c, from = 3 }
                end
            end
        elseif source == 4 then -- 对象组（2026-09-27 补充配置）：{$} 对象(组)变量逐张洗入
            -- 张数（number_10）留空或 0 = 该对象(组)全部；列表仅 1 张而张数大于 1 时按克隆
            -- 补足到该张数（覆盖「一个对象洗入 N 张」）。组内逐张按所在区分流：在手牌 →
            -- 移动入卡组（from 1）；在本方场上 → 移动入卡组并离场（from 2）；其余 → 克隆
            -- 一份入卡组（from 3，同「凭空生成」语义）。已在卡组内的卡跳过（避免同句柄重复）。
            local list = ResolveObjectSlot(ctx, node, item.groupVar)
            local count = math.max(0, math.floor(ResolveCount(ctx, node, item.groupCount)))
            local deckNow = KARDS.Deck:GetDeck(ctx.tableID, player) or {}
            local function InDeck(c)
                for i = 1, #deckNow do
                    if deckNow[i] == c then return true end
                end
                return false
            end
            local function InField(c)
                if not (c.GetOwner and c:GetOwner() == player) then return false end
                local sup = KARDS.Battlefield:GetSupport(ctx.tableID, player)
                for i = 1, KARDS.Battlefield.SLOT_COUNT do
                    if sup and sup[i] == c then return true end
                end
                if KARDS.Battlefield:GetFrontlineOwner(ctx.tableID) == player then
                    local fl = KARDS.Battlefield:GetFrontline(ctx.tableID)
                    for i = 1, KARDS.Battlefield.SLOT_COUNT do
                        if fl and fl[i] == c then return true end
                    end
                end
                return false
            end
            if #list == 1 and count > 1 then
                for _ = 1, count do
                    local clone = CloneCard(list[1])
                    if clone then
                        KARDS.Deck:InsertRandom(ctx.tableID, player, clone)
                        entries[#entries + 1] = { card = clone, from = 3 }
                    end
                end
            else
                local limit = (count > 0) and math.min(count, #list) or #list
                for i = 1, limit do
                    local c = list[i]
                    if c and not InDeck(c) then
                        if takeFromHand(c) then
                            -- 手牌来源：取手牌 + 随机插入卡组已由 takeFromHand 完成
                        elseif InField(c) then
                            KARDS.Deck:InsertRandom(ctx.tableID, player, c)
                            entries[#entries + 1] = { card = c, from = 2 }
                            fieldCards[#fieldCards + 1] = c
                        else
                            local clone = CloneCard(c)
                            if clone then
                                KARDS.Deck:InsertRandom(ctx.tableID, player, clone)
                                entries[#entries + 1] = { card = clone, from = 3 }
                            end
                        end
                    end
                end
            end
        else -- 指定的（source 2）：specifiedZone 1=手牌 / 2=场上
            local zone = ReadSlot(node, item.specifiedZone) or 1
            local count = math.max(0, math.floor(ResolveCount(ctx, node, item.specifiedCount)))
            if zone == 2 then -- 场上单位（本方支援阵线 + 本方占据的前线，过滤归属）
                local cands = {}
                local sup = KARDS.Battlefield:GetSupport(ctx.tableID, player)
                for i = 1, KARDS.Battlefield.SLOT_COUNT do
                    local c = sup and sup[i]
                    if c and c:GetType() ~= "headquarter" and c:GetOwner() == player then
                        cands[#cands + 1] = c
                    end
                end
                if KARDS.Battlefield:GetFrontlineOwner(ctx.tableID) == player then
                    local fl = KARDS.Battlefield:GetFrontline(ctx.tableID)
                    for i = 1, KARDS.Battlefield.SLOT_COUNT do
                        local c = fl and fl[i]
                        if c and c:GetOwner() == player then cands[#cands + 1] = c end
                    end
                end
                -- 选择注入 ctx.specify.fieldPicker（伪用户控制台 / 未来 UI）；缺省正序取前 count 张
                local chosen
                if ctx.specify and type(ctx.specify.fieldPicker) == "function" then
                    local picked = ctx.specify.fieldPicker(cands)
                    if type(picked) == "table" then chosen = picked end
                end
                if not chosen then
                    chosen = {}
                    for i = 1, math.min(count, #cands) do chosen[i] = cands[i] end
                end
                for i = 1, math.min(#chosen, count) do
                    local c = chosen[i]
                    if c then
                        KARDS.Deck:InsertRandom(ctx.tableID, player, c)
                        entries[#entries + 1] = { card = c, from = 2 }
                        fieldCards[#fieldCards + 1] = c
                    end
                end
            else -- 手牌（指定的手牌，张数 specifiedCount）
                local chosen = KARDS.Specify.HandCard(ctx.tableID, player, count,
                    ctx.specify and ctx.specify.handPicker)
                for _, c in ipairs(chosen) do takeFromHand(c) end
            end
        end

        if #entries == 0 then return false end

        -- 洗入刻：发起者 = 首张，受影响 = 其余；手牌 -N（仅手牌来源）、卡组 +N
        local handDelta = 0
        local targets = {}
        for i = 2, #entries do
            table.insert(targets, { entries[i].card, { "shuffle_into" } })
        end
        for _, e in ipairs(entries) do
            if e.from == 1 then handDelta = handDelta + 1 end
        end
        local changes = { { player, "deck", "+" .. #entries } }
        if handDelta > 0 then table.insert(changes, 1, { player, "hand", "-" .. handDelta }) end
        KARDS.TickLog:Push(ctx.tableID, entries[1].card, { "shuffle_into" }, targets, nil, changes)
        -- 计数变更事件（2026-08-18 规划 C5）：shuffleInto 直接改手牌/卡组数组，
        -- 实体层订阅后补 SyncBattleCounts（手牌数 + 卡组余量 NW）
        KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.CountsChanged, { player = player })
        -- 洗入事件（2026-09-26 缺口 D）：实体层订阅后广播洗入动画；此刻场上来源的战场
        -- 实体仍有效，实体层可据其原位创建正常卡模型动画载体
        KARDS.EffectRegistry.Trigger(ctx.tableID, KARDS.EffectRegistry.EVENTS.ShuffleInto,
            { player = player, source = source, entries = entries })
        -- 场上单位来源离场（事件之后）：SimRemoveFromField 复用缺口 C 的 reason 通道，
        -- 附带清槽居中 +「移除」开始点效果链 + 钳击解除
        for _, c in ipairs(fieldCards) do
            KARDS.Battle:SimRemoveFromField(c, "shuffle_into")
        end
        return true
    end,
}

-- ====================================================================
-- 语义动作执行器（command 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, targets, item, node)
--   ctx     执行上下文（含 tableID）
--   card    效果发起卡牌句柄（指令卡）
--   targets 受影响卡牌列表（command 模板不使用，忽略）
--   item    语义项（含 side：friendly/enemy/both）
--   node    节点实例（读取 select_2 / select_3 / number_1）
local CommandActs = {
    -- 指挥点 / 指挥点槽变更：阵营 × 资源 × 操作 × 数值
    commandPoint = function(ctx, card, targets, item, node)
        local resource = ReadSlot(node, "select_2") or 1 -- 1 指挥点 / 2 指挥点槽
        local op = ReadSlot(node, "select_3") or 1       -- 1 增加 / 2 减少 / 3 设为
        local amount = tonumber(ReadSlot(node, "number_1")) or 0
        local owner = card:GetOwner()
        local enemy = EnemyOf(owner)
        -- 目标玩家集合（友方 = 发起者；敌方 = 对方；双方 = 两人）
        local players = {}
        if item.side == "enemy" then
            players[1] = enemy
        elseif item.side == "both" then
            players[1], players[2] = owner, enemy
        else
            players[1] = owner
        end
        local ok = false
        for _, p in ipairs(players) do
            local r
            if resource == 1 then
                r = KARDS.Battle:SimChangeCommandPoints(p, amount, op)
            else
                r = KARDS.Battle:SimChangeCommandSlots(p, amount, op)
            end
            if r then ok = true end
        end
        return ok
    end,
}

-- ====================================================================
-- 语义动作执行器（extract 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, targets, item, node)
--   ctx     执行上下文（含 tableID）
--   card    效果发起卡牌句柄（指令卡，决定「友方」阵营）
--   targets 未使用（extract 无对象槽输入）
--   item    语义项（cardType / attr / value / cost 组件 ID）
--   node    节点实例（select_1 阵营 + select_2 类型 + 属性槽值经 ReadSlot 读取）
-- 提取结果（卡牌对象组）写入 node.data[输出端口名]（如「提取的卡牌对象组」），
-- 供下游节点经 e 类型数据线消费（见 ResolveEWires）。
local ExtractActs = {
    -- 提取：按 阵营(select_1) + 卡牌类型(select_2) + 属性条件 收集卡牌对象组
    --   单位 → 战场（支援阵线除总部 + 前线）；指令/反制 → 手牌
    --   属性条件为「=」比较（模板 config：'攻击力'=[] 字面等号）
    extract = function(ctx, card, targets, item, node)
        local tableID = ctx.tableID or ctx.table_id
        -- 阵营展开（select_1：1 友方 / 2 敌方 / 3 双方）
        local owner = card:GetOwner()
        local enemy = EnemyOf(owner)
        local side = ReadSlot(node, "select_1") or 1
        local players = {}
        if side == 2 then
            if enemy then players[1] = enemy end
        else
            players[1] = owner
            if side == 3 and enemy then players[2] = enemy end
        end
        -- 按类型收集源卡牌（单位取战场，指令/反制取手牌，总部取总部卡）
        local group = {}
        for _, p in ipairs(players) do
            if item.cardType == "headquarter" then
                local hq = KARDS.Battlefield:GetHQ(tableID, p)
                if hq then table.insert(group, hq) end
            elseif item.cardType == "unit" then
                local support = KARDS.Battlefield:GetSupport(tableID, p)
                if support then
                    for i = 1, KARDS.Battlefield.SLOT_COUNT do
                        local u = support[i]
                        if u and u:GetType() ~= "headquarter" then table.insert(group, u) end
                    end
                end
                if KARDS.Battlefield:GetFrontlineOwner(tableID) == p then
                    local frontline = KARDS.Battlefield:GetFrontline(tableID)
                    if frontline then
                        for i = 1, KARDS.Battlefield.SLOT_COUNT do
                            local u = frontline[i]
                            if u then table.insert(group, u) end
                        end
                    end
                end
            else
                for _, c in ipairs(KARDS.Deck:GetHand(tableID, p) or {}) do
                    if c:GetType() == item.cardType then table.insert(group, c) end
                end
            end
        end
        -- 属性条件过滤（「=」比较；总部无属性条件，直接输出）
        if item.cardType == "unit" then
            local attr = ReadSlot(node, item.attr) or 1
            local want = tonumber(ReadSlot(node, item.value)) or 0
            local filtered = {}
            for _, u in ipairs(group) do
                local v
                if attr == 1 then
                    v = (u.GetStat and u:GetStat("attack")) or 0
                elseif attr == 2 then
                    v = (u.GetStat and u:GetStat("defense")) or 0
                elseif attr == 3 then
                    v = u:GetCost()
                else
                    v = u:GetActionCost()
                end
                if v == want then table.insert(filtered, u) end
            end
            group = filtered
        elseif item.cardType == "command" or item.cardType == "counter_command" then
            local want = tonumber(ReadSlot(node, item.cost)) or 0
            local filtered = {}
            for _, c in ipairs(group) do
                if c:GetCost() == want then table.insert(filtered, c) end
            end
            group = filtered
        end
        -- 输出端口名：base 输出类型首项（如「提取的卡牌对象组」），数据线 variableName 同源
        local outName = "提取的卡牌对象组"
        if node.base and node.base ~= "" then
            local struct = KARDS.NodeParser.ParseBaseStructure(node.base)
            if struct and struct.outputTypes and struct.outputTypes[1] then
                outName = struct.outputTypes[1].name
            end
        end
        node.data[outName] = group
        return true
    end,
}

-- ====================================================================
-- 语义动作执行器（headquarter 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, targets, item, node)
--   ctx     执行上下文（含 tableID）
--   card    效果发起卡牌句柄（指令卡，决定「友方」阵营）
--   targets 未使用（headquarter 无对象槽输入）
--   item    语义项（含 side：friendly / enemy / both）
--   node    节点实例（select_2 操作 + number_1 数值经 ReadSlot 读取）
local HeadquarterActs = {
    -- 总部防御力变更：阵营(select_1) × 操作(select_2 增加1/减少2/设为3) × 数值(number_1)
    hqDefense = function(ctx, card, targets, item, node)
        local owner = card:GetOwner()
        local enemy = EnemyOf(owner)
        local players = {}
        if item.side == "enemy" then
            players[1] = enemy
        elseif item.side == "both" then
            players[1], players[2] = owner, enemy
        else
            players[1] = owner
        end
        local op = ReadSlot(node, "select_2") or 1 -- 1 增加 / 2 减少 / 3 设为
        local amount = tonumber(ReadSlot(node, "number_1")) or 0
        local ok = false
        for _, p in ipairs(players) do
            if p and KARDS.Battle:SimChangeHQDefense(p, amount, op) then ok = true end
        end
        return ok
    end,
}

-- ====================================================================
-- 语义动作执行器（loop 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, targets, item, node)
--   ctx     执行上下文（含 tableID）
--   card    效果发起卡牌句柄（指令卡）
--   targets 未使用（loop 无对象槽输入）
--   item    语义项（loop 无分支，item == 语义表本身）
--   node    节点实例（number_1 循环计数经 ReadSlot 读取；递减后写回 node.data）
local LoopActs = {
    -- 循环：读 number_1 循环计数。
    --   未结束（>0）→ 计数 -1 并返回 true（双输出第一输出点，继续循环）；
    --   已结束（=0）→ 返回 false（双输出第二输出点，循环结束）。
    -- 写回与 GetBaseSlotValue 读取优先级对齐：编辑器导出 numbers/slots 与测试直存 data 同步更新。
    loop = function(ctx, card, targets, item, node)
        local count = tonumber(ReadSlot(node, "number_1")) or 0
        if count <= 0 then return false end
        count = count - 1
        if node.data then
            if node.data.numbers and node.data.numbers.number_1 then
                node.data.numbers.number_1.value = count
            end
            if node.data.slots and node.data.slots.number_1
                and node.data.slots.number_1.literalValue ~= nil then
                node.data.slots.number_1.literalValue = count
            end
            node.data["number_1"] = count
        end
        return true
    end,
}

-- ====================================================================
-- 语义动作执行器（property 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, targets, item, node)
--   ctx     执行上下文（含 tableID）
--   card    效果发起卡牌句柄（指令卡，决定「友方」阵营）
--   targets e 数据线注入的对象组（如 target_selector 选出的敌方单位，战斗分支优先取 targets[1]）
--   item    语义项（shuffleUnits 含 side 组件 ID；battle 含 attacker/defender 组件 ID）
--   node    节点实例（select_1 主选项：随机排列所有1/战斗2）
local PropertyActs = {
    -- 随机排列：阵营(select_2 单位1/友方2/敌方3) → 在目标方控制的阵线范围随机重排单位
    shuffleUnits = function(ctx, card, targets, item, node)
        local owner = card:GetOwner()
        local enemy = EnemyOf(owner)
        local players = {}
        local sideIdx = tonumber(ReadSlot(node, item.side)) or 1
        if sideIdx == 3 then
            players[1] = enemy
        elseif sideIdx == 1 then
            players[1], players[2] = owner, enemy
        else
            players[1] = owner
        end
        local ok = false
        for _, p in ipairs(players) do
            if p and KARDS.Battle:SimShuffleField(p) then ok = true end
        end
        return ok
    end,
    -- 战斗：e 数据线注入对象组（targets）优先作为攻击者列表，否则 select_3 对象槽；
    -- 防御者 select_4 对象槽；两列表正序笛卡尔积互扣（SimFight，互扣双方攻击力防御；
    -- 与 action「战斗」同惯例：e 输入 = 发起方；对象槽统一 ResolveObjectSlot 逐张语义）
    battle = function(ctx, card, targets, item, node)
        -- e 数据线注入的 targets（ExecuteBaseNode 已过滤隐蔽非自身）非空优先；
        -- 未注入回退 select_3 对象槽（逐张语义，含隐蔽过滤）
        local as = (targets and #targets > 0)
            and targets
            or FilterHiddenOnField(ctx, ResolveObjectSlot(ctx, node, item.attacker), card)
        local bs = FilterHiddenOnField(ctx, ResolveObjectSlot(ctx, node, item.defender), card)
        if #as == 0 or #bs == 0 then
            print("[NodeParser] 警告: property「战斗」对象解析为空（对象槽未指向单位）")
            return false
        end
        return ForEachPair(as, bs, function(a, b)
            return KARDS.Battle:SimFight(a, b)
        end)
    end,
}

-- ====================================================================
-- 执行器合并：各模板 handlers 合并进 BaseSemantics 分派表
-- （ExecuteBaseNode 经 sem.handlers 分派，行为与原 if/elseif 链一致）
-- ====================================================================
KARDS.NodeParser.BaseSemantics.action.handlers = ActionActs
KARDS.NodeParser.BaseSemantics.card.handlers = CardActs
KARDS.NodeParser.BaseSemantics.command.handlers = CommandActs
KARDS.NodeParser.BaseSemantics.extract.handlers = ExtractActs
KARDS.NodeParser.BaseSemantics.headquarter.handlers = HeadquarterActs
KARDS.NodeParser.BaseSemantics.loop.handlers = LoopActs
KARDS.NodeParser.BaseSemantics.property.handlers = PropertyActs
