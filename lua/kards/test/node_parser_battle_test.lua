--[[
    节点解析器战斗场景测试 (Node Parser Battle Test)

    在 GMod 控制台执行 kards_node_battle_test 运行全部场景（纯数据层，服务端/客户端皆可）。
    测试对象：KARDS.NodeParser 效果执行管线（ExecuteEffect → ExecuteBaseNode → 语义执行器）
    与战斗系统骨架（KARDS.Battle，lua/kards/sh_battle_stub.lua）的联动——
    即「节点效果能否在战斗场景生效」，区别于 node_parser_test.lua 仅验证解析。

    触发方式统一：P1 打出带 effect 的指令卡（KARDS.Battle:SimPlayCard）触发节点效果。
    对 action / card 模板的所有组合各设立一个简单战斗场景验证效果生效
    （以后新增 base 节点均按此模式测试）。

    场景清单：
      action 组合（23）：
        获得 18 项：
          RunActionGainTest
            1 撤退（目标从战线回支援阵线）
            2 移动(到前线)（目标从支援阵线入前线）
            3 交战（与对象槽单位交战，目标防御 -攻击）
            4 战斗（与对象槽单位互扣）
            5 加入战场（目标入场支援阵线）
            6 加入前线（目标直接入场前线）
            7 压制（KeywordStates.Suppressed 置位）
            8 抑制（KeywordStates.Inhibited 置位）
            9 转换（记录 convert 刻）
            10 修复（目标防御 +1）
            11 控制（目标归属转移为 P1）
            12 免疫（HasActiveKeyword 免疫生效）
            13 情报（触发情报记录 intelligence 刻）
            14 造成伤害（目标防御 -N）
            15 触发关键字效果（记录 trigger 刻）
            16 返回手牌（目标离场入所有者手牌）
            17 召唤单位（对象槽单位加入本方支援阵线）
            18 升为老兵（套用老兵外观并触发「升级」开始点）
        取消 4 项：RunActionCancelTest（解除压制/解除抑制/解除控制/解除免疫）
        被消灭 1 项：RunActionDestroyTest
      card 组合（16）：友方/敌方 × 8 分支（抽取/复制/弃掉/开发/选择/爆牌/洗切卡组/洗入）
        RunCardSideTest(1, "P1") / RunCardSideTest(2, "P2")
      command 组合（18）：RunCommandTest —— 阵营（友方/敌方/双方）× 资源（指挥点/指挥点槽）× 操作（增加/减少/设为）
        P1 打出指令触发，断言 KARDS.CommandPoints 点数/槽数变更 + command_points/command_slot 刻记录
      condition 判断（12）：RunConditionTest —— 5 种统计方式 × 运算符比较 + 关键字检查，断言 node.data 结果
      condition 双输出分支（3）：RunConditionBranchTest —— 模拟 if else 结构：
        满足 → satisfied 端口 → 抽 1 张；不满足 → not_satisfied 端口 → 抽 2 张；无连线端口不执行
        经 effect.connections 控制流模式验证分支信号传递（断言 P1 手牌/卡组）
      event_monitor 监测：RunEventMonitorTest —— 8 种事件 × 阵营/约束（总部防御、指令花费、
        时：触发情报(H1)、目标/单位属性变化(H4)、手牌张数、回合阶段），断言 t事件类型/e事件目标/p触发事件 输出
      event_monitor 双输出分支（9）：RunEventMonitorBranchTest —— 触发/未触发分支信号传递
      extract 提取（28）：RunExtractTest —— 阵营（友方/敌方/双方）× 类型（单位/指令/反制）× 属性条件
        筛选的卡牌对象组正确性（单位取战场含前线、指令/反制取手牌）
        + e 类型数据线传递（extract 输出对象组经 dataConnections 注入下游 action「造成伤害」目标集，
        覆盖控制流与顺序两种执行模式）
      headquarter 总部（23）：RunHeadquarterTest —— 阵营（友方/敌方/双方）× 操作（增加/减少/设为）× 数值 2
        的防御力变更正确性 + stat_change 刻记录（总部初始防御 20）
      loop 循环（9）：RunLoopTest —— 循环双输出节点（hasSecondOutput）：计数 N 次循环
        （第一输出点 satisfied 走回循环体、第二输出点 not_satisfied 走循环结束后节点），
        N = 3 / 1 / 0 边界验证循环体执行次数 + 循环计数归零
      property 特殊执行操作（33）：RunPropertyTest —— 主选项（随机排列所有/战斗）：
        随机排列所有：目标方（单位=双方/友方/敌方）控制的阵线范围（支援阵线 + 控制的前线）
        随机重排单位，总部不参与；未控制前线时仅在支援阵线排列。确定性断言：单位守恒/
        总部仍在支援/阵线归属规则/单位不越界
        战斗：e 数据线注入对象组（target_selector 选出的敌方单位）优先作攻击者，无注入回退
        对象槽 1；防御者 = 对象槽 2。双方互相战斗（SimFight 互扣对方攻击力防御）
      register_hook 注册钩子（26）：RunRegisterHookTest —— 双分支：
        ① 一般属性修饰：作用目标（敌方/友方）× 修饰对象（造成的伤害/攻击力/防御力）× 修饰方式
          （增加/减少/设为）× 数值 × 作用域（存活在场/永久），输出 p钩子ID。
          断言：敌方伤害 -1/+2/设为1、敌我攻击力/防御力修饰、存活在场绑定单位离场失效
        ② 通用效果（调用函数）：总是触发 = 注册持续钩子（AlwaysHooks），此后每次打出
          指令（含注册本次）都调用函数；条件触发 = 注册事件钩子（事件阵营 × 事件
          回合开始/结束、部署、打出指令、触发反制），事件发生时经 TriggerEventHooks
          匹配阵营后调用函数。
          断言：注册后每次打出调用函数（含注册本次 HQ 20→22）、条件触发仅在指定阵营
          事件时调用、函数内多节点全部生效且调用者后续节点在函数完成后才执行（20+2+3+1=26）
      target_selector 目标选择（37）：RunTargetSelectorTest —— 选择方式（指向一个/随机/所有/
        属性最高/属性最低）× 阵营范围（友方/敌方/场上）× 卡牌类别（单位/目标/总部）×
        单位类型（任意/战斗机/坦克/轰炸机/炮兵/步兵），输出 e选中的卡牌 对象组。
        断言：阵营收集正确（含前线）、总部选择、随机数量与不重复、属性最高/最低按名次、
        指向一个取打出指令目标、单位类型过滤（任意不过滤）、e 数据线注入下游 action 造成伤害
      trigger_function 触发函数（16）：RunTriggerFunctionTest —— 触发模式（触发一次/保持触发/
        停止保持触发/拦截一次/保持拦截）× funcslot_1 函数 × e 输入目标实体，输出 e目标、t效果图案类型。
        触发一次 = 立即同步调用函数；保持触发 = 注册到目标实体，实体拥有者回合开始（SimBeginTurn）
        自动执行；停止保持触发 = 移除注册；拦截 = 注册 OnBeforePlayCard 钩子拦截敌方打出指令
        （函数效果执行成功视为已拦截），拦截一次首次拦截后注销、保持拦截持续拦截。
        断言：立即调用函数、保持触发仅注册者回合执行、停止后不再执行、拦截一次二次生效、
        保持拦截多次拦截、效果图案类型输出
      trigger 属性与伤害（23）：RunTriggerTest —— 目标卡牌（e 输入）× 主分支（攻击/防御/受到伤害）：
        攻击 = 攻击力 设为/增加/减少 N；防御 = 防御力 受到（伤害结算）/设为/增加/减少 N；
        受到伤害 = 目标受到 N 点伤害（总部可为目标）；输出 n攻击力、n防御力（修改后属性值）。
        断言：攻击/防御修改正确、受到伤害结算、伤害值 = 输入数值、输出端口写入、
        e 数据线（extract → trigger）注入目标生效、extract 总部 → 总部受到伤害
      turn 回合（20）：RunTurnTest —— 实在的时间刻节点（跨刻执行）：
        等待 = 效果跨刻挂起（信号停滞在节点，后续符合条件的时间刻计数 +1，达标后继续）；
        使 = 立即推进回合（回合结束 / 跳过回合）。
        断言：等待-友方/敌方/任意 × 开始/结束 × 次数（1 次/2 次）挂起与恢复、
        阵营不匹配不计数、挂起时下游节点不执行、恢复后下游执行、挂起注册表登记/清空、
        使-回合结束立即生效（countdown 单位移除）、使-跳过回合（回合数 +1 当前回合玩家转移）、
        顺序模式（无连线）挂起后从挂起节点后继恢复

    依赖：KARDS.Battle（sh_battle_stub.lua）、KARDS.Battlefield、KARDS.Deck、
          KARDS.CardInterface、KARDS.NodeParser（sh_node_parser.lua）。
    加载：autorun/sh_card_editor_loader.lua（node_parser_test.lua 之后）。
]]

KARDS = KARDS or {}

local TestsPassed = 0
local TestsFailed = 0
local FailedTests = {} -- 本次运行失败的断言消息（结束前重新打印一遍）

-- ====================================================================
-- 断言辅助
-- ====================================================================

local function AssertEqual(actual, expected, label)
    if actual == expected then
        TestsPassed = TestsPassed + 1
        print("[PASS] " .. label)
    else
        TestsFailed = TestsFailed + 1
        local msg = "[FAIL] " .. label .. " | 期望=" .. tostring(expected) .. " 实际=" .. tostring(actual)
        print(msg)
        table.insert(FailedTests, msg)
    end
end

local function AssertTrue(cond, label)
    if cond then
        TestsPassed = TestsPassed + 1
        print("[PASS] " .. label)
    else
        TestsFailed = TestsFailed + 1
        local msg = "[FAIL] " .. label .. " | 期望=true 实际=" .. tostring(cond)
        print(msg)
        table.insert(FailedTests, msg)
    end
end

-- ====================================================================
-- 常量：模板 base 结构串（与 data_static/kards/node_templates/action.json / card.json 一致）
-- ====================================================================
local ACTION_BASE = "e{1}{3} if 1 then {18} if 2 then {1} end if 3 then {1} end if 4 then [lib] end if 5 then [0] end if 6 then {1}{1} end if 7 then end if 8 then {1}{2} end elseif 9 then {4} elseif 10 then end"
local CARD_BASE = "e{2}{8} if 1 then [lib]{4} if 2 then {1} else {4} end elseif 4 then [lib]{4} if 5 then else end elseif 7 then [lib]{5} if 8 then {2} if 9 then [lib] end else end elseif 11 then [lib]{1} elseif 12 then [lib] elseif 13 then [lib] elseif 14 then {4} if 15 then {2}[lib] elseif 16 then {1}[lib] elseif 17 then {1}[lib] else {2}[lib] end end(e影响的卡牌)"
local COMMAND_BASE = "{3}{2}{3}[lib](n结果)"
local CONDITION_BASE = "e{2} if 1 then {2}[lib+5]{5}[lib] end if 2 then {1}{1} end(n比较结果、p布尔值、p是否有关键字)"
local EVENT_MONITOR_BASE = "{2}{8} if 1 then [0] elseif 2 then {2} if 3 then {5}{4} if 4 then [0] else [0] end else {1} end elseif 7 then elseif 8 then {3} if 9 then [0] end elseif 10 then {1}[0] elseif 11 then {2} end(t事件类型、e事件目标、p触发事件)"
local EXTRACT_BASE = "{3}{4} if 1 then {4}[0] elseif 2 or 3 then [0] elseif 4 then end(e提取的卡牌对象组)"
local HEADQUARTER_BASE = "{3}{3}[lib](n总部防御力)"
local LOOP_BASE = "[0](n循环次数)"
local PROPERTY_BASE = "e{2} if 1 then {3} end if 2 then {1} {1} end"
local REGISTER_HOOK_BASE = "{2}if 1 then {3}{3}{3}[0]{2} else {2}if 2 then {2}{5} end # end(p钩子ID)"
local TARGET_SELECTOR_BASE = "e{5} if 1 then {1}[0] end if 2 then [0] end {3}{3} if 3 then {6} end(e选中的卡牌)"
local TRIGGER_FUNCTION_BASE = "e{5}#{1}{1}(e目标、t效果图案类型)"
local TRIGGER_BASE = "e{1}{3} if 1 then {3}[0] end if 2 then {4}[0] end if 3 then [0] end(n攻击力、n防御力)"
local TURN_BASE = "{2} if 1 then {3}{2}[0] elseif 2 then {2}{2} end"

-- ====================================================================
-- 测试辅助（战斗搭建 / 节点 / 指令 / 校验）
-- ====================================================================

-- 新建/重置战斗牌桌（StartBattle 重建时间刻/布局/卡组/指挥点，复用同一 tableID 隔离）
local function NewBattle()
    KARDS.Battle:StartBattle("nbt", { "P1", "P2" }, "before", "P1")
    return "nbt"
end

-- 构造单位卡（cost/actionCost 默认 0，避免指挥点不足影响效果验证）
local function MakeUnit(id, owner, stats)
    local s = stats or {}
    s.cost = s.cost or 0
    s.actionCost = s.actionCost or 0
    return KARDS.CardInterface.CreateMockCard(id, "unit", owner, s)
end

-- 构造 base 型节点（槽值直接写入 node.data[compId]，ReadSlot 兜底读取）
-- extra 可选：{ id = 节点 id（控制流连线引用）, hasSecondOutput = 双输出点标记 }
local function MakeBaseNode(tplType, baseStr, values, extra)
    extra = extra or {}
    return {
        id = extra.id,
        name = tplType .. "_node",
        type = "base",
        base = baseStr,
        hasSecondOutput = extra.hasSecondOutput or false,
        data = values or {},
    }
end

-- 构造带 effect 的指令卡（P1 打出触发节点效果；cost 0）
local function MakeCommandCard(id, node)
    local card = KARDS.CardInterface.CreateMockCard(id, "command", "P1", { cost = 0 })
    card.effect = { nodes = { node }, variables = {}, dataConnections = {} }
    return card
end

-- 构造带多节点 + 控制流连线（connections，编辑器导出格式 { fromNode, toNode, fromPort }）的指令卡
-- 用于验证 condition 双输出点 if else 结构：satisfied / not_satisfied 端口连接的下游节点
-- dataConns 可选：数据线（编辑器导出格式 { id, fromNode, toNode, fromPortIndex, toPortIndex, dataType, variableName }）
local function MakeBranchCommandCard(id, nodes, connections, dataConns)
    local card = KARDS.CardInterface.CreateMockCard(id, "command", "P1", { cost = 0 })
    card.effect = { nodes = nodes, variables = {}, dataConnections = dataConns or {}, connections = connections or {} }
    return card
end

-- 将卡牌加入指定玩家手牌
local function GiveHand(tid, player, card)
    table.insert(KARDS.Deck:GetHand(tid, player), card)
end

-- P1 打出指令（统一触发方式；opts 可选：{ specify = { handPicker = fn, targetPicker = fn } } 指定操作选择注入）
local function PlayCommand(cmd, targets, opts)
    return KARDS.Battle:SimPlayCard("P1", cmd, targets or {}, opts)
end

-- 卡牌所在阵线（"support" 支援阵线 / "frontline" 前线 / nil 不在场）
local function ZoneOf(tid, card)
    return KARDS.Battlefield:FindCardZone(tid, card)
end

-- 手牌是否包含指定卡牌（按引用）
local function HandContains(tid, player, card)
    for _, h in ipairs(KARDS.Deck:GetHand(tid, player) or {}) do
        if h == card then return true end
    end
    return false
end

-- 对象组是否包含指定卡牌（按引用，extract 输出顺序与阵营/槽位有关，不做序断言）
local function GroupContains(group, card)
    for _, c in ipairs(group or {}) do
        if c == card then return true end
    end
    return false
end

-- 支援阵线占用卡数（含总部）
local function SupportCount(tid, owner)
    local line = KARDS.Battlefield:GetSupport(tid, owner)
    local n = 0
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        if line[i] ~= nil then n = n + 1 end
    end
    return n
end

-- 最近刻中是否存在「发起者 = card 且操作类型数组含 opType」的刻
local function HasTickOp(tid, card, opType)
    local n = KARDS.TickLog:Count(tid)
    for i = n, 1, -1 do
        local tick = KARDS.TickLog:GetTick(tid, i)
        local initiator = tick and tick[1]
        if initiator and initiator[1] == card then
            for _, op in ipairs(initiator[2] or {}) do
                if op == opType then return true end
            end
        end
    end
    return false
end

-- 是否存在任意发起者的指定操作类型的刻（发起者不固定，如 scry/develop 刻的发起者是选中卡）
local function HasAnyTickOp(tid, opType)
    for i = 1, KARDS.TickLog:Count(tid) do
        local tick = KARDS.TickLog:GetTick(tid, i)
        local initiator = tick and tick[1]
        if initiator then
            for _, op in ipairs(initiator[2] or {}) do
                if op == opType then return true end
            end
        end
    end
    return false
end

-- action 通用场景：双方支援阵线各部署 1 单位（P2 单位带情报词条供情报场景），推进 P1 回合
-- @return tid, u1(P1 单位), u2(P2 单位)
local function SetupActionField()
    local tid = NewBattle()
    local u1 = MakeUnit("A_P1", "P1", { unitType = "infantry", attack = 3, defense = 5 })
    local u2 = MakeUnit("A_P2", "P2", { unitType = "fighter", attack = 2, defense = 6,
        keywords = { { "intel", 2 } } })
    KARDS.Battle:SimDeploy(u1, 3)
    KARDS.Battle:SimDeploy(u2, 3)
    KARDS.Battle:SimBeginTurn("P1") -- 推进回合使已部署单位可行动（闪击规则，readme 7.2.2）
    return tid, u1, u2
end

