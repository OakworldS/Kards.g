--[[
    节点解析器测试 (Node Parser Test)

    在 GMod 控制台执行 kards_node_test 运行全部场景（纯数据层，服务端/客户端皆可）。
    测试对象：KARDS.NodeParser（lua/kards/sh_node_parser.lua）—— 设置变量节点专属解析器。

    以节点类型分割场景，覆盖解析器与战斗系统操作的组合映射：
      1. RunSetNumberTest          n  数字（设为/增加/减少/引用/预定义变量/长期变量）
      2. RunSetBoolTest            b  布尔（设为/反转）
      3. RunSetTextTest            t  文本
      4. RunSetArrayTest           g  数组（整体复制/第 X 项·值/第 X 项·类型/最后一项/e 项对象句柄/索引非法）
      5. RunSetObjectTest          e  对象（empty 设为 / unit·cmd 数值属性含 {设为,增加,减少} /
                                       单位类型单选（值存英文内部名）/ 词条（战斗机剔除烟幕）/
                                       名称·描述·历史文本 / 插图含"无插图" / 子类型 /
                                       品质无通道 / 无 cardAppearance 卡兜底）
      6. RunSetScopeTest           global·longterm 作用域（每卡实例隔离 / 全等共用 /
                                       initialValue 兜底 / 战斗结束 ResetBattleVars 重置）
      7. RunSetDataConnectionTest  数据线来源（source=="input" 按 connId 取 variableName）
      8. RunInvalidInputTest       非法/边界输入（空条目/非法类型/空名/函数占位/索引 0/非法数字/引用不存在）
      9. RunEntryPointTest         解析器入口（ParseSetVariable 多条目 + 每条写入记录 stat_change 刻）
      10. RunEvaluateTest           判断变量关系（var_evaluate：六种运算符 / 右值引用 / 数据线输入 /
                                       AND·OR 组合 / 左结合 / 不产生 stat_change 刻 / 非数字·空条件·未知运算符边界）
      11. RunBaseTest               base 通用解析器（base 结构串：前缀/后缀、select·number·funcslot、
                                       [lib] 变量库数字槽、if 嵌套与分支绑定、action 真实 base、
                                       槽值回退 slots→dropdowns→data、空 base/无 base 边界）
      12. RunCardBaseTest            card 模板 base（else 分支 / 嵌套 if / 中文输出名 /
                                      分支序号 1·4·7·10·11·12·13 / number·select 独立计数 /
                                      H5 开发分支改为 [0]{1}（次数 + {$} 开发池））
      13. RunFactOverrideTest        事实变量一回合覆盖（IsFactPath 判定 / SetFactOverride 首次快照 /
                                      SetFact 被覆盖时让位 / ClearFactOverrides 按快照还原并清空登记 /
                                      未改写路径不受影响 / 用户自定义变量不登记覆盖 /
                                      ParseSetVariable 写入事实变量生效且登记覆盖）

    测试不依赖真实牌桌/卡组/手牌系统，全部使用 MockCard（KARDS.CardInterface.CreateMockCard）。
]]

KARDS = KARDS or {}

local NP = KARDS.NodeParser
local V = KARDS.VarLib

local TestsPassed = 0
local TestsFailed = 0
local FailedTests = {}  -- 本次运行失败的断言消息（结束前重新打印一遍）

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
-- 测试辅助（牌桌/上下文/条目/变量定义）
-- ====================================================================

-- 新建/重置牌桌变量库（专用前缀 np_ 避免与 kards_test 既有牌桌冲突）
-- 同时清空该牌桌的 TickLog 刻（V.Destroy 不清理 TickLog，重复运行会累积计数）
local function NewTable(tableID)
    if V.Exists(tableID) then V.Destroy(tableID) end
    if KARDS.TickLog then KARDS.TickLog:Clear(tableID) end
    return V.GetOrCreate(tableID)
end

-- 构造执行上下文（与 ParseSetVariable 的 ctx 约定一致）
local function MakeCtx(tableID, card, variables, dataConnections)
    return {
        tableID = tableID,
        initiatorCard = card,
        variables = variables,
        dataConnections = dataConnections,
    }
end

-- 构造设置行条目（_setEntries 元素；extra 覆盖/追加字段如 objOpIdx/subOpIdx/itemType/itemIndex/source/connId）
local function MakeEntry(varType, varName, opIdx, value, extra)
    local e = {
        varType = varType,
        varName = varName,
        opIdx = opIdx or 1,
        value = value,
        source = "global",
    }
    if extra then
        for k, v in pairs(extra) do e[k] = v end
    end
    return e
end

-- 读取指定牌桌最后一条 stat_change 刻的变更文本（无刻返回 nil）
-- PushStatChange 将 change 置于受影响项第三位：
--   tick = { initiator = {卡牌, 操作类型数组}, targets = { {卡牌, 操作类型数组, change} } }
local function LastChange(tableID)
    local n = KARDS.TickLog:Count(tableID)
    if n == 0 then return nil end
    local tick = KARDS.TickLog:GetTick(tableID, n)
    local targets = tick and tick[2]
    return (targets and targets[1] and targets[1][3]) or nil
end

-- 读取卡牌实例变量空间（global 作用域用户变量）
local function GetCardVar(tableID, card, internalName)
    local T = V.Get(tableID)
    return T and T.CardVars and T.CardVars[card:GetID()] and T.CardVars[card:GetID()][internalName]
end

-- 用户自定义变量内部名（与 MakeVariables 的 internalName 对应）
local V_ATK = "KARDS.User.ATK_BONUS"       -- n global 攻击加成
local V_BOARD = "KARDS.User.BOARD"         -- n longterm 全局面板
local V_AWK = "KARDS.User.AWAKEN"          -- b global 是否觉醒
local V_LOG = "KARDS.User.LOG"             -- t global 战场记录
local V_QUEUE = "KARDS.User.QUEUE"         -- g global 友方队列
local V_QUEUE_SRC = "KARDS.User.QUEUE_SRC" -- g global 源队列
local V_TGT = "KARDS.User.TARGET"          -- e global 目标单位
local V_OBJ = "KARDS.User.SHARED_TARGET"   -- e longterm 共用目标

-- 标准编辑器变量定义（global + longterm 混合，覆盖 n/b/t/g/e）
local function MakeVariables()
    return {
        n = {
            { name = "攻击加成", internalName = V_ATK, scope = "global", initialValue = 0 },
            { name = "全局面板", internalName = V_BOARD, scope = "longterm", initialValue = 0 },
        },
        b = {
            { name = "是否觉醒", internalName = V_AWK, scope = "global", initialValue = false },
        },
        t = {
            { name = "战场记录", internalName = V_LOG, scope = "global", initialValue = "" },
        },
        g = {
            { name = "友方队列", internalName = V_QUEUE, scope = "global", initialValue = {} },
            { name = "源队列", internalName = V_QUEUE_SRC, scope = "global", initialValue = {} },
        },
        e = {
            { name = "目标单位", internalName = V_TGT, scope = "global", initialValue = nil },
            { name = "共用目标", internalName = V_OBJ, scope = "longterm", initialValue = nil },
        },
    }
end

