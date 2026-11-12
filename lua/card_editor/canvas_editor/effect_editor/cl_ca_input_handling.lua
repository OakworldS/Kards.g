--[[
=======================================================================================
输入处理系统 (Input Handling System)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的子系统，负责画布编辑器的所有输入事件处理。

包含功能：
  - RouteInput（主输入路由入口，2026-11-08 起按 ADR 0004 接入共享输入路由引擎）
  - InputActions（三层动作表，动作复用下方已拆分的输入子函数）
  - CheckNodeSelectorClick（检查节点选择器点击）
  - CheckPortClick（检查端口点击）
  - CheckTabClick（检查标签页点击）
  - CheckNodeDragStart（检查节点拖拽开始）
  - FinishTempNode（完成临时节点创建）
  - FinishTempConnection（完成临时连接创建）
  - CreateNode（创建节点）
  - CreateConnection（创建连接）
  - GetNodeById（按ID获取节点）
  - DrawTabs（绘制标签页）
  - DrawToggleButton（绘制自定义切换按钮）
  - DarkenColor（颜色变暗函数）

源文件：cl_canvas_editor.lua
  - 原 HandleInput：行 4200~4989（2026-11-08 改名为 RouteInput 并接入共享路由）
  - CheckNodeSelectorClick：行 4991~5030
  - CheckPortClick：行 5032~5125
  - CheckTabClick：行 5127~5145
  - CheckNodeDragStart：行 5147~5176
  - FinishTempNode：行 5178~5204
  - FinishTempConnection：行 5206~5325
  - CreateNode：行 5327~5333
  - CreateConnection：行 5335~5358
  - GetNodeById：行 5360~5362
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

-- 原 HandleInput 与 13 个局部子函数已于 2026-10-04 从主文件拆分时归位到本文件；
-- 2026-11-08 按 ADR 0004 把 HandleInput 改为 RouteInput 加三层动作表
-- 此文件保留其余辅助函数（CheckNodeSelectorClick, CheckPortClick 等）

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

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
                        errorMsg = T("editor.canvasinput.event_monitor_only_start")
                    else
                        -- 根据当前模式检查开始点类型
                        if KARDS.CardEditor.Canvas.EditorMode == "unit" then
                            if fromNode.title ~= "在场" then
                                isValid = false
                                errorMsg = T("editor.canvasinput.event_monitor_unit_start")
                            end
                        elseif KARDS.CardEditor.Canvas.EditorMode == "command" then
                            if fromNode.title ~= "打出" then
                                isValid = false
                                errorMsg = T("editor.canvasinput.event_monitor_command_start")
                            end
                        elseif KARDS.CardEditor.Canvas.EditorMode == "counter_command" then
                            if fromNode.title ~= "激活时" then
                                isValid = false
                                errorMsg = T("editor.canvasinput.event_monitor_counter_start")
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

KARDS.CardEditor.Canvas.LastMouseState = KARDS.CardEditor.Canvas.LastMouseState or false

-- ================================================================
-- 从 HandleInput 拆分的 13 个局部子函数（P0-1.2 重构）
-- ================================================================

-- 1. 处理卡牌选择器输入
local function HandleCardSelectorInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    local selector = KARDS.CardEditor.Canvas.CardSelector
    if selector.visible then
        if isLeftReleased then
            -- 主按钮区域
            local buttonY = selector.y + 2
            local buttonHeight = selector.height - 4
            local buttonWidth = selector.width - 4
            local buttonX = selector.x + 2
            
            local isButtonClicked = mouseX >= buttonX and mouseX <= buttonX + buttonWidth and mouseY >= buttonY and mouseY <= buttonY + buttonHeight
            
            if isButtonClicked then
                -- 切换展开状态
                selector.expanded = not selector.expanded
                -- 如果展开，刷新列表
                if selector.expanded then
                    KARDS.CardEditor.Canvas.CardSelector.RefreshList()
                end
                return true
            end
            
            -- 如果展开，处理列表项点击
            if selector.expanded then
                local listX = selector.x + 2
                local listY = buttonY + buttonHeight + 4
                local listWidth = selector.width - 4
                local listHeight = selector.expandedHeight - selector.height - 8
                local itemHeight = 45
                local previewWidth = 150
                
                -- 检查是否点击了外部区域
                local isOutsideClick = not (mouseX >= selector.x and mouseX <= selector.x + selector.width and mouseY >= selector.y and mouseY <= selector.y + selector.expandedHeight)
                if isOutsideClick then
                    selector.expanded = false
                    return true
                end
                
                -- 检查列表项点击
                local visibleItems = math.floor(listHeight / itemHeight)
                local scrollOffset = selector.scrollOffset
                
                for i = 1 + scrollOffset, math.min(#selector.cardsList, visibleItems + scrollOffset) do
                    local card = selector.cardsList[i]
                    local itemIndex = i - scrollOffset
                    local itemY = listY + (itemIndex - 1) * itemHeight
                    
                    if itemY + itemHeight > listY + listHeight then break end
                    
                    local isItemClicked = mouseX >= listX and mouseX <= listX + listWidth - previewWidth and mouseY >= itemY and mouseY <= itemY + itemHeight
                    if isItemClicked then
                        selector.selectedCard = card
                        selector.expanded = false
                        
                        -- 加载卡牌数据到编辑器
                        if card.fullData then
                            if card.fullData.nodes then
                                KARDS.CardEditor.Canvas.Nodes = card.fullData.nodes
                            end
                            if card.fullData.connections then
                                KARDS.CardEditor.Canvas.Connections = card.fullData.connections
                            end
                            if card.fullData.cardAppearance then
                                KARDS.CardEditor.Canvas.CardAppearance = card.fullData.cardAppearance
                                -- 同步钳击输入框
                                if KARDS.CardEditor.Canvas.PincerInputState then
                                    local app = card.fullData.cardAppearance
                                    KARDS.CardEditor.Canvas.PincerInputState.text = app.pincerValue or ""
                                    KARDS.CardEditor.Canvas.PincerInputState.active = false
                                end
                                -- 规模：旧卡无 cardScale 字段时补默认，并同步选中态（规模 UI 高亮）
                                local app = card.fullData.cardAppearance
                                if not app.cardScale then
                                    app.cardScale = "small"
                                end
                                KARDS.CardEditor.Canvas.SelectedCardScale = app.cardScale
                                -- 音效手动锁定兼容（2026-08-14）：旧卡无 _manual 标记，但
                                -- 自动分配（规模/类型）为本轮新增，已配置的 deploy/attack
                                -- 必来自手动选择器，视为手动锁定（规模/类型变更不再覆盖）
                                app.sounds = app.sounds or {}
                                if not app.sounds._manual then
                                    app.sounds._manual = {}
                                    if app.sounds.deploy then app.sounds._manual.deploy = true end
                                    if app.sounds.attack then app.sounds._manual.attack = true end
                                end
                            end
                            if card.fullData.currentPage then
                                KARDS.CardEditor.Canvas.CurrentPage = card.fullData.currentPage
                            end
                            if card.fullData.appearanceEditorActive ~= nil then
                                KARDS.CardEditor.Canvas.AppearanceEditorActive = card.fullData.appearanceEditorActive
                            end
                            
                            -- 更新VGUI控件
                            KARDS.CardEditor.Canvas.UpdateControlsFromAppearance()
                            
                            -- 重新创建 INE 开始点（使"钳击"等词条相关的开始点与卡牌关键词同步）
                            local INE = KARDS.CardEditor.IndependentNodeEditor
                            if INE then
                                local ineEditor = GetNodeEditor("card_effect_editor")
                                if ineEditor then
                                    INE:CreateStartNodesForEditor(ineEditor)
                                end
                            end
                            
                            KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.card_loaded"), Color(50, 200, 50), true)
                            KARDS.CardEditor.Audio.PlayLoad()
                        end
                        
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- 2. 处理文件按钮和菜单
local function HandleFileMenuInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if isLeftReleased then
        local fm = KARDS.CardEditor.Canvas.FileMenu
        -- 文件菜单点击处理（如果菜单已打开）
        if fm.visible then
            local menuX = fm.x
            local menuY = fm.y
            local menuW = fm.width
            local menuH = fm.height
            
            -- 检查是否点击了菜单内的按钮
            for _, button in ipairs(fm.buttons) do
                if mouseX >= button.x and mouseX <= button.x + button.width and mouseY >= button.y and mouseY <= button.y + button.height then
                    if button.id == "save" then
                        KARDS.CardEditor.Canvas.SaveWindow.visible = true
                        KARDS.CardEditor.Canvas.SaveWindow.inputText = ""
                        KARDS.CardEditor.Canvas.SaveWindow.errorMessage = ""
                        KARDS.CardEditor.Canvas.SaveWindow.isReplaceMode = false
                        -- 【默认卡牌】勾选初值取当前编辑卡牌的默认状态（仅测试版）
                        KARDS.CardEditor.Canvas.SaveWindow.setDefault =
                            KARDS.CardEditor.Canvas.CardAppearance and KARDS.CardEditor.Canvas.CardAppearance.isDefault == true or false
                        if IsValid(KARDS.CardEditor.Canvas.SaveWindow.inputPanel) then
                            KARDS.CardEditor.Canvas.SaveWindow.inputPanel:SetVisible(true)
                        end
                        timer.Simple(0.1, function()
                            if IsValid(KARDS.CardEditor.Canvas.SaveWindow.inputTextEntry) then
                                KARDS.CardEditor.Canvas.SaveWindow.inputTextEntry:SetText("")
                                KARDS.CardEditor.Canvas.SaveWindow.inputTextEntry:RequestFocus()
                            end
                        end)
                    elseif button.id == "load" then
                        KARDS.CardEditor.Canvas.LoadWindow.visible = true
                        KARDS.CardEditor.Canvas.LoadWindow.selectedFile = nil
                        KARDS.CardEditor.Canvas.LoadWindow.scrollOffset = 0
                        KARDS.CardEditor.Canvas.LoadWindow.category = "card"
                        KARDS.CardEditor.Canvas.LoadWindow.files = KARDS.CardEditor.SaveSystem.GetCardFiles()
                    elseif button.id == "delete" then
                        KARDS.CardEditor.Canvas.LoadWindow.visible = true
                        KARDS.CardEditor.Canvas.LoadWindow.selectedFile = nil
                        KARDS.CardEditor.Canvas.LoadWindow.scrollOffset = 0
                        KARDS.CardEditor.Canvas.LoadWindow.category = "card"
                        KARDS.CardEditor.Canvas.LoadWindow.deleteMode = true
                        KARDS.CardEditor.Canvas.LoadWindow.files = KARDS.CardEditor.SaveSystem.GetCardFiles()
                    end
                    fm.visible = false
                    return true
                end
            end
            
            -- 如果点击了外部，隐藏菜单
            if not (mouseX >= menuX and mouseX <= menuX + menuW and mouseY >= menuY and mouseY <= menuY + menuH) then
                fm.visible = false
            end
        else
            -- 文件按钮点击（打开菜单）
            local win = KARDS.CardEditor.Canvas.Window
            local fileBtnX = win.x + 300
            local fileBtnY = win.y + 5
            local fileBtnW = 80
            local fileBtnH = 30
            if mouseX >= fileBtnX and mouseX <= fileBtnX + fileBtnW and mouseY >= fileBtnY and mouseY <= fileBtnY + fileBtnH then
                fm.visible = true
                return true
            end
        end
    end
    return false
end

-- 3. 处理保存窗口（卡牌编辑器只保存卡牌）
local function HandleSaveWindowInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if KARDS.CardEditor.Canvas.SaveWindow.visible then
        if isLeftReleased then
            local saveWindow = KARDS.CardEditor.Canvas.SaveWindow

            -- 【默认卡牌】勾选切换与解锁（仅测试版；正式版移除本段）
            if KARDS.CardEditor.DefaultCardTestMode then
                local cb = saveWindow.checkbox
                if cb.hitW > 0 and mouseX >= cb.hitX and mouseX <= cb.hitX + cb.hitW and mouseY >= cb.hitY and mouseY <= cb.hitY + cb.hitH then
                    saveWindow.setDefault = not saveWindow.setDefault
                    KARDS.CardEditor.Audio.PlayClick()
                    return true
                end
                local app = KARDS.CardEditor.Canvas.CardAppearance
                if app and app.isDefault == true then
                    local ub = saveWindow.unlockButton
                    if mouseX >= ub.x and mouseX <= ub.x + ub.width and mouseY >= ub.y and mouseY <= ub.y + ub.height then
                        local curFile = KARDS.CardEditor.Canvas.CurrentCardFile
                        if curFile and KARDS.CardEditor.SaveSystem.UnlockDefaultCard(curFile) then
                            app.isDefault = false
                            saveWindow.setDefault = false
                            KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.default_card_unlocked"), Color(50, 200, 50), true)
                            KARDS.CardEditor.Audio.PlaySave()
                        else
                            KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.unlock_failed_file_missing"), Color(200, 50, 50), false)
                            KARDS.CardEditor.Audio.PlayNotification()
                        end
                        return true
                    end
                end
            end

            local confirmBtn = saveWindow.buttons[1]
            if mouseX >= confirmBtn.x and mouseX <= confirmBtn.x + confirmBtn.width and mouseY >= confirmBtn.y and mouseY <= confirmBtn.y + confirmBtn.height then
                local fileName = saveWindow.inputText
                if fileName == "" then
                    KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.filename_empty"), Color(200, 50, 50), false)
                    KARDS.CardEditor.Audio.PlayNotification()
                elseif KARDS.CardEditor.SaveSystem.IsDefaultCard(fileName) then
                    -- 默认卡牌锁定：禁止覆盖修改，需先解锁
                    KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.default_locked_edit", fileName), Color(200, 50, 50), false)
                    KARDS.CardEditor.Audio.PlayNotification()
                else
                    -- 【默认卡牌】应用「设为默认卡牌」勾选（仅测试版；正式版移除本段，
                    -- 正式版无勾选框，写盘标记由 SaveCard 内部强制 false）
                    if KARDS.CardEditor.DefaultCardTestMode and KARDS.CardEditor.Canvas.CardAppearance then
                        KARDS.CardEditor.Canvas.CardAppearance.isDefault = saveWindow.setDefault == true
                    end
                    -- 联动保存 INE 效果：先把节点编辑器内容导出为效果文件，
                    -- 将返回的保存路径绑定为卡牌 effectPath（编辑器无有效效果节点或导出失败时绑定为空）
                    local effectPath = ""
                    local ineEditor = GetNodeEditor and GetNodeEditor("card_effect_editor")
                    local INE = KARDS.CardEditor.IndependentNodeEditor
                    if ineEditor and INE and INE.ExportEditorToFile then
                        local hasEffectNode = false
                        for _, n in ipairs(ineEditor.nodes or {}) do
                            if not n.isStartNode then hasEffectNode = true break end
                        end
                        if hasEffectNode then
                            effectPath = INE:ExportEditorToFile(ineEditor, fileName) or ""
                        end
                    end
                    KARDS.CardEditor.Canvas.CardAppearance.effectPath = effectPath
                    -- 保存时确保卡面纹理已渲染落盘（已点过「渲染」则仅指向其文件路径，不重复渲染；
                    -- 未渲染则本次离屏渲染一次并保存 PNG），纹理路径随保存文件入库，组卡/生成直接引用
                    local textureInfo = KARDS.CardEditor.Canvas.EnsureCardTextures()
                    local success = KARDS.CardEditor.SaveSystem.SaveCard(fileName, textureInfo)
                    if success then
                        -- 记录当前编辑卡牌文件（后续默认卡牌解锁定位用）
                        KARDS.CardEditor.Canvas.CurrentCardFile = fileName
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.card_saved"), Color(50, 200, 50), true)
                        KARDS.CardEditor.Audio.PlaySave()
                    else
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.card_save_failed"), Color(200, 50, 50), false)
                        KARDS.CardEditor.Audio.PlayNotification()
                    end
                    
                    saveWindow.visible = false
                    if IsValid(saveWindow.inputPanel) then
                        saveWindow.inputPanel:SetVisible(false)
                    end
                end
            end
            
            local cancelBtn = saveWindow.buttons[2]
            if mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height then
                saveWindow.visible = false
                if IsValid(saveWindow.inputPanel) then
                    saveWindow.inputPanel:SetVisible(false)
                end
            end
        end
        return true
    end
    return false
end

-- 4. 处理加载确认对话框（卡牌编辑器只加载卡牌）
local function HandleLoadConfirmInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if KARDS.CardEditor.Canvas.LoadConfirmDialog.visible then
        if isLeftReleased then
            local dialog = KARDS.CardEditor.Canvas.LoadConfirmDialog
            
            -- 先更新按钮位置
            local continueBtn = dialog.buttons[1]
            continueBtn.x = dialog.x + dialog.width / 2 - 115
            continueBtn.y = dialog.y + dialog.height - 50
            continueBtn.hovered = mouseX >= continueBtn.x and mouseX <= continueBtn.x + continueBtn.width and mouseY >= continueBtn.y and mouseY <= continueBtn.y + continueBtn.height
            
            local cancelBtn = dialog.buttons[2]
            cancelBtn.x = dialog.x + dialog.width / 2 + 15
            cancelBtn.y = dialog.y + dialog.height - 50
            cancelBtn.hovered = mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height
            
            -- 检测点击
            if mouseX >= continueBtn.x and mouseX <= continueBtn.x + continueBtn.width and mouseY >= continueBtn.y and mouseY <= continueBtn.y + continueBtn.height then
                local fileName = dialog.selectedFile
                local success = KARDS.CardEditor.SaveSystem.LoadCard(fileName)
                if success then
                    -- 同步导入卡牌绑定的效果数据到 INE 面板（替换当前画布效果，实现加载卡牌即恢复效果）
                    local app = KARDS.CardEditor.Canvas.CardAppearance
                    local INE = KARDS.CardEditor.IndependentNodeEditor
                    if app and app.effectPath and app.effectPath ~= "" and INE and INE.ImportEffectData then
                        local effectData = KARDS.CardEditor.SaveSystem.LoadEffect(app.effectPath)
                        if effectData and effectData.nodes then
                            local ineEditor = GetNodeEditor and GetNodeEditor("card_effect_editor")
                            if ineEditor then
                                INE:ImportEffectData(ineEditor, effectData)
                            else
                                -- 尚未打开卡牌效果编辑器页面（INE 面板未创建）：
                                -- 暂存待导入数据，DrawEffectEditor 首次创建面板后应用
                                -- （修复：非效果页加载卡牌时 INE 面板此前显示为空）
                                KARDS.CardEditor.Canvas.PendingEffectImport = effectData
                            end
                        end
                    end
                    KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.card_loaded"), Color(50, 200, 50), true)
                    KARDS.CardEditor.Audio.PlayLoad()
                else
                    KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.card_load_failed"), Color(200, 50, 50), false)
                    KARDS.CardEditor.Audio.PlayNotification()
                end
                
                dialog.visible = false
                KARDS.CardEditor.Canvas.LoadWindow.visible = false
                KARDS.CardEditor.Canvas.LoadWindow.selectedFile = nil
                KARDS.CardEditor.Canvas.LoadWindow.files = {}
            end
            
            if mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height then
                dialog.visible = false
            end
        end
        return true
    end
    return false
end

-- 5. 处理加载窗口
local function HandleFileSelectInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if KARDS.CardEditor.Canvas.LoadWindow.visible then
        local loadWindow = KARDS.CardEditor.Canvas.LoadWindow
        local listX = loadWindow.x + 40
        local listY = loadWindow.y + 80 + loadWindow.headerHeight
        local listW = loadWindow.width - 80
        local listH = loadWindow.height - 180 - loadWindow.headerHeight
        local rowH = loadWindow.rowHeight

        -- 滚轮滚动文件列表（消费 CreateMove 设置的缩放标记；仅鼠标位于列表区域内时生效，
        -- 避免与卡牌插图预览的滚轮缩放冲突）
        local mouseInList = mouseX >= listX and mouseX <= listX + listW and mouseY >= listY and mouseY <= listY + listH
        if mouseInList and KARDS.CardEditor.Canvas._wheelZoomIn then
            KARDS.CardEditor.Canvas._wheelZoomIn = false
            local maxScroll = math.max(0, #loadWindow.files - math.max(1, math.floor(listH / rowH)))
            if loadWindow.scrollOffset > 0 then
                loadWindow.scrollOffset = loadWindow.scrollOffset - 1
                KARDS.CardEditor.Audio.PlayClick()
            end
        elseif mouseInList and KARDS.CardEditor.Canvas._wheelZoomOut then
            KARDS.CardEditor.Canvas._wheelZoomOut = false
            local maxScroll = math.max(0, #loadWindow.files - math.max(1, math.floor(listH / rowH)))
            if loadWindow.scrollOffset < maxScroll then
                loadWindow.scrollOffset = loadWindow.scrollOffset + 1
                KARDS.CardEditor.Audio.PlayClick()
            end
        end

        if isLeftReleased then
            if mouseX >= listX and mouseX <= listX + listW and mouseY >= listY and mouseY <= listY + listH then
                local itemIndex = loadWindow.scrollOffset + math.floor((mouseY - listY) / rowH) + 1
                if itemIndex >= 1 and itemIndex <= #loadWindow.files then
                    loadWindow.selectedFile = loadWindow.files[itemIndex]
                    KARDS.CardEditor.Audio.PlayClick()
                end
            end
            
            local actionBtn = loadWindow.buttons[1]
            if actionBtn.enabled and loadWindow.selectedFile and mouseX >= actionBtn.x and mouseX <= actionBtn.x + actionBtn.width and mouseY >= actionBtn.y and mouseY <= actionBtn.y + actionBtn.height then
                if loadWindow.deleteMode then
                    -- 删除模式：直接删除卡牌文件
                    local fileName = loadWindow.selectedFile
                    if KARDS.CardEditor.SaveSystem.IsDefaultCard(fileName) then
                        -- 默认卡牌锁定：不可删除（需先加载该卡并在保存窗口解锁）
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.default_locked_delete"), Color(200, 50, 50), false)
                        KARDS.CardEditor.Audio.PlayNotification()
                    else
                        local delSuccess = KARDS.CardEditor.SaveSystem.DeleteCard(fileName)
                        if delSuccess then
                            KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.file_deleted"), Color(50, 200, 50), true)
                            KARDS.CardEditor.Audio.PlaySave()
                        else
                            KARDS.CardEditor.Canvas.AddNotification(T("editor.canvasinput.file_delete_failed"), Color(200, 50, 50), false)
                            KARDS.CardEditor.Audio.PlayNotification()
                        end
                        loadWindow.visible = false
                        loadWindow.selectedFile = nil
                        loadWindow.files = {}
                        loadWindow.deleteMode = false
                    end
                else
                    -- 加载模式：显示确认对话框
                    local dialog = KARDS.CardEditor.Canvas.LoadConfirmDialog
                    dialog.visible = true
                    dialog.selectedFile = loadWindow.selectedFile
                    dialog.x = loadWindow.x + (loadWindow.width - dialog.width) / 2
                    dialog.y = loadWindow.y + (loadWindow.height - dialog.height) / 2
                    KARDS.CardEditor.Audio.PlayClick()
                end
            end
            
            local cancelBtn = loadWindow.buttons[2]
            if mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height then
                loadWindow.visible = false
                loadWindow.selectedFile = nil
                loadWindow.files = {}
                loadWindow.deleteMode = false
                KARDS.CardEditor.Audio.PlayClick()
            end
        end
        return true
    end
    return false
end

-- 6. 处理标签页和数据端口按钮点击
local function HandleTabAndPortClick(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if isLeftReleased then
        if KARDS.CardEditor.Canvas.CheckTabClick(mouseX, mouseY) then
            return true
        end

        -- 多选下拉框状态归属 INE 会话（ADR 0003），Canvas 节点本身没有会话
        local ineEditor = GetNodeEditor and GetNodeEditor("card_effect_editor")
        local session = ineEditor and ineEditor.session
        
        -- 处理数据端口按钮点击
        for _, node in ipairs(KARDS.CardEditor.Canvas.Nodes) do
            if not node.isStartNode then
                local nodeX, nodeY = NodeBase.GetScreenPosition(node)
                local portRadius = NodeBase.Config.portRadius
                local clickRadius = NodeBase.Config.clickRadius
                
                -- 检查输出数据点添加按钮
                if node.showAddOutputButton and #node.availableOutputTypes > 0 then
                    local addButtonX = nodeX + node.width / 2 - portRadius
                    local addButtonY = nodeY + node.height + portRadius * 2 + 4
                    if #node.selectedOutputTypes > 0 then
                        addButtonY = addButtonY + portRadius * 3 + 8
                    end
                    
                    local isAddButtonHovered = NodeBase.IsMouseOverPort(addButtonX, addButtonY, mouseX, mouseY, portRadius, clickRadius)
                    if isAddButtonHovered and session then
                        -- 打开多选下拉框
                        session.ExpandedMultiDropdown = node.id .. "_output"
                        
                        -- 计算多列布局
                        local style = KARDS.CardEditor.Canvas.DropdownStyle
                        local screenH = ScrH()
                        local dropdownY = addButtonY + portRadius * 2 + 4
                        local optionWidth = 160
                        local maxRowsPerColumn = math.floor((screenH - dropdownY - style.padding * 2) / style.rowHeight)
                        maxRowsPerColumn = math.max(1, maxRowsPerColumn)
                        local numColumns = math.ceil(#node.availableOutputTypes / maxRowsPerColumn)
                        local totalWidth = numColumns * optionWidth
                        
                        local dropdownH
                        if numColumns == 1 then
                            dropdownH = #node.availableOutputTypes * style.rowHeight + style.padding * 2
                        else
                            dropdownH = maxRowsPerColumn * style.rowHeight + style.padding * 2
                        end
                        
                        local dropdownX = addButtonX + portRadius - totalWidth / 2
                        if dropdownX < 0 then dropdownX = 0 end
                        if dropdownX + totalWidth > ScrW() then dropdownX = ScrW() - totalWidth end
                        
                        session.ExpandedMultiDropdownInfo = {
                            x = addButtonX, y = addButtonY, width = portRadius * 2, height = portRadius * 2,
                            nodeId = node.id, dropdownId = "output", dataTypes = node.availableOutputTypes,
                            dropdownX = dropdownX, dropdownY = dropdownY, totalWidth = totalWidth,
                            maxRowsPerColumn = maxRowsPerColumn, dropdownH = dropdownH,
                            numColumns = numColumns, optionWidth = optionWidth
                        }
                        
                        return true
                    end
                end
                
                -- 检查输入数据点添加按钮
                if node.showAddInputButton and #node.availableInputTypes > 0 then
                    local inputPortX = nodeX + node.width / 2 - portRadius
                    local inputPortY = nodeY - portRadius * 2 - 4
                    
                    local isInputButtonHovered = NodeBase.IsMouseOverPort(inputPortX, inputPortY, mouseX, mouseY, portRadius, clickRadius)
                    if isInputButtonHovered and session then
                        session.ExpandedMultiDropdown = node.id .. "_input"
                        
                        local style = KARDS.CardEditor.Canvas.DropdownStyle
                        local screenH = ScrH()
                        local dropdownY = inputPortY - 8
                        local optionWidth = 160
                        local maxRowsPerColumn = math.floor((screenH - dropdownY - style.padding * 2) / style.rowHeight)
                        maxRowsPerColumn = math.max(1, maxRowsPerColumn)
                        local numColumns = math.ceil(#node.availableInputTypes / maxRowsPerColumn)
                        local totalWidth = numColumns * optionWidth
                        
                        local dropdownH
                        if numColumns == 1 then
                            dropdownH = #node.availableInputTypes * style.rowHeight + style.padding * 2
                        else
                            dropdownH = maxRowsPerColumn * style.rowHeight + style.padding * 2
                        end
                        
                        local dropdownX = inputPortX + portRadius - totalWidth / 2
                        if dropdownX < 0 then dropdownX = 0 end
                        if dropdownX + totalWidth > ScrW() then dropdownX = ScrW() - totalWidth end
                        
                        dropdownY = inputPortY - dropdownH - 8
                        
                        session.ExpandedMultiDropdownInfo = {
                            x = inputPortX, y = inputPortY, width = portRadius * 2, height = portRadius * 2,
                            nodeId = node.id, dropdownId = "input", dataTypes = node.availableInputTypes,
                            dropdownX = dropdownX, dropdownY = dropdownY, totalWidth = totalWidth,
                            maxRowsPerColumn = maxRowsPerColumn, dropdownH = dropdownH,
                            numColumns = numColumns, optionWidth = optionWidth
                        }
                        
                        return true
                    end
                end
            end
        end
        
        -- 展开下拉框与多选下拉框状态都已迁入编辑器会话（ADR 0003）
        if session and KARDS.CardEditor.Canvas.HandleMultiDropdownClickOutside(mouseX, mouseY, session) then
            return true
        end
    end
    return false
end

-- 7. 处理节点选择器拖拽和端口点击
local function HandleNodeDragDrop(mouseX, mouseY, isLeftDown, isRightDown)
    if isLeftDown and KARDS.CardEditor.Canvas.CurrentPage == "effect" and 
       not KARDS.CardEditor.Canvas.SelectionState.isSelecting then
        if KARDS.CardEditor.Canvas.CheckNodeSelectorClick(mouseX, mouseY) then
            return true
        end
        if not KARDS.CardEditor.Canvas.TempNode and not KARDS.CardEditor.Canvas.DraggingNode and KARDS.CardEditor.Canvas.CheckPortClick(mouseX, mouseY) then
            return true
        end
        if not KARDS.CardEditor.Canvas.TempNode and not KARDS.CardEditor.Canvas.TempConnection and not KARDS.CardEditor.Canvas.DraggingNode and KARDS.CardEditor.Canvas.CheckNodeDragStart(mouseX, mouseY) then
            return true
        end
    end
    return false
end

-- 8. 处理临时节点拖拽和连接完成
local function HandleTempNodeAndConnection(mouseX, mouseY, isLeftDown, isLeftReleased, isRightDown)
    if KARDS.CardEditor.Canvas.TempNode and isLeftDown then
        KARDS.CardEditor.Canvas.TempNode.x = mouseX - 100
        KARDS.CardEditor.Canvas.TempNode.y = mouseY - 40
    end
    
    if isLeftReleased then
        if KARDS.CardEditor.Canvas.TempNode then
            KARDS.CardEditor.Canvas.FinishTempNode(mouseX, mouseY)
        elseif KARDS.CardEditor.Canvas.TempConnection then
            KARDS.CardEditor.Canvas.FinishTempConnection(mouseX, mouseY)
        end
        
        if KARDS.CardEditor.Canvas.DraggingNode then
            local win = KARDS.CardEditor.Canvas.Window
            local node = KARDS.CardEditor.Canvas.DraggingNode
            local contentX = win.x + 5
            local contentY = win.y + 75
            local selectorW = 180
            local contentH = win.height - 80
            local isInSelector = mouseX >= contentX and mouseX <= contentX + selectorW and
                               mouseY >= contentY and mouseY <= contentY + contentH
            if isInSelector then
                local connectionsToRemove = {}
                for i, conn in ipairs(KARDS.CardEditor.Canvas.Connections) do
                    if conn.fromNode == node.id or conn.toNode == node.id then table.insert(connectionsToRemove, i) end
                end
                for i = #connectionsToRemove, 1, -1 do
                    table.remove(KARDS.CardEditor.Canvas.Connections, connectionsToRemove[i])
                end
                for i, n in ipairs(KARDS.CardEditor.Canvas.Nodes) do
                    if n.id == node.id then table.remove(KARDS.CardEditor.Canvas.Nodes, i) break end
                end
            end
            node.dragging = false
            KARDS.CardEditor.Canvas.DraggingNode = nil
        end
    end
end

-- 9. 处理节点拖拽位置更新
local function HandleNodePositionUpdate(mouseX, mouseY, isLeftDown)
    if KARDS.CardEditor.Canvas.DraggingNode and KARDS.CardEditor.Canvas.DraggingNode.dragging then
        local win = KARDS.CardEditor.Canvas.Window
        local node = KARDS.CardEditor.Canvas.DraggingNode
        local dx = mouseX - node.dragStartX
        local dy = mouseY - node.dragStartY
        local contentX = win.x + 5
        local contentY = win.y + 45
        local selectorW = 180
        local nodeEditorX = contentX + selectorW
        local nodeEditorW = win.width - 10 - selectorW
        local nodeEditorH = win.height - 50
        local newX = node.startX + dx
        local newY = node.startY + dy
        newX = math.max(0, math.min(newX, nodeEditorW - node.width))
        newY = math.max(0, math.min(newY, nodeEditorH - node.height))
        node.x = newX
        node.y = newY
    end
end

-- 10. 处理悬停连接检测
local function HandleHoverConnection(mouseX, mouseY)
    local hoveredConn = nil
    local win = KARDS.CardEditor.Canvas.Window
    local contentX = win.x + 5
    local selectorW = 180
    local nodeEditorX = contentX + selectorW
    for _, conn in ipairs(KARDS.CardEditor.Canvas.Connections) do
        local fromNode = KARDS.CardEditor.Canvas.GetNodeById(conn.fromNode)
        local toNode = KARDS.CardEditor.Canvas.GetNodeById(conn.toNode)
        if fromNode and toNode then
            local fromX, fromY
            local portRadius = 6
            if fromNode.isStartNode then
                local absoluteNodeX = win.x + fromNode.x
                if fromNode.type == "condition" or fromNode.type == "event_monitor" or fromNode.type == "loop" then
                    if conn.fromPort == "output1" then
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height / 3 + portRadius
                    elseif conn.fromPort == "output2" then
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height * 2 / 3 + portRadius
                    else
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height / 2
                    end
                else
                    fromX = absoluteNodeX + fromNode.width
                    fromY = win.y + fromNode.y + fromNode.height / 2
                end
            else
                local absoluteNodeX = nodeEditorX + fromNode.x
                if fromNode.type == "condition" or fromNode.type == "event_monitor" or fromNode.type == "loop" then
                    if conn.fromPort == "output1" then
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height / 3 + portRadius
                    elseif conn.fromPort == "output2" then
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height * 2 / 3 + portRadius
                    else
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height / 2
                    end
                else
                    fromX = absoluteNodeX + fromNode.width
                    fromY = win.y + fromNode.y + fromNode.height / 2
                end
            end
            local toX = nodeEditorX + toNode.x
            local toY = win.y + toNode.y + toNode.height / 2
            local distance = toX - fromX
            local controlPoint1X = fromX + distance / 3
            local controlPoint1Y = fromY
            local controlPoint2X = fromX + distance * 2 / 3
            local controlPoint2Y = toY
            local points = KARDS.CardEditor.Canvas.BezierCurve(fromX, fromY, controlPoint1X, controlPoint1Y, controlPoint2X, controlPoint2Y, toX, toY)
            if KARDS.CardEditor.Canvas.IsMouseNearCurve(points, mouseX, mouseY, 15) then
                hoveredConn = conn
                break
            end
        end
    end
    KARDS.CardEditor.Canvas.HoveredConnection = hoveredConn
end

--[[
    Canvas 输入路由入口（2026-11-08，ADR 0004）。
    只负责刷新提示、组装原始输入上下文、按动作表路由，并记录本帧按键状态。
    动作表见文件末尾的 Canvas.InputActions。

    @return {string|nil} 被消费的动作名
]]
function KARDS.CardEditor.Canvas.RouteInput()
    local Canvas = KARDS.CardEditor.Canvas

    -- 更新提示状态
    Canvas.UpdateNotifications()

    local leftDown = input.IsMouseDown(MOUSE_LEFT)
    local rightDown = input.IsMouseDown(MOUSE_RIGHT)

    local Router = KARDS.CardEditor.InputRouter
    if not Router or not Canvas.InputActions then
        -- 加载顺序异常时不处理输入，但仍记录状态避免下一帧误判释放
        Canvas.LastMouseState = leftDown
        Canvas.LastRightMouseState = rightDown
        return
    end

    local ctx = Router.BuildContext(Canvas, {
        x = gui.MouseX(),
        y = gui.MouseY(),
        leftDown = leftDown,
        rightDown = rightDown,
        middleDown = input.IsMouseDown(MOUSE_MIDDLE)
    })
    local consumed = Router.Route(Canvas, ctx, Canvas.InputActions)
    Router.Commit(Canvas, ctx)

    -- 兼容字段：外部仍可能读取这两个历史状态
    Canvas.LastRightMouseState = ctx.rightDown
    Canvas.LastMouseState = ctx.leftDown
    return consumed
end

--[[
    Canvas 三层动作表（ADR 0004）。
    动作都是本文件已拆分出的输入子函数，保持原有顺序与消费语义：
      modal：卡牌选择器、文件菜单、保存窗口、读取确认、文件选择、页签与端口点击
      chrome：关于页整页接管、节点拖放
      canvas：临时节点与连线、节点位置更新、悬停连线
]]
KARDS.CardEditor.Canvas.InputActions = {
    modal = {
        { name = "card_selector", run = function(editor, ctx)
            return HandleCardSelectorInput(ctx.x, ctx.y, ctx.leftReleased, ctx.leftDown, ctx.rightDown)
        end },
        { name = "file_menu", run = function(editor, ctx)
            return HandleFileMenuInput(ctx.x, ctx.y, ctx.leftReleased, ctx.leftDown, ctx.rightDown)
        end },
        { name = "save_window", run = function(editor, ctx)
            return HandleSaveWindowInput(ctx.x, ctx.y, ctx.leftReleased, ctx.leftDown, ctx.rightDown)
        end },
        { name = "load_confirm", run = function(editor, ctx)
            return HandleLoadConfirmInput(ctx.x, ctx.y, ctx.leftReleased, ctx.leftDown, ctx.rightDown)
        end },
        { name = "file_select", run = function(editor, ctx)
            return HandleFileSelectInput(ctx.x, ctx.y, ctx.leftReleased, ctx.leftDown, ctx.rightDown)
        end },
        { name = "tab_and_port_click", run = function(editor, ctx)
            return HandleTabAndPortClick(ctx.x, ctx.y, ctx.leftReleased, ctx.leftDown, ctx.rightDown)
        end }
    },
    chrome = {
        {
            name = "about_page",
            enabled = function(editor, ctx)
                return KARDS.CardEditor.Canvas.CurrentPage == "about"
            end,
            run = function(editor, ctx)
                local Canvas = KARDS.CardEditor.Canvas
                local about = Canvas.About
                -- 素材来源弹窗是整页浮层，打开时仍然整页接管
                if about and about.sourcesVisible then
                    Canvas.HandleAboutSourcesInput(ctx.x, ctx.y, ctx.leftReleased, ctx.leftDown)
                    return true
                end
                -- 关于页内容矩形之外的点击不消费，交给同层后续动作与画布层处理。
                -- 没有矩形（绘制尚未写入）时退回整页接管，避免输入丢失
                local rect = about and about.pageRect
                if rect and not (ctx.x >= rect.x and ctx.x <= rect.x + rect.w
                    and ctx.y >= rect.y and ctx.y <= rect.y + rect.h) then
                    return false
                end
                Canvas.HandleAboutPageInput(ctx.x, ctx.y, ctx.leftReleased, ctx.leftDown)
                return true
            end
        },
        { name = "node_drag_drop", run = function(editor, ctx)
            return HandleNodeDragDrop(ctx.x, ctx.y, ctx.leftDown, ctx.rightDown)
        end }
    },
    canvas = {
        { name = "temp_node_and_connection", run = function(editor, ctx)
            HandleTempNodeAndConnection(ctx.x, ctx.y, ctx.leftDown, ctx.leftReleased, ctx.rightDown)
            return false
        end },
        { name = "node_position_update", run = function(editor, ctx)
            HandleNodePositionUpdate(ctx.x, ctx.y, ctx.leftDown)
            return false
        end },
        { name = "hover_connection", run = function(editor, ctx)
            HandleHoverConnection(ctx.x, ctx.y)
            return false
        end }
    }
}
