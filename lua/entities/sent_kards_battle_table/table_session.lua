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

-- ====================================================================
-- 全服正式对战锁（2026-09-13 规划 S1 方案 A）：
-- 数据层 KARDS.Battle 为单例（TableID / Players 为模块级字段，全部 Sim 方法
-- 经单例路由），两张牌桌同时正式对战时后开局者夺走 TableID，旧桌操作会把旧桌
-- 卡牌送进新桌状态空间结算。开局在此抢锁，全服同一时刻只允许一场正式对战，
-- 对局判定结束（OnGameOver）/ 人去桌空（ExitSlot / 断线）/ 牌桌销毁时释放。
-- 组卡模式与旁观不受影响。锁持有牌桌实体，持锁桌失效后自动视为空闲。
-- ====================================================================
KARDS.FormalBattleLock = KARDS.FormalBattleLock or { holder = nil }

-- 尝试持有锁：本桌已持有时幂等成功；被其他有效牌桌持有时返回 false
function KARDS.FormalBattleLock.TryAcquire(tableEnt)
    local holder = KARDS.FormalBattleLock.holder
    if IsValid(holder) then
        return holder == tableEnt
    end
    KARDS.FormalBattleLock.holder = tableEnt
    return true
end

-- 释放锁：仅持有者本人释放；持锁桌已失效时清空允许他桌接管（幂等）
function KARDS.FormalBattleLock.Release(tableEnt)
    local holder = KARDS.FormalBattleLock.holder
    if not IsValid(holder) or holder == tableEnt then
        KARDS.FormalBattleLock.holder = nil
    end
end

-- 当前持锁牌桌（无锁或持锁桌已失效时返回 nil）
function KARDS.FormalBattleLock.GetHolder()
    local holder = KARDS.FormalBattleLock.holder
    return IsValid(holder) and holder or nil
