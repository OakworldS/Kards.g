--[[
=======================================================================================
输入处理系统 (Input Handling System)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的子系统，负责画布编辑器的所有输入事件处理。

包含功能：
  - HandleInput（主输入处理函数）
  - CheckNodeSelectorClick（检查节点选择器点击）
  - CheckPortClick（检查端口点击）
  - CheckTabClick（检查标签页点击）
  - CheckNodeDragStart（检查节点拖拽开始）
  - FinishTempNode（完成临时节点创建）
  - FinishTempConnection（完成临时连接创建）
  - CreateNode（创建节点）
  - CreateConnection（创建连接）
  - GetNodeById（按ID获取节点）
  - DeleteSelectedNodes（删除选中节点）
  - DrawContextMenu（绘制右键菜单）
  - DrawTabs（绘制标签页）
  - DrawToggleButton（绘制自定义切换按钮）
  - DarkenColor（颜色变暗函数）

源文件：cl_canvas_editor.lua
  - HandleInput：行 4200~4989
  - CheckNodeSelectorClick：行 4991~5030
  - CheckPortClick：行 5032~5125
  - CheckTabClick：行 5127~5145
  - CheckNodeDragStart：行 5147~5176
  - FinishTempNode：行 5178~5204
  - FinishTempConnection：行 5206~5325
  - CreateNode：行 5327~5333
  - CreateConnection：行 5335~5358
  - GetNodeById：行 5360~5362
  - DeleteSelectedNodes：行 5364~5415
  - DrawContextMenu：行 5417~5433
  - DrawTabs：行 5435~5459
  - DrawToggleButton：行 5462~5469
  - DarkenColor：行 5473~5475
=======================================================================================
]]

-- 防御性命名空间初始化：确保即使本文件在 GMod 自动加载阶段先于
-- sh_card_editor_loader.lua 被加载，KARDS.CardEditor.Canvas 也已就绪
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}
KARDS.CardEditor.Audio = KARDS.CardEditor.Audio or {}

-- HandleInput 已迁移至 cl_canvas_editor.lua（拆分为 13 个局部函数）
-- 此文件保留其余辅助函数（CheckNodeSelectorClick, CheckPortClick 等）

function KARDS.CardEditor.Canvas.CheckNodeSelectorClick(mouseX, mouseY)
    local win = KARDS.CardEditor.Canvas.Window

    local contentX = win.x + 5
    local contentY = win.y + 75 -- 与DrawEditor中的contentY一致
    local contentW = win.width - 10
    local contentH = win.height - 80
    local selectorW = 180

    if mouseX >= contentX and mouseX <= contentX + selectorW and
       mouseY >= contentY and mouseY <= contentY + contentH then

        local templateY = contentY + 60
        for i, template in ipairs(KARDS.CardEditor.Canvas.Templates) do
            local templateH = 50
            if mouseX >= contentX + 10 and mouseX <= contentX + selectorW - 10 and
               mouseY >= templateY and mouseY <= templateY + templateH then

                KARDS.CardEditor.Canvas.TempNode = {
                    template = template,
                    x = mouseX - 100,
                    y = mouseY - 40
                }

                return true
            end
            templateY = templateY + templateH + 10
        end
    end

    return false
end

