--[[
    战斗系统骨架·卡牌/卡组操作域 (Battle Card Operations)

    从 sh_battle_stub.lua 拆分（re.md B-H1：按职责拆分文件）：
    打出指令 / 卡组构筑 / 起手抽牌 / 抽牌 / 重新调度 集中于此，
    均挂 KARDS.Battle 命名空间（sh_battle_stub.lua 先加载声明命名空间），
    对外 API 签名不变。

    本域函数依赖：
      - 判定查询函数与对局状态（见 sh_battle_stub.lua）
      - Deck / CommandPoints / TickLog / Battlefield / NodeParser（全局）
      - 抽牌回调 DrawCallbacks[tableID]（依赖倒置：牌桌实体注册，抽牌成功后触发，
        见 sent_kards_battle_table/init.lua OnBattleDraw）

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_battle_stub.lua 之后）
=======================================================================================
]]

KARDS = KARDS or {}
KARDS.Battle = KARDS.Battle or {}

--[[
    打出指令（骨架）

    指令效果：若卡牌带有 effect（节点编辑器保存的效果数据 { nodes, variables, dataConnections }），
    经 KARDS.NodeParser.ExecuteEffect 执行节点效果（base 型节点 → 语义表 → 战斗系统操作）；
    无 effect 时保留演示效果（每个目标 attack/defense +1，供非节点流程测试）。

    @param player  string 打出的玩家
    @param card    table  指令卡牌句柄（KARDS.CardInterface 约定；可选 card.effect）
    @param targets table|nil 指令目标卡牌句柄列表（base 节点 action 模板的 e 输入对象槽）
    @param opts    table|nil 可选扩展参数（向后兼容）：
        specify = { handPicker = fn, targetPicker = fn } 指定操作选择注入
        （经 ctx.specify 传递：洗入「指定的」走 Specify.HandCard、target_selector「指向一个」
        走 Specify.Target；骨架缺省确定性回退，未来 UI 回调经此提交玩家选择）
    @return boolean 指令是否生效（false = 被反制钩子拦截）
]]
function KARDS.Battle:SimPlayCard(player, card, targets, opts)
    targets = targets or {}
    local hasEffect = card.effect ~= nil -- 节点效果模式（无演示 +1，节点操作各自记录刻）

    -- 隐蔽（readme 7.2.2）：未揭示的隐蔽单位不受指令影响 → 拒绝以隐蔽单位为目标的指令
    local st = self.KeywordStates and self.KeywordStates[self.TableID]
    for _, t in ipairs(targets) do
        if KARDS.KeywordStates.Hidden.Is(st, t) then
            print("[Battle] SimPlayCard 失败: 目标处于隐蔽（未揭示），不受指令影响（readme 7.2.2）")
            return false
        end
    end

    -- 打出指令消耗卡牌花费（指挥点，readme 7.1 操作）；不足拒绝
    local cost = card:GetCost()
    if not KARDS.CommandPoints:CanPay(self.TableID, player, cost) then
        print("[Battle] SimPlayCard 失败: 指挥点不足（需要 " .. cost .. "）")
        return false
    end
    KARDS.CommandPoints:Pay(self.TableID, player, cost)

    -- 推进时机存在牌桌实例上（KARDS.TickLog.Instances[tableID].PushTiming），
    -- 非 KARDS.TickLog 表字段；缺省按 "before" 处理
    local inst = KARDS.TickLog:Get(self.TableID)
    local timing = inst and inst.PushTiming or "before"

    -- 指令效果：有 effect → 经节点解析执行（base 型节点 → 语义表 → 战斗系统操作）；
    -- 无 effect → 保留演示效果（目标 attack/defense +1）
    local function applyEffect()
        if hasEffect then
            return KARDS.NodeParser.ExecuteEffect({
                tableID = self.TableID,
                initiatorCard = card,
                variables = card.effect.variables,
                dataConnections = card.effect.dataConnections,
                functions = card.effect.functions, -- 效果级函数表（funcslot 引用函数子图，见 CallFunction）
                battle = self,
                specify = opts and opts.specify, -- 指定操作选择注入（Specify.HandCard / Specify.Target 消费）
            }, card, targets, card.effect)
        end
        for _, t in ipairs(targets) do
            t:ApplyChange("attack", "increase", 1)
            t:ApplyChange("defense", "increase", 1)
        end
        return true
    end

    -- 触发反制钩子（OnBeforePlayCard），返回修改后的 args
    local function triggerHooks()
        return KARDS.EngineHooks.Trigger(self.TableID, KARDS.EngineHooks.HookPoints.OnBeforePlayCard, {
            player = player,
            card = card,
            targets = targets,
        })
    end

    if timing == "before" then
        -- 生效前：先反制后生效，反制可先击杀目标使指令失效
        local args = triggerHooks()
        if args.intercepted then
            -- 记录被拦截的打出：play_command + counter 刻（event_monitor「打出指令/触发反制」可命中）
            KARDS.TickLog:Push(self.TableID, card, { "play_command", "counter" }, {})
            -- 事件钩子（register_hook 通用效果·条件触发）：触发反制事件（发起者 = 被拦截的指令卡）
            if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
                KARDS.NodeParser.TriggerEventHooks(self.TableID, "counter", card)
            end
            return false
        end
        applyEffect()
    else
        -- 生效后：先生效后反制，反制只能事后响应
        applyEffect()
        local args = triggerHooks()
        if args.intercepted then
            -- 记录被拦截的打出：play_command + counter 刻（event_monitor「打出指令/触发反制」可命中）
            KARDS.TickLog:Push(self.TableID, card, { "play_command", "counter" }, {})
            -- 事件钩子（register_hook 通用效果·条件触发）：触发反制事件（发起者 = 被拦截的指令卡）
            if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
                KARDS.NodeParser.TriggerEventHooks(self.TableID, "counter", card)
            end
            return false
        end
    end

    -- 记录刻度：发起者 = 指令卡（打出），受影响 = 目标
    -- （节点效果模式下各节点操作已自行记录刻，此处受影响为空；演示模式为属性 +1）
    local affected = {}
    if not hasEffect then
        for _, t in ipairs(targets) do
            -- 演示效果攻击/防御各 +1：受影响分条标注变化属性（供 event_monitor select_4 过滤）
            table.insert(affected, { t, { "stat_change" }, "+1", "attack" })
            table.insert(affected, { t, { "stat_change" }, "+1", "defense" })
        end
    end
    KARDS.TickLog:Push(self.TableID, card, { "play_command" }, affected)
    -- 事件钩子（register_hook 通用效果·条件触发）：打出指令事件（发起者 = 指令卡）
    if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
        KARDS.NodeParser.TriggerEventHooks(self.TableID, "play_command", card)
    end
    -- 总是触发（register_hook 通用效果·总是触发）：每次打出指令成功都调用已注册函数（M5）
    if KARDS.NodeParser and KARDS.NodeParser.TriggerAlwaysHooks then
        KARDS.NodeParser.TriggerAlwaysHooks(self.TableID, card)
    end
    return true