-- ====================================================================
-- action 获得分支：18 项动作
-- ====================================================================
local function RunActionGainTest()
    -- 1 撤退
    do
        local tid, u1 = SetupActionField()
        KARDS.Battle:SimMoveToFrontline(u1) -- 前置：把 u1 移到前线
        AssertEqual(ZoneOf(tid, u1), "frontline", "action 撤退 前置：目标位于前线")
        AssertTrue(PlayCommand(MakeCommandCard("cmd_retreat", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 1,
        })), { u1 }), "action 撤退：P1 打出指令生效")
        AssertEqual(ZoneOf(tid, u1), "support", "action 撤退：目标回到本方支援阵线")
    end

    -- 2 移动(到前线)
    do
        local tid, u1 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_mtf", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 2,
        })), { u1 }), "action 移动：P1 打出指令生效")
        AssertEqual(ZoneOf(tid, u1), "frontline", "action 移动(到前线)：目标移入前线")
    end

    -- 3 交战（与对象槽单位交战，目标防御 -攻击力）
    -- （2026-08-15 调整：攻击者 u1 不部署、模拟直接行动——部署在支援阵线的单位受
    -- attack_range 限制（支援阵线单位不能攻击敌方支援阵线目标，见 sh_battle_combat.lua）；
    -- 未部署的攻击者不受距离检查，与守护/烟幕等场景的既有模式一致）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("A_E1", "P1", { unitType = "infantry", attack = 3, defense = 5 })
        local u2 = MakeUnit("A_E2", "P2", { unitType = "fighter", attack = 2, defense = 6 })
        KARDS.Battle:SimDeploy(u2, 3)
        AssertTrue(PlayCommand(MakeCommandCard("cmd_engage", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 3, ["select_4"] = u2,
        })), { u1 }), "action 交战：P1 打出指令生效")
        AssertEqual(u2:GetStat("defense"), 3, "action 交战：目标防御 6 - 攻击 3 = 3")
    end

    -- 4 战斗（与对象槽单位互扣）
    do
        local tid, u1, u2 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_fight", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 4, ["select_5"] = u2,
        })), { u1 }), "action 战斗：P1 打出指令生效")
        AssertEqual(u2:GetStat("defense"), 3, "action 战斗：目标防御 6 - 3 = 3")
        AssertEqual(u1:GetStat("defense"), 3, "action 战斗：发起者防御 5 - 2 = 3")
    end

    -- 5 加入战场（目标入场本方支援阵线）
    do
        local tid = NewBattle()
        local u3 = MakeUnit("A_JBF", "P1", { unitType = "infantry", attack = 1, defense = 1 })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_jbf", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 5,
        })), { u3 }), "action 加入战场：P1 打出指令生效")
        AssertEqual(ZoneOf(tid, u3), "support", "action 加入战场：目标加入本方支援阵线")
    end

    -- 6 加入前线（目标直接入场前线）
    do
        local tid = NewBattle()
        local u3 = MakeUnit("A_JFL", "P1", { unitType = "infantry", attack = 1, defense = 1 })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_jfl", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 6,
        })), { u3 }), "action 加入前线：P1 打出指令生效")
        AssertEqual(ZoneOf(tid, u3), "frontline", "action 加入前线：目标直接加入前线")
    end

    -- 7 压制
    do
        local tid, _, u2 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_suppress", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 7,
        })), { u2 }), "action 压制：P1 打出指令生效")
        AssertEqual(KARDS.Battle.KeywordStates[tid].Suppressed[u2], true, "action 压制：目标被压制")
    end

    -- 8 抑制
    do
        local tid, _, u2 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_neutralize", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 8,
        })), { u2 }), "action 抑制：P1 打出指令生效")
        AssertEqual(KARDS.Battle.KeywordStates[tid].Inhibited[u2], true, "action 抑制：目标被抑制")
    end

    -- 9 转换（无类型输入，记录 convert 刻）
    do
        local tid, _, u2 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_convert", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 9,
        })), { u2 }), "action 转换：P1 打出指令生效")
        AssertTrue(HasTickOp(tid, u2, "convert"), "action 转换：记录 convert 刻")
    end

    -- 9b 转换（指定「转换目标卡」：整体换卡，阵线与槽位不变）
    -- 目标卡数据来自编辑器存档，测试用桩替代文件读取，避免依赖具体卡文件存在
    do
        local tid = NewBattle()
        local u1 = MakeUnit("A_P1", "P1", { unitType = "infantry", attack = 3, defense = 5 })
        local u2 = MakeUnit("A_P2", "P2", { unitType = "fighter", attack = 2, defense = 6,
            convertTarget = "test_convert_target" })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        KARDS.Battle:SimBeginTurn("P1")
        local line, slot = KARDS.Battlefield:FindCardSlot(tid, u2)
        AssertTrue(line ~= nil and slot ~= nil, "action 转换指定目标卡 前置：目标已在场")
        local oldLine, oldSlot = line, slot
        local SaveSystem = KARDS.CardEditor and KARDS.CardEditor.SaveSystem
        local savedGetCardInfo = SaveSystem and SaveSystem.GetCardInfo
        if SaveSystem then
            SaveSystem.GetCardInfo = function()
                return { cardAppearance = {
                    cardType = "tank", attack = 4, defense = 5, cost = 2, actionCost = 1,
                } }
            end
        end
        local ok = PlayCommand(MakeCommandCard("cmd_convert_target", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 9,
        })), { u2 })
        if SaveSystem and savedGetCardInfo then SaveSystem.GetCardInfo = savedGetCardInfo end
        AssertTrue(ok, "action 转换指定目标卡：P1 打出指令生效")
        local newCard = oldLine[oldSlot]
        AssertTrue(newCard ~= nil and newCard ~= u2, "action 转换指定目标卡：原槽位换为新卡")
        AssertEqual(newCard:GetOwner(), "P2", "action 转换指定目标卡：新卡归属为原归属方")
        AssertEqual(newCard:GetStat("attack"), 4, "action 转换指定目标卡：新卡按目标卡数据重置攻击 4")
        AssertEqual(newCard:GetStat("defense"), 5, "action 转换指定目标卡：新卡按目标卡数据重置防御 5")
        AssertEqual(ZoneOf(tid, u2), nil, "action 转换指定目标卡：旧卡不再在场")
        AssertTrue(HasTickOp(tid, newCard, "convert"), "action 转换指定目标卡：记录 convert 刻")
    end

    -- 10 修复（目标防御 +1）
    do
        local tid, _, u2 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_repair", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 10,
        })), { u2 }), "action 修复：P1 打出指令生效")
        AssertEqual(u2:GetStat("defense"), 7, "action 修复：目标防御 6 + 1 = 7")
    end

    -- 11 控制（目标归属转移为 P1）
    do
        local tid, _, u2 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_control", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 11,
        })), { u2 }), "action 控制：P1 打出指令生效")
        AssertEqual(u2:GetOwner(), "P1", "action 控制：目标归属转移为 P1")
    end

    -- 12 免疫（HasActiveKeyword 免疫生效）
    do
        local tid, _, u2 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_immune", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 12,
        })), { u2 }), "action 免疫：P1 打出指令生效")
        AssertEqual(KARDS.Battle:HasActiveKeyword(tid, u2, "immune"), true, "action 免疫：目标免疫生效")
    end

    -- 13 情报（敌方手牌有牌 → 触发情报记录 intelligence 刻）
    do
        local tid, _, u2 = SetupActionField()
        GiveHand(tid, "P1", MakeUnit("A_INT1", "P1", { attack = 1, defense = 1 }))
        GiveHand(tid, "P1", MakeUnit("A_INT2", "P1", { attack = 1, defense = 1 }))
        AssertTrue(PlayCommand(MakeCommandCard("cmd_intel", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 13,
        })), { u2 }), "action 情报：P1 打出指令生效")
        AssertTrue(HasTickOp(tid, u2, "intelligence"), "action 情报：记录 intelligence 刻")
    end

    -- 14 造成伤害（目标防御 -N）
    do
        local tid, _, u2 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_damage", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 14, ["number_2"] = 3,
        })), { u2 }), "action 造成伤害：P1 打出指令生效")
        AssertEqual(u2:GetStat("defense"), 3, "action 造成伤害：目标防御 6 - 3 = 3")
    end

    -- 15 触发关键字效果（对象槽目标 + 关键字槽）
    do
        local tid, _, u2 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_triggerkw", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 15, ["select_6"] = u2, ["select_7"] = "deathrattle",
        })), {}), "action 触发关键字效果：P1 打出指令生效")
        AssertTrue(HasTickOp(tid, u2, "trigger"), "action 触发关键字效果：记录 trigger 刻")
    end

    -- 16 返回手牌（目标离场入所有者手牌）
    do
        local tid, u1 = SetupActionField()
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ret2hand", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 16,
        })), { u1 }), "action 返回手牌：P1 打出指令生效")
        AssertEqual(ZoneOf(tid, u1), nil, "action 返回手牌：目标离开战场")
        AssertTrue(HandContains(tid, "P1", u1), "action 返回手牌：目标进入所有者手牌")
    end

    -- 17 召唤单位（对象槽单位加入本方支援阵线）
    do
        local tid = NewBattle()
        local u3 = MakeUnit("A_SUM", "P1", { unitType = "infantry", attack = 1, defense = 1 })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_summon", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 17, ["select_8"] = u3, ["select_9"] = 1,
        })), {}), "action 召唤单位：P1 打出指令生效")
        AssertEqual(ZoneOf(tid, u3), "support", "action 召唤单位：目标加入本方支援阵线")
    end

    -- 18 升为老兵（套用老兵外观并触发「升级」开始点）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("A_VET", "P1", {
            unitType = "infantry", attack = 2, defense = 3, cost = 1, actionCost = 1,
            keywords = { "can_elevate_to_veteran" },
            veteranAppearance = { attack = 6, defense = 7, cost = 2, actionCost = 0,
                quality = "special", keywords = { "veteran" } },
        })
        -- 2026-08-15 调整：部署需支付 1 指挥点（readme 7.1 操作），开局 0 点 → 先补给 1 点
        KARDS.CommandPoints:AddSlot(tid, "P1")
        KARDS.CommandPoints:BeginTurn(tid, "P1")
        AssertTrue(KARDS.Battle:SimDeploy(u1, 3), "action 升为老兵 前置：目标部署成功")
        AssertTrue(PlayCommand(MakeCommandCard("cmd_vet", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 18,
        })), { u1 }), "action 升为老兵：P1 打出指令生效")
        AssertEqual(u1:GetStat("attack"), 6, "action 升为老兵：攻击重置为老兵外观 6")
        AssertEqual(u1:GetStat("defense"), 7, "action 升为老兵：防御重置为老兵外观 7")
        AssertEqual(u1:GetCost(), 2, "action 升为老兵：费用重置为老兵外观 2")
        AssertEqual(u1:GetActionCost(), 0, "action 升为老兵：行动花费重置为 0")
        AssertTrue(u1:IsVeteran(), "action 升为老兵：目标标记为老兵")
        AssertTrue(u1:HasKeyword("veteran"), "action 升为老兵：目标词条替换为老兵")
        AssertTrue(not u1:CanElevateToVeteran(), "action 升为老兵：升级后不再可升为老兵")
        AssertTrue(HasTickOp(tid, u1, "veteran"), "action 升为老兵：记录 veteran 刻")
        -- 返回手牌回退：恢复为初始非老兵状态（可再次升级）
        AssertTrue(KARDS.Battle:SimReturnToHand(u1), "action 升为老兵：老兵返回手牌成功")
        AssertEqual(u1:GetStat("attack"), 2, "action 升为老兵回退：攻击恢复为初始 2")
        AssertEqual(u1:GetStat("defense"), 3, "action 升为老兵回退：防御恢复为初始 3")
        AssertEqual(u1:GetCost(), 1, "action 升为老兵回退：费用恢复为初始 1")
        AssertEqual(u1:GetActionCost(), 1, "action 升为老兵回退：行动花费恢复为初始 1")
        AssertTrue(not u1:IsVeteran(), "action 升为老兵回退：清除老兵标记")
        AssertTrue(u1:CanElevateToVeteran(), "action 升为老兵回退：恢复可升为老兵词条")
    end
end

-- ====================================================================
-- action 取消分支：4 项状态解除
-- ====================================================================
local function RunActionCancelTest()
    -- 解除压制
    do
        local tid, _, u2 = SetupActionField()
        KARDS.Battle:SimSuppress(u2)
        AssertEqual(KARDS.Battle.KeywordStates[tid].Suppressed[u2], true, "action 解除压制 前置：目标被压制")
        AssertTrue(PlayCommand(MakeCommandCard("cmd_unsuppress", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 2, ["select_10"] = 1,
        })), { u2 }), "action 解除压制：P1 打出指令生效")
        AssertEqual(KARDS.Battle.KeywordStates[tid].Suppressed[u2], nil, "action 解除压制：目标解除压制状态")
    end

    -- 解除抑制
    do
        local tid, _, u2 = SetupActionField()
        KARDS.Battle:SimInhibit(u2)
        AssertEqual(KARDS.Battle.KeywordStates[tid].Inhibited[u2], true, "action 解除抑制 前置：目标被抑制")
        AssertTrue(PlayCommand(MakeCommandCard("cmd_unneutralize", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 2, ["select_10"] = 2,
        })), { u2 }), "action 解除抑制：P1 打出指令生效")
        AssertEqual(KARDS.Battle.KeywordStates[tid].Inhibited[u2], nil, "action 解除抑制：目标解除抑制状态")
    end

    -- 解除控制（归属还原为原玩家）
    do
        local tid, _, u2 = SetupActionField()
        KARDS.Battle:SimControl(u2, "P1")
        AssertEqual(u2:GetOwner(), "P1", "action 解除控制 前置：目标被控制为 P1")
        AssertTrue(PlayCommand(MakeCommandCard("cmd_uncontrol", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 2, ["select_10"] = 3,
        })), { u2 }), "action 解除控制：P1 打出指令生效")
        AssertEqual(u2:GetOwner(), "P2", "action 解除控制：归属还原为原玩家 P2")
    end

    -- 解除免疫
    do
        local tid, _, u2 = SetupActionField()
        KARDS.Battle:SimImmune(u2)
        AssertEqual(KARDS.Battle:HasActiveKeyword(tid, u2, "immune"), true, "action 解除免疫 前置：目标免疫")
        AssertTrue(PlayCommand(MakeCommandCard("cmd_unimmune", MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 2, ["select_10"] = 4,
        })), { u2 }), "action 解除免疫：P1 打出指令生效")
        AssertEqual(KARDS.Battle:HasActiveKeyword(tid, u2, "immune"), false, "action 解除免疫：目标不再免疫")
    end
end

-- ====================================================================
-- action 被消灭分支
-- ====================================================================
local function RunActionDestroyTest()
    local tid, _, u2 = SetupActionField()
    AssertTrue(PlayCommand(MakeCommandCard("cmd_destroy", MakeBaseNode("action", ACTION_BASE, {
        ["select_2"] = 3,
    })), { u2 }), "action 被消灭：P1 打出指令生效")
    AssertEqual(ZoneOf(tid, u2), nil, "action 被消灭：目标离开战场")
end

-- ====================================================================
-- card 模板：友方/敌方 × 8 分支
-- ====================================================================

-- 搭建双方各 5 张卡组的战斗场景（4 单位 + 1 指令，洗牌顺序不依赖）
local function SetupCardField()
    local tid = NewBattle()
    for _, owner in ipairs({ "P1", "P2" }) do
        KARDS.Battle:SimSetupDeck(owner, {
            MakeUnit("CD1_" .. owner, owner, { unitType = "infantry", attack = 1, defense = 1 }),
            MakeUnit("CD2_" .. owner, owner, { unitType = "tank", attack = 2, defense = 2 }),
            KARDS.CardInterface.CreateMockCard("CD3_" .. owner, "command", owner, { cost = 0 }),
            MakeUnit("CD4_" .. owner, owner, { unitType = "artillery", attack = 3, defense = 3 }),
            MakeUnit("CD5_" .. owner, owner, { unitType = "bomber", attack = 4, defense = 4 }),
        })
    end
    return tid
end

-- 单侧完整 8 分支场景（side=1 友方 P1 / side=2 敌方 P2）
-- 每个分支独立 SetupCardField()：SimPlayCard 不打出手牌移除，共享牌桌会污染后续分支的手牌/卡组断言
local function RunCardSideTest(side, target)
    local sideLabel = (side == 1) and "友方" or "敌方"
    -- 1 抽取：手牌 +2、卡组 -2
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_draw", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 1, ["number_1"] = 2, ["select_3"] = 1,
        }))
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "card 抽取(" .. sideLabel .. ")：P1 打出指令生效")
        local handBonus = (side == 1) and 1 or 0 -- 友方手牌含指令卡；敌方手牌为空
        AssertEqual(KARDS.Deck:HandSize(tid, target), 2 + handBonus, "card 抽取(" .. sideLabel .. ")：手牌 +2")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 3, "card 抽取(" .. sideLabel .. ")：卡组 5 - 2 = 3")
    end

    -- 2 复制：手牌 +1 克隆（不取走源卡，卡组不变）
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_copy", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 2, ["number_2"] = 1, ["select_6"] = 1,
        }))
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "card 复制(" .. sideLabel .. ")：P1 打出指令生效")
        local hand = KARDS.Deck:GetHand(tid, target)
        AssertEqual(#hand, (side == 1) and 2 or 1, "card 复制(" .. sideLabel .. ")：手牌 +1")
        AssertTrue((hand[#hand] and hand[#hand]:GetID():find("_copy") ~= nil),
            "card 复制(" .. sideLabel .. ")：新增卡为克隆（ID 带 _copy）")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 5, "card 复制(" .. sideLabel .. ")：卡组不变 5")
    end

    -- 3 弃掉·卡组顶：卡组 -1（select_7 位置 2=卡组顶）
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_discard", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 3, ["number_3"] = 1, ["select_7"] = 2,
        }))
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "card 弃掉(" .. sideLabel .. ")：P1 打出指令生效")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 4, "card 弃掉(" .. sideLabel .. ")：卡组 5 - 1 = 4")
    end

    -- 3b 弃掉·手中·第 N 张（select_7=1 手中 + select_8=2 第 + number_4 序数）：
    --    无玩家选择回调时按数值序数直接弃该方手牌第 N 张（卡组不变）
    do
        local tid = SetupCardField()
        local extra = MakeUnit("C_DISC_" .. side, target, { attack = 1, defense = 1 })
        GiveHand(tid, target, extra) -- 先放入目标方手牌（index 1），供序数定位
        local cmd = MakeCommandCard("cmd_discard_hand", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 3, ["select_7"] = 1, ["select_8"] = 2, ["number_4"] = 1,
        }))
        GiveHand(tid, "P1", cmd)
        local handBefore = KARDS.Deck:HandSize(tid, target)
        AssertTrue(PlayCommand(cmd), "card 弃掉·手中·第 N 张(" .. sideLabel .. ")：P1 打出指令生效")
        AssertEqual(KARDS.Deck:HandSize(tid, target), handBefore - 1,
            "card 弃掉·手中·第 N 张(" .. sideLabel .. ")：手牌 -1")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 5,
            "card 弃掉·手中·第 N 张(" .. sideLabel .. ")：卡组不变 5")
    end

    -- 4 开发：从开发池对象组变量（{$}，如「卡组中单位」）随机 3 选 1 加入手牌
    --   （readme 7.2.1：开发 = 从特定卡池随机 3 张选 1 加入手牌；2026-10-02 用户规格：
    --    加入手牌的是「复制一份」，卡组原卡保留、卡组余量不变）
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_develop", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 4, ["number_5"] = 1,
            ["select_9"] = "卡组中单位",
        }))
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "card 开发(" .. sideLabel .. ")：P1 打出指令生效")
        -- 开发池「卡组中单位」= 目标方卡组 4 单位；开发 1 张复制入手，卡组余量不变
        local handBonus = (side == 1) and 1 or 0 -- 友方手牌含指令卡；敌方手牌为空
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 5, "card 开发(" .. sideLabel .. ")：卡组不变 5")
        AssertEqual(KARDS.Deck:HandSize(tid, target), 1 + handBonus, "card 开发(" .. sideLabel .. ")：手牌 +1")
        -- develop 刻发起者 = 开发出的卡（非指令卡），扫描任意刻的 develop 操作
        local hasDevelop = false
        for i = 1, KARDS.TickLog:Count(tid) do
            local t = KARDS.TickLog:GetTick(tid, i)
            local ops = t and t[1] and t[1][2]
            if ops then
                for _, op in ipairs(ops) do
                    if op == "develop" then hasDevelop = true end
                end
            end
        end
        AssertTrue(hasDevelop, "card 开发(" .. sideLabel .. ")：记录 develop 刻")
    end

    -- 5 选择（观星）：从卡组顶 count 张选 1 张加入手牌，其余按序回卡组底
    --   （2026-09-26 语义重写：卡组 -1、手牌 +1；scry 刻发起者 = 选中的卡）
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_scry", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 5, ["number_6"] = 2,
        }))
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "card 选择(" .. sideLabel .. ")：P1 打出指令生效")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 4, "card 选择(" .. sideLabel .. ")：卡组 -1（顶 2 选 1 入手）")
        AssertTrue(HasAnyTickOp(tid, "scry"), "card 选择(" .. sideLabel .. ")：记录 scry 刻")
    end

    -- 6 爆牌：卡组 -2
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_burn", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 6, ["number_7"] = 2,
        }))
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "card 爆牌(" .. sideLabel .. ")：P1 打出指令生效")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 3, "card 爆牌(" .. sideLabel .. ")：卡组 5 - 2 = 3")
    end

    -- 7 洗切卡组：卡组数量不变（顺序随机无法断言，验证管线执行）
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_shuffledeck", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 7,
        }))
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "card 洗切卡组(" .. sideLabel .. ")：P1 打出指令生效")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 5, "card 洗切卡组(" .. sideLabel .. ")：卡组数量不变")
    end

    -- 8 洗入：手牌 1 张洗入卡组（手牌 -1、卡组 +1）
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_shuffleinto", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 8, ["select_10"] = 1, ["select_11"] = 1, ["number_8"] = 1,
        }))
        GiveHand(tid, "P1", cmd)
        if side == 2 then
            GiveHand(tid, "P2", MakeUnit("C_HAND_P2", "P2", { attack = 1, defense = 1 })) -- 敌方手牌需有牌可洗入
        end
        AssertTrue(PlayCommand(cmd), "card 洗入(" .. sideLabel .. ")：P1 打出指令生效")
        AssertEqual(KARDS.Deck:HandSize(tid, target), 0, "card 洗入(" .. sideLabel .. ")：手牌 -1")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 6, "card 洗入(" .. sideLabel .. ")：卡组 5 + 1 = 6")
    end

    -- 8b 洗入·手牌中·指定的：走通用指定操作 Specify.HandCard（注入 handPicker 选 spec 洗入，
    -- 非随机）：手牌 -1（剩 keep）、卡组 +1、指定牌移出手牌
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_si_spechand", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 8, ["select_10"] = 1, ["select_11"] = 2, ["number_8"] = 1,
        }))
        GiveHand(tid, "P1", cmd)
        local keep = MakeUnit("C_KEEP_" .. side, target, { attack = 1, defense = 1 })
        local spec = MakeUnit("C_SPEC_" .. side, target, { attack = 2, defense = 2 })
        GiveHand(tid, target, keep)
        GiveHand(tid, target, spec)
        -- 注入指定手牌选择：按牌 ID 精确指定 spec（未来 UI 由玩家点击手牌 +「确定」提交）
        AssertTrue(PlayCommand(cmd, nil, { specify = { handPicker = function(hand)
            for _, c in ipairs(hand) do
                if c:GetID() == "C_SPEC_" .. side then return { c } end
            end
            return {}
        end } }), "card 洗入·手牌中·指定的(" .. sideLabel .. ")：P1 打出指令生效")
        local handBonus = (side == 1) and 1 or 0 -- 友方手牌含指令卡；敌方手牌不含
        AssertEqual(KARDS.Deck:HandSize(tid, target), 1 + handBonus, "card 洗入·手牌中·指定的(" .. sideLabel .. ")：手牌 2 - 1（剩 keep" .. ((side == 1) and " + 指令卡" or "") .. "）")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 6, "card 洗入·手牌中·指定的(" .. sideLabel .. ")：卡组 5 + 1 = 6")
        AssertTrue(not HandContains(tid, target, spec), "card 洗入·手牌中·指定的(" .. sideLabel .. ")：指定牌 spec 已移出手牌")
        AssertTrue(HandContains(tid, target, keep), "card 洗入·手牌中·指定的(" .. sideLabel .. ")：未指定牌 keep 保留在手牌")
    end

    -- 8c 洗入·指定的·手牌 N 张：走通用指定操作 Specify.HandCard（注入 handPicker 选指定牌洗入）
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_si_spec", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 8, ["select_10"] = 2, ["select_13"] = 1, ["number_10"] = 1,
        }))
        GiveHand(tid, "P1", cmd)
        local spec = MakeUnit("C_SPEC2_" .. side, target, { attack = 3, defense = 3 })
        GiveHand(tid, target, spec)
        AssertTrue(PlayCommand(cmd, nil, { specify = { handPicker = function(hand)
            for _, c in ipairs(hand) do
                if c:GetID() == "C_SPEC2_" .. side then return { c } end
            end
            return {}
        end } }), "card 洗入·指定的(" .. sideLabel .. ")：P1 打出指令生效")
        local handBonus = (side == 1) and 1 or 0 -- 友方手牌含指令卡；敌方手牌不含
        AssertEqual(KARDS.Deck:HandSize(tid, target), 0 + handBonus, "card 洗入·指定的(" .. sideLabel .. ")：手牌 -1")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 6, "card 洗入·指定的(" .. sideLabel .. ")：卡组 5 + 1 = 6")
        AssertTrue(not HandContains(tid, target, spec), "card 洗入·指定的(" .. sideLabel .. ")：指定牌已移出手牌")
    end

    -- 8d 洗入·指定的·场上：从该方支援阵线上的单位中洗入（缺省取候选前 N 张，无需注入）
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_si_specfield", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 8, ["select_10"] = 2, ["select_13"] = 2, ["number_10"] = 1,
        }))
        GiveHand(tid, "P1", cmd)
        local fld = MakeUnit("C_FLD_" .. side, target, { attack = 3, defense = 3 })
        AssertTrue(KARDS.Battle:SimDeploy(fld, 3), "card 洗入·指定的·场上(" .. sideLabel .. ")：前置部署成功")
        AssertTrue(PlayCommand(cmd), "card 洗入·指定的·场上(" .. sideLabel .. ")：P1 打出指令生效")
        AssertTrue(KARDS.Battlefield:FindCardZone(tid, fld) == nil,
            "card 洗入·指定的·场上(" .. sideLabel .. ")：场上单位已离场")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 6,
            "card 洗入·指定的·场上(" .. sideLabel .. ")：卡组 5 + 1 = 6")
    end

    -- 8e 洗入·凭空生成：从开发池变量（{$}，池解析同 develop）克隆 N 张随机插入卡组，手牌不变
    do
        local tid = SetupCardField()
        local cmd = MakeCommandCard("cmd_si_gen", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = side, ["select_2"] = 8, ["select_10"] = 3,
            ["select_12"] = "卡组中单位", ["number_9"] = 1,
        }))
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "card 洗入·凭空生成(" .. sideLabel .. ")：P1 打出指令生效")
        local handBonus = (side == 1) and 1 or 0
        AssertEqual(KARDS.Deck:HandSize(tid, target), 0 + handBonus,
            "card 洗入·凭空生成(" .. sideLabel .. ")：手牌不变")
        AssertEqual(KARDS.Deck:DeckSize(tid, target), 6,
            "card 洗入·凭空生成(" .. sideLabel .. ")：卡组 5 + 1 = 6")
    end
end

