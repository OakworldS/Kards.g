-- Kards 卡牌编辑器卡牌实体共享代码
-- 共享文件，定义实体的基础属性和方法

ENT.Base = "base_gmodentity"
ENT.Type = "anim"
ENT.PrintName = "Kards Card"
ENT.Author = "Kards Team"
ENT.Contact = ""
ENT.Purpose = "Card entity for Kards card editor"
ENT.Instructions = "Spawn this entity to create a Kards card"
ENT.Spawnable = true
ENT.AdminOnly = false

-- 卡牌数据
function ENT:SetCardData(data)
    self.CardData = data
    if SERVER then
        self:SetNWString("CardID", data.id)
        self:SetNWString("CardName", data.name)
        self:SetNWInt("CardCost", data.cost)
        self:SetNWInt("CardAttack", data.attack)
        self:SetNWInt("CardDefense", data.defense)
        self:SetNWString("CardDescription", data.description)
        self:SetNWString("CardImagePath", data.imagePath)
        self:SetNWString("CardTemplatePath", data.templatePath)
    end
end

function ENT:GetCardData()
    if SERVER then
        return self.CardData
    else
        return {
            id = self:GetNWString("CardID"),
            name = self:GetNWString("CardName"),
            cost = self:GetNWInt("CardCost"),
            attack = self:GetNWInt("CardAttack"),
            defense = self:GetNWInt("CardDefense"),
            description = self:GetNWString("CardDescription"),
            imagePath = self:GetNWString("CardImagePath"),
            templatePath = self:GetNWString("CardTemplatePath")
        }
    end
end

-- 实体初始化
function ENT:Initialize()
    self:SetModel("models/props_phx/construct/plastic/plastic_panel1x1.mdl")
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    
    if SERVER then
        self:PhysicsInit(SOLID_VPHYSICS)
        self:SetUseType(SIMPLE_USE)
        
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            phys:EnableMotion(true)
            phys:SetMass(1)
        end
    end
    
    -- 缩放模型为扁平状（使用数值参数，非Vector）
    self:SetModelScale(0.1)
end

-- 实体使用
function ENT:Use(ply)
    if IsValid(ply) and ply:IsPlayer() then
        -- 打开卡牌编辑器
        KARDS.CardEditor:OpenEditor(ply)
    end
end
