-- Kards 词条状态模块聚合（共享，re.md B-M1）
--
-- KeywordStates[tableID] 单一状态表承载 11 种词条状态，状态之间耦合规则
-- （免疫禁止伤害 / 烟幕破与移动攻击联动 / 伏击每回合重置等）原先散落在各
-- Sim 函数中。现按词条域分模块（keyword_states/*.lua），每个模块声明：
--   状态字段（Field，KeywordStates[tableID] 中的键）
--   读写接口（Is / Set / Clear / Get；数值与记录状态为 Get/Set/Clear）
--   联动规则（模块头注释说明何时清除/禁止）
-- 战斗 Sim 函数只调用模块接口，不再直接读写状态表字段；
-- KeywordStates[tableID] 的表结构保持不变（测试断言直接读取字段）。

KARDS = KARDS or {}
KARDS.KeywordStates = KARDS.KeywordStates or {}

-- 模块注册表（各模块文件定义后自注册；字段/回合重置规则由聚合入口遍历）
KARDS.KeywordStates.Modules = {}

include("kards/keyword_states/suppression.lua")
include("kards/keyword_states/hidden.lua")
include("kards/keyword_states/smoke.lua")
include("kards/keyword_states/shock.lua")
include("kards/keyword_states/ambush.lua")
include("kards/keyword_states/attack.lua")
include("kards/keyword_states/mobilize.lua")
include("kards/keyword_states/inhibit.lua")
include("kards/keyword_states/countdown.lua")
include("kards/keyword_states/immune.lua")
include("kards/keyword_states/control.lua")
include("kards/keyword_states/turn_action.lua")

-- 创建一张牌桌的词条状态表（StartBattle 调用；字段由各模块声明，均为 card → 状态 的映射表）
-- @return table 状态表（KeywordStates[tableID]）
function KARDS.KeywordStates.New()
    local st = {}
    for _, m in ipairs(KARDS.KeywordStates.Modules) do
        st[m.Field] = {}
    end
    return st
end

-- 每回合开始重置回合状态（readme 7.2.2：伏击已用 / 攻击次数等回合状态在回合开始重置，
-- SimBeginTurn 调用）；仅实现了 ResetTurn 规则的模块参与（ambush / attack）
-- @param st table 状态表（KeywordStates[tableID]）
function KARDS.KeywordStates.ResetTurn(st)
    if not st then return end
    for _, m in ipairs(KARDS.KeywordStates.Modules) do
        if m.ResetTurn then m.ResetTurn(st) end
    end
end
