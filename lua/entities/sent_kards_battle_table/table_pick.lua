--[[
    三选一会话（table_pick.lua，2026-09-26）

    服务端职责：为「开发」「观星」效果提供三张候选卡的实体展示 + 玩家选择挂起与回传。
      1. 数据层效果结算途中经 ctx.specify.developPicker / scryPicker 进入本模块
         （ENT:BeginPick），生成三张候选卡实体（同一坐标重合，位于该槽卡堆顶），
         广播 KardsPickOffer，随后 coroutine.yield 挂起，等待玩家选择。
      2. 客户端展示三张候选卡并点击选择，发送 KardsPickChoose → ENT:ResolvePick
         以选中卡续跑协程（数据层继续结算：移出卡组、插入手牌）。
      3. 结算完成后 ENT:FinishPick 广播 KardsPickResult（选中序号 + 手牌序号与总张数）
         并延迟回收未选中的候选实体。

    协程前提：BeginPick 必须在协程内调用（真实玩家路径见 table_battledeck.lua 的
    KardsPlayCard 接收器；测试路径见 sv_fakeuser.lua 的协程）。非协程路径返回 nil，
    由数据层缺省分支处理（开发取第 3 张候选，观星取顶张），不会卡死。

    同一张卡多次开发：上一轮的结果在下一轮 BeginPick 时先行广播（此时上一轮已插入
    手牌，手牌序号可算），保证客户端按「上一轮结果 → 本轮展开」的顺序播放。

    实体生命周期：候选实体经 ENT:SpawnBattleDeckCard 生成并登记进 deck.drawEnts /
    entCard / cardEnt（与抽牌临时卡同套链路，退出牌桌/牌桌销毁由 ExitSlot 统一清理）。
    选中卡的实体接管为手牌实体；未选中两张在 PickCleanupDelay 秒后回收。
]]

local ENT = scripted_ents.GetStored("sent_kards_battle_table").t

-- 选择超时（秒）：超时按第一张候选结算（玩家掉线/长时间不选时避免对局卡死）
local PickTimeout = 20
-- 第二段动画播完后回收未选中候选实体的延迟（秒）
local PickCleanupDelay = 2.0

