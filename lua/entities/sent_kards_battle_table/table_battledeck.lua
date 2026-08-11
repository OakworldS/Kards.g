-- Kards 战斗牌桌实体服务端代码：卡组槽段（re.md T-H1 拆分，由 init.lua include）
-- 职责：battle 模式卡组槽加载/生成（6 档厚度卡堆 + 总部 + 抽牌临时卡 + 手牌槽）、
-- 卡组存档读取与句柄构造（LoadPlayerDeck / DeckCardHandleFromFile / 缓存 B-M4）、
-- 卡堆档位切换、手牌/卡组剩余数同步。
-- 跨文件共享的 ENT 方法 helper（EnsureBattleDeckManifest / EnsureHandSlotManifest /
-- EnsureDeckPileSingleManifest）亦定义于此。

local ENT = scripted_ents.GetStored("sent_kards_battle_table").t

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
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[slot]
        if deck then
            deck.hqLeft = true
            ent:SetDeckPileTier(slot)
        end
    end)

    -- 总部动画完成（客户端 StartHQReveal onComplete 发送，仅参战者）：把总部实体模型
    -- 切换为 basic_card_unit（短卡 + UV 裁切）。服务端 ApplyImportedModel 权威（模型
    -- ID/缩放同步所有客户端）；客户端渲染按各自本地 manifest——客户端 onComplete 已
    -- 同步 CloneUnit + ClearCache + PrefillUnitCrop 预填，切换时材质已就绪。
    net.Receive("KardsHQRevealDone", function(_, ply)
        local ent = net.ReadEntity()
        local slot = net.ReadUInt(8)
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or data.slot ~= slot then return end -- 仅本方总部
        local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[slot]
        if not deck or not IsValid(deck.hqEnt) or not deck.hqUnitModelID then return end
        if KARDS.CardManifest and KARDS.CardManifest.CloneUnit then
            KARDS.CardManifest.CloneUnit(deck.hqUnitModelID, "kards_deck/hq_" .. deck.hqSafe)
            local ok = deck.hqEnt:ApplyImportedModel(deck.hqUnitModelID, 0.06) -- 世界 7.2×8.528
            if not ok then
                print(("[Kards] 总部 unit 模型应用失败: %s"):format(deck.hqUnitModelID))
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

    -- 打出卡牌（客户端拖拽松手在非手牌区域发送）：手牌实体 + 目标槽位（0 = 指令）→ 服务端权威打出
    net.Receive("KardsPlayCard", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
        local data = ply._kardsTable
        if not data or data.ent ~= ent or not data.slot then return end
        local cardEnt = net.ReadEntity()
        local slotIndex = net.ReadUInt(8)
        ent:OnPlayCard(ply, data.slot, cardEnt, slotIndex)
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
        unitType = unitType, keywords = app.keywords,
        combatModifiers = app.combatModifiers,
    })
    -- 解析效果路径并加载效果文件（canvas 保存时把 INE 导出路径写入 cardAppearance.effectPath）：
    -- LoadEffect 得到 { nodes, connections, dataConnections, variables, functions }，
    -- 与 SimPlayCard 消费的 card.effect 结构同构，挂上后打出指令即走节点 base 解析执行；
    -- 无 effectPath 或文件缺失/节点为空 → 不挂（指令走演示效果分支）
    if app.effectPath and app.effectPath ~= "" then
        local effect = KARDS.CardEditor.SaveSystem.LoadEffect(app.effectPath)
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
    卡堆档位模型的世界高度（读 manifest bounds 高度 × 缩放）：
    档位模型原点在底面中心（mins z = -0.75 模型单位 = 底面下方 0.045 世界），实体原点放
    DeckSlotBase 时底面与旧「单卡逐张堆叠」的底面一致（见 LoadPlayerBattleDeck 注释）。
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
    -- 单张档为 basic_card 副本（manifest 需按需创建，见 KARDS.CardManifest.EnsureDeckPileSingle）；
    -- 其余档位为 PMXStaticImporter.exe 导入的原始模型，manifest 已存在
    if modelID == self.DeckPileModelIDs[1] and not KARDS.CardManifest.EnsureDeckPileSingle() then
        return nil
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
            ent:SetLocalAngles(Angle(0, self.DeckSlotYaw[slotIdx], 0))
        end
        ent:SetNWString("Kards_DeckSafeName", safeName) -- 抽牌动画翻面时找卡面文件（客户端 InitDrawCardFace）
        ent:SetNWInt("Kards_DeckSlot", slot)            -- 槽位（客户端卡背初始化/堆叠可见性按槽分组）
        ent:SetNWString("Kards_CardType", card:GetType()) -- 卡牌类型（客户端拖拽腾位预览/打出判定：unit/command/counter_command）
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
    -- NW：卡名（卡背国家查询用）+ 模型副本标识 + 卡组槽卡标记（客户端卡背初始化）
    ent:SetNWString("Kards_CardName", card:GetName())
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
         - 无卡组：不生成总部实体，但卡堆仍显示——remaining 用 39 视觉占位
           （档位 snapUp → 40 档整叠 usa 卡背，见下方数据块注释）
      3. 抽牌：服务端生成一张临时卡实体（位于当前可见卡堆顶，manifest 后缀 _d<serial>
         唯一化），客户端抽牌动画将其移入手牌并留在手牌位（卡面 + 3D2D 文字）
      4. 卡背统一 usa（测试版暂定，客户端钩子固定改写档位模型 front 槽）

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
    end
    -- 首次进入对战时不再建立空手牌槽（占位空卡）：起手发牌/抽牌经 OnBattleDraw 生成
    -- 真实卡牌实体并落手牌位（2026-08-10 移除占位空手牌，见重新调度流程）
    -- 抽牌回调（SimDraw / 额外抽取 → 通知客户端抽牌动画；幂等每桌一次）
    -- overdraw（第三参数）= 本次抽牌是否爆牌（手牌已达上限），随广播发给客户端
    if not self._kardsDrawCallbackRegistered then
        self._kardsDrawCallbackRegistered = true
        KARDS.Battle:SetDrawCallback(self.TableID, function(playerID, drawn, overdraw)
            self:OnBattleDraw(playerID, drawn, overdraw)
        end)
    end
    local playerID = (slot == 1) and "P1" or "P2"
    -- 1) 数据层：有卡组存档且为 39 张 → SimSetupDeck（洗牌一次，此后顺序固定）
    local deck = self:LoadPlayerDeck(ply)
    local pool = {}
    if deck then
        for _, entry in ipairs(deck.cards or {}) do
            for _ = 1, (entry.count or 1) do
                local h = self:DeckCardHandleFromFile(entry.fileName, playerID)
                if h then pool[#pool + 1] = h end
            end
        end
        if #pool == 39 then
            KARDS.Battle:SimSetupDeck(playerID, pool)
        else
            print(("[Kards] 卡组槽: 卡组 %s 非 39 张（%d），数据层跳过（仅视觉放置）"):format(tostring(deck.name), #pool))
        end
    else
        net.Start("KardsTableMsg") net.WriteString("未找到你的卡组存档（请先在组卡模式保存），卡组槽显示默认卡背") net.Send(ply)
    end
    -- 2) 视觉：6 档厚度卡堆模型 + 隐藏总部（性能优化，见上方函数注释与 L1258 常量块）。
    --    每槽预生成全部档位实体（同时仅一档可见，SetNoDraw 切换，见 SetDeckPileTier）；
    --    卡堆剩余卡数 = remaining +（总部仍在堆顶时 1）；无卡组时卡堆仍显示
    --    （remaining 用 39 视觉占位 → 40 档，整叠为 usa 卡背，见下方 hasDeck 判断）。
    local slotIdx = (slot == 1) and 1 or 2
    local base = self.DeckSlotBase[slotIdx]
    local yaw = self.DeckSlotYaw[slotIdx]
    local pileEnts = {}
    for _, tier in ipairs(self.DeckPileTiers) do
        local scale = (tier == 1) and self.DeckPileScaleSingle or self.DeckPileScale
        local pent = self:SpawnDeckPile(self.DeckPileModelIDs[tier], base, yaw, slot, tier, scale)
        if IsValid(pent) then
            pent:SetNoDraw(true) -- 初始全部隐藏，由 SetDeckPileTier 切换可见档
            pileEnts[tier] = pent
        end
    end
    -- 3) 总部实体：仍为独立卡牌实体但初始隐藏（SetNoDraw(true)，堆叠厚度已由档位
    --    模型表现）；对局开始头像揭晓完成后客户端播放总部动画（cl_init.lua
    --    StartHQReveal 显式 SetNoDraw(false) + 发送 KardsHQRevealStart，服务端据此
    --    把卡堆剩余卡数改为「不含总部」）移动到头像旁，动画结束落位本方支援阵线。
    local hasDeck = #pool == 39
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
    -- 无卡组（hasDeck=false）：不生成总部实体，但卡堆仍显示——remaining 用 39 视觉占位
    -- （档位 snapUp → 40 档整叠 usa 卡背），数据层无卡组不会触发抽牌，占位保持不变
    self._kardsBattleDecks[slot] = {
        pileEnts = pileEnts,   -- 档位实体表：tier → 实体（SetDeckPileTier 切换可见性）
        hqEnt = hqEnt,         -- 隐藏总部实体（有卡组时存在；动画时客户端显式显示）
        hqSafe = hqSafe,       -- 总部文件名 safeName（动画后切换 unit 模型用）
        hqUnitModelID = hqSafe and ("kards_unit_hq_" .. hqSafe) or nil, -- 总部 unit 模型标识
        hqLeft = not hasDeck,  -- 总部是否已离开堆顶（无卡组无总部 → true：剩余卡数不 +1）
        remaining = 39,        -- 数据层剩余普通卡数（抽牌递减；无卡组时为视觉占位 39 → 40 档）
        currentTier = 0,       -- 当前可见档位（SetDeckPileTier 写入）
        drawEnts = {},         -- 抽牌临时卡实体列表（退出/销毁时清理）
        playerID = playerID,
    }
    self:SetDeckPileTier(slot)
    self:SyncBattleCounts(slot) -- 悬停信息面板数据（手牌数 / 卡组剩余数 → NW）
    print(("[Kards] 卡组槽: %s 已就绪（%s，档位 %d）"):format(playerID, hasDeck and "有卡组" or "无卡组", self._kardsBattleDecks[slot].currentTier))
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

    @param playerID string 抽牌玩家（"P1"/"P2"）
    @param drawn    table 抽到的卡牌句柄列表
    @param overdraw boolean|nil 本次抽牌是否爆牌（至少一张卡因手牌已达上限未进手牌）
    @param overdrawnCards table|nil 爆牌卡表 [card] = true（per-card，支持部分爆牌）
]]
function ENT:OnBattleDraw(playerID, drawn, overdraw, overdrawnCards)
    if not drawn or #drawn == 0 then return end
    local slot = (playerID == "P1") and 1 or 2
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    -- 落位手牌扇形总数（发牌即最终张数；数据层已把抽到的卡移入手牌，爆牌时
    -- 卡不进手牌 → total 保持上限 9，客户端据此跳过手牌重排，只播弃牌动画）
    local total = #(KARDS.Deck:GetHand(self.TableID, playerID) or {})
    -- 重新调度补抽标记：OnMulliganSubmit 已把被弃牌序号放入 pendingDrawIndexes
    local isMulliganReplace = deck and deck.pendingDrawIndexes and #deck.pendingDrawIndexes > 0
    for _, card in ipairs(drawn) do
        -- 数据层已把该卡移出牌堆：剩余卡数递减 + 档位切换（即使临时卡实体生成失败
        -- 也应先减，保证卡堆视觉与数据层一致）
        if deck then
            deck.remaining = math.max(0, (deck.remaining or 0) - 1)
            self:SetDeckPileTier(slot)
        end
        -- 爆牌判定（per-card）：overdrawnCards 缺省时回退到整体 overdraw 标记
        local isCardOverdraw = overdraw and (overdrawnCards == nil or overdrawnCards[card])
        -- 手牌序号：爆牌卡不进手牌（不占序号，idx=0 占位，客户端爆牌分支不使用）；
        -- 重新调度补抽卡占用被弃牌的原序号（原位替换）；其余按抽牌顺序递增
        local idx
        if isCardOverdraw then
            idx = 0
        elseif deck and deck.pendingDrawIndexes and #deck.pendingDrawIndexes > 0 then
            idx = table.remove(deck.pendingDrawIndexes, 1)
        else
            deck.handCounter = (deck.handCounter or 0) + 1
            idx = deck.handCounter
        end
        -- 抽牌临时卡实体：位于当前可见卡堆顶部，客户端播放发牌/抽牌动画
        local ent = self:SpawnDeckDrawCard(slot, card)
        if IsValid(ent) then
            if deck then
                -- 手牌序号 → 实体（重新调度弃牌时按实体找回原序号）
                deck.handIndexByEnt = deck.handIndexByEnt or setmetatable({}, { __mode = "k" })
                deck.handIndexByEnt[ent] = idx
            end
            net.Start("KardsTableDeckDraw")
                net.WriteEntity(ent)
                net.WriteUInt(slot, 8)
                net.WriteUInt(idx, 8)
                net.WriteUInt(total, 8)
                net.WriteBool(isMulliganReplace or false)
                net.WriteBool(isCardOverdraw or false) -- 爆牌标记（客户端播专属弃牌动画）
                net.WriteString(card:GetName())
            net.Broadcast()
        end
    end
    self:SyncBattleCounts(slot) -- 抽牌后同步手牌数 / 卡组剩余数（NW 自动广播）
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