-- command 全组合（3 阵营 × 2 资源 × 3 操作 = 18）：P1 打出指令触发
-- 初始（StartBattle）：P1 先手 1 指挥点/1 槽，P2 后手 0 指挥点/0 槽（readme 7.1）
local function RunCommandTest()
    for side = 1, 3 do -- 阵营：1 友方 / 2 敌方 / 3 双方
        for res = 1, 2 do -- 资源：1 指挥点 / 2 指挥点槽
            for op = 1, 3 do -- 操作：1 增加 / 2 减少 / 3 设为
                local tid = NewBattle()
                local ci = (side - 1) * 6 + (res - 1) * 3 + op -- 组合编号 1..18
                local cmd = MakeCommandCard("cmd_cp" .. ci, MakeBaseNode("command", COMMAND_BASE, {
                    ["select_1"] = side, ["select_2"] = res, ["select_3"] = op, ["number_1"] = 2,
                }))
                GiveHand(tid, "P1", cmd)
                local label = ("command 组合%d(阵营%d 资源%d 操作%d)"):format(ci, side, res, op)
                -- 变更前数值
                local function valueOf(p)
                    return (res == 1) and KARDS.CommandPoints:GetPoints(tid, p)
                        or KARDS.CommandPoints:GetSlots(tid, p)
                end
                local beforeP1, beforeP2 = valueOf("P1"), valueOf("P2")
                AssertTrue(PlayCommand(cmd), label .. "：P1 打出指令生效")
                -- 期望（对齐骨架：槽受绝对上限 24 约束，指挥点无即时上限；减少最低 0）
                local function expected(before)
                    if op == 2 then return math.max(0, before - 2) end
                    if op == 3 then return (res == 2) and math.min(2, KARDS.CommandPoints.MAX_SLOT_ABSOLUTE) or 2 end
                    return (res == 2) and math.min(before + 2, KARDS.CommandPoints.MAX_SLOT_ABSOLUTE) or (before + 2)
                end
                if side == 1 or side == 3 then
                    AssertEqual(valueOf("P1"), expected(beforeP1),
                        label .. "：P1 " .. ((res == 1) and "指挥点" or "指挥点槽"))
                end
                if side == 2 or side == 3 then
                    AssertEqual(valueOf("P2"), expected(beforeP2),
                        label .. "：P2 " .. ((res == 1) and "指挥点" or "指挥点槽"))
                end
                -- 刻记录断言（代表性组合：友方/敌方 × 指挥点/指挥点槽 × 增加）
                if ci == 1 then
                    AssertTrue(HasTickOp(tid, KARDS.Battlefield:GetHQ(tid, "P1"), "command_points"),
                        label .. "：记录 command_points 刻")
                elseif ci == 4 then
                    AssertTrue(HasTickOp(tid, KARDS.Battlefield:GetHQ(tid, "P1"), "command_slot"),
                        label .. "：记录 command_slot 刻")
                elseif ci == 7 then
                    AssertTrue(HasTickOp(tid, KARDS.Battlefield:GetHQ(tid, "P2"), "command_points"),
                        label .. "：记录 command_points 刻（敌方）")
                elseif ci == 10 then
                    AssertTrue(HasTickOp(tid, KARDS.Battlefield:GetHQ(tid, "P2"), "command_slot"),
                        label .. "：记录 command_slot 刻（敌方）")
                end
            end
        end
    end
end

-- condition 测试：数量判断（5 种统计方式 × 运算符 × 值）+ 关键字检查
-- 战斗场景：P1 支援阵线部署 infantry(3/5, blitz) + artillery(2/4)，P2 无单位（仅总部）
-- P1 打出指令触发 condition 节点，检查 node.data 结果
local function RunConditionTest()
    -- ============================================================
    -- 数量判断：5 种统计方式 × 带运算符比较
    -- ============================================================
    local tid = NewBattle()
    -- 部署 P1 单位：infantry(3/5, blitz, 德国) + artillery(2/4, 美国)（国籍供「不同国籍单位数」H3 统计）
    local u1 = MakeUnit("inf_cond", "P1", { attack = 3, defense = 5, keywords = { "blitz" }, country = "germany" })
    local u2 = MakeUnit("art_cond", "P1", { attack = 2, defense = 4, country = "usa" })
    GiveHand(tid, "P1", u1)
    GiveHand(tid, "P1", u2)
    -- 推进回合（使单位可部署）后部署到支援阵线
    KARDS.Battle:SimBeginTurn("P2")
    KARDS.Battle:SimEndTurn("P2")
    KARDS.Battle:SimDeploy(u1, 3) -- 部署到槽 3
    KARDS.Battle:SimDeploy(u2, 4) -- 部署到槽 4

    -- 测试 1：友方 最大攻击力单位 > 2 → true（max=3）
    local function makeCountCheck(side, countType, operator, value)
        return MakeBaseNode("condition", CONDITION_BASE, {
            ["select_1"] = 1,      -- 判断数量
            ["select_2"] = side,   -- 1 敌方 / 2 友方
            ["number_1"] = countType, -- 2=maxAttack 3=minAttack 4=maxDefense 5=minDefense
            ["select_3"] = operator, -- 1= 2> 3< 4>= 5<=
            ["number_2"] = value,
        })
    end
    local function runCondAndCheck(node, expectedResult, checkLabel)
        local cmd = MakeCommandCard("cond_cmd_" .. checkLabel, node)
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "condition 打出指令成功：" .. checkLabel)
        -- 检查 node.data 中的结果
        local nData = cmd.effect.nodes[1].data
        AssertEqual(nData["p布尔值"], expectedResult, "condition " .. checkLabel .. "：p布尔值")
        return nData
    end
    -- 友方 maxAttack > 2 → true
    local n1 = makeCountCheck(2, 2, 2, 2)
    runCondAndCheck(n1, true, "友方maxAttack>2")
    -- 友方 maxAttack = 3 → true
    local n2 = makeCountCheck(2, 2, 1, 3)
    runCondAndCheck(n2, true, "友方maxAttack=3")
    -- 友方 maxAttack = 2 → false
    local n3 = makeCountCheck(2, 2, 1, 2)
    runCondAndCheck(n3, false, "友方maxAttack=2")
    -- 友方 minAttack = 2 → true
    local n4 = makeCountCheck(2, 3, 1, 2)
    runCondAndCheck(n4, true, "友方minAttack=2")
    -- 友方 maxDefense = 5 → true
    local n5 = makeCountCheck(2, 4, 1, 5)
    runCondAndCheck(n5, true, "友方maxDefense=5")
    -- 友方 minDefense = 4 → true
    local n6 = makeCountCheck(2, 5, 1, 4)
    runCondAndCheck(n6, true, "友方minDefense=4")
    -- 友方 maxAttack >= 3 → true
    local n7 = makeCountCheck(2, 2, 4, 3)
    runCondAndCheck(n7, true, "友方maxAttack>=3")
    -- 友方 maxAttack <= 2 → false
    local n8 = makeCountCheck(2, 2, 5, 2)
    runCondAndCheck(n8, false, "友方maxAttack<=2")
    -- 敌方 maxAttack = 0 → true（无我方以外单位，maxAttack=0）
    local n9 = makeCountCheck(1, 2, 1, 0)
    runCondAndCheck(n9, true, "敌方maxAttack=0")
    -- 敌方 maxAttack > 0 → false
    local n10 = makeCountCheck(1, 2, 2, 0)
    runCondAndCheck(n10, false, "敌方maxAttack>0(f)")
    -- 不同国籍单位数（H3 修复：按 GetCountry 去重统计）：u1 德国 + u2 美国 → 友方 = 2
    local n11 = makeCountCheck(2, 1, 1, 2)
    runCondAndCheck(n11, true, "友方不同国籍单位数=2")
    local n12 = makeCountCheck(2, 1, 1, 1)
    runCondAndCheck(n12, false, "友方不同国籍单位数=1(f)")
    -- 敌方（无单位在场）不同国籍 = 0
    local n13 = makeCountCheck(1, 1, 1, 0)
    runCondAndCheck(n13, true, "敌方不同国籍单位数=0")

    -- ============================================================
    -- 关键字检查
    -- ============================================================
    -- 检查 u1（infantry, blitz）是否有 blitz → true
    local nodeK1 = MakeBaseNode("condition", CONDITION_BASE, {
        ["select_1"] = 2,       -- 关键字检查
        ["select_4"] = u1,      -- 目标卡牌
        ["select_5"] = "blitz", -- 关键字
    })
    local cmdK1 = MakeCommandCard("cond_kw_blitz", nodeK1)
    GiveHand(tid, "P1", cmdK1)
    AssertTrue(PlayCommand(cmdK1), "condition 关键字检查打出指令成功")
    local k1Data = cmdK1.effect.nodes[1].data
    AssertEqual(k1Data["p是否有关键字"], true, "condition 关键字检查 blitz：p是否有关键字")
    AssertEqual(k1Data["n比较结果"], 0, "condition 关键字检查 blitz：n比较结果")

    -- 检查 u1 是否有 ambush → false
    local nodeK2 = MakeBaseNode("condition", CONDITION_BASE, {
        ["select_1"] = 2,       -- 关键字检查
        ["select_4"] = u1,      -- 目标卡牌
        ["select_5"] = "ambush",-- 关键字
    })
    local cmdK2 = MakeCommandCard("cond_kw_ambush", nodeK2)
    GiveHand(tid, "P1", cmdK2)
    AssertTrue(PlayCommand(cmdK2), "condition 关键字检查 ambush 打出指令成功")
    local k2Data = cmdK2.effect.nodes[1].data
    AssertEqual(k2Data["p是否有关键字"], false, "condition 关键字检查 ambush：p是否有关键字")
end

-- ====================================================================
-- condition 双输出点分支测试（模拟 if else 结构）
-- P1 打出指令触发 condition 节点，判断结果决定信号走向：
--   满足 → satisfied 端口 → 抽 1 张；不满足 → not_satisfied 端口 → 抽 2 张
-- 断言 P1 手牌 / 卡组变化验证分支信号是否按预设走向传递（另一分支不执行）
-- 依赖：ExecuteEffect 控制流模式（effect.connections 驱动节点间连线）
-- ====================================================================
local function RunConditionBranchTest()
    -- 场景 A：战场满足条件（友方 maxAttack=5 >= 3）→ 走 satisfied → 抽 1 张
    do
        local tid = NewBattle()
        KARDS.Battle:SimSetupDeck("P1", {
            MakeUnit("BR_A1", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_A2", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_A3", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_A4", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_A5", "P1", { attack = 1, defense = 1 }),
        })
        KARDS.Battle:SimDeploy(MakeUnit("BR_AU", "P1", { attack = 5, defense = 5 }), 3) -- 友方 maxAttack = 5
        -- condition：友方 maxAttack >= 3 → true；下游 抽1张（satisfied）/ 抽2张（not_satisfied）
        local cond = MakeBaseNode("condition", CONDITION_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["number_1"] = 2, ["select_3"] = 4, ["number_2"] = 3,
        }, { id = "condA", hasSecondOutput = true })
        local draw1 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 1, ["select_3"] = 1,
        }, { id = "draw1A" })
        local draw2 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2, ["select_3"] = 1,
        }, { id = "draw2A" })
        local cmd = MakeBranchCommandCard("cmd_branch_sat", { cond, draw1, draw2 }, {
            { fromNode = "condA", toNode = "draw1A", fromPort = "satisfied" },
            { fromNode = "condA", toNode = "draw2A", fromPort = "not_satisfied" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "condition 双输出 满足分支：P1 打出指令生效")
        -- 手牌 = 指令卡（打出不移除）+ 抽 1 张 = 2；卡组 5 - 1 = 4
        AssertEqual(KARDS.Deck:HandSize(tid, "P1"), 2, "condition 双输出 满足分支：手牌 1 + 抽 1 = 2")
        AssertEqual(KARDS.Deck:DeckSize(tid, "P1"), 4, "condition 双输出 满足分支：卡组 5 - 1 = 4（抽2张分支未执行）")
    end

    -- 场景 B：战场不满足条件（友方 maxAttack=1 < 3）→ 走 not_satisfied → 抽 2 张
    do
        local tid = NewBattle()
        KARDS.Battle:SimSetupDeck("P1", {
            MakeUnit("BR_B1", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_B2", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_B3", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_B4", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_B5", "P1", { attack = 1, defense = 1 }),
        })
        KARDS.Battle:SimDeploy(MakeUnit("BR_BU", "P1", { attack = 1, defense = 1 }), 3) -- 友方 maxAttack = 1
        local cond = MakeBaseNode("condition", CONDITION_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["number_1"] = 2, ["select_3"] = 4, ["number_2"] = 3,
        }, { id = "condB", hasSecondOutput = true })
        local draw1 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 1, ["select_3"] = 1,
        }, { id = "draw1B" })
        local draw2 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2, ["select_3"] = 1,
        }, { id = "draw2B" })
        local cmd = MakeBranchCommandCard("cmd_branch_not", { cond, draw1, draw2 }, {
            { fromNode = "condB", toNode = "draw1B", fromPort = "satisfied" },
            { fromNode = "condB", toNode = "draw2B", fromPort = "not_satisfied" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "condition 双输出 不满足分支：P1 打出指令生效")
        -- 手牌 = 指令卡 + 抽 2 张 = 3；卡组 5 - 2 = 3
        AssertEqual(KARDS.Deck:HandSize(tid, "P1"), 3, "condition 双输出 不满足分支：手牌 1 + 抽 2 = 3")
        AssertEqual(KARDS.Deck:DeckSize(tid, "P1"), 3, "condition 双输出 不满足分支：卡组 5 - 2 = 3（抽1张分支未执行）")
    end

    -- 场景 C：not_satisfied 端口无连线时，条件不满足 → 无下游信号 → 手牌/卡组不变
    do
        local tid = NewBattle()
        KARDS.Battle:SimSetupDeck("P1", {
            MakeUnit("BR_C1", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_C2", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_C3", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_C4", "P1", { attack = 1, defense = 1 }),
            MakeUnit("BR_C5", "P1", { attack = 1, defense = 1 }),
        })
        KARDS.Battle:SimDeploy(MakeUnit("BR_CU", "P1", { attack = 1, defense = 1 }), 3) -- 友方 maxAttack = 1
        local cond = MakeBaseNode("condition", CONDITION_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["number_1"] = 2, ["select_3"] = 4, ["number_2"] = 3,
        }, { id = "condC", hasSecondOutput = true })
        local draw1 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 1, ["select_3"] = 1,
        }, { id = "draw1C" })
        local cmd = MakeBranchCommandCard("cmd_branch_none", { cond, draw1 }, {
            { fromNode = "condC", toNode = "draw1C", fromPort = "satisfied" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "condition 双输出 无连线分支：P1 打出指令生效")
        AssertEqual(KARDS.Deck:HandSize(tid, "P1"), 1, "condition 双输出 无连线分支：not_satisfied 无下游，手牌不变 1")
        AssertEqual(KARDS.Deck:DeckSize(tid, "P1"), 5, "condition 双输出 无连线分支：卡组不变 5")
    end
end

-- ====================================================================
-- event_monitor 事件监测测试（判断节点）
-- 场景：P1 打出指令触发 event_monitor，在最近刻（TickLog）中检索「发起者属于监测阵营
-- 且操作类型匹配事件」的刻。断言 p触发事件 / t事件类型 / e事件目标。
-- 前置操作先产生目标刻（event_monitor 自身指令的 play_command 刻在效果之后才推，不干扰）
-- ====================================================================
local function RunEventMonitorTest()
    -- 打出指令(友方)：先打一张普通指令产生 play_command 刻 → 监测命中
    do
        local tid = NewBattle()
        local pre = MakeCommandCard("em_pre_play", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 0, ["select_3"] = 1,
        })) -- 抽取 0 张：仅产生刻，不动手牌
        GiveHand(tid, "P1", pre)
        AssertTrue(PlayCommand(pre), "event_monitor 前置：普通指令打出成功")
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, -- 友方
            ["select_2"] = 4, -- 打出指令
        })
        local cmd = MakeCommandCard("em_play_f", mon)
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 打出指令(友方)：打出指令生效")
        local d = cmd.effect.nodes[1].data
        AssertEqual(d["p触发事件"], true, "event_monitor 打出指令(友方)：p触发事件")
        AssertEqual(d["t事件类型"], "打出指令", "event_monitor 打出指令(友方)：t事件类型")
        AssertEqual(d["e事件目标"], pre, "event_monitor 打出指令(友方)：e事件目标=前置指令卡")
    end

    -- 打出指令(敌方)：前置刻发起者是 P1 → 敌方监测不命中
    do
        local tid = NewBattle()
        local pre = MakeCommandCard("em_pre_play2", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 0, ["select_3"] = 1,
        }))
        GiveHand(tid, "P1", pre)
        PlayCommand(pre)
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 2, -- 敌方
            ["select_2"] = 4,
        })
        local cmd = MakeCommandCard("em_play_e", mon)
        GiveHand(tid, "P1", cmd)
        PlayCommand(cmd)
        AssertEqual(cmd.effect.nodes[1].data["p触发事件"], false, "event_monitor 打出指令(敌方)：未触发")
    end

    -- 打出指令·时：触发情报（H1）：前置 SimUseIntel 产生 intelligence 刻（发起者=敌方单位，变更 +1）
    -- → 监测「打出指令-时：触发情报 = 1」命中（select_2=4, select_7=3, number_3=1）
    do
        local tid = NewBattle()
        local intelUnit = MakeUnit("em_intel", "P2", { keywords = { { "intel", 1 } } })
        KARDS.Battle:SimDeploy(intelUnit, 3)
        GiveHand(tid, "P1", MakeUnit("em_hand1", "P1", { attack = 1, defense = 1 }))
        KARDS.Battle:SimUseIntel(intelUnit) -- 情报 1 → intelligence 刻（发起者变更 +1）
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 2, -- 敌方（情报发起者 = 敌方单位）
            ["select_2"] = 4, -- 打出指令
            ["select_7"] = 3, -- 时：触发情报
            ["number_3"] = 1, -- = 1 张
        })
        local cmd = MakeCommandCard("em_intel_f", mon)
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 时：触发情报=1：打出指令生效")
        local d = cmd.effect.nodes[1].data
        AssertEqual(d["p触发事件"], true, "event_monitor 时：触发情报=1：p触发事件")
        AssertEqual(d["t事件类型"], "打出指令", "event_monitor 时：触发情报=1：t事件类型")
        AssertEqual(d["e事件目标"], intelUnit, "event_monitor 时：触发情报=1：e事件目标=情报单位")
        -- 数量不匹配：= 2 张 → 不命中
        local mon2 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 2, ["select_2"] = 4, ["select_7"] = 3, ["number_3"] = 2,
        })
        local cmd2 = MakeCommandCard("em_intel_no", mon2)
        GiveHand(tid, "P1", cmd2)
        PlayCommand(cmd2)
        AssertEqual(cmd2.effect.nodes[1].data["p触发事件"], false, "event_monitor 时：触发情报=2：数量不匹配未触发")
    end

    -- 加入(友方)：SimDeploy 产生 deploy 刻 → 命中
    do
        local tid = NewBattle()
        local u = MakeUnit("em_u3", "P1", { attack = 1, defense = 1 })
        KARDS.Battle:SimDeploy(u, 3)
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 6, -- 加入
        })
        local cmd = MakeCommandCard("em_join_f", mon)
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 加入(友方)：打出指令生效")
        local d = cmd.effect.nodes[1].data
        AssertEqual(d["p触发事件"], true, "event_monitor 加入(友方)：p触发事件")
        AssertEqual(d["t事件类型"], "加入", "event_monitor 加入(友方)：t事件类型")
        AssertEqual(d["e事件目标"], u, "event_monitor 加入(友方)：e事件目标=部署单位")
    end

    -- 加入(敌方)：部署的是 P1 单位 → 敌方监测不命中
    do
        local tid = NewBattle()
        KARDS.Battle:SimDeploy(MakeUnit("em_u4", "P1", { attack = 1, defense = 1 }), 3)
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 2, ["select_2"] = 6,
        })
        local cmd = MakeCommandCard("em_join_e", mon)
        GiveHand(tid, "P1", cmd)
        PlayCommand(cmd)
        AssertEqual(cmd.effect.nodes[1].data["p触发事件"], false, "event_monitor 加入(敌方)：未触发")
    end

    -- 总部(友方)：SimDealDamage 对 HQ 产生 deal_damage 刻（发起者=HQ）→ 命中
    do
        local tid = NewBattle()
        local hq = KARDS.Battlefield:GetHQ(tid, "P1")
        KARDS.Battle:SimDealDamage(nil, hq, 3)
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 3, -- 总部
        })
        local cmd = MakeCommandCard("em_hq_f", mon)
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 总部(友方)：打出指令生效")
        local d = cmd.effect.nodes[1].data
        AssertEqual(d["p触发事件"], true, "event_monitor 总部(友方)：p触发事件")
        AssertEqual(d["t事件类型"], "总部", "event_monitor 总部(友方)：t事件类型")
        AssertEqual(d["e事件目标"], hq, "event_monitor 总部(友方)：e事件目标=总部")
    end

    -- 总部防御约束：HQ 受 3 伤后防御 17；number_1=17 命中 / number_1=20 约束不匹配
    do
        local tid = NewBattle()
        KARDS.Battle:SimDealDamage(nil, KARDS.Battlefield:GetHQ(tid, "P1"), 3)
        local mon1 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 3, ["number_1"] = 17,
        })
        local cmd1 = MakeCommandCard("em_hq_ok", mon1)
        GiveHand(tid, "P1", cmd1)
        PlayCommand(cmd1)
        AssertEqual(cmd1.effect.nodes[1].data["p触发事件"], true, "event_monitor 总部防御=17：命中")
        local mon2 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 3, ["number_1"] = 20,
        })
        local cmd2 = MakeCommandCard("em_hq_no", mon2)
        GiveHand(tid, "P1", cmd2)
        PlayCommand(cmd2)
        AssertEqual(cmd2.effect.nodes[1].data["p触发事件"], false, "event_monitor 总部防御=20：约束不匹配")
    end

    -- 回合(友方, 开始)：SimBeginTurn 产生 turn_begin 刻（发起者=HQ）→ 命中；结束 → 恒不触发
    do
        local tid = NewBattle()
        KARDS.Battle:SimBeginTurn("P1")
        local mon1 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 8, ["select_9"] = 1, -- 回合-开始
        })
        local cmd1 = MakeCommandCard("em_turn_b", mon1)
        GiveHand(tid, "P1", cmd1)
        AssertTrue(PlayCommand(cmd1), "event_monitor 回合-开始(友方)：打出指令生效")
        local d1 = cmd1.effect.nodes[1].data
        AssertEqual(d1["p触发事件"], true, "event_monitor 回合-开始(友方)：p触发事件")
        AssertEqual(d1["t事件类型"], "回合", "event_monitor 回合-开始(友方)：t事件类型")
        local mon2 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 8, ["select_9"] = 2, -- 回合-结束
        })
        KARDS.Battle:SimEndTurn("P1") -- 产生 turn_end 刻（发起者 = P1 总部，M4a）
        local cmd2 = MakeCommandCard("em_turn_e", mon2)
        GiveHand(tid, "P1", cmd2)
        PlayCommand(cmd2)
        AssertEqual(cmd2.effect.nodes[1].data["p触发事件"], true, "event_monitor 回合-结束(友方)：SimEndTurn 产生 turn_end 刻，触发")
    end

    -- 单位(友方)：SimTriggerKeyword 产生 trigger 刻（发起者=目标单位）→ 命中
    -- 注意：经受类型须在 TickLog OpTypes 白名单（deathrattle 在列，blitz 不在）
    do
        local tid = NewBattle()
        local u = MakeUnit("em_u9", "P1", { attack = 1, defense = 1 })
        KARDS.Battle:SimTriggerKeyword(nil, u, "deathrattle")
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_3"] = 2, -- 单位-触发
        })
        local cmd = MakeCommandCard("em_unit_f", mon)
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 单位-触发(友方)：打出指令生效")
        local d = cmd.effect.nodes[1].data
        AssertEqual(d["p触发事件"], true, "event_monitor 单位-触发(友方)：p触发事件")
        AssertEqual(d["t事件类型"], "单位", "event_monitor 单位-触发(友方)：t事件类型")
        AssertEqual(d["e事件目标"], u, "event_monitor 单位-触发(友方)：e事件目标=触发单位")
    end

    -- 单位·有变化的·增加了（H4）：SimRepair 产生 stat_change 刻（受影响防御 +1）→
    -- 监测「单位-有变化的-属性防御-增加了 = 1」命中（select_2=2, select_3=1, select_4=4, select_5=2, number_2=1）
    do
        local tid = NewBattle()
        local u = MakeUnit("em_stat", "P1", { attack = 1, defense = 5 })
        KARDS.Battle:SimDeploy(u, 3)
        KARDS.Battle:SimRepair(u) -- 防御 +1 → stat_change 刻（受影响 { u, {stat_change}, "+1" }）
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, -- 友方
            ["select_2"] = 2, -- 单位
            ["select_3"] = 1, -- 有变化的
            ["select_4"] = 4, -- 属性 防御
            ["select_5"] = 2, -- 增加了
            ["number_2"] = 1, -- = 1
        })
        local cmd = MakeCommandCard("em_stat_inc", mon)
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 单位-有变化的-增加了=1：打出指令生效")
        local d = cmd.effect.nodes[1].data
        AssertEqual(d["p触发事件"], true, "event_monitor 单位-有变化的-增加了=1：p触发事件")
        AssertEqual(d["t事件类型"], "单位", "event_monitor 单位-有变化的-增加了=1：t事件类型")
        AssertEqual(d["e事件目标"], u, "event_monitor 单位-有变化的-增加了=1：e事件目标=变化单位")
        -- 为 = 2（当前防御 6 ≠ 2）→ 不命中
        local mon2 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_3"] = 1,
            ["select_4"] = 4, ["select_5"] = 4, ["number_2"] = 2,
        })
        local cmd2 = MakeCommandCard("em_stat_no", mon2)
        GiveHand(tid, "P1", cmd2)
        PlayCommand(cmd2)
        AssertEqual(cmd2.effect.nodes[1].data["p触发事件"], false, "event_monitor 单位-有变化的-为=2：防御 6 ≠ 2 未触发")
    end

    -- 单位·有变化的·属性筛选（M2）：SimRepair 产生防御 +N 刻（受影响标注 defense）；
    -- 选「属性=攻击」不命中、「属性=防御」命中
    do
        local tid = NewBattle()
        local u = MakeUnit("em_attr", "P1", { attack = 1, defense = 5 })
        KARDS.Battle:SimDeploy(u, 3)
        KARDS.Battle:SimRepair(u) -- 防御 +1 → stat_change 刻（属性 defense）
        local mon1 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_3"] = 1, ["select_4"] = 3, -- 有变化的/攻击
        })
        local cmd1 = MakeCommandCard("em_attr_atk", mon1)
        GiveHand(tid, "P1", cmd1)
        PlayCommand(cmd1)
        AssertEqual(cmd1.effect.nodes[1].data["p触发事件"], false, "event_monitor 有变化的·属性=攻击：防御变化不命中")
        local mon2 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_3"] = 1, ["select_4"] = 4, -- 有变化的/防御
        })
        local cmd2 = MakeCommandCard("em_attr_def", mon2)
        GiveHand(tid, "P1", cmd2)
        PlayCommand(cmd2)
        AssertEqual(cmd2.effect.nodes[1].data["p触发事件"], true, "event_monitor 有变化的·属性=防御：防御变化命中")
    end

    -- 单位·触发·能力/词条筛选（M3）：SimTriggerKeyword 产生 trigger 刻（受影响携带词条 id）；
    -- 选「亡计(last_strike)」命中（trigger 刻关键词 deathrattle 互为别名）、选「动员(mobilize)」不命中
    do
        local tid = NewBattle()
        local u = MakeUnit("em_abil", "P1", { attack = 1, defense = 1 })
        KARDS.Battle:SimTriggerKeyword(nil, u, "deathrattle") -- 亡计触发刻（关键词 deathrattle）
        local mon1 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_3"] = 2, ["select_6"] = "last_strike", -- 触发/亡计
        })
        local cmd1 = MakeCommandCard("em_abil_ls", mon1)
        GiveHand(tid, "P1", cmd1)
        PlayCommand(cmd1)
        AssertEqual(cmd1.effect.nodes[1].data["p触发事件"], true, "event_monitor 触发·亡计：deathrattle 刻命中")
        local mon2 = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_3"] = 2, ["select_6"] = "mobilize", -- 触发/动员
        })
        local cmd2 = MakeCommandCard("em_abil_mob", mon2)
        GiveHand(tid, "P1", cmd2)
        PlayCommand(cmd2)
        AssertEqual(cmd2.effect.nodes[1].data["p触发事件"], false, "event_monitor 触发·动员：亡计刻不命中")
    end

    -- 触发反制(友方)：引擎钩子拦截产生 counter 刻（发起者=被拦截指令卡）→ 命中（M4b）
    do
        local tid = NewBattle()
        local dummy = MakeCommandCard("em_counter_dummy", MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 0, ["select_3"] = 1,
        }))
        GiveHand(tid, "P1", dummy)
        -- 反制钩子：仅拦截 dummy（先产生 counter 刻，再打监测指令）
        KARDS.EngineHooks.Register(tid, KARDS.EngineHooks.HookPoints.OnBeforePlayCard, "em_counter_hook", function(args)
            if args.card == dummy then args.intercepted = true end
            return args
        end, KARDS.EngineHooks.TYPE_EFFECT)
        PlayCommand(dummy) -- 被拦截 → play_command + counter 刻
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 5,
        })
        local cmd = MakeCommandCard("em_counter", mon)
        GiveHand(tid, "P1", cmd)
        PlayCommand(cmd)
        local d = cmd.effect.nodes[1].data
        AssertEqual(d["p触发事件"], true, "event_monitor 触发反制(友方)：拦截产生 counter 刻，触发")
        AssertEqual(d["t事件类型"], "触发反制", "event_monitor 触发反制(友方)：t事件类型")
        AssertEqual(d["e事件目标"], dummy, "event_monitor 触发反制(友方)：e事件目标=被拦截指令卡")
    end

    -- 玩家(友方)：SimDraw 产生 draw 刻（发起者=抽到的牌，第三部分 P1 手牌 +1）→ 命中「抽牌 = 1 张」
    do
        local tid = NewBattle()
        local pool = {}
        for i = 1, 5 do pool[i] = KARDS.CardInterface.CreateMockCard("EMPD_" .. i, "unit", "P1", {}) end
        KARDS.Battle:SimSetupDeck("P1", pool)
        KARDS.Battle:SimDraw("P1", 1) -- 抽 1 张：draw 刻 + 手牌 +1
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 7, ["select_8"] = 1, -- 玩家 / @player_actions 抽牌
            ["number_4"] = 1,                                     -- = 1 张
        })
        local cmd = MakeCommandCard("em_player_f", mon)
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 玩家(友方)：打出指令生效")
        local d = cmd.effect.nodes[1].data
        AssertEqual(d["p触发事件"], true, "event_monitor 玩家(友方) 抽牌=1张：p触发事件")
        AssertEqual(d["t事件类型"], "玩家", "event_monitor 玩家(友方)：t事件类型")
        -- 发起者 = 抽到的牌：SetDeck 洗牌后抽取位置随机（sh_deck.lua SetDeck L142），
        -- 只能断言目标必为卡组中的某一张（不能按 pool[#pool] 预判）
        local targetIsPoolCard = false
        for _, c in ipairs(pool) do
            if d["e事件目标"] == c then targetIsPoolCard = true break end
        end
        AssertTrue(targetIsPoolCard, "event_monitor 玩家(友方)：e事件目标=抽到的牌（卡组中的一张）")
    end

    -- 玩家(友方) 抽牌张数不匹配：一刻内手牌 +1 ≠ 配置 2 张 → 不命中
    do
        local tid = NewBattle()
        local pool = {}
        for i = 1, 5 do pool[i] = KARDS.CardInterface.CreateMockCard("EMPD_" .. i, "unit", "P1", {}) end
        KARDS.Battle:SimSetupDeck("P1", pool)
        KARDS.Battle:SimDraw("P1", 1)
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 7, ["select_8"] = 1,
            ["number_4"] = 2, -- = 2 张（实际一刻内仅 +1）
        })
        local cmd = MakeCommandCard("em_player_f2", mon)
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 玩家(友方) 抽牌=2张：打出指令生效")
        AssertEqual(cmd.effect.nodes[1].data["p触发事件"], false, "event_monitor 玩家(友方) 抽牌=2张：一刻内变化量不匹配，未触发")
    end
