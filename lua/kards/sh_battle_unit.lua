--[[
    战斗系统骨架·单位/战场操作域 (Battle Unit Operations)

    从 sh_battle_stub.lua 拆分（re.md B-H1：按职责拆分文件）：
    单位部署/移动/撤退/移除/召唤/状态操作（词条状态与资源变更）集中于此，
    均挂 KARDS.Battle 命名空间（sh_battle_stub.lua 先加载声明命名空间），
    对外 API 签名不变，sh_node_parser.lua 执行器表经语义表调用的入口不变。

    本域函数依赖：
      - 判定查询函数（CanUnitAct / GetActionCost / HasActiveKeyword / GetKeywordValue，
        见 sh_battle_stub.lua）
      - 词条状态表 KeywordStates[tableID]（StartBattle 初始化，见 sh_battle_stub.lua）
      - Battlefield / Deck / CommandPoints / TickLog / EffectRegistry（全局）

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_battle_stub.lua 之后）
=======================================================================================
]]

KARDS = KARDS or {}
KARDS.Battle = KARDS.Battle or {}

--[[
    压制 / 解除压制（readme 7.2.1）

    被压制的单位不能移动或攻击；压制于单位所有者下个回合结束时移除
    （回合结束系统归正式版，骨架提供手动解除入口 SimUnsuppress）。

    @param card table 单位卡牌句柄
    @return boolean 是否成功
]]
function KARDS.Battle:SimSuppress(card)
    local st = self.KeywordStates[self.TableID]
    if not st or not card or card:GetType() ~= "unit" then return false end
    KARDS.KeywordStates.Suppression.Set(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "suppress" }, { { card, { "suppressed" } } })
    return true
end

function KARDS.Battle:SimUnsuppress(card)
    local st = self.KeywordStates[self.TableID]
    if not st or not card or card:GetType() ~= "unit" then return false end
    KARDS.KeywordStates.Suppression.Clear(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "suppress" }, {})
    return true
end

--[[
    揭示隐蔽单位（readme 7.2.2）

    隐蔽单位在发起攻击或被攻击后揭示并失去隐蔽（状态 Hidden 移除）。
    由 SimAttack / SimEngage 在攻击结算后自动调用。

    @param card table 单位卡牌句柄
    @return boolean 是否成功（非隐蔽状态返回 false）
]]
function KARDS.Battle:SimReveal(card)
    local st = self.KeywordStates[self.TableID]
    if not KARDS.KeywordStates.Hidden.Is(st, card) then return false end
    KARDS.KeywordStates.Hidden.Clear(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "reveal" }, {})
    return true
end

--[[
    抑制（readme 7.2.1）

    被抑制的卡牌失去所有关键词和效果（战斗规则侧由 HasActiveKeyword 统一失效）；
    攻击力 / 最大防御力 / 行动花费的重置由卡牌/效果配置（节点编辑器），骨架仅承载状态。

    @param card table 单位卡牌句柄
    @return boolean 是否成功
]]
function KARDS.Battle:SimInhibit(card)
    local st = self.KeywordStates[self.TableID]
    if not st or not card or card:GetType() ~= "unit" then return false end
    KARDS.KeywordStates.Inhibit.Set(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "neutralized" }, {})
    return true
end

