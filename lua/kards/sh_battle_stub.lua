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
      SimConvert          转换：整体换卡为「转换目标卡」（readme 7.3；无目标卡时仅记录 convert 刻）
      SimRepair           修复：恢复防御（readme 7.1 效果）
      SimControl          控制：转移归属 + 记录原归属（readme 7.1）
      SimUncontrol        解除控制：归属还原
      SimImmune           免疫：效果给予免疫状态（readme 7.2.1）
      SimUnimmune         解除免疫
      SimUnneutralize     解除抑制（readme 7.2.1）
      SimTriggerKeyword   触发关键字效果（亡计/倒计时等，效果由节点编辑器配置）
      SimReturnToHand     返回手牌（从场上回所有者手牌）
      SimSummonUnit       召唤单位到指定阵线（效果召唤）
      SimVeteran          升为老兵：套用老兵外观 + 触发「升级」开始点（readme 7.2.1）

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
    -- 反制管理器清理：新对局开始时清除本桌激活反制登记（防复用同一 tableID 时残留，见 sh_counter.lua）
    if KARDS.Counter and KARDS.Counter.ClearTable then
        KARDS.Counter:ClearTable(self.TableID)
    end
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
    统一操作被拦截的收尾（2026-08-15 反制系统 M1）

    任一操作在入口触发 OnBeforeOperation 且被反制拦截时，由调用方转入本函数：
    记录被拦截的操作刻（有主动卡时，发起者 = 主动卡，操作类型 = 该操作类型 + counter）
    并触发反制事件钩子（event_monitor「触发反制」可命中），返回 false 表示操作未生效。
    card 为 nil 的操作（抽取 / 回合开始等无主动卡操作）只触发事件钩子不推刻。

    @param opType string 操作类型（KARDS.TickLog.OpTypes 键）
    @param card   table|nil 该操作的主动卡（无主动卡可省略）
    @return boolean 恒 false（操作未生效）
]]
function KARDS.Battle:InterceptOperation(opType, card)
    if card then
        KARDS.TickLog:Push(self.TableID, card, { opType, "counter" }, {})
    end
    if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
        KARDS.NodeParser.TriggerEventHooks(self.TableID, "counter", card)
    end
    return false
end

--[[
    攻防 +N+N 词条效果（山地 / 动员共用）：应用属性变化 + 飘字 + stat_change 刻 + 属性变化音效

    山地（mountain，sh_battle_unit.lua ApplyEnterKeywords）：每有一个其他友方山地单位，
    获得一次 +1+1（amount = 友方山地单位数）；动员（mobilize，SimBeginTurn）：每回合
    开始获得 +1+1（amount = 1）。两者同构，共享本 helper。挂 KARDS.Battle 命名空间
    供 sh_battle_unit.lua 调用（加载顺序：stub 先于 unit，见 sh_card_editor_loader.lua）。

    @param self   KARDS.Battle 骨架实例
    @param card   table 单位卡牌句柄
    @param amount number 增加次数（每次 attack/defense +1）
]]
function KARDS.Battle.ApplyStatPairBoost(self, card, amount)
    for _ = 1, amount do
        card:ApplyChange("attack", "increase", 1)
        card:ApplyChange("defense", "increase", 1)
    end
    -- 飘字（2026-08-14）：词条 +1+1 → 攻防增加绿色飘字
    self:NotifyStatFX(card, "attack", amount, "increase", "other")
    self:NotifyStatFX(card, "defense", amount, "increase", "other")
    -- stat_change 刻：受影响分条标注变化属性（attack/defense，供 event_monitor select_4 过滤）
    KARDS.TickLog:Push(self.TableID, card, { "stat_change" },
        { { card, { "stat_change" }, "+" .. amount, "attack" }, { card, { "stat_change" }, "+" .. amount, "defense" } })
    -- 2026-08-13（stat_change.ogg 播放时机）：词条 +1+1 → 触发属性变化音效
    -- （客户端播 stat_change.ogg，见 sh_battle_combat.lua NotifyStatSound）
    self:NotifyStatSound(self.TableID)
end

--[[
    回合边界事件收尾（SimBeginTurn / SimEndTurn 共用）：触发回合事件钩子 + 推进跨刻挂起

    register_hook 条件触发的回合开始/结束事件（发起者 = 本方总部）与 turn「等待」
    跨刻挂起推进（ResumeTurnNodes）在两处逐字重复，提取本函数；hq 为 nil 时由调用
    方决定是否调用（SimEndTurn 原判定 hq 存在才触发，见调用处）。

    @param self      KARDS.Battle 骨架实例
    @param tableID   string 牌桌唯一标识符
    @param player    string 当前回合玩家
    @param hq        table 总部卡（发起者）
    @param eventName string 事件名（"turn_begin" / "turn_end"）
]]
local function FireTurnEdge(self, tableID, player, hq, eventName)
    -- 事件钩子（register_hook 通用效果·条件触发）：回合开始/结束事件（发起者 = 本方总部）
    if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
        KARDS.NodeParser.TriggerEventHooks(tableID, eventName, hq)
    end
    -- 跨刻挂起（turn「等待」）：回合开始/结束时间刻 → 推进计数 / 达标恢复效果执行
    if KARDS.NodeParser and KARDS.NodeParser.ResumeTurnNodes then
        KARDS.NodeParser.ResumeTurnNodes(tableID, player, eventName)
    end
