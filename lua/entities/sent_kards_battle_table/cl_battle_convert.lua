--[[
    Kards 战斗牌桌客户端模块：卡牌转换交接动画（cl_battle_convert.lua，2026-09-26 缺口 J）

    数据层 SimConvert 以「转换目标卡」原地置换阵线中的卡牌后触发 UnitConvert 事件，实体层
    经 BroadcastUnitConvert 广播 KardsUnitConvert（牌桌实体 + 旧实体 + 新实体），本模块播
    「旧卡 z 上升 + 翻面至侧立 90° → 90° 处立即换显 → 新卡反向回落至平躺」，三方视角一致
    （服务端 net.Broadcast，模块内不做视角分支）。

    换显语义（用户 2026-09-26）：卡牌翻转到 90° 时立即把卡牌对象切为转换后对象，朝上的
    那一面由新卡承担，纹理槽本身不动；z 转而向下移动，视觉上像把卡牌翻一个面成为新卡牌。
    侧立 90° 时卡面与卡背均与视线平行（不可见），故换显瞬间不露切换痕迹；新卡回落时
    呈现的已是新卡正面。

    新卡卡面与单位文字在换显前完成准备（同部署半程切换：CloneUnit 改写 manifest →
    ClearCache 重建 renderable → PrefillUnitCrop 预填 UV 裁切材质 → AddLocal 绑定单位
    文字 3D2D），否则新实体首次 Draw 会白屏无纹理、无属性文字。

    挂载：cl_init.lua include 本文件（cl_battle_veteran.lua 之后）。
    依赖 cl_init.lua 末尾桥接导出（KARDS.AnimPlayer / BattleState）与
    KardsFieldLayout 接收器的转换守卫（AnimPlayer:Active(e, "unitConvert")，
    2026-10-03 联机排查 NEW-8 起改按动画组查询，原 active 标志表已移除）。
]]

KARDS = KARDS or {}

-- 动画常量（时长秒 / 距离世界单位）
local ConvertGroup = "unitConvert" -- 转换动画组名（守卫侧的查询键，改名需两处同改）
local RiseDur      = 0.3           -- 旧卡上升与翻面时长
local FallDur      = 0.3           -- 新卡回落时长
local LiftZ        = 1.5           -- z 上升量（防翻转穿模）

--[[
    准备新实体卡面材质与卡面文件（换显前调用）：CloneUnit 按目标卡安全名改写 manifest 的
    front/back 指向 data/kards_deck/<safeName>/，ClearCache 销毁旧 renderable 使实体按新
    manifest 重建，PrefillUnitCrop 预填 UV 裁切材质（避免换显瞬间白屏）。

    @param ent Entity 新战场单位实体（Kards_DeckModelID / Kards_DeckSafeName 已就绪）
]]
local function PrepareNewFace(ent)
    local modelID = ent:GetNWString("Kards_DeckModelID", "")
    local safeName = ent:GetNWString("Kards_DeckSafeName", "")
    if modelID == "" or safeName == "" then return end
    if not (KARDS.CardManifest and KARDS.CardManifest.CloneUnit) then return end
    KARDS.CardManifest.CloneUnit(modelID, "kards_deck/" .. safeName)
    if PMXStaticImporter and PMXStaticImporter.ClearCache then
        PMXStaticImporter.ClearCache(modelID)
        KARDS.PrefillUnitCrop(modelID)
    end
end

-- 转换交接接收（服务端 BroadcastUnitConvert）：牌桌 → 旧实体 → 新实体。
-- 仅关注桌消费；两个实体任一无效时退化为无动画（新实体 NW 与布局广播已到达，
-- 由常规布局驱动落到槽位）。
net.Receive("KardsUnitConvert", function()
    local tableEnt = net.ReadEntity()
    local oldEnt = net.ReadEntity()
    local newEnt = net.ReadEntity()
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    if not IsValid(oldEnt) or not IsValid(newEnt) then return end
    -- 新卡卡面与单位文字准备（换显前完成）
    PrepareNewFace(newEnt)
    if KARDS.CardTextOverlay then
        KARDS.CardTextOverlay:Remove(oldEnt) -- 旧卡文字随换显退场
        -- 3D2D 文字：单位模式（仅攻击/防御/行动花费），口径同部署半程切换
        -- 闪卡判定：由新卡身份取外观模板，供文字层配色（2026-10-04，见 EntryIsFlash）
        local newApp = (KARDS.DeckFindCardInfo and KARDS.GetCardIdentity)
            and KARDS.DeckFindCardInfo(KARDS.GetCardIdentity(newEnt)) or nil
        KARDS.CardTextOverlay:AddLocal(newEnt, {
            cost = 0,
            actionCost = newEnt:GetNWInt("Kards_CardActionCost", 0),
            attack = newEnt:GetNWInt("Kards_CardAttack", 0),
            defense = newEnt:GetNWInt("Kards_CardDefense", 0),
            cardTemplate = (newApp and newApp.cardTemplate) or "",
            _unitMode = true, -- DrawOverlay 据此跳过 cost/keywords/desc
            ownerSlot = newEnt:GetNWInt("Kards_DeckSlot", 1),
        }, 7.2, 8.528, 209, 290, false)
        KARDS.CardTextOverlay:SetBaseStat(newEnt, "attack", newEnt:GetNWInt("Kards_CardAttack", 0))
        KARDS.CardTextOverlay:SetBaseStat(newEnt, "defense", newEnt:GetNWInt("Kards_CardDefense", 0))
    end
    local cur = oldEnt:GetLocalPos()
    local ang = oldEnt:GetLocalAngles()
    local y, r = ang.y, ang.r
    local lifted = cur + Vector(0, 0, LiftZ)
    -- 阶段一（旧卡）：0.3 秒内 z 上升 + 翻面至侧立 90°，90° 处触发换显
    KARDS.AnimPlayer:Play(oldEnt, {
        { t = 0, pos = cur, ang = Angle(0, y, r) },
        { t = RiseDur, pos = lifted, ang = Angle(90, y, r), easing = "cos", event = "convertSwap" },
    }, {
        group = ConvertGroup,
        noQueue = true,
        onKeyframe = function(_, name)
            if name ~= "convertSwap" then return end
            if not IsValid(oldEnt) or not IsValid(newEnt) then return end
            -- 换显：此刻旧卡与新卡在侧立姿态完全重合，切换不可见
            oldEnt:SetNoDraw(true)
            newEnt:SetLocalPos(lifted)
            newEnt:SetLocalAngles(Angle(90, y, r))
            newEnt:SetNoDraw(false)
            -- 阶段二（新卡）：从侧立 90° 与升起高度反向回落至平躺，落回即新卡正面
            KARDS.AnimPlayer:Play(newEnt, {
                { t = 0, pos = lifted, ang = Angle(90, y, r) },
                { t = FallDur, pos = cur, ang = Angle(0, y, r), easing = "cos" },
            }, {
                group = ConvertGroup,
                noQueue = true,
            })
        end,
    })
end)