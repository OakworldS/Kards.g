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
    util.AddNetworkString("KardsTableBattleStart") -- 服务端→客户端：对战正式开始（WriteEntity 牌桌, WriteUInt 先手槽位, WriteBool 是否有敌方；有敌方时追加 WriteString 敌方昵称, WriteString 敌方 SteamID64。客户端隐藏 HUD + 摄像头过渡；观战者分支仅 WriteEntity+先手槽位+WriteBool(false)，无敌方信息，见 table_session.lua / cl_init.lua net.Receive）
    util.AddNetworkString("KardsTableMsg")     -- 服务端→客户端：提示消息（WriteString 文字，如槽位被占用）
    util.AddNetworkString("KardsTableToggleMode")  -- 客户端→服务端：请求切换组卡/对战模式（WriteEntity 牌桌，宽面判定）
    util.AddNetworkString("KardsTableModeChanged") -- 服务端→客户端：模式已切换（WriteEntity 牌桌, WriteString 模式）
    util.AddNetworkString("KardsDeckCardClick")   -- 客户端→服务端：点击组卡卡牌（WriteEntity 实体）
    util.AddNetworkString("KardsPileCardRemoved") -- 服务端→客户端：堆叠卡被移出销毁（通知移除 3D2D 文字）
    util.AddNetworkString("KardsDeckSave")        -- 客户端→服务端：保存卡组（WriteString 卡组名）
    util.AddNetworkString("KardsTableDeckDraw")   -- 服务端→客户端：抽牌动画通知（WriteEntity 被抽卡实体, WriteUInt 槽位, WriteUInt 序号, WriteUInt 总数, WriteBool 补抽, WriteBool 爆牌；2026-08-18 规划 B1：不再携带卡名，卡面改由 KardsTableDrawFace 定向只发本方）
    util.AddNetworkString("KardsTableDrawFace")   -- 服务端→本方：手牌卡面定向（WriteEntity 手牌实体, WriteString 卡名, WriteString 卡文件, WriteString 类型；2026-08-18 规划 B1：手牌实体 NW 不再写卡名/卡文件/类型）
    util.AddNetworkString("KardsHQRevealStart")   -- 客户端→服务端：总部揭晓动画开始（WriteEntity 牌桌, WriteUInt 槽位；服务端据此把卡堆剩余卡数改为「不含总部」）
    util.AddNetworkString("KardsHQRevealDone")    -- 客户端→服务端：总部动画第二关键帧（WriteEntity 牌桌, WriteUInt 槽位；服务端把总部实体模型切换为 basic_card_unit）
    util.AddNetworkString("KardsMulliganReady")   -- 客户端→服务端：重新调度就绪（WriteEntity 牌桌；服务端 OnMulliganReady 发起手牌）
    util.AddNetworkString("KardsMulliganSubmit")  -- 客户端→服务端：重新调度确认（WriteEntity 牌桌, WriteUInt 数量, WriteEntity 被弃卡…）
    util.AddNetworkString("KardsMulliganDone")    -- 服务端→客户端：重新调度完成（WriteEntity 牌桌, WriteUInt 槽位, WriteUInt 数量, WriteEntity 被弃卡…；客户端播放弃牌回卡组 + 补抽原位动画）
    util.AddNetworkString("KardsMulliganAnimDone") -- 客户端→服务端：重新调度动画全部结束（WriteEntity 牌桌, WriteUInt 槽位；客户端本方视角所有调度动画（含对方/虚拟对手）播完时发送，服务端据此 StartFirstTurn，见 table_battledeck.lua net.Receive）
    util.AddNetworkString("KardsTurnUpdate")      -- 服务端→客户端：当前回合方更新（WriteEntity 牌桌, WriteUInt 当前回合槽位；客户端 HUD「结束回合」按钮按此显示友方/敌方）
    util.AddNetworkString("KardsEndTurn")         -- 客户端→服务端：请求结束回合（WriteEntity 牌桌；仅当前回合方可发起）
    util.AddNetworkString("KardsPlayCard")         -- 客户端→服务端：打出卡牌（WriteEntity 牌桌, WriteEntity 手牌实体, WriteUInt 目标槽位；0 = 指令）
    util.AddNetworkString("KardsCounterToggle")    -- 客户端→服务端：切换反制激活状态（WriteEntity 牌桌, WriteEntity 手牌实体, WriteBool 期望激活；反制拖出手牌区外松手触发，服务端权威激活/失活，见 table_battledeck.lua net.Receive）
    util.AddNetworkString("KardsCounterActive")    -- 服务端→本方：反制激活状态回执（WriteEntity 牌桌, WriteEntity 手牌实体, WriteBool 激活中；客户端乐观显示后以服务端为准，见 cl_battle_drag.lua net.Receive）
    util.AddNetworkString("KardsCardPlayed")       -- 服务端→客户端：打出成功（WriteEntity 牌桌, WriteUInt 槽位, WriteEntity 手牌实体, WriteUInt landed 槽位；0 = 指令）
    util.AddNetworkString("KardsDeploySwitch")     -- 客户端→服务端：部署动画半程切换完成（WriteEntity 牌桌, WriteEntity 源手牌实体, WriteEntity 小模型实体；服务端销毁源卡实体，见 table_battledeck.lua net.Receive）
    util.AddNetworkString("KardsFieldLayout")      -- 服务端→客户端：支援阵线布局广播（WriteEntity 牌桌, WriteUInt 槽位, WriteUInt 数量, (WriteUInt 槽位, WriteEntity)*n）
    util.AddNetworkString("KardsPlayCardRejected") -- 服务端→客户端：打出被拒（WriteEntity 牌桌, WriteUInt 槽位, WriteEntity 手牌实体；客户端渐变退回手牌）
    util.AddNetworkString("KardsCommandPoints") -- 服务端→客户端：指挥点广播（WriteEntity 牌桌, WriteUInt P1 点数, WriteUInt P2 点数, WriteUInt P1 槽数, WriteUInt P2 槽数；HUD 面板点数/槽数滚动 + 手牌花费 3D2D 文字颜色黄/灰判定，见 cl_battle_command_points.lua / cl_init.lua KardsHandCostColorThink）
    util.AddNetworkString("KardsUnitEngage")     -- 客户端→服务端：单位交战（WriteEntity 牌桌, WriteEntity 攻击方实体, WriteEntity 防御方实体；判定/结算全在战斗系统）
    util.AddNetworkString("KardsUnitAttackHQ")   -- 客户端→服务端：单位攻击总部（WriteEntity 牌桌, WriteEntity 攻击方实体；判定/结算全在战斗系统）
    util.AddNetworkString("KardsUnitMoveFront")  -- 客户端→服务端：单位移动至前线（WriteEntity 牌桌, WriteEntity 单位实体；判定/结算全在战斗系统）
    util.AddNetworkString("KardsDragSync") -- 客户端→服务端→其他客户端：拖拽位置同步（WriteEntity 牌桌, WriteEntity 卡, WriteVector 局部位置, WriteAngle 局部角度；对方/观战展示玩家握住的牌）
    util.AddNetworkString("KardsDragEnd")  -- 客户端→服务端→其他客户端：拖拽结束（WriteEntity 牌桌, WriteEntity 卡, WriteBool 是否回手牌）
    util.AddNetworkString("KardsCommandExit") -- 客户端→服务端：指令出场完成（WriteEntity 牌桌, WriteEntity 指令卡；服务端据此销毁实体，见 table_battledeck.lua net.Receive / OnPlayCard 指令分支）
    util.AddNetworkString("KardsHintRelay")   -- 客户端→服务端：本方提示中继请求（WriteEntity 牌桌, WriteString 提示文字；服务端转给观战者，对手不可见，见 table_battledeck.lua net.Receive）
    util.AddNetworkString("KardsHintObserver") -- 服务端→观战者：提示广播（WriteEntity 牌桌, WriteString 被提示玩家名, WriteString 提示文字；观战端牌桌中心 z+ 上方 3D2D 打字机显示，见 cl_battle_hint.lua）
    util.AddNetworkString("KardsSwitchSlot") -- 服务端→客户端：无对手模式操作身份切换（WriteEntity 牌桌, WriteUInt 新槽位；kards_switch 指令，客户端更新视角/相机/手牌卡面，见 cl_init.lua net.Receive）
    util.AddNetworkString("KardsReturnToHand") -- 服务端→客户端：返回手牌动画通知（WriteEntity 牌桌, WriteUInt 槽位, WriteEntity 源战场实体（小模型）, WriteEntity 新卡实体（正常模型动画载体）, WriteUInt 手牌序号, WriteUInt 手牌总数；见 table_battledeck.lua BroadcastReturnToHand / cl_init.lua net.Receive）
    util.AddNetworkString("KardsReturnToHandDone") -- 客户端→服务端：返回手牌动画完成（WriteEntity 牌桌, WriteEntity 新卡实体；服务端据此移除源战场实体并清理映射，见 table_battledeck.lua net.Receive）
    util.AddNetworkString("KardsUnitRetreat") -- 客户端→服务端：单位撤退（WriteEntity 牌桌, WriteEntity 单位战场实体；服务端 SimRetreat + 布局广播驱动撤退动画，见 table_battledeck.lua OnUnitRetreat / cl_battle_ops.lua）
    util.AddNetworkString("KardsBattleBGM") -- 服务端→客户端：战斗 BGM 启动（WriteEntity 牌桌, WriteUInt 槽位；仅在场玩家收到，观战者不发——客户端本地随机选风格/曲目循环播放，见 cl_battle_bgm.lua）
    util.AddNetworkString("KardsGameOver") -- 服务端→客户端：对局结束结算（WriteEntity 牌桌, WriteUInt 胜利槽位, WriteUInt 失败槽位；客户端播放 1 秒结算动画 + 胜负字样 + 继续按钮，见 table_battledeck.lua OnGameOver / cl_battle_gameover.lua net.Receive）
    util.AddNetworkString("KardsReveal") -- 服务端→客户端：隐蔽单位揭示事件（WriteEntity 牌桌, WriteUInt 数量, WriteEntity 单位实体…；客户端播放翻面动画（先渲染正面→翻面 z 抬升）+ 揭示音效，完成后攻击结算广播继续，见 table_battledeck.lua BroadcastReveal / cl_battle_stealth.lua net.Receive）
    util.AddNetworkString("KardsStatChangeSound") -- 服务端→客户端：属性变化音效（WriteEntity 牌桌；数据层来源命中——属性与伤害节点攻击/防御分支 + 山地/动员词条——客户端播放 stat_change.ogg，见 table_battledeck.lua BroadcastStatChangeSound / cl_init.lua net.Receive）
    util.AddNetworkString("KardsStatChangeFX") -- 服务端→客户端：属性变化 3D2D 飘字（WriteEntity 目标实体, WriteUInt 槽位 1攻击/2防御/3行动花费, WriteInt 变动值, WriteUInt mod 1增/2减/3设, WriteUInt kind 1伤害/2节点/3其他, WriteInt 改动后的当前值（白字显示用）；见 table_battledeck.lua BroadcastStatChangeFX / cl_card_text_overlay.lua net.Receive）
    util.AddNetworkString("KardsFieldDeath") -- 服务端→客户端：场上目标死亡延迟移除广播（WriteEntity 牌桌, WriteEntity 死亡单位实体；客户端登记待移除实体，计算「最晚飘字结束 +0.5s」后发 KardsFieldDeathRemove 通知，见 table_battledeck.lua ScheduleFieldDeathRemove / cl_init.lua net.Receive）
    util.AddNetworkString("KardsEventSound") -- 服务端→客户端：事件音效（WriteEntity 牌桌, WriteEntity 事件源实体, WriteString 相对路径；参战者 2D 全屏、观战者 3D 方位——音源位置取事件源实体 WorldCenter，data/ 自定义音效回退 2D，见 table_battledeck.lua BroadcastEventSound / cl_init.lua net.Receive）
    util.AddNetworkString("KardsHandHover") -- 客户端→服务端→其他客户端：手牌悬停广播（客户端→服务端：WriteEntity 牌桌, WriteEntity 被悬停手牌实体，无悬停 WriteEntity(NULL)；服务端中继给「其他所有客户端」：WriteEntity 牌桌, WriteUInt 槽位, WriteEntity 被悬停手牌实体。对方+观战者据此把该卡 z 抬升为手牌中最高，见 table_battledeck.lua net.Receive / cl_init.lua net.Receive 与 KardsRealHandFacing）
    util.AddNetworkString("KardsControlAnim") -- 服务端→客户端：控制/解除控制动画通知（WriteEntity 牌桌, WriteEntity 被控单位实体, WriteBool 是否解除, WriteUInt 落位阵线 1前线/0支援, WriteUInt 落位槽位, WriteUInt 旋转起点槽位, WriteUInt 旋转终点槽位；客户端播放 0.7s 移向牌桌中心 + z 上升 + 控制图标动画 + 落位，见 table_battledeck.lua BroadcastControlAnim / cl_init.lua net.Receive）
    util.AddNetworkString("KardsShuffleInto") -- 服务端→客户端：洗入动画通知（WriteEntity 牌桌, WriteUInt 槽位, WriteUInt 张数, WriteVector 卡组终点（牌桌局部坐标；多张同刻洗入为卡堆顶卡与底卡 z 的中点，单张为卡堆顶面）, (WriteEntity 动画载体, WriteUInt 载体来源 1手牌/2场上/3凭空生成)*n（客户端按序位错峰，展示位取右槽）；卡面经 KardsTableDrawFace 定向只发该方，见 table_battledeck.lua BroadcastShuffleInto / cl_battle_shuffle.lua net.Receive）
    util.AddNetworkString("KardsPileCardFlyOut") -- 服务端→客户端：节点弃牌/爆牌单卡飞出（WriteEntity 牌桌, WriteUInt 槽位, WriteUInt 数量, (WriteEntity 载体)*n；客户端从卡堆顶飞向该方视角右侧卡槽，无提示，见 table_battledeck.lua BroadcastPileCardFlyOut / cl_battle_mulligan.lua net.Receive）
    util.AddNetworkString("KardsJoinAnim") -- 服务端→客户端：加入阵线动画通知（WriteEntity 牌桌, WriteUInt 归属槽位, WriteBool 是否有手牌来源, WriteEntity 手牌来源实体（无则 NULL）, WriteString 手牌来源实体的模型副本标识（Kards_DeckModelID，实体引用无效时客户端按它找回，2026-09-27 F1）, WriteEntity 战场实体, WriteUInt 阵线 1支援/2前线, WriteString 部署音效路径（仅手牌来源非空）；客户端手牌侧下落 + 屏右入场并发，见 table_battledeck.lua BroadcastJoinAnim / cl_battle_join.lua net.Receive）
    util.AddNetworkString("KardsUnitAction") -- 服务端→客户端：单位攻击冲刺动画通知（WriteEntity 牌桌, WriteEntity 攻击方实体, WriteEntity 目标实体, WriteString 单位类型；客户端按类型播坦克炮兵回弹 / 步兵高频往复，见 table_battledeck.lua BroadcastUnitAction / cl_battle_unit_action.lua net.Receive）
    util.AddNetworkString("KardsUnitElevate") -- 服务端→客户端：老兵升级动画通知（WriteEntity 牌桌, WriteEntity 单位实体, WriteBool 行动花费是否变化, WriteInt 行动花费变动值, WriteInt 行动花费新值, WriteInt 攻击力变动值, WriteInt 攻击力新值, WriteInt 防御力变动值, WriteInt 防御力新值；客户端播 z 上升 + 依次白色飘字 + 回落，见 table_battledeck.lua BroadcastUnitElevate / cl_battle_veteran.lua net.Receive）
    util.AddNetworkString("KardsUnitConvert") -- 服务端→客户端：卡牌整体转换交接动画通知（WriteEntity 牌桌, WriteEntity 旧实体, WriteEntity 新实体；客户端播 z 上升 + 翻面至 90° 换显 + 反向回落，见 table_battledeck.lua BroadcastUnitConvert / cl_battle_convert.lua net.Receive）
    util.AddNetworkString("KardsDeckSearchInput") -- 客户端→服务端：组卡搜索输入（WriteString 文本；仅 P2 构建者发送，服务端校验后广播，见 table_deckmode.lua net.Receive）
    util.AddNetworkString("KardsDeckSearchInputBC") -- 服务端→客户端：组卡搜索输入广播（WriteEntity 牌桌, WriteString 文本；所有客户端更新 3D2D 输入框文字，见 cl_init.lua net.Receive）
    util.AddNetworkString("KardsDeckSaved") -- 服务端→客户端：卡组保存成功（WriteEntity 牌桌；本桌客户端播「收拢为总部竖列 → 回落摊开」两段卡组动画，见 cl_deck_pile.lua）
    -- 测试版不同步恢复（2026-09-13；正式版改为 NetSync 签名重同步，见《战斗系统规划.md》）
    util.AddNetworkString("KardsDesyncNotify") -- 服务端→本方：检测到结构性状态分歧（WriteEntity 牌桌；客户端弹模糊弹窗，见 cl_battle_desync.lua）
    util.AddNetworkString("KardsDesyncReenter") -- 客户端→服务端：请求软重进快照（WriteEntity 牌桌；不释放槽位、不中断对局）
    util.AddNetworkString("KardsDesyncSnapshot") -- 服务端→本方：当前战斗全量快照（牌桌/槽位/回合槽/手牌实体+卡面/两支援阵线/前线/指挥点，客户端本地清空重建，见 cl_battle_desync.lua net.Receive）
    -- 伪用户控制台（2026-09-13：管理接管虚拟对手替对方出牌，彩色文本经此串下发 MsgC，
    -- 见 sv_fakeuser.lua / cl_fakeuser_console.lua）
    util.AddNetworkString("KardsFakeUserPrint")
    -- 三选一（开发/观星，2026-09-26）：候选卡广播 + 选择回传 + 结果回执
    util.AddNetworkString("KardsPickOffer")  -- 服务端→本桌：三选一开始（WriteEntity 牌桌, WriteUInt 发起槽位, WriteString kind, WriteUInt 张数, (WriteEntity 候选实体)*n；卡面只定向发发起方（KardsTableDrawFace），其余客户端保持卡背，见 table_pick.lua / cl_battle_pick.lua）
    util.AddNetworkString("KardsPickChoose") -- 客户端→服务端：提交选择（WriteEntity 牌桌, WriteUInt 候选序号 1..n）
    util.AddNetworkString("KardsPickResult") -- 服务端→本桌：选择结果（WriteEntity 牌桌, WriteUInt 选中候选序号, WriteUInt 手牌序号 0=未入手牌, WriteUInt 手牌总张数；客户端据此播放第二段动画，见 table_pick.lua / cl_battle_pick.lua）
    -- 抉择（2026-10-04 新增，见 table_choice.lua / cl_battle_choice.lua）：
    util.AddNetworkString("KardsChoiceOffer")  -- 服务端→打出方+观战者（不含敌方）：抉择演出开始（WriteEntity 牌桌, WriteUInt 发起槽位, WriteEntity 抉择卡实体, WriteString T1, WriteString T2）
    util.AddNetworkString("KardsChoiceHide")   -- 服务端→敌方：演出期间隐藏该卡（WriteEntity 牌桌, WriteEntity 抉择卡实体；结算后由 KardsChoiceResult 解除）
    util.AddNetworkString("KardsChoiceResult") -- 服务端→打出方+观战者+敌方：抉择结算（WriteEntity 牌桌, WriteUInt 发起槽位, WriteUInt 选中序号 1/2, WriteString 所选 T）
    util.AddNetworkString("KardsChoiceChoose") -- 客户端→服务端：提交选择（WriteEntity 牌桌, WriteUInt 选中序号 1/2）
    -- 弃牌选择（2026-10-06 新增，见 table_discard.lua / cl_battle_discard.lua）：
    util.AddNetworkString("KardsDiscardOffer")  -- 服务端→本桌：弃牌选择开始（WriteEntity 牌桌, WriteUInt 发起槽位, WriteUInt 手牌张数, (WriteEntity 手牌实体)*n；仅该槽视角显示交互 UI，其余视角不显示）
    util.AddNetworkString("KardsDiscardChoose") -- 客户端→服务端：提交弃牌选择（WriteEntity 牌桌, WriteUInt 手牌序号 1..n）
    util.AddNetworkString("KardsDiscardResult") -- 服务端→本桌：弃牌选择结束（WriteEntity 牌桌, WriteUInt 发起槽位, WriteUInt 选中序号 0=放弃；客户端据此关闭选择 UI）
    util.AddNetworkString("KardsHandCardFlyOut") -- 服务端→客户端：手牌弃牌飞出（WriteEntity 牌桌, WriteUInt 槽位, WriteEntity 手牌实体；客户端把牌移到该方视角右槽、停留 1 秒后顺时针出场，见 table_battledeck.lua BroadcastHandCardFlyOut / cl_battle_mulligan.lua net.Receive）