end

--[[
    回合开始（骨架，指挥点入口，readme 7.1 指挥点(槽)）

    每回合获得 1 个指挥点槽（自然上限 12），指挥点调整至与槽相等；
    记录 turn_begin 刻（发起者 = 该玩家总部）。

    @param player string 玩家标识
    @return boolean 是否成功（指挥点实例不存在返回 false）
]]
function KARDS.Battle:SimBeginTurn(player)
    -- 统一操作钩子（M1）：回合开始可被反制拦截（无主动卡，拦截时不推刻）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "turn_begin", { player = player }).intercepted then
        return self:InterceptOperation("turn_begin", nil)
    end
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
                -- 动员词条 +1+1（飘字/刻/音效见 ApplyStatPairBoost，与山地共用）
                KARDS.Battle.ApplyStatPairBoost(self, unit, 1)
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

    -- 开始点「在场」：回合开始时，场上（支援阵线 + 前线）所有单位与总部
    -- 按「在场」开始点执行效果链（开始点 = 触发点；无匹配开始点不执行）。
    -- 与动员/伏击刷新同点（ResetTurn 之后），位于 turn_begin 刻与回合边界事件之前。
    for _, p in ipairs(self.Players) do
        local sup = KARDS.Battlefield:GetSupport(self.TableID, p)
        if sup then
            for i = 1, KARDS.Battlefield.SLOT_COUNT do
                if sup[i] then self:RunCardEffect(sup[i], {}, "在场") end
            end
        end
        local hqP = KARDS.Battlefield:GetHQ(self.TableID, p)
        if hqP then self:RunCardEffect(hqP, { hqP }, "在场") end
    end
    local fl = KARDS.Battlefield:GetFrontline(self.TableID)
    if fl then
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            if fl[i] then self:RunCardEffect(fl[i], {}, "在场") end
        end
    end

    KARDS.TickLog:Push(self.TableID, hq, { "turn_begin" }, {})
    -- 当前回合玩家记录（turn「使」分支推进回合用；开始回合的玩家即当前回合玩家）
    self.CurTurnPlayer = self.CurTurnPlayer or {}
    self.CurTurnPlayer[self.TableID] = player
    -- 回合边界事件收尾：回合开始事件钩子 + 跨刻挂起推进（发起者 = 本方总部，见 FireTurnEdge）
    FireTurnEdge(self, self.TableID, player, hq, "turn_begin")
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
    @return boolean, string|nil 能否行动；失败时第二返回值为原因
            （"单位被压制，本回合不能行动" / "单位入场时不能立即行动"，2026-08-12 区分）
]]
function KARDS.Battle:CanUnitAct(tableID, card)
    local st = self.KeywordStates and self.KeywordStates[tableID]
    if KARDS.KeywordStates.Suppression.Is(st, card) then
        return false, "单位被压制，本回合不能行动" -- 被压制：不能移动或攻击（readme 7.2.1）
    end
    local entered = self.EnteredTurns[tableID] and self.EnteredTurns[tableID][card]
    if entered == nil then return true end -- 未入场（模拟直接行动）不检查
    if entered == (self.TurnNumbers[tableID] or 0) and not card:HasKeyword("blitz") then
        return false, "单位入场时不能立即行动" -- 本回合刚入场且无闪击（readme 7.2.2）
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
    -- 统一操作钩子（M1）：回合结束可被反制拦截（无主动卡，拦截时不推刻）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "turn_end", { player = player }).intercepted then
        return self:InterceptOperation("turn_end", nil)
    end
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
    -- 事实变量一回合覆盖还原（2026-10-04 用户规格）：本回合内被「设置变量」节点改写的
    -- 系统事实变量（Battle.* / Special.*，如「友方有老兵单位」）在此还原为覆盖前的值
    -- （即当前事实）。置于倒计时与回合结束事件之前，令回合结束效果设置的新覆盖归属下一回合。
    if KARDS.VarLib and KARDS.VarLib.ClearFactOverrides then
        KARDS.VarLib.ClearFactOverrides(self.TableID)
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
                -- 2026-08-13：倒计时数值变化 → 刷新词条串（客户端倒计时图标数字跟随）
                self:NotifyStatsChanged(unit)
            end
        end
    end
    -- 回合边界事件收尾：回合结束事件钩子 + 跨刻挂起推进（hq 为 nil 时跳过，对齐原判定）
    if hq then
        FireTurnEdge(self, self.TableID, player, hq, "turn_end")
    end
    -- 反制到点自动失活（M2.3）：该玩家回合结束时，已跨过一个完整敌方回合的激活反制
    -- 自动失活且不返还花费（跨回合存续口径见 D4，见 sh_counter.lua OnTurnEnd）
    if KARDS.Counter and KARDS.Counter.OnTurnEnd then
        KARDS.Counter:OnTurnEnd(self.TableID, player)
    end
    return true
