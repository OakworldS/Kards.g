-- 词条状态模块：隐蔽（readme 7.2.2）
--
-- 状态字段：Hidden（[card] = true 隐蔽未揭示）
-- 联动规则：未揭示的隐蔽单位不受指令/反制/单位效果影响（SimPlayCard 拒绝以隐蔽
--   单位为目标）、行动花费 1（GetActionCost 查询 Is）；隐蔽单位发起攻击或被攻击后
--   揭示（SimReveal → Clear）。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Hidden = {
    Field = "Hidden",

    -- 是否处于隐蔽（未揭示）
    Is = function(st, card)
        return st ~= nil and st.Hidden[card] == true
    end,

    -- 置为隐蔽（未揭示）；隐蔽单位入场时调用（ApplyEnterKeywords）
    Set = function(st, card)
        st.Hidden[card] = true
    end,

    -- 揭示（移除隐蔽）；由 SimReveal 在攻击结算后调用
    Clear = function(st, card)
        st.Hidden[card] = nil
    end,
}
table.insert(KS.Modules, KS.Hidden)