--[[
    情报 X（readme 7.2.2）

    情报触发时能显示敌方 X 张手牌，最多 9（触发时机由效果配置，此处为数据查看入口）：
    返回敌方手牌前 X 张（X = 词条数值，上限 9）；无敌方手牌或无情报 → 返回 nil。

    @param card   table 具有情报词条的卡牌句柄（发起者）
    @param amount number|nil 指定情报张数（执行节点「情报」动作 [lib] 槽传入）；
                             未提供或 <=0 时回退目标词条数值（缺省行为）
    @return table|nil 敌方手牌卡牌列表
]]
function KARDS.Battle:SimUseIntel(card, amount)
    local st = self.KeywordStates[self.TableID]
    if not st or not card or card:GetType() ~= "unit" then return nil end
    local x = amount
    if not x or x <= 0 then
        x = self:GetKeywordValue(self.TableID, card, "intel", 0) or 0 -- 回退词条数值
    end
    x = math.min(x, 9) -- 最多 9
    if x <= 0 then return nil end
    local owner = card:GetOwner()
    local enemy = nil
    for _, p in ipairs(self.Players) do
        if p ~= owner then enemy = p break end
    end
    if not enemy then return nil end
    local hand = KARDS.Deck:GetHand(self.TableID, enemy) or {}
    local result = {}
    for i = 1, math.min(x, #hand) do
        table.insert(result, hand[i])
    end
    if #result == 0 then return nil end
    -- intelligence 刻：发起者变更文本记录情报张数（"+N"，最多 9），供事件监测「时：触发情报 = N」匹配（H1）
    KARDS.TickLog:Push(self.TableID, card, { "intelligence" }, {}, "+" .. #result)
    return result
end

-- 统计场上的友方山地单位数（readme 7.2.2 山地：部署或加入战场时，
-- 每有一个其他友方山地单位，获得一次 +1+1；统计排除自身）
-- @param self KARDS.Battle 骨架实例
-- @param card table 单位卡牌句柄
-- @return number 友方其他山地单位数
local function CountFriendlyMountain(self, card)
    local owner = card:GetOwner()
    local count = 0
    local function scan(line)
        if not line then return end
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            local u = line[i]
            if u ~= nil and u ~= card and u:GetType() == "unit" and u:GetOwner() == owner
                and self:HasActiveKeyword(self.TableID, u, "mountain") then
                count = count + 1
            end
        end
    end
    scan(KARDS.Battlefield:GetSupport(self.TableID, owner))
    scan(KARDS.Battlefield:GetFrontline(self.TableID))
    return count
end

-- 入场词条效果（readme 7.2.2 山地 / 隐蔽）：部署或加入战场时生效
-- @param self KARDS.Battle 骨架实例
-- @param card table 单位卡牌句柄
local function ApplyEnterKeywords(self, card)
    -- 山地：每有一个其他友方山地单位，获得一次 +1+1（readme 7.2.2）
    local mountainCount = CountFriendlyMountain(self, card)
    if mountainCount > 0 then
        for _ = 1, mountainCount do
            card:ApplyChange("attack", "increase", 1)
            card:ApplyChange("defense", "increase", 1)
        end
        -- stat_change 刻：受影响分条标注变化属性（attack/defense，供 event_monitor select_4 过滤）
        KARDS.TickLog:Push(self.TableID, card, { "stat_change" },
            { { card, { "stat_change" }, "+" .. mountainCount, "attack" }, { card, { "stat_change" }, "+" .. mountainCount, "defense" } })
    end
    if self:HasActiveKeyword(self.TableID, card, "stealth") then
        KARDS.KeywordStates.Hidden.Set(self.KeywordStates[self.TableID], card) -- 隐蔽单位入场时背面朝上
    end
    -- 倒计时 X：入场记录初始值（每回合结束后 -1，归零触发事件并移除，readme 7.2.2）
    local cv = self:GetKeywordValue(self.TableID, card, "countdown")
    if cv and cv > 0 then KARDS.KeywordStates.Countdown.Set(self.KeywordStates[self.TableID], card, cv) end
end

--[[
    部署单位到本方支援阵线的指定槽位（骨架，战场布局入口）

    部署位置由玩家选择（Kards 特色：单位部署在哪个单位旁 / 总部旁是战术决策）。

    @param card      table 单位卡牌句柄
    @param slotIndex number 目标槽位（仅单位槽 1/2/4/5 有效，且必须为空）
    @return boolean 是否成功（对局停止 / 槽位非法 / 槽位占用 / 重复入场 / 总部 均拒绝）
]]
function KARDS.Battle:SimDeploy(card, slotIndex)
    -- 部署单位消耗卡牌花费（指挥点，readme 7.1 操作）；不足拒绝
    local cost = card:GetCost()
    if not KARDS.CommandPoints:CanPay(self.TableID, card:GetOwner(), cost) then
        print("[Battle] SimDeploy 失败: 指挥点不足（需要 " .. cost .. "）")
        return false
    end
    local ok, reason = KARDS.Battlefield:AddToSupport(self.TableID, card, slotIndex)
    if not ok then
        print("[Battle] SimDeploy 失败: " .. tostring(reason))
        return false
    end
    KARDS.CommandPoints:Pay(self.TableID, card:GetOwner(), cost)
    -- 记录入场回合（闪击规则判定：本回合刚入场且无闪击不能行动，readme 7.2.2）
    self.EnteredTurns[self.TableID] = self.EnteredTurns[self.TableID] or {}
    self.EnteredTurns[self.TableID][card] = self.TurnNumbers[self.TableID] or 0
    -- 入场词条效果（山地 / 隐蔽，readme 7.2.2）
    ApplyEnterKeywords(self, card)
    KARDS.TickLog:Push(self.TableID, card, { "deploy" }, {})
    -- 卡牌进入战场事件（注册式效果框架：渲染层订阅后自动绑定实体，re.md B-M3 / B-H2）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardEnter, { card = card })
    -- 事件钩子（register_hook 通用效果·条件触发）：部署单位事件（发起者 = 部署的单位）
    if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
        KARDS.NodeParser.TriggerEventHooks(self.TableID, "deploy", card)
    end
    return true
end

--[[
    固定槽位部署单位到本方支援阵线（已弃用：不自动居中、不重排，单位精确落入
    目标空槽会在单位与总部间留空槽——2026-08-10 反馈后主路径改回 SimDeploy 居中；
    本函数与 AddToSupportFixed 保留供效果/测试等特殊用途，牌桌 OnPlayCard 不再调用）

    与 SimDeploy 同构，仅布局调用换 AddToSupportFixed（不自动居中、不重排，
    单位精确落入目标空槽，其余卡保持当前槽位）。目标槽被占时 AddToSupportFixed
    返回 slot_occupied。

    @param card      table 单位卡牌句柄
    @param slotIndex number 目标槽位（1..SLOT_COUNT，必须为空）
    @return boolean 是否成功（对局停止 / 槽位非法 / 槽位占用 / 重复入场 / 总部 / 指挥点不足 均拒绝）
]]
function KARDS.Battle:SimDeployFixed(card, slotIndex)
    -- 部署单位消耗卡牌花费（指挥点，readme 7.1 操作）；不足拒绝
    local cost = card:GetCost()
    if not KARDS.CommandPoints:CanPay(self.TableID, card:GetOwner(), cost) then
        print("[Battle] SimDeployFixed 失败: 指挥点不足（需要 " .. cost .. "）")
        return false
    end
    local ok, reason = KARDS.Battlefield:AddToSupportFixed(self.TableID, card, slotIndex)
    if not ok then
        print("[Battle] SimDeployFixed 失败: " .. tostring(reason))
        return false
    end
    KARDS.CommandPoints:Pay(self.TableID, card:GetOwner(), cost)
    -- 记录入场回合（闪击规则判定：本回合刚入场且无闪击不能行动，readme 7.2.2）
    self.EnteredTurns[self.TableID] = self.EnteredTurns[self.TableID] or {}
    self.EnteredTurns[self.TableID][card] = self.TurnNumbers[self.TableID] or 0
    -- 入场词条效果（山地 / 隐蔽，readme 7.2.2）
    ApplyEnterKeywords(self, card)
    KARDS.TickLog:Push(self.TableID, card, { "deploy" }, {})
    -- 卡牌进入战场事件（注册式效果框架：渲染层订阅后自动绑定实体，re.md B-M3 / B-H2）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardEnter, { card = card })
    -- 事件钩子（register_hook 通用效果·条件触发）：部署单位事件（发起者 = 部署的单位）
    if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
        KARDS.NodeParser.TriggerEventHooks(self.TableID, "deploy", card)
    end
    return true
