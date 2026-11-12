--[[
=======================================================================================
外貌编辑器模块 (Appearance Editors)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的子系统，负责卡牌外貌属性编辑区的绘制。

包含功能：
  - DrawSliderBar（滑动条组件）
  - DrawHoverButton（悬停按钮组件）
  - DrawApplePillChip（Apple 药丸标签组件）
  - DrawTypeEditArea（类型编辑区）
  - DrawSliderWithInput（带输入框的滑动条组件）
  - DrawAttrEditArea（属性编辑区）
  - DrawCountryEditArea（国家编辑区）
  - DrawKeywordsEditArea（关键词编辑区）
  - DrawDescriptionEditArea（描述编辑区）
  - ScanLocalImages（扫描本地图片）
  - DrawIllustrationEditArea（插图编辑区）
  - GetImageFileDimensions / GetImageDimensions（图片尺寸工具）
  - AutoFitImageScale（自适应缩放）
  - StartHistoryImageDownload / StartImageDownload（图片下载）
  - DrawHistoryEditArea（历史编辑区）

源文件：cl_canvas_editor.lua（下列行号为拆分时的历史行号，非当前行号；当前定义位置见本文件内各函数）
  - DrawSliderBar：行 6708~6883
  - DrawHoverButton：行 6885~6905
  - DrawApplePillChip：行 6907~6931
  - DrawTypeEditArea：行 6933~7176
  - DrawSliderWithInput：行 7194~7270
  - DrawAttrEditArea：行 7272~7303
  - DrawCountryEditArea：行 7305~7343
  - DrawKeywordsEditArea：行 7345~7531
  - DrawDescriptionEditArea：行 7533~7627
  - ScanLocalImages：行 7629~7635
  - DrawIllustrationEditArea：行 7638~8027
  - GetImageFileDimensions：行 8043~8083
  - GetImageDimensions：行 8085~8093
  - AutoFitImageScale：行 8095~8148
  - StartHistoryImageDownload：行 8150~8177
  - StartImageDownload：行 8179~8208
  - DrawHistoryEditArea：行 8211~9272
=======================================================================================
]]

-- 防御性命名空间初始化：确保即使本文件在 GMod 自动加载阶段先于
-- sh_card_editor_loader.lua 被加载，KARDS.CardEditor.Canvas 也已就绪
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}
local T = KARDS.Lang.T

