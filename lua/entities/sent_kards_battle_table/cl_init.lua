--[[
    ============================================================================
    PMXModel / PMXStaticImporter 机制速查（2026-08-11 归纳，涉及纹理/贴图先读本段；
    本项目实测结论，避免反复在模型导入处花费大量时间排查）

    【整体架构】
    前置模组「Simple Static Model Importer」（PMXStaticImporter，workshop
    3706539692）：exe 把 GLB/GLTF 转自定义网格数据写入
    garrysmod/data/pmx_static_importer/models/<model_id>/，游戏内以实体类
    sent_pmx_static_imported 运行时渲染（非传统 .mdl，跳过编译管线）。该实体类由
    前置模组运行时注入（不在任何磁盘 Lua 里），故本项目所有卡牌/卡堆/总部实体
    都用它。实体 API：
      - 服务端：ents.Create("sent_pmx_static_imported") + ent:ApplyImportedModel(modelID, scale)
      - 客户端：ents.CreateClientside(...)——无 ApplyImportedModel（服务端专用），
        直接写 datatable：SetPMXModelID(modelID) / SetPMXScale(scale) /
        SetPMXColor(Vector(1,1,1))（必须显式置白！SetupDataTables 的 SERVER 分支
        不执行 → PMXColor 缺省 Vector(0,0,0) → 渲染全黑）。
      - 客户端实体 Think（_lastModelID 比对）自动更新渲染包围盒，Draw 按 PMXModelID
        从磁盘 manifest 加载 renderable 渲染（悬停复制卡 HoverPreviewCreate 即此方式）。

    【模型产物与卡牌几何】
    - data/pmx_static_importer/models/<model_id>/manifest.json 关键字段：model_id、
      mesh_file（几何共享 basic_card 的 mesh.json）、submeshes（front/back/side，
      各含 image_path / diffuse / double_sided）、bounds（包围盒）、scale、flip_v。
    - basic_card 实测：bounds = 36(x) × 54(y) × 0.45(z)，scale = 10；世界尺寸 =
      bounds × 世界缩放（KARDS.BattleRender.Defaults.CardScale = 0.2）→
      7.2(宽) × 10.8(长) × 0.09(厚)。卡面轴系：卡宽 = Forward(+X) = 7.2、
      卡长 = Right(+Y) = 10.8、法线 = Up(+Z)。
      （注意：sh_battle_render.lua 顶部注释「basic_card 约 120x1.5x180 单位」是旧值，
      与现 manifest 不符，以 bounds 36×54 为准）
    - 卡堆档位模型（basic_card_xxxx/_xxx/_xx/_x/_v）是 exe 导入的整叠模型（底面
      120×180 世界单位、缩放 0.06）；单张档 kards_deckpile_1 是 basic_card 副本
      （缩放 0.2，与普通卡一致）。exe 不支持纯数字命名 → 档位后缀用罗马数字。

    【纹理加载链路（顺序敏感：文件 → manifest → ClearCache → PrefillBackFlip）】
    1. manifest 的 submeshes[].image_path 指向 data/<dir>/front.png / back.png
       （相对 GAME 目录，实际落在 garrysmod/data/ 下；front/back 各指一张）。
    2. PNG 落盘必须先于实体首次 Draw：引擎材质按路径缓存——若 PNG/manifest 在实体
       首次请求材质后才落盘，本会话白屏无纹理直至重启。故所有贴图预置
       （PrepareDeckPileFiles / PrepareHandSlotFiles / DeckPrepareCardFiles /
       ProcessDeckCard / ProcessBattleDeckCard）都在首次 Draw 前完成「文件落盘 +
       manifest 改写」。
    3. 贴图更新后必须 PMXStaticImporter.ClearCache(modelID) 销毁旧 renderable，
       实体 Draw 重建时才按 manifest 新 image_path 加载（否则继续用旧缓存材质）。
    4. ClearCache 之后须调 PrefillBackFlip(modelID)：basic_card 家族模型 back 槽从
       -z 方向采样的 UV 相对图片是水平镜像的（建模时 back 面 UV 未按背向重映射，
       front 槽从 +z 正常），卡背图须在 back 槽水平翻转才能正常显示。前置 Draw
       优先使用 MaterialCache（cl_canvas_editor.lua 预填实测生效），故预填带
       $basetexturetransform "center 0.5 0.5 scale -1 1 rotate 0 translate 0 0" 的
       UnlitGeneric 材质。材质配方不能带颜色/透明流（mesh 顶点流仅 pos3+normal3+uv2，
       带 $vertexcolor 等会读垃圾数据致透明）。

    【manifest 副本机制（KARDS.CardManifest，sh_card_manifest.lua）】
    - 每张卡克隆独立 manifest（独立 model_id + 独立 image_path，几何共享 basic_card
      mesh.json）。原因：批量多卡共用 basic_card 会互相覆盖 image_path，前置渲染
      加载不到贴图显示紫黑棋盘格。
    - Clone(modelID, imageDir, errPrefix)：读 basic_card manifest 模板 → 改写
      model_id + front/back 的 image_path → 写盘（幂等，每次重写）。
    - modelID 前缀约定（safeName = URL 编码，如 e6_ad_a5_e5_85_b5... 表"步兵团"）：
        kards_deck_<safeName>                组卡卡牌（卡面+卡背+3D2D 文字）
        kards_battledeck_<safeName>[_d<N>]   卡组槽/抽牌临时卡（仅卡背 usa；_d 抽牌
                                             临时卡唯一化，manifest 改写不影响后续同卡）
        kards_battledeck_placeholder         无卡组占位卡（usa 卡背）
        kards_handslot                       手牌槽卡（front 缺失→白色兜底 / back=UK 卡背）
        kards_deckpile_1 / kards_deckpile_usa 卡堆单张档（usa 卡背）
        kards_deck_hq_<safeName>             总部卡

    【客户端实体初始化流程（role 驱动）】
    - OnEntityCreated / EntityNetworkedVarChanged（Kards_CardRole / Kards_DeckModelID）
      → EnqueueCardEntity 入 cardPendingEntities（带时间戳，3s 超时未处理则移除）→
      KardsTableCardMaterial Think 按 Kards_CardRole 分派：
        "deck"       → ProcessDeckCard（kards_deck_*：卡面+卡背+3D2D 文字，翻面卡仅落卡背）
        "battledeck" → ProcessBattleDeckCard（kards_battledeck_*：仅卡背，测试版统一 usa）
      无 role 的实体（如客户端本地展示卡）不入初始化。
    - Kards_DeckModelID NW 携带 modelID（服务端 SpawnBattleDeckCard/SpawnBattleCard 等设置）。
    - 卡背统一策略（测试版）：卡组槽 / 卡堆 / 总部 = usa 卡背；手牌槽 = UK 卡背。
    - 客户端本地实体（SetPMXModelID 直写）必须先确保 manifest + PNG 就绪（InitPostEntity
      预置，或自行 CardManifest.Ensure* + WriteCardTextures），否则 Draw 按 image_path
      加载失败白屏。

    【常见坑速查】
    - 客户端实体忘 SetPMXColor(白) → 全黑
    - PNG 落盘晚于首次 Draw → 本会话白屏（须重启；或确保 InitPostEntity 预置）
    - 贴图改后忘 ClearCache → 旧缓存材质
    - 卡背水平镜像 → 忘 PrefillBackFlip（且必须在 ClearCache 之后调用）
    - 共用 basic_card manifest → image_path 互相覆盖 → 紫黑棋盘格
    - 3D2D 文字与 PMX 无关：走 KARDS.CardTextOverlay（cl_card_text_overlay.lua）
    ============================================================================
]]

-- Kards 战斗牌桌实体客户端代码
-- 1) 玩家处于牌桌槽位范围内时，在屏幕底部渲染进入提示文字。
-- 2) 控制台指令 kards_enter 进入/退出牌桌（服务端校验槽位占用；位置判定无需准星瞄准，
--    可 bind <键> "kards_enter" 绑定任意按键）：进入后完全接管 HUD（隐藏 GMod 全部默认
--    HUD 元素，含十字准星/血量/弹药/语音等；第三方模组若走 HUDShouldDraw 亦被隐藏），
--    摄像头由 BattleCamera 接管（宽边外侧上方俯视牌桌）；按 F4 准备。
-- 3) 对战开始（KardsTableBattleStart）后播放摄像头过渡动画，动画结束后在双方 UI 上
--    展示先手揭晓动画：左右两侧 Steam 头像（AvatarImage 控件）+ 玩家名淡入，随机先手方
--    回弹放大并显示黄色“先手”，随后整体淡出（见 KardsFirstTurnReveal* 段）。
-- 4) 初始化卡顿加载提示（KardsInitLoading* 段）：进入牌桌/切换组卡模式时启动 FPS 检测，
--    实体卡牌初始化导致帧率 <10 时在准星下方显示"正在初始化战场/卡组"，帧率恢复后淡出。
-- 槽位区域判定复用 shared.lua 的 GetPlayerSlot（与服务器同一套判定，保证两端一致）。

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

include("shared.lua")

-- 共享状态模块（2026-08-11 拆分 A1）：跨段落共享状态集中于此，见 cl_battle_state.lua；
-- 必须在任何状态使用方之前加载（相对实体目录，与 include("shared.lua") 同路径规则）
include("cl_battle_state.lua")

-- 射线命中统一（2026-11-08）：鼠标射线、最近命中、命中阈值与业务筛选的唯一解释者，
-- 见 docs/adr/0009-射线命中统一.md；调用点不再各自构造射线或写距离公式
include("cl_hit_test.lua")

-- 卡面视图（2026-11-08）：渲染层读取卡牌数据的唯一入口，NW 键名收在其内，
-- 见 docs/adr/0008-卡面视图层.md；必须紧跟 cl_battle_state，其身份读取依赖
-- KARDS.GetCardIdentity 的定向表回退链
include("cl_card_view.lua")

-- 每帧共享的 PMX 实体列表（2026-10-16 性能优化）：cl_battle_material.lua 两处、
-- cl_battle_hud.lua 卡堆悬停、cl_deck_pile.lua 抗视差原本各自每帧调用
-- ents.FindByClass("sent_pmx_static_imported") 做全量扫描，同帧共 4 次。此处按
-- FrameNumber 缓存：同帧首个调用者执行一次扫描，其余复用同一结果（调用方只读遍历）。
-- 必须在各模块 include 之前定义，供其 Think 钩子运行时调用。
local pmxList, pmxListFrame = nil, -1
function KARDS.GetPmxList()
    local f = FrameNumber()
    if pmxListFrame ~= f then
        pmxList = ents.FindByClass("sent_pmx_static_imported")
        pmxListFrame = f
    end
    return pmxList
end

-- 未实现职责占位文件（2026-08-11 拆分 A2）：各职责待开发（多为正式版标准职责），
-- 当前为空文件，仅登记加载顺序；实现时代码写在对应文件内、挂 KARDS 命名空间
--（各文件头注释写明职责与约定，本行注释随功能落地后删改）
include("cl_battle_pick.lua")       -- 三选一交互（开发/观星候选卡展示与选择，2026-09-26 实现）
include("cl_battle_choice.lua")     -- 抉择演出与二选一交互（中槽分裂 + 鼠标选卡，2026-10-04 实现）
include("cl_battle_discard.lua")    -- 弃牌选择交互（手牌上移选择 + 确认按钮，2026-10-06 实现）
include("cl_battle_front.lua")      -- 移到前线交互（待实现）
include("cl_battle_chat.lua")       -- 纯固定文本聊天（待实现）
include("cl_battle_settings.lua")   -- 设置（待实现）
include("cl_battle_surrender.lua")  -- 投降（待实现）
include("cl_battle_history.lua")    -- 历史出牌回顾（待实现）

-- 指挥点 HUD 面板（2026-08-11 拆分 B1：状态/常量/Think 推进/HUDPaint 绘制/net 接收器，
-- 导出 KARDS.CommandPointsReset / KARDS.CommandPointsApplyBroadcast；2026-10-10 起
-- 面板自角落向中线让位，导出角落布局 KARDS.CPAvatarRect / KARDS.CPAvatarSize）
include("cl_battle_command_points.lua")

-- 对局内玩家头像面板（2026-10-10：先手揭晓结束后在角落（指挥点面板让位处）常驻展示
-- 双方玩家头像 + 玩家名，头像淡入 / 名字向右滑动淡入，结算时淡出；
-- 导出 KARDS.PlayerPanelIntro / Outro / Reset，见 cl_battle_player_panel.lua）
include("cl_battle_player_panel.lua")

-- HUD 三件套（2026-08-11 拆分 B1：卡堆悬停信息面板 / 结束回合按钮 / 手牌花费颜色）
include("cl_battle_hud.lua")

-- 提示系统（2026-08-12：屏幕中心 toast，textUnderground.png 底 + 白色文字，
-- 淡入 1.5s / 停留 3s / 淡出 1.5s；多提示向上堆叠移出屏幕，导出 KARDS.BattleHint；
-- 服务端操作失败原因经 KardsTableMsg 接收器转本系统）
include("cl_battle_hint.lua")

-- 单位操作交互（2026-08-11 拆分 C2：按下在场单位 → 松开按悬停目标发送操作请求；
-- 判定/决策全在服务端战斗系统，导出 KARDS.UnitOpsReset）
include("cl_battle_ops.lua")

-- 隐蔽机制（2026-08-13：隐蔽部署背面朝上视觉/揭示翻面动画+音效/指令指向提示，
-- 见 cl_battle_stealth.lua；导出 KARDS.Stealth）
include("cl_battle_stealth.lua")

-- 前线符号实体（2026-08-11：客户端实体渲染前线占领状态，数据源 frontlineOwnerSlot）
include("cl_battle_frontline_symbol.lua")

-- 对局结算（2026-08-13：总部被摧毁 → 震屏/肩后相机/模糊/胜负字样/继续/黑屏退出，
-- 见 cl_battle_gameover.lua；导出 KARDS.GameOverReset）
include("cl_battle_gameover.lua")

-- 测试版不同步恢复（2026-09-13：服务端结构性分歧通知 → 模糊弹窗 + 「重启」软重进
-- 快照本地重建，见 cl_battle_desync.lua；导出 KARDS.DrawActionButton / DesyncReset）
include("cl_battle_desync.lua")

-- 伪用户控制台彩色输出接收（2026-09-13：管理测试用 kards_fakeuser_* 指令输出，
-- 服务端 AddCSLuaFile 下发，本处 include 注册 net.Receive MsgC 打印）
include("cl_fakeuser_console.lua")

-- 战斗 BGM（2026-08-14：对局开始仅在场玩家收到 KardsBattleBGM，本地随机风格/曲目
-- 循环播放；导出 KARDS.PlayBattleBGM / KARDS.StopBattleBGM）
include("cl_battle_bgm.lua")

-- 当前槽位提示状态：{ ent = 牌桌实体, slot = 槽位编号 }（进入后置 nil）
local slotHint = nil

-- 当前宽面提示状态：ent = 牌桌实体（玩家在宽边 x 侧中段，可切换组卡/对战模式；进入后置 nil）
local wideHint = nil

-- 远程手牌悬停（2026-08-14，KardsHandHover 广播接收端登记）：remoteHandHover[slot]
-- = 对方/其他玩家悬停的该槽手牌实体（无悬停 nil）。对方+观战者据此把该卡 z 抬升
-- 为手牌中最高（需求 2/3），KardsRealHandFacing 每帧消费；声明置于文件顶部——顶部
-- net.Receive 复位块（KardsTableExited / KardsTableBattleStart）与手牌钩子共用，
-- Lua 词法作用域：引用须在声明之后，声明在后会被当作全局变量（nil）访问而报错
-- （2026-08-15 实测 cl_init.lua:898 attempt to index global 'remoteHandHover'）。
local remoteHandHover = { [1] = nil, [2] = nil }
-- 已发送悬停实体（悬停变化时广播，避免每帧发送）；kards_switch 切身份时随悬停
-- 重新检测自然覆盖，无需按槽位区分。
local lastSentHover = nil

-- 当前进入状态：{ ent = 牌桌实体, slot = 槽位编号 }（进入后非 nil，接管 HUD/摄像头）
-- 2026-08-11 已迁移至 KARDS.BattleState.inTable（cl_battle_state.lua）

-- 对战已开始（服务端 KardsTableBattleStart 置位）：隐藏本模组自绘提示文字，
-- 播放摄像头过渡动画；退出牌桌时复位
-- 2026-08-11 已迁移至 KARDS.BattleState.battleStarted（cl_battle_state.lua）

-- 先手揭晓 UI 状态（服务端 KardsTableBattleStart 附带先手槽位与敌方信息）：
-- pendingReveal = 摄像头动画结束后待启动的数据；KARDS.BattleState.reveal = 进行中状态（含头像面板，
-- 结构见 StartReveal）。头像用引擎内置 AvatarImage VGUI 控件（见 KardsFirstTurnReveal* 段）
local pendingReveal = nil
-- 2026-08-11 已迁移至 KARDS.BattleState.reveal（cl_battle_state.lua）
-- 总部对局开始动画是否已启动（每场对局一次）：头像与玩家名淡入完成后 REVEAL_HQ_IN_START
-- 秒启动（见 KardsFirstTurnRevealStart），先于先手揭晓；KardsTableBattleStart
-- 收到时重置，防止上一场残留导致本场不触发
local hqRevealStarted = false
-- 总部对局开始动画中的活跃 HQ 集合（re.md 重构：动画本身由 KARDS.AnimPlayer 关键帧
-- 播放器驱动，组名 "hqReveal"；本表仅保留 { ent, slot } 供 InHQRevealAnim 遍历判定 +
-- 全部完成时播放一次 hq_end 收尾音效；每场对局最多两个：本方 + 敌方）。声明置于文件
-- 顶部——顶部 net.Receive 复位块（KardsTableExited / KardsTableBattleStart）与动画
-- 驱动共用，Lua 词法作用域先例同 remoteHandHover（2026-08-15）。
local hqReveals = {}
-- B 修复（2026-08-12，2026-08-15 桥接修正）：每场对局复位 per-modelID 去重表的
-- 函数。定义在 cl_battle_material.lua（KARDS.KardsResetPerMatchDedup）——GMod
-- include 独立编译执行，不共享本文件词法作用域，故经 KARDS 命名空间访问；
-- 本文件 KardsTableBattleStart 回调经 KARDS.KardsResetPerMatchDedup 调用。
-- 清理头像面板（新对局 / 退出牌桌 / 序列结束）
local function ClearRevealPanels()
    if not KARDS.BattleState.reveal then return end
    if IsValid(KARDS.BattleState.reveal.leftAvatar) then KARDS.BattleState.reveal.leftAvatar:Remove() end
    if IsValid(KARDS.BattleState.reveal.rightAvatar) then KARDS.BattleState.reveal.rightAvatar:Remove() end
    KARDS.BattleState.reveal.leftAvatar, KARDS.BattleState.reveal.rightAvatar = nil, nil
end

-- 进入牌桌后的常驻头像（右上角 AvatarImage 面板，显示本地玩家头像）：
-- { panel = 面板,
--   fadeStart = 对局开始后淡出启动时刻 CurTime|nil,
--   slideStart = 当前滑动动画启动时刻 CurTime, slideFromX/slideToX = 滑动起止 x,
--   curX = 当前 x（退出反向滑动的起点用）, exiting = 是否反向滑出中 }
-- 进入牌桌：从屏幕右外侧先快后慢（easeOut）0.8s 滑入右上角并常驻显示；
-- 对局开始（KardsTableBattleStart）后 ENTER_AVATAR_FADE_DUR 秒淡出并移除；
-- 退出牌桌：动画反向（滑回屏幕右外侧）后移除（见 Think 钩子 KardsTableEnterAvatarUpdate）
local ENTER_AVATAR_SIZE = 128         -- 头像边长（px）
local ENTER_AVATAR_FADE_DUR = 0.5     -- 对局开始后淡出时长
local ENTER_AVATAR_SLIDE_DUR = 0.8    -- 进入/退出滑动时长
local enterAvatar = nil
local function ClearEnterAvatar()
    if not enterAvatar then return end
    if IsValid(enterAvatar.panel) then enterAvatar.panel:Remove() end
    enterAvatar = nil
end

-- 创建头像面板（引擎内置 AvatarImage 控件：SetPlayer 自动经 Steamworks 拿 SteamID64、
-- 从 Steam CDN 异步下载对应分辨率头像，期间显示默认占位头像；184 = 最高分辨率）
-- 层级（2026-10-26 用户规格「头像始终在最高层」）：创建时置极高 ZPos，且调用处每帧
-- MoveToFront——其它 VGUI 面板（弹窗等）的 MakePopup 内部会 MoveToFront 自身，只设
-- 初始 ZPos 不足以长期保证在其它面板之上，故两者并用。
local AVATAR_TOP_ZPOS = 32767
-- 2026-11-01 修复：AvatarImage 必须挂到 GetHUDPanel()（全屏、位置 0,0，子控件坐标即
-- 屏幕坐标）。此前无父面板创建，SetPos 不生效（头像固定停在屏幕左上角），且无父面板
-- 时 MoveToFront 无效、Think 后续淡出逻辑不再执行（头像在对局开始动画前后一直残留）。
local function MakeAvatarPanel(playerEnt, size)
    local av = vgui.Create("AvatarImage", GetHUDPanel())
    av:SetSize(size, size)
    av:SetMouseInputEnabled(false)
    av:SetKeyboardInputEnabled(false)
    av:SetZPos(AVATAR_TOP_ZPOS)
    if playerEnt then
        av:SetPlayer(playerEnt, 184)
    end
    return av
end

-- 对战开始后固定的色调映射/曝光目标标度（render.SetGoalToneMappingScale，见 PreRender 钩子）。
-- 1 = 引擎中性自动曝光基线；小于 1 使整体更暗、大于 1 更亮。俯视深色牌桌导致自动曝光爬升
-- 过曝时，将此值调小即可压暗牌桌外景物。
local BattleExposureScale = 1.0

-- 临时提示：{ text = 文字, expire = CurTime 截止 }（槽位占用拒绝 / 准备回执反馈）
local flashMsg = nil

-- 键盘状态（F4 上升沿检测；进入/退出改用控制台指令 kards_enter）
local prevF4 = false

-- ====================================================================
-- 重新调度（KARDS.BattleState.mulligan）+ 真实手牌客户端状态（2026-08-10 起，占位空手牌已移除）
-- 状态变量集中在文件顶部：先手揭晓序列结束（KardsFirstTurnRevealStart）发送
-- 重新调度就绪、KardsTableBattleStart / KardsTableExited 重置本状态均位于文件
-- 前部，故前移声明（坐标函数 HandFanPos / MulliganFanPos 因依赖手牌常量
-- HandSlot*，定义于文件后部，见下方「重新调度」段）。
-- ====================================================================
-- 重新调度状态（仅本方，由 KardsTableDeckDraw 首张本方发牌卡创建）：
--   { active, slot, total, cards = { [ent] = { ent, index, selected } }, submitted }
-- 2026-08-11 已迁移至 KARDS.BattleState.mulligan（cl_battle_state.lua）
-- 本方重新调度就绪已发送（每场对局一次；服务端据此发牌）
-- 2026-08-11 已迁移至 KARDS.BattleState.mulliganReadySent（cl_battle_state.lua）
-- 已完成重新调度的槽位（本方该槽后续抽牌不再走牌桌中间发牌路径）
-- 2026-08-11 已迁移至 KARDS.BattleState.mulliganDoneSlot（cl_battle_state.lua）
-- 真实手牌注册表：slot → { [ent] = 手牌序号 }（动画结束后由 KardsRealHandFacing 落位）
-- 2026-08-11 已迁移至 KARDS.BattleState.realHandCards（cl_battle_state.lua）
-- 发牌卡生成时（服务端卡堆顶）的局部坐标：弃牌回卡组动画的终点
-- 2026-08-11 已迁移至 KARDS.BattleState.entSpawnPos（cl_battle_state.lua）
-- 重新调度动画（re.md 重构：由 KARDS.AnimPlayer 关键帧播放器驱动，组名区分动画
-- 种类——发牌 "mulliganDeal" / 弃牌回卡组 "mulliganReturn" / 保留牌落手牌
-- "mulliganToHand"；busy 判定统一走 KARDS.AnimPlayer:Active(ent, 组名)）
-- 重新调度选择交互的上一帧左键状态（点击沿检测用）
-- 2026-08-11 已迁移至 KARDS.BattleState.prevMulliganLeft（cl_battle_state.lua）
-- 牌桌内鼠标呼出管理：只要玩家在牌桌内（KARDS.BattleState.inTable 非 nil）鼠标必须保持呼出
--（2026-08-10 反馈：重新调度点击「确认」后鼠标消失——确认/落位后仍在牌桌内，
--  不应关闭）。仅离开牌桌（KardsTableExited，含牌桌销毁触发的离开）时关闭；
-- 记录上次状态避免重复调用 EnableScreenClicker。
-- 2026-08-11 已迁移至 KARDS.BattleState.tableMouseOn（cl_battle_state.lua）
local function UpdateTableMouse()
    local want = KARDS.BattleState.inTable ~= nil
    if want ~= KARDS.BattleState.tableMouseOn then
        KARDS.BattleState.tableMouseOn = want
        gui.EnableScreenClicker(want)
    end
end
-- 重新调度「确认」按钮矩形（HUDPaint 写入，点击检测读取；准星下方）
-- 2026-08-11 已迁移至 KARDS.BattleState.mulliganConfirmRect（cl_battle_state.lua）
-- 卡组槽相对坐标 / 朝向（与服务端 ENT.DeckSlotBase / ENT.DeckSlotYaw 同步，
-- 弃牌回卡组动画终点的兜底位置）
local PileBase = { [1] = Vector(-32.72, 12.80, 18.43), [2] = Vector(32.88, -12.80, 18.43) }
local PileYaw = { [1] = -135, [2] = 45 }

-- 手牌拿起 / 拖拽 / 打出 状态（2026-08-10）：声明置于文件前部——状态重置
--（KardsTableExited / KardsTableBattleStart）与引用钩子（KardsDragCardThink /
-- KardsRealHandFacing / net 接收）均在本声明之后，Lua 词法作用域要求声明在前
--（声明在后会被当作全局 nil 访问而报错，2026-08-10 实测）
-- 拖拽中的卡：{ ent, slot, idx }（2026-08-11 已迁移至 KARDS.BattleState.dragCard）
-- 鼠标左键上一帧状态（上升沿拿起 / 下降沿松手）（2026-08-11 已迁移至 KARDS.BattleState.prevDragLeft）
-- 支援阵线布局：KARDS.BattleState.fieldLayouts[slot][ent] = 槽位 index（2026-08-11 已迁移至 KARDS.BattleState.fieldLayouts）
-- 战场位置动画（re.md 重构：由 KARDS.AnimPlayer 关键帧播放器驱动，组名——
-- 战场复位 "fieldRepos" / 松手回手牌 "dragReturn" / 部署飞行 "deployFlight"（源卡半程
-- + 小模型后半程，2026-08-12 起））
-- 等待服务端确认的打出实体（确认前冻结位置，防重复打出）（2026-08-11 已迁移至 KARDS.BattleState.pendingPlayEnt）
-- 已结束本方回合（点击按钮置位；对方回合开始广播回本方时复位，期间禁止拿起手牌）（2026-08-11 已迁移至 KARDS.BattleState.endedTurn）
-- 双方指挥点（服务端 KardsCommandPoints 广播；手牌花费 3D2D 文字颜色黄/灰判定）
-- 2026-08-11 已迁移至 KARDS.BattleState.commandPoints（cl_battle_state.lua）

-- ====================================================================
-- 共享工具（2026-08-15 拆分 C2）：手牌计数/忙判定/命中测试/候选场/局部 y 轴——
-- 由 cl_init.lua 多段与拆分文件共用，统一挂 KARDS 命名空间；定义置于文件前部，
-- 早于全部使用段（含 C1 拆分文件的 include 点）。运行时引用 KARDS.BattleState /
-- KARDS.AnimPlayer / KARDS.RayCardHit（KardsRealHandFacing 等使用段均晚于其定义）。
-- ====================================================================

--- 某槽当前手牌张数（真实手牌，含拖拽中/动画中）
-- 2026-10-03 联机排查 NEW-12：槽位越界时返回 0（上游接收器漏检时不因索引 nil 报错）
function KARDS.HandCount(slot)
    local map = KARDS.BattleState.realHandCards[slot]
    if not map then return 0 end
    local n = 0
    for e in pairs(map) do
        if IsValid(e) then n = n + 1 end
    end
    return n
end

--- 手牌是否处于「不可交互」状态（2026-08-15 C2 统一 3 处组名不一致的跳过列表）：
--- 待打出确认 / 拖拽中 / 抽牌（deckDraw）/ 返回手牌（dragReturn）/ 重排（handRepos）/
--- 调度转手牌（mulliganToHand）动画中的卡位置/角度由对应钩子接管，悬停/拿起跳过
function KARDS.IsHandBusy(ent)
    if not IsValid(ent) then return true end
    if ent == KARDS.BattleState.pendingPlayEnt then return true end
    if KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == ent then return true end
    return KARDS.AnimPlayer:Active(ent, "mulliganToHand", "deckDraw", "dragReturn", "handRepos")
end

--- 手牌命中测试（2026-08-15 C2 收敛拿起/悬停/预览 3 处内联）：射线命中某槽真实手牌
--- 卡面矩形（RayCardHit）的实体——重叠扇形卡取最先命中（t 最小）＝视觉最上层卡。
--- @param pos Vector 视线起点；dir Vector 视线方向；slot number 槽位（1/2）
--- @param skipBusy boolean 是否跳过 IsHandBusy 的卡（悬停/拿起 true；预览 false 保持原行为）
--- @return Entity|nil 命中的手牌实体
function KARDS.HandHitTest(pos, dir, slot, skipBusy)
    local bestT, hit = math.huge, nil
    for ent in pairs(KARDS.BattleState.realHandCards[slot]) do
        if IsValid(ent) and (not skipBusy or not KARDS.IsHandBusy(ent)) then
            local h, t = KARDS.RayCardHit(pos, dir, ent, KARDS.HandHitHalfW, KARDS.HandHitHalfL)
            if h and t < bestT then bestT, hit = t, ent end
        end
    end
    return hit
end