-- 带 cardAppearance 数据定义对象的卡（模拟真实卡牌：外观字段写入通道）
local function MakeAppCard(id, stats)
    local card = KARDS.CardInterface.CreateMockCard(id, "unit", "P1", stats or { attack = 1, defense = 1 })
    card.cardAppearance = {
        cardType = "unit",
        name = "", description = "", historyText = "",
        imagePath = "", subtype = "",
    }
    return card
end

-- ====================================================================
-- 场景 1：数字（n）
-- ====================================================================
local function RunSetNumberTest()
    local tid = "np_num"
    NewTable(tid)
    local vars = MakeVariables()
    local card = KARDS.CardInterface.CreateMockCard("ncard", "unit", "P1", {})

    -- 设为
    AssertTrue(NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "攻击加成", 1, 5)), "数字 设为：返回 true")
    AssertEqual(GetCardVar(tid, card, V_ATK), 5, "数字 设为 5：CardVars[发起卡][攻击加成] == 5")
    AssertEqual(LastChange(tid), "=5", "数字 设为：stat_change 刻 =5")

    -- 增加
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "攻击加成", 2, 3))
    AssertEqual(GetCardVar(tid, card, V_ATK), 8, "数字 增加 3：5+3=8")
    AssertEqual(LastChange(tid), "+3", "数字 增加：stat_change 刻 +3")

    -- 减少
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "攻击加成", 3, 2))
    AssertEqual(GetCardVar(tid, card, V_ATK), 6, "数字 减少 2：8-2=6")
    AssertEqual(LastChange(tid), "-2", "数字 减少：stat_change 刻 -2")

    -- 引用（"var:<显示名>" 读被引用变量当前值）
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "攻击加成", 1, "var:攻击加成"))
    AssertEqual(GetCardVar(tid, card, V_ATK), 6, "数字 设为 引用：读自身当前值 6")

    -- 预定义系统变量（翻译表反查：「回合数」→ Battle.Turn）
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "回合数", 1, 1))
    AssertEqual(V.Get(tid).Battle.Turn, 1, "数字 预定义「回合数」→ Battle.Turn == 1")

    -- 长期变量（longterm → Battle[internalName]）
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "全局面板", 1, 3))
    AssertEqual(V.Get(tid).Battle[V_BOARD], 3, "数字 longterm「全局面板」→ Battle[internalName] == 3")
end

-- ====================================================================
-- 场景 2：布尔（b）
-- ====================================================================
local function RunSetBoolTest()
    local tid = "np_bool"
    NewTable(tid)
    local vars = MakeVariables()
    local card = KARDS.CardInterface.CreateMockCard("bcard", "unit", "P1", {})

    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("b", "是否觉醒", 1, "true"))
    AssertEqual(GetCardVar(tid, card, V_AWK), true, "布尔 设为 true")

    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("b", "是否觉醒", 2, nil))
    AssertEqual(GetCardVar(tid, card, V_AWK), false, "布尔 反转 → false")

    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("b", "是否觉醒", 2, nil))
    AssertEqual(GetCardVar(tid, card, V_AWK), true, "布尔 反转 → true")

    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("b", "是否觉醒", 1, "false"))
    AssertEqual(GetCardVar(tid, card, V_AWK), false, "布尔 设为 false")
end

-- ====================================================================
-- 场景 3：文本（t）
-- ====================================================================
local function RunSetTextTest()
    local tid = "np_text"
    NewTable(tid)
    local vars = MakeVariables()
    local card = KARDS.CardInterface.CreateMockCard("tcard", "unit", "P1", {})

    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("t", "战场记录", 1, "侦察到装甲部队"))
    AssertEqual(GetCardVar(tid, card, V_LOG), "侦察到装甲部队", "文本 直接写入")
end

