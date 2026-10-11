--[[
=======================================================================================
纹理边界计算模块 (Texture Bounds)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的纹理边界计算模块，负责卡牌纹理有效区域与模板空心
区域的自动识别与缓存，供画布编辑器渲染时定位卡面与插图区域。

包含功能：
  - GetCardTextureBounds（自动裁切素材透明空白，获取卡牌实际有效区域）
  - GetTemplateHollowBounds（获取模板纹理的空心透明插图区域的位置与尺寸）

缓存数据：
  - TextureBoundsCache / TextureBoundsCacheTimeout（纹理边界计算结果缓存）
  - HollowBoundsCache / HollowBoundsCacheTimeout（模板空心区域缓存）

源文件：cl_canvas_editor.lua
  - 缓存数据与功能函数：行 886~1211
=======================================================================================
]]

-- 防御性命名空间初始化：确保即使本文件在 GMod 自动加载阶段先于
-- sh_card_editor_loader.lua 被加载，KARDS.CardEditor.Canvas 也已就绪
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}

-- 纹理边界计算结果缓存
local TextureBoundsCache = {}
local TextureBoundsCacheTimeout = 300

-- 自动裁切素材的透明空白，获取卡牌的实际有效区域
-- 优化版本：使用降采样策略提升大纹理性能
function KARDS.CardEditor.Canvas.GetCardTextureBounds(material)
    if not material then
        return 0, 0, 0, 0
    end
    
    local tex = material:GetTexture("$basetexture")
    local matName = material:GetName() or tostring(material)
    
    local cacheEntry = TextureBoundsCache[matName]
    local now = SysTime()
    if cacheEntry and (now - cacheEntry.timestamp) < TextureBoundsCacheTimeout then
        return cacheEntry.minX, cacheEntry.minY, cacheEntry.width, cacheEntry.height
    end
    
    if not tex or not tex.GetSize then
        local defaultW, defaultH = material:Width(), material:Height()
        TextureBoundsCache[matName] = { minX = 0, minY = 0, width = defaultW, height = defaultH, timestamp = now }
        return 0, 0, defaultW, defaultH
    end
    
    local w, h = tex:GetSize()
    if not w or not h then
        local defaultW, defaultH = material:Width(), material:Height()
        TextureBoundsCache[matName] = { minX = 0, minY = 0, width = defaultW, height = defaultH, timestamp = now }
        return 0, 0, defaultW, defaultH
    end
    
    -- 根据纹理尺寸动态计算采样步长
    -- 对于大纹理（>512），使用更大步长提升性能
    local step = 1
    local maxDimension = math.max(w, h)
    if maxDimension > 1024 then
        step = 8  -- 超大纹理：每 8 像素采样一次
    elseif maxDimension > 512 then
        step = 4  -- 大纹理：每 4 像素采样一次
    elseif maxDimension > 256 then
        step = 2  -- 中等纹理：每 2 像素采样一次
    end
    
    local minX, minY = w, h
    local maxX, maxY = 0, 0

    -- 第一阶段：降采样快速扫描，找到近似边界
    for x = 0, w - 1, step do
        for y = 0, h - 1, step do
            local r, g, b, a = tex:GetPixel(x, y)
            if a > 10 then
                minX = math.min(minX, x)
                minY = math.min(minY, y)
                maxX = math.max(maxX, x)
                maxY = math.max(maxY, y)
            end
        end
    end
    
    -- 第二阶段：如果使用了降采样，在近似边界的四条边带区域精细扫描
    -- 只扫描边界条带（宽 step 像素），修正粗扫描可能遗漏的边缘像素
    if step > 1 and maxX > 0 and maxY > 0 then
        local clampMinX = math.max(0, minX - step)
        local clampMaxX = math.min(w - 1, maxX + step)
        local clampMinY = math.max(0, minY - step)
        local clampMaxY = math.min(h - 1, maxY + step)
        
        -- 左侧边带：修正 minX / minY / maxY
        for x = clampMinX, minX do
            for y = clampMinY, clampMaxY do
                local r, g, b, a = tex:GetPixel(x, y)
                if a > 10 then
                    minX = math.min(minX, x)
                    minY = math.min(minY, y)
                    maxY = math.max(maxY, y)
                end
            end
        end
        
        -- 右侧边带：修正 maxX / minY / maxY
        for x = maxX, clampMaxX do
            for y = clampMinY, clampMaxY do
                local r, g, b, a = tex:GetPixel(x, y)
                if a > 10 then
                    maxX = math.max(maxX, x)
                    minY = math.min(minY, y)
                    maxY = math.max(maxY, y)
                end
            end
        end
        
        -- 上侧边带：修正 minY（跳过已被左右边带扫描的区域）
        for x = minX + 1, maxX - 1 do
            for y = clampMinY, minY do
                local r, g, b, a = tex:GetPixel(x, y)
                if a > 10 then
                    minY = math.min(minY, y)
                end
            end
        end
        
        -- 下侧边带：修正 maxY（跳过已被左右边带扫描的区域）
        for x = minX + 1, maxX - 1 do
            for y = maxY, clampMaxY do
                local r, g, b, a = tex:GetPixel(x, y)
                if a > 10 then
                    maxY = math.max(maxY, y)
                end
            end
        end
    end
    
    local boundW, boundH = maxX - minX, maxY - minY
    if boundW <= 0 or boundH <= 0 then
        minX, minY, boundW, boundH = 0, 0, w, h
    end
    
    TextureBoundsCache[matName] = { minX = minX, minY = minY, width = boundW, height = boundH, timestamp = now }
    return minX, minY, boundW, boundH
