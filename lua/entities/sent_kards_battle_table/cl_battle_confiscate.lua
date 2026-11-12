--[[
    Kards 战斗牌桌客户端模块：收缴动画（cl_battle_confiscate.lua，2026-10-15）

    数据层 SimConfiscate 触发 Confiscate 事件 → 实体层 BroadcastConfiscate 在源战场实体
    （小模型单位）原位创建完整卡动画载体（SpawnReturnedCard，同时登记为收缴方手牌实体），
    先置隐藏并延迟 0.1 秒广播 KardsConfiscateAnim（牌桌 / 槽位 / 源小模型 / 完整卡载体 /
    手牌序号 / 总数）。

    本模块时序（2026-10-15 用户规格「单位被消灭动画后，0.5 秒后重新原地出现，0.5 秒后
    加入手牌」）：
      1. 等源小模型阵亡移除（阵亡路径 KardsFieldDeathDelayedRemove 在「最晚飘字结束 +
         0.5 秒」后通知服务端移除该实体）
      2. 移除后延 CONFISCATE_REVEAL_DELAY：完整卡载体在阵亡原位现身（不再是短卡小模型）
      3. 再延 CONFISCATE_HOLD：飞入收缴方手牌末位（复用 KARDS.PlayHandFlyIn，与返回
         手牌共用三段飞行；本方/观战途经牌桌中心，对方直飞减半）

    隐藏机制：服务端创建即 SetNoDraw(true) 并写 NW Kards_ConfiscateHidden（网络同步）；
    cl_init.lua KardsTableEntitiesThink 的卡组槽兜底显隐对 NW 为真的实体跳过（否则会被
    本地 SetNoDraw(false) 提前显示）。揭示由本模块负责（本地 SetNoDraw(false) + 清 NW）。

    挂载：cl_init.lua include 本文件（cl_battle_convert.lua 之后，晚于 cl_battle_mulligan.lua
    以保证 KARDS.PlayHandFlyIn 已定义）。依赖 cl_init.lua 桥接导出：KARDS.PlayHandFlyIn /
    KARDS.RenumberHand / KARDS.InitDrawCardFace / KARDS.drawFacePending / KARDS.BattleState。
]]

KARDS = KARDS or {}

-- 单位阵亡移除后，完整卡原地重现的延迟（秒）
local CONFISCATE_REVEAL_DELAY = 0.5
-- 完整卡原地停留时长（秒），之后飞入手牌
local CONFISCATE_HOLD = 0.5
-- 等待源小模型消失的上限（秒）：正常由阵亡路径驱动（最晚飘字结束 + 0.5 秒 + 网络往返）；
-- 超上限则从收到消息起按同一延迟兜底揭示，避免异常时永不揭示
local CONFISCATE_DEATH_WAIT_MAX = 6.0
-- 源小模型消失的轮询间隔（秒）
local CONFISCATE_POLL_INTERVAL = 0.05

--[[
    收缴动画接收（服务端 BroadcastConfiscate 广播）。

    @载荷 牌桌实体 / 槽位 / 源小模型（NULL 表示已移除）/ 完整卡载体 / 手牌序号 / 手牌总数
]]
net.Receive("KardsConfiscateAnim", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local unitEnt = net.ReadEntity() -- 源战场实体（小模型；无效时不等待其消失）
    local cardEnt = net.ReadEntity() -- 完整卡动画载体（位于小模型原位）
    local idx = net.ReadUInt(8)
    local total = net.ReadUInt(8)
    if not IsValid(ent) or not IsValid(cardEnt) then return end
    if slot ~= 1 and slot ~= 2 then return end
    if not KARDS.BattleState:IsLocalTable(ent) then return end
    -- 本地复核隐藏（服务端创建即 SetNoDraw(true)，此处防兜底显隐先于本消息到达）
    cardEnt:SetNoDraw(true)
    local isMine = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot
    -- 本方需卡面（揭示前完成材质准备，避免现身瞬间白屏）；对方/观战不初始化（两面卡背）
    if isMine then
        KARDS.InitDrawCardFace(cardEnt)
        KARDS.drawFacePending[cardEnt] = true
    end

    -- 揭示：完整卡在原地现身，登记为手牌末位并让其余手牌腾位重排
    -- 现场景（阵亡移除后或超时兜底）：清隐藏 → 登记 realHandCards → RenumberHand 腾位，
    -- 再延 CONFISCATE_HOLD 调用 KARDS.PlayHandFlyIn 飞入末位空位。
    local function Reveal()
        if not IsValid(cardEnt) then return end
        cardEnt:SetNoDraw(false)
        cardEnt:SetNWBool("Kards_ConfiscateHidden", false)
        if isMine then KARDS.InitDrawCardFace(cardEnt) end
        KARDS.BattleState.realHandCards[slot][cardEnt] = idx
        KARDS.RenumberHand(slot, cardEnt, total)
        -- 停留后飞入收缴方手牌末位（共用返回手牌的三段飞行）
        timer.Simple(CONFISCATE_HOLD, function()
            if not IsValid(cardEnt) then return end
            KARDS.PlayHandFlyIn(slot, cardEnt, idx, total)
        end)
    end

    -- 等源小模型阵亡移除，移除后再延 CONFISCATE_REVEAL_DELAY 揭示
    local waitStart = CurTime()
    -- 轮询点：源小模型无效或等待超过 CONFISCATE_DEATH_WAIT_MAX 时转入揭示，
    -- 否则按 CONFISCATE_POLL_INTERVAL 复检（每次复检重入自身）。
    local function WaitThenReveal()
        if not IsValid(cardEnt) then return end
        if not IsValid(unitEnt) or (CurTime() - waitStart) >= CONFISCATE_DEATH_WAIT_MAX then
            timer.Simple(CONFISCATE_REVEAL_DELAY, Reveal)
        else
            timer.Simple(CONFISCATE_POLL_INTERVAL, WaitThenReveal)
        end
    end
    WaitThenReveal()
end)
