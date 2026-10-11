--[[
    Kards 战斗牌桌 - 客户端共享状态模块（2026-08-11 拆分 A1）

    从 cl_init.lua（lua/entities/sent_kards_battle_table/cl_init.lua，4205 行）迁移的
    「跨段落共享」状态。原为 cl_init.lua main chunk 顶层 local（占 GLua 200 局部变量
    槽，两度触发超限），现集中挂 KARDS.BattleState 命名空间，供 cl_init.lua 与各
    拆分文件（cl_battle_hud.lua / cl_battle_drag.lua / cl_battle_mulligan.lua 等）
    统一读写，不再占用 main chunk 局部槽。

    迁移原则（见《cl_init.lua 拆分规划.md》§3）：
      - 跨段落共享、拆分文件需要访问的状态 → 迁移到本模块
      - 段落自含状态（mulligan 主表、reveal/pendingReveal、slotHint/wideHint、
        flashMsg/prevF4、handHoverCards 等）→ 随段落提取时一并迁走，不进本模块

    注意：cl_init.lua 在 include("shared.lua") 之后 include 本文件（相对实体目录），
    本文件加载早于全部状态使用方。
]]

KARDS = KARDS or {}
KARDS.BattleState = KARDS.BattleState or {}

-- 进入牌桌状态（进入/退出/对战开始核心段与几乎所有段落共享）
KARDS.BattleState.inTable = nil          -- { ent = 牌桌实体, slot = 槽位编号 }（进入后非 nil）
KARDS.BattleState.battleStarted = false  -- 对战已开始（KardsTableBattleStart 置位）
-- 对局结算进行中（2026-08-13，cl_battle_gameover.lua 置位/复位）：期间禁止拖牌、
-- 单位操作与结束回合（各交互钩子门控读取；KardsTableBattleStart / KardsTableExited 复位）
KARDS.BattleState.gameOver = false

-- 先手揭晓动画进行中状态（服务端 KardsTableBattleStart 附带先手槽位与敌方信息；
-- 含头像面板，结构见 cl_init.lua StartReveal；B1 起迁移，先手揭晓段/结束回合
-- 可见性/悬停预览共用）
KARDS.BattleState.reveal = nil

-- 双方指挥点（服务端 KardsCommandPoints 广播；手牌花费 3D2D 文字颜色黄/灰判定 + HUD 面板 + 打出判定）
KARDS.BattleState.commandPoints = { [1] = 0, [2] = 0 }

-- 真实手牌注册表：slot → { [ent] = 手牌序号 }（动画结束后由 KardsRealHandFacing 落位；
-- 手牌悬停提升 / 拿起拖拽 / 重新调度落位 / 花费颜色共用）
KARDS.BattleState.realHandCards = { [1] = {}, [2] = {} }

-- 手牌拿起 / 拖拽 / 打出状态（KardsDragCardThink / KardsRealHandFacing / 悬停预览共用）
KARDS.BattleState.dragCard = nil          -- 拖拽中的卡：{ ent, slot, idx }
KARDS.BattleState.prevDragLeft = false    -- 鼠标左键上一帧状态（上升沿拿起 / 下降沿松手）
KARDS.BattleState.remoteDrags = {}        -- 远程拖拽（对方/观战视角展示玩家握住的牌）：[card] = { pos, ang }（KardsDragSync 写入 / KardsRemoteDragThink 应用）
KARDS.BattleState.dragSync = {}           -- 拖拽位置同步节流状态（发送端）：[ent] = { pos, t }（KardsDragCardThink 节流用）
KARDS.BattleState.fieldLayouts = { [1] = {}, [2] = {} } -- 支援阵线布局：fieldLayouts[slot][ent] = 槽位 index
KARDS.BattleState.pendingPlayEnt = nil    -- 等待服务端确认的打出实体（确认前冻结位置，防重复打出）
KARDS.BattleState.endedTurn = false       -- 已结束本方回合（点击按钮置位；对方回合开始广播回本方时复位）

-- 指向机制（2026-08-12，阶段 B）：拖拽卡效果节点信息缓存与指向状态
KARDS.BattleState.effectCache = setmetatable({}, { __mode = "k" }) -- [cardEnt] = GetCardEffectNodeInfo 结果（weak keys 随实体清理）

-- 手牌卡面定向表（2026-08-18，规划 B1）：[手牌实体] = { name, fileName, ctype }
-- 服务端 KardsTableDrawFace 只发给本方玩家，记录手牌实体的卡牌标识供卡面渲染
-- （InitDrawCardFace）/拖拽判定（Kards_CardType）/指向机制（卡文件）读取。
-- 手牌实体 NW 不再写入卡名/卡文件/类型（NW 自动同步所有客户端 = 对手可读手牌），
-- 对方/观战者收不到定向消息 → 本地表为空，无法读对手手牌。
KARDS.BattleState.cardFaces = setmetatable({}, { __mode = "k" }) -- weak keys 随实体清理