end

--[[
    加入战场：将单位放入本方支援阵线的首个空槽（骨架）

    用于效果拉入场等非玩家选位的加入；部署（玩家选位）请用 SimDeploy。

    @param card table 单位卡牌句柄
    @return boolean 是否成功
]]
function KARDS.Battle:SimJoinBattlefield(card)
    local ok, reason = KARDS.Battlefield:JoinBattlefield(self.TableID, card)
    if not ok then
        print("[Battle] SimJoinBattlefield 失败: " .. tostring(reason))
        return false
    end
    -- 记录入场回合（闪击规则判定：本回合刚加入且无闪击不能行动，readme 7.2.2）
    self.EnteredTurns[self.TableID] = self.EnteredTurns[self.TableID] or {}
    self.EnteredTurns[self.TableID][card] = self.TurnNumbers[self.TableID] or 0
    -- 入场词条效果（山地 / 隐蔽，readme 7.2.2）
    ApplyEnterKeywords(self, card)
    KARDS.TickLog:Push(self.TableID, card, { "join_battlefield" }, {})
    -- 卡牌进入战场事件（注册式效果框架：渲染层订阅后自动绑定实体，re.md B-M3 / B-H2）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardEnter, { card = card })
    return true
end

--[[
    单位从本方支援阵线移动至前线（骨架，readme 7.1 操作 / 7.1 注 前线占领）

    前置拒绝（readme 7.1）：前线已被敌方占领 → 拒绝移动（提示"前线已被敌方占领"）；
    一个单位只能操作一次（readme 7.1）：已移动 / 已攻击 → 拒绝（移动/攻击互斥）。

    触发作弊（他方单位试图进入已控制的前线）时：
    对局立即停止（Battlefield.Stop），并写入一条作弊刻（cheat）供审计。

    @param card      table 单位卡牌句柄
    @param slotIndex number|nil 前线目标槽位（缺省自动首个空槽）
    @return boolean, string|nil 是否成功；失败时第二返回值为原因
            （false 且原因=cheat 表示作弊已触发、对局停止）
]]
function KARDS.Battle:SimMoveToFrontline(card, slotIndex)
    -- 单位本回合能否行动（被压制 / 刚部署且无闪击 → 拒绝，readme 7.2.1 / 7.2.2）
    if not self:CanUnitAct(self.TableID, card) then
        print("[Battle] SimMoveToFrontline 失败: 单位本回合不能行动（被压制或刚入场无闪击，readme 7.2.1/7.2.2）")
        return false, "单位本回合不能行动（被压制或刚入场无闪击）"
    end
    -- 行动互斥（readme 7.1：一个单位只能操作一次）：已攻击 → 拒绝（攻击后不能移动）
    local st = self.KeywordStates[self.TableID]
    if st and KARDS.KeywordStates.TurnAction.HasAttacked(st, card) then
        print("[Battle] SimMoveToFrontline 失败: 单位本回合已攻击过（攻击后不能移动，readme 7.1）")
        return false, "单位本回合已攻击过（攻击后不能移动）"
    end
    -- 行动互斥：已移动 → 拒绝（移动一次即不可再移动；坦克例外由攻击检查器负责，此处不放开）
    if st and KARDS.KeywordStates.TurnAction.HasMoved(st, card) then
        print("[Battle] SimMoveToFrontline 失败: 单位本回合已移动过（readme 7.1）")
        return false, "单位本回合已移动过"
    end
    -- 前线占领（readme 7.1 注）：前线已被敌方占领 → 拒绝移动（仅本方 / 无主前线可进入）
    local flOwner = KARDS.Battlefield:GetFrontlineOwner(self.TableID)
    if flOwner ~= nil and flOwner ~= card:GetOwner() then
        print("[Battle] SimMoveToFrontline 失败: 前线已被敌方占领（readme 7.1 注）")
        return false, "前线已被敌方占领"
    end
    -- 移动消耗行动花费（隐蔽未揭示 → 行动花费为 1，readme 7.2.2）；不足拒绝
    local actionCost = self:GetActionCost(self.TableID, card)
    if not KARDS.CommandPoints:CanPay(self.TableID, card:GetOwner(), actionCost) then
        print("[Battle] SimMoveToFrontline 失败: 指挥点不足（需要行动花费 " .. tostring(actionCost) .. "）")
        return false, ("指挥点不足（需要行动花费 %s）"):format(tostring(actionCost))
    end
    local ok, reason = KARDS.Battlefield:MoveToFrontline(self.TableID, card, slotIndex)
    if reason == "cheat" then
        KARDS.TickLog:Push(self.TableID, card, { "cheat" }, {}) -- 审计：作弊刻
        return false, "cheat"
    end
    if not ok then
        print("[Battle] SimMoveToFrontline 失败: " .. tostring(reason))
        return false, tostring(reason)
    end
    KARDS.CommandPoints:Pay(self.TableID, card:GetOwner(), actionCost)
    -- 烟幕（readme 7.2.2）：移动后失去烟幕（位于前线的单位不能具有烟幕）
    if self:HasActiveKeyword(self.TableID, card, "smoke") then
        KARDS.KeywordStates.Smoke.Break(self.KeywordStates[self.TableID], card)
    end
    -- 记录本回合已移动（readme 7.1：一个单位只能操作一次；坦克移动后仍可攻击由攻击检查器例外）
    KARDS.KeywordStates.TurnAction.MarkMoved(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "move" }, {})
    return true
