--[[
    Kards 战斗牌桌客户端模块：抉择演出（cl_battle_choice.lua，2026-10-04）

    职责：为「抉择」效果节点（choice 模板）提供二选一演出与选择交互。协议见
    init.lua 的 KardsChoice* 网络字符串注册与服务端 table_choice.lua。

    演出（打出方 + 观战者，敌方不收 Offer）：
      1. 收到 KardsChoiceOffer：抉择卡（真实服务端实体，此刻仍登记为该槽手牌）从
         当前位置飞到中槽（KARDS.PickSlotPos(2, viewSlot)，组 "choiceDeal"）。
      2. 到达中槽后同时：客户端本地复制一张（z 略低于原卡 ChoiceCopyZ），原卡效果
         3D2D 文本覆盖为 T1、复制卡为 T2，二者分列中左/中右槽（组 "choiceSplit"）。
         观战视角两张卡 pitch 45° 朝打出方倾斜（KARDS.PickSpecAngle，与三选一观战
         同款）；本方视角卡面朝上正对。
      3. 打出方鼠标悬停抬升 + 左键选中 → KardsChoiceChoose 提交序号。
      4. 收到 KardsChoiceResult：选中卡移到中槽成为后续动画主体，另一张 xy 平面
         逆时针出场（同三选一 PlayDevelopExit 关键帧）；主体必须收敛回真实服务端
         实体——若选中项为复制卡，则在移动完成时把原卡瞬移到复制卡终态、销毁复制卡，
         使后续「打出」动画（KardsCardPlayed → PlayCommandExitAnim）作用在真实实体上。

    可见性（用户规格）：
      - 敌方演出期间完全看不到该卡：服务端发 KardsChoiceHide → 本端立即 SetNoDraw(true)
        并把它移出 realHandCards（否则每帧手牌朝向兜底会把它重新显示），结算时解除。
      - 观战者可看到演出，故服务端同时定向补发卡面（KardsTableDrawFace）。

    文本样式（用户规格「代码内部用变量选择打出卡效果文字样式」）：
      - 打出方：演出后卡面自然只表述所选 T（延伸卡只有 T）。
      - 观战者：默认跟随打出方（仅所选 T），由 BattleChoice.SpectateShowFullText 切换。
      - 敌方：默认原封不动（完整「抉择：T1 或 T2」），由 BattleChoice.EnemyShowFullText 切换。

    挂载：cl_init.lua include 本文件（cl_battle_pick.lua 之后）。
]]

if not CLIENT then return end

KARDS = KARDS or {}

-- 打出后卡面效果文本样式（代码内变量，用户规格「代码内部用变量选择…」）
KARDS.BattleChoice = KARDS.BattleChoice or {
    EnemyShowFullText = true,     -- 敌方卡面：true = 原封不动（完整「抉择：T1 或 T2」）；
                                  --           false = 仅表述所选 T
    SpectateShowFullText = false, -- 观战者卡面：false = 跟随打出方（仅所选 T）
}

-- 抉择演出状态（跨 Think 钩子共享）
KARDS.BattleChoiceState = KARDS.BattleChoiceState or {
    active     = false, -- 演出进行中（收到 Offer 起、Result 清理完止）
    view       = nil,   -- 视角 "self" | "spectate"（敌方不收 Offer，仅 Hide）
    viewSlot   = nil,   -- 视角槽位（左右镜像基准）
    slot       = nil,   -- 发起槽位（1/2）
    tableEnt   = nil,   -- 发起牌桌实体
    orig       = nil,   -- 原卡（真实服务端实体，对应效果一 T1）
    copy       = nil,   -- 复制卡（客户端本地实体，对应效果二 T2）
    t1         = "",    -- 效果一文本
    t2         = "",    -- 效果二文本
    slots      = {},    -- { [1] = { ent, pos }, [2] = { ent, pos } }（中左/中右槽位与实体）
    selectable = false, -- 第一段动画播完后置 true（本方此时可点击选择）
    submitted  = false, -- 已提交选择
    finishing  = false, -- 已收到结果，第二段动画进行中/待清理
    prevLeft   = false, -- 左键上一帧状态（上升沿判定）
    hidden     = {},    -- 敌方被隐藏的实体（演出期间每帧兜底 SetNoDraw(true)）
    extraClone = nil,   -- 追加的本地卡（原卡需收敛为主体时，用同款本地卡承接其形象做出场）
    pendingSwap = false,-- 待主体交接（选中复制卡：真实实体需收敛为主体）
    swapAt     = nil,   -- 主体交接时刻（CurTime）
    chosenText = "",    -- 所选 T 文本（交接与结算写卡面文本用）
}

