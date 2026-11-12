--[[
=======================================================================================
输入处理系统 (Input Handling System)
=======================================================================================
从 cl_ine_node_editor.lua 拆分出的子系统，负责编辑器鼠标/键盘输入处理。

包含功能：
  - RouteInput（输入路由入口，2026-11-08 起按 ADR 0004 拆分，只组装原始输入
    并交给 KARDS.CardEditor.InputRouter）
  - 节点删除、断开、连线校验等输入相关的公共函数
  - 三层动作实现见 cl_ine_input_actions.lua

依赖：
  - INE 编辑器实例的全部状态字段
  - 大量碰撞检测工具函数（IsPointInRect、IsPointInCircle、GetNodeAtPosition 等）
  - OverlayWindow 系统

源文件：cl_ine_node_editor.lua（行 6338~8531）
=======================================================================================
]]

-- 本文件内容最初剪切自 cl_ine_node_editor.lua 行 6338~8531，2026-11-08 按职责再拆分
KARDS.CardEditor.INE_InputHandlingLoaded = true
print("[CardEditor] cl_ine_input_handling.lua loaded")
local INE = KARDS.CardEditor.IndependentNodeEditor

-- 多语言查表（2026-11-08）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- 「激活时」开始点只能连接事件监测节点与注册钩子节点
-- （templates.md 反制画布连接约束：钩子路径 / 事件节点路径二选一）
local function ValidateCounterStartConnection(fromNode, toNode)
    if fromNode and fromNode.isStartNode and fromNode.data and fromNode.data.title == "激活时" then
        if toNode.type ~= "event_monitor" and toNode.type ~= "register_hook" then
            return false, "「激活时」开始点只能连接事件监测或注册钩子节点！"
        end
    end
    return true, ""
end

-- 导出到命名空间：include 不共享文件级 local，画布层动作需要复用该校验
INE.ValidateCounterStartConnection = ValidateCounterStartConnection

