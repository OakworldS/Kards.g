--[[
    Kards 战斗牌桌客户端模块：三选一交互（cl_battle_pick.lua，2026-09-26 实现）

    职责（拆分 A2，2026-08-11 建文件占位）：KARDS 原作抽卡/发现机制：从服务端提供的
    候选卡中选择 1 张加入手牌。效果来源两种，「开发」与「观星」共用本演出：
      - 开发：从开发池随机 3 张选 1 加入手牌，其余卡不返回任何容器（开发池不一定是卡组）
      - 观星：从卡组顶 3 张选 1 加入手牌，其余返回卡组底

    两段演出：
      第一段（收到 KardsPickOffer）：三张候选卡在卡堆顶坐标重合生成 → 依次落到中左槽 /
        中槽 / 中右槽（KARDS.PickSlotPos），鼠标悬停的候选卡 z 上升（KARDS.PickHoverLift），
        第一段动画播完后才允许点击选择。
      第二段（收到 KardsPickResult）：选中卡移到并加入手牌扇形分布（本方视角）；其余卡按
        来源分支出场（开发：xy 平面逆时针旋转 + z 下降 + 向视角左下移出；观星：先移到牌桌
        上方贴桌翻面，再落到卡组底）。进行期间鼠标保持呼出，动画播完后清空状态。

    视角三分（与抽牌/重新调度同源）：
      self     本方发起（inTable.slot == 发起槽）：三张看卡面（KardsTableDrawFace 定向只
               发本方），第二段选中卡入手牌扇形
      enemy    本方为发起方的对手（Perspective.LocalView 有效）：三张全程卡背朝上，
               第二段选中卡由中槽向该方前移一部分（前线 xy 前方）且不旋转
      spectate 观战者（Perspective.LocalView == nil）：三张卡背朝上，第二段选中卡向该方
               前移一部分并旋转 45° 倾向该方玩家

    挂载：cl_init.lua include 本文件（cl_battle_state.lua 之后，见加载链注释）。
    约定：常驻钩子/状态挂 KARDS 命名空间（KARDS.BattlePick），不新增 cl_init.lua main
          chunk 局部槽压力；跨段落共享状态读写走 KARDS.BattleState。
]]

if not CLIENT then return end

KARDS = KARDS or {}

-- 三选一交互状态（跨 Think 钩子共享）
KARDS.BattlePick = KARDS.BattlePick or {
    active    = false, -- 第一段动画播完后置 true（此时可选择）
    submitted = false, -- 已提交选择（本方视角）
    finishing = false, -- 已收到结果，第二段动画进行中/待清理
    slot      = nil,   -- 发起槽位（1/2）
    kind      = nil,   -- 效果来源 "develop" | "scry"
    view      = nil,   -- 视角 "self" | "enemy" | "spectate"
    viewSlot  = nil,   -- 视角槽位（左右镜像基准）
    tableEnt  = nil,   -- 发起牌桌实体
    ents      = {},    -- 候选实体（按候选序号；本端尚未传播的无效实体写 false 占位，不留空洞）
    count     = 0,     -- 本次候选张数（服务端下发，供按下标遍历到数组末尾）
    prevLeft  = false, -- 左键上一帧状态（上升沿判定）
}

local BP = KARDS.BattlePick

-- 清空三选一交互（退出牌桌 / 新对局 / 对局结束 / 第二段动画播完）
function KARDS.BattlePickReset()
    BP.active = false
    BP.submitted = false
    BP.finishing = false
    BP.slot = nil
    BP.kind = nil
    BP.view = nil
    BP.viewSlot = nil
    BP.tableEnt = nil
    BP.ents = {}
    BP.count = 0
    BP.prevLeft = false
end

-- 视角左侧 x 符号（P1 视角左侧为 +x，与爆牌弃牌槽 P1LP2RSlot 判定一致）
local function LeftSign(viewSlot)
    return (viewSlot == 2) and -1 or 1
end

-- 发起方所在一侧的 y 符号（P1 槽位在 +y 端，见 shared.lua SlotLocalPos）：即「前线 xy 前方」
local function SideSign(slot)
    return (slot == 1) and 1 or -1
end

