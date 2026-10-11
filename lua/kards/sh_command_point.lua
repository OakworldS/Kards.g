--[[
    指挥点数据层 (Command Points)

    纯 Lua 实现，不依赖 GMod API；多牌桌按 tableID 分实例隔离，
    与 TickLog / Battlefield / Deck 的 tableID 隔离体系一致（战斗系统规划.md 第 14 节）。

    规则（readme 7.1 指挥点(槽) / 操作）：
      - 玩家每回合获得 1 个指挥点槽，直到达到 12 个（自然增长上限 MAX_SLOT_GROWTH）
      - 指挥点槽最多可拥有 24 个（绝对上限 MAX_SLOT_ABSOLUTE；卡牌效果可突破 12，见 ExtendSlot）
      - 回合开始时指挥点会调整至与指挥点槽相等（无条件：点数 = 槽数）
      - 开局（开场动画 / 重新调度期间）：双方均为 0 指挥点槽（点数 = 0）；
        先手首回合开始时由牌桌会话层执行初始补给（AddSlot +1 槽 + BeginTurn 补满，
        见 table_session.lua StartFirstTurn，2026-08-11）
      - 操作消耗指挥点：打出卡牌消耗卡牌花费 cost；单位移动/攻击消耗行动花费 actionCost
        （readme 7.1 操作；卡牌花费/行动花费见 sh_card_interface.lua）

    指挥点检查与扣减（CanPay / Pay）由 Battle 骨架在操作入口调用（见 sh_battle_stub.lua）。
]]

KARDS = KARDS or {}
---@class CommandPoints 指挥点数据层
KARDS.CommandPoints = KARDS.CommandPoints or {}

-- 各牌桌实例：Instances[tableID] = { Points = { [player] = number }, Slots = { [player] = number } }
KARDS.CommandPoints.Instances = KARDS.CommandPoints.Instances or {}

-- 每回合自然增长上限（达到后不再增长，除非卡牌效果扩展）
KARDS.CommandPoints.MAX_SLOT_GROWTH = 12

-- 指挥点槽绝对上限（含卡牌效果扩展）
KARDS.CommandPoints.MAX_SLOT_ABSOLUTE = 24

--[[
    创建（开始）一场牌桌的指挥点空间：双方均为 0 槽（点数 0）——开场动画与
    重新调度期间双方无指挥点（2026-08-11）；先手初始补给（+1 槽并补满点数）
    由牌桌会话层在 StartFirstTurn 先手首回合开始时以 AddSlot + BeginTurn 执行。

    @param tableID     string 牌桌唯一标识符
    @param players     table|nil 玩家标识列表（缺省 {"P1", "P2"}）
    @param firstPlayer string|nil 先手玩家（缺省 players[1]，仅记录，开局双方无差别）
    @return table 新创建的指挥点实例
]]
function KARDS.CommandPoints:Create(tableID, players, firstPlayer)
    players = players or { "P1", "P2" }
    local inst = { Points = {}, Slots = {}, Hidden = {} }
    for _, p in ipairs(players) do
        inst.Slots[p] = 0
        inst.Points[p] = 0 -- 开局（开场动画 / 重新调度期间）双方 0 槽 0 点
        inst.Hidden[p] = 0 -- 隐藏花费（反制系统 M4）：已支付但暂不对敌方公开的反制花费累计
    end
    self.Instances[tableID] = inst
    return inst
end

-- 获取指定牌桌的指挥点实例（不存在返回 nil）
function KARDS.CommandPoints:Get(tableID)
    return self.Instances[tableID]
end

-- 指挥点/槽变更回调（由变量库在 Create 时注册，用于把剩余指挥点同步到变量库事实；
-- 签名 function(tableID, player)；未注册时为空操作，2026-10-04）
KARDS.CommandPoints.OnChanged = nil

-- 通知变更（内部改点与本文件外的直接写 Points 路径共用，见 sh_battle_unit.lua SimChangeCommandPoints）
function KARDS.CommandPoints:NotifyChanged(tableID, player)
    local cb = self.OnChanged
    if cb then cb(tableID, player) end
end

