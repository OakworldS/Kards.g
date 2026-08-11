-- Kards 卡牌编辑器动画系统
-- 共享文件，处理编辑器动画相关的共享逻辑

KARDS.CardEditor.Animation = KARDS.CardEditor.Animation or {}
KARDS.CardEditor.Animation.Config = {
    AnimationPath = "models/kards/editor/editor_anim.mdl",
    AnimationDuration = 2.0,
    AnimationFPS = 25,
    GestureSlot = GESTURE_SLOT_CUSTOM,
    LoopAnimation = true,
    SequenceName = "editor_idle"
}

-- 网络消息名称
KARDS.CardEditor.Animation.Net = {
    StartEditorAnim = "KARDS_Editor_StartAnim",
    StopEditorAnim = "KARDS_Editor_StopAnim",
    SyncAnimState = "KARDS_Editor_SyncAnim"
}

-- 玩家动画状态存储
KARDS.CardEditor.Animation.PlayerState = KARDS.CardEditor.Animation.PlayerState or {}
KARDS.CardEditor.Animation.AnimStartTime = KARDS.CardEditor.Animation.AnimStartTime or {}

-- 获取玩家动画状态
function KARDS.CardEditor.Animation:GetPlayerState(ply)
    if SERVER then
        return ply:GetNWBool("KARDS_Editor_AnimActive", false)
    else
        return KARDS.CardEditor.Animation.PlayerState[ply] or false
    end
end

-- 设置玩家动画状态
function KARDS.CardEditor.Animation:SetPlayerState(ply, active)
    if SERVER then
        ply:SetNWBool("KARDS_Editor_AnimActive", active)
    else
        KARDS.CardEditor.Animation.PlayerState[ply] = active
    end
end

-- 设置动画开始时间
function KARDS.CardEditor.Animation:SetAnimStartTime(ply, time)
    KARDS.CardEditor.Animation.AnimStartTime[ply] = time
end

-- 获取动画开始时间
function KARDS.CardEditor.Animation:GetAnimStartTime(ply)
    return KARDS.CardEditor.Animation.AnimStartTime[ply] or 0
end