--[[
    检查双方重新调度是否均已完成：所有在场槽位的 deck 均已提交（mulliganDone）
    → 调用 StartFirstTurn 开始先手回合（回合开始事件 + 指挥点 0→1，见
    table_session.lua StartFirstTurn）。不在场槽位不计入（单机 kards_forcestart
    仅一方在场时亦可推进）。

    调用点：OnMulliganSubmit 末尾（正常提交）与 OnMulliganReady 无卡组跳过分支。
    幂等：StartFirstTurn 内部有 _kardsFirstTurnStarted 防重复。
]]
function ENT:CheckAllMulligansDone()
    if self._kardsFirstTurnStarted then return end
    for slot, p in pairs(self.Slots or {}) do
        if IsValid(p) and p:IsPlayer() then
            local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
            if not (deck and deck.mulliganDone) then return end -- 仍有玩家未提交
        end
    end
    self:StartFirstTurn()
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
]]
function ENT:OnPlayCard(ply, slot, cardEnt, slotIndex)
    local function reject()
        net.Start("KardsPlayCardRejected")
            net.WriteEntity(self)
            net.WriteUInt(slot, 8)
            net.WriteEntity(cardEnt)
        net.Send(ply)
    end
    -- 校验：对局已开始、当前回合方、实体有效且属于本槽抽出（在手牌中）
    if not self._kardsFormalBattleStarted or self._kardsTurnSlot ~= slot then
        return reject()
    end
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local card = deck and deck.entCard and deck.entCard[cardEnt]
    if not card then return reject() end
    local playerID = (slot == 1) and "P1" or "P2"
    -- unit 战场实体（单位打出时创建，KardsCardPlayed 广播携带；指令为 nil）
    local unitEnt = nil
    local ctype = card:GetType()
    if ctype == "command" or ctype == "counter_command" then
        -- 指令 / 反制：战斗系统打出（play_command 刻 + 反制钩子 + 指挥点支付）
        if not KARDS.Battle:SimPlayCard(playerID, card, nil) then return reject() end
        KARDS.Deck:RemoveFromHand(self.TableID, playerID, card)
        deck.entCard[cardEnt] = nil
        deck.cardEnt[card] = nil
        self:SyncBattleCounts(slot)
        -- 实体淡出移除（子物体系统 1 秒淡出后销毁；非子物体直接移除）
        if self._kardsChildSystem and not self._kardsChildSystem:RemoveChild(cardEnt) then
            cardEnt:Remove()
        end
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
    -- 广播打出结果（所有客户端：本方本地收尾拖拽动画、对方/观战同步战场卡）。
    -- 第 5 字段 = unit 战场实体（单位>0 且创建成功；指令/NULL：客户端走原实体全程动画）
    net.Start("KardsCardPlayed")
        net.WriteEntity(self)
        net.WriteUInt(slot, 8)
        net.WriteEntity(cardEnt)
        net.WriteUInt(landed, 8)
        net.WriteEntity(unitEnt or NULL)
    net.Broadcast()
    -- 单位：广播该玩家支援阵线布局（各卡槽位 → 实体；客户端按槽位 → 列坐标驱动/复位）
    if ctype == "unit" then
        self:BroadcastFieldLayout(slot, playerID)
    end
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

