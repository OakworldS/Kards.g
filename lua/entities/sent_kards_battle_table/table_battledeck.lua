-- Kards 战斗牌桌实体服务端代码：卡组槽段（re.md T-H1 拆分，由 init.lua include）
-- 职责：battle 模式卡组槽加载/生成（6 档厚度卡堆 + 总部 + 抽牌临时卡 + 手牌槽）、
-- 卡组存档读取与句柄构造（LoadPlayerDeck / DeckCardHandleFromFile / 缓存 B-M4）、
-- 卡堆档位切换、手牌/卡组剩余数同步。
-- 跨文件共享的 ENT 方法 helper（EnsureBattleDeckManifest / EnsureHandSlotManifest /
-- EnsureDeckPileSingleManifest）亦定义于此。

local ENT = scripted_ents.GetStored("sent_kards_battle_table").t

-- 指令卡服务端移除兜底延迟（2026-08-12 阶段 C）：客户端指令动画「展示槽（打出方
-- 视角左侧）停留 → 左下出场」总长 ≈ 0.35+2.0+0.6 = 2.95s，客户端动画 onComplete
-- 发送 KardsCommandExit 通知移除；本常量作兜底（+1s 缓冲），客户端未通知（断线/
-- 异常）时仍能销毁实体。
local CommandServerRemoveDelay = 4.0

-- 被消灭单位实体服务端移除兜底延迟（2026-08-13 用户规格）：场上目标死亡（防御 ≤0）
-- 后不立即消失，待客户端「最晚飘字（数值变动特效，FX_DURATION = 1.75s）结束 +0.5s」
-- 再消失——客户端计算精确延迟后发 KardsFieldDeathRemove 通知移除；本常量作兜底
--（1.75 + 0.5 + 0.75 缓冲），客户端未通知（断线/异常）时仍能销毁实体。
local FieldDeathServerRemoveDelay = 3.0

-- 隐蔽揭示动画延迟（2026-08-13）：隐蔽单位发起/被攻击时，数据层 SimAttack/SimEngage
-- 已先揭示（Hidden 清除），此处广播揭示事件后延迟 ApplyCombatOutcome——客户端在
-- 翻面动画（pitch 180→0，翻到一半 z 抬升防穿桌，见 cl_battle_stealth.lua）播完前
-- 不接收布局/属性广播，保证「先渲染正面 → 翻面 → 才继续（被）攻击动画」。
-- 取值须 ≥ 客户端翻面动画总时长（cl_battle_stealth.lua RevealFlipDur = 0.8）。
local RevealDelay = 0.9

