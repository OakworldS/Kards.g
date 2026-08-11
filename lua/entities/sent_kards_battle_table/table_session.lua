-- Kards 战斗牌桌实体服务端代码：玩家会话段（re.md T-H1 拆分，由 init.lua include）
-- 职责：玩家进入/退出/准备/对战开始 + 玩家会话状态机（T-M2）。
-- 文件头取实体表（shared.lua 已 include 注册），方法定义挂到同一 ENT 表。

local ENT = scripted_ents.GetStored("sent_kards_battle_table").t

-- ====================================================================
-- 玩家会话状态机（re.md T-M2）：
-- 集中管理「进入冻结 / 退出恢复」的状态保存与恢复
-- （移动类型 / 无敌 / 武器 / 视角 / 煤油灯 / 卡组槽），此前分散在
-- TryEnterSlot / ExitSlot / OnRemove / PlayerDisconnected 四处、靠幂等约定保证安全；
-- 现收敛为单一对象：Enter / Exit / ForceExitAll 三个入口，销毁与断线只调统一退出，
-- 新增中间态不会漏恢复。
-- 挂载：KARDS.TableSession（共享命名空间，init.lua Initialize 调用 New 挂实体）。
-- ====================================================================
KARDS = KARDS or {}
local TableSession = {}
TableSession.__index = TableSession
KARDS.TableSession = TableSession

-- 创建会话状态机（每牌桌一个；Initialize 时挂 self._kardsSession）
-- @param tableEnt Entity 牌桌实体
function TableSession.New(tableEnt)
    return setmetatable({ ent = tableEnt }, TableSession)
end

--[[
    玩家进入会话：保存进入前状态并冻结（移至槽位中心 + MOVETYPE_NONE + 无敌 + 空武器）。
    槽位分配与合法性校验由调用方（TryEnterSlot）完成。

    @param ply  Player 进入玩家
    @param slot number 槽位编号
]]
function TableSession:Enter(ply, slot)
    -- 保存进入前状态（退出 / 牌桌销毁 / 玩家断开时恢复或释放）
    ply._kardsTable = {
        ent = self.ent,
        slot = slot,
        ready = false,       -- 准备标记（按 F4 置位；对局衔接见规划 16.6 #4）
        pos = ply:GetPos(),  -- 进入前位置（退出时恢复）
        ang = ply:EyeAngles(), -- 进入前视角（退出时恢复）
        god = ply:HasGodMode(), -- 进入前是否已无敌（退出时按原状恢复）
        weapons = {},        -- 武器 class 列表（退出时归还）
        activeClass = nil,   -- 当前激活武器 class（退出时重新选中）
    }
    for _, wep in ipairs(ply:GetWeapons()) do
        table.insert(ply._kardsTable.weapons, wep:GetClass())
    end
    local active = ply:GetActiveWeapon()
    ply._kardsTable.activeClass = IsValid(active) and active:GetClass() or nil

    -- 玩家模型移至槽位中心并面向牌桌（保持脚底高度 cur.z，避免悬浮/陷入桌面）
    local slotPos = self.ent:GetSlotWorldPos(slot)
    local cur = ply:GetPos()
    ply:SetPos(Vector(slotPos.x, slotPos.y, cur.z))
    local face = (self.ent:GetPos() - ply:GetPos()):Angle()
    ply:SetEyeAngles(face)
    ply:SetAngles(Angle(0, face.yaw, 0))

    -- 冻结移动（力的相互作用对玩家不生效）+ 无敌 + 空武器
    -- 移动类型 MOVETYPE_NONE：玩家不受物理力驱动（不可被推动/击退/抛起），
    -- 碰撞组 COLLISION_GROUP_PLAYER：玩家仍与其他实体正常碰撞，
    -- 其他实体之间的物理相互作用不受影响（仅本玩家自身物理行为被冻结）
    ply:SetMoveType(MOVETYPE_NONE)
    ply:SetLocalVelocity(Vector(0, 0, 0))
    ply:SetCollisionGroup(COLLISION_GROUP_PLAYER)
    ply:GodEnable()
    ply:StripWeapons()

    -- 有玩家在玩家槽：牌桌上方点亮煤油灯（无玩家时 UpdateTableLight 会移除）
    self.ent:UpdateTableLight()
end