local BC = KARDS.BattleChoiceState

-- 演出时长/偏移（秒 / 世界单位）
local ChoiceToCenterDur = 0.35 -- 当前位置 → 中槽
local ChoiceSplitDur    = 0.35 -- 中槽 → 中左/中右
local ChoiceResultDur   = 0.35 -- 选中卡 → 中槽（主体位）
local ChoiceCopyZ       = 0.3  -- 复制卡相对原卡的 z 下移（「z 微微低于原卡」）

-- 视角左侧 x 符号 / 发起方所在一侧 y 符号（与三选一 cl_battle_pick.lua 同式）
local function LeftSign(viewSlot)
    return (viewSlot == 2) and -1 or 1
end

local function SideSign(slot)
    return (slot == 1) and 1 or -1
end

-- 卡面朝向：本方/正常演出 = 卡面朝上正对各自玩家（P1 槽 180 / P2 槽 0）
local function MainAngle(slot)
    return Angle(0, (slot == 1) and 180 or 0, 0)
end

-- 观战视角朝向：绕俯仰轴 pitch 45° 朝打出抉择的玩家倾斜（用户规格；同三选一观战先例
-- KARDS.PickSpecAngle，见 cl_battle_pick.lua 观战分支）
local function ViewAngle(slot, view)
    if view == "spectate" then
        return Angle(KARDS.PickSpecAngle or 45, (slot == 1) and 180 or 0, 0)
    end
    return MainAngle(slot)
end

-- 创建复制卡（客户端本地实体，天然仅本客户端可见）：复制原卡 modelID（手牌卡面已由
-- manifest 改写为真实卡面，同 modelID 直接 SetPMXModelID 即显示卡面）+ 绑定 3D2D 文字
-- （与源卡同一本地外观表 AddLocal；文本由 CardTextOverlay:SetTextOverride 覆盖）。
-- 父级 = 原卡父级（牌桌），使动画与源卡同用牌桌局部坐标（AnimPlayer 实体分支写局部坐标）
local function CreateChoiceCopy(src)
    if not IsValid(src) then return nil end
    local copy = ents.CreateClientside("sent_pmx_static_imported")
    if not IsValid(copy) then return nil end
    local parent = src:GetParent()
    if IsValid(parent) then copy:SetParent(parent) end
    copy:SetLocalPos(src:GetLocalPos())
    copy:SetLocalAngles(src:GetLocalAngles())
    copy:Spawn()
    local modelID = src:GetNWString("Kards_DeckModelID", "")
    if modelID == "" or not copy.SetPMXModelID then
        copy:Remove()
        return nil
    end
    copy:SetPMXModelID(modelID)
    copy:SetPMXScale(KARDS.BattleRender.Defaults.CardScale)
    -- 客户端实体 SetupDataTables 的 SERVER 分支不执行（PMXColor 缺省 Vector(0,0,0)），
    -- 需显式置白，避免复制卡渲染变黑（同悬停复制卡 HoverPreviewCreate）
    copy:SetPMXColor(Vector(1, 1, 1))
    copy:SetSolid(SOLID_NONE)
    local phys = copy:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    local appearance, _, textureSize = KARDS.DeckFindCardInfo(KARDS.GetCardIdentity(src))
    if appearance and KARDS.CardTextOverlay then
        local texW, texH = 300, 400
        if textureSize and textureSize.w and textureSize.h then
            texW, texH = textureSize.w, textureSize.h
        end
        KARDS.CardTextOverlay:AddLocal(copy, appearance, 7.2, 10.8, texW, texH)
    end
    return copy
end

-- 销毁复制卡（含 3D2D 文字叠加与文本覆盖）
local function DestroyChoiceCopy()
    local copy = BC.copy
    BC.copy = nil
    if not IsValid(copy) then return end
    if KARDS.CardTextOverlay then
        KARDS.CardTextOverlay:ClearTextOverride(copy)
        KARDS.CardTextOverlay:Remove(copy)
    end
    copy:Remove()
end

