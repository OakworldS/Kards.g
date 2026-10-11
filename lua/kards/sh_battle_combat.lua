--[[
    战斗系统骨架·攻击/伤害结算域 (Battle Combat)

    从 sh_battle_stub.lua 拆分并重构（re.md B-H1）：
      - 攻击前置检查提取为「阶段流水线」collectChecks / RunChecks——检查项可注册、
        可组合（词条检查按 KeywordStates 注册），新增词条无需在顺序 if 链上找插入点；
      - 攻击/交战/伤害共用的伤害结算提取 resolveDamage（伤害修饰钩子 / 重甲 / 免疫 /
        动员失去统一收口）；
      - 伏击反击结算提取 ResolveAmbush（SimAttack / SimEngage 共用，readme 7.2.2 伏击）。
    均挂 KARDS.Battle 命名空间（sh_battle_stub.lua 先加载声明命名空间），
    对外 API 签名不变（SimAttack / SimEngage / SimFight / SimDealDamage）。

    本域依赖：
      - 判定查询函数（CanUnitAct / CanBomberAttackTarget / CanAttackTarget /
        CanUnitAttackNow / GetActionCost / GetKeywordValue / HasActiveKeyword，见 sh_battle_stub.lua）
      - SimReveal / SimRemoveFromField（见 sh_battle_unit.lua，运行时方法查找，加载顺序无关）

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_battle_stub.lua 之后）
=======================================================================================
]]

KARDS = KARDS or {}
KARDS.Battle = KARDS.Battle or {}

-- 回调注册表工厂（B3：StatsChanged/StatSound/StatFX/Sound 4 套同构注册表收敛为三件套；
-- 规划.md 第四章：数据层新代码统一走本工厂）
KARDS.Callbacks = KARDS.Callbacks or {}

--[[
    创建一套「回调注册表三件套」（XCallbacks[tableID] = fn + Set + Notify）

    注册表字段挂在 KARDS.Battle 命名空间（既有代码直接访问该表）：
      - SetXxxCallback(tableID, fn)  注册回调（幂等，后注册覆盖先注册）
      - NotifyXxx(...) 触发回调（无回调注册时静默，测试环境安全）
      - 可选 byTable 变体：NotifyXxxByTable(tableID, ...) 供无 battle 实例的
        节点效果路径使用（ExecuteEffect ctx 必有 tableID）
      - 可选 after 钩子：回调之后执行（如总部被摧毁判定收口）

    @param opts table 工厂选项：
        registry string 注册表字段名（挂 KARDS.Battle，如 "StatsChangedCallbacks"）
        setter   string 注册方法名（挂 KARDS.Battle，如 "SetStatsChangedCallback"）
        notify   string 触发方法名（挂 KARDS.Battle，如 "NotifyStatsChanged"）
        usesTableID boolean|nil 触发方法首个参数是否为 tableID：
            true  → Notify(tableID, ...)（如 NotifyStatSound / NotifyEventSound）
            false → Notify(...) 内部用 self.TableID（如 NotifyStatsChanged / NotifyStatFX）
        byTable string|nil 按桌 ID 变体方法名（如 "NotifyStatsChangedByTable"）
        after   function|nil 回调之后执行 after(tableID, ...)
    @return table { registry = KARDS.Battle[registry] }
]]
function KARDS.Callbacks:New(opts)
    local Battle = KARDS.Battle
    Battle[opts.registry] = Battle[opts.registry] or {}

    Battle[opts.setter] = function(self, tableID, fn)
        self[opts.registry][tableID] = fn
    end

    if opts.usesTableID then
        Battle[opts.notify] = function(self, tableID, ...)
            if not tableID then return end
            local cb = self[opts.registry] and self[opts.registry][tableID]
            if cb then cb(...) end
            if opts.after then opts.after(tableID, ...) end
        end
    else
        Battle[opts.notify] = function(self, ...)
            local cb = self[opts.registry] and self[opts.registry][self.TableID]
            if cb then cb(...) end
            if opts.after then opts.after(self.TableID, ...) end
        end
    end

    if opts.byTable then
        Battle[opts.byTable] = function(self, tableID, ...)
            if not tableID then return end
            local cb = self[opts.registry] and self[opts.registry][tableID]
            if cb then cb(...) end
            if opts.after then opts.after(tableID, ...) end
        end
    end

    return { registry = Battle[opts.registry] }
end

-- 属性变更回调注册表（t4 3D2D 数值同步，2026-08-12）：StatsChangedCallbacks[tableID] = function(...cards) end
-- 依赖倒置——数据层（伤害/战斗结算）不直接依赖牌桌实体，由牌桌实体注册回调
-- （StartFormalBattle → OnBattleStatsChanged），节点效果路径（SimDealDamage / SimFight，
-- 不经实体层 ApplyCombatOutcome）改变单位/总部属性后触发 → 实体层刷新战场实体 NW
-- （客户端 3D2D 文字每帧读取，见 cl_card_text_overlay.lua ReadData）。与 DrawCallbacks 同款模式。
KARDS.Battle.StatsChangedCallbacks = KARDS.Battle.StatsChangedCallbacks or {}

-- 注册/通知属性变更三件套（回调注册表工厂收敛，B3，见 KARDS.Callbacks:New）：
-- SetStatsChangedCallback(tableID, fn) 幂等（后注册覆盖先注册）；
-- NotifyStatsChanged(...) 通知（受影响卡牌可多个，如 SimFight 双方互扣；
-- 无回调注册时静默）；NotifyStatsChangedByTable(tableID, ...) 按桌 ID 通知
-- （供无 battle 实例的节点效果路径使用——ExecuteEffect ctx 必有 tableID，
-- 见 TriggerActs.modifyAttack / modifyDefense 的 SetCardField 成功分支）。
-- 总部被摧毁判定（同 NotifyStatsChangedByTable）：攻击总部 / 交战波及总部的路径
-- 经 Notify 后统一收口——属性变更中总部防御力 ≤ 0 → 摧毁（readme 7.1），
-- 为 SimAttack / SimFight / SimDealDamage 攻击总部路径的统一收口；
-- 士气伤害 / 节点「HQ 防御力」变更不经本函数，由各自入口显式调用
-- CheckHQDestroyed（见 sh_battle_card.lua ApplyMoraleHits / sh_battle_unit.lua
-- SimChangeHQDefense）。CheckHQDestroyed 幂等，重复调用无害。
KARDS.Callbacks:New({
    registry = "StatsChangedCallbacks",
    setter = "SetStatsChangedCallback",
    notify = "NotifyStatsChanged",
    byTable = "NotifyStatsChangedByTable",
    after = function(tableID, ...)
        KARDS.Battle:CheckHQDestructionIn(tableID, ...)
    end,
})

