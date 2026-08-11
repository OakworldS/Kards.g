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

include("shared.lua")

-- 共享状态模块（2026-08-11 拆分 A1）：跨段落共享状态集中于此，见 cl_battle_state.lua；
-- 必须在任何状态使用方之前加载（相对实体目录，与 include("shared.lua") 同路径规则）
include("cl_battle_state.lua")

-- 未实现职责占位文件（2026-08-11 拆分 A2）：各职责待开发（多为正式版标准职责），
-- 当前为空文件，仅登记加载顺序；实现时代码写在对应文件内、挂 KARDS 命名空间
--（各文件头注释写明职责与约定，本行注释随功能落地后删改）
include("cl_battle_pick.lua")       -- 三选一交互（待实现）
include("cl_battle_front.lua")      -- 移到前线交互（待实现）
include("cl_battle_chat.lua")       -- 纯固定文本聊天（待实现）
include("cl_battle_settings.lua")   -- 设置（待实现）
include("cl_battle_surrender.lua")  -- 投降（待实现）
include("cl_battle_history.lua")    -- 历史出牌回顾（待实现）

-- 指挥点 HUD 面板（2026-08-11 拆分 B1：状态/常量/Think 推进/HUDPaint 绘制/net 接收器，
-- 导出 KARDS.CommandPointsReset / KARDS.CommandPointsApplyBroadcast）
include("cl_battle_command_points.lua")

-- HUD 三件套（2026-08-11 拆分 B1：卡堆悬停信息面板 / 结束回合按钮 / 手牌花费颜色）
include("cl_battle_hud.lua")

-- 单位操作交互（2026-08-11 拆分 C2：按下在场单位 → 松开按悬停目标发送操作请求；
-- 判定/决策全在服务端战斗系统，导出 KARDS.UnitOpsReset）
include("cl_battle_ops.lua")

-- 当前槽位提示状态：{ ent = 牌桌实体, slot = 槽位编号 }（进入后置 nil）
local slotHint = nil

-- 当前宽面提示状态：ent = 牌桌实体（玩家在宽边 x 侧中段，可切换组卡/对战模式；进入后置 nil）
local wideHint = nil

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
-- 总部对局开始动画是否已启动（每场对局一次）：头像完全淡入后 REVEAL_HQ_DELAY
-- 秒启动（见 KardsFirstTurnRevealStart），先于序列结束；KardsTableBattleStart
-- 收到时重置，防止上一场残留导致本场不触发
local hqRevealStarted = false
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
local function MakeAvatarPanel(playerEnt, size)
    local av = vgui.Create("AvatarImage")
    av:SetSize(size, size)
    av:SetMouseInputEnabled(false)
    av:SetKeyboardInputEnabled(false)
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
-- 拖拽中的卡：{ ent, slot, idx, zFrom, start }（2026-08-11 已迁移至 KARDS.BattleState.dragCard）
-- 鼠标左键上一帧状态（上升沿拿起 / 下降沿松手）（2026-08-11 已迁移至 KARDS.BattleState.prevDragLeft）
-- 支援阵线布局：KARDS.BattleState.fieldLayouts[slot][ent] = 槽位 index（2026-08-11 已迁移至 KARDS.BattleState.fieldLayouts）
-- 战场位置动画（re.md 重构：由 KARDS.AnimPlayer 关键帧播放器驱动，组名——
-- 战场复位 "fieldRepos" / 松手回手牌 "dragReturn" / 打出飞行 "dragFlight"）
-- 等待服务端确认的打出实体（确认前冻结位置，防重复打出）（2026-08-11 已迁移至 KARDS.BattleState.pendingPlayEnt）
-- 已结束本方回合（点击按钮置位；对方回合开始广播回本方时复位，期间禁止拿起手牌）（2026-08-11 已迁移至 KARDS.BattleState.endedTurn）
-- 双方指挥点（服务端 KardsCommandPoints 广播；手牌花费 3D2D 文字颜色黄/灰判定）
-- 2026-08-11 已迁移至 KARDS.BattleState.commandPoints（cl_battle_state.lua）

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

-- 重新调度/对局音效（sound/kards/，2026-08-10）：surface.PlaySound 相对路径不带
-- sound/ 前缀但必须带扩展名（缺 .ogg 会报 Failed to load sound）；文件名用英文
-- （sound.PlayFile 不支持非 ASCII 文件名，见 cl_dynamic_bgm_compat.lua），未接入的
-- 音效保持中文文件名以分辨哪些用了哪些没用
function KARDS.PlayKardsSound(name)
    surface.PlaySound("kards/" .. name .. ".ogg")