function KARDS.CardEditor.Canvas.CheckPortClick(mouseX, mouseY)
    local win = KARDS.CardEditor.Canvas.Window
    local contentX = win.x + 5
    local contentY = win.y + 45
    local selectorW = 180
    local nodeEditorX = contentX + selectorW

    -- 检查所有节点的输出端口点击（包括开始点节点）
    for i = #KARDS.CardEditor.Canvas.Nodes, 1, -1 do
        local node = KARDS.CardEditor.Canvas.Nodes[i]
        -- 开始点节点特殊处理
        if node.isStartNode then
            local nodeX = win.x + node.x
            local nodeY = win.y + node.y
            local portRadius = 6
            local clickRadius = 12
            local nodeHeight = node.height
            local portY = nodeY + nodeHeight / 2
            local outputPortX = nodeX + node.width - portRadius
            local outputPortY = portY - portRadius
            
            if mouseX >= outputPortX - (clickRadius - portRadius) and mouseX <= outputPortX + portRadius * 2 + (clickRadius - portRadius) and
               mouseY >= outputPortY - (clickRadius - portRadius) and mouseY <= outputPortY + portRadius * 2 + (clickRadius - portRadius) then
                KARDS.CardEditor.Canvas.TempConnection = {
                    fromNode = node.id,
                    fromPort = "output"
                }
                return true
            end
        else
            local nodeX = nodeEditorX + node.x
            local nodeY = win.y + node.y
            local portRadius = 8
            local clickRadius = 12
            
            -- 检查是否点击在输入端口上（输入点只能被连接，不能主动连接）
            if node.hasInput and not KARDS.CardEditor.Canvas.TempConnection then
                local portY = nodeY + node.height / 2
                local inputPortX = nodeX - portRadius
                if mouseX >= inputPortX - clickRadius and mouseX <= inputPortX + clickRadius and
                   mouseY >= portY - clickRadius and mouseY <= portY + clickRadius then
                    local currentTime = SysTime()
                    if not KARDS.CardEditor.Canvas.LastInputPortClickTime or currentTime - KARDS.CardEditor.Canvas.LastInputPortClickTime > 0.5 then
                        KARDS.CardEditor.Canvas.LastInputPortClickTime = currentTime
                    end
                    return false
                end
            end

            if node.hasOutput then
                -- 特殊处理具有双输出端口的节点（condition、event_monitor和loop）
                if node.type == "condition" or node.type == "event_monitor" or node.type == "loop" then
                    -- 第一个输出端口（满足/循环内）
                    local portY1 = nodeY + node.height / 3
                    local portX1 = nodeX + node.width - portRadius
                    if mouseX >= portX1 - clickRadius and mouseX <= portX1 + clickRadius and
                       mouseY >= portY1 - clickRadius and mouseY <= portY1 + clickRadius then
                        KARDS.CardEditor.Canvas.TempConnection = {
                            fromNode = node.id,
                            fromPort = "output1"
                        }
                        return true
                    end
                    
                    -- 第二个输出端口（不满足/结束循环后）
                    local portY2 = nodeY + node.height * 2 / 3
                    local portX2 = nodeX + node.width - portRadius
                    if mouseX >= portX2 - clickRadius and mouseX <= portX2 + clickRadius and
                       mouseY >= portY2 - clickRadius and mouseY <= portY2 + clickRadius then
                        KARDS.CardEditor.Canvas.TempConnection = {
                            fromNode = node.id,
                            fromPort = "output2"
                        }
                        return true
                    end
                else
                    -- 普通节点的输出端口
                    local portY = nodeY + node.height / 2
                    local portX = nodeX + node.width - portRadius
                    if mouseX >= portX - clickRadius and mouseX <= portX + clickRadius and
                       mouseY >= portY - clickRadius and mouseY <= portY + clickRadius then
                        KARDS.CardEditor.Canvas.TempConnection = {
                            fromNode = node.id,
                            fromPort = "output"
                        }
                        return true
                    end
                end
            end
        end
    end

    return false
end

function KARDS.CardEditor.Canvas.CheckTabClick(mouseX, mouseY)
    local win = KARDS.CardEditor.Canvas.Window
    local tabX = win.x
    local tabY = win.y + 40 -- 标题栏下方
    
    for i, tab in ipairs(KARDS.CardEditor.Canvas.Tabs) do
        -- 新的标签页尺寸：宽120，高30
        if mouseX >= tabX and mouseX <= tabX + 120 and
           mouseY >= tabY and mouseY <= tabY + 30 then
            KARDS.CardEditor.Canvas.CurrentPage = tab.id
            -- 播放展开音效
            KARDS.CardEditor.Audio.PlayExpand()
            return true
        end
        tabX = tabX + 120 + 10
    end
    
    return false
end

function KARDS.CardEditor.Canvas.CheckNodeDragStart(mouseX, mouseY)
    local win = KARDS.CardEditor.Canvas.Window

    local contentX = win.x + 5
    local contentY = win.y + 75
    local selectorW = 180
    local nodeEditorX = contentX + selectorW

    for i = #KARDS.CardEditor.Canvas.Nodes, 1, -1 do
        local node = KARDS.CardEditor.Canvas.Nodes[i]
        
        if not node.isStartNode then
            local nodeX = nodeEditorX + node.x
            local nodeY = win.y + node.y

            if mouseX >= nodeX and mouseX <= nodeX + node.width and
               mouseY >= nodeY and mouseY <= nodeY + 24 then
                node.dragging = true
                node.dragStartX = mouseX
                node.dragStartY = mouseY
                node.startX = node.x
                node.startY = node.y
                KARDS.CardEditor.Canvas.DraggingNode = node
                return true
            end
        end
    end

    return false
