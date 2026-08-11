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
KARDS.BattleState.dragCard = nil          -- 拖拽中的卡：{ ent, slot, idx, zFrom, start }
KARDS.BattleState.prevDragLeft = false    -- 鼠标左键上一帧状态（上升沿拿起 / 下降沿松手）
KARDS.BattleState.fieldLayouts = { [1] = {}, [2] = {} } -- 支援阵线布局：fieldLayouts[slot][ent] = 槽位 index
KARDS.BattleState.pendingPlayEnt = nil    -- 等待服务端确认的打出实体（确认前冻结位置，防重复打出）
KARDS.BattleState.endedTurn = false       -- 已结束本方回合（点击按钮置位；对方回合开始广播回本方时复位）

-- 单位操作（cl_battle_ops.lua）：按下在场单位 → 松开按目标操作
KARDS.BattleState.unitOpSel = nil         -- 当前按下的本方单位实体（按下置位，松开/取消清除）
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
KARDS.BattleState.entSpawnPos = setmetatable({}, { __mode = "k" }) -- 发牌卡生成时的局部坐标（弃牌回卡组动画终点）
KARDS.BattleState.tableMouseOn = false      -- 牌桌内鼠标呼出管理（进入时呼出 / 离开时关闭）
KARDS.BattleState.mulliganConfirmRect = nil -- 重新调度「确认」按钮矩形（HUDPaint 写入，点击检测读取）
KARDS.BattleState.prevMulliganLeft = false  -- 重新调度选择交互上一帧左键状态（点击沿检测）
