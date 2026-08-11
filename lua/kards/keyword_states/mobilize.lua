-- 词条状态模块：动员（readme 7.2.2）
--
-- 状态字段：MobilizeLost（[card] = true 动员已失去）
-- 联动规则：动员单位每回合开始时获得 +1+1（SimBeginTurn 查询 IsLost，
--   失去动员后不再获得）；动员单位受到伤害后失去动员（ResolveDamage → MarkLost）。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Mobilize = {
    Field = "MobilizeLost",

    -- 动员是否已失去
    IsLost = function(st, card)
        return st ~= nil and st.MobilizeLost[card] == true
    end,

    -- 标记动员失去（受到伤害后调用）
    MarkLost = function(st, card)
        st.MobilizeLost[card] = true
    end,
}
table.insert(KS.Modules, KS.Mobilize)
