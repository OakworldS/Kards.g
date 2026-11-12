-- Kards Card Editor - dynamic_BGM Compatibility Module
-- This module provides seamless audio compatibility between Kards and dynamic_BGM addons.
-- When the Kards editor opens, dynamic_BGM track volumes fade out to zero.
-- When the Kards editor closes, dynamic_BGM track volumes fade back to their original levels.
-- The BGM playback process of dynamic_BGM is never interrupted.

if CLIENT then

KARDS.CardEditor.Compat = KARDS.CardEditor.Compat or {}
KARDS.CardEditor.Compat.DynamicBGM = KARDS.CardEditor.Compat.DynamicBGM or {}

local Compat = KARDS.CardEditor.Compat.DynamicBGM

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- State variables for track volume management
Compat.OriginalIdleMaxVolume = nil
Compat.OriginalCombatMaxVolume = nil
Compat.OriginalMasterVolume = nil
Compat.IsFadedOut = false
Compat.FadeDuration = 1.5

-- Editor track state
Compat.CurrentEditorTrack = nil
Compat.CurrentCountry = nil
Compat.EditorTrackChannel = nil
Compat.CurrentTrackIndex = 0 -- 用于循环播放的索引
Compat.CurrentTrackName = nil -- 当前播放曲目的音乐名（文件名 <序号>.<音乐名>.ogg 解析，纯数字文件名为 nil）
Compat.TrackLoading = false -- sound.PlayFile 正在异步加载/等待回调中，Think 不应抢跑切歌
Compat.NextTrackRetryAt = 0 -- 自动重试的时间点（秒）：播放失败后到点前 Think 不再重试，避免逐帧刷 sound.PlayFile

-- 平滑缓动（提示出入场透明度 GetBGMMessageAlpha 与悬停简介淡入淡出共用，2026-08-15 编辑器重构 7.5-4）
local function BGMHoverSmoothstep(t)
    t = math.Clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

-- ===== BGM 播放模式（右键曲目列表顶部"模式"按键，2026-08-14） =====
-- random 随机选择（当前风格内随机）/ random_all 跨列表随机选择（所有风格随机）
-- loop 循环列表（当前风格内顺序循环）/ loop_all 跨列表循环（所有风格顺序循环）/ single 单曲循环（循环当前曲目）
-- 玩家选择的模式持久记忆：garrysmod/data/kards_bgm_playmode.txt
local PlayModeFile = "kards_bgm_playmode.txt"
Compat.PlayMode = "random"
Compat.PlayModeOrder = { "random", "random_all", "loop", "loop_all", "single" }
Compat.PlayModeNames = {
    random = T("editor.bgm.mode_random"),
    random_all = T("editor.bgm.mode_random_all"),
    loop = T("editor.bgm.mode_loop"),
    loop_all = T("editor.bgm.mode_loop_all"),
    single = T("editor.bgm.mode_single")
}

-- 载入持久记忆的播放模式（仅在模式合法时采用）；顶层调用一次（2026-08-15 编辑器重构 7.5-4）
local function InitPlayMode()
    local savedMode = file.Read(PlayModeFile, "DATA")
    if savedMode then
        savedMode = string.Trim(savedMode)
        if Compat.PlayModeNames[savedMode] then
            Compat.PlayMode = savedMode
        end
    end
end
InitPlayMode()

-- 设置播放模式并持久记忆（无效模式忽略并返回 false）
function Compat.SetPlayMode(mode)
    if not Compat.PlayModeNames[mode] then return false end
    if Compat.PlayMode ~= mode then
        Compat.PlayMode = mode
        file.Write(PlayModeFile, mode)
    end
    return true
end

