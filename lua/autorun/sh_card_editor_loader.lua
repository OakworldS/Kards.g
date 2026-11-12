-- Kards 卡牌编辑器加载器
-- 共享文件，服务端和客户端都会执行

KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Version = "0.5.0-alpha"

-- ===== BGM 注册机制（全局 API，供外部音乐扩展模组注册新风格与曲目）=====
-- 外部模组在 autorun 中调用 KARDS.CardEditor.RegisterBGMCountry / RegisterBGMTrack：
-- 注册数据先写入注册表（KARDS.CardEditor.BGMRegistrations / TrackRegistrations），
-- 主模组 BGM 模块（compat）加载时统一消费；若 compat 已就绪则调用时实时应用。
-- 时序兜底：主模组在初始化完成后触发 hook "KARDS_CardEditorReady"，外部模组可 hook 它延迟注册。
KARDS.CardEditor.BGMRegistrations = {}
KARDS.CardEditor.TrackRegistrations = {}

-- 注册一个 BGM 风格（在编辑器更多音乐面板显示圆按钮）
-- countryId: string 风格唯一标识；data: { name = 显示名, shortName = 无图标时显示的简称(可选),
-- icon = 图标材质路径(64*64 png, 可选), color = 按钮背景色,
-- backgroundVolume = 播放该风格音乐时编辑器背景音效的音量倍率(可选, 1=原音量, 如 0.5 减半),
-- description = 国家简介文本(可选, 悬停扩展面板圆按钮时以打字机动画显示, 留空则不显示) }
function KARDS.CardEditor.RegisterBGMCountry(countryId, data)
    table.insert(KARDS.CardEditor.BGMRegistrations, { id = countryId, data = data })
    -- 主模组 compat 已就绪时实时应用
    local compat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
    if compat and compat.RegisterCountry then
        compat.RegisterCountry(countryId, data)
    end
end

-- 注册曲目：将音频文件归类到某个 BGM 风格
-- countryId: string 所属风格；trackPath: 音频相对 garrysmod/ 的路径（如 "sound/xxx/1.ogg"）；
-- trackName: 可选显示曲名（nil 则无曲名提示）
function KARDS.CardEditor.RegisterBGMTrack(countryId, trackPath, trackName)
    table.insert(KARDS.CardEditor.TrackRegistrations, { id = countryId, path = trackPath, name = trackName })
    local compat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
    if compat and compat.RegisterTrack then
        compat.RegisterTrack(countryId, trackPath, trackName)
    end
end

-- 日志函数
function KARDS.CardEditor:Log(message, level)
    print("[KARDS Editor] " .. (level or "INFO") .. ": " .. message)
end

