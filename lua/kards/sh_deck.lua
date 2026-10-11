--[[
    卡组数据层 (Deck Data Layer)

    纯 Lua 实现，不依赖 GMod API；多牌桌按 tableID 分实例隔离，
    与 TickLog / Battlefield 的 tableID 隔离体系一致（战斗系统规划.md 第 12 节）。

    规则（2026-08-04 新增，来源：readme.md 7.1 + 用户要求）：
      - 对局中双方各有 39 张牌组成的卡组（构筑）；数量由 SetDeck 传入的卡牌列表决定，
        代码不硬编码（readme 7.1 构筑校验为 40 张，归正式版）
      - 对局开始即随机打乱卡组数组（洗牌一次，Fisher-Yates），此后顺序固定不变：
        「抽牌不是真随机，是有序但确是随机的」——按洗牌后的固定顺序抽取
      - 抽牌从牌堆顶（数组末项）依次取，加入手牌；抽牌时卡组已空 → 士气伤害：
          第一次失去 1，第二次失去 2，以此类推（readme 7.1 士气伤害）
        本层只累计伤害计数并返回伤害量（Draw 第二返回值 moraleHits），
        由 Battle 骨架应用到总部卡并写时间刻（依赖倒置，见 sh_battle_stub.lua）
      - 手牌上限（readme 7.1）：手牌上限为 9 张（MAX_HAND），达到上限后抽到的牌
        不进手牌（手牌无法增加 = 爆牌），但仍从卡组移除并随 drawn 返回，
        由上层播放专属弃牌动画（Draw 第三返回值 overdraw 标记本次抽牌是否爆牌）
      - 重新调度（readme 7.1，先手 4 手牌 / 后手 5 手牌）：
          对局开始时双方各一次机会，选择不想要的起始手牌并确认 → 随机移动、插入到卡组中
          （随机位置，含牌堆首尾）→ 抽取等量卡牌替换
      - 重新调度会扰动卡组顺序（用户明确要求），补抽按新顺序

    随机源：默认 math.random（GMod），可用 SetRNG 注入确定性随机源（测试用）。
]]

KARDS = KARDS or {}
---@class Deck 卡组数据层
KARDS.Deck = KARDS.Deck or {}

-- 各牌桌实例：Instances[tableID] = { FirstPlayer, Decks, Hands, MoralDamage, Mulliganed, Starters }
KARDS.Deck.Instances = KARDS.Deck.Instances or {}

-- 随机源（默认 GMod math.random，测试可注入确定性实现）
KARDS.Deck.RNG = math.random

-- 起手牌数：先手 4 / 后手 5（readme 7.1 重新调度）
KARDS.Deck.FIRST_STARTER = 4
KARDS.Deck.SECOND_STARTER = 5

-- 手牌上限（readme 7.1 手牌上限）：达到上限后抽到的牌不进手牌（爆牌，由上层播专属弃牌动画）
KARDS.Deck.MAX_HAND = 9

-- 注入随机源（测试用确定性 RNG；需支持 (a, b) 返回 [a, b] 内整数）
function KARDS.Deck:SetRNG(fn)
    self.RNG = fn or math.random
end

-- 生成 [1, n] 内随机整数
function KARDS.Deck:RandomInt(n)
    return math.floor(self.RNG(1, n))
end

--[[
    创建（开始）一场牌桌的卡组空间：空卡组 / 空手牌 / 士气计数归零 / 起手数按先手后手

    @param tableID    string 牌桌唯一标识符
    @param players    table|nil 玩家标识列表（缺省 {"P1", "P2"}）
    @param firstPlayer string|nil 先手玩家（缺省 players[1]；先手 4 手牌，后手 5 手牌）
    @return table 新创建的卡组实例
]]
function KARDS.Deck:Create(tableID, players, firstPlayer)
    players = players or { "P1", "P2" }
    local first = firstPlayer or players[1]
    local inst = {
        FirstPlayer = first,
        Decks = {},   -- [player] = { 卡牌... }（第一项 = 牌堆顶）
        Hands = {},   -- [player] = { 卡牌... }
        MoralDamage = {}, -- [player] = 士气伤害计数（第 N 次空抽伤害 N）
        Mulliganed = {},  -- [player] = 是否已重新调度（一次机会）
        Starters = {},    -- [player] = 起手牌数（先手 4 / 后手 5）
    }
    for _, p in ipairs(players) do
        inst.Decks[p] = {}
        inst.Hands[p] = {}
        inst.MoralDamage[p] = 0
        inst.Mulliganed[p] = false
        inst.Starters[p] = (p == first) and self.FIRST_STARTER or self.SECOND_STARTER
    end
    self.Instances[tableID] = inst
    return inst