-- ====================================================================
-- 属性变化音效回调（2026-08-13：stat_change.ogg 播放时机收窄）
-- ====================================================================
-- 与 StatsChangedCallbacks 同款模式（数据层不直接依赖牌桌实体，由牌桌实体注册回调）：
-- StatSoundCallbacks[tableID] = fn。来源命中时触发 → 牌桌实体广播 KardsStatChangeSound
-- → 客户端播放 stat_change.ogg（见 table_session.lua StartFormalBattle 注册 /
-- table_battledeck.lua BroadcastStatChangeSound / cl_init.lua net.Receive）。
--
-- 播放来源（2026-08-13 用户规格：仅「属性与伤害节点 + 词条效果」）：
--   - 属性与伤害节点（trigger）中「攻击 / 防御」分支——modifyAttack / modifyDefense
--     非「受到」（sh_node_acts_register.lua）；「受到伤害」分支（SimDealDamage）不播；
--   - 词条效果：山地（mountain，sh_battle_unit.lua ApplyEnterKeywords）/ 动员
--     （mobilize，sh_battle_stub.lua SimBeginTurn）。
-- 其余属性变更路径（SimFight / SimDealDamage 伤害、HQ 防御、SimRepair 等）不触发。
KARDS.Battle.StatSoundCallbacks = KARDS.Battle.StatSoundCallbacks or {}

-- 注册/触发属性变化音效三件套（回调注册表工厂收敛，B3，见 KARDS.Callbacks:New）：
-- SetStatSoundCallback(tableID, fn) 幂等（后注册覆盖先注册）；
-- NotifyStatSound(tableID) 触发（无回调注册时静默，测试环境安全）。仅上文列出的来源调用。
-- 参数：tableID 牌桌唯一标识符；fn 音效广播回调（无参）
KARDS.Callbacks:New({
    registry = "StatSoundCallbacks",
    setter = "SetStatSoundCallback",
    notify = "NotifyStatSound",
    usesTableID = true,
})

-- ====================================================================
-- 属性变化飘字回调（2026-08-14：3D2D 飘字）
-- ====================================================================
-- 与 StatsChangedCallbacks 同款模式（数据层不直接依赖牌桌实体，由牌桌实体注册回调）：
-- StatFXCallbacks[tableID] = fn(card, slot, delta, mod, kind)。全部攻击/防御/行动花费
-- 变动来源点（伤害 / 节点设增减 / 词条 / 修复 / 老兵等）触发 → 牌桌实体广播
-- KardsStatChangeFX → 客户端 3D2D 飘字（见 table_session.lua StartFormalBattle 注册 /
-- table_battledeck.lua BroadcastStatChangeFX / cl_card_text_overlay.lua net.Receive）。
--
-- 参数：
--   card  卡牌句柄（目标；须在场，广播方按实体映射过滤——手牌无实体不广播）
--   slot  "attack" / "defense" / "actionCost"
--   delta 变动值（new - old，符号表增减；为 0 时广播方直接跳过）
--   mod   "increase" / "decrease" / "set"
--   kind  "dmg"（伤害）/ "node"（节点效果）/ "other"（词条/修复/演示/老兵等）
-- 客户端按用户规格着色：攻防 增→绿 / 减（伤害）→红 / 设为或减（节点）→白；
-- 行动花费 增→红 / 减→绿（见 cl_card_text_overlay.lua net.Receive KardsStatChangeFX）。
KARDS.Battle.StatFXCallbacks = KARDS.Battle.StatFXCallbacks or {}

-- 注册/触发属性变化飘字三件套（回调注册表工厂收敛，B3，见 KARDS.Callbacks:New）：
-- SetStatFXCallback(tableID, fn) 幂等（后注册覆盖先注册）；
-- NotifyStatFX(card, slot, delta, mod, kind) battle 实例方法（self.TableID 即牌桌；
-- 无回调注册时静默，测试环境安全）；
-- NotifyStatFXByTable(tableID, ...) 按桌 ID 触发（供无 battle 实例的节点效果路径
-- 使用——ExecuteEffect ctx 必有 tableID，见 sh_node_acts_register.lua /
-- sh_node_semantics.lua 各调用处）。
-- 参数：fn 飘字广播回调 fn(card, slot, delta, mod, kind)
KARDS.Callbacks:New({
    registry = "StatFXCallbacks",
    setter = "SetStatFXCallback",
    notify = "NotifyStatFX",
    byTable = "NotifyStatFXByTable",
})

-- 事件音效回调（2026-08-13：卡牌事件音效，编辑器属性页 sounds 字段消费）
-- ====================================================================
-- 与 StatSoundCallbacks 同款模式：数据层不直接依赖牌桌实体，由牌桌实体注册回调。
-- SoundCallbacks[tableID] = fn(eventKey, card)。数据层事件（当前仅反制拦截触发
-- trigger）发生时触发 → 牌桌实体广播 KardsEventSound（见 table_session.lua
-- StartFormalBattle 注册 / table_battledeck.lua BroadcastEventSound / cl_init.lua net.Receive）。
--
-- 事件键（与编辑器属性页音效槽位一致）：deploy=部署 / attack=攻击 / death=阵亡 /
-- play=打出 / activate=激活时 / trigger=触发。
KARDS.Battle.SoundCallbacks = KARDS.Battle.SoundCallbacks or {}

-- 注册/触发事件音效三件套（回调注册表工厂收敛，B3，见 KARDS.Callbacks:New）：
-- SetSoundCallback(tableID, fn) 幂等（后注册覆盖先注册）；
-- NotifyEventSound(tableID, eventKey, card) 触发（无回调注册时静默，测试环境安全）。
-- 参数：eventKey 事件键（deploy/attack/death/play/activate/trigger）；
--       card 事件源卡牌句柄（须有 GetSounds 方法）
KARDS.Callbacks:New({
    registry = "SoundCallbacks",
    setter = "SetSoundCallback",
    notify = "NotifyEventSound",
    usesTableID = true,
})

-- ====================================================================
-- 控制/解除控制回调（2026-08-16：客户端控制动画）
-- ====================================================================
-- 与 StatsChangedCallbacks 同款模式（数据层不直接依赖牌桌实体，由牌桌实体注册回调）：
-- ControlCallbacks[tableID] = fn(card, isUncontrol, landingZone, landingSlot, fromOwner, toOwner)。
-- SimControl / SimUncontrol 成功后触发 → 牌桌实体广播 KardsControlAnim → 客户端播放
-- 控制动画（0.7s 移向牌桌中心 + z 上升 → 控制图标动画 → 落位，见 cl_init.lua
-- net.Receive / table_battledeck.lua BroadcastControlAnim / table_session.lua 注册）。
-- 解除控制返回手牌路径不触发（SimReturnToHand 经 ReturnToHand 事件走既有返回手牌动画）。
--
-- 参数：
--   card          卡牌句柄（控制/解除对象；须在场，广播方按实体映射过滤）
--   isUncontrol   boolean true=解除控制 / false=控制
--   landingZone   string|nil 控制落位阵线（"frontline"/"support"；解除时为 nil）
--   landingSlot   number|nil 控制落位槽位（前线第 3 / 支援阵线右侧；解除时为 nil）
--   fromOwner     string 旋转起点归属（控制=原归属方；解除=控制者）
--   toOwner       string 旋转终点归属（控制=新控制者；解除=原归属方）——
--                 供观察者视角第一段动画 yaw 旋转（在场玩家视角 yaw 恒朝向自身，
--                 见 cl_init.lua net.Receive KardsControlAnim）
KARDS.Battle.ControlCallbacks = KARDS.Battle.ControlCallbacks or {}

