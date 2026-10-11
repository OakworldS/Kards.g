--[[
    Kards 战斗牌桌客户端模块：洗入动画（cl_battle_shuffle.lua，2026-09-26 缺口 D）

    数据层 shuffleInto 三来源统一经 ShuffleInto 事件 → 实体层 BroadcastShuffleInto
    建载体并广播 KardsShuffleInto → 本模块按载体来源与视角三分播关键帧动画。

    载体来源 from（服务端下发，编码载体本身而非选择来源）：
      1 = 手牌实体（既有手牌卡原地起飞）
      2 = 场上单位（服务端已在其原位换成正常卡模型载体）
      3 = 凭空生成（服务端已在屏幕右外侧生成）

    视角三分（同抽牌动画惯例）：
      本方（inTable.slot == slot）：手牌 → 右槽 → 翻面入卡组
      对方（LocalView ~= nil）：手牌先 z 轴独立升到手牌上方，不翻转，直接移入卡组
      观战（LocalView == nil）：手牌直接飞入卡组并同时翻转
    多张同刻洗入（2026-09-27 用户规格）：第一张以外的卡依次错峰半个首段时长到位，展示位
    取右槽且 z 逐张减少（相对牌桌平面下移），随后同样错峰飞向卡组中间。

    挂载：cl_init.lua include 本文件（cl_battle_mulligan.lua 之后）。
    依赖 cl_init.lua 末尾桥接导出（KARDS.CenterSlotPos / DisplaySlots / CrossSlotFor /
    RenumberHand / HandCount / HandFanPos / InitDrawCardFace / AnimPlayer / BattleState）。
]]

KARDS = KARDS or {}

-- 动画数值常量（时长秒 / 距离世界单位）
local ShuffleToSlotDur = 0.45  -- 手牌/凭空生成 → 中槽或右槽的飞行时长
local ShuffleHoldField = 0.75  -- 场上单位来源在中槽的停留时长（用户指定：换算完成后再待 0.75 秒）
local ShuffleFlipDur   = 0.35  -- 翻面并入卡组的时长
local ShuffleRiseDur   = 0.3   -- 对方视角：手牌 z 轴独立上升段时长
local ShuffleRiseZ     = 6     -- 对方视角：手牌 z 轴上升量（升至所有手牌之上）
-- 多张同刻洗入的错峰与排布（2026-09-27 用户规格）：
local ShuffleQueueDropZ    = 1.6 -- 第一张以外的卡每张相对牌桌平面下移量（z 逐张减少，张数可见）
local ShuffleStaggerBudget = 0.9 -- 全部错峰的总预算（服务端兜底 2.5 秒减去最长单卡分支 1.55 秒）