-- ====================================================================
-- 场景 4：数组（g）
-- ====================================================================
local function RunSetArrayTest()
    local tid = "np_arr"
    local T = NewTable(tid)
    local vars = MakeVariables()
    local card = KARDS.CardInterface.CreateMockCard("gcard", "unit", "P1", {})

    -- 源队列预置（「设为」的拷贝源）
    T.CardVars[card:GetID()] = T.CardVars[card:GetID()] or {}
    T.CardVars[card:GetID()][V_QUEUE_SRC] = { "a", "b", "c" }

    -- 1. 设为：数组整体复制
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("g", "友方队列", 1, "源队列"))
    local q = GetCardVar(tid, card, V_QUEUE)
    AssertEqual(#q, 3, "数组 设为：拷贝长度 3")
    AssertEqual(q[1], "a", "数组 设为：项1 拷贝正确")

    -- 2. 第 X 项·值（数字）
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("g", "友方队列", 2, 9, { subOpIdx = 1, itemType = "n", itemIndex = 2 }))
    q = GetCardVar(tid, card, V_QUEUE)
    AssertEqual(q[2], 9, "数组 第2项·值：数字 9 写入")

    -- 3. 最后一项·值（布尔）
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("g", "友方队列", 3, "true", { subOpIdx = 1, itemType = "b" }))
    q = GetCardVar(tid, card, V_QUEUE)
    AssertEqual(q[3], true, "数组 最后一项·值：布尔 true 写入")

    -- 4. 第 X 项·类型（结构化标记 {_varType, _varName}）
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("g", "友方队列", 2, nil, { subOpIdx = 2, itemType = "t", itemName = "标签", itemIndex = 1 }))
    q = GetCardVar(tid, card, V_QUEUE)
    AssertEqual(q[1]._varType, "t", "数组 第1项·类型：_varType=t")
    AssertEqual(q[1]._varName, "标签", "数组 第1项·类型：_varName=标签")

    -- 5. 最后一项·类型
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("g", "友方队列", 3, nil, { subOpIdx = 2, itemType = "e", itemName = "目标单位" }))
    q = GetCardVar(tid, card, V_QUEUE)
    AssertEqual(q[#q]._varType, "e", "数组 最后一项·类型：_varType=e")
    AssertEqual(q[#q]._varName, "目标单位", "数组 最后一项·类型：_varName=目标单位")

    -- 6. e 项·值：对象变量 → 卡牌句柄
    local objCard = KARDS.CardInterface.CreateMockCard("arrObj", "unit", "P2", { attack = 1, defense = 1 })
    T.Battle[V_OBJ] = objCard
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("g", "友方队列", 2, "共用目标", { subOpIdx = 1, itemType = "e", itemIndex = 1 }))
    q = GetCardVar(tid, card, V_QUEUE)
    AssertEqual(q[1], objCard, "数组 第1项·值：对象项 = 卡牌句柄")

    -- 7. 非法索引（0）→ 拒绝
    local ok = NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("g", "友方队列", 2, 1, { subOpIdx = 1, itemType = "n", itemIndex = 0 }))
    AssertEqual(ok, false, "数组 第0项：非法索引 → false")
end

-- ====================================================================
-- 场景 5：对象（e）
-- ====================================================================
local function RunSetObjectTest()
    local tid = "np_obj"
    local T = NewTable(tid)
    local vars = MakeVariables()
    local cardA = KARDS.CardInterface.CreateMockCard("caster", "unit", "P1", {})

    -- 目标对象：longterm e 变量「共用目标」（Battle 预置单位卡）
    local objCard = KARDS.CardInterface.CreateMockCard("obj", "unit", "P2",
        { attack = 3, defense = 5, cost = 4, actionCost = 2, unitType = "infantry" })
    T.Battle[V_OBJ] = objCard

    -- 1. empty 设为：目标「目标单位」= 「共用目标」解析出的卡牌句柄
    AssertTrue(NP.ParseSetEntry(MakeCtx(tid, cardA, vars),
        MakeEntry("e", "目标单位", 1, "共用目标", { objMode = "empty" })), "对象 empty 设为：返回 true")
    AssertEqual(GetCardVar(tid, cardA, V_TGT), objCard, "对象 empty 设为：CardVars[发起卡][目标单位] == 目标卡")

    -- 2. 攻击力 设为 7（unit 操作集索引 3，objOpIdx=1 设为）
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 3, 7, { objMode = "unit", objOpIdx = 1 }))
    AssertEqual(objCard:GetStat("attack"), 7, "对象 攻击力 设为 7")
    AssertEqual(LastChange(tid), "=7", "对象 攻击力 设为：刻 =7")

    -- 3. 攻击力 增加 2（objOpIdx=2 增加）
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 3, 2, { objMode = "unit", objOpIdx = 2 }))
    AssertEqual(objCard:GetStat("attack"), 9, "对象 攻击力 增加 2 → 9")
    AssertEqual(LastChange(tid), "+2", "对象 攻击力 增加：刻 +2")

    -- 4. 防御力 减少 1（objOpIdx=3 减少）
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 4, 1, { objMode = "unit", objOpIdx = 3 }))
    AssertEqual(objCard:GetStat("defense"), 4, "对象 防御力 减少 1 → 4")
    AssertEqual(LastChange(tid), "-1", "对象 防御力 减少：刻 -1")

    -- 5. 花费 设为 6（操作集索引 1）
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 1, 6, { objMode = "unit", objOpIdx = 1 }))
    AssertEqual(objCard:GetCost(), 6, "对象 花费 设为 6")
    AssertEqual(LastChange(tid), "=6", "对象 花费 设为：刻 =6")

    -- 6. 花费 增加 1（objOpIdx=2：读旧值 +1）
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 1, 1, { objMode = "unit", objOpIdx = 2 }))
    AssertEqual(objCard:GetCost(), 7, "对象 花费 增加 1 → 7")
    AssertEqual(LastChange(tid), "+1", "对象 花费 增加：刻 +1")

    -- 7. 行动花费 减少 2（objOpIdx=3：读旧值 -2）
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 2, 2, { objMode = "unit", objOpIdx = 3 }))
    AssertEqual(objCard:GetActionCost(), 0, "对象 行动花费 减少 2 → 0")
    AssertEqual(LastChange(tid), "-2", "对象 行动花费 减少：刻 -2")

    -- 8. 攻击力 设为 引用 "var:攻击加成"（先设全局值 6）
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("n", "攻击加成", 1, 6))
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 3, "var:攻击加成", { objMode = "unit", objOpIdx = 1 }))
    AssertEqual(objCard:GetStat("attack"), 6, "对象 攻击力 设为 引用：取全局当前值 6")

    -- 9. 单位类型 设为 tank（操作集索引 5，值存英文内部名）
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 5, "tank", { objMode = "unit" }))
    AssertEqual(objCard:GetUnitType(), "tank", "对象 单位类型 设为 tank")

    -- 10. 单位类型 非法值（mech）→ 拒绝且保持原值
    local okUT = NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 5, "mech", { objMode = "unit" }))
    AssertEqual(okUT, false, "对象 单位类型 非法 mech → false")
    AssertEqual(objCard:GetUnitType(), "tank", "对象 单位类型 非法值不覆盖（保持 tank）")

    -- 11. 词条（操作集索引 7）：白名单过滤
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 7, "blitz,guard,非法词条", { objMode = "unit" }))
    AssertEqual(#objCard:GetKeywords(), 2, "对象 词条：非法词条剔除后剩 2 项")
    AssertTrue(objCard:HasKeyword("blitz") and objCard:HasKeyword("guard"), "对象 词条：保留 blitz 与 guard")

    -- 12. 战斗机剔除烟幕（readme 7.3）
    local fighter = KARDS.CardInterface.CreateMockCard("fig", "unit", "P2", { unitType = "fighter" })
    T.Battle[V_OBJ] = fighter
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 7, "smoke,guard", { objMode = "unit" }))
    AssertEqual(#fighter:GetKeywords(), 1, "对象 词条：战斗机剔除 smoke 后剩 1 项")
    AssertTrue(fighter:HasKeyword("guard") and not fighter:HasKeyword("smoke"), "对象 词条：战斗机剔除烟幕")

    -- 13-18. 外观字段（cardAppearance 数据定义对象）
    local appCard = MakeAppCard("app", { attack = 1, defense = 1 })
    T.Battle[V_OBJ] = appCard

    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 6, "侦察连", { objMode = "unit" }))
    AssertEqual(appCard.cardAppearance.name, "侦察连", "对象 卡牌名称 → cardAppearance.name")

    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 8, "前线侦察小队", { objMode = "unit" }))
    AssertEqual(appCard.cardAppearance.description, "前线侦察小队", "对象 描述 → cardAppearance.description")

    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 12, "历史记录一", { objMode = "unit" }))
    AssertEqual(appCard.cardAppearance.historyText, "历史记录一", "对象 历史文本 → cardAppearance.historyText")

    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 10, "../data/kards_images/test.png", { objMode = "unit" }))
    AssertEqual(appCard.cardAppearance.imagePath, "../data/kards_images/test.png", "对象 卡牌插图 → cardAppearance.imagePath")

    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 11, "", { objMode = "unit" }))
    AssertEqual(appCard.cardAppearance.imagePath, "", "对象 历史插图 空值 → 无插图（imagePath 置空）")

    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 13, "侦察", { objMode = "unit" }))
    AssertEqual(appCard.cardAppearance.subtype, "侦察", "对象 子类型 → cardAppearance.subtype")

    -- 19. 品质（操作集索引 9）：卡牌句柄无通道 → false
    AssertEqual(NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 9, "传奇", { objMode = "unit" })), false,
        "对象 品质：无写入通道 → false")

    -- 20. 无 cardAppearance 的卡：名称 → false（提示路径）
    T.Battle[V_OBJ] = objCard
    AssertEqual(NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 6, "改名", { objMode = "unit" })), false,
        "对象 无 cardAppearance 卡：名称 → false（骨架阶段无通道）")

    -- 21. cmd 对象：花费 增加（操作集索引 1）
    local cmdCard = KARDS.CardInterface.CreateMockCard("cmd", "command", "P1", { cost = 3 })
    T.Battle[V_OBJ] = cmdCard
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("e", "共用目标", 1, 2, { objMode = "cmd", objOpIdx = 2 }))
    AssertEqual(cmdCard:GetCost(), 5, "对象 cmd 花费 增加 2 → 5")
end