-- 注册/触发控制回调三件套（回调注册表工厂收敛，B3，见 KARDS.Callbacks:New）：
-- SetControlCallback(tableID, fn) 幂等（后注册覆盖先注册）；
-- NotifyControlByTable(tableID, ...) 触发（无回调注册时静默，测试环境安全）。
KARDS.Callbacks:New({
    registry = "ControlCallbacks",
    setter = "SetControlCallback",
    notify = "NotifyControl",
    byTable = "NotifyControlByTable",
})

-- ====================================================================
-- 反制自动打出回调（反制系统 M5：客户端打出动画通道复用）
-- ====================================================================
-- 与 ControlCallbacks 同款模式（数据层不直接依赖牌桌实体，由牌桌实体注册回调）：
-- CounterPlayCallbacks[tableID] = fn(card, slot)。FireCounter（sh_battle_card.lua）
-- 在反制被敌方操作触发自动打出后触发 → 牌桌实体广播指令口径的 KardsCardPlayed
-- 动画 + 激活时音效，并清理手牌映射与延迟销毁实体（见 table_battledeck.lua
-- OnCounterFired / BroadcastCommandPlayed）。
--
-- 参数：
--   card  反制卡牌句柄（已激活；在其拦截函数命中后消费）
--   slot  槽位编号（1/2，由卡牌归属方推导）
KARDS.Battle.CounterPlayCallbacks = KARDS.Battle.CounterPlayCallbacks or {}

-- 注册/触发反制自动打出三件套（回调注册表工厂收敛，见 KARDS.Callbacks:New）：
-- SetCounterPlayCallback(tableID, fn) 幂等（后注册覆盖先注册）；
-- NotifyCounterPlay(card, slot) battle 实例方法（self.TableID 即牌桌；无回调注册时静默）
KARDS.Callbacks:New({
    registry = "CounterPlayCallbacks",
    setter = "SetCounterPlayCallback",
    notify = "NotifyCounterPlay",
})

-- 属性变更中的总部被摧毁判定（内部收口）：遍历受影响卡牌，总部防御力 ≤ 0 →
-- CheckHQDestroyed（幂等：对局已停止 / 已判定时无操作）。供两个 NotifyStatsChanged
-- 变体共用；士气伤害 / 节点「HQ 防御力」路径不经属性变更通知，各自显式调用。
-- @param tableID string 牌桌唯一标识符
-- @param ...     受影响卡牌句柄（可变数量）
function KARDS.Battle:CheckHQDestructionIn(tableID, ...)
    if not (tableID and KARDS.Battlefield and KARDS.Battlefield.CheckHQDestroyed) then return end
    for i = 1, select("#", ...) do
        local card = select(i, ...)
        if card and card.GetType and card:GetType() == "headquarter"
            and card.GetOwner then
            KARDS.Battlefield:CheckHQDestroyed(tableID, card:GetOwner())
        end
    end
end

-- ====================================================================
-- 攻击检查器注册制（re.md B-H1：检查项可注册、可组合）
-- ====================================================================

-- 检查器注册表：CheckRegistry[mode][name] = { check = fn(battle, attacker, defender), failMsg = string }
--   mode 攻击流程变体（"attack" 简单攻击 / "engage" 交战；战斗 SimFight 无前置检查，互扣结算）
--   check 返回 true 通过；返回 false/nil 时，第二个返回值（字符串）作为失败原因，
--         否则用 failMsg 兜底
-- 词条/新状态检查按 KeywordStates 挂载（注册后自动并入对应 mode 的检查链）。
KARDS.Battle.CheckRegistry = KARDS.Battle.CheckRegistry or {}

-- 注册检查器（幂等：同名同 mode 覆盖）
-- @param mode    string 攻击流程变体（"attack" / "engage"）
-- @param name    string 检查项唯一名
-- @param check   function(battle, attacker, defender) 检查函数
-- @param failMsg string 失败提示（check 未返回自定义原因时使用）
function KARDS.Battle:RegisterCheck(mode, name, check, failMsg)
    self.CheckRegistry[mode] = self.CheckRegistry[mode] or {}
    self.CheckRegistry[mode][name] = { check = check, failMsg = failMsg }
end

-- 收集指定 mode 的检查器数组（返回有序表；供调试/审计遍历）
function KARDS.Battle:CollectChecks(mode)
    local list = {}
    for name, c in pairs(self.CheckRegistry[mode] or {}) do
        list[#list + 1] = { name = name, failMsg = c.failMsg, check = c.check }
    end
    return list
end

--[[
    逐项执行指定 mode 的前置检查流水线

    @param mode     string 攻击流程变体（"attack" / "engage"）
    @param attacker table 攻击方卡牌句柄
    @param defender table 被攻击方卡牌句柄
    @return boolean, string|nil 是否全部通过；失败时返回首个失败原因
]]
function KARDS.Battle:RunChecks(mode, attacker, defender)
    for name, c in pairs(self.CheckRegistry[mode] or {}) do
        local ok, reason = c.check(self, attacker, defender)
        if not ok then
            return false, reason or c.failMsg or ("检查未通过: " .. tostring(name))
        end
    end
    return true
end

-- 内置检查器注册（攻击/交战共用检查链；SimEngage 额外含单位类型校验）
-- 0) 友军归属校验（2026-08-19 规划 C10）：攻击/交战目标必须是敌方——同阵营目标
--    拒绝（自损会触发亡语/腾槽/消耗指挥点，readme 7.1 交战对象为敌方单位）。
--    防御方缺失（总部直击类调用）不拦截，交由后续检查处理。
KARDS.Battle:RegisterCheck("attack", "enemy_only",
    function(_, attacker, defender)
        if not attacker or not defender then return true end
        if attacker:GetOwner() == defender:GetOwner() then
            return false, "不能攻击己方目标（友军归属校验）"
        end
        return true
    end, "不能攻击己方目标")