end

-- 将士气伤害应用到总部卡并写时间刻（内部；moraleHits 来自 Deck:Draw / Deck:Mulligan）
-- @param tableID    string 牌桌唯一标识符
-- @param moraleHits table|nil 士气伤害表 [player] = 本轮累计伤害
local function ApplyMoraleHits(tableID, moraleHits)
    for player, dmg in pairs(moraleHits or {}) do
        local hq = KARDS.Battlefield:GetHQ(tableID, player)
        if hq then
            hq:ApplyChange("defense", "decrease", dmg)
            -- 士气伤害刻：发起者 = 受影响 = 总部卡（同对象，经受 take_damage）
            KARDS.TickLog:Push(tableID, hq, { "take_damage" }, { { hq, { "take_damage" }, "-" .. dmg } })
        end
    end
end

--[[
    设置一方卡组（构筑）并对局开始洗牌一次（骨架，卡组入口）

    @param player string 玩家标识
    @param cards  table  卡牌句柄列表（构筑；对局中双方各 39 张，数量由列表决定）
    @return boolean 是否成功
]]
function KARDS.Battle:SimSetupDeck(player, cards)
    local ok, reason = KARDS.Deck:SetDeck(self.TableID, player, cards)
    if not ok then
        print("[Battle] SimSetupDeck 失败: " .. tostring(reason))
        return false
    end
    return true
end

--[[
    起手抽牌：先手 4 手牌 / 后手 5 手牌（骨架，重新调度前置）

    @return boolean 是否成功
]]
function KARDS.Battle:SimDealOpeningHands()
    local inst = KARDS.Deck:Get(self.TableID)
    if not inst then
        print("[Battle] SimDealOpeningHands 失败: no_table")
        return false
    end
    for _, p in ipairs(self.Players) do
        self:SimDraw(p, inst.Starters[p] or KARDS.Deck.FIRST_STARTER)
    end
    return true