end

--[[
    前线单位撤退回本方支援阵线（骨架）

    注：支援阵线已满时退回所有者手牌（readme 7.1 撤退规则）归正式版实现。

    @param card      table 单位卡牌句柄
    @param slotIndex number|nil 支援阵线目标槽位（缺省自动首个空槽）
    @return boolean 是否成功
]]
function KARDS.Battle:SimRetreat(card, slotIndex)
    local ok, reason = KARDS.Battlefield:Retreat(self.TableID, card, slotIndex)
    if not ok then
        print("[Battle] SimRetreat 失败: " .. tostring(reason))
        return false
    end
    -- 烟幕（readme 7.2.2）：移动后失去烟幕
    if self:HasActiveKeyword(self.TableID, card, "smoke") then
        KARDS.KeywordStates.Smoke.Break(self.KeywordStates[self.TableID], card)
    end
    KARDS.TickLog:Push(self.TableID, card, { "retreat" }, {})
    -- 卡牌离开战场事件（渲染层订阅后自动移除实体）+ 注销绑定该卡的注册条目（保持触发离场自动注销，re.md B-H2）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardLeave, { card = card })
    KARDS.EffectRegistry.UnregisterByEntity(card)
    return true
end

--[[
    随机排列（property 模板「随机排列所有」效果）

    在指定玩家控制的阵线范围（支援阵线 + 该方控制的前线）内随机重排所有单位：
      - 单位 ≠ 总部：总部不参与随机排列（恒驻支援阵线原槽，不进入洗牌池、不被随机到前线）
      - 随机性：单位池与「槽位池」（支援阵线非总部槽 + 前线槽）各自洗牌后按序填入，
        因此支援单位可能随机到前线、前线单位也可能随机到支援阵线（单位在阵线间随机分布）
      - 未控制前线（前线为空 / 被对方控制）：槽位池仅含支援阵线非总部槽 → 仅在支援阵线内随机排列
    纯布局重排，不写刻（无资源/属性/事件语义）。

    @param player string 目标玩家
    @return boolean 是否成功（牌桌不存在返回 false；无单位时视为成功）
]]
function KARDS.Battle:SimShuffleField(player)
    local inst = KARDS.Battlefield.Instances[self.TableID]
    if not inst then
        print("[Battle] SimShuffleField 失败: 牌桌不存在（需先 StartBattle）")
        return false
    end
    local support = KARDS.Battlefield:GetSupport(self.TableID, player)
    local frontline = KARDS.Battlefield:GetFrontline(self.TableID)
    local hasFL = (KARDS.Battlefield:GetFrontlineOwner(self.TableID) == player)
    local slotCount = KARDS.Battlefield.SLOT_COUNT

    -- 收集参与单位：支援阵线（排除总部）+ 前线（该方控制时）；记录总部原槽
    local units, hq, hqSlot = {}, nil, nil
    for i = 1, slotCount do
        local u = support[i]
        if u then
            if u:GetType() == "headquarter" then
                hq, hqSlot = hq or u, hqSlot or i
            else
                units[#units + 1] = u
            end
        end
    end
    if hasFL then
        for i = 1, slotCount do
            if frontline[i] then units[#units + 1] = frontline[i] end
        end
    end
    if not hq then
        hq = KARDS.Battlefield:GetHQ(self.TableID, player)
        hqSlot = hqSlot or 1
    end
    if #units == 0 then return true end -- 无单位可排列（空阵线视为成功）

    -- Fisher-Yates 洗牌单位池
    for i = #units, 2, -1 do
        local j = math.random(i)
        units[i], units[j] = units[j], units[i]
    end
    -- 槽位池：支援阵线非总部槽 + 前线槽（该方控制时），同样洗牌 → 单位随机分布到各槽
    local slots = {}
    for i = 1, slotCount do
        if i ~= hqSlot then slots[#slots + 1] = { support, i } end
    end
    if hasFL then
        for i = 1, slotCount do slots[#slots + 1] = { frontline, i } end
    end
    for i = #slots, 2, -1 do
        local j = math.random(i)
        slots[i], slots[j] = slots[j], slots[i]
    end
    -- 清空支援阵线（保留总部槽）与前线，再按槽位池顺序填入单位
    for i = 1, slotCount do
        if i ~= hqSlot then support[i] = nil end
    end
    if hasFL then
        for i = 1, slotCount do frontline[i] = nil end
    end
    for i = 1, #slots do
        local line, idx = slots[i][1], slots[i][2]
        if units[i] then
            line[idx] = units[i]
        end
    end
    return true
end

--[[
    被消灭 / 被移除：清空所在槽位（骨架）

    伤害结算后自动调用（AutoRemoveDead，见 sh_battle_combat.lua）；
    手动移除入口（效果移除 / 测试直接使用）。总部不可被移除（恒驻支援阵线槽 3）。

    @param card   table 单位卡牌句柄
    @param opType string|nil 操作类型（"death" 被消灭 / "remove" 被移除，缺省 "remove"）
    @return boolean 是否成功（总部不可被消灭/移除）
]]
function KARDS.Battle:SimRemoveFromField(card, opType)
    local ok, reason = KARDS.Battlefield:RemoveFromField(self.TableID, card)
    if not ok then
        print("[Battle] SimRemoveFromField 失败: " .. tostring(reason))
        return false
    end
    KARDS.TickLog:Push(self.TableID, card, { opType or "remove" }, {})
    -- 卡牌离开战场事件（渲染层订阅后自动移除实体）+ 注销绑定该卡的注册条目（保持触发离场自动注销，re.md B-H2）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardLeave, { card = card })
    KARDS.EffectRegistry.UnregisterByEntity(card)
    return true
end

--[[
    加入前线（效果直接加入前线，非玩家移动；含阵营一致性作弊检测）

    @param card table 单位卡牌句柄
    @return boolean 是否成功
]]
function KARDS.Battle:SimJoinFrontline(card)
    local ok, reason = KARDS.Battlefield:JoinFrontline(self.TableID, card)
    if not ok then
        print("[Battle] SimJoinFrontline 失败: " .. tostring(reason))
        return false
    end
    -- 记录入场回合（闪击规则判定：本回合刚加入且无闪击不能行动，readme 7.2.2）
    self.EnteredTurns[self.TableID] = self.EnteredTurns[self.TableID] or {}
    self.EnteredTurns[self.TableID][card] = self.TurnNumbers[self.TableID] or 0
    -- 入场词条效果（山地 / 隐蔽，readme 7.2.2）
    ApplyEnterKeywords(self, card)
    KARDS.TickLog:Push(self.TableID, card, { "join_frontline" }, {})
    -- 卡牌进入战场事件（注册式效果框架：渲染层订阅后自动绑定实体，re.md B-M3 / B-H2）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardEnter, { card = card })
    return true
end

--[[
    转换：更换单位类型（readme 7.3 单位类型）

    未指定新类型（nil，action 模板「转换」无类型输入）时保持原类型不变，仅记录 convert 刻。

    @param card        table 单位卡牌句柄
    @param newUnitType string|nil 新单位类型（非法类型拒绝并保持原类型）
    @return boolean 是否成功（非单位卡返回 false）
]]
function KARDS.Battle:SimConvert(card, newUnitType)
    if not card or card:GetType() ~= "unit" then return false end
    if newUnitType and KARDS.CardInterface.UnitTypes[newUnitType] then
        card:SetUnitType(newUnitType)
    end
    KARDS.TickLog:Push(self.TableID, card, { "convert" }, {})
    return true
end

--[[
    修复：恢复 amount 防御（readme 7.1 效果）

    @param card   table 单位卡牌句柄
    @param amount number|nil 恢复量（缺省 1）
    @return boolean 是否成功
]]
function KARDS.Battle:SimRepair(card, amount)
    if not card or card:GetType() ~= "unit" then return false end
    amount = math.max(0, math.floor(amount or 1))
    card:ApplyChange("defense", "increase", amount)
    -- stat_change 刻：受影响分条标注变化属性（defense，供 event_monitor select_4 过滤）
    KARDS.TickLog:Push(self.TableID, card, { "stat_change" },
        { { card, { "stat_change" }, "+" .. amount, "defense" } })
    return true
end

--[[
    控制：转移归属到 newOwner（readme 7.1 控制规则）

    记录原归属（ControlOrigin）供解除控制（SimUncontrol）还原；
    战场布局中的归属一致性（支援阵线按归属分线）归正式版处理，骨架仅变更卡牌归属字段。

    @param card     table 单位卡牌句柄（总部不可被控制）
    @param newOwner string 新归属玩家标识
    @return boolean 是否成功
]]
function KARDS.Battle:SimControl(card, newOwner)
    local st = self.KeywordStates[self.TableID]
    if not st or not card or card:GetType() == "headquarter" then return false end
    if not KARDS.KeywordStates.Control.Get(st, card) then
        KARDS.KeywordStates.Control.Set(st, card, card:GetOwner())
    end
    card:SetOwner(newOwner)
    KARDS.TickLog:Push(self.TableID, card, { "control" }, {})
    return true
end

--[[
    解除控制：归属还原为控制前的原玩家（readme 7.1 控制规则）

    @param card table 单位卡牌句柄
    @return boolean 是否成功（未被控制过返回 false）
]]
function KARDS.Battle:SimUncontrol(card)
    local st = self.KeywordStates and self.KeywordStates[self.TableID]
    if not st then return false end
    local origin = KARDS.KeywordStates.Control.Get(st, card)
    if not origin then return false end
    card:SetOwner(origin)
    KARDS.KeywordStates.Control.Clear(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "uncontrol" }, {})
    return true
end

--[[
    免疫：效果给予免疫状态（readme 7.2.1 免疫：免疫单位不会受到伤害）

    与卡面 immune 词条等效（HasActiveKeyword 生效）；被抑制时免疫同样失效。

    @param card table 单位卡牌句柄（总部不可免疫）
    @return boolean 是否成功
]]
function KARDS.Battle:SimImmune(card)
    local st = self.KeywordStates[self.TableID]
    if not st or not card or card:GetType() == "headquarter" then return false end
    KARDS.KeywordStates.Immune.Set(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "immune" }, {})
    return true