-- 加载共享文件
local function LoadSharedFiles()
    KARDS.CardEditor:Log("Loading shared files...")

    -- 多语言基础设施（2026-10-17）：语言判定 + T() 查表 + 文本表。
    -- 置于加载链最前，保证后续任何模块（含核心数据结构）都能直接使用 KARDS.Lang.T()
    include("kards/sh_lang.lua")

    -- 牌桌消息收发契约（2026-11-08）：声明式字段表驱动收发，见
    -- docs/adr/0007-牌桌消息收发契约.md；紧跟 sh_lang 之后，Notify 依赖 KARDS.Lang.TFor
    include("kards/sh_table_sync.lua")

    -- 核心数据结构
    include("card_editor/sh_card_data.lua")

    -- 通用工具函数
    include("card_editor/sh_utils.lua")

    -- 核心共享代码
    include("card_editor/sh_core.lua")

    -- 输入路由共享引擎（2026-11-08，ADR 0004）：纯 Lua，不依赖 GMod API
    include("card_editor/sh_input_router.lua")

    -- 编辑器几何共享模块（2026-11-08，ADR 0006）：视图变换、端口矩形、曲线采样
    include("card_editor/sh_editor_geometry.lua")

    -- 动画系统共享代码
    include("card_editor/sh_animation.lua")

    -- 保存系统
    local saveOk, saveErr = pcall(function()
        include("card_editor/sh_save_system.lua")
    end)
    if not saveOk then
        KARDS.CardEditor:Log("Error loading sh_save_system.lua: " .. tostring(saveErr), "ERROR")
    end

    -- 版本历史与素材来源（关于页数据源，2026-10-05）
    include("card_editor/sh_version_history.lua")
    include("card_editor/sh_source_credits.lua")

    -- 贡献者名单（关于页贡献者卡数据源）
    include("card_editor/sh_contributors.lua")

    -- 全局变量库（战斗系统基础，需在其他战斗模块之前加载）
    include("kards/sh_varlib.lua")

    -- 规则词汇表（节点模板 {@section} 引用、自定义规则项持久化的数据源）
    include("kards/sh_rules_vocabulary.lua")

    -- 引擎钩子系统（海鹰/Hx 权杖号等持续效果/拦截方案的基础框架，供战斗系统插入钩子点）
    include("kards/sh_engine_hooks.lua")

    -- 注册式效果框架（统一 KeepTriggers/EventHooks/AlwaysHooks/PendingTurns 的注册表骨架，
    -- 供 sh_battle_stub.lua / sh_node_parser.lua 使用，re.md B-H2）
    include("kards/sh_effect_registry.lua")

    -- 时间刻系统数据层（战斗系统规划的时间刻记录载体，纯 Lua）
    include("kards/sh_ticklog.lua")

    -- 卡牌句柄接口约定 + Mock 实现（真实卡牌系统就绪后按接口替换，依赖倒置迁移）
    include("kards/sh_card_interface.lua")

    -- 卡牌规模音效（部署/攻击/放置在场音效按「单位类型 × 规模」分配与级联回退；
    -- 依赖 sh_card_interface.lua 的 UnitTypes，故紧随其后加载；re.md 阶段二 B4 拆分）
    include("kards/sh_card_sounds.lua")

    -- 战场布局数据层（支援阵线/前线/总部/作弊检测，战斗系统规划第 11 节，纯 Lua）
    include("kards/sh_battlefield.lua")

    -- 卡组数据层（构筑/洗牌/抽牌/士气伤害/重新调度，战斗系统规划第 12 节，纯 Lua）
    include("kards/sh_deck.lua")

    -- 指定（Specify）通用操作模块（指定手牌 / 指定目标两种选择操作，依赖卡组手牌，纯 Lua）
    include("kards/sh_specify.lua")

    -- 指挥点数据层（readme 7.1 指挥点(槽)/操作；卡牌花费/行动花费消耗指挥点，战斗系统规划第 14 节，纯 Lua）
    include("kards/sh_command_point.lua")

    -- 词条状态模块聚合（re.md B-M1：KeywordStates 按词条域分模块，状态字段 +
    -- 读写接口 + 联动规则集中定义，供战斗骨架/拆分模块使用；先于战斗系统加载）
    include("kards/sh_keyword_states.lua")

    -- 战斗系统骨架（模拟操作入口，验证时间刻与引擎钩子联动；入口即未来真实系统的接缝）
    include("kards/sh_battle_stub.lua")

    -- 战斗系统骨架拆分模块（re.md B-H1：按职责拆分，均挂 KARDS.Battle 命名空间，
    -- 在 stub 之后加载；unit/card/combat 相互引用均为运行时方法查找，顺序无强依赖）
    include("kards/sh_battle_unit.lua")
    include("kards/sh_battle_card.lua")
    include("kards/sh_battle_combat.lua")

    -- 反制管理器（反制系统 M2：手中保持激活的反制状态、隐藏花费、跨回合存续与
    -- 到点自动失活；依赖 EngineHooks / EffectRegistry / CommandPoints / Battle）
    include("kards/sh_counter.lua")

    -- 节点解析系统（将节点编辑器数据结构翻译为战斗系统操作；首个解析器：设置变量节点，
    -- 依赖 VarLib/TickLog/CardInterface，故置于战斗骨架之后）
    include("kards/sh_node_parser.lua")

    -- 节点解析系统拆分模块（re.md B-H3：按职责拆分，语义表先于执行器表/钩子/控制流加载；
    -- 均挂在 KARDS.NodeParser 命名空间，原文件入口 ExecuteBaseNode/ExecuteEffect 分派引用）
    include("kards/sh_node_semantics.lua")
    include("kards/sh_node_acts_field.lua")
    include("kards/sh_node_acts_choice.lua")
    include("kards/sh_node_acts_condition.lua")
    include("kards/sh_node_acts_register.lua")
    include("kards/sh_node_hooks.lua")
    include("kards/sh_effect_flow.lua")

    -- 联机防作弊与同步骨架（readme 四：服务端权威 / 实时同步校验 / 异常同步处理，纯 Lua）
    include("kards/sh_sync_stub.lua")

    -- 卡牌变换动画系统（预设 3D 位置 + 三个角度共 6 值；线性/平滑曲线插值，曲线可扩展，纯 Lua）
    include("kards/sh_animation.lua")

    -- 战场阵线偶数偏移驱动（时间刻结束后偶数阵线全卡 0.3s 线性右移 0.5*SPACING，纯 Lua）
    include("kards/sh_battlefield_center.lua")

    -- 3D 模型渲染接入层（前置模组 Simple Static Model Importer 导入的牌桌/卡牌模型接入战斗系统；
    -- 服务端生成实体 + 每帧采样 card.pos/ang 驱动，演示命令 kards_battle_demo）
    include("kards/sh_battle_render.lua")

    -- 子物体系统（牌桌空卡占位统一管理：相对/世界坐标换算、设置/获得相对坐标、
    -- 新建（固定空卡 + 材质接口）/ 删除（1 秒透明度淡出后销毁），统一相对 z 轴，纯 Lua 共享）
    include("kards/sh_child_system.lua")

    -- 虚拟 3D2D 输入框通用模块（2026-09-05：在牌桌平面内渲染半透明输入框，
    -- 所有玩家实时看到输入文本；作为通用方法供组卡搜索等场景使用，见 sh_3d2d_input.lua）
    include("kards/sh_3d2d_input.lua")

    -- 牌桌卡牌 manifest 共享模块（re.md T-H2：收敛 init.lua / cl_init.lua 多份同构
    -- Ensure*Manifest 实现为单一「副本克隆 + image_path 改写」，两端仅保留薄包装调用）
    include("kards/sh_card_manifest.lua")

    -- 战斗骨架测试脚本（控制台命令 kards_test 运行，覆盖刻度格式/爆牌/钩子反制/战场布局场景）
    include("kards/test/ticklog_test.lua")

    -- 节点解析器测试脚本（控制台命令 kards_node_test 运行，按节点类型分割场景覆盖解析器与操作）
    include("kards/test/node_parser_test.lua")

    -- 节点解析器战斗场景测试脚本（控制台命令 kards_node_battle_test 运行，
    -- 对 action/card 全组合设立战斗场景，P1 打出带 effect 的指令卡触发节点效果）
    include("kards/test/node_parser_battle_test.lua")
