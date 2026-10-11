--[[
=======================================================================================
文件管理器与音效命名模块 (File Manager)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的文件管理器与音效伪命名模块，负责特效/音效/子类型
文件树的构建与导出、文件管理器与音效管理器的绘制交互、F2 显示名重命名，以及子类型
选择器绘制。

包含功能：
  - SaveSoundAliases / SoundAliases（音效伪命名映射与持久化）
  - BuildEffectFileTree / BuildSoundFileTree / BuildSubtypeFileTree（文件树构建与导出）
  - DrawFileManagerInternal（文件管理器通用绘制内核）
  - DrawEffectFileManager / DrawSoundFileManager / DrawSubtypeSelector（三个封装绘制入口）
  - CommitSoundRename / DrawRenameInputBox / ManageRenameTextEntry（F2 重命名交互）
  - CleanupRenameInput（编辑器关闭时清理重命名输入框）

源文件：cl_canvas_editor.lua
  - 历史行号：行 9~28、1303~1507、3012~3727
=======================================================================================
]]

-- 防御性命名空间初始化：确保即使本文件在 GMod 自动加载阶段先于
-- sh_card_editor_loader.lua 被加载，KARDS.CardEditor.Canvas 也已就绪
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}

-- ===== 音效伪命名系统（F2 重命名显示名，不改磁盘文件） =====
-- 维护"音频完整路径 → 自定义显示名"映射，存 garrysmod/data/kards_sound_aliases.json；
-- 文件选择器展示条目时优先显示 json 内的名称（见 BuildSoundFileTree 的 display 应用）。
local SoundAliasesFile = "kards_sound_aliases.json"
local SoundAliases = util.JSONToTable(file.Read(SoundAliasesFile, "DATA") or "") or {}

local function SaveSoundAliases()
    file.Write(SoundAliasesFile, util.TableToJSON(SoundAliases, true))
end

-- F2 按下标记（KeyPress 捕获，绘制时消费；无选中文件时丢弃防残留误触发）
local F2Pressed = false
hook.Add("KeyPress", "KARDS_SoundRename_F2", function(ply, key)
    if key == KEY_F2 then F2Pressed = true end
end)

-- 命名输入框状态（选中文件后按 F2 打开，覆盖在选中行位置）：
--   fullPath = 被命名音频的完整路径，text = 输入的新显示名，x/y/w/h = 输入框区域
local RenameInputState = nil
local RenameTextEntry = nil -- 透明 DTextEntry，捕获 IME 键盘输入

-- 特效文件系统：英文名→中文显示名映射（GMod 文件系统不支持中文名）
local EffectDisplayNames = {
    infantry = "步兵",
    tank = "坦克",
    artillery = "炮兵",
    fighter = "战斗机",
    bomber = "轰炸机",
    attack = "攻击特效",
}

-- 构建特效文件树（从真实文件系统读取）
local function BuildEffectFileTree()
    local rootPath = "effects_data/effects"
    local function scanDir(dirPath)
        local files, dirs = file.Find(dirPath .. "/*", "DATA")
        local children = {}
        if dirs then
            table.sort(dirs)
            for _, dirName in ipairs(dirs) do
                local subPath = dirPath .. "/" .. dirName
                local display = EffectDisplayNames[dirName] or dirName
                table.insert(children, {
                    name = dirName,
                    display = display,
                    type = "folder",
                    children = scanDir(subPath)
                })
            end
        end
        if files then
            table.sort(files)
            for _, fileName in ipairs(files) do
                local display = EffectDisplayNames[fileName] or fileName
                table.insert(children, {
                    name = fileName,
                    display = display,
                    type = "file"
                })
            end
        end
        return children
    end
    local children = scanDir(rootPath)
    return {
        name = "特效",
        type = "folder",
        children = children
    }
end

-- 初始化特效文件树
KARDS.CardEditor.Canvas.EffectFileSystem = BuildEffectFileTree()
-- 特效文件管理器状态
KARDS.CardEditor.Canvas.EffectFileState = KARDS.CardEditor.Canvas.EffectFileState or {
    navStack = {},          -- 导航路径栈，存储 folder entry
    selectedEntry = nil,    -- 当前选中的 file entry
    showConfirm = false,    -- 是否显示确认/取消按钮
    animOffset = 0,         -- 页面滑动偏移量（像素）
    showOverlay = false,    -- 是否显示选择成功叠加层
}

--[[
    音效文件树（音效选择器专用）：
    - 第一层固定两个文件夹：「游戏内置音效」(addons/Kards/sound，GAME 文件系统)、
      「玩家自定义音效」(garrysmod/data/kards_sounds，DATA，不存在则自动创建)。
    - 仅收录音效扩展名(.ogg/.wav/.mp3)；中文文件名条目标记 disabled（BASS 无法
      播放非 ASCII 路径，见 cl_dynamic_bgm_compat.lua 注释），显示但禁用。
    - 无有效音效的空文件夹递归剪枝。
    - 文件条目 fullPath 为 garrysmod 根相对路径：GAME 侧 "sound/…"、DATA 侧
      "data/kards_sounds/…"，供 sound.PlayFile / sound.Play 直接播放。
]]
local SoundExtensions = { ogg = true, wav = true, mp3 = true }

