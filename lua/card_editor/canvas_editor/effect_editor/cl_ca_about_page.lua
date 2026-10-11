--[[
=======================================================================================
关于页（cl_ca_about_page.lua）
=======================================================================================
职责：卡牌编辑器「关于」标签页的全部绘制、交互与状态，一个文件装完。

数据来源（本文件只读，不写）：
  lua/card_editor/sh_version_history.lua  版本历史，绘制数轴时间线
  lua/card_editor/sh_source_credits.lua   素材来源，绘制来源弹窗

对外函数：
  KARDS.CardEditor.Canvas.DrawAboutPage(x, y, w, h)
      由 cl_canvas_editor.lua 的 about 分支调用。左列是卡片，随滚轮滚动；
      右列是竖向版本数轴，固定不滚动；鼠标悬停节点时播放四段预览动画
  KARDS.CardEditor.Canvas.DrawAboutSourcesOverlay()
      由 cl_canvas_editor.lua 的主绘制链末尾调用，绘制素材来源弹窗
  KARDS.CardEditor.Canvas.HandleAboutPageInput(mx, my, isLeftReleased, isLeftDown)
  KARDS.CardEditor.Canvas.HandleAboutSourcesInput(mx, my, isLeftReleased, isLeftDown)
      由 cl_ca_input_handling.lua 的 HandleInput 调用，返回 true 表示已消费

状态：KARDS.CardEditor.Canvas.About（滚动量、时间线选中项、弹窗可见性、命中矩形缓存）

加载顺序：由 sh_card_editor_loader.lua 的 LoadClientFiles 在 cl_ca_file_manager.lua 之后加载。
依赖 Canvas 命名空间、APPLE_* 常量、IsMouseIn、DrawHoverButton，均已在此时就绪。
=======================================================================================
]]
local C = KARDS.CardEditor.Canvas

-- ===== 状态 =====
C.About = C.About or {
    scrollOffset = 0,       -- 关于页纵向滚动量
    scrollMax = 0,
    timelineIndex = 0,      -- 时间线当前选中项，0 表示待初始化（默认选最后一项）
    sourcesVisible = false, -- 素材来源弹窗是否打开
    sourcesScroll = 0,
    sourcesScrollMax = 0,
    linkRows = {}           -- 链接行命中矩形缓存，每帧重填
}
local About = C.About
About.linkRows = About.linkRows or {}

-- 右侧竖轴的几何（每帧由 DrawVerticalTimeline 填入，供节点定位与悬停使用）
local tlState = {
    axisX = 0,
    axisTop = 0,
    axisH = 1
}

-- ===== 主题与常量 =====
local THEME = {
    developer    = Color(230, 160, 60),   -- 琥珀
    thanks       = Color(235, 130, 170),  -- 粉
    contributors = Color(235, 235, 235)   -- 白
}
local CARD_BG     = Color(45, 45, 45)
local CARD_SHADOW = Color(0, 0, 0, 120)
local CARD_RADIUS = 8
local GAP         = 12

local H_IDENTITY = 104
local H_CREDIT   = 128
local H_CONTRIB  = 92
local H_FOOTER   = 24
local BTN_W, BTN_H = 200, 40
local SHOT_W, SHOT_H = 320, 180

-- 右列竖向数轴的列宽。轴居中，左半放五条线的阶段点，右半放版本书签
local TIMELINE_W = 520

-- 版本历史卡片的底图。只做内层底图，圆角、左侧色条、描边与阴影仍由 DrawCardFrame 画。
-- 尺寸按 1080p 下的卡片面积做：宽 520，高 ScrH() - 196 = 884。贴图缺失时回退纯色底板
local TIMELINE_BG = "materials/kards/ui/about/timeline_bg.png"

-- 五条时间线：点半径、同一天按轨错开的横向偏移（相对轴，全部落在轴左侧五个车道）、图例排版
local TRACK_DOT_R   = 4
local TRACK_OFFSETS = { -24, -56, -88, -120, -152 }
local LEGEND_COL_W  = 120
local LEGEND_ROW_H  = 22

-- 悬停预览面板：宽高由文字量出，超宽时折行；高度与宽度各有上下限
local PANEL_PAD    = 8
local PANEL_MIN_W  = 220
local PANEL_MAX_W  = 460
local PANEL_MAX_H  = 360
local SHOT_MARGIN  = 16

-- 悬停动画四段的时间区间（秒）
local ANIM_T_STEM  = { 0.00, 0.16 }   -- 垂线从节点延伸
local ANIM_T_RECT  = { 0.16, 0.42 }   -- 矩形描边逐步绘制
local ANIM_T_TEXT  = { 0.26, 0.58 }   -- 文字淡入
local ANIM_T_IMAGE = { 0.55, 0.95 }   -- 图片从文字位置左移到空白处

-- 退场：进入的倒放，时间从 ANIM_T_IMAGE[2] 递减到 0。仅描边与图片共用一段，
-- 于是图片回缩与描边回退同时进行，其余各段仍按各自的倒放窗
local ANIM_T_BORDER = { ANIM_T_RECT[1], ANIM_T_IMAGE[2] }

-- 打开关于页时的卡片描边动画：依次错开，每张按周长画出描边
local INTRO_STAGGER  = 0.07
local INTRO_DURATION = 0.28
local INTRO_ORDER = {
    identity     = 1,
    timeline     = 2,
    developer    = 3,
    thanks       = 4,
    contributors = 5
}

local AVATAR_PATHS = {
    developer = "materials/kards/ui/avatars/oak_world.jpg",
    thanks    = "materials/kards/ui/avatars/hoshi.jpg"
}

-- ===== 头像与截图的材质缓存 =====
local materialCache = {}
local function GetCachedMaterial(path)
    if materialCache[path] == nil then
        materialCache[path] = Material(path, "noclamp smooth")
    end
    return materialCache[path]
end

-- 从图片数据里量出宽高比。PNG 看 IHDR，JPEG 逐个跳过段去找 SOF 帧头，
-- 两者给的都必须是真实像素，不能问纹理也不能问 Material：非 2 的幂的图会被引擎
-- 补成 2 的幂尺寸，比如 1920x1078 会读成 2048x2048，比例被当成 1 比 1，图就压成方块。
-- 文件扩展名不作数，按内容判断
local function ParseImageAspect(data)
    local n = #data
    if n < 24 then return 0 end
    local b = string.byte

    -- PNG：签名之后必是 IHDR，宽高为大端 32 位整数，落在第 17 到 24 字节
    if b(data, 1) == 137 and b(data, 2) == 80 and b(data, 3) == 78 and b(data, 4) == 71 then
        local w = b(data, 17) * 16777216 + b(data, 18) * 65536 + b(data, 19) * 256 + b(data, 20)
        local h = b(data, 21) * 16777216 + b(data, 22) * 65536 + b(data, 23) * 256 + b(data, 24)
        if w > 0 and h > 0 then return w / h end
        return 0
    end

    -- JPEG：段以 FF 加标记开头，带两字节长度（含长度本身）。SOF 帧头里
    -- 第 5 到 8 字节是高与宽，其余段按长度跳过
    local i = 1
    while i + 8 <= n do
        if b(data, i) ~= 255 then
            i = i + 1
        else
            local marker = b(data, i + 1)
            if (marker >= 192 and marker <= 195) or (marker >= 197 and marker <= 199)
                or (marker >= 201 and marker <= 203) or (marker >= 205 and marker <= 207) then
                local h = b(data, i + 5) * 256 + b(data, i + 6)
                local w = b(data, i + 7) * 256 + b(data, i + 8)
                if w > 0 and h > 0 then return w / h end
                return 0
            elseif marker == 255 or marker == 1 or (marker >= 208 and marker <= 217) then
                i = i + 1          -- 填充字节与无长度字段的标记
            else
                local segLen = b(data, i + 2) * 256 + b(data, i + 3)
                if segLen < 2 then return 0 end
                i = i + 2 + segLen
            end
        end
    end
    return 0
