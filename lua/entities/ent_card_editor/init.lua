-- Kards 卡牌编辑器卡牌实体服务端代码
-- 服务端文件，处理实体的服务端逻辑

AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")

include("shared.lua")

-- 实体生成
function ENT:SpawnFunction(ply, tr, ClassName)
    if not tr.Hit then return end
    
    local SpawnPos = tr.HitPos + tr.HitNormal * 16
    local ent = ents.Create(ClassName)
    ent:SetPos(SpawnPos)
    ent:SetAngles(Angle(0, ply:EyeAngles().yaw, 0))
    ent:Spawn()
    ent:Activate()
    
    -- 设置默认卡牌数据
    local defaultCard = KARDS.CardEditor.Core.CardManager.CreateCard()
    ent:SetCardData(defaultCard)
    
    return ent
end

-- 实体初始化
function ENT:Initialize()
    self.BaseClass.Initialize(self)
    
    -- 设置碰撞组
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    
    -- 生成唯一ID
    -- 注：SpawnFunction 中 SetCardData 在 Spawn() 之后才调用，Initialize 先执行，
    -- 此时 GetCardData() 可能为 nil，需先补一份默认卡牌数据
    local cardData = self:GetCardData()
    if not cardData then
        cardData = KARDS.CardEditor.Core.CardManager.CreateCard()
        self:SetCardData(cardData)
    end
    if not cardData.id then
        cardData.id = KARDS.CardEditor.Core.Utils.GenerateID()
        self:SetCardData(cardData)
    end
end

-- 保存卡牌数据
function ENT:SaveCardData()
    local cardData = self:GetCardData()
    if cardData and cardData.id then
        KARDS.CardEditor.Storage:SaveCard(cardData)
    end
end

-- 加载卡牌数据
function ENT:LoadCardData(cardId)
    local cardData = KARDS.CardEditor.Storage:LoadCard(cardId)
    if cardData then
        self:SetCardData(cardData)
    end
end