-- ====================================================================
-- 单位操作（readme 7.1 操作：移动或攻击；判定/决策全在战斗系统）
-- ====================================================================

-- 操作失败提示（KardsTableMsg → 客户端 Flash 显示，见 cl_init.lua）
function ENT:SendOpFail(ply, msg)
    if not IsValid(ply) or not ply:IsPlayer() then return end
    net.Start("KardsTableMsg")
        net.WriteString(msg)
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
        self:SendOpFail(ply, "对战尚未开始")
        return false
    end
    if self._kardsTurnSlot ~= slot then
        self:SendOpFail(ply, "当前不是你的回合")
        return false
    end
    if not IsValid(ent) then
        self:SendOpFail(ply, "单位实体无效")
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
    刷新单位战场实体属性 NW（战斗后攻击/防御可能变化；部署时已初写，此处显式刷新，
    客户端 cl_card_text_overlay.lua ReadData _unitMode 分支每帧从 NW 读取）
]]
function ENT:SyncUnitNW(card, ent)
    if not IsValid(ent) then return end
    ent:SetNWInt("Kards_CardAttack", (card.GetStat and card:GetStat("attack")) or 0)
    ent:SetNWInt("Kards_CardDefense", (card.GetStat and card:GetStat("defense")) or 0)
    ent:SetNWInt("Kards_CardActionCost", (card.GetActionCost and card:GetActionCost()) or 0)
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
                else
                    ent:Remove() -- 已离场（被消灭）：移除实体
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
    单位交战（readme 7.1 交战：一个单位攻击另一个单位，无论是否造成伤害；攻击总部不算交战）。
    判定/决策全在战斗系统 SimEngage；失败原因 → 客户端提示。

    @param ply          Player 操作玩家
    @param slot         number 玩家槽位
    @param attackerEnt  Entity 攻击方单位战场实体
    @param defenderEnt  Entity 防御方单位战场实体
]]
function ENT:OnUnitEngage(ply, slot, attackerEnt, defenderEnt)
    if not self:UnitOpGuard(ply, slot, attackerEnt) then return end
    if not IsValid(defenderEnt) then return self:SendOpFail(ply, "目标单位无效") end
    local deck = self._kardsBattleDecks and self._kardsBattleDecks[slot]
    local attacker = deck and self:FieldCardByEnt(deck, attackerEnt)
    if not attacker or attacker:GetType() ~= "unit" then
        return self:SendOpFail(ply, "单位实体无效")
    end
    -- 防御方可能在敌方卡组槽：遍历反查（总部不在此路径——攻击总部走 OnUnitAttackHQ）
    local defender = nil
    for s = 1, 2 do
        local d = self._kardsBattleDecks and self._kardsBattleDecks[s]
        defender = d and self:FieldCardByEnt(d, defenderEnt)
        if defender then break end
    end
    if not defender or defender:GetType() ~= "unit" then
        return self:SendOpFail(ply, "目标单位无效")
    end
    local ok, reason = KARDS.Battle:SimEngage(attacker, defender)
    -- SimEngage：检查失败返回 (false, 原因)；结算成功返回 finalDmg>0（交战无伤害也成功）
    if ok == false and reason ~= nil then
        return self:SendOpFail(ply, reason)
    end
    self:ApplyCombatOutcome({ attacker, defender })
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
        return self:SendOpFail(ply, "单位实体无效")
    end
    local playerID = (slot == 1) and "P1" or "P2"
    local enemyID = (playerID == "P1") and "P2" or "P1"
    local hq = KARDS.Battlefield:GetHQ(self.TableID, enemyID)
    if not hq then return self:SendOpFail(ply, "敌方总部不存在") end
    local ok, reason = KARDS.Battle:SimAttack(attacker, hq)
    -- SimAttack：检查失败返回 (false, 原因)；结算成功返回 finalDmg>0（免疫等无伤害也成功）
    if ok == false and reason ~= nil then
        return self:SendOpFail(ply, reason)
    end
    self:ApplyCombatOutcome({ attacker })
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
        return self:SendOpFail(ply, "单位实体无效")
    end
    local ok, reason = KARDS.Battle:SimMoveToFrontline(card)
    if not ok then
        -- 作弊停局（reason=cheat）亦提示（对局已停止，客户端据此知晓异常）
        return self:SendOpFail(ply, reason or "移动失败")
    end
    self:ApplyCombatOutcome({ card })
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