end

-- 加载服务端文件
local function LoadServerFiles()
    if SERVER then
        KARDS.CardEditor:Log("Loading server files...")

        -- 服务端动画系统
        include("card_editor/sv_animation.lua")

        -- 注册网络消息
        util.AddNetworkString(KARDS.CardEditor.Animation.Net.StartEditorAnim)
        util.AddNetworkString(KARDS.CardEditor.Animation.Net.StopEditorAnim)
        util.AddNetworkString(KARDS.CardEditor.Animation.Net.SyncAnimState)

        -- 注册 KARDS_Editor_CloseKeepAnim 网络消息（从 sv_animation.lua 集中到此）
        util.AddNetworkString("KARDS_Editor_CloseKeepAnim")
    end
end

-- 加载客户端文件
local function LoadClientFiles()
    if CLIENT then
        KARDS.CardEditor:Log("Loading client files...")

        -- 提前初始化 Canvas 命名空间，因为其他模块在加载时需要访问
        KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}

        -- 思源黑体空格补偿（渲染层统一处理，需在其他 UI 模块绘制前安装）
        include("card_editor/cl_sourcehan_space.lua")

        -- 音效管理器
        include("card_editor/cl_audio_manager.lua")

        -- 客户端动画系统
        include("card_editor/cl_animation.lua")

        -- INE 节点编辑器系统
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_node_editor.lua...")
        include("card_editor/ine_editor/cl_ine_node_editor.lua")

        -- INE 编辑器子系统：内联输入会话（透明 DTextEntry 生命周期唯一实现处，见 ADR 0010）
        -- 必须在 cl_ine_node_editor.lua 之后、cl_ine_think.lua 之前
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_inline_field.lua...")
        include("card_editor/ine_editor/cl_ine_inline_field.lua")

        -- INE 编辑器子系统：配置 DSL 解析（从 cl_ine_node_editor.lua 拆分，2026-10-18）
        -- 必须紧跟核心文件：LogNewNode 注册模板时会调用 INE.ParseConfig
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_config_parser.lua...")
        include("card_editor/ine_editor/cl_ine_config_parser.lua")

        -- INE 编辑器子系统：视图、缩放、通知、提示、浮层窗口（从 cl_ine_node_editor.lua 拆分）
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_view.lua...")
        include("card_editor/ine_editor/cl_ine_view.lua")

        -- INE 编辑器子系统：每帧逻辑更新（从 cl_ine_node_editor.lua 拆分）
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_think.lua...")
        include("card_editor/ine_editor/cl_ine_think.lua")

        -- INE 编辑器子系统：命中检测（从 cl_ine_node_editor.lua 拆分）
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_hit_test.lua...")
        include("card_editor/ine_editor/cl_ine_hit_test.lua")

        -- INE 编辑器子系统：统一槽系统（依赖 INE 命名空间）
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_unified_slot.lua...")
        include("card_editor/ine_editor/cl_ine_unified_slot.lua")

        -- INE 编辑器子系统：变量对话框
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_variable_dialogs.lua...")
        include("card_editor/ine_editor/cl_ine_variable_dialogs.lua")

        -- INE 编辑器子系统：函数子编辑器
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_function_sub_editor.lua...")
        include("card_editor/ine_editor/cl_ine_function_sub_editor.lua")

        -- INE 编辑器子系统：全局变量面板
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_global_var_page.lua...")
        include("card_editor/ine_editor/cl_ine_global_var_page.lua")

        -- INE 编辑器子系统：基础变量操作节点系统（依赖 INE 命名空间和 LogNewNode）
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_var_op_nodes.lua...")
        local varOpOk, varOpErr = pcall(function()
            include("card_editor/ine_editor/cl_ine_var_op_nodes.lua")
        end)
        if not varOpOk then
            KARDS.CardEditor:Log("Error loading cl_ine_var_op_nodes.lua: " .. tostring(varOpErr), "ERROR")
        end

        -- INE 编辑器子系统：叠加窗口输入处理（必须早于 cl_ine_input_handling.lua）
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_input_overlay.lua...")
        local overlayOk, overlayErr = pcall(function()
            include("card_editor/ine_editor/cl_ine_input_overlay.lua")
        end)
        if not overlayOk then
            KARDS.CardEditor:Log("Error loading cl_ine_input_overlay.lua: " .. tostring(overlayErr), "ERROR")
        end

        -- INE 编辑器子系统：输入处理
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_input_handling.lua...")
        local inputOk, inputErr = pcall(function()
            include("card_editor/ine_editor/cl_ine_input_handling.lua")
        end)
        if not inputOk then
            KARDS.CardEditor:Log("Error loading cl_ine_input_handling.lua: " .. tostring(inputErr), "ERROR")
        end

        -- INE 编辑器子系统：输入动作表（2026-11-08，ADR 0004，须在输入处理之后）
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_input_actions.lua...")
        local actionsOk, actionsErr = pcall(function()
            include("card_editor/ine_editor/cl_ine_input_actions.lua")
        end)
        if not actionsOk then
            KARDS.CardEditor:Log("Error loading cl_ine_input_actions.lua: " .. tostring(actionsErr), "ERROR")
        end

        -- INE 编辑器子系统：节点绘制
        KARDS.CardEditor:Log("Loading ine_editor/cl_ine_node_drawing.lua...")
        include("card_editor/ine_editor/cl_ine_node_drawing.lua")

        -- 节点基础系统
        KARDS.CardEditor:Log("Loading cl_node_base.lua...")
        include("card_editor/cl_node_base.lua")

        -- 卡牌预览渲染
        KARDS.CardEditor:Log("Loading cl_card_preview.lua...")
        include("card_editor/cl_card_preview.lua")

        -- Apple 设计系统全局常量及工具函数（必须在其他 canvas_editor 文件之前加载）
        KARDS.CardEditor:Log("Loading canvas_editor/cl_apple_design.lua...")
        include("card_editor/canvas_editor/cl_apple_design.lua")

        -- 外观编辑器 VGUI 控件
        KARDS.CardEditor:Log("Loading canvas_editor/appearance_editor/cl_appearance_editor.lua...")
        include("card_editor/canvas_editor/appearance_editor/cl_appearance_editor.lua")

        -- 画布编辑器子系统：卡牌选择器
        KARDS.CardEditor:Log("Loading canvas_editor/cl_ca_card_selector.lua...")
        include("card_editor/canvas_editor/cl_ca_card_selector.lua")

        -- 画布编辑器子系统：旧节点绘制兼容
        KARDS.CardEditor:Log("Loading canvas_editor/effect_editor/cl_ca_node_drawing.lua...")
        include("card_editor/canvas_editor/effect_editor/cl_ca_node_drawing.lua")

        -- 画布编辑器子系统：通知/提示系统
        KARDS.CardEditor:Log("Loading canvas_editor/cl_ca_notifications.lua...")
        include("card_editor/canvas_editor/cl_ca_notifications.lua")

        -- 画布编辑器子系统：保存/加载窗口
        KARDS.CardEditor:Log("Loading canvas_editor/cl_ca_save_load.lua...")
        include("card_editor/canvas_editor/cl_ca_save_load.lua")

        -- 新画布编辑器（基于全屏根面板 + Paint 绘制）
        KARDS.CardEditor:Log("Loading canvas_editor/effect_editor/cl_canvas_editor.lua...")
        local success, err = pcall(function()
            include("card_editor/canvas_editor/effect_editor/cl_canvas_editor.lua")
        end)
        if success then
            KARDS.CardEditor:Log("canvas_editor/effect_editor/cl_canvas_editor.lua loaded successfully")
            if KARDS.CardEditor.Canvas then
                KARDS.CardEditor:Log("Canvas initialized: " .. tostring(KARDS.CardEditor.Canvas))
            else
                KARDS.CardEditor:Log("Canvas is nil after loading")
            end
        else
            KARDS.CardEditor:Log("Error loading canvas_editor/effect_editor/cl_canvas_editor.lua: " .. err)
        end

        -- 画布编辑器子系统：UI 组件（从 cl_canvas_editor.lua 拆分）
        KARDS.CardEditor:Log("Loading canvas_editor/effect_editor/cl_ca_ui_components.lua...")
        include("card_editor/canvas_editor/effect_editor/cl_ca_ui_components.lua")

        -- 画布编辑器子系统：输入处理（从 cl_canvas_editor.lua 拆分）
        KARDS.CardEditor:Log("Loading canvas_editor/effect_editor/cl_ca_input_handling.lua...")
        include("card_editor/canvas_editor/effect_editor/cl_ca_input_handling.lua")

        -- 画布编辑器子系统：外貌编辑区（从 cl_canvas_editor.lua 拆分）
        KARDS.CardEditor:Log("Loading canvas_editor/appearance_editor/cl_ca_appearance_editors.lua...")
        include("card_editor/canvas_editor/appearance_editor/cl_ca_appearance_editors.lua")

        -- 纹理边界计算模块（本次从 cl_canvas_editor.lua 拆分）
        include("card_editor/canvas_editor/effect_editor/cl_ca_texture_bounds.lua")

        -- 卡牌离屏渲染模块（本次从 cl_canvas_editor.lua 拆分）
        include("card_editor/canvas_editor/effect_editor/cl_ca_card_render.lua")

        -- 变量弹窗与对象选择器模块（本次从 cl_canvas_editor.lua 拆分）
        include("card_editor/canvas_editor/effect_editor/cl_ca_var_popups.lua")

        -- BGM 扩展国家菜单模块（本次从 cl_canvas_editor.lua 拆分）
        include("card_editor/canvas_editor/effect_editor/cl_ca_bgm_menu.lua")

        -- 文件管理器与音效命名模块（本次从 cl_canvas_editor.lua 拆分）
        include("card_editor/canvas_editor/effect_editor/cl_ca_file_manager.lua")

        -- 关于页（2026-10-05）：版本时间线、开发者与鸣谢名单、素材来源弹窗
        include("card_editor/canvas_editor/effect_editor/cl_ca_about_page.lua")

        -- 卡牌渲染系统（cl_card_renderer.lua 已删，2026-08-15 编辑器重构 7.5-1 孤儿链清理）
        -- 动态材质：canvas_editor/effect_editor/cl_canvas_editor.lua 统一管理

        -- dynamic_BGM 兼容性模块
        KARDS.CardEditor:Log("Loading dynamic_BGM compatibility module...")
        local compatSuccess, compatErr = pcall(function()
            include("card_editor/cl_dynamic_bgm_compat.lua")
        end)
        if compatSuccess then
            KARDS.CardEditor:Log("dynamic_BGM compatibility module loaded successfully")
        else
            KARDS.CardEditor:Log("Error loading dynamic_BGM compatibility module: " .. compatErr)
        end

        -- 通用 6 值关键帧动画播放器（re.md 重构：统一牌桌 3D 动画为 pos.xyz + ang.pyr
        -- 关键帧驱动；先于战斗相机加载——相机进入动画复用本播放器）
        KARDS.CardEditor:Log("Loading kards/cl_anim_player.lua...")
        include("kards/cl_anim_player.lua")

        -- 战斗相机控制（CalcView 接管本地玩家相机；控制台命令 kards_camera 模拟战斗视角）
        KARDS.CardEditor:Log("Loading kards/cl_battle_camera.lua...")
        include("kards/cl_battle_camera.lua")

        -- 单位词条图标（2026-08-13：3D2D 上下文内右缘外侧竖排绘制，见
        -- cl_battle_keyword_icons.lua；先于 cl_card_text_overlay.lua 加载，
        -- 后者 DrawOverlay 的单位/总部分支调用 KARDS.KeywordIcons:Draw）
        KARDS.CardEditor:Log("Loading kards/cl_battle_keyword_icons.lua...")
        include("kards/cl_battle_keyword_icons.lua")

        -- 卡牌 3D2D 属性文字叠加层（客户端：编辑器 3D2D 文字卡生成 + 战场卡牌属性文字实时悬浮）
        KARDS.CardEditor:Log("Loading kards/cl_card_text_overlay.lua...")
        include("kards/cl_card_text_overlay.lua")

        -- 客户端视角朝向基础模块（基础规则：P1/P2/观战三视角的战场卡牌朝向，
        -- 朝向由客户端本地计算，服务端只发归属数据；见 cl_perspective.lua）
        KARDS.CardEditor:Log("Loading kards/cl_perspective.lua...")
        include("kards/cl_perspective.lua")
    end
