-- 词条状态模块：伏击（readme 7.2.2）
--
-- 状态字段：AmbushUsed（[card] = true 伏击本回合已用）
-- 联动规则：伏击单位每回合首次被攻击时先造成反击伤害（ResolveAmbush 查询 IsUsed，
--   触发后 MarkUsed，本回合不再触发）；伏击已用每回合开始重置（ResetTurn，
--   冲击压伏击：冲击生效期间伏击不触发，见 ResolveAmbush）。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Ambush = {
    Field = "AmbushUsed",

    -- 伏击本回合是否已用过
    IsUsed = function(st, card)
        return st ~= nil and st.AmbushUsed[card] == true
    end,

    -- 标记伏击已用（本回合首次被攻击触发后调用）
    MarkUsed = function(st, card)
        st.AmbushUsed[card] = true
    end,

    -- 每回合开始重置（伏击每回合首次被攻击生效）
    ResetTurn = function(st)
        st.AmbushUsed = {}
    end,
}
table.insert(KS.Modules, KS.Ambush)
