--[[
=======================================================================================
编辑器子系统：cl_ine_hit_test.lua
=======================================================================================
从 cl_ine_node_editor.lua 拆分出的子系统：命中检测（矩形与圆形判定、节点与端口查找、节点ID索引）。
源行范围：cl_ine_node_editor.lua 第 4674 至 5107 行（2026-10-18 拆分时点）。
=======================================================================================
]]

local INE = KARDS.CardEditor.IndependentNodeEditor
local T = KARDS.Lang.T

--[[
    判断一个点是否在矩形区域内（碰撞检测工具函数）。
    
    @param  px    {number}  点的X坐标（屏幕坐标）
    @param  py    {number}  点的Y坐标（屏幕坐标）
    @param  rect  {table}   矩形区域 {x, y, w, h}
    
    @return {boolean} 点在矩形内返回true，否则返回false
]]
function INE:IsPointInRect(px, py, rect)
    return px >= rect.x and px <= rect.x + rect.w and py >= rect.y and py <= rect.y + rect.h
end

--[[
    判断点是否在圆形内。
    用于检测鼠标是否悬停在圆形按钮或数据点上。
    
    @param  px      {number}  点X坐标
    @param  py      {number}  点Y坐标
    @param  cx      {number}  圆心X坐标
    @param  cy      {number}  圆心Y坐标
    @param  radius  {number}  圆半径
    
    @return {boolean} 点在圆内返回true，否则返回false
]]
function INE:IsPointInCircle(px, py, cx, cy, radius)
    local dx = px - cx
    local dy = py - cy
    return (dx * dx + dy * dy) <= (radius * radius)
end

--[[
    判断鼠标是否在节点的标题栏区域。
    标题栏高度为 24px（乘以画布缩放后的屏幕坐标）。
    开始点（isStartNode）没有标题栏，始终返回 false。
    
    @param  editor  {table}   编辑器实例对象
    @param  node    {table}   节点实例
    @param  mouseX  {number}  鼠标X坐标（屏幕坐标）
    @param  mouseY  {number}  鼠标Y坐标（屏幕坐标）
    
    @return {boolean} 鼠标在标题栏区域内返回 true
]]
function INE:IsMouseOnNodeTitle(editor, node, mouseX, mouseY)
    if node.isStartNode then return false end
    local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
    local nodeW = node.width * editor.canvasScale
    local titleH = 24 * editor.canvasScale
    return mouseX >= nodeX and mouseX <= nodeX + nodeW and
           mouseY >= nodeY and mouseY <= nodeY + titleH
end

--[[
    检测鼠标是否在节点的内容区域（标题栏下方、非端口区域）。
    用于区分"点击节点体选中输出点"与"拖拽连线从端口开始"。
    
    @param  editor  {table}   编辑器实例对象
    @param  node    {table}   要检测的节点
    @param  mouseX  {number}  鼠标屏幕X坐标
    @param  mouseY  {number}  鼠标屏幕Y坐标
    
    @return {boolean} 是否在节点内容区域
]]
function INE:IsMouseOnNodeBody(editor, node, mouseX, mouseY)
    if node.isStartNode then return false end
    local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
    local nodeW = node.width * editor.canvasScale
    local nodeH = node.height * editor.canvasScale
    local titleH = 24 * editor.canvasScale
    return mouseX >= nodeX + 20 * editor.canvasScale and mouseX <= nodeX + nodeW - 20 * editor.canvasScale and
           mouseY >= nodeY + titleH and mouseY <= nodeY + nodeH - 20 * editor.canvasScale
end

--[[
    根据节点ID在编辑器中查找节点实例。
    
    @param  editor  {table}   编辑器实例对象
    @param  nodeID  {string}  要查找的节点ID
    
    @return {table|nil} 找到的节点实例，未找到返回nil
]]
-- 节点ID索引缓存：每帧（或节点数量变化时）重建一次，避免绘制与命中检测路径
-- 反复线性扫描 editor.nodes，把整体复杂度从 O(节点数 × 查询次数) 降为
-- O(节点数 + 查询次数)。以帧号与节点数量作为失效依据：新增、删除、导入、
-- 清空节点都会改变节点数量，从而触发重建。
function INE:GetNodeByID(editor, nodeID)
    local index = editor._nodeIdIndex
    if index == nil then
        index = {}
        editor._nodeIdIndex = index
    end

    local frame = FrameNumber()
    local count = #editor.nodes
    if editor._nodeIdIndexFrame ~= frame or editor._nodeIdIndexCount ~= count then
        for key in pairs(index) do
            index[key] = nil
        end
        -- 与线性扫描保持一致：重复 ID 时取 editor.nodes 中第一个匹配项
        for _, node in ipairs(editor.nodes) do
            if index[node.id] == nil then
                index[node.id] = node
            end
        end
        editor._nodeIdIndexFrame = frame
        editor._nodeIdIndexCount = count
    end

    return index[nodeID]
