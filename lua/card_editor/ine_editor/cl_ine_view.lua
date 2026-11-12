--[[
=======================================================================================
编辑器子系统：cl_ine_view.lua
=======================================================================================
从 cl_ine_node_editor.lua 拆分出的子系统：画布坐标变换、视图缩放与居中、通知与悬停提示、查找窗口、画布裁剪、浮层窗口、导入警告对话框。
源行范围：cl_ine_node_editor.lua 第 2950 至 3881 行（2026-10-18 拆分时点）。
=======================================================================================
]]

local INE = KARDS.CardEditor.IndependentNodeEditor
local T = KARDS.Lang.T

--[[
    统一计算画布区域，返回画布在屏幕上的位置和尺寸。
    
    @param  editor  {table}     编辑器实例对象
    
    @return {table} 画布区域 {x, y, w, h}
]]
function INE:GetCanvasRect(editor)
    -- 计算体已迁至共享几何模块（ADR 0006），此处保留签名供既有调用方使用
    return KARDS.CardEditor.Geometry.GetCanvasRect(editor)
end

--[[
    将画布世界坐标转换为屏幕坐标。
    
    @param  editor  {table}     编辑器实例对象
    @param  worldX  {number}    画布世界X坐标
    @param  worldY  {number}    画布世界Y坐标
    
    @return {number, number} 屏幕X, Y坐标
]]
function INE:WorldToScreen(editor, worldX, worldY)
    -- 四舍五入到整数坐标以避免缩放/平移后小数坐标导致鼠标命中检测失败
    -- gui.MouseX()/MouseY() 返回整数，若坐标含小数则 100 >= 100.3 为 false
    -- 计算体已迁至共享几何模块（ADR 0006），此处保留签名供既有调用方使用
    return KARDS.CardEditor.Geometry.WorldToScreen(editor, worldX, worldY)
end

--[[
    将屏幕坐标转换为画布世界坐标。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {number, number} 画布世界X, Y坐标
]]
function INE:ScreenToWorld(editor, screenX, screenY)
    -- 计算体已迁至共享几何模块（ADR 0006），此处保留签名供既有调用方使用
    return KARDS.CardEditor.Geometry.ScreenToWorld(editor, screenX, screenY)
end

--[[
    检测节点是否在画布视口内（部分可见也算可见）。
    
    @param  editor  {table}   编辑器实例对象
    @param  node    {table}   节点实例对象
    
    @return {boolean} 节点可见返回true，完全在视口外返回false
]]
function INE:IsNodeVisible(editor, node)
    local rect = self:GetCanvasRect(editor)
    local nodeScreenX, nodeScreenY = self:WorldToScreen(editor, node.x, node.y)
    local nodeScreenW = node.width * editor.canvasScale
    local nodeScreenH = node.height * editor.canvasScale
    
    if nodeScreenX + nodeScreenW < rect.x then return false end
    if nodeScreenX > rect.x + rect.w then return false end
    if nodeScreenY + nodeScreenH < rect.y then return false end
    if nodeScreenY > rect.y + rect.h then return false end
    
    return true
end

--[[
    检测连接线是否可见（连接的两个节点至少有一个部分可见，或线段端点在画布扩展范围内）。
    
    @param  editor    {table}   编辑器实例对象
    @param  fromNode  {table}   起始节点
    @param  toNode    {table}   目标节点
    
    @return {boolean} 连接线可见返回true，否则返回false
]]
function INE:IsConnectionVisible(editor, fromNode, toNode)
    if self:IsNodeVisible(editor, fromNode) or self:IsNodeVisible(editor, toNode) then
        return true
    end
    local fromScreenX, fromScreenY = self:WorldToScreen(editor, fromNode.x + fromNode.width, fromNode.y + fromNode.height / 2)
    local toScreenX, toScreenY = self:WorldToScreen(editor, toNode.x, toNode.y + toNode.height / 2)
    local rect = self:GetCanvasRect(editor)
    local margin = 100
    local minX = math.min(fromScreenX, toScreenX) - margin
    local maxX = math.max(fromScreenX, toScreenX) + margin
    local minY = math.min(fromScreenY, toScreenY) - margin
    local maxY = math.max(fromScreenY, toScreenY) + margin
    return maxX >= rect.x and minX <= rect.x + rect.w and maxY >= rect.y and minY <= rect.y + rect.h
end

--[[
    将视图居中到指定世界坐标点
    
    @param  editor  {table}   编辑器实例对象
    @param  worldX  {number}  世界X坐标
    @param  worldY  {number}  世界Y坐标
]]
function INE:CenterViewOn(editor, worldX, worldY)
    local rect = self:GetCanvasRect(editor)
    editor.canvasOffsetX = rect.w / (2 * editor.canvasScale) - worldX
    editor.canvasOffsetY = rect.h / (2 * editor.canvasScale) - worldY