KARDS.Battle:RegisterCheck("engage", "enemy_only",
    function(_, attacker, defender)
        if not attacker or not defender then return true end
        if attacker:GetOwner() == defender:GetOwner() then
            return false, "不能与己方单位交战（友军归属校验）"
        end
        return true
    end, "不能与己方单位交战")
-- 1) 单位本回合能否行动（被压制 / 刚部署且无闪击，readme 7.2.1 / 7.2.2）
--    原因由 CanUnitAct 区分返回（2026-08-12）；failMsg 仅作兜底
KARDS.Battle:RegisterCheck("attack", "can_act",
    function(b, attacker) return b:CanUnitAct(b.TableID, attacker) end,
    "单位本回合不能行动")
KARDS.Battle:RegisterCheck("engage", "can_act",
    function(b, attacker) return b:CanUnitAct(b.TableID, attacker) end,
    "单位本回合不能行动")
-- 2) 轰炸机拦截判定（敌阵线有战斗机 → 只能攻击战斗机；被守护战斗机 → 完全封锁，readme 7.3）
KARDS.Battle:RegisterCheck("attack", "bomber_intercept",
    function(b, attacker, defender) return b:CanBomberAttackTarget(attacker, defender) end,
    "轰炸机被拦截（敌方阵线战斗机，readme 7.3）")
KARDS.Battle:RegisterCheck("engage", "bomber_intercept",
    function(b, attacker, defender) return b:CanBomberAttackTarget(attacker, defender) end,
    "轰炸机被拦截（敌方阵线战斗机，readme 7.3）")
-- 3) 词条目标限制（被守护 / 守护 / 烟幕，readme 7.2.1 / 7.2.2）
KARDS.Battle:RegisterCheck("attack", "target_limit",
    function(b, attacker, defender) return b:CanAttackTarget(attacker, defender) end,
    "目标受词条限制（被守护/守护/烟幕，readme 7.2.1/7.2.2）")
KARDS.Battle:RegisterCheck("engage", "target_limit",
    function(b, attacker, defender) return b:CanAttackTarget(attacker, defender) end,
    "目标受词条限制（被守护/守护/烟幕，readme 7.2.1/7.2.2）")
-- 4) 攻击次数（奋战单位一回合可攻击两次，其余一次，readme 7.2.2）
KARDS.Battle:RegisterCheck("attack", "attack_count",
    function(b, attacker) return b:CanUnitAttackNow(attacker) end,
    "本回合攻击次数已用尽（奋战单位可攻击两次，readme 7.2.2）")
KARDS.Battle:RegisterCheck("engage", "attack_count",
    function(b, attacker) return b:CanUnitAttackNow(attacker) end,
    "本回合攻击次数已用尽（奋战单位可攻击两次，readme 7.2.2）")
-- 5) 攻击消耗行动花费（隐蔽未揭示 → 行动花费为 1，readme 7.2.2）；不足拒绝
KARDS.Battle:RegisterCheck("attack", "action_cost",
    function(b, attacker)
        local cost = b:GetActionCost(b.TableID, attacker)
        if not KARDS.CommandPoints:CanPay(b.TableID, attacker:GetOwner(), cost) then
            return false, ("指挥点不足（需要行动花费 %s）"):format(tostring(cost))
        end
        return true
    end, "指挥点不足（行动花费）")
KARDS.Battle:RegisterCheck("engage", "action_cost",
    function(b, attacker)
        local cost = b:GetActionCost(b.TableID, attacker)
        if not KARDS.CommandPoints:CanPay(b.TableID, attacker:GetOwner(), cost) then
            return false, ("指挥点不足（需要行动花费 %s）"):format(tostring(cost))
        end
        return true
    end, "指挥点不足（行动花费）")
-- 6) 交战专属：攻击方/防御方必须是单位卡（攻击总部不算交战，readme 7.1）
KARDS.Battle:RegisterCheck("engage", "unit_types",
    function(_, attacker, defender)
        if not attacker or attacker:GetType() ~= "unit" then
            return false, "攻击方必须是单位卡"
        end
        if not defender or defender:GetType() ~= "unit" then
            return false, "攻击总部不算交战（readme 7.1）；防御方必须是单位卡"
        end
        return true
    end, "攻击方/防御方必须是单位卡")
-- 7) 攻击距离（readme 7.3 单位类型规则：坦克/步兵只能攻击相邻战线的敌人）：
--    仅坦克/步兵受阵线距离限制：友方支援阵线只能攻击前线单位（支援 → 支援拒绝）；
--    前线只能攻击对方支援阵线单位（前线 → 前线拒绝，前线为共用单阵营阵线）。
--    炮兵/轰炸机/战斗机不受限（基础即可攻击任何阵线的目标）。
--    攻击方或目标不在场（模拟直接行动）不限制（与既有检查惯例一致）。
KARDS.Battle:RegisterCheck("attack", "attack_range",
    function(b, attacker, defender)
        local unitType = attacker.GetUnitType and attacker:GetUnitType() or nil
        if unitType ~= "tank" and unitType ~= "infantry" then return true end
        local azone = KARDS.Battlefield:FindCardZone(b.TableID, attacker)
        if not azone then return true end
        local dzone = KARDS.Battlefield:FindCardZone(b.TableID, defender)
        if not dzone then return true end
        if azone == "support" and dzone == "support" then
            return false, "攻击距离不够（支援阵线单位不能攻击敌方支援阵线目标）"
        end
        if azone == "frontline" and dzone == "frontline" then
            return false, "攻击距离不够（前线单位只能攻击对方支援阵线单位）"
        end
        return true
    end, "攻击距离不够（步兵/坦克只能攻击相邻战线的目标）")
KARDS.Battle:RegisterCheck("engage", "attack_range",
    function(b, attacker, defender)
        local unitType = attacker.GetUnitType and attacker:GetUnitType() or nil
        if unitType ~= "tank" and unitType ~= "infantry" then return true end
        local azone = KARDS.Battlefield:FindCardZone(b.TableID, attacker)
        if not azone then return true end
        local dzone = KARDS.Battlefield:FindCardZone(b.TableID, defender)
        if not dzone then return true end
        if azone == "support" and dzone == "support" then
            return false, "攻击距离不够（支援阵线单位不能攻击敌方支援阵线目标）"
        end
        if azone == "frontline" and dzone == "frontline" then
            return false, "攻击距离不够（前线单位只能攻击对方支援阵线单位）"
        end
        return true
    end, "攻击距离不够（步兵/坦克只能攻击相邻战线的目标）")
-- 8) 本回合行动记录（readme 7.1：一个单位只能操作一次）：
--    已移动的单位本回合不能攻击（移动/攻击互斥）；坦克移动至前线后可继续攻击（例外）。
KARDS.Battle:RegisterCheck("attack", "turn_action",
    function(b, attacker)
        local st = b.KeywordStates[b.TableID]
        if st and KARDS.KeywordStates.TurnAction.HasMoved(st, attacker)
            and not (attacker.GetUnitType and attacker:GetUnitType() == "tank") then
            return false, "单位本回合已移动过（移动后不能攻击，坦克除外）"
        end
        return true
    end, "单位本回合已移动过（移动后不能攻击，坦克除外）")
