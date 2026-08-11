--[[
=======================================================================================
NodeBase 旧节点编辑器系统
=======================================================================================
基于单例模式的节点编辑器系统，与 KARDS.CardEditor.Canvas 深度耦合。
提供节点创建/删除、连线、端口检测、贝塞尔曲线绘制、序列化/反序列化、
框选、配置解析（ParseConfig DSL）等功能。

注意：此系统已被 INE（IndependentNodeEditor）取代为最终方案，
但暂时保留以兼容现有功能。

=======================================================================================
]]

-- 节点基类
KARDS.CardEditor.Canvas.NodeBase = {}
NodeBase = KARDS.CardEditor.Canvas.NodeBase

-- 节点编辑器配置（为独立化做准备）
NodeBase.Config = {
    selectorWidth = 180,
    contentOffsetX = 5,
    contentOffsetY = 45,
    portRadius = 6,
    clickRadius = 12
}

-- 数据类型定义
NodeBase.DataTypes = {
    NUMBER = {
        id = "n",
        name = "数字",
        color = Color(255, 165, 0),
        shape = "circle"
    },
    BOOLEAN = {
        id = "p",
        name = "布尔值",
        color = Color(135, 206, 250),
        shape = "triangle"
    },
    STRING = {
        id = "t",
        name = "字符串",
        color = Color(144, 238, 144),
        shape = "hollow_circle"
    },
    ARRAY = {
        id = "g",
        name = "数组",
        color = Color(255, 255, 0),
        shape = "hollow_square"
    },
    CARD = {
        id = "e",
        name = "卡牌对象",
        color = Color(255, 127, 127),
        shape = "square"
    },
    FUNCTION = {
        id = "f",
        name = "节点函数",
        color = Color(200, 150, 255),
        shape = "diamond"
    }
}

-- 根据标识符获取数据类型
function NodeBase.GetDataTypeById(id)
    for _, dataType in pairs(NodeBase.DataTypes) do
        if dataType.id == id then
            return dataType
        end
    end
    return nil
end

-- 绘制数据类型图标
function NodeBase.DrawDataTypeIcon(dataType, x, y, size)
    if not dataType then return end
    
    local halfSize = size / 2
    surface.SetDrawColor(dataType.color)
    
    if dataType.shape == "circle" then
        draw.RoundedBox(halfSize, x - halfSize, y - halfSize, size, size, dataType.color)
    elseif dataType.shape == "triangle" then
        local points = {
            {x = x, y = y - halfSize},
            {x = x + halfSize, y = y + halfSize},
            {x = x - halfSize, y = y + halfSize}
        }
        draw.NoTexture()
        surface.SetDrawColor(dataType.color)
        surface.DrawPoly(points)
    elseif dataType.shape == "square" then
        surface.DrawRect(x - halfSize, y - halfSize, size, size)
    elseif dataType.shape == "hollow_circle" then
        draw.RoundedBox(halfSize, x - halfSize, y - halfSize, size, size, dataType.color)
        draw.RoundedBox(halfSize - 2, x - halfSize + 2, y - halfSize + 2, size - 4, size - 4, Color(50, 50, 50))
    elseif dataType.shape == "hollow_square" then
        surface.DrawRect(x - halfSize, y - halfSize, size, size)
        surface.SetDrawColor(Color(50, 50, 50))
        surface.DrawRect(x - halfSize + 2, y - halfSize + 2, size - 4, size - 4)
    elseif dataType.shape == "diamond" then
        local points = {
            {x = x, y = y - halfSize},
            {x = x + halfSize, y = y},
            {x = x, y = y + halfSize},
            {x = x - halfSize, y = y}
        }
        draw.NoTexture()
        surface.SetDrawColor(dataType.color)
        surface.DrawPoly(points)
    end
end

-- 设置窗口引用
function NodeBase.SetWindow(win)
    NodeBase.Window = win
end

-- 获取屏幕位置计算辅助
function NodeBase.GetContentX()
    local win = NodeBase.Window or KARDS.CardEditor.Canvas.Window
    return win.x + NodeBase.Config.contentOffsetX
end

function NodeBase.GetNodeEditorX()
    return NodeBase.GetContentX() + NodeBase.Config.selectorWidth
end

function NodeBase.GetContentY()
    local win = NodeBase.Window or KARDS.CardEditor.Canvas.Window
    return win.y + NodeBase.Config.contentOffsetY
end

-- 创建一个新节点实例
function NodeBase.New(nodeType, nodeName, nodeColor, hasInput, hasOutput, template)
    KARDS.CardEditor.Canvas.NodeCounter = KARDS.CardEditor.Canvas.NodeCounter + 1
    
    local nodeWidth = 200
    local nodeHeight = 80
    local nodeData = {}
    
    local availableOutputTypes = {}
    local availableInputTypes = {}
    
    -- 如果有模板，解析配置并计算尺寸
    if template and template.config then
        local configResult = NodeBase.ParseConfig(template.config)
        local components = configResult.components or configResult
        nodeData = NodeBase.InitNodeData(components, {})
        nodeWidth, nodeHeight = NodeBase.CalculateSize(components, nodeData)
        availableOutputTypes = configResult.outputTypes or {}
        availableInputTypes = configResult.inputTypes or {}
    end
    
    local node = {
        id = "node_" .. KARDS.CardEditor.Canvas.NodeCounter,
        type = nodeType,
        title = nodeName,
        color = nodeColor,
        x = 0,
        y = 0,
        width = nodeWidth,
        height = nodeHeight,
        dragging = false,
        dragStartX = 0,
        dragStartY = 0,
        startX = 0,
        startY = 0,
        hasInput = hasInput,
        hasOutput = hasOutput,
        hasSecondOutput = template and template.hasSecondOutput or false, -- 是否有第二个输出点（双分支：满足/不满足）
        data = nodeData,
        availableOutputTypes = availableOutputTypes,
        availableInputTypes = availableInputTypes,
        selectedOutputTypes = {},
        selectedInputTypes = {},
        showAddOutputButton = #availableOutputTypes > 0,
        showAddInputButton = #availableInputTypes > 0
    }
    
    return node
end

