--[[
    战斗骨架测试脚本 (Tick Log / Engine Hooks / Battle Stub)

    在 GMod 控制台执行 kards_test 运行全部测试（服务端）。
    测试数据层不依赖真实牌桌 / 卡组 / 手牌系统，全部使用 MockCard。

    覆盖场景：
      1. 刻度条目格式（攻击造成 3 伤害，操作文本 "-3"；操作类型为数组）
         - 场景 1b：玩家资源变化（一次抽牌 = 一刻，第三部分记录手牌 delta，非法资源类型/操作文本拒绝）
      2. 爆牌同对象（发起者 = 受影响 = 同一张牌，无数值操作省略字段）
      3. 钩子反制（用户示例：卡牌 x 攻击 6 防御 3）
         - "before" 生效前：反制先击杀 x（3-3=0），指令失效
         - "after"  生效后：x 先变 7:4，反制不击杀（4-3=1）
      4. 多牌桌时间刻隔离（T1/T2 各自计数独立）+ _G 全局视图（KARDS_TickLog/
         KARDS_TickCount/KARDS_TickTiming 动态指向当前激活牌桌）
      5. 战场布局（自动居中 + 受限选位，2026-08-05 修订）
         - 三个数组固定 SLOT_COUNT（5）槽，默认全 nil；总部参与居中（不再恒驻槽 3），防御 20，不可移动/移除/消灭
         - 任一阵线布局变化后自动居中：奇数完美居中 / 偶数居中靠左（GetCenteredStart 公式，按 SLOT_COUNT 计算）
         - 同一阵线卡牌间距 = 1（SPACING）；时间刻结束后偶数阵线全卡 0.3s 线性右移 0.5*SPACING（sh_battlefield_center.lua）
         - 部署受限选位：点击目标左/右侧、可从两目标之间插入、无相邻目标自动靠最近目标（不阻止）
         - 加入战场自动首个空槽 / 被消灭·被移除清槽；跨数组移动：移到前线、撤退（目标槽位缺省自动首个空槽）
         - 前线同阵营约束：他方进入已控制前线 → 作弊 → 对局立即停止
         - 容量：支援阵线 4 单位 + 总部 = 5 槽；前线 5 槽
      6. 卡组 / 士气伤害 / 重新调度（sh_deck.lua，战斗系统规划.md 第 12 节）
         - 39 张构筑，对局开始洗牌一次，此后顺序固定（抽牌顺序 = 卡组数组顺序）
         - 抽空卡组后空抽 → 士气伤害（第一次 1，第二次 2），总部防御 20-1-2=17
         - 起手：先手 4 手牌 / 后手 5 手牌；重新调度弃牌随机插入卡组 + 补抽等量
         - 重新调度仅一次机会；丢弃不在手牌的牌被拒绝
      7. 交战 / 战斗 / 单位类型（readme 7.1 / 7.3，战斗系统规划.md 第 13 节）
         - 卡牌类型：unit/headquarter/command/counter_command；单位类型：为单位卡时
           fighter/tank/bomber/infantry/artillery，非单位卡恒为 nil
         - 交战刻：发起者 {engage, attack, deal_damage}，受影响 {engage, take_damage, counterattack}；
           发起者第三字段 = 被反击数值（操作类型为数组，一刻一张卡多个操作类型）
         - 单位类型规则在交战时生效：炮兵攻击无反伤（发起者无操作字段）
         - 战斗刻：发起者 {fight, attack, deal_damage}，受影响 {fight, take_damage, counterattack}
         - 单位类型规则在战斗时失效：炮兵也受战斗伤害（互扣等同对方攻击的防御）
      8. 指挥点 / 卡牌花费 / 行动花费（readme 7.1，战斗系统规划.md 第 14 节）
         - 卡牌对象：卡牌花费 cost（所有卡牌类型，缺省 0）；行动花费 actionCost（仅单位，非单位 nil）
         - 开局（开场动画 / 重新调度期间）：双方 0 指挥点槽（点数 0）
         - 先手首回合：初始补给 +1 槽（点数补满 1）→ 回合开始 +1 槽（点数 2，与槽相等）；
           记录 turn_begin 刻
         - 自然上限 12：回合开始 +1 槽（上限 12）；绝对上限 24：效果扩展可突破 12，封顶 24
         - 支付/检查：足够扣减、不足拒绝不扣；打出/部署扣卡牌花费，攻击/移动扣行动花费
      12. 词条效果与限制（readme 7.2.1 效果能力 / 7.2.2 战斗词条能力；亡计除外——倒计时：每回合结束后 -1，归零触发并移除）
         - 被守护 guarded：只能被轰炸机和炮兵攻击
         - 守护 guard：与守护单位相邻的非守护单位仅轰炸机/炮兵可攻击，守护单位本身可被攻击
         - 烟幕 smoke：无法被敌方单位攻击；攻击或移动后失去（SmokeBroken）
         - 隐蔽 stealth：部署时背面朝上（Hidden），揭示前不受指令影响、行动花费 1；发起/被攻击后揭示（reveal 刻）
         - 免疫 immune：SimAttack / SimEngage / SimFight / SimDealDamage 伤害均为 0
         - 重甲 X armor：交战（SimEngage）伤害减免 X（上限 3；攻击伤害与反击伤害均减，readme 7.4 示例）
         - 冲击 shock：首次攻击被攻击单位不反击，攻击后移除（第二次攻击有反击；移除后伏击正常触发）
         - 伏击 ambush：每回合首次被攻击时首先反击（=本次反击权，替代普通反击，readme 7.4 示例）；
           击杀攻击者则攻击无效；冲击攻击不触发；每回合重置
         - 奋战 frenzy：一回合可攻击两次（普通单位一次，攻击次数每回合重置）
         - 动员 mobilize：回合开始 +1+1（stat_change 刻），受到伤害后失去（不再 +）
         - 山地 mountain：部署/加入时每有一个其他友方山地单位 +1+1（统计排除自身）
         - 情报 X intel：SimUseIntel 返回敌方手牌前 X 张（最多 9）；无情报返回 nil（intelligence 刻）
         - 抑制（SimInhibit）：失去所有关键词和效果（HasActiveKeyword 统一失效，neutralized 刻）
         - 被压制（SimSuppress）：不能移动或攻击；SimUnsuppress 解除后恢复（suppress/suppressed 刻）
         - 倒计时 X countdown：部署时记录初始值；每回合结束后 -1（countdown 刻），归零触发事件并移除（trigger/remove 刻）
     13. 7.4 Kards 标准战斗流程实战（readme 7.4 示例）
         - 四号坦克 vs 步兵班 + T-34：前线单一阵营占领 / 守护·被守护 / 冲击（压反击后移除）/
           重甲（攻击伤害与反击伤害均减）/ 奋战（一回合两攻）/ 伏击（=首先反击，替代普通反击）
     14. 卡牌变换动画（sh_animation.lua）
         - 预设 6 值 pose（位置 3 + 角度 3）副本隔离 / 6 值读写 / 非法轴拒绝
         - Animate：线性·平滑渐变到 / 增加·减少 / 超时 clamp / 参数校验 / AddEasing 曲线扩展
         - AnimateCard：指定一张卡或一方玩家摄像头的一个坐标或旋转值渐变
           （起始值缺省取对象当前值，Apply/ApplyAt 写回 pos/ang；卡牌与摄像头
           共用相对牌桌的世界坐标系）
         - 真实时间开关 RealTime：false 直接终值（测试环境）/ true 按 seconds
           时长真实渐变（ValueNow/ApplyNow 以 CurTime 插值）
     15. 自动居中序列 + 偶数偏移驱动（sh_battlefield_center.lua）
         - 居中序列：1→[3] / 2→[2,3] / 3→[2,3,4] / 4→[1,2,3,4] / 5→全满（总部参与居中计数）
         - 阵线变化后整线重新居中（移除 1 张：5 → 4 张居中靠左）
         - GetCenteredStart 自定义 lineSize（修改阵线最大值后公式自动生效）
         - 偶数偏移：时间刻结束后偶数阵线全卡 0.3s 线性右移 0.5*SPACING（OnTickEnd/GetShift/Reset）；
           奇数 / 空阵线不移；前线按 FrontlineOwner 独立判定
     16. 伤害倍率 / 受伤害倍率（combatModifiers，与卡牌外貌属性编辑器一致）
         - 单位卡可配置：outgoing 伤害倍率（攻击匹配 targetPath 目标时 ×N）/
           incoming 受伤害倍率（受到匹配 sourcePath 来源伤害时 ×N）
         - 倍率为 1 的规则不入数组（一般伤害/受伤为 1 倍率）；非单位卡（指令/反制/总部）两数组恒空
         - 伤害计算解析：查询未匹配返回默认 1 倍率；同路径规则覆盖更新（覆盖为 1 时移除该条）
     17. 移除动画（sh_animation.lua CreateRemovalAnimations，阵亡不触发移除）
         - 三段时间线：0.25s 线性升 z（pos.z +rise）→ 等待 0.5s → 1s 平滑同时
           左移到场外（pos.x → offscreenX）与 xy 平面逆时针旋转 180°（ang.r +180）
         - 阶段 3 经 delay=0.75 延迟开始（升 z 0.25s + 等待 0.5s）；本场景真实时间
           开关暂定 true，每 0.1s 采样打印处于渐变动画的卡牌当前渐变值
         - 阵亡 ≠ 移除：卡牌防御归 0（阵亡）不触发 Kards 语义的"移除"，仅"移除"操作时创建动画
]]

KARDS = KARDS or {}

local TestsPassed = 0
local TestsFailed = 0

local function AssertEqual(actual, expected, label)
    if actual == expected then
        TestsPassed = TestsPassed + 1
        print("[PASS] " .. label)
    else
        TestsFailed = TestsFailed + 1
        print("[FAIL] " .. label .. " | 期望=" .. tostring(expected) .. " 实际=" .. tostring(actual))
    end
end

-- 断言数值近似相等（容差 epsilon，缺省 1e-6）
-- 用于真实时间模拟的浮点采样断言：StartTime = CurTime() - t 大数减法存在 ULP 舍入误差，
-- 严格 == 会误报（如 8 与 8.0000000000018）
-- @param actual   number 实际值
-- @param expected number 期望值
-- @param epsilon  number|nil 容差（缺省 1e-6）
local function AssertNear(actual, expected, epsilon, label)
    epsilon = epsilon or 1e-6
    if math.abs(actual - expected) <= epsilon then
        TestsPassed = TestsPassed + 1
        print("[PASS] " .. label)
    else
        TestsFailed = TestsFailed + 1
        print("[FAIL] " .. label .. " | 期望=" .. tostring(expected) .. " 实际=" .. tostring(actual))
    end
end

-- 断言「操作类型数组」恰包含给定操作类型（顺序无关，数量一致）
-- 操作类型是数组：一刻的一张卡可有多个操作类型（战斗系统规划.md 第 3 节）
-- @param opTypes   table 实际的操作类型数组
-- @param ...       期望的操作类型（数量须与数组一致）
-- @return boolean
local function HasOpTypes(opTypes, ...)
    if type(opTypes) ~= "table" then return false end
    local expected = { ... }
    if #opTypes ~= #expected then return false end
    for _, want in ipairs(expected) do
        local found = false
        for _, got in ipairs(opTypes) do
            if got == want then found = true break end
        end
        if not found then return false end
    end
    return true
end