--- 序列化编辑器全部节点/连接/数据线/子函数/变量并保存为效果文件。
--- 供文件菜单「导出」与卡牌保存联动（canvas 保存卡牌时自动保存 INE 效果并绑定 effectPath）复用。
--- @param editor   INE 编辑器实例
--- @param fileName string 文件名（不含路径，可带可不带 .json）
--- @return string|nil 保存成功返回效果文件相对路径（"effects/xxx.json"，含安全转义后的磁盘名），失败返回 nil
function INE:ExportEditorToFile(editor, fileName)
    if not editor or not fileName or fileName == "" then return nil end
    if not string.EndsWith(fileName, ".json") then
        fileName = fileName .. ".json"
    end
    local serializedNodes = {}
    for _, node in ipairs(editor.nodes) do
        -- 保存端运行时迁移：写出模板 base + runtimeData（修复编辑器混合计数与运行时
        -- 类型独立计数的组件键错位；服务端 LoadEffectForRuntime 应用 runtimeData 后执行）。
        -- 无 config 的节点（开始点/var-op 等由类型分派，不走 base 解析）不生成。
        local nodeBase, runtimeData
        local hasConfig = node.config and node.config ~= ""
        if hasConfig then
            local template = INE.RegisteredNodes[node.name]
            local tplBase = template and template._templateBase
            nodeBase = (tplBase and tplBase ~= "" and not tplBase:match("^AUTO:")) and tplBase
                       or INE.GenerateBaseFromConfig(node.config)
            local ok, rd = pcall(INE.BuildRuntimeData, node.config, nodeBase, node.data or {})
            if ok then
                runtimeData = rd
            else
                print("[INE] ExportEditorToFile: BuildRuntimeData 失败（节点 " .. tostring(node.name)
                    .. "）: " .. tostring(rd))
            end
        end
        table.insert(serializedNodes, {
            id = node.id,
            name = node.name,
            type = node.type,
            x = node.x,
            y = node.y,
            width = node.width,
            height = node.height,
            hasInput = node.hasInput,
            hasOutput = node.hasOutput,
            hasInputs = node.hasInputs,
            hasOutputs = node.hasOutputs,
            inputTypes = node.inputTypes,
            outputTypes = node.outputTypes,
            config = node.config,
            selectedInputTypes = node.selectedInputTypes,
            selectedOutputTypes = node.selectedOutputTypes,
            isStartNode = node.isStartNode,
            canDelete = node.canDelete,
            base = nodeBase,
            runtimeData = runtimeData,
            data = node.data or {}
        })
    end
    local serializedConns = {}
    for _, conn in ipairs(editor.connections) do
        table.insert(serializedConns, {
            id = conn.id,
            fromNode = conn.fromNode,
            toNode = conn.toNode,
            fromPort = conn.fromPort
        })
    end
    local serializedDataConns = {}
    for _, conn in ipairs(editor.dataConnections or {}) do
        table.insert(serializedDataConns, {
            id = conn.id,
            fromNode = conn.fromNode,
            toNode = conn.toNode,
            fromPortIndex = conn.fromPortIndex,
            toPortIndex = conn.toPortIndex,
            dataType = conn.dataType,
            variableName = conn.variableName
        })
    end
    -- 收集所有函数子编辑器的已保存数据
    local functionsData = {}
    for varName, subID in pairs(editor.functionSubEditors or {}) do
        local subEditor = INE.Editors[subID]
        if subEditor and subEditor._savedFunctionData and not subEditor._arrayItemRef then
            -- 跳过数组项内的函数（其数据存储在数组项本身的 functionData 中）
            functionsData[varName] = subEditor._savedFunctionData
        end
    end
    local exportData = {
        nodes = serializedNodes,
        connections = serializedConns,
        dataConnections = serializedDataConns,
        nodeCounter = editor.nodeCounter,
        dataConnectionCounter = editor.dataConnectionCounter,
        view = {
            canvasOffsetX = editor.canvasOffsetX,
            canvasOffsetY = editor.canvasOffsetY,
            canvasScale = editor.canvasScale
        },
        functions = functionsData,
        variables = INE:PrefixInternalNames(editor.variables) or editor.variables   -- 包含数组变量及其项内的 functionData，添加 KARDS.User. 前缀
    }
    local saveOk = KARDS.CardEditor.SaveSystem.SaveEffect(fileName, exportData)
    if saveOk then
        -- 提示显示还原后的中文文件名（磁盘名含 %XX 转义，UnescapeFileName 反解）
        local displayPath = KARDS.CardEditor.SaveSystem.UnescapeFileName(saveOk)
        INE:AddNotification(editor, "已导出至 " .. displayPath, Color(100, 255, 100), 3, true)
        return saveOk
    else
        INE:AddNotification(editor, "导出失败", Color(255, 100, 100), 3)
        return nil
    end
end

--[[
    删除当前框选的节点，供 Delete 键与框选删除按钮共用。
    受保护节点与开始点不会被删除，并在通知中列出名称。

    @param  editor {table} 编辑器实例对象
    @return {number} 实际删除的节点数量
]]
function INE:DeleteSelectedNodes(editor)
    local deletedCount = 0
    local nonDeletableNames = {}
    for _, node in ipairs(editor.selectedNodes or {}) do
        if node.canDelete and not node.isStartNode then
            INE:RemoveNode(editor, node.id)
            deletedCount = deletedCount + 1
        else
            local nodeTitle = (node.data and node.data.title) or node.type or T("editor.nodeinput.unknown")
            table.insert(nonDeletableNames, nodeTitle)
        end
    end
    editor.selectedNodes = {}
    editor.selectedOutputs = {}
    editor._selectionDeleteBtn = nil
    editor._selectionDisconnectBtn = nil

    if deletedCount > 0 then
        if #nonDeletableNames > 0 then
            local nameStr = table.concat(nonDeletableNames, "、")
            INE:AddNotification(editor, T("editor.nodeinput.deleted_partial", nameStr), Color(200, 150, 50), 3)
        else
            INE:AddNotification(editor, T("editor.nodeinput.deleted_selected"), Color(100, 255, 100), 3, true)
        end
    elseif #nonDeletableNames > 0 then
        local nameStr = table.concat(nonDeletableNames, "、")
        INE:AddNotification(editor, T("editor.nodeinput.cannot_delete", nameStr), Color(200, 100, 100), 3)
    end
    return deletedCount
