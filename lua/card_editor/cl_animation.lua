-- Kards 卡牌编辑器动画系统 - 客户端
-- 使用 wOS Animation Extension 播放自定义动画序列
-- 需要 [wOS] Animation Extension – Base (ID: 757604550) 作为前置

if CLIENT then

    KARDS.CardEditor.Animation.Client = KARDS.CardEditor.Animation.Client or {}
    KARDS.CardEditor.Animation.Client.ActivePlayers = KARDS.CardEditor.Animation.Client.ActivePlayers or {}
    KARDS.CardEditor.Animation.Client.KeepAnimation = false
    KARDS.CardEditor.Animation.Client.LastGestureTime = KARDS.CardEditor.Animation.Client.LastGestureTime or {}
    KARDS.CardEditor.Animation.Client.SequenceName = "editor_idle"

    -- 检测 wOS 是否安装
    KARDS.CardEditor.Animation.Client.WosMounted = wOS and wOS.AnimExtension and wOS.AnimExtension.Mounted and wOS.AnimExtension.Mounted["Base"]
    KARDS.CardEditor.Animation.Client.UseSimpleAnim = not KARDS.CardEditor.Animation.Client.WosMounted  -- 无 wOS 时回退到手势模式

    if KARDS.CardEditor.Animation.Client.WosMounted then
        print("[Kards] wOS Animation Extension detected, using MDL sequences")
    else
        print("[Kards] wOS Animation Extension not found, using gesture fallback")
    end

    --[[
        播放编辑器动画
    ]]
    function KARDS.CardEditor.Animation.Client:PlayEditorAnim(ply, startTime)
        if not IsValid(ply) then return end
        self.ActivePlayers[ply] = true
        KARDS.CardEditor.Animation:SetPlayerState(ply, true)
        KARDS.CardEditor.Animation:SetAnimStartTime(ply, startTime or CurTime())

        ply:Freeze(true)
        ply:SetPlaybackRate(0)
        ply:SetCycle(0)

        -- 重置姿态参数
        ply:SetPoseParameter("move_x", 0)
        ply:SetPoseParameter("move_y", 0)
        ply:SetPoseParameter("move_yaw", 0)
        ply:SetPoseParameter("aim_yaw", 0)
        ply:SetPoseParameter("aim_pitch", 0)
        ply:SetPoseParameter("body_yaw", 0)
        ply:SetPoseParameter("body_pitch", 0)

        -- 重置所有手势槽
        if GESTURE_SLOT_ATTACK_AND_RELOAD then ply:AnimResetGestureSlot(GESTURE_SLOT_ATTACK_AND_RELOAD) end
        if GESTURE_SLOT_JUMP then ply:AnimResetGestureSlot(GESTURE_SLOT_JUMP) end
        if GESTURE_SLOT_CUSTOM then ply:AnimResetGestureSlot(GESTURE_SLOT_CUSTOM) end
        if GESTURE_SLOT_FLINCH then ply:AnimResetGestureSlot(GESTURE_SLOT_FLINCH) end

        if self.UseSimpleAnim then
            print("[Kards] Anim started (gesture mode)")
        else
            print("[Kards] Anim started (wOS mode)")
        end
    end

    --[[
        停止编辑器动画
    ]]
    function KARDS.CardEditor.Animation.Client:StopEditorAnim(ply)
        if not IsValid(ply) then return end
        self.ActivePlayers[ply] = nil
        KARDS.CardEditor.Animation:SetPlayerState(ply, false)

        ply:Freeze(false)
        ply:SetPlaybackRate(1)
        ply:AnimRestartMainSequence()
    end

    --[[
        CalcMainActivity：覆盖玩家的动画序列
        仅在 wOS 安装时生效
        返回 -1 表示直接使用序列索引
    ]]
    hook.Add("CalcMainActivity", "KARDS_Editor_CalcActivity", function(ply, vel)
        local self = KARDS.CardEditor.Animation.Client
        if self.UseSimpleAnim then return end       -- 手势模式不干预
        if not self.ActivePlayers[ply] then return end  -- 非动画玩家不干预

        local seqID = ply:LookupSequence(self.SequenceName)
        if seqID and seqID > -1 then
            return -1, seqID
        end
    end)

    --[[
        Think 循环：简单模式手势更新
    ]]
    hook.Add("Think", "KARDS_Editor_AnimThink", function()
        local self = KARDS.CardEditor.Animation.Client
        if not self.UseSimpleAnim then return end  -- wOS 模式不处理手势

        for ply, _ in pairs(self.ActivePlayers) do
            if IsValid(ply) then
                local last = self.LastGestureTime[ply] or 0
                if CurTime() - last > 2 then
                    ply:AnimResetGestureSlot(GESTURE_SLOT_CUSTOM)
                    ply:AnimRestartGesture(GESTURE_SLOT_CUSTOM, ACT_GMOD_GESTURE_BOW, true)
                    self.LastGestureTime[ply] = CurTime()
                end
            else
                self.ActivePlayers[ply] = nil
                self.LastGestureTime[ply] = nil
            end
        end
    end)

    -- 网络消息处理
    net.Receive(KARDS.CardEditor.Animation.Net.StartEditorAnim, function()
        local ply = net.ReadEntity()
        local startTime = net.ReadFloat()
        if IsValid(ply) then KARDS.CardEditor.Animation.Client:PlayEditorAnim(ply, startTime) end
    end)

    net.Receive(KARDS.CardEditor.Animation.Net.StopEditorAnim, function()
        local ply = net.ReadEntity()
        if IsValid(ply) then KARDS.CardEditor.Animation.Client:StopEditorAnim(ply) end
    end)

    net.Receive(KARDS.CardEditor.Animation.Net.SyncAnimState, function()
        local ply = net.ReadEntity()
        local isActive = net.ReadBool()
        local startTime = net.ReadFloat()
        if IsValid(ply) then
            if isActive then KARDS.CardEditor.Animation.Client:PlayEditorAnim(ply, startTime)
            else KARDS.CardEditor.Animation.Client:StopEditorAnim(ply) end
        end
    end)

    net.Receive("KARDS_Editor_CloseKeepAnim", function()
        KARDS.CardEditor.Animation.Client.KeepAnimation = true
        if KARDS.CardEditor.Canvas and KARDS.CardEditor.Canvas.CloseEditor then
            KARDS.CardEditor.Canvas.CloseEditor()
        end
    end)

    -- 诊断命令
    concommand.Add("kards_anim_diag", function()
        local ply = LocalPlayer()
        print("========== Kards Animation Diagnostic ==========")
        print("LocalPlayer valid:", IsValid(ply))
        print("wOS Mounted:", tostring(KARDS.CardEditor.Animation.Client.WosMounted))
        if IsValid(ply) then
            print("Current model:", ply:GetModel())
            local seqID = ply:LookupSequence(KARDS.CardEditor.Animation.Client.SequenceName)
            print("LookupSequence(editor_idle):", seqID)
        end
        print("================================================")
    end)

    print("[Kards] Client animation system loaded (wOS-based)")
end