end

-- 实体注册必须先于拆分文件：拆分文件各头部
-- local ENT = scripted_ents.GetStored("sent_kards_battle_table").t 依赖已注册实体表。
-- scripted_ents.Register 保存的是 ENT 表引用，其后挂载的骨架方法（Initialize/Think
-- 等，见文件后部）随同一引用一并生效。
scripted_ents.Register(ENT, "sent_kards_battle_table")

KARDS = KARDS or {}

-- operator 级权限白名单（2026-10-03）：逗号或分号分隔的 SteamID 与 SteamID64 混合，
-- 供没有任何管理权限的测试人员使用（GMod 原版玩家组只有 user / admin / superadmin，
-- operator 等级需第三方管理插件或服务器自定义组提供）
local cvOperatorIDs = CreateConVar("kards_operator_steamids", "", FCVAR_ARCHIVE,
    "operator 级权限白名单：逗号或分号分隔的 SteamID / SteamID64")

--[[
    operator 级权限判定（kards_forcestart、kards_switch 与 kards_fakeuser_* 共用，2026-10-03）

    判定顺序，任一命中即通过：
      1. 第三方管理插件提供的 `Player:IsOperator`（自定义组语义，覆盖 operator 及以上）。
         该方法不存在时不能以方法语法直调，否则报 attempt to call method 'IsOperator'。
      2. 白名单 convar `kards_operator_steamids` 内的 SteamID / SteamID64（测试人员）。
      3. 用户组字符串 `operator` / `admin` / `superadmin`（原版只有后两组，
         operator 组需服务器在 users.txt 或管理插件里自建）。

    @param ply Player 执行玩家
    @return boolean 是否具备 operator 级权限
]]
function KARDS.IsOperator(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return false end
    -- 三级逐个尝试，任一命中即通过（插件判定为否时不提前返回，否则装了插件时白名单失效）
    local fn = ply.IsOperator
    if fn and fn(ply) then return true end
    local sid, sid64 = ply:SteamID(), ply:SteamID64()
    for id in string.gmatch(cvOperatorIDs:GetString(), "[^,;%s]+") do
        if id == sid or id == sid64 then return true end
    end
    local group = ply:GetUserGroup()
    return group == "operator" or group == "admin" or group == "superadmin"
end

-- 职责拆分文件（各文件头 local ENT = scripted_ents.GetStored("sent_kards_battle_table").t）
include("table_session.lua")
include("table_deckmode.lua")
include("table_battledeck.lua")
include("table_pick.lua") -- 三选一会话（开发/观星候选卡挂起与回传；依赖 table_battledeck 的实体工具，见文件头）
include("table_choice.lua") -- 抉择会话（二选一演出 + 选择挂起与回传；依赖 table_battledeck 的卡实体映射，见文件头）
include("table_discard.lua") -- 弃牌选择会话（手牌弃牌选择挂起与回传；依赖 table_battledeck 的卡实体映射，见文件头）
include("table_cleanup.lua")
include("sv_fakeuser.lua") -- 伪用户控制台命令系统（kards_fakeuser_*；管理测试用，见文件头）

-- 客户端伪用户控制台彩色输出接收（服务端文件经 AddCSLuaFile 下发）
AddCSLuaFile("cl_fakeuser_console.lua")

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

    -- 物理材质设为木质：外观已是木质，但箱体碰撞（PhysicsInitBox）默认物理材质
    -- 不是木头，碰撞/物理枪拖动音效与木质外观不符。按 Valve 表面属性文档
    -- （Material surface properties → Wood），桌子属大型木质家具，对应 Wood_Crate
    -- （Large wood furniture: bookcases, tables）；不用通用 wood（文档注明应使用
    -- wood_box/wood_crate/wood_plank 等具体类型）。
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetMaterial("wood_crate")
    end

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
-- 同处记录并锁定 yaw：以生成完成后的初始朝向为基准（首次 Think 时角度已由生成/
-- 粘贴流程定稿，兼容 spawnmenu 与 duplicator），此后外力（物理枪旋转/碰撞）改变
-- yaw 时立即拉回；pitch/roll 已由 Initialize 的 KeepUpright 约束锁定。
function ENT:Think()
    if not self._kardsFixed then
        self._kardsFixed = true
        self:SetPos(self:GetPos() - self:GetKardsCenter())
        self._kardsLockYaw = self:GetAngles().yaw
    end
    -- yaw 锁定修正：绕 z 轴的朝向偏移即恢复初始朝向，并清零角速度防止继续偏转
    if self._kardsLockYaw then
        local ang = self:GetAngles()
        if math.abs(ang.yaw - self._kardsLockYaw) > 0.01 then
            self:SetAngles(Angle(0, self._kardsLockYaw, 0))
            local phys = self:GetPhysicsObject()
            if IsValid(phys) then
                phys:SetAngleVelocity(Vector(0, 0, 0))
            end
        end
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
