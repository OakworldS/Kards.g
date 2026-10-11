--[[
    Kards 战斗牌桌客户端模块：手牌拖拽机制（cl_battle_drag.lua，2026-08-15 C1 拆分）

    自 cl_init.lua（lua/entities/sent_kards_battle_table/cl_init.lua）拖拽段迁移：
      - KardsDragCardThink（Think）：手牌拿起 / 拖拽 / 打出主循环——拿起判定
        （KARDS.HandHitTest）、指向模式（固定屏幕底部 + 连线）、正常拖拽（抬升 z +
        鼠标投影）、腾位预览（KARDS.PreviewFieldPositions）、松手三分支（指向打出 /
        回手牌 / 固定槽位部署 SimDeployFixed）
      - KardsHandHover（net.Receive）：远程手牌悬停登记（KARDS.remoteHandHover）
      - KardsDragSync（net.Receive）：远程拖拽位置登记（remoteDrags）
      - KardsDragEnd（net.Receive）：远程拖拽结束（回手牌恢复扇形位 / 打出保持）
      - KardsRemoteDragThink（Think）：远程拖拽位置每帧应用

    挂载：cl_init.lua include 本文件（KardsHoverCardPreview 段之后、指令卡打出动画段
    之前）。约定：GMod include 为独立编译执行的 chunk，不共享 cl_init.lua 文件级
    local —— 本文件对 cl_init.lua 状态的访问一律经 KARDS 命名空间（cl_init.lua 在
    include 点前的「跨文件桥接」块把对应 local 值挂到 KARDS，运行时求值）：
    KARDS.remoteHandHover、KARDS.HandSlotBase/ZStep/TextYaw/DragVisDist/ReturnDur/ReposDur、
    KARDS.SupportLineHover、KARDS.HandRegionDist、KARDS.handHoverCards、KARDS.InHQRevealAnim、
    KARDS.FieldPos、KARDS.PreviewFieldPositions、KARDS.HandFanPos。
    KARDS.GetCardEffectNodeInfo / GetPointingTarget / PointingFailReason 为运行时命名空间
    访问（cl_battle_pointing.lua 文件末尾 include，调用时已定义）；文件级函数自含
    （2026-08-15 阶段四 C3 提级：DragMouseLocalZ / DragNearestCol / DragTryPickup /
    DragUpdate / DragRelease，KardsDragCardThink 精简为拿起判定 + 帧分发）。
]]

-- ====================================================================
-- 手牌拿起 / 拖拽 / 打出（2026-08-10）：
--   悬停在本方手牌时按下左键 → 拿起（z 抬升至手牌扇形 z 理论最大值上方 0.1、xy 原点始终跟随
--   鼠标、悬停机制失效、播放「拿起卡牌」音效）；握着的牌是单位且鼠标位于本方
--   支援阵线、在支援阵线整体卡牌的一侧 → 该玩家视角下支援阵线所有卡（含总部）
--   往另一侧移动（腾位预览）；松手在手牌区域 → 渐变回原位；否则为打出（单位 →
--   KardsPlayCard 固定槽位部署 SimDeployFixed；指令 → 战斗系统 SimPlayCard）。
--   从打出开始由服务端战斗系统权威处理（反应、时间刻记录）。
-- ====================================================================
-- 相机视线与牌桌局部 z 平面交点 → 牌桌局部坐标（拖拽 xy 跟随鼠标的投影基准；
-- 与 StartHQReveal 的屏幕 → 桌面平面投影同法）
local function DragMouseLocalZ(z)
    local pos, dir = KARDS.MouseRay(gui.MouseX(), gui.MouseY())
    local inBattle = KARDS.BattleState.battleStarted and KARDS.BattleState.inTable and IsValid(KARDS.BattleState.inTable.ent)
    if not inBattle or not dir or math.abs(dir.z) < 0.001 then return nil end
    local planeZ = KARDS.BattleState.inTable.ent:LocalToWorld(Vector(0, 0, z)).z
    local world = pos + dir * ((planeZ - pos.z) / dir.z)
    return KARDS.BattleState.inTable.ent:WorldToLocal(world)
end

-- 某槽当前手牌张数（真实手牌，含拖拽中/动画中）——2026-08-15 C2 提取至
-- KARDS.HandCount（共享工具区，见文件前部）

