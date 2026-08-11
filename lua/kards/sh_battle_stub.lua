--[[
    战斗系统骨架 (Battle Stub)

    在真实牌桌 / 卡组 / 手牌系统就绪前，用模拟操作验证时间刻与引擎钩子联动。
    操作入口即未来真实系统的「接缝」：真实战斗系统实现相同语义入口即可替换，
    时间刻记录与钩子触发逻辑复用。

    当前骨架语义（简化，仅为验证数据流）：
      SimPlayCard         打出指令（卡牌带 effect → 经 NodeParser.ExecuteEffect 执行节点效果；
                           无 effect 保留演示效果 = 每个目标 attack/defense +1）
      SimAttack           简单攻击（伤害 = 攻击力，触发 OnModifyDamage 修饰）
      SimEngage           交战：完整结算（攻击 + 反击 + 单位类型规则生效，readme 7.1/7.3）
      SimFight            战斗：双方互扣等同对方攻击的防御（无视单位类型规则，readme 7.1 注）
      SimDeploy           部署单位到本方支援阵线指定槽位（玩家选位，见 sh_battlefield.lua）
      SimJoinBattlefield  单位加入本方支援阵线首个空槽（效果拉入场，非玩家选位）
      SimJoinFrontline    单位直接加入前线首个空槽（效果拉入场，含阵营一致性作弊检测）
      SimMoveToFrontline  单位从支援阵线移动至前线（含阵营一致性作弊检测）
      SimRetreat          前线单位撤退回本方支援阵线
      SimRemoveFromField  被消灭 / 被移除（清空所在槽位；伤害结算后自动调用，见 AutoRemoveDead）
      SimSetupDeck        设置一方卡组（构筑）并对局开始洗牌一次（见 sh_deck.lua）
      SimDealOpeningHands 起手抽牌：先手 4 手牌 / 后手 5 手牌（重新调度前置）
      SimDraw             抽牌；卡组为空时触发士气伤害（总部防御减少，见 sh_deck.lua）
      SimMulligan         重新调度：弃牌随机插入卡组 + 抽等量替换（开局一次机会）
      SimConvert          转换：更换单位类型（readme 7.3）
      SimRepair           修复：恢复防御（readme 7.1 效果）
      SimControl          控制：转移归属 + 记录原归属（readme 7.1）
      SimUncontrol        解除控制：归属还原
      SimImmune           免疫：效果给予免疫状态（readme 7.2.1）
      SimUnimmune         解除免疫
      SimUnneutralize     解除抑制（readme 7.2.1）
      SimTriggerKeyword   触发关键字效果（亡计/倒计时等，效果由节点编辑器配置）
      SimReturnToHand     返回手牌（从场上回所有者手牌）
      SimSummonUnit       召唤单位到指定阵线（效果召唤）

    操作类型是数组（一刻一张卡可有多个操作类型，见 sh_ticklog.lua / 规划.md 第 3 节）：
      - 交战刻：发起者 {engage, attack, deal_damage}，受影响 {engage, take_damage, counterattack}
      - 战斗刻：发起者 {fight, attack, deal_damage}，受影响 {fight, take_damage, counterattack}

    流程按当前牌桌实例的推进时机（Instances[tableID].PushTiming）决定「效果生效」与「钩子触发」的先后：
      "before" 生效前：先触发反制钩子，再应用效果（拦截可先击杀目标）
      "after"  生效后：先应用效果，再触发反制钩子（效果已生效后才可反制）

    拆分说明（re.md B-H1：按职责拆分文件，对外 API 签名不变）：
      本文件保留战斗骨架核心（命名空间 / StartBattle / 回合流程 SimBeginTurn·SimEndTurn /
      判定查询函数 / 对局状态），其余职责拆分至：
        sh_battle_unit.lua   单位/战场操作（SimDeploy / SimMoveToFrontline / SimSummonUnit 等
                             与词条状态操作 SimSuppress / SimControl / SimImmune 等）
        sh_battle_card.lua   卡牌/卡组操作（SimPlayCard / SimDraw / SimSetupDeck / SimMulligan 等）
        sh_battle_combat.lua 攻击/伤害结算（SimAttack / SimEngage / SimFight / SimDealDamage
                             + CollectChecks 检查器注册制 + ResolveDamage 统一伤害结算）
      均挂 KARDS.Battle 命名空间，sh_node_parser.lua 执行器表经语义表调用的入口不变。
]]

