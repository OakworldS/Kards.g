--[[
    战场布局数据层 (Battlefield Layout)

    纯 Lua 实现，不依赖 GMod API；多牌桌按 tableID 分实例隔离，
    与 TickLog / EngineHooks 的 tableID 隔离体系一致（战斗系统规划.md 第 11 节）。

    布局规则（2026-08-04 初版，2026-08-05 自动居中修订，来源：readme.md 7.1 战线规则）：
      - 双方各有一条支援阵线（数组，固定 SLOT_COUNT 槽，默认全 nil），
        前线（数组，固定 SLOT_COUNT 槽，默认全 nil）为双方争夺区域
      - 自动居中机制（2026-08-05 定）：
          * 任一阵线（支援阵线 / 前线）在布局变化后，全部卡牌自动居中重排
          * 奇数张牌 → 完美居中；偶数张牌 → 居中靠左（右端多出 1 个空槽）
            例（SLOT_COUNT=5）：1:[,,x,,] / 2:[,x,x,,] / 3:[,x,x,x,] / 4:[x,x,x,x,] / 5:[x,x,x,x,x]
          * 居中公式用 SLOT_COUNT（阵线最大值）：修改最大值后公式自动生效（GetCenteredStart）
      - 同一阵线上每一张牌的间距 = 1（SPACING；客户端渲染 / 偶数偏移共用）
      - 双方支援阵线始终、无论如何都有一个「总部」卡牌对象（headquarter 类型，防御 20），
        参与居中计数（不再恒驻槽 3），不可被替换 / 移除 / 消灭
      - 部署为受限选位（2026-08-05 定）：
          * 只能选择当前支援阵线上相邻目标的左侧或右侧（点击目标卡所在槽 = 其左侧；
            点击目标右侧空槽 = 其右侧），允许从两个目标之间插入
          * 选择后整线自动居中；若目标槽位没有相邻目标（点击远离卡群的空槽），
            自动移动到最近目标旁（不阻止部署）
      - 战局变化通过槽位操作表达（2026-08-04 定）：
          * 替换：部署（受限选位）/ 加入战场（自动首个空槽）/ 被消灭（清槽）/ 被移除（清槽）
          * 跨数组移动：移到前线（支援阵线槽 → 前线槽）/ 撤退（前线槽 → 支援阵线槽）/
                        移动（同移到前线）；目标槽位缺省自动首个空槽
          * 每次槽位变化后，涉及到的阵线自动居中重排
      - 前线的所有槽位必须是同一阵营：进入前线时以上一刻前线阵营（FrontlineOwner）为基准，
        他方单位试图进入已控制的前线 → 拒绝进入并返回「前线已被敌方占领」（2026-09-26 缺口 F：
        不再立即停局，同时存在两方单位的一致性由刻级校验 KARDS.Battle:VerifyFrontlineExclusive 追溯）
      - 前线空出后（FrontlineOwner = nil），任一方可进入，实现"争夺控制权"
      - 反作弊基础：布局校验由服务端权威执行，停止后所有操作入口拒绝执行

    操作类型复用第 9 节枚举（deploy / join_battlefield / move / retreat / death / remove）；
    作弊刻使用新枚举 `cheat`（9.8 对局管控），由 Battle 骨架在作弊发生时写入时间刻，供审计
    （刻级前线一致性校验定位到作弊者后写入）。
]]

KARDS = KARDS or {}
---@class Battlefield 战场布局数据层
KARDS.Battlefield = KARDS.Battlefield or {}

-- 布局常量（战斗系统规划.md 第 11.1 节）
KARDS.Battlefield.SLOT_COUNT = 5 -- 阵线最大值（支援阵线 / 前线共用；自动居中公式按此计算，修改后自动生效）
KARDS.Battlefield.SPACING = 1 -- 同一阵线上卡牌之间的间距（布局 / 客户端偶数偏移共用；偶数时右移 0.5*SPACING）
KARDS.Battlefield.MAX_FRONTLINE_SLOTS = 5 -- 前线槽位（全为单位；与 SLOT_COUNT 一致，保留兼容别名）
KARDS.Battlefield.HQ_DEFENSE = 20 -- 总部初始防御