end

-- ====================================================================
-- event_monitor 双输出点分支测试（模拟 if else 结构）
-- 触发 → satisfied 端口 → 抽 1 张；未触发 → not_satisfied 端口 → 抽 2 张
-- 断言 P1 手牌 / 卡组变化验证分支信号按预设走向传递（另一分支不执行）
-- ====================================================================
local function RunEventMonitorBranchTest()
    -- 场景 A：先 SimDeploy 制造「加入」刻 → 监测命中 → 触发分支 → 抽 1 张
    do
        local tid = NewBattle()
        KARDS.Battle:SimSetupDeck("P1", {
            MakeUnit("EMB_A1", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_A2", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_A3", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_A4", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_A5", "P1", { attack = 1, defense = 1 }),
        })
        local deployed = MakeUnit("EMB_AU", "P1", { attack = 1, defense = 1 })
        KARDS.Battle:SimDeploy(deployed, 3) -- 制造「加入」刻
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 6, -- 加入(友方)
        }, { id = "monA", hasSecondOutput = true })
        local draw1 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 1, ["select_3"] = 1,
        }, { id = "draw1A" })
        local draw2 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2, ["select_3"] = 1,
        }, { id = "draw2A" })
        local cmd = MakeBranchCommandCard("cmd_emb_a", { mon, draw1, draw2 }, {
            { fromNode = "monA", toNode = "draw1A", fromPort = "satisfied" },
            { fromNode = "monA", toNode = "draw2A", fromPort = "not_satisfied" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 双输出 触发分支：P1 打出指令生效")
        -- 手牌 = 指令卡（打出不移除）+ 抽 1 张 = 2；卡组 5 - 1 = 4
        AssertEqual(KARDS.Deck:HandSize(tid, "P1"), 2, "event_monitor 双输出 触发分支：手牌 1 + 抽 1 = 2")
        AssertEqual(KARDS.Deck:DeckSize(tid, "P1"), 4, "event_monitor 双输出 触发分支：卡组 5 - 1 = 4（抽2张分支未执行）")
    end

    -- 场景 B：不制造「加入」刻 → 未触发 → not_satisfied → 抽 2 张
    do
        local tid = NewBattle()
        KARDS.Battle:SimSetupDeck("P1", {
            MakeUnit("EMB_B1", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_B2", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_B3", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_B4", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_B5", "P1", { attack = 1, defense = 1 }),
        })
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 6,
        }, { id = "monB", hasSecondOutput = true })
        local draw1 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 1, ["select_3"] = 1,
        }, { id = "draw1B" })
        local draw2 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2, ["select_3"] = 1,
        }, { id = "draw2B" })
        local cmd = MakeBranchCommandCard("cmd_emb_b", { mon, draw1, draw2 }, {
            { fromNode = "monB", toNode = "draw1B", fromPort = "satisfied" },
            { fromNode = "monB", toNode = "draw2B", fromPort = "not_satisfied" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 双输出 未触发分支：P1 打出指令生效")
        -- 手牌 = 指令卡 + 抽 2 张 = 3；卡组 5 - 2 = 3
        AssertEqual(KARDS.Deck:HandSize(tid, "P1"), 3, "event_monitor 双输出 未触发分支：手牌 1 + 抽 2 = 3")
        AssertEqual(KARDS.Deck:DeckSize(tid, "P1"), 3, "event_monitor 双输出 未触发分支：卡组 5 - 2 = 3（抽1张分支未执行）")
    end

    -- 场景 C：未触发且 not_satisfied 端口无连线 → 无下游信号 → 手牌/卡组不变
    do
        local tid = NewBattle()
        KARDS.Battle:SimSetupDeck("P1", {
            MakeUnit("EMB_C1", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_C2", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_C3", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_C4", "P1", { attack = 1, defense = 1 }),
            MakeUnit("EMB_C5", "P1", { attack = 1, defense = 1 }),
        })
        local mon = MakeBaseNode("event_monitor", EVENT_MONITOR_BASE, {
            ["select_1"] = 1, ["select_2"] = 6,
        }, { id = "monC", hasSecondOutput = true })
        local draw1 = MakeBaseNode("card", CARD_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 1, ["select_3"] = 1,
        }, { id = "draw1C" })
        local cmd = MakeBranchCommandCard("cmd_emb_c", { mon, draw1 }, {
            { fromNode = "monC", toNode = "draw1C", fromPort = "satisfied" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "event_monitor 双输出 无连线分支：P1 打出指令生效")
        AssertEqual(KARDS.Deck:HandSize(tid, "P1"), 1, "event_monitor 双输出 无连线分支：not_satisfied 无下游，手牌不变 1")
        AssertEqual(KARDS.Deck:DeckSize(tid, "P1"), 5, "event_monitor 双输出 无连线分支：卡组不变 5")
    end
end

-- ====================================================================
-- extract 提取：阵营/类型/属性筛选的卡牌对象组正确性 + e 类型数据线传递
-- 单位 → 战场（支援阵线+前线，除总部）；指令/反制 → 手牌；属性条件为「=」比较
-- 数据线：extract 输出（e提取的卡牌对象组）经 dataConnections 注入下游 action 目标集
--   覆盖控制流（connections）与顺序（nodes 数组）两种执行模式
-- ====================================================================
local function RunExtractTest()
    -- 1 友方单位·攻击力（含前线收集）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("EX1_U1", "P1", { attack = 3, defense = 5, keywords = { "blitz" } })
        local u2 = MakeUnit("EX1_U2", "P1", { attack = 5, defense = 7 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimMoveToFrontline(u1) -- u1 上前线（blitz 刚入场可行动），验证前线单位也被收集
        KARDS.Battle:SimDeploy(u2, 3)
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 1, ["number_1"] = 3, -- 友方/单位/攻击力=3
        })
        local cmd = MakeCommandCard("cmd_ex1", ex)
        AssertTrue(PlayCommand(cmd), "extract 友方单位·攻击力：P1 打出指令生效")
        local g = ex.data["提取的卡牌对象组"]
        AssertEqual(#g, 1, "extract 友方单位·攻击力：攻击力=3 只提取 u1（u2 攻击 5 被过滤）")
        AssertTrue(GroupContains(g, u1), "extract 友方单位·攻击力：对象组包含 u1（前线单位）")
    end

    -- 2 友方单位·防御力（属性下拉选择）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("EX2_U1", "P1", { attack = 1, defense = 5 })
        local u2 = MakeUnit("EX2_U2", "P1", { attack = 1, defense = 7 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 2, ["number_1"] = 5, -- 友方/单位/防御力=5
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ex2", ex)), "extract 友方单位·防御力：P1 打出指令生效")
        local g = ex.data["提取的卡牌对象组"]
        AssertEqual(#g, 1, "extract 友方单位·防御力：防御力=5 只提取 u1（u2 防御 7 被过滤）")
        AssertTrue(GroupContains(g, u1), "extract 友方单位·防御力：对象组包含 u1")
    end

    -- 3 友方单位·行动花费（属性下拉第 4 项）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("EX3_U1", "P1", { attack = 1, defense = 1, actionCost = 1 })
        local u2 = MakeUnit("EX3_U2", "P1", { attack = 1, defense = 1 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 4, ["number_1"] = 1, -- 友方/单位/行动花费=1
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ex3", ex)), "extract 友方单位·行动花费：P1 打出指令生效")
        local g = ex.data["提取的卡牌对象组"]
        AssertEqual(#g, 1, "extract 友方单位·行动花费：行动花费=1 只提取 u1（u2 行动花费 0 被过滤）")
        AssertTrue(GroupContains(g, u1), "extract 友方单位·行动花费：对象组包含 u1")
    end

    -- 4 敌方单位（阵营筛选）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("EX4_U1", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("EX4_U2", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 2, ["select_2"] = 1, ["select_3"] = 1, ["number_1"] = 3, -- 敌方/单位/攻击力=3
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ex4", ex)), "extract 敌方单位·攻击力：P1 打出指令生效")
        local g = ex.data["提取的卡牌对象组"]
        AssertEqual(#g, 1, "extract 敌方单位·攻击力：敌方只提取 u2（P2 攻击力 3 单位）")
        AssertTrue(GroupContains(g, u2), "extract 敌方单位·攻击力：对象组包含 u2（敌方）")
        AssertTrue(not GroupContains(g, u1), "extract 敌方单位·攻击力：不包含 u1（友方）")
    end

    -- 5 双方单位（双方合并收集）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("EX5_U1", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("EX5_U2", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 3, ["select_2"] = 1, ["select_3"] = 1, ["number_1"] = 3, -- 双方/单位/攻击力=3
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ex5", ex)), "extract 双方单位·攻击力：P1 打出指令生效")
        local g = ex.data["提取的卡牌对象组"]
        AssertEqual(#g, 2, "extract 双方单位·攻击力：双方攻击力 3 单位共 2 张")
        AssertTrue(GroupContains(g, u1) and GroupContains(g, u2), "extract 双方单位·攻击力：对象组同时包含 u1 与 u2")
    end

    -- 6 指令/反制提取（手牌来源 + 卡牌花费筛选）
    do
        local tid = NewBattle()
        local cmd1 = MakeUnit("EX6_C1", "P1", { cost = 2 })
        cmd1 = KARDS.CardInterface.CreateMockCard("EX6_C1", "command", "P1", { cost = 2 })
        local cmd2 = KARDS.CardInterface.CreateMockCard("EX6_C2", "command", "P1", { cost = 3 })
        local cc = KARDS.CardInterface.CreateMockCard("EX6_CC", "counter_command", "P1", { cost = 2 })
        GiveHand(tid, "P1", cmd1)
        GiveHand(tid, "P1", cmd2)
        GiveHand(tid, "P1", cc)
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["number_2"] = 2, -- 友方/指令/卡牌花费=2
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ex6", ex)), "extract 友方指令·花费：P1 打出指令生效")
        local g = ex.data["提取的卡牌对象组"]
        AssertEqual(#g, 1, "extract 友方指令·花费：花费=2 只提取 cmd1（cmd2 花费 3 被过滤）")
        AssertTrue(GroupContains(g, cmd1), "extract 友方指令·花费：对象组包含 cmd1")
        AssertTrue(not GroupContains(g, cc), "extract 友方指令·花费：不包含反制卡 cc（类型筛选）")
        -- 反制提取
        local ex2 = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 1, ["select_2"] = 3, ["number_2"] = 2, -- 友方/反制/卡牌花费=2
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ex6b", ex2)), "extract 友方反制·花费：P1 打出指令生效")
        local g2 = ex2.data["提取的卡牌对象组"]
        AssertEqual(#g2, 1, "extract 友方反制·花费：花费=2 只提取 cc")
        AssertTrue(GroupContains(g2, cc), "extract 友方反制·花费：对象组包含 cc")
    end

    -- 7 e 类型数据线（控制流模式）：extract 输出对象组 → 注入 action「造成伤害」目标集
    do
        local tid = NewBattle()
        local u1 = MakeUnit("EX7_U1", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("EX7_U2", "P1", { attack = 5, defense = 6 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 1, ["number_1"] = 3,
        }, { id = "ex7" })
        local act = MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 14, ["number_2"] = 2, -- 获得/造成伤害/2
        }, { id = "act7" })
        local cmd = MakeBranchCommandCard("cmd_ex7", { ex, act }, {
            { fromNode = "ex7", toNode = "act7", fromPort = "output" },
        }, {
            { id = "dc7", fromNode = "ex7", toNode = "act7", fromPortIndex = 1,
              toPortIndex = 1, dataType = "e", variableName = "提取的卡牌对象组" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "extract 数据线（控制流）：P1 打出指令生效")
        AssertEqual(u1:GetStat("defense"), 3, "extract 数据线（控制流）：u1 被造成 2 伤害，防御 5 → 3")
        AssertEqual(u2:GetStat("defense"), 6, "extract 数据线（控制流）：u2 攻击 5 未在对象组，防御不变 6")
    end

    -- 8 e 类型数据线（顺序模式）：无 connections，按 nodes 数组顺序 extract → action
    do
        local tid = NewBattle()
        local u1 = MakeUnit("EX8_U1", "P1", { attack = 3, defense = 10 })
        KARDS.Battle:SimDeploy(u1, 3)
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 1, ["number_1"] = 3,
        }, { id = "ex8" })
        local act = MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 14, ["number_2"] = 5, -- 获得/造成伤害/5
        }, { id = "act8" })
        local cmd = MakeBranchCommandCard("cmd_ex8", { ex, act }, {}, {
            { id = "dc8", fromNode = "ex8", toNode = "act8", fromPortIndex = 1,
              toPortIndex = 1, dataType = "e", variableName = "提取的卡牌对象组" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "extract 数据线（顺序模式）：P1 打出指令生效")
        AssertEqual(u1:GetStat("defense"), 5, "extract 数据线（顺序模式）：u1 防御 10 → 5")
    end

    -- 9 总部提取：阵营（友方/敌方）× 类型=总部 → 只取该方总部卡（不含单位）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("EX9_U1", "P1", { attack = 3, defense = 10 })
        KARDS.Battle:SimDeploy(u1, 3)
        local exF = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 1, ["select_2"] = 4, -- 友方/总部
        }, { id = "ex9f" })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ex9f", exF)), "extract 友方总部：P1 打出指令生效")
        local gf = exF.data["提取的卡牌对象组"] or {}
        AssertEqual(#gf, 1, "extract 友方总部：对象组只有 1 张（总部）")
        AssertEqual(gf[1], KARDS.Battlefield:GetHQ(tid, "P1"), "extract 友方总部：对象组为 P1 总部卡")
        local exE = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 2, ["select_2"] = 4, -- 敌方/总部
        }, { id = "ex9e" })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ex9e", exE)), "extract 敌方总部：P1 打出指令生效")
        local ge = exE.data["提取的卡牌对象组"] or {}
        AssertEqual(#ge, 1, "extract 敌方总部：对象组只有 1 张（总部）")
        AssertEqual(ge[1], KARDS.Battlefield:GetHQ(tid, "P2"), "extract 敌方总部：对象组为 P2 总部卡")
        AssertTrue(not GroupContains(gf, u1), "extract 友方总部：不包含场上单位 u1")
    end
end

-- headquarter 测试：总部防御力变更
-- 战斗场景：NewBattle 双方总部初始防御 20（HQ_DEFENSE）
-- P1 打出指令触发 headquarter 节点（select_1 阵营 × select_2 操作 × number_1 数值 2）
-- 断言目标玩家总部防御按 增加/减少/设为 正确变更 + stat_change 刻记录（代表性组合）
local function RunHeadquarterTest()
    for side = 1, 3 do -- 阵营：1 友方 / 2 敌方 / 3 双方
        for op = 1, 3 do -- 操作：1 增加 / 2 减少 / 3 设为
            local tid = NewBattle()
            local ci = (side - 1) * 3 + op -- 组合编号 1..9
            local cmd = MakeCommandCard("cmd_hq" .. ci, MakeBaseNode("headquarter", HEADQUARTER_BASE, {
                ["select_1"] = side, ["select_2"] = op, ["number_1"] = 2,
            }))
            GiveHand(tid, "P1", cmd)
            local label = ("headquarter 组合%d(阵营%d 操作%d)"):format(ci, side, op)
            -- 变更前防御（总部始终存在，防御可低于 0 但 20±2 均在正常范围）
            local function defenseOf(p)
                return KARDS.Battlefield:GetHQ(tid, p):GetStat("defense")
            end
            local beforeP1, beforeP2 = defenseOf("P1"), defenseOf("P2")
            AssertTrue(PlayCommand(cmd), label .. "：P1 打出指令生效")
            local function expected(before)
                if op == 2 then return before - 2 end
                if op == 3 then return 2 end
                return before + 2
            end
            if side == 1 or side == 3 then
                AssertEqual(defenseOf("P1"), expected(beforeP1), label .. "：P1 总部防御")
            end
            if side == 2 or side == 3 then
                AssertEqual(defenseOf("P2"), expected(beforeP2), label .. "：P2 总部防御")
            end
            -- 刻记录断言（代表性组合：友方增加 / 敌方增加）
            if ci == 1 then
                AssertTrue(HasTickOp(tid, KARDS.Battlefield:GetHQ(tid, "P1"), "stat_change"),
                    label .. "：记录 stat_change 刻（友方）")
            elseif ci == 4 then
                AssertTrue(HasTickOp(tid, KARDS.Battlefield:GetHQ(tid, "P2"), "stat_change"),
                    label .. "：记录 stat_change 刻（敌方）")
            end
        end
    end
end

-- HQ 摧毁判定测试（readme 7.1：总部防御 ≤0 即被摧毁 → 对局结束，摧毁敌方总部即胜利）：
-- 覆盖单位攻击总部（SimAttack）路径——2026-08-13 修复：此前 SimAttack/SimEngage 结算
-- 后未触发 HQ 摧毁判定（只有 SimFight / SimDealDamage / SimChangeHQDefense /
-- ApplyMoraleHits 有收口），总部防御降到 -1 对局不结束。
local function RunHQDestroyTest()
    -- 1 单毁：炮兵攻击总部至 ≤0 → 对局结束，攻击方胜利
    do
        local tid = NewBattle()
        local atk = MakeUnit("HQKILL_P1", "P1", { unitType = "artillery", attack = 30, defense = 5 })
        KARDS.Battle:SimDeploy(atk, 3)   -- P1 炮兵部署支援阵线（炮兵不受攻击距离限制）
        KARDS.Battle:SimBeginTurn("P1")  -- 推进回合使已部署单位可行动
        local hq2 = KARDS.Battlefield:GetHQ(tid, "P2")
        AssertEqual(KARDS.Battle:SimAttack(atk, hq2), true, "HQ 摧毁判定：P1 炮兵攻击 P2 总部（30 攻）")
        AssertEqual(hq2:GetStat("defense"), -10, "HQ 摧毁判定：攻击后 P2 总部防御 ≤0（20 - 30）")
        local go = KARDS.Battlefield:GetGameOver(tid)
        AssertEqual(go and go.winner, "P1", "HQ 摧毁判定：胜利方 = 攻击方 P1")
        AssertEqual(go and go.loser, "P2", "HQ 摧毁判定：失败方 = 总部被摧毁方 P2")
    end
    -- 2 双毁：双方总部先后被摧毁 → 最早被摧毁方失败（readme 7.1 注；对局停止后第二次
    -- 判定被幂等短路，胜负不翻转）
    do
        local tid = NewBattle()
        local atk1 = MakeUnit("HQKILL2_P1", "P1", { unitType = "artillery", attack = 30, defense = 5 })
        local atk2 = MakeUnit("HQKILL2_P2", "P2", { unitType = "artillery", attack = 30, defense = 5 })
        KARDS.Battle:SimDeploy(atk1, 3)
        KARDS.Battle:SimDeploy(atk2, 3)
        KARDS.Battle:SimBeginTurn("P1")
        AssertEqual(KARDS.Battle:SimAttack(atk1, KARDS.Battlefield:GetHQ(tid, "P2")), true,
            "双毁：P1 炮兵首毁 P2 总部")
        local go = KARDS.Battlefield:GetGameOver(tid)
        AssertEqual(go and go.winner, "P1", "双毁：首毁 P2 → P1 胜利")
        AssertEqual(go and go.loser, "P2", "双毁：首毁 P2 → P2 失败")
        KARDS.Battle:SimBeginTurn("P2")
        AssertEqual(KARDS.Battle:SimAttack(atk2, KARDS.Battlefield:GetHQ(tid, "P1")), true,
            "双毁：P2 炮兵再毁 P1 总部（对局已停止，伤害仍结算）")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), -10,
            "双毁：P1 总部也被摧毁（20 - 30）")
        local go2 = KARDS.Battlefield:GetGameOver(tid)
        AssertEqual(go2 and go2.winner, "P1", "双毁：最早被摧毁方（P2）失败，胜负不翻转")
        AssertEqual(go2 and go2.loser, "P2", "双毁：P2 保持失败")
    end
end

-- loop 测试：循环双输出节点（hasSecondOutput）
-- 编辑器使用方式：第一输出点（satisfied）→ 循环体节点；第二输出点（not_satisfied）→ 循环结束后的节点
-- 执行语义：循环计数 > 0（未结束）→ 计数 -1，信号走第一输出点（继续循环）；= 0（已结束）→ 走第二输出点
-- 场景：loop(count=N) →[satisfied] 循环体 headquarter(友方+1) →[output] 回 loop（成环）
--       loop(count=0) →[not_satisfied] 结束节点 headquarter(友方+10)
-- 断言：总部防御 = 20 + N×1(循环体) + 10(结束节点)；循环计数最终为 0
local function RunLoopTest()
    local cases = { { 3, 33 }, { 1, 31 }, { 0, 30 } } -- { 循环次数 N, 期望总部防御 }
    for _, c in ipairs(cases) do
        local n, expectHQ = c[1], c[2]
        local tid = NewBattle()
        local loop = MakeBaseNode("loop", LOOP_BASE, { ["number_1"] = n },
            { id = "loopN", hasSecondOutput = true })
        local hqBody = MakeBaseNode("headquarter", HEADQUARTER_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 1, -- 友方/增加/1（循环体）
        }, { id = "loop_hqBody" })
        local hqEnd = MakeBaseNode("headquarter", HEADQUARTER_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 10, -- 友方/增加/10（结束节点）
        }, { id = "loop_hqEnd" })
        local cmd = MakeBranchCommandCard("cmd_loop" .. n, { loop, hqBody, hqEnd }, {
            { fromNode = "loopN", toNode = "loop_hqBody", fromPort = "satisfied" },
            { fromNode = "loop_hqBody", toNode = "loopN", fromPort = "output" },
            { fromNode = "loopN", toNode = "loop_hqEnd", fromPort = "not_satisfied" },
        })
        GiveHand(tid, "P1", cmd)
        local label = ("loop 循环%d次"):format(n)
        AssertTrue(PlayCommand(cmd), label .. "：P1 打出指令生效")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), expectHQ,
            label .. ("：总部防御 20 + %d×1(循环体) + 10(结束节点) = %d"):format(n, expectHQ))
        AssertEqual(loop.data["number_1"], 0, label .. "：循环计数最终为 0")
    end
end

-- ====================================================================
-- property 测试：随机排列（特殊执行操作）
-- ====================================================================
-- 模板 base "{1}{3}"：select_1 固定「随机排列所有」；select_2 = 单位1/友方单位2/敌方单位3
-- 语义：在目标方控制的阵线范围（支援阵线 + 控制的前线）随机重排所有单位（总部不参与）；
--       未控制前线（前线空 / 被对方控制）时仅在支援阵线内随机排列
-- 随机性不可精确断言 → 聚焦确定性断言：单位守恒、总部不动（仍在支援阵线）、
--       阵线归属规则（控制前线与否）、单位不越界（始终在目标方控制的阵线范围内）

-- 统计玩家控制的阵线范围中单位数（支援排除总部 + 前线若该方控制）
local function CountFieldUnits(tid, p)
    local n = 0
    local support = KARDS.Battlefield:GetSupport(tid, p)
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        local u = support[i]
        if u and u:GetType() == "unit" then n = n + 1 end
    end
    if KARDS.Battlefield:GetFrontlineOwner(tid) == p then
        local fl = KARDS.Battlefield:GetFrontline(tid)
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            if fl[i] then n = n + 1 end
        end
    end
    return n
end

-- 单位是否在指定玩家支援阵线（引用匹配）
local function InSupport(tid, p, card)
    local support = KARDS.Battlefield:GetSupport(tid, p)
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        if support[i] == card then return true end
    end
    return false
end

-- 总部是否仍在指定玩家支援阵线
local function HQInSupport(tid, p)
    local support = KARDS.Battlefield:GetSupport(tid, p)
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        if support[i] and support[i]:GetType() == "headquarter" then return true end
    end
    return false
end

local function RunPropertyTest()
    -- 1 友方单位 + P1 控制前线（支援 2 + 前线 2 → 排列后单位仍守恒、总部不动、不越界）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("PR1_U1", "P1", { attack = 2, defense = 2, keywords = { "blitz" } })
        local u2 = MakeUnit("PR1_U2", "P1", { attack = 3, defense = 3, keywords = { "blitz" } })
        local u3 = MakeUnit("PR1_U3", "P1", { attack = 4, defense = 4, keywords = { "blitz" } })
        local u4 = MakeUnit("PR1_U4", "P1", { attack = 5, defense = 5, keywords = { "blitz" } })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        KARDS.Battle:SimDeploy(u3, 3)
        KARDS.Battle:SimDeploy(u4, 3)
        KARDS.Battle:SimMoveToFrontline(u1) -- u1/u2 上前线 → P1 控制前线（blitz 刚入场可行动）
        KARDS.Battle:SimMoveToFrontline(u2)
        AssertEqual(KARDS.Battlefield:GetFrontlineOwner(tid), "P1", "property 场景1：前置 P1 控制前线")
        local pr = MakeBaseNode("property", PROPERTY_BASE, { ["select_1"] = 1, ["select_2"] = 2 }) -- 友方单位
        local cmd = MakeCommandCard("cmd_pr1", pr)
        AssertTrue(PlayCommand(cmd), "property 场景1：P1 打出指令生效")
        AssertEqual(CountFieldUnits(tid, "P1"), 4, "property 场景1：P1 单位总数守恒 = 4")
        AssertTrue(HQInSupport(tid, "P1"), "property 场景1：总部仍在 P1 支援阵线（不参与随机排列）")
        -- 4 个单位引用全部在场，且都在 P1 控制的阵线范围内（支援 或 P1 前线）
        for _, u in ipairs({ u1, u2, u3, u4 }) do
            local zone, owner = KARDS.Battlefield:FindCardZone(tid, u)
            AssertTrue(zone ~= nil, "property 场景1：单位 " .. u:GetID() .. " 仍在场")
            AssertEqual(owner, "P1", "property 场景1：单位 " .. u:GetID() .. " 仍在 P1 控制的阵线")
        end
    end

    -- 2 友方单位 + 前线空（未控制前线）→ 仅在支援阵线随机排列
    do
        local tid = NewBattle()
        local u1 = MakeUnit("PR2_U1", "P1", { attack = 2, defense = 2 })
        local u2 = MakeUnit("PR2_U2", "P1", { attack = 3, defense = 3 })
        local u3 = MakeUnit("PR2_U3", "P1", { attack = 4, defense = 4 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        KARDS.Battle:SimDeploy(u3, 3)
        local pr = MakeBaseNode("property", PROPERTY_BASE, { ["select_1"] = 1, ["select_2"] = 2 }) -- 友方单位
        local cmd = MakeCommandCard("cmd_pr2", pr)
        AssertTrue(PlayCommand(cmd), "property 场景2：P1 打出指令生效")
        AssertEqual(CountFieldUnits(tid, "P1"), 3, "property 场景2：P1 单位总数守恒 = 3")
        AssertTrue(HQInSupport(tid, "P1"), "property 场景2：总部仍在 P1 支援阵线")
        AssertEqual(KARDS.Battlefield:GetFrontlineOwner(tid), nil, "property 场景2：前线仍空（未控制前线）")
        -- 3 个单位全在 P1 支援阵线（未控制前线 → 仅在支援阵线排列）
        for _, u in ipairs({ u1, u2, u3 }) do
            AssertTrue(InSupport(tid, "P1", u), "property 场景2：单位 " .. u:GetID() .. " 仍在 P1 支援阵线")
        end
    end

    -- 3 敌方单位（只排列 P2）：P1 单位不动
    do
        local tid = NewBattle()
        local u1 = MakeUnit("PR3_U1", "P1", { attack = 2, defense = 2 })
        local v1 = MakeUnit("PR3_V1", "P2", { attack = 3, defense = 3 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(v1, 3)
        local pr = MakeBaseNode("property", PROPERTY_BASE, { ["select_1"] = 1, ["select_2"] = 3 }) -- 敌方单位
        local cmd = MakeCommandCard("cmd_pr3", pr)
        AssertTrue(PlayCommand(cmd), "property 场景3：P1 打出指令生效")
        local z1, o1 = KARDS.Battlefield:FindCardZone(tid, u1)
        AssertEqual(z1, "support", "property 场景3：P1 单位 u1 仍在支援阵线（敌方排列不动友方）")
        AssertEqual(o1, "P1", "property 场景3：u1 归属 P1 不变")
        local z2, o2 = KARDS.Battlefield:FindCardZone(tid, v1)
        AssertEqual(z2, "support", "property 场景3：P2 单位 v1 仍在 P2 支援阵线")
        AssertEqual(o2, "P2", "property 场景3：v1 归属 P2 不变")
        AssertEqual(CountFieldUnits(tid, "P1"), 1, "property 场景3：P1 单位数不变 = 1")
    end

    -- 4 双方单位（select_2=1 单位 = 双方）+ P1 控制前线
    do
        local tid = NewBattle()
        local u1 = MakeUnit("PR4_U1", "P1", { attack = 2, defense = 2, keywords = { "blitz" } })
        local u2 = MakeUnit("PR4_U2", "P1", { attack = 3, defense = 3, keywords = { "blitz" } })
        local v1 = MakeUnit("PR4_V1", "P2", { attack = 4, defense = 4 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        KARDS.Battle:SimMoveToFrontline(u2) -- u2 上前线 → P1 控制前线（blitz 刚入场可行动）
        KARDS.Battle:SimDeploy(v1, 3)
        AssertEqual(KARDS.Battlefield:GetFrontlineOwner(tid), "P1", "property 场景4：前置 P1 控制前线")
        local pr = MakeBaseNode("property", PROPERTY_BASE, { ["select_1"] = 1, ["select_2"] = 1 }) -- 单位（双方）
        local cmd = MakeCommandCard("cmd_pr4", pr)
        AssertTrue(PlayCommand(cmd), "property 场景4：P1 打出指令生效")
        AssertEqual(CountFieldUnits(tid, "P1"), 2, "property 场景4：P1 单位总数守恒 = 2")
        AssertEqual(CountFieldUnits(tid, "P2"), 1, "property 场景4：P2 单位总数守恒 = 1")
        AssertTrue(HQInSupport(tid, "P1"), "property 场景4：P1 总部仍在支援阵线")
        AssertTrue(HQInSupport(tid, "P2"), "property 场景4：P2 总部仍在支援阵线")
        -- P2 不控制前线：v1 必在 P2 支援（前线即便非空也只会是 P1 单位）
        local z, o = KARDS.Battlefield:FindCardZone(tid, v1)
        AssertEqual(z, "support", "property 场景4：P2 单位 v1 仍在 P2 支援阵线")
        AssertEqual(o, "P2", "property 场景4：v1 归属 P2 不变")
        -- 前线单位（若有）全部属于 P1
        local fl = KARDS.Battlefield:GetFrontline(tid)
        local flAllP1 = true
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            if fl[i] and fl[i]:GetOwner() ~= "P1" then flAllP1 = false end
        end
        AssertTrue(flAllP1, "property 场景4：前线单位（若有）全部属于 P1（P2 未控制前线）")
    end

    -- 5 战斗：select_1=2（战斗），对象槽 1 与对象槽 2 的单位互相战斗（SimFight 互扣对方攻击力防御）
    do
        local tid = NewBattle()
        local a = MakeUnit("PR5_A", "P1", { attack = 3, defense = 6 })
        local b = MakeUnit("PR5_B", "P2", { attack = 2, defense = 5 })
        KARDS.Battle:SimDeploy(a, 3)
        KARDS.Battle:SimDeploy(b, 3)
        local pr = MakeBaseNode("property", PROPERTY_BASE, {
            ["select_1"] = 2, ["select_3"] = a, ["select_4"] = b, -- 战斗/对象1=A/对象2=B
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_pr5", pr)), "property 场景5：P1 打出指令触发战斗生效")
        AssertEqual(a:GetStat("defense"), 4, "property 场景5：A 受 B 攻击 2，防御 6 → 4")
        AssertEqual(b:GetStat("defense"), 2, "property 场景5：B 受 A 攻击 3，防御 5 → 2")
    end

    -- 6 战斗 + e 数据线：target_selector（所有/敌方/单位）输出敌方对象组 → 注入 property「战斗」攻击者，
    -- 防御者 = select_4 对象槽单位（对齐 action 数据线惯例：e 输入 = 发起方；无注入回退 select_3 对象槽）
    do
        local tid = NewBattle()
        local a = MakeUnit("PR6_A", "P1", { attack = 3, defense = 6 })
        local b = MakeUnit("PR6_B", "P2", { attack = 2, defense = 5 })
        KARDS.Battle:SimDeploy(a, 3)
        KARDS.Battle:SimDeploy(b, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 3, ["select_3"] = 2, ["select_4"] = 1, -- 所有/敌方/单位
        }, { id = "pr6_ts" })
        local pr = MakeBaseNode("property", PROPERTY_BASE, {
            ["select_1"] = 2, ["select_4"] = a, -- 战斗/防御者对象槽 = A
        }, { id = "pr6_pr" })
        local cmd = MakeBranchCommandCard("cmd_pr6", { ts, pr }, {
            { fromNode = "pr6_ts", toNode = "pr6_pr", fromPort = "output" },
        }, {
            { id = "pr6_dc", fromNode = "pr6_ts", toNode = "pr6_pr", fromPortIndex = 1,
              toPortIndex = 1, dataType = "e", variableName = "选中的卡牌" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "property 场景6：P1 打出指令触发 e 数据线战斗生效")
        -- e 输入敌方 b 作为攻击者（攻击 2）→ A 防御 6 → 4；对象槽 A 攻击 3 → b 防御 5 → 2
        AssertEqual(a:GetStat("defense"), 4, "property 场景6：对象槽 A 受 e 输入 b 攻击 2，防御 6 → 4")
        AssertEqual(b:GetStat("defense"), 2, "property 场景6：e 输入 b 受对象槽 A 攻击 3，防御 5 → 2")
    end
end

-- ====================================================================
-- register_hook 测试：注册钩子（引擎钩子系统 Engine Hook System）
-- ====================================================================
-- 模板 base "{3}{3}{3}[0]{2}(p钩子ID)"：
--   select_1 作用目标（敌方1/友方2/所有3）| select_2 修饰对象（造成的伤害1/攻击力2/防御力3）
--   select_3 修饰方式（增加1/减少2/设为3）| number_1 数值 | select_4 作用域（存活在场1/永久2）
--   → OnModifyDamage / OnModifyStat 钩子点；输出 p钩子ID
-- 语义：「持续修饰」——注册后影响后续伤害结算 / 属性读取（对齐 templates.md 海鹰：敌方伤害 -1）
local function RunRegisterHookTest()
    -- 1 敌方造成的伤害 -1（永久）：只修饰敌方来源，友方不受影响；输出钩子ID
    do
        local tid = NewBattle()
        local u1 = MakeUnit("RH1_U1", "P1", { attack = 3, defense = 5 })
        local v1 = MakeUnit("RH1_V1", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(v1, 3)
        local rh = MakeBaseNode("register_hook", REGISTER_HOOK_BASE, {
            ["select_1"] = 2, ["select_2"] = 1, ["select_3"] = 1, ["select_4"] = 2, ["number_1"] = 1, ["select_5"] = 2, -- 一般属性修饰/敌方/伤害/减少/1/永久
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_rh1", rh)), "register_hook 场景1：P1 打出指令生效")
        KARDS.Battle:SimDealDamage(v1, KARDS.Battlefield:GetHQ(tid, "P1"), 3) -- 敌方伤害 3 → -1 → 2
        KARDS.Battle:SimDealDamage(u1, KARDS.Battlefield:GetHQ(tid, "P2"), 3) -- 友方伤害不修饰 → 3
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 18,
            "register_hook 场景1：敌方伤害 -1（20 → 18）")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P2"):GetStat("defense"), 17,
            "register_hook 场景1：友方伤害不受修饰（20 → 17）")
        AssertTrue(rh.data["钩子ID"] ~= nil, "register_hook 场景1：输出钩子ID 非空")
    end

    -- 2 敌方造成的伤害 +2（永久，修饰方式=增加）
    do
        local tid = NewBattle()
        local v1 = MakeUnit("RH2_V1", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(v1, 3)
        local rh = MakeBaseNode("register_hook", REGISTER_HOOK_BASE, {
            ["select_1"] = 2, ["select_2"] = 1, ["select_3"] = 1, ["select_4"] = 1, ["number_1"] = 2, ["select_5"] = 2, -- 一般属性修饰/敌方/伤害/增加/2/永久
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_rh2", rh)), "register_hook 场景2：P1 打出指令生效")
        KARDS.Battle:SimDealDamage(v1, KARDS.Battlefield:GetHQ(tid, "P1"), 3) -- 3 + 2 = 5
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 15,
            "register_hook 场景2：敌方伤害 +2（20 → 15）")
    end

    -- 3 敌方造成的伤害设为 1（永久，修饰方式=设为）
    do
        local tid = NewBattle()
        local v1 = MakeUnit("RH3_V1", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(v1, 3)
        local rh = MakeBaseNode("register_hook", REGISTER_HOOK_BASE, {
            ["select_1"] = 2, ["select_2"] = 1, ["select_3"] = 1, ["select_4"] = 3, ["number_1"] = 1, ["select_5"] = 2, -- 一般属性修饰/敌方/伤害/设为/1/永久
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_rh3", rh)), "register_hook 场景3：P1 打出指令生效")
        KARDS.Battle:SimDealDamage(v1, KARDS.Battlefield:GetHQ(tid, "P1"), 3) -- 设为 1
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 19,
            "register_hook 场景3：敌方伤害设为 1（20 → 19）")
    end

    -- 4 敌方攻击力 -1（永久，OnModifyStat 属性修饰）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("RH4_U1", "P1", { attack = 3, defense = 5 })
        local v1 = MakeUnit("RH4_V1", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(v1, 3)
        local rh = MakeBaseNode("register_hook", REGISTER_HOOK_BASE, {
            ["select_1"] = 2, ["select_2"] = 1, ["select_3"] = 2, ["select_4"] = 2, ["number_1"] = 1, ["select_5"] = 2, -- 一般属性修饰/敌方/攻击力/减少/1/永久
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_rh4", rh)), "register_hook 场景4：P1 打出指令生效")
        AssertEqual(v1:GetStat("attack"), 2, "register_hook 场景4：敌方单位攻击力 -1（3 → 2）")
        AssertEqual(u1:GetStat("attack"), 3, "register_hook 场景4：友方单位攻击力不受修饰（3）")
    end

    -- 5 存活在场（节点层）：指令卡注册后自身不在场 → 修饰不生效（绑定实体离场即失效）
    do
        local tid = NewBattle()
        local v1 = MakeUnit("RH5_V1", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(v1, 3)
        local rh = MakeBaseNode("register_hook", REGISTER_HOOK_BASE, {
            ["select_1"] = 2, ["select_2"] = 1, ["select_3"] = 1, ["select_4"] = 2, ["number_1"] = 1, ["select_5"] = 1, -- 一般属性修饰/敌方/伤害/减少/1/存活在场
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_rh5", rh)), "register_hook 场景5：P1 打出指令生效")
        KARDS.Battle:SimDealDamage(v1, KARDS.Battlefield:GetHQ(tid, "P1"), 3) -- 绑定卡（指令卡）不在场 → 不修饰
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 17,
            "register_hook 场景5：存活在场（绑定指令卡不在场）修饰不生效（20 → 17）")
    end

    -- 6 存活在场（引擎层）：绑定在场单位时修饰生效，单位离场后失效
    do
        local tid = NewBattle()
        local v1 = MakeUnit("RH6_V1", "P2", { attack = 3, defense = 5 })
        local u1 = MakeUnit("RH6_U1", "P1", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(v1, 3)
        KARDS.Battle:SimDeploy(u1, 3)
        -- 直接注册引擎钩子（模拟单位在场注册「存活在场」修饰，与节点执行器同一模式）
        KARDS.EngineHooks.Register("nbt", KARDS.EngineHooks.HookPoints.OnModifyDamage, "rh6_hook", function(args)
            if KARDS.Battlefield:FindCardZone("nbt", u1) == nil then return args end -- 绑定单位离场 → 失效
            if args.attacker and args.attacker:GetOwner() == "P2" then
                args.damage = math.max(0, (tonumber(args.damage) or 0) - 1)
            end
            return args
        end, KARDS.EngineHooks.TYPE_MODIFY, u1)
        KARDS.Battle:SimDealDamage(v1, KARDS.Battlefield:GetHQ(tid, "P1"), 3) -- u1 在场 → -1 → 2
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 18,
            "register_hook 场景6：绑定单位在场时敌方伤害 -1（20 → 18）")
        KARDS.Battle:SimRemoveFromField(u1) -- 单位离场
        KARDS.Battle:SimDealDamage(v1, KARDS.Battlefield:GetHQ(tid, "P1"), 3) -- 离场 → 修饰失效 → 3
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 15,
            "register_hook 场景6：绑定单位离场后修饰失效（18 → 15）")
    end

    -- 7 敌方防御力 -1（永久，OnModifyStat 属性修饰）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("RH7_U1", "P1", { attack = 3, defense = 5 })
        local v1 = MakeUnit("RH7_V1", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(v1, 3)
        local rh = MakeBaseNode("register_hook", REGISTER_HOOK_BASE, {
            ["select_1"] = 2, ["select_2"] = 1, ["select_3"] = 3, ["select_4"] = 2, ["number_1"] = 1, ["select_5"] = 2, -- 一般属性修饰/敌方/防御力/减少/1/永久
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_rh7", rh)), "register_hook 场景7：P1 打出指令生效")
        AssertEqual(v1:GetStat("defense"), 4, "register_hook 场景7：敌方单位防御力 -1（5 → 4）")
        AssertEqual(u1:GetStat("defense"), 5, "register_hook 场景7：友方单位防御力不受修饰（5）")
    end

    -- 8 通用效果·总是触发：注册后立即调用函数（函数内 headquarter 给友方总部 +2）
    do
        local tid = NewBattle()
        local fnNode = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2 }) -- 友方/增加/2
        local rh = MakeBaseNode("register_hook", REGISTER_HOOK_BASE, {
            ["select_1"] = 1, ["select_6"] = 1, ["funcslot_1"] = "通用函数", -- 通用效果/总是触发/函数
        })
        local cmd = MakeCommandCard("cmd_rh8", rh)
        -- 全局函数变量（variables["f"]，name 匹配 funcslot 槽值；functionData 为函数子图）
        cmd.effect.variables = { f = { { name = "通用函数", internalName = "KARDS.User.通用函数",
            functionData = { nodes = { fnNode }, connections = {}, dataConnections = {} } } } }
        AssertTrue(PlayCommand(cmd), "register_hook 场景8：P1 打出指令生效")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 22,
            "register_hook 场景8：总是触发注册本次打出即调用函数（HQ 20 → 22）")
    end

    -- 9 通用效果·条件触发：敌方回合开始时调用函数（友方回合开始不触发）
    do
        local tid = NewBattle()
        -- 函数内 headquarter 修饰「敌方」（以事件发起者为准：P2 总部的敌方 = P1）
        local fnNode = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 2, ["select_2"] = 1, ["number_1"] = 2 }) -- 敌方/增加/2
        local rh = MakeBaseNode("register_hook", REGISTER_HOOK_BASE, {
            ["select_1"] = 1, ["select_6"] = 2, ["select_7"] = 1, ["select_8"] = 1, ["funcslot_1"] = "回合函数", -- 通用效果/条件触发/敌方/回合开始/函数
        })
        local cmd = MakeCommandCard("cmd_rh9", rh)
        cmd.effect.variables = { f = { { name = "回合函数", internalName = "KARDS.User.回合函数",
            functionData = { nodes = { fnNode }, connections = {}, dataConnections = {} } } } }
        AssertTrue(PlayCommand(cmd), "register_hook 场景9：P1 打出指令生效")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 20,
            "register_hook 场景9：注册后未触发（HQ 20）")
        KARDS.Battle:SimBeginTurn("P2") -- 敌方回合开始 → 触发（side=1 敌方：发起者 P2 ≠ 注册者 P1）
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 22,
            "register_hook 场景9：敌方回合开始调用函数（20 → 22）")
        KARDS.Battle:SimBeginTurn("P1") -- 友方回合开始 → 不触发（发起者 P1 == 注册者 P1）
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 22,
            "register_hook 场景9：友方回合开始不触发（22）")
    end

    -- 10 函数调用同步：调用者节点等待函数内全部节点效果完成后，再继续传递信号
    --    （函数内 headquarter +2、+3 全部生效，随后连线上的后续节点 headquarter +1 再执行 → 20+2+3+1=26）
    do
        local tid = NewBattle()
        local fn1 = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2 }) -- 友方+2
        local fn2 = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 3 }) -- 友方+3
        local rh = MakeBaseNode("register_hook", REGISTER_HOOK_BASE, {
            ["select_1"] = 1, ["select_6"] = 1, ["funcslot_1"] = "同步函数", -- 通用效果/总是触发/函数
        }, { id = 1 })
        local after = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 1 }, { id = 2 })
        local cmd = MakeBranchCommandCard("cmd_rh10", { rh, after }, { { fromNode = 1, toNode = 2, fromPort = "output" } })
        cmd.effect.variables = { f = { { name = "同步函数", internalName = "KARDS.User.同步函数",
            functionData = { nodes = { fn1, fn2 }, connections = {}, dataConnections = {} } } } }
        AssertTrue(PlayCommand(cmd), "register_hook 场景10：P1 打出指令生效")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 26,
            "register_hook 场景10：函数内全部执行 + 调用者继续传递信号（20+2+3+1=26）")
    end
end

-- target_selector 测试：目标选择器（选择方式 × 阵营范围 × 卡牌类别 × 单位类型）
-- 战斗场景：NewBattle + 双方部署单位；P1 打出指令触发 target_selector 节点
-- 输出 e选中的卡牌 对象组（node.data["选中的卡牌"]），供下游 action 经数据线消费
local function RunTargetSelectorTest()
    -- 1 所有 + 友方 + 单位：收集友方战场全部单位
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS1_U1", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("TS1_U2", "P1", { attack = 5, defense = 7 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 3, ["select_3"] = 1, ["select_4"] = 1, -- 所有/友方/单位
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts1", ts)), "target_selector 所有·友方·单位：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 2, "target_selector 所有·友方·单位：友方战场全部 2 单位")
        AssertTrue(GroupContains(g, u1), "target_selector 所有·友方·单位：包含 u1")
        AssertTrue(GroupContains(g, u2), "target_selector 所有·友方·单位：包含 u2")
    end

    -- 2 所有 + 敌方 + 单位：只收集敌方单位
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS2_U1", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("TS2_U2", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 3, ["select_3"] = 2, ["select_4"] = 1, -- 所有/敌方/单位
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts2", ts)), "target_selector 所有·敌方·单位：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 1, "target_selector 所有·敌方·单位：敌方战场 1 单位")
        AssertTrue(GroupContains(g, u2), "target_selector 所有·敌方·单位：包含敌方 u2")
        AssertTrue(not GroupContains(g, u1), "target_selector 所有·敌方·单位：不含友方 u1")
    end

    -- 3 所有 + 场上 + 单位：双方战场单位合并
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS3_U1", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("TS3_U2", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 3, ["select_3"] = 3, ["select_4"] = 1, -- 所有/场上/单位
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts3", ts)), "target_selector 所有·场上·单位：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 2, "target_selector 所有·场上·单位：双方战场共 2 单位")
        AssertTrue(GroupContains(g, u1) and GroupContains(g, u2), "target_selector 所有·场上·单位：同时包含双方单位")
    end

    -- 4 所有 + 友方 + 总部：选择友方总部
    do
        local tid = NewBattle()
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 3, ["select_3"] = 1, ["select_4"] = 3, -- 所有/友方/总部
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts4", ts)), "target_selector 所有·友方·总部：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 1, "target_selector 所有·友方·总部：输出 1 张总部")
        AssertEqual(g[1]:GetType(), "headquarter", "target_selector 所有·友方·总部：选中对象是总部")
        AssertEqual(g[1]:GetOwner(), "P1", "target_selector 所有·友方·总部：总部归属 P1（友方）")
    end

    -- 5 随机 + 友方 + 单位 + 数量 2：随机取 2 个（不重复、均来自候选）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS5_U1", "P1", { attack = 1, defense = 1 })
        local u2 = MakeUnit("TS5_U2", "P1", { attack = 2, defense = 2 })
        local u3 = MakeUnit("TS5_U3", "P1", { attack = 3, defense = 3 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        KARDS.Battle:SimDeploy(u3, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 2, ["select_3"] = 1, ["select_4"] = 1, ["number_2"] = 2, -- 随机/友方/单位/2
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts5", ts)), "target_selector 随机·友方·单位：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 2, "target_selector 随机·友方·单位：随机取 2 个单位")
        AssertTrue(GroupContains(g, u1) or GroupContains(g, u2) or GroupContains(g, u3), "target_selector 随机·友方·单位：选自友方候选")
        AssertTrue(g[1] ~= g[2], "target_selector 随机·友方·单位：随机结果不重复")
    end

    -- 6 属性最高 + 友方 + 单位 + 攻击力 + 名次 1：取攻击力最高的友方单位
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS6_U1", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("TS6_U2", "P1", { attack = 5, defense = 7 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 4, ["select_2"] = 1, ["number_1"] = 1, ["select_3"] = 1, ["select_4"] = 1, -- 属性最高/攻击力/第1名/友方/单位
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts6", ts)), "target_selector 属性最高·攻击力：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 1, "target_selector 属性最高·攻击力：输出 1 个单位")
        AssertEqual(g[1], u2, "target_selector 属性最高·攻击力：攻击 5 的 u2 被选中（u1 攻击 3）")
    end

    -- 7 属性最低 + 敌方 + 单位 + 防御力 + 名次 1：取防御力最低的敌方单位
    do
        local tid = NewBattle()
        local v1 = MakeUnit("TS7_V1", "P2", { attack = 3, defense = 6 })
        local v2 = MakeUnit("TS7_V2", "P2", { attack = 3, defense = 4 })
        KARDS.Battle:SimDeploy(v1, 3)
        KARDS.Battle:SimDeploy(v2, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 5, ["select_2"] = 2, ["number_1"] = 1, ["select_3"] = 2, ["select_4"] = 1, -- 属性最低/防御力/第1名/敌方/单位
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts7", ts)), "target_selector 属性最低·防御力：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 1, "target_selector 属性最低·防御力：输出 1 个单位")
        AssertEqual(g[1], v2, "target_selector 属性最低·防御力：防御 4 的 v2 被选中（v1 防御 6）")
    end

    -- 8 指向一个 + 目标：从打出指令时选择的目标中取第 1 个
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS8_U1", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("TS8_U2", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 1, ["select_3"] = 3, ["select_4"] = 2, -- 指向一个/场上/目标
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts8", ts), { u2 }), "target_selector 指向一个·目标：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 1, "target_selector 指向一个·目标：输出 1 个目标")
        AssertEqual(g[1], u2, "target_selector 指向一个·目标：选中打出指令时的目标 u2")
    end

    -- 8b 指向一个 + 单位 + 注入指定目标操作（Specify.Target，targetPicker 选 u2；
    -- 缺省会取收集顺序第一张 u1，未来 UI 由玩家箭头指向、不可指向目标黑白）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS8B_U1", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("TS8B_U2", "P2", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 1, ["select_3"] = 3, ["select_4"] = 1, -- 指向一个/场上/单位
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts8b", ts), nil, { specify = { targetPicker = function(candidates)
            for _, c in ipairs(candidates) do
                if c:GetID() == "TS8B_U2" then return c end
            end
            return candidates[1]
        end } }), "target_selector 指向一个·指定目标：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 1, "target_selector 指向一个·指定目标：输出 1 个目标")
        AssertEqual(g[1], u2, "target_selector 指向一个·指定目标：注入指定选中 u2")
    end

    -- 9 所有 + 友方 + 单位 + 步兵类型：单位类型过滤（select_5 第 6 项）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS9_U1", "P1", { attack = 3, defense = 5, unitType = "infantry" })
        local u2 = MakeUnit("TS9_U2", "P1", { attack = 3, defense = 5, unitType = "tank" })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 3, ["select_3"] = 1, ["select_4"] = 1, ["select_5"] = 6, -- 所有/友方/单位/步兵
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts9", ts)), "target_selector 单位类型·步兵：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 1, "target_selector 单位类型·步兵：只收集步兵 u1")
        AssertEqual(g[1], u1, "target_selector 单位类型·步兵：选中步兵 u1（坦克 u2 被过滤）")
    end

    -- 10 e 类型数据线（控制流模式）：target_selector 输出对象组 → 注入 action「造成伤害」目标集
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS10_U1", "P1", { attack = 3, defense = 10 })
        local u2 = MakeUnit("TS10_U2", "P1", { attack = 3, defense = 8 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 3, ["select_3"] = 1, ["select_4"] = 1, -- 所有/友方/单位
        }, { id = "ts10" })
        local act = MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 14, ["number_2"] = 2, -- 获得/造成伤害/2
        }, { id = "act10" })
        local cmd = MakeBranchCommandCard("cmd_ts10", { ts, act }, {
            { fromNode = "ts10", toNode = "act10", fromPort = "output" },
        }, {
            { id = "dc10", fromNode = "ts10", toNode = "act10", fromPortIndex = 1,
              toPortIndex = 1, dataType = "e", variableName = "选中的卡牌" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "target_selector 数据线（控制流）：P1 打出指令生效")
        AssertEqual(u1:GetStat("defense"), 8, "target_selector 数据线（控制流）：u1 被造成 2 伤害，防御 10 → 8")
        AssertEqual(u2:GetStat("defense"), 6, "target_selector 数据线（控制流）：u2 被造成 2 伤害，防御 8 → 6")
    end

    -- 11 任意：单位类型=任意（select_5=1），不限定类型收集敌方全部单位（不含总部）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("TS11_U1", "P1", { attack = 1, defense = 10 })
        local u2 = MakeUnit("TS11_U2", "P2", { attack = 1, defense = 10 })
        local v3 = MakeUnit("TS11_V3", "P2", { attack = 1, defense = 10 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 3)
        KARDS.Battle:SimDeploy(v3, 3)
        local ts = MakeBaseNode("target_selector", TARGET_SELECTOR_BASE, {
            ["select_1"] = 3, ["select_3"] = 2, ["select_4"] = 1, ["select_5"] = 1, -- 所有/敌方/单位/任意
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_ts11", ts)), "target_selector 单位类型·任意：P1 打出指令生效")
        local g = ts.data["选中的卡牌"]
        AssertEqual(#g, 2, "target_selector 单位类型·任意：敌方单位 2 个候选（总部不属单位类别）")
        AssertTrue(GroupContains(g, u2) and GroupContains(g, v3), "target_selector 单位类型·任意：包含敌方单位 u2、v3")
        local hasHQ = false
        for _, c in ipairs(g) do
            if c:GetType() == "headquarter" then hasHQ = true break end
        end
        AssertEqual(hasHQ, false, "target_selector 单位类型·任意：不含总部")
    end
end

-- trigger_function 测试：触发函数（触发一次 / 保持触发 / 停止保持触发 / 拦截一次 / 保持拦截）
-- 战斗场景：NewBattle + P1 打出指令触发 trigger_function 节点（e 输入传注册目标实体）
-- 保持触发注册到目标实体，实体拥有者回合开始（SimBeginTurn）自动执行；
-- 拦截注册 OnBeforePlayCard 引擎钩子，敌方打出指令时拦截（函数效果执行成功 = 已拦截，骨架约定）
local function RunTriggerFunctionTest()
    -- 1 触发一次：立即同步调用函数（函数内 headquarter 友方+2），输出效果图案类型
    do
        local tid = NewBattle()
        local fnNode = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2 }) -- 友方/增加/2
        local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 1, ["funcslot_1"] = "一次函数", ["select_2"] = 2, -- 触发一次/函数/被动效果
        })
        local cmd = MakeCommandCard("cmd_tf1", tf)
        cmd.effect.variables = { f = { { name = "一次函数", internalName = "KARDS.User.一次函数",
            functionData = { nodes = { fnNode }, connections = {}, dataConnections = {} } } } }
        AssertTrue(PlayCommand(cmd), "trigger_function 场景1：P1 打出指令生效")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 22,
            "trigger_function 场景1：触发一次立即调用函数（HQ 20 → 22）")
        AssertEqual(tf.data["效果图案类型"], "被动效果",
            "trigger_function 场景1：输出效果图案类型（被动效果）")
    end

    -- 2 保持触发：注册到 P1 总部，注册者回合开始自动执行（非注册者回合不执行）
    do
        local tid = NewBattle()
        local fnNode = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2 })
        local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 2, ["funcslot_1"] = "保持函数", ["select_2"] = 2, -- 保持触发/函数/被动效果
        })
        local cmd = MakeCommandCard("cmd_tf2", tf)
        cmd.effect.variables = { f = { { name = "保持函数", internalName = "KARDS.User.保持函数",
            functionData = { nodes = { fnNode }, connections = {}, dataConnections = {} } } } }
        local hq = KARDS.Battlefield:GetHQ(tid, "P1")
        AssertTrue(PlayCommand(cmd, { hq }), "trigger_function 场景2：P1 打出指令生效")
        AssertEqual(hq:GetStat("defense"), 20, "trigger_function 场景2：注册后未触发（20）")
        KARDS.Battle:SimBeginTurn("P1") -- 注册者回合开始 → 执行
        AssertEqual(hq:GetStat("defense"), 22, "trigger_function 场景2：注册者回合开始执行函数（20 → 22）")
        KARDS.Battle:SimBeginTurn("P2") -- 非注册者回合开始 → 不执行
        AssertEqual(hq:GetStat("defense"), 22, "trigger_function 场景2：非注册者回合开始不执行（22）")
        AssertEqual(#tf.data["目标"], 1, "trigger_function 场景2：输出 e目标（注册实体）")
    end

    -- 3 停止保持触发：注册后回合开始执行；打出停止节点（同注册 ID）后不再执行
    do
        local tid = NewBattle()
        local fnNode = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2 })
        local tfReg = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 2, ["funcslot_1"] = "停止函数", ["select_2"] = 2, -- 保持触发/函数/被动效果
        })
        local cmdReg = MakeCommandCard("cmd_tf3_reg", tfReg)
        cmdReg.effect.variables = { f = { { name = "停止函数", internalName = "KARDS.User.停止函数",
            functionData = { nodes = { fnNode }, connections = {}, dataConnections = {} } } } }
        local hq = KARDS.Battlefield:GetHQ(tid, "P1")
        AssertTrue(PlayCommand(cmdReg, { hq }), "trigger_function 场景3：P1 打出注册指令生效")
        KARDS.Battle:SimBeginTurn("P1")
        AssertEqual(hq:GetStat("defense"), 22, "trigger_function 场景3：注册后回合开始执行（20 → 22）")
        -- 停止保持触发节点（与注册节点同 name → 同注册 ID，可匹配移除；停止不调用函数）
        local tfStop = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 3, ["funcslot_1"] = "停止函数", ["select_2"] = 2, -- 停止保持触发
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_tf3_stop", tfStop), { hq }),
            "trigger_function 场景3：P1 打出停止指令生效")
        KARDS.Battle:SimBeginTurn("P1")
        AssertEqual(hq:GetStat("defense"), 22, "trigger_function 场景3：停止后回合开始不再执行（22）")
    end

    -- 4 拦截一次：敌方打出指令被拦截（效果不生效），再次打出不再拦截（钩子已注销）
    do
        local tid = NewBattle()
        -- 拦截函数：空函数子图（CallFunctionData 空函数返回 true → 视为已拦截）
        -- select_2 = 1：拦截「打出指令」这一操作类型（拦截分支的操作类型选择器）
        local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 4, ["funcslot_1"] = "拦截函数", ["select_2"] = 1, -- 拦截一次/函数/打出指令
        })
        local cmdI = MakeCommandCard("cmd_tf4_i", tf)
        cmdI.effect.variables = { f = { { name = "拦截函数", internalName = "KARDS.User.拦截函数",
            functionData = { nodes = {}, connections = {}, dataConnections = {} } } } }
        AssertTrue(PlayCommand(cmdI), "trigger_function 场景4：P1 打出拦截卡生效")
        -- P2 打出带 headquarter 效果的指令（友方 = P2 → P2 总部 +2）
        local function makeV(idd)
            local vNode = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2 })
            local v = KARDS.CardInterface.CreateMockCard(idd, "command", "P2", { cost = 0 })
            v.effect = { nodes = { vNode }, variables = {}, dataConnections = {} }
            return v
        end
        AssertEqual(KARDS.Battle:SimPlayCard("P2", makeV("cmd_tf4_v1"), {}), false,
            "trigger_function 场景4：P2 指令被拦截（SimPlayCard 返回 false）")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P2"):GetStat("defense"), 20,
            "trigger_function 场景4：拦截后指令效果未生效（P2 HQ 20）")
        AssertEqual(KARDS.Battle:SimPlayCard("P2", makeV("cmd_tf4_v2"), {}), true,
            "trigger_function 场景4：拦截一次已注销，再次打出不被拦截（返回 true）")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P2"):GetStat("defense"), 22,
            "trigger_function 场景4：第二次打出生效（P2 HQ 20 → 22）")
    end

    -- 5 保持拦截：敌方打出指令持续被拦截（多次都不生效）
    do
        local tid = NewBattle()
        local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 5, ["funcslot_1"] = "拦函数", ["select_2"] = 3, -- 保持拦截/函数/无
        })
        local cmdI = MakeCommandCard("cmd_tf5_i", tf)
        cmdI.effect.variables = { f = { { name = "拦函数", internalName = "KARDS.User.拦函数",
            functionData = { nodes = {}, connections = {}, dataConnections = {} } } } }
        AssertTrue(PlayCommand(cmdI), "trigger_function 场景5：P1 打出拦截卡生效")
        local function makeV(idd)
            local vNode = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2 })
            local v = KARDS.CardInterface.CreateMockCard(idd, "command", "P2", { cost = 0 })
            v.effect = { nodes = { vNode }, variables = {}, dataConnections = {} }
            return v
        end
        AssertEqual(KARDS.Battle:SimPlayCard("P2", makeV("cmd_tf5_v1"), {}), false,
            "trigger_function 场景5：第一次拦截（SimPlayCard 返回 false）")
        AssertEqual(KARDS.Battle:SimPlayCard("P2", makeV("cmd_tf5_v2"), {}), false,
            "trigger_function 场景5：第二次仍拦截（保持拦截）")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P2"):GetStat("defense"), 20,
            "trigger_function 场景5：两次指令效果均未生效（P2 HQ 20）")
    end

    -- 6 拦截一次 + 属性变更 + 至多：敌方 3 点伤害被压到 1 点，操作不取消；一次性生效后不再改写
    do
        local tid = NewBattle()
        -- select_2 = 13：伤害（INTERCEPT_OPTYPES 第 13 项）；select_6 = 2 属性变更；select_7 = 4 至多
        local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 4, ["select_2"] = 13,
            ["select_6"] = 2, ["select_7"] = 4, ["number_1"] = 1,
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_tf6_i", tf)),
            "trigger_function 场景6：P1 注册属性变更拦截（伤害·至多 1）")
        local target = MakeUnit("u_tf6_t", "P1", { attack = 1, defense = 20 })
        local src = MakeUnit("u_tf6_s", "P2", { attack = 3, defense = 20 })
        KARDS.Battle:SimDeploy(target, 3)
        KARDS.Battle:SimDeploy(src, 3)
        KARDS.Battle:SimDealDamage(src, target, 3)
        AssertEqual(target:GetStat("defense"), 19,
            "trigger_function 场景6：3 点伤害被改写为至多 1（20 → 19）")
        KARDS.Battle:SimDealDamage(src, target, 3)
        AssertEqual(target:GetStat("defense"), 16,
            "trigger_function 场景6：拦截一次已消费，第二次伤害不再改写（19 → 16）")
    end

    -- 7 保持拦截 + 属性变更 + 减少：连续两次伤害都被减 1（钩子不注销）
    do
        local tid = NewBattle()
        local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 5, ["select_3"] = 13,
            ["select_8"] = 2, ["select_9"] = 2, ["number_2"] = 1,
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_tf7_i", tf)),
            "trigger_function 场景7：P1 注册属性变更拦截（伤害·保持·减少 1）")
        local target = MakeUnit("u_tf7_t", "P1", { attack = 1, defense = 20 })
        local src = MakeUnit("u_tf7_s", "P2", { attack = 3, defense = 20 })
        KARDS.Battle:SimDeploy(target, 3)
        KARDS.Battle:SimDeploy(src, 3)
        KARDS.Battle:SimDealDamage(src, target, 3)
        AssertEqual(target:GetStat("defense"), 18,
            "trigger_function 场景7：第一次伤害减 1（20 → 18）")
        KARDS.Battle:SimDealDamage(src, target, 3)
        AssertEqual(target:GetStat("defense"), 16,
            "trigger_function 场景7：第二次伤害仍减 1（18 → 16）")
    end

    -- 8 数值修饰：设为 / 增加 / 至少（直接经统一操作钩子校验改写结果）
    do
        local function rewrote(modIdx, value, current, cardSuffix)
            local tid = NewBattle()
            local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
                ["select_1"] = 5, ["select_3"] = 13,
                ["select_8"] = 2, ["select_9"] = modIdx, ["number_2"] = value,
            })
            PlayCommand(MakeCommandCard("cmd_tf8_" .. cardSuffix, tf))
            local args = KARDS.EngineHooks.TriggerOperation(tid, "deal_damage", { amount = current })
            return args.amount, args.modified
        end
        local amount, modified = rewrote(3, 4, 9, "set")
        AssertEqual(amount, 4, "trigger_function 场景8：设为 4（原 9 → 4）")
        AssertEqual(modified, true, "trigger_function 场景8：设为标记 args.modified")
        amount = rewrote(1, 4, 9, "inc")
        AssertEqual(amount, 13, "trigger_function 场景8：增加 4（原 9 → 13）")
        amount = rewrote(5, 4, 2, "least")
        AssertEqual(amount, 4, "trigger_function 场景8：至少 4（原 2 → 4）")
    end

    -- 9 属性变更接入 stat_change：敌方把友方单位攻击力加 3，被至多 1 改写
    do
        local tid = NewBattle()
        local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 4, ["select_2"] = 14, -- 拦截一次/属性变更
            ["select_6"] = 2, ["select_7"] = 4, ["number_1"] = 1,
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_tf9_i", tf)),
            "trigger_function 场景9：P1 注册属性写入拦截（至多 1）")
        local u = MakeUnit("u_tf9", "P1", { attack = 2, defense = 10 })
        local enemy = KARDS.CardInterface.CreateMockCard("cmd_tf9_src", "command", "P2", { cost = 0 })
        local ok = KARDS.NodeParser.SetFixedVarValue(u, "n", "KARDS.User.攻击", 3,
            { tableID = tid, _srcCard = enemy })
        AssertTrue(ok, "trigger_function 场景9：属性写入未被取消（返回 true）")
        AssertEqual(u:GetStat("attack"), 1,
            "trigger_function 场景9：攻击力写入被改写为至多 1（2 → 1）")
    end

    -- 10 属性变更接入 stat_change：收尾方式为反制时属性写入被取消（旧卡无收尾字段回退反制）
    do
        local tid = NewBattle()
        local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 4, ["funcslot_1"] = "写入拦截函数", ["select_2"] = 14, -- 拦截一次/属性变更/反制
        })
        local cmd = MakeCommandCard("cmd_tf10_i", tf)
        cmd.effect.variables = { f = { { name = "写入拦截函数", internalName = "KARDS.User.写入拦截函数",
            functionData = { nodes = {}, connections = {}, dataConnections = {} } } } }
        AssertTrue(PlayCommand(cmd), "trigger_function 场景10：P1 注册属性写入反制")
        local u = MakeUnit("u_tf10", "P1", { attack = 2, defense = 10 })
        local enemy = KARDS.CardInterface.CreateMockCard("cmd_tf10_src", "command", "P2", { cost = 0 })
        AssertEqual(KARDS.NodeParser.SetFixedVarValue(u, "n", "KARDS.User.攻击", 3,
            { tableID = tid, _srcCard = enemy }), false,
            "trigger_function 场景10：属性写入被反制取消（返回 false）")
        AssertEqual(u:GetStat("attack"), 2, "trigger_function 场景10：攻击力保持原值（2）")
    end