-- 最近列 index（鼠标投影 x → 支援阵线槽位列 1..5）
local function DragNearestCol(x)
    local best, bd = 1, math.huge
    for i = 1, 5 do
        local d = math.abs(KARDS.Animation.Board2D.ColX[i] - x)
        if d < bd then bd, best = d, i end
    end
    return best
end

-- 拿起（左键上升沿 + 我方回合 + 视角本方 + 无 GUI + 无进行中的拖拽/待确认 + 非结算中）
-- 2026-08-15 阶段四 C3：原 Think 钩子内每帧重建闭包（MouseLocalZ / NearestCol）且单函数
-- 过长——拿起/拖拽/松手提级为文件级函数，Think 仅做状态驱动；上下文（view /
-- inBattle / guiBlocked / left）于函数内自算（同帧调用与帧头计算等价）
local function DragTryPickup()
    local view = KARDS.Perspective and KARDS.Perspective.LocalView
    local inBattle = KARDS.BattleState.battleStarted and KARDS.BattleState.inTable and IsValid(KARDS.BattleState.inTable.ent)
    local guiBlocked = gui.IsConsoleVisible() or gui.IsGameUIVisible()
    local left = input.IsMouseDown(MOUSE_LEFT)
    if not guiBlocked and inBattle and KARDS.BattleState.battleTurn == KARDS.BattleState.inTable.slot
        and (view == 1 or view == 2) and not KARDS.BattleState.dragCard and not KARDS.BattleState.pendingPlayEnt
        and not KARDS.BattleState.endedTurn and not KARDS.BattleState.gameOver
        and left and not KARDS.BattleState.prevDragLeft then
        local pos, dir = KARDS.MouseRay(gui.MouseX(), gui.MouseY())
        -- 拿起判定（2026-08-11 改）：射线命中手牌卡面矩形才算点到手牌（替代原
        -- 「到中心 3D 距离 <12」——过宽，鼠标指向靠近手牌的战场单位时被误判为
        -- 拿起手牌）；重叠扇形卡取最先命中（t 最小）＝视觉最上层卡（2026-08-14 修复：
        -- 原最近中心距离 d 会选中被上方卡遮挡的左卡，见 L2884 注释）。
        -- 2026-08-15 C2：收敛至 KARDS.HandHitTest——busy 判定统一为 IsHandBusy（原
        -- 内联缺 dragReturn 组，统一后返回手牌动画中的卡不再可拿起，与悬停判定一致）
        local hit = KARDS.HandHitTest(pos, dir, view, true)
        if hit then
            KARDS.BattleState.dragCard = {
                ent = hit,
                slot = view,
                idx = KARDS.BattleState.realHandCards[view][hit],
            }
            -- 指向模式（2026-08-12 阶段 B）：效果含「选择卡牌单位目标（指向一个）」
            -- → 卡牌固定屏幕底部 + 连线箭头指向目标；否则正常拖拽
            local einfo = KARDS.GetCardEffectNodeInfo(hit)
            KARDS.BattleState.dragCard.pointing = einfo and einfo.hasTargetSelector or false
            KARDS.BattleState.dragCard.info = einfo
            KARDS.BattleState.dragCard.validTarget = nil
            -- 2026-08-13：指令指向与单位指向统一音效（aim.ogg，见 KARDS.PlayAimSound）——
            -- 指向模式拿起即播放；非指向模式兜底停止（防异常残留）
            if KARDS.BattleState.dragCard.pointing then
                KARDS.PlayAimSound()
            else
                KARDS.StopAimSound()
            end
            KARDS.handHoverCards[hit] = nil -- 悬停机制失效（位置/角度由本钩子接管）
            KARDS.PlayKardsSound("pickup")
        end
    end
end

