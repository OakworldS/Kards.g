if CLIENT then

KARDS.CardEditor.Audio = KARDS.CardEditor.Audio or {}

KARDS.CardEditor.Audio.SoundPaths = {
    drag_new_node = {
        "editor/drag_new_node.wav",
        "editor/drag_new_node_2.wav",
        "editor/drag_new_node_3.wav",
        "editor/drag_new_node_4.wav"
    },
    save = {
        "editor/save.wav",
        "editor/save_2.wav",
        "editor/save_3.wav",
        "editor/save_4.wav",
        "editor/save_5.wav",
        "editor/save_6.wav"
    },
    delete_connection_or_node = {
        "editor/delete_connection_or_node.wav"
    },
    load = {
        "editor/load.wav",
        "editor/load_2.wav",
        "editor/load_3.wav",
        "editor/load_4.wav"
    },
    notification = {
        "editor/notification.wav",
        "editor/notification_2.wav",
        "editor/notification_3.wav"
    },
    notification_success = {
        "editor/upload_image_success.wav",
        "editor/upload_image_success_2.wav",
        "editor/upload_image_success_3.wav"
    },
    click_upload_template = {
        "editor/click_upload_template.wav"
    },
    connect = {
        "editor/connect.wav",
        "editor/connect_2.wav",
        "editor/connect_3.wav",
        "editor/connect_4.wav",
        "editor/connect_5.wav"
    },
    open = {
        "editor/open_1.wav",
        "editor/open_2.wav",
        "editor/open_3.wav",
        "editor/open_4.wav"
    },
    expand = {
        "editor/expand.wav"
    },
    background = {
        "editor/background_1.wav",
        "editor/background_2.wav",
        "editor/background_3.wav",
        "editor/background_4.wav",
        "editor/background_5.wav",
        "editor/background_6.wav",
        "editor/background_7.wav",
        "editor/background_8.wav",
        "editor/background_9.wav",
        "editor/background_10.wav",
        "editor/background_11.wav",
        "editor/background_12.wav",
        "editor/background_13.wav",
        "editor/background_14.wav",
        "editor/background_15.wav",
        "editor/background_16.wav",
        "editor/background_17.wav",
        "editor/background_18.wav",
        "editor/background_19.wav"
    }
}

-- 背景音效管理变量
KARDS.CardEditor.Audio.BackgroundMusic = {
    IsPlaying = false,
    Channels = {}, -- 正在播放的背景音效条目列表 {channel, path}（允许与上一音效叠加，停止/调音量时遍历全部）
    NextPlayTime = 0,
    InitialDelay = 3, -- 打开编辑器后等待多少秒开始播放
    MinWaitTime = 5, -- 播放完后最少等待多少秒
    MaxWaitTime = 9, -- 播放完后最多等待多少秒
    FadeDuration = 1.5, -- 淡出时长（秒）
    CurrentIndex = 1, -- 当前播放的索引
    Volume = 1 -- 背景音效音量倍率（1=原音量；播放外部模组音乐时可由其注册配置调低）
}