end

-- trigger 测试：属性与伤害（攻击 / 防御（受到伤害） / 伤害 / e 数据线）
-- 战斗场景：NewBattle + P1 打出指令（e 输入传目标卡牌）触发 trigger 节点修改目标属性；
-- 输出 n攻击力、n防御力（修改后属性值）存 node.data[输出端口名]
local function RunTriggerTest()
    -- 1 攻击-设为：u1 攻击 3 → 5，输出 n攻击力=5、n防御力=10（未变）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_trg1", "P1", { attack = 3, defense = 10 })
        KARDS.Battle:SimDeploy(u1, 3)
        local trg = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 1, ["number_1"] = 5, -- 攻击/设为/5
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_trg1", trg), { u1 }), "trigger 场景1：P1 打出指令生效")
        AssertEqual(u1:GetStat("attack"), 5, "trigger 场景1：攻击设为 5（3 → 5）")
        AssertEqual(trg.data["攻击力"], 5, "trigger 场景1：输出 n攻击力（修改后 5）")
        AssertEqual(trg.data["防御力"], 10, "trigger 场景1：输出 n防御力（未变 10）")
    end

    -- 2 攻击-增加/减少：u1 攻击 3 → 增加 2 → 5 → 减少 1 → 4
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_trg2", "P1", { attack = 3, defense = 10 })
        KARDS.Battle:SimDeploy(u1, 3)
        local trgInc = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 2, ["number_1"] = 2, -- 攻击/增加/2
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_trg2a", trgInc), { u1 }), "trigger 场景2：P1 打出增加指令生效")
        AssertEqual(u1:GetStat("attack"), 5, "trigger 场景2：攻击增加 2（3 → 5）")
        local trgDec = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 3, ["number_1"] = 1, -- 攻击/减少/1
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_trg2b", trgDec), { u1 }), "trigger 场景2：P1 打出减少指令生效")
        AssertEqual(u1:GetStat("attack"), 4, "trigger 场景2：攻击减少 1（5 → 4）")
    end

    -- 3 防御-设为/增加/减少：u1 防御 10 → 设为 8 → 增加 2 → 10 → 减少 3 → 7
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_trg3", "P1", { attack = 1, defense = 10 })
        KARDS.Battle:SimDeploy(u1, 3)
        local trgSet = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_4"] = 2, ["number_2"] = 8, -- 防御/设为/8
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_trg3a", trgSet), { u1 }), "trigger 场景3：P1 打出设为指令生效")
        AssertEqual(u1:GetStat("defense"), 8, "trigger 场景3：防御设为 8（10 → 8）")
        local trgInc = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_4"] = 3, ["number_2"] = 2, -- 防御/增加/2
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_trg3b", trgInc), { u1 }), "trigger 场景3：P1 打出增加指令生效")
        AssertEqual(u1:GetStat("defense"), 10, "trigger 场景3：防御增加 2（8 → 10）")
        local trgDec = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_4"] = 4, ["number_2"] = 3, -- 防御/减少/3
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_trg3c", trgDec), { u1 }), "trigger 场景3：P1 打出减少指令生效")
        AssertEqual(u1:GetStat("defense"), 7, "trigger 场景3：防御减少 3（10 → 7）")
    end

    -- 4 防御-受到：u1 受到 3 伤害（伤害结算，防御 10 → 7）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_trg4", "P1", { attack = 1, defense = 10 })
        KARDS.Battle:SimDeploy(u1, 3)
        local trg = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_4"] = 1, ["number_2"] = 3, -- 防御/受到/3
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_trg4", trg), { u1 }), "trigger 场景4：P1 打出受到伤害指令生效")
        AssertEqual(u1:GetStat("defense"), 7, "trigger 场景4：防御受到 3 伤害（10 → 7）")
        AssertEqual(trg.data["防御力"], 7, "trigger 场景4：输出 n防御力（伤害后 7）")
    end

    -- 5 受到伤害：u1 受到 number_3 = 5 点伤害（防御 10 → 5）
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_trg5", "P1", { attack = 3, defense = 10 })
        KARDS.Battle:SimDeploy(u1, 3)
        local trg = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 3, ["number_3"] = 5, -- 受到伤害/5
        })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_trg5", trg), { u1 }), "trigger 场景5：P1 打出受到伤害指令生效")
        AssertEqual(u1:GetStat("defense"), 5, "trigger 场景5：受到 5 伤害（防御 10 → 5）")
        AssertEqual(trg.data["防御力"], 5, "trigger 场景5：输出 n防御力（伤害后 5）")
    end

    -- 6 e 数据线：extract 选出 u1 → 数据线注入 trigger 攻击+2
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_trg6", "P1", { attack = 3, defense = 10 })
        KARDS.Battle:SimDeploy(u1, 3)
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 1, ["number_1"] = 3, -- 友方/单位/攻击力=3
        }, { id = "ex6" })
        local trg = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 2, ["number_1"] = 2, -- 攻击/增加/2
        }, { id = "trg6" })
        local cmd = MakeBranchCommandCard("cmd_trg6", { ex, trg }, {}, {
            { id = "dc_trg6", fromNode = "ex6", toNode = "trg6", fromPortIndex = 1,
              toPortIndex = 1, dataType = "e", variableName = "提取的卡牌对象组" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "trigger 场景6：e 数据线（extract → trigger）P1 打出指令生效")
        AssertEqual(u1:GetStat("attack"), 5, "trigger 场景6：数据线注入目标后攻击增加 2（3 → 5）")
    end

    -- 7 总部受到伤害：extract 提取敌方总部 → 数据线注入 trigger「受到伤害」→ 总部防御 -5（HQ 20 → 15）
    do
        local tid = NewBattle()
        local ex = MakeBaseNode("extract", EXTRACT_BASE, {
            ["select_1"] = 2, ["select_2"] = 4, -- 敌方/总部
        }, { id = "ex7" })
        local trg = MakeBaseNode("trigger", TRIGGER_BASE, {
            ["select_1"] = 1, ["select_2"] = 3, ["number_3"] = 5, -- 受到伤害/5
        }, { id = "trg7" })
        local cmd = MakeBranchCommandCard("cmd_trg7", { ex, trg }, {}, {
            { id = "dc_trg7", fromNode = "ex7", toNode = "trg7", fromPortIndex = 1,
              toPortIndex = 1, dataType = "e", variableName = "提取的卡牌对象组" },
        })
        GiveHand(tid, "P1", cmd)
        AssertTrue(PlayCommand(cmd), "trigger 场景7：extract 敌方总部 → trigger 受到伤害，P1 打出指令生效")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P2"):GetStat("defense"), 15,
            "trigger 场景7：敌方总部受到 5 伤害（20 → 15）")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P1"):GetStat("defense"), 20,
            "trigger 场景7：友方总部不受影响（仍 20）")
    end