KARDS.Battle:RegisterCheck("engage", "turn_action",
    function(b, attacker)
        local st = b.KeywordStates[b.TableID]
        if st and KARDS.KeywordStates.TurnAction.HasMoved(st, attacker)
            and not (attacker.GetUnitType and attacker:GetUnitType() == "tank") then
            return false, "单位本回合已移动过（移动后不能攻击，坦克除外）"
        end
        return true
    end, "单位本回合已移动过（移动后不能攻击，坦克除外）")

-- ====================================================================
-- 伤害结算（re.md B-H1：攻击/交战/伤害共用结算统一收口）
-- ====================================================================

--[[
    统一伤害结算（readme 7.2.1 免疫 / 7.2.2 重甲·动员；引擎钩子 OnModifyDamage 修饰）

    顺序：伤害修饰钩子（OnModifyDamage，所有经过结算的伤害都会被修饰影响）
      → 重甲减伤（opts.applyArmor，交战时每个单位最多 3 重甲）
      → 免疫（单位或总部具有免疫时不会受到伤害）
      → 应用防御减少 + 动员失去（opts.applyMobilize，受到伤害后失去动员）。
    由 SimAttack / SimEngage / SimDealDamage 调用（各按语义传 opts）。

    @param source table|nil 伤害来源（攻击方 / 效果发起者）
    @param target table 受伤害卡牌句柄
    @param amount number 伤害量
    @param opts   table|nil 可选项：
        applyArmor    boolean 是否应用目标重甲减伤（交战生效，readme 7.2.2）
        applyMobilize boolean 是否触发目标动员失去（受到伤害后失去动员，readme 7.2.2）
    @return number 实际造成的伤害（免疫/减伤后；非负）
]]
-- 伤害倍率路径匹配（combatModifiers 的 targetPath/sourcePath 语义，2026-10-04）：
-- 路径形如 "Battle.Friendly/Enemy + 类别"，判定某卡相对视角方（perspectiveOwner）是否落入该路径集合。
-- 类别：Headquarter（总部）、Units（任意单位）、GroundUnits（步兵/坦克/炮兵）、AirUnits（战斗机/轰炸机）、
--       Infantry/Tank/Artillery/Fighter/Bomber（精确单位类型）、Target（任意对象）。
-- 返回 boolean（路径非法或类型不符返回 false）。
local function CombatPathMatches(path, card, perspectiveOwner)
    if not path or not card then return false end
    if not card.GetOwner or not card.GetType then return false end
    local side, kind = path:match("^Battle%.(Friendly|Enemy)(.+)$")
    if not side then return false end
    local isFriendly = (card:GetOwner() == perspectiveOwner)
    if (side == "Friendly") ~= isFriendly then return false end
    if kind == "Headquarter" then
        return card:GetType() == "headquarter"
    end
    if card:GetType() ~= "unit" then return false end
    local ut = card.GetUnitType and card:GetUnitType() or nil
    if kind == "Units" or kind == "Target" then return true end
    if kind == "GroundUnits" then
        return ut == "infantry" or ut == "tank" or ut == "artillery"
    end
    if kind == "AirUnits" then
        return ut == "fighter" or ut == "bomber"
    end
    local exact = {
        Infantry = "infantry", Tank = "tank", Artillery = "artillery",
        Fighter = "fighter", Bomber = "bomber",
    }
    return exact[kind] ~= nil and exact[kind] == ut
end

function KARDS.Battle:ResolveDamage(source, target, amount, opts)
    opts = opts or {}
    amount = math.max(0, amount or 0)
    -- 伤害修饰钩子（OnModifyDamage）：所有经过结算的伤害都会被修饰影响
    -- （readme 引擎钩子系统；register_hook 注册的「造成的伤害」修饰在此累计偏移）
    local args = KARDS.EngineHooks.Trigger(self.TableID, KARDS.EngineHooks.HookPoints.OnModifyDamage, {
        attacker = source,
        defender = target,
        damage = amount,
    })
    amount = math.max(0, args.damage or 0)
    -- 伤害倍率（combatModifiers，2026-10-04）：攻击者输出倍率 × 被击者受伤害倍率（未匹配默认 1）
    local mult = 1
    if source and source.GetCombatModifiers then
        local sOwner = source.GetOwner and source:GetOwner() or nil
        for _, rule in ipairs(source:GetCombatModifiers().outgoing or {}) do
            if rule.multiplier and CombatPathMatches(rule.targetPath, target, sOwner) then
                mult = mult * rule.multiplier
            end
        end
    end
    if target and target.GetCombatModifiers then
        local tOwner = target.GetOwner and target:GetOwner() or nil
        for _, rule in ipairs(target:GetCombatModifiers().incoming or {}) do
            if source and rule.multiplier and CombatPathMatches(rule.sourcePath, source, tOwner) then
                mult = mult * rule.multiplier
            end
        end
    end
    if mult ~= 1 then
        amount = math.floor(amount * mult + 0.5)
    end
    -- 重甲 X（readme 7.2.2）：交战时受到的伤害减少 X（每个单位最多 3 重甲）
    if opts.applyArmor then
        amount = math.max(0, amount - math.min(self:GetKeywordValue(self.TableID, target, "armor", 0) or 0, 3))
    end
    -- 免疫（readme 7.2.1）：单位或总部具有免疫时不会受到伤害
    if self:HasActiveKeyword(self.TableID, target, "immune") then
        amount = 0
    end
    if amount > 0 then
        target:ApplyChange("defense", "decrease", amount)
        -- 飘字（2026-08-14）：伤害（ResolveDamage 收口 SimAttack/SimEngage/SimDealDamage/
        -- 节点「受到伤害」「受到」）→ 防御减少红色飘字
        self:NotifyStatFX(target, "defense", -amount, "decrease", "dmg")
        -- 动员（readme 7.2.2）：受到伤害后失去动员
        if opts.applyMobilize and self:HasActiveKeyword(self.TableID, target, "mobilize") then
            KARDS.KeywordStates.Mobilize.MarkLost(self.KeywordStates[self.TableID], target)
        end
    end
    return amount
end

