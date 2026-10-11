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
    -- 2026-08-13：词条串刷新（suppress 图标随压制出现；经 OnBattleStatsChanged → SyncUnitNW）
    self:NotifyStatsChanged(card)
    return true
end

function KARDS.Battle:SimUnsuppress(card)
    local st = self.KeywordStates[self.TableID]
    if not st or not card or card:GetType() ~= "unit" then return false end
    KARDS.KeywordStates.Suppression.Clear(st, card)
    KARDS.TickLog:Push(self.TableID, card, { "suppress" }, {})
    -- 2026-08-13：词条串刷新（suppress 图标随解除压制消失）
    self:NotifyStatsChanged(card)
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
    -- 山地：每有一个其他友方山地单位，获得一次 +1+1（readme 7.2.2；
    -- 飘字/刻/音效见 KARDS.Battle.ApplyStatPairBoost，与动员共用）
    local mountainCount = CountFriendlyMountain(self, card)
    if mountainCount > 0 then
        KARDS.Battle.ApplyStatPairBoost(self, card, mountainCount)
    end
    if self:HasActiveKeyword(self.TableID, card, "stealth") then
        KARDS.KeywordStates.Hidden.Set(self.KeywordStates[self.TableID], card) -- 隐蔽单位入场时背面朝上
    end
    -- 倒计时 X：入场记录初始值（每回合结束后 -1，归零触发事件并移除，readme 7.2.2）
    local cv = self:GetKeywordValue(self.TableID, card, "countdown")
    if cv and cv > 0 then KARDS.KeywordStates.Countdown.Set(self.KeywordStates[self.TableID], card, cv) end
end

-- 入场尾部四连（记录入场回合 + 入场词条效果 + 入场刻 + 进入战场事件）
-- 四处（SimDeploy / SimDeployFixed / SimJoinBattlefield / SimJoinFrontline）同构；
-- 入场刻名随入口不同（deploy / join_battlefield / join_frontline）。
-- @param self      KARDS.Battle 骨架实例
-- @param card      table 单位卡牌句柄
-- @param enterTick string 入场刻名（"deploy" / "join_battlefield" / "join_frontline"）
local function MarkEntered(self, card, enterTick)
    -- 记录入场回合（闪击规则判定：本回合刚入场且无闪击不能行动，readme 7.2.2）
    self.EnteredTurns[self.TableID] = self.EnteredTurns[self.TableID] or {}
    self.EnteredTurns[self.TableID][card] = self.TurnNumbers[self.TableID] or 0
    -- 入场词条效果（山地 / 隐蔽，readme 7.2.2）
    ApplyEnterKeywords(self, card)
    KARDS.TickLog:Push(self.TableID, card, { enterTick }, {})
    -- 卡牌进入战场事件（注册式效果框架：渲染层订阅后自动绑定实体，re.md B-M3 / B-H2）
    -- enterTick 供实体层分流（2026-09-26 缺口 F）：join_battlefield / join_frontline
    -- 为「加入阵线」（另播加入动画），deploy 为「部署」（走既有部署动画）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardEnter,
        { card = card, enterTick = enterTick })
end

-- 执行单位效果链（节点模式，按「开始点」执行）
-- 开始点 = 触发点：全部触发时机（部署/在场/升级/阵亡/移除/抽取/弃牌/钳击/受到伤害/
-- 防御变化等）统一经本方法按对应开始点标题执行效果链（无匹配开始点不执行——
-- 顺序模式隔离见 sh_node_parser.lua ExecuteEffect；控制流模式经 ExecuteEffectFlow）。
-- @param self       KARDS.Battle 骨架实例
-- @param card       table 效果发起者卡牌句柄（effect 挂载者）
-- @param targets    table 受影响对象数组（ExecuteEffect 第二参数）
-- @param startPoint string 开始点名（"部署"/"阵亡"/"升级"/"移除"/"抽取"/"弃牌"/"钳击"/…）
function KARDS.Battle:RunCardEffect(card, targets, startPoint)
    if card.effect and KARDS.NodeParser and KARDS.NodeParser.ExecuteEffect then
        -- 钳击对象数据点注入（「钳击」触发时）：把同伴卡牌对象写入效果数据中
        -- 「钳击对象」数据源开始点的 data（ResolveEWires 经 dataConnections
        -- variableName 读取该字段注入下游 targets，见 sh_effect_flow.lua）
        if startPoint == "钳击" and targets and targets[1] then
            for _, node in ipairs(card.effect.nodes or {}) do
                if (node.type == "start" or node.name == "start_point")
                   and node.data and node.data.title == "钳击对象" then
                    node.data["钳击对象"] = targets
                    break
                end
            end
        end
        KARDS.NodeParser.ExecuteEffect({
            tableID = self.TableID,
            initiatorCard = card,
            variables = card.effect.variables,
            dataConnections = card.effect.dataConnections,
            functions = card.effect.functions, -- 效果级函数表（funcslot 引用函数子图）
            battle = self,
        }, card, targets, card.effect, nil, startPoint)
    end
end

-- ====================================================================
-- 钳击机制（readme 7.2.2 / 卡面机制文案「钳击：部署钳击单位时，可以选择另一个
-- 友方单位作为钳击同伴，两者将具有钳击加成，直到其中一个单位离场或失去钳击」）
--
-- 骨架承载：同伴关系登记（PincerPartners[tableID][card] = 同伴，双向）+ 部署时
-- 选择同伴（opts.pincerPicker 注入，缺省自动取场上首个其他友方单位）+ 攻击触发
-- 「钳击」开始点 + 「钳击对象」数据点注入 + 离场/失效解除。实际加成内容由单卡
-- 「钳击」开始点链配置（开始点 = 触发点的设计语义：加成不硬编码）。
-- ====================================================================

-- 钳击同伴关系表：PincerPartners[tableID][card] = 同伴卡牌（双向登记）
KARDS.Battle.PincerPartners = KARDS.Battle.PincerPartners or {}