end

--[[
    获取指定屏幕坐标处的数据点（用于数据连接拖拽释放检测）。
    根据拖拽的数据点类型，检测相反类型的数据点（输出拖到输入，输入拖到输出）。

    @param  editor      {table}   编辑器实例对象
    @param  screenX     {number}  屏幕X坐标
    @param  screenY     {number}  屏幕Y坐标
    @param  fromType    {string}  拖拽起点类型 ("output" 或 "input")

    @return {table|nil} 命中的数据点信息 {node, portData, portType, portIndex}，未命中返回nil
]]
function INE:GetDataPortAtPosition(editor, screenX, screenY, fromType)
    -- 根据拖拽起点类型，检测相反类型的数据点
    local targetType = (fromType == "output") and "input" or "output"
    local clickPadding = 4 * editor.canvasScale  -- 点击容差

    -- 逆序遍历节点：后创建/后绘制的节点在上层，优先检测
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        if not node.isUnregistered then
            -- 端口几何由共享模块按帧惰性计算，与绘制使用同一份结果（ADR 0006）
            local geometry = KARDS.CardEditor.Geometry.GetPortRects(editor, node)
            local portPositions = (targetType == "input") and geometry.input.positions or geometry.output.positions
            for j, portPos in ipairs(portPositions) do
                local clickRadius = (portPos.radius or 0) + clickPadding
                if self:IsPointInCircle(screenX, screenY, portPos.x, portPos.y, clickRadius) then
                    return {
                        node = node,
                        portData = portPos.data,
                        portType = targetType,
                        portIndex = j
                    }
                end
            end
        end
    end
    return nil
end

--[[
    获取指定屏幕坐标处的节点（从上到下逆序遍历，优先返回最上层节点）。

    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标

    @return {table|nil} 命中的节点实例，未命中返回nil
]]
function INE:GetNodeAtPosition(editor, screenX, screenY)
    -- 逆序遍历：后创建/后绘制的节点在上层，优先检测
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        -- 跳过开始点节点（只能通过端口圆点选中，不由 GetNodeAtPosition 处理）
        if not node.isStartNode then
            local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
            local nodeW = node.width * editor.canvasScale
            local nodeH = node.height * editor.canvasScale

            if screenX >= nodeX and screenX <= nodeX + nodeW and
               screenY >= nodeY and screenY <= nodeY + nodeH then
                return node
            end
        end
    end
    return nil
end

--[[
    检测屏幕坐标是否在某个节点的"添加数据点"按钮（绿色/深蓝色圆形）上。
    数据点按钮位于节点边线上，半径超出节点边界。
    用于在 GetNodeAtPosition 之前优先检测，确保点击数据点按钮能正确触发。

    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标

    @return {table|nil} 命中的节点实例（数据点按钮属于该节点），未命中返回nil
]]
function INE:GetDataPortButtonNodeAtPosition(editor, screenX, screenY)
    -- 逆序遍历：后创建的节点在上层
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        if not node.isStartNode then
            -- 按钮矩形由共享几何模块维护，与绘制使用同一份结果（ADR 0006）
            local geometry = KARDS.CardEditor.Geometry.GetPortRects(editor, node)
            -- 检查输出数据点按钮（绿色"+"号）
            if geometry.output.buttonRect and self:IsPointInRect(screenX, screenY, geometry.output.buttonRect) then
                return node
            end
            -- 检查输入数据点按钮（深蓝色"+"号）
            if geometry.input.buttonRect and self:IsPointInRect(screenX, screenY, geometry.input.buttonRect) then
                return node
            end
        end
    end
    return nil
end

--[[
    全局检测屏幕坐标是否在任意节点的数据点图标上（输出或输入）。
    数据点图标位于节点边线上，半径超出节点边界，GetNodeAtPosition 无法命中。
    需要在 GetNodeAtPosition 之前独立检测。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中的数据点信息 {node, portData, portType, portIndex}，未命中返回nil
]]
function INE:GetDataPortIconAtPosition(editor, screenX, screenY)
    local clickPadding = 4 * editor.canvasScale
    -- 逆序遍历：后创建/后绘制的节点在上层，优先检测
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        -- 允许开始点（含数据源开始点如"钳击对象"）的数据端口作为拖线起点；
        -- 普通开始点无数据端口，不受影响
        if not node.isUnregistered then
            -- 端口几何由共享模块按帧惰性计算，与绘制使用同一份结果（ADR 0006）
            local geometry = KARDS.CardEditor.Geometry.GetPortRects(editor, node)
            -- 检测输出数据点
            for j, portPos in ipairs(geometry.output.positions) do
                local clickRadius = (portPos.radius or 0) + clickPadding
                if self:IsPointInCircle(screenX, screenY, portPos.x, portPos.y, clickRadius) then
                    return {
                        node = node,
                        portData = portPos.data,
                        portType = "output",
                        portIndex = j
                    }
                end
            end
            -- 检测输入数据点
            for j, portPos in ipairs(geometry.input.positions) do
                local clickRadius = (portPos.radius or 0) + clickPadding
                if self:IsPointInCircle(screenX, screenY, portPos.x, portPos.y, clickRadius) then
                    return {
                        node = node,
                        portData = portPos.data,
                        portType = "input",
                        portIndex = j
                    }
                end
            end
        end
    end
    return nil
