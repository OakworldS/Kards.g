-- 词条状态模块：隐蔽（readme 7.2.2）
--
-- 状态字段：Hidden（[card] = true 隐蔽未揭示）
-- 联动规则（2026-08-13 用户规格统一收口）：任何节点上作用到非自身的效果无法作用到
--   隐蔽的单位（SimPlayCard 过滤指令目标 + ExecuteBaseNode 统一过滤节点效果目标；
--   攻击伤害 SimAttack/SimEngage 不走节点执行器，隐蔽不免疫伤害）、行动花费 1
--   （GetActionCost 查询 Is）；隐蔽单位发起攻击或被攻击后揭示（SimAttack/SimEngage
--   结算前先 SimReveal → Clear，保证「先揭示→再攻击→再触发反制」）。
--   反制例证：指向仍隐蔽单位的效果被过滤（消灭不生效）；攻击揭示后反制可作用。

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

    -- 揭示（移除隐蔽）；由 SimReveal 在攻击/被攻击结算前调用（SimAttack/SimEngage
    -- 开头，保证先揭示再攻击再触发反制，见 sh_battle_combat.lua）
    Clear = function(st, card)
        st.Hidden[card] = nil
    end,
}
table.insert(KS.Modules, KS.Hidden)
