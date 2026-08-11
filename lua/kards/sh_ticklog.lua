--[[
    时间刻系统数据层 (Tick Log Data Layer)

    纯 Lua 实现，不依赖 GMod API，可在 GMod 内或外部 Lua 环境运行，
    是未来真实战斗系统与当前测试骨架共用的数据结构层。

    刻度条目格式（战斗系统规划.md 第 3 节）：
      〔〔发起者卡牌, 〔操作类型…〕, 操作?〕, 〔〔受影响卡牌1, 〔经受类型…〕, 操作?〕, ……〕,
       〔〔玩家, 资源类型, 操作〕, ……〕?〕
      -- 第三部分「玩家资源变化列表」可选：记录该刻一方玩家手牌/卡组等张数变化（如抽牌手牌 +3）

    「操作类型」为数组（明确定义：一刻的一张卡可有多个操作类型）：
      - 交战（engage）刻：发起者〔engage, attack, deal_damage〕，
        受影响〔engage, take_damage, counterattack〕
      - 战斗（fight）刻：发起者〔fight, attack, deal_damage〕，
        受影响〔fight, take_damage, counterattack〕

    其中「操作」为可选文本，始终为字符串：
      "+N" 增加  /  "-N" 减少  /  "=N" 设为
    「操作」表示该卡在该刻经受的数值变更——发起者也可能经受变更（如被反击），
    无数值效果操作（压制/抑制/开发等）省略该字段，受影响项为 {卡牌, 〔经受类型…〕}。

    操作类型枚举见战斗系统规划.md 第 9 节（OpTypes 白名单）。

    ------------------------------------------------------------------
    多牌桌隔离与 _G 全局视图（战斗系统规划.md 第 3 节，2026-08-04 已定）：
      - 内部按 tableID 分实例存储（Instances[tableID]），多牌桌互不混淆
      - _G 级全局变量（KARDS_TickLog / KARDS_TickCount / KARDS_TickTiming）
        为「当前激活牌桌」的动态视图：SetActive 切换时同步指向对应实例，
        GMod 单线程处理操作，切换原子，任意时刻读取 _G 变量即当前牌桌数据
      - 反作弊基础：时间刻由服务端权威写入（append-only），客户端仅持只读副本
    ------------------------------------------------------------------
]]

KARDS = KARDS or {}
---@class TickLog 时间刻系统数据层
KARDS.TickLog = KARDS.TickLog or {}

-- _G 级全局变量（规划第 3 节要求；动态指向当前激活牌桌，见文件头注释）
-- 时间刻数组（当前激活牌桌 Ticks 的引用）、当前刻度数、刻度推进时机
_G.KARDS_TickLog = nil
_G.KARDS_TickCount = 0
_G.KARDS_TickTiming = nil

-- 各牌桌实例表：Instances[tableID] = { Ticks, TickCount, PushTiming }
KARDS.TickLog.Instances = KARDS.TickLog.Instances or {}
-- 当前激活牌桌 ID
KARDS.TickLog.ActiveTableID = nil

-- 操作类型白名单（战斗系统规划.md 第 9 节）
KARDS.TickLog.OpTypes = {
    -- 9.1 打出与部署
    play_command = true,
    counter = true, -- 触发反制（SimPlayCard 拦截时 play_command+counter 刻，event_monitor「触发反制」）
    deploy = true,
    activate_counter = true,
    -- 9.2 战场操作
    move = true,
    attack = true,
    retreat = true,
    engage = true,
    fight = true,
    counterattack = true,
    join_battlefield = true,
    join_frontline = true,
    overwatch = true,
    pincer = true,
    -- 9.3 玩家操作
    draw = true,
    extra_draw = true,
    discard = true,
    burn = true,
    copy = true, -- 复制（card 模板复制分支：克隆入手的操作）
    scry = true, -- 选择/观星（card 模板选择分支：窥视卡组不改状态）
    shuffle_into = true, -- 洗入（card 模板洗入分支：手牌/指定卡洗入卡组）
    -- 9.4 生命周期
    death = true,
    remove = true,
    join = true,
    stat_change = true,
    -- 9.5 回合
    turn_begin = true,
    turn_end = true,
    turn_switch = true,
    -- 9.6 战斗结算
    deal_damage = true,
    take_damage = true,
    -- 9.7 效果能力
    suppress = true,
    suppressed = true,
    guarded = true,
    neutralized = true,
    trigger = true,
    passive_effect = true,
    convert = true,
    repair = true,
    develop = true,
    control = true,
    uncontrol = true, -- 解除控制（action 取消分支：归属还原为原玩家）
    immune = true,
    unimmune = true, -- 解除免疫（action 取消分支：移除效果给予的免疫状态）
    unneutralized = true, -- 解除抑制（action 取消分支：恢复被抑制卡牌的关键词和效果）
    summon = true, -- 召唤单位（action 召唤分支：单位入场支援阵线/前线）
    return_to_hand = true, -- 返回手牌（action 返回手牌分支：离场入所有者手牌）
    veteran = true,
    intelligence = true,
    reveal = true, -- 隐蔽揭示（readme 7.2.2 隐蔽：发起攻击或被攻击后揭示并失去隐蔽）
    countdown = true, -- 倒计时 X（readme 7.2.2：每回合结束后 -1，归零触发事件并移除）
    deathrattle = true, -- 亡计（readme 7.2.2：触发关键字效果的经受类型，SimTriggerKeyword）
    command_points = true, -- 指挥点变更（command 模板效果：增加/减少/设为，SimChangeCommandPoints）
    command_slot = true, -- 指挥点槽变更（command 模板效果：增加/减少/设为，SimChangeCommandSlots）
    -- 9.8 对局管控（战场布局作弊检测见第 11 节；联机同步 desync/sync 见第 16 节）
    cheat = true,
    desync = true,
    sync = true,
}