-- 销毁悬停/出场用的临时本地卡（BC.extraClone：真实实体需收敛为主体时，用同款本地卡
-- 承接原卡可见形象去做「另一张逆时针出场」）
local function DestroyChoiceClone()
    local e = BC.extraClone
    BC.extraClone = nil
    if not IsValid(e) then return end
    if KARDS.CardTextOverlay then
        KARDS.CardTextOverlay:ClearTextOverride(e)
        KARDS.CardTextOverlay:Remove(e)
    end
    e:Remove()
end

-- 主体交接：选中「效果二」时，把真实实体（BC.orig）瞬移到复制卡终态、文本覆盖为所选 T
-- 并显形，随后销毁复制卡——使后续「打出」动画（KardsCardPlayed）作用在真实实体上。
-- 幂等：pendingSwap 置 false 后重复调用无副作用。
local function PerformChoiceSwap()
    BC.pendingSwap = false
    if not IsValid(BC.orig) or not IsValid(BC.copy) then return end
    local p = BC.copy:GetLocalPos()
    local a = BC.copy:GetLocalAngles()
    if KARDS.CardTextOverlay and BC.chosenText ~= "" then
        KARDS.CardTextOverlay:SetTextOverride(BC.orig, BC.chosenText)
    end
    BC.orig:SetLocalPos(p)
    BC.orig:SetLocalAngles(a)
    BC.orig:SetNoDraw(false)
    DestroyChoiceCopy()
end

-- 清空抉择演出（退出牌桌 / 对局结束 / 第二段动画播完）
function KARDS.BattleChoiceReset()
    BC.active = false
    BC.view = nil
    BC.viewSlot = nil
    BC.slot = nil
    BC.tableEnt = nil
    BC.t1 = ""
    BC.t2 = ""
    BC.chosenText = ""
    BC.slots = {}
    BC.selectable = false
    BC.submitted = false
    BC.finishing = false
    BC.prevLeft = false
    -- 主体交接未完成（异常路径）：把真实实体显形，避免打出的卡永久不可见
    if BC.pendingSwap and IsValid(BC.orig) then
        BC.orig:SetNoDraw(false)
    end
    BC.pendingSwap = false
    BC.swapAt = nil
    -- 敌方隐藏实体的兜底解除（正常路径已在 KardsChoiceResult 解除）
    for e in pairs(BC.hidden) do
        if IsValid(e) then
            e:SetNoDraw(false)
        end
    end
    BC.hidden = {}
    -- 注意：原卡（BC.orig）的文本覆盖不清除——结算后该卡作为已打出的抉择卡继续显示
    -- 所选 T（用户规格「打出者的…自然只有T」）；覆盖表为弱键表，实体销毁后自动回收。
    BC.orig = nil
    DestroyChoiceClone()
    DestroyChoiceCopy()
end

-- 把实体移出本槽手牌登记（演出期间两张效果卡不再由每帧手牌朝向驱动；结算时
-- KardsCardPlayed 接收器本就会注销该登记）
local function DetachFromHand(ent, slot)
    local map = KARDS.BattleState.realHandCards and KARDS.BattleState.realHandCards[slot]
    if map and IsValid(ent) then map[ent] = nil end
end

-- 射线命中两张效果卡之一（同三选一 HitPickCard：阈值 10^2）
local function HitChoiceCard()
    local ply = LocalPlayer()
    if not IsValid(ply) then return nil end
    local pos = KARDS.BattleCamera and KARDS.BattleCamera.ViewPos or ply:EyePos()
    local dir = gui.ScreenToVector(gui.MouseX(), gui.MouseY())
    if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then return nil end
    local bestEnt, bestD = nil, 100
    for i = 1, 2 do
        local item = BC.slots[i]
        local e = item and item.ent
        if IsValid(e) then
            local d = KARDS.RayPointDistSqr(pos, dir, e:GetPos())
            if d < bestD then bestEnt, bestD = e, d end
        end
    end
    return bestEnt
end