--[[
    单张洗入动画（关键帧由载体来源与视角决定）

    @param ent     Entity 动画载体（服务端网络实体，客户端不可 Remove）
    @param slot    number 洗入方槽位（1/2）
    @param from    number 载体来源（1手牌 / 2场上 / 3凭空生成）
    @param endPos  Vector 卡组终点（牌桌局部坐标，服务端下发）
    @param isMine  boolean 是否本方视角
    @param obs     boolean 是否观战视角
    @param index   number|nil 本批中的序位（1 起，缺省 1）
    @param total   number|nil 本批张数（缺省 1）
]]
local function ShuffleAnim(ent, slot, from, endPos, isMine, obs, index, total)
    ent:SetNoDraw(false)
    -- 卡面（2026-08-18 规划 B1）：卡名只在 own 客户端的 cardFaces 表内，非本方调用
    -- InitDrawCardFace 无标识 → 内部返回 false 保持卡背（不泄露牌面）
    KARDS.InitDrawCardFace(ent)
    KARDS.drawFacePending[ent] = true
    local startPos = ent:GetLocalPos()
    local startAng = ent:GetLocalAngles()
    -- 展示位统一取右槽（2026-09-27 用户规格：洗入卡与弃置卡同为右槽）。多张同刻洗入时，
    -- 第一张以外的卡依次错峰半个首段时长到位（相邻到位时刻相差首段时长的一半），且 z 逐张
    -- 减少、相对牌桌平面下移，使同一批洗入的张数看得见。
    index = index or 1
    total = total or 1
    local stagger = 0
    if total > 1 then
        stagger = math.min(ShuffleToSlotDur * 0.5, ShuffleStaggerBudget / (total - 1))
    end
    local lag = (index - 1) * stagger
    local rightPos = KARDS.DisplaySlots[KARDS.CrossSlotFor(slot, "right")].pos
        + Vector(0, 0, -ShuffleQueueDropZ * (index - 1))
    -- 平躺正面朝上的朝向：取该方手牌扇形最终角度（HandFanPos 服务端同款），
    -- 保证文字朝向与该方手牌一致
    local _, fanAng = KARDS.HandFanPos(slot, 1, 1)
    local handYaw = fanAng and fanAng.y or ((slot == 1) and 0 or 180)
    local flatAng = Angle(0, handYaw, 0)          -- 平躺正面朝上
    local buriedAng = Angle(180, handYaw, 0)      -- 卡背朝上（埋入卡组）
    local frames
    if from == 1 then
        -- 手牌来源：手牌数组已由数据层移除、实体登记已由服务端摘除
        -- （服务端 BroadcastShuffleInto）；此处清本地手牌登记并按新张数重排扇形，
        -- 避免起飞后扇形区残留幽灵卡
        if KARDS.BattleState.realHandCards[slot] then
            KARDS.BattleState.realHandCards[slot][ent] = nil
        end
        -- 2026-10-03 联机排查 NEW-10：同步清远程拖拽残留。KardsRemoteDragThink 注册晚于
        -- 动画驱动且每帧无条件写入位置与角度，残留会把该卡钉在最后同步位置覆盖本段动画
        if KARDS.BattleState.remoteDrags then KARDS.BattleState.remoteDrags[ent] = nil end
        KARDS.RenumberHand(slot, ent, KARDS.HandCount(slot))
        if isMine then
            frames = {
                { t = 0, pos = startPos, ang = startAng },
                { t = ShuffleToSlotDur + lag, pos = rightPos, ang = flatAng },
                { t = ShuffleToSlotDur + lag + ShuffleFlipDur, pos = endPos, ang = buriedAng },
            }
        elseif obs then
            -- 观战：直接一段飞入卡组，同时翻转
            frames = {
                { t = 0, pos = startPos, ang = startAng },
                { t = ShuffleToSlotDur + lag + ShuffleFlipDur, pos = endPos, ang = buriedAng },
            }
        else
            -- 对方：先 z 轴独立升到手牌上方（保持 x/y 与角度），不翻转，再直接入卡组
            frames = {
                { t = 0, pos = startPos, ang = startAng },
                { t = ShuffleRiseDur + lag, pos = startPos + Vector(0, 0, ShuffleRiseZ), ang = startAng },
                { t = ShuffleRiseDur + lag + ShuffleFlipDur, pos = endPos, ang = startAng },
            }
        end
    elseif from == 3 then
        -- 凭空生成：服务端已在屏幕右外侧生成，先移到该方视角右槽，再翻面入卡组
        frames = {
            { t = 0, pos = startPos, ang = startAng },
            { t = ShuffleToSlotDur + lag, pos = rightPos, ang = flatAng },
            { t = ShuffleToSlotDur + lag + ShuffleFlipDur, pos = endPos, ang = buriedAng },
        }
    else
        -- 场上单位来源：服务端已在其原位换成正常卡模型，先移到右槽停留 0.75 秒，再翻面入卡组
        frames = {
            { t = 0, pos = startPos, ang = startAng },
            { t = ShuffleToSlotDur + lag, pos = rightPos, ang = flatAng },
            { t = ShuffleToSlotDur + lag + ShuffleHoldField, pos = rightPos, ang = flatAng },
            { t = ShuffleToSlotDur + lag + ShuffleHoldField + ShuffleFlipDur, pos = endPos, ang = buriedAng },
        }
    end
    KARDS.AnimPlayer:Play(ent, frames, {
        group = "shuffleInto",
        onComplete = function(target)
            -- 动画结束隐藏实体（同爆牌：载体为服务端网络实体，客户端不可 Remove，
            -- 由服务端 ShuffleIntoCleanupDelay 兜底回收）
            if IsValid(target) then target:SetNoDraw(true) end
        end,
    })
end

-- 洗入动画接收（服务端 BroadcastShuffleInto）：牌桌 → 槽位 → 张数 → 卡组终点 →
-- 各载体（实体 + 来源）。仅关注桌消费（跨桌广播读完载荷后跳过）
net.Receive("KardsShuffleInto", function()
    local tableEnt = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local n = net.ReadUInt(8)
    local endPos = net.ReadVector()
    local carriers = {}
    for i = 1, n do
        carriers[i] = { ent = net.ReadEntity(), from = net.ReadUInt(8) }
    end
    if slot ~= 1 and slot ~= 2 then return end
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    local isMine = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot
    local obs = KARDS.Perspective and not KARDS.Perspective.LocalView
    -- 有效载体先收集（序位与总数按有效载体计，与错峰排布一致）
    local live = {}
    for _, c in ipairs(carriers) do
        if IsValid(c.ent) then live[#live + 1] = c end
    end
    for i, c in ipairs(live) do
        ShuffleAnim(c.ent, slot, c.from, endPos, isMine, obs, i, #live)
    end
end)