end

-- 截图原始宽高比，用于按容纳样式放进 16:9 图框。整段只读一次，按路径缓存；
-- 读不到或认不出格式时返回 0，表示比例未知，绘制方退回整框铺满
local shotAspectCache = {}
local function GetShotAspect(path)
    local cached = shotAspectCache[path]
    if cached ~= nil then return cached end
    local aspect = 0
    local handle = path and file.Open(path, "rb", "GAME")
    if handle then
        -- 头 64KB 足够覆盖 PNG 的 IHDR 与 JPEG 里 EXIF 之后的 SOF 帧头
        local head = handle:Read(65536)
        handle:Close()
        if head then aspect = ParseImageAspect(head) end
    end
    shotAspectCache[path] = aspect
    return aspect
end

-- ===== 日期工具 =====
local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function IsLeapYear(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

-- 把 YYYY-MM-DD 折算成自 2000-01-01 起的天数，用于时间轴等比定位
local function ParseDateToDay(text)
    local y, m, d = string.match(tostring(text or ""), "^(%d+)%-(%d+)%-(%d+)$")
    if not y then return 0 end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    local total = 0
    for yy = 2000, y - 1 do
        total = total + (IsLeapYear(yy) and 366 or 365)
    end
    for mm = 1, m - 1 do
        total = total + DAYS_IN_MONTH[mm]
        if mm == 2 and IsLeapYear(y) then total = total + 1 end
    end
    return total + d
end

-- 竖轴上端为最早版本，下端为当天
local function GetTimelineRange()
    local history = KARDS.CardEditor.VersionHistory or {}
    local firstDay = ParseDateToDay(history[1] and history[1].date)
    local now = os.date("*t")
    local lastDay = ParseDateToDay(string.format("%04d-%02d-%02d", now.year, now.month, now.day))
    if lastDay <= firstDay then lastDay = firstDay + 1 end
    return firstDay, lastDay
end

-- 第 i 个版本在竖轴上的 y 坐标
local function NodeYForIndex(i)
    local history = KARDS.CardEditor.VersionHistory or {}
    if #history == 0 then return tlState.axisTop end
    local firstDay, lastDay = GetTimelineRange()
    local day = ParseDateToDay(history[i] and history[i].date)
    local t = (day - firstDay) / (lastDay - firstDay)
    return tlState.axisTop + math.Clamp(t, 0, 1) * tlState.axisH
end

-- 任意日期在竖轴上的 y 坐标，供五条时间线的点定位
local function AxisYForDate(dateText)
    local firstDay, lastDay = GetTimelineRange()
    local t = (ParseDateToDay(dateText) - firstDay) / (lastDay - firstDay)
    return tlState.axisTop + math.Clamp(t, 0, 1) * tlState.axisH
end

-- 阶段点可能是单日（只有 date），也可能是一段时间（有 from 与 to，用于把挤在一起的点并成一段）。
-- 时段点画在时段中点，悬停面板显示起止日期
local function TrackPointAnchorY(point)
    if point.from and point.to then
        return (AxisYForDate(point.from) + AxisYForDate(point.to)) * 0.5
    end
    return AxisYForDate(point.date)
end

local function TrackPointRangeText(point)
    if point.from and point.to then
        return tostring(point.from) .. " 至 " .. tostring(point.to)
    end
    return tostring(point.date or "")
end

-- 截图的材质路径由轨道 id 与日期推出，数据里因此不必再写 shot 字段：
-- materials/kards/ui/about/<轨道 id>_<日期>.png，日期取 date 或时段点的 from，去掉连字符。
-- 推到的那张图不存在时，悬停面板只是不播图片动画，其余三段照常
local function ShotPathFor(trackId, point)
    local token = string.gsub(tostring(point.date or point.from or ""), "%-", "")
    if token == "" then return nil end
    return "materials/kards/ui/about/" .. tostring(trackId or "point") .. "_" .. token .. ".png"
end

-- 把绝对时间换算成某一动画段的 0 到 1 进度
local function PhaseProgress(elapsed, range)
    if elapsed <= range[1] then return 0 end
    if elapsed >= range[2] then return 1 end
    return (elapsed - range[1]) / (range[2] - range[1])
end

-- 按周长比例分段绘制矩形描边：上边、右边、下边、左边依次长出
local function DrawPartialOutline(x, y, w, h, progress, color)
    local perimeter = 2 * (w + h)
    local drawn = perimeter * math.Clamp(progress, 0, 1)
    surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)

    local len = math.min(drawn, w)
    surface.DrawLine(x, y, x + len, y)
    drawn = drawn - w
    if drawn <= 0 then return end

    len = math.min(drawn, h)
    surface.DrawLine(x + w, y, x + w, y + len)
    drawn = drawn - h
    if drawn <= 0 then return end

    len = math.min(drawn, w)
    surface.DrawLine(x + w, y + h, x + w - len, y + h)
    drawn = drawn - w
    if drawn <= 0 then return end

    surface.DrawLine(x, y + h, x, y + h - math.min(drawn, h))
end

local function EaseOutCubic(t)
    t = math.Clamp(t, 0, 1)
    local inv = 1 - t
    return 1 - inv * inv * inv
end

-- 打开关于页时，按 INTRO_ORDER 依次给每张卡片算描边进度
local function CardProgress(key)
    local order = INTRO_ORDER[key]
    if not order then return 1 end
    local elapsed = CurTime() - (About.introStart or 0) - (order - 1) * INTRO_STAGGER
    if elapsed <= 0 then return 0 end
    if elapsed >= INTRO_DURATION then return 1 end
    return elapsed / INTRO_DURATION
end

-- ===== 绘制小工具 =====
-- 版本历史卡片换上外部底图后，代码画的文字与线条直接压上去会发虚。这里统一在右下角
-- 先补一层深色副本，再在原点画原色，元素于是从底图上浮起来。极淡的辅助线不参与
local SHADOW_OFFSET = 1
local SHADOW_COLOR  = Color(0, 0, 0, 150)