-- ================================================================
-- 滑动进度条组件
-- 自定义绘制的水平滑动条，支持数轴刻度、自动平移动画、整数取值
-- ================================================================
-- @param x,y,w,h: 滑动条区域（数轴 + 刻度标签 + 滑块的总绘制区域）
-- @param value: 当前值（引用，函数内修改）
-- @param minVal: 全局最小值
-- @param maxVal: 全局最大值
-- @param displayMin: 当前可见范围最小值（引用）
-- @param displayMax: 当前可见范围最大值（引用）
-- @param sliderState: 拖拽状态表（含 isDragging, animating 等字段）
-- @param mx, my: 鼠标坐标
-- @param isLeftPressed: 是否鼠标左键按下瞬间
-- @param dt: 帧时间
local function DrawSliderBar(x, y, w, h, valueRef, minVal, maxVal, displayMinRef, displayMaxRef, sliderState, mx, my, isLeftPressed, dt, arrowDir, stepSize)
    sliderState = sliderState or { isDragging = false, animating = false, dragStartX = 0, dragValueAtStart = 0, displayMin = 0, displayMax = 10, animStartTime = 0, animDuration = 0.3 }
    arrowDir = arrowDir or "right"   -- "right" 或 "left"
    stepSize = stepSize or 1         -- 步长（取整间隔）
    local val = valueRef[1]
    local dMin = displayMinRef[1]
    local dMax = displayMaxRef[1]
    maxVal = maxVal or 99  -- 默认最大值 99
    minVal = minVal or 0
    local axisY = y + h - 6  -- 数轴纵坐标（底部留空间给标签）
    local shiftStep = stepSize  -- 自动平移步长等于步长

    -- 处理平移动画
    if sliderState.animating then
        local elapsed = SysTime() - sliderState.animStartTime
        local t = math.min(1, elapsed / sliderState.animDuration)
        -- 使用 easeOutCubic 缓动
        local ease = 1 - math.pow(1 - t, 3)
        dMin = sliderState.animDisplayMinFrom + (sliderState.animDisplayMinTo - sliderState.animDisplayMinFrom) * ease
        dMax = sliderState.animDisplayMaxFrom + (sliderState.animDisplayMaxTo - sliderState.animDisplayMaxFrom) * ease
        if t >= 1 then
            dMin = sliderState.animDisplayMinTo
            dMax = sliderState.animDisplayMaxTo
            sliderState.animating = false
        end
        displayMinRef[1] = dMin
        displayMaxRef[1] = dMax
    end

    -- 自动平移：当值到达数轴边缘时，整个可见范围固定平移 shiftStep 个单位
    if not sliderState.isDragging and not sliderState.animating then
        local intVal = math.floor(val + 0.5)
        if intVal >= dMax and dMax < maxVal then
            -- 值到达右边界 → 范围右移
            local shift = math.min(shiftStep, maxVal - dMax)
            if shift > 0 then
                sliderState.animDisplayMinFrom = dMin
                sliderState.animDisplayMaxFrom = dMax
                sliderState.animDisplayMinTo = math.min(dMin + shift, maxVal - (dMax - dMin))
                sliderState.animDisplayMaxTo = math.min(dMax + shift, maxVal)
                sliderState.animStartTime = SysTime()
                sliderState.animDuration = math.Clamp(shift * 0.06, 0.15, 0.6)
                sliderState.animating = true
            end
        elseif intVal <= dMin and dMin > minVal then
            -- 值到达左边界 → 范围左移
            local shift = math.min(shiftStep, dMin - minVal)
            if shift > 0 then
                sliderState.animDisplayMinFrom = dMin
                sliderState.animDisplayMaxFrom = dMax
                sliderState.animDisplayMinTo = math.max(dMin - shift, minVal)
                sliderState.animDisplayMaxTo = math.max(dMax - shift, minVal + (dMax - dMin))
                sliderState.animStartTime = SysTime()
                sliderState.animDuration = math.Clamp(shift * 0.06, 0.15, 0.6)
                sliderState.animating = true
            end
        end
    end

    -- 鼠标拖拽处理
    if sliderState.isDragging then
        if input.IsMouseDown(MOUSE_LEFT) then
            -- 拖拽中：浮点跟随鼠标 X 轴，不取整
            local range = dMax - dMin
            if range <= 0 then range = 1 end
            local ratio = (mx - x) / w
            ratio = math.Clamp(ratio, 0, 1)
            local newVal = dMin + ratio * range
            newVal = math.Clamp(newVal, minVal, maxVal)
            val = newVal
            valueRef[1] = val
        else
            -- 释放时：按步长取整
            if stepSize > 1 then
                val = math.floor((val + stepSize / 2) / stepSize) * stepSize
            else
                val = math.floor(val + 0.5)
            end
            val = math.Clamp(val, minVal, maxVal)
            valueRef[1] = val
            sliderState.isDragging = false
        end
    else
        -- 检测新的拖拽开始 + 点击轴跳转
        if isLeftPressed then
            local sliderCX = x + (val - dMin) / (dMax - dMin) * w
            if dMax - dMin <= 0 then sliderCX = x end
            local sliderR = 8
            if mx >= sliderCX - sliderR and mx <= sliderCX + sliderR and my >= y and my <= y + h then
                -- 点击滑块 → 开始拖拽
                sliderState.isDragging = true
            elseif mx >= x and mx <= x + w and my >= y and my <= y + h then
                -- 点击数轴其他位置 → 直接跳转到该位置
                local range = dMax - dMin
                if range <= 0 then range = 1 end
                local ratio = (mx - x) / w
                ratio = math.Clamp(ratio, 0, 1)
                local newVal = dMin + ratio * range
                newVal = math.Clamp(newVal, minVal, maxVal)
                -- 按步长取整
                if stepSize > 1 then
                    newVal = math.floor((newVal + stepSize / 2) / stepSize) * stepSize
                else
                    newVal = math.floor(newVal + 0.5)
                end
                valueRef[1] = newVal
            end
        end
    end

    -- 获取最新值用于绘制
    val = valueRef[1]
    dMin = displayMinRef[1]
    dMax = displayMaxRef[1]

    -- ===== 绘制数轴 =====
    local axisLeftX = x
    local axisRightX = x + w
    local range = dMax - dMin
    if range <= 0 then range = 1 end

    local tickAreaLeft, tickAreaRight

    if arrowDir == "left" then
        -- 左端箭头模式
        tickAreaLeft = axisLeftX + 6
        tickAreaRight = axisRightX

        -- 数轴线（从箭头右端到右侧）
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawRect(tickAreaLeft, axisY - 1, tickAreaRight - tickAreaLeft, 2)

        -- 左端箭头
        draw.SimpleText("◀", "SourceHan_Heavy_16", axisLeftX + 2, axisY, APPLE_INK, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        -- 当前范围最小值标注（在箭头右侧）
        local labelY = axisY - 3 - 8 - 4
        draw.SimpleText(tostring(math.floor(dMin)), "SourceHan_Heavy_12", tickAreaLeft + 2, labelY, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
    else
        -- 右端箭头模式（默认/原有行为）
        tickAreaLeft = axisLeftX
        tickAreaRight = axisRightX - 6

        -- 数轴线（延伸到箭头）
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawRect(axisLeftX, axisY - 1, tickAreaRight - axisLeftX, 2)

        -- 右端箭头
        draw.SimpleText("▶", "SourceHan_Heavy_16", axisRightX - 2, axisY, APPLE_INK, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        -- 当前范围最大值标注
        local labelY = axisY - 3 - 8 - 4
        draw.SimpleText(tostring(math.floor(dMax)), "SourceHan_Heavy_12", tickAreaRight, labelY, APPLE_INK_MUTED80, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
    end

    -- ===== 绘制刻度（含半值中间刻度） =====
    local tickLong = 8  -- 长刻度高度
    local tickShort = 4 -- 半值刻度高度

    for i = math.ceil(dMin), math.floor(dMax) do
        local ratio = (i - dMin) / range
        local tickX = tickAreaLeft + ratio * (tickAreaRight - tickAreaLeft)
        local isMax = (i >= math.floor(dMax))

        if not isMax then
            -- 主刻度（整数值）
            surface.SetDrawColor(APPLE_HAIRLINE)
            surface.DrawLine(tickX, axisY - 3, tickX, axisY - 3 - tickLong)
        end

        -- 整数值数字标签（步长>1时只渲染可达的数字）
        local numLabelY = axisY - 3 - tickLong - 2
        if not isMax then
            if stepSize <= 1 or (i - minVal) % stepSize == 0 then
                draw.SimpleText(tostring(i), "SourceHan_Heavy_12", tickX, numLabelY, APPLE_INK_MUTED80, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
            end
        end
    end

    -- 半值中间刻度（密度翻倍）
    for half = math.ceil(dMin * 2) / 2, math.floor(dMax * 2) / 2 - 0.5, 0.5 do
        local halfInt = half * 2
        if halfInt % 2 ~= 0 then  -- 只在半值上画，跳过整值
            local ratio = (half - dMin) / range
            local tickX = tickAreaLeft + ratio * (tickAreaRight - tickAreaLeft)
            surface.SetDrawColor(APPLE_HAIRLINE)
            surface.DrawLine(tickX, axisY - 3, tickX, axisY - 3 - tickShort)
        end
    end

    -- ===== 绘制填充条 =====
    local sliderRatio = (val - dMin) / range
    sliderRatio = math.Clamp(sliderRatio, 0, 1)
    local sliderCenterX = tickAreaLeft + sliderRatio * (tickAreaRight - tickAreaLeft)

    -- 左段（已填充）- 蓝色（6px 高）
    if sliderCenterX > tickAreaLeft then
        surface.SetDrawColor(APPLE_BLUE)
        surface.DrawRect(tickAreaLeft, axisY - 3, sliderCenterX - tickAreaLeft, 6)
    end

    -- 右段（未填充）- hairline（6px 高）
    if sliderCenterX < tickAreaRight then
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawRect(sliderCenterX, axisY - 3, tickAreaRight - sliderCenterX, 6)
    end

    -- ===== 绘制滑块（圆形，亮色突出） =====
    local sliderR = 8
    local sliderBodyColor = Color(230, 230, 230)
    local sliderBorderColor = Color(180, 180, 180)
    -- 阴影
    surface.SetDrawColor(Color(0, 0, 0, 60))
    surface.DrawCircle(sliderCenterX + 1, axisY + 2, sliderR + 1)
    -- 本体（亮灰色突出于暗色背景）
    surface.SetDrawColor(sliderBodyColor)
    surface.DrawCircle(sliderCenterX, axisY, sliderR)
    -- 边框
    surface.SetDrawColor(sliderBorderColor)
    surface.DrawCircle(sliderCenterX, axisY, sliderR)
end

-- 绘制带悬停背景色的按钮（RoundedBox + 居中文字）
-- @param x, y, w, h: 位置和尺寸
-- @param text: 按钮文字
-- @param isHovered: 是否悬停
-- @param opts: 可选参数表
--   radius: 圆角（默认 4）
--   hoverBg: 悬停背景色（默认 Color(100, 100, 100)）
--   normalBg: 正常背景色（默认 Color(80, 80, 80)）
--   textColor: 文字颜色（默认 Color(255, 255, 255)）
--   font: 字体（默认 "SourceHan_Heavy_14"）
local function DrawHoverButton(x, y, w, h, text, isHovered, opts)
    opts = opts or {}
    local radius = opts.radius or 4
    local hoverBg = opts.hoverBg or Color(100, 100, 100)
    local normalBg = opts.normalBg or Color(80, 80, 80)
    local textColor = opts.textColor or Color(255, 255, 255)
    local font = opts.font or "SourceHan_Heavy_14"

    draw.RoundedBox(radius, x, y, w, h, isHovered and hoverBg or normalBg)
    draw.SimpleText(text, font, x + w / 2, y + h / 2, textColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- 导出供 cl_canvas_editor.lua 使用
KARDS.CardEditor.Canvas.DrawHoverButton = DrawHoverButton

-- ====================================================================
-- 气泡提示（统一实现，带淡入上浮与淡出动画）
-- 外观编辑器内原本有三处各自手绘的黑色气泡：规模提示、属性滑条提示、
-- 不稳定警告。字号与出现方式不一致，这里收敛为同一组件（2026-11-07）。
-- 状态按 key 跨帧缓存；未悬停时继续绘制直到淡出完成。
-- ====================================================================
local BubbleStates = {}

local function DrawTooltipBubble(key, anchorX, anchorY, text, isHovered, opts)
    opts = opts or {}
    local font = opts.font or "SourceHan_Heavy_14"
    local padX = opts.padX or 8
    local padY = opts.padY or 5
    local offsetX = opts.offsetX or 4
    local offsetY = opts.offsetY or 0
    local radius = opts.radius or 4
    local bgColor = opts.bgColor or Color(0, 0, 0, 215)

    local state = BubbleStates[key]
    if not state then
        state = { progress = 0, x = anchorX, y = anchorY }
        BubbleStates[key] = state
    end

    -- 进入比退出快，避免鼠标划过时闪烁
    local dt = opts.dt or FrameTime()
    local speed = isHovered and 14 or 9
    if isHovered then
        state.progress = math.min(1, state.progress + dt * speed)
        state.x, state.y = anchorX, anchorY
    else
        state.progress = math.max(0, state.progress - dt * speed)
    end
    if state.progress <= 0.001 then return end

    -- 二次缓出：位移与透明度同步收束
    local p = 1 - (1 - state.progress) ^ 2

    surface.SetFont(font)
    local textW, textH = surface.GetTextSize(text)
    local boxW = textW + padX * 2
    local boxH = textH + padY * 2
    local bx = state.x + offsetX
    local by = state.y + offsetY + (1 - p) * 4
    -- 右侧或底部空间不足时翻到另一侧，避免气泡出屏
    if bx + boxW > ScrW() then bx = state.x - boxW - offsetX end
    if by + boxH > ScrH() then by = state.y - boxH - offsetY end

    draw.RoundedBox(radius, bx, by, boxW, boxH, Color(bgColor.r, bgColor.g, bgColor.b, math.floor(bgColor.a * p)))
    draw.SimpleText(text, font, bx + boxW / 2, by + boxH / 2, Color(255, 255, 255, math.floor(255 * p)), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

KARDS.CardEditor.Canvas.DrawTooltipBubble = DrawTooltipBubble

-- Apple pill chip 绘制（选中/未选中态的 RoundBox + 文字组合）
-- @param bx, by, w, h: 位置和尺寸
-- @param text: 显示文字（传 nil 则跳过文字绘制，由调用方自行绘制）
-- @param isSelected: 是否选中态
-- @param isHovered: 是否悬停
-- @param radii: 圆角半径（默认 APPLE_RADII.pill）
-- @param showHairline: 未选中时是否显示 hairline 边框（默认 true）
-- 背景图片材质缓存（2026-08-16）：路径 → { mat, iw, ih }（原始纹理宽高，供等比缩放）
local BgMatCache = {}
local function GetBgMatSize(path)
    local cached = BgMatCache[path]
    if cached == nil then
        local mat = Material(path, "noclamp smooth")
        local iw, ih = 1, 1
        local tex = mat and mat:GetTexture("$basetexture")
        if tex then
            iw = tex:GetMappingWidth() or 1
            ih = tex:GetMappingHeight() or 1
            if iw <= 0 then iw = 1 end
            if ih <= 0 then ih = 1 end
        end
        cached = { mat = mat, iw = iw, ih = ih }
        BgMatCache[path] = cached
    end
    return cached
end

-- 药片按钮（2026-08-16 增参）：bgMat = 背景图片路径字符串（nil 不绘制）；bgPad = 填充
-- 大小（图片距按钮边缘的内边距 px，缺省 6——保证 pill 圆角（半径=h/2）常见尺寸下
-- 图片四角落在圆角内，视觉上完全「只在按钮中渲染」）；bgZoom = 图片整体缩放倍数
-- （缺省 2）；sugImg = 建议图（悬停时上报给左下角建议板的图片，可单独配置，缺省
-- 用 bgMat）。图片**保持原始宽高比**，整体缩放值 = min(可用宽/图宽, 可用高/图高)
-- × bgZoom（可用 = 按钮内缩 bgPad 后的区域），以按钮中心居中放置；图片上叠加半透明
-- 黑色矩形叠层压暗，文字绘制于最上层。
local function DrawApplePillChip(bx, by, w, h, text, isSelected, isHovered, radii, showHairline, bgMat, bgPad, bgZoom, sugImg)
    radii = radii or APPLE_RADII.pill
    if showHairline == nil then showHairline = true end

    -- 悬停：上报建议图给左下角建议板（sugImg 单独配置优先，否则用按钮图 bgMat；
    -- 无图按钮悬停时不更新，与 SuggestionText 的遗留行为一致）
    if isHovered then
        KARDS.CardEditor.Canvas.SuggestionImage = sugImg or bgMat
    end

    if isSelected then
        draw.RoundedBox(radii, bx, by, w, h, isHovered and APPLE_BLUE_HOVER or APPLE_BLUE)
    else
        if showHairline then
            draw.RoundedBox(radii, bx - 1, by - 1, w + 2, h + 2, APPLE_HAIRLINE)
        end
        draw.RoundedBox(radii, bx, by, w, h, isHovered and APPLE_DARK_HOVER or APPLE_PARCHMENT)
    end

    if bgMat then
        local px = bgPad or 6
        local bg = GetBgMatSize(bgMat)
        local availW = w - px * 2
        local availH = h - px * 2
        local s = math.min(availW / bg.iw, availH / bg.ih) * (bgZoom or 2)
        local dw = bg.iw * s
        local dh = bg.ih * s
        local dx = bx + (w - dw) / 2
        local dy = by + (h - dh) / 2
        -- 裁剪到按钮矩形：图片超出按钮的部分不渲染（2026-08-16，放大 2 倍后
        -- dw/dh 会超出按钮，仅保留按钮范围内的图片与叠层）
        render.SetScissorRect(bx, by, bx + w, by + h, true)
        surface.SetMaterial(bg.mat)
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRect(dx, dy, dw, dh)
        -- 半透明黑色矩形叠层（2026-08-16）：覆盖图片区域压暗，突出上层文字
        surface.SetDrawColor(0, 0, 0, 90)
        surface.DrawRect(dx, dy, dw, dh)
        render.SetScissorRect(0, 0, 0, 0, false)
    end

    if text then
        local textColor = isSelected and APPLE_TEXT_ON_BLUE or APPLE_INK
        draw.SimpleText(text, "SourceHan_Heavy_14", bx + w / 2, by + h / 2, textColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

-- ====================================================================
-- 不稳定警告标识（红色三角 + 感叹号，标题右侧复用）
-- 2026-10-05：图标在调用处即时绘制；悬停提示写入待绘状态，
-- 由 DrawCardAppearanceEditor 在页面内容全部绘制完成后统一绘制，保证最高层不被遮挡。
-- 顶点必须顺时针（顶点 → 右下 → 左下），逆时针会被 surface.DrawPoly 背面剔除而不可见。
-- ====================================================================
local UNSTABLE_WARN_TEXT = T("editor.appearance.unstable_warning")
local UNSTABLE_WARN_SIZE = 24
-- 上一帧的警告图标锚点，供气泡淡出阶段继续绘制
local UnstableWarnAnchor = nil

function KARDS.CardEditor.Canvas.DrawUnstableWarnIcon(x, y, mx, my)
    local size = UNSTABLE_WARN_SIZE
    local hov = IsMouseIn(mx, my, x, y, size, size)
    local triVerts = {
        { x = x + size / 2, y = y + 2 },
        { x = x + size - 2, y = y + size - 2 },
        { x = x + 2, y = y + size - 2 },
    }
    draw.NoTexture()
    surface.SetDrawColor(210, 45, 45, 255)
    surface.DrawPoly(triVerts)
    draw.SimpleText("!", "SourceHan_Heavy_16", x + size / 2, y + size / 2 + 1, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if hov then
        KARDS.CardEditor.Canvas.SuggestionText = UNSTABLE_WARN_TEXT
        KARDS.CardEditor.Canvas._UnstableWarnTooltip = { x = x, y = y }
    end
    return hov
end

-- 在标题文本右侧放置警告标识（按标题字号测量宽度）
function KARDS.CardEditor.Canvas.DrawUnstableWarnAfterTitle(titleX, titleY, titleText, font, mx, my)
    surface.SetFont(font or "SourceHan_Heavy_16")
    local w = surface.GetTextSize(titleText)
    return KARDS.CardEditor.Canvas.DrawUnstableWarnIcon(titleX + w + 10, titleY, mx, my)
end

-- 绘制本帧待处理的不稳定警告提示（页面内容之后调用以保证最高层），随后清空状态
function KARDS.CardEditor.Canvas.DrawPendingUnstableWarnTooltip()
    local t = KARDS.CardEditor.Canvas._UnstableWarnTooltip
    KARDS.CardEditor.Canvas._UnstableWarnTooltip = nil
    if t then
        UnstableWarnAnchor = { x = t.x, y = t.y }
    end
    -- 未悬停时保留上一帧锚点继续淡出，避免气泡瞬间消失
    if not UnstableWarnAnchor then return end
    DrawTooltipBubble("unstable_warn", UnstableWarnAnchor.x + UNSTABLE_WARN_SIZE, UnstableWarnAnchor.y,
        UNSTABLE_WARN_TEXT, t ~= nil,
        { font = "SourceHan_Heavy_16", offsetX = 6, offsetY = -4, padX = 8, padY = 7 })
end

-- 单位类型规则（readme 7.3）：悬停或点击卡牌类型 chip 时写入 SuggestionText
local UNIT_TYPE_RULES = {
    infantry  = T("editor.appearance.rule_infantry"),
    tank      = T("editor.appearance.rule_tank"),
    artillery = T("editor.appearance.rule_artillery"),
    fighter   = T("editor.appearance.rule_fighter"),
    bomber    = T("editor.appearance.rule_bomber"),
}

function DrawTypeEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    local anchorX = trX + 15
    local anchorY = trY + 15
    local colGap = 12
    -- 四列布局：卡牌类型、规模、特效（更窄）、闪卡+子类型
    local usable = trW - 30 - colGap * 4  -- 额外一个 colGap 用于特效与闪卡之间
    local effColW = math.max(70, math.floor(usable * 0.19))     -- 特效 ~19%
    local newColW = math.max(70, math.floor(usable * 0.20))      -- 闪卡+子类型 ~20%
    local otherColW = math.floor((usable - effColW - newColW) / 2)

    -- 判断单位模式
    local isUnit = app.cardType == "infantry" or app.cardType == "tank" or app.cardType == "artillery" or app.cardType == "fighter" or app.cardType == "bomber"

    -- ===== 第一层子锚点 1: 卡牌类型（Apple pill chip 竖向排列） =====
    local leftX = anchorX
    draw.SimpleText(T("editor.appearance.card_type"), "SourceHan_Heavy_16", leftX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local typeNames = {T("editor.appearance.infantry"), T("editor.appearance.tank"), T("editor.appearance.artillery"), T("editor.appearance.fighter"), T("editor.appearance.bomber")}
    local typeIds = {"infantry", "tank", "artillery", "fighter", "bomber"}
    local chipH = 28
    local chipGapY = 8

    for i, name in ipairs(typeNames) do
        local optY = anchorY + 22 + (i - 1) * (chipH + chipGapY)
        local isSelected = app.cardType == typeIds[i]
        surface.SetFont("SourceHan_Heavy_14")
        local textW = surface.GetTextSize(name)
        local chipW = textW + 24
        local isHov = IsMouseIn(mx, my, leftX, optY, chipW, chipH)

        -- Apple pill chip 风格（2026-08-16：单位类型图标，materials/kards/icons/cardtype_*.png）
        DrawApplePillChip(leftX, optY, chipW, chipH, name, isSelected, isHov, APPLE_RADII.pill, true,
            "materials/kards/icons/cardtype_" .. typeIds[i] .. ".png")

        -- 点击检测
        if isLeftPressed and isHov and isUnit then
            app.cardType = typeIds[i]
            app.veteranAppearance.cardType = typeIds[i]
            -- 单位类型变更时重新按（单位类型 × 规模）分配部署/攻击音效
            KARDS.CardSounds.AutoAssignDeploySound(app)
            KARDS.CardSounds.AutoAssignAttackSound(app)
            KARDS.CardEditor.Canvas.SuggestionText = UNIT_TYPE_RULES[typeIds[i]] or (T("editor.appearance.current_card_type_prefix") .. name)
        end

        -- 悬停时把该单位类型规则写入 SuggestionText（readme 7.3）
        if isHov and not isLeftPressed then
            KARDS.CardEditor.Canvas.SuggestionText = UNIT_TYPE_RULES[typeIds[i]] or (T("editor.appearance.current_card_type_prefix") .. name)
        end
    end

    -- 非单位模式：卡牌类型区域灰色覆盖不可选
    if not isUnit then
        local overlayX = leftX
        local overlayY = anchorY + 22
        local overlayH = 5 * (chipH + chipGapY) - chipGapY
        local overlayW = otherColW
        draw.RoundedBox(APPLE_RADII.sm, overlayX, overlayY, overlayW, overlayH, Color(200, 200, 205, 120))
        -- 锁定文字
        draw.SimpleText(T("editor.appearance.type_locked"), "SourceHan_Heavy_14", overlayX + overlayW / 2, overlayY + overlayH / 2, Color(100, 100, 110, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- ===== 第一层子锚点 2: 规模（Apple pill chip 竖向排列） =====
    local midX = anchorX + otherColW + colGap
    draw.SimpleText(T("editor.appearance.scale"), "SourceHan_Heavy_16", midX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 提示标 "?"（气泡由统一组件绘制，带淡入上浮与淡出动画）
    local tooltipX = midX + 36
    local tooltipY = anchorY
    local ttSize = 16
    local isTooltipHovered = IsMouseIn(mx, my, tooltipX, tooltipY, ttSize, ttSize)
    draw.RoundedBox(8, tooltipX, tooltipY, ttSize, ttSize, APPLE_BLUE_DARK)
    draw.SimpleText("?", "SourceHan_Heavy_14", tooltipX + ttSize / 2, tooltipY + ttSize / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    DrawTooltipBubble("scale_help", tooltipX + ttSize, tooltipY, T("editor.appearance.scale_tooltip"), isTooltipHovered,
        { offsetX = 4, offsetY = -6, dt = dt })

    -- Apple pill chip 竖向排列
    local scaleOptions = KARDS.CardEditor.Canvas.CardScaleOptions
    local chipW_scale = math.min(120, otherColW - 10)
    local chipH_scale = 28
    local chipGapY_scale = 8
    local selectedScale = KARDS.CardEditor.Canvas.SelectedCardScale

    for i, opt in ipairs(scaleOptions) do
        local bx = midX
        local by = anchorY + 22 + (i - 1) * (chipH_scale + chipGapY_scale)
        local isHov = IsMouseIn(mx, my, bx, by, chipW_scale, chipH_scale)
        local isSel = selectedScale == opt.id

        if isHov then
            KARDS.CardEditor.Canvas.SuggestionText = opt.desc
        end

        -- Apple pill chip 风格
        DrawApplePillChip(bx, by, chipW_scale, chipH_scale, opt.name, isSel, isHov, APPLE_RADII.pill, true)

        if isHov and isLeftPressed and isUnit then
            KARDS.CardEditor.Canvas.SelectedCardScale = opt.id
            app.cardScale = opt.id
            -- 选择规模时自动分配部署/攻击音效（按单位类型 × 规模；缺失文件会提示准备）
            KARDS.CardSounds.AutoAssignDeploySound(app)
            KARDS.CardSounds.AutoAssignAttackSound(app)
        end
    end

    -- 非单位模式：规模区域灰色覆盖不可选
    if not isUnit then
        local overlayX = midX
        local overlayY = anchorY + 22
        local overlayH = #scaleOptions * (chipH_scale + chipGapY_scale) - chipGapY_scale
        local overlayW = chipW_scale
        draw.RoundedBox(APPLE_RADII.sm, overlayX, overlayY, overlayW, overlayH, Color(200, 200, 205, 120))
        draw.SimpleText(T("editor.appearance.locked"), "SourceHan_Heavy_14", overlayX + overlayW / 2, overlayY + overlayH / 2, Color(100, 100, 110, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- ===== 第一层子锚点 3: 特效（文件管理器，更窄） =====
    local effX = anchorX + otherColW + colGap + otherColW + colGap
    draw.SimpleText(T("editor.appearance.effect"), "SourceHan_Heavy_16", effX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 不稳定警告标识（特效列，标题右侧；悬停提示由页面末尾统一绘制，2026-10-05）
    KARDS.CardEditor.Canvas.DrawUnstableWarnAfterTitle(effX, anchorY, T("editor.appearance.effect"), "SourceHan_Heavy_16", mx, my)

    -- 文件管理器
    local fmW = effColW
    local fmH = math.Clamp(trH - 50, 80, 200)
    KARDS.CardEditor.Canvas.DrawEffectFileManager(effX, anchorY + 22, fmW, fmH, mx, my, isLeftPressed, dt)

    if isWarnHovered then
        KARDS.CardEditor.Canvas.SuggestionText = T("editor.appearance.unstable_warning")
    end

    -- ===== 第一层子锚点 4: 闪卡 + 子类型 =====
    local newX = anchorX + otherColW + colGap + otherColW + colGap + effColW + colGap * 2
    local toggleW = math.min(newColW - 4, 44)
    local toggleH = toggleW  -- 1:1 方形开关

    -- 闪卡标题 + 开关按钮
    draw.SimpleText(T("editor.appearance.flash"), "SourceHan_Heavy_16", newX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local fc = KARDS.CardEditor.Canvas.FlashCardToggle
    -- 与 app.cardTemplate 同步（2026-10-04：此前开关只改 fc.isOn，从不写 app，开启不生效）
    if not fc.isPressed then
        fc.isOn = (app.cardTemplate == "flash")
    end
    local toggleX = newX
    local toggleY = anchorY + 22
    local toggleHov = IsMouseIn(mx, my, toggleX, toggleY, toggleW, toggleH)

    -- 按压检测（边缘触发）
    if not fc.lastLeft and isLeftPressed then
        fc.isPressed = toggleHov
    end

    -- 动画：按压时向右下滑动（键帽按下），松开时回弹至右上
    if fc.isPressed and toggleHov then
        fc.anim = math.max(0, fc.anim - dt * 6)
    else
        fc.anim = math.min(1, fc.anim + dt * 6)
        if fc.anim >= 1 then fc.isPressed = false end
    end

    -- 点击切换状态（松开时在范围内触发）
    if fc.lastLeft and not isLeftPressed and fc.isPressed and toggleHov then
        fc.isOn = not fc.isOn
        fc.isPressed = false
        -- 写回卡牌模板（2026-10-04）：开启闪卡 → app.cardTemplate = "flash"，关闭 → "card"。
        -- 该字段即卡牌预览卡面模板键的来源（TemplateKeyOf = cardTemplate .. "_" .. cardType）。
        -- 闪卡模板覆盖单位/指令/反制（见 ImagePaths.template）；总部无 flash_headquarter，排除。
        if app.cardType ~= "headquarter" then
            app.cardTemplate = fc.isOn and "flash" or "card"
        end
    end
    fc.lastLeft = isLeftPressed

    -- === Apple 风格方形开关（Apple palette 颜色） ===
    -- 底矩形（键帽底座）
    draw.RoundedBox(4, toggleX, toggleY, toggleW, toggleH, APPLE_PARCHMENT)

    -- 内按钮（键帽顶面）：固定大小，不缩放
    local btnSize = toggleW * 0.65
    local btnW = btnSize
    local btnH = btnSize

    -- 计算按钮位置：anim=1(松开)在右上，anim=0(按下)在左下，平滑滑动
    local pressProgress = 1 - fc.anim  -- 0=松开, 1=按下
    local startX = toggleX + toggleW - btnW   -- 右上 X
    local startY = toggleY                     -- 右上 Y
    local endX = toggleX                       -- 左下 X
    local endY = toggleY + toggleH - btnH      -- 左下 Y
    local btnX = startX + (endX - startX) * pressProgress
    local btnY = startY + (endY - startY) * pressProgress

    -- 绘制左侧梯形（暗色斜面）
    local leftVerts = {
        {x = toggleX, y = toggleY},                           -- 外左上
        {x = toggleX, y = toggleY + toggleH},                 -- 外左下
        {x = btnX, y = btnY + btnH},                          -- 内左下
        {x = btnX, y = btnY},                                 -- 内左上
    }
    surface.SetDrawColor(APPLE_HAIRLINE)
    draw.NoTexture()
    surface.DrawPoly(leftVerts)

    -- 绘制底侧梯形（亮色斜面）
    local bottomVerts = {
        {x = btnX, y = btnY + btnH},                          -- 内左下
        {x = toggleX, y = toggleY + toggleH},                 -- 外左下
        {x = toggleX + toggleW, y = toggleY + toggleH},       -- 外右下
        {x = btnX + btnW, y = btnY + btnH},                  -- 内右下
    }
    surface.SetDrawColor(APPLE_DIVIDER)
    draw.NoTexture()
    surface.DrawPoly(bottomVerts)

    -- 内按钮（键帽顶面）：Apple Blue 当开启，Ink 当关闭
    local innerColor = fc.isOn and APPLE_BLUE or APPLE_INK_MUTED80
    draw.RoundedBox(3, btnX, btnY, btnW, btnH, innerColor)

    -- 绘制叉号或勾号
    local pad = 4
    surface.SetDrawColor(APPLE_WHITE)
    if btnW > pad * 2 and btnH > pad * 2 then
        if fc.isOn then
            -- 勾号 ✓
            local lx, ly = btnX + pad, btnY + btnH * 0.58
            local cx2, cy2 = btnX + btnW * 0.38, btnY + btnH - pad
            local rx2, ry2 = btnX + btnW - pad, btnY + pad
            surface.DrawLine(lx, ly, cx2, cy2)
            surface.DrawLine(cx2, cy2, rx2, ry2)
        else
            -- 叉号 ✗
            surface.DrawLine(btnX + pad, btnY + pad, btnX + btnW - pad, btnY + btnH - pad)
            surface.DrawLine(btnX + btnW - pad, btnY + pad, btnX + pad, btnY + btnH - pad)
        end
    end

    -- 子类型标题
    local subtypeTitleY = toggleY + toggleH + 14
    draw.SimpleText(T("editor.appearance.subtype_selector"), "SourceHan_Heavy_16", newX, subtypeTitleY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    KARDS.CardEditor.Canvas.DrawUnstableWarnAfterTitle(newX, subtypeTitleY, T("editor.appearance.subtype_selector"), "SourceHan_Heavy_16", mx, my)

    -- 子类型选择器
    local subFMX = newX
    local subFMY = subtypeTitleY + 22
    local subFMW = newColW
    local subFMH = math.Clamp(trY + trH - subFMY - 15, 60, 160)
    KARDS.CardEditor.Canvas.DrawSubtypeSelector(subFMX, subFMY, subFMW, subFMH, mx, my, isLeftPressed, dt, app)
end

-- ================================================================
-- 属性编辑区（DrawAttrEditArea）
-- 子锚点排版：两列布局（攻击力 / 防御力），每列包含滑动进度条 + 输入框
-- ================================================================

-- 通用"标题 + 滑动进度条 + 输入框"组件
-- 参数:
--   x, y: 起始位置
--   colW: 列宽度
--   title: 标签文本
--   tipText: 提示文本（nil 表示不显示提示图标）
--   app: 外观数据表
--   fieldName: app 中的字段名（如 "attack", "defense"）
--   sliderState: 滑条状态表（含 displayMin/displayMax）
--   inputState: 输入框状态表（含 active/text/lastValidValue）
--   mx, my, isLeftPressed, dt: 鼠标/帧状态
local function DrawSliderWithInput(x, y, colW, title, tipText, app, fieldName, sliderState, inputState, mx, my, isLeftPressed, dt)
    -- 防御性初始化：确保外部传递的状态表不为 nil
    inputState = inputState or { active = false, text = "", lastValidValue = 0 }
    sliderState = sliderState or { isDragging = false, dragStartX = 0, dragValueAtStart = 0, displayMin = 0, displayMax = 10 }

    -- 标题
    draw.SimpleText(title, "SourceHan_Heavy_16", x, y, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 提示图标 "?"（仅 tipText 非空时绘制，气泡带淡入上浮与淡出动画）
    if tipText then
        local tooltipX = x + 56
        local tooltipY = y
        local ttSize = 16
        local isTooltipHovered = IsMouseIn(mx, my, tooltipX, tooltipY, ttSize, ttSize)
        draw.RoundedBox(8, tooltipX, tooltipY, ttSize, ttSize, APPLE_BLUE_DARK)
        draw.SimpleText("?", "SourceHan_Heavy_14", tooltipX + ttSize / 2, tooltipY + ttSize / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        DrawTooltipBubble("attr_help_" .. tostring(fieldName), tooltipX + ttSize, tooltipY, tipText, isTooltipHovered,
            { offsetX = 4, offsetY = -6, dt = dt })
    end

    -- 滑动进度条
    local sliderY = y + 26
    local sliderH = 36
    local sliderW = math.floor((colW - 50) / 2)
    local valRef = { app[fieldName] or 0 }
    local dMinRef = { sliderState.displayMin }
    local dMaxRef = { sliderState.displayMax }

    DrawSliderBar(x, sliderY, sliderW, sliderH, valRef, 0, nil, dMinRef, dMaxRef, sliderState, mx, my, isLeftPressed, dt)

    -- 回写滑条值（卡牌花费同步到老兵，其他属性独立编辑）
    local newVal = math.floor(valRef[1] + 0.5)
    if newVal ~= (app[fieldName] or 0) then
        app[fieldName] = newVal
        -- 卡牌花费始终与老兵保持一致（升为老兵时牌已上场）
        if fieldName == "cost" and app.veteranAppearance then
            app.veteranAppearance.cost = newVal
        end
    end
    sliderState.displayMin = dMinRef[1]
    sliderState.displayMax = dMaxRef[1]
    if inputState then
        inputState.lastValidValue = app[fieldName] or 0
    end

    -- 输入框（滑条右侧）
    local inputX = x + sliderW + 6
    local inputY = sliderY + (sliderH / 2) - 10
    local inputW = 36
    local inputH = 20
    local isHoverInput = IsMouseIn(mx, my, inputX, inputY, inputW, inputH)

    if inputState.active then
        draw.RoundedBox(3, inputX, inputY, inputW, inputH, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(inputX, inputY, inputW, inputH)
    else
        draw.RoundedBox(3, inputX, inputY, inputW, inputH, Color(40, 40, 40))
    end

    local displayText = inputState.active and inputState.text or tostring(app[fieldName] or 0)
    if displayText == "" then displayText = "0" end
    draw.SimpleText(displayText, "SourceHan_Heavy_16", inputX + inputW / 2, inputY + inputH / 2, Color(255, 230, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- 输入框交互（激活/失活/回退）
    if isLeftPressed and isHoverInput then
        inputState.active = true
        inputState.text = tostring(app[fieldName] or 0)
    elseif isLeftPressed and not isHoverInput then
        if inputState.active then
            local num = tonumber(inputState.text)
            if num == nil or num ~= math.floor(num) or num < 0 or num > 99 then
                inputState.text = tostring(inputState.lastValidValue)
                app[fieldName] = inputState.lastValidValue
            end
        end
        inputState.active = false
    end
end

-- 转换目标卡选择器（2026-09-26 缺口 J）
-- 位于老兵属性区第四行左列：点击按钮展开卡牌文件列表，选择本卡被转换效果作用后
-- 变成的目标卡；列表首项「（无）」表示不换卡。列表本体延后到 DrawAttrEditArea
-- 末尾绘制以覆盖底部条控件，本函数只负责标题/按钮绘制与交互，并返回列表绘制数据。
-- 返回: overlay(列表绘制数据表或 nil), blockStrip(是否应屏蔽底部条控件交互)
local function DrawConvertTargetSelector(x, y, colW, app, mx, my, isLeftPressed, bottomLimit)
    local C = KARDS.CardEditor.Canvas

    -- 标题
    draw.SimpleText(T("editor.appearance.convert_target_card"), "SourceHan_Heavy_16", x, y, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 按钮：显示当前目标卡文件名（空为「（无）」）
    local btnX, btnY, btnW, btnH = x, y + 26, colW, 32
    local btnHover = IsMouseIn(mx, my, btnX, btnY, btnW, btnH)
    draw.RoundedBox(APPLE_RADII.xs, btnX, btnY, btnW, btnH, btnHover and APPLE_DARK_HOVER or Color(40, 40, 40))
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawOutlinedRect(btnX, btnY, btnW, btnH)

    local value = app.convertTarget or ""
    local label = T("editor.appearance.none_paren")
    if value ~= "" then
        label = (KARDS.CardEditor.SaveSystem and KARDS.CardEditor.SaveSystem.UnescapeFileName)
            and KARDS.CardEditor.SaveSystem.UnescapeFileName(value) or value
    end
    draw.SimpleText(label, "SourceHan_Heavy_14", btnX + 8, btnY + btnH / 2, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

    -- 右侧展开指示箭头
    local arrowX = btnX + btnW - 12
    local arrowY = btnY + btnH / 2
    surface.SetDrawColor(150, 150, 150, 255)
    if C._convertTargetExpanded then
        surface.DrawLine(arrowX - 5, arrowY + 2, arrowX, arrowY - 2)
        surface.DrawLine(arrowX, arrowY - 2, arrowX + 5, arrowY + 2)
    else
        surface.DrawLine(arrowX - 5, arrowY - 2, arrowX, arrowY + 2)
        surface.DrawLine(arrowX, arrowY + 2, arrowX + 5, arrowY - 2)
    end
    surface.SetDrawColor(255, 255, 255, 255)

    -- 点击按钮：切换展开/收起；重新展开时刷新卡牌文件列表（缓存于 _convertTargetList）
    if isLeftPressed and btnHover then
        if C._convertTargetExpanded then
            C._convertTargetExpanded = false
        else
            C._convertTargetExpanded = true
            C._convertTargetList = (KARDS.CardEditor.SaveSystem and KARDS.CardEditor.SaveSystem.GetCardFiles)
                and KARDS.CardEditor.SaveSystem.GetCardFiles() or {}
            C._convertTargetScroll = 0
        end
    end

    if not C._convertTargetExpanded then return nil, false end

    -- 列表几何：按钮下方展开，限制最大高度，空间不足时收窄
    local list = C._convertTargetList or {}
    local itemCount = #list + 1 -- 首项为「（无）」
    local itemH = 22
    local listX, listW = btnX, btnW
    local listTop = btnY + btnH + 2
    local avail = math.max(itemH + 8, bottomLimit - listTop)
    local visible = math.max(1, math.floor((math.min(184, avail) - 8) / itemH))
    visible = math.min(visible, itemCount)
    local listH = visible * itemH + 8

    -- 滚动偏移钳制 + 滚轮滚动（复用 CreateMove 设置的滚轮标记，鼠标悬停列表时生效；
    -- 在此提前消费滚轮标记，避免被覆盖的底部条音效列表同时滚动）
    local maxScroll = math.max(0, itemCount - visible)
    C._convertTargetScroll = math.max(0, math.min(C._convertTargetScroll or 0, maxScroll))
    local listHover = IsMouseIn(mx, my, listX, listTop, listW, listH)
    if listHover then
        if C._wheelZoomIn then
            C._wheelZoomIn = false
            C._convertTargetScroll = math.max(0, C._convertTargetScroll - 1)
        elseif C._wheelZoomOut then
            C._wheelZoomOut = false
            C._convertTargetScroll = math.min(maxScroll, C._convertTargetScroll + 1)
        end
    end

    -- 点击列表项：首项置空字符串（不换卡），其余写入文件名并收起列表
    if isLeftPressed and listHover then
        for i = 1, visible do
            local idx = C._convertTargetScroll + i
            if idx > itemCount then break end
            local itemY = listTop + 4 + (i - 1) * itemH
            if IsMouseIn(mx, my, listX, itemY, listW, itemH) then
                app.convertTarget = (idx == 1) and "" or (list[idx - 1] or "")
                C._convertTargetExpanded = false
                break
            end
        end
    end

    return {
        x = listX, y = listTop, w = listW, h = listH,
        itemH = itemH, visible = visible, scroll = C._convertTargetScroll, list = list,
    }, listHover
end

function DrawAttrEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    local anchorX = trX + 15
    local anchorY = trY + 15
    local colGap = 12
    local usable = trW - 30
    local colW = math.floor((usable - colGap) / 2)
    local col1X = anchorX
    local col2X = anchorX + colW + colGap
    local rowH = 26 + 36 + 14 -- 每行高度（标题26 + 滑块36 + 间距14）

    -- 转换目标卡下拉列表绘制数据（延后到函数末尾绘制，以覆盖底部条控件；2026-09-26 缺口 J）
    local convOverlay, convBlockStrip = nil, false

    -- 总部模式：属性仅防御力（默认 20），隐藏攻击/设置花费/行动花费/老兵属性
    if app.cardType == "headquarter" then
        draw.SimpleText(T("editor.appearance.headquarters_defense"), "SourceHan_Heavy_16", anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        DrawSliderWithInput(anchorX, anchorY + 30, usable, T("editor.appearance.defense"), T("editor.appearance.headquarters_defense_tip"), app, "defense",
            KARDS.CardEditor.Canvas._defenseSliderState, KARDS.CardEditor.Canvas._defenseInputState,
            mx, my, isLeftPressed, dt)
        return
    end

    -- 指令/反制模式：无攻击力/防御力/行动花费（指令与反制卡不参与攻防），属性区仅保留设置花费
    -- 同时清除从单位卡切换类型时可能残留的攻击/防御/行动花费输入框状态，防止幽灵输入框写入无效字段
    local isUnit = app.cardType == "infantry" or app.cardType == "tank" or app.cardType == "artillery" or app.cardType == "fighter" or app.cardType == "bomber"
    if app.cardType == "command" or app.cardType == "counter_command" then
        for _, key in ipairs({ "_attrInputState", "_defenseInputState", "_actionCostInputState" }) do
            local st = KARDS.CardEditor.Canvas[key]
            if st then st.active = false end
        end
    end

    if isUnit then
    -- 第一行：攻击力 | 防御力
    DrawSliderWithInput(col1X, anchorY, colW, T("editor.appearance.attack"), T("editor.appearance.attack_tip"), app, "attack",
        KARDS.CardEditor.Canvas._attackSliderState, KARDS.CardEditor.Canvas._attrInputState,
        mx, my, isLeftPressed, dt)
    DrawSliderWithInput(col2X, anchorY, colW, T("editor.appearance.defense"), nil, app, "defense",
        KARDS.CardEditor.Canvas._defenseSliderState, KARDS.CardEditor.Canvas._defenseInputState,
        mx, my, isLeftPressed, dt)

    -- 第二行：设置花费 | 行动花费
    local costRowY = anchorY + rowH
    DrawSliderWithInput(col1X, costRowY, colW, T("editor.appearance.cost"), nil, app, "cost",
        KARDS.CardEditor.Canvas._costSliderState, KARDS.CardEditor.Canvas._costInputState,
        mx, my, isLeftPressed, dt)
    DrawSliderWithInput(col2X, costRowY, colW, T("editor.appearance.action_cost"), nil, app, "actionCost",
        KARDS.CardEditor.Canvas._actionCostSliderState, KARDS.CardEditor.Canvas._actionCostInputState,
        mx, my, isLeftPressed, dt)
    else
        -- 指令/反制模式：仅卡牌花费
        draw.SimpleText(T("editor.appearance.card_cost"), "SourceHan_Heavy_16", anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        DrawSliderWithInput(anchorX, anchorY + 30, usable, T("editor.appearance.cost"), T("editor.appearance.command_counter_cost_only"), app, "cost",
            KARDS.CardEditor.Canvas._costSliderState, KARDS.CardEditor.Canvas._costInputState,
            mx, my, isLeftPressed, dt)
    end

    -- 底部条（效果类型多选 + 各类型音效选择器）与老兵属性区（2026-08-13）：
    -- 老兵属性区可折叠——点击"— 老兵属性 —"分界线切换展开/折叠（app.vetExpanded，
    -- 默认折叠）。展开（单位+可升为老兵词条+用户点击）时保持原样式：老兵滑块在
    -- 底部条上方；折叠（含无词条——也算关闭）时底部条上移扩大、覆盖老兵滑块区域，
    -- 仅保留灰色分界线。
    local isVet = isUnit and table.HasValue(app.keywords or {}, "can_elevate_to_veteran")
    local vetExpanded = isVet and app.vetExpanded -- 有词条且用户展开；无词条恒为折叠
    local vetTitleH = 28       -- 标题行高
    local vetSectionH = vetTitleH + 10 + rowH * 2 -- 标题 + 间距 + 两行滑块
    local barBottom = trY + trH - 15
    local baseStripH = 172
    local openStripY = barBottom - baseStripH
    -- 分界线固定于老兵区顶（底部条贴底 172 时的上方）；单位卡均显示（灰色=折叠/无词条）
    local sepY = isUnit and (openStripY - 20 - vetSectionH) or nil
    local StripY, StripH
    if vetExpanded then
        -- 展开：底部条贴底保持原样式，老兵滑块在分界线下方
        StripY, StripH = openStripY, baseStripH
    elseif isUnit then
        -- 折叠（未展开或无可升为老兵词条）：底部条上移覆盖老兵滑块区，仅保留分界线
        StripY = sepY + vetTitleH + 6
        StripH = barBottom - StripY
    else
        -- 指令/反制卡：无老兵概念，底部条贴底原样式
        StripY, StripH = openStripY, baseStripH
    end
    -- 极限保护：折叠上移不越出编辑区顶（极小窗口兜底；正常编辑区高度下不触发）
    StripY = math.max(StripY, trY + 20)
    StripH = math.max(60, barBottom - StripY)

    -- 分界线 "— 老兵属性 —"（单位卡专属；点击切换展开/折叠，无词条时恒灰不可切换）
    if sepY then
        local sepHov = IsMouseIn(mx, my, anchorX, sepY, usable, vetTitleH)
        surface.SetFont("SourceHan_Heavy_18")
        local titleW = surface.GetTextSize(T("editor.appearance.veteran_attributes_separator"))
        local lineY = sepY + 14
        local lineLeft = anchorX
        local lineRight = anchorX + usable
        local sepColor = vetExpanded and APPLE_BLUE or Color(130, 130, 140)
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawLine(lineLeft, lineY, math.floor((anchorX + usable / 2) - titleW / 2 - 8), lineY)
        surface.DrawLine(math.ceil((anchorX + usable / 2) + titleW / 2 + 8), lineY, lineRight, lineY)
        draw.SimpleText(T("editor.appearance.veteran_attributes_separator"), "SourceHan_Heavy_18", anchorX + usable / 2, sepY, sepColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        if isLeftPressed and sepHov and isVet then
            app.vetExpanded = not app.vetExpanded
        end
    end

    -- 老兵属性滑块（仅展开且有词条时绘制，保持原样式）
    if vetExpanded then
        local vet = app.veteranAppearance
        if not vet then
            vet = {}
            app.veteranAppearance = vet
        end

        -- 第三行：老兵攻击力 | 老兵防御力
        local vetRow1Y = sepY + vetTitleH + 6
        DrawSliderWithInput(col1X, vetRow1Y, colW, T("editor.appearance.veteran_attack"), nil, vet, "attack",
            KARDS.CardEditor.Canvas._vetAttackSliderState, KARDS.CardEditor.Canvas._vetAttrInputState,
            mx, my, isLeftPressed, dt)
        DrawSliderWithInput(col2X, vetRow1Y, colW, T("editor.appearance.veteran_defense"), nil, vet, "defense",
            KARDS.CardEditor.Canvas._vetDefenseSliderState, KARDS.CardEditor.Canvas._vetDefenseInputState,
            mx, my, isLeftPressed, dt)

        -- 第四行：老兵行动花费（左列空置）
        local vetRow2Y = vetRow1Y + rowH
        DrawSliderWithInput(col2X, vetRow2Y, colW, T("editor.appearance.veteran_action_cost"), nil, vet, "actionCost",
            KARDS.CardEditor.Canvas._vetActionCostSliderState, KARDS.CardEditor.Canvas._vetActionCostInputState,
            mx, my, isLeftPressed, dt)

        -- 第四行左列：转换目标卡选择器（返回列表绘制数据与底部条交互屏蔽标记）
        convOverlay, convBlockStrip = DrawConvertTargetSelector(col1X, vetRow2Y, colW, app, mx, my, isLeftPressed, barBottom)
    end

    -- 老兵区收起时复位转换目标卡列表展开状态（2026-09-26 缺口 J）
    if not vetExpanded then
        KARDS.CardEditor.Canvas._convertTargetExpanded = false
    end

    -- ===== 底部条：效果类型多选（左下角）+ 各类型音效文件选择器（右侧） =====
    -- 转换目标卡下拉列表覆盖底部条时，本帧屏蔽底部条控件的点击，防止点击穿透
    local stripLeftPressed = isLeftPressed and not convBlockStrip
    -- 效果类型：主动效果 / 被动效果（长方形块状多选，非胶囊；可同时选中两者）
    app.effectTypes = app.effectTypes or {}
    draw.SimpleText(T("editor.appearance.effect_type"), "SourceHan_Heavy_16", anchorX, StripY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    local chipW, chipH, chipGap = 78, 28, 8
    local chipY = StripY + 30
    local effectOptions = {
        { id = "active", name = T("editor.appearance.active_effect") },
        { id = "passive", name = T("editor.appearance.passive_effect") },
    }
    for i, opt in ipairs(effectOptions) do
        local cxp = anchorX + (i - 1) * (chipW + chipGap)
        local selected = table.HasValue(app.effectTypes, opt.id)
        local hover = IsMouseIn(mx, my, cxp, chipY, chipW, chipH)
        DrawApplePillChip(cxp, chipY, chipW, chipH, opt.name, selected, hover, 6, true,
            "materials/kards/effects/3d2d/" .. opt.id .. "_effect.png") -- 圆角6：长方形外貌；2026-08-16 效果类型图标
        if stripLeftPressed and hover then
            if selected then
                for j = #app.effectTypes, 1, -1 do
                    if app.effectTypes[j] == opt.id then table.remove(app.effectTypes, j) end
                end
            else
                table.insert(app.effectTypes, opt.id)
            end
        end
    end

    -- 分隔竖线
    local sepX = anchorX + 158
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawLine(sepX, StripY, sepX, StripY + StripH)

    -- 右侧：音效文件选择器（按卡牌类型给事件槽位：单位 部署/攻击/阵亡；指令 打出；反制 激活时/触发）
    local sndX0 = anchorX + 170
    local sndAvail = (anchorX + usable) - sndX0
    local slots = {}
    if app.cardType == "command" then
        slots = { { key = "play" } }
    elseif app.cardType == "counter_command" then
        slots = { { key = "activate" }, { key = "trigger" } }
    else
        slots = { { key = "deploy" }, { key = "attack" }, { key = "death" } }
    end
    local boxGap = 10
    local boxW = math.floor((sndAvail - boxGap * (#slots - 1)) / #slots)
    for i, slot in ipairs(slots) do
        local bx = sndX0 + (i - 1) * (boxW + boxGap)
        KARDS.CardEditor.Canvas.DrawSoundFileManager(bx, StripY, boxW, StripH, mx, my, stripLeftPressed, dt, slot.key, app)
    end

    -- ===== 转换目标卡下拉列表（最后绘制以覆盖底部条控件；2026-09-26 缺口 J） =====
    if convOverlay then
        local ox, oy, ow, oh = convOverlay.x, convOverlay.y, convOverlay.w, convOverlay.h
        local itemH = convOverlay.itemH
        local visible = convOverlay.visible
        local scroll = convOverlay.scroll
        local list = convOverlay.list or {}
        local currentValue = app.convertTarget or ""
        draw.RoundedBox(APPLE_RADII.xs, ox, oy, ow, oh, Color(35, 35, 38))
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawOutlinedRect(ox, oy, ow, oh)
        for i = 1, visible do
            local idx = scroll + i
            local itemY = oy + 4 + (i - 1) * itemH
            local value, label
            if idx == 1 then
                value, label = "", T("editor.appearance.none_paren")
            else
                value = list[idx - 1]
                if not value then break end
                label = (KARDS.CardEditor.SaveSystem and KARDS.CardEditor.SaveSystem.UnescapeFileName)
                    and KARDS.CardEditor.SaveSystem.UnescapeFileName(value) or value
            end
            local selected = (currentValue == value)
            if selected then
                draw.RoundedBox(3, ox + 2, itemY, ow - 4, itemH, APPLE_BLUE)
            elseif IsMouseIn(mx, my, ox, itemY, ow, itemH) then
                draw.RoundedBox(3, ox + 2, itemY, ow - 4, itemH, Color(60, 60, 64))
            end
            draw.SimpleText(label, "SourceHan_Heavy_14", ox + 8, itemY + itemH / 2,
                selected and APPLE_TEXT_ON_BLUE or APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end
end

-- ===== 国家编辑区（Apple pill chip） =====
function DrawCountryEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    local anchorX = trX + 15
    local anchorY = trY + 15
    draw.SimpleText(T("editor.appearance.card_country"), "SourceHan_Heavy_16", anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local countries = {
        { id = "none",   name = T("editor.appearance.country_none"),    desc = T("editor.appearance.country_none_desc") },
        { id = "sandbox",name = T("editor.appearance.sandbox"),  desc = T("editor.appearance.sandbox_desc") },
        { id = "uk",     name = T("editor.appearance.country_uk"),  desc = T("editor.appearance.country_uk_desc") },
        { id = "usa",    name = T("editor.appearance.country_usa"),  desc = T("editor.appearance.country_usa_desc") },
        { id = "ussr",   name = T("editor.appearance.country_ussr"),  desc = T("editor.appearance.country_ussr_desc") },
        { id = "japan",  name = T("editor.appearance.country_japan"),  desc = T("editor.appearance.country_japan_desc") },
        { id = "germany",name = T("editor.appearance.country_germany"),  desc = T("editor.appearance.country_germany_desc") },
    }

    local chipW = math.min(120, trW - 30)
    local chipH = 28
    local chipGap = 8
    local startY = anchorY + 26
    local selected = KARDS.CardEditor.Canvas.SelectedCountry

    for i, c in ipairs(countries) do
        local bx = anchorX
        local by = startY + (i - 1) * (chipH + chipGap)
        local isHov = IsMouseIn(mx, my, bx, by, chipW, chipH)
        local isSel = selected == c.id

        if isHov then
            KARDS.CardEditor.Canvas.SuggestionText = c.desc
        end

        -- Apple pill chip 风格（2026-08-16：国家图标，materials/kards/icons/country_*.png；
        -- "无"无图标；bgZoom = 4 比全局默认 ×2 再放大一倍）
        local countryIcon = c.id ~= "none" and ("materials/kards/icons/country_" .. c.id .. ".png") or nil
        DrawApplePillChip(bx, by, chipW, chipH, c.name, isSel, isHov, APPLE_RADII.pill, true, countryIcon, nil, 4)

        if isHov and isLeftPressed then
            KARDS.CardEditor.Canvas.SelectCountry(c.id)
        end
    end
end

-- 检查当前卡牌是否启用了老兵模式（用于描述/词条分割）
local function IsVeteranMode(app)
    local isUnit = app.cardType == "infantry" or app.cardType == "tank" or app.cardType == "artillery" or app.cardType == "fighter" or app.cardType == "bomber"
    return isUnit and table.HasValue(app.keywords or {}, "can_elevate_to_veteran")
end

-- ===== 词条编辑区 =====
-- 使用全局 Apple 设计规范配色（已定义在文件顶部）

-- 在词条编辑区内绘制一组关键词 pill chip（用于左右两侧复用）
local function DrawKeywordChipGrid(anchorX, anchorY, chipW, cols, keywordsList, targetKeywords, targetKeywordValues, mx, my, isLeftPressed)
    local chipGap = 8
    local chipH = 36
    local chipR = math.floor(chipH / 2)
    local rows = math.ceil(#keywordsList / cols)

    for i, kw in ipairs(keywordsList) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local bx = anchorX + col * (chipW + chipGap)
        local by = anchorY + row * (chipH + chipGap)

        -- 检查是否已选中
        local isSel = false
        for _, kid in ipairs(targetKeywords) do
            if kid == kw.id then isSel = true; break end
        end

        local isHov = IsMouseIn(mx, my, bx, by, chipW, chipH)
        local kwDesc = KARDS.CardEditor.Data.GetKeywordDescription(kw.id)
        if isHov then
            KARDS.CardEditor.Canvas.SuggestionText = kwDesc
        end

        DrawApplePillChip(bx, by, chipW, chipH, nil, isSel, isHov, chipR, true, kw.bg, kw.bgPad)

        local handledByNum = false
        -- 钳击输入框内点击标志（2026-10-04）：避免点击输入框时又触发下方的词条勾选切换而取消钳击
        local handledByInput = false
        if kw.hasNum and isSel then
            local numVal = (targetKeywordValues and targetKeywordValues[kw.numKey]) or 0
            local numW = 68
            local nameW = chipW - numW
            local midY = by + chipH / 2

            draw.SimpleText(kw.name, "SourceHan_Heavy_14", bx + 12, midY, APPLE_TEXT_ON_BLUE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

            local numX = bx + nameW
            local third = math.floor(numW / 3)
            local decX = numX
            local valX = numX + third
            local incX = numX + third * 2

            local decHov = IsMouseIn(mx, my, decX, by, third, chipH)
            local incHov = IsMouseIn(mx, my, incX, by, third, chipH)

            surface.SetDrawColor(APPLE_WHITE.r, APPLE_WHITE.g, APPLE_WHITE.b, 50)
            surface.DrawLine(numX + 1, by + 6, numX + 1, by + chipH - 6)

            draw.SimpleText("−", "SourceHan_Heavy_16", decX + third / 2 + 1, midY,
                decHov and APPLE_TEXT_ON_BLUE or Color(255, 255, 255, 180),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.SimpleText(tostring(numVal), "SourceHan_Heavy_14", valX + third / 2, midY,
                APPLE_TEXT_ON_BLUE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.SimpleText("+", "SourceHan_Heavy_16", incX + third / 2, midY,
                incHov and APPLE_TEXT_ON_BLUE or Color(255, 255, 255, 180),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

            if isLeftPressed then
                if decHov then
                    if numVal <= 1 then
                        local newKeys = {}
                        for _, kid in ipairs(targetKeywords) do
                            if kid ~= kw.id then table.insert(newKeys, kid) end
                        end
                        for i = #targetKeywords, 1, -1 do targetKeywords[i] = nil end
                        for _, v in ipairs(newKeys) do table.insert(targetKeywords, v) end
                    else
                        targetKeywordValues[kw.numKey] = numVal - 1
                    end
                    handledByNum = true
                elseif incHov then
                    local newVal = math.min(kw.maxVal, numVal + 1)
                    targetKeywordValues[kw.numKey] = newVal
                    handledByNum = true
                end
            end
        else
            local textColor = isSel and APPLE_TEXT_ON_BLUE or APPLE_INK
            if kw.id == "pincer" and isSel then
                -- 钳击：左侧显示标签，右侧绘制输入框
                local inputW = math.floor(chipW * 0.55)
                local labelW = chipW - inputW
                local midY = by + chipH / 2

                -- 标签文字
                draw.SimpleText(T("editor.appearance.pincer"), "SourceHan_Heavy_14", bx + 12, midY, APPLE_TEXT_ON_BLUE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

                -- 输入框坐标
                local inputX = bx + labelW
                local inputY = by + 3
                local inputH = chipH - 6

                -- 更新状态中的坐标（供DTextEntry生命周期和点击检测使用）
                KARDS.CardEditor.Canvas.PincerInputState.x = inputX
                KARDS.CardEditor.Canvas.PincerInputState.y = inputY
                KARDS.CardEditor.Canvas.PincerInputState.w = inputW
                KARDS.CardEditor.Canvas.PincerInputState.h = inputH

                local isActive = KARDS.CardEditor.Canvas.PincerInputState.active
                local inputText = KARDS.CardEditor.Canvas.PincerInputState.text

                -- 背景
                if isActive then
                    draw.RoundedBox(3, inputX, inputY, inputW, inputH, Color(60, 60, 70))
                    surface.SetDrawColor(Color(100, 150, 255, 200))
                    surface.DrawOutlinedRect(inputX, inputY, inputW, inputH)
                else
                    draw.RoundedBox(3, inputX, inputY, inputW, inputH, Color(40, 40, 40))
                end

                -- 文本/占位
                if inputText == "" then
                    draw.SimpleText(T("editor.appearance.enter_target"), "SourceHan_Heavy_12", inputX + 4, midY,
                        isActive and Color(180, 180, 180) or Color(120, 120, 120),
                        TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                else
                    draw.SimpleText(inputText, "SourceHan_Heavy_12", inputX + 4, midY,
                        Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                end

                -- 光标
                if isActive and math.floor(SysTime() * 2) % 2 == 0 then
                    surface.SetFont("SourceHan_Heavy_12")
                    local cursorX = inputX + 4 + surface.GetTextSize(inputText)
                    surface.SetDrawColor(Color(200, 200, 200))
                    surface.DrawLine(cursorX, inputY + 2, cursorX, inputY + inputH - 2)
                end

                -- 点击检测（激活输入框）
                if isLeftPressed then
                    if mx >= inputX and mx <= inputX + inputW and my >= inputY and my <= inputY + inputH then
                        KARDS.CardEditor.Canvas.PincerInputState.active = true
                        handledByInput = true
                    elseif not (mx >= bx and mx <= bx + chipW and my >= by and my <= by + chipH) then
                        -- 点击输入框外才失活
                        KARDS.CardEditor.Canvas.PincerInputState.active = false
                    end
                end
            else
                draw.SimpleText(kw.name, "SourceHan_Heavy_14", bx + chipW / 2, by + chipH / 2,
                    textColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end

        if isHov and isLeftPressed and not handledByNum and not handledByInput then
            if isSel then
                local newKeys = {}
                for _, kid in ipairs(targetKeywords) do
                    if kid ~= kw.id then table.insert(newKeys, kid) end
                end
                for i = #targetKeywords, 1, -1 do targetKeywords[i] = nil end
                for _, v in ipairs(newKeys) do table.insert(targetKeywords, v) end
            else
                table.insert(targetKeywords, kw.id)
                if kw.hasNum then
                    if not targetKeywordValues then
                        targetKeywordValues = {}
                        -- 如果是老兵模式，需要写回 app.veteranAppearance.keywordValues
                    end
                    if not targetKeywordValues[kw.numKey] or targetKeywordValues[kw.numKey] < 1 then
                        targetKeywordValues[kw.numKey] = 1
                    end
                end
            end
        end
    end

    local totalH = rows * (chipH + chipGap) - chipGap
    return totalH
end

function DrawKeywordsEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    local anchorX = trX + 15
    local anchorY = trY + 15
    local isVet = IsVeteranMode(app)
    local chipGap = 8
    local chipH = 36

    -- 词条勾选后刷新已打开的 INE 效果编辑器开始点（钳击/钳击对象/升级）：
    -- 修复"勾选钳击/可升为老兵时开始点不出现"——效果编辑器已存在时从不刷新。
    -- 仅监听普通词条（app.keywords），与 CreateStartNodesForEditor 读取来源一致；
    -- 老兵面板词条（vetApp.keywords）不驱动开始点，不在此监听。
    do
        local kwSig = table.concat(app.keywords or {}, ",")
        local lastSig = KARDS.CardEditor.Canvas._keywordSigForStartNodes
        if kwSig ~= lastSig then
            KARDS.CardEditor.Canvas._keywordSigForStartNodes = kwSig
            local ineM = KARDS.CardEditor.IndependentNodeEditor
            local effectEd = ineM and ineM.Editors["card_effect_editor"]
            if effectEd then
                ineM:RefreshKeywordStartNodes(effectEd)
            end
        end
    end

    -- 同步钳击输入框文本
    if KARDS.CardEditor.Canvas.PincerInputState then
        KARDS.CardEditor.Canvas.PincerInputState.text = app.pincerValue or ""
    end

    local allKeywords = {
        { id = "blitz",       name = T("editor.appearance.keyword_blitz"),     hasNum = false },
        { id = "impact",      name = T("editor.appearance.keyword_impact"),     hasNum = false, bg = "materials/kards/effects/3d2d/shock.png" },
        { id = "smoke",       name = T("editor.appearance.keyword_smoke"),     hasNum = false, bg = "materials/kards/effects/3d2d/smoke.png" },
        { id = "conceal",     name = T("editor.appearance.keyword_conceal"),     hasNum = false, bg = "materials/kards/effects/3d2d/stealth.png" },
        { id = "fight_hard",  name = T("editor.appearance.keyword_fight_hard"),     hasNum = false, bg = "materials/kards/effects/3d2d/frenzy.png" },
        { id = "guard",       name = T("editor.appearance.keyword_guard"),     hasNum = false, bg = "materials/kards/effects/3d2d/guard.png" },
        { id = "mountain",    name = T("editor.appearance.keyword_mountain"),     hasNum = false },
        { id = "death_plan",  name = T("editor.appearance.keyword_death_plan"),     hasNum = false, bg = "materials/kards/effects/3d2d/deathrattle.png" },
        { id = "ambush",      name = T("editor.appearance.keyword_ambush"),     hasNum = false, bg = "materials/kards/effects/3d2d/ambush.png" },
        { id = "mobilize",    name = T("editor.appearance.keyword_mobilize"),     hasNum = false, bg = "materials/kards/effects/3d2d/mobilize.png" },
        { id = "intel",       name = T("editor.appearance.keyword_intel"),     hasNum = true,  numKey = "intel",       maxVal = 9, bg = "materials/kards/effects/other/intel.png" },
        { id = "countdown",   name = T("editor.appearance.keyword_countdown"),   hasNum = true,  numKey = "countdown",   maxVal = 9, bg = "materials/kards/effects/3d2d/countdown.png" },
        { id = "heavy_armor", name = T("editor.appearance.keyword_heavy_armor"),     hasNum = true,  numKey = "heavy_armor", maxVal = 3, bg = "materials/kards/effects/3d2d/armor.png" },
        { id = "pincer",      name = T("editor.appearance.pincer"),     hasNum = false, bg = "materials/kards/effects/3d2d/pincer.png" },
        { id = "cooperation", name = T("editor.appearance.keyword_cooperation"),     hasNum = false },
        { id = "forecast",    name = T("editor.appearance.keyword_forecast"),     hasNum = false },
    }

    -- 非单位模式：只有词条可选 情报、协力、预报
    local isUnit = app.cardType == "infantry" or app.cardType == "tank" or app.cardType == "artillery" or app.cardType == "fighter" or app.cardType == "bomber"
    local activeKeywords = allKeywords
    if not isUnit then
        activeKeywords = {}
        local unitOnlyIds = { intel = true, cooperation = true, forecast = true }
        for _, kw in ipairs(allKeywords) do
            if unitOnlyIds[kw.id] then
                table.insert(activeKeywords, kw)
            end
        end
    end

    if isVet then
        -- 老兵模式：原内容左移，右侧放置老兵词条
        local halfW = math.floor((trW - 30 - 12) / 2) -- 12px 中间间距
        local cols = 3
        local chipW = math.max(70, math.floor((halfW - (cols - 1) * chipGap) / cols))
        local startY = anchorY + 26

        -- ===== 左侧：原卡牌词条 =====
        draw.SimpleText(T("editor.appearance.combat_keywords"), "SourceHan_Heavy_16", anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        local leftTotalH = DrawKeywordChipGrid(anchorX, startY, chipW, cols, activeKeywords, app.keywords, app.keywordValues, mx, my, isLeftPressed)

        -- 左侧特别词条
        local specialY = startY + leftTotalH + 16
        draw.SimpleText(T("editor.appearance.special_keywords"), "SourceHan_Heavy_14", anchorX, specialY, APPLE_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        KARDS.CardEditor.Canvas.DrawUnstableWarnAfterTitle(anchorX, specialY, T("editor.appearance.special_keywords"), "SourceHan_Heavy_14", mx, my)
        local specialKeywords = {
            { id = "exile",                  name = T("editor.appearance.keyword_exile"),        desc = T("editor.appearance.keyword_exile_desc") },
            { id = "can_elevate_to_veteran", name = T("editor.appearance.keyword_can_elevate"),  desc = T("editor.appearance.keyword_can_elevate_desc"), bg = "materials/kards/effects/3d2d/veteran.png" },
        }
        for i, skw in ipairs(specialKeywords) do
            local spW = math.max(80, math.floor((halfW - chipGap) / 2))
            local sbx = anchorX + (i - 1) * (spW + chipGap)
            local sby = specialY + 20
            local isSel = false
            for _, kid in ipairs(app.keywords) do
                if kid == skw.id then isSel = true; break end
            end
            local isHov = IsMouseIn(mx, my, sbx, sby, spW, chipH)
            if isHov then KARDS.CardEditor.Canvas.SuggestionText = skw.desc end
            DrawApplePillChip(sbx, sby, spW, chipH, skw.name, isSel, isHov, math.floor(chipH / 2), false, skw.bg, skw.bgPad)
            if isHov and isLeftPressed then
                if isSel then
                    local newKeys = {}
                    for _, kid in ipairs(app.keywords) do
                        if kid ~= skw.id then table.insert(newKeys, kid) end
                    end
                    for i = #app.keywords, 1, -1 do app.keywords[i] = nil end
                    for _, v in ipairs(newKeys) do table.insert(app.keywords, v) end
                else
                    table.insert(app.keywords, skw.id)
                end
            end
        end

        -- ===== 右侧：老兵词条 =====
        local rightX = anchorX + halfW + 12
        draw.SimpleText(T("editor.appearance.veteran_combat_keywords"), "SourceHan_Heavy_16", rightX, anchorY, APPLE_BLUE, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        -- 初始化老兵词条数据
        local vetApp = app.veteranAppearance
        if not vetApp then
            vetApp = {}
            app.veteranAppearance = vetApp
        end
        vetApp.keywords = vetApp.keywords or {}
        vetApp.keywordValues = vetApp.keywordValues or { intel = 0, countdown = 0, heavy_armor = 0 }
        -- 确保 veteran 词条一直在老兵 keywords 中
        if not table.HasValue(vetApp.keywords, "veteran") then
            table.insert(vetApp.keywords, 1, "veteran")
        end

        local rightTotalH = DrawKeywordChipGrid(rightX, startY, chipW, cols, activeKeywords, vetApp.keywords, vetApp.keywordValues, mx, my, isLeftPressed)
        -- 2026-08-16：老兵侧不提供特别战斗词条配置——特别战斗词条仅「流亡/老兵」两种：
        -- 流亡属卡组配组时配置（左侧普通词条）；可升为老兵的对象升为老兵后即此面板，无需再配「老兵」
    else
        -- 非老兵模式：保持原有布局
        draw.SimpleText(T("editor.appearance.combat_keywords"), "SourceHan_Heavy_16", anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        local cols = 3
        local chipW = math.max(90, math.floor((trW - 30 - (cols - 1) * chipGap) / cols))
        local startY = anchorY + 26
        local totalRows = math.ceil(#activeKeywords / cols)
        local totalH = DrawKeywordChipGrid(anchorX, startY, chipW, cols, activeKeywords, app.keywords, app.keywordValues, mx, my, isLeftPressed)
        totalH = totalH or (totalRows * (chipGap + chipH) - chipGap)

        if isUnit then
            -- 特别词条
            local specialY = startY + totalH + 16
            draw.SimpleText(T("editor.appearance.special_keywords"), "SourceHan_Heavy_14", anchorX, specialY, APPLE_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        KARDS.CardEditor.Canvas.DrawUnstableWarnAfterTitle(anchorX, specialY, T("editor.appearance.special_keywords"), "SourceHan_Heavy_14", mx, my)
            local specialKeywords = {
                { id = "exile",                  name = T("editor.appearance.keyword_exile"),        desc = T("editor.appearance.keyword_exile_desc") },
                { id = "can_elevate_to_veteran", name = T("editor.appearance.keyword_can_elevate"),  desc = T("editor.appearance.keyword_can_elevate_desc"), bg = "materials/kards/effects/3d2d/veteran.png" },
            }
            local spCols = 2
            local spW = math.max(100, math.floor((trW - 30 - (spCols - 1) * chipGap) / spCols))
            local spY = specialY + 20
            for i, skw in ipairs(specialKeywords) do
            local sbx = anchorX + (i - 1) * (spW + chipGap)
            local sby = spY
            local isSel = false
            for _, kid in ipairs(app.keywords) do
                if kid == skw.id then isSel = true; break end
            end
            local isHov = IsMouseIn(mx, my, sbx, sby, spW, chipH)
            if isHov then KARDS.CardEditor.Canvas.SuggestionText = skw.desc end
            DrawApplePillChip(sbx, sby, spW, chipH, skw.name, isSel, isHov, math.floor(chipH / 2), false, skw.bg, skw.bgPad)
            if isHov and isLeftPressed then
                if isSel then
                    local newKeys = {}
                    for _, kid in ipairs(app.keywords) do
                        if kid ~= skw.id then table.insert(newKeys, kid) end
                    end
                    for i = #app.keywords, 1, -1 do app.keywords[i] = nil end
                    for _, v in ipairs(newKeys) do table.insert(app.keywords, v) end
                else
                    table.insert(app.keywords, skw.id)
                end
            end
        end -- end for specialKeywords
        end -- end if isUnit
    end

    -- 钳击输入框文本写回卡牌数据
    if KARDS.CardEditor.Canvas.PincerInputState then
        app.pincerValue = KARDS.CardEditor.Canvas.PincerInputState.text or ""
    end

    -- ===== 流亡国家多选（2026-08-16） =====
    -- 选择「流亡」词条后，页底显示所有国家多选区；保存时随 app 一并落盘：
    -- 普通流亡（app.keywords）→ app.exileCountries；老兵流亡（vetApp.keywords）
    -- → app.veteranAppearance.exileCountries（readme 7.2.3 流亡=可投入含本国/流亡国的卡组）
    local exileTarget
    if isUnit then
        if table.HasValue(app.keywords or {}, "exile") then
            exileTarget = app
        elseif IsVeteranMode(app) and app.veteranAppearance
            and table.HasValue(app.veteranAppearance.keywords or {}, "exile") then
            exileTarget = app.veteranAppearance
        end
    end
    if exileTarget then
        exileTarget.exileCountries = exileTarget.exileCountries or {}
        local ExileCountries = {
            { id = "usa", name = T("editor.appearance.country_usa") }, { id = "germany", name = T("editor.appearance.country_germany") },
            { id = "soviet", name = T("editor.appearance.country_ussr") }, { id = "uk", name = T("editor.appearance.country_uk") },
            { id = "japan", name = T("editor.appearance.country_japan") }, { id = "italy", name = T("editor.appearance.country_italy") },
            { id = "france", name = T("editor.appearance.country_france") }, { id = "poland", name = T("editor.appearance.country_poland") },
        }
        local exY = trY + trH - 44
        draw.SimpleText(T("editor.appearance.exile_country"), "SourceHan_Heavy_14", anchorX, exY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        local exW, exH2, exGap = 76, 24, 6
        local exX = anchorX + 84
        for i, c in ipairs(ExileCountries) do
            if exX + exW > anchorX + (trW - 30) then
                exX = anchorX
                exY = exY + exH2 + exGap
            end
            local isSel2 = table.HasValue(exileTarget.exileCountries, c.id)
            local isHov2 = IsMouseIn(mx, my, exX, exY, exW, exH2)
            if isHov2 then KARDS.CardEditor.Canvas.SuggestionText = T("editor.appearance.exile_country_prefix") .. c.name end
            DrawApplePillChip(exX, exY, exW, exH2, c.name, isSel2, isHov2, math.floor(exH2 / 2), false)
            if isHov2 and isLeftPressed then
                if isSel2 then
                    local newC = {}
                    for _, v in ipairs(exileTarget.exileCountries) do
                        if v ~= c.id then table.insert(newC, v) end
                    end
                    exileTarget.exileCountries = newC
                else
                    table.insert(exileTarget.exileCountries, c.id)
                end
            end
            exX = exX + exW + exGap
        end
    end
end

-- SourceHan_Heavy 已注册的所有有效字号（参见 Oak_world_Library sh_fonts.lua）
local VALID_FONT_SIZES = {2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 40, 44, 48, 52, 56, 60, 64, 68, 72}

-- 将数值吸附到最近的已注册有效字号
local function SnapToValidFontSize(val)
    local best = VALID_FONT_SIZES[1]
    for _, size in ipairs(VALID_FONT_SIZES) do
        if math.abs(size - val) < math.abs(best - val) then
            best = size
        end
    end
    return best
end

-- ===== 描述编辑区 =====
-- 富文本工具栏（描述页，2026-10-04）：在光标处插入 <b></b> / <i></i>，
-- 与渲染端 ParseRichText（cl_card_preview.lua）支持的标签一致；关键词高亮由渲染端按
-- KeywordsForHighlight 自动处理，无需标签。
-- stateTable 为对应输入状态（_descInputState / _vetDescInputState），app 为外观数据表。
local function DrawRichTextToolbar(x, y, stateTable, app, isVetPanel, mx, my, isLeftPressed)
    local btns = {
        { label = "B", openTag = "<b>", closeTag = "</b>" },
        { label = "I", openTag = "<i>", closeTag = "</i>" },
    }
    local bw, bh, gap = 26, 22, 6
    local bx = x
    for _, b in ipairs(btns) do
        local hov = IsMouseIn(mx, my, bx, y, bw, bh)
        draw.RoundedBox(4, bx, y, bw, bh, hov and Color(70, 130, 220) or Color(90, 90, 96))
        draw.SimpleText(b.label, "SourceHan_Heavy_14", bx + bw / 2, y + bh / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if hov and isLeftPressed and stateTable then
            local text = stateTable.text or ""
            local n = #text
            -- caretPos 为字节偏移（DTextEntry 语义），初值可能来自 utf8.len（字符数）。
            -- 统一按字节处理并钳制，避免 utf8.offset 落在续字节上抛 "initial position is a continuation byte"（2026-10-04）
            local cp = tonumber(stateTable.caretPos)
            if cp == nil or cp < 0 or cp > n then cp = n end
            stateTable.text = string.sub(text, 1, cp) .. b.openTag .. b.closeTag .. string.sub(text, cp + 1)
            stateTable.caretPos = cp + #b.openTag
            -- 同步写回外观数据（输入框未激活时 DTextEntry 的 OnTextChanged 不会触发）
            if app then
                if isVetPanel then
                    if app.veteranAppearance then
                        KARDS.CardEditor.Data.SetLocalizedField(app.veteranAppearance, "specialEffect", stateTable.text)
                    end
                else
                    KARDS.CardEditor.Data.SetLocalizedField(app, "specialEffect", stateTable.text)
                end
            end
        end
        bx = bx + bw + gap
    end
end

function DrawDescriptionEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    local anchorX = trX + 15
    local anchorY = trY + 15
    local isVet = IsVeteranMode(app)

    -- ===== 卡牌名称输入框（所有模式共用，位于顶部） =====
    local nameInputH = 26
    local nameInputW = trW - 30
    local nameInputY = anchorY + 22

    draw.SimpleText(T("editor.appearance.card_name"), "SourceHan_Heavy_16", anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local nameState = KARDS.CardEditor.Canvas._cardNameInputState or {}
    local nameActive = nameState.active or false
    local nameText = nameState.text or ""

    if nameActive then
        draw.RoundedBox(APPLE_RADII.sm, anchorX, nameInputY, nameInputW, nameInputH, APPLE_WHITE)
        surface.SetDrawColor(APPLE_BLUE)
        surface.DrawOutlinedRect(anchorX, nameInputY, nameInputW, nameInputH)
    else
        draw.RoundedBox(APPLE_RADII.sm, anchorX, nameInputY, nameInputW, nameInputH, APPLE_WHITE)
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawOutlinedRect(anchorX, nameInputY, nameInputW, nameInputH)
    end

    local nameTextTopPad = 5
    if nameText == "" then
        draw.SimpleText(T("editor.appearance.enter_card_name"), "SourceHan_Heavy_14", anchorX + 6, nameInputY + nameTextTopPad,
            nameActive and APPLE_INK_MUTED80 or APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    else
        draw.SimpleText(nameText, "SourceHan_Heavy_14", anchorX + 6, nameInputY + nameTextTopPad,
            APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end

    -- 名称输入框光标
    if nameActive and math.floor(SysTime() * 2) % 2 == 0 then
        surface.SetFont("SourceHan_Heavy_14")
        local cursorX = anchorX + 6
        if nameState.caretPos ~= nil then
            local byteLen = #nameText
            local charLen = utf8.len(nameText) or byteLen
            local textBeforeCursor
            if nameState.caretPos <= 0 then
                textBeforeCursor = ""
            elseif nameState.caretPos >= charLen then
                textBeforeCursor = nameText
            else
                local byteStart = utf8.offset(nameText, nameState.caretPos + 1)
                textBeforeCursor = byteStart and string.sub(nameText, 1, byteStart - 1) or nameText
            end
            cursorX = anchorX + 6 + surface.GetTextSize(textBeforeCursor)
        else
            cursorX = anchorX + 6 + surface.GetTextSize(nameText)
        end
        surface.SetDrawColor(APPLE_BLUE)
        surface.DrawLine(cursorX, nameInputY + 4, cursorX, nameInputY + nameInputH - 4)
    end

    -- 名称输入框点击检测范围
    local nameHov = mx >= anchorX and mx <= anchorX + nameInputW and
                    my >= nameInputY and my <= nameInputY + nameInputH

    -- 名称输入框点击
    if isLeftPressed then
        if nameHov then
            if not nameState.active then
                nameState.active = true
                -- 失活所有描述输入框
                local ds = KARDS.CardEditor.Canvas._descInputState
                if ds then ds.active = false end
                local vds = KARDS.CardEditor.Canvas._vetDescInputState
                if vds then vds.active = false end
                KARDS.CardEditor.Canvas._cardNameInputState = nameState
            end
        end
    end
    KARDS.CardEditor.Canvas._cardNameInputState = nameState

    -- 描述区域起始Y（在名称输入框下方留间距）
    local descLabelY = anchorY + 60
    local descTextY = descLabelY + 26          -- 描述输入框起始 Y
    local descInputH = trH - 226                -- 描述输入框高度（缩小以容纳底部两条字体大小数轴）

    if isVet then
        -- 老兵模式：横向切割为左右两半
        local halfW = math.floor((trW - 30 - 12) / 2) -- 12px 中间间距

        -- ===== 左侧：原卡牌描述 =====
        draw.SimpleText(T("editor.appearance.effect_description"), "SourceHan_Heavy_16", anchorX, descLabelY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        local leftInputX = anchorX
        local leftInputY = descTextY
        local leftInputW = halfW
        local leftInputH = descInputH

        local descState = KARDS.CardEditor.Canvas._descInputState or {}
        local isActive = descState.active or false
        local searchText = descState.text or ""
        -- 富文本工具栏（加粗/斜体），插入到光标处（2026-10-04）
        DrawRichTextToolbar(anchorX + 90, descLabelY, descState, app, false, mx, my, isLeftPressed)

        if isActive then
            draw.RoundedBox(APPLE_RADII.sm, leftInputX, leftInputY, leftInputW, leftInputH, APPLE_WHITE)
            surface.SetDrawColor(APPLE_BLUE)
            surface.DrawOutlinedRect(leftInputX, leftInputY, leftInputW, leftInputH)
        else
            draw.RoundedBox(APPLE_RADII.sm, leftInputX, leftInputY, leftInputW, leftInputH, APPLE_WHITE)
            surface.SetDrawColor(APPLE_HAIRLINE)
            surface.DrawOutlinedRect(leftInputX, leftInputY, leftInputW, leftInputH)
        end

        local textTopPad = 6
        if searchText == "" then
            draw.SimpleText(T("editor.appearance.enter_description"), "SourceHan_Heavy_12", leftInputX + 6, leftInputY + textTopPad,
                isActive and APPLE_INK_MUTED80 or APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        else
            draw.SimpleText(searchText, "SourceHan_Heavy_12", leftInputX + 6, leftInputY + textTopPad,
                APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end

        -- 左侧光标
        if isActive and math.floor(SysTime() * 2) % 2 == 0 then
            surface.SetFont("SourceHan_Heavy_12")
            local cursorX = leftInputX + 6
            if descState.caretPos ~= nil then
                local byteLen = #searchText
                local charLen = utf8.len(searchText) or byteLen
                local textBeforeCursor
                if descState.caretPos <= 0 then
                    textBeforeCursor = ""
                elseif descState.caretPos >= charLen then
                    textBeforeCursor = searchText
                else
                    local byteStart = utf8.offset(searchText, descState.caretPos + 1)
                    textBeforeCursor = byteStart and string.sub(searchText, 1, byteStart - 1) or searchText
                end
                cursorX = leftInputX + 6 + surface.GetTextSize(textBeforeCursor)
            else
                cursorX = leftInputX + 6 + surface.GetTextSize(searchText)
            end
            surface.SetDrawColor(APPLE_BLUE)
            surface.DrawLine(cursorX, leftInputY + textTopPad - 1, cursorX, leftInputY + textTopPad + 15)
        end

        -- 左侧鼠标点击
        local leftHov = mx >= leftInputX and mx <= leftInputX + leftInputW and
                        my >= leftInputY and my <= leftInputY + leftInputH
        if isLeftPressed then
            if leftHov then
                if not descState.active then
                    descState.active = true
                    -- 失活右侧和名称输入框
                    local vds = KARDS.CardEditor.Canvas._vetDescInputState
                    if vds then vds.active = false end
                    if nameState then nameState.active = false end
                    KARDS.CardEditor.Canvas._descInputState = descState
                end
            elseif not (mx >= anchorX + halfW + 12 and mx <= anchorX + halfW + 12 + halfW and
                       my >= descTextY and my <= descTextY + descInputH) and not nameHov then
                if descState.active then
                    descState.active = false
                    KARDS.CardEditor.Canvas._descInputState = descState
                end
            end
        end
        KARDS.CardEditor.Canvas._descInputState = descState

        -- ===== 右侧：老兵描述 =====
        local rightInputX = anchorX + halfW + 12
        local rightInputY = descTextY
        local rightInputW = halfW
        local rightInputH = descInputH

        draw.SimpleText(T("editor.appearance.veteran_effect_description"), "SourceHan_Heavy_16", rightInputX, descLabelY, APPLE_BLUE, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        local vetDescState = KARDS.CardEditor.Canvas._vetDescInputState or {}
        local vetIsActive = vetDescState.active or false
        local vetText = vetDescState.text or ""
        -- 富文本工具栏（加粗/斜体），插入到光标处（2026-10-04）
        DrawRichTextToolbar(rightInputX + 130, descLabelY, vetDescState, app, true, mx, my, isLeftPressed)

        if vetIsActive then
            draw.RoundedBox(APPLE_RADII.sm, rightInputX, rightInputY, rightInputW, rightInputH, APPLE_WHITE)
            surface.SetDrawColor(APPLE_BLUE)
            surface.DrawOutlinedRect(rightInputX, rightInputY, rightInputW, rightInputH)
        else
            draw.RoundedBox(APPLE_RADII.sm, rightInputX, rightInputY, rightInputW, rightInputH, APPLE_WHITE)
            surface.SetDrawColor(APPLE_HAIRLINE)
            surface.DrawOutlinedRect(rightInputX, rightInputY, rightInputW, rightInputH)
        end

        if vetText == "" then
            draw.SimpleText(T("editor.appearance.enter_veteran_description"), "SourceHan_Heavy_12", rightInputX + 6, rightInputY + textTopPad,
                vetIsActive and APPLE_INK_MUTED80 or APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        else
            draw.SimpleText(vetText, "SourceHan_Heavy_12", rightInputX + 6, rightInputY + textTopPad,
                APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end

        -- 右侧光标
        if vetIsActive and math.floor(SysTime() * 2) % 2 == 0 then
            surface.SetFont("SourceHan_Heavy_12")
            local cursorX2 = rightInputX + 6
            if vetDescState.caretPos ~= nil then
                local byteLen = #vetText
                local charLen = utf8.len(vetText) or byteLen
                local textBeforeCursor
                if vetDescState.caretPos <= 0 then
                    textBeforeCursor = ""
                elseif vetDescState.caretPos >= charLen then
                    textBeforeCursor = vetText
                else
                    local byteStart = utf8.offset(vetText, vetDescState.caretPos + 1)
                    textBeforeCursor = byteStart and string.sub(vetText, 1, byteStart - 1) or vetText
                end
                cursorX2 = rightInputX + 6 + surface.GetTextSize(textBeforeCursor)
            else
                cursorX2 = rightInputX + 6 + surface.GetTextSize(vetText)
            end
            surface.SetDrawColor(APPLE_BLUE)
            surface.DrawLine(cursorX2, rightInputY + textTopPad - 1, cursorX2, rightInputY + textTopPad + 15)
        end

        -- 右侧鼠标点击
        local rightHov = mx >= rightInputX and mx <= rightInputX + rightInputW and
                         my >= rightInputY and my <= rightInputY + rightInputH
        if isLeftPressed then
            if rightHov then
                if not vetDescState.active then
                    vetDescState.active = true
                    -- 失活左侧和名称输入框
                    if descState then descState.active = false end
                    if nameState then nameState.active = false end
                    KARDS.CardEditor.Canvas._vetDescInputState = vetDescState
                end
            elseif not leftHov and not nameHov then
                if vetDescState.active then
                    vetDescState.active = false
                    KARDS.CardEditor.Canvas._vetDescInputState = vetDescState
                end
            end
        end
        KARDS.CardEditor.Canvas._vetDescInputState = vetDescState
    else
        -- 非老兵模式：单输入框布局（下移以容纳名称框，上缩以容纳字体大小数轴）
        draw.SimpleText(T("editor.appearance.effect_description"), "SourceHan_Heavy_16", anchorX, descLabelY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        local inputX = anchorX
        local inputY = descTextY
        local inputW_val = trW - 30
        local inputH_val = descInputH

        local descState = KARDS.CardEditor.Canvas._descInputState or {}
        local isActive = descState.active or false
        local searchText = descState.text or ""
        -- 富文本工具栏（加粗/斜体），插入到光标处（2026-10-04）
        DrawRichTextToolbar(anchorX + 90, descLabelY, descState, app, false, mx, my, isLeftPressed)

        if isActive then
            draw.RoundedBox(APPLE_RADII.sm, inputX, inputY, inputW_val, inputH_val, APPLE_WHITE)
            surface.SetDrawColor(APPLE_BLUE)
            surface.DrawOutlinedRect(inputX, inputY, inputW_val, inputH_val)
        else
            draw.RoundedBox(APPLE_RADII.sm, inputX, inputY, inputW_val, inputH_val, APPLE_WHITE)
            surface.SetDrawColor(APPLE_HAIRLINE)
            surface.DrawOutlinedRect(inputX, inputY, inputW_val, inputH_val)
        end

        local textTopPad = 6
        if searchText == "" then
            draw.SimpleText(T("editor.appearance.enter_description"), "SourceHan_Heavy_12", inputX + 6, inputY + textTopPad,
                isActive and APPLE_INK_MUTED80 or APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        else
            draw.SimpleText(searchText, "SourceHan_Heavy_12", inputX + 6, inputY + textTopPad,
                APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end

        if isActive and math.floor(SysTime() * 2) % 2 == 0 then
            surface.SetFont("SourceHan_Heavy_12")
            local cursorX
            if descState.caretPos ~= nil then
                local textBeforeCursor
                local byteLen = #searchText
                local charLen = utf8.len(searchText) or byteLen
                if descState.caretPos <= 0 then
                    textBeforeCursor = ""
                elseif descState.caretPos >= charLen then
                    textBeforeCursor = searchText
                else
                    local byteStart = utf8.offset(searchText, descState.caretPos + 1)
                    if byteStart then
                        textBeforeCursor = string.sub(searchText, 1, byteStart - 1)
                    else
                        textBeforeCursor = searchText
                    end
                end
                cursorX = inputX + 6 + surface.GetTextSize(textBeforeCursor)
            else
                cursorX = inputX + 6 + surface.GetTextSize(searchText)
            end
            surface.SetDrawColor(APPLE_BLUE)
            surface.DrawLine(cursorX, inputY + textTopPad - 1, cursorX, inputY + textTopPad + 15)
        end

        local inputHov = mx >= inputX and mx <= inputX + inputW_val and
                         my >= inputY and my <= inputY + inputH_val
        if isLeftPressed then
            if inputHov then
                if not descState.active then
                    descState.active = true
                    -- 失活名称输入框
                    if nameState then nameState.active = false end
                    KARDS.CardEditor.Canvas._descInputState = descState
                end
            elseif not nameHov then
                if descState.active then
                    descState.active = false
                    KARDS.CardEditor.Canvas._descInputState = descState
                end
            end
        end
        KARDS.CardEditor.Canvas._descInputState = descState
    end

    -- ===== 字体大小数轴（所有模式共用，位于描述框底部） =====
    local fsSliderW = trW - 30
    local fsSliderY = descTextY + descInputH + 8  -- 描述框底部 + 间距（名称字号数轴）
    local fsSliderH = 36

    -- ===== 效果描述字体大小数轴（位于名称字号数轴上方） =====
    local dsSliderW = fsSliderW
    local dsSliderY = fsSliderY - 66  -- 名称字号数轴上方（标题22 + 滑条36 + 间距8）
    local dsSliderH = 36

    -- 标题和当前值
    local curDescSize = app.descFontSize or 20
    draw.SimpleText(T("editor.appearance.effect_desc_font_size"), "SourceHan_Heavy_16", anchorX, dsSliderY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText(tostring(curDescSize), "SourceHan_Heavy_16", anchorX + dsSliderW, dsSliderY, APPLE_BLUE, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)

    -- 描述字号滑块状态初始化
    local dsState = KARDS.CardEditor.Canvas._descFontSizeSliderState
    if not dsState then
        local initMin = math.max(2, curDescSize - 10)
        local initMax = math.min(72, curDescSize + 10)
        dsState = { isDragging = false, animating = false, dragStartX = 0, dragValueAtStart = 0, displayMin = initMin, displayMax = initMax, animStartTime = 0, animDuration = 0.3 }
        KARDS.CardEditor.Canvas._descFontSizeSliderState = dsState
    end
    local dsValRef = { curDescSize }
    local dsDMinRef = { dsState.displayMin }
    local dsDMaxRef = { dsState.displayMax }

    -- 绘制滑条（箭头在左、步长2）
    DrawSliderBar(anchorX, dsSliderY + 22, dsSliderW, dsSliderH, dsValRef, 2, 72, dsDMinRef, dsDMaxRef, dsState, mx, my, isLeftPressed, dt, "left", 2)

    -- 回写值（吸附到最近的有效字号）
    local newDescSize = SnapToValidFontSize(dsValRef[1])
    if newDescSize ~= curDescSize then
        app.descFontSize = newDescSize
        if app.veteranAppearance then
            app.veteranAppearance.descFontSize = newDescSize
        end
    end
    KARDS.CardEditor.Canvas._descFontSizeSliderState = dsState
    dsState.displayMin = dsDMinRef[1]
    dsState.displayMax = dsDMaxRef[1]

    -- ===== 卡牌名称字体大小数轴（位于描述字号数轴下方） =====
    -- 标题和当前值
    local curFontSize = app.nameFontSize or 36
    draw.SimpleText(T("editor.appearance.card_name_font_size"), "SourceHan_Heavy_16", anchorX, fsSliderY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText(tostring(curFontSize), "SourceHan_Heavy_16", anchorX + fsSliderW, fsSliderY, APPLE_BLUE, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)

    -- 字体大小滑块状态初始化
    local fsState = KARDS.CardEditor.Canvas._nameFontSizeSliderState
    if not fsState then
        local initMin = math.max(2, curFontSize - 10)
        local initMax = math.min(72, curFontSize + 10)
        fsState = { isDragging = false, animating = false, dragStartX = 0, dragValueAtStart = 0, displayMin = initMin, displayMax = initMax, animStartTime = 0, animDuration = 0.3 }
        KARDS.CardEditor.Canvas._nameFontSizeSliderState = fsState
    end
    local fsValRef = { curFontSize }
    local fsDMinRef = { fsState.displayMin }
    local fsDMaxRef = { fsState.displayMax }

    -- 绘制滑条（箭头在左、步长2）
    DrawSliderBar(anchorX, fsSliderY + 22, fsSliderW, fsSliderH, fsValRef, 2, 72, fsDMinRef, fsDMaxRef, fsState, mx, my, isLeftPressed, dt, "left", 2)

    -- 回写值（吸附到最近的有效字号）
    local newSize = SnapToValidFontSize(fsValRef[1])
    if newSize ~= curFontSize then
        app.nameFontSize = newSize
        if app.veteranAppearance then
            app.veteranAppearance.nameFontSize = newSize
        end
    end
    KARDS.CardEditor.Canvas._nameFontSizeSliderState = fsState
    fsState.displayMin = fsDMinRef[1]
    fsState.displayMax = fsDMaxRef[1]
end

-- 扫描本地 kards_images 目录下的图片文件（自动创建目录）
local function ScanLocalImages()
    file.CreateDir("kards_images")
    local files, dirs = file.Find("kards_images/*", "DATA")
    local state = KARDS.CardEditor.Canvas._localImageState
    state.files = files or {}
end

-- ===== 插图编辑区（双列布局：本地上传 | 网络上传 + 底部预览） =====
function DrawIllustrationEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    -- 进入插图时立即扫描一次本地图片文件
    if not KARDS.CardEditor.Canvas._illustrationAutoScanned then
        KARDS.CardEditor.Canvas._illustrationAutoScanned = true
        ScanLocalImages()
    end

    local anchorX = trX + 15
    local anchorY = trY + 15
    local editW = trW - 30

    -- 字体参数（全部加大）
    local fontTitle = "SourceHan_Heavy_20"
    local fontHeader = "SourceHan_Heavy_16"
    local fontBody = "SourceHan_Heavy_14"
    local headerH = 24
    local bodyH = 20
    local inputH = 32

    -- 双列布局
    local colGap = 20
    local colW = (editW - colGap) / 2
    local c1x = anchorX
    local c2x = anchorX + colW + colGap

    -- === 主标题 ===
    draw.SimpleText(T("editor.appearance.card_illustration"), fontTitle, anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- ========== 左列：方式一·本地图片上传 ==========
    local ly = anchorY + 34
    draw.SimpleText(T("editor.appearance.upload_from_local"), fontHeader, c1x, ly, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    ly = ly + headerH + 8
    draw.SimpleText(T("editor.appearance.local_folder_instruction"), fontBody, c1x, ly, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    ly = ly + bodyH + 2
    local folderClr = Color(100, 160, 255)
    draw.SimpleText("garrysmod/data/kards_images/", fontBody, c1x, ly, folderClr, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 扫描按钮（左半）+ 排列样式按钮（右半：按下一次切换到下一样式 3→6→9→3）
    ly = ly + bodyH + 12
    local btnY = ly
    local btnGap = 8
    local btnW = math.floor((colW - btnGap) / 2)
    local btnH = 32
    local btnHov = mx >= c1x and mx <= c1x + btnW and my >= btnY and my <= btnY + btnH
    DrawHoverButton(c1x, btnY, btnW, btnH, T("editor.appearance.scan_local_images"), btnHov, { radius = APPLE_RADII.sm, hoverBg = Color(70, 130, 220), normalBg = Color(60, 110, 200), font = fontBody })
    if isLeftPressed and btnHov then
        ScanLocalImages()
    end
    -- 排列样式按钮：显示当前每行张数，按下一次循环切换到下一样式
    local cycleBtnX = c1x + btnW + btnGap
    local cycleBtnW = colW - btnW - btnGap
    local cycleCols = KARDS.CardEditor.Canvas._localImageCols or 3
    if cycleCols ~= 3 and cycleCols ~= 6 and cycleCols ~= 9 then
        cycleCols = 3
    end
    local cycleHov = mx >= cycleBtnX and mx <= cycleBtnX + cycleBtnW and my >= btnY and my <= btnY + btnH
    DrawHoverButton(cycleBtnX, btnY, cycleBtnW, btnH, T("editor.appearance.arrange_prefix") .. cycleCols .. T("editor.appearance.arrange_suffix"), cycleHov, { radius = APPLE_RADII.sm, hoverBg = Color(70, 130, 220), normalBg = Color(60, 110, 200), font = fontBody })
    if isLeftPressed and cycleHov then
        KARDS.CardEditor.Canvas._localImageCols = (cycleCols == 3 and 6) or (cycleCols == 6 and 9) or 3
    end

    -- 本地图片列表（缩略图网格：每个选项为一张以"填充"铺满矩形的图片缩略图）
    ly = ly + btnH + 12
    local localState = KARDS.CardEditor.Canvas._localImageState or {}
    local files = localState.files or {}
    local hoveredFilePath = nil
    local hoveredThumbRect = nil
    local hoveredNameTip = nil
    local leftImagesBottom = nil
    local extraFiles = 0
    if #files == 0 then
        draw.SimpleText(T("editor.appearance.no_images_scanned"), fontBody, c1x, ly, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    else
        draw.SimpleText(T("editor.appearance.available_local_images"), fontBody, c1x, ly, APPLE_INK_MUTED60, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        ly = ly + bodyH + 6

        -- 当前排列样式（每行图片数），由上方"排列"按钮循环切换，持久化在 Canvas 状态
        local gridCols = KARDS.CardEditor.Canvas._localImageCols or 3
        if gridCols ~= 3 and gridCols ~= 6 and gridCols ~= 9 then
            gridCols = 3
        end

        -- 缩略图网格：每行 gridCols 张（整列宽度），图片以"填充"模式铺满整个缩略图矩形（object-fit: cover），
        -- 超出部分居中裁剪，选中用蓝色描边、悬停用淡蓝描边标识
        local gridGap = 6
        local thumbW = math.floor((colW - (gridCols - 1) * gridGap) / gridCols)
        local thumbH = thumbW
        local rowGap = 6
        local thumbFont = "SourceHan_Heavy_12"
        local maxRows = math.floor((trH - (ly - trY) - 100) / (thumbH + rowGap))
        maxRows = math.max(1, maxRows)
        local maxItems = math.min(#files, maxRows * gridCols)
        local anyItemHovered = false
        for i = 1, maxItems do
            local col = (i - 1) % gridCols
            local row = math.floor((i - 1) / gridCols)
            local tx = c1x + col * (thumbW + gridGap)
            local ty = ly + row * (thumbH + rowGap)
            local fullName = files[i]
            local filePath = "../data/kards_images/" .. fullName
            -- 文件名截断（字号不变 SourceHan_Heavy_12）：长名从"可显示前缀倒数第2个字符"处
            -- 开始改为"……"，溢出文字不显示
            local label = fullName
            local truncated = false
            if thumbH >= 18 then
                local maxLabelW = math.max(8, thumbW - 6)
                surface.SetFont(thumbFont)
                if surface.GetTextSize(fullName) > maxLabelW then
                    truncated = true
                    -- 求能完整显示的字符数（字节安全）
                    local fitChars = 0
                    while true do
                        local nextOff = utf8.offset(fullName, fitChars + 2)
                        if not nextOff then break end
                        if surface.GetTextSize(string.sub(fullName, 1, nextOff - 1)) > maxLabelW then break end
                        fitChars = fitChars + 1
                    end
                    -- 溢出文字从 -2 处开始改为"……"（保留 fitChars-2 个字符）
                    local keepChars = math.max(1, fitChars - 2)
                    local kb = utf8.offset(fullName, keepChars + 1)
                    label = string.sub(fullName, 1, (kb and kb - 1) or #fullName) .. "……"
                    -- 若替换后仍超宽，逐步减字符（最少保留 1 个字符）
                    while surface.GetTextSize(label) > maxLabelW and keepChars > 1 do
                        keepChars = keepChars - 1
                        local kb2 = utf8.offset(fullName, keepChars + 1)
                        label = string.sub(fullName, 1, (kb2 and kb2 - 1) or #fullName) .. "……"
                    end
                end
            else
                -- 缩略图过小不绘制文件名，悬停时展示全名
                truncated = true
                label = ""
            end
            local itemHov = mx >= tx and mx <= tx + thumbW and my >= ty and my <= ty + thumbH
            local isSelected = app.imagePath == filePath
            if itemHov then
                anyItemHovered = true
                hoveredFilePath = filePath
                hoveredThumbRect = { x = tx, y = ty, w = thumbW, h = thumbH }
                hoveredNameTip = truncated and fullName or nil
            end
            -- 缩略图背景（加载失败时可见）
            draw.RoundedBox(4, tx, ty, thumbW, thumbH, Color(220, 220, 220))
            -- 以"填充"模式绘制图片：按 max 缩放使图片铺满缩略图矩形，居中裁剪溢出部分
            local mat = Material(filePath, "noclamp smooth")
            if mat and not mat:IsError() then
                local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(filePath)
                local texW = realW or mat:Width()
                local texH = realH or mat:Height()
                if texW > 0 and texH > 0 then
                    local coverScale = math.max(thumbW / texW, thumbH / texH)
                    local drawW = texW * coverScale
                    local drawH = texH * coverScale
                    local imgX = tx + (thumbW - drawW) / 2
                    local imgY = ty + (thumbH - drawH) / 2
                    render.SetScissorRect(tx, ty, tx + thumbW, ty + thumbH, true)
                    surface.SetDrawColor(255, 255, 255, 255)
                    surface.SetMaterial(mat)
                    surface.DrawTexturedRect(imgX, imgY, drawW, drawH)
                    render.SetScissorRect(0, 0, 0, 0, false)
                end
            end
            if isSelected then
                draw.RoundedBox(4, tx, ty, thumbW, thumbH, Color(60, 110, 200, 40))
                surface.SetDrawColor(60, 110, 200)
                surface.DrawOutlinedRect(tx - 1, ty - 1, thumbW + 2, thumbH + 2)
            elseif itemHov then
                surface.SetDrawColor(60, 110, 200, 130)
                surface.DrawOutlinedRect(tx - 1, ty - 1, thumbW + 2, thumbH + 2)
            end
            -- 文件名叠加在缩略图底部（半透明黑条）
            if label ~= "" then
                surface.SetDrawColor(0, 0, 0, 140)
                surface.DrawRect(tx, ty + thumbH - 16, thumbW, 16)
                draw.SimpleText(label, thumbFont, tx + 3, ty + thumbH - 14, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            end
            if isLeftPressed and itemHov then
                app.imagePath = filePath
                -- 预热缓存，使首次渲染即可使用文件头真实尺寸
                KARDS.CardEditor.Canvas.GetImageDimensions(app.imagePath)
                -- 自动缩放至填充预览槽，并重置偏移
                app.imageScale = KARDS.CardEditor.Canvas.AutoFitImageScale(app.imagePath, app)
                app.imageOffsetX = 0
                app.imageOffsetY = 0
            end
        end
        ly = ly + math.ceil(maxItems / gridCols) * (thumbH + rowGap)
        -- 记录图片矩形底边（不含行距），供分界线对齐；未显示文件数移出到分界线下方提示
        leftImagesBottom = ly - rowGap
        extraFiles = math.max(0, #files - maxItems)
        -- 鼠标不在任何缩略图上时清除悬停状态（悬停预览与全名提示随之淡出）
        if not anyItemHovered then
            hoveredFilePath = nil
            hoveredThumbRect = nil
            hoveredNameTip = nil
        end
    end

    -- 悬停预览：双槽交叉淡入淡出（切换图片时旧图淡出、新图淡入，鼠标移出后淡出）
    -- 新槽 _thumbPrevTip 显示当前悬停图片；旧槽 _thumbPrevOld 承载被替换的上一张
    local pv = KARDS.CardEditor.Canvas._thumbPrevTip
    if not pv then
        pv = { alpha = 0, x = 0, y = 0, w = 0, h = 0, mat = nil, _key = nil }
        KARDS.CardEditor.Canvas._thumbPrevTip = pv
    end
    local pvOld = KARDS.CardEditor.Canvas._thumbPrevOld
    if not pvOld then
        pvOld = { alpha = 0, x = 0, y = 0, w = 0, h = 0, mat = nil }
        KARDS.CardEditor.Canvas._thumbPrevOld = pvOld
    end
    -- 悬停目标改变：把当前显示降级为旧槽（从当前 alpha 开始淡出），新槽从 0 淡入
    local hoverKey = hoveredFilePath or ""
    if pv._key ~= hoverKey then
        if pv.mat then
            pvOld.alpha, pvOld.x, pvOld.y, pvOld.w, pvOld.h, pvOld.mat = pv.alpha, pv.x, pv.y, pv.w, pv.h, pv.mat
        end
        pv.alpha = 0
        pv.mat = nil
        pv._key = hoverKey
    end
    if hoveredFilePath and hoveredThumbRect then
        local hoverMat = Material(hoveredFilePath, "noclamp smooth")
        if hoverMat and not hoverMat:IsError() then
            local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(hoveredFilePath)
            local texW = realW or hoverMat:Width()
            local texH = realH or hoverMat:Height()
            -- 预览缩略图大小（最大 160x120，保持宽高比）
            local pvMaxW = 160
            local pvMaxH = 120
            local pvScale = math.min(pvMaxW / texW, pvMaxH / texH, 1.0)
            pv.w = texW * pvScale
            pv.h = texH * pvScale
            -- 定位到悬停图片选项的正下方（水平居中），并限制在编辑区内
            pv.x = math.max(trX + 4, math.min(trX + editW - pv.w - 8, hoveredThumbRect.x + (hoveredThumbRect.w - pv.w) / 2))
            pv.y = math.max(trY + 4, hoveredThumbRect.y + hoveredThumbRect.h + 8)
            pv.mat = hoverMat
        else
            pv.mat = nil
        end
    end
    -- 悬停预览的绘制推迟到本区全部内容之后（2026-10-04：保证在最高层，不被底部预览框等后续内容遮挡）。
    -- 此处仅定义绘制函数，实际调用在 DrawIllustrationEditArea 末尾。
    local function DrawIllustrationHoverPreview()
        -- 新槽淡入（无效材质不淡入），旧槽持续淡出（约 0.17 秒到位）
        pv.alpha = math.Approach(pv.alpha, pv.mat and 1 or 0, dt * 6)
        pvOld.alpha = math.Approach(pvOld.alpha, 0, dt * 6)
        -- 绘制：先旧后新，新图覆盖旧图实现交叉淡入淡出
        if pvOld.alpha > 0.02 and pvOld.mat then
            local a = math.floor(220 * pvOld.alpha)
            draw.RoundedBox(APPLE_RADII.sm, pvOld.x - 4, pvOld.y - 4, pvOld.w + 8, pvOld.h + 8, Color(40, 40, 40, a))
            surface.SetDrawColor(255, 255, 255, math.floor(255 * pvOld.alpha))
            surface.SetMaterial(pvOld.mat)
            surface.DrawTexturedRect(pvOld.x, pvOld.y, pvOld.w, pvOld.h)
        end
        if pv.alpha > 0.02 and pv.mat then
            local a = math.floor(220 * pv.alpha)
            draw.RoundedBox(APPLE_RADII.sm, pv.x - 4, pv.y - 4, pv.w + 8, pv.h + 8, Color(40, 40, 40, a))
            surface.SetDrawColor(255, 255, 255, math.floor(255 * pv.alpha))
            surface.SetMaterial(pv.mat)
            surface.DrawTexturedRect(pv.x, pv.y, pv.w, pv.h)
        end
        -- 旧槽淡出完成后清除材质
        if pvOld.alpha <= 0.02 then
            pvOld.mat = nil
        end
    end

    -- 文件名全名提示：悬停在"名称被截断"的图片选项上时，在文件名位置淡入矩形展示全名
    local tipState = KARDS.CardEditor.Canvas._thumbNameTip
    if not tipState then
        tipState = { alpha = 0, x = 0, y = 0, w = 0, text = "" }
        KARDS.CardEditor.Canvas._thumbNameTip = tipState
    end
    local tipTarget = 0
    if hoveredNameTip and hoveredThumbRect then
        tipTarget = 1
        surface.SetFont("SourceHan_Heavy_12")
        local tw = surface.GetTextSize(hoveredNameTip)
        local tipX = hoveredThumbRect.x
        local rightBound = trX + editW - 4
        if tipX + tw + 8 > rightBound then
            tipX = math.max(trX + 4, rightBound - tw - 8)
        end
        tipState.x = tipX
        tipState.y = math.max(trY + 4, hoveredThumbRect.y + hoveredThumbRect.h - 16)
        tipState.w = tw + 8
        tipState.text = hoveredNameTip
    end
    -- 淡入淡出（约 0.17 秒到位）
    tipState.alpha = math.Approach(tipState.alpha, tipTarget, dt * 6)
    if tipState.alpha > 0.02 then
        local a = math.floor(255 * tipState.alpha)
        draw.RoundedBox(3, tipState.x, tipState.y, tipState.w, 16, Color(30, 30, 30, a))
        draw.SimpleText(tipState.text, "SourceHan_Heavy_12", tipState.x + 4, tipState.y + 8, Color(255, 255, 255, a), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    -- 分界线基准：有图片网格时以图片底边为基准（分界线与 3 张/行样式图片底边重合），
    -- 无图片网格时沿用原基准
    local leftBottomY = leftImagesBottom and (leftImagesBottom - 10) or (ly + bodyH)

    -- ========== 右列：方式二·从网络上传 ==========
    local ry = anchorY + 34
    draw.SimpleText(T("editor.appearance.upload_from_url"), fontHeader, c2x, ry, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- URL 输入框（右列）
    ry = ry + headerH + 8
    local inputY = ry
    local inputW = colW
    local urlState = KARDS.CardEditor.Canvas._urlInputState or {}
    local isActive = urlState.active or false
    local urlText = urlState.text or ""

    if isActive then
        draw.RoundedBox(APPLE_RADII.sm, c2x, inputY, inputW, inputH, APPLE_WHITE)
        surface.SetDrawColor(APPLE_BLUE)
        surface.DrawOutlinedRect(c2x, inputY, inputW, inputH)
    else
        draw.RoundedBox(APPLE_RADII.sm, c2x, inputY, inputW, inputH, APPLE_WHITE)
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawOutlinedRect(c2x, inputY, inputW, inputH)
    end

    if urlText == "" then
        draw.SimpleText(T("editor.appearance.enter_image_url"), fontBody, c2x + 6, inputY + inputH / 2,
            isActive and APPLE_INK_MUTED80 or APPLE_INK_MUTED,
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(urlText, fontBody, c2x + 6, inputY + inputH / 2,
            APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    -- 光标绘制
    if isActive and math.floor(SysTime() * 2) % 2 == 0 then
        surface.SetFont(fontBody)
        local cursorX
        if urlState.caretPos ~= nil then
            local charLen = utf8.len(urlText) or #urlText
            if urlState.caretPos <= 0 then
                cursorX = c2x + 6
            elseif urlState.caretPos >= charLen then
                cursorX = c2x + 6 + surface.GetTextSize(urlText)
            else
                local byteStart = utf8.offset(urlText, urlState.caretPos + 1)
                if byteStart then
                    cursorX = c2x + 6 + surface.GetTextSize(string.sub(urlText, 1, byteStart - 1))
                else
                    cursorX = c2x + 6 + surface.GetTextSize(urlText)
                end
            end
        else
            cursorX = c2x + 6 + surface.GetTextSize(urlText)
        end
        surface.SetDrawColor(APPLE_BLUE)
        surface.DrawLine(cursorX, inputY + 3, cursorX, inputY + inputH - 3)
    end

    -- 输入框点击检测
    local inputHov = mx >= c2x and mx <= c2x + inputW and my >= inputY and my <= inputY + inputH
    if isLeftPressed then
        if inputHov then
            if not urlState.active then
                urlState.active = true
                KARDS.CardEditor.Canvas._urlInputState = urlState
            end
        else
            if urlState.active then
                urlState.active = false
                KARDS.CardEditor.Canvas._urlInputState = urlState
            end
        end
    end

    -- 操作步骤
    ry = inputY + inputH + 12
    draw.SimpleText(T("editor.appearance.steps"), fontBody, c2x, ry, APPLE_INK_MUTED60, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    ry = ry + bodyH + 4
    draw.SimpleText(T("editor.appearance.step_find_image"), fontBody, c2x, ry, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    ry = ry + bodyH
    draw.SimpleText(T("editor.appearance.step_copy_address"), fontBody, c2x, ry, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    ry = ry + bodyH + 4
    draw.SimpleText(T("editor.appearance.step_click_input"), fontBody, c2x, ry, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    ry = ry + bodyH

    draw.SimpleText(T("editor.appearance.step_paste_url"), fontBody, c2x, ry, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    ry = ry + bodyH + 4
    draw.SimpleText(T("editor.appearance.step_auto_download"), fontBody, c2x, ry, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    ry = ry + bodyH
    draw.SimpleText(T("editor.appearance.step_preview_below"), fontBody, c2x, ry, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    ry = ry + bodyH + 8
    draw.SimpleText(T("editor.appearance.note_gmod_cannot_read"), fontBody, c2x, ry, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    ry = ry + bodyH
    draw.SimpleText(T("editor.appearance.note_local_files"), fontBody, c2x, ry, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    ry = ry + bodyH
    draw.SimpleText(T("editor.appearance.note_network_url_required"), fontBody, c2x, ry, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 下载状态
    ry = ry + bodyH + 8
    local dlState = KARDS.CardEditor.Canvas._imageDownloadState or {}
    if dlState.status == "downloading" then
        draw.SimpleText(T("editor.appearance.downloading_image"), fontBody, c2x, ry, APPLE_BLUE, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    elseif dlState.status == "success" then
        draw.SimpleText(T("editor.appearance.download_success"), fontBody, c2x, ry, Color(100, 200, 100), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    elseif dlState.status == "error" then
        draw.SimpleText(T("editor.appearance.download_failed_prefix") .. dlState.errorMsg, fontBody, c2x, ry, Color(200, 100, 100), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end
    local rightBottomY = ry + bodyH

    -- ========== 底部预览区域（居中，匹配卡牌插图槽比例） ==========
    local contentBottomY = math.max(leftBottomY, rightBottomY)
    local previewTopY = contentBottomY + 20
    local remainingH = trH - (previewTopY - trY)

    -- 计算当前模板的空心区域尺寸（模板空间，即0.25缩放下）
    local slotW_ts, slotH_ts = 140, 110  -- 默认回退值
    do
        local tempKey = app.cardTemplate .. "_" .. app.cardType
        local tempPath = KARDS.CardEditor.Canvas.ImagePaths.template[tempKey]
        if not tempPath then
            tempPath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
        end
        if tempPath then
            local tempMat = Material(tempPath)
            if tempMat and not tempMat:IsError() then
                local hx, hy, hw, hh = KARDS.CardEditor.Canvas.GetTemplateHollowBounds(tempMat)
                if hw > 0 and hh > 0 then
                    slotW_ts = hw * 0.25
                    slotH_ts = hh * 0.25
                end
            end
        end
    end

    -- 预览框：正方形，宽 = 高
    local maxPreviewW = math.min(editW - 20, 220)
    local maxPreviewH = remainingH - 10
    local previewSize = math.min(maxPreviewW, maxPreviewH)
    local previewW = previewSize
    local previewH = previewSize
    local previewX = anchorX + (editW - previewW) / 2
    local previewY = previewTopY + ((remainingH - 10) - previewH) / 2

    -- 分隔线
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawLine(anchorX, contentBottomY + 10, anchorX + editW, contentBottomY + 10)

    -- 预览框背景
    draw.RoundedBox(APPLE_RADII.sm, previewX, previewY, previewW, previewH, APPLE_PARCHMENT)
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawOutlinedRect(previewX, previewY, previewW, previewH)

    -- 编辑区缩放因子：预览框宽度 / 模板空间插槽宽度
    local editScaleFactor = previewW / slotW_ts

    -- 渲染图片
    local imgPreview = false
    if app.imagePath and #app.imagePath > 0 then
        local mat = Material(app.imagePath, "noclamp smooth")
        if mat and not mat:IsError() then
            -- 使用文件头解析的实际尺寸（避免 POT 纹理填充导致错误宽高）
            local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(app.imagePath)
            local texW = realW or mat:Width()
            local texH = realH or mat:Height()
            -- 固定缩放比例 0.25（与卡牌模板一致），渲染原图后缩放
            local imgScale = 0.25 * app.imageScale
            local imgW = texW * imgScale * editScaleFactor
            local imgH = texH * imgScale * editScaleFactor
            local imgX = previewX + (previewW - imgW) / 2 + app.imageOffsetX * editScaleFactor
            local imgY = previewY + (previewH - imgH) / 2 + app.imageOffsetY * editScaleFactor

            -- 裁剪：将图片限定在预览框内，防止拖拽溢出
            render.SetScissorRect(previewX, previewY, previewX + previewW, previewY + previewH, true)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.SetMaterial(mat)
            surface.DrawTexturedRect(imgX, imgY, imgW, imgH)
            render.SetScissorRect(0, 0, 0, 0, false)

            -- 拖拽提示边框
            surface.SetDrawColor(Color(255, 255, 255, 40))
            surface.DrawOutlinedRect(previewX + 4, previewY + 4, previewW - 8, previewH - 8)

            imgPreview = true

            -- 拖拽检测
            local dragState = KARDS.CardEditor.Canvas._imageDragState
            local prevLeft = dragState.isDragging
            local inPreview = mx >= previewX + 4 and mx <= previewX + previewW - 4 and
                             my >= previewY + 4 and my <= previewY + previewH - 4

            -- 中键按下检测（单个帧的按下事件）
            local lastMiddle = KARDS.CardEditor.Canvas._imageDragLastMiddle or false
            local isMiddleDown = input.IsMouseDown(MOUSE_MIDDLE)
            local isMiddlePressed = isMiddleDown and not lastMiddle
            KARDS.CardEditor.Canvas._imageDragLastMiddle = isMiddleDown

            if (isLeftPressed or isMiddlePressed) and not prevLeft and inPreview then
                dragState.isDragging = true
                dragState.dragStartMX = mx
                dragState.dragStartMY = my
                dragState.dragStartOffsetX = app.imageOffsetX or 0
                dragState.dragStartOffsetY = app.imageOffsetY or 0
            end

            if dragState.isDragging then
                if input.IsMouseDown(MOUSE_LEFT) or input.IsMouseDown(MOUSE_MIDDLE) then
                    local dx = mx - dragState.dragStartMX
                    local dy = my - dragState.dragStartMY
                    -- 将屏幕像素增量转换为模板空间单位（除以缩放因子），使两处预览偏移一致
                    app.imageOffsetX = dragState.dragStartOffsetX + dx / editScaleFactor
                    app.imageOffsetY = dragState.dragStartOffsetY + dy / editScaleFactor
                    -- 越界钳制（2026-10-04）：保证图片始终覆盖预览框，拖拽不出现留白
                    if editScaleFactor and editScaleFactor > 0 then
                        local drawnW = texW * 0.25 * (app.imageScale or 1) * editScaleFactor
                        local drawnH = texH * 0.25 * (app.imageScale or 1) * editScaleFactor
                        local maxOffX = math.max(0, (drawnW - previewW) / (2 * editScaleFactor))
                        local maxOffY = math.max(0, (drawnH - previewH) / (2 * editScaleFactor))
                        app.imageOffsetX = math.Clamp(app.imageOffsetX, -maxOffX, maxOffX)
                        app.imageOffsetY = math.Clamp(app.imageOffsetY, -maxOffY, maxOffY)
                    end
                else
                    dragState.isDragging = false
                end
            end
            KARDS.CardEditor.Canvas._imageDragState = dragState

            -- 滚轮缩放检测（以鼠标为缩放点）
            local wheelIn = KARDS.CardEditor.Canvas._wheelZoomIn
            local wheelOut = KARDS.CardEditor.Canvas._wheelZoomOut
            local inPreviewForZoom = mx >= previewX + 4 and mx <= previewX + previewW - 4 and
                                     my >= previewY + 4 and my <= previewY + previewH - 4
            if inPreviewForZoom then
                local zoomFactor = wheelIn and 1.1 or (wheelOut and 1/1.1 or nil)
                if zoomFactor then
                    KARDS.CardEditor.Canvas._wheelZoomIn = false
                    KARDS.CardEditor.Canvas._wheelZoomOut = false
                    local oldScale = app.imageScale or 1
                    local newScale = math.Clamp(oldScale * zoomFactor, 0.01, 4)
                    
                    -- 缩放前图片在屏幕上的位置
                    local oldRenderScale = 0.25 * oldScale * editScaleFactor
                    local oldImgW = texW * oldRenderScale
                    local oldImgH = texH * oldRenderScale
                    local oldImgX = previewX + (previewW - oldImgW) / 2 + (app.imageOffsetX or 0) * editScaleFactor
                    local oldImgY = previewY + (previewH - oldImgH) / 2 + (app.imageOffsetY or 0) * editScaleFactor
                
                    -- 鼠标在图片内的相对位置 (0~1)
                    local relX = (mx - oldImgX) / oldImgW
                    local relY = (my - oldImgY) / oldImgH
                
                    -- 缩放后图片在屏幕上的位置，保持鼠标点固定
                    local newRenderScale = 0.25 * newScale * editScaleFactor
                    local newImgW = texW * newRenderScale
                    local newImgH = texH * newRenderScale
                    local newImgX = mx - relX * newImgW
                    local newImgY = my - relY * newImgH
                
                    -- 转换回模板空间偏移
                    app.imageScale = newScale
                    app.imageOffsetX = (newImgX - previewX - (previewW - newImgW) / 2) / editScaleFactor
                    app.imageOffsetY = (newImgY - previewY - (previewH - newImgH) / 2) / editScaleFactor
                end
            end
        else
            draw.SimpleText(T("editor.appearance.image_load_failed"), fontBody, previewX + previewW / 2, previewY + previewH / 2, Color(200, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    end

    if not imgPreview then
        if not (app.imagePath and #app.imagePath > 0) then
            draw.SimpleText(T("editor.appearance.no_illustration"), "SourceHan_Heavy_14", previewX + previewW / 2, previewY + previewH / 2, Color(100, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.SimpleText(T("editor.appearance.add_image_left_or_above"), fontBody, previewX + previewW / 2, previewY + previewH / 2 + 22, Color(80, 80, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    end

    -- 未显示文件提示（绘制在分界线下方，位于左列，避开居中预览框）
    if extraFiles > 0 then
        draw.SimpleText(T("editor.appearance.more_files_prefix") .. extraFiles .. T("editor.appearance.more_files_suffix"), fontBody, c1x, contentBottomY + 16, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end

    -- 路径显示
    if app.imagePath and #app.imagePath > 0 then
        draw.SimpleText(T("editor.appearance.path_prefix") .. app.imagePath, fontBody, anchorX, previewY + previewH + 10, Color(140, 140, 140), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end

    -- 悬停预览最后绘制（最高层，避免被底部预览框等后续内容遮挡）
    DrawIllustrationHoverPreview()
end

-- 插图文件尺寸缓存（path -> {w, h}）
local imageDimCache = {}

-- 从图片文件头解析实际像素尺寸（PNG/JPEG），避免 POT 纹理填充导致的尺寸错误
local function GetImageFileDimensions(filePath)
    -- 查缓存
    if imageDimCache[filePath] then
        return imageDimCache[filePath].w, imageDimCache[filePath].h
    end

    local data = file.Read(filePath, "DATA")
    if not data or #data < 24 then return nil end

    local b = string.byte

    -- PNG: 签名后 IHDR 块的前 8 字节为宽高（大端）
    if b(data, 1) == 137 and b(data, 2) == 80 and b(data, 3) == 78 and b(data, 4) == 71 then
        local w = b(data, 17) * 16777216 + b(data, 18) * 65536 + b(data, 19) * 256 + b(data, 20)
        local h = b(data, 21) * 16777216 + b(data, 22) * 65536 + b(data, 23) * 256 + b(data, 24)
        if w > 0 and h > 0 then
            imageDimCache[filePath] = { w = w, h = h }
            return w, h
        end
    end

    -- JPEG: 扫描 SOF0 标记 0xFF 0xC0
    local i = 1
    while i < #data - 8 do
        if b(data, i) == 255 then
            local marker = b(data, i + 1)
            if marker == 192 or marker == 193 or marker == 194 then  -- SOF0/SOF1/SOF2
                -- SOF 帧头布局：FF C0 [长度:2] [精度:1] [高:2] [宽:2]，即高在 i+5/i+6、宽在 i+7/i+8
                local h = b(data, i + 5) * 256 + b(data, i + 6)
                local w = b(data, i + 7) * 256 + b(data, i + 8)
                if w > 0 and h > 0 then
                    imageDimCache[filePath] = { w = w, h = h }
                    return w, h
                end
                break
            end
            -- 跳过非 SOF 标记
            if marker ~= 208 and marker ~= 209 and marker ~= 210 and marker ~= 211 and
               marker ~= 212 and marker ~= 213 and marker ~= 214 and marker ~= 215 and
               marker ~= 216 and marker ~= 217 and marker ~= 218 then
                local segLen = b(data, i + 2) * 256 + b(data, i + 3)
                i = i + 2 + segLen
            else
                i = i + 2
            end
        else
            i = i + 1
        end
    end

    return nil
end

-- 从 imagePath（如 "../data/kards_images/xxx.png"）解析实际像素尺寸，供渲染代码使用
-- 若无法解析则返回 nil，调用方应回退到 Material:Width()/Height()
local function GetImageDimensions(imagePath)
    if not imagePath or imagePath == "" then return nil end
    local dataPath = imagePath:match("^%.%./data/(.+)$")
    if not dataPath then return nil end
    return GetImageFileDimensions(dataPath)
end
KARDS.CardEditor.Canvas.GetImageDimensions = GetImageDimensions

-- 导入图片时自动计算 imageScale，使图片填充模板空心区域（object-fit: cover）
-- 参数：imagePath - 图片路径，appearance - 卡牌外观数据（用于获取当前模板）
local function AutoFitImageScale(imagePath, appearance)
    local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(imagePath)
    -- 若文件头解析失败，回退到 Material 尺寸（可能为 POT，但至少能得到合理缩放）
    if (not realW or not realH) and imagePath then
        local fallbackMat = Material(imagePath, "noclamp smooth")
        if fallbackMat and not fallbackMat:IsError() then
            realW, realH = fallbackMat:Width(), fallbackMat:Height()
        end
    end
    if not realW or not realH then return 1.0 end

    -- 获取当前模板的空心区域尺寸，并应用扩展
    local slotW, slotH = 140, 110  -- 默认回退值
    if appearance then
        local tempKey = appearance.cardTemplate .. "_" .. appearance.cardType
        local tempPath = KARDS.CardEditor.Canvas.ImagePaths.template[tempKey]
        if not tempPath then
            tempPath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
        end
        if tempPath then
            local tempMat = Material(tempPath)
            if tempMat and not tempMat:IsError() then
                local hx, hy, hw, hh = KARDS.CardEditor.Canvas.GetTemplateHollowBounds(tempMat)
                if hw > 0 and hh > 0 then
                    slotW = hw * 0.25
                    slotH = hh * 0.25
                end
            end
        end
    end
    -- 插图槽扩展：高度向下延伸2倍，宽度向两侧延伸1.5倍
    slotW = slotW * 1.5
    slotH = slotH * 2

    local baseScale = 0.25

    -- 根据宽高比决定按哪边适配：让图片填满预览槽，多余部分裁剪
    local imageRatio = realW / realH
    local slotRatio = slotW / slotH

    local fitScale
    if imageRatio > slotRatio then
        -- 图片更宽：按高度适配
        fitScale = slotH / (realH * baseScale)
    else
        -- 图片更高：按宽度适配
        fitScale = slotW / (realW * baseScale)
    end

    return math.max(fitScale, 0.01)
end
KARDS.CardEditor.Canvas.AutoFitImageScale = AutoFitImageScale

-- 从 URL 下载图片到历史插图
function StartHistoryImageDownload(url)
    if not url or url == "" then return end

    local dlState = KARDS.CardEditor.Canvas._imageDownloadState
    dlState.status = "downloading"
    dlState.errorMsg = ""

    http.Fetch(url, function(body, len)
        local fileName = "kards_images/img_" .. util.CRC(url) .. ".png"
        file.Write(fileName, body)

        dlState.status = "success"
        dlState.downloadedPath = fileName

        local app = KARDS.CardEditor.Canvas.CardAppearance
        if app then
            app.historyImagePath = "../data/" .. fileName
            KARDS.CardEditor.Canvas.GetImageDimensions(app.historyImagePath)
            app.historyImageScale = KARDS.CardEditor.Canvas.AutoFitImageScale(app.historyImagePath, app)
            app.historyImageOffsetX = 0
            app.historyImageOffsetY = 0
        end
    end, function(error)
         dlState.status = "error"
         dlState.errorMsg = tostring(error)
     end)
end

-- ===== 历史编辑区（左列：完整插图编辑 + 预览区 | 中：卡牌预览 | 右：展示区 + 输入框） =====
function DrawHistoryEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    -- 进入历史时立即扫描一次本地图片文件
    if not KARDS.CardEditor.Canvas._historyAutoScanned then
        KARDS.CardEditor.Canvas._historyAutoScanned = true
        ScanLocalImages()
    end

    local anchorX = trX + 15
    local anchorY = trY + 15
    local editW = trW - 30
    local fontTitle = "SourceHan_Heavy_20"
    local fontHeader = "SourceHan_Heavy_16"
    local fontBody = "SourceHan_Heavy_14"
    local headerH = 24
    local bodyH = 20
    local inputH = 32

    -- 可用垂直范围
    local contentTopY = anchorY
    local contentBottomY = trY + trH - 15
    local availH = contentBottomY - contentTopY

    -- ========== 卡牌预览（在整个编辑区居中，缩放与主预览完全一致） ==========
    local totalEditorH = KARDS.CardEditor.Canvas.TotalEditorH
    local previewBaseH = totalEditorH or trH
    local cardPreviewH = math.floor(previewBaseH / 3)
    local cardPreviewW = math.floor(cardPreviewH * 3 / 4)
    local editCenterX = anchorX + editW / 2
    local cardPreviewX = editCenterX - cardPreviewW / 2
    local cardPreviewY = contentTopY + (availH - cardPreviewH) / 2

    -- 左区宽度（从 anchorX 到卡牌左侧）
    local leftGap = 15
    local leftAreaW = math.max(10, cardPreviewX - anchorX - leftGap)
    local c1x = anchorX
    local c1w = leftAreaW

    -- 右区宽度（从卡牌右侧到编辑区右边缘）
    local rightGap = 8
    local rightAreaX = cardPreviewX + cardPreviewW + rightGap
    local rightAreaW = math.max(10, anchorX + editW - rightAreaX)

    -- 绘制卡牌预览
    draw.RoundedBox(APPLE_RADII.sm, cardPreviewX - 4, cardPreviewY - 4, cardPreviewW + 8, cardPreviewH + 8, Color(50, 50, 50, 180))
    KARDS.CardEditor.Canvas.DrawCardPreview(app, cardPreviewX, cardPreviewY, cardPreviewW, cardPreviewH)

    -- ========== 左列（c1x ~ cardPreviewX）：完整插图编辑，复制自插图页 ==========
    local ly = anchorY
    local colW = c1w

    -- 主标题
    draw.SimpleText(T("editor.appearance.history_illustration"), fontTitle, c1x, ly, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    KARDS.CardEditor.Canvas.DrawUnstableWarnAfterTitle(c1x, ly, T("editor.appearance.history_illustration"), fontTitle, mx, my)
    ly = ly + 34

    -- === 方式一：从本地上传 ===
    draw.SimpleText(T("editor.appearance.upload_from_local"), fontHeader, c1x, ly, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    ly = ly + headerH + 8

    draw.SimpleText(T("editor.appearance.local_folder_instruction"), fontBody, c1x, ly, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    ly = ly + bodyH + 2

    local folderClr = Color(100, 160, 255)
    draw.SimpleText("garrysmod/data/kards_images/", fontBody, c1x, ly, folderClr, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 扫描按钮（左半）+ 排列样式按钮（右半：按下一次切换到下一样式 3→6→9→3，与插图页改造一致）
    ly = ly + bodyH + 12
    local btnY = ly
    local btnGap = 8
    local btnW = math.floor((colW - btnGap) / 2)
    local btnH2 = 32
    local btnHov = mx >= c1x and mx <= c1x + btnW and my >= btnY and my <= btnY + btnH2
    DrawHoverButton(c1x, btnY, btnW, btnH2, T("editor.appearance.scan_local_images"), btnHov, { radius = APPLE_RADII.sm, hoverBg = Color(70, 130, 220), normalBg = Color(60, 110, 200), font = fontBody })
    if isLeftPressed and btnHov then
        ScanLocalImages()
    end
    -- 排列样式按钮：显示当前每行张数，按下一次循环切换到下一样式
    local cycleBtnX = c1x + btnW + btnGap
    local cycleBtnW = colW - btnW - btnGap
    local cycleCols = KARDS.CardEditor.Canvas._historyImageCols or 3
    if cycleCols ~= 3 and cycleCols ~= 6 and cycleCols ~= 9 then
        cycleCols = 3
    end
    local cycleHov = mx >= cycleBtnX and mx <= cycleBtnX + cycleBtnW and my >= btnY and my <= btnY + btnH2
    DrawHoverButton(cycleBtnX, btnY, cycleBtnW, btnH2, T("editor.appearance.arrange_prefix") .. cycleCols .. T("editor.appearance.arrange_suffix"), cycleHov, { radius = APPLE_RADII.sm, hoverBg = Color(70, 130, 220), normalBg = Color(60, 110, 200), font = fontBody })
    if isLeftPressed and cycleHov then
        KARDS.CardEditor.Canvas._historyImageCols = (cycleCols == 3 and 6) or (cycleCols == 6 and 9) or 3
    end

    -- 本地图片文件列表（缩略图网格：每个选项为一张以"填充"铺满矩形的图片缩略图，与插图页一致）
    ly = ly + btnH2 + 12
    local localState = KARDS.CardEditor.Canvas._localImageState or {}
    local files = localState.files or {}
    local hoveredHistoryPath = nil
    local hoveredHistoryThumbRect = nil
    local hoveredHistoryNameTip = nil
    local anyHistoryItemHovered = false
    if #files == 0 then
        draw.SimpleText(T("editor.appearance.no_images_scanned"), fontBody, c1x, ly, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    else
        draw.SimpleText(T("editor.appearance.available_local_images"), fontBody, c1x, ly, APPLE_INK_MUTED60, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        ly = ly + bodyH + 6

        -- 当前排列样式（每行图片数），由上方"排列"按钮循环切换，持久化在 Canvas 状态（独立于插图页 _localImageCols）
        local gridCols = KARDS.CardEditor.Canvas._historyImageCols or 3
        if gridCols ~= 3 and gridCols ~= 6 and gridCols ~= 9 then
            gridCols = 3
        end

        -- 缩略图网格：每行 gridCols 张，图片以"填充"模式铺满整个缩略图矩形（object-fit: cover），
        -- 超出部分居中裁剪，选中用蓝色描边、悬停用淡蓝描边标识
        local gridGap = 6
        local thumbW = math.floor((colW - (gridCols - 1) * gridGap) / gridCols)
        -- 历史页左列较宽：正方形缩略图若随列宽放大，行高会挤压下方布局（预览区被挤出页面底部），钳制最大边长
        local maxThumb = 60
        thumbW = math.min(thumbW, maxThumb)
        local thumbH = thumbW
        local rowGap = 6
        local thumbFont = "SourceHan_Heavy_12"
        -- 网格高度限制：保持原有布局约束（不侵入下方方式二/预览区）
        local fileListMaxY = anchorY + availH * 0.5
        local maxRows = math.floor((fileListMaxY - ly) / (thumbH + rowGap))
        maxRows = math.max(1, maxRows)
        local maxItems = math.min(#files, maxRows * gridCols)
        for i = 1, maxItems do
            local col = (i - 1) % gridCols
            local row = math.floor((i - 1) / gridCols)
            local tx = c1x + col * (thumbW + gridGap)
            local ty = ly + row * (thumbH + rowGap)
            local fullName = files[i]
            local filePath = "../data/kards_images/" .. fullName
            -- 文件名截断（字号不变 SourceHan_Heavy_12）：长名从"可显示前缀倒数第2个字符"处
            -- 开始改为"……"，溢出文字不显示
            local label = fullName
            local truncated = false
            if thumbH >= 18 then
                local maxLabelW = math.max(8, thumbW - 6)
                surface.SetFont(thumbFont)
                if surface.GetTextSize(fullName) > maxLabelW then
                    truncated = true
                    -- 求能完整显示的字符数（字节安全）
                    local fitChars = 0
                    while true do
                        local nextOff = utf8.offset(fullName, fitChars + 2)
                        if not nextOff then break end
                        if surface.GetTextSize(string.sub(fullName, 1, nextOff - 1)) > maxLabelW then break end
                        fitChars = fitChars + 1
                    end
                    -- 溢出文字从 -2 处开始改为"……"（保留 fitChars-2 个字符）
                    local keepChars = math.max(1, fitChars - 2)
                    local kb = utf8.offset(fullName, keepChars + 1)
                    label = string.sub(fullName, 1, (kb and kb - 1) or #fullName) .. "……"
                    -- 若替换后仍超宽，逐步减字符（最少保留 1 个字符）
                    while surface.GetTextSize(label) > maxLabelW and keepChars > 1 do
                        keepChars = keepChars - 1
                        local kb2 = utf8.offset(fullName, keepChars + 1)
                        label = string.sub(fullName, 1, (kb2 and kb2 - 1) or #fullName) .. "……"
                    end
                end
            else
                -- 缩略图过小不绘制文件名，悬停时展示全名
                truncated = true
                label = ""
            end
            local itemHov = mx >= tx and mx <= tx + thumbW and my >= ty and my <= ty + thumbH
            local isSelected = app.historyImagePath == filePath
            if itemHov then
                anyHistoryItemHovered = true
                hoveredHistoryPath = filePath
                hoveredHistoryThumbRect = { x = tx, y = ty, w = thumbW, h = thumbH }
                hoveredHistoryNameTip = truncated and fullName or nil
            end
            -- 缩略图背景（加载失败时可见）
            draw.RoundedBox(4, tx, ty, thumbW, thumbH, Color(220, 220, 220))
            -- 以"填充"模式绘制图片：按 max 缩放使图片铺满缩略图矩形，居中裁剪溢出部分
            local mat = Material(filePath, "noclamp smooth")
            if mat and not mat:IsError() then
                local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(filePath)
                local texW = realW or mat:Width()
                local texH = realH or mat:Height()
                if texW > 0 and texH > 0 then
                    local coverScale = math.max(thumbW / texW, thumbH / texH)
                    local drawW = texW * coverScale
                    local drawH = texH * coverScale
                    local imgX = tx + (thumbW - drawW) / 2
                    local imgY = ty + (thumbH - drawH) / 2
                    render.SetScissorRect(tx, ty, tx + thumbW, ty + thumbH, true)
                    surface.SetDrawColor(255, 255, 255, 255)
                    surface.SetMaterial(mat)
                    surface.DrawTexturedRect(imgX, imgY, drawW, drawH)
                    render.SetScissorRect(0, 0, 0, 0, false)
                end
            end
            if isSelected then
                draw.RoundedBox(4, tx, ty, thumbW, thumbH, Color(60, 110, 200, 40))
                surface.SetDrawColor(60, 110, 200)
                surface.DrawOutlinedRect(tx - 1, ty - 1, thumbW + 2, thumbH + 2)
            elseif itemHov then
                surface.SetDrawColor(60, 110, 200, 130)
                surface.DrawOutlinedRect(tx - 1, ty - 1, thumbW + 2, thumbH + 2)
            end
            -- 文件名叠加在缩略图底部（半透明黑条）
            if label ~= "" then
                surface.SetDrawColor(0, 0, 0, 140)
                surface.DrawRect(tx, ty + thumbH - 16, thumbW, 16)
                draw.SimpleText(label, thumbFont, tx + 3, ty + thumbH - 14, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            end
            if isLeftPressed and itemHov then
                app.historyImagePath = filePath
                -- 预热缓存，使首次渲染即可使用文件头真实尺寸
                KARDS.CardEditor.Canvas.GetImageDimensions(app.historyImagePath)
                -- 自动缩放至填充预览槽，并重置偏移
                app.historyImageScale = KARDS.CardEditor.Canvas.AutoFitImageScale(app.historyImagePath, app)
                app.historyImageOffsetX = 0
                app.historyImageOffsetY = 0
            end
        end
        -- 记录网格底边（不含最后一行行距），供下方布局（方式二/预览区）定位
        ly = ly + math.ceil(maxItems / gridCols) * (thumbH + rowGap) - rowGap
        if #files > maxItems then
            draw.SimpleText(T("editor.appearance.more_files_prefix") .. (#files - maxItems) .. T("editor.appearance.more_files_suffix"), fontBody, c1x, ly, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end
        -- 鼠标不在任何缩略图上时清除悬停状态（悬停预览与全名提示随之淡出）
        if not anyHistoryItemHovered then
            hoveredHistoryPath = nil
            hoveredHistoryThumbRect = nil
            hoveredHistoryNameTip = nil
        end
    end

    -- 悬停预览（与插图页一致）：双槽交叉淡入淡出（切换图片时旧图淡出、新图淡入，鼠标移出后淡出）
    -- 新槽 _historyThumbPrevTip 显示当前悬停图片；旧槽 _historyThumbPrevOld 承载被替换的上一张
    local hpv = KARDS.CardEditor.Canvas._historyThumbPrevTip
    if not hpv then
        hpv = { alpha = 0, x = 0, y = 0, w = 0, h = 0, mat = nil, _key = nil }
        KARDS.CardEditor.Canvas._historyThumbPrevTip = hpv
    end
    local hpvOld = KARDS.CardEditor.Canvas._historyThumbPrevOld
    if not hpvOld then
        hpvOld = { alpha = 0, x = 0, y = 0, w = 0, h = 0, mat = nil }
        KARDS.CardEditor.Canvas._historyThumbPrevOld = hpvOld
    end
    -- 悬停目标改变：把当前显示降级为旧槽（从当前 alpha 开始淡出），新槽从 0 淡入
    local hHoverKey = hoveredHistoryPath or ""
    if hpv._key ~= hHoverKey then
        if hpv.mat then
            hpvOld.alpha, hpvOld.x, hpvOld.y, hpvOld.w, hpvOld.h, hpvOld.mat = hpv.alpha, hpv.x, hpv.y, hpv.w, hpv.h, hpv.mat
        end
        hpv.alpha = 0
        hpv.mat = nil
        hpv._key = hHoverKey
    end
    if hoveredHistoryPath and hoveredHistoryThumbRect then
        local hoverMat = Material(hoveredHistoryPath, "noclamp smooth")
        if hoverMat and not hoverMat:IsError() then
            local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(hoveredHistoryPath)
            local texW = realW or hoverMat:Width()
            local texH = realH or hoverMat:Height()
            -- 预览缩略图大小（最大 160x120，保持宽高比）
            local hpvMaxW = 160
            local hpvMaxH = 120
            local hpvScale = math.min(hpvMaxW / texW, hpvMaxH / texH, 1.0)
            hpv.w = texW * hpvScale
            hpv.h = texH * hpvScale
            -- 定位到悬停图片选项的正下方（水平居中），并限制在编辑区内
            hpv.x = math.max(trX + 4, math.min(trX + editW - hpv.w - 8, hoveredHistoryThumbRect.x + (hoveredHistoryThumbRect.w - hpv.w) / 2))
            hpv.y = math.max(trY + 4, hoveredHistoryThumbRect.y + hoveredHistoryThumbRect.h + 8)
            hpv.mat = hoverMat
        else
            hpv.mat = nil
        end
    end
    -- 悬停预览的绘制推迟到本区全部内容之后（2026-10-04：保证在最高层，不被底部预览框等后续内容遮挡）。
    -- 此处仅定义绘制函数，实际调用在 DrawHistoryEditArea 末尾。
    local function DrawHistoryHoverPreview()
        -- 新槽淡入（无效材质不淡入），旧槽持续淡出（约 0.17 秒到位）
        hpv.alpha = math.Approach(hpv.alpha, hpv.mat and 1 or 0, dt * 6)
        hpvOld.alpha = math.Approach(hpvOld.alpha, 0, dt * 6)
        -- 绘制：先旧后新，新图覆盖旧图实现交叉淡入淡出
        if hpvOld.alpha > 0.02 and hpvOld.mat then
            local a = math.floor(220 * hpvOld.alpha)
            draw.RoundedBox(APPLE_RADII.sm, hpvOld.x - 4, hpvOld.y - 4, hpvOld.w + 8, hpvOld.h + 8, Color(40, 40, 40, a))
            surface.SetDrawColor(255, 255, 255, math.floor(255 * hpvOld.alpha))
            surface.SetMaterial(hpvOld.mat)
            surface.DrawTexturedRect(hpvOld.x, hpvOld.y, hpvOld.w, hpvOld.h)
        end
        if hpv.alpha > 0.02 and hpv.mat then
            local a = math.floor(220 * hpv.alpha)
            draw.RoundedBox(APPLE_RADII.sm, hpv.x - 4, hpv.y - 4, hpv.w + 8, hpv.h + 8, Color(40, 40, 40, a))
            surface.SetDrawColor(255, 255, 255, math.floor(255 * hpv.alpha))
            surface.SetMaterial(hpv.mat)
            surface.DrawTexturedRect(hpv.x, hpv.y, hpv.w, hpv.h)
        end
        -- 旧槽淡出完成后清除材质
        if hpvOld.alpha <= 0.02 then
            hpvOld.mat = nil
        end
    end

    -- 文件名全名提示：悬停在"名称被截断"的图片选项上时，在文件名位置淡入矩形展示全名
    local htip = KARDS.CardEditor.Canvas._historyThumbNameTip
    if not htip then
        htip = { alpha = 0, x = 0, y = 0, w = 0, text = "" }
        KARDS.CardEditor.Canvas._historyThumbNameTip = htip
    end
    local htipTarget = 0
    if hoveredHistoryNameTip and hoveredHistoryThumbRect then
        htipTarget = 1
        surface.SetFont("SourceHan_Heavy_12")
        local htw = surface.GetTextSize(hoveredHistoryNameTip)
        local htipX = hoveredHistoryThumbRect.x
        local hrightBound = trX + editW - 4
        if htipX + htw + 8 > hrightBound then
            htipX = math.max(trX + 4, hrightBound - htw - 8)
        end
        htip.x = htipX
        htip.y = math.max(trY + 4, hoveredHistoryThumbRect.y + hoveredHistoryThumbRect.h - 16)
        htip.w = htw + 8
        htip.text = hoveredHistoryNameTip
    end
    -- 淡入淡出（约 0.17 秒到位）
    htip.alpha = math.Approach(htip.alpha, htipTarget, dt * 6)
    if htip.alpha > 0.02 then
        local a = math.floor(255 * htip.alpha)
        draw.RoundedBox(3, htip.x, htip.y, htip.w, 16, Color(30, 30, 30, a))
        draw.SimpleText(htip.text, "SourceHan_Heavy_12", htip.x + 4, htip.y + 8, Color(255, 255, 255, a), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    -- 左列内容底部 Y
    local leftColBottomY = ly + bodyH

    -- ===== 左列下方预览区位置（提前计算：贴内容底部，供方式二判定避免重叠） =====
    -- 计算模板空心区域尺寸（同插图页逻辑）
    local slotW_ts, slotH_ts = 140, 110
    do
        local tempKey = app.cardTemplate .. "_" .. app.cardType
        local tempPath = KARDS.CardEditor.Canvas.ImagePaths.template[tempKey]
        if not tempPath then
            tempPath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
        end
        if tempPath then
            local tempMat = Material(tempPath)
            if tempMat and not tempMat:IsError() then
                local hx, hy, hw, hh = KARDS.CardEditor.Canvas.GetTemplateHollowBounds(tempMat)
                if hw > 0 and hh > 0 then
                    slotW_ts = hw * 0.25
                    slotH_ts = hh * 0.25
                end
            end
        end
    end
    -- 预览区位置：贴内容底部（无论上方网格多高都不被挤出页面底部）
    local editPreviewH = math.min(240, math.max(slotH_ts + 20, availH * 0.3))
    local editPreviewTop = math.max(contentBottomY - editPreviewH - 15, ly + bodyH + 10)
    local editPreviewW = colW
    local editPreviewX = c1x
    local editPreviewY = editPreviewTop

    -- === 方式二：从网络上传（在左列下方，预览区上方） ===
    local urlY = leftColBottomY + 12
    -- 如果空间不够，不再绘制网络上传部分
    local urlSectionH = headerH + 8 + inputH + 12 + bodyH * 6 + 12
    local previewSlotMinH = 100
    local remainingForPreview = anchorY + availH - urlY - urlSectionH

    -- 方式二须在预览区上方（预览区贴底部定位，二者不重叠才绘制）
    if remainingForPreview >= previewSlotMinH and (urlY + urlSectionH) < editPreviewTop - 12 then
        draw.SimpleText(T("editor.appearance.upload_from_url"), fontHeader, c1x, urlY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        urlY = urlY + headerH + 8
        local urlInputY = urlY
        local urlInputW = colW
        -- 状态表在编辑器关闭时被置 nil（cl_canvas_editor.lua L2421）；此处缺失则重建。
        -- 否则 urlState 为临时表，active 无法持久，输入框点击后永不激活、DTextEntry 永不创建（2026-10-04）
        if not KARDS.CardEditor.Canvas._historyUrlInputState then
            KARDS.CardEditor.Canvas._historyUrlInputState = { active = false, text = "", caretPos = nil }
        end
        local urlState = KARDS.CardEditor.Canvas._historyUrlInputState
        -- 保存 URL 输入框位置供 DTextEntry 生命周期使用
        urlState.inputRect = { x = c1x, y = urlInputY, w = urlInputW, h = inputH }
        local urlActive = urlState.active or false
        local urlText = urlState.text or ""

        if urlActive then
            draw.RoundedBox(APPLE_RADII.sm, c1x, urlInputY, urlInputW, inputH, APPLE_WHITE)
            surface.SetDrawColor(APPLE_BLUE)
            surface.DrawOutlinedRect(c1x, urlInputY, urlInputW, inputH)
        else
            draw.RoundedBox(APPLE_RADII.sm, c1x, urlInputY, urlInputW, inputH, APPLE_WHITE)
            surface.SetDrawColor(APPLE_HAIRLINE)
            surface.DrawOutlinedRect(c1x, urlInputY, urlInputW, inputH)
        end

        if urlText == "" then
            draw.SimpleText(T("editor.appearance.enter_image_url"), fontBody, c1x + 6, urlInputY + inputH / 2,
                urlActive and APPLE_INK_MUTED80 or APPLE_INK_MUTED,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        else
            draw.SimpleText(urlText, fontBody, c1x + 6, urlInputY + inputH / 2,
                APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end

        -- 光标
        if urlActive and math.floor(SysTime() * 2) % 2 == 0 then
            surface.SetFont(fontBody)
            local curX
            if urlState.caretPos ~= nil then
                local charLen = utf8.len(urlText) or #urlText
                if urlState.caretPos <= 0 then
                    curX = c1x + 6
                elseif urlState.caretPos >= charLen then
                    curX = c1x + 6 + surface.GetTextSize(urlText)
                else
                    local byteStart = utf8.offset(urlText, urlState.caretPos + 1)
                    if byteStart then
                        curX = c1x + 6 + surface.GetTextSize(string.sub(urlText, 1, byteStart - 1))
                    else
                        curX = c1x + 6 + surface.GetTextSize(urlText)
                    end
                end
            else
                curX = c1x + 6 + surface.GetTextSize(urlText)
            end
            surface.SetDrawColor(APPLE_BLUE)
            surface.DrawLine(curX, urlInputY + 3, curX, urlInputY + inputH - 3)
        end

        -- URL 输入框点击检测
        local inUrlInput = mx >= c1x and mx <= c1x + urlInputW and my >= urlInputY and my <= urlInputY + inputH
        if isLeftPressed then
            if inUrlInput then
                urlState.active = true
            else
                urlState.active = false
            end
        end

        -- 下载状态
        urlY = urlInputY + inputH + 8
        local dlState = KARDS.CardEditor.Canvas._imageDownloadState or {}
        if dlState.status == "downloading" then
            draw.SimpleText(T("editor.appearance.downloading_image"), fontBody, c1x, urlY, APPLE_BLUE, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        elseif dlState.status == "success" then
            draw.SimpleText(T("editor.appearance.download_success"), fontBody, c1x, urlY, Color(100, 200, 100), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        elseif dlState.status == "error" then
            draw.SimpleText(T("editor.appearance.download_failed_prefix") .. dlState.errorMsg, fontBody, c1x, urlY, Color(200, 100, 100), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end
    end

    -- ========== 左列下方：预览区（与插图页一致的拖拽/缩放预览） ==========
    -- 背景
    draw.RoundedBox(APPLE_RADII.sm, editPreviewX, editPreviewY, editPreviewW, editPreviewH, APPLE_PARCHMENT)
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawOutlinedRect(editPreviewX, editPreviewY, editPreviewW, editPreviewH)

    -- 编辑区缩放因子
    local editScaleFactor = editPreviewW / slotW_ts
    local imgPreview = false

    if app.historyImagePath and app.historyImagePath ~= "" then
        local mat = Material(app.historyImagePath, "noclamp smooth")
        if mat and not mat:IsError() then
            local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(app.historyImagePath)
            local texW = realW or mat:Width()
            local texH = realH or mat:Height()
            local imgScale = 0.25 * (app.historyImageScale or 1)
            local imgW = texW * imgScale * editScaleFactor
            local imgH = texH * imgScale * editScaleFactor
            local imgX = editPreviewX + (editPreviewW - imgW) / 2 + (app.historyImageOffsetX or 0) * editScaleFactor
            local imgY = editPreviewY + (editPreviewH - imgH) / 2 + (app.historyImageOffsetY or 0) * editScaleFactor

            render.SetScissorRect(editPreviewX, editPreviewY, editPreviewX + editPreviewW, editPreviewY + editPreviewH, true)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.SetMaterial(mat)
            surface.DrawTexturedRect(imgX, imgY, imgW, imgH)
            render.SetScissorRect(0, 0, 0, 0, false)

            -- 拖拽提示边框
            surface.SetDrawColor(Color(255, 255, 255, 40))
            surface.DrawOutlinedRect(editPreviewX + 4, editPreviewY + 4, editPreviewW - 8, editPreviewH - 8)

            imgPreview = true

            -- 拖拽检测
            local dragState = KARDS.CardEditor.Canvas._historyEditDragState
            local prevLeft = dragState.isDragging
            local inEditPrev = mx >= editPreviewX + 4 and mx <= editPreviewX + editPreviewW - 4 and
                              my >= editPreviewY + 4 and my <= editPreviewY + editPreviewH - 4

            local lastMiddle = KARDS.CardEditor.Canvas._imageDragLastMiddle or false
            local isMiddleDown = input.IsMouseDown(MOUSE_MIDDLE)
            local isMiddlePressed = isMiddleDown and not lastMiddle
            KARDS.CardEditor.Canvas._imageDragLastMiddle = isMiddleDown

            if (isLeftPressed or isMiddlePressed) and not prevLeft and inEditPrev then
                dragState.isDragging = true
                dragState.dragStartMX = mx
                dragState.dragStartMY = my
                dragState.dragStartOffsetX = app.historyImageOffsetX or 0
                dragState.dragStartOffsetY = app.historyImageOffsetY or 0
            end

            if dragState.isDragging then
                if input.IsMouseDown(MOUSE_LEFT) or input.IsMouseDown(MOUSE_MIDDLE) then
                    local dx = mx - dragState.dragStartMX
                    local dy = my - dragState.dragStartMY
                    app.historyImageOffsetX = dragState.dragStartOffsetX + dx / editScaleFactor
                    app.historyImageOffsetY = dragState.dragStartOffsetY + dy / editScaleFactor
                    -- 越界钳制（2026-10-04）：保证图片始终覆盖编辑预览框
                    if editScaleFactor and editScaleFactor > 0 then
                        local drawnW = texW * 0.25 * (app.historyImageScale or 1) * editScaleFactor
                        local drawnH = texH * 0.25 * (app.historyImageScale or 1) * editScaleFactor
                        local maxOffX = math.max(0, (drawnW - editPreviewW) / (2 * editScaleFactor))
                        local maxOffY = math.max(0, (drawnH - editPreviewH) / (2 * editScaleFactor))
                        app.historyImageOffsetX = math.Clamp(app.historyImageOffsetX, -maxOffX, maxOffX)
                        app.historyImageOffsetY = math.Clamp(app.historyImageOffsetY, -maxOffY, maxOffY)
                    end
                else
                    dragState.isDragging = false
                end
            end

            -- 滚轮缩放
            local wheelIn = KARDS.CardEditor.Canvas._wheelZoomIn
            local wheelOut = KARDS.CardEditor.Canvas._wheelZoomOut
            local inEditZoom = mx >= editPreviewX + 4 and mx <= editPreviewX + editPreviewW - 4 and
                               my >= editPreviewY + 4 and my <= editPreviewY + editPreviewH - 4
            if inEditZoom then
                local zoomFactor = wheelIn and 1.1 or (wheelOut and 1/1.1 or nil)
                if zoomFactor then
                    KARDS.CardEditor.Canvas._wheelZoomIn = false
                    KARDS.CardEditor.Canvas._wheelZoomOut = false
                    local oldScale = app.historyImageScale or 1
                    local newScale = math.Clamp(oldScale * zoomFactor, 0.01, 4)

                    local oldRenderScale = 0.25 * oldScale * editScaleFactor
                    local oldImgW = texW * oldRenderScale
                    local oldImgH = texH * oldRenderScale
                    local oldImgX = editPreviewX + (editPreviewW - oldImgW) / 2 + (app.historyImageOffsetX or 0) * editScaleFactor
                    local oldImgY = editPreviewY + (editPreviewH - oldImgH) / 2 + (app.historyImageOffsetY or 0) * editScaleFactor

                    local relX = (mx - oldImgX) / oldImgW
                    local relY = (my - oldImgY) / oldImgH

                    local newRenderScale = 0.25 * newScale * editScaleFactor
                    local newImgW = texW * newRenderScale
                    local newImgH = texH * newRenderScale
                    local newImgX = mx - relX * newImgW
                    local newImgY = my - relY * newImgH

                    app.historyImageScale = newScale
                    app.historyImageOffsetX = (newImgX - editPreviewX - (editPreviewW - newImgW) / 2) / editScaleFactor
                    app.historyImageOffsetY = (newImgY - editPreviewY - (editPreviewH - newImgH) / 2) / editScaleFactor
                end
            end
        end
    end

    if not imgPreview then
        if not (app.historyImagePath and #app.historyImagePath > 0) then
            draw.SimpleText(T("editor.appearance.no_illustration"), "SourceHan_Heavy_14", editPreviewX + editPreviewW / 2, editPreviewY + editPreviewH / 2, Color(100, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.SimpleText(T("editor.appearance.add_image_left"), fontBody, editPreviewX + editPreviewW / 2, editPreviewY + editPreviewH / 2 + 22, Color(80, 80, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        else
            draw.SimpleText(T("editor.appearance.image_load_failed"), fontBody, editPreviewX + editPreviewW / 2, editPreviewY + editPreviewH / 2, Color(200, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    end

    -- 路径显示
    if app.historyImagePath and app.historyImagePath ~= "" then
        draw.SimpleText(T("editor.appearance.path_prefix") .. app.historyImagePath, fontBody, editPreviewX, editPreviewY + editPreviewH + 5, Color(140, 140, 140), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end

    -- ========== 卡牌右侧：历史插图展示区（顶边与卡牌预览图对齐）+ 输入框 ==========
    local histDisplayW = rightAreaW
    local histDisplayH = math.min(availH * 0.45, cardPreviewH * 0.55)
    local histDisplayX = rightAreaX
    local histDisplayY = cardPreviewY  -- 顶边与卡牌预览图对齐

    draw.RoundedBox(APPLE_RADII.sm, histDisplayX, histDisplayY, histDisplayW, histDisplayH, APPLE_PARCHMENT)
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawOutlinedRect(histDisplayX, histDisplayY, histDisplayW, histDisplayH)

    -- "插图"标题（放大靠左）
    draw.SimpleText(T("editor.appearance.illustration"), "SourceHan_Heavy_16", histDisplayX + 6, histDisplayY + 6, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 渲染历史插图（带拖拽和缩放，仅在灰色矩形内渲染）
    local displayImgPadding = 6
    local displayImgAreaY = histDisplayY + 28
    local displayImgAreaH = histDisplayH - 28 - displayImgPadding

    if app.historyImagePath and app.historyImagePath ~= "" then
        local histMat = Material(app.historyImagePath, "noclamp smooth")
        if histMat and not histMat:IsError() then
            local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(app.historyImagePath)
            local texW = realW or histMat:Width()
            local texH = realH or histMat:Height()

            -- 使用与左侧预览区相同的 imageScale/Offset，适配右侧展示区尺寸
            local displayScaleFactor = histDisplayW / slotW_ts
            local renderScale = 0.25 * (app.historyImageScale or 1) * displayScaleFactor
            local imgW = texW * renderScale
            local imgH = texH * renderScale
            local imgX = histDisplayX + (histDisplayW - imgW) / 2 + (app.historyImageOffsetX or 0) * displayScaleFactor
            local imgY = displayImgAreaY + (displayImgAreaH - imgH) / 2 + (app.historyImageOffsetY or 0) * displayScaleFactor

            render.SetScissorRect(histDisplayX + 2, displayImgAreaY, histDisplayX + histDisplayW - 2, displayImgAreaY + displayImgAreaH, true)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.SetMaterial(histMat)
            surface.DrawTexturedRect(imgX, imgY, imgW, imgH)

            -- 拖拽提示边框
            surface.SetDrawColor(Color(255, 255, 255, 40))
            surface.DrawOutlinedRect(histDisplayX + 4, displayImgAreaY + 4, histDisplayW - 8, displayImgAreaH - 8)
            render.SetScissorRect(0, 0, 0, 0, false)

            -- 展示区拖拽检测（与编辑预览区使用不同的拖拽状态）
            local dispDragState = KARDS.CardEditor.Canvas._historyDisplayDragState
            local prevDispDrag = dispDragState.isDragging
            local inDispArea = mx >= histDisplayX + 4 and mx <= histDisplayX + histDisplayW - 4 and
                              my >= displayImgAreaY + 4 and my <= displayImgAreaY + displayImgAreaH - 4

            local lastMiddle2 = KARDS.CardEditor.Canvas._imageDragLastMiddle or false
            local isMiddleDown2 = input.IsMouseDown(MOUSE_MIDDLE)
            local isMiddlePressed2 = isMiddleDown2 and not lastMiddle2

            if (isLeftPressed or isMiddlePressed2) and not prevDispDrag and inDispArea then
                dispDragState.isDragging = true
                dispDragState.dragStartMX = mx
                dispDragState.dragStartMY = my
                dispDragState.dragStartOffsetX = app.historyImageOffsetX or 0
                dispDragState.dragStartOffsetY = app.historyImageOffsetY or 0
            end

            if dispDragState.isDragging then
                if input.IsMouseDown(MOUSE_LEFT) or input.IsMouseDown(MOUSE_MIDDLE) then
                    local dx = mx - dispDragState.dragStartMX
                    local dy = my - dispDragState.dragStartMY
                    app.historyImageOffsetX = dispDragState.dragStartOffsetX + dx / displayScaleFactor
                    app.historyImageOffsetY = dispDragState.dragStartOffsetY + dy / displayScaleFactor
                    -- 越界钳制（2026-10-04）：保证图片始终覆盖展示区
                    if displayScaleFactor and displayScaleFactor > 0 then
                        local drawnW = texW * 0.25 * (app.historyImageScale or 1) * displayScaleFactor
                        local drawnH = texH * 0.25 * (app.historyImageScale or 1) * displayScaleFactor
                        local maxOffX = math.max(0, (drawnW - histDisplayW) / (2 * displayScaleFactor))
                        local maxOffY = math.max(0, (drawnH - displayImgAreaH) / (2 * displayScaleFactor))
                        app.historyImageOffsetX = math.Clamp(app.historyImageOffsetX, -maxOffX, maxOffX)
                        app.historyImageOffsetY = math.Clamp(app.historyImageOffsetY, -maxOffY, maxOffY)
                    end
                else
                    dispDragState.isDragging = false
                end
            end

            -- 展示区缩放
            local wheelIn2 = KARDS.CardEditor.Canvas._wheelZoomIn
            local wheelOut2 = KARDS.CardEditor.Canvas._wheelZoomOut
            local inDispZoom = mx >= histDisplayX + 4 and mx <= histDisplayX + histDisplayW - 4 and
                              my >= displayImgAreaY + 4 and my <= displayImgAreaY + displayImgAreaH - 4
            if inDispZoom then
                local zoomFactor = wheelIn2 and 1.1 or (wheelOut2 and 1/1.1 or nil)
                if zoomFactor then
                    KARDS.CardEditor.Canvas._wheelZoomIn = false
                    KARDS.CardEditor.Canvas._wheelZoomOut = false
                    local oldScale = app.historyImageScale or 1
                    local newScale = math.Clamp(oldScale * zoomFactor, 0.01, 4)

                    local oldRenderScale = 0.25 * oldScale * displayScaleFactor
                    local oldImgW = texW * oldRenderScale
                    local oldImgH = texH * oldRenderScale
                    local oldImgX = histDisplayX + (histDisplayW - oldImgW) / 2 + (app.historyImageOffsetX or 0) * displayScaleFactor
                    local oldImgY = displayImgAreaY + (displayImgAreaH - oldImgH) / 2 + (app.historyImageOffsetY or 0) * displayScaleFactor

                    local relX = (mx - oldImgX) / oldImgW
                    local relY = (my - oldImgY) / oldImgH

                    local newRenderScale = 0.25 * newScale * displayScaleFactor
                    local newImgW = texW * newRenderScale
                    local newImgH = texH * newRenderScale
                    local newImgX = mx - relX * newImgW
                    local newImgY = my - relY * newImgH

                    app.historyImageScale = newScale
                    app.historyImageOffsetX = (newImgX - histDisplayX - (histDisplayW - newImgW) / 2) / displayScaleFactor
                    app.historyImageOffsetY = (newImgY - displayImgAreaY - (displayImgAreaH - newImgH) / 2) / displayScaleFactor
                end
            end
        else
            draw.SimpleText(T("editor.appearance.unable_to_load_image"), fontBody, histDisplayX + histDisplayW / 2, histDisplayY + histDisplayH / 2, APPLE_INK_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    else
        draw.SimpleText(T("editor.appearance.no_image_selected"), fontBody, histDisplayX + histDisplayW / 2, histDisplayY + histDisplayH / 2, APPLE_INK_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- ========== 右侧输入框（紧贴展示区下方） ==========
    local inputX = rightAreaX
    local inputW = rightAreaW
    local inputTopY = histDisplayY + histDisplayH + 12
    local inputMaxH = math.max(60, anchorY + availH - inputTopY)
    local inputState = KARDS.CardEditor.Canvas._historyInputState
    inputState.text = app.historyText or ""

    -- 计算内容高度（修复多行计数 bug：初始为 0，每个段落 +wrappedLines）
    surface.SetFont("SourceHan_Heavy_14")
    local lineCount = 0
    if inputState.text and inputState.text ~= "" then
        for line in inputState.text:gmatch("[^\n]*") do
            local lineW = surface.GetTextSize(line)
            local wrappedLines = math.max(1, math.ceil(lineW / math.max(1, inputW - 12)))
            lineCount = lineCount + wrappedLines
        end
    end
    local lineHeight = 20
    local paddingH = 12
    local contentH = lineCount * lineHeight + paddingH
    local inputH2 = math.Clamp(contentH, 60, inputMaxH)

    -- 是否需要滚动
    local needsScroll = contentH > inputMaxH
    if needsScroll then
        inputH2 = inputMaxH
        inputState.maxHeight = inputMaxH
    end

    -- 输入框背景
    if inputState.active then
        draw.RoundedBox(APPLE_RADII.sm, inputX, inputTopY, inputW, inputH2, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(inputX, inputTopY, inputW, inputH2)
    else
        draw.RoundedBox(APPLE_RADII.sm, inputX, inputTopY, inputW, inputH2, Color(40, 40, 40))
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawOutlinedRect(inputX, inputTopY, inputW, inputH2)
    end

    -- 文本绘制（带裁剪，支持滚动，支持 \n 多行渲染）
    render.SetScissorRect(inputX, inputTopY, inputX + inputW, inputTopY + inputH2, true)
    if inputState.text and inputState.text ~= "" then
        local textOffsetY = inputTopY + 6 - (inputState.scrollY or 0)
        surface.SetFont("SourceHan_Heavy_14")
        surface.SetTextColor(255, 255, 255, 255)
        -- 按换行符分行绘制，解决 surface.DrawText 不处理 \n 的问题
        local lines = string.Explode("\n", inputState.text)
        for i, line in ipairs(lines) do
            surface.SetTextPos(inputX + 6, textOffsetY + (i - 1) * lineHeight)
            surface.DrawText(line)
        end
    else
        surface.SetFont("SourceHan_Heavy_14")
        local tw, th = surface.GetTextSize(T("editor.appearance.enter_history_text"))
        surface.SetTextColor(inputState.active and Color(180, 180, 180) or Color(120, 120, 120))
        surface.SetTextPos(inputX + 6, inputTopY + (inputH2 - th) / 2)
        surface.DrawText(T("editor.appearance.enter_history_text"))
    end

    -- 闪烁光标（支持 \n 多行定位）
    if inputState.active and math.floor(SysTime() * 2) % 2 == 0 then
        surface.SetFont("SourceHan_Heavy_14")
        local caretPos = 0
        -- 从 DTextEntry 中获取当前光标位置
        local textEntry = KARDS.CardEditor.Canvas._historyTextEntry
        if textEntry and IsValid(textEntry) then
            caretPos = textEntry:GetCaretPos() or utf8.len(inputState.text or "")
        else
            caretPos = utf8.len(inputState.text or "")
        end

        local preText = utf8.sub(inputState.text or "", 1, caretPos)
        -- 计算光标所在的行号和该行的字符偏移
        local preLines = string.Explode("\n", preText)
        local cursorLine = #preLines                               -- 第几行（1-based）
        local cursorCol = utf8.len(preLines[cursorLine] or "")     -- 该行光标前的字符数
        local cursorX = inputX + 6 + surface.GetTextSize(preLines[cursorLine] or "")
        local cursorY = inputTopY + 6 - (inputState.scrollY or 0) + (cursorLine - 1) * lineHeight
        surface.SetDrawColor(Color(200, 200, 200))
        surface.DrawLine(cursorX, cursorY, cursorX, cursorY + lineHeight)
    end
    render.SetScissorRect(0, 0, 0, 0, false)

    -- 点击检测
    local inInput = mx >= inputX and mx <= inputX + inputW and my >= inputTopY and my <= inputTopY + inputH2
    if isLeftPressed then
        if inInput then
            inputState.active = true
        else
            if not (KARDS.CardEditor.Canvas._historyTextEntry and
                    KARDS.CardEditor.Canvas._historyTextEntry:IsValid() and
                    KARDS.CardEditor.Canvas._historyTextEntry:IsHovered()) then
                inputState.active = false
                inputState.scrollY = 0
            end
        end
    end

    -- 滚轮滚动
    if inputState.active and inInput then
        local wheelIn = KARDS.CardEditor.Canvas._wheelZoomIn
        local wheelOut = KARDS.CardEditor.Canvas._wheelZoomOut
        if needsScroll then
            if wheelIn then
                inputState.scrollY = math.max(0, (inputState.scrollY or 0) - lineHeight * 3)
                KARDS.CardEditor.Canvas._wheelZoomIn = false
            end
            if wheelOut then
                local maxScroll = math.max(0, contentH - inputMaxH)
                inputState.scrollY = math.min(maxScroll, (inputState.scrollY or 0) + lineHeight * 3)
                KARDS.CardEditor.Canvas._wheelZoomOut = false
            end
        end
    end

    -- 同步文本
    app.historyText = inputState.text
    KARDS.CardEditor.Canvas._historyInputState = inputState

    -- ========== 历史输入框 DTextEntry 生命周期管理 ==========
    local rootPanel = KARDS.CardEditor.Canvas.RootPanel
    local oldEntry = KARDS.CardEditor.Canvas._historyTextEntry
    if inputState.active then
        if not oldEntry or not IsValid(oldEntry) then
            local entry = vgui.Create("DTextEntry", rootPanel)
            entry:SetPos(inputX, inputTopY)
            entry:SetSize(inputW, inputH2)
            entry:SetText(inputState.text or "")
            entry:SetMultiline(true)
            entry:SetVerticalScrollbarEnabled(true)
            entry:SetAllowNonAsciiCharacters(true)
            entry:SetDrawBackground(false)
            entry:SetDrawBorder(false)
            entry:SetTextColor(Color(255, 255, 255, 0))
            entry:SetCursorColor(Color(255, 255, 255, 0))
            entry.Paint = nil
            entry:RequestFocus()

            entry.OnTextChanged = function(self)
                local txt = self:GetText()
                if inputState then
                    inputState.text = txt
                    app.historyText = txt
                end
                -- 尺寸由 DrawHistoryEditArea 每帧同步统一管理，此处不做 SetSize
            end

            -- 保存原始 OnKeyCodeTyped 引用（来自 DTextEntry 元表的 TextEntry.OnKeyCodeTyped）
            local baseOnKeyCodeTyped = entry.OnKeyCodeTyped
            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    if inputState then
                        inputState.active = false
                    end
                elseif keyCode == KEY_ENTER then
                    -- Enter 换行：手动插入 \n 替代依赖基类处理
                    local txt = self:GetText() or ""
                    local caret = self:GetCaretPos()
                    if not caret or caret < 0 then caret = utf8.len(txt) end
                    self:SetText(utf8.sub(txt, 1, caret) .. "\n" .. utf8.sub(txt, caret + 1))
                    self:SetCaretPos(caret + 1)
                else
                    -- 其他键由默认处理器接管
                    baseOnKeyCodeTyped(self, keyCode)
                end
            end

            KARDS.CardEditor.Canvas._historyTextEntry = entry
        else
            if not oldEntry:HasFocus() then
                oldEntry:RequestFocus()
            end
            oldEntry:SetPos(inputX, inputTopY)
            oldEntry:SetSize(inputW, inputH2)
        end
    else
        if oldEntry and IsValid(oldEntry) then
            oldEntry:Remove()
        end
        KARDS.CardEditor.Canvas._historyTextEntry = nil
    end
    -- 创建后同步 DTextEntry 尺寸与滚动条
    local dte = KARDS.CardEditor.Canvas._historyTextEntry
    if dte and IsValid(dte) then
        local dw, dh = dte:GetSize()
        if dw ~= inputW or dh ~= inputH2 then
            dte:SetSize(inputW, inputH2)
        end
        -- 仅当需要滚动时才显示滚动条
        dte:SetVerticalScrollbarEnabled(needsScroll)
    end

    -- ========== 历史 URL 输入框 DTextEntry 生命周期管理 ==========
    local hisUrlState = KARDS.CardEditor.Canvas._historyUrlInputState or {}
    local oldHisUrlEntry = KARDS.CardEditor.Canvas._historyUrlTextEntry
    if hisUrlState.active and hisUrlState.inputRect then
        local ur = hisUrlState.inputRect
        if not oldHisUrlEntry or not IsValid(oldHisUrlEntry) then
            local entry = vgui.Create("DTextEntry", rootPanel)
            entry:SetPos(ur.x, ur.y)
            entry:SetSize(ur.w, ur.h)
            entry:SetText(hisUrlState.text or "")
            hisUrlState.caretPos = utf8.len(hisUrlState.text or "") or 0
            entry:SetDrawBackground(false)
            entry:SetDrawBorder(false)
            entry:SetTextColor(Color(255, 255, 255, 0))
            entry:SetCursorColor(Color(255, 255, 255, 0))
            entry.Paint = nil
            entry:RequestFocus()
            entry.OnTextChanged = function(self)
                local txt = self:GetText()
                local hs = KARDS.CardEditor.Canvas._historyUrlInputState
                if hs then
                    hs.text = txt
                    if self.GetCaretPos then
                        local cp = self:GetCaretPos()
                        if cp ~= nil then hs.caretPos = cp end
                    end
                    if txt and txt ~= "" then
                        StartHistoryImageDownload(txt)
                    end
                end
            end
            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    local hs = KARDS.CardEditor.Canvas._historyUrlInputState
                    if hs then hs.active = false end
                end
            end
            KARDS.CardEditor.Canvas._historyUrlTextEntry = entry
        else
            if not oldHisUrlEntry:HasFocus() then
                oldHisUrlEntry:RequestFocus()
            end
            if oldHisUrlEntry.GetCaretPos then
                local cp = oldHisUrlEntry:GetCaretPos()
                if cp ~= nil then hisUrlState.caretPos = cp end
            end
            oldHisUrlEntry:SetPos(ur.x, ur.y)
            oldHisUrlEntry:SetSize(ur.w, ur.h)
        end
    else
        if oldHisUrlEntry and IsValid(oldHisUrlEntry) then
            oldHisUrlEntry:Remove()
        end
        KARDS.CardEditor.Canvas._historyUrlTextEntry = nil
     end

    -- 悬停预览最后绘制（最高层，避免被底部预览框等后续内容遮挡）
    DrawHistoryHoverPreview()
end

-- ===== 稀有度编辑区（Apple pill chip） =====
function DrawRarityEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    local anchorX = trX + 15
    local anchorY = trY + 15
    draw.SimpleText(T("editor.appearance.card_rarity"), "SourceHan_Heavy_16", anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    KARDS.CardEditor.Canvas.DrawUnstableWarnAfterTitle(anchorX, anchorY, T("editor.appearance.card_rarity"), "SourceHan_Heavy_16", mx, my)

    local rarities = {
        { id = "normal",  name = T("editor.appearance.rarity_normal"),   desc = T("editor.appearance.rarity_normal_desc"), color = Color(160, 160, 160) },
        { id = "limited", name = T("editor.appearance.rarity_limited"),   desc = T("editor.appearance.rarity_limited_desc"), color = Color(60, 180, 60) },
        { id = "special", name = T("editor.appearance.rarity_special"),   desc = T("editor.appearance.rarity_special_desc"), color = Color(60, 120, 200) },
        { id = "elite",   name = T("editor.appearance.rarity_elite"),   desc = T("editor.appearance.rarity_elite_desc"), color = Color(200, 120, 40) },
    }

    local chipW = math.min(140, trW - 30)
    local chipH = 28
    local chipGap = 8
    local startY = anchorY + 26

    for i, r in ipairs(rarities) do
        local bx = anchorX
        local by = startY + (i - 1) * (chipH + chipGap)
        local isHov = IsMouseIn(mx, my, bx, by, chipW, chipH)
        local isSel = app.quality == r.id

        if isHov then
            KARDS.CardEditor.Canvas.SuggestionText = r.desc
        end

        -- Apple pill chip 风格（所有选中项统一使用 Apple Blue；2026-08-16：
        -- 品质图标，materials/kards/icons/quality_*.png）
        DrawApplePillChip(bx, by, chipW, chipH, r.name, isSel, isHov, APPLE_RADII.pill, true,
            "materials/kards/icons/quality_" .. r.id .. ".png")

        if isHov and isLeftPressed then
            app.quality = r.id
            KARDS.CardEditor.Canvas.SuggestionText = T("editor.appearance.current_rarity_prefix") .. r.name
        end
    end
end

-- Apple 建议提示板（footer 风格 - parchment 背景 + fine-print 文字）
function DrawSuggestionBoard(x, y, w, h, mx, my)
    draw.RoundedBox(APPLE_RADII.sm, x + 2, y + 2, w - 4, h - 4, APPLE_PARCHMENT)
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawOutlinedRect(x + 2, y + 2, w - 4, h - 4)
    draw.SimpleText(T("editor.appearance.suggestion"), "SourceHan_Heavy_14", x + APPLE_SPACE.sm, y + APPLE_SPACE.xs, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local text = KARDS.CardEditor.Canvas.SuggestionText
    if text and #text > 0 then
        surface.SetFont("SourceHan_Heavy_14")
        local maxW = w - APPLE_SPACE.md * 2
        local lineY = y + APPLE_SPACE.lg
        local currentLine = ""
        local i = 1
        while i <= #text do
            local byte = string.byte(text, i)
            local charLen = 1
            if byte >= 0xE0 then charLen = 3 elseif byte >= 0xC0 then charLen = 2 end
            local char = string.sub(text, i, i + charLen - 1)
            local testLine = currentLine .. char
            local tw = surface.GetTextSize(testLine)
            if tw > maxW and #currentLine > 0 then
                draw.SimpleText(currentLine, "SourceHan_Heavy_14", x + APPLE_SPACE.sm, lineY, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
                lineY = lineY + 18
                currentLine = char
            else
                currentLine = testLine
            end
            i = i + charLen
        end
        if #currentLine > 0 then
            draw.SimpleText(currentLine, "SourceHan_Heavy_14", x + APPLE_SPACE.sm, lineY, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end
    else
        draw.SimpleText(T("editor.appearance.hover_for_details"), "SourceHan_Heavy_14", x + APPLE_SPACE.sm, y + APPLE_SPACE.xl, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end

    -- 建议图（2026-08-16）：悬停的按钮上报 SuggestionImage 时，在左下角空位按
    -- 原始大小绘制（不缩放、无底衬）
    local imgPath = KARDS.CardEditor.Canvas.SuggestionImage
    if imgPath then
        local bg = GetBgMatSize(imgPath)
        local pad = APPLE_SPACE.sm
        local dx = x + pad
        local dy = y + h - pad - bg.ih
        surface.SetMaterial(bg.mat)
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRect(dx, dy, bg.iw, bg.ih)
    end
end

-- ===================== Apple 总控台 =====================
-- 卡牌总类型规则（readme.md 7.1）：悬停或点击总控台卡类型 chip 时写入 SuggestionText
local CARD_TYPE_RULES = {
    unit            = T("editor.appearance.rule_unit"),
    command         = T("editor.appearance.rule_command"),
    counter_command = T("editor.appearance.rule_counter"),
    headquarter     = T("editor.appearance.rule_headquarters"),
}

function DrawControlPanel(cpX, cpY, cpW, cpH, app, mx, my, isLeftPressed)
    -- Apple 风格总控台背景（白色画布 + hairline 边框）
    draw.RoundedBox(APPLE_RADII.sm, cpX + 2, cpY + 2, cpW - 4, cpH - 4, APPLE_WHITE)
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawOutlinedRect(cpX + 2, cpY + 2, cpW - 4, cpH - 4)

    -- Apple 标题
    draw.SimpleText(T("editor.appearance.control_panel"), "SourceHan_Heavy_16", cpX + cpW / 2, cpY + APPLE_SPACE.xs, APPLE_INK, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

    -- ===== Apple configurator-option-chip 风格：卡牌总类型 =====
    local typeTitleY = cpY + 35
    draw.SimpleText(T("editor.appearance.card_type"), "SourceHan_Heavy_14", cpX + APPLE_SPACE.sm, typeTitleY, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local typeOptions = {
        { name = T("editor.appearance.unit"), id = "unit" },
        { name = T("editor.appearance.command"), id = "command" },
        { name = T("editor.appearance.counter"), id = "counter_command" },
        { name = T("editor.appearance.headquarters"), id = "headquarter" },
    }

    -- 确定当前总类型
    local currentOverallType = "unit"
    if app.cardType == "command" then
        currentOverallType = "command"
    elseif app.cardType == "counter_command" then
        currentOverallType = "counter_command"
    elseif app.cardType == "headquarter" then
        currentOverallType = "headquarter"
    end

    local blockW = cpW - 16
    local blockH = 36
    local blockGapY = 6
    local blockStartY = typeTitleY + 24

    for i, opt in ipairs(typeOptions) do
        local bx = cpX + APPLE_SPACE.xs
        local by = blockStartY + (i - 1) * (blockH + blockGapY)
        local isHov = IsMouseIn(mx, my, bx, by, blockW, blockH)
        local isSel = currentOverallType == opt.id

        -- Apple pill chip 风格
        local bgColor, txtColor
        if isSel then
            bgColor = isHov and APPLE_BLUE_HOVER or APPLE_BLUE
            txtColor = APPLE_TEXT_ON_BLUE
        else
            bgColor = isHov and APPLE_DARK_HOVER or APPLE_PARCHMENT
            txtColor = APPLE_INK
        end

        draw.RoundedBox(APPLE_RADII.pill, bx, by, blockW, blockH, bgColor)
        draw.SimpleText(opt.name, "SourceHan_Heavy_14", bx + blockW / 2, by + blockH / 2, txtColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        -- 悬停时把该卡类型规则写入 SuggestionText（readme 7.1）
        if isHov and not isLeftPressed then
            KARDS.CardEditor.Canvas.SuggestionText = CARD_TYPE_RULES[opt.id] or (T("editor.appearance.current_category_prefix") .. opt.name)
        end

        -- 点击切换
        if isHov and isLeftPressed then
            if opt.id == "unit" and currentOverallType ~= "unit" then
                app.cardType = "infantry"
                app.veteranAppearance.cardType = "infantry"
                KARDS.CardEditor.Canvas.SuggestionText = CARD_TYPE_RULES.unit
            elseif opt.id == "command" then
                app.cardType = "command"
                app.veteranAppearance.cardType = "command"
                KARDS.CardEditor.Canvas.SuggestionText = CARD_TYPE_RULES.command
                -- 非单位模式：清除单位专属词条
                local allowed = { intel = true, cooperation = true, forecast = true }
                local filtered = {}
                for _, kid in ipairs(app.keywords) do
                    if allowed[kid] then table.insert(filtered, kid) end
                end
                app.keywords = filtered
                if app.keywordValues then
                    for k, _ in pairs(app.keywordValues) do
                        if not allowed[k] then app.keywordValues[k] = nil end
                    end
                end
            elseif opt.id == "counter_command" then
                app.cardType = "counter_command"
                app.veteranAppearance.cardType = "counter_command"
                KARDS.CardEditor.Canvas.SuggestionText = CARD_TYPE_RULES.counter_command
                -- 非单位模式：清除单位专属词条
                local allowed = { intel = true, cooperation = true, forecast = true }
                local filtered = {}
                for _, kid in ipairs(app.keywords) do
                    if allowed[kid] then table.insert(filtered, kid) end
                end
                app.keywords = filtered
                if app.keywordValues then
                    for k, _ in pairs(app.keywordValues) do
                        if not allowed[k] then app.keywordValues[k] = nil end
                    end
                end
            elseif opt.id == "headquarter" then
                app.cardType = "headquarter"
                app.veteranAppearance.cardType = "headquarter"
                KARDS.CardEditor.Canvas.SuggestionText = CARD_TYPE_RULES.headquarter
                -- 总部：无词条（词条书签不可编辑），清空所有词条
                app.keywords = {}
                -- 总部默认防御力 20（仅当防御力为空/0 时填充，保留已编辑的防御力）
                if not (app.defense and app.defense > 0) then
                    app.defense = 20
                end
            end
            -- 总类型变更后重新分配部署/攻击音效（单位按类型×规模；指令/反制/总部清除）
            KARDS.CardSounds.AutoAssignDeploySound(app)
            KARDS.CardSounds.AutoAssignAttackSound(app)
            KARDS.CardEditor.Canvas.EditorMode = opt.id
            local INE = KARDS.CardEditor.IndependentNodeEditor
            if INE and INE.Editors["card_effect_editor"] then
                INE:CloseEditor("card_effect_editor")
            end
        end
    end

    -- ===== Apple 按钮（button-primary pill 风格） =====
    local btnW = math.max(60, cpW - 16)
    local btnH = 32
    local btnGap = 8

    -- 从底部往上排列三个按钮
    local uploadBtnY = cpY + cpH - btnH - 8
    local testBtnY = uploadBtnY - btnH - btnGap
    local renderBtnY = testBtnY - btnH - btnGap

    -- 渲染按钮（button-primary）
    local renderBtnHov = IsMouseIn(mx, my, cpX + APPLE_SPACE.xs, renderBtnY, btnW, btnH)
    draw.RoundedBox(APPLE_RADII.pill, cpX + APPLE_SPACE.xs, renderBtnY, btnW, btnH, renderBtnHov and APPLE_BLUE_HOVER or APPLE_BLUE)
    draw.SimpleText(T("editor.appearance.render"), "SourceHan_Heavy_14", cpX + APPLE_SPACE.xs + btnW / 2, renderBtnY + btnH / 2, APPLE_TEXT_ON_BLUE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    if renderBtnHov and isLeftPressed then
        local result = KARDS.CardEditor.Canvas.RenderAndSaveCard(app)
        surface.PlaySound("buttons/button14.wav")
        if result and result.fullMaterial then
            KARDS.CardEditor.Canvas.LastRenderedMaterial = result.fullMaterial
        end
        -- 无属性文字模板卡面（3D2D文字卡生成用）与渲染尺寸缓存
        if result and result.templateMaterial then
            KARDS.CardEditor.Canvas.LastRenderedTemplateMaterial = result.templateMaterial
            KARDS.CardEditor.Canvas.LastRenderedCardSize = {
                w = result.renderWidth or 300,
                h = result.renderHeight or 400,
            }
        end
    end

    -- 生成按钮（分割为两半）：左半「全图像生成」= 完整卡面（属性文字烘焙进纹理）；
    -- 右半「3D2D文字卡」= 无属性文字模板卡面 + 3D2D 文字实时悬浮叠加（属性随卡牌变化）
    local btnGap2 = 4
    local btnHalfW = math.floor((btnW - btnGap2) / 2)
    local fullBtnX = cpX + APPLE_SPACE.xs
    local textBtnX = fullBtnX + btnHalfW + btnGap2
    local hasFullMat = KARDS.CardEditor.Canvas.LastRenderedMaterial ~= nil
    local hasTextMat = KARDS.CardEditor.Canvas.LastRenderedTemplateMaterial ~= nil

    -- 左半：全图像生成（有完整卡面材质时才可点击）
    local fullBtnHov = IsMouseIn(mx, my, fullBtnX, testBtnY, btnHalfW, btnH)
    draw.RoundedBox(APPLE_RADII.pill, fullBtnX, testBtnY, btnHalfW, btnH, hasFullMat and (fullBtnHov and APPLE_BLUE_HOVER or APPLE_BLUE) or APPLE_DARK_DISABLED)
    draw.SimpleText(T("editor.appearance.full_image"), "SourceHan_Heavy_14", fullBtnX + btnHalfW / 2, testBtnY + btnH / 2, hasFullMat and APPLE_TEXT_ON_BLUE or APPLE_INK_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if hasFullMat and fullBtnHov and isLeftPressed then
        KARDS.CardEditor.Canvas.SpawnTestEntity(app, "full")
        surface.PlaySound("buttons/button14.wav")
    end

    -- 右半：3D2D文字卡生成（有模板卡面材质时才可点击）
    local textBtnHov = IsMouseIn(mx, my, textBtnX, testBtnY, btnHalfW, btnH)
    draw.RoundedBox(APPLE_RADII.pill, textBtnX, testBtnY, btnHalfW, btnH, hasTextMat and (textBtnHov and APPLE_BLUE_HOVER or APPLE_BLUE) or APPLE_DARK_DISABLED)
    draw.SimpleText(T("editor.appearance.text_card_3d2d"), "SourceHan_Heavy_14", textBtnX + btnHalfW / 2, testBtnY + btnH / 2, hasTextMat and APPLE_TEXT_ON_BLUE or APPLE_INK_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if hasTextMat and textBtnHov and isLeftPressed then
        KARDS.CardEditor.Canvas.SpawnTestEntity(app, "3d2d")
        surface.PlaySound("buttons/button14.wav")
    end

    -- 上传按钮（disabled 状态）
    local uploadBtnHov = IsMouseIn(mx, my, cpX + APPLE_SPACE.xs, uploadBtnY, btnW, btnH)
    draw.RoundedBox(APPLE_RADII.pill, cpX + APPLE_SPACE.xs, uploadBtnY, btnW, btnH, APPLE_DARK_DISABLED)
    draw.SimpleText(T("editor.appearance.upload"), "SourceHan_Heavy_14", cpX + APPLE_SPACE.xs + btnW / 2, uploadBtnY + btnH / 2, APPLE_INK_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- Apple 风格预览区
function DrawPreviewArea(x, y, w, h, app, mx, my, isLeftPressed)
    -- 卡牌预览 - 高度为编辑器总高度的1/3，保持宽高比
    local totalEditorH = KARDS.CardEditor.Canvas.TotalEditorH or 720
    local prevH = math.floor(totalEditorH / 3)
    local prevW = math.min(math.floor(prevH * 3 / 4), math.floor(w * 0.4))
    local prevX = x + APPLE_SPACE.sm
    local prevY = y + APPLE_SPACE.xxs

    -- 计算卡面预览缩放因子（用于滚轮缩放等计算，DrawCardPreview 内部已使用相同逻辑）
    local frontScaleFactor = KARDS.CardEditor.Canvas.ComputeCardScaleFactor(app, prevH)

    KARDS.CardEditor.Canvas.DrawCardPreview(app, prevX, prevY, prevW, prevH)

    -- 滚轮缩放检测（以鼠标为缩放点）
    local slot = KARDS.CardEditor.Canvas._lastCardImageSlot
    local wheelIn = KARDS.CardEditor.Canvas._wheelZoomIn
    local wheelOut = KARDS.CardEditor.Canvas._wheelZoomOut
    -- 检测鼠标是否在卡牌预览区域内
    local inFrontPreview = mx >= prevX and mx <= prevX + prevW and
                           my >= prevY and my <= prevY + prevH
    if inFrontPreview and slot and slot.texW and slot.texH then
        local zoomFactor = wheelIn and 1.1 or (wheelOut and 1/1.1 or nil)
        if zoomFactor then
            KARDS.CardEditor.Canvas._wheelZoomIn = false
            KARDS.CardEditor.Canvas._wheelZoomOut = false
            local oldScale = app.imageScale or 1
            local newScale = math.Clamp(oldScale * zoomFactor, 0.2, 4)

            -- 缩放前图片在屏幕上的位置（与 DrawCardImage 中的计算一致）
            local oldRenderScale = 0.25 * frontScaleFactor * oldScale
            local oldImgW = slot.texW * oldRenderScale
            local oldImgH = slot.texH * oldRenderScale
            local oldImgX = slot.x + (slot.w - oldImgW) / 2 + (app.imageOffsetX or 0) * frontScaleFactor
            local oldImgY = slot.y + (slot.h - oldImgH) / 2 + (app.imageOffsetY or 0) * frontScaleFactor

            -- 鼠标在图片内的相对位置 (0~1)
            local relX = (mx - oldImgX) / oldImgW
            local relY = (my - oldImgY) / oldImgH

            -- 缩放后图片在屏幕上的位置，保持鼠标点固定
            local newRenderScale = 0.25 * frontScaleFactor * newScale
            local newImgW = slot.texW * newRenderScale
            local newImgH = slot.texH * newRenderScale
            local newImgX = mx - relX * newImgW
            local newImgY = my - relY * newImgH

            -- 转换回模板空间偏移
            app.imageScale = newScale
            app.imageOffsetX = (newImgX - slot.x - (slot.w - newImgW) / 2) / frontScaleFactor
            app.imageOffsetY = (newImgY - slot.y - (slot.h - newImgH) / 2) / frontScaleFactor
        end
    end

    -- 卡背预览 - 同样高度为1/3，保持相同宽高比
    local cardbackX = prevX + prevW + APPLE_SPACE.md
    local cardbackY = prevY
    local cardbackW = prevW
    local cardbackH = prevH

    -- Apple 白色卡片背景 + hairline 边框
    draw.RoundedBox(APPLE_RADII.sm, cardbackX, cardbackY, cardbackW, cardbackH, APPLE_WHITE)
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawOutlinedRect(cardbackX, cardbackY, cardbackW, cardbackH)

    local countryName = string.lower(app.country)
    local cardbackPath = "materials/kards/cardbacks/" .. countryName .. ".png"
    local cardbackMat = Material(cardbackPath, "noclamp smooth")
    if cardbackMat and not cardbackMat:IsError() then
        local tempApp = {
            name = "", cost = 0, actionCost = 0, country = app.country, cardType = "infantry",
            attack = 0, defense = 0, quality = "normal", keywords = {}, keywordValues = {},
            specialEffect = "", imagePath = "", cardTemplate = "custom",
            customTemplatePath = cardbackPath, nameIsBlack = false, nameFontSize = 36,
            descFontSize = 20, nameIsEnglish = false, imageOffsetX = 0, imageOffsetY = 0, imageScale = 1
        }
        local oldCP = KARDS.CardEditor.Canvas.ImagePaths.template.custom
        KARDS.CardEditor.Canvas.ImagePaths.template.custom = cardbackPath
        KARDS.CardEditor.Canvas.DrawCardPreview(tempApp, cardbackX, cardbackY, cardbackW, cardbackH, true)
        KARDS.CardEditor.Canvas.ImagePaths.template.custom = oldCP
    else
        draw.SimpleText(T("editor.appearance.cardback_not_found"), "SourceHan_Heavy_12", cardbackX + cardbackW / 2, cardbackY + cardbackH / 2 - 10, APPLE_INK_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(cardbackPath, "SourceHan_Heavy_10", cardbackX + cardbackW / 2, cardbackY + cardbackH / 2 + 10, APPLE_INK_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- 渲染材质预览（Apple 白色卡片风格）
    if KARDS.CardEditor.Canvas.LastRenderedMaterial then
        local matPrevX = prevX
        local matPrevY = prevY + prevH + APPLE_SPACE.xxs
        local matPrevH = h - (matPrevY - y) - APPLE_SPACE.xxs
        if matPrevH > 20 then
            local matPrevW = prevW
            draw.RoundedBox(APPLE_RADII.sm, matPrevX, matPrevY, matPrevW, matPrevH, APPLE_WHITE)
            surface.SetDrawColor(APPLE_HAIRLINE)
            surface.DrawOutlinedRect(matPrevX, matPrevY, matPrevW, matPrevH)
            surface.SetMaterial(KARDS.CardEditor.Canvas.LastRenderedMaterial)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.DrawTexturedRect(matPrevX + APPLE_SPACE.xxs, matPrevY + APPLE_SPACE.lg, matPrevW - APPLE_SPACE.xs, matPrevH - APPLE_SPACE.xl)
            draw.SimpleText(T("editor.appearance.render_preview"), "SourceHan_Heavy_12", matPrevX + matPrevW / 2, matPrevY + APPLE_SPACE.xxs, APPLE_INK_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        end
    end

    -- 老兵预览（Apple 白色卡片风格）- 位于卡背预览右侧，中间有右箭头
    local isUnit = app.cardType == "infantry" or app.cardType == "tank" or app.cardType == "artillery" or app.cardType == "fighter" or app.cardType == "bomber"
    local showVeteran = isUnit and table.HasValue(app.keywords or {}, "can_elevate_to_veteran")

    if showVeteran then
        -- 老兵预览图：使用与主卡牌预览相同的缩放（相同高度）
        local vetCardH = prevH -- 与主预览高度一致，确保缩放相同
        local vetCardW = math.floor(vetCardH * 3 / 4)
        local vetPrevH2 = vetCardH + 16 -- 容器高度 = 卡面 + 标题
        local vetPrevW = vetCardW

        -- 老兵预览位置：与卡背之间留一个卡牌宽的空隙，中间放大箭头
        local arrowFont = "SourceHan_Heavy_36"
        local arrowW = 36 -- 箭头占用宽度
        local gapWidth = cardbackW -- 卡背与老兵之间的空隙宽度（一个卡牌宽）
        local vetPrevX2 = cardbackX + cardbackW + gapWidth

        -- 如果空间不足，逐步压缩空隙
        local rightEdgeLimit = x + w - APPLE_SPACE.xs
        if vetPrevX2 + vetPrevW > rightEdgeLimit then
            -- 先减空隙到最小可接受值（箭头宽 + 两侧 padding）
            local minGap = arrowW + APPLE_SPACE.sm * 2
            gapWidth = math.max(minGap, (rightEdgeLimit - cardbackX - cardbackW - vetPrevW))
            vetPrevX2 = cardbackX + cardbackW + gapWidth
            -- 如果还超出，缩小老兵卡牌
            if vetPrevX2 + vetPrevW > rightEdgeLimit then
                local maxVetW = rightEdgeLimit - vetPrevX2
                vetPrevW = math.max(60, maxVetW)
                vetCardW = vetPrevW
                vetCardH = math.floor(vetCardW * 4 / 3)
                vetPrevH2 = vetCardH + 16
            end
        end

        -- 箭头居中于空隙
        local arrowX = (cardbackX + cardbackW + vetPrevX2) / 2
        local arrowY = prevY + prevH / 2
        draw.SimpleText("→", arrowFont, arrowX, arrowY, APPLE_BLUE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        -- 白色卡片背景 + hairline 边框
        draw.RoundedBox(APPLE_RADII.sm, vetPrevX2, prevY, vetPrevW, vetPrevH2, APPLE_WHITE)
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawOutlinedRect(vetPrevX2, prevY, vetPrevW, vetPrevH2)

        -- 标题
        draw.SimpleText(T("editor.appearance.veteran"), "SourceHan_Heavy_12", vetPrevX2 + vetPrevW / 2, prevY + 2, APPLE_INK_MUTED80, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        local vetApp = table.Copy(app.veteranAppearance)
        -- 插图位置/缩放与主卡牌共享（调试时同步）
        vetApp.imagePath = app.imagePath
        vetApp.imageOffsetX = app.imageOffsetX or 0
        vetApp.imageOffsetY = app.imageOffsetY or 0
        vetApp.imageScale = app.imageScale or 1
        vetApp.cardTemplate = app.cardTemplate
        vetApp.customTemplatePath = app.customTemplatePath
        vetApp.cardType = app.cardType
        vetApp.country = app.country
        vetApp.name = app.name
        vetApp.quality = app.quality
        vetApp.nameIsBlack = app.nameIsBlack
        vetApp.nameFontSize = app.nameFontSize
        vetApp.nameIsEnglish = app.nameIsEnglish
        if vetApp.keywords == nil then vetApp.keywords = {} end
        if not table.HasValue(vetApp.keywords, "veteran") then
            table.insert(vetApp.keywords, 1, "veteran")
        end
        KARDS.CardEditor.Canvas.DrawCardPreview(vetApp, vetPrevX2, prevY + 16, vetCardW, vetCardH)
    end
end

-- ====================================
-- 钳击输入框状态（DTextEntry IME 兼容方案）
-- ====================================
KARDS.CardEditor.Canvas.PincerInputState = {
    active = false,
    text = "",
    x = 0, y = 0, w = 0, h = 0,
}
KARDS.CardEditor.Canvas._pincerTextEntry = nil

-- 钳击输入框 DTextEntry 生命周期管理（Think 钩子，支持 IME 中文输入）
if CLIENT and not KARDS.CardEditor.Canvas._pincerThinkHooked then
    KARDS.CardEditor.Canvas._pincerThinkHooked = true
    hook.Add("Think", "KARDS_PincerInputThink", function()
        local state = KARDS.CardEditor.Canvas.PincerInputState
        if not state then return end
        local entry = KARDS.CardEditor.Canvas._pincerTextEntry
        local rootPanel = KARDS.CardEditor.Canvas.RootPanel
        
        if state.active then
            if not entry or not IsValid(entry) then
                if not rootPanel then return end
                local textEntry = vgui.Create("DTextEntry", rootPanel)
                textEntry:SetPos(state.x, state.y)
                textEntry:SetSize(state.w, state.h)
                textEntry:SetText(state.text or "")
                textEntry:SetCaretPos(#(state.text or ""))
                textEntry:SetDrawBackground(false)
                textEntry:SetDrawBorder(false)
                textEntry:SetTextColor(Color(255, 255, 255, 0))
                textEntry:SetCursorColor(Color(255, 255, 255, 0))
                textEntry.Paint = nil
                textEntry:MakePopup()
                textEntry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    local s = KARDS.CardEditor.Canvas.PincerInputState
                    if s then
                        s.text = txt
                        local app = KARDS.CardEditor.Canvas.CardAppearance
                        if app then
                            app.pincerValue = txt
                        end
                    end
                end
                textEntry.OnKeyCodeTyped = function(self, keyCode)
                    if keyCode == KEY_ESCAPE then
                        local s = KARDS.CardEditor.Canvas.PincerInputState
                        if s then s.active = false end
                    end
                end
                KARDS.CardEditor.Canvas._pincerTextEntry = textEntry
            else
                -- 更新位置
                entry:SetPos(state.x, state.y)
                entry:SetSize(state.w, state.h)
                -- 同步文本：切换卡片时 DTextEntry 可能残留旧文本
                local expected = state.text or ""
                if entry:GetText() ~= expected then
                    entry:SetText(expected)
                    entry:SetCaretPos(#expected)
                end
                if not entry:HasFocus() then
                    entry:MakePopup()
                end
            end
        else
            if entry and IsValid(entry) then
                entry:Remove()
            end
            KARDS.CardEditor.Canvas._pincerTextEntry = nil
        end
    end)
end

-- 从 URL 下载图片并写入本地缓存
function StartImageDownload(url)
    if not url or url == "" then return end

    local dlState = KARDS.CardEditor.Canvas._imageDownloadState
    dlState.status = "downloading"
    dlState.errorMsg = ""

    http.Fetch(url, function(body, len)
        -- 生成唯一文件名，写入 data/ （Material 用 ../data/ 加载）
        local fileName = "kards_images/img_" .. util.CRC(url) .. ".png"
        file.Write(fileName, body)

        dlState.status = "success"
        dlState.downloadedPath = fileName

        -- 更新 CardAppearance.imagePath 并自动缩放重置
        local app = KARDS.CardEditor.Canvas.CardAppearance
        if app then
            app.imagePath = "../data/" .. fileName
            -- 预热缓存 + 自动缩放至填充预览槽 + 重置偏移
            app.imageScale = KARDS.CardEditor.Canvas.AutoFitImageScale(app.imagePath, app)
            app.imageOffsetX = 0
            app.imageOffsetY = 0
        end
    end, function(error)
        dlState.status = "error"
        dlState.errorMsg = tostring(error)
    end)
end

-- ================================================================
-- 通用透明输入框（管理/伤害页共用，DTextEntry IME 兼容方案）
-- 与 PincerInputState 相同的生命周期模式：激活时创建透明 DTextEntry，
-- Think 钩子每帧同步位置/文本，失焦或 ESC/Enter 时提交 onCommit。
-- ================================================================
KARDS.CardEditor.Canvas._uiInputState = {
    active = false,
    id = nil,       -- 输入框标识："rv_label" / "rv_id" / "dmg_mult"
    path = nil,     -- 附加数据（倍率规则的目标/来源路径）
    text = "",
    x = 0, y = 0, w = 0, h = 0,
    onCommit = nil, -- 提交回调 function(text)，失焦/ESC/Enter 时调用
}
KARDS.CardEditor.Canvas._uiTextEntry = nil

if CLIENT and not KARDS.CardEditor.Canvas._uiInputThinkHooked then
    KARDS.CardEditor.Canvas._uiInputThinkHooked = true
    hook.Add("Think", "KARDS_UIInputThink", function()
        local state = KARDS.CardEditor.Canvas._uiInputState
        if not state then return end
        local entry = KARDS.CardEditor.Canvas._uiTextEntry
        local rootPanel = KARDS.CardEditor.Canvas.RootPanel

        if state.active then
            if not entry or not IsValid(entry) then
                if not rootPanel then return end
                local textEntry = vgui.Create("DTextEntry", rootPanel)
                textEntry:SetPos(state.x, state.y)
                textEntry:SetSize(state.w, state.h)
                textEntry:SetText(state.text or "")
                textEntry:SetCaretPos(#(state.text or ""))
                textEntry:SetDrawBackground(false)
                textEntry:SetDrawBorder(false)
                textEntry:SetTextColor(Color(255, 255, 255, 0))
                textEntry:SetCursorColor(Color(255, 255, 255, 0))
                textEntry.Paint = nil
                textEntry:MakePopup()
                textEntry.OnTextChanged = function(self)
                    local s = KARDS.CardEditor.Canvas._uiInputState
                    if s then s.text = self:GetText() end
                end
                local function commit(s)
                    if not s or not s.active then return end
                    s.active = false
                    local cb = s.onCommit
                    s.onCommit = nil
                    if cb then
                        local ok, err = pcall(cb, s.text)
                        if not ok then
                            print(T("editor.appearance.uiinput_commit_error") .. tostring(err))
                        end
                    end
                end
                textEntry.OnKeyCodeTyped = function(self, keyCode)
                    local s = KARDS.CardEditor.Canvas._uiInputState
                    if keyCode == KEY_ESCAPE or keyCode == KEY_ENTER then
                        commit(s)
                    end
                end
                textEntry.OnLoseFocus = function(self)
                    commit(KARDS.CardEditor.Canvas._uiInputState)
                end
                KARDS.CardEditor.Canvas._uiTextEntry = textEntry
            else
                -- 更新位置与文本（切换卡片/页面时 DTextEntry 可能残留旧内容）
                entry:SetPos(state.x, state.y)
                entry:SetSize(state.w, state.h)
                local expected = state.text or ""
                if entry:GetText() ~= expected then
                    entry:SetText(expected)
                    entry:SetCaretPos(#expected)
                end
                if not entry:HasFocus() then
                    entry:MakePopup()
                end
            end
        else
            if entry and IsValid(entry) then
                entry:Remove()
            end
            KARDS.CardEditor.Canvas._uiTextEntry = nil
        end
    end)
end

-- ================================================================
-- 规则词汇表管理（"管理"书签页）
-- 章节选择 + 选项列表（自定义项可删除）+ 添加自定义规则项
-- ================================================================
KARDS.CardEditor.Canvas._rvState = KARDS.CardEditor.Canvas._rvState or {
    selectedSection = nil, -- 当前章节 ID
    page = 1,              -- 选项列表分页
    labelText = "",        -- 添加区：中文标签
    idText = "",           -- 添加区：内部 ID
}

function DrawManageEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    local anchorX = trX + 15
    local anchorY = trY + 15
    local rvState = KARDS.CardEditor.Canvas._rvState
    local uiState = KARDS.CardEditor.Canvas._uiInputState
    local usableW = trW - 30

    draw.SimpleText(T("editor.appearance.rules_vocabulary_management"), "SourceHan_Heavy_16", anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    KARDS.CardEditor.Canvas.DrawUnstableWarnAfterTitle(anchorX, anchorY, T("editor.appearance.rules_vocabulary_management"), "SourceHan_Heavy_16", mx, my)

    -- 点击输入框外部 → 关闭输入框（后续交互元素可重新激活覆盖）
    if isLeftPressed and uiState.active and not IsMouseIn(mx, my, uiState.x, uiState.y, uiState.w, uiState.h) then
        uiState.active = false
        uiState.id = nil
    end

    -- ===== 章节选择（Apple pill chip 网格） =====
    local sections = KARDS.RulesVocabulary.GetSectionList("zh-CN")
    if #sections == 0 then
        draw.SimpleText(T("editor.appearance.no_rule_sections"), "SourceHan_Heavy_14", anchorX, anchorY + 30, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        return
    end
    if not rvState.selectedSection then
        rvState.selectedSection = sections[1].id
    end

    local chipH = 26
    local chipGap = 8
    local chipsY = anchorY + 24
    local chipX = anchorX
    local maxChipRowY = chipsY
    for _, sec in ipairs(sections) do
        surface.SetFont("SourceHan_Heavy_14")
        local tw = surface.GetTextSize(sec.label)
        local chipW = tw + 20
        if chipX + chipW > anchorX + usableW then
            chipX = anchorX
            chipsY = chipsY + chipH + chipGap
        end
        local isSel = rvState.selectedSection == sec.id
        local isHov = IsMouseIn(mx, my, chipX, chipsY, chipW, chipH)
        DrawApplePillChip(chipX, chipsY, chipW, chipH, sec.label, isSel, isHov, APPLE_RADII.pill, true)
        if isHov and isLeftPressed then
            rvState.selectedSection = sec.id
            rvState.page = 1
        end
        chipX = chipX + chipW + chipGap
        maxChipRowY = math.max(maxChipRowY, chipsY)
    end

    local section = KARDS.RulesVocabulary.Registry[rvState.selectedSection]
    local options = section and KARDS.RulesVocabulary.GetOptions(rvState.selectedSection) or {}
    local allowCustom = section and section.allowCustom or false

    -- ===== 选项列表 =====
    local listTop = maxChipRowY + chipH + 12
    local listBottom = trY + trH - 15 - (allowCustom and 70 or 30)
    local listH = listBottom - listTop
    local rowH = 24
    local maxRows = math.max(1, math.floor(listH / rowH))
    local totalPages = math.max(1, math.ceil(#options / maxRows))
    rvState.page = math.Clamp(rvState.page, 1, totalPages)

    draw.SimpleText(T("editor.appearance.section_options_title"), "SourceHan_Heavy_14", anchorX, listTop, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    local listStartY = listTop + 22

    local pageStart = (rvState.page - 1) * maxRows
    for i = 1, maxRows do
        local idx = pageStart + i
        if idx > #options then break end
        local opt = options[idx]
        local rowY = listStartY + (i - 1) * rowH
        local isHov = IsMouseIn(mx, my, anchorX, rowY, usableW, rowH - 2)
        draw.RoundedBox(4, anchorX, rowY, usableW, rowH - 2, isHov and Color(50, 50, 54) or Color(44, 44, 48))

        local label = opt.label and (opt.label["zh-CN"] or opt.label["en"]) or opt.id
        draw.SimpleText(label, "SourceHan_Heavy_14", anchorX + 6, rowY + (rowH - 2) / 2, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        surface.SetFont("SourceHan_Heavy_12")
        local idText = opt.id
        local idW = surface.GetTextSize(idText)
        local rightPad = opt.isCustom and 58 or 8
        draw.SimpleText(idText, "SourceHan_Heavy_12", anchorX + usableW - rightPad - idW, rowY + (rowH - 2) / 2, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        if opt.isCustom then
            draw.SimpleText(T("editor.appearance.custom"), "SourceHan_Heavy_12", anchorX + usableW - 62, rowY + (rowH - 2) / 2, Color(200, 160, 60), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            local delX = anchorX + usableW - 26
            local delHov = IsMouseIn(mx, my, delX, rowY + 3, 20, rowH - 8)
            draw.RoundedBox(4, delX, rowY + 3, 20, rowH - 8, delHov and Color(160, 60, 60) or Color(110, 50, 50))
            draw.SimpleText("✕", "SourceHan_Heavy_12", delX + 10, rowY + 3 + (rowH - 8) / 2, Color(255, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if delHov and isLeftPressed then
                KARDS.RulesVocabulary.RemoveCustomOption(rvState.selectedSection, opt.id)
            end
        end
    end

    -- 分页导航（选项超一页时）
    if totalPages > 1 then
        local pgY = listBottom - 18
        draw.SimpleText(tostring(rvState.page) .. " / " .. tostring(totalPages), "SourceHan_Heavy_12", anchorX + usableW / 2, pgY, APPLE_INK_MUTED80, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        local prevX = anchorX + usableW / 2 - 50
        local prevHov = IsMouseIn(mx, my, prevX, pgY - 10, 40, 20)
        draw.RoundedBox(4, prevX, pgY - 10, 40, 20, prevHov and Color(100, 100, 100) or Color(80, 80, 80))
        draw.SimpleText(T("editor.appearance.previous_page"), "SourceHan_Heavy_12", prevX + 20, pgY, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if prevHov and isLeftPressed then rvState.page = math.max(1, rvState.page - 1) end

        local nextX = anchorX + usableW / 2 + 10
        local nextHov = IsMouseIn(mx, my, nextX, pgY - 10, 40, 20)
        draw.RoundedBox(4, nextX, pgY - 10, 40, 20, nextHov and Color(100, 100, 100) or Color(80, 80, 80))
        draw.SimpleText(T("editor.appearance.next_page"), "SourceHan_Heavy_12", nextX + 20, pgY, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if nextHov and isLeftPressed then rvState.page = math.min(totalPages, rvState.page + 1) end
    end

    -- ===== 添加自定义规则项（底部） =====
    if allowCustom then
        local addY = trY + trH - 15 - 58
        draw.SimpleText(T("editor.appearance.add_custom_rule"), "SourceHan_Heavy_14", anchorX, addY, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        local inputY = addY + 22
        local inputH = 24
        local gap = 8
        local btnW = 60
        local labelW = math.floor((usableW - gap * 2 - btnW) * 0.55)
        local idW = math.floor((usableW - gap * 2 - btnW) * 0.45)

        -- 标签输入框
        local lblBox = { x = anchorX, y = inputY, w = labelW, h = inputH }
        local lblActive = uiState.active and uiState.id == "rv_label"
        draw.RoundedBox(4, lblBox.x, lblBox.y, lblBox.w, lblBox.h, APPLE_WHITE)
        surface.SetDrawColor(lblActive and APPLE_BLUE or APPLE_HAIRLINE)
        surface.DrawOutlinedRect(lblBox.x, lblBox.y, lblBox.w, lblBox.h)
        local lblText = rvState.labelText or ""
        if lblText == "" then
            draw.SimpleText(T("editor.appearance.chinese_label"), "SourceHan_Heavy_12", lblBox.x + 6, lblBox.y + 5, lblActive and APPLE_INK_MUTED80 or APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        else
            draw.SimpleText(lblText, "SourceHan_Heavy_12", lblBox.x + 6, lblBox.y + 5, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end

        -- ID 输入框
        local idBox = { x = anchorX + labelW + gap, y = inputY, w = idW, h = inputH }
        local idActive = uiState.active and uiState.id == "rv_id"
        draw.RoundedBox(4, idBox.x, idBox.y, idBox.w, idBox.h, APPLE_WHITE)
        surface.SetDrawColor(idActive and APPLE_BLUE or APPLE_HAIRLINE)
        surface.DrawOutlinedRect(idBox.x, idBox.y, idBox.w, idBox.h)
        local idText = rvState.idText or ""
        if idText == "" then
            draw.SimpleText(T("editor.appearance.internal_id_english"), "SourceHan_Heavy_12", idBox.x + 6, idBox.y + 5, idActive and APPLE_INK_MUTED80 or APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        else
            draw.SimpleText(idText, "SourceHan_Heavy_12", idBox.x + 6, idBox.y + 5, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end

        -- 添加按钮
        local btnX = anchorX + labelW + gap + idW + gap
        local btnHov = IsMouseIn(mx, my, btnX, inputY, btnW, inputH)
        draw.RoundedBox(4, btnX, inputY, btnW, inputH, btnHov and Color(60, 130, 200) or Color(50, 110, 170))
        draw.SimpleText(T("editor.appearance.add"), "SourceHan_Heavy_14", btnX + btnW / 2, inputY + inputH / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        -- 点击处理
        if isLeftPressed then
            if IsMouseIn(mx, my, lblBox.x, lblBox.y, lblBox.w, lblBox.h) then
                uiState.active = true
                uiState.id = "rv_label"
                uiState.path = nil
                uiState.text = rvState.labelText or ""
                uiState.x, uiState.y, uiState.w, uiState.h = lblBox.x, lblBox.y, lblBox.w, lblBox.h
                uiState.onCommit = nil
            elseif IsMouseIn(mx, my, idBox.x, idBox.y, idBox.w, idBox.h) then
                uiState.active = true
                uiState.id = "rv_id"
                uiState.path = nil
                uiState.text = rvState.idText or ""
                uiState.x, uiState.y, uiState.w, uiState.h = idBox.x, idBox.y, idBox.w, idBox.h
                uiState.onCommit = nil
            elseif IsMouseIn(mx, my, btnX, inputY, btnW, inputH) then
                local lbl = rvState.labelText or ""
                local iid = rvState.idText or ""
                if lbl ~= "" and iid ~= "" then
                    KARDS.RulesVocabulary.AddCustomOption(rvState.selectedSection, iid, { ["zh-CN"] = lbl, ["en"] = lbl })
                    rvState.labelText = ""
                    rvState.idText = ""
                    -- 按新选项数重算总页数并跳到末页查看新项（totalPages 为添加前旧值，可能少算一页）
                    local newOptions = KARDS.RulesVocabulary.GetOptions(rvState.selectedSection)
                    rvState.page = math.max(1, math.ceil(#newOptions / maxRows))
                end
            end
        end

        -- 输入框文本 → 状态同步（保持 DTextEntry 与状态一致）
        if uiState.active then
            if uiState.id == "rv_label" then
                rvState.labelText = uiState.text
            elseif uiState.id == "rv_id" then
                rvState.idText = uiState.text
            end
        end
    end
end

-- ================================================================
-- 单位伤害倍率配置（"伤害"书签页）
-- 输出倍率/受伤倍率双子页签，基于 Varlib 对象/对象组变量
-- ================================================================
KARDS.CardEditor.Canvas._dmgState = KARDS.CardEditor.Canvas._dmgState or {
    tab = "outgoing",    -- "outgoing" / "incoming"
    page = 1,            -- 规则列表分页
    pickerOpen = false,  -- 添加规则选择器是否展开
    pickerPage = 1,      -- 选择器分页
}

function DrawDamageModifierEditArea(trX, trY, trW, trH, app, mx, my, isLeftPressed, dt)
    local anchorX = trX + 15
    local anchorY = trY + 15
    local dmgState = KARDS.CardEditor.Canvas._dmgState
    local uiState = KARDS.CardEditor.Canvas._uiInputState
    local usableW = trW - 30

    draw.SimpleText(T("editor.appearance.damage_multiplier_config"), "SourceHan_Heavy_16", anchorX, anchorY, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 确保 combatModifiers 结构存在（旧版保存的卡牌可能缺字段）
    app.combatModifiers = app.combatModifiers or { outgoing = {}, incoming = {} }
    app.combatModifiers.outgoing = app.combatModifiers.outgoing or {}
    app.combatModifiers.incoming = app.combatModifiers.incoming or {}

    -- 点击输入框外部 → 关闭输入框
    if isLeftPressed and uiState.active and not IsMouseIn(mx, my, uiState.x, uiState.y, uiState.w, uiState.h) then
        uiState.active = false
        uiState.id = nil
    end

    -- ===== 子页签 =====
    local tabY = anchorY + 24
    local tabs = { { id = "outgoing", name = T("editor.appearance.outgoing_multiplier") }, { id = "incoming", name = T("editor.appearance.incoming_multiplier") } }
    local tabX = anchorX
    for i, tab in ipairs(tabs) do
        surface.SetFont("SourceHan_Heavy_14")
        local tw = surface.GetTextSize(tab.name) + 24
        local isSel = dmgState.tab == tab.id
        local isHov = IsMouseIn(mx, my, tabX, tabY, tw, 24)
        DrawApplePillChip(tabX, tabY, tw, 24, tab.name, isSel, isHov, APPLE_RADII.pill, true)
        if isHov and isLeftPressed then
            dmgState.tab = tab.id
            dmgState.page = 1
        end
        tabX = tabX + tw + 8
    end

    -- ===== 规则列表 =====
    local list = app.combatModifiers[dmgState.tab]
    local listTop = tabY + 34
    local listBottom = trY + trH - 15 - 36 -- 底部预留 [+ 添加规则] 按钮
    local listH = listBottom - listTop
    -- 选择器浮层几何提前计算（2026-10-04）：浮层覆盖列表时，点击不得同时触发下层行操作
    -- （避免删除/调倍率与选择器选择重复响应）
    local addBtnY = trY + trH - 15 - 26
    local pickerH = math.min(200, math.max(60, listH - 40))
    local pickerY = addBtnY - pickerH - 6
    local pickerBlocksClick = dmgState.pickerOpen
        and IsMouseIn(mx, my, anchorX, pickerY, usableW, pickerH)
    local rowH = 24
    local maxRows = math.max(1, math.floor(listH / rowH))
    local totalPages = math.max(1, math.ceil(#list / maxRows))
    dmgState.page = math.Clamp(dmgState.page, 1, totalPages)

    draw.SimpleText(T("editor.appearance.type"), "SourceHan_Heavy_12", anchorX, listTop, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText(T("editor.appearance.target_source"), "SourceHan_Heavy_12", anchorX + 90, listTop, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText(T("editor.appearance.multiplier"), "SourceHan_Heavy_12", anchorX + usableW - 100, listTop, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    local listStartY = listTop + 20

    local pageStart = (dmgState.page - 1) * maxRows
    for i = 1, maxRows do
        local idx = pageStart + i
        if idx > #list then break end
        local rule = list[idx]
        local rowY = listStartY + (i - 1) * rowH
        local isHov = IsMouseIn(mx, my, anchorX, rowY, usableW, rowH - 2)
        draw.RoundedBox(4, anchorX, rowY, usableW, rowH - 2, isHov and Color(50, 50, 54) or Color(44, 44, 48))

        -- 类型（对象/对象组）
        draw.SimpleText(rule.isGroup and T("editor.appearance.object_group") or T("editor.appearance.object"), "SourceHan_Heavy_12", anchorX + 6, rowY + (rowH - 2) / 2, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 目标/来源名称
        local name = rule.targetName or rule.sourceName or rule.targetPath or rule.sourcePath or ""
        surface.SetFont("SourceHan_Heavy_14")
        local nameMaxW = usableW - 90 - 100
        if surface.GetTextSize(name) > nameMaxW then
            -- 超长路径截断显示
            local chars = 0
            local cut = name
            for c in name:gmatch(".") do
                surface.SetFont("SourceHan_Heavy_14")
                chars = chars + 1
                cut = string.sub(name, 1, utf8.offset(name, chars + 1) and (utf8.offset(name, chars + 1) - 1) or #name)
                if surface.GetTextSize(cut) > nameMaxW then
                    cut = string.sub(name, 1, (utf8.offset(name, chars) or #name) - 1) .. "…"
                    break
                end
            end
            name = cut
        end
        draw.SimpleText(name, "SourceHan_Heavy_14", anchorX + 90, rowY + (rowH - 2) / 2, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 倍率值（上下箭头调节：一次 0.5，按住 Alt 一次 0.1，2026-10-04 替换原透明输入框）
        local multW = 48
        local arrowW = 16
        local arrowGap = 2
        local multX = anchorX + usableW - 24 - (multW + arrowGap + arrowW)
        local multY = rowY + 2
        local multH = rowH - 6
        draw.RoundedBox(4, multX, multY, multW, multH, Color(55, 55, 60))
        draw.SimpleText("×" .. tostring(rule.multiplier or 1), "SourceHan_Heavy_14", multX + multW / 2, rowY + (rowH - 2) / 2, Color(230, 200, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        -- 上下箭头按钮（上 = 增加，下 = 减少）
        local arrowX = multX + multW + arrowGap
        local halfH = math.floor(multH / 2)
        local upRect = { x = arrowX, y = multY, w = arrowW, h = halfH }
        local downRect = { x = arrowX, y = multY + halfH, w = arrowW, h = multH - halfH }
        local upHov = IsMouseIn(mx, my, upRect.x, upRect.y, upRect.w, upRect.h)
        local downHov = IsMouseIn(mx, my, downRect.x, downRect.y, downRect.w, downRect.h)
        draw.RoundedBox(3, upRect.x, upRect.y, upRect.w, upRect.h, upHov and Color(70, 130, 220) or Color(70, 70, 76))
        draw.RoundedBox(3, downRect.x, downRect.y, downRect.w, downRect.h, downHov and Color(70, 130, 220) or Color(70, 70, 76))
        -- 三角形用线段绘制（不依赖字体是否含箭头符号）
        surface.SetDrawColor(upHov and Color(255, 255, 255) or Color(210, 210, 210))
        local ucx, ucy = upRect.x + upRect.w / 2, upRect.y + upRect.h / 2
        surface.DrawLine(ucx, ucy - 3, ucx - 4, ucy + 2)
        surface.DrawLine(ucx, ucy - 3, ucx + 4, ucy + 2)
        surface.DrawLine(ucx - 4, ucy + 2, ucx + 4, ucy + 2)
        local dcx, dcy = downRect.x + downRect.w / 2, downRect.y + downRect.h / 2
        surface.DrawLine(dcx, dcy + 3, dcx - 4, dcy - 2)
        surface.DrawLine(dcx, dcy + 3, dcx + 4, dcy - 2)
        surface.DrawLine(dcx - 4, dcy - 2, dcx + 4, dcy - 2)
        if isLeftPressed and not pickerBlocksClick and (upHov or downHov) then
            local stepSize = (input.IsKeyDown(KEY_LALT) or input.IsKeyDown(KEY_RALT)) and 0.1 or 0.5
            local cur = tonumber(rule.multiplier) or 1
            local newVal = upHov and (cur + stepSize) or (cur - stepSize)
            newVal = math.Round(newVal * 10) / 10
            if newVal < 0.1 then newVal = 0.1 end
            rule.multiplier = newVal
        end

        -- 删除按钮
        local delX = anchorX + usableW - 22
        local delHov = IsMouseIn(mx, my, delX, rowY + 3, 18, rowH - 8)
        draw.RoundedBox(4, delX, rowY + 3, 18, rowH - 8, delHov and Color(160, 60, 60) or Color(110, 50, 50))
        draw.SimpleText("✕", "SourceHan_Heavy_12", delX + 9, rowY + 3 + (rowH - 8) / 2, Color(255, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if delHov and isLeftPressed and not pickerBlocksClick then
            table.remove(list, idx)
        end
    end

    -- 分页导航（规则超一页时）
    if totalPages > 1 then
        local pgY = listBottom - 18
        draw.SimpleText(tostring(dmgState.page) .. " / " .. tostring(totalPages), "SourceHan_Heavy_12", anchorX + usableW / 2, pgY, APPLE_INK_MUTED80, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        local prevX = anchorX + usableW / 2 - 50
        local prevHov = IsMouseIn(mx, my, prevX, pgY - 10, 40, 20)
        draw.RoundedBox(4, prevX, pgY - 10, 40, 20, prevHov and Color(100, 100, 100) or Color(80, 80, 80))
        draw.SimpleText(T("editor.appearance.previous_page"), "SourceHan_Heavy_12", prevX + 20, pgY, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if prevHov and isLeftPressed and not pickerBlocksClick then dmgState.page = math.max(1, dmgState.page - 1) end

        local nextX = anchorX + usableW / 2 + 10
        local nextHov = IsMouseIn(mx, my, nextX, pgY - 10, 40, 20)
        draw.RoundedBox(4, nextX, pgY - 10, 40, 20, nextHov and Color(100, 100, 100) or Color(80, 80, 80))
        draw.SimpleText(T("editor.appearance.next_page"), "SourceHan_Heavy_12", nextX + 20, pgY, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if nextHov and isLeftPressed and not pickerBlocksClick then dmgState.page = math.min(totalPages, dmgState.page + 1) end
    end

    -- ===== [+ 添加规则] =====
    local addBtnHov = IsMouseIn(mx, my, anchorX, addBtnY, 120, 24)
    draw.RoundedBox(4, anchorX, addBtnY, 120, 24, addBtnHov and Color(60, 130, 200) or Color(50, 110, 170))
    draw.SimpleText(T("editor.appearance.add_rule"), "SourceHan_Heavy_14", anchorX + 60, addBtnY + 12, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if isLeftPressed and addBtnHov then
        dmgState.pickerOpen = not dmgState.pickerOpen
    end

    -- ===== 对象/对象组选择器（展开浮层） =====
    if dmgState.pickerOpen then
        draw.RoundedBox(4, anchorX, pickerY, usableW, pickerH, Color(30, 30, 34))
        surface.SetDrawColor(APPLE_HAIRLINE)
        surface.DrawOutlinedRect(anchorX, pickerY, usableW, pickerH)
        draw.SimpleText(T("editor.appearance.select_object_varlib"), "SourceHan_Heavy_12", anchorX + 6, pickerY + 4, APPLE_INK_MUTED80, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        -- 单位不能攻击指令（2026-08-16）：输出倍率（攻击目标）选择过滤指令/反制
        -- 对象组与开发池指令路径（指令/反制打出即离场，不构成攻击目标）；
        -- 受伤倍率（来源）保留——指令/反制效果可造成伤害
        local function isNonAttackTarget(path)
            if path:match("^Battle%.%w+CommandCards$") or path:match("^Battle%.%w+CounterCards$") then
                return true
            end
            if path:match("^Battle%.DevelopPool%.") then
                if path:match("%.command%.") or path:match("%.command$")
                    or path:match("own_command") or path:match("own_elite_command") then
                    return true
                end
            end
            return false
        end

        local paths = {}
        if KARDS.VarLib and KARDS.VarLib.GetObjectVarPaths then
            paths = KARDS.VarLib.GetObjectVarPaths("1")
        end
        if dmgState.tab == "outgoing" then
            local filtered = {}
            for _, p in ipairs(paths) do
                if not isNonAttackTarget(p.path) then table.insert(filtered, p) end
            end
            paths = filtered
        end

        local rowH2 = 20
        local maxItems = math.max(1, math.floor((pickerH - 24) / rowH2))
        local totalPickerPages = math.max(1, math.ceil(#paths / maxItems))
        dmgState.pickerPage = math.Clamp(dmgState.pickerPage or 1, 1, totalPickerPages)

        local itemY = pickerY + 22
        local startIdx = (dmgState.pickerPage - 1) * maxItems
        for i = 1, maxItems do
            local pi = startIdx + i
            if pi > #paths then break end
            local p = paths[pi]
            local label = p.path
            if KARDS.VarLib.GetDisplayName then
                label = KARDS.VarLib.GetDisplayName(p.path, "zh-CN")
            end
            local hover = IsMouseIn(mx, my, anchorX + 2, itemY, usableW - 4, rowH2 - 2)
            draw.RoundedBox(3, anchorX + 2, itemY, usableW - 4, rowH2 - 2, hover and Color(50, 50, 56) or Color(36, 36, 40))
            draw.SimpleText((p.isGroup and T("editor.appearance.group_prefix") or T("editor.appearance.object_prefix")) .. label, "SourceHan_Heavy_12", anchorX + 8, itemY + (rowH2 - 2) / 2, hover and Color(255, 255, 255) or Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if hover and isLeftPressed then
                local rule
                if dmgState.tab == "outgoing" then
                    rule = { targetPath = p.path, multiplier = 1, targetName = label, isGroup = p.isGroup }
                else
                    rule = { sourcePath = p.path, multiplier = 1, sourceName = label, isGroup = p.isGroup }
                end
                table.insert(list, rule)
                dmgState.pickerOpen = false
                -- 插入后按新列表长度重算总页数（totalPages 为插入前旧值，新规则可能落在新页）
                dmgState.page = math.max(1, math.ceil(#list / maxRows))
            end
            itemY = itemY + rowH2
        end

        -- 选择器分页
        if totalPickerPages > 1 then
            draw.SimpleText(tostring(dmgState.pickerPage) .. " / " .. tostring(totalPickerPages), "SourceHan_Heavy_12", anchorX + usableW / 2, pickerY + pickerH - 14, APPLE_INK_MUTED80, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            local ppPrevX = anchorX + usableW / 2 - 50
            local ppPrevHov = IsMouseIn(mx, my, ppPrevX, pickerY + pickerH - 24, 40, 18)
            draw.RoundedBox(3, ppPrevX, pickerY + pickerH - 24, 40, 18, ppPrevHov and Color(90, 90, 90) or Color(70, 70, 70))
            draw.SimpleText(T("editor.appearance.previous_page"), "SourceHan_Heavy_12", ppPrevX + 20, pickerY + pickerH - 15, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if ppPrevHov and isLeftPressed then dmgState.pickerPage = math.max(1, dmgState.pickerPage - 1) end

            local ppNextX = anchorX + usableW / 2 + 10
            local ppNextHov = IsMouseIn(mx, my, ppNextX, pickerY + pickerH - 24, 40, 18)
            draw.RoundedBox(3, ppNextX, pickerY + pickerH - 24, 40, 18, ppNextHov and Color(90, 90, 90) or Color(70, 70, 70))
            draw.SimpleText(T("editor.appearance.next_page"), "SourceHan_Heavy_12", ppNextX + 20, pickerY + pickerH - 15, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if ppNextHov and isLeftPressed then dmgState.pickerPage = math.min(totalPickerPages, dmgState.pickerPage + 1) end
        end
    end
end