-- 各牌桌实例：Instances[tableID] = { SupportLines, Frontline, FrontlineOwner, Cheater, Stopped }
KARDS.Battlefield.Instances = KARDS.Battlefield.Instances or {}

-- 找第一个空槽（1..SLOT_COUNT；自动居中后阵线无空洞，首个空槽即卡群右侧；返回 index 或 nil）
local function FirstEmpty(line)
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        if line[i] == nil then return i end
    end
    return nil
end

-- 阵线非空卡牌计数（含总部）
local function CountUnits(line)
    local n = 0
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        if line[i] ~= nil then n = n + 1 end
    end
    return n
end

-- 收集阵线上按槽位顺序排列的非空卡牌（含总部）
local function GetOrderedCards(line)
    local cards = {}
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        if line[i] ~= nil then cards[#cards + 1] = line[i] end
    end
    return cards
end

-- 自动居中：将阵线上全部卡牌（含总部）按槽位顺序重排到居中位置
-- 奇数居中 / 偶数居中靠左；间距由客户端按 SPACING 渲染，本层只负责槽位重排。
-- @param line  table 阵线数组（就地修改）
-- @param cards table|nil 卡牌列表（缺省 = 按当前槽位顺序收集）
local function CenterLine(line, cards)
    cards = cards or GetOrderedCards(line)
    local lineSize = KARDS.Battlefield.SLOT_COUNT
    for i = 1, lineSize do line[i] = nil end -- 清空
    local start = KARDS.Battlefield:GetCenteredStart(#cards)
    for k, card in ipairs(cards) do
        line[start + k - 1] = card
    end
end

-- 受限选位 + 自动居中：将 card 插入 line 的目标槽位位置（占用 = 插入到该卡左侧 / 空槽 = 放入该处），
-- 随后整线自动居中（奇数居中 / 偶数居中靠左）。若目标槽位没有相邻目标，自动靠向最近目标（不阻止）。
-- @param line      table 阵线数组（就地修改）
-- @param card      table 单位卡牌句柄
-- @param slotIndex number 目标槽位（1..SLOT_COUNT）
-- @return boolean 是否成功（false = 阵线已满）
local function InsertCentered(line, card, slotIndex)
    if CountUnits(line) >= KARDS.Battlefield.SLOT_COUNT then return false end
    local cards = GetOrderedCards(line)
    local insertAfter = 0
    for i = 1, slotIndex - 1 do
        if line[i] ~= nil then insertAfter = insertAfter + 1 end -- 目标槽位左侧的卡牌数 = 插入位置
    end
    table.insert(cards, insertAfter + 1, card)
    CenterLine(line, cards)
    return true
end

-- 查找卡牌所在位置：返回 (所在数组, 槽位 index) 或 (nil, nil)
local function FindCard(inst, card)
    for _, line in pairs(inst.SupportLines) do
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            if line[i] == card then return line, i end
        end
    end
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        if inst.Frontline[i] == card then return inst.Frontline, i end
    end
    return nil, nil
end

--[[
    创建（开始）一场牌桌的战场布局：
    双方支援阵线各建一张总部卡（headquarter，防御 20，居中于槽 3）+ 空前线

    @param tableID string 牌桌唯一标识符
    @param players table|nil 玩家标识列表（缺省 {"P1", "P2"}）
    @return table 新创建的布局实例
]]
function KARDS.Battlefield:Create(tableID, players)
    local support = {}
    for _, p in ipairs(players or { "P1", "P2" }) do
        local hq = KARDS.CardInterface.CreateMockCard("HQ_" .. p, "headquarter", p,
            { attack = 0, defense = KARDS.Battlefield.HQ_DEFENSE })
        local line = {}
        for i = 1, self.SLOT_COUNT do line[i] = nil end
        CenterLine(line, { hq }) -- 总部参与居中（首张 = 居中，位于槽 3）
        support[p] = line
    end
    local inst = {
        SupportLines = support,
        Frontline = {}, -- 前线固定 SLOT_COUNT 槽（全 nil）
        FrontlineOwner = nil, -- 上一刻前线阵营（进入前线校验基准；空出后为 nil）
        Cheater = nil, -- 作弊方（对局停止后记录）
        Stopped = false, -- 对局是否已停止（作弊 / 总部被摧毁后冻结所有操作）
        Players = players or { "P1", "P2" }, -- 玩家标识列表（总部被摧毁胜负判定用）
        HQDestroyed = {}, -- 已摧毁总部：HQDestroyed[player] = 摧毁顺序号（1 = 最先被摧毁）
        GameOver = nil, -- 对局结束信息 { winner = player, loser = player }（总部被摧毁结算；nil = 未结束）
    }
    for i = 1, self.SLOT_COUNT do inst.Frontline[i] = nil end
    self.Instances[tableID] = inst
    return inst
end

-- 获取指定牌桌的布局实例（不存在返回 nil）
function KARDS.Battlefield:Get(tableID)
    return self.Instances[tableID]
end

-- 获取指定牌桌、指定玩家的支援阵线数组（固定 SLOT_COUNT 槽，总部随阵线居中）
function KARDS.Battlefield:GetSupport(tableID, owner)
    local inst = self.Instances[tableID]
    return inst and inst.SupportLines[owner] or nil
end

-- 获取指定牌桌的前线数组（固定 SLOT_COUNT 槽）
function KARDS.Battlefield:GetFrontline(tableID)
    local inst = self.Instances[tableID]
    return inst and inst.Frontline or nil
end

-- 获取指定牌桌、指定玩家的总部卡牌对象（始终存在；参与居中，槽位随阵线卡牌数变化，不再恒驻槽 3）
function KARDS.Battlefield:GetHQ(tableID, owner)
    local support = self:GetSupport(tableID, owner)
    if not support then return nil end
    for i = 1, self.SLOT_COUNT do
        local card = support[i]
        if card and card:GetType() == "headquarter" then return card end
    end
    return nil
end

--[[
    计算居中起始槽位（自动居中核心公式）

    奇数张牌 → 完美居中；偶数张牌 → 居中靠左（floor 向下取整，右端多出 1 个空槽）。
    例（lineSize=5）：1→3 / 2→2 / 3→2 / 4→1 / 5→1；lineSize=7：1→4 / 2→3 / 3→3 / 4→2 / 6→1。

    @param count    number 阵线上卡牌数量
    @param lineSize number|nil 阵线最大值（缺省 SLOT_COUNT；以后修改阵线最大值时按新值计算，自动生效）
    @return number 起始槽位（1..lineSize，自动 clamp）
]]
function KARDS.Battlefield:GetCenteredStart(count, lineSize)
    lineSize = lineSize or self.SLOT_COUNT
    count = math.max(0, math.min(lineSize, count or 0))
    return math.floor((lineSize - count) / 2) + 1
end

--[[
    查找卡牌所在阵线（轰炸机拦截判定用，readme 7.3 战斗机拦截）

    @param tableID string 牌桌唯一标识符
    @param card    table 卡牌句柄
    @return string|nil zone 所在阵线（"support" 支援阵线 / "frontline" 前线）
    @return string|nil owner 该阵线归属玩家（前线取 FrontlineOwner；不在场返回 nil, nil）
]]
function KARDS.Battlefield:FindCardZone(tableID, card)
    local inst = self.Instances[tableID]
    if not inst then return nil, nil end
    for owner, line in pairs(inst.SupportLines) do
        for i = 1, self.SLOT_COUNT do
            if line[i] == card then return "support", owner end
        end
    end
    for i = 1, self.SLOT_COUNT do
        if inst.Frontline[i] == card then
            return "frontline", inst.FrontlineOwner or card:GetOwner()
        end
    end
    return nil, nil
end

--[[
    查找卡牌所在阵线数组与槽位（公开；控制落位/回位等需要槽位的场景用）

    @param tableID string 牌桌唯一标识符
    @param card    table 卡牌句柄
    @return table|nil line 所在阵线数组（支援阵线或前线；不在场返回 nil）
    @return number|nil slot 槽位（1..SLOT_COUNT）
]]
function KARDS.Battlefield:FindCardSlot(tableID, card)
    local inst = self.Instances[tableID]
    if not inst then return nil, nil end
    return FindCard(inst, card)
end

--[[
    查询指定玩家的支援阵线是否已满（含总部；readme 7.1 控制规则「支援阵线已满」判定用）

    @param tableID string 牌桌唯一标识符
    @param owner   string 玩家标识
    @return boolean 已满返回 true（阵线不存在也按已满处理，保守拒绝）
]]
function KARDS.Battlefield:IsSupportFull(tableID, owner)
    local line = self:GetSupport(tableID, owner)
    if not line then return true end
    return CountUnits(line) >= self.SLOT_COUNT
end

--[[
    查询前线是否已满（含前线上的全部单位）

    @param tableID string 牌桌唯一标识符
    @return boolean 已满返回 true（前线不存在也按已满处理）
]]
function KARDS.Battlefield:IsFrontlineFull(tableID)
    local line = self:GetFrontline(tableID)
    if not line then return true end
    return CountUnits(line) >= self.SLOT_COUNT
end

--[[
    获取指定阵线的占用单位列表（轰炸机拦截判定用；含总部等所有占用槽位）

    @param tableID string 牌桌唯一标识符
    @param zone    string 阵线（"support" 支援阵线 / "frontline" 前线）
    @param owner   string|nil 阵线归属玩家（支援阵线必须传；前线可缺省）
    @return table 单位卡牌列表（非 nil 槽位，顺序为槽位序）
]]
function KARDS.Battlefield:GetZoneUnits(tableID, zone, owner)
    local inst = self.Instances[tableID]
    if not inst then return {} end
    local line
    if zone == "support" then
        line = owner and inst.SupportLines[owner] or nil
    elseif zone == "frontline" then
        line = inst.Frontline
    end
    local units = {}
    if line then
        for i = 1, self.SLOT_COUNT do
            if line[i] ~= nil then table.insert(units, line[i]) end
        end
    end
    return units
end

-- 获取指定牌桌的上一刻前线阵营（nil = 前线为空，可被任一方进入）
function KARDS.Battlefield:GetFrontlineOwner(tableID)
    local inst = self.Instances[tableID]
    return inst and inst.FrontlineOwner or nil
end

-- 指定牌桌的对局是否已停止（作弊后为 true）
function KARDS.Battlefield:IsStopped(tableID)
    local inst = self.Instances[tableID]
    return inst and inst.Stopped or false
end

-- 指定牌桌的作弊方（未作弊返回 nil）
function KARDS.Battlefield:GetCheater(tableID)
    local inst = self.Instances[tableID]
    return inst and inst.Cheater or nil
end

--[[
    停止对局（作弊判定触发）：标记作弊方并冻结布局

    @param tableID string 牌桌唯一标识符
    @param cheater string 作弊方玩家标识
    @param reason  string 作弊原因（用于审计输出）
]]
function KARDS.Battlefield:Stop(tableID, cheater, reason)
    local inst = self.Instances[tableID]
    if not inst or inst.Stopped then return end
    inst.Stopped = true
    inst.Cheater = cheater
    print("[Battlefield] 对局停止（作弊）: 作弊方=" .. tostring(cheater) .. " 原因=" .. tostring(reason))
    -- 作弊停止事件（2026-08-18 规划 D7）：此前实体层无收口（客户端仅零散失败提示），
    -- 实体层订阅后向参战玩家广播冻结提示并停回合超时定时器
    if KARDS.EffectRegistry then
        KARDS.EffectRegistry.Trigger(tableID, KARDS.EffectRegistry.EVENTS.BattleStopped,
            { cheater = cheater, reason = reason })
    end
end

-- 指定牌桌对局是否已结束（总部被摧毁，正常结算；区别于作弊停止）
function KARDS.Battlefield:IsGameOver(tableID)
    local inst = self.Instances[tableID]
    return not not (inst and inst.GameOver)
end

-- 获取对局结束信息（nil = 未结束）：{ winner = player, loser = player }
function KARDS.Battlefield:GetGameOver(tableID)
    local inst = self.Instances[tableID]
    return inst and inst.GameOver or nil
end

--[[
    停止对局（总部被摧毁的正常结算）：冻结布局与操作，记录胜负

    @param tableID string 牌桌唯一标识符
    @param winner  string 胜利方玩家标识
    @param loser   string 失败方玩家标识
]]
function KARDS.Battlefield:StopByVictory(tableID, winner, loser)
    local inst = self.Instances[tableID]
    if not inst or inst.Stopped then return end
    inst.Stopped = true
    inst.GameOver = { winner = winner, loser = loser }
    print(("[Battlefield] 对局结束: 胜利方=%s 失败方=%s"):format(tostring(winner), tostring(loser)))
end

--[[
    检查指定玩家总部是否被摧毁（防御力 ≤ 0，readme 7.1：摧毁敌方总部即胜利）。

    总部被摧毁后：记录摧毁顺序（HQDestroyed[player] = 顺序号）→ 判定胜负 →
    停止对局（StopByVictory）→ 触发 GameOver 事件（实体层订阅广播结算动画）。

    胜负判定（readme 7.1 注：若双方总部都被摧毁，最早被摧毁的一方失败）：
      单毁   → 被摧毁方失败，另一方胜利；
      双毁   → 摧毁顺序较早的一方失败（另一方胜利）。

    幂等：已记录摧毁 / 对局已停止时直接返回 false（同一总部不重复判定）。

    @param tableID string 牌桌唯一标识符
    @param owner   string 总部所有者玩家标识
    @return boolean 是否本次判定为总部被摧毁（首次判定 true，已判定/未摧毁 false）
]]
function KARDS.Battlefield:CheckHQDestroyed(tableID, owner)
    local inst = self.Instances[tableID]
    if not inst or inst.Stopped or inst.HQDestroyed[owner] then return false end
    local hq = self:GetHQ(tableID, owner)
    if not hq or (hq.GetStat and (hq:GetStat("defense") or 0) > 0) then return false end
    -- 记录摧毁顺序（1 = 最先被摧毁）
    inst.HQDestroyOrder = (inst.HQDestroyOrder or 0) + 1
    inst.HQDestroyed[owner] = inst.HQDestroyOrder
    -- 胜负判定：单毁 = 被摧毁方失败；双毁 = 最早被摧毁的一方失败
    local p1, p2 = inst.Players[1], inst.Players[2]
    local winner, loser
    if inst.HQDestroyed[p1] and inst.HQDestroyed[p2] then
        loser = (inst.HQDestroyed[p1] < inst.HQDestroyed[p2]) and p1 or p2
        winner = (loser == p1) and p2 or p1
    elseif inst.HQDestroyed[p1] then
        loser, winner = p1, p2
    else
        loser, winner = p2, p1
    end
    self:StopByVictory(tableID, winner, loser)
    -- GameOver 事件（实体层订阅：广播结算 + 移除被摧毁总部实体）
    if KARDS.EffectRegistry and KARDS.EffectRegistry.EVENTS.GameOver then
        KARDS.EffectRegistry.Trigger(tableID, KARDS.EffectRegistry.EVENTS.GameOver,
            { winner = winner, loser = loser, destroyed = owner })
    end
    return true
end

-- 前线空出后重置控制方（供内部操作调用）
local function ResetFrontlineOwnerIfEmpty(inst)
    if CountUnits(inst.Frontline) == 0 then
        inst.FrontlineOwner = nil
    end
end

--[[
    部署：将单位加入本方支援阵线并自动居中（受限选位，2026-08-05 定）

    部署位置选择：
      - 只能选择当前支援阵线上相邻目标的左侧或右侧（点击目标卡所在槽位 = 其左侧；
        点击目标右侧空槽 = 其右侧），允许从两个目标之间插入（点击目标卡所在槽位）
      - 选择后整线自动居中（奇数居中 / 偶数居中靠左）
      - 若目标槽位没有相邻目标（点击远离卡群的空槽），自动移动到最近目标旁（不阻止部署）

    @param tableID   string 牌桌唯一标识符
    @param card      table 单位卡牌句柄（headquarter 拒绝：总部始终唯一驻留，不可被替换/移除/消灭）
    @param slotIndex number 目标槽位（1..SLOT_COUNT；占用时插入到该卡左侧，空槽则放入该处）
    @return boolean, string 是否成功；失败原因（no_table / stopped / hq_immovable /
                           already_on_field / invalid_slot / support_full）
]]
function KARDS.Battlefield:AddToSupport(tableID, card, slotIndex)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    if inst.Stopped then return false, "stopped" end
    if not card or card:GetType() == "headquarter" then return false, "hq_immovable" end
    if type(slotIndex) ~= "number" or slotIndex < 1 or slotIndex > self.SLOT_COUNT then
        return false, "invalid_slot"
    end

    local support = inst.SupportLines[card:GetOwner()]
    if not support then return false, "no_support_line" end
    local line, _ = FindCard(inst, card)
    if line then return false, "already_on_field" end

    -- 受限选位 + 自动居中（阵线已满则拒绝）
    if not InsertCentered(support, card, slotIndex) then return false, "support_full" end
    return true
end

--[[
    固定槽位部署（已弃用：不自动居中、不重排，单位精确落入目标空槽，其余卡保持
    当前槽位坐标——会在单位与总部间留空槽。2026-08-10 反馈后主路径改回
    AddToSupport（受限选位 + 自动居中），本函数保留供效果/测试等特殊用途）。
    与 AddToSupport（受限选位 + 自动居中）互斥：目标槽被占 → 返回
    false, "slot_occupied"。

    @param tableID   string 牌桌唯一标识符
    @param card      table 单位卡牌句柄（headquarter 拒绝：总部始终唯一驻留）
    @param slotIndex number 目标槽位（1..SLOT_COUNT，必须为空）
    @return boolean, string 是否成功；失败原因（no_table / stopped / hq_immovable /
                           invalid_slot / no_support_line / already_on_field / slot_occupied）
]]
function KARDS.Battlefield:AddToSupportFixed(tableID, card, slotIndex)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    if inst.Stopped then return false, "stopped" end
    if not card or card:GetType() == "headquarter" then return false, "hq_immovable" end
    if type(slotIndex) ~= "number" or slotIndex < 1 or slotIndex > self.SLOT_COUNT then
        return false, "invalid_slot"
    end

    local support = inst.SupportLines[card:GetOwner()]
    if not support then return false, "no_support_line" end
    local line, _ = FindCard(inst, card)
    if line then return false, "already_on_field" end

    -- 固定槽位：目标槽必须为空（被占则拒绝，调用方回退受限选位居中）
    if support[slotIndex] ~= nil then return false, "slot_occupied" end
    support[slotIndex] = card
    return true
end

--[[
    加入战场：将单位放入本方支援阵线的首个空槽（效果拉入场等，非玩家选位），随后自动居中

    @param tableID string 牌桌唯一标识符
    @param card    table 单位卡牌句柄
    @return boolean, string 是否成功；失败原因（support_full / 其余同 AddToSupport）
]]
function KARDS.Battlefield:JoinBattlefield(tableID, card)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    if inst.Stopped then return false, "stopped" end
    if not card or card:GetType() == "headquarter" then return false, "hq_immovable" end

    local support = inst.SupportLines[card:GetOwner()]
    if not support then return false, "no_support_line" end
    local line, _ = FindCard(inst, card)
    if line then return false, "already_on_field" end

    local slot = FirstEmpty(support)
    if not slot then return false, "support_full" end
    support[slot] = card
    CenterLine(support) -- 加入后整线自动居中
    return true
end

--[[
    加入前线：将单位直接放入前线首个空槽（效果拉入场，非玩家移动；含阵营一致性作弊检测）

    与 MoveToFrontline 的区别：单位不在场上（手牌/效果创建），直接加入前线而非从支援阵线移动。
    阵营一致性校验与 MoveToFrontline 一致：上一刻前线阵营与进入单位阵营必须一致，
    否则拒绝进入并返回原因（2026-09-26 缺口 F：不再立即停局，一致性由刻级校验兜底）。

    @param tableID string 牌桌唯一标识符
    @param card    table 单位卡牌句柄
    @return boolean, string 是否成功；失败原因（"前线已被敌方占领" 表示阵营冲突被拒）
]]
function KARDS.Battlefield:JoinFrontline(tableID, card)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    if inst.Stopped then return false, "stopped" end
    if not card or card:GetType() == "headquarter" then return false, "hq_immovable" end

    local frontline = inst.Frontline
    local line, _ = FindCard(inst, card)
    if line then return false, "already_on_field" end

    -- 阵营一致性校验（2026-09-26 缺口 F 软失败）：上一刻前线阵营与进入单位阵营必须一致，
    -- 否则拒绝进入（刻级校验 KARDS.Battle:VerifyFrontlineExclusive 负责追溯作弊者）
    local owner = card:GetOwner()
    local lastOwner = inst.FrontlineOwner
    if lastOwner and lastOwner ~= owner then
        return false, "前线已被敌方占领"
    end

    local slot = FirstEmpty(frontline)
    if not slot then return false, "frontline_full" end
    frontline[slot] = card
    CenterLine(frontline) -- 加入后整线自动居中
    inst.FrontlineOwner = owner
    return true
end

--[[
    加入前线指定槽位（效果落位 / 控制反转用，非玩家移动）

    与 JoinFrontline / MoveToFrontline 的区别：
      - 指定槽位（受限选位 + 自动居中），而非首个空槽；
      - opts.forceOwner 控制反转（readme 7.1 控制规则：控制前线单位时前线反转为
        新控制者占领）：跳过「上一刻前线阵营一致」作弊校验，直接令 FrontlineOwner
        = forceOwner，再把卡插入前线 slotIndex 位置（控制是合法操作，不触发作弊）。

    @param tableID   string 牌桌唯一标识符
    @param card      table 单位卡牌句柄
    @param slotIndex number 前线目标槽位（1..SLOT_COUNT；占用时插入到该卡左侧）
    @param opts      table|nil { forceOwner = string|nil } 控制反转时传新控制者
    @return boolean, string 是否成功；失败原因（"前线已被敌方占领" 阵营冲突被拒 /
                           frontline_full 前线已满）
]]
function KARDS.Battlefield:AddToFrontline(tableID, card, slotIndex, opts)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    if inst.Stopped then return false, "stopped" end
    if not card or card:GetType() == "headquarter" then return false, "hq_immovable" end
    if type(slotIndex) ~= "number" or slotIndex < 1 or slotIndex > self.SLOT_COUNT then
        return false, "invalid_slot"
    end
    local line, _ = FindCard(inst, card)
    if line then return false, "already_on_field" end

    local forceOwner = opts and opts.forceOwner or nil
    local enterOwner = forceOwner or card:GetOwner()
    local lastOwner = inst.FrontlineOwner
    -- 阵营一致性：控制反转（forceOwner）跳过校验（合法操作）；其余须与上一刻前线阵营一致，
    -- 否则拒绝进入（2026-09-26 缺口 F：不再立即停局，一致性由刻级校验兜底）
    if not forceOwner and lastOwner and lastOwner ~= enterOwner then
        return false, "前线已被敌方占领"
    end
    -- 前线已满则拒绝（先校验后落位，失败不改变任何状态）
    if CountUnits(inst.Frontline) >= self.SLOT_COUNT then
        return false, "frontline_full"
    end
    if not InsertCentered(inst.Frontline, card, slotIndex) then
        return false, "frontline_full"
    end
    inst.FrontlineOwner = enterOwner
    return true
end

--[[
    原地置换阵线中的卡牌（2026-09-26 缺口 J 转换）

    保持阵线与槽位不变，仅把该槽位元素替换为新卡（不改动数组长度，因此不需要居中
    重排）。既有 AddToSupport / JoinBattlefield 都会重排居中，不适用于原地替换。

    @param tableID string 牌桌唯一标识符
    @param oldCard table 旧卡牌句柄（须在场上）
    @param newCard table 新卡牌句柄
    @return boolean 是否成功（旧卡不在场返回 false）
]]
function KARDS.Battlefield:ReplaceCard(tableID, oldCard, newCard)
    local inst = self.Instances[tableID]
    if not inst then return false end
    if not oldCard or not newCard then return false end
    local line, slot = FindCard(inst, oldCard)
    if not line or not slot then return false end
    line[slot] = newCard
    return true
end

--[[
    移到前线：单位从本方支援阵线槽位跨数组移动到前线槽位（含阵营一致性作弊检测），双方阵线自动居中

    顺序：先校验（目标槽合法 + 阵营一致），再从支援阵线取槽（清空）、受限选位填入前线；
    阵营冲突时拒绝进入且不改变任何布局状态（2026-09-26 缺口 F：不再立即停局，
    一致性由刻级校验兜底）。

    @param tableID   string 牌桌唯一标识符
    @param card      table 单位卡牌句柄
    @param slotIndex number|nil 前线目标槽位（缺省自动首个空槽；占用时插入到该卡左侧）
    @return boolean, string 是否成功；失败原因（"前线已被敌方占领" 阵营冲突被拒）
]]
function KARDS.Battlefield:MoveToFrontline(tableID, card, slotIndex)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    if inst.Stopped then return false, "stopped" end
    if not card or card:GetType() == "headquarter" then return false, "hq_immovable" end

    local frontline = inst.Frontline
    local targetSlot = slotIndex
    if targetSlot then
        if type(targetSlot) ~= "number" or targetSlot < 1 or targetSlot > self.SLOT_COUNT then
            return false, "invalid_slot"
        end
    else
        targetSlot = FirstEmpty(frontline)
        if not targetSlot then return false, "frontline_full" end
    end

    -- 阵营一致性校验（2026-09-26 缺口 F 软失败）：上一刻前线阵营与进入单位阵营必须一致，
    -- 否则拒绝进入（刻级校验 KARDS.Battle:VerifyFrontlineExclusive 负责追溯作弊者）
    local owner = card:GetOwner()
    local lastOwner = inst.FrontlineOwner
    if lastOwner and lastOwner ~= owner then
        return false, "前线已被敌方占领"
    end

    -- 从本方支援阵线取槽（先校验后修改，作弊时不改变布局）
    local support = inst.SupportLines[owner]
    if not support then return false, "no_support_line" end
    local fromSlot = nil
    for i = 1, self.SLOT_COUNT do
        if support[i] == card then fromSlot = i break end
    end
    if not fromSlot then return false, "not_in_support" end

    support[fromSlot] = nil
    CenterLine(support) -- 源支援阵线移除后自动居中
    -- 前线受限选位 + 自动居中（前线已满则拒绝）
    if not InsertCentered(frontline, card, targetSlot) then
        return false, "frontline_full"
    end
    inst.FrontlineOwner = owner
    return true
end

--[[
    撤退：单位从前线槽位跨数组移回本方支援阵线槽位，双方阵线自动居中

    @param tableID   string 牌桌唯一标识符
    @param card      table 单位卡牌句柄
    @param slotIndex number|nil 支援阵线目标槽位（缺省自动首个空槽；占用时插入到该卡左侧）
    @return boolean, string 是否成功；失败原因（not_in_frontline / support_full / invalid_slot）
    注：支援阵线已满时退回所有者手牌（readme 7.1 撤退规则）归正式版实现。
]]
function KARDS.Battlefield:Retreat(tableID, card, slotIndex)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    if inst.Stopped then return false, "stopped" end
    if not card or card:GetType() == "headquarter" then return false, "hq_immovable" end

    local frontline = inst.Frontline
    local fromSlot = nil
    for i = 1, self.SLOT_COUNT do
        if frontline[i] == card then fromSlot = i break end
    end
    if not fromSlot then return false, "not_in_frontline" end

    local support = inst.SupportLines[card:GetOwner()]
    local targetSlot = slotIndex
    if targetSlot then
        if type(targetSlot) ~= "number" or targetSlot < 1 or targetSlot > self.SLOT_COUNT then
            return false, "invalid_slot"
        end
    else
        targetSlot = FirstEmpty(support)
        if not targetSlot then return false, "support_full" end
    end

    frontline[fromSlot] = nil
    CenterLine(frontline) -- 前线移除后自动居中
    -- 支援阵线受限选位 + 自动居中（已满则拒绝）
    if not InsertCentered(support, card, targetSlot) then
        return false, "support_full"
    end
    ResetFrontlineOwnerIfEmpty(inst) -- 前线空出后控制方重置（争夺控制权）
    return true
end

--[[
    被消灭 / 被移除：将单位从所在槽位清除（无论支援阵线或前线），并自动居中

    @param tableID string 牌桌唯一标识符
    @param card    table 单位卡牌句柄（headquarter 拒绝：总部不可被消灭/移除）
    @return boolean, string 是否成功；失败原因（hq_immovable / not_on_field）
]]
function KARDS.Battlefield:RemoveFromField(tableID, card)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    if inst.Stopped then return false, "stopped" end
    if not card or card:GetType() == "headquarter" then return false, "hq_immovable" end

    local line, idx = FindCard(inst, card)
    if not line then return false, "not_on_field" end

    line[idx] = nil
    CenterLine(line) -- 移除后整线自动居中
    if line == inst.Frontline then
        ResetFrontlineOwnerIfEmpty(inst)
    end
    return true
end