end

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
    -- physSlot = 实际站位的物理槽位（恒等于进入槽位，不被 kards_switch 修改；
    -- data.slot 为操作身份槽位，无对手模式下切换 P1/P2 时两者分离，退出按 physSlot 还原）
    ply._kardsTable = {
        ent = self.ent,
        slot = slot,
        physSlot = slot,
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
    -- 释放槽位（无对手模式 kards_switch 切换过操作身份时，data.slot 为操作槽位，
    -- 实际占用/卡组均挂在物理槽位 physSlot 上，退出须按 physSlot 还原）
    local slot = data.physSlot or data.slot
    if self.ent.Slots and self.ent.Slots[slot] == ply then
        self.ent.Slots[slot] = nil
    end
    self.ent:SyncSlotName(slot) -- 槽位玩家名 NW 清空（观战者重新调度提示用，2026-08-12）
    self.ent:UpdateTableFreeze() -- 玩家退出：无玩家时解除牌桌物理冻结
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

    -- 清理卡组槽（battle 模式）：移除该槽卡堆档位实体、总部实体、抽牌临时卡实体、
    -- 战场单位实体（fieldCardEnts）与本槽手牌槽卡占位（kards_handslot）——
    -- 2026-08-13：此前漏清 fieldCardEnts 与手牌槽卡，对局结束后上一局单位残留在牌桌上
    if self.ent._kardsBattleDecks and self.ent._kardsBattleDecks[slot] then
        local bd = self.ent._kardsBattleDecks[slot]
        for _, e in pairs(bd.pileEnts or {}) do
            if IsValid(e) then e:Remove() end
        end
        if IsValid(bd.hqEnt) then bd.hqEnt:Remove() end
        for _, e in ipairs(bd.drawEnts or {}) do
            if IsValid(e) then e:Remove() end
        end
        -- 战场单位（牌桌上单位小模型）：经子物体系统逐个淡出移除（RemoveChild
        -- 1 秒淡出）；实体未注册/无效时直接 Remove
        for _, e in pairs(bd.fieldCardEnts or {}) do
            if IsValid(e) then
                if not (self.ent._kardsChildSystem and self.ent._kardsChildSystem:RemoveChild(e)) then
                    e:Remove()
                end
            end
        end
        bd.fieldCardEnts = nil
        -- 本槽手牌槽卡占位（kards_handslot，未登记于 deck 表）：按归属槽位 NW 移除
        if self.ent._kardsChildSystem then
            for _, child in ipairs(self.ent._kardsChildSystem:GetChildren()) do
                if IsValid(child) and child:GetNWBool("Kards_IsHandSlotCard", false)
                    and child:GetNWInt("Kards_DeckSlot", 0) == slot then
                    self.ent._kardsChildSystem:RemoveChild(child)
                end
            end
        end
        self.ent._kardsBattleDecks[slot] = nil
    end
    -- 无对手模式：本方退出时连带清理对方槽的虚拟对手卡组（虚拟卡组仅随本方在场有效，
    -- 否则残留实体/旧卡组数据在重新进入并再次开始对局时被 SetupVirtualOpponent 幂等跳过）
    local obd = self.ent._kardsBattleDecks and self.ent._kardsBattleDecks[3 - slot]
    if obd and obd.virtual then
        for _, e in pairs(obd.pileEnts or {}) do
            if IsValid(e) then e:Remove() end
        end
        if IsValid(obd.hqEnt) then obd.hqEnt:Remove() end
        for _, e in ipairs(obd.drawEnts or {}) do
            if IsValid(e) then e:Remove() end
        end
        -- 虚拟对手战场单位（同正常槽，2026-08-13 补齐）
        for _, e in pairs(obd.fieldCardEnts or {}) do
            if IsValid(e) then
                if not (self.ent._kardsChildSystem and self.ent._kardsChildSystem:RemoveChild(e)) then
                    e:Remove()
                end
            end
        end
        obd.fieldCardEnts = nil
        -- 虚拟对手手牌槽卡占位（kards_handslot，按归属槽位 NW 移除）
        if self.ent._kardsChildSystem then
            for _, child in ipairs(self.ent._kardsChildSystem:GetChildren()) do
                if IsValid(child) and child:GetNWBool("Kards_IsHandSlotCard", false)
                    and child:GetNWInt("Kards_DeckSlot", 0) == 3 - slot then
                    self.ent._kardsChildSystem:RemoveChild(child)
                end
            end
        end
        self.ent._kardsBattleDecks[3 - slot] = nil
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
    -- 牌桌内有玩家时禁止物理枪拾取牌桌（配合 UpdateTableFreeze 的冻结：物理枪
    -- 拾取冻结实体时会自动启用运动，仅 EnableMotion(false) 挡不住拖走牌桌；
    -- 无玩家时允许拾取，便于生成后移动摆放）
    hook.Add("PhysgunPickup", "KardsTableFreezeGuard", function(ply, ent)
        if IsValid(ent) and ent:GetClass() == "sent_kards_battle_table"
            and ent:GetPlayerCount() > 0 then
            return false
        end
    end)

    net.Receive("KardsTableEnter", function(_, ply)
        local ent = net.ReadEntity()
        if IsValid(ent) and ent:GetClass() == "sent_kards_battle_table" then
            ent:TryEnterSlot(ply)
        end
    end)

    net.Receive("KardsTableExit", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) then return end
        -- 归属校验（2026-10-03 联机排查）：须为发送者当前所在牌桌，防用他人牌桌实体触发退出
        local data = ply._kardsTable
        if not data or data.ent ~= ent then return end
        ent:ExitSlot(ply)
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
            -- 对手提示（2026-08-18 规划 D10）：对局中对方断线 → 通知留在牌桌内的
            -- 对手（对局推进由 D12 回合超时兜底，断线方重连不在本次范围）
            local oppSlot = 3 - (data.slot or 0)
            local opp = ent.Slots and ent.Slots[oppSlot]
            if IsValid(opp) and opp:IsPlayer() and ent._kardsFormalBattleStarted then
                KARDS.TableSync.Notify(opp, "msg.opponent_offline")
            end
            -- 最后一人断线：牌桌已无人在槽，复位开局标记并释放全服对战锁
            --（规划 S1；断线路径走会话状态机 Exit，不经过 ExitSlot）
            local stillHas = false
            for _, p in pairs(ent.Slots or {}) do
                if IsValid(p) and p:IsPlayer() then
                    stillHas = true
                    break
                end
            end
            if not stillHas then
                ent._kardsFormalBattleStarted = false
                KARDS.FormalBattleLock.Release(ent)
            end
        end
    end)

    -- 强制开始对战（单人快速测试）：执行玩家须已进入某牌桌，直接跳过双方就绪
    -- 与 3 秒倒计时（StartFormalBattle(forced=true)），服务端权威校验在牌桌内。
    -- 权限限制（2026-08-19 规划 C8）：仅 operator 及以上可用，普通玩家无权绕过双方就绪
    -- 强制开局。判定走 KARDS.IsOperator（2026-10-03 修复：管理插件未装时回退内建管理员判定，
    -- 原先直接调 Player:IsOperator 在该情形下报 nil 方法错误）。
    concommand.Add("kards_forcestart", function(ply, cmd, args)
        if not IsValid(ply) or not ply:IsPlayer() then
            print("[Kards] kards_forcestart 仅限玩家在牌桌内执行")
            return
        end
        if not KARDS.IsOperator(ply) then
            KARDS.TableSync.Notify(ply, "msg.no_permission")
            return
        end
        local data = ply._kardsTable
        if not data or not IsValid(data.ent) then
            KARDS.TableSync.Notify(ply, "msg.not_in_table_force_start")
            return
        end
        data.ent:StartFormalBattle(true)
    end)

    -- 切换操作方（无对手模式，单人测试）：牌桌内仅本方一名玩家时，把玩家本体
    -- 移动到对面槽位（GetSlotWorldPos 定位 + Slots 占用迁移 + data.slot/physSlot
    -- 同步），并通知客户端切换视角/相机/手牌卡面（KardsSwitchSlot）。
    -- 卡组归属随移动互换：玩家离开的槽其卡组转为虚拟对手（virtual=true），
    -- 到达的槽转为真实玩家（virtual=false）——退出清理/回合自动回传判断随之正确。
    -- 权限限制（2026-10-03）：仅 operator 及以上可用（判定见 KARDS.IsOperator，与
    -- kards_forcestart、kards_fakeuser_* 同一档），防外人误用无对手模式。
    concommand.Add("kards_switch", function(ply, cmd, args)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        if not KARDS.IsOperator(ply) then
            KARDS.TableSync.Notify(ply, "msg.no_permission")
            return
        end
        local data = ply._kardsTable
        if not data or not IsValid(data.ent) then
            KARDS.TableSync.Notify(ply, "msg.not_in_table_switch")
            return
        end
        local ent = data.ent
        if not ent._kardsFormalBattleStarted then
            KARDS.TableSync.Notify(ply, "msg.battle_not_started_switch")
            return
        end
        if ent:GetPlayerCount() ~= 1 then
            KARDS.TableSync.Notify(ply, "msg.only_solo_switch")
            return
        end
        if ent._kardsFakeUser then
            -- 伪用户接管中（2026-09-13）：对方由控制台指令操作，交换位置会打乱
            -- 槽位/视角归属，禁用直到 kards_fakeuser 0 关闭
            KARDS.TableSync.Notify(ply, "msg.fakeuser_switch")
            return
        end
        local oldSlot = data.physSlot or data.slot
        local newSlot = 3 - oldSlot
        -- 切换目标槽位须已有卡组（对局开始时两槽均补齐，StartFormalBattle）
        local targetDeck = ent._kardsBattleDecks and ent._kardsBattleDecks[newSlot]
        if not targetDeck then
            KARDS.TableSync.Notify(ply, "msg.enemy_slot_no_deck")
            return
        end
        -- 卡组归属互换（旧槽现无真人 → 转虚拟对手；新槽有真人 → 转真实玩家）
        local oldDeck = ent._kardsBattleDecks and ent._kardsBattleDecks[oldSlot]
        if oldDeck then oldDeck.virtual = true end
        targetDeck.virtual = false
        -- 玩家本体移至新槽位中心（保持脚底高度，避免悬浮/陷入桌面），面向牌桌
        local slotPos = ent:GetSlotWorldPos(newSlot)
        local cur = ply:GetPos()
        ply:SetPos(Vector(slotPos.x, slotPos.y, cur.z))
        local face = (ent:GetPos() - ply:GetPos()):Angle()
        ply:SetEyeAngles(face)
        ply:SetAngles(Angle(0, face.yaw, 0))
        -- 槽位占用与操作身份同步迁移（进入冻结仍生效，MOVETYPE_NONE 下 SetPos 有效）
        ent.Slots[oldSlot] = nil
        ent.Slots[newSlot] = ply
        ent:SyncSlotName(oldSlot) -- 旧槽无真人（虚拟对手）→ 清空名
        ent:SyncSlotName(newSlot) -- 新槽真人 → 玩家名
        data.slot = newSlot
        data.physSlot = newSlot
        -- 通知客户端切换视角/相机/手牌卡面
        net.Start("KardsSwitchSlot")
            net.WriteEntity(ent)
            net.WriteUInt(newSlot, 8)
        net.Send(ply)
        -- 卡面定向补发（2026-11-12）：手牌卡面标识平时只经 KardsTableDrawFace 发给
        -- 当时的本方玩家，无对手模式切到新槽后，该客户端没有新槽手牌的卡面记录，
        -- InitDrawCardFace 因卡名为空一直早退（入队重试也永远失败），重新调度代选
        -- 与切换后的本方手牌会一直显示卡背。这里把新槽手牌卡面补发给切换后的操作者，
        -- 客户端 cardFaces 就绪后由 KardsDrawFacePending 自动完成卡面初始化。
        local ownerName = (newSlot == 1) and "P1" or "P2"
        local hand = KARDS.Deck:GetHand(ent.TableID, ownerName) or {}
        local cardEnts = targetDeck.cardEnt
        if cardEnts then
            for _, handCard in ipairs(hand) do
                local handEnt = cardEnts[handCard]
                if IsValid(handEnt) then
                    net.Start("KardsTableDrawFace")
                        net.WriteEntity(handEnt)
                        net.WriteString(handCard:GetName())
                        net.WriteString(handCard:GetName())
                        net.WriteString(handCard:GetType())
                    net.Send(ply)
                end
            end
        end
        print(("[Kards] 无对手模式: %s 移动到 P%d"):format(ply:Nick(), newSlot))
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

--[[
    按牌桌内玩家占用冻结/解冻牌桌物理（2026-08-13）：
    有玩家在槽位（已进入牌桌）→ 冻结运动（EnableMotion(false)），配合
    PhysgunPickup hook 阻止物理枪拾取，防止对局中被碰撞/物理枪等移走牌桌破坏对战；
    无玩家 → 解冻（EnableMotion(true)），玩家可自由移动摆放牌桌。
    在 TryEnterSlot 进入成功后与会话状态机 Exit（释放槽位）后调用。
]]
function ENT:UpdateTableFreeze()
    local hasPlayer = false
    for _, p in pairs(self.Slots or {}) do
        if IsValid(p) then
            hasPlayer = true
            break
        end
    end
    local phys = self:GetPhysicsObject()
    if not IsValid(phys) then return end
    -- 有玩家 → 冻结（禁运动）；无玩家 → 解冻（可移动）
    if phys:IsMoveable() == (not hasPlayer) then return end -- 状态已符合，跳过
    phys:EnableMotion(not hasPlayer)
end

--[[
    同步槽位玩家名到牌桌 NW（Kards_SlotName_<slot>，2026-08-12）：
    观战者视角重新调度进度提示（cl_init.lua KardsSpectateMulliganHUD 的
    「「玩家名」正在重新调度」）按槽位显示仍在重新调度的一方玩家名；
    槽位无真人（虚拟对手 / 已离开）→ 空串（客户端按 "P<槽>" 兜底）。
    进入（TryEnterSlot）/ 退出（TableSession:Exit 释放槽位）/ kards_switch
    槽位迁移时调用。NW 自动广播所有客户端（含观战者）。

    @param slot number 槽位编号（1 / 2）
]]
function ENT:SyncSlotName(slot)
    local p = self.Slots and self.Slots[slot]
    self:SetNWString("Kards_SlotName_" .. slot, IsValid(p) and p:IsPlayer() and p:Nick() or "")
end

function ENT:TryEnterSlot(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return false end
    -- 已在牌桌中（本桌或其他桌），拒绝重复进入
    if ply._kardsTable then return false end
    -- 对局进行中（2026-08-19 规划 C9）：拒绝中途进入——LoadPlayerBattleDeck 会
    -- SimSetupDeck 覆盖该侧数据层卡组为全新 39 张并清空手牌（场上旧实体残留）；
    -- 未进入的玩家自动为观战者（StartFormalBattle 已广播 KardsTableBattleStart
    -- 观战分支，见 table_session.lua），再次 kards_enter 走 ExitSlot 退出观战。
    -- 注：槽位判空（GetPlayerSlot）之前拒绝，双人退出后空槽/虚拟对手槽均不可进入。
    if self._kardsFormalBattleStarted then
        KARDS.TableSync.Notify(ply, "msg.join_in_progress")
        return false
    end
    -- 槽位判定：玩家必须处于本桌某槽位范围内
    local slot = self:GetPlayerSlot(ply)
    if not slot then return false end
    -- 组卡模式：仅 P2（槽位 2）可进入牌桌（组卡构建由 P2 进行）
    if self.Mode == "deck" and slot ~= 2 then
        KARDS.TableSync.Notify(ply, "msg.deck_mode_p2_only")
        return false
    end
    -- 占用检测：目标槽位已被其他玩家占用则拒绝并提示
    if IsValid(self.Slots[slot]) then
        KARDS.TableSync.Notify(ply, "msg.slot_taken")
        return false
    end
    -- 分配槽位 + 会话状态机进入（保存进入前状态 + 冻结 + 移至槽位 + 煤油灯）
    self.Slots[slot] = ply
    self:SyncSlotName(slot) -- 槽位玩家名 NW（观战者重新调度提示用，2026-08-12）
    self:UpdateTableFreeze() -- 有玩家进入：冻结牌桌物理（对局中防被移走）
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
    -- 离开牌桌：清除不同步弹窗标记（下次进入若再发生分歧可重新弹窗，见 NotifyDesync）
    ply._kardsDesyncNotified = nil
    -- 离开牌桌：解除该玩家的伪用户接管（协程/待选状态随牌桌会话一并作废，
    -- kards_switch 与回合超时门控随之恢复，见 sv_fakeuser.lua）
    if self._kardsFakeUser and self._kardsFakeUser.ply == ply then
        self._kardsFakeUser = nil
    end
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
        -- 人去桌空：释放全服正式对战锁（规划 S1，他桌可开局）
        KARDS.FormalBattleLock.Release(self)
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
    根据槽位占用更新牌桌上方灯具：
    有玩家在玩家槽（已进入牌桌）→ 确保灯具存在；无玩家 → 移除灯具。
    在会话状态机 Enter / Exit 末尾调用。

    2026-10-24 用户规格：由 gmod_light（全向点光，无实时阴影）换为 gmod_lamp
    （GMod Q 菜单「工具 > 灯」的投影灯，内部创建 env_projectedtexture 并固定
    enableshadows=1）——玩家视频设置「阴影质量：高」时投射实时阴影（卡牌/单位
    在桌面投下随光源变化的影子），低档位时引擎自动退化为无阴影投影光。
    灯具朝向垂直向下（Angle(90,0,0)），暖橙黄煤油灯色，牌桌正上方。
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
            -- 创建 gmod_lamp 投影灯（灯工具同款 gmod_lamp 实体）：
            -- 直射锥形光 + 实时阴影（阴影质量高档时），煤油灯色（暖橙黄），牌桌正上方。
            -- 实测 light_dynamic 运行时创建渲染不可靠，gmod_light 无实时阴影（2026-10-24 前用）。
            local top = self:LocalToWorld(Vector(0, 0, 80)) -- fallback：牌桌正上方
            local phys = self:GetPhysicsObject()
            if IsValid(phys) then
                -- 实测：phys:GetAABB() 返回局部坐标（相对实体原点），须经 LocalToWorld 转世界坐标
                local mins, maxs = phys:GetAABB()
                top = self:LocalToWorld(Vector((mins.x + maxs.x) / 2, (mins.y + maxs.y) / 2, maxs.z + 60)) -- 桌面顶上方 60 单位
            end
            light = ents.Create("gmod_lamp")
            if IsValid(light) then
                -- 参数顺序同沙盒灯工具 MakeLamp：模型/贴图/锥角/距离/亮度/开关均在 Spawn 前设置
                --（gmod_lamp 的 NetworkVarNotify 在 SetOn(true) 时即创建 env_projectedtexture 子实体）
                light:SetModel("models/maxofs2d/lamp_projector.mdl")
                light:SetPos(top)
                light:SetAngles(Angle(90, 0, 0)) -- pitch 90 = 正向垂直向下照桌面
                light:SetFlashlightTexture("effects/flashlight001")
                light:SetLightFOV(110)                 -- 光锥角（覆盖牌桌 90x45 与余量）
                light:SetDistance(300)                 -- 投射远裁剪面（灯距桌面 60，余量充足）
                light:SetColor(Color(255, 185, 90, 255)) -- 煤油灯色（暖橙黄）
                light:SetBrightness(2)                 -- 亮度（env_projectedtexture 为颜色倍率，同旧灯）
                light:Switch(true)                     -- 点亮（创建投影光子实体）
                light:Spawn()
                -- 隐藏灯具本体（模型 + 光斑 sprite，仅保留投影光照）+ 冻结（不因重力落下/不碰撞）
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

    准备前校验该槽卡组有效（2026-10-17）：无存档 / 不足 40 张 / 缺总部时拒绝并提示。
    无总部的一方既无手牌也无胜负判定载体，开局后对局无法结束。

    @param ply Player
    @param ready boolean 目标准备状态
]]
function ENT:SetReady(ply, ready)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    local data = ply._kardsTable
    if not data or data.ent ~= self then return end
    if self._kardsFormalBattleStarted then return end -- 对战已开始：忽略准备切换
    -- 卡组有效性校验（见上方说明）：只拦「准备」，取消准备不受影响
    if ready then
        local bd = self._kardsBattleDecks and self._kardsBattleDecks[data.slot]
        if not (bd and bd.hasValidDeck) then
            KARDS.TableSync.Notify(ply, "msg.ready_no_deck")
            return
        end
    end
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
    -- 提示双方：进入 3 秒等待（闪屏消息，见客户端 Flash；逐人按各自语言发送）
    for _, p in ipairs({ p1, p2 }) do
        KARDS.TableSync.Notify(p, "msg.both_ready_3s")
    end
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
    -- 全服正式对战锁（规划 S1 方案 A）：他桌对局进行中时拒绝开局并提示等待，
    -- 本桌不置 _kardsFormalBattleStarted，就绪状态保留，锁释放后可再次尝试开局
    if not KARDS.FormalBattleLock.TryAcquire(self) then
        self:CancelBattleStartCountdown()
        local targets = {}
        for _, p in pairs(self.Slots or {}) do
            if IsValid(p) and p:IsPlayer() then targets[#targets + 1] = p end
        end
        if #targets > 0 then
            -- 逐人按各自语言下发（2026-10-17 多语言化）
            for _, p in ipairs(targets) do
                KARDS.TableSync.Notify(p, "msg.battle_lock_busy")
            end
        else
            print("[Kards] 已有一场正式对战正在进行，请等待其结束")
        end
        return
    end
    self._kardsFormalBattleStarted = true
    -- 注册属性变更回调（t4 3D2D 数值同步，2026-08-12）：节点效果路径（trigger 伤害
    -- SimDealDamage / 战斗操作 SimFight）改变单位/总部属性后刷新战场实体 NW
    -- （OnBattleStatsChanged 定义于 table_battledeck.lua；数据层回调见 sh_battle_combat.lua
    -- SetStatsChangedCallback / NotifyStatsChanged）
    if KARDS.Battle and KARDS.Battle.SetStatsChangedCallback then
        KARDS.Battle:SetStatsChangedCallback(self.TableID,
            function(...) self:OnBattleStatsChanged(...) end)
    end
    -- 注册属性变化音效回调（2026-08-13：stat_change.ogg 播放时机收窄——数据层来源
    -- 命中——属性与伤害节点攻击/防御分支 + 山地/动员词条——广播客户端播放音效，
    -- 见 sh_battle_combat.lua NotifyStatSound / table_battledeck.lua BroadcastStatChangeSound）
    if KARDS.Battle and KARDS.Battle.SetStatSoundCallback then
        KARDS.Battle:SetStatSoundCallback(self.TableID,
            function() self:BroadcastStatChangeSound() end)
    end
    -- 注册属性变化飘字回调（2026-08-14：3D2D 飘字——数据层攻击/防御/行动花费全部
    -- 变动来源点触发 → 广播客户端飘字，见 sh_battle_combat.lua NotifyStatFX /
    -- table_battledeck.lua BroadcastStatChangeFX）
    if KARDS.Battle and KARDS.Battle.SetStatFXCallback then
        KARDS.Battle:SetStatFXCallback(self.TableID,
            function(card, slot, delta, mod, kind)
                self:BroadcastStatChangeFX(card, slot, delta, mod, kind)
            end)
    end
    -- 注册控制/解除控制动画回调（2026-08-16：数据层 SimControl/SimUncontrol 成功
    -- 触发 → 广播客户端控制动画 + 布局重排，见 sh_battle_combat.lua NotifyControl /
    -- table_battledeck.lua BroadcastControlAnim）
    if KARDS.Battle and KARDS.Battle.SetControlCallback then
        KARDS.Battle:SetControlCallback(self.TableID,
            function(card, isUncontrol, landingZone, landingSlot, fromOwner, toOwner)
                self:BroadcastControlAnim(card, isUncontrol, landingZone, landingSlot, fromOwner, toOwner)
            end)
    end
    -- 注册事件音效回调（2026-08-13：数据层事件——当前仅反制拦截触发 trigger——
    -- 广播客户端播放卡牌保存的音效路径；反制触发无事件源实体，写牌桌自身，客户端
    -- 回退音源方位为牌桌 WorldCenter。见 sh_battle_combat.lua NotifyEventSound /
    -- table_battledeck.lua BroadcastEventSound）
    -- 2026-09-26 缺口 H：改走 BroadcastEventSound，效果路径获得按「单位类型 × 规模」的
    -- 自动分配能力（与手动路径一致）。行为等价性：trigger 在 BroadcastEventSound 内
    -- 无自动分支，最终路径仍取 snds.trigger；无事件源实体时音源回退牌桌自身
    -- （BroadcastEventSound 的 ent or self），与改前一致。
    if KARDS.Battle and KARDS.Battle.SetSoundCallback then
        KARDS.Battle:SetSoundCallback(self.TableID, function(eventKey, card)
            if not (card and card.GetSounds) then return end
            self:BroadcastEventSound(card, eventKey)
        end)
    end
    -- 注册反制自动打出回调（反制系统 M5：数据层 FireCounter 在反制被敌方操作触发后
    -- 通知 → 广播指令口径的打出动画 + 激活时音效并清理手牌实体与计数，见
    -- sh_battle_combat.lua CounterPlayCallbacks / table_battledeck.lua OnCounterFired）
    if KARDS.Battle and KARDS.Battle.SetCounterPlayCallback then
        KARDS.Battle:SetCounterPlayCallback(self.TableID, function(card, slot)
            self:OnCounterFired(card, slot)
        end)
    end
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
            -- 战斗 BGM 启动（2026-08-14 用户规格）：仅在场玩家收到——客户端本地
            -- 独立随机选风格（kards/wards）与曲目循环播放，双方随机故音乐不要求
            -- 相同；观战者收不到本消息自然不会播放。播放/停止见 cl_battle_bgm.lua
            net.Start("KardsBattleBGM")
                net.WriteEntity(self)
                net.WriteUInt(slot, 2)
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
    -- 回合系统初始化（2026-08-10）：当前回合方 = 先手方。
    -- 注意：此处不再 BroadcastTurn（2026-08-13 修复）——提前广播会把 KardsTurnUpdate
    -- 在重新调度开始前发给客户端，battleTurn 提前置位导致：① 客户端「敌方正在重新
    -- 调度手牌」提示被 battleTurn ~= nil 拦截永不显示（cl_init.lua KardsWaitingOpponent
    -- MulliganHUD）；② 先手「结束回合」按钮在对方调度期间即可点（cl_battle_hud.lua
    -- KardsEndTurnThink）。回合方改由 StartFirstTurn 广播（双方重新调度均完成 +
    -- MulliganToFirstTurnDelay 延迟后），期间客户端 battleTurn 保持 nil。
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
    -- 无对手模式（2026-08-12）：缺玩家的槽位建立虚拟对手（无 AI，默认卡组 = 本方
    -- 副本，见 SetupVirtualOpponent）——单人 kards_forcestart 后双方卡组/起手/重新
    -- 调度均就绪，配合 kards_switch 指令切换 P1/P2 操作身份。置于先手同步之后：
    -- 虚拟对手起手抽牌按 Starters（先手 4 / 后手 5）取数。双方均有玩家时循环为空操作。
    for slot = 1, 2 do
        if not (IsValid(self.Slots[slot]) and self.Slots[slot]:IsPlayer()) then
            local otherPly = self.Slots[3 - slot]
            local deckData = nil
            if IsValid(otherPly) and otherPly:IsPlayer() then
                local obd = self._kardsBattleDecks and self._kardsBattleDecks[3 - slot]
                deckData = obd and obd.deckData
            end
            self:SetupVirtualOpponent(slot, deckData)
        end
    end
    -- 开局顺序（2026-08-11 修正）：原此处立即 SimBeginTurn（回合开始事件 + 指挥点
    -- 0→1）导致顺序错误——先手回合/指挥点在开场动画与重新调度之前就推进。
    -- 现改为：开场动画确定先手 → 双方重新调度 → 先手开始回合（回合开始事件 +
    -- 初始补给）→ 指挥点 0→2。SimBeginTurn 移至 StartFirstTurn（双方重新调度均
    -- 完成后触发，见 OnMulliganSubmit / CheckAllMulligansDone）。此处仅广播复位值：
    -- 指挥点池此时仍为 0（StartBattle 初始化），客户端无滚动显示 0。
    -- 指挥点复位广播（重新调度结束前恒 0；先手 2 点由 StartFirstTurn 广播）
    -- 2026-08-13：BroadcastTurn 已移除——回合方（KardsTurnUpdate → battleTurn）只由
    -- StartFirstTurn 广播，保证重新调度期间客户端 battleTurn == nil（等待敌方提示 /
    -- 结束回合按钮防抢先的前提，见上方注释）。
    self:BroadcastCommandPoints()
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
    -- 回合超时（2026-08-18 规划 D12）：首回合开始即启动超时定时器
    self:StartTurnTimer(self._kardsTurnSlot)
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
    广播当前双方指挥点（服务端权威）→ 各客户端：
    WriteEntity 牌桌 + WriteUInt P1 点数 + WriteUInt P2 点数 +
    WriteUInt P1 槽数 + WriteUInt P2 槽数。
    客户端据此：
    1. 判定本方手牌卡牌花费 3D2D 文字颜色：友方回合且指挥点 ≥ 卡牌花费 →
       黄色，否则灰色（见 cl_init.lua KardsHandCostColorThink / cl_card_text_overlay.lua）；
    2. 绘制 HUD 指挥点面板：左半点数 + 右半 K/槽数（槽数为本载荷第 3/4 个
       16 位，见 cl_init.lua KardsCommandPointsHUD / KardsCommandPointsHUDThink）。
    调用时机：对战开始首回合（2026-08-11 起：StartFormalBattle 播 0 值复位、
    StartFirstTurn 于双方重新调度完成后播先手 2 点）、结束回合切换后（EndTurn）、
    打出手牌支付指挥点后（OnPlayCard）、反制激活 / 失活后。指挥点数据源 =
    KARDS.CommandPoints（sh_command_point.lua，SimBeginTurn 补满 / Pay 扣减）。
    反制系统 M4（信息隔离）：改为按查看者裁剪后逐个 net.Send——本方槽位发真实点数，
    对方 / 观战者看到的槽位发公开口径（GetPublicPoints = 真实点数 + 隐藏的反制花费）。
    槽数双方同值不变。（原 net.Broadcast 全员同值，无法隐藏支付。）
]]
function ENT:BroadcastCommandPoints()
    local cp = KARDS.CommandPoints
    local inst = cp and cp:Get(self.TableID)
    if not inst then return end
    local slots1, slots2 = inst.Slots["P1"] or 0, inst.Slots["P2"] or 0
    local real1, real2 = inst.Points["P1"] or 0, inst.Points["P2"] or 0
    local pub1 = cp.GetPublicPoints and cp:GetPublicPoints(self.TableID, "P1") or real1
    local pub2 = cp.GetPublicPoints and cp:GetPublicPoints(self.TableID, "P2") or real2
    local ply1 = self.Slots and self.Slots[1]
    local ply2 = self.Slots and self.Slots[2]
    -- 逐客户端发送（避免无接收者时残留未结束消息污染 net.messageStarted，
    -- 见 table_battledeck.lua KardsDragSync 注释）
    for _, p in ipairs(player.GetAll()) do
        local p1, p2
        if p == ply1 then
            p1, p2 = real1, pub2 -- 本方 P1：P1 真实、P2 公开
        elseif p == ply2 then
            p1, p2 = pub1, real2 -- 本方 P2：P1 公开、P2 真实
        else
            p1, p2 = pub1, pub2 -- 观战者：双方公开
        end
        net.Start("KardsCommandPoints")
            net.WriteEntity(self)
            net.WriteUInt(p1, 16)
            net.WriteUInt(p2, 16)
            net.WriteUInt(slots1, 16)
            net.WriteUInt(slots2, 16)
        net.Send(p)
    end