end

--[[
    断开当前框选节点的全部连线，供框选后的「断开连接」按钮使用。
    选中节点作为起点或终点的普通连线与数据连线都会被移除，节点自身保留。

    @param  editor {table} 编辑器实例对象
    @return {number} 实际断开的连接线数量
]]
function INE:DisconnectSelectedNodes(editor)
    local selectedIDs = {}
    for _, node in ipairs(editor.selectedNodes or {}) do
        selectedIDs[node.id] = true
    end
    if next(selectedIDs) == nil then return 0 end

    local removed = 0
    local function RemoveAttached(list)
        if not list then return end
        for i = #list, 1, -1 do
            local conn = list[i]
            if selectedIDs[conn.fromNode] or selectedIDs[conn.toNode] then
                table.remove(list, i)
                removed = removed + 1
            end
        end
    end
    RemoveAttached(editor.connections)
    RemoveAttached(editor.dataConnections)

    -- 断开后清空输出点选择，避免残留已失效的连线起点
    editor.selectedOutputs = {}

    if removed > 0 then
        INE:AddNotification(editor, T("editor.nodeinput.disconnected_selected", removed), Color(100, 255, 100), 3, true)
    else
        INE:AddNotification(editor, T("editor.nodeinput.no_connection_to_disconnect"), Color(200, 150, 50), 3)
    end
    return removed
end