end

-- 初始化函数
function KARDS.CardEditor:Initialize()
    self:Log("Initializing Kards Card Editor v" .. self.Version)

    -- 加载所有文件
    LoadSharedFiles()
    LoadServerFiles()
    LoadClientFiles()

    -- 注册网络消息（KARDS_Editor_SaveCard/LoadCard/DeleteCard/CardList 随 sv_storage.lua 删除，2026-08-15 编辑器重构 7.5-1）
    if SERVER then
        util.AddNetworkString("KARDS_Editor_Open")
    end

    self:Log("Initialization complete")
end

-- 打开编辑器
function KARDS.CardEditor:OpenEditor(ply)
    if CLIENT then
        if not KARDS.CardEditor.Canvas then
            KARDS.CardEditor:Log("Canvas 模块未初始化，尝试重新加载 canvas_editor/effect_editor/cl_canvas_editor.lua...")
            KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}
            local success, err = pcall(function()
                include("card_editor/canvas_editor/effect_editor/cl_canvas_editor.lua")
            end)
            if not success then
                KARDS.CardEditor:Log("重新加载 cl_canvas_editor.lua 失败: " .. tostring(err), "ERROR")
                return
            end
        end
        if KARDS.CardEditor.Canvas and KARDS.CardEditor.Canvas.OpenEditor then
            KARDS.CardEditor.Canvas.OpenEditor()
        else
            KARDS.CardEditor:Log("Canvas.OpenEditor 不可用", "ERROR")
        end
    elseif SERVER then
        net.Start("KARDS_Editor_Open")
        net.Send(ply)
    end