--[[
    玩家退出会话：恢复进入前状态并释放槽位（幂等：已退出 / 不在本牌桌时返回 false）。
    恢复：释放槽位、解冻移动、解除无敌（进入前无敌则保持）、归还武器并重新选中
    进入前的激活武器、恢复进入前位置与视角，并清理该槽卡组槽（battle 模式）。
    广播（KardsTableExited）由 opts.broadcast 控制：正常退出（ExitSlot）与牌桌销毁
    （ForceExitAll）广播；玩家断开（PlayerDisconnected）不广播（玩家已离开）。

    @param ply  Player
    @param opts table|nil { broadcast = boolean } 是否向该玩家广播退出消息
    @return boolean 是否真的退出（false = 未在会话中）
]]
function TableSession:Exit(ply, opts)
    if not IsValid(ply) or not ply:IsPlayer() then return false end
    local data = ply._kardsTable
    if not data or data.ent ~= self.ent then return false end
    -- 释放槽位
    local slot = data.slot
    if self.ent.Slots and self.ent.Slots[slot] == ply then
        self.ent.Slots[slot] = nil
    end
    ply._kardsTable = nil

    -- 恢复移动（MOVETYPE_WALK 行走 + COLLISION_GROUP_PLAYER 默认玩家碰撞组）+ 解除无敌（进入前无敌则保持）+ 归还武器
    ply:SetMoveType(MOVETYPE_WALK)
    ply:SetLocalVelocity(Vector(0, 0, 0))
    ply:SetCollisionGroup(COLLISION_GROUP_PLAYER)
    if not data.god then
        ply:GodDisable()
    end
    for _, cls in ipairs(data.weapons) do
        ply:Give(cls)
    end
    if data.activeClass then
        ply:SelectWeapon(data.activeClass)
    end

    -- 恢复进入前位置与视角
    ply:SetPos(data.pos)
    ply:SetEyeAngles(data.ang)

    -- 无玩家在槽位：牌桌上方煤油灯熄灭（UpdateTableLight 内判断移除）
    self.ent:UpdateTableLight()

    -- 清理卡组槽（battle 模式）：移除该槽卡堆档位实体、总部实体与抽牌临时卡实体
    if self.ent._kardsBattleDecks and self.ent._kardsBattleDecks[slot] then
        local bd = self.ent._kardsBattleDecks[slot]
        for _, e in pairs(bd.pileEnts or {}) do
            if IsValid(e) then e:Remove() end
        end
        if IsValid(bd.hqEnt) then bd.hqEnt:Remove() end
        for _, e in ipairs(bd.drawEnts or {}) do
            if IsValid(e) then e:Remove() end
        end
        self.ent._kardsBattleDecks[slot] = nil
    end

    -- 广播退出（客户端恢复 HUD / 摄像头）
    if opts and opts.broadcast then
        net.Start("KardsTableExited")
            net.WriteEntity(self.ent)
            net.WriteUInt(slot, 8)
        net.Send(ply)
    end
    return true
end

--[[
    强制退出全部槽位玩家（牌桌销毁 OnRemove 兜底；幂等）。
    每位玩家按 broadcast=true 退出（客户端恢复 HUD / 摄像头）。
]]
function TableSession:ForceExitAll()
    for slot, ply in pairs(self.ent.Slots or {}) do
        if IsValid(ply) and ply:IsPlayer() then
            self:Exit(ply, { broadcast = true })
        end
    end
end