end

--[[
    按桌清理数据层全部按桌状态（2026-09-13 规划 S3/R6 总入口）：
    此前牌桌销毁清理清单散落在实体层 table_cleanup.lua DestroyTableState，且遗漏
    PincerPartners / 七张回调注册表（DrawCallbacks / DiscardCallbacks + 属性事件五张）/
    EngineHooks.Registry / TickLog 激活视图，造成卡键强引用卡牌对象阻止 GC、
    注册闭包强引用牌桌实体、ActiveTableID 悬空指向已销毁桌。现由数据层提供单一
    入口，实体层销毁时调用一次，幂等。

    覆盖清单（按加载顺序各模块均已加载，缺失成员做 nil 守卫，测试环境安全）：
      战斗骨架自有：KeywordStates / TurnNumbers / EnteredTurns / CurTurnPlayer /
                    PincerPartners / DrawCallbacks / DiscardCallbacks / 属性事件回调五张
                    （StatsChanged / StatSound / StatFX / Sound / Control，
                     见 sh_battle_card.lua / sh_battle_combat.lua）
      关联子系统：VarLib / EffectRegistry / Deck / Battlefield / BattlefieldCenter /
                  CommandPoints / TickLog（实例 + 激活视图复位）/ EngineHooks /
                  NetSync
    不含：渲染层 KARDS.BattleRender:DestroyTable（实体层专属）、全服对战锁
      （KARDS.FormalBattleLock 属实体会话层，由实体层自行释放）。

    @param tableID string 牌桌唯一标识符
]]
function KARDS.Battle:ClearTableState(tableID)
    if not tableID then return end
    -- 战斗骨架自有按桌表
    if self.KeywordStates then self.KeywordStates[tableID] = nil end
    if self.TurnNumbers then self.TurnNumbers[tableID] = nil end
    if self.EnteredTurns then self.EnteredTurns[tableID] = nil end
    if self.CurTurnPlayer then self.CurTurnPlayer[tableID] = nil end
    if self.PincerPartners then self.PincerPartners[tableID] = nil end
    if self.DrawCallbacks then self.DrawCallbacks[tableID] = nil end
    if self.DiscardCallbacks then self.DiscardCallbacks[tableID] = nil end
    -- 六个按桌回调注册表：注册闭包强引用牌桌实体，必须在销毁时断引用
    for _, regName in ipairs({
        "StatsChangedCallbacks",
        "StatSoundCallbacks",
        "StatFXCallbacks",
        "SoundCallbacks",
        "ControlCallbacks",
    }) do
        if self[regName] then self[regName][tableID] = nil end
    end
    -- 关联子系统
    if KARDS.VarLib and KARDS.VarLib.Destroy then
        KARDS.VarLib.Destroy(tableID)
    end
    if KARDS.EffectRegistry and KARDS.EffectRegistry.Clear then
        KARDS.EffectRegistry.Clear(tableID)
    end
    -- 反制管理器：本桌激活反制登记清理（防卡键强引用卡牌对象阻止 GC，见 sh_counter.lua）
    if KARDS.Counter and KARDS.Counter.ClearTable then
        KARDS.Counter:ClearTable(tableID)
    end
    if KARDS.Deck and KARDS.Deck.Instances then
        KARDS.Deck.Instances[tableID] = nil
    end
    if KARDS.Battlefield and KARDS.Battlefield.Instances then
        KARDS.Battlefield.Instances[tableID] = nil
    end
    if KARDS.BattlefieldCenter and KARDS.BattlefieldCenter.Reset then
        KARDS.BattlefieldCenter:Reset(tableID)
    end
    if KARDS.CommandPoints and KARDS.CommandPoints.Instances then
        KARDS.CommandPoints.Instances[tableID] = nil
    end
    -- TickLog：实例移除；若本桌是当前激活桌，激活视图复位为无激活（防悬空指向）
    if KARDS.TickLog then
        if KARDS.TickLog.Instances then KARDS.TickLog.Instances[tableID] = nil end
        if KARDS.TickLog.ActiveTableID == tableID then
            KARDS.TickLog:SetActive(nil)
        end
    end
    -- EngineHooks：本桌全部引擎钩子注销（StartBattle 会 ClearTable 重建，
    -- 销毁路径此前漏调，注册表闭包随桌残留）
    if KARDS.EngineHooks and KARDS.EngineHooks.ClearTable then
        KARDS.EngineHooks.ClearTable(tableID)
    end
    if KARDS.NetSync and KARDS.NetSync.Instances then
        KARDS.NetSync.Instances[tableID] = nil
    end
end