-- 伏击结算（readme 7.2.2）：伏击单位每回合首次被攻击时会首先造成反击伤害；
-- 若攻击者因此被消灭，则其无法对伏击单位造成伤害（冲击压反击：冲击单位攻击时不触发）
-- 由 SimAttack / SimEngage 共用（re.md B-H1：攻击/交战共用结算统一收口）。
-- @param battle KARDS.Battle 骨架实例
-- @param attacker table 攻击方卡牌句柄
-- @param defender table 被攻击方卡牌句柄
-- @return boolean, boolean, boolean, number
--   ambushTriggered 伏击是否触发（反击权已行使，交战不再普通反击）
--   ambushBlocked   攻击者被伏击击杀（主伤害不结算）
--   shockActive     冲击当前生效（压伏击；交战反击条件用）
--   ambushDamage    攻击者受到的伏击反击伤害
local function ResolveAmbush(battle, attacker, defender)
    local st = battle.KeywordStates[battle.TableID]
    -- 冲击当前生效（卡面有冲击且本回合未用）才压伏击：冲击攻击单位后已移除（ShockUsed，readme 7.4 示例）
    local shockActive = battle:HasActiveKeyword(battle.TableID, attacker, "shock")
        and not KARDS.KeywordStates.Shock.IsUsed(st, attacker)
    if not (battle:HasActiveKeyword(battle.TableID, defender, "ambush")
        and not KARDS.KeywordStates.Ambush.IsUsed(st, defender)
        and not shockActive) then
        return false, false, shockActive, 0
    end
    KARDS.KeywordStates.Ambush.MarkUsed(st, defender)
    local counter = defender:GetStat("attack")
    if counter > 0 then
        -- 重甲 X（readme 7.2.2）：交战时受到的伤害减少 X（反击伤害同样受减伤，readme 7.4 示例）
        counter = math.max(0, counter - math.min(battle:GetKeywordValue(battle.TableID, attacker, "armor", 0) or 0, 3))
        if counter > 0 then
            attacker:ApplyChange("defense", "decrease", counter)
            -- 飘字（2026-08-14）：伏击反击伤害 → 攻击方防御减少红色飘字
            battle:NotifyStatFX(attacker, "defense", -counter, "decrease", "dmg")
            if not attacker:IsAlive() then
                return true, true, shockActive, counter -- 攻击者被伏击击杀：主伤害不结算
            end
        end
    end
    return true, false, shockActive, counter
end

-- 交战反击豁免判定（readme 7.3 单位类型规则；交战生效，战斗失效）
-- 判定「防御方是否对攻击方造成反击伤害」：
--   - 攻击方是炮兵：攻击时不会受到反击伤害 → 无反击
--   - 攻击方是轰炸机 且 防御方不是战斗机：攻击非战斗机目标不受反击 → 无反击
--   - 防御方是轰炸机：被攻击时也不会造成反击伤害 → 无反击
--   - 其余（坦克/步兵/战斗机互交、轰炸机 vs 战斗机）：正常反击
-- @param attacker 攻击方卡牌句柄
-- @param defender 防御方（被攻击单位）卡牌句柄
-- @return boolean 防御方是否反击攻击方
local function CanCounterattack(attacker, defender)
    if attacker:GetUnitType() == "artillery" then return false end
    if attacker:GetUnitType() == "bomber" and defender:GetUnitType() ~= "fighter" then return false end
    if defender:GetUnitType() == "bomber" then return false end
    return true
end

-- 自动移除被消灭的单位（readme 7.1 溢出伤害：目标防御力 ≤0 时被消灭）
-- 伤害结算入口（SimAttack / SimEngage / SimFight / SimDealDamage）在结算后调用：
-- 防御力 ≤0 的单位自动离场（无需手动 SimRemoveFromField）；总部不可被移除（非单位卡，
-- 总部防御可低于 0 但仍驻留支援阵线槽 3）。
-- @param self KARDS.Battle 骨架实例
-- @param ...  可变数量卡牌句柄（单位 / 总部）
local function AutoRemoveDead(self, ...)
    for i = 1, select("#", ...) do
        local card = select(i, ...)
        if card and card:GetType() == "unit" and not card:IsAlive() then
            self:SimRemoveFromField(card, "death")
        end
    end
end

--[[
    单位攻击（骨架，简单攻击：伤害 = 攻击力）

    不含交战 / 战斗语义（无反击、无单位类型规则）；用于「攻击总部」等非交战场景。
    完整结算（攻击 + 反击 + 单位类型规则）见 SimEngage；互扣见 SimFight。

    @param attacker table 攻击方卡牌句柄
    @param defender table 被攻击方卡牌句柄
    @return boolean 是否造成伤害（finalDmg > 0）
]]
function KARDS.Battle:SimAttack(attacker, defender)
    -- 统一操作钩子（M1）：攻击可被反制拦截（主动卡 = 攻击方）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "attack", {
        player = attacker and attacker:GetOwner(), card = attacker, targets = { defender },
    }).intercepted then
        return self:InterceptOperation("attack", attacker)
    end
    -- 前置检查流水线（re.md B-H1：检查器注册制，检查项可注册、可组合）
    local ok, reason = self:RunChecks("attack", attacker, defender)
    if not ok then
        print("[Battle] SimAttack 失败: " .. tostring(reason))
        return false, reason
    end
    local actionCost = self:GetActionCost(self.TableID, attacker)
    local st = self.KeywordStates[self.TableID]
    local dmg = attacker:GetStat("attack")
    local attackerChange = nil -- 发起者自身经受的数值变更（伏击反击）

    -- 隐蔽（readme 7.2.2 + 2026-08-13 用户规格）：发起攻击时先触发揭示事件（揭示
    -- 先于攻击结算与反制/事件触发——隐蔽单位攻击会先揭示、再攻击、再触发反制，
    -- 反制因此能作用到已揭示的隐蔽单位）；被攻击方同理（被敌方单位攻击时揭示）。
    -- 隐蔽只免疫指令/反制/单位效果，不免疫攻击伤害本身，故揭示后攻击照常结算。
    if KARDS.KeywordStates.Hidden.Is(st, attacker) then self:SimReveal(attacker) end
    if KARDS.KeywordStates.Hidden.Is(st, defender) then self:SimReveal(defender) end

    -- 伏击（readme 7.2.2）：伏击单位每回合首次被攻击时会首先造成反击伤害；
    -- 若攻击者因此被消灭，则其无法对伏击单位造成伤害（冲击压反击：冲击单位攻击时不触发）
    local _, ambushBlocked, _, ambushDamage = ResolveAmbush(self, attacker, defender)
    if ambushDamage > 0 then
        attackerChange = "-" .. ambushDamage
    end

    -- 主伤害结算（伤害修饰钩子 / 免疫 / 动员失去统一收口，re.md B-H1 resolveDamage）
    local finalDmg = 0
    if not ambushBlocked then
        finalDmg = self:ResolveDamage(attacker, defender, dmg, { applyMobilize = true })
    end

    -- 攻击后状态（readme 7.2.2）：烟幕移动或攻击后失去；冲击攻击单位后移除
    -- （隐蔽揭示已提前至攻击结算前，见上方「隐蔽」注释，此处不再重复揭示）
    if self:HasActiveKeyword(self.TableID, attacker, "smoke") then
        KARDS.KeywordStates.Smoke.Break(st, attacker)
    end
    if self:HasActiveKeyword(self.TableID, attacker, "shock") then
        KARDS.KeywordStates.Shock.MarkUsed(st, attacker)
    end
    KARDS.KeywordStates.Attack.Inc(st, attacker)
    KARDS.KeywordStates.TurnAction.MarkAttacked(st, attacker)

    -- 记录刻度：发起者 = 攻击方（攻击），受影响 = 防御方（受到伤害 -N）；发起者第三字段 = 伏击反击数值
    local affected = {}
    if finalDmg > 0 then
        table.insert(affected, { defender, { "take_damage" }, "-" .. finalDmg })
    end
    KARDS.CommandPoints:Pay(self.TableID, attacker:GetOwner(), actionCost)
    KARDS.TickLog:Push(self.TableID, attacker, { "attack" }, affected, attackerChange)
    -- 钳击（开始点 = 触发点）：攻击结算后若攻击者存在钳击同伴（双方互相登记，
    -- 见 sh_battle_unit.lua PincerPartners），触发双方「钳击」开始点；同伴链的
    -- 「钳击对象」数据点 = 攻击者（RunCardEffect 注入）。置于 AutoRemoveDead 之前：
    -- 钳击效果中消灭的单位由 AutoRemoveDead 统一收口离场。
    self:MaybeTriggerPincer(attacker)
    AutoRemoveDead(self, attacker, defender) -- 防御力 ≤0 的单位自动离场（readme 7.1 溢出伤害）
    -- 总部被摧毁判定（readme 7.1）：单位攻击总部（SimAttack）不经属性变更通知，
    -- 此处显式收口（CheckHQDestructionIn 幂等：非总部跳过 / 已判定无操作）
    self:CheckHQDestructionIn(self.TableID, attacker, defender)
    -- 总部开始点（开始点 = 触发点）：攻击对象是总部时，按「受到伤害」「防御变化」
    -- 开始点执行总部效果链（与 ApplyMoraleHits 士气伤害的 HQ 触发一致；发起者 =
    -- 受影响 = 总部自身，无匹配开始点不执行）
    if defender and defender:GetType() == "headquarter" then
        self:RunCardEffect(defender, { defender }, "受到伤害")
        self:RunCardEffect(defender, { defender }, "防御变化")
    end
    return finalDmg > 0