-- ====================================================================
-- net 消息注册（SERVER 段）：总部揭晓开始
-- ====================================================================
if SERVER then
    -- 总部揭晓开始（客户端 StartHQReveal 发送）：总部离开卡堆顶 → 服务端把该槽剩余
    -- 卡数改为「不含总部」（卡堆档位计算含总部时 +1，见 SetDeckPileTier）。40→39
    -- 同为 40 档通常无视觉变化，此处保持幂等重算即可。
    net.Receive("KardsHQRevealStart", function(_, ply)
        local ent = net.ReadEntity()
        local slot = net.ReadUInt(8)
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent then return end
        -- 槽位归属校验（2026-08-18 规划 C7）：只允许本方槽触发 hqLeft（否则任意桌内
        -- 玩家可对任意槽置 hqLeft → 对方卡堆档位提前降档）。虚拟对手槽（无对手模式）
        -- 由本方客户端代为触发动画，参照 KardsHQRevealDone 放行。
        local isOwn = data.ent == ent and data.slot == slot
        if not isOwn then
            local vdeck = ent._kardsBattleDecks and ent._kardsBattleDecks[slot]
            if not (vdeck and vdeck.virtual) then return end
        end
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[slot]
        if deck then
            deck.hqLeft = true
            ent:SetDeckPileTier(slot)
        end
    end)

    -- 总部动画第二关键帧（客户端 StartHQReveal onKeyframe「switch」发送，仅参战者）：
    -- 把总部实体模型切换为 basic_card_unit（短卡 + UV 裁切）。服务端 ApplyImportedModel
    -- 权威（模型 ID/缩放同步所有客户端）；客户端渲染按各自本地 manifest——客户端
    -- onKeyframe 已同步 CloneUnit + ClearCache + PrefillUnitCrop 预填，切换时材质已就绪。
    net.Receive("KardsHQRevealDone", function(_, ply)
        local ent = net.ReadEntity()
        local slot = net.ReadUInt(8)
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        -- 仅本方总部（无对手模式：虚拟对手槽无玩家，其总部由本方客户端随揭晓动画代为
        -- 触发——客户端对两槽总部同时播放动画并发送 KardsHQRevealDone，服务端据此同步
        -- 虚拟总部的权威状态，否则动画结束后被服务端「隐藏 + 卡堆顶」状态覆盖）
        local isOwn = data and data.ent == ent and data.slot == slot
        if not isOwn then
            local vdeck = ent._kardsBattleDecks and ent._kardsBattleDecks[slot]
            if not (vdeck and vdeck.virtual) then return end
        end
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[slot]
        if not deck or not IsValid(deck.hqEnt) or not deck.hqUnitModelID then return end
        if KARDS.CardManifest and KARDS.CardManifest.CloneUnit then
            KARDS.CardManifest.CloneUnit(deck.hqUnitModelID, "kards_deck/hq_" .. deck.hqSafe)
            local ok = deck.hqEnt:ApplyImportedModel(deck.hqUnitModelID, 0.06) -- 世界 7.2×8.528
            if not ok then
                print(("[Kards] 总部 unit 模型应用失败: %s"):format(deck.hqUnitModelID))
            else
                -- 2026-08-13：总部词条展示串初写（模型切换为 basic_card_unit 后客户端
                -- 词条图标开始绘制；此后变化经 OnBattleStatsChanged / ApplyCombatOutcome 刷新）
                deck.hqEnt:SetNWString("Kards_UnitKeywords", ent:BuildUnitKeywordsStr(deck.hq))
            end
            -- 同步服务端权威状态为动画结束状态（2026-08-11 修复「总部动画结束后消失」）：
            -- 客户端总部动画为纯本地视觉（本地 SetNoDraw(false) + 本地动画 SetLocalPos），
            -- 服务端 hqEnt 自创建起恒为 NoDraw=true + 卡堆顶初始位置（见 LoadPlayerBattleDeck）。
            -- ApplyImportedModel 触发物理重建（RebuildPhysics/PhysicsInitBox）→ 服务端实体
            -- 状态网络同步 → 客户端收到服务端权威状态，把本地动画结果覆盖回「隐藏 + 卡堆顶」。
            -- 故此处显式把服务端权威状态设为动画结束状态（可见 + 支援阵线第 3 槽 + 卡面朝上）；
            -- 与单位路径（服务端实体初始即目标槽 + 可见）一致。yaw 由客户端 KardsFieldFacing
            -- 每帧接管（battleHQLeft 置位后，ApplyFacing 只改 yaw 保留 pitch——故服务端必须
            -- 把 pitch 归零，否则卡背朝上）；roll 保留。
            if ok and KARDS.Animation and KARDS.Animation.Board2D then
                local row = (slot == 1) and 1 or -1
                local supportPos = KARDS.Animation.Board2D:RelPos(3, row)
                if supportPos then
                    deck.hqEnt:SetNoDraw(false)
                    deck.hqEnt:SetLocalPos(supportPos)
                    local ang = deck.hqEnt:GetLocalAngles()
                    deck.hqEnt:SetLocalAngles(Angle(0, ang.y, ang.r)) -- pitch 归零：卡面朝上
                end
            end
        end
    end)

    -- 重新调度就绪（客户端先手揭晓序列结束后发送）：该玩家起手抽牌（先手 4 / 后手 5）。
    -- 数据层 SimDraw → OnBattleDraw 广播发牌（本方客户端走牌桌中间扇形选择，对方/观战走落手牌）
    net.Receive("KardsMulliganReady", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        ent:OnMulliganReady(data.slot)
    end)


    -- 重新调度确认（客户端点击「确认」按钮后发送）：被弃卡牌实体列表 → 服务端执行重新调度
    net.Receive("KardsMulliganSubmit", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local n = net.ReadUInt(8)
        local ents = {}
        for _ = 1, math.min(n, 7) do
            local e = net.ReadEntity()
            if IsValid(e) then ents[#ents + 1] = e end
        end
        ent:OnMulliganSubmit(data.slot, ents)
    end)

    -- 打出卡牌（客户端拖拽松手在非手牌区域发送）：手牌实体 + 目标槽位（0 = 指令）
    -- + 指向目标实体（B3：指向模式客户端携带；普通打出为 NULL）→ 服务端权威打出
    net.Receive("KardsPlayCard", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local cardEnt = net.ReadEntity()
        local slotIndex = net.ReadUInt(8)
        local targetEnt = net.ReadEntity() -- 指向目标实体（B3：指向模式携带；普通打出 NULL）
        -- 协程包装（2026-09-26 三选一）：开发/观星结算需在候选选择处挂起
        --（table_pick.lua BeginPick），选择回传后 coroutine.resume 续跑本轮结算。
        -- 非协程路径（BeginPick 内 coroutine.running() 为 nil）数据层缺省分支接管。
        -- 2026-10-04 抉择：同一 specify 通道合并 choicePicker（table_choice.lua BeginChoice），
        -- 抉择节点执行时挂起等待二选一，回传后按所选分支续跑。
        local co = coroutine.create(function()
            local specify = ent:BuildPickSpecify(ply, data.slot)
            local choiceSpecify = ent:BuildChoiceSpecify(ply, data.slot)
            if choiceSpecify then
                specify = specify or {}
                for k, v in pairs(choiceSpecify) do specify[k] = v end
            end
            ent:OnPlayCard(ply, data.slot, cardEnt, slotIndex, targetEnt, { specify = specify })
        end)
        local ok, err = coroutine.resume(co)
        if not ok then print("[Kards] 打出卡牌结算出错：" .. tostring(err)) end
    end)

    -- 反制激活/失活切换（客户端把反制拖出手牌区外松手发送）：手牌实体 + 期望状态
    -- → 服务端权威激活/失活（指挥点扣除/返还 + 拦截钩子注册/注销，见 M2）。
    -- 协程包裹（与 KardsPlayCard 一致）：激活效果链若含候选选择（开发/观星）需挂起，
    -- 选择回传后 coroutine.resume 续跑本轮结算。
    net.Receive("KardsCounterToggle", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local cardEnt = net.ReadEntity()
        local wantActive = net.ReadBool()
        local slot = data.slot
        -- 门控与 OnPlayCard 一致：对局已开始、先手回合已开始、当前回合方
        if not ent._kardsFormalBattleStarted or not ent._kardsFirstTurnStarted
            or ent._kardsTurnSlot ~= slot then
            return
        end
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[slot]
        local card = deck and deck.entCard and deck.entCard[cardEnt]
        if not card or card:GetType() ~= "counter_command" then return end
        -- 数据层手牌二次校验（与 OnPlayCard 防作弊口径一致）：卡须确实在本方手牌
        local playerID = (slot == 1) and "P1" or "P2"
        local hand = KARDS.Deck and KARDS.Deck:GetHand(ent.TableID, playerID)
        local inHand = false
        if hand then
            for _, h in ipairs(hand) do
                if h == card then inHand = true break end
            end
        end
        if not inHand then return end
        local co = coroutine.create(function()
            if wantActive then
                KARDS.Battle:SimActivateCounter(playerID, card, nil)
            else
                KARDS.Battle:SimDeactivateCounter(playerID, card)
            end
            -- 指挥点广播（含隐藏花费裁剪，见 M4）+ 回执实际状态（乐观显示以服务端为准）
            ent:BroadcastCommandPoints()
            net.Start("KardsCounterActive")
                net.WriteEntity(ent)
                net.WriteEntity(cardEnt)
                net.WriteBool(KARDS.Counter:IsActive(ent.TableID, card))
            net.Send(ply)
        end)
        local ok, err = coroutine.resume(co)
        if not ok then print("[Kards] 反制切换结算出错：" .. tostring(err)) end
    end)

    -- 部署模型交接（客户端 KardsCardPlayed 阶段 1 半程完成、切换小模型后发送，仅部署方）：
    -- 源手牌实体 cardEnt 已切换为小模型 unitEnt（各端本地各自执行阶段 2 动画），服务端
    -- 据此销毁源卡实体——子物体系统 1 秒淡出（客户端本地已 SetNoDraw，淡出不可见；
    -- 延迟销毁避免其他客户端阶段 1 动画中途被清导致不切换，2026-08-12）
    net.Receive("KardsDeploySwitch", function(_, ply)
        local ent = net.ReadEntity()
        local cardEnt = net.ReadEntity()
        local unitEnt = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        -- 仅销毁本桌子物体系统的卡牌实体（防客户端传任意实体被删）
        if not IsValid(cardEnt) or cardEnt:GetClass() ~= "sent_pmx_static_imported"
            or cardEnt:GetParent() ~= ent then return end
        -- 归属校验（2026-10-03 联机排查）：源手牌实体须属发送者本槽（Kards_DeckSlot 由
        -- SpawnHandSlotCard 写入，不依赖已被注销的 deck.entCard 映射）
        if cardEnt:GetNWInt("Kards_DeckSlot", 0) ~= data.slot then return end
        if not IsValid(unitEnt) or unitEnt:GetClass() ~= "sent_pmx_static_imported" then return end
        if ent._kardsChildSystem and not ent._kardsChildSystem:RemoveChild(cardEnt) then
            cardEnt:Remove()
        end
    end)

    -- 返回手牌动画完成（客户端 KardsReturnToHand 动画播完、仅所有者发送）：新卡实体
    -- 已落手牌位，服务端据此移除源战场实体（小模型单位）并清理 fieldCardEnts 映射。
    -- guard 幂等：老兵回退路径已由 OnBattleStatsChanged 移除实体/清映射（广播时源实体
    -- 已 NULL），兜底定时（BroadcastReturnToHand ReturnAnimServerRemoveDelay）同样清理。
    net.Receive("KardsReturnToHandDone", function(_, ply)
        local ent = net.ReadEntity()
        local cardEnt = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        if not IsValid(cardEnt) or cardEnt:GetClass() ~= "sent_pmx_static_imported"
            or cardEnt:GetParent() ~= ent then return end
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[data.slot]
        if not deck then return end
        local card = deck.entCard and deck.entCard[cardEnt]
        local fe = card and deck.fieldCardEnts and deck.fieldCardEnts[card]
        if IsValid(fe) then
            if ent._kardsChildSystem and not ent._kardsChildSystem:RemoveChild(fe) then
                fe:Remove()
            end
        end
        if card and deck.fieldCardEnts then deck.fieldCardEnts[card] = nil end
    end)

    -- 单位交战（客户端按下在场单位后松开在敌方单位上方发送，readme 7.1 交战）：
    -- 攻击方实体 + 防御方实体 → 服务端权威结算（判定/决策全在战斗系统 SimEngage）
    net.Receive("KardsUnitEngage", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local attackerEnt = net.ReadEntity()
        local defenderEnt = net.ReadEntity()
        ent:OnUnitEngage(ply, data.slot, attackerEnt, defenderEnt)
    end)

    -- 单位攻击总部（客户端按下在场单位后松开在敌方总部上方发送，readme 7.1）：
    -- 攻击方实体 → 服务端权威结算（判定/决策全在战斗系统 SimAttack；攻击总部不算交战）
    net.Receive("KardsUnitAttackHQ", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local attackerEnt = net.ReadEntity()
        ent:OnUnitAttackHQ(ply, data.slot, attackerEnt)
    end)

    -- 单位移动至前线（客户端按下在场单位后松开在前线区域发送，readme 7.1 操作）：
    -- 单位实体 → 服务端权威结算（判定/决策全在战斗系统 SimMoveToFrontline）
    net.Receive("KardsUnitMoveFront", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local unitEnt = net.ReadEntity()
        ent:OnUnitMoveFront(ply, data.slot, unitEnt)
    end)

    -- 单位撤退（客户端按下前线单位后松开在本方支援阵线区域发送，readme 7.1 操作）：
    -- 单位实体 → 服务端权威结算（判定/决策全在战斗系统 SimRetreat；支援阵线未满 →
    -- 移到/插入支援阵线最右侧，见 sh_battlefield.lua Retreat；满则拒绝提示）
    net.Receive("KardsUnitRetreat", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local unitEnt = net.ReadEntity()
        ent:OnUnitRetreat(ply, data.slot, unitEnt)
    end)

    -- 拖拽位置同步（拖拽方客户端节流发送，2026-08-12）：中继广播给「观战者」
    -- （非本桌双方牌手的其他客户端），接收端 SetLocalPos/SetLocalAngles 本地覆盖
    -- 展示「玩家握住的牌」；本方牌手（含对方）不接收——对方是竞争方，看到握住的
    -- 牌会泄露打牌意图。服务端仅做会话校验（发送者在该牌桌），不校验位置合法性。
    net.Receive("KardsDragSync", function(_, ply)
        local ent = net.ReadEntity()
        local card = net.ReadEntity()
        if not IsValid(ent) or not IsValid(card) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        -- 服务端节流（2026-08-18 规划 D1）：客户端节流可被作弊客户端绕过，满速率
        -- spam → 逐人转发放大带宽；上限 20Hz（50ms 滑动窗口）
        if CurTime() - (ply._kardsDragSyncLast or 0) < 0.05 then return end
        ply._kardsDragSyncLast = CurTime()
        -- 实体归属校验（2026-08-18 规划 D1）：拖拽卡须为发送者本槽手牌实体
        -- （entCard 映射；被弃实体 A1 已注销 → 拒绝，防借任意实体 spam）
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[data.slot]
        if not deck or not deck.entCard or not deck.entCard[card] then return end
        local pos = net.ReadVector()
        local ang = net.ReadAngle()
        -- 观战者 = 非本桌双方牌手的其他客户端；先收集再发——若无接收者（如标准
        -- 2 人对局）绝不能 net.Start，否则消息停留在「已开始未发送」状态，污染
        -- 服务端 net.messageStarted，导致后续所有 net.Start 警告并丢弃（2026-08-12）
        local targets = {}
        for _, p in ipairs(player.GetAll()) do
            if p ~= ent.Slots[1] and p ~= ent.Slots[2] then
                targets[#targets + 1] = p
            end
        end
        if #targets > 0 then
            net.Start("KardsDragSync")
                net.WriteEntity(ent)
                net.WriteEntity(card)
                net.WriteVector(pos)
                net.WriteAngle(ang)
            for _, p in ipairs(targets) do net.Send(p) end
        end
    end)

    -- 拖拽结束（拖拽方松手发送）：中继广播给观战者；returned=回手牌（接收端
    -- 恢复该卡扇形位），打出则接收端保持最后同步位置等 KardsCardPlayed 接管。
    net.Receive("KardsDragEnd", function(_, ply)
        local ent = net.ReadEntity()
        local card = net.ReadEntity()
        if not IsValid(ent) or not IsValid(card) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        -- 实体归属校验（2026-08-18 规划 D1）：拖拽结束卡须为发送者本槽手牌实体；
        -- 已打出（entCard 注销，观战者由 KardsCardPlayed 布局广播接管）拒绝无妨
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[data.slot]
        if not deck or not deck.entCard or not deck.entCard[card] then return end
        local returned = net.ReadBool()
        -- 同 KardsDragSync：先收集观战者，无接收者（2 人对局）不 net.Start，
        -- 避免残留未结束消息污染 net.messageStarted（2026-08-12）
        local targets = {}
        for _, p in ipairs(player.GetAll()) do
            if p ~= ent.Slots[1] and p ~= ent.Slots[2] then
                targets[#targets + 1] = p
            end
        end
        if #targets > 0 then
            net.Start("KardsDragEnd")
                net.WriteEntity(ent)
                net.WriteEntity(card)
                net.WriteBool(returned)
            for _, p in ipairs(targets) do net.Send(p) end
        end
    end)

    -- 手牌悬停同步（2026-08-14）：悬停方客户端在悬停变化时发送，中继给「除发送者
    -- 外的所有客户端」（对方牌手 + 观战者）——对方据此把其手牌中该卡的 z 抬升为
    -- 最高（用户规格「当敌方悬停时，将敌方鼠标悬停的手牌z增加」），观战者据此
    -- 看到双方悬停（「观战视角的手牌也增加…同样的增量」）。与 KardsDragSync 不同：
    -- 拖拽会泄露打牌意图故只给观战者，悬停仅抬升一张卡的高度、用户明确要求对方
    -- 可见。无悬停（鼠标离开手牌）时客户端发 WriteEntity(NULL) 清除；服务端写入
    -- 权威槽位（发送者座位槽，卡属其本方手牌）便于接收端定位。
    net.Receive("KardsHandHover", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local card = net.ReadEntity()
        if not IsValid(card) then card = nil end
        -- 实体归属校验（2026-08-18 规划 D2）：非清除（card 有效）时须为发送者本槽
        -- 手牌实体（entCard 映射）——否则作弊客户端可借任意实体刷中继
        if card then
            local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[data.slot]
            if not deck or not deck.entCard or not deck.entCard[card] then return end
        end
        -- 节流（2026-08-18 规划 D2）：上限 20Hz（悬停变化本就低频，防作弊 spam 中继）
        if CurTime() - (ply._kardsHandHoverLast or 0) < 0.05 then return end
        ply._kardsHandHoverLast = CurTime()
        -- 先收集目标再发——无接收者（仅 1 名参战者的无对手模式）绝不能 net.Start，
        -- 否则消息停留在「已开始未发送」状态污染 net.messageStarted（同 KardsDragSync）
        local targets = {}
        for _, p in ipairs(player.GetAll()) do
            if p ~= ply then targets[#targets + 1] = p end
        end
        if #targets > 0 then
            net.Start("KardsHandHover")
                net.WriteEntity(ent)
                net.WriteUInt(data.slot, 2)
                net.WriteEntity(card or NULL)
            for _, p in ipairs(targets) do net.Send(p) end
        end
    end)

    -- 本方提示中继给观战者（2026-08-12）：对局中本方提示（操作失败原因等，本地
    -- BattleHint.Push 触发）同步给观战者（非本桌双方牌手），对手不可见；观战端
    -- 牌桌中心 z+ 上方 3D2D 打字机显示「被提示玩家名：提示内容」。
    -- 同 KardsDragSync：先收集观战者，无接收者不 net.Start，避免污染 net.messageStarted。
    net.Receive("KardsHintRelay", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        if not ent._kardsFormalBattleStarted then return end -- 仅正式对局中提示中继
        local text = net.ReadString()
        if text == "" then return end
        -- 服务端限流 + 长度截断（2026-08-18 规划 D3）：观战刷屏保护——每秒 1 条、
        -- 单条 128 字符上限（本地 BattleHint 文本远短于此，正常操作不受影响）
        if CurTime() - (ply._kardsHintLast or 0) < 1 then return end
        ply._kardsHintLast = CurTime()
        if #text > 128 then text = text:sub(1, 128) end
        local targets = {}
        for _, p in ipairs(player.GetAll()) do
            if p ~= ent.Slots[1] and p ~= ent.Slots[2] then
                targets[#targets + 1] = p
            end
        end
        if #targets > 0 then
            net.Start("KardsHintObserver")
                net.WriteEntity(ent)
                net.WriteString(ply:Nick())
                net.WriteString(text)
            for _, p in ipairs(targets) do net.Send(p) end
        end
    end)

    -- 指令出场完成（客户端指令动画 onComplete 发送，仅本方槽位）：销毁指令卡实体。
    -- 2026-08-12 阶段 C：指令卡需在客户端完成「展示槽（打出方视角左侧）停留 → 左下
    -- 出场」动画后才移除
    -- （原打出即 1 秒淡出会把动画中的卡销毁）；服务端兜底定时见 OnPlayCard 指令分支。
    net.Receive("KardsCommandExit", function(_, ply)
        local ent = net.ReadEntity()
        local cardEnt = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[data.slot]
        if not deck then return end
        local guard = deck.commandExitPending and deck.commandExitPending[cardEnt]
        if guard then
            guard() -- 幂等（removedCmd 标志；兜底定时/本通知互不重复移除）
            deck.commandExitPending[cardEnt] = nil
        end
    end)

    -- 被消灭单位延迟移除完成（2026-08-13 用户规格）：客户端在其「最晚飘字（数值变动
    -- 特效）结束 +0.5s」后发送，移除死亡单位实体；服务端兜底定时见
    -- ScheduleFieldDeathRemove。2026-10-03 联机排查起只接受死亡实体所属槽玩家的通知，对方
    -- 槽无真人（虚拟对手）时允许在槽玩家代发，其余情形由兜底定时覆盖（GuardRemove 幂等）。
    net.Receive("KardsFieldDeathRemove", function(_, ply)
        local ent = net.ReadEntity()
        local unitEnt = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        -- 发送者须在槽内（2026-08-18 规划 D6）：观战者无槽位，禁止触发死亡单位移除
        -- （幂等 guard 仅视觉时点错乱，但观战者不应能影响对战双方视野）
        -- 且只认本槽 pending 表（2026-10-03 联机排查：对方玩家不得提前触发本槽实体移除；
        -- 对方槽无真人时代发仍生效，避免虚拟对手情形只剩兜底定时）
        if not data or data.ent ~= ent or not data.slot then return end
        for s = 1, 2 do
            local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[s]
            if deck then
                local guard = deck.fieldRemovePendingEnt and deck.fieldRemovePendingEnt[unitEnt]
                if guard and (s == data.slot or not IsValid(ent.Slots and ent.Slots[s])) then
                    guard() -- 幂等（removed 标志；兜底定时/本通知互不重复移除）
                    deck.fieldRemovePendingEnt[unitEnt] = nil
                    return
                end
            end
        end
    end)
end

-- ====================================================================
-- 卡组槽 manifest / 存档 / 句柄 helper（ENT 方法）
-- ====================================================================
-- 卡组槽/手牌槽/卡堆单张档的 manifest 副本统一由共享模块 KARDS.CardManifest
-- 提供（EnsureBattleDeck / EnsureHandSlot / EnsureDeckPileSingle，re.md T-H2），
-- 本文件不再维护同构薄包装。

-- 读取玩家卡组存档（decks/<SteamID>.json，KardsDeckSave 按玩家分文件写入）；无存档返回 nil
function ENT:LoadPlayerDeck(ply)
    if not IsValid(ply) then return nil end
    local json = file.Read("card_editor/decks/" .. self:DeckPlayerFileName(ply), "DATA")
    if not json then return nil end
    local ok, data = pcall(util.JSONToTable, json)
    if not ok or not data then return nil end
    return data
end

--[[
    卡组存档 → 数据层卡组池

    品质上限复验（2026-08-18 规划 D5）当前暂时关闭，Beta 版启用品质校验：
    存档为 data 目录明文 JSON，主机/本地可篡改卡牌品质计数（如 39 张全填 elite）；
    组卡网格入口有携带上限限制，加载路径（battle 对局 / 虚拟对手）需复验。
    启用后按「同卡品质携带上限」（DeckQualityLimit：normal 4 / limited 3 /
    special 2 / elite 1）逐张复验，超限部分丢弃——卡组总张数不足 39 时数据层不建，
    仅视觉放置（同现有非 39 张处理），不产生越限品质堆砌。

    @param deckData table|nil 卡组存档（deck.cards = { fileName, count }）
    @param playerID string 归属玩家 ID（"P1"/"P2"，句柄 owner）
    @return table 数据层卡组池（MockCard 数组，可能不足 39 张）
]]
function ENT:DeckPoolFromSave(deckData, playerID)
    local pool = {}
    if not deckData then return pool end
    for _, entry in ipairs(deckData.cards or {}) do
        for _ = 1, (entry.count or 1) do
            local h = self:DeckCardHandleFromFile(entry.fileName, playerID)
            if h then
                -- 品质校验（Beta 版启用）：去掉下方注释块首尾，并补回循环外的计数表
                --   local qualityCounts = {} -- [fileName] = 已计入张数
                --[[
                local q = (h.GetQuality and h:GetQuality()) or "normal"
                local cur = qualityCounts[entry.fileName] or 0
                if cur < (self.DeckQualityLimit[q] or 4) then
                    qualityCounts[entry.fileName] = cur + 1
                    pool[#pool + 1] = h
                end
                ]]
                pool[#pool + 1] = h
            end
        end
    end
    return pool
end

--[[
    卡组文件 fileName → 战斗句柄（MockCard；卡文件类型映射到接口类型：
    headquarter/command/counter_command 原样，infantry/bomber/fighter → 单位 + 单位类型）。

    句柄不缓存（2026-08-10 修复）：同 fileName 的多张卡（卡组重复牌）必须为独立
    句柄对象——数据层战场按句柄引用登记（SupportLines / FindCard 引用比较），共享
    句柄会把同 ID 第二张卡误判为已在场（部署报 already_on_field）。代价：对局开始
    每张卡解析一次文件（卡组编辑保存的 InvalidateAll 回调保留，后续如恢复缓存可按
    「效果解析结果」缓存而非句柄对象）。

    @param fileName string 卡组文件文件名
    @param owner    string 归属玩家 ID（"P1"/"P2"）
    @return table|nil 卡牌句柄
]]
function ENT:DeckCardHandleFromFile(fileName, owner)
    if not KARDS.CardEditor or not KARDS.CardEditor.SaveSystem then return nil end
    local info = KARDS.CardEditor.SaveSystem.GetCardInfo(fileName)
    if not info or not info.cardAppearance then return nil end
    local app = info.cardAppearance
    local ctype = app.cardType or "unit"
    local type, unitType = "unit", nil
    if ctype == "headquarter" then type = "headquarter"
    elseif ctype == "command" then type = "command"
    elseif ctype == "counter_command" then type = "counter_command"
    else unitType = ctype end -- infantry/bomber/fighter → 单位 + 单位类型
    local card = KARDS.CardInterface.CreateMockCard(fileName, type, owner, {
        attack = app.attack or 0, defense = app.defense or 0,
        cost = app.cost or 0, actionCost = app.actionCost,
        -- 卡面文本（2026-10-17 多语言）：中英双字段随卡牌句柄透传，NW 同步时分别下发
        name = app.name, nameEn = app.nameEn,
        description = app.specialEffect, descriptionEn = app.specialEffectEn,
        -- 国籍（readme 国籍/国家）：卡堆顶面卡背（SyncDeckTopBack → Kards_DeckTopBack
        -- NW → 客户端按国家卡背目录改写档位 manifest）与 H3/H5 国籍筛选依赖；
        -- 2026-08-12 补传（此前恒 nil → 顶卡卡背兜底 usa）
        country = app.country,
        unitType = unitType, keywords = app.keywords,
        combatModifiers = app.combatModifiers,
        -- 事件音效（编辑器属性页音效选择器保存，sounds = { deploy/attack/death/play/activate/trigger = 相对路径 }）
        sounds = app.sounds,
        -- 规模（卡牌外貌属性编辑器「规模」：small/medium/large；决定放牌/部署音效分配，
        -- 见 KARDS.CardSounds；GetCardScale 读取）
        cardScale = app.cardScale,
    })
    -- 解析效果路径并加载效果文件（canvas 保存时把 INE 导出路径写入 cardAppearance.effectPath）：
    -- LoadEffectForRuntime 得到 { nodes, connections, dataConnections, variables, functions }，
    -- 并应用保存端 BuildRuntimeData 迁移的节点运行时数据（base + runtimeData），
    -- 与 SimPlayCard 消费的 card.effect 结构同构，挂上后打出指令即走节点 base 解析执行；
    -- 无 effectPath 或文件缺失/节点为空 → 不挂（指令走演示效果分支）
    if app.effectPath and app.effectPath ~= "" then
        local effect = KARDS.CardEditor.SaveSystem.LoadEffectForRuntime(app.effectPath)
        if effect and effect.nodes and #effect.nodes > 0 then
            card.effect = effect
        else
            print(("[Kards] DeckCardHandleFromFile: 卡牌 %s 效果文件加载失败或为空（%s），指令将走演示效果"):format(
                fileName, tostring(app.effectPath)))
        end
    end
    return card
end

-- ====================================================================
-- 卡组槽（battle 模式）：P1/P2 双方卡组放置位（牌桌局部坐标，y=±1 行一侧）
-- 与相邻列卡牌间距 = 2×列间距(8.20) = 16.40；整叠在 xy 平面（绕 z）旋转 45°
-- ====================================================================
ENT.DeckSlotBase = {
    -- P1（y=+1 行，-x 端）：列5 x=-16.32 - 2×列间距 = -32.72（只交换 x，角度不变）
    [1] = Vector(-32.72, 12.80, 18.43),
    -- P2（y=-1 行，+x 端）：列1 x=16.48 + 2×列间距 = 32.88（只交换 x，角度不变）
    [2] = Vector(32.88, -12.80, 18.43),
}
-- 卡堆档位模型（性能优化，2026-08-09 起）：卡组槽不再逐张生成 40 个卡牌实体，改为
-- 预置「多档厚度卡堆模型」（6 档）+ 1 张总部实体 + 抽牌时临时生成被抽卡实体
-- （见 SetDeckPileTier / SpawnDeckDrawCard）。档位模型经 PMXStaticImporter.exe 导入
-- （garrysmod/data/pmx_static_importer/models/<model_id>/，非传统 Source .mdl），
-- exe 按文件夹名命名且不支持数字，故档位名用罗马数字：
--   40 张 = basic_card_xxxx（_xxx=30 / _xx=20 / _x=10 / _v=5；单张 = basic_card 副本）
-- 组合卡堆模型为 120x180 底面、原点在底面中心（mins z=-0.75），缩放 DeckPileScale 后
-- 底面 = 卡面 7.2x10.8、每张间隔 ≈0.1（与原 DeckSlotStepZ 一致，用户建模约定）；单张档
-- 用 basic_card 副本 kards_deckpile_1（36x54、原点几何中心、缩放 0.2），与普通卡一致。
ENT.DeckPileScale       = 0.06 -- 卡堆档位模型缩放（120x180 → 世界 7.2x10.8，与单卡一致）
ENT.DeckPileScaleSingle = 0.2  -- 单张档缩放（kards_deckpile_1 = basic_card 副本）
ENT.DeckPileTiers       = { 40, 30, 20, 10, 5, 1 } -- 档位（降序；切换时向上取最近档 snapUp）
ENT.DeckPileModelIDs    = {
    [40] = "basic_card_xxxx",
    [30] = "basic_card_xxx",
    [20] = "basic_card_xx",
    [10] = "basic_card_x",
    [5]  = "basic_card_v",
    [1]  = "kards_deckpile_1",
}
ENT.DeckSlotYaw   = { [1] = -135, [2] = 45 } -- 槽旋转：P1 逆时针 135°（原 45° 再各绕自身 z 旋转 180°）/ P2 顺时针 45°（原 -135° 再各绕自身 z 旋转 180°）；绕 z，yaw；若实测俯视方向相反则交换符号

-- ====================================================================
-- 开始手牌卡牌槽（battle 模式）：P1/P2 起始手牌的空卡占位（牌桌局部坐标，
-- 子物体系统空卡，仅作槽位视觉定位，不参与战斗），扇形分布模拟手部拿手牌。
-- 支持任意张数 HandSlotCount（1~9）均居中对称（中心偏移序号 k=(N+1)/2−i，
-- 见 CreateHandCardSlots）。数学原理（坐标系约定 / 槽位对称 / 弧匹配 / z 阶梯 /
-- 扇形旋转与符号）见文档《手牌分布的原理.md》§2-§4；本块仅保留各常量的取值含义。
-- 卡牌整体平行于地面平躺（HandSlotAngles roll=0，卡面朝上）：调整 yz 平面角度
-- 即可在保持扇形分布算法不变的同时让卡牌平行于地面（面法线朝上 → 玩家俯视位于
-- 法线正面 → 扇形旋转 ψ 取正，见 §4；原 135° 倾斜方案已废弃）。
-- ====================================================================
ENT.HandSlotBase    = Vector(0, 0, 30.5)          -- 手牌中心卡位置：桌面中心正上方（z 抬升于桌面顶；30.5 使 P1/P2 视角手牌整体更高、更贴近视线，可微调；任意 N 中心卡/对称中心恒落于此，见 §2）
ENT.HandSlotHalfY   = 18                          -- 南北分离半距：P1 槽 +y / P2 槽 −y（俯视上下，正对各自玩家；18 使 P1/P2 视角手牌更靠近牌桌中心，可微调，见 §2）
ENT.HandSlotCount   = 4                           -- 每名玩家手牌卡数（1~9 任意张数均居中；默认 4 为偶数，两中心卡之间对称）
ENT.HandSlotSpacing = 2.0                         -- 扇形布局相邻卡的局部 x（弧宽向）间距（卡宽 7.2，微重叠紧凑，见 §3）
ENT.HandSlotFanRadius = 50                        -- 扇形圆弧半径（圆心 = 基准位原点 + 局部 (0,+50)；勿改负：见 §3）
ENT.HandSlotZStep   = 0.1                         -- 卡面法线（局部 z）阶梯间隔：编号大的一侧最高层、编号小的一侧最低（见 §3）
ENT.HandSlotFanAngle = 30                         -- 扇形半展开角（°）：端点卡 ±α、中心 0°（玩家俯视方向；ψ 取正原因见 §4）
-- 槽位卡牌局部角度（父级为牌桌；卡面法线为本地 z+）：平行于地面平躺（卡面朝上、
-- 面向天空），仅作为扇形布局的位置/张开基准（弧朝向对方：P1 槽 +y、yaw0 弧凸向
-- −y；P2 槽 −y、yaw180 弧凸向 +y）。文字朝向不再由本常量决定——2026-08-10 曾
-- 交换两侧成 180/0 修「文字朝对方」，导致整个扇形左右镜像「整体反了」（用户
-- 实测），故文字方向与扇形布局解耦：客户端 HandFanPos 在最终角度叠加
-- HandSlotTextYaw=180° 使文字朝本方（见 cl_init.lua 常量区说明），本常量保持
-- 0/180 与客户端 HandFanPos / CreateHandCardSlots 同步。
-- 平躺后卡面法线朝上（Up=(0,0,1)），玩家俯视位于法线正面，是扇形旋转 ψ 取正的
-- 原因（见 §4；原 135° 倾斜时法线朝下、位于反面、ψ 取负，已废弃）。
ENT.HandSlotAngles = {
    [1] = Angle(0, 0, 0),     -- P1：平躺（卡面朝上；扇形布局位置基准，弧朝对方）
    [2] = Angle(0, 180, 0),   -- P2：平躺（卡面朝上；扇形布局位置基准，弧朝对方）
}
-- 观战视角扇形基准角度（最早方法，已废弃的 135° 倾斜方案）：观战视角使用独立于
-- P1/P2 视角的扇形分布计算方法（135° 基准 + ψ 绕面法线、ψ 取负），保持最早
-- "手拿手牌"观感。服务端创建手牌槽卡时按此独立计算扇形角度写入
-- Kards_LegacyFanAng NW（见 CreateHandCardSlots），客户端观战分支直接读取。
ENT.HandSlotLegacyAngles = {
    [1] = Angle(0, 0, 135),    -- P1：yz 倾斜 135°
    [2] = Angle(0, 180, 135),  -- P2：yz 倾斜 135°（yaw 180 镜像）
}

--[[
    卡堆档位模型的槽专属 modelID（2026-08-12 顶卡卡背需求）：原档位模型
    （basic_card_xxxx 导入模型 / kards_deckpile_1 单张档）manifest 全局唯一，两槽共用
    一份 manifest 与 image_path，无法分别表达两槽不同顶卡的国家卡背。现按槽克隆
    manifest（kards_deckpile_<tier>_s<slot>，几何 mesh 与 bounds 复制自原档位模型，
    客户端 PrepareDeckPileFiles 在 InitPostEntity 预置），顶面卡背（front 槽）按本槽
    顶卡国家动态改写（RewriteImagePaths + ClearCache，见 cl_init.lua）。

    @param tier number 档位（40/30/20/10/5/1，见 DeckPileTiers）
    @param slot number 槽位编号（1 = P1 / 2 = P2）
    @return string
]]
function ENT:DeckPileModelIDForSlot(tier, slot)
    return "kards_deckpile_" .. tier .. "_s" .. slot
end

--[[
    卡堆档位模型的世界高度（读 manifest bounds 高度 × 缩放）：
    档位模型原点在底面中心（mins z = -0.75 模型单位 = 底面下方 0.045 世界），实体原点放
    DeckSlotBase 时底面与旧「单卡逐张堆叠」的底面一致（见 LoadPlayerBattleDeck 注释）。
    读原档位模型 manifest（服务端本地存在；槽专属 manifest 由客户端/服务端按需生成，
    bounds 复制自原档位模型，此处无需按槽区分——高度一致）。

    @param tier number 档位（40/30/20/10/5/1，见 DeckPileTiers）
    @return number 世界高度（manifest 缺失返回 0）
]]
function ENT:DeckPileWorldHeight(tier)
    local modelID = self.DeckPileModelIDs[tier]
    if not modelID then return 0 end
    local scale = (tier == 1) and self.DeckPileScaleSingle or self.DeckPileScale
    local json = file.Read("pmx_static_importer/models/" .. modelID .. "/manifest.json", "DATA")
    if not json then return 0 end
    local m = util.JSONToTable(json)
    if not m or not m.bounds then return 0 end
    return (m.bounds.maxs[3] - m.bounds.mins[3]) * scale
end

--[[
    服务端本地生成槽专属档位 manifest（2026-08-12 顶卡卡背需求）：槽专属 modelID
    （kards_deckpile_<tier>_s<slot>）的 manifest 渲染纹理由客户端改写（按顶卡国家卡背，
    见 cl_init.lua PrepareDeckPileFiles / KardsBattleDeckPileMaterial）；服务端本地无需
    渲染纹理，只需 manifest 存在（ApplyImportedModel 校验、DeckPileWorldHeight 高度
    读原档位模型）。此处复制原档位 manifest（mesh_file / bounds 保留，image_path 指向
    usa 占位目录，客户端钩子随后改写）。单张档（tier 1）= basic_card 副本（Clone）。

    @param modelID string 槽专属档位 modelID（kards_deckpile_<tier>_s<slot>）
    @return boolean
]]
function ENT:EnsureDeckPileManifestForSlot(modelID)
    local tier = modelID:match("^kards_deckpile_(%d+)_s%d+$")
    if not tier then return false end
    tier = tonumber(tier)
    if tier == 1 then
        -- 单张档：basic_card 副本（Clone 共享入口，几何共享 basic_card mesh）
        return KARDS.CardManifest.Clone(modelID, "kards_deckpile/usa", "[Kards] 卡堆单张档")
    end
    local srcID = self.DeckPileModelIDs[tier]
    if not srcID then return false end
    local src = file.Read("pmx_static_importer/models/" .. srcID .. "/manifest.json", "DATA")
    if not src then return false end
    local m = util.JSONToTable(src)
    if not m then return false end
    m.model_id = modelID
    m.safe_display_name = modelID
    if m.submeshes then
        for _, sm in ipairs(m.submeshes) do
            if sm.name == "front" or sm.name == "back" then
                sm.image_path = "data/kards_deckpile/usa/" .. sm.name .. ".png"
            end
        end
    end
    file.CreateDir("pmx_static_importer/models/" .. modelID)
    return file.Write("pmx_static_importer/models/" .. modelID .. "/manifest.json", util.TableToJSON(m, true))
end

--[[
    卡堆档位实体（battle 模式）：预置多档厚度模型的其中一档，无碰撞无物理，
    与卡组槽卡同款（SOLID_NONE + 冻结运动 + RegisterChild 绑定牌桌）。
    每个玩家槽位预生成全部 6 档（同时仅一档可见，SetNoDraw 切换，见 SetDeckPileTier）。

    @param modelID string 档位模型 ID（DeckPileModelIDs）
    @param base    Vector 卡堆基准（牌桌局部，DeckSlotBase[slot]；实体原点 = 底面中心）
    @param yaw     number 局部 yaw 旋转角（DeckSlotYaw[slot]）
    @param slot    number 槽位编号（1/2）
    @param tier    number 档位（40/30/20/10/5/1）
    @param scale   number 模型缩放（档位模型 0.06 / 单张档 0.2）
    @return Entity|nil
]]
function ENT:SpawnDeckPile(modelID, base, yaw, slot, tier, scale)
    if not PMXStaticImporter or not PMXStaticImporter.NormalizeModelID then return nil end
    -- 槽专属档位 manifest：渲染纹理由客户端改写（按顶卡国家卡背，cl_init.lua
    -- PrepareDeckPileFiles / KardsBattleDeckPileMaterial）；服务端本地缺失时现场生成
    -- 占位 manifest（EnsureDeckPileManifestForSlot，mesh/bounds 复制原档位模型，
    -- image_path 指向 usa 占位目录），保证 ApplyImportedModel 校验通过。
    if not file.Exists("pmx_static_importer/models/" .. modelID .. "/manifest.json", "DATA") then
        if not self:EnsureDeckPileManifestForSlot(modelID) then return nil end
    end
    local ent = ents.Create("sent_pmx_static_imported")
    if not IsValid(ent) then return nil end
    -- 初始世界位置/朝向（随后子物体系统 RegisterChild 转相对定位；初始值保证生成即落位）
    ent:SetPos(self:LocalToWorld(base))
    ent:SetAngles(self:LocalToWorldAngles(Angle(0, yaw, 0)))
    ent:Spawn()
    local ok = ent:ApplyImportedModel(modelID, scale)
    if not ok then
        ent:Remove()
        return nil
    end
    -- 无碰撞无物理（同卡组槽卡）
    ent:SetSolid(SOLID_NONE)
    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    -- NW：模型副本标识 + 卡堆标记（客户端按 modelID 改写 front 槽为卡背图）+ 槽位
    ent:SetNWString("Kards_DeckModelID", modelID)
    ent:SetNWBool("Kards_IsBattleDeckPile", true)
    ent:SetNWInt("Kards_DeckSlot", slot)
    if self._kardsChildSystem and self._kardsChildSystem:RegisterChild(ent, base) then
        ent:SetLocalAngles(Angle(0, yaw, 0))
        return ent
    end
    ent:Remove()
    return nil
end

--[[
    卡堆档位切换（服务端权威）：按当前剩余卡数（含堆顶总部）向上取最近档
    （snapUp：卡堆视觉不短于实际卡数，只在跨越档位边界时向下跳一档——跳变发生在
    抽牌动画期间，被飞出的卡遮挡）。剩余卡数 = remaining +（总部仍在堆顶时 1）。
    无卡（size=0）时全部档位隐藏。

    @param slot number 槽位编号（1/2）
]]
function ENT:SetDeckPileTier(slot)
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck or not deck.pileEnts then return end
    local size = (deck.remaining or 0) + (deck.hqLeft and 0 or 1)
    local tier = 0
    if size > 0 then
        for _, t in ipairs(self.DeckPileTiers) do
            if t >= size then
                tier = t
                break
            end
        end
    end
    deck.currentTier = tier
    for t, ent in pairs(deck.pileEnts) do
        if IsValid(ent) then
            ent:SetNoDraw(t ~= tier)
        end
    end
end

--[[
    同步双方手牌数 / 卡组剩余数到 NW 变量（悬停卡堆信息面板数据源，客户端读取）：
    数据层权威（KARDS.Deck 纯逻辑层，多牌桌按 TableID 隔离），抽牌 / 重新调度等
    数量变化后调用。NW 变量自动广播给所有客户端（含观战者）。
    - Kards_HandCount_<slot>   ：该槽玩家手牌张数
    - Kards_DeckRemain_<slot>  ：该槽玩家卡组剩余普通卡数（不含总部；无卡组为 0）

    @param slot number 槽位编号（1 = P1 / 2 = P2）
]]
function ENT:SyncBattleCounts(slot)
    local playerID = (slot == 1) and "P1" or "P2"
    local deckSize = KARDS.Deck:DeckSize(self.TableID, playerID)
    local handSize = KARDS.Deck:HandSize(self.TableID, playerID)
    self:SetNWInt("Kards_HandCount_" .. slot, handSize)
    self:SetNWInt("Kards_DeckRemain_" .. slot, deckSize)
end

--[[
    同步卡堆顶卡的国家卡背到卡堆实体 NW（2026-08-12 取消统一 usa 卡背）：
    数据层权威（KARDS.Deck:Peek 取牌堆顶 = 数组末项，抽牌从末项取），顶卡变化
    （起手发牌 / 抽牌 / 重新调度补抽）后调用。客户端读取后改写该槽档位 manifest
    顶面（front 槽）为对应国家卡背图（materials/kards/cardbacks/<country>.png），
    观战者同样收到（NW 自动广播）。国家值 lower 归一化（编辑器保存值可能大小写
    混合，如默认 "SandBox"，卡背目录均为小写）。
    无卡组 / 卡组抽空 → ""（不兜底 usa：空堆时卡堆档位已全部隐藏（SetDeckPileTier
    size=0 → tier 0），卡组槽本身为空，无需占位卡背）。

    @param slot number 槽位编号（1 = P1 / 2 = P2）
]]
function ENT:SyncDeckTopBack(slot)
    local playerID = (slot == 1) and "P1" or "P2"
    local topCard = KARDS.Deck:Peek(self.TableID, playerID)
    local country = tostring(topCard and topCard:GetCountry() or ""):lower()
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck or not deck.pileEnts then return end
    for _, ent in pairs(deck.pileEnts) do
        if IsValid(ent) then
            ent:SetNWString("Kards_DeckTopBack", country)
        end
    end
end

--[[
    抽牌临时卡实体（battle 模式）：数据层抽牌（SimDraw / 额外抽取）回调时生成，
    位于当前可见卡堆顶部（卡堆视觉顶层），客户端抽牌动画将其抽到手牌并留在手牌位
    （卡面 + 3D2D 文字）。模型副本 kards_battledeck_<safeName>_d<serial> 唯一化
    （serial 每桌递增），manifest 改写不影响后续抽到的同卡。

    ★ 权威生成入口：凡是在对局世界中生成「保存的卡牌实体」（起手发牌 / 重新调度 /
    补抽 / 后续抽牌）一律必须使用本方法（或其封装的 SpawnBattleDeckCard），
    不得另新建其它卡牌实体生成方法——保证 manifest 副本唯一化 / NW 属性 /
    子物体绑定 / 动画坐标系全部走同一套标准链路。新增抽卡类功能一律经此入口。

    @param slot number 槽位编号（1/2）
    @param card table 抽到的卡牌句柄
    @return Entity|nil
]]
function ENT:SpawnDeckDrawCard(slot, card)
    local safeName = self:DeckSafeName(card:GetID())
    self._kardsDrawSerial = (self._kardsDrawSerial or 0) + 1
    local suffix = "_d" .. self._kardsDrawSerial
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local slotIdx = (slot == 1) and 1 or 2
    local base = self.DeckSlotBase[slotIdx]
    -- 位置：当前可见卡堆顶 + 半张卡厚度余量（避免与卡堆顶面 z-fight）
    local topZ = base.z + self:DeckPileWorldHeight(deck and deck.currentTier or 40) + 0.05
    local ent = self:SpawnBattleDeckCard(card, safeName, Vector(base.x, base.y, topZ), self.DeckSlotYaw[slotIdx], suffix)
    if IsValid(ent) then
        -- 绑定牌桌父级（与卡堆/总部一致）：位置/角度转为牌桌局部坐标系，动画两端
        --（服务端生成 / 客户端抽牌动画）在同一坐标系下工作，不受牌桌世界旋转影响；
        -- RegisterChild 会把局部角度重置为平躺（0,0,0），故绑定后重新施加卡堆 yaw。
        if self._kardsChildSystem and self._kardsChildSystem:RegisterChild(ent, Vector(base.x, base.y, topZ)) then
            -- pitch=180 卡背朝上（2026-08-12）：客户端抽牌动画可排队/delay（AnimPlayer
            -- 首帧快照「此刻」姿态），若此处保持平躺正面朝上，等待期间卡面会一直
            -- 暴露在卡组顶（用户反馈：额外抽牌动画等待时卡组顶渲染所抽牌正面）。
            -- 抽牌动画 t=0 关键帧本方/观战/爆牌/发牌均为 pitch180、对方两面卡背，
            -- 初始 180 与各分支动画起点一致，无跳变。
            ent:SetLocalAngles(Angle(180, self.DeckSlotYaw[slotIdx], 0))
        end
        ent:SetNWString("Kards_DeckSafeName", safeName) -- 抽牌动画翻面时找卡面文件（客户端 InitDrawCardFace）
        ent:SetNWInt("Kards_DeckSlot", slot)            -- 槽位（客户端卡背初始化/堆叠可见性按槽分组）
        -- 2026-08-18 规划 B1：不再写 Kards_CardFileName / Kards_CardType（NW 自动同步
        -- 所有客户端 = 对手/观战者可读手牌）；卡面文件/类型改由 KardsTableDrawFace
        -- 定向只发本方（客户端 cardFaces 表 + KARDS.GetCardIdentity 读取）
        -- 登记临时卡：玩家退出/牌桌销毁时经 ExitSlot / OnRemove 清理（动画结束后卡留在手牌位）
        if deck then
            deck.drawEnts = deck.drawEnts or {}
            deck.drawEnts[#deck.drawEnts + 1] = ent
            -- 实体 → 卡牌句柄（重新调度确认时按实体映射回卡牌，服务端本地；weak keys 防泄漏）
            deck.entCard = deck.entCard or setmetatable({}, { __mode = "k" })
            deck.entCard[ent] = card
            -- 卡牌句柄 → 实体（打出时按卡反查手牌实体；weak keys 防泄漏）
            deck.cardEnt = deck.cardEnt or setmetatable({}, { __mode = "k" })
            deck.cardEnt[card] = ent
        end
    end
    return ent
end

--[[
    卡组槽卡牌实体（battle 模式）：独立模型副本（kards_battledeck_<safeName>），
    仅显示卡背（front=back=卡背图，客户端 Think 钩子复制卡背 PNG 落盘），
    不渲染任何 3D2D 文字（不广播 KARDS_Battle_CardOverlayAdd、不绑定 Overlay）、
    不设 Kards_CardRole="deck"（组卡材质钩子跳过）——性能优化，仅以卡背区分每张牌。
    堆叠旋转：局部 yaw（xy 平面绕 z 旋转 ±45°）。

    @param card     table 卡牌对象（_CreateDeckCard 轻量句柄）
    @param safeName string DeckSafeName 安全标识
    @param relPos   Vector 相对坐标（牌桌局部）
    @param yaw      number 局部 yaw 旋转角（度）
    @param modelSuffix string|nil 模型副本后缀（重复卡 _i 唯一化：manifest 独立，
            抽牌时客户端只改写被抽卡的 manifest 不影响堆中同卡；缺省 ""）
    @return Entity|nil
]]
function ENT:SpawnBattleDeckCard(card, safeName, relPos, yaw, modelSuffix)
    local modelID = "kards_battledeck_" .. safeName .. (modelSuffix or "")
    if not KARDS.CardManifest.EnsureBattleDeck(modelID, safeName) then
        print("[Kards] 卡组槽卡 manifest 创建失败: " .. modelID)
        return nil
    end
    if not PMXStaticImporter or not PMXStaticImporter.NormalizeModelID then
        return nil
    end
    local ent = ents.Create("sent_pmx_static_imported")
    if not IsValid(ent) then return nil end
    -- 初始世界位置/朝向（随后子物体系统 RegisterChild 转相对定位；初始值保证生成即落位）
    ent:SetPos(self:LocalToWorld(relPos))
    ent:SetAngles(self:LocalToWorldAngles(Angle(0, yaw, 0)))
    ent:Spawn()
    local ok = ent:ApplyImportedModel(modelID, KARDS.BattleRender.Defaults.CardScale)
    if not ok then
        ent:Remove()
        return nil
    end
    -- 无碰撞无物理（同组卡卡牌）
    ent:SetSolid(SOLID_NONE)
    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    -- NW：卡背国家（客户端卡背初始化；国家公开，非卡牌身份）+ 模型副本标识 +
    -- 卡组槽卡标记（客户端卡背初始化）。2026-08-18 规划 B1：不写 Kards_CardName /
    -- Kards_CardFileName / Kards_CardType（NW 自动同步所有客户端 = 对手/观战者可读
    -- 手牌），手牌卡面标识改由 KardsTableDrawFace 定向只发本方（客户端 cardFaces 表）。
    ent:SetNWString("Kards_CardCountry", tostring(card:GetCountry() or ""):lower())
    ent:SetNWString("Kards_DeckModelID", modelID)
    ent:SetNWString("Kards_CardRole", "battledeck") -- 卡牌大类枚举（re.md T-M1）：仅卡背初始化，不绑文字
    return ent
end

--[[
    生成单张手牌槽卡牌实体（battle 模式）：独立模型副本 kards_handslot
    （front 缺失白色兜底"正面"占位，back=UK 卡背图，卡牌平躺时朝上为正面/朝下为
    卡背），无碰撞无物理；客户端 Think 钩子（cl_init.lua KardsHandSlotCardMaterial）
    复制 UK 卡背 PNG 落盘 + ClearCache 重建 renderable 后按 image_path 加载卡背。
    不渲染 3D2D 文字（不设 Kards_CardRole="deck"）。
    实体随后由 CreateHandCardSlots 经子物体系统 RegisterChild 绑定牌桌为父级。

    @param relPos Vector 相对坐标（牌桌局部，z = 抬升后槽位高度）
    @param angle  Angle 局部角度（牌桌父级，见 HandSlotAngles：平躺 + P2 卡面内 180°）
    @param slot   number 槽位编号（1/2；写 Kards_DeckSlot NW 供客户端三视角规则
                  cl_perspective.lua ApplyHandFacing 区分本方/对方手牌）
    @return Entity|nil
]]
function ENT:SpawnHandSlotCard(relPos, angle, slot)
    local modelID = "kards_handslot"
    if not KARDS.CardManifest.EnsureHandSlot(modelID) then
        print("[Kards] 手牌槽卡 manifest 创建失败: " .. modelID)
        return nil
    end
    if not PMXStaticImporter or not PMXStaticImporter.NormalizeModelID then
        return nil
    end
    local ent = ents.Create("sent_pmx_static_imported")
    if not IsValid(ent) then return nil end
    -- 初始世界位置/朝向（随后子物体系统 RegisterChild 转相对定位；初始值保证生成即落位）
    ent:SetPos(self:LocalToWorld(relPos))
    ent:SetAngles(self:LocalToWorldAngles(angle))
    ent:Spawn()
    local ok = ent:ApplyImportedModel(modelID, KARDS.BattleRender.Defaults.CardScale)
    if not ok then
        ent:Remove()
        return nil
    end
    -- 无碰撞无物理（同卡组槽卡）
    ent:SetSolid(SOLID_NONE)
    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    -- NW：模型副本标识 + 手牌槽卡标记（客户端卡背初始化，见 cl_init.lua）
    -- + 归属槽位（客户端三视角规则区分本方/对方，见 cl_perspective.lua ApplyHandFacing）
    ent:SetNWString("Kards_DeckModelID", modelID)
    ent:SetNWBool("Kards_IsHandSlotCard", true)
    if slot == 1 or slot == 2 then
        ent:SetNWInt("Kards_DeckSlot", slot)
    end
    return ent
end

--[[
    进入战斗模式时加载该玩家卡组（TryEnterSlot 调用）：
      1. 数据层：懒初始化对局骨架（StartBattle）→ 有卡组存档且为 39 张 → 普通卡句柄
         喂给 SimSetupDeck（sh_deck 约定 39 张，不含总部）；无存档/非 39 张 → 数据层不建
         （空抽触发士气伤害）
      2. 视觉（性能优化方案 2026-08-09 起）：卡组槽不再逐张生成 40 个卡牌实体，改为
         「6 档厚度卡堆模型 + 1 张隐藏总部 + 抽牌临时实体」（见 L1258 起常量注释与
         SpawnDeckPile / SetDeckPileTier / SpawnDeckDrawCard）：
         - 每槽预生成全部 6 档卡堆实体（同时仅一档可见，SetNoDraw 切换）；档位按
           剩余卡数 snapUp 向上取最近档（剩余 = deck.remaining +（总部在堆顶时 1））
         - 有卡组：总部实体仍为独立卡牌但初始 SetNoDraw(true) 隐藏（堆叠厚度已由
           档位模型表现）；对局开始头像揭晓完成后客户端播放总部动画
           （cl_init.lua StartHQReveal 显式 SetNoDraw(false) + 发送 KardsHQRevealStart，
           服务端据此把剩余卡数改为「不含总部」）移动到头像旁落位支援阵线
         - 无卡组：不生成总部实体，卡堆档位实体全部隐藏（remaining=0 → tier 0，
           卡组槽本身为空，无需占位卡背，见下方数据块注释）
      3. 抽牌：服务端生成一张临时卡实体（位于当前可见卡堆顶，manifest 后缀 _d<serial>
         唯一化），客户端抽牌动画将其移入手牌并留在手牌位（卡面 + 3D2D 文字）
      4. 卡堆顶面卡背 = 数据层顶卡国家卡背（SyncDeckTopBack → Kards_DeckTopBack NW →
         客户端按国家卡背目录改写档位 manifest front 槽，2026-08-12 取消统一 usa）

    @param ply  Player 进入玩家
    @param slot number 槽位编号（1 = P1 / 2 = P2）
]]
function ENT:LoadPlayerBattleDeck(ply, slot)
    if not IsValid(ply) then return end
    -- 懒初始化对局数据层骨架（每牌桌一次；KARDS.Battle 为单例，多牌桌并发不在本次范围）
    if not self._kardsBattleStarted then
        self._kardsBattleStarted = true
        KARDS.Battle:StartBattle(self.TableID, { "P1", "P2" })
        -- 渲染层订阅战斗事件（re.md B-M3）：卡牌进入/离开战场时自动维护 CardEnts
        -- （入战场 SpawnCard 生成实体 / 离场移除实体；经 EffectRegistry 按本桌隔离，
        --  同桌重复进入幂等——注册条目同 ID 覆盖；随下次 StartBattle 的 Clear 一并清理）
        if KARDS.BattleRender and KARDS.BattleRender.BindBattleEvents then
            KARDS.BattleRender:BindBattleEvents(self.TableID)
        end
        -- 返回手牌动画：数据层 SimReturnToHand 触发 ReturnToHand 事件 → 实体层创建
        -- 正常卡模型动画载体并广播（同 CardEnter/CardLeave 注册式事件通道，随下次
        -- StartBattle 的 EffectRegistry.Clear 一并清理）
        if KARDS.EffectRegistry and KARDS.EffectRegistry.Register then
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.ReturnToHand,
                "table_return_to_hand_anim", { handler = function(payload)
                    self:BroadcastReturnToHand(payload and payload.card)
                end })
            -- 收缴动画（2026-10-15）：数据层 SimConfiscate 触发 Confiscate 事件 → 实体层在源
            -- 小模型原位创建完整卡载体并延迟广播（同 ReturnToHand 注册式事件通道）
            -- 处理器载荷：{ card = 单位句柄, newOwner = 收缴方, handTotal = 插入前手牌数 }
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.Confiscate,
                "table_confiscate_anim", { handler = function(payload)
                    self:BroadcastConfiscate(payload)
                end })
            -- 洗入动画（2026-09-26 缺口 D）：数据层 shuffleInto 三来源统一经 ShuffleInto
            -- 事件通知，实体层建动画载体 + 广播 KardsShuffleInto（同 ReturnToHand 模式）
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.ShuffleInto,
                "table_shuffle_into", { handler = function(payload)
                    self:BroadcastShuffleInto(payload)
                end })
            -- 节点弃牌 / 爆牌单卡飞出（2026-09-26 缺口 E）：右槽飞出，无「手牌已满」提示
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.PileCardRemoved,
                "table_pile_card_removed", { handler = function(payload)
                    self:BroadcastPileCardFlyOut(payload)
                end })
            -- 手牌弃牌飞出（2026-10-06 用户规格）：弃掉的手牌移到该方视角右槽，停留 1 秒
            -- 后顺时针出场（所有查看端一致）
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.HandCardDiscarded,
                "table_hand_card_discarded", { handler = function(payload)
                    self:BroadcastHandCardFlyOut(payload)
                end })
            -- 加入阵线标记（2026-09-26 缺口 F）：节点效果拉入场的卡登记待播加入动画，
            -- 由 CardEnter 收口的 table_layout_enter 在布局广播后消费（见该处理器）
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.JoinField,
                "table_join_field", { handler = function(payload)
                    if not IsValid(self) then return end
                    local cards = payload and payload.cards
                    if type(cards) ~= "table" then return end
                    self._kardsPendingJoin = self._kardsPendingJoin
                        or setmetatable({}, { __mode = "k" })
                    for _, c in ipairs(cards) do self._kardsPendingJoin[c] = true end
                end })
            -- 进入前线被拒提示（2026-09-26 缺口 F）：软失败后向发起方定向提示
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.FrontlineDenied,
                "table_frontline_denied", { handler = function(payload)
                    if not IsValid(self) then return end
                    local player = payload and payload.player
                    if not player then return end
                    self:SendActionHint((player == "P2") and 2 or 1, "frontline_occupied")
                end })
            -- 单位攻击冲刺（2026-09-26 缺口 G）：效果路径（节点「交战」「战斗」）经事件桥接，
            -- 与手动路径（OnUnitEngage / OnUnitAttackHQ 直接调用）共用 BroadcastUnitAction
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.UnitAction,
                "table_unit_action", { handler = function(payload)
                    if not IsValid(self) then return end
                    self:BroadcastUnitAction(payload and payload.attacker, payload and payload.target)
                end })
            -- 老兵升级动画（2026-09-26 缺口 I）：数据层 SimVeteran 触发 → 广播单位实体 +
            -- 三个变动值与新值，客户端播 z 上升 + 白色飘字 + 回落
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.UnitElevate,
                "table_unit_elevate", { handler = function(payload)
                    if not IsValid(self) then return end
                    self:BroadcastUnitElevate(payload and payload.card, payload)
                end })
            -- 卡牌整体转换（2026-09-26 缺口 J）：数据层 SimConvert 原地置换后触发 →
            -- 实体层生成新战场实体并广播翻面交接动画；旧实体保留到动画结束再清理
            --（不触发 CardLeave，避免渲染层提前移除旧实体）
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.UnitConvert,
                "table_unit_convert", { handler = function(payload)
                    if not IsValid(self) then return end
                    local oldCard = payload and payload.oldCard
                    local newCard = payload and payload.newCard
                    if not oldCard or not newCard then return end
                    local oldEnt = self:BattleEntByCard(oldCard)
                    local newEnt = IsValid(oldEnt) and self:SpawnConvertedUnit(oldCard, newCard) or nil
                    if not IsValid(newEnt) then
                        -- 实体生成失败（旧实体已无效 / 模型应用失败）：退化为无动画，
                        -- 数据层置换已生效，布局广播兜底
                        self:BroadcastFieldLayout(1, "P1")
                        self:BroadcastFieldLayout(2, "P2")
                        self:BroadcastFrontlineLayout()
                        return
                    end
                    self:BroadcastUnitConvert(newCard, oldEnt, newEnt)
                    -- 旧实体清理（2026-09-27 修复：原 1.0 秒只覆盖动画总时长 0.6 秒，客户端消息
                    -- 延迟超过 0.4 秒时旧实体在动画中途消失，AnimPlayer 清掉 clip，中断发生在
                    -- 90° 之前则换显从未发生。改为 2.5 秒，与洗入 / 卡堆飞出两条载体兜底清理同口径）
                    local oldSlot = ((oldCard.GetOwner and oldCard:GetOwner()) == "P2") and 2 or 1
                    local tableID = self.TableID
                    timer.Simple(2.5, function()
                        if IsValid(self) then
                            local d = self._kardsBattleDecks and self._kardsBattleDecks[oldSlot]
                            if d and d.fieldCardEnts then d.fieldCardEnts[oldCard] = nil end
                        end
                        if KARDS.BattleRender and KARDS.BattleRender.CardEnts
                            and KARDS.BattleRender.CardEnts[tableID] then
                            KARDS.BattleRender.CardEnts[tableID][oldCard] = nil
                        end
                        if IsValid(oldEnt) then oldEnt:Remove() end
                    end)
                end })
        end
        -- 战场布局收口（2026-08-18 规划 C1-C4）：效果召唤/移除/撤退/回手路径不经实体层
        -- ApplyCombatOutcome / OnBattleStatsChanged，客户端布局表不更新（双方视角一致地
        -- 错误）。统一在 CardEnter / CardLeave 事件消费处补布局广播 + 实体映射维护：
        --   - CardEnter  效果召唤/入场单位（渲染层 spawnCard 已生成实体）→ 登记实体层
        --     fieldCardEnts（BroadcastFieldLayout 反查）+ 补 Kards_IsFieldCard/DeckSlot
        --     NW（客户端视角朝向驱动）；延迟一帧等渲染层先创建实体（同事件 handler 无序）
        --   - CardLeave  离场/撤退/回手 → 真离场时清理 fieldCardEnts + 广播布局重排；
        --     手牌计数（SimReturnToHand 手牌插入后才触发 CardLeave，时序安全）
        -- 玩家路径（打牌/攻击/移动/撤退）已有广播，重复广播幂等无害——客户端对相同
        -- 目标位置跳过动画（cl_init.lua KardsFieldLayout 判定，existing.toPos 相同跳过）。
        if KARDS.EffectRegistry and KARDS.EffectRegistry.Register then
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.CardEnter,
                "table_layout_enter", { handler = function(payload)
                    local card = payload and payload.card
                    if not card or not IsValid(self) then return end
                    local owner = (card.GetOwner and card:GetOwner()) or "P1"
                    local slot = (owner == "P2") and 2 or 1
                    timer.Simple(0, function()
                        if not IsValid(self) then return end
                        local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
                        if not deck then return end
                        if not deck.fieldCardEnts or not deck.fieldCardEnts[card] then
                            -- 渲染层 spawnCard 生成的实体（打牌复用拦截时不存在 → 跳过，
                            -- 部署路径 L1694 已登记 unitEnt）
                            local rent = KARDS.BattleRender and KARDS.BattleRender.CardEnts
                                and KARDS.BattleRender.CardEnts[self.TableID]
                                and KARDS.BattleRender.CardEnts[self.TableID][card]
                            if IsValid(rent) then
                                deck.fieldCardEnts = deck.fieldCardEnts
                                    or setmetatable({}, { __mode = "k" })
                                deck.fieldCardEnts[card] = rent
                                rent:SetNWBool("Kards_IsFieldCard", true)
                                rent:SetNWInt("Kards_DeckSlot", slot)
                            end
                        end
                        self:BroadcastFieldLayout(slot, owner)
                        self:BroadcastFrontlineLayout()
                        -- 加入阵线动画（2026-09-26 缺口 F）：JoinField 事件已登记待播标记，
                        -- 此处布局广播之后消费并广播加入动画（与既有部署动画分离）
                        if self._kardsPendingJoin and self._kardsPendingJoin[card] then
                            self._kardsPendingJoin[card] = nil
                            self:BroadcastJoinAnim(card)
                        end
                    end)
                end })
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.CardLeave,
                "table_layout_leave", { handler = function(payload)
                    local card = payload and payload.card
                    if not card or not IsValid(self) then return end
                    local owner = (card.GetOwner and card:GetOwner()) or "P1"
                    local slot = (owner == "P2") and 2 or 1
                    -- C1 修复（2026-09-27）：节点「消灭」经 SimRemoveFromField(card, "death")
                    -- 直接离场，不经 ApplyCombatOutcome / OnBattleStatsChanged（属性未变），原先
                    -- 没有阵亡演出（无死亡音效、无 KardsFieldDeath 精确延迟移除）。此处按
                    -- CardLeave 的 reason 分流：death 时补一次延迟移除演出；调用前先刷死亡防御
                    -- NW（客户端防御飘字依赖该值，与 ApplyCombatOutcome 的顺序一致）。
                    -- ScheduleFieldDeathRemove 已幂等，战斗路径稍后再次调用不重复播音效与广播。
                    if payload and payload.reason == "death"
                        and card.IsAlive and not card:IsAlive() then
                        local deathEnt
                        for s = 1, 2 do
                            local dd = self._kardsBattleDecks and self._kardsBattleDecks[s]
                            if dd and dd.fieldCardEnts and dd.fieldCardEnts[card] then
                                deathEnt = dd.fieldCardEnts[card]
                                break
                            end
                        end
                        if not IsValid(deathEnt) then
                            local rent = KARDS.BattleRender and KARDS.BattleRender.CardEnts
                                and KARDS.BattleRender.CardEnts[self.TableID]
                                and KARDS.BattleRender.CardEnts[self.TableID][card]
                            if IsValid(rent) then deathEnt = rent end
                        end
                        if IsValid(deathEnt) then
                            self:SyncUnitNW(card, deathEnt)
                            self:ScheduleFieldDeathRemove(card, deathEnt)
                        end
                    end
                    -- 真离场（不在任何阵线）才清理映射：撤退（前线→支援阵线）也触发
                    -- CardLeave 但卡仍在场，映射保留（ApplyCombatOutcome SyncUnitNW 反查）
                    if not (KARDS.Battlefield and KARDS.Battlefield:FindCardZone(self.TableID, card)) then
                        for s = 1, 2 do
                            local d = self._kardsBattleDecks and self._kardsBattleDecks[s]
                            if d and d.fieldCardEnts then d.fieldCardEnts[card] = nil end
                        end
                    end
                    -- 手牌计数（C3：SimReturnToHand 后手牌数已更新）+ 布局重排（C3/C4）
                    self:SyncBattleCounts(slot)
                    for i, playerID in ipairs({ "P1", "P2" }) do
                        self:BroadcastFieldLayout(i, playerID)
                    end
                    self:BroadcastFrontlineLayout()
                end })
            -- C1：SimShuffleField 随机排列（无 CardEnter/CardLeave）→ 布局重排广播
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.LayoutChanged,
                "table_layout_changed", { handler = function()
                    if not IsValid(self) then return end
                    for i, playerID in ipairs({ "P1", "P2" }) do
                        self:BroadcastFieldLayout(i, playerID)
                    end
                    self:BroadcastFrontlineLayout()
                end })
            -- C5：节点效果 burn / shuffleInto 直接改手牌/卡组数组 → 计数 NW 同步
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.CountsChanged,
                "table_counts_changed", { handler = function(payload)
                    if not IsValid(self) then return end
                    local player = payload and payload.player
                    if not player then return end
                    self:SyncBattleCounts((player == "P2") and 2 or 1)
                end })
            -- C6：亡计/倒计时/event_monitor 触发的指挥点效果不经打牌广播路径 → 补指挥点广播
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.CommandPointsChanged,
                "table_command_points_changed", { handler = function()
                    if IsValid(self) then self:BroadcastCommandPoints() end
                end })
            -- D7：作弊停止对局 → 向参战玩家广播冻结提示 + 停回合超时（2026-08-18）
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.BattleStopped,
                "table_battle_stopped", { handler = function(payload)
                    if not IsValid(self) then return end
                    self:ClearTurnTimer() -- 冻结后不再自动推进回合
                    local cheater = payload and payload.cheater or "unknown"
                    for _, p in ipairs(player.GetAll()) do
                        if p == self.Slots[1] or p == self.Slots[2] then
                            KARDS.TableSync.Notify(p, "msg.cheat_frozen", tostring(cheater))
                        end
                    end
                end })
        end
        -- 对局结束（总部被摧毁）：数据层 CheckHQDestroyed 判定胜负后触发 GameOver
        -- 事件 → 实体层移除被摧毁总部 + 广播结算（客户端结算动画），随下次
        -- StartBattle 的 EffectRegistry.Clear 一并清理）
        if KARDS.EffectRegistry and KARDS.EffectRegistry.Register then
            KARDS.EffectRegistry.Register(self.TableID, KARDS.EffectRegistry.EVENTS.GameOver,
                "table_game_over", { handler = function(payload)
                    self:OnGameOver(payload and payload.winner, payload and payload.loser,
                        payload and payload.destroyed)
                end })
        end
    end
    -- 首次进入对战时不再建立空手牌槽（占位空卡）：起手发牌/抽牌经 OnBattleDraw 生成
    -- 真实卡牌实体并落手牌位（2026-08-10 移除占位空手牌，见重新调度流程）
    -- 抽牌回调（SimDraw / 额外抽取 → 通知客户端抽牌动画；幂等每桌一次）
    -- overdraw（第三参数）= 本次抽牌是否爆牌（手牌已达上限），随广播发给客户端
    if not self._kardsDrawCallbackRegistered then
        self._kardsDrawCallbackRegistered = true
        KARDS.Battle:SetDrawCallback(self.TableID, function(playerID, drawn, overdraw, overdrawnCards, noDeckConsume)
            self:OnBattleDraw(playerID, drawn, overdraw, overdrawnCards, noDeckConsume)
        end)
    end
    -- 延时效果证明回调（keepTrigger / turn「等待」在回合时间刻触发 → 向来源卡归属玩家
    -- 播放「来源卡入场」证明动画；幂等每桌一次，见 ENT:BroadcastDelayedProof）
    if not self._kardsDelayedProofCallbackRegistered then
        self._kardsDelayedProofCallbackRegistered = true
        KARDS.Battle:SetDelayedProofCallback(self.TableID, function(card)
            self:BroadcastDelayedProof(card)
        end)
    end
    -- 弃牌选择回调（SimDiscard 无卡且无数值序数时为「让玩家选择」；幂等每桌一次）：
    -- 进入 table_discard.lua 选择会话（广播 KardsDiscardOffer，玩家点击手牌 +「确认」回传）
    if not self._kardsDiscardCallbackRegistered then
        self._kardsDiscardCallbackRegistered = true
        KARDS.Battle:SetDiscardCallback(self.TableID, function(playerID)
            return self:BeginDiscardPick(playerID)
        end)
    end
    local playerID = (slot == 1) and "P1" or "P2"
    -- 1) 数据层：有卡组存档且为 39 张 → SimSetupDeck（洗牌一次，此后顺序固定）
    local deck = self:LoadPlayerDeck(ply)
    -- 品质上限复验（2026-08-18 规划 D5）：当前关闭，Beta 版启用
    local pool = self:DeckPoolFromSave(deck, playerID)
    -- 对局开始资格：存档存在、卡牌数为 39、且有总部（总部是胜负判定载体；
    -- 无总部时对局无法结束）。品质校验当前关闭，Beta 版启用后此处自动按复验结果判定。
    -- SetReady 据此拒绝空卡组准备（2026-10-17）。
    local hasValidDeck = deck ~= nil and #pool == 39 and deck.hq ~= nil
    if deck and #pool == 39 then
        KARDS.Battle:SimSetupDeck(playerID, pool)
    elseif deck then
        print(("[Kards] 卡组槽: 卡组 %s 非 39 张（%d），数据层跳过（仅视觉放置）"):format(tostring(deck.name), #pool))
    else
        KARDS.TableSync.Notify(ply, "msg.no_deck_save")
    end
    -- 2) 视觉：6 档厚度卡堆模型 + 隐藏总部（性能优化方案 2026-08-09 起，详见
    --    BuildSlotDeckVisual 注释；卡堆档位/总部实体与玩家实体无关，无对手模式下
    --    虚拟对手复用同一构建，见 SetupVirtualOpponent）
    self:BuildSlotDeckVisual(slot, #pool == 39, deck)
    -- 记录卡组存档（无对手模式：虚拟对手默认复制本方卡组，见 SetupVirtualOpponent）
    local bd = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if bd then
        bd.deckData = deck
        bd.hasValidDeck = hasValidDeck
    end
end

--[[
    建卡组槽视觉（battle 模式，LoadPlayerBattleDeck 与 SetupVirtualOpponent 共用）：
      6 档厚度卡堆模型 + 隐藏总部（性能优化方案 2026-08-09 起，见原函数注释）：
        - 每槽预生成全部 6 档卡堆实体（同时仅一档可见，SetNoDraw 切换）；档位按
          剩余卡数 snapUp 向上取最近档（剩余 = deck.remaining +（总部在堆顶时 1））
        - 有卡组：总部实体仍为独立卡牌但初始 SetNoDraw(true) 隐藏（堆叠厚度已由
          档位模型表现）；对局开始头像揭晓完成后客户端播放总部动画
          （cl_init.lua StartHQReveal 显式 SetNoDraw(false) + 发送 KardsHQRevealStart，
          服务端据此把剩余卡数改为「不含总部」）移动到头像旁落位支援阵线
        - 无卡组：不生成总部实体，卡堆档位实体全部隐藏（remaining=0 → tier 0，
          卡组槽本身为空，无需占位卡背）
      卡堆顶面卡背 = 数据层顶卡国家卡背（SyncDeckTopBack → Kards_DeckTopBack NW →
      客户端按国家卡背目录改写档位 manifest front 槽，2026-08-12 取消统一 usa）

    @param slot     number 槽位编号（1 = P1 / 2 = P2）
    @param hasDeck  boolean 数据层是否已建卡组（39 张校验由调用方完成）
    @param deck     table|nil 卡组存档（deck.cards / deck.hq；无卡组为 nil）
]]
function ENT:BuildSlotDeckVisual(slot, hasDeck, deck)
    local playerID = (slot == 1) and "P1" or "P2"
    -- 2) 视觉：6 档厚度卡堆模型 + 隐藏总部（性能优化，见上方函数注释与常量块）。
    --    每槽预生成全部档位实体（同时仅一档可见，SetNoDraw 切换，见 SetDeckPileTier）；
    --    卡堆剩余卡数 = remaining +（总部仍在堆顶时 1）；无卡组时 remaining=0 →
    --    tier 0 → 全部隐藏（卡组槽留空，见下方 hasDeck 判断）。
    local slotIdx = (slot == 1) and 1 or 2
    local base = self.DeckSlotBase[slotIdx]
    local yaw = self.DeckSlotYaw[slotIdx]
    local pileEnts = {}
    for _, tier in ipairs(self.DeckPileTiers) do
        local scale = (tier == 1) and self.DeckPileScaleSingle or self.DeckPileScale
        -- 槽专属档位 modelID（manifest 由客户端按槽克隆，顶面卡背按本槽顶卡国家改写）
        local pent = self:SpawnDeckPile(self:DeckPileModelIDForSlot(tier, slot), base, yaw, slot, tier, scale)
        if IsValid(pent) then
            pent:SetNoDraw(true) -- 初始全部隐藏，由 SetDeckPileTier 切换可见档
            pileEnts[tier] = pent
        end
    end
    -- 3) 总部实体：仍为独立卡牌实体但初始隐藏（SetNoDraw(true)，堆叠厚度已由档位
    --    模型表现）；对局开始头像揭晓完成后客户端播放总部动画（cl_init.lua
    --    StartHQReveal 显式 SetNoDraw(false) + 发送 KardsHQRevealStart，服务端据此
    --    把卡堆剩余卡数改为「不含总部」）移动到头像旁，动画结束落位本方支援阵线。
    local hqEnt = nil
    local hqSafe = nil
    if hasDeck and deck and deck.hq then
        local hqInfo = KARDS.CardEditor.SaveSystem.GetCardInfo(deck.hq)
        if hqInfo and hqInfo.cardAppearance then
            local card = self:_CreateDeckCard(hqInfo)
            hqSafe = self:DeckSafeName(deck.hq)
            local hqModel = "kards_deck_hq_" .. hqSafe
            if KARDS.CardManifest.EnsureDeck(hqModel, "hq_" .. hqSafe) then
                -- 卡堆顶面（40 档顶 = 总部初始所在位置；动画起始点取此局部坐标）
                local relPos = Vector(base.x, base.y, base.z + self:DeckPileWorldHeight(40))
                local pent = self:SpawnDeckCardEntity(card, hqModel, relPos)
                if IsValid(pent) then
                    pent:SetNWString("Kards_DeckRole", "hq")
                    pent:SetNWInt("Kards_DeckSlot", slot) -- 槽位（客户端区分本方/敌方总部动画）+ 战场卡归属方（视角朝向规则，见 cl_perspective.lua）
                    pent:SetNWBool("Kards_IsFieldCard", true) -- 战场卡标记（客户端视角朝向基础规则：P1/P2/观战按本地视角本地设置 yaw，服务端只发归属数据）
                    if self._kardsChildSystem and self._kardsChildSystem:RegisterChild(pent, relPos) then
                        pent:SetLocalAngles(Angle(180, yaw, 0)) -- 卡背朝上（初始隐藏，动画开始时翻转）
                        pent:SetNoDraw(true) -- 隐藏：总部动画前堆叠厚度由档位模型表现
                        hqEnt = pent
                    else
                        pent:Remove()
                    end
                end
            end
        end
    end
    self._kardsBattleDecks = self._kardsBattleDecks or {}
    -- 无卡组（hasDeck=false）：不生成总部实体，卡堆档位实体全部隐藏（remaining=0 →
    -- SetDeckPileTier size=0 → tier 0 → 全部 NoDraw）——卡组槽本身为空，无需
    -- 占位卡背（2026-08-12 取消无卡组 39 视觉占位与 usa 兜底卡背）
    self._kardsBattleDecks[slot] = {
        pileEnts = pileEnts,   -- 档位实体表：tier → 实体（SetDeckPileTier 切换可见性）
        hqEnt = hqEnt,         -- 隐藏总部实体（有卡组时存在；动画时客户端显式显示）
        hqSafe = hqSafe,       -- 总部文件名 safeName（动画后切换 unit 模型用）
        hqUnitModelID = hqSafe and ("kards_unit_hq_" .. hqSafe) or nil, -- 总部 unit 模型标识
        hqLeft = not hasDeck,  -- 总部是否已离开堆顶（无卡组无总部 → true：剩余卡数不 +1）
        remaining = hasDeck and 39 or 0, -- 数据层剩余普通卡数（抽牌递减；无卡组为 0 → 档位全部隐藏）
        currentTier = 0,       -- 当前可见档位（SetDeckPileTier 写入）
        drawEnts = {},         -- 抽牌临时卡实体列表（退出/销毁时清理）
        playerID = playerID,
    }
    self:SetDeckPileTier(slot)
    self:SyncBattleCounts(slot) -- 悬停信息面板数据（手牌数 / 卡组剩余数 → NW）
    self:SyncDeckTopBack(slot)  -- 卡堆顶面卡背 = 顶卡国家卡背（取消统一 usa）
    print(("[Kards] 卡组槽: %s 已就绪（%s，档位 %d）"):format(playerID, hasDeck and "有卡组" or "无卡组", self._kardsBattleDecks[slot].currentTier))
