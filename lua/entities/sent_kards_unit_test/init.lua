-- basic_card_unit 模型检查测试实体（服务端）
AddCSLuaFile("shared.lua")
include("shared.lua")

-- 生成子实体：服务端创建 sent_pmx_static_imported + ApplyImportedModel 应用模型，
-- 客户端实体类自动同步渲染（与手牌/战场卡同一渲染链路）
function ENT:Initialize()
    if not PMXStaticImporter or not PMXStaticImporter.NormalizeModelID then
        print("[Kards] unit 测试实体：PMXStaticImporter 未加载")
        return
    end
    local sub = ents.Create("sent_pmx_static_imported")
    if not IsValid(sub) then
        print("[Kards] unit 测试实体：sent_pmx_static_imported 创建失败")
        return
    end
    sub:SetPos(self:GetPos())
    sub:SetAngles(self:GetAngles())
    sub:Spawn()
    -- 测试缩放 0.5（世界尺寸约 60×71），便于观察模型 UV 裁切与几何
    local ok, err = sub:ApplyImportedModel("basic_card_unit", 0.5)
    print(("[Kards] unit 测试实体模型应用: ok=%s err=%s"):format(tostring(ok), tostring(err)))
    sub:SetSolid(SOLID_NONE)
    local phys = sub:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    sub:SetParent(self)
    sub:SetLocalPos(Vector(0, 0, 0))
    sub:SetLocalAngles(Angle(0, 0, 0))
    self._kardsUnitSub = sub
end

function ENT:OnRemove()
    if IsValid(self._kardsUnitSub) then
        self._kardsUnitSub:Remove()
    end
end
