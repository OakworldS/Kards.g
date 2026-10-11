--[[
    Kards 战斗牌桌客户端模块：牌桌音效（cl_battle_sound.lua，2026-08-15 C1 拆分）

    自 cl_init.lua（lua/entities/sent_kards_battle_table/cl_init.lua）音效段迁移：
      - KARDS.PlayKardsSound：重新调度/对局音效（sound/kards/，surface.PlaySound
        相对路径不带 sound/ 前缀但必须带扩展名；文件名用英文——sound.PlayFile 不支持
        非 ASCII 文件名，未接入的音效保持中文文件名以分辨哪些用了哪些没用）
      - KARDS.PlayAimSound / KARDS.StopAimSound：指向音效管理（aim.ogg，
        sound.PlayFile 的 SoundHandle 控制，播放中判定 GetState()==1）
      - KardsStatChangeSound net 接收：属性变化音效（stat_change.ogg）
      - KARDS.PlaySoundPath：播放任意完整相对路径音效（sound/… 或 data/…）
      - KardsEventSound net 接收：卡牌事件音效（参战者 2D / 观战者 3D）

    挂载：cl_init.lua include 本文件（savedBGMPlayMode 声明之后、KardsFieldDeath 段
    之前）。约定：常驻钩子/函数挂 KARDS 命名空间；文件级 local（AimHandle）自含。
]]

-- 重新调度/对局音效（sound/kards/，2026-08-10）：surface.PlaySound 相对路径不带
-- sound/ 前缀但必须带扩展名（缺 .ogg 会报 Failed to load sound）；文件名用英文
-- （sound.PlayFile 不支持非 ASCII 文件名，见 cl_dynamic_bgm_compat.lua），未接入的
-- 音效保持中文文件名以分辨哪些用了哪些没用
function KARDS.PlayKardsSound(name)
    surface.PlaySound("kards/" .. name .. ".ogg")
end

-- 指向音效管理（2026-08-13 用户规格）：指令指向（拖拽指向模式）与单位指向（点选
-- 战场单位操作）统一走本方法——指向开始时播放 aim.ogg，指向结束（松手/失活/选中
-- 单位移除）若音效未播完立即停止。surface.PlaySound 无法中途停止，改用
-- sound.PlayFile 的 SoundHandle 控制（2D 全屏，与 surface.PlaySound 同一听感）。
-- 播放中判定用 GetState()==1（BASS_ACTIVE_PLAYING）：IGModAudioChannel 无 IsPlaying
-- 方法（GMod wiki 方法集），此前 IsPlaying 调用报 nil value
local AimHandle = nil
function KARDS.PlayAimSound()
    if AimHandle and AimHandle:GetState() == 1 then return end -- 已在播放不重复触发
    -- sound.PlayFile 须带回调（异步加载完成/失败后调用；"noplay" 加载后不自动播放，
    -- 回调内手动 Play，避免加载中连续调用重复触发——同 cl_audio_manager.lua 用法）
    sound.PlayFile("sound/kards/aim.ogg", "noplay", function(snd)
        if snd then
            AimHandle = snd
            snd:Play()
        end
    end)
end
function KARDS.StopAimSound()
    if AimHandle then
        if AimHandle:GetState() == 1 then AimHandle:Stop() end
        AimHandle = nil
    end
end

-- 属性变化音效接收（2026-08-13：stat_change.ogg 播放时机收窄）：服务端数据层来源
-- 命中（属性与伤害节点攻击/防御分支 + 山地/动员词条，见 sh_battle_combat.lua
-- NotifyStatSound）→ BroadcastStatChangeSound 广播 → 此处播放 stat_change.ogg。
-- 其余属性变更（战斗伤害、HQ 防御、SimRepair 等）不再触发（客户端 cl_card_text_overlay.lua
-- UpdateStatFX 的通用 diff 播放已移除，仅剩本事件驱动）。
net.Receive("KardsStatChangeSound", function()
    local ent = net.ReadEntity()
    if IsValid(ent) and KARDS.PlayKardsSound then
        KARDS.PlayKardsSound("stat_change")
    end
end)

-- 播放任意完整相对路径音效（sound/… 或 data/…，garrysmod 根为基准）：
-- sound.PlayFile 异步回调驱动，2D 全屏
function KARDS.PlaySoundPath(path)
    if not path or path == "" then return end
    sound.PlayFile(path, "noplay", function(channel)
        if IsValid(channel) then channel:SetVolume(1) channel:Play() end
    end)
end

-- 事件音效接收（2026-08-13：卡牌事件音效，编辑器属性页 sounds 字段）。参战者
-- （KARDS.BattleState.inTable 为本桌）2D 全屏播放，与 draw/aim 一致；观战者 3D
-- 方位播放——sound.Play(相对 sound/ 的路径, 音源位置, 音量等级)，音源位置取事件源
-- 实体 WorldCenter（反制触发无实体 → 回退牌桌）。仅 sound/ 内容支持 3D
-- （sound.PlayFile 通道无位置控制，BASS 限制），data/kards_sounds 自定义音效回退 2D。
net.Receive("KardsEventSound", function()
    local tbl = net.ReadEntity()
    local ent = net.ReadEntity()
    local path = net.ReadString()
    local isParticipant = IsValid(tbl) and KARDS.BattleState.inTable
        and KARDS.BattleState.inTable.ent == tbl
    if isParticipant or path:sub(1, 6) ~= "sound/" then
        KARDS.PlaySoundPath(path) -- 参战者 2D / data 文件 2D 回退
        return
    end
    local pos = nil
    if IsValid(ent) then pos = ent:WorldCenter() end
    if not pos and IsValid(tbl) then pos = tbl:WorldCenter() end
    if not pos then KARDS.PlaySoundPath(path) return end
    sound.Play(path:sub(7), pos, 75, 100, 1) -- 观战者 3D：剥掉 sound/ 前缀（sound.Play 相对 sound/ 目录）
end)