-- ====================================================================
-- 第一 / 第二段：演出开始
-- ====================================================================
net.Receive("KardsChoiceOffer", function()
    local tableEnt = net.ReadEntity()
    local slot = net.ReadUInt(2)
    local cardEnt = net.ReadEntity()
    local t1 = net.ReadString()
    local t2 = net.ReadString()
    if slot ~= 1 and slot ~= 2 then return end
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    if not IsValid(cardEnt) then return end
    -- 视角三分（敌方不收 Offer，此处作防御）
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
    KARDS.BattleChoiceReset()
    BC.active = true
    BC.view = view
    BC.viewSlot = (KARDS.Perspective and KARDS.Perspective.LocalView) or slot
    BC.slot = slot
    BC.tableEnt = tableEnt
    BC.orig = cardEnt
    BC.t1 = t1
    BC.t2 = t2
    -- 卡面（观战者由服务端定向补发 KardsTableDrawFace → cardFaces 就绪；本方本就已初始化，
    -- InitDrawCardFace 幂等且卡名缺失时内部早退保持卡背）
    if KARDS.InitDrawCardFace then
        KARDS.InitDrawCardFace(cardEnt)
        KARDS.drawFacePending[cardEnt] = true
    end
    cardEnt:SetNoDraw(false)
    -- 演出期间该卡由本模块驱动：移出手牌登记，避免每帧手牌朝向把卡拉回扇形位
    DetachFromHand(cardEnt, slot)
    -- 文本覆盖：原卡 = 效果一
    if KARDS.CardTextOverlay then KARDS.CardTextOverlay:SetTextOverride(cardEnt, t1) end
    local viewSlot = BC.viewSlot
    local centerPos = KARDS.PickSlotPos(2, viewSlot)
    local leftPos = KARDS.PickSlotPos(1, viewSlot)
    local rightPos = KARDS.PickSlotPos(3, viewSlot)
    local ang = ViewAngle(slot, view)
    local copyAng = ViewAngle(slot, view)
    -- 第一段：当前位置 → 中槽
    KARDS.AnimPlayer:Play(cardEnt, {
        { t = 0 },
        { t = ChoiceToCenterDur, pos = centerPos, ang = ang, easing = "cos" },
    }, {
        group = "choiceDeal",
        onStart = function() KARDS.PlayKardsSound("draw") end,
        onComplete = function()
            if not BC.active or BC.orig ~= cardEnt then return end
            -- 复制卡（z 略低于原卡）并同时移到中左 / 中右
            local copy = CreateChoiceCopy(cardEnt)
            if IsValid(copy) then
                BC.copy = copy
                if KARDS.CardTextOverlay then KARDS.CardTextOverlay:SetTextOverride(copy, t2) end
                local copyStart = Vector(centerPos.x, centerPos.y, centerPos.z - ChoiceCopyZ)
                copy:SetLocalPos(copyStart)
                copy:SetLocalAngles(copyAng)
                KARDS.AnimPlayer:Play(copy, {
                    { t = 0, pos = copyStart, ang = copyAng },
                    { t = ChoiceSplitDur, pos = rightPos, ang = copyAng, easing = "cos" },
                }, { group = "choiceSplit" })
            end
            KARDS.AnimPlayer:Play(cardEnt, {
                { t = 0, pos = centerPos, ang = ang },
                { t = ChoiceSplitDur, pos = leftPos, ang = ang, easing = "cos" },
            }, { group = "choiceSplit" })
            BC.slots = {
                [1] = { ent = cardEnt, pos = leftPos, ang = ang },
                [2] = { ent = copy, pos = rightPos, ang = copyAng },
            }
        end,
    })
    KARDS.UpdateTableMouse()
end)

-- ====================================================================
-- 敌方：演出期间隐藏该卡（结算时由 KardsChoiceResult 解除）
-- ====================================================================
net.Receive("KardsChoiceHide", function()
    local tableEnt = net.ReadEntity()
    local cardEnt = net.ReadEntity()
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    if not IsValid(cardEnt) then return end
    -- 仅敌方路径：本方/观战者收到 Offer 后自行驱动该卡
    if BC.active and BC.orig == cardEnt then return end
    cardEnt:SetNoDraw(true)
    BC.hidden[cardEnt] = true
    -- 移出手牌登记：否则每帧手牌朝向兜底（RealHandFacingCard）会 SetNoDraw(false) 复活该卡
    local slot
    for s = 1, 2 do
        local map = KARDS.BattleState.realHandCards and KARDS.BattleState.realHandCards[s]
        if map and map[cardEnt] then slot = s break end
    end
    if slot then DetachFromHand(cardEnt, slot) end
end)