-- 候选卡射线命中判定（同 HitMulliganCard：阈值 10^2）
local function HitPickCard()
    local ply = LocalPlayer()
    if not IsValid(ply) then return nil end
    local pos = KARDS.BattleCamera.ViewPos or ply:EyePos()
    local dir = gui.ScreenToVector(gui.MouseX(), gui.MouseY())
    if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then return nil end
    local bestEnt, bestD = nil, 100
    -- 按下标遍历（候选实体可能因尚未传播为 false），跳过无效项
    for i = 1, BP.count do
        local e = BP.ents[i]
        if IsValid(e) then
            local d = KARDS.RayPointDistSqr(pos, dir, e:GetPos())
            if d < bestD then bestEnt, bestD = e, d end
        end
    end
    return bestEnt
end

-- ====================================================================
-- 第一段：候选卡依次落到三槽
-- ====================================================================
net.Receive("KardsPickOffer", function()
    local tableEnt = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local kind = net.ReadString()
    local n = net.ReadUInt(8)
    local cnt = math.min(n, 8)
    local ents = {}
    for i = 1, cnt do
        local e = net.ReadEntity()
        -- 无效/未传播实体写 false 占位，保证数组无空洞（其余候选仍可被遍历命中）
        ents[i] = IsValid(e) and e or false
    end
    if slot ~= 1 and slot ~= 2 then return end
    if not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    -- 视角三分
    local inTable = KARDS.BattleState.inTable
    local mine = inTable and inTable.slot
    local view
    if mine == slot then
        view = "self"
    elseif KARDS.Perspective and KARDS.Perspective.LocalView == nil then
        view = "spectate"
    else
        view = "enemy"
    end
    BP.active = false
    BP.submitted = false
    BP.finishing = false
    BP.slot = slot
    BP.kind = kind
    BP.view = view
    BP.tableEnt = tableEnt
    -- 镜像基准（2026-10-03 联机排查 NEW-1）：取本地视角槽位；观战（LocalView 为 nil）时
    -- 跟随发起方槽位，不再恒按 P1 侧映射。本方视角下 LocalView 即 slot，语义不变。
    BP.viewSlot = (KARDS.Perspective and KARDS.Perspective.LocalView) or slot
    BP.ents = ents
    BP.count = cnt
    BP.prevLeft = false
    local faceUp = (view == "self")
    -- 文字朝向（P1 槽 180 / P2 槽 0，与 cl_battle_mulligan DeckDrawDealHand 一致）
    local endYaw = (slot == 1) and 180 or 0
    for i = 1, cnt do
        local e = ents[i]
        if IsValid(e) then
            if faceUp then
                -- 本方看卡面（卡面标识由服务端 KardsTableDrawFace 定向只发本方；NW 未就绪时
                -- 入队由 cl_init.lua KardsDrawFacePending 重试）
                KARDS.InitDrawCardFace(e)
                KARDS.drawFacePending[e] = true
            end
            e:SetNoDraw(false)
            -- 从卡组堆叠剥离（同抽牌临时卡 KardsTableDeckDraw 处理）：Kards_CardRole
            -- 为 battledeck 的实体每帧被 KardsTableEntitiesThink 兜底 SetNoDraw(false)，
            -- 不标记则第二段 SetNoDraw(true) 出场后会被立刻重新显示
            KARDS.battleDeckDrawn[e] = true
            -- 卡堆顶（卡背朝上）→ 槽位（本方翻面朝上 / 其余视角保持卡背），错峰发牌
            KARDS.AnimPlayer:Play(e, {
                { t = 0, pos = e:GetLocalPos(), ang = Angle(180, e:GetLocalAngles().y, 0) },
                { t = KARDS.PickDealDur, pos = KARDS.PickSlotPos(i, BP.viewSlot),
                  ang = Angle(faceUp and 0 or 180, endYaw, 0) },
            }, {
                group = "pickDeal",
                delay = (i - 1) * KARDS.PickDealStagger,
                onStart = (i == 1) and function() KARDS.PlayKardsSound("draw") end or nil,
            })
        end
    end
    KARDS.UpdateTableMouse()
end)