-- ====================================================================
-- net 消息注册（SERVER 段，一次性）：
-- 进入/退出/准备请求 → 会话状态机；断开 → 统一退出
-- ====================================================================
if SERVER then
    net.Receive("KardsTableEnter", function(_, ply)
        local ent = net.ReadEntity()
        if IsValid(ent) and ent:GetClass() == "sent_kards_battle_table" then
            ent:TryEnterSlot(ply)
        end
    end)

    net.Receive("KardsTableExit", function(_, ply)
        local ent = net.ReadEntity()
        if IsValid(ent) then
            ent:ExitSlot(ply)
        end
    end)

    net.Receive("KardsTableReady", function(_, ply)
        local ent = net.ReadEntity()
        if IsValid(ent) then
            -- F4 切换准备：再次按 F4 取消准备（取反当前 ready 状态）
            local data = ply._kardsTable
            if data and data.ent == ent then
                ent:SetReady(ply, not data.ready)
            end
        end
    end)

    -- 结束回合请求（客户端 HUD「结束回合」按钮点击，仅当前回合方可发起）：
    -- 服务端权威校验（牌桌内 / 对战已开始 / 当前回合方）→ 切换到对方回合并广播
    net.Receive("KardsEndTurn", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        if not ent._kardsFormalBattleStarted then return end -- 对战尚未开始
        if not ent._kardsFirstTurnStarted then return end -- 先手回合未开始（双方重新调度未完成，防抢先推进）
        if ent._kardsTurnSlot ~= data.slot then return end -- 非当前回合方
        ent:EndTurn()
    end)

    -- 玩家断开：会话状态机统一退出（释放槽位 + 清理卡组槽；玩家已离开，
    -- 不广播——原逻辑同样不广播，恢复操作对离场玩家无害）
    hook.Add("PlayerDisconnected", "KardsTableSlotCleanup", function(ply)
        local data = ply._kardsTable
        if data and IsValid(data.ent) then
            local ent = data.ent
            if ent._kardsSession then
                ent._kardsSession:Exit(ply)
            else
                -- 兜底（状态机缺失的异常场景）：直接释放槽位
                for slot, p in pairs(ent.Slots or {}) do
                    if p == ply then ent.Slots[slot] = nil end
                end
                ply._kardsTable = nil
            end
            -- 一方离开：取消双方就绪后挂起的开始倒计时（条件不再满足）
            ent:CancelBattleStartCountdown()
        end
    end)

    -- 强制开始对战（单人快速测试）：执行玩家须已进入某牌桌，直接跳过双方就绪
    -- 与 3 秒倒计时（StartFormalBattle(forced=true)），服务端权威校验在牌桌内。
    concommand.Add("kards_forcestart", function(ply, cmd, args)
        if not IsValid(ply) or not ply:IsPlayer() then
            print("[Kards] kards_forcestart 仅限玩家在牌桌内执行")
            return
        end
        local data = ply._kardsTable
        if not data or not IsValid(data.ent) then
            net.Start("KardsTableMsg")
                net.WriteString("未在牌桌内，无法强制开始对战")
            net.Send(ply)
            return
        end
        data.ent:StartFormalBattle(true)
    end)
end

--[[
    玩家尝试进入牌桌（客户端按 E 请求，经 net.Receive "KardsTableEnter" 触发）

    校验：玩家在本桌某槽位范围内（共享判定 GetPlayerSlot）、目标槽位未被占用、
    玩家未在其他牌桌。成功后：槽位分配 + 会话状态机进入（冻结移动/无敌/空武器/
    移至槽位/煤油灯），对战模式加载卡组到卡组槽，并广播进入成功
    （客户端据此完全接管 HUD 与摄像头）。

    @param ply Player
    @return boolean 是否进入成功
]]
-- 当前牌桌内玩家数（有效槽位中的玩家数）：匹配音效循环播放条件的数据源，
-- 经 KardsTableEntered 附带值（进入者）与 KardsTablePlayerCount 广播（所有玩家）下发
function ENT:GetPlayerCount()
    local n = 0
    for _, p in pairs(self.Slots or {}) do
        if IsValid(p) and p:IsPlayer() then n = n + 1 end
    end
    return n
end