end

--[[
    交战（骨架，readme 7.1：单位攻击另一个单位，无论是否造成伤害；攻击总部不算交战）

    单位类型规则在交战时生效（readme 7.1 注 / 7.3）：
      伤害 = 攻击方攻击力；防御方按单位类型规则反击（炮兵/轰炸机豁免见 CanCounterattack）。

    @param attacker table 攻击方单位卡牌句柄
    @param defender table 被攻击方单位卡牌句柄
    @return boolean 是否造成伤害（finalDmg > 0；false 亦可能因参数非法）
]]
function KARDS.Battle:SimEngage(attacker, defender)
    -- 统一操作钩子（M1）：交战可被反制拦截（主动卡 = 攻击方）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "engage", {
        player = attacker and attacker:GetOwner(), card = attacker, targets = { defender },
    }).intercepted then
        return self:InterceptOperation("engage", attacker)
    end
    -- 前置检查流水线（含单位类型校验；re.md B-H1 检查器注册制）
    local ok, reason = self:RunChecks("engage", attacker, defender)
    if not ok then
        print("[Battle] SimEngage 失败: " .. tostring(reason))
        return false, reason
    end
    local actionCost = self:GetActionCost(self.TableID, attacker)
    local st = self.KeywordStates[self.TableID]
    local attackerDamageTaken = 0 -- 攻击者经受的总伤害（伏击反击 + 正常反击）

    -- 隐蔽（readme 7.2.2 + 2026-08-13 用户规格）：发起/被攻击时先触发揭示事件——
    -- 揭示先于攻击结算与反制/事件触发（同 SimAttack 注释）；隐蔽不免疫攻击伤害本身
    if KARDS.KeywordStates.Hidden.Is(st, attacker) then self:SimReveal(attacker) end
    if KARDS.KeywordStates.Hidden.Is(st, defender) then self:SimReveal(defender) end

    -- 伏击（readme 7.2.2）：伏击单位每回合首次被攻击时会首先造成反击伤害；
    -- 若攻击者因此被消灭，则其无法对伏击单位造成伤害（冲击压反击：冲击单位攻击时不触发）
    local ambushTriggered, ambushBlocked, shockActive, ambushDamage = ResolveAmbush(self, attacker, defender)
    attackerDamageTaken = ambushDamage

    -- 主伤害结算（伤害修饰钩子 / 重甲 / 免疫 / 动员失去统一收口，re.md B-H1 resolveDamage）
    local finalDmg = 0
    if not ambushBlocked then
        finalDmg = self:ResolveDamage(attacker, defender, attacker:GetStat("attack"),
            { applyArmor = true, applyMobilize = true })
    end

    -- 反击（单位类型规则生效；readme 7.2.2 冲击：首次攻击时被攻击单位不会造成任何反击伤害；
    -- 伏击已触发则反击权已行使，不再普通反击，readme 7.4 示例）
    if not ambushBlocked and not ambushTriggered and not shockActive
        and CanCounterattack(attacker, defender) then
        local retal = defender:GetStat("attack")
        if retal > 0 then
            -- 重甲 X（readme 7.2.2）：交战时受到的伤害减少 X（反击伤害同样受减伤，readme 7.4 示例）
            retal = math.max(0, retal - math.min(self:GetKeywordValue(self.TableID, attacker, "armor", 0) or 0, 3))
            if retal > 0 then
                attacker:ApplyChange("defense", "decrease", retal)
                -- 飘字（2026-08-14）：正常反击伤害 → 攻击方防御减少红色飘字
                self:NotifyStatFX(attacker, "defense", -retal, "decrease", "dmg")
                attackerDamageTaken = attackerDamageTaken + retal -- 发起者自身经受的数值变更（被反击）
            end
        end
    end

    -- 攻击后状态（readme 7.2.2）：烟幕移动或攻击后失去；冲击攻击单位后移除
    -- （隐蔽揭示已提前至攻击结算前，见上方「隐蔽」注释，此处不再重复揭示）
    if self:HasActiveKeyword(self.TableID, attacker, "smoke") then
        KARDS.KeywordStates.Smoke.Break(st, attacker)
    end
    if self:HasActiveKeyword(self.TableID, attacker, "shock") then
        KARDS.KeywordStates.Shock.MarkUsed(st, attacker)
    end
    KARDS.KeywordStates.Attack.Inc(st, attacker)
    KARDS.KeywordStates.TurnAction.MarkAttacked(st, attacker)

    -- 交战刻：发起者（交战/攻击/造成伤害），受影响（交战/受到伤害/反击）
    local affected = {}
    if finalDmg > 0 then
        table.insert(affected, { defender, { "engage", "take_damage", "counterattack" }, "-" .. finalDmg })
    else
        table.insert(affected, { defender, { "engage", "take_damage", "counterattack" } })
    end
    local attackerChange = attackerDamageTaken > 0 and ("-" .. attackerDamageTaken) or nil
    KARDS.CommandPoints:Pay(self.TableID, attacker:GetOwner(), actionCost)
    KARDS.TickLog:Push(self.TableID, attacker, { "engage", "attack", "deal_damage" }, affected, attackerChange)
    -- 钳击（开始点 = 触发点）：交战结算后若攻击者存在钳击同伴（双方互相登记，
    -- 见 sh_battle_unit.lua PincerPartners），触发双方「钳击」开始点；同伴链的
    -- 「钳击对象」数据点 = 攻击者（RunCardEffect 注入）。置于 AutoRemoveDead 之前：
    -- 钳击效果中消灭的单位由 AutoRemoveDead 统一收口离场。
    self:MaybeTriggerPincer(attacker)
    AutoRemoveDead(self, attacker, defender) -- 防御力 ≤0 的单位自动离场（readme 7.1 溢出伤害）
    -- 总部被摧毁判定（readme 7.1）：交战波及总部（防御方 / 被反击的进攻方）
    -- 不经属性变更通知，此处显式收口（CheckHQDestructionIn 幂等：非总部跳过）
    self:CheckHQDestructionIn(self.TableID, attacker, defender)
    -- 总部开始点（开始点 = 触发点）：交战波及总部（防御方为总部，或反击使总部
    -- 防御减少）时，按「受到伤害」「防御变化」开始点执行总部效果链（与 SimAttack
    -- HQ 触发 / ApplyMoraleHits 士气伤害一致；发起者 = 受影响 = 总部自身）
    if defender and defender:GetType() == "headquarter" then
        self:RunCardEffect(defender, { defender }, "受到伤害")
        self:RunCardEffect(defender, { defender }, "防御变化")
    end
    return finalDmg > 0
