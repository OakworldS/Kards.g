-- Kards Card Editor - dynamic_BGM Compatibility Module
-- This module provides seamless audio compatibility between Kards and dynamic_BGM addons.
-- When the Kards editor opens, dynamic_BGM track volumes fade out to zero.
-- When the Kards editor closes, dynamic_BGM track volumes fade back to their original levels.
-- The BGM playback process of dynamic_BGM is never interrupted.

if CLIENT then

KARDS.CardEditor.Compat = KARDS.CardEditor.Compat or {}
KARDS.CardEditor.Compat.DynamicBGM = KARDS.CardEditor.Compat.DynamicBGM or {}

local Compat = KARDS.CardEditor.Compat.DynamicBGM

-- State variables for track volume management
Compat.OriginalIdleMaxVolume = nil
Compat.OriginalCombatMaxVolume = nil
Compat.OriginalMasterVolume = nil
Compat.IsFadedOut = false
Compat.FadeStartTime = 0
Compat.FadeDuration = 1.5

-- Editor track state
Compat.CurrentEditorTrack = nil
Compat.CurrentCountry = nil
Compat.EditorTrackChannel = nil
Compat.CurrentTrackIndex = 0 -- 用于循环播放的索引
Compat.CurrentTrackName = nil -- 当前播放曲目的音乐名（文件名 <序号>.<音乐名>.ogg 解析，纯数字文件名为 nil）
Compat.TrackLoading = false -- sound.PlayFile 正在异步加载/等待回调中，Think 不应抢跑切歌

-- Country music configurations
-- tracks 由 RefreshCountryTracks() 自动扫描 sound/editor/ 目录填充：
-- 目录结构 sound/editor/<国家id>/<数字>.<音乐名>.ogg，国家以文件夹区分、音频文件名为"数字序号.音乐名"，
-- 新增背景音乐无需修改代码（新建国家文件夹 + 放入 序号.音乐名.ogg 即可）；纯数字 <数字>.ogg 亦兼容（无音乐名）
-- 预设条目仅保留国家显示色等配置，未预设的新国家会被扫描动态创建
Compat.CountryMusic = {
    none = {
        tracks = {},
        color = nil
    },
    uk = {
        tracks = {},
        color = Color(100, 180, 255)
    },
    usa = {
        tracks = {},
        color = Color(60, 80, 60)
    },
    ussr = {
        tracks = {},
        color = Color(80, 30, 30)
    },
    japan = {
        tracks = {},
        color = Color(100, 70, 30)
    },
    germany = {
        tracks = {},
        color = Color(80, 80, 80)
    },
    finland = {
        tracks = {},
        color = Color(70, 110, 200)
    },
    italy = {
        tracks = {},
        color = Color(40, 140, 70)
    },
    australia = {
        tracks = {},
        color = Color(30, 60, 160)
    },
    france = {
        tracks = {},
        color = Color(50, 90, 200)
    },
    poland = {
        tracks = {},
        color = Color(190, 40, 40)
    }
}

-- 扫描 sound/editor/ 目录，按 国家文件夹/<序号>.<音乐名>.ogg 结构自动登记背景音乐
-- 每个子文件夹名即国家 id；文件名解析：<数字序号>.<音乐名>.ogg（如 1.La Parisienne.ogg）
-- 序号用于排序/循环定位，音乐名用于提示展示；纯数字 <数字>.ogg 亦兼容（音乐名为 nil）
-- 未预设的国家自动创建条目（color 为空）
function Compat.RefreshCountryTracks()
    -- file.Find 返回两个值：文件表、目录表；国家以文件夹区分，取目录表
    local _, dirs = file.Find("sound/editor/*", "GAME")

    for _, folder in ipairs(dirs or {}) do
        local folderPath = "sound/editor/" .. folder
        local trackFiles = file.Find(folderPath .. "/*.ogg", "GAME") or {}
        local tracks = {}
        for _, fileName in ipairs(trackFiles) do
            -- 带音乐名格式：<数字>.<音乐名>.ogg
            local index, name = string.match(fileName, "^(%d+)%.(.+)%.ogg$")
            if index then
                table.insert(tracks, { n = tonumber(index), path = folderPath .. "/" .. fileName, name = name })
            else
                -- 兼容纯数字格式：<数字>.ogg（音乐名为空）
                index = string.match(fileName, "^(%d+)%.ogg$")
                if index then
                    table.insert(tracks, { n = tonumber(index), path = folderPath .. "/" .. fileName, name = nil })
                end
            end
        end
        table.sort(tracks, function(a, b) return a.n < b.n end)

        if not Compat.CountryMusic[folder] then
            Compat.CountryMusic[folder] = { tracks = {}, color = nil }
        end
        -- tracks 保存结构数组 { n, path, name }；保留该国家已注册的外部曲目（registered 标记），
        -- 避免外部模组注册的曲目被目录扫描重建清除
        local existingTracks = Compat.CountryMusic[folder].tracks
        Compat.CountryMusic[folder].tracks = {}
        for _, t in ipairs(existingTracks or {}) do
            if t.registered then
                table.insert(Compat.CountryMusic[folder].tracks, t)
            end
        end
        for _, track in ipairs(tracks) do
            table.insert(Compat.CountryMusic[folder].tracks, track)
        end
        table.sort(Compat.CountryMusic[folder].tracks, function(a, b) return a.n < b.n end)
    end