-- ====================================================================
-- 第二段：结算（选中卡成为主体，另一张逆时针出场）
-- ====================================================================
net.Receive("KardsChoiceResult", function()
    local tableEnt = net.ReadEntity()
    local slot = net.ReadUInt(2)
    local index = net.ReadUInt(2)
    local chosenText = net.ReadString()
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    index = (index == 2) and 2 or 1
    -- 敌方：解除隐藏 + 按变量决定文本样式（默认原封不动 = 完整「抉择：T1 或 T2」）
    for e in pairs(BC.hidden) do
        if IsValid(e) then
            e:SetNoDraw(false)
            local cfg = KARDS.BattleChoice
            if cfg and cfg.EnemyShowFullText == false and KARDS.CardTextOverlay then
                KARDS.CardTextOverlay:SetTextOverride(e, chosenText)
            end
        end
    end
    BC.hidden = {}
    if not BC.active then
        -- 敌方分支（无演出状态）：解除后即结束
        return
    end
    if BC.slot ~= slot or BC.finishing then return end
    BC.finishing = true
    BC.selectable = false
    local viewSlot = BC.viewSlot or slot
    local leftSign = LeftSign(viewSlot)
    local sideSign = SideSign(slot)
    local centerPos = KARDS.PickSlotPos(2, viewSlot)
    local exitFly = KARDS.PickExitDist or 0
    local exitDropZ = KARDS.PickSpinDropZ or 0
    -- 观战者：文本样式由变量决定（默认跟随打出方 = 仅所选 T）
    if BC.view == "spectate" and KARDS.CardTextOverlay then
        local cfg = KARDS.BattleChoice
        if cfg and cfg.SpectateShowFullText == true then
            KARDS.CardTextOverlay:ClearTextOverride(BC.orig)
        else
            KARDS.CardTextOverlay:SetTextOverride(BC.orig, chosenText)
        end
    end
    -- 主体 / 出场者（主体必须收敛回真实服务端实体 BC.orig：后续 KardsCardPlayed 的
    -- 指令出场动画只作用于真实实体）：
    --   选中效果一（原卡）→ 原卡为主体；复制卡（T2）逆时针出场
    --   选中效果二（复制卡）→ 复制卡先为主体；原卡的真实实体隐身待交接，另用同款本地卡
    --     承接其可见形象（T1）逆时针出场
    local indexItem, otherItem = BC.slots[index], BC.slots[3 - index]
    local mainEnt = indexItem and indexItem.ent
    local exitEnt, exitBasePos, exitIsCopy, exitIsExtra
    if index == 1 then
        exitEnt = otherItem and otherItem.ent
        exitBasePos = otherItem and otherItem.pos or centerPos
        exitIsCopy = true
    else
        if IsValid(BC.copy) then
            mainEnt = BC.copy
            -- 原卡承接形象：同款本地卡（同 modelID / 同外观表，文本覆盖为 T1）
            exitEnt = CreateChoiceCopy(BC.orig)
            if IsValid(exitEnt) then
                exitEnt:SetLocalPos(BC.orig:GetLocalPos())
                exitEnt:SetLocalAngles(BC.orig:GetLocalAngles())
                if KARDS.CardTextOverlay then
                    KARDS.CardTextOverlay:SetTextOverride(exitEnt, BC.t1)
                end
                BC.extraClone = exitEnt
                exitIsExtra = true
                exitBasePos = BC.orig:GetLocalPos()
                -- 真实实体隐身（交接时再出现在中槽）；承接卡就绪后才隐，避免主体空缺
                BC.orig:SetNoDraw(true)
            end
        else
            mainEnt = BC.orig
        end
    end
    if not IsValid(mainEnt) then mainEnt = BC.orig end
    -- 主体 → 中槽
    if IsValid(mainEnt) then
        KARDS.AnimPlayer:Play(mainEnt, {
            { t = 0, pos = mainEnt:GetLocalPos(), ang = mainEnt:GetLocalAngles() },
            { t = ChoiceResultDur, pos = centerPos, ang = MainAngle(slot), easing = "cos" },
        }, { group = "choiceResult" })
    end
    -- 另一张：xy 平面逆时针出场 + z 下降 + 移出（同三选一 PlayDevelopExit 关键帧）
    if IsValid(exitEnt) then
        local basePos = exitBasePos or centerPos
        local yaw = exitEnt:GetLocalAngles().y
        local exitPos = basePos + Vector(leftSign * exitFly, sideSign * exitFly, -exitDropZ)
        KARDS.AnimPlayer:Play(exitEnt, {
            { t = 0, pos = basePos, ang = Angle(0, yaw, 0) },
            { t = KARDS.PickSpinDur, pos = exitPos,
              ang = Angle(0, yaw - leftSign * KARDS.PickSpinYaw, 0) },
        }, {
            group = "choiceResult",
            onComplete = function(target)
                if not IsValid(target) then return end
                target:SetNoDraw(true)
                if exitIsCopy and target == BC.copy then
                    DestroyChoiceCopy()
                elseif exitIsExtra and target == BC.extraClone then
                    DestroyChoiceClone()
                end
            end,
        })
    end
    if index == 1 and KARDS.CardTextOverlay then
        -- 打出方：延伸卡只有所选 T（自然只表述 T）
        KARDS.CardTextOverlay:SetTextOverride(BC.orig, chosenText)
    end
    -- 主体交接（选中复制卡时）：由 Think 按 swapAt 时刻执行（见 PerformChoiceSwap）——
    -- 不用动画 onComplete：KardsCardPlayed 的指令出场动画会在同一目标上「原位替换」
    -- 主体动画，onComplete 可能不触发
    BC.pendingSwap = (index == 2) and IsValid(BC.copy) or false
    BC.swapAt = CurTime() + ChoiceResultDur
    BC.chosenText = chosenText
    KARDS.UpdateTableMouse()
end)