-- ====================================================================
-- 场景 6：全局 / 长期作用域
-- ====================================================================
local function RunSetScopeTest()
    local tid = "np_scope"
    NewTable(tid)
    local vars = MakeVariables()
    local cardA = KARDS.CardInterface.CreateMockCard("A", "unit", "P1", {})
    local cardB = KARDS.CardInterface.CreateMockCard("B", "unit", "P1", {})
    local cardC = KARDS.CardInterface.CreateMockCard("C", "unit", "P1", {})

    -- 全局：每张卡牌实例隔离
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("n", "攻击加成", 1, 5))
    NP.ParseSetEntry(MakeCtx(tid, cardB, vars), MakeEntry("n", "攻击加成", 1, 9))
    AssertEqual(GetCardVar(tid, cardA, V_ATK), 5, "全局：卡A 设为 5 → 自身空间 5")
    AssertEqual(GetCardVar(tid, cardB, V_ATK), 9, "全局：卡B 设为 9 → 自身空间 9")
    AssertEqual(GetCardVar(tid, cardA, V_ATK), 5, "全局：卡A 不受卡B 设置影响（实例隔离）")

    -- 全局：未设置过的卡调用时是初始值（initialValue=0）
    NP.ParseSetEntry(MakeCtx(tid, cardC, vars), MakeEntry("n", "攻击加成", 2, 2))
    AssertEqual(GetCardVar(tid, cardC, V_ATK), 2, "全局：新卡 C 未设置时读 initialValue 0 → 增加 2 → 2")

    -- 长期：全等卡牌共用（Battle 区）
    NP.ParseSetEntry(MakeCtx(tid, cardA, vars), MakeEntry("n", "全局面板", 1, 3))
    NP.ParseSetEntry(MakeCtx(tid, cardB, vars), MakeEntry("n", "全局面板", 2, 1))
    AssertEqual(V.Get(tid).Battle[V_BOARD], 4, "长期：卡A 设 3、卡B 增 1 → Battle 共享值 4")

    -- 战斗结束重置（ResetBattleVars：Battle 重建 + CardVars 清空）
    KARDS.VarLib.ResetBattleVars(tid)
    local T2 = V.Get(tid)
    AssertEqual(#(T2.CardVars or {}), 0, "战斗结束：CardVars 清空（全局变量重置）")
    AssertEqual(T2.Battle[V_BOARD], nil, "战斗结束：Battle 用户长期变量清空")
    AssertEqual(T2.Battle.Turn, 0, "战斗结束：Battle 预定义变量重置为初始值")
    -- 重置后全局变量读取回到 initialValue
    local ctx = MakeCtx(tid, cardA, vars)
    local tgt = NP.ResolveTarget(ctx, "n", "攻击加成")
    AssertEqual(NP.GetTarget(ctx, tgt), 0, "战斗结束：全局变量读取回到 initialValue 0")
end

-- ====================================================================
-- 场景 7：数据线来源（source=="input"）
-- ====================================================================
local function RunSetDataConnectionTest()
    local tid = "np_dc"
    NewTable(tid)
    local vars = MakeVariables()
    local card = KARDS.CardInterface.CreateMockCard("dccard", "unit", "P1", {})
    local dcs = { { id = "dc1", variableName = "全局面板" } }

    -- connId 匹配 → 目标变量名 = 数据线 variableName
    AssertTrue(NP.ParseSetEntry(MakeCtx(tid, card, vars, dcs),
        MakeEntry("n", "占位名", 1, 4, { source = "input", connId = "dc1" })), "数据线：connId 匹配 → 返回 true")
    AssertEqual(V.Get(tid).Battle[V_BOARD], 4, "数据线：写入数据线携带的变量名「全局面板」= 4")

    -- connId 不匹配 → 保留条目 varName（未定义 → 失败）
    AssertEqual(NP.ParseSetEntry(MakeCtx(tid, card, vars, dcs),
        MakeEntry("n", "占位名", 1, 1, { source = "input", connId = "dc99" })), false,
        "数据线：connId 不匹配且条目名未定义 → false")
end

-- ====================================================================
-- 场景 8：非法 / 边界输入
-- ====================================================================
local function RunInvalidInputTest()
    local tid = "np_inv"
    NewTable(tid)
    local vars = MakeVariables()
    local card = KARDS.CardInterface.CreateMockCard("invcard", "unit", "P1", {})

    -- 空 _setEntries
    AssertEqual(NP.ParseSetVariable(MakeCtx(tid, card, vars),
        { type = "var_set", data = { _setEntries = {} } }), false, "空 _setEntries → false")

    -- 非法类型
    AssertEqual(NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("x", "攻击加成", 1, 1)), false,
        "非法目标类型 x → false")

    -- 空目标名
    AssertEqual(NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "", 1, 1)), false,
        "空目标名 → false")

    -- 函数占位（f 未接入子编辑器）
    AssertEqual(NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("f", "占位函数", 1, nil)), false,
        "函数 f 占位 → false（跳过）")

    -- 数组非法索引（0）
    AssertEqual(NP.ParseSetEntry(MakeCtx(tid, card, vars),
        MakeEntry("g", "友方队列", 2, 5, { subOpIdx = 1, itemType = "n", itemIndex = 0 })), false,
        "数组 第0项 → false")

    -- 非法数字值 → 0 兜底
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "攻击加成", 1, "abc"))
    AssertEqual(GetCardVar(tid, card, V_ATK), 0, "非法数字 'abc' → 按 0 写入")

    -- 数字引用不存在的变量 → 0 兜底
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "攻击加成", 1, "var:不存在的变量"))
    AssertEqual(GetCardVar(tid, card, V_ATK), 0, "引用不存在变量 → 按 0 写入")
end

-- ====================================================================
-- 场景 9：解析器入口（ParseSetVariable 多条目）
-- ====================================================================
local function RunEntryPointTest()
    local tid = "np_ep"
    NewTable(tid)
    local vars = MakeVariables()
    local card = KARDS.CardInterface.CreateMockCard("epcard", "unit", "P1", {})
    local node = {
        type = "var_set",
        data = {
            _setEntries = {
                MakeEntry("n", "攻击加成", 1, 5),
                MakeEntry("n", "全局面板", 1, 3),
            },
        },
    }
    AssertTrue(NP.ParseSetVariable(MakeCtx(tid, card, vars), node), "入口：多条目节点至少成功一条 → true")
    AssertEqual(GetCardVar(tid, card, V_ATK), 5, "入口：数字条目1 生效（攻击加成=5）")
    AssertEqual(V.Get(tid).Battle[V_BOARD], 3, "入口：数字条目2 生效（全局面板=3）")
    AssertEqual(KARDS.TickLog:Count(tid), 2, "入口：两条写入各记录一条 stat_change 刻")
end

