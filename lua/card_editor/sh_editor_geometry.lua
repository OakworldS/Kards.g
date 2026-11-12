--[[
=======================================================================================
编辑器几何模块（Editor Geometry）
=======================================================================================
节点图在屏幕坐标下的位置计算与命中判定，供独立节点编辑器与卡牌画布共用。
见 docs/adr/0006-节点几何深模块.md。

职责：
  - 视图变换：画布区域、世界坐标与屏幕坐标互换
  - 端口矩形：端口中心与半径、加号按钮矩形、多选下拉框矩形，按节点与帧号惰性缓存
  - 曲线采样：执行线（水平）与数据线（垂直）的贝塞尔离散点
  - 折线距离：点到折线的最短距离

约定：
  - 纯几何，不依赖编辑器会话与绘制状态
  - 端口矩形每次计算后同步写回节点的六个旧字段，保持既有读取方兼容
=======================================================================================
]]

local Geometry = {}
KARDS.CardEditor.Geometry = Geometry

-- GMod 提供 math.Round，离线环境用四舍五入兜底
local Round = math.Round or function(value)
    return math.floor(value + 0.5)
end

--[[
    统一计算画布区域，返回画布在屏幕上的位置和尺寸。

    @param  editor {table} 编辑器实例对象
    @return {table} 画布区域 {x, y, w, h}
]]
function Geometry.GetCanvasRect(editor)
    local canvasX = editor.x + 5 + (editor.borderless and 0 or 160)
    local canvasY = editor.borderless and editor.y or (editor.y + 45)
    local canvasW = editor.width - 10 - (editor.borderless and 0 or 160)
    local canvasH = editor.borderless and editor.height or (editor.height - 45)
    return {x = canvasX, y = canvasY, w = canvasW, h = canvasH}
end

--[[
    将画布世界坐标转换为屏幕坐标。

    @param  editor {table}  编辑器实例对象
    @param  worldX {number} 画布世界X坐标
    @param  worldY {number} 画布世界Y坐标
    @return {number, number} 屏幕X, Y坐标
]]
function Geometry.WorldToScreen(editor, worldX, worldY)
    local rect = Geometry.GetCanvasRect(editor)
    local screenX = rect.x + (worldX + editor.canvasOffsetX) * editor.canvasScale
    local screenY = rect.y + (worldY + editor.canvasOffsetY) * editor.canvasScale
    -- 四舍五入到整数坐标，避免小数坐标导致整数鼠标坐标的命中检测失败
    return Round(screenX), Round(screenY)
end

--[[
    将屏幕坐标转换为画布世界坐标。

    @param  editor  {table}  编辑器实例对象
    @param  screenX {number} 屏幕X坐标
    @param  screenY {number} 屏幕Y坐标
    @return {number, number} 画布世界X, Y坐标
]]
function Geometry.ScreenToWorld(editor, screenX, screenY)
    local rect = Geometry.GetCanvasRect(editor)
    local worldX = (screenX - rect.x) / editor.canvasScale - editor.canvasOffsetX
    local worldY = (screenY - rect.y) / editor.canvasScale - editor.canvasOffsetY
    return worldX, worldY
end

--[[
    按固定步数采样三次贝塞尔曲线。

    @param  p1x, p1y 起点
    @param  p2x, p2y 控制点一
    @param  p3x, p3y 控制点二
    @param  p4x, p4y 终点
    @param  steps    采样步数
    @return {table} 点列表，长度为 steps + 1
]]
function Geometry.SampleCubic(p1x, p1y, p2x, p2y, p3x, p3y, p4x, p4y, steps)
    steps = steps or 20
    local points = {}
    for i = 0, steps do
        local t = i / steps
        local it = 1 - t
        local x = it ^ 3 * p1x + 3 * it ^ 2 * t * p2x + 3 * it * t ^ 2 * p3x + t ^ 3 * p4x
        local y = it ^ 3 * p1y + 3 * it ^ 2 * t * p2y + 3 * it * t ^ 2 * p3y + t ^ 3 * p4y
        points[i + 1] = {x = x, y = y}
    end
    return points
end

