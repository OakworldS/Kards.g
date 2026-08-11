-- 词条状态模块：控制（readme 7.1 控制规则）
--
-- 状态字段：ControlOrigin（[card] = 原归属玩家标识）
-- 联动规则：控制转移归属时记录原归属（SimControl 首次控制时 Set 原归属、
--   后续控制不覆盖），解除控制时归属还原并清除（SimUncontrol 读取 Get → 还原 → Clear）；
--   总部不可被控制。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Control = {
    Field = "ControlOrigin",

    -- 原归属玩家（未被控制过返回 nil）
    Get = function(st, card)
        return st ~= nil and st.ControlOrigin[card] or nil
    end,

    -- 记录原归属玩家（首次控制时调用）
    Set = function(st, card, owner)
        st.ControlOrigin[card] = owner
    end,

    -- 清除原归属记录（解除控制后调用）
    Clear = function(st, card)
        st.ControlOrigin[card] = nil
    end,
}
table.insert(KS.Modules, KS.Control)