-- ====================================================================
-- 每帧：状态校验 / 第二段收尾 / 悬停抬升 + 左键选择（仅打出方）
-- ====================================================================
hook.Add("Think", "KardsBattleChoiceUpdate", function()
    -- 敌方隐藏兜底：每帧重申，防被其它显隐逻辑复活
    for e in pairs(BC.hidden) do
        if not IsValid(e) then
            BC.hidden[e] = nil
        elseif not e:GetNoDraw() then
            e:SetNoDraw(true)
        end
    end
    if not BC.active then return end
    -- 牌桌失效（退出牌桌 / 销毁）→ 直接清理
    if not IsValid(BC.tableEnt) or not IsValid(BC.orig)
        or not KARDS.BattleState:IsLocalTable(BC.tableEnt) then
        KARDS.BattleChoiceReset()
        return
    end
    -- 第一段（含分裂）播完 → 允许选择
    if not BC.selectable and not BC.finishing and not BC.submitted
        and not KARDS.AnimPlayer:Any("choiceDeal") and not KARDS.AnimPlayer:Any("choiceSplit") then
        BC.selectable = true
    end
    if BC.finishing then
        -- 主体交接（选中复制卡）：按时刻推进，与动画是否被指令出场动画替换无关
        if BC.pendingSwap and CurTime() >= (BC.swapAt or 0) then
            PerformChoiceSwap()
        end
        if not BC.pendingSwap and not KARDS.AnimPlayer:Any("choiceResult") then
            KARDS.BattleChoiceReset()
        end
        return
    end
    -- 悬停抬升 + 左键选择粒度与三选一一致（kards 牌桌内鼠标恒呼出）
    KARDS.UpdateTableMouse()
    if not BC.selectable or BC.submitted or BC.view ~= "self" then
        BC.prevLeft = false
        return
    end
    local hover = HitChoiceCard()
    for i = 1, 2 do
        local item = BC.slots[i]
        local e = item and item.ent
        if IsValid(e) and item.pos then
            local lift = (e == hover) and (KARDS.PickHoverLift or 0) or 0
            local cur = e:GetLocalPos()
            local targetZ = item.pos.z + lift
            if math.abs(cur.z - targetZ) > 0.01 then
                e:SetLocalPos(Vector(item.pos.x, item.pos.y, targetZ))
            end
        end
    end
    local left = input.IsMouseDown(MOUSE_LEFT)
    if left and not BC.prevLeft and hover and BC.slots[1] then
        local idx = (hover == BC.slots[1].ent) and 1 or 2
        net.Start("KardsChoiceChoose")
            net.WriteEntity(BC.tableEnt)
            net.WriteUInt(idx, 2)
        net.SendToServer()
        BC.submitted = true
    end
    BC.prevLeft = left
end)