end

function KARDS.CardEditor.Canvas.FinishTempNode(mouseX, mouseY)
    local win = KARDS.CardEditor.Canvas.Window

    local contentX = win.x + 5
    local contentY = win.y + 45
    local contentW = win.width - 10
    local contentH = win.height - 50
    local selectorW = 180

    local nodeEditorX = contentX + selectorW
    local nodeEditorW = contentW - selectorW

    if mouseX >= nodeEditorX and mouseX <= nodeEditorX + nodeEditorW and
       mouseY >= contentY and mouseY <= contentY + contentH then
        local nodeX = mouseX - nodeEditorX - 100 + 80
        local nodeY = mouseY - contentY - 40 + 30

        nodeX = math.max(0, math.min(nodeX, nodeEditorW - 200))
        nodeY = math.max(0, math.min(nodeY, contentH - 80))

        local template = KARDS.CardEditor.Canvas.TempNode.template
        KARDS.CardEditor.Canvas.CreateNode(nodeX, nodeY, template.type, template.name, template.color, template.hasInput, template.hasOutput, template)
        KARDS.CardEditor.Audio.PlayDragNewNode()
    end

    KARDS.CardEditor.Canvas.TempNode = nil
end

function KARDS.CardEditor.Canvas.FinishTempConnection(mouseX, mouseY)
    local win = KARDS.CardEditor.Canvas.Window

    local contentX = win.x + 5
    local contentY = win.y + 45
    local selectorW = 180
    local nodeEditorX = contentX + selectorW

    local conn = KARDS.CardEditor.Canvas.TempConnection
    local fromNodeId = conn and conn.fromNode or "nil"

    for i = #KARDS.CardEditor.Canvas.Nodes, 1, -1 do
        local node = KARDS.CardEditor.Canvas.Nodes[i]

        local nodeX = nodeEditorX + node.x
        local nodeY = win.y + node.y
        local portRadius = 6
        local clickRadius = 12
        local nodeHeight = node.height
        local portY = nodeY + nodeHeight / 2

        -- 检查是否点击在输出端口上（尝试将输出点连接到输出点）
        if node.hasOutput then
            if node.isStartNode then
                -- 开始点节点的输出端口
                local outputPortX = win.x + node.x + node.width - portRadius
                local outputPortY = win.y + node.y + node.height / 2
                if mouseX >= outputPortX - clickRadius and mouseX <= outputPortX + clickRadius and
                   mouseY >= outputPortY - clickRadius and mouseY <= outputPortY + clickRadius then
                    KARDS.CardEditor.Canvas.TempConnection = nil
                    return
                end
            elseif node.type == "condition" then
                -- 检查判断节点的两个输出端口
                local outputPortX1 = nodeX + node.width - portRadius
                local outputPortY1 = nodeY + node.height / 3
                if mouseX >= outputPortX1 - clickRadius and mouseX <= outputPortX1 + clickRadius and
                   mouseY >= outputPortY1 - clickRadius and mouseY <= outputPortY1 + clickRadius then
                    KARDS.CardEditor.Canvas.TempConnection = nil
                    return
                end
                local outputPortX2 = nodeX + node.width - portRadius
                local outputPortY2 = nodeY + node.height * 2 / 3
                if mouseX >= outputPortX2 - clickRadius and mouseX <= outputPortX2 + clickRadius and
                   mouseY >= outputPortY2 - clickRadius and mouseY <= outputPortY2 + clickRadius then
                    KARDS.CardEditor.Canvas.TempConnection = nil
                    return
                end
            else
                -- 普通节点的输出端口
                local outputPortX = nodeX + node.width - portRadius
                local outputPortY = nodeY + node.height / 2
                if mouseX >= outputPortX - clickRadius and mouseX <= outputPortX + clickRadius and
                   mouseY >= outputPortY - clickRadius and mouseY <= outputPortY + clickRadius then
                    KARDS.CardEditor.Canvas.TempConnection = nil
                    return
                end
            end
        end

        -- 检查是否点击在输入端口上
        if node.hasInput then
            local detectionY1 = portY - clickRadius
            local detectionY2 = portY + clickRadius
            local inputPortX = nodeX - portRadius
            local detectionX1 = inputPortX - (clickRadius - portRadius)
            local detectionX2 = inputPortX + portRadius * 2 + (clickRadius - portRadius)
            if mouseX >= detectionX1 and mouseX <= detectionX2 and
               mouseY >= detectionY1 and mouseY <= detectionY2 then
                -- 检查是否是同一个节点
                if node.id == fromNodeId then
                    KARDS.CardEditor.Canvas.TempConnection = nil
                    return
                end
                
                -- 如果目标节点是事件监测节点，检查连接规则
                if node.type == "event_monitor" then
                    local fromNode = KARDS.CardEditor.Canvas.GetNodeById(fromNodeId)
                    local isValid = true
                    local errorMsg = ""
                    
                    -- 检查是否是开始节点
                    if not fromNode or not fromNode.isStartNode then
                        isValid = false
                        errorMsg = "事件监测节点只能连接到开始点！"
                    else
                        -- 根据当前模式检查开始点类型
                        if KARDS.CardEditor.Canvas.EditorMode == "unit" then
                            if fromNode.title ~= "在场" then
                                isValid = false
                                errorMsg = "单位模式下，事件监测节点只能连接到「在场」开始点！"
                            end
                        elseif KARDS.CardEditor.Canvas.EditorMode == "command" then
                            if fromNode.title ~= "打出" then
                                isValid = false
                                errorMsg = "指令模式下，事件监测节点只能连接到「打出」开始点！"
                            end
                        elseif KARDS.CardEditor.Canvas.EditorMode == "counter_command" then
                            if fromNode.title ~= "激活时" then
                                isValid = false
                                errorMsg = "反制指令模式下，事件监测节点只能连接到「激活时」开始点！"
                            end
                        end
                    end
                    
                    if not isValid then
                        KARDS.CardEditor.Canvas.TempConnection = nil
                        return
                    end
                end
                
                KARDS.CardEditor.Canvas.CreateConnection(fromNodeId, node.id)
                KARDS.CardEditor.Canvas.TempConnection = nil
                return
            end
        end
    end

    KARDS.CardEditor.Canvas.TempConnection = nil