--- 候选场列表（2026-08-15 C2 收敛 GetPointingTarget / PointingFailReason /
--- cl_battle_stealth.HitStealthTarget 3 处内联）：双方支援阵线 + 占领方前线
---（归属槽 1/2；无主 0 不加入——前线无主时无单位可指）
--- @return table 布局表数组（fieldLayouts[1] / fieldLayouts[2] / 前线布局）
function KARDS.FieldCandidates()
    local BS = KARDS.BattleState
    local fields = {}
    for slot = 1, 2 do
        fields[#fields + 1] = BS.fieldLayouts[slot]
        if BS.frontlineOwnerSlot == slot then
            fields[#fields + 1] = BS.frontlineLayout
        end
    end
    return fields
end

--- 实体自身 +y 轴方向（父局部系；2026-08-15 C2 收敛悬停提升/预览偏移/占位卡悬停
--- 3 处内联——GMod 无 WorldToLocalVector，用两次 WorldToLocal 点变换求差）
--- @param ent Entity 实体
--- @return Vector 局部 +y 方向向量（父局部坐标，供 SetLocalPos 使用）
function KARDS.LocalYAxis(ent)
    local yp = ent:LocalToWorld(Vector(0, 1, 0)) - ent:GetPos()
    local parent = ent:GetParent()
    if IsValid(parent) then
        yp = parent:WorldToLocal(ent:LocalToWorld(Vector(0, 1, 0)))
            - parent:WorldToLocal(ent:GetPos())
    end
    return yp
end

-- ====================================================================
-- 指挥点 HUD 面板段（2026-08-11 拆分 B1：状态/常量/工具与 Think/HUDPaint 钩子、
-- net 接收器已迁移至 cl_battle_command_points.lua，导出 KARDS.CommandPointsReset /
-- KARDS.CommandPointsApplyBroadcast）
-- ====================================================================

-- ====================================================================
-- 结束回合按钮段（2026-08-11 拆分 B1：状态/常量/EndTurnRect/KardsEndTurnVisible/
-- KardsEndTurnThink/KardsEndTurnHUD 已迁移至 cl_battle_hud.lua，
-- 导出 KARDS.EndTurnReset 复位 prevEndTurnLeft）
-- ====================================================================

-- dynamic_BGM 插件进入牌桌前的播放模式（进入牌桌时保存并置 0 停止 BGM，
-- 退出牌桌时恢复原值；插件不存在则恒为 nil）
local savedBGMPlayMode = nil

-- 牌桌音效（2026-08-15 C1 拆分：PlayKardsSound / PlayAimSound / StopAimSound /
-- PlaySoundPath + KardsStatChangeSound / KardsEventSound 接收器已迁移至
-- cl_battle_sound.lua；本 include 置于 savedBGMPlayMode 声明之后，词法访问不变）
include("cl_battle_sound.lua")

-- 被消灭单位延迟消失（2026-08-13 用户规格）：场上目标死亡（防御 ≤0）后不立即消失，
-- 待「最晚飘字（数值变动特效，cl_card_text_overlay.lua Overlay.FX）结束 +0.5s」再消失。
-- 服务端死亡时先刷新防御（≤0）NW（触发防御变动飘字）再广播本消息；此处登记待移除
-- 实体，Think（KardsFieldDeathDelayedRemove）中等待防御 NW ≤0（死亡确认 + 飘字已
-- 触发）后计算该实体在播飘字的最晚结束时间，延迟（最晚结束 +0.5s）后发
-- KardsFieldDeathRemove 通知服务端移除（服务端 GuardRemove 幂等；兜底定时见
-- table_battledeck.lua ScheduleFieldDeathRemove）。
net.Receive("KardsFieldDeath", function()
    local ent = net.ReadEntity()
    local unitEnt = net.ReadEntity()
    if not IsValid(ent) or not IsValid(unitEnt) then return end
    KARDS.BattleState.fieldDeathPending = KARDS.BattleState.fieldDeathPending or
        setmetatable({}, { __mode = "k" })
    KARDS.BattleState.fieldDeathPending[unitEnt] = { table = ent, armed = false }
end)

hook.Add("Think", "KardsFieldDeathDelayedRemove", function()
    local pending = KARDS.BattleState.fieldDeathPending
    if not pending then return end
    for unitEnt, info in pairs(pending) do
        if not IsValid(unitEnt) then
            pending[unitEnt] = nil -- 实体已消失（如对局结束）：清理登记
        elseif not info.armed then
            -- 防御 NW ≤0 = 死亡已确认且防御变动飘字已触发（服务端 SyncUnitNW 写入）
            if unitEnt:GetNWInt("Kards_CardDefense", 99) <= 0 then
                info.armed = true -- 本帧确认；下一帧计算（确保 UpdateStatFX 已触发 FX）
            end
        else
            -- 计算该实体在播飘字的最晚结束时间（数值变动特效）
            local latestEnd = 0
            if KARDS.CardTextOverlay and KARDS.CardTextOverlay.FX then
                for _, fx in ipairs(KARDS.CardTextOverlay.FX) do
                    if fx.ent == unitEnt then
                        latestEnd = math.max(latestEnd, fx.start + fx.dur)
                    end
                end
            end
            local delay = math.max(0, latestEnd + 0.5 - CurTime())
            timer.Simple(delay, function()
                if IsValid(info.table) and IsValid(unitEnt) then
                    net.Start("KardsFieldDeathRemove")
                        net.WriteEntity(info.table)
                        net.WriteEntity(unitEnt)
                    net.SendToServer()
                end
                pending[unitEnt] = nil
            end)
            pending[unitEnt] = nil
        end
    end
end)

-- 匹配等待音效（sound/kards/match.ogg，2026-08-10）：玩家进入牌桌且牌桌未满
-- （< 2 名玩家）时循环播放，第二位玩家加入 / 对战开始 / 退出牌桌时停止。
-- sound.PlayFile 须用完整相对路径（sound/ 前缀）且文件名须为英文（BASS 未启用
-- UNICODE，非 ASCII 文件名加载失败，见 cl_dynamic_bgm_compat.lua；原 匹配.ogg
-- 已重命名为 match.ogg）。"noplay loop" = 加载不播 + 循环，回调后 Play() 开始。
local matchSnd = nil             -- 循环播放的音频通道（nil = 未播放）
local matchSoundWanted = false   -- 期望播放状态（StopMatchSound 后加载回调不播放，防"停止后仍播"）
local matchSoundPending = false  -- 加载中（sound.PlayFile 异步：回调返回前连续 Start 会重复加载 → 双重播放）
local tablePlayerCount = 0       -- 当前牌桌内玩家数（服务端 KardsTablePlayerCount 广播更新）
local function StartMatchSound()
    if matchSnd then return end
    matchSoundWanted = true
    if matchSoundPending then return end -- 已加载中：防重复启动第二个通道
    matchSoundPending = true
    sound.PlayFile("sound/kards/match.ogg", "noplay loop", function(channel)
        matchSoundPending = false
        if not IsValid(channel) then
            matchSnd = nil -- 加载失败：清标记，允许下次重试
            return
        end
        matchSnd = channel
        if matchSoundWanted then
            channel:Play() -- 加载期间未被停止 → 开始循环播放
        else
            channel:Stop() -- 加载期间已被停止（如对战开始）→ 不播放并释放
        end
    end)
end
local function StopMatchSound()
    matchSoundWanted = false
    if matchSnd then
        if IsValid(matchSnd) then matchSnd:Stop() end
        matchSnd = nil
    end
end
-- 按当前状态决定播放/停止：牌桌内 + 对战模式 + 对战未开始（NW 服务端权威）+
-- 牌桌未满（< 2 名玩家）→ 播放；否则停止（调用点：进入牌桌 / 玩家数广播 /
-- 对战开始 / 退出牌桌）
local function UpdateMatchSound()
    local want = false
    if KARDS.BattleState.inTable then
        local ent = KARDS.BattleState.inTable.ent
        want = ent:GetNWString("Kards_Mode", "battle") == "battle"
            and not ent:GetNWBool("Kards_FormalBattleStarted", false)
            and tablePlayerCount < 2
    end
    if want then
        StartMatchSound()
    else
        StopMatchSound()
    end
end
-- 显示临时提示（2 秒后消失）
local function Flash(text)
    -- 注意：字段名不能用 until（GLua 保留字，repeat...until 结构用），否则编译报错
    flashMsg = { text = text, expire = CurTime() + 2 }
end

-- ====================================================================
-- 初始化卡顿加载提示（FPS 检测，2026-08-09）：
-- 实体卡牌初始化（组卡铺卡 / 卡组槽加载）伴随客户端文件 I/O 与渲染重建，
-- 期间帧率会跌至 10 以下（不可避免的初始化卡顿）。进入牌桌 / 切换组卡模式时
-- 启动 FPS 检测，把卡顿转换为加载提示：
--   帧率连续 2 帧 <10 → 立即在准星下方显示提示（正在初始化战场 / 卡组）；
--   帧率恢复 ≥10 → 停留 1 秒后 0.5 秒淡出。
-- 状态机：idle（已武装未触发）→ showing（显示）→ holding（帧率恢复停留）→
--         fading（淡出）→ idle；showing/holding/fading 期间再掉帧则回 showing。
-- 武装/解除：KardsTableEntered（战场）/ KardsTableModeChanged deck（卡组）武装，
-- KardsTableExited / 切回对战解除。提示位置 = 屏幕中心下方（准星下方；进入牌桌后
-- 默认十字准星虽被 HUDShouldDraw 隐藏，位置仍以屏幕中心为基准）。
-- ====================================================================
local LOADING_FPS_THRESHOLD = 10  -- 帧率阈值（低于视为初始化卡顿）
local LOADING_LOW_FRAMES = 2      -- 连续低于阈值的帧数（防单帧抖动误触发）
local LOADING_HOLD = 1.0          -- 帧率恢复后停留时长（秒）
local LOADING_FADE = 0.5          -- 淡出时长（秒）
local LOADING_ALPHA = 220         -- 提示不透明度（0~255）
-- 加载提示状态：{ text = 文字, state = "idle"/"showing"/"holding"/"fading",
--                lowFrames = 连续低帧计数, holdStart/fadeStart = CurTime }
local initLoading = nil

-- 启动加载提示检测（text 变化时重置为待触发状态）
local function StartInitLoading(text)
    if initLoading and initLoading.text == text then return end
    initLoading = { text = text, state = "idle", lowFrames = 0 }
end

-- 停止加载提示检测（退出牌桌 / 切回对战模式）
local function StopInitLoading()
    initLoading = nil
end

-- 每帧：FPS 检测 + 状态机驱动（FrameTime 即上一帧渲染耗时，1/ft 为瞬时帧率）
hook.Add("Think", "KardsInitLoadingDetect", function()
    local st = initLoading
    if not st then return end
    local ft = FrameTime()
    if ft <= 0 then return end
    if 1 / ft < LOADING_FPS_THRESHOLD then
        st.lowFrames = st.lowFrames + 1
    else
        st.lowFrames = 0
    end
    local t = CurTime()
    if st.state == "idle" then
        if st.lowFrames >= LOADING_LOW_FRAMES then
            st.state = "showing"
        end
    elseif st.state == "showing" then
        if st.lowFrames < LOADING_LOW_FRAMES then
            -- 帧率已恢复：进入停留计时（期间再掉帧则回 showing）
            st.state = "holding"
            st.holdStart = t
        end
    elseif st.state == "holding" then
        if st.lowFrames >= LOADING_LOW_FRAMES then
            st.state = "showing" -- 又掉帧：取消停留，回到显示态
        elseif t - st.holdStart >= LOADING_HOLD then
            st.state = "fading"
            st.fadeStart = t
        end
    elseif st.state == "fading" then
        if st.lowFrames >= LOADING_LOW_FRAMES then
            st.state = "showing" -- 淡出期间又掉帧：回到显示态
        elseif t - st.fadeStart >= LOADING_FADE then
            st.state = "idle"
        end
    end
end)

-- 绘制加载提示（准星下方：屏幕中心下方 40px，黑底圆角 + 白色文字）
hook.Add("HUDPaint", "KardsInitLoadingDraw", function()
    local st = initLoading
    if not st then return end
    local alpha = LOADING_ALPHA
    if st.state == "fading" then
        local p = (CurTime() - st.fadeStart) / LOADING_FADE
        if p >= 1 then return end
        alpha = math.floor(LOADING_ALPHA * (1 - p))
    elseif st.state ~= "showing" and st.state ~= "holding" then
        return
    end
    local x, y = ScrW() / 2, ScrH() / 2 + 40 -- 准星下方
    surface.SetFont("SourceHan_Heavy_32")
    local tw, th = surface.GetTextSize(st.text)
    draw.RoundedBox(8, x - tw / 2 - 16, y - th / 2 - 10, tw + 32, th + 20,
        Color(0, 0, 0, math.floor(alpha * 0.7)))
    draw.SimpleText(st.text, "SourceHan_Heavy_32", x, y,
        Color(255, 255, 255, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

-- 客户端每帧：槽位提示检测 + F4（准备）按键上升沿
hook.Add("Think", "KardsTableSlotHint", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then
        slotHint = nil
        return
    end

    -- 槽位提示检测（已进入则不再提示进入提示；宽面提示同样只在未进入时检测）
    if KARDS.BattleState.inTable then
        slotHint = nil
        wideHint = nil
    else
        local foundEnt, foundSlot = nil, nil
        local foundWide = nil
        for _, ent in ipairs(ents.FindByClass("sent_kards_battle_table")) do
            if IsValid(ent) then
                local slot = ent:GetPlayerSlot(ply)
                if slot then
                    foundEnt, foundSlot = ent, slot
                    break
                end
                -- 宽面（x 侧中段）：可切换组卡/对战模式（与槽位判定互斥）
                if not foundWide and ent:IsAtWideSide(ply) then
                    foundWide = ent
                end
            end
        end
        slotHint = foundEnt and { ent = foundEnt, slot = foundSlot } or nil
        wideHint = foundWide
    end

    -- 控制台 / 暂停菜单（游戏 UI）打开时忽略按键（避免误触）
    if gui.IsConsoleVisible() or gui.IsGameUIVisible() then
        prevF4 = input.IsKeyDown(KEY_F4)
        return
    end
    local f4Down = input.IsKeyDown(KEY_F4)
    -- F4 上升沿：已进入 → 请求准备
    if f4Down and not prevF4 and KARDS.BattleState.inTable then
        net.Start("KardsTableReady")
            net.WriteEntity(KARDS.BattleState.inTable.ent)
        net.SendToServer()
    end
    prevF4 = f4Down
end)

-- 控制台指令：进入/退出牌桌 / 切换组卡模式（位置判定，无需准星瞄准；可 bind <键> "kards_enter"）
-- 已进入 → 请求退出；未进入 → 在槽位（长边两端）→ 请求进入；在宽面（x 侧，IsAtWideSide）
-- → 请求切换牌桌模式（组卡 deck / 对战 battle，服务端权威校验）
concommand.Add("kards_enter", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    if KARDS.BattleState.inTable then
        net.Start("KardsTableExit")
            net.WriteEntity(KARDS.BattleState.inTable.ent)
        net.SendToServer()
        return
    end
    for _, ent in ipairs(ents.FindByClass("sent_kards_battle_table")) do
        if IsValid(ent) and ent:GetPlayerSlot(ply) then
            net.Start("KardsTableEnter")
                net.WriteEntity(ent)
            net.SendToServer()
            return
        end
    end
    -- 宽面：切换组卡/对战模式
    for _, ent in ipairs(ents.FindByClass("sent_kards_battle_table")) do
        if IsValid(ent) and ent:IsAtWideSide(ply) then
            net.Start("KardsTableToggleMode")
                net.WriteEntity(ent)
            net.SendToServer()
            return
        end
    end
end)

-- 控制台指令：随时切换距离玩家最近牌桌的视角（本地执行，无需进入牌桌；可 bind <键> "kards_view p1"）
--   kards_view        观战者视角（解除相机接管 + 卡牌朝向按归属方，见 cl_perspective.lua LocalView=nil）
--   kards_view p1     P1 牌桌视角（正上方俯视，画面"上"朝 P1 侧；卡牌朝向 P1 视角规则）
--   kards_view p2     P2 牌桌视角（正上方俯视，画面"上"朝 P2 侧；卡牌朝向 P2 视角规则）
-- P1/P2 相机目标与对战开始目标相机一致（yaw=270/90，见 KardsTableBattleStart）
concommand.Add("kards_view", function(ply, cmd, args)
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    -- 距离玩家最近牌桌（无牌桌直接返回）
    local bestEnt, bestDist = nil, math.huge
    for _, ent in ipairs(ents.FindByClass("sent_kards_battle_table")) do
        if IsValid(ent) then
            local d = ent:GetPos():DistToSqr(ply:GetPos())
            if d < bestDist then bestDist, bestEnt = d, ent end
        end
    end
    if not IsValid(bestEnt) then
        print("[Kards] kards_view: 未找到牌桌")
        return
    end
    local arg = (args and #args > 0 and tostring(args[1]):lower()) or ""
    if arg == "p1" or arg == "p2" then
        local slot = (arg == "p1") and 1 or 2
        -- 卡牌朝向视角（P1/P2 槽位视角，见 cl_perspective.lua LocalView）
        if KARDS.Perspective and KARDS.Perspective.SetLocalView then
            KARDS.Perspective:SetLocalView(slot)
        end
        -- 相机：正上方俯视，画面"上"方向朝向各自玩家（P2 yaw=90 / P1 相差 180° yaw=270）
        if KARDS.BattleCamera and KARDS.BattleCamera.SetView then
            local deckPos = bestEnt:LocalToWorld(Vector(0, 0, 60))
            local deckAng = bestEnt:LocalToWorldAngles(Angle(90, (slot == 1) and 270 or 90, 0))
            KARDS.BattleCamera:SetView(ply, deckPos, deckAng, 75)
        end
        print(("[Kards] kards_view: 最近牌桌 → %s 视角"):format(arg))
    else
        -- 观战者视角：解除相机接管（自由视角）+ 卡牌朝向按归属方（LocalView=nil）
        if KARDS.BattleCamera and KARDS.BattleCamera.Reset then
            KARDS.BattleCamera:Reset(ply)
        end
        if KARDS.Perspective and KARDS.Perspective.SetLocalView then
            KARDS.Perspective:SetLocalView(nil)
        end
        print("[Kards] kards_view: 最近牌桌 → 观战者视角")
    end
end)

-- 完全接管 HUD：进入后隐藏 GMod 全部默认 HUD 元素（HUDShouldDraw 对所有元素返回 false）
-- 2026-11-12：实测本环境里该拦截会让引擎跳过整个 HUDPaint 阶段，自绘战斗界面随之全部消失，
-- 故在 PostDrawHUD 补跑一次 HUDPaint；帧号标志保证正常环境（引擎已执行 HUDPaint）不会重复绘制
local hudPaintFrame = nil
hook.Add("HUDPaint", "KardsTableHUDGuard", function()
    hudPaintFrame = FrameNumber()
end)
hook.Add("HUDShouldDraw", "KardsTableHUD", function()
    if KARDS.BattleState.inTable then return false end
end)
hook.Add("PostDrawHUD", "KardsTableHUDFallback", function()
    if KARDS.BattleState.inTable and hudPaintFrame ~= FrameNumber() then
        hook.Run("HUDPaint")
    end
end)

--[[
    对战开始后固定色调映射/曝光目标：PreRender 每帧调用 render.SetGoalToneMappingScale
    （引擎每帧重置该目标，故需逐帧设置）。
    原因：俯视深色木质牌桌时，GMod 自动曝光认为画面过暗而持续调高曝光；牌桌为深色
    几乎不受曝光影响，导致牌桌外景物被过度调亮（过曝）。组卡模式桌面铺有卡牌、平均
    亮度正常，故不受影响。固定目标后曝光不再随俯视画面爬升；若仍过曝，调小
    BattleExposureScale（<1 更暗）。
]]
hook.Add("PreRender", "KardsBattleFixedExposure", function()
    if KARDS.BattleState.battleStarted and KARDS.BattleState.inTable then
        render.SetGoalToneMappingScale(BattleExposureScale)
    end
end)

-- 进入后隐藏常见 VGUI（打开的菜单 / 比分板），尽力减少其他界面残留
hook.Add("Think", "KardsTableHideVGUI", function()
    if not KARDS.BattleState.inTable then return end
    CloseDermaMenus()
    if scoreboard and scoreboard.Hide then scoreboard.Hide() end
end)

-- 屏幕底部渲染提示：未进入且在槽位范围 → 进入提示；已进入 → 退出/准备提示；临时提示
-- 对战开始后隐藏本模组自绘提示（KARDS.BattleState.battleStarted，配合 HUDShouldDraw 全面接管画面）
hook.Add("HUDPaint", "KardsTableSlotHintDraw", function()
    if KARDS.BattleState.inTable and not KARDS.BattleState.battleStarted then
        -- 已进入：提示退出 / 准备（玩家序号取自槽位编号）
        draw.SimpleText(T("battle.slot.exit", KARDS.BattleState.inTable.slot), "SourceHan_Heavy_24",
            ScrW() / 2, ScrH() - 80,
            Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    elseif slotHint then
        -- 未进入且处于槽位范围：提示进入（玩家序号取自槽位编号）
        draw.SimpleText(T("battle.slot.enter", slotHint.slot), "SourceHan_Heavy_24",
            ScrW() / 2, ScrH() - 80,
            Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    elseif wideHint and IsValid(wideHint) then
        -- 未进入且处于宽面（x 侧中段）：提示切换组卡/对战模式（模式经 NW 同步）
        local mode = wideHint:GetNWString("Kards_Mode", "battle")
        local modeText = (mode == "deck") and T("battle.mode.deck") or T("battle.mode.battle")
        draw.SimpleText(T("battle.slot.toggle_mode", modeText), "SourceHan_Heavy_24",
            ScrW() / 2, ScrH() - 80,
            Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    -- 临时提示（槽位占用拒绝 / 准备回执）
    if flashMsg and CurTime() < flashMsg.expire then
        draw.SimpleText(flashMsg.text, "SourceHan_Heavy_24",
            ScrW() / 2, ScrH() - 120,
            Color(255, 220, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end)

-- 进入成功：接管 HUD 与摄像头（摄像头放宽边外侧上方，面向牌桌中心）
-- 呼出鼠标（gui.EnableScreenClicker(true)：显示光标、鼠标不再旋转角色视角，供 UI 点击；退出时恢复）
net.Receive("KardsTableEntered", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local count = net.ReadUInt(8) -- 当前牌桌玩家数（含本次进入者；匹配音效循环播放依据）
    if not IsValid(ent) then return end
    KARDS.BattleState.inTable = { ent = ent, slot = slot }
    -- 观战追踪复位（进入牌桌成为参战者：观战重新调度进度不再适用，见 KardsSpectateMulliganHUD）
    KARDS.BattleState.spectate = nil
    KARDS.BattleState.mulliganStarted = false
    tablePlayerCount = count
    UpdateMatchSound() -- 进入牌桌且未满（< 2 人）→ 开始循环播放匹配音效
    -- 进入牌桌：若 dynamic_BGM 插件存在，暂停其 BGM（插件主循环仅在
    -- BGMPlayMode==0 时每帧 StopAllBGM 并 return，故需置 0 才能持续停止；
    -- 原模式保存于 savedBGMPlayMode，退出牌桌时恢复。插件全局 API 见
    -- dynamic_BGM/lua/autorun/dynamic_bgm_client.lua）
    if _G.DynamicBGM and _G.DynamicBGM.Config then
        savedBGMPlayMode = _G.DynamicBGM.Config.BGMPlayMode -- 保存原播放模式（每次进入覆盖，保证为原始配置）
        _G.DynamicBGM.Config.BGMPlayMode = 0
        if _G.DynamicBGM.StopAllBGM then _G.DynamicBGM.StopAllBGM() end -- 立即停止当前播放
    end
    -- 初始化卡顿加载提示：进入牌桌启动 FPS 检测。对战模式 → 「正在初始化战场」
    -- （卡组槽/手牌槽实体初始化）；组卡模式 → 组卡卡牌初始化仍在进行，保持「正在
    -- 初始化卡组」检测（模式切换时已武装，此处同文字不重置）
    if ent:GetNWString("Kards_Mode", "battle") == "deck" then
        StartInitLoading(T("battle.loading.deck"))
    else
        StartInitLoading(T("battle.loading.battle"))
    end
    -- 设置本地视角（见 cl_perspective.lua）：仅对战开始后才区分 P1/P2 槽位视角；
    -- 加入牌桌但未开始对战一律使用观察者视角（nil），对战开始后由
    -- KardsTableBattleStart 切换为槽位视角（P1=槽位1 / P2=槽位2）。
    -- 中途重进（对战已开始）则直接按槽位视角（服务端 Kards_FormalBattleStarted NW）。
    -- 战场卡/手牌槽卡朝向按视角本地计算（见 KardsFieldFacing / KardsHandSlotFacing 驱动）
    local started = ent:GetNWBool("Kards_FormalBattleStarted", false)
    if KARDS.Perspective and KARDS.Perspective.SetLocalView then
        KARDS.Perspective:SetLocalView(started and slot or nil)
    end
    UpdateTableMouse() -- 牌桌内：呼出鼠标（进入即呼出，离开才关闭，见函数说明）
    -- 右侧常驻头像（右上角）：进入牌桌从屏幕右外侧先快后慢滑入；对局开始后淡出并移除
    -- （位置/透明度由 Think 钩子 KardsTableEnterAvatarUpdate 逐帧维护）
    ClearEnterAvatar()
    enterAvatar = {
        panel = MakeAvatarPanel(LocalPlayer(), ENTER_AVATAR_SIZE),
        fadeStart = nil,
        slideStart = CurTime(),
        slideFromX = ScrW(),                                -- 屏幕右外侧起点（头像完全在屏外）
        slideToX = ScrW() - ENTER_AVATAR_SIZE - 40,         -- 目标：右上角
        curX = ScrW(),
        exiting = false,
    }
    -- BattleCamera 接管（见 cl_battle_camera.lua SetView）：组卡模式 → 牌桌正上方俯视；
    -- 对战模式 → 共享常量算出的世界坐标（已向下移动，见 shared.lua SlotCameraLocalPos）
    -- 朝向指向牌桌中心后 pitch 上抬（更平视）；fov 75
    local camPos, camAng
    if ent:GetNWString("Kards_Mode", "battle") == "deck" then
        -- 组卡模式：摄像头靠近牌桌俯视（局部 z 上方 60 高度，垂直朝下），画面在 xy 平面逆时针旋转 90°（yaw +90）
        camPos = ent:LocalToWorld(Vector(0, 0, 60))
        camAng = ent:LocalToWorldAngles(Angle(90, 90, 0))
    else
        camPos = ent:GetSlotCameraWorldPos()
        camAng = (ent:GetPos() - camPos):Angle()
        camAng.pitch = camAng.pitch - 30 -- 上抬 30°（Source 引擎 pitch 正值=俯视，相机在桌面上方看中心为正 pitch，减 30 更平视）
    end
    -- 进入动画（两关键帧路径）：以玩家当前眼睛位置/视角为起点关键帧，1.2s smoothstep 缓动插值到目标相机位
    local ply = LocalPlayer()
    local fromPos = ply:GetPos() + Vector(0, 0, 64)
    local fromAng = ply:EyeAngles()
    KARDS.BattleCamera:SetView(ply, camPos, camAng, 75, 1.2, fromPos, fromAng)
end)

-- 牌桌玩家数广播（服务端 TryEnterSlot 在任意玩家加入后发送）：第二位玩家加入
-- （牌桌满）→ 停止匹配音效；对战开始 / 退出牌桌同样停止（见各自处理）
net.Receive("KardsTablePlayerCount", function()
    local ent = net.ReadEntity()
    local count = net.ReadUInt(8)
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then
        tablePlayerCount = count
        UpdateMatchSound()
    end
end)

--[[
    每场对局共享状态复位（2026-09-13 规划 S2/R1）：
    退出牌桌（KardsTableExited）与新一场对局开始（KardsTableBattleStart 参战分支）
    原有两处长序列逐项一致，收敛为单一入口，防后续新增状态只在一处复位造成跨场/跨桌
    残留。仅复位对局共享状态；摄像头 / BGM / 鼠标 / 常驻头像 / 本地视角等接管类
    复位与调用点特有流程仍由各接收器自行处理。
]]
function KARDS.ResetBattleState()
    local BS = KARDS.BattleState
    -- 重新调度状态复位（含观战追踪）
    BS.mulligan = nil
    BS.mulliganReadySent = false
    BS.mulliganDoneSlot = {}
    BS.mulliganAnimSentSlot = {}
    BS.dealStarterCount = {}
    BS.mulliganStarted = false
    BS.spectate = nil
    BS.realHandCards[1], BS.realHandCards[2] = {}, {}
    BS.prevMulliganLeft = false
    -- 结束回合按钮状态复位（当前回合/悬停/点击沿）
    BS.battleTurn = nil
    BS.turnHint = nil -- 友方回合开始提示（cl_battle_hud.lua）
    BS.endTurnRect = nil
    BS.endTurnHover = 0
    KARDS.EndTurnReset()
    -- 指挥点复位（手牌花费颜色恢复默认；HUD 面板显示与动画清空）
    BS.commandPoints[1], BS.commandPoints[2] = 0, 0
    KARDS.CommandPointsReset()
    -- 手牌拿起/拖拽/打出状态复位（拖拽卡/待确认/战场布局/动画表）
    BS.dragCard = nil
    BS.pendingPlayEnt = nil
    BS.endedTurn = false
    BS.fieldLayouts[1], BS.fieldLayouts[2] = {}, {}
    BS.remoteDrags = {}
    remoteHandHover[1], remoteHandHover[2] = nil, nil
    lastSentHover = nil
    BS.dragSync = {}
    BS.effectCache = setmetatable({}, { __mode = "k" })
    BS.cardFaces = setmetatable({}, { __mode = "k" })
    BS.commandAnimQueue = {}
    BS.frontlineLayout = {}
    BS.frontlineOwnerSlot = 0
    KARDS.UnitOpsReset()
    KARDS.BattleHint.Clear()
    KARDS.AnimPlayer:StopAll()
    hqReveals = {} -- 总部对局开始动画活跃集合复位（StopAll 中断时 onComplete 不触发）
    BS.prevDragLeft = false
    -- 角落玩家头像面板复位（移除控件 + 清空数据源，见 cl_battle_player_panel.lua）
    if KARDS.PlayerPanelReset then KARDS.PlayerPanelReset() end
end

-- 退出成功：恢复默认 HUD 与摄像头（并恢复鼠标视角控制）；清理先手揭晓 UI 残留
net.Receive("KardsTableExited", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then
        KARDS.BattleState.inTable = nil
        -- 退出牌桌：对局结算状态复位（黑屏动画进行中则保留由 KardsGameOverThink 收尾，
        -- 见 cl_battle_gameover.lua GameOverReset）
        if KARDS.GameOverReset then KARDS.GameOverReset() end
        tablePlayerCount = 0
        UpdateMatchSound() -- 离开牌桌：停止匹配音效（循环播放通道释放）
        -- 离开牌桌：对局结束为淡出停止战斗 BGM（2026-08-15 用户规格；牌桌销毁由
        -- table_cleanup.lua OnRemove 立即停止，见 cl_battle_bgm.lua 播放模式说明）
        if KARDS.StopBattleBGM and KARDS.BattleBGM then
            KARDS.StopBattleBGM(KARDS.BattleBGM.FadeOut)
        end
        KARDS.BattleState.battleStarted = false
        pendingReveal = nil
        StopInitLoading() -- 退出牌桌：停止初始化卡顿加载提示检测
        -- 退出牌桌：清除本地视角（回到观战视角；战场卡朝向按归属方，见 cl_perspective.lua）
        if KARDS.Perspective and KARDS.Perspective.SetLocalView then
            KARDS.Perspective:SetLocalView(nil)
        end
        -- 退出牌桌：常驻头像动画反向（从当前位置先快后慢滑回屏幕右外侧），
        -- 滑出完成后由 KardsTableEnterAvatarUpdate 移除；面板无效则直接清理
        if enterAvatar and IsValid(enterAvatar.panel) then
            enterAvatar.fadeStart = nil -- 取消淡出：滑出期间恢复完整不透明
            enterAvatar.exiting = true
            enterAvatar.slideStart = CurTime()
            enterAvatar.slideFromX = enterAvatar.curX
            enterAvatar.slideToX = ScrW()
        else
            ClearEnterAvatar()
        end
        ClearRevealPanels()
        KARDS.BattleState.reveal = nil
        -- 对局共享状态复位（重新调度/手牌/布局/指挥点/动画表等，见 ResetBattleState）
        KARDS.ResetBattleState()
        -- 离开牌桌：关闭测试版不同步重启弹窗（若残留）
        if KARDS.DesyncReset then KARDS.DesyncReset() end
        -- 离开牌桌：清空三选一交互（候选实体/动画/悬停态，见 cl_battle_pick.lua）
        if KARDS.BattlePickReset then KARDS.BattlePickReset() end
        -- 离开牌桌：清空弃牌选择交互（手牌上移/选中/确认按钮，见 cl_battle_discard.lua）
        if KARDS.BattleDiscardReset then KARDS.BattleDiscardReset() end
        -- 退出牌桌：恢复 dynamic_BGM 原播放模式（进入牌桌时置 0 停止 BGM，见
        -- KardsTableEntered；插件不存在则 savedBGMPlayMode 恒为 nil 不处理）
        if savedBGMPlayMode ~= nil and _G.DynamicBGM and _G.DynamicBGM.Config then
            _G.DynamicBGM.Config.BGMPlayMode = savedBGMPlayMode
        end
        savedBGMPlayMode = nil
        KARDS.BattleCamera:Reset(LocalPlayer())
        UpdateTableMouse() -- 离开牌桌：关闭鼠标（唯一关闭点，见函数说明）
    end
end)

-- 服务端提示（如槽位被占用 / 单位操作失败原因）：转提示系统居中显示（2026-08-12）
-- 2026-11-08 改由 KARDS.TableSync 的提示通道接收，字段由描述符统一读取，见
-- docs/adr/0007-牌桌消息收发契约.md
KARDS.TableSync.Handler("KardsTableMsg", function(payload)
    KARDS.BattleHint.Push(payload.text)
end)

-- 准备回执：显示已准备状态
net.Receive("KardsTableReadyAck", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local ready = net.ReadBool()
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then
        Flash(ready and T("battle.ready.ack", slot) or T("battle.ready.cancel", slot))
    end
end)

--[[
    对战正式开始（服务端 StartFormalBattle 逐个发送）：完全接管画面并播放摄像头过渡。
      1. HUD 隐藏：KARDS.BattleState.inTable 期间 HUDShouldDraw 已对所有默认元素返回 false（含十字准星/
         血量/弹药/语音等，第三方走 HUDShouldDraw 的亦被隐藏）；此处再置 KARDS.BattleState.battleStarted
         隐藏本模组自绘提示文字。尽力而为：绕过 HUDShouldDraw 直接 HUDPaint 的第三方
         模组无法被本模组可靠屏蔽。
      2. 摄像头过渡：起始关键帧 = 位置在宽边 +x 侧外部（局部 (70,0,30)，与默认进入
         相机 (-70,0,30) 相对），朝向 = 面向牌桌中心（+ 上抬 30°）再叠加三向旋转
         （yz 平面逆时针 90°=roll-90、xz 平面逆时针 45°=pitch+45、xy 平面逆时针
         45°=yaw+45；若实测某向视觉相反则对应取负）；2 秒 smoothstep 渐变到组卡模式
         相机（局部 (0,0,60) 正上方俯视，画面在 xy 平面逆时针旋转 90°）。
      3. 附带数据（服务端按玩家逐个写入）：随机先手槽位（WriteUInt 8）+ 该玩家的
         敌方是否存在（WriteBool）+ 敌方名称/SteamID64（WriteString，存在时）。
         存入 pendingReveal，待摄像头动画结束后启动先手揭晓动画（见下方
         KardsFirstTurnReveal* 段）。
]]
-- 当前回合方更新（服务端 KardsTurnUpdate，对战开始 / 结束回合时广播）：
-- 记录 KARDS.BattleState.battleTurn 驱动 HUD「结束回合」按钮友方/敌方状态（见 KardsEndTurnHUD）；
-- 观战者（KARDS.BattleState.inTable 非本桌）不记录，按钮仅对局内玩家显示。
-- 对方结束回合广播回本方（KARDS.BattleState.battleTurn 由对方 → 本方）时：播放「友方回合开始」音效
-- + 友方回合开始提示（渐变横幅 + 文字淡入缩小，屏幕震动在文字动画 2/3 处，见 cl_battle_hud.lua）
-- + 复位 KARDS.BattleState.endedTurn（本方回合恢复可拿起手牌）；对局开始首次广播
--（KARDS.BattleState.battleTurn 为 nil）不触发。
net.Receive("KardsTurnUpdate", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    if not IsValid(ent) then return end
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then
        local wasOther = KARDS.BattleState.battleTurn ~= nil and KARDS.BattleState.battleTurn ~= KARDS.BattleState.inTable.slot
        KARDS.BattleState.battleTurn = slot
        if slot == KARDS.BattleState.inTable.slot and wasOther then
            KARDS.BattleState.endedTurn = false -- 本方回合开始：恢复可拿起手牌
            KARDS.PlayKardsSound("turnstart")
            -- 友方回合开始提示（渐变横幅 + 文字淡入缩小；屏幕震动在文字动画
            -- 2/3 处触发，时序统一由 cl_battle_hud.lua ShowFriendlyTurnHint 驱动）
            KARDS.ShowFriendlyTurnHint(ent)
        end
    end
end)

-- 指挥点广播（2026-08-11 拆分 B1：net 接收器已迁移至 cl_battle_command_points.lua，
-- 主体为 KARDS.CommandPointsApplyBroadcast；服务端 BroadcastCommandPoints 见 table_session.lua）


net.Receive("KardsTableBattleStart", function()
    local ent = net.ReadEntity()
    local firstSlot = net.ReadUInt(8)
    local hasEnemy = net.ReadBool()
    local enemyName, enemySteamID64 = nil, nil
    if hasEnemy then
        enemyName = net.ReadString()
        enemySteamID64 = net.ReadString()
    end
    if not IsValid(ent) then return end
    -- 新一场对局：对局结算状态复位（上一场结算残留，见 cl_battle_gameover.lua GameOverReset）
    if KARDS.GameOverReset then KARDS.GameOverReset() end
    -- B 修复（2026-08-12）：每场对局开始复位 per-modelID 去重表（血红镰刀跨桌污染，
    -- 机制见 cl_battle_material.lua KARDS.KardsResetPerMatchDedup）。置于 if/else
    -- 分支之前：参战者与观战者路径都覆盖（观战者本地同样渲染卡组槽卡/抽牌临时卡）。
    if KARDS.KardsResetPerMatchDedup then KARDS.KardsResetPerMatchDedup() end
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then
        KARDS.BattleState.battleStarted = true
        -- 对战开始：立即无条件停止匹配音效（服务端 SetNWBool 的 Kards_FormalBattleStarted
        -- 随下个网络更新同步，晚于本 net 消息——依赖 UpdateMatchSound 的 NW 条件会因
        -- NW 仍为 false 而继续播放；StopMatchSound 同时使加载中的通道不播放）
        StopMatchSound()
        hqRevealStarted = false -- 新一场对局：总部动画启动标志复位（上一场残留防误触发）
        -- 新一场对局：对局共享状态复位（重新调度/手牌/布局/指挥点/动画表等，
        -- 与退出牌桌共用 ResetBattleState，规划 S2/R1）
        KARDS.ResetBattleState()
        -- 新对局：关闭测试版不同步重启弹窗（若残留）
        if KARDS.DesyncReset then KARDS.DesyncReset() end
        -- 新对局：清空三选一交互（候选实体/动画/悬停态，见 cl_battle_pick.lua）
        if KARDS.BattlePickReset then KARDS.BattlePickReset() end
        -- 新对局：清空弃牌选择交互（手牌上移/选中/确认按钮，见 cl_battle_discard.lua）
        if KARDS.BattleDiscardReset then KARDS.BattleDiscardReset() end
        UpdateTableMouse() -- 对局开始：仍处牌桌内，鼠标保持呼出（2026-08-10）
        -- 对战开始：本地视角从观察者（nil）切换为槽位视角（P1/P2），
        -- 手牌槽卡/战场卡朝向随之切换（见 cl_perspective.lua ApplyHandFacing/ApplyFacing）
        if KARDS.Perspective and KARDS.Perspective.SetLocalView then
            KARDS.Perspective:SetLocalView(KARDS.BattleState.inTable.slot)
        end
        -- 对局开始：右上角常驻头像开始淡出（见 KardsTableEnterAvatarUpdate）
        if enterAvatar then enterAvatar.fadeStart = CurTime() end
        -- 重置上一场残留的揭晓状态（StartFormalBattle 幂等，正常流程不会触发）
        ClearRevealPanels()
        KARDS.BattleState.reveal = nil
        pendingReveal = {
            firstSlot = firstSlot,
            enemyName = enemyName,
            enemySteamID64 = enemySteamID64,
        }
        -- 角落玩家头像面板数据源（2026-10-10）：敌方昵称 + SteamID64（PlayerPanelIntro
        -- 按此查找敌方玩家实体；虚拟对手时为 nil，头像缺失走白色矩形兜底，见
        -- cl_battle_player_panel.lua）。须置于上方 ResetBattleState 之后（该处清空）
        KARDS.PlayerPanelData = { enemyName = enemyName, enemySteamID64 = enemySteamID64 }
        local ply = LocalPlayer()
        -- 起始关键帧：位置 = 宽边 +x 侧外部（镜像默认进入相机位置；位置对双方相同，
        -- 视角差异由目标相机 yaw 区分，见下方 deckAng）
        local introPos = ent:LocalToWorld(Vector(70, 0, 30))
        -- 起始关键帧：朝向 = 面向牌桌中心（+ 上抬 30° 更平视，同默认进入相机）叠加三向旋转
        local baseAng = (ent:GetPos() - introPos):Angle()
        baseAng.pitch = baseAng.pitch - 30
        local introAng = Angle(baseAng.pitch + 45, baseAng.yaw + 45, baseAng.roll - 90)
        -- 目标关键帧：正上方俯视；yaw（xy 平面旋转角）按槽位区分——P2 视角 yaw=90
        -- （组卡模式相机，组卡仅 P2 进入），P1 视角与之相差 180°（yaw=270），
        -- 使双方画面"上"方向朝向各自玩家（P1 +y / P2 -y）
        local deckPos = ent:LocalToWorld(Vector(0, 0, 60))
        local deckYaw = (KARDS.BattleState.inTable.slot == 1) and 270 or 90
        local deckAng = ent:LocalToWorldAngles(Angle(90, deckYaw, 0))
        KARDS.BattleCamera:SetView(ply, deckPos, deckAng, 75, 2, introPos, introAng)
    else
        -- 观战者（未进入该牌桌）：该场对局开始 → 本地直接触发总部对局开始动画
        --（无 KARDS.BattleState.reveal 序列/无本方头像；mySlot=nil 时直接翻转落位
        -- 支援阵线，观战视角下 P1 总部朝 P1、P2 总部朝 P2，见 StartHQReveal/FacingYaw）
        -- 观战重新调度进度追踪（2026-08-12，KardsSpectateMulliganHUD）：
        -- spectate.mulliganDone 由 KardsMulliganDone 广播写入，mulliganStarted 由首个
        -- 重新调度发牌广播置位（KardsTableDeckDraw）
        -- 2026-09-13 规划 S2：服务端把开局广播发给全部非本槽玩家（含在其他牌桌参战
        -- 者）。本客户端若已在他桌参战，只播总部开始的世界动画，不得覆盖 spectate
        -- 单例，否则他桌事件会被误判为关注桌事件写入本地状态
        if not KARDS.BattleState.inTable then
            KARDS.BattleState.spectate = { ent = ent, mulliganDone = {} }
            KARDS.BattleState.mulliganStarted = false
        end
        StartHQReveal(ent, nil)
    end
end)

-- ====================================================================
-- 先手揭晓 UI（摄像头动画结束后，双方玩家 UI 上展示）
-- 时间轴（自摄像头动画结束起，2026-10-24 重排为四段：头像动画 → 总部出场 →
-- 先手揭示 → 总部下场）：
--   0~0.5    左侧本方头像淡入 + 从极大体积（3x）缩小到正常；右侧敌方头像同时动画
--            （敌方缺失 → 白色矩形兜底）
--   0.5~1.0  每个头像下方玩家名淡入（敌方缺失 → “暂无对手”）
--   1.0~1.7  双方总部出场：卡组槽顶 → 各自主角头像中点（翻面 + 45° 倾斜，z = 中槽
--            高度），见 StartHQReveal（参战者分支）
--   1.8      随机先手（服务端随机）：先手方头像+名称 0.4s 回弹曲线放大一部分；
--            其名称下方 0.5s 淡入黄色“先手”；同时先手方总部 z 上升
--            REVEAL_HQ_RISE_LIFT（0.4s）
--   2.6~3.75 双方总部依次下场（先手方先下场，另一方延迟 REVEAL_HQ_OUT_STAGGER）
--            滑向本方支援阵线第 3 槽落位
--   4.1~4.6  下场全部落位后停留 REVEAL_HOLD，随后所有元素整体淡出（REVEAL_FADE）
-- 头像用 GMod 引擎内置 AvatarImage VGUI 控件：SetPlayer 自动经 Steamworks 拿
-- SteamID64、从 Steam CDN 异步下载对应分辨率头像（期间显示默认占位头像）；
-- 淡入淡出/缩放由每帧 SetAlpha（0~255）+ SetSize/SetPos 驱动。
-- ====================================================================

local REVEAL_AVATAR_SIZE = 256      -- 头像正常边长（px，放大为原 128 的两倍）
local REVEAL_AVATAR_MAX_SCALE = 3   -- 入场起始“极大体积”倍率
local REVEAL_AVATAR_CX_LEFT = 0.30  -- 头像中心 x（屏宽比例）：左 = 本方
local REVEAL_AVATAR_CX_RIGHT = 0.70 -- 头像中心 x（屏宽比例）：右 = 敌方
local REVEAL_AVATAR_CY = 0.50       -- 头像中心 y（屏高比例）
local REVEAL_INTRO = 0.5            -- 头像淡入 + 缩小时长
local REVEAL_NAME_DELAY = 0.5       -- 名称淡入延迟（头像入场完成后）
local REVEAL_NAME_DUR = 0.5         -- 名称淡入时长
local REVEAL_FIRST_DELAY = 1.8      -- 先手揭晓时刻（自序列开始；总部出场完成后）
local REVEAL_FIRST_BOUNCE = 0.4     -- 先手回弹放大时长
local REVEAL_FIRST_TEXT = 0.5       -- “先手”文字淡入时长

-- 总部对局开始动画时序（2026-10-24 用户规格重排：头像动画 → 双方总部出场 →
-- 先手揭示（先手方总部同时在揭示时 z 上升）→ 双方总部下场（先手方先下场））
local REVEAL_HQ_IN_START = 1.0      -- 总部出场起点（自序列开始；头像与玩家名淡入完成后）
local REVEAL_HQ_IN_DUR = 0.7        -- 出场时长（卡堆顶 → 头像中点，翻面 + 45° 倾斜）
local REVEAL_HQ_RISE_DUR = 0.4      -- 先手方总部 z 上升时长（与头像回弹同步）
local REVEAL_HQ_RISE_LIFT = 6       -- 先手方总部 z 上升量（世界单位）
local REVEAL_HQ_OUT_START = 2.6     -- 下场起点（自序列开始；先手揭晓完成后）
local REVEAL_HQ_OUT_STAGGER = 0.45  -- 后下场一方相对先下场一方的延迟（先手方先下场）
local REVEAL_HQ_OUT_DUR = 0.7       -- 下场时长（滑向支援阵线第 3 槽落位）
local REVEAL_HQ_OBS_LIFT = 12       -- 观战者分支出场抬升量（无头像中点环节，直接抬高后落位）
local REVEAL_HOLD = 0.35            -- 下场全部落位后的停留时长
local REVEAL_FADE = 0.5             -- 整体淡出时长
-- 淡出起点（下场全部落位 + 停留）与序列结束时刻（供 Think 结束判定与绘制淡出共用）
local REVEAL_FADE_AT = REVEAL_HQ_OUT_START + REVEAL_HQ_OUT_STAGGER + REVEAL_HQ_OUT_DUR + REVEAL_HOLD
local REVEAL_END = REVEAL_FADE_AT + REVEAL_FADE

local function RevealEaseInOut(t)
    return t * t * (3 - 2 * t)
end

-- 先快后慢（easeOutCubic）
local function RevealEaseOut(t)
    return 1 - (1 - t) * (1 - t) * (1 - t)
end

-- 回弹曲线（easeOutBack：先过冲再回落到目标）
local function RevealEaseOutBack(t)
    local c1 = 1.70158
    local c3 = c1 + 1
    t = t - 1
    return 1 + c3 * t * t * t + c1 * t * t
end

-- 先手回弹放大倍率（2026-10-24 用户规格「总部与头像看起来是整体缩放」）：
-- 头像自揭晓时刻起以 easeOutBack 放大到 1.25（过冲后回落到 1.25 并保持）。
-- 本函数为头像放大与总部 z 抬升共用的唯一曲线源——总部抬升量由该倍率反算
--（见 StartHQReveal），两者同时刻同曲线，视觉上合为一个整体缩放。
-- @param t number 序列时间（秒，自摄像头动画结束起）
-- @return number 放大倍率（揭晓前恒 1）
local function RevealBounceScale(t)
    if t < REVEAL_FIRST_DELAY then return 1 end
    return 1 + 0.25 * RevealEaseOutBack(math.Clamp((t - REVEAL_FIRST_DELAY) / REVEAL_FIRST_BOUNCE, 0, 1))
end

-- 摄像头动画结束后启动先手揭晓序列（由 Think 钩子 KardsFirstTurnRevealStart 触发）
-- （头像面板由文件顶部公共函数 MakeAvatarPanel 创建）
local function StartReveal()
    local data = pendingReveal
    pendingReveal = nil
    if not data then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    -- 敌方玩家实体（按 SteamID64 查找；已离开 → nil → 右侧白色矩形 + “暂无对手”）
    local enemyPly = nil
    if data.enemySteamID64 and data.enemySteamID64 ~= "" then
        enemyPly = player.GetBySteamID64(data.enemySteamID64)
    end
    local hasEnemy = IsValid(enemyPly)
    KARDS.BattleState.reveal = {
        start = CurTime(),
        firstSlot = data.firstSlot,
        enemyName = hasEnemy and enemyPly:Nick() or T("battle.no_opponent"),
        hasEnemy = hasEnemy,
        leftAvatar = MakeAvatarPanel(ply, REVEAL_AVATAR_SIZE),
        rightAvatar = hasEnemy and MakeAvatarPanel(enemyPly, REVEAL_AVATAR_SIZE) or nil, -- 敌方缺失 → 白色矩形兜底
    }
end

-- 更新头像面板：按中心点 (cx,cy) 与缩放倍率设置尺寸/位置，并设整体透明度。
-- 末行 MoveToFront 保证头像始终绘制在其它 VGUI 面板之上（2026-10-26 用户规格；
-- 本函数在揭晓绘制钩子中每帧调用，正是需要持续置顶的窗口期）
local function UpdateAvatarPanel(panel, cx, cy, scale, alpha)
    if not IsValid(panel) then return end
    local s = REVEAL_AVATAR_SIZE * scale
    panel:SetSize(s, s)
    panel:SetPos(cx - s / 2, cy - s / 2)
    panel:SetAlpha(math.Clamp(math.Round(alpha), 0, 255))
    panel:MoveToFront()
end

-- 名称文字：居中于头像下方（随当前头像缩放浮动）。先手回弹放大时，因 GMod surface 无
-- SetTextScale，按 48 基准 × scale 映射到最近已注册字号档位（SourceHan_Heavy 在 40~72
-- 区间为 4px 步进注册：48/52/56/60/64/68/72，见 Oak_world_Library sh_fonts.lua）
local function DrawRevealName(text, cx, cy, scale, alpha)
    if alpha <= 0 or text == "" then return end
    local y = cy + REVEAL_AVATAR_SIZE * scale / 2 + 44 -- 名字中心：头像底边下方 44px
    local size = math.Clamp(48 + 4 * math.Round((48 * scale - 48) / 4), 48, 72)
    draw.SimpleText(text, ("SourceHan_Heavy_%d"):format(size), cx, y,
        Color(255, 255, 255, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- 每帧：HUD 可见性同步 + 序列结束清理 + 摄像头动画结束后启动揭晓序列。
-- HUD 隐藏（cl_drawhud 0）时 HUDPaint 不执行、vgui 面板仍会绘制，故在此处按
-- cl_drawhud 同步隐藏头像面板；序列结束也在此统一清理（同样不受 HUD 隐藏影响）
-- 总部对局开始动画入口（文件尾部 KardsHQReveal* 段定义；前向声明供本钩子调用）
local StartHQReveal = nil
hook.Add("Think", "KardsFirstTurnRevealStart", function()
    if KARDS.BattleState.reveal then
        local hudCvar = GetConVar("cl_drawhud")
        local hudOn = hudCvar and hudCvar:GetBool() or true
        local t = CurTime() - KARDS.BattleState.reveal.start
        -- 开场动画音效（2026-08-10，sound/kards/）：头像渐变完成（REVEAL_INTRO）/
        -- 确定先手（REVEAL_FIRST_DELAY，先手回弹放大 + “先手”文字出现）各播一次
        if not KARDS.BattleState.reveal.avatarSnd and t >= REVEAL_INTRO then
            KARDS.BattleState.reveal.avatarSnd = true
            KARDS.PlayKardsSound("avatar_done") -- 头像渐变完成音效（头像淡入完成）
        end
        if not KARDS.BattleState.reveal.firstSnd and t >= REVEAL_FIRST_DELAY then
            KARDS.BattleState.reveal.firstSnd = true
            KARDS.PlayKardsSound("first_turn") -- 确定先手音效（回弹放大 + “先手”文字）
        end
        -- 总部对局开始动画：头像与玩家名淡入完成后（REVEAL_HQ_IN_START）启动出场
        --（每场对局一次，先于先手揭晓；此时相机仍为揭晓期间固定俯视，
        --  StartHQReveal 取视线与中心槽高度平面交点有效，见 StartHQReveal）
        if not hqRevealStarted and t >= REVEAL_HQ_IN_START then
            hqRevealStarted = true
            KARDS.PlayKardsSound("hq_start") -- 总部卡动画开始音效（总部离堆上场前）
            if KARDS.BattleState.inTable then StartHQReveal(KARDS.BattleState.inTable.ent, KARDS.BattleState.inTable.slot) end
        end
        if t >= REVEAL_END then
            -- 序列结束：清理面板与状态（总部动画已在头像与玩家名淡入完成后提前启动，
            -- 见上方分支，不再在此触发）
            ClearRevealPanels()
            KARDS.BattleState.reveal = nil
            -- 先手揭晓结束 → 角落玩家头像面板入场（头像淡入 + 玩家名向右滑动淡入，
            -- 2026-10-10，见 cl_battle_player_panel.lua）
            if KARDS.PlayerPanelIntro then KARDS.PlayerPanelIntro() end
            -- 先手揭晓序列结束 → 本方重新调度就绪（每场对局一次；服务端
            -- OnMulliganReady 据此发牌，本方走牌桌中间扇形选择）
            if KARDS.BattleState.inTable and not KARDS.BattleState.mulliganReadySent then
                KARDS.BattleState.mulliganReadySent = true
                net.Start("KardsMulliganReady")
                    net.WriteEntity(KARDS.BattleState.inTable.ent)
                net.SendToServer()
            end
        elseif not hudOn then
            if IsValid(KARDS.BattleState.reveal.leftAvatar) then KARDS.BattleState.reveal.leftAvatar:SetVisible(false) end
            if IsValid(KARDS.BattleState.reveal.rightAvatar) then KARDS.BattleState.reveal.rightAvatar:SetVisible(false) end
        end
    end
    if KARDS.BattleState.reveal or not pendingReveal or not KARDS.BattleState.battleStarted then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local cam = KARDS.BattleCamera and KARDS.BattleCamera.Cameras[ply]
    if cam and cam.active and KARDS.AnimPlayer:Get(cam) then return end -- 相机进入动画仍在进行（re.md 重构：AnimPlayer 播放中）
    StartReveal()
end)

-- 先手揭晓 UI 绘制：头像面板（+白色矩形兜底）+ 玩家名 + “先手”文字
hook.Add("HUDPaint", "KardsFirstTurnRevealPaint", function()
    if not KARDS.BattleState.reveal then return end
    -- HUD 隐藏时 Think 钩子已隐藏面板；此处重新显示并逐帧更新动画状态
    if IsValid(KARDS.BattleState.reveal.leftAvatar) then KARDS.BattleState.reveal.leftAvatar:SetVisible(true) end
    if IsValid(KARDS.BattleState.reveal.rightAvatar) then KARDS.BattleState.reveal.rightAvatar:SetVisible(true) end

    local t = CurTime() - KARDS.BattleState.reveal.start
    local intro = math.Clamp(t / REVEAL_INTRO, 0, 1)
    local iEase = RevealEaseInOut(intro)
    local avatarAlpha = 255 * iEase                                          -- 0.5s 内淡入
    local baseScale = REVEAL_AVATAR_MAX_SCALE + (1 - REVEAL_AVATAR_MAX_SCALE) * iEase -- 3x → 1x
    local nameAlpha = 255 * RevealEaseInOut(math.Clamp((t - REVEAL_NAME_DELAY) / REVEAL_NAME_DUR, 0, 1))
    -- 先手回弹放大（揭晓时刻起 0.4s easeOutBack → 1.25）：曲线与总部 z 抬升共用
    -- RevealBounceScale（2026-10-24 用户规格「总部与头像看起来是整体缩放」）
    local bounce = RevealBounceScale(t)
    -- 下场全部落位 + 停留后整体淡出（REVEAL_FADE_AT 为淡出起点）
    local fadeMul = 1 - RevealEaseInOut(math.Clamp((t - REVEAL_FADE_AT) / REVEAL_FADE, 0, 1))
    avatarAlpha = avatarAlpha * fadeMul
    nameAlpha = nameAlpha * fadeMul
    local firstAlpha = 255 * RevealEaseInOut(math.Clamp((t - REVEAL_FIRST_DELAY) / REVEAL_FIRST_TEXT, 0, 1)) * fadeMul

    local ply = LocalPlayer()
    local meFirst = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == KARDS.BattleState.reveal.firstSlot or false
    -- 头像中心：屏幕 y 一半，水平向屏幕中心收拢（原 0.24/0.76 → 0.30/0.70）；
    -- 常量与 StartHQReveal 的总部出场终点共用（总部质心落在头像中点）
    local lx, ly = ScrW() * REVEAL_AVATAR_CX_LEFT, ScrH() * REVEAL_AVATAR_CY -- 左侧（本方）
    local rx, ry = ScrW() * REVEAL_AVATAR_CX_RIGHT, ScrH() * REVEAL_AVATAR_CY -- 右侧（敌方）

    -- 头像：左侧本方 + 右侧敌方（缺失 → 白色矩形，同时动画）
    local leftScale = baseScale * (meFirst and bounce or 1)
    local rightScale = baseScale * ((not meFirst) and bounce or 1)
    UpdateAvatarPanel(KARDS.BattleState.reveal.leftAvatar, lx, ly, leftScale, avatarAlpha)
    if KARDS.BattleState.reveal.rightAvatar then
        UpdateAvatarPanel(KARDS.BattleState.reveal.rightAvatar, rx, ry, rightScale, avatarAlpha)
    else
        local s = REVEAL_AVATAR_SIZE * rightScale
        draw.RoundedBox(0, rx - s / 2, ry - s / 2, s, s, Color(255, 255, 255, avatarAlpha))
    end

    -- 玩家名：头像下方淡入
    DrawRevealName(IsValid(ply) and ply:Nick() or "", lx, ly, leftScale, nameAlpha)
    DrawRevealName(KARDS.BattleState.reveal.enemyName, rx, ry, rightScale, nameAlpha)

    -- 先手：先手方名称下方黄色“先手”淡入（字号随头像放大为 56；y = 名字中心下方 56px，
    -- 即 cy + fs/2 + 44 + 56）
    if t >= REVEAL_FIRST_DELAY and firstAlpha > 0 then
        local fx, fy = meFirst and lx or rx, meFirst and ly or ry
        local fs = REVEAL_AVATAR_SIZE * (meFirst and leftScale or rightScale)
        draw.SimpleText(T("battle.first_turn"), "SourceHan_Heavy_56", fx, fy + fs / 2 + 100,
            Color(255, 220, 80, firstAlpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end)

-- 每帧：进入牌桌常驻头像更新（右外侧 ↔ 右上角 先快后慢滑动 + 对局开始后淡出 +
-- HUD 隐藏（cl_drawhud 0）时同步隐藏面板——vgui 面板不受 cl_drawhud 影响仍会绘制）
hook.Add("Think", "KardsTableEnterAvatarUpdate", function()
    if not enterAvatar then return end
    local panel = enterAvatar.panel
    if not IsValid(panel) then
        enterAvatar = nil
        return
    end
    -- 滑动动画：先快后慢（easeOutCubic）沿 slideFromX → slideToX
    local slideT = (CurTime() - enterAvatar.slideStart) / ENTER_AVATAR_SLIDE_DUR
    if slideT >= 1 then
        -- 滑动结束：定格终点
        enterAvatar.curX = enterAvatar.slideToX
        if enterAvatar.exiting then
            ClearEnterAvatar() -- 反向滑出完成（退出牌桌场景）→ 移除面板
            return
        end
    else
        enterAvatar.curX = enterAvatar.slideFromX
            + (enterAvatar.slideToX - enterAvatar.slideFromX) * RevealEaseOut(slideT)
    end
    panel:SetPos(enterAvatar.curX, 40) -- 右上角（分辨率自适应）
    panel:MoveToFront() -- 头像始终在最上层（2026-10-26 用户规格，见 MakeAvatarPanel）
    local hudCvar = GetConVar("cl_drawhud")
    local hudOn = hudCvar and hudCvar:GetBool() or true
    if not hudOn then
        panel:SetVisible(false)
        return
    end
    panel:SetVisible(true)
    -- 对局开始后淡出（0.5s smoothstep）
    if enterAvatar.fadeStart then
        local ft = (CurTime() - enterAvatar.fadeStart) / ENTER_AVATAR_FADE_DUR
        if ft >= 1 then
            ClearEnterAvatar()
            return
        end
        panel:SetAlpha(math.Round(255 * (1 - RevealEaseInOut(ft))))
    else
        panel:SetAlpha(255)
    end
end)

-- ====================================================================
-- 组卡模式（deck）：牌桌宽面 kards_enter 切换；准星浏览铺在桌面上的卡牌
-- ====================================================================

-- 模式切换广播：提示当前模式（模式本身经 NW 变量 Kards_Mode 同步，供宽面提示/浏览判定）
net.Receive("KardsTableModeChanged", function()
    local ent = net.ReadEntity()
    local mode = net.ReadString()
    if IsValid(ent) then
        local modeText = (mode == "deck") and T("battle.mode.changed_deck") or T("battle.mode.changed_battle")
        Flash(modeText)
        -- 初始化卡顿加载提示：切组卡 → 检测「正在初始化卡组」（铺 5×3 网格卡实体）；
        -- 切回对战 → 若已在牌桌内则恢复「正在初始化战场」检测，否则停止
        if mode == "deck" then
            StartInitLoading(T("battle.loading.deck"))
        elseif KARDS.BattleState.inTable then
            StartInitLoading(T("battle.loading.battle"))
        else
            StopInitLoading()
        end
    end
end)

-- 当前准星浏览的组卡卡牌实体（组卡模式下准星落点 HitPos 最近距离判定选中）
local aimDeckCard = nil
hook.Add("Think", "KardsDeckCardAim", function()
    aimDeckCard = nil
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    if gui.IsConsoleVisible() or gui.IsGameUIVisible() then return end
    -- 玩家须位于组卡模式（Kards_Mode == "deck"）牌桌宽面
    local inDeckArea = false
    for _, ent in ipairs(ents.FindByClass("sent_kards_battle_table")) do
        if IsValid(ent) and ent:IsAtWideSide(ply) and ent:GetNWString("Kards_Mode", "battle") == "deck" then
            inDeckArea = true
            break
        end
    end
    if not inDeckArea then return end
    -- 组卡卡牌 SOLID_NONE 无碰撞，射线不会命中实体——用射线落点 HitPos 的最近距离判定
    local tr = ply:GetEyeTrace()
    if not tr.HitPos then return end
    -- 中心距离阈值统一由 KARDS.HitTest.Radii 提供（22^2：卡牌半宽 3.6 / 半长 5.4，视野内 22 单位容差）
    local best, bestD = nil, KARDS.HitTest.Radii.CardPick
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        -- 翻面卡不参与浏览（卡面朝下，不展示卡头信息面板）
        if IsValid(ent) and ent:GetNWString("Kards_CardRole", "") == "deck"
        and not ent:GetNWBool("Kards_GridFlipped", false) then
            local d = ent:GetPos():DistToSqr(tr.HitPos)
            if d < bestD then
                best, bestD = ent, d
            end
        end
    end
    aimDeckCard = best
end)

-- 组卡构建：左键点击 5×3 网格非总部卡 → 复制加入卡组；点击卡组堆叠卡 → 移回销毁（瞬时）
-- 仅 P1（槽位 1）进入牌桌后生效；相机被 CalcView 接管，点击射线取 BattleCamera 当前视图
local prevDeckLeft = false
hook.Add("Think", "KardsDeckCardClick", function()
    local ply = LocalPlayer()
    local down = IsValid(ply) and input.IsMouseDown(MOUSE_LEFT) or false
    local clicked = down and not prevDeckLeft
    prevDeckLeft = down
    if not clicked or not IsValid(ply) or not KARDS.BattleState.inTable then return end
    if KARDS.BattleState.inTable.slot ~= 2 then return end -- 仅 P2（槽位 2）可构建卡组
    if KARDS.BattleState.inTable.ent:GetNWString("Kards_Mode", "battle") ~= "deck" then return end
    if gui.IsConsoleVisible() or gui.IsGameUIVisible() then return end
    -- 相机射线：统一走抗视差实现（KARDS.HitTest.MouseRay）
    local pos, dir = KARDS.HitTest.MouseRay()
    if not pos then return end
    -- 组卡卡牌筛选：非总部卡的卡面角色（总部卡不参与组卡点击，仅展示）
    local DeckCardFilter = KARDS.HitTest.All(
        KARDS.HitTest.Filters.Valid,
        KARDS.HitTest.Filters.Role("deck"),
        KARDS.HitTest.Filters.NotHQ)
    local list = ents.FindByClass("sent_pmx_static_imported")
    -- 阈值 22^2（卡牌半宽 3.6 / 半长 5.4，视野内 22 单位容差）
    local best, bestD = KARDS.HitTest.NearestInRay(pos, dir, list,
        KARDS.HitTest.Radii.CardPick,
        KARDS.HitTest.All(DeckCardFilter, KARDS.HitTest.Filters.NotFlipped))
    -- 已翻面（达携带上限）：记入阻挡，射线最近的是它时整次点击无效果，不选任何卡
    local flippedEnt, flippedD = KARDS.HitTest.NearestInRay(pos, dir, list,
        KARDS.HitTest.Radii.CardPick,
        KARDS.HitTest.All(DeckCardFilter, KARDS.HitTest.Filters.IsFlipped))
    if flippedEnt and (not IsValid(best) or flippedD <= bestD) then
        best = nil
    end
    -- "保存"按钮（原总部槽位置）：作为点击目标与卡牌竞争最近距离（阈值 15^2：
    -- 按钮文字约 2×1 单位，避免靠近的卡组堆叠/网格卡被误判为保存）
    local savePos = KARDS.BattleState.inTable.ent:LocalToWorld(Vector(24.68, -12.80, 18.43))
    local _, saveD = KARDS.HitTest.NearestInRay(pos, dir, { savePos }, KARDS.HitTest.Radii.Button)
    -- 最近目标优先：卡牌更近 → 卡牌操作；否则命中保存按钮（仅 P2）→ 弹输入框
    if IsValid(best) and saveD and bestD <= saveD then
        net.Start("KardsDeckCardClick")
            net.WriteEntity(best)
        net.SendToServer()
    elseif KARDS.BattleState.inTable.slot == 2 and saveD then
        ShowDeckNameDialog()
    end
end)

-- 服务端通知：堆叠卡被移出销毁（常规移出）→ 立即移除其 3D2D 文字，避免淡出期间文字残留。
-- 计数阶段移出（实体保留）不通知，文字与 ×N 计数保留并更新
net.Receive("KardsPileCardRemoved", function()
    local ent = net.ReadEntity()
    if IsValid(ent) and KARDS.CardTextOverlay then
        KARDS.CardTextOverlay:Remove(ent)
    end
end)

-- 组卡保存输入框对话框（可取消：取消/右上角 X/ESC 关闭且不保存；输入名点"保存"才提交）
-- saveDialogOpen 防重复弹出（对话框打开期间忽略保存按钮点击）
-- 注意：定义为全局函数（点击钩子 KardsDeckCardClick 在文件更早处注册，local 前向引用不可见）
local saveDialogOpen = false
function ShowDeckNameDialog()
    if saveDialogOpen then return end
    saveDialogOpen = true
    local frame = vgui.Create("DFrame")
    frame:SetSize(320, 150)
    frame:Center()
    frame:SetTitle(T("deck.save.title"))
    frame:SetDraggable(true)
    frame:ShowCloseButton(true) -- 右上角 X = 取消
    function frame:OnClose()
        saveDialogOpen = false
    end
    function frame:OnKeyCodePressed(key)
        if key == KEY_ESCAPE then -- ESC = 取消
            self:Close()
        end
    end
    local entry = vgui.Create("DTextEntry", frame)
    entry:SetPos(16, 40)
    entry:SetSize(288, 28)
    entry:SetPlaceholderText(T("deck.save.placeholder"))
    entry:RequestFocus()
    -- 回车 = 保存
    function entry:OnEnter()
        okBtn:DoClick()
    end
    local okBtn = vgui.Create("DButton", frame)
    okBtn:SetText(T("common.save"))
    okBtn:SetPos(16, 88)
    okBtn:SetSize(140, 36)
    okBtn.DoClick = function()
        local text = entry:GetValue():gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then
            Flash(T("deck.save.empty"))
            return
        end
        net.Start("KardsDeckSave")
            net.WriteString(text)
        net.SendToServer()
        frame:Close()
    end
    local cancelBtn = vgui.Create("DButton", frame)
    cancelBtn:SetText(T("common.cancel"))
    cancelBtn:SetPos(164, 88)
    cancelBtn:SetSize(140, 36)
    cancelBtn.DoClick = function()
        frame:Close() -- 取消不保存
    end
    frame:MakePopup()
end

-- 组卡模式"保存"按钮（原总部槽位置）：3D2D 描边文字（点击输入卡组名保存）。
-- 布局（上→下）：当前卡牌：N（实时统计组卡模式网格卡数量，不含总部）→ 空行 →
-- 保存（主文字）→ 底部小字"点击保存（40张）"。
-- 位置 = 牌桌相对坐标 DeckSavePos（与服务端 ENT.DeckSavePos 同步）
hook.Add("PostDrawOpaqueRenderables", "KardsDeckSaveButton", function()
    if not KARDS.BattleState.inTable then return end
    if KARDS.BattleState.inTable.ent:GetNWString("Kards_Mode", "battle") ~= "deck" then return end
    local ent = KARDS.BattleState.inTable.ent
    -- 当前卡牌数量：组卡模式网格卡（Kards_CardRole="deck" 且非总部，实时统计）
    local cardCount = 0
    for _, c in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(c) and c:GetNWString("Kards_CardRole", "") == "deck"
            and c:GetNWString("Kards_DeckRole", "grid") ~= "hq" then
            cardCount = cardCount + 1
        end
    end
    local pos = ent:LocalToWorld(Vector(24.68, -12.80, 18.43))
    -- 3D2D 平面：x 沿牌桌 forward、y 沿牌桌 right（与卡牌 3D2D 文字同构），
    -- 沿法线（牌桌 up）悬浮偏移避免与桌面 Z-fighting
    local dx = ent:GetForward()
    local dy = ent:GetRight()
    local camAng = dx:AngleEx(dx:Cross(-dy))
    cam.Start3D2D(pos + ent:GetUp() * 0.08, camAng, 0.02)
        -- 顶部：当前卡牌数量（黑色描边（四向偏移）+ 白色填充；位于"保存"上方留空行）
        local countText = T("deck.save.current_cards", cardCount)
        for _, off in ipairs({ { -2, 0 }, { 2, 0 }, { 0, -2 }, { 0, 2 } }) do
            draw.DrawText(countText, "SourceHan_Heavy_28", off[1], -56 + off[2],
                Color(0, 0, 0, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        draw.DrawText(countText, "SourceHan_Heavy_28", 0, -56,
            Color(255, 255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        -- 主文字"保存"（黑色描边（四向偏移）+ 白色填充）
        for _, off in ipairs({ { -2, 0 }, { 2, 0 }, { 0, -2 }, { 0, 2 } }) do
            draw.DrawText(T("common.save"), "SourceHan_Heavy_48", off[1], off[2],
                Color(0, 0, 0, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        draw.DrawText(T("common.save"), "SourceHan_Heavy_48", 0, 0,
            Color(255, 255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        -- 底部小字提示：点击保存卡组（40 张）
        draw.DrawText(T("deck.save.hint"), "SourceHan_Heavy_24", 0, 40,
            Color(255, 220, 80, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    cam.End3D2D()
end)

-- 组卡卡组堆叠：抗视差（仅组卡构建者）+ 保存成功两段动画（见文件头）
include("cl_deck_pile.lua")

-- 组卡搜索输入广播接收（2026-09-05）：所有客户端实时更新 3D2D 输入框文字
local deckSearchText = "" -- 本地映射的搜索文本
net.Receive("KardsDeckSearchInputBC", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "sent_kards_battle_table" then return end
    local text = net.ReadString()
    deckSearchText = text
    if KARDS.Input3D2D then
        KARDS.Input3D2D:SetText(ent.TableID, text)
    end
end)

-- 3D2D 搜索输入框渲染（2026-09-05）：卡组堆叠上方半透明矩形
hook.Add("PostDrawOpaqueRenderables", "KardsDeckSearchInput", function()
    if not KARDS.BattleState.inTable then return end
    if KARDS.BattleState.inTable.ent:GetNWString("Kards_Mode", "battle") ~= "deck" then return end
    local ent = KARDS.BattleState.inTable.ent
    local tid = ent.TableID
    local inst = KARDS.Input3D2D and KARDS.Input3D2D.Instances[tid]
    if not inst or not inst.active then return end
    local pos = ent:LocalToWorld(inst.pos)
    local dx = ent:GetForward()
    local dy = ent:GetRight()
    local camAng = dx:AngleEx(dx:Cross(-dy))
    local halfW, halfH = inst.width / 2, inst.height / 2
    cam.Start3D2D(pos + ent:GetUp() * 0.08, camAng, inst.scale)
        -- 背景（半透明黑）
        surface.SetDrawColor(0, 0, 0, 180)
        surface.DrawRect(-halfW, -halfH, inst.width, inst.height)
        -- 边框（亮白）
        surface.SetDrawColor(220, 220, 220, 255)
        surface.DrawOutlinedRect(-halfW, -halfH, inst.width, inst.height)
        -- 文字
        local displayText = inst.text
        if displayText == "" then
            displayText = inst.placeholder
            draw.DrawText(displayText, "SourceHan_Heavy_24", 0, 0,
                Color(120, 120, 120, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        else
            draw.DrawText(displayText, "SourceHan_Heavy_24", 0, 0,
                Color(255, 255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    cam.End3D2D()
end)

-- 组卡搜索输入框 DTextEntry（2026-09-05）：在 3D2D 输入框投影屏幕位置创建 DTextEntry
local searchInputDialogOpen = false
local function ShowDeckSearchDialog()
    if searchInputDialogOpen then return end
    searchInputDialogOpen = true
    local ent = KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent
    if not IsValid(ent) then return end
    local tid = ent.TableID
    local inst = KARDS.Input3D2D and KARDS.Input3D2D.Instances[tid]
    if not inst then return end
    -- 计算 3D2D 输入框的世界坐标，投影到屏幕
    local worldPos = ent:LocalToWorld(inst.pos) + ent:GetUp() * 0.08
    local screenPos = worldPos:ToScreen()
    local sx, sy = screenPos.x, screenPos.y
    local w, h = 160, 28
    local frame = vgui.Create("DFrame")
    frame:SetSize(200, 60)
    frame:SetPos(sx - 100, sy - 30)
    frame:SetTitle("")
    frame:SetDraggable(false)
    frame:ShowCloseButton(false)
    frame:SetAlpha(0) -- 完全透明（只显示 DTextEntry）
    function frame:OnClose()
        searchInputDialogOpen = false
    end
    function frame:OnKeyCodePressed(key)
        if key == KEY_ESCAPE then
            self:Close()
        end
    end
    -- 移除标题栏（Panel 默认无标题栏，仅 DFrame 有，覆写 Paint 隐藏）
    frame.Paint = function() end
    local entry = vgui.Create("DTextEntry", frame)
    entry:SetPos(20, 16)
    entry:SetSize(w, h)
    entry:SetPlaceholderText(T("deck.search.placeholder"))
    entry:SetText(inst.text)
    entry:RequestFocus()
    function entry:OnEnter()
        net.Start("KardsDeckSearchInput")
            net.WriteString(self:GetValue())
        net.SendToServer()
        frame:Close()
    end
    function entry:OnValueChange(val)
        if #val > 6 then
            self:SetText(val:sub(1, 6))
            return
        end
        net.Start("KardsDeckSearchInput")
            net.WriteString(val)
        net.SendToServer()
    end
    frame:MakePopup()
end

-- 修改现有 KardsDeckCardClick 钩子：在保存按钮判定后追加搜索输入框点击判定
-- 在确认不是保存按钮点击后，新增输入框命中检测。hook 定义在 line 1409，通过 Think 方式
-- 注册，需要修改原 hook 逻辑。由于 hook 是追加方式，新增一个 Think 钩子专门处理输入框
-- 点击即可（独立于原卡牌+保存点击检测，避免干扰原逻辑）。
local prevDeckSearchLeft = false
hook.Add("Think", "KardsDeckSearchClick", function()
    local ply = LocalPlayer()
    local down = IsValid(ply) and input.IsMouseDown(MOUSE_LEFT) or false
    local clicked = down and not prevDeckSearchLeft
    prevDeckSearchLeft = down
    if not clicked or not IsValid(ply) or not KARDS.BattleState.inTable then return end
    if KARDS.BattleState.inTable.slot ~= 2 then return end -- 仅 P2（构建者）可输入
    if KARDS.BattleState.inTable.ent:GetNWString("Kards_Mode", "battle") ~= "deck" then return end
    if gui.IsConsoleVisible() or gui.IsGameUIVisible() then return end
    local ent = KARDS.BattleState.inTable.ent
    local tid = ent.TableID
    local inst = KARDS.Input3D2D and KARDS.Input3D2D.Instances[tid]
    if not inst or not inst.active then return end
    -- 射线检测：投影到输入框世界位置（统一走抗视差射线与命中阈值）
    local pos, dir = KARDS.HitTest.MouseRay()
    if not pos then return end
    local worldPos = ent:LocalToWorld(inst.pos) + ent:GetUp() * 0.08
    -- 输入框世界尺寸：半宽 ≈ 7.2（180像素 × 0.02缩放 × 2），半长 ≈ 1.6（取决于朝向）
    -- 阈值 15^2（与保存按钮容差一致）
    if KARDS.HitTest.NearestInRay(pos, dir, { worldPos }, KARDS.HitTest.Radii.Button) then
        ShowDeckSearchDialog()
    end
end)

-- 组卡模式卡牌名称过滤（2026-09-05）：搜索文本非空时，隐藏不匹配的网格卡
local function UpdateDeckCardFilter()
    local searchText = deckSearchText or ""
    -- 搜索文本为空 → 显示所有网格卡
    if searchText == "" then
        for _, c in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
            if IsValid(c) and c:GetNWString("Kards_CardRole", "") == "deck"
                and c:GetNWString("Kards_DeckRole", "") == "grid" then
                if c:GetNoDraw() then c:SetNoDraw(false) end
            end
        end
        return
    end
    -- 搜索文本非空 → 按名称匹配过滤
    for _, c in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(c) and c:GetNWString("Kards_CardRole", "") == "deck"
            and c:GetNWString("Kards_DeckRole", "") == "grid" then
            local name = c:GetNWString("Kards_CardName", "")
            local nameEn = c:GetNWString("Kards_CardNameEn", "")
            local q = searchText:lower()
            local match = name:lower():find(q, 1, true) or (nameEn ~= "" and nameEn:lower():find(q, 1, true))
            c:SetNoDraw(not match)
        end
    end
end
-- 每帧执行过滤（搜索文本变化时实际生效，不变时 Check 几乎无开销）
hook.Add("Think", "KardsDeckCardFilter", function()
    if not KARDS.BattleState.inTable then return end
    if KARDS.BattleState.inTable.ent:GetNWString("Kards_Mode", "battle") ~= "deck" then return end
    UpdateDeckCardFilter()
end)

-- 右侧卡头浏览面板（组卡模式）：名称 / 费用 / 攻击 / 防御 / 词条（卡头=简单浏览）
hook.Add("HUDPaint", "KardsDeckCardView", function()
    if not aimDeckCard or not IsValid(aimDeckCard) then return end
    local ent = aimDeckCard
    local w, h = 240, 300
    local x, y = ScrW() - w - 30, (ScrH() - h) / 2
    draw.RoundedBox(8, x, y, w, h, Color(0, 0, 0, 200))
    -- 名称条（头部）
    draw.RoundedBox(8, x + 8, y + 8, w - 16, 44, Color(60, 60, 80, 230))
    draw.SimpleText(KARDS.CardEditor.Data.PickLocalized(ent:GetNWString("Kards_CardName", ""),
        ent:GetNWString("Kards_CardNameEn", "")), "SourceHan_Heavy_24",
        x + w / 2, y + 30, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 费用（左上；总部无费用，不显示）
    if not ent:GetNWBool("Kards_CardIsHeadquarter", false) then
        draw.SimpleText(tostring(ent:GetNWInt("Kards_CardCost", 0)), "SourceHan_Heavy_24",
            x + 24, y + 80, Color(120, 180, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(T("card.cost_short"), "SourceHan_Heavy_24",
            x + 24, y + 110, Color(160, 180, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    -- 攻击 / 防御（中下部）
    draw.SimpleText(tostring(ent:GetNWInt("Kards_CardAttack", 0)), "SourceHan_Heavy_24",
        x + 70, y + h - 60, Color(255, 120, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    draw.SimpleText(tostring(ent:GetNWInt("Kards_CardDefense", 0)), "SourceHan_Heavy_24",
        x + 170, y + h - 60, Color(120, 255, 160), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 词条文本（中下；NW 串为词条 id 列表，按本机语言重建）
    local kwStr = ent:GetNWString("Kards_CardKeywords", "")
    local kws = kwStr ~= "" and KARDS.CardEditor.Data.BuildKeywordsText(
        KARDS.CardEditor.Data.DeserializeKeywords(kwStr)) or ""
    if kws ~= "" then
        draw.SimpleText(kws, "SourceHan_Heavy_24",
            x + w / 2, y + h - 110, Color(255, 220, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end)

-- ====================================================================
-- 卡牌材质链路（2026-08-15 C1 拆分：组卡卡牌材质/文字初始化、国家卡背 PNG 缓存、
-- 卡牌纹理落盘、牌桌卡牌材质就绪统一驱动、卡堆档位模型卡背预置、手牌槽卡卡面预置
-- 已迁移至 cl_battle_material.lua）
include("cl_battle_material.lua")
-- ====================================================================


-- ====================================================================
-- 手牌槽卡可见性（组卡模式隐藏）：牌桌处于组卡模式（Kards_Mode == "deck"）时，
-- 三个视角（P1/P2/观战）均不渲染手牌（手牌槽卡占位，Kards_IsHandSlotCard）；
-- 切回对战模式恢复渲染。按父级牌桌判断（手牌槽卡经 RegisterChild 绑定牌桌，
-- 见 init.lua CreateHandCardSlots）。NoDraw 属渲染层，与本地视角无关，全局生效。
-- 幂等：NoDraw 状态一致时跳过（避免每帧重复调用）。
-- ====================================================================
hook.Add("Think", "KardsHandSlotVisibility", function()
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWBool("Kards_IsHandSlotCard", false) then
            local parent = ent:GetParent()
            local hide = IsValid(parent) and parent:GetNWString("Kards_Mode", "battle") == "deck"
            if ent:GetNoDraw() ~= hide then
                ent:SetNoDraw(hide)
            end
        end
    end
end)

-- ====================================================================
-- 卡组槽堆叠（battle 模式）：可见性控制 + 总部对局开始动画 + 抽牌动画
-- 性能优化方案（2026-08-09 起，见服务端 LoadPlayerBattleDeck）：卡组槽为「6 档厚度
-- 卡堆模型 + 1 张隐藏总部 + 抽牌临时实体」——
--   - 每槽预生成全部 6 档卡堆实体（同时仅一档可见），可见性由服务端 SetDeckPileTier
--     权威驱动（档位按剩余卡数 snapUp 向上取最近档），客户端本钩子不干预
--   - 总部实体初始隐藏（服务端 SetNoDraw(true)，堆叠厚度由档位模型表现）；对局开始
--     动画的「总部出场」段 StartHQReveal 显式 SetNoDraw(false) 并播放总部动画：
--     本方总部 → 左侧头像中点 / 敌方总部 → 右侧头像中点（终点质心与头像中点重合、
--     z = 中槽高度、yaw 相对面向基准 ±45°），先手方在揭晓时 z 上升且先下场，动画
--     结束落位本方支援阵线第 3 槽
--   - 抽牌：服务端生成一张临时卡实体（卡堆顶），客户端抽牌动画渲染卡面 + 翻面 →
--     移动到牌桌中间面向摄像头 → 停留 0.5s → 移到手牌最右侧，同时左侧手牌向左
--     移动部分；动画结束后卡留在手牌位
--   - 卡背统一 usa（测试版暂定，PrepareDeckPileFiles 改写档位模型 front 槽）
-- ====================================================================

-- 已被抽走（正在播放抽牌动画）的卡组槽卡（weak keys：实体移除自动清理）
local battleDeckDrawn = setmetatable({}, { __mode = "k" })
-- 已离开卡组槽的总部卡（weak keys）：总部对局开始动画启动后置位，
-- 可见性钩子据此不再把它计入堆叠顶层（下一张普通卡成为顶层）
local battleHQLeft = setmetatable({}, { __mode = "k" })

--[[
    卡组槽堆叠可见性（每帧）：仅兜底保证卡组槽卡（含抽牌临时卡）可见。卡堆档位
    实体（Kards_IsBattleDeckPile）的可见性由服务端 SetDeckPileTier 驱动、总部
    （Kards_DeckRole="hq"）的隐藏由服务端 SetNoDraw(true) 驱动（动画时 StartHQReveal
    显式 SetNoDraw(false)），均不在此处理——若此处对总部 SetNoDraw(false)，会把
    服务端隐藏的总部提前显示。被抽的卡（battleDeckDrawn）与已离开卡组槽的总部
    （battleHQLeft）不在此处设置：其显示/朝向由抽牌动画 / 总部对局开始动画驱动接管。
    注：早期方案曾把非顶层卡 SetNoDraw(true) 隐藏，导致卡组只剩顶层一张牌——
    逐张堆叠方案因此改为全部渲染模型；现卡堆为单实体档位模型，此问题已不存在。
    2026-08-15 阶段四 C4：本钩子已并入 KardsTableEntitiesThink（文件后部统一实体
    遍历，见 KardsFieldFacing / KardsHandSlotFacing 段）。
]]

--[[
    总部对局开始动画（2026-10-24 用户规格重排为四段：头像动画 → 双方总部出场 →
    先手揭示（先手方总部同时在揭示时 z 上升）→ 双方总部下场，先手方先下场）：
      参战者（KardsFirstTurnRevealStart 在 REVEAL_HQ_IN_START 触发）：双方总部卡从
      卡组槽顶经 REVEAL_HQ_IN_DUR 秒移到各自头像中点（本方 → 左侧头像，敌方 →
      右侧头像），期间卡背朝上翻转至卡面朝上；终点质心与头像中点重合（取头像中点
      屏幕点在该高度平面上的视线交点，其屏幕投影即头像中点）、z = 中槽高度
      （CenterSlotPos.z），yaw 相对面向基准旋转 45°（本方逆时针 / 敌方顺时针，屏幕
      观察方向）。先手方：自揭晓时刻起沿「相机 → 卡片」视线向相机靠近（与头像回弹
      同步），透视投影下 2D 尺寸随深度反比放大，即「相对于相机 2D 平面的放大」——
      全程只改位置，不改模型尺寸，不做空间缩放；相机垂直俯视时表现为 z 上升
      （x/y 同步向相机轴收拢，屏幕位置不变，故与头像合成一个整体缩放）；
      随后双方依次下场（先手方先下场，另一方延迟 REVEAL_HQ_OUT_STAGGER），下场即
      滑向本方支援阵线第 3 槽落位（REVEAL_HQ_OUT_DUR），角度转回面向基准，下场
      起点切短卡模型（event = "switch"）。
      观战者（KardsTableBattleStart 广播分支调用，mySlot=nil）：无本方头像与揭晓
      序列，不经过头像中点——直接在支援阵线第 3 槽上方抬升 REVEAL_HQ_OBS_LIFT 处
      翻面后落位。
      屏幕头像中点 → 牌桌世界坐标：取当前相机视线与中心槽高度平面的交点
      （揭晓期间相机为固定俯视视角，见 KardsTableBattleStart 的目标相机）。
--]]
-- 总部对局开始动画（定义见下方 KardsHQReveal* 段；此处必须用「赋值」而非 local function
-- 重新声明——同作用域重复 local 会创建新局部变量遮蔽上方前向声明，导致上方钩子闭包
-- 捕获的 upvalue 恒为 nil，调用时报错）
StartHQReveal = function(tableEnt, mySlot)
    if not IsValid(tableEnt) then return end
    local ply = LocalPlayer()
    -- 参战者（mySlot 非 nil）才有头像中点环节：相机接管期间取视线与中心槽高度平面交点；
    -- 观战者（mySlot=nil）直接落位支援阵线，不依赖相机（观战用自由视角）
    local camPos = nil
    if mySlot then
        local cam = KARDS.BattleCamera and KARDS.BattleCamera.Cameras[ply]
        camPos = cam and cam.active and cam.pos or nil
    end
    -- 先手方槽位（揭晓状态 firstSlot）：仅该方总部在揭晓时刻 z 上升；观战者无揭晓序列 → nil
    local firstSlot = KARDS.BattleState.reveal and KARDS.BattleState.reveal.firstSlot or nil
    -- 总部出场高度 = 中槽高度（CenterSlotPos 由本文件后部导出，见常量区中槽定义）
    local centerZ = (KARDS.CenterSlotPos and KARDS.CenterSlotPos.z) or 30.5
    local list = {}
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWString("Kards_DeckRole", "") == "hq" then
            local slot = ent:GetNWInt("Kards_DeckSlot", 0)
            if slot >= 1 and slot <= 2 then
                local isMine = (slot == mySlot)
                -- 落位行号按槽位映射（P1 槽 → +1 行 / P2 槽 → -1 行，与视角无关）：
                -- 用 isMine 会在 P2 视角本方总部误落 P1 行、观战者（mySlot=nil）
                -- 两总部全部落 P2 行（2026-08-10 修复）
                local row = (slot == 1) and 1 or -1
                -- 落位朝向 = 本地视角朝向（基础规则：P1 视角所有牌朝 P2 / P2 视角所有牌朝
                -- P1 / 观战按归属方；见 cl_perspective.lua FacingYaw，2026-08-10 起反向）。总部动画全程以该
                -- 朝向为基准（翻转独立绕 x 轴，yaw 与之不冲突），动画结束后由 KardsFieldFacing
                -- 驱动持续接管（角度一致无跳变）
                local facing = KARDS.Perspective and KARDS.Perspective.FacingYaw
                    and KARDS.Perspective:FacingYaw(KARDS.Perspective.LocalView, slot) or 0
                local supportPos = KARDS.Animation.Board2D:RelPos(3, row)
                -- 出场终点与 Yaw（2026-10-24 用户规格）：
                --   参战者：质心落在本方/敌方头像中点，z = 中槽高度；yaw 相对面向基准
                --   旋转 45°（本方逆时针 / 敌方顺时针，屏幕观察方向）
                --   观战者：无头像中点环节，在支援阵线第 3 槽上方抬升 REVEAL_HQ_OBS_LIFT
                --   处翻面，无倾斜
                local flankPos, flankYaw
                if mySlot then
                    -- 头像中点屏幕坐标（左 = 本方 / 右 = 敌方）
                    local ax = (isMine and REVEAL_AVATAR_CX_LEFT or REVEAL_AVATAR_CX_RIGHT) * ScrW()
                    local ay = REVEAL_AVATAR_CY * ScrH()
                    local world = nil
                    if camPos then
                        local dir = gui.ScreenToVector(ax, ay)
                        -- 取中心槽高度平面（而非桌面顶）：交点位于「头像中点」射线上，
                        -- 其屏幕投影恰为头像中点 → 卡片质心与头像中点重合
                        local planeZ = tableEnt:LocalToWorld(Vector(0, 0, centerZ)).z
                        if dir and dir.z < 0 then
                            world = camPos + dir * ((planeZ - camPos.z) / dir.z)
                        end
                    end
                    -- 兜底（相机不可用 / 视线不朝下）：本方支援阵线第 3 槽高度
                    flankPos = world and tableEnt:WorldToLocal(world)
                        or KARDS.Animation.Board2D:RelPos(3, row)
                    flankPos.z = centerZ
                    -- yaw 相对面向基准 ±45°：本方（左）逆时针、敌方（右）顺时针。
                    -- 揭晓相机 yaw 与面向基准之差对双方视角恒为 90°（P1 为 270/180、
                    -- P2 为 90/0），故 ±45 的取法在两个视角下得到同样的屏幕倾斜方向
                    flankYaw = facing + (isMine and 45 or -45)
                else
                    flankPos = KARDS.Animation.Board2D:RelPos(3, row)
                    flankPos.z = flankPos.z + REVEAL_HQ_OBS_LIFT
                    flankYaw = facing
                end
                battleHQLeft[ent] = true -- 离开卡组槽：堆叠顶层让给下一张普通卡
                ent:SetNoDraw(false)
                -- 通知服务端：总部已离开卡堆顶（服务端把该槽剩余卡数改为「不含总部」
                -- 并重算卡堆档位，见 init.lua net.Receive KardsHQRevealStart）。观战者
                -- （mySlot=nil）无 _kardsTable，服务端忽略其消息；参战者必发，档位
                -- 仍会正确重算，故所有视角最终一致。
                net.Start("KardsHQRevealStart")
                    net.WriteEntity(tableEnt)
                    net.WriteUInt(slot, 8)
                net.SendToServer()
                -- 关键帧动画（KARDS.AnimPlayer 驱动，组名 "hqReveal"）：帧时刻以本动画起点
                --（= 序列 REVEAL_HQ_IN_START，与揭晓 UI 时间轴对齐）为基准换算：
                --   t=0 卡堆顶（卡背朝上 pitch 180）→ t=REVEAL_HQ_IN_DUR 头像中点（翻到
                --   卡面 pitch 0 + 45° 倾斜）→ [先手方] 停住等揭晓时刻 → 上升
                --   REVEAL_HQ_RISE_LIFT → 停住至下场起点（event "switch" 切短卡模型）→
                --   t=+REVEAL_HQ_OUT_DUR 滑落支援阵线第 3 槽（角度转回 facing）。
                -- 缓动 smooth = 原 RevealEaseInOut（z 上升段单独用 easeOut）
                local fromPos = ent:GetLocalPos()
                local fromYaw = ent:GetLocalAngles().y -- 动画起点 yaw（卡堆角度 ±45/-135）
                local isFirst = (firstSlot == slot) -- 先手方（其总部在揭晓时 z 上升、先下场）
                -- 下场起点（本动画基准）：先手方 REVEAL_HQ_OUT_START，另一方再延迟
                -- REVEAL_HQ_OUT_STAGGER
                local relExit = REVEAL_HQ_OUT_START - REVEAL_HQ_IN_START
                    + (isFirst and 0 or REVEAL_HQ_OUT_STAGGER)
                local frames
                if mySlot then
                    frames = {
                        { t = 0, pos = fromPos, ang = Angle(180, fromYaw, 0) },
                        { t = REVEAL_HQ_IN_DUR, pos = flankPos, ang = Angle(0, flankYaw, 0) },
                    }
                    local holdPos = flankPos
                    if isFirst then
                        -- 先手方：与头像回弹同时、同曲线、同幅度的「整体缩放」（2026-10-24
                        -- 用户规格；2026-10-27 明确为纯透视放大）。
                        -- 放大完全由「沿相机视线向相机靠近」实现，不做任何空间缩放：
                        -- 透视投影下屏幕尺寸与相机到卡片的深度成反比，把卡片沿
                        -- 「相机 → 卡片」射线移到深度 d / b 处，其 2D 投影尺寸恰为 b 倍，
                        -- 且屏幕位置不变（卡片质心本就落在头像中点）。
                        --   P' = camPos + (P - camPos) / b
                        -- 揭晓相机垂直俯视时 P 与 P' 的 x/y 不变，退化为单纯 z 上升；
                        -- 相机若不严格垂直，也仍沿该视线进行，不会偏离这一缩放关系。
                        -- 全程不调用 SetPMXScale，卡面模型尺寸保持不变。
                        -- 曲线无法用单个缓动表达（easeOutBack 含过冲后的回落），按采样点
                        -- 插值（linear 段），与头像逐帧完全同步。
                        local relRise = REVEAL_FIRST_DELAY - REVEAL_HQ_IN_START
                        local flankWorld = tableEnt:LocalToWorld(flankPos)
                        -- 由放大倍率反算位置（相机不可用时退化为沿牌桌 z 抬升常量）
                        local function BouncePos(tAbs)
                            local b = RevealBounceScale(tAbs)
                            if camPos then
                                return tableEnt:WorldToLocal(camPos + (flankWorld - camPos) / b)
                            end
                            return Vector(flankPos.x, flankPos.y,
                                flankPos.z + REVEAL_HQ_RISE_LIFT * (b - 1) / 0.25)
                        end
                        -- 停在出场终点，等揭晓时刻（同姿关键帧，保证不提前上升）
                        frames[#frames + 1] = { t = relRise, pos = flankPos, ang = Angle(0, flankYaw, 0) }
                        local N = 10 -- 采样段数（0.4s 内 10 段，过冲峰值与回落均可还原）
                        for i = 1, N do
                            local tAbs = REVEAL_FIRST_DELAY + REVEAL_HQ_RISE_DUR * (i / N)
                            frames[#frames + 1] = {
                                t = relRise + REVEAL_HQ_RISE_DUR * (i / N),
                                pos = BouncePos(tAbs),
                                ang = Angle(0, flankYaw, 0),
                                easing = "linear",
                            }
                        end
                        holdPos = BouncePos(REVEAL_FIRST_DELAY + REVEAL_HQ_RISE_DUR)
                    end
                    frames[#frames + 1] = { t = relExit, pos = holdPos, ang = Angle(0, flankYaw, 0),
                        event = "switch" }
                    frames[#frames + 1] = { t = relExit + REVEAL_HQ_OUT_DUR, pos = supportPos,
                        ang = Angle(0, facing, 0) }
                else
                    -- 观战者：无头像中点环节，翻面 + 抬升后直接落位
                    frames = {
                        { t = 0, pos = fromPos, ang = Angle(180, fromYaw, 0) },
                        { t = REVEAL_HQ_IN_DUR, pos = flankPos, ang = Angle(0, flankYaw, 0), event = "switch" },
                        { t = REVEAL_HQ_IN_DUR + REVEAL_HQ_OUT_DUR, pos = supportPos, ang = Angle(0, facing, 0) },
                    }
                end
                list[#list + 1] = { ent = ent, slot = slot } -- 活跃 HQ 集合（InHQRevealAnim 遍历）
                KARDS.AnimPlayer:Play(ent, frames, {
                    group = "hqReveal",
                    easing = "smooth", -- 原 RevealEaseInOut（翻转 / 滑落同一曲线）
                    -- 短卡切换时机（2026-10-24 随动画重排调整）：下场起点（开始滑向支援
                    -- 阵线第 3 槽之时）切换 basic_card_unit 模型（短卡 + UV 裁切），
                    -- 此前在头像中点阶段展示完整卡面。部署单位「半程切换小模型」原理
                    -- 同款：客户端本地准备 manifest + 裁切材质 + 重绑短卡尺寸文字；
                    -- 参战者通知服务端 ApplyImportedModel 权威切换（观战者渲染随服务端
                    -- 切换同步，本地仅准备 manifest + 文字）。服务端收到通知后把权威状态
                    -- 置为支援阵线第 3 槽，客户端动画每帧 SetLocalPos 覆盖之，不产生跳变。
                    onKeyframe = function(target, name, t)
                        if name ~= "switch" then return end
                        local hqModelID = target:GetNWString("Kards_DeckModelID", "")
                        local hqSafe = hqModelID:match("^kards_deck_hq_(.+)$") or ""
                        if hqSafe ~= "" and KARDS.CardManifest and KARDS.CardManifest.CloneUnit then
                            local hqUnitModelID = "kards_unit_hq_" .. hqSafe
                            KARDS.CardManifest.CloneUnit(hqUnitModelID, "kards_deck/hq_" .. hqSafe)
                            if PMXStaticImporter and PMXStaticImporter.ClearCache then
                                PMXStaticImporter.ClearCache(hqUnitModelID)
                                KARDS.PrefillUnitCrop(hqUnitModelID)
                            end
                            if mySlot then
                                net.Start("KardsHQRevealDone")
                                    net.WriteEntity(tableEnt)
                                    net.WriteUInt(slot, 8)
                                net.SendToServer()
                            end
                            -- 重绑 3D2D 文字为短卡尺寸（实体模式读 NW；总部短卡 hqShort=仅防御，
                            -- 无攻击/行动花费/词条/描述；renderW/H=209/290 与单位短卡一致，
                            -- 否则缺省 7.2/10.8 当作渲染像素致位置错乱）
                            if KARDS.CardTextOverlay then
                                KARDS.CardTextOverlay:Remove(target)
                                KARDS.CardTextOverlay:AddEntity(target, 7.2, 8.528, 209, 290, true)
                                -- 总部防御源值（t4 攻防颜色规则基准，2026-08-12）：防御 NW
                                -- 已由服务端创建时初写（文件值，见 table_battledeck.lua），快照
                                -- 为 base——此后受伤害防御下降 → 红色 + 数值变动特效
                                KARDS.CardTextOverlay:SetBaseStat(target, "defense", target:GetNWInt("Kards_CardDefense", 0))
                            end
                        end
                    end,
                    onComplete = function(target)
                        -- 总部落位支援阵线第 3 槽：登记进 KARDS.BattleState.fieldLayouts（服务端 HQ 恒参与居中，
                        -- 见 BroadcastFieldLayout；首次广播前拖拽预览/飞行的偶数偏移计数含总部，
                        -- 2026-08-10 部署落位修复）
                        KARDS.BattleState.fieldLayouts[slot][target] = 3
                        -- 从活跃集合移除；全部总部动画结束 → 播放一次收尾音效
                        for i, r in ipairs(hqReveals) do
                            if r.ent == target then
                                table.remove(hqReveals, i)
                                break
                            end
                        end
                        if #hqReveals == 0 then
                            KARDS.PlayKardsSound("hq_end") -- 总部动画结束音效（全部总部落位支援阵线完成，一次）
                        end
                    end,
                })
            end
        end
    end
    hqReveals = list
end

-- 总部对局开始动画驱动已移除（re.md 重构）：3 帧关键帧动画由 KARDS.AnimPlayer 的
-- 单一 Think 驱动（组名 "hqReveal"），落位登记与 hq_end 音效在 Play 的 onComplete
-- 中完成，不再需要本逐帧循环。

-- 被抽卡切换为卡面模式：改写该卡唯一 modelID 的 manifest（front → 真实卡面）。
-- 发牌卡卡面初始化已完成的实体（幂等：同实体只改写一次 manifest + ClearCache）
local drawFaceReady = setmetatable({}, { __mode = "k" })
-- 发牌卡卡面初始化待处理队列（NW 未就绪时 Think 每帧重试；net.Receive 到达时
-- Kards_DeckModelID / Kards_DeckSafeName NW 可能尚未同步，导致 InitDrawCardFace
-- 提前 return → 无人改写 manifest → ProcessBattleDeckCard 把 front 定为 usa 卡背
--（用户实测：重新调度卡显示棕褐色卡背）。入队后 Think 轮询，NW 就绪即改写卡面。）
local drawFacePending = setmetatable({}, { __mode = "k" })

-- 卡面初始化（manifest 改写 front/back → data/kards_deck/<safeName>/front.png、
-- back → 该卡卡背），ClearCache 重建 renderable 加载卡面，并绑定 3D2D 文字（外观
-- 编辑器生成 3D2D 预览卡同款：AddLocal 本地外观表 + 渲染像素尺寸，每帧从
-- appearance 实时读取 → 文字分布与编辑器预览一致；不再用 AddEntity NW 同步）。
-- 同步执行（net 消息内）：卡牌动画翻面到卡面可见前材质已就绪。NW 未就绪返回
-- false（调用方入队重试）；幂等：已处理过的实体直接返回。
local function InitDrawCardFace(ent)
    local modelID = ent:GetNWString("Kards_DeckModelID", "")
    local safeName = ent:GetNWString("Kards_DeckSafeName", "")
    if modelID == "" or safeName == "" then return false end
    if drawFaceReady[ent] then return true end
    local cardName = KARDS.GetCardIdentity(ent) -- 手牌卡面定向表优先，回退 NW（2026-08-18，规划 B1）
    -- 卡名 NW 未就绪：外观数据（appearance/textureSize）无法匹配，不标记就绪，
    -- 调用方（drawFacePending Think 重试）等 NW 同步后再初始化
    if cardName == "" then return false end
    local appearance, texturePath, textureSize = KARDS.DeckFindCardInfo(cardName)
    -- manifest 改写（组卡同款确定性改写：front/back → data/kards_deck/<safeName>/）
    if KARDS.CardManifest.EnsureDeck(modelID, safeName) then
        -- 卡面文件兜底：本地卡面 PNG 未落盘时从保存文件模板复制（组卡模式通常已落盘）
        local dir = "kards_deck/" .. safeName
        if not file.Exists(dir .. "/front.png", "DATA") then
            local tmplPath = appearance and texturePath and texturePath.template or nil
            if tmplPath and file.Exists(tmplPath, "DATA") then
                file.CreateDir(dir)
                file.Write(dir .. "/front.png", file.Read(tmplPath, "DATA"))
            end
        end
        -- A 修复（2026-08-12）：manifest back → data/kards_deck/<safeName>/back.png，
        -- 原只保证 front.png、back.png 从不落盘 → 卡背加载缺失贴图（白色空背；调试
        -- 会话 A:face 探针证实血红镰刀/步兵55团 back=false）。卡背源 = 外观国家卡背，
        -- 缺失依次兜底 usa → front.png（与 WriteCardTextures「卡背缺失用卡面兜底」一致）。
        if not file.Exists(dir .. "/back.png", "DATA") then
            local country = tostring((appearance and appearance.country) or "usa"):lower()
            local backData = KARDS.ReadCardbackPNG(country)
            if not backData then
                backData = KARDS.ReadCardbackPNG("usa")
            end
            if not backData and file.Exists(dir .. "/front.png", "DATA") then
                backData = file.Read(dir .. "/front.png", "DATA")
            end
            if backData then
                file.CreateDir(dir)
                file.Write(dir .. "/back.png", backData)
            end
        end
        if PMXStaticImporter and PMXStaticImporter.ClearCache then
            PMXStaticImporter.ClearCache(modelID)
            -- back 槽 UV 镜像修正：ClearCache 后预填翻转材质（抽牌临时卡翻面后 back 槽可见）
            -- 2026-08-15：PrefillBackFlip 定义于 cl_battle_material.lua（include 独立
            -- 编译执行不共享本文件 local），经 KARDS 命名空间访问
            KARDS.PrefillBackFlip(modelID)
        end
    end
    -- 标记为已处理：防止统一驱动 KardsTableCardMaterial 再把 manifest 写回卡背
    -- 2026-08-15：battleDeckReady / battleDeckModelReady 定义于 cl_battle_material.lua
    -- （include 独立编译执行不共享本文件 local），经 KARDS 命名空间访问
    drawFaceReady[ent] = true
    KARDS.battleDeckReady[ent] = true
    KARDS.battleDeckModelReady[modelID] = true
    -- 绑定 3D2D 文字（外观编辑器生成 3D2D 预览卡同款，cl_canvas_editor.lua SpawnTestEntity
    -- mode=="3d2d"）：AddLocal 本地外观表 + 渲染像素尺寸 → 文字分布/字号与编辑器预览
    -- 完全一致（appearance 静态表每帧实时读；renderW/H = 保存文件记录的渲染尺寸，
    -- 与卡面纹理像素对齐，缺省 300×400）
    if appearance and KARDS.CardTextOverlay then
        local texW, texH = 300, 400
        if textureSize and textureSize.w and textureSize.h then
            texW, texH = textureSize.w, textureSize.h
        end
        -- hideWhenBack=true（2026-08-12）：卡背朝上（抽牌动画排队/delay 等待期或
        -- 翻面早期）不绘制 3D2D 文字，避免在卡组顶泄露所抽牌攻防/费用；翻面越过
        -- ±90° 后文字随卡面出现（见 cl_card_text_overlay.lua DrawOverlay）
        KARDS.CardTextOverlay:AddLocal(ent, appearance, 7.2, 10.8, texW, texH, true)
    end
    return true
end

-- 卡面初始化重试（每帧）：NW 未就绪的实体保持入队；就绪后 InitDrawCardFace
-- 完成（幂等），处理完移出。空队列时零开销。
hook.Add("Think", "KardsDrawFacePending", function()
    for ent in pairs(drawFacePending) do
        if not IsValid(ent) then
            drawFacePending[ent] = nil
        else
            InitDrawCardFace(ent)
            if drawFaceReady[ent] then drawFacePending[ent] = nil end
        end
    end
end)

-- 无对手模式操作身份切换（服务端 kards_switch 指令发送）：更新本方槽位 + 本地视角
-- + 相机朝向（正上方俯视，yaw 按槽位，与 KardsTableBattleStart 目标姿态同款）。
-- 切换后本方手牌 = 目标槽手牌：该槽原按「对方」绘制（未 InitDrawCardFace 卡背），
-- 需补卡面初始化才能操作；旧槽（现为对方）手牌绕卡长轴翻转 180° 恢复卡背
--（不改 manifest，见下方处理）；真实手牌扇形/翻转角度由 KardsRealHandFacing 每帧
-- 驱动（本方扇形姿态 / 对方已初始化卡强制卡背朝上），战场卡朝向由 cl_perspective.lua
-- ApplyFacing 驱动（读 P.LocalView）。
-- 位置位于 InitDrawCardFace 定义之后：处理函数依赖其 local 引用。
-- F 修复（2026-08-12）：前向占位——本回调引用 HandFanPos / MulliganFanPos，二者分别于
-- L2754 / L2821 声明、晚于本回调，不占位则词法解析为全局 nil → 代选/旧槽回收路径运行时
-- 报错。占位后由原声明处 local function 改为赋值（同 KardsResetPerMatchDedup 前向占位
-- 模式，见 L166 / L1808）。
local HandFanPos, MulliganFanPos
net.Receive("KardsSwitchSlot", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    if not IsValid(ent) then return end
    local inTable = KARDS.BattleState.inTable
    if not (inTable and inTable.ent == ent) then return end
    local oldSlot = inTable.slot
    inTable.slot = slot
    if KARDS.Perspective and KARDS.Perspective.SetLocalView then
        KARDS.Perspective:SetLocalView(slot)
    end
    -- F 修复（2026-08-12）：无对手模式结束本方回合后 endedTurn=true，且不随对方回合
    -- 广播复位（KardsTurnUpdate 仅当 slot==inTable.slot 才复位 endedTurn，而切换时
    -- 该广播早已到达）→ 切换后拿起门控 not endedTurn 恒不满足 → 双方手牌都拿不起。
    -- 切换即接管新槽操作身份：复位 endedTurn，新槽回合（battleTurn==slot）可拿起。
    KARDS.BattleState.endedTurn = false
    -- F 修复（2026-08-12）：旧槽仍在重新调度选择中（mulligan 未提交）时切换——把中间
    -- 扇形卡收回手牌位并登记（放弃本次选择；返回该槽时由下方代选逻辑重新呈现）。避免
    -- 新槽代选替换 mulligan 状态后旧槽卡被孤弃（不在手牌表、不可选择、不可拿起）。
    local oldM = KARDS.BattleState.mulligan
    if oldSlot and oldSlot ~= slot and oldM and oldM.slot == oldSlot and not oldM.submitted then
        for ce, card in pairs(oldM.cards) do
            if IsValid(ce) then
                KARDS.AnimPlayer:Play(ce, {
                    { t = 0, pos = ce:GetLocalPos(), ang = Angle(0, ce:GetLocalAngles().y, 0) },
                    { t = 1.0, pos = HandFanPos(oldSlot, card.index, oldM.total), ang = Angle(0, (oldSlot == 1) and 180 or 0, 0) },
                }, { group = "mulliganToHand" })
                KARDS.BattleState.realHandCards[oldSlot][ce] = card.index
            end
        end
        oldM.cards = {}
    end
    -- 目标槽重新调度代选（2026-08-12）：无对手模式虚拟对手不再自动确认重新调度
    --（table_battledeck.lua SetupVirtualOpponent 改动），切换到尚未完成重新调度的槽
    --（mulliganDoneSlot 未置位）且该槽已有起手牌（发牌广播已按对方视角登记
    -- realHandCards）→ 把起手牌（idx ≤ dealStarterCount[slot]，后续回合抽牌留在手牌）
    -- 重新呈现为牌桌中间扇形选择（玩家代替虚拟对手选择去留），确认后走既有补抽/
    -- 统一落位流程（KardsMulliganDone / KardsMulliganAnimsUpdate）。
    local hand = KARDS.BattleState.realHandCards[slot]
    local m = KARDS.BattleState.mulligan
    local starterTotal = KARDS.BattleState.dealStarterCount[slot] or 0
    if hand and next(hand) and not KARDS.BattleState.mulliganDoneSlot[slot] and starterTotal > 0
        and not (m and m.slot == slot and m.submitted) then
        if not m or m.slot ~= slot or m.submitted then
            m = { active = false, slot = slot, total = starterTotal, cards = {}, submitted = false }
            KARDS.BattleState.mulligan = m
        end
        for cardEnt, idx in pairs(hand) do
            if IsValid(cardEnt) and idx <= starterTotal then
                InitDrawCardFace(cardEnt) -- 代选需看卡面（原对方视角未初始化，卡背）
                drawFacePending[cardEnt] = true
                m.cards[cardEnt] = { ent = cardEnt, index = idx, selected = false }
                local endYaw = (slot == 1) and 180 or 0 -- 文字朝本方（同重新调度发牌）
                KARDS.AnimPlayer:Play(cardEnt, {
                    { t = 0, pos = cardEnt:GetLocalPos(), ang = Angle(0, cardEnt:GetLocalAngles().y, 0) },
                    { t = 0.5, pos = MulliganFanPos(idx, starterTotal), ang = Angle(0, endYaw, 0) },
                }, { group = "mulliganDeal", delay = (idx - 1) * 0.25 })
                KARDS.BattleState.realHandCards[slot][cardEnt] = nil -- 移出手牌登记（代选期间不可拿起）
            end
        end
    else
        -- 已完成的槽（正常切换）：补卡面初始化（原对方手牌卡背，NW 未就绪则入队重试）；
        -- 角度由 KardsRealHandFacing 本方分支下帧驱动回扇形姿态（卡面朝上）
        if hand then
            for cardEnt in pairs(hand) do
                if IsValid(cardEnt) then
                    InitDrawCardFace(cardEnt)
                    drawFacePending[cardEnt] = true
                end
            end
        end
        -- 旧槽（现为对方）：手牌绕卡长轴翻转 180°（pitch 180，卡背朝上）——恢复卡背
        -- 不改 manifest（back 子网格即真实卡背图，PrefillBackFlip 已修正 UV 镜像）；
        -- 3D2D 文字跟随实体朝向（cl_card_text_overlay DrawOverlay 用 GetForward/GetRight/
        -- GetUp 派生轴线）→ 文字朝卡背侧不可见，满足「对方手牌正面不渲染」。
        -- 兜底：KardsRealHandFacing 对方分支每帧强制翻转（动画终帧/后续抽牌 pitch=0
        -- 会被覆盖），见该钩子 mine/elseif drawFaceReady 分支。
        if oldSlot and oldSlot ~= slot then
            local oldHand = KARDS.BattleState.realHandCards[oldSlot]
            if oldHand then
                for cardEnt in pairs(oldHand) do
                    if IsValid(cardEnt) then
                        local cur = cardEnt:GetLocalAngles()
                        cardEnt:SetLocalAngles(Angle(180, cur.y, cur.r))
                    end
                end
            end
        end
    end
    -- 相机切到新视角（正上方俯视，yaw 按槽位；与 KardsTableBattleStart 目标关键帧同款）
    local deckPos = ent:LocalToWorld(Vector(0, 0, 60))
    local deckYaw = (slot == 1) and 270 or 90
    local deckAng = ent:LocalToWorldAngles(Angle(90, deckYaw, 0))
    KARDS.BattleCamera:SetView(LocalPlayer(), deckPos, deckAng, 75)
end)

-- 手牌槽常量（与服务端 ENT.HandSlot* 同步硬编码：客户端实体对象上不存在服务端 ENT
-- 字段，访问 tableEnt.HandSlotBase 等会得 nil → 算术错误；数值变更须与服务端同步）
local HandSlotBase    = Vector(0, 0, 30.5)  -- 手牌中心卡位置（桌面中心正上方，z 抬升更高；与服务端同步，见 init.lua L1333）
-- 中槽（2026-09-26 新增；2026-09-30 统一）：牌桌玩家视角下的居中展示槽位族，xy 取牌桌中心、
-- z 与手牌等高（= HandSlotBase.z），供居中展示类动画使用（如「开发」三选一展开候选卡）。
-- 槽位几何沿用牌桌中间扇形（重新调度发牌 MulliganFanPos）：n 张时第 i 张落
-- x = ((n + 1) / 2 - i) * CenterSlotSpacing（首张在最左，P1 视角 +x 为左），于是
-- n = 4 即中槽的 4 槽模式（x = 12 / 4 / -4 / -12，先手重新调度的四张卡槽），
-- n = 3 即三选一（x = 8 / 0 / -8），居中那张与 CenterSlotPos（x = 0）重合。
-- 高度由 CenterSlotZ 承载，重新调度扇形与中槽同为该高度（2026-09-30 统一，此前扇形用
-- CardZ + 10，比中槽低约 2 个单位，跨槽动画会出现高度跳变）。
local CenterSlotSpacing = 8.0
local CenterSlotZ       = HandSlotBase.z
local CenterSlotPos     = Vector(0, 0, CenterSlotZ)
-- 三选一槽位（2026-09-26 新增：「开发」「观星」三张候选卡的展示位）：即中槽槽位族取 n = 3，
-- index 1 = 中左 / 2 = 中 / 3 = 中右，index 2 与 CenterSlotPos 完全一致。间距与高度同中槽
-- 常量（CenterSlotSpacing / CenterSlotZ）。左右方向随视角镜像：P1 视角左侧为 +x（与爆牌弃牌
-- 槽 P1LP2RSlot 的判定一致，见 cl_battle_mulligan.lua L119 起），P2 视角取反，故用取值函数承载。
-- 槽位坐标预置（2026-10-16 性能优化）：三选一悬停每帧逐卡取值，坐标恒定，改为返回
-- 共享向量（调用方只读取坐标 / 作为动画目标，从不改写返回值）
local PickSlotVectors = {
    [1] = {
        Vector(CenterSlotSpacing, 0, CenterSlotZ),
        Vector(0, 0, CenterSlotZ),
        Vector(-CenterSlotSpacing, 0, CenterSlotZ),
    },
    [2] = {
        Vector(-CenterSlotSpacing, 0, CenterSlotZ),
        Vector(0, 0, CenterSlotZ),
        Vector(CenterSlotSpacing, 0, CenterSlotZ),
    },
}
local function PickSlotPos(index, viewSlot)
    local row = PickSlotVectors[(viewSlot == 2) and 2 or 1]
    return row[index] or row[2]
end
-- 三选一动画数值常量（时长秒 / 距离世界单位 / 角度度）
local PickDealDur      = 0.5    -- 单张候选卡由卡组顶飞到槽位的时长（同 mulligan 发牌）
local PickDealStagger  = 0.25   -- 错峰：前一张度过一半时下一张起飞
local PickHoverLift    = 1.5    -- 悬停抬升量（z 上升，历史导出保留：中槽各交互 2026-11-01 起统一走 KARDS.HoverLiftPos）
local PickToHandDur    = 1.0    -- 选中卡飞入手牌扇形时长（同 mulligan 落位）
local PickSpinDur      = 0.9    -- 未选中卡出场时长
local PickSpinYaw      = 135    -- 未选中卡逆时针旋转角
local PickSpinDropZ    = 18     -- 未选中卡出场过程 z 下降量（30.5 降到 12.5）
local PickExitDist     = 26     -- 未选中卡出场终点沿「视角左下」方向的位移
local PickEnemyShift   = 14     -- 敌方 / 观战视角：选中卡由中槽向该方前移的距离（前线 xy 前方）
local PickSpecAngle    = 45     -- 观战视角：选中卡倾向该方玩家的旋转角
local ScryTableZ       = 18.93  -- 观星未选中卡第一段终点 z（桌面高度 CardZ 18.43 + 0.5，贴桌不悬空）
local ScryFlipDur      = 0.45   -- 观星未选中卡翻面段时长
local ScryToBottomDur  = 0.6    -- 观星未选中卡落入卡组底段时长
local HandSlotHalfY   = 18                  -- 南北分离半距（P1 +y / P2 −y；18 更靠近牌桌中心，与服务端同步）
local HandSlotZViewOffset = 8               -- 观战视角手牌 z 偏移：观战不跟随 P1/P2 的 z 抬升，
                                            -- 按服务端基础 z − 本偏移还原观战基线（= 服务端 HandSlotBase.z − 22.5，须与服务端同步）
local HandSlotSpacing = 2.0                 -- 扇形相邻卡局部 x 间距
local HandSlotFanRadius = 50                -- 扇形圆弧半径
local HandSlotZStep   = 0.1                 -- 卡面法线 z 阶梯
local HandSlotFanAngle = 30                 -- 扇形半展开角（°）：端点卡 ±α、中心 0°（与服务端 ENT.HandSlotFanAngle 同步）
-- 槽卡位置基准角度（平躺卡面朝上；扇形布局用，弧朝向对方）：P1 yaw0 / P2 yaw180
-- （i=1 恒在扇形 +X 端、z 阶梯斜率与初始设计一致）。与服务端 ENT.HandSlotAngles 同步。
local HandSlotAngles  = { [1] = Angle(0, 0, 0), [2] = Angle(0, 180, 0) }
-- 文字朝向翻转量（°）：位置基准再绕面法线转 180° yaw = 文字顶朝本方（P1 手牌在
-- +y 侧需文字顶朝 +y / P2 在 −y 侧需朝 −y，3D2D 文字顶部沿实体 −Right）。
-- 2026-08-10 曾直接交换 HandSlotAngles 两侧常量修「文字朝对方」，导致整个扇形
-- 左右镜像「整体反了」（用户实测）——文字方向必须与扇形布局解耦，故位置/卡体
-- 张开用位置基准（HandSlotAngles），文字方向在 HandFanPos 最终角度叠加本常量。
local HandSlotTextYaw = 180
local HandSlotHoverLift = 0.8   -- 悬停提升量：鼠标悬停本方手牌时沿自身 y 轴的最大移动量（单位，可微调；2026-08-14 用户规格由 1.6 减半；对方/观战远程悬停 z 抬升同用此增量）
local HandSlotHoverDur = 0.1   -- 悬停提升时长（秒）：0.1 秒内增加到满量（离开同样 0.1 秒回落）
local HandSlotHoverRadius = 12 -- 悬停判定半径：鼠标射线到手牌中心的最大距离（单位）

-- ====================================================================
-- 左右卡槽常量（2026-08-12 更名，牌桌卡动画系统坐标常量，见 re.md §3.2 姿态库）：
--   原「左卡槽 / 右卡槽」按 P2 视角命名（-x = P2 视角左 / +x = P2 视角右），与 P1
--   视角左右相反，容易混淆；现按双方视角命名：
--     P1RP2LSlot = 原左卡槽（x=-DisplaySlotHalfX）：P1 视角右 / P2 视角左
--     P1LP2RSlot = 原右卡槽（x=+DisplaySlotHalfX）：P1 视角左 / P2 视角右
--   （P1 视角约定：+x 为左侧 / -x 为右侧——与 MulliganFanPos 发牌从左侧起填一致；
--   2026-08-11 曾按战场列误设「-x 为左」并标注实测修正，实际该左右是相对 P2 的。）
--   位置：x = ±DisplaySlotHalfX（2026-08-11 由 ±24 收拢到 ±14，更靠近屏幕中心——
--   相机在 (-70,0,30) 近水平朝牌桌中线看，越靠近中线越接近画面中央）、y = 0（牌桌
--   中线）、z = DisplaySlotZ（2026-08-11 由手牌层 30.5 抬高到 40，浮于战场上方更醒目）。
--   角度：Angle(0, 0, 0)——相对牌桌 yaw = 0（与牌桌 x/y 轴对齐），pitch/roll 归零 =
--   正面朝上（平躺，同手牌姿态）。
-- ====================================================================
local DisplaySlotHalfX = 14  -- 左右卡槽 x 半距（P1 视角：+x 为左 / -x 为右；数值可调）
local DisplaySlotZ = 40      -- 卡槽 z（进桌对战视角 LocalView=1|2，浮于战场/手牌之上；数值可调）
KARDS.P1RP2LSlot = 1 -- 原左卡槽（-x；P1 视角右 / P2 视角左）
KARDS.P1LP2RSlot = 2 -- 原右卡槽（+x；P1 视角左 / P2 视角右）
local DisplaySlots = {
    [KARDS.P1RP2LSlot] = { pos = Vector(-DisplaySlotHalfX, 0, DisplaySlotZ), ang = Angle(0, 0, 0) }, -- P2 视角左
    [KARDS.P1LP2RSlot] = { pos = Vector( DisplaySlotHalfX, 0, DisplaySlotZ), ang = Angle(0, 0, 0) }, -- P1 视角左
}

-- ====================================================================
-- 交叉填槽统一方法（2026-08-12）：声明卡应出现在「哪方视角的哪一侧」，自动交叉
-- 填槽使从双方视角看卡都在声明的同一侧。调用方只需声明视角方与期望侧，无需关心
-- 实际坐标符号：
--   KARDS.CrossSlotFor(1, "left")  → KARDS.P1LP2RSlot（P1 视角左 = +x）
--   KARDS.CrossSlotFor(2, "left")  → KARDS.P1RP2LSlot（P2 视角左 = -x）
--   KARDS.CrossSlotFor(1, "right") → KARDS.P1RP2LSlot（P1 视角右 = -x）
--   KARDS.CrossSlotFor(2, "right") → KARDS.P1LP2RSlot（P2 视角右 = +x）
-- 挂 KARDS 命名空间（非顶层 local，同 L2693 惯例：顶层 local 接近 GLua 上限，
-- 且本方法供其他文件/后续复用）：
-- @param viewer number 视角方槽位（1=P1 / 2=P2）
-- @param side string "left" / "right"（viewer 视角下的左/右侧）
-- @return number 槽位编号（KARDS.P1RP2LSlot / KARDS.P1LP2RSlot）
-- ====================================================================
function KARDS.CrossSlotFor(viewer, side)
    local left = (viewer == 1) and KARDS.P1LP2RSlot or KARDS.P1RP2LSlot
    local right = (viewer == 1) and KARDS.P1RP2LSlot or KARDS.P1LP2RSlot
    return (side == "right") and right or left
end

-- ====================================================================
-- 指令卡打出动画常量（2026-08-12，阶段 C；更名）：指令卡打出后飞至「打出方视角
-- 左侧」卡槽（交叉填槽：P1 打出 → P1LP2RSlot(+x) / P2 打出 → P1RP2LSlot(-x)，双方
-- 看起来打出的指令都在自己左侧），停留 CommandHoldDur 秒后向左下出场（跳台）。
-- 队列规则（2026-08-13 特殊处理）：前一指令停留达 CommandHoldGate（1s）即放行后一
-- 指令开始动画（不必等其完全出场）；z 下移 CommandZDn 同样仅在前一指令停留达
-- CommandHoldGate 后生效（未达则后一指令与 z 下移一起等待至该时刻）。已有两个指令
-- 未结束动画又打出新指令 → 最早指令直接出场。
--   展示槽：CommandSlotFor(slot)（打出方视角左侧，见 CrossSlotFor）→ 槽位 pos。
--   出场终点：相对展示槽再向该方视角左侧（±CommandExitX，符号随槽位）、向观者侧
--     （P1 +y / P2 −y，按打出方取符号）、z 降低（CommandExitZ）——「左下」移动出牌桌
--     （z 降后仍高于桌面顶 CardZ=18.43）。
--   动画时长（CommandToSlotDur → 展示槽 / CommandHoldDur 停留 / CommandExitDur 出场）
--   总长约 2.6s；服务端据此延后实体移除（见 table_battledeck.lua C3）。
-- ====================================================================
local CommandToSlotDur = 0.35  -- 当前位置 → 展示槽飞行时长（秒）
local CommandHoldDur = 2.0     -- 展示槽停留时长（秒，用户指定：打出指令 2 秒后出场）
local CommandExitDur = 0.6     -- 展示槽 → 左下出场动画时长（秒；总动画 0.35+2.0+0.6 ≈ 2.95s）
local CommandHoldGate = 1.0    -- 停留放行阈值（秒，2026-08-13 用户指定）：前一指令停留达此值
                               -- 才允许后一指令开始动画，且 CommandZDn 下移才生效
local CommandZDn = 2.0         -- 前一指令 z 下移量（单位；新的指令覆盖其上）
local CommandExitX = 46        -- 出场终点相对展示槽、向该方视角左侧的偏移（牌桌局部，符号随槽位）
local CommandExitY = 12        -- 出场终点相对展示槽的观者侧偏移（P1 +y / P2 −y，符号按打出方）
local CommandExitZ = 8         -- 出场终点相对展示槽的 z 降低量（40 → 32，仍高于桌面顶 18.43）

-- 指令展示槽（打出方视角左侧；交叉填槽——双方打出指令都在自己视角左侧）
-- @param playSlot number 打出方槽位（1=P1 / 2=P2）
-- @return number 槽位编号（P1RP2LSlot / P1LP2RSlot）
local function CommandSlotFor(playSlot)
    return KARDS.CrossSlotFor(playSlot, "left")
end

-- 指令左下出场终点（相对展示槽偏移：向该方视角左侧按槽位取符号 + 向观者侧按打出方取符号）
-- @param playSlot number 打出方槽位（1=P1 / 2=P2）
-- @return Vector 出场终点（牌桌局部坐标）
local function CommandExitPosFor(playSlot)
    local slotIdx = CommandSlotFor(playSlot)
    local slotPos = DisplaySlots[slotIdx].pos
    local xSign = (slotIdx == KARDS.P1LP2RSlot) and 1 or -1 -- 向打出方视角左侧出场（沿槽位 x 符号方向）
    local yOff = (playSlot == 1) and CommandExitY or -CommandExitY
    return slotPos + Vector(xSign * CommandExitX, yOff, -CommandExitZ)
end

-- ====================================================================
-- 出场动画预设（2026-08-11，re.md §3.2 姿态库约定：返回 { pos, ang } 6 值姿态）：
--   逆时针出场 / 顺时针出场——卡从原位（调用方传入的起点姿态 pose）飞出牌桌外。
--   终点相对起点变化：
--     · 位置：x 偏移 ±ExitFlyDist（牌桌局部；P1 视角 −x 为左 / +x 为右——逆时针
--       出场向左飞 = −x，顺时针出场向右飞 = +x；y/z 保持起点不变）
--     · 角度：yaw 旋转 ±135°（Source 引擎 yaw 正值 = 逆时针——逆时针出场 yaw+135、
--       顺时针出场 yaw−135；pitch/roll 保持起点不变，卡仍平躺）。
--   返回的姿态可直接作 AnimPlayer 终点关键帧（起点帧用 pose 本身）。
-- ====================================================================
local ExitFlyDist = 64 -- 出场动画横向偏移极大值（牌桌局部 x 方向，飞出画面；数值可调）

-- 逆时针出场终点：向左（牌桌局部 −x）偏移 ExitFlyDist，yaw 逆时针 +135°
local function CounterClockwiseExitPose(pose)
    return {
        pos = pose.pos + Vector(-ExitFlyDist, 0, 0),
        ang = Angle(pose.ang.p, pose.ang.y + 135, pose.ang.r),
    }
end

-- 顺时针出场终点：向右（牌桌局部 +x）偏移 ExitFlyDist，yaw 顺时针 −135°
local function ClockwiseExitPose(pose)
    return {
        pos = pose.pos + Vector( ExitFlyDist, 0, 0),
        ang = Angle(pose.ang.p, pose.ang.y - 135, pose.ang.r),
    }
end

-- 爆牌动画时长（2026-08-11，readme 7.1 手牌上限 9：抽牌时手牌已满 → 专属弃牌动画，
-- 见 KardsTableDeckDraw 爆牌分支）：卡堆顶 → 爆牌方视角左侧卡槽（交叉填槽，
-- KARDS.CrossSlotFor(slot, "left")）→ 停留 OverdrawHold 秒 → 沿槽位方向出场
-- （+x 槽向右顺时针 / -x 槽向左逆时针，镜像对称）
local OverdrawFlyDur = 0.45  -- 卡堆顶 → 弃牌槽位飞行时长（秒，同抽牌动画 dur1）
local OverdrawHold = 1.0     -- 弃牌槽位停留时长（秒，1 秒后沿槽位方向出场，用户指定）
local OverdrawExitDur = 0.4  -- 出场动画时长（秒，同抽牌动画 dur2）

-- 对方视角抽牌直飞时长（2026-08-12）：看对方抽牌 → 直接到手牌、不翻面、无桌中
-- 停留（第二关键帧即手牌位），单段飞行时长同本方抽牌首段（dur1）
local EnemyDrawDirectDur = 0.45

-- 手牌拿起 / 拖拽 / 打出 常量（2026-08-10）：拖拽机制在悬停提升基础上扩展——
-- 按下左键拿起（屏幕投影补偿跟随鼠标、悬停失效、播放「拿起卡牌」音效）；松手
-- 在手牌区域渐变回原位，否则打出（单位进本方支援阵线、指令进战斗系统）。
-- 拖拽视觉位置 = 「鼠标射线 ∩ 抬升 z 平面」交点（2026-08-12 三次修订，见
-- KardsDragCardThink）：抬升 z（手牌扇形最高层 +0.1）保证拿起后高于所有手牌，
-- 射线交点任意屏幕位置（含边缘）投影恒 = 鼠标（ScreenToVector 逆映射），精确无
-- 视差；射线不穿抬升平面（斜视相机指向桌面下方）时回退深度锁定（HandSlotDragVisDist）。
-- 修订史：二次修订（2026-08-11）用「迭代 ToScreen 补偿」修正抬升后 xy，其线性化
-- 步长在屏幕边缘收敛慢、残余偏移明显（2026-08-12 用户反馈），故改为直接求交。
local HandSlotDragVisDist = 72    -- 深度锁定回退距离：射线不穿抬升平面（斜视相机指向桌面下方）时，卡牌原点置于鼠标射线前方 72 单位（≈相机到手牌距离），屏幕投影恒等于鼠标
local HandSlotFlightDur = 0.35    -- 打出飞行动画时长（秒）
local HandSlotReturnDur = 0.2     -- 松手回手牌渐变时长（秒）
local HandSlotReposDur = 0.15     -- 腾位预览 / 布局复位动画时长（秒）
-- 移动 / 撤退位移动画（2026-10-27 用户规格）：基础时长在布局复位时长上延长 1.5 倍，
-- 且时长随位移长度等比缩放 + 线性缓动 → 匀速，距离越远耗时越长、速度不变。
-- 基准位移取支援阵线与前线行距（移动 / 撤退的最小位移），基准时长 = 0.15 × 1.5；
-- 行距惰性读取（cl_init.lua 加载时 Board2D 可能尚未就绪，同 FieldStepX）。
local UnitMoveDurMul = 1.5
local UnitMoveRefDistCache = nil
local function UnitMoveRefDist()
    if not UnitMoveRefDistCache then
        local rowY = KARDS.Animation and KARDS.Animation.Board2D
            and KARDS.Animation.Board2D.RowY
        local span = rowY and math.abs(rowY[1] - rowY[0]) or 0
        UnitMoveRefDistCache = (span > 0.01) and span or 12.8
    end
    return UnitMoveRefDistCache
end

-- 移动 / 撤退动画时长：基准时长 × 实际位移 / 基准位移（下限 0.01 秒防零时长段）
local function UnitMoveAnimDur(fromPos, toPos)
    local base = HandSlotReposDur * UnitMoveDurMul
    local dist = (toPos - fromPos):Length()
    return math.max(base * dist / UnitMoveRefDist(), 0.01)
end
local CounterRiseHeight = 6       -- 反制激活上浮高度（反制系统 M3：反制卡拖出松手时先上浮该值再还原，见 cl_battle_hud.lua CounterClientToggle）
-- 部署飞行动画组（2026-08-12，阶段五 P7 组名英文化）：源卡半程飞行 + 小模型占位
-- + 小模型后半程三段同组并发——同组调度不会被排队机制停顿（切换瞬间源卡销毁、
-- 小模型接管的衔接动画原子完成）
local DeployAnimGroup = "deployFlight"
local SupportLineHover = 4        -- 支援阵线行判定容差（鼠标投影 y 到行 y 的最大距离）
local HandRegionDist = 12         -- 手牌区域判定半径（鼠标投影与手牌扇形位置的水平距离；复用 HandSlotHoverRadius）
-- 手牌点击/悬停命中尺寸（2026-08-11）：拿起与悬停判定从「到中心 3D 距离 <12」改为
-- 「射线命中卡面矩形」——原判定过宽（12 约为卡面半对角线 6.5 的两倍），鼠标指向靠近
-- 手牌的战场单位时会被误判为悬停/拿起手牌。手牌卡面 7.2×10.8（basic_card：卡宽沿
-- 局部 X、卡长沿局部 Y），命中矩形 = 卡面 + 四周容差。
-- 挂 KARDS 命名空间（非顶层 local）：main chunk 局部变量接近 GLua 200 上限
-- （2026-08-11 实测 local 声明会触发超限报错，同 L1588 先例），故不占局部槽。
KARDS.HandHitPad = 1.0                  -- 命中容差（卡面四周外扩单位，可微调）
KARDS.HandHitHalfW = 3.6 + KARDS.HandHitPad -- 命中半宽（卡宽 7.2 / 2 + 容差）
KARDS.HandHitHalfL = 5.4 + KARDS.HandHitPad -- 命中半长（卡长 10.8 / 2 + 容差）

-- 射线是否命中卡面矩形：射线与卡面平面（法线 = 实体 Up，手牌平躺）求交，
-- 交点落在卡面 ±半宽/±半长（含容差）内即命中；用于手牌拿起与悬停判定
-- （替代宽泛的中心距离判定）。命中时额外返回射线参数 t（沿射线到卡面交点的
-- 距离）——重叠扇形卡取 t 最小 = 最先命中 = 视觉最上层卡（z 阶梯层叠，2026-08-14
-- 修复「拿起/悬停选悬停卡左侧卡」：原最近中心距离会选中被上方卡遮挡的卡）。
-- 挂 KARDS 命名空间同理不占局部槽。
function KARDS.RayCardHit(origin, dir, ent, halfW, halfL)
    local plane = ent:GetUp()
    local denom = dir:Dot(plane)
    if math.abs(denom) < 1e-4 then return false end -- 射线与卡面平行（俯视不会发生）
    local t = (ent:GetPos() - origin):Dot(plane) / denom
    if t < 0 then return false end
    local lp = ent:WorldToLocal(origin + dir * t)
    if math.abs(lp.x) <= halfW and math.abs(lp.y) <= halfL then
        return true, t
    end
    return false
end

-- 相机射线（抗视差，2026-08-14 用户规格「握住手牌抗视差」）：Think 钩子中
-- gui.ScreenToVector 基于「上一帧活跃相机」——BattleCamera 经 CalcView 接管渲染时，
-- Think 期间活跃相机常为玩家默认相机（位置/FOV 与渲染相机不同），与 pos=ViewPos
-- （渲染相机位置）组合即产生视差：屏幕中心偏差小、越靠屏幕两侧越大，拿起/悬停
-- 命中与鼠标视觉所指不一致（用户反馈）。BattleCamera 接管时按其相机参数
-- （ViewPos/ViewAng/fov，CalcView 记录、与渲染同源）手动构造透视射线：
--   dir = fwd + right*(nx*tan(φ/2)*aspect) + up*(ny*tan(φ/2))（垂直 FOV 逆投影）
-- 与渲染画面完全一致；未接管时回退玩家默认相机（gui.ScreenToVector 此刻基于默认
-- 相机，恰好正确）。返回 pos, dir；LocalPlayer 无效时返回 nil。挂 KARDS 命名空间
-- 同理不占局部槽。
function KARDS.MouseRay(mx, my)
    local ply = LocalPlayer()
    if not IsValid(ply) then return nil end
    local vp = KARDS.BattleCamera and KARDS.BattleCamera.ViewPos
    local va = KARDS.BattleCamera and KARDS.BattleCamera.ViewAng
    if vp and va then
        local cam = KARDS.BattleCamera.Cameras[ply]
        local fov = (cam and cam.fov) or 75
        local fwd, right, up = va:Forward(), va:Right(), va:Up()
        local nx = (mx / ScrW() - 0.5) * 2 -- 屏幕 x → 归一化设备坐标（右为正）
        local ny = (0.5 - my / ScrH()) * 2 -- 屏幕 y 向下 → 归一化设备坐标（上为正）
        local tan = math.tan(math.rad(fov) * 0.5)
        -- 投影系数（2026-08-14 实测修正，用户 kards_raytest 诊断数据）：GMod 渲染实际
        -- 投影为  tan_h = tan(fov/2) × aspect × 3/4、tan_v = tan(fov/2) × 3/4（16:9 实测
        -- 引擎垂直半角正切 0.5755 = tan(37.5°)×3/4，并非 tan(fov/2) 恒定——旧代码垂直
        -- 用 ny×tan 过修正 1/(3/4)≈1.33 倍，屏幕上下边缘握住的手牌偏出屏幕（用户反馈
        -- 「上下移动为视差、越屏幕边缘几何坐标离鼠标越远」；kards_raytest 实测左上角
        -- ny=1 时 MouseRay 投影 y=-180）。一般化：k = aspect×3/4（4:3 屏幕 =1，退化为
        -- 标准垂直 FOV 语义），tan_h = tan×k、tan_v = tan/k（垂直半角随宽屏收缩）。
        -- 水平系数与旧实现一致（tan×aspect×3/4，已修复「两次反视差」），此处仅改垂直。
        local k = (ScrW() / ScrH()) * (3 / 4)
        local dir = fwd + right * (nx * tan * k) + up * (ny * tan / k)
        if dir:LengthSqr() < 1e-8 then dir = fwd end
        return vp, dir:GetNormalized()
    end
    local dir = gui.ScreenToVector(mx, my)
    if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then
        dir = ply:EyeAngles():Forward()
    end
    return ply:EyePos(), dir
end

-- ====================================================================
-- 重新调度（KARDS.BattleState.mulligan）+ 真实手牌坐标函数（2026-08-10 起，占位空手牌已移除）
-- 状态变量（KARDS.BattleState.mulligan / KARDS.BattleState.mulliganReadySent / 动画表等）声明于文件顶部：先手揭晓
-- 序列结束、对局开始 / 退出重置需在其前引用。此处仅定义依赖手牌常量
-- HandSlot* 的坐标函数。
-- ====================================================================
-- 手牌扇形落位（服务端 ENT:CreateHandCardSlots 同款数学，见《手牌分布的原理.md》
-- §2-§6；动态张数 n = 该槽当前手牌总数——起手发牌 / 补抽 / 后续抽牌 / 重新调度
-- 转手牌一律使用本函数，不得另建手牌分布方法）：
--   位置 = 中心 + X·xl + Y·yl + Up·zl（弧匹配 §3 + z 阶梯；k=(n+1)/2−i 居中对称，
--           i=1 为扇形一端、i 越大越靠另一端）；+yl 弧凸向 +Y = 对方侧（P1 槽 +y、
--           Y=−y → 弧朝 −y；P2 槽 −y、Y=+y → 弧朝 +y），与服务端/文档 §3 一致。
--   角度 = HandSlotAngles[slot]（P1 yaw0 / P2 yaw180 平躺）+ 绕面法线旋转 fan 角
--   ψ=(k/maxIdx)·HandSlotFanAngle（§4 显式半展开角；Rodrigues §5 + roll 修正 §6，
--   逐字对应服务端 CreateHandCardSlots）+ HandSlotTextYaw=180°（文字方向解耦：
--   3D2D 文字顶部沿实体 +Right → 朝向本方，见上方常量区说明，2026-08-10）。
-- @return Vector pos 牌桌局部位置；Angle ang 局部角度（平躺 + 扇形旋转 + 文字朝向）
-- （2026-08-12：改由 L2488 前向占位 local 承接赋值——KardsSwitchSlot 回调引用本函数，
-- 原 local function 声明晚于该回调会解析为全局 nil）
HandFanPos = function(slot, i, n)
    local sign = (slot == 1) and 1 or -1
    local center = HandSlotBase + Vector(0, sign * HandSlotHalfY, 0)
    local base = HandSlotAngles[slot]
    local X, Y = base:Forward(), base:Right()
    local R = HandSlotFanRadius
    local centerIdx = (n + 1) / 2
    local k = centerIdx - i
    local xl = k * HandSlotSpacing
    local yl = R - math.sqrt(math.max(0, R * R - xl * xl))
    local zl = -k * HandSlotZStep -- 阶梯取负：编号大的一侧（k<0）最高层（与服务端 CreateHandCardSlots 同步）
    -- 位置 = 中心 + X·xl + Y·yl + Up·zl（+yl 弧凸向 +Y，与服务端 CreateHandCardSlots
    -- 及《手牌分布的原理.md》§3 一致）：P1 槽 +y、Y=−y → 弧凸向 −y = 对方侧；
    -- P2 槽 −y、Y=+y → 弧凸向 +y = 对方侧。位置基准 HandSlotAngles 保持 0/180——
    -- 曾交换成 180/0 修文字导致整个扇形左右镜像「整体反了」（2026-08-10 实测，
    -- 见上方常量区说明），故不再交换。
    local pos = center + X * xl + Y * yl + base:Up() * zl
    -- 扇形角度（§4-§6）：平躺后面法线朝上、玩家俯视位于正面，ψ 取正（与废弃的
    -- 135° 倾斜 ψ 取负相反）。n=1 时 k=0 → psi=0，maxIdx 兜底 0.5 避免除零。
    local maxIdx = math.max((n - 1) / 2, 0.5)
    local psi = (k / maxIdx) * math.rad(HandSlotFanAngle)
    local up = base:Up()
    local cosP, sinP = math.cos(psi), math.sin(psi)
    local fwd = base:Forward() * cosP + up:Cross(base:Forward()) * sinP
    local rgt = base:Right() * cosP + up:Cross(base:Right()) * sinP
    -- roll 修正公式收敛自 cl_perspective.lua AngleFromBasis（阶段五 P5）
    local total = KARDS.Perspective.AngleFromBasis(fwd, rgt)
    -- 文字方向解耦（2026-08-10）：位置/扇形张开用位置基准（0/180，弧朝向对方），
    -- 文字朝向在最终角度叠加 HandSlotTextYaw（180°：绕面法线转半圈，3D2D 文字
    -- 顶部沿实体 +Right → 朝向本方），避免再交换基准常量导致扇形镜像。
    total.y = total.y + HandSlotTextYaw
    return pos, total
end

-- 手牌重排动画（re.md 重构：由 KARDS.AnimPlayer 关键帧播放器驱动，组名 "handRepos"）
-- 出牌/弃牌后剩余手牌索引重排（RenumberHand）触发，位置+角度平滑过渡到新扇形位；
-- 动画期间 KardsRealHandFacing 跳过（不覆盖角度、不悬停提升）。

-- 重排某槽手牌索引为连续 1..n（按当前索引顺序；打出确认/抽牌后调用，配合手牌数量
-- 变化让扇形分布按新张数收缩/张开），并为每张剩余手牌启动平滑过渡动画：
-- 位置/角度从当前位置渐变到新扇形位（HandFanPos），避免索引跳变导致卡瞬移。
-- @param slot     number 手牌槽位（1/2）
-- @param skipEnt  Entity|nil 跳过该实体（抽牌落位中的新卡：deckDraw 动画接管，
--   不参与重排，避免 Play 替换其飞行动画）
-- @param targetN  number|nil 目标手牌总数（抽牌时服务端已广播新张数，须传入使
--   剩余卡按新张数重排；缺省 = 登记卡数，用于打出/弃牌的张数递减场景）
local function RenumberHand(slot, skipEnt, targetN)
    -- 2026-10-03 联机排查 NEW-12：槽位越界时直接返回（上游接收器漏检时不因索引 nil 报错）
    local map = KARDS.BattleState.realHandCards[slot]
    if not map then return end
    local list = {}
    for e, idx in pairs(map) do
        if IsValid(e) and e ~= skipEnt then list[#list + 1] = { e, idx } end
    end
    table.sort(list, function(a, b) return a[2] < b[2] end)
    local n = targetN or #list
    for i, it in ipairs(list) do
        local e = it[1]
        map[e] = i
        local pos, ang = HandFanPos(slot, i, n)
        -- 2026-08-12 修复（敌方手牌重排闪卡面）：非本方槽目标角度 pitch=180（卡背
        -- 朝上）——HandFanPos 返回 pitch=0（平躺卡面朝上），若该槽手牌经 kards_switch
        -- 代选已 InitDrawCardFace（manifest front=卡面），重排动画期间会正面朝上闪露
        -- 牌面（用户反馈：点击结束回合敌方抽牌重排时闪一帧）。KardsRealHandFacing
        -- 对方分支在动画期间跳过（handRepos 组排除），须在动画目标帧即翻转；未初始化
        -- 卡两面卡背，pitch 180 无副作用（与对方手牌常态卡背姿态一致）。
        if not (KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot) then
            ang.p = 180
        end
        -- 位置/角度 6 值两关键帧（cos 缓动）；首帧快照当前姿态 → 从当前位置渐变到新扇形位
        KARDS.AnimPlayer:Play(e, {
            { t = 0, pos = e:GetLocalPos(), ang = e:GetLocalAngles() },
            { t = HandSlotReposDur, pos = pos, ang = ang },
        }, { group = "handRepos", easing = "cos" })
    end
end
-- 牌桌中间扇形相对坐标（重新调度发牌 / 选择期间显示；不重叠横排，卡宽 7.2 留缝 0.8，
-- 整体 z 抬高于桌面顶 CardZ + 10，浮起明显便于选择；2026-08-13 用户反馈：z 上移，
-- 原 +3.4 浮起不明显）
-- （2026-08-12：改由 L2488 前向占位 local 承接赋值——KardsSwitchSlot 回调引用本函数，
-- 原 local function 声明晚于该回调会解析为全局 nil）
MulliganFanPos = function(i, n)
    local centerIdx = (n + 1) / 2
    -- k 取 centerIdx - i（2026-08-10 反向）：i=1（第一张抽的牌）落视觉左侧
    -- （P1 视角 +x），发牌/补抽从左侧开始往右填卡槽；原 k=i-centerIdx 时
    -- i=1 落 -x（P1 视角右侧），表现为从右开始填
    local k = centerIdx - i
    -- 高度与中槽一致（2026-09-30 统一）：重新调度的卡槽即中槽的 4 槽模式（先手 4 张），
    -- 此前用 CardZ + 10，比中槽低约 2 个单位，扇形与中槽的跨槽动画会出现高度跳变
    return Vector(k * CenterSlotSpacing, 0, CenterSlotZ)
end

-- 抽牌动画（re.md 重构：由 KARDS.AnimPlayer 关键帧播放器驱动，组名 "deckDraw"；
-- 阶段事件：越过桌中停留帧（离开桌中）时回调 StartHandShift）
-- 手牌槽卡左移动画（多实体批量 pos.x 平移，非单实体关键帧，保留原逻辑）：
-- { start, dur, items = { { ent, fromX, dx } } }
local deckDrawShift = nil

-- 本玩家手牌槽卡向左移动部分（抽牌动画阶段 3：为新卡让位）
-- （声明于抽牌接收器之前：onKeyframe 闭包按词法作用域引用，后置声明会解析为全局 nil）
local function StartHandShift()
    if not KARDS.BattleState.inTable then return end
    local sign = (KARDS.BattleState.inTable.slot == 1) and 1 or -1
    local items = {}
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWBool("Kards_IsHandSlotCard", false) then
            local pos = ent:GetLocalPos()
            if (pos.y > 0) == (sign > 0) then -- 本玩家手牌槽（P1 +y / P2 −y）
                items[#items + 1] = { ent = ent, fromX = pos.x, dx = -2.5 }
            end
        end
    end
    deckDrawShift = { start = CurTime(), dur = 0.4, items = items }
end

-- ====================================================================
-- 中槽候选卡悬停抬升（2026-11-01）：中槽展示卡牌的交互（重新调度 / 三选一 / 抉择）
-- 共用同一实现，保证三处悬停手感一致。抬升方向取「卡 → 渲染相机」视线方向
--（抗视差，屏幕投影上呈现为向观察者浮起，而非纯世界 z 上升）；抬升与回落均按
-- 指数缓动过渡（先快后慢）形成上升 / 回落动画。
-- ====================================================================
KARDS.HoverLiftAmount = 0.55   -- 悬停抬升量（世界单位，沿相机视线方向）
KARDS.HoverLiftSpeed = 9       -- 缓动速率（越大越快到位，指数趋近）

--[[
    计算中槽候选卡悬停后的局部坐标（缓动状态按 state.hoverLift 逐帧缓存）。
    @param  ent    卡实体
    @param  base   基础局部坐标（相对牌桌）
    @param  target 目标抬升量（正值抬起，0 回落）
    @param  state  该卡的缓动状态表（读写 hoverLift 字段）
    @param  speed  缓动速率（缺省 KARDS.HoverLiftSpeed）
    @return Vector 应用抬升后的局部坐标
]]
function KARDS.HoverLiftPos(ent, base, target, state, speed)
    local dt = FrameTime()
    local lift = state.hoverLift or 0
    lift = Lerp(1 - math.exp(-dt * (speed or KARDS.HoverLiftSpeed)), lift, target)
    if math.abs(lift - target) < 0.001 then lift = target end
    state.hoverLift = lift
    if lift <= 0 then return base end
    local camPos = (KARDS.BattleCamera and KARDS.BattleCamera.ViewPos) or EyePos()
    local parent = IsValid(ent) and ent:GetParent() or nil
    local dir
    if IsValid(parent) then
        local baseWorld = parent:LocalToWorld(base)
        dir = camPos - baseWorld
        if dir:LengthSqr() > 1e-6 then dir:Normalize() else dir = Vector(0, 0, 1) end
        return parent:WorldToLocal(baseWorld + dir * lift)
    end
    dir = camPos - ent:GetPos()
    if dir:LengthSqr() > 1e-6 then dir:Normalize() else dir = Vector(0, 0, 1) end
    return Vector(base.x + dir.x * lift, base.y + dir.y * lift, base.z + dir.z * lift)
end

-- ====================================================================
-- 跨文件桥接（2026-08-15 修复）：GMod include 为独立编译执行的 chunk，不共享
-- 本文件（cl_init.lua）的词法作用域 —— 被拆出的 cl_battle_mulligan.lua /
-- cl_battle_drag.lua 中的裸名引用会解析为全局 nil 而报错（实测
-- cl_battle_mulligan.lua:556 attempt to call global 'UpdateTableMouse'）。
-- 故本文件将拆分文件所需的文件级 local 值挂到 KARDS 命名空间，拆分文件内
-- 改为经 KARDS.xxx 运行时访问（引用均位于函数体内、运行时求值，晚于本桥接块
-- 执行，无时序问题）。local 本体保留不变，本文件内继续词法使用。
-- ====================================================================
KARDS.UpdateTableMouse = UpdateTableMouse
KARDS.PileBase = PileBase
KARDS.PileYaw = PileYaw
KARDS.battleDeckDrawn = battleDeckDrawn
KARDS.battleHQLeft = battleHQLeft
KARDS.drawFacePending = drawFacePending
KARDS.InitDrawCardFace = InitDrawCardFace
KARDS.HandFanPos = HandFanPos
KARDS.MulliganFanPos = MulliganFanPos
KARDS.CenterSlotPos = CenterSlotPos  -- 中槽（居中展示槽位：xy 牌桌中心 / z 同手牌；重新调度扇形与三选一共用同一高度），见常量区中槽定义
KARDS.PickSlotPos = PickSlotPos      -- 三选一槽位取值函数（中槽槽位族取 n = 3：index 1/2/3 为中左/中/中右，viewSlot 视角槽位），见常量区三选一槽位定义
KARDS.PickDealDur = PickDealDur
KARDS.PickDealStagger = PickDealStagger
KARDS.PickHoverLift = PickHoverLift
KARDS.PickToHandDur = PickToHandDur
KARDS.PickSpinDur = PickSpinDur
KARDS.PickSpinYaw = PickSpinYaw
KARDS.PickSpinDropZ = PickSpinDropZ
KARDS.PickExitDist = PickExitDist
KARDS.PickEnemyShift = PickEnemyShift
KARDS.PickSpecAngle = PickSpecAngle
KARDS.ScryTableZ = ScryTableZ
KARDS.ScryFlipDur = ScryFlipDur
KARDS.ScryToBottomDur = ScryToBottomDur
KARDS.DisplaySlots = DisplaySlots
KARDS.ExitFlyDist = ExitFlyDist
KARDS.OverdrawFlyDur = OverdrawFlyDur
KARDS.OverdrawHold = OverdrawHold
KARDS.OverdrawExitDur = OverdrawExitDur
KARDS.EnemyDrawDirectDur = EnemyDrawDirectDur
KARDS.RenumberHand = RenumberHand
KARDS.StartHandShift = StartHandShift
KARDS.deckDrawShift = deckDrawShift
KARDS.RevealEaseInOut = RevealEaseInOut
KARDS.remoteHandHover = remoteHandHover
KARDS.HandSlotBase = HandSlotBase
KARDS.HandSlotZStep = HandSlotZStep
KARDS.HandSlotTextYaw = HandSlotTextYaw
KARDS.HandSlotDragVisDist = HandSlotDragVisDist
KARDS.HandSlotReturnDur = HandSlotReturnDur
KARDS.HandSlotReposDur = HandSlotReposDur
KARDS.CounterRiseHeight = CounterRiseHeight
KARDS.SupportLineHover = SupportLineHover
KARDS.HandRegionDist = HandRegionDist

-- ====================================================================
-- 重新调度机制（2026-08-15 C1 拆分：KardsTableDeckDraw / KardsReturnToHand /
-- KardsDeckDrawUpdate / KardsMulliganDone / KardsMulliganAnimsUpdate /
-- KardsMulliganAnimDoneNotify / KardsMulliganSelect / 三个重新调度 HUD
-- 已迁移至 cl_battle_mulligan.lua）
include("cl_battle_mulligan.lua")
-- ====================================================================

-- ====================================================================
-- 洗入动画（2026-09-26 缺口 D 拆分：KardsShuffleInto 接收器 + ShuffleAnim
-- 三来源（手牌/场上/凭空生成）三分视角（本方/敌方/观战）动画
-- 已迁移至 cl_battle_shuffle.lua）
include("cl_battle_shuffle.lua")
-- ====================================================================

-- ====================================================================
-- 加入阵线动画（2026-09-26 缺口 F 拆分：KardsJoinAnim 接收器 + 手牌下落 /
-- 观战二次曲线入场 / KARDS.JoinAnim:Target 接入 KardsFieldLayout
-- 已迁移至 cl_battle_join.lua）
include("cl_battle_join.lua")
-- ====================================================================

-- ====================================================================
-- 单位攻击冲刺动画（2026-09-26 缺口 G 拆分：KardsUnitAction 接收器 +
-- 坦克炮兵回弹 / 步兵高频往复两套帧序列
-- 已迁移至 cl_battle_unit_action.lua）
include("cl_battle_unit_action.lua")
-- ====================================================================

-- ====================================================================
-- 老兵升级动画（2026-09-26 缺口 I 拆分：KardsUnitElevate 接收器 + z 上升 /
-- 依次白色飘字 / 回落三段
-- 已迁移至 cl_battle_veteran.lua）
include("cl_battle_veteran.lua")
-- ====================================================================

-- ====================================================================
-- 卡牌转换交接动画（2026-09-26 缺口 J 拆分：KardsUnitConvert 接收器 +
-- 旧卡 z 上升翻面至侧立 / 90° 换显 / 新卡反向回落三段
-- 已迁移至 cl_battle_convert.lua）
include("cl_battle_convert.lua")
-- ====================================================================

-- ====================================================================
-- 延时效果证明动画（2026-11-07 用户规格：延时效果触发时把来源卡从牌桌左边缘移入，
-- 逆时针 + 透视放大，0.8 秒后反向；KardsDelayedProof 接收器 + 副本卡面初始化 +
-- 三段关键帧，见 cl_battle_delayed_proof.lua）
include("cl_battle_delayed_proof.lua")
-- ====================================================================

-- ====================================================================
-- 收缴动画（2026-10-15 用户规格：单位阵亡移除 → 0.5 秒原地重现完整卡 →
-- 0.5 秒飞入收缴方手牌；KardsConfiscateAnim 接收器 + 阵亡等待 / 揭示 / 停留
-- 三段时序，已迁移至 cl_battle_confiscate.lua）
include("cl_battle_confiscate.lua")
-- ====================================================================

-- ====================================================================
-- 结束回合按钮交互 / 绘制（2026-08-11 拆分 B1：KardsEndTurnThink /
-- KardsEndTurnHUD 已迁移至 cl_battle_hud.lua）
-- ====================================================================

-- 手牌悬停提升状态（weak keys）：{ hovered, cur }，cur 为 0..1 的提升进度。
-- 供 KardsRealHandFacing（真实手牌）与 KardsHandSlotFacing（占位槽卡）两个驱动
-- 共用；声明置于两个钩子之前——Lua 词法作用域：钩子函数体引用的名字必须在其
-- 定义处可见，声明在后会被当作全局变量（nil）访问而报错（2026-08-10 实测）。
local handHoverCards = setmetatable({}, { __mode = "k" })

-- 手牌悬停提升状态机（2026-08-15 阶段四 C9 收敛）：KardsRealHandFacing 与
-- KardsHandSlotFacing 两处同构状态机收敛为共享工具——st 存在则更新悬停标记/axis，
-- cur 在 HandSlotHoverDur 秒内逼近目标（悬停 1 / 回落 0），cur>0 时按 axis 位移：
-- "y" 沿自身 y+ 轴（本方悬停）/ "z" 沿父局部 z（远程悬停，增量 0.8 > 扇形 z 阶梯
-- 最大落差 0.3，必为该手牌 z 最高）；回落完成移除登记（交还常规位置，动画定格值）。
-- st 不存在且 isHovered → 记录当前实际位置为基线（冻结，避免逐帧叠加造成无上限
-- 移动）新建登记。axis 仅悬停时更新（回落沿原方向），与原逻辑一致。
-- 返回 true = 状态机已接管该卡位置（调用方跳过自身常规位置/角度覆盖，等价原
-- if st / elseif 悬停 两分支）；false = 无登记且未悬停（调用方做常规修正）。
function KARDS.UpdateHandHover(ent, isHovered, axis)
    local st = handHoverCards[ent]
    if st then
        st.hovered = isHovered
        if isHovered and axis then st.axis = axis end
        local target = st.hovered and 1 or 0
        if st.cur < target then
            st.cur = math.min(st.cur + FrameTime() / HandSlotHoverDur, 1)
        elseif st.cur > target then
            st.cur = math.max(st.cur - FrameTime() / HandSlotHoverDur, 0)
        end
        if st.cur > 0 then
            if st.axis == "z" then
                -- 远程悬停：沿卡面法线（父局部 z）抬升——与扇形 z 阶梯同坐标系
                ent:SetLocalPos(st.base + Vector(0, 0, st.cur * HandSlotHoverLift))
            else
                -- 本方悬停：沿自身 y+ 轴方向移动（yp 为局部 +y；LocalToWorld 换算
                -- 随当前朝向变化，扇形各卡方向略异 → 父局部方向，2026-08-15
                -- C2 收敛至 KARDS.LocalYAxis）
                local yp = KARDS.LocalYAxis(ent)
                ent:SetLocalPos(st.base + yp * (st.cur * HandSlotHoverLift))
            end
        else
            handHoverCards[ent] = nil -- 已回落，交还常规位置（动画定格值）
        end
    elseif isHovered then
        -- 新悬停：记录当前实际位置为基线（动画已结束，位置稳定）
        handHoverCards[ent] = { hovered = true, cur = 0, base = ent:GetLocalPos(), axis = axis }
    end
    return st ~= nil or isHovered
end

-- 总部对局开始动画中的实体判定（hqReveals 声明于上方；本函数供 KardsDragCardThink /
-- KardsFieldLayout 接收 / KardsFieldFacing 共用，须先于这些引用者声明——Lua 词法
-- 作用域：声明在后会被当作全局 nil 访问而报错，2026-08-10 实测）
local function InHQRevealAnim(ent)
    for _, r in ipairs(hqReveals) do
        if r.ent == ent then return true end
    end
    return false
end

-- ====================================================================
-- 支援阵线视觉坐标辅助（2026-08-10 部署落位修复）：
--   阵线整线以 5 列矩阵为中心（联动服务端 GetCenteredStart 居中数组）；当整线
--   卡数（含总部）为偶数时，服务端居中靠左（右端多 1 空槽），客户端展示在服务端
--   槽位基础上整线额外右移 0.5 槽距（列号 +0.5 = x 减半列）——偶数阵线视觉中心
--   正好落在桌面中心（奇数阵线本就居中，无偏移）。参考 sh_battlefield.lua
--   SPACING 常量注释「偶数时右移 0.5*SPACING」。所有战场卡定位（布局复位 /
--   打出飞行 / 部署预览 / 松手复位）统一走本辅助，保证所见即所得。
-- ====================================================================
-- 列距（8.2）：惰性计算并缓存——cl_init.lua 位于 lua/entities/，文件加载时
-- KARDS.Animation.Board2D（lua/kards/sh_animation.lua）可能尚未加载，直接求值会 nil 报错
local fieldStepXCache = nil
local function FieldStepX()
    if not fieldStepXCache then
        fieldStepXCache = math.abs(KARDS.Animation.Board2D.ColX[2] - KARDS.Animation.Board2D.ColX[3])
    end
    return fieldStepXCache
end

-- 由整线卡数 + 槽位列号 → 视觉局部坐标（含偶数 0.5 槽偏移）
local function FieldPosByCount(count, col, row)
    local x = KARDS.Animation.Board2D.ColX[col]
    if count % 2 == 0 then
        x = x - FieldStepX() * 0.5
    end
    return Vector(x, KARDS.Animation.Board2D.RowY[row], KARDS.Animation.Board2D.CardZ)
end

-- 由布局表（KARDS.BattleState.fieldLayouts[slot]：ent → 槽位）+ 目标卡 → 视觉局部坐标（整线卡数含总部）
local function FieldPos(layout, ent, col, row)
    local count = 0
    for e in pairs(layout) do
        if IsValid(e) then count = count + 1 end
    end
    return FieldPosByCount(count, col, row)
end

-- 部署预览位置表：把拖拽单位按落点列插入现有阵线（排秩同服务端 InsertCentered：
-- 落点列左侧现有卡数 = 插入位置），整线按 GetCenteredStart 居中，返回现有各卡的
-- 目标视觉坐标 { [ent] = Vector }（拖拽单位本身跟随鼠标，不在表内）。预览与
-- 服务端居中结果一致，松手后所见即所得。
local function PreviewFieldPositions(layout, dragEnt, dropCol, row)
    local ordered = {}
    for e, si in pairs(layout) do
        if IsValid(e) and e ~= dragEnt then ordered[#ordered + 1] = { e, si } end
    end
    table.sort(ordered, function(a, b) return a[2] < b[2] end)
    local insertAfter = 0 -- 落点列左侧现有卡数（同服务端 InsertCentered 排秩逻辑）
    for _, it in ipairs(ordered) do
        if it[2] < dropCol then insertAfter = insertAfter + 1 end
    end
    local n = #ordered + 1 -- 含拖拽单位后的整线卡数（偶数偏移基准）
    -- 阵线已满（含总部共 SLOT_COUNT 张）：部署必被服务端拒绝（InsertCentered 满员
    -- 返回 false），不产生腾位预览——返回空表，调用方回退各卡当前布局位（卡不动），
    -- 并避免 GetCenteredStart 按 lineSize 截断后落点列越界（ColX[6] 为 nil 崩溃）
    if n > KARDS.Battlefield.SLOT_COUNT then return {} end
    local start = KARDS.Battlefield:GetCenteredStart(n)
    local out = {}
    for k, it in ipairs(ordered) do
        local rank = (k <= insertAfter) and k or (k + 1) -- 拖拽单位插在 insertAfter+1 处
        out[it[1]] = FieldPosByCount(n, start + rank - 1, row)
    end
    return out
end

-- 真实手牌静止朝向兜底（weak 注册表 KARDS.BattleState.realHandCards，动画结束后每帧保持）：
-- 本方卡保持预设扇形角度（HandFanPos：位置基准 + fan 角 + 文字朝向，服务端 CreateHandCardSlots
-- 同款，见《手牌分布的原理.md》）；对方/观战卡保持平躺（两侧卡背图，任何姿态看到的
-- 都是卡背，不改角度），仅确保可见。动画中的卡跳过（动画驱动接管）。
-- 悬停 y 变化（2026-08-10）：占位空手牌移除后，把原手牌槽卡（服务端 CreateHandCardSlots
-- 创建）的悬停提升机制补回真实手牌——鼠标悬停本方某张手牌时，该卡沿自身 y+ 轴在
-- HandSlotHoverDur 秒内移动 HandSlotHoverLift（离开同样时长回落），机制与
-- KardsHandSlotFacing 占位卡同款（handHoverCards 状态表 + 射线最近距离判定）。
-- 单张真实手牌每帧驱动（2026-08-15 阶段四 C9 拆分）：跳过判定（拖拽中 / 待打出
-- 确认 / 重排动画中的卡位置角度由拖拽钩子或飞行/返回动画接管）+ 悬停提升（共享
-- 状态机 KARDS.UpdateHandHover）+ 角度驱动（本方 HandFanPos 扇形角度 / 对方
-- drawFaceReady pitch 180 兜底）
local function RealHandFacingCard(view, slot, mine, n, ent, idx, hoveredEnt)
    if not IsValid(ent) or ent == KARDS.BattleState.pendingPlayEnt
        -- 2026-10-03 联机排查 NEW-2/NEW-9：跳过条件由枚举组名改为「任一动画在播」。
        -- 枚举必然漏项（洗入 shuffleInto、三选一 pickResult 就漏了），漏掉时动画收尾的
        -- SetNoDraw(true) 会被本函数下方的兜底显隐复活，同一张卡三方表现不一致。
        or KARDS.AnimPlayer:Active(ent)
        or (KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == ent) then
        return
    end
    if ent:GetNoDraw() then ent:SetNoDraw(false) end
    -- 悬停提升（本方鼠标悬停 / 远程对方悬停均驱动；与 KardsHandSlotFacing 占位卡
    -- 同款状态机，已收敛至 KARDS.UpdateHandHover）。提升方向：本方悬停（view 与
    -- slot 一致）沿自身 y+ 轴（2026-08-10 反向后沿 +y 提升）；远程悬停（对方在
    -- P1/P2 视角、双方在观战视角，经 KardsHandHover 广播）沿 z 抬升——需求 2
    -- 「敌方悬停 z 增加为手牌中最高」、需求 3「观战视角同样增量」。
    local localHover = (view == 1 or view == 2) and slot == view and ent == hoveredEnt
    local remoteHover = remoteHandHover[slot] == ent
    KARDS.UpdateHandHover(ent, localHover or remoteHover, localHover and "y" or "z")
    if mine then
        -- 与动画定格同一预设扇形角度（n=当前手牌数；动画全部结束后 n 与登记时
        -- total 一致，角度不跳变）
        local _, ang = HandFanPos(slot, idx, n)
        local cur = ent:GetLocalAngles()
        if math.abs(cur.p - ang.p) > 0.01 or math.abs(cur.y - ang.y) > 0.01
            or math.abs(cur.r - ang.r) > 0.01 then
            ent:SetLocalAngles(ang)
        end
    elseif drawFaceReady[ent] then
        -- 对方/观战视角看本方切过的卡（kards_switch 已 InitDrawCardFace 初始化
        -- 卡面，manifest front=卡面）：绕卡长轴翻转 180°（pitch 180）使卡背
        -- （back 子网格，真实卡背图）朝上——恢复卡背不改 manifest（2026-08-12
        -- kards_switch 切换不干净修复：切回后对方手牌不再正面朝上泄漏牌面）。
        -- 每帧兜底：kards_switch 切离时已即时翻转，此处覆盖动画终帧/后续
        -- 抽牌动画终帧（pitch=0）残留。未初始化卡两面卡背（front=back=usa）
        -- 任何姿态均为卡背，跳过；3D2D 文字随实体朝向下翻不可见。
        local cur = ent:GetLocalAngles()
        if math.abs(cur.p - 180) > 0.01 then
            ent:SetLocalAngles(Angle(180, cur.y, cur.r))
        end
    end
end

hook.Add("Think", "KardsRealHandFacing", function()
    -- 悬停检测（仅 P1/P2 视角 + 本方真实手牌）：相机射线命中手牌卡面矩形才算
    -- 悬停（2026-08-11 改，替代宽泛的中心距离）；重叠扇形卡取最先命中（t 最小）＝
    -- 视觉最上层卡（2026-08-14 修复：原最近中心距离会选中被上方卡遮挡的左卡，
    -- 且 `local bestD, hoveredEnt` 在 if 块内重复声明遮蔽外层导致悬停提升从未
    -- 生效）；观战/未进入牌桌不悬停
    local view = KARDS.Perspective and KARDS.Perspective.LocalView
    local hoveredEnt = nil
    if view == 1 or view == 2 then
        local ply = LocalPlayer()
        if IsValid(ply) and not gui.IsConsoleVisible() and not gui.IsGameUIVisible() then
            local pos, dir = KARDS.MouseRay(gui.MouseX(), gui.MouseY())
            -- 2026-08-15 C2：命中测试收敛至 KARDS.HandHitTest（skipBusy=true：busy 判定
            -- = IsHandBusy，与原内联的 pendingPlayEnt + 4 组动画 + dragCard 过滤一致）
            hoveredEnt = KARDS.HandHitTest(pos, dir, view, true)
        end
    end
    -- 悬停广播（2026-08-14，需求 2/3）：本方悬停变化时发给服务端中继（对方+观战者
    -- 据此显示敌方悬停 z 抬升）；仅 P1/P2 视角、对局进行中发送；无悬停发 NULL 清除
    if (view == 1 or view == 2) and hoveredEnt ~= lastSentHover then
        lastSentHover = hoveredEnt
        local tbl = KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent
        if IsValid(tbl) and KARDS.BattleState.battleStarted then
            net.Start("KardsHandHover")
                net.WriteEntity(tbl)
                net.WriteEntity(hoveredEnt or NULL)
            net.SendToServer()
        end
    end
    for slot = 1, 2 do
        local mine = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot
        local n = KARDS.HandCount(slot) -- 2026-08-15 C2：内联计数收敛至共享工具
        for ent, idx in pairs(KARDS.BattleState.realHandCards[slot]) do
            RealHandFacingCard(view, slot, mine, n, ent, idx, hoveredEnt)
        end
    end
end)

-- ====================================================================
-- 悬停卡牌复制预览（2026-08-10，见 .trae/documents/悬停卡牌复制预览机制.md）：
--   鼠标悬停在本方手牌或双方战场卡上持续 HoverPreviewDelay 秒后，客户端本地创建
--   一份复制卡（local entity：客户端本地创建、不同步服务端/其他客户端 → 天然仅
--   悬停者本人可见）；手牌复制卡沿源卡自身 +y 轴方向置于原卡上方（xy 平面偏移
--   HoverPreviewHandLift——俯视投影下 z 偏移无 xy 位移，2026-08-11 起改为沿 +y，
--   与手牌悬停提升同向）、角度对齐牌桌但保持可读（2026-08-11：不再跟随手牌
--   扇形 yaw，P1 视角牌桌局部 180 / P2 视角 0，卡面正对各自玩家）；战场复制卡
--   置于原卡右侧（牌桌局部 +x，偏移 HoverPreviewFieldX）+ z 额外增量；
--   鼠标停止悬停（或切换到另一张卡）立即销毁复制卡。
--   源卡范围：本方手牌 KARDS.BattleState.realHandCards（仅 P1/P2 视角，观战不预览手牌）+ 双方战场卡
--   KARDS.BattleState.fieldLayouts（含总部）。拖拽中 / 先手揭晓 / 重新调度 / 动画中的卡不预览。
--   依赖（均声明于本节之前）：HandSlotHoverRadius(L2193) / KARDS.BattleState.realHandCards(L103) /
--   KARDS.BattleState.fieldLayouts(L137) / KARDS.BattleState.dragCard、KARDS.BattleState.pendingPlayEnt / KARDS.AnimPlayer（动画 busy 判定）/
--   hqReveals(L1973) / InHQRevealAnim(L2718) / KARDS.HitTest（射线与命中统一模块）/
--   KARDS.DeckFindCardInfo(L1516) / KARDS.CardTextOverlay。
-- ====================================================================
local HoverPreviewDelay = 0.4      -- 悬停持续时间阈值（秒）：达到后创建复制卡
local HoverPreviewHandLift = 12    -- 手牌复制卡沿源卡自身 y+ 轴方向的偏移距离（xy 平面，俯视位于原卡上方；
                                   -- 2026-08-11 起由 z 增量改为沿 +y——俯视投影下 z 偏移无 xy 位移；
                                   -- 2026-08-11 由 8 增到 12：卡长 10.8，间隙 1.2 基本分离）
local HoverPreviewZField = 8       -- 战场复制卡 z 增量（高于桌面顶 CardZ=18.43）
local HoverPreviewFieldX = 7.2     -- 战场复制卡 x+ 偏移（卡宽，右移一张卡位不遮挡原卡）
local HoverFieldHoverRadius = 14   -- 战场卡悬停判定半径（卡 7.2×10.8，手牌复用 HandSlotHoverRadius=12）
local HoverPreviewFieldPitch = 8   -- 战场复制卡 pitch 倾斜（°）：对抗俯视 z 视差——本方战场卡
                                   -- 上端朝本方（+y）抬起、对方朝对方（−y）对称倾斜；数值可调

-- 复制卡预览状态（单例，同一时刻最多悬停一张卡）：
--   { ent = 源卡, hand = 是否手牌（决定偏移方向）, slot = 源卡槽位（战场卡 pitch 方向
--    判定：1 本方 + / 2 对方 −）, copy = 复制实体,
--     hoverStart = 悬停开始时刻, valid = 复制卡是否已创建 }
local hoverPreview = nil

-- 源卡是否可预览：有效实体 + 有卡面 modelID + 不在动画/拖拽中（动画位置由对应钩子
-- 接管、拖拽中位置跟随鼠标，预览跟随会错位；重新调度保留牌落位动画同理）
local function HoverPreviewCardCanShow(src)
    if not IsValid(src) then return false end
    if src:GetNWString("Kards_DeckModelID", "") == "" then return false end
    if KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == src then return false end
    if src == KARDS.BattleState.pendingPlayEnt then return false end
    if KARDS.AnimPlayer:Active(src, DeployAnimGroup, "dragReturn", "handRepos", "mulliganToHand", "deckDraw") then return false end
    if InHQRevealAnim(src) then return false end
    return true
end

-- 创建复制卡（local entity）：复制原卡 modelID（手牌/战场卡面已被 manifest 改写为
-- 真实卡面，同 modelID 直接 ApplyImportedModel 即显示卡面）+ 绑定 3D2D 文字（与原卡
-- 一致的本地外观表 AddLocal；appearance 缺失不绑，与原卡行为一致）。失败返回 nil
local function HoverPreviewCreate(src)
    -- 客户端无 ents.Create（服务端专用），本地复制卡须用 ents.CreateClientside；
    -- 客户端实体亦无 ApplyImportedModel（外部前置模组 init.lua 服务端专用），
    -- 改为直接写实体 datatable（shared.lua SetupDataTables 定义 PMXModelID /
    -- PMXScale / PMXColor）：cl_init.lua 的 Think（_lastModelID 比对）会自动更新
    -- 渲染包围盒，Draw 按 PMXModelID 取 renderable 渲染
    local copy = ents.CreateClientside("sent_pmx_static_imported")
    if not IsValid(copy) then return nil end
    copy:SetPos(src:GetPos())
    copy:SetAngles(src:GetAngles())
    copy:Spawn()
    local modelID = src:GetNWString("Kards_DeckModelID", "")
    if modelID == "" or not copy.SetPMXModelID then
        copy:Remove()
        return nil
    end
    copy:SetPMXModelID(modelID)
    copy:SetPMXScale(KARDS.BattleRender.Defaults.CardScale)
    -- 客户端实体 SetupDataTables 的 SERVER 分支不执行（PMXColor 缺省 Vector(0,0,0)），
    -- 需显式置白，与前置模组服务端默认一致，避免复制卡渲染变黑
    copy:SetPMXColor(Vector(1, 1, 1))
    -- 抑制状态随源卡同步：Kards_UnitKeywords 含 neutralized 时，3D2D 描述层绘制删除线
    copy:SetNWString("Kards_UnitKeywords", src:GetNWString("Kards_UnitKeywords", ""))
    -- 无碰撞无物理（同原卡）
    copy:SetSolid(SOLID_NONE)
    local phys = copy:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    local appearance, _, textureSize = KARDS.DeckFindCardInfo(KARDS.GetCardIdentity(src)) -- 手牌卡面定向表优先（2026-08-18，规划 B1）
    if appearance and KARDS.CardTextOverlay then
        local texW, texH = 300, 400
        if textureSize and textureSize.w and textureSize.h then
            texW, texH = textureSize.w, textureSize.h
        end
        KARDS.CardTextOverlay:AddLocal(copy, appearance, 7.2, 10.8, texW, texH)
    end
    return copy
end

-- 销毁复制卡（含 3D2D 文字叠加；下次悬停覆盖时复用）
local function HoverPreviewDestroy()
    if not hoverPreview then return end
    if IsValid(hoverPreview.copy) then
        if KARDS.CardTextOverlay then KARDS.CardTextOverlay:Remove(hoverPreview.copy) end
        hoverPreview.copy:Remove()
    end
    hoverPreview = nil
end

-- 每帧：悬停射线检测（统一走 KARDS.HitTest）+ 复制卡生命周期管理
hook.Add("Think", "KardsHoverCardPreview", function()
    local now = CurTime()
    -- 仅进入牌桌且对战已开始；先手揭晓 / 重新调度 / 拖拽期间不预览
    --（同 KardsEndTurnVisible 开场动画条件 + 拖拽整体排除）
    if not KARDS.BattleState.inTable or not KARDS.BattleState.battleStarted or KARDS.BattleState.reveal or KARDS.BattleState.mulligan or KARDS.BattleState.dragCard then
        HoverPreviewDestroy()
        return
    end
    local ply = LocalPlayer()
    if not IsValid(ply) or gui.IsConsoleVisible() or gui.IsGameUIVisible() then
        HoverPreviewDestroy()
        return
    end
    local pos, dir = KARDS.HitTest.MouseRay()
    if not pos then
        HoverPreviewDestroy()
        return
    end
    local view = KARDS.Perspective and KARDS.Perspective.LocalView
    -- 扫描候选（取最近距离）：本方手牌（仅 P1/P2 视角）+ 双方战场卡（含总部）
    local bestD, bestEnt, bestHand, bestSlot = math.huge, nil, false, nil
    if view == 1 or view == 2 then
        -- 手牌候选：射线命中卡面矩形才参与（2026-08-11 改，替代中心距离 12——
        -- 过宽会抢走靠近手牌的战场单位预览）；重叠扇形卡先取最先命中（t 最小）＝
        -- 视觉最上层卡（2026-08-14 修复悬停预览卡错位），再以中心距离与战场竞争
        -- 2026-08-15 C2：收敛至 KARDS.HandHitTest（skipBusy=false：预览不跳过动画中的卡，保持原行为）
        local be = KARDS.HandHitTest(pos, dir, view, false)
        if be and HoverPreviewCardCanShow(be) then
            local _, d = KARDS.HitTest.NearestInRay(pos, dir, { be }, math.huge)
            bestD, bestEnt, bestHand, bestSlot = d, be, true, view
        end
    end
    -- 战场卡按槽位各取最近，再与手牌候选比较中心距离
    for slot = 1, 2 do
        local ent, d = KARDS.HitTest.NearestInRay(pos, dir, KARDS.BattleState.fieldLayouts[slot] or {},
            HoverFieldHoverRadius * HoverFieldHoverRadius, HoverPreviewCardCanShow)
        if ent and d < bestD then
            bestD, bestEnt, bestHand, bestSlot = d, ent, false, slot
        end
    end
    -- 无命中 / 命中目标切换 → 销毁旧复制（切换后重新计时）
    if not bestEnt then
        HoverPreviewDestroy()
        return
    end
    if not hoverPreview or hoverPreview.ent ~= bestEnt or hoverPreview.hand ~= bestHand then
        HoverPreviewDestroy()
        hoverPreview = { ent = bestEnt, hand = bestHand, slot = bestSlot, copy = nil, hoverStart = now, valid = false }
    end
    -- 持续悬停达阈值且复制卡未创建 → 创建（失败静默，下帧重试）
    if hoverPreview and not hoverPreview.valid and now - hoverPreview.hoverStart >= HoverPreviewDelay then
        hoverPreview.copy = HoverPreviewCreate(hoverPreview.ent)
        hoverPreview.valid = hoverPreview.copy ~= nil
    end
    -- 每帧同步复制卡位置/角度（源卡是子物体：父局部坐标 + 牌桌变换；无父则直接世界坐标）
    if hoverPreview and hoverPreview.valid and IsValid(hoverPreview.copy) and IsValid(hoverPreview.ent) then
        local src = hoverPreview.ent
        local parent = src:GetParent()
        local localPos
        if IsValid(parent) then
            localPos = parent:WorldToLocal(src:GetPos())
        else
            localPos = src:GetPos()
        end
        -- 偏移：手牌 → 沿源卡自身 y+ 轴方向（xy 平面，俯视位于原卡上方——俯视投影
        -- 下 z 偏移无 xy 位移，2026-08-11 用户澄清；与手牌悬停提升同向，见
        -- KardsRealHandFacing 的 yp 计算）；战场 → 桌面固定 +x + z 上方
        if hoverPreview.hand then
            -- 2026-08-15 C2：局部 +y 方向收敛至 KARDS.LocalYAxis（含父局部换算）
            local yp = KARDS.LocalYAxis(src)
            localPos = localPos + yp * HoverPreviewHandLift
        else
            localPos = localPos + Vector(HoverPreviewFieldX, 0, HoverPreviewZField)
        end
        if IsValid(parent) then
            hoverPreview.copy:SetPos(parent:LocalToWorld(localPos))
        else
            hoverPreview.copy:SetPos(localPos)
        end
        if hoverPreview.hand then
            -- 复制手牌：对齐牌桌但保持可读（2026-08-11 用户要求）——不再跟随悬停手牌
            -- yaw（原卡角度 = 槽位基准 0/180 + 扇形旋转 ψ + 文字朝向 180，跟随会让复制卡
            -- 随扇形歪斜），改为牌桌局部固定朝向：P1 视角 180 / P2 视角 0（与战场卡同向；
            -- 保留 HandSlotTextYaw 文字朝向——文字顶朝各自玩家、卡面内容不倒置，避免此前
            -- 整体 yaw 归 0 时 P1 视角卡面内容倒置朝下的问题）。平躺（pitch/roll 归零）
            -- + 牌桌世界 yaw（复制卡非父实体，须换算到世界系）
            local parentAng = IsValid(parent) and parent:GetAngles() or Angle(0, 0, 0)
            local textYaw = (hoverPreview.slot == 1) and 180 or 0
            hoverPreview.copy:SetAngles(Angle(0, parentAng.y + textYaw, 0))
        else
            -- 复制战场卡：pitch 对抗俯视 z 视差——本方（slot 1）上端朝本方 +y 抬起、
            -- 对方（slot 2）朝对方 −y 对称倾斜；yaw 保持原卡（ApplyFacing 驱动：
            -- P1 视角 180 / P2 视角 0，文字方向与原卡一致）
            local srcAng = src:GetAngles()
            local pitch = (hoverPreview.slot == 1) and HoverPreviewFieldPitch or -HoverPreviewFieldPitch
            hoverPreview.copy:SetAngles(Angle(pitch, srcAng.y, srcAng.r))
        end
    end
end)

-- ====================================================================
-- 跨文件桥接（续，2026-08-15）：下述 local 声明晚于 cl_battle_mulligan.lua 的
-- include 点，于此处补挂供 cl_battle_drag.lua 使用（cl_init.lua 自身词法使用不变）
-- ====================================================================
KARDS.handHoverCards = handHoverCards
KARDS.InHQRevealAnim = InHQRevealAnim
KARDS.FieldPos = FieldPos
KARDS.PreviewFieldPositions = PreviewFieldPositions

-- ====================================================================
-- 手牌拿起 / 拖拽 / 打出（2026-08-15 C1 拆分：KardsDragCardThink / KardsHandHover /
-- KardsDragSync / KardsDragEnd / KardsRemoteDragThink 已迁移至 cl_battle_drag.lua）
include("cl_battle_drag.lua")
-- ====================================================================

-- ====================================================================
-- 指令卡打出动画（2026-08-12，阶段 C；更名）：展示槽（打出方视角左侧）停留 →
-- 左下出场 + 队列管理
--   · 队列登记：KardsCardPlayed landed=0 时入队尾（commandAnimQueue）
--   · 已有 ≥2 个未结束动画（含本卡 ≥3）→ 最早指令直接出场（跳过后台等待）
--   · 已有 1 个未结束动画（含本卡 =2）→ 前一指令停留达 CommandHoldGate（1s）后
--     z 下移 CommandZDn（2026-08-13 特殊处理：停留未达 1s 时 z 下移暂不生效，后一
--     指令与本卡的 z 下移替换动画一起 delay 等待至该时刻；delay 期间前一指令保持
--     停留姿态，视觉上无跳跃）
--   · 本卡：当前位置 → 展示槽（CommandToSlotDur）→ 停留至 CommandHoldDur →
--     左下出场（CommandExitDur）；开始前若前一指令停留未达 CommandHoldGate 则
--     delay 等待（达 1s 即放行，不必等前一指令完全出场）
--   · onComplete：从队列移除 + 通知服务端销毁实体（C3，仅本方槽位发送）
-- ====================================================================
local function RemoveFromCommandQueue(q, ent)
    for i, e in ipairs(q) do
        if e == ent then
            table.remove(q, i)
            break
        end
    end
end

-- 指令卡动画停留时长（秒，2026-08-13）：自到达展示槽（动画 t=CommandToSlotDur）起算；
-- delay 等待未开始时为负。用于 CommandHoldGate 放行判定（后一指令开始 / z 下移生效）
local function CommandHoldOf(ent)
    local pc = KARDS.AnimPlayer:Get(ent)
    if not pc or not pc.start then return 0 end
    return CurTime() - pc.start - CommandToSlotDur
end

-- 指令出场完成通知：本卡动画结束 → 服务端据此销毁实体（C3；仅本方槽位发送，
-- 对方/观战端的 KardsCardPlayed 也驱动同款动画，但不通知，服务端只收一次）
local function NotifyCommandExited(slot, cardEnt)
    if not IsValid(cardEnt) then return end
    local inTable = KARDS.BattleState.inTable
    if inTable and IsValid(inTable.ent) and inTable.slot == slot then
        net.Start("KardsCommandExit")
            net.WriteEntity(inTable.ent)
            net.WriteEntity(cardEnt)
        net.SendToServer()
    end
end

-- 播放指令卡出场动画（含队列管理，见上）
-- @param slot    number 打出方槽位（1/2；展示槽取打出方视角左侧，出场终点向观者侧偏移按打出方取符号）
-- @param cardEnt Entity 指令卡实体（已从手牌登记移除）
local function PlayCommandExitAnim(slot, cardEnt)
    if not IsValid(cardEnt) then return end
    local q = KARDS.BattleState.commandAnimQueue
    local exitPos = CommandExitPosFor(slot)
    local slotPos = DisplaySlots[CommandSlotFor(slot)].pos -- 指令展示槽（打出方视角左侧）
    table.insert(q, cardEnt)
    -- 已有 ≥2 个未结束动画（含本卡 = ≥3）→ 最早指令直接出场（跳过后台等待）
    if #q >= 3 then
        local oldest = q[1]
        RemoveFromCommandQueue(q, oldest) -- 直接出场接管其队列席位（实体失效先出队）
        if IsValid(oldest) then
            KARDS.AnimPlayer:Stop(oldest)
            KARDS.AnimPlayer:Play(oldest, {
                { t = 0 },
                { t = CommandExitDur, pos = exitPos, easing = "easeOut" },
            }, {
                group = "commandExit",
                noQueue = true, -- 直接出场：免排队立即播放（跳过后台等待）
                onComplete = function()
                    NotifyCommandExited(slot, oldest)
                end,
            })
        end
    end
    -- 本卡开始延迟（2026-08-13 特殊处理）：前一指令停留未达 CommandHoldGate 时，
    -- 后一指令等待至其停留达 1s 才允许开始（不必等其完全出场）；z 下移同此延迟。
    local startDelay = 0
    -- 已有 1 个未结束动画（含本卡 = 2）→ 前一指令：停留达 CommandHoldGate 后 z 下移
    if #q >= 2 then
        local prev = q[#q - 1]
        if IsValid(prev) then
            local hold = CommandHoldOf(prev)
            if hold < CommandHoldDur then -- 前一指令仍停留阶段才处理（出场中不打扰）
                if hold < CommandHoldGate then
                    -- 停留未达 1s：z 下移暂不生效，与后一指令一起等待至停留达 1s
                    startDelay = CommandHoldGate - hold
                end
                local prevPos = prev:GetLocalPos()
                local zDnPos = Vector(prevPos.x, prevPos.y, slotPos.z - CommandZDn)
                local holdRemain = math.max(0, CommandHoldDur - (hold + startDelay))
                KARDS.AnimPlayer:Play(prev, {
                    { t = 0 },
                    { t = 0.2, pos = zDnPos, easing = "cos" },
                    { t = 0.2 + holdRemain, pos = zDnPos },
                    { t = 0.2 + holdRemain + CommandExitDur, pos = exitPos, easing = "easeOut" },
                }, {
                    group = "commandExit",
                    delay = startDelay, -- 停留达 CommandHoldGate 时 z 下移生效
                    onComplete = function()
                        RemoveFromCommandQueue(q, prev)
                        NotifyCommandExited(slot, prev)
                    end,
                })
            end
        end
    end
    -- 本卡：当前位置 → 展示槽 → 停留至 CommandHoldDur → 左下出场
    --（delay 等待前一指令停留达 CommandHoldGate；期间保持打出时的位置姿态）
    KARDS.AnimPlayer:Play(cardEnt, {
        { t = 0 },
        { t = CommandToSlotDur, pos = slotPos, easing = "cos" },
        { t = CommandHoldDur, pos = slotPos },
        { t = CommandHoldDur + CommandExitDur, pos = exitPos, easing = "easeOut" },
    }, {
        group = "commandExit",
        delay = startDelay,
        onComplete = function()
            RemoveFromCommandQueue(q, cardEnt)
            NotifyCommandExited(slot, cardEnt)
        end,
    })
end

-- 打出确认（服务端 OnPlayCard 广播）：本方收尾拖拽动画、对方/观战同步战场卡。
-- 单位（landed>0）：登记战场布局 + 打出手牌 → 目标格飞行（角度交由 KardsFieldFacing
-- 接管）；指令（landed=0）：展示槽（打出方视角左侧）停留 → 左下出场（阶段 C，见 PlayCommandExitAnim）。
-- 单位部署动画（2026-08-15 阶段四 C6）：KardsCardPlayed 接收器 landed>0 分支拆出——
-- 源手牌实体 cardEnt 飞半程 → 切换小模型 unitEnt（应用单位外貌 + 3D2D 单位文字 +
-- 隐蔽卡背）→ 小模型继续飞后半程落位；两段同组 DeployAnimGroup 并发无停顿。
-- 上下文（fieldLayouts / FieldPos / CardManifest / AnimPlayer / CardTextOverlay）均
-- 为 cl_init.lua 文件级 local 或 KARDS 命名空间，与接收器同文件词法可达。
local function CardPlayedDeploy(ent, slot, cardEnt, landed, unitEnt, placeSnd, deploySnd)
    -- 单位：登记战场槽位 + 两阶段飞行动画（2026-08-12 半程切换小模型）
    -- 阶段 1（0→总部署动画一半）：源手牌实体 cardEnt 从当前位置飞至半程中点
    --   （阶段 1 动画终点 = 总时长一半处）；到达后源卡在中点切换为小卡牌模型
    --   unitEnt（应用单位外貌），通知服务端后销毁，小模型继续飞后半程。
    --   两段动画同组 DeployAnimGroup（"deployFlight"）：同组并发调度，切换瞬间
    --   不会被排队机制停顿。
    KARDS.BattleState.fieldLayouts[slot][cardEnt] = landed
    local row = (slot == 1) and 1 or -1
    local targetPos = FieldPos(KARDS.BattleState.fieldLayouts[slot], cardEnt, landed, row)

    -- 准备客户端本地 unit manifest（渲染按客户端 DATA 读 manifest；单机与服务器
    -- 同 DATA 时幂等）+ UV 裁切材质预填（切换前同步完成，避免切换瞬间白屏）
    local safeName = cardEnt:GetNWString("Kards_DeckSafeName", "")
    local unitModelID = "kards_unit_" .. safeName
    -- 以服务端实体 modelID 为准（2026-08-11 修复）：MaterialCache key =
    -- modelID|子网格|imagePath 大小写敏感，而本处 NW safeName 与服务端
    -- DeckSafeName 推导出的 modelID 大小写可能不一致（编辑器 ID 大写 hex /
    -- battle 文件名小写），导致预填的 UV 裁切材质 miss、贴图拉伸铺满正面。
    -- 实体 GetPMXModelID() 与渲染同源，故预填/清缓存均以它为准。
    if IsValid(unitEnt) and unitEnt.GetPMXModelID then
        local entModelID = unitEnt:GetPMXModelID()
        if entModelID and entModelID ~= "" then
            unitModelID = entModelID
        end
    end
    if safeName ~= "" and KARDS.CardManifest and KARDS.CardManifest.CloneUnit then
        KARDS.CardManifest.CloneUnit(unitModelID, "kards_deck/" .. safeName)
        if PMXStaticImporter and PMXStaticImporter.ClearCache then
            PMXStaticImporter.ClearCache(unitModelID)
            KARDS.PrefillUnitCrop(unitModelID)
        end
    end

    local halfDur = HandSlotFlightDur / 2
    -- 放牌音效（2026-08-14）：放置在场动作直接播放——飞行开始时立即播放，
    -- 与部署无关（指令卡 placeSnd 恒空串不播放）；2D 全屏（sound.PlayFile）
    if placeSnd ~= "" and KARDS.PlaySoundPath then
        KARDS.PlaySoundPath(placeSnd)
    end
    if IsValid(unitEnt) then
        -- 半程中点（局部坐标）：源卡当前局部位置与落位点的中间。cos 缓动下
        -- 两段各自 easeInOut、时程各半，拼接视觉为一条平滑飞行曲线。
        local startLocal = cardEnt:GetLocalPos()
        local midPos = (startLocal + targetPos) * 0.5
        -- 半程前小模型暂不显示（服务端实体创建于手牌位，提前显形会在右侧出现）；
        -- 并占位同组动画，使 KardsFieldLayout 的「部署单位」忙碌判定跳过它——
        -- 防止布局广播提前把小模型复位到落位点（原 bug：小卡从右侧平移过原位）
        unitEnt:SetNoDraw(true)
        KARDS.AnimPlayer:Play(unitEnt, {
            { t = 0, pos = unitEnt:GetLocalPos() },
            { t = HandSlotFlightDur, pos = unitEnt:GetLocalPos() },
        }, { group = DeployAnimGroup })
        -- 阶段 1：源卡飞半程；切换由动画完成回调 onComplete 驱动（2026-08-12
        -- 队列系统：动画可能排队，挂钟 timer.Simple 会在阶段 1 尚未开播时提前
        -- 触发，故改为动画完成同步）
        KARDS.AnimPlayer:Play(cardEnt, {
            { t = 0 },
            { t = halfDur, pos = midPos, easing = "cos" },
        }, {
            group = DeployAnimGroup,
            onComplete = function()
                if not IsValid(unitEnt) then
                    -- 回退：unit 实体已失效，源卡继续飞后半程（保留显示与文字）
                    print("[Kards] unit 战场实体已失效，源卡继续飞后半程")
                    KARDS.AnimPlayer:Play(cardEnt, {
                        { t = 0 },
                        { t = halfDur, pos = targetPos, easing = "cos" },
                    }, { group = DeployAnimGroup })
                    return
                end
                -- 小模型落位半程中点（源卡当前所在位置），应用单位外貌
                unitEnt:SetLocalPos(midPos)
                if IsValid(cardEnt) then
                    unitEnt:SetAngles(cardEnt:GetAngles())
                end
                -- 隐蔽单位（2026-08-13）：部署落位背面朝上（pitch=180 显示卡背，
                -- 不渲染正面——3D2D 文字 hideWhenBack 在 pitch>90 时不绘制）。动画
                -- 终点即卡背朝上；KardsFieldFacing 每帧只改 yaw 保留 pitch，故此处
                -- 设定后隐蔽期始终保持卡背朝上（揭示翻面见 cl_battle_stealth.lua）
                local hidden = unitEnt:GetNWBool("Kards_IsHidden", false)
                if hidden then
                    local ua = unitEnt:GetLocalAngles()
                    unitEnt:SetLocalAngles(Angle(180, ua.y, ua.r))
                end
                unitEnt:SetNoDraw(false)
                -- 部署音效（2026-08-14）：只有单位变身为小模型单位（本时刻）才算
                -- 部署——半程切换完成即播放；2D 全屏（sound.PlayFile）
                if deploySnd ~= "" and KARDS.PlaySoundPath then
                    KARDS.PlaySoundPath(deploySnd)
                end

                -- 3D2D 文字：单位模式（仅攻击/防御/行动花费，行动花费替代卡牌花费位置）
                if KARDS.CardTextOverlay then
                    -- 闪卡判定：由源卡身份取外观模板，供文字层配色（2026-10-04，见 EntryIsFlash）
                    local unitApp = (KARDS.DeckFindCardInfo and KARDS.GetCardIdentity and IsValid(cardEnt))
                        and KARDS.DeckFindCardInfo(KARDS.GetCardIdentity(cardEnt)) or nil
                    KARDS.CardTextOverlay:AddLocal(unitEnt, {
                        cost = 0,
                        actionCost = unitEnt:GetNWInt("Kards_CardActionCost", 0),
                        attack = unitEnt:GetNWInt("Kards_CardAttack", 0),
                        defense = unitEnt:GetNWInt("Kards_CardDefense", 0),
                        cardTemplate = (unitApp and unitApp.cardTemplate) or "",
                        _unitMode = true, -- DrawOverlay 据此跳过 cost/keywords/desc
                        ownerSlot = slot, -- 归属槽（行动花费指挥点颜色判定，cl_battle_hud.lua KardsUnitActionCostColorThink 读取）
                    }, 7.2, 8.528, 209, 290, hidden) -- hideWhenBack：隐蔽期卡背朝上不绘制正面属性
                    -- 源保存文件值（t4 攻防颜色规则基准，2026-08-12）：注册时 NW 为
                    -- 服务端部署初写（= 文件属性值），快照为 base——此后攻防与源值比较：
                    -- 升绿 / 降红 / 持平恢复默认色（cl_card_text_overlay.lua UpdateStatFX）
                    KARDS.CardTextOverlay:SetBaseStat(unitEnt, "attack", unitEnt:GetNWInt("Kards_CardAttack", 0))
                    KARDS.CardTextOverlay:SetBaseStat(unitEnt, "defense", unitEnt:GetNWInt("Kards_CardDefense", 0))
                end

                -- 本地隐藏源卡（模型+文字），仅本客户端生效（对方/观战各自在本地
                -- KardsCardPlayed 中执行同样切换，视角一致）
                if IsValid(cardEnt) then
                    cardEnt:SetNoDraw(true)
                    if KARDS.CardTextOverlay then KARDS.CardTextOverlay:Remove(cardEnt) end
                end

                -- 上传服务端：源卡已切换为小模型（附带记录的小模型实体），服务端
                -- 据此销毁源卡实体（仅部署方发送；对方/观战本地执行同样切换不发送）
                if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent
                    and KARDS.BattleState.inTable.slot == slot then
                    net.Start("KardsDeploySwitch")
                        net.WriteEntity(ent)
                        net.WriteEntity(cardEnt)
                        net.WriteEntity(unitEnt)
                    net.SendToServer()
                end

                -- 阶段 2 动画：小模型从中点继续飞后半程（原位替换上方占位动画，
                -- 同组并发，切换无停顿）
                KARDS.AnimPlayer:Play(unitEnt, {
                    { t = 0 },
                    { t = halfDur, pos = targetPos, easing = "cos" },
                }, { group = DeployAnimGroup })
            end,
        })
    else
        -- 无 unit 实体（指令卡或 unit 创建失败回退）：原实体直接飞全程
        KARDS.AnimPlayer:Play(cardEnt, {
            { t = 0 },
            { t = HandSlotFlightDur, pos = targetPos, easing = "cos" },
        }, { group = DeployAnimGroup })
    end
end

net.Receive("KardsCardPlayed", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local cardEnt = net.ReadEntity()
    local landed = net.ReadUInt(8)
    local unitEnt = net.ReadEntity() -- 单位>0：服务端 unit 战场实体；指令：NULL
    -- 放牌/部署音效路径（2026-08-14 规模接入战斗系统，服务端随广播携带；空串 = 不播放）：
    -- 放牌 = 放置在场动作直接播放（飞行开始）；部署 = 单位变身为小模型时播放（半程切换）
    local placeSnd = net.ReadString()
    local deploySnd = net.ReadString()
    if not IsValid(ent) or not IsValid(cardEnt) then return end
    -- 2026-09-13 规划 S2：仅关注桌（参战桌/观战追踪桌）事件允许写本地单例状态。
    -- 跨桌广播直接跳过（S1 全服对战锁下不存在并发对局；卡实体虽 SetParent 到各自
    -- 牌桌，但部署会写全局 fieldLayouts、指令出场用全局队列、音效为 2D 全屏，
    -- 跳过最安全）。载荷至此已全部读完
    if slot ~= 1 and slot ~= 2 then return end
    if not KARDS.BattleState:IsLocalTable(ent) then return end
    if KARDS.BattleState.pendingPlayEnt == cardEnt then KARDS.BattleState.pendingPlayEnt = nil end
    KARDS.BattleState.remoteDrags[cardEnt] = nil -- 远程拖拽登记清除（打出接管；无登记的 no-op）
    KARDS.BattleState.realHandCards[slot][cardEnt] = nil -- 已离手（本/对方/观战均移除手牌登记）
    handHoverCards[cardEnt] = nil
    -- 剩余手牌索引重排（连续 1..n）+ 平滑过渡到新扇形位：手牌数量变化后扇形
    -- 按新张数收缩分布（2026-08-11 用户反馈打出后扇形仍按原数量分布）
    RenumberHand(slot)
    if landed > 0 then
        -- 单位部署段（2026-08-15 C6 拆出，见 CardPlayedDeploy）
        CardPlayedDeploy(ent, slot, cardEnt, landed, unitEnt, placeSnd, deploySnd)
    else
        -- 指令：展示槽（打出方视角左侧）停留 → 左下出场（2026-08-12 阶段 C）；realHandCards 已移除
        PlayCommandExitAnim(slot, cardEnt)
    end
end)

-- 支援阵线布局广播（服务端单位打出成功后）：重建 KARDS.BattleState.fieldLayouts[slot] 并按槽位复位各卡
--（固定部署不重排，其余卡槽位/坐标保持腾位后状态；飞行/拖拽/总部动画中的卡跳过复位）
net.Receive("KardsFieldLayout", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    if not IsValid(ent) then return end
    -- 2026-09-13 规划 S2：布局表为全局单例，仅关注桌消费载荷后的写入与复位动画
    -- 生效；跨桌广播先读完整个载荷（防污染 net 流），再直接 return
    local localTbl = KARDS.BattleState:IsLocalTable(ent)
    -- slot=0：前线布局变体（2026-08-11 单位操作，服务端 BroadcastFrontlineLayout）。
    -- 读序与支援阵线不同：牌桌 → slot(0) → 前线归属槽 → 数量 → items
    if slot == 0 then
        local ownerSlot = net.ReadUInt(8)
        local n = net.ReadUInt(8)
        local layout = {}
        for _ = 1, n do
            local idx = net.ReadUInt(8)
            local e = net.ReadEntity()
            if IsValid(e) then layout[e] = idx end
        end
        if not localTbl then return end
        KARDS.BattleState.frontlineLayout = layout
        if ownerSlot == 1 or ownerSlot == 2 then -- 越界载荷不污染归属槽（默认 0 无主）
            KARDS.BattleState.frontlineOwnerSlot = ownerSlot
        end
        local row = 0 -- 前线行
        for e, idx in pairs(layout) do
            if IsValid(e) then
                local to = FieldPos(layout, e, idx, row)
                -- 加入阵线落点登记（2026-09-26 缺口 F）：加入动画广播比布局广播晚
                -- 0.1 秒（服务端次序，实体需先传播），Target 据此在收到加入动画时立即接管
                KARDS.JoinAnim.layoutTo[e] = to
                if KARDS.JoinAnim:Target(e, to) then
                    -- 加入动画已接管（自屏幕右外侧滑入落点），跳过常规复位
                elseif e ~= KARDS.BattleState.pendingPlayEnt
                    and not KARDS.AnimPlayer:Active(e, DeployAnimGroup)
                    and not KARDS.AnimPlayer:Active(e, "joinField") -- 加入动画中：落位由其专用动画接管（缺口 F）
                    and not KARDS.AnimPlayer:Active(e, "unitLunge") -- 攻击冲刺中：位移由其专用动画接管（缺口 G）
                    -- 2026-10-03 联机排查 NEW-7/NEW-8：守卫改按动画组查询。原 active 标志
                    -- 只在 onComplete 清除，动画被顶替时永不复位，该卡被布局永久跳过
                    and not KARDS.AnimPlayer:Active(e, "unitConvert") -- 转换交接动画中：落位由其专用动画接管（缺口 J）
                    and not KARDS.AnimPlayer:Active(e, "controlAnim") -- 控制动画中：落位由其专用动画接管（2026-08-16）
                    and not (KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == e)
                    and not InHQRevealAnim(e) then
                    local existing = KARDS.AnimPlayer:Get(e)
                    if not existing or not existing.toPos
                        or (existing.toPos - to):LengthSqr() > 0.01 then
                        -- frontlineMove 组（2026-08-12，阶段五 P7 组名英文化）：与前线
                        -- 标识同组并发——单位移动至前线时单位与前线标识同时移动
                        -- （前线标识动画见 cl_battle_frontline_symbol.lua）
                        -- 2026-10-27：移动 / 撤退操作的位移改为匀速——时长按位移
                        -- 等比缩放（UnitMoveAnimDur，基准 1.5 倍），线性缓动
                        KARDS.AnimPlayer:Play(e, {
                            { t = 0 },
                            { t = UnitMoveAnimDur(e:GetLocalPos(), to), pos = to, easing = "linear" },
                        }, { group = "frontlineMove" })
                    end
                end
            end
        end
        return
    end
    -- slot 越界（合法仅 1/2，0 为上方前线变体）：无法解析后续布局，直接丢弃
    if slot ~= 1 and slot ~= 2 then return end
    local n = net.ReadUInt(8)
    local layout = {}
    for _ = 1, n do
        local idx = net.ReadUInt(8)
        local e = net.ReadEntity()
        if IsValid(e) then layout[e] = idx end
    end
    if not localTbl then return end
    KARDS.BattleState.fieldLayouts[slot] = layout
    local row = (slot == 1) and 1 or -1
    for e, idx in pairs(layout) do
        if IsValid(e) then
            local to = FieldPos(layout, e, idx, row)
            -- 加入阵线落点登记（2026-09-26 缺口 F，见前线变体同段说明）
            KARDS.JoinAnim.layoutTo[e] = to
            if KARDS.JoinAnim:Target(e, to) then
                -- 加入动画已接管，跳过常规复位
            elseif e ~= KARDS.BattleState.pendingPlayEnt
                and not KARDS.AnimPlayer:Active(e, DeployAnimGroup)
                and not KARDS.AnimPlayer:Active(e, "joinField") -- 加入动画中：落位由其专用动画接管（缺口 F）
                and not KARDS.AnimPlayer:Active(e, "unitLunge") -- 攻击冲刺中：位移由其专用动画接管（缺口 G）
                -- 2026-10-03 联机排查 NEW-7/NEW-8：守卫改按动画组查询（同前线变体）
                and not KARDS.AnimPlayer:Active(e, "unitConvert") -- 转换交接动画中：落位由其专用动画接管（缺口 J）
                and not KARDS.AnimPlayer:Active(e, "controlAnim") -- 控制动画中：落位由其专用动画接管（2026-08-16）
                and not (KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == e)
                and not InHQRevealAnim(e) then
                local existing = KARDS.AnimPlayer:Get(e)
                if not existing or not existing.toPos
                    or (existing.toPos - to):LengthSqr() > 0.01 then
                    local dur, ease = HandSlotReposDur, "cos"
                    -- 撤退（2026-10-27 用户规格）：旧前线布局（本卡在此次广播后仍登记）
                    -- 中仍有本卡 → 本卡正从前线退回支援阵线。与移动至前线一致，
                    -- 时长按位移等比缩放 + 线性缓动（匀速），基准时长 1.5 倍
                    local oldFront = KARDS.BattleState.frontlineLayout
                    if oldFront and oldFront[e] then
                        dur = UnitMoveAnimDur(e:GetLocalPos(), to)
                        ease = "linear"
                    end
                    KARDS.AnimPlayer:Play(e, {
                        { t = 0 },
                        { t = dur, pos = to, easing = ease },
                    }, { group = "fieldRepos" })
                end
            end
        end
    end
end)

-- ====================================================================
-- 控制/解除控制动画（2026-08-16 用户规格，测试版实现）
-- ====================================================================
-- 服务端 SimControl/SimUncontrol 成功 → BroadcastControlAnim 广播本消息（被控单位
-- 实体 + 是否解除 + 落位阵线/槽位），随后广播布局（KardsFieldLayout）。动画与
-- CardPlayedDeploy 同款 AnimPlayer 关键帧驱动：
--   控制：0.7s 移到牌桌中心（z 上升）→ 中心停留播放控制图标动画（词条图标闪烁，
--   见 cl_battle_keyword_icons.lua TriggerControlFlash）→ 落位（前线第 3 位置 /
--   新控制者支援阵线右侧——落位目标由随后到达的布局广播计算 FieldPos）。
--   解除控制：同样飞向中心停留后落位回原阵线位置（返回手牌路径服务端已跳过，
--   走既有 KardsReturnToHand 动画）。
-- 动画期间布局复位跳过该卡（2026-10-03 联机排查 NEW-7 起改按动画组查询，见上方
-- KardsFieldLayout 判定的 AnimPlayer:Active(e, "controlAnim")，原 active 标志表已移除）；
-- noQueue 免排队：不阻塞其它卡（fieldRepos/frontlineMove）复位动画并发播放。
KARDS.ControlAnim = KARDS.ControlAnim or {}
KARDS.ControlAnim.FlyDur = 0.7   -- 0.7s 移向牌桌中心
KARDS.ControlAnim.HoldDur = 0.4  -- 中心停留（控制图标动画）
KARDS.ControlAnim.LandDur = 0.4  -- 落位动画
KARDS.ControlAnim.LiftZ = 7      -- z 上升量（桌面 CardZ 之上）

net.Receive("KardsControlAnim", function()
    local tableEnt = net.ReadEntity() -- 牌桌（2026-09-13 规划 S2：跨桌过滤）
    local cardEnt = net.ReadEntity()
    local isUncontrol = net.ReadBool()
    local landingFront = net.ReadUInt(8) == 1 -- 1=前线 0=支援
    local landingSlot = net.ReadUInt(8)
    local fromSlot = net.ReadUInt(8) -- 观察者 yaw 旋转起点归属（控制=原方 / 解除=控制者）
    local toSlot = net.ReadUInt(8)   -- 旋转终点归属（控制=新控制者 / 解除=原方）
    if not IsValid(cardEnt) then return end
    -- 落位目标从本地单例布局表（关注桌）查询，跨桌卡片查不到会滞留中心；跨桌广播
    -- 直接跳过（实体落位由 KardsFieldLayout 复位动画覆盖）
    if not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    -- 观察者视角（LocalView=nil）：第一段飞向中心（z+）期间 yaw 从原归属方旋转到新归属方
    --（控制）/ 旋转回原方（解除）；在场玩家视角（LocalView=1/2）：yaw 恒朝向自身
    --（180/0，与归属无关）不旋转——动画期间 Think 跳过（active），动画结束后按新归属接管。
    local fromYaw, toYaw
    local obs = KARDS.Perspective and not KARDS.Perspective.LocalView
    if obs and KARDS.Perspective.FacingYaw and fromSlot ~= toSlot then
        fromYaw = KARDS.Perspective:FacingYaw(nil, fromSlot)
        toYaw = KARDS.Perspective:FacingYaw(nil, toSlot)
    end
    -- 落位目标：控制 → 前线第 3 / 支援阵线右侧；解除 → 原阵线位置。均由随后到达的
    -- 布局广播（KardsFieldLayout）重建布局表，落位时（中心停留结束）已就绪，按实体
    -- 所在布局表 FieldPos 计算；找不到（异常）则原地收尾（不落位）。
    local function landTarget(ent)
        local BS = KARDS.BattleState
        local idx = BS.frontlineLayout and BS.frontlineLayout[ent]
        if idx then return FieldPos(BS.frontlineLayout, ent, idx, 0) end
        for s = 1, 2 do
            local layout = BS.fieldLayouts and BS.fieldLayouts[s]
            if layout and layout[ent] then
                return FieldPos(layout, ent, layout[ent], (s == 1) and 1 or -1)
            end
        end
        return nil
    end
    local center = Vector(KARDS.Animation.Board2D.ColX[3], KARDS.Animation.Board2D.RowY[0],
        KARDS.Animation.Board2D.CardZ + KARDS.ControlAnim.LiftZ)
    -- 观察者旋转帧：首帧显式原方 yaw（动画起始即原归属朝向），飞向中心过程
    -- cos 缓动旋转到新方 yaw，中心停留保持新方（toYaw 为 nil 时省略 ang 轴 →
    -- 仅位置动画，yaw 保持动画开始时的当前值——在场玩家朝向自身）
    KARDS.AnimPlayer:Play(cardEnt, {
        { t = 0, ang = fromYaw and Angle(0, fromYaw, 0) or nil },
        { t = KARDS.ControlAnim.FlyDur, pos = center, ang = toYaw and Angle(0, toYaw, 0) or nil, easing = "cos", event = "center" },
        { t = KARDS.ControlAnim.FlyDur + KARDS.ControlAnim.HoldDur, pos = center, ang = toYaw and Angle(0, toYaw, 0) or nil },
    }, {
        group = "controlAnim",
        noQueue = true, -- 免排队：不阻塞其它卡布局复位动画
        onKeyframe = function(ent, name)
            -- 到达中心：播放控制图标动画（图标闪烁）；解除时图标正在消失，不播
            if not isUncontrol and name == "center" and KARDS.KeywordIcons
                and KARDS.KeywordIcons.TriggerControlFlash then
                KARDS.KeywordIcons.TriggerControlFlash(ent)
            end
        end,
        onComplete = function(ent)
            local to = landTarget(ent)
            if not to then return end
            KARDS.AnimPlayer:Play(ent, {
                { t = 0 },
                { t = KARDS.ControlAnim.LandDur, pos = to, ang = toYaw and Angle(0, toYaw, 0) or nil, easing = "cos" },
            }, {
                group = "controlAnim",
                noQueue = true,
            })
        end,
    })
end)

-- 打出被拒（服务端校验失败：非当前回合 / 指挥点不足 / 阵线已满等）：渐变退回手牌
net.Receive("KardsPlayCardRejected", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local cardEnt = net.ReadEntity()
    if not IsValid(cardEnt) then return end
    -- 2026-10-03 联机排查 NEW-11：槽位门控（同族接收器均有），防越界 slot 索引手牌表报错
    if slot ~= 1 and slot ~= 2 then return end
    if KARDS.BattleState.pendingPlayEnt == cardEnt then KARDS.BattleState.pendingPlayEnt = nil end
    local idx = KARDS.BattleState.realHandCards[slot][cardEnt]
    if idx then
        local n = 0
        for e in pairs(KARDS.BattleState.realHandCards[slot]) do
            if IsValid(e) then n = n + 1 end
        end
        local handPos, handAng = HandFanPos(slot, idx, n)
        -- 角度一并恢复扇形位（2026-08-12：远程拖拽同步后对方/观战端卡保持平躺角度，
        -- 只动画位置会残留平躺；本方端动画期间 KardsRealHandFacing 跳过、结束才归位，
        -- 加角度关键帧平滑过渡且两端一致）
        KARDS.AnimPlayer:Play(cardEnt, {
            { t = 0, ang = cardEnt:GetLocalAngles() },
            { t = HandSlotReturnDur, pos = handPos, ang = handAng, easing = "cos" },
        }, { group = "dragReturn" })
    end
end)

-- ====================================================================
-- 手牌/单位花费文字颜色（2026-08-11 拆分 B1：花费颜色 Think 已迁移至
-- cl_battle_hud.lua；2026-08-15 C8 合并为 KardsCostColorThink）
-- ====================================================================

-- ====================================================================
-- 指挥点 HUD 面板动画驱动（2026-08-11 拆分 B1：Think 钩子 KardsCommandPointsHUDThink
-- 已迁移至 cl_battle_command_points.lua）
-- ====================================================================

-- ====================================================================
-- 视角朝向驱动（基础规则，见 cl_perspective.lua）：
--   P1 视角：场上所有卡牌朝向 P1 / P2 视角：场上所有卡牌朝向 P2 /
--   观战视角（未进入牌桌）：P1 的牌朝向 P1、P2 的牌朝向 P2。
-- 服务端只发归属数据（Kards_IsFieldCard + Kards_DeckSlot），角度由客户端本地计算设置。
-- 动画协调：总部对局开始动画中的总部卡（hqReveals）由动画驱动角度，此处跳过；
-- 总部卡仅在其已离开卡组槽（battleHQLeft 置位，动画完成后）由本模块接管朝向
-- （未上场的总部卡保持卡组槽美观角度）。抽牌动画的卡属手牌区，不参与本规则。
-- 未来部署卡实体设置 Kards_IsFieldCard + Kards_DeckSlot 后自动跟随本驱动。
-- ====================================================================

-- 战场实体统一驱动（2026-08-15 阶段四 C4 合并）：原 KardsFieldFacing /
-- KardsHandSlotFacing / KardsBattleDeckStackVisible 三个每帧全量遍历
-- ents.FindByClass("sent_pmx_static_imported") 的 Think 合并——共享一次实体遍历
-- 结果，按原注册顺序分派（卡堆可见 → 战场朝向 → 手牌槽朝向）。行为等价：原三
-- 钩子每帧独立全量遍历，同帧内实体列表一致；各阶段判定只依赖 NW / 状态表
-- （ApplyFacing / ApplyHandFacing / SetNoDraw 不改变他卡判定输入），逐实体顺序与
-- 分段顺序等价；守卫条件分别保留（卡堆可见仅需 inTable；朝向需 Perspective）。
hook.Add("Think", "KardsTableEntitiesThink", function()
    -- 共享每帧 PMX 列表（KARDS.GetPmxList）：与 cl_battle_material / cl_battle_hud /
    -- cl_deck_pile 的同帧遍历合并为一次全量扫描（2026-10-16 性能优化）
    local list = KARDS.GetPmxList()
    local inTable = KARDS.BattleState.inTable
    local persp = KARDS.Perspective
    local hasFacing = persp and persp.IsFieldCard and persp.IsHandSlotCard
    -- 手牌 z 视角修正（原 KardsHandSlotFacing 帧头）：P1/P2 视角（LocalView=1/2）用
    -- 服务端基础 z（Kards_HandSlotBasePos）；观察者视角（LocalView=nil，含未进入牌桌 /
    -- 未开始对战）还原到更低基线（基础 z − HandSlotZViewOffset），不跟随 P1/P2 的 z
    -- 抬升。只改 z、保留 x/y（不干扰抽牌左移动画）。
    local view = hasFacing and persp.LocalView or nil
    local zOff = (view == 1 or view == 2) and 0 or -HandSlotZViewOffset
    -- 悬停检测（仅 P1/P2 视角 + 本方手牌）：相机射线到各手牌中心的最近距离判定
    --（与卡堆悬停同走 KARDS.HitTest 中心距离口径）
    local hoveredEnt = nil
    if view == 1 or view == 2 then
        local ply = LocalPlayer()
        if IsValid(ply) and not gui.IsConsoleVisible() and not gui.IsGameUIVisible() then
            local pos, dir = KARDS.HitTest.MouseRay()
            hoveredEnt = pos and KARDS.HitTest.NearestInRay(pos, dir, list,
                HandSlotHoverRadius * HandSlotHoverRadius,
                function(ent)
                    return persp:IsHandSlotCard(ent)
                        and ent:GetNWInt("Kards_DeckSlot", 0) == view
                end)
        end
    end
    for _, ent in ipairs(list) do
        -- 卡组槽堆叠可见性（原 KardsBattleDeckStackVisible）：仅兜底保证卡组槽卡
        -- （含抽牌临时卡）可见。卡堆档位实体（Kards_IsBattleDeckPile）的可见性由
        -- 服务端 SetDeckPileTier 驱动、总部（Kards_DeckRole="hq"）的隐藏由服务端
        -- SetNoDraw(true) 驱动（动画时 StartHQReveal 显式 SetNoDraw(false)），均不在
        -- 此处处理——若此处对总部 SetNoDraw(false)，会把服务端隐藏的总部提前显示。
        -- 被抽的卡（battleDeckDrawn）与已离开卡组槽的总部（battleHQLeft）不在此处
        -- 设置：其显示/朝向由抽牌动画 / 总部对局开始动画驱动接管。
        -- 2026-10-03 联机排查 NEW-2：补「任一动画在播即让位」（洗入载体动画收尾隐藏后
        -- 原会被下方兜底复活；battleDeckDrawn / battleHQLeft 两个豁免名单保留作第二层）
        -- 2026-10-15 收缴：已创建待揭示的收缴载体（NW Kards_ConfiscateHidden）不参与兜底
        -- 显隐，否则会在揭示前被本地 SetNoDraw(false) 提前显示（揭示由 cl_battle_confiscate.lua 负责）
        if inTable and IsValid(ent) and not battleDeckDrawn[ent] and not battleHQLeft[ent]
            and not KARDS.AnimPlayer:Active(ent)
            and not ent:GetNWBool("Kards_ConfiscateHidden", false)
            and ent:GetNWString("Kards_CardRole", "") == "battledeck" then
            ent:SetNoDraw(false)
        end
        if hasFacing and IsValid(ent) then
            -- 战场朝向（原 KardsFieldFacing）：待打出确认的卡跳过（确认前冻结，避免
            -- NW 先于 KardsCardPlayed 到达时被提前驱动到战场朝向，与拖拽收尾动画冲突；
            -- 确认后由飞行动画收尾、本驱动接管）；控制/解除控制动画中的卡跳过
            --（2026-08-16：yaw 由控制动画驱动——观察者第一段飞向中心期间旋转到新归属
            -- 方、在场玩家 yaw 恒朝向自身，动画结束后本驱动按新归属 NW 接管）
            if persp:IsFieldCard(ent) and ent ~= KARDS.BattleState.pendingPlayEnt
                -- 2026-10-03 联机排查 NEW-7：改按动画组查询（active 标志被顶替后不复位）
                and not KARDS.AnimPlayer:Active(ent, "controlAnim") then
                if ent:GetNWString("Kards_DeckRole", "") == "hq" then
                    -- 总部：仅已离开卡组槽（battleHQLeft）且不在动画中时由本模块接管朝向
                    if battleHQLeft[ent] and not InHQRevealAnim(ent) then
                        persp:ApplyFacing(ent)
                    end
                else
                    persp:ApplyFacing(ent)
                end
            end
            -- 手牌槽朝向（原 KardsHandSlotFacing）：扇形基准角度来自服务端
            -- Kards_HandBaseAng NW（CreateHandCardSlots 写入），归属槽位来自
            -- Kards_DeckSlot NW（SpawnHandSlotCard 写入）。抽牌动画的临时卡
            -- （battleDeckDrawn）非手牌槽卡（无 Kards_IsHandSlotCard），不在此驱动，
            -- 角度由抽牌动画自行控制；手牌槽左移动画（deckDrawShift）只改位置 x、
            -- 不动角度与 z，与本驱动无冲突。悬停提升（仅 P1/P2 视角、本方手牌）：
            -- 鼠标悬停某张本方手牌时，该卡沿自身 y+ 轴（实体局部 +y，随当前朝向
            -- 变化）在 HandSlotHoverDur 秒内移动 HandSlotHoverLift 到满量，离开同样
            -- 时长回落（共享状态机 KARDS.UpdateHandHover，2026-08-15 C9 收敛）。
            if persp:IsHandSlotCard(ent) then
                persp:ApplyHandFacing(ent)
                local v = ent:GetNWVector("Kards_HandSlotBasePos")
                if v then
                    -- 悬停提升状态机：提升中位置 = 基线 st.base 冻结 + 沿自身 y+ 轴
                    -- 提升量，避免逐帧叠加无上限；新悬停记录实际位置为基线（含视角
                    -- z 修正与抽牌左移）；返回 true = 状态机已接管位置，跳过常规修正
                    local hovered = KARDS.UpdateHandHover(ent, ent == hoveredEnt, "y")
                    if not hovered then
                        -- 常规位置修正：z 按视角（P1/P2 服务端 z / 观战还原基线），
                        -- 保留 x/y（不干扰抽牌左移动画）
                        local pos = ent:GetLocalPos()
                        local wantZ = v.z + zOff
                        if math.abs(pos.z - wantZ) > 0.01 then
                            ent:SetLocalPos(Vector(pos.x, pos.y, wantZ))
                        end
                    end
                end
            end
        end
    end
end)

-- ====================================================================
-- 卡组悬停信息面板（2026-08-11 拆分 B1：状态 + KardsDeckHoverDetect 检测 +
-- KardsDeckHoverInfo 绘制已迁移至 cl_battle_hud.lua）
-- ====================================================================

-- ====================================================================
-- 指挥点 HUD 面板绘制（2026-08-11 拆分 B1：HUDPaint 钩子 KardsCommandPointsHUD 与
-- CPCycleBand 数字带已迁移至 cl_battle_command_points.lua）
-- ====================================================================

-- 指向机制（2026-08-15 C1 拆分：GetCardEffectNodeInfo / GetPointingTarget /
-- PointingFailReason / KardsPointingDraw 绘制已迁移至 cl_battle_pointing.lua）
include("cl_battle_pointing.lua")