-- ====================================================================
-- 第二段：选择完成
-- ====================================================================
-- 开发：其余卡 xy 平面逆时针旋转 + z 下降 + 向视角左下移出（旋转方向按视角左侧符号取定）
local function PlayDevelopExit(e, index, slotPos, leftSign, sideSign)
    local yaw = e:GetLocalAngles().y
    local exitPos = slotPos + Vector(leftSign * KARDS.PickExitDist, sideSign * KARDS.PickExitDist, -KARDS.PickSpinDropZ)
    KARDS.AnimPlayer:Play(e, {
        { t = 0, pos = slotPos, ang = Angle(0, yaw, 0) },
        { t = KARDS.PickSpinDur, pos = exitPos, ang = Angle(0, yaw - leftSign * KARDS.PickSpinYaw, 0) },
    }, {
        group = "pickResult",
        onComplete = function(target) if IsValid(target) then target:SetNoDraw(true) end end,
    })
end

-- 观星：其余卡先移到牌桌上方贴桌（不悬空）并翻面朝下，再落到卡组底
local function PlayScryReturn(e, index, slotPos, slot)
    local pileIdx = (slot == 1) and 1 or 2
    local pilePos = KARDS.PileBase[pileIdx]
    local pileYaw = KARDS.PileYaw[pileIdx]
    local yaw = e:GetLocalAngles().y
    KARDS.AnimPlayer:Play(e, {
        { t = 0, pos = slotPos, ang = Angle(e:GetLocalAngles().p, yaw, 0) },
        { t = KARDS.ScryFlipDur, pos = Vector(slotPos.x, slotPos.y, KARDS.ScryTableZ), ang = Angle(180, yaw, 0) },
        { t = KARDS.ScryFlipDur + KARDS.ScryToBottomDur, pos = Vector(pilePos.x, pilePos.y, pilePos.z),
          ang = Angle(180, pileYaw, 0) },
    }, {
        group = "pickResult",
        onComplete = function(target) if IsValid(target) then target:SetNoDraw(true) end end,
    })
end

net.Receive("KardsPickResult", function()
    local tableEnt = net.ReadEntity()
    local chosenIndex = net.ReadUInt(8)
    local handIndex = net.ReadUInt(8)
    local handTotal = net.ReadUInt(8)
    if not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    if not BP.slot or BP.finishing then return end
    local slot = BP.slot
    local view = BP.view or "self"
    local kind = BP.kind
    local viewSlot = BP.viewSlot or slot
    local leftSign = LeftSign(viewSlot)
    local sideSign = SideSign(slot)
    BP.finishing = true
    local chosenEnt = BP.ents[chosenIndex]
    -- 本方视角且选中卡确实进了手牌 → 飞入扇形；否则（未入手牌）按出场处理
    local intoHand = (view == "self") and (handIndex >= 1) and IsValid(chosenEnt)
    if intoHand then
        local pos, ang = KARDS.HandFanPos(slot, handIndex, handTotal)
        KARDS.BattleState.realHandCards[slot][chosenEnt] = handIndex
        KARDS.RenumberHand(slot, chosenEnt, handTotal) -- 其余手牌重排让位（选中卡排除在重排外）
        KARDS.AnimPlayer:Play(chosenEnt, {
            { t = 0, pos = chosenEnt:GetLocalPos(), ang = chosenEnt:GetLocalAngles() },
            { t = KARDS.PickToHandDur, pos = pos, ang = Angle(0, ang.y, 0) },
        }, { group = "pickResult" })
    end
    -- 选中卡（非本方视角 / 未入手牌）：敌方与观战视角按是否进手牌分流
    if IsValid(chosenEnt) and not intoHand then
        if view ~= "self" then
            -- 对手与观战（2026-10-03 联机排查 NEW-3/NEW-4）：选中卡确实进手牌时登记为该方手牌
            -- 并落扇形位。原实现登记后只向中心前移且收尾隐藏，导致手牌计数与扇形卡背数量不符，
            -- 动画结束又会被每帧兜底复活停在前移中点。未进手牌（手牌已满等）保持原前移出场。
            if handIndex >= 1 then
                local pos, ang = KARDS.HandFanPos(slot, handIndex, handTotal)
                KARDS.BattleState.realHandCards[slot][chosenEnt] = handIndex
                KARDS.RenumberHand(slot, chosenEnt, handTotal) -- 其余手牌重排让位（选中卡排除在重排外）
                ang.p = 180 -- 非本方槽一律卡背朝上（同 RenumberHand 的非本方分支）
                KARDS.AnimPlayer:Play(chosenEnt, {
                    { t = 0, pos = chosenEnt:GetLocalPos(), ang = Angle(180, chosenEnt:GetLocalAngles().y, 0) },
                    { t = KARDS.PickSpinDur, pos = pos, ang = ang },
                }, { group = "pickResult" })
            else
                local center = KARDS.PickSlotPos(2, viewSlot)
                local targetPos = center + Vector(0, sideSign * KARDS.PickEnemyShift, 0)
                -- 敌方视角：全程卡背朝上且不旋转；观战视角：45° 倾向该方玩家
                local targetAng = (view == "spectate")
                    and Angle(KARDS.PickSpecAngle, (slot == 1) and 180 or 0, 0)
                    or Angle(180, chosenEnt:GetLocalAngles().y, 0)
                KARDS.AnimPlayer:Play(chosenEnt, {
                    { t = 0, pos = chosenEnt:GetLocalPos(), ang = Angle(180, chosenEnt:GetLocalAngles().y, 0) },
                    { t = KARDS.PickSpinDur, pos = targetPos, ang = targetAng },
                }, {
                    group = "pickResult",
                    onComplete = function(target) if IsValid(target) then target:SetNoDraw(true) end end,
                })
            end
        else
            -- 本方视角但未入手牌（开发失败等）：与其余卡同款出场
            PlayDevelopExit(chosenEnt, chosenIndex, KARDS.PickSlotPos(chosenIndex, viewSlot), leftSign, sideSign)
        end
    end
    -- 其余候选卡（按下标遍历，跳过本端未传播的 false 占位与已失效实体）
    for i = 1, BP.count do
        local e = BP.ents[i]
        if IsValid(e) and i ~= chosenIndex then
            local slotPos = KARDS.PickSlotPos(i, viewSlot)
            if kind == "scry" then
                PlayScryReturn(e, i, slotPos, slot)
            else
                PlayDevelopExit(e, i, slotPos, leftSign, sideSign)
            end
        end
    end
    KARDS.UpdateTableMouse()
end)

