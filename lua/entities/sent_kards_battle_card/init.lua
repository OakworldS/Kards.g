-- Kards 战斗卡牌实体服务端代码
-- 固定应用前置模组导入的 basic_card 模型（卡牌）：
-- 模型经导入器转轴后为 z-up 平躺几何（manifest bounds 36x54x0.45，
-- axis_preset "x,-z,y"：卡面宽沿 x、卡面长沿 y、厚度沿 z），实体角度 (0,y,0)
-- 时卡牌即平躺面朝上，无需轴修正；生成时直接应用玩家朝向角度即可。
-- 卡牌为可动的轻质薄箱体（可被物理枪抓取/投掷/推动）。

AddCSLuaFile("shared.lua")
include("shared.lua")

-- 网络消息：外观编辑器「生成」按钮请求生成卡牌实体（客户端已预填材质缓存）
-- 服务端负责生成实体，并替换该玩家上一次生成的预览卡牌；
-- 生成后回传实体（KARDS_Editor_SpawnCardResult），供客户端绑定 3D2D 文字叠加（cl_card_text_overlay.lua）
-- realm 门控（2026-08-18 规划 D11）：AddNetworkString/net.Receive 仅服务端注册
if SERVER then
    util.AddNetworkString("KARDS_Editor_SpawnCard")
    util.AddNetworkString("KARDS_Editor_SpawnCardResult")
    local PreviewEntities = {}
    net.Receive("KARDS_Editor_SpawnCard", function(_, ply)
        local pos = net.ReadVector()
        local ang = net.ReadAngle()

        local old = PreviewEntities[ply]
        if IsValid(old) then
            old:Remove()
            PreviewEntities[ply] = nil
        end

        local ent = ents.Create("sent_kards_battle_card")
        if not IsValid(ent) then return end
        ent:SetPos(pos)
        -- basic_card 为 z-up 平躺模型（卡面宽 x 36 / 长 y 54 / 厚 z 0.45），
        -- 直接应用玩家朝向角度即平躺面朝上；几何中心为原点（manifest bounds 中心 (0,0,0)）
        ent:SetAngles(ang)
        ent:Spawn()
        PreviewEntities[ply] = ent

        -- 回传实体给请求玩家（3D2D 文字卡生成需要实体引用绑定本地属性数据）
        -- 注意：net.WriteEntity 内部按 MAX_EDICT_BITS（≈11 位）写入实体索引，
        -- 客户端若用 net.ReadInt(16) 读取会位宽错位（16 位读取只覆盖 11 位有效数据，
        -- 读得 0/错值，导致 Entity(idx) 永远无效、绑定失败），
        -- 故此处显式用 net.WriteInt 以固定 16 位写入索引，客户端 net.ReadInt(16) 精确读取
        net.Start("KARDS_Editor_SpawnCardResult")
        net.WriteInt(ent:EntIndex(), 16)
        net.Send(ply)
    end)
end

-- 固定应用的模型与缩放（basic_card 为 z-up 平躺，原始 36x54x0.45 单位，×0.2 后
-- 世界卡面 7.2x10.8x0.09，卡牌平躺面朝上，无需轴修正）
ENT.KardsModelID = "basic_card"
ENT.KardsScale = 0.2

function ENT:Initialize()
    self.BaseClass.Initialize(self)
    local ok, err = self:ApplyImportedModel(self.KardsModelID, self.KardsScale)
    if not ok then
        ErrorNoHalt("[Kards] 卡牌实体生成失败: " .. tostring(err) .. "\n")
        self:Remove()
        return
    end
    -- 模型为 z-up 平躺原始几何，生成时直接应用玩家朝向角度（无需轴修正）
    -- 卡牌可动（ApplyImportedModel 内部会冻结运动，这里重新启用）：
    -- 轻质薄箱体，可被物理枪抓取/投掷/推动
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableMotion(true)
        phys:SetMass(1)
        phys:SetDamping(0.5, 0.5)
    end
end
