-- 词条状态模块：免疫（readme 7.2.1）
--
-- 状态字段：Immune（[card] = true 免疫状态）
-- 联动规则：免疫单位不会受到伤害（HasActiveKeyword "immune" 查询 Is 生效、
--   ResolveDamage 将伤害归零）；免疫为效果给予的状态，与卡面 immune 词条等效；
--   被抑制时免疫同样失效（HasActiveKeyword 先拦截抑制）。
--   骨架经 SimImmune → Set、SimUnimmune → Clear 维护。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Immune = {
    Field = "Immune",

    -- 是否处于免疫状态
    Is = function(st, card)
        return st ~= nil and st.Immune[card] == true
    end,

    -- 给予免疫状态
    Set = function(st, card)
        st.Immune[card] = true
    end,

    -- 解除免疫状态
    Clear = function(st, card)
        st.Immune[card] = nil
    end,
}
table.insert(KS.Modules, KS.Immune)
