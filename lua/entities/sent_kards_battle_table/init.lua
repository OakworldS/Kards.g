-- Kards 战斗牌桌实体服务端代码
-- 固定应用前置模组导入的 wooden_table 模型（牌桌）：
-- 导入后为 z-up 平躺（manifest bounds 高度轴在 Z），无需轴修正；
-- 桌体为静态箱体碰撞（ApplyImportedModel 内部冻结运动）。
-- 玩家进入/退出/准备：客户端按 E 请求（校验槽位占用 → 冻结+无敌+空武器 →
-- 广播进入），再按 E 退出（恢复状态），按 F4 准备；牌桌销毁时解冻玩家并删变量库。
--
-- 文件结构（re.md T-H1 拆分）：本文件保留实体骨架（Initialize/Think/GetKardsCenter/
-- net 消息注册/实体字段），职责段拆分为四个被 include 的文件（各文件头
-- local ENT = scripted_ents.GetStored(...).t 后定义方法）：
--   table_session.lua    —— 玩家会话（进入/退出/准备/对战开始）+ 玩家会话状态机（T-M2）
--   table_deckmode.lua   —— 组卡模式（模式切换/铺卡/卡组堆叠/保存）
--   table_battledeck.lua —— 卡组槽加载/生成（档位卡堆/总部/抽牌/手牌槽）+ 句柄缓存（B-M4）
--   table_cleanup.lua    —— 销毁清理（OnRemove / EntityRemoved 兜底）

AddCSLuaFile("shared.lua")
include("shared.lua")

-- 固定应用的模型与缩放（wooden_table 约 20x8.2x10 单位，×3 后约 60x24.6x30）
ENT.KardsModelID = "wooden_table"
ENT.KardsScale = 3

