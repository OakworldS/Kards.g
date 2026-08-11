-- 词条状态模块：单位本回合行动记录（readme 7.1 操作）
--
-- 状态字段：TurnAction（[card] = { Moved = bool, Attacked = bool } 的映射表）
-- 联动规则：单位每回合可移动或攻击一次（移动/攻击互斥）；
--   坦克移动至前线后可继续攻击（例外由 sh_battle_combat.lua 的 turn_action 检查器
--   判定 unitType ~= "tank" 实现）；攻击后不可移动；移动一次即不可再移动。
--   行动记录每回合开始重置（ResetTurn）。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.TurnAction = {
    Field = "TurnAction",

    -- 本回合是否已移动
    HasMoved = function(st, card)
        return st ~= nil and st.TurnAction.Moved and st.TurnAction.Moved[card] == true
    end,

    -- 本回合是否已攻击（交战 / 攻击总部均计）
    HasAttacked = function(st, card)
        return st ~= nil and st.TurnAction.Attacked and st.TurnAction.Attacked[card] == true
    end,

    -- 标记已移动（移动至前线成功后调用）
    MarkMoved = function(st, card)
        st.TurnAction.Moved[card] = true
    end,

    -- 标记已攻击（SimAttack / SimEngage 攻击结算后调用）
    MarkAttacked = function(st, card)
        st.TurnAction.Attacked[card] = true
    end,

    -- 每回合开始重置（New() 只建空表，Moved/Attacked 子表由首次 ResetTurn 初始化）
    ResetTurn = function(st)
        st.TurnAction.Moved = {}
        st.TurnAction.Attacked = {}
    end,
}
table.insert(KS.Modules, KS.TurnAction)