--[[
    判断编辑器当前是否处于拖拽交互中（拖拽临时连线、数据点、节点或框选）。
    拖拽期间应屏蔽单选下拉框的展开与选项选择，避免按住左键经过时误触。

    @param  editor {table} 编辑器实例对象
    @return {boolean} 处于拖拽交互中返回 true
]]
function INE:IsPointerBusy(editor)
    if not editor then return false end
    return (editor.isSelecting or editor.draggingNode or editor.draggingFrom
        or editor.draggingDataPort or editor.tempConnection
        or (editor.selectedOutputs and #editor.selectedOutputs > 0)) and true or false
end

--[[
    删除指定的连接线。

    @param  editor {table}   编辑器实例对象
    @param  conn   {table}   连接线对象
    @param  isData {boolean} 是否为数据连线
    @return {boolean} 是否删除成功
]]
function INE:RemoveConnection(editor, conn, isData)
    local list = isData and editor.dataConnections or editor.connections
    if not list then return false end
    for i = #list, 1, -1 do
        if list[i] == conn then
            table.remove(list, i)
            return true
        end
    end
    return false
end

--[[
    执行视图菜单中的指定项，供顶部视图菜单与右键菜单共用。

    @param  editor    {table}  编辑器实例对象
    @param  itemIndex {number} 菜单项索引（1 到 17）
]]
function INE:ExecuteViewMenuItem(editor, itemIndex)
    if itemIndex == 1 then
        INE:ResetView(editor)
    elseif itemIndex == 2 then
        INE:FitAllNodes(editor)
    elseif itemIndex == 3 then
        INE:FocusExtremeNode(editor, "left")
    elseif itemIndex == 4 then
        INE:FocusExtremeNode(editor, "right")
    elseif itemIndex == 5 then
        INE:FocusExtremeNode(editor, "top")
    elseif itemIndex == 6 then
        INE:FocusExtremeNode(editor, "bottom")
    elseif itemIndex == 7 then
        INE:ZoomView(editor, INE.ZOOM_STEP)
    elseif itemIndex == 8 then
        INE:ZoomView(editor, 1/INE.ZOOM_STEP)
    elseif itemIndex == 9 then
        editor.canvasScale = 1
    elseif itemIndex == 10 then
        editor._viewZoomFollowMouse = not editor._viewZoomFollowMouse
        INE._viewZoomFollowMouse = editor._viewZoomFollowMouse
    elseif itemIndex == 11 then
        editor._viewConnectionMode = not editor._viewConnectionMode
        INE._viewConnectionMode = editor._viewConnectionMode
    elseif itemIndex == 12 then
        INE:OpenFindNodeWindow(editor)
    elseif itemIndex == 13 then
        editor.showCoordinates = not editor.showCoordinates
    elseif itemIndex == 14 then
        -- 分隔线，不做任何操作
    elseif itemIndex == 15 then
        editor._viewMode = "fullscreen"
    elseif itemIndex == 16 then
        editor._viewMode = "half"
    elseif itemIndex == 17 then
        editor._viewMode = "window"
    end
end

--[[
    构建右键菜单的文件子菜单项。

    @param  editor {table} 编辑器实例对象
    @return {table} 菜单项列表，actionIndex 对应顶部文件菜单的项索引
]]
function INE:GetFileMenuItems(editor)
    if editor.editorMode == "function" then
        return {
            {label = T("editor.nodevar.file_edit_base_function"), actionIndex = 1},
            {label = T("editor.nodevar.file_save"), actionIndex = 2},
            {label = T("editor.nodevar.file_import"), actionIndex = 3},
            {label = T("editor.nodevar.file_clear_canvas"), actionIndex = 4}
        }
    end
    return {
        {label = T("editor.nodevar.file_export"), actionIndex = 1},
        {label = T("editor.nodevar.file_import"), actionIndex = 2},
        {label = T("editor.nodevar.file_clear_canvas"), actionIndex = 3}
    }
end

--[[
    构建右键菜单的视图子菜单项，项顺序与顶部视图菜单保持一致。

    @param  editor {table} 编辑器实例对象
    @return {table} 菜单项列表
]]
function INE:GetViewMenuItems(editor)
    return {
        {label = T("editor.nodevar.view_reset_origin"), actionIndex = 1},
        {label = T("editor.nodevar.view_fit_all"), actionIndex = 2},
        {label = T("editor.nodevar.view_leftmost"), actionIndex = 3},
        {label = T("editor.nodevar.view_rightmost"), actionIndex = 4},
        {label = T("editor.nodevar.view_topmost"), actionIndex = 5},
        {label = T("editor.nodevar.view_bottommost"), actionIndex = 6},
        {label = T("editor.nodevar.view_zoom_in"), actionIndex = 7},
        {label = T("editor.nodevar.view_zoom_out"), actionIndex = 8},
        {label = T("editor.nodevar.view_reset_zoom"), actionIndex = 9},
        {label = T("editor.nodevar.view_zoom_follow_mouse"), actionIndex = 10},
        {label = T("editor.nodevar.view_view_order"), actionIndex = 11},
        {label = T("editor.nodevar.view_find_node"), actionIndex = 12},
        {label = T("editor.nodevar.view_toggle_coordinates"), actionIndex = 13},
        {separator = true},
        {label = T("editor.nodevar.view_fullscreen"), actionIndex = 15},
        {label = T("editor.nodevar.view_half"), actionIndex = 16},
        {label = T("editor.nodevar.view_window"), actionIndex = 17}
    }
end

--[[
    计算菜单项的高度并写入每项的纵坐标。

    @param  items   {table}  菜单项列表
    @param  startY  {number} 起始纵坐标
    @param  width   {number} 菜单宽度
    @return {number} 菜单总高度
]]
function INE:LayoutContextMenuItems(items, startY, width)
    local itemHeight = 28
    local separatorHeight = 9
    local total = 0
    for _, item in ipairs(items) do
        item.h = item.separator and separatorHeight or itemHeight
        item.y = startY + total
        item.w = width
        total = total + item.h
    end
    return total
end

--[[
    构建右键菜单。

    @param  editor          {table}   编辑器实例对象
    @param  mouseX          {number}  鼠标X坐标
    @param  mouseY          {number}  鼠标Y坐标
    @param  targetKind      {string}  右键目标类型：node、connection 或 none
    @param  targetNode      {table}   目标节点
    @param  targetConnection{table}   目标连接线
    @param  isData          {boolean} 目标连接线是否为数据连线
]]
function INE:BuildContextMenu(editor, mouseX, mouseY, targetKind, targetNode, targetConnection, isData)
    local items = {
        {id = "file", label = T("editor.nodevar.file"), submenuKind = "file", submenuItems = INE:GetFileMenuItems(editor), submenuWidth = 150},
        {id = "view", label = T("editor.nodevar.view"), submenuKind = "view", submenuItems = INE:GetViewMenuItems(editor), submenuWidth = 170}
    }
    if targetKind == "node" then
        table.insert(items, {separator = true})
        table.insert(items, {id = "delete_node", label = T("editor.canvasinput.delete_node"), danger = true})
    elseif targetKind == "connection" then
        table.insert(items, {separator = true})
        table.insert(items, {id = "delete_connection", label = T("editor.canvasinput.delete_connection"), danger = true})
    end

    local menuW = 120
    local menuH = INE:LayoutContextMenuItems(items, 0, menuW)
    local x = math.Clamp(mouseX + 10, 4, ScrW() - menuW - 4)
    local y = math.Clamp(mouseY + 10, 4, ScrH() - menuH - 4)
    INE:LayoutContextMenuItems(items, y, menuW)

    editor.contextMenu = {
        x = x, y = y, w = menuW, h = menuH,
        items = items, hovered = 0, submenu = nil,
        targetKind = targetKind, node = targetNode,
        connection = targetConnection, isData = isData
    }
end

--[[
    创建右键菜单的二级子菜单并定位到屏幕内。

    @param  menu        {table} 一级菜单
    @param  parentIndex {number} 一级菜单项索引
    @param  parentItem  {table} 一级菜单项
    @return {table} 子菜单对象
]]
function INE:CreateContextSubmenu(menu, parentIndex, parentItem)
    local items = parentItem.submenuItems
    local width = parentItem.submenuWidth or 150
    local height = 0
    for _, item in ipairs(items) do
        item.h = item.separator and 9 or 28
        height = height + item.h
    end

    local x = menu.x + menu.w + 2
    if x + width > ScrW() - 4 then
        x = menu.x - width - 2
    end
    x = math.Clamp(x, 4, ScrW() - width - 4)
    -- parentItem.y 由 LayoutContextMenuItems 以绝对屏幕纵坐标写入，已含菜单顶部偏移，
    -- 不能再叠加 menu.y，否则越靠下的父项重复计入越多，被 Clamp 压到屏幕底部后整体上顶
    local y = math.Clamp(parentItem.y, 4, ScrH() - height - 4)

    local offset = 0
    for _, item in ipairs(items) do
        item.y = y + offset
        item.w = width
        offset = offset + item.h
    end

    return {
        x = x, y = y, w = width, h = height,
        items = items, hovered = 0, parentIndex = parentIndex,
        kind = parentItem.submenuKind
    }
end

--[[
    更新右键菜单的悬停项与展开状态。

    @param editor {table}  编辑器实例对象
    @param mouseX {number} 鼠标X坐标
    @param mouseY {number} 鼠标Y坐标
]]
function INE:UpdateContextMenuState(editor, mouseX, mouseY)
    local menu = editor.contextMenu
    if not menu then return end

    menu.hovered = 0
    if INE:IsPointInRect(mouseX, mouseY, menu) then
        for i, item in ipairs(menu.items) do
            if mouseY >= item.y and mouseY <= item.y + item.h then
                if not item.separator then
                    menu.hovered = i
                end
                break
            end
        end
    end

    local topItem = menu.items[menu.hovered]
    if topItem and topItem.submenuItems then
        if not menu.submenu or menu.submenu.parentIndex ~= menu.hovered then
            menu.submenu = INE:CreateContextSubmenu(menu, menu.hovered, topItem)
        end
    elseif topItem and not topItem.submenuItems then
        menu.submenu = nil
    end

    if menu.submenu then
        menu.submenu.hovered = 0
        if INE:IsPointInRect(mouseX, mouseY, menu.submenu) then
            for i, item in ipairs(menu.submenu.items) do
                if mouseY >= item.y and mouseY <= item.y + item.h then
                    if not item.separator then
                        menu.submenu.hovered = i
                    end
                    break
                end
            end
        end
    end

    if INE:IsPointInRect(mouseX, mouseY, menu)
    or (menu.submenu and INE:IsPointInRect(mouseX, mouseY, menu.submenu)) then
        editor._mouseOverOverlayWindow = true
    end
end

--[[
    处理右键菜单的左键点击。

    @param  editor {table}  编辑器实例对象
    @param  mouseX {number} 鼠标X坐标
    @param  mouseY {number} 鼠标Y坐标
    @return {boolean} 是否已消费本次输入
]]
function INE:HandleContextMenuInput(editor, mouseX, mouseY)
    local menu = editor.contextMenu
    if not menu then return false end

    local leftDown = input.IsMouseDown(MOUSE_LEFT)
    if not leftDown then
        editor._contextMenuHeld = false
        return false
    end
    if editor._contextMenuHeld then return false end
    editor._contextMenuHeld = true

    -- 消费本次左键，避免穿透到画布
    editor._mouseDown = true
    editor._clickStartX = mouseX
    editor._clickStartY = mouseY

    local sub = menu.submenu
    if sub and INE:IsPointInRect(mouseX, mouseY, sub) then
        local item = sub.items[sub.hovered]
        if item and not item.separator and item.actionIndex then
            if sub.kind == "file" then
                INE:ExecuteFileMenuItem(editor, item.actionIndex)
            else
                INE:ExecuteViewMenuItem(editor, item.actionIndex)
            end
        end
        editor.contextMenu = nil
        return true
    end

    local topItem = menu.items[menu.hovered]
    if topItem and INE:IsPointInRect(mouseX, mouseY, menu) then
        if topItem.submenuItems then
            menu.submenu = INE:CreateContextSubmenu(menu, menu.hovered, topItem)
        elseif topItem.id == "delete_node" and menu.node then
            INE:RemoveNode(editor, menu.node.id)
            editor.selectedNodes = {}
            editor.selectedOutputs = {}
            editor._selectionDeleteBtn = nil
            editor._selectionDisconnectBtn = nil
            INE:AddNotification(editor, T("editor.nodeinput.deleted_node"), Color(100, 255, 100), 3, true)
            editor.contextMenu = nil
        elseif topItem.id == "delete_connection" and menu.connection then
            if INE:RemoveConnection(editor, menu.connection, menu.isData) then
                INE:AddNotification(editor, T("editor.nodeinput.deleted_connection"), Color(100, 255, 100), 3, true)
            end
            editor.contextMenu = nil
        end
        return true
    end

    editor.contextMenu = nil
    -- 点击菜单外只关闭菜单，不消费输入，保证顶部文件/视图菜单与画布交互仍可响应
    return false
end

--[[
    处理框选后操作按钮（删除所选节点、断开连接）的左键点击。

    @param  editor {table}  编辑器实例对象
    @param  mouseX {number} 鼠标X坐标
    @param  mouseY {number} 鼠标Y坐标
    @return {boolean} 是否已消费本次输入
]]
function INE:HandleSelectionDeleteButtonInput(editor, mouseX, mouseY)
    local btn = editor._selectionDeleteBtn
    local disconnectBtn = editor._selectionDisconnectBtn
    if not btn and not disconnectBtn then return false end

    local leftDown = input.IsMouseDown(MOUSE_LEFT)
    if not leftDown then
        editor._selectionDeleteBtnHeld = false
        editor._selectionDisconnectBtnHeld = false
        return false
    end

    if btn and INE:IsPointInRect(mouseX, mouseY, btn) then
        if editor._selectionDeleteBtnHeld then return false end
        editor._selectionDeleteBtnHeld = true
        editor._mouseDown = true
        editor._clickStartX = mouseX
        editor._clickStartY = mouseY
        INE:DeleteSelectedNodes(editor)
        return true
    end

    if disconnectBtn and INE:IsPointInRect(mouseX, mouseY, disconnectBtn) then
        if editor._selectionDisconnectBtnHeld then return false end
        editor._selectionDisconnectBtnHeld = true
        editor._mouseDown = true
        editor._clickStartX = mouseX
        editor._clickStartY = mouseY
        INE:DisconnectSelectedNodes(editor)
        return true
    end

    -- 点击按钮外只关闭按钮，不消费输入，避免影响正常交互
    editor._selectionDeleteBtn = nil
    editor._selectionDisconnectBtn = nil
    return false
end

--[[
    执行文件菜单中的指定项，供顶部文件菜单与右键菜单共用。

    @param  editor    {table}  编辑器实例对象
    @param  itemIndex {number} 菜单项索引
]]
function INE:ExecuteFileMenuItem(editor, itemIndex)
        if itemIndex == 1 then
            if editor.editorMode == "function" then
                -- 编辑基础函数：打开函数变量编辑对话框修改名称和参数
                local parentID = editor._parentEditorID
                local varName = editor._funcVarName
                if parentID and varName then
                    local parentEditor = INE.Editors[parentID]
                    if parentEditor then
                            local funcVars = parentEditor.variables["f"] or {}
                            for vi, fv in ipairs(funcVars) do
                                if fv.name == varName then
                                    parentEditor._numVarDialogIdx = vi
                                    parentEditor._numVarDialogIsNew = nil
                                    -- 在子编辑器(当前编辑器)上显示对话框，确保图层在上层
                                    -- 保存数据编辑器引用，供对话框内容和确定/取消处理使用
                                    editor._funcDialogDataEditor = parentEditor
                                    INE:ShowFuncVarDialog(editor, vi)
                                    break
                            end
                        end
                    end
                end
            else
                -- 导出：弹出窗口自定义文件名，然后直接序列化全部节点与连接
                local defaultName = "ine_export_" .. editor.id .. "_" .. os.time() .. ".json"
                Derma_StringRequest(
                    "导出节点文件",
                    "请输入文件名:",
                    defaultName,
                    function(fileName)
                        if fileName and fileName ~= "" then
                            INE:ExportEditorToFile(editor, fileName)
                        end
                    end,
                    function() end
                )
            end
        elseif itemIndex == 2 then
            if editor.editorMode == "function" then
                -- 函数模式：保存函数内容到内存
                local savedData = {
                    nodes = {},
                    connections = {},
                    dataConnections = {}
                }
                for _, node in ipairs(editor.nodes) do
                    table.insert(savedData.nodes, {
                        id = node.id,
                        name = node.name,
                        type = node.type,
                        x = node.x,
                        y = node.y,
                        width = node.width,
                        height = node.height,
                        hasInput = node.hasInput,
                        hasOutput = node.hasOutput,
                        hasInputs = node.hasInputs,
                        hasOutputs = node.hasOutputs,
                        inputTypes = node.inputTypes,
                        outputTypes = node.outputTypes,
                        config = node.config,
                        selectedInputTypes = node.selectedInputTypes,
                        selectedOutputTypes = node.selectedOutputTypes,
                        isStartNode = node.isStartNode,
                        canDelete = node.canDelete,
                        data = node.data or {}
                    })
                end
                for _, conn in ipairs(editor.connections) do
                    table.insert(savedData.connections, {
                        id = conn.id,
                        fromNode = conn.fromNode,
                        toNode = conn.toNode,
                        fromPort = conn.fromPort
                    })
                end
                for _, conn in ipairs(editor.dataConnections or {}) do
                    table.insert(savedData.dataConnections, {
                        id = conn.id,
                        fromNode = conn.fromNode,
                        toNode = conn.toNode,
                        fromPortIndex = conn.fromPortIndex,
                        toPortIndex = conn.toPortIndex,
                        dataType = conn.dataType,
                        variableName = conn.variableName
                    })
                end
                savedData.nodeCounter = editor.nodeCounter
                savedData.dataConnectionCounter = editor.dataConnectionCounter
                savedData.view = {
                    canvasOffsetX = editor.canvasOffsetX,
                    canvasOffsetY = editor.canvasOffsetY,
                    canvasScale = editor.canvasScale
                }
                -- 检测是否为数组项中的函数
                if editor._arrayItemRef then
                    -- 数组项中的函数：保存到数组项内部，数据完全自包含
                    editor._arrayItemRef.functionData = savedData
                else
                    editor._savedFunctionData = savedData
                    -- 同时持久化到父编辑器，确保关闭子编辑器后数据不丢失
                    if editor._parentEditorID then
                        local parentEditor = INE.Editors[editor._parentEditorID]
                        if parentEditor then
                            parentEditor._savedFunctionData = parentEditor._savedFunctionData or {}
                            parentEditor._savedFunctionData[editor._funcVarName] = savedData
                        end
                    end
                end
                INE:AddNotification(editor, "函数已保存", Color(100, 255, 100), 3, true)
            else
                -- 导入：显示文件选择窗口（从 effects/ 目录读取）
                local files = KARDS.CardEditor.SaveSystem.GetEffectFiles()
                if #files == 0 then
                    INE:AddNotification(editor, "effects/ 目录下没有可导入的文件", Color(255, 100, 100), 3)
                else
                    editor._importFiles = files
                    editor._importSelectedFile = nil
                    editor._importScrollOffset = 0
                    INE:ShowOverlayWindow(editor, {
                        id = "ine_import_window",
                        title = "导入节点文件",
                        x = editor.x + (editor.width - 500) / 2,
                        y = editor.y + (editor.height - 400) / 2,
                        width = 500,
                        height = 400,
                        content = function(ed, win, cx, cy, cw, ch)
                            INE:DrawImportWindowContent(ed, win, cx, cy, cw, ch)
                        end
                    })
                end
            end
        elseif itemIndex == 3 then
            if editor.editorMode == "function" then
                -- 函数模式：导入（从 effects/ 目录读取）
                local files = KARDS.CardEditor.SaveSystem.GetEffectFiles()
                if #files == 0 then
                    INE:AddNotification(editor, "effects/ 目录下没有可导入的文件", Color(255, 100, 100), 3)
                else
                    editor._importFiles = files
                    editor._importSelectedFile = nil
                    editor._importScrollOffset = 0
                    INE:ShowOverlayWindow(editor, {
                        id = "ine_import_window",
                        title = "导入节点文件",
                        x = editor.x + (editor.width - 500) / 2,
                        y = editor.y + (editor.height - 400) / 2,
                        width = 500,
                        height = 400,
                        content = function(ed, win, cx, cy, cw, ch)
                            INE:DrawImportWindowContent(ed, win, cx, cy, cw, ch)
                        end
                    })
                end
            else
                -- 清空画布
                ClearNodeEditor(editor.id)
                INE:AddNotification(editor, "画布已清空", Color(100, 255, 100), 3, true)
            end
        elseif itemIndex == 4 and editor.editorMode == "function" then
            -- 函数模式：清空画布
            ClearNodeEditor(editor.id)
            INE:AddNotification(editor, "画布已清空", Color(100, 255, 100), 3, true)
        end
end

--[[
    INE 输入路由入口（2026-11-08，ADR 0004）。
    只负责两件事：组装原始输入上下文、按动作表路由。
    端口几何由 KARDS.CardEditor.Geometry 按帧惰性计算，命中时自行取用（ADR 0006）。
    动作表见 cl_ine_input_actions.lua。

    @param  editor {table} 编辑器实例对象
    @return {string|nil} 被消费的动作名
]]
function INE:RouteInput(editor)
    local Router = KARDS.CardEditor.InputRouter
    if not Router or not INE.InputActions then return end

    local wheel = 0
    if INE._wheelZoomIn then
        wheel = 1
    elseif INE._wheelZoomOut then
        wheel = -1
    end

    local ctx = Router.BuildContext(editor, {
        x = gui.MouseX(),
        y = gui.MouseY(),
        leftDown = input.IsMouseDown(MOUSE_LEFT),
        rightDown = input.IsMouseDown(MOUSE_RIGHT),
        middleDown = input.IsMouseDown(MOUSE_MIDDLE),
        wheel = wheel
    })
    local consumed = Router.Route(editor, ctx, INE.InputActions)
    Router.Commit(editor, ctx)
    return consumed
end