-- 数值变更文本格式：+N / -N / =N
local CHANGE_PATTERN = "^[+-=]%d+$"

-- 玩家资源类型白名单（刻度条目第三部分「玩家资源变化列表」，战斗系统规划.md 第 3 节）：
--   hand 手牌 / deck 卡组（指挥点等 meta 数值日后可扩展复用同通道）
KARDS.TickLog.ResourceTypes = {
    hand = true,
    deck = true,
}

-- 将指定牌桌实例的计数/时机同步到 _G 全局视图（仅当该牌桌为当前激活时）
-- @param tableID string 牌桌唯一标识符
-- @param inst    table   该牌桌的实例
local function SyncGlobalView(tableID, inst)
    if KARDS.TickLog.ActiveTableID == tableID then
        _G.KARDS_TickLog = inst.Ticks
        _G.KARDS_TickCount = inst.TickCount
        _G.KARDS_TickTiming = inst.PushTiming
    end
end

--[[
    创建（开始）一场牌桌的战斗：建立独立时间刻实例并设为当前激活

    @param tableID string 牌桌唯一标识符（多牌桌隔离的键）
    @param timing  string|nil 刻度推进时机（"before" 生效前 / "after" 生效后，缺省 "before"）
    @return table 新创建的牌桌实例
]]
function KARDS.TickLog:Create(tableID, timing)
    local inst = {
        Ticks = {},
        TickCount = 0,
        PushTiming = timing or "before",
    }
    self.Instances[tableID] = inst
    self:SetActive(tableID)
    return inst
end

--[[
    切换当前激活牌桌，并同步 _G 全局视图指向该牌桌

    @param tableID string 牌桌唯一标识符
]]
function KARDS.TickLog:SetActive(tableID)
    self.ActiveTableID = tableID
    local inst = self.Instances[tableID]
    if inst then
        _G.KARDS_TickLog = inst.Ticks
        _G.KARDS_TickCount = inst.TickCount
        _G.KARDS_TickTiming = inst.PushTiming
    else
        _G.KARDS_TickLog = nil
        _G.KARDS_TickCount = 0
        _G.KARDS_TickTiming = nil
    end
end

-- 获取指定牌桌的实例（不存在返回 nil）
function KARDS.TickLog:Get(tableID)
    return self.Instances[tableID]
end

-- 获取当前激活牌桌的实例（未激活返回 nil）
function KARDS.TickLog:GetActive()
    return self.Instances[self.ActiveTableID]
end

-- 操作类型规范化：字符串 → 单元素数组；数组 → 拷贝数组
-- 操作类型是数组（一刻一张卡可有多个操作类型），兼容传字符串的旧调用
local function NormalizeOpTypes(opTypes)
    if type(opTypes) == "table" then
        local copy = {}
        for _, v in ipairs(opTypes) do
            table.insert(copy, v)
        end
        return copy
    end
    return { opTypes }
end

-- 判断操作类型（支持字符串或数组）是否在白名单中（返回 boolean）
-- 数组时每个元素都必须合法，且至少含一个操作类型
function KARDS.TickLog:IsValidOpType(opType)
    if opType == nil then return false end
    local list = type(opType) == "table" and opType or { opType }
    if #list == 0 then return false end
    for _, v in ipairs(list) do
        if self.OpTypes[v] ~= true then return false end
    end
    return true
end

-- 判断「操作」文本是否为合法数值变更格式（+N / -N / =N，返回 boolean）
function KARDS.TickLog:IsValidChange(change)
    return type(change) == "string" and change:match(CHANGE_PATTERN) ~= nil
end