-- ====================================================================
-- 场景 10：判断变量关系（var_evaluate）— 数值比较
-- ====================================================================
local function RunEvaluateTest()
    local tid = "np_eval"
    NewTable(tid)
    local vars = MakeVariables()
    local card = KARDS.CardInterface.CreateMockCard("ecard", "unit", "P1", {})

    -- 预置变量：攻击加成 = 5（global）、全局面板 = 8（longterm）
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "攻击加成", 1, 5))
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "全局面板", 1, 8))

    -- 构造判断节点辅助
    -- MakeCond(left, op, literal)：left = { source, varName, dataType?, connId? }（测试版仅 n + literal 右值）
    local function MakeCond(left, op, literal)
        return {
            left = {
                source = left.source or "global",
                varName = left.varName or "",
                dataType = left.dataType or "n",
                connId = left.connId,
            },
            operator = op,
            right = { mode = "literal", varName = "", dataType = "", literal = literal },
        }
    end
    local function MakeEvalNode(conds, conns)
        return { type = "var_evaluate", data = { _conditions = conds, _connectors = conns or {} } }
    end
    local ctx = MakeCtx(tid, card, vars)
    local G = function(varName) return { source = "global", varName = varName } end

    -- 1. 单条件各运算符（左值恒 5）
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "=", 5) })), true, "评估 =：5 = 5 → true")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "=", 6) })), false, "评估 =：5 = 6 → false")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "≠", 6) })), true, "评估 ≠：5 ≠ 6 → true")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "≠", 5) })), false, "评估 ≠：5 ≠ 5 → false")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), ">", 4) })), true, "评估 >：5 > 4 → true")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), ">", 5) })), false, "评估 >：5 > 5 → false")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "<", 6) })), true, "评估 <：5 < 6 → true")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "<", 5) })), false, "评估 <：5 < 5 → false")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "≥", 5) })), true, "评估 ≥：5 ≥ 5 → true")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "≥", 6) })), false, "评估 ≥：5 ≥ 6 → false")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "≤", 5) })), true, "评估 ≤：5 ≤ 5 → true")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "≤", 4) })), false, "评估 ≤：5 ≤ 4 → false")

    -- 2. 右值 "var:<名>" 引用：攻击加成(5) = 全局面板(8) → false
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "=", "var:全局面板") })), false,
        "评估 右值引用：5 = var:全局面板(8) → false")

    -- 3. 左操作数数据线输入（connId 匹配 → 取数据线 variableName）
    local dcs = { { id = "dcE", variableName = "攻击加成" } }
    local inputLeft = { source = "input", connId = "dcE", varName = "" }
    AssertEqual(NP.ParseEvaluateVariable(MakeCtx(tid, card, vars, dcs),
        MakeEvalNode({ MakeCond(inputLeft, "=", 5) })), true, "评估 数据线输入：dc variableName=攻击加成 = 5 → true")
    -- connId 不匹配 → 左侧未解析为 0 → 0 = 5 false
    AssertEqual(NP.ParseEvaluateVariable(MakeCtx(tid, card, vars, dcs),
        MakeEvalNode({ MakeCond({ source = "input", connId = "dcX", varName = "" }, "=", 0) })), true,
        "评估 数据线 connId 不匹配：左值按 0，0 = 0 → true")

    -- 4. 多条件 AND / OR 组合
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode(
        { MakeCond(G("攻击加成"), ">", 3), MakeCond(G("攻击加成"), "<", 10) }, { "AND" })), true,
        "评估 AND：5>3 AND 5<10 → true")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode(
        { MakeCond(G("攻击加成"), ">", 3), MakeCond(G("攻击加成"), "<", 4) }, { "AND" })), false,
        "评估 AND：5>3 AND 5<4 → false")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode(
        { MakeCond(G("攻击加成"), ">", 10), MakeCond(G("攻击加成"), "<", 4) }, { "OR" })), false,
        "评估 OR：5>10 OR 5<4 → false")

    -- 5. 连接符左结合：(c1 AND c2) OR c3 = true AND false OR true
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode(
        { MakeCond(G("攻击加成"), "=", 5), MakeCond(G("攻击加成"), ">", 100), MakeCond(G("攻击加成"), "<", 6) },
        { "AND", "OR" })), true, "评估 左结合：true AND false OR true → (false) OR true → true")

    -- 6. 判断不产生 stat_change 刻（预置 2 条后保持不变）
    AssertEqual(KARDS.TickLog:Count(tid), 2, "评估：判断不记录 stat_change 刻（保持 2）")

    -- 7. 边界：左操作数非数字 / 无条件行 / 未知运算符
    local bCond = MakeCond(G("攻击加成"), "=", 5)
    bCond.left.dataType = "b"
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ bCond })), false, "评估 左类型 b（测试版仅数值）→ false")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({})), false, "评估 无条件行 → false")
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond(G("攻击加成"), "><", 5) })), false,
        "评估 未知运算符 → false")
    -- 左侧未选择变量 → 按 0，0 = 0 true
    AssertEqual(NP.ParseEvaluateVariable(ctx, MakeEvalNode({ MakeCond({ source = "global", varName = "" }, "=", 0) })), true,
        "评估 左侧未选择 → 左值按 0，0 = 0 → true")
end