function ENT:TryEnterSlot(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return false end
    -- 已在牌桌中（本桌或其他桌），拒绝重复进入
    if ply._kardsTable then return false end
    -- 槽位判定：玩家必须处于本桌某槽位范围内
    local slot = self:GetPlayerSlot(ply)
    if not slot then return false end
    -- 组卡模式：仅 P2（槽位 2）可进入牌桌（组卡构建由 P2 进行）
    if self.Mode == "deck" and slot ~= 2 then
        net.Start("KardsTableMsg")
            net.WriteString("组卡模式仅 P2 可进入牌桌")
        net.Send(ply)
        return false
    end
    -- 占用检测：目标槽位已被其他玩家占用则拒绝并提示
    if IsValid(self.Slots[slot]) then
        net.Start("KardsTableMsg")
            net.WriteString("该槽位已被占用")
        net.Send(ply)
        return false
    end
    -- 分配槽位 + 会话状态机进入（保存进入前状态 + 冻结 + 移至槽位 + 煤油灯）
    self.Slots[slot] = ply
    self._kardsSession:Enter(ply, slot)

    -- 对战模式：为该玩家加载卡组到卡组槽（数据层 SimSetupDeck + 视觉卡背堆叠 + 总部）
    if self.Mode ~= "deck" then
        self:LoadPlayerBattleDeck(ply, slot)
    end

    -- 广播进入成功（客户端据此接管 HUD / 摄像头）；附带当前牌桌玩家数（含本次
    -- 进入者）：进入者据此决定是否循环播放匹配音效，见 cl_init.lua UpdateMatchSound
    local count = self:GetPlayerCount()
    net.Start("KardsTableEntered")
        net.WriteEntity(self)
        net.WriteUInt(slot, 8)
        net.WriteUInt(count, 8)
    net.Send(ply)
    -- 玩家数变化广播（所有玩家）：其他客户端（已在牌桌内的玩家）据此停止匹配音效
    --（第二位玩家加入 → 牌桌满），进入者自身经 KardsTableEntered 已按 count 处理
    net.Start("KardsTablePlayerCount")
        net.WriteEntity(self)
        net.WriteUInt(count, 8)
    net.Broadcast()
    return true
end

--[[
    玩家退出牌桌（再次 kards_enter 指令请求，经 net.Receive "KardsTableExit" 触发；
    牌桌销毁 / EntityRemoved 兜底经会话状态机 ForceExitAll / Exit 复用本恢复逻辑）。
    幂等：会话状态机 Exit 已清空 ply._kardsTable 时直接返回。

    @param ply Player
]]
function ENT:ExitSlot(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not self._kardsSession:Exit(ply, { broadcast = true }) then return end
    -- 玩家退出：取消双方就绪后挂起的开始倒计时（条件不再满足）
    self:CancelBattleStartCountdown()
    -- 无玩家在槽位：重置对战开始标记（牌桌恢复初始态，重新进入可再次就绪/强制开始）
    local hasAny = false
    for _, p in pairs(self.Slots or {}) do
        if IsValid(p) then
            hasAny = true
            break
        end
    end
    if not hasAny then
        self._kardsFormalBattleStarted = false
    end
    -- 玩家数变化广播（所有玩家）：另一玩家退出后牌桌可能恢复未满状态，仍在牌桌
    -- 内的玩家据此恢复循环播放匹配音效（对战已开始则客户端按 NW 条件不恢复，
    -- 见 cl_init.lua UpdateMatchSound）
    net.Start("KardsTablePlayerCount")
        net.WriteEntity(self)
        net.WriteUInt(self:GetPlayerCount(), 8)
    net.Broadcast()
end

--[[
    根据槽位占用更新牌桌上方灯具（gmod_light 全向点光，煤油灯色暖橙黄）：
    有玩家在玩家槽（已进入牌桌）→ 确保灯具存在；无玩家 → 移除灯具。
    在会话状态机 Enter / Exit 末尾调用。
]]
function ENT:UpdateTableLight()
    local hasPlayer = false
    for _, p in pairs(self.Slots or {}) do
        if IsValid(p) then
            hasPlayer = true
            break
        end
    end
    local light = self._kardsLight
    if hasPlayer then
        if not IsValid(light) then
            -- 创建 gmod_light 灯具（GMod Q 菜单「工具 > 灯具」实际生成的实体）：
            -- 全向点光、无模型（空灯具），煤油灯色（暖橙黄），牌桌正上方。
            -- 实测 light_dynamic 运行时创建渲染不可靠，改用灯工具同款 gmod_light。
            local top = self:LocalToWorld(Vector(0, 0, 80)) -- fallback：牌桌正上方
            local phys = self:GetPhysicsObject()
            if IsValid(phys) then
                -- 实测：phys:GetAABB() 返回局部坐标（相对实体原点），须经 LocalToWorld 转世界坐标
                local mins, maxs = phys:GetAABB()
                top = self:LocalToWorld(Vector((mins.x + maxs.x) / 2, (mins.y + maxs.y) / 2, maxs.z + 60)) -- 桌面顶上方 60 单位
            end
            light = ents.Create("gmod_light")
            if IsValid(light) then
                light:SetPos(top)
                light:SetColor(Color(255, 185, 90, 255)) -- 煤油灯色（暖橙黄）
                light:SetBrightness(2)                   -- 亮度（工具范围 -6~6，默认 2；减半自 4）
                light:SetLightSize(400)                  -- 光照半径（覆盖牌桌 90x45）
                light:SetToggle(false)
                light:SetOn(true)
                light:Spawn()
                -- 空灯具：隐藏模型（仅光照）+ 冻结（不因重力落下/不碰撞）
                light:SetNoDraw(true)
                light:SetSolid(SOLID_NONE)
                light:SetMoveType(MOVETYPE_NONE)
                local lphys = light:GetPhysicsObject()
                if IsValid(lphys) then lphys:EnableMotion(false) end
                self._kardsLight = light
            end
        end
    else
        if IsValid(light) then
            light:Remove()
            self._kardsLight = nil
        end
    end
end

--[[
    玩家按 F4 切换准备状态（经 net.Receive "KardsTableReady" 触发，
    处理器取反当前 ready 后调用：再次按 F4 取消准备）

    仅标记 ply._kardsTable.ready 并回执客户端显示「已准备 / 取消准备」；
    标记后检查双方是否均已就绪（CheckBattleStart）——若两槽均有玩家且均准备，
    自动进入 3 秒倒计时后开始对战；任一条件不满足则取消挂起的倒计时。

    @param ply Player
    @param ready boolean 目标准备状态
]]
function ENT:SetReady(ply, ready)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local data = ply._kardsTable
    if not data or data.ent ~= self then return end
    if self._kardsFormalBattleStarted then return end -- 对战已开始：忽略准备切换
    data.ready = ready
    net.Start("KardsTableReadyAck")
        net.WriteEntity(self)
        net.WriteUInt(data.slot, 8)
        net.WriteBool(ready)
    net.Send(ply)
    self:CheckBattleStart()
end

--[[
    检查双方是否均已就绪，决定开始对战倒计时的启动/取消：
      两槽位均有玩家且双方 _kardsTable.ready 均为 true → 启动 3 秒倒计时
      （幂等：已挂起时不重复启动），随后 StartFormalBattle 正式开始；
      任一条件不满足 → 取消已挂起的倒计时（一方取消准备 / 退出即中断）。
    倒计时用自增 token 标记：取消只需置 nil，过期的 timer 回调比对 token 不符即中止。
]]
function ENT:CheckBattleStart()
    if self._kardsFormalBattleStarted then return end
    local p1, p2 = self.Slots[1], self.Slots[2]
    local bothReady = IsValid(p1) and IsValid(p2)
        and p1._kardsTable and p1._kardsTable.ent == self and p1._kardsTable.ready
        and p2._kardsTable and p2._kardsTable.ent == self and p2._kardsTable.ready
    if not bothReady then
        self:CancelBattleStartCountdown()
        return
    end
    if self._kardsStartCountdownToken then return end -- 已在倒计时
    local token = (self._kardsStartCountdownToken or 0) + 1
    self._kardsStartCountdownToken = token
    -- 提示双方：进入 3 秒等待（闪屏消息，见客户端 Flash）
    net.Start("KardsTableMsg")
        net.WriteString("双方已就绪，3 秒后开始对战")
    net.Send({ p1, p2 })
    timer.Simple(3, function()
        if not IsValid(self) then return end
        if self._kardsStartCountdownToken ~= token then return end -- 已取消
        self._kardsStartCountdownToken = nil
        self:StartFormalBattle(false)
    end)
end

-- 取消挂起的开始倒计时（token 置 nil，过期 timer 回调因 token 不符而中止）
function ENT:CancelBattleStartCountdown()
    self._kardsStartCountdownToken = nil
end

--[[
    对战正式开始（服务端权威）：幂等（每桌仅一次）。
    向每个槽内玩家发送 KardsTableBattleStart（附带随机先手槽位 + 该玩家的敌方信息，
    供客户端摄像头动画结束后的先手揭晓动画使用，见 cl_init.lua KardsFirstTurnReveal*），
    客户端据此隐藏 HUD 并播放摄像头过渡动画（起始：牌桌右侧外部 + 旋转；2 秒渐变到
    组卡模式相机）。

    @param forced boolean 是否强制开始（kards_forcestart 单人快速测试：
            跳过双方就绪与 3 秒倒计时，直接开始）
]]
function ENT:StartFormalBattle(forced)
    if self._kardsFormalBattleStarted then return end
    self._kardsFormalBattleStarted = true
    -- NW 同步对战已开始：客户端进入牌桌时据此决定本地视角（已开始 → 槽位视角
    -- P1/P2；未开始 → 观察者视角 nil），见 cl_init.lua KardsTableEntered
    self:SetNWBool("Kards_FormalBattleStarted", true)
    self:CancelBattleStartCountdown()
    -- 随机先手槽位（先手揭晓动画用）：仅一人在场时该玩家自动先手，两人均在场时
    -- 1/2 随机（同一数值随消息下发给双方，保证两端展示一致）
    local has1 = IsValid(self.Slots[1]) and self.Slots[1]:IsPlayer()
    local has2 = IsValid(self.Slots[2]) and self.Slots[2]:IsPlayer()
    local firstSlot
    if has1 and not has2 then
        firstSlot = 1
    elseif not has1 and has2 then
        firstSlot = 2
    else
        firstSlot = math.random(2)
    end
    self._kardsFirstTurnSlot = firstSlot
    -- 逐个槽内玩家发送：先手槽位 + 该玩家的敌方信息（客户端揭晓动画需展示对方头像/名称）
    for slot, p in pairs(self.Slots or {}) do
        if IsValid(p) and p:IsPlayer() then
            local enemySlot = (slot == 1) and 2 or 1
            local enemy = self.Slots[enemySlot]
            local hasEnemy = IsValid(enemy) and enemy:IsPlayer()
            net.Start("KardsTableBattleStart")
                net.WriteEntity(self)
                net.WriteUInt(firstSlot, 8)
                net.WriteBool(hasEnemy)
                if hasEnemy then
                    net.WriteString(enemy:Nick())
                    net.WriteString(enemy:SteamID64())
                end
            net.Send(p)
        end
    end
    -- 广播给观战者（未进入本牌桌的玩家，含在其他牌桌的玩家）：无 reveal 序列，
    -- 客户端收到后本地触发总部对局开始动画（见 cl_init.lua KardsTableBattleStart 观战分支）
    local inSlot = {}
    for _, p in pairs(self.Slots or {}) do
        if IsValid(p) and p:IsPlayer() then inSlot[p] = true end
    end
    for _, p in ipairs(player.GetAll()) do
        if not inSlot[p] then
            net.Start("KardsTableBattleStart")
                net.WriteEntity(self)
                net.WriteUInt(firstSlot, 8)
                net.WriteBool(false) -- 观战者无敌方信息（仅用牌桌实体触发总部动画）
            net.Send(p)
        end
    end
    print(("[Kards] 对战开始（牌桌 %s%s）"):format(self.TableID, forced and " [强制]" or ""))
    -- 回合系统初始化（2026-08-10）：当前回合方 = 先手方，广播当前回合。
    -- 客户端 HUD「结束回合」按钮按 KardsTurnUpdate 显示友方/敌方回合状态
    --（开场动画结束前按钮不绘制，见 cl_init.lua KardsEndTurnVisible）。
    self._kardsTurnSlot = firstSlot
    -- 数据层先手同步（2026-08-10 修复）：数据层 StartBattle 缺省先手 = players[1]（P1），
    -- 与随机 firstSlot 可能不一致 → 起手牌数（先手 4 / 后手 5）与先手揭晓/回合方脱节
    --（曾出现「显示先手却重新调度 5 张」）。实例已由 LoadPlayerBattleDeck 建立，
    -- 此处按随机先手修正 FirstPlayer / Starters（重新调度发牌在其后触发，见 OnMulliganReady）。
    local firstPlayer = (firstSlot == 1) and "P1" or "P2"
    local deckInst = KARDS.Deck and KARDS.Deck:Get(self.TableID)
    if deckInst then
        deckInst.FirstPlayer = firstPlayer
        deckInst.Starters = deckInst.Starters or {}
        for _, p in ipairs({ "P1", "P2" }) do
            deckInst.Starters[p] = (p == firstPlayer)
                and KARDS.Deck.FIRST_STARTER or KARDS.Deck.SECOND_STARTER
        end
    end
    -- 开局顺序（2026-08-11 修正）：原此处立即 SimBeginTurn（回合开始事件 + 指挥点
    -- 0→1）导致顺序错误——先手回合/指挥点在开场动画与重新调度之前就推进。
    -- 现改为：开场动画确定先手 → 双方重新调度 → 先手开始回合（回合开始事件 +
    -- 初始补给）→ 指挥点 0→2。SimBeginTurn 移至 StartFirstTurn（双方重新调度均
    -- 完成后触发，见 OnMulliganSubmit / CheckAllMulligansDone）。此处仅广播复位值：
    -- 指挥点池此时仍为 0（StartBattle 初始化），客户端无滚动显示 0。
    self:BroadcastTurn()
    self:BroadcastCommandPoints() -- 指挥点复位广播（重新调度结束前恒 0；先手 2 点由 StartFirstTurn 广播）
end

--[[
    先手回合开始（服务端权威）：双方重新调度均完成后调用（见 CheckAllMulligansDone）。
    在此执行先手初始补给（指挥点 0→1：AddSlot +1 槽 + BeginTurn 补满，2026-08-11
    数据层 Create 起双方 0 槽）→ 回合开始事件（SimBeginTurn 的 turn_begin 事件钩子 /
    词条每回合效果，+1 槽 → 2 点）→ 广播当前回合与指挥点（先手 2 点 / 后手 0 点）——
    客户端据此播放指挥点 0→2 滚动（StartFormalBattle 已广播 0 值，开场动画 /
    重新调度期间双方恒 0）。

    开局正确顺序（2026-08-11 修正）：开场动画确定先手 → 重新调度 → 先手开始回合
    （回合开始事件 + 初始补给）→ 先手指挥点从 0 到 2。此前 SimBeginTurn 在
    StartFormalBattle 内立即执行，导致「先手开始回合 → 指挥点 0→1 → 开场动画 →
    重新调度」。

    幂等：每场对局仅执行一次。
]]
function ENT:StartFirstTurn()
    if self._kardsFirstTurnStarted then return end
    self._kardsFirstTurnStarted = true
    local firstPlayer = (self._kardsFirstTurnSlot == 1) and "P1" or "P2"
    -- 先手初始补给：指挥点 0→1（+1 槽 + 点数补满；开局双方 0 槽，2026-08-11）
    if KARDS.CommandPoints then
        KARDS.CommandPoints:AddSlot(self.TableID, firstPlayer)
        KARDS.CommandPoints:BeginTurn(self.TableID, firstPlayer)
    end
    -- 广播先手 1 点：开场动画/重新调度期间双方恒 0（无广播），首个非 0 广播同时作为
    -- 客户端 HUD 指挥点面板的显示开关——动画前/中面板不显示，先手回合开始才出现
    --（先手 1 点，后手 0 点直到其回合开始；2026-08-11）
    self:BroadcastCommandPoints()
    -- 回合开始事件 + 指挥点 1→2（回合开始 +1 槽，点数补满至与槽相等）
    if KARDS.Battle and KARDS.Battle.SimBeginTurn then
        KARDS.Battle:SimBeginTurn(firstPlayer)
    end
    self:BroadcastTurn()
    self:BroadcastCommandPoints() -- 先手 2 点 / 后手 0 点（客户端 1→2 滚动，手牌花费颜色变黄）
    -- 初始战场布局广播（2026-08-11 单位操作）：双方重新调度完成、HQ 已上场，
    -- 且避开揭晓动画（KardsFieldLayout 接收器跳过 InHQRevealAnim 实体）——此时
    -- 广播双方支援阵线（总部驻留）+ 前线（无单位，ownerSlot=0 初始化客户端前线视图）
    for i, playerID in ipairs({ "P1", "P2" }) do
        self:BroadcastFieldLayout(i, playerID)
    end
    self:BroadcastFrontlineLayout(0)
end

--[[
    广播当前回合方（服务端权威）→ 所有客户端（含观战者）：
    WriteEntity 牌桌 + WriteUInt 当前回合槽位。客户端据此驱动 HUD「结束回合」
    按钮的友方/敌方状态（见 cl_init.lua KardsTurnUpdate / KardsEndTurnHUD）。
]]
function ENT:BroadcastTurn()
    local cur = self._kardsTurnSlot
    if not cur then return end
    net.Start("KardsTurnUpdate")
        net.WriteEntity(self)
        net.WriteUInt(cur, 8)
    net.Broadcast()
end

--[[
    广播当前双方指挥点（服务端权威）→ 所有客户端：
    WriteEntity 牌桌 + WriteUInt P1 点数 + WriteUInt P2 点数 +
    WriteUInt P1 槽数 + WriteUInt P2 槽数。
    客户端据此：
    1. 判定本方手牌卡牌花费 3D2D 文字颜色：友方回合且指挥点 ≥ 卡牌花费 →
       黄色，否则灰色（见 cl_init.lua KardsHandCostColorThink / cl_card_text_overlay.lua）；
    2. 绘制 HUD 指挥点面板：左半点数 + 右半 K/槽数（槽数为本载荷第 3/4 个
       16 位，见 cl_init.lua KardsCommandPointsHUD / KardsCommandPointsHUDThink）。
    调用时机：对战开始首回合（2026-08-11 起：StartFormalBattle 播 0 值复位、
    StartFirstTurn 于双方重新调度完成后播先手 2 点）、结束回合切换后（EndTurn）、
    打出手牌支付指挥点后（OnPlayCard）。指挥点数据源 = KARDS.CommandPoints
    （sh_command_point.lua，SimBeginTurn 补满 / Pay 扣减）。
]]
function ENT:BroadcastCommandPoints()
    local inst = KARDS.CommandPoints and KARDS.CommandPoints:Get(self.TableID)
    if not inst then return end
    net.Start("KardsCommandPoints")
        net.WriteEntity(self)
        net.WriteUInt(inst.Points["P1"] or 0, 16)
        net.WriteUInt(inst.Points["P2"] or 0, 16)
        net.WriteUInt(inst.Slots["P1"] or 0, 16)
        net.WriteUInt(inst.Slots["P2"] or 0, 16)
    net.Broadcast()
end

--[[
    结束回合（服务端权威）：切换到对方回合并广播。
    调用方已校验：请求玩家在牌桌内、对战已开始、且为当前回合方（见
    KardsEndTurn 接收器）。2026-08-10 起接通数据层回合：结束当前方回合 →
    开始下家回合（指挥点池 +1 槽，SimBeginTurn；turn_end 刻由 SimEndTurn 记录），
    2026-08-11 起回合开始抽 1 张（SimDraw，先手第一回合除外——由 StartFirstTurn
    处理且不抽牌）。使打出手牌的指挥点池随回合推进（先手首回合 2 点起步）。
]]
function ENT:EndTurn()
    if not self._kardsTurnSlot then return end
    -- 数据层回合推进（SimEndTurn 不存在时仅推进 SimBeginTurn，指挥点照常结算）
    if KARDS.Battle then
        local cur = (self._kardsTurnSlot == 1) and "P1" or "P2"
        local nxt = (self._kardsTurnSlot == 1) and "P2" or "P1"
        if KARDS.Battle.SimEndTurn then KARDS.Battle:SimEndTurn(cur) end
        if KARDS.Battle.SimBeginTurn then KARDS.Battle:SimBeginTurn(nxt) end
        -- 回合开始抽牌（2026-08-11）：下家回合开始抽 1 张（先手第一回合由
        -- StartFirstTurn 处理且不抽牌，EndTurn 只处理先手之后的对局回合）
        if KARDS.Battle.SimDraw then KARDS.Battle:SimDraw(nxt, 1) end
    end
    self._kardsTurnSlot = 3 - self._kardsTurnSlot
    self:BroadcastTurn()
    self:BroadcastCommandPoints() -- 回合切换后指挥点同步（下家补满；上家支付后的剩余一并广播）
    -- 暂无对手自动回传（测试版测试代码，2026-08-10）：对方槽位无玩家时 1 秒后
    -- 自动结束对方回合计回本方——便于单机快速测试回合机制。不播放对方的
    -- 「结束回合」音效（音效由点击方客户端本地播放，对方不在场自然无点击者）。
    -- 仅调度一次（对方仍不在场时，下一轮由本方再次点击结束回合触发）。
    local other = self._kardsTurnSlot
    if not IsValid(self.Slots[other]) then
        timer.Simple(1, function()
            -- 牌桌仍有效、回合仍是对方、且桌内仍有玩家（本方退出后不再空转切换）
            if IsValid(self) and self._kardsTurnSlot == other and self:GetPlayerCount() > 0 then
                self:EndTurn()
            end
        end)
    end
end