--[[
    推进一刻（追加到指定牌桌时间刻数组末尾）

    刻度条目三段式（战斗系统规划.md 第 3 节）：
      〔发起者〔〔操作类型…〕, 操作?〕, 〔受影响卡牌列表〕, 〔玩家资源变化列表〕?〕

    @param tableID         string 牌桌唯一标识符（不存在则自动创建）
    @param initiatorCard   table 发起者卡牌句柄（遵循 KARDS.CardInterface 约定）
    @param initiatorOpTypes string|table 发起者操作类型（数组；一刻一张卡可有多个操作类型）
    @param targets         table|nil 受影响项列表，每项为
                              { 卡牌句柄, 〔经受类型…〕, 操作? }   -- 操作可选（+N/-N/=N）
    @param initiatorChange string|nil 发起者自身经受的数值变更（可选；如被反击 -3）
    @param resourceChanges table|nil 玩家资源变化列表（可选；刻度条目第三部分），每项为
                              { 玩家, 资源类型, 操作 }             -- 资源类型见 ResourceTypes；操作 +N/-N/=N
    @return boolean 是否推进成功（校验失败返回 false）
]]
function KARDS.TickLog:Push(tableID, initiatorCard, initiatorOpTypes, targets, initiatorChange, resourceChanges)
    local inst = self.Instances[tableID]
    if not inst then
        inst = self:Create(tableID) -- 容错：未 Create 的牌桌自动创建并激活
    end
    if not initiatorCard then
        print("[TickLog] 错误: 缺少发起者卡牌")
        return false
    end
    local iOpTypes = NormalizeOpTypes(initiatorOpTypes)
    if not self:IsValidOpType(iOpTypes) then
        print("[TickLog] 错误: 非法发起者操作类型: " .. tostring(initiatorOpTypes))
        return false
    end
    if initiatorChange ~= nil and not self:IsValidChange(initiatorChange) then
        print("[TickLog] 错误: 非法发起者操作文本: " .. tostring(initiatorChange) .. "（应为 +N / -N / =N）")
        return false
    end
    targets = targets or {}
    for _, t in ipairs(targets) do
        if not t or not t[1] then
            print("[TickLog] 错误: 受影响项缺少卡牌")
            return false
        end
        t[2] = NormalizeOpTypes(t[2]) -- 经受类型规范化为数组
        if not self:IsValidOpType(t[2]) then
            print("[TickLog] 错误: 非法经受类型: " .. tostring(t[2]))
            return false
        end
        if t[3] ~= nil and not self:IsValidChange(t[3]) then
            print("[TickLog] 错误: 非法操作文本: " .. tostring(t[3]) .. "（应为 +N / -N / =N）")
            return false
        end
    end
    -- 玩家资源变化列表校验：{ 玩家, 资源类型, 操作 }，操作格式同 +N/-N/=N
    for _, rc in ipairs(resourceChanges or {}) do
        if not rc or not rc[1] then
            print("[TickLog] 错误: 玩家资源变化项缺少玩家")
            return false
        end
        if self.ResourceTypes[rc[2]] ~= true then
            print("[TickLog] 错误: 非法资源类型: " .. tostring(rc[2]) .. "（应为 hand / deck）")
            return false
        end
        if not self:IsValidChange(rc[3]) then
            print("[TickLog] 错误: 非法资源操作文本: " .. tostring(rc[3]) .. "（应为 +N / -N / =N）")
            return false
        end
    end

    local initiator = { initiatorCard, iOpTypes }
    if initiatorChange ~= nil then
        table.insert(initiator, initiatorChange)
    end
    local tick = { initiator, targets }
    if resourceChanges and #resourceChanges > 0 then
        table.insert(tick, resourceChanges) -- 第三部分：玩家资源变化列表（可选）
    end
    table.insert(inst.Ticks, tick)
    inst.TickCount = #inst.Ticks
    SyncGlobalView(tableID, inst)
    return true
end

-- 获取指定牌桌的指定刻（1 起），越界返回 nil
function KARDS.TickLog:GetTick(tableID, i)
    local inst = self.Instances[tableID]
    return inst and inst.Ticks[i] or nil
end

-- 获取一刻的玩家资源变化列表（刻度条目第三部分；无则返回空表）
-- @param tick table 一刻条目（GetTick 返回值）
-- @return table { {玩家, 资源类型, 操作}, ... }
function KARDS.TickLog:GetResourceChanges(tick)
    return tick and tick[3] or {}
end

-- 指定牌桌的当前刻度数
function KARDS.TickLog:Count(tableID)
    local inst = self.Instances[tableID]
    return inst and inst.TickCount or 0
end

-- 获取指定牌桌的全部刻度（嵌套数组格式，供序列化/历史预览）
function KARDS.TickLog:GetAll(tableID)
    local inst = self.Instances[tableID]
    return inst and inst.Ticks or {}
end

-- 清空指定牌桌的时间刻（对局结束调用）
function KARDS.TickLog:Clear(tableID)
    local inst = self.Instances[tableID]
    if inst then
        inst.Ticks = {}
        inst.TickCount = 0
        SyncGlobalView(tableID, inst)
    end
end