-- 获取节点在屏幕上的位置（考虑编辑器窗口位置）
function NodeBase.GetScreenPosition(node)
    local win = NodeBase.Window or KARDS.CardEditor.Canvas.Window
    
    if node.isStartNode then
        return win.x + node.x, win.y + node.y
    else
        return NodeBase.GetNodeEditorX() + node.x, win.y + node.y
    end
end

-- 检查鼠标是否在节点上
function NodeBase.IsMouseOver(node, mouseX, mouseY)
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    return mouseX >= nodeX and mouseX <= nodeX + node.width and
           mouseY >= nodeY and mouseY <= nodeY + node.height
end

-- 开始拖拽节点
function NodeBase.StartDrag(node, mouseX, mouseY)
    node.dragging = true
    node.dragStartX = mouseX
    node.dragStartY = mouseY
    node.startX = node.x
    node.startY = node.y
end

-- 结束拖拽节点
function NodeBase.EndDrag(node)
    node.dragging = false
end

-- 更新节点拖拽位置
function NodeBase.UpdateDrag(node, mouseX, mouseY)
    if node.dragging then
        node.x = node.startX + (mouseX - node.dragStartX)
        node.y = node.startY + (mouseY - node.dragStartY)
    end
end

-- 检查是否为特殊节点（有特殊绘制要求）
function NodeBase.IsSpecialNode(node)
    return node.type == "condition" or node.type == "loop" or node.type == "target_selector" or node.type == "event_monitor"
end

