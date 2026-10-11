--[[
    Kards 战斗牌桌客户端模块：加入阵线动画（cl_battle_join.lua，2026-09-26 缺口 F）

    数据层 joinBattlefield / joinFrontline / summonUnit 成功后触发 JoinField 事件，
    实体层登记待播标记，在布局广播之后经 BroadcastJoinAnim 广播 KardsJoinAnim，
    本模块按视角播加入动画。

    载荷：牌桌 / 归属槽位 / 是否有手牌来源 / 手牌来源实体 / 战场实体 /
          阵线（1 支援阵线 / 2 前线）/ 部署音效路径（仅手牌来源非空）

    动画分支：
      入场（非手牌单位，以及本方与敌方视角的手牌单位）：战场实体自屏幕右外侧沿
        该阵线延长线生成，线性向左滑入居中算法指定落点；前线取组名 frontlineMove
        （与前线标识同组并发），支援阵线取组名 joinField。起点卡背朝上、落位翻至
        正面（单位落场后需可读，隐蔽单位另由 stealth 模块保持卡背）。
      手牌来源 + 本方或敌方视角：手牌实体独自沿该方屏幕下方移出画面。
      手牌来源 + 观战视角：手牌实体先沿卡面向下落到牌桌面，再沿二次函数曲线
        （顶点落在该单位所属方右侧）飞抵落点，同时旋转角平躺。

    挂载：cl_init.lua include 本文件（cl_battle_shuffle.lua 之后）。
    依赖 cl_init.lua 末尾桥接导出（KARDS.AnimPlayer / HandSlotReposDur / HandFanPos /
    HandCount / RenumberHand / BattleState / Perspective）与 sh_animation.lua 的
    KARDS.Animation.Board2D.CardZ；KardsFieldLayout 接收器经 KARDS.JoinAnim:Target
    与 KARDS.JoinAnim.layoutTo 接入。
]]

KARDS = KARDS or {}
KARDS.JoinAnim = KARDS.JoinAnim or {}

-- 动画数值常量（时长秒 / 距离世界单位）
local JoinDropDur     = 0.5  -- 手牌下落：本方与敌方视角沿屏幕下方外移；观战第一段落至桌面
local JoinCurveDur    = 0.6  -- 观战第二段：桌面二次曲线飞行时长
local JoinExitDist    = 40   -- 手牌沿屏幕下方外移距离
local JoinCurveApex   = 12   -- 观战二次曲线顶点相对弦中点的偏移（该单位所属方右侧）
local JoinEnterOutX   = 70   -- 入场起点沿 x 外推量（屏幕右外侧）
local JoinCurveSteps  = 8    -- 观战第二段二次贝塞尔采样帧数
-- 入场左移时长：前线同 cl_battle_frontline_symbol.lua 的 FL_SYMBOL_MOVE_DUR（0.15），
-- 支援阵线同 cl_init.lua 的 HandSlotReposDur（0.15，两值当前一致）
local JoinEnterDurFront   = 0.15
local JoinEnterDurSupport = KARDS.HandSlotReposDur or 0.15

-- 待播登记（weak keys）：[战场实体] = { srcEnt, fromHand, slot, line }
local pending = setmetatable({}, { __mode = "k" })

-- 布局落点登记（weak keys）：[战场实体] = 最近一次布局广播算得的落点。加入动画广播
-- 比布局广播晚 0.1 秒（服务端次序：实体需先传播到客户端），故收到加入动画时布局
-- 多已处理完，此处直接取登记值立即接管，不必等下一次布局广播
KARDS.JoinAnim.layoutTo = setmetatable({}, { __mode = "k" })

--[[
    入场动画：战场实体自屏幕右外侧沿阵线延长线生成并向左滑入落点

    @param fieldEnt Entity 战场实体
    @param to       Vector 落点（牌桌局部坐标，居中算法指定）
    @param line     number 阵线（1 支援阵线 / 2 前线）
]]
local function PlayEnter(fieldEnt, to, line)
    local startPos = to + Vector(JoinEnterOutX, 0, 0)
    local cur = fieldEnt:GetLocalAngles()
    local backAng = Angle(180, cur.y, cur.r) -- 起点卡背朝上
    local flatAng = Angle(0, cur.y, cur.r)   -- 落位翻至正面
    local dur = (line == 2) and JoinEnterDurFront or JoinEnterDurSupport
    fieldEnt:SetNoDraw(false)
    fieldEnt:SetLocalPos(startPos)
    fieldEnt:SetLocalAngles(backAng)
    KARDS.AnimPlayer:Play(fieldEnt, {
        { t = 0, pos = startPos, ang = backAng },
        { t = dur, pos = to, ang = flatAng, easing = "linear" },
    }, { group = (line == 2) and "frontlineMove" or "joinField" })