end

-- 返回已登记曲目的国家ID列表（排除 none），供编辑器随机选择等使用
function Compat.GetAvailableCountries()
    local result = {}
    for country, data in pairs(Compat.CountryMusic) do
        if country ~= "none" and data.tracks and #data.tracks > 0 then
            table.insert(result, country)
        end
    end
    return result
end

-- ===== BGM 专属提示系统（编辑器窗口右下角文字提示）=====
-- 类型：play 初次播放风格 / switch 曲目末尾切换 / error 注册错误 / warning 无曲目警告
-- 多个提示并存时旧的向上先快后慢移动文本高度；play 类型新提示出现时更早的 play 提示立即消失、新提示原地入场
Compat.BGMMessages = {}
Compat.PendingBGMMessages = {} -- 编辑器未打开时暂存，打开后立即显示（用于加载阶段的注册错误/警告）
Compat.IsInitialPlay = false -- 标记当前播放是否由"选择风格"发起（若是则不重复发 switch 提示）

-- 显示一条 BGM 专属提示
-- text: 正文内容；kind: "play"/"switch"/"error"/"warning"
function Compat.ShowBGMMessage(text, kind)
    local msg = {
        kind = kind,
        createdAt = SysTime(),
        currentY = nil,
        targetY = nil
    }
    if kind == "play" then
        msg.fullText = "播放：" .. tostring(text)
        msg.enterDur = 0.75
        msg.holdDur = 2.5
        msg.exitDur = 0.75
        msg.maxAlpha = 191 -- 75%
        msg.color = Color(255, 255, 255)
    elseif kind == "switch" then
        msg.fullText = "BGM：" .. tostring(text)
        msg.enterDur = 1.0
        msg.holdDur = 5.0
        msg.exitDur = 1.0
        msg.maxAlpha = 102 -- 40%
        msg.color = Color(255, 255, 255)
    elseif kind == "error" then
        msg.fullText = "[错误]" .. tostring(text)
        msg.enterDur = 0
        msg.holdDur = 5.0
        msg.exitDur = 0
        msg.maxAlpha = 230 -- 90%
        msg.flash = true -- 2Hz 渐变闪烁
        msg.color = Color(220, 60, 60)
    elseif kind == "warning" then
        msg.fullText = "[警告]" .. tostring(text)
        msg.enterDur = 0.5
        msg.holdDur = 5.0
        msg.exitDur = 0.5
        msg.maxAlpha = 217 -- 85%
        msg.color = Color(230, 200, 60)
    else
        return
    end

    -- play 类型：更早的 play 提示立即消失，新提示原地入场（不参与上移）
    if kind == "play" then
        for _, m in ipairs(Compat.BGMMessages) do
            if m.kind == "play" then
                m.removeImmediately = true
            end
        end
    end

    -- 编辑器已打开直接显示，否则暂存到打开时显示
    local canvas = KARDS.CardEditor.Canvas
    if canvas and canvas.Enabled and canvas.Window then
        table.insert(Compat.BGMMessages, msg)
    else
        table.insert(Compat.PendingBGMMessages, msg)
    end
end

-- 编辑器打开时把暂存的提示转入活动列表并开始计时
function Compat.DrainPendingBGMMessages()
    if #Compat.PendingBGMMessages == 0 then return end
    local now = SysTime()
    for _, m in ipairs(Compat.PendingBGMMessages) do
        m.createdAt = now
        table.insert(Compat.BGMMessages, m)
    end
    Compat.PendingBGMMessages = {}
end