end

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
hook.Add("HUDShouldDraw", "KardsTableHUD", function()
    if KARDS.BattleState.inTable then return false end
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
        draw.SimpleText(("kards_enter 退出牌桌（P%d）   按 F4 准备"):format(KARDS.BattleState.inTable.slot), "SourceHan_Heavy_24",
            ScrW() / 2, ScrH() - 80,
            Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    elseif slotHint then
        -- 未进入且处于槽位范围：提示进入（玩家序号取自槽位编号）
        draw.SimpleText(("kards_enter 进入牌桌（P%d）"):format(slotHint.slot), "SourceHan_Heavy_24",
            ScrW() / 2, ScrH() - 80,
            Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    elseif wideHint and IsValid(wideHint) then
        -- 未进入且处于宽面（x 侧中段）：提示切换组卡/对战模式（模式经 NW 同步）
        local mode = wideHint:GetNWString("Kards_Mode", "battle")
        local modeText = (mode == "deck") and "组卡" or "对战"
        draw.SimpleText(("kards_enter 切换牌桌模式（当前：%s）"):format(modeText), "SourceHan_Heavy_24",
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
        StartInitLoading("正在初始化卡组")
    else
        StartInitLoading("正在初始化战场")
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

-- 退出成功：恢复默认 HUD 与摄像头（并恢复鼠标视角控制）；清理先手揭晓 UI 残留
net.Receive("KardsTableExited", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then
        KARDS.BattleState.inTable = nil
        tablePlayerCount = 0
        UpdateMatchSound() -- 离开牌桌：停止匹配音效（循环播放通道释放）
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
        -- 退出牌桌：重新调度状态复位（含屏幕点击器关闭，见重新调度段）
        KARDS.BattleState.mulligan = nil
        KARDS.BattleState.mulliganReadySent = false
        KARDS.BattleState.mulliganDoneSlot = {}
        KARDS.BattleState.realHandCards[1], KARDS.BattleState.realHandCards[2] = {}, {}
        KARDS.BattleState.prevMulliganLeft = false
        -- 退出牌桌：结束回合按钮状态复位（当前回合/悬停/点击沿）
        KARDS.BattleState.battleTurn = nil
        KARDS.BattleState.endTurnRect = nil
        KARDS.BattleState.endTurnHover = 0
        KARDS.EndTurnReset() -- 2026-08-11 拆分 B1：prevEndTurnLeft 复位收归 cl_battle_hud.lua
        -- 退出牌桌：指挥点复位（手牌花费颜色恢复默认；HUD 面板显示与动画清空）
        KARDS.BattleState.commandPoints[1], KARDS.BattleState.commandPoints[2] = 0, 0
        KARDS.CommandPointsReset() -- 2026-08-11 拆分 B1：段内状态复位收归 cl_battle_command_points.lua
        -- 退出牌桌：手牌拿起/拖拽/打出状态复位（拖拽卡/待确认/战场布局/动画表）
        KARDS.BattleState.dragCard = nil
        KARDS.BattleState.pendingPlayEnt = nil
        KARDS.BattleState.endedTurn = false
        KARDS.BattleState.fieldLayouts[1], KARDS.BattleState.fieldLayouts[2] = {}, {}
        KARDS.BattleState.frontlineLayout = {} -- 前线布局复位（2026-08-11 单位操作）
        KARDS.BattleState.frontlineOwnerSlot = 0
        KARDS.UnitOpsReset() -- 单位操作选中复位（cl_battle_ops.lua）
        KARDS.AnimPlayer:StopAll() -- 退出牌桌：停止全部关键帧动画（re.md 重构）
        hqReveals = {} -- 退出牌桌：总部对局开始动画活跃集合复位（StopAll 中断时 onComplete 不触发）
        KARDS.BattleState.prevDragLeft = false
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

-- 服务端提示（如槽位被占用）
net.Receive("KardsTableMsg", function()
    Flash(net.ReadString())
end)

-- 准备回执：显示已准备状态
net.Receive("KardsTableReadyAck", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local ready = net.ReadBool()
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then
        Flash(ready and ("P%d 已准备"):format(slot) or ("P%d 取消准备"):format(slot))
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
-- + 摄像头轻微抖动 + 复位 KARDS.BattleState.endedTurn（本方回合恢复可拿起手牌）；对局开始首次广播
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
            -- 摄像头轻微抖动（CalcView 叠加，见 cl_battle_camera.lua）
            KARDS.BattleCamera.Shake = { start = CurTime(), endT = CurTime() + 0.35, amp = 0.6 }
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
    if KARDS.BattleState.inTable and KARDS.BattleState.inTable.ent == ent then
        KARDS.BattleState.battleStarted = true
        -- 对战开始：立即无条件停止匹配音效（服务端 SetNWBool 的 Kards_FormalBattleStarted
        -- 随下个网络更新同步，晚于本 net 消息——依赖 UpdateMatchSound 的 NW 条件会因
        -- NW 仍为 false 而继续播放；StopMatchSound 同时使加载中的通道不播放）
        StopMatchSound()
        hqRevealStarted = false -- 新一场对局：总部动画启动标志复位（上一场残留防误触发）
        -- 新一场对局：重新调度状态复位（上一场残留防误触发）
        KARDS.BattleState.mulligan = nil
        KARDS.BattleState.mulliganReadySent = false
        KARDS.BattleState.mulliganDoneSlot = {}
        KARDS.BattleState.realHandCards[1], KARDS.BattleState.realHandCards[2] = {}, {}
        KARDS.BattleState.prevMulliganLeft = false
        -- 新一场对局：结束回合按钮状态复位（KARDS.BattleState.battleTurn 待 KardsTurnUpdate 写入）
        KARDS.BattleState.battleTurn = nil
        KARDS.BattleState.endTurnRect = nil
        KARDS.BattleState.endTurnHover = 0
        KARDS.EndTurnReset() -- 2026-08-11 拆分 B1：prevEndTurnLeft 复位收归 cl_battle_hud.lua
        -- 新一场对局：指挥点复位（手牌花费颜色待 KardsCommandPoints 广播写入；HUD 面板显示与动画清空）
        KARDS.BattleState.commandPoints[1], KARDS.BattleState.commandPoints[2] = 0, 0
        KARDS.CommandPointsReset() -- 2026-08-11 拆分 B1：段内状态复位收归 cl_battle_command_points.lua
        -- 新一场对局：手牌拿起/拖拽/打出状态复位（上一场残留防误触发）
        KARDS.BattleState.dragCard = nil
        KARDS.BattleState.pendingPlayEnt = nil
        KARDS.BattleState.endedTurn = false
        KARDS.BattleState.fieldLayouts[1], KARDS.BattleState.fieldLayouts[2] = {}, {}
        KARDS.BattleState.frontlineLayout = {} -- 前线布局复位（2026-08-11 单位操作）
        KARDS.BattleState.frontlineOwnerSlot = 0
        KARDS.UnitOpsReset() -- 单位操作选中复位（cl_battle_ops.lua）
        KARDS.AnimPlayer:StopAll() -- 新一场对局：停止全部关键帧动画（re.md 重构）
        hqReveals = {} -- 新一场对局：总部对局开始动画活跃集合复位（StopAll 中断时 onComplete 不触发）
        KARDS.BattleState.prevDragLeft = false
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
        -- 观战者（未进入该牌桌，含在其他牌桌的玩家）：该场对局开始 → 本地直接触发
        -- 总部对局开始动画（无 KARDS.BattleState.reveal 序列/无本方头像；mySlot=nil 时直接翻转落位
        -- 支援阵线，观战视角下 P1 总部朝 P1、P2 总部朝 P2，见 StartHQReveal/FacingYaw）
        StartHQReveal(ent, nil)
    end
end)

-- ====================================================================
-- 先手揭晓 UI（摄像头动画结束后，双方玩家 UI 上展示）
-- 时间轴（自摄像头动画结束起）：
--   0~0.5    左侧本方头像淡入 + 从极大体积（3x）缩小到正常；右侧敌方头像同时动画
--            （敌方缺失 → 白色矩形兜底）
--   0.5~1.0  每个头像下方玩家名淡入（敌方缺失 → “暂无对手”）
--   1.5      随机先手（服务端随机）：先手方头像+名称 0.4s 回弹曲线放大一部分；
--            其名称下方 0.5s 淡入黄色“先手”
--   1.5+2.0  停留 2 秒后所有元素整体淡出（0.5s）
-- 头像用 GMod 引擎内置 AvatarImage VGUI 控件：SetPlayer 自动经 Steamworks 拿
-- SteamID64、从 Steam CDN 异步下载对应分辨率头像（期间显示默认占位头像）；
-- 淡入淡出/缩放由每帧 SetAlpha（0~255）+ SetSize/SetPos 驱动。
-- ====================================================================

local REVEAL_AVATAR_SIZE = 256      -- 头像正常边长（px，放大为原 128 的两倍）
local REVEAL_AVATAR_MAX_SCALE = 3   -- 入场起始“极大体积”倍率
local REVEAL_INTRO = 0.5            -- 头像淡入 + 缩小时长
local REVEAL_NAME_DELAY = 0.5       -- 名称淡入延迟（头像入场完成后）
local REVEAL_NAME_DUR = 0.5         -- 名称淡入时长
local REVEAL_FIRST_DELAY = 1.5      -- 先手揭晓延迟（自序列开始）
local REVEAL_FIRST_BOUNCE = 0.4     -- 先手回弹放大时长
local REVEAL_FIRST_TEXT = 0.5       -- “先手”文字淡入时长
local REVEAL_HQ_DELAY = 1.5         -- 总部动画延迟（自头像完全淡入 REVEAL_INTRO 起，先于序列结束启动）
local REVEAL_HQ_FLANK_LIFT = 12     -- 总部动画阶段1终点（头像外侧）z 抬升量（世界单位）：桌面顶
                                    -- CardZ=18.43 + 12 ≈ 30.4，接近手牌高度（30.5），展示总部卡面更醒目
local REVEAL_HOLD = 2.0             -- 揭晓后停留时长（随后整体淡出）
local REVEAL_FADE = 0.5             -- 整体淡出时长

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
        enemyName = hasEnemy and enemyPly:Nick() or "暂无对手",
        hasEnemy = hasEnemy,
        leftAvatar = MakeAvatarPanel(ply, REVEAL_AVATAR_SIZE),
        rightAvatar = hasEnemy and MakeAvatarPanel(enemyPly, REVEAL_AVATAR_SIZE) or nil, -- 敌方缺失 → 白色矩形兜底
    }
end

-- 更新头像面板：按中心点 (cx,cy) 与缩放倍率设置尺寸/位置，并设整体透明度
local function UpdateAvatarPanel(panel, cx, cy, scale, alpha)
    if not IsValid(panel) then return end
    local s = REVEAL_AVATAR_SIZE * scale
    panel:SetSize(s, s)
    panel:SetPos(cx - s / 2, cy - s / 2)
    panel:SetAlpha(math.Clamp(math.Round(alpha), 0, 255))
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
        -- 总部对局开始动画：头像完全淡入（REVEAL_INTRO）后 REVEAL_HQ_DELAY 秒启动
        --（每场对局一次，先于先手揭晓停留/淡出；此时相机仍为揭晓期间固定俯视，
        --  StartHQReveal 取视线与桌面交点有效，见 StartHQReveal）
        if not hqRevealStarted and t >= REVEAL_INTRO + REVEAL_HQ_DELAY then
            hqRevealStarted = true
            KARDS.PlayKardsSound("hq_start") -- 总部卡动画开始音效（总部离堆上场前）
            if KARDS.BattleState.inTable then StartHQReveal(KARDS.BattleState.inTable.ent, KARDS.BattleState.inTable.slot) end
        end
        if t >= REVEAL_FIRST_DELAY + REVEAL_HOLD + REVEAL_FADE then
            -- 序列结束：清理面板与状态（总部动画已在头像完全淡入后提前启动，
            -- 见上方分支，不再在此触发）
            ClearRevealPanels()
            KARDS.BattleState.reveal = nil
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
    local bounce = 1 -- 先手回弹放大（1.5s 起 0.4s easeOutBack → 1.25）
    if t >= REVEAL_FIRST_DELAY then
        bounce = 1 + 0.25 * RevealEaseOutBack(math.Clamp((t - REVEAL_FIRST_DELAY) / REVEAL_FIRST_BOUNCE, 0, 1))
    end
    -- 1.5 + 2.0 停留后整体淡出
    local fadeMul = 1 - RevealEaseInOut(math.Clamp((t - REVEAL_FIRST_DELAY - REVEAL_HOLD) / REVEAL_FADE, 0, 1))
    avatarAlpha = avatarAlpha * fadeMul
    nameAlpha = nameAlpha * fadeMul
    local firstAlpha = 255 * RevealEaseInOut(math.Clamp((t - REVEAL_FIRST_DELAY) / REVEAL_FIRST_TEXT, 0, 1)) * fadeMul

    local ply = LocalPlayer()
    local meFirst = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == KARDS.BattleState.reveal.firstSlot or false
    -- 头像中心：屏幕 y 一半，水平向屏幕中心收拢（原 0.24/0.76 → 0.30/0.70）
    local lx, ly = ScrW() * 0.30, ScrH() * 0.50 -- 左侧（本方）
    local rx, ry = ScrW() * 0.70, ScrH() * 0.50 -- 右侧（敌方）

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
        draw.SimpleText("先手", "SourceHan_Heavy_56", fx, fy + fs / 2 + 100,
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
        local modeText = (mode == "deck") and "已切换组卡模式（准星浏览桌面卡牌，再次切换返回对战）" or "已切换对战模式"
        Flash(modeText)
        -- 初始化卡顿加载提示：切组卡 → 检测「正在初始化卡组」（铺 5×3 网格卡实体）；
        -- 切回对战 → 若已在牌桌内则恢复「正在初始化战场」检测，否则停止
        if mode == "deck" then
            StartInitLoading("正在初始化卡组")
        elseif KARDS.BattleState.inTable then
            StartInitLoading("正在初始化战场")
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
    local best, bestD = nil, 484 -- 阈值 22^2（卡牌半宽 3.6 / 半长 5.4，视野内 22 单位容差）
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

-- 射线到点的最近距离平方（组卡点击命中检测，阈值同准星浏览 22 单位）
function KARDS.RayPointDistSqr(origin, dir, point)
    local toPoint = point - origin
    local t = math.max(toPoint:Dot(dir), 0)
    return (origin + dir * t):DistToSqr(point)
end

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
    -- 相机射线：优先 BattleCamera 当前视图（cl_battle_camera.lua CalcView 记录），回退玩家眼睛
    local pos = KARDS.BattleCamera.ViewPos or ply:EyePos()
    local dir = gui.ScreenToVector(gui.MouseX(), gui.MouseY())
    if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then
        dir = (KARDS.BattleCamera.ViewAng or ply:EyeAngles()):Forward()
    end
    local best, bestD = nil, 484 -- 阈值 22^2（卡牌半宽 3.6 / 半长 5.4，视野内 22 单位容差）
    local flippedD = nil -- 最近翻面卡距离：翻面卡（达上限）作为阻挡，点击它不触发临近卡
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWString("Kards_CardRole", "") == "deck" then
            local role = ent:GetNWString("Kards_DeckRole", "grid")
            if role ~= "hq" then -- 总部卡不参与组卡点击（仅展示）
                local d = KARDS.RayPointDistSqr(pos, dir, ent:GetPos())
                if ent:GetNWBool("Kards_GridFlipped", false) then
                    -- 已翻面（达携带上限）：记入阻挡，点击它时整次点击无效果
                    if not flippedD or d < flippedD then flippedD = d end
                elseif d < bestD then
                    best, bestD = ent, d
                end
            end
        end
    end
    -- 射线最近的是翻面卡（在容差内）→ 点击无效果，不选任何卡（避免误加临近卡）
    if flippedD and flippedD <= 484 and (not IsValid(best) or flippedD <= bestD) then
        best = nil
    end
    -- "保存"按钮（原总部槽位置）：作为点击目标与卡牌竞争最近距离（阈值 15^2：
    -- 按钮文字约 2×1 单位，避免靠近的卡组堆叠/网格卡被误判为保存）
    local savePos = KARDS.BattleState.inTable.ent:LocalToWorld(Vector(24.68, -12.80, 18.43))
    local saveD = KARDS.RayPointDistSqr(pos, dir, savePos)
    -- 最近目标优先：卡牌更近 → 卡牌操作；否则命中保存按钮（仅 P2）→ 弹输入框
    if IsValid(best) and bestD <= saveD then
        net.Start("KardsDeckCardClick")
            net.WriteEntity(best)
        net.SendToServer()
    elseif KARDS.BattleState.inTable.slot == 2 and saveD <= 225 then
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
    frame:SetTitle("保存卡组")
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
    entry:SetPlaceholderText("输入卡组名称…")
    entry:RequestFocus()
    -- 回车 = 保存
    function entry:OnEnter()
        okBtn:DoClick()
    end
    local okBtn = vgui.Create("DButton", frame)
    okBtn:SetText("保存")
    okBtn:SetPos(16, 88)
    okBtn:SetSize(140, 36)
    okBtn.DoClick = function()
        local text = entry:GetValue():gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then
            Flash("卡组名不能为空")
            return
        end
        net.Start("KardsDeckSave")
            net.WriteString(text)
        net.SendToServer()
        frame:Close()
    end
    local cancelBtn = vgui.Create("DButton", frame)
    cancelBtn:SetText("取消")
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
        local countText = "当前卡牌：" .. cardCount
        for _, off in ipairs({ { -2, 0 }, { 2, 0 }, { 0, -2 }, { 0, 2 } }) do
            draw.DrawText(countText, "SourceHan_Heavy_28", off[1], -56 + off[2],
                Color(0, 0, 0, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        draw.DrawText(countText, "SourceHan_Heavy_28", 0, -56,
            Color(255, 255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        -- 主文字"保存"（黑色描边（四向偏移）+ 白色填充）
        for _, off in ipairs({ { -2, 0 }, { 2, 0 }, { 0, -2 }, { 0, 2 } }) do
            draw.DrawText("保存", "SourceHan_Heavy_48", off[1], off[2],
                Color(0, 0, 0, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        draw.DrawText("保存", "SourceHan_Heavy_48", 0, 0,
            Color(255, 255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        -- 底部小字提示：点击保存卡组（40 张）
        draw.DrawText("点击保存（40张）", "SourceHan_Heavy_24", 0, 40,
            Color(255, 220, 80, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    cam.End3D2D()
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
    draw.SimpleText(ent:GetNWString("Kards_CardName", ""), "SourceHan_Heavy_24",
        x + w / 2, y + 30, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 费用（左上；总部无费用，不显示）
    if not ent:GetNWBool("Kards_CardIsHeadquarter", false) then
        draw.SimpleText(tostring(ent:GetNWInt("Kards_CardCost", 0)), "SourceHan_Heavy_24",
            x + 24, y + 80, Color(120, 180, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText("费", "SourceHan_Heavy_24",
            x + 24, y + 110, Color(160, 180, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    -- 攻击 / 防御（中下部）
    draw.SimpleText(tostring(ent:GetNWInt("Kards_CardAttack", 0)), "SourceHan_Heavy_24",
        x + 70, y + h - 60, Color(255, 120, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    draw.SimpleText(tostring(ent:GetNWInt("Kards_CardDefense", 0)), "SourceHan_Heavy_24",
        x + 170, y + h - 60, Color(120, 255, 160), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 词条文本（中下）
    local kws = ent:GetNWString("Kards_CardKeywords", "")
    if kws ~= "" then
        draw.SimpleText(kws, "SourceHan_Heavy_24",
            x + w / 2, y + h - 110, Color(255, 220, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end)

-- ====================================================================
-- 组卡卡牌材质/文字初始化（客户端）：与编辑器「生成3D2D卡牌」同链路
-- ====================================================================
-- 卡面纹理在「保存卡牌」时已离屏渲染一次并落盘为不透明 RGB PNG（保存文件记录
-- texturePath/textureSize）。故此处对每张组卡卡牌：本地创建模型副本 manifest
-- （image_path 指向 data/kards_deck/<safeName>/front.png|back.png）→ 将保存文件指向的
-- 卡面渲染与卡背图复制到该路径 → ClearCache 销毁旧 renderable → 前置模组按 image_path
-- 直接加载不透明贴图（已实测：不预填 MaterialCache 时卡面正常；Material() 自动材质为
-- 半透明渲染，预填后卡面透明而露出卡背）→ Overlay:AddLocal 绑定文字（renderW/H
-- 用保存文件记录的渲染尺寸，与模板像素对齐）。全程不再离屏渲染，避免反复渲染的性能风险。
-- 注意：manifest + PNG 复制必须在实体首次 Draw 前完成（Think 阶段同步执行，见
-- DeckPrepareCardFiles / KardsDeckCardMaterial）——引擎材质按路径缓存，先缺后补无法刷新，
-- 否则新卡（本会话才落盘）会白屏无纹理直至重启。

-- 已初始化卡牌实体集合 / 排队处理中（weak keys：实体移除自动清理）
local deckCardReady = setmetatable({}, { __mode = "k" })
local deckCardPending = setmetatable({}, { __mode = "k" })
-- modelID 级就绪标记：同 modelID 副本（加卡复制）复用首次初始化成果（manifest/贴图/缓存），
-- 跳过重复文件 I/O 与 ClearCache 重建（后者销毁共享 renderable 强制重建是加卡卡顿主因）
local deckModelReady = {}
-- 翻面变化（Kards_GridFlipped）改由 EntityNetworkedVarChanged 事件即时检测并处理
--（见下方统一驱动 KardsTableCardNWChanged），不再每帧轮询对比

-- 卡牌 manifest 副本统一由共享模块 KARDS.CardManifest 提供（EnsureDeck /
-- EnsureBattleDeck / EnsureHandSlot / EnsureDeckPileSingle，re.md T-H2）：
-- 服务端已创建则直接复用，远程客户端本地无副本时此处调用同样会自行创建；
-- 两端同一入口，不再维护同构薄包装。

-- 卡堆档位模型清单（与 init.lua ENT.DeckPileModelIDs 同步硬编码：客户端实体对象上
-- 不存在服务端 ENT 字段；PMXStaticImporter.exe 不支持数字命名，档位用罗马数字）
local DeckPileModelIDs = {
    "basic_card_xxxx", -- 40 张
    "basic_card_xxx",  -- 30 张
    "basic_card_xx",   -- 20 张
    "basic_card_x",    -- 10 张
    "basic_card_v",    -- 5 张
    "kards_deckpile_1",-- 单张（basic_card 副本）
}

-- 卡堆档位模型卡背改写：整叠卡堆模型（PMXStaticImporter.exe 导入的档位模型，
-- 专属用途不被其他系统共享）可见面 = 顶层卡背（front 子网格），把 front/back
-- image_path 统一改写为 usa 卡背图（side 卡边保持默认灰白色）。幂等：已指向目标
-- 时跳过写入。@return boolean
local function EnsureDeckPileManifest(modelID)
    return KARDS.CardManifest.RewriteImagePaths(modelID, "kards_deckpile/usa")
end

--[[
    back 槽 UV 镜像修正（2026-08-09）：basic_card 家族模型（含卡堆档位模型）的
    back 子网格从 -z 方向采样的 UV 相对图片是水平镜像的（建模时 back 面 UV 未按
    背向重映射——U 仍沿模型 +X，而从 -z 观察 +X 落在屏幕左侧，图像左右颠倒；
    front 槽从 +z 观察正常，故卡组槽卡 front=卡背图显示正常、而手牌/组卡/翻面卡
    的 back 槽卡背图镜像）。卡背图须在 back 槽水平翻转才能从 -z 方向正常显示。
    前置模组 Draw 时优先使用 MaterialCache（cl_canvas_editor.lua 预填实测生效，
    "预填后卡面透明"现象即预填材质被使用），故在此为 back 槽预填带
    $basetexturetransform 水平翻转的 UnlitGeneric 材质——不透明（无
    $vertexcolor/$vertexalpha/$translucent：mesh 顶点流仅 pos3+normal3+uv2，带颜色
    流会读垃圾数据致透明，配方同 cl_canvas_editor.lua 的 mesh 专用材质）。
    调用时机：必须在 PMXStaticImporter.ClearCache(modelID) 之后——ClearCache 清空
    MaterialCache，实体 Draw 重建 renderable 时才会读取本函数预填的翻转材质。

    @param modelID string 模型副本 ID（manifest 已就绪；无 back 子网格则跳过）
]]
local function PrefillBackFlip(modelID)
    if not PMXStaticImporter or not PMXStaticImporter.MaterialCache then return end
    local path = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    local src = file.Read(path, "DATA")
    if not src then
        -- 附加包 GAME 随包分发副本回退（同 cl_canvas_editor.lua 的 manifest 读取方式）
        src = file.Read("data_static/" .. path, "GAME")
    end
    if not src then return end
    local m = util.JSONToTable(src)
    if not m or not m.submeshes then return end
    local cache = PMXStaticImporter.MaterialCache
    for idx, sm in ipairs(m.submeshes) do
        if sm.name == "back" then
            local imagePath = tostring(sm.image_path or "")
            local key = modelID .. "|" .. tostring(idx) .. "|" .. imagePath
            local cur = cache[key]
            -- 幂等：已预填过同名材质则跳过（CreateMaterial 同名会更新，避免反复重建）
            if not (cur and cur.GetName and cur:GetName() == ("Kards_BackFlip_" .. modelID)) then
                -- 与前置 cl_runtime.lua get_image_material 同款纹理解析：Material() 加载
                -- data/ PNG（克隆 manifest 的 image_path = "data/<imageDir>/back.png"），
                -- 再以 GetName() 作为 $basetexture，保证材质系统解析到同一纹理
                -- （直接写路径可能因大小写/别名解析不一致导致纹理解析失败）
                local base = Material(imagePath, "vertexlitgeneric noclamp smooth")
                if base and not base:IsError() then
                    cache[key] = CreateMaterial("Kards_BackFlip_" .. modelID, "UnlitGeneric", {
                        ["$basetexture"] = base:GetName(),
                        -- 绕纹理中心 (0.5, 0.5) 水平翻转（scale -1 1）：修正 back 槽水平镜像
                        ["$basetexturetransform"] = "center 0.5 0.5 scale -1 1 rotate 0 translate 0 0",
                        ["$nolod"] = 1,
                    })
                end
            end
            return
        end
    end
end

--[[
    basic_card_unit UV 裁切预填（2026-08-11）：单位部署战场模型 basic_card_unit 复用手牌
    卡牌纹理（209×290），通过 V 轴缩放 229/290 ≈ 0.789655（锚定 v=0）裁切底部
    品质/效果描述/词条区域（209×61），仅保留上部 209×229。
    调用时机：必须在 PMXStaticImporter.ClearCache(modelID) 之后。

    @param modelID string 模型副本 ID（basic_card_unit 克隆，manifest 已就绪）
]]
-- 挂 KARDS 命名空间（非顶层 local）：main chunk 局部变量接近 GLua 200 上限
-- （2026-08-11 实测 local function 声明会占用槽位触发超限报错），故不占局部槽
function KARDS.PrefillUnitCrop(modelID)
    if not PMXStaticImporter or not PMXStaticImporter.MaterialCache then return end
    local path = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    local src = file.Read(path, "DATA")
    if not src then return end
    local m = util.JSONToTable(src)
    if not m or not m.submeshes then return end
    local cache = PMXStaticImporter.MaterialCache
    for idx, sm in ipairs(m.submeshes) do
        if sm.name == "front" or sm.name == "back" then
            local imagePath = tostring(sm.image_path or "")
            local key = modelID .. "|" .. tostring(idx) .. "|" .. imagePath
            local matName = "Kards_UnitCrop_" .. modelID .. "_" .. sm.name
            local cur = cache[key]
            if not (cur and cur.GetName and cur:GetName() == matName) then
                local base = Material(imagePath, "vertexlitgeneric noclamp smooth")
                if base and not base:IsError() then
                    -- V 轴缩放 229/290 ≈ 0.789655，锚定 v=0；back 槽需同时水平翻转
                    local scaleX = (sm.name == "back") and -1 or 1
                    local transform = ("center 0.5 0 scale %s 0.789655 rotate 0 translate 0 0"):format(scaleX)
                    cache[key] = CreateMaterial(matName, "UnlitGeneric", {
                        ["$basetexture"] = base:GetName(),
                        ["$basetexturetransform"] = transform,
                        ["$nolod"] = 1,
                    })
                end
            end
        end
    end
end

-- ====================================================================
-- 卡牌纹理落盘（re.md T-M1 共享）：组卡与卡组槽两套「材质/贴图链路」共用的原子操作
-- —— 把卡面/卡背 PNG 复制到 manifest image_path 对应的真实文件 + ClearCache 重建。
-- 两链路差异（卡面来源/是否绑文字）在调用方（DeckPrepareCardFiles /
-- ProcessBattleDeckCard），本函数仅统一「目录创建 + 双面文件写 + 缓存重建」。
-- 卡背缺失用卡面兜底（保证 back.png 真实存在，避免卡背棋盘格）；卡面缺失不写 front
-- （旧格式卡 / 卡组槽卡背缺失 → 前置模组白色兜底，维持原回退行为）。
--
-- @param dir        string PNG 落盘目录（data 相对路径，= manifest image_path 目录，
--                    如 "kards_deck/<safeName>" / "kards_battledeck/<safeName>"）
-- @param frontData  string|nil 卡面 PNG 数据（nil → 不写 front.png）
-- @param backData   string|nil 卡背 PNG 数据（nil → 用 frontData 兜底写 back.png）
-- @param modelID    string|nil 模型副本 ID（非 nil → PMXStaticImporter.ClearCache 重建
--                    renderable，使实体 Draw 重建时按 image_path 加载新贴图）
local function WriteCardTextures(dir, frontData, backData, modelID)
    file.CreateDir(dir)
    if frontData then file.Write(dir .. "/front.png", frontData) end
    if backData then file.Write(dir .. "/back.png", backData)
    elseif frontData then file.Write(dir .. "/back.png", frontData) end -- 卡背缺失 → 卡面兜底
    if modelID and PMXStaticImporter and PMXStaticImporter.ClearCache then
        PMXStaticImporter.ClearCache(modelID)
        -- back 槽 UV 镜像修正：ClearCache 清空 MaterialCache 后预填翻转材质
        PrefillBackFlip(modelID)
    end
end

-- 本地保存文件按名称匹配外观数据（卡面纹理路径 + 渲染尺寸 + 文字叠加数据源）。
-- 支持两种卡标识（Kards_CardName NW 因生成链路而异）：
--   组卡（table_deckmode）→ 卡牌显示名 app.name；battle 抽卡/卡组槽（table_battledeck）
--   → 保存文件名（card:GetName() = fileName）。故先精确匹配显示名，再按归一化
--   （去目录/扩展名）匹配显示名与文件名，保证两端都能命中。
local function DeckFindCardInfo(cardName)
    local appearance, texturePath, textureSize = nil, nil, nil
    if KARDS.CardEditor and KARDS.CardEditor.SaveSystem then
        -- 归一化卡标识：去目录前缀、去 .json/.txt 扩展名（保存文件名可能带扩展名）
        local function norm(s)
            local n = tostring(s or ""):match("[^/\\]+$") or tostring(s or "")
            return n:gsub("%.json$", ""):gsub("%.txt$", "")
        end
        local target = norm(cardName)
        local infos = KARDS.CardEditor.SaveSystem.GetAllCardsInfo() or {}
        for _, info in ipairs(infos) do
            local hit = (info.name and info.name == cardName)
                or (target ~= "" and norm(info.name) == target)
                or (target ~= "" and norm(info.fileName) == target)
            if hit then
                appearance = info.cardAppearance
                texturePath = info.texturePath
                textureSize = info.textureSize
                break
            end
        end
    end
    return appearance, texturePath, textureSize
end

-- 组卡卡牌文件准备（manifest 副本 + 卡面/卡背 PNG 落盘）：
-- 必须在实体首次 Draw（前置模组按 manifest image_path 调 Material() 建材质）之前完成——
-- GMod 材质系统按路径名缓存：若在 PNG 落盘前先以该路径请求过材质，引擎层会缓存错误材质
-- 直到本次会话结束（之后复制文件 + ClearCache 只能清前置模组的 Lua 缓存，无法刷新引擎层
-- 材质缓存，卡面呈现前置模组的白色兜底 =「没有纹理」；重启后文件已存在才正常）。
-- 故本函数须在 Think 阶段（先于当帧渲染）同步调用，保证首次 Draw 时文件已存在。
-- 返回是否处理完成（成功后同 modelID 副本不再重复文件 I/O 与 ClearCache）。
local function DeckPrepareCardFiles(modelID, safeName, appearance, texturePath)
    if not KARDS.CardManifest.EnsureDeck(modelID, safeName) then
        print("[Kards] 组卡卡牌 manifest 副本创建失败: " .. modelID)
        return false
    end
    -- 卡面纹理：直接应用保存文件指向的路径（保存时已离屏渲染落盘为不透明 RGB PNG）。
    -- 前置模组按 manifest image_path 从 data/kards_deck/<safeName>/front.png 直接加载贴图
    -- （ClearCache 后重建 renderable 命中真实文件，实测卡面正常）；不再预填 MaterialCache——
    -- Material() 自动创建的 data/ PNG 材质为半透明渲染，预填后卡面透明而露出卡背（已实测回退）
    local tmplPath = appearance and texturePath and texturePath.template or nil
    if not (tmplPath and file.Exists(tmplPath, "DATA")) then
        return true -- 旧格式卡（无卡面文件）：前置模组按 image_path 加载缺失即白色兜底，维持原回退行为
    end
    -- 复制卡面/卡背 PNG 到 manifest image_path 对应的真实文件（data/kards_deck/<safeName>/）：
    -- 卡面 = 保存文件指向的模板渲染；卡背 = materials/kards/cardbacks/<country>.png（缺失用卡面兜底）
    -- （WriteCardTextures 共享函数，re.md T-M1）
    local frontData = file.Read(tmplPath, "DATA")
    local country = tostring(appearance.country or ""):lower()
    local backData = file.Read("materials/kards/cardbacks/" .. country .. ".png", "GAME")
    WriteCardTextures("kards_deck/" .. safeName, frontData, backData, modelID)
    -- 副本诊断：front.png（manifest image_path 指向）是否复制成功（与模板渲染文件大小一致）
    local copyData = file.Read("kards_deck/" .. safeName .. "/front.png", "DATA")
    print("[Kards] 组卡卡牌副本诊断: template_size=" .. tostring(frontData and #frontData or 0)
        .. " | front_copy_size=" .. tostring(copyData and #copyData or 0)
        .. " | match=" .. tostring(frontData and copyData and #frontData == #copyData or false))
    return true
end

-- 初始化单张组卡卡牌：manifest 副本 → 复制卡面/卡背到 image_path 对应文件 → ClearCache
-- 重建 → 前置模组直接加载不透明贴图 → 绑定 3D2D 文字。
-- 性能：同 modelID 副本（加卡复制）仅首次执行文件 I/O 与 ClearCache，后续实体只绑定文字。
-- 文件准备（manifest + PNG 复制）已由首次发现实体时的 Think 同步完成，此处兜底再确认一次。
local function DeckInitCard(ent, modelID)
    deckCardPending[ent] = nil
    if not IsValid(ent) then return end
    -- 已就绪（可能已被其他初始化路径处理）则直接返回，避免重复绑定文字
    if deckCardReady[ent] then return end
    -- 翻面卡守卫：0.1s 延迟初始化期间翻面的卡不绑定 3D2D 文字
    -- （NW 事件 KardsTableCardNWChanged 已移除文字并标记就绪）
    if ent:GetNWBool("Kards_GridFlipped", false) then
        deckCardReady[ent] = true
        return
    end
    local safeName = modelID:match("^kards_deck_(.+)$")
    if not safeName then return end
    local appearance, texturePath, textureSize = DeckFindCardInfo(ent:GetNWString("Kards_CardName", ""))
    -- 首次初始化该 modelID：写 manifest + 复制卡面/卡背 + 清缓存重建（仅一次；通常已由
    -- 首次发现时的同步准备完成，此处兜底——如当时保存文件尚未就绪）
    if not deckModelReady[modelID] then
        if not DeckPrepareCardFiles(modelID, safeName, appearance, texturePath) then
            return -- 准备失败：不标记就绪，下帧 Think 会重新尝试（如保存文件稍后可用）
        end
        deckModelReady[modelID] = true
    end
    if not appearance or not KARDS.CardTextOverlay then
        -- 无本地外观数据 / 叠加层未加载：回退实体模式（3D2D 文字从 NW 变量读取）
        if KARDS.CardTextOverlay then KARDS.CardTextOverlay:AddEntity(ent) end
        deckCardReady[ent] = true
        return
    end
    -- 3D2D 文字：编辑器同款本地绑定（appearance 静态表实时读：费用/攻防/词条/描述富文本）；
    -- renderW/H 用保存文件记录的渲染尺寸（与模板像素对齐，避免文字错位）
    local texW, texH = 300, 400
    if textureSize and textureSize.w and textureSize.h then
        texW, texH = textureSize.w, textureSize.h
    end
    KARDS.CardTextOverlay:AddLocal(ent, appearance, 7.2, 10.8, texW, texH)
    deckCardReady[ent] = true
    print("[Kards] 组卡卡牌纹理已应用: " .. tostring(ent:GetNWString("Kards_CardName", "")))
end

-- ====================================================================
-- 牌桌卡牌材质就绪统一驱动（re.md T-H3）：
-- 原两个 Think 钩子（KardsDeckCardMaterial / KardsBattleDeckCardMaterial）每帧对全部
-- sent_pmx_static_imported 实体全量扫描匹配属性；现改为「实体自身驱动」——实体创建
-- （OnEntityCreated）或 NW 属性变更（EntityNetworkedVarChanged）时注册到待初始化集合，
-- 下方单一 Think 钩子只处理集合成员、完成即移除，不再每帧全量扫描。两类卡牌按属性
-- 区分初始化路径：组卡 kards_deck_*（卡面 + 卡背 + 3D2D 文字）/ 卡组槽 kards_battledeck_*
--（仅卡背，不渲染正面纹理、不绑定文字）。
-- ====================================================================

-- 待初始化集合（weak keys：实体移除自动清理）：新实体创建或卡属性 NW 变更时入队，
-- 处理完成即移除；非卡牌实体（卡堆/手牌槽/牌桌模型等）入队后快速移出。
local cardPendingEntities = setmetatable({}, { __mode = "k" })
-- 实体 NW 初始值等待超时（秒）：批量创建卡牌时 NW 同步可能延迟 1 秒以上才全部到位，
-- 超时后仍未识别为卡牌（role 空）的实体从待初始化集合移除（见 Think KardsTableCardMaterial）
local KARDS_CARD_INIT_TIMEOUT = 3

-- 已处理卡组槽卡实体集合 / modelID 级就绪标记（weak keys：实体移除自动清理）
local battleDeckReady = setmetatable({}, { __mode = "k" })
local battleDeckModelReady = {}

-- 注册实体到待初始化集合（去重；NW 同步晚于实体创建，仅靠创建事件可能漏掉初始
-- NW 值，故 NW 变更事件（EntityNetworkedVarChanged）会再次入队兜底）
local function EnqueueCardEntity(ent)
    if IsValid(ent) and ent:GetClass() == "sent_pmx_static_imported" then
        cardPendingEntities[ent] = CurTime()
        -- 竞态兜底：初始 NW 同步晚于 OnEntityCreated（GetNWString 此时返回空），且 NW 值
        -- 作为初始状态到达时 EntityNetworkedVarChanged 不触发——若实体在 Think 的 else 分支
        -- 被移出集合（role 暂空），将永远不再处理（卡面文件不落盘、3D2D 文字不绑定）。
        -- 延迟复检：NW 就绪（role 为 deck/battledeck）后重新入队；非卡牌实体复检为空直接跳过。
        -- 已处理实体（deckCardReady 命中）复检入队为无害空转（ProcessDeckCard 守卫直接返回）。
        timer.Simple(0.5, function()
            if not IsValid(ent) then return end
            local role = ent:GetNWString("Kards_CardRole", "")
            if role == "deck" or role == "battledeck" then
                cardPendingEntities[ent] = CurTime()
            end
        end)
    end
end

hook.Add("OnEntityCreated", "KardsTableCardEnqueue", function(ent)
    EnqueueCardEntity(ent)
end)

-- NW 属性变更：卡属性就绪/更新 → 重新入队；翻面切换（Kards_GridFlipped）→ 即时
-- 移除/恢复 3D2D 文字并重新入队（原每帧对比 deckCardFlipped 检测变化，现事件驱动）
hook.Add("EntityNetworkedVarChanged", "KardsTableCardNWChanged", function(ent, key, oldv, newv)
    if not IsValid(ent) or ent:GetClass() ~= "sent_pmx_static_imported" then return end
    if key == "Kards_CardRole" or key == "Kards_DeckModelID" then
        cardPendingEntities[ent] = CurTime()
    elseif key == "Kards_GridFlipped" then
        if newv and KARDS.CardTextOverlay then
            KARDS.CardTextOverlay:Remove(ent) -- 翻面：移除已绑定的 3D2D 文字
        end
        deckCardReady[ent] = nil -- 翻面/恢复正面均清空就绪标记，重新初始化
        deckCardPending[ent] = nil
        cardPendingEntities[ent] = CurTime()
    end
end)

-- 组卡卡牌（kards_deck_*）单实体初始化：返回 true 表示本实体处理完成可从集合移除。
-- 同步准备（DeckPrepareCardFiles：manifest + PNG 复制）必须先于实体首次 Draw：Think
-- 阶段先于当帧渲染，保证前置模组首次 Material() 时文件已存在，避免引擎层缓存错误
-- 材质导致卡面白屏无纹理（见 DeckPrepareCardFiles 注释）。文字先以实体模式绑定
-- （NW 数据）：卡牌出现即文字出现，避免延迟初始化期间文字空白（随后 DeckInitCard
-- 无缝覆盖为本地富文本模式）。翻面卡（Kards_GridFlipped，达携带上限）：不渲染卡面
-- 与 3D2D 文字——卡面朝下由服务端 180° 旋转实现（init.lua SetGridFlipped，正面子网格
-- 转至 -z 朝下不可见），仅保证卡背纹理落盘；翻面/恢复正面变化由 NW 事件即时处理。
local function ProcessDeckCard(ent)
    local modelID = ent:GetNWString("Kards_DeckModelID", "")
    if modelID == "" then return false end -- NW 未就绪：保持入队等待后续 NW 事件
    local flipped = ent:GetNWBool("Kards_GridFlipped", false)
    if not deckCardReady[ent] and not deckCardPending[ent] then
        -- 卡面 PNG 落盘须早于实体首次 Draw：此处 Think 先于渲染阶段同步复制，
        -- 保证当帧渲染时文件已存在（新卡首帧即正常显示纹理，无需重启）。
        -- 翻面卡同样须先落盘卡背纹理（正面朝下不可见，卡背朝上需真实卡背图）
        local safeName = modelID:match("^kards_deck_(.+)$")
        if safeName and not deckModelReady[modelID] then
            local appearance, texturePath = DeckFindCardInfo(ent:GetNWString("Kards_CardName", ""))
            -- 总部卡（battle 模式 Kards_DeckRole="hq"）卡背固定 usa（测试版暂定）：
            -- 临时改写 country 写卡背，同步执行完立即还原，不影响其他卡
            local hqFixed = ent:GetNWString("Kards_DeckRole", "") == "hq" and appearance
            local savedCountry = hqFixed and appearance.country or nil
            if hqFixed then appearance.country = "usa" end
            local prepOk = DeckPrepareCardFiles(modelID, safeName, appearance, texturePath)
            if hqFixed then appearance.country = savedCountry end
            if prepOk then deckModelReady[modelID] = true end
        end
        if flipped then
            -- 翻面卡：仅保证卡背纹理就绪，不绑定任何 3D2D 文字
            deckCardReady[ent] = true
        else
            deckCardPending[ent] = true
            if KARDS.CardTextOverlay then KARDS.CardTextOverlay:AddEntity(ent) end
            timer.Simple(0.1, function()
                if IsValid(ent) then DeckInitCard(ent, modelID) end
            end)
        end
    end
    return true
end

-- 卡组槽卡牌（kards_battledeck_*）单实体初始化：仅复制卡背 PNG（front=back=卡背图，
-- 测试版统一 usa 卡背 materials/kards/cardbacks/usa.png，无论卡名国家；无卡组占位卡
-- 同样 usa）落盘到 data/kards_battledeck/<safeName>/，再 ClearCache 重建 renderable
-- 使前置模组按 manifest image_path 加载卡背——不绑定任何 3D2D 文字、不渲染正面纹理
-- （性能优化）。卡背 PNG 缺失时直接不写文件 → 前置模组按 image_path 加载缺失 → 白色
-- 兜底（与组卡「旧格式卡无卡面」回退行为一致）。同 modelID 副本仅首次执行文件 I/O
-- 与 ClearCache（battleDeckModelReady 去重）；本实体无论成败只尝试一次（battleDeckReady）。
-- 返回 true 表示可从集合移除。
local function ProcessBattleDeckCard(ent)
    local modelID = ent:GetNWString("Kards_DeckModelID", "")
    if modelID == "" then return false end -- NW 未就绪：保持入队等待后续 NW 事件
    if battleDeckReady[ent] then return true end
    battleDeckReady[ent] = true
    local safeName = modelID:match("^kards_battledeck_(.+)$")
    if safeName and not battleDeckModelReady[modelID] then
        -- 卡背统一 usa（测试版暂定：卡组槽卡背均为美国卡背，不看卡名国家）
        if KARDS.CardManifest.EnsureBattleDeck(modelID, safeName) then
            -- front=back=usa 卡背（WriteCardTextures 共享函数，re.md T-M1）：
            -- 卡背 PNG 缺失时不写文件 → 前置模组按 image_path 加载缺失 → 白色兜底
            local backData = file.Read("materials/kards/cardbacks/usa.png", "GAME")
            WriteCardTextures("kards_battledeck/" .. safeName, backData, backData, modelID)
            battleDeckModelReady[modelID] = true
        end
    end
    return true
end

-- 单一 Think：只处理待初始化集合（实体自身驱动，完成即移除；无新卡时集合为空，
-- 不再每帧全量扫描全部 sent_pmx_static_imported 实体）
hook.Add("Think", "KardsTableCardMaterial", function()
    for ent in pairs(cardPendingEntities) do
        if not IsValid(ent) then
            cardPendingEntities[ent] = nil
        elseif ent:GetNWString("Kards_CardRole", "") == "deck" then
            if ProcessDeckCard(ent) then cardPendingEntities[ent] = nil end
        elseif ent:GetNWString("Kards_CardRole", "") == "battledeck" then
            if ProcessBattleDeckCard(ent) then cardPendingEntities[ent] = nil end
        else
            -- NW 尚未就绪（role 空）：实体保留在集合中等待初始 NW 到达（批量创建时
            -- NW 同步可延迟 1 秒以上才全部到位，且初始值到达不触发
            -- EntityNetworkedVarChanged——立即移出将永久漏掉）。超过
            -- KARDS_CARD_INIT_TIMEOUT 仍无 role 才移出（非卡牌实体），后续 NW 变更再入队。
            -- 时间戳由 EnqueueCardEntity / EntityNetworkedVarChanged 入队时刷新（CurTime）
            local enqTime = cardPendingEntities[ent]
            if not enqTime or CurTime() - enqTime > KARDS_CARD_INIT_TIMEOUT then
                cardPendingEntities[ent] = nil
            end
        end
    end
end)

-- ====================================================================
-- 卡堆档位模型卡背文件预置（session 级，InitPostEntity 执行，同手牌槽
-- PrepareHandSlotFiles 的时序理由）：引擎材质按路径缓存——若 PNG/manifest 在实体
-- 首次请求材质后才落盘，本会话白屏无纹理直至重启。故在地图加载后、任何人进入对战
-- 之前，把 usa 卡背 PNG 复制到 data/kards_deckpile/usa/ 并改写全部档位模型 manifest
--（含单张档 basic_card 副本），保证卡堆实体首次 Draw 时文件已在。实体钩子
-- KardsBattleDeckPileMaterial 的 ClearCache 仅作兜底重建，不承担首发材质职责。
-- 幂等：成功后同会话不再重复文件 I/O；失败可重试。
-- ====================================================================
local deckPileFilesReady = false
local function PrepareDeckPileFiles()
    if deckPileFilesReady then return true end
    -- usa 卡背 PNG 落盘（front/back 均指向卡背图；缺失时前置模组白色兜底）
    file.CreateDir("kards_deckpile/usa")
    local backData = file.Read("materials/kards/cardbacks/usa.png", "GAME")
    if backData then
        file.Write("kards_deckpile/usa/front.png", backData)
        file.Write("kards_deckpile/usa/back.png", backData)
    end
    -- 改写档位模型 manifest（front/back → usa 卡背）；单张档先建 basic_card 副本
    if not KARDS.CardManifest.EnsureDeckPileSingle() then return false end
    for _, modelID in ipairs(DeckPileModelIDs) do
        if not EnsureDeckPileManifest(modelID) then return false end
    end
    deckPileFilesReady = true
    return true
end
hook.Add("InitPostEntity", "KardsDeckPileFiles", PrepareDeckPileFiles)

-- 卡堆档位实体卡背兜底（每帧）：档位模型 manifest 与卡背 PNG 已由
-- PrepareDeckPileFiles 在 InitPostEntity 预置；此处对出现的卡堆实体仅作兜底重试 +
-- ClearCache 重建一次（同 modelID 仅首次执行；前置模组 renderable 按 manifest 重建
-- 时读取 usa 卡背）。两槽共用同一组档位模型，故按 modelID 而非实体去重。
local deckPileModelReady = {}
hook.Add("Think", "KardsBattleDeckPileMaterial", function()
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWBool("Kards_IsBattleDeckPile", false) then
            local modelID = ent:GetNWString("Kards_DeckModelID", "")
            if modelID ~= "" and not deckPileModelReady[modelID] then
                if PrepareDeckPileFiles() then
                    deckPileModelReady[modelID] = true
                    -- 销毁该 modelID 旧 renderable：manifest（image_path）已就绪，
                    -- 强制实体 Draw 重建时按 image_path 加载 usa 卡背（档位模型每档唯一）
                    if PMXStaticImporter and PMXStaticImporter.ClearCache then
                        PMXStaticImporter.ClearCache(modelID)
                        -- back 槽 UV 镜像修正：ClearCache 后预填翻转材质（卡堆 back 槽朝下）
                        PrefillBackFlip(modelID)
                    end
                end
            end
        end
    end
end)

-- ====================================================================
-- 手牌槽卡牌卡面文件预置（session 级，回合开始即执行）：
-- 引擎材质按路径缓存——若 PNG/manifest 在实体首次请求材质后才落盘，本会话白屏无纹理
-- 直至重启（详见 DeckPrepareCardFiles 注释）。故在 InitPostEntity（地图加载后、任何人
-- 进入对战的牌桌实体与手牌槽卡创建之前）提前把 UK 卡背 PNG 复制到 data/kards_handslot/
-- 并写好 kards_handslot manifest，保证实体首次 ApplyImportedModel / Draw 时文件已在；
-- 实体钩子 KardsHandSlotCardMaterial 的 ClearCache 仅作兜底重建，不承担首发材质职责。
-- 仅写 back（朝下，-z 卡背子网格）：back 槽就是卡背——卡背 = UK 卡背图（卡背图片
-- 放卡背槽）；front（朝上，+z 卡面）不写文件 → 缺失白色兜底"正面"占位（卡牌平躺
-- 卡面朝上时俯视见 front，即"正面"，避免"正反两面都是卡背"；并删除旧会话可能残留的
-- front.png，否则引擎按路径缓存会继续加载旧卡背）。
-- 幂等：成功后同会话不再重复文件 I/O；失败可重试。
-- ====================================================================
local handSlotFilesReady = false
local function PrepareHandSlotFiles()
    -- 防御旧残留：front 槽=卡面，任何时候都不应存在卡背图（缺失 → 白色兜底"正面"）。
    -- 每次调用都删除 front.png（文件删除幂等，开销可忽略）：旧版本曾把卡背图写进
    -- front 槽（卡面方向 UV），卡背图按卡面方向采样会左右镜像；且引擎材质按路径缓存，
    -- 同会话内已加载的 front 卡背材质无法刷新，须靠删除文件 + 重启规避。
    file.Delete("kards_handslot/front.png")
    if handSlotFilesReady then return true end
    if not KARDS.CardManifest.EnsureHandSlot("kards_handslot") then
        return false
    end
    file.CreateDir("kards_handslot")
    local backData = file.Read("materials/kards/cardbacks/uk.png", "GAME")
    if backData then
        file.Write("kards_handslot/back.png", backData)
    end
    handSlotFilesReady = true
    return true
end
hook.Add("InitPostEntity", "KardsHandSlotFiles", PrepareHandSlotFiles)

-- ====================================================================
-- 手牌槽卡牌卡背初始化（battle 模式）：模型副本 kards_handslot（front 缺失白色
-- 兜底"正面"占位、back=UK 卡背图，服务端 CreateHandCardSlots 创建）。卡面文件已
-- 在 InitPostEntity 预置
-- （PrepareHandSlotFiles），此处对出现的实体仅作兜底重试 + ClearCache 重建一次
-- （两槽共享 modelID，同 modelID 仅首次执行）。
-- ====================================================================
local handSlotModelReady = {}
hook.Add("Think", "KardsHandSlotCardMaterial", function()
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWBool("Kards_IsHandSlotCard", false) then
            local modelID = ent:GetNWString("Kards_DeckModelID", "")
            if modelID ~= "" and not handSlotModelReady[modelID] then
                if PrepareHandSlotFiles() then
                    handSlotModelReady[modelID] = true
                    -- 销毁该 modelID 旧 renderable：manifest（image_path）已就绪，
                    -- 强制实体 Draw 重建时按 image_path 加载 UK 卡背（两槽共享 modelID）
                    if PMXStaticImporter and PMXStaticImporter.ClearCache then
                        PMXStaticImporter.ClearCache(modelID)
                        -- back 槽 UV 镜像修正：ClearCache 后预填翻转材质（手牌槽卡背朝下）
                        PrefillBackFlip(modelID)
                    end
                end
            end
        end
    end
end)

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
--   - 总部实体初始隐藏（服务端 SetNoDraw(true)，堆叠厚度由档位模型表现）；先手揭晓
--     动画（头像展示）完成后 StartHQReveal 显式 SetNoDraw(false) 并播放总部动画：
--     本方总部 → 本方头像左侧 / 敌方总部 → 敌方头像右侧（对称），动画结束落位本方
--     支援阵线第 3 槽
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
]]
hook.Add("Think", "KardsBattleDeckStackVisible", function()
    if not KARDS.BattleState.inTable then return end
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and not battleDeckDrawn[ent] and not battleHQLeft[ent] then
            if ent:GetNWString("Kards_CardRole", "") == "battledeck" then
                ent:SetNoDraw(false)
            end
        end
    end
end)

-- 总部对局开始动画中的活跃 HQ 集合（re.md 重构：动画本身由 KARDS.AnimPlayer 关键帧
-- 播放器驱动，组名 "hqReveal"；本表仅保留 { ent, slot } 供 InHQRevealAnim 遍历判定 +
-- 全部完成时播放一次 hq_end 收尾音效；每场对局最多两个：本方 + 敌方）
local hqReveals = {}

--[[
    总部对局开始动画：
      参战者（KardsFirstTurnRevealStart 序列结束时调用）：双方总部卡从卡组槽顶 1 秒
      移动到各自头像外侧（本方总部 → 本方头像左侧；敌方总部 → 敌方头像右侧，对称），
      期间卡背朝上翻转至卡面朝上；阶段1终点 z 抬升 REVEAL_HQ_FLANK_LIFT（头像外侧
      高处展示卡面）；随后 0.6 秒平滑滑向本方支援阵线第 3 槽落位。
      观战者（KardsTableBattleStart 广播分支调用，mySlot=nil）：无本方头像/相机接管，
      不经过头像外侧——直接翻转并移动到本方支援阵线第 3 槽落位（flankPos=支援阵线）。
      屏幕头像位置 → 牌桌平面世界坐标：取当前相机视线与桌面顶平面的交点
      （揭晓期间相机为固定俯视视角，见 KardsTableBattleStart 的目标相机）。
--]]
-- 总部对局开始动画（定义见下方 KardsHQReveal* 段；此处必须用「赋值」而非 local function
-- 重新声明——同作用域重复 local 会创建新局部变量遮蔽上方前向声明，导致上方钩子闭包
-- 捕获的 upvalue 恒为 nil，调用时报错）
StartHQReveal = function(tableEnt, mySlot)
    if not IsValid(tableEnt) then return end
    local ply = LocalPlayer()
    -- 参战者（mySlot 非 nil）才有头像外侧环节：相机接管期间取视线与桌面交点；
    -- 观战者（mySlot=nil）直接落位支援阵线，不依赖相机（观战用自由视角）
    local camPos = nil
    if mySlot then
        local cam = KARDS.BattleCamera and KARDS.BattleCamera.Cameras[ply]
        camPos = cam and cam.active and cam.pos or nil
    end
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
                -- 头像外侧（对称）：本方 → 左方头像左侧；敌方 → 右方头像右侧
                local sx = isMine and (ScrW() * 0.30 - REVEAL_AVATAR_SIZE)
                                    or (ScrW() * 0.70 + REVEAL_AVATAR_SIZE)
                local sy = ScrH() * 0.50
                -- 屏幕 → 牌桌平面交点（桌面顶局部 z = Board2D.CardZ）
                local world = nil
                if camPos then
                    local dir = gui.ScreenToVector(sx, sy)
                    local planeZ = tableEnt:LocalToWorld(Vector(0, 0, KARDS.Animation.Board2D.CardZ)).z
                    if dir.z < 0 then
                        world = camPos + dir * ((planeZ - camPos.z) / dir.z)
                    end
                end
                -- 兜底（相机不可用 / 视线不朝下）：直接落位本方支援阵线第 3 槽
                local flankPos = world and tableEnt:WorldToLocal(world)
                    or KARDS.Animation.Board2D:RelPos(3, row)
                -- 阶段1终点（头像外侧）z 抬升（REVEAL_HQ_FLANK_LIFT）：世界交点/兜底
                -- 均在桌面顶（z=CardZ），抬高后总部在头像外侧高处展示卡面，随后阶段2
                -- 从高处滑落桌面落位（2026-08-10）
                flankPos.z = flankPos.z + REVEAL_HQ_FLANK_LIFT
                local supportPos = KARDS.Animation.Board2D:RelPos(3, row)
                -- 落位朝向 = 本地视角朝向（基础规则：P1 视角所有牌朝 P2 / P2 视角所有牌朝
                -- P1 / 观战按归属方；见 cl_perspective.lua FacingYaw，2026-08-10 起反向）。总部动画全程使用该
                -- 朝向（翻转独立绕 x 轴，yaw 与之不冲突），动画结束后由 KardsFieldFacing
                -- 驱动持续接管（角度一致无跳变）
                local facing = KARDS.Perspective and KARDS.Perspective.FacingYaw
                    and KARDS.Perspective:FacingYaw(KARDS.Perspective.LocalView, slot) or 0
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
                -- 3 帧关键帧动画（re.md 重构：KARDS.AnimPlayer 驱动，组名 "hqReveal"）：
                --   帧 1 → 帧 2（dur1=1.0s）：卡堆顶 → 头像外侧（z 抬升），卡背翻转为
                --   卡面（pitch 180→0），yaw 从卡堆角度（fromYaw，±45/-135）沿最短路径
                --   渐变到 facing；帧 2 → 帧 3（dur2=0.6s）：从高处平滑滑落支援阵线
                --   第 3 槽（角度保持 facing）。缓动 smooth = 原 RevealEaseInOut
                local fromPos = ent:GetLocalPos()
                local fromYaw = ent:GetLocalAngles().y -- 动画起点 yaw（卡堆角度 ±45/-135，阶段1 渐变到 facing）
                list[#list + 1] = { ent = ent, slot = slot } -- 活跃 HQ 集合（InHQRevealAnim 遍历）
                KARDS.AnimPlayer:Play(ent, {
                    { t = 0, pos = fromPos, ang = Angle(180, fromYaw, 0) },
                    { t = 1.0, pos = flankPos, ang = Angle(0, facing, 0) },
                    { t = 1.6, pos = supportPos, ang = Angle(0, facing, 0) },
                }, {
                    group = "hqReveal",
                    easing = "smooth", -- 原 RevealEaseInOut（翻转 / 滑落同一曲线）
                    onComplete = function(target)
                        -- 总部落位支援阵线第 3 槽：登记进 KARDS.BattleState.fieldLayouts（服务端 HQ 恒参与居中，
                        -- 见 BroadcastFieldLayout；首次广播前拖拽预览/飞行的偶数偏移计数含总部，
                        -- 2026-08-10 部署落位修复）
                        KARDS.BattleState.fieldLayouts[slot][target] = 3
                        -- 2026-08-11：总部动画结束 → 切换 basic_card_unit 模型（短卡 + UV
                        -- 裁切，与单位一致）。客户端本地准备 manifest + 裁切材质 + 重绑短卡
                        -- 尺寸文字；参战者通知服务端 ApplyImportedModel 权威切换（观战者
                        -- 渲染随服务端切换同步，本地仅准备 manifest + 文字）
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
                            end
                        end
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
    local cardName = ent:GetNWString("Kards_CardName", "")
    -- 卡名 NW 未就绪：外观数据（appearance/textureSize）无法匹配，不标记就绪，
    -- 调用方（drawFacePending Think 重试）等 NW 同步后再初始化
    if cardName == "" then return false end
    local appearance, texturePath, textureSize = DeckFindCardInfo(cardName)
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
        if PMXStaticImporter and PMXStaticImporter.ClearCache then
            PMXStaticImporter.ClearCache(modelID)
            -- back 槽 UV 镜像修正：ClearCache 后预填翻转材质（抽牌临时卡翻面后 back 槽可见）
            PrefillBackFlip(modelID)
        end
    end
    -- 标记为已处理：防止统一驱动 KardsTableCardMaterial 再把 manifest 写回卡背
    drawFaceReady[ent] = true
    battleDeckReady[ent] = true
    battleDeckModelReady[modelID] = true
    -- 绑定 3D2D 文字（外观编辑器生成 3D2D 预览卡同款，cl_canvas_editor.lua SpawnTestEntity
    -- mode=="3d2d"）：AddLocal 本地外观表 + 渲染像素尺寸 → 文字分布/字号与编辑器预览
    -- 完全一致（appearance 静态表每帧实时读；renderW/H = 保存文件记录的渲染尺寸，
    -- 与卡面纹理像素对齐，缺省 300×400）
    if appearance and KARDS.CardTextOverlay then
        local texW, texH = 300, 400
        if textureSize and textureSize.w and textureSize.h then
            texW, texH = textureSize.w, textureSize.h
        end
        KARDS.CardTextOverlay:AddLocal(ent, appearance, 7.2, 10.8, texW, texH)
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

-- 手牌槽常量（与服务端 ENT.HandSlot* 同步硬编码：客户端实体对象上不存在服务端 ENT
-- 字段，访问 tableEnt.HandSlotBase 等会得 nil → 算术错误；数值变更须与服务端同步）
local HandSlotBase    = Vector(0, 0, 30.5)  -- 手牌中心卡位置（桌面中心正上方，z 抬升更高；与服务端同步，见 init.lua L1333）
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
local HandSlotHoverLift = 1.6   -- 悬停提升量：鼠标悬停本方手牌时沿自身 y 轴的最大移动量（单位，可微调）
local HandSlotHoverDur = 0.1   -- 悬停提升时长（秒）：0.1 秒内增加到满量（离开同样 0.1 秒回落）
local HandSlotHoverRadius = 12 -- 悬停判定半径：鼠标射线到手牌中心的最大距离（单位）

-- ====================================================================
-- 左右展示槽常量（2026-08-11，牌桌卡动画系统坐标常量，见 re.md §3.2 姿态库）：
--   左侧展示 / 右侧展示——牌桌俯视视角（P1 视角：−x 为左侧 / +x 为右侧；2026-08-11
--   实测修正：原按战场列注释「+x 为左」设置与实际视觉左右相反，已交换）左右对称的
--   两个固定展示位，供卡牌展示 / 信息陈列类动画使用（{ pos, ang } 即 re.md 6 值姿态
--   帧结构，可直接喂 AnimPlayer）。
--   位置：x = ±DisplaySlotHalfX（俯视视角区分左右，仅 x 符号不同；2026-08-11 由
--   ±24 收拢到 ±14，更靠近屏幕中心——相机在 (-70,0,30) 近水平朝牌桌中线看，越靠近
--   中线越接近画面中央）、y = 0（牌桌中线）、z = DisplaySlotZ（2026-08-11 由
--   手牌层 30.5 抬高到 40，浮于战场上方更醒目、贴近相机瞄准线高度；测试定位期间
--   观战视角曾用 DisplaySlotSpectatorZ=22.5 贴桌面验证，占位卡已移除后锁定 z=40）。
--   角度：Angle(0, 0, 0)——相对牌桌 yaw = 0（与牌桌 x/y 轴对齐，不随本地视角 / 手牌
--   扇形旋转），pitch/roll 归零 = 正面朝上（平躺，同手牌姿态）。
-- ====================================================================
local DisplaySlotHalfX = 14  -- 左右展示槽 x 半距（俯视视角：左侧 −x / 右侧 +x；数值可调）
local DisplaySlotZ = 40      -- 展示槽 z（进桌对战视角 LocalView=1|2，浮于战场/手牌之上；数值可调）
local DisplaySlots = {
    [1] = { pos = Vector(-DisplaySlotHalfX, 0, DisplaySlotZ), ang = Angle(0, 0, 0) }, -- 左侧展示
    [2] = { pos = Vector( DisplaySlotHalfX, 0, DisplaySlotZ), ang = Angle(0, 0, 0) }, -- 右侧展示
}

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
-- 见 KardsTableDeckDraw 爆牌分支）：卡堆顶 → 右卡槽（DisplaySlots[2]）→ 停留
-- OverdrawHold 秒 → 顺时针出场（ClockwiseExitPose）
local OverdrawFlyDur = 0.45  -- 卡堆顶 → 右卡槽飞行时长（秒，同抽牌动画 dur1）
local OverdrawHold = 1.0     -- 右卡槽停留时长（秒，1 秒后顺时针出场，用户指定）
local OverdrawExitDur = 0.4  -- 顺时针出场动画时长（秒，同抽牌动画 dur2）

-- 手牌拿起 / 拖拽 / 打出 常量（2026-08-10）：拖拽机制在悬停提升基础上扩展——
-- 按下左键拿起（z 抬升 + xy 跟随鼠标、悬停失效、播放「拿起卡牌」音效）；松手
-- 在手牌区域渐变回原位，否则打出（单位进本方支援阵线、指令进战斗系统）。
-- 拖拽抬升 z 不设固定常量：按当前手牌张数取扇形 z 理论最大值（阶梯最高层）
-- 上方 0.1（KardsDragCardThink 内计算），避免固定 40 与手牌层落差过大。
local HandSlotLiftDur = 0.1       -- 拿起 z 抬升 / 松手 z 回落时长（秒）
local HandSlotFlightDur = 0.35    -- 打出飞行动画时长（秒）
local HandSlotReturnDur = 0.2     -- 松手回手牌渐变时长（秒）
local HandSlotReposDur = 0.15     -- 腾位预览 / 布局复位动画时长（秒）
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
-- （替代宽泛的中心距离判定）。挂 KARDS 命名空间同理不占局部槽。
function KARDS.RayCardHit(origin, dir, ent, halfW, halfL)
    local plane = ent:GetUp()
    local denom = dir:Dot(plane)
    if math.abs(denom) < 1e-4 then return false end -- 射线与卡面平行（俯视不会发生）
    local t = (ent:GetPos() - origin):Dot(plane) / denom
    if t < 0 then return false end
    local lp = ent:WorldToLocal(origin + dir * t)
    return math.abs(lp.x) <= halfW and math.abs(lp.y) <= halfL
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
local function HandFanPos(slot, i, n)
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
    local total = fwd:Angle()
    local r0 = total:Right()
    total.roll = total.roll + math.deg(math.atan2(fwd:Cross(r0):Dot(rgt), r0:Dot(rgt)))
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
    local list = {}
    for e, idx in pairs(KARDS.BattleState.realHandCards[slot]) do
        if IsValid(e) and e ~= skipEnt then list[#list + 1] = { e, idx } end
    end
    table.sort(list, function(a, b) return a[2] < b[2] end)
    local n = targetN or #list
    for i, it in ipairs(list) do
        local e = it[1]
        KARDS.BattleState.realHandCards[slot][e] = i
        local pos, ang = HandFanPos(slot, i, n)
        -- 位置/角度 6 值两关键帧（cos 缓动）；首帧快照当前姿态 → 从当前位置渐变到新扇形位
        KARDS.AnimPlayer:Play(e, {
            { t = 0, pos = e:GetLocalPos(), ang = e:GetLocalAngles() },
            { t = HandSlotReposDur, pos = pos, ang = ang },
        }, { group = "handRepos", easing = "cos" })
    end
end
-- 牌桌中间扇形相对坐标（重新调度发牌 / 选择期间显示；不重叠横排，卡宽 7.2 留缝 0.8，
-- 整体 z 抬高于桌面顶 CardZ + 3.4，贴近视线便于选择）
local function MulliganFanPos(i, n)
    local centerIdx = (n + 1) / 2
    -- k 取 centerIdx - i（2026-08-10 反向）：i=1（第一张抽的牌）落视觉左侧
    -- （P1 视角 +x），发牌/补抽从左侧开始往右填卡槽；原 k=i-centerIdx 时
    -- i=1 落 -x（P1 视角右侧），表现为从右开始填
    local k = centerIdx - i
    return Vector(k * 8.0, 0, KARDS.Animation.Board2D.CardZ + 3.4)
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

-- 服务端抽牌通知（OnBattleDraw 广播，含重新调度发牌/补抽）：抽牌临时卡实体
-- （卡堆顶，见 table_battledeck.lua SpawnDeckDrawCard）→ 按「槽位 × 补抽标记 ×
-- 本方/对方」路由：
--   本方 + 非补抽 + 未完成重新调度 → 起手发牌：牌桌中间扇形（MulliganFanPos，可点击选择）
--   本方 + 补抽（isReplace，确认后）→ 补抽卡飞向牌桌中间扇形区空位（被弃卡原序号
--     位置，与保留卡一起待 0.7s 统一落手牌，见 KardsMulliganAnimsUpdate 末段）
--   爆牌（overdraw，readme 7.1 手牌上限 9：手牌已达上限）→ 专属弃牌动画：卡堆顶 →
--     右卡槽（DisplaySlots[2]）停留 OverdrawHold 秒 → 顺时针出场（ClockwiseExitPose），
--     动画结束移除实体（手牌不变，不重排扇形 / 不登记 KARDS.BattleState.realHandCards）
--   对方 / 观战（非本方）→ 直接落该槽手牌位（HandFanPos，卡背朝上：本方客户端
--     不改写 manifest，被抽卡两面子网格均为卡背图 → 任何姿态看到的都是卡背，
--     对方牌面不可见）
net.Receive("KardsTableDeckDraw", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local idx = net.ReadUInt(8)
    local total = net.ReadUInt(8)
    local isReplace = net.ReadBool()
    local isOverdraw = net.ReadBool() -- 本张卡爆牌标记（手牌已达上限 9，服务端数据层 per-card 判定）
    net.ReadString() -- 卡名（材质数据源用实体 NW Kards_CardName）
    if not IsValid(ent) then return end
    battleDeckDrawn[ent] = true -- 从堆叠移除（可见性钩子跳过，动画驱动接管）
    KARDS.BattleState.entSpawnPos[ent] = ent:GetLocalPos() -- 弃牌回卡组动画的终点（服务端卡堆顶）
    local isMine = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot
    -- 本方起手发牌且该槽未完成重新调度 → 牌桌中间扇形选择阶段
    if isMine and not isReplace and not KARDS.BattleState.mulliganDoneSlot[slot] then
        InitDrawCardFace(ent) -- 本方需看卡面选择（NW 未就绪则入队，Think 重试）
        drawFacePending[ent] = true
        ent:SetNoDraw(false)
        local m = KARDS.BattleState.mulligan
        if not m or m.slot ~= slot or m.submitted then
            m = { active = false, slot = slot, total = total, cards = {}, submitted = false }
            KARDS.BattleState.mulligan = m
            -- 选择在发牌动画全部结束后才启用（active 延迟置 true，见
            -- KardsMulliganAnimsUpdate 发牌循环后）
        end
        m.cards[ent] = { ent = ent, index = idx, selected = false }
        -- 发牌动画：卡堆顶 → 牌桌中间扇形，抽牌动画同款翻面（pitch 180 卡背朝上
        -- 离堆 → 0 卡面朝上落位）+ yaw 从卡堆角度渐变到朝向本方；取消全程强制
        -- 正面（2026-08-10 反馈）。错峰发牌：delay 使前一槽动画进行一半（dur 0.5
        -- → 0.25s）时开始下一槽；翻面音效在动画实际启动时播放（onStart）。
        -- （re.md 重构：KARDS.AnimPlayer 6 值两关键帧）
        local endYaw = (slot == 1) and 180 or 0 -- 文字朝本方（P1 yaw180 / P2 yaw0：P1 卡组槽在牌桌 -x 侧，文字顶部需朝 +x 才正对 P1）
        KARDS.AnimPlayer:Play(ent, {
            { t = 0, pos = ent:GetLocalPos(), ang = Angle(180, ent:GetLocalAngles().y, 0) },
            { t = 0.5, pos = MulliganFanPos(idx, m.total), ang = Angle(0, endYaw, 0) },
        }, {
            group = "mulliganDeal",
            delay = (idx - 1) * 0.25,
            onStart = function() KARDS.PlayKardsSound("draw") end, -- 翻面音效在动画实际启动时播放
        })
        return
    end
    -- 本方重新调度补抽（isReplace=true，KardsMulliganDone 已置 submitted）：补抽卡
    -- 从卡堆飞向牌桌中间扇形区的空位（被弃牌原序号位置），与保留卡一起待 0.7s 后
    -- 统一进手牌（2026-08-10 补充动画，见 KardsMulliganAnimsUpdate 末段统一落位）
    if isMine and isReplace and KARDS.BattleState.mulligan and KARDS.BattleState.mulligan.slot == slot then
        InitDrawCardFace(ent) -- 本方需看卡面（补抽卡进入中间扇形区待命）
        drawFacePending[ent] = true
        ent:SetNoDraw(false)
        KARDS.BattleState.mulligan.cards[ent] = { ent = ent, index = idx, selected = false }
        KARDS.BattleState.mulligan.replaceGot = (KARDS.BattleState.mulligan.replaceGot or 0) + 1 -- 已收到补抽卡计数
        -- 发牌动画同款（卡堆顶 → 中间扇形区空位，翻面 + yaw 朝向本方）；错峰 delay
        -- 同起手发牌（按被弃原序号）；补抽不播抽牌音效（2026-08-10 需求：点击确定后
        -- 的抽牌静音，不注册 onStart 音效回调）
        local endYaw = (slot == 1) and 180 or 0
        KARDS.AnimPlayer:Play(ent, {
            { t = 0, pos = ent:GetLocalPos(), ang = Angle(180, ent:GetLocalAngles().y, 0) },
            { t = 0.5, pos = MulliganFanPos(idx, KARDS.BattleState.mulligan.total), ang = Angle(0, endYaw, 0) },
        }, {
            group = "mulliganDeal",
            delay = (idx - 1) * 0.25,
        })
        return
    end
    -- 爆牌（readme 7.1 手牌上限 9）：手牌已达上限，抽到的卡不进手牌，播放专属
    -- 弃牌动画——卡堆顶 → 右卡槽（DisplaySlots[2]）停留 OverdrawHold 秒 → 顺时针
    -- 出场（ClockwiseExitPose）；动画结束隐藏实体（手牌不变：不 RenumberHand /
    -- 不登记 KARDS.BattleState.realHandCards / 不掉落手牌位）。本方看卡面（InitDrawCardFace），
    -- 对方/观战看卡背（不改写 manifest）。
    if isOverdraw then
        if isMine then
            InitDrawCardFace(ent)
            drawFacePending[ent] = true
        end
        ent:SetNoDraw(false)
        local slotPose = DisplaySlots[2] -- 右卡槽（右侧展示位：x=-DisplaySlotHalfX / z=DisplaySlotZ）
        local startAng = Angle(180, ent:GetLocalAngles().y, 0) -- 卡背朝上离堆（同抽牌动画）
        local flyPose = { pos = slotPose.pos, ang = Angle(0, slotPose.ang.y, 0) } -- 右卡槽平躺正面朝上
        local exitPose = ClockwiseExitPose(flyPose) -- 顺时针出场终点（向右飞 ExitFlyDist、yaw −135°）
        -- 4 关键帧：卡堆顶 → 右卡槽（翻面）→ 右卡槽停留（第二、三关键帧同姿）→ 顺时针出场
        KARDS.AnimPlayer:Play(ent, {
            { t = 0, pos = ent:GetLocalPos(), ang = startAng },
            { t = OverdrawFlyDur, pos = flyPose.pos, ang = flyPose.ang },
            { t = OverdrawFlyDur + OverdrawHold, pos = flyPose.pos, ang = flyPose.ang },
            { t = OverdrawFlyDur + OverdrawHold + OverdrawExitDur, pos = exitPose.pos, ang = exitPose.ang },
        }, {
            group = "deckOverdraw",
            onComplete = function(target)
                -- 爆牌：卡被弃，隐藏实体（同弃牌回卡组；抽牌临时卡为服务端网络实体，
                -- 客户端不可 Remove，由服务端 ExitSlot / 牌桌 OnRemove 统一清理）
                if IsValid(target) then target:SetNoDraw(true) end
            end,
        })
        return
    end
    -- 其余（对方/观战补抽 / 后续回合抽牌）：直接落手牌扇形（原位）
    local faceUp = isMine -- 本方看卡面；对方/观战看卡背（不改写 manifest）
    if faceUp then
        InitDrawCardFace(ent)
        drawFacePending[ent] = true
    end
    ent:SetNoDraw(false)
    KARDS.BattleState.realHandCards[slot][ent] = idx
    -- 剩余手牌按新张数重排扇形（2026-08-11 修复：原 StartHandShift 只按
    -- Kards_IsHandSlotCard 左移 2.5——占位空手牌移除后无人设置该 NW → 恒为空操作，
    -- 导致抽牌后既有手牌不随新张数更新扇形分布（KardsRealHandFacing 仅驱动角度，
    -- 位置仍停旧扇形）。此处立即按服务端广播的 total 重排：位置/角度平滑过渡到
    -- 新扇形位；新卡经 deckDraw 动画落位（skipEnt 排除，避免 Play 替换其飞行动画））
    RenumberHand(slot, ent, total)
    local handPos, handAng = HandFanPos(slot, idx, total) -- 预设扇形落位（位置+角度，服务端同款）
    local endYaw = handAng.y -- 落手牌位朝向（HandFanPos：位置基准 + fan 角 + 文字朝向）
    -- 补抽：卡堆顶 → 手牌原位直接飞行（与弃牌回卡组动画同时进行）；
    -- 非补抽（对方起手发牌 / 后续回合抽牌）：经牌桌中间翻面后落手牌
    local skipCenter = isReplace
    local dur1, hold, dur2 = 0.45, skipCenter and 0 or 0.5, skipCenter and 0.25 or 0.4
    -- 桌中终点：z 抬升于桌面顶 +3.4（与重新调度发牌 MulliganFanPos 同高，贴近视线；
    -- 2026-08-11 修复：原 z=CardZ 贴桌面，抽牌翻面阶段过低）
    local centerPos = skipCenter and handPos
        or (KARDS.Animation.Board2D:RelPos(3, 0) + Vector(0, 0, 3.4))
    -- 桌中阶段朝向本方（P1 yaw180 / P2 yaw0，与重新调度发牌落位一致；2026-08-11
    -- 修复：原固定 0° 对 P1 文字朝向反了）/ 直接飞行朝向本方
    local centerYaw = skipCenter and endYaw or ((slot == 1) and 180 or 0)
    local pitch0 = faceUp and 180 or 0 -- 翻面：本方卡 卡背朝上 → 卡面朝上 / 对方保持卡背朝上
    -- 4 关键帧：卡堆顶 → 桌中（翻面 + yaw 朝向本方）→ 桌中停留（两相同帧）→ 手牌位
    -- （re.md 重构：KARDS.AnimPlayer；越过停留帧（离开桌中）触发手牌槽卡左移 StartHandShift）
    KARDS.AnimPlayer:Play(ent, {
        { t = 0, pos = ent:GetLocalPos(), ang = Angle(pitch0, ent:GetLocalAngles().y, 0) },
        { t = dur1, pos = centerPos, ang = Angle(0, centerYaw, 0) },
        { t = dur1 + hold, pos = centerPos, ang = Angle(0, centerYaw, 0), event = "shift" },
        { t = dur1 + hold + dur2, pos = handPos, ang = Angle(0, endYaw, 0) },
    }, {
        group = "deckDraw",
        onKeyframe = function(target, name)
            if name == "shift" then StartHandShift() end -- 阶段 3：为新卡让位
        end,
    })
end)

-- 手牌槽卡左移动画驱动（每帧）：抽牌动画阶段 3（KardsTableDeckDraw 的
-- "deckDraw" 组动画离开桌中停留帧时触发 StartHandShift）后，本玩家手牌槽卡
-- 向左移动部分为新卡让位；占位空手牌已移除后该部分为空操作。抽牌动画本体由
-- KARDS.AnimPlayer 驱动（re.md 重构），本钩子仅保留多实体批量平移。
hook.Add("Think", "KardsDeckDrawUpdate", function()
    -- 手牌槽卡左移（阶段 3 触发）
    if deckDrawShift then
        local t = (CurTime() - deckDrawShift.start) / deckDrawShift.dur
        local e = RevealEaseInOut(math.min(t, 1))
        for _, item in ipairs(deckDrawShift.items) do
            if IsValid(item.ent) then
                local pos = item.ent:GetLocalPos()
                item.ent:SetLocalPos(Vector(item.fromX + item.dx * e, pos.y, pos.z))
            end
        end
        if t >= 1 then deckDrawShift = nil end
    end
end)

-- ====================================================================
-- 重新调度完成广播（服务端 OnMulliganSubmit，先于补抽发牌广播）：
--   本方：被弃卡从牌桌中间回卡组；保留卡留在中间扇形区不移动，被弃卡空位
--     等待补抽卡飞入（KardsTableDeckDraw isReplace 分支），0.7s（toHandAt）
--     后中间扇形区卡统一落手牌位（见 KardsMulliganAnimsUpdate 末段统一落位）；
--   对方/观战：被弃卡从对方手牌位回卡组（对方保留卡本就停手牌位，不移动），
--     补抽卡直接落手牌原位（见上方接收器 skipCenter 分支）。
-- ====================================================================
net.Receive("KardsMulliganDone", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local n = net.ReadUInt(8)
    local ents = {}
    for _ = 1, n do ents[#ents + 1] = net.ReadEntity() end
    if not IsValid(ent) then return end
    KARDS.BattleState.mulliganDoneSlot[slot] = true
    local isMine = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot
    -- 被弃卡回卡组：从当前所在位置（本方=牌桌中间 / 对方=手牌位）飞回卡堆顶
    if #ents > 0 then KARDS.PlayKardsSound("shuffle") end -- 洗牌音效（弃牌洗入卡组，一次）
    for _, e in ipairs(ents) do
        if IsValid(e) then
            -- 回卡组动画（re.md 重构：KARDS.AnimPlayer 6 值两关键帧）：翻回卡背朝上
            -- （本方被弃卡原本卡面朝上；对方/观战本就卡背无变化）飞回卡堆顶，
            -- 结束 SetNoDraw 回卡堆档位 + 移出真实手牌
            KARDS.AnimPlayer:Play(e, {
                { t = 0, pos = e:GetLocalPos(), ang = Angle(0, e:GetLocalAngles().y, 0) },
                { t = 0.55, pos = KARDS.BattleState.entSpawnPos[e] or PileBase[slot], ang = Angle(180, PileYaw[slot], 0) },
            }, {
                group = "mulliganReturn",
                onComplete = function(target)
                    if IsValid(target) then target:SetNoDraw(true) end -- 已回到卡组内（卡堆档位模型表现厚度）
                    KARDS.BattleState.realHandCards[slot][target] = nil
                end,
            })
            KARDS.BattleState.realHandCards[slot][e] = nil
        end
    end
    -- 本方：保留卡留在牌桌中间扇形区（不移动，2026-08-10 补充动画），被弃卡空位
    -- 等待补抽卡飞入；0.7s 后中间扇形区卡（保留 + 补抽）统一进手牌，见
    -- KardsMulliganAnimsUpdate 末段统一落位（KARDS.BattleState.mulligan 保留至落位完成）
    if isMine and KARDS.BattleState.mulligan and KARDS.BattleState.mulligan.slot == slot then
        KARDS.BattleState.mulligan.toHandAt = CurTime() + 0.7     -- 确认后 0.7s 统一落手牌（可微调）
        KARDS.BattleState.mulligan.expectedReplace = #ents        -- 补抽卡数 = 被弃卡数（服务端原位替换）
        KARDS.BattleState.mulligan.replaceGot = 0                 -- 已收到补抽卡计数（随补抽广播递增）
        for _, e in ipairs(ents) do
            if IsValid(e) then KARDS.BattleState.mulligan.cards[e] = nil end -- 被弃卡移出待落位表
        end
        UpdateTableMouse() -- 仍处牌桌内：鼠标保持呼出（2026-08-10）
        KARDS.BattleState.prevMulliganLeft = false
    end
end)

-- 重新调度动画驱动（每帧）：发牌 / 弃牌回卡组 / 落手牌动画本体由 KARDS.AnimPlayer
-- 驱动（re.md 重构），本钩子仅保留「发牌完成判定」与「统一落位调度」两段业务逻辑
hook.Add("Think", "KardsMulliganAnimsUpdate", function()
    -- 发牌动画全部结束后才允许选择（2026-08-10 补充动画）：KARDS.BattleState.mulligan 创建时
    -- active=false，待所有发牌（起手/补抽）动画完成（"mulliganDeal" 组清空）
    -- 后置 active=true，选择交互 / 确认按钮 HUD 才生效
    if KARDS.BattleState.mulligan and not KARDS.BattleState.mulligan.active and not KARDS.BattleState.mulligan.submitted
        and not KARDS.AnimPlayer:Any("mulliganDeal") then
        KARDS.BattleState.mulligan.active = true
    end
    -- 统一落位（2026-08-10 补充动画）：KardsMulliganDone 设 toHandAt（确认后 0.7s）。
    -- 到时后，中间扇形区的卡（保留 + 已到达的补抽）逐张落手牌位（HandFanPos）；
    -- 仍在飞入的补抽卡（"mulliganDeal" 组动画）等其落位后再启动（晚到不搁浅）；
    -- 全部落位完成后清理 KARDS.BattleState.mulligan（保留至此刻：补抽卡才知该飞向中间区空位）。
    -- 每张卡只启动一次（card.toHandStarted），落位期间由 AnimPlayer 驱动，
    -- 结束后 KARDS.BattleState.realHandCards 登记仍保留，KardsRealHandFacing 兜底接管角度。
    if KARDS.BattleState.mulligan and KARDS.BattleState.mulligan.submitted and KARDS.BattleState.mulligan.toHandAt
        and CurTime() >= KARDS.BattleState.mulligan.toHandAt then
        -- 抽牌音效：存在本帧待启动落位的卡（保留/补抽 中间扇形区 → 手牌）时播一次，
        -- 避免每张各播一次叠音（统一落位一次即可）
        local willStart = false
        for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
            if IsValid(ce) and not card.toHandStarted
                and not KARDS.AnimPlayer:Active(ce, "mulliganDeal") then
                willStart = true
                break
            end
        end
        if willStart then KARDS.PlayKardsSound("draw") end
        local allSettled = true
        local anyValid = false
        for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
            if IsValid(ce) then
                anyValid = true
                if not card.toHandStarted then
                    if KARDS.AnimPlayer:Active(ce, "mulliganDeal") then
                        allSettled = false -- 补抽卡仍在飞入：等其落位（下一帧再启动）
                    else
                        card.toHandStarted = true
                        local toPos, toAng = HandFanPos(KARDS.BattleState.mulligan.slot, card.index, KARDS.BattleState.mulligan.total)
                        -- 落手牌位：位置渐变到扇形槽位 + yaw 渐变到扇形角度（无翻面，pitch 恒 0）
                        KARDS.AnimPlayer:Play(ce, {
                            { t = 0, pos = ce:GetLocalPos(), ang = Angle(0, ce:GetLocalAngles().y, 0) },
                            { t = 0.5, pos = toPos, ang = Angle(0, toAng.y, 0) },
                        }, { group = "mulliganToHand" })
                        KARDS.BattleState.realHandCards[KARDS.BattleState.mulligan.slot][ce] = card.index
                        allSettled = false -- 本帧刚启动，等动画结束
                    end
                elseif KARDS.AnimPlayer:Active(ce, "mulliganToHand") then
                    allSettled = false -- 落位动画进行中
                end
            end
        end
        if anyValid and allSettled then
            KARDS.BattleState.mulligan = nil -- 全部落位完成：清理（退出牌桌/新对局本就重置，此处为常态清理）
        end
    end
end)

-- ====================================================================
-- 重新调度选择交互：牌桌中间扇形卡 左键点击 选中/取消（选中=丢弃，卡沿法线上抬）；
-- 屏幕点击器在重新调度期间开启（自由鼠标：点卡片 + 点准星下方「确认」按钮），
-- 提交 / 完成 / 退出时关闭。
-- ====================================================================

-- 选中卡图标材质（materials/kards/cards/choose.png，3D2D 绘制于卡面上方 z+0.1）
local chooseMat = Material("materials/kards/cards/choose.png", "noclamp smooth")

-- 射线到牌桌中间扇形卡的最近距离判定（同卡堆悬停 KARDS.RayPointDistSqr 方法）
local function HitMulliganCard(mX, mY)
    local ply = LocalPlayer()
    if not IsValid(ply) then return nil end
    local pos = KARDS.BattleCamera.ViewPos or ply:EyePos()
    local dir = gui.ScreenToVector(mX, mY)
    if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then return nil end
    local bestEnt, bestD = nil, 100 -- 阈值 10^2（扇形卡间距 4 单位，半对角 ~6.5）
    for ce in pairs(KARDS.BattleState.mulligan.cards) do
        if IsValid(ce) then
            local d = KARDS.RayPointDistSqr(pos, dir, ce:GetPos())
            if d < bestD then bestEnt, bestD = ce, d end
        end
    end
    return bestEnt
end

-- 提交重新调度（点击「确认」）：被选中的卡 = 不想要的牌 → 发送服务端
local function SubmitMulligan()
    if not KARDS.BattleState.mulligan or not KARDS.BattleState.mulligan.active or KARDS.BattleState.mulligan.submitted then return end
    if not KARDS.BattleState.inTable then return end
    KARDS.BattleState.mulligan.submitted = true
    KARDS.PlayKardsSound("click_button") -- 确认按钮点击音效（点击按钮）
    local ents = {}
    for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
        if card.selected and IsValid(ce) then ents[#ents + 1] = ce end
    end
    net.Start("KardsMulliganSubmit")
        net.WriteEntity(KARDS.BattleState.inTable.ent)
        net.WriteUInt(#ents, 8)
        for _, e in ipairs(ents) do net.WriteEntity(e) end
    net.SendToServer()
    -- 确认提交后仍在牌桌内：鼠标保持呼出（2026-08-10；等待服务端广播落位动画）
    UpdateTableMouse()
    KARDS.BattleState.prevMulliganLeft = false
end

hook.Add("Think", "KardsMulliganSelect", function()
    local active = KARDS.BattleState.mulligan and KARDS.BattleState.mulligan.active and not KARDS.BattleState.mulligan.submitted
    -- 牌桌内鼠标恒呼出（2026-08-10：KARDS.BattleState.mulligan 结束/确认后仍在牌桌内，不再关闭；
    -- 开关由 UpdateTableMouse 按 KARDS.BattleState.inTable 统一决定，仅离开牌桌才关闭；内部记录
    -- 上次状态，active 期间每帧调用也无重复切换）
    UpdateTableMouse()
    if not active then
        KARDS.BattleState.prevMulliganLeft = false
        return
    end
    -- 选择卡定格落位（发牌动画结束后；选中卡沿法线上抬）。
    -- 取消每帧强制正面/朝向（2026-08-10 反馈：改为抽牌动画同款翻面落位，角度由
    -- 发牌动画定格为扇面姿态 Angle(0, endYaw, 0)，此处仅保位置）。
    for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
        if IsValid(ce) and not KARDS.AnimPlayer:Active(ce, "mulliganDeal") then
            local pos = MulliganFanPos(card.index, KARDS.BattleState.mulligan.total)
            local lift = card.selected and 1.5 or 0
            local cur = ce:GetLocalPos()
            if cur.z ~= pos.z + lift or cur.x ~= pos.x or cur.y ~= pos.y then
                ce:SetLocalPos(Vector(pos.x, pos.y, pos.z + lift))
            end
        end
    end
    -- 左键上升沿：确认按钮优先，其次点击牌桌中间扇形卡
    local left = input.IsMouseDown(MOUSE_LEFT)
    if left and not KARDS.BattleState.prevMulliganLeft then
        local mX, mY = gui.MouseX(), gui.MouseY()
        local r = KARDS.BattleState.mulliganConfirmRect
        if r and mX >= r.x and mX <= r.x + r.w and mY >= r.y and mY <= r.y + r.h then
            SubmitMulligan()
        else
            local hit = HitMulliganCard(mX, mY)
            if hit and KARDS.BattleState.mulligan.cards[hit] then
                KARDS.BattleState.mulligan.cards[hit].selected = not KARDS.BattleState.mulligan.cards[hit].selected
                KARDS.PlayKardsSound("select_card") -- 选中/取消选择音效（选择卡牌）
            end
        end
    end
    KARDS.BattleState.prevMulliganLeft = left
end)

-- 文字提示渐变背景材质（materials/kards/ui/textUnderground.png，2026-08-11）：
-- 横向线性对称渐变——中心 70% 黑 → 两侧 0% 透明黑，作为重新调度提示文字横幅背景
-- （放大提示文字「选择要替换的卡牌」）；亦供「友方回合开始」提示横幅使用（线性渐变拉伸无损）
local textUndergroundMat = Material("materials/kards/ui/textUnderground.png", "noclamp smooth")

-- 重新调度 HUD（仅本方选择阶段）：选中卡图标（3D2D）+ 提示 + 准星下方「确认」按钮
hook.Add("HUDPaint", "KardsMulliganHUD", function()
    if not KARDS.BattleState.mulligan or not KARDS.BattleState.mulligan.active or KARDS.BattleState.mulligan.submitted then return end
    -- 被选中的卡：在卡面上方（局部 z+0.1，跟随上抬）绘制选中图标。
    -- 3D2D 平面法线朝上（pitch 90）俯视可见，图标尺寸 1.4 世界单位（卡宽 7.2）
    for ce, card in pairs(KARDS.BattleState.mulligan.cards) do
        if card.selected and IsValid(ce) then
            local ang = ce:GetAngles()
            cam.Start3D2D(ce:GetPos() + ce:GetUp() * 0.1, Angle(90, ang.y, 0), 1)
                surface.SetMaterial(chooseMat)
                surface.SetDrawColor(255, 255, 255, 255)
                surface.DrawTexturedRect(-0.7, -0.7, 1.4, 1.4)
            cam.End3D2D()
        end
    end
    -- 按钮：屏幕底部居中（2026-08-11 由准星下方移至底部——牌桌中间扇形卡投影在
    -- 屏幕中心，提示与按钮不遮挡卡面/牌桌视野；距底边 90px）
    local x, y = ScrW() / 2, ScrH() - 90
    local w, h = 160, 52
    KARDS.BattleState.mulliganConfirmRect = { x = x - w / 2, y = y - h / 2, w = w, h = h }
    -- 提示横幅（textUnderground.png 横向渐变背景，2026-08-11）：包裹放大提示文字，
    -- 置于按钮上方 8px
    local tipText = "选择要替换的卡牌"
    local tipFont = "SourceHan_Heavy_36"
    surface.SetFont(tipFont)
    local tw, th = surface.GetTextSize(tipText)
    local tipPadX, tipPadY = 28, 12 -- 渐变横幅内边距
    local tipW, tipH = tw + tipPadX * 2, th + tipPadY * 2
    local tipY = y - h / 2 - 8 - tipH -- 按钮顶 - 8px
    surface.SetMaterial(textUndergroundMat)
    surface.SetDrawColor(255, 255, 255, 255)
    surface.DrawTexturedRect(ScrW() / 2 - tipW / 2, tipY, tipW, tipH)
    draw.SimpleText(tipText, tipFont, ScrW() / 2, tipY + tipH / 2,
        Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 确认按钮背景：#BDBCAF 浅灰米色非软边矩形（直角，替代渐变背景，2026-08-11；
    -- 浅底配深色文字保持可读）；按住（左键悬停按下）时背景 #333229 / 文字 #C78736
    local held = input.IsMouseDown(MOUSE_LEFT)
        and gui.MouseX() >= KARDS.BattleState.mulliganConfirmRect.x and gui.MouseX() <= KARDS.BattleState.mulliganConfirmRect.x + w
        and gui.MouseY() >= KARDS.BattleState.mulliganConfirmRect.y and gui.MouseY() <= KARDS.BattleState.mulliganConfirmRect.y + h
    surface.SetDrawColor(held and Color(51, 50, 41) or Color(189, 188, 175))
    surface.DrawRect(KARDS.BattleState.mulliganConfirmRect.x, KARDS.BattleState.mulliganConfirmRect.y, w, h)
    draw.SimpleText("确认", "SourceHan_Heavy_32", x, y,
        held and Color(199, 135, 54) or Color(16, 16, 16), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

-- ====================================================================
-- 结束回合按钮交互 / 绘制（2026-08-11 拆分 B1：KardsEndTurnThink /
-- KardsEndTurnHUD 已迁移至 cl_battle_hud.lua）
-- ====================================================================

-- 手牌悬停提升状态（weak keys）：{ hovered, cur }，cur 为 0..1 的提升进度。
-- 供 KardsRealHandFacing（真实手牌）与 KardsHandSlotFacing（占位槽卡）两个驱动
-- 共用；声明置于两个钩子之前——Lua 词法作用域：钩子函数体引用的名字必须在其
-- 定义处可见，声明在后会被当作全局变量（nil）访问而报错（2026-08-10 实测）。
local handHoverCards = setmetatable({}, { __mode = "k" })

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
hook.Add("Think", "KardsRealHandFacing", function()
    -- 悬停检测（仅 P1/P2 视角 + 本方真实手牌）：相机射线到各手牌中心的最近距离判定
    --（同卡堆悬停 KardsDeckHoverDetect 的 KARDS.RayPointDistSqr 方法）；观战/未进入牌桌不悬停
    local view = KARDS.Perspective and KARDS.Perspective.LocalView
    local hoveredEnt = nil
    if view == 1 or view == 2 then
        local ply = LocalPlayer()
        if IsValid(ply) and not gui.IsConsoleVisible() and not gui.IsGameUIVisible() then
            local pos = KARDS.BattleCamera.ViewPos or ply:EyePos()
            local dir = gui.ScreenToVector(gui.MouseX(), gui.MouseY())
            if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then
                dir = (KARDS.BattleCamera.ViewAng or ply:EyeAngles()):Forward()
            end
            -- 悬停判定（2026-08-11 改）：射线命中手牌卡面矩形才算悬停（替代原
            -- 「到中心 3D 距离 <12」——过宽，鼠标指向靠近手牌的战场单位时误触手牌）；
            -- 重叠扇形卡取最近中心距离
            local bestD, hoveredEnt = math.huge, nil
            for ent in pairs(KARDS.BattleState.realHandCards[view]) do
                -- 拖拽中 / 待打出确认 / 返回手牌动画 / 重排动画中的卡跳过（位置/角度由拖拽钩子或飞行/返回动画接管）
                if IsValid(ent) and ent ~= KARDS.BattleState.pendingPlayEnt
                    and not KARDS.AnimPlayer:Active(ent, "mulliganToHand", "deckDraw", "dragReturn", "handRepos")
                    and not (KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == ent) then
                    if KARDS.RayCardHit(pos, dir, ent, KARDS.HandHitHalfW, KARDS.HandHitHalfL) then
                        local d = KARDS.RayPointDistSqr(pos, dir, ent:GetPos())
                        if d < bestD then
                            bestD, hoveredEnt = d, ent
                        end
                    end
                end
            end
        end
    end
    for slot = 1, 2 do
        local mine = KARDS.BattleState.inTable and KARDS.BattleState.inTable.slot == slot
        local n = 0
        for ent in pairs(KARDS.BattleState.realHandCards[slot]) do
            if IsValid(ent) then n = n + 1 end
        end
        for ent, idx in pairs(KARDS.BattleState.realHandCards[slot]) do
            -- 拖拽中 / 待打出确认 / 重排动画中的卡跳过（位置/角度由拖拽钩子或飞行/返回动画接管）
            if IsValid(ent) and ent ~= KARDS.BattleState.pendingPlayEnt
                and not KARDS.AnimPlayer:Active(ent, "mulliganToHand", "deckDraw", "dragReturn", "handRepos")
                and not (KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == ent) then
                if ent:GetNoDraw() then ent:SetNoDraw(false) end
                -- 悬停提升（仅本方手牌会命中 hoveredEnt；与 KardsHandSlotFacing 占位卡
                -- 同款：新悬停记录实际位置为基线，提升中冻结基线避免逐帧叠加）
                local st = handHoverCards[ent]
                if st then
                    st.hovered = (ent == hoveredEnt)
                    local target = st.hovered and 1 or 0
                    if st.cur < target then
                        st.cur = math.min(st.cur + FrameTime() / HandSlotHoverDur, 1)
                    elseif st.cur > target then
                        st.cur = math.max(st.cur - FrameTime() / HandSlotHoverDur, 0)
                    end
                    if st.cur > 0 then
                        -- 自身 y+ 轴方向（LocalToWorld 换算，随当前朝向变化，扇形各卡
                        -- 方向略异）→ 父局部方向（SetLocalPos 使用父局部坐标；GMod 无
                        -- WorldToLocalVector，用两次 WorldToLocal 点变换求差）
                        local yp = ent:LocalToWorld(Vector(0, 1, 0)) - ent:GetPos()
                        local parent = ent:GetParent()
                        if IsValid(parent) then
                            yp = parent:WorldToLocal(ent:LocalToWorld(Vector(0, 1, 0)))
                                - parent:WorldToLocal(ent:GetPos())
                        end
                        -- 沿自身 y+ 轴方向移动（yp 为局部 +y；2026-08-10 反向后沿 +y 提升）
                        ent:SetLocalPos(st.base + yp * (st.cur * HandSlotHoverLift))
                    else
                        handHoverCards[ent] = nil -- 已回落，交还常规位置（动画定格值）
                    end
                elseif ent == hoveredEnt then
                    -- 新悬停：记录当前实际位置为基线（动画已结束，位置稳定）
                    handHoverCards[ent] = { hovered = true, cur = 0, base = ent:GetLocalPos() }
                end
                if mine then
                    -- 与动画定格同一预设扇形角度（n=当前手牌数；动画全部结束后
                    -- n 与登记时 total 一致，角度不跳变）
                    local _, ang = HandFanPos(slot, idx, n)
                    local cur = ent:GetLocalAngles()
                    if math.abs(cur.p - ang.p) > 0.01 or math.abs(cur.y - ang.y) > 0.01
                        or math.abs(cur.r - ang.r) > 0.01 then
                        ent:SetLocalAngles(ang)
                    end
                end
            end
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
--   hqReveals(L1973) / InHQRevealAnim(L2718) / KARDS.RayPointDistSqr(L1187) /
--   DeckFindCardInfo(L1516) / KARDS.CardTextOverlay。
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
    if KARDS.AnimPlayer:Active(src, "dragFlight", "dragReturn", "handRepos", "mulliganToHand", "deckDraw") then return false end
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
    -- 无碰撞无物理（同原卡）
    copy:SetSolid(SOLID_NONE)
    local phys = copy:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    local appearance, _, textureSize = DeckFindCardInfo(src:GetNWString("Kards_CardName", ""))
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

-- 每帧：悬停射线检测（同卡堆悬停 KARDS.RayPointDistSqr 方法）+ 复制卡生命周期管理
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
    local pos = KARDS.BattleCamera.ViewPos or ply:EyePos()
    local dir = gui.ScreenToVector(gui.MouseX(), gui.MouseY())
    if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then
        dir = (KARDS.BattleCamera.ViewAng or ply:EyeAngles()):Forward()
    end
    local view = KARDS.Perspective and KARDS.Perspective.LocalView
    -- 扫描候选（取最近距离）：本方手牌（仅 P1/P2 视角）+ 双方战场卡（含总部）
    local bestD, bestEnt, bestHand, bestSlot = math.huge, nil, false, nil
    local function Consider(ent, radius, isHand, slot)
        if not HoverPreviewCardCanShow(ent) then return end
        local d = KARDS.RayPointDistSqr(pos, dir, ent:GetPos())
        local r2 = radius * radius
        if d < r2 and d < bestD then
            bestD, bestEnt, bestHand, bestSlot = d, ent, isHand, slot
        end
    end
    if view == 1 or view == 2 then
        for ent in pairs(KARDS.BattleState.realHandCards[view]) do
            -- 手牌候选：射线命中卡面矩形才参与（2026-08-11 改，替代中心距离 12——
            -- 过宽会抢走靠近手牌的战场单位预览）；radius 传 math.huge 仅让距离竞争
            if IsValid(ent) and KARDS.RayCardHit(pos, dir, ent, KARDS.HandHitHalfW, KARDS.HandHitHalfL) then
                Consider(ent, math.huge, true, view)
            end
        end
    end
    for slot = 1, 2 do
        for ent in pairs(KARDS.BattleState.fieldLayouts[slot] or {}) do
            if IsValid(ent) then Consider(ent, HoverFieldHoverRadius, false, slot) end
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
            local yp = src:LocalToWorld(Vector(0, 1, 0)) - src:GetPos()
            if IsValid(parent) then
                yp = parent:WorldToLocal(src:LocalToWorld(Vector(0, 1, 0)))
                    - parent:WorldToLocal(src:GetPos())
            end
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
-- 手牌拿起 / 拖拽 / 打出（2026-08-10）：
--   悬停在本方手牌时按下左键 → 拿起（z 抬升至手牌扇形 z 理论最大值上方 0.1、xy 原点始终跟随
--   鼠标、悬停机制失效、播放「拿起卡牌」音效）；握着的牌是单位且鼠标位于本方
--   支援阵线、在支援阵线整体卡牌的一侧 → 该玩家视角下支援阵线所有卡（含总部）
--   往另一侧移动（腾位预览）；松手在手牌区域 → 渐变回原位；否则为打出（单位 →
--   KardsPlayCard 固定槽位部署 SimDeployFixed；指令 → 战斗系统 SimPlayCard）。
--   从打出开始由服务端战斗系统权威处理（反应、时间刻记录）。
-- ====================================================================
hook.Add("Think", "KardsDragCardThink", function()
    local now = CurTime()
    local ply = LocalPlayer()
    local view = KARDS.Perspective and KARDS.Perspective.LocalView
    local inBattle = KARDS.BattleState.battleStarted and KARDS.BattleState.inTable and IsValid(KARDS.BattleState.inTable.ent)
    local guiBlocked = gui.IsConsoleVisible() or gui.IsGameUIVisible()
    local left = input.IsMouseDown(MOUSE_LEFT)

    -- 相机视线与牌桌局部 z 平面交点 → 牌桌局部坐标（拖拽 xy 跟随鼠标的投影基准；
    -- 与 StartHQReveal 的屏幕 → 桌面平面投影同法）
    local function MouseLocalZ(z)
        local pos = (KARDS.BattleCamera and KARDS.BattleCamera.ViewPos) or ply:EyePos()
        local dir = gui.ScreenToVector(gui.MouseX(), gui.MouseY())
        if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then
            dir = (KARDS.BattleCamera and KARDS.BattleCamera.ViewAng or ply:EyeAngles()):Forward()
        end
        if not inBattle or math.abs(dir.z) < 0.001 then return nil end
        local planeZ = KARDS.BattleState.inTable.ent:LocalToWorld(Vector(0, 0, z)).z
        local world = pos + dir * ((planeZ - pos.z) / dir.z)
        return KARDS.BattleState.inTable.ent:WorldToLocal(world)
    end

    -- 某槽当前手牌张数（真实手牌，含拖拽中/动画中）
    local function HandCount(slot)
        local n = 0
        for e in pairs(KARDS.BattleState.realHandCards[slot]) do
            if IsValid(e) then n = n + 1 end
        end
        return n
    end

    -- 最近列 index（鼠标投影 x → 支援阵线槽位列 1..5）
    local function NearestCol(x)
        local best, bd = 1, math.huge
        for i = 1, 5 do
            local d = math.abs(KARDS.Animation.Board2D.ColX[i] - x)
            if d < bd then bd, best = d, i end
        end
        return best
    end

    -- 位置动画（返回手牌 / 打出飞行 / 战场复位）与手牌重排动画（位置+角度双插值）
    -- 由 KARDS.AnimPlayer 单一 Think 驱动（re.md 重构），本钩子不再逐帧驱动

    -- 拿起（左键上升沿 + 我方回合 + 视角本方 + 无 GUI + 无进行中的拖拽/待确认）
    if not guiBlocked and inBattle and KARDS.BattleState.battleTurn == KARDS.BattleState.inTable.slot
        and (view == 1 or view == 2) and not KARDS.BattleState.dragCard and not KARDS.BattleState.pendingPlayEnt
        and not KARDS.BattleState.endedTurn and left and not KARDS.BattleState.prevDragLeft then
        local pos = (KARDS.BattleCamera and KARDS.BattleCamera.ViewPos) or ply:EyePos()
        local dir = gui.ScreenToVector(gui.MouseX(), gui.MouseY())
        if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then
            dir = (KARDS.BattleCamera and KARDS.BattleCamera.ViewAng or ply:EyeAngles()):Forward()
        end
        -- 拿起判定（2026-08-11 改）：射线命中手牌卡面矩形才算点到手牌（替代原
        -- 「到中心 3D 距离 <12」——过宽，鼠标指向靠近手牌的战场单位时被误判为
        -- 拿起手牌）；重叠扇形卡取最近中心距离
        local bestD, hit = math.huge, nil
        for ent in pairs(KARDS.BattleState.realHandCards[view]) do
            if IsValid(ent) and not KARDS.AnimPlayer:Active(ent, "mulliganToHand", "deckDraw", "handRepos") then
                if KARDS.RayCardHit(pos, dir, ent, KARDS.HandHitHalfW, KARDS.HandHitHalfL) then
                    local d = KARDS.RayPointDistSqr(pos, dir, ent:GetPos())
                    if d < bestD then bestD, hit = d, ent end
                end
            end
        end
        if hit then
            KARDS.BattleState.dragCard = {
                ent = hit,
                slot = view,
                idx = KARDS.BattleState.realHandCards[view][hit],
                zFrom = hit:GetLocalPos().z,
                start = now,
            }
            handHoverCards[hit] = nil -- 悬停机制失效（位置/角度由本钩子接管）
            KARDS.PlayKardsSound("pickup")
        end
    end

    -- 拖拽（拿起后每帧）：z 抬升 + xy 跟随鼠标 + 保持扇形角度 + 腾位预览
    if KARDS.BattleState.dragCard and IsValid(KARDS.BattleState.dragCard.ent) and inBattle then
        local ent = KARDS.BattleState.dragCard.ent
        local t = math.min((now - KARDS.BattleState.dragCard.start) / HandSlotLiftDur, 1)
        local lift = 0.5 - 0.5 * math.cos(math.pi * t)
        -- 拖拽抬升 z：手牌扇形 z 理论最大值（阶梯最高层，编号大的一侧）+ 0.1——
        -- 仅略高于手牌层（原固定 40 落差过大，2026-08-10 反馈）
        local dragZ = HandSlotBase.z + ((HandCount(KARDS.BattleState.dragCard.slot) - 1) / 2) * HandSlotZStep + 0.1
        local targetZ = KARDS.BattleState.dragCard.zFrom + (dragZ - KARDS.BattleState.dragCard.zFrom) * lift
        -- 水平位置用桌面投影（CardZ）：与松手落位（NearestCol 同样投影到 CardZ）一致，
        -- 所见即所得——否则相机在宽边外斜视时，抬升高度（targetZ≈30.5）与桌面
        --（CardZ=18.43）的投影横向偏差可达 1 列以上，单位会落到与视觉位置隔一空槽
        --（2026-08-10 修复）；z 仍独立抬升（视觉浮起）
        local lp = MouseLocalZ(KARDS.Animation.Board2D.CardZ)
        local cp = ent:GetLocalPos()
        ent:SetLocalPos(lp and Vector(lp.x, lp.y, targetZ) or Vector(cp.x, cp.y, targetZ))
        -- 角度：被握住时不再遵循扇形分布（不在手牌中），平躺正面朝上（xy 位置由
        -- 鼠标投影接管；松手回手牌时 KardsRealHandFacing 恢复扇形姿态、打出后
        -- KardsFieldFacing 接管战场朝向）。yaw 取拿起前扇形基准 + 文字朝向偏移
        --（P1 位置基准 0 + 文字 180 → 180 / P2 基准 180 + 文字 180 → 0），保持文字
        -- 顶朝本方，避免从扇形角度（P1 ≈180±30）直接归 0 造成卡面 180° 翻转
        --（2026-08-11 用户反馈握住后 yaw 反了）
        local ang = Angle(0, (KARDS.BattleState.dragCard.slot == 1) and HandSlotTextYaw or 0, 0)
        local cur = ent:GetLocalAngles()
        if math.abs(cur.p - ang.p) > 0.01 or math.abs(cur.y - ang.y) > 0.01
            or math.abs(cur.r - ang.r) > 0.01 then
            ent:SetLocalAngles(ang)
        end
        -- 腾位预览：单位 + 鼠标在本方支援阵线行 → 预览整线居中后的结果
        --（PreviewFieldPositions：按落点列插入拖拽单位 + GetCenteredStart 整线居中 +
        -- 偶数整线 0.5 槽偏移，与服务端 SimDeploy 落位一致，所见即所得）
        local ctype = ent:GetNWString("Kards_CardType", "")
        local isUnit = (ctype == "unit")
        local row = (KARDS.BattleState.dragCard.slot == 1) and 1 or -1
        local layout = KARDS.BattleState.fieldLayouts[KARDS.BattleState.dragCard.slot]
        local preview = nil
        if isUnit and lp and layout then
            if math.abs(lp.y - KARDS.Animation.Board2D.RowY[row]) <= SupportLineHover then
                preview = PreviewFieldPositions(layout, KARDS.BattleState.dragCard.ent, NearestCol(lp.x), row)
            end
        end
        for e, si in pairs(layout or {}) do
            if IsValid(e) and e ~= KARDS.BattleState.dragCard.ent and e ~= KARDS.BattleState.pendingPlayEnt and not InHQRevealAnim(e) then
                -- 预览目标优先；未参与预览（待确认/总部动画中）回布局数据槽位
                local to = (preview and preview[e]) or FieldPos(layout, e, si, row)
                local existing = KARDS.AnimPlayer:Get(e)
                -- 目标变化或动画缺失时重建（避免每帧重建/中断抖动）
                if not existing or not existing.toPos
                    or (existing.toPos - to):LengthSqr() > 0.01 then
                    KARDS.AnimPlayer:Play(e, {
                        { t = 0 },
                        { t = HandSlotReposDur, pos = to, easing = "cos" },
                    }, { group = "fieldRepos" })
                end
            end
        end
    end

    -- 松手（左键下降沿 + 有拖拽中的卡）
    if KARDS.BattleState.dragCard and IsValid(KARDS.BattleState.dragCard.ent) and not left and KARDS.BattleState.prevDragLeft then
        local ent = KARDS.BattleState.dragCard.ent
        -- 腾位预览复位：松手后战场卡回布局原位（无论回手牌 / 打出；打出成功时
        -- 服务端 KardsFieldLayout 会按新布局再次复位，与本处目标一致不冲突；
        -- 回手牌 / 打出被拒时保证战场卡归位）
        local row = (KARDS.BattleState.dragCard.slot == 1) and 1 or -1
        for e, si in pairs(KARDS.BattleState.fieldLayouts[KARDS.BattleState.dragCard.slot] or {}) do
            if IsValid(e) and e ~= ent and not InHQRevealAnim(e) then
                local to = FieldPos(KARDS.BattleState.fieldLayouts[KARDS.BattleState.dragCard.slot], e, si, row)
                local existing = KARDS.AnimPlayer:Get(e)
                if not existing or not existing.toPos
                    or (existing.toPos - to):LengthSqr() > 0.01 then
                    KARDS.AnimPlayer:Play(e, {
                        { t = 0 },
                        { t = HandSlotReposDur, pos = to, easing = "cos" },
                    }, { group = "fieldRepos" })
                end
            end
        end
        -- 手牌区域判定：投影与当前本方手牌扇形各卡位置的水平距离
        local lp = MouseLocalZ(HandSlotBase.z)
        local inHand = false
        if lp then
            local n = HandCount(KARDS.BattleState.dragCard.slot)
            local best = math.huge
            for i = 1, n do
                local p = HandFanPos(KARDS.BattleState.dragCard.slot, i, n)
                local d = Vector(p.x - lp.x, p.y - lp.y, 0):LengthSqr()
                if d < best then best = d end
            end
            inHand = best <= HandRegionDist * HandRegionDist
        end
        if inHand then
            -- 渐变回到原位（扇形位；z 一并回落）
            local handPos = HandFanPos(KARDS.BattleState.dragCard.slot, KARDS.BattleState.dragCard.idx, HandCount(KARDS.BattleState.dragCard.slot))
            KARDS.AnimPlayer:Play(ent, {
                { t = 0 },
                { t = HandSlotReturnDur, pos = handPos, easing = "cos" },
            }, { group = "dragReturn" })
            KARDS.BattleState.dragCard = nil
        else
            -- 打出：单位 → 目标槽位 = 鼠标投影最近列（与服务端 SimDeploy 受限选位
            -- InsertCentered 排秩同源，与拖拽预览 PreviewFieldPositions 的落点列一致 →
            -- 所见即所得）；指令 → 0
            local ctype = ent:GetNWString("Kards_CardType", "")
            local isUnit = (ctype == "unit")
            local slotIndex = 0
            if isUnit then
                local lp2 = MouseLocalZ(KARDS.Animation.Board2D.CardZ)
                if lp2 then
                    -- 不再「被占则往鼠标侧找空槽」：服务端 InsertCentered 对占用列的
                    -- 语义为「插入到该卡左侧 + 整线居中」（与预览 PreviewFieldPositions
                    -- 相同）——悬停两卡之间（最近列被占）时改找空槽会把部署目标换到
                    -- 别的列，与预览让位不符、落不到预览空位（2026-08-11 反馈）
                    slotIndex = NearestCol(lp2.x)
                end
            end
            KARDS.BattleState.pendingPlayEnt = ent -- 冻结位置，等待服务端确认（防重复打出）
            net.Start("KardsPlayCard")
                net.WriteEntity(KARDS.BattleState.inTable.ent)
                net.WriteEntity(ent)
                net.WriteUInt(slotIndex, 8)
            net.SendToServer()
            KARDS.BattleState.dragCard = nil
        end
    end

    KARDS.BattleState.prevDragLeft = left
end)

-- 打出确认（服务端 OnPlayCard 广播）：本方收尾拖拽动画、对方/观战同步战场卡。
-- 单位（landed>0）：登记战场布局 + 打出手牌 → 目标格飞行（角度交由 KardsFieldFacing
-- 接管）；指令（landed=0）：服务端已开始淡出移除（子物体系统），客户端仅从手牌登记移除。
net.Receive("KardsCardPlayed", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local cardEnt = net.ReadEntity()
    local landed = net.ReadUInt(8)
    local unitEnt = net.ReadEntity() -- 单位>0：服务端 unit 战场实体；指令：NULL
    if not IsValid(ent) or not IsValid(cardEnt) then return end
    if KARDS.BattleState.pendingPlayEnt == cardEnt then KARDS.BattleState.pendingPlayEnt = nil end
    KARDS.BattleState.realHandCards[slot][cardEnt] = nil -- 已离手（本/对方/观战均移除手牌登记）
    handHoverCards[cardEnt] = nil
    -- 剩余手牌索引重排（连续 1..n）+ 平滑过渡到新扇形位：手牌数量变化后扇形
    -- 按新张数收缩分布（2026-08-11 用户反馈打出后扇形仍按原数量分布）
    RenumberHand(slot)
    if landed > 0 then
        -- 单位：登记战场槽位 + 两阶段飞行动画（2026-08-11 basic_card_unit 切换）
        -- 阶段 1（0→HandSlotFlightDur/2）：原手牌实体（服务端保留作动画载体）飞半程
        -- 阶段 2（半程→终点）：服务端 unit 战场实体从中点继续飞剩余半程
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
        -- 阶段 1：原实体飞半程
        KARDS.AnimPlayer:Play(cardEnt, {
            { t = 0 },
            { t = halfDur, pos = targetPos, easing = "cos" },
        }, { group = "dragFlight" })

        if IsValid(unitEnt) then
            -- 阶段 2：unit 战场实体从中点飞剩余半程（服务端实体，客户端 AnimPlayer
            -- 驱动位置，与手牌实体同款；渲染由服务端 ApplyImportedModel 链路保证）
            timer.Simple(halfDur, function()
                if not IsValid(unitEnt) then
                    -- 回退：unit 实体已失效，原实体飞完剩余半程（保留显示与文字）
                    print("[Kards] unit 战场实体已失效，回退原实体飞完剩余半程")
                    if IsValid(cardEnt) then
                        KARDS.AnimPlayer:Play(cardEnt, {
                            { t = 0 },
                            { t = halfDur, pos = targetPos, easing = "cos" },
                        }, { group = "dragFlight" })
                    end
                    return
                end
                local midPos = cardEnt:GetPos()
                local midAng = cardEnt:GetAngles()
                unitEnt:SetPos(midPos)
                unitEnt:SetAngles(midAng)

                -- 3D2D 文字：单位模式（仅攻击/防御/行动花费，行动花费替代卡牌花费位置）
                if KARDS.CardTextOverlay then
                    KARDS.CardTextOverlay:AddLocal(unitEnt, {
                        cost = 0,
                        actionCost = unitEnt:GetNWInt("Kards_CardActionCost", 0),
                        attack = unitEnt:GetNWInt("Kards_CardAttack", 0),
                        defense = unitEnt:GetNWInt("Kards_CardDefense", 0),
                        _unitMode = true, -- DrawOverlay 据此跳过 cost/keywords/desc
                    }, 7.2, 8.528, 209, 290)
                end

                -- 本地隐藏原手牌实体（模型+文字），仅本客户端生效（对方/观战各自
                -- 在本地 KardsCardPlayed 中执行同样切换，视角一致）
                cardEnt:SetNoDraw(true)
                if KARDS.CardTextOverlay then KARDS.CardTextOverlay:Remove(cardEnt) end

                -- 阶段 2 动画：unit 实体飞剩余半程
                KARDS.AnimPlayer:Play(unitEnt, {
                    { t = 0 },
                    { t = halfDur, pos = targetPos, easing = "cos" },
                }, { group = "dragFlight" })
            end)
        else
            -- 无 unit 实体（指令卡或 unit 创建失败回退）：原实体直接飞全程
            KARDS.AnimPlayer:Play(cardEnt, {
                { t = 0 },
                { t = HandSlotFlightDur, pos = targetPos, easing = "cos" },
            }, { group = "dragFlight" })
        end
    end
    -- 指令：无额外动画（服务端淡出移除），KARDS.BattleState.realHandCards 已移除
end)

-- 支援阵线布局广播（服务端单位打出成功后）：重建 KARDS.BattleState.fieldLayouts[slot] 并按槽位复位各卡
--（固定部署不重排，其余卡槽位/坐标保持腾位后状态；飞行/拖拽/总部动画中的卡跳过复位）
net.Receive("KardsFieldLayout", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    if not IsValid(ent) then return end
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
        KARDS.BattleState.frontlineLayout = layout
        KARDS.BattleState.frontlineOwnerSlot = ownerSlot
        local row = 0 -- 前线行
        for e, idx in pairs(layout) do
            if IsValid(e) and e ~= KARDS.BattleState.pendingPlayEnt
                and not KARDS.AnimPlayer:Active(e, "dragFlight")
                and not (KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == e) and not InHQRevealAnim(e) then
                local to = FieldPos(layout, e, idx, row)
                local existing = KARDS.AnimPlayer:Get(e)
                if not existing or not existing.toPos
                    or (existing.toPos - to):LengthSqr() > 0.01 then
                    KARDS.AnimPlayer:Play(e, {
                        { t = 0 },
                        { t = HandSlotReposDur, pos = to, easing = "cos" },
                    }, { group = "fieldRepos" })
                end
            end
        end
        return
    end
    local n = net.ReadUInt(8)
    local layout = {}
    for _ = 1, n do
        local idx = net.ReadUInt(8)
        local e = net.ReadEntity()
        if IsValid(e) then layout[e] = idx end
    end
    KARDS.BattleState.fieldLayouts[slot] = layout
    local row = (slot == 1) and 1 or -1
    for e, idx in pairs(layout) do
        if IsValid(e) and e ~= KARDS.BattleState.pendingPlayEnt
            and not KARDS.AnimPlayer:Active(e, "dragFlight")
            and not (KARDS.BattleState.dragCard and KARDS.BattleState.dragCard.ent == e) and not InHQRevealAnim(e) then
            local to = FieldPos(layout, e, idx, row)
            local existing = KARDS.AnimPlayer:Get(e)
            if not existing or not existing.toPos
                or (existing.toPos - to):LengthSqr() > 0.01 then
                KARDS.AnimPlayer:Play(e, {
                    { t = 0 },
                    { t = HandSlotReposDur, pos = to, easing = "cos" },
                }, { group = "fieldRepos" })
            end
        end
    end
end)

-- 打出被拒（服务端校验失败：非当前回合 / 指挥点不足 / 阵线已满等）：渐变退回手牌
net.Receive("KardsPlayCardRejected", function()
    local ent = net.ReadEntity()
    local slot = net.ReadUInt(8)
    local cardEnt = net.ReadEntity()
    if not IsValid(cardEnt) then return end
    if KARDS.BattleState.pendingPlayEnt == cardEnt then KARDS.BattleState.pendingPlayEnt = nil end
    local idx = KARDS.BattleState.realHandCards[slot][cardEnt]
    if idx then
        local n = 0
        for e in pairs(KARDS.BattleState.realHandCards[slot]) do
            if IsValid(e) then n = n + 1 end
        end
        local handPos = HandFanPos(slot, idx, n)
        KARDS.AnimPlayer:Play(cardEnt, {
            { t = 0 },
            { t = HandSlotReturnDur, pos = handPos, easing = "cos" },
        }, { group = "dragReturn" })
    end
end)

-- ====================================================================
-- 手牌卡牌花费文字颜色（2026-08-11 拆分 B1：KardsHandCostColorThink 钩子与颜色
-- 常量/目标色表已迁移至 cl_battle_hud.lua）
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

hook.Add("Think", "KardsFieldFacing", function()
    if not KARDS.Perspective or not KARDS.Perspective.IsFieldCard then return end
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        -- 待打出确认的卡跳过（确认前冻结，避免 NW 先于 KardsCardPlayed 到达时被提前
        -- 驱动到战场朝向，与拖拽收尾动画冲突；确认后由飞行动画收尾、本驱动接管）
        if IsValid(ent) and KARDS.Perspective:IsFieldCard(ent) and ent ~= KARDS.BattleState.pendingPlayEnt then
            if ent:GetNWString("Kards_DeckRole", "") == "hq" then
                -- 总部：仅已离开卡组槽（battleHQLeft）且不在动画中时由本模块接管朝向
                if battleHQLeft[ent] and not InHQRevealAnim(ent) then
                    KARDS.Perspective:ApplyFacing(ent)
                end
            else
                KARDS.Perspective:ApplyFacing(ent)
            end
        end
    end
end)


-- ====================================================================
-- 手牌槽卡三视角朝向驱动（见 cl_perspective.lua ApplyHandFacing）：
--   P1/P2 视角（进入牌桌，LocalView=1/2）：本方手牌保持扇形姿态（正面朝上，
--   看到 front"正面"）/ 对方手牌绕卡长轴翻转 180°（背面朝上，看到 back 卡背）
--   ——各视角只看得到自己的牌面；
--   观战视角（LocalView=nil）：使用独立于 P1/P2 视角的扇形分布计算方法（最早
--   方法：135° 倾斜基准 + ψ 绕面法线、ψ 取负，保持最早"手拿手牌"观感），角度
--   由服务端独立计算写入 Kards_LegacyFanAng NW，再绕卡长轴翻转 180° 使正面
--   （front）朝上（观战看到的是卡正面空白占位，而非背面纹理）。
-- 扇形基准角度来自服务端 Kards_HandBaseAng NW（CreateHandCardSlots 写入），
-- 归属槽位来自 Kards_DeckSlot NW（SpawnHandSlotCard 写入）。
-- 抽牌动画的临时卡（battleDeckDrawn）非手牌槽卡（无 Kards_IsHandSlotCard），
-- 不在此驱动，角度由抽牌动画自行控制；手牌槽左移动画（deckDrawShift）只改
-- 位置 x、不动角度与 z，与本驱动无冲突。
-- 悬停提升（仅 P1/P2 视角、本方手牌）：鼠标悬停某张本方手牌时，该卡沿自身
-- y+ 轴（实体局部 +y，随当前朝向变化）在 HandSlotHoverDur 秒内移动
-- HandSlotHoverLift 到满量，离开同样时长回落（见本钩子手牌悬停检测）。
-- ====================================================================

hook.Add("Think", "KardsHandSlotFacing", function()
    if not KARDS.Perspective or not KARDS.Perspective.IsHandSlotCard then return end
    -- 手牌 z 视角修正：P1/P2 视角（LocalView=1/2）用服务端基础 z（Kards_HandSlotBasePos）；
    -- 观察者视角（LocalView=nil，含未进入牌桌 / 未开始对战）还原到更低基线
    --（基础 z − HandSlotZViewOffset），不跟随 P1/P2 的 z 抬升。只改 z、保留 x/y
    --（不干扰抽牌左移动画）。
    local zOff = (KARDS.Perspective.LocalView == 1 or KARDS.Perspective.LocalView == 2)
        and 0 or -HandSlotZViewOffset
    -- 悬停检测（仅 P1/P2 视角 + 本方手牌）：相机射线到各手牌中心的最近距离判定
    --（同卡堆悬停 KardsDeckHoverDetect 的 KARDS.RayPointDistSqr 方法）
    local view = KARDS.Perspective.LocalView
    local hoveredEnt = nil
    if view == 1 or view == 2 then
        local ply = LocalPlayer()
        if IsValid(ply) and not gui.IsConsoleVisible() and not gui.IsGameUIVisible() then
            local pos = KARDS.BattleCamera.ViewPos or ply:EyePos()
            local dir = gui.ScreenToVector(gui.MouseX(), gui.MouseY())
            if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then
                dir = (KARDS.BattleCamera.ViewAng or ply:EyeAngles()):Forward()
            end
            local bestD = HandSlotHoverRadius * HandSlotHoverRadius
            for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
                if KARDS.Perspective:IsHandSlotCard(ent)
                    and ent:GetNWInt("Kards_DeckSlot", 0) == view then
                    local d = KARDS.RayPointDistSqr(pos, dir, ent:GetPos())
                    if d < bestD then
                        bestD, hoveredEnt = d, ent
                    end
                end
            end
        end
    end
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if KARDS.Perspective:IsHandSlotCard(ent) then
            KARDS.Perspective:ApplyHandFacing(ent)
            local v = ent:GetNWVector("Kards_HandSlotBasePos")
            if v then
                local st = handHoverCards[ent]
                if st then
                    -- 悬停提升中（含回落）：位置 = 悬停起始基线 st.base（冻结，避免
                    -- 逐帧叠加造成无上限移动）+ 沿自身 y+ 轴提升量
                    st.hovered = (ent == hoveredEnt)
                    local target = st.hovered and 1 or 0
                    if st.cur < target then
                        st.cur = math.min(st.cur + FrameTime() / HandSlotHoverDur, 1)
                    elseif st.cur > target then
                        st.cur = math.max(st.cur - FrameTime() / HandSlotHoverDur, 0)
                    end
                    if st.cur > 0 then
                        -- 自身 y+ 轴方向（LocalToWorld 换算，随当前朝向变化，扇形各卡
                        -- 方向略异）→ 父局部方向（SetLocalPos 使用父局部坐标；GMod 无
                        -- WorldToLocalVector，用两次 WorldToLocal 点变换求差）
                        local yp = ent:LocalToWorld(Vector(0, 1, 0)) - ent:GetPos()
                        local parent = ent:GetParent()
                        if IsValid(parent) then
                            yp = parent:WorldToLocal(ent:LocalToWorld(Vector(0, 1, 0)))
                                - parent:WorldToLocal(ent:GetPos())
                        end
                        -- 沿自身 y+ 轴方向移动（yp 为局部 +y；2026-08-10 反向后沿 +y 提升）
                        ent:SetLocalPos(st.base + yp * (st.cur * HandSlotHoverLift))
                    else
                        handHoverCards[ent] = nil -- 已回落，交还常规位置修正
                    end
                elseif ent == hoveredEnt then
                    -- 新悬停：记录当前实际位置为基线（含视角 z 修正与抽牌左移）
                    handHoverCards[ent] = { hovered = true, cur = 0, base = ent:GetLocalPos() }
                else
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
end)

-- ====================================================================
-- 卡组悬停信息面板（2026-08-11 拆分 B1：状态 + KardsDeckHoverDetect 检测 +
-- KardsDeckHoverInfo 绘制已迁移至 cl_battle_hud.lua）
-- ====================================================================

-- ====================================================================
-- 指挥点 HUD 面板绘制（2026-08-11 拆分 B1：HUDPaint 钩子 KardsCommandPointsHUD 与
-- CPCycleBand 数字带已迁移至 cl_battle_command_points.lua）
-- ====================================================================