-- ====================================================================
-- net 消息注册（SERVER 段，文件顶层一次性注册；各拆分文件中的 net.Receive 使用）
-- ====================================================================
if SERVER then
    util.AddNetworkString("KardsTableEnter")   -- 客户端→服务端：请求进入（WriteEntity 牌桌）
    util.AddNetworkString("KardsTableExit")    -- 客户端→服务端：请求退出（WriteEntity 牌桌）
    util.AddNetworkString("KardsTableReady")   -- 客户端→服务端：请求准备（WriteEntity 牌桌）
    util.AddNetworkString("KardsTableEntered") -- 服务端→客户端：进入成功（WriteEntity 牌桌, WriteUInt slot, WriteUInt 玩家数）
    util.AddNetworkString("KardsTablePlayerCount") -- 服务端→客户端：牌桌玩家数变化（WriteEntity 牌桌, WriteUInt 玩家数；匹配音效循环播放控制）
    util.AddNetworkString("KardsTableExited")  -- 服务端→客户端：退出成功（WriteEntity 牌桌, WriteUInt slot）
    util.AddNetworkString("KardsTableReadyAck")-- 服务端→客户端：准备回执（WriteEntity 牌桌, WriteUInt slot, WriteBool ready）
    util.AddNetworkString("KardsTableBattleStart") -- 服务端→客户端：对战正式开始（WriteEntity 牌桌；客户端隐藏 HUD + 摄像头过渡）
    util.AddNetworkString("KardsTableMsg")     -- 服务端→客户端：提示消息（WriteString 文字，如槽位被占用）
    util.AddNetworkString("KardsTableToggleMode")  -- 客户端→服务端：请求切换组卡/对战模式（WriteEntity 牌桌，宽面判定）
    util.AddNetworkString("KardsTableModeChanged") -- 服务端→客户端：模式已切换（WriteEntity 牌桌, WriteString 模式）
    util.AddNetworkString("KardsDeckCardClick")   -- 客户端→服务端：点击组卡卡牌（WriteEntity 实体）
    util.AddNetworkString("KardsPileCardRemoved") -- 服务端→客户端：堆叠卡被移出销毁（通知移除 3D2D 文字）
    util.AddNetworkString("KardsDeckSave")        -- 客户端→服务端：保存卡组（WriteString 卡组名）
    util.AddNetworkString("KardsTableDeckDraw")   -- 服务端→客户端：抽牌动画通知（WriteEntity 被抽卡实体, WriteString 卡名）
    util.AddNetworkString("KardsHQRevealStart")   -- 客户端→服务端：总部揭晓动画开始（WriteEntity 牌桌, WriteUInt 槽位；服务端据此把卡堆剩余卡数改为「不含总部」）
    util.AddNetworkString("KardsHQRevealDone")    -- 客户端→服务端：总部动画完成（WriteEntity 牌桌, WriteUInt 槽位；服务端把总部实体模型切换为 basic_card_unit）
    util.AddNetworkString("KardsMulliganReady")   -- 客户端→服务端：重新调度就绪（WriteEntity 牌桌；服务端 OnMulliganReady 发起手牌）
    util.AddNetworkString("KardsMulliganSubmit")  -- 客户端→服务端：重新调度确认（WriteEntity 牌桌, WriteUInt 数量, WriteEntity 被弃卡…）
    util.AddNetworkString("KardsMulliganDone")    -- 服务端→客户端：重新调度完成（WriteEntity 牌桌, WriteUInt 槽位, WriteUInt 数量, WriteEntity 被弃卡…；客户端播放弃牌回卡组 + 补抽原位动画）
    util.AddNetworkString("KardsTurnUpdate")      -- 服务端→客户端：当前回合方更新（WriteEntity 牌桌, WriteUInt 当前回合槽位；客户端 HUD「结束回合」按钮按此显示友方/敌方）
    util.AddNetworkString("KardsEndTurn")         -- 客户端→服务端：请求结束回合（WriteEntity 牌桌；仅当前回合方可发起）
    util.AddNetworkString("KardsPlayCard")         -- 客户端→服务端：打出卡牌（WriteEntity 牌桌, WriteEntity 手牌实体, WriteUInt 目标槽位；0 = 指令）
    util.AddNetworkString("KardsCardPlayed")       -- 服务端→客户端：打出成功（WriteEntity 牌桌, WriteUInt 槽位, WriteEntity 手牌实体, WriteUInt landed 槽位；0 = 指令）
    util.AddNetworkString("KardsFieldLayout")      -- 服务端→客户端：支援阵线布局广播（WriteEntity 牌桌, WriteUInt 槽位, WriteUInt 数量, (WriteUInt 槽位, WriteEntity)*n）
    util.AddNetworkString("KardsPlayCardRejected") -- 服务端→客户端：打出被拒（WriteEntity 牌桌, WriteUInt 槽位, WriteEntity 手牌实体；客户端渐变退回手牌）
    util.AddNetworkString("KardsCommandPoints") -- 服务端→客户端：指挥点广播（WriteEntity 牌桌, WriteUInt P1 点数, WriteUInt P2 点数；手牌花费 3D2D 文字颜色黄/灰判定，见 cl_init.lua KardsHandCostColorThink）
    util.AddNetworkString("KardsUnitEngage")     -- 客户端→服务端：单位交战（WriteEntity 牌桌, WriteEntity 攻击方实体, WriteEntity 防御方实体；判定/结算全在战斗系统）
    util.AddNetworkString("KardsUnitAttackHQ")   -- 客户端→服务端：单位攻击总部（WriteEntity 牌桌, WriteEntity 攻击方实体；判定/结算全在战斗系统）
    util.AddNetworkString("KardsUnitMoveFront")  -- 客户端→服务端：单位移动至前线（WriteEntity 牌桌, WriteEntity 单位实体；判定/结算全在战斗系统）
end

-- 实体注册必须先于拆分文件：拆分文件各头部
-- local ENT = scripted_ents.GetStored("sent_kards_battle_table").t 依赖已注册实体表。
-- scripted_ents.Register 保存的是 ENT 表引用，其后挂载的骨架方法（Initialize/Think
-- 等，见文件后部）随同一引用一并生效。
scripted_ents.Register(ENT, "sent_kards_battle_table")

-- 职责拆分文件（各文件头 local ENT = scripted_ents.GetStored("sent_kards_battle_table").t）
include("table_session.lua")
include("table_deckmode.lua")
include("table_battledeck.lua")
include("table_cleanup.lua")