-- 场景 1：刻度条目格式（攻击 3 伤害）
local function RunFormatTest()
    print("--- 场景1: 刻度条目格式（攻击 3 伤害） ---")
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local a = KARDS.CardInterface.CreateMockCard("A", "unit", "P1", { attack = 3, defense = 2 })
    local b = KARDS.CardInterface.CreateMockCard("B", "unit", "P2", { attack = 1, defense = 4 })
    KARDS.Battle:SimAttack(a, b)

    AssertEqual(KARDS.TickLog:Count("1"), 1, "刻度数应为 1")
    local tick = KARDS.TickLog:GetTick("1", 1)
    -- 期望条目: {{A, {"attack"}}, {{B, {"take_damage"}, "-3"}}}
    AssertEqual(tick[1][1], a, "发起者应为 A")
    AssertEqual(HasOpTypes(tick[1][2], "attack"), true, "发起者操作类型应为 {attack}（数组）")
    AssertEqual(tick[2][1][1], b, "受影响卡牌应为 B")
    AssertEqual(HasOpTypes(tick[2][1][2], "take_damage"), true, "经受类型应为 {take_damage}（数组）")
    AssertEqual(tick[2][1][3], "-3", "操作文本应为 -3")
    AssertEqual(b:GetStat("defense"), 1, "B 防御应为 4-3=1")

    -- 场景 1b：玩家资源变化（一次抽牌操作 = 一刻，第三部分记录手牌 delta；H2 修复支撑）
    KARDS.Battle:StartBattle("1b", { "P1", "P2" }, "before")
    local pool1b = {}
    for i = 1, 5 do pool1b[i] = KARDS.CardInterface.CreateMockCard("R1_" .. i, "unit", "P1", {}) end
    KARDS.Battle:SimSetupDeck("P1", pool1b)
    KARDS.Battle:SimDraw("P1", 3) -- 抽 3 张：合并为 1 刻
    AssertEqual(KARDS.TickLog:Count("1b"), 1, "抽 3 张应合并为 1 刻（一次操作 = 一刻）")
    local tick1b = KARDS.TickLog:GetTick("1b", 1)
    AssertEqual(HasOpTypes(tick1b[1][2], "draw"), true, "发起者操作类型应为 {draw}（抽牌）")
    AssertEqual(#tick1b[2], 2, "受影响列表应含其余 2 张抽到的牌")
    local rc = KARDS.TickLog:GetResourceChanges(tick1b)
    AssertEqual(#rc, 1, "玩家资源变化应记录 1 项")
    AssertEqual(rc[1][1], "P1", "资源变化玩家应为 P1")
    AssertEqual(rc[1][2], "hand", "资源类型应为 hand")
    AssertEqual(rc[1][3], "+3", "手牌变化应为 +3")

    -- 资源变化校验：非法资源类型 / 非法操作文本应拒绝（append-only 防线）
    local unit1b = KARDS.CardInterface.CreateMockCard("R2_", "unit", "P1", {})
    AssertEqual(KARDS.TickLog:Push("1b", unit1b, "draw", {}, nil, { { "P1", "mana", "+1" } }), false, "非法资源类型应拒绝")
    AssertEqual(KARDS.TickLog:Push("1b", unit1b, "draw", {}, nil, { { "P1", "hand", "add" } }), false, "非法资源操作文本应拒绝")
end

-- 场景 2：爆牌同对象（发起者 = 受影响 = 同一张牌）
local function RunBurnTest()
    print("--- 场景2: 爆牌同对象 ---")
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local card = KARDS.CardInterface.CreateMockCard("card", "unit", "P1", { attack = 1, defense = 1 })
    -- 爆牌：发起者 = 该牌（draw），受影响 = 该牌（burn），无数值操作省略字段
    KARDS.TickLog:Push("1", card, "draw", { { card, "burn" } })

    local tick = KARDS.TickLog:GetTick("1", 1)
    AssertEqual(tick[1][1], card, "发起者应为该牌")
    AssertEqual(HasOpTypes(tick[1][2], "draw"), true, "发起者操作类型应为 {draw}（数组）")
    AssertEqual(tick[2][1][1], card, "受影响应为同一张牌")
    AssertEqual(HasOpTypes(tick[2][1][2], "burn"), true, "经受类型应为 {burn}（数组）")
    AssertEqual(tick[2][1][3], nil, "无数值操作应省略（burn 无 change）")
end

-- 场景 3：钩子反制（用户示例）
-- 友方回合注册反制钩子：敌方指令指向目标时，使该目标受到 3 伤害
-- 敌方回合：指令 +1+1 指向 x
local function RunCounterScenario(timing, expectedDefense, expectedAttack, label)
    print("--- 场景3: 钩子反制（" .. label .. "） ---")
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, timing)
    local x = KARDS.CardInterface.CreateMockCard("x", "unit", "P1", { attack = 6, defense = 3 })
    local counterCard = KARDS.CardInterface.CreateMockCard("counter", "counter_command", "P1", {})

    -- 注册反制钩子（OnBeforePlayCard）：目标受到 3 伤害；若目标死亡则拦截指令
    KARDS.EngineHooks.Register(KARDS.Battle.TableID, KARDS.EngineHooks.HookPoints.OnBeforePlayCard,
        "counter_test", function(args)
            local t = args.targets and args.targets[1]
            if t then
                t:ApplyChange("defense", "decrease", 3)
                KARDS.TickLog:Push("1", counterCard, "activate_counter", { { t, "take_damage", "-3" } })
                if not t:IsAlive() then
                    args.intercepted = true -- 目标死亡，指令失效
                end
            end
            return args
        end, KARDS.EngineHooks.TYPE_EFFECT)

    -- 敌方回合：指令 +1+1 指向 x
    local buffCard = KARDS.CardInterface.CreateMockCard("buff", "command", "P2", {})
    local ok = KARDS.Battle:SimPlayCard("P2", buffCard, { x })

    AssertEqual(x:GetStat("defense"), expectedDefense, label .. ": x 防御应为 " .. expectedDefense)
    AssertEqual(x:GetStat("attack"), expectedAttack, label .. ": x 攻击应为 " .. expectedAttack)
    if timing == "before" then
        AssertEqual(ok, false, label .. ": 指令应被拦截（目标先死亡）")
    else
        AssertEqual(ok, true, label .. ": 指令应生效（效果先于反制）")
    end

    -- 反制刻应被记录（操作类型为数组）
    local hasCounterTick = false
    for i = 1, KARDS.TickLog:Count("1") do
        if HasOpTypes(KARDS.TickLog:GetTick("1", i)[1][2], "activate_counter") then
            hasCounterTick = true
        end
    end
    AssertEqual(hasCounterTick, true, label .. ": 应记录反制刻（activate_counter）")
    AssertEqual(KARDS.TickLog:Count("1"), 2, label .. ": 总刻度数应为 2（反制刻 + 指令刻）")
end

-- 场景 4：多牌桌时间刻隔离 + _G 全局视图（用户核心关切）
local function RunMultiTableTest()
    print("--- 场景4: 多牌桌时间刻隔离 + _G 全局视图 ---")
    local c1 = KARDS.CardInterface.CreateMockCard("c1", "unit", "P1", {})
    local c2 = KARDS.CardInterface.CreateMockCard("c2", "unit", "P1", {})

    -- 创建 T1 后自动激活，_G 视图指向 T1
    KARDS.TickLog:Create("T1", "before")
    AssertEqual(_G.KARDS_TickTiming, "before", "创建 T1 后激活: 时机应为 before")
    AssertEqual(_G.KARDS_TickCount, 0, "创建 T1 后激活: 计数应为 0")

    -- T1 推进一刻（T1 为激活牌桌，_G 视图应同步）
    KARDS.TickLog:Push("T1", c1, "draw", {})
    AssertEqual(_G.KARDS_TickCount, 1, "T1 推进后: _G 视图计数应为 1")
    AssertEqual(_G.KARDS_TickLog[1][1][1], c1, "T1 推进后: _G 视图首条发起者应为 c1")

    -- 创建 T2：激活切到 T2，_G 视图指向 T2（计数 0），与 T1 数据不混淆
    KARDS.TickLog:Create("T2", "after")
    AssertEqual(_G.KARDS_TickCount, 0, "切到 T2: 视图计数应为 0（T1 不混淆）")
    AssertEqual(_G.KARDS_TickTiming, "after", "切到 T2: 视图时机应为 after")
    KARDS.TickLog:Push("T2", c2, "burn", {})
    AssertEqual(_G.KARDS_TickCount, 1, "T2 推进后: 视图计数应为 1")

    -- 切回 T1：数据应完整保留
    KARDS.TickLog:SetActive("T1")
    AssertEqual(_G.KARDS_TickCount, 1, "切回 T1: 视图计数仍为 1")
    AssertEqual(KARDS.TickLog:Count("T1"), 1, "T1 实例计数应为 1")
    AssertEqual(KARDS.TickLog:Count("T2"), 1, "T2 实例计数应为 1（互不影响）")
    AssertEqual(HasOpTypes(KARDS.TickLog:GetTick("T1", 1)[1][2], "draw"), true, "T1 首条操作类型应为 {draw}")
    AssertEqual(HasOpTypes(KARDS.TickLog:GetTick("T2", 1)[1][2], "burn"), true, "T2 首条操作类型应为 {burn}")
end

-- 场景 5：战场布局（自动居中 / 受限选位 / 总部参与 / 作弊 / 容量 / 总部保护）
local function RunBattlefieldTest()
    print("--- 场景5: 战场布局（自动居中/受限选位/总部参与/作弊/容量/总部保护） ---")
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local hq1 = KARDS.Battlefield:GetHQ("1", "P1")
    local sup1 = KARDS.Battlefield:GetSupport("1", "P1")
    local fl1 = KARDS.Battlefield:GetFrontline("1")

    -- 三个数组默认全 nil；总部参与居中（1 张恰居中于槽 3，不再恒驻但首张即居中）
    AssertEqual(hq1 ~= nil and hq1:GetType() == "headquarter", true, "P1 应有总部卡")
    AssertEqual(hq1:GetStat("defense"), 20, "总部防御应为 20")
    AssertEqual(sup1[3], hq1, "总部初始居中于槽 3（1 张居中）")
    AssertEqual(sup1[1] == nil and sup1[2] == nil and sup1[4] == nil and sup1[5] == nil, true,
        "支援阵线其余槽应为 nil")
    AssertEqual(fl1[1] == nil and fl1[3] == nil and fl1[5] == nil, true, "前线默认应全 nil")
    AssertEqual(KARDS.Battlefield:GetFrontlineOwner("1"), nil, "前线初始无控制方")

    -- 居中公式：奇数完美居中 / 偶数居中靠左（lineSize 可自定义，改阵线最大值自动生效）
    AssertEqual(KARDS.Battlefield:GetCenteredStart(1), 3, "居中公式：1 张 → 槽 3")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(2), 2, "居中公式：2 张 → 槽 2（偶数居中靠左）")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(3), 2, "居中公式：3 张 → 槽 2")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(4), 1, "居中公式：4 张 → 槽 1（偶数居中靠左）")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(5), 1, "居中公式：5 张 → 槽 1（全满）")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(1, 7), 4, "居中公式：lineSize=7 时 1 张 → 槽 4")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(2, 7), 3, "居中公式：lineSize=7 时 2 张 → 槽 3（偶数靠左）")

    -- 部署：受限选位（点击目标左/右侧、从两目标之间插入、无相邻目标自动靠最近目标）+ 整线自动居中
    local u1 = KARDS.CardInterface.CreateMockCard("u1", "unit", "P1", { attack = 2, defense = 2, keywords = { "blitz" } })
    local u1b = KARDS.CardInterface.CreateMockCard("u1b", "unit", "P1", {})
    local u1c = KARDS.CardInterface.CreateMockCard("u1c", "unit", "P1", {})
    local u1d = KARDS.CardInterface.CreateMockCard("u1d", "unit", "P1", {})
    -- 点击远离卡群的空槽（槽 1，无相邻目标）→ 自动靠向最近目标（总部）左侧，不阻止部署
    AssertEqual(KARDS.Battle:SimDeploy(u1, 1), true, "部署：点击空槽 1（无相邻目标自动靠最近目标）")
    AssertEqual(sup1[2], u1, "居中：2 张 → [槽2 u1, 槽3 总部]（偶数居中靠左）")
    AssertEqual(sup1[3], hq1, "总部参与居中（仍在槽 3，未被替换）")
    AssertEqual(KARDS.Battle:SimDeploy(u1, 2), false, "重复部署应被拒绝")
    -- 点击占用槽（总部所在槽）→ 插入该卡左侧（从 u1 与总部之间插入）
    AssertEqual(KARDS.Battle:SimDeploy(u1b, 3), true, "部署：点击占用槽（总部所在槽）= 插入其左侧")
    AssertEqual(sup1[2], u1, "居中：3 张 → [槽2 u1, 槽3 u1b, 槽4 总部]（奇数居中）")
    AssertEqual(sup1[3], u1b, "u1b 应从两目标（u1/总部）之间插入")
    AssertEqual(sup1[4], hq1, "总部参与居中（3 张时移至槽 4）")
    -- 点击目标右侧空槽 → 插入其右侧
    AssertEqual(KARDS.Battle:SimDeploy(u1c, 5), true, "部署：点击总部右侧空槽 = 插入其右侧")
    AssertEqual(sup1[1], u1, "居中：4 张 → [槽1 u1, 槽2 u1b, 槽3 总部, 槽4 u1c]（偶数居中靠左）")
    AssertEqual(sup1[3], hq1, "总部参与居中（4 张时回到槽 3）")
    AssertEqual(sup1[4], u1c, "u1c 应位于总部右侧")
    -- 点击占用槽（u1c 所在槽）→ 插入该卡左侧（5 张全满）
    AssertEqual(KARDS.Battle:SimDeploy(u1d, 4), true, "部署：点击占用槽（u1c 所在槽）= 插入其左侧")
    AssertEqual(sup1[4], u1d, "u1d 应插入 u1c 左侧（5 张居中全满）")
    AssertEqual(sup1[5], u1c, "u1c 右移一位（仍满）")
    -- 非法槽位 / 容量 / 重复部署
    AssertEqual(KARDS.Battle:SimDeploy(u1b, 0), false, "部署到非法槽位应被拒绝")
    AssertEqual(KARDS.Battle:SimDeploy(u1b, 6), false, "部署到越界槽位应被拒绝")
    local u1e = KARDS.CardInterface.CreateMockCard("u1e", "unit", "P1", {})
    AssertEqual(KARDS.Battle:SimDeploy(u1e, 1), false, "支援阵线已满（总部+4 单位），部署应被拒绝")

    -- 移动进前线（缺省自动首个空槽；u1 带闪击通过 7.2.2 闪击规则：本回合刚入场无闪击不能行动）
    AssertEqual(KARDS.Battle:SimMoveToFrontline(u1), true, "u1 移动进前线")
    AssertEqual(sup1[1], u1b, "居中：u1 移出后 4 张 → [槽1 u1b, 槽2 总部, 槽3 u1d, 槽4 u1c]")
    AssertEqual(sup1[2], hq1, "总部参与居中（4 张时槽 2）")
    AssertEqual(fl1[3], u1, "前线 1 张居中于槽 3")
    AssertEqual(KARDS.Battlefield:GetFrontlineOwner("1"), "P1", "前线控制方应为 P1")

    -- 加入战场：自动首个空槽 + 居中
    local u2 = KARDS.CardInterface.CreateMockCard("u2", "unit", "P1", {})
    AssertEqual(KARDS.Battle:SimJoinBattlefield(u2), true, "P1 加入战场（自动空槽）")
    AssertEqual(sup1[5], u2, "u2 应自动填入首个空槽（槽 5，5 张全满）")

    -- 撤退（缺省自动首个空槽；支援阵线已满先拒绝，清出一个空位后成功）
    AssertEqual(KARDS.Battle:SimRetreat(u1), false, "撤退：支援阵线已满应被拒绝")
    AssertEqual(KARDS.Battle:SimRemoveFromField(u2, "death"), true, "u2 被消灭")
    AssertEqual(sup1[4], u1c, "居中：u2 移出后 4 张 → [槽1 u1b, 槽2 总部, 槽3 u1d, 槽4 u1c]")
    AssertEqual(KARDS.Battle:SimRetreat(u1), true, "u1 撤退回支援阵线（自动首个空槽）")
    AssertEqual(fl1[3], nil, "撤退后前线已空（全 nil）")
    AssertEqual(KARDS.Battlefield:GetFrontlineOwner("1"), nil, "前线空出后控制方应重置")
    AssertEqual(sup1[5], u1, "u1 应回支援阵线槽 5（首个空槽，5 张全满）")

    -- 作弊：P2 单位试图进入 P1 控制的前线
    AssertEqual(KARDS.Battle:SimMoveToFrontline(u1), true, "u1 再进前线")
    local u3 = KARDS.CardInterface.CreateMockCard("u3", "unit", "P2", { attack = 1, defense = 1, keywords = { "blitz" } })
    AssertEqual(KARDS.Battle:SimDeploy(u3, 1), true, "P2 部署 u3（P2 支援阵线 2 张 → 槽 2）")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(u3), false, "P2 u3 进 P1 控制的前线应被拒绝（作弊）")
    AssertEqual(KARDS.Battlefield:GetCheater("1"), "P2", "作弊方应为 P2")
    AssertEqual(KARDS.Battlefield:IsStopped("1"), true, "对局应已停止")
    AssertEqual(HasOpTypes(KARDS.TickLog:GetTick("1", KARDS.TickLog:Count("1"))[1][2], "cheat"), true, "最后一刻应为作弊刻（cheat）")

    -- 总部保护：不可移动 / 不可被移除 / 不可被消灭
    AssertEqual(KARDS.Battlefield:MoveToFrontline("1", hq1), false, "总部不可移动进前线")
    AssertEqual(KARDS.Battlefield:RemoveFromField("1", hq1), false, "总部不可被移除")
    AssertEqual(KARDS.Battle:SimRemoveFromField(hq1, "death"), false, "总部不可被消灭")

    -- 容量：支援阵线 4 单位 + 总部满 5 槽
    KARDS.Battle:StartBattle("2", { "P1", "P2" }, "before")
    local slots = { 1, 2, 4, 5 }
    for k, s in ipairs(slots) do
        local c = KARDS.CardInterface.CreateMockCard("s" .. k, "unit", "P1", { attack = 1, defense = 1 })
        AssertEqual(KARDS.Battle:SimDeploy(c, s), true, "P1 部署到槽 " .. s)
    end
    local sup2 = KARDS.Battlefield:GetSupport("2", "P1")
    local hq2 = KARDS.Battlefield:GetHQ("2", "P1")
    -- 自动居中模型：4 单位 + 总部共 5 张全满，总部参与居中（槽位随受限选位插入顺序变化，不恒驻某槽）
    local filled = 0
    local hasHQ = false
    for i = 1, 5 do
        if sup2[i] ~= nil then filled = filled + 1 end
        if sup2[i] == hq2 then hasHQ = true end
    end
    AssertEqual(filled == 5 and hasHQ, true, "支援阵线 4 单位 + 总部满 5 槽（总部参与居中）")
    local s5 = KARDS.CardInterface.CreateMockCard("s5", "unit", "P1", { attack = 1, defense = 1 })
    AssertEqual(KARDS.Battle:SimDeploy(s5, 1), false, "支援阵线单位槽已满，部署应被拒绝")
    AssertEqual(KARDS.Battle:SimJoinBattlefield(s5), false, "加入战场也无空槽应被拒绝")

    -- 前线容量：5 槽满后拒绝
    KARDS.Battle:StartBattle("3", { "P1", "P2" }, "before")
    for i = 1, 5 do
        local c = KARDS.CardInterface.CreateMockCard("f" .. i, "unit", "P1", { attack = 1, defense = 1, keywords = { "blitz" } })
        AssertEqual(KARDS.Battle:SimDeploy(c, 1), true, "部署第 " .. i .. " 个（槽 1）")
        AssertEqual(KARDS.Battle:SimMoveToFrontline(c, i), true, "第 " .. i .. " 个进前线槽 " .. i)
    end
    local fl3 = KARDS.Battlefield:GetFrontline("3")
    AssertEqual(fl3[1] ~= nil and fl3[2] ~= nil and fl3[3] ~= nil and fl3[4] ~= nil and fl3[5] ~= nil, true,
        "前线 5 槽应全满")
    local f6 = KARDS.CardInterface.CreateMockCard("f6", "unit", "P1", { attack = 1, defense = 1, keywords = { "blitz" } })
    AssertEqual(KARDS.Battle:SimDeploy(f6, 1), true, "部署第 6 个（支援阵线有空位）")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(f6), false, "前线已满，应被拒绝")

    -- 总部保护（表 3）：不可移动 / 不可被移除
    local hq3 = KARDS.Battlefield:GetHQ("3", "P1")
    AssertEqual(KARDS.Battlefield:MoveToFrontline("3", hq3), false, "总部不可移动进前线")
    AssertEqual(KARDS.Battlefield:RemoveFromField("3", hq3), false, "总部不可被移除")
end