end

--[[
    返回原点：将世界坐标原点居中显示在画布面板中央
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:ResetView(editor)
    local rect = self:GetCanvasRect(editor)
    editor.canvasOffsetX = rect.w / 2
    editor.canvasOffsetY = rect.h / 2
    editor.canvasScale = 1
end

--[[
    适配所有节点：调整视图以显示所有节点。
    计算所有节点的包围盒，将视图居中并缩放至合适比例。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:FitAllNodes(editor)
    if #editor.nodes == 0 then
        INE:ResetView(editor)
        return
    end
    
    local minX, minY, maxX, maxY = nil, nil, nil, nil
    for _, node in ipairs(editor.nodes) do
        local nx1, ny1 = node.x, node.y
        local nx2, ny2 = node.x + node.width, node.y + node.height
        minX = (minX == nil) and nx1 or math.min(minX, nx1)
        minY = (minY == nil) and ny1 or math.min(minY, ny1)
        maxX = (maxX == nil) and nx2 or math.max(maxX, nx2)
        maxY = (maxY == nil) and ny2 or math.max(maxY, ny2)
    end
    
    local rect = self:GetCanvasRect(editor)
    local contentW = rect.w - 40
    local contentH = rect.h - 40
    local bboxW = maxX - minX
    local bboxH = maxY - minY
    
    local scaleX = contentW / math.max(bboxW, 100)
    local scaleY = contentH / math.max(bboxH, 100)
    local scale = math.min(scaleX, scaleY, 1.0)
    editor.canvasScale = math.Clamp(scale, INE.ZOOM_MIN, INE.ZOOM_MAX)
    
    local centerX = (minX + maxX) / 2
    local centerY = (minY + maxY) / 2
    editor.canvasOffsetX = rect.w / (2 * editor.canvasScale) - centerX
    editor.canvasOffsetY = rect.h / (2 * editor.canvasScale) - centerY
end

--[[
    缩放视图
    
    @param  editor  {table}   编辑器实例对象
    @param  factor  {number}  缩放因子（>1放大，<1缩小）
]]
function INE:ZoomView(editor, factor)
    local oldScale = editor.canvasScale
    
    -- 沿鼠标缩放：先记录鼠标下方的世界坐标（使用旧缩放值计算）
    local worldX, worldY
    if editor._viewZoomFollowMouse then
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        local rect = self:GetCanvasRect(editor)
        if mouseX >= rect.x and mouseX <= rect.x + rect.w and mouseY >= rect.y and mouseY <= rect.y + rect.h then
            -- 使用旧缩放计算世界坐标
            worldX = (mouseX - rect.x) / oldScale - editor.canvasOffsetX
            worldY = (mouseY - rect.y) / oldScale - editor.canvasOffsetY
        end
    end
    
    editor.canvasScale = math.Clamp(editor.canvasScale * factor, INE.ZOOM_MIN, INE.ZOOM_MAX)
    
    -- 缩放时关闭展开的下拉框、变量弹窗和对象选择器
    -- 浮层状态都在编辑器会话里（ADR 0003），随缩放一并关闭
    if editor.session then
        editor.session.ExpandedDropdown = nil
        editor.session.ExpandedDropdownInfo = nil
        editor.session.NumericVarPopup = nil
        editor.session.CardObjectSelector = nil
        editor.session.FuncVarPopup = nil
        editor.session.GlobalVarSelector = nil
        editor.session.KeywordMultiSelect = nil
        editor.session.ExpandedMultiDropdown = nil
        editor.session.ExpandedMultiDropdownInfo = nil
    end
    
    -- 沿鼠标缩放：调整偏移使世界坐标点保持在鼠标下
    if editor._viewZoomFollowMouse and worldX then
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        local rect = self:GetCanvasRect(editor)
        local newScreenX = rect.x + (worldX + editor.canvasOffsetX) * editor.canvasScale
        local newScreenY = rect.y + (worldY + editor.canvasOffsetY) * editor.canvasScale
        editor.canvasOffsetX = editor.canvasOffsetX + (mouseX - newScreenX) / editor.canvasScale
        editor.canvasOffsetY = editor.canvasOffsetY + (mouseY - newScreenY) / editor.canvasScale
    end
end

--[[
    定位到极端节点
    
    @param  editor     {table}   编辑器实例对象
    @param  direction  {string}  方向："left"/"right"/"top"/"bottom"
]]
function INE:FocusExtremeNode(editor, direction)
    if #editor.nodes == 0 then return end
    local targetNode = editor.nodes[1]
    for _, node in ipairs(editor.nodes) do
        if direction == "left" and node.x < targetNode.x then
            targetNode = node
        elseif direction == "right" and node.x + node.width > targetNode.x + targetNode.width then
            targetNode = node
        elseif direction == "top" and node.y < targetNode.y then
            targetNode = node
        elseif direction == "bottom" and node.y + node.height > targetNode.y + targetNode.height then
            targetNode = node
        end
    end
    self:CenterViewOn(editor, targetNode.x + targetNode.width/2, targetNode.y + targetNode.height/2)
end

--[[
=======================================================================================
INE 通知与悬停提示系统
=======================================================================================
独立的通知系统，用于替代旧的 NodeBase / Canvas 提示系统，确保提示显示在最顶层。
支持弹出通知（自动淡出）和鼠标跟随的悬停提示。
=======================================================================================
]]

--[[
    向指定编辑器添加一条弹出通知。
    
    @param  editor   {table}    编辑器实例对象
    @param  text     {string}   通知文本
    @param  color    {Color}    通知颜色（用于左侧色条和文字）
    @param  duration {number}   显示时长（秒），默认 3 秒
]]
-- 通知系统配置（每个编辑器面板独立使用）
INE.NotificationConfig = {
    animationDuration = 0.4,       -- 滑入/滑出动画持续时间（秒）
    displayDuration = 2.0,         -- 显示持续时间（秒）
    minWidth = 150,                -- 最小宽度
    maxWidth = 320,                -- 最大宽度
    padding = 12,                  -- 内边距
    titleHeight = 20,              -- 标题框高度
    rowSpacing = 8,                -- 通知间距
    cornerRadius = 6,              -- 圆角半径
    titleColor = Color(60, 60, 65), -- 标题框颜色
    textColor = Color(230, 230, 230),  -- 文本颜色
    flashDuration = 0.4,           -- 闪烁持续时间
    flashCount = 3,                -- 闪烁次数
    fontSize = "SourceHan_Heavy_14" -- 字体
}

--[[
    缓动函数：Back Out（带回弹效果）。
    用于通知滑入/滑出动画，形成自然的弹性效果。
]]
function INE:EaseOutBack(t, b, c, d, s)
    s = s or 1.70158
    local t2 = t / d - 1
    return c * (t2 * t2 * ((s + 1) * t2 + s) + 1) + b
end

--[[
    向指定编辑器添加通知。
    具备以下特性：
    - 声音反馈（成功/失败音频）
    - 重复文本自动合并并计数
    - 自动执行三阶段动画（进入→显示→退出）
    - 宽度根据文本内容自适应
    
    @param  editor   {table}    编辑器实例对象
    @param  text     {string}   通知文本
    @param  color    {Color}    通知颜色（用于标题框和背景）
    @param  duration {number}   显示时长（秒），默认 3 秒
    @param  isSuccess {boolean} 是否为成功通知（播放成功音效），默认 false
]]
function INE:AddNotification(editor, text, color, duration, isSuccess)
    if not editor or not text then return end
    editor.notifications = editor.notifications or {}
    color = color or Color(200, 200, 200)
    duration = duration or 3
    local config = INE.NotificationConfig
    local currentTime = SysTime()

    -- 播放音效
    if isSuccess then
        if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayNotificationSuccess then
            KARDS.CardEditor.Audio.PlayNotificationSuccess()
        end
    else
        if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayNotification then
            KARDS.CardEditor.Audio.PlayNotification()
        end
    end

    -- 检查是否有重复的通知（2秒内的相同文本自动合并）
    for _, notif in ipairs(editor.notifications) do
        if notif.text == text and currentTime - notif.createdTime < 2 then
            notif.count = (notif.count or 1) + 1
            notif.createdTime = currentTime
            notif.animationTime = 0
            notif.state = "entering"
            notif.flashTime = 0
            notif.flashCount = 0
            return
        end
    end

    -- 计算通知框尺寸
    surface.SetFont(config.fontSize)
    local textWidth, textHeight = surface.GetTextSize(text)
    local notifWidth = math.Clamp(textWidth + config.padding * 2, config.minWidth, config.maxWidth)
    local notifHeight = textHeight + config.padding * 2 + config.titleHeight

    -- 创建新通知
    local notif = {
        text = text,
        color = color,
        count = 1,
        createdTime = currentTime,
        animationTime = 0,
        state = "entering",
        position = 0,
        flashTime = 0,
        flashCount = 0,
        width = notifWidth,
        height = notifHeight
    }
    table.insert(editor.notifications, notif)

    -- 限制通知数量，避免过多堆积
    while #editor.notifications > 5 do
        table.remove(editor.notifications, 1)
    end
end

--[[
    更新指定编辑器的通知状态。
    管理三阶段动画（进入→显示→退出）的生命周期，
    以及闪烁效果和过期清除。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:UpdateNotifications(editor)
    if not editor.notifications or #editor.notifications == 0 then return end
    local config = INE.NotificationConfig
    local notifications = editor.notifications

    -- 过滤过期的通知
    local valid = {}
    for _, notif in ipairs(notifications) do
        notif.animationTime = (notif.animationTime or 0) + FrameTime()

        local shouldSkip = false
        if notif.state == "entering" then
            if notif.animationTime >= config.animationDuration then
                notif.state = "active"
                notif.animationTime = 0
            end
        elseif notif.state == "active" then
            if notif.animationTime >= config.displayDuration then
                notif.state = "exiting"
                notif.animationTime = 0
            end
        elseif notif.state == "exiting" then
            if notif.animationTime >= config.animationDuration then
                shouldSkip = true
            end
        end

        if not shouldSkip then
            -- 更新闪烁状态
            if notif.count > 1 then
                notif.flashTime = (notif.flashTime or 0) + FrameTime()
            end
            table.insert(valid, notif)
        end
    end

    -- 按创建时间排序，新通知在上
    table.sort(valid, function(a, b)
        return a.createdTime > b.createdTime
    end)

    -- 更新位置索引
    for i, notif in ipairs(valid) do
        notif.position = i - 1
    end

    editor.notifications = valid
end

--[[
    绘制指定编辑器的通知列表。
    通知显示在编辑器面板的右上角，相对于面板边缘定位。
    支持滑入/滑出动画、计数徽标、闪烁效果。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:DrawNotifications(editor)
    if not editor.notifications or #editor.notifications == 0 then return end
    local config = INE.NotificationConfig
    local notifications = editor.notifications

    for _, notif in ipairs(notifications) do
        local totalWidth = notif.width
        local totalHeight = notif.height
        
        -- 垂直位置：相对于编辑器面板顶部，每行依次向下排列
        local y = editor.y + (editor.borderless and 10 or 45) + notif.position * (totalHeight + config.rowSpacing)

        -- 计算水平滑入/滑出动画偏移
        local xOffset = 0
        if notif.state == "entering" then
            local progress = math.min(notif.animationTime / config.animationDuration, 1)
            xOffset = INE:EaseOutBack(progress, totalWidth, -totalWidth * 2, 1)
        elseif notif.state == "active" then
            xOffset = -totalWidth
        elseif notif.state == "exiting" then
            local progress = math.min(notif.animationTime / config.animationDuration, 1)
            xOffset = INE:EaseOutBack(progress, -totalWidth, totalWidth * 2, 1)
        end

        -- x 是通知框的左边缘位置（从右侧滑入）
        local x = editor.x + editor.width + xOffset

        -- 绘制背景圆角框
        draw.RoundedBox(config.cornerRadius, x, y, totalWidth, totalHeight, notif.color)

        -- 绘制标题框
        draw.RoundedBoxEx(config.cornerRadius, x, y, totalWidth, config.titleHeight, config.titleColor, true, true, false, false)

        -- 绘制标题文本（先画一层暗色偏移阴影，再画正文）
        local titleText = T("editor.nodeeditor.notification_title")
        draw.SimpleText(titleText, config.fontSize, x + config.padding + 1, y + config.titleHeight / 2 + 1, Color(0, 0, 0, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText(titleText, config.fontSize, x + config.padding, y + config.titleHeight / 2, config.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 绘制计数徽标在标题框中
        if notif.count > 1 then
            local countText = "×" .. notif.count
            surface.SetFont(config.fontSize)
            local countWidth, countHeight = surface.GetTextSize(countText)
            local countX = x + totalWidth - config.padding - countWidth

            draw.RoundedBox(4, countX - 4, y + config.titleHeight / 2 - countHeight / 2 - 2, countWidth + 8, countHeight + 4, Color(0, 0, 0, 150))
            draw.SimpleText(countText, config.fontSize, countX + 1, y + config.titleHeight / 2 + 1, Color(0, 0, 0, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            draw.SimpleText(countText, config.fontSize, countX, y + config.titleHeight / 2, config.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end

        -- 绘制通知文本（同样先画阴影）
        draw.SimpleText(notif.text, config.fontSize, x + config.padding + 1, y + config.titleHeight + config.padding + 1, Color(0, 0, 0, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        draw.SimpleText(notif.text, config.fontSize, x + config.padding, y + config.titleHeight + config.padding, config.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        -- 绘制闪烁边框（计数 > 1 时的闪烁提示）
        if notif.count > 1 and (notif.flashTime or 0) < config.flashDuration then
            local flashProgress = notif.flashTime / (config.flashDuration / (config.flashCount * 2))
            local flashState = math.floor(flashProgress) % 2

            if flashState == 0 then
                surface.SetDrawColor(255, 255, 255, 200)
                surface.DrawOutlinedRect(x - 2, y - 2, totalWidth + 4, totalHeight + 4)
            end
        end
    end
end

--[[
    更新指定编辑器的悬停提示文本。
    
    @param  editor  {table}   编辑器实例对象
    @param  text    {string}  提示文本，传入空字符串或 nil 清除提示
]]
function INE:UpdateHoverTooltip(editor, text)
    if not editor then return end
    editor.hoverTooltip = editor.hoverTooltip or { text = "", updated = false, x = 0, y = 0 }
    editor.hoverTooltip.text = text or ""
    editor.hoverTooltip.updated = true
end

--[[
    清除指定编辑器的悬停提示。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:ClearHoverTooltip(editor)
    if not editor then return end
    editor.hoverTooltip = editor.hoverTooltip or { text = "", updated = false, x = 0, y = 0 }
    editor.hoverTooltip.text = ""
    editor.hoverTooltip.updated = true
end

--[[
    在绘制开始前标记悬停提示为“本帧未更新”，用于自动清除过期的提示。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:BeginHoverTooltipFrame(editor)
    if not editor then return end
    editor.hoverTooltip = editor.hoverTooltip or { text = "", updated = false, x = 0, y = 0 }
    editor.hoverTooltip.updated = false
end

--[[
    绘制指定编辑器的悬停提示。
    提示显示在鼠标右下方，并限制在屏幕范围内。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:DrawHoverTooltip(editor)
    if not editor or not editor.hoverTooltip then return end
    local tooltip = editor.hoverTooltip
    if tooltip.text == "" or tooltip.text == nil then return end
    
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local text = tooltip.text
    local font = "SourceHan_Heavy_14"
    local padding = 8
    
    surface.SetFont(font)
    local textW, textH = surface.GetTextSize(text)
    local boxW = textW + padding * 2
    local boxH = textH + padding * 2
    
    local boxX = mouseX + 15
    local boxY = mouseY + 15
    
    -- 防止超出屏幕右/下边界
    if boxX + boxW > ScrW() then
        boxX = mouseX - boxW - 10
    end
    if boxY + boxH > ScrH() then
        boxY = mouseY - boxH - 10
    end
    
    draw.RoundedBox(4, boxX, boxY, boxW, boxH, Color(30, 30, 35, 240))
    draw.SimpleText(text, font, boxX + padding, boxY + padding, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end

function INE:GetFilteredNodeList(editor)
    local searchText = string.lower(editor._findNodeSearchText or "")
    local result = {}
    for _, node in ipairs(editor.nodes) do
        if searchText == "" or string.find(string.lower(node.name), searchText, 1, true) then
            table.insert(result, node)
        end
    end
    return result
end

function INE:ReadKeyboardChar(editor)
    editor._findKeyStates = editor._findKeyStates or {}
    local ch = nil
    
    for i = 1, 26 do
        local key = KEY_A + i - 1
        local keyDown = input.IsKeyDown(key)
        if keyDown and not editor._findKeyStates[key] then
            editor._findKeyStates[key] = true
            local char = string.char(96 + i)
            if input.IsKeyDown(KEY_LSHIFT) or input.IsKeyDown(KEY_RSHIFT) then
                char = string.upper(char)
            end
            if input.IsKeyDown(KEY_CAPSLOCK) then
                char = string.upper(char)
            end
            ch = char
            break
        elseif not keyDown then
            editor._findKeyStates[key] = false
        end
    end
    
    if not ch then
        for i = 0, 9 do
            local key = KEY_0 + i
            local keyDown = input.IsKeyDown(key)
            if keyDown and not editor._findKeyStates[key] then
                editor._findKeyStates[key] = true
                ch = tostring(i)
                break
            elseif not keyDown then
                editor._findKeyStates[key] = false
            end
        end
    end
    
    if not ch then
        local key = KEY_SPACE
        local keyDown = input.IsKeyDown(key)
        if keyDown and not editor._findKeyStates[key] then
            editor._findKeyStates[key] = true
            ch = " "
        elseif not keyDown then
            editor._findKeyStates[key] = false
        end
    end
    
    if not ch then
        local key = KEY_MINUS
        local keyDown = input.IsKeyDown(key)
        if keyDown and not editor._findKeyStates[key] then
            editor._findKeyStates[key] = true
            ch = (input.IsKeyDown(KEY_LSHIFT) or input.IsKeyDown(KEY_RSHIFT)) and "_" or "-"
        elseif not keyDown then
            editor._findKeyStates[key] = false
        end
    end
    
    return ch
end

function INE:OpenFindNodeWindow(editor)
    editor._findNodeWindowOpen = true
    editor._findNodeSearchText = ""
    editor._findNodeSelectedIndex = 0
    editor._findNodeInputFocused = true
    editor._findKeyStates = {}
    
    local rect = self:GetCanvasRect(editor)
    INE:ShowOverlayWindow(editor, {
        id = "find_node_window",
        title = T("editor.nodeeditor.find_node_title"),
        x = rect.x + rect.w/2 - 175,
        y = rect.y + 80,
        width = 350,
        height = 300,
        content = function(editor, win, wx, wy, ww, wh)
            INE:DrawFindNodeContent(editor, win, wx, wy, ww, wh)
        end,
        onClose = function(win)
            editor._findNodeWindowOpen = false
        end
    })
end

function INE:DrawFindNodeContent(editor, win, wx, wy, ww, wh)
    local searchText = editor._findNodeSearchText or ""
    
    draw.RoundedBox(4, wx + 5, wy + 5, ww - 10, 28, Color(40, 40, 45))
    
    if searchText ~= "" then
        draw.SimpleText(searchText, "Calibri_20", wx + 12, wy + 19, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(T("editor.nodeeditor.find_node_placeholder"), "Calibri_20", wx + 12, wy + 19, Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    
    if editor._findNodeInputFocused and CurTime() % 1 < 0.5 then
        local textW = 0
        if searchText ~= "" then
            surface.SetFont("Calibri_20")
            textW = surface.GetTextSize(searchText)
        end
        local cursorX = wx + 12 + textW + 2
        surface.SetDrawColor(Color(220, 220, 220))
        surface.DrawRect(cursorX, wy + 10, 2, 18)
    end
    
    local listStartY = wy + 40
    local itemH = 26
    local filteredNodes = INE:GetFilteredNodeList(editor)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    if #filteredNodes == 0 then
        draw.SimpleText(T("editor.nodeeditor.find_node_no_results"), "SourceHan_Heavy_14", wx + ww/2, listStartY + 20, Color(120, 120, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    else
        for i, node in ipairs(filteredNodes) do
            local itemY = listStartY + (i - 1) * itemH
            if itemY + itemH > wy + wh then break end
            
            local itemX = wx + 2
            local itemW = ww - 4
            
            local itemHovered = mouseX >= itemX and mouseX <= itemX + itemW and
                               mouseY >= itemY and mouseY <= itemY + itemH
            local itemSelected = (i == editor._findNodeSelectedIndex)
            
            local bgColor = nil
            if itemSelected then
                bgColor = Color(70, 100, 150)
            elseif itemHovered then
                bgColor = Color(60, 60, 70)
            end
            
            if bgColor then
                draw.RoundedBox(2, itemX, itemY, itemW, itemH, bgColor)
            end
            
            draw.SimpleText(node.name, "SourceHan_Heavy_14", wx + 10, itemY + itemH/2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end
end

--[[
    启用画布裁剪区域，限制后续绘制只在画布区域内显示。
]]
function INE:BeginCanvasScissor(editor)
    local rect = self:GetCanvasRect(editor)
    -- 使用整数坐标避免浮点精度导致裁剪区域异常
    local x1 = math.floor(rect.x)
    local y1 = math.floor(rect.y)
    local x2 = math.ceil(rect.x + rect.w)
    local y2 = math.ceil(rect.y + rect.h)
    render.SetScissorRect(x1, y1, x2, y2, true)
end

--[[
    禁用画布裁剪区域，恢复正常绘制。
]]
function INE:EndCanvasScissor()
    render.SetScissorRect(0, 0, 0, 0, false)
end

--[[
    显示一个叠加窗口。
    
    @param  editor      {table}     编辑器实例
    @param  windowData  {table}     窗口数据表，至少包含id, title, x, y, width, height, content
]]
function INE:ShowOverlayWindow(editor, windowData)
    windowData.visible = true
    windowData.draggable = windowData.draggable ~= false
    editor.overlayWindows = editor.overlayWindows or {}
    -- 先删除旧条目再重新插入，确保新窗口在 pairs 迭代中排在最后（即绘制在最上层）
    if editor.overlayWindows[windowData.id] then
        editor.overlayWindows[windowData.id] = nil
    end
    editor.overlayWindows[windowData.id] = windowData
    -- 记录创建序号用于确定绘制顺序（后创建的在上层）
    INE._overlayOrderCounter = (INE._overlayOrderCounter or 0) + 1
    windowData._order = INE._overlayOrderCounter
end

--[[
    隐藏/关闭叠加窗口。
    
    @param  editor    {table}   编辑器实例
    @param  windowId  {string}  窗口ID
]]
function INE:CloseOverlayWindow(editor, windowId)
    if editor.overlayWindows and editor.overlayWindows[windowId] then
        local win = editor.overlayWindows[windowId]
        win.visible = false
        if win.onClose then win:onClose() end
        editor.overlayWindows[windowId] = nil
    end
end

--[[
    获取指定位置上方的叠加窗口（用于命中检测，逆序遍历后创建的窗口在上层）。
    
    @param  editor   {table}   编辑器实例
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中的窗口实例，未命中返回nil
]]
function INE:GetOverlayWindowAt(editor, screenX, screenY)
    if not editor.overlayWindows then return nil end
    local windows = {}
    for _, win in pairs(editor.overlayWindows) do
        if win.visible then table.insert(windows, win) end
    end
    -- 按创建顺序排序，后创建的在上层（与绘制顺序一致）
    table.sort(windows, function(a, b) return (a._order or 0) < (b._order or 0) end)
    for i = #windows, 1, -1 do
        local win = windows[i]
        if screenX >= win.x and screenX <= win.x + win.width and
           screenY >= win.y and screenY <= win.y + win.height then
            return win
        end
    end
    return nil
end

--[[
    判断鼠标是否在任何叠加窗口上。
    
    @param  editor   {table}   编辑器实例
    @param  mouseX   {number}  鼠标X坐标
    @param  mouseY   {number}  鼠标Y坐标
    
    @return {boolean} 鼠标在叠加窗口上返回true
]]
function INE:IsMouseOverOverlayWindow(editor, mouseX, mouseY)
    return self:GetOverlayWindowAt(editor, mouseX, mouseY) ~= nil
end

--[[
    绘制单个叠加窗口。
    
    @param  editor  {table}   编辑器实例
    @param  win     {table}   窗口实例
]]
function INE:DrawOverlayWindow(editor, win)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    draw.RoundedBox(8, win.x + 2, win.y + 2, win.width, win.height, Color(0, 0, 0, 100))
    draw.RoundedBox(8, win.x, win.y, win.width, win.height, Color(55, 55, 60, 250))
    draw.RoundedBoxEx(8, win.x, win.y, win.width, 32, Color(65, 65, 75), true, true, false, false)
    local titleMaxX = win.x + win.width
    draw.SimpleText(win.title, "SourceHan_Heavy_16", win.x + 10, win.y + 16, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    
    local closeX = win.x + win.width - 30
    local closeY = win.y + 3
    local closeW = 25
    local closeH = 25
    local closeHovered = mouseX >= closeX and mouseX <= closeX + closeW and
                        mouseY >= closeY and mouseY <= closeY + closeH
    draw.RoundedBox(4, closeX, closeY, closeW, closeH, closeHovered and Color(200, 70, 70) or Color(180, 60, 60))
    draw.SimpleText("X", "SourceHan_Heavy_14", closeX + closeW/2, closeY + closeH/2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    win._closeBtn = {x = closeX, y = closeY, w = closeW, h = closeH}
    
    -- 变量分类选择器（仅变量对话框显示）
    if win.showScope then
        local scope = win.scope or "global"
        local btnW, btnH = 32, 22
        local btnY = win.y + 5
        local gap = 4
        -- 长期按钮
        local longX = closeX - btnW - gap
        local longHov = mouseX >= longX and mouseX <= longX + btnW and mouseY >= btnY and mouseY <= btnY + btnH
        local longActive = (scope == "longterm")
        draw.RoundedBox(4, longX, btnY, btnW, btnH,
            longActive and Color(180, 120, 60) or (longHov and Color(90, 85, 80) or Color(65, 65, 75)))
        draw.SimpleText(T("editor.nodeeditor.scope_longterm"), "SourceHan_Heavy_10", longX + btnW/2, btnY + btnH/2,
            longActive and Color(255, 230, 180) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        win._scopeLongtermBtn = {x = longX, y = btnY, w = btnW, h = btnH}
        -- 全局按钮
        local globalX = longX - btnW - gap
        local globalHov = mouseX >= globalX and mouseX <= globalX + btnW and mouseY >= btnY and mouseY <= btnY + btnH
        local globalActive = (scope == "global" or not scope)
        draw.RoundedBox(4, globalX, btnY, btnW, btnH,
            globalActive and Color(80, 120, 180) or (globalHov and Color(85, 85, 90) or Color(65, 65, 75)))
        draw.SimpleText(T("editor.nodeeditor.scope_global"), "SourceHan_Heavy_10", globalX + btnW/2, btnY + btnH/2,
            globalActive and Color(180, 210, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        win._scopeGlobalBtn = {x = globalX, y = btnY, w = btnW, h = btnH}
    end
    
    local clientX = win.x
    local clientY = win.y + 32
    local clientW = win.width
    local clientH = win.height - 32
    if win.content then
        win.content(editor, win, clientX, clientY, clientW, clientH)
    end
end

--[[
    绘制导入文件选择窗口的内容（文件列表 + 按钮）。
    
    @param  editor  {table}   编辑器实例
    @param  win     {table}   窗口实例
    @param  cx      {number}  客户区X
    @param  cy      {number}  客户区Y
    @param  cw      {number}  客户区宽度
    @param  ch      {number}  客户区高度
]]
function INE:DrawImportWindowContent(editor, win, cx, cy, cw, ch)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    -- 绘制提示文字
    draw.SimpleText(T("editor.nodeeditor.import_select_file"), "SourceHan_Heavy_16", cx + 15, cy + 15, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    
    -- 文件列表区域
    local listX = cx + 10
    local listY = cy + 40
    local listW = cw - 20
    local listH = ch - 110
    
    -- 列表背景
    draw.RoundedBox(4, listX, listY, listW, listH, Color(45, 45, 50))
    
    -- 文件列表
    local files = editor._importFiles or {}
    local itemH = 30
    local startY = listY + 5
    local scrollOffset = editor._importScrollOffset or 0
    
    -- 存储文件行矩形用于点击检测
    editor._importFileRects = {}
    
    for i = 1, #files do
        local idx = i + scrollOffset
        if idx < 1 then idx = 1 end
        if idx > #files then break end
        
        local itemY = startY + (i - 1) * itemH
        if itemY + itemH > listY + listH then break end
        
        local fileName = files[idx]
        local isSelected = editor._importSelectedFile == fileName
        local isHovered = mouseX >= listX and mouseX <= listX + listW and mouseY >= itemY and mouseY <= itemY + itemH
        
        local itemColor = isSelected and Color(80, 80, 120) or (isHovered and Color(65, 65, 70) or Color(45, 45, 50))
        draw.RoundedBox(2, listX + 2, itemY, listW - 4, itemH - 2, itemColor)
        
        draw.SimpleText(fileName, "SourceHan_Heavy_14", listX + 15, itemY + itemH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        
        -- 存储矩形用于点击检测
        table.insert(editor._importFileRects, {x = listX + 2, y = itemY, w = listW - 4, h = itemH - 2, idx = idx})
    end
    
    -- 按钮区域
    local btnY = cy + ch - 45
    
    -- 加载按钮
    local loadBtnX = cx + cw / 2 - 175
    local loadBtnW = 160
    local loadBtnH = 35
    local loadEnabled = editor._importSelectedFile ~= nil
    local loadHovered = mouseX >= loadBtnX and mouseX <= loadBtnX + loadBtnW and mouseY >= btnY and mouseY <= btnY + loadBtnH
    
    editor._importLoadBtnRect = {x = loadBtnX, y = btnY, w = loadBtnW, h = loadBtnH}
    
    local loadColor = loadEnabled and (loadHovered and Color(100, 150, 255) or Color(80, 120, 200)) or Color(70, 70, 75)
    draw.RoundedBox(6, loadBtnX, btnY, loadBtnW, loadBtnH, loadColor)
    draw.SimpleText(T("editor.nodeeditor.button_load"), "SourceHan_Heavy_16", loadBtnX + loadBtnW / 2, btnY + loadBtnH / 2, loadEnabled and Color(255, 255, 255) or Color(150, 150, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 取消按钮
    local cancelBtnX = cx + cw / 2 + 15
    local cancelBtnW = 160
    local cancelBtnH = 35
    local cancelHovered = mouseX >= cancelBtnX and mouseX <= cancelBtnX + cancelBtnW and mouseY >= btnY and mouseY <= btnY + cancelBtnH
    
    editor._importCancelBtnRect = {x = cancelBtnX, y = btnY, w = cancelBtnW, h = cancelBtnH}
    
    local cancelColor = cancelHovered and Color(100, 100, 100) or Color(80, 80, 85)
    draw.RoundedBox(6, cancelBtnX, btnY, cancelBtnW, cancelBtnH, cancelColor)
    draw.SimpleText(T("editor.nodeeditor.button_cancel"), "SourceHan_Heavy_16", cancelBtnX + cancelBtnW / 2, btnY + cancelBtnH / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end