-- 拖拽（拿起后每帧）：视觉位置 = 抬升 z + 屏幕投影补偿到鼠标 + 保持扇形角度 + 腾位预览
local function DragUpdate()
    local inBattle = KARDS.BattleState.battleStarted and KARDS.BattleState.inTable and IsValid(KARDS.BattleState.inTable.ent)
    if KARDS.BattleState.dragCard and IsValid(KARDS.BattleState.dragCard.ent) and inBattle then
        local ent = KARDS.BattleState.dragCard.ent
        -- 指向模式（2026-08-12 阶段 B）：卡牌固定屏幕底部（射线经屏幕底部中点 ∩
        -- 抬升 z 平面 → 牌桌局部坐标），不随鼠标移动；每帧记录鼠标位置 + 检测指向
        -- 的合法战场目标（HUDPaint 据此画连线箭头与高亮）。其余卡牌走下方正常拖拽。
        if KARDS.BattleState.dragCard.pointing then
            local tableEnt = KARDS.BattleState.inTable.ent
            -- 屏幕底部中点（ScrW/2, ScrH*0.82）射线 ∩ 抬升 z 平面 → 固定底部位置
            local vp, bdir = KARDS.MouseRay(ScrW() * 0.5, ScrH() * 0.82)
            local bottomPos = nil
            if bdir and bdir.z ~= 0 then
                local dragZ = KARDS.HandSlotBase.z + ((KARDS.HandCount(KARDS.BattleState.dragCard.slot) - 1) / 2) * KARDS.HandSlotZStep + 0.1
                local tz = tableEnt:LocalToWorld(Vector(0, 0, dragZ)).z
                local t = (tz - vp.z) / bdir.z
                if t > 0 then
                    bottomPos = tableEnt:WorldToLocal(vp + bdir * t)
                end
            end
            if bottomPos then
                ent:SetLocalPos(bottomPos)
            end
            -- 角度：平躺正面朝上（同正常拖拽：位置基准 + 文字朝向偏移，文字顶朝本方）
            local pang = Angle(0, (KARDS.BattleState.dragCard.slot == 1) and KARDS.HandSlotTextYaw or 0, 0)
            local pcur = ent:GetLocalAngles()
            if math.abs(pcur.p - pang.p) > 0.01 or math.abs(pcur.y - pang.y) > 0.01
                or math.abs(pcur.r - pang.r) > 0.01 then
                ent:SetLocalAngles(pang)
            end
            -- 目标检测：鼠标射线命中合法战场单位（约束校验在 GetPointingTarget）
            local ppos, pdir = KARDS.MouseRay(gui.MouseX(), gui.MouseY())
            KARDS.BattleState.dragCard.validTarget = KARDS.GetPointingTarget(ent, KARDS.BattleState.dragCard.info, ppos, pdir)
            KARDS.BattleState.dragCard.pointMouse = { x = gui.MouseX(), y = gui.MouseY() }
            -- 指向提示（2026-08-13 隐蔽）：悬停隐蔽单位 → 始终提示「隐蔽单位不受指令
            -- 指向」（节流推送见 cl_battle_stealth.lua HintIfPointing；GetPointingTarget
            -- 已剔除隐蔽候选 → validTarget 为 nil，松手回手牌 + PointingFailReason 同文案）
            if KARDS.Stealth and KARDS.Stealth.HintIfPointing then
                KARDS.Stealth.HintIfPointing(ppos, pdir)
            end
            -- 拖拽位置同步（同正常拖拽节流：观战者展示玩家握住的牌）
            if bottomPos then
                local pnow = CurTime()
                local plast = KARDS.BattleState.dragSync[ent]
                local pmoved = (not plast) or (plast.pos - bottomPos):LengthSqr() > 2.25
                local pdue = (not plast) or (pnow - plast.t) >= 0.05
                -- 2026-10-03 联机排查 NEW-10：静止握持时补心跳（每 0.5 秒一次），供接收端超时释放
                local pbeat = (not plast) or (pnow - plast.t) >= 0.5
                if (pmoved or pbeat) and pdue then
                    KARDS.BattleState.dragSync[ent] = { pos = Vector(bottomPos), t = pnow }
                    net.Start("KardsDragSync")
                        net.WriteEntity(tableEnt)
                        net.WriteEntity(ent)
                        net.WriteVector(bottomPos)
                        net.WriteAngle(pang)
                    net.SendToServer()
                end
            end
        else
        -- 游戏逻辑水平位置仍用桌面投影（CardZ）：与松手落点判定（NearestCol 同样投影
        -- 到 CardZ）同源，所见即所得（鼠标指向哪列 → 落到哪列）
        local lp = DragMouseLocalZ(KARDS.Animation.Board2D.CardZ)
        -- 视觉位置（2026-08-12 三次修订：二次修订的「迭代 ToScreen 补偿」在屏幕边缘
        -- 线性化步长收敛慢、残余投影偏移明显，用户反馈）——改为直接求「鼠标射线 ∩
        -- 抬升 z 平面」交点：ScreenToVector 射线上任意点屏幕投影恒 = 鼠标（逆映射），
        -- 故该交点任意屏幕位置（含边缘）投影精确无偏移，无需迭代。
        --   1. 抬升 z = 手牌扇形 z 理论最大值（阶梯最高层，编号大的一侧）+ 0.1
        --      （原拿起高度），拿起后高于所有手牌；
        --   2. 射线与抬升 z 平面求交 → 交点即视觉位置（z 恒定 = 抬升高度）。
        -- 射线不穿抬升平面（指向桌面下方，仅斜视相机可能）时无解 → 回退「深度锁定」：
        -- 卡置于鼠标射线前方 KARDS.HandSlotDragVisDist 处（屏幕投影恒 = 鼠标，z 随射线
        -- 变化，下限夹在桌面之上防穿模）。
        local visLocal = nil
        if lp then
            local tableEnt = KARDS.BattleState.inTable.ent
            local vp, vd = KARDS.MouseRay(gui.MouseX(), gui.MouseY())
            local dragZ = KARDS.HandSlotBase.z + ((KARDS.HandCount(KARDS.BattleState.dragCard.slot) - 1) / 2) * KARDS.HandSlotZStep + 0.1
            local targetZWorld = tableEnt:LocalToWorld(Vector(0, 0, dragZ)).z
            if vd and vd.z ~= 0 then
                local t = (targetZWorld - vp.z) / vd.z
                if t > 0 then -- 抬升平面在射线前方（有解）
                    visLocal = tableEnt:WorldToLocal(vp + vd * t)
                end
            end
            if not visLocal and vd then
                -- 回退：深度锁定（屏幕投影恒 = 鼠标；z 随射线，下限夹桌面之上）
                local visWorld = vp + vd * KARDS.HandSlotDragVisDist
                local minZ = tableEnt:LocalToWorld(
                    Vector(0, 0, KARDS.Animation.Board2D.CardZ + 0.3)).z
                if visWorld.z < minZ then visWorld.z = minZ end
                visLocal = tableEnt:WorldToLocal(visWorld)
            end
        end
        local cp = ent:GetLocalPos()
        local applyPos = visLocal or (lp and Vector(lp.x, lp.y, cp.z)) or cp
        ent:SetLocalPos(applyPos)
        -- 角度：被握住时不再遵循扇形分布（不在手牌中），平躺正面朝上（xy 位置由
        -- 鼠标投影接管；松手回手牌时 KardsRealHandFacing 恢复扇形姿态、打出后
        -- KardsFieldFacing 接管战场朝向）。yaw 取拿起前扇形基准 + 文字朝向偏移
        --（P1 位置基准 0 + 文字 180 → 180 / P2 基准 180 + 文字 180 → 0），保持文字
        -- 顶朝本方，避免从扇形角度（P1 ≈180±30）直接归 0 造成卡面 180° 翻转
        --（2026-08-11 用户反馈握住后 yaw 反了）
        local ang = Angle(0, (KARDS.BattleState.dragCard.slot == 1) and KARDS.HandSlotTextYaw or 0, 0)
        local cur = ent:GetLocalAngles()
        if math.abs(cur.p - ang.p) > 0.01 or math.abs(cur.y - ang.y) > 0.01
            or math.abs(cur.r - ang.r) > 0.01 then
            ent:SetLocalAngles(ang)
        end
        -- 拖拽位置同步（对方/观战视角展示玩家握住的牌，2026-08-12）：拿起当帧即发
        --（节流表空），拖拽中按「20Hz + 位移 1.5 阈值」节流；服务端中继广播给其他
        -- 客户端（排除发送者），接收端 SetLocalPos/SetLocalAngles 本地覆盖渲染。
        local now = CurTime()
        local last = KARDS.BattleState.dragSync[ent]
        local moved = (not last) or (last.pos - applyPos):LengthSqr() > 2.25
        local due = (not last) or (now - last.t) >= 0.05
        -- 2026-10-03 联机排查 NEW-10：静止握持时补心跳（每 0.5 秒一次）。原条件只在位移超过
        -- 阈值时发送，接收端无法用超时安全释放，拖拽方客户端卡死或 DragEnd 丢失时被钉住
        local beat = (not last) or (now - last.t) >= 0.5
        if (moved or beat) and due and KARDS.BattleState.inTable then
            KARDS.BattleState.dragSync[ent] = { pos = Vector(applyPos), t = now }
            net.Start("KardsDragSync")
                net.WriteEntity(KARDS.BattleState.inTable.ent)
                net.WriteEntity(ent)
                net.WriteVector(applyPos)
                net.WriteAngle(ang)
            net.SendToServer()
        end
        -- 腾位预览：单位 + 鼠标在本方支援阵线行 → 预览整线居中后的结果
        --（KARDS.PreviewFieldPositions：按落点列插入拖拽单位 + GetCenteredStart 整线居中 +
        -- 偶数整线 0.5 槽偏移，与服务端 SimDeploy 落位一致，所见即所得）
        local ctype = select(3, KARDS.GetCardIdentity(ent)) -- 手牌卡面定向表优先，回退 NW（2026-08-18，规划 B1）
        local isUnit = (ctype == "unit")
        local row = (KARDS.BattleState.dragCard.slot == 1) and 1 or -1
        local layout = KARDS.BattleState.fieldLayouts[KARDS.BattleState.dragCard.slot]
        local preview = nil
        if isUnit and lp and layout then
            if math.abs(lp.y - KARDS.Animation.Board2D.RowY[row]) <= KARDS.SupportLineHover then
                preview = KARDS.PreviewFieldPositions(layout, KARDS.BattleState.dragCard.ent, DragNearestCol(lp.x), row)
            end
        end
        for e, si in pairs(layout or {}) do
            if IsValid(e) and e ~= KARDS.BattleState.dragCard.ent and e ~= KARDS.BattleState.pendingPlayEnt and not KARDS.InHQRevealAnim(e) then
                -- 预览目标优先；未参与预览（待确认/总部动画中）回布局数据槽位
                local to = (preview and preview[e]) or KARDS.FieldPos(layout, e, si, row)
                local existing = KARDS.AnimPlayer:Get(e)
                -- 目标变化或动画缺失时重建（避免每帧重建/中断抖动）
                if not existing or not existing.toPos
                    or (existing.toPos - to):LengthSqr() > 0.01 then
                    KARDS.AnimPlayer:Play(e, {
                        { t = 0 },
                        { t = KARDS.HandSlotReposDur, pos = to, easing = "cos" },
                    }, { group = "fieldRepos", noQueue = true }) -- 拖拽腾位预览：高频交互反馈免排队即时播放（2026-08-12 队列系统）
                end
            end
        end
        end -- 指向模式 else 闭合（2026-08-12 阶段 B）
    end