-- 场景 6：卡组（39 张构筑）/ 士气伤害 / 重新调度（战斗系统规划.md 第 12 节）
local function RunDeckTest()
    print("--- 场景6: 卡组 / 士气伤害 / 重新调度 ---")

    -- 卡组：对局开始洗牌一次，此后顺序固定（有序但随机）
    KARDS.Battle:StartBattle("4", { "P1", "P2" }, "before", "P1") -- P1 先手
    local pool = {}
    for i = 1, 39 do
        pool[i] = KARDS.CardInterface.CreateMockCard("D1_" .. i, "unit", "P1", { attack = 1, defense = 1 })
    end
    AssertEqual(KARDS.Battle:SimSetupDeck("P1", pool), true, "P1 设置卡组（39 张构筑）")
    AssertEqual(KARDS.Deck:DeckSize("4", "P1"), 39, "卡组应为 39 张")

    -- 洗牌后顺序固定：抽牌顺序 = 卡组数组顺序
    local deckArr = KARDS.Deck:GetDeck("4", "P1")
    local top = deckArr[#deckArr]
    AssertEqual(KARDS.Deck:Peek("4", "P1"), top, "牌堆顶应为卡组数组末项")
    local drawn = KARDS.Battle:SimDraw("P1", 3)
    AssertEqual(#drawn, 3, "抽 3 张应得到 3 张")
    AssertEqual(drawn[1], top, "第 1 张抽到的应等于原牌堆顶（顺序固定）")
    AssertEqual(KARDS.Deck:HandSize("4", "P1"), 3, "P1 手牌应为 3 张")
    AssertEqual(KARDS.Deck:DeckSize("4", "P1"), 36, "卡组应剩 36 张")

    -- 士气伤害：抽空卡组后空抽（第一次 1，第二次 2）
    KARDS.Battle:SimDraw("P1", 36)
    AssertEqual(KARDS.Deck:DeckSize("4", "P1"), 0, "卡组应已抽空")
    AssertEqual(KARDS.Deck:GetMoralDamage("4", "P1"), 0, "尚未空抽，士气伤害计数应为 0")
    KARDS.Battle:SimDraw("P1", 1) -- 第一次空抽
    AssertEqual(KARDS.Deck:GetMoralDamage("4", "P1"), 1, "第一次空抽计数应为 1")
    local hq1 = KARDS.Battlefield:GetHQ("4", "P1")
    AssertEqual(hq1:GetStat("defense"), 19, "总部防御应 20-1=19")
    KARDS.Battle:SimDraw("P1", 1) -- 第二次空抽
    AssertEqual(KARDS.Deck:GetMoralDamage("4", "P1"), 2, "第二次空抽计数应为 2")
    AssertEqual(hq1:GetStat("defense"), 17, "总部防御应 20-1-2=17")
    AssertEqual(HasOpTypes(KARDS.TickLog:GetTick("4", KARDS.TickLog:Count("4"))[1][2], "take_damage"), true,
        "最后一刻应为士气伤害刻（take_damage）")

    -- 重新调度：先手 4 / 后手 5，弃牌随机插入卡组 + 补抽等量
    KARDS.Battle:StartBattle("5", { "P1", "P2" }, "before", "P1")
    local pool1, pool2 = {}, {}
    for i = 1, 39 do
        pool1[i] = KARDS.CardInterface.CreateMockCard("M1_" .. i, "unit", "P1", { attack = 1, defense = 1 })
        pool2[i] = KARDS.CardInterface.CreateMockCard("M2_" .. i, "unit", "P2", { attack = 1, defense = 1 })
    end
    KARDS.Battle:SimSetupDeck("P1", pool1)
    KARDS.Battle:SimSetupDeck("P2", pool2)
    KARDS.Battle:SimDealOpeningHands()
    AssertEqual(KARDS.Deck:HandSize("5", "P1"), 4, "先手 P1 起手 4 张")
    AssertEqual(KARDS.Deck:HandSize("5", "P2"), 5, "后手 P2 起手 5 张")
    AssertEqual(KARDS.Deck:DeckSize("5", "P1"), 35, "先手卡组剩 35 张")
    AssertEqual(KARDS.Deck:DeckSize("5", "P2"), 34, "后手卡组剩 34 张")

    -- 重新调度：P1 丢弃 1 张 → 随机插入卡组 + 补抽 1 张
    local unwanted = KARDS.Deck:GetHand("5", "P1")[1]
    AssertEqual(KARDS.Battle:SimMulligan("P1", { unwanted }), true, "P1 重新调度成功")
    AssertEqual(KARDS.Deck:HandSize("5", "P1"), 4, "重新调度后手牌数不变（4 张）")
    AssertEqual(KARDS.Deck:DeckSize("5", "P1"), 35, "卡组数不变（弃 1 插回 1）")
    local inDeck = false
    for _, c in ipairs(KARDS.Deck:GetDeck("5", "P1")) do
        if c == unwanted then inDeck = true end
    end
    AssertEqual(inDeck, true, "丢弃的牌应已随机插入卡组中")
    AssertEqual(KARDS.Deck:GetMoralDamage("5", "P1"), 0, "重新调度不应触发士气伤害（卡组充足）")

    -- 重新调度仅一次机会；丢弃不在手牌的牌被拒绝
    AssertEqual(KARDS.Battle:SimMulligan("P1", {}), false, "第二次重新调度应被拒绝")
    local outside = KARDS.CardInterface.CreateMockCard("outside", "unit", "P1", {})
    AssertEqual(KARDS.Battle:SimMulligan("P2", { outside }), false, "丢弃不在手牌的牌应被拒绝")
end

-- 场景 7：交战 / 战斗 / 单位类型规则（readme 7.1 / 7.3，战斗系统规划.md 第 13 节）
local function RunEngageFightTest()
    print("--- 场景7: 交战 / 战斗 / 单位类型规则 ---")

    -- 卡牌类型（单位/总部/指令/反制）与单位类型（仅单位卡有，非单位卡恒 nil）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local tank = KARDS.CardInterface.CreateMockCard("tank", "unit", "P1", { attack = 4, defense = 5, unitType = "tank" })
    local infantry = KARDS.CardInterface.CreateMockCard("inf", "unit", "P2", { attack = 2, defense = 2, unitType = "infantry" })
    local artillery = KARDS.CardInterface.CreateMockCard("art", "unit", "P1", { attack = 3, defense = 3, unitType = "artillery" })
    local command = KARDS.CardInterface.CreateMockCard("cmd", "command", "P1", {})
    local hq = KARDS.Battlefield:GetHQ("1", "P1")
    AssertEqual(tank:GetType(), "unit", "卡牌类型应为 unit（单位）")
    AssertEqual(hq:GetType(), "headquarter", "卡牌类型应为 headquarter（总部）")
    AssertEqual(command:GetType(), "command", "卡牌类型应为 command（指令）")
    AssertEqual(tank:GetUnitType(), "tank", "单位类型应为 tank")
    AssertEqual(infantry:GetUnitType(), "infantry", "单位类型应为 infantry")
    AssertEqual(command:GetUnitType(), nil, "指令卡单位类型应为 nil")
    AssertEqual(hq:GetUnitType(), nil, "总部单位类型应为 nil")
    AssertEqual(KARDS.CardInterface.CreateMockCard("bad", "unit", "P1", { unitType = "mech" }):GetUnitType(), nil,
        "非法单位类型应被拒绝（置 nil）")

    -- 交战：坦克 vs 步兵（双方互伤 + 反击；操作类型为数组，发起者第三字段 = 被反击数值）
    KARDS.Battle:SimEngage(tank, infantry)
    AssertEqual(infantry:GetStat("defense"), -2, "步兵防御应 2-4=-2（被攻击）")
    AssertEqual(tank:GetStat("defense"), 3, "坦克防御应 5-2=3（被反击）")
    local tick = KARDS.TickLog:GetTick("1", 1)
    AssertEqual(tick[1][1], tank, "交战发起者应为坦克")
    AssertEqual(HasOpTypes(tick[1][2], "engage", "attack", "deal_damage"), true,
        "交战发起者操作类型应为 {engage,attack,deal_damage}（数组）")
    AssertEqual(tick[1][3], "-2", "发起者第三字段应为 -2（被反击 2）")
    AssertEqual(tick[2][1][1], infantry, "交战受影响应为步兵")
    AssertEqual(HasOpTypes(tick[2][1][2], "engage", "take_damage", "counterattack"), true,
        "交战受影响操作类型应为 {engage,take_damage,counterattack}（数组）")
    AssertEqual(tick[2][1][3], "-4", "受影响操作字段应为 -4（受到 4 伤害）")

    -- 交战：炮兵 vs 步兵（单位类型规则在交战时生效：炮兵攻击不会受到反击伤害）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local art2 = KARDS.CardInterface.CreateMockCard("art2", "unit", "P1", { attack = 3, defense = 3, unitType = "artillery" })
    local inf2 = KARDS.CardInterface.CreateMockCard("inf2", "unit", "P2", { attack = 2, defense = 2, unitType = "infantry" })
    KARDS.Battle:SimEngage(art2, inf2)
    AssertEqual(inf2:GetStat("defense"), -1, "步兵防御应 2-3=-1（被攻击）")
    AssertEqual(art2:GetStat("defense"), 3, "炮兵防御应不变（攻击时不会受到反击伤害）")
    tick = KARDS.TickLog:GetTick("1", 1)
    AssertEqual(tick[1][3], nil, "炮兵被反制豁免：发起者无操作字段（无反伤）")

    -- 交战：轰炸机反击豁免（readme 7.3 单位类型规则）
    --   ① 轰炸机被攻击时不造成反击（无论攻击者是谁）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local tankA = KARDS.CardInterface.CreateMockCard("tkA", "unit", "P1", { attack = 2, defense = 4, unitType = "tank" })
    local bomA = KARDS.CardInterface.CreateMockCard("bomA", "unit", "P2", { attack = 3, defense = 3, unitType = "bomber" })
    KARDS.Battle:SimEngage(tankA, bomA)
    AssertEqual(bomA:GetStat("defense"), 1, "轰炸机被坦克攻击：只受 2 伤害（3-2=1）")
    AssertEqual(tankA:GetStat("defense"), 4, "轰炸机被攻击不反击：坦克防御不变（4）")
    tick = KARDS.TickLog:GetTick("1", 1)
    AssertEqual(tick[1][3], nil, "轰炸机被攻击不反击：发起者（坦克）无操作字段")
    --   ② 轰炸机攻击非战斗机目标不受反击
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local bomB = KARDS.CardInterface.CreateMockCard("bomB", "unit", "P1", { attack = 3, defense = 3, unitType = "bomber" })
    local tankB = KARDS.CardInterface.CreateMockCard("tkB", "unit", "P2", { attack = 2, defense = 4, unitType = "tank" })
    KARDS.Battle:SimEngage(bomB, tankB)
    AssertEqual(tankB:GetStat("defense"), 1, "轰炸机攻击坦克：坦克 4-3=1")
    AssertEqual(bomB:GetStat("defense"), 3, "轰炸机攻击非战斗机不受反击：防御不变（3）")
    tick = KARDS.TickLog:GetTick("1", 1)
    AssertEqual(tick[1][3], nil, "轰炸机攻击非战斗机：发起者无操作字段（不受反击）")
    --   ③ 轰炸机攻击战斗机仍受反击（readme 7.3：攻击除战斗机以外的目标时才不受反击）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local bomC = KARDS.CardInterface.CreateMockCard("bomC", "unit", "P1", { attack = 3, defense = 3, unitType = "bomber" })
    local fighterC = KARDS.CardInterface.CreateMockCard("ftC", "unit", "P2", { attack = 2, defense = 2, unitType = "fighter" })
    KARDS.Battle:SimEngage(bomC, fighterC)
    AssertEqual(bomC:GetStat("defense"), 1, "轰炸机攻击战斗机：仍受反击（3-2=1）")
    AssertEqual(fighterC:GetStat("defense"), -1, "战斗机防御 2-3=-1（被攻击，被消灭自动离场）")

    -- 战斗：无视单位类型规则（炮兵也受战斗伤害，互扣等同对方攻击的防御）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local art3 = KARDS.CardInterface.CreateMockCard("art3", "unit", "P1", { attack = 3, defense = 3, unitType = "artillery" })
    local inf3 = KARDS.CardInterface.CreateMockCard("inf3", "unit", "P2", { attack = 2, defense = 2, unitType = "infantry" })
    KARDS.Battle:SimFight(art3, inf3)
    AssertEqual(inf3:GetStat("defense"), -1, "战斗：步兵防御应 2-3=-1（互扣）")
    AssertEqual(art3:GetStat("defense"), 1, "战斗：炮兵防御应 3-2=1（无视单位类型规则）")
    tick = KARDS.TickLog:GetTick("1", 1)
    AssertEqual(tick[1][1], art3, "战斗发起者应为炮兵")
    AssertEqual(HasOpTypes(tick[1][2], "fight", "attack", "deal_damage"), true,
        "战斗发起者操作类型应为 {fight,attack,deal_damage}（数组）")
    AssertEqual(tick[1][3], "-2", "战斗发起者第三字段应为 -2（受战斗伤害）")
    AssertEqual(tick[2][1][1], inf3, "战斗受影响应为步兵")
    AssertEqual(HasOpTypes(tick[2][1][2], "fight", "take_damage", "counterattack"), true,
        "战斗受影响操作类型应为 {fight,take_damage,counterattack}（数组）")
    AssertEqual(tick[2][1][3], "-3", "战斗受影响操作字段应为 -3（受战斗伤害）")

    -- 攻击总部不算交战（readme 7.1）：SimEngage 拒绝总部目标
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local unit1 = KARDS.CardInterface.CreateMockCard("u1", "unit", "P1", { attack = 3, defense = 3 })
    AssertEqual(KARDS.Battle:SimEngage(unit1, hq), false, "攻击总部不算交战：SimEngage 应拒绝")
    AssertEqual(KARDS.TickLog:Count("1"), 0, "拒绝后不应记录刻度")
end

-- 场景 8：指挥点 / 卡牌花费 / 行动花费（readme 7.1，战斗系统规划.md 第 14 节）
local function RunCommandPointTest()
    print("--- 场景8: 指挥点 / 卡牌花费 / 行动花费 ---")

    -- 卡牌对象：卡牌花费（所有卡牌类型，缺省 0）+ 行动花费（仅单位，非单位 nil）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local unit = KARDS.CardInterface.CreateMockCard("u", "unit", "P1", { attack = 3, defense = 3, cost = 4, actionCost = 1 })
    local cmd = KARDS.CardInterface.CreateMockCard("c", "command", "P1", { cost = 2 })
    local plain = KARDS.CardInterface.CreateMockCard("p", "unit", "P1", {})
    local hq = KARDS.Battlefield:GetHQ("1", "P1")
    AssertEqual(unit:GetCost(), 4, "单位卡花费应为 4")
    AssertEqual(cmd:GetCost(), 2, "指令卡花费应为 2")
    AssertEqual(hq:GetCost(), 0, "总部卡花费缺省应为 0")
    AssertEqual(plain:GetCost(), 0, "未指定花费缺省应为 0")
    AssertEqual(unit:GetActionCost(), 1, "单位卡行动花费应为 1")
    AssertEqual(plain:GetActionCost(), 0, "单位卡行动花费缺省应为 0")
    AssertEqual(cmd:GetActionCost(), nil, "指令卡行动花费应为 nil（非单位）")
    AssertEqual(hq:GetActionCost(), nil, "总部卡行动花费应为 nil（非单位）")

    -- 开局（开场动画 / 重新调度期间）：双方 0 槽（点数 0，2026-08-11）
    AssertEqual(KARDS.CommandPoints:GetSlots("1", "P1"), 0, "先手 P1 开局槽数应为 0（开场动画期间）")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 0, "先手 P1 开局点数应为 0（开场动画期间）")
    AssertEqual(KARDS.CommandPoints:GetSlots("1", "P2"), 0, "后手 P2 开局槽数应为 0")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P2"), 0, "后手 P2 开局点数应为 0")

    -- 先手首回合：初始补给 +1 槽（点数补满 1；table_session.lua StartFirstTurn 同款序列）
    AssertEqual(KARDS.CommandPoints:AddSlot("1", "P1"), true, "先手初始补给：+1 槽应成功")
    AssertEqual(KARDS.CommandPoints:BeginTurn("1", "P1"), true, "先手初始补给：点数补满应成功")
    AssertEqual(KARDS.CommandPoints:GetSlots("1", "P1"), 1, "初始补给后先手槽数应为 1")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 1, "初始补给后先手点数应为 1")

    -- 回合开始：+1 槽 → 点数调整至与槽相等（先手 2 点）；记录 turn_begin 刻
    AssertEqual(KARDS.Battle:SimBeginTurn("P1"), true, "P1 回合开始应成功")
    AssertEqual(KARDS.CommandPoints:GetSlots("1", "P1"), 2, "P1 回合开始后槽数应为 2")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 2, "P1 点数应调整至与槽相等（2）")
    AssertEqual(KARDS.Battle:SimBeginTurn("P2"), true, "P2 回合开始应成功")
    AssertEqual(KARDS.CommandPoints:GetSlots("1", "P2"), 1, "P2 回合开始后槽数应为 1")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P2"), 1, "P2 点数应调整至与槽相等（1）")
    local lastTick = KARDS.TickLog:GetTick("1", KARDS.TickLog:Count("1"))
    AssertEqual(HasOpTypes(lastTick[1][2], "turn_begin"), true, "回合开始应记录 turn_begin 刻")

    -- 自然增长上限 12：P1 当前 2 槽，再 +10 次到 12，之后不再增长
    for _ = 1, 10 do KARDS.Battle:SimBeginTurn("P1") end
    AssertEqual(KARDS.CommandPoints:GetSlots("1", "P1"), 12, "P1 槽数自然增长上限应为 12")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 12, "P1 点数应与槽相等（12）")
    KARDS.Battle:SimBeginTurn("P1")
    AssertEqual(KARDS.CommandPoints:GetSlots("1", "P1"), 12, "达到上限后回合开始不再增长槽数（仍 12）")

    -- 绝对上限 24：卡牌效果扩展可突破 12，封顶 24
    for _ = 1, 12 do KARDS.CommandPoints:ExtendSlot("1", "P1") end
    AssertEqual(KARDS.CommandPoints:GetSlots("1", "P1"), 24, "效果扩展后槽数应为 24（绝对上限）")
    KARDS.CommandPoints:ExtendSlot("1", "P1")
    AssertEqual(KARDS.CommandPoints:GetSlots("1", "P1"), 24, "超过 24 应封顶（仍 24）")

    -- 效果扩展只增加槽上限，点数在回合开始补满（readme 7.1：回合开始时点数调整至与槽相等）
    KARDS.CommandPoints:BeginTurn("1", "P1")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 24, "回合开始点数补满至与槽相等（24）")

    -- 支付 / 检查：足够扣减，不足拒绝且不扣
    AssertEqual(KARDS.CommandPoints:Pay("1", "P1", 5), true, "支付 5 应成功")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 19, "支付后点数应为 24-5=19")
    AssertEqual(KARDS.CommandPoints:Pay("1", "P1", 100), false, "支付 100 应失败（点数不足）")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 19, "支付失败不应扣减点数")
    AssertEqual(KARDS.CommandPoints:CanPay("1", "P1", 19), true, "点数恰好足够应可支付")
    AssertEqual(KARDS.CommandPoints:CanPay("1", "P1", 20), false, "点数不足不可支付")

    -- 部署花费：先手初始补给 1 点，部署 cost=2 被拒绝；回合开始补到 2 点后成功并扣减
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local deployUnit = KARDS.CardInterface.CreateMockCard("d1", "unit", "P1", { attack = 2, defense = 2, cost = 2 })
    KARDS.CommandPoints:AddSlot("1", "P1")
    KARDS.CommandPoints:BeginTurn("1", "P1")
    AssertEqual(KARDS.Battle:SimDeploy(deployUnit, 1), false, "点数 1 不足 cost=2，部署应被拒绝")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 1, "拒绝后点数不变（1）")
    KARDS.Battle:SimBeginTurn("P1")
    AssertEqual(KARDS.Battle:SimDeploy(deployUnit, 1), true, "点数 2 足够 cost=2，部署应成功")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 0, "部署后点数应为 2-2=0")

    -- 行动花费：攻击消耗行动花费（先手初始补给 1 点，actionCost=1）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local atk = KARDS.CardInterface.CreateMockCard("a1", "unit", "P1", { attack = 3, defense = 3, actionCost = 1 })
    local def = KARDS.CardInterface.CreateMockCard("d2", "unit", "P2", { attack = 1, defense = 4 })
    KARDS.CommandPoints:AddSlot("1", "P1")
    KARDS.CommandPoints:BeginTurn("1", "P1")
    AssertEqual(KARDS.Battle:SimAttack(atk, def), true, "点数 1 足够 actionCost=1，攻击应成功")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 0, "攻击后点数应为 1-1=0")
    AssertEqual(KARDS.Battle:SimAttack(atk, def), false, "点数 0 不足 actionCost=1，再攻击应被拒绝")
    AssertEqual(def:GetStat("defense"), 1, "被拒绝的攻击不应造成伤害（防御仍 4-3=1）")

    -- 行动花费：移动消耗行动花费（先手初始补给 1 点，actionCost=1；先部署到支援阵线，cost=0 不扣点。
    -- mover 带闪击词条，故进入战场的本回合即可行动，readme 7.2.2）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local mover = KARDS.CardInterface.CreateMockCard("m1", "unit", "P1", { attack = 1, defense = 2, actionCost = 1, keywords = { "blitz" } })
    KARDS.CommandPoints:AddSlot("1", "P1")
    KARDS.CommandPoints:BeginTurn("1", "P1")
    AssertEqual(KARDS.Battle:SimDeploy(mover, 1), true, "先部署单位到支援阵线（cost=0 不扣点）")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 1, "部署后点数不变（1，cost=0）")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(mover), true, "点数 1 足够 actionCost=1，移动应成功（闪击）")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 0, "移动后点数应为 1-1=0")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(mover), false, "点数 0 不足 actionCost=1，再移动应被拒绝")