KARDS = KARDS or {}
---@class Battle 战斗系统骨架
KARDS.Battle = KARDS.Battle or {}

-- 当前对局使用的牌桌 ID（由 StartBattle 指定；正式版每张牌桌唯一 ID，
-- 与 TickLog / EngineHooks / Varlib 的 tableID 隔离体系一致）
KARDS.Battle.TableID = "1"

--[[
    开始战斗：创建指定牌桌的时间刻实例 + 清空该牌桌引擎钩子注册表 + 战场布局 + 卡组空间

    @param tableID    string 牌桌唯一标识符（多牌桌隔离的键）
    @param players    table|nil 玩家标识列表（缺省 {"P1", "P2"}）
    @param timing     string|nil 刻度推进时机（"before" 生效前 / "after" 生效后）
    @param firstPlayer string|nil 先手玩家（缺省 players[1]；先手 4 手牌、后手 5 手牌，见 sh_deck.lua）
]]
function KARDS.Battle:StartBattle(tableID, players, timing, firstPlayer)
    self.TableID = tableID or "1"
    KARDS.TickLog:Create(self.TableID, timing)
    KARDS.EngineHooks.ClearTable(self.TableID)
    -- 注册式效果框架清理：统一清除本桌全部注册条目与每桌清理回调。
    -- （KeepTriggers / EventHooks / AlwaysHooks 已迁入 EffectRegistry（re.md B-H2），
    --  PendingTurns 经 ClearCallbacks 挂清理，见 sh_effect_registry.lua；按牌桌隔离，
    --  与引擎钩子 / Varlib 的 tableID 体系一致）
    KARDS.EffectRegistry.Clear(self.TableID)
    self.Players = players or { "P1", "P2" }
    -- 战场布局：双方支援阵线（含 20 防御总部）+ 空前线（见 sh_battlefield.lua）
    KARDS.Battlefield:Create(self.TableID, self.Players)
    -- 卡组空间：空卡组 / 空手牌 / 先手后手起手数（见 sh_deck.lua）
    KARDS.Deck:Create(self.TableID, self.Players, firstPlayer)
    -- 指挥点：开局双方 0 槽（点数 0，开场动画/重新调度期间）；先手初始补给（+1 槽
    -- 补满）由牌桌会话层 StartFirstTurn 执行，回合开始 +1 槽至 12（见 sh_command_point.lua）
    KARDS.CommandPoints:Create(self.TableID, self.Players, firstPlayer)
    -- 回合计数（SimBeginTurn +1；供"刚部署/加入的单位本回合不能行动"判定，readme 7.2.2 闪击）
    self.TurnNumbers = self.TurnNumbers or {}
    self.TurnNumbers[tableID] = 0
    -- 当前回合玩家（turn「使」分支推进回合用；SimBeginTurn 记录，随战斗重置）
    self.CurTurnPlayer = self.CurTurnPlayer or {}
    self.CurTurnPlayer[tableID] = nil
    -- 入场回合记录：EnteredTurns[tableID][card] = 入场时的回合数（闪击规则判定）
    self.EnteredTurns = self.EnteredTurns or {}
    self.EnteredTurns[tableID] = {}
    -- 词条效果与限制状态表：KeywordStates[tableID]（readme 7.2.1 效果能力 / 7.2.2 战斗词条能力，
    -- 战斗骨架以自身状态表承载需跨刻追踪的词条状态，卡牌对象本身只读，依赖倒置保持不变；
    -- 状态字段 + 读写接口 + 联动规则按词条域分模块（re.md B-M1，见 sh_keyword_states.lua），
    -- 本处经 KARDS.KeywordStates.New 按模块声明的字段创建空状态表）
    self.KeywordStates = self.KeywordStates or {}
    self.KeywordStates[tableID] = KARDS.KeywordStates.New()
    -- 联机防作弊与同步：客户端视图 + 实时校验 + 暂停/全量同步（readme 四，见 sh_sync_stub.lua）
    KARDS.NetSync:InitTable(self.TableID, self.Players)