end

--[[
    解除免疫：移除效果给予的免疫状态

    @param card table 单位卡牌句柄
    @return boolean 是否成功
]]
function KARDS.Battle:SimUnimmune(card)
    local st = self.KeywordStates and self.KeywordStates[self.TableID]
    if not st then return false end
    KARDS.KeywordStates.Immune.Clear(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "unimmune" }, {})
    return true
end

--[[
    解除抑制：恢复被抑制卡牌的关键词和效果（readme 7.2.1）

    @param card table 单位卡牌句柄
    @return boolean 是否成功（未被抑制过返回 false）
]]
function KARDS.Battle:SimUnneutralize(card)
    local st = self.KeywordStates and self.KeywordStates[self.TableID]
    if not st then return false end
    if not KARDS.KeywordStates.Inhibit.Is(st, card) then return false end
    KARDS.KeywordStates.Inhibit.Clear(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "unneutralized" }, {})
    return true
end

--[[
    触发关键字效果（readme 7.2.2 亡计 / 倒计时等）

    具体效果由节点编辑器配置（效果数据挂在卡牌/事件系统），骨架仅记录触发刻：
    发起者 = source（效果发起者），受影响 = target（{ keyword } 操作类型）。

    @param source  table 效果发起者卡牌句柄
    @param target  table 被触发关键字效果的单位卡牌句柄
    @param keyword string 关键字 id
    @return boolean 是否成功
]]
function KARDS.Battle:SimTriggerKeyword(source, target, keyword)
    if not target or target:GetType() ~= "unit" then return false end
    KARDS.TickLog:Push(self.TableID, target, { "trigger" }, { { target, { tostring(keyword) } } })
    return true
