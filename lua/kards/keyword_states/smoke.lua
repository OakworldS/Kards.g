-- 词条状态模块：烟幕（readme 7.2.2）
--
-- 状态字段：SmokeBroken（[card] = true 烟幕已破）
-- 联动规则：烟幕单位（未破）无法被敌方单位攻击（CanAttackTarget 查询 IsBroken）；
--   烟幕在移动或攻击后失去（SimMoveToFrontline / SimRetreat / SimAttack / SimEngage
--   → Break 置位；置位后不再受烟幕保护）。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Smoke = {
    Field = "SmokeBroken",

    -- 烟幕是否已破（false = 烟幕仍生效，受保护）
    IsBroken = function(st, card)
        return st ~= nil and st.SmokeBroken[card] == true
    end,

    -- 打破烟幕（移动或攻击后失去烟幕）
    Break = function(st, card)
        st.SmokeBroken[card] = true
    end,
}
table.insert(KS.Modules, KS.Smoke)