end

--[[
    场景 9：词条 / 明牌浏览 / 闪击规则（readme 7.1 明牌 / 7.2.2 战斗词条能力 / 7.2.3 特别战斗词条）
]]
local function RunKeywordTest()
    print("--- 场景9: 词条 / 明牌浏览 / 闪击规则 ---")

    -- 词条数组格式：单独 id 字符串；带数值词条（情报/倒计时/重甲）为 { 词条id, 数值 }
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local kwCard = KARDS.CardInterface.CreateMockCard("k1", "unit", "P1",
        { attack = 2, defense = 2, keywords = { "blitz", { "intel", 3 }, { "armor", 2 }, { "countdown", 5 } } })
    local kws = kwCard:GetKeywords()
    AssertEqual(#kws, 4, "词条数组应含 4 项")
    AssertEqual(kws[1], "blitz", "无数值词条应为单独 id 字符串")
    AssertEqual(kws[2][1], "intel", "带数值词条第 1 项为词条 id")
    AssertEqual(kws[2][2], 3, "带数值词条第 2 项为数值 x")
    AssertEqual(kwCard:HasKeyword("blitz"), true, "HasKeyword 命中单独 id 词条")
    AssertEqual(kwCard:HasKeyword("intel"), true, "HasKeyword 命中带数值词条")
    AssertEqual(kwCard:HasKeyword("smoke"), false, "无该词条返回 false")

    -- 非法词条剔除
    local bad = KARDS.CardInterface.CreateMockCard("k2", "unit", "P1", { keywords = { "nonexistent", "guard" } })
    AssertEqual(bad:HasKeyword("nonexistent"), false, "非法词条应被剔除")
    AssertEqual(bad:HasKeyword("guard"), true, "合法词条保留")

    -- 战斗机无法具有烟幕（readme 7.3 单位类型规则：创建时校验剔除 smoke）
    local fighterSmoke = KARDS.CardInterface.CreateMockCard("k4", "unit", "P1", { unitType = "fighter", keywords = { "smoke" } })
    AssertEqual(fighterSmoke:HasKeyword("smoke"), false, "战斗机无法具有烟幕（剔除）")
    local tankSmoke = KARDS.CardInterface.CreateMockCard("k5", "unit", "P1", { unitType = "tank", keywords = { "smoke" } })
    AssertEqual(tankSmoke:HasKeyword("smoke"), true, "其他单位类型可有烟幕")

    -- 亡计仅标记词条（触发效果由节点编辑器配置）；倒计时计数与移除由战斗系统实现（见场景 12）
    local dr = KARDS.CardInterface.CreateMockCard("k3", "unit", "P1", { keywords = { "deathrattle", { "countdown", 2 } } })
    AssertEqual(dr:HasKeyword("deathrattle"), true, "亡计仅标记词条")
    AssertEqual(dr:HasKeyword("countdown"), true, "倒计时为带数值词条（每回合 -1 归零移除，见场景 12）")

    -- 明牌浏览：对方手牌有明牌 → 返回卡牌对象；无 → 拒绝
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local ow = KARDS.CardInterface.CreateMockCard("o1", "unit", "P2", { attack = 1, defense = 1, keywords = { "overwatch" } })
    KARDS.Battle:SimSetupDeck("P2", { ow, KARDS.CardInterface.CreateMockCard("o2", "unit", "P2", { attack = 1, defense = 1 }) })
    KARDS.Battle:SimDealOpeningHands()
    local seen = KARDS.Battle:SimInspectOverwatch("P1", "P2")
    AssertEqual(seen ~= nil, true, "对方手牌有明牌，浏览应返回卡牌对象")
    AssertEqual(seen and seen[1] == ow, true, "返回的明牌应为明牌卡本身")
    AssertEqual(KARDS.Battle:SimInspectOverwatch("P2", "P1"), nil, "对方手牌无明牌，浏览应被拒绝")
    AssertEqual(KARDS.Battle:SimInspectOverwatch("P1", "P1"), nil, "不能浏览自己的手牌")

    -- 闪击规则：刚部署/加入的单位本回合不能行动（移动/攻击），除非闪击（readme 7.2.2）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local plain = KARDS.CardInterface.CreateMockCard("p1", "unit", "P1", { attack = 2, defense = 2, actionCost = 1 })
    AssertEqual(KARDS.Battle:SimDeploy(plain, 1), true, "部署普通单位成功")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(plain), false, "刚部署的单位本回合不能移动（无闪击）")
    AssertEqual(KARDS.Battle:SimAttack(plain, KARDS.CardInterface.CreateMockCard("e1", "unit", "P2", { attack = 0, defense = 3 })), false, "刚部署的单位本回合不能攻击（无闪击）")
    KARDS.Battle:SimBeginTurn("P1")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(plain), true, "下一回合开始后可移动")

    -- 闪击单位进入战场的本回合即可行动
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local blitz = KARDS.CardInterface.CreateMockCard("b1", "unit", "P1", { attack = 2, defense = 2, actionCost = 1, keywords = { "blitz" } })
    KARDS.CommandPoints:AddSlot("1", "P1")
    KARDS.CommandPoints:BeginTurn("1", "P1")
    AssertEqual(KARDS.Battle:SimDeploy(blitz, 1), true, "部署闪击单位成功")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(blitz), true, "闪击单位进入战场本回合即可移动")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 0, "移动后点数应为 1-1=0")
end

--[[
    场景 10：轰炸机拦截（readme 7.3 战斗机规则，拦截定义明确）

    敌阵线有战斗机 → 轰炸机无法攻击该阵线除战斗机以外的目标；
    战斗机被守护（guarded 词条）→ 轰炸机无法攻击该阵线任何目标（完全封锁）。
]]
local function RunInterceptTest()
    print("--- 场景10: 轰炸机拦截（readme 7.3 战斗机） ---")

    -- 有战斗机：轰炸机只能攻击战斗机，不能攻击该阵线其他单位
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local bomber = KARDS.CardInterface.CreateMockCard("b1", "unit", "P1",
        { attack = 3, defense = 2, actionCost = 0, unitType = "bomber", keywords = { "blitz" } })
    local fighter = KARDS.CardInterface.CreateMockCard("f1", "unit", "P2",
        { attack = 2, defense = 2, unitType = "fighter" })
    local tank = KARDS.CardInterface.CreateMockCard("t1", "unit", "P2",
        { attack = 1, defense = 4, unitType = "tank" })
    KARDS.Battle:SimDeploy(bomber, 1)
    KARDS.Battle:SimDeploy(fighter, 1)
    KARDS.Battle:SimDeploy(tank, 2)
    AssertEqual(KARDS.Battle:SimAttack(bomber, tank), false, "拦截：轰炸机不能攻击该阵线其他单位（坦克）")
    AssertEqual(tank:GetStat("defense"), 4, "被拦截的攻击不造成伤害")
    AssertEqual(KARDS.Battle:SimAttack(bomber, fighter), true, "拦截只允许轰炸机攻击战斗机")
    AssertEqual(fighter:IsAlive(), false, "战斗机被击毁（防御 2-3，被消灭自动离场）")

    -- 战斗机被消灭后自动离场 → 无拦截，轰炸机可攻击阵线其他单位
    -- （普通单位一回合一次攻击，readme 7.2.2 奋战；跨新回合后次数重置）
    KARDS.Battle:SimBeginTurn("P1")
    AssertEqual(KARDS.Battle:SimAttack(bomber, tank), true, "无战斗机：轰炸机可攻击该阵线其他单位")
    AssertEqual(tank:GetStat("defense"), 1, "坦克受到 3 伤害（防御 4-3=1）")

    -- 被守护战斗机：完全封锁该阵线（连战斗机也不能攻击）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local bomber2 = KARDS.CardInterface.CreateMockCard("b2", "unit", "P1",
        { attack = 3, defense = 2, actionCost = 0, unitType = "bomber", keywords = { "blitz" } })
    local gFighter = KARDS.CardInterface.CreateMockCard("f2", "unit", "P2",
        { attack = 2, defense = 2, unitType = "fighter", keywords = { "guarded" } })
    local tank2 = KARDS.CardInterface.CreateMockCard("t2", "unit", "P2",
        { attack = 1, defense = 4, unitType = "tank" })
    KARDS.Battle:SimDeploy(bomber2, 1)
    KARDS.Battle:SimDeploy(gFighter, 1)
    KARDS.Battle:SimDeploy(tank2, 2)
    AssertEqual(KARDS.Battle:SimAttack(bomber2, tank2), false, "被守护战斗机：轰炸机无法攻击该阵线任何目标（坦克）")
    AssertEqual(KARDS.Battle:SimAttack(bomber2, gFighter), false, "被守护战斗机：连战斗机也不能攻击")
    AssertEqual(tank2:IsAlive(), true, "坦克未受伤害")

    -- 非轰炸机不受拦截
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local infantry = KARDS.CardInterface.CreateMockCard("i1", "unit", "P1",
        { attack = 2, defense = 2, actionCost = 0, unitType = "infantry", keywords = { "blitz" } })
    local fighter3 = KARDS.CardInterface.CreateMockCard("f3", "unit", "P2",
        { attack = 2, defense = 2, unitType = "fighter" })
    local tank3 = KARDS.CardInterface.CreateMockCard("t3", "unit", "P2",
        { attack = 1, defense = 4, unitType = "tank" })
    KARDS.Battle:SimDeploy(infantry, 1)
    KARDS.Battle:SimDeploy(fighter3, 1)
    KARDS.Battle:SimDeploy(tank3, 2)
    AssertEqual(KARDS.Battle:SimAttack(infantry, tank3), true, "非轰炸机不受拦截")
end

--[[
    场景 11：联机防作弊与同步（readme 四：服务端权威 / 实时同步校验 / 异常同步处理）
]]
local function RunNetSyncTest()
    print("--- 场景11: 联机防作弊与同步（readme 四） ---")
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local u1 = KARDS.CardInterface.CreateMockCard("u1", "unit", "P1", { attack = 2, defense = 2, keywords = { "blitz" } })
    local u2 = KARDS.CardInterface.CreateMockCard("u2", "unit", "P2", { attack = 1, defense = 1, keywords = { "blitz" } })
    local sup1 = KARDS.Battlefield:GetSupport("1", "P1")

    -- ① 服务端权威判定：玩家仅发送执行请求，由服务端统一执行（readme 四-1）
    local ok, reason = KARDS.NetSync:ClientRequest("1", "P1",
        function() return KARDS.Battle:SimDeploy(u1, 1) end,
        KARDS.NetSync:GetClientView("1", "P1"))
    AssertEqual(ok, true, "P1 请求部署由服务端统一执行成功")
    AssertEqual(sup1[2], u1, "服务端状态已变更（u1 部署后 2 张居中 → 支援阵线槽 2）")
    AssertEqual(reason, nil, "成功时无失败原因")

    -- ② 实时同步校验：客户端上报签名与服务端不一致 → 判定不同步（参数篡改，readme 四-2）
    local ok2, reason2 = KARDS.NetSync:ClientRequest("1", "P1",
        function() return KARDS.Battle:SimMoveToFrontline(u1) end, "tampered_sig")
    AssertEqual(ok2, false, "篡改签名的请求应被拒绝")
    AssertEqual(reason2, "desync", "拒绝原因为 desync（数据不同步）")
    AssertEqual(KARDS.NetSync:IsSuspended("1", "P1"), true, "不同步后该客户端操作被暂停")
    AssertEqual(KARDS.Battlefield:IsStopped("1"), false, "desync 不停止对局（区别于规则层作弊）")
    AssertEqual(HasOpTypes(KARDS.TickLog:GetTick("1", KARDS.TickLog:Count("1"))[1][2], "desync"), true,
        "最后一刻应为 desync 刻")

    -- ③ 异常同步处理：暂停中拒绝所有操作；对端不受影响；全量同步后恢复（readme 四-3）
    local ok3, reason3 = KARDS.NetSync:ClientRequest("1", "P1",
        function() return KARDS.Battle:SimDeploy(u1, 2) end,
        KARDS.NetSync:GetClientView("1", "P1"))
    AssertEqual(ok3, false, "暂停中的客户端所有操作被拒绝")
    AssertEqual(reason3, "suspended", "拒绝原因为 suspended（暂停中）")
    local ok4, reason4 = KARDS.NetSync:ClientRequest("1", "P2",
        function() return KARDS.Battle:SimDeploy(u2, 1) end,
        KARDS.NetSync:GetClientView("1", "P2"))
    AssertEqual(ok4, true, "未被暂停的对端不受影响，请求正常执行")
    AssertEqual(reason4, nil, "对端成功无失败原因")

    -- 全量同步：客户端视图 = 服务端权威，同步完成后开放操作权限
    AssertEqual(KARDS.NetSync:SyncClient("1", "P1"), true, "对 P1 执行全服数据同步")
    AssertEqual(KARDS.NetSync:IsSuspended("1", "P1"), false, "同步完成后开放操作权限")
    AssertEqual(KARDS.NetSync:GetClientView("1", "P1"), KARDS.NetSync:BuildSignature("1"),
        "同步后客户端视图 = 服务端权威签名")
    AssertEqual(HasOpTypes(KARDS.TickLog:GetTick("1", KARDS.TickLog:Count("1"))[1][2], "sync"), true,
        "最后一刻应为 sync 刻（全量同步完成）")

    -- 同步完成后请求恢复执行
    local ok5, reason5 = KARDS.NetSync:ClientRequest("1", "P1",
        function() return KARDS.Battle:SimMoveToFrontline(u1) end,
        KARDS.NetSync:GetClientView("1", "P1"))
    AssertEqual(ok5, true, "同步完成后 P1 请求恢复执行")
    AssertEqual(reason5, nil, "恢复后请求成功无失败原因")
end