end

--[[
    无对手模式（2026-08-12）：为无玩家槽位建立虚拟对手（无 AI，仅占位数据）——
    默认对手卡组 = 本方卡组（数据层 SimSetupDeck 39 张 + 视觉卡堆/总部，复用
    LoadPlayerBattleDeck 同款构建）。虚拟对手不自动完成重新调度（2026-08-12 起，
    此前「自动完成瞬间完成」的临时设计使命已完成）：起手发牌正常发出，重新调度
    留待玩家经 kards_switch 切换操作身份后代选（见下方 OnMulliganReady 调用与
    CheckAllMulligansDone——虚拟槽需代选提交 + 动画结束通知后才开始先手回合）。
    配合 kards_switch 指令切换 P1/P2 操作身份（见 table_session.lua）。

    @param slot     number 缺玩家的槽位编号（1/2）
    @param deckData table|nil 本方卡组存档（默认对手卡组数据源；nil = 对手也无卡组）
    @return boolean 是否建立成功（槽位已有卡组 / 已建过返回 false）
]]
function ENT:SetupVirtualOpponent(slot, deckData)
    if self._kardsBattleDecks and self._kardsBattleDecks[slot] then return false end -- 已有卡组（真实玩家）
    local playerID = (slot == 1) and "P1" or "P2"
    -- 数据层：与 LoadPlayerBattleDeck 同款 39 张校验 → SimSetupDeck（owner 不同）；
    -- 品质上限复验同 LoadPlayerBattleDeck（当前关闭，Beta 版启用）
    local pool = self:DeckPoolFromSave(deckData, playerID)
    if deckData and #pool == 39 then
        KARDS.Battle:SimSetupDeck(playerID, pool)
    elseif deckData then
        print(("[Kards] 无对手: 对手卡组 %s 非 39 张（%d），数据层跳过（仅视觉放置）"):format(tostring(deckData.name), #pool))
    else
        print("[Kards] 无对手: 本方无卡组存档，对手卡组同样留空（空抽触发士气伤害）")
    end
    -- 视觉：卡堆档位 + 隐藏总部（与真实玩家同款）
    self:BuildSlotDeckVisual(slot, #pool == 39, deckData)
    local bd = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not bd then return false end
    bd.virtual = true   -- 虚拟对手标记（kards_switch 切换提示用）
    bd.deckData = deckData
    -- 起手发牌（2026-08-12 起不再自动确认重新调度）：虚拟对手起手牌正常发出
    --（SimDraw → OnBattleDraw 广播，本方客户端按对方视角登记该槽 realHandCards），
    -- 重新调度留待玩家经 kards_switch 切换到该槽时代选——客户端 KardsSwitchSlot 把
    -- 该槽起手牌重新呈现为牌桌中间扇形选择（玩家代替虚拟对手选择去留），确认后走
    -- 既有补抽/统一落位流程。deck.mulliganDone 保持 false：CheckAllMulligansDone
    -- 等待虚拟槽代选提交 + 动画结束通知后才开始先手回合（2026-08-13 修复，见
    -- CheckAllMulligansDone——此前跳过虚拟槽，本方完成即回合开始，是旧「自动完成」
    -- 设计的残留，造成「提示完成但实际未完成」的假象）。
    self:OnMulliganReady(slot)
    print(("[Kards] 无对手模式: P%d 虚拟对手已就绪（卡组=%s，重新调度待代选）"):format(slot, pool and #pool == 39 and "本方副本" or "无"))
    return true
end

--[[
    抽牌通知（数据层 SimDraw 回调，服务端权威）：抽牌 / 额外抽取成功后：
      1. 卡堆剩余卡数递减并切换档位（snapUp 向上取最近档，跨档跳变发生在抽牌
         动画期间，被飞出的卡遮挡，见 SetDeckPileTier）
      2. 生成一张抽牌临时卡实体（位于当前可见卡堆顶部，manifest 后缀 _d<serial>
         唯一化，见 SpawnDeckDrawCard），把该实体广播给所有客户端：本方客户端
         播放重新调度发牌（牌桌中间扇形）或抽牌动画（手牌），对方/观战播放落对方
         手牌动画。消息含归属槽位 + 手牌序号（补抽卡占用被弃牌原序号 = 原位替换）
         + 落位手牌扇形总数 + 是否重新调度补抽 + 是否爆牌。
    爆牌（overdraw，readme 7.1 手牌上限 9）：数据层已把抽到的卡移出卡组但不进手牌，
    广播携带每张卡的爆牌标记 → 客户端播放专属弃牌动画（右卡槽停留后顺时针出场）。
    空抽（drawn 为空）不通知（士气伤害已在数据层结算）。

    节点「复制」（sh_node_acts_field.lua copy，2026-09-27 缺口 B）复用本链路播抽牌
    动画：克隆卡在卡堆顶生成实体后落手牌位，但源卡并未离开卡组 → 第五参数
    noDeckConsume 置位，跳过卡堆档位切换与顶卡卡背同步，保持卡堆视觉与数据层一致。

    @param playerID string 抽牌玩家（"P1"/"P2"）
    @param drawn    table 抽到的卡牌句柄列表
    @param overdraw boolean|nil 本次抽牌是否爆牌（至少一张卡因手牌已达上限未进手牌）
    @param overdrawnCards table|nil 爆牌卡表 [card] = true（per-card，支持部分爆牌）
    @param noDeckConsume boolean|nil 本次是否不消耗卡组（节点「复制」：源卡仍留卡组）
]]
function ENT:OnBattleDraw(playerID, drawn, overdraw, overdrawnCards, noDeckConsume)
    if not drawn or #drawn == 0 then return end
    local slot = (playerID == "P1") and 1 or 2
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    -- 落位手牌扇形总数（发牌即最终张数；数据层已把抽到的卡移入手牌，爆牌时
    -- 卡不进手牌 → total 保持上限 9，客户端据此跳过手牌重排，只播弃牌动画）；
    -- hand 表供下方按数组位置取手牌序号
    local hand = KARDS.Deck:GetHand(self.TableID, playerID) or {}
    local total = #hand
    -- 重新调度补抽标记：OnMulliganSubmit 已把被弃牌序号放入 pendingDrawIndexes
    local isMulliganReplace = deck and deck.pendingDrawIndexes and #deck.pendingDrawIndexes > 0
    -- 爆牌提示去重（2026-08-12）：一次抽牌可能多张爆牌（per-card 循环），只提示一次
    local overdrawHintSent = false
    for _, card in ipairs(drawn) do
        -- 数据层已把该卡移出牌堆：剩余卡数递减 + 档位切换（即使临时卡实体生成失败
        -- 也应先减，保证卡堆视觉与数据层一致）；noDeckConsume（节点「复制」）时源卡
        -- 未离卡组，卡堆余量/档位不变
        if deck and not noDeckConsume then
            deck.remaining = math.max(0, (deck.remaining or 0) - 1)
            self:SetDeckPileTier(slot)
        end
        -- 爆牌判定（per-card）：overdrawnCards 缺省时回退到整体 overdraw 标记
        local isCardOverdraw = overdraw and (overdrawnCards == nil or overdrawnCards[card])
        -- 爆牌观战提示（2026-08-12）：观战者（非本桌双方牌手）收「玩家名：手牌已满」，
        -- 同 KardsHintRelay 观战同步（3D2D 打字机）。双方玩家提示由各自客户端在爆牌
        -- 动画分支本地显示（本方「你的手牌已满」/ 对方「敌方手牌已满」），故此处只发
        -- 观战者；per-card 循环内每批抽牌只发一次。
        if isCardOverdraw and not overdrawHintSent then
            overdrawHintSent = true
            local targets = {}
            for _, p in ipairs(player.GetAll()) do
                if p ~= self.Slots[1] and p ~= self.Slots[2] then
                    targets[#targets + 1] = p
                end
            end
            if #targets > 0 then
                local me = self.Slots and self.Slots[slot]
                local name = (IsValid(me) and me:Nick()) or playerID
                -- 观战者各自语言不同 → 逐人发送（2026-10-17 多语言化）
                for _, p in ipairs(targets) do
                    net.Start("KardsHintObserver")
                        net.WriteEntity(self)
                        net.WriteString(name)
                        net.WriteString(KARDS.Lang.TFor(p, "battle.overdraw.observer"))
                    net.Send(p)
                end
            end
        end
        -- 手牌序号：爆牌卡不进手牌（不占序号，idx=0 占位，客户端爆牌分支不使用）；
        -- 重新调度补抽卡占用被弃牌的原序号（原位替换）；其余 = 该卡在手牌数组中的
        -- 实际位置（修复 2026-08-11：原 deck.handCounter 只增不减永不复位——出牌后
        -- 手牌减少再抽牌时 idx 仍沿用递增旧值（如手牌 3 张时 idx=5），客户端抽牌
        -- 动画终点按旧 idx 落错位。抽牌总是追加到手牌末位 → 单张抽牌 idx=total
        -- （末位）、起手发牌多张按数组顺序递增 1..N）
        local idx
        if isCardOverdraw then
            idx = 0
        elseif deck and deck.pendingDrawIndexes and #deck.pendingDrawIndexes > 0 then
            idx = table.remove(deck.pendingDrawIndexes, 1)
        else
            idx = 0
            for i, h in ipairs(hand) do
                if h == card then idx = i break end
            end
        end
        -- 抽牌临时卡实体：位于当前可见卡堆顶部，客户端播放发牌/抽牌动画
        local ent = self:SpawnDeckDrawCard(slot, card)
        if IsValid(ent) then
            if deck then
                -- 手牌序号 → 实体（重新调度弃牌时按实体找回原序号）
                deck.handIndexByEnt = deck.handIndexByEnt or setmetatable({}, { __mode = "k" })
                deck.handIndexByEnt[ent] = idx
            end
            -- C 修复（2026-08-12）：实体在本 tick 刚创建即广播，可靠 net 消息可能先于
            -- 实体快照到达客户端 → net.ReadEntity 无效 → 整条 KardsTableDeckDraw 被丢弃
            -- → 对方手牌不出现（调试会话 round1 entValid=false ×5 确认）。延迟 0.1s
            -- （listen server/LAN 下实体快照早已传播）再广播，并守卫牌桌/实体有效性。
            -- 注意：此前调试插桩曾把本块改成「双 net.Broadcast」（第二个残缺消息在
            -- net.Start 外 WriteString），一并还原为单次完整广播。
            timer.Simple(0.1, function()
                if not IsValid(self) or not IsValid(ent) then return end
                net.Start("KardsTableDeckDraw")
                    net.WriteEntity(ent)
                    net.WriteUInt(slot, 8)
                    net.WriteUInt(idx, 8)
                    net.WriteUInt(total, 8)
                    net.WriteBool(isMulliganReplace or false)
                    net.WriteBool(isCardOverdraw or false) -- 爆牌标记（客户端播专属弃牌动画）
                net.Broadcast()
                -- 2026-08-18 规划 B1：卡名不再进广播（对方/观战者收到动画但读不到卡名）；
                -- 卡面标识定向只发本方玩家（KardsTableDrawFace → 客户端 cardFaces 表）。
                -- 卡文件取 GetName 而非 GetID（2026-09-27 缺口 B）：保存卡两者同为卡文件名，
                -- 而克隆卡 ID 带 _copy 后缀、卡面标识沿用源卡（见 sh_node_acts_field.lua
                -- CloneCard），取 GetName 才能查回外观数据与效果链（指向机制按卡文件解析）
                local owner = self.Slots and self.Slots[slot]
                if IsValid(owner) then
                    net.Start("KardsTableDrawFace")
                        net.WriteEntity(ent)
                        net.WriteString(card:GetName())
                        net.WriteString(card:GetName())
                        net.WriteString(card:GetType())
                    net.Send(owner)
                end
            end)
        end
    end
    self:SyncBattleCounts(slot) -- 抽牌后同步手牌数 / 卡组剩余数（NW 自动广播）
    -- 抽牌后顶卡前移：卡堆顶面卡背同步新顶卡国家（noDeckConsume 时顶卡未变，跳过）
    if not noDeckConsume then
        self:SyncDeckTopBack(slot)
    end
end

--[[
    延时效果证明广播（2026-11-07 用户规格）：保持触发 / turn「等待」在回合时间刻即将执行时，
    把来源卡身份发给「来源卡归属玩家」，由该玩家客户端本地播放证明动画
    （cl_battle_delayed_proof.lua：从牌桌左边缘移入 + 逆时针旋转 + 透视放大，0.8 秒后反向，
    去程播放 hq_start.ogg）。

    只定向发归属玩家（不广播）：与 KardsTableDrawFace 的卡面定向口径一致，避免向对手
    泄露卡面（打出过的指令卡对手仍只见卡背）；观战者不参与证明动画。
    无对手模式虚拟对手无玩家实体 → 静默跳过。

    @param card table 延时效果来源卡牌句柄（数据层卡牌表，非实体）
]]
function ENT:BroadcastDelayedProof(card)
    if not IsValid(self) or not card then return end
    local owner = card.GetOwner and card:GetOwner() or nil
    if not owner then return end
    local slot = (owner == "P1") and 1 or 2
    local ply = self.Slots and self.Slots[slot]
    if not IsValid(ply) then return end
    local cardName = card.GetName and card:GetName() or ""
    if cardName == "" then return end
    local safeName = self:DeckSafeName(card:GetID())
    net.Start("KardsDelayedProof")
        net.WriteEntity(self)
        net.WriteString(cardName)   -- 卡文件名（客户端 DeckFindCardInfo 查外观数据）
        net.WriteString(safeName)   -- 卡面文件安全标识（客户端写 kards_deck/<safeName>/）
        net.WriteUInt(slot, 8)      -- 来源卡归属槽位（客户端据此决定左边缘方向与文字朝向）
    net.Send(ply)
end

-- 返回手牌动画兜底清理延迟（秒）：客户端动画完成 KardsReturnToHandDone 通知提前
-- 清理；断线/异常未通知时仍移除源战场实体（小模型）并清理 fieldCardEnts 映射。
local ReturnAnimServerRemoveDelay = 3.0

-- 收缴动画兜底揭示延迟（秒）：覆盖阵亡移除 + 0.5 秒重现 + 0.5 秒停留 + 余量
-- 消费点：BroadcastConfiscate 的兜底 timer 把载体 Kards_ConfiscateHidden 置 false，
-- 避免客户端动画未触发揭示时载体永久不可见。
local ConfiscateServerRevealFallback = 4.0

--[[
    返回手牌：在源战场实体位置创建正常卡模型动画载体（小模型 → 正常模型原地切换）

    部署流程为「手牌实体（正常卡）飞半程 → 切换小模型单位实体」；返回手牌是其
    对称路径：数据层 SimReturnToHand 触发 ReturnToHand 事件（时机早于老兵回退属性
    回调移除战场实体，见 sh_battle_unit.lua）→ 本方法在战场实体（小模型）当前
    位置创建正常卡模型实体（kards_battledeck_<safeName> 同款 manifest 唯一化链路，
    SpawnBattleDeckCard），客户端播放该实体飞回手牌的动画。动画期间小模型本地隐藏，
    动画完成通知服务端移除。

    注册：同 SpawnDeckDrawCard 登记 drawEnts / entCard / cardEnt（返回手牌后可再次
    打出：打出流程经 deck.entCard[cardEnt] 反查卡牌句柄）。

    @param slot    number 手牌槽位（1/2）
    @param card    table 返回手牌的卡牌句柄
    @param unitEnt Entity 源战场实体（小模型单位；须有效以读取位置/朝向）
    @return Entity|nil 新卡实体（失败返回 nil）
]]
function ENT:SpawnReturnedCard(slot, card, unitEnt)
    if not IsValid(unitEnt) then return nil end
    local safeName = self:DeckSafeName(card:GetID())
    self._kardsReturnSerial = (self._kardsReturnSerial or 0) + 1
    local suffix = "_r" .. self._kardsReturnSerial
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    -- 位置/朝向：源战场实体（小模型）当前世界姿态 → 牌桌局部（动画坐标系一致；
    -- 战场单位平躺 pitch=0，仅 yaw 有朝向，RegisterChild 后重设局部角度）
    local relPos = self:WorldToLocal(unitEnt:GetPos())
    local localAng = self:WorldToLocalAngles(unitEnt:GetAngles())
    local ent = self:SpawnBattleDeckCard(card, safeName, relPos, localAng.y, suffix)
    if IsValid(ent) then
        if self._kardsChildSystem then
            self._kardsChildSystem:RegisterChild(ent, relPos)
            ent:SetLocalAngles(Angle(0, localAng.y, 0)) -- RegisterChild 重置平躺后恢复战场朝向
        end
        ent:SetNWString("Kards_DeckSafeName", safeName) -- 客户端 InitDrawCardFace 找卡面文件
        ent:SetNWInt("Kards_DeckSlot", slot)
        -- 2026-08-18 规划 B1：同 SpawnDeckDrawCard 不写 Kards_CardFileName / Kards_CardType，
        -- 卡面标识由 KardsTableDrawFace 定向只发本方（BroadcastReturnToHand 补发）
        if deck then
            deck.drawEnts = deck.drawEnts or {}
            deck.drawEnts[#deck.drawEnts + 1] = ent
            deck.entCard = deck.entCard or setmetatable({}, { __mode = "k" })
            deck.entCard[ent] = card
            deck.cardEnt = deck.cardEnt or setmetatable({}, { __mode = "k" })
            deck.cardEnt[card] = ent
        end
    end
    return ent
end

--[[
    返回手牌动画广播（数据层 SimReturnToHand 触发 ReturnToHand 事件时调用）

    在源战场实体（小模型单位）位置创建正常卡模型动画载体，延迟广播 KardsReturnToHand
    （实体快照传播，同 OnBattleDraw 0.1s）：槽位 / 源实体 / 新卡实体 / 手牌序号 / 总数。
    客户端按视角三分播动画（本方与观战途经牌桌中心 z 上升 → 手牌空位；对方直飞 +
    空位/移动/翻面并行、时长减半），动画完成 KardsReturnToHandDone 通知清理小模型。

    手牌序号：事件先于手牌插入触发，返回手牌总是追加末位 → idx = 当前手牌数 + 1
    （插入后 = 新张数），与客户端 RenumberHand(slot, cardEnt, total) 让出的末位空位一致。

    @param card table 返回手牌的卡牌句柄
]]
function ENT:BroadcastReturnToHand(card)
    if not card or not IsValid(self) then return end
    local slot = (card:GetOwner() == "P1") and 1 or 2
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck then return end
    -- 源战场实体（小模型）：事件先于老兵回退属性回调触发，此刻仍在场；此后可能被
    -- OnBattleStatsChanged 移除（老兵回退），延迟广播时无效 → WriteEntity 写 NULL，
    -- 客户端 IsValid 检查跳过隐藏（动画载体新卡实体已创建于其原位，视觉仍是原地切换）
    local unitEnt = deck.fieldCardEnts and deck.fieldCardEnts[card]
    -- 手牌序号（事件先于插入：按追加末位计算）与插入后手牌总数
    local hand = KARDS.Deck:GetHand(self.TableID, card:GetOwner()) or {}
    local idx = 0
    for i, h in ipairs(hand) do
        if h == card then idx = i break end
    end
    if idx == 0 then idx = #hand + 1 end
    local total = #hand + 1
    local cardEnt = self:SpawnReturnedCard(slot, card, unitEnt)
    if not IsValid(cardEnt) then return end
    timer.Simple(0.1, function()
        if not IsValid(self) or not IsValid(cardEnt) then return end
        net.Start("KardsReturnToHand")
            net.WriteEntity(self)
            net.WriteUInt(slot, 8)
            net.WriteEntity(unitEnt or NULL)
            net.WriteEntity(cardEnt)
            net.WriteUInt(idx, 8)
            net.WriteUInt(total, 8)
        net.Broadcast()
        -- 2026-08-18 规划 B1：返回手牌后手牌实体 NW 已无卡面标识，卡面定向只发本方
        -- （对方/观战者只能看到一张牌飞回手牌，读不到卡名）。卡文件取 GetName（同
        -- OnBattleDraw：克隆卡 ID 带 _copy 后缀，卡面标识沿用源卡）
        local owner = self.Slots and self.Slots[slot]
        if IsValid(owner) then
            net.Start("KardsTableDrawFace")
                net.WriteEntity(cardEnt)
                net.WriteString(card:GetName())
                net.WriteString(card:GetName())
                net.WriteString(card:GetType())
            net.Send(owner)
        end
        -- 服务端兜底清理源战场实体（客户端动画完成 KardsReturnToHandDone 提前清理；
        -- 断线/异常时仍移除小模型 + 清理 fieldCardEnts 映射；guard 幂等）
        timer.Simple(ReturnAnimServerRemoveDelay, function()
            if not IsValid(self) then return end
            local c = deck.entCard and deck.entCard[cardEnt]
            local fe = c and deck.fieldCardEnts and deck.fieldCardEnts[c]
            if IsValid(fe) then
                if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(fe) then
                    fe:Remove()
                end
            end
            if c and deck.fieldCardEnts then deck.fieldCardEnts[c] = nil end
        end)
    end)
end

--[[
    收缴动画广播（数据层 SimConfiscate 触发 Confiscate 事件时调用）

    在源战场实体（小模型单位）位置创建完整卡动画载体（复用 SpawnReturnedCard，同时登记为
    收缴方手牌实体），先置隐藏（NW Kards_ConfiscateHidden），延迟 0.1 秒广播
    KardsConfiscateAnim（牌桌 / 槽位 / 源小模型 / 完整卡载体 / 手牌序号 / 总数）。

    客户端时序（见 cl_battle_confiscate.lua）：等源小模型阵亡移除 → 0.5 秒后载体原地现身
    → 再 0.5 秒飞入手牌末位。源小模型由既有阵亡路径（ScheduleFieldDeathRemove）回收，
    本广播不负责其清理。

    @param payload table { card = 单位句柄, newOwner = 收缴方, handTotal = 插入前手牌数 }

    @return nil 无返回值
    说明：slot 取收缴方（newOwner）所在槽；idx = handTotal + 1，total = idx，均按事件先于
          手牌插入触发计算；载体创建后即 SetNoDraw(true) 并写 NW Kards_ConfiscateHidden，
          等客户端揭示（服务端仅在兜底延迟后强显）。
]]
function ENT:BroadcastConfiscate(payload)
    if not IsValid(self) or not payload or not payload.card then return end
    local card = payload.card
    local slot = (payload.newOwner == "P1") and 1 or 2
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck then return end
    -- 源战场实体（小模型）：事件先于 SimRemoveFromField 触发，此刻仍在场可读原位。
    -- 注意收缴不限定归属，被收缴单位仍在原归属方阵线上（收缴方 deck 查不到），故两槽皆查
    local unitEnt
    for s = 1, 2 do
        local d = self._kardsBattleDecks and self._kardsBattleDecks[s]
        if d and d.fieldCardEnts and d.fieldCardEnts[card] then
            unitEnt = d.fieldCardEnts[card]
            break
        end
    end
    local idx = (payload.handTotal or 0) + 1
    local total = idx
    local cardEnt = self:SpawnReturnedCard(slot, card, unitEnt)
    if not IsValid(cardEnt) then return end
    -- 载体先隐藏：客户端揭示前不可见（NW 同步到各端；断线兜底见下）
    cardEnt:SetNoDraw(true)
    cardEnt:SetNWBool("Kards_ConfiscateHidden", true)
    timer.Simple(0.1, function()
        if not IsValid(self) or not IsValid(cardEnt) then return end
        net.Start("KardsConfiscateAnim")
            net.WriteEntity(self)
            net.WriteUInt(slot, 8)
            net.WriteEntity(unitEnt or NULL)
            net.WriteEntity(cardEnt)
            net.WriteUInt(idx, 8)
            net.WriteUInt(total, 8)
        net.Broadcast()
        -- 卡面定向只发本方（同 BroadcastReturnToHand：卡名不入广播，对方/观战者看不到）
        local owner = self.Slots and self.Slots[slot]
        if IsValid(owner) then
            net.Start("KardsTableDrawFace")
                net.WriteEntity(cardEnt)
                net.WriteString(card:GetName())
                net.WriteString(card:GetName())
                net.WriteString(card:GetType())
            net.Send(owner)
        end
        -- 兜底：客户端动画未触发揭示时（断线等）强显载体，避免永久不可见
        timer.Simple(ConfiscateServerRevealFallback, function()
            if IsValid(cardEnt) then cardEnt:SetNWBool("Kards_ConfiscateHidden", false) end
        end)
    end)
end

-- ====================================================================
-- 洗入 / 节点弃牌 / 加入阵线动画广播（2026-09-26 缺口 D / E / F）
-- 三者均由数据层经 EffectRegistry 事件通知，实体层在此创建动画载体并广播：
-- 手牌实体与战场小模型为服务端网络实体，客户端动画结束后不可自行 Remove，
-- 故统一由服务端定时兜底回收（同 BroadcastReturnToHand 的分工）。
-- ====================================================================

-- 洗入动画兜底清理延迟（秒）：覆盖最长分支 2.45 秒（手牌/场上飞行 + 0.75 秒中槽停留 +
-- 翻面入堆 + 多张错峰预算）并留约 0.55 秒缓冲（2026-10-03 联机排查：原值 2.5 只剩 0.05 秒余量）
local ShuffleIntoCleanupDelay = 3.0
-- 节点弃牌 / 爆牌飞出兜底清理延迟（秒）：覆盖最坏 2.45 秒（OverdrawFlyDur + OverdrawHold +
-- OverdrawExitDur + 多张错峰预算）并留约 0.55 秒缓冲（同上）
local PileFlyOutCleanupDelay = 3.0
-- 加入动画兜底清理延迟（秒）：覆盖手牌下落 + 入场左移
local JoinAnimCleanupDelay = 2.0
-- 凭空生成卡的屏幕右外侧生成偏移（牌桌局部 x）：起点质点须与右槽延长线重合，仅 x 外推
local ShuffleGenSpawnX = 70

--[[
    洗入动画广播（数据层 shuffleInto 触发 ShuffleInto 事件时调用，2026-09-26 缺口 D）

    逐条 entries（{ card, from }，from 编码载体来源 1=手牌 / 2=场上 / 3=凭空生成）建动画载体：
      - from 1：复用既有手牌实体原地起飞，并从手牌登记（drawEnts / entCard / cardEnt）摘除，
        避免扇形区残留幽灵卡（手牌数组已由数据层移除）
      - from 2：战场小模型当前位姿处新建正常卡模型载体（同 SpawnReturnedCard），原小模型
        随后由渲染层 CardLeave 移除
      - from 3：该方卡组槽右外侧新建正常卡模型载体，卡背朝上（pitch 180）
    延迟 0.1 秒广播 KardsShuffleInto（实体快照传播，同 OnBattleDraw），终端高度
    deckTopZ 由服务端算出随消息下发（客户端不自算）。卡面经 KardsTableDrawFace 定向只发
    本方（2026-08-18 规划 B1 约定：卡名不入广播，对方/观战者看不到卡名）。

    @param payload table 事件载荷（{ player = 玩家标识, source = 来源编码, entries = { { card, from } } }）
]]
function ENT:BroadcastShuffleInto(payload)
    if not IsValid(self) then return end
    local player = payload and payload.player
    local entries = payload and payload.entries
    if not player or type(entries) ~= "table" or #entries == 0 then return end
    local slot = (player == "P2") and 2 or 1
    local slotIdx = (slot == 1) and 1 or 2
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck then return end
    local base = self.DeckSlotBase[slotIdx]
    -- 卡组终点高度：单张洗入用卡堆顶面（与 SpawnDeckDrawCard 同式）；多张同刻洗入用
    -- 「卡组中间」（2026-09-27 用户规格：取从卡组顶卡到卡组底卡 z 的中间值，即卡堆高度的一半）
    local deckTopZ = base.z + self:DeckPileWorldHeight(deck.currentTier or 40)
    local deckMidZ = base.z + (deckTopZ - base.z) * 0.5
    self._kardsShuffleSerial = (self._kardsShuffleSerial or 0) + 1
    local serial = self._kardsShuffleSerial
    local carriers = {}   -- { ent = 载体, card = 卡牌句柄, from = 1|2|3 }
    local staleHand = {}  -- 待兜底清理的既有手牌实体（from == 1）
    local staleField = {} -- 待兜底清理的战场小模型（from == 2）
    for i, e in ipairs(entries) do
        local card = e and e.card
        local from = (e and e.from) or 1
        if card then
            local safeName = self:DeckSafeName(card:GetID())
            if from == 1 then
                local ent = deck.cardEnt and deck.cardEnt[card]
                if IsValid(ent) then
                    deck.cardEnt[card] = nil
                    if deck.entCard then deck.entCard[ent] = nil end
                    for j = #(deck.drawEnts or {}), 1, -1 do
                        if deck.drawEnts[j] == ent then table.remove(deck.drawEnts, j) break end
                    end
                    carriers[#carriers + 1] = { ent = ent, card = card, from = 1 }
                    staleHand[#staleHand + 1] = ent
                end
            elseif from == 2 then
                local unitEnt = deck.fieldCardEnts and deck.fieldCardEnts[card]
                if IsValid(unitEnt) then
                    local relPos = self:WorldToLocal(unitEnt:GetPos())
                    local localAng = self:WorldToLocalAngles(unitEnt:GetAngles())
                    local ent = self:SpawnBattleDeckCard(card, safeName, relPos,
                        localAng.y, "_s" .. serial .. "_" .. i)
                    if IsValid(ent) then
                        if self._kardsChildSystem then
                            self._kardsChildSystem:RegisterChild(ent, relPos)
                            ent:SetLocalAngles(Angle(0, localAng.y, 0)) -- 恢复战场朝向（平躺）
                        end
                        ent:SetNWString("Kards_DeckSafeName", safeName)
                        ent:SetNWInt("Kards_DeckSlot", slot)
                        carriers[#carriers + 1] = { ent = ent, card = card, from = 2 }
                    end
                    staleField[#staleField + 1] = unitEnt
                end
            else
                -- 屏幕右外侧起点（该方视角右侧 = 远离牌桌中心的一侧，随槽位镜像）：
                -- 载体质点与右槽延长线重合（y 与卡堆同排），仅 x 外推
                local outSign = (base.x >= 0) and 1 or -1
                local relPos = Vector(base.x + outSign * ShuffleGenSpawnX, base.y, base.z)
                local ent = self:SpawnBattleDeckCard(card, safeName, relPos,
                    self.DeckSlotYaw[slotIdx], "_s" .. serial .. "_" .. i)
                if IsValid(ent) then
                    if self._kardsChildSystem then
                        self._kardsChildSystem:RegisterChild(ent, relPos)
                        ent:SetLocalAngles(Angle(180, self.DeckSlotYaw[slotIdx], 0)) -- 卡背朝上
                    end
                    ent:SetNWString("Kards_DeckSafeName", safeName)
                    ent:SetNWInt("Kards_DeckSlot", slot)
                    carriers[#carriers + 1] = { ent = ent, card = card, from = 3 }
                end
            end
        end
    end
    if #carriers == 0 then return end
    -- 卡堆视觉同步（数据层已把卡插回卡组）：可视剩余递增 + 档位切换 + 计数/顶卡卡背刷新
    for _ = 1, #carriers do
        deck.remaining = math.min(39, (deck.remaining or 0) + 1)
    end
    self:SetDeckPileTier(slot)
    self:SyncBattleCounts(slot)
    self:SyncDeckTopBack(slot)
    timer.Simple(0.1, function()
        if not IsValid(self) then return end
        local live = {}
        for _, c in ipairs(carriers) do
            if IsValid(c.ent) then live[#live + 1] = c end
        end
        if #live == 0 then return end
        net.Start("KardsShuffleInto")
            net.WriteEntity(self)
            net.WriteUInt(slot, 8)
            net.WriteUInt(#live, 8)
            net.WriteVector(Vector(base.x, base.y, (#live > 1) and deckMidZ or deckTopZ)) -- 卡组终点（牌桌局部坐标）
            for _, c in ipairs(live) do
                net.WriteEntity(c.ent)
                net.WriteUInt(c.from, 8)
            end
        net.Broadcast()
        -- 卡面定向只发本方（同 BroadcastReturnToHand）：对方/观战者看到动画但读不到卡名
        local owner = self.Slots and self.Slots[slot]
        if IsValid(owner) then
            for _, c in ipairs(live) do
                net.Start("KardsTableDrawFace")
                    net.WriteEntity(c.ent)
                    net.WriteString(c.card:GetName())
                    net.WriteString(c.card:GetName())
                    net.WriteString(c.card:GetType())
                net.Send(owner)
            end
        end
    end)
    -- 服务端兜底清理：手牌实体与战场小模型交客户端动画后回收（断线/异常仍清理）
    timer.Simple(ShuffleIntoCleanupDelay, function()
        if not IsValid(self) then return end
        for _, ent in ipairs(staleHand) do
            if IsValid(ent) then
                if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(ent) then
                    ent:Remove()
                end
            end
        end
        for _, ent in ipairs(staleField) do
            if IsValid(ent) then
                if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(ent) then
                    ent:Remove()
                end
            end
        end
    end)
end

--[[
    节点弃牌 / 爆牌单卡飞出广播（数据层 discard / burn 触发 PileCardRemoved 事件时调用，
    2026-09-26 缺口 E）

    在卡堆顶逐张生成临时卡实体（SpawnDeckDrawCard），同步卡堆可视剩余与档位（同
    OnBattleDraw），延迟 0.1 秒广播 KardsPileCardFlyOut。客户端从卡堆顶飞向该方视角
    右侧卡槽（与抽牌爆牌的左侧槽位表现区分），无「手牌已满」提示。

    @param payload table 事件载荷（{ player = 玩家标识, cards = { 卡牌句柄 } }）
]]
function ENT:BroadcastPileCardFlyOut(payload)
    if not IsValid(self) then return end
    local player = payload and payload.player
    local cards = payload and payload.cards
    if not player or type(cards) ~= "table" or #cards == 0 then return end
    local slot = (player == "P2") and 2 or 1
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck then return end
    local ents = {}
    for _, card in ipairs(cards) do
        local ent = self:SpawnDeckDrawCard(slot, card)
        if IsValid(ent) then ents[#ents + 1] = ent end
    end
    if #ents == 0 then return end
    -- 卡堆视觉同步（数据层已把卡移出卡组）：剩余递减 + 档位切换 + 计数/顶卡卡背刷新
    for _ = 1, #ents do
        deck.remaining = math.max(0, (deck.remaining or 0) - 1)
    end
    self:SetDeckPileTier(slot)
    self:SyncBattleCounts(slot)
    self:SyncDeckTopBack(slot)
    timer.Simple(0.1, function()
        if not IsValid(self) then return end
        net.Start("KardsPileCardFlyOut")
            net.WriteEntity(self)
            net.WriteUInt(slot, 8)
            net.WriteUInt(#ents, 8)
            for _, ent in ipairs(ents) do net.WriteEntity(ent) end
        net.Broadcast()
    end)
    -- 服务端兜底清理：移除临时实体并从卡组槽登记摘除
    timer.Simple(PileFlyOutCleanupDelay, function()
        if not IsValid(self) then return end
        for _, ent in ipairs(ents) do
            if IsValid(ent) then
                if deck.entCard then deck.entCard[ent] = nil end
                if deck.cardEnt then
                    for card, e in pairs(deck.cardEnt) do
                        if e == ent then deck.cardEnt[card] = nil end
                    end
                end
                for j = #(deck.drawEnts or {}), 1, -1 do
                    if deck.drawEnts[j] == ent then table.remove(deck.drawEnts, j) break end
                end
                if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(ent) then
                    ent:Remove()
                end
            end
        end
    end)
end

--[[
    手牌弃牌飞出广播（数据层 SimDiscard 触发 HandCardDiscarded 事件时调用，2026-10-06）

    弃掉的手牌实体（SpawnDeckDrawCard 生成，登记在 deck.cardEnt）仍存在于场上，取其实体
    广播 KardsHandCardFlyOut。客户端复用节点弃牌右槽口径（cl_battle_mulligan.lua 的
    OverdrawFly）：牌从当前手牌位飞向该方视角右侧卡槽，停留 1 秒后顺时针出场，所有查看端
    动画一致；对方/观战端因无定向卡面记录（KardsTableDrawFace 只发本方）而自动显示卡背。

    动画播完（约 1.85 秒）后服务端兜底清理：销毁该手牌实体并摘除卡组槽登记
    （数据层已把卡移出手牌，实体不再复用）。

    @param payload table 事件载荷（{ player = 玩家标识, card = 卡牌句柄 }）
]]
function ENT:BroadcastHandCardFlyOut(payload)
    if not IsValid(self) then return end
    local player = payload and payload.player
    local card = payload and payload.card
    if not player or not card then return end
    local slot = (player == "P2") and 2 or 1
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local ent = deck and deck.cardEnt and deck.cardEnt[card]
    if not IsValid(ent) then return end
    timer.Simple(0.1, function()
        if not IsValid(self) or not IsValid(ent) then return end
        net.Start("KardsHandCardFlyOut")
            net.WriteEntity(self)
            net.WriteUInt(slot, 8)
            net.WriteEntity(ent)
        net.Broadcast()
    end)
    -- 服务端兜底清理：移除手牌实体并从卡组槽登记摘除
    timer.Simple(PileFlyOutCleanupDelay, function()
        if not IsValid(self) then return end
        if not IsValid(ent) then return end
        if deck.entCard then deck.entCard[ent] = nil end
        if deck.cardEnt then deck.cardEnt[card] = nil end
        if deck.handIndexByEnt then deck.handIndexByEnt[ent] = nil end
        for j = #(deck.drawEnts or {}), 1, -1 do
            if deck.drawEnts[j] == ent then table.remove(deck.drawEnts, j) break end
        end
        if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(ent) then
            ent:Remove()
        end
    end)
end

--[[
    加入阵线动画广播（节点效果拉入场时调用，2026-09-26 缺口 F）

    sourceEnt = deck.cardEnt[card]（手牌实体；无则为 NULL，即「非手牌单位」），登记摘除后
    交客户端动画、服务端兜底移除。fieldEnt = 渲染层战场实体（KARDS.BattleRender.CardEnts）。
    所在阵线经 KARDS.Battlefield:FindCardZone 判定并转为 line 值（2 前线 / 1 支援阵线）。
    延迟 0.1 秒广播 KardsJoinAnim。

    @param card table 成功加入阵线的卡牌句柄
]]
function ENT:BroadcastJoinAnim(card)
    if not card or not IsValid(self) then return end
    local owner = (card.GetOwner and card:GetOwner()) or "P1"
    local slot = (owner == "P2") and 2 or 1
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck then return end
    local sourceEnt = deck.cardEnt and deck.cardEnt[card]
    if IsValid(sourceEnt) then
        deck.cardEnt[card] = nil
        if deck.entCard then deck.entCard[sourceEnt] = nil end
        for j = #(deck.drawEnts or {}), 1, -1 do
            if deck.drawEnts[j] == sourceEnt then table.remove(deck.drawEnts, j) break end
        end
    end
    local fieldEnt = deck.fieldCardEnts and deck.fieldCardEnts[card]
    if not IsValid(fieldEnt) then
        fieldEnt = KARDS.BattleRender and KARDS.BattleRender.CardEnts
            and KARDS.BattleRender.CardEnts[self.TableID]
            and KARDS.BattleRender.CardEnts[self.TableID][card]
    end
    local zone = KARDS.Battlefield and KARDS.Battlefield:FindCardZone(self.TableID, card)
    local line = (zone == "frontline") and 2 or 1
    local hasSource = IsValid(sourceEnt)
    -- 手牌来源实体标识（2026-09-27 F1 修复）：消息里的实体引用在客户端尚未持有该实体时
    -- 会读成 NULL，本端于是少一次手牌脱手（扇形区残留幽灵卡），并改播屏右入场而与同桌
    -- 其它端不一致。随消息带上该实体的模型副本标识（同卡不同副本唯一，NW 已公开），
    -- 客户端在实体引用无效时按该标识在手牌登记表里找回同一实体。
    local sourceModelID = ""
    if hasSource then
        sourceModelID = sourceEnt:GetNWString("Kards_DeckModelID", "")
    end
    -- 部署音效（2026-09-26 缺口 F）：仅手牌来源播放；取法与打牌路径一致
    -- （手动锁定优先，否则按单位类型 × 规模自动分配），非手牌来源不播
    local deploySnd = ""
    if hasSource then
        local snds = (card.GetSounds and card:GetSounds()) or {}
        if snds._manual and snds._manual.deploy then
            deploySnd = snds.deploy or ""
        else
            deploySnd = KARDS.CardSounds.GetDeploySound(card:GetUnitType(), card:GetCardScale())
                or snds.deploy or ""
        end
    end
    timer.Simple(0.1, function()
        if not IsValid(self) then return end
        net.Start("KardsJoinAnim")
            net.WriteEntity(self)
            net.WriteUInt(slot, 8)
            net.WriteBool(hasSource)
            net.WriteEntity(hasSource and sourceEnt or NULL)
            net.WriteString(sourceModelID)
            net.WriteEntity(IsValid(fieldEnt) and fieldEnt or NULL)
            net.WriteUInt(line, 8)
            net.WriteString(deploySnd)
        net.Broadcast()
    end)
    -- 服务端兜底清理手牌实体（客户端动画结束后不可 Remove，故由服务端定时回收）
    if hasSource then
        timer.Simple(JoinAnimCleanupDelay, function()
            if not IsValid(self) then return end
            if IsValid(sourceEnt) then
                if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(sourceEnt) then
                    sourceEnt:Remove()
                end
            end
        end)
    end
end

--[[
    重新调度：该玩家起手抽牌（服务端入口，客户端「先手揭晓序列结束」发送 KardsMulliganReady）
    数据层 SimDraw 先手 4 / 后手 5 → OnBattleDraw 广播发牌（本方走牌桌中间扇形选择）。
    幂等：已发过 / 已重新调度过不再重复发牌（防重复发送 / 重复点击）。

    @param slot number 槽位编号（1/2）
]]
function ENT:OnMulliganReady(slot)
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck or deck.openingDealt or deck.mulliganDone then return end
    deck.openingDealt = true
    local inst = KARDS.Deck:Get(self.TableID)
    local count = inst and inst.Starters[deck.playerID] or KARDS.Deck.FIRST_STARTER
    if count and count > 0 then
        local drawn = KARDS.Battle:SimDraw(deck.playerID, count)
        -- 无卡组（抽不到牌）：不进入重新调度选择，直接视为已完成
        --（客户端无发牌卡 → 不显示 mulligan UI → 不会发 KardsMulliganSubmit，
        --  不标记将导致 CheckAllMulligansDone 永不满足、回合永不开始）
        if #drawn == 0 then
            deck.mulliganDone = true
            deck.mulliganAnimDone = true -- 无卡组无调度动画，直接视为动画已结束（2026-08-13）
            self:CheckAllMulligansDone()
        end
    end
end

--[[
    重新调度确认（服务端入口，客户端点击「确认」发送 KardsMulliganSubmit）：
      1. 广播 KardsMulliganDone（被弃实体列表）——先于补抽发牌广播，所有客户端先知道
         哪些牌回卡组：本方从牌桌中间、对方/观战从对方手牌位播放「弃牌回卡组」动画
      2. 弃牌回卡组：卡堆视觉加厚（档位 snapUp）
      3. 数据层 SimMulligan：弃牌随机插回卡组 + 补抽等量（OnBattleDraw 广播补抽卡，
         序号占用被弃牌原序号 → 所有客户端原位落手牌，同时进行）
    幂等：mulliganDone 后拒绝重复提交。

    @param slot number 槽位编号（1/2）
    @param ents table 被弃卡牌实体列表（客户端选中的「不想要」的牌）
]]
function ENT:OnMulliganSubmit(slot, ents)
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck or deck.mulliganDone then return end
    deck.mulliganDone = true
    -- 实体 → 卡牌句柄（SpawnDeckDrawCard 登记 entCard）+ 收集被弃牌手牌序号
    local unwanted, vacated = {}, {}
    for _, e in ipairs(ents or {}) do
        local card = deck.entCard and deck.entCard[e]
        if card then
            table.insert(unwanted, card)
            local idx = deck.handIndexByEnt and deck.handIndexByEnt[e]
            if idx then table.insert(vacated, idx) end
            -- 防作弊（2026-08-18，规划 A1）：被弃卡已回卡组，注销实体↔卡牌双向
            -- 映射，防止后续用被弃实体发 KardsPlayCard 打出「卡组外」的卡（实体
            -- 动画结束后仅 SetNoDraw 不销毁，映射残留即成为免费卡牌副本）。
            deck.entCard[e] = nil
            if deck.cardEnt and deck.cardEnt[card] == e then deck.cardEnt[card] = nil end
        end
    end
    table.sort(vacated)
    deck.pendingDrawIndexes = vacated -- 补抽卡序号占用被弃牌原序号（原位替换）
    -- 广播重新调度完成（被弃实体列表；先于下方 SimMulligan 的补抽发牌广播）
    net.Start("KardsMulliganDone")
        net.WriteEntity(self)
        net.WriteUInt(slot, 8)
        net.WriteUInt(#ents, 8)
        for _, e in ipairs(ents or {}) do net.WriteEntity(e) end
    net.Broadcast()
    -- 弃牌回卡组：卡堆视觉加厚（随后补抽递减，净不变；飞行中的卡遮挡跳变）
    for _ = 1, #ents do
        deck.remaining = math.min(39, (deck.remaining or 0) + 1)
    end
    self:SetDeckPileTier(slot)
    -- 数据层重新调度（弃牌随机插回卡组 + 补抽 → OnBattleDraw 广播补抽卡）
    KARDS.Battle:SimMulligan(deck.playerID, unwanted)
    self:SyncBattleCounts(slot)
    -- 双方重新调度均完成（在场玩家均已提交）→ 开始先手回合（回合开始事件 + 指挥点 0→1，
    -- 见 StartFirstTurn）。最后一名玩家提交时触发，保证开场动画 → 重新调度 →
    -- 先手开始回合的正确开局顺序（2026-08-11 修正）。
    self:CheckAllMulligansDone()
end

-- 双方重新调度动画结束后 → StartFirstTurn 前的小缓冲（2026-08-13，秒）：客户端
-- KardsMulliganAnimDone 通知发送时动画组已全部结束，此处仅留广播/网络到达的余量
--（防 StartFirstTurn 广播抢在动画收尾帧前到达客户端）
local MulliganToFirstTurnDelay = 0.3

--[[
    客户端重新调度动画结束通知（2026-08-13，替代固定 2.5s 延迟）：参战者客户端在本方
    视角所有重新调度动画（本方起手/补抽 + 弃牌回卡组，以及对方/虚拟对手同组动画）实际
    播完后发送（见 cl_init.lua KardsMulliganAnimDoneNotify），本接收器置位该槽
    deck.mulliganAnimDone 并复查 CheckAllMulligansDone。

    为何不用固定延迟：起手发牌/补抽按张串行（delay 0.25s/张），后手弃牌多时补抽动画
    总长可超 2.5s；无对手模式虚拟槽无玩家被 CheckAllMulligansDone 直接跳过、其动画由
    本方客户端播放——只有客户端知道动画真正结束。真人对战双方各自发送，服务端等双方。
]]
if SERVER then -- realm 门控（2026-08-18 规划 D11）：本文件由 init.lua 双端 include，
    -- 此接收器此前无 SERVER 守卫——客户端注册无害但会进入 CheckAllMulligansDone
    --（服务端权威流程），须仅服务端注册
    net.Receive("KardsMulliganAnimDone", function(_, ply)
        local ent = net.ReadEntity()
        local slot = net.ReadUInt(8)
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or data.slot ~= slot then return end
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[slot]
        if not deck or deck.mulliganAnimDone then return end -- 幂等：已置位 / 无卡组服务端直置
        deck.mulliganAnimDone = true
        ent:CheckAllMulligansDone()
    end)
end

--[[
    检查双方重新调度是否均已完成：真实玩家槽位的 deck 均已提交（mulliganDone）且其
    客户端重新调度动画已播完（mulliganAnimDone，KardsMulliganAnimDone 通知写入）；
    虚拟对手槽（deck.virtual、无玩家）同样要求代选提交 + 动画结束通知（2026-08-13，
    此前跳过虚拟槽是旧「自动完成」设计残留）。全部满足后延迟 MulliganToFirstTurnDelay
    （小缓冲）调用 StartFirstTurn 开始先手回合（回合开始事件 + 指挥点 0→1，
    见 table_session.lua StartFirstTurn）。

    动画等待原因（2026-08-13）：客户端补抽 / 弃牌回卡组动画实际结束前，先手不应开始
    回合——此前固定 2.5s 延迟不可靠（后手弃牌多时补抽动画可超时）导致：① 先手能在
    对方调度动画期间结束回合（KardsEndTurn 仅挡 _kardsFirstTurnStarted，但回合已被
    提前开始）；② 客户端「敌方正在重新调度手牌」提示过早消失（见 cl_init.lua
    KardsWaitingOpponentMulliganHUD）。

    调用点：OnMulliganSubmit 末尾 / OnMulliganReady 无卡组跳过分支 /
    KardsMulliganAnimDone 接收器（动画结束通知）。
    幂等：_kardsFirstTurnStarted / _kardsFirstTurnScheduled 防重复调度。
]]
function ENT:CheckAllMulligansDone()
    if self._kardsFirstTurnStarted or self._kardsFirstTurnScheduled then return end
    -- 真实玩家槽（按物理槽位，kards_switch 不改 Slots）：要求提交 + 动画结束通知
    for slot, p in pairs(self.Slots or {}) do
        if IsValid(p) and p:IsPlayer() then
            local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
            if not (deck and deck.mulliganDone and deck.mulliganAnimDone) then return end -- 仍有玩家未提交或其动画未播完
        end
    end
    -- 虚拟对手槽（无玩家但 deck.virtual）：同样要求提交（玩家 kards_switch 代选）+
    -- 动画结束通知（2026-08-13 修复：此前跳过虚拟槽，本方完成即回合开始——旧设计
    -- 「虚拟对手自动完成重新调度」的残留；改为等待代选后「双方调度完成」才有真实
    -- 语义，先手回合才在其后开始，符合 kards_switch 测试牌桌的预期）
    for vslot, vdeck in pairs(self._kardsBattleDecks or {}) do
        local p = self.Slots and self.Slots[vslot]
        if vdeck.virtual and not (p and IsValid(p) and p:IsPlayer()) then
            if not (vdeck.mulliganDone and vdeck.mulliganAnimDone) then return end
        end
    end
    self._kardsFirstTurnScheduled = true
    local ent = self
    timer.Simple(MulliganToFirstTurnDelay, function()
        if not IsValid(ent) then return end
        ent._kardsFirstTurnScheduled = false
        ent:StartFirstTurn()
    end)
end

--[[
    打出卡牌（服务端权威入口，客户端拖拽松手在非手牌区域发送 KardsPlayCard 触发）：
    从手牌打出指令（SimPlayCard，play_command 刻 + 反制钩子 + 指挥点支付）或部署单位
    （SimDeploy 受限选位 + 整线自动居中：落点列定排秩，整线按 GetCenteredStart 居中，
    2026-08-10 起主路径改回居中——固定槽位部署不重排，单位与总部间会留空槽）。
    从本入口起动用战斗系统反应、时间刻记录的服务端内容。

    实体策略（2026-08-10 定）：拖拽中的手牌实体复用为战场卡——ReuseCard 登记映射，
    CardEnter 事件由渲染层复用拦截消费（不新建实体、设战场 NW 字段）；未来部署动画
    过半时经 CreateBattleCardEntity 切换更简单的战场模型（预留接口）。

    @param ply       Player 发起玩家（服务端已按 _kardsTable 校验归属）
    @param slot      number 槽位编号（1/2）
    @param cardEnt   Entity 手牌实体（SpawnDeckDrawCard 生成，entCard 已登记）
    @param slotIndex number 目标槽位（1..SLOT_COUNT；0 = 指令卡不进战场）
    @param targetEnt Entity|nil 指向目标实体（B3：客户端指向模式携带；普通打出 NULL）
    @param extraOpts table|nil 调用方扩展（伪用户控制台用）：{ specify = { targetPicker/developPicker } }
]]
function ENT:OnPlayCard(ply, slot, cardEnt, slotIndex, targetEnt, extraOpts)
    local function reject()
        net.Start("KardsPlayCardRejected")
            net.WriteEntity(self)
            net.WriteUInt(slot, 8)
            net.WriteEntity(cardEnt)
        net.Send(ply)
    end
    -- 校验：对局已开始、先手回合已开始（防重新调度窗口打 0 费卡，规划 A3）、
    -- 当前回合方、实体有效且属于本槽抽出（在手牌中）
    if not self._kardsFormalBattleStarted or not self._kardsFirstTurnStarted
        or self._kardsTurnSlot ~= slot then
        return reject()
    end
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local card = deck and deck.entCard and deck.entCard[cardEnt]
    if not card then
        -- 结构性分歧（2026-09-13 测试版 desync 恢复）：开局/先手/回合方门控均已通过，
        -- 说明对局活跃且轮到该玩家，但其打出的手牌实体在服务端映射中不存在。正常时序
        -- 客户端 pendingPlayEnt 在点击上升沿即冻结防重复发送，故此情形只可能是客户端
        -- 手牌视图与服务端分歧（丢包/本地状态错乱），退回动画无意义，转重启弹窗
        self:NotifyDesync(ply)
        return
    end
    local playerID = (slot == 1) and "P1" or "P2"
    -- 防作弊（2026-08-18，规划 A1）：卡必须确实在本方手牌（服务端权威）。
    -- 仅靠 entCard 实体映射不足以证明归属——重调度被弃实体的映射已注销，
    -- 此处再从数据层手牌表二次校验，杜绝打出「卡组外」的卡。
    local hand = KARDS.Deck and KARDS.Deck:GetHand(self.TableID, playerID)
    if not hand then
        self:NotifyDesync(ply) -- 对局活跃但本方手牌数据缺失：数据层分歧，同转重启弹窗
        return
    end
    local inHand = false
    for _, h in ipairs(hand) do
        if h == card then inHand = true break end
    end
    if not inHand then
        -- 实体映射在册但数据层手牌查无此卡：客户端手牌索引与服务端分歧，转重启弹窗
        self:NotifyDesync(ply)
        return
    end
    -- unit 战场实体（单位打出时创建，KardsCardPlayed 广播携带；指令为 nil）
    local unitEnt = nil
    local ctype = card:GetType()
    if ctype == "command" or ctype == "counter_command" then
        -- 指令 / 反制：战斗系统打出（play_command 刻 + 反制钩子 + 指挥点支付）。
        -- B3：客户端指向模式携带目标实体 → FieldCardByEnt 反查卡牌 → targetPicker
        -- 注入（TargetSelectorActs.select mode=="one" 从候选返回选中的卡，见
        -- sh_node_acts_condition.lua；通道见 SimPlayCard opts.specify）
        local opts = nil
        -- specify 组装（2026-09-26 三选一合并语义）：先按 targetEnt 反查得到
        -- targetPicker（指向类指令），再用调用方直传的 specify 逐键覆盖。
        -- 直传值含开发/观星 picker（接收器传 ent:BuildPickSpecify），与 targetPicker
        -- 可同时存在；整组替换会丢 targetPicker，使指向类指令退化为候选首项。
        local specify = nil
        if IsValid(targetEnt) then
            -- 指向目标可能在敌方槽位（指向敌方单位/总部）：遍历两个槽位反查，
            -- 与 OnUnitEngage 防御方反查一致。仅查发起方 deck 会漏敌方实体 →
            -- targetPicker 不注入 → Specify.Target 回退候选首项（本方支援阵线
            -- 第 1 槽单位），造成「指向敌方步兵55团却结算到友方同槽位单位」。
            local targetCard = nil
            for s = 1, 2 do
                local d = self._kardsBattleDecks and self._kardsBattleDecks[s]
                targetCard = d and self:FieldCardByEnt(d, targetEnt)
                if targetCard then break end
            end
            if targetCard then
                specify = {
                    targetPicker = function(candidates)
                        for _, c in ipairs(candidates or {}) do
                            if c == targetCard then return c end
                        end
                        return candidates and candidates[1] -- 目标已离场：回退默认
                    end,
                }
            end
        end
        -- 调用方直传 specify（伪用户控制台 kards_fakeuser：目标/开发/观星选择经协程
        -- 挂起由控制台续选，候选是卡牌句柄，不经世界实体反查）逐键覆盖上表
        if extraOpts and type(extraOpts.specify) == "table" then
            specify = specify or {}
            for k, v in pairs(extraOpts.specify) do
                specify[k] = v
            end
        end
        if specify then opts = { specify = specify } end
        if not KARDS.Battle:SimPlayCard(playerID, card, nil, opts) then return reject() end
        -- 事件音效（2026-08-13）：指令打出 play / 反制打出激活时 activate（音源方位=手牌实体）
        self:BroadcastEventSound(card, ctype == "counter_command" and "activate" or "play", cardEnt)
        KARDS.Deck:RemoveFromHand(self.TableID, playerID, card)
        deck.entCard[cardEnt] = nil
        deck.cardEnt[card] = nil
        self:SyncBattleCounts(slot)
        -- 实体移除延后（2026-08-12 阶段 C）：客户端需完成「展示槽（打出方视角左侧）
        -- 停留 → 左下出场」动画（约 2.95s）后才销毁。客户端动画 onComplete 发送
        -- KardsCommandExit 通知；服务端兜底定时（CommandServerRemoveDelay）防客户端
        -- 未通知（断线/异常）。guard 幂等：通知与兜底定时只移除一次
        -- （commandExitPending 登记 + removedCmd 标志）。
        deck.commandExitPending = deck.commandExitPending or {}
        local removedCmd = false
        local function GuardRemove()
            if removedCmd then return end
            removedCmd = true
            deck.commandExitPending[cardEnt] = nil
            if not IsValid(cardEnt) then return end
            if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(cardEnt) then
                cardEnt:Remove()
            end
        end
        deck.commandExitPending[cardEnt] = GuardRemove
        timer.Simple(CommandServerRemoveDelay, function()
            if IsValid(self) and deck.commandExitPending and deck.commandExitPending[cardEnt] then
                GuardRemove()
            end
        end)
    elseif ctype == "unit" then
        -- 单位：登记复用映射（SimDeploy 触发 CardEnter → spawnCard 拦截消费：设战场
        -- NW 字段、不新建实体）。原手牌实体 cardEnt 仅作飞行动画载体——战场卡由下方
        -- 新建的 unit 实体承担（2026-08-11 basic_card_unit 切换）
        if KARDS.BattleRender and KARDS.BattleRender.ReuseCard then
            KARDS.BattleRender:ReuseCard(self.TableID, card, cardEnt)
        end
        -- 部署：受限选位 + 整线自动居中（SimDeploy 数据层定落位）——固定槽位部署
        -- 不重排会让单位与总部间留空槽（2026-08-10 反馈），故主路径改回居中
        local ok = KARDS.Battle:SimDeploy(card, slotIndex)
        if not ok then
            -- 失败（指挥点不足 / 阵线已满等）：清除复用映射，避免遗留
            if KARDS.BattleRender and KARDS.BattleRender.Unreuse then
                KARDS.BattleRender:Unreuse(self.TableID, card)
            end
            return reject()
        end
        KARDS.Deck:RemoveFromHand(self.TableID, playerID, card)
        deck.entCard[cardEnt] = nil
        deck.cardEnt[card] = nil
        -- 创建 unit 战场实体（服务端 ApplyImportedModel 渲染链路，与手牌实体一致；
        -- Q 菜单测试已验证可渲染。mesh 共享 basic_card_unit，UV 裁切由客户端
        -- PrefillUnitCrop 预填；原 cardEnt 保留作飞行动画载体，客户端动画中途隐藏）
        local safeName = self:DeckSafeName(card:GetID())
        if KARDS.CardManifest and KARDS.CardManifest.CloneUnit then
            local unitModelID = "kards_unit_" .. safeName
            KARDS.CardManifest.CloneUnit(unitModelID, "kards_deck/" .. safeName)
            unitEnt = ents.Create("sent_pmx_static_imported")
            if IsValid(unitEnt) then
                unitEnt:SetPos(cardEnt:GetPos())
                unitEnt:SetAngles(cardEnt:GetAngles())
                unitEnt:Spawn()
                local uok = unitEnt:ApplyImportedModel(unitModelID, 0.06) -- 世界 7.2×8.528
                if not uok then
                    print(("[Kards] unit 战场实体模型应用失败: %s"):format(unitModelID))
                    unitEnt:Remove()
                    unitEnt = nil
                else
                    unitEnt:SetSolid(SOLID_NONE)
                    local phys = unitEnt:GetPhysicsObject()
                    if IsValid(phys) then phys:EnableMotion(false) end
                    -- 战场属性 NW（客户端 AddLocal 单位模式文字读取）
                    unitEnt:SetNWInt("Kards_CardAttack", (card.GetStat and card:GetStat("attack")) or 0)
                    unitEnt:SetNWInt("Kards_CardDefense", (card.GetStat and card:GetStat("defense")) or 0)
                    unitEnt:SetNWInt("Kards_CardActionCost", (card.GetActionCost and card:GetActionCost()) or 0)
                    -- 2026-08-13：词条展示串初写（部署时同步；此后变化经 SyncUnitNW 刷新，
                    -- 见 BuildUnitKeywordsStr / cl_battle_keyword_icons.lua）
                    unitEnt:SetNWString("Kards_UnitKeywords", self:BuildUnitKeywordsStr(card))
                    -- 战场卡标记（客户端视角朝向基础规则：KardsFieldFacing 按本地视角
                    -- 设置 yaw，与总部一致朝向本方；服务端只发归属数据，见
                    -- cl_perspective.lua / cl_init.lua KardsFieldFacing）。2026-08-12：
                    -- 切换 basic_card_unit 后可见战场实体是 unitEnt（非复用实体 cardEnt，
                    -- 后者经 spawnCard 拦截设过这两个 NW），缺失导致单位不被朝向驱动、
                    -- 残留手牌扇形角度——敌方单位朝向对方、与本方总部朝向不一致）
                    unitEnt:SetNWBool("Kards_IsFieldCard", true)
                    unitEnt:SetNWInt("Kards_DeckSlot", slot)
                    -- 隐蔽单位（2026-08-13 readme 7.2.2）：SimDeploy 已 ApplyEnterKeywords
                    -- 置 Hidden，NW 同步客户端部署落位背面朝上（KardsCardPlayed 半程切换时
                    -- 读取设 pitch=180 + 3D2D 文字 hideWhenBack）；揭示时 BroadcastReveal 清除
                    local st = KARDS.Battle and KARDS.Battle.KeywordStates
                        and KARDS.Battle.KeywordStates[self.TableID]
                    unitEnt:SetNWBool("Kards_IsHidden",
                        st and KARDS.KeywordStates.Hidden.Is(st, card) or false)
                    -- 接入子物体系统：随牌桌移动/旋转 + 牌桌销毁时统一清理
                    if self._kardsChildSystem then
                        local relPos = self:WorldToLocal(cardEnt:GetPos())
                        if relPos then
                            self._kardsChildSystem:RegisterChild(unitEnt, relPos)
                        end
                    end
                end
            else
                unitEnt = nil
            end
        end
        -- 战场卡实体映射（布局广播反查；weak keys 防泄漏）——unit 创建失败时回退原实体
        deck.fieldCardEnts = deck.fieldCardEnts or setmetatable({}, { __mode = "k" })
        deck.fieldCardEnts[card] = IsValid(unitEnt) and unitEnt or cardEnt
        self:SyncBattleCounts(slot)
        -- 2026-08-13：部署后刷新同线词条 NW——被守护由相邻守护单位实时赋予，守护单位
        -- 部署到已存在单位旁时，相邻单位需同步获得/解除被守护图标（部署单位自身已初写）
        if KARDS.Battlefield then
            local z2, o2 = KARDS.Battlefield:FindCardZone(self.TableID, card)
            if z2 then
                local line = (z2 == "support") and KARDS.Battlefield:GetSupport(self.TableID, o2)
                    or KARDS.Battlefield:GetFrontline(self.TableID)
                for _, c in ipairs(line) do
                    if c and c ~= card then
                        local e = c and deck.fieldCardEnts and deck.fieldCardEnts[c]
                        -- 总部驻留支援阵线（槽 3）：实体在 deck.hqEnt 而非 fieldCardEnts，
                        -- 词条刷新单独处理（2026-08-13：守护单位部署到总部旁时总部
                        -- 需显示被守护图标）
                        if not e and c:GetType() == "headquarter" then
                            e = deck.hqEnt
                        end
                        if IsValid(e) then
                            if c:GetType() == "headquarter" then
                                e:SetNWString("Kards_UnitKeywords", self:BuildUnitKeywordsStr(c))
                            else
                                self:SyncUnitNW(c, e)
                            end
                        end
                    end
                end
            end
        end
    else
        -- 总部 / 未知类型：不可打出
        return reject()
    end
    -- 实际落位槽位（指令 0；单位以数据层为准——居中重排后的实际槽位，可能与
    -- 客户端落点列不同，见 KardsCardPlayed 接收 / KardsFieldLayout 复位）
    local landed = 0
    if ctype == "unit" then
        local line = KARDS.Battlefield:GetSupport(self.TableID, playerID)
        if line then
            for i = 1, KARDS.Battlefield.SLOT_COUNT do
                if line[i] == card then landed = i; break end
            end
        end
    end
    -- 指挥点同步（打出已支付卡牌花费）：广播当前双方指挥点，驱动手牌花费文字颜色
    self:BroadcastCommandPoints()
    -- 放牌/部署音效（2026-08-14 规模接入战斗系统）：随 KardsCardPlayed 广播，客户端
    -- 飞行开始播放放牌音效（placeSnd）、小模型切换时刻播放部署音效（deploySnd）。
    -- 放牌按规模（medium→place_medium / large→place_large / small→无，见
    -- KARDS.CardSounds.GetPlaceSound）。部署音效手动锁定优先（编辑器音效选择器
    -- 五角星，_manual.deploy=true 用手动 sounds.deploy）；否则按「单位类型×规模」
    -- 自动分配（GetDeploySound 对缺失文件级联回退，回退失败再回退手动配置）。仅单位卡有。
    local placeSnd, deploySnd = "", ""
    if ctype == "unit" then
        placeSnd = KARDS.CardSounds.GetPlaceSound(card:GetCardScale()) or ""
        local snds = card:GetSounds() or {}
        if snds._manual and snds._manual.deploy then
            deploySnd = snds.deploy or ""
        else
            deploySnd = KARDS.CardSounds.GetDeploySound(card:GetUnitType(), card:GetCardScale())
                or snds.deploy or ""
        end
    end
    -- 广播打出结果（所有客户端：本方本地收尾拖拽动画、对方/观战同步战场卡）。
    -- 第 5 字段 = unit 战场实体（单位>0 且创建成功；指令/NULL：客户端走原实体全程动画）；
    -- 第 6/7 字段 = 放牌音效路径 / 部署音效路径（空串 = 不播放）
    -- 延迟 0.1 秒（2026-10-03 联机排查）：unitEnt 是本 tick 内新建的实体，立即广播时可靠
    -- 消息可能先于实体快照到达，客户端 net.ReadEntity 读到 NULL 而丢弃消息。两步同包保持
    -- 「先 CardPlayed 后布局」的既有次序（布局广播同样引用这个新实体）。
    timer.Simple(0.1, function()
        if not IsValid(self) then return end
        if ctype == "unit" then
            net.Start("KardsCardPlayed")
                net.WriteEntity(self)
                net.WriteUInt(slot, 8)
                net.WriteEntity(cardEnt)
                net.WriteUInt(landed, 8)
                net.WriteEntity(unitEnt or NULL)
                net.WriteString(placeSnd)
                net.WriteString(deploySnd)
            net.Broadcast()
            -- 单位：广播该玩家支援阵线布局（各卡槽位 → 实体；客户端按槽位 → 列坐标驱动/复位）
            self:BroadcastFieldLayout(slot, playerID)
        else
            -- 指令 / 反制：指令口径载荷，与反制自动打出通道共用（见 BroadcastCommandPlayed）
            self:BroadcastCommandPlayed(slot, cardEnt)
        end
    end)
end

--[[
    广播「指令 / 反制打出」通用载荷（KardsCardPlayed，指令口径）：
    牌桌 / slot / cardEnt / landed=0 / unitEnt=NULL / 空音效串。
    指令与反制均不进战场（landed=0、无战场实体），与单位打出共用同一消息类型、
    另一套载荷。OnPlayCard 指令分支与反制自动打出（OnCounterFired，反制系统 M5）
    共用本函数，保证两条通道的客户端动画完全一致。

    @param slot    number 槽位编号（1/2）
    @param cardEnt Entity 手牌实体
]]
function ENT:BroadcastCommandPlayed(slot, cardEnt)
    net.Start("KardsCardPlayed")
        net.WriteEntity(self)
        net.WriteUInt(slot, 8)
        net.WriteEntity(cardEnt)
        net.WriteUInt(0, 8)   -- landed：指令 / 反制不进战场
        net.WriteEntity(NULL) -- unit 战场实体（指令 / 反制无）
        net.WriteString("")   -- 放牌音效（指令 / 反制无）
        net.WriteString("")   -- 部署音效（指令 / 反制无）
    net.Broadcast()
end

--[[
    反制自动打出收尾（反制系统 M5）：数据层 FireCounter 经 SetCounterPlayCallback 通知
    （见 sh_battle_combat.lua CounterPlayCallbacks）→ 清理该反制的手牌映射与计数、
    广播指令口径打出动画 + 激活时音效、登记实体延迟销毁。
    与 OnPlayCard 指令分支的收尾同构（不结算 SimPlayCard——拦截函数效果已在拦截时执行；
    数据层 RemoveFromHand / Counter:Fire 已由 FireCounter 完成）。

    @param card table 反制卡牌句柄（已激活、已移出数据层手牌）
    @param slot number 槽位编号（1/2）
]]
function ENT:OnCounterFired(card, slot)
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck then return end
    local cardEnt = deck.cardEnt and deck.cardEnt[card]
    if not IsValid(cardEnt) then return end
    -- 事件音效（音源方位 = 手牌实体）：反制自动打出 = 激活时
    self:BroadcastEventSound(card, "activate", cardEnt)
    -- 手牌实体映射与计数（数据层手牌已由 FireCounter 移除，此处只清实体映射）
    deck.entCard[cardEnt] = nil
    deck.cardEnt[card] = nil
    self:SyncBattleCounts(slot)
    -- 广播指令口径打出动画（客户端走指令展示槽 → 出场动画，onComplete 通知 KardsCommandExit）
    self:BroadcastCommandPlayed(slot, cardEnt)
    -- 实体移除延后（同 OnPlayCard 指令分支：等客户端出场动画完成通知；服务端兜底定时防丢通知）
    deck.commandExitPending = deck.commandExitPending or {}
    local removedCmd = false
    local function GuardRemove()
        if removedCmd then return end
        removedCmd = true
        deck.commandExitPending[cardEnt] = nil
        if not IsValid(cardEnt) then return end
        if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(cardEnt) then
            cardEnt:Remove()
        end
    end
    deck.commandExitPending[cardEnt] = GuardRemove
    timer.Simple(CommandServerRemoveDelay, function()
        if IsValid(self) and deck.commandExitPending and deck.commandExitPending[cardEnt] then
            GuardRemove()
        end
    end)
end

--[[
    广播本方支援阵线布局（槽位 index → 战场卡实体，客户端据此驱动/复位卡位坐标）：
    总部 → deck.hqEnt；已打出单位 → deck.fieldCardEnts[card]；未登记实体（异常）
    → 写 nil（客户端跳过该槽）。在单位打出成功后调用——布局为居中重排后的
    GetCenteredStart 槽位（客户端按槽位 + 偶数整线 0.5 槽偏移展示，见 cl_init.lua
    FieldPos 辅助）。

    @param slot     number 槽位编号（1/2）
    @param playerID string 玩家标识（"P1"/"P2"）
]]
function ENT:BroadcastFieldLayout(slot, playerID)
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local line = KARDS.Battlefield:GetSupport(self.TableID, playerID)
    if not deck or not line then return end
    local items = {}
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        local card = line[i]
        if card then
            local ent
            if card:GetType() == "headquarter" then
                ent = deck.hqEnt -- 总部（上场动画后驻留支援阵线，随布局复位坐标）
            else
                ent = deck.fieldCardEnts and deck.fieldCardEnts[card]
            end
            items[#items + 1] = { i, ent }
        end
    end
    net.Start("KardsFieldLayout")
        net.WriteEntity(self)
        net.WriteUInt(slot, 8)
        net.WriteUInt(#items, 8)
        for _, item in ipairs(items) do
            net.WriteUInt(item[1], 8)
            net.WriteEntity(item[2])
        end
    net.Broadcast()
end

--[[
    广播前线布局（KardsFieldLayout slot=0 变体）：前线占领方 + 前线各槽位 → 战场卡实体。
    读序与支援阵线广播不同：多写一个 ownerSlot（前线归属槽 1/2；无主写 0）在 items 之前。
    客户端据此把前线单位实体复位到前线行（RowY[0]），并在无主/敌方占领时清空本方前线视图。

    @param ownerSlot number|nil 前线归属槽（1/2；前线无主传 0）
]]
function ENT:BroadcastFrontlineLayout(ownerSlot)
    local frontline = KARDS.Battlefield:GetFrontline(self.TableID)
    if not frontline then return end
    local flOwner = KARDS.Battlefield:GetFrontlineOwner(self.TableID)
    if ownerSlot == nil then
        ownerSlot = (flOwner == "P1") and 1 or ((flOwner == "P2") and 2 or 0)
    end
    local items = {}
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        local card = frontline[i]
        if card then
            -- 前线单位归属其玩家卡组槽：按归属反查实体
            local deck = self._kardsBattleDecks
                and self._kardsBattleDecks[(card:GetOwner() == "P1") and 1 or 2]
            local ent = deck and deck.fieldCardEnts and deck.fieldCardEnts[card]
            items[#items + 1] = { i, ent }
        end
    end
    net.Start("KardsFieldLayout")
        net.WriteEntity(self)
        net.WriteUInt(0, 8)      -- slot=0：前线变体
        net.WriteUInt(ownerSlot, 8) -- 前线归属槽（0 = 无主）
        net.WriteUInt(#items, 8)
        for _, item in ipairs(items) do
            net.WriteUInt(item[1], 8)
            net.WriteEntity(item[2])
        end
    net.Broadcast()
end

--[[
    广播控制/解除控制动画通知（2026-08-16，数据层 ControlCallbacks 回调触发）：
      1. KardsControlAnim（被控单位实体 + 是否解除 + 落位阵线/槽位）——客户端播放
         控制动画：0.7s 移向牌桌中心 + z 上升 → 控制图标动画 → 落位；
      2. 布局广播（支援阵线两张 + 前线）——控制会跨线移动/重排，客户端据此更新
         布局状态并重排其余卡（被控卡在控制动画期间跳过复位，见 cl_init.lua
         net.Receive KardsFieldLayout 的 controlAnim 判定）。
    解除控制返回手牌路径不触发本函数（SimReturnToHand 经 ReturnToHand 事件走既有
    KardsReturnToHand 返回手牌动画，见 BroadcastReturnToHand）。

    @param card         table 卡牌句柄（控制/解除对象）
    @param isUncontrol  boolean true=解除控制 / false=控制
    @param landingZone  string|nil 控制落位阵线（"frontline"/"support"；解除时为 nil）
    @param landingSlot  number|nil 控制落位槽位（前线第 3 / 支援阵线右侧；解除时为 nil）
    @param fromOwner    string|nil 旋转起点归属（控制=原归属方；解除=控制者）
    @param toOwner      string|nil 旋转终点归属（控制=新控制者；解除=原归属方）
]]
function ENT:BroadcastControlAnim(card, isUncontrol, landingZone, landingSlot, fromOwner, toOwner)
    if not card or not IsValid(self) then return end
    -- 控制转移后归属已变更而实体仍存于原归属卡组槽的 fieldCardEnts，故跨两槽查找
    --（与 OnBattleStatsChanged 同款回退，2026-08-13）
    local unitEnt
    for s = 1, 2 do
        local d = self._kardsBattleDecks and self._kardsBattleDecks[s]
        if d and d.fieldCardEnts and d.fieldCardEnts[card] then
            unitEnt = d.fieldCardEnts[card]
            break
        end
    end
    if not IsValid(unitEnt) then
        -- 无实体（异常/数据层先于实体创建）：仍广播布局，客户端仅重排无动画
        self:BroadcastFieldLayout(1, "P1")
        self:BroadcastFieldLayout(2, "P2")
        self:BroadcastFrontlineLayout()
        return
    end
    local fromSlot = (fromOwner == "P1") and 1 or 2
    local toSlot = (toOwner == "P1") and 1 or 2
    -- 归属 NW 先同步（控制后卡牌归属已变）：客户端 KardsFieldFacing 观战视角按归属方
    -- 定向，动画期间 Think 跳过被控卡（yaw 由动画驱动），动画结束后按新归属接管
    unitEnt:SetNWInt("Kards_DeckSlot", toSlot)
    net.Start("KardsControlAnim")
        net.WriteEntity(self)
        net.WriteEntity(unitEnt)
        net.WriteBool(isUncontrol == true)
        net.WriteUInt((landingZone == "frontline") and 1 or 0, 8)
        net.WriteUInt(landingSlot or 0, 8)
        net.WriteUInt(fromSlot, 8) -- 观察者视角第一段动画 yaw 旋转起点（原归属方）
        net.WriteUInt(toSlot, 8)   -- 旋转终点（新归属方；在场玩家视角 yaw 恒朝向自身）
    net.Broadcast()
    -- 控制跨线落位后的布局广播（先动画后布局，可靠通道保证顺序 → 客户端先标记
    -- 控制动画中的卡，布局复位时跳过它，避免与专用动画冲突）
    self:BroadcastFieldLayout(1, "P1")
    self:BroadcastFieldLayout(2, "P2")
    self:BroadcastFrontlineLayout()
end

-- ====================================================================
-- 单位操作（readme 7.1 操作：移动或攻击；判定/决策全在战斗系统）
-- ====================================================================

-- 操作失败提示（KardsTableMsg → 客户端 Flash 显示，见 cl_init.lua）。
-- 失败原因可为引擎错误码（"code" / "code|参数"）或已是成品文案，统一经 ReasonFor
-- 按接收玩家语言解析（2026-10-17 多语言化）。
function ENT:SendOpFail(ply, msg)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    KARDS.TableSync.Broadcast("KardsTableMsg", { text = KARDS.Lang.ReasonFor(ply, msg) }, { ply })
end

--[[
    行动提示（2026-09-26 缺口 F）：向指定槽位玩家定向显示一条提示。

    复用观战提示通道 KardsHintObserver（其接收器 cl_battle_hint.lua 不校验接收者身份，
    故可直接定向发给参战玩家），语义由「观战同步」扩展为「定向行动提示」。
    当前唯一用途：节点效果拉入前线被拒绝时提示「前线已被敌方占领」。
    提示文字可为引擎错误码，按接收玩家语言解析（2026-10-17 多语言化）。

    @param slot number 目标槽位（1/2）
    @param text string 提示文字（错误码或成品文案）
]]
function ENT:SendActionHint(slot, text)
    local ply = self.Slots and self.Slots[slot]
    if not IsValid(ply) or not ply:IsPlayer() then return end
    net.Start("KardsHintObserver")
        net.WriteEntity(self)
        net.WriteString(ply:Nick())
        net.WriteString(KARDS.Lang.ReasonFor(ply, tostring(text or "")))
    net.Send(ply)
end

--[[
    单位操作统一入口守卫：对局已开始 + 当前回合方 + 单位实体有效
    （回合归属校验范例与 KardsEndTurn 一致，见 table_session.lua）。

    @param ply  Player 操作玩家
    @param slot number 玩家槽位
    @param ent  Entity 单位战场实体
    @return boolean 是否通过（不通过时已向玩家发送失败提示）
]]
function ENT:UnitOpGuard(ply, slot, ent)
    if not self._kardsFormalBattleStarted then
        self:SendOpFail(ply, "not_started")
        return false
    end
    if self._kardsTurnSlot ~= slot then
        self:SendOpFail(ply, "not_your_turn")
        return false
    end
    if not IsValid(ent) then
        self:SendOpFail(ply, "invalid_unit")
        return false
    end
    return true
end

--[[
    战场实体反查卡牌句柄（deck.fieldCardEnts 为 weak-keys 卡牌→实体表，无反向表需遍历）。
    总部实体（deck.hqEnt）不在此表内——总部仅作攻击目标，不作操作发起方。

    @param deck table 卡组槽数据表
    @param ent  Entity 战场实体
    @return table|nil 卡牌句柄（未登记返回 nil）
]]
function ENT:FieldCardByEnt(deck, ent)
    if not deck or not ent then return nil end
    for card, e in pairs(deck.fieldCardEnts or {}) do
        if e == ent then return card end
    end
    return nil
end

--[[
    卡牌句柄反查战场实体（2026-09-26 缺口 G）：跨两个卡组槽查 fieldCardEnts（归属变更后
    实体仍存于原归属槽，同 BroadcastControlAnim 的跨槽回退）；未命中且该卡为总部时
    回退该槽 deck.hqEnt（总部实体不在 fieldCardEnts 内）。

    @param card table 卡牌句柄
    @return Entity|nil 战场实体（未登记返回 nil）
]]
function ENT:BattleEntByCard(card)
    if not card then return nil end
    for s = 1, 2 do
        local d = self._kardsBattleDecks and self._kardsBattleDecks[s]
        if d and d.fieldCardEnts and d.fieldCardEnts[card] then
            return d.fieldCardEnts[card]
        end
    end
    if card:GetType() == "headquarter" then
        local d = self._kardsBattleDecks and self._kardsBattleDecks[(card:GetOwner() == "P2") and 2 or 1]
        if d and IsValid(d.hqEnt) then return d.hqEnt end
    end
    return nil
end

--[[
    刷新单位战场实体属性 NW（战斗后攻击/防御可能变化；部署时已初写，此处显式刷新，
    客户端 cl_card_text_overlay.lua ReadData _unitMode 分支每帧从 NW 读取）
]]
-- 词条图标白名单（2026-08-13）：图标文件已按词条参数名命名——materials/kards/effects/3d2d/
-- 下 deathrattle.png / ambush.png …（中文名 → 词条 id / active_effect / passive_effect）。
-- 仅收录 3d2d 文件夹内的图标（用户规格：只绘制 3d2d 文件夹内的词条图标）；情报
-- （other/情报.png）、闪击/山地/协力等无图标词条不参与。压制/控制为动态状态（非卡面
-- 词条），由 KeywordStates 派生，一并编码。客户端渲染见 lua/kards/cl_battle_keyword_icons.lua。
local KeywordIconFile = {
    deathrattle = true,
    ambush      = true,
    countdown   = true,
    immune      = true,
    shock       = true,
    mobilize    = true,
    frenzy      = true,
    guard       = true,
    smoke       = true,
    veteran     = true,
    guarded     = true,
    armor       = true,
    pincer      = true,
    stealth     = true,
    suppress    = true, -- 动态状态（被压制）
    control     = true, -- 动态状态（被控制）
    neutralized = true, -- 动态状态（被抑制）
}

--[[
    构建单位词条展示编码串（2026-08-13，客户端词条图标数据源）：
    格式 "id[:数值][,id[:数值]...]"，顺序 = 卡面词条数组顺序 + 追加动态状态（压制/控制/抑制）。
      - armor / countdown：编码当前数值（重甲 X / 倒计时当前值——倒计时每回合 -1，
        客户端据此显示等级数字并在数值变化时播放橙白闪烁）；
      - frenzy：编码剩余攻击次数（2 - 本回合已攻击次数；0 = 已攻击两次 → 图标恢复原色）；
      - shock：编码 0（未用，黄色）/ 1（已用——客户端闪烁两次后不再绘制）；
      - 其余有图标词条：仅 id。
    被抑制（HasActiveKeyword 失效）的词条不编码（图标随抑制消失）；隐蔽词条仅编码
    词条本体，客户端在 Hidden（Kards_IsHidden）期间整体不绘制（不泄露隐蔽单位词条）。

    @param card table 卡牌句柄（单位 / 总部）
    @return string 编码串（无词条返回 ""）
]]
function ENT:BuildUnitKeywordsStr(card)
    local parts = {}
    local battle = KARDS.Battle
    local tid = self.TableID
    local st = battle and battle.KeywordStates and battle.KeywordStates[tid]
    -- 隐蔽单位（2026-08-13 用户规格）：隐蔽期间只显示「隐蔽」图标（防泄露卡面
    -- 词条）；揭示（Hidden 清除）后经 BroadcastReveal 刷新词条 NW 恢复真实词条
    if st and KARDS.KeywordStates.Hidden.Is(st, card) then
        return "stealth"
    end
    local function active(id)
        return battle and battle.HasActiveKeyword and battle:HasActiveKeyword(tid, card, id)
    end
    local function push(id, val)
        if not KeywordIconFile[id] then return end
        parts[#parts + 1] = val and (id .. ":" .. val) or id
    end
    local kws = (card and card.GetKeywords and card:GetKeywords()) or {}
    for _, kw in ipairs(kws) do
        local id = type(kw) == "table" and kw[1] or kw
        if active(id) then
            if id == "armor" then
                push("armor", battle:GetKeywordValue(tid, card, "armor", 0))
            elseif id == "countdown" then
                local v = (st and KARDS.KeywordStates.Countdown.Get(st, card))
                    or battle:GetKeywordValue(tid, card, "countdown", 0)
                push("countdown", v)
            elseif id == "frenzy" then
                local n = st and KARDS.KeywordStates.Attack.Get(st, card) or 0
                push("frenzy", math.max(0, 2 - n))
            elseif id == "shock" then
                push("shock", (st and KARDS.KeywordStates.Shock.IsUsed(st, card)) and 1 or 0)
            else
                push(id)
            end
        end
    end
    -- 动态状态（外部施加，不经 HasActiveKeyword 过滤）：被压制 / 被控制 / 被抑制
    if st then
        if KARDS.KeywordStates.Suppression.Is(st, card) then push("suppress") end
        if KARDS.KeywordStates.Control.Get(st, card) then push("control") end
        if KARDS.KeywordStates.Inhibit.Is(st, card) then push("neutralized") end
    end
    -- 被守护 guarded（readme 7.2.2）：相邻存在守护单位且自身非守护 → 动态赋予（与
    -- CanAttackTarget 守护判定同款逻辑）；守护单位本身不获得被守护（active("guard") 排除）
    if battle and battle.Battlefield then
        local zone, owner = KARDS.Battlefield:FindCardZone(tid, card)
        if zone then
            local line = (zone == "support")
                and KARDS.Battlefield:GetSupport(tid, owner)
                or KARDS.Battlefield:GetFrontline(tid)
            local idx = nil
            for i = 1, KARDS.Battlefield.SLOT_COUNT do
                if line[i] == card then idx = i break end
            end
            if idx and not active("guard") then
                for _, a in ipairs({ idx - 1, idx + 1 }) do
                    if a >= 1 and a <= KARDS.Battlefield.SLOT_COUNT and line[a]
                        and battle:HasActiveKeyword(tid, line[a], "guard") then
                        push("guarded")
                        break
                    end
                end
            end
        end
    end
    return table.concat(parts, ",")
end

function ENT:SyncUnitNW(card, ent)
    if not IsValid(ent) then return end
    ent:SetNWInt("Kards_CardAttack", (card.GetStat and card:GetStat("attack")) or 0)
    ent:SetNWInt("Kards_CardDefense", (card.GetStat and card:GetStat("defense")) or 0)
    ent:SetNWInt("Kards_CardActionCost", (card.GetActionCost and card:GetActionCost()) or 0)
    -- 2026-08-13：词条展示串同步（客户端词条图标，见 BuildUnitKeywordsStr /
    -- cl_battle_keyword_icons.lua；战斗/倒计时/压制等变化后随本函数一并刷新）
    ent:SetNWString("Kards_UnitKeywords", self:BuildUnitKeywordsStr(card))
end

--[[
    被消灭单位实体延迟移除（2026-08-13 用户规格）：场上目标死亡（防御 ≤0 被消灭）后
    不立即消失，待客户端「最晚飘字（数值变动特效，cl_card_text_overlay.lua FX）结束
    +0.5s」再消失。流程：
      1. 立即从场登记摘除（fieldCardEnts[card] = nil，数据层已离场，布局/目标反查
         不再涉及该实体；实体仅作显示残留保留至延迟移除）
      2. 广播 KardsFieldDeath（客户端据此登记待移除实体，计算精确延迟）
      3. 客户端在其最晚飘字结束 +0.5s 后发 KardsFieldDeathRemove 通知 → 本方法注册
         的幂等 GuardRemove 移除实体
      4. 服务端兜底定时（FieldDeathServerRemoveDelay）防客户端未通知（断线/异常）

    调用方须先 SyncUnitNW 刷新死亡防御（≤0）NW——客户端防御变动飘字依赖该值。

    @param card table 已离场的死亡单位卡牌句柄（IsAlive 为 false）
    @param ent  Entity 单位战场实体（仍有效，将延迟移除）
]]
function ENT:ScheduleFieldDeathRemove(card, ent)
    if not IsValid(ent) then return end
    local deck = self._kardsBattleDecks
        and self._kardsBattleDecks[(card:GetOwner() == "P1") and 1 or 2]
    if not deck then return end
    -- 幂等（2026-09-27）：该实体已在死亡延迟移除中则直接返回，避免节点路径（CardLeave 分流）
    -- 与战斗路径（ApplyCombatOutcome / OnBattleStatsChanged）先后调用时重复播死亡音效与广播
    if deck.fieldRemovePendingEnt and deck.fieldRemovePendingEnt[ent] then return end
    if deck.fieldCardEnts then deck.fieldCardEnts[card] = nil end
    deck.fieldRemovePendingEnt = deck.fieldRemovePendingEnt or {}
    local removed = false
    local function GuardRemove()
        if removed then return end
        removed = true
        deck.fieldRemovePendingEnt[ent] = nil
        if not IsValid(ent) then return end
        if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(ent) then
            ent:Remove()
        end
    end
    deck.fieldRemovePendingEnt[ent] = GuardRemove
    -- 事件音效（2026-08-13）：单位阵亡 death（此刻 ent 仍有效，音源方位=死亡单位实体）
    self:BroadcastEventSound(card, "death", ent)
    -- 广播死亡：客户端计算「最晚飘字结束 +0.5s」后发 KardsFieldDeathRemove 通知
    net.Start("KardsFieldDeath")
        net.WriteEntity(self)
        net.WriteEntity(ent)
    net.Broadcast()
    -- 兜底定时（客户端未通知/断线时仍销毁）
    timer.Simple(FieldDeathServerRemoveDelay, function()
        if IsValid(self) and deck.fieldRemovePendingEnt and deck.fieldRemovePendingEnt[ent] then
            GuardRemove()
        end
    end)
end

--[[
    属性变更回调（t4 3D2D 数值同步，2026-08-12）：节点效果路径（trigger 伤害
    SimDealDamage / 战斗操作 SimFight，不经 ApplyCombatOutcome）改变单位/总部属性后，
    数据层经 StatsChangedCallbacks 回调本函数 → 刷新战场实体 NW（客户端 3D2D 文字
    每帧读取，见 cl_card_text_overlay.lua ReadData）。对局开始注册，见 StartFormalBattle。

    @param ...cards 受影响卡牌句柄（单位 / 总部；单位可能在伤害后已离场）
]]
function ENT:OnBattleStatsChanged(...)
    local layoutDirty = false -- 有单位离场：阵线布局变化，需广播复位（2026-08-12）
    for i = 1, select("#", ...) do
        local card = select(i, ...)
        if not card then return end
        local deck = self._kardsBattleDecks
            and self._kardsBattleDecks[(card:GetOwner() == "P1") and 1 or 2]
        if not deck then return end
        if card:GetType() == "headquarter" then
            -- 总部：仅防御（hqShort 文字读 Kards_CardDefense；总部驻留支援阵线不移除）
            local hqEnt = deck.hqEnt
            if IsValid(hqEnt) then
                hqEnt:SetNWInt("Kards_CardDefense", (card.GetStat and card:GetStat("defense")) or 0)
                -- 2026-08-13：总部词条展示串同步（客户端词条图标，与单位一致）
                hqEnt:SetNWString("Kards_UnitKeywords", self:BuildUnitKeywordsStr(card))
            end
        else
            -- 单位：仍在场刷新属性，已离场移除实体（与 ApplyCombatOutcome 一致）。
            -- 控制转移后归属已变更而实体仍存于原归属卡组槽的 fieldCardEnts，故跨两槽
            -- 查找（2026-08-13：SimControl/SimUncontrol 的 control 词条刷新依赖此回退）
            local ent
            for s = 1, 2 do
                local d = self._kardsBattleDecks and self._kardsBattleDecks[s]
                if d and d.fieldCardEnts and d.fieldCardEnts[card] then
                    ent = d.fieldCardEnts[card]
                    break
                end
            end
            if IsValid(ent) then
                if KARDS.Battlefield:FindCardZone(self.TableID, card) then
                    self:SyncUnitNW(card, ent)
                elseif not card:IsAlive() then
                    -- 被消灭（防御 ≤0，2026-08-13 用户规格）：先刷新死亡防御（≤0）NW
                    -- （客户端防御变动飘字），再延迟移除（最晚飘字结束 +0.5s）
                    self:SyncUnitNW(card, ent)
                    self:ScheduleFieldDeathRemove(card, ent)
                    layoutDirty = true
                else
                    -- 存活被移除（撤退/替换等）：立即消失（保持原行为）
                    ent:Remove()
                    deck.fieldCardEnts[card] = nil
                    layoutDirty = true
                end
            end
        end
    end
    -- 单位离场后广播阵线布局（节点效果路径不经实体层 ApplyCombatOutcome，此处补收口，
    -- 与 ApplyCombatOutcome 的广播一致）：支援阵线两张 + 前线
    if layoutDirty then
        for i, playerID in ipairs({ "P1", "P2" }) do
            self:BroadcastFieldLayout(i, playerID)
        end
        self:BroadcastFrontlineLayout()
    end
end

--[[
    单位操作结算后的同步收口：
      1. 属性 NW 刷新（操作涉及的卡牌实体按最新属性同步）
      2. 被消灭单位实体移除（数据层 SimRemoveFromField 触发 CardLeave → 渲染层仅移除
         CardEnts 绑定实体；手动创建的 unit 实体不在其中，此处按「已不在场」兜底移除）
      3. 布局广播（支援阵线两张 + 前线）与指挥点广播（行动花费已支付）

    @param cards table 操作涉及的卡牌句柄列表
]]
function ENT:ApplyCombatOutcome(cards)
    for _, card in ipairs(cards or {}) do
        -- 按归属找到该卡所属卡组槽（攻击方在本方槽；防御方/被反击目标可能在敌方槽）
        local deck = self._kardsBattleDecks
            and self._kardsBattleDecks[(card:GetOwner() == "P1") and 1 or 2]
        if deck then
            local ent = deck.fieldCardEnts and deck.fieldCardEnts[card]
            if IsValid(ent) then
                if KARDS.Battlefield:FindCardZone(self.TableID, card) then
                    self:SyncUnitNW(card, ent) -- 仍在场：刷新属性
                elseif not card:IsAlive() then
                    -- 被消灭（防御 ≤0，2026-08-13 用户规格）：先刷新死亡防御（≤0）NW
                    -- （客户端防御变动飘字），再延迟移除（最晚飘字结束 +0.5s）
                    self:SyncUnitNW(card, ent)
                    self:ScheduleFieldDeathRemove(card, ent)
                else
                    ent:Remove() -- 存活被移除（撤退/替换等）：立即消失
                    deck.fieldCardEnts[card] = nil
                end
            end
        end
    end
    -- 总部实体 NW 刷新（攻击总部后防御变化；总部不在 fieldCardEnts 内，
    -- 客户端 hqEnt 走 AddEntity 实体模式每帧读 NW，见 cl_init.lua KardsHQRevealDone）
    for s = 1, 2 do
        local deck = self._kardsBattleDecks and self._kardsBattleDecks[s]
        local hqEnt = deck and deck.hqEnt
        if IsValid(hqEnt) then
            local hq = KARDS.Battlefield:GetHQ(self.TableID, (s == 1) and "P1" or "P2")
            if hq then
                hqEnt:SetNWInt("Kards_CardDefense", (hq.GetStat and hq:GetStat("defense")) or 0)
                -- 2026-08-13：总部词条展示串同步（与 OnBattleStatsChanged 总部分支一致）
                hqEnt:SetNWString("Kards_UnitKeywords", self:BuildUnitKeywordsStr(hq))
            end
        end
    end
    for i, playerID in ipairs({ "P1", "P2" }) do
        self:BroadcastFieldLayout(i, playerID)
    end
    self:BroadcastFrontlineLayout()
    self:BroadcastCommandPoints()
end

--[[
    隐蔽揭示事件广播（2026-08-13）：SimAttack/SimEngage 数据层已先揭示（Hidden 清除），
    此处把「被揭示的隐蔽单位」实体广播给所有客户端——客户端播放翻面动画（先渲染
    正面 → 翻面到一半 z 抬升 → 落回正面）+ 揭示音效（cl_battle_stealth.lua
    net.Receive KardsReveal）。同时清除实体的 Kards_IsHidden NW（部署时初写，揭示后
    维持正面朝上——客户端 KardsFieldFacing 只改 yaw 保留 pitch，NW 仅作部署期视觉标记）。

    调用方（OnUnitEngage / OnUnitAttackHQ）：捕获攻击结算前的隐蔽状态（SimEngage/
    SimAttack 内部已揭示，结算后 Hidden.Is 恒为 false），涉及隐蔽单位时先广播再延迟
    ApplyCombatOutcome（RevealDelay）——翻面动画完成后才广播布局/属性 → 攻击动画。

    @param cards table 处于隐蔽（未揭示）的单位卡牌句柄列表（只含需翻面的单位）
]]
function ENT:BroadcastReveal(cards)
    local ents = {}
    for _, card in ipairs(cards or {}) do
        local deck = self._kardsBattleDecks
            and self._kardsBattleDecks[(card:GetOwner() == "P1") and 1 or 2]
        local e = deck and deck.fieldCardEnts and deck.fieldCardEnts[card]
        if IsValid(e) then
            e:SetNWBool("Kards_IsHidden", false) -- 揭示后维持正面朝上
            -- 2026-08-13：同步刷新词条 NW——隐蔽期词条串=stealth，此刻数据层已揭示
            -- （Hidden 清除），恢复真实词条；客户端揭示动画结束后以此入场显示
            e:SetNWString("Kards_UnitKeywords", self:BuildUnitKeywordsStr(card))
            ents[#ents + 1] = e
        end
    end
    if #ents == 0 then return end
    net.Start("KardsReveal")
        net.WriteEntity(self)
        net.WriteUInt(#ents, 8)
        for _, e in ipairs(ents) do net.WriteEntity(e) end
    net.Broadcast()
end

--[[
    属性变化音效广播（2026-08-13：stat_change.ogg 播放时机收窄）：数据层来源命中
    （属性与伤害节点「攻击/防御」分支 + 山地/动员词条，见 sh_battle_combat.lua
    NotifyStatSound 注释）→ 广播客户端播放 stat_change.ogg（接收见 cl_init.lua
    net.Receive KardsStatChangeSound）。回调注册于 StartFormalBattle（table_session.lua
    SetStatSoundCallback），与 OnBattleStatsChanged 同款依赖倒置。
]]
function ENT:BroadcastStatChangeSound()
    net.Start("KardsStatChangeSound")
        net.WriteEntity(self)
    net.Broadcast()
end

--[[
    属性变化飘字广播（2026-08-14：3D2D 飘字）：数据层攻击/防御/行动花费变动 → 广播
    客户端 3D2D 飘字（接收见 cl_card_text_overlay.lua net.Receive KardsStatChangeFX）。
    目标须在场：单位经 fieldCardEnts（跨两槽回退，控制转移后归属已变更）、总部经 hqEnt
    ——手牌无战场实体 → 不广播（用户规格「手牌的属性变动不使用飘字」）；单位已离场但
    实体尚存（死亡延迟移除，见 ScheduleFieldDeathRemove）→ 照常广播（死亡飘字预期）。

    @param card table 目标卡牌句柄
    @param slot string "attack"/"defense"/"actionCost"
    @param delta number 变动值（new - old，符号表增减；0 = 无实际变动，跳过）
    @param mod  string "increase"/"decrease"/"set"
    @param kind string "dmg"（伤害）/ "node"（节点效果）/ "other"（词条/修复/老兵等）
]]
function ENT:BroadcastStatChangeFX(card, slot, delta, mod, kind)
    if not card or not delta or delta == 0 then return end
    local ent
    if card:GetType() == "headquarter" then
        local owner = card:GetOwner()
        local deck = self._kardsBattleDecks and self._kardsBattleDecks[(owner == "P1") and 1 or 2]
        ent = deck and deck.hqEnt
    else
        for s = 1, 2 do
            local d = self._kardsBattleDecks and self._kardsBattleDecks[s]
            if d and d.fieldCardEnts and d.fieldCardEnts[card] then
                ent = d.fieldCardEnts[card]
                break
            end
        end
    end
    if not IsValid(ent) then return end
    local slotIdx = (slot == "attack") and 1 or (slot == "defense") and 2 or 3
    local modIdx = (mod == "increase") and 1 or (mod == "decrease") and 2 or 3
    local kindIdx = (kind == "dmg") and 1 or (kind == "node") and 2 or 3
    -- 改动后的当前值（2026-09-26 缺口 I / 计划 3.5）：白字语义为「设为」，客户端白字分支
    -- 显示该值而非变动绝对值。服务端在广播瞬间现读，避免网络到达顺序造成新旧值错位。
    local value = (slot == "actionCost") and (card:GetActionCost() or 0)
        or (card:GetStat(slot) or 0)
    net.Start("KardsStatChangeFX")
        net.WriteEntity(ent)
        net.WriteUInt(slotIdx, 4)
        net.WriteInt(delta, 16)
        net.WriteUInt(modIdx, 4)
        net.WriteUInt(kindIdx, 4)
        net.WriteInt(value, 16)
    net.Broadcast()
end

--[[
    事件音效广播（2026-08-13）：卡牌事件（部署/攻击/阵亡/打出/激活时/触发）发生时
    播放对应对象保存文件中的音效路径（编辑器属性页音效选择器，card:GetSounds()）。
    携带事件源实体：客户端参战者 2D 全屏、观战者据此 3D 方位定位（音源位置取
    WorldCenter）。未配置音效槽位静默（不广播不报错）。

    @param card     table 事件源卡牌句柄（须有 GetSounds 方法）
    @param eventKey string 事件键（deploy/attack/death/play/activate/trigger）
    @param ent      Entity|nil 事件源实体（音源方位；反制触发无实体时回退牌桌自身）
]]
function ENT:BroadcastEventSound(card, eventKey, ent)
    if not card then return end
    local snds = card.GetSounds and card:GetSounds() or {}
    local path = snds and snds[eventKey]
    -- 攻击音效自动分配（2026-08-14 规模接入）：未手动锁定（音效选择器五角星
    -- _manual.attack=true）时按 (单位类型×规模) 计算——仅步兵/坦克/炮兵有映射，
    -- 飞机（fighter/bomber）返回 nil → 回退手动配置 snds.attack；手动锁定优先。
    if eventKey == "attack" and not (snds._manual and snds._manual.attack) then
        local auto = card.GetUnitType and card.GetCardScale
            and KARDS.CardSounds.GetAttackSound(card:GetUnitType(), card:GetCardScale())
        if auto then path = auto end
    end
    -- 部署音效自动分配（2026-08-14 单位移动到前线，用户规格）：与攻击音效同款——
    -- 未手动锁定（音效选择器五角星 _manual.deploy=true）时按 (单位类型×规模) 计算
    -- （GetDeploySound 对缺失文件级联回退）；自动未命中回退手动配置 snds.deploy。
    if eventKey == "deploy" and not (snds._manual and snds._manual.deploy) then
        local auto = card.GetUnitType and card.GetCardScale
            and KARDS.CardSounds.GetDeploySound(card:GetUnitType(), card:GetCardScale())
        if auto then path = auto end
    end
    if not path or path == "" then return end
    net.Start("KardsEventSound")
        net.WriteEntity(self)        -- 牌桌实体：客户端据此判定参战/观战
        net.WriteEntity(ent or self) -- 事件源实体（音源方位；反制触发无实体时回退牌桌）
        net.WriteString(path)
    net.Broadcast()
end

--[[
    单位攻击冲刺广播（2026-09-26 缺口 G）：手动路径（点击交战 / 攻击总部）与效果路径
    （节点「交战」「战斗」经 UnitAction 事件）共用的唯一出口。

    载荷：牌桌实体 + 攻击方实体 + 目标实体 + 单位类型字符串（客户端据此选帧序列）。
    单位类型缺省 infantry；任一实体无效时静默返回（如目标已离场且实体已销毁）。
    必须在 ApplyCombatOutcome 之前调用：客户端先登记冲刺标记，随后到达的布局广播
    才会被 KardsFieldLayout 守卫跳过（否则冲刺中的单位被拉回原位）。

    @param attackerCard table 攻击方卡牌句柄
    @param targetCard   table 目标方卡牌句柄（单位或总部）
]]
function ENT:BroadcastUnitAction(attackerCard, targetCard)
    if not IsValid(self) or not attackerCard or not targetCard then return end
    local attackerEnt = self:BattleEntByCard(attackerCard)
    local targetEnt = self:BattleEntByCard(targetCard)
    if not IsValid(attackerEnt) or not IsValid(targetEnt) then return end
    local unitType = (attackerCard.GetUnitType and attackerCard:GetUnitType()) or "infantry"
    net.Start("KardsUnitAction")
        net.WriteEntity(self)
        net.WriteEntity(attackerEnt)
        net.WriteEntity(targetEnt)
        net.WriteString(unitType)
    net.Broadcast()
end

--[[
    老兵升级广播（2026-09-26 缺口 I）：数据层 SimVeteran 套用老兵外观后触发 UnitElevate
    事件，实体层订阅后经本方法广播 KardsUnitElevate → 客户端播 z 上升 + 依次白色飘字 +
    回落（三方视角一致）。

    载荷：牌桌实体 + 单位实体 + 行动花费是否变化（Bool）+ 行/攻/防三个变动值与三个新值。
    行动花费未变化时客户端不飘该条；攻防无论是否变化都飘，且白字语义为「设为」，
    显示新值而非变动值（见 cl_card_text_overlay.lua PlayStatFXWhite）。

    @param card    table 升级为老兵的卡牌句柄
    @param payload table UnitElevate 事件载荷（ackChanged/ackOld/ackNew/atkOld/atkNew/defOld/defNew）
]]
function ENT:BroadcastUnitElevate(card, payload)
    if not IsValid(self) or not card or type(payload) ~= "table" then return end
    local ent = self:BattleEntByCard(card)
    if not IsValid(ent) then return end
    local function num(v) return math.floor((tonumber(v) or 0) + 0.5) end
    local ackOld, ackNew = num(payload.ackOld), num(payload.ackNew)
    local atkOld, atkNew = num(payload.atkOld), num(payload.atkNew)
    local defOld, defNew = num(payload.defOld), num(payload.defNew)
    net.Start("KardsUnitElevate")
        net.WriteEntity(self)
        net.WriteEntity(ent)
        net.WriteBool(payload.ackChanged and true or false)
        net.WriteInt(ackNew - ackOld, 16) -- 行动花费变动值（带符号）
        net.WriteInt(ackNew, 16)          -- 行动花费新值
        net.WriteInt(atkNew - atkOld, 16) -- 攻击力变动值
        net.WriteInt(atkNew, 16)          -- 攻击力新值（白字显示此值）
        net.WriteInt(defNew - defOld, 16) -- 防御力变动值
        net.WriteInt(defNew, 16)          -- 防御力新值（白字显示此值）
    net.Broadcast()
end

--[[
    生成转换后的战场单位实体（2026-09-26 缺口 J）：按手牌部署配方生成新的战场单位实体，
    落位取旧实体的当前坐标与角度（交接动画在同一位置换显，不能换位）。

    新实体初始 SetNoDraw(true)：客户端交接动画在旧卡翻至侧立 90° 的瞬间才换显
    （onKeyframe "convertSwap"），避免换显前场上出现两张卡。

    @param oldCard table 被转换的旧卡牌句柄（其战场实体作为落位与清理基准）
    @param newCard table 转换后的新卡牌句柄
    @return Entity|nil 新战场实体（旧实体无效或模型应用失败返回 nil）
]]
function ENT:SpawnConvertedUnit(oldCard, newCard)
    if not IsValid(self) or not oldCard or not newCard then return nil end
    if not (KARDS.CardManifest and KARDS.CardManifest.CloneUnit) then return nil end
    local oldEnt = self:BattleEntByCard(oldCard)
    if not IsValid(oldEnt) then return nil end
    local owner = (newCard.GetOwner and newCard:GetOwner()) or "P1"
    local slot = (owner == "P2") and 2 or 1
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    if not deck then return nil end
    local safeName = self:DeckSafeName(newCard:GetID())
    local unitModelID = "kards_unit_" .. safeName
    KARDS.CardManifest.CloneUnit(unitModelID, "kards_deck/" .. safeName)
    local unitEnt = ents.Create("sent_pmx_static_imported")
    if not IsValid(unitEnt) then return nil end
    unitEnt:SetPos(oldEnt:GetPos())
    unitEnt:SetAngles(oldEnt:GetAngles())
    unitEnt:Spawn()
    local uok = unitEnt:ApplyImportedModel(unitModelID, 0.06) -- 世界 7.2×8.528
    if not uok then
        print(("[Kards] 转换单位实体模型应用失败: %s"):format(unitModelID))
        unitEnt:Remove()
        return nil
    end
    unitEnt:SetSolid(SOLID_NONE)
    local phys = unitEnt:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    unitEnt:SetNoDraw(true) -- 待客户端交接动画在 90° 换显
    -- 战场属性 NW（同部署配方；客户端卡面初始化与 3D2D 单位文字读取）
    unitEnt:SetNWString("Kards_DeckModelID", unitModelID)
    unitEnt:SetNWString("Kards_DeckSafeName", safeName)
    self:SyncUnitNW(newCard, unitEnt)
    unitEnt:SetNWBool("Kards_IsFieldCard", true)
    unitEnt:SetNWInt("Kards_DeckSlot", slot)
    -- 接入子物体系统：随牌桌移动/旋转 + 牌桌销毁时统一清理
    if self._kardsChildSystem then
        local relPos = self:WorldToLocal(oldEnt:GetPos())
        if relPos then
            self._kardsChildSystem:RegisterChild(unitEnt, relPos)
        end
    end
    -- 战场卡实体映射（布局广播反查；weak keys 防泄漏）+ 渲染层映射
    deck.fieldCardEnts = deck.fieldCardEnts or setmetatable({}, { __mode = "k" })
    deck.fieldCardEnts[newCard] = unitEnt
    if KARDS.BattleRender and KARDS.BattleRender.CardEnts then
        KARDS.BattleRender.CardEnts[self.TableID] = KARDS.BattleRender.CardEnts[self.TableID] or {}
        KARDS.BattleRender.CardEnts[self.TableID][newCard] = unitEnt
    end
    return unitEnt
end

--[[
    转换交接动画广播（2026-09-26 缺口 J）：广播 KardsUnitConvert（牌桌实体 + 旧实体 +
    新实体），客户端据此播 z 上升 + 翻面至侧立 90° 换显 + 反向回落；随后三连布局广播
    （同 BroadcastControlAnim）：先动画后布局，可靠通道保证顺序，客户端先标记转换中的
    实体，布局复位时跳过它。

    @param newCard table 转换后的新卡牌句柄（取归属决定布局广播的槽位）
    @param oldEnt  Entity 旧战场实体
    @param newEnt  Entity 新战场实体
]]
function ENT:BroadcastUnitConvert(newCard, oldEnt, newEnt)
    if not IsValid(self) or not IsValid(oldEnt) or not IsValid(newEnt) then return end
    net.Start("KardsUnitConvert")
        net.WriteEntity(self)
        net.WriteEntity(oldEnt)
        net.WriteEntity(newEnt)
    net.Broadcast()
    self:BroadcastFieldLayout(1, "P1")
    self:BroadcastFieldLayout(2, "P2")
    self:BroadcastFrontlineLayout()
end

--[[
    单位交战（readme 7.1 交战：一个单位攻击另一个单位，无论是否造成伤害；攻击总部不算交战）。
    判定/决策全在战斗系统 SimEngage；失败原因 → 客户端提示。

    @param ply          Player 操作玩家
    @param slot         number 玩家槽位
    @param attackerEnt  Entity 攻击方单位战场实体
    @param defenderEnt  Entity 防御方单位战场实体
]]
function ENT:OnUnitEngage(ply, slot, attackerEnt, defenderEnt)
    if not self:UnitOpGuard(ply, slot, attackerEnt) then return end
    if not IsValid(defenderEnt) then return self:SendOpFail(ply, "invalid_target") end
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local attacker = deck and self:FieldCardByEnt(deck, attackerEnt)
    if not attacker or attacker:GetType() ~= "unit" then
        return self:SendOpFail(ply, "invalid_unit")
    end
    -- 防御方可能在敌方卡组槽：遍历反查（总部不在此路径——攻击总部走 OnUnitAttackHQ）
    local defender = nil
    for s = 1, 2 do
        local d = self._kardsBattleDecks and self._kardsBattleDecks[s]
        defender = d and self:FieldCardByEnt(d, defenderEnt)
        if defender then break end
    end
    if not defender or defender:GetType() ~= "unit" then
        return self:SendOpFail(ply, "invalid_target")
    end
    -- 隐蔽揭示（2026-08-13）：SimEngage 内部已先揭示（数据层先揭示→再攻击→再触发
    -- 反制），此处捕获结算前的隐蔽状态——涉及隐蔽单位时先广播揭示事件（客户端翻面
    -- 动画+音效），延迟 RevealDelay 后再结算布局/属性广播（翻面完成后才播攻击动画）。
    -- 移动不揭示（仅 SimAttack/SimEngage 揭示），OnUnitMoveFront 无此分支。
    local st = KARDS.Battle and KARDS.Battle.KeywordStates
        and KARDS.Battle.KeywordStates[self.TableID]
    local hiddenCards = {}
    if st then
        if KARDS.KeywordStates.Hidden.Is(st, attacker) then hiddenCards[#hiddenCards + 1] = attacker end
        if KARDS.KeywordStates.Hidden.Is(st, defender) then hiddenCards[#hiddenCards + 1] = defender end
    end
    local ok, reason = KARDS.Battle:SimEngage(attacker, defender)
    -- SimEngage：检查失败返回 (false, 原因)；结算成功返回 finalDmg>0（交战无伤害也成功）
    if ok == false and reason ~= nil then
        return self:SendOpFail(ply, reason)
    end
    -- 事件音效（2026-08-13）：单位交战攻击 attack（音源方位=攻击方战场实体）
    self:BroadcastEventSound(attacker, "attack", attackerEnt)
    -- 攻击冲刺动画（2026-09-26 缺口 G）：先广播冲刺，客户端登记标记后到达的布局广播
    -- 会被守卫跳过（否则冲刺中的单位被拉回原位）
    self:BroadcastUnitAction(attacker, defender)
    if #hiddenCards > 0 then
        self:BroadcastReveal(hiddenCards)
        timer.Simple(RevealDelay, function()
            if IsValid(self) then self:ApplyCombatOutcome({ attacker, defender }) end
        end)
    else
        self:ApplyCombatOutcome({ attacker, defender })
    end
end

--[[
    单位攻击总部（readme 7.1：攻击总部不算交战，走简单攻击 SimAttack）。
    判定/决策全在战斗系统；失败原因 → 客户端提示。

    @param ply         Player 操作玩家
    @param slot        number 玩家槽位
    @param attackerEnt Entity 攻击方单位战场实体
]]
function ENT:OnUnitAttackHQ(ply, slot, attackerEnt)
    if not self:UnitOpGuard(ply, slot, attackerEnt) then return end
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local attacker = deck and self:FieldCardByEnt(deck, attackerEnt)
    if not attacker or attacker:GetType() ~= "unit" then
        return self:SendOpFail(ply, "invalid_unit")
    end
    local playerID = (slot == 1) and "P1" or "P2"
    local enemyID = (playerID == "P1") and "P2" or "P1"
    local hq = KARDS.Battlefield:GetHQ(self.TableID, enemyID)
    if not hq then return self:SendOpFail(ply, "no_enemy_hq") end
    -- 隐蔽揭示（2026-08-13）：隐蔽单位攻击总部同样先揭示（SimAttack 内部已先揭示）——
    -- 先广播揭示事件（客户端翻面动画+音效），延迟 RevealDelay 后再结算布局/属性广播
    local st = KARDS.Battle and KARDS.Battle.KeywordStates
        and KARDS.Battle.KeywordStates[self.TableID]
    local hiddenAttacker = st and KARDS.KeywordStates.Hidden.Is(st, attacker) or false
    local ok, reason = KARDS.Battle:SimAttack(attacker, hq)
    -- SimAttack：检查失败返回 (false, 原因)；结算成功返回 finalDmg>0（免疫等无伤害也成功）
    if ok == false and reason ~= nil then
        return self:SendOpFail(ply, reason)
    end
    -- 事件音效（2026-08-13）：单位攻击总部 attack（音源方位=攻击方战场实体）
    self:BroadcastEventSound(attacker, "attack", attackerEnt)
    -- 攻击冲刺动画（2026-09-26 缺口 G）：攻击总部同样冲刺（目标实体为总部）
    self:BroadcastUnitAction(attacker, hq)
    if hiddenAttacker then
        self:BroadcastReveal({ attacker })
        timer.Simple(RevealDelay, function()
            if IsValid(self) then self:ApplyCombatOutcome({ attacker }) end
        end)
    else
        self:ApplyCombatOutcome({ attacker })
    end
end

--[[
    单位移动至前线（readme 7.1 操作：支援阵线单位指向前线区域 → 移动）。
    判定/决策全在战斗系统 SimMoveToFrontline；失败原因 → 客户端提示。

    @param ply     Player 操作玩家
    @param slot    number 玩家槽位
    @param unitEnt Entity 单位战场实体
]]
function ENT:OnUnitMoveFront(ply, slot, unitEnt)
    if not self:UnitOpGuard(ply, slot, unitEnt) then return end
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local card = deck and self:FieldCardByEnt(deck, unitEnt)
    if not card or card:GetType() ~= "unit" then
        return self:SendOpFail(ply, "invalid_unit")
    end
    local ok, reason = KARDS.Battle:SimMoveToFrontline(card)
    if not ok then
        -- 作弊停局（reason=cheat）亦提示（对局已停止，客户端据此知晓异常）
        return self:SendOpFail(ply, reason or "move_failed")
    end
    -- 部署音效（2026-08-14 用户规格：单位移动到前线时播放该单位的部署音效，与
    -- 部署单位同款——手动锁定优先 / 按单位类型×规模自动分配，见 BroadcastEventSound
    -- "deploy" 分支）；音源实体 = 移动单位（观战者 3D 方位定位）
    self:BroadcastEventSound(card, "deploy", unitEnt)
    self:ApplyCombatOutcome({ card })
end

--[[
    前线单位撤退回本方支援阵线（readme 7.1 操作；判定/决策全在战斗系统 SimRetreat）

    成功（支援阵线未满 → 单位移到/插入支援阵线最右侧）后走 ApplyCombatOutcome：
    广播本方支援阵线布局 + 前线布局 + 指挥点——客户端 KardsFieldLayout 接收器据此
    驱动单位从当前位置（前线行）飞向支援阵线槽位（fieldRepos 组匀速位置动画，时长按
    位移等比缩放，见 cl_init.lua UnitMoveAnimDur），
    对方/观战端同步看到。失败原因 → 客户端提示（如支援阵线已满）。

    @param ply     Player 操作玩家
    @param slot    number 玩家槽位
    @param unitEnt Entity 单位战场实体
]]
function ENT:OnUnitRetreat(ply, slot, unitEnt)
    if not self:UnitOpGuard(ply, slot, unitEnt) then return end
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local card = deck and self:FieldCardByEnt(deck, unitEnt)
    if not card or card:GetType() ~= "unit" then
        return self:SendOpFail(ply, "invalid_unit")
    end
    local ok, reason = KARDS.Battle:SimRetreat(card)
    if not ok then
        return self:SendOpFail(ply, reason or "retreat_failed")
    end
    self:ApplyCombatOutcome({ card })
end

--[[
    对局结束（总部被摧毁，readme 7.1）：数据层 CheckHQDestroyed 判定胜负后触发
    GameOver 事件，本方法：
      1. 移除被摧毁总部实体（服务端 Remove 自动同步所有客户端「总部消失」；
         双毁时事件触发两次，各移除一方总部——幂等独立于广播）
      2. 首次触发时广播结算（所有客户端：双方 + 观战者；客户端据此播放 1 秒
         结算动画 + 胜负字样 + 继续按钮，见 cl_init.lua net.Receive KardsGameOver）
      3. 冻结回合推进（对局已结束，不再 EndTurn）

    @param winner   string 胜利方玩家标识（"P1"/"P2"）
    @param loser    string 失败方玩家标识
    @param destroyed string 本次被摧毁总部所属玩家标识
]]
function ENT:OnGameOver(winner, loser, destroyed)
    -- 1) 被摧毁总部实体移除（双毁时两次事件各移除一个；已移除 / 无效跳过）
    if destroyed then
        local dSlot = (destroyed == "P1") and 1 or 2
        local dDeck = self._kardsBattleDecks and self._kardsBattleDecks[dSlot]
        if dDeck and IsValid(dDeck.hqEnt) then
            dDeck.hqEnt:Remove()
            dDeck.hqEnt = nil
        end
    end
    -- 2) 首次触发广播结算（双毁第二次仅移除总部，不重复广播）
    if self._kardsGameOver or not (winner and loser) then return end
    self._kardsGameOver = { winner = winner, loser = loser }
    -- 对局已决：解除伪用户接管（2026-09-13；协程待选状态作废，门控恢复）
    self._kardsFakeUser = nil
    -- 对局已决：释放全服正式对战锁（规划 S1）。此后 _kardsTurnSlot 置空，
    -- 出牌 / 单位操作 / 结束回合的服务端门控全部拦截，本桌不会再走 Sim 结算，
    -- 他桌可立即开局（结算动画期间的本桌残留操作不落数据层）
    if KARDS.FormalBattleLock then KARDS.FormalBattleLock.Release(self) end
    net.Start("KardsGameOver")
        net.WriteEntity(self)
        net.WriteUInt((winner == "P1") and 1 or 2, 8)
        net.WriteUInt((loser == "P1") and 1 or 2, 8)
    net.Broadcast()
    -- 3) 冻结回合推进（客户端结算界面接管后不再发送结束回合）
    self._kardsTurnSlot = nil
    self:ClearTurnTimer() -- 回合超时定时器一并清理（2026-08-18 规划 D12：结算后不再推进回合）
    print(("[Kards] 对局结束: 胜利 P%d / 失败 P%d"):format(
        (winner == "P1") and 1 or 2, (loser == "P1") and 1 or 2))
end

--[[
    建立开始手牌卡牌槽（battle 模式）：每名玩家 HandSlotCount 张空卡占位（独立模型
    副本 kards_handslot + 子物体系统 RegisterChild），模拟手部拿手牌的扇形分布。
    支持任意张数 N=1~HandSlotCount 均居中：对称偏移序号 k=(N+1)/2−i（奇数 N 中心卡
    k=0 落于基准位；偶数 N 两中心卡之间对称，k 为半整数）。完整数学原理见
    《手牌分布的原理.md》，本函数逐段对应：
      坐标系约定与槽位对称 → §2；弧匹配 y=R−√(R²−x²) 与 z 阶梯 → §3；
      扇形角度 ψ 与符号（平躺时面法线朝上、玩家俯视位于正面，ψ 取正）→ §4；
      绕面法线 Rodrigues 旋转与 roll 修正 → §5-§6。
    各卡基础朝向为 HandSlotAngles：平行于地面平躺（卡面朝上）；P2 另在卡面平面内
    （yaw）旋转 180° 与 P1 镜像对称；扇形 ψ 在基础朝向上再绕面法线叠加。卡背渲染
    UK 卡背图（客户端复制落盘 + ClearCache，见 cl_init.lua KardsHandSlotCardMaterial），
    用于确认平躺+扇形后卡牌朝向是否正常。
    仅作槽位视觉定位，不参与战斗；由 LoadPlayerBattleDeck 首次进入对战时懒创建
    （幂等）。返回子物体实体数组（创建失败项自动跳过）；牌桌销毁时经子物体系统
    Destroy 一并清理。

    @return table 子物体实体数组（[1] = P1 第 1 张…[9] = P1 第 9 张、[10] = P2 第 1 张…，
        按 HandSlotCount 顺序；创建失败自动跳过）
]]
function ENT:CreateHandCardSlots()
    local list = {}
    if not self._kardsChildSystem then return list end
    for slot = 1, 2 do
        local sign = (slot == 1) and 1 or -1
        local center = self.HandSlotBase + Vector(0, sign * self.HandSlotHalfY, 0)
        -- 以中心卡的朝向为平面（卡牌局部系 x=宽轴、y=长轴、z=面法线，见 §2）：
        -- 扇形偏移在该系中计算，再经 HandSlotAngles 旋转到牌桌局部系。
        local ang = self.HandSlotAngles[slot]
        local X = ang:Forward()      -- 中心卡局部 x（宽轴）→ 牌桌局部系
        local Y = ang:Right()        -- 中心卡局部 y（长轴）→ 牌桌局部系
        local R = self.HandSlotFanRadius
        local centerIdx = (self.HandSlotCount + 1) / 2  -- 中心偏移基准：奇数 N 为整数（中心卡），偶数 N 为半整数（两中卡对称居中）
        for i = 1, self.HandSlotCount do
            local k = centerIdx - i                     -- 对称偏移序号：居中（奇数 N 含 k=0 中心卡；偶数 N 成对 ±k 对称）
            -- 弧匹配（见 §3）：x=k·间距；y=R−√(R²−x²)（过基准位原点的下弧；k 对称 → x/y/z 对称居中）；
            -- 弧匹配仅取 x/y（"不考虑 z 轴"），z 独立保留阶梯 z=−k·ZStep 沿面法线
            --（平躺 Up 朝上；取负使编号大的一侧（k<0）最高层、编号小的一侧最低——
            -- 与 135° 倾斜时"Up 越负世界高度越高"等效，维持各视角右侧最高层）。
            local xl = k * self.HandSlotSpacing
            local yl = R - math.sqrt(R * R - xl * xl)
            local zl = -k * self.HandSlotZStep
            local rel = center + X * xl + Y * yl + ang:Up() * zl
            -- 扇形角度（见 §4）：玩家俯视视角 k>0 侧（编号小的一侧）逆时针、k<0 侧
            --（编号大的一侧）顺时针，卡平面内原点→圆心连线垂直卡底；精确垂直角
            -- atan2(xl, R−yl) 当前仅 ±9° 不可见，故用显式半展开角 HandSlotFanAngle。
            -- 卡平躺（HandSlotAngles roll=0）后面法线朝上、玩家俯视位于法线正面，
            -- 所见方向与数学方向一致，故 psi 取正（原 135° 倾斜时法线朝下、位于反面，
            -- 取负，已废弃）。
            local maxIdx = (self.HandSlotCount - 1) / 2  -- 角度归一化分母（N=9 时为 4；偶数 N 为半整数）
            local psi = (k / maxIdx) * math.rad(self.HandSlotFanAngle)
            local card = self:SpawnHandSlotCard(rel, self.HandSlotAngles[slot], slot)
            if IsValid(card) then
                if self._kardsChildSystem:RegisterChild(card, rel) then
                    -- 基础位置写 NW：客户端按视角修正 z（P1/P2 视角用服务端 z、
                    -- 观战视角还原到更低基线，见 cl_init.lua KardsHandSlotFacing）
                    card:SetNWVector("Kards_HandSlotBasePos", rel)
                    -- RegisterChild 将局部角度重置为平躺（Angle(0,0,0)），需重新施加：
                    -- 绕自身面法线旋转 ψ（Rodrigues + roll 修正，公式见 §5-§6）。
                    -- 本 GMod 版本 Angle:RotateAroundAxis 既无返回值也不就地修改
                    --（曾导致 SetLocalAngles 拿到 nil / 角度始终无变化），故用显式向量旋转。
                    local base = self.HandSlotAngles[slot]
                    local up = base:Up()
                    local cosP, sinP = math.cos(psi), math.sin(psi)
                    local function rotV(v)
                        return v * cosP + up:Cross(v) * sinP
                    end
                    local fwd = rotV(base:Forward())
                    local rgt = rotV(base:Right())
                    local total = fwd:Angle()
                    local r0 = total:Right()
                    total.roll = total.roll + math.deg(math.atan2(fwd:Cross(r0):Dot(rgt), r0:Dot(rgt)))
                    card:SetLocalAngles(total)
                    -- 扇形基准角度写 NW（Vector 存 p/y/r）：客户端三视角规则读取后本地
                    -- 翻转（本方保持正面朝上 / 对方绕长轴 180° 背面朝上），见
                    -- cl_perspective.lua ApplyHandFacing
                    card:SetNWVector("Kards_HandBaseAng", Vector(total.p, total.y, total.r))
                    -- 观战视角独立扇形角度（最早方法，135° 倾斜基准 + ψ 绕面法线、
                    -- ψ 取负——135° 时面法线朝下、俯视位于反面，与 §4 平躺取正相反）：
                    -- 独立于平躺扇形，客户端观战分支（LocalView=nil）直接读取应用，
                    -- 见 cl_perspective.lua ApplyHandFacing。
                    do
                        local lbase = self.HandSlotLegacyAngles[slot]
                        local lup = lbase:Up()
                        local lpsi = -psi -- 弧度；135° 倾斜方案 ψ 取负
                        local lc, ls = math.cos(lpsi), math.sin(lpsi)
                        local lfwd = lbase:Forward() * lc + lup:Cross(lbase:Forward()) * ls
                        local lrgt = lbase:Right() * lc + lup:Cross(lbase:Right()) * ls
                        local ltotal = lfwd:Angle()
                        local lr0 = ltotal:Right()
                        ltotal.roll = ltotal.roll + math.deg(math.atan2(lfwd:Cross(lr0):Dot(lrgt), lr0:Dot(lrgt)))
                        card:SetNWVector("Kards_LegacyFanAng", Vector(ltotal.p, ltotal.y, ltotal.r))
                    end
                    list[#list + 1] = card
                else
                    card:Remove()
                end
            end
        end
    end
    return list
end