end

-- 抽牌回调注册表：DrawCallbacks[tableID] = function(player, drawn) end
-- 依赖倒置——骨架（纯逻辑层）不直接依赖牌桌实体，由上层（牌桌实体）注册回调，
-- 抽牌成功后回调触发（如通知客户端播放抽牌动画，见 sent_kards_battle_table/init.lua OnBattleDraw）
KARDS.Battle.DrawCallbacks = KARDS.Battle.DrawCallbacks or {}

-- 注册抽牌回调（覆盖「抽取 / 额外抽取」等一切走 SimDraw 的抽牌路径；幂等，后注册覆盖先注册）
function KARDS.Battle:SetDrawCallback(tableID, fn)
    self.DrawCallbacks[tableID] = fn
end

--[[
    抽牌（骨架，卡组入口）

    一次抽牌操作 = 一刻（规划第 2 节「一个操作事件 = 一单位时间刻」）：
      发起者 = 抽到的第一张牌；受影响列表 = 其余抽到的牌（经受 draw）；
      第三部分记录该玩家手牌张数变化（手牌 +N，按实际变化量——爆牌时手牌已达
      上限不增加，供事件监测「抽牌 = N 张时」按一刻内变化量匹配）。
    卡组为空时触发士气伤害（第一次 1，第二次 2，以此类推），总部防御减少并写 take_damage 刻。
    抽牌成功后触发已注册的抽牌回调（DrawCallbacks，见 SetDrawCallback；
    第三个参数 overdraw = 本次是否爆牌、第四个参数 overdrawnCards = 爆牌卡表
    [card]=true（per-card，支持部分爆牌），由上层播放专属弃牌动画）。

    @param player string 玩家标识
    @param count  number|nil 抽牌张数（缺省 1）
    @return table 实际抽到的卡牌列表（含爆牌弃掉的卡）
]]
function KARDS.Battle:SimDraw(player, count)
    local handBefore = #(KARDS.Deck:GetHand(self.TableID, player) or {})
    local drawn, moraleHits, overdraw, overdrawnCards = KARDS.Deck:Draw(self.TableID, player, count)
    if #drawn > 0 then
        local targets = {}
        for i = 2, #drawn do
            table.insert(targets, { drawn[i], { "draw" } })
        end
        -- 手牌变化量按实际差值（正常抽牌 = #drawn；爆牌时手牌已达上限不增加）
        local handDelta = #(KARDS.Deck:GetHand(self.TableID, player) or {}) - handBefore
        KARDS.TickLog:Push(self.TableID, drawn[1], { "draw" }, targets, nil,
            { { player, "hand", "+" .. math.max(0, handDelta) } })
        local cb = self.DrawCallbacks and self.DrawCallbacks[self.TableID]
        if cb then cb(player, drawn, overdraw, overdrawnCards) end
    end
    ApplyMoraleHits(self.TableID, moraleHits)
    return drawn
end

--[[
    重新调度（骨架，卡组入口；readme 7.1，开局双方各一次机会）

    丢弃不想要的起始手牌 → 随机移动、插入到卡组中（随机位置）→ 抽取等量替换。
    先手方开始 4 手牌，后手方开始 5 手牌（起手抽牌见 SimDealOpeningHands）。
    unwanted 即「指定手牌」的选择结果：未来 UI 经 KARDS.Specify.HandCard
    （点击手牌选择后按「确定」）取得后传入本函数。

    @param player   string 玩家标识
    @param unwanted table|nil 要丢弃的手牌卡牌列表
    @return boolean 是否成功（重复调度 / 丢弃不在手牌的牌均拒绝）
]]
function KARDS.Battle:SimMulligan(player, unwanted)
    local ok, reason, moraleHits, drawn = KARDS.Deck:Mulligan(self.TableID, player, unwanted)
    if not ok then
        print("[Battle] SimMulligan 失败: " .. tostring(reason))
        return false
    end
    -- 补抽等量卡（视觉层）：与 SimDraw 一致触发抽牌回调（牌桌实体 OnBattleDraw
    -- 据此广播补抽卡，客户端原位落手牌）
    if drawn and #drawn > 0 then
        local cb = self.DrawCallbacks and self.DrawCallbacks[self.TableID]
        if cb then cb(player, drawn) end
    end
    ApplyMoraleHits(self.TableID, moraleHits)
    return true
end