-- 获取指定牌桌、指定玩家的指挥点槽数
function KARDS.CommandPoints:GetSlots(tableID, player)
    local inst = self.Instances[tableID]
    return inst and (inst.Slots[player] or 0) or 0
end

-- 获取指定牌桌、指定玩家的当前指挥点数
function KARDS.CommandPoints:GetPoints(tableID, player)
    local inst = self.Instances[tableID]
    return inst and (inst.Points[player] or 0) or 0
end

--[[
    隐藏花费（反制系统 M4）：玩家激活反制时已支付、但暂不对敌方公开的指挥点累计。
    真实剩余指挥点仍是 Points（用于逻辑判定与扣费）；对敌方展示的口径为
    Points + Hidden（见 GetPublicPoints）。隐藏值在反制失活返还或自动打出公开时清零。
]]
function KARDS.CommandPoints:GetHidden(tableID, player)
    local inst = self.Instances[tableID]
    return inst and (inst.Hidden and inst.Hidden[player] or 0) or 0
end

-- 增加隐藏花费（反制激活扣费后调用，见 sh_counter.lua Activate）
function KARDS.CommandPoints:AddHidden(tableID, player, n)
    local inst = self.Instances[tableID]
    if not inst then return false end
    inst.Hidden = inst.Hidden or {}
    inst.Hidden[player] = (inst.Hidden[player] or 0) + math.max(0, math.floor(n or 0))
    return true
end

-- 减少隐藏花费（反制失活返还 / 自动打出公开时调用），下限 0
function KARDS.CommandPoints:SubHidden(tableID, player, n)
    local inst = self.Instances[tableID]
    if not inst then return false end
    inst.Hidden = inst.Hidden or {}
    inst.Hidden[player] = math.max(0, (inst.Hidden[player] or 0) - math.max(0, math.floor(n or 0)))
    return true
end

-- 公开指挥点（供广播裁剪）：真实点数 + 隐藏花费；对敌方 / 观战者展示该值
function KARDS.CommandPoints:GetPublicPoints(tableID, player)
    return self:GetPoints(tableID, player) + self:GetHidden(tableID, player)
end

--[[
    每回合自然增长指挥点槽：+count（缺省 1），上限 MAX_SLOT_GROWTH（12）；
    达到上限后不再增长（卡牌效果扩展请用 ExtendSlot）。
]]
function KARDS.CommandPoints:AddSlot(tableID, player, count)
    local inst = self.Instances[tableID]
    if not inst then return false end
    local cur = inst.Slots[player] or 0
    inst.Slots[player] = math.min(cur + (count or 1), self.MAX_SLOT_GROWTH)
    self:NotifyChanged(tableID, player)
    return true
end

--[[
    卡牌效果扩展指挥点槽：+count（缺省 1），可突破 12，绝对上限 MAX_SLOT_ABSOLUTE（24）。
]]
function KARDS.CommandPoints:ExtendSlot(tableID, player, count)
    local inst = self.Instances[tableID]
    if not inst then return false end
    local cur = inst.Slots[player] or 0
    inst.Slots[player] = math.min(cur + (count or 1), self.MAX_SLOT_ABSOLUTE)
    self:NotifyChanged(tableID, player)
    return true
end

--[[
    回合开始：指挥点调整至与指挥点槽相等（无条件：点数 = 槽数，readme 7.1）。
]]
function KARDS.CommandPoints:BeginTurn(tableID, player)
    local inst = self.Instances[tableID]
    if not inst then return false end
    inst.Points[player] = inst.Slots[player] or 0
    self:NotifyChanged(tableID, player)
    return true
end

-- 能否支付 amount 指挥点（点数不足返回 false）
function KARDS.CommandPoints:CanPay(tableID, player, amount)
    return (self:GetPoints(tableID, player) or 0) >= (amount or 0)
end

--[[
    支付 amount 指挥点：足够则扣减并返回 true；不足返回 false（不扣减）。
]]
function KARDS.CommandPoints:Pay(tableID, player, amount)
    local inst = self.Instances[tableID]
    if not inst then return false end
    amount = math.max(0, math.floor(amount or 0))
    local cur = inst.Points[player] or 0
    if cur < amount then return false end
    inst.Points[player] = cur - amount
    self:NotifyChanged(tableID, player)
    return true
end
