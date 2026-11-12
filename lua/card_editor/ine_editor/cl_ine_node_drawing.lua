--[[
=======================================================================================
节点绘制系统 (Node Drawing System)
=======================================================================================
从 cl_ine_node_editor.lua 拆分出的子系统，负责节点编辑器的所有视觉绘制。

包含功能：
  - UpdateDataPortPositions（更新节点数据点位置）
  - DrawDataPorts（绘制节点底边输出数据点）
  - DrawInputDataPorts（绘制节点顶边输入数据点）
  - DrawNode（绘制完整节点）
  - DrawConnection（绘制事件流连接线）
  - GetConnectionColor（获取连接线颜色）
  - DrawThickCurve（绘制粗贝塞尔曲线）
  - GetCurveNormals（计算曲线法线）
  - DrawTempConnection（绘制临时拖拽连接线）
  - DrawDataConnection（绘制数据流连接线）
  - DrawTempDataConnection（绘制临时数据连接线）
  - DrawSelectedOutputFeedback（绘制选中输出反馈曲线）
  - DrawTempNodePreview（绘制临时节点预览）
  - DrawImportWarningDialog（绘制导入警告对话框）

依赖：
  - INE 编辑器实例的画布变换函数（WorldToScreen、ScreenToWorld）
  - INE 颜色/着色方案

源文件：cl_ine_node_editor.lua（行 4859~5930）
=======================================================================================
]]

-- 此文件内容将剪切自 cl_ine_node_editor.lua 行 4859~5930
-- 包含：UpdateDataPortPositions、DrawDataPorts、DrawInputDataPorts、DrawNode、
--       DrawConnection、GetConnectionColor、DrawThickCurve、GetCurveNormals、
--       DrawTempConnection、DrawDataConnection、DrawTempDataConnection、
--       DrawSelectedOutputFeedback、DrawTempNodePreview、DrawImportWarningDialog
local INE = KARDS.CardEditor.IndependentNodeEditor
-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- 绘制期颜色记忆化：绘制路径下同一 (r,g,b,a) 组合每帧被反复构造，
-- 记忆后仅在首次调用时创建 Color 表，绘制期间不再产生临时表分配。
-- 颜色值相同即等价，本文件内不存在对颜色表字段的写入（已核实）。
-- 仅对 0~255 的整数分量做记忆化；浮点分量（如逐帧插值的 alpha）直接构造，
-- 避免缓存键随浮点值变化而无限增长。
local drawColorCache = {}
local function C(r, g, b, a)
    local alpha = a or 255
    if r % 1 == 0 and g % 1 == 0 and b % 1 == 0 and alpha % 1 == 0
        and r >= 0 and r <= 255 and g >= 0 and g <= 255
        and b >= 0 and b <= 255 and alpha >= 0 and alpha <= 255 then
        local key = ((r * 256 + g) * 256 + b) * 256 + alpha
        local color = drawColorCache[key]
        if not color then
            color = Color(r, g, b, a)
            drawColorCache[key] = color
        end
        return color
    end
    return Color(r, g, b, a)
end

--[[
    更新节点的数据点位置（用于点击检测）。
    独立计算数据点位置，不依赖绘制流程。
    
    @param  editor   {table}   编辑器实例对象
    @param  node     {table}   节点实例
    @param  portType {string}  端口类型 ("output" 或 "input")
]]
function INE:UpdateDataPortPositions(editor, node, portType)
    -- 计算体已迁至共享几何模块（ADR 0006），此处保留签名供既有调用方使用；
    -- portType 不再区分，几何模块一次算齐输出与输入端口
    return KARDS.CardEditor.Geometry.GetPortRects(editor, node)
end

