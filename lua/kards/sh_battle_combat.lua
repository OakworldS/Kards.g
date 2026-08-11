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
-- 1) 单位本回合能否行动（被压制 / 刚部署且无闪击，readme 7.2.1 / 7.2.2）
KARDS.Battle:RegisterCheck("attack", "can_act",
    function(b, attacker) return b:CanUnitAct(b.TableID, attacker) end,
    "单位本回合不能行动（被压制或刚入场无闪击，readme 7.2.1/7.2.2）")
KARDS.Battle:RegisterCheck("engage", "can_act",
    function(b, attacker) return b:CanUnitAct(b.TableID, attacker) end,
    "单位本回合不能行动（被压制或刚入场无闪击，readme 7.2.1/7.2.2）")
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
--    仅坦克/步兵受「支援阵线 → 支援阵线」拒绝限制；炮兵/轰炸机/战斗机不受限。
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
        return true
    end, "攻击距离不够（支援阵线单位不能攻击敌方支援阵线目标）")
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
        return true
    end, "攻击距离不够（支援阵线单位不能攻击敌方支援阵线目标）")
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

    -- 攻击后状态（readme 7.2.2）：烟幕移动或攻击后失去；冲击攻击单位后移除；隐蔽发起/被攻击后揭示
    if self:HasActiveKeyword(self.TableID, attacker, "smoke") then
        KARDS.KeywordStates.Smoke.Break(st, attacker)
    end
    if self:HasActiveKeyword(self.TableID, attacker, "shock") then
        KARDS.KeywordStates.Shock.MarkUsed(st, attacker)
    end
    if KARDS.KeywordStates.Hidden.Is(st, attacker) then self:SimReveal(attacker) end
    if KARDS.KeywordStates.Hidden.Is(st, defender) then self:SimReveal(defender) end
    KARDS.KeywordStates.Attack.Inc(st, attacker)
    KARDS.KeywordStates.TurnAction.MarkAttacked(st, attacker)

    -- 记录刻度：发起者 = 攻击方（攻击），受影响 = 防御方（受到伤害 -N）；发起者第三字段 = 伏击反击数值
    local affected = {}
    if finalDmg > 0 then
        table.insert(affected, { defender, { "take_damage" }, "-" .. finalDmg })
    end
    KARDS.CommandPoints:Pay(self.TableID, attacker:GetOwner(), actionCost)
    KARDS.TickLog:Push(self.TableID, attacker, { "attack" }, affected, attackerChange)
    AutoRemoveDead(self, attacker, defender) -- 防御力 ≤0 的单位自动离场（readme 7.1 溢出伤害）
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
    -- 前置检查流水线（含单位类型校验；re.md B-H1 检查器注册制）
    local ok, reason = self:RunChecks("engage", attacker, defender)
    if not ok then
        print("[Battle] SimEngage 失败: " .. tostring(reason))
        return false, reason
    end
    local actionCost = self:GetActionCost(self.TableID, attacker)
    local st = self.KeywordStates[self.TableID]
    local attackerDamageTaken = 0 -- 攻击者经受的总伤害（伏击反击 + 正常反击）

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
                attackerDamageTaken = attackerDamageTaken + retal -- 发起者自身经受的数值变更（被反击）
            end
        end
    end

    -- 攻击后状态（readme 7.2.2）：烟幕移动或攻击后失去；冲击攻击单位后移除；隐蔽发起/被攻击后揭示
    if self:HasActiveKeyword(self.TableID, attacker, "smoke") then
        KARDS.KeywordStates.Smoke.Break(st, attacker)
    end
    if self:HasActiveKeyword(self.TableID, attacker, "shock") then
        KARDS.KeywordStates.Shock.MarkUsed(st, attacker)
    end
    if KARDS.KeywordStates.Hidden.Is(st, attacker) then self:SimReveal(attacker) end
    if KARDS.KeywordStates.Hidden.Is(st, defender) then self:SimReveal(defender) end
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
    AutoRemoveDead(self, attacker, defender) -- 防御力 ≤0 的单位自动离场（readme 7.1 溢出伤害）
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

    -- 双方互扣等同对方攻击的防御（无视单位类型规则：炮兵/轰炸机也受战斗伤害）；
    -- 免疫（readme 7.2.1）：免疫单位不会受到伤害
    local dmgToB = self:HasActiveKeyword(self.TableID, unitB, "immune") and 0 or unitA:GetStat("attack")
    local dmgToA = self:HasActiveKeyword(self.TableID, unitA, "immune") and 0 or unitB:GetStat("attack")
    if dmgToB > 0 then
        unitB:ApplyChange("defense", "decrease", dmgToB)
    end
    if dmgToA > 0 then
        unitA:ApplyChange("defense", "decrease", dmgToA)
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
    return true
end

-- 模拟造成 / 受到伤害（供测试直接使用；结算统一走 ResolveDamage）
-- @param source table|nil 伤害来源（卡牌句柄或 nil）
-- @param target table 受伤害卡牌句柄
-- @param amount number 伤害量
function KARDS.Battle:SimDealDamage(source, target, amount)
    amount = self:ResolveDamage(source, target, amount)
    local affected = {}
    if amount > 0 then
        table.insert(affected, { target, { "take_damage" }, "-" .. amount })
    end
    KARDS.TickLog:Push(self.TableID, source or target, { "deal_damage" }, affected)
    AutoRemoveDead(self, target) -- 防御力 ≤0 的单位自动离场（readme 7.1 溢出伤害；总部不可移除）
end