end

-- 松手（左键下降沿 + 有拖拽中的卡）
local function DragRelease()
    local left = input.IsMouseDown(MOUSE_LEFT)
    if KARDS.BattleState.dragCard and IsValid(KARDS.BattleState.dragCard.ent) and not left and KARDS.BattleState.prevDragLeft then
        local ent = KARDS.BattleState.dragCard.ent
        -- 腾位预览复位：松手后战场卡回布局原位（无论回手牌 / 打出；打出成功时
        -- 服务端 KardsFieldLayout 会按新布局再次复位，与本处目标一致不冲突；
        -- 回手牌 / 打出被拒时保证战场卡归位）
        local row = (KARDS.BattleState.dragCard.slot == 1) and 1 or -1
        for e, si in pairs(KARDS.BattleState.fieldLayouts[KARDS.BattleState.dragCard.slot] or {}) do
            if IsValid(e) and e ~= ent and not KARDS.InHQRevealAnim(e) then
                local to = KARDS.FieldPos(KARDS.BattleState.fieldLayouts[KARDS.BattleState.dragCard.slot], e, si, row)
                local existing = KARDS.AnimPlayer:Get(e)
                if not existing or not existing.toPos
                    or (existing.toPos - to):LengthSqr() > 0.01 then
                    KARDS.AnimPlayer:Play(e, {
                        { t = 0 },
                        { t = KARDS.HandSlotReposDur, pos = to, easing = "cos" },
                    }, { group = "fieldRepos", noQueue = true }) -- 松手复位：高频交互反馈免排队即时播放（2026-08-12 队列系统）
                end
            end
        end
        -- 手牌区域判定：投影与当前本方手牌扇形各卡位置的水平距离
        local lp = DragMouseLocalZ(KARDS.HandSlotBase.z)
        local inHand = false
        if lp then
            local n = KARDS.HandCount(KARDS.BattleState.dragCard.slot)
            local best = math.huge
            for i = 1, n do
                local p = KARDS.HandFanPos(KARDS.BattleState.dragCard.slot, i, n)
                local d = Vector(p.x - lp.x, p.y - lp.y, 0):LengthSqr()
                if d < best then best = d end
            end
            inHand = best <= KARDS.HandRegionDist * KARDS.HandRegionDist
        end
        -- 指向模式松手（2026-08-12 阶段 B）：指向合法目标 → 打出（net 携带目标实体，
        -- 服务端 FieldCardByEnt 反查卡牌 → targetPicker 注入）；未指向合法目标 → 回手牌
        if KARDS.BattleState.dragCard.pointing then
            local vt = KARDS.BattleState.dragCard.validTarget
            if vt and IsValid(vt) then
                KARDS.BattleState.pendingPlayEnt = ent -- 冻结位置，等待服务端确认（防重复打出）
                net.Start("KardsPlayCard")
                    net.WriteEntity(KARDS.BattleState.inTable.ent)
                    net.WriteEntity(ent)
                    net.WriteUInt(0, 8) -- 指令：无战场槽位
                    net.WriteEntity(vt) -- 指向目标实体（服务端反查卡牌）
                net.SendToServer()
                -- 拖拽结束同步：打出（接收端保持最后同步位置，等 KardsCardPlayed 接管）
                net.Start("KardsDragEnd")
                    net.WriteEntity(KARDS.BattleState.inTable.ent)
                    net.WriteEntity(ent)
                    net.WriteBool(false)
                net.SendToServer()
            else
                -- 未指向合法目标：回手牌（渐变回扇形位；z 一并回落）
                local handPos = KARDS.HandFanPos(KARDS.BattleState.dragCard.slot, KARDS.BattleState.dragCard.idx, KARDS.HandCount(KARDS.BattleState.dragCard.slot))
                KARDS.AnimPlayer:Play(ent, {
                    { t = 0 },
                    { t = KARDS.HandSlotReturnDur, pos = handPos, easing = "cos" },
                }, { group = "dragReturn" })
                net.Start("KardsDragEnd")
                    net.WriteEntity(KARDS.BattleState.inTable.ent)
                    net.WriteEntity(ent)
                    net.WriteBool(true)
                net.SendToServer()
                -- 指向失败提示（2026-08-12 提示系统）：悬停不可选目标 → 不能指向此目标；
                -- 悬停空位 → 请指向目标
                local ppos, pdir = KARDS.MouseRay(gui.MouseX(), gui.MouseY())
                local reason = KARDS.PointingFailReason(ppos, pdir)
                if reason then KARDS.BattleHint.Push(reason) end
            end
            KARDS.BattleState.dragSync[ent] = nil
            KARDS.StopAimSound() -- 2026-08-13：指向结束（打出/回手牌）未播完立即停止
            KARDS.BattleState.dragCard = nil
        elseif inHand then
            -- 渐变回到原位（扇形位；z 一并回落）
            local handPos = KARDS.HandFanPos(KARDS.BattleState.dragCard.slot, KARDS.BattleState.dragCard.idx, KARDS.HandCount(KARDS.BattleState.dragCard.slot))
            KARDS.AnimPlayer:Play(ent, {
                { t = 0 },
                { t = KARDS.HandSlotReturnDur, pos = handPos, easing = "cos" },
            }, { group = "dragReturn" })
            -- 拖拽结束同步：回手牌（接收端恢复该卡扇形位；拖拽方本端由上方返回动画接管）
            net.Start("KardsDragEnd")
                net.WriteEntity(KARDS.BattleState.inTable.ent)
                net.WriteEntity(ent)
                net.WriteBool(true)
            net.SendToServer()
            KARDS.BattleState.dragSync[ent] = nil
            KARDS.BattleState.dragCard = nil
        else
            -- 打出：单位 → 目标槽位 = 鼠标投影最近列（与服务端 SimDeploy 受限选位
            -- InsertCentered 排秩同源，与拖拽预览 KARDS.PreviewFieldPositions 的落点列一致 →
            -- 所见即所得）；指令 → 0
            local ctype = select(3, KARDS.GetCardIdentity(ent)) -- 手牌卡面定向表优先，回退 NW（2026-08-18，规划 B1）
            -- 反制激活（M3.1，反制系统）：反制卡拖出手牌外松手不判定为「打出」，
            -- 改为切换激活状态（KARDS.CounterClientToggle，见 cl_battle_hud.lua）。
            -- 仅本方回合处理（非本方回合按回手牌处理，复用 inHand 分支的返回动画与
            -- KardsDragEnd）；不发送 KardsPlayCard。
            if ctype == "counter_command" then
                if KARDS.BattleState.battleTurn == KARDS.BattleState.dragCard.slot then
                    KARDS.CounterClientToggle(ent)
                else
                    local handPos = KARDS.HandFanPos(KARDS.BattleState.dragCard.slot, KARDS.BattleState.dragCard.idx, KARDS.HandCount(KARDS.BattleState.dragCard.slot))
                    KARDS.AnimPlayer:Play(ent, {
                        { t = 0 },
                        { t = KARDS.HandSlotReturnDur, pos = handPos, easing = "cos" },
                    }, { group = "dragReturn" })
                end
                -- 反制激活动画为本方客户端表现（信息隔离：敌方不可见），拖拽结束同步
                -- 仍按「回手牌」通知其他客户端恢复扇形位（接收端据 bool 恢复姿态）
                net.Start("KardsDragEnd")
                    net.WriteEntity(KARDS.BattleState.inTable.ent)
                    net.WriteEntity(ent)
                    net.WriteBool(true)
                net.SendToServer()
                KARDS.BattleState.dragSync[ent] = nil
                KARDS.BattleState.dragCard = nil
                return
            end
            local isUnit = (ctype == "unit")
            local slotIndex = 0
            if isUnit then
                local lp2 = DragMouseLocalZ(KARDS.Animation.Board2D.CardZ)
                if lp2 then
                    -- 不再「被占则往鼠标侧找空槽」：服务端 InsertCentered 对占用列的
                    -- 语义为「插入到该卡左侧 + 整线居中」（与预览 KARDS.PreviewFieldPositions
                    -- 相同）——悬停两卡之间（最近列被占）时改找空槽会把部署目标换到
                    -- 别的列，与预览让位不符、落不到预览空位（2026-08-11 反馈）
                    slotIndex = DragNearestCol(lp2.x)
                end
            end
            KARDS.BattleState.pendingPlayEnt = ent -- 冻结位置，等待服务端确认（防重复打出）
            net.Start("KardsPlayCard")
                net.WriteEntity(KARDS.BattleState.inTable.ent)
                net.WriteEntity(ent)
                net.WriteUInt(slotIndex, 8)
                net.WriteEntity(NULL) -- 目标实体（B3 消息扩展：普通打出无指向目标）
            net.SendToServer()
            -- 拖拽结束同步：打出（接收端保持最后同步位置，等 KardsCardPlayed 飞行接管）
            net.Start("KardsDragEnd")
                net.WriteEntity(KARDS.BattleState.inTable.ent)
                net.WriteEntity(ent)
                net.WriteBool(false)
            net.SendToServer()
            KARDS.BattleState.dragSync[ent] = nil
            KARDS.BattleState.dragCard = nil
        end
    end
