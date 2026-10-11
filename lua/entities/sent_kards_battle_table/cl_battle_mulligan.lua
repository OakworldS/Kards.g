--[[
    Kards 战斗牌桌客户端模块：重新调度机制（cl_battle_mulligan.lua，2026-08-15 C1 拆分）

    自 cl_init.lua（lua/entities/sent_kards_battle_table/cl_init.lua）重新调度段迁移：
      - KardsTableDeckDraw（net.Receive）：抽牌/发牌通知——本方起手扇形、补抽、
        爆牌、对方直飞、本方/观战桌中翻面 4 分支路由
      - KardsReturnToHand（net.Receive）：返回手牌动画（对称于部署；本方/观战途经
        牌桌中心三段时长对齐抽牌，对方直飞总时长减半）
      - KardsDeckDrawUpdate（Think）：抽牌动画阶段 3 触发的手牌槽卡左移
      - KardsMulliganDone（net.Receive）：弃牌回卡组 + 统一落位调度（toHandAt）
      - KardsMulliganAnimsUpdate（Think）：发牌完成判定 + 统一落位
      - KardsMulliganAnimDoneNotify（Think）：动画结束通知（服务端延迟开始先手回合）
      - KardsMulliganSelect（Think）+ HitMulliganCard / SubmitMulligan：选择交互
      - KardsMulliganHUD / KardsWaitingOpponentMulliganHUD /
        KardsSpectateMulliganHUD（HUDPaint）：三视角重新调度提示

    挂载：cl_init.lua include 本文件（KardsDeckDrawShift 段之后、结束回合按钮段
    之前）。约定：GMod include 为独立编译执行的 chunk，不共享 cl_init.lua 文件级
    local —— 本文件对 cl_init.lua 状态的访问一律经 KARDS 命名空间（cl_init.lua 在
    include 点前的「跨文件桥接」块把对应 local 值挂到 KARDS，运行时求值）：
    KARDS.PileBase/PileYaw、KARDS.HandFanPos、KARDS.MulliganFanPos、KARDS.RenumberHand、
    KARDS.StartHandShift、KARDS.deckDrawShift、KARDS.InitDrawCardFace、KARDS.drawFacePending、
    KARDS.DisplaySlots、KARDS.ExitFlyDist、KARDS.OverdrawFlyDur/Hold/ExitDur、
    KARDS.EnemyDrawDirectDur、KARDS.battleDeckDrawn/battleHQLeft、KARDS.CrossSlotFor、
    KARDS.RevealEaseInOut、KARDS.UpdateTableMouse；文件级 local
    （ReturnAnimOwnerDur1/2/Hold、chooseMat、textUndergroundMat、HitMulliganCard、
    SubmitMulligan）自含。
]]

-- 服务端抽牌通知（OnBattleDraw 广播，含重新调度发牌/补抽）：抽牌临时卡实体
-- （卡堆顶，见 table_battledeck.lua SpawnDeckDrawCard）→ 按「槽位 × 补抽标记 ×
-- 本方/对方」路由：
--   本方 + 非补抽 + 未完成重新调度 → 起手发牌：牌桌中间扇形（KARDS.MulliganFanPos，可点击选择）
--   本方 + 补抽（isReplace，确认后）→ 补抽卡飞向牌桌中间扇形区空位（被弃卡原序号
--     位置，与保留卡一起待 0.7s 统一落手牌，见 KardsMulliganAnimsUpdate 末段）
--   爆牌（overdraw，readme 7.1 手牌上限 9：手牌已达上限）→ 专属弃牌动画：卡堆顶 →
--     爆牌方视角左侧卡槽（交叉填槽，KARDS.CrossSlotFor(slot, "left")）停留 KARDS.OverdrawHold
--     秒 → 沿槽位方向出场（+x 槽向右顺时针 / -x 槽向左逆时针），
--     动画结束移除实体（手牌不变，不重排扇形 / 不登记 KARDS.BattleState.realHandCards）
--   对方 / 观战（非本方）→ 直接落该槽手牌位（KARDS.HandFanPos，卡背朝上：本方客户端
--     不改写 manifest，被抽卡两面子网格均为卡背图 → 任何姿态看到的都是卡背，
--     对方牌面不可见）
-- 分支（2026-08-15 阶段四 C5）：KardsTableDeckDraw 接收器五分支按分支拆函数——
-- 起手发牌 / 补抽 / 爆牌 / 落手牌（视角三分）。接收器仅做解码 + 调度。

-- 本方起手发牌且该槽未完成重新调度 → 牌桌中间扇形选择阶段
local function DeckDrawDealHand(ent, slot, idx, total)
    KARDS.InitDrawCardFace(ent) -- 本方需看卡面选择（NW 未就绪则入队，Think 重试）
    KARDS.drawFacePending[ent] = true
    ent:SetNoDraw(false)
    local m = KARDS.BattleState.mulligan
    if not m or m.slot ~= slot or m.submitted then
        m = { active = false, slot = slot, total = total, cards = {}, submitted = false }
        KARDS.BattleState.mulligan = m
        -- 选择在发牌动画全部结束后才启用（active 延迟置 true，见
        -- KardsMulliganAnimsUpdate 发牌循环后）
    end
    m.cards[ent] = { ent = ent, index = idx, selected = false }
    -- 发牌动画：卡堆顶 → 牌桌中间扇形，抽牌动画同款翻面（pitch 180 卡背朝上
    -- 离堆 → 0 卡面朝上落位）+ yaw 从卡堆角度渐变到朝向本方；取消全程强制
    -- 正面（2026-08-10 反馈）。错峰发牌：delay 使前一槽动画进行一半（dur 0.5
    -- → 0.25s）时开始下一槽；翻面音效在动画实际启动时播放（onStart）。
    -- （re.md 重构：KARDS.AnimPlayer 6 值两关键帧）
    local endYaw = (slot == 1) and 180 or 0 -- 文字朝本方（P1 yaw180 / P2 yaw0：P1 卡组槽在牌桌 -x 侧，文字顶部需朝 +x 才正对 P1）
    KARDS.AnimPlayer:Play(ent, {
        { t = 0, pos = ent:GetLocalPos(), ang = Angle(180, ent:GetLocalAngles().y, 0) },
        { t = 0.5, pos = KARDS.MulliganFanPos(idx, m.total), ang = Angle(0, endYaw, 0) },
    }, {
        group = "mulliganDeal",
        delay = (idx - 1) * 0.25,
        onStart = function() KARDS.PlayKardsSound("draw") end, -- 翻面音效在动画实际启动时播放
    })
end

-- 本方重新调度补抽（isReplace=true，KardsMulliganDone 已置 submitted）：补抽卡
-- 从卡堆飞向牌桌中间扇形区的空位（被弃牌原序号位置），与保留卡一起待 1.4s 后
-- 统一进手牌（2026-08-10 补充动画，见 KardsMulliganAnimsUpdate 末段统一落位）
local function DeckDrawMulliganReplace(ent, slot, idx)
    KARDS.InitDrawCardFace(ent) -- 本方需看卡面（补抽卡进入中间扇形区待命）
    KARDS.drawFacePending[ent] = true
    ent:SetNoDraw(false)
    KARDS.BattleState.mulligan.cards[ent] = { ent = ent, index = idx, selected = false }
    KARDS.BattleState.mulligan.replaceGot = (KARDS.BattleState.mulligan.replaceGot or 0) + 1 -- 已收到补抽卡计数
    -- 发牌动画同款（卡堆顶 → 中间扇形区空位，翻面 + yaw 朝向本方）；错峰 delay
    -- 同起手发牌（按被弃原序号）；补抽不播抽牌音效（2026-08-10 需求：点击确定后
    -- 的抽牌静音，不注册 onStart 音效回调）
    local endYaw = (slot == 1) and 180 or 0
    KARDS.AnimPlayer:Play(ent, {
        { t = 0, pos = ent:GetLocalPos(), ang = Angle(180, ent:GetLocalAngles().y, 0) },
        { t = 0.5, pos = KARDS.MulliganFanPos(idx, KARDS.BattleState.mulligan.total), ang = Angle(0, endYaw, 0) },
    }, {
        group = "mulliganDeal",
        delay = (idx - 1) * 0.25,
    })