--[[
    场景 12：词条效果与限制（readme 7.2.1 效果能力 / 7.2.2 战斗词条能力；亡计/倒计时除外）

    战斗骨架以 KeywordStates[tableID] 状态表承载跨刻词条状态（压制/隐蔽/烟幕破/冲击/伏击/攻击次数/
    动员失去/抑制，见 sh_battle_stub.lua），词条规则查询一律经 HasActiveKeyword / GetKeywordValue
    （被抑制单位视为无任何词条）。本场景验证各词条在战斗入口（SimAttack / SimEngage / SimFight /
    SimDealDamage / SimMoveToFrontline / SimPlayCard / SimBeginTurn）中的实际效果与限制。
]]
local function RunKeywordEffectTest()
    print("--- 场景12: 词条效果与限制（readme 7.2.1 / 7.2.2） ---")

    -- ① 被守护 guarded（readme 7.2.1）：只能被轰炸机和炮兵攻击
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local inf1 = KARDS.CardInterface.CreateMockCard("i1", "unit", "P1", { attack = 2, defense = 2, unitType = "infantry", keywords = { "blitz" } })
    local art1 = KARDS.CardInterface.CreateMockCard("a1", "unit", "P1", { attack = 2, defense = 2, unitType = "artillery", keywords = { "blitz" } })
    local bom1 = KARDS.CardInterface.CreateMockCard("b1", "unit", "P1", { attack = 2, defense = 2, unitType = "bomber", keywords = { "blitz" } })
    local gd1 = KARDS.CardInterface.CreateMockCard("gd", "unit", "P2", { attack = 1, defense = 5, unitType = "infantry", keywords = { "guarded" } })
    KARDS.Battle:SimDeploy(gd1, 1)
    AssertEqual(KARDS.Battle:SimAttack(inf1, gd1), false, "被守护：步兵不能攻击被守护单位")
    AssertEqual(gd1:GetStat("defense"), 5, "被守护：被拒攻击不造成伤害")
    AssertEqual(KARDS.Battle:SimAttack(art1, gd1), true, "被守护：炮兵可以攻击被守护单位")
    AssertEqual(gd1:GetStat("defense"), 3, "被守护：炮兵造成 2 伤害（5-2）")
    AssertEqual(KARDS.Battle:SimAttack(bom1, gd1), true, "被守护：轰炸机可以攻击被守护单位")
    AssertEqual(gd1:GetStat("defense"), 1, "被守护：轰炸机造成 2 伤害（3-2）")

    -- ② 守护 guard（readme 7.2.2）：与守护单位相邻的非守护单位仅轰炸机/炮兵可攻击；守护单位本身可被攻击
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local inf2 = KARDS.CardInterface.CreateMockCard("i2", "unit", "P1", { attack = 2, defense = 2, unitType = "infantry", keywords = { "blitz" } })
    local art2 = KARDS.CardInterface.CreateMockCard("a2", "unit", "P1", { attack = 2, defense = 2, unitType = "artillery", keywords = { "blitz" } })
    local gd2 = KARDS.CardInterface.CreateMockCard("gd2", "unit", "P2", { attack = 1, defense = 5, unitType = "infantry", keywords = { "guard" } })
    local plain2 = KARDS.CardInterface.CreateMockCard("pl2", "unit", "P2", { attack = 1, defense = 5 })
    KARDS.Battle:SimDeploy(gd2, 1)
    KARDS.Battle:SimDeploy(plain2, 2)
    AssertEqual(KARDS.Battle:SimAttack(inf2, plain2), false, "守护：步兵不能攻击相邻守护的非守护单位")
    AssertEqual(plain2:GetStat("defense"), 5, "守护：被拒攻击不造成伤害")
    AssertEqual(KARDS.Battle:SimAttack(inf2, gd2), true, "守护：守护单位本身可被攻击")
    AssertEqual(gd2:GetStat("defense"), 3, "守护：守护单位受 2 伤害（5-2）")
    AssertEqual(KARDS.Battle:SimAttack(art2, plain2), true, "守护：炮兵可攻击相邻守护的非守护单位")
    AssertEqual(plain2:GetStat("defense"), 3, "守护：炮兵造成 2 伤害（5-2）")

    -- ③ 烟幕 smoke（readme 7.2.2）：无法被敌方单位攻击；攻击后失去（SmokeBroken）；移动后失去
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local inf3 = KARDS.CardInterface.CreateMockCard("i3", "unit", "P1", { attack = 2, defense = 2, unitType = "infantry", keywords = { "blitz" } })
    local tg3 = KARDS.CardInterface.CreateMockCard("tg", "unit", "P1", { attack = 0, defense = 3, unitType = "infantry", keywords = { "blitz" } })
    local smk3 = KARDS.CardInterface.CreateMockCard("smk", "unit", "P2", { attack = 2, defense = 3, unitType = "tank", keywords = { "smoke", "blitz" } })
    KARDS.Battle:SimDeploy(tg3, 1)
    KARDS.Battle:SimDeploy(smk3, 1)
    KARDS.Battle:SimDeploy(inf3, 2)
    AssertEqual(KARDS.Battle:SimAttack(inf3, smk3), false, "烟幕：烟幕单位（未破）无法被敌方攻击")
    AssertEqual(KARDS.Battle:SimAttack(smk3, tg3), true, "烟幕：烟幕单位自身可攻击（攻击后失去烟幕）")
    AssertEqual(tg3:GetStat("defense"), 1, "烟幕：目标受 2 伤害（3-2）")
    AssertEqual(KARDS.Battle:SimAttack(inf3, smk3), true, "烟幕：攻击后失去烟幕，可被攻击")
    AssertEqual(smk3:GetStat("defense"), 1, "烟幕：第二次攻击命中（3-2）")
    -- 移动后失去烟幕
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local inf3b = KARDS.CardInterface.CreateMockCard("i3b", "unit", "P1", { attack = 2, defense = 2, unitType = "infantry", keywords = { "blitz" } })
    local smk3b = KARDS.CardInterface.CreateMockCard("smk3b", "unit", "P2", { attack = 1, defense = 3, unitType = "tank", keywords = { "smoke", "blitz" } })
    KARDS.Battle:SimDeploy(inf3b, 1)
    KARDS.Battle:SimDeploy(smk3b, 1)
    AssertEqual(KARDS.Battle:SimAttack(inf3b, smk3b), false, "烟幕（移动前）：无法被攻击")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(smk3b), true, "烟幕：单位移动进前线（移动后失去烟幕）")
    AssertEqual(KARDS.Battle:SimAttack(inf3b, smk3b), true, "烟幕（移动后）：失去烟幕，可被攻击")

    -- ④ 隐蔽 stealth（readme 7.2.2）：部署时背面朝上（Hidden）；揭示前不受指令影响、行动花费 1；发起/被攻击后揭示（reveal 刻）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local ste4 = KARDS.CardInterface.CreateMockCard("ste", "unit", "P1", { attack = 2, defense = 3, keywords = { "stealth", "blitz" } })
    local en4 = KARDS.CardInterface.CreateMockCard("en", "unit", "P2", { attack = 0, defense = 3 })
    KARDS.CommandPoints:AddSlot("1", "P1")
    KARDS.CommandPoints:BeginTurn("1", "P1")
    KARDS.Battle:SimDeploy(ste4, 1)
    local st4 = KARDS.Battle.KeywordStates["1"]
    AssertEqual(st4.Hidden[ste4] == true, true, "隐蔽：部署时背面朝上（Hidden 标记）")
    local cmd4 = KARDS.CardInterface.CreateMockCard("cmd", "command", "P1", {})
    AssertEqual(KARDS.Battle:SimPlayCard("P1", cmd4, { ste4 }), false, "隐蔽：未揭示单位不能成为指令目标")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 1, "隐蔽：P1 初始补给后 1 点")
    AssertEqual(KARDS.Battle:SimAttack(ste4, en4), true, "隐蔽：单位发起攻击（Hidden 行动花费 1）")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 0, "隐蔽：攻击消耗 1 点（1-1=0）")
    AssertEqual(en4:GetStat("defense"), 1, "隐蔽：目标受 2 伤害（3-2）")
    AssertEqual(st4.Hidden[ste4] == nil, true, "隐蔽：发起攻击后揭示（Hidden 移除）")
    local hasReveal4 = false
    for i = 1, KARDS.TickLog:Count("1") do
        if HasOpTypes(KARDS.TickLog:GetTick("1", i)[1][2], "reveal") then hasReveal4 = true end
    end
    AssertEqual(hasReveal4, true, "隐蔽：揭示应记录 reveal 刻")
    AssertEqual(KARDS.Battle:SimPlayCard("P1", cmd4, { ste4 }), true, "隐蔽：揭示后可被指令影响")
    AssertEqual(ste4:GetStat("attack"), 3, "隐蔽：指令效果生效（attack 2+1）")
    -- 被攻击后揭示
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local atk4 = KARDS.CardInterface.CreateMockCard("atk4", "unit", "P1", { attack = 2, defense = 2, keywords = { "blitz" } })
    local ste4b = KARDS.CardInterface.CreateMockCard("ste4b", "unit", "P2", { attack = 0, defense = 3, keywords = { "stealth" } })
    KARDS.Battle:SimDeploy(atk4, 1)
    KARDS.Battle:SimDeploy(ste4b, 1)
    local st4b = KARDS.Battle.KeywordStates["1"]
    AssertEqual(st4b.Hidden[ste4b] == true, true, "隐蔽（被攻击侧）：部署时背面朝上")
    AssertEqual(KARDS.Battle:SimAttack(atk4, ste4b), true, "隐蔽（被攻击侧）：攻击命中")
    AssertEqual(ste4b:GetStat("defense"), 1, "隐蔽（被攻击侧）：受 2 伤害（3-2）")
    AssertEqual(st4b.Hidden[ste4b] == nil, true, "隐蔽（被攻击侧）：被攻击后揭示")

    -- ⑤ 免疫 immune（readme 7.2.1）：四个伤害入口伤害均为 0
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local im5 = KARDS.CardInterface.CreateMockCard("im", "unit", "P2", { attack = 2, defense = 5, keywords = { "immune" } })
    local a5a = KARDS.CardInterface.CreateMockCard("a5a", "unit", "P1", { attack = 3, defense = 3, keywords = { "blitz" } })
    local a5b = KARDS.CardInterface.CreateMockCard("a5b", "unit", "P1", { attack = 3, defense = 3, keywords = { "blitz" } })
    AssertEqual(KARDS.Battle:SimAttack(a5a, im5), false, "免疫：SimAttack 不造成伤害（返回 false）")
    AssertEqual(im5:GetStat("defense"), 5, "免疫：SimAttack 伤害为 0（防御不变）")
    AssertEqual(KARDS.Battle:SimEngage(a5b, im5), false, "免疫：SimEngage 不造成伤害（返回 false）")
    AssertEqual(im5:GetStat("defense"), 5, "免疫：SimEngage 伤害为 0（防御不变）")
    AssertEqual(a5b:GetStat("defense"), 1, "免疫：反击仍正常（攻击方受 2 伤害，3-2=1）")
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local im5b = KARDS.CardInterface.CreateMockCard("im5b", "unit", "P1", { attack = 3, defense = 3, keywords = { "immune" } })
    local b5 = KARDS.CardInterface.CreateMockCard("b5", "unit", "P2", { attack = 1, defense = 5 })
    AssertEqual(KARDS.Battle:SimFight(im5b, b5), true, "免疫：SimFight 执行成功")
    AssertEqual(im5b:GetStat("defense"), 3, "免疫：SimFight 免疫方不受伤害")
    AssertEqual(b5:GetStat("defense"), 2, "免疫：SimFight 对方正常受伤害（5-3）")
    KARDS.Battle:SimDealDamage(b5, im5b, 5)
    AssertEqual(im5b:GetStat("defense"), 3, "免疫：SimDealDamage 伤害为 0（防御不变）")

    -- ⑥ 重甲 X armor（readme 7.2.2）：交战（SimEngage）伤害减免 X，上限 3
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local atk6a = KARDS.CardInterface.CreateMockCard("atk6a", "unit", "P1", { attack = 5, defense = 5, keywords = { "blitz" } })
    local atk6b = KARDS.CardInterface.CreateMockCard("atk6b", "unit", "P1", { attack = 5, defense = 5, keywords = { "blitz" } })
    local arm6a = KARDS.CardInterface.CreateMockCard("arm6a", "unit", "P2", { attack = 1, defense = 5, keywords = { { "armor", 2 } } })
    local arm6b = KARDS.CardInterface.CreateMockCard("arm6b", "unit", "P2", { attack = 1, defense = 5, keywords = { { "armor", 5 } } })
    KARDS.Battle:SimDeploy(arm6a, 1)
    KARDS.Battle:SimDeploy(arm6b, 2)
    AssertEqual(KARDS.Battle:SimEngage(atk6a, arm6a), true, "重甲：交战命中（减免后伤害仍 > 0）")
    AssertEqual(arm6a:GetStat("defense"), 2, "重甲 2：5 伤害减 2 = 3（防御 5-3=2）")
    AssertEqual(KARDS.Battle:SimEngage(atk6b, arm6b), true, "重甲：上限 3 命中")
    AssertEqual(arm6b:GetStat("defense"), 3, "重甲 5 → 上限 3：5 伤害减 3 = 2（防御 5-2=3）")

    -- ⑥b 重甲减反击（readme 7.2.2 / 7.4 示例）：交战时攻击者受到的普通反击 / 伏击反击也受攻击者重甲减免
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local atkR = KARDS.CardInterface.CreateMockCard("atkR", "unit", "P1", { attack = 2, defense = 6, keywords = { "blitz", { "armor", 2 } } })
    local defR = KARDS.CardInterface.CreateMockCard("defR", "unit", "P2", { attack = 3, defense = 5 })
    KARDS.Battle:SimDeploy(defR, 1)
    AssertEqual(KARDS.Battle:SimEngage(atkR, defR), true, "重甲减反击：普通反击场景交战命中")
    AssertEqual(atkR:GetStat("defense"), 5, "重甲减反击：普通反击 3-重甲2=1（防御 6-1=5，未减则为 3）")
    local atkVA = KARDS.CardInterface.CreateMockCard("atkVA", "unit", "P1", { attack = 2, defense = 6, keywords = { "blitz", { "armor", 2 } } })
    local defVA = KARDS.CardInterface.CreateMockCard("defVA", "unit", "P2", { attack = 3, defense = 5, keywords = { "ambush" } })
    KARDS.Battle:SimDeploy(defVA, 1)
    AssertEqual(KARDS.Battle:SimEngage(atkVA, defVA), true, "重甲减反击：伏击反击场景交战命中")
    AssertEqual(atkVA:GetStat("defense"), 5, "重甲减反击：伏击反击 3-重甲2=1（防御 6-1=5）")
    AssertEqual(defVA:GetStat("defense"), 3, "重甲减反击：伏击单位受攻击 2 伤害（防御 5-2=3）")

    -- ⑦ 冲击 shock（readme 7.2.2）：首次攻击被攻击单位不反击，攻击后移除（第二次攻击有反击）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local sh7 = KARDS.CardInterface.CreateMockCard("sh7", "unit", "P1", { attack = 3, defense = 3, keywords = { "blitz", "shock" } })
    local d7 = KARDS.CardInterface.CreateMockCard("d7", "unit", "P2", { attack = 2, defense = 5 })
    KARDS.Battle:SimDeploy(d7, 1)
    AssertEqual(KARDS.Battle:SimEngage(sh7, d7), true, "冲击：首次攻击命中")
    AssertEqual(sh7:GetStat("defense"), 3, "冲击：首次攻击无反击（防御不变）")
    AssertEqual(d7:GetStat("defense"), 2, "冲击：目标受 3 伤害（5-3）")
    KARDS.Battle:SimBeginTurn("P1") -- 重置攻击次数（冲击已移除，ShockUsed 不重置）
    AssertEqual(KARDS.Battle:SimEngage(sh7, d7), true, "冲击：第二次攻击（ShockUsed 已置）")
    AssertEqual(sh7:GetStat("defense"), 1, "冲击：第二次攻击有反击（3-2=1）")
    AssertEqual(d7:GetStat("defense"), -1, "冲击：目标再受 3 伤害（2-3）")

    -- ⑧ 伏击 ambush（readme 7.2.2）：每回合首次被攻击时首先反击；击杀攻击者则攻击无效；冲击不触发；每回合重置
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local v8 = KARDS.CardInterface.CreateMockCard("v8", "unit", "P2", { attack = 3, defense = 5, keywords = { "ambush" } })
    local a8a = KARDS.CardInterface.CreateMockCard("a8a", "unit", "P1", { attack = 2, defense = 2, keywords = { "blitz" } })
    local a8b = KARDS.CardInterface.CreateMockCard("a8b", "unit", "P1", { attack = 1, defense = 6, keywords = { "blitz" } })
    local sh8 = KARDS.CardInterface.CreateMockCard("sh8", "unit", "P1", { attack = 2, defense = 6, keywords = { "blitz", "shock" } })
    KARDS.Battle:SimDeploy(v8, 1)
    local countV8 = KARDS.TickLog:Count("1") -- 交战刻位置（伏击击杀攻击者后自动移除，death 刻在其后）
    AssertEqual(KARDS.Battle:SimAttack(a8a, v8), false, "伏击：攻击者被伏击反击击杀，攻击无效")
    AssertEqual(a8a:IsAlive(), false, "伏击：攻击者被击杀（防御 2-3，自动离场）")
    AssertEqual(v8:GetStat("defense"), 5, "伏击：伏击单位未受伤害")
    AssertEqual(KARDS.TickLog:GetTick("1", countV8 + 1)[1][3], "-3", "伏击：发起者第三字段 = 伏击反击数值（-3，交战刻）")
    KARDS.Battle:SimBeginTurn("P1") -- 伏击每回合重置（AmbushUsed）
    AssertEqual(KARDS.Battle:SimAttack(a8b, v8), true, "伏击：新回合攻击者存活，攻击命中")
    AssertEqual(a8b:GetStat("defense"), 3, "伏击：攻击者受伏击反击（6-3=3）")
    AssertEqual(v8:GetStat("defense"), 4, "伏击：伏击单位受 1 伤害（5-1）")
    KARDS.Battle:SimBeginTurn("P1")
    AssertEqual(KARDS.Battle:SimAttack(sh8, v8), true, "伏击：冲击攻击命中（冲击压伏击）")
    AssertEqual(sh8:GetStat("defense"), 6, "伏击：冲击攻击不触发伏击（防御不变）")
    AssertEqual(v8:GetStat("defense"), 2, "伏击：伏击单位受 2 伤害（4-2）")

    -- ⑧b 伏击替代普通反击（readme 7.4 示例，SimEngage 交战）：伏击=首先反击（本次被攻击反击权已行使，
    -- 不再普通反击）；冲击攻击单位后移除（ShockUsed）→ 下回合攻击时伏击正常触发
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local atkv8 = KARDS.CardInterface.CreateMockCard("atkv8", "unit", "P1", { attack = 1, defense = 8, keywords = { "blitz" } })
    local defv8 = KARDS.CardInterface.CreateMockCard("defv8", "unit", "P2", { attack = 3, defense = 5, keywords = { "ambush" } })
    KARDS.Battle:SimDeploy(defv8, 1)
    AssertEqual(KARDS.Battle:SimEngage(atkv8, defv8), true, "伏击替代反击：交战命中")
    AssertEqual(atkv8:GetStat("defense"), 5, "伏击替代反击：仅伏击反击 3（防御 8-3=5，无普通反击）")
    AssertEqual(defv8:GetStat("defense"), 4, "伏击替代反击：伏击单位受攻击 1 伤害（防御 5-1=4）")
    local tickV = KARDS.TickLog:GetTick("1", KARDS.TickLog:Count("1"))
    AssertEqual(tickV[1][3], "-3", "伏击替代反击：发起者第三字段 = 伏击反击数值（-3，无普通反击叠加）")
    -- 冲击移除后伏击触发（readme 7.4 示例）：冲击首次攻击压伏击，攻击后移除 → 下回合攻击伏击正常触发
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local atkSH = KARDS.CardInterface.CreateMockCard("atkSH", "unit", "P1", { attack = 2, defense = 8, keywords = { "blitz", "shock" } })
    local defSH = KARDS.CardInterface.CreateMockCard("defSH", "unit", "P2", { attack = 3, defense = 5, keywords = { "ambush" } })
    KARDS.Battle:SimDeploy(defSH, 1)
    AssertEqual(KARDS.Battle:SimEngage(atkSH, defSH), true, "冲击移除：首次攻击（冲击压伏击）命中")
    AssertEqual(atkSH:GetStat("defense"), 8, "冲击移除：首次攻击伏击不触发（冲击压反击，防御不变）")
    AssertEqual(defSH:GetStat("defense"), 3, "冲击移除：伏击单位受攻击 2 伤害（防御 5-2=3）")
    KARDS.Battle:SimBeginTurn("P1") -- 重置攻击次数 / 伏击次数；冲击移除状态（ShockUsed）保留
    AssertEqual(KARDS.Battle:SimEngage(atkSH, defSH), true, "冲击移除：冲击已移除后攻击命中")
    AssertEqual(atkSH:GetStat("defense"), 5, "冲击移除：伏击正常触发 3（防御 8-3=5，冲击已移除）")
    AssertEqual(defSH:GetStat("defense"), 1, "冲击移除：伏击单位再受攻击 2 伤害（防御 3-2=1）")

    -- ⑨ 奋战 frenzy（readme 7.2.2）：一回合可攻击两次；普通单位一次；每回合重置
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local f9 = KARDS.CardInterface.CreateMockCard("f9", "unit", "P1", { attack = 2, defense = 5, keywords = { "blitz", "frenzy" } })
    local n9 = KARDS.CardInterface.CreateMockCard("n9", "unit", "P1", { attack = 1, defense = 5, keywords = { "blitz" } })
    local d9a = KARDS.CardInterface.CreateMockCard("d9a", "unit", "P2", { attack = 0, defense = 5 })
    local d9b = KARDS.CardInterface.CreateMockCard("d9b", "unit", "P2", { attack = 0, defense = 5 })
    KARDS.Battle:SimDeploy(d9a, 1)
    KARDS.Battle:SimDeploy(d9b, 2)
    AssertEqual(KARDS.Battle:SimAttack(f9, d9a), true, "奋战：第一次攻击")
    AssertEqual(KARDS.Battle:SimAttack(f9, d9b), true, "奋战：第二次攻击（一回合两次）")
    AssertEqual(KARDS.Battle:SimAttack(f9, d9a), false, "奋战：第三次攻击被拒绝（次数用尽）")
    AssertEqual(KARDS.Battle:SimAttack(n9, d9a), true, "攻击次数：普通单位第一次攻击")
    AssertEqual(KARDS.Battle:SimAttack(n9, d9a), false, "攻击次数：普通单位第二次攻击被拒绝")
    AssertEqual(d9a:GetStat("defense"), 2, "攻击次数：d9a 受 3 伤害（5-2-1）")
    AssertEqual(d9b:GetStat("defense"), 3, "攻击次数：d9b 受 2 伤害（5-2）")

    -- ⑩ 动员 mobilize（readme 7.2.2）：回合开始 +1+1（stat_change 刻），受到伤害后失去
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local m10 = KARDS.CardInterface.CreateMockCard("m10", "unit", "P1", { attack = 1, defense = 5, keywords = { "mobilize", "blitz" } })
    local e10 = KARDS.CardInterface.CreateMockCard("e10", "unit", "P2", { attack = 3, defense = 1, unitType = "infantry", keywords = { "blitz" } })
    KARDS.Battle:SimDeploy(m10, 1)
    AssertEqual(m10:GetStat("attack"), 1, "动员：部署时 1/5")
    KARDS.Battle:SimBeginTurn("P1")
    AssertEqual(m10:GetStat("attack"), 2, "动员：回合开始 attack +1")
    AssertEqual(m10:GetStat("defense"), 6, "动员：回合开始 defense +1")
    local hasStatChange10 = false
    for i = 1, KARDS.TickLog:Count("1") do
        if HasOpTypes(KARDS.TickLog:GetTick("1", i)[1][2], "stat_change") then hasStatChange10 = true end
    end
    AssertEqual(hasStatChange10, true, "动员：+1+1 应记录 stat_change 刻")
    AssertEqual(KARDS.Battle:SimAttack(e10, m10), true, "动员：敌方攻击命中")
    AssertEqual(m10:GetStat("defense"), 3, "动员：受 3 伤害（6-3=3）")
    KARDS.Battle:SimBeginTurn("P1")
    AssertEqual(m10:GetStat("attack"), 2, "动员：受伤后失去，回合开始不再 +1+1（attack 仍 2）")
    AssertEqual(m10:GetStat("defense"), 3, "动员：受伤后失去，回合开始不再 +1+1（defense 仍 3）")

    -- ⑪ 山地 mountain（readme 7.2.2）：部署/加入时每有一个其他友方山地单位 +1+1（统计排除自身）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local mt1 = KARDS.CardInterface.CreateMockCard("mt1", "unit", "P1", { attack = 1, defense = 1, keywords = { "mountain" } })
    local mt2 = KARDS.CardInterface.CreateMockCard("mt2", "unit", "P1", { attack = 1, defense = 1, keywords = { "mountain" } })
    local mt3 = KARDS.CardInterface.CreateMockCard("mt3", "unit", "P1", { attack = 1, defense = 1, keywords = { "mountain" } })
    KARDS.Battle:SimDeploy(mt1, 1)
    AssertEqual(mt1:GetStat("attack"), 1, "山地：首个山地无加成（1/1）")
    KARDS.Battle:SimDeploy(mt2, 2)
    AssertEqual(mt2:GetStat("attack"), 2, "山地：第 2 个有 1 个友方山地（2/2）")
    KARDS.Battle:SimDeploy(mt3, 4)
    AssertEqual(mt3:GetStat("attack"), 3, "山地：第 3 个有 2 个友方山地（3/3）")

    -- ⑫ 情报 X intel（readme 7.2.2）：返回敌方手牌前 X 张（最多 9）；无情报返回 nil
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local i12 = KARDS.CardInterface.CreateMockCard("i12", "unit", "P1", { keywords = { { "intel", 3 } } })
    local i15 = KARDS.CardInterface.CreateMockCard("i15", "unit", "P1", { keywords = { { "intel", 15 } } })
    local pl12 = KARDS.CardInterface.CreateMockCard("pl12", "unit", "P1", {})
    local pool12 = {}
    for i = 1, 6 do pool12[i] = KARDS.CardInterface.CreateMockCard("h" .. i, "unit", "P2", {}) end
    KARDS.Battle:SimSetupDeck("P2", pool12)
    KARDS.Battle:SimDraw("P2", 4)
    local hand12 = KARDS.Deck:GetHand("1", "P2")
    AssertEqual(#hand12, 4, "情报：P2 手牌 4 张")
    local seen12 = KARDS.Battle:SimUseIntel(i12)
    AssertEqual(#seen12, 3, "情报 X=3：返回敌方手牌前 3 张")
    AssertEqual(seen12[1] == hand12[1] and seen12[2] == hand12[2] and seen12[3] == hand12[3], true,
        "情报：返回手牌前 X 张（顺序一致）")
    AssertEqual(#KARDS.Battle:SimUseIntel(i15), 4, "情报 X=15：上限 9 且不超手牌数（返回 4 张）")
    AssertEqual(KARDS.Battle:SimUseIntel(pl12), nil, "情报：无情报单位返回 nil")
    local hasIntel12 = false
    for i = 1, KARDS.TickLog:Count("1") do
        if HasOpTypes(KARDS.TickLog:GetTick("1", i)[1][2], "intelligence") then hasIntel12 = true end
    end
    AssertEqual(hasIntel12, true, "情报：应记录 intelligence 刻")

    -- ⑬ 抑制（readme 7.2.1）：失去所有关键词和效果（HasActiveKeyword 统一失效）
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local inf13 = KARDS.CardInterface.CreateMockCard("i13", "unit", "P1", { attack = 2, defense = 2, unitType = "infantry", keywords = { "blitz" } })
    local gd13 = KARDS.CardInterface.CreateMockCard("gd13", "unit", "P2", { attack = 1, defense = 5, keywords = { "guard" } })
    local pl13 = KARDS.CardInterface.CreateMockCard("pl13", "unit", "P2", { attack = 0, defense = 5 })
    KARDS.Battle:SimDeploy(gd13, 1)
    KARDS.Battle:SimDeploy(pl13, 2)
    AssertEqual(KARDS.Battle:SimAttack(inf13, pl13), false, "抑制前：守护生效（步兵不能攻击相邻单位）")
    AssertEqual(KARDS.Battle:SimInhibit(gd13), true, "抑制：SimInhibit 成功")
    AssertEqual(KARDS.Battle:HasActiveKeyword("1", gd13, "guard"), false, "抑制：HasActiveKeyword(guard) 为 false")
    AssertEqual(KARDS.Battle:SimAttack(inf13, pl13), true, "抑制后：守护失效（可攻击）")
    AssertEqual(pl13:GetStat("defense"), 3, "抑制后：攻击命中（5-2）")
    local hasNeutral13 = false
    for i = 1, KARDS.TickLog:Count("1") do
        if HasOpTypes(KARDS.TickLog:GetTick("1", i)[1][2], "neutralized") then hasNeutral13 = true end
    end
    AssertEqual(hasNeutral13, true, "抑制：应记录 neutralized 刻")

    -- ⑭ 被压制（readme 7.2.1）：不能移动或攻击；SimUnsuppress 解除后恢复
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local u14 = KARDS.CardInterface.CreateMockCard("u14", "unit", "P1", { attack = 2, defense = 2, keywords = { "blitz" } })
    local e14 = KARDS.CardInterface.CreateMockCard("e14", "unit", "P2", { attack = 0, defense = 3 })
    KARDS.Battle:SimDeploy(u14, 1)
    AssertEqual(KARDS.Battle:SimSuppress(u14), true, "被压制：SimSuppress 成功")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(u14), false, "被压制：不能移动")
    AssertEqual(KARDS.Battle:SimAttack(u14, e14), false, "被压制：不能攻击")
    AssertEqual(KARDS.Battle:SimUnsuppress(u14), true, "被压制：SimUnsuppress 成功")
    AssertEqual(KARDS.Battle:SimAttack(u14, e14), true, "被压制：解除后恢复攻击")
    AssertEqual(e14:GetStat("defense"), 1, "被压制：攻击命中（3-2）")
    local hasSuppress14, hasSuppressed14 = false, false
    for i = 1, KARDS.TickLog:Count("1") do
        local tick = KARDS.TickLog:GetTick("1", i)
        if HasOpTypes(tick[1][2], "suppress") then hasSuppress14 = true end
        if tick[2] and tick[2][1] and HasOpTypes(tick[2][1][2], "suppressed") then hasSuppressed14 = true end
    end
    AssertEqual(hasSuppress14, true, "被压制：应记录 suppress 刻")
    AssertEqual(hasSuppressed14, true, "被压制：应记录 suppressed 刻（受影响）")

    -- ⑮ 倒计时（readme 7.2.2）：每回合结束后 -1，归零触发事件并移除
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")
    local cd15 = KARDS.CardInterface.CreateMockCard("cd15", "unit", "P1",
        { attack = 1, defense = 1, keywords = { { "countdown", 2 }, "blitz" } })
    AssertEqual(KARDS.Battle:SimDeploy(cd15, 1), true, "倒计时：部署成功")
    local st15 = KARDS.Battle.KeywordStates["1"]
    AssertEqual(st15.Countdowns[cd15], 2, "倒计时：部署后初始值应为 2")
    AssertEqual(KARDS.Battle:SimEndTurn("P1"), true, "倒计时：P1 回合结束执行成功")
    AssertEqual(st15.Countdowns[cd15], 1, "倒计时：回合结束后 -1 → 1")
    local tickA15 = KARDS.TickLog:GetTick("1", KARDS.TickLog:Count("1"))
    AssertEqual(HasOpTypes(tickA15[1][2], "countdown"), true, "倒计时：-1 应记录 countdown 刻")
    AssertEqual(tickA15[2][1][3], "-1", "倒计时：countdown 刻 change 应为 -1")
    AssertEqual(KARDS.Battle:SimEndTurn("P2"), true, "倒计时：P2 回合结束执行成功")
    AssertEqual(st15.Countdowns[cd15], nil, "倒计时：归零后状态应清除")
    local tickT15 = KARDS.TickLog:GetTick("1", KARDS.TickLog:Count("1") - 1)
    AssertEqual(HasOpTypes(tickT15[1][2], "countdown", "trigger"), true, "倒计时：归零应记录触发刻（countdown+trigger）")
    local tickR15 = KARDS.TickLog:GetTick("1", KARDS.TickLog:Count("1"))
    AssertEqual(HasOpTypes(tickR15[1][2], "remove"), true, "倒计时：归零应移除单位（最后一刻 remove）")
    AssertEqual(KARDS.Battlefield:GetSupport("1", "P1")[1], nil, "倒计时：归零后单位应已移出战场")
end

-- 场景 13：7.4 Kards 标准战斗流程实战（readme 7.4 示例）
-- 四号坦克 vs 步兵班 + T-34：前线单一阵营占领 / 守护·被守护 / 冲击（压反击后移除）/
-- 重甲（攻击伤害与反击伤害均减）/ 奋战（一回合两攻）/ 伏击（=首先反击，替代普通反击）
local function RunScenario13()
    print("--- 场景13: 7.4 Kards 标准战斗流程实战（readme 7.4 示例） ---")
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before", "P1")

    -- 战斗场景设定（readme 7.4）：
    -- 我方四号坦克（坦克）攻击4/防御5/行动花费2：冲击、重甲2
    -- 敌方 T-34 1939（坦克）攻击3/防御3/行动花费1：伏击、奋战、重甲3
    -- 敌方步兵班（步兵）攻击2/防御2：守护
    local panzer = KARDS.CardInterface.CreateMockCard("panzer", "unit", "P1",
        { attack = 4, defense = 5, actionCost = 2, unitType = "tank", keywords = { "shock", { "armor", 2 } } })
    local t34 = KARDS.CardInterface.CreateMockCard("t34", "unit", "P2",
        { attack = 3, defense = 3, actionCost = 1, unitType = "tank", keywords = { "ambush", "frenzy", { "armor", 3 } } })
    local inf = KARDS.CardInterface.CreateMockCard("inf", "unit", "P2",
        { attack = 2, defense = 2, unitType = "infantry", keywords = { "guard" } })
    KARDS.Battle:SimDeploy(panzer, 1) -- 我方支援阵线槽 1
    KARDS.Battle:SimDeploy(t34, 1)    -- 敌方支援阵线槽 1（与步兵班相邻）
    KARDS.Battle:SimDeploy(inf, 2)    -- 敌方支援阵线槽 2（守护单位，使相邻 T-34 被守护）

    -- 战前推进回合：模拟对局已进行数回合，使我方 4 指挥点槽、敌方 5 指挥点槽（readme 场景设定）
    -- 开局双方 0 槽；先手初始补给 +1（P1=1）+ P1 再 +3 次 = 4；P2 0 槽 +5 次 = 5（交替推进）
    KARDS.CommandPoints:AddSlot("1", "P1")
    KARDS.CommandPoints:BeginTurn("1", "P1")
    for _ = 1, 3 do
        KARDS.Battle:SimBeginTurn("P1")
        KARDS.Battle:SimEndTurn("P1")
        KARDS.Battle:SimBeginTurn("P2")
        KARDS.Battle:SimEndTurn("P2")
    end
    for _ = 1, 2 do
        KARDS.Battle:SimBeginTurn("P2")
        KARDS.Battle:SimEndTurn("P2")
    end
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 4, "场景设定：我方 4 指挥点槽（点数=槽）")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P2"), 5, "场景设定：敌方 5 指挥点槽（点数=槽）")

    -- 步骤 1-2（我方回合）：四号移动至前线（坦克同一回合可移动+攻击，readme 7.3/7.4）
    AssertEqual(KARDS.Battle:SimMoveToFrontline(panzer), true, "移动：四号坦克移动至前线")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 2, "移动：消耗行动花费 2（4-2=2，readme 剩余2）")
    AssertEqual(KARDS.Battlefield:GetFrontlineOwner("1"), "P1", "前线：空出后进入，由我方占领（readme 7.1）")
    AssertEqual(KARDS.Battlefield:GetFrontline("1")[3], panzer, "前线：四号坦克居中于前线槽 3（1 张）")
    -- 步兵班【守护】：相邻 T-34 被守护，只能被轰炸机/炮兵攻击（四号是坦克，无法攻击）
    AssertEqual(KARDS.Battle:SimEngage(panzer, t34), false, "守护：坦克无法攻击被守护的 T-34（readme 7.4）")
    AssertEqual(t34:GetStat("defense"), 3, "守护：被拒攻击不造成伤害")
    -- 守护单位本身可被攻击：四号攻击步兵班（冲击压反击 + 重甲2 本次无反击暂不生效）
    AssertEqual(KARDS.Battle:SimEngage(panzer, inf), true, "攻击：四号攻击步兵班（守护单位本身可被攻击）")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 0, "攻击：消耗行动花费 2（2-2=0，readme 剩余0）")
    AssertEqual(inf:GetStat("defense"), -2, "伤害：4 攻 vs 防御2 → 2-4=-2（步兵班被消灭，readme）")
    AssertEqual(panzer:GetStat("defense"), 5, "冲击：首次攻击步兵班无反击（四号防御不变，readme）")
    AssertEqual(KARDS.Battle.KeywordStates["1"].ShockUsed[panzer] == true, true, "冲击：攻击后移除（ShockUsed 置位，readme）")
    -- 步兵班防御 ≤0 被自动移除（readme 7.1 溢出伤害：被消灭即离场）→ 守护单位离场后 T-34 失去被守护
    AssertEqual(KARDS.Battle:CanAttackTarget(panzer, t34), true, "守护解除：步兵班被消灭自动离场后 T-34 失去被守护")

    -- 步骤 3（敌方回合）：T-34 攻击四号 ×2（奋战，readme 7.2.2）
    KARDS.Battle:SimEndTurn("P1")
    KARDS.Battle:SimBeginTurn("P2")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P2"), 6, "敌方回合：指挥点槽+1，点数=6（readme）")
    AssertEqual(KARDS.Battle:SimEngage(t34, panzer), true, "交战：T-34 第一次攻击四号")
    AssertEqual(panzer:GetStat("defense"), 4, "重甲2：3 攻-2 = 1（四号防御 5-1=4，readme）")
    AssertEqual(t34:GetStat("defense"), 2, "反击：四号反击 4 攻-重甲3 = 1（T-34 防御 3-1=2，readme）")
    AssertEqual(KARDS.Battle:SimEngage(t34, panzer), true, "奋战：T-34 第二次攻击（一回合两次，readme）")
    AssertEqual(panzer:GetStat("defense"), 3, "重甲2：再受 1 伤害（四号防御 4-1=3，readme）")
    AssertEqual(t34:GetStat("defense"), 1, "反击：四号再反击 1（T-34 防御 2-1=1，readme）")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P2"), 4, "敌方回合：两次攻击扣 2（6-2=4，readme 剩余4）")

    -- 步骤 4（友方回合）：四号攻击 T-34（冲击已移除 → 伏击正常触发，readme 7.4）
    KARDS.Battle:SimEndTurn("P2")
    KARDS.Battle:SimBeginTurn("P1")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 5, "友方回合：指挥点槽+1，点数=5（readme）")
    local tickBefore13 = KARDS.TickLog:Count("1") -- 交战刻位置（T-34 被消灭后自动移除，death 刻在其后）
    AssertEqual(KARDS.Battle:SimEngage(panzer, t34), true, "交战：四号攻击 T-34")
    AssertEqual(panzer:GetStat("defense"), 2, "伏击：反击 3 攻-重甲2 = 1（四号防御 3-1=2，readme）")
    AssertEqual(t34:GetStat("defense"), 0, "重甲3：4 攻-3 = 1（T-34 防御 1-1=0，被消灭，readme）")
    AssertEqual(t34:IsAlive(), false, "伏击：T-34 被消灭（自动离场）")
    local tick13 = KARDS.TickLog:GetTick("1", tickBefore13 + 1)
    AssertEqual(tick13[1][1], panzer, "伏击：交战刻发起者应为四号坦克")
    AssertEqual(HasOpTypes(tick13[1][2], "engage", "attack", "deal_damage"), true, "伏击：发起者操作类型 {engage, attack, deal_damage}（数组）")
    AssertEqual(tick13[1][3], "-1", "伏击：发起者第三字段 = 伏击反击数值（-1，替代普通反击无叠加，readme）")
    AssertEqual(KARDS.Battle.KeywordStates["1"].AmbushUsed[t34] == true, true, "伏击：T-34 伏击已触发（AmbushUsed 置位）")
    AssertEqual(KARDS.CommandPoints:GetPoints("1", "P1"), 3, "友方回合：攻击扣 2（5-2=3，readme 剩余3）")

    -- 步骤 5（战斗结果，readme 7.4）：
    AssertEqual(panzer:IsAlive(), true, "结果：四号坦克存活")
    AssertEqual(panzer:GetStat("defense"), 2, "结果：四号坦克剩余防御力 2")
    AssertEqual(KARDS.Battlefield:GetSupport("1", "P2")[1], nil, "结果：T-34 已移出战场")
    AssertEqual(KARDS.Battlefield:GetSupport("1", "P2")[2], nil, "结果：步兵班已移出战场")
    AssertEqual(KARDS.Battlefield:GetFrontlineOwner("1"), "P1", "结果：前线仍由我方四号坦克占领（readme）")
    AssertEqual(KARDS.Battlefield:GetFrontline("1")[3], panzer, "结果：四号坦克仍在前线（1 张居中于槽 3）")
    AssertEqual(KARDS.Battle:IsStopped(), false, "结果：无作弊，对局未停止")
