--[[
=======================================================================================
节点绘制系统 - 旧 NodeBase 兼容代码 (Node Drawing System)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的子系统，负责旧 NodeBase 系统的节点绘制渲染。

包含功能：
  - DrawNodes（绘制所有节点）
  - DrawPorts（绘制端口）
  - DrawNode（绘制单个节点）
  - DrawNodePorts（绘制节点端口）
  - DrawTab（绘制标签页）

源文件：cl_canvas_editor.lua（行 2582~2727）
=======================================================================================
]]

-- 此文件内容将剪切自 cl_canvas_editor.lua 行 2582~2727
-- 包含：DrawNodes、DrawPorts、DrawNode、DrawNodePorts、DrawTab
function KARDS.CardEditor.Canvas.DrawNodes()
    local draggingNode = nil
    KARDS.CardEditor.Canvas.HoveredNode = nil
    
    local selectedSet = {}
    for _, selectedNode in ipairs(KARDS.CardEditor.Canvas.SelectionState.selectedNodes) do
        selectedSet[selectedNode] = true
    end
    KARDS.CardEditor.Canvas.SelectionState.selectedSet = selectedSet
    
    for _, node in ipairs(KARDS.CardEditor.Canvas.Nodes) do
        if node == KARDS.CardEditor.Canvas.DraggingNode then
            draggingNode = node
        else
            KARDS.CardEditor.Canvas.DrawNode(node, selectedSet)
        end
    end
    
    if draggingNode then
        KARDS.CardEditor.Canvas.DrawNode(draggingNode, selectedSet)
    end
end

function KARDS.CardEditor.Canvas.DrawPorts()
    local draggingNode = nil
    
    for _, node in ipairs(KARDS.CardEditor.Canvas.Nodes) do
        if node == KARDS.CardEditor.Canvas.DraggingNode then
            draggingNode = node
        else
            KARDS.CardEditor.Canvas.DrawNodePorts(node)
        end
    end
    
    if draggingNode then
        KARDS.CardEditor.Canvas.DrawNodePorts(draggingNode)
    end
end

function KARDS.CardEditor.Canvas.DrawNode(node, selectedSet)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    if node.isStartNode then
        NodeBase.DrawStartNode(node)
        return
    end
    
    local isHovered = NodeBase.IsMouseOver(node, mouseX, mouseY)
    
    if isHovered then
        KARDS.CardEditor.Canvas.HoveredNode = node
    end
    
    local isDraggingToSelector = false
    if KARDS.CardEditor.Canvas.DraggingNode == node then
        local win = KARDS.CardEditor.Canvas.Window
        local contentX = win.x + 5
        local contentY = win.y + 75
        local selectorW = 180
        local contentH = win.height - 80
        isDraggingToSelector = mouseX >= contentX and mouseX <= contentX + selectorW and
                              mouseY >= contentY and mouseY <= contentY + contentH
    end
    
    if isDraggingToSelector then
        surface.SetAlphaMultiplier(0.5)
    end
    
    NodeBase.DrawBackground(node)
    
    if isDraggingToSelector then
        surface.SetAlphaMultiplier(1)
    end
    
    local isSelected = selectedSet and selectedSet[node] or false
    
    NodeBase.DrawHoverAndSelection(node, isHovered, isSelected)

    NodeBase.DrawNodeContent(node)
    return

end

function KARDS.CardEditor.Canvas.DrawNodePorts(node)
    if node.isStartNode then return end
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    NodeBase.DrawPorts(node, mouseX, mouseY)
    NodeBase.DrawDataPorts(node, mouseX, mouseY)
end

-- 绘制选项卡组件
function KARDS.CardEditor.Canvas.DrawTab(x, y, width, height, options, selectedIndex, node, tabId)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local win = KARDS.CardEditor.Canvas.Window
    
    options = options or {}
    if #options == 0 then
        return 1
    end
    
    node.data = node.data or {}
    node.data.tabs = node.data.tabs or {}
    
    if not node.data.tabs[tabId] then
        node.data.tabs[tabId] = {
            selectedIndex = selectedIndex or 1,
            lastClickTime = 0
        }
    end
    
    local tabData = node.data.tabs[tabId]
    local currentIndex = tabData.selectedIndex
    currentIndex = math.Clamp(currentIndex, 1, #options)
    local currentTime = SysTime()
    
    draw.RoundedBox(4, x, y, width, height, Color(60, 60, 60))
    
    local selectedOption = options[currentIndex] or options[1] or ""
    if selectedOption ~= "" then
        draw.SimpleText(selectedOption, "SourceHan_Heavy_14", x + width / 2, y + height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    
    local triangleSize = 6
    local triangleX = x + width - 10
    local triangleY = y + height / 2
    surface.SetDrawColor(Color(150, 150, 150))
    surface.DrawLine(triangleX, triangleY - triangleSize / 2, triangleX + triangleSize, triangleY - triangleSize / 2)
    surface.DrawLine(triangleX, triangleY - triangleSize / 2, triangleX + triangleSize / 2, triangleY + triangleSize / 2)
    surface.DrawLine(triangleX + triangleSize, triangleY - triangleSize / 2, triangleX + triangleSize / 2, triangleY + triangleSize / 2)
    
    if input.WasMousePressed(MOUSE_LEFT) and not KARDS.CardEditor.Canvas.DraggingNode then
        if mouseX >= x and mouseX <= x + width and
           mouseY >= y and mouseY <= y + height then
            currentIndex = currentIndex % #options + 1
            tabData.selectedIndex = currentIndex
            tabData.lastClickTime = currentTime
        end
    end
    
    if mouseX >= x and mouseX <= x + width and
       mouseY >= y and mouseY <= y + height then
        draw.RoundedBox(4, x, y, width, height, Color(80, 80, 80, 150))
    end
    
    return currentIndex
end