local function IsAsciiName(name)
    for i = 1, #name do
        if name:byte(i) > 127 then return false end
    end
    return true
end

local function BuildSoundFileTree()
    local function scan(path, root, fullPathPrefix)
        local files, dirs = file.Find(path .. "/*", root)
        local children = {}
        if dirs then
            table.sort(dirs)
            for _, dirName in ipairs(dirs) do
                local subPath = path .. "/" .. dirName
                local childFolder = {
                    name = dirName,
                    display = dirName,
                    type = "folder",
                    fullPath = fullPathPrefix .. "/" .. dirName,
                    children = scan(subPath, root, fullPathPrefix .. "/" .. dirName),
                }
                -- 剪枝：无有效音效文件的空文件夹不显示
                if #childFolder.children > 0 then
                    table.insert(children, childFolder)
                end
            end
        end
        if files then
            table.sort(files)
            for _, fileName in ipairs(files) do
                local ext = string.match(fileName, "%.([^.]+)$")
                if ext and SoundExtensions[string.lower(ext)] then
                    table.insert(children, {
                        name = fileName,
                        -- 伪命名优先：展示 json 内的自定义名称（SoundAliases 映射磁盘路径→显示名）
                        display = SoundAliases[fullPathPrefix .. "/" .. fileName] or fileName,
                        type = "file",
                        fullPath = fullPathPrefix .. "/" .. fileName,
                        disabled = not IsAsciiName(fileName),
                    })
                end
            end
        end
        return children
    end
    file.CreateDir("kards_sounds") -- 玩家自定义音效目录（幂等，编辑器加载时创建）
    local children = {
        -- Kards 模组专属音效（sound/kards：牌桌对战音效，与编辑器音效 sound/editor 区分）
        {
            name = "kards",
            display = "Kards模组音效",
            type = "folder",
            fullPath = "sound/kards",
            children = scan("sound/kards", "GAME", "sound/kards"),
        },
        {
            name = "sound",
            -- GAME 文件系统 sound/ 为全部来源合并视图（GMod 自带 + 全部模组 + 挂载的
            -- 起源引擎游戏音频），故命名为"全部音效"而非"游戏内置音效"
            display = "全部音效",
            type = "folder",
            fullPath = "sound",
            children = scan("sound", "GAME", "sound"),
        },
        {
            name = "kards_sounds",
            display = "玩家自定义音效",
            type = "folder",
            fullPath = "kards_sounds",
            children = scan("kards_sounds", "DATA", "data/kards_sounds"),
        },
    }
    return {
        name = "音效",
        type = "folder",
        children = children,
    }
end

-- 音效文件系统与每事件槽位独立导航状态
KARDS.CardEditor.Canvas.SoundFileSystem = BuildSoundFileTree()
KARDS.CardEditor.Canvas.SoundFileStates = KARDS.CardEditor.Canvas.SoundFileStates or {}

-- 子类型文件系统（英文名→中文显示名映射）
-- sandbox 为一个国家（沙盒，默认中立国家），此前误标为「所有国家」，2026-10-04 更正
local SubtypeDisplayNames = {
    sandbox = "沙盒",
}

-- 构建子类型文件树（从真实文件系统读取）
local function BuildSubtypeFileTree()
    local rootPath = "effects_data/subtypes"
    local function scanDir(dirPath)
        local files, dirs = file.Find(dirPath .. "/*", "DATA")
        local children = {}
        if dirs then
            table.sort(dirs)
            for _, dirName in ipairs(dirs) do
                local subPath = dirPath .. "/" .. dirName
                local display = SubtypeDisplayNames[dirName] or dirName
                table.insert(children, {
                    name = dirName,
                    display = display,
                    type = "folder",
                    fullPath = subPath,
                    children = scanDir(subPath)
                })
            end
        end
        if files then
            table.sort(files)
            for _, fileName in ipairs(files) do
                table.insert(children, {
                    name = fileName,
                    type = "file",
                    fullPath = dirPath .. "/" .. fileName
                })
            end
        end
        return children
    end
    local children = scanDir(rootPath)
    return {
        name = "子类型",
        type = "folder",
        children = children
    }
end

-- 初始化子类型文件树
KARDS.CardEditor.Canvas.SubtypeFileSystem = BuildSubtypeFileTree()