end

--[[
    回合开始（骨架，指挥点入口，readme 7.1 指挥点(槽)）

    每回合获得 1 个指挥点槽（自然上限 12），指挥点调整至与槽相等；
    记录 turn_begin 刻（发起者 = 该玩家总部）。

    @param player string 玩家标识
    @return boolean 是否成功（指挥点实例不存在返回 false）
]]
function KARDS.Battle:SimBeginTurn(player)
    if not KARDS.CommandPoints:Get(self.TableID) then
        print("[Battle] SimBeginTurn 失败: 指挥点实例不存在（需先 StartBattle）")
        return false
    end
    KARDS.CommandPoints:AddSlot(self.TableID, player)
    KARDS.CommandPoints:BeginTurn(self.TableID, player)
    -- 回合数 +1（供"刚部署/加入的单位本回合不能行动"判定，readme 7.2.2 闪击）
    self.TurnNumbers[self.TableID] = (self.TurnNumbers[self.TableID] or 0) + 1
    local hq = KARDS.Battlefield:GetHQ(self.TableID, player)
    -- 词条每回合效果（readme 7.2.2）：
    --   动员 mobilize：动员单位每回合开始时获得 +1+1，受到伤害后失去（MobilizeLost）
    --   伏击 ambush / 攻击次数（奋战 frenzy）：本回合状态重置
    local st = self.KeywordStates[self.TableID]
    if st then
        local function boost(unit)
            if unit and unit:GetType() == "unit"
                and self:HasActiveKeyword(self.TableID, unit, "mobilize")
                and not KARDS.KeywordStates.Mobilize.IsLost(st, unit) then
                unit:ApplyChange("attack", "increase", 1)
                unit:ApplyChange("defense", "increase", 1)
                -- stat_change 刻：受影响分条标注变化属性（attack/defense，供 event_monitor select_4 过滤）
                KARDS.TickLog:Push(self.TableID, unit, { "stat_change" },
                    { { unit, { "stat_change" }, "+1", "attack" }, { unit, { "stat_change" }, "+1", "defense" } })
            end
        end
        for _, p in ipairs(self.Players) do
            local sup = KARDS.Battlefield:GetSupport(self.TableID, p)
            if sup then
                for i = 1, KARDS.Battlefield.SLOT_COUNT do boost(sup[i]) end
            end
        end
        local fl = KARDS.Battlefield:GetFrontline(self.TableID)
        if fl then
            for i = 1, KARDS.Battlefield.SLOT_COUNT do boost(fl[i]) end
        end
        KARDS.KeywordStates.ResetTurn(st) -- 伏击已用 / 攻击次数每回合重置（readme 7.2.2）
    end
    KARDS.TickLog:Push(self.TableID, hq, { "turn_begin" }, {})
    -- 当前回合玩家记录（turn「使」分支推进回合用；开始回合的玩家即当前回合玩家）
    self.CurTurnPlayer = self.CurTurnPlayer or {}
    self.CurTurnPlayer[self.TableID] = player
    -- 事件钩子（register_hook 通用效果·条件触发）：回合开始事件（发起者 = 本方总部）
    if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
        KARDS.NodeParser.TriggerEventHooks(self.TableID, "turn_begin", hq)
    end
    -- 跨刻挂起（turn「等待」）：回合开始时间刻 → 推进计数 / 达标恢复效果执行
    if KARDS.NodeParser and KARDS.NodeParser.ResumeTurnNodes then
        KARDS.NodeParser.ResumeTurnNodes(self.TableID, player, "turn_begin")
    end
    -- 保持触发（trigger_function 保持触发）：目标实体拥有者 == 当前回合玩家时执行注册的函数
    if KARDS.NodeParser and KARDS.NodeParser.TriggerKeepTriggers then
        KARDS.NodeParser.TriggerKeepTriggers(self.TableID, player)
    end
    return true