-- 取单位钳击同伴（readme 7.2.2）：发起者仍具钳击（含抑制失效判定）且同伴仍在场才有效
-- @param card table 钳击单位卡牌句柄
-- @return table|nil 钳击同伴卡牌句柄（无同伴 / 已离场 / 失去钳击 → nil）
function KARDS.Battle:GetPincerPartner(card)
    if not card then return nil end
    local partners = self.PincerPartners[self.TableID]
    local partner = partners and partners[card]
    if not partner then return nil end
    -- 失去钳击（抑制等经 HasActiveKeyword 统一失效）→ 钳击加成结束
    if not self:HasActiveKeyword(self.TableID, card, "pincer") then
        self:ClearPincer(card)
        return nil
    end
    -- 同伴已离场 → 钳击加成结束（惰性清除）
    if not KARDS.Battlefield:FindCardZone(self.TableID, partner) then
        self:ClearPincer(card)
        return nil
    end
    return partner
end

-- 登记钳击同伴（双向；任一方已在旧关系时先解除，避免三角钳击）
-- @param card    table 钳击单位卡牌句柄
-- @param partner table 钳击同伴卡牌句柄
-- @return boolean 是否成功
function KARDS.Battle:SetPincerPartner(card, partner)
    if not card or not partner or card == partner then return false end
    local partners = self.PincerPartners[self.TableID]
    if not partners then
        partners = {}
        self.PincerPartners[self.TableID] = partners
    end
    self:ClearPincer(card)
    self:ClearPincer(partner)
    partners[card] = partner
    partners[partner] = card
    return true
end

-- 解除钳击同伴关系（双向；离场 / 失去钳击时调用）
-- @param card table 卡牌句柄（清除其所在钳击关系）
function KARDS.Battle:ClearPincer(card)
    if not card then return end
    local partners = self.PincerPartners[self.TableID]
    if not partners then return end
    local mate = partners[card]
    if mate then partners[mate] = nil end
    partners[card] = nil
end