end

-- 爆牌（readme 7.1 手牌上限 9）：手牌已达上限，抽到的卡不进手牌，播放专属
-- 弃牌动画——卡堆顶 → 爆牌方视角左侧卡槽（交叉填槽，2026-08-12：P1 爆牌 →
-- P1LP2RSlot(+x) / P2 爆牌 → P1RP2LSlot(-x)，与指令动画一致，爆牌方看到弃牌在
-- 自己左侧）停留 KARDS.OverdrawHold 秒 → 沿槽位方向出场（+x 槽向右顺时针 / -x 槽向左
-- 逆时针，镜像对称）；动画结束隐藏实体（手牌不变：不 KARDS.RenumberHand /
-- 不登记 KARDS.BattleState.realHandCards / 不掉落手牌位）。
-- 牌面（2026-08-12，2026-10-03 联机排查更正）：弃牌不向对方公示。三方都调
-- KARDS.InitDrawCardFace，但卡名只经 KardsTableDrawFace 定向发给本槽玩家，对方与观战
-- 本地无 cardFaces 记录，InitDrawCardFace 在卡名为空时早退，故实际看到卡背，本方看卡面。
-- 提示：本方「你的手牌已满」/ 参战对方「敌方手牌已满」（观战者
-- 由服务端 OnBattleDraw 统一发 KardsHintObserver，故此处 Push 均 noRelay 防重复）。
-- 弃牌飞出动画（2026-09-26 缺口 E 抽出，供抽牌爆牌与节点弃牌/爆牌复用）：
-- 卡堆顶 → 侧卡槽（翻面）→ 槽位停留（第二、三关键帧同姿）→ 沿槽位方向出场，
-- 动画结束隐藏实体（卡被弃；临时卡为服务端网络实体，客户端不可 Remove，
-- 由服务端 ExitSlot / 牌桌 OnRemove 统一清理）。
-- side 取 "left" / "right"：槽位下标由 KARDS.CrossSlotFor 得出，出场方向符号沿用
-- 槽位归属推导（+x 槽向右顺时针 / -x 槽向左逆时针，镜像对称）。
-- @param ent   Entity 卡牌实体（抽牌/弃牌临时卡，服务端网络实体）
-- @param slot  number 归属槽位（1/2）
-- @param side  string 侧槽（"left" 抽牌爆牌 / "right" 节点弃牌与爆牌）
-- @param delay number|nil 起播延迟秒数（多张依次错峰用；缺省 nil = 立即，与既有单张调用一致）
local function OverdrawFly(ent, slot, side, delay)
    ent:SetNoDraw(false)
    -- 弃牌槽位交叉填槽（2026-08-12 修正）：此前固定 +x（P1LP2RSlot）导致 P2 爆牌
    -- 落在 P2 视角右侧（P1 视角左侧），与「爆牌方看弃牌在自己左侧」不符（用户
    -- 反馈：P1 视角下对方爆牌在 P1 左侧 / P2 视角下 P1 爆牌在 P2 右侧才正常）。
    local slotIdx = KARDS.CrossSlotFor(slot, side)
    local slotPose = KARDS.DisplaySlots[slotIdx]
    local startAng = Angle(180, ent:GetLocalAngles().y, 0) -- 卡背朝上离堆（同抽牌动画）
    local flyPose = { pos = slotPose.pos, ang = Angle(0, slotPose.ang.y, 0) } -- 槽位平躺正面朝上
    -- 出场沿槽位方向（2026-08-12）：+x 槽向右顺时针出场（原 ClockwiseExitPose）；
    -- -x 槽向左逆时针出场——镜像对称，从爆牌方视角看弃牌都在自己左侧飞出
    local exitSign = (slotIdx == KARDS.P1LP2RSlot) and 1 or -1
    local exitPose = {
        pos = flyPose.pos + Vector(exitSign * KARDS.ExitFlyDist, 0, 0),
        ang = Angle(flyPose.ang.p, flyPose.ang.y - exitSign * 135, flyPose.ang.r),
    }
    -- 4 关键帧：卡堆顶 → 槽位（翻面）→ 槽位停留（第二、三关键帧同姿）→ 出场
    KARDS.AnimPlayer:Play(ent, {
        { t = 0, pos = ent:GetLocalPos(), ang = startAng },
        { t = KARDS.OverdrawFlyDur, pos = flyPose.pos, ang = flyPose.ang },
        { t = KARDS.OverdrawFlyDur + KARDS.OverdrawHold, pos = flyPose.pos, ang = flyPose.ang },
        { t = KARDS.OverdrawFlyDur + KARDS.OverdrawHold + KARDS.OverdrawExitDur, pos = exitPose.pos, ang = exitPose.ang },
    }, {
        group = "deckOverdraw",
        delay = delay, -- 多张依次错峰（2026-09-27 E2）：等待期内保持本帧起点姿态（卡堆顶）
        onComplete = function(target)
            -- 爆牌：卡被弃，隐藏实体（同弃牌回卡组；抽牌临时卡为服务端网络实体，
            -- 客户端不可 Remove，由服务端 ExitSlot / 牌桌 OnRemove 统一清理）
            if IsValid(target) then target:SetNoDraw(true) end
        end,
    })
end

local function DeckDrawOverdraw(ent, slot, isMine)
    KARDS.InitDrawCardFace(ent)
    KARDS.drawFacePending[ent] = true
    if isMine then
        KARDS.BattleHint.Push("你的手牌已满", true)
    elseif KARDS.Perspective and KARDS.Perspective.LocalView ~= nil then
        KARDS.BattleHint.Push("敌方手牌已满", true)
    end
    OverdrawFly(ent, slot, "left")
end