end

-- ====================================================================
-- turn 回合节点（跨刻执行）：等待（挂起/时间刻推进/恢复）与 使（立即推进回合）
-- ====================================================================
local function RunTurnTest()
    -- 1 等待-友方-开始-1次：挂起 → 下游不执行 → 友方回合开始时间刻恢复
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_tn1", "P1", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimBeginTurn("P1")
        KARDS.Battle:SimMoveToFrontline(u1)
        local tn = MakeBaseNode("turn", TURN_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 1, ["number_1"] = 1, -- 等待/友方/开始/1次
        }, { id = "tn1" })
        local retreat = MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 1, -- 撤退
        }, { id = "tn1_retreat" })
        local cmd = MakeBranchCommandCard("cmd_tn1", { tn, retreat }, {
            { fromNode = "tn1", toNode = "tn1_retreat", fromPort = "output" },
        })
        AssertTrue(PlayCommand(cmd, { u1 }), "turn 场景1：P1 打出等待指令生效（挂起注册）")
        AssertEqual(ZoneOf(tid, u1), "frontline", "turn 场景1：挂起时信号停滞（下游撤退未执行，u1 仍在前线）")
        AssertEqual(#(KARDS.NodeParser.PendingTurns[tid] or {}), 1, "turn 场景1：挂起注册表登记 1 条")
        KARDS.Battle:SimBeginTurn("P1")
        AssertEqual(ZoneOf(tid, u1), "support", "turn 场景1：友方回合开始 → 恢复执行（u1 回支援阵线）")
        AssertEqual(#(KARDS.NodeParser.PendingTurns[tid] or {}), 0, "turn 场景1：恢复后挂起注册表清空")
    end

    -- 2 等待-敌方-结束-1次：本方回合结束不计数，敌方回合结束恢复
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_tn2", "P1", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimBeginTurn("P1")
        KARDS.Battle:SimMoveToFrontline(u1)
        local tn = MakeBaseNode("turn", TURN_BASE, {
            ["select_1"] = 1, ["select_2"] = 2, ["select_3"] = 2, ["number_1"] = 1, -- 等待/敌方/结束/1次
        }, { id = "tn2" })
        local retreat = MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 1,
        }, { id = "tn2_retreat" })
        local cmd = MakeBranchCommandCard("cmd_tn2", { tn, retreat }, {
            { fromNode = "tn2", toNode = "tn2_retreat", fromPort = "output" },
        })
        AssertTrue(PlayCommand(cmd, { u1 }), "turn 场景2：P1 打出等待指令生效（挂起注册）")
        KARDS.Battle:SimEndTurn("P1") -- 本方回合结束：不匹配（敌方 = P2）
        AssertEqual(ZoneOf(tid, u1), "frontline", "turn 场景2：本方回合结束不计数（u1 仍在前线）")
        KARDS.Battle:SimEndTurn("P2") -- 敌方回合结束：计数达标 → 恢复
        AssertEqual(ZoneOf(tid, u1), "support", "turn 场景2：敌方回合结束 → 恢复执行（u1 回支援阵线）")
    end

    -- 3 等待-任意-开始-2次：两次回合开始计数达标后恢复
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_tn3", "P1", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimBeginTurn("P1")
        KARDS.Battle:SimMoveToFrontline(u1)
        local tn = MakeBaseNode("turn", TURN_BASE, {
            ["select_1"] = 1, ["select_2"] = 3, ["select_3"] = 1, ["number_1"] = 2, -- 等待/任意/开始/2次
        }, { id = "tn3" })
        local retreat = MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 1,
        }, { id = "tn3_retreat" })
        local cmd = MakeBranchCommandCard("cmd_tn3", { tn, retreat }, {
            { fromNode = "tn3", toNode = "tn3_retreat", fromPort = "output" },
        })
        AssertTrue(PlayCommand(cmd, { u1 }), "turn 场景3：P1 打出等待指令生效（挂起注册）")
        KARDS.Battle:SimBeginTurn("P2") -- 第 1 次回合开始（任意阵营计数）
        AssertEqual(ZoneOf(tid, u1), "frontline", "turn 场景3：第 1 次开始计数未达标（u1 仍在前线）")
        KARDS.Battle:SimBeginTurn("P1") -- 第 2 次 → 达标恢复
        AssertEqual(ZoneOf(tid, u1), "support", "turn 场景3：第 2 次开始 → 恢复执行（u1 回支援阵线）")
    end

    -- 4 使-友方回合结束：立即结束效果拥有者（P1）回合（countdown 1 单位移除）+ 下游未挂起直接执行
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_tn4", "P1", { attack = 3, defense = 5 })
        local u2 = MakeUnit("u_tn4c", "P1", { attack = 1, defense = 3, keywords = { { "countdown", 1 } } })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimDeploy(u2, 1)
        KARDS.Battle:SimBeginTurn("P1")
        KARDS.Battle:SimMoveToFrontline(u1)
        local tn = MakeBaseNode("turn", TURN_BASE, {
            ["select_1"] = 2, ["select_4"] = 1, ["select_5"] = 1, -- 使/友方/回合结束
        }, { id = "tn4" })
        local retreat = MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 1,
        }, { id = "tn4_retreat" })
        local cmd = MakeBranchCommandCard("cmd_tn4", { tn, retreat }, {
            { fromNode = "tn4", toNode = "tn4_retreat", fromPort = "output" },
        })
        AssertTrue(PlayCommand(cmd, { u1 }), "turn 场景4：P1 打出「使-回合结束」指令生效")
        AssertEqual(ZoneOf(tid, u1), "support", "turn 场景4：立即执行（下游撤退生效，u1 回支援阵线）")
        AssertEqual(ZoneOf(tid, u2), nil, "turn 场景4：回合结束生效（countdown 1 单位被移除）")
    end

    -- 5 使-友方跳过回合：结束效果拥有者（P1）回合 + 开始其对手（P2）回合
    do
        local tid = NewBattle()
        KARDS.Battle:SimBeginTurn("P1") -- 回合数 1，当前回合玩家 P1
        local tn = MakeBaseNode("turn", TURN_BASE, {
            ["select_1"] = 2, ["select_4"] = 1, ["select_5"] = 2, -- 使/友方/跳过回合
        }, { id = "tn5" })
        AssertTrue(PlayCommand(MakeCommandCard("cmd_tn5", tn)), "turn 场景5：P1 打出「使-跳过回合」指令生效")
        AssertEqual(KARDS.Battle.TurnNumbers[tid], 2, "turn 场景5：跳过回合 → 对手回合开始（回合数 +1）")
        AssertEqual(KARDS.Battle.CurTurnPlayer[tid], "P2", "turn 场景5：当前回合玩家转为对手（P2）")
    end

    -- 6 顺序模式（无连线）：挂起 → 从挂起节点数组后继恢复
    do
        local tid = NewBattle()
        local u1 = MakeUnit("u_tn6", "P1", { attack = 3, defense = 5 })
        KARDS.Battle:SimDeploy(u1, 3)
        KARDS.Battle:SimBeginTurn("P1")
        KARDS.Battle:SimMoveToFrontline(u1)
        local tn = MakeBaseNode("turn", TURN_BASE, {
            ["select_1"] = 1, ["select_2"] = 1, ["select_3"] = 1, ["number_1"] = 1, -- 等待/友方/开始/1次
        }, { id = "tns1" })
        local retreat = MakeBaseNode("action", ACTION_BASE, {
            ["select_2"] = 1, ["select_3"] = 1,
        })
        local cmd = MakeCommandCard("cmd_tn6", tn)
        cmd.effect.nodes = { tn, retreat } -- 顺序模式（无 connections）
        AssertTrue(PlayCommand(cmd, { u1 }), "turn 场景6：顺序模式等待指令生效（挂起注册）")
        AssertEqual(ZoneOf(tid, u1), "frontline", "turn 场景6：挂起时后续节点未执行（u1 仍在前线）")
        KARDS.Battle:SimBeginTurn("P1")
        AssertEqual(ZoneOf(tid, u1), "support", "turn 场景6：恢复后从挂起节点后继继续（u1 回支援阵线）")
    end