end

--[[
    返回手牌：从场上移除并加入所有者手牌（readme 7.1 效果）

    @param card table 单位卡牌句柄（须在场上）
    @return boolean 是否成功
]]
function KARDS.Battle:SimReturnToHand(card)
    if not card or card:GetType() == "headquarter" then return false end
    local zone = KARDS.Battlefield:FindCardZone(self.TableID, card)
    if not zone then return false end
    local ok, reason = KARDS.Battlefield:RemoveFromField(self.TableID, card)
    if not ok then
        print("[Battle] SimReturnToHand 失败: " .. tostring(reason))
        return false
    end
    local hand = KARDS.Deck:GetHand(self.TableID, card:GetOwner())
    if not hand then return false end
    table.insert(hand, card)
    KARDS.TickLog:Push(self.TableID, card, { "return_to_hand" }, {})
    -- 卡牌离开战场事件（渲染层订阅后自动移除实体）+ 注销绑定该卡的注册条目（保持触发离场自动注销，re.md B-H2）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardLeave, { card = card })
    KARDS.EffectRegistry.UnregisterByEntity(card)
    return true
end

--[[
    召唤单位：将单位放入 owner 阵营的指定阵线（效果召唤，readme 7.1 效果）

    归属与 owner 不同时先转移（SetOwner）；zone 1=支援阵线（首个空槽）2=前线。
    记录入场刻（join_battlefield / join_frontline）+ summon 刻。

    @param owner string 召唤方玩家标识
    @param unit  table 单位卡牌句柄
    @param zone  number|nil 目标阵线（1=支援阵线，2=前线；缺省 1）
    @return boolean 是否成功
]]
function KARDS.Battle:SimSummonUnit(owner, unit, zone)
    if not unit or unit:GetType() ~= "unit" then return false end
    if unit:GetOwner() ~= owner then unit:SetOwner(owner) end
    local ok
    if (zone or 1) == 2 then
        ok = self:SimJoinFrontline(unit)
    else
        ok = self:SimJoinBattlefield(unit)
    end
    if not ok then return false end
    KARDS.TickLog:Push(self.TableID, unit, { "summon" }, {})
    return true
