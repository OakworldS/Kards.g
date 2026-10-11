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

    -- 隐蔽（readme 7.2.2 + 2026-08-13 用户规格：任何节点上作用到非自身的效果，无法
    -- 作用到隐蔽的单位）：指令以隐蔽单位为目标的 → 从目标列表剔除（指令仍可打出，
    -- 费用照付，效果因无目标而不生效）。剔除而非拒绝的原因（反制例证）：反制指令
    -- （如「失踪：敌方单位移至前线时，将其消灭」）指向仍隐蔽的移动单位时——反制
    -- 仍会触发、但「消灭」不会作用成功在隐蔽单位（目标被过滤）；攻击类反制在单位
    -- 已揭示（SimAttack/SimEngage 先 SimReveal）后结算则正常作用。剔除后 targets
    -- 为空时指令效果无目标（演示效果无操作）。「自身是隐蔽单位就能作用到自身」的
    -- 例外仅适用于单位自身效果（ExecuteBaseNode 过滤），指令发起者恒非隐蔽目标。
    local st = self.KeywordStates and self.KeywordStates[self.TableID]
    local filtered = {}
    for _, t in ipairs(targets) do
        if not (st and KARDS.KeywordStates.Hidden.Is(st, t)) then
            filtered[#filtered + 1] = t
        end
    end
    targets = filtered

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
    -- 无 effect → 保留演示效果（目标 attack/defense +1）。开始点分流：指令按「打出」、
    -- 反制按「激活时」执行效果链（开始点 = 触发点；无匹配开始点 → ExecuteEffect 返回
    -- false 不执行，旧格式/测试的纯节点链从首节点执行，向后兼容）
    local function applyEffect()
        if hasEffect then
            local entryTitle = card:GetType() == "counter_command" and "激活时" or "打出"
            return KARDS.NodeParser.ExecuteEffect({
                tableID = self.TableID,
                initiatorCard = card,
                variables = card.effect.variables,
                dataConnections = card.effect.dataConnections,
                functions = card.effect.functions, -- 效果级函数表（funcslot 引用函数子图，见 CallFunction）
                battle = self,
                specify = opts and opts.specify, -- 指定操作选择注入（Specify.HandCard / Specify.Target 消费）
            }, card, targets, card.effect, nil, entryTitle)
        end
        for _, t in ipairs(targets) do
            t:ApplyChange("attack", "increase", 1)
            t:ApplyChange("defense", "increase", 1)
            -- 飘字（2026-08-14）：演示模式指令 +1+1 → 攻防增加绿色飘字
            KARDS.Battle:NotifyStatFXByTable(self.TableID, t, "attack", 1, "increase", "other")
            KARDS.Battle:NotifyStatFXByTable(self.TableID, t, "defense", 1, "increase", "other")
        end
        return true
    end

    -- 触发反制钩子：OnBeforePlayCard（既有）与统一操作钩子 OnBeforeOperation（M1，
    -- 反制按操作类型拦截），共用同一 args 表，任一置 intercepted 即拦截
    local function triggerHooks()
        local args = { player = player, card = card, targets = targets }
        args = KARDS.EngineHooks.Trigger(self.TableID, KARDS.EngineHooks.HookPoints.OnBeforePlayCard, args)
        return KARDS.EngineHooks.TriggerOperation(self.TableID, "play_command", args)
    end

    -- 反制拦截收尾（timing before/after 共用）：记录被拦截的打出（play_command + counter 刻，
    -- event_monitor「打出指令/触发反制」可命中）+ 触发反制事件钩子（register_hook 通用效果·
    -- 条件触发，发起者 = 被拦截的指令卡）+ 返回拦截结果
    local function onIntercepted()
        KARDS.TickLog:Push(self.TableID, card, { "play_command", "counter" }, {})
        if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
            KARDS.NodeParser.TriggerEventHooks(self.TableID, "counter", card)
        end
        return false
    end

    if timing == "before" then
        -- 生效前：先反制后生效，反制可先击杀目标使指令失效
        local args = triggerHooks()
        if args.intercepted then return onIntercepted() end
        applyEffect()
    else
        -- 生效后：先生效后反制，反制只能事后响应
        applyEffect()
        local args = triggerHooks()
        if args.intercepted then return onIntercepted() end
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

--[[
    激活反制（骨架，反制系统 M2）

    本方回合把手牌中的反制卡拖出手牌区外松手触发（客户端见 cl_battle_drag.lua，
    网络入口 KardsCounterToggle）：回合校验 → 统一操作钩子（activate_counter 本身
    可被反制拦截）→ 支付卡牌花费（隐藏扣除，仅本方可见，见 M4）→ 执行「激活时」
    效果链（反制开始点 = 激活时，其中的 trigger_function 拦截分支注册拦截钩子，
    见 sh_node_hooks.lua RegisterIntercept）→ 登记激活状态（KARDS.Counter）→
    记录 activate_counter 刻。

    @param player  string 发起玩家（须为本方回合方）
    @param card    table  反制卡牌句柄（须在手中）
    @param targets table|nil 效果目标卡牌句柄列表（base 节点 action 模板的 e 输入对象槽）
    @param opts    table|nil 可选扩展参数（specify 指定操作选择注入，同 SimPlayCard）
    @return boolean 是否激活成功
]]
function KARDS.Battle:SimActivateCounter(player, card, targets, opts)
    if not card then return false end
    -- 仅本方回合可手动激活（敌方回合的反制走拦截命中后自动打出，见 M5）
    local cur = self.CurTurnPlayer and self.CurTurnPlayer[self.TableID]
    if cur and cur ~= player then
        print("[Battle] SimActivateCounter 失败: 非本方回合")
        return false
    end
    -- 统一操作钩子（M1）：激活反制本身可被反制拦截
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "activate_counter", {
        player = player, card = card,
    }).intercepted then
        return self:InterceptOperation("activate_counter", card)
    end
    -- 花费校验与扣除（隐藏扣除：仅本方可见，敌方不可见，见 M4）
    local cost = card:GetCost()
    if not KARDS.CommandPoints:CanPay(self.TableID, player, cost) then
        print("[Battle] SimActivateCounter 失败: 指挥点不足（需要 " .. tostring(cost) .. "）")
        return false
    end
    KARDS.CommandPoints:Pay(self.TableID, player, cost)
    -- 执行「激活时」效果链（与 SimPlayCard 的 applyEffect 同构；反制卡开始点 = 激活时）
    if card.effect then
        KARDS.NodeParser.ExecuteEffect({
            tableID = self.TableID,
            initiatorCard = card,
            variables = card.effect.variables,
            dataConnections = card.effect.dataConnections,
            functions = card.effect.functions,
            battle = self,
            specify = opts and opts.specify,
        }, card, targets or {}, card.effect, nil, "激活时")
    end
    -- 登记激活状态（含隐藏花费计入，见 sh_counter.lua）
    KARDS.Counter:Activate(self.TableID, player, card, cost)
    KARDS.TickLog:Push(self.TableID, card, { "activate_counter" }, {})
    return true