--[[
    统一读取卡牌标识（2026-08-18，规划 B1）：卡名 / 卡文件 / 卡类型

    优先取本地定向表（KardsTableDrawFace 只发本方的手牌卡面信息），回退实体 NW
    （组卡网格 / 战场单位 / 卡组槽等公开实体仍由 NW 提供，不受影响）。

    @param ent Entity
    @return string name, string fileName, string ctype（可能为空字符串）
]]
function KARDS.GetCardIdentity(ent)
    if IsValid(ent) then
        local localFace = KARDS.BattleState.cardFaces[ent]
        if localFace then
            return localFace.name or "", localFace.fileName or "", localFace.ctype or ""
        end
        return ent:GetNWString("Kards_CardName", ""),
               ent:GetNWString("Kards_CardFileName", ""),
               ent:GetNWString("Kards_CardType", "")
    end
    return "", "", ""
end

-- 指令卡打出动画队列（2026-08-12，阶段 C）：当前动画未结束的指令卡实体数组
-- （新打出指令入队尾；最早指令直接出场 / 前一指令停留达 CommandHoldGate 后 z 下移
-- / 出场上移除；2026-08-13 起后一指令在前一指令停留达 1s 时即放行开始）
KARDS.BattleState.commandAnimQueue = {}

-- 单位操作（cl_battle_ops.lua）：按下在场单位 → 松开按目标操作
KARDS.BattleState.unitOpSel = nil         -- 当前按下的本方单位实体（按下置位，松开/取消清除）
KARDS.BattleState.unitOpTarget = nil      -- 指向目标状态（选中期间每帧计算，箭头样式反馈同指向性指令）：
                                          --   { kind = "engage"|"hq"|"move", ent = 目标实体|nil } 或 nil（非法）
KARDS.BattleState.frontlineLayout = {}    -- 前线布局：frontlineLayout[ent] = 前线槽位 index（KardsFieldLayout slot=0 写入）
KARDS.BattleState.frontlineOwnerSlot = 0  -- 前线归属槽（1/2；0 = 无主）——本方单位可移动的条件

-- 结束回合按钮（HUD，battleTurn 由服务端 KardsTurnUpdate 写入）
KARDS.BattleState.battleTurn = nil        -- 当前回合槽位（battleTurn == inTable.slot 时为本方回合）
KARDS.BattleState.endTurnRect = nil       -- 按钮矩形（Think 写入，HUDPaint 绘制）
KARDS.BattleState.endTurnHover = 0        -- 悬停渐变进度（0..1）

-- 重新调度（与发牌 / 落位共享；B1-0d 起主表也迁入本模块，B3 提取重新调度段时随段迁走）
KARDS.BattleState.mulligan = nil          -- 重新调度主表：{ active, slot, total, cards = { [ent] = { ent, index, selected } }, submitted }
KARDS.BattleState.mulliganReadySent = false -- 本方重新调度就绪已发送（每场对局一次）
KARDS.BattleState.mulliganDoneSlot = {}     -- 已完成重新调度的槽位（后续抽牌不走牌桌中间发牌路径）
KARDS.BattleState.mulliganAnimSentSlot = {} -- 各槽重新调度动画结束通知已发送（2026-08-13；kards_switch 切换操作身份后按槽位独立发送，见 cl_init.lua KardsMulliganAnimDoneNotify）

-- 各槽起手发牌张数（2026-08-12，kards_switch 代选用）：某槽首次收到发牌广播（非补抽
-- 且该槽尚未完成重新调度）时记录 total（先手 4 / 后手 5）。切换到虚拟对手槽时代选只把
-- 起手牌（idx ≤ 该数）呈现为选择扇形，后续回合抽牌（idx 递增）留在手牌。对局开始/退出复位。
KARDS.BattleState.dealStarterCount = {}
KARDS.BattleState.mulliganStarted = false   -- 观战重新调度进度标记（2026-08-12）：首个重新调度发牌广播置位（KardsSpectateMulliganHUD 显示前提）
KARDS.BattleState.spectate = nil            -- 观战重新调度追踪（2026-08-12）：{ ent = 牌桌实体, mulliganDone = { [slot] = true } }（KardsTableBattleStart 观战分支创建；参战者恒 nil）
KARDS.BattleState.entSpawnPos = setmetatable({}, { __mode = "k" }) -- 发牌卡生成时的局部坐标（弃牌回卡组动画终点）
KARDS.BattleState.tableMouseOn = false      -- 牌桌内鼠标呼出管理（进入时呼出 / 离开时关闭）
KARDS.BattleState.mulliganConfirmRect = nil -- 重新调度「确认」按钮矩形（HUDPaint 写入，点击检测读取）
KARDS.BattleState.prevMulliganLeft = false  -- 重新调度选择交互上一帧左键状态（点击沿检测）

--[[
    判定网络事件所属牌桌是否为本客户端当前关注桌（2026-09-13 规划 S2）：
    参战桌（inTable.ent）或观战追踪桌（spectate.ent）。本模块各状态为全局单例，
    仅关注桌事件允许写入本地状态；跨桌广播只播世界空间实体动画，调用方自行门控。

    @param ent Entity 消息携带的牌桌实体
    @return boolean
]]
function KARDS.BattleState:IsLocalTable(ent)
    if not IsValid(ent) then return false end
    if self.inTable and self.inTable.ent == ent then return true end
    if self.spectate and self.spectate.ent == ent then return true end
    return false
end