end

-- 场景 14：卡牌变换动画（预设 6 值 pose / 线性·平滑曲线 / 渐变到·增加·减少 / 曲线扩展 / AnimateCard / 真实时间开关）
local function RunAnimationTest()
    print("--- 场景14: 卡牌变换动画（6 值 / 线性·平滑 / 渐变到·增加·减少 / 曲线扩展 / AnimateCard / 真实时间开关） ---")
    local anim = KARDS.Animation

    -- 预设：3D 空间下卡牌的位置 + 三个角度（共 6 值）
    local pose = anim:GetPose("table")
    AssertEqual(pose ~= nil, true, "预设 pose：table 存在")
    AssertEqual(pose.pos.x == 0 and pose.pos.z == 0 and pose.ang.p == 90, true, "预设 pose：位置 + 角度（pitch 90 平放）")
    -- 副本隔离：修改副本不影响预设表
    pose.pos.x = 999
    AssertEqual(anim.Poses.table.pos.x, 0, "GetPose 返回副本，修改不影响预设")

    -- 6 值读写
    AssertEqual(anim:GetValue(anim.Poses.hand, "pos.y"), 0, "6 值读取：hand.pos.y = 0")
    AssertEqual(anim:SetValue(anim.Poses.hand, "ang.r", 45), true, "6 值写入：hand.ang.r = 45")
    AssertEqual(anim.Poses.hand.ang.r, 45, "写入生效")
    AssertEqual(anim:ParseAxis("pos.w"), nil, "非法轴 pos.w 拒绝")
    AssertEqual(anim:ParseAxis("ang.x"), nil, "非法轴 ang.x 拒绝")

    -- 线性·渐变到：5 秒内 pos.x 从 0 渐变到 10
    local t1 = anim:Animate(5, "pos.x", "linear", "to", 10)
    AssertEqual(t1 ~= nil, true, "线性·渐变到：创建成功")
    AssertEqual(t1:ValueAt(0), 0, "0 秒 = 起始 0")
    AssertEqual(t1:ValueAt(2.5), 5, "2.5 秒 = 5（线性中点）")
    AssertEqual(t1:ValueAt(5), 10, "5 秒 = 终值 10")
    AssertEqual(t1:Eval(0.75), 7.5, "Eval(0.75) = 7.5（进度采样）")

    -- 平滑·渐变到：smoothstep 对称（中点同线性、1/4 处缓入）
    local t2 = anim:Animate(1, "pos.x", "smooth", "to", 10)
    AssertEqual(t2:ValueAt(0.5), 5, "平滑中点 = 5（smoothstep 对称）")
    AssertEqual(math.abs(t2:ValueAt(0.25) - 1.5625) < 0.0001, true, "平滑 1/4 处 = 1.5625（缓入缓出）")

    -- 增加 / 减少
    local t3 = anim:Animate(1, "pos.y", "linear", "add", 5)
    AssertEqual(t3:ValueAt(1), 5, "增加：起始 0 + 5 = 5")
    local t4 = anim:Animate(1, "pos.y", "linear", "sub", 5, 10)
    AssertEqual(t4:ValueAt(1), 5, "减少：起始 10 - 5 = 5")

    -- 超时 clamp
    AssertEqual(t1:ValueAt(99), 10, "超过时长 clamp 到终值")
    AssertEqual(t1:ValueAt(-1), 0, "负时间 clamp 到起始")

    -- 参数校验（6 值约束 / 曲线注册表 / 模式）
    AssertEqual(anim:Animate(0, "pos.x", "linear", "to", 1), nil, "非法时长（0 秒）拒绝")
    AssertEqual(anim:Animate(1, "ang.roll", "linear", "to", 1), nil, "非法轴（ang.roll）拒绝")
    AssertEqual(anim:Animate(1, "pos.x", "bounce", "to", 1), nil, "未注册曲线（bounce）拒绝")
    AssertEqual(anim:Animate(1, "pos.x", "linear", "jump", 1), nil, "非法模式（jump）拒绝")

    -- 曲线扩展：AddEasing 注册新曲线后立即可用
    anim:AddEasing("ease_in_quad", function(t) return t * t end)
    local t5 = anim:Animate(1, "pos.x", "ease_in_quad", "to", 10)
    AssertEqual(t5 ~= nil, true, "曲线扩展：AddEasing 注册 ease_in_quad 后可用")
    AssertEqual(t5:ValueAt(0.5), 2.5, "ease_in_quad 0.5 秒 = 2.5（t²）")

    -- 卡牌绑定渐变：AnimateCard 指定一张卡的一个坐标/旋转值渐变并写回
    local ac = KARDS.CardInterface.CreateMockCard("anim_card", "unit", "P1", {})
    local a1 = anim:AnimateCard(ac, 1, "pos.x", "linear", "to", 10)
    AssertEqual(a1 ~= nil, true, "AnimateCard：创建成功")
    AssertEqual(a1.Apply ~= nil and a1.ApplyAt ~= nil, true, "AnimateCard：动画对象含 Apply / ApplyAt")
    AssertEqual(ac.pos.x, 0, "AnimateCard：卡牌 pos 字段缺省自动补齐 0")
    a1:Apply(1)
    AssertEqual(ac.pos.x, 10, "Apply(1) 将终值写回卡牌 pos.x = 10")
    AssertEqual(ac.pos.x, a1:ValueAt(1), "Apply 与 ValueAt 采样一致")
    -- 起始值缺省取卡牌当前值（从 5 渐变到 10）
    ac.pos.x = 5
    local a2 = anim:AnimateCard(ac, 1, "pos.x", "linear", "to", 10)
    a2:Apply(0.5)
    AssertEqual(ac.pos.x, 7.5, "起始值取卡牌当前值：从 5 渐变，Apply(0.5) = 7.5")
    a2:ApplyAt(1)
    AssertEqual(ac.pos.x, 10, "ApplyAt(1) = 10（渐变完成）")
    -- 增加模式：从卡牌当前值增加
    ac.pos.y = 2
    local a3 = anim:AnimateCard(ac, 1, "pos.y", "linear", "add", 3)
    a3:ApplyAt(1)
    AssertEqual(ac.pos.y, 5, "增加：卡牌当前 2 + 3 = 5")
    -- 旋转值渐变（ang 字段缺省自动补齐）
    local a4 = anim:AnimateCard(ac, 1, "ang.p", "smooth", "to", 90)
    AssertEqual(ac.ang ~= nil, true, "旋转渐变：卡牌 ang 字段缺省自动补齐")
    a4:Apply(1)
    AssertEqual(ac.ang.p, 90, "旋转渐变：Apply(1) 写回 ang.p = 90")
    -- 参数校验
    AssertEqual(anim:AnimateCard(nil, 1, "pos.x", "linear", "to", 1), nil, "AnimateCard：无卡牌对象拒绝")
    AssertEqual(anim:AnimateCard(ac, 1, "pos.w", "linear", "to", 1), nil, "AnimateCard：非法轴拒绝")
    AssertEqual(anim:AnimateCard(ac, 0, "pos.x", "linear", "to", 1), nil, "AnimateCard：非法时长拒绝")
    AssertEqual(anim:AnimateCard(ac, 1, "pos.x", "bounce", "to", 1), nil, "AnimateCard：未注册曲线拒绝")
    -- 减少模式：从卡牌当前值减少（sub）
    ac.pos.z = 8
    local a5 = anim:AnimateCard(ac, 1, "pos.z", "linear", "sub", 3)
    a5:ApplyAt(1)
    AssertEqual(ac.pos.z, 5, "减少：卡牌当前 8 - 3 = 5")
    AssertEqual(a5:Apply(0.5), a5:Eval(0.5), "Apply 与 Eval 采样值一致（6.5）")
    -- 显式 start 参数：覆盖卡牌当前值（当前 pos.x=10，显式 start=0 应从 0 渐变）
    local a6 = anim:AnimateCard(ac, 1, "pos.x", "linear", "to", 10, 0)
    a6:Apply(0.5)
    AssertEqual(ac.pos.x, 5, "显式 start=0：忽略卡牌当前值，Apply(0.5) = 5（若取当前值则为 15）")
    -- 非法模式（AnimateCard 复用 Animate 校验路径）
    AssertEqual(anim:AnimateCard(ac, 1, "pos.x", "linear", "jump", 1), nil, "AnimateCard：非法模式（jump）拒绝")
    -- 非 table 卡牌对象拒绝（type ~= "table" 分支）
    AssertEqual(anim:AnimateCard("not_a_card", 1, "pos.x", "linear", "to", 1), nil, "AnimateCard：非 table 卡牌对象拒绝")
    -- 玩家摄像头对象渐变：AnimateCard 可直接渐变摄像头 pos/ang（与卡牌共用同一世界坐标系）
    local cam = { pos = Vector(0, 0, 0), ang = Angle(0, 0, 0), fov = 75 }
    local c1 = anim:AnimateCard(cam, 1, "pos.x", "linear", "to", 100)
    c1:Apply(1)
    AssertEqual(cam.pos.x, 100, "摄像头渐变：Apply(1) 写回摄像头 pos.x = 100")
    local c2 = anim:AnimateCard(cam, 1, "ang.p", "smooth", "to", 45)
    c2:Apply(1)
    AssertEqual(cam.ang.p, 45, "摄像头渐变：旋转 ang.p 写回 = 45")
    -- 与卡牌对象共用同一坐标系：pos/ang 均为相对牌桌世界坐标的直接数值
    AssertEqual(type(cam.pos.x) == "number" and type(cam.ang.p) == "number", true,
        "摄像头与卡牌坐标/旋转均为相对牌桌世界坐标（直接数值）")

    -- 真实时间开关（KARDS.Animation.RealTime）：false 直接终值 / true 按真实秒数渐变
    AssertEqual(KARDS.Animation.RealTime, false, "真实时间开关默认 false（测试环境）")
    local r0 = anim:Animate(1, "pos.x", "linear", "to", 10)
    AssertEqual(r0:ValueNow(), 10, "RealTime=false：ValueNow 直接终值 10（不等真实秒数）")
    local r0b = anim:AnimateCard(ac, 1, "pos.x", "linear", "to", 20)
    r0b:ApplyNow()
    AssertEqual(ac.pos.x, 20, "RealTime=false：ApplyNow 直接写终值 20")
    -- 开关 true：创建时记录 StartTime，按真实时间插值（模拟 StartTime 为过去时刻验证）
    KARDS.Animation.RealTime = true
    local r1 = anim:Animate(1, "pos.x", "linear", "to", 10)
    AssertEqual(r1.StartTime ~= nil, true, "RealTime=true：创建时记录 StartTime")
    r1.StartTime = CurTime() - 0.5 -- 模拟已过 0.5 秒
    AssertNear(r1:ValueNow(), 5, 1e-6, "RealTime=true：0.5s 时线性中途 = 5（确实随时间渐变）")
    r1.StartTime = CurTime() - 1.5 -- 模拟超时
    AssertEqual(r1:ValueNow(), 10, "RealTime=true：超时 clamp 到终值 10")
    local r2 = anim:AnimateCard(ac, 1, "pos.y", "linear", "to", 10, 0) -- 显式起始 0，保证断言确定性（缺省取对象当前值）
    r2.StartTime = CurTime() - 0.5
    r2:ApplyNow()
    AssertNear(ac.pos.y, 5, 1e-6, "RealTime=true：ApplyNow 0.5s 写回 5（真实时间插值，显式起始 0）")
    KARDS.Animation.RealTime = false -- 恢复默认（测试环境保持 false）
