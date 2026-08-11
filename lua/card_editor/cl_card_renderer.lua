-- Kards 卡牌编辑器卡牌渲染系统
-- 客户端文件，实现卡牌的实时渲染和预览

if CLIENT then

KARDS.CardEditor.Renderer = KARDS.CardEditor.Renderer or {}
KARDS.CardEditor.Renderer.Materials = {}

-- 卡牌尺寸
KARDS.CardEditor.Renderer.CardSize = {
    width = 200,
    height = 280
}

-- 渲染卡牌
function KARDS.CardEditor.Renderer:RenderCard(cardData, x, y, w, h)
    if not cardData then return end
    w = w or self.CardSize.width
    h = h or self.CardSize.height
    
    -- 绘制卡牌背景
    self:DrawCardBackground(x, y, w, h)
    
    -- 绘制卡牌模板
    self:DrawCardTemplate(cardData, x, y, w, h)
    
    -- 绘制卡牌属性
    self:DrawCardProperties(cardData, x, y, w, h)
    
    -- 绘制卡牌插图
    self:DrawCardImage(cardData, x, y, w, h)
    
    -- 绘制卡牌描述
    self:DrawCardDescription(cardData, x, y, w, h)
end

-- 绘制卡牌背景
function KARDS.CardEditor.Renderer:DrawCardBackground(x, y, w, h)
    -- 绘制卡牌边框
    draw.RoundedBox(8, x, y, w, h, Color(50, 50, 50))
    
    -- 绘制卡牌背景
    draw.RoundedBox(6, x + 2, y + 2, w - 4, h - 4, Color(240, 240, 240))
end

-- 绘制卡牌模板
function KARDS.CardEditor.Renderer:DrawCardTemplate(cardData, x, y, w, h)
    if not cardData then return end
    if cardData.templatePath and cardData.templatePath ~= "" then
        -- 尝试加载模板材质
        local material = self:GetMaterial(cardData.templatePath)
        if material then
            surface.SetMaterial(material)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.DrawTexturedRect(x + 2, y + 2, w - 4, h - 4)
        end
    end
end

-- 绘制卡牌属性
function KARDS.CardEditor.Renderer:DrawCardProperties(cardData, x, y, w, h)
    if not cardData then return end
    
    local attack = cardData.attack or 0
    local defense = cardData.defense or 0
    local name = cardData.name or "Unnamed"
    
    -- 绘制费用（总部无费用，不绘制）
    if cardData.cardType ~= "headquarter" then
        local cost = cardData.cost or 0
        draw.RoundedBox(4, x + 8, y + 8, 30, 30, Color(0, 100, 255))
        draw.SimpleText(tostring(cost), "Trebuchet24", x + 23, y + 23, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    
    -- 绘制攻击力
    draw.RoundedBox(4, x + 8, y + h - 38, 30, 30, Color(255, 50, 50))
    draw.SimpleText(tostring(attack), "Trebuchet24", x + 23, y + h - 23, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 绘制防御力
    draw.RoundedBox(4, x + w - 38, y + h - 38, 30, 30, Color(50, 150, 50))
    draw.SimpleText(tostring(defense), "Trebuchet24", x + w - 23, y + h - 23, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 绘制卡牌名称
    draw.SimpleText(tostring(name), "Trebuchet24", x + w / 2, y + 30, Color(0, 0, 0), TEXT_ALIGN_CENTER)
end

-- 绘制卡牌插图
function KARDS.CardEditor.Renderer:DrawCardImage(cardData, x, y, w, h)
    if not cardData then return end
    if cardData.imagePath and cardData.imagePath ~= "" then
        -- 尝试加载图片材质
        local material = self:GetMaterial(cardData.imagePath)
        if material then
            surface.SetMaterial(material)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.DrawTexturedRect(x + 10, y + 60, w - 20, h - 140)
        end
    else
        -- 绘制默认插图占位符
        draw.RoundedBox(4, x + 10, y + 60, w - 20, h - 140, Color(200, 200, 200))
        draw.SimpleText("No Image", "Trebuchet24", x + w / 2, y + h / 2, Color(100, 100, 100), TEXT_ALIGN_CENTER)
    end
end

-- 绘制卡牌描述
function KARDS.CardEditor.Renderer:DrawCardDescription(cardData, x, y, w, h)
    if not cardData then return end
    local description = cardData.description or ""
    
    -- 绘制描述背景
    draw.RoundedBox(4, x + 10, y + h - 100, w - 20, 60, Color(220, 220, 220))
    
    -- 绘制描述文本（Trebuchet14 不是有效字体，GMod 内置的是 Trebuchet24）
    draw.DrawText(tostring(description), "Trebuchet24", x + 15, y + h - 95, Color(0, 0, 0), TEXT_ALIGN_LEFT)
end

-- 获取材质
function KARDS.CardEditor.Renderer:GetMaterial(path)
    if not path then return nil end
    if not self.Materials[path] then
        self.Materials[path] = Material(path)
    end
    return self.Materials[path]
end

-- 创建动态材质
function KARDS.CardEditor.Renderer:CreateDynamicMaterial(cardData)
    if not cardData or not cardData.id then return nil end
    local matName = "kards_card_" .. tostring(cardData.id)
    
    -- 检查材质是否已存在
    if not self.Materials[matName] then
        -- 创建动态材质
        self.Materials[matName] = CreateMaterial(matName, "UnlitGeneric", {
            ["$basetexture"] = "vgui/white",
            ["$translucent"] = 1,
            ["$vertexalpha"] = 1,
            ["$vertexcolor"] = 1
        })
    end
    
    -- 更新材质
    self:UpdateDynamicMaterial(cardData, self.Materials[matName])
    
    return self.Materials[matName]
end

-- 更新动态材质
function KARDS.CardEditor.Renderer:UpdateDynamicMaterial(cardData, material)
    if not cardData or not cardData.id or not material then return end
    
    -- 创建离屏渲染目标
    local rtName = "kards_card_rt" .. tostring(cardData.id)
    local rt = GetRenderTarget(rtName, self.CardSize.width, self.CardSize.height)
    
    -- 开始渲染到渲染目标
    render.PushRenderTarget(rt)
    render.Clear(255, 255, 255, 255)
    
    -- 渲染卡牌
    self:RenderCard(cardData, 0, 0, self.CardSize.width, self.CardSize.height)
    
    -- 结束渲染
    render.PopRenderTarget()
    
    -- 更新材质
    material:SetTexture("$basetexture", rt)
end

-- 导出卡牌为图片
function KARDS.CardEditor.Renderer:ExportCard(cardData, path)
    if not cardData or not cardData.id then return false end
    
    -- 创建渲染目标
    local rtName = "kards_export_rt" .. tostring(cardData.id)
    local rt = GetRenderTarget(rtName, self.CardSize.width, self.CardSize.height)
    
    -- 渲染卡牌
    render.PushRenderTarget(rt)
    render.Clear(255, 255, 255, 255)
    self:RenderCard(cardData, 0, 0, self.CardSize.width, self.CardSize.height)
    render.PopRenderTarget()
    
    -- 保存为图片
    render.SaveRenderTargetToFile(rt, path)
    return true
end

-- 初始化渲染器
function KARDS.CardEditor.Renderer:Initialize()
    KARDS.CardEditor:Log("Card renderer initialized", "DEBUG")
end

-- 当 Lua 初始化时执行
KARDS.CardEditor.Renderer:Initialize()

end