-- 文字投影。阴影透明度跟着文字走，淡入淡出时不会留下先到的黑影
local function DrawTextShadowed(text, font, sx, sy, color, xalign, yalign)
    local a = color.a or 255
    draw.SimpleText(text, font, sx + SHADOW_OFFSET, sy + SHADOW_OFFSET,
        Color(SHADOW_COLOR.r, SHADOW_COLOR.g, SHADOW_COLOR.b, math.floor(SHADOW_COLOR.a * a / 255)),
        xalign, yalign)
    draw.SimpleText(text, font, sx, sy, color, xalign, yalign)
end

-- 圆角矩形投影，用于图例色块、数轴与时间点
local function DrawBoxShadowed(radius, bx, by, bw, bh, color)
    draw.RoundedBox(radius, bx + SHADOW_OFFSET, by + SHADOW_OFFSET, bw, bh, SHADOW_COLOR)
    draw.RoundedBox(radius, bx, by, bw, bh, color)
end

-- 用折线拼出圆形描边，Source 的 DrawLine 固定 1 像素宽，需要更粗时叠两圈
local function StrokeRing(cx, cy, radius, r, g, b, a)
    local segments = 28
    surface.SetDrawColor(r, g, b, a)
    local prevX, prevY
    for i = 0, segments do
        local ang = (i / segments) * math.pi * 2
        local px, py = cx + math.cos(ang) * radius, cy + math.sin(ang) * radius
        if prevX then
            surface.DrawLine(prevX, prevY, px, py)
        end
        prevX, prevY = px, py
    end
end

-- shadow 为真时先在右下角补一层深色环，供压在底图上的版本节点与彩点使用
local function DrawRing(cx, cy, radius, color, shadow)
    if shadow then
        StrokeRing(cx + SHADOW_OFFSET, cy + SHADOW_OFFSET, radius,
            SHADOW_COLOR.r, SHADOW_COLOR.g, SHADOW_COLOR.b, SHADOW_COLOR.a)
    end
    StrokeRing(cx, cy, radius, color.r, color.g, color.b, color.a or 255)
end

-- outlineProgress 为 nil 时按画完处理，用于不需要动画的场合
-- bgPath 可选：给了且贴图可用时，纯色底板换成这张底图，仍按同一圆角形状裁切
local function DrawCardFrame(x, y, w, h, accent, outlineProgress, bgPath)
    local p = (outlineProgress == nil) and 1 or math.Clamp(outlineProgress, 0, 1)

    draw.RoundedBox(CARD_RADIUS, x, y + 2, w, h, CARD_SHADOW)

    local bgMat = bgPath and GetCachedMaterial(bgPath)
    if bgMat and not bgMat:IsError() then
        -- 底图是直角矩形，直接铺会顶破卡片圆角。先用底板自己写一份模板，
        -- 再按模板贴图，四角于是跟着圆角裁掉。模板画完立刻关掉并清空，
        -- 免得影响后续绘制
        render.ClearStencil()
        render.SetStencilEnable(true)
        render.SetStencilWriteMask(1)
        render.SetStencilTestMask(1)
        render.SetStencilReferenceValue(1)
        render.SetStencilCompareFunction(STENCIL_ALWAYS)
        render.SetStencilPassOperation(STENCIL_REPLACE)
        render.SetStencilFailOperation(STENCIL_KEEP)
        render.SetStencilZFailOperation(STENCIL_KEEP)
        draw.RoundedBox(CARD_RADIUS, x, y, w, h, color_white)
        render.SetStencilCompareFunction(STENCIL_EQUAL)
        surface.SetMaterial(bgMat)
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRect(x, y, w, h)
        render.SetStencilEnable(false)
        render.ClearStencil()
    else
        draw.RoundedBox(CARD_RADIUS, x, y, w, h, CARD_BG)
    end

    -- 左侧色条随描边一起淡入
    local barAlpha = math.floor(255 * math.min(1, p * 2))
    draw.RoundedBox(2, x, y + 10, 4, h - 20, Color(accent.r, accent.g, accent.b, barAlpha))

    if p >= 1 then
        surface.SetDrawColor(accent.r, accent.g, accent.b, 140)
        surface.DrawOutlinedRect(x, y, w, h, 1)
        surface.SetDrawColor(255, 255, 255, 255)
    elseif p > 0 then
        DrawPartialOutline(x, y, w, h, p, Color(accent.r, accent.g, accent.b, 200))
    end
end

