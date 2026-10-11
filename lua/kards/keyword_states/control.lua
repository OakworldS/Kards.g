-- 词条状态模块：控制（readme 7.1 控制规则）
--
-- 状态字段：ControlOrigin（[card] = { zone = 原阵线("support"/"frontline"),
--                                     slot = 原槽位, owner = 原归属玩家 }）
-- 联动规则：控制时记录原阵线位置（SimControl 首次控制时 Set、后续控制不覆盖，
--   解除控制时还原最初归属与最初原位），解除控制时读取 → 还原归属 → 移回原位 →
--   清除（SimUncontrol 读取 Get → 还原 → Clear）；原位在支援阵线且支援阵线已满，
--   或原位在前线且前线被该单位阵营的另一方占领时 → 返回手牌；
--   总部不可被控制。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Control = {
    Field = "ControlOrigin",

    -- 原阵线位置（{ zone, slot, owner }；未被控制过返回 nil）
    Get = function(st, card)
        return st ~= nil and st.ControlOrigin[card] or nil
    end,

    -- 记录原阵线位置（首次控制时调用）
    Set = function(st, card, info)
        st.ControlOrigin[card] = info
    end,

    -- 清除原阵线位置记录（解除控制后调用）
    Clear = function(st, card)
        st.ControlOrigin[card] = nil
    end,
}
table.insert(KS.Modules, KS.Control)
