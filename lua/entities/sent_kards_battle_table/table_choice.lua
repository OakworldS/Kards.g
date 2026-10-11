--[[
    抉择会话（table_choice.lua，2026-10-04）

    服务端职责：为「抉择」效果节点（choice 模板，sh_node_acts_choice.lua）提供
    「二选一」演出与选择挂起：
      1. 数据层效果结算途中经 ctx.specify.choicePicker 进入本模块（ENT:BeginChoice）：
         定向通知「打出方 + 观战者」开始演出（KardsChoiceOffer，含两张效果文本 T1/T2），
         随后 coroutine.yield 挂起，等待玩家选择。
      2. 打出方客户端点击选中一张效果卡 → 发送 KardsChoiceChoose → ENT:ResolveChoice
         以选中序号续跑协程（数据层按所选分支继续结算：返回值 true=效果一 / false=效果二）。
      3. 结算时广播 KardsChoiceResult（选中序号 + 所选 T）。

    可见性（2026-10-04 用户规格）：
      - 观战者可看到演出（收到 KardsChoiceOffer），且其两张卡面需要文本 → 一并定向发
        KardsTableDrawFace（与三选一候选卡同一通道；打出方本就有卡面，幂等）。
      - 敌方在演出期间完全看不到该卡：单独发 KardsChoiceHide（客户端 SetNoDraw），
        结算时随 KardsChoiceResult 解除隐藏，并由 KardsTableDrawFace 补发卡面，
        使其能显示该卡效果文本（默认完整表述，可经变量切为仅表述所选 T）。

    协程前提：BeginChoice 必须在协程内调用（真实玩家路径见 table_battledeck.lua 的
    KardsPlayCard 接收器；测试路径见 sv_fakeuser.lua 的协程）。非协程路径返回 1
    （缺省效果一），与执行器缺省分支一致，不会卡死。

    加载：init.lua include（table_pick.lua 之后）
]]

local ENT = scripted_ents.GetStored("sent_kards_battle_table").t

-- 选择超时（秒）：超时按效果一结算（玩家掉线/长时间不选时避免对局卡死）
local ChoiceTimeout = 20
-- 消息延迟（秒）：卡实体本 tick 可能刚创建，实体快照晚于 net 消息（同三选一 0.1s 先例）
local ChoiceMsgDelay = 0.1

--[[
    构造抉择选择注入（与 BuildPickSpecify 同型：随 opts.specify 传入效果执行上下文，
    执行器 sh_node_acts_choice.lua 经 ctx.specify.choicePicker 调用）。

    @param ply  Player 打出方
    @param slot number 打出方槽位
    @return table { choicePicker = fn(card, t1, t2) -> number 选中序号 1/2 }
]]
function ENT:BuildChoiceSpecify(ply, slot)
    return {
        choicePicker = function(card, t1, t2)
            return self:BeginChoice(ply, slot, card, t1, t2)
        end,
    }
end

-- ====================================================================
-- 接收者收集 / 卡面定向
-- ====================================================================