end

--[[
    回合超时自动结束（2026-08-18 规划 D12）：一方回合若无时限，该方永不点「结束
    回合」（打完牌忘点或有意为之）→ 对局卡死。每回合（StartFirstTurn / EndTurn
    切换后）为当前回合方启动单发定时器，超时（KARDS_TURN_TIMEOUT 秒）自动 EndTurn。
    仅真实玩家 / 虚拟对手槽启动（两槽均无卡组的旧单机测试由 EndTurn 自动回传处理）；
    对局结束（OnGameOver 置 _kardsTurnSlot=nil）时清理。定时器回调自校验牌桌有效 /
    对局未结束 / 回合未切换（防旧定时器误触发已推进的回合）。
]]
local KARDS_TURN_TIMEOUT = 120 -- 出牌时限（秒）

function ENT:ClearTurnTimer()
    if self._kardsTurnTimer then
        timer.Remove(self._kardsTurnTimer)
        self._kardsTurnTimer = nil
    end
end

function ENT:StartTurnTimer(slot)
    self:ClearTurnTimer()
    if not slot then return end
    -- 伪用户接管中（2026-09-13）：对方回合由管理控制台手动操作/结束，回合超时失效
    if self._kardsFakeUser then return end
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not IsValid(self.Slots[slot]) and not (deck and deck.virtual) then return end
    local id = "kards_turn_timeout_" .. self:EntIndex()
    self._kardsTurnTimer = id
    timer.Create(id, KARDS_TURN_TIMEOUT, 1, function()
        if not IsValid(self) then return end
        if self._kardsGameOver then return end
        if self._kardsTurnSlot ~= slot then return end
        self:EndTurn()
    end)
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
    -- 无对手模式（2026-08-12）：对方槽位已建立虚拟对手卡组（bd.virtual）时不自动
    -- 回传——该回合停在对方，玩家经 kards_switch 切换操作身份后手动结束；自动回传
    -- 仅保留给两槽均无卡组的旧单机测试场景。
    local other = self._kardsTurnSlot
    local otherDeck = self._kardsBattleDecks and self._kardsBattleDecks[other]
    if not IsValid(self.Slots[other]) and not (otherDeck and otherDeck.virtual) then
        timer.Simple(1, function()
            -- 牌桌仍有效、回合仍是对方、且桌内仍有玩家（本方退出后不再空转切换）
            if IsValid(self) and self._kardsTurnSlot == other and self:GetPlayerCount() > 0 then
                self:EndTurn()
            end
        end)
    end
    -- 回合超时（2026-08-18 规划 D12）：切换后为对方启动超时定时器（无玩家/虚拟槽
    -- 由上方自动回传处理，StartTurnTimer 内部跳过）
    self:StartTurnTimer(self._kardsTurnSlot)