end

--[[
    单位本回合能否行动（readme 7.2.2 闪击；readme 7.2.1 被压制；规则补充）

    被压制的单位不能移动或攻击（readme 7.2.1）；
    单位刚部署或加入时，本回合还不能行动（移动/攻击），除非具有"闪击"。
    未入场的单位（骨架模拟直接行动，如测试中直接攻击）不受此限制。

    @param tableID string 牌桌唯一标识符
    @param card    table 单位卡牌句柄
    @return boolean 能否行动
]]
function KARDS.Battle:CanUnitAct(tableID, card)
    local st = self.KeywordStates and self.KeywordStates[tableID]
    if KARDS.KeywordStates.Suppression.Is(st, card) then return false end -- 被压制：不能移动或攻击（readme 7.2.1）
    local entered = self.EnteredTurns[tableID] and self.EnteredTurns[tableID][card]
    if entered == nil then return true end -- 未入场（模拟直接行动）不检查
    if entered == (self.TurnNumbers[tableID] or 0) and not card:HasKeyword("blitz") then
        return false -- 本回合刚入场且无闪击
    end
    return true
end

--[[
    轰炸机攻击拦截判定（readme 7.3 战斗机规则，拦截定义明确）

    当一个阵营阵线上有战斗机存在时，另一阵营的轰炸机无法攻击该阵线除战斗机以外的目标；
    若该阵线存在被守护（guarded 词条）的战斗机，拦截完全封锁：轰炸机无法攻击该阵线任何目标。
    目标不在场上（骨架模拟直接行动）不拦截。

    @param attacker table 攻击方卡牌句柄
    @param defender table 被攻击方卡牌句柄
    @return boolean 是否允许攻击
]]
function KARDS.Battle:CanBomberAttackTarget(attacker, defender)
    if attacker:GetUnitType() ~= "bomber" then return true end -- 仅轰炸机受拦截
    local zone, owner = KARDS.Battlefield:FindCardZone(self.TableID, defender)
    if not zone then return true end -- 目标不在场上（模拟直接行动）不拦截
    local hasFighter, hasGuardedFighter = false, false
    for _, u in ipairs(KARDS.Battlefield:GetZoneUnits(self.TableID, zone, owner)) do
        if u:GetType() == "unit" and u:GetUnitType() == "fighter" then
            hasFighter = true
            if u:HasKeyword("guarded") then hasGuardedFighter = true end
        end
    end
    if not hasFighter then return true end
    if hasGuardedFighter then return false end -- 被守护战斗机：完全封锁该阵线
    return defender:GetUnitType() == "fighter" -- 普通战斗机拦截：只能攻击战斗机
end

--[[
    词条生效判定（readme 7.2.1 抑制）

    被抑制的卡牌失去所有关键词和效果 → 战斗规则查询一律经本入口，
    被抑制单位视为无任何词条（属性重置由卡牌/效果配置）。

    @param tableID string 牌桌唯一标识符
    @param card    table 卡牌句柄
    @param id      string 词条 id
    @return boolean 词条是否生效
]]
function KARDS.Battle:HasActiveKeyword(tableID, card, id)
    local st = self.KeywordStates and self.KeywordStates[tableID]
    if KARDS.KeywordStates.Inhibit.Is(st, card) then return false end
    -- 免疫：效果给予的状态（SimImmune）与卡面词条等效；抑制时不生效（上方已拦截）
    if KARDS.KeywordStates.Immune.Is(st, card) and id == "immune" then return true end
    return card:HasKeyword(id)
end