--[[
    收集抉择演出的「非敌方」接收者：打出方 + 所有观战者（排除敌方牌手）。
    @param ent  Entity 牌桌实体
    @param ply  Player 打出方玩家
    @return table Player 列表（可能为空）
]]
function ENT:ChoiceOfferTargets(ply)
    local targets = {}
    local enemy = nil
    if self.Slots then
        for _, p in pairs(self.Slots) do
            if IsValid(p) and p ~= ply then enemy = p break end
        end
    end
    if IsValid(ply) then targets[#targets + 1] = ply end
    for _, p in ipairs(player.GetAll()) do
        if p ~= ply and p ~= enemy then targets[#targets + 1] = p end
    end
    return targets, enemy
end

--[[
    定向补发抉择卡卡面（WriteEntity 卡实体 + 卡名/卡文件/类型，字段口径同三选一
    table_pick.lua 的候选卡面发送）。打出方本就有卡面（幂等），观战者与结算后的
    敌方据此显示卡面与 3D2D 效果文本。
    @param targets table Player 列表（空表不发送，避免污染 net.messageStarted）
    @param ent     Entity 抉择卡实体
    @param card    table 卡牌句柄
]]
function ENT:SendChoiceCardFace(targets, ent, card)
    if not IsValid(ent) or not card or #targets == 0 then return end
    net.Start("KardsTableDrawFace")
        net.WriteEntity(ent)
        net.WriteString(card:GetName())
        net.WriteString(card:GetName())
        net.WriteString(card:GetType())
    for _, p in ipairs(targets) do net.Send(p) end
end

--[[
    广播抉择演出开始（打出方 + 观战者；敌方不收）。
    @param session table 会话
]]
function ENT:BroadcastChoiceOffer(session)
    local targets = self:ChoiceOfferTargets(session.ply)
    if #targets == 0 then return end
    net.Start("KardsChoiceOffer")
        net.WriteEntity(self)
        net.WriteUInt(session.slot, 2)
        net.WriteEntity(IsValid(session.cardEnt) and session.cardEnt or NULL)
        net.WriteString(session.t1 or "")
        net.WriteString(session.t2 or "")
    for _, p in ipairs(targets) do net.Send(p) end
    -- 观战者需要卡面才能显示两张效果的 3D2D 文本（打出方已有，幂等）
    self:SendChoiceCardFace(targets, session.cardEnt, session.card)
end

--[[
    广播抉择结算：接收者 = 打出方 + 观战者 + 敌方（敌方据此解除隐藏、按变量显示文本）。
    @param session table 会话
    @param index   number 选中序号（1/2）
]]
function ENT:BroadcastChoiceResult(session, index)
    local chosenText = (index == 2) and (session.t2 or "") or (session.t1 or "")
    local targets, enemy = self:ChoiceOfferTargets(session.ply)
    if IsValid(enemy) then targets[#targets + 1] = enemy end
    if #targets == 0 then return end
    net.Start("KardsChoiceResult")
        net.WriteEntity(self)
        net.WriteUInt(session.slot, 2)
        net.WriteUInt(index, 2)
        net.WriteString(chosenText)
    for _, p in ipairs(targets) do net.Send(p) end
    -- 敌方结算后才可见该卡：补发卡面（3D2D 文本来源），客户端同时解除隐藏
    if IsValid(enemy) then
        self:SendChoiceCardFace({ enemy }, session.cardEnt, session.card)
    end
end

--[[
    抉择演出与选择挂起入口（数据层执行器经 ctx.specify.choicePicker 调用）。

    @param ply  Player 打出方
    @param slot number 打出方槽位（1/2）
    @param card table 抉择卡牌句柄（效果发起者）
    @param t1   string 效果一文本
    @param t2   string 效果二文本
    @return number 选中序号（1 = 效果一 / 2 = 效果二；协程内经 yield 由客户端选择决定）
]]
function ENT:BeginChoice(ply, slot, card, t1, t2)
    -- 协程前提：非协程路径不建会话（执行器缺省分支接管为效果一）
    local co = coroutine.running()
    if not co then return 1 end
    -- 卡实体解析（演出载体）：卡牌句柄 → 手牌实体映射
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local cardEnt = deck and deck.cardEnt and deck.cardEnt[card] or nil
    -- 实体缺失（异常时序/已被回收）：无法演出与交互，直接按效果一结算
    if not IsValid(cardEnt) then return 1 end
    -- 上一轮抉择尚未结算（理论上不可达：OnPlayCard 在 BeginChoice 处挂起，回合制下同一
    -- 时刻只可能有一个会话）：不重入创建新会话，直接按效果一返回，旧会话由其自身超时
    -- 兜底结算（避免在效果执行中途 resume 另一协程造成结算交错）
    local prev = self._kardsChoice
    if prev and not prev.resolved then
        print("[Kards] 抉择：存在未结算的旧会话，本轮按效果一结算（见 table_choice.lua）")
        return 1
    end
    local session = {
        ply = ply,
        slot = slot,
        card = card,
        cardEnt = cardEnt,
        t1 = t1,
        t2 = t2,
        at = CurTime(),
        co = co,
        resolved = false,
    }
    self._kardsChoice = session
    -- 敌方：演出期间隐藏该卡（结算时随 KardsChoiceResult 解除）
    local _, enemy = self:ChoiceOfferTargets(ply)
    if IsValid(enemy) then
        net.Start("KardsChoiceHide")
            net.WriteEntity(self)
            net.WriteEntity(cardEnt)
        net.Send(enemy)
    end
    -- 实体快照可能晚于 net 消息（同三选一 0.1s 延迟先例）
    timer.Simple(ChoiceMsgDelay, function()
        if not IsValid(self) or self._kardsChoice ~= session then return end
        self:BroadcastChoiceOffer(session)
    end)
    -- 超时兜底：按效果一结算（避免对局卡死）
    timer.Simple(ChoiceTimeout, function()
        if not IsValid(self) or self._kardsChoice ~= session or session.resolved then return end
        self:ResolveChoice(session, 1)
    end)
    return coroutine.yield(session)
end

--[[
    抉择结算：广播结果并续跑挂起的协程（幂等：已结算/会话已换则忽略）。

    @param session table 会话
    @param index   number 选中序号（1/2）
]]
function ENT:ResolveChoice(session, index)
    if not session or session.resolved then return end
    session.resolved = true
    if self._kardsChoice == session then self._kardsChoice = nil end
    index = (index == 2) and 2 or 1
    if IsValid(self) then
        self:BroadcastChoiceResult(session, index)
    end
    coroutine.resume(session.co, index)
end

-- 客户端提交选择（仅打出方；会话校验 + 槽位一致性）
net.Receive("KardsChoiceChoose", function(_, ply)
    local ent = net.ReadEntity()
    local index = net.ReadUInt(2)
    if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    local data = ply._kardsTable
    if not data or data.ent ~= ent then return end
    local session = ent._kardsChoice
    if not session or session.resolved or session.ply ~= ply then return end
    ent:ResolveChoice(session, index)
end)