end

--[[
    战斗（骨架，readme 7.1：当两个单位战斗时，对彼此造成等同于其攻击的伤害；
    不算作攻击或对战，无视单位类型规则）

    战斗无前置检查（非攻击流程，互扣结算）；免疫（readme 7.2.1）直接判定，
    不触发 OnModifyDamage 伤害修饰钩子（对齐原语义：战斗互扣不走修饰）。

    @param unitA table 参战单位卡牌句柄（刻的发起者）
    @param unitB table 参战单位卡牌句柄
    @return boolean 是否成功（双方均为单位卡）
]]
function KARDS.Battle:SimFight(unitA, unitB)
    if not unitA or unitA:GetType() ~= "unit" or not unitB or unitB:GetType() ~= "unit" then
        print("[Battle] SimFight 失败: 战斗双方必须是单位卡")
        return false
    end
    -- 统一操作钩子（M1）：战斗可被反制拦截（主动卡 = 第一个参战单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "fight", {
        player = unitA:GetOwner(), card = unitA, targets = { unitB },
    }).intercepted then
        return self:InterceptOperation("fight", unitA)
    end

    -- 双方互扣等同对方攻击的防御（无视单位类型规则：炮兵/轰炸机也受战斗伤害）；
    -- 免疫（readme 7.2.1）：免疫单位不会受到伤害
    local dmgToB = self:HasActiveKeyword(self.TableID, unitB, "immune") and 0 or unitA:GetStat("attack")
    local dmgToA = self:HasActiveKeyword(self.TableID, unitA, "immune") and 0 or unitB:GetStat("attack")
    if dmgToB > 0 then
        unitB:ApplyChange("defense", "decrease", dmgToB)
        -- 飘字（2026-08-14）：战斗互扣伤害 → 双方防御减少红色飘字
        self:NotifyStatFX(unitB, "defense", -dmgToB, "decrease", "dmg")
    end
    if dmgToA > 0 then
        unitA:ApplyChange("defense", "decrease", dmgToA)
        self:NotifyStatFX(unitA, "defense", -dmgToA, "decrease", "dmg")
    end

    -- 战斗刻：发起者（战斗/攻击/造成伤害），受影响（战斗/受到伤害/反击）
    local affected = {}
    if dmgToB > 0 then
        table.insert(affected, { unitB, { "fight", "take_damage", "counterattack" }, "-" .. dmgToB })
    else
        table.insert(affected, { unitB, { "fight", "take_damage", "counterattack" } })
    end
    local aChange = dmgToA > 0 and ("-" .. dmgToA) or nil
    KARDS.TickLog:Push(self.TableID, unitA, { "fight", "attack", "deal_damage" }, affected, aChange)
    AutoRemoveDead(self, unitA, unitB) -- 防御力 ≤0 的单位自动离场（readme 7.1 溢出伤害）
    -- 2026-08-12（t4 3D2D 数值同步）：战斗操作路径（节点效果调用，不经实体层
    -- ApplyCombatOutcome）改变双方防御 → 通知牌桌实体刷新战场实体 NW
    self:NotifyStatsChanged(unitA, unitB)
    return true
end

-- 模拟造成 / 受到伤害（供测试直接使用；结算统一走 ResolveDamage）
-- @param source table|nil 伤害来源（卡牌句柄或 nil）
-- @param target table 受伤害卡牌句柄
-- @param amount number 伤害量
function KARDS.Battle:SimDealDamage(source, target, amount)
    -- 统一操作钩子（M1）：造成伤害可被反制拦截（主动卡 = 伤害来源，无来源时取目标）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "deal_damage", {
        card = source or target, targets = { target },
    }).intercepted then
        return self:InterceptOperation("deal_damage", source or target)
    end
    amount = self:ResolveDamage(source, target, amount)
    local affected = {}
    if amount > 0 then
        table.insert(affected, { target, { "take_damage" }, "-" .. amount })
    end
    KARDS.TickLog:Push(self.TableID, source or target, { "deal_damage" }, affected)
    AutoRemoveDead(self, target) -- 防御力 ≤0 的单位自动离场（readme 7.1 溢出伤害；总部不可移除）
    -- 2026-08-12（t4 3D2D 数值同步）：trigger 伤害路径（节点效果）不经实体层
    -- ApplyCombatOutcome → 此处通知牌桌实体刷新单位/总部属性 NW（实体层注册见
    -- table_battledeck.lua OnBattleStatsChanged / StartFormalBattle）
    self:NotifyStatsChanged(target)
end