-- 取带数值词条的值（情报 X / 重甲 X）；被抑制或无该词条返回缺省值
-- @param tableID string 牌桌唯一标识符
-- @param card    table 卡牌句柄
-- @param id      string 带数值词条 id（词条数组项为 { 词条id, 数值 }）
-- @param default number|nil 缺省值
-- @return number
function KARDS.Battle:GetKeywordValue(tableID, card, id, default)
    local st = self.KeywordStates and self.KeywordStates[tableID]
    if KARDS.KeywordStates.Inhibit.Is(st, card) then return 0 end
    for _, kw in ipairs(card:GetKeywords()) do
        if type(kw) == "table" and kw[1] == id then return kw[2] end
    end
    return default
end

--[[
    单位有效行动花费（readme 7.2.2 隐蔽）

    隐蔽单位揭示前行动花费为 1；其余单位返回卡牌自身的行动花费。
    应用入口：SimAttack / SimEngage / SimMoveToFrontline（支付行动花费处）。

    @param tableID string 牌桌唯一标识符
    @param card    table 单位卡牌句柄
    @return number 有效行动花费
]]
function KARDS.Battle:GetActionCost(tableID, card)
    local st = self.KeywordStates and self.KeywordStates[tableID]
    if KARDS.KeywordStates.Hidden.Is(st, card) then return 1 end
    return card:GetActionCost()
end

--[[
    攻击次数判定（readme 7.2.2 奋战）

    奋战单位一回合中可以攻击两次，其余单位一回合一次；每回合重置（SimBeginTurn）。

    @param attacker table 单位卡牌句柄
    @return boolean 本回合还可攻击
]]
function KARDS.Battle:CanUnitAttackNow(attacker)
    local st = self.KeywordStates and self.KeywordStates[self.TableID]
    local n = KARDS.KeywordStates.Attack.Get(st, attacker)
    local limit = self:HasActiveKeyword(self.TableID, attacker, "frenzy") and 2 or 1
    return n < limit
end

--[[
    词条目标限制判定（readme 7.2.1 被守护 / 7.2.2 守护·烟幕；拦截判定见 CanBomberAttackTarget）

      - 被守护 guarded：被守护单位只能被轰炸机和炮兵攻击
      - 守护 guard：与守护单位相邻的非守护单位，无法被轰炸机和炮兵以外的单位攻击
      - 烟幕 smoke：烟幕单位（未破）无法被敌方单位攻击
    目标不在场上（骨架模拟直接行动）时守护/烟幕不限制（无相邻关系 / 未入场）。

    @param attacker table 攻击方卡牌句柄
    @param defender table 被攻击方卡牌句柄
    @return boolean 是否允许攻击
]]
function KARDS.Battle:CanAttackTarget(attacker, defender)
    local tableID = self.TableID
    -- 被守护 guarded（readme 7.2.1）：只能被轰炸机和炮兵攻击
    if self:HasActiveKeyword(tableID, defender, "guarded") then
        local ut = attacker:GetUnitType()
        if ut ~= "bomber" and ut ~= "artillery" then return false end
    end
    -- 守护 guard（readme 7.2.2）：与守护单位相邻的非守护单位，仅轰炸机/炮兵可攻击
    local zone, owner = KARDS.Battlefield:FindCardZone(tableID, defender)
    if zone then
        local line
        if zone == "support" then
            line = KARDS.Battlefield:GetSupport(tableID, owner)
        else
            line = KARDS.Battlefield:GetFrontline(tableID)
        end
        local idx = nil
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            if line[i] == defender then idx = i break end
        end
        if idx and not self:HasActiveKeyword(tableID, defender, "guard") then
            for _, a in ipairs({ idx - 1, idx + 1 }) do
                if a >= 1 and a <= KARDS.Battlefield.SLOT_COUNT and line[a]
                    and self:HasActiveKeyword(tableID, line[a], "guard") then
                    local ut = attacker:GetUnitType()
                    if ut ~= "bomber" and ut ~= "artillery" then return false end
                    break
                end
            end
        end
    end
    -- 烟幕 smoke（readme 7.2.2）：烟幕单位（未破）无法被敌方单位攻击
    local st = self.KeywordStates and self.KeywordStates[tableID]
    if self:HasActiveKeyword(tableID, defender, "smoke") and not KARDS.KeywordStates.Smoke.IsBroken(st, defender) then
        return false
    end
    return true