end

--[[
    指挥点变更（command 模板效果，readme 7.1 指挥点(槽) / 效果）

    @param player string 目标玩家
    @param amount number 变更数值（非负整数）
    @param op     number 1=增加 2=减少 3=设为
    @return boolean 是否成功（指挥点实例不存在返回 false）
]]
function KARDS.Battle:SimChangeCommandPoints(player, amount, op)
    local cp = KARDS.CommandPoints:Get(self.TableID)
    if not cp then
        print("[Battle] SimChangeCommandPoints 失败: 指挥点实例不存在（需先 StartBattle）")
        return false
    end
    amount = math.max(0, math.floor(amount or 0))
    local cur = cp.Points[player] or 0
    local new
    if op == 2 then
        new = math.max(0, cur - amount) -- 减少（最低 0）
    elseif op == 3 then
        new = amount                    -- 设为
    else
        new = cur + amount              -- 增加
    end
    cp.Points[player] = new
    -- 记录刻：发起者 = 该玩家总部（代表玩家资源变更），操作 command_points，change +N/-N/=N
    local hq = KARDS.Battlefield:GetHQ(self.TableID, player)
    local change = (op == 2) and ("-" .. amount) or ((op == 3) and ("=" .. amount) or ("+" .. amount))
    KARDS.TickLog:Push(self.TableID, hq, { "command_points" }, { { hq, { "command_points" }, change } })
    return true