end

-- 反制系统测试：激活登记与隐藏花费 / 回合校验 / 手动失活返还 / 到点自动失活 /
-- 激活操作本身可被拦截 / 拦截命中自动打出 / 保持拦截型反制自动打出 /
-- 反制卡拦截另一张反制的激活操作 / 属性变更改写数值与敌方视角扣费
-- （KARDS.Counter 与 SimActivateCounter、
-- SimDeactivateCounter、FireCounter，反制系统 M2/M4/M5）
-- 依赖：KARDS.Counter（sh_counter.lua）、KARDS.CommandPoints 隐藏池、统一操作钩子
local function RunCounterTest()
    -- 构造反制卡（counter_command，花费 cost）；opts 可指定：
    --   owner  归属方（默认 "P1"）
    --   mode   附带「激活时」拦截效果链："once" 拦截一次（select_1=4, select_2）/ "keep" 保持拦截（select_1=5, select_3）
    --   opType 拦截的操作类型选项索引（INTERCEPT_OPTYPES 顺序，默认 1 = 打出指令）
    --   finish 收尾方式：2 = 属性变更（改写数值，不要求函数槽）；缺省 1 = 反制
    --   mod / value 属性变更的数值修饰索引与数值（仅 finish = 2 时生效）
    -- 不传 mode 则构造无效果的反制卡（仅用于激活状态与花费断言）
    local function MakeCounterCard(id, cost, opts)
        opts = opts or {}
        local cc = KARDS.CardInterface.CreateMockCard(id, "counter_command", opts.owner or "P1", { cost = cost or 0 })
        if opts.mode then
            local vals = { ["funcslot_1"] = "拦截函数" }
            if opts.mode == "keep" then
                vals["select_1"] = 5 -- 保持拦截
                vals["select_3"] = opts.opType or 1
            else
                vals["select_1"] = 4 -- 拦截一次
                vals["select_2"] = opts.opType or 1
            end
            if opts.finish == 2 then
                vals["funcslot_1"] = nil -- 属性变更只改数值，函数槽留空也可
                if opts.mode == "keep" then
                    vals["select_8"] = 2
                    vals["select_9"] = opts.mod or 1
                    vals["number_2"] = opts.value or 0
                else
                    vals["select_6"] = 2
                    vals["select_7"] = opts.mod or 1
                    vals["number_1"] = opts.value or 0
                end
            end
            local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, vals)
            cc.effect = {
                nodes = { tf },
                variables = { f = { { name = "拦截函数", internalName = "KARDS.User.拦截函数",
                    functionData = { nodes = {}, connections = {}, dataConnections = {} } } } },
                dataConnections = {},
            }
        end
        return cc
    end
    -- 给指定玩家直接注入 N 指挥点（绕过回合补给；扣费断言需要确定基数；玩家缺省 P1）
    local function GivePoints(tid, n, player)
        player = player or "P1"
        local cp = KARDS.CommandPoints:Get(tid)
        cp.Slots[player] = n
        cp.Points[player] = n
    end

    -- 1 激活：登记 + 支付 + 隐藏花费（对敌口径不变）+ activate_counter 刻
    do
        local tid = NewBattle()
        GivePoints(tid, 5)
        local cc = MakeCounterCard("counter_a1", 2)
        GiveHand(tid, "P1", cc)
        AssertTrue(KARDS.Battle:SimActivateCounter("P1", cc), "counter 场景1：P1 激活反制成功")
        AssertTrue(KARDS.Counter:IsActive(tid, cc), "counter 场景1：登记为已激活")
        AssertEqual(KARDS.CommandPoints:GetPoints(tid, "P1"), 3, "counter 场景1：已扣花费（5 - 2 = 3）")
        AssertEqual(KARDS.CommandPoints:GetHidden(tid, "P1"), 2, "counter 场景1：花费计入隐藏池（2）")
        AssertEqual(KARDS.CommandPoints:GetPublicPoints(tid, "P1"), 5, "counter 场景1：对敌方口径不变（隐藏，5）")
        AssertTrue(HasTickOp(tid, cc, "activate_counter"), "counter 场景1：记录 activate_counter 刻")
    end

    -- 2 非本方回合拒绝激活（不扣费不入册）
    do
        local tid = NewBattle()
        GivePoints(tid, 5)
        local cc = MakeCounterCard("counter_a2", 2)
        GiveHand(tid, "P1", cc)
        KARDS.Battle.CurTurnPlayer[tid] = "P2" -- 当前为 P2 回合
        AssertEqual(KARDS.Battle:SimActivateCounter("P1", cc), false, "counter 场景2：非本方回合拒绝激活")
        AssertEqual(KARDS.Counter:IsActive(tid, cc), false, "counter 场景2：未登记激活")
        AssertEqual(KARDS.CommandPoints:GetPoints(tid, "P1"), 5, "counter 场景2：未扣花费（5）")
    end

    -- 3 手动失活：返还花费 + 隐藏池清零 + 移出登记；未激活失活返回 false
    do
        local tid = NewBattle()
        GivePoints(tid, 5)
        local cc = MakeCounterCard("counter_a3", 2)
        GiveHand(tid, "P1", cc)
        KARDS.Battle.CurTurnPlayer[tid] = "P1"
        AssertTrue(KARDS.Battle:SimActivateCounter("P1", cc), "counter 场景3：P1 激活反制成功")
        -- 取消激活只能在持有者本方回合进行：敌方回合取消失败且状态保持
        KARDS.Battle.CurTurnPlayer[tid] = "P2"
        AssertEqual(KARDS.Battle:SimDeactivateCounter("P1", cc), false,
            "counter 场景3：敌方回合不能取消激活")
        AssertTrue(KARDS.Counter:IsActive(tid, cc), "counter 场景3：取消失败后仍为激活")
        -- 回合开始后（本方回合）取消激活并返还
        KARDS.Battle.CurTurnPlayer[tid] = "P1"
        AssertTrue(KARDS.Battle:SimDeactivateCounter("P1", cc), "counter 场景3：本方回合取消激活成功")
        AssertEqual(KARDS.Counter:IsActive(tid, cc), false, "counter 场景3：移出激活登记")
        AssertEqual(KARDS.CommandPoints:GetPoints(tid, "P1"), 5, "counter 场景3：返还花费（3 + 2 = 5）")
        AssertEqual(KARDS.CommandPoints:GetHidden(tid, "P1"), 0, "counter 场景3：隐藏池清零")
        AssertEqual(KARDS.Battle:SimDeactivateCounter("P1", cc), false, "counter 场景3：未激活失活返回 false")
    end

    -- 4 到点自动失活：他方回合结束不影响；激活当回合结束保留；跨过一个完整敌方回合后失活不返还
    do
        local tid = NewBattle()
        GivePoints(tid, 5)
        local cc = MakeCounterCard("counter_a4", 2)
        GiveHand(tid, "P1", cc)
        KARDS.Battle.CurTurnPlayer[tid] = "P1"
        KARDS.Battle.TurnNumbers[tid] = 1 -- 激活发生在第 1 回合
        AssertTrue(KARDS.Battle:SimActivateCounter("P1", cc), "counter 场景4：P1 激活反制成功")
        KARDS.Counter:OnTurnEnd(tid, "P2") -- 他方回合结束
        AssertTrue(KARDS.Counter:IsActive(tid, cc), "counter 场景4：他方回合结束不自动失活")
        KARDS.Counter:OnTurnEnd(tid, "P1") -- 激活当回合结束（回合序号未变）
        AssertTrue(KARDS.Counter:IsActive(tid, cc), "counter 场景4：激活当回合结束保留")
        KARDS.Battle.TurnNumbers[tid] = 3 -- 已经历一个完整敌方回合
        KARDS.Counter:OnTurnEnd(tid, "P1")
        AssertEqual(KARDS.Counter:IsActive(tid, cc), false, "counter 场景4：跨回合自动失活")
        AssertEqual(KARDS.CommandPoints:GetHidden(tid, "P1"), 0, "counter 场景4：自动失活隐藏池清零")
        AssertEqual(KARDS.CommandPoints:GetPoints(tid, "P1"), 3, "counter 场景4：自动失活不返还花费（3）")
    end

    -- 5 激活反制本身可被拦截（统一操作钩子 activate_counter）：被拦截则不支付不入册
    do
        local tid = NewBattle()
        GivePoints(tid, 5)
        local cc = MakeCounterCard("counter_a5", 2)
        GiveHand(tid, "P1", cc)
        KARDS.EngineHooks.Register(tid, KARDS.EngineHooks.HookPoints.OnBeforeOperation, "hook_act_block",
            function(args)
                if args.opType == "activate_counter" then args.intercepted = true end
                return args
            end)
        AssertEqual(KARDS.Battle:SimActivateCounter("P1", cc), false, "counter 场景5：激活操作被拦截（返回 false）")
        AssertEqual(KARDS.Counter:IsActive(tid, cc), false, "counter 场景5：被拦截后未登记激活")
        AssertEqual(KARDS.CommandPoints:GetPoints(tid, "P1"), 5, "counter 场景5：被拦截后未扣花费（5）")
    end

    -- 6 拦截命中自动打出（FireCounter）：已激活反制经 trigger_function 拦截钩子命中敌方打出指令 →
    -- 移出手牌 + 公开隐藏花费 + 记录 counter 刻 + 通知牌桌实体按指令口径广播（回调）
    do
        local tid = NewBattle()
        GivePoints(tid, 5)
        local cc = MakeCounterCard("counter_a6", 2, { mode = "once", opType = 1 }) -- 带「拦截一次·打出指令」效果链
        GiveHand(tid, "P1", cc)
        KARDS.Battle.CurTurnPlayer[tid] = "P1"
        AssertTrue(KARDS.Battle:SimActivateCounter("P1", cc), "counter 场景6：P1 激活拦截型反制")
        -- 牌桌实体广播回调（数据层不直接依赖实体，见 sh_battle_combat.lua）
        local played = { count = 0, card = nil, slot = nil }
        KARDS.Battle:SetCounterPlayCallback(tid, function(card, slot)
            played.count = played.count + 1
            played.card = card
            played.slot = slot
        end)
        -- P2 打出指令 → 命中已激活反制（拦截后指令效果不生效）
        local vNode = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2 })
        local v = KARDS.CardInterface.CreateMockCard("cmd_counter_v1", "command", "P2", { cost = 0 })
        v.effect = { nodes = { vNode }, variables = {}, dataConnections = {} }
        AssertEqual(KARDS.Battle:SimPlayCard("P2", v, {}), false, "counter 场景6：P2 指令被反制拦截（返回 false）")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P2"):GetStat("defense"), 20,
            "counter 场景6：被拦截后指令效果未生效（P2 HQ 20）")
        AssertEqual(KARDS.Counter:IsActive(tid, cc), false, "counter 场景6：命中后移出激活登记")
        AssertEqual(HandContains(tid, "P1", cc), false, "counter 场景6：命中后反制移出手牌")
        AssertEqual(KARDS.CommandPoints:GetHidden(tid, "P1"), 0, "counter 场景6：命中后隐藏花费公开清零")
        AssertTrue(HasTickOp(tid, cc, "counter"), "counter 场景6：记录 counter 刻（发起者 = 反制卡）")
        AssertEqual(played.count, 1, "counter 场景6：通知牌桌实体广播打出动画（回调 1 次）")
        AssertEqual(played.card, cc, "counter 场景6：广播回调带反制卡")
        AssertEqual(played.slot, 1, "counter 场景6：广播槽位为归属方 P1（1）")
        KARDS.Battle.CounterPlayCallbacks[tid] = nil -- 清理回调（防跨场景残留）
    end

    -- 7 保持拦截型反制自动打出：与场景6同链路，但走「保持拦截」分支（select_1=5）；
    -- 命中一次后反制被消费（FireCounter 移出手牌并注销钩子），后续敌方操作不再被拦
    do
        local tid = NewBattle()
        GivePoints(tid, 5)
        local cc = MakeCounterCard("counter_a7", 2, { mode = "keep", opType = 1 }) -- 保持拦截·打出指令
        GiveHand(tid, "P1", cc)
        KARDS.Battle.CurTurnPlayer[tid] = "P1"
        AssertTrue(KARDS.Battle:SimActivateCounter("P1", cc), "counter 场景7：P1 激活保持拦截型反制")
        local played = { count = 0, slot = nil }
        KARDS.Battle:SetCounterPlayCallback(tid, function(_, slot)
            played.count = played.count + 1
            played.slot = slot
        end)
        local function makeV(idd)
            local vNode = MakeBaseNode("headquarter", HEADQUARTER_BASE, { ["select_1"] = 1, ["select_2"] = 1, ["number_1"] = 2 })
            local v = KARDS.CardInterface.CreateMockCard(idd, "command", "P2", { cost = 0 })
            v.effect = { nodes = { vNode }, variables = {}, dataConnections = {} }
            return v
        end
        -- 第一次 P2 打出指令 → 命中保持拦截并自动打出反制
        AssertEqual(KARDS.Battle:SimPlayCard("P2", makeV("cmd_counter_v7_1"), {}), false,
            "counter 场景7：P2 指令被保持拦截（返回 false）")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P2"):GetStat("defense"), 20,
            "counter 场景7：拦截后指令效果未生效（P2 HQ 20）")
        AssertEqual(KARDS.Counter:IsActive(tid, cc), false, "counter 场景7：命中后移出激活登记")
        AssertEqual(HandContains(tid, "P1", cc), false, "counter 场景7：命中后反制移出手牌")
        AssertEqual(KARDS.CommandPoints:GetHidden(tid, "P1"), 0, "counter 场景7：命中后隐藏花费公开清零")
        AssertTrue(HasTickOp(tid, cc, "counter"), "counter 场景7：记录 counter 刻")
        AssertEqual(played.count, 1, "counter 场景7：广播回调 1 次")
        AssertEqual(played.slot, 1, "counter 场景7：广播槽位为归属方 P1（1）")
        -- 反制已被消费并注销钩子 → 第二次 P2 打出指令不被拦截，效果照常生效
        AssertEqual(KARDS.Battle:SimPlayCard("P2", makeV("cmd_counter_v7_2"), {}), true,
            "counter 场景7：反制消费后再次打出不被拦截（返回 true）")
        AssertEqual(KARDS.Battlefield:GetHQ(tid, "P2"):GetStat("defense"), 22,
            "counter 场景7：第二次指令生效（P2 HQ 20 → 22）")
        AssertEqual(played.count, 1, "counter 场景7：反制消费后不再广播（仍 1 次）")
        KARDS.Battle.CounterPlayCallbacks[tid] = nil -- 清理回调
    end

    -- 8 反制拦下另一张反制的激活操作（链式）：P1 的已激活反制 A 拦截「激活反制」操作，
    -- P2 激活反制 B 时被 A 命中 → B 未入册未扣费、A 自动打出并消费
    do
        local tid = NewBattle()
        GivePoints(tid, 5, "P1")
        GivePoints(tid, 5, "P2")
        local a = MakeCounterCard("counter_a8", 2, { owner = "P1", mode = "once", opType = 2 }) -- 拦截「激活反制」
        local b = MakeCounterCard("counter_b8", 1, { owner = "P2" }) -- 无效果，仅待激活
        GiveHand(tid, "P1", a)
        GiveHand(tid, "P2", b)
        KARDS.Battle.CurTurnPlayer[tid] = "P1"
        AssertTrue(KARDS.Battle:SimActivateCounter("P1", a), "counter 场景8：P1 激活拦截型反制 A")
        KARDS.Battle.CurTurnPlayer[tid] = "P2" -- 轮到 P2 激活自己的反制
        AssertEqual(KARDS.Battle:SimActivateCounter("P2", b), false,
            "counter 场景8：P2 激活被 A 拦截（返回 false）")
        AssertEqual(KARDS.Counter:IsActive(tid, b), false, "counter 场景8：B 未登记激活")
        AssertEqual(KARDS.CommandPoints:GetPoints(tid, "P2"), 5, "counter 场景8：B 未扣花费（P2 5）")
        AssertTrue(HandContains(tid, "P2", b), "counter 场景8：B 留在手牌")
        AssertEqual(KARDS.Counter:IsActive(tid, a), false, "counter 场景8：A 命中后移出激活登记")
        AssertEqual(HandContains(tid, "P1", a), false, "counter 场景8：A 命中后移出手牌")
        AssertEqual(KARDS.CommandPoints:GetHidden(tid, "P1"), 0, "counter 场景8：A 隐藏花费公开清零")
        AssertTrue(HasTickOp(tid, a, "counter"), "counter 场景8：A 记录 counter 刻")
    end

    -- 9 已激活反制以「属性变更」收尾拦截敌方伤害：改写数值但不取消操作；扣费发生在激活时
    -- （隐藏），命中时只公开隐藏花费、不再次扣费；敌方视角在命中前看不到扣费
    do
        local tid = NewBattle()
        GivePoints(tid, 5, "P1")
        -- 拦截一次 / 伤害 / 属性变更 / 至多 1（无函数槽，属性变更不要求函数）
        local cc = MakeCounterCard("counter_a9", 2, {
            owner = "P1", mode = "once", opType = 13, finish = 2, mod = 4, value = 1,
        })
        GiveHand(tid, "P1", cc)
        KARDS.Battle.CurTurnPlayer[tid] = "P1"
        AssertTrue(KARDS.Battle:SimActivateCounter("P1", cc), "counter 场景9：P1 激活属性变更型反制")
        AssertEqual(KARDS.CommandPoints:GetPoints(tid, "P1"), 3, "counter 场景9：激活时扣费（5 - 2 = 3）")
        AssertEqual(KARDS.CommandPoints:GetHidden(tid, "P1"), 2, "counter 场景9：花费计入隐藏池（2）")
        AssertEqual(KARDS.CommandPoints:GetPublicPoints(tid, "P1"), 5, "counter 场景9：激活后敌方视角不变（5）")
        -- 对方回合：P2 对 P1 单位造成 3 点伤害，被改写为至多 1
        KARDS.Battle.CurTurnPlayer[tid] = "P2"
        local target = MakeUnit("u_counter9_t", "P1", { attack = 1, defense = 10 })
        local src = MakeUnit("u_counter9_s", "P2", { attack = 3, defense = 10 })
        KARDS.Battle:SimDeploy(target, 3)
        KARDS.Battle:SimDeploy(src, 3)
        KARDS.Battle:SimDealDamage(src, target, 3)
        AssertEqual(target:GetStat("defense"), 9, "counter 场景9：伤害被改写为至多 1（10 → 9），操作未取消")
        -- 命中后自动打出：移出登记与手牌，隐藏花费公开，不再次扣费
        AssertEqual(KARDS.Counter:IsActive(tid, cc), false, "counter 场景9：命中后移出激活登记")
        AssertEqual(HandContains(tid, "P1", cc), false, "counter 场景9：命中后移出手牌")
        AssertEqual(KARDS.CommandPoints:GetHidden(tid, "P1"), 0, "counter 场景9：命中后隐藏花费公开清零")
        AssertEqual(KARDS.CommandPoints:GetPoints(tid, "P1"), 3, "counter 场景9：命中不再次扣费（仍 3）")
        AssertEqual(KARDS.CommandPoints:GetPublicPoints(tid, "P1"), 3, "counter 场景9：命中后敌方视角公开扣费（5 → 3）")
        AssertTrue(HasTickOp(tid, cc, "counter"), "counter 场景9：记录 counter 刻")
    end
