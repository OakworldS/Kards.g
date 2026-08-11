--[[
=======================================================================================
通知/提示系统 (Notification/Toast System)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的子系统，负责屏幕通知提示的显示和管理。

包含功能：
  - AddNotification（添加提示）
  - AddNodeEditorNotification（向 INE 编辑器发送提示）
  - UpdateNotifications（更新提示状态与动画）
  - DrawNotifications（绘制提示框）
  - EaseOutBack（回弹缓动函数，为通知动画提供缓动效果）

状态数据：
  - NotificationConfig（行 1009~1024）
  - Notifications（行 1027）

源文件：cl_canvas_editor.lua
  - 状态数据：行 1009~1027
  - 工具函数：行 8775~8779（EaseOutBack）
  - 功能函数：行 8785~8852（AddNotification、AddNodeEditorNotification）
  - 更新逻辑：行 8855~8904（UpdateNotifications）
  - 绘制函数：行 9052~9123（DrawNotifications + 测试指令）
=======================================================================================
]]

-- 防御性命名空间初始化：确保即使本文件在 GMod 自动加载阶段先于
-- sh_card_editor_loader.lua 被加载，KARDS.CardEditor.Canvas 也已就绪
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}
KARDS.CardEditor.Audio = KARDS.CardEditor.Audio or {}
KARDS.CardEditor.Audio.PlayNotification = KARDS.CardEditor.Audio.PlayNotification or function() end
KARDS.CardEditor.Audio.PlayNotificationSuccess = KARDS.CardEditor.Audio.PlayNotificationSuccess or function() end

-- 提示计数器
KARDS.CardEditor.Canvas.NotificationCounter = 0

-- 提示系统配置
KARDS.CardEditor.Canvas.NotificationConfig = {
    animationDuration = 0.5,      -- 动画持续时间（秒）
    displayDuration = 1.5,         -- 显示持续时间（秒）
    minWidth = 150,                -- 最小宽度
    maxWidth = 300,                -- 最大宽度
    padding = 12,                  -- 内边距
    titleHeight = 18,              -- 标题框高度（减少）
    rowSpacing = 10,                  -- 提示间距
    cornerRadius = 8,              -- 圆角半径
    titleColor = Color(80, 80, 80), -- 标题框颜色（灰色）
    textColor = Color(255, 255, 255),  -- 文本颜色
    flashDuration = 0.5,           -- 闪烁持续时间
    flashCount = 3,                -- 闪烁次数
    fontSize = "SourceHan_Heavy_14" -- 字体
}

-- 提示系统配置
KARDS.CardEditor.Canvas.Notifications = {}
-- 添加提示函数
-- 注意：此函数已经有频繁触发提示的兼容
-- 当短时间内有相同文本的提示被调用时，会对提示启动"计数"
-- 并重置倒计时回 1.5 秒，同时触发闪烁效果
function KARDS.CardEditor.Canvas.AddNotification(text, color, isSuccess)
    color = color or Color(200, 100, 50)
    local currentTime = SysTime()
    local config = KARDS.CardEditor.Canvas.NotificationConfig
    
    if isSuccess then
        KARDS.CardEditor.Audio.PlayNotificationSuccess()
    else
        KARDS.CardEditor.Audio.PlayNotification()
    end
    
    -- 检查是否有重复的提示
    for i, notification in ipairs(KARDS.CardEditor.Canvas.Notifications) do
        if notification.text == text and currentTime - notification.createdTime < 2 then
            -- 更新现有提示
            notification.count = notification.count + 1
            notification.createdTime = currentTime
            notification.animationTime = 0
            notification.state = "entering"
            notification.flashTime = 0
            notification.flashCount = 0
            return
        end
    end
    
    -- 创建新提示
    KARDS.CardEditor.Canvas.NotificationCounter = KARDS.CardEditor.Canvas.NotificationCounter + 1
    local notification = {
        id = "notification_" .. KARDS.CardEditor.Canvas.NotificationCounter,
        text = text,
        color = color,
        count = 1,
        createdTime = currentTime,
        animationTime = 0,
        state = "entering",
        position = 0,
        flashTime = 0,
        flashCount = 0,
        width = 0,
        height = 0
    }
    
    -- 计算提示框尺寸
    surface.SetFont(config.fontSize)
    local textWidth, textHeight = surface.GetTextSize(text)
    notification.width = math.Clamp(textWidth + config.padding * 2, config.minWidth, config.maxWidth)
    notification.height = textHeight + config.padding * 2 + config.titleHeight
    
    table.insert(KARDS.CardEditor.Canvas.Notifications, notification)