end

--[[
    失活反制（骨架，反制系统 M2）

    本方回合再次把已激活的反制拖出手牌区外松手触发：注销该卡的拦截钩子与效果注册、
    返还已扣花费（隐藏池一并返还）、移出激活登记，并记录 activate_counter 刻
    （状态变化，沿用同名操作类型）。

    @param player string 发起玩家（须为本方回合方）
    @param card   table  反制卡牌句柄
    @return boolean 是否失活成功（未激活返回 false）
]]
function KARDS.Battle:SimDeactivateCounter(player, card)
    if not card then return false end
    -- 仅本方回合可手动失活
    local cur = self.CurTurnPlayer and self.CurTurnPlayer[self.TableID]
    if cur and cur ~= player then
        print("[Battle] SimDeactivateCounter 失败: 非本方回合")
        return false
    end
    if not KARDS.Counter:IsActive(self.TableID, card) then return false end
    KARDS.Counter:Deactivate(self.TableID, card, true)
    KARDS.TickLog:Push(self.TableID, card, { "activate_counter" }, {})
    return true
end

--[[
    反制自动打出（骨架，反制系统 M5）

    敌方操作命中已激活反制的拦截函数后（拦截回调 sh_node_hooks.lua RegisterIntercept
    判定成功），由回调调用本函数消费该反制：从所有者手牌移除、移出激活登记并公开
    此前隐藏的花费（KARDS.Counter:Fire → SubHidden）、通知牌桌实体按指令口径广播打出
    动画与激活时音效、记录反制刻。

    数据层不直接依赖牌桌实体，动画与实体清理经 SetCounterPlayCallback 注册的回调完成
    （见 sh_battle_combat.lua CounterPlayCallbacks / table_battledeck.lua OnCounterFired）。

    @param tableID string 牌桌唯一标识符
    @param card    table  反制卡牌句柄（须已激活）
    @param opArgs  table|nil 被拦截操作的上下文（保留，供后续扩展）
    @return boolean 是否成功（未激活返回 false）
]]
function KARDS.Battle:FireCounter(tableID, card, opArgs)
    if not card then return false end
    if not (KARDS.Counter and KARDS.Counter:IsActive(tableID, card)) then return false end
    local owner = card.GetOwner and card:GetOwner() or nil
    if owner then
        KARDS.Deck:RemoveFromHand(tableID, owner, card)
    end
    -- 移出激活登记 + 公开隐藏花费（SubHidden：敌方 HUD 随之补播扣减动画，见 M4）
    KARDS.Counter:Fire(tableID, card)
    -- 通知牌桌实体按指令口径广播打出动画 + 激活时音效
    local slot = (owner == "P1") and 1 or ((owner == "P2") and 2 or nil)
    if slot and self.NotifyCounterPlay then
        self:NotifyCounterPlay(card, slot)
    end
    -- 反制刻（触发反制）
    KARDS.TickLog:Push(tableID, card, { "counter" }, {})
    return true