end

hook.Add("Think", "KardsDragCardThink", function()
    DragTryPickup()
    DragUpdate()
    DragRelease()
    KARDS.BattleState.prevDragLeft = input.IsMouseDown(MOUSE_LEFT)
end)

-- ====================================================================
-- 远程手牌悬停（2026-08-14，需求 2/3）：悬停方客户端广播（KardsHandHover）→
-- 服务端中继给其他所有客户端 → 本端登记 KARDS.remoteHandHover[槽位]，KardsRealHandFacing
-- 每帧据此把该卡沿 z 抬升（敌方在 P1/P2 视角、双方在观战视角可见）。无悬停时
-- 服务端写 NULL 清除对应槽位。广播未开始对局忽略；本方为发送方时服务端中继
-- 已排除，不会收到自己的悬停。
-- ====================================================================
net.Receive("KardsHandHover", function()
    local ent = net.ReadEntity() -- 牌桌（校验）
    local slot = net.ReadUInt(2)
    local card = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    if not KARDS.BattleState.battleStarted then return end -- 未在对局（进桌前的广播忽略）
    if slot ~= 1 and slot ~= 2 then return end
    KARDS.remoteHandHover[slot] = IsValid(card) and card or nil
end)

-- ====================================================================
-- 远程拖拽同步（2026-08-12：对方/观战视角展示玩家握住的牌）
-- 拖拽方客户端节流发送位置（KardsDragSync）→ 服务端中继广播给其他客户端 →
-- 本客户端登记 remoteDrags，每帧 SetLocalPos/SetLocalAngles 本地覆盖渲染；
-- 松手时拖拽方发 KardsDragEnd：回手牌 → 接收端恢复该卡扇形位（仍登记在手牌，
-- 索引/张数与广播时一致）；打出 → 接收端保持最后同步位置，等 KardsCardPlayed
-- 飞行动画接管（该收尾一并清远程登记，见下）。
-- 冲突：KardsRealHandFacing 仅驱动本方手牌角度与悬停提升（对方/观战视角不改远程
-- 拖拽卡）→ 本 Think 的位置/角度覆盖无冲突。
-- ====================================================================
net.Receive("KardsDragSync", function()
    local ent = net.ReadEntity() -- 牌桌（仅校验；位置为牌桌局部坐标，直接应用）
    local card = net.ReadEntity()
    local pos = net.ReadVector()
    local ang = net.ReadAngle()
    if not IsValid(ent) or not IsValid(card) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    if not KARDS.BattleState.battleStarted then return end -- 未在对局（进桌前的广播忽略）
    -- 本方是所同步牌桌的牌手（含对方牌手）→ 不展示对方握住的牌（竞争方信息隔离，
    -- 服务端中继已排除双方牌手，此处为兜底）；仅观战者（inTable=nil 或坐其他牌桌）应用
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then return end
    -- 本地正在拖拽同一张卡（服务端中继误发自己）→ 忽略（本地拖拽分支已接管）
    if KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == card then return end
    KARDS.BattleState.remoteDrags[card] = { pos = pos, ang = ang, t = CurTime() }
end)