end

-- 获取指定牌桌的卡组实例（不存在返回 nil）
function KARDS.Deck:Get(tableID)
    return self.Instances[tableID]
end

-- 获取指定牌桌、指定玩家的卡组数组（末项 = 牌堆顶；与 node 解析器「卡组顶=末项」约定一致）
function KARDS.Deck:GetDeck(tableID, player)
    local inst = self.Instances[tableID]
    return inst and inst.Decks[player] or nil
end

-- 获取指定牌桌、指定玩家的手牌数组
function KARDS.Deck:GetHand(tableID, player)
    local inst = self.Instances[tableID]
    return inst and inst.Hands[player] or nil
end

-- 牌堆顶卡牌（不取出；卡组空返回 nil）
function KARDS.Deck:Peek(tableID, player)
    local deck = self:GetDeck(tableID, player)
    return deck and deck[#deck] or nil
end

-- 指定牌桌、指定玩家的卡组剩余张数
function KARDS.Deck:DeckSize(tableID, player)
    local deck = self:GetDeck(tableID, player)
    return deck and #deck or 0
end

-- 指定牌桌、指定玩家的手牌张数
function KARDS.Deck:HandSize(tableID, player)
    local hand = self:GetHand(tableID, player)
    return hand and #hand or 0
end

--[[
    从手牌移除指定卡（打出指令 / 部署单位成功后调用，服务端权威，2026-08-10）

    @param tableID string 牌桌唯一标识符
    @param player  string 玩家标识
    @param card    table  卡牌句柄（必须位于手牌中）
    @return boolean 是否成功（牌桌/手牌不存在或卡不在手牌返回 false）
]]
function KARDS.Deck:RemoveFromHand(tableID, player, card)
    local hand = self:GetHand(tableID, player)
    if not hand then return false end
    for i = #hand, 1, -1 do
        if hand[i] == card then
            table.remove(hand, i)
            return true
        end
    end
    return false
end

-- 指定牌桌、指定玩家的士气伤害计数（第 N 次空抽伤害 N）
function KARDS.Deck:GetMoralDamage(tableID, player)
    local inst = self.Instances[tableID]
    return inst and (inst.MoralDamage[player] or 0) or 0
end

-- 指定牌桌的先手玩家
function KARDS.Deck:GetFirstPlayer(tableID)
    local inst = self.Instances[tableID]
    return inst and inst.FirstPlayer or nil
end

--[[
    设置一方卡组（构筑）并对局开始即洗牌一次，此后顺序固定（有序但随机）

    @param tableID string 牌桌唯一标识符
    @param player  string 玩家标识
    @param cards   table  卡牌句柄列表（构筑；数量不硬编码）
    @return boolean, string 是否成功；失败原因（no_table）
]]
function KARDS.Deck:SetDeck(tableID, player, cards)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    local copy = {}
    for _, c in ipairs(cards or {}) do
        table.insert(copy, c)
    end
    inst.Decks[player] = copy
    inst.Hands[player] = inst.Hands[player] or {}
    self:Shuffle(tableID, player) -- 对局开始打乱一次
    return true
end

-- 洗牌（Fisher-Yates，就地打乱卡组数组）
function KARDS.Deck:Shuffle(tableID, player)
    local deck = self:GetDeck(tableID, player)
    if not deck then return false end
    for i = #deck, 2, -1 do
        local j = self:RandomInt(i) -- [1, i]
        deck[i], deck[j] = deck[j], deck[i]
    end
    return true
end

-- 将卡牌随机插入卡组（随机位置，含牌堆首尾）
function KARDS.Deck:InsertRandom(tableID, player, card)
    local deck = self:GetDeck(tableID, player)
    if not deck then return false end
    if #deck == 0 then
        table.insert(deck, card)
    else
        local pos = self:RandomInt(#deck + 1) -- [1, #deck+1]，含首尾
        table.insert(deck, pos, card)
    end
    return true
end

--[[
    将卡牌放到卡组顶（数组末项 = 牌堆顶，见本文件 GetDeck 约定，2026-10-04）

    用于「返回卡组顶」动作（亡计：返回卡组顶并使其算作海军）。仅负责入堆顶，
    来源区（手牌/战场）的移出由调用方（战斗骨架或节点动作）先行处理。

    @param tableID string 牌桌唯一标识符
    @param player  string 玩家标识
    @param card    table  卡牌句柄
    @return boolean 是否成功（牌桌/卡组不存在返回 false）
]]
function KARDS.Deck:PutOnTop(tableID, player, card)
    local deck = self:GetDeck(tableID, player)
    if not deck then return false end
    table.insert(deck, card) -- 末项 = 堆顶
    return true
end

--[[
    抽牌：从牌堆顶（数组第一项）依次取 count 张加入手牌；
    抽牌时卡组已空 → 士气伤害（第一次 1，第二次 2，以此类推，计数按玩家递增）；
    手牌已达上限（MAX_HAND=9）→ 爆牌：抽到的牌不进手牌（手牌无法增加），
    但仍从卡组移除并返回（由上层播放专属弃牌动画，见 readme 7.1 手牌上限）

    @param tableID string 牌桌唯一标识符
    @param player  string 玩家标识
    @param count   number|nil 抽牌张数（缺省 1）
    @return table drawn      实际抽到的卡牌列表（含爆牌弃掉的卡）
    @return table moraleHits 士气伤害表 [player] = 本轮累计伤害（空抽触发时才有）
    @return boolean overdraw 本次抽牌是否触发爆牌（至少一张卡因手牌已达上限未进手牌）
    @return table  overdrawnCards 爆牌卡表 [card] = true（per-card，支持部分爆牌：
            抽多张时前几张进手牌、达上限后的剩余卡爆牌）
]]
function KARDS.Deck:Draw(tableID, player, count)
    local inst = self.Instances[tableID]
    if not inst then
        print("[Deck] 错误: 牌桌不存在: " .. tostring(tableID))
        return {}, {}, false, {}
    end
    count = math.max(0, math.floor(count or 1))
    local deck = inst.Decks[player]
    local hand = inst.Hands[player]
    local drawn = {}
    local moraleHits = {}
    local overdraw = false
    local overdrawnCards = {}
    for _ = 1, count do
        if #deck == 0 then
            -- 士气伤害：第 N 次空抽造成 N 伤害（readme 7.1）
            inst.MoralDamage[player] = (inst.MoralDamage[player] or 0) + 1
            local dmg = inst.MoralDamage[player]
            moraleHits[player] = (moraleHits[player] or 0) + dmg
        else
            local card = table.remove(deck, #deck) -- 牌堆顶（数组末项）
            -- 手牌上限（readme 7.1）：已达上限 → 爆牌，卡不进手牌（仍随 drawn 返回）
            if #hand < self.MAX_HAND then
                table.insert(hand, card)
            else
                overdraw = true
                overdrawnCards[card] = true
            end
            table.insert(drawn, card)
        end
    end
    return drawn, moraleHits, overdraw, overdrawnCards
end

--[[
    重新调度（仅一次机会）：丢弃不想要的起始手牌 → 随机插入卡组（随机位置）→ 抽取等量替换

    @param tableID   string 牌桌唯一标识符
    @param player    string 玩家标识
    @param unwanted  table|nil 要丢弃的手牌卡牌列表（必须都在手牌中）
    @return boolean, string|nil, table 是否成功；失败原因；士气伤害表（补抽空抽时才有）
]]
function KARDS.Deck:Mulligan(tableID, player, unwanted)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    if inst.Mulliganed[player] then return false, "already_mulliganed" end

    unwanted = unwanted or {}
    local hand = inst.Hands[player]
    -- 校验：丢弃的牌必须都在手牌中
    for _, card in ipairs(unwanted) do
        local found = false
        for _, h in ipairs(hand) do
            if h == card then found = true break end
        end
        if not found then return false, "not_in_hand" end
    end

    -- 丢弃：从手牌移除 → 随机插入卡组（随机移动、插入）
    for _, card in ipairs(unwanted) do
        for i = #hand, 1, -1 do
            if hand[i] == card then
                table.remove(hand, i)
                self:InsertRandom(tableID, player, card)
                break
            end
        end
    end
    inst.Mulliganed[player] = true

    -- 抽取等量卡牌替换（补抽；卡组充足时无士气伤害）
    local drawn, moraleHits = self:Draw(tableID, player, #unwanted)
    return true, nil, moraleHits, drawn
end
