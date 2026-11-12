--[[
    Kards 战斗牌桌客户端模块：延时效果证明动画（cl_battle_delayed_proof.lua，2026-11-07）

    用户规格：延时效果（保持触发 keepTrigger / 跨刻等待 turn「等待」）在回合时间刻触发时，
    把该效果的「来源卡」从牌桌左边缘向右移入，带逆时针旋转与放大（z 抬升），0.8 秒后
    反向播放（回程无音效）；去程播放 sound/kards/hq_start.ogg。

    数据流：
      数据层 sh_node_hooks.lua 在触发延时效果前调用 KARDS.Battle:NotifyDelayedProof
      → 牌桌实体 ENT:BroadcastDelayedProof 只向来源卡归属玩家发送 KardsDelayedProof
      （载荷：牌桌实体 / 卡文件名 / 卡面安全标识 / 归属槽位）。
      只定向发归属玩家，与 KardsTableDrawFace 的卡面定向口径一致：不向对手泄露卡面。

    卡面副本：客户端本地创建 PMX 静态实体（不占服务端实体）。贴图链路顺序敏感
    （见 cl_init.lua 顶部说明）：卡面/卡背 PNG 落盘 → manifest → ClearCache →
    PrefillBackFlip，全部在实体首次 Draw 之前完成；随后绑定 3D2D 文字层
    （AddLocal，与 InitDrawCardFace 同款）。

    「放大」用透视缩放实现：起点沿「相机 → 卡」视线外推，卡在去程中随深度减小而投影
    变大，停留位置（第 0.8 秒）严格落在左槽，不调用 SetPMXScale（同 cl_init.lua
    StartHQReveal 的 BouncePos 手法）。

    挂载：cl_init.lua include 本文件（cl_battle_convert.lua 之后）。
]]

KARDS = KARDS or {}

local ProofGroup = "delayedProof" -- AnimPlayer 组名
local EntryDur  = 0.8             -- 去程时长（秒；用户指定 0.8 秒后反向）
local ExitDur   = 0.8             -- 回程时长（秒）
local OffZ      = -8              -- 起点相对展示槽的 z 降低量（仍在桌面之上）
local SpinYaw   = 50              -- 起点相对终点的逆时针偏转（yaw 增大 = 逆时针，终点归零）
local ZoomOut   = 1.2             -- 起点沿相机视线外推倍率（起点投影更小，移入时透视放大）

-- 取来源卡证明动画的姿态（牌桌局部坐标）
-- @param tableEnt table 牌桌实体
-- @param slot     number 来源卡归属槽位（1=P1 / 2=P2）
-- @return Vector 起点, Vector 放大位, Angle 终点角度, Angle 起点角度
local function ProofPoses(tableEnt, slot)
    local slotIdx = KARDS.CrossSlotFor(slot, "left")
    local slotPos = (KARDS.DisplaySlots[slotIdx] and KARDS.DisplaySlots[slotIdx].pos)
        or Vector(14, 0, 40)
    -- 起点在「归属方视角左侧」展示槽再向外偏移，即牌桌左边缘之外
    local xSign = (slotIdx == KARDS.P1LP2RSlot) and 1 or -1
    local startPos = slotPos + Vector(xSign * (KARDS.ExitFlyDist or 64), 0, OffZ)
    -- 起点再沿「相机 → 卡」视线外推（投影更小，移入过程即透视放大）；
    -- 终点严格落在左槽（停留展示位置 = 展示槽），不做任何偏置
    local camPos = (KARDS.BattleCamera and KARDS.BattleCamera.ViewPos) or EyePos()
    if camPos then
        local startWorld = tableEnt:LocalToWorld(startPos)
        startPos = tableEnt:WorldToLocal(camPos + (startWorld - camPos) * ZoomOut)
    end
    -- 文字朝向：P1 视角 yaw 180 / P2 视角 yaw 0（卡面正对本人）
    local baseYaw = (slot == 1) and 180 or 0
    return startPos, slotPos, Angle(0, baseYaw, 0), Angle(0, baseYaw - SpinYaw, 0)
end