end

-- ====================================================================
-- 测试版不同步恢复（2026-09-13）：
-- 服务端在权威校验中发现「规则门控已通过、但客户端引用的战斗状态在服务端不存在」
-- 这类结构性分歧（正常时序不可能发生，见 OnPlayCard 接入点）时，定向通知该玩家
-- 客户端弹出模糊重启窗；玩家点「重启」后请求本桌快照，本地清空重建战斗视图。
-- 不释放槽位、不移动玩家、不触碰数据层，对局不中断。玩家身上的弹窗标记幂等，
-- 快照送达或玩家离开牌桌（ExitSlot）时清除。
-- 正式版由 NetSync 签名比对 + 自动全量重同步取代（见《战斗系统规划.md》）。
-- ====================================================================

--[[
    通知玩家客户端其本地状态与服务端分歧（幂等：弹窗未通过重启解除前不重复发送）。

    @param ply Player
]]
function ENT:NotifyDesync(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if ply._kardsDesyncNotified then return end
    ply._kardsDesyncNotified = true
    net.Start("KardsDesyncNotify")
        net.WriteEntity(self)
    net.Send(ply)
end

--[[
    向玩家单播当前战斗全量快照（软重进）：手牌实体（顺序 + 卡面标识）、两槽支援
    阵线（总部取 deck.hqEnt）、前线（归属 + 单位）、当前回合槽、指挥点点数与槽数。
    世界实体（手牌/战场卡）均已存在且经子物体系统绑定本桌，快照只重建客户端本地
    索引表，不新建任何实体。

    @param ply  Player 必须在本桌槽位中
    @param slot number 该玩家槽位（1/2）
]]
function ENT:SendDesyncSnapshot(ply, slot)
    if not (IsValid(ply) and ply:IsPlayer()) then return end
    if not self._kardsFormalBattleStarted then return end
    local decks = self._kardsBattleDecks
    local deck = decks and decks[slot]
    if not deck then return end
    local tid = self.TableID
    local playerID = (slot == 1) and "P1" or "P2"

    -- 本方手牌：数据层手牌顺序 → 抽出时登记的手牌实体（deck.cardEnt 反向映射）
    local handItems = {}
    local hand = KARDS.Deck and KARDS.Deck:GetHand(tid, playerID)
    if hand then
        for _, card in ipairs(hand) do
            local ce = deck.cardEnt and deck.cardEnt[card]
            if IsValid(ce) then
                handItems[#handItems + 1] = { ce, card:GetName(), card:GetID(), card:GetType() }
            end
        end
    end

    -- 某槽支援阵线快照项（总部实体单独取 hqEnt，其余取 fieldCardEnts）
    local function supportItems(s)
        local pid = (s == 1) and "P1" or "P2"
        local d = decks and decks[s]
        local line = KARDS.Battlefield and KARDS.Battlefield:GetSupport(tid, pid)
        local items = {}
        if d and line then
            for i = 1, KARDS.Battlefield.SLOT_COUNT do
                local card = line[i]
                if card then
                    local e
                    if card:GetType() == "headquarter" then
                        e = d.hqEnt
                    else
                        e = d.fieldCardEnts and d.fieldCardEnts[card]
                    end
                    if IsValid(e) then items[#items + 1] = { i, e } end
                end
            end
        end
        return items
    end
    local support1 = supportItems(1)
    local support2 = supportItems(2)

    -- 前线快照项（单位按卡牌归属反查所属槽 deck）
    local flItems = {}
    local flOwner = 0
    local frontline = KARDS.Battlefield and KARDS.Battlefield:GetFrontline(tid)
    if frontline then
        local ownerID = KARDS.Battlefield:GetFrontlineOwner(tid)
        flOwner = (ownerID == "P1") and 1 or ((ownerID == "P2") and 2 or 0)
        for i = 1, KARDS.Battlefield.SLOT_COUNT do
            local card = frontline[i]
            if card then
                local d = decks and decks[(card:GetOwner() == "P1") and 1 or 2]
                local e = d and d.fieldCardEnts and d.fieldCardEnts[card]
                if IsValid(e) then flItems[#flItems + 1] = { i, e } end
            end
        end
    end

    -- 指挥点点数/槽数（缺失按 0，载荷格式与 KardsCommandPoints 一致）
    local cp = KARDS.CommandPoints and KARDS.CommandPoints:Get(tid)
    local cp1 = cp and (cp.Points["P1"] or 0) or 0
    local cp2 = cp and (cp.Points["P2"] or 0) or 0
    local cs1 = cp and (cp.Slots["P1"] or 0) or 0
    local cs2 = cp and (cp.Slots["P2"] or 0) or 0

    net.Start("KardsDesyncSnapshot")
        net.WriteEntity(self)
        net.WriteUInt(slot, 8)
        net.WriteUInt(self._kardsTurnSlot or 0, 8) -- 0 = 先手回合尚未开始（重新调度窗口）
        net.WriteUInt(#handItems, 8)
        for _, it in ipairs(handItems) do
            net.WriteEntity(it[1])
            net.WriteString(it[2] or "")
            net.WriteString(it[3] or "")
            net.WriteString(it[4] or "")
        end
        for _, items in ipairs({ support1, support2 }) do
            net.WriteUInt(#items, 8)
            for _, it in ipairs(items) do
                net.WriteUInt(it[1], 8)
                net.WriteEntity(it[2])
            end
        end
        net.WriteUInt(flOwner, 8)
        net.WriteUInt(#flItems, 8)
        for _, it in ipairs(flItems) do
            net.WriteUInt(it[1], 8)
            net.WriteEntity(it[2])
        end
        net.WriteUInt(cp1, 16)
        net.WriteUInt(cp2, 16)
        net.WriteUInt(cs1, 16)
        net.WriteUInt(cs2, 16)
    net.Send(ply)
    -- 快照已送达：解除弹窗幂等标记（此后若再次发生分歧可重新弹窗）
    ply._kardsDesyncNotified = nil
end

-- 客户端请求软重进（重启按钮）：仅接受本桌槽内玩家；对局已结束/未开始时无可重放
-- 快照（客户端退出牌桌流程已能恢复），静默忽略
net.Receive("KardsDesyncReenter", function(_, ply)
    local ent = net.ReadEntity()
    if not IsValid(ply) or not ply:IsPlayer() then return end
    if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    if ply._kardsTable ~= ent then return end
    local slot
    for s = 1, 2 do
        if ent.Slots and ent.Slots[s] == ply then slot = s break end
    end
    if not slot then return end
    if not ent._kardsFormalBattleStarted then return end
    ent:SendDesyncSnapshot(ply, slot)
end)

