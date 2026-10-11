--[[
    弃牌选择会话（table_discard.lua，2026-10-06）

    服务端职责：为「弃牌」操作中「手中 / 自选的一张卡」（无数值序数）路径提供手牌实体
    展示 + 玩家选择挂起与回传。
      1. 数据层 KARDS.Battle:SimDiscard 无卡且无数值序数时经弃牌选择回调
         （DiscardCallbacks / SetDiscardCallback，见 sh_battle_card.lua）进入本模块
         ENT:BeginDiscardPick：收集该方手牌实体，广播 KardsDiscardOffer，随后
         coroutine.yield 挂起等待选择。
      2. 客户端（该槽玩家 / kards_switch 代操作者）把本方手牌上移并高亮，点击一张手牌 +
         「确认」发送 KardsDiscardChoose → ENT:ResolveDiscard 以选中卡牌句柄续跑协程
         （数据层继续：移出手牌 + 弃牌刻 + 「弃牌」开始点效果链 + 触发手牌弃牌飞出动画）。
      3. 结算后 ENT:BroadcastDiscardResult 广播 KardsDiscardResult 关闭选择 UI。

    协程前提：BeginDiscardPick 必须在协程内调用（真实玩家路径见 table_battledeck.lua 的
    KardsPlayCard 接收器把 OnPlayCard 包进 coroutine.create；测试路径见 sv_fakeuser.lua）。
    非协程路径返回 nil，SimDiscard 放弃本次弃牌（返回 false），不会卡死。

    加载：init.lua include（table_choice.lua 之后）
]]

local ENT = scripted_ents.GetStored("sent_kards_battle_table").t

-- 选择超时（秒）：超时放弃本次弃牌（玩家掉线/长时间不选时避免对局卡死）
local DiscardTimeout = 20
-- 消息延迟（秒）：手牌实体为既有网络实体，仍沿用三选一 / 抉择的 0.1s 延迟先例，
-- 保证实体快照先于 net 消息到达客户端
local DiscardMsgDelay = 0.1

--[[
    收集该玩家手牌实体（顺序与手牌数组一致，供客户端按下标回传序号）。

    @param playerID string 手牌所有者（"P1" / "P2"）
    @return table { { ent = Entity, card = table }, ... }（按手牌顺序；无实体项跳过）
]]
function ENT:CollectDiscardHandEnts(playerID)
    local slot = (playerID == "P2") and 2 or 1
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local out = {}
    if not deck or not deck.cardEnt then return out end
    local hand = KARDS.Deck:GetHand(self.TableID, playerID) or {}
    for _, card in ipairs(hand) do
        local ent = deck.cardEnt[card]
        if IsValid(ent) then out[#out + 1] = { ent = ent, card = card } end
    end
    return out
end

--[[
    广播弃牌选择开始（手牌实体列表；本桌所有客户端收到，仅该槽视角显示交互 UI）。

    @param session table 会话
]]
function ENT:BroadcastDiscardOffer(session)
    net.Start("KardsDiscardOffer")
        net.WriteEntity(self)
        net.WriteUInt(session.slot, 8)
        net.WriteUInt(#session.items, 8)
        for _, it in ipairs(session.items) do
            net.WriteEntity(it.ent)
        end
    net.Broadcast()
end

--[[
    开启一轮弃牌选择：收集手牌实体 → 广播 offer → 挂起等待选择。

    @param playerID string 手牌所有者（SimDiscard 的 player 参数）
    @return table|nil 玩家选中的卡牌句柄（协程内经 yield 返回）；非协程路径返回 nil
]]
function ENT:BeginDiscardPick(playerID)
    -- 协程前提：非协程路径不建会话（SimDiscard 缺省放弃）
    local co = coroutine.running()
    if not co then return nil end
    local slot = (playerID == "P2") and 2 or 1
    local items = self:CollectDiscardHandEnts(playerID)
    if #items == 0 then return nil end
    local session = {
        playerID = playerID,
        slot = slot,
        items = items,
        at = CurTime(),
        co = co,
    }
    self._kardsDiscard = session
    timer.Simple(DiscardMsgDelay, function()
        if not IsValid(self) or self._kardsDiscard ~= session then return end
        self:BroadcastDiscardOffer(session)
    end)
    return coroutine.yield(session)
end

--[[
    广播弃牌选择结束（关闭客户端选择 UI）。

    @param slot        number 发起槽位
    @param chosenIndex number 选中序号（0 = 未选择/超时放弃）
]]
function ENT:BroadcastDiscardResult(slot, chosenIndex)
    net.Start("KardsDiscardResult")
        net.WriteEntity(self)
        net.WriteUInt(slot, 8)
        net.WriteUInt(chosenIndex or 0, 8)
    net.Broadcast()
end

--[[
    提交选择并续跑协程：resume 后数据层完成移出手牌、弃牌刻、弃牌开始点效果链与飞出动效广播。

    @param session table 会话
    @param card    table|nil 选中的卡牌句柄（nil = 放弃）
    @param index   number 选中序号（0 = 放弃）
    @return boolean, any resume 结果
]]
function ENT:ResolveDiscard(session, card, index)
    if not session or self._kardsDiscard ~= session then return false, nil end
    self._kardsDiscard = nil
    self:BroadcastDiscardResult(session.slot, index or 0)
    local ok, err = coroutine.resume(session.co, card)
    if not ok then
        print("[Kards] 弃牌选择续跑出错：" .. tostring(err))
    end
    return ok, err
end

-- ====================================================================
-- 选择回传 / 超时与中断
-- ====================================================================

net.Receive("KardsDiscardChoose", function(_, ply)
    local ent = net.ReadEntity()
    local index = net.ReadUInt(8)
    if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    local data = ply._kardsTable
    if not data or data.ent ~= ent then return end
    local session = ent._kardsDiscard
    -- 仅发起槽位可提交（data.slot 为操作身份槽位，kards_switch 代操作时随之切换）
    if not session or data.slot ~= session.slot then return end
    local item = session.items[index]
    if not item then return end
    ent:ResolveDiscard(session, item.card, index)
end)

-- 超时（每帧）：超时放弃本次弃牌（该帧只处理一次）
hook.Add("Think", "KardsDiscardTimeoutCheck", function()
    for _, ent in ipairs(ents.FindByClass("sent_kards_battle_table")) do
        local session = ent._kardsDiscard
        if session and (CurTime() - session.at) > DiscardTimeout then
            ent:ResolveDiscard(session, nil, 0)
        end
    end
end)