end

--[[
    检测屏幕坐标是否在节点的交互式元素（下拉框、数字框）上。
    用于 HandleInput 中拦截点击，避免穿透到输出点选中逻辑。
    
    @param  editor   {table}   编辑器实例对象
    @param  node     {table}   要检测的节点
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {boolean} 点击在交互式元素上返回 true，否则返回 false
]]
function INE:GetNodeInteractiveElement(editor, node, screenX, screenY)
    -- 使用绘制阶段记录的交互元素包围盒进行命中检测，
    -- 避免重复布局逻辑导致的位置偏差。
    local rects = editor._interactiveRects
    if not rects then return false end
    
    for _, rect in ipairs(rects) do
        if rect.nodeId == node.id and
           screenX >= rect.x and screenX <= rect.x + rect.w and
           screenY >= rect.y and screenY <= rect.y + rect.h then
            return true
        end
    end
    return false
end

--[[
    检测屏幕坐标是否在指定节点的输出端口上。
    
    @param  editor   {table}   编辑器实例对象
    @param  node     {table}   要检测的节点
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {string|nil} 命中返回端口标识 "output"，未命中返回nil
]]
function INE:GetOutputPortAtPosition(editor, node, screenX, screenY)
    if not node.hasOutput then return nil end
    
    local portR = 6 * editor.canvasScale
    local clickR = 24 * editor.canvasScale
    
    if node.hasSecondOutput then
        -- 双分支：检测两个端口
        local nodeScreenX, nodeScreenY = self:WorldToScreen(editor, node.x, node.y)
        local nodeW = node.width * editor.canvasScale
        local nodeH = node.height * editor.canvasScale
        local portScreenX = nodeScreenX + nodeW
        
        -- 满足分支（上）
        local topPortScreenY = nodeScreenY + nodeH / 3
        local dx = screenX - portScreenX
        local dy = screenY - topPortScreenY
        if dx * dx + dy * dy <= clickR * clickR then
            return "satisfied"
        end
        
        -- 不满足分支（下）
        local botPortScreenY = nodeScreenY + nodeH * 2 / 3
        dy = screenY - botPortScreenY
        if dx * dx + dy * dy <= clickR * clickR then
            return "not_satisfied"
        end
        
        return nil
    else
        -- 单输出端口：圆形距离检测
        local portScreenX, portScreenY = self:WorldToScreen(editor, node.x + node.width, node.y + node.height / 2)
        local dx = screenX - portScreenX
        local dy = screenY - portScreenY
        if dx * dx + dy * dy <= clickR * clickR then
            return "output"
        end
        return nil
    end
end

--[[
    检测屏幕坐标是否在某个开始点节点的输出端口圆点上。
    开始点仅通过端口圆点（而非整个节点矩形）进行选中。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中的开始点节点实例，未命中返回nil
]]
function INE:GetStartNodeAtPort(editor, screenX, screenY)
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        -- 数据源开始点（钳击对象）无执行输出端口，其中数据端口由 GetDataPortIconAtPosition 处理
        if node.isStartNode and node.name ~= "data_start_point" then
            local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
            local portR = 6 * editor.canvasScale
            local portCX = nodeX  -- 端口圆心在 Y 轴（node.x = 0）
            local portCY = nodeY + node.height * editor.canvasScale / 2  -- 端口圆心Y（垂直居中）

            -- 检测鼠标是否在端口圆点范围内（使用 24*scale 的圆形命中半径）
            local hitR = 24 * editor.canvasScale
            local dx = screenX - portCX
            local dy = screenY - portCY
            if dx * dx + dy * dy <= hitR * hitR then
                return node
            end
        end
    end
    return nil
end