end

--[[
    指挥点槽变更（command 模板效果，readme 7.1 指挥点(槽) / 效果）

    效果增加/设为受绝对上限 MAX_SLOT_ABSOLUTE（24）约束（对应 CommandPoints:ExtendSlot 语义，
    卡牌效果可突破自然上限 12）；减少最低 0。指挥点本身不受槽数即时约束（回合开始才调整至与槽相等）。

    @param player string 目标玩家
    @param amount number 变更数值（非负整数）
    @param op     number 1=增加 2=减少 3=设为
    @return boolean 是否成功（指挥点实例不存在返回 false）
]]
function KARDS.Battle:SimChangeCommandSlots(player, amount, op)
    local cp = KARDS.CommandPoints:Get(self.TableID)
    if not cp then
        print("[Battle] SimChangeCommandSlots 失败: 指挥点实例不存在（需先 StartBattle）")
        return false
    end
    amount = math.max(0, math.floor(amount or 0))
    local cap = KARDS.CommandPoints.MAX_SLOT_ABSOLUTE
    local cur = cp.Slots[player] or 0
    local new
    if op == 2 then
        new = math.max(0, cur - amount)            -- 减少（最低 0）
    elseif op == 3 then
        new = math.min(amount, cap)                -- 设为（绝对上限）
    else
        new = math.min(cur + amount, cap)          -- 增加（绝对上限）
    end
    cp.Slots[player] = new
    -- 记录刻：发起者 = 该玩家总部（代表玩家资源变更），操作 command_slot，change +N/-N/=N
    local hq = KARDS.Battlefield:GetHQ(self.TableID, player)
    local change = (op == 2) and ("-" .. amount) or ((op == 3) and ("=" .. amount) or ("+" .. amount))
    KARDS.TickLog:Push(self.TableID, hq, { "command_slot" }, { { hq, { "command_slot" }, change } })
    return true
end

--[[
    总部防御力变更（headquarter 模板效果）

    直接修改指定玩家总部卡防御力（总部始终驻留，防御可低于 0）。
    记录 stat_change 刻（发起者 = 经受 = 该玩家总部；event_monitor「总部」分支监听）。

    @param player string 目标玩家
    @param amount number 变更数值（非负整数）
    @param op     number 1=增加 2=减少 3=设为
    @return boolean 是否成功（总部卡不存在返回 false）
]]
function KARDS.Battle:SimChangeHQDefense(player, amount, op)
    local hq = KARDS.Battlefield:GetHQ(self.TableID, player)
    if not hq then
        print("[Battle] SimChangeHQDefense 失败: 找不到 " .. tostring(player) .. " 的总部卡（需先 StartBattle）")
        return false
    end
    amount = math.max(0, math.floor(amount or 0))
    local modifier = (op == 2) and "decrease" or ((op == 3) and "set" or "increase")
    hq:ApplyChange("defense", modifier, amount)
    -- 记录刻：发起者 = 经受 = 该玩家总部，操作 stat_change，change +N/-N/=N（属性标注 defense）
    local change = (op == 2) and ("-" .. amount) or ((op == 3) and ("=" .. amount) or ("+" .. amount))
    KARDS.TickLog:Push(self.TableID, hq, { "stat_change" }, { { hq, { "stat_change" }, change, "defense" } })
    return true
end

--[[
    浏览对方明牌（readme 7.1 明牌 / 词条 overwatch）

    明牌：仅卡牌在手中时可具有效果，敌方可浏览。
    玩家向服务器发送查看明牌信息：对方手牌中有明牌 → 返回明牌卡牌对象列表；
    无明牌（或试图浏览自己）→ 拒绝（返回 nil）。

    @param inspector string 请求浏览的玩家
    @param target    string 被浏览的玩家（其手牌中的明牌）
    @return table|nil 明牌卡牌对象列表（无则 nil）
]]
function KARDS.Battle:SimInspectOverwatch(inspector, target)
    if inspector == target then
        print("[Battle] SimInspectOverwatch 拒绝: 明牌仅敌方可浏览（不能浏览自己）")
        return nil
    end
    local hand = KARDS.Deck:GetHand(self.TableID, target)
    local result = {}
    if hand then
        for _, card in ipairs(hand) do
            if card:HasKeyword("overwatch") then
                table.insert(result, card)
            end
        end
    end
    if #result == 0 then
        print("[Battle] SimInspectOverwatch 拒绝: " .. target .. " 手牌中无明牌")
        return nil
    end
    return result
end