--[[
    绘制节点底边的输出数据点。
    包括：绿色"增加数据点"按钮、已选择的数据点图标。
    点击按钮后显示多选下拉框选择数据类型。
    
    @param  editor  {table}     编辑器实例对象
    @param  node    {table}     要绘制的节点实例对象
]]
function INE:DrawDataPorts(editor, node)
    local selectedPorts = node.selectedOutputTypes or {}
    local portCount = #selectedPorts
    -- 是否有"增加数据点"按钮（有可用类型时才绘制按钮；开始点数据端口固定，不绘制增删按钮）
    local hasButton = node.availableOutputTypes and #node.availableOutputTypes > 0 and not node.isStartNode
    -- 无可用类型且无已选端口时无需绘制；
    -- 有已选端口即使无可用类型也绘制（如"新建变量"节点的动态输出点，无添加按钮）
    if not hasButton and portCount == 0 then return end

    local scale = editor.canvasScale
    local portR = 6 * scale
    local buttonSize = portR * 2

    -- 端口位置、按钮矩形、下拉框矩形统一由共享几何模块计算并写入节点字段（ADR 0006）
    local geometry = KARDS.CardEditor.Geometry.GetPortRects(editor, node)

    -- 绘制已选择的数据点
    for i, portData in ipairs(selectedPorts) do
        local position = geometry.output.positions[i]
        -- 兼容多种端口格式：{id=} / {type=} / 类型引用 / 字符串
        local dataType = INE.GetDataTypeById(portData.id or portData.type or portData)
        if dataType and position then
            INE.DrawDataTypeIcon(dataType, position.x, position.y, portR * 2)
        end
    end

    -- 绘制"增加数据点"按钮（绿色圆形，带+号），与节点底边重合（无可用类型时无按钮）
    local addButtonX, addButtonY
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    if hasButton and geometry.output.buttonRect then
        -- 按钮中心由几何模块的按钮矩形反推，与命中判定使用同一份几何
        local buttonRect = geometry.output.buttonRect
        addButtonX = buttonRect.x + buttonRect.w / 2
        addButtonY = buttonRect.y + buttonRect.h / 2

        -- 检查鼠标悬停
        local isHovered = self:IsPointInCircle(mouseX, mouseY, addButtonX, addButtonY, portR + 2 * scale)

        -- 绘制按钮背景（绿色）
        local buttonColor = isHovered and C(80, 200, 80) or C(60, 180, 60)
        draw.RoundedBox(portR, addButtonX - portR, addButtonY - portR, buttonSize, buttonSize, buttonColor)

        -- 根据选中状态绘制符号
        -- "+": 无选中（仅添加）；"-": 全选（仅移除）；"+/-": 部分选中（可添可删）
        surface.SetDrawColor(C(255, 255, 255))
        local crossSize = 4 * scale
        local selectedCount = #selectedPorts
        local totalCount = #node.availableOutputTypes
        if selectedCount == 0 then
            -- "+": 仅添加
            surface.DrawLine(addButtonX - crossSize, addButtonY, addButtonX + crossSize, addButtonY)
            surface.DrawLine(addButtonX, addButtonY - crossSize, addButtonX, addButtonY + crossSize)
        elseif selectedCount >= totalCount then
            -- "-": 已全选，仅移除
            surface.DrawLine(addButtonX - crossSize, addButtonY, addButtonX + crossSize, addButtonY)
        else
            -- "+/-": 部分选中，可添加可移除
            local halfSize = crossSize * 0.6
            local vOffset = crossSize * 0.45
            -- "+" 在上半部分
            surface.DrawLine(addButtonX - halfSize, addButtonY - vOffset, addButtonX + halfSize, addButtonY - vOffset)
            surface.DrawLine(addButtonX, addButtonY - vOffset - halfSize, addButtonX, addButtonY - vOffset + halfSize)
            -- "-" 在下半部分
            surface.DrawLine(addButtonX - halfSize, addButtonY + vOffset, addButtonX + halfSize, addButtonY + vOffset)
        end

        -- 按钮矩形已由几何模块写入 node._dataPortButtonRect，供点击检测读取（ADR 0006）
    end

    -- 下拉框矩形由几何模块计算，未激活时置 nil（ADR 0006）
    if hasButton and node.dataPortDropdownActive and geometry.output.dropdownRect then
        local dropdownRect = geometry.output.dropdownRect
        local dropdownX = dropdownRect.x
        local dropdownY = dropdownRect.y
        local options = node.availableOutputTypes
        local selectedIndices = {}
        for i, portData in ipairs(selectedPorts) do
            for j, opt in ipairs(options) do
                -- 按 id 匹配（兼容 {id=, name=} / {type=, name=} 自定义端口表与导入数据）
                if (portData.id or portData.type or portData) == (opt.id or opt.type or opt) then
                    selectedIndices[j] = true
                end
            end
        end

        self:DrawMultiSelectDropdown(editor, dropdownX, dropdownY, options, selectedIndices, function(idx, isSelected)
            if isSelected then
                table.insert(node.selectedOutputTypes, options[idx])
            else
                -- 移除选中（按 id 匹配，兼容 {id=, name=} / {type=, name=} 端口表）
                local removedIdx = nil
                for i = #node.selectedOutputTypes, 1, -1 do
                    local sp = node.selectedOutputTypes[i]
                    if (sp.id or sp.type or sp) == (options[idx].id or options[idx].type or options[idx]) then
                        removedIdx = i
                        table.remove(node.selectedOutputTypes, i)
                        break
                    end
                end
                -- 清理与该数据端口关联的数据连接
                if removedIdx and editor.dataConnections then
                    local i = 1
                    while i <= #editor.dataConnections do
                        local dc = editor.dataConnections[i]
                        if dc.fromNode == node.id then
                            if dc.fromPortIndex == removedIdx then
                                -- 移除该端口的连接
                                table.remove(editor.dataConnections, i)
                            elseif dc.fromPortIndex > removedIdx then
                                -- 后续端口索引前移
                                dc.fromPortIndex = dc.fromPortIndex - 1
                                i = i + 1
                            else
                                i = i + 1
                            end
                        else
                            i = i + 1
                        end
                    end
                end
            end
        end, scale)

    end

    -- 检测鼠标悬停在数据点上，显示名称提示（数据源开始点除外：标题已居中显示在节点上，悬停提示冗余）
    if not node.isStartNode then
        for i, posData in ipairs(node._outputDataPortPositions or {}) do
            if self:IsPointInCircle(mouseX, mouseY, posData.x, posData.y, posData.radius + 2 * scale) then
                local tipText = posData.data and (posData.data.name or posData.data.id) or "?"
                local tipFont = self:GetScaledFont("SourceHan_Heavy", 12, scale)
                surface.SetFont(tipFont)
                local textW = surface.GetTextSize(tipText)
                local tipPadding = 4 * scale
                local tipX = mouseX + 10 * scale
                local tipY = mouseY - 10 * scale - 16 * scale
                local tipW = textW + tipPadding * 2
                local tipH = 16 * scale + tipPadding * 2
                draw.RoundedBox(3, tipX, tipY, tipW, tipH, C(30, 30, 40, 230))
                draw.SimpleText(tipText, tipFont, tipX + tipPadding, tipY + tipH / 2, C(255, 255, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                break
            end
        end
    end
end

--[[
    绘制节点顶边的输入数据点。
    包括：深蓝色"输入数据点支持数据"按钮、已选择的输入数据点图标。
    点击按钮后显示多选下拉框选择数据类型。
    
    @param  editor  {table}     编辑器实例对象
    @param  node    {table}     要绘制的节点实例对象
]]
function INE:DrawInputDataPorts(editor, node)
    -- 有可用类型（标准节点）或已有已选端口（如"判断变量关系"动态输入点）时均绘制
    if (not node.availableInputTypes or #node.availableInputTypes == 0)
    and (not node.selectedInputTypes or #node.selectedInputTypes == 0) then return end

    local scale = editor.canvasScale
    local portR = 6 * scale
    local buttonSize = portR * 2

    -- 已选择的输入数据点
    local selectedPorts = node.selectedInputTypes or {}
    -- 是否有"输入数据点支持数据"按钮（无可用类型时不绘制按钮，端口完全由代码自动管理）
    local hasButton = node.availableInputTypes and #node.availableInputTypes > 0

    -- 端口位置、按钮矩形、下拉框矩形统一由共享几何模块计算并写入节点字段（ADR 0006）
    local geometry = KARDS.CardEditor.Geometry.GetPortRects(editor, node)

    -- 绘制已选择的输入数据点
    for i, portData in ipairs(selectedPorts) do
        local position = geometry.input.positions[i]
        -- 兼容多种端口格式：{id=} / {type=} / 类型引用 / 字符串
        local dataType = INE.GetDataTypeById(portData.id or portData.type or portData)
        if dataType and position then
            INE.DrawDataTypeIcon(dataType, position.x, position.y, portR * 2)
        end
    end

    -- 绘制"输入数据点支持数据"按钮（深蓝色圆形，带+号），与节点顶边重合（无可用类型时无按钮）
    local addButtonX, addButtonY
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    if hasButton and geometry.input.buttonRect then
        -- 按钮中心由几何模块的按钮矩形反推，与命中判定使用同一份几何
        local buttonRect = geometry.input.buttonRect
        addButtonX = buttonRect.x + buttonRect.w / 2
        addButtonY = buttonRect.y + buttonRect.h / 2

        -- 检查鼠标悬停
        local isHovered = self:IsPointInCircle(mouseX, mouseY, addButtonX, addButtonY, portR + 2 * scale)

        -- 绘制按钮背景（深蓝色）
        local buttonColor = isHovered and C(80, 120, 200) or C(60, 100, 180)
        draw.RoundedBox(portR, addButtonX - portR, addButtonY - portR, buttonSize, buttonSize, buttonColor)

        -- 根据选中状态绘制符号
        -- "+": 无选中（仅添加）；"-": 全选（仅移除）；"+/-": 部分选中（可添可删）
        surface.SetDrawColor(C(255, 255, 255))
        local crossSize = 4 * scale
        local selectedCount = #selectedPorts
        local totalCount = #node.availableInputTypes
        if selectedCount == 0 then
            -- "+": 仅添加
            surface.DrawLine(addButtonX - crossSize, addButtonY, addButtonX + crossSize, addButtonY)
            surface.DrawLine(addButtonX, addButtonY - crossSize, addButtonX, addButtonY + crossSize)
        elseif selectedCount >= totalCount then
            -- "-": 已全选，仅移除
            surface.DrawLine(addButtonX - crossSize, addButtonY, addButtonX + crossSize, addButtonY)
        else
            -- "+/-": 部分选中，可添加可移除
            local halfSize = crossSize * 0.6
            local vOffset = crossSize * 0.45
            -- "+" 在上半部分
            surface.DrawLine(addButtonX - halfSize, addButtonY - vOffset, addButtonX + halfSize, addButtonY - vOffset)
            surface.DrawLine(addButtonX, addButtonY - vOffset - halfSize, addButtonX, addButtonY - vOffset + halfSize)
            -- "-" 在下半部分
            surface.DrawLine(addButtonX - halfSize, addButtonY + vOffset, addButtonX + halfSize, addButtonY + vOffset)
        end

        -- 按钮矩形已由几何模块写入 node._inputDataPortButtonRect，供点击检测读取（ADR 0006）
    end

    -- 下拉框矩形由几何模块计算，未激活时置 nil（ADR 0006）
    if hasButton and node.inputDataPortDropdownActive and geometry.input.dropdownRect then
        local dropdownRect = geometry.input.dropdownRect
        local dropdownX = dropdownRect.x
        local dropdownY = dropdownRect.y
        local options = node.availableInputTypes
        local selectedIndices = {}
        for i, portData in ipairs(selectedPorts) do
            for j, opt in ipairs(options) do
                -- 按 id 匹配（兼容 {id=, name=} / {type=, name=} 自定义端口表与导入数据）
                if (portData.id or portData.type or portData) == (opt.id or opt.type or opt) then
                    selectedIndices[j] = true
                end
            end
        end

        self:DrawMultiSelectDropdown(editor, dropdownX, dropdownY, options, selectedIndices, function(idx, isSelected)
            if isSelected then
                table.insert(node.selectedInputTypes, options[idx])
            else
                -- 移除选中（按 id 匹配，兼容 {id=, name=} / {type=, name=} 端口表）
                local removedIdx = nil
                for i = #node.selectedInputTypes, 1, -1 do
                    local sp = node.selectedInputTypes[i]
                    if (sp.id or sp.type or sp) == (options[idx].id or options[idx].type or options[idx]) then
                        removedIdx = i
                        table.remove(node.selectedInputTypes, i)
                        break
                    end
                end
                -- 清理与该输入数据端口关联的数据连接
                if removedIdx and editor.dataConnections then
                    local i = 1
                    while i <= #editor.dataConnections do
                        local dc = editor.dataConnections[i]
                        if dc.toNode == node.id then
                            if dc.toPortIndex == removedIdx then
                                -- 移除该端口的连接
                                table.remove(editor.dataConnections, i)
                            elseif dc.toPortIndex > removedIdx then
                                -- 后续端口索引前移
                                dc.toPortIndex = dc.toPortIndex - 1
                                i = i + 1
                            else
                                i = i + 1
                            end
                        else
                            i = i + 1
                        end
                    end
                end
            end
        end, scale)
    end

    -- 检测鼠标悬停在输入数据点上，显示名称提示
    for i, posData in ipairs(node._inputDataPortPositions or {}) do
        if self:IsPointInCircle(mouseX, mouseY, posData.x, posData.y, posData.radius + 2 * scale) then
            local tipText = posData.data and (posData.data.name or posData.data.id) or "?"
            local tipFont = self:GetScaledFont("SourceHan_Heavy", 12, scale)
            surface.SetFont(tipFont)
            local textW = surface.GetTextSize(tipText)
            local tipPadding = 4 * scale
            local tipX = mouseX + 10 * scale
            local tipY = mouseY - 10 * scale - 16 * scale
            local tipW = textW + tipPadding * 2
            local tipH = 16 * scale + tipPadding * 2
            draw.RoundedBox(3, tipX, tipY, tipW, tipH, C(30, 30, 40, 230))
            draw.SimpleText(tipText, tipFont, tipX + tipPadding, tipY + tipH / 2, C(255, 255, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            break
        end
    end
end

--[[
    绘制单个节点，包括：节点主体、标题栏、输入/输出端口、自定义内容、
    无效/未注册高亮、选中状态高亮边框。
    使用pcall安全调用自定义绘制函数，避免错误导致整个编辑器崩溃。
    
    @param  editor  {table}     编辑器实例对象
    @param  node    {table}     要绘制的节点实例对象
]]
function INE:DrawNode(editor, node)
    if node.parsedConfig and node.parsedConfig.components then
        local calcW, calcH = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput, editor, node.id)
        node.width = calcW
        node.height = calcH
    end
    
    local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
    local nodeW = node.width * editor.canvasScale
    local nodeH = node.height * editor.canvasScale

    -- 检查节点是否被选中（框选/多选）
    local isSelected = false
    for _, selNode in ipairs(editor.selectedNodes) do
        if selNode == node then
            isSelected = true
            break
        end
    end

    -- 开始点绘制：文字分布在端口两侧（端口由 DrawNodePorts 在最后层绘制）
    -- 数据源开始点（钳击对象）的数据端口同样位于垂直居中，与普通开始点的端口位置一致
    if node.isStartNode then
        local title = node.data.title or node.name or T("editor.nodedraw.start_node")
        local startNodeFont = self:GetScaledFont("SourceHan_Heavy", 20, editor.canvasScale)
        local centerX = nodeX
        local centerY = nodeY + nodeH / 2

        -- 左侧显示第一个字符，右侧显示其余文字
        local firstChar = utf8.sub(title, 1, 1)
        local restChars = utf8.sub(title, 2)
        local gap = 8 * editor.canvasScale

        if firstChar ~= "" then
            draw.SimpleText(firstChar, startNodeFont, centerX - gap, centerY, C(200, 200, 200), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        end
        if restChars ~= "" then
            draw.SimpleText(restChars, startNodeFont, centerX + gap, centerY, C(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        return
    end

    -- 根据节点状态确定高亮边框颜色
    local highlightColor = nil
    if node.isInvalid then
        -- 无效节点（不属于当前面板）：红色高亮
        highlightColor = C(255, 80, 80, 150)
    elseif node.isUnregistered then
        -- 未注册节点类型：深红色高亮
        highlightColor = C(255, 100, 100, 100)
    end

    -- 绘制高亮边框（如有）
    if highlightColor then
        draw.RoundedBox(8 * editor.canvasScale, nodeX - 3, nodeY - 3, nodeW + 6, nodeH + 6, highlightColor)
    end

    -- 确定节点主体颜色，未注册节点使用暗红
    local nodeColor = node.color
    if node.isUnregistered then
        nodeColor = C(100, 50, 50)
    end

    -- 绘制节点主体（双层圆角矩形模拟边框效果）
    draw.RoundedBox(8 * editor.canvasScale, nodeX, nodeY, nodeW, nodeH, nodeColor)
    draw.RoundedBox(8 * editor.canvasScale, nodeX + 2 * editor.canvasScale, nodeY + 2 * editor.canvasScale, nodeW - 4 * editor.canvasScale, nodeH - 4 * editor.canvasScale, C(50, 50, 55))

    if not node.isUnregistered then
        -- 绘制标题栏
        draw.RoundedBox(4 * editor.canvasScale, nodeX, nodeY, nodeW, 24 * editor.canvasScale, C(70, 70, 75))
        -- 绘制节点标题（开始点使用 data.title，普通节点使用 displayName/name）
        local displayTitle = node.data.title or node.displayName or node.name
        local titleFont = self:GetScaledFont("SourceHan_Heavy", 14, editor.canvasScale)
        local typeFont = self:GetScaledFont("SourceHan_Heavy", 12, editor.canvasScale)
        draw.SimpleText(displayTitle, titleFont, nodeX + 10 * editor.canvasScale, nodeY + 12 * editor.canvasScale, C(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        -- 右侧绘制灰色小号 [type] 标签（如 NodeBase 风格）
        draw.SimpleText("[" .. node.type .. "]", typeFont, nodeX + nodeW - 10 * editor.canvasScale, nodeY + 12 * editor.canvasScale, C(180, 180, 180), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

        -- 输出端口和数据端口由 DrawNodePorts 在最后层绘制

        -- 绘制节点内容（优先 DSL 配置解析组件，其次自定义绘制函数）
        if node.parsedConfig and node.parsedConfig.components and #node.parsedConfig.components > 0 then
            self:DrawNodeContent(editor, node)
        elseif node.drawFunction then
            local success, err = pcall(node.drawFunction, node, nodeX + 10 * editor.canvasScale, nodeY + 30 * editor.canvasScale, nodeW - 20 * editor.canvasScale, nodeH - 40 * editor.canvasScale, editor.canvasScale)
            if not success then
                local errFont = self:GetScaledFont("SourceHan_Heavy", 12, editor.canvasScale)
                draw.SimpleText(T("editor.nodedraw.draw_error"), errFont, nodeX + nodeW/2, nodeY + nodeH/2, C(255, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end

        -- 输入/输出数据点由 DrawNodePorts 在最后层绘制
    else
        -- 未注册节点显示错误提示
        local unregFont1 = self:GetScaledFont("SourceHan_Heavy", 14, editor.canvasScale)
        local unregFont2 = self:GetScaledFont("SourceHan_Heavy", 12, editor.canvasScale)
        draw.SimpleText(T("editor.nodedraw.unregistered_node"), unregFont1, nodeX + nodeW/2, nodeY + nodeH/2, C(200, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(node.name or "unknown", unregFont2, nodeX + nodeW/2, nodeY + nodeH/2 + 20, C(150, 80, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- 绘制选中状态高亮（三层蓝色边框动画效果）
    if isSelected then
        surface.SetDrawColor(C(100, 150, 255, 200))
        for i = 0, 2 do
            surface.DrawOutlinedRect(nodeX - 2 - i, nodeY - 2 - i, nodeW + 4 + i*2, nodeH + 4 + i*2)
        end
    end
end

--[[
    仅绘制节点的端口元素（输入/输出圆形端口、数据端口）。
    在所有绘制完成后调用，确保端口始终在最上层，不被连接线遮挡。

    @param  editor  {table}     编辑器实例对象
    @param  node    {table}     节点实例
]]
function INE:DrawNodePorts(editor, node)
    local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
    local nodeW = node.width * editor.canvasScale
    local nodeH = node.height * editor.canvasScale

    -- 检查该节点的输出点是否被选中
    local isOutputSelected = false
    local selectedOutputPort = nil
    if editor.selectedOutputs then
        for _, output in ipairs(editor.selectedOutputs) do
            if output.node == node then
                isOutputSelected = true
                selectedOutputPort = output.port
                break
            end
        end
    end

    -- 开始点端口
    if node.isStartNode then
        if node.name ~= "data_start_point" then
            -- 输出端口（红色圆点），描边宽度随缩放变化
            local portR = 6 * editor.canvasScale
            local portCX = nodeX
            local portCY = nodeY + nodeH / 2
            local bw = math.max(1, math.Round(2 * editor.canvasScale))
            draw.RoundedBox(portR + bw, portCX - portR - bw, portCY - portR - bw, portR * 2 + bw * 2, portR * 2 + bw * 2, C(150, 50, 50))
            draw.RoundedBox(portR, portCX - portR, portCY - portR, portR * 2, portR * 2, C(255, 100, 100))

            -- 选中高亮（输出点被选中时）
            if isOutputSelected then
                surface.SetDrawColor(C(100, 255, 150, 200))
                for i = 0, 2 do
                    surface.DrawOutlinedRect(portCX - portR - 4 - i, portCY - portR - 4 - i, portR * 2 + 8 + i * 2, portR * 2 + 8 + i * 2)
                end
            end
        end

        -- 数据端口（底部）
        if node.availableOutputTypes and #node.availableOutputTypes > 0 then
            self:UpdateDataPortPositions(editor, node, "output")
            self:DrawDataPorts(editor, node)
        end
        return
    end

    -- 普通节点输入端口（蓝色圆形）
    if node.hasInput then
        local portR = 6 * editor.canvasScale
        local portX = nodeX - portR
        local portY = nodeY + nodeH / 2 - portR
        draw.RoundedBox(portR, portX, portY, portR * 2, portR * 2, C(100, 100, 255))
    end

    -- 普通节点输出端口（红色/绿色圆形）
    if node.hasOutput then
        if node.hasSecondOutput then
            local portR = 6 * editor.canvasScale
            local portX = nodeX + nodeW - portR
            local portTopY = nodeY + nodeH / 3 - portR
            local portBotY = nodeY + nodeH * 2 / 3 - portR
            local labelFont = self:GetScaledFont("SourceHan_Heavy", 11, editor.canvasScale)
            local labelGap = 4 * editor.canvasScale
            -- 端口标签（node.outputLabels 优先：如「抉择」的双效果端口为 {"效果一","效果二"}；
            -- 缺省保持 condition / loop / event_monitor 的「满足/不满足」语义）
            local labelTop = (node.outputLabels and node.outputLabels[1]) or T("editor.nodedraw.satisfied")
            local labelBot = (node.outputLabels and node.outputLabels[2]) or T("editor.nodedraw.not_satisfied")

            -- 满足分支（上）
            draw.RoundedBox(portR, portX, portTopY, portR * 2, portR * 2, C(100, 255, 100))
            draw.SimpleText(labelTop, labelFont, portX - labelGap, portTopY + portR, C(144, 238, 144), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
            -- 不满足分支（下）
            draw.RoundedBox(portR, portX, portBotY, portR * 2, portR * 2, C(255, 100, 100))
            draw.SimpleText(labelBot, labelFont, portX - labelGap, portBotY + portR, C(255, 180, 180), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

            -- 输出点选中高亮
            if isOutputSelected then
                surface.SetDrawColor(C(100, 255, 150, 200))
                for i = 0, 2 do
                    if not selectedOutputPort or selectedOutputPort == "satisfied" then
                        surface.DrawOutlinedRect(portX - 4 - i, portTopY - 4 - i, portR * 2 + 8 + i * 2, portR * 2 + 8 + i * 2)
                    end
                    if not selectedOutputPort or selectedOutputPort == "not_satisfied" then
                        surface.DrawOutlinedRect(portX - 4 - i, portBotY - 4 - i, portR * 2 + 8 + i * 2, portR * 2 + 8 + i * 2)
                    end
                end
            end
        else
            local portR = 6 * editor.canvasScale
            local portX = nodeX + nodeW - portR
            local portY = nodeY + nodeH / 2 - portR
            draw.RoundedBox(portR, portX, portY, portR * 2, portR * 2, C(255, 100, 100))

            -- 输出点选中高亮
            if isOutputSelected then
                surface.SetDrawColor(C(100, 255, 150, 200))
                for i = 0, 2 do
                    surface.DrawOutlinedRect(portX - 4 - i, portY - 4 - i, portR * 2 + 8 + i * 2, portR * 2 + 8 + i * 2)
                end
            end
        end
    end

    -- 输入数据点（顶边）
    -- 有可用类型（标准节点）或已有已选端口（如"判断变量关系"动态输入点）时均绘制
    if (node.availableInputTypes and #node.availableInputTypes > 0)
    or (node.selectedInputTypes and #node.selectedInputTypes > 0) then
        self:UpdateDataPortPositions(editor, node, "input")
        self:DrawInputDataPorts(editor, node)
    end

    -- 输出数据点（底边）
    -- 有可用类型（标准节点）或已有已选端口（如"新建变量"动态输出点）时均绘制
    if (node.availableOutputTypes and #node.availableOutputTypes > 0)
    or (node.selectedOutputTypes and #node.selectedOutputTypes > 0) then
        self:UpdateDataPortPositions(editor, node, "output")
        self:DrawDataPorts(editor, node)
    end
end

--[[
    使用三次贝塞尔曲线绘制两个节点之间的连接线。
    曲线从输出端口出发，经过两个控制点平滑地连接到输入端口。
    
    @param  editor    {table}   编辑器实例对象
    @param  fromNode  {table}   起始节点（输出端）
    @param  toNode    {table}   目标节点（输入端）
    @param  fromPort  {string}  输出端口标识（保留用于多端口支持）
]]
function INE:DrawConnection(editor, fromNode, toNode, fromPort)
    -- 计算起始节点输出端口屏幕坐标
    local fromPortX = fromNode.isStartNode and fromNode.x or (fromNode.x + fromNode.width)
    local fromWorldY = fromNode.y + fromNode.height / 2
    
    -- 双分支输出点：根据端口名确定 Y 位置
    if fromNode.hasSecondOutput then
        if fromPort == "satisfied" then
            fromWorldY = fromNode.y + fromNode.height / 3
        elseif fromPort == "not_satisfied" then
            fromWorldY = fromNode.y + fromNode.height * 2 / 3
        end
    end
    
    local fromX, fromY = self:WorldToScreen(editor, fromPortX, fromWorldY)
    local toX, toY = self:WorldToScreen(editor, toNode.x, toNode.y + toNode.height / 2)
    
    -- 计算贝塞尔曲线控制点（水平方向三分之一和三分之二处）
    -- 采样由共享几何模块统一提供，命中检测与绘制使用同一组点（ADR 0006）
    local points = KARDS.CardEditor.Geometry.BuildCurvePoints(fromX, fromY, toX, toY, "horizontal", 40)
    
    -- 使用 NodeBase 风格的粗曲线 + 节点类型颜色
    -- 连接线厚度随画布缩放变化，确保放大时加粗、缩小时变细，最小为1px
    local connThickness = math.max(1, 2 * editor.canvasScale)
    
    -- 判断连接线类型和颜色模式
    local NORMAL_BLUE = C(100, 200, 255)  -- 普通浅蓝色
    local RED = C(255, 60, 60)             -- 红色
    local GRADIENT_BLUE = C(80, 180, 255)  -- 渐变蓝端
    local GRADIENT_RED = C(255, 80, 80)    -- 渐变红端
    
    local isSourceSpecial = INE:IsSpecialTurnNode(fromNode)
    local isInRedChain = (not isSourceSpecial) and INE:IsInRedChain(editor, fromNode)
    
    if isSourceSpecial then
        -- 从特殊"回合"节点出发：蓝→红渐变
        local splitT = 0.4
        local gradientLen = 0.15
        local splitPoints = {}
        for _, p in ipairs(points) do
            table.insert(splitPoints, {x = p.x, y = p.y})
        end
        INE:DrawGradientCurve(splitPoints, GRADIENT_BLUE, GRADIENT_RED, connThickness, splitT, gradientLen)
        -- 标注文字：均匀逐个字符分布在线上，带阴影，适应缩放
        -- 蓝端（近source）始终显示蓝文字，红端（近target）始终显示红文字
        -- 当连接线从右向左时（输入点x<输出点x），字符反序以在屏幕上呈现正序
        local curveLen = INE:GetCurveLength(points)
        local textOffset = 8 * editor.canvasScale
        local fontSize = math.max(12, math.Round(16 * editor.canvasScale))
        local fontName = fontSize >= 14 and "SourceHan_Heavy_14" or "SourceHan_Heavy_12"
        local shadowColor = C(0, 0, 0, 180)
        local isReversed = toX < fromX
        if curveLen > 35 * editor.canvasScale then
            local ft1, ft2, et1, et2, friendText, enemyText
            if curveLen > 200 * editor.canvasScale then
                ft1, ft2, et1, et2 = 0.15, 0.38, 0.62, 0.85
                friendText = isReversed and T("editor.nodedraw.friendly_turn_reversed") or T("editor.nodedraw.friendly_turn")
                enemyText = isReversed and T("editor.nodedraw.enemy_turn_reversed") or T("editor.nodedraw.enemy_turn")
            elseif curveLen > 120 * editor.canvasScale then
                ft1, ft2, et1, et2 = 0.20, 0.38, 0.62, 0.80
                friendText = isReversed and T("editor.nodedraw.friendly_short_reversed") or T("editor.nodedraw.friendly_short")
                enemyText = isReversed and T("editor.nodedraw.enemy_short_reversed") or T("editor.nodedraw.enemy_short")
            else
                ft1, ft2, et1, et2 = 0.25, 0.38, 0.62, 0.75
                friendText, enemyText = T("editor.nodedraw.friendly_char"), T("editor.nodedraw.enemy_char")
            end
            INE:DrawCharsAlongCurve(points, friendText, ft1, ft2, fontName,
                C(100, 200, 255), shadowColor, -textOffset)
            INE:DrawCharsAlongCurve(points, enemyText, et1, et2, fontName,
                C(255, 100, 100), shadowColor, -textOffset)
        end
    elseif isInRedChain then
        -- 处于红色链中：全红
        INE:DrawThickCurve(points, RED, connThickness)
    else
        -- 普通连接：浅蓝色
        INE:DrawThickCurve(points, NORMAL_BLUE, connThickness)
    end
end

--[[
    判断节点是否为特殊"回合"节点（输出连接线需要渐变效果的回合节点）
    渐变条件（2026-08-14 用户规格，与 turn.json 模板结构对应）：
      - 等待分支 {友方、敌方、任意}'回合'{开始、结束}[]'次'：
          敌方回合开始（归属=敌方且时相=开始）
          友方回合结束（归属=友方且时相=结束）
          任意回合（归属=任意 且 次数为奇数）——仅"任意"需奇数
      - 使分支 {友方、敌方}{回合结束、跳过回合}：
          友方跳过回合、友方回合结束（归属=友方，动作任意）
    
    @param  node  {table}   节点实例
    @return {boolean} 是否为特殊回合节点
]]
function INE:IsSpecialTurnNode(node)
    if not node or node.type ~= "turn" then return false end
    local data = node.data
    if not data then return false end
    local parsedConfig = node.parsedConfig
    if not parsedConfig or not parsedConfig.components then return false end
    
    -- 动态查找组件ID，不依赖硬编码的序号
    -- 外层的第一个select组件即为{等待、使}
    local outerSelectId = nil
    local ifId = nil
    for _, comp in ipairs(parsedConfig.components) do
        if comp.type == "select" and not outerSelectId then
            outerSelectId = comp.id
        elseif comp.type == "if" then
            ifId = comp.id
        end
    end
    if not outerSelectId then return false end
    
    local select1 = data[outerSelectId]
    if not select1 then return false end
    
    local options1 = {"等待", "使"}
    local val1 = options1[select1]
    
    if val1 == "等待" then
        -- 动态查找"等待"分支内的 select（归属、时相）与 number（次数）组件ID
        local ownerSelectId, phaseSelectId, numId = nil, nil, nil
        if ifId and parsedConfig.components then
            for _, comp in ipairs(parsedConfig.components) do
                if comp.type == "if" and comp.branches then
                    for _, branch in ipairs(comp.branches) do
                        -- "等待"分支条件为"等待"
                        if branch.condition == "等待" and branch.components then
                            for _, bc in ipairs(branch.components) do
                                if bc.type == "select" then
                                    if not ownerSelectId then
                                        ownerSelectId = bc.id
                                    elseif not phaseSelectId then
                                        phaseSelectId = bc.id
                                    end
                                elseif bc.type == "number" then
                                    numId = bc.id
                                end
                            end
                        end
                    end
                end
            end
        end
        local ownerVal = data[ownerSelectId] or 1
        local phaseVal = data[phaseSelectId] or 1
        local numVal = data[numId or "number_1"] or 0
        local optionsOwner = {"友方", "敌方", "任意"}
        local optionsPhase = {"开始", "结束"}
        local owner = optionsOwner[ownerVal]
        local phase = optionsPhase[phaseVal]
        -- 敌方回合开始 / 友方回合结束：渐变（不要求次数）
        if owner == "敌方" and phase == "开始" then return true end
        if owner == "友方" and phase == "结束" then return true end
        -- 任意回合：仅次数为奇数时渐变
        if owner == "任意" and numVal % 2 == 1 then return true end
        return false
    elseif val1 == "使" then
        -- 动态查找"使"分支内的两个 select 组件ID：归属 {友方、敌方}、动作 {回合结束、跳过回合}
        local ownerSelectId, actSelectId = nil, nil
        if ifId and parsedConfig.components then
            for _, comp in ipairs(parsedConfig.components) do
                if comp.type == "if" and comp.branches then
                    for _, branch in ipairs(comp.branches) do
                        -- "使"对应条件为"使"
                        if branch.condition == "使" and branch.components then
                            for _, bc in ipairs(branch.components) do
                                if bc.type == "select" then
                                    if not ownerSelectId then
                                        ownerSelectId = bc.id
                                    elseif not actSelectId then
                                        actSelectId = bc.id
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        local ownerVal = data[ownerSelectId] or 1
        local optionsOwner = {"友方", "敌方"}
        local owner = optionsOwner[ownerVal]
        -- 友方跳过回合 / 友方回合结束：渐变（归属=友方，动作任意）
        return owner == "友方"
    end
    return false
end

--[[
    判断节点是否在"红色链"中（从特殊回合节点出发的可达节点）
    即：该节点的入度连接线中，存在从特殊回合节点出发的路径
    
    @param  editor  {table}   编辑器实例
    @param  node    {table}   要检查的节点
    @return {boolean} 是否在红色链中
]]
function INE:IsInRedChain(editor, node)
    if not editor or not node then return false end
    local visited = {}
    local function dfs(current)
        if visited[current.id] then return false end
        visited[current.id] = true
        -- 找到所有输入连接到 current 的节点
        for _, conn in ipairs(editor.connections) do
            if conn.toNode == current.id then
                local fromNode = INE:GetNodeByID(editor, conn.fromNode)
                if fromNode then
                    if INE:IsSpecialTurnNode(fromNode) then
                        return true
                    end
                    if dfs(fromNode) then
                        return true
                    end
                end
            end
        end
        return false
    end
    return dfs(node)
end

--[[
    计算曲线总长度
    
    @param  points  {table}   曲线点列表
    @return {number} 曲线长度（像素）
]]
function INE:GetCurveLength(points)
    local len = 0
    for i = 2, #points do
        local dx = points[i].x - points[i-1].x
        local dy = points[i].y - points[i-1].y
        len = len + math.sqrt(dx*dx + dy*dy)
    end
    return len
end

--[[
    绘制渐变曲线：沿曲线从 fromColor 渐变到 toColor。
    在 splitT 处有渐变过渡区，渐变区长度为 gradientLen。
    
    @param  points       {table}   曲线点列表 [{x, y}, ...]
    @param  fromColor    {Color}   起始颜色
    @param  toColor      {Color}   结束颜色
    @param  thickness    {number}  曲线粗细
    @param  splitT       {number}  渐变中心位置比例 (0~1)
    @param  gradientLen  {number}  渐变区长度比例 (0~1)
]]
function INE:DrawGradientCurve(points, fromColor, toColor, thickness, splitT, gradientLen)
    if #points < 2 then return end
    thickness = thickness or 2
    splitT = splitT or 0.5
    gradientLen = gradientLen or 0.15
    
    local fromR, fromG, fromB = fromColor.r, fromColor.g, fromColor.b
    local toR, toG, toB = toColor.r, toColor.g, toColor.b
    
    local gradStart = math.max(0, splitT - gradientLen / 2)
    local gradEnd = math.min(1, splitT + gradientLen / 2)
    
    for i = 1, #points - 1 do
        local t = (i - 1) / (#points - 1)
        local r, g, b
        if t <= gradStart then
            r, g, b = fromR, fromG, fromB
        elseif t >= gradEnd then
            r, g, b = toR, toG, toB
        else
            local lt = (t - gradStart) / (gradEnd - gradStart)
            r = fromR + (toR - fromR) * lt
            g = fromG + (toG - fromG) * lt
            b = fromB + (toB - fromB) * lt
        end
        
        local dx = points[i+1].x - points[i].x
        local dy = points[i+1].y - points[i].y
        local segLen = math.sqrt(dx*dx + dy*dy)
        if segLen > 0 then
            local nx = -dy / segLen
            local ny = dx / segLen
            for offset = -thickness, thickness do
                local x1 = points[i].x + nx * offset
                local y1 = points[i].y + ny * offset
                local x2 = points[i+1].x + nx * offset
                local y2 = points[i+1].y + ny * offset
                surface.SetDrawColor(r, g, b, 255)
                surface.DrawLine(x1, y1, x2, y2)
            end
        end
    end
end

--[[
    沿曲线逐个字符渲染文字，字符均匀分布，带阴影。
    每个字符独立绘制并放置在曲线的对应位置上。
    
    @param  points     {table}   曲线点列表 [{x, y}, ...]
    @param  text       {string}  要渲染的文字
    @param  tStart     {number}  文字起始位置比例 (0~1)
    @param  tEnd       {number}  文字结束位置比例 (0~1)
    @param  font       {string}  字体名称
    @param  color      {Color}   文字颜色
    @param  shadowColor {Color}  阴影颜色
    @param  yOffset    {number}  Y 轴偏移（线上方为正）
]]
function INE:DrawCharsAlongCurve(points, text, tStart, tEnd, font, color, shadowColor, yOffset)
    local numChars = utf8 and utf8.len(text) or #text
    if numChars == 0 or #points < 2 then return end
    
    local range = tEnd - tStart
    
    for i = 1, numChars do
        local t = tStart + range * (i - 0.5) / numChars
        local idx = math.max(1, math.min(#points, math.floor(t * (#points - 1)) + 1))
        local px = points[idx].x
        local py = points[idx].y
        
        local char = utf8 and utf8.sub(text, i, i) or string.sub(text, i, i)
        
        -- 阴影（右下偏移 1px）
        draw.SimpleText(char, font, px + 1, py + 1 + yOffset, shadowColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        -- 主文字
        draw.SimpleText(char, font, px, py + yOffset, color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

--[[
    绘制粗曲线（与 NodeBase 风格一致）。
    通过沿法线方向偏移生成多条平行线，模拟带厚度的曲线。
    
    @param  points    {table}   曲线点列表 [{x, y}, ...]
    @param  color     {Color}   曲线颜色
    @param  thickness {number}  曲线粗细（像素）
]]
function INE:DrawThickCurve(points, color, thickness)
    thickness = thickness or 2
    local normals = INE:GetCurveNormals(points, thickness)
    
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

--[[
    计算曲线每个点的法线方向，用于 DrawThickCurve 沿法线偏移生成厚度。
    
    @param  points    {table}   曲线点列表 [{x, y}, ...]
    @param  thickness {number}  曲线粗细
    
    @return {table} 法线方向列表 [{x, y}, ...]
]]
function INE:GetCurveNormals(points, thickness)
    local normals = {}
    for i = 1, #points do
        local prev = points[math.max(i - 1, 1)]
        local next = points[math.min(i + 1, #points)]
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

--[[
    绘制临时连接线（拖拽连线时从节点输出端口到鼠标位置的预览线）。
    使用半透明颜色，与正式连接线区分。
    
    @param  editor  {table}   编辑器实例对象
    @param  node    {table}   起始节点
    @param  port    {string}  输出端口标识
]]
function INE:DrawTempConnection(editor, node, port, hovering)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    -- 起始端口位置：开始节点在 x=0，普通节点在右边缘
    local portX = node.isStartNode and node.x or (node.x + node.width)
    local fromWorldY = node.y + node.height / 2
    
    -- 双分支输出点：根据端口名确定 Y 位置
    if node.hasSecondOutput then
        if port == "satisfied" then
            fromWorldY = node.y + node.height / 3
        elseif port == "not_satisfied" then
            fromWorldY = node.y + node.height * 2 / 3
        end
    end
    
    local fromX, fromY = self:WorldToScreen(editor, portX, fromWorldY)
    
    -- 贝塞尔曲线终点为鼠标当前位置，采样由共享几何模块统一提供（ADR 0006）
    local points = KARDS.CardEditor.Geometry.BuildCurvePoints(fromX, fromY, mouseX, mouseY, "horizontal", 40)
    
    local isSourceSpecial = INE:IsSpecialTurnNode(node)
    local isSourceRed = (not isSourceSpecial) and INE:IsInRedChain(editor, node)
    local connThickness = math.max(1, 2 * editor.canvasScale)
    
    if isSourceSpecial then
        -- 从特殊"回合"节点拖出：蓝→红渐变（半透明）
        local alpha = hovering and 200 or 80
        local fromColor = C(80, 180, 255, alpha)
        local toColor = C(255, 80, 80, alpha)
        local splitT = 0.4
        local gradientLen = 0.15
        INE:DrawGradientCurve(points, fromColor, toColor, hovering and 4 or 3, splitT, gradientLen)
    elseif isSourceRed then
        -- 从红色链中的节点拖出：全红（半透明）
        local alpha = hovering and 200 or 80
        local thickness = hovering and 4 or 3
        INE:DrawThickCurve(points, C(255, 60, 60, alpha), thickness)
    else
        -- 半透明浅蓝色连线：接近输入点时更亮更不透明，远离时更暗更透明
        local alpha = hovering and 200 or 80
        local r, g, b = 100, 200, 255  -- 浅蓝色（普通输入/输出点连接）
        
        -- 使用粗曲线绘制临时连接线（厚度3px，接近输入点时厚度5px）
        local thickness = hovering and 4 or 3
        INE:DrawThickCurve(points, C(r, g, b, alpha), thickness)
    end
end

--[[
    绘制数据连接线（黄色）。
    连接两个节点的数据点，从输出数据点到底边，到输入数据点到顶边。
    
    @param  editor         {table}   编辑器实例对象
    @param  fromNode       {table}   起始节点（输出数据点所在节点）
    @param  toNode         {table}   目标节点（输入数据点所在节点）
    @param  fromPortIndex  {number}  输出数据点索引
    @param  toPortIndex    {number}  输入数据点索引
]]
function INE:DrawDataConnection(editor, fromNode, toNode, fromPortIndex, toPortIndex)
    -- 获取输出数据点位置
    local fromPortPos = fromNode._outputDataPortPositions and fromNode._outputDataPortPositions[fromPortIndex]
    local toPortPos = toNode._inputDataPortPositions and toNode._inputDataPortPositions[toPortIndex]
    
    if not fromPortPos or not toPortPos then return end
    
    local fromX, fromY = fromPortPos.x, fromPortPos.y
    local toX, toY = toPortPos.x, toPortPos.y
    
    -- 计算贝塞尔曲线控制点（垂直方向偏移，额外偏移使曲线更突出）
    -- 采样由共享几何模块统一提供（ADR 0006）
    local points = KARDS.CardEditor.Geometry.BuildCurvePoints(fromX, fromY, toX, toY, "vertical", 20)
    
    -- 使用黄色绘制数据连接线（厚度随画布缩放自适应）
    INE:DrawThickCurve(points, C(255, 200, 0), math.max(1, 2 * editor.canvasScale))
end

--[[
    绘制临时数据连接线（拖拽数据点时的预览线）。
    从拖拽的数据点到鼠标位置的黄色半透明曲线。
    
    @param  editor     {table}   编辑器实例对象
    @param  fromPort   {table}   拖拽的数据点信息 {node, portData, portType, portIndex}
    @param  hoverPort  {table|nil} 悬停的目标数据点信息（用于高亮提示）
]]
function INE:DrawTempDataConnection(editor, fromPort, hoverPort)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    -- 获取起始数据点位置
    local fromPortPos
    if fromPort.portType == "output" then
        fromPortPos = fromPort.node._outputDataPortPositions and fromPort.node._outputDataPortPositions[fromPort.portIndex]
    else
        fromPortPos = fromPort.node._inputDataPortPositions and fromPort.node._inputDataPortPositions[fromPort.portIndex]
    end
    
    if not fromPortPos then return end
    
    local fromX, fromY = fromPortPos.x, fromPortPos.y
    
    -- 如果有悬停的目标数据点，连接到该数据点；否则连接到鼠标位置
    local toX, toY = mouseX, mouseY
    if hoverPort then
        local hoverPortPos
        if hoverPort.portType == "input" then
            hoverPortPos = hoverPort.node._inputDataPortPositions and hoverPort.node._inputDataPortPositions[hoverPort.portIndex]
        else
            hoverPortPos = hoverPort.node._outputDataPortPositions and hoverPort.node._outputDataPortPositions[hoverPort.portIndex]
        end
        if hoverPortPos then
            toX, toY = hoverPortPos.x, hoverPortPos.y
        end
    end
    
    -- 计算贝塞尔曲线控制点（垂直方向偏移，额外偏移使曲线更突出）
    -- 采样由共享几何模块统一提供（ADR 0006）
    local points = KARDS.CardEditor.Geometry.BuildCurvePoints(fromX, fromY, toX, toY, "vertical", 20)
    
    -- 半透明黄色连线：接近目标数据点时更亮更不透明，厚度随画布缩放自适应
    local hovering = hoverPort ~= nil
    local alpha = hovering and 200 or 80
    local baseThickness = hovering and 4 or 3
    local thickness = math.max(1, baseThickness * editor.canvasScale)
    
    INE:DrawThickCurve(points, C(255, 200, 0, alpha), thickness)
end

--[[
    绘制选中输出点的反馈：从输出端口到鼠标的贝塞尔曲线。
    当有输出点被选中时，实时绘制连接线提示用户即将建立连接。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:DrawSelectedOutputFeedback(editor)
    if not editor.selectedOutputs or #editor.selectedOutputs == 0 then return end
    
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    -- 为每个选中的输出点绘制反馈线
    for _, output in ipairs(editor.selectedOutputs) do
        local node = output.node
        local port = output.port or "output"
        
        -- 计算输出端口的屏幕坐标
        local portR = 6 * editor.canvasScale
        local fromWorldY = node.y + node.height / 2
        
        -- 双分支输出点：根据端口名确定 Y 位置
        if node.hasSecondOutput then
            if port == "satisfied" then
                fromWorldY = node.y + node.height / 3
            elseif port == "not_satisfied" then
                fromWorldY = node.y + node.height * 2 / 3
            end
        end
        
        local fromX, fromY = self:WorldToScreen(editor, node.x + node.width, fromWorldY)
        
        -- 贝塞尔曲线终点为鼠标当前位置，采样由共享几何模块统一提供（ADR 0006）
        local points = KARDS.CardEditor.Geometry.BuildCurvePoints(fromX, fromY, mouseX, mouseY, "horizontal", 20)
        
        -- 半透明绿色绘制反馈线（区分于旧的蓝色临时连线）
        surface.SetDrawColor(C(100, 255, 150, 150))
        for i = 1, #points - 1 do
            surface.DrawLine(points[i].x, points[i].y, points[i + 1].x, points[i + 1].y)
        end
    end
end

--[[
    绘制从节点选择面板拖拽出的临时节点预览（半透明）。
    在鼠标位置跟随显示，松开鼠标后在画布上创建正式节点。
    
    @param  editor    {table}   编辑器实例对象
    @param  nodeName  {string}  节点类型名称
    @param  x         {number}  预览位置X（屏幕坐标）
    @param  y         {number}  预览位置Y（屏幕坐标）
]]
function INE:DrawTempNodePreview(editor, nodeName, x, y)
    local template = INE.RegisteredNodes[nodeName]
    if not template then return end
    
    -- 设置半透明绘制节点预览
    surface.SetAlphaMultiplier(0.7)
    local w = template.width * editor.canvasScale
    local h = template.height * editor.canvasScale
    
    draw.RoundedBox(8 * editor.canvasScale, x, y, w, h, template.color)
    draw.RoundedBox(8 * editor.canvasScale, x + 2, y + 2, w - 4, h - 4, C(50, 50, 55))
    draw.RoundedBox(4 * editor.canvasScale, x, y, w, 24 * editor.canvasScale, C(70, 70, 75))
    local previewFont = editor and INE:GetScaledFont("SourceHan_Heavy", 14, editor.canvasScale) or "SourceHan_Heavy_14"
    draw.SimpleText(template.name, previewFont, x + 10 * editor.canvasScale, y + 12 * editor.canvasScale, C(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    surface.SetAlphaMultiplier(1)
end

--[[
    绘制导入警告对话框。
    当导入数据包含未注册节点或不属于当前面板的节点时显示，
    提示用户选择"仍然导入"或"取消导入"。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:DrawImportWarningDialog(editor)
    local warnings = editor.importWarnings
    local dlgW, dlgH = 450, 200
    local dlgX = editor.x + editor.width/2 - dlgW/2
    local dlgY = editor.y + editor.height/2 - dlgH/2
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    draw.RoundedBox(8, dlgX, dlgY, dlgW, dlgH, C(50, 50, 55))
    draw.RoundedBox(8, dlgX + 2, dlgY + 2, dlgW - 4, dlgH - 4, C(60, 60, 65))
    draw.RoundedBox(4, dlgX, dlgY, dlgW, 40, C(80, 60, 60))
    
    local titleText = warnings.hasUnregistered and T("editor.nodedraw.import_invalid_title") or T("editor.nodedraw.import_wrong_purpose_title")
    draw.SimpleText(titleText, "SourceHan_Heavy_18", dlgX + dlgW/2, dlgY + 20, C(255, 200, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    local msgText = warnings.hasUnregistered and T("editor.nodedraw.import_unregistered_message") or
                    T("editor.nodedraw.import_foreign_message")
    draw.SimpleText(msgText, "SourceHan_Heavy_14", dlgX + dlgW/2, dlgY + 70, C(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    if warnings.hasUnregistered then
        draw.SimpleText(T("editor.nodedraw.import_unregistered_hint"), "SourceHan_Heavy_12", dlgX + dlgW/2, dlgY + 100, C(180, 150, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(T("editor.nodedraw.import_unreferenced_hint"), "SourceHan_Heavy_12", dlgX + dlgW/2, dlgY + 100, C(180, 150, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    
    local btnW, btnH = 120, 35
    local continueBtnX = dlgX + dlgW/2 - btnW - 20
    local cancelBtnX = dlgX + dlgW/2 + 20
    local btnY = dlgY + dlgH - 50
    
    local continueHovered = mouseX >= continueBtnX and mouseX <= continueBtnX + btnW and
                           mouseY >= btnY and mouseY <= btnY + btnH
    draw.RoundedBox(4, continueBtnX, btnY, btnW, btnH, continueHovered and C(80, 150, 80) or C(60, 120, 60))
    draw.SimpleText(T("editor.nodedraw.import_anyway"), "SourceHan_Heavy_14", continueBtnX + btnW/2, btnY + btnH/2, C(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    local cancelHovered = mouseX >= cancelBtnX and mouseX <= cancelBtnX + btnW and
                         mouseY >= btnY and mouseY <= btnY + btnH
    draw.RoundedBox(4, cancelBtnX, btnY, btnW, btnH, cancelHovered and C(150, 80, 80) or C(120, 60, 60))
    draw.SimpleText(T("editor.nodedraw.cancel_import"), "SourceHan_Heavy_14", cancelBtnX + btnW/2, btnY + btnH/2, C(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    editor._importDialogButtons = {
        ["continue"] = {x = continueBtnX, y = btnY, w = btnW, h = btnH},
        cancel = {x = cancelBtnX, y = btnY, w = btnW, h = btnH}
    }
end