--[[
    检测屏幕坐标是否在任意节点的输入端口上（返回节点，用于拖拽连线检测悬停）。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中输入端口的节点，未命中返回nil
]]
function INE:GetInputNodeAtPosition(editor, screenX, screenY)
    local hitR = 24 * editor.canvasScale

    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        if not node.isStartNode and node.hasInput then
            local portScreenX, portScreenY = self:WorldToScreen(editor, node.x, node.y + node.height / 2)
            local dx = screenX - portScreenX
            local dy = screenY - portScreenY
            if dx * dx + dy * dy <= hitR * hitR then
                return node
            end
        end
    end
    return nil
end

--[[
    检测屏幕坐标是否在任意节点的输入端口上。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中返回 {node = 目标节点}，未命中返回nil
]]
function INE:GetInputPortAtPosition(editor, screenX, screenY)
    local hitR = 24 * editor.canvasScale
    
    for _, node in ipairs(editor.nodes) do
        if node.hasInput then
            local portScreenX, portScreenY = self:WorldToScreen(editor, node.x, node.y + node.height / 2)
            local dx = screenX - portScreenX
            local dy = screenY - portScreenY
            if dx * dx + dy * dy <= hitR * hitR then
                return {node = node}
            end
        end
    end
    return nil
end

--[[
    检测屏幕坐标是否在某条连接线（事件连线或数据连线）附近。
    事件连线使用水平三次贝塞尔曲线，数据连线使用垂直三次贝塞尔曲线，
    控制点计算与绘制阶段保持一致。命中多条时返回距离最近的一条。

    @param  editor    {table}   编辑器实例对象
    @param  screenX   {number}  屏幕X坐标
    @param  screenY   {number}  屏幕Y坐标
    @param  threshold {number}  命中阈值（屏幕像素）

    @return {table|nil, boolean} 命中的连接线对象，以及是否为数据连线
]]
function INE:GetConnectionAtPosition(editor, screenX, screenY, threshold)
    threshold = threshold or (8 * editor.canvasScale)
    local thresholdSq = threshold * threshold
    local bestConn, bestIsData, bestDistSq

    local function Consider(points, conn, isData)
        for i = 1, #points - 1 do
            local a, b = points[i], points[i + 1]
            local dx, dy = b.x - a.x, b.y - a.y
            local lenSq = dx * dx + dy * dy
            local t = 0
            if lenSq > 0 then
                t = math.Clamp(((screenX - a.x) * dx + (screenY - a.y) * dy) / lenSq, 0, 1)
            end
            local px, py = a.x + dx * t, a.y + dy * t
            local ddx, ddy = screenX - px, screenY - py
            local distSq = ddx * ddx + ddy * ddy
            if distSq <= thresholdSq and (not bestDistSq or distSq < bestDistSq) then
                bestDistSq = distSq
                bestConn = conn
                bestIsData = isData
            end
        end
    end

    local function BuildPoints(fromX, fromY, toX, toY, vertical)
        -- 采样由共享几何模块统一提供，步数与绘制一致（ADR 0006）
        return KARDS.CardEditor.Geometry.BuildCurvePoints(fromX, fromY, toX, toY, vertical and "vertical" or "horizontal")
    end

    for _, conn in ipairs(editor.connections) do
        local fromNode = INE:GetNodeByID(editor, conn.fromNode)
        local toNode = INE:GetNodeByID(editor, conn.toNode)
        if fromNode and toNode and INE:IsConnectionVisible(editor, fromNode, toNode) then
            local fromPortX = fromNode.isStartNode and fromNode.x or (fromNode.x + fromNode.width)
            local fromWorldY = fromNode.y + fromNode.height / 2
            if fromNode.hasSecondOutput then
                if conn.fromPort == "satisfied" then
                    fromWorldY = fromNode.y + fromNode.height / 3
                elseif conn.fromPort == "not_satisfied" then
                    fromWorldY = fromNode.y + fromNode.height * 2 / 3
                end
            end
            local fromX, fromY = INE:WorldToScreen(editor, fromPortX, fromWorldY)
            local toX, toY = INE:WorldToScreen(editor, toNode.x, toNode.y + toNode.height / 2)
            Consider(BuildPoints(fromX, fromY, toX, toY, false), conn, false)
        end
    end

    for _, conn in ipairs(editor.dataConnections or {}) do
        local fromNode = INE:GetNodeByID(editor, conn.fromNode)
        local toNode = INE:GetNodeByID(editor, conn.toNode)
        if fromNode and toNode then
            local fromPortPos = fromNode._outputDataPortPositions and fromNode._outputDataPortPositions[conn.fromPortIndex]
            local toPortPos = toNode._inputDataPortPositions and toNode._inputDataPortPositions[conn.toPortIndex]
            if fromPortPos and toPortPos then
                Consider(BuildPoints(fromPortPos.x, fromPortPos.y, toPortPos.x, toPortPos.y, true), conn, true)
            end
        end
    end

    return bestConn, bestIsData
end