end

-- 当前对局是否已停止（作弊后为 true）
function KARDS.Battle:IsStopped()
    return KARDS.Battlefield:IsStopped(self.TableID)
end

-- 当前对局的作弊方（未作弊返回 nil）
function KARDS.Battle:GetCheater()
    return KARDS.Battlefield:GetCheater(self.TableID)
end

--[[
    回合结束（骨架，readme 7.2.2 倒计时 X）

    倒计时单位每回合结束后 -1（记录 countdown 刻，change "-1"）；
    归零时触发事件（事件效果由节点编辑器配置）并移除单位（触发刻 countdown+trigger + 移除刻 remove）。
    （正式版回合结束还处理压制移除等，归骨架后续扩展）

    @param player string 当前结束回合的玩家（保留参数，正式版扩展用）
    @return boolean 是否成功（词条状态表不存在返回 false）
]]
function KARDS.Battle:SimEndTurn(player)
    local st = self.KeywordStates and self.KeywordStates[self.TableID]
    if not st then
        print("[Battle] SimEndTurn 失败: 词条状态表不存在（需先 StartBattle）")
        return false
    end
    -- 收集场上所有单位（双方支援阵线 + 前线）
    local units = {}
    local function scan(line)
        if not line then return end
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            local u = line[i]
            if u and u:GetType() == "unit" then table.insert(units, u) end
        end
    end
    for _, p in ipairs(self.Players) do
        scan(KARDS.Battlefield:GetSupport(self.TableID, p))
    end
    scan(KARDS.Battlefield:GetFrontline(self.TableID))
    -- 回合结束刻记录（发起者 = 该玩家总部，对齐 SimBeginTurn 记录 turn_begin 刻的模式，
    -- 供 event_monitor「回合·结束」与 register_hook 回合结束事件钩子匹配；
    -- 置于倒计时之前，保证倒计时（countdown）刻为回合结束后的最后一刻，ticklog_test 场景 12 ⑮ 断言）
    local hq = KARDS.Battlefield:GetHQ(self.TableID, player)
    if hq then
        KARDS.TickLog:Push(self.TableID, hq, { "turn_end" }, {})
    end
    -- 倒计时 X：每回合结束后 -1，归零触发事件并移除
    for _, unit in ipairs(units) do
        if self:HasActiveKeyword(self.TableID, unit, "countdown") then
            local cur = (KARDS.KeywordStates.Countdown.Get(st, unit) or self:GetKeywordValue(self.TableID, unit, "countdown", 0)) - 1
            if cur <= 0 then
                KARDS.KeywordStates.Countdown.Clear(st, unit)
                KARDS.TickLog:Push(self.TableID, unit, { "countdown", "trigger" }, { { unit, { "remove" } } })
                self:SimRemoveFromField(unit, "remove")
            else
                KARDS.KeywordStates.Countdown.Set(st, unit, cur)
                KARDS.TickLog:Push(self.TableID, unit, { "countdown" }, { { unit, { "countdown" }, "-1" } })
            end
        end
    end
    -- 事件钩子（register_hook 通用效果·条件触发）：回合结束事件（发起者 = 本方总部）
    if hq and KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
        KARDS.NodeParser.TriggerEventHooks(self.TableID, "turn_end", hq)
    end
    -- 跨刻挂起（turn「等待」）：回合结束时间刻 → 推进计数 / 达标恢复效果执行
    if KARDS.NodeParser and KARDS.NodeParser.ResumeTurnNodes then
        KARDS.NodeParser.ResumeTurnNodes(self.TableID, player, "turn_end")
    end
    return true
end