-- 其余（对方/观战补抽 / 后续回合抽牌）：直接落手牌扇形（原位）——视角三分
-- （2026-08-12）：本方（isMine）/ 观战（非本方且 LocalView=nil）/
-- 对方（非本方且 LocalView=1|2，cl_perspective.lua P.LocalView）
local function DeckDrawToHand(ent, slot, idx, total, isMine, isReplace)
    local faceUp = isMine -- 本方看卡面；对方/观战看卡背（不改写 manifest）
    if faceUp then
        KARDS.InitDrawCardFace(ent)
        KARDS.drawFacePending[ent] = true
    end
    ent:SetNoDraw(false)
    KARDS.BattleState.realHandCards[slot][ent] = idx
    -- 剩余手牌按新张数重排扇形（2026-08-11 修复：原 KARDS.StartHandShift 只按
    -- Kards_IsHandSlotCard 左移 2.5——占位空手牌移除后无人设置该 NW → 恒为空操作，
    -- 导致抽牌后既有手牌不随新张数更新扇形分布（KardsRealHandFacing 仅驱动角度，
    -- 位置仍停旧扇形）。此处立即按服务端广播的 total 重排：位置/角度平滑过渡到
    -- 新扇形位；新卡经 deckDraw 动画落位（skipEnt 排除，避免 Play 替换其飞行动画））
    KARDS.RenumberHand(slot, ent, total)
    local handPos, handAng = KARDS.HandFanPos(slot, idx, total) -- 预设扇形落位（位置+角度，服务端同款）
    local endYaw = handAng.y -- 落手牌位朝向（KARDS.HandFanPos：位置基准 + fan 角 + 文字朝向）
    local obs = (not isMine) and (KARDS.Perspective.LocalView == nil)
    -- 重新调度补抽（对方/观战侧）动画不动：卡堆顶 → 手牌原位直接飞行
    -- （skipCenter 原逻辑：直飞 + 终点停留 0.25s，与弃牌回卡组动画同时进行）
    if isReplace then
        local dur1, hold, dur2 = 0.45, 0, 0.25
        KARDS.AnimPlayer:Play(ent, {
            { t = 0, pos = ent:GetLocalPos(), ang = Angle(0, ent:GetLocalAngles().y, 0) },
            { t = dur1, pos = handPos, ang = Angle(0, endYaw, 0) },
            { t = dur1 + hold, pos = handPos, ang = Angle(0, endYaw, 0), event = "shift" },
            { t = dur1 + hold + dur2, pos = handPos, ang = Angle(0, endYaw, 0) },
        }, {
            group = "deckDraw",
            onKeyframe = function(target, name)
                if name == "shift" then KARDS.StartHandShift() end -- 阶段 3：为新卡让位
            end,
        })
        return
    end
    -- 对方视角：直接到手牌、不翻面（看对方手牌本身就不翻面），无第三、四关键帧，
    -- 第二关键帧直接到手牌（无桌中停留；手牌让位由 KARDS.RenumberHand 立即重排接管）
    if not isMine and not obs then
        KARDS.AnimPlayer:Play(ent, {
            { t = 0, pos = ent:GetLocalPos(), ang = Angle(0, ent:GetLocalAngles().y, 0) },
            { t = KARDS.EnemyDrawDirectDur, pos = handPos, ang = Angle(0, endYaw, 0) },
        }, {
            group = "deckDraw",
            onStart = function() KARDS.PlayKardsSound("draw") end, -- 抽牌音效（动画实际启动时播放）
        })
        return
    end
    -- 本方 / 观战：卡堆顶 → 桌中翻面（第二关键帧终点 z 抬升于桌面顶 +3.4，贴近视线；
    -- 2026-08-11 修复：原 z=CardZ 贴桌面，抽牌翻面阶段过低。该高度为抽牌专用，2026-09-30
    -- 中槽统一后重新调度扇形已升到中槽高度（KARDS.CenterSlotPos.z），两者不再同高）
    -- → 桌中停留 → 手牌位。观战动画与此相同，但第二关键帧终点
    -- 额外向抽牌者旋转（P1 yaw0 / P2 yaw180，cl_perspective.lua FacingYaw 观战基准）；
    -- 本方桌中朝向本方（P1 yaw180 / P2 yaw0，与重新调度发牌落位一致；2026-08-11
    -- 修复：原固定 0° 对 P1 文字朝向反了）
    local centerYaw = obs and ((slot == 1) and 0 or 180) or ((slot == 1) and 180 or 0)
    local dur1, hold, dur2 = 0.45, 0.5, 0.4
    local centerPos = KARDS.Animation.Board2D:RelPos(3, 0) + Vector(0, 0, 3.4)
    -- 翻面：本方卡 卡背朝上 → 卡面朝上（KARDS.InitDrawCardFace 改 manifest）；观战卡背朝上
    -- → 卡背朝上（姿态同本方，不 KARDS.InitDrawCardFace → 两面卡背，不泄露牌面）
    local pitch0 = (faceUp or obs) and 180 or 0
    -- 4 关键帧：卡堆顶 → 桌中（翻面 + yaw 朝向本方/抽牌者）→ 桌中停留（两相同帧）→ 手牌位
    -- （re.md 重构：KARDS.AnimPlayer；越过停留帧（离开桌中）触发手牌槽卡左移 KARDS.StartHandShift）
    KARDS.AnimPlayer:Play(ent, {
        { t = 0, pos = ent:GetLocalPos(), ang = Angle(pitch0, ent:GetLocalAngles().y, 0) },
        { t = dur1, pos = centerPos, ang = Angle(0, centerYaw, 0) },
        { t = dur1 + hold, pos = centerPos, ang = Angle(0, centerYaw, 0), event = "shift" },
        { t = dur1 + hold + dur2, pos = handPos, ang = Angle(0, endYaw, 0) },
    }, {
        group = "deckDraw",
        onStart = function() KARDS.PlayKardsSound("draw") end, -- 抽牌音效（动画实际启动时播放）
        onKeyframe = function(target, name)
            if name == "shift" then KARDS.StartHandShift() end -- 阶段 3：为新卡让位
        end,
    })
end

net.Receive("KardsTableDeckDraw", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local idx = net.ReadUInt(8)
    local total = net.ReadUInt(8)
    local isReplace = net.ReadBool()
    local isOverdraw = net.ReadBool() -- 本张卡爆牌标记（手牌已达上限 9，服务端数据层 per-card 判定）
    -- 卡名已移出本广播（规划 B1）：手牌卡面信息改由 KardsTableDrawFace 定向发本方，
    -- 卡面渲染经 KARDS.GetCardIdentity 读本地表；对方/观战者收不到 → 无法读手牌。
    if not IsValid(ent) then return end
    KARDS.battleDeckDrawn[ent] = true -- 从堆叠移除（可见性钩子跳过，动画驱动接管）
    KARDS.BattleState.entSpawnPos[ent] = ent:GetLocalPos() -- 弃牌回卡组动画的终点（服务端卡堆顶）
    -- 2026-09-13 规划 S2：本消息载荷首字段是抽牌卡实体（不带牌桌），卡经
    -- SpawnDeckDrawCard → RegisterChild 以牌桌为父级，反查归属桌做跨桌过滤。
    -- battleDeckDrawn / entSpawnPos 按实体键且仅影响本桌渲染扫描，跨桌也保留；
    -- mulliganStarted / dealStarterCount 与发牌调度写本地单例，仅关注桌执行。
    local tableEnt = ent:GetParent()
    if slot ~= 1 and slot ~= 2 then return end -- slot 越界（至此载荷已读完）
    if not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    -- 观战重新调度进度（2026-08-12，KardsSpectateMulliganHUD）：非补抽且该槽未完成
    -- 重新调度 → 属于重新调度发牌（本方/观战均适用），置位 mulliganStarted。
    -- 完成标记数据源：真观战者用 spectate.mulliganDone（KardsTableBattleStart 观战分支
    -- 创建，避免混用参战者 mulliganDoneSlot 的上一场残留）；kards_view 参战者用
    -- mulliganDoneSlot（对局开始已复位）。
    local sp = KARDS.BattleState.spectate
    local spDone = (sp and sp.ent == ent) and sp.mulliganDone or nil
    local doneSet = spDone or KARDS.BattleState.mulliganDoneSlot
    if not isReplace and not doneSet[slot] then
        KARDS.BattleState.mulliganStarted = true
        -- 2026-08-12（kards_switch 代选用）：该槽首次收到发牌广播（非补抽且尚未完成
        -- 重新调度）→ 记录起手张数（先手 4 / 后手 5）。切换操作身份代选时只把起手牌
        --（idx ≤ 该数）呈现为选择扇形，后续回合抽牌（idx 递增）留在手牌位。
        if not KARDS.BattleState.dealStarterCount[slot] then
            KARDS.BattleState.dealStarterCount[slot] = total
        end
    end
    local isMine = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot
    -- 分支调度（2026-08-15 C5 拆分，原三 if+return 链等价）
    if isMine and not isReplace and not KARDS.BattleState.mulliganDoneSlot[slot] then
        DeckDrawDealHand(ent, slot, idx, total)
    elseif isMine and isReplace and KARDS.BattleState.mulligan and KARDS.BattleState.mulligan.slot == slot then
        DeckDrawMulliganReplace(ent, slot, idx)
    elseif isOverdraw then
        DeckDrawOverdraw(ent, slot, isMine)
    else
        DeckDrawToHand(ent, slot, idx, total, isMine, isReplace)
    end
end)