-- ====================================================================
-- 场景 11：base 通用解析器（base 型模板节点：action 等）
-- ====================================================================
local function RunBaseTest()
    -- 1. 简单结构：前缀 + select + number + funcslot + 输出后缀
    local s1 = NP.ParseBaseStructure("n{3}[0]#(nOut)")
    AssertEqual(s1.inputTypes[1], "n", "base 前缀：inputTypes[1] == n")
    AssertEqual(s1.components[1].type, "select", "base 组件1：select")
    AssertEqual(s1.components[1].id, "select_1", "base select id：select_1")
    AssertEqual(s1.components[1].optionsCount, 3, "base select：optionsCount=3")
    AssertEqual(s1.components[2].type, "number", "base 组件2：number")
    AssertEqual(s1.components[2].optionsCount, 0, "base number：[0] 空槽 optionsCount=0")
    AssertEqual(s1.components[3].type, "funcslot", "base 组件3：funcslot")
    AssertEqual(s1.outputTypes[1].type, "n", "base 输出类型：n")
    AssertEqual(s1.outputTypes[1].name, "Out", "base 输出名：Out")

    -- 2. 变量库数字槽 [lib] / [lib+2]
    local s2 = NP.ParseBaseStructure("e[lib][lib+2]")
    AssertEqual(s2.components[1].useLib, true, "base [lib]：useLib=true")
    AssertEqual(s2.components[1].optionsCount, 0, "base [lib]：optionsCount=0")
    AssertEqual(s2.components[2].useLib, true, "base [lib+2]：useLib=true")
    AssertEqual(s2.components[2].extraCount, 2, "base [lib+2]：extraCount=2")

    -- 3. action 真实 base：if 嵌套 + 分支绑定
    local actBase = "e{1}{3} if 1 then {17} if 2 then {1} end if 3 then {1} end if 4 then end if 5 then [0] end if 6 then {1}{1} end if 7 then end if 8 then {1}{2} end elseif 9 then {4} elseif 10 then end"
    local s3 = NP.ParseBaseStructure(actBase)
    AssertEqual(s3.inputTypes[1], "e", "action base 前缀：e")
    AssertEqual(#s3.outputTypes, 0, "action base 无输出后缀")
    AssertEqual(#s3.components, 3, "action base 顶层组件数：3（select,select,if）")
    AssertEqual(s3.components[1].id, "select_1", "action base select_1（对象槽）")
    AssertEqual(s3.components[2].optionsCount, 3, "action base select_2 {3}（获得/取消/被消灭）")
    AssertEqual(s3.components[3].type, "if", "action base 组件3：if")
    AssertEqual(s3.components[3].id, "if_1", "action base 顶层 if 为 if_1")
    AssertEqual(s3.components[3].boundSelectId, "select_2", "action base if_1 绑定 select_2")
    AssertEqual(#s3.components[3].branches, 3, "action base if_1 三个分支（if/elseif/elseif）")
    local b1 = s3.components[3].branches[1]
    AssertEqual(b1.index, 1, "action base 分支1 index=1")
    AssertEqual(b1.components[1].type, "select", "action base 分支1 组件1：select")
    AssertEqual(b1.components[1].id, "select_3", "action base 分支1 select_3")
    AssertEqual(b1.components[1].optionsCount, 17, "action base 分支1 {17} 选项数")
    AssertEqual(b1.components[2].type, "if", "action base 分支1 组件2：if")
    AssertEqual(b1.components[2].id, "if_2", "action base if_2（嵌套）")
    AssertEqual(b1.components[2].boundSelectId, "select_3", "action base if_2 绑定 select_3")
    AssertEqual(#b1.components[2].branches, 1, "action base if_2 单分支")
    AssertEqual(b1.components[2].branches[1].components[1].id, "select_4", "action base if_2 分支内 select_4")
    -- if_5 内 [0] 数字槽（分支1 组件顺序：select_3、if_2、if_3、if_4、if_5、if_6、if_7、if_8）
    local if5 = b1.components[5]
    AssertEqual(if5.id, "if_5", "action base 分支1 第5组件 if_5")
    AssertEqual(if5.branches[1].components[1].type, "number", "action base if_5 内 number")
    AssertEqual(if5.branches[1].components[1].optionsCount, 0, "action base if_5 内 [0]")
    -- elseif 9 / elseif 10 分支
    local b9 = s3.components[3].branches[2]
    AssertEqual(b9.index, 9, "action base 分支2（elseif 9）")
    AssertEqual(b9.components[1].id, "select_10", "action base elseif 9 内 select_10")
    AssertEqual(b9.components[1].optionsCount, 4, "action base elseif 9 内 {4}")
    local b10 = s3.components[3].branches[3]
    AssertEqual(b10.index, 10, "action base 分支3（elseif 10）")
    AssertEqual(#b10.components, 0, "action base elseif 10 内无组件")

    -- 4. 数据填充：select 索引 / number 值 / funcslot 函数名
    local nodeA = {
        base = "n{3}[2][lib]#(nOut)",
        data = {
            select_1 = 2,
            number_1 = 7,
            number_2 = "var:攻击加成",
            funcslot_1 = "custom_effect",
        },
    }
    local t = NP.ParseBaseNode(MakeCtx("np_base", nil, nil), nodeA)
    AssertEqual(t.inputTypes[1], "n", "base 节点：inputTypes")
    AssertEqual(t.components[1].selected, 2, "base 节点：select 选中索引 2")
    AssertEqual(t.components[2].value, 7, "base 节点：number 值 7")
    AssertEqual(t.components[3].value, "var:攻击加成", "base 节点：[lib] number 变量引用")
    AssertEqual(t.components[4].funcName, "custom_effect", "base 节点：funcslot 函数名")
    AssertEqual(t.outputTypes[1].type, "n", "base 节点：输出类型 n")
    AssertEqual(t.outputTypes[1].name, "Out", "base 节点：输出名 Out")

    -- 5. 槽值回退：dropdowns.selectedIndex → data[compId]
    local nodeB = { base = "e{2}", data = { dropdowns = { select_1 = { selectedIndex = 2 } } } }
    local tb = NP.ParseBaseNode(nil, nodeB)
    AssertEqual(tb.components[1].selected, 2, "base 节点：dropdowns.selectedIndex 回退")

    -- 6. 统一槽 slots 优先（覆盖 data[compId]）
    local nodeC = { base = "n[0]", data = { slots = { number_1 = { mode = "variable", variableRef = "var:全局面板" } } } }
    local tc = NP.ParseBaseNode(nil, nodeC)
    AssertEqual(tc.components[1].value, "var:全局面板", "base 节点：slots 统一槽优先")

    -- 7. 边界：空 base / 无 base / 多输出
    local se = NP.ParseBaseStructure("")
    AssertEqual(#se.components, 0, "base 空串：无组件")
    AssertEqual(NP.ParseBaseNode(nil, {}), nil, "base 节点无 base → nil")
    local sm = NP.ParseBaseStructure("e{1}(nResult、tName)")
    AssertEqual(#sm.outputTypes, 2, "base 多输出：2 个")
    AssertEqual(sm.outputTypes[2].type, "t", "base 多输出：第二个 t")
    AssertEqual(sm.outputTypes[2].name, "Name", "base 多输出：第二个名 Name")
end

-- ====================================================================
-- 场景 12：card 模板 base 解析（else 分支 / 嵌套 if / 中文输出名；H5 开发分支 {$}）
-- ====================================================================
local function RunCardBaseTest()
    local base = "e{2}{8} if 1 then [lib]{4} if 2 then {1} else {4} end elseif 4 then [lib]{4} if 5 then else end elseif 7 then [lib]{5} if 8 then {2} if 9 then [lib] end else end elseif 11 then [lib]{1} elseif 12 then [lib] elseif 13 then [lib] elseif 14 then {4} if 15 then {2}[lib] elseif 16 then {1}[lib] elseif 17 then {1}[lib] else {2}[lib] end end(e影响的卡牌)"
    local s = NP.ParseBaseStructure(base)

    -- 前缀 / 输出后缀（中文名）
    AssertEqual(s.inputTypes[1], "e", "card base 前缀：e")
    AssertEqual(#s.outputTypes, 1, "card base 输出：1 个")
    AssertEqual(s.outputTypes[1].type, "e", "card base 输出类型：e")
    AssertEqual(s.outputTypes[1].name, "影响的卡牌", "card base 输出名：影响的卡牌")

    -- 顶层结构
    AssertEqual(#s.components, 3, "card base 顶层组件数：3（select,select,if）")
    AssertEqual(s.components[1].id, "select_1", "card base select_1（{2} 友方/敌方）")
    AssertEqual(s.components[1].optionsCount, 2, "card base select_1 选项数 2")
    AssertEqual(s.components[2].id, "select_2", "card base select_2（{8} 抽取/复制/…）")
    AssertEqual(s.components[2].optionsCount, 8, "card base select_2 选项数 8")
    AssertEqual(s.components[3].type, "if", "card base 组件3：if")
    AssertEqual(s.components[3].id, "if_1", "card base if_1")
    AssertEqual(s.components[3].boundSelectId, "select_2", "card base if_1 绑定 select_2")
    AssertEqual(#s.components[3].branches, 7, "card base if_1 七个分支")

    -- 分支1（抽取）：[lib]{4} + if_2（含 else 分支）
    local b1 = s.components[3].branches[1]
    AssertEqual(b1.index, 1, "card base 分支1 index=1（抽取）")
    AssertEqual(b1.components[1].id, "number_1", "card base 分支1 number_1（张数）")
    AssertEqual(b1.components[2].id, "select_3", "card base 分支1 select_3（{4} 卡组顶/底/随机/指定）")
    local if2 = b1.components[3]
    AssertEqual(if2.id, "if_2", "card base if_2（嵌套）")
    AssertEqual(if2.boundSelectId, "select_3", "card base if_2 绑定 select_3")
    AssertEqual(#if2.branches, 2, "card base if_2 两个分支（if/else）")
    AssertEqual(if2.branches[1].index, 2, "card base if_2 分支1 index=2")
    AssertEqual(if2.branches[1].components[1].id, "select_4", "card base if_2 分支1 select_4（{$} 指定）")
    AssertEqual(if2.branches[2]["else"], true, "card base if_2 分支2 else")
    AssertEqual(if2.branches[2].components[1].id, "select_5", "card base if_2 else 分支 select_5（类型卡牌）")

    -- 分支2（复制，elseif 4）：[lib]{4} + if_3（空分支 + 空 else）
    local b2 = s.components[3].branches[2]
    AssertEqual(b2.index, 4, "card base 分支2 index=4（复制）")
    AssertEqual(b2.components[1].id, "number_2", "card base 分支2 number_2（张数）")
    AssertEqual(b2.components[2].id, "select_6", "card base 分支2 select_6（{4} 卡组顶/底/随机/指定）")
    local if3 = b2.components[3]
    AssertEqual(if3.id, "if_3", "card base if_3")
    AssertEqual(if3.boundSelectId, "select_6", "card base if_3 绑定 select_6")
    AssertEqual(#if3.branches, 2, "card base if_3 两分支（if 5 空 + else 空）")
    AssertEqual(#if3.branches[1].components, 0, "card base if_3 分支1 空")
    AssertEqual(if3.branches[2]["else"], true, "card base if_3 分支2 else 空")

    -- 分支3（弃掉，elseif 7）：[lib]{5} + if_4
    --   if 8（手中）→ {2} + if_5（if 9 第 → [lib]）；else 空
    local b3 = s.components[3].branches[3]
    AssertEqual(b3.index, 7, "card base 分支3 index=7（弃掉）")
    AssertEqual(b3.components[1].id, "number_3", "card base 分支3 number_3（数量）")
    AssertEqual(b3.components[2].id, "select_7", "card base 分支3 select_7（{5} 手中/卡组顶/底/随机/指定）")
    AssertEqual(b3.components[2].optionsCount, 5, "card base 分支3 select_7 选项数 5")
    local if4 = b3.components[3]
    AssertEqual(if4.id, "if_4", "card base if_4")
    AssertEqual(if4.boundSelectId, "select_7", "card base if_4 绑定 select_7")
    AssertEqual(#if4.branches, 2, "card base if_4 两分支（if 8 手中 + else 空）")
    AssertEqual(if4.branches[1].index, 8, "card base if_4 分支1 index=8（手中）")
    AssertEqual(if4.branches[1].components[1].id, "select_8", "card base if_4 分支1 select_8（{2} 自选的一张卡/第）")
    AssertEqual(if4.branches[1].components[1].optionsCount, 2, "card base if_4 分支1 select_8 选项数 2")
    local if5 = if4.branches[1].components[2]
    AssertEqual(if5.id, "if_5", "card base if_5（弃掉·手中 二级）")
    AssertEqual(if5.boundSelectId, "select_8", "card base if_5 绑定 select_8")
    AssertEqual(#if5.branches, 1, "card base if_5 一分支（if 9 第）")
    AssertEqual(if5.branches[1].index, 9, "card base if_5 分支1 index=9（第）")
    AssertEqual(if5.branches[1].components[1].id, "number_4", "card base if_5 分支1 number_4（第 [lib] 张）")
    AssertEqual(if4.branches[2]["else"], true, "card base if_4 分支2 else 空")

    -- 分支4（开发，elseif 11）：[lib]{1}（次数 number_5 + {$} 开发池 select_9）
    local b4 = s.components[3].branches[4]
    AssertEqual(b4.index, 11, "card base 分支4 index=11（开发）")
    AssertEqual(#b4.components, 2, "card base 分支4 两组件（次数 + 开发池）")
    AssertEqual(b4.components[1].id, "number_5", "card base 分支4 number_5（次数）")
    AssertEqual(b4.components[2].id, "select_9", "card base 分支4 select_9（{$} 开发池）")
    AssertEqual(b4.components[2].optionsCount, 1, "card base 分支4 select_9 选项数 1（{$}）")

    -- 分支5（选择/观星，elseif 12）：[lib]
    local b5 = s.components[3].branches[5]
    AssertEqual(b5.index, 12, "card base 分支5 index=12（选择）")
    AssertEqual(b5.components[1].id, "number_6", "card base 分支5 number_6（次数）")

    -- 分支6（爆牌，elseif 13）：[lib]
    local b6 = s.components[3].branches[6]
    AssertEqual(b6.index, 13, "card base 分支6 index=13（爆牌）")
    AssertEqual(b6.components[1].id, "number_7", "card base 分支6 number_7（次数）")

    -- 分支7（洗入，elseif 14）：{4} + if_6（四分支，四来源：手牌中/凭空生成/对象组/else 指定的）
    local b7 = s.components[3].branches[7]
    AssertEqual(b7.index, 14, "card base 分支7 index=14（洗入）")
    AssertEqual(b7.components[1].id, "select_10", "card base 分支7 select_10（{4} 手牌中/指定的/凭空生成/对象组）")
    AssertEqual(b7.components[1].optionsCount, 4, "card base 分支7 select_10 选项数 4")
    local if6 = b7.components[2]
    AssertEqual(if6.id, "if_6", "card base if_6")
    AssertEqual(if6.boundSelectId, "select_10", "card base if_6 绑定 select_10")
    AssertEqual(#if6.branches, 4, "card base if_6 四分支（手牌中/凭空生成/对象组/else 指定的）")
    AssertEqual(if6.branches[1].components[1].id, "select_11", "card base if_6 分支1 select_11（{2} 随机/指定）")
    AssertEqual(if6.branches[1].components[2].id, "number_8", "card base if_6 分支1 number_8（张数）")
    AssertEqual(if6.branches[2].index, 16, "card base if_6 分支2 index=16（凭空生成）")
    AssertEqual(if6.branches[2].components[1].id, "select_12", "card base if_6 分支2 select_12（{$} 开发池）")
    AssertEqual(if6.branches[2].components[1].optionsCount, 1, "card base if_6 分支2 select_12 选项数 1")
    AssertEqual(if6.branches[2].components[2].id, "number_9", "card base if_6 分支2 number_9（生成张数）")
    AssertEqual(if6.branches[3].index, 17, "card base if_6 分支3 index=17（对象组）")
    AssertEqual(if6.branches[3].components[1].id, "select_13", "card base if_6 分支3 select_13（{$} 对象组变量）")
    AssertEqual(if6.branches[3].components[2].id, "number_10", "card base if_6 分支3 number_10（张数）")
    AssertEqual(if6.branches[4]["else"], true, "card base if_6 分支4 else（指定的）")
    AssertEqual(if6.branches[4].components[1].id, "select_14", "card base if_6 else 分支 select_14（{2} 手牌/场上）")
    AssertEqual(if6.branches[4].components[1].optionsCount, 2, "card base if_6 else 分支 select_14 选项数 2")
    AssertEqual(if6.branches[4].components[2].id, "number_11", "card base if_6 else 分支 number_11（指定张数）")
end

-- ====================================================================
-- 场景 13：事实变量一回合覆盖（设置变量改写 Battle.* / Special.* 的回合内语义）
-- ====================================================================
local function RunFactOverrideTest()
    local tid = "np_fact"
    local T = NewTable(tid)
    local vars = MakeVariables()
    local card = KARDS.CardInterface.CreateMockCard("factcard", "unit", "P1", {})

    -- 统计已登记覆盖条数（用于确认用户自定义变量写入不登记覆盖）
    local function CountOverrides()
        local n = 0
        for _ in pairs(V.Get(tid).FactOverrides or {}) do n = n + 1 end
        return n
    end

    -- 1. IsFactPath 判定
    AssertTrue(V.IsFactPath("Battle.Turn"), "事实路径：Battle.Turn → true")
    AssertTrue(V.IsFactPath("Special.Veteran.HasFriendlyUnit"), "事实路径：Special.Veteran.HasFriendlyUnit → true")
    AssertEqual(V.IsFactPath("KARDS.User.X"), false, "事实路径：KARDS.User.X → false")
    AssertEqual(V.IsFactPath("CardVars.X"), false, "事实路径：CardVars.X → false")
    AssertEqual(V.IsFactPath(nil), false, "事实路径：nil → false")
    AssertEqual(V.IsFactPath(123), false, "事实路径：非字符串 123 → false")

    -- 2. 登记覆盖：首次快照被保留，同回合重复写只记首次旧值
    T.Battle.Turn = 3
    V.SetFactOverride(tid, "Battle.Turn", T.Battle.Turn)
    AssertTrue(V.IsFactOverridden(tid, "Battle.Turn"), "登记覆盖：IsFactOverridden(Battle.Turn) → true")
    V.SetFactOverride(tid, "Battle.Turn", 99) -- 第二次传入 99，首次快照 3 不应被覆盖

    -- 3. SetFact 在已覆盖时让位：返回 false 且不改变当前值
    T.Battle.Turn = 7 -- 模拟「设置变量」写入后的当前值
    AssertEqual(V.SetFact(tid, "Battle.Turn", 55), false, "事实写入：已覆盖 → SetFact 返回 false")
    AssertEqual(T.Battle.Turn, 7, "事实写入：已覆盖 → 当前值保持 7 不变")

    -- 4. 回合边界还原：按首次快照（3，而非 99）写回并清空登记
    V.ClearFactOverrides(tid)
    AssertEqual(T.Battle.Turn, 3, "回合边界：ClearFactOverrides 还原首次快照值 3")
    AssertEqual(V.IsFactOverridden(tid, "Battle.Turn"), false, "回合边界：IsFactOverridden → false")

    -- 5. 清覆盖后 SetFact 恢复写入能力
    AssertTrue(V.SetFact(tid, "Battle.Turn", 8), "清覆盖后：SetFact 返回 true")
    AssertEqual(T.Battle.Turn, 8, "清覆盖后：SetFact 写入 8")

    -- 6. 未被改写的路径不受 ClearFactOverrides 影响
    T.Battle.SomeUntouched = "keep"
    T.Special.Veteran.HasFriendlyUnit = true
    V.ClearFactOverrides(tid)
    AssertEqual(T.Battle.SomeUntouched, "keep", "未改写路径：ClearFactOverrides 后保持 keep")
    AssertEqual(T.Special.Veteran.HasFriendlyUnit, true, "未改写事实：ClearFactOverrides 后保持 true")

    -- 7. 覆盖前键不存在（hasPrev=false）：还原为 nil（键移除）
    local spVet = T.Special.Veteran
    spVet.HasFriendlyUnit = nil
    V.SetFactOverride(tid, "Special.Veteran.HasFriendlyUnit", nil)
    spVet.HasFriendlyUnit = true
    V.ClearFactOverrides(tid)
    AssertEqual(spVet.HasFriendlyUnit, nil, "覆盖前不存在：ClearFactOverrides 还原为 nil 键移除")

    -- 8. 用户自定义变量（isUser 分支）写入不登记覆盖
    local before = CountOverrides()
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "攻击加成", 1, 5))   -- 全局 → CardVars
    NP.ParseSetEntry(MakeCtx(tid, card, vars), MakeEntry("n", "全局面板", 1, 3))   -- 长期 → Battle
    AssertEqual(V.IsFactOverridden(tid, V_ATK), false, "用户变量：全局 KARDS.User.ATK_BONUS 不登记覆盖")
    AssertEqual(V.IsFactOverridden(tid, V_BOARD), false, "用户变量：长期 KARDS.User.BOARD 不登记覆盖")
    AssertEqual(CountOverrides(), before, "用户变量：写入后覆盖登记条数不变")

    -- 9. 解析器节点入口写入事实变量：写入生效且登记覆盖，回合边界还原
    local turnBefore = V.Get(tid).Battle.Turn
    local spBefore = V.Get(tid).Special.Veteran.HasFriendlyUnit
    local factNode = {
        type = "var_set",
        data = {
            _setEntries = {
                MakeEntry("n", "回合数", 1, 4),
                MakeEntry("b", "友方有老兵单位", 1, "true"),
            },
        },
    }
    AssertTrue(NP.ParseSetVariable(MakeCtx(tid, card, vars), factNode),
        "解析器：事实写入节点至少成功一条 → true")
    AssertEqual(V.Get(tid).Battle.Turn, 4, "解析器：Battle.Turn 写入生效 == 4")
    AssertEqual(V.Get(tid).Special.Veteran.HasFriendlyUnit, true, "解析器：Special.Veteran.HasFriendlyUnit 写入 true")
    AssertTrue(V.IsFactOverridden(tid, "Battle.Turn"), "解析器：写入 Battle 事实登记覆盖 → true")
    AssertTrue(V.IsFactOverridden(tid, "Special.Veteran.HasFriendlyUnit"),
        "解析器：写入 Special 事实登记覆盖 → true")

    V.ClearFactOverrides(tid)
    AssertEqual(V.Get(tid).Battle.Turn, turnBefore, "解析器：回合边界还原 Battle.Turn 为写入前的值")
    AssertEqual(V.Get(tid).Special.Veteran.HasFriendlyUnit, spBefore,
        "解析器：回合边界还原 Special 事实为写入前的值")
    AssertEqual(CountOverrides(), 0, "解析器：回合边界清空全部覆盖登记")
end

-- ====================================================================
-- 运行全部测试（GMod 控制台 kards_node_test 或外部 Lua 直接调用）
-- ====================================================================
function RunNodeParserTests()
    print("==============================================")
    print("KARDS 节点解析器测试开始（按节点类型分割场景）")
    print("==============================================")
    TestsPassed, TestsFailed = 0, 0
    FailedTests = {}
    RunSetNumberTest()
    RunSetBoolTest()
    RunSetTextTest()
    RunSetArrayTest()
    RunSetObjectTest()
    RunSetScopeTest()
    RunSetDataConnectionTest()
    RunInvalidInputTest()
    RunEntryPointTest()
    RunEvaluateTest()
    RunBaseTest()
    RunCardBaseTest()
    RunFactOverrideTest()
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

-- GMod 控制台命令：kards_node_test（仅服务端注册；玩家执行需 operator 及以上，服务器控制台放行）
if SERVER and concommand then
    concommand.Add("kards_node_test", function(ply)
        if not KARDS.CanUseDevCommand(ply) then
            print("[Kards] kards_node_test：需要 operator 及以上权限")
            return
        end
        RunNodeParserTests()
    end)
end