end
-- 更新提示状态
function KARDS.CardEditor.Canvas.UpdateNotifications()
    local currentTime = SysTime()
    local config = KARDS.CardEditor.Canvas.NotificationConfig
    local notifications = KARDS.CardEditor.Canvas.Notifications
    
    -- 过滤掉过期的提示
    local validNotifications = {}
    for i, notification in ipairs(notifications) do
        notification.animationTime = notification.animationTime + FrameTime()
        
        local shouldSkip = false
        if notification.state == "entering" then
            if notification.animationTime >= config.animationDuration then
                notification.state = "active"
                notification.animationTime = 0
            end
        elseif notification.state == "active" then
            if notification.animationTime >= config.displayDuration then
                notification.state = "exiting"
                notification.animationTime = 0
            end
        elseif notification.state == "exiting" then
            if notification.animationTime >= config.animationDuration then
                -- 提示过期，不添加到有效列表
                shouldSkip = true
            end
        end
        
        if not shouldSkip then
            -- 更新闪烁状态
            if notification.count > 1 then
                notification.flashTime = notification.flashTime + FrameTime()
            end
            
            table.insert(validNotifications, notification)
        end
    end
    
    -- 按创建时间排序，新提示在上
    table.sort(validNotifications, function(a, b)
        return a.createdTime > b.createdTime
    end)
    
    -- 更新位置索引
    for i, notification in ipairs(validNotifications) do
        notification.position = i - 1
    end
    
    KARDS.CardEditor.Canvas.Notifications = validNotifications
end
-- 绘制提示
function KARDS.CardEditor.Canvas.DrawNotifications()
    if #KARDS.CardEditor.Canvas.Notifications == 0 then return end

    local win = KARDS.CardEditor.Canvas.Window
    local config = KARDS.CardEditor.Canvas.NotificationConfig
    local notifications = KARDS.CardEditor.Canvas.Notifications

    for i, notification in ipairs(notifications) do
        local totalWidth = notification.width
        local totalHeight = notification.height
        local rowSpacing = config.rowSpacing
        -- 调整Y坐标，使通知显示在国家按钮之下（国家按钮在 win.y + 40 位置，高度30）
        local y = win.y + 80 + notification.position * (totalHeight + rowSpacing)

        -- 计算动画位置
        -- 进入：从窗口右侧外侧(totalWidth)滑入到内侧(-totalWidth)
        -- 活动：保持在内侧(-totalWidth)
        -- 退出：从内侧(-totalWidth)滑出到外侧(totalWidth)
        local xOffset = 0
        if notification.state == "entering" then
            local progress = math.min(notification.animationTime / config.animationDuration, 1)
            xOffset = KARDS.CardEditor.Canvas.EaseOutBack(progress, totalWidth, -totalWidth * 2, 1)
        elseif notification.state == "active" then
            -- 活动状态：保持在窗口内侧
            xOffset = -totalWidth
        elseif notification.state == "exiting" then
            local progress = math.min(notification.animationTime / config.animationDuration, 1)
            xOffset = KARDS.CardEditor.Canvas.EaseOutBack(progress, -totalWidth, totalWidth * 2, 1)
        end

        -- x 是提示框的左边缘位置
        -- 进入时：x 从 win.x + win.width + totalWidth(外侧) 变为 win.x + win.width - totalWidth(内侧)
        local x = win.x + win.width + xOffset

        -- 绘制背景
        draw.RoundedBox(config.cornerRadius, x, y, totalWidth, totalHeight, notification.color)

        -- 绘制标题框
        draw.RoundedBoxEx(config.cornerRadius, x, y, totalWidth, config.titleHeight, config.titleColor, true, true, false, false)

        -- 绘制标题文本
        local titleText = "提示  -Tip-"
        draw.SimpleText(titleText, config.fontSize, x + config.padding, y + config.titleHeight / 2, config.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 绘制计数在标题框中
        if notification.count > 1 then
            local countText = "×" .. notification.count
            surface.SetFont(config.fontSize)
            local countWidth, countHeight = surface.GetTextSize(countText)
            local countX = x + totalWidth - config.padding - countWidth
            local countY = y + config.titleHeight / 2

            -- 绘制计数背景
            draw.RoundedBox(4, countX - 4, countY - countHeight / 2 - 2, countWidth + 8, countHeight + 4, Color(0, 0, 0, 150))
            draw.SimpleText(countText, config.fontSize, countX, countY, config.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end

        -- 绘制文本
        draw.SimpleText(notification.text, config.fontSize, x + config.padding, y + config.titleHeight + config.padding, config.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        -- 绘制闪烁效果
        if notification.count > 1 and notification.flashTime < config.flashDuration then
            local flashProgress = notification.flashTime / (config.flashDuration / (config.flashCount * 2))
            local flashState = math.floor(flashProgress) % 2

            if flashState == 0 then
                surface.SetDrawColor(255, 255, 255, 200)
                surface.DrawOutlinedRect(x - 2, y - 2, totalWidth + 4, totalHeight + 4)
            end
        end
    end
end
-- 回弹缓动函数
function KARDS.CardEditor.Canvas.EaseOutBack(t, b, c, d, s)
    s = s or 1.70158
    t = t / d - 1
    return c * (t * t * ((s + 1) * t + s) + 1) + b
end