end

-- 当 Lua 初始化时执行
if not KARDS.CardEditor.Initialized then
    KARDS.CardEditor:Initialize()
    KARDS.CardEditor.Initialized = true
else
    KARDS.CardEditor:Log("Editor already initialized")
end

-- 确保客户端命令注册（最终版本，覆盖之前注册的任何版本）
if CLIENT then
    concommand.Add("kards_editor", function()
        print("[KARDS] Opening canvas editor...")
        if KARDS.CardEditor.Canvas and KARDS.CardEditor.Canvas.ToggleEditor then
            KARDS.CardEditor.Canvas.ToggleEditor()
        else
            KARDS.CardEditor:OpenEditor()
        end
    end)
end

-- 当玩家加入时的处理
if SERVER then
    hook.Add("PlayerInitialSpawn", "KARDS_Editor_PlayerInitialSpawn", function(ply)
        KARDS.CardEditor:Log("Player " .. ply:Name() .. " joined")
    end)

    -- 控制台命令
    concommand.Add("kards_editor", function(ply)
        if IsValid(ply) then
            KARDS.CardEditor:OpenEditor(ply)
        end
    end)
end

if CLIENT then
    -- 网络消息处理
    net.Receive("KARDS_Editor_Open", function()
        KARDS.CardEditor:OpenEditor()
    end)
end