-- shadow 为真时带投影，供压在底图上的版本历史标题使用
local function DrawCardTitle(text, x, y, color, shadow)
    if shadow then
        DrawTextShadowed(text, "SourceHan_Heavy_20", x, y, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        return
    end
    draw.SimpleText(text, "SourceHan_Heavy_20", x, y, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end

local function MeasureText(text, font)
    surface.SetFont(font)
    return surface.GetTextSize(text)
end

-- 按 UTF-8 首字节判断字符占几个字节，用于逐字折行，避免把多字节字符截断
local function Utf8CharLen(byte)
    if byte < 0x80 then return 1 end
    if byte < 0xE0 then return 2 end
    if byte < 0xF0 then return 3 end
    return 4
end

-- 按可用宽度折行。中文没有空格可依，所以逐字累加测量，超宽即断行
local function WrapText(text, font, maxW)
    text = tostring(text or "")
    if text == "" then return { "" } end
    if MeasureText(text, font) <= maxW then return { text } end

    local out, current = {}, ""
    local i, len = 1, string.len(text)
    while i <= len do
        local ch = string.sub(text, i, i + Utf8CharLen(string.byte(text, i)) - 1)
        local candidate = current .. ch
        if current ~= "" and MeasureText(candidate, font) > maxW then
            table.insert(out, current)
            current = ch
        else
            current = candidate
        end
        i = i + string.len(ch)
    end
    if current ~= "" then table.insert(out, current) end
    return out
end

-- 阶段徽章：Alpha 空心描边，Beta 半填充，Release 实心
local function DrawStageBadge(x, y, stage)
    local font = "SourceHan_Heavy_14"
    local tw, th = MeasureText(stage, font)
    local pw, ph = tw + 18, th + 8
    local accent = APPLE_BLUE
    if stage == "Release" then
        draw.RoundedBox(4, x - pw, y, pw, ph, accent)
        draw.SimpleText(stage, font, x - pw / 2, y + ph / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    elseif stage == "Beta" then
        draw.RoundedBox(4, x - pw, y, pw, ph, Color(accent.r, accent.g, accent.b, 130))
        draw.SimpleText(stage, font, x - pw / 2, y + ph / 2, APPLE_INK, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    else
        surface.SetDrawColor(accent.r, accent.g, accent.b, 220)
        surface.DrawOutlinedRect(x - pw, y, pw, ph, 1)
        surface.SetDrawColor(255, 255, 255, 255)
        draw.SimpleText(stage, font, x - pw / 2, y + ph / 2, accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

-- 直角矩形标签，与圆角徽章在轮廓上区分
local function DrawRectTag(x, y, text)
    local font = "SourceHan_Heavy_14"
    local tw, th = MeasureText(text, font)
    local pw, ph = tw + 16, th + 8
    draw.RoundedBox(0, x - pw, y, pw, ph, APPLE_HAIRLINE)
    draw.SimpleText(text, font, x - pw / 2, y + ph / 2, APPLE_INK, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

local function VersionHasTag(entry, tag)
    if not entry or not entry.tags then return false end
    for _, t in ipairs(entry.tags) do
        if t == tag then return true end
    end
    return false
end

-- 阶段状态文案
local function StatusTextForStage(stage)
    if stage == "Release" then
        return "正式版"
    elseif stage == "Beta" then
        return "公开测试，基础功能已确认"
    end
    return "私密测试，功能未冻结"
end

-- ===== 第一块 身份卡 =====
local function DrawIdentityCard(x, y, w, h, frameP)
    DrawCardFrame(x, y, w, h, APPLE_BLUE, frameP)

    draw.SimpleText("Kards 卡牌编辑器", "SourceHan_Heavy_26", x + 16, y + 12, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText("在 Garry's Mod 里自己造卡，并让它真的能打", "SourceHan_Heavy_16", x + 16, y + 46, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    local history = KARDS.CardEditor.VersionHistory or {}
    local current = history[#history]
    local display = (current and current.display) or "Alpha"
    local stage = (current and current.stage) or "Alpha"

    draw.SimpleText(display, "SourceHan_Heavy_30", x + w - 16, y + 10, APPLE_BLUE, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
    DrawStageBadge(x + w - 16, y + 48, stage)

    if VersionHasTag(current, "Server") then
        DrawRectTag(x + w - 16, y + 70, "Serve")
    end

    draw.SimpleText(StatusTextForStage(stage), "SourceHan_Heavy_14", x + 16, y + 70, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end

-- 五色图例，两列排布
local function DrawTrackLegend(x, y)
    local tracks = KARDS.CardEditor.TimelineTracks or {}
    for i, track in ipairs(tracks) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local lx = x + col * LEGEND_COL_W
        local ly = y + row * LEGEND_ROW_H
        DrawBoxShadowed(3, lx, ly + 4, 8, 8, track.color or APPLE_BLUE)
        DrawTextShadowed(track.name or "", "SourceHan_Heavy_14", lx + 14, ly, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end
end

-- ===== 右列 竖向版本数轴 =====
-- 上端是最早的版本，下端是当天。轴居中：左半是五条时间线的阶段点，按颜色分五条车道；
-- 右半是版本书签胶囊，平时只显示简称，悬停时向右展开露出完整标题。
-- 轨道点靠悬停查看。悬停时由 DrawHoverPanel 播放四段预览动画。
local CHIP_FONT  = "SourceHan_Heavy_16"
local CHIP_H     = 24
local CHIP_PAD_X = 10
local CHIP_GAP   = 12

-- 版本书签胶囊。画法参考卡牌外貌属性编辑器的书签：收起时是简称，
-- 悬停时按进度把完整标题逐字露出，超宽部分由裁切收住。展开宽度不越过卡片右内边距。
-- 选中项也保持收起，选中状态由轴上的圆点放大与胶囊配色体现，避免最底部的版本一直展开
local function DrawBookmarkChip(index, chipX, cy, shortName, fullName, maxRight, isSelected, isHovered)
    About.chipProgress = About.chipProgress or {}
    local prog = About.chipProgress[index] or 0

    local normalW = MeasureText(shortName, CHIP_FONT) + CHIP_PAD_X * 2
    local fullW = MeasureText(fullName, CHIP_FONT) + CHIP_PAD_X * 2
    local availW = math.max(normalW, maxRight - chipX)
    local expandW = math.min(math.max(0, fullW - normalW), availW - normalW)

    -- 先按上一帧进度算出当前宽度，再推进进度，避免同一帧内宽度与动画互相追着改。
    -- 展开只由悬停驱动
    local dt = FrameTime()
    local speed = isHovered and 8 or 6
    if isHovered then
        prog = math.min(1, prog + dt * speed)
    else
        prog = math.max(0, prog - dt * speed)
    end
    About.chipProgress[index] = prog

    local curW = normalW + prog * expandW
    local bg = isSelected and APPLE_BLUE or APPLE_PARCHMENT
    if not isSelected and isHovered then bg = APPLE_DARK_HOVER end
    local textColor = isSelected and APPLE_TEXT_ON_BLUE or APPLE_INK

    -- 贴轴一侧留直角，外侧收圆角，像贴在外沿的书签
    draw.RoundedBoxEx(APPLE_RADII.pill, chipX, cy, curW, CHIP_H, bg, false, true, false, true)

    -- 文字按当前宽度横向裁切：收起时只露简称，展开时完整标题逐步露出来
    local innerW = math.max(0, curW - CHIP_PAD_X * 2)
    local page = About.pageRect
    if innerW > 1 and page then
        local innerX, cyMid = chipX + CHIP_PAD_X, cy + CHIP_H / 2
        render.SetScissorRect(innerX, cy, innerX + innerW, cy + CHIP_H, true)
        local shortA = math.floor(255 * (1 - math.min(1, prog * 1.4)))
        local fullA  = math.floor(255 * math.min(1, math.max(0, (prog - 0.2) / 0.8)))
        if shortA > 0 then
            DrawTextShadowed(shortName, CHIP_FONT, innerX, cyMid,
                Color(textColor.r, textColor.g, textColor.b, shortA), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        if fullA > 0 then
            DrawTextShadowed(fullName, CHIP_FONT, innerX, cyMid,
                Color(textColor.r, textColor.g, textColor.b, fullA), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        render.SetScissorRect(page.x, page.y, page.x + page.w, page.y + page.h, true)
    end
end

local function DrawVerticalTimeline(x, y, w, h, frameP)
    DrawCardFrame(x, y, w, h, APPLE_BLUE, frameP, TIMELINE_BG)
    DrawCardTitle("版本历史", x + 16, y + 10, APPLE_BLUE, true)
    DrawTrackLegend(x + 16, y + 34)

    local history = KARDS.CardEditor.VersionHistory or {}
    local count = #history
    if count == 0 then
        DrawTextShadowed("暂无版本记录", "SourceHan_Heavy_16", x + 16, y + 60, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        return
    end
    if About.timelineIndex < 1 or About.timelineIndex > count then
        About.timelineIndex = count
    end

    local tracks = KARDS.CardEditor.TimelineTracks or {}
    local axisX = x + math.floor(w / 2)
    local axisTop = y + 104
    local axisBottom = y + h - 34
    tlState.axisX = axisX
    tlState.axisTop = axisTop
    tlState.axisH = math.max(60, axisBottom - axisTop)

    -- 轨道：未过区段用 hairline，已过区段用品牌色
    local lastNodeY = NodeYForIndex(count)
    DrawBoxShadowed(1, axisX - 1, axisTop, 2, tlState.axisH, APPLE_HAIRLINE)
    DrawBoxShadowed(1, axisX - 1, axisTop, 2, math.max(1, lastNodeY - axisTop), APPLE_BLUE)

    -- 悬停检测：版本节点与五条线的阶段点都参与，取离鼠标最近的一个，并重置动画计时。
    -- 版本节点命中区覆盖轴上的圆点与轴右侧整片书签区域，避免书签展开后鼠标移出缩小
    local mx, my = gui.MouseX(), gui.MouseY()
    local bestKey, bestDist, bestVersion, bestPoint, bestAnchorY = "", math.huge, 0, nil, axisTop

    if mx >= axisX - 26 and mx <= x + w - 8 then
        for i = 1, count do
            local ny = NodeYForIndex(i)
            local d = math.abs(my - ny)
            if d <= 14 and d < bestDist then
                bestKey, bestDist, bestVersion, bestPoint, bestAnchorY = "v" .. i, d, i, nil, ny
            end
        end
    end

    for ti, track in ipairs(tracks) do
        local offX = TRACK_OFFSETS[ti] or 0
        for pi, point in ipairs(track.points or {}) do
            local px = axisX + offX
            local py = TrackPointAnchorY(point)
            local dist = math.sqrt((mx - px) * (mx - px) + (my - py) * (my - py))
            if dist <= 10 and dist < bestDist then
                bestKey, bestDist, bestVersion, bestAnchorY = "p" .. ti .. "_" .. pi, dist, 0, py
                bestPoint = {
                    title = point.label or "",
                    display = track.name or "",
                    date = TrackPointRangeText(point),
                    notes = point.notes or {},
                    color = track.color,
                    shot = ShotPathFor(track.id, point)
                }
            end
        end
    end

    if bestKey ~= (About.hoverKey or "") then
        About.hoverKey = bestKey
        About.hoverStart = CurTime()
    end
    About.hoverIndex = bestVersion
    About.hoverPoint = bestPoint
    About.hoverAnchorY = bestAnchorY

    -- 节点与轴右侧的书签
    for i = 1, count do
        local entry = history[i]
        local ny = NodeYForIndex(i)
        local isSelected = (i == About.timelineIndex)
        local isHovered = (i == About.hoverIndex)
        local r = (isSelected or isHovered) and 7 or 5

        if entry.stage == "Release" then
            DrawBoxShadowed(r, axisX - r, ny - r, r * 2, r * 2, APPLE_BLUE)
        elseif entry.stage == "Beta" then
            DrawBoxShadowed(r, axisX - r, ny - r, r * 2, r * 2, Color(APPLE_BLUE.r, APPLE_BLUE.g, APPLE_BLUE.b, 130))
            DrawRing(axisX, ny, r, APPLE_BLUE, true)
        else
            DrawBoxShadowed(r, axisX - r, ny - r, r * 2, r * 2, CARD_BG)
            DrawRing(axisX, ny, r, APPLE_BLUE, true)
            DrawRing(axisX, ny, r - 1, APPLE_BLUE, true)
        end

        -- 轴右侧的书签：收起时只显示简称，悬停时向右展开露出完整标题。
        -- 展开宽度受卡片右内边距限制，完整内容仍以悬停面板为准
        local shortName = entry.short or entry.display or ""
        DrawBookmarkChip(i, axisX + CHIP_GAP, ny - CHIP_H / 2, shortName, entry.title or shortName,
            x + w - 12, isSelected, isHovered)
    end

    -- 五条线的阶段点：轴上端到下端画五条淡色竖向车道，点落在各自车道上，
    -- 同一天的点因此天然分开，不再互相挤在一起；每个点再拉一条淡线回到轴
    for ti, track in ipairs(tracks) do
        local offX = TRACK_OFFSETS[ti] or 0
        local color = track.color or APPLE_BLUE
        local laneX = axisX + offX
        draw.RoundedBox(1, laneX - 0.5, axisTop, 1, tlState.axisH, Color(color.r, color.g, color.b, 40))
        for pi, point in ipairs(track.points or {}) do
            local py = TrackPointAnchorY(point)
            -- 时间段点：在车道上从起点画到终点，点落在时段中点
            if point.from and point.to then
                local y1, y2 = AxisYForDate(point.from), AxisYForDate(point.to)
                if y2 < y1 then y1, y2 = y2, y1 end
                draw.RoundedBox(2, laneX - 2, y1, 4, math.max(2, y2 - y1), Color(color.r, color.g, color.b, 160))
            end
            draw.RoundedBox(1, laneX, py - 0.5, axisX - laneX, 1, Color(color.r, color.g, color.b, 55))
            DrawBoxShadowed(TRACK_DOT_R, laneX - TRACK_DOT_R, py - TRACK_DOT_R, TRACK_DOT_R * 2, TRACK_DOT_R * 2, color)
            if About.hoverKey == ("p" .. ti .. "_" .. pi) then
                DrawRing(laneX, py, TRACK_DOT_R + 3, APPLE_INK, true)
            end
        end
    end

    DrawTextShadowed("悬停版本节点或彩点查看截图", "SourceHan_Heavy_14", x + 16, y + h - 26, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end

-- ===== 第三与第四块 开发者卡与鸣谢卡 =====
-- links 为数组，每项 { label, shown, url }
-- nameFont 可选，默认思源黑体。开发者名字用了小型大写字母，思源黑体没有那些字形，
-- 改由项目已注册的 Calibri 渲染，那张卡因此单独传字体
local function DrawCreditCard(x, y, w, h, accent, avatarPath, name, nameNote, role, links, frameP, nameFont)
    DrawCardFrame(x, y, w, h, accent, frameP)
    nameFont = nameFont or "SourceHan_Heavy_22"

    local pad = 16
    local avatarSize = 72
    local ax = x + pad
    local ay = y + (h - avatarSize) / 2

    -- 头像：圆角方形，外侧 2 像素主题色圈
    draw.RoundedBox(8, ax - 2, ay - 2, avatarSize + 4, avatarSize + 4, accent)
    local mat = GetCachedMaterial(avatarPath)
    if mat and not mat:IsError() then
        surface.SetMaterial(mat)
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRect(ax, ay, avatarSize, avatarSize)
    else
        draw.RoundedBox(8, ax, ay, avatarSize, avatarSize, APPLE_HAIRLINE)
        draw.SimpleText("头像缺失", "SourceHan_Heavy_14", ax + avatarSize / 2, ay + avatarSize / 2, APPLE_INK_MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    local tx = ax + avatarSize + 16
    draw.SimpleText(name, nameFont, tx, y + 18, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    if nameNote and nameNote ~= "" then
        local nameW = MeasureText(name, nameFont)
        draw.SimpleText(nameNote, "SourceHan_Heavy_14", tx + nameW + 8, y + 26, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end

    draw.SimpleText(role, "SourceHan_Heavy_16", tx, y + 46, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 链接行：游戏内无法打开浏览器，点一下把完整地址打到聊天框
    local linkY = y + 70
    for _, link in ipairs(links or {}) do
        local text = link.label .. "：" .. link.shown
        local tw, th = MeasureText(text, "SourceHan_Heavy_14")
        local hovered = IsMouseIn(gui.MouseX(), gui.MouseY(), tx, linkY - 2, tw, th + 4)
        draw.SimpleText(text, "SourceHan_Heavy_14", tx, linkY, hovered and accent or APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        table.insert(About.linkRows, { x = tx, y = linkY - 2, w = tw, h = th + 4, url = link.url })
        linkY = linkY + 18
    end
end

-- ===== 第五块 贡献者卡 =====
local function DrawContributorCard(x, y, w, h, frameP)
    DrawCardFrame(x, y, w, h, THEME.contributors, frameP)
    DrawCardTitle("贡献者", x + 16, y + 12, THEME.contributors)
    draw.SimpleText("贡献者名单暂空，欢迎在 Steam 或 B 站留言", "SourceHan_Heavy_16", x + 16, y + 44, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end

-- ===== 第六块 素材来源按钮 =====
local function DrawSourcesButton(x, y, w, h)
    local hovered = IsMouseIn(gui.MouseX(), gui.MouseY(), x, y, w, h)
    KARDS.CardEditor.Canvas.DrawHoverButton(x, y, w, h, "素材来源", hovered, {
        font = "SourceHan_Heavy_18",
        normalBg = APPLE_HAIRLINE,
        hoverBg = APPLE_BLUE
    })
    About.buttonRect = { x = x, y = y, w = w, h = h }
end

-- ===== 第七块 页脚 =====
local function DrawFooter(x, y, w)
    local version = KARDS.CardEditor.Version or "unknown"
    local text = "构建 " .. os.date("%Y-%m-%d") .. "　版本 " .. version
    draw.SimpleText(text, "SourceHan_Heavy_14", x, y, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end

-- ===== 悬停预览面板（四段动画） =====
-- ① 垂线从节点延伸 ② 矩形描边逐步绘制 ③ 文字淡入 ④ 图片从文字位置向左移到空白处。
-- 图片以文字块左缘为裁剪边界，落在文字范围内的部分不渲染，于是它像从文字卡片背后滑出来。
-- 该点没有配图或截图文件不存在时，第④段整段省略，只画前三段，不留占位框；
-- 四段的起止时间不变，描边的快慢因此与其他点完全一致。
local function DrawHoverPanel()
    -- 版本节点优先；没有命中版本节点时显示五条线上的阶段点
    local index = About.hoverIndex or 0
    local history = KARDS.CardEditor.VersionHistory or {}
    local entry = (index >= 1 and history[index]) or About.hoverPoint
    local nodeY, elapsed, exiting

    if entry then
        -- 命中中：记下本帧状态，鼠标离开时据此起播退场
        nodeY = About.hoverAnchorY or NodeYForIndex(index)
        elapsed = CurTime() - (About.hoverStart or 0)
        exiting = false
        About.hoverExit = nil
        About.hoverLive = {
            entry = entry,
            index = index,
            anchorY = nodeY,
            elapsed = math.min(elapsed, ANIM_T_IMAGE[2])
        }
    else
        -- 鼠标已离开：以上一帧的记录起播退场。时间从离开时的进度递减回 0，各段因此倒放
        local exit = About.hoverExit
        if not exit then
            local live = About.hoverLive
            if not live then return end
            exit = {
                entry = live.entry,
                index = live.index,
                anchorY = live.anchorY,
                start = CurTime(),
                elapsed0 = live.elapsed
            }
            About.hoverExit = exit
            About.hoverLive = nil
        end
        elapsed = (exit.elapsed0 or ANIM_T_IMAGE[2]) - (CurTime() - exit.start)
        if elapsed <= 0 then
            About.hoverExit = nil
            return
        end
        entry, index, exiting = exit.entry, exit.index or 0, true
        nodeY = exit.anchorY or NodeYForIndex(index)
    end

    -- 描边与垂线跟随悬停点所属轨道的颜色，版本节点回退品牌蓝
    local accent = entry.color or APPLE_BLUE

    local page = About.pageRect
    if not page then return end

    -- 截图缺失时第④段整体省略：不放占位框，也不为它留出时间窗
    local shotMat = (entry.shot and entry.shot ~= "") and GetCachedMaterial(entry.shot) or nil
    local hasShot = (shotMat and not shotMat:IsError()) or false

    -- 退场时描边与图片共用一段，于是两段同时进行。有没有图都按同一套时间窗走，
    -- 缺图只是让第④段不画，描边的快慢不受影响
    local stemP  = PhaseProgress(elapsed, ANIM_T_STEM)
    local rectP  = PhaseProgress(elapsed, exiting and ANIM_T_BORDER or ANIM_T_RECT)
    local textP  = PhaseProgress(elapsed, ANIM_T_TEXT)
    local imageP = hasShot and PhaseProgress(elapsed, exiting and ANIM_T_BORDER or ANIM_T_IMAGE) or 0

    -- 先量文字：标题、版本名与日期，再加全部要点
    local titleFont, lineFont = "SourceHan_Heavy_16", "SourceHan_Heavy_14"
    local notes = entry.notes or {}
    local lines = {
        { text = entry.title or "", font = titleFont, color = APPLE_INK, gap = 8 },
        { text = (entry.display or "") .. "　" .. (entry.date or ""), font = lineFont, color = APPLE_INK_MUTED, gap = 8 }
    }
    for k = 1, #notes do
        lines[#lines + 1] = { text = notes[k], font = lineFont, color = APPLE_INK_MUTED, gap = 4 }
    end

    local naturalW = 0
    for _, line in ipairs(lines) do
        naturalW = math.max(naturalW, MeasureText(line.text, line.font))
    end

    -- 面板宽由文字决定，但被左侧可用宽度与上下限夹住
    local availW = math.max(PANEL_MIN_W, tlState.axisX + 1 - (page.x + 8))
    local panelW = math.Clamp(naturalW + PANEL_PAD * 2, PANEL_MIN_W, math.min(PANEL_MAX_W, availW))
    local textW = panelW - PANEL_PAD * 2

    -- 按面板宽折行并累出实际高度，保证文字不越出面板
    local drawn, textH = {}, 0
    for _, line in ipairs(lines) do
        for _, piece in ipairs(WrapText(line.text, line.font, textW)) do
            local _, lh = MeasureText(piece, line.font)
            drawn[#drawn + 1] = { text = piece, font = line.font, color = line.color, h = lh }
            textH = textH + lh + 4
        end
        textH = textH + line.gap
    end

    local panelH = math.Clamp(textH + PANEL_PAD * 2, 64, math.min(PANEL_MAX_H, math.max(64, page.h - 16)))

    -- 面板高被上限截断时丢掉末尾放不下的行，保证竖向也不溢出
    local maxTextH = panelH - PANEL_PAD * 2
    local acc, keep = 0, 0
    for i, line in ipairs(drawn) do
        if acc + line.h + 4 > maxTextH then break end
        acc = acc + line.h + 4
        keep = i
    end
    if keep < #drawn then
        local trimmed = {}
        for i = 1, keep do trimmed[i] = drawn[i] end
        drawn = trimmed
    end

    -- 面板默认挂在锚点下方，下方放不开时改挂上方
    local dir = 1
    if nodeY + 18 + panelH > page.y + page.h - 8 then dir = -1 end

    local px = math.Clamp(tlState.axisX + 1 - panelW, page.x + 8,
        math.max(page.x + 8, page.x + page.w - panelW - 8))
    local py = nodeY + (18 * stemP + 2) * dir
    if dir < 0 then py = py - panelH end
    py = math.Clamp(py, page.y + 8, math.max(page.y + 8, page.y + page.h - panelH - 8))

    -- ① 垂线延伸
    if stemP > 0 then
        surface.SetDrawColor(accent.r, accent.g, accent.b, 220)
        surface.DrawLine(tlState.axisX, nodeY, tlState.axisX, nodeY + 18 * stemP * dir)
        surface.SetDrawColor(255, 255, 255, 255)
    end

    -- ② 先铺底，再按周长长出矩形描边。退场时底色随描边一起淡出，不做整块消失
    if rectP > 0 then
        local fillA = exiting and math.floor(235 * rectP) or 235
        draw.RoundedBox(CARD_RADIUS, px, py, panelW, panelH, Color(28, 28, 30, fillA))
        DrawPartialOutline(px, py, panelW, panelH, rectP, accent)
    end

    -- ③ 文字淡入。行高用折行后量出的高度累加，与面板高保持一致
    local textLeft = px + PANEL_PAD
    if textP > 0 then
        local a = math.floor(255 * textP)
        local ty = py + PANEL_PAD
        for _, line in ipairs(drawn) do
            draw.SimpleText(line.text, line.font, textLeft, ty,
                Color(line.color.r, line.color.g, line.color.b, a), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            ty = ty + line.h + 4
        end
    end

    -- ④ 图片从文字位置向左移动，落在文字范围内的部分不渲染。
    -- hasShot 为假时 imageP 恒为 0，这段整个不执行
    if imageP > 0 then
        local startX = textLeft
        local endX = math.max(page.x + 8, px - SHOT_W - SHOT_MARGIN)
        local imgX = startX + (endX - startX) * EaseOutCubic(imageP)
        local imgY = math.Clamp(py + panelH / 2 - SHOT_H / 2, page.y + 8,
            math.max(page.y + 8, page.y + page.h - SHOT_H - 8))

        -- 容纳样式：原图等比缩放，取能塞进 16:9 图框的最大尺寸，多出的方向留边。
        -- 整张图都画出来，既不裁也不拉；解析不出原始比例时退回整框铺满
        local drawW, drawH = SHOT_W, SHOT_H
        local aspect = GetShotAspect(entry.shot)
        if aspect > 0 then
            if aspect >= SHOT_W / SHOT_H then
                drawH = SHOT_W / aspect          -- 原图更宽，宽是约束，图框上下留边
            else
                drawW = SHOT_H * aspect          -- 原图更高，高是约束，图框左右留边
            end
        end
        local drawX = imgX + (SHOT_W - drawW) * 0.5
        local drawY = imgY + (SHOT_H - drawH) * 0.5

        -- 从文字卡片背后滑出：落在文字块左缘以内的部分不画
        local visibleW = math.min(drawW, math.max(0, textLeft - drawX))
        if visibleW > 1 then
            surface.SetMaterial(shotMat)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.DrawTexturedRectUV(drawX, drawY, visibleW, drawH, 0, 0, visibleW / drawW, 1)
        end
    end
end

-- ===== 整页绘制 =====
function KARDS.CardEditor.Canvas.DrawAboutPage(x, y, w, h)
    About.linkRows = {}

    -- 刚进入关于页时重播卡片描边动画。在页内时每帧都会调用本函数，间隔只有十几毫秒，
    -- 所以离上一帧超过 0.4 秒就判定为重新进入，与 CurrentPage 的状态跟踪无关
    if not About.lastDrawTime or (CurTime() - About.lastDrawTime) > 0.4 then
        About.introStart = CurTime()
        -- 重新进入时清掉上一次的悬停残留，否则会给一个早已离开的点补播退场
        About.hoverKey = ""
        About.hoverExit = nil
        About.hoverLive = nil
    end
    About.lastDrawTime = CurTime()

    -- 左列卡片的总高，右列竖轴固定不滚动
    local totalH = 8
        + H_IDENTITY + GAP
        + H_CREDIT + GAP
        + H_CREDIT + GAP
        + H_CONTRIB + GAP
        + BTN_H + GAP
        + H_FOOTER + 8
    About.scrollMax = math.max(0, totalH - h)
    About.scrollOffset = math.Clamp(About.scrollOffset or 0, 0, About.scrollMax)

    render.SetScissorRect(x, y, x + w, y + h, true)

    About.pageRect = { x = x, y = y, w = w, h = h }

    -- 右列：竖向版本数轴，占满内容高度，不随滚动
    DrawVerticalTimeline(x + w - 12 - TIMELINE_W, y + 8, TIMELINE_W, h - 16, CardProgress("timeline"))

    -- 左列：卡片，随滚轮滚动
    local cx = x + 12
    local cw = math.max(200, w - 24 - TIMELINE_W - GAP)
    local cy = y + 8 - About.scrollOffset

    DrawIdentityCard(cx, cy, cw, H_IDENTITY, CardProgress("identity"))
    cy = cy + H_IDENTITY + GAP

    DrawCreditCard(cx, cy, cw, H_CREDIT, THEME.developer, AVATAR_PATHS.developer,
        "Oak_ᴡᴏʀʟᴅ", nil, "开发与设计，单人开发", {
            { label = "Steam", url = "https://steamcommunity.com/id/oak_world/", shown = "steamcommunity.com/id/oak_world/" },
            { label = "B 站", url = "https://b23.tv/q7IhCs6", shown = "b23.tv/q7IhCs6" }
        }, CardProgress("developer"), "Calibri_24")
    cy = cy + H_CREDIT + GAP

    DrawCreditCard(cx, cy, cw, H_CREDIT, THEME.thanks, AVATAR_PATHS.thanks,
        "星野爱你qwq", "Steam 个人界面现用名为喵牢星", "Alpha 阶段唯一测试者，也是开发路上唯一的支持者", {
            { label = "Steam", url = "https://steamcommunity.com/profiles/76561199048273860/", shown = "steamcommunity.com/profiles/76561199048273860/" }
        }, CardProgress("thanks"))
    cy = cy + H_CREDIT + GAP

    DrawContributorCard(cx, cy, cw, H_CONTRIB, CardProgress("contributors"))
    cy = cy + H_CONTRIB + GAP

    DrawSourcesButton(cx, cy, BTN_W, BTN_H)
    cy = cy + BTN_H + GAP

    DrawFooter(cx, cy, cw)

    -- 悬停预览动画：画在左列卡片之上
    DrawHoverPanel()

    render.SetScissorRect(0, 0, 0, 0, false)
end

-- ===== 素材来源弹窗 =====
function KARDS.CardEditor.Canvas.DrawAboutSourcesOverlay()
    if not About.sourcesVisible then return end

    local scrW, scrH = ScrW(), ScrH()
    surface.SetDrawColor(0, 0, 0, 180)
    surface.DrawRect(0, 0, scrW, scrH)

    local pw, ph = 720, 420
    local px, py = (scrW - pw) / 2, (scrH - ph) / 2
    About.panelRect = { x = px, y = py, w = pw, h = ph }

    draw.RoundedBox(12, px - 1, py - 1, pw + 2, ph + 2, APPLE_HAIRLINE)
    draw.RoundedBox(12, px, py, pw, ph, APPLE_WHITE)

    draw.SimpleText("素材来源", "SourceHan_Heavy_22", px + 24, py + 16, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText("此处仅列出来源与上传者，不代表已获得再分发授权", "SourceHan_Heavy_14", px + 24, py + 44, APPLE_INK_MUTED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

    -- 关闭按钮
    local closeW, closeH = 64, 26
    local closeX = px + pw - closeW - 16
    local closeY = py + 16
    About.closeRect = { x = closeX, y = closeY, w = closeW, h = closeH }
    local closeHovered = IsMouseIn(gui.MouseX(), gui.MouseY(), closeX, closeY, closeW, closeH)
    KARDS.CardEditor.Canvas.DrawHoverButton(closeX, closeY, closeW, closeH, "关闭", closeHovered, {
        font = "SourceHan_Heavy_16",
        normalBg = APPLE_HAIRLINE,
        hoverBg = APPLE_BLUE
    })

    -- 组装行数据：先音乐，再音效，最后声明
    local credits = KARDS.CardEditor.SourceCredits or {}
    local music = credits.music or {}
    local sounds = credits.sounds or {}
    local notes = credits.notes or {}

    local rows = {}
    table.insert(rows, { header = true, text = "音乐（B 站收藏夹「背景音乐」，共 " .. #music .. " 条）" })
    for _, item in ipairs(music) do
        local tracks = item.tracks or ""
        if item.used == false then tracks = tracks .. "（未采用）" end
        table.insert(rows, {
            text = (item.author or "") .. " · " .. tracks,
            right = item.homepage or "",
            muted = (item.used == false)
        })
    end
    table.insert(rows, { header = true, text = "音效（B 站收藏夹以外）" })
    for _, item in ipairs(sounds) do
        table.insert(rows, {
            text = (item.source or "") .. " · " .. (item.content or "") .. " · " .. (item.date or ""),
            right = item.homepage or ""
        })
    end
    table.insert(rows, { header = true, text = "声明" })
    for _, note in ipairs(notes) do
        table.insert(rows, { text = note, muted = true })
    end

    -- 列表区域
    local listX = px + 24
    local listY = py + 74
    local listW = pw - 48
    local listH = ph - 74 - 20
    About.listRect = { x = listX, y = listY, w = listW, h = listH }

    local rowH = 22
    local totalH = #rows * rowH
    About.sourcesScrollMax = math.max(0, totalH - listH)
    About.sourcesScroll = math.Clamp(About.sourcesScroll or 0, 0, About.sourcesScrollMax)

    render.SetScissorRect(listX, listY, listX + listW, listY + listH, true)
    for i, row in ipairs(rows) do
        local ry = listY + (i - 1) * rowH - About.sourcesScroll
        if ry + rowH >= listY and ry <= listY + listH then
            if row.header then
                draw.SimpleText(row.text, "SourceHan_Heavy_16", listX, ry + 4, APPLE_INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            else
                local color = row.muted and APPLE_INK_MUTED or APPLE_INK
                draw.SimpleText(row.text, "SourceHan_Heavy_14", listX, ry + 4, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
                if row.right and row.right ~= "" then
                    draw.SimpleText(row.right, "SourceHan_Heavy_14", listX + listW, ry + 4, APPLE_INK_MUTED, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
                end
            end
        end
    end
    render.SetScissorRect(0, 0, 0, 0, false)

    -- 滚动条
    if About.sourcesScrollMax > 0 then
        local barW, barH = 4, math.max(24, listH * (listH / totalH))
        local barY = listY + (About.sourcesScroll / About.sourcesScrollMax) * (listH - barH)
        draw.RoundedBox(2, listX + listW + 8, barY, barW, barH, APPLE_INK_MUTED)
    end
end

-- ===== 输入：素材来源弹窗 =====
function KARDS.CardEditor.Canvas.HandleAboutSourcesInput(mx, my, isLeftReleased, isLeftDown)
    if not About.sourcesVisible then return false end

    -- 滚轮：列表滚动
    if About.listRect then
        if C._wheelZoomIn then
            C._wheelZoomIn = false
            About.sourcesScroll = math.Clamp(About.sourcesScroll - 44, 0, About.sourcesScrollMax)
        elseif C._wheelZoomOut then
            C._wheelZoomOut = false
            About.sourcesScroll = math.Clamp(About.sourcesScroll + 44, 0, About.sourcesScrollMax)
        end
    end

    if isLeftReleased then
        local closeRect = About.closeRect
        if closeRect and IsMouseIn(mx, my, closeRect.x, closeRect.y, closeRect.w, closeRect.h) then
            About.sourcesVisible = false
            if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayClick then
                KARDS.CardEditor.Audio.PlayClick()
            end
            return true
        end

        local panel = About.panelRect
        if panel and not IsMouseIn(mx, my, panel.x, panel.y, panel.w, panel.h) then
            About.sourcesVisible = false
            return true
        end
    end

    -- 弹窗打开期间，其余输入一律不再下传
    return true
end

-- ===== 输入：关于页本体 =====
function KARDS.CardEditor.Canvas.HandleAboutPageInput(mx, my, isLeftReleased, isLeftDown)
    -- 滚轮：页内滚动。关于页不缩放画布，这里把 CreateMove 设下的滚轮标记消费掉
    if C._wheelZoomIn then
        C._wheelZoomIn = false
        About.scrollOffset = math.Clamp(About.scrollOffset - 48, 0, About.scrollMax)
    elseif C._wheelZoomOut then
        C._wheelZoomOut = false
        About.scrollOffset = math.Clamp(About.scrollOffset + 48, 0, About.scrollMax)
    end

    -- 素材来源按钮：点击打开弹窗
    local btn = About.buttonRect
    if btn and isLeftReleased and IsMouseIn(mx, my, btn.x, btn.y, btn.w, btn.h) then
        About.sourcesVisible = true
        About.sourcesScroll = 0
        if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayClick then
            KARDS.CardEditor.Audio.PlayClick()
        end
        return true
    end

    -- 链接行：游戏内打不开浏览器，点一下把完整地址打到聊天框，方便复制
    if isLeftReleased then
        for _, row in ipairs(About.linkRows or {}) do
            if IsMouseIn(mx, my, row.x, row.y, row.w, row.h) then
                chat.AddText(Color(0, 102, 204), "[Kards] ", Color(245, 245, 247), row.url)
                if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayClick then
                    KARDS.CardEditor.Audio.PlayClick()
                end
                return true
            end
        end
    end

    -- 竖轴：点节点切换选中。预览由悬停驱动，这里不需要拖动
    local history = KARDS.CardEditor.VersionHistory or {}
    if #history > 0 and isLeftReleased and math.abs(mx - tlState.axisX) <= 26 then
        for i = 1, #history do
            if math.abs(my - NodeYForIndex(i)) <= 14 then
                About.timelineIndex = i
                if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayClick then
                    KARDS.CardEditor.Audio.PlayClick()
                end
                break
            end
        end
    end

    -- 关于页消费全部输入，画布的框选与节点拖拽不参与本页
    return true
end
