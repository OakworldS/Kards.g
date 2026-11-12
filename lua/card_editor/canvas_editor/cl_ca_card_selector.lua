--[[
=======================================================================================
卡牌选择器 (Card Selector)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的子系统，负责卡牌选择和嵌入选择器的 UI 绘制。

包含功能：
  - DrawCardSelector（全局卡牌选择组件）
  - DrawEmbeddedCardSelector（可嵌入节点的卡牌单选组件）

源文件：cl_canvas_editor.lua（行 9568~9809）
=======================================================================================
]]

-- 此文件内容将剪切自 cl_canvas_editor.lua 行 9568~9809
-- 包含：DrawEmbeddedCardSelector、DrawCardSelector

-- 剪切完成后，在 cl_canvas_editor.lua 中保留：
-- 1. KARDS.CardEditor.Canvas.CardSelector 状态声明（行 972~985）
-- 2. CardSelector.RefreshList 函数（行 987~992）

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- 绘制可内嵌的卡牌单选组件
function KARDS.CardEditor.Canvas.DrawEmbeddedCardSelector(x, y, width, height, node, selectorId)
    -- 初始化节点中的选择器数据
    node.data = node.data or {}
    node.data.cardSelectors = node.data.cardSelectors or {}
    node.data.cardSelectors[selectorId] = node.data.cardSelectors[selectorId] or {
        expanded = false,
        selectedCard = nil,
        cardsList = {},
        hoveredCardIndex = nil,
        scrollOffset = 0,
        lastRefresh = 0
    }
    
    local selector = node.data.cardSelectors[selectorId]
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local currentTime = SysTime()
    
    -- 定期刷新卡牌列表
    if currentTime - selector.lastRefresh > 1 then
        if KARDS.CardEditor.SaveSystem and KARDS.CardEditor.SaveSystem.GetAllSavedCardsInfo then
            selector.cardsList = KARDS.CardEditor.SaveSystem.GetAllSavedCardsInfo()
        end
        selector.lastRefresh = currentTime
    end
    
    local buttonHeight = height
    local currentHeight = selector.expanded and (buttonHeight + 180) or buttonHeight
    
    -- 绘制主按钮区域
    local buttonY = y
    local buttonX = x
    local buttonWidth = width
    
    local isButtonHovered = mouseX >= buttonX and mouseX <= buttonX + buttonWidth and mouseY >= buttonY and mouseY <= buttonY + buttonHeight
    local buttonColor = isButtonHovered and Color(60, 60, 60) or Color(50, 50, 50)
    draw.RoundedBox(4, buttonX, buttonY, buttonWidth, buttonHeight, buttonColor)
    
    -- 绘制显示文本（根据大小调整字体）
    local fontSize = 14
    local displayText = selector.selectedCard and selector.selectedCard.name or T("editor.selector.select_card")
    draw.SimpleText(displayText, "SourceHan_Heavy_" .. fontSize, buttonX + 8, buttonY + buttonHeight / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    
    -- 绘制箭头
    local arrowX = buttonX + buttonWidth - 18
    local arrowY = buttonY + buttonHeight / 2
    surface.SetDrawColor(150, 150, 150, 255)
    if selector.expanded then
        surface.DrawLine(arrowX - 5, arrowY + 2, arrowX, arrowY - 2)
        surface.DrawLine(arrowX, arrowY - 2, arrowX + 5, arrowY + 2)
    else
        surface.DrawLine(arrowX - 5, arrowY - 2, arrowX, arrowY + 2)
        surface.DrawLine(arrowX, arrowY + 2, arrowX + 5, arrowY - 2)
    end
    
    -- 处理按钮点击
    if isButtonHovered and input.IsMouseDown(MOUSE_LEFT) then
        if not selector.wasPressed then
            selector.wasPressed = true
            selector.expanded = not selector.expanded
        end
    else
        selector.wasPressed = false
    end
    
    -- 如果展开，绘制列表（缩小缩放）
    if selector.expanded then
        local listX = x
        local listY = y + buttonHeight + 2
        local listWidth = width
        local listHeight = 178
        local itemHeight = 35
        local previewWidth = 100
        local previewHeight = 140
        
        -- 绘制列表背景
        draw.RoundedBox(4, listX, listY, listWidth, listHeight, Color(35, 35, 35))
        
        -- 如果没有卡牌，显示提示
        if #selector.cardsList == 0 then
            draw.SimpleText(T("editor.selector.no_cards"), "SourceHan_Heavy_12", listX + listWidth / 2, listY + listHeight / 2, Color(100, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return selector
        end
        
        -- 计算可显示的项目数
        local visibleItems = math.floor(listHeight / itemHeight)
        local scrollOffset = selector.scrollOffset
        
        -- 绘制卡牌列表项
        local hoveredCard = nil
        for i = 1 + scrollOffset, math.min(#selector.cardsList, visibleItems + scrollOffset) do
            local card = selector.cardsList[i]
            local itemIndex = i - scrollOffset
            local itemY = listY + (itemIndex - 1) * itemHeight
            
            if itemY + itemHeight > listY + listHeight then break end
            
            -- 检查悬停
            local isItemHovered = mouseX >= listX and mouseX <= listX + listWidth and mouseY >= itemY and mouseY <= itemY + itemHeight
            local isSelected = selector.selectedCard and selector.selectedCard.fileName == card.fileName
            
            if isItemHovered then
                selector.hoveredCardIndex = i
                hoveredCard = card
                
                -- 处理点击选择
                if input.IsMouseDown(MOUSE_LEFT) then
                    if not selector.itemWasPressed then
                        selector.itemWasPressed = true
                        selector.selectedCard = card
                        selector.expanded = false
                    end
                else
                    selector.itemWasPressed = false
                end
            end
            
            -- 绘制项背景
            local itemColor = isSelected and Color(80, 80, 120) or (isItemHovered and Color(55, 55, 55) or Color(45, 45, 45))
            draw.RoundedBox(2, listX + 2, itemY + 2, listWidth - 4, itemHeight - 4, itemColor)
            
            -- 绘制分隔线
            if itemIndex > 1 then
                surface.SetDrawColor(60, 60, 60, 255)
                surface.DrawLine(listX + 4, itemY + 2, listX + listWidth - 4, itemY + 2)
                surface.SetDrawColor(255, 255, 255, 255)
            end
            
            -- 绘制卡牌名称（缩小字体）
            local displayName = card.name ~= "" and card.name or T("editor.selector.unnamed")
            draw.SimpleText(displayName, "SourceHan_Heavy_12", listX + 8, itemY + itemHeight / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        

    end
    
    return selector
end

-- 绘制卡牌单选组件（保持原有的全局组件）
function KARDS.CardEditor.Canvas.DrawCardSelector()
    local selector = KARDS.CardEditor.Canvas.CardSelector
    if not selector.visible then return end
    
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local currentHeight = selector.expanded and selector.expandedHeight or selector.height
    
    -- 绘制组件背景
    draw.RoundedBox(8, selector.x, selector.y, selector.width, currentHeight, Color(50, 50, 50))
    draw.RoundedBox(8, selector.x + 2, selector.y + 2, selector.width - 4, currentHeight - 4, Color(40, 40, 40))
    
    -- 绘制主按钮区域
    local buttonY = selector.y + 2
    local buttonHeight = selector.height - 4
    local buttonWidth = selector.width - 4
    local buttonX = selector.x + 2
    
    local isButtonHovered = mouseX >= buttonX and mouseX <= buttonX + buttonWidth and mouseY >= buttonY and mouseY <= buttonY + buttonHeight
    local buttonColor = isButtonHovered and Color(60, 60, 60) or Color(50, 50, 50)
    draw.RoundedBox(6, buttonX, buttonY, buttonWidth, buttonHeight, buttonColor)
    
    -- 绘制显示文本
    local displayText = selector.selectedCard and selector.selectedCard.name or T("editor.selector.select_card_ellipsis")
    draw.SimpleText(displayText, "SourceHan_Heavy_16", buttonX + 15, buttonY + buttonHeight / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    
    -- 绘制箭头
    local arrowX = buttonX + buttonWidth - 25
    local arrowY = buttonY + buttonHeight / 2
    surface.SetDrawColor(150, 150, 150, 255)
    if selector.expanded then
        -- 向上箭头
        surface.DrawLine(arrowX - 6, arrowY + 3, arrowX, arrowY - 3)
        surface.DrawLine(arrowX, arrowY - 3, arrowX + 6, arrowY + 3)
    else
        -- 向下箭头
        surface.DrawLine(arrowX - 6, arrowY - 3, arrowX, arrowY + 3)
        surface.DrawLine(arrowX, arrowY + 3, arrowX + 6, arrowY - 3)
    end
    
    -- 如果展开，绘制列表
    if selector.expanded then
        local listX = selector.x + 2
        local listY = buttonY + buttonHeight + 4
        local listWidth = selector.width - 4
        local listHeight = selector.expandedHeight - selector.height - 8
        local itemHeight = 45
        local previewWidth = 150
        local previewHeight = 200
        
        -- 绘制列表背景
        draw.RoundedBox(4, listX, listY, listWidth, listHeight, Color(35, 35, 35))
        
        -- 如果没有卡牌，显示提示
        if #selector.cardsList == 0 then
            draw.SimpleText(T("editor.selector.no_saved_cards"), "SourceHan_Heavy_14", listX + listWidth / 2, listY + listHeight / 2, Color(100, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return
        end
        
        -- 计算可显示的项目数
        local visibleItems = math.floor(listHeight / itemHeight)
        local scrollOffset = selector.scrollOffset
        
        -- 绘制卡牌列表项
        local hoveredCard = nil
        for i = 1 + scrollOffset, math.min(#selector.cardsList, visibleItems + scrollOffset) do
            local card = selector.cardsList[i]
            local itemIndex = i - scrollOffset
            local itemY = listY + (itemIndex - 1) * itemHeight
            
            if itemY + itemHeight > listY + listHeight then break end
            
            -- 检查悬停
            local isItemHovered = mouseX >= listX and mouseX <= listX + listWidth and mouseY >= itemY and mouseY <= itemY + itemHeight
            local isSelected = selector.selectedCard and selector.selectedCard.fileName == card.fileName
            
            if isItemHovered then
                selector.hoveredCardIndex = i
                hoveredCard = card
            end
            
            -- 绘制项背景
            local itemColor = isSelected and Color(80, 80, 120) or (isItemHovered and Color(55, 55, 55) or Color(45, 45, 45))
            draw.RoundedBox(4, listX + 2, itemY + 2, listWidth - 4, itemHeight - 4, itemColor)
            
            -- 绘制分隔线
            if itemIndex > 1 then
                surface.SetDrawColor(60, 60, 60, 255)
                surface.DrawLine(listX + 5, itemY + 2, listX + listWidth - 5, itemY + 2)
                surface.SetDrawColor(255, 255, 255, 255)
            end
            
            -- 绘制卡牌名称
            local displayName = card.name ~= "" and card.name or T("editor.selector.unnamed")
            draw.SimpleText(displayName, "SourceHan_Heavy_16", listX + 15, itemY + 18, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            
            -- 绘制文件名和保存时间
            draw.SimpleText(KARDS.CardEditor.SaveSystem.UnescapeFileName(card.fileName), "SourceHan_Heavy_12", listX + 15, itemY + 35, Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            draw.SimpleText(card.savedAt, "SourceHan_Heavy_12", listX + listWidth - 15, itemY + 35, Color(100, 100, 100), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        end
        

    end
end