end

function KARDS.CardEditor.Canvas.CreateNode(x, y, nodeType, nodeName, nodeColor, hasInput, hasOutput, template)
    local node = NodeBase.New(nodeType, nodeName, nodeColor, hasInput, hasOutput, template)
    node.x = x
    node.y = y
    table.insert(KARDS.CardEditor.Canvas.Nodes, node)
    return node
end

function KARDS.CardEditor.Canvas.CreateConnection(fromNodeId, toNodeId)
    local tempConn = KARDS.CardEditor.Canvas.TempConnection
    local fromPort = tempConn and tempConn.fromPort or "output"
    
    for _, conn in ipairs(KARDS.CardEditor.Canvas.Connections) do
        if conn.fromNode == fromNodeId and conn.toNode == toNodeId and conn.fromPort == fromPort then
            return
        end
    end

    KARDS.CardEditor.Canvas.ConnectionCounter = KARDS.CardEditor.Canvas.ConnectionCounter + 1

    local conn = {
        id = "conn_" .. KARDS.CardEditor.Canvas.ConnectionCounter,
        fromNode = fromNodeId,
        toNode = toNodeId,
        fromPort = fromPort
    }

    table.insert(KARDS.CardEditor.Canvas.Connections, conn)
    KARDS.CardEditor.Audio.PlayConnect()

    return conn
end

function KARDS.CardEditor.Canvas.GetNodeById(nodeId)
    return NodeBase.GetNodeById(KARDS.CardEditor.Canvas.Nodes, nodeId)
end

