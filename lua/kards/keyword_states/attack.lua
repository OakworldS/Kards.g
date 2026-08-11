-- 词条状态模块：攻击次数（readme 7.2.2 奋战）
--
-- 状态字段：Attacks（[card] = 本回合攻击次数）
-- 联动规则：单位一回合默认攻击一次，奋战单位可攻击两次（CanUnitAttackNow 查询 Get，
--   上限经 HasActiveKeyword "frenzy" 判定）；攻击结算后 Inc 计数；
--   攻击次数每回合开始重置（ResetTurn）。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Attack = {
    Field = "Attacks",

    -- 本回合攻击次数（未攻击过返回 0）
    Get = function(st, card)
        return st ~= nil and st.Attacks[card] or 0
    end,

    -- 攻击次数 +1（攻击结算后调用）
    Inc = function(st, card)
        st.Attacks[card] = (st.Attacks[card] or 0) + 1
    end,

    -- 每回合开始重置
    ResetTurn = function(st)
        st.Attacks = {}
    end,
}
table.insert(KS.Modules, KS.Attack)
