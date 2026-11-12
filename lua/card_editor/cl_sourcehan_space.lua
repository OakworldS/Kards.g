--[[
=======================================================================================
思源黑体空格补偿（cl_sourcehan_space.lua）
=======================================================================================
思源黑体的空格字宽偏窄，正常字体一个空格的视觉间隔，在思源黑体上需要两个空格
才看得清。这里在渲染层统一补偿：凡是使用 SourceHan 系列字体绘制或测量的文本，
每个连续空格段追加一个空格，单个空格因此渲染为两格。

处理范围：
  - draw.SimpleText
  - draw.SimpleTextOutlined
  - draw.DrawText（旧接口）
  - surface.SetFont + surface.GetTextSize（测量同步，避免光标与截断错位）

只影响渲染与测量，不改动任何持久化文本，存档中的字符串保持原样。
=======================================================================================
]]

if not CLIENT then return end

-- 防止热重载时重复包裹导致空格被成倍放大
if KARDS.CardEditor._SourceHanSpacePatched then return end
KARDS.CardEditor._SourceHanSpacePatched = true

-- 判断字体名是否属于思源黑体系列
local function IsSourceHanFont(font)
    return isstring(font) and string.find(font, "SourceHan", 1, true) ~= nil
end

-- 每个连续空格段追加一个空格（单空格变双空格，避免成倍放大）
local function WidenSpaces(text)
    if not isstring(text) then return text end
    if not string.find(text, " ", 1, true) then return text end
    return (string.gsub(text, " +", function(run)
        return run .. " "
    end))
end

-- 当前 surface 字体（供测量同步使用）
local currentSurfaceFont = nil

local rawSetFont = surface.SetFont
function surface.SetFont(font)
    currentSurfaceFont = font
    return rawSetFont(font)
end

local rawGetTextSize = surface.GetTextSize
function surface.GetTextSize(text)
    if IsSourceHanFont(currentSurfaceFont) then
        text = WidenSpaces(text)
    end
    return rawGetTextSize(text)
end

local rawSimpleText = draw.SimpleText
function draw.SimpleText(text, font, x, y, color, alignX, alignY)
    if IsSourceHanFont(font) then
        text = WidenSpaces(text)
    end
    return rawSimpleText(text, font, x, y, color, alignX, alignY)
end

local rawSimpleTextOutlined = draw.SimpleTextOutlined
if rawSimpleTextOutlined then
    function draw.SimpleTextOutlined(text, font, x, y, color, alignX, alignY, outlineWidth, outlineColor)
        if IsSourceHanFont(font) then
            text = WidenSpaces(text)
        end
        return rawSimpleTextOutlined(text, font, x, y, color, alignX, alignY, outlineWidth, outlineColor)
    end
end

local rawDrawText = draw.DrawText
if rawDrawText then
    function draw.DrawText(text, font, x, y, color, alignX)
        if IsSourceHanFont(font) then
            text = WidenSpaces(text)
        end
        return rawDrawText(text, font, x, y, color, alignX)
    end
end
