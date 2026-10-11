-- 战斗 BGM（2026-08-14 用户规格 + 2026-08-15 播放模式）：对局开始（服务端
-- StartFormalBattle）时服务端仅向在场玩家发送 KardsBattleBGM（观战者收不到 →
-- 观战者不播放音乐）；本模块收到后本地独立随机——先从两个风格（kards / wards）
-- 中随机选一种，再从该风格曲库随机选一首播放——双方独立随机故音乐不要求相同
-- （允许不同/相同）。播放模式（2026-08-15 用户规格）：
--   1. 对战开始即播放（服务端 StartFormalBattle 即发消息，不等开场动画结束）；
--   2. 每当一首播完，BGM.Gap（5）秒后随机下一首（不单曲循环）；
--   3. 停止时机：对局结束（玩家端结算动画播放结束、退出牌桌 KardsTableExited）
--      → BGM.FadeOut 秒淡出停止；对局途中牌桌销毁（OnRemove）→ 立即停止。
-- 曲库结构（2026-08-15 用户规格）：sound/kards/bgm/<风格>/<国家>/ 按国家分文件夹
-- 存放；国家子目录与风格顶层直放的曲目都会被运行时 file.Find 自动发现——后续往
-- 现有目录加音乐、甚至新增国家子目录（如 china/）都无需改代码（见 CollectTracks）；
-- 全部文件名须为 ASCII（BASS 不支持非 ASCII 文件名，见 cl_dynamic_bgm_compat.lua）。
-- 测试版：BGM.Nation 保持 nil → 随机该风格下全部国家曲目（含顶层直放曲目）；
-- 正式版分国家播放基础：把 BGM.Nation 设为国家名，或调用 KARDS.PlayBattleBGM(nation)
-- 传入对局国家 → 只播放该国曲目。风格固定：默认每次随机选风格（kards/wards）；
-- 控制台命令 kards_table_bgm 可固定或切换风格（见文件底部）；新增风格目录则需把
-- 目录名加进 BGM.Styles。音量/间隔/淡出时长在下方 BGM 配置内调整。

-- 配置（代码内调整）
local BGM = {
    Volume = 0.6,                    -- 战斗 BGM 音量（0.0 ~ 1.0）
    Loop = false,                    -- 单曲循环：false=不循环单曲（一首结束 Gap 秒
                                     -- 后随机下一首，2026-08-15 用户规格）
    Gap = 5,                         -- 一首结束到随机下一首的间隔（秒）
    FadeOut = 2,                     -- 对局结束（退出牌桌）时 BGM 淡出时长（秒）；
                                     -- 牌桌销毁为立即停止
    Styles = { "kards", "wards" },   -- 两个风格目录名（sound/kards/bgm/ 下）；新增
                                     -- 风格目录时把目录名加进此表
    Nation = nil,                    -- 正式版分国家播放：nil=测试版（随机该风格下
                                     -- 全部国家曲目）；设为国家名=只播放该国曲目
    Style = nil,                     -- 固定风格：nil=每次随机选风格；设 "kards" 或
                                     -- "wards" 则固定该风格（kards_table_bgm 切换）
}
KARDS.BattleBGM = BGM -- 暴露配置，供其他模块/控制台临时调整

local BattleBGMHandle = nil -- 当前 BGM 通道（IGModAudioChannel；同 PlayAimSound 的
                            -- SoundHandle 管理模式，sound.PlayFile 异步加载回调驱动）
local CurrentStyle = nil    -- 当前曲目风格（切歌沿用，kards_table_bgm 切换时更新）
local CurrentNation = nil   -- 当前曲目国家（切歌沿用；nil=随机该风格下全部国家曲目）
local NextTrackTime = nil   -- 下一首排队时刻（CurTime；nil=未排队）
local LoadingTrack = false  -- 正在异步加载曲目（加载完成前不重复调度切歌）
local FadeOutEnd = nil      -- 淡出结束时刻（nil=无淡出）
local FadeOutDur = 0        -- 淡出总时长（秒）

-- 立即释放句柄（取消切歌排队/淡出状态）；空闲/加载中通道直接释放
local function KillHandle()
    NextTrackTime = nil
    FadeOutEnd = nil
    if BattleBGMHandle then
        if BattleBGMHandle:GetState() == 1 then BattleBGMHandle:Stop() end
        BattleBGMHandle = nil
    end
end

-- 停止战斗 BGM（fade：nil=立即停止；数字=淡出时长秒，仅播放中才淡出，归零后停）
function KARDS.StopBattleBGM(fade)
    NextTrackTime = nil -- 取消排队中的下一首
    if BattleBGMHandle and fade and BattleBGMHandle:GetState() == 1 then
        FadeOutEnd = CurTime() + fade
        FadeOutDur = fade
        return
    end
    KillHandle()
end