-- ====================================================================
-- 动画驱动与选择交互（每帧）
-- ====================================================================
-- 第一段动画播完后启用选择；第二段动画播完后清空状态
hook.Add("Think", "KardsBattlePickUpdate", function()
    if not BP.slot then return end
    if not BP.active and not BP.submitted and not BP.finishing and not KARDS.AnimPlayer:Any("pickDeal") then
        BP.active = true
    end
    if BP.finishing then
        if not KARDS.AnimPlayer:Any("pickResult") then
            KARDS.BattlePickReset()
        end
    end
end)

-- 选择交互：悬停抬升 + 左键上升沿提交
hook.Add("Think", "KardsBattlePickSelect", function()
    if not BP.slot then return end
    -- 牌桌内鼠标恒呼出（开关由 KARDS.UpdateTableMouse 按 inTable 统一决定）
    KARDS.UpdateTableMouse()
    if not BP.active or BP.submitted or BP.finishing then
        BP.prevLeft = false
        return
    end
    -- 悬停：命中候选卡 z 上升（KARDS.PickHoverLift），其余回落槽位 z（每帧纠偏）
    local hover = HitPickCard()
    for i = 1, BP.count do
        local e = BP.ents[i]
        if IsValid(e) then
            local base = KARDS.PickSlotPos(i, BP.viewSlot)
            local z = (e == hover) and (base.z + KARDS.PickHoverLift) or base.z
            local cur = e:GetLocalPos()
            if math.abs(cur.x - base.x) > 0.01 or math.abs(cur.y - base.y) > 0.01 or math.abs(cur.z - z) > 0.01 then
                e:SetLocalPos(Vector(base.x, base.y, z))
            end
        end
    end
    -- 左键上升沿：命中候选卡则提交（仅本方视角可提交；对手/观战视角由服务端会话校验拒绝）
    local left = input.IsMouseDown(MOUSE_LEFT)
    if left and not BP.prevLeft and hover and BP.view == "self" then
        local index
        for i = 1, BP.count do
            if BP.ents[i] == hover then index = i break end
        end
        if index then
            BP.submitted = true
            BP.prevLeft = false
            KARDS.PlayKardsSound("select_card")
            net.Start("KardsPickChoose")
                net.WriteEntity(BP.tableEnt)
                net.WriteUInt(index, 8)
            net.SendToServer()
            KARDS.UpdateTableMouse()
            return
        end
    end
    BP.prevLeft = left
end)