-- 为钳击单位选择钳击同伴（部署时调用）：候选 = 场上其他友方单位（支援阵线 +
-- 前线的本方单位）；经 picker（opts.pincerPicker，未来 UI 选择注入）选择，
-- 缺省取候选首项；无候选 → 不建立钳击关系（可后续由效果/UI 补选）。
-- @param card   table 钳击单位卡牌句柄（须已入场）
-- @param picker function|nil 选择回调 function(candidates) → 选中的同伴（或 nil）
-- @return boolean 是否成功建立钳击关系
function KARDS.Battle:AssignPincerPartner(card, picker)
    if not card then return false end
    local owner = card:GetOwner()
    local candidates = {}
    local sup = KARDS.Battlefield:GetSupport(self.TableID, owner)
    if sup then
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            local u = sup[i]
            if u and u ~= card and u:GetType() == "unit" then
                candidates[#candidates + 1] = u
            end
        end
    end
    local fl = KARDS.Battlefield:GetFrontline(self.TableID)
    if fl then
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            local u = fl[i]
            if u and u ~= card and u:GetType() == "unit" and u:GetOwner() == owner then
                candidates[#candidates + 1] = u
            end
        end
    end
    if #candidates == 0 then return false end
    local partner = (picker and picker(candidates)) or candidates[1]
    if not partner then return false end
    return self:SetPincerPartner(card, partner)
end

-- 钳击攻击触发（SimAttack / SimEngage 攻击结算后调用）：发起者具有钳击同伴时，
-- 向发起者效果注入「钳击对象」数据点（= 同伴）并按「钳击」开始点执行其效果链；
-- 同伴同样按「钳击」执行（同伴链的「钳击对象」= 发起者）——「两者将具有钳击加成」
-- 由各卡「钳击」链自行定义（无匹配开始点不执行）。
-- @param attacker table 攻击方卡牌句柄
function KARDS.Battle:MaybeTriggerPincer(attacker)
    if not attacker or attacker:GetType() ~= "unit" then return end
    local partner = self:GetPincerPartner(attacker)
    if not partner then return end
    self:RunCardEffect(attacker, { partner }, "钳击") -- 发起者链：钳击对象 = 同伴
    self:RunCardEffect(partner, { attacker }, "钳击") -- 同伴链：钳击对象 = 发起者
end

-- 部署单位到本方支援阵线（SimDeploy / SimDeployFixed 共用核心，B2 合并）
-- 两者唯一差异是布局调用（AddToSupport 居中重排 vs AddToSupportFixed 精确落槽）；
-- 返回 (ok, reason) 供包装层输出不同前缀日志。
-- @param self      KARDS.Battle 骨架实例
-- @param card      table 单位卡牌句柄
-- @param slotIndex number 目标槽位
-- @param fixed     boolean 是否精确落槽（false = 居中重排）
-- @param opts      table|nil 可选扩展参数（向后兼容）：
--     pincerPicker = function(candidates) 钳击同伴选择注入（未来 UI；缺省取候选首项）
-- @return boolean, string|nil 是否成功；失败时第二返回值为原因
local function DeployToSupport(self, card, slotIndex, fixed, opts)
    -- 部署单位消耗卡牌花费（指挥点，readme 7.1 操作）；不足拒绝
    local cost = card:GetCost()
    if not KARDS.CommandPoints:CanPay(self.TableID, card:GetOwner(), cost) then
        return false, "指挥点不足（需要 " .. cost .. "）"
    end
    local addFn = fixed and KARDS.Battlefield.AddToSupportFixed or KARDS.Battlefield.AddToSupport
    -- AddToSupport/AddToSupportFixed 均为冒号定义（首参 self = Battlefield）；
    -- 函数引用取值后须显式传 Battlefield 作 self，否则点调用会把 TableID 字符串
    -- 错位进 self 参数（2026-08-15 实测：sh_battlefield.lua:375 index field 'Instances'）
    local ok, reason = addFn(KARDS.Battlefield, self.TableID, card, slotIndex)
    if not ok then
        return false, reason
    end
    KARDS.CommandPoints:Pay(self.TableID, card:GetOwner(), cost)
    -- 入场尾部四连（入场回合记录 + 山地/隐蔽词条 + deploy 刻 + 进入战场事件）
    MarkEntered(self, card, "deploy")
    -- 单位效果（节点模式）：按「部署」开始点执行单位效果链（绑定了 effectPath 的单位卡，如 55团）
    self:RunCardEffect(card, {}, "部署")
    -- 钳击（readme 7.2.2）：部署钳击单位时选择另一个友方单位作为钳击同伴，
    -- 两者将具有钳击加成，直到其中一个单位离场或失去钳击。选择经 opts.pincerPicker
    -- 注入（未来 UI 选择钳击同伴）；缺省自动取场上首个其他友方单位。
    if self:HasActiveKeyword(self.TableID, card, "pincer") then
        self:AssignPincerPartner(card, opts and opts.pincerPicker)
    end
    -- 事件钩子（register_hook 通用效果·条件触发）：部署单位事件（发起者 = 部署的单位）
    if KARDS.NodeParser and KARDS.NodeParser.TriggerEventHooks then
        KARDS.NodeParser.TriggerEventHooks(self.TableID, "deploy", card)
    end
    return true
end

--[[
    部署单位到本方支援阵线的指定槽位（骨架，战场布局入口）

    部署位置由玩家选择（Kards 特色：单位部署在哪个单位旁 / 总部旁是战术决策）。

    @param card      table 单位卡牌句柄
    @param slotIndex number 目标槽位（仅单位槽 1/2/4/5 有效，且必须为空）
    @param opts      table|nil 可选扩展参数（向后兼容，见 DeployToSupport：pincerPicker）
    @return boolean 是否成功（对局停止 / 槽位非法 / 槽位占用 / 重复入场 / 总部 均拒绝）
]]
function KARDS.Battle:SimDeploy(card, slotIndex, opts)
    -- 统一操作钩子（M1）：部署可被反制拦截（主动卡 = 部署单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "deploy", {
        player = card and card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("deploy", card)
    end
    local ok, reason = DeployToSupport(self, card, slotIndex, false, opts)
    if not ok then
        print("[Battle] SimDeploy 失败: " .. tostring(reason))
    end
    return ok
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
    @param opts      table|nil 可选扩展参数（向后兼容，见 DeployToSupport：pincerPicker）
    @return boolean 是否成功（对局停止 / 槽位非法 / 槽位占用 / 重复入场 / 总部 / 指挥点不足 均拒绝）
]]
function KARDS.Battle:SimDeployFixed(card, slotIndex, opts)
    local ok, reason = DeployToSupport(self, card, slotIndex, true, opts)
    if not ok then
        print("[Battle] SimDeployFixed 失败: " .. tostring(reason))
    end
    return ok
end

--[[
    加入战场：将单位放入本方支援阵线的首个空槽（骨架）

    用于效果拉入场等非玩家选位的加入；部署（玩家选位）请用 SimDeploy。

    @param card table 单位卡牌句柄
    @return boolean 是否成功
]]
function KARDS.Battle:SimJoinBattlefield(card)
    -- 统一操作钩子（M1）：加入战场可被反制拦截（主动卡 = 加入单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "join_battlefield", {
        player = card and card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("join_battlefield", card)
    end
    local ok, reason = KARDS.Battlefield:JoinBattlefield(self.TableID, card)
    if not ok then
        print("[Battle] SimJoinBattlefield 失败: " .. tostring(reason))
        return false
    end
    -- 入场尾部四连（入场回合记录 + 山地/隐蔽词条 + join_battlefield 刻 + 进入战场事件）
    MarkEntered(self, card, "join_battlefield")
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
    -- 统一操作钩子（M1）：移动可被反制拦截（主动卡 = 移动单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "move", {
        player = card and card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("move", card)
    end
    -- 单位本回合能否行动（被压制 / 刚部署且无闪击 → 拒绝，readme 7.2.1 / 7.2.2）
    local canAct, actReason = self:CanUnitAct(self.TableID, card)
    if not canAct then
        print("[Battle] SimMoveToFrontline 失败: " .. tostring(actReason or "单位本回合不能行动"))
        return false, actReason or "单位本回合不能行动"
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
    -- 统一操作钩子（M1）：撤退可被反制拦截（主动卡 = 撤退单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "retreat", {
        player = card and card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("retreat", card)
    end
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
    -- reason 供渲染层分流（2026-09-26 缺口 C）：撤退立即销毁，不延迟
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardLeave, { card = card, reason = "retreat" })
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
    -- 布局重排事件（2026-08-18 规划 C1）：实体层订阅后补布局广播——随机排列直接改
    -- 数组无 CardEnter/CardLeave，客户端战场保持旧排列（双方视角一致地错误）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.LayoutChanged, { player = player })
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
    -- 统一操作钩子（M1）：移除/阵亡可被反制拦截（主动卡 = 被移除单位，操作类型随参）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, opType or "remove", {
        player = card and card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation(opType or "remove", card)
    end
    local ok, reason = KARDS.Battlefield:RemoveFromField(self.TableID, card)
    if not ok then
        print("[Battle] SimRemoveFromField 失败: " .. tostring(reason))
        return false
    end
    KARDS.TickLog:Push(self.TableID, card, { opType or "remove" }, {})
    -- 阵亡路径（opType == "death"）：触发亡计刻（deathrattle，event_monitor「词条触发」可命中，
    -- 格式与 SimTriggerKeyword 一致）+ 按「阵亡」开始点执行单位效果链（绑定了 effectPath 的单位卡，如 55团）
    if opType == "death" then
        KARDS.TickLog:Push(self.TableID, card, { "trigger" }, { { card, { "deathrattle" } } })
        self:RunCardEffect(card, {}, "阵亡")
    else
        -- 移除路径（非死亡离场：效果移除等）：按「移除」开始点执行单位效果链
        self:RunCardEffect(card, {}, "移除")
    end
    -- 钳击同伴离场解除（readme 7.2.2：「直到其中一个单位离场」钳击加成结束）
    self:ClearPincer(card)
    -- 卡牌离开战场事件（渲染层订阅后自动移除实体）+ 注销绑定该卡的注册条目（保持触发离场自动注销，re.md B-H2）
    -- reason 供渲染层分流（2026-09-26 缺口 C）：仅 death 延迟 1 秒销毁，其余立即
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardLeave,
        { card = card, reason = opType or "remove" })
    KARDS.EffectRegistry.UnregisterByEntity(card)
    -- 同时注销绑定该卡的引擎钩子（拦截等）：否则单位注册的拦截在离场后残留（2026-10-05）
    KARDS.EngineHooks.UnregisterByEntity(card)
    return true
end

--[[
    加入前线（效果直接加入前线，非玩家移动；含阵营一致性作弊检测）

    @param card table 单位卡牌句柄
    @return boolean 是否成功
    @return string|nil 失败原因（不传 reason 时由调用方按 nil 处理；2026-09-26 缺口 F
            起返回 "前线已被敌方占领" 供行动作接线 FrontlineDenied 提示）
]]
function KARDS.Battle:SimJoinFrontline(card)
    -- 统一操作钩子（M1）：加入前线可被反制拦截（主动卡 = 加入单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "join_frontline", {
        player = card and card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("join_frontline", card)
    end
    -- 前线占领（readme 7.1 注，2026-09-26 缺口 F）：前线已被敌方占领 → 拒绝加入
    -- （与 SimMoveToFrontline 同款软失败；仅本方 / 无主前线可进入）
    local flOwner = KARDS.Battlefield:GetFrontlineOwner(self.TableID)
    if flOwner ~= nil and flOwner ~= card:GetOwner() then
        print("[Battle] SimJoinFrontline 失败: 前线已被敌方占领（readme 7.1 注）")
        return false, "前线已被敌方占领"
    end
    local ok, reason = KARDS.Battlefield:JoinFrontline(self.TableID, card)
    if reason == "cheat" then
        KARDS.TickLog:Push(self.TableID, card, { "cheat" }, {}) -- 审计：作弊刻
        return false, "cheat"
    end
    if not ok then
        print("[Battle] SimJoinFrontline 失败: " .. tostring(reason))
        return false, tostring(reason)
    end
    -- 入场尾部四连（入场回合记录 + 山地/隐蔽词条 + join_frontline 刻 + 进入战场事件）
    MarkEntered(self, card, "join_frontline")
    return true
end

--[[
    转换：卡牌整体换卡（readme 7.3 转换效果；2026-09-26 缺口 J）
    （原「更换单位类型」语义已被本缺口取代：单位类型由转换目标卡的数据决定）

    convertTo 为空（nil / 空字符串）时保持既有语义：仅记录 convert 刻，类型不变。
    convertTo 为卡文件名时按该文件的编辑器数据构造一张全新的单位卡（初始状态：不带
    老兵状态、不继承旧卡当前防御力与词条），在原阵线槽位原地置换，并触发 UnitConvert
    事件（实体层据此生成新战场实体并广播翻面交接动画）。不改动旧卡句柄本身，
    保证旧战场实体存活到交接动画结束（不触发 CardLeave / CardEnter）。

    目标卡须为战场单位（非单位卡如总部 / 指令拒绝）。

    @param card      table 被转换的单位卡牌句柄
    @param convertTo string|nil 转换目标卡文件名（编辑器「转换目标卡」字段）
    @return boolean 是否成功
]]
local function BuildCardFromFile(fileName, owner)
    local SaveSystem = KARDS.CardEditor and KARDS.CardEditor.SaveSystem
    if not (SaveSystem and SaveSystem.GetCardInfo) then return nil end
    local info = SaveSystem.GetCardInfo(fileName)
    local app = info and info.cardAppearance
    if not app then return nil end
    -- 单位类型存于编辑器 cardType（infantry / tank / artillery / fighter / bomber）
    local ctype = app.cardType or "unit"
    if ctype ~= "unit" and not KARDS.CardInterface.UnitTypes[ctype] then
        print("[Battle] SimConvert 失败: 目标卡 " .. tostring(fileName) .. " 不是单位卡")
        return nil
    end
    local card = KARDS.CardInterface.CreateMockCard(fileName, "unit", owner, {
        attack = app.attack or 0, defense = app.defense or 0,
        cost = app.cost or 0, actionCost = app.actionCost,
        country = app.country,
        unitType = ctype, keywords = app.keywords,
        combatModifiers = app.combatModifiers,
        sounds = app.sounds,
        cardScale = app.cardScale,
        veteranAppearance = app.veteranAppearance,
        convertTarget = app.convertTarget,
    })
    -- 效果文件挂载（与 DeckCardHandleFromFile 同源）：无 effectPath 或文件为空则不挂
    if app.effectPath and app.effectPath ~= "" and SaveSystem.LoadEffectForRuntime then
        local effect = SaveSystem.LoadEffectForRuntime(app.effectPath)
        if effect and effect.nodes and #effect.nodes > 0 then
            card.effect = effect
        end
    end
    return card
end

function KARDS.Battle:SimConvert(card, convertTo)
    if not card or card:GetType() ~= "unit" then return false end
    -- 统一操作钩子（M1）：转换可被反制拦截（主动卡 = 被转换单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "convert", {
        player = card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("convert", card)
    end
    if not convertTo or convertTo == "" then
        KARDS.TickLog:Push(self.TableID, card, { "convert" }, {})
        return true
    end
    local newCard = BuildCardFromFile(convertTo, card:GetOwner())
    if not newCard then return false end
    -- 原地置换（保持阵线与槽位不变；失败说明旧卡已不在场）
    if not KARDS.Battlefield:ReplaceCard(self.TableID, card, newCard) then return false end
    -- 整体换卡事件（2026-09-26 缺口 J）：实体层据此生成新战场实体并广播交接动画。
    -- 不触发 CardLeave / CardEnter：旧实体需存活到动画结束，新实体的登记与布局广播
    -- 由事件 handler 显式完成
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.UnitConvert,
        { player = card:GetOwner(), oldCard = card, newCard = newCard })
    -- 刻：发起者用新卡，受影响列表补旧卡与新卡各一条（便于审计）
    KARDS.TickLog:Push(self.TableID, newCard, { "convert" },
        { { card, { "convert" } }, { newCard, { "convert" } } })
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
    -- 统一操作钩子（M1）：修复可被反制拦截（主动卡 = 被修复单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "repair", {
        player = card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("repair", card)
    end
    amount = math.max(0, math.floor(amount or 1))
    local old = card:GetStat("defense") or 0
    card:ApplyChange("defense", "increase", amount)
    -- 飘字（2026-08-14）：修复 → 防御增加绿色飘字（delta = new - old，含 99 上限截断）
    self:NotifyStatFX(card, "defense", (card:GetStat("defense") or 0) - old, "increase", "other")
    -- stat_change 刻：受影响分条标注变化属性（defense，供 event_monitor select_4 过滤）
    KARDS.TickLog:Push(self.TableID, card, { "stat_change" },
        { { card, { "stat_change" }, "+" .. amount, "defense" } })
    return true
end

--[[
    控制：转移归属到 newOwner（readme 7.1 控制规则）

    规则（2026-08-15 用户规格，测试版实现）：
      - 只能控制敌方单位（同阵营目标拒绝）；
      - 目标必须已在战场（控制作用于战场单位）；
      - 目标不在前线（在支援阵线）且新控制者支援阵线已满 → 提示「支援阵线已满」并拒绝；
      - 记录原阵线位置（ControlOrigin：zone / slot / owner，首次控制，后续不覆盖）
        供解除控制（SimUncontrol）还原；
      - 跨线落位：前线 → 前线反转为新控制者占领 + 移到前线第 3 位置；
        支援阵线 → 移到新控制者支援阵线右侧（受限选位 + 自动居中）。

    @param card     table 单位卡牌句柄（总部不可被控制）
    @param newOwner string 新归属玩家标识
    @return boolean 是否成功
]]
function KARDS.Battle:SimControl(card, newOwner)
    local st = self.KeywordStates[self.TableID]
    if not st or not card or card:GetType() == "headquarter" then return false end
    -- 统一操作钩子（M1）：控制可被反制拦截（主动卡 = 被控制单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "control", {
        player = card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("control", card)
    end
    -- 只能控制敌方单位（readme 7.1）；未指定新归属 / 目标已是新归属方 → 拒绝
    if not newOwner or newOwner == card:GetOwner() then return false end
    local inst = KARDS.Battlefield:Get(self.TableID)
    if not inst then return false end
    -- 目标必须已在战场（控制作用于战场单位，且跨线落位需要其原阵线位置）
    local line, idx = KARDS.Battlefield:FindCardSlot(self.TableID, card)
    if not line then
        print("[Battle] SimControl 失败: 目标不在战场")
        return false
    end
    local zone = (line == inst.Frontline) and "frontline" or "support"
    -- 目标不在前线（在支援阵线）且新控制者支援阵线已满 → 提示「支援阵线已满」并拒绝
    if zone == "support" and KARDS.Battlefield:IsSupportFull(self.TableID, newOwner) then
        print("[Battle] SimControl 失败: 支援阵线已满")
        return false
    end
    -- 记录原阵线位置（首次控制；后续控制不覆盖 → 解除控制还原最初归属与最初原位）
    if not KARDS.KeywordStates.Control.Get(st, card) then
        KARDS.KeywordStates.Control.Set(st, card, {
            zone = zone, slot = idx, owner = card:GetOwner(),
        })
    end
    local oldOwner = card:GetOwner()
    card:SetOwner(newOwner)
    -- 跨线落位（readme 7.1 控制规则）：
    --   前线 → 前线反转为新控制者占领 + 移到前线第 3 位置；
    --   支援阵线 → 移到新控制者支援阵线右侧（受限选位 + 自动居中）
    if zone == "frontline" then
        KARDS.Battlefield:RemoveFromField(self.TableID, card)
        local ok, reason = KARDS.Battlefield:AddToFrontline(self.TableID, card, 3,
            { forceOwner = newOwner })
        if not ok then
            print("[Battle] SimControl 失败: " .. tostring(reason))
            card:SetOwner(oldOwner) -- 前线已满：回滚归属
            return false
        end
    else
        KARDS.Battlefield:RemoveFromField(self.TableID, card)
        local ok, reason = KARDS.Battlefield:AddToSupport(self.TableID, card,
            KARDS.Battlefield.SLOT_COUNT)
        if not ok then
            print("[Battle] SimControl 失败: " .. tostring(reason))
            card:SetOwner(oldOwner)
            KARDS.Battlefield:AddToSupport(self.TableID, card, idx) -- 尽力回滚原位
            return false
        end
    end
    KARDS.TickLog:Push(self.TableID, card, { "control" }, {})
    self:NotifyStatsChanged(card)
    -- 控制动画通知（客户端播放 0.7s 移向中心 + 图标动画 + 落位，见 sh_battle_combat.lua
    -- ControlCallbacks / cl_init.lua net.Receive KardsControlAnim）；落位 = 原阵线：
    -- 前线 → 前线第 3 位置；支援 → 新控制者支援阵线右侧。附旋转归属对：
    -- fromOwner = 原归属方 / toOwner = 新控制者（观察者视角第一段动画 yaw 旋转到新方）
    self:NotifyControl(card, false, zone, (zone == "frontline") and 3 or KARDS.Battlefield.SLOT_COUNT,
        oldOwner, newOwner)
    return true
end

--[[
    解除控制：归属还原为控制前的原玩家，移回原阵线位置（readme 7.1 控制规则）

    原位还原条件（2026-08-15 用户规格，测试版实现）：
      - 原位在支援阵线且原归属者支援阵线已满 → 返回手牌；
      - 原位在前线且前线被该单位阵营的另一方（自身以外）占领 → 返回手牌；
      - 原位在前线且前线已满 → 返回手牌（无空位可回位）；
      - 否则 → 移回原阵线位置（受限选位 + 自动居中）。

    @param card table 单位卡牌句柄
    @return boolean 是否成功（未被控制过返回 false）
]]
function KARDS.Battle:SimUncontrol(card)
    local st = self.KeywordStates and self.KeywordStates[self.TableID]
    if not st then return false end
    local origin = KARDS.KeywordStates.Control.Get(st, card)
    if not origin then return false end
    -- 统一操作钩子（M1）：解除控制可被反制拦截（主动卡 = 被解除控制的单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "uncontrol", {
        player = card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("uncontrol", card)
    end
    -- 原位还原条件判定（基于原归属者与原阵线位置）
    local toHand = false
    if origin.zone == "support" then
        toHand = KARDS.Battlefield:IsSupportFull(self.TableID, origin.owner)
    else -- origin.zone == "frontline"
        local flOwner = KARDS.Battlefield:GetFrontlineOwner(self.TableID)
        toHand = (flOwner and flOwner ~= origin.owner)
            or KARDS.Battlefield:IsFrontlineFull(self.TableID)
    end
    local prevOwner = card:GetOwner() -- 解除前归属（控制者；观察者控制动画 yaw 旋转起点）
    card:SetOwner(origin.owner) -- 归属先还原（返回手牌 / 回位均以原归属为准）
    KARDS.KeywordStates.Control.Clear(st, card)
    -- 回位失败兜底：卡此时已从战场移除（SimReturnToHand 要求在场），直接插入
    -- 原归属者手牌（省略移除类事件，兜底路径罕见——预检查已覆盖支援满/前线满/占领）
    local function handFallback(reason)
        print("[Battle] SimUncontrol 回位失败: " .. tostring(reason))
        local hand = KARDS.Deck:GetHand(self.TableID, card:GetOwner())
        if hand then table.insert(hand, card) end
        KARDS.TickLog:Push(self.TableID, card, { "return_to_hand" }, {})
        -- 计数变更事件（2026-08-18 规划 C5）：兜底直接插入手牌无事件通道，
        -- 实体层订阅后补 SyncBattleCounts
        KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CountsChanged,
            { player = card:GetOwner() })
    end
    if toHand then
        self:SimReturnToHand(card)
        -- 返回手牌：走既有返回手牌动画（SimReturnToHand → ReturnToHand 事件 →
        -- KardsReturnToHand），不触发控制动画通知
    elseif origin.zone == "frontline" then
        KARDS.Battlefield:RemoveFromField(self.TableID, card)
        local ok, reason = KARDS.Battlefield:AddToFrontline(self.TableID, card, origin.slot,
            { forceOwner = origin.owner })
        if not ok then handFallback(reason)
        else self:NotifyControl(card, true, nil, nil, prevOwner, origin.owner) end
    else
        KARDS.Battlefield:RemoveFromField(self.TableID, card)
        local ok, reason = KARDS.Battlefield:AddToSupport(self.TableID, card, origin.slot)
        if not ok then handFallback(reason)
        else self:NotifyControl(card, true, nil, nil, prevOwner, origin.owner) end
    end
    KARDS.TickLog:Push(self.TableID, card, { "uncontrol" }, {})
    self:NotifyStatsChanged(card)
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
    -- 统一操作钩子（M1）：免疫可被反制拦截（主动卡 = 被免疫单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "immune", {
        player = card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("immune", card)
    end
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
    -- 统一操作钩子（M1）：解除免疫可被反制拦截（主动卡 = 被解除免疫单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "unimmune", {
        player = card and card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("unimmune", card)
    end
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
    -- 统一操作钩子（M1）：解除抑制可被反制拦截（主动卡 = 被解除抑制单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "unneutralized", {
        player = card and card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("unneutralized", card)
    end
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
    -- 统一操作钩子（M1）：触发关键字可被反制拦截（主动卡 = 效果发起者，缺省取目标）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "trigger", {
        player = source and source.GetOwner and source:GetOwner() or nil,
        card = source or target, targets = { target },
    }).intercepted then
        return self:InterceptOperation("trigger", source or target)
    end
    KARDS.TickLog:Push(self.TableID, target, { "trigger" }, { { target, { tostring(keyword) } } })
    return true
end

--[[
    升为老兵：套用老兵外观并触发「升级」开始点（readme 7.2.1 老兵）

    目标单位按 veteranAppearance（编辑器老兵外观）重置：费用 / 行动花费 / 攻防 /
    品质 / 词条（带数值词条保留 { id, x } 结构，词条 key 按 CreateMockCard 同规则
    翻译 + 白名单校验）；已在老兵状态或缺少外观数据时拒绝。
    套用前保存基础属性快照（返回手牌时回退为初始非老兵状态，见 SimReturnToHand）。
    套用后触发目标单位效果文件的「升级」开始点（升级附加效果由单卡节点配置），
    并记录 veteran 刻。

    @param target table 目标单位卡牌句柄
    @return boolean 是否成功
]]
function KARDS.Battle:SimVeteran(target)
    if not target or target:GetType() ~= "unit" then return false end
    -- 统一操作钩子（M1）：升为老兵可被反制拦截（主动卡 = 目标单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "veteran", {
        player = target:GetOwner(), card = target,
    }).intercepted then
        return self:InterceptOperation("veteran", target)
    end
    if target:IsVeteran() then return false end -- 已在老兵状态：拒绝重复升级
    if not target:CanElevateToVeteran() then return false end -- 无可升为老兵词条：拒绝
    local va = target:GetVeteranAppearance()
    if not va or type(va) ~= "table" then
        print("[Battle] SimVeteran 失败: 卡牌 " .. tostring(target:GetID()) .. " 缺少老兵外观数据")
        return false
    end
    -- 保存升级前基础属性快照（返回手牌时回退为初始非老兵状态）
    target._preVeteranStats = {
        attack = target._stats.attack or 0,
        defense = target._stats.defense or 0,
        cost = target._cost,
        actionCost = target._actionCost,
        quality = target._quality,
        keywords = table.Copy(target._keywords),
    }
    -- 套用老兵外观：费用 / 行动花费 / 攻防 / 品质 / 词条
    --（费用/行动花费同 kards 数值上限 99，2026-08-13；攻防经 ApplyChange 已统一上限）
    if va.cost ~= nil then target._cost = math.min(99, va.cost) end
    -- 行动花费新旧值（2026-09-26 缺口 I：白色飘字由 UnitElevate 事件统一承载；
    -- 未变化时 ackChanged 为 false，客户端不飘行动花费）
    local ackChanged, ackOld, ackNew = false, target._actionCost, target._actionCost
    if va.actionCost ~= nil then
        local oldAC = target._actionCost
        target._actionCost = math.min(99, va.actionCost)
        ackChanged, ackOld, ackNew = true, oldAC, target._actionCost
    end
    local oldAtk = target:GetStat("attack") or 0
    local oldDef = target:GetStat("defense") or 0
    target:ApplyChange("attack", "set", va.attack or 0)
    target:ApplyChange("defense", "set", va.defense or 0)
    -- 攻防新值（2026-09-26 缺口 I：老兵白字语义为「设为」，飘字显示设置后的新值；
    -- 由 UnitElevate 事件携带新旧值下发，零变动也飘）
    local atkNew = target:GetStat("attack") or 0
    local defNew = target:GetStat("defense") or 0
    if va.quality then target._quality = va.quality end
    if va.keywords then
        local newKeywords = {}
        for _, kw in ipairs(va.keywords) do
            local kwId = type(kw) == "table" and kw[1] or kw
            -- 编辑器词条 key → 战斗系统词条 id（同 CreateMockCard 规则）
            kwId = KARDS.CardInterface.EditorKeywordToBattle[kwId] or kwId
            if KARDS.CardInterface.Keywords[kwId] or KARDS.CardInterface.IsHiddenKeyword(kwId) then
                table.insert(newKeywords, type(kw) == "table" and { kwId, kw[2] } or kwId)
            end
        end
        target._keywords = newKeywords
    end
    target:SetVeteran()
    -- 触发「升级」开始点（升级附加效果由单卡节点配置；发起者 = 升级的单位自身，同 SimDeploy 模式）
    self:RunCardEffect(target, { target }, "升级")
    -- 老兵升级动画与白色飘字（2026-09-26 缺口 I）：实体层订阅 UnitElevate 后播 z 上升、
    -- 依次白色飘字（行动花费有变动才飘且显示带符号变动值；攻防无论是否变动都飘且显示
    -- 设为后的新值）、回落；三方视角一致
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.UnitElevate, {
        card = target,
        ackChanged = ackChanged, ackOld = ackOld, ackNew = ackNew,
        atkOld = oldAtk, atkNew = atkNew,
        defOld = oldDef, defNew = defNew,
    })
    KARDS.TickLog:Push(self.TableID, target, { "veteran" }, {})
    return true
end

--[[
    返回手牌：从场上移除并加入所有者手牌（readme 7.1 效果）

    老兵回退：若目标是老兵状态，返回手牌时恢复为初始非老兵状态
    （撤销 SimVeteran 套用的老兵外观：恢复升级前基础属性与词条）。

    @param card table 单位卡牌句柄（须在场上）
    @return boolean 是否成功
]]
function KARDS.Battle:SimReturnToHand(card)
    if not card or card:GetType() == "headquarter" then return false end
    -- 统一操作钩子（M1）：返回手牌可被反制拦截（主动卡 = 被返回的单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "return_to_hand", {
        player = card:GetOwner(), card = card,
    }).intercepted then
        return self:InterceptOperation("return_to_hand", card)
    end
    local zone = KARDS.Battlefield:FindCardZone(self.TableID, card)
    if not zone then return false end
    local ok, reason = KARDS.Battlefield:RemoveFromField(self.TableID, card)
    if not ok then
        print("[Battle] SimReturnToHand 失败: " .. tostring(reason))
        return false
    end
    -- 返回手牌事件（实体层订阅后广播返回手牌动画）。触发时机刻意早于下方老兵
    -- 回退与手牌插入：老兵回退的属性回调（OnBattleStatsChanged）会把战场实体
    -- （fieldCardEnts[card]）立即移除，须在此前触发才能让实体层读取其位置创建
    -- 正常卡模型动画载体（小模型 → 正常模型原地切换）；手牌序号由实体层按
    -- 「追加末位」计算（事件先于插入：idx = 当前手牌数 + 1 = 插入后新张数）。
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.ReturnToHand, { card = card })
    -- 老兵回退：返回手牌时恢复为初始非老兵状态（撤销老兵外观，可再次升级）
    --（攻防经 ApplyChange 统一上限 99；费用/行动花费恢复快照值，同上限保险）
    if card:IsVeteran() and card._preVeteranStats then
        local s = card._preVeteranStats
        card:ApplyChange("attack", "set", s.attack)
        card:ApplyChange("defense", "set", s.defense)
        card._cost = math.min(99, s.cost)
        card._actionCost = math.min(99, s.actionCost)
        card._quality = s.quality
        card._keywords = s.keywords
        card._isVeteran = false
        card._preVeteranStats = nil
    end
    local hand = KARDS.Deck:GetHand(self.TableID, card:GetOwner())
    if not hand then return false end
    -- 手牌上限检查（2026-09-05）：手牌已满时不移入手牌，等同于移除（Kards 语义）
    if #hand < KARDS.Deck.MAX_HAND then
        table.insert(hand, card)
    else
        print("[Battle] SimReturnToHand 手牌已满，单位被移除: " .. tostring(card.GetName and card:GetName() or ""))
        -- 仍需记录刻度以标明移除事实（刻度第三字段为 nil 表示无数值变更的移除）
    end
    KARDS.TickLog:Push(self.TableID, card, { "return_to_hand" }, {})
    -- 按「移除」开始点执行单位效果链（返回手牌 = 离开战场，与 SimRemoveFromField 非死亡移除同语义）
    self:RunCardEffect(card, {}, "移除")
    -- 钳击同伴离场解除（readme 7.2.2：「直到其中一个单位离场」钳击加成结束）
    self:ClearPincer(card)
    -- 卡牌离开战场事件（渲染层订阅后自动移除实体）+ 注销绑定该卡的注册条目（保持触发离场自动注销，re.md B-H2）
    -- reason 供渲染层分流（2026-09-26 缺口 C）：回手立即销毁，不延迟
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CardLeave, { card = card, reason = "return_to_hand" })
    KARDS.EffectRegistry.UnregisterByEntity(card)
    -- 同时注销绑定该卡的引擎钩子（拦截等）：返回手牌 = 离开战场，拦截随之失效（2026-10-05）
    KARDS.EngineHooks.UnregisterByEntity(card)
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
    @return string|nil 失败原因（2026-09-26 缺口 F：zone==2 且前线被敌方占领时透传
            "前线已被敌方占领"）
]]
function KARDS.Battle:SimSummonUnit(owner, unit, zone)
    if not unit or unit:GetType() ~= "unit" then return false end
    -- 统一操作钩子（M1）：召唤可被反制拦截（主动卡 = 被召唤单位）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "summon", {
        player = owner, card = unit,
    }).intercepted then
        return self:InterceptOperation("summon", unit)
    end
    if unit:GetOwner() ~= owner then unit:SetOwner(owner) end
    local ok, reason
    if (zone or 1) == 2 then
        ok, reason = self:SimJoinFrontline(unit)
    else
        ok = self:SimJoinBattlefield(unit)
    end
    if not ok then return false, reason end
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
    -- 统一操作钩子（M1）：指挥点变更可被反制拦截（无主动卡，作用对象 = 目标玩家）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "command_points", {
        player = player,
    }).intercepted then
        return self:InterceptOperation("command_points", nil)
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
    -- 剩余指挥点同步到变量库事实（2026-10-04：本函数直接写 Points，不经 CommandPoints 变更方法，
    -- 故在此显式通知；供条件节点「剩余指挥点」数值源读取）
    KARDS.CommandPoints:NotifyChanged(self.TableID, player)
    -- 记录刻：发起者 = 该玩家总部（代表玩家资源变更），操作 command_points，change +N/-N/=N
    local hq = KARDS.Battlefield:GetHQ(self.TableID, player)
    local change = (op == 2) and ("-" .. amount) or ((op == 3) and ("=" .. amount) or ("+" .. amount))
    KARDS.TickLog:Push(self.TableID, hq, { "command_points" }, { { hq, { "command_points" }, change } })
    -- 指挥点变更事件（2026-08-18 规划 C6）：亡计/倒计时/event_monitor 触发的指挥点
    -- 效果不经实体层打牌广播路径，实体层订阅后补 BroadcastCommandPoints（HUD 同步）
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CommandPointsChanged, { player = player })
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
    -- 统一操作钩子（M1）：指挥点槽变更可被反制拦截（无主动卡，作用对象 = 目标玩家）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "command_slot", {
        player = player,
    }).intercepted then
        return self:InterceptOperation("command_slot", nil)
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
    -- 指挥点槽变更事件（2026-08-18 规划 C6）：同 SimChangeCommandPoints 补广播
    KARDS.EffectRegistry.Trigger(self.TableID, KARDS.EffectRegistry.EVENTS.CommandPointsChanged, { player = player })
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
    local old = hq:GetStat("defense") or 0
    hq:ApplyChange("defense", modifier, amount)
    -- 飘字（2026-08-14）：节点「HQ 防御力」变更 → 设为/减少白色、增加绿色（delta = new - old）
    self:NotifyStatFX(hq, "defense", (hq:GetStat("defense") or 0) - old, modifier, "node")
    -- 记录刻：发起者 = 经受 = 该玩家总部，操作 stat_change，change +N/-N/=N（属性标注 defense）
    local change = (op == 2) and ("-" .. amount) or ((op == 3) and ("=" .. amount) or ("+" .. amount))
    KARDS.TickLog:Push(self.TableID, hq, { "stat_change" }, { { hq, { "stat_change" }, change, "defense" } })
    -- 总部被摧毁判定（readme 7.1）：节点「HQ 防御力」变更不经属性变更通知，
    -- 此处显式检查（CheckHQDestroyed 幂等：已停止 / 已判定时无操作）
    if (op == 2 or op == 3) then
        KARDS.Battlefield:CheckHQDestroyed(self.TableID, player)
    end
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
    -- 统一操作钩子（M1）：浏览明牌可被反制拦截（无主动卡，作用对象 = 被浏览玩家）
    if KARDS.EngineHooks.TriggerOperation(self.TableID, "overwatch", {
        player = inspector, targets = { target },
    }).intercepted then
        self:InterceptOperation("overwatch", nil)
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

