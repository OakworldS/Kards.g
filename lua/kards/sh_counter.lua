--[[
    反制管理器 (Counter Manager)

    承载「在手中保持激活」的反制状态（readme 7.1 反制）：玩家在本方回合把手牌中的
    反制卡拖出手牌区外松手即激活，效果链（开始点「激活时」）执行后拦截钩子挂起，
    跨一个完整敌方回合存续，命中敌方操作时自动打出，或到点自动失活。

    状态与生命周期（2026-08-15 反制系统 M2）：
      Active[tableID][card] = { player, cost, turn }
        player 激活方；cost 激活时已扣（隐藏）的卡牌花费；turn 激活时的回合序号
      Activate(tableID, player, card, cost)：登记激活项并把花费计入隐藏池
      Deactivate(tableID, card, refund)：注销该卡的引擎钩子与效果注册，按需返还花费，
        移出登记（返还与自动失活均移出隐藏池）
      Fire(tableID, card)：被敌方操作触发自动打出后的收尾（移出登记 + 公开隐藏花费）
      OnTurnEnd(tableID, player)：该玩家回合结束时，已跨过一个完整敌方回合的激活项
        自动失活（不返还）
      ClearTable(tableID)：牌桌销毁清理

    隐藏花费（M4）：激活时把花费计入 CommandPoints 隐藏池（敌方不可见），失活返还时
    与自动打出时移出隐藏池（自动打出移出即对敌方公开扣减）。CommandPoints 的
    AddHidden / SubHidden 由 M4.1 提供，未就绪时为空操作（本模块可独立于 M4 运行）。

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_battle_combat.lua 之后；
    依赖 EngineHooks / EffectRegistry / CommandPoints / Battle / TickLog）
]]

KARDS = KARDS or {}
KARDS.Counter = KARDS.Counter or {}

-- 激活反制登记表：Active[tableID][card] = { player, cost, turn }
KARDS.Counter.Active = KARDS.Counter.Active or {}

-- 把花费计入隐藏池（仅本方可见，敌方不可见，见 M4.1；未就绪时为空操作）
local function AddHidden(tableID, player, cost)
    if cost and cost > 0 and KARDS.CommandPoints and KARDS.CommandPoints.AddHidden then
        KARDS.CommandPoints:AddHidden(tableID, player, cost)
    end
end

-- 把花费移出隐藏池（返还或公开扣减；未就绪时为空操作）
local function SubHidden(tableID, player, cost)
    if cost and cost > 0 and KARDS.CommandPoints and KARDS.CommandPoints.SubHidden then
        KARDS.CommandPoints:SubHidden(tableID, player, cost)
    end
end

-- 注销该卡注册的引擎钩子与效果注册（激活时注册的拦截钩子随卡失活/打出一并注销）
local function ReleaseRegistrations(card)
    if KARDS.EngineHooks and KARDS.EngineHooks.UnregisterByEntity then
        KARDS.EngineHooks.UnregisterByEntity(card)
    end
    if KARDS.EffectRegistry and KARDS.EffectRegistry.UnregisterByEntity then
        KARDS.EffectRegistry.UnregisterByEntity(card)
    end
end

-- 返还已扣花费：直接写回 Points（CommandPoints 无加回方法，直接写路径与
-- sh_battle_unit.lua SimChangeCommandPoints 一致），并通知变更（变量库事实同步）
local function RefundCost(tableID, player, cost)
    if not cost or cost <= 0 then return end
    local cp = KARDS.CommandPoints
    local inst = cp and cp:Get(tableID)
    if not inst then return end
    inst.Points[player] = (inst.Points[player] or 0) + cost
    if cp.NotifyChanged then cp:NotifyChanged(tableID, player) end
end

--[[
    登记一个激活反制：记录激活方 / 已扣花费 / 激活时回合序号，并把花费计入隐藏池。

    @param tableID string 牌桌唯一标识符
    @param player  string 激活方玩家标识
    @param card    table  反制卡牌句柄（激活期间作为引擎钩子绑定实体）
    @param cost    number 激活时已扣的卡牌花费
    @return boolean 恒 true（重复激活同一卡覆盖登记）
]]
function KARDS.Counter:Activate(tableID, player, card, cost)
    self.Active[tableID] = self.Active[tableID] or {}
    cost = math.max(0, math.floor(cost or 0))
    self.Active[tableID][card] = {
        player = player,
        cost = cost,
        turn = (KARDS.Battle and KARDS.Battle.TurnNumbers and KARDS.Battle.TurnNumbers[tableID]) or 0,
    }
    AddHidden(tableID, player, cost)
    return true
end

-- 取激活项（未激活返回 nil）
function KARDS.Counter:Get(tableID, card)
    local t = self.Active[tableID]
    return t and t[card] or nil
end

-- 该卡是否处于激活状态
function KARDS.Counter:IsActive(tableID, card)
    return self:Get(tableID, card) ~= nil
end

--[[
    失活一个激活反制：移出登记，注销该卡的引擎钩子与效果注册，按需返还花费。
    无论是否返还，都移出隐藏池（返还则恢复到激活前的公开值，不返还则公开该次扣减）。

    @param tableID string 牌桌唯一标识符
    @param card    table  反制卡牌句柄
    @param refund  boolean 是否返还已扣花费（手动失活 true；自动失活 false）
    @return boolean 是否成功（未激活返回 false）
]]
function KARDS.Counter:Deactivate(tableID, card, refund)
    local t = self.Active[tableID]
    local entry = t and t[card]
    if not entry then return false end
    t[card] = nil
    ReleaseRegistrations(card)
    if refund then
        RefundCost(tableID, entry.player, entry.cost)
    end
    SubHidden(tableID, entry.player, entry.cost)
    return true
end

--[[
    反制被触发（敌方操作命中条件）自动打出后的收尾：移出登记 + 注销注册 +
    公开此前隐藏的花费（对敌方公开该次扣减，见 M5）。

    @param tableID string 牌桌唯一标识符
    @param card    table  反制卡牌句柄
    @return boolean 是否成功（未激活返回 false）
]]
function KARDS.Counter:Fire(tableID, card)
    local t = self.Active[tableID]
    local entry = t and t[card]
    if not entry then return false end
    t[card] = nil
    ReleaseRegistrations(card)
    SubHidden(tableID, entry.player, entry.cost)
    return true
end

--[[
    该玩家回合结束时的自动失活：把本玩家「激活回合不是当前回合」的激活项全部失活
    （即已经历过一个完整敌方回合，见 D4），不返还花费。回合开始时 SimBeginTurn 递增
    回合序号，故激活当回合结束（序号相同）保留，下一个本方回合结束（序号已变）失活。

    @param tableID string 牌桌唯一标识符
    @param player  string 结束回合的玩家标识
]]
function KARDS.Counter:OnTurnEnd(tableID, player)
    local t = self.Active[tableID]
    if not t then return end
    local cur = (KARDS.Battle and KARDS.Battle.TurnNumbers and KARDS.Battle.TurnNumbers[tableID]) or 0
    local expired = {}
    for card, entry in pairs(t) do
        if entry.player == player and entry.turn ~= cur then
            expired[#expired + 1] = card
        end
    end
    for _, card in ipairs(expired) do
        self:Deactivate(tableID, card, false) -- 跨过一个完整敌方回合，自动失活不返还
    end
end

-- 按桌清理（牌桌销毁 / 新对局开始）
function KARDS.Counter:ClearTable(tableID)
    self.Active[tableID] = nil
end