-- 创建来源卡证明副本（客户端本地 PMX 实体 + 3D2D 文字层）
-- @param cardName string 卡文件名（DeckFindCardInfo 查外观数据）
-- @param safeName string 卡面安全标识（data/kards_deck/<safeName>/）
-- @return Entity|nil 副本实体
local function CreateProofCopy(cardName, safeName)
    if not cardName or cardName == "" or not safeName or safeName == "" then return nil end
    if not (KARDS.CardManifest and KARDS.DeckFindCardInfo) then return nil end
    local appearance, texturePath, textureSize = KARDS.DeckFindCardInfo(cardName)
    if not appearance then return nil end
    -- 卡面/卡背文件兜底（对手客户端未初始化过该卡卡面时从保存文件模板复制）；
    -- 文件必须先于实体首次 Draw 落盘，否则本会话该材质白屏
    local dir = "kards_deck/" .. safeName
    if not file.Exists(dir .. "/front.png", "DATA") or not file.Exists(dir .. "/back.png", "DATA") then
        KARDS.CardManifest.WriteDeckCardImages(safeName,
            texturePath and texturePath.template or nil, appearance.country)
    end
    -- 独立 modelID（不与卡组/手牌/抽牌临时卡共用 manifest，避免 image_path 互相覆盖）
    local modelID = "kards_proof_" .. safeName
    KARDS.CardManifest.EnsureDeck(modelID, safeName)
    if PMXStaticImporter and PMXStaticImporter.ClearCache then
        PMXStaticImporter.ClearCache(modelID)
        KARDS.PrefillBackFlip(modelID)
    end
    local copy = ents.CreateClientside("sent_pmx_static_imported")
    if not IsValid(copy) then return nil end
    copy:Spawn()
    if not copy.SetPMXModelID then
        copy:Remove()
        return nil
    end
    copy:SetPMXModelID(modelID)
    copy:SetPMXScale(KARDS.BattleRender.Defaults.CardScale)
    -- 客户端实体 SetupDataTables 的 SERVER 分支不执行，PMXColor 缺省为黑，须显式置白
    copy:SetPMXColor(Vector(1, 1, 1))
    -- 无碰撞无物理（同原卡）
    copy:SetSolid(SOLID_NONE)
    local phys = copy:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    -- 3D2D 文字层（外观表实时读取，与编辑器预览/手牌卡面一致）
    if appearance and KARDS.CardTextOverlay then
        local texW, texH = 300, 400
        if textureSize and textureSize.w and textureSize.h then
            texW, texH = textureSize.w, textureSize.h
        end
        KARDS.CardTextOverlay:AddLocal(copy, appearance, 7.2, 10.8, texW, texH, true)
    end
    return copy
end

-- 播放来源卡证明动画：去程移入 + 逆时针 + 透视放大，0.8 秒后原路反向，结束销毁副本
-- @param tableEnt table 牌桌实体
-- @param cardName string 卡文件名
-- @param safeName string 卡面安全标识
-- @param slot     number 来源卡归属槽位
local function PlayDelayedProof(tableEnt, cardName, safeName, slot)
    local copy = CreateProofCopy(cardName, safeName)
    if not IsValid(copy) then return end
    copy:SetParent(tableEnt)
    local startPos, nearPos, nearAng, startAng = ProofPoses(tableEnt, slot)
    copy:SetLocalPos(startPos)
    copy:SetLocalAngles(startAng)
    KARDS.AnimPlayer:Play(copy, {
        { t = 0, pos = startPos, ang = startAng },
        { t = EntryDur, pos = nearPos, ang = nearAng, easing = "easeOut" },
        { t = EntryDur + ExitDur, pos = startPos, ang = startAng, easing = "smooth" },
    }, {
        group = ProofGroup,
        noQueue = true, -- 同帧多个延时效果各自独立播放（用户明确不考虑重叠）
        onStart = function()
            -- 仅去程播放音效；回程无声
            if KARDS.PlayKardsSound then KARDS.PlayKardsSound("hq_start") end
        end,
        onComplete = function()
            if KARDS.CardTextOverlay then KARDS.CardTextOverlay:Remove(copy) end
            if IsValid(copy) then copy:Remove() end
        end,
    })
end

-- 延时效果证明接收（服务端 ENT:BroadcastDelayedProof 定向发送来源卡归属玩家）
net.Receive("KardsDelayedProof", function()
    local tableEnt = net.ReadEntity()
    local cardName = net.ReadString()
    local safeName = net.ReadString()
    local slot = net.ReadUInt(8)
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    PlayDelayedProof(tableEnt, cardName, safeName, (slot == 2) and 2 or 1)
end)