-- ====================================================================
-- 刻级前线一致性校验（2026-09-26 缺口 F）
-- ====================================================================

--[[
    前线排他性校验（KARDS.TickLog.OnPushed 钩子，每推进一刻后执行）

    正常路径（含控制反转的 forceOwner 越权）不会让前线同时存在两方单位；若出现，
    说明有绕过软失败的写入口。检查步骤：

      1. 统计前线非空单位的所有者集合，少于 2 个直接返回
      2. 追溯范围取当前刻与上一刻（SimJoinFrontline 先落位后推刻，操作记在所推进刻内）
      3. 例外：范围内任一刻含 control / uncontrol 操作 → 跳过（控制反转经 forceOwner
         合法越权，见 sh_battlefield.lua AddToFrontline）
      4. 定位作弊者：操作类型含 join_frontline / join_battlefield / move / summon 且
         归属不等于前线归属的卡，取最后一个
      5. 定位成功则补一条 cheat 刻并停局（保留停局作为既有作弊后果）

    @param tableID string 牌桌唯一标识符
]]
function KARDS.Battle:VerifyFrontlineExclusive(tableID)
    if not KARDS.TickLog or not KARDS.Battlefield then return end
    local inst = KARDS.TickLog:Get(tableID)
    if not inst or inst._verifying then return end
    local line = KARDS.Battlefield:GetFrontline(tableID)
    if not line then return end
    -- 1. 前线单位所有者集合（少于 2 方则无需校验）
    local owners, ownerCount = {}, 0
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        local c = line[i]
        if c and c.GetOwner then
            local o = c:GetOwner()
            if o and not owners[o] then
                owners[o] = true
                ownerCount = ownerCount + 1
            end
        end
    end
    if ownerCount < 2 then return end
    -- 2. 追溯范围：当前刻与上一刻
    local ticks = {}
    local cur = KARDS.TickLog:GetTick(tableID, inst.TickCount)
    local prev = KARDS.TickLog:GetTick(tableID, inst.TickCount - 1)
    if cur then ticks[#ticks + 1] = cur end
    if prev then ticks[#ticks + 1] = prev end
    if #ticks == 0 then return end
    -- 3. 控制反转例外（forceOwner 合法越权）
    local function entryHasOp(entry, a, b)
        if not entry then return false end
        for _, op in ipairs(entry[2] or {}) do
            if op == a or op == b then return true end
        end
        return false
    end
    for _, tk in ipairs(ticks) do
        if entryHasOp(tk[1], "control", "uncontrol") then return end
        for _, t in ipairs(tk[2] or {}) do
            if entryHasOp(t, "control", "uncontrol") then return end
        end
    end
    -- 4. 作弊者定位（进线/入场类操作且归属不等于前线归属，取最后一个）
    local flOwner = KARDS.Battlefield:GetFrontlineOwner(tableID)
    local entryOps = {
        join_frontline = true, join_battlefield = true, move = true, summon = true,
    }
    local culprit
    local function scan(entry)
        if not entry or not entry[1] or not entry[1].GetOwner then return end
        local card = entry[1]
        local hit = false
        for _, op in ipairs(entry[2] or {}) do
            if entryOps[op] then hit = true break end
        end
        if hit and card:GetOwner() ~= flOwner then culprit = card end
    end
    for _, tk in ipairs(ticks) do
        scan(tk[1])
        for _, t in ipairs(tk[2] or {}) do scan(t) end
    end
    if not culprit then return end
    -- 5. 补 cheat 刻 + 停局（_verifying 防递归：Push 会再次触发本钩子）
    inst._verifying = true
    KARDS.TickLog:Push(tableID, culprit, { "cheat" }, {})
    KARDS.Battlefield:Stop(tableID, culprit:GetOwner(), "前线同时存在两方单位")
    inst._verifying = false
end

-- 注册校验钩子（TickLog 保持纯 Lua，不反向依赖战斗层；注入点见 sh_ticklog.lua OnPushed）
KARDS.TickLog.OnPushed = function(tableID)
    KARDS.Battle:VerifyFrontlineExclusive(tableID)
end