-- 绘制通用节点背景和标题
function NodeBase.DrawBackground(node)
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    
    draw.RoundedBox(8, nodeX, nodeY, node.width, node.height, node.color)
    draw.RoundedBox(8, nodeX + 2, nodeY + 2, node.width - 4, node.height - 4, Color(50, 50, 50))
    draw.RoundedBox(4, nodeX, nodeY, node.width, 24, Color(70, 70, 70))
    draw.SimpleText(node.title, "SourceHan_Heavy_16", nodeX + 10, nodeY + 12, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    draw.SimpleText("[" .. node.type .. "]", "SourceHan_Heavy_12", nodeX + node.width - 10, nodeY + 12, Color(180, 180, 180), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
end

-- 绘制数据端口
function NodeBase.DrawDataPorts(node, mouseX, mouseY)
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    local portRadius = NodeBase.Config.portRadius
    local clickRadius = NodeBase.Config.clickRadius
    
    -- 绘制输入数据点（顶部，深蓝色）
    if node.showAddInputButton and #node.availableInputTypes > 0 then
        local inputPortX = nodeX + node.width / 2 - portRadius
        local inputPortY = nodeY - portRadius * 2 - 4
        
        local isPortHovered = NodeBase.IsMouseOverPort(inputPortX, inputPortY, mouseX, mouseY, portRadius, clickRadius)
        
        surface.SetDrawColor(isPortHovered and Color(80, 120, 200) or Color(60, 100, 180))
        draw.RoundedBox(portRadius, inputPortX, inputPortY, portRadius * 2, portRadius * 2, isPortHovered and Color(80, 120, 200) or Color(60, 100, 180))
        
        surface.SetDrawColor(Color(255, 255, 255))
        local centerX = inputPortX + portRadius
        local centerY = inputPortY + portRadius
        surface.DrawLine(centerX - 3, centerY, centerX + 3, centerY)
        surface.DrawLine(centerX, centerY - 3, centerX, centerY + 3)
        
        if #node.selectedInputTypes > 0 then
            local startX = nodeX + node.width / 2 - (#node.selectedInputTypes * (portRadius * 2 + 4)) / 2 + portRadius
            local yPos = nodeY - portRadius * 5 - 8
            for i, typeId in ipairs(node.selectedInputTypes) do
                local dataType = NodeBase.GetDataTypeById(typeId)
                if dataType then
                    NodeBase.DrawDataTypeIcon(dataType, startX + (i - 1) * (portRadius * 2 + 4), yPos, portRadius * 1.5)
                end
            end
        end
    end
    
    -- 绘制输出数据点（底部，黄色）
    if node.showAddOutputButton and #node.availableOutputTypes > 0 then
        if #node.selectedOutputTypes > 0 then
            local startX = nodeX + node.width / 2 - (#node.selectedOutputTypes * (portRadius * 2 + 4)) / 2 + portRadius
            local yPos = nodeY + node.height + portRadius * 2 + 4
            for i, typeId in ipairs(node.selectedOutputTypes) do
                local dataType = NodeBase.GetDataTypeById(typeId)
                if dataType then
                    local portX = startX + (i - 1) * (portRadius * 2 + 4) - portRadius
                    local portY = yPos - portRadius
                    
                    local isPortHovered = NodeBase.IsMouseOverPort(portX, portY, mouseX, mouseY, portRadius, clickRadius)
                    
                    NodeBase.DrawDataTypeIcon(dataType, portX + portRadius, portY + portRadius, portRadius * 2)
                    
                    if isPortHovered then
                        surface.SetDrawColor(Color(255, 255, 255, 100))
                        draw.RoundedBox(portRadius, portX - 2, portY - 2, portRadius * 2 + 4, portRadius * 2 + 4, Color(255, 255, 255, 100))
                    end
                end
            end
        end
        
        local addButtonX = nodeX + node.width / 2 - portRadius
        local addButtonY = nodeY + node.height + portRadius * 2 + 4
        if #node.selectedOutputTypes > 0 then
            addButtonY = addButtonY + portRadius * 3 + 8
        end
        
        local isAddHovered = NodeBase.IsMouseOverPort(addButtonX, addButtonY, mouseX, mouseY, portRadius, clickRadius)
        
        surface.SetDrawColor(isAddHovered and Color(80, 200, 80) or Color(60, 180, 60))
        draw.RoundedBox(portRadius, addButtonX, addButtonY, portRadius * 2, portRadius * 2, isAddHovered and Color(80, 200, 80) or Color(60, 180, 60))
        
        surface.SetDrawColor(Color(255, 255, 255))
        local centerX = addButtonX + portRadius
        local centerY = addButtonY + portRadius
        surface.DrawLine(centerX - 3, centerY, centerX + 3, centerY)
        surface.DrawLine(centerX, centerY - 3, centerX, centerY + 3)
    end
end

-- 绘制节点选中效果
function NodeBase.DrawHoverAndSelection(node, isHovered, isSelected)
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    
    if isHovered then
        surface.SetDrawColor(Color(255, 255, 255))
        surface.DrawOutlinedRect(nodeX - 2, nodeY - 2, node.width + 4, node.height + 4)
    end
    
    if isSelected then
        surface.SetDrawColor(Color(100, 150, 255))
        for i = 0, 2 do
            surface.DrawOutlinedRect(nodeX - 3 - i, nodeY - 3 - i, node.width + 6 + i * 2, node.height + 6 + i * 2)
        end
    end
end

-- 绘制通用输入输出端口
function NodeBase.DrawPorts(node, mouseX, mouseY)
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    local portRadius = NodeBase.Config.portRadius
    local clickRadius = NodeBase.Config.clickRadius
    local portY = nodeY + node.height / 2
    
    if node.hasInput then
        local inputPortX = nodeX - portRadius
        local inputPortY = portY - portRadius
        local isPortHovered = NodeBase.IsMouseOverPort(inputPortX, inputPortY, mouseX, mouseY, portRadius, clickRadius)
        
        surface.SetDrawColor(isPortHovered and Color(255, 255, 255) or Color(50, 50, 150))
        surface.DrawOutlinedRect(inputPortX - 2, inputPortY - 2, portRadius * 2 + 4, portRadius * 2 + 4)
        draw.RoundedBox(portRadius, inputPortX, inputPortY, portRadius * 2, portRadius * 2, Color(100, 100, 255))
        
        draw.SimpleText("输入", "SourceHan_Heavy_14", nodeX + 9, portY, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    
    if node.hasOutput and not NodeBase.IsSpecialNode(node) then
        local outputPortX = nodeX + node.width - portRadius
        local outputPortY = portY - portRadius
        local isPortHovered = NodeBase.IsMouseOverPort(outputPortX, outputPortY, mouseX, mouseY, portRadius, clickRadius)
        
        surface.SetDrawColor(isPortHovered and Color(255, 255, 255) or Color(150, 50, 50))
        surface.DrawOutlinedRect(outputPortX - 2, outputPortY - 2, portRadius * 2 + 4, portRadius * 2 + 4)
        draw.RoundedBox(portRadius, outputPortX, outputPortY, portRadius * 2, portRadius * 2, Color(255, 100, 100))
        
        draw.SimpleText("输出", "SourceHan_Heavy_14", nodeX + node.width - 15, portY, Color(200, 200, 200), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
    end
end

-- 检查鼠标是否在端口上
function NodeBase.IsMouseOverPort(portX, portY, mouseX, mouseY, portRadius, clickRadius)
    clickRadius = clickRadius or NodeBase.Config.clickRadius
    portRadius = portRadius or NodeBase.Config.portRadius
    
    return mouseX >= portX - (clickRadius - portRadius) and 
           mouseX <= portX + portRadius * 2 + (clickRadius - portRadius) and
           mouseY >= portY - (clickRadius - portRadius) and 
           mouseY <= portY + portRadius * 2 + (clickRadius - portRadius)
end

-- 获取节点端口的屏幕位置
function NodeBase.GetPortPosition(node, portType, portIndex)
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    local portRadius = NodeBase.Config.portRadius
    local portY = nodeY + node.height / 2
    
    if portType == "input" then
        return nodeX - portRadius, portY - portRadius
    elseif portType == "output" then
        if node.type == "condition" or node.type == "event_monitor" or node.type == "loop" then
            if portIndex == 1 then
                return nodeX + node.width, nodeY + node.height / 3 + portRadius
            else
                return nodeX + node.width, nodeY + node.height * 2 / 3 + portRadius
            end
        else
            return nodeX + node.width, portY
        end
    end
end

-- 贝塞尔曲线计算
function NodeBase.BezierCurve(p1x, p1y, p2x, p2y, p3x, p3y, p4x, p4y, steps)
    steps = steps or 20
    local points = {}
    for i = 0, steps do
        local t = i / steps
        local x = math.pow(1 - t, 3) * p1x + 3 * math.pow(1 - t, 2) * t * p2x + 3 * (1 - t) * math.pow(t, 2) * p3x + math.pow(t, 3) * p4x
        local y = math.pow(1 - t, 3) * p1y + 3 * math.pow(1 - t, 2) * t * p2y + 3 * (1 - t) * math.pow(t, 2) * p3y + math.pow(t, 3) * p4y
        table.insert(points, {x = x, y = y})
    end
    return points
end

-- 计算曲线法线
function NodeBase.GetCurveNormals(points, thickness)
    thickness = thickness or 5
    local normals = {}
    for i = 1, #points do
        local prev = points[math.max(1, i - 1)]
        local next = points[math.min(#points, i + 1)]
        local dx = next.x - prev.x
        local dy = next.y - prev.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0 then
            local nx = -dy / len
            local ny = dx / len
            table.insert(normals, {x = nx, y = ny})
        else
            table.insert(normals, {x = 0, y = 0})
        end
    end
    return normals
end

-- 绘制粗曲线
function NodeBase.DrawThickCurve(points, color, thickness)
    thickness = thickness or 5
    local normals = NodeBase.GetCurveNormals(points, thickness)
    
    for offset = -thickness, thickness do
        local offsetPoints = {}
        for i = 1, #points do
            table.insert(offsetPoints, {
                x = points[i].x + normals[i].x * offset,
                y = points[i].y + normals[i].y * offset
            })
        end
        
        surface.SetDrawColor(color)
        for i = 1, #offsetPoints - 1 do
            surface.DrawLine(offsetPoints[i].x, offsetPoints[i].y, offsetPoints[i+1].x, offsetPoints[i+1].y)
        end
    end
end

-- 检查鼠标是否在曲线附近
function NodeBase.IsMouseNearCurve(points, mouseX, mouseY, threshold)
    threshold = threshold or 10
    for i = 1, #points - 1 do
        local p1 = points[i]
        local p2 = points[i + 1]
        local dist = NodeBase.PointToLineDistance(mouseX, mouseY, p1.x, p1.y, p2.x, p2.y)
        if dist < threshold then
            return true
        end
    end
    return false
end

-- 计算点到线段的距离
function NodeBase.PointToLineDistance(px, py, x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local len2 = dx * dx + dy * dy
    if len2 == 0 then
        return math.sqrt((px - x1) ^ 2 + (py - y1) ^ 2)
    end
    local t = math.max(0, math.min(1, ((px - x1) * dx + (py - y1) * dy) / len2))
    local projX = x1 + t * dx
    local projY = y1 + t * dy
    return math.sqrt((px - projX) ^ 2 + (py - projY) ^ 2)
end

-- 确定连线颜色（统一使用浅蓝色）
function NodeBase.GetConnectionColor(fromNode, toNode)
    return Color(100, 200, 255)
end

-- 绘制连线
function NodeBase.DrawConnection(fromNode, toNode, fromPort, isHovered)
    local fromX, fromY = NodeBase.GetPortPosition(fromNode, "output", fromPort == "output2" and 2 or 1)
    local toX, toY = NodeBase.GetPortPosition(toNode, "input", 1)
    
    local distance = toX - fromX
    local controlPoint1X = fromX + distance / 3
    local controlPoint1Y = fromY
    local controlPoint2X = fromX + distance * 2 / 3
    local controlPoint2Y = toY
    
    local points = NodeBase.BezierCurve(fromX, fromY, controlPoint1X, controlPoint1Y, controlPoint2X, controlPoint2Y, toX, toY)
    local connectionColor = NodeBase.GetConnectionColor(fromNode, toNode)
    
    if isHovered then
        NodeBase.DrawThickCurve(points, Color(255, 255, 255), 4)
    end
    
    NodeBase.DrawThickCurve(points, connectionColor, 2)
end

-- 获取两个节点之间的连线点
function NodeBase.GetConnectionPoints(fromNode, toNode, fromPort)
    local fromX, fromY = NodeBase.GetPortPosition(fromNode, "output", fromPort == "output2" and 2 or 1)
    local toX, toY = NodeBase.GetPortPosition(toNode, "input", 1)
    
    local distance = toX - fromX
    local controlPoint1X = fromX + distance / 3
    local controlPoint1Y = fromY
    local controlPoint2X = fromX + distance * 2 / 3
    local controlPoint2Y = toY
    
    return NodeBase.BezierCurve(fromX, fromY, controlPoint1X, controlPoint1Y, controlPoint2X, controlPoint2Y, toX, toY)
end

-- 获取临时连线点（从节点到鼠标位置）
function NodeBase.GetTempConnectionPoints(fromNode, fromPort, mouseX, mouseY)
    local fromX, fromY = NodeBase.GetPortPosition(fromNode, "output", fromPort == "output2" and 2 or 1)
    
    local distance = mouseX - fromX
    local controlPoint1X = fromX + distance / 3
    local controlPoint1Y = fromY
    local controlPoint2X = fromX + distance * 2 / 3
    local controlPoint2Y = mouseY
    
    return NodeBase.BezierCurve(fromX, fromY, controlPoint1X, controlPoint1Y, controlPoint2X, controlPoint2Y, mouseX, mouseY)
end

-- 绘制临时连线
function NodeBase.DrawTempConnection(fromNode, fromPort, mouseX, mouseY)
    local points = NodeBase.GetTempConnectionPoints(fromNode, fromPort, mouseX, mouseY)
    local tempColor = NodeBase.GetConnectionColor(fromNode, fromNode)
    tempColor.a = 150
    
    surface.SetDrawColor(tempColor)
    for i = 1, #points - 1 do
        local p1 = points[i]
        local p2 = points[i + 1]
        local dx = p2.x - p1.x
        local dy = p2.y - p1.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0 then
            local nx = -dy / len
            local ny = dx / len
            for offset = -1, 1 do
                surface.DrawLine(p1.x + nx * offset, p1.y + ny * offset, p2.x + nx * offset, p2.y + ny * offset)
            end
        else
            surface.DrawLine(p1.x, p1.y, p2.x, p2.y)
        end
    end
end

-- 绘制临时节点预览
function NodeBase.DrawTempNode(template, x, y)
    surface.SetAlphaMultiplier(0.7)
    local nodeWidth = template and template.width or 200
    local nodeHeight = template and template.height or 80
    draw.RoundedBox(8, x, y, nodeWidth, nodeHeight, template.color)
    draw.RoundedBox(8, x + 2, y + 2, nodeWidth - 4, nodeHeight - 4, Color(60, 60, 60))
    draw.RoundedBox(4, x, y, nodeWidth, 24, Color(80, 80, 80))
    draw.SimpleText(template.name, "SourceHan_Heavy_14", x + 10, y + 12, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    surface.SetAlphaMultiplier(1)
end

-- 检测鼠标是否在某个输入端口上
function NodeBase.GetHoveredInputPort(node, mouseX, mouseY)
    if not node.hasInput then return nil end
    
    local portRadius = NodeBase.Config.portRadius
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    local inputPortX = nodeX - portRadius
    local inputPortY = nodeY + node.height / 2 - portRadius
    
    if NodeBase.IsMouseOverPort(inputPortX, inputPortY, mouseX, mouseY, portRadius, NodeBase.Config.clickRadius) then
        return "input"
    end
    
    return nil
end

-- 检测鼠标是否在某个输出端口上
function NodeBase.GetHoveredOutputPort(node, mouseX, mouseY)
    if not node.hasOutput then return nil end
    
    local portRadius = NodeBase.Config.portRadius
    
    if NodeBase.IsSpecialNode(node) then
        for i = 1, 2 do
            local portX, portY = NodeBase.GetPortPosition(node, "output", i)
            if NodeBase.IsMouseOverPort(portX - portRadius, portY - portRadius, mouseX, mouseY, portRadius, NodeBase.Config.clickRadius) then
                return "output" .. i
            end
        end
    else
        local portX, portY = NodeBase.GetPortPosition(node, "output", 1)
        if NodeBase.IsMouseOverPort(portX - portRadius, portY - portRadius, mouseX, mouseY, portRadius, NodeBase.Config.clickRadius) then
            return "output"
        end
    end
    
    return nil
end

-- 检测节点选择器相关
function NodeBase.IsInNodeSelector(mouseX, mouseY, win, selectorX, selectorY, selectorW, selectorH)
    return mouseX >= selectorX and mouseX <= selectorX + selectorW and
           mouseY >= selectorY and mouseY <= selectorY + selectorH
end

-- 获取当前正在拖动节点是否在节点选择器区域
function NodeBase.IsNodeInSelector(nodeX, nodeY, win, selectorX, selectorY, selectorW, selectorH)
    local nodeWidth = node.width or 200
    local nodeHeight = node.height or 80
    return nodeX >= selectorX and nodeX + nodeWidth <= selectorX + selectorW and
           nodeY >= selectorY and nodeY + nodeHeight <= selectorY + selectorH
end

-- 检查连接是否有效
function NodeBase.ValidateConnection(fromNode, toNode, editorMode)
    if fromNode.id == toNode.id then
        return false, "同一个节点上不能连接两点！"
    end
    
    if toNode.type == "event_monitor" then
        if not fromNode.isStartNode then
            return false, "事件监测节点只能连接到开始点！"
        end
        
        if editorMode == "unit" then
            if fromNode.title ~= "在场" then
                return false, "单位模式下，事件监测节点只能连接到「在场」开始点！"
            end
        elseif editorMode == "command" then
            if fromNode.title ~= "打出" then
                return false, "指令模式下，事件监测节点只能连接到「打出」开始点！"
            end
        elseif editorMode == "counter_command" then
            if fromNode.title ~= "激活时" then
                return false, "反制指令模式下，事件监测节点只能连接到「激活时」开始点！"
            end
        end
    end
    
    return true, ""
end

-- 检查两个节点之间是否已经存在连接
function NodeBase.ConnectionExists(connections, fromNodeId, toNodeId, fromPort)
    for _, conn in ipairs(connections) do
        if conn.fromNode == fromNodeId and conn.toNode == toNodeId and conn.fromPort == fromPort then
            return true
        end
    end
    return false
end

-- 从连接列表中删除连接
function NodeBase.RemoveConnectionsFromNode(connections, nodeId)
    local newConnections = {}
    for _, conn in ipairs(connections) do
        if conn.fromNode ~= nodeId and conn.toNode ~= nodeId then
            table.insert(newConnections, conn)
        end
    end
    return newConnections
end

-- 从节点列表中获取指定ID的节点
function NodeBase.GetNodeById(nodes, nodeId)
    for _, node in ipairs(nodes) do
        if node.id == nodeId then
            return node
        end
    end
    return nil
end

-- 从节点列表中删除指定ID的节点
function NodeBase.RemoveNodeById(nodes, nodeId)
    for i = #nodes, 1, -1 do
        if nodes[i].id == nodeId then
            return table.remove(nodes, i)
        end
    end
    return nil
end

-- 获取所有与指定节点相连的连接
function NodeBase.GetConnectionsForNode(connections, nodeId)
    local nodeConnections = {}
    for _, conn in ipairs(connections) do
        if conn.fromNode == nodeId or conn.toNode == nodeId then
            table.insert(nodeConnections, conn)
        end
    end
    return nodeConnections
end

-- 清除空连接
function NodeBase.CleanupInvalidConnections(connections, nodes)
    local validConnections = {}
    for _, conn in ipairs(connections) do
        local fromNode = NodeBase.GetNodeById(nodes, conn.fromNode)
        local toNode = NodeBase.GetNodeById(nodes, conn.toNode)
        if fromNode and toNode then
            table.insert(validConnections, conn)
        end
    end
    return validConnections
end

-- 初始化节点数据
function NodeBase.EnsureNodeData(node)
    node.data = node.data or {}
    return node
end

-- 节点序列化
function NodeBase.SerializeNode(node)
    return {
        id = node.id,
        type = node.type,
        title = node.title,
        x = node.x,
        y = node.y,
        color = node.color,
        width = node.width,
        height = node.height,
        hasInput = node.hasInput,
        hasOutput = node.hasOutput,
        hasSecondOutput = node.hasSecondOutput or false,
        isStartNode = node.isStartNode,
        data = node.data or {}
    }
end

-- 节点反序列化
function NodeBase.DeserializeNode(data)
    local node = {
        id = data.id,
        type = data.type,
        title = data.title,
        x = data.x,
        y = data.y,
        color = data.color,
        width = data.width or 200,
        height = data.height or 80,
        hasInput = data.hasInput,
        hasOutput = data.hasOutput,
        hasSecondOutput = data.hasSecondOutput or false,
        isStartNode = data.isStartNode or false,
        data = data.data or {},
        dragging = false,
        dragStartX = 0,
        dragStartY = 0,
        startX = 0,
        startY = 0
    }
    return node
end

-- 创建连接数据结构
function NodeBase.CreateConnectionData(fromNodeId, toNodeId, fromPort, connectionCounter)
    connectionCounter = connectionCounter or 0
    return {
        id = "conn_" .. connectionCounter,
        fromNode = fromNodeId,
        toNode = toNodeId,
        fromPort = fromPort or "output"
    }
end

-- 连接序列化
function NodeBase.SerializeConnection(conn)
    return {
        id = conn.id,
        fromNode = conn.fromNode,
        toNode = conn.toNode,
        fromPort = conn.fromPort
    }
end

-- 连接反序列化
function NodeBase.DeserializeConnection(data)
    return {
        id = data.id,
        fromNode = data.fromNode,
        toNode = data.toNode,
        fromPort = data.fromPort
    }
end

-- 完整图表序列化
function NodeBase.SerializeGraph(nodes, connections)
    local serializedNodes = {}
    for _, node in ipairs(nodes) do
        table.insert(serializedNodes, NodeBase.SerializeNode(node))
    end
    
    local serializedConnections = {}
    for _, conn in ipairs(connections) do
        table.insert(serializedConnections, NodeBase.SerializeConnection(conn))
    end
    
    return {
        nodes = serializedNodes,
        connections = serializedConnections
    }
end

-- 完整图表反序列化
function NodeBase.DeserializeGraph(data, nodeCounter)
    nodeCounter = nodeCounter or 0
    local nodes = {}
    for _, nodeData in ipairs(data.nodes) do
        local node = NodeBase.DeserializeNode(nodeData)
        table.insert(nodes, node)
        local num = tonumber(node.id:match("node_(%d+)"))
        if num and num > nodeCounter then
            nodeCounter = num
        end
    end
    
    local connections = {}
    for _, connData in ipairs(data.connections) do
        table.insert(connections, NodeBase.DeserializeConnection(connData))
    end
    
    return nodes, connections, nodeCounter
end

-- 复制节点及其数据
function NodeBase.CloneNode(node, offsetX, offsetY, nodeCounter)
    offsetX = offsetX or 20
    offsetY = offsetY or 20
    nodeCounter = nodeCounter or 0
    
    local clonedNode = {
        id = "node_" .. (nodeCounter + 1),
        type = node.type,
        title = node.title,
        x = node.x + offsetX,
        y = node.y + offsetY,
        color = node.color,
        width = node.width or 200,
        height = node.height or 80,
        hasInput = node.hasInput,
        hasOutput = node.hasOutput,
        hasSecondOutput = node.hasSecondOutput or false,
        isStartNode = node.isStartNode or false,
        data = table.Copy(node.data) or {},
        dragging = false,
        dragStartX = 0,
        dragStartY = 0,
        startX = 0,
        startY = 0
    }
    
    return clonedNode, nodeCounter + 1
end

-- 初始化选择状态
function NodeBase.CreateSelectionState()
    return {
        selectedNodes = {},
        isSelecting = false,
        selectionStartX = 0,
        selectionStartY = 0,
        selectionEndX = 0,
        selectionEndY = 0
    }
end

-- 检查节点是否在选择框内
function NodeBase.IsNodeInSelection(node, startX, startY, endX, endY)
    local minX = math.min(startX, endX)
    local minY = math.min(startY, endY)
    local maxX = math.max(startX, endX)
    local maxY = math.max(startY, endY)
    
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    
    return nodeX >= minX and nodeX + node.width <= maxX and
           nodeY >= minY and nodeY + node.height <= maxY
end

-- 从列表中选择节点并添加到选择状态
function NodeBase.SelectNode(selectionState, node)
    if not table.HasValue(selectionState.selectedNodes, node) then
        table.insert(selectionState.selectedNodes, node)
    end
end

-- 从选择状态中取消选择节点
function NodeBase.DeselectNode(selectionState, node)
    for i = #selectionState.selectedNodes, 1, -1 do
        if selectionState.selectedNodes[i] == node then
            table.remove(selectionState.selectedNodes, i)
            break
        end
    end
end

-- 清除所有选择
function NodeBase.ClearSelection(selectionState)
    selectionState.selectedNodes = {}
end

-- 检查节点是否被选中
function NodeBase.IsNodeSelected(selectionState, node)
    for _, selectedNode in ipairs(selectionState.selectedNodes) do
        if selectedNode == node then
            return true
        end
    end
    return false
end

-- 绘制开始点节点
function NodeBase.DrawStartNode(node)
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    local nodeHeight = node.height
    local portY = nodeY + node.height / 2
    local textX = nodeX + 120
    local textY = portY
    
    draw.SimpleText(node.title, "SourceHan_Heavy_36", textX + 2, textY + 2, Color(0, 0, 0, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    draw.SimpleText(node.title, "SourceHan_Heavy_36", textX, textY, Color(160, 160, 160), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    
    if node.hasOutput then
        local portRadius = 6
        local clickRadius = 12
        local outputPortX = nodeX + node.width - portRadius
        local outputPortY = portY - portRadius
        local isPortHovered = mouseX >= outputPortX - (clickRadius - portRadius) and mouseX <= outputPortX + portRadius * 2 + (clickRadius - portRadius) and
                             mouseY >= outputPortY - (clickRadius - portRadius) and mouseY <= outputPortY + portRadius * 2 + (clickRadius - portRadius)
        
        surface.SetDrawColor(isPortHovered and Color(255, 255, 255) or Color(150, 50, 50))
        surface.DrawOutlinedRect(outputPortX - 2, outputPortY - 2, portRadius * 2 + 4, portRadius * 2 + 4)
        draw.RoundedBox(portRadius, outputPortX, outputPortY, portRadius * 2, portRadius * 2, Color(255, 100, 100))
    end
end

-- 配置解析缓存
NodeBase.ConfigCache = {}

--[[
特殊文本格式语法说明:
1. 输入数据类型定义（可选，放在开头）:
   - n: 数字
   - p: 布尔值
   - t: 字符串
   - g: 数组
   - e: 卡牌对象
   - f: 节点函数
   - 示例: nptg{...} 表示支持数字、布尔值、字符串、数组输入
   
2. 组件定义:
   - '文本': 固定文本组件
   - {选项1、选项2、选项3}: 单选组件
   - []: 数字输入组件
   
3. 条件分支:
   - if 条件 then ... elseif 条件 then ... else ... end
   
4. 输出数据类型定义（可选）:
   - (选项1、选项2): 多选数据类型，使用、分隔
   - 每个选项以数据类型标识符开头（n/p/t/g/e/f）
   - 示例: (n数字、p布尔值、t字符串)
]]
-- 解析输入数据类型标识符（开头的 n/p/t/g/e/f 字符）
function NodeBase.ParseInputTypes(str, startPos, len)
    local inputTypes = {}
    local i = startPos
    
    while i <= len do
        local char = str:sub(i, i)
        if char == "n" or char == "p" or char == "t" or char == "g" or char == "e" or char == "f" then
            local dataType = NodeBase.GetDataTypeById(char)
            if dataType then
                table.insert(inputTypes, dataType)
            end
            i = i + 1
        else
            break
        end
    end
    
    return inputTypes, i
end

-- 解析文本组件（单引号包裹）
function NodeBase.ParseTextComponent(str, startPos, len, componentId)
    local j = startPos + 1
    while j <= len and str:sub(j, j) ~= "'" do
        j = j + 1
    end
    local text = str:sub(startPos + 1, j - 1)
    
    if text ~= "" then
        componentId = componentId + 1
        return {
            type = "text",
            id = "text_" .. componentId,
            text = text
        }, j + 1, componentId
    end
    
    return nil, j + 1, componentId
end

-- 解析下拉选项组件（花括号包裹）
function NodeBase.ParseSelectComponent(str, startPos, len, componentId)
    local j = startPos + 1
    while j <= len and str:sub(j, j) ~= "}" do
        j = j + 1
    end
    local optionsStr = str:sub(startPos + 1, j - 1)
    local options = {}
    for opt in string.gmatch(optionsStr, "([^、]+)") do
        table.insert(options, opt)
    end
    
    if #options > 0 then
        componentId = componentId + 1
        return {
            type = "select",
            id = "select_" .. componentId,
            options = options
        }, j + 1, componentId
    end
    
    return nil, j + 1, componentId
end

-- 解析数字输入组件（方括号包裹）
function NodeBase.ParseNumberComponent(str, startPos, len, componentId)
    local j = startPos + 1
    while j <= len and str:sub(j, j) ~= "]" do
        j = j + 1
    end
    
    componentId = componentId + 1
    return {
        type = "number",
        id = "number_" .. componentId
    }, j + 1, componentId
end

-- 解析输出类型定义（圆括号包裹）
function NodeBase.ParseOutputTypes(str, startPos, len)
    local j = startPos + 1
    while j <= len and str:sub(j, j) ~= ")" do
        j = j + 1
    end
    local optionsStr = str:sub(startPos + 1, j - 1)
    local newOutputTypes = {}
    
    for opt in string.gmatch(optionsStr, "([^、]+)") do
        local firstChar = opt:sub(1, 1)
        local dataType = NodeBase.GetDataTypeById(firstChar)
        if dataType then
            local displayName = opt:sub(2)
            if displayName == "" then
                displayName = dataType.name
            end
            table.insert(newOutputTypes, {
                id = dataType.id,
                name = displayName,
                color = dataType.color,
                shape = dataType.shape
            })
        end
    end
    
    return newOutputTypes, j + 1
end

-- 解析条件分支组件（if/elseif/else/end）
function NodeBase.ParseConditionalComponent(str, startPos, len, componentId)
    local depth = 1
    local j = startPos + 2
    local branches = {}
    
    -- 解析第一个 if 条件
    local condStart = j
    while j <= len and not (str:sub(j, j + 3) == "then") do
        j = j + 1
    end
    local condition = str:sub(condStart, j - 1)
    condition = condition:gsub("^%s+", ""):gsub("%s+$", "")
    j = j + 4
    
    local currentBranch = {
        condition = condition,
        content = ""
    }
    
    -- 解析所有分支
    while j <= len and depth > 0 do
        local sub = str:sub(j, j + 5)
        if sub == "elseif" then
            table.insert(branches, currentBranch)
            depth = depth + 1
            local eiStart = j + 6
            while j <= len and not (str:sub(j, j + 3) == "then") do
                j = j + 1
            end
            condition = str:sub(eiStart, j - 1)
            condition = condition:gsub("^%s+", ""):gsub("%s+$", "")
            currentBranch = {
                condition = condition,
                content = ""
            }
            j = j + 4
        elseif sub:sub(1, 4) == "else" then
            table.insert(branches, currentBranch)
            currentBranch = {
                condition = "else",
                content = ""
            }
            j = j + 4
        elseif str:sub(j, j + 2) == "end" then
            depth = depth - 1
            if depth == 0 then
                table.insert(branches, currentBranch)
                break
            end
            currentBranch.content = currentBranch.content .. "end"
            j = j + 3
        else
            currentBranch.content = currentBranch.content .. str:sub(j, j)
            j = j + 1
        end
    end
    
    -- 递归解析每个分支的内容
    componentId = componentId + 1
    local ifComp = {
        type = "if",
        id = "if_" .. componentId,
        branches = {}
    }
    
    local outputTypes = {}
    for _, branch in ipairs(branches) do
        local branchResult = NodeBase.ParseConfig(branch.content)
        table.insert(ifComp.branches, {
            condition = branch.condition,
            components = branchResult.components
        })
        if #branchResult.outputTypes > 0 then
            outputTypes = branchResult.outputTypes
        end
    end
    
    return ifComp, j + 1, componentId, outputTypes
end

-- 解析配置字符串为主函数
function NodeBase.ParseConfig(configString)
    if not configString or configString == "" then
        return {
            components = {},
            inputTypes = {},
            outputTypes = {}
        }
    end
    
    -- 检查缓存
    if NodeBase.ConfigCache[configString] then
        if type(NodeBase.ConfigCache[configString]) == "table" and not NodeBase.ConfigCache[configString].components then
            return {
                components = NodeBase.ConfigCache[configString],
                inputTypes = {},
                outputTypes = {}
            }
        end
        return NodeBase.ConfigCache[configString]
    end
    
    local components = {}
    local inputTypes = {}
    local outputTypes = {}
    local str = configString:gsub("\n", " "):gsub("\r", " ")
    local i = 1
    local len = #str
    local componentId = 0
    
    -- 跳过开头的空白字符
    while i <= len and str:sub(i, i):match("%s") do
        i = i + 1
    end
    
    -- 1. 解析开头的输入数据类型
    inputTypes, i = NodeBase.ParseInputTypes(str, i, len)
    
    -- 2. 解析剩余的组件
    while i <= len do
        local char = str:sub(i, i)
        local component = nil
        
        if char == "'" then
            component, i, componentId = NodeBase.ParseTextComponent(str, i, len, componentId)
        elseif char == "{" then
            component, i, componentId = NodeBase.ParseSelectComponent(str, i, len, componentId)
        elseif char == "[" then
            component, i, componentId = NodeBase.ParseNumberComponent(str, i, len, componentId)
        elseif char == "(" then
            outputTypes, i = NodeBase.ParseOutputTypes(str, i, len)
        elseif char == "i" and str:sub(i, i + 1) == "if" then
            local branchOutputTypes
            component, i, componentId, branchOutputTypes = NodeBase.ParseConditionalComponent(str, i, len, componentId)
            if #branchOutputTypes > 0 then
                outputTypes = branchOutputTypes
            end
        elseif char:match("%s") then
            i = i + 1
        else
            i = i + 1
        end
        
        if component then
            table.insert(components, component)
        end
    end
    
    local result = {
        components = components,
        inputTypes = inputTypes,
        outputTypes = outputTypes
    }
    
    NodeBase.ConfigCache[configString] = result
    return result
end

-- 获取文本宽度
function NodeBase.GetTextWidth(text, font)
    font = font or "SourceHan_Heavy_14"
    surface.SetFont(font)
    local w, _ = surface.GetTextSize(text)
    return w
end

-- 计算组件尺寸
function NodeBase.CalculateSize(components, nodeData)
    local padding = 20
    local minWidth = 200
    local minHeight = 80
    
    local maxX = padding
    local selectIndex = 0
    
    local function processCompList(compList, data)
        local cx = padding
        local mx = maxX
        
        for _, comp in ipairs(compList) do
            if comp.type == "text" then
                local w = NodeBase.GetTextWidth(comp.text)
                cx = cx + w + 5
                mx = math.max(mx, cx)
            elseif comp.type == "select" then
                selectIndex = selectIndex + 1
                local maxOptW = 0
                for _, opt in ipairs(comp.options) do
                    maxOptW = math.max(maxOptW, NodeBase.GetTextWidth(opt))
                end
                local w = maxOptW + 30
                cx = cx + w + 5
                mx = math.max(mx, cx)
            elseif comp.type == "number" then
                local w = 40
                cx = cx + w + 5
                mx = math.max(mx, cx)
            elseif comp.type == "if" then
                local selectedValue = nil
                for idx = #compList, 1, -1 do
                    local c = compList[idx]
                    if c.type == "select" then
                        local dataKey = c.id
                        if data and data[dataKey] then
                            selectedValue = c.options[data[dataKey]] or c.options[1]
                        else
                            selectedValue = c.options[1]
                        end
                        break
                    end
                end
                
                local branchMaxW = 0
                for _, branch in ipairs(comp.branches) do
                    local savedMX = mx
                    local savedCX = cx
                    mx = padding
                    cx = padding
                    processCompList(branch.components, data)
                    branchMaxW = math.max(branchMaxW, mx)
                    mx = savedMX
                    cx = savedCX
                end
                cx = cx + branchMaxW - padding + 5
                mx = math.max(mx, cx)
            end
        end
        
        maxX = math.max(maxX, mx)
    end
    
    processCompList(components, nodeData)
    
    local width = math.max(minWidth, maxX + padding)
    local height = minHeight
    
    return width, height
end

-- 初始化节点数据
function NodeBase.InitNodeData(components, nodeData)
    nodeData = nodeData or {}
    local selectIndex = 0
    
    local function processCompList(compList, data)
        for _, comp in ipairs(compList) do
            if comp.type == "select" then
                selectIndex = selectIndex + 1
                if not data[comp.id] then
                    data[comp.id] = 1
                end
            elseif comp.type == "number" then
                if not data[comp.id] then
                    data[comp.id] = 0
                end
            elseif comp.type == "if" then
                for _, branch in ipairs(comp.branches) do
                    processCompList(branch.components, data)
                end
            end
        end
    end
    
    processCompList(components, nodeData)
    return nodeData
end

-- 绘制节点内容
function NodeBase.DrawNodeContent(node)
    if node.isStartNode then
        return
    end
    
    local nodeX, nodeY = NodeBase.GetScreenPosition(node)
    local template = nil
    
    for _, tpl in ipairs(KARDS.CardEditor.Canvas.Templates) do
        if tpl.type == node.type then
            template = tpl
            break
        end
    end
    
    if not template or not template.config then
        return
    end
    
    local configResult = NodeBase.ParseConfig(template.config)
    local components = configResult.components or configResult
    NodeBase.DrawComponents(nodeX + 20, nodeY + 40, components, node.data, node)
end

-- 绘制组件
function NodeBase.DrawComponents(startX, startY, components, nodeData, node)
    local x = startX
    local y = startY
    local spacing = 5
    local selectIndices = {}
    local currentSelectIdx = 0
    
    local function processCompList(compList, data)
        local cx = x
        local cy = y
        
        for _, comp in ipairs(compList) do
            if comp.type == "text" then
                draw.SimpleText(comp.text, "SourceHan_Heavy_14", cx, cy + 8, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local w = NodeBase.GetTextWidth(comp.text)
                cx = cx + w + spacing
            elseif comp.type == "select" then
                currentSelectIdx = currentSelectIdx + 1
                table.insert(selectIndices, comp)
                local maxOptW = 0
                for _, opt in ipairs(comp.options) do
                    maxOptW = math.max(maxOptW, NodeBase.GetTextWidth(opt))
                end
                local w = maxOptW + 30
                local selectedIdx = data[comp.id] or 1
                KARDS.CardEditor.Canvas.DrawDropdown(cx, cy, w, 20, comp.options, selectedIdx, node, comp.id)
                cx = cx + w + spacing
            elseif comp.type == "number" then
                local val = data[comp.id] or 0
                KARDS.CardEditor.Canvas.DrawNumberBox(cx, cy - 3, 40, val, node, comp.id)
                cx = cx + 40 + spacing
            elseif comp.type == "if" then
                local selectedValue = nil
                for idx = #selectIndices, 1, -1 do
                    local selComp = selectIndices[idx]
                    if data[selComp.id] then
                        selectedValue = selComp.options[data[selComp.id]] or selComp.options[1]
                        break
                    end
                end
                
                if selectedValue then
                    for _, branch in ipairs(comp.branches) do
                        local cond = branch.condition
                        local matches = false
                        if cond == "else" then
                            matches = true
                        elseif selectedValue == cond then
                            matches = true
                        end
                        
                        if matches then
                            local savedX = cx
                            local savedY = cy
                            local savedSelects = {unpack(selectIndices)}
                            local savedSelIdx = currentSelectIdx
                            x = cx
                            y = cy
                            processCompList(branch.components, data)
                            cx = x
                            cy = y
                            selectIndices = savedSelects
                            currentSelectIdx = savedSelIdx
                            break
                        end
                    end
                end
            end
        end
        
        x = cx
        y = cy
    end
    
    processCompList(components, nodeData)
end
