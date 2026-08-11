-- 词条状态模块：冲击（readme 7.2.2）
--
-- 状态字段：ShockUsed（[card] = true 冲击已用）
-- 联动规则：冲击单位本回合首次攻击时生效、随后移除（readme 7.4 示例）；
--   冲击生效期间压伏击（ResolveAmbush 查询 IsUsed）；攻击结算后 MarkUsed。
--   冲击已用不随回合重置（每回合仅首次攻击生效，使用后整局不再触发）。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Shock = {
    Field = "ShockUsed",

    -- 冲击是否已用（false = 本回合冲击仍可生效）
    IsUsed = function(st, card)
        return st ~= nil and st.ShockUsed[card] == true
    end,

    -- 标记冲击已用（攻击结算后调用）
    MarkUsed = function(st, card)
        st.ShockUsed[card] = true
    end,
}
table.insert(KS.Modules, KS.Shock)
