--[[
=======================================================================================
BGM 扩展国家菜单模块 (BGM Menu)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的 BGM 扩展国家菜单与曲目列表模块，负责顶栏 BGM 倒三角
按钮的展开面板，以及右键 BGM 圆按钮打开的曲目列表面板的开关与状态清理。

包含功能：
  - ToggleBGMMenu / OpenBGMMenu / CloseBGMMenu（展开国家菜单开关）
  - OpenBGMPlaylist / CloseBGMPlaylist（曲目列表面板开关）

源文件：cl_canvas_editor.lua
  - 功能函数：行 1842~2192
=======================================================================================
]]

-- 防御性命名空间初始化：确保即使本文件在 GMod 自动加载阶段先于
-- sh_card_editor_loader.lua 被加载，KARDS.CardEditor.Canvas 也已就绪
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}

-- ===== 展开 BGM 国家菜单（顶栏倒三角按钮） =====

-- 切换展开面板显隐
function KARDS.CardEditor.Canvas.ToggleBGMMenu()
    if KARDS.CardEditor.Canvas.BGMMenuExpanded then
        KARDS.CardEditor.Canvas.CloseBGMMenu()
    else
        KARDS.CardEditor.Canvas.OpenBGMMenu()
    end
end

-- 打开展开面板：遮罩（点击外部关闭） + 横向一排扩展国家圆按钮
function KARDS.CardEditor.Canvas.OpenBGMMenu()
    local root = KARDS.CardEditor.Canvas.RootPanel
    if not IsValid(root) then return end

    -- 与曲目列表面板互斥：先关闭已打开的曲目列表
    KARDS.CardEditor.Canvas.CloseBGMPlaylist()

    local btnSize = 30
    local spacing = 6
    local padding = 5
    local perRow = 5 -- 每行按钮数，超过自动换行
    local expandCountries = KARDS.CardEditor.Canvas.BGMExpandCountries
    local colCount = math.min(#expandCountries, perRow)
    local rowCount = math.ceil(#expandCountries / perRow)
    local totalW = colCount * btnSize + (colCount - 1) * spacing
    local totalH = rowCount * btnSize + (rowCount - 1) * spacing

    -- 遮罩：拦截外部点击并关闭菜单（低于按钮 zpos，不影响按钮点击）
    local mask = vgui.Create("DPanel", root)
    mask:SetPos(0, 0)
    mask:SetSize(root:GetWide(), root:GetTall())
    mask:SetZPos(90)
    mask:SetMouseInputEnabled(true)
    mask.Paint = function() end
    mask.OnMousePressed = function()
        -- 遮罩点击本帧即将移除面板：预置 lastLeft 抑制同帧总控台自绘点击检测（穿透防护，见 cl_appearance_editor.lua DrawCardAppearanceEditor）
        KARDS.CardEditor.Canvas._AppearanceLastLeft = true
        KARDS.CardEditor.Canvas.CloseBGMMenu()
    end
    KARDS.CardEditor.Canvas.BGMMenuMask = mask

    -- 面板定位：位于扩展按钮正下方，右移 2 个按钮直径
    local panelX, panelY = 0, 0
    local extendBtn = KARDS.CardEditor.Canvas.BGMExtendButton
    if IsValid(extendBtn) then
        local bx, by = extendBtn:GetPos()
        panelX = bx + 2 * btnSize
        panelY = by + extendBtn:GetTall() + 6
    end

    local panel = vgui.Create("DPanel", root)
    panel:SetPos(panelX, panelY)
    panel:SetSize(totalW + padding * 2, totalH + padding * 2)
    panel:SetZPos(110)
    panel:SetMouseInputEnabled(true)
    panel.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(42, 42, 42, 240))
        draw.RoundedBox(2, 1, 1, w - 2, h - 2, Color(110, 110, 110, 160))
    end
    KARDS.CardEditor.Canvas.BGMMenuPanel = panel

    -- 扩展国家圆按钮网格布局（每行 perRow 个，与主行按钮同款样式）
    KARDS.CardEditor.Canvas.BGMMenuButtons = {}
    for i, country in ipairs(expandCountries) do
        local col = (i - 1) % perRow
        local row = math.floor((i - 1) / perRow)
        local btn = vgui.Create("DButton", panel)
        btn:SetPos(padding + col * (btnSize + spacing), padding + row * (btnSize + spacing))
        btn:SetSize(btnSize, btnSize)
        btn:SetText("")
        btn.countryData = country -- 悬停简介（打字机动画）读取的国家数据（含二战简介 description）
        btn.Paint = function(self, w, h)
            local iconMat = country.iconMat
            local isHovered = self:IsHovered()
            local bgColor = Color(60, 60, 60)
            if isHovered and country.color then
                bgColor = Color(math.min(country.color.r + 20, 255), math.min(country.color.g + 20, 255), math.min(country.color.b + 20, 255))
            elseif isHovered then
                bgColor = Color(80, 80, 80)
            end
            draw.RoundedBox(btnSize / 2, 0, 0, w, h, bgColor)
            if iconMat and not iconMat:IsError() then
                surface.SetDrawColor(255, 255, 255, 255)
                surface.SetMaterial(iconMat)
                local pad = 3
                surface.DrawTexturedRect(pad, pad, w - pad * 2, h - pad * 2)
            else
                -- 无图标时显示简称（外部注册风格可用 shortName，如 "C"），否则显示名称首字
                draw.SimpleText(country.shortName or country.name:sub(1, 1), "SourceHan_Heavy_12", w / 2, h / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end
        btn.DoClick = function()
            KARDS.CardEditor.Canvas.SelectEditorBGM(country.id)
            KARDS.CardEditor.Canvas.CloseBGMMenu()
        end
        btn.DoRightClick = function()
            -- 右键：在鼠标处展开该扩展风格的曲目列表面板
            KARDS.CardEditor.Canvas.OpenBGMPlaylist(country.id)
        end
        table.insert(KARDS.CardEditor.Canvas.BGMMenuButtons, btn)
    end

    KARDS.CardEditor.Canvas.BGMMenuExpanded = true
end

-- 关闭展开面板并清理
function KARDS.CardEditor.Canvas.CloseBGMMenu()
    KARDS.CardEditor.Canvas.BGMMenuExpanded = false
    -- 清空悬停简介状态（菜单关闭时提示随按钮一并消失）
    if KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM then
        KARDS.CardEditor.Compat.DynamicBGM.BGMHoverState = nil
    end
    if IsValid(KARDS.CardEditor.Canvas.BGMMenuMask) then
        KARDS.CardEditor.Canvas.BGMMenuMask:Remove()
    end
    KARDS.CardEditor.Canvas.BGMMenuMask = nil
    if IsValid(KARDS.CardEditor.Canvas.BGMMenuPanel) then
        KARDS.CardEditor.Canvas.BGMMenuPanel:Remove()
    end
    KARDS.CardEditor.Canvas.BGMMenuPanel = nil
    KARDS.CardEditor.Canvas.BGMMenuButtons = nil
end

-- ===== BGM 曲目列表面板（右键 BGM 圆按钮，2026-08-14） =====

-- 在鼠标处打开始某国家（风格）的曲目列表面板：最多同时展示 11 曲目，其余滚轮滚动选择
function KARDS.CardEditor.Canvas.OpenBGMPlaylist(countryId)
    local root = KARDS.CardEditor.Canvas.RootPanel
    if not IsValid(root) then return end

    local bgmCompat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
    if not bgmCompat then return end

    local countryData = bgmCompat.CountryMusic and bgmCompat.CountryMusic[countryId]
    if not countryData or not countryData.tracks or #countryData.tracks == 0 then return end
    local tracks = countryData.tracks

    -- 与展开国家面板及其他曲目列表互斥：先清理旧面板
    KARDS.CardEditor.Canvas.CloseBGMPlaylist()
    KARDS.CardEditor.Canvas.CloseBGMMenu()

    -- 遮罩：拦截外部点击并关闭曲目列表（与展开面板同款机制）
    local mask = vgui.Create("DPanel", root)
    mask:SetPos(0, 0)
    mask:SetSize(root:GetWide(), root:GetTall())
    mask:SetZPos(90)
    mask:SetMouseInputEnabled(true)
    mask.Paint = function() end
    mask.OnMousePressed = function()
        -- 遮罩点击本帧即将移除面板：预置 lastLeft 抑制同帧总控台自绘点击检测（穿透防护，见 cl_appearance_editor.lua DrawCardAppearanceEditor）
        KARDS.CardEditor.Canvas._AppearanceLastLeft = true
        KARDS.CardEditor.Canvas.CloseBGMPlaylist()
    end
    KARDS.CardEditor.Canvas.BGMTrackListMask = mask

    -- 面板尺寸与定位（鼠标处；root 为全屏 (0,0) 面板，转局部坐标后取整）
    local rowH = 24
    local maxVisible = 11 -- 一个曲目列表最多同时展示 11 曲目，其余滚轮滚动选择
    local padding = 6
    local toolbarH = 24 -- 顶部工具条（模式/上一首/下一首）高度
    local toolbarGap = 6
    local panelW = 220
    local trackCount = #tracks
    local visibleRows = math.min(trackCount, maxVisible)
    local scrollH = visibleRows * rowH
    local panelH = padding * 2 + toolbarH + toolbarGap + scrollH

    local mouseX, mouseY = root:ScreenToLocal(gui.MousePos())
    local panelX = math.max(4, math.min(mouseX, root:GetWide() - panelW - 4))
    local panelY = math.max(4, math.min(mouseY, root:GetTall() - panelH - 4))

    local panel = vgui.Create("DPanel", root)
    panel:SetPos(panelX, panelY)
    panel:SetSize(panelW, panelH)
    panel:SetZPos(110)
    panel:SetMouseInputEnabled(true)
    panel.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(42, 42, 42, 245))
        draw.RoundedBox(2, 1, 1, w - 2, h - 2, Color(110, 110, 110, 160))
    end
    KARDS.CardEditor.Canvas.BGMTrackListPanel = panel

    -- 顶部工具条：播放模式 / 上一首 / 下一首（图标 materials/kards/editor/ui/*.png，2026-08-14）
    -- 着色规则：选中的模式图标为深橙色；玩家鼠标按下的为橙色；其余保持图标原色
    local iconBase = "materials/kards/editor/ui/"
    local modeIconMats = {
        random     = file.Exists(iconBase .. "random.png", "GAME") and Material(iconBase .. "random.png", "noclamp smooth") or nil,
        random_all = file.Exists(iconBase .. "random_all.png", "GAME") and Material(iconBase .. "random_all.png", "noclamp smooth") or nil,
        loop       = file.Exists(iconBase .. "loop.png", "GAME") and Material(iconBase .. "loop.png", "noclamp smooth") or nil,
        loop_all   = file.Exists(iconBase .. "loop_all.png", "GAME") and Material(iconBase .. "loop_all.png", "noclamp smooth") or nil,
        single     = file.Exists(iconBase .. "single.png", "GAME") and Material(iconBase .. "single.png", "noclamp smooth") or nil
    }
    local prevIconMat = file.Exists(iconBase .. "prev.png", "GAME") and Material(iconBase .. "prev.png", "noclamp smooth") or nil
    local nextIconMat = file.Exists(iconBase .. "next.png", "GAME") and Material(iconBase .. "next.png", "noclamp smooth") or nil
    -- 图标原始像素尺寸（Material:Width/Height 在纹理解包为 2 的幂时返回失真值，用常量表）
    local modeIconSizes = {
        random     = { 31, 31 },
        random_all = { 31, 31 },
        loop       = { 35, 39 },
        loop_all   = { 35, 39 },
        single     = { 35, 39 },
    }
    local prevIconSize = { 23, 23 }
    local nextIconSize = { 23, 23 }
    local darkOrange = Color(205, 120, 25) -- 深橙：模式图标选中态
    local orange = Color(255, 150, 40) -- 橙：鼠标按下态
    local iconFit = 20 -- 图标最大显示边长（按钮 24 内缩 2px 边距，2026-08-14 用户反馈图标太大）

    local function DrawTrackIcon(iconMat, w, h, color, srcW, srcH)
        if not iconMat or iconMat:IsError() then return end
        -- 按原始宽高比缩放到 iconFit 内居中，避免拉伸铺满按钮变形/过大
        local scale = math.min(iconFit / srcW, iconFit / srcH)
        local dw, dh = srcW * scale, srcH * scale
        surface.SetDrawColor(color.r, color.g, color.b, 255)
        surface.SetMaterial(iconMat)
        surface.DrawTexturedRect((w - dw) / 2, (h - dh) / 2, dw, dh)
    end
    local function DrawToolButton(self, w, h, iconMat, isModeButton, iconSize)
        if self:IsHovered() then
            draw.RoundedBox(3, 0, 0, w, h, Color(90, 90, 90, 110))
        end
        if self:IsDown() then -- DButton 无 IsDepressed（GMod 内置 dbutton.lua），按下态用 IsDown 返回 self.Depressed
            DrawTrackIcon(iconMat, w, h, orange, iconSize[1], iconSize[2])
        elseif isModeButton then
            DrawTrackIcon(iconMat, w, h, darkOrange, iconSize[1], iconSize[2])
        else
            DrawTrackIcon(iconMat, w, h, Color(255, 255, 255), iconSize[1], iconSize[2])
        end
    end

    local btnSize = 24
    local btnSpacing = 6
    local toolbarX = padding
    local toolbarY = padding

    -- 模式按键：显示当前播放模式图标，点击循环切换播放模式（持久记忆）
    local modeBtn = vgui.Create("DButton", panel)
    modeBtn:SetPos(toolbarX, toolbarY)
    modeBtn:SetSize(btnSize, btnSize)
    modeBtn:SetText("")
    modeBtn:SetZPos(2)
    modeBtn.Paint = function(self, w, h)
        local pm = bgmCompat.PlayMode
        DrawToolButton(self, w, h, modeIconMats[pm], true, modeIconSizes[pm] or { 31, 31 })
    end
    modeBtn.DoClick = function()
        bgmCompat.CyclePlayMode()
    end
    KARDS.CardEditor.Canvas.BGMTrackListModeBtn = modeBtn

    -- 上一首
    local prevBtn = vgui.Create("DButton", panel)
    prevBtn:SetPos(toolbarX + btnSize + btnSpacing, toolbarY)
    prevBtn:SetSize(btnSize, btnSize)
    prevBtn:SetText("")
    prevBtn:SetZPos(2)
    prevBtn.Paint = function(self, w, h)
        DrawToolButton(self, w, h, prevIconMat, false, prevIconSize)
    end
    prevBtn.DoClick = function()
        bgmCompat.PlayPrevTrack()
    end
    KARDS.CardEditor.Canvas.BGMTrackListPrevBtn = prevBtn

    -- 下一首
    local nextBtn = vgui.Create("DButton", panel)
    nextBtn:SetPos(toolbarX + (btnSize + btnSpacing) * 2, toolbarY)
    nextBtn:SetSize(btnSize, btnSize)
    nextBtn:SetText("")
    nextBtn:SetZPos(2)
    nextBtn.Paint = function(self, w, h)
        DrawToolButton(self, w, h, nextIconMat, false, nextIconSize)
    end
    nextBtn.DoClick = function()
        bgmCompat.PlayNextTrack()
    end
    KARDS.CardEditor.Canvas.BGMTrackListNextBtn = nextBtn

    -- 曲目滚动区：trackCount > maxVisible 时 DScrollPanel 自动出现滚动条，滚轮滚动选择
    local scroll = vgui.Create("DScrollPanel", panel)
    scroll:SetPos(padding, padding + toolbarH + toolbarGap)
    scroll:SetSize(panelW - padding * 2, scrollH)
    scroll:SetZPos(1)
    -- 滚动条样式贴合面板暗色风格
    local vbar = scroll:GetVBar()
    vbar.Paint = function(self, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(60, 60, 60, 120))
    end
    vbar.btnUp.Paint = function(self, w, h)
        draw.RoundedBox(2, 0, 0, w, h, Color(70, 70, 70))
    end
    vbar.btnDown.Paint = function(self, w, h)
        draw.RoundedBox(2, 0, 0, w, h, Color(70, 70, 70))
    end
    vbar.btnGrip.Paint = function(self, w, h)
        draw.RoundedBox(4, 2, 2, w - 4, h - 4, Color(160, 160, 160))
    end
    KARDS.CardEditor.Canvas.BGMTrackListScroll = scroll

    local canvas = scroll:GetCanvas()
    canvas:SetSize(scroll:GetWide(), trackCount * rowH)
    canvas:SetPos(0, 0)

    -- 曲目行按钮：hover 高亮、当前播放曲目标记；点击播放该曲并关闭面板
    KARDS.CardEditor.Canvas.BGMTrackListButtons = {}
    for i, track in ipairs(tracks) do
        local row = vgui.Create("DButton", canvas)
        row:SetPos(0, (i - 1) * rowH)
        row:SetSize(canvas:GetWide(), rowH)
        row:SetText("")
        row.trackIndex = i
        row.Paint = function(self, w, h)
            local isHovered = self:IsHovered()
            local isPlaying = bgmCompat.CurrentCountry == countryId and bgmCompat.CurrentTrackIndex == i
            if isHovered then
                draw.RoundedBox(3, 0, 0, w, h, Color(90, 130, 190, 120))
            end
            if isPlaying then
                draw.SimpleText("▶", "SourceHan_Heavy_12", 12, h / 2, Color(110, 190, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                draw.SimpleText(track.name or tostring(track.n), "SourceHan_Heavy_16", 24, h / 2, Color(110, 190, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            else
                draw.SimpleText(track.name or tostring(track.n), "SourceHan_Heavy_16", 10, h / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
        end
        row.DoClick = function()
            bgmCompat.PlaySpecificTrack(countryId, i)
            KARDS.CardEditor.Canvas.CloseBGMPlaylist()
            KARDS.CardEditor.Canvas.NotifyBGMPlaying(countryId)
        end
        table.insert(KARDS.CardEditor.Canvas.BGMTrackListButtons, row)
    end
end

-- 关闭 BGM 曲目列表面板并清理
function KARDS.CardEditor.Canvas.CloseBGMPlaylist()
    if IsValid(KARDS.CardEditor.Canvas.BGMTrackListMask) then
        KARDS.CardEditor.Canvas.BGMTrackListMask:Remove()
    end
    KARDS.CardEditor.Canvas.BGMTrackListMask = nil
    if IsValid(KARDS.CardEditor.Canvas.BGMTrackListPanel) then
        KARDS.CardEditor.Canvas.BGMTrackListPanel:Remove()
    end
    KARDS.CardEditor.Canvas.BGMTrackListPanel = nil
    KARDS.CardEditor.Canvas.BGMTrackListScroll = nil
    KARDS.CardEditor.Canvas.BGMTrackListButtons = nil
    KARDS.CardEditor.Canvas.BGMTrackListModeBtn = nil
    KARDS.CardEditor.Canvas.BGMTrackListPrevBtn = nil
    KARDS.CardEditor.Canvas.BGMTrackListNextBtn = nil
end
