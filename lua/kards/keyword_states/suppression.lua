-- 词条状态模块：压制（readme 7.2.1）
--
-- 状态字段：Suppressed（[card] = true 被压制）
-- 联动规则：被压制单位不能移动或攻击（CanUnitAct 查询 Is）；
--   压制于单位所有者下个回合结束时移除（回合结束系统归正式版，
--   骨架经 SimUnsuppress → Clear 手动解除）。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Suppression = {
    Field = "Suppressed",

    -- 是否被压制
    Is = function(st, card)
        return st ~= nil and st.Suppressed[card] == true
    end,

    -- 置为被压制
    Set = function(st, card)
        st.Suppressed[card] = true
    end,

    -- 解除压制
    Clear = function(st, card)
        st.Suppressed[card] = nil
    end,
}
table.insert(KS.Modules, KS.Suppression)