--[[
    构建连接线采样点。

    @param  fromX, fromY 起点屏幕坐标
    @param  toX, toY     终点屏幕坐标
    @param  mode         "horizontal" 为执行线，"vertical" 为数据线
    @param  steps        采样步数，缺省按模式取 40 或 20
    @return {table} 点列表
]]
function Geometry.BuildCurvePoints(fromX, fromY, toX, toY, mode, steps)
    if mode == "vertical" then
        -- 数据线：控制点沿垂直方向偏移三分之一并额外外扩 30 像素
        local distance = toY - fromY
        local cp1x, cp1y = fromX, fromY + distance / 3 + 30
        local cp2x, cp2y = toX, toY - distance / 3 - 30
        return Geometry.SampleCubic(fromX, fromY, cp1x, cp1y, cp2x, cp2y, toX, toY, steps or 20)
    end
    -- 执行线：控制点落在水平方向的三分之一与三分之二处
    local distance = toX - fromX
    local cp1x, cp1y = fromX + distance / 3, fromY
    local cp2x, cp2y = fromX + distance * 2 / 3, toY
    return Geometry.SampleCubic(fromX, fromY, cp1x, cp1y, cp2x, cp2y, toX, toY, steps or 40)
end

--[[
    点到线段的最短距离。

    @return {number} 距离
]]
function Geometry.PointToSegmentDistance(px, py, x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local lenSq = dx * dx + dy * dy
    if lenSq == 0 then
        return math.sqrt((px - x1) ^ 2 + (py - y1) ^ 2)
    end
    local t = ((px - x1) * dx + (py - y1) * dy) / lenSq
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local nearX = x1 + t * dx
    local nearY = y1 + t * dy
    return math.sqrt((px - nearX) ^ 2 + (py - nearY) ^ 2)
end

--[[
    点到折线的最短距离。点不足两个时返回 math.huge。

    @param  px, py 点坐标
    @param  points 折线点列表
    @return {number} 距离
]]
function Geometry.DistanceToPolyline(px, py, points)
    local best = math.huge
    for i = 1, #points - 1 do
        local distance = Geometry.PointToSegmentDistance(px, py, points[i].x, points[i].y, points[i + 1].x, points[i + 1].y)
        if distance < best then
            best = distance
        end
    end
    return best
end

-- 多选下拉框命中矩形，与 INE:DrawMultiSelectDropdown 的布局公式一致
local function MultiSelectRect(x, y, optionCount, scale)
    if optionCount <= 0 then
        return {x = x, y = y, w = 0, h = 0}
    end
    local columns = math.min(3, math.max(1, optionCount))
    local optionW = 180 * scale
    local optionH = 28 * scale
    local padding = 8 * scale
    local rows = math.ceil(optionCount / columns)
    return {
        x = x,
        y = y,
        w = columns * optionW + (columns - 1) * padding,
        h = rows * optionH + (rows - 1) * padding
    }
end

-- 计算一组端口的几何：位置、加号按钮矩形、多选下拉框矩形
local function ComputePorts(nodeX, nodeW, portsY, scale, options, selectedPorts, dropdownActive, buttonAllowed, fixedLeft)
    local portR = 6 * scale
    local portSpacing = 4 * scale
    local buttonSize = portR * 2
    local portCount = #selectedPorts
    local hasButton = buttonAllowed and options and #options > 0

    local totalWidth
    if portCount > 0 then
        totalWidth = portCount * (portR * 2 + portSpacing) + (hasButton and (buttonSize + portSpacing) or 0)
    else
        totalWidth = hasButton and buttonSize or 0
    end
    local startX
    if fixedLeft then
        startX = nodeX
    else
        startX = nodeX + nodeW / 2 - totalWidth / 2 + portR
    end

    local positions = {}
    for i, portData in ipairs(selectedPorts) do
        positions[i] = {
            x = startX + (i - 1) * (portR * 2 + portSpacing),
            y = portsY,
            radius = portR,
            data = portData
        }
    end

    local buttonRect
    local addButtonX
    if hasButton then
        if portCount > 0 then
            addButtonX = startX + portCount * (portR * 2 + portSpacing) + portSpacing
        else
            addButtonX = startX
        end
        buttonRect = {
            x = addButtonX - portR - 2 * scale,
            y = portsY - portR - 2 * scale,
            w = buttonSize + 4 * scale,
            h = buttonSize + 4 * scale
        }
    end

    local dropdownRect
    if hasButton and dropdownActive then
        dropdownRect = MultiSelectRect(addButtonX - 90 * scale, portsY + portR + 4 * scale, #options, scale)
    end

    return {
        positions = positions,
        buttonRect = buttonRect,
        dropdownRect = dropdownRect
    }
end

--[[
    计算节点的端口矩形，按节点与帧号惰性缓存。
    缓存失效条件覆盖帧号、缩放、平移、节点位置与尺寸、下拉框展开状态。

    @param  editor {table} 编辑器实例对象
    @param  node   {table} 节点实例
    @return {table} { output = {...}, input = {...}, scale }
]]
function Geometry.GetPortRects(editor, node)
    local scale = editor.canvasScale
    local frame = FrameNumber and FrameNumber() or 0
    local outputCount = #(node.selectedOutputTypes or {})
    local inputCount = #(node.selectedInputTypes or {})
    local outputOptionCount = node.availableOutputTypes and #node.availableOutputTypes or 0
    local inputOptionCount = node.availableInputTypes and #node.availableInputTypes or 0
    local cached = node._geometry
    if cached
        and node._geometryFrame == frame
        and node._geometryScale == scale
        and node._geometryNodeX == node.x
        and node._geometryNodeY == node.y
        and node._geometryNodeW == node.width
        and node._geometryNodeH == node.height
        and node._geometryOffsetX == editor.canvasOffsetX
        and node._geometryOffsetY == editor.canvasOffsetY
        and node._geometryDropdownOutput == node.dataPortDropdownActive
        and node._geometryDropdownInput == node.inputDataPortDropdownActive
        and node._geometryOutputCount == outputCount
        and node._geometryInputCount == inputCount
        and node._geometryOutputOptionCount == outputOptionCount
        and node._geometryInputOptionCount == inputOptionCount then
        return cached
    end

    local nodeX, nodeY = Geometry.WorldToScreen(editor, node.x, node.y)
    local nodeW = node.width * scale
    local nodeH = node.height * scale

    -- 输出端口：普通节点与底边重合，开始点垂直居中；数据源开始点固定在左边缘
    local outputPortsY = nodeY + nodeH
    if node.isStartNode then
        outputPortsY = nodeY + nodeH / 2
    end
    local output = ComputePorts(nodeX, nodeW, outputPortsY, scale,
        node.availableOutputTypes, node.selectedOutputTypes or {}, node.dataPortDropdownActive, not node.isStartNode, node.isStartNode)

    -- 输入端口：与顶边重合，水平居中
    local input = ComputePorts(nodeX, nodeW, nodeY, scale,
        node.availableInputTypes, node.selectedInputTypes or {}, node.inputDataPortDropdownActive, true)

    local geometry = {
        output = output,
        input = input,
        scale = scale
    }

    -- 同步旧字段，保持既有读取方兼容；只有几何模块写这些字段
    node._outputDataPortPositions = output.positions
    node._dataPortButtonRect = output.buttonRect
    node._dataPortDropdownRect = output.dropdownRect
    node._inputDataPortPositions = input.positions
    node._inputDataPortButtonRect = input.buttonRect
    node._inputDataPortDropdownRect = input.dropdownRect

    node._geometry = geometry
    node._geometryFrame = frame
    node._geometryScale = scale
    node._geometryNodeX = node.x
    node._geometryNodeY = node.y
    node._geometryNodeW = node.width
    node._geometryNodeH = node.height
    node._geometryOffsetX = editor.canvasOffsetX
    node._geometryOffsetY = editor.canvasOffsetY
    node._geometryDropdownOutput = node.dataPortDropdownActive
    node._geometryDropdownInput = node.inputDataPortDropdownActive
    node._geometryOutputCount = outputCount
    node._geometryInputCount = inputCount
    node._geometryOutputOptionCount = outputOptionCount
    node._geometryInputOptionCount = inputOptionCount

    return geometry
end

return Geometry