local function DrawFileManagerInternal(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt, fs, state, hooks)

    -- 绘制背景
    draw.RoundedBox(6, fmX, fmY, fmW, fmH, Color(25, 25, 30))
    draw.RoundedBox(6, fmX + 1, fmY + 1, fmW - 2, fmH - 2, Color(30, 30, 35))

    -- 获取当前文件夹内容
    local currentFolder = fs
    for _, idx in ipairs(state.navStack) do
        if currentFolder.children and currentFolder.children[idx] then
            currentFolder = currentFolder.children[idx]
        else
            break
        end
    end

    -- 构建显示列表
    local items = {}
    if #state.navStack > 0 then
        table.insert(items, { name = ".. 返回上一级", type = "back" })
    end
    for i, child in ipairs(currentFolder.children or {}) do
        table.insert(items, { entry = child, name = child.name, type = child.type, idx = i })
    end

    -- 更新滑动动画：下钻 animOffset = fmW（从右滑入）、返回 animOffset = -fmW（从左滑入），
    -- 均向 0 渐变（速度 2000px/s）
    if state.animOffset > 0 then
        state.animOffset = math.max(0, state.animOffset - dt * 2000)
    elseif state.animOffset < 0 then
        state.animOffset = math.min(0, state.animOffset + dt * 2000)
    end

    -- 启用剪切矩形，确保内容只在文件管理器矩形内渲染
    render.SetScissorRect(fmX, fmY, fmX + fmW, fmY + fmH, true)

    -- 绘制项目列表（hooks.topPad：顶部预留区——音效管理器标题栏，列表相应下移）
    local itemH = 20
    local listStartY = fmY + 5 + ((hooks and hooks.topPad) or 0)
    local hoveredItem = nil
    local fileClickConsumed = false -- 本帧 onFileRow 已消费点击（音效试听图标），不再触发选中

    -- 鼠标滚轮滚动列表（2026-08-13）：消费 CreateMove 设置的滚轮标记（见本文件尾部
    -- KARDS_Canvas_Wheel），仅鼠标悬停列表区域时生效；滚动量按 itemH 步进、范围钳制。
    -- 偏移存 state.scrollOffset（各文件管理器独立，切换目录时清零）
    state.scrollOffset = state.scrollOffset or 0
    local listTop = listStartY
    local listBottom = fmY + fmH - 2
    local mouseInList = IsMouseIn(mx, my, fmX, listTop, fmW, listBottom - listTop)
    local maxScroll = math.max(0, #items * itemH - (listBottom - listTop))
    if mouseInList and KARDS.CardEditor.Canvas._wheelZoomIn then
        KARDS.CardEditor.Canvas._wheelZoomIn = false
        state.scrollOffset = math.max(0, state.scrollOffset - itemH)
    elseif mouseInList and KARDS.CardEditor.Canvas._wheelZoomOut then
        KARDS.CardEditor.Canvas._wheelZoomOut = false
        state.scrollOffset = math.min(maxScroll, state.scrollOffset + itemH)
    end

    for i, item in ipairs(items) do
        local iy = listStartY + (i - 1) * itemH - state.scrollOffset
        -- X方向偏移实现从右侧平移到
        local ix = fmX + 4 + state.animOffset
        if ix < fmX + fmW - 4 then
            local isHov = IsMouseIn(mx, my, ix, iy, fmW - 8, itemH)
            if isHov then
                hoveredItem = item
            end

            local textColor = Color(200, 200, 200)
            local prefix = ""
            local isSelected = false

            if item.type == "back" then
                textColor = Color(180, 180, 100)
                prefix = "← "
            elseif item.type == "folder" then
                textColor = Color(180, 200, 255)
                prefix = "+ "
            elseif item.type == "file" then
                isSelected = state.selectedEntry and state.selectedEntry.name == item.name
                if isSelected then
                    textColor = Color(80, 180, 255)
                elseif item.entry and item.entry.disabled then
                    textColor = Color(220, 90, 90) -- 中文文件名（BASS 无法播放）：显示但禁用
                else
                    textColor = Color(200, 200, 200)
                end
            end

            if isHov then
                draw.RoundedBox(4, ix, iy, fmW - 8, itemH, Color(55, 55, 65))
            end

            local displayText = prefix .. (item.entry and item.entry.display or item.name)
            if isSelected then
                displayText = "✓ " .. (item.entry and item.entry.display or item.name)
            end
            draw.SimpleText(displayText, "SourceHan_Heavy_12", ix + 6, iy + itemH / 2, textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

            -- 文件行扩展钩子（音效管理器：试听播放/暂停图标；返回 true = 本帧已消费点击）
            if item.type == "file" and hooks and hooks.onFileRow then
                if hooks.onFileRow(item, ix, iy, fmW - 8, itemH, mx, my, isLeftPressed) then
                    fileClickConsumed = true
                end
            end
        end
    end

    -- 禁用剪切矩形
    render.SetScissorRect(0, 0, 0, 0, false)

    -- 点击处理
    if isLeftPressed and hoveredItem then
        if hoveredItem.type == "back" then
            table.remove(state.navStack)
            state.selectedEntry = nil
            state.showConfirm = false
            state.showOverlay = false
            state.scrollOffset = 0 -- 切换目录重置滚动
            state.animOffset = -fmW -- 返回动画：父级内容从左侧滑入（向左移动效果）
            if hooks and hooks.onBack then
                hooks.onBack() -- 返回上一级回调（音效管理器：停止试听）
            end
        elseif hoveredItem.type == "folder" then
            if hoveredItem.entry and hoveredItem.idx then
                table.insert(state.navStack, hoveredItem.idx)
                state.animOffset = fmW
                state.selectedEntry = nil
                state.showConfirm = false
                state.showOverlay = false
                state.scrollOffset = 0 -- 切换目录重置滚动
            end
        elseif hoveredItem.type == "file" then
            -- 禁用项（中文文件名音效）不可选中；onFileRow 已消费点击（试听图标）也不再选中
            if not (hoveredItem.entry and hoveredItem.entry.disabled) and not fileClickConsumed then
                state.selectedEntry = hoveredItem.entry
                state.showConfirm = true
                state.showOverlay = false
            end
        end
    end

    -- 确认/取消按钮行
    if state.showConfirm and state.selectedEntry then
        local confirmY = fmY + fmH - 52
        draw.RoundedBox(4, fmX + 4, confirmY, fmW - 8, 48, Color(20, 20, 25, 230))

        local fileName = state.selectedEntry.display or state.selectedEntry.name
        draw.SimpleText("选择 '" .. fileName .. "'？", "SourceHan_Heavy_12", fmX + fmW / 2, confirmY + 8, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        local btnW = 55
        local btnH = 20
        local btnGap = 8
        local totalBtnW = btnW * 2 + btnGap
        local btnStartX = fmX + (fmW - totalBtnW) / 2
        local btnY2 = confirmY + 26

        local selBtnX = btnStartX
        local selHov = IsMouseIn(mx, my, selBtnX, btnY2, btnW, btnH)
        KARDS.CardEditor.Canvas.DrawHoverButton(selBtnX, btnY2, btnW, btnH, "选择", selHov, { hoverBg = Color(80, 170, 80), normalBg = Color(60, 130, 60), font = "SourceHan_Heavy_12" })

        local noBtnX = btnStartX + btnW + btnGap
        local noHov = IsMouseIn(mx, my, noBtnX, btnY2, btnW, btnH)
        KARDS.CardEditor.Canvas.DrawHoverButton(noBtnX, btnY2, btnW, btnH, "不选", noHov, { hoverBg = Color(170, 80, 80), normalBg = Color(130, 60, 60), font = "SourceHan_Heavy_12" })

        if isLeftPressed then
            if selHov then
                state.showOverlay = true
                state.showConfirm = false
            elseif noHov then
                state.selectedEntry = nil
                state.showConfirm = false
            end
        end
    end

    -- 选择成功叠加层（全等半透明黑色 + 五角星）
    if state.showOverlay and state.selectedEntry then
        draw.RoundedBox(6, fmX, fmY, fmW, fmH, Color(0, 0, 0, 180))

        local starCX = fmX + fmW / 2
        local starCY = fmY + fmH / 2 - 18
        local starOuterR = 22
        local starInnerR = 9

        -- 构建五角星顶点
        local starVerts = {}
        for i = 0, 9 do
            local angle = math.rad(-90 + i * 36)
            local r = (i % 2 == 0) and starOuterR or starInnerR
            table.insert(starVerts, {
                x = starCX + math.cos(angle) * r,
                y = starCY + math.sin(angle) * r
            })
        end

        local isStarHov = IsMouseIn(mx, my, starCX - starOuterR, starCY - starOuterR, starOuterR * 2, starOuterR * 2)

        if isStarHov then
            -- 悬停时只绘制厚描边空心星（不绘制实心星）
            surface.SetDrawColor(255, 220, 0)
            draw.NoTexture()
            for i = 1, #starVerts do
                local next = i % #starVerts + 1
                surface.DrawLine(starVerts[i].x, starVerts[i].y, starVerts[next].x, starVerts[next].y)
                -- 加粗描边
                surface.DrawLine(starVerts[i].x + 1, starVerts[i].y, starVerts[next].x + 1, starVerts[next].y)
                surface.DrawLine(starVerts[i].x, starVerts[i].y + 1, starVerts[next].x, starVerts[next].y + 1)
            end
        else
            -- 未悬停时绘制实心五角星
            surface.SetDrawColor(255, 220, 0)
            draw.NoTexture()
            for i = 1, #starVerts do
                local next = starVerts[i % #starVerts + 1]
                surface.DrawPoly({
                    {x = starCX, y = starCY},
                    starVerts[i],
                    next
                })
            end
        end

        -- 下方文字
        local fileName = state.selectedEntry.display or state.selectedEntry.name
        draw.SimpleText("已选择", "SourceHan_Heavy_16", starCX, starCY + starOuterR + 12, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        draw.SimpleText(fileName, "SourceHan_Heavy_14", starCX, starCY + starOuterR + 34, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        if isLeftPressed and isStarHov then
            if hooks and hooks.onLock then
                hooks.onLock(state.selectedEntry) -- 锁定回调（音效管理器：写回 app.sounds 并停止试听）
            end
            state.selectedEntry = nil
            state.showOverlay = false
            state.showConfirm = false
        end
    end
end

-- 特效文件管理器封装器
local function DrawEffectFileManager(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt)
    DrawFileManagerInternal(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt,
        KARDS.CardEditor.Canvas.EffectFileSystem,
        KARDS.CardEditor.Canvas.EffectFileState)
end

-- 事件槽位中文显示名
local SoundEventDisplay = {
    deploy = "部署",
    attack = "攻击",
    death = "阵亡",
    play = "打出",
    activate = "激活时",
    trigger = "触发",
}

-- 试听图标材质（GMod 内置 icon16 图标集；本环境 surface.DrawPoly 绘制不可靠，
-- 改用与 DrawRect 同机制的 surface.DrawTexturedRect）
local PLAY_ICON_MAT = Material("icon16/control_play.png")
local PAUSE_ICON_MAT = Material("icon16/control_pause.png")

-- 提交 F2 命名：文本非空则写入别名 json（路径→新显示名）并重建音效文件树使展示立即生效；
-- 空文本视为放弃（不写入）。
local function CommitSoundRename()
    local st = RenameInputState
    if st then
        local text = st.text or ""
        if text ~= "" and st.fullPath then
            SoundAliases[st.fullPath] = text
            SaveSoundAliases()
            KARDS.CardEditor.Canvas.SoundFileSystem = BuildSoundFileTree()
        end
        RenameInputState = nil
    end
end

-- 绘制 F2 命名输入框（覆盖在选中文件行上；enter / 点击外部 = 提交，ESC = 取消）
local function DrawRenameInputBox(mx, my, isLeftPressed)
    local rs = RenameInputState
    if not rs then return end
    draw.RoundedBox(3, rs.x, rs.y, rs.w, rs.h, Color(60, 60, 70))
    surface.SetDrawColor(100, 150, 255, 200)
    surface.DrawOutlinedRect(rs.x, rs.y, rs.w, rs.h)
    local txt = rs.text or ""
    surface.SetFont("SourceHan_Heavy_12")
    if txt == "" then
        draw.SimpleText("输入新名称…", "SourceHan_Heavy_12", rs.x + 6, rs.y + rs.h / 2, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(txt, "SourceHan_Heavy_12", rs.x + 6, rs.y + rs.h / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    -- 闪烁光标
    if math.floor(SysTime() * 2) % 2 == 0 then
        local cX = rs.x + 6 + surface.GetTextSize(txt)
        surface.SetDrawColor(200, 200, 200)
        surface.DrawLine(cX, rs.y + 3, cX, rs.y + rs.h - 3)
    end
    -- 点击输入框外部 → 命名完成（提交）
    if isLeftPressed and not IsMouseIn(mx, my, rs.x, rs.y, rs.w, rs.h) then
        CommitSoundRename()
    end
end

-- F2 命名输入框 DTextEntry 生命周期（透明 DTextEntry 捕获 IME 输入；激活创建聚焦，失活销毁）
local function ManageRenameTextEntry()
    local rs = RenameInputState
    if rs then
        if not RenameTextEntry or not IsValid(RenameTextEntry) then
            local entry = vgui.Create("DTextEntry", KARDS.CardEditor.Canvas.RootPanel)
            entry:SetPos(rs.x, rs.y)
            entry:SetSize(rs.w, rs.h)
            entry:SetText("")
            entry:SetAllowNonAsciiCharacters(true) -- 中文命名需要 IME 输入
            entry:SetDrawBackground(false)
            entry:SetDrawBorder(false)
            entry:SetTextColor(Color(255, 255, 255, 0))
            entry:SetCursorColor(Color(255, 255, 255, 0))
            entry.Paint = nil
            entry:RequestFocus()
            entry.OnTextChanged = function(self)
                if RenameInputState then RenameInputState.text = self:GetText() end
            end
            entry.OnEnter = function(self)
                CommitSoundRename() -- Enter 命名完成
            end
            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE and RenameInputState then
                    RenameInputState = nil -- ESC 取消命名（不写入 json）
                end
            end
            RenameTextEntry = entry
        else
            if not RenameTextEntry:HasFocus() then
                RenameTextEntry:RequestFocus()
            end
        end
    else
        if RenameTextEntry and IsValid(RenameTextEntry) then
            RenameTextEntry:Remove()
        end
        RenameTextEntry = nil
    end
end

--[[
    音效文件管理器（封装 DrawFileManagerInternal，属性页底部条音效槽位）：
    - 每个事件槽位（eventKey）独立导航状态 SoundFileStates[eventKey]。
    - 文件行右侧播放/暂停图标：点击试听（同一时间仅一个预览，Audio 自动 duck
      编辑器 BGM 与背景音效至 50%）；暂停 / 选中并锁定 / 播放完毕 → 图标还原并
      停止（见 cl_audio_manager.lua PlayPreviewSound/StopPreviewSound）。
    - 中文文件名条目（disabled）红色 + 悬停工具提示，不可试听不可选中。
    - 锁定（五角星）→ onLock 写回 app.sounds[eventKey]，同时停止试听。
    - 顶部标题区（事件名 + 当前已保存音效文件名）由本封装在内部盒上叠加绘制。
]]
local function DrawSoundFileManager(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt, eventKey, app)
    app.sounds = app.sounds or {}
    KARDS.CardEditor.Canvas.SoundFileStates[eventKey] = KARDS.CardEditor.Canvas.SoundFileStates[eventKey] or {
        navStack = {}, selectedEntry = nil, showConfirm = false, animOffset = 0, showOverlay = false,
    }
    local state = KARDS.CardEditor.Canvas.SoundFileStates[eventKey]
    local Audio = KARDS.CardEditor.Audio
    local hoveredDisabled = nil

    -- F2 伪命名：仅"有选中文件且未在命名中"时才响应，否则丢弃（防残留误触发）
    if F2Pressed and not (state.selectedEntry and not RenameInputState) then
        F2Pressed = false
    end
    local hooks = {
        topPad = 20, -- 顶部标题区高度（事件名一行；已选文件名仅配置时显示，未配置不占位）
        onBack = function()
            Audio.StopPreviewSound() -- 返回上一级时停止试听音频（与锁定行为一致）
        end,
        onFileRow = function(item, ix, iy, rowW, rowH, mx2, my2, leftPressed)
            local entry = item.entry -- 文件条目数据（fullPath/disabled 挂在此，item 仅为行包装表）
            if not entry then return false end
            local iconR = 13
            local iconX = ix + rowW - iconR - 2
            local iconY = iy + rowH / 2
            local iconHov = IsMouseIn(mx2, my2, iconX - iconR, iconY - iconR, iconR * 2, iconR * 2)
            -- 行可见才绘制图标（滚动后越界行不绘），且绘制时临时禁用 Scissor：
            -- surface.DrawPoly 在 ScissorRect 启用期间不可靠（项目内 DrawPoly 先例均在
            -- Scissor 外绘制），暂停竖条 DrawRect 不受影响故此前可见正常
            local rowVisible = iy >= fmY and iy + rowH <= fmY + fmH
            if entry.disabled then
                -- 禁用条目（中文文件名，BASS 无法播放）：红色播放图标（不可试听），
                -- 悬停记录供尾部工具提示（internal 对 entry.disabled 行已跳过选中）
                if rowVisible then
                    render.SetScissorRect(0, 0, 0, 0, false)
                    surface.SetDrawColor(220, 90, 90)
                    surface.SetMaterial(PLAY_ICON_MAT)
                    surface.DrawTexturedRect(iconX - 8, iconY - 8, 16, 16)
                    render.SetScissorRect(fmX, fmY, fmX + fmW, fmY + fmH, true)
                end
                if iconHov or IsMouseIn(mx2, my2, ix, iy, rowW, rowH) then
                    hoveredDisabled = item
                end
                return false
            end
            local isPlayingThis = Audio.Preview.path == entry.fullPath and Audio.Preview.playing
            if rowVisible then
                render.SetScissorRect(0, 0, 0, 0, false)
                if isPlayingThis then
                    -- 暂停样式（icon16 双竖条）
                    surface.SetDrawColor(255, 200, 60)
                    surface.SetMaterial(PAUSE_ICON_MAT)
                    surface.DrawTexturedRect(iconX - 8, iconY - 8, 16, 16)
                else
                    -- 播放三角（icon16；亮色浅灰白，悬停提亮）
                    surface.SetDrawColor(iconHov and 255 or 235, iconHov and 255 or 238, iconHov and 255 or 240)
                    surface.SetMaterial(PLAY_ICON_MAT)
                    surface.DrawTexturedRect(iconX - 8, iconY - 8, 16, 16)
                end
                render.SetScissorRect(fmX, fmY, fmX + fmW, fmY + fmH, true)
            end
            if leftPressed and iconHov then
                if isPlayingThis then
                    Audio.StopPreviewSound()
                else
                    Audio.PlayPreviewSound(entry.fullPath)
                end
                return true -- 消费点击：本帧不再触发文件选中
            end
            -- F2 伪命名：选中本行文件时按下 F2 → 在本行位置打开命名输入框（覆盖选中行）
            if F2Pressed then
                F2Pressed = false
                if not RenameInputState and state.selectedEntry and state.selectedEntry.name == item.name then
                    RenameInputState = {
                        fullPath = entry.fullPath,
                        x = ix, y = iy, w = rowW, h = rowH,
                        text = "",
                    }
                end
            end
            return false
        end,
        onLock = function(entry)
            if entry then
                app.sounds[eventKey] = entry.fullPath
                -- 手动锁定标记（2026-08-14）：五角星锁定的音效优先于规模/类型的
                -- 自动分配——AutoAssignDeploySound 见到 _manual.deploy=true 跳过覆盖
                app.sounds._manual = app.sounds._manual or {}
                app.sounds._manual[eventKey] = true
            end
            Audio.StopPreviewSound()
        end,
    }
    DrawFileManagerInternal(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt,
        KARDS.CardEditor.Canvas.SoundFileSystem, state, hooks)
    -- 顶部标题区（事件名；已选文件名仅在已配置时显示，未配置不显示"未设置"）
    draw.SimpleText(SoundEventDisplay[eventKey] or eventKey, "SourceHan_Heavy_12", fmX + 6, fmY + 4, Color(255, 200, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    local saved = app.sounds[eventKey]
    if saved then
        local savedName = string.match(saved, "([^/]+)$")
        -- 伪命名优先：已配置路径有别名则显示别名
        draw.SimpleText(SoundAliases[saved] or savedName, "SourceHan_Heavy_12", fmX + 6, fmY + 18, Color(160, 200, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end
    -- 悬停禁用条目：工具提示（绘制在盒子外，不受裁剪影响）
    if hoveredDisabled then
        local tipText = "Gmod播放文件只支持ASCII字符（就是纯英文字母）"
        surface.SetFont("SourceHan_Heavy_12")
        local tw = surface.GetTextSize(tipText)
        local tipW, tipH = tw + 16, 26
        local tipX, tipY = mx + 14, my + 16
        if tipX + tipW > ScrW() then tipX = mx - tipW - 14 end
        if tipY + tipH > ScrH() then tipY = my - tipH - 14 end
        draw.RoundedBox(4, tipX, tipY, tipW, tipH, Color(20, 20, 25, 235))
        draw.SimpleText(tipText, "SourceHan_Heavy_12", tipX + tipW / 2, tipY + tipH / 2, Color(255, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    -- F2 命名输入框：绘制（覆盖选中行）+ 点击外部提交 + DTextEntry 生命周期（捕获 IME）
    DrawRenameInputBox(mx, my, isLeftPressed)
    ManageRenameTextEntry()
end

-- 子类型文件管理器封装器
-- 子类型选择器（继承文件管理器，支持选择文件后读取子类型）
local function DrawSubtypeSelector(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt, app)
    local state = KARDS.CardEditor.Canvas.SubtypeFileState
    local fs = KARDS.CardEditor.Canvas.SubtypeFileSystem

    -- 绘制背景
    draw.RoundedBox(6, fmX, fmY, fmW, fmH, Color(25, 25, 30))
    draw.RoundedBox(6, fmX + 1, fmY + 1, fmW - 2, fmH - 2, Color(30, 30, 35))

    -- ===== 模式 3: 选择成功叠加层 =====
    if state.showOverlay and state.selectedSubtype then
        draw.RoundedBox(6, fmX, fmY, fmW, fmH, Color(0, 0, 0, 180))

        local starCX = fmX + fmW / 2
        local starCY = fmY + fmH / 2 - 18
        local starOuterR = 22
        local starInnerR = 9

        local starVerts = {}
        for i = 0, 9 do
            local angle = math.rad(-90 + i * 36)
            local r = (i % 2 == 0) and starOuterR or starInnerR
            table.insert(starVerts, {
                x = starCX + math.cos(angle) * r,
                y = starCY + math.sin(angle) * r
            })
        end

        local isStarHov = IsMouseIn(mx, my, starCX - starOuterR, starCY - starOuterR, starOuterR * 2, starOuterR * 2)

        if isStarHov then
            surface.SetDrawColor(255, 220, 0)
            draw.NoTexture()
            for i = 1, #starVerts do
                local next = i % #starVerts + 1
                surface.DrawLine(starVerts[i].x, starVerts[i].y, starVerts[next].x, starVerts[next].y)
                surface.DrawLine(starVerts[i].x + 1, starVerts[i].y, starVerts[next].x + 1, starVerts[next].y)
                surface.DrawLine(starVerts[i].x, starVerts[i].y + 1, starVerts[next].x, starVerts[next].y + 1)
            end
        else
            surface.SetDrawColor(255, 220, 0)
            draw.NoTexture()
            for i = 1, #starVerts do
                local next = starVerts[i % #starVerts + 1]
                surface.DrawPoly({
                    {x = starCX, y = starCY},
                    starVerts[i],
                    next
                })
            end
        end

        draw.SimpleText("已选择", "SourceHan_Heavy_16", starCX, starCY + starOuterR + 12, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        draw.SimpleText(state.selectedSubtype, "SourceHan_Heavy_14", starCX, starCY + starOuterR + 34, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        if isLeftPressed and isStarHov then
            state.selectedSubtype = nil
            state.showOverlay = false
            state.isSelectingSubtype = false
            state.subtypeOptions = nil
            state.selectedEntry = nil
            state.showConfirm = false
        end
        return
    end

    -- ===== 模式 2: 子类型选择列表 =====
    if state.isSelectingSubtype and state.subtypeOptions then
        local itemH = 20
        local listStartY = fmY + 5

        -- "< 返回文件选择" 选项
        local backY = listStartY
        local backHov = IsMouseIn(mx, my, fmX + 4, backY, fmW - 8, itemH)
        draw.RoundedBox(3, fmX + 4, backY, fmW - 8, itemH - 2, backHov and Color(50, 50, 55) or Color(0, 0, 0, 0))
        draw.SimpleText("< 返回文件选择", "SourceHan_Heavy_12", fmX + 10, backY + itemH / 2, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        if isLeftPressed and backHov then
            state.isSelectingSubtype = false
            state.subtypeOptions = nil
            state.selectedEntry = nil
            state.showConfirm = false
        end

        -- 子类型选项列表
        for i, subtypeName in ipairs(state.subtypeOptions) do
            local iy = listStartY + i * itemH
            if iy + itemH <= fmY + fmH - 4 then
                local isHov = IsMouseIn(mx, my, fmX + 4, iy, fmW - 8, itemH)
                draw.RoundedBox(3, fmX + 4, iy, fmW - 8, itemH - 2, isHov and Color(60, 60, 65) or Color(0, 0, 0, 0))
                draw.SimpleText(subtypeName, "SourceHan_Heavy_14", fmX + 10, iy + itemH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

                if isLeftPressed and isHov then
                    state.selectedSubtype = subtypeName
                    state.showOverlay = true
                    -- 写回卡牌外观子类型字段（2026-10-04：此前仅写本地 state，未落 app）
                    if app then app.subtype = subtypeName end
                end
            end
        end
        return
    end

    -- ===== 模式 1: 文件浏览（复用文件管理器逻辑） =====
    local currentFolder = fs
    for _, idx in ipairs(state.navStack) do
        if currentFolder.children and currentFolder.children[idx] then
            currentFolder = currentFolder.children[idx]
        else break end
    end

    -- 构建显示列表
    local items = {}
    if #state.navStack > 0 then
        table.insert(items, { name = ".. 返回上一级", type = "back" })
    end
    for i, child in ipairs(currentFolder.children or {}) do
        table.insert(items, { entry = child, name = child.name, type = child.type, idx = i })
    end

    -- 滑动动画（从右向左平移）
    if state.animOffset > 0 then
        state.animOffset = math.max(0, state.animOffset - dt * 2000)
    end

    -- 裁剪渲染区域（只在矩形内渲染）
    render.SetScissorRect(fmX, fmY, fmX + fmW, fmY + fmH, true)

    local itemH = 20
    local listStartY = fmY + 5
    local hoveredItem = nil

    for i, item in ipairs(items) do
        local ix = fmX + 4 + state.animOffset
        local iy = listStartY + (i - 1) * itemH

        if iy + itemH >= fmY and iy <= fmY + fmH then
            local isHov = IsMouseIn(mx, my, ix, iy, fmW - 8, itemH - 2)
            if isHov then hoveredItem = item end

            local prefix = ""
            if item.type == "folder" then
                prefix = "📁 "
            elseif item.type == "file" and state.selectedEntry and state.selectedEntry == item.entry then
                prefix = "✓ "
            end

            draw.RoundedBox(3, ix, iy, fmW - 8, itemH - 2, isHov and Color(50, 50, 55) or Color(0, 0, 0, 0))

            local textColor = Color(220, 220, 220)
            if item.type == "file" and state.selectedEntry and state.selectedEntry == item.entry then
                textColor = Color(80, 140, 220)
            end

            local displayText = prefix .. (item.entry and (item.entry.display or item.entry.name) or item.name)
            draw.SimpleText(displayText, "SourceHan_Heavy_14", ix + 4, iy + itemH / 2, textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end

    render.SetScissorRect(0, 0, 0, 0, false)

    -- 点击处理
    if isLeftPressed and hoveredItem then
        if hoveredItem.type == "back" then
            table.remove(state.navStack)
            state.selectedEntry = nil
            state.showConfirm = false
            state.animOffset = 0
        elseif hoveredItem.type == "folder" then
            table.insert(state.navStack, hoveredItem.idx)
            state.animOffset = fmW
            state.selectedEntry = nil
            state.showConfirm = false
        elseif hoveredItem.type == "file" then
            state.selectedEntry = hoveredItem.entry
            if not state.showConfirm then
                state.showConfirm = true
            else
                state.showConfirm = false
            end
        end
    end

    -- 确认/取消按钮行
    if state.showConfirm and state.selectedEntry then
        local btnY = fmY + fmH - 44
        draw.RoundedBox(4, fmX + 2, btnY, fmW - 4, 42, Color(20, 20, 25, 200))

        local fileName = state.selectedEntry.display or state.selectedEntry.name
        draw.SimpleText("选择 '" .. fileName .. "'？", "SourceHan_Heavy_12", fmX + fmW / 2, btnY + 6, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        local btnW = 50
        local btnH = 20
        local btnGap = 10
        local btnStartX = fmX + (fmW - btnW * 2 - btnGap) / 2
        local btnY2 = btnY + 20

        -- "选择" 按钮：读取 lua 文件并进入子类型选择模式
        local selHov = IsMouseIn(mx, my, btnStartX, btnY2, btnW, btnH)
        KARDS.CardEditor.Canvas.DrawHoverButton(btnStartX, btnY2, btnW, btnH, "选择", selHov, { hoverBg = Color(60, 160, 60), normalBg = Color(50, 110, 50), font = "SourceHan_Heavy_12" })

        -- "不选" 按钮：取消
        local noBtnX = btnStartX + btnW + btnGap
        local noHov = IsMouseIn(mx, my, noBtnX, btnY2, btnW, btnH)
        KARDS.CardEditor.Canvas.DrawHoverButton(noBtnX, btnY2, btnW, btnH, "不选", noHov, { hoverBg = Color(170, 80, 80), normalBg = Color(130, 60, 60), font = "SourceHan_Heavy_12" })

        if isLeftPressed then
            if selHov then
                -- 读取 lua 文件获取子类型列表
                local filePath = state.selectedEntry.fullPath
                if filePath then
                    local content = file.Read(filePath, "DATA")
                    if content then
                        local ok, func = CompileString(content, "subtype_loader")
                        if ok then
                            local success, data = pcall(func)
                            if success and type(data) == "table" then
                                -- 过滤出有效子类型（去掉空的）
                                local validTypes = {}
                                for _, v in ipairs(data) do
                                    if v and #tostring(v) > 0 then
                                        table.insert(validTypes, v)
                                    end
                                end
                                state.subtypeOptions = validTypes
                                state.isSelectingSubtype = true
                                state.showConfirm = false
                            end
                        end
                    end
                end
            elseif noHov then
                state.selectedEntry = nil
                state.showConfirm = false
            end
        end
    end
end

-- 导出文件管理器、音效管理器与子类型选择器供 cl_ca_appearance_editors.lua 使用
KARDS.CardEditor.Canvas.DrawEffectFileManager = DrawEffectFileManager
KARDS.CardEditor.Canvas.DrawSoundFileManager = DrawSoundFileManager
KARDS.CardEditor.Canvas.DrawSubtypeSelector = DrawSubtypeSelector

-- 清理 F2 音效命名输入框 DTextEntry（编辑器关闭时调用；2026-10-04 拆分时从 CloseEditor 封装到此）
function KARDS.CardEditor.Canvas.CleanupRenameInput()
    if RenameTextEntry and IsValid(RenameTextEntry) then
        RenameTextEntry:Remove()
    end
    RenameTextEntry = nil
    RenameInputState = nil
end