-- 收集某风格下的候选曲目列表：nation 为空 → 该风格所有国家子目录曲目 + 顶层直放
-- 曲目（国家目录由 file.Find 自动发现，新增国家目录无需改代码）；nation 指定 → 只
-- 收集该国子目录曲目（正式版分国家播放）。file.Find 返回两表：第一文件、第二子目录，
-- 故顶层扫描天然排除子目录不重复，国家扫描也只取直接文件。
local function CollectTracks(style, nation)
    local tracks = {}
    local base = "sound/kards/bgm/" .. style .. "/"
    if nation then
        for _, f in ipairs(file.Find(base .. nation .. "/*", "GAME")) do
            table.insert(tracks, nation .. "/" .. f)
        end
    else
        local files, folders = file.Find(base .. "*", "GAME")
        for _, country in ipairs(folders) do
            for _, f in ipairs(file.Find(base .. country .. "/*", "GAME")) do
                table.insert(tracks, country .. "/" .. f)
            end
        end
        for _, f in ipairs(files) do
            table.insert(tracks, f)
        end
    end
    return tracks
end

-- 播放指定风格/国家曲库中的随机一首（异步加载，加载完成回调接管句柄）
local function PlayTrack(style, nation)
    local tracks = CollectTracks(style, nation)
    if #tracks == 0 then
        local where = nation and (style .. "/" .. nation) or style
        print(("[Kards] 战斗 BGM：%s 曲库为空，请在 sound/kards/bgm/%s/ 放入音乐"):format(where, where))
        BattleBGMHandle = nil
        return
    end
    local track = tracks[math.random(#tracks)]
    local path = "sound/kards/bgm/" .. style .. "/" .. track
    LoadingTrack = true
    sound.PlayFile(path, "noplay", function(snd)
        LoadingTrack = false
        if not snd then
            print(("[Kards] 战斗 BGM 加载失败: %s"):format(path))
            BattleBGMHandle = nil
            return
        end
        BattleBGMHandle = snd
        snd:SetVolume(BGM.Volume)
        if BGM.Loop then snd:SetLooping(true) end
        snd:Play()
    end)
end

-- 启动战斗 BGM：随机风格 + 随机候选曲目（nation 参数优先于 BGM.Nation），替换旧曲目
function KARDS.PlayBattleBGM(nation)
    KARDS.StopBattleBGM() -- 立即停止旧曲/中断淡出（新对局直接覆盖）
    CurrentNation = nation or BGM.Nation
    CurrentStyle = BGM.Style or BGM.Styles[math.random(#BGM.Styles)]
    NextTrackTime = nil
    PlayTrack(CurrentStyle, CurrentNation)
end

-- 常驻调度（Think）：淡出推进 + 一首结束 Gap 秒后随机下一首（沿用当前风格/国家）
hook.Add("Think", "KardsBattleBGM", function()
    -- 淡出推进：音量线性降至 0，归零后停止
    if FadeOutEnd then
        local remain = FadeOutEnd - CurTime()
        local vol = BGM.Volume * math.max(remain / FadeOutDur, 0)
        if BattleBGMHandle then BattleBGMHandle:SetVolume(vol) end
        if remain <= 0 then KillHandle() end
        return
    end
    -- 自动切歌（Loop=false 自然结束后 GetState() ~= 1）
    if LoadingTrack or not BattleBGMHandle then return end
    if BattleBGMHandle:GetState() ~= 1 then
        if not NextTrackTime then
            NextTrackTime = CurTime() + BGM.Gap
        elseif CurTime() >= NextTrackTime then
            NextTrackTime = nil
            PlayTrack(CurrentStyle, CurrentNation)
        end
    end
end)

-- 接收：服务端 StartFormalBattle 仅向在场玩家发送；本桌校验兜底（观战者/其他牌桌
-- 收到异常消息时忽略，不播放）
net.Receive("KardsBattleBGM", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(2)
    if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    if not (KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent) then return end
    KARDS.PlayBattleBGM()
end)

-- 控制台命令 kards_table_bgm（2026-08-15 用户规格）：固定/切换 kards 与 wards 两风格。
-- 用法：kards_table_bgm          → 在当前固定风格间切换（未固定则固定为 kards）
--       kards_table_bgm <风格>   → 固定为指定风格（kards / wards）
-- 对局中有 BGM 在播则立即按新风格重播；未开对局则设置对下次对局生效。
-- 注意回调签名：GMOD concommand 回调为 (ply, cmd, args, argStr)，args 才是参数表；
-- 若写成 4 个占位符会误把 argStr（原始字符串）当参数表，args[1] 会取到字符串首字符
concommand.Add("kards_table_bgm", function(_, _, args)
    local arg = args and args[1]
    local newStyle
    if arg then
        arg = string.lower(arg)
        if arg ~= "kards" and arg ~= "wards" then
            print(("[Kards] kards_table_bgm：参数应为 kards 或 wards（当前 %s），无参数时在两者间切换"):format(BGM.Style or "自动随机"))
            return
        end
        newStyle = arg
    else
        newStyle = (BGM.Style == "kards") and "wards" or "kards"
    end
    BGM.Style = newStyle
    print(("[Kards] 战斗 BGM 风格固定为：%s（再输 kards_table_bgm 可切换）"):format(newStyle))
    -- 对局中当前有 BGM 在播 → 立即按新风格重播；无则对下次对局生效
    if BattleBGMHandle then KARDS.PlayBattleBGM() end
end)