end

-- 将士气伤害应用到总部卡并写时间刻（内部；moraleHits 来自 Deck:Draw / Deck:Mulligan）
-- 同时按总部开始点触发：受到伤害 / 防御变化（开始点 = 触发点；无匹配开始点不执行）
-- @param battle     KARDS.Battle 骨架实例（TableID / RunCardEffect 用）
-- @param moraleHits table|nil 士气伤害表 [player] = 本轮累计伤害
local function ApplyMoraleHits(battle, moraleHits)
    local tableID = battle.TableID
    for player, dmg in pairs(moraleHits or {}) do
        local hq = KARDS.Battlefield:GetHQ(tableID, player)
        if hq then
            hq:ApplyChange("defense", "decrease", dmg)
            -- 飘字（2026-08-14）：士气伤害 → 总部防御减少红色飘字
            KARDS.Battle:NotifyStatFXByTable(tableID, hq, "defense", -dmg, "decrease", "dmg")
            -- 士气伤害刻：发起者 = 受影响 = 总部卡（同对象，经受 take_damage）
            KARDS.TickLog:Push(tableID, hq, { "take_damage" }, { { hq, { "take_damage" }, "-" .. dmg } })
            -- 总部被摧毁判定（readme 7.1）：士气伤害不经属性变更通知，此处显式检查
            KARDS.Battlefield:CheckHQDestroyed(tableID, player)
            -- 总部开始点：受到伤害 / 防御变化（发起者 = 受影响 = 总部自身）
            battle:RunCardEffect(hq, { hq }, "受到伤害")
            battle:RunCardEffect(hq, { hq }, "防御变化")
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

-- 弃牌选择回调注册表：DiscardCallbacks[tableID] = function(player) -> card|nil end
-- 依赖倒置（同 DrawCallbacks）：SimDiscard 未收到具体卡与数值序数时（「让玩家选择」）
-- 经此回调进入实体层选择会话（table_discard.lua），回调内可协程挂起等待玩家点击手牌 +
-- 「确认」；返回选中的卡牌句柄（未选择/超时返回 nil，SimDiscard 放弃本次弃牌）。
KARDS.Battle.DiscardCallbacks = KARDS.Battle.DiscardCallbacks or {}

-- 注册弃牌选择回调（幂等，后注册覆盖先注册）
function KARDS.Battle:SetDiscardCallback(tableID, fn)
    self.DiscardCallbacks[tableID] = fn
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
    -- 统一操作钩子（M1）：抽取可被反制拦截（无主动卡，拦截时不抽牌）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "draw", { player = player }).intercepted then
        self:InterceptOperation("draw", nil)
        return {}
    end
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
        -- 开始点「抽取」：抽到的每张卡按「抽取」开始点执行其效果链（含爆牌弃掉的卡——
        -- 卡已离卡组即算抽到；无匹配开始点不执行）
        for _, card in ipairs(drawn) do
            self:RunCardEffect(card, {}, "抽取")
        end
        -- 开始点「弃牌」：爆牌卡（手牌已达上限未进手牌）按「弃牌」开始点执行效果链
        for card in pairs(overdrawnCards or {}) do
            self:RunCardEffect(card, {}, "弃牌")
        end
        local cb = self.DrawCallbacks and self.DrawCallbacks[self.TableID]
        if cb then cb(player, drawn, overdraw, overdrawnCards) end
    end
    ApplyMoraleHits(self, moraleHits)
    return drawn