-- 实体初始化：先跑前置初始化（占位模型 + VPHYSICS），再应用导入模型（重建箱体碰撞盒）
function ENT:Initialize()
    self.BaseClass.Initialize(self)
    local ok, err = self:ApplyImportedModel(self.KardsModelID, self.KardsScale)
    if not ok then
        ErrorNoHalt("[Kards] 牌桌实体生成失败: " .. tostring(err) .. "\n")
        self:Remove()
        return
    end
    -- 模型导入后已 z-up 平躺（桌面朝上），保持 Q 菜单生成的初始朝向
    -- 启动保持直立：创建 KeepUpright 约束（物理枪「保持直立」属性同款实现，
    -- 见 constraint.lua Keepupright 与 garrysmod/lua/autorun/properties/keep_upright.lua），
    -- 以生成时角度为「直立」参考角——物体的 z 朝向（pitch/roll）将永远不因外力改变，
    -- 仅保留绕 z 轴的 yaw 旋转。angularlimit=999999 表示约束强度极高（接近不可偏移）。
    self._kardsKeepUpright = constraint.Keepupright(self, self:GetAngles(), 0, 999999)

    -- 安装唯一全局变量库：tableID 用实体 EntIndex 生成的字符串（实体删除后 ID 仍有效，
    -- 便于销毁时兜底清理）；KARDS.VarLib 按 tableID 实例隔离，多牌桌相同变量库并列、互不混淆
    self.TableID = "table_" .. self:EntIndex()
    KARDS.VarLib.Create(self.TableID)

    -- 两个玩家槽位（玩家进入后写入玩家实体；槽位区域判定见 shared.lua GetPlayerSlot）
    self.Slots = { [1] = nil, [2] = nil }

    -- 玩家会话状态机（re.md T-M2）：集中管理进入冻结/退出恢复（移动/无敌/武器/视角/煤油灯/卡组槽）
    self._kardsSession = KARDS.TableSession.New(self)

    -- 对局进行中标记（进入对局后置 true，牌桌销毁时据此停止对局并解冻玩家）
    self.Playing = false

    -- 子物体系统管理器（sh_child_system.lua）：相对坐标 = 牌桌局部坐标（统一相对 z 轴 =
    -- 桌顶法线），新建/删除（1 秒淡出）/材质接口均经此系统；桌面空卡占位已停用
    -- （定位坐标固化为 sh_animation.lua 拟 2D 布局坐标系常量），管理器保留备用
    self._kardsChildSystem = KARDS.ChildSystem.New(self)

    -- 牌桌模式：battle（对战，默认）/ deck（组卡，宽面 kards_enter 切换，见 ToggleMode）
    -- 经 NW 变量 Kards_Mode 同步客户端（组卡浏览面板 / 宽面提示读取）
    self.Mode = "battle"
    self:SetNWString("Kards_Mode", self.Mode)
    -- 组卡模式的卡牌渲染独立 tableID（与对战/demo 的 CardEnts/ActiveAnims 分表隔离）
    self._kardsDeckTableID = "deck_" .. self.TableID
end

-- 首次 Think 做几何居中：Q 菜单生成时实体位置在准星处，
-- wooden_table 几何中心接近原点（偏移约 ±0.05×scale，可忽略），
-- 保留此修正以兼容未来中心偏移的模型；桌面空卡牌占位已停用
-- （定位坐标已固化为 sh_animation.lua 拟 2D 布局坐标系常量，不再创建占位实体）。
function ENT:Think()
    if not self._kardsFixed then
        self._kardsFixed = true
        self:SetPos(self:GetPos() - self:GetKardsCenter())
    end
    -- 驱动子物体系统：删除淡出（透明度 1 秒渐变至 0 后销毁）
    if self._kardsChildSystem then
        self._kardsChildSystem:Think()
    end
    return self.BaseClass.Think(self)
end

--[[
    读取模型 manifest 的 bounds 中心（绕 x +90° 轴修正后 × scale）

    与 sh_battle_render.lua 的 GetModelCenter(modelID, scale, fixAxis=true) 逻辑一致：
    旋转公式 x'=x, y'=-z, z'=y。读取失败返回零向量。
]]
function ENT:GetKardsCenter()
    local scale = self.KardsScale or 1
    local json = file.Read("pmx_static_importer/models/" .. self.KardsModelID .. "/manifest.json", "DATA")
    if not json then return Vector(0, 0, 0) end
    local manifest = util.JSONToTable(json)
    if not manifest or not manifest.bounds then return Vector(0, 0, 0) end
    local b = manifest.bounds
    return Vector(
        (b.mins[1] + b.maxs[1]) / 2,
        -(b.mins[3] + b.maxs[3]) / 2,
        (b.mins[2] + b.maxs[2]) / 2
    ) * scale
end