end

-- 场景 15：自动居中序列 + 偶数偏移驱动（sh_battlefield_center.lua）
local function RunCenterShiftTest()
    print("--- 场景15: 自动居中序列 + 偶数偏移驱动 ---")
    KARDS.Battle:StartBattle("1", { "P1", "P2" }, "before")
    local sup1 = KARDS.Battlefield:GetSupport("1", "P1")
    local hq1 = KARDS.Battlefield:GetHQ("1", "P1")

    -- 居中序列（含总部参与计数）：1→[3] / 2→[2,3] / 3→[2,3,4] / 4→[1,2,3,4] / 5→全满
    AssertEqual(sup1[3], hq1, "居中序列：1 张 → [槽3]（总部参与居中）")
    local units = {}
    for i = 1, 4 do
        units[i] = KARDS.CardInterface.CreateMockCard("c" .. i, "unit", "P1", { attack = 1, defense = 1 })
        AssertEqual(KARDS.Battle:SimJoinBattlefield(units[i]), true, "加入第 " .. i .. " 张（自动空槽）")
        if i == 1 then
            AssertEqual(sup1[2] == units[1] and sup1[3] == hq1 and sup1[4] == nil and sup1[5] == nil, true,
                "居中序列：2 张 → [槽2, 槽3]（偶数居中靠左）")
        elseif i == 2 then
            AssertEqual(sup1[2] == units[2] and sup1[3] == units[1] and sup1[4] == hq1, true,
                "居中序列：3 张 → [槽2, 槽3, 槽4]（奇数居中）")
        elseif i == 3 then
            AssertEqual(sup1[1] == units[3] and sup1[2] == units[2] and sup1[3] == units[1] and sup1[4] == hq1, true,
                "居中序列：4 张 → [槽1, 槽2, 槽3, 槽4]（偶数居中靠左）")
        end
    end
    AssertEqual(sup1[1] == units[3] and sup1[2] == units[2] and sup1[3] == units[1]
        and sup1[4] == hq1 and sup1[5] == units[4], true, "居中序列：5 张 → 全满")

    -- 阵线变化后整线重新居中（移除 1 张：5 → 4 张居中靠左）
    AssertEqual(KARDS.Battle:SimRemoveFromField(units[4], "death"), true, "移除第 4 张（5→4 张）")
    AssertEqual(sup1[1] == units[3] and sup1[2] == units[2] and sup1[3] == units[1] and sup1[4] == hq1, true,
        "移除后整线重排：4 张 → [槽1, 槽2, 槽3, 槽4]")

    -- GetCenteredStart 自定义 lineSize（修改阵线最大值后公式自动生效）
    AssertEqual(KARDS.Battlefield:GetCenteredStart(0), 3, "居中公式：0 张 → 槽 3（clamp）")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(1, 7), 4, "居中公式：lineSize=7，1 张 → 槽 4")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(2, 7), 3, "居中公式：lineSize=7，2 张 → 槽 3（偶数靠左）")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(3, 7), 3, "居中公式：lineSize=7，3 张 → 槽 3")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(4, 7), 2, "居中公式：lineSize=7，4 张 → 槽 2")
    AssertEqual(KARDS.Battlefield:GetCenteredStart(6, 7), 1, "居中公式：lineSize=7，6 张 → 槽 1（偶数靠左）")

    -- 偶数偏移驱动（sh_battlefield_center.lua）：时间刻结束后偶数阵线整线右移 0.5*SPACING
    local bc = KARDS.BattlefieldCenter
    AssertEqual(bc:GetShift("1", "support", "P1"), 0, "偶数偏移：未记录 → 0")
    -- 当前 P1 支援阵线 4 张（偶数）→ 时间刻结束后记录移量
    AssertEqual(bc:OnTickEnd("1", "support", "P1"), 0.5, "偶数偏移：4 张（偶数）→ 0.5*SPACING=0.5")
    AssertEqual(bc:GetShift("1", "support", "P1"), 0.5, "偶数偏移：GetShift=0.5（渲染层采样驱动 0.3s 线性右移）")
    AssertEqual(bc:OnTickEnd("1", "support", "P2"), 0, "偶数偏移：P2 支援阵线 1 张（奇数）→ 0")
    AssertEqual(bc:GetShift("1", "support", "P2"), 0, "偶数偏移：奇数阵线 GetShift=0")
    AssertEqual(bc:OnTickEnd("1", "support", "NO_SUCH"), 0, "偶数偏移：不存在的支援阵线 → 0")

    -- 前线：1 张（奇数）→ 0；2 张（偶数）→ 0.5（前线按 FrontlineOwner 独立判定）
    local uf1 = KARDS.CardInterface.CreateMockCard("uf1", "unit", "P1", { attack = 1, defense = 1, keywords = { "blitz" } })
    local uf2 = KARDS.CardInterface.CreateMockCard("uf2", "unit", "P1", { attack = 1, defense = 1, keywords = { "blitz" } })
    AssertEqual(KARDS.Battle:SimDeploy(uf1, 1), true, "部署 uf1（P1 支援阵线 5 张全满）")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(uf1), true, "uf1 移入前线（前线 1 张）")
    AssertEqual(bc:OnTickEnd("1", "frontline"), 0, "偶数偏移：前线 1 张（奇数）→ 0")
    AssertEqual(KARDS.Battle:SimDeploy(uf2, 1), true, "部署 uf2（uf1 移走后支援阵线 5 张满）")
    AssertEqual(KARDS.Battle:SimMoveToFrontline(uf2), true, "uf2 移入前线（前线 2 张）")
    AssertEqual(bc:OnTickEnd("1", "frontline"), 0.5, "偶数偏移：前线 2 张（偶数）→ 0.5")
    AssertEqual(bc:GetShift("1", "frontline"), 0.5, "偶数偏移：GetShift=0.5（前线按 FrontlineOwner 独立判定）")

    -- 重置：清空该牌桌全部偏移记录
    bc:Reset("1")
    AssertEqual(bc:GetShift("1", "support", "P1"), 0, "偶数偏移：Reset 后清空 → 0")
    AssertEqual(bc:GetShift("1", "frontline"), 0, "偶数偏移：Reset 后前线 → 0")