end

--[[
    弃牌（从手牌弃掉，骨架）

    两种入口（2026-10-06 用户规格）：
      有数值 → 按数值序数弃牌：SimDiscard(player, nil, ordinal) 弃该玩家手牌第 ordinal 张；
      没有数值 → 让玩家选择：SimDiscard(player) 经 DiscardCallbacks（SetDiscardCallback）
        进入实体层选择会话（table_discard.lua 广播选择面板，玩家点击手牌 +「确认」后回传），
        回调内协程挂起，返回选中的卡牌句柄；无回调（骨架/测试）时放弃本次弃牌（返回 false）。
    card 非空时直接弃该卡（既有语义，测试兼容）。

    一个弃牌操作 = 一刻：发起者 = 被弃掉的手牌卡；从手牌移出（不入任何区，
    与卡组「弃掉」同语义），并按「弃牌」开始点执行该卡的效果链。
    统一操作钩子（M1）：弃牌走 opType = discard，可被反制卡 / 单位效果拦截
    （「友方手牌无法被弃掉」即注册 discard 的持续拦截，见 sh_node_hooks.lua RegisterIntercept），
    拦截时卡留在手牌、操作返回 false；拦截路径只推刻 + 触发事件钩子，单位侧无任何动画展示
    （2026-10-06 用户规格「单位的拦截不需要任何动画展示」）。
    注：爆牌（抽牌超手牌上限）不算弃牌，不走本入口（见 SimDraw 的 overdrawn 分支）。

    @param player  string 手牌所有者（序数定位 / 玩家选择均以该玩家的手牌为准）
    @param card    table|nil 被弃掉的手牌卡牌句柄（须在其所有者手牌中）；nil + ordinal 时由序数定位
    @param ordinal number|nil 手牌序数（1 起；仅 card 为空时生效）
    @return boolean 是否成功（被拦截 / 卡不在手牌 / 未选择 均返回 false）
]]
function KARDS.Battle:SimDiscard(player, card, ordinal)
    -- 数值序数路径：未直接给出卡但有数值 → 弃该玩家手牌第 ordinal 张
    if not card and ordinal then
        local hand = KARDS.Deck:GetHand(self.TableID, player) or {}
        card = hand[math.floor(ordinal)]
    end
    -- 玩家选择路径（无卡且无数值）：经依赖倒置回调进入实体层选择会话（可协程挂起）
    if not card then
        local chooser = self.DiscardCallbacks and self.DiscardCallbacks[self.TableID]
        if chooser then card = chooser(player) end
    end
    if not card then return false end
    -- 统一操作钩子（M1）：弃牌可被反制 / 单位效果拦截（主动卡 = 被弃掉的手牌卡）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "discard", {
        player = player, card = card,
    }).intercepted then
        return self:InterceptOperation("discard", card)
    end
    local owner = card:GetOwner()
    if not KARDS.Deck:RemoveFromHand(self.TableID, owner, card) then return false end
    KARDS.TickLog:Push(self.TableID, card, { "discard" }, {}, nil, { { owner, "hand", "-1" } })
    -- 计数变更事件（手牌 -1）：实体层订阅后补 SyncBattleCounts（与节点弃牌同款）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CountsChanged, { player = owner })
    -- 手牌弃牌飞出动画（2026-10-06 用户规格）：牌移到该方右槽，停留 1 秒后顺时针出场；
    -- 实体层订阅后按手牌实体播放（所有查看端动画一致）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.HandCardDiscarded,
        { player = owner, card = card })
    -- 开始点「弃牌」：被弃卡按其「弃牌」开始点执行效果链（与爆牌弃牌一致）
    self:RunCardEffect(card, {}, "弃牌")
    return true
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
    -- 据此广播补抽卡，客户端原位落手牌）；补抽的卡与 SimDraw 一致触发「抽取」开始点
    -- （丢弃的卡是洗回卡组而非弃牌，不触发「弃牌」开始点）
    if drawn and #drawn > 0 then
        for _, card in ipairs(drawn) do
            self:RunCardEffect(card, {}, "抽取")
        end
        local cb = self.DrawCallbacks and self.DrawCallbacks[self.TableID]
        if cb then cb(player, drawn) end
    end
    ApplyMoraleHits(self, moraleHits)
    return true
end