-- 清理已播完/失效的背景音效通道（GetState()==0 为播放完毕），避免叠加播放时通道列表膨胀
local function PruneBackgroundChannels(bgMusic)
    local alive = {}
    for _, entry in ipairs(bgMusic.Channels) do
        if IsValid(entry.channel) and entry.channel:GetState() ~= 0 then
            alive[#alive + 1] = entry
        end
    end
    bgMusic.Channels = alive
end

-- 设置背景音效音量倍率（外部 BGM 风格播放时按注册配置调整，如未知伤亡 = 0.5）
function KARDS.CardEditor.Audio.SetBackgroundMusicVolume(scale)
    local bgMusic = KARDS.CardEditor.Audio.BackgroundMusic
    bgMusic.Volume = scale or 1
    -- 立即应用到所有正在播放的音效（允许叠加，逐一设置）
    for _, entry in ipairs(bgMusic.Channels) do
        if IsValid(entry.channel) then
            entry.channel:SetVolume(bgMusic.Volume)
        end
    end
end

function KARDS.CardEditor.Audio.PlaySound(soundPath)
    if soundPath and soundPath ~= "" then
        surface.PlaySound(soundPath)
    end
end

function KARDS.CardEditor.Audio.PlayRandomSound(soundType)
    local sounds = KARDS.CardEditor.Audio.SoundPaths[soundType]
    if not sounds or #sounds == 0 then return end
    
    local randomIndex = math.random(1, #sounds)
    KARDS.CardEditor.Audio.PlaySound(sounds[randomIndex])
end

function KARDS.CardEditor.Audio.PlayDragNewNode()
    KARDS.CardEditor.Audio.PlayRandomSound("drag_new_node")
end

function KARDS.CardEditor.Audio.PlaySave()
    KARDS.CardEditor.Audio.PlayRandomSound("save")
end

function KARDS.CardEditor.Audio.PlayDelete()
    KARDS.CardEditor.Audio.PlayRandomSound("delete_connection_or_node")
end

function KARDS.CardEditor.Audio.PlayLoad()
    KARDS.CardEditor.Audio.PlayRandomSound("load")
end

function KARDS.CardEditor.Audio.PlayNotification()
    KARDS.CardEditor.Audio.PlayRandomSound("notification")
end

function KARDS.CardEditor.Audio.PlayNotificationSuccess()
    KARDS.CardEditor.Audio.PlayRandomSound("notification_success")
end

function KARDS.CardEditor.Audio.PlayConnect()
    KARDS.CardEditor.Audio.PlayRandomSound("connect")
end

function KARDS.CardEditor.Audio.PlayClick()
    KARDS.CardEditor.Audio.PlayRandomSound("click_upload_template")
end

function KARDS.CardEditor.Audio.PlayOpen()
    KARDS.CardEditor.Audio.PlayRandomSound("open")
end

function KARDS.CardEditor.Audio.PlayExpand()
    KARDS.CardEditor.Audio.PlayRandomSound("expand")
end

-- 背景音效系统
function KARDS.CardEditor.Audio.StartBackgroundMusic()
    local bgMusic = KARDS.CardEditor.Audio.BackgroundMusic
    bgMusic.NextPlayTime = CurTime() + 1 -- 1秒后就开始播放，不等太久
    bgMusic.IsPlaying = true
end

function KARDS.CardEditor.Audio.StopBackgroundMusic()
    local bgMusic = KARDS.CardEditor.Audio.BackgroundMusic
    bgMusic.IsPlaying = false

    -- 停止全部正在播放的音效（允许叠加，需逐一停止）
    for _, entry in ipairs(bgMusic.Channels) do
        if IsValid(entry.channel) then
            entry.channel:Stop()
        end
    end
    bgMusic.Channels = {}
end

function KARDS.CardEditor.Audio.UpdateBackgroundMusic()
    local bgMusic = KARDS.CardEditor.Audio.BackgroundMusic

    if not bgMusic.IsPlaying then return end

    local currentTime = CurTime()

    -- 回收已播完的通道（叠加播放时列表会累积，须每帧清理）
    PruneBackgroundChannels(bgMusic)

    -- 检查是否到了播放时间
    if currentTime >= bgMusic.NextPlayTime then
        local sounds = KARDS.CardEditor.Audio.SoundPaths["background"]
        if sounds and #sounds > 0 then
            -- 与上一音效叠加：不再停止旧通道（2026-10-05 用户规格：取消「播放下一音效时停止上一音效」）
            -- 播放期间排除自身：短音效一两秒即播完，此规则实际只对长音效生效（如 background_9 达 56 秒，
            -- 横跨十来个触发周期，若不排除会同一首叠播）
            local playingPaths = {}
            for _, entry in ipairs(bgMusic.Channels) do
                playingPaths[entry.path] = true
            end
            local candidates = {}
            for _, path in ipairs(sounds) do
                if not playingPaths[path] then
                    candidates[#candidates + 1] = path
                end
            end
            if #candidates == 0 then candidates = sounds end -- 全部在播时保底，避免无候选

            local soundPath = candidates[math.random(1, #candidates)]

            -- 使用 sound.PlayFile 获取可控制的 channel（异步回调）
            local playVolume = bgMusic.Volume
            sound.PlayFile("sound/" .. soundPath, "noplay", function(channel, err, errName)
                if IsValid(channel) then
                    channel:SetVolume(playVolume)
                    channel:Play()
                    bgMusic.Channels[#bgMusic.Channels + 1] = { channel = channel, path = soundPath }
                end
            end)

            -- 下次播放时间
            local waitTime = math.Rand(bgMusic.MinWaitTime, bgMusic.MaxWaitTime)
            bgMusic.NextPlayTime = currentTime + waitTime
        else
            -- 如果没有列表，3秒后再试
            bgMusic.NextPlayTime = currentTime + 3
        end
    end
end

--[[
    音效试听 + BGM/背景音效 duck（属性页音效选择器试听用，2026-08-13）：
    - Preview：当前试听状态（path/channel/playing），同一时间仅一个试听音频。
    - 试听期间编辑器 BGM（Compat.DynamicBGM.EditorTrackChannel）与背景音效
      （BackgroundMusic）渐变至 50% 音量（duck）；暂停 / 选中并锁定 / 播放完毕
      后渐变还原。瞬时点击音（surface.PlaySound）不参与。
]]
KARDS.CardEditor.Audio.Preview = {
    path = nil,    -- 当前试听音效完整相对路径（sound/… 或 data/…）
    channel = nil, -- SoundHandle
    playing = false,
}

KARDS.CardEditor.Audio.PreviewDuck = {
    active = false, -- duck 是否进行中
    mul = 1,        -- 当前音量倍率（1 = 原音量）
    target = 1,     -- 目标倍率（试听中 0.5，停止后 1）
    fadeDur = 0.6,  -- 渐变时长（秒）
    bgBase = 1,     -- duck 起始时 BackgroundMusic.Volume 基线
    chBase = 0.5,   -- duck 起始时编辑器 BGM channel 音量基线
}

function KARDS.CardEditor.Audio.StartDuck()
    local Audio = KARDS.CardEditor.Audio
    local duck = Audio.PreviewDuck
    if duck.active then return end -- 已有 duck 进行中：保留原基线，避免二次压低
    duck.active = true
    duck.mul = 1
    duck.target = 0.5
    duck.bgBase = Audio.BackgroundMusic.Volume
    local compat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
    local ch = compat and compat.EditorTrackChannel
    duck.chBase = IsValid(ch) and ch:GetVolume() or 0.5
end

-- 试听指定音效（自动停止旧试听；回调成功才置 playing=true，失败立即还原）
function KARDS.CardEditor.Audio.PlayPreviewSound(path)
    local Audio = KARDS.CardEditor.Audio
    Audio.StopPreviewSound()
    Audio.PreviewDuck.target = 0.5 -- 新试听：恢复 duck 目标（StartDuck 已在旧 duck 中时只需改目标）
    if not Audio.PreviewDuck.active then
        Audio.StartDuck()
    end
    Audio.Preview.path = path
    Audio.Preview.playing = false
    sound.PlayFile(path, "noplay", function(channel)
        if IsValid(channel) then
            channel:SetVolume(1)
            channel:Play()
            Audio.Preview.channel = channel
            Audio.Preview.playing = true
        else
            -- 加载失败（文件不存在/BASS 限制等）：停止试听并还原音量与图标
            Audio.StopPreviewSound()
        end
    end)
    hook.Add("Think", "KARDS_Editor_Audio_Preview", Audio.UpdatePreviewDuck)
end

-- 停止试听（暂停 / 选中并锁定 / 播放完毕 统一走此函数）：还原图标并触发 duck 还原
function KARDS.CardEditor.Audio.StopPreviewSound()
    local Audio = KARDS.CardEditor.Audio
    local preview = Audio.Preview
    if IsValid(preview.channel) then
        preview.channel:Stop()
    end
    preview.channel = nil
    preview.path = nil
    preview.playing = false
    Audio.PreviewDuck.target = 1 -- Think 逐帧渐变回原音量
end

-- Think：播放完毕检测 + duck 音量渐变（帧率无关，按 fadeDur 线性逼近）
function KARDS.CardEditor.Audio.UpdatePreviewDuck()
    local Audio = KARDS.CardEditor.Audio
    local preview = Audio.Preview
    local duck = Audio.PreviewDuck

    -- 播放完毕检测：channel 已停止（GetState()==0）→ 自动停止试听（还原图标 + duck 还原）
    if preview.playing and IsValid(preview.channel) and preview.channel:GetState() == 0 then
        Audio.StopPreviewSound()
    end

    if duck.active then
        local step = FrameTime() / duck.fadeDur
        if duck.mul < duck.target then
            duck.mul = math.min(duck.target, duck.mul + step)
        elseif duck.mul > duck.target then
            duck.mul = math.max(duck.target, duck.mul - step)
        end
        -- 应用到背景音效（新 channel 播放时读 Volume 已含 duck 倍率；叠加时逐一设置）
        Audio.BackgroundMusic.Volume = duck.bgBase * duck.mul
        for _, entry in ipairs(Audio.BackgroundMusic.Channels) do
            if IsValid(entry.channel) then
                entry.channel:SetVolume(Audio.BackgroundMusic.Volume)
            end
        end
        -- 应用到编辑器 BGM 曲目 channel（曲目切换新 channel 置 0.5 也由本帧覆盖）
        local compat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
        local ch = compat and compat.EditorTrackChannel
        if IsValid(ch) then
            ch:SetVolume(duck.chBase * duck.mul)
        end
        -- 停止且已还原到 1：结束 duck（Volume 已等于 bgBase）
        if duck.mul == 1 and not preview.playing then
            duck.active = false
            Audio.BackgroundMusic.Volume = duck.bgBase
        end
    end

    -- 无试听且无 duck 时移除 hook
    if not preview.playing and not duck.active then
        hook.Remove("Think", "KARDS_Editor_Audio_Preview")
    end
end

end