function KARDS.CardEditor.Canvas.DeleteSelectedNodes()
    if #KARDS.CardEditor.Canvas.SelectionState.selectedNodes == 0 then return end
    
    -- 收集选中节点的ID，但过滤掉不能删除的节点
    local selectedNodeIds = {}
    local hasNonDeletable = false
    for _, node in ipairs(KARDS.CardEditor.Canvas.SelectionState.selectedNodes) do
        if node.canDelete == false then
            hasNonDeletable = true
        else
            table.insert(selectedNodeIds, node.id)
        end
    end
    
    -- 如果只有不能删除的节点被选中，直接返回
    if #selectedNodeIds == 0 then
        if hasNonDeletable then
        end
        return
    end
    
    -- 首先删除连接到这些节点的连接线（从后往前删除）
    for i = #KARDS.CardEditor.Canvas.Connections, 1, -1 do
        local conn = KARDS.CardEditor.Canvas.Connections[i]
        if table.HasValue(selectedNodeIds, conn.fromNode) or table.HasValue(selectedNodeIds, conn.toNode) then
            -- 检查是否连接到特殊事件监测节点，如果是，则不删除这条连接
            local fromNode = KARDS.CardEditor.Canvas.GetNodeById(conn.fromNode)
            local toNode = KARDS.CardEditor.Canvas.GetNodeById(conn.toNode)
            if (not fromNode or fromNode.canDelete ~= false) and (not toNode or toNode.canDelete ~= false) then
                table.remove(KARDS.CardEditor.Canvas.Connections, i)
            end
        end
    end
    
    -- 删除选中的节点（从后往前删除）
    for i = #KARDS.CardEditor.Canvas.Nodes, 1, -1 do
        local node = KARDS.CardEditor.Canvas.Nodes[i]
        if table.HasValue(selectedNodeIds, node.id) then
            table.remove(KARDS.CardEditor.Canvas.Nodes, i)
        end
    end
    
    -- 清除选择状态
    KARDS.CardEditor.Canvas.SelectionState.selectedNodes = {}
    KARDS.CardEditor.Canvas.SelectionState.deleteButtonVisible = false
    KARDS.CardEditor.Canvas.SelectionState.deleteButton = nil
    
    -- 播放删除音效
    KARDS.CardEditor.Audio.PlayDelete()
    
    -- 添加通知（已迁移到 INE）
end

function KARDS.CardEditor.Canvas.DrawContextMenu()
    if KARDS.CardEditor.Canvas.ContextMenu and KARDS.CardEditor.Canvas.ContextMenu.visible then
        local menu = KARDS.CardEditor.Canvas.ContextMenu
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        local isHovered = mouseX >= menu.x and mouseX <= menu.x + menu.width and
                         mouseY >= menu.y and mouseY <= menu.y + menu.height
        
        local bgColor = isHovered and Color(120, 120, 120) or Color(80, 80, 80)
        draw.RoundedBox(4, menu.x, menu.y, menu.width, menu.height, bgColor)
        
        local menuText = "删除节点"
        if menu.connection then
            menuText = "删除连接线"
        end
        draw.SimpleText(menuText, "SourceHan_Heavy_14", menu.x + menu.width / 2, menu.y + menu.height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

function KARDS.CardEditor.Canvas.DrawTabs()
    local win = KARDS.CardEditor.Canvas.Window
    local tabX = win.x
    local tabY = win.y + 40 -- 标题栏下方
    
    for i, tab in ipairs(KARDS.CardEditor.Canvas.Tabs) do
        local isActive = KARDS.CardEditor.Canvas.CurrentPage == tab.id
        local bgColor = isActive and Color(60, 60, 60) or Color(40, 40, 40)
        local borderColor = isActive and Color(100, 150, 255) or Color(60, 60, 60)
        
        -- 反转宽高比例：宽120，高30
        draw.RoundedBoxEx(4, tabX, tabY, 120, 30, bgColor, true, true, false, false)
        surface.SetDrawColor(borderColor)
        surface.DrawOutlinedRect(tabX, tabY, 120, 30)
        
        surface.SetTextColor(Color(255, 255, 255))
        surface.SetFont("SourceHan_Heavy_12")
        
        local textWidth, textHeight = surface.GetTextSize(tab.name)
        surface.SetTextPos(tabX + 120 / 2 - textWidth / 2, tabY + 30 / 2 - textHeight / 2)
        surface.DrawText(tab.name)
        
        tabX = tabX + 120 + 10
    end
end

-- 绘制自定义切换按钮（小矩形，带文字）
local function DrawToggleButton(label, bx, by, bw, bh, isOn, hovered, acColor)
    local bgColor = isOn and (acColor or Color(60, 120, 60)) or Color(50, 50, 50)
    if hovered then
        bgColor = isOn and Color(80, 150, 80) or Color(70, 70, 70)
    end
    draw.RoundedBox(4, bx, by, bw, bh, bgColor)
    draw.SimpleText(label, "SourceHan_Heavy_14", bx + bw / 2, by + bh / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- IsMouseIn 已移至 cl_apple_design.lua（全局函数）

local function DarkenColor(c, factor)
    return Color(c.r * factor, c.g * factor, c.b * factor)
end