end

-- 场景 16：伤害倍率 / 受伤害倍率（combatModifiers，与卡牌外貌属性编辑器一致）
local function RunCombatModifiersTest()
    print("--- 场景16: 伤害倍率/受伤害倍率（combatModifiers，倍率1不入数组/未匹配默认1/非单位恒空） ---")
    local u = KARDS.CardInterface.CreateMockCard("mul_unit", "unit", "P1", { attack = 2, defense = 2 })

    -- 默认：两数组空；未匹配查询返回默认 1 倍率
    local mods = u:GetCombatModifiers()
    AssertEqual(#mods.outgoing, 0, "默认：伤害倍率数组为空")
    AssertEqual(#mods.incoming, 0, "默认：受伤害倍率数组为空")
    AssertEqual(u:GetCombatMultiplier("outgoing", "Battle.EnemyGroundUnits"), 1, "未匹配：伤害倍率默认 1")
    AssertEqual(u:GetCombatMultiplier("incoming", "Battle.AllSources"), 1, "未匹配：受伤害倍率默认 1")

    -- 伤害倍率（outgoing）：添加规则 + 匹配查询
    AssertEqual(u:AddCombatMultiplier("outgoing", "Battle.EnemyGroundUnits", 2, "敌方陆军单位"), true, "添加伤害倍率规则")
    AssertEqual(u:AddCombatMultiplier("outgoing", "Battle.EnemyHeadquarter", 2, "敌方总部"), true, "添加第二条伤害倍率规则")
    AssertEqual(#u:GetCombatModifiers().outgoing, 2, "伤害倍率数组 2 条")
    AssertEqual(u:GetCombatMultiplier("outgoing", "Battle.EnemyGroundUnits"), 2, "对敌方陆军伤害 ×2")
    AssertEqual(u:GetCombatMultiplier("outgoing", "Battle.EnemyHeadquarter"), 2, "对敌方总部伤害 ×2")
    AssertEqual(u:GetCombatMultiplier("outgoing", "Battle.EnemyUnits"), 1, "未配置目标仍为默认 1")
    local out = u:GetCombatModifiers().outgoing[1]
    AssertEqual(out.targetPath, "Battle.EnemyGroundUnits", "伤害倍率条目含 targetPath（编辑器结构一致）")
    AssertEqual(out.multiplier, 2, "伤害倍率条目 multiplier")
    AssertEqual(out.targetName, "敌方陆军单位", "伤害倍率条目 targetName")

    -- 倍率 1 不入数组（等价无规则）
    AssertEqual(u:AddCombatMultiplier("outgoing", "Battle.EnemyAirUnits", 1, "敌方空军单位"), true, "添加倍率 1 规则：接受但不入数组")
    AssertEqual(#u:GetCombatModifiers().outgoing, 2, "倍率 1 规则不入数组（仍 2 条）")
    AssertEqual(u:GetCombatMultiplier("outgoing", "Battle.EnemyAirUnits"), 1, "倍率 1 目标查询为默认 1")

    -- 同路径覆盖更新；覆盖为 1 时移除该条
    AssertEqual(u:AddCombatMultiplier("outgoing", "Battle.EnemyGroundUnits", 3), true, "同路径覆盖 ×3")
    AssertEqual(#u:GetCombatModifiers().outgoing, 2, "覆盖后数组仍 2 条")
    AssertEqual(u:GetCombatMultiplier("outgoing", "Battle.EnemyGroundUnits"), 3, "覆盖后对敌方陆军 ×3")
    AssertEqual(u:AddCombatMultiplier("outgoing", "Battle.EnemyGroundUnits", 1), true, "覆盖为 1：移除该条")
    AssertEqual(#u:GetCombatModifiers().outgoing, 1, "覆盖为 1 后数组 1 条")
    AssertEqual(u:GetCombatMultiplier("outgoing", "Battle.EnemyGroundUnits"), 1, "移除后查询默认 1")

    -- 受伤害倍率（incoming）：结构与编辑器一致（sourcePath/sourceName）
    AssertEqual(u:AddCombatMultiplier("incoming", "Battle.AllSources", 2, "所有来源"), true, "添加受伤害倍率规则")
    AssertEqual(#u:GetCombatModifiers().incoming, 1, "受伤害倍率数组 1 条")
    AssertEqual(u:GetCombatMultiplier("incoming", "Battle.AllSources"), 2, "受所有来源伤害 ×2")
    local inc = u:GetCombatModifiers().incoming[1]
    AssertEqual(inc.sourcePath, "Battle.AllSources", "受伤害倍率条目含 sourcePath（编辑器结构一致）")
    AssertEqual(inc.multiplier, 2, "受伤害倍率条目 multiplier")
    AssertEqual(inc.sourceName, "所有来源", "受伤害倍率条目 sourceName")

    -- 创建时传入 stats.combatModifiers：规范化（倍率 1 丢弃）
    local u2 = KARDS.CardInterface.CreateMockCard("mul_unit2", "unit", "P1", {
        combatModifiers = {
            outgoing = {
                { targetPath = "Battle.EnemyTank", multiplier = 1.5, targetName = "敌方坦克" },
                { targetPath = "Battle.EnemyInfantry", multiplier = 1, targetName = "敌方步兵" }, -- 应被丢弃
            },
            incoming = {
                { sourcePath = "Battle.EnemyArtillery", multiplier = 2, sourceName = "敌方炮兵" },
            },
        },
    })
    AssertEqual(#u2:GetCombatModifiers().outgoing, 1, "创建传入：倍率 1 条目被丢弃（1.5 保留）")
    AssertEqual(u2:GetCombatMultiplier("outgoing", "Battle.EnemyTank"), 1.5, "创建传入：对敌方坦克 ×1.5")
    AssertEqual(u2:GetCombatMultiplier("outgoing", "Battle.EnemyInfantry"), 1, "创建传入：倍率 1 目标查询默认 1")
    AssertEqual(u2:GetCombatMultiplier("incoming", "Battle.EnemyArtillery"), 2, "创建传入：受敌方炮兵 ×2")

    -- 非单位卡：两数组恒空，不可配置，查询恒 1
    local cmd = KARDS.CardInterface.CreateMockCard("mul_cmd", "command", "P1", {})
    AssertEqual(#cmd:GetCombatModifiers().outgoing, 0, "非单位（指令）：伤害倍率数组空")
    AssertEqual(#cmd:GetCombatModifiers().incoming, 0, "非单位（指令）：受伤害倍率数组空")
    AssertEqual(cmd:AddCombatMultiplier("outgoing", "Battle.EnemyGroundUnits", 2), false, "非单位卡拒绝配置伤害倍率")
    AssertEqual(cmd:GetCombatMultiplier("outgoing", "Battle.EnemyGroundUnits"), 1, "非单位卡查询恒默认 1")
    local hq = KARDS.CardInterface.CreateMockCard("mul_hq", "headquarter", "P1", { defense = 20 })
    AssertEqual(#hq:GetCombatModifiers().incoming, 0, "总部：受伤害倍率数组空")
    AssertEqual(hq:AddCombatMultiplier("incoming", "Battle.AllSources", 2), false, "总部拒绝配置受伤害倍率")
    AssertEqual(hq:GetCombatMultiplier("incoming", "Battle.AllSources"), 1, "总部查询恒默认 1")

    -- 非法参数拒绝
    AssertEqual(u:AddCombatMultiplier("xxx", "p", 2), false, "非法 kind 拒绝")
    AssertEqual(u:AddCombatMultiplier("outgoing", "", 2), false, "空路径拒绝")
    AssertEqual(u:AddCombatMultiplier("outgoing", "p", 0), false, "倍率 0 拒绝")
    AssertEqual(u:AddCombatMultiplier("outgoing", "p", -2), false, "倍率负数拒绝")
end

-- 场景 17：移除动画（0.25s 升 z → 等待 0.5s → 1s 平滑左移 + 逆时针 180°；阵亡不触发移除）
local function RunRemovalAnimationTest()
    print("--- 场景17: 移除动画（0.25s升z → 等待0.5s → 1s平滑左移+逆时针180°，阵亡不触发） ---")
    -- 阵亡 ≠ 移除：卡牌防御归 0（阵亡）不触发 Kards 语义的"移除"；
    -- 仅"移除"操作（RemoveFromField 语义）发生时创建动画（渲染层触发点，本场景验证动画时序）
    local card = KARDS.CardInterface.CreateMockCard("rem_card", "unit", "P1", { attack = 1, defense = 1 })
    card.pos = { x = 50, y = 0, z = 0 } -- 预设卡牌位置（相对牌桌世界坐标）
    card.ang = { p = 0, y = 0, r = 0 }
    local rise, offscreenX = 20, -50

    KARDS.Animation.RealTime = true -- 本场景暂定开启真实时间开关
    local anims = KARDS.Animation:CreateRemovalAnimations(card, rise, offscreenX)
    AssertEqual(anims ~= nil, true, "移除动画组创建成功")
    AssertEqual(anims.shift.delay, 0.75, "左移动画延迟 0.75s 开始（0.25s 升 z + 0.5s 等待）")
    AssertEqual(anims.roll.delay, 0.75, "旋转动画延迟 0.75s 开始（与左移同时）")

    -- 每 0.1 秒采样打印处于渐变动画的卡牌当前渐变值（模拟时钟推进，采样表供断言）
    -- samples 按序：每时间点 3 条（rise / shift / roll）；
    -- 用整数索引 i（t = i*0.1）避免浮点步进迭代次数不稳（2.0/0.1 浮点为 19.999…）
    local samples = {}
    for i = 0, 20 do
        local t = i * 0.1 -- 第 i 个时间点（t = 0 ~ 2.0，步进 0.1）
        for _, name in ipairs({ "rise", "shift", "roll" }) do
            anims[name].StartTime = CurTime() - t -- 模拟已推进 t 秒
            local v = anims[name]:ValueNow()
            samples[#samples + 1] = { t = t, name = name, v = v }
            print(string.format("[t=%.1f] %s 当前渐变值=%.3f", t, name, v)) -- 每 0.1s 打印
        end
    end
    AssertEqual(#samples, 63, "采样点 21 个时间 × 3 动画 = 63")
    -- 按时间点索引取值（tIndex 从 0 起，t = tIndex * 0.1；每个时间点 3 条记录）
    local function At(tIndex, name)
        local rec = samples[tIndex * 3 + 1] -- rise 在组首
        if name == "shift" then rec = samples[tIndex * 3 + 2] end
        if name == "roll" then rec = samples[tIndex * 3 + 3] end
        return rec.v
    end
    -- 断言关键时间点（smooth 期望值用同一表达式计算；真实时间模拟存在 ULP 误差，用容差比较）
    AssertNear(At(1, "rise"), rise * (0.1 / 0.25), 1e-6, "t=0.1：升 z 完成 40%（线性）")
    AssertNear(At(3, "rise"), rise, 1e-6, "t=0.3：升 z 完成（超 0.25s clamp）")
    AssertNear(At(5, "rise"), rise, 1e-6, "t=0.5：升 z 保持（阶段 2 等待期）")
    AssertNear(At(7, "shift"), 50, 1e-6, "t=0.7：左移未开始（等待期保持起始 x=50）")
    AssertNear(At(8, "shift"), 50 + (offscreenX - 50) * (0.05 * 0.05 * (3 - 2 * 0.05)), 1e-6,
        "t=0.8：左移平滑开始（progress=0.05）")
    AssertNear(At(18, "shift"), offscreenX, 1e-6, "t=1.8：左移完成到场外 x=-50")
    AssertNear(At(18, "roll"), 180, 1e-6, "t=1.8：逆时针旋转 180° 完成")
    AssertNear(At(7, "roll"), 0, 1e-6, "t=0.7：旋转未开始")
    AssertNear(At(20, "roll"), 180, 1e-6, "t=2.0：旋转保持 180°（超时 clamp）")
    AssertNear(At(20, "rise"), rise, 1e-6, "t=2.0：升 z 保持（三阶段完成）")
    AssertEqual(card.pos.z, 0, "纯采样 ValueNow 不写回卡牌（ApplyNow 才写回）")

    -- 恢复默认（测试环境保持 false）
    KARDS.Animation.RealTime = false
end

-- 运行全部测试（GMod 控制台 kards_test 或外部 Lua 直接调用）
function RunKardsTests()
    print("==============================================")
    print("KARDS 战斗骨架测试开始")
    print("==============================================")
    TestsPassed, TestsFailed = 0, 0
    RunFormatTest()
    RunBurnTest()
    RunCounterScenario("before", 0, 6, "生效前 before")
    RunCounterScenario("after", 1, 7, "生效后 after")
    RunMultiTableTest()
    RunBattlefieldTest()
    RunDeckTest()
    RunEngageFightTest()
    RunCommandPointTest()
    RunKeywordTest()
    RunInterceptTest()
    RunNetSyncTest()
    RunKeywordEffectTest()
    RunScenario13()
    RunAnimationTest()
    RunCenterShiftTest()
    RunCombatModifiersTest()
    RunRemovalAnimationTest()
    print("==============================================")
    print(("测试完成: 通过 %d, 失败 %d"):format(TestsPassed, TestsFailed))
    print("==============================================")
    return TestsFailed == 0
end

-- GMod 控制台命令：kards_test
if concommand then
    concommand.Add("kards_test", function()
        RunKardsTests()
    end)
end