end

--[[
    观战视角第二段：桌面二次函数曲线飞行（顶点约束在该单位所属方右侧）

    二次贝塞尔在参数 0.5 处的取值恰为 (S + 2C + G) / 4，故由期望顶点 A 反解控制点
    C = (A * 4 - S - G) * 0.5；按参数等分采样 JoinCurveSteps 帧，末帧同时把旋转角
    平躺（pitch 归 0）。

    @param srcEnt   Entity 手牌来源实体
    @param g        Vector 终点（落点）
    @param s        Vector 起点（桌面上的手牌位置）
    @param rightSign number 顶点偏移方向（该单位所属方右侧：槽 1 为 +1 / 槽 2 为 -1）
    @return table 帧序列（t 从 0 起，末帧含 ang）
]]
local function CurveFrames(srcEnt, g, s, rightSign)
    local apex = (s + g) * 0.5 + Vector(rightSign * JoinCurveApex, 0, 0)
    local c = (apex * 4 - s - g) * 0.5
    local cur = srcEnt:GetLocalAngles()
    local frames = {}
    for i = 0, JoinCurveSteps do
        local u = i / JoinCurveSteps
        local iu = 1 - u
        local pos = s * (iu * iu) + c * (2 * iu * u) + g * (u * u)
        local f = { t = JoinCurveDur * u, pos = pos, easing = "linear" }
        if i == JoinCurveSteps then f.ang = Angle(0, cur.y, cur.r) end -- 末帧平躺
        frames[#frames + 1] = f
    end
    return frames
end

-- 手牌登记脱手（数据层已移除该卡，客户端同步清除并按新张数重排扇形，
-- 避免起飞后扇形区残留幽灵卡、或被 KardsRealHandFacing 每帧拉回扇形位）
local function DetachHand(srcEnt, slot)
    local hand = KARDS.BattleState.realHandCards and KARDS.BattleState.realHandCards[slot]
    if hand then hand[srcEnt] = nil end
    KARDS.RenumberHand(slot, srcEnt, KARDS.HandCount(slot))
end

--[[
    手牌来源侧动画（本方与敌方视角）：沿该方屏幕下方外移出画面

    @param srcEnt Entity 手牌来源实体
    @param slot   number 归属槽位（1/2）
]]
local function PlayHandOut(srcEnt, slot)
    local startPos = srcEnt:GetLocalPos()
    local sign = (KARDS.HandFanPos(slot, 1, 1).y >= 0) and 1 or -1
    local target = startPos + Vector(0, sign * JoinExitDist, -JoinExitDist * 0.5)
    KARDS.AnimPlayer:Play(srcEnt, {
        { t = 0 },
        { t = JoinDropDur, pos = target, easing = "linear" },
    }, {
        group = "joinHandOut",
        onComplete = function(target)
            if IsValid(target) then target:SetNoDraw(true) end
        end,
    })
end

--[[
    手牌来源侧动画（观战视角）：先沿手牌卡面向下落到牌桌面，再沿二次曲线飞抵落点；
    抵达时手牌载体隐藏、战场实体换显（同一张卡的两个载体交接）

    @param srcEnt   Entity 手牌来源实体
    @param to       Vector 落点（牌桌局部坐标）
    @param slot     number 归属槽位（1/2）
    @param fieldEnt Entity 战场实体
]]
local function PlayObsCurve(srcEnt, to, slot, fieldEnt)
    local startPos = srcEnt:GetLocalPos()
    local cardZ = (KARDS.Animation and KARDS.Animation.Board2D
        and KARDS.Animation.Board2D.CardZ) or startPos.z
    local s = Vector(startPos.x, startPos.y, cardZ)
    local rightSign = (slot == 1) and 1 or -1
    local frames = {
        { t = 0, pos = startPos, easing = "linear" },
        { t = JoinDropDur, pos = s, easing = "linear" },
    }
    for _, f in ipairs(CurveFrames(srcEnt, to, s, rightSign)) do
        f.t = f.t + JoinDropDur
        frames[#frames + 1] = f
    end
    KARDS.AnimPlayer:Play(srcEnt, frames, {
        group = "joinHandOut",
        onComplete = function(target)
            if IsValid(target) then target:SetNoDraw(true) end
            if IsValid(fieldEnt) then fieldEnt:SetNoDraw(false) end
        end,
    })
end

--[[
    加入动画落点接管（由 KardsFieldLayout 接收器在算完 to 后调用）

    @param fieldEnt Entity 战场实体
    @param to       Vector 落点（牌桌局部坐标）
    @return boolean true = 已接管（调用方跳过普通复位动画）
]]
function KARDS.JoinAnim:Target(fieldEnt, to)
    local p = pending[fieldEnt]
    if not p then return false end
    pending[fieldEnt] = nil
    self.layoutTo[fieldEnt] = nil
    local obs = KARDS.Perspective and not KARDS.Perspective.LocalView
    if obs and p.fromHand and IsValid(p.srcEnt) then
        -- 观战视角 + 手牌来源：由手牌载体沿桌面曲线飞抵落点，战场实体先隐、抵达换显
        fieldEnt:SetLocalPos(to)
        fieldEnt:SetNoDraw(true)
        PlayObsCurve(p.srcEnt, to, p.slot, fieldEnt)
        return true
    end
    PlayEnter(fieldEnt, to, p.line)
    return true
end

-- 加入阵线动画接收（服务端 BroadcastJoinAnim）：牌桌 → 槽位 → 是否有手牌来源 →
-- 手牌来源实体 → 战场实体 → 阵线 → 部署音效路径。仅关注桌消费
net.Receive("KardsJoinAnim", function()
    local tableEnt = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local hasSource = net.ReadBool()
    local srcEnt = net.ReadEntity()
    local srcModelID = net.ReadString()
    local fieldEnt = net.ReadEntity()
    local line = net.ReadUInt(8)
    local deploySnd = net.ReadString()
    if slot ~= 1 and slot ~= 2 then return end
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    if not IsValid(fieldEnt) then return end -- 实体尚未传播到客户端：退化为常规复位
    -- F1 修复（2026-09-27）：手牌来源实体引用未传播（读成 NULL）时按模型副本标识在手牌
    -- 登记表里找回同一实体，使脱手与手牌侧动画照常进行。否则扇形区残留幽灵卡（要等
    -- 服务端 2.0 秒兜底回收），且本端改播屏右入场，与同桌其它端表现不一致。
    if hasSource and not IsValid(srcEnt) and srcModelID ~= "" then
        local reg = KARDS.BattleState.realHandCards and KARDS.BattleState.realHandCards[slot]
        for e in pairs(reg or {}) do
            if IsValid(e) and e:GetNWString("Kards_DeckModelID", "") == srcModelID then
                srcEnt = e
                break
            end
        end
    end
    local fromHand = hasSource and IsValid(srcEnt)
    -- 2026-10-03 联机排查 NEW-10：清手牌来源实体的远程拖拽残留。KardsRemoteDragThink
    -- 注册晚于动画驱动且每帧无条件写入，残留会覆盖 DetachHand 后的手牌侧动画
    if fromHand and KARDS.BattleState.remoteDrags then
        KARDS.BattleState.remoteDrags[srcEnt] = nil
    end
    pending[fieldEnt] = { srcEnt = srcEnt, fromHand = fromHand, slot = slot, line = line }
    local obs = KARDS.Perspective and not KARDS.Perspective.LocalView
    if fromHand then
        if deploySnd ~= "" then KARDS.PlaySoundPath(deploySnd) end -- 部署音效与动画同时
        DetachHand(srcEnt, slot)
        -- 本方与敌方视角：手牌沿屏幕下方外移，与入场动画并行（不依赖落点）
        -- 观战视角：等待落点登记后由 Target 起播桌面曲线（第二段需要终点）
        if not obs then PlayHandOut(srcEnt, slot) end
    end
    -- 布局广播先到（服务端次序）→ 已有落点，立即接管；否则等下一次布局广播
    local to = KARDS.JoinAnim.layoutTo[fieldEnt]
    if to then KARDS.JoinAnim:Target(fieldEnt, to) end
end)