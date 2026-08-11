if CLIENT then

KARDS.CardEditor.Audio = KARDS.CardEditor.Audio or {}

KARDS.CardEditor.Audio.SoundPaths = {
    drag_new_node = {
        "editor/drag_new_node.wav",
        "editor/drag_new_node_2.wav"
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
    upload_image_fail = {
        "editor/upload_image_fail.wav"
    },
    upload_image_success = {
        "editor/upload_image_success.wav",
        "editor/upload_image_success_2.wav",
        "editor/upload_image_success_3.wav",
        "editor/upload_image_success_4.wav",
        "editor/upload_image_success_5.wav"
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
    select_infantry = {
        "editor/select_infantry.wav"
    },
    select_keyword = {
        "editor/select_keyword.wav"
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
    CurrentChannel = nil,
    NextPlayTime = 0,
    InitialDelay = 3, -- 打开编辑器后等待多少秒开始播放
    MinWaitTime = 5, -- 播放完后最少等待多少秒
    MaxWaitTime = 9, -- 播放完后最多等待多少秒
    FadeDuration = 1.5, -- 淡出时长（秒）
    CurrentIndex = 1, -- 当前播放的索引
    Volume = 1 -- 背景音效音量倍率（1=原音量；播放外部模组音乐时可由其注册配置调低）
}

-- 设置背景音效音量倍率（外部 BGM 风格播放时按注册配置调整，如未知伤亡 = 0.5）
function KARDS.CardEditor.Audio.SetBackgroundMusicVolume(scale)
    local bgMusic = KARDS.CardEditor.Audio.BackgroundMusic
    bgMusic.Volume = scale or 1
    -- 立即应用到当前正在播放的音效
    if IsValid(bgMusic.CurrentChannel) then
        bgMusic.CurrentChannel:SetVolume(bgMusic.Volume)
    end
end

-- 获取音效时长（Garry's Mod没有直接API，我们估算）
function KARDS.CardEditor.Audio.GetSoundDuration(soundPath)
    -- 简单估算：假设背景音效平均3-5秒
    return 4
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

function KARDS.CardEditor.Audio.PlayUploadImageFail()
    KARDS.CardEditor.Audio.PlayRandomSound("upload_image_fail")
end

function KARDS.CardEditor.Audio.PlayUploadImageSuccess()
    KARDS.CardEditor.Audio.PlayRandomSound("upload_image_success")
end

function KARDS.CardEditor.Audio.PlayNotification()
    KARDS.CardEditor.Audio.PlayRandomSound("notification")
end

function KARDS.CardEditor.Audio.PlayNotificationSuccess()
    KARDS.CardEditor.Audio.PlayRandomSound("notification_success")
end

function KARDS.CardEditor.Audio.PlayClickUploadTemplate()
    KARDS.CardEditor.Audio.PlayRandomSound("click_upload_template")
end

function KARDS.CardEditor.Audio.PlayConnect()
    KARDS.CardEditor.Audio.PlayRandomSound("connect")
end

function KARDS.CardEditor.Audio.PlaySelectInfantry()
    KARDS.CardEditor.Audio.PlayRandomSound("select_infantry")
end

function KARDS.CardEditor.Audio.PlaySelectKeyword()
    KARDS.CardEditor.Audio.PlayRandomSound("select_keyword")
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

    -- 停止当前播放的音效（通过 CurrentChannel 停止）
    if IsValid(bgMusic.CurrentChannel) then
        bgMusic.CurrentChannel:Stop()
    end
    bgMusic.CurrentChannel = nil
end

function KARDS.CardEditor.Audio.UpdateBackgroundMusic()
    local bgMusic = KARDS.CardEditor.Audio.BackgroundMusic

    if not bgMusic.IsPlaying then return end

    local currentTime = CurTime()

    -- 检查是否到了播放时间
    if currentTime >= bgMusic.NextPlayTime then
        local sounds = KARDS.CardEditor.Audio.SoundPaths["background"]
        if sounds and #sounds > 0 then
            -- 停止旧的音效（通过 CurrentChannel 停止）
            if IsValid(bgMusic.CurrentChannel) then
                bgMusic.CurrentChannel:Stop()
                bgMusic.CurrentChannel = nil
            end

            local randomIndex = math.random(1, #sounds)
            local soundPath = sounds[randomIndex]

            -- 使用 sound.PlayFile 获取可控制的 channel（异步回调）
            local playVolume = bgMusic.Volume
            sound.PlayFile("sound/" .. soundPath, "noplay", function(channel, err, errName)
                if IsValid(channel) then
                    channel:SetVolume(playVolume)
                    channel:Play()
                    bgMusic.CurrentChannel = channel
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

end