-- 节点弃牌 / 爆牌单卡飞出（2026-09-26 缺口 E）：服务端 PileCardRemoved 事件经
-- BroadcastPileCardFlyOut 广播。卡从该方视角右侧卡槽飞出（与抽牌爆牌的左侧槽位
-- 表现区分），仅本方能看到卡面，对手与观战显示卡背（2026-08-18 规划的卡面保密
-- 约定：卡面标识 KardsTableDrawFace 定向只发本方），不推任何「手牌已满」提示。
net.Receive("KardsPileCardFlyOut", function()
    local tableEnt = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local n = net.ReadUInt(8)
    local ents = {}
    for i = 1, n do ents[i] = net.ReadEntity() end
    if slot ~= 1 and slot ~= 2 then return end
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    -- 多张依次错峰（2026-09-27 E2）：相邻卡起播间隔取首段飞行时长的一半（0.25 秒），并按
    -- 张数收敛在服务端兜底清理前播完（单卡 1.85 秒，兜底 2.5 秒，错峰总预算 0.6 秒）。
    -- 弃置载体不进 KARDS.BattleState.realHandCards，拿起判定（cl_battle_drag.lua 的
    -- HandHitTest 按手牌登记命中）天然排除这一类实体，播放期间不会被鼠标握住。
    local live = {}
    for _, ent in ipairs(ents) do
        if IsValid(ent) then live[#live + 1] = ent end
    end
    local step = (#live > 1) and math.min(0.25, 0.6 / (#live - 1)) or 0
    local wait = 0
    for _, ent in ipairs(live) do
        KARDS.battleDeckDrawn[ent] = true -- 从堆叠移除（可见性钩子跳过，动画驱动接管）
        KARDS.BattleState.entSpawnPos[ent] = ent:GetLocalPos() -- 卡堆顶（动画起点兜底）
        KARDS.InitDrawCardFace(ent) -- 仅本方有定向卡面记录可显示卡面；对手/观战显示卡背
        KARDS.drawFacePending[ent] = true
        OverdrawFly(ent, slot, "right", wait)
        wait = wait + step
    end
end)

-- 手牌弃牌飞出（2026-10-06 用户规格）：玩家选择/序数弃掉的手牌移到该方视角右槽，
-- 停留 1 秒后顺时针出场。复用节点弃牌右槽口径（OverdrawFly：按弃牌方 slot 交叉填槽取
-- 右侧槽位，+x 槽顺时针 / -x 槽逆时针），所有查看端动画一致；对方/观战端因无定向卡面
-- 记录（KardsTableDrawFace 只发本方）而自动显示卡背。弃牌已移出该方手牌，故先摘除手牌
-- 登记并重排其余手牌让位。
net.Receive("KardsHandCardFlyOut", function()
    local tableEnt = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local ent = net.ReadEntity()
    if slot ~= 1 and slot ~= 2 then return end
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    if not IsValid(ent) then return end
    KARDS.battleDeckDrawn[ent] = true -- 从堆叠/兜底显隐移除（动画驱动接管）
    -- 摘除手牌登记 + 其余手牌按新张数重排让位（弃牌已离手）
    if KARDS.BattleState.realHandCards[slot] then
        KARDS.BattleState.realHandCards[slot][ent] = nil
    end
    KARDS.RenumberHand(slot, ent)
    KARDS.InitDrawCardFace(ent) -- 仅本方有定向卡面记录可显示卡面；对手/观战显示卡背
    KARDS.drawFacePending[ent] = true
    OverdrawFly(ent, slot, "right")
end)

-- 手牌卡面定向（2026-08-18，规划 B1）：服务端 KardsTableDrawFace 只发给本方玩家，
-- 记录手牌实体 → 卡牌标识，供卡面渲染（InitDrawCardFace）/拖拽判定（卡类型）/
-- 指向机制（卡文件）读取。手牌实体 NW 已不再写卡名/卡文件/类型，对方/观战者
-- 收不到本消息 → 无法读对手手牌。实体失效时 weak keys 自动清理。
net.Receive("KardsTableDrawFace", function()
    local ent = net.ReadEntity()
    local name = net.ReadString()
    local fileName = net.ReadString()
    local ctype = net.ReadString()
    if not IsValid(ent) then return end
    KARDS.BattleState.cardFaces[ent] = { name = name, fileName = fileName, ctype = ctype }
    -- 卡面初始化可能在卡面定向消息到达前已入队（KardsReturnToHand 同帧触发）：
    -- drawFacePending Think 轮询经 KARDS.GetCardIdentity 读到定向记录后自动初始化。
end)

-- 返回手牌动画时长（2026-08-13）：对称于部署「手牌实体 → 小模型单位」——
-- 服务端已在小模型原位创建正常卡模型动画载体，本端播小模型 → 正常模型原地切换 +
-- 飞回手牌末位空位。本方/观战途经牌桌中心（z 抬升，同抽牌桌中高度）三段时长对齐
-- 抽牌动画（dur1/hold/dur2）；对方直飞（空位/移动/翻面同时进行）总时长为本方/观战
-- 的一半（用户规格）。
local ReturnAnimOwnerDur1 = 0.45  -- 原位 → 牌桌中心飞行时长（秒，同抽牌动画 dur1）
local ReturnAnimOwnerHold = 0.5   -- 牌桌中心停留时长（秒，同抽牌动画 hold）
local ReturnAnimOwnerDur2 = 0.4   -- 牌桌中心 → 手牌空位飞行时长（秒，同抽牌动画 dur2）

-- ====================================================================
-- 返回手牌动画（数据层 SimReturnToHand → 实体层 KardsReturnToHand 广播，
-- 见 table_battledeck.lua SpawnReturnedCard / BroadcastReturnToHand）
-- 对称于部署动画：服务端已在源战场实体（小模型单位）原位创建正常卡模型实体
-- （SpawnReturnedCard），本端先隐藏小模型（原地切换为正常模型）再播飞回手牌动画。
-- 视角三分（同抽牌动画 KardsTableDeckDraw）：
--   本方 / 观战：原位 → 牌桌中心（z 抬升 +3.4，贴近视线）→ 手牌末位空位；
--   对方：直接飞手牌末位空位 + 翻面（pitch 0 → 180 卡背朝上），时长为本方/观战一半；
-- 手牌按新张数重排（KARDS.RenumberHand 让出末位空位，组 "handRepos"）与飞行动画同时开始；
-- 动画组用 "deckDraw"（已列入 KardsRealHandFacing / 拖拽 / 悬停的动画中跳过组，
-- 动画期间朝向不被 Think 覆盖，结束后 Think 按视角接管）。
-- ====================================================================
net.Receive("KardsReturnToHand", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local unitEnt = net.ReadEntity() -- 源战场实体（小模型；老兵回退已移除时 NULL）
    local cardEnt = net.ReadEntity() -- 新卡实体（正常模型动画载体，位于小模型原位）
    local idx = net.ReadUInt(8)
    local total = net.ReadUInt(8)
    if not IsValid(ent) or not IsValid(cardEnt) then return end
    -- 2026-09-13 规划 S2：首字段即牌桌，跨桌广播不落本地手牌单例
    --（realHandCards[slot] 索引对越界 slot 还会直接报错），载荷至此已读完
    if slot ~= 1 and slot ~= 2 then return end
    if not KARDS.BattleState:IsLocalTable(ent) then return end
    -- 2026-10-03 联机排查 NEW-10：清远程拖拽残留（新卡实体与源小模型各清一次），
    -- 否则远程拖拽的每帧驱动会覆盖本段返回手牌动画
    if KARDS.BattleState.remoteDrags then
        KARDS.BattleState.remoteDrags[cardEnt] = nil
        if IsValid(unitEnt) then KARDS.BattleState.remoteDrags[unitEnt] = nil end
    end
    local isMine = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot
    local obs = (not isMine) and (KARDS.Perspective.LocalView == nil)
    -- 小模型原地切换为正常模型：本地隐藏源战场实体（各端各自隐藏；服务端动画完成
    -- KardsReturnToHandDone / 兜底定时移除）——新卡实体已在原位，视觉为原地切换
    if IsValid(unitEnt) then
        unitEnt:SetNoDraw(true)
        if KARDS.CardTextOverlay then KARDS.CardTextOverlay:Remove(unitEnt) end
    end
    -- 新卡实体：本方需卡面（返回手牌后手牌显示初始属性卡面，与老兵回退为初始
    -- 非老兵状态一致）；对方/观战不初始化（两面卡背，不泄露牌面）
    if isMine then
        KARDS.InitDrawCardFace(cardEnt)
        KARDS.drawFacePending[cardEnt] = true
    end
    cardEnt:SetNoDraw(false)
    KARDS.BattleState.realHandCards[slot][cardEnt] = idx
    -- 手牌按新张数重排（空位动画）：返回手牌总是追加末位（idx=total），其余手牌
    -- 重排让出末位空位，与飞行动画同时进行（KARDS.RenumberHand 组 "handRepos" 独立并行）
    KARDS.RenumberHand(slot, cardEnt, total)
    local handPos, handAng = KARDS.HandFanPos(slot, idx, total)
    local endYaw = handAng.y
    local startPos = cardEnt:GetLocalPos()
    local startYaw = cardEnt:GetLocalAngles().y
    -- 对方视角：直接移动到手牌空位，同时空位让位 / 卡牌移动 / 卡牌翻面（pitch 0 →
    -- 180 卡背朝上，同对方手牌常态姿态）同时进行，总时长为本方/观战的一半（用户规格）
    if not isMine and not obs then
        local dur = (ReturnAnimOwnerDur1 + ReturnAnimOwnerHold + ReturnAnimOwnerDur2) / 2
        KARDS.AnimPlayer:Play(cardEnt, {
            { t = 0, pos = startPos, ang = Angle(0, startYaw, 0) },
            { t = dur, pos = handPos, ang = Angle(180, endYaw, 0) },
        }, { group = "deckDraw" })
        return
    end
    -- 本方 / 观战：原位 → 牌桌中心（z 抬升 +3.4，同抽牌桌中高度）→ 手牌末位空位
    local centerYaw = obs and ((slot == 1) and 0 or 180) or ((slot == 1) and 180 or 0)
    local centerPos = KARDS.Animation.Board2D:RelPos(3, 0) + Vector(0, 0, 3.4)
    KARDS.AnimPlayer:Play(cardEnt, {
        { t = 0, pos = startPos, ang = Angle(0, startYaw, 0) },
        { t = ReturnAnimOwnerDur1, pos = centerPos, ang = Angle(0, centerYaw, 0) },
        { t = ReturnAnimOwnerDur1 + ReturnAnimOwnerHold, pos = centerPos, ang = Angle(0, centerYaw, 0) },
        { t = ReturnAnimOwnerDur1 + ReturnAnimOwnerHold + ReturnAnimOwnerDur2, pos = handPos, ang = Angle(0, endYaw, 0) },
    }, {
        group = "deckDraw",
        onComplete = function()
            -- 通知服务端移除源战场实体并清理映射（仅所有者；观战/对方不发送，
            -- 服务端 BroadcastReturnToHand 兜底定时 ReturnAnimServerRemoveDelay 清理）
            if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent
                and KARDS.BattleState.inTable.slot == slot then
                net.Start("KardsReturnToHandDone")
                    net.WriteEntity(ent)
                    net.WriteEntity(cardEnt)
                net.SendToServer()
            end
        end,
    })
end)

-- 手牌槽卡左移动画驱动（每帧）：抽牌动画阶段 3（KardsTableDeckDraw 的
-- "deckDraw" 组动画离开桌中停留帧时触发 KARDS.StartHandShift）后，本玩家手牌槽卡
-- 向左移动部分为新卡让位；占位空手牌已移除后该部分为空操作。抽牌动画本体由
-- KARDS.AnimPlayer 驱动（re.md 重构），本钩子仅保留多实体批量平移。
hook.Add("Think", "KardsDeckDrawUpdate", function()
    -- 手牌槽卡左移（阶段 3 触发）
    if KARDS.deckDrawShift then
        local t = (CurTime() - KARDS.deckDrawShift.start) / KARDS.deckDrawShift.dur
        local e = KARDS.RevealEaseInOut(math.min(t, 1))
        for _, item in ipairs(KARDS.deckDrawShift.items) do
            if IsValid(item.ent) then
                local pos = item.ent:GetLocalPos()
                item.ent:SetLocalPos(Vector(item.fromX + item.dx * e, pos.y, pos.z))
            end
        end
        if t >= 1 then KARDS.deckDrawShift = nil end
    end
end)

-- ====================================================================
-- 重新调度完成广播（服务端 OnMulliganSubmit，先于补抽发牌广播）：
--   本方：被弃卡从牌桌中间回卡组；保留卡留在中间扇形区不移动，被弃卡空位
--     等待补抽卡飞入（KardsTableDeckDraw isReplace 分支），0.7s（toHandAt）
--     后中间扇形区卡统一落手牌位（见 KardsMulliganAnimsUpdate 末段统一落位）；
--   对方/观战：被弃卡从对方手牌位回卡组（对方保留卡本就停手牌位，不移动），
--     补抽卡直接落手牌原位（见上方接收器 skipCenter 分支）。
-- ====================================================================
net.Receive("KardsMulliganDone", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local n = net.ReadUInt(8)
    local ents = {}
    for _ = 1, n do ents[#ents + 1] = net.ReadEntity() end
    if not IsValid(ent) then return end
    KARDS.BattleState.mulliganDoneSlot[slot] = true
    -- 观战重新调度进度（2026-08-12，KardsSpectateMulliganHUD）：观战者同样接收
    -- KardsMulliganDone 广播，写入 spectate.mulliganDone（槽位完成标记）；同时置位
    -- mulliganStarted（错过发牌广播时的兜底——观战中途进入仍能显示剩余一方进度）
    KARDS.BattleState.mulliganStarted = true
    local sp = KARDS.BattleState.spectate
    if sp and sp.ent == ent then sp.mulliganDone[slot] = true end
    local isMine = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot
    -- 被弃卡回卡组：从当前所在位置（本方=牌桌中间 / 对方=手牌位）飞回卡堆顶
    if #ents > 0 then KARDS.PlayKardsSound("shuffle") end -- 洗牌音效（弃牌洗入卡组，一次）
    for _, e in ipairs(ents) do
        if IsValid(e) then
            -- 回卡组动画（re.md 重构：KARDS.AnimPlayer 6 值两关键帧）：翻回卡背朝上
            -- （本方被弃卡原本卡面朝上；对方/观战本就卡背无变化）飞回卡堆顶，
            -- 结束 SetNoDraw 回卡堆档位 + 移出真实手牌
            KARDS.AnimPlayer:Play(e, {
                { t = 0, pos = e:GetLocalPos(), ang = Angle(0, e:GetLocalAngles().y, 0) },
                { t = 1.1, pos = KARDS.BattleState.entSpawnPos[e] or KARDS.PileBase[slot], ang = Angle(180, KARDS.PileYaw[slot], 0) },
            }, {
                group = "mulliganReturn",
                onComplete = function(target)
                    if IsValid(target) then target:SetNoDraw(true) end -- 已回到卡组内（卡堆档位模型表现厚度）
                    KARDS.BattleState.realHandCards[slot][target] = nil
                end,
            })
            KARDS.BattleState.realHandCards[slot][e] = nil
        end
    end
    -- 本方：保留卡留在牌桌中间扇形区（不移动，2026-08-10 补充动画），被弃卡空位
    -- 等待补抽卡飞入；1.4s 后中间扇形区卡（保留 + 补抽）统一进手牌，见
    -- KardsMulliganAnimsUpdate 末段统一落位（KARDS.BattleState.mulligan 保留至落位完成）
    if isMine and KARDS.BattleState.mulligan and KARDS.BattleState.mulligan.slot == slot then
        KARDS.BattleState.mulligan.toHandAt = CurTime() + 1.4     -- 确认后 1.4s 统一落手牌（可微调；2026-08-13 动画放慢一倍，原 0.7）
        KARDS.BattleState.mulligan.expectedReplace = #ents        -- 补抽卡数 = 被弃卡数（服务端原位替换）
        KARDS.BattleState.mulligan.replaceGot = 0                 -- 已收到补抽卡计数（随补抽广播递增）
        for _, e in ipairs(ents) do
            if IsValid(e) then KARDS.BattleState.mulligan.cards[e] = nil end -- 被弃卡移出待落位表
        end
        KARDS.UpdateTableMouse() -- 仍处牌桌内：鼠标保持呼出（2026-08-10）
        KARDS.BattleState.prevMulliganLeft = false
    end
end)

-- 重新调度动画驱动（每帧）：发牌 / 弃牌回卡组 / 落手牌动画本体由 KARDS.AnimPlayer
-- 驱动（re.md 重构），本钩子仅保留「发牌完成判定」与「统一落位调度」两段业务逻辑
hook.Add("Think", "KardsMulliganAnimsUpdate", function()
    -- 发牌动画全部结束后才允许选择（2026-08-10 补充动画）：KARDS.BattleState.mulligan 创建时
    -- active=false，待所有发牌（起手/补抽）动画完成（"mulliganDeal" 组清空）
    -- 后置 active=true，选择交互 / 确认按钮 HUD 才生效
    if KARDS.BattleState.mulligan and not KARDS.BattleState.mulligan.active and not KARDS.BattleState.mulligan.submitted
        and not KARDS.AnimPlayer:Any("mulliganDeal") then
        KARDS.BattleState.mulligan.active = true
    end
    -- 统一落位（2026-08-10 补充动画）：KardsMulliganDone 设 toHandAt（确认后 1.4s）。
    -- 到时后，中间扇形区的卡（保留 + 已到达的补抽）逐张落手牌位（KARDS.HandFanPos）；
    -- 仍在飞入的补抽卡（"mulliganDeal" 组动画）等其落位后再启动（晚到不搁浅）；
    -- 全部落位完成后清理 KARDS.BattleState.mulligan（保留至此刻：补抽卡才知该飞向中间区空位）。
    -- 每张卡只启动一次（card.toHandStarted），落位期间由 AnimPlayer 驱动，
    -- 结束后 KARDS.BattleState.realHandCards 登记仍保留，KardsRealHandFacing 兜底接管角度。
    if KARDS.BattleState.mulligan and KARDS.BattleState.mulligan.submitted and KARDS.BattleState.mulligan.toHandAt
        and CurTime() >= KARDS.BattleState.mulligan.toHandAt then
        -- 抽牌音效：存在本帧待启动落位的卡（保留/补抽 中间扇形区 → 手牌）时播一次，
        -- 避免每张各播一次叠音（统一落位一次即可）
        local willStart = false
        for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
            if IsValid(ce) and not card.toHandStarted
                and not KARDS.AnimPlayer:Active(ce, "mulliganDeal") then
                willStart = true
                break
            end
        end
        if willStart then KARDS.PlayKardsSound("draw") end
        local allSettled = true
        local anyValid = false
        for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
            if IsValid(ce) then
                anyValid = true
                if not card.toHandStarted then
                    if KARDS.AnimPlayer:Active(ce, "mulliganDeal") then
                        allSettled = false -- 补抽卡仍在飞入：等其落位（下一帧再启动）
                    else
                        card.toHandStarted = true
                        local toPos, toAng = KARDS.HandFanPos(KARDS.BattleState.mulligan.slot, card.index, KARDS.BattleState.mulligan.total)
                        -- 落手牌位：位置渐变到扇形槽位 + yaw 渐变到扇形角度（无翻面，pitch 恒 0）
                        KARDS.AnimPlayer:Play(ce, {
                            { t = 0, pos = ce:GetLocalPos(), ang = Angle(0, ce:GetLocalAngles().y, 0) },
                            { t = 1.0, pos = toPos, ang = Angle(0, toAng.y, 0) },
                        }, { group = "mulliganToHand" })
                        KARDS.BattleState.realHandCards[KARDS.BattleState.mulligan.slot][ce] = card.index
                        allSettled = false -- 本帧刚启动，等动画结束
                    end
                elseif KARDS.AnimPlayer:Active(ce, "mulliganToHand") then
                    allSettled = false -- 落位动画进行中
                end
            end
        end
        if anyValid and allSettled then
            KARDS.BattleState.mulligan = nil -- 全部落位完成：清理（退出牌桌/新对局本就重置，此处为常态清理）
        end
    end
end)

-- ====================================================================
-- 重新调度动画结束通知（2026-08-13）：本方提交且本方统一落位完成后（mulligan 清理），
-- 再等本方视角所有重新调度动画组清空（起手/补抽 "mulliganDeal" + 弃牌回卡组
-- "mulliganReturn"——对方/虚拟对手的调度动画同样由这些组驱动，见 OnBattleDraw），
-- 即「本方视角看到的双方调度动画均已实际播完」时，发送 KardsMulliganAnimDone 给服务端
--（服务端 CheckAllMulligansDone 等全部参战槽的 mulliganDone + mulliganAnimDone 才
-- StartFirstTurn，替代此前固定延迟——见 table_battledeck.lua net.Receive 注释）。
-- 每槽只发送一次（mulliganAnimSentSlot[slot]；kards_switch 切换操作身份后，
-- 玩家代选虚拟对手槽完成其重新调度时，该槽作为当前视角槽独立发送一次）。
-- ====================================================================
hook.Add("Think", "KardsMulliganAnimDoneNotify", function()
    local BS = KARDS.BattleState
    local inTable = BS.inTable
    if not (inTable and inTable.slot) then return end -- 非槽位视角（观战者）不发送
    if BS.mulliganAnimSentSlot[inTable.slot] then return end -- 该槽动画结束通知已发送
    if not BS.mulliganDoneSlot[inTable.slot] then return end -- 该槽尚未提交重新调度
    if BS.mulligan ~= nil then return end -- 该槽统一落位未完成（含补抽仍在飞入）
    -- 本方视角所有重新调度动画组已结束（任一仍在播/排队则等待，晚到不提前发）：
    --   起手/本方补抽 "mulliganDeal"（OnBattleDraw 本方分支）
    --   对方/观战补抽 "deckDraw"（OnBattleDraw 对方补抽分支，L3038 起——2026-08-13
    --     漏检修复：此前只查 mulliganDeal/mulliganReturn，对方补抽动画被漏掉导致
    --     通知过早、回合提前开始）
    --   弃牌回卡组 "mulliganReturn"（KardsMulliganDone 接收器）
    --   补抽触发的手牌重排 "handRepos"（KARDS.RenumberHand）
    if KARDS.AnimPlayer:Any("mulliganDeal") or KARDS.AnimPlayer:Any("mulliganReturn")
        or KARDS.AnimPlayer:Any("deckDraw") or KARDS.AnimPlayer:Any("handRepos") then return end
    BS.mulliganAnimSentSlot[inTable.slot] = true
    net.Start("KardsMulliganAnimDone")
        net.WriteEntity(inTable.ent)
        net.WriteUInt(inTable.slot, 8)
    net.SendToServer()
end)

-- ====================================================================
-- 重新调度选择交互：牌桌中间扇形卡 左键点击 选中/取消（选中=丢弃；2026-08-13 起
-- 选中不再使卡 z 上移，仅以卡面上方选中图标标示）；屏幕点击器在重新调度期间开启
-- （自由鼠标：点卡片 + 点准星下方「确认」按钮），提交 / 完成 / 退出时关闭。
-- ====================================================================

-- 选中卡图标材质（materials/kards/cards/choose.png，3D2D 绘制于卡面上方 z+0.1）
local chooseMat = Material("materials/kards/cards/choose.png", "noclamp smooth")

-- 射线到牌桌中间扇形卡的最近距离判定（同卡堆悬停 KARDS.RayPointDistSqr 方法）
local function HitMulliganCard(mX, mY)
    local ply = LocalPlayer()
    if not IsValid(ply) then return nil end
    local pos = KARDS.BattleCamera.ViewPos or ply:EyePos()
    local dir = gui.ScreenToVector(mX, mY)
    if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then return nil end
    local bestEnt, bestD = nil, 100 -- 阈值 10^2（扇形卡间距 4 单位，半对角 ~6.5）
    for ce in pairs(KARDS.BattleState.mulligan.cards) do
        if IsValid(ce) then
            local d = KARDS.RayPointDistSqr(pos, dir, ce:GetPos())
            if d < bestD then bestEnt, bestD = ce, d end
        end
    end
    return bestEnt
end

-- 提交重新调度（点击「确认」）：被选中的卡 = 不想要的牌 → 发送服务端
local function SubmitMulligan()
    if not KARDS.BattleState.mulligan or not KARDS.BattleState.mulligan.active or KARDS.BattleState.mulligan.submitted then return end
    if not KARDS.BattleState.inTable then return end
    KARDS.BattleState.mulligan.submitted = true
    KARDS.PlayKardsSound("click_button") -- 确认按钮点击音效（点击按钮）
    local ents = {}
    for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
        if card.selected and IsValid(ce) then ents[#ents + 1] = ce end
    end
    net.Start("KardsMulliganSubmit")
        net.WriteEntity(KARDS.BattleState.inTable.ent)
        net.WriteUInt(#ents, 8)
        for _, e in ipairs(ents) do net.WriteEntity(e) end
    net.SendToServer()
    -- 确认提交后仍在牌桌内：鼠标保持呼出（2026-08-10；等待服务端广播落位动画）
    KARDS.UpdateTableMouse()
    KARDS.BattleState.prevMulliganLeft = false
end

hook.Add("Think", "KardsMulliganSelect", function()
    local active = KARDS.BattleState.mulligan and KARDS.BattleState.mulligan.active and not KARDS.BattleState.mulligan.submitted
    -- 牌桌内鼠标恒呼出（2026-08-10：KARDS.BattleState.mulligan 结束/确认后仍在牌桌内，不再关闭；
    -- 开关由 KARDS.UpdateTableMouse 按 KARDS.BattleState.inTable 统一决定，仅离开牌桌才关闭；内部记录
    -- 上次状态，active 期间每帧调用也无重复切换）
    KARDS.UpdateTableMouse()
    if not active then
        KARDS.BattleState.prevMulliganLeft = false
        return
    end
    -- 选择卡定格落位（发牌动画结束后；2026-08-13 用户规格：被选中时 z 不再移动，
    -- 选中仅由卡面上方选中图标标示）。
    -- 取消每帧强制正面/朝向（2026-08-10 反馈：改为抽牌动画同款翻面落位，角度由
    -- 发牌动画定格为扇面姿态 Angle(0, endYaw, 0)，此处仅保位置）。
    for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
        if IsValid(ce) and not KARDS.AnimPlayer:Active(ce, "mulliganDeal") then
            local pos = KARDS.MulliganFanPos(card.index, KARDS.BattleState.mulligan.total)
            local cur = ce:GetLocalPos()
            if cur.z ~= pos.z or cur.x ~= pos.x or cur.y ~= pos.y then
                ce:SetLocalPos(pos)
            end
        end
    end
    -- 左键上升沿：确认按钮优先，其次点击牌桌中间扇形卡
    local left = input.IsMouseDown(MOUSE_LEFT)
    if left and not KARDS.BattleState.prevMulliganLeft then
        local mX, mY = gui.MouseX(), gui.MouseY()
        local r = KARDS.BattleState.mulliganConfirmRect
        if r and mX >= r.x and mX <= r.x + r.w and mY >= r.y and mY <= r.y + r.h then
            SubmitMulligan()
        else
            local hit = HitMulliganCard(mX, mY)
            if hit and KARDS.BattleState.mulligan.cards[hit] then
                KARDS.BattleState.mulligan.cards[hit].selected = not KARDS.BattleState.mulligan.cards[hit].selected
                KARDS.PlayKardsSound("select_card") -- 选中/取消选择音效（选择卡牌）
            end
        end
    end
    KARDS.BattleState.prevMulliganLeft = left
end)

-- 文字提示渐变背景材质（materials/kards/ui/textUnderground.png，2026-08-11）：
-- 横向线性对称渐变——中心 70% 黑 → 两侧 0% 透明黑，作为重新调度提示文字横幅背景
-- （放大提示文字「选择要替换的卡牌」）；亦供「友方回合开始」提示横幅使用（线性渐变拉伸无损）
local textUndergroundMat = Material("materials/kards/ui/textUnderground.png", "noclamp smooth")

-- 重新调度 HUD（仅本方选择阶段）：选中卡图标（3D2D）+ 提示 + 准星下方「确认」按钮
hook.Add("HUDPaint", "KardsMulliganHUD", function()
    if not KARDS.BattleState.mulligan or not KARDS.BattleState.mulligan.active or KARDS.BattleState.mulligan.submitted then return end
    -- 被选中的卡：在卡面上方（局部 z+0.8）绘制选中图标。
    -- 图标尺寸 1.4 世界单位（卡宽 7.2）。
    -- 2026-08-13：原 z+0.1 低于卡模型顶面被 Z 缓冲遮挡 → 抬高至 0.8 悬浮于卡面上。
    -- 2026-09-27 修复：原方位角硬编码 Angle(90, ang.y, 0)，其 forward 为世界 (0,0,-1)、
    -- up 为水平向量 → 得到竖直平面（俯视几乎不可见，且图标被转 90°）。改用与本项目
    -- 所有卡面 3D2D 同款的角度构造式（见 cl_card_text_overlay.lua 坐标系注释）：
    -- dx = 卡面宽轴（实体 GetForward）、dy = 卡面长轴（实体 GetRight），
    -- 所得角度 up 即卡面法线，平面平躺于卡面上。
    for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
        if card.selected and IsValid(ce) then
            local dx = ce:GetForward()
            local dy = ce:GetRight()
            local camAng = dx:AngleEx(dx:Cross(-dy))
            cam.Start3D2D(ce:GetPos() + ce:GetUp() * 0.8, camAng, 1)
                surface.SetMaterial(chooseMat)
                surface.SetDrawColor(255, 255, 255, 255)
                surface.DrawTexturedRect(-0.7, -0.7, 1.4, 1.4)
            cam.End3D2D()
        end
    end
    -- 按钮：屏幕底部居中（2026-08-11 由准星下方移至底部——牌桌中间扇形卡投影在
    -- 屏幕中心，提示与按钮不遮挡卡面/牌桌视野；距底边 90px）
    local x, y = ScrW() / 2, ScrH() - 90
    local w, h = 160, 52
    KARDS.BattleState.mulliganConfirmRect = { x = x - w / 2, y = y - h / 2, w = w, h = h }
    -- 提示横幅（textUnderground.png 横向渐变背景，2026-08-11）：包裹放大提示文字，
    -- 置于按钮上方 8px
    local tipText = "选择要替换的卡牌"
    local tipFont = "SourceHan_Heavy_36"
    surface.SetFont(tipFont)
    local tw, th = surface.GetTextSize(tipText)
    local tipPadX, tipPadY = 28, 12 -- 渐变横幅内边距
    local tipW, tipH = tw + tipPadX * 2, th + tipPadY * 2
    local tipY = y - h / 2 - 8 - tipH -- 按钮顶 - 8px
    surface.SetMaterial(textUndergroundMat)
    surface.SetDrawColor(255, 255, 255, 255)
    surface.DrawTexturedRect(ScrW() / 2 - tipW / 2, tipY, tipW, tipH)
    draw.SimpleText(tipText, tipFont, ScrW() / 2, tipY + tipH / 2,
        Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 确认按钮（2026-09-13 起与不同步弹窗「重启」共用 KARDS.DrawActionButton：
    -- #BDBCAF 浅灰米色直角矩形，按下 #333229 / 文字 #C78736，见 cl_battle_desync.lua）
    KARDS.DrawActionButton(x, y, w, h, "确认")
end)

-- ====================================================================
-- 等待敌方重新调度提示（2026-08-12）：本方重新调度已完成（调度动画结束、
-- KARDS.BattleState.mulligan 已清理落位），对方尚未完成 → 持续提示
-- 「敌方正在重新调度手牌」，直到先手回合开始（服务端延迟 StartFirstTurn →
-- KardsTurnUpdate 广播 battleTurn 置位，见 table_battledeck.lua CheckAllMulligansDone）。
-- 与 KardsMulliganHUD 互斥：本提示仅在 mulligan == nil（本方动画已结束）时绘制。
-- ====================================================================
hook.Add("HUDPaint", "KardsWaitingOpponentMulliganHUD", function()
    local BS = KARDS.BattleState
    local inTable = BS and BS.inTable
    if not inTable or not IsValid(inTable.ent) then return end
    -- 观战视角（LocalView=nil，kards_view 观战者视角）由 KardsSpectateMulliganHUD
    -- 显示中性进度（「双方正在重新调度」/「「玩家名」正在重新调度」），
    -- 本方等待提示仅在槽位视角（P1/P2）下显示，避免双横幅叠加
    if KARDS.Perspective and KARDS.Perspective.LocalView == nil then return end
    if BS.battleTurn ~= nil then return end -- 先手回合已开始（双方调度动画结束、服务端延迟置位）
    if BS.mulligan ~= nil then return end   -- 本方重新调度动画未结束（选择/落位中）
    local mySlot = inTable.slot
    if not mySlot or not BS.mulliganDoneSlot[mySlot] then return end -- 本方尚未完成重新调度
    -- （2026-08-12）不按「对方 mulliganDoneSlot 完成」隐藏：对方提交后补抽 / 落位
    -- 动画仍在播放，提示持续到服务端延迟 StartFirstTurn 广播 battleTurn 才消失
    -- 提示横幅（与重新调度 HUD 同款渐变背景，屏幕居中）
    local tipText = "敌方正在重新调度手牌"
    local tipFont = "SourceHan_Heavy_36"
    surface.SetFont(tipFont)
    local tw, th = surface.GetTextSize(tipText)
    local tipPadX, tipPadY = 28, 12
    local tipW, tipH = tw + tipPadX * 2, th + tipPadY * 2
    local cx, cy = ScrW() / 2, ScrH() / 2
    surface.SetMaterial(textUndergroundMat)
    surface.SetDrawColor(255, 255, 255, 255)
    surface.DrawTexturedRect(cx - tipW / 2, cy - tipH / 2, tipW, tipH)
    draw.SimpleText(tipText, tipFont, cx, cy,
        Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

-- ====================================================================
-- 观战视角重新调度进度提示（2026-08-12）：观战视角（LocalView=nil——未进入牌桌
-- 的真观战者 / kards_view 观战者视角的参战者）下，以 ChatFont 悬浮字体显示重新
-- 调度进度（屏幕顶部居中，阴影保证可读性）：
--   双方都未完成           →「双方正在重新调度」
--   一方完成               →「「玩家名」正在重新调度」（显示仍在重新调度一方的
--                           玩家名；槽位玩家名经服务端 Kards_SlotName_<slot> NW
--                           同步，见 table_session.lua SyncSlotName）
-- 双方完成（KardsMulliganDone 广播置位双方完成标记）→ 隐藏；先手回合随后开始。
-- 数据源：真观战者用 KardsTableBattleStart 观战分支创建的 spectate.mulliganDone
-- （与参战者 mulliganDoneSlot 隔离，避免上一场残留）；kards_view 参战者用 inTable
-- 兜底（mulliganDoneSlot，对局开始已复位）。mulliganStarted 由首个重新调度发牌
-- 广播置位（KardsTableDeckDraw），错过发牌时由 KardsMulliganDone 兜底。
-- ====================================================================
hook.Add("HUDPaint", "KardsSpectateMulliganHUD", function()
    local BS = KARDS.BattleState
    -- 观战视角判定：本地视角为观察者（nil）才显示中性进度（槽位视角看本方等待提示
    -- KardsWaitingOpponentMulliganHUD，两者互斥）
    if not (KARDS.Perspective and KARDS.Perspective.LocalView == nil) then return end
    if not BS.mulliganStarted then return end
    -- 数据源：真观战者用 spectate（槽位完成标记），kards_view 参战者用 inTable 兜底
    local sp = BS.spectate
    local ent, d1, d2
    if sp and IsValid(sp.ent) then
        ent = sp.ent
        d1, d2 = sp.mulliganDone[1], sp.mulliganDone[2]
    elseif BS.inTable and IsValid(BS.inTable.ent) then
        ent = BS.inTable.ent
        d1, d2 = BS.mulliganDoneSlot[1], BS.mulliganDoneSlot[2]
    end
    if not IsValid(ent) then return end
    if d1 and d2 then return end -- 双方均完成 → 不显示
    local text
    if not d1 and not d2 then
        text = "双方正在重新调度"
    else
        local pendingSlot = d1 and 2 or 1
        local name = ent:GetNWString("Kards_SlotName_" .. pendingSlot, "")
        if name == "" then name = ("P%d"):format(pendingSlot) end -- 虚拟对手/未同步兜底
        text = ("「%s」正在重新调度"):format(name)
    end
    -- ChatFont 悬浮字体（屏幕顶部居中，阴影保证可读性）
    local font = "ChatFont"
    surface.SetFont(font)
    local cx, cy = ScrW() / 2, ScrH() * 0.14
    draw.SimpleText(text, font, cx + 1, cy + 1, Color(0, 0, 0, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    draw.SimpleText(text, font, cx, cy, Color(255, 255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