-- 计算提示当前透明度（smoothstep 平滑渐变出入场；error 附加 2Hz 正弦渐变闪烁）
function Compat.GetBGMMessageAlpha(m, age)
    local alpha = 0
    if age < m.enterDur and m.enterDur > 0 then
        local t = math.min(age / m.enterDur, 1)
        alpha = m.maxAlpha * t * t * (3 - 2 * t)
    elseif age < m.enterDur + m.holdDur then
        alpha = m.maxAlpha
    elseif m.exitDur > 0 then
        local t = math.min((age - m.enterDur - m.holdDur) / m.exitDur, 1)
        alpha = m.maxAlpha * (1 - t * t * (3 - 2 * t))
    end
    if m.flash then
        -- 2Hz 渐变闪烁：alpha 在 0~max 之间正弦起伏
        alpha = alpha * (0.5 + 0.5 * math.sin(age * 2 * math.pi * 2))
    end
    return math.Clamp(math.floor(alpha + 0.5), 0, 255)
end

-- 每帧更新并绘制 BGM 专属提示（HUDPaint，仅编辑器打开时）
function Compat.DrawBGMMessages()
    local canvas = KARDS.CardEditor.Canvas
    if not (canvas and canvas.Enabled and canvas.Window) then return end
    local win = canvas.Window
    local now = SysTime()
    local font = "SourceHan_Heavy_20"
    surface.SetFont(font)
    local _, lineH = surface.GetTextSize("A")
    if lineH < 10 then lineH = 18 end
    local spacing = 8
    local marginX = 24
    local bottomMargin = 20

    -- 过滤过期（含 play 立即消失）
    local valid = {}
    for _, m in ipairs(Compat.BGMMessages) do
        local age = now - m.createdAt
        if age < (m.enterDur + m.holdDur + m.exitDur) and not m.removeImmediately then
            valid[#valid + 1] = m
        end
    end
    Compat.BGMMessages = valid
    if #valid == 0 then return end

    -- 排序：旧的在上方，新的在底部
    table.sort(valid, function(a, b) return a.createdAt < b.createdAt end)

    -- 目标位置：自底向上堆叠（右下角）
    local cursorY = win.y + win.height - bottomMargin
    for i, m in ipairs(valid) do
        m.targetY = cursorY
        cursorY = cursorY - lineH - spacing
    end

    -- 先快后慢移动（指数趋近目标）
    local dt = FrameTime()
    for i, m in ipairs(valid) do
        m.currentY = m.currentY or m.targetY
        if m.currentY ~= m.targetY then
            m.currentY = m.currentY + (m.targetY - m.currentY) * (1 - math.exp(-dt * 10))
            if math.abs(m.currentY - m.targetY) < 0.5 then
                m.currentY = m.targetY
            end
        end
    end

    -- 绘制（右对齐，文本底边在 currentY）
    local rightX = win.x + win.width - marginX
    for i, m in ipairs(valid) do
        local age = now - m.createdAt
        local alpha = Compat.GetBGMMessageAlpha(m, age)
        draw.SimpleText(m.fullText, font, rightX, m.currentY, Color(m.color.r, m.color.g, m.color.b, alpha), TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
    end
end

-- ===== 国家按钮悬停简介（常驻5国按钮行左侧空白区：风格名称："简介源文本"）=====
-- 覆盖主行常驻 5 国按钮与扩展面板按钮；文字固定显示在常驻 5 国按钮行的左侧空白区（右对齐，垂直与主行同行）
-- 入场：打字机动画，字符从左往右逐个淡入（位置固定不跳动，每字符自身透明度平滑淡入）
-- 出场：鼠标移开时全部字符整体透明度平滑淡出；无简介（description 留空）不显示
Compat.BGMHoverState = nil -- 当前悬停提示状态：{ btn, enterTime, exitTime }
Compat.BGMHoverFont = "SourceHan_Heavy_18"
Compat.BGMHoverMaxAlpha = 217 -- 85%
Compat.BGMHoverEnterCharGap = 0.02 -- 打字机每字符出现间隔（秒）
Compat.BGMHoverEnterCharFade = 0.15 -- 每字符自身淡入时长（秒）
Compat.BGMHoverExitDur = 0.3 -- 出场集体淡出时长（秒）
Compat.BGMHoverMaxWidth = 560 -- 文本最大宽度，超出按字符截断

-- 平滑缓动（入场/出场透明度用）
local function BGMHoverSmoothstep(t)
    t = math.Clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

-- UTF-8 安全逐字符拆分（兼容中英文混排；一个汉字占 3 字节需按字节数判断）
local function BGMHoverSplitChars(text)
    local chars = {}
    local len = #text
    local i = 1
    while i <= len do
        local b = text:byte(i)
        local n = 1
        if b < 0x80 then
            n = 1
        elseif b < 0xE0 then
            n = 2
        elseif b < 0xF0 then
            n = 3
        elseif b < 0xF8 then
            n = 4
        end
        chars[#chars + 1] = text:sub(i, i + n - 1)
        i = i + n
    end
    return chars
end

-- 每帧绘制悬停简介（HUDPaint，编辑器打开即生效）：覆盖主行常驻 5 国按钮与扩展面板按钮
function Compat.DrawBGMHoverTooltip()
    local canvas = KARDS.CardEditor.Canvas
    if not (canvas and canvas.Enabled and canvas.Window) then
        Compat.BGMHoverState = nil
        return
    end
    local now = SysTime()

    -- 找到当前悬停且带简介的按钮（先查扩展面板按钮，再查主行常驻 5 国按钮）
    local hoveredBtn = nil
    for _, btn in ipairs(canvas.BGMMenuButtons or {}) do
        if IsValid(btn) and btn:IsHovered() and btn.countryData
            and btn.countryData.description and btn.countryData.description ~= "" then
            hoveredBtn = btn
            break
        end
    end
    if not hoveredBtn then
        for _, btn in ipairs(canvas.CountryButtons or {}) do
            if IsValid(btn) and btn:IsHovered() and btn.countryData
                and btn.countryData.description and btn.countryData.description ~= "" then
                hoveredBtn = btn
                break
            end
        end
    end

    if hoveredBtn then
        if not Compat.BGMHoverState then
            Compat.BGMHoverState = { btn = hoveredBtn, enterTime = now, exitTime = nil }
        elseif Compat.BGMHoverState.btn ~= hoveredBtn then
            -- 从另一按钮移来：重置入场起点
            Compat.BGMHoverState = { btn = hoveredBtn, enterTime = now, exitTime = nil }
        elseif Compat.BGMHoverState.exitTime then
            -- 出场中又移回同一按钮：重新入场
            Compat.BGMHoverState.enterTime = now
            Compat.BGMHoverState.exitTime = nil
        end
    elseif Compat.BGMHoverState then
        -- 鼠标已离开：记录出场起点（仅首次），随后整体淡出
        if not Compat.BGMHoverState.exitTime then
            Compat.BGMHoverState.exitTime = now
        end
    else
        return
    end

    local state = Compat.BGMHoverState
    -- 悬停按钮已失效（如菜单被关闭）直接清除
    if not IsValid(state.btn) then
        Compat.BGMHoverState = nil
        return
    end

    -- 出场完成：清除
    if state.exitTime and now - state.exitTime >= Compat.BGMHoverExitDur then
        Compat.BGMHoverState = nil
        return
    end

    local country = state.btn.countryData
    local fullText = country.name .. "：“" .. country.description .. "”"
    local chars = BGMHoverSplitChars(fullText)

    -- 按字符测量累计宽度，超过最大宽度截断（打字机基于截断后文本）
    surface.SetFont(Compat.BGMHoverFont)
    local visibleCount = #chars
    local accW = 0
    for i, c in ipairs(chars) do
        local cw = surface.GetTextSize(c)
        accW = accW + cw
        if accW > Compat.BGMHoverMaxWidth then
            visibleCount = i - 1
            break
        end
    end
    if visibleCount <= 0 then return end

    -- 预测量每个字符宽度，便于右对齐从右往左排布字符位置
    local perCharW = {}
    for i = 1, visibleCount do
        perCharW[i] = surface.GetTextSize(chars[i])
    end

    -- 文字固定在常驻 5 国按钮行左侧空白区：右对齐贴主行左端（扩展按钮左缘 - 10px），垂直与主行同行
    local rightX, centerY
    local extendBtn = canvas.BGMExtendButton
    if IsValid(extendBtn) then
        local ex, ey = extendBtn:LocalToScreen(0, 0)
        rightX = ex - 10
        centerY = ey + extendBtn:GetTall() / 2
    else
        -- 兜底：跟随悬停按钮（编辑器主行按钮缺失时）
        local sx, sy = state.btn:LocalToScreen(0, 0)
        rightX = sx + state.btn:GetWide() + 10
        centerY = sy + state.btn:GetTall() / 2
    end

    -- 出场整体透明度倍率（集体淡出）
    local exitMul = 1
    if state.exitTime then
        exitMul = 1 - BGMHoverSmoothstep((now - state.exitTime) / Compat.BGMHoverExitDur)
    end

    -- 打字机从左往右：字符位置固定（完整文本右对齐布局不跳动），每个字符按间隔依次从左侧向右淡入
    local charRights = {}
    local x = rightX
    for i = visibleCount, 1, -1 do
        charRights[i] = x
        x = x - perCharW[i]
    end
    local enterAge = now - state.enterTime
    for i = 1, visibleCount do
        local cAge = enterAge - (i - 1) * Compat.BGMHoverEnterCharGap
        if cAge >= 0 then
            local charAlpha
            if cAge < Compat.BGMHoverEnterCharFade then
                charAlpha = Compat.BGMHoverMaxAlpha * BGMHoverSmoothstep(cAge / Compat.BGMHoverEnterCharFade)
            else
                charAlpha = Compat.BGMHoverMaxAlpha
            end
            charAlpha = math.floor(charAlpha * exitMul + 0.5)
            if charAlpha > 0 then
                draw.SimpleText(chars[i], Compat.BGMHoverFont, charRights[i], centerY, Color(255, 255, 255, charAlpha), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
            end
        end
    end
end

-- 外部模组注册风格（RegisterBGMCountry 的实时实现）：
-- 加入展开面板配置（BGMExpandCountries，幂等：同 id 仅首次生效）+ CountryMusic 预设条目
function Compat.RegisterCountry(countryId, data)
    -- 格式校验：注册风格格式不规范时给出红色错误提示
    if type(countryId) ~= "string" or countryId == "" then
        KARDS.CardEditor:Log("外部BGM注册警告：风格 id 格式不规范：" .. tostring(countryId))
        Compat.ShowBGMMessage("注册风格格式不规范：id 无效（" .. tostring(countryId) .. "）", "error")
        return
    end
    if type(data) ~= "table" then
        KARDS.CardEditor:Log("外部BGM注册警告：风格 '" .. countryId .. "' 的配置 data 必须为表，实际为 " .. type(data))
        Compat.ShowBGMMessage("注册风格格式不规范：'" .. countryId .. "' 的 data 必须为表", "error")
        return
    end
    data = data or {}
    local canvas = KARDS.CardEditor.Canvas
    if canvas and canvas.BGMExpandCountries then
        -- 防重复：同 id 已存在则仅更新预设色，不再插入按钮
        for _, c in ipairs(canvas.BGMExpandCountries) do
            if c.id == countryId then return end
        end
        table.insert(canvas.BGMExpandCountries, {
            id = countryId,
            name = data.name or countryId,
            shortName = data.shortName,
            icon = data.icon,
            description = data.description, -- 国家二战简介（悬停扩展按钮时显示，可留空）
            -- file.Exists 预判图标文件存在才创建材质（同主行按钮机制，避免 "?" 占位符）
            iconMat = data.icon and file.Exists(data.icon, "GAME") and Material(data.icon, "noclamp smooth") or nil,
            color = data.color or Color(120, 120, 120)
        })
    end
    if not Compat.CountryMusic[countryId] then
        Compat.CountryMusic[countryId] = { tracks = {}, color = data.color or nil }
    end
    -- 背景音效音量倍率（外部模组播放其音乐时可调低编辑器背景音效，默认 1 原音量）
    Compat.CountryMusic[countryId].backgroundVolume = data.backgroundVolume or 1
end

-- 外部模组注册曲目（RegisterBGMTrack 的实时实现）：
-- 将音频文件归类到某风格；n 用 10000+ 递增序号排在目录曲目之后；
-- registered 标记保证目录扫描重建 tracks 时不会被清除
function Compat.RegisterTrack(countryId, trackPath, trackName)
    -- 格式校验：trackPath 必须为非空字符串（外部模组漏传/传 nil 时给出红色错误提示）
    if type(trackPath) ~= "string" or trackPath == "" then
        KARDS.CardEditor:Log("外部BGM注册警告：曲目路径无效：" .. tostring(trackPath) .. "（所属风格：" .. tostring(countryId) .. "）")
        Compat.ShowBGMMessage("注册曲目格式不规范：路径无效（" .. tostring(trackPath) .. "）", "error")
        return
    end
    if not Compat.CountryMusic[countryId] then
        Compat.CountryMusic[countryId] = { tracks = {}, color = nil }
    end
    local data = Compat.CountryMusic[countryId]
    -- 防重复：同路径只注册一次
    for _, t in ipairs(data.tracks) do
        if t.path == trackPath then return end
    end
    -- 校验音频文件存在，避免外部模组注册无效路径（静默失败无任何提示）
    if not file.Exists(trackPath, "GAME") then
        KARDS.CardEditor:Log("外部BGM注册警告：音频文件不存在：" .. tostring(trackPath) .. "（所属风格：" .. tostring(countryId) .. "）")
        Compat.ShowBGMMessage("注册曲目不存在：" .. tostring(trackPath), "error")
    end
    Compat._externalTrackSeq = (Compat._externalTrackSeq or 0) + 1
    table.insert(data.tracks, { n = 10000 + Compat._externalTrackSeq, path = trackPath, name = trackName, registered = true })
    table.sort(data.tracks, function(a, b) return a.n < b.n end)
end

-- 安全停止所有相关通道
function Compat.SafeStopChannel()
    -- 先移除Think hook，防止新的播放
    hook.Remove("Think", "KARDS_EditorTrack_Loop")
    
    -- 重置加载标记（可能有 pending 的 sound.PlayFile 回调）
    Compat.TrackLoading = false
    
    -- 停止当前channel
    if IsValid(Compat.EditorTrackChannel) then
        Compat.EditorTrackChannel:Stop()
    end
    Compat.EditorTrackChannel = nil
    Compat.CurrentEditorTrack = nil
    Compat.CurrentTrackName = nil
end

-- Check whether the dynamic_BGM addon is present and functional.
function Compat.IsAvailable()
    return _G.DynamicBGM ~= nil and _G.DynamicBGM.Config ~= nil
end

-- Fade out dynamic_BGM track volumes to zero over Compat.FadeDuration seconds.
function Compat.FadeOut()
    if not Compat.IsAvailable() then
        return
    end

    if Compat.IsFadedOut then
        return
    end

    -- Save original configuration values
    Compat.OriginalIdleMaxVolume = _G.DynamicBGM.Config.MaxIdleVolume
    Compat.OriginalCombatMaxVolume = _G.DynamicBGM.Config.MaxCombatVolume
    Compat.OriginalMasterVolume = _G.DynamicBGM.Config.MasterVolume

    Compat.IsFadedOut = true
    Compat.FadeStartTime = CurTime()

    hook.Add("Think", "KARDS_DynamicBGM_FadeOut", function()
        if not Compat.IsFadedOut then
            hook.Remove("Think", "KARDS_DynamicBGM_FadeOut")
            return
        end

        local elapsed = CurTime() - Compat.FadeStartTime
        local progress = math.Clamp(elapsed / Compat.FadeDuration, 0, 1)

        -- Gradually modify the configuration values that dynamic_BGM uses
        _G.DynamicBGM.Config.MaxIdleVolume = Lerp(progress, Compat.OriginalIdleMaxVolume, 0)
        _G.DynamicBGM.Config.MaxCombatVolume = Lerp(progress, Compat.OriginalCombatMaxVolume, 0)
        _G.DynamicBGM.Config.MasterVolume = Lerp(progress, Compat.OriginalMasterVolume, 0)

        if progress >= 1 then
            hook.Remove("Think", "KARDS_DynamicBGM_FadeOut")
        end
    end)
end

-- Fade in dynamic_BGM track volumes back to original saved levels.
function Compat.FadeIn()
    if not Compat.IsAvailable() then
        return
    end

    if not Compat.IsFadedOut then
        return
    end

    Compat.IsFadedOut = false
    local fadeStart = CurTime()

    hook.Add("Think", "KARDS_DynamicBGM_FadeIn", function()
        if Compat.IsFadedOut then
            hook.Remove("Think", "KARDS_DynamicBGM_FadeIn")
            return
        end

        local elapsed = CurTime() - fadeStart
        local progress = math.Clamp(elapsed / Compat.FadeDuration, 0, 1)

        -- Gradually restore the configuration values
        _G.DynamicBGM.Config.MaxIdleVolume = Lerp(progress, _G.DynamicBGM.Config.MaxIdleVolume, Compat.OriginalIdleMaxVolume)
        _G.DynamicBGM.Config.MaxCombatVolume = Lerp(progress, _G.DynamicBGM.Config.MaxCombatVolume, Compat.OriginalCombatMaxVolume)
        _G.DynamicBGM.Config.MasterVolume = Lerp(progress, _G.DynamicBGM.Config.MasterVolume, Compat.OriginalMasterVolume)

        if progress >= 1 then
            hook.Remove("Think", "KARDS_DynamicBGM_FadeIn")
            Compat.OriginalIdleMaxVolume = nil
            Compat.OriginalCombatMaxVolume = nil
            Compat.OriginalMasterVolume = nil
        end
    end)
end

-- Stop any playing editor track
function Compat.StopEditorTrack()
    Compat.SafeStopChannel()
end

-- Play a country-specific editor track (循环版)
function Compat.PlayEditorTrack(country)
    -- 彻底停止所有
    Compat.SafeStopChannel()

    -- 应用该国家配置的背景音效音量倍率（none 或未配置时恢复默认 1）
    local volumeCountryData = country and Compat.CountryMusic[country]
    local bgVolume = volumeCountryData and volumeCountryData.backgroundVolume or 1
    if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.SetBackgroundMusicVolume then
        KARDS.CardEditor.Audio.SetBackgroundMusicVolume(bgVolume)
    end

    if not country or country == "none" then
        return
    end

    local countryData = Compat.CountryMusic[country]
    if not countryData or not countryData.tracks or #countryData.tracks == 0 then
        -- 未预设或未登记曲目的国家：尝试扫描目录自动登记后再试一次
        Compat.RefreshCountryTracks()
        countryData = Compat.CountryMusic[country]
    end
    if not countryData or not countryData.tracks or #countryData.tracks == 0 then
        -- 该风格没有任何可用曲目：黄色警告提示（打开编辑器或点击 0 首风格时触发）
        KARDS.CardEditor:Log("编辑器BGM：风格'" .. tostring(country) .. "'没有可用曲目，请检查外部模组注册是否成功（曲目可能因语法错误未注册）")
        Compat.ShowBGMMessage("风格'" .. tostring(country) .. "'没有可用背景音乐，可能注册失败", "warning")
        return
    end

    Compat.CurrentCountry = country
    Compat.CurrentTrackIndex = 0 -- 重置索引，从第一首开始
    Compat.IsInitialPlay = true -- 由"选择风格"发起：本次播放不重复发 switch 提示

    -- 播放第一首
    Compat.PlayNextTrack()

    -- 添加Think hook，检查是否播放完并循环
    hook.Add("Think", "KARDS_EditorTrack_Loop", function()
        -- 检查编辑器是否还开着
        if not KARDS.CardEditor.Canvas or not KARDS.CardEditor.Canvas.Enabled then
            Compat.StopEditorTrack()
            return
        end

        -- 检查是否还有效的country
        if not Compat.CurrentCountry or Compat.CurrentCountry == "none" then
            Compat.StopEditorTrack()
            return
        end

        -- sound.PlayFile 正在异步加载中，等待回调后再决定下一步（防止加载慢的外部音乐被抢跑丢弃）
        if Compat.TrackLoading then
            return
        end

        -- 检查当前channel
        if not IsValid(Compat.EditorTrackChannel) then
            -- channel无效了，重新播放
            Compat.PlayNextTrack()
            return
        end

        -- 检查是否播放完了
        local state = Compat.EditorTrackChannel:GetState()
        -- 0 = stopped, 1 = playing, 2 = paused
        if state == 0 then
            -- 播放完了，播放下一首
            Compat.PlayNextTrack()
        end
    end)
end

-- 播放下一首（内部使用）
function Compat.PlayNextTrack()
    if not Compat.CurrentCountry or Compat.CurrentCountry == "none" then
        return
    end

    local countryData = Compat.CountryMusic[Compat.CurrentCountry]
    if not countryData or not countryData.tracks or #countryData.tracks == 0 then
        return
    end

    -- 先停止旧的channel
    if IsValid(Compat.EditorTrackChannel) then
        Compat.EditorTrackChannel:Stop()
    end
    Compat.EditorTrackChannel = nil

    -- 随机选择下一首（trackCount > 1 时避免与当前曲目重复）
    local trackCount = #countryData.tracks
    local prevIndex = Compat.CurrentTrackIndex
    Compat.CurrentTrackIndex = math.random(1, trackCount)
    if trackCount > 1 then
        while Compat.CurrentTrackIndex == prevIndex do
            Compat.CurrentTrackIndex = math.random(1, trackCount)
        end
    end
    local trackData = countryData.tracks[Compat.CurrentTrackIndex]
    local trackPath = trackData.path
    Compat.CurrentEditorTrack = trackPath
    Compat.CurrentTrackName = trackData.name or nil

    -- 切换提示：仅"一曲到末尾而切换"时显示（由"选择风格"发起的初次播放不发，改由 play 提示承载）
    if Compat.IsInitialPlay then
        Compat.IsInitialPlay = false
    else
        Compat.ShowBGMMessage(Compat.CurrentTrackName or "音乐", "switch")
    end

    -- 生成唯一的回调标识，防止旧回调干扰
    local expectedCountry = Compat.CurrentCountry
    local expectedTrackIndex = Compat.CurrentTrackIndex

    -- 诊断：GMod 的 sound.PlayFile 不支持非 ASCII 文件名（Issue #2304，BASS 未启用 UNICODE），
    -- 文件名含非 ASCII 字符（如 ä、ó）的曲目必然播放失败，提前提示以便排查
    local hasNonAscii = false
    for i = 1, #trackPath do
        local b = trackPath:byte(i)
        if b and b > 127 then
            hasNonAscii = true
            break
        end
    end
    if hasNonAscii then
        KARDS.CardEditor:Log("编辑器BGM警告：曲目文件名含非 ASCII 字符，sound.PlayFile 无法播放，请重命名为纯英文文件名：" .. trackPath)
    end

    -- 标记加载中：Think 在回调返回前不抢跑切歌（外部大文件加载慢，否则回调因索引不匹配被丢弃，永远只播第一首）
    Compat.TrackLoading = true
    sound.PlayFile(trackPath, "noplay", function(channel, errCode, errStr)
        -- 回调已触发（无论成败），解除加载标记
        Compat.TrackLoading = false
        if not IsValid(channel) then
            -- 播放失败时输出诊断信息（错误码与路径）
            KARDS.CardEditor:Log("编辑器BGM播放失败：" .. tostring(errStr) .. "（" .. tostring(trackPath) .. "）")
            return
        end

        -- 验证：国家是否仍然一样、索引是否仍然一样、当前是否还有效的country
        if not Compat.CurrentCountry or Compat.CurrentCountry ~= expectedCountry or Compat.CurrentTrackIndex ~= expectedTrackIndex then
            channel:Stop()
            return
        end

        -- 再做一次安全检查：如果已经有新的channel了，停止这个旧的
        if IsValid(Compat.EditorTrackChannel) then
            channel:Stop()
            return
        end

        Compat.EditorTrackChannel = channel
        channel:SetVolume(0.5)
        channel:Play()
    end)
end

-- Select a country and play its music
function Compat.SelectCountry(countryId)
    Compat.CurrentCountry = countryId

    -- Stop current track and play new one
    Compat.StopEditorTrack()

    if countryId and countryId ~= "none" then
        Compat.PlayEditorTrack(countryId)
    end
end

-- Load editor track for a country (used when editor opens)
function Compat.LoadEditorTrack(country)
    if country and country ~= "none" then
        Compat.PlayEditorTrack(country)
    end
end

-- Hook-based integration: listen for Kards editor open/close events.
hook.Add("KARDS_EditorOpened", "KARDS_DynamicBGM_Compat", function()
    Compat.FadeOut()
    -- 编辑器已打开，把加载阶段暂存的注册错误/警告提示转入显示
    Compat.DrainPendingBGMMessages()
end)

hook.Add("KARDS_EditorClosed", "KARDS_DynamicBGM_Compat", function()
    Compat.FadeIn()
    Compat.StopEditorTrack()
end)

KARDS.CardEditor:Log("dynamic_BGM compatibility module initialized")

-- 加载时自动扫描登记 sound/editor/ 目录下的全部背景音乐
Compat.RefreshCountryTracks()

-- 消费 autorun 阶段外部模组已注册的风格与曲目（RegisterCountry/RegisterTrack 内部幂等防重复）
for _, reg in ipairs(KARDS.CardEditor.BGMRegistrations or {}) do
    Compat.RegisterCountry(reg.id, reg.data)
end
for _, reg in ipairs(KARDS.CardEditor.TrackRegistrations or {}) do
    Compat.RegisterTrack(reg.id, reg.path, reg.name)
end

-- 校验：注册了风格但没有任何曲目的国家，提示外部模组注册异常（如曲目名漏写引号导致 nil）
for _, reg in ipairs(KARDS.CardEditor.BGMRegistrations or {}) do
    local data = Compat.CountryMusic[reg.id]
    if data and data.tracks and #data.tracks == 0 then
        KARDS.CardEditor:Log("外部BGM注册警告：风格'" .. tostring(reg.id) .. "'没有注册任何曲目，点击其按钮将无法播放（请检查外部模组曲目注册是否有语法错误）")
        Compat.ShowBGMMessage("风格'" .. tostring(reg.id) .. "'没有注册任何曲目，可能注册失败", "warning")
    end
end

-- 主模组 BGM 相关模块（Canvas + compat）已就绪，通知外部模组可安全注册
hook.Run("KARDS_CardEditorReady")

-- 每帧绘制 BGM 专属提示（内部检查编辑器是否打开）
hook.Add("HUDPaint", "KARDS_BGM_Messages_Draw", function()
    Compat.DrawBGMMessages()
    Compat.DrawBGMHoverTooltip()
end)

end