end

-- 模板空心区域缓存
local HollowBoundsCache = {}
local HollowBoundsCacheTimeout = 60

-- 获取模板纹理的空心区域（透明插图区域）的位置和尺寸
-- 返回: hollowX, hollowY, hollowW, hollowH（纹理像素坐标，相对于纹理左上角）
function KARDS.CardEditor.Canvas.GetTemplateHollowBounds(material)
    if not material then
        return 0, 0, 0, 0
    end

    local matName = material:GetName() or tostring(material)
    local cacheEntry = HollowBoundsCache[matName]
    local now = SysTime()
    if cacheEntry and (now - cacheEntry.timestamp) < HollowBoundsCacheTimeout then
        return cacheEntry.hollowX, cacheEntry.hollowY, cacheEntry.hollowW, cacheEntry.hollowH
    end

    local tex = material:GetTexture("$basetexture")
    if not tex or not tex.GetSize then
        local defaultW, defaultH = material:Width(), material:Height()
        HollowBoundsCache[matName] = { hollowX = 0, hollowY = 0, hollowW = defaultW, hollowH = defaultH, timestamp = now }
        return 0, 0, defaultW, defaultH
    end

    local w, h = tex:GetSize()
    if not w or not h then
        local defaultW, defaultH = material:Width(), material:Height()
        HollowBoundsCache[matName] = { hollowX = 0, hollowY = 0, hollowW = defaultW, hollowH = defaultH, timestamp = now }
        return 0, 0, defaultW, defaultH
    end

    -- 获取卡面边界
    local cardMinX, cardMinY, cardW, cardH = KARDS.CardEditor.Canvas.GetCardTextureBounds(material)
    local cardMaxX = cardMinX + cardW - 1
    local cardMaxY = cardMinY + cardH - 1

    -- 动态计算步长，大纹理用大步长快速扫描
    local step = 1
    local maxDimension = math.max(w, h)
    if maxDimension > 1024 then
        step = 8
    elseif maxDimension > 512 then
        step = 4
    elseif maxDimension > 256 then
        step = 2
    end

    local threshold = 0.8  -- 透明像素比例超过此值认为是空心区域

    -- === 垂直方向扫描：找到空心区域的上下边界 ===
    local hollowTopY = cardMinY
    local hollowBottomY = cardMaxY
    local foundTop = false
    local foundBottom = false

    -- 从顶部向下扫描，找到第一个大部分透明的行
    for y = cardMinY, cardMaxY, step do
        local transparentCount = 0
        local sampleCount = 0
        for x = cardMinX, cardMaxX, step do
            local r, g, b, a = tex:GetPixel(x, y)
            sampleCount = sampleCount + 1
            if a < 5 then
                transparentCount = transparentCount + 1
            end
        end
        if sampleCount > 0 and transparentCount / sampleCount > threshold then
            hollowTopY = y
            foundTop = true
            break
        end
    end

    -- 从底部向上扫描，找到最后一个大部分透明的行
    for y = cardMaxY, cardMinY, -step do
        local transparentCount = 0
        local sampleCount = 0
        for x = cardMinX, cardMaxX, step do
            local r, g, b, a = tex:GetPixel(x, y)
            sampleCount = sampleCount + 1
            if a < 5 then
                transparentCount = transparentCount + 1
            end
        end
        if sampleCount > 0 and transparentCount / sampleCount > threshold then
            hollowBottomY = y
            foundBottom = true
            break
        end
    end

    -- 如果大步长没找到，回退到整个卡面高度
    if not foundTop then hollowTopY = cardMinY end
    if not foundBottom then hollowBottomY = cardMaxY end

    -- 如果用了大步长，在边界附近精细扫描修正
    if step > 1 and foundTop and foundBottom then
        -- 修正上边界：从上方向下找
        local clampTop = math.max(cardMinY, hollowTopY - step)
        for y = clampTop, hollowTopY do
            local transparentCount = 0
            local sampleCount = 0
            for x = cardMinX, cardMaxX, step do
                local r, g, b, a = tex:GetPixel(x, y)
                sampleCount = sampleCount + 1
                if a < 5 then
                    transparentCount = transparentCount + 1
                end
            end
            if sampleCount > 0 and transparentCount / sampleCount > threshold then
                hollowTopY = y
                break
            end
        end

        -- 修正下边界：从下方向上找
        local clampBottom = math.min(cardMaxY, hollowBottomY + step)
        for y = clampBottom, hollowBottomY, -1 do
            local transparentCount = 0
            local sampleCount = 0
            for x = cardMinX, cardMaxX, step do
                local r, g, b, a = tex:GetPixel(x, y)
                sampleCount = sampleCount + 1
                if a < 5 then
                    transparentCount = transparentCount + 1
                end
            end
            if sampleCount > 0 and transparentCount / sampleCount > threshold then
                hollowBottomY = y
                break
            end
        end
    end

    -- === 水平方向扫描：在空心区域中间行找左右边界 ===
    local midY = math.floor((hollowTopY + hollowBottomY) / 2)
    local hollowLeftX = cardMinX
    local hollowRightX = cardMaxX
    local foundLeft = false
    local foundRight = false

    -- 从左向右扫描
    for x = cardMinX, cardMaxX, step do
        local r, g, b, a = tex:GetPixel(x, midY)
        if a < 5 then
            hollowLeftX = x
            foundLeft = true
            break
        end
    end

    -- 从右向左扫描
    for x = cardMaxX, cardMinX, -step do
        local r, g, b, a = tex:GetPixel(x, midY)
        if a < 5 then
            hollowRightX = x
            foundRight = true
            break
        end
    end

    -- 精细修正水平边界
    if step > 1 and foundLeft and foundRight then
        local clampLeft = math.max(cardMinX, hollowLeftX - step)
        for x = clampLeft, hollowLeftX do
            local r, g, b, a = tex:GetPixel(x, midY)
            if a < 5 then
                hollowLeftX = x
                break
            end
        end

        local clampRight = math.min(cardMaxX, hollowRightX + step)
        for x = clampRight, hollowRightX, -1 do
            local r, g, b, a = tex:GetPixel(x, midY)
            if a < 5 then
                hollowRightX = x
                break
            end
        end
    end

    if not foundLeft then hollowLeftX = cardMinX end
    if not foundRight then hollowRightX = cardMaxX end

    local hollowW = hollowRightX - hollowLeftX + 1
    local hollowH = hollowBottomY - hollowTopY + 1

    if hollowW <= 0 or hollowH <= 0 then
        hollowLeftX, hollowTopY = cardMinX, cardMinY
        hollowW, hollowH = cardW, cardH
    end

    HollowBoundsCache[matName] = {
        hollowX = hollowLeftX,
        hollowY = hollowTopY,
        hollowW = hollowW,
        hollowH = hollowH,
        timestamp = now
    }
    return hollowLeftX, hollowTopY, hollowW, hollowH
end
