-- Kards 卡牌编辑器卡牌实体客户端代码
-- 客户端文件，处理实体的客户端渲染和视觉效果

include("shared.lua")

-- 实体绘制
function ENT:Draw()
    -- 绘制实体模型
    self:DrawModel()
    
    -- 应用动态材质
    self:ApplyDynamicMaterial()
end

-- 应用动态材质
function ENT:ApplyDynamicMaterial()
    local cardData = self:GetCardData()
    if not cardData then return end
    
    -- 创建并应用动态材质
    local material = KARDS.CardEditor.Renderer:CreateDynamicMaterial(cardData)
    self:SetMaterial(material)
end

-- 实体思考
function ENT:Think()
    -- 每帧更新材质
    self:ApplyDynamicMaterial()
    
    -- 让卡牌面向玩家
    self:FacePlayer()
    
    -- 检查是否有玩家鼠标悬停在实体上
    local ply = LocalPlayer()
    if IsValid(ply) then
        local tr = ply:GetEyeTrace()
        if tr.Entity == self then
            self:ShowCardInfo()
        end
    end
end

-- 让卡牌面向玩家
function ENT:FacePlayer()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    
    local plyPos = ply:GetEyePos()
    local cardPos = self:GetPos()
    
    local angle = (plyPos - cardPos):Angle()
    angle.p = 0
    angle.r = 0
    
    self:SetAngles(angle)
end

-- 显示卡牌信息
function ENT:ShowCardInfo()
    local cardData = self:GetCardData()
    if not cardData then return end
    
    -- 这里可以实现卡牌信息的显示，比如使用 HUD 或 VGUI
    -- 暂时使用控制台输出
    if not self.LastShowTime or CurTime() - self.LastShowTime > 1 then
        print("Card: " .. cardData.name)
        print("Cost: " .. cardData.cost)
        print("Attack: " .. cardData.attack)
        print("Defense: " .. cardData.defense)
        print("Description: " .. cardData.description)
        self.LastShowTime = CurTime()
    end
end