end

-- ====================================================================
-- 单位效果拦截测试（拦截可随时使用：单位在场期间持续拦截，离场/回手自动注销）
-- ====================================================================
-- 单位在以「部署」开始点执行效果链时注册持续拦截（trigger_function 保持拦截，见
-- sh_node_hooks.lua RegisterIntercept）。拦截归属本方（owner），只拦敌方发起的操作；
-- 单位离场（SimRemoveFromField）/ 回手（SimReturnToHand）时经 EngineHooks.UnregisterByEntity
-- 注销绑定该卡的钩子，拦截随之失效（2026-10-05 修复：此前只注销 EffectRegistry，引擎钩子残留）。
-- 操作类型索引按 INTERCEPT_OPTYPES：抽取 = 9，弃牌 = 10。
local function RunUnitInterceptTest()
    -- 构造带「部署」开始点 + 保持拦截 的单位卡（owner 固定 P1；opTypeIndex 见上）
    local function MakeInterceptUnit(id, opTypeIndex)
        local u = MakeUnit(id, "P1", { attack = 1, defense = 5 })
        local startNode = { type = "start", data = { title = "部署" } } -- 部署开始点
        local tf = MakeBaseNode("trigger_function", TRIGGER_FUNCTION_BASE, {
            ["select_1"] = 5, ["funcslot_1"] = "拦截函数", ["select_3"] = opTypeIndex, -- 保持拦截/函数/操作类型
        })
        u.effect = {
            nodes = { startNode, tf },
            variables = { f = { { name = "拦截函数", internalName = "KARDS.User.拦截函数",
                functionData = { nodes = {}, connections = {}, dataConnections = {} } } } },
            dataConnections = {},
        }
        return u
    end

    -- 1 单位部署注册保持拦截·抽取：敌方抽取被拦（返回空，手牌不增）
    do
        local tid = NewBattle()
        -- P2 卡组需有牌，否则「被拦返回空」与「卡组为空返回空」无法区分
        KARDS.Battle:SimSetupDeck("P2", { KARDS.CardInterface.CreateMockCard("deck_itc1", "unit", "P2", {}) })
        local u = MakeInterceptUnit("u_itc1", 9) -- 抽取
        AssertTrue(KARDS.Battle:SimDeploy(u, 3), "unit 拦截场景1：P1 部署拦截单位")
        local before = #KARDS.Deck:GetHand(tid, "P2")
        local drawn = KARDS.Battle:SimDraw("P2", 1)
        AssertEqual(#drawn, 0, "unit 拦截场景1：P2 抽取被拦（返回空）")
        AssertEqual(#KARDS.Deck:GetHand(tid, "P2"), before, "unit 拦截场景1：P2 手牌未增加")
    end

    -- 2 单位离场后拦截自动注销：离场前被拦，离场后不再被拦
    do
        local tid = NewBattle()
        -- P2 卡组需有牌，离场后抽取 1 张才能验证拦截已注销
        KARDS.Battle:SimSetupDeck("P2", { KARDS.CardInterface.CreateMockCard("deck_itc2", "unit", "P2", {}) })
        local u = MakeInterceptUnit("u_itc2", 9)
        AssertTrue(KARDS.Battle:SimDeploy(u, 3), "unit 拦截场景2：P1 部署拦截单位")
        AssertEqual(#KARDS.Battle:SimDraw("P2", 1), 0, "unit 拦截场景2：离场前抽取被拦")
        AssertTrue(KARDS.Battle:SimRemoveFromField(u), "unit 拦截场景2：单位离场成功")
        AssertEqual(#KARDS.Battle:SimDraw("P2", 1), 1, "unit 拦截场景2：离场后抽取不被拦（抽到 1 张）")
    end

    -- 3 单位回手后拦截自动注销
    do
        local tid = NewBattle()
        -- P2 卡组需有牌，回手后抽取 1 张才能验证拦截已注销
        KARDS.Battle:SimSetupDeck("P2", { KARDS.CardInterface.CreateMockCard("deck_itc3", "unit", "P2", {}) })
        local u = MakeInterceptUnit("u_itc3", 9)
        AssertTrue(KARDS.Battle:SimDeploy(u, 3), "unit 拦截场景3：P1 部署拦截单位")
        AssertEqual(#KARDS.Battle:SimDraw("P2", 1), 0, "unit 拦截场景3：回手前抽取被拦")
        AssertTrue(KARDS.Battle:SimReturnToHand(u), "unit 拦截场景3：单位回手成功")
        AssertEqual(#KARDS.Battle:SimDraw("P2", 1), 1, "unit 拦截场景3：回手后抽取不被拦（抽到 1 张）")
    end

    -- 4 单位拦截·弃牌（友方手牌无法被弃掉）：敌方弃我方手牌被拦（卡留手牌）；单位离场后不再被拦
    do
        local tid = NewBattle()
        local u = MakeInterceptUnit("u_itc4", 10) -- 弃牌
        AssertTrue(KARDS.Battle:SimDeploy(u, 3), "unit 拦截场景4：P1 部署拦截单位")
        local hc = KARDS.CardInterface.CreateMockCard("hand_itc4", "command", "P1", { cost = 0 })
        GiveHand(tid, "P1", hc)
        AssertEqual(KARDS.Battle:SimDiscard("P2", hc), false, "unit 拦截场景4：P2 弃 P1 手牌被拦（返回 false）")
        AssertTrue(HandContains(tid, "P1", hc), "unit 拦截场景4：被弃手牌留在手牌")
        AssertTrue(KARDS.Battle:SimRemoveFromField(u), "unit 拦截场景4：单位离场成功")
        AssertEqual(KARDS.Battle:SimDiscard("P2", hc), true, "unit 拦截场景4：离场后弃牌不被拦（返回 true）")
        AssertEqual(HandContains(tid, "P1", hc), false, "unit 拦截场景4：弃牌成功，手牌移出")
    end
end

-- ====================================================================
-- 主入口
-- ====================================================================
function RunNodeParserBattleTests()
    print("==============================================")
    print("KARDS 节点解析器战斗场景测试开始（P1 打出指令触发节点效果）")
    print("==============================================")
    TestsPassed, TestsFailed = 0, 0
    FailedTests = {}
    RunActionGainTest()
    RunActionCancelTest()
    RunActionDestroyTest()
    RunCardSideTest(1, "P1") -- 友方（select_1 = 1）
    RunCardSideTest(2, "P2") -- 敌方（select_1 = 2）
    RunCommandTest()
    RunConditionTest()
    RunConditionBranchTest()
    RunEventMonitorTest()
    RunEventMonitorBranchTest()
    RunExtractTest()
    RunHeadquarterTest()
    RunHQDestroyTest() -- HQ 摧毁判定（单位攻击总部至 ≤0 → 对局结束；双毁）
    RunLoopTest()
    RunPropertyTest()
    RunRegisterHookTest()
    RunTargetSelectorTest()
    RunTriggerFunctionTest()
    RunTriggerTest()
    RunTurnTest()
    RunCounterTest() -- 反制系统（激活/失活/到点失活/激活可被拦截/拦截命中自动打出/保持拦截自动打出/反制拦反制）
    RunUnitInterceptTest() -- 单位效果拦截（单位在场持续拦截·抽取/弃牌；离场与回手自动注销引擎钩子）
    print("==============================================")
    -- 出现 FAIL 项时，在"测试完成"前将失败项重新打印一遍（便于从长输出中定位）
    if TestsFailed > 0 then
        for _, msg in ipairs(FailedTests) do
            print(msg)
        end
    end
    print(("测试完成: 通过 %d, 失败 %d"):format(TestsPassed, TestsFailed))
    print("==============================================")
    return TestsFailed == 0
end

-- GMod 控制台命令：kards_node_battle_test（仅服务端注册；玩家执行需 operator 及以上，服务器控制台放行）
if SERVER and concommand then
    concommand.Add("kards_node_battle_test", function(ply)
        if not KARDS.CanUseDevCommand(ply) then
            print("[Kards] kards_node_battle_test：需要 operator 及以上权限")
            return
        end
        RunNodeParserBattleTests()
    end)
end