net.Receive("KardsDragEnd", function()
    local ent = net.ReadEntity()
    local card = net.ReadEntity()
    local returned = net.ReadBool()
    if not IsValid(ent) or not IsValid(card) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    -- 同 KardsDragSync 守卫：本方为该桌牌手（含对方）不处理（竞争方信息隔离）
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then return end
    KARDS.BattleState.remoteDrags[card] = nil
    if returned then
        -- 恢复该卡扇形位（手牌仍登记，索引/张数与广播时一致）
        for slot = 1, 2 do
            local idx = KARDS.BattleState.realHandCards[slot] and KARDS.BattleState.realHandCards[slot][card]
            if idx then
                local n = KARDS.HandCount(slot) -- 2026-08-15 C2：内联计数收敛至共享工具
                local pos, a = KARDS.HandFanPos(slot, idx, n)
                card:SetLocalPos(pos)
                card:SetLocalAngles(a)
                break
            end
        end
    end
end)

-- 远程拖拽位置应用（每帧）
hook.Add("Think", "KardsRemoteDragThink", function()
    local remote = KARDS.BattleState.remoteDrags
    local now = CurTime()
    for card, st in pairs(remote) do
        if not IsValid(card) then
            remote[card] = nil
        elseif now - (st.t or 0) > 2 then
            -- 2026-10-03 联机排查 NEW-10：超过 2 秒未收到同步（发送端每 0.5 秒心跳一次）视为
            -- 拖拽已结束，释放位置接管。此前只在收到 KardsDragEnd 或打出时清除，拖拽方客户端
            -- 卡死或该消息丢失时，这张卡会在对方与观战端被永久钉在最后同步位置。
            -- 释放后手牌扇形由每帧朝向驱动（cl_init.lua 的 KardsRealHandFacing）自行归位。
            remote[card] = nil
        else
            card:SetLocalPos(st.pos)
            card:SetLocalAngles(st.ang)
        end
    end
end)