--[[
    生成一张三选一候选卡实体：位置取该槽卡堆顶（公式与 SpawnDeckDrawCard 一致），
    模型副本后缀 _p<serial>_<index>（与卡堆/其它抽牌临时卡的 manifest 互不干扰），
    卡背朝上（pitch 180）等待客户端第一段动画翻面落位。

    @param slot   number 发起槽位（1/2）
    @param card   table 候选卡牌句柄
    @param index  number 候选序号（1..3）
    @param serial number 本桌三选一序号（模型副本唯一化）
    @return Entity|nil
]]
function ENT:SpawnPickCandidate(slot, card, index, serial)
    local safeName = self:DeckSafeName(card:GetID())
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local slotIdx = (slot == 1) and 1 or 2
    local base = self.DeckSlotBase[slotIdx]
    -- 位置：当前可见卡堆顶 + 半张卡厚度余量（与 SpawnDeckDrawCard 同款，避免 z-fight）
    local topZ = base.z + self:DeckPileWorldHeight(deck and deck.currentTier or 40) + 0.05
    local suffix = "_p" .. serial .. "_" .. index
    local ent = self:SpawnBattleDeckCard(card, safeName,
        Vector(base.x, base.y, topZ), self.DeckSlotYaw[slotIdx], suffix)
    if not IsValid(ent) then return nil end
    -- 绑定牌桌父级（与卡堆/抽牌临时卡一致；RegisterChild 重置局部角度为平躺，故随后重施卡堆 yaw）
    if self._kardsChildSystem and self._kardsChildSystem:RegisterChild(ent, Vector(base.x, base.y, topZ)) then
        ent:SetLocalAngles(Angle(180, self.DeckSlotYaw[slotIdx], 0))
    end
    ent:SetNWString("Kards_DeckSafeName", safeName) -- 客户端卡面初始化（InitDrawCardFace）
    ent:SetNWInt("Kards_DeckSlot", slot)
    if deck then
        -- 登记临时卡（退出牌桌/牌桌销毁经 ExitSlot 统一清理）
        deck.drawEnts = deck.drawEnts or {}
        deck.drawEnts[#deck.drawEnts + 1] = ent
        deck.entCard = deck.entCard or setmetatable({}, { __mode = "k" })
        deck.entCard[ent] = card
        deck.cardEnt = deck.cardEnt or setmetatable({}, { __mode = "k" })
        deck.cardEnt[card] = ent
    end
    return ent
end

--[[
    广播三选一开始（候选实体三张，位置重合于卡堆顶）。

    @param session table 会话（见 ENT:BeginPick）
]]
function ENT:BroadcastPickOffer(session)
    net.Start("KardsPickOffer")
        net.WriteEntity(self)
        net.WriteUInt(session.slot, 8)
        net.WriteString(session.kind)
        net.WriteUInt(#session.candidates, 8)
        for i = 1, #session.candidates do
            local e = session.ents[i]
            net.WriteEntity(IsValid(e) and e or NULL)
        end
    net.Broadcast()
end

--[[
    开启一轮三选一：生成候选实体 → 广播 offer → 挂起等待选择。

    @param ply        Player 发起玩家（卡面只发给他；测试路径为代操作者）
    @param slot       number 发起槽位
    @param kind       string "develop" | "scry"
    @param candidates table 候选卡牌句柄数组
    @return table|nil 玩家选中的卡牌句柄（协程内经 yield 返回）；非协程路径返回 nil
]]
function ENT:BeginPick(ply, slot, kind, candidates)
    if type(candidates) ~= "table" or #candidates == 0 then return nil end
    -- 协程前提：非协程路径不建会话（数据层缺省分支接管）
    local co = coroutine.running()
    if not co then return nil end
    -- 同一张卡多次开发：上一轮结果先广播（此刻上一轮已插入手牌，手牌序号可算），
    -- 保证客户端先播上一轮二段动画、再播本轮展开
    local prev = self._kardsPick
    if prev then self:FinishPick(prev, prev.chosen, prev.chosenIndex) end
    local cands = {}
    for i = 1, #candidates do cands[i] = candidates[i] end
    self._kardsPickSerial = (self._kardsPickSerial or 0) + 1
    local serial = self._kardsPickSerial
    local ents = {}
    for i, c in ipairs(cands) do
        ents[i] = self:SpawnPickCandidate(slot, c, i, serial)
    end
    -- 发起方卡面定向（与手牌卡面同款 KardsTableDrawFace）：其余客户端保持卡背。
    -- 仅当 ply 确为本槽位操作者时发送：伪用户接管对方时 ply 为代操作者（本方），
    -- 其视角应看到卡背（规划：敌方开发友方始终见卡背），故不发卡面
    local plyData = IsValid(ply) and ply._kardsTable or nil
    if plyData and plyData.ent == self and plyData.slot == slot then
        for i, c in ipairs(cands) do
            local e = ents[i]
            if IsValid(e) then
                net.Start("KardsTableDrawFace")
                    net.WriteEntity(e)
                    net.WriteString(c:GetName())
                    -- 卡文件字段与其余三处发送点（抽牌 / 返回手牌 / 洗入）一致取 GetName：
                    -- 开发候选用克隆卡时 GetID() 带 _copy 后缀，客户端 cardFaces 的文件名随之失效，
                    -- 指向机制 KARDS.GetCardEffectNodeInfo 按该文件名查卡信息会落空，开发得来的
                    -- 指令卡无法进入指向模式（卡名与类型不受影响）
                    net.WriteString(c:GetName())
                    net.WriteString(c:GetType())
                net.Send(ply)
            end
        end
    end
    local session = {
        ply = ply,
        slot = slot,
        kind = kind,
        candidates = cands,
        ents = ents,
        serial = serial,
        at = CurTime(),
        co = co,
    }
    self._kardsPick = session
    -- 候选实体本 tick 刚创建，实体快照可能晚于 net 消息（同抽牌广播 0.1s 延迟先例）
    timer.Simple(0.1, function()
        if not IsValid(self) or self._kardsPick ~= session then return end
        self:BroadcastPickOffer(session)
    end)
    return coroutine.yield(session)
end

--[[
    三选一结算收尾：广播结果（选中序号 + 选中卡的手牌序号与总张数）+ 回收未选中候选。

    @param session     table 会话
    @param chosen      table 选中的卡牌句柄
    @param chosenIndex number 选中候选序号（1..n）
]]
function ENT:FinishPick(session, chosen, chosenIndex)
    if not session then return end
    chosenIndex = chosenIndex or 0
    local playerID = (session.slot == 1) and "P1" or "P2"
    local hand = KARDS.Deck:GetHand(self.TableID, playerID) or {}
    local handIndex, handTotal = 0, #hand
    for i, c in ipairs(hand) do
        if c == chosen then handIndex = i break end
    end
    -- 选中卡的实际实体接管为手牌实体：候选允许重复（同卡句柄被随机抽中多次）时，
    -- 覆盖 SpawnPickCandidate 的末次登记，保证 entCard / cardEnt 指向玩家真正选中的那个
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[session.slot]
    local chosenEnt = session.ents[chosenIndex]
    if deck and chosen and IsValid(chosenEnt) then
        deck.entCard = deck.entCard or setmetatable({}, { __mode = "k" })
        deck.entCard[chosenEnt] = chosen
        deck.cardEnt = deck.cardEnt or setmetatable({}, { __mode = "k" })
        deck.cardEnt[chosen] = chosenEnt
    end
    net.Start("KardsPickResult")
        net.WriteEntity(self)
        net.WriteUInt(chosenIndex, 8)
        net.WriteUInt(handIndex, 8) -- 0 = 未入手牌（客户端按出场处理）
        net.WriteUInt(handTotal, 8)
    net.Broadcast()
    -- 未选中的候选实体：第二段动画播完后回收（延迟销毁先例见 KardsDeploySwitch）
    for i = 1, #session.candidates do
        local victim = session.ents[i]
        if i ~= chosenIndex and IsValid(victim) then
            timer.Simple(PickCleanupDelay, function()
                if not IsValid(victim) then return end
                if IsValid(self) and self._kardsChildSystem then
                    if not self._kardsChildSystem:RemoveChild(victim) then victim:Remove() end
                else
                    victim:Remove()
                end
            end)
        end
    end
end

--[[
    提交选择并续跑协程：resume 后若协程未开启新一轮三选一，则清空会话并收尾
    （广播结果 + 回收未选中候选）。收尾必须在 resume 返回后进行——数据层在此刻才
    完成「移出卡组、插入手牌」，手牌序号才能算准。

    @param session     table 会话
    @param chosen      table 选中的卡牌句柄
    @param chosenIndex number 选中候选序号
    @return boolean, any resume 结果（供伪用户控制台续跑后输出下一次挂起提示）
]]
function ENT:ResolvePick(session, chosen, chosenIndex)
    if not session or self._kardsPick ~= session then return false, nil end
    session.chosen, session.chosenIndex = chosen, chosenIndex
    local ok, err = coroutine.resume(session.co, chosen)
    if not ok then
        print("[Kards] 三选一续跑出错：" .. tostring(err))
    end
    if self._kardsPick == session then
        -- 协程已结束（未开启下一轮）：清空会话
        self._kardsPick = nil
    else
        -- 下一轮 BeginPick 已先行收尾并广播本轮结果，此处不重复
        return ok, err
    end
    self:FinishPick(session, chosen, chosenIndex)
    return ok, err
end

--[[
    构造真实玩家打出的选择注入（table_battledeck.lua KardsPlayCard 接收器传入
    OnPlayCard 的 extraOpts.specify）：开发与观星共用同一注入点，与伪用户控制台
    的桥函数同名同义（sv_fakeuser.lua）。

    @param ply  Player 发起玩家
    @param slot number 发起槽位
    @return table { developPicker = fn, scryPicker = fn }
]]
function ENT:BuildPickSpecify(ply, slot)
    return {
        developPicker = function(candidates)
            return self:BeginPick(ply, slot, "develop", candidates)
        end,
        scryPicker = function(candidates)
            return self:BeginPick(ply, slot, "scry", candidates)
        end,
    }
end

-- ====================================================================
-- 选择回传 / 超时与中断
-- ====================================================================

net.Receive("KardsPickChoose", function(_, ply)
    local ent = net.ReadEntity()
    local index = net.ReadUInt(8)
    if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    local data = ply._kardsTable
    if not data or data.ent ~= ent then return end
    local session = ent._kardsPick
    if not session or session.ply ~= ply then return end
    local chosen = session.candidates[index]
    if not chosen then return end
    ent:ResolvePick(session, chosen, index)
end)

-- 超时与中断（每帧）：超时或发起者离桌时按第一张候选结算（该帧只处理一次）
hook.Add("Think", "KardsPickTimeoutCheck", function()
    for _, ent in ipairs(ents.FindByClass("sent_kards_battle_table")) do
        local session = ent._kardsPick
        if session then
            local expired = (CurTime() - session.at) > PickTimeout
            local owner = session.ply
            local ownerGone = not IsValid(owner)
                or owner._kardsTable == nil
                or owner._kardsTable.ent ~= ent
            if expired or ownerGone then
                ent:ResolvePick(session, session.candidates[1], 1)
            end
        end
    end
end)