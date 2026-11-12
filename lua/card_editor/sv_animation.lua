-- Kards 卡牌编辑器动画系统 - 服务端
-- 处理编辑器动画的服务端同步逻辑

if SERVER then

    KARDS.CardEditor.Animation.Server = KARDS.CardEditor.Animation.Server or {}
    KARDS.CardEditor.Animation.Server.PlayerWeapons = KARDS.CardEditor.Animation.Server.PlayerWeapons or {}
    KARDS.CardEditor.Animation.Server.KeepAnimation = KARDS.CardEditor.Animation.Server.KeepAnimation or {}

    -- 开始编辑器动画
    function KARDS.CardEditor.Animation.Server:StartEditorAnim(ply)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        
        -- 保存所有武器和当前活动武器
        local weaponData = {}
        weaponData.weapons = {}
        local activeWep = ply:GetActiveWeapon()
        weaponData.activeClass = activeWep and activeWep:IsValid() and activeWep:GetClass() or nil
        
        for _, wep in ipairs(ply:GetWeapons()) do
            table.insert(weaponData.weapons, wep:GetClass())
        end
        self.PlayerWeapons[ply] = weaponData
        
        -- 去除所有武器，实现空手状态
        ply:StripWeapons()
        
        -- 设置动画状态和时间
        KARDS.CardEditor.Animation:SetPlayerState(ply, true)
        KARDS.CardEditor.Animation:SetAnimStartTime(ply, CurTime())
        
        -- 发送网络消息到所有客户端，包含开始时间
        net.Start(KARDS.CardEditor.Animation.Net.StartEditorAnim)
            net.WriteEntity(ply)
            net.WriteFloat(KARDS.CardEditor.Animation:GetAnimStartTime(ply))
        net.Broadcast()
        
        KARDS.CardEditor:Log("Started editor animation for player " .. ply:Name(), "INFO")
    end

    -- 停止编辑器动画
    function KARDS.CardEditor.Animation.Server:StopEditorAnim(ply)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        
        -- 恢复所有武器
        local weaponData = self.PlayerWeapons[ply]
        if weaponData then
            for _, wepClass in ipairs(weaponData.weapons) do
                ply:Give(wepClass)
            end
            if weaponData.activeClass then
                ply:SelectWeapon(weaponData.activeClass)
            end
            self.PlayerWeapons[ply] = nil
        end
        
        -- 清除动画状态
        KARDS.CardEditor.Animation:SetPlayerState(ply, false)
        KARDS.CardEditor.Animation:SetAnimStartTime(ply, 0)
        
        -- 发送网络消息到所有客户端
        net.Start(KARDS.CardEditor.Animation.Net.StopEditorAnim)
            net.WriteEntity(ply)
        net.Broadcast()
        
        KARDS.CardEditor:Log("Stopped editor animation for player " .. ply:Name(), "INFO")
    end

    -- 同步玩家动画状态
    function KARDS.CardEditor.Animation.Server:SyncAnimState(ply, targetPly)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        
        local isActive = KARDS.CardEditor.Animation:GetPlayerState(targetPly or ply)
        local startTime = KARDS.CardEditor.Animation:GetAnimStartTime(targetPly or ply)
        
        net.Start(KARDS.CardEditor.Animation.Net.SyncAnimState)
            net.WriteEntity(targetPly or ply)
            net.WriteBool(isActive)
            net.WriteFloat(startTime)
        net.Send(ply)
    end

    -- 控制台命令：开始编辑器动画
    concommand.Add("kards_start_editor_anim", function(ply)
        if IsValid(ply) and ply:IsPlayer() then
            KARDS.CardEditor.Animation.Server:StartEditorAnim(ply)
        end
    end)

    -- 控制台命令：停止编辑器动画
    concommand.Add("kards_stop_editor_anim", function(ply)
        if IsValid(ply) and ply:IsPlayer() then
            KARDS.CardEditor.Animation.Server:StopEditorAnim(ply)
        end
    end)

    -- 控制台命令：关闭编辑器但保持动画（用于测试）
    -- 上面两个启停命令由编辑器打开/关闭时自动调用（cl_canvas_editor.lua），属正常玩法流程，
    -- 故不加权限判定；本命令仅测试用，玩家执行需 operator 及以上，服务器控制台放行
    concommand.Add("kards_close_editor_keep_anim", function(ply)
        if not KARDS.CanUseDevCommand(ply) then
            print("[Kards] kards_close_editor_keep_anim：需要 operator 及以上权限")
            return
        end
        if IsValid(ply) and ply:IsPlayer() then
            KARDS.CardEditor.Animation.Server.KeepAnimation[ply] = true
            -- 发送消息给客户端关闭编辑器界面
            net.Start("KARDS_Editor_CloseKeepAnim")
            net.Send(ply)
            KARDS.CardEditor:Log("Player " .. ply:Name() .. " closed editor with animation kept", "INFO")
        end
    end)

    -- 玩家加入时同步所有当前在播放动画的玩家状态
    hook.Add("PlayerInitialSpawn", "KARDS_Editor_SyncAnimOnSpawn", function(ply)
        timer.Simple(1, function()
            if IsValid(ply) then
                for _, otherPly in ipairs(player.GetAll()) do
                    if otherPly ~= ply and KARDS.CardEditor.Animation:GetPlayerState(otherPly) then
                        KARDS.CardEditor.Animation.Server:SyncAnimState(ply, otherPly)
                    end
                end
            end
        end)
    end)

    -- 玩家断开时清理
    hook.Add("PlayerDisconnected", "KARDS_Editor_CleanAnimOnDisconnect", function(ply)
        if KARDS.CardEditor.Animation:GetPlayerState(ply) then
            KARDS.CardEditor.Animation.Server.PlayerWeapons[ply] = nil
        end
        KARDS.CardEditor.Animation.Server.KeepAnimation[ply] = nil
    end)
end
