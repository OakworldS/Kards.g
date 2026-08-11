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
            if KARDS.Battle:SimMoveToFrontline(t) then ok = true end
        end
        return ok
    end,
    -- 交战（与对象槽单位交战）
    engage = function(ctx, card, targets, item, node)
        local src = targets[1]
        local dst = ReadSlot(node, item.target)
        if not src or not dst then return false end
        return KARDS.Battle:SimEngage(src, dst)
    end,
    -- 战斗（与对象槽单位战斗）
    fight = function(ctx, card, targets, item, node)
        local a = targets[1]
        local b = ReadSlot(node, item.target)
        if not a or not b then return false end
        return KARDS.Battle:SimFight(a, b)
    end,
    -- 加入战场（效果拉入场：支援阵线首个空槽）
    joinBattlefield = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimJoinBattlefield(t) then ok = true end
        end
        return ok
    end,
    -- 加入前线（效果直接加入前线）
    joinFrontline = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimJoinFrontline(t) then ok = true end
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
    -- 转换（更换单位类型；骨架未指定新类型时不变，仅记录）
    convert = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimConvert(t, nil) then ok = true end
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
    -- 触发关键字效果（target 对象槽 + keyword 关键字槽）
    triggerKeyword = function(ctx, card, targets, item, node)
        local dst = ReadSlot(node, item.target)
        local kw = ReadSlot(node, item.keyword)
        if not dst or not kw then return false end
        return KARDS.Battle:SimTriggerKeyword(card, dst, tostring(kw))
    end,
    -- 返回手牌（从场上回所有者手牌）
    returnToHand = function(ctx, card, targets)
        local ok = false
        for _, t in ipairs(targets) do
            if KARDS.Battle:SimReturnToHand(t) then ok = true end
        end
        return ok
    end,
    -- 召唤单位（unit 对象槽 + zone 选项：1=支援阵线 2=前线）
    summonUnit = function(ctx, card, targets, item, node)
        local unit = ReadSlot(node, item.unit)
        local zone = ReadSlot(node, item.zone) or 1
        if not unit then return false end
        return KARDS.Battle:SimSummonUnit(card:GetOwner(), unit, zone)
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
-- @param card table 源卡牌句柄
-- @return table 克隆卡牌句柄
local function CloneCard(card)
    local kw = {}
    for _, k in ipairs(card:GetKeywords()) do table.insert(kw, k) end
    local combat = card:GetCombatModifiers()
    return KARDS.CardInterface.CreateMockCard(card:GetID() .. "_copy", card:GetType(), card:GetOwner(), {
        attack = card:GetStat("attack"),
        defense = card:GetStat("defense"),
        cost = card:GetCost(),
        actionCost = card:GetActionCost(),
        unitType = card:GetUnitType(),
        keywords = kw,
        combatModifiers = { outgoing = combat.outgoing, incoming = combat.incoming },
    })
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
            -- 一次抽取操作 = 一刻（对齐 SimDraw）：发起者 = 首张，受影响 = 其余，
            -- 第三部分记录该玩家手牌张数变化（手牌 +N），供事件监测「抽牌 = N 张时」匹配
            local targets = {}
            for i = 2, #drawn do
                table.insert(targets, { drawn[i], { "draw" } })
            end
            KARDS.TickLog:Push(ctx.tableID, drawn[1], { "draw" }, targets, nil,
                { { player, "hand", "+" .. #drawn } })
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
            for _, c in ipairs(picked) do
                local copy = CloneCard(c)
                table.insert(hand, copy)
                table.insert(copies, copy)
            end
            local targets = {}
            for i = 2, #copies do
                table.insert(targets, { copies[i], { "copy" } })
            end
            KARDS.TickLog:Push(ctx.tableID, copies[1], { "copy" }, targets, nil,
                { { player, "hand", "+" .. #copies } })
        end
        return #picked > 0
    end,
    -- 弃掉：从卡组取 count 张丢弃（不入任何区；卡组 -N）
    discard = function(ctx, card, player, item, node)
        local count = ResolveCount(ctx, node, item.count)
        local position = ReadSlot(node, item.position) or 1
        local picked = TakeDeckCards(ctx.tableID, player, count, position, nil, true)
        if #picked > 0 then
            local targets = {}
            for i = 2, #picked do
                table.insert(targets, { picked[i], { "discard" } })
            end
            KARDS.TickLog:Push(ctx.tableID, picked[1], { "discard" }, targets, nil,
                { { player, "deck", "-" .. #picked } })
        end
        return #picked > 0
    end,
    -- 开发：从所选开发池（{$} 对象组变量）随机 3 张（允许重复）选 1 加入手牌，共 count 次
    -- readme 7.2.1：开发 = 从特定卡池（对象(组)）中的随机 3 张牌中选择 1 张，并将其加入手牌
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
        count = math.max(0, count)
        local picked = {}
        for _ = 1, count do
            -- 每次重新筛选卡池（卡组随开发消耗变化；def 为 nil 时兜底用对象组变量值）
            local pool
            if def then
                pool = KARDS.VarLib.GetDevelopPoolCards(ctx.tableID, player, def)
            else
                local obj = KARDS.NodeParser.ResolveObject(ctx, poolName)
                if type(obj) == "table" and #obj > 0 then pool = obj end
            end
            if not pool or #pool == 0 then break end
            -- 随机 3 张（允许重复）中选 1（readme 7.2.1）
            local pick = pool[KARDS.Deck:RandomInt(#pool)]
            for _ = 1, 2 do
                pick = pool[KARDS.Deck:RandomInt(#pool)]
            end
            -- 从卡组取走（若取自卡组；用户对象组变量兜底时仅入牌不移卡组）
            for i = #deck, 1, -1 do
                if deck[i] == pick then
                    table.remove(deck, i)
                    break
                end
            end
            table.insert(hand, pick)
            table.insert(picked, pick)
        end
        if #picked == 0 then return false end
        -- 开发刻：发起者 = 首张开发牌，受影响 = 其余；记录玩家手牌 +N、卡组 -N
        local targets = {}
        for i = 2, #picked do
            table.insert(targets, { picked[i], { "develop" } })
        end
        KARDS.TickLog:Push(ctx.tableID, picked[1], { "develop" }, targets, nil,
            { { player, "hand", "+" .. #picked }, { player, "deck", "-" .. #picked } })
        return true
    end,
    -- 选择（观星）：窥视卡组顶 count 张，不改状态（正式版允许重排）
    scry = function(ctx, card, player, item, node)
        local count = ResolveCount(ctx, node, item.count)
        local deck = KARDS.Deck:GetDeck(ctx.tableID, player)
        if not deck then return false end
        local peeked = {}
        for i = 1, math.min(math.floor(count), #deck) do
            table.insert(peeked, deck[#deck - i + 1])
        end
        KARDS.TickLog:Push(ctx.tableID, card, { "scry" }, {})
        return #peeked > 0
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
        end
        return #picked > 0
    end,
    -- 洗切卡组
    shuffleDeck = function(ctx, card, player)
        return KARDS.Deck:Shuffle(ctx.tableID, player)
    end,
    -- 洗入：手牌（随机/指定）或指定卡牌洗入卡组（手牌 -N、卡组 +N）
    -- 「手牌中·指定的」（randomKind==2）与「指定的」（source==2）均走通用指定操作
    -- KARDS.Specify.HandCard（选择注入 ctx.specify.handPicker，未来 UI 由选择面板「确定」回调提交）
    shuffleInto = function(ctx, card, player, item, node)
        local source = ReadSlot(node, item.source) or 1
        local hand = KARDS.Deck:GetHand(ctx.tableID, player)
        if not hand or #hand == 0 then return false end
        local removed = {}
        if source == 1 then -- 手牌中
            local kind = ReadSlot(node, item.randomKind) or 1
            local count = ResolveCount(ctx, node, item.randomCount)
            if kind == 2 then -- 手牌中·指定的：指定手牌操作选择
                local chosen = KARDS.Specify.HandCard(ctx.tableID, player, count,
                    ctx.specify and ctx.specify.handPicker)
                -- 指定路径：选中的牌在手牌中逐一匹配移除后随机插入卡组（不在手牌的忽略）
                for _, c in ipairs(chosen) do
                    for i = 1, #hand do
                        if hand[i] == c then
                            table.remove(hand, i)
                            KARDS.Deck:InsertRandom(ctx.tableID, player, c)
                            table.insert(removed, c)
                            break
                        end
                    end
                end
            else -- 手牌中·随机
                count = math.max(0, math.min(math.floor(count), #hand))
                for _ = 1, count do
                    local idx = KARDS.Deck:RandomInt(#hand)
                    local c = table.remove(hand, idx)
                    KARDS.Deck:InsertRandom(ctx.tableID, player, c)
                    table.insert(removed, c)
                end
            end
        else -- 指定的：指定手牌操作选择
            local count = ResolveCount(ctx, node, item.specifiedCount)
            local chosen = KARDS.Specify.HandCard(ctx.tableID, player, count,
                ctx.specify and ctx.specify.handPicker)
            for _, c in ipairs(chosen) do
                for i = 1, #hand do
                    if hand[i] == c then
                        table.remove(hand, i)
                        KARDS.Deck:InsertRandom(ctx.tableID, player, c)
                        table.insert(removed, c)
                        break
                    end
                end
            end
        end
        if #removed > 0 then
            local targets = {}
            for i = 2, #removed do
                table.insert(targets, { removed[i], { "shuffle_into" } })
            end
            KARDS.TickLog:Push(ctx.tableID, removed[1], { "shuffle_into" }, targets, nil,
                { { player, "hand", "-" .. #removed }, { player, "deck", "+" .. #removed } })
        end
        return #removed > 0
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
    -- 战斗：e 数据线注入对象组（targets）优先作为攻击者，否则 select_3 对象槽；防御者 select_4 对象槽
    -- （SimFight 互扣双方攻击力防御；与 action「战斗」同惯例：e 输入 = 发起方）
    battle = function(ctx, card, targets, item, node)
        local function resolve(compId)
            local v = ReadSlot(node, compId)
            if type(v) == "table" then return v end -- 测试/数据线直接写卡牌句柄
            if type(v) == "string" and v ~= "" then return KARDS.NodeParser.ResolveObject(ctx, v) end
            return nil
        end
        local a = targets and targets[1] or nil -- e 数据线注入的对象组（无注入时为 nil）
        if not a then a = resolve(item.attacker) end
        local b = resolve(item.defender)
        if not a or not b then
            print("[NodeParser] 警告: property「战斗」对象解析为空（对象槽未指向单位）")
            return false
        end
        return KARDS.Battle:SimFight(a, b)
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