-- 循环到下一个播放模式（"模式"按键点击用），返回新模式
function Compat.CyclePlayMode()
    local order = Compat.PlayModeOrder
    local currentIdx = 1
    for i, m in ipairs(order) do
        if m == Compat.PlayMode then currentIdx = i break end
    end
    Compat.SetPlayMode(order[(currentIdx % #order) + 1])
    return Compat.PlayMode
end

-- 当前播放模式的中文显示名
function Compat.GetPlayModeName()
    return Compat.PlayModeNames[Compat.PlayMode] or Compat.PlayMode
end

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

-- 确保国家条目存在（RefreshCountryTracks / RegisterCountry / RegisterTrack 共用缺省创建，2026-08-15 编辑器重构 7.5-4）
-- color 仅在新建时应用（已存在条目不覆盖）；返回条目
local function EnsureCountryEntry(countryId, color)
    if not Compat.CountryMusic[countryId] then
        Compat.CountryMusic[countryId] = { tracks = {}, color = color or nil }
    end
    return Compat.CountryMusic[countryId]
end

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

        EnsureCountryEntry(folder)
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
        msg.fullText = T("editor.bgm.play_prefix", tostring(text))
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
        msg.fullText = T("editor.bgm.error_prefix", tostring(text))
        msg.enterDur = 0
        msg.holdDur = 5.0
        msg.exitDur = 0
        msg.maxAlpha = 230 -- 90%
        msg.flash = true -- 2Hz 渐变闪烁
        msg.color = Color(220, 60, 60)
    elseif kind == "warning" then
        msg.fullText = T("editor.bgm.warning_prefix", tostring(text))
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
        alpha = m.maxAlpha * BGMHoverSmoothstep(t)
    elseif age < m.enterDur + m.holdDur then
        alpha = m.maxAlpha
    elseif m.exitDur > 0 then
        local t = math.min((age - m.enterDur - m.holdDur) / m.exitDur, 1)
        alpha = m.maxAlpha * (1 - BGMHoverSmoothstep(t))
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
    local rightX = win.x + win.width - marginX
    local baseY = win.y + win.height - bottomMargin

    -- 歌词独立槽（与提示并存）：固定占右下角最底部，原文在上、译文在下，提示堆叠在歌词上方（歌词见文末同步/解析）
    local lyricText, lyricSub, lyricAlpha = Compat.GetLyricDisplay()
    local lyricVisible = lyricText and lyricText ~= "" and lyricAlpha > 0
    local lyricRows = 0
    if lyricVisible then
        local hasSub = lyricSub and lyricSub ~= ""
        lyricRows = hasSub and 2 or 1
        -- 自底向上：译文画在最底部（baseY），原文抬到其上一行
        local y = baseY
        if hasSub then
            draw.SimpleText(lyricSub, font, rightX, y, Color(255, 255, 255, lyricAlpha), TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
            y = y - lineH - Compat.LyricLineGap
        end
        draw.SimpleText(lyricText, font, rightX, y, Color(255, 255, 255, lyricAlpha), TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
    end

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

    -- 目标位置：自底向上堆叠（右下角）；歌词占位时提示整体上移（双语两行时占两行）
    local lyricBlockHeight = 0
    if lyricVisible then
        lyricBlockHeight = (lineH + Compat.LyricLineGap) * (lyricRows - 1) + lineH + spacing
    end
    local cursorY = baseY - lyricBlockHeight
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

    -- 绘制（右对齐，文本底边在 currentY；rightX 见函数开头）
    for i, m in ipairs(valid) do
        local age = now - m.createdAt
        local alpha = Compat.GetBGMMessageAlpha(m, age)
        draw.SimpleText(m.fullText, font, rightX, m.currentY, Color(m.color.r, m.color.g, m.color.b, alpha), TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
    end
end

-- ===== BGM 歌词（编辑器窗口右下角独立槽，2026-10-05）=====
-- 数据源：data_static/kards/bgm_lyrics/<国家>/<序号>.<音乐名>.txt（LRC 文本，可单语可双语），与音频
-- sound/editor/<国家>/<序号>.<音乐名>.ogg 路径镜像。gmad 只放行 data_static/ 下的 .json/.txt
-- （.lrc 会被白名单拒绝并导致整包失败），故歌词以 .txt 承载 LRC 文本。
-- 时间轴：播放位置取 Compat.EditorTrackChannel:GetTime()（秒），在 Think 中逐帧比对时间戳，
-- 不依赖 SysTime 累加，天然跟随暂停与切歌。
-- 双语（2026-10-16）：同一时间戳连写两行，前一行是原文、后一行是译文；显示时原文在上、译文在下。
-- 某时间戳只有一行时视为单语，译文槽留空、不占位（如纯器乐或未译曲目仍按原样显示）。
Compat.LyricLines = nil -- 解析后的行数组 { { t = 秒, text = 原文, translation = 译文或 nil }, ... }（按 t 升序）
Compat.LyricIndex = 0 -- 当前应显示的行号（0 = 未到第一行）
Compat.LyricChangeTime = nil -- 当前行切换时刻（SysTime），用于淡入
Compat.LyricFadeIn = 0.4 -- 行切换淡入时长（秒）
Compat.LyricMaxAlpha = 99 -- 歌词最大透明度（65%，2026-10-17 用户规格）
Compat.LyricLineGap = 2 -- 原文与译文两行之间的额外行距（像素）

-- 解析 LRC 文本：支持 [mm:ss.xx]/[mm:ss.xxx]/[mm:ss] 时间戳、一行多时间戳、
-- 元数据标签（ti/ar/al/by/offset 等非时间标签忽略）
-- 双语配对：同一时间戳出现的两行，前一行作原文、后一行作译文。
-- Lua 的 table.sort 不稳定，故先按出现序编号再按（时间，出现序）排序，
-- 保证同一时间戳的原文仍排在译文之前，配对不会因排序而颠倒。
function Compat.ParseLRC(content)
    local raw = {}
    local seq = 0
    for rawLine in string.gmatch(content, "[^\r\n]+") do
        local stamps = {}
        local rest = rawLine
        while true do
            local tag, after = string.match(rest, "^%[([^%]]*)%](.*)$")
            if not tag then break end
            rest = after
            local mm, ss = string.match(tag, "^(%d+):(%d+%.?%d*)$")
            if mm and ss then
                stamps[#stamps + 1] = tonumber(mm) * 60 + tonumber(ss)
            end
        end
        local text = string.Trim(rest)
        for _, t in ipairs(stamps) do
            seq = seq + 1
            raw[#raw + 1] = { t = t, text = text, seq = seq }
        end
    end
    table.sort(raw, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.seq < b.seq
    end)

    -- 合并同时间戳：紧邻的下一行填进上一个条目的译文槽；多出的行另起新条目（不丢文本）
    local lines = {}
    for _, item in ipairs(raw) do
        local last = lines[#lines]
        if last and last.t == item.t and not last.translation then
            if last.text == "" then
                last.text = item.text -- 原文位为空（如多出一个空的时间戳行）时顺延到原文
            else
                last.translation = item.text
            end
        else
            lines[#lines + 1] = { t = item.t, text = item.text, translation = nil }
        end
    end
    return lines
end

-- 按当前曲目路径加载歌词：sound/editor/<国家>/<file>.ogg → data_static/kards/bgm_lyrics/<国家>/<file>.txt
-- 无对应文件或解析为空则视为无歌词（外部注册曲目通常无歌词）
function Compat.LoadLyricForTrack(trackPath)
    Compat.LyricLines = nil
    Compat.LyricIndex = 0
    Compat.LyricChangeTime = nil
    if not trackPath then return end
    local rel = trackPath:match("^sound/editor/(.+)$")
    if not rel then return end
    rel = rel:gsub("%.ogg$", "")
    local content = file.Read("data_static/kards/bgm_lyrics/" .. rel .. ".txt", "GAME")
    if not content then return end
    local lines = Compat.ParseLRC(content)
    if #lines > 0 then
        Compat.LyricLines = lines
    end
end

-- 歌词行推进（Think 每帧）：按播放位置定位最后一条已到达的时间戳
function Compat.UpdateLyric()
    local lines = Compat.LyricLines
    if not lines or #lines == 0 then return end
    local ch = Compat.EditorTrackChannel
    if not IsValid(ch) then return end
    if not ch.GetTime then return end -- 通道无 GetTime（异常实现）时跳过，避免逐帧报错
    local t = ch:GetTime()
    if not t then return end
    local idx = 0
    for i = 1, #lines do
        if lines[i].t <= t then idx = i else break end
    end
    if idx ~= Compat.LyricIndex then
        Compat.LyricIndex = idx
        Compat.LyricChangeTime = SysTime()
    end
end

-- 当前歌词行的显示文本与透明度（空行=间奏不显示；行切换淡入）
-- 返回 原文, 译文, 透明度；无歌词或原文为空返回 nil, nil, 0（译文可为 nil，调用方按单语处理）
function Compat.GetLyricDisplay()
    local lines = Compat.LyricLines
    local idx = Compat.LyricIndex
    if not lines or not idx or idx < 1 then return nil, nil, 0 end
    local line = lines[idx]
    if not line or line.text == "" then return nil, nil, 0 end
    local age = SysTime() - (Compat.LyricChangeTime or 0)
    local alpha = Compat.LyricMaxAlpha * BGMHoverSmoothstep(math.Clamp(age / Compat.LyricFadeIn, 0, 1))
    return line.text, line.translation, math.floor(alpha + 0.5)
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

-- UTF-8 安全逐字符拆分（兼容中英文混排；统一委托 Core.Utils.SplitUTF8Chars，见 sh_utils.lua）
local BGMHoverSplitChars = KARDS.CardEditor.Core.Utils.SplitUTF8Chars

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
        Compat.ShowBGMMessage(T("editor.bgm.register_country_invalid_id", tostring(countryId)), "error")
        return
    end
    if type(data) ~= "table" then
        KARDS.CardEditor:Log("外部BGM注册警告：风格 '" .. countryId .. "' 的配置 data 必须为表，实际为 " .. type(data))
        Compat.ShowBGMMessage(T("editor.bgm.register_country_invalid_data", countryId), "error")
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
    EnsureCountryEntry(countryId, data.color)
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
        Compat.ShowBGMMessage(T("editor.bgm.register_track_invalid_path", tostring(trackPath)), "error")
        return
    end
    EnsureCountryEntry(countryId)
    local data = Compat.CountryMusic[countryId]
    -- 防重复：同路径只注册一次
    for _, t in ipairs(data.tracks) do
        if t.path == trackPath then return end
    end
    -- 校验音频文件存在，避免外部模组注册无效路径（静默失败无任何提示）
    if not file.Exists(trackPath, "GAME") then
        KARDS.CardEditor:Log("外部BGM注册警告：音频文件不存在：" .. tostring(trackPath) .. "（所属风格：" .. tostring(countryId) .. "）")
        Compat.ShowBGMMessage(T("editor.bgm.register_track_missing", tostring(trackPath)), "error")
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
    -- 清空自动重试冷却，避免上一次会话的失败退避延续到下一次播放
    Compat.NextTrackRetryAt = 0
    
    -- 停止当前channel
    if IsValid(Compat.EditorTrackChannel) then
        Compat.EditorTrackChannel:Stop()
    end
    Compat.EditorTrackChannel = nil
    Compat.CurrentEditorTrack = nil
    Compat.CurrentTrackName = nil
    -- 清空歌词状态（曲目停止）
    Compat.LyricLines = nil
    Compat.LyricIndex = 0
    Compat.LyricChangeTime = nil
end

-- Check whether the dynamic_BGM addon is present and functional.
function Compat.IsAvailable()
    return _G.DynamicBGM ~= nil and _G.DynamicBGM.Config ~= nil
end

-- 参数化通用音量渐变（FadeOut / FadeIn 共用，2026-08-15 编辑器重构 7.5-4）：
--   fadeOut=true  淡出：先保存原始配置，渐变到 0
--   fadeOut=false 淡入：从当前值渐变回原始值，完成后清空保存的原始配置
-- 渐变起点语义与重构前一致：淡出固定用保存的原始值、淡入每帧读当前值
local function FadeVolumes(fadeOut)
    if not Compat.IsAvailable() then return end
    -- 淡出中再次淡出 / 非淡出状态下淡入：忽略
    if fadeOut == Compat.IsFadedOut then return end

    if fadeOut then
        -- Save original configuration values
        Compat.OriginalIdleMaxVolume = _G.DynamicBGM.Config.MaxIdleVolume
        Compat.OriginalCombatMaxVolume = _G.DynamicBGM.Config.MaxCombatVolume
        Compat.OriginalMasterVolume = _G.DynamicBGM.Config.MasterVolume
    end
    Compat.IsFadedOut = fadeOut
    local fadeStart = CurTime()
    local hookName = fadeOut and "KARDS_DynamicBGM_FadeOut" or "KARDS_DynamicBGM_FadeIn"

    hook.Add("Think", hookName, function()
        -- 中途状态被反向操作（淡入中又淡出等）：终止本渐变
        if Compat.IsFadedOut ~= fadeOut then
            hook.Remove("Think", hookName)
            return
        end

        local progress = math.Clamp((CurTime() - fadeStart) / Compat.FadeDuration, 0, 1)
        local cfg = _G.DynamicBGM.Config

        -- 淡出：原始值 → 0；淡入：当前值 → 原始值（当前值每帧读取，语义同重构前）
        cfg.MaxIdleVolume = Lerp(progress, fadeOut and Compat.OriginalIdleMaxVolume or cfg.MaxIdleVolume, fadeOut and 0 or Compat.OriginalIdleMaxVolume)
        cfg.MaxCombatVolume = Lerp(progress, fadeOut and Compat.OriginalCombatMaxVolume or cfg.MaxCombatVolume, fadeOut and 0 or Compat.OriginalCombatMaxVolume)
        cfg.MasterVolume = Lerp(progress, fadeOut and Compat.OriginalMasterVolume or cfg.MasterVolume, fadeOut and 0 or Compat.OriginalMasterVolume)

        if progress >= 1 then
            hook.Remove("Think", hookName)
            -- 淡入完成后清空保存的原始配置
            if not fadeOut then
                Compat.OriginalIdleMaxVolume = nil
                Compat.OriginalCombatMaxVolume = nil
                Compat.OriginalMasterVolume = nil
            end
        end
    end)
end

-- Fade out dynamic_BGM track volumes to zero over Compat.FadeDuration seconds.
function Compat.FadeOut()
    FadeVolumes(true)
end

-- Fade in dynamic_BGM track volumes back to original saved levels.
function Compat.FadeIn()
    FadeVolumes(false)
end

-- Stop any playing editor track
function Compat.StopEditorTrack()
    Compat.SafeStopChannel()
end

-- 启动循环检查 Think hook（PlayEditorTrack / PlaySpecificTrack 共用，2026-08-15 编辑器重构 7.5-4）：
-- 编辑器关闭/国家失效时停止；异步加载中不抢跑；channel 失效或播放完毕则自动切下一首
local function StartTrackLoopHook()
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
            -- 上次播放失败进入冷却中：等冷却结束再重试，避免逐帧刷 sound.PlayFile
            if SysTime() < Compat.NextTrackRetryAt then
                return
            end
            -- channel无效了，重新播放
            Compat.PlayNextTrack()
            return
        end

        -- 检查是否播放完了（0 = stopped, 1 = playing, 2 = paused）
        if Compat.EditorTrackChannel:GetState() == 0 then
            -- 冷却未到（刚失败过）时先不切歌，避免状态抖动引发连发
            if SysTime() < Compat.NextTrackRetryAt then
                return
            end
            -- 播放完了，播放下一首
            Compat.PlayNextTrack()
        end
    end)
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
        Compat.ShowBGMMessage(T("editor.bgm.style_no_tracks", tostring(country)), "warning")
        return
    end

    Compat.CurrentCountry = country
    Compat.CurrentTrackIndex = 0 -- 重置索引，从第一首开始
    Compat.IsInitialPlay = true -- 由"选择风格"发起：本次播放不重复发 switch 提示

    -- 播放第一首
    Compat.PlayNextTrack()

    -- 启动循环检查 Think hook（编辑器关闭/播放完毕自动切歌）
    StartTrackLoopHook()
end

-- 按当前 CurrentTrackIndex 播放曲目（内部）：停止旧 channel + 播放 + 回调验证 + 切换提示
-- PlayNextTrack（随机选曲）与 PlaySpecificTrack（右键曲目列表点选）共用本函数
local function PlayCurrentTrack()
    if not Compat.CurrentCountry or Compat.CurrentCountry == "none" then return end
    local countryData = Compat.CountryMusic[Compat.CurrentCountry]
    if not countryData or not countryData.tracks or #countryData.tracks == 0 then return end

    -- 先停止旧的channel
    if IsValid(Compat.EditorTrackChannel) then
        Compat.EditorTrackChannel:Stop()
    end
    Compat.EditorTrackChannel = nil

    -- 索引越界兜底（如 PlayEditorTrack 初始化索引 0 后直接进入 single 模式时，tracks[0] 为 nil）
    if Compat.CurrentTrackIndex < 1 or Compat.CurrentTrackIndex > #countryData.tracks then
        Compat.CurrentTrackIndex = 1
    end
    local trackData = countryData.tracks[Compat.CurrentTrackIndex]
    if not trackData then return end
    local trackPath = trackData.path
    Compat.CurrentEditorTrack = trackPath
    Compat.CurrentTrackName = trackData.name or nil
    -- 歌词加载：镜像路径 data_static/kards/bgm_lyrics/<国家>/<序号>.<音乐名>.txt（2026-10-05）
    Compat.LoadLyricForTrack(trackPath)

    -- 切换提示：仅"一曲到末尾而切换"时显示（由"选择风格"发起的初次播放不发，改由 play 提示承载）
    if Compat.IsInitialPlay then
        Compat.IsInitialPlay = false
    else
        Compat.ShowBGMMessage(Compat.CurrentTrackName or T("editor.bgm.music"), "switch")
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
            -- 失败后退避 2 秒再允许自动重试：否则循环 hook 每帧都会重新调 sound.PlayFile，
            -- 反复触发磁盘读取与解码，把帧预算耗光，表现为关于页卡死
            Compat.NextTrackRetryAt = SysTime() + 2
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

-- 所有风格曲目的扁平位置列表（跨列表模式用）：按国家 id 排序，跨列表顺序稳定
local function GetAllTracksFlat()
    local ids = {}
    for countryId, countryData in pairs(Compat.CountryMusic) do
        if countryId ~= "none" and countryData.tracks and #countryData.tracks > 0 then
            table.insert(ids, countryId)
        end
    end
    table.sort(ids)
    local all = {}
    for _, countryId in ipairs(ids) do
        for i = 1, #Compat.CountryMusic[countryId].tracks do
            table.insert(all, { country = countryId, index = i })
        end
    end
    return all
end

-- 在扁平列表中找到当前曲目（country, index）的位置；找不到返回 nil
local function FindFlatPos(country, index, all)
    for pos, entry in ipairs(all) do
        if entry.country == country and entry.index == index then
            return pos
        end
    end
    return nil
end

-- 按播放模式计算"下一首"目标，返回 newCountry, newIndex（列表无效时返回原值）
local function StepNext(country, index)
    local mode = Compat.PlayMode
    local trackCount = Compat.CountryMusic[country] and #Compat.CountryMusic[country].tracks or 0
    if trackCount == 0 then return country, index end

    if mode == "loop" then
        -- 循环列表：当前风格内顺序下一首（wrap）
        return country, (index % trackCount) + 1
    elseif mode == "single" then
        -- 单曲循环：始终重复当前曲目（自动切歌也重复）
        return country, index
    elseif mode == "random_all" or mode == "loop_all" then
        -- 跨列表模式：目标可能落在其他风格
        local all = GetAllTracksFlat()
        if #all <= 1 then return country, index end
        if mode == "loop_all" then
            local pos = FindFlatPos(country, index, all)
            if not pos then return country, index end
            local entry = all[(pos % #all) + 1]
            return entry.country, entry.index
        else
            -- 跨列表随机：随机挑选，避免与当前曲目重复
            local entry
            repeat
                entry = all[math.random(#all)]
            until not (entry.country == country and entry.index == index)
            return entry.country, entry.index
        end
    end
    -- random（默认）：当前风格内随机，避免与当前曲目重复
    if trackCount <= 1 then return country, index end
    local newIndex
    repeat
        newIndex = math.random(trackCount)
    until newIndex ~= index
    return country, newIndex
end

-- 按播放模式计算"上一首"目标，返回 newCountry, newIndex（列表无效时返回原值）
local function StepPrev(country, index)
    local mode = Compat.PlayMode
    local trackCount = Compat.CountryMusic[country] and #Compat.CountryMusic[country].tracks or 0
    if trackCount == 0 then return country, index end

    if mode == "random_all" or mode == "loop_all" then
        -- 跨列表模式：跨风格顺序上一首（wrap）
        local all = GetAllTracksFlat()
        if #all <= 1 then return country, index end
        local pos = FindFlatPos(country, index, all)
        if not pos then return country, index end
        local entry = all[((pos - 2) % #all) + 1]
        return entry.country, entry.index
    end
    -- 其余模式（random / loop / single）：当前风格内顺序上一首（wrap）
    return country, ((index - 2) % trackCount) + 1
end

-- 播放下一首（按播放模式；曲目自动切换与"下一首"按键共用）
function Compat.PlayNextTrack()
    if not Compat.CurrentCountry or Compat.CurrentCountry == "none" then
        return
    end

    local countryData = Compat.CountryMusic[Compat.CurrentCountry]
    if not countryData or not countryData.tracks or #countryData.tracks == 0 then
        return
    end

    local newCountry, newIndex = StepNext(Compat.CurrentCountry, Compat.CurrentTrackIndex)
    Compat.CurrentCountry = newCountry
    Compat.CurrentTrackIndex = newIndex

    -- 玩家点"下一首"也走本函数，故先清冷却，手动切歌不被失败退避拖延
    Compat.NextTrackRetryAt = 0
    PlayCurrentTrack()
end

-- 播放上一首（按播放模式；"上一首"按键用）
function Compat.PlayPrevTrack()
    if not Compat.CurrentCountry or Compat.CurrentCountry == "none" then
        return
    end

    local countryData = Compat.CountryMusic[Compat.CurrentCountry]
    if not countryData or not countryData.tracks or #countryData.tracks == 0 then
        return
    end

    local newCountry, newIndex = StepPrev(Compat.CurrentCountry, Compat.CurrentTrackIndex)
    Compat.CurrentCountry = newCountry
    Compat.CurrentTrackIndex = newIndex

    -- 玩家点"上一首"也走本函数，故先清冷却，手动切歌不被失败退避拖延
    Compat.NextTrackRetryAt = 0
    PlayCurrentTrack()
end

-- 播放指定曲目（编辑器 BGM 曲目列表面板右键点选，2026-08-14）：
-- 按索引播放指定曲目，随后由循环 hook 按该风格随机播放其余曲目（与"选择风格"行为一致）
function Compat.PlaySpecificTrack(country, index)
    local countryData = Compat.CountryMusic[country]
    if not countryData or not countryData.tracks or #countryData.tracks == 0 then return false end
    if not countryData.tracks[index] then return false end
    Compat.SafeStopChannel()
    Compat.CurrentCountry = country
    Compat.CurrentTrackIndex = index
    Compat.IsInitialPlay = true
    PlayCurrentTrack()

    -- 启动循环检查 Think hook（与 PlayEditorTrack 同款）
    StartTrackLoopHook()
    return true
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

-- 歌词同步：编辑器打开且曲目播放时逐帧推进歌词行（时间取自播放通道，见 Compat.UpdateLyric）
hook.Add("Think", "KARDS_EditorLyric_Sync", function()
    Compat.UpdateLyric()
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
        Compat.ShowBGMMessage(T("editor.bgm.style_no_registered_tracks", tostring(reg.id)), "warning")
    end
end

-- 主模组 BGM 相关模块（Canvas + compat）已就绪，通知外部模组可安全注册
hook.Run("KARDS_CardEditorReady")

-- BGM 专属提示与风格按钮悬停简介的绘制改由卡牌编辑器 DrawEditor 在内容绘制完成后调用
--（canvas_editor/effect_editor/cl_canvas_editor.lua 的 KARDS.CardEditor.Canvas.DrawEditor 末尾），
-- 以保证处于编辑器窗口最上层；此前独立 HUDPaint 钩子注册早于编辑器绘制钩子，绘制被窗口覆盖而不可见（2026-10-04 修复）

end
