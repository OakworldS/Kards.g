-- 词条状态模块：抑制（readme 7.2.1）
--
-- 状态字段：Inhibited（[card] = true 被抑制）
-- 联动规则：被抑制的卡牌失去所有关键词和效果（HasActiveKeyword / GetKeywordValue
--   查询 Is → 全部失效；属性重置由卡牌/效果配置）；骨架经 SimInhibit → Set、
--   SimUnneutralize → Clear 维护。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Inhibit = {
    Field = "Inhibited",

    -- 是否被抑制
    Is = function(st, card)
        return st ~= nil and st.Inhibited[card] == true
    end,

    -- 置为被抑制
    Set = function(st, card)
        st.Inhibited[card] = true
    end,

    -- 解除抑制（恢复关键词和效果）
    Clear = function(st, card)
        st.Inhibited[card] = nil
    end,
}
table.insert(KS.Modules, KS.Inhibit)
