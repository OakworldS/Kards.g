KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}

local T = KARDS.Lang.T

-- 滚轮缩放标记（CreateMove 中设值，Draw 中消费）
-- 用于卡牌插图预览和卡牌预览图的滚轮缩放
KARDS.CardEditor.Canvas._wheelZoomIn = false
KARDS.CardEditor.Canvas._wheelZoomOut = false

-- 音效伪命名（SoundAliases / F2 重命名状态）已拆分至 effect_editor/cl_ca_file_manager.lua

-- 展开的 BGM 国家配置（顶栏倒三角按钮展开的更多国家音乐组）
-- 与主行按钮同款圆钮样式；flags 图标缺失时自动回退为名称首字
-- iconMat 用 file.Exists 预判：文件存在才创建材质，否则为 nil（Material 对不存在文件返回的材质不可靠）
KARDS.CardEditor.Canvas.BGMExpandCountries = {
    { id = "finland", name = T("editor.canvas.country_finland"), icon = "materials/kards/flags/finland.png", iconMat = file.Exists("materials/kards/flags/finland.png", "GAME") and Material("materials/kards/flags/finland.png", "noclamp smooth") or nil, color = Color(70, 110, 200), description = T("editor.canvas.country_finland_desc") },
    { id = "italy", name = T("editor.canvas.country_italy"), icon = "materials/kards/flags/italy.png", iconMat = file.Exists("materials/kards/flags/italy.png", "GAME") and Material("materials/kards/flags/italy.png", "noclamp smooth") or nil, color = Color(40, 140, 70), description = T("editor.canvas.country_italy_desc") },
    { id = "australia", name = T("editor.canvas.country_australia"), icon = "materials/kards/flags/australia.png", iconMat = file.Exists("materials/kards/flags/australia.png", "GAME") and Material("materials/kards/flags/australia.png", "noclamp smooth") or nil, color = Color(30, 60, 160), description = T("editor.canvas.country_australia_desc") },
    { id = "france", name = T("editor.canvas.country_france"), icon = "materials/kards/flags/france.png", iconMat = file.Exists("materials/kards/flags/france.png", "GAME") and Material("materials/kards/flags/france.png", "noclamp smooth") or nil, color = Color(50, 90, 200), description = T("editor.canvas.country_france_desc") },
    { id = "poland", name = T("editor.canvas.country_poland"), icon = "materials/kards/flags/poland.png", iconMat = file.Exists("materials/kards/flags/poland.png", "GAME") and Material("materials/kards/flags/poland.png", "noclamp smooth") or nil, color = Color(190, 40, 40), description = T("editor.canvas.country_poland_desc") }
}

-- 判断国家id是否属于展开的扩展国家组（非原 5 国）
function KARDS.CardEditor.Canvas.IsBGMExpandCountry(countryId)
    for _, c in ipairs(KARDS.CardEditor.Canvas.BGMExpandCountries) do
        if c.id == countryId then
            return true
        end
    end
    return false
end

-- Apple 设计系统全局常量及工具函数（由 cl_apple_design.lua 自动加载）
-- 包含：APPLE_BLUE, APPLE_INK, APPLE_RADII, APPLE_SPACE, IsMouseIn 等

-- 高级文本绘制（DrawRichText / DrawSpecialEffectRichText 及其专属辅助 keywordsForHighlight / GetTextSizeForFont / ParseFormatTags / FindVarByInternalName_CE）经确认零调用点，已于 2026-10-04 拆分时删除

-- 从 CardAppearance 更新所有剩余输入框的状态（由 cl_appearance_editor.lua 定义）
-- 此函数在 cl_appearance_editor.lua 中已重写为简化版本，
-- 这里作为备用保留，确保加载顺序不影响功能

-- 从 veteranAppearance 更新老兵输入框的状态（由 cl_appearance_editor.lua 定义）
-- 此函数在 cl_appearance_editor.lua 中已重写为简化版本，
-- 这里作为备用保留，确保加载顺序不影响功能

-- 离屏渲染与卡牌材质（RenderAndSaveCard / SpawnTestEntity / DynamicMaterials 等）已拆分至 effect_editor/cl_ca_card_render.lua

KARDS.CardEditor.Canvas.Enabled = false
KARDS.CardEditor.Canvas.RootPanel = nil
KARDS.CardEditor.Canvas.HUDHookAdded = false

KARDS.CardEditor.Canvas.Window = {
    x = 50,
    y = 50,
    width = ScrW() - 100,
    height = ScrH() - 100,
    fileMenuOpen = false
}

KARDS.CardEditor.Canvas.Nodes = {}
KARDS.CardEditor.Canvas.Connections = {}
KARDS.CardEditor.Canvas.NodeCounter = 0
KARDS.CardEditor.Canvas.ConnectionCounter = 0

KARDS.CardEditor.Canvas.TempNode = nil
KARDS.CardEditor.Canvas.TempConnection = nil
KARDS.CardEditor.Canvas.DraggingNode = nil
KARDS.CardEditor.Canvas.HoveredConnection = nil
KARDS.CardEditor.Canvas.HoveredNode = nil -- 跟踪悬停的节点
KARDS.CardEditor.Canvas.LastRightMouseState = false
KARDS.CardEditor.Canvas.LastInputPortClickTime = 0
KARDS.CardEditor.Canvas.CurrentPage = "appearance" -- "effect" or "appearance"
KARDS.CardEditor.Canvas.AppearanceEditorActive = false -- 卡牌外貌编辑器是否激活
KARDS.CardEditor.Canvas.CurrentCardFile = nil -- 当前编辑卡牌对应的磁盘文件名（默认卡牌解锁定位用）
-- 多选节点相关状态
KARDS.CardEditor.Canvas.SelectionState = {
    isSelecting = false,       -- 是否正在框选
    startX = 0,                -- 框选起始点X
    startY = 0,                -- 框选起始点Y
    selectedNodes = {}         -- 选中的节点列表
}
KARDS.CardEditor.Canvas.ToggleAppearanceBtn = {
    x = 0,
    y = 0,
    width = 200,
    height = 40,
    text = T("editor.canvas.launch_appearance_editor"),
    hovered = false
}

-- 文件菜单状态（卡牌编辑器只保存卡牌，效果由 INE 编辑器处理）
KARDS.CardEditor.Canvas.FileMenu = {
    visible = false,
    x = 0,
    y = 0,
    width = 280,
    height = 145,
    buttons = {
        {
            id = "save",
            text = T("editor.canvas.save"),
            x = 0,
            y = 0,
            width = 260,
            height = 30,
            hovered = false
        },
        {
            id = "load",
            text = T("editor.canvas.load"),
            x = 0,
            y = 0,
            width = 260,
            height = 30,
            hovered = false
        },
        {
            id = "delete",
            text = T("editor.canvas.delete"),
            x = 0,
            y = 0,
            width = 260,
            height = 30,
            hovered = false
        }
    }
}

-- 卡牌单选组件状态
KARDS.CardEditor.Canvas.CardSelector = {
    visible = false,
    expanded = false,
    x = 0,
    y = 0,
    width = 400,
    height = 35, -- 收起时高度
    expandedHeight = 400, -- 展开时高度
    selectedCard = nil, -- 选中的卡牌
    cardsList = {}, -- 卡牌列表
    hoveredCardIndex = nil, -- 悬停的卡牌索引
    scrollOffset = 0 -- 滚动偏移
}

-- 刷新卡牌列表
function KARDS.CardEditor.Canvas.CardSelector.RefreshList()
    if KARDS.CardEditor.SaveSystem and KARDS.CardEditor.SaveSystem.GetAllSavedCardsInfo then
        KARDS.CardEditor.Canvas.CardSelector.cardsList = KARDS.CardEditor.SaveSystem.GetAllSavedCardsInfo()
    else
        KARDS.CardEditor.Canvas.CardSelector.cardsList = {}
    end
end
KARDS.CardEditor.Canvas.Tabs = {
    {
        id = "appearance",
        name = T("editor.canvas.tab_appearance"),
        width = 40,
        height = 150
    },
    {
        id = "effect",
        name = T("editor.canvas.tab_effect"),
        width = 40,
        height = 150
    },
    {
        id = "about",
        name = T("editor.canvas.tab_about"),
        width = 40,
        height = 150
    }
}



-- 保存窗口状态

KARDS.CardEditor.Canvas.LastInputPortClickTime = 0

-- 纹理边界计算（GetCardTextureBounds / GetTemplateHollowBounds）已拆分至 effect_editor/cl_ca_texture_bounds.lua

-- 初始化开始点节点
function KARDS.CardEditor.Canvas.InitializeStartNodes()
    -- 清除现有的开始点节点
    local nodesToRemove = {}
    for i, node in ipairs(KARDS.CardEditor.Canvas.Nodes) do
        if node.isStartNode then
            table.insert(nodesToRemove, i)
        end
    end
    for i = #nodesToRemove, 1, -1 do
        table.remove(KARDS.CardEditor.Canvas.Nodes, nodesToRemove[i])
    end
    
    -- 根据当前模式选择开始点
    local specialOutputs
    if KARDS.CardEditor.Canvas.EditorMode == "unit" then
        -- 单位模式：原有开始点
        specialOutputs = {"抽取", "部署", "加入", "在场", "死亡", "离开"}
        -- 当 can_elevate_to_veteran 被勾选时，添加"升级"开始点
        -- "升级"开始点用于定义卡牌升级为老兵时触发的特殊效果逻辑
        if table.HasValue(KARDS.CardEditor.Canvas.CardAppearance.keywords or {}, "can_elevate_to_veteran") then
            table.insert(specialOutputs, "升级")
        end
    elseif KARDS.CardEditor.Canvas.EditorMode == "command" then
        -- 指令模式：抽取、打出、弃牌、爆牌
        specialOutputs = {"抽取", "打出", "弃牌", "爆牌"}
    elseif KARDS.CardEditor.Canvas.EditorMode == "counter_command" then
        -- 反制指令模式：抽取、激活时、弃牌、爆牌
        specialOutputs = {"抽取", "激活时", "弃牌", "爆牌"}
    elseif KARDS.CardEditor.Canvas.EditorMode == "headquarter" then
        -- 总部模式：常驻牌桌，效果围绕自身受击/防御变化触发
        specialOutputs = {"在场", "受到伤害", "防御变化"}
    else
        -- 默认单位模式
        specialOutputs = {"抽取", "部署", "加入", "在场", "死亡", "离开"}
    end
    
    local win = KARDS.CardEditor.Canvas.Window
    local contentX = win.x + 5
    local contentY = win.y + 75
    local selectorW = 180
    local specialOutputX = contentX + selectorW + 20
    local specialOutputSpacing = 60
    local activationNodeId = nil
    
    for i, outputName in ipairs(specialOutputs) do
        local outputY = contentY + 50 + (i - 1) * specialOutputSpacing
        local nodeX = specialOutputX - 100
        local nodeY = outputY - 50
        
        local node = {
            id = "special_" .. outputName,
            type = "start",
            title = outputName,
            color = Color(70, 130, 180),
            x = nodeX - win.x,
            y = nodeY - win.y,
            width = 200,
            height = 100,
            dragging = false,
            dragStartX = 0,
            dragStartY = 0,
            startX = 0,
            startY = 0,
            hasInput = false,
            hasOutput = true,
            isStartNode = true
        }
        
        table.insert(KARDS.CardEditor.Canvas.Nodes, node)
        
        -- 记住激活时开始点的ID
        if outputName == "激活时" then
            activationNodeId = node.id
        end
    end
    
    -- 反制指令模式：创建特殊事件监测节点
    if KARDS.CardEditor.Canvas.EditorMode == "counter_command" and activationNodeId then
        -- 检查是否已存在特殊事件监测节点
        local hasEventMonitor = false
        for _, node in ipairs(KARDS.CardEditor.Canvas.Nodes) do
            if node.isEventMonitor and node.canDelete == false then
                hasEventMonitor = true
                break
            end
        end
        
        if not hasEventMonitor then
            -- 创建特殊事件监测节点
            local eventMonitorNode = {
                id = "event_monitor_special",
                type = "event_monitor",
                title = T("editor.canvas.node_event_monitor"),
                color = Color(180, 100, 180),
                x = 150,
                y = 110,
                width = 600,
                height = 80,
                dragging = false,
                dragStartX = 0,
                dragStartY = 0,
                startX = 0,
                startY = 0,
                hasInput = true,
                hasOutput = true,
                isStartNode = false,
                isEventMonitor = true,
                canDelete = false
            }
            table.insert(KARDS.CardEditor.Canvas.Nodes, eventMonitorNode)
            
            -- 自动连接到激活时开始点
            local connection = {
                id = "conn_event_monitor",
                fromNode = activationNodeId,
                toNode = eventMonitorNode.id
            }
            table.insert(KARDS.CardEditor.Canvas.Connections, connection)
            KARDS.CardEditor.Canvas.ConnectionCounter = KARDS.CardEditor.Canvas.ConnectionCounter + 1
        end
    end
end

-- 过滤指令/反制指令卡牌允许的关键词（仅保留情报和协力）
local function FilterCommandKeywords(keywords)
    local newKeywords = {}
    for _, kw in ipairs(keywords or {}) do
        if kw == "intel" or kw == "cooperation" or kw == "forecast" then
            table.insert(newKeywords, kw)
        end
    end
    return newKeywords
end

-- 根据卡牌类型更新编辑器模式
function KARDS.CardEditor.Canvas.UpdateEditorModeFromCardType()
    local cardAppearance = KARDS.CardEditor.Canvas.CardAppearance
    local cardType = cardAppearance.cardType
    cardAppearance.keywords = cardAppearance.keywords or {}
    
    if cardType == "infantry" or cardType == "tank" or cardType == "artillery" or cardType == "fighter" or cardType == "bomber" then
        KARDS.CardEditor.Canvas.EditorMode = "unit"
    elseif cardType == "command" then
        KARDS.CardEditor.Canvas.EditorMode = "command"
        cardAppearance.keywords = FilterCommandKeywords(cardAppearance.keywords)
    elseif cardType == "counter_command" then
        KARDS.CardEditor.Canvas.EditorMode = "counter_command"
        cardAppearance.keywords = FilterCommandKeywords(cardAppearance.keywords)
    elseif cardType == "headquarter" then
        -- 总部模式：无词条（词条书签不可编辑），仅防御力（默认 20）
        KARDS.CardEditor.Canvas.EditorMode = "headquarter"
        cardAppearance.keywords = {}
        if not (cardAppearance.defense and cardAppearance.defense > 0) then
            cardAppearance.defense = 20
        end
    else
        KARDS.CardEditor.Canvas.EditorMode = "unit"
    end
    -- 更新UI控件
    KARDS.CardEditor.Canvas.UpdateControlsFromAppearance()
    -- 更新开始点
    KARDS.CardEditor.Canvas.InitializeStartNodes()
end
KARDS.CardEditor.Canvas.Templates = {
    { type = "trigger", name = T("editor.canvas.node_trigger"), color = Color(70, 130, 180), hasInput = true, hasOutput = true,
      config = "'使这个(这些)卡牌' {攻击、防御} {设置为、增加、减少} [] (n攻击力、n防御力)" },
    { type = "condition", name = T("editor.canvas.node_condition"), color = Color(60, 179, 113), hasInput = true, hasOutput = true,
      config = "n'当' {敌方、友方} {单位数量、总部血量、不同国籍单位数、最大攻击力单位、最小攻击力单位、最大防御力单位、最小防御力单位} {=、>、<、>=、<=} [lib] (n比较结果、p布尔值)" },
    { type = "target_selector", name = T("editor.canvas.node_target_selector"), color = Color(20, 90, 50), hasInput = true, hasOutput = true,
      config = "e'{指向一个、随机、所有} if 随机 then [] end {友方、敌方、场上} {单位、目标、总部} if 单位 then ':' {战斗机、坦克、轰炸机、炮兵、步兵} end (e选中的卡牌)" },
    { type = "loop", name = T("editor.canvas.node_loop"), color = Color(255, 215, 0), hasInput = true, hasOutput = true,
      config = "'重复信号' [] '次' (n循环次数)" },
    { type = "card", name = T("editor.canvas.node_card"), color = Color(220, 20, 60), hasInput = true, hasOutput = true,
      config = "e'{抽取、复制、弃掉、开发、选择、爆牌、洗切卡组、洗入} if 抽取 then [] '张' {卡组顶、卡组底、随机、指定} '的卡牌' elseif 复制 then [] '张' {卡组顶、卡组底、随机、指定} '的卡牌' elseif 弃掉 then [] '张' {卡组顶、卡组底、随机、指定} '的卡牌' elseif 开发 then [] '次' {卡组中、卡组顶、卡组底、本国指令、本国精英指令、本国精英单位} '的牌' elseif 选择 then [] '次' '观星' elseif 爆牌 then [] '次' elseif 洗入 then {手牌中、指定的} if 手牌中 then {随机、指定} '的' [] '张牌' else [] '张牌' end end (e影响的卡牌)" },
    { type = "property", name = T("editor.canvas.node_property"), color = Color(148, 0, 211), hasInput = true, hasOutput = true,
      config = "{随机排列所有} {单位、友方单位、敌方单位}" },
    { type = "event_monitor", name = T("editor.canvas.node_event_monitor"), color = Color(180, 100, 180), hasInput = true, hasOutput = true,
      config = "{友方、敌方} {目标、单位、总部、打出指令、触发反制、玩家、回合} if 总部 then '防御' '=' [] elseif 目标 or 单位 then {有变化的、触发} if 有变化的 then {属性、攻防、攻击、防御、行动花费} {变化了、增加了、减少了、为} '=' [] else {抑制、老兵、部署、触发、被动效果、转换、修复、开发、控制、免疫、情报、动员、奋战、守护、山地、亡计、伏击、倒计时、冲击、重甲、钳击、闪击、隐蔽、烟幕、协力} end elseif 打出指令 or 触发反制 then {时、的花费、的情报} if 的花费 or 的情报 then '=' [] end elseif 玩家 then {抽牌、额外抽牌、弃牌、爆牌} '=' [] '张时' elseif 回合 then {开始、结束} '时' end (t事件类型、e事件目标、p触发事件)" }
}

-- 当前编辑器模式
-- "unit" = 单位模式
-- "command" = 指令模式
-- "counter_command" = 反制指令模式
KARDS.CardEditor.Canvas.EditorMode = "unit"


KARDS.CardEditor.Canvas.UnitTypeRules = {

    ["战斗机"] = T("editor.canvas.rule_fighter"),
    ["坦克"] = T("editor.canvas.rule_tank"),
    ["轰炸机"] = T("editor.canvas.rule_bomber"),
    ["炮兵"] = T("editor.canvas.rule_artillery"),
    ["步兵"] = T("editor.canvas.rule_infantry")
}

-- 术语悬停释义表（依据 readme 七、Kards 基本规则 7.1/7.2/7.3；zh-CN 键）
-- 供 select 下拉（DrawDropdown / DrawExpandedDropdowns）悬停选项时提示名词含义，
-- 便于玩家区分近义词（交战/战斗、压制/抑制、攻击/攻击力、弃掉/弃牌等）。
-- 匹配方式见 LookupTermTooltip：整词优先，其次取选项文本内最长包含的术语。
KARDS.CardEditor.Canvas.TermTooltips = {

    -- 7.1 综合规则（readme.md L114-139）
    ["总部"] = T("editor.canvas.term_hq"),
    ["目标"] = T("editor.canvas.term_target"),
    ["单位"] = T("editor.canvas.term_unit"),
    ["战斗"] = T("editor.canvas.term_combat"),
    ["交战"] = T("editor.canvas.term_engage"),
    ["撤退"] = T("editor.canvas.term_retreat"),
    ["移动"] = T("editor.canvas.term_move"),
    ["攻击"] = T("editor.canvas.term_attack"),
    ["反击"] = T("editor.canvas.term_counterattack"),
    ["部署"] = T("editor.canvas.term_deploy"),
    ["指令"] = T("editor.canvas.term_order"),
    ["反制"] = T("editor.canvas.term_countermeasure"),
    ["前线"] = T("editor.canvas.term_frontline"),
    ["支援阵线"] = T("editor.canvas.term_support_line"),
    ["手牌"] = T("editor.canvas.term_hand"),
    ["卡组"] = T("editor.canvas.term_deck"),
    ["指挥点"] = T("editor.canvas.term_kredit"),
    ["指挥点槽"] = T("editor.canvas.term_kredit_slot"),
    ["士气伤害"] = T("editor.canvas.term_morale_damage"),
    ["重新调度"] = T("editor.canvas.term_mulligan"),
    ["伤害"] = T("editor.canvas.term_damage"),
    ["加入战场"] = T("editor.canvas.term_add_to_battlefield"),
    ["加入前线"] = T("editor.canvas.term_add_to_frontline"),
    ["返回手牌"] = T("editor.canvas.term_return_to_hand"),
    ["召唤单位"] = T("editor.canvas.term_summon_unit"),
    ["触发关键字效果"] = T("editor.canvas.term_trigger_keyword"),

    -- 7.2.1 效果能力（readme.md L145-156）
    ["被压制"] = T("editor.canvas.term_pinned"),
    ["压制"] = T("editor.canvas.term_pin"),
    ["被守护"] = T("editor.canvas.term_guarded"),
    ["抑制"] = T("editor.canvas.term_suppressed"),
    ["触发"] = T("editor.canvas.term_triggered"),
    ["被动效果"] = T("editor.canvas.term_passive"),
    ["转换"] = T("editor.canvas.term_transform"),
    ["修复"] = T("editor.canvas.term_repair"),
    ["开发"] = T("editor.canvas.term_develop"),
    ["控制"] = T("editor.canvas.term_control"),
    ["免疫"] = T("editor.canvas.term_immune"),
    ["老兵"] = T("editor.canvas.term_veteran"),
    ["老兵(精英)"] = T("editor.canvas.term_veteran_elite"),
    ["情报"] = T("editor.canvas.term_intel"),

    -- 7.2.2 / 7.2.3 战斗词条能力（readme.md L160-179）
    ["动员"] = T("editor.canvas.term_mobilize"),
    ["奋战"] = T("editor.canvas.term_fury"),
    ["守护"] = T("editor.canvas.term_guard"),
    ["山地"] = T("editor.canvas.term_mountain"),
    ["亡计"] = T("editor.canvas.term_deathrattle"),
    ["伏击"] = T("editor.canvas.term_ambush"),
    ["倒计时"] = T("editor.canvas.term_countdown"),
    ["冲击"] = T("editor.canvas.term_impact"),
    ["重甲"] = T("editor.canvas.term_heavy_armor"),
    ["钳击"] = T("editor.canvas.term_pincer"),
    ["闪击"] = T("editor.canvas.term_blitz"),
    ["隐蔽"] = T("editor.canvas.term_camouflage"),
    ["烟幕"] = T("editor.canvas.term_smokescreen"),
    ["协力"] = T("editor.canvas.term_cooperation"),
    ["流亡"] = T("editor.canvas.term_exile"),

    -- 卡牌操作（card 节点动作）
    ["抽取"] = T("editor.canvas.term_draw"),
    ["额外抽牌"] = T("editor.canvas.term_extra_draw"),
    ["复制"] = T("editor.canvas.term_copy"),
    ["弃掉"] = T("editor.canvas.term_discard_action"),
    ["弃牌"] = T("editor.canvas.term_discard_event"),
    ["选择"] = T("editor.canvas.term_pick"),
    ["爆牌"] = T("editor.canvas.term_burn"),
    ["洗切卡组"] = T("editor.canvas.term_shuffle_deck"),
    ["洗入"] = T("editor.canvas.term_shuffle_in"),

    -- 卡牌属性（card_stats 词汇表）
    ["攻击力"] = T("editor.canvas.term_attack_stat"),
    ["防御力"] = T("editor.canvas.term_defense_stat"),
    ["防御"] = T("editor.canvas.term_defense"),
    ["最大防御力"] = T("editor.canvas.term_max_defense"),
    ["行动花费"] = T("editor.canvas.term_action_cost"),
    ["费用"] = T("editor.canvas.term_cost"),
    ["花费"] = T("editor.canvas.term_play_cost"),

    -- 通用操作词（多节点共用，便于区分近义/动词搭配）
    ["获得"] = T("editor.canvas.term_gain"),
    ["受到"] = T("editor.canvas.term_take"),
    ["设为"] = T("editor.canvas.term_set"),
    ["增加"] = T("editor.canvas.term_increase"),
    ["减少"] = T("editor.canvas.term_decrease"),
    ["任意"] = T("editor.canvas.term_any"),

    -- 回合相关（turn 节点）
    ["回合"] = T("editor.canvas.term_turn"),
    ["回合开始"] = T("editor.canvas.term_turn_start"),
    ["回合结束"] = T("editor.canvas.term_turn_end"),
    ["跳过回合"] = T("editor.canvas.term_skip_turn"),
    ["等待"] = T("editor.canvas.term_wait"),
    ["使"] = T("editor.canvas.term_make"),

    -- 事件监测（event_monitor 节点）
    ["有变化的"] = T("editor.canvas.term_changed"),
    ["属性"] = T("editor.canvas.term_stats"),
    ["攻防"] = T("editor.canvas.term_attack_defense"),
    ["的值"] = T("editor.canvas.term_value_of"),
    ["增加了"] = T("editor.canvas.term_increased"),
    ["减少了"] = T("editor.canvas.term_decreased"),
    ["为"] = T("editor.canvas.term_equals"),
    ["时：触发情报"] = T("editor.canvas.term_on_intel"),
    ["总部防御力"] = T("editor.canvas.term_hq_defense"),

    -- 目标选择（target_selector 节点）
    ["指向"] = T("editor.canvas.term_point"),
    ["指定"] = T("editor.canvas.term_choose"),
    ["随机"] = T("editor.canvas.term_random"),
    ["场上"] = T("editor.canvas.term_battlefield"),
    ["属性最高"] = T("editor.canvas.term_highest_stat"),
    ["属性最低"] = T("editor.canvas.term_lowest_stat"),

    -- 注册钩子（register_hook 节点）
    ["作用域"] = T("editor.canvas.term_scope"),
    ["存活在场"] = T("editor.canvas.term_while_in_play"),
    ["永久"] = T("editor.canvas.term_permanent"),
    ["总是触发"] = T("editor.canvas.term_always_trigger"),
    ["条件触发"] = T("editor.canvas.term_conditional_trigger"),
    ["部署单位"] = T("editor.canvas.term_unit_deployed"),
    ["打出指令"] = T("editor.canvas.term_command_played"),

    -- 触发函数（trigger_function 节点）
    ["触发一次"] = T("editor.canvas.term_trigger_once"),
    ["保持触发"] = T("editor.canvas.term_keep_triggering"),
    ["停止保持触发"] = T("editor.canvas.term_stop_triggering"),
    ["拦截一次"] = T("editor.canvas.term_intercept_once"),
    ["保持拦截"] = T("editor.canvas.term_keep_intercepting"),
    ["效果图标"] = T("editor.canvas.term_effect_icon"),
    ["主动效果"] = T("editor.canvas.term_active_effect"),

    -- 其余节点专用词
    ["随机排列"] = T("editor.canvas.term_randomize_order"),
    ["判断数量"] = T("editor.canvas.term_count_check"),
    ["关键字检查"] = T("editor.canvas.term_keyword_check"),
    ["重复信号"] = T("editor.canvas.term_repeat_signal"),
    ["观星"] = T("editor.canvas.term_scry"),
}

--[[
    查找选项文本对应的术语悬停释义（依据 TermTooltips）。

    直接匹配选项内文字而非选项本身：
      1. 整词（全等）优先，命中即返回；
      2. 未命中时取选项文本内「长度最长」的包含术语；
      3. 长度相同时取文本中更靠后的术语（更接近名词主体）。

    @param text string 选项文本（可能带 $...$ 包裹）
    @return string|nil 释义文本（无匹配返回 nil）
]]
function KARDS.CardEditor.Canvas.LookupTermTooltip(text)
    if not text or text == "" then return nil end
    local t = text
    -- 去除 $...$ 包裹（卡牌对象模式选项显示用）
    if t:sub(1, 1) == "$" and t:sub(-1, -1) == "$" and #t >= 2 then
        t = t:sub(2, -2)
    end
    local map = KARDS.CardEditor.Canvas.TermTooltips
    local full = map[t]
    if full then return full end
    local bestLen, bestPos, bestDef = 0, -1, nil
    for term, def in pairs(map) do
        if #term >= 2 then
            local pos = t:find(term, 1, true)
            if pos and (#term > bestLen or (#term == bestLen and pos > bestPos)) then
                bestLen, bestPos, bestDef = #term, pos, def
            end
        end
    end
    return bestDef
end

-- 背景图片相关配置
KARDS.CardEditor.Canvas.BackgroundImageFolder = "materials/kards/editor_backgrounds/"
KARDS.CardEditor.Canvas.BackgroundImageList = {}
-- 为两个页面分别存储背景图片
KARDS.CardEditor.Canvas.SelectedBackgroundImages = {
    effect = nil,
    appearance = nil
}

-- 动态检测背景图片数量
function KARDS.CardEditor.Canvas.ScanBackgroundImages()
    KARDS.CardEditor.Canvas.BackgroundImageList = {}
    
    -- 首先添加默认的editor_background.png作为备选
    local defaultPath = "materials/kards/editor_background.png"
    local defaultMat = Material(defaultPath, "noclamp smooth")
    if defaultMat and not defaultMat:IsError() then
        table.insert(KARDS.CardEditor.Canvas.BackgroundImageList, defaultPath)
    end
    
    -- 扫描editor_backgrounds文件夹中的背景图片
    -- Garry's Mod中无法直接列出文件列表，所以我们尝试查找常用的命名模式
    -- 尝试查找editor_background_1.png, editor_background_2.png, ...直到找不到为止
    local i = 1
    while true do
        -- 首先尝试 .png 格式
        local bgPathPng = KARDS.CardEditor.Canvas.BackgroundImageFolder .. "editor_background_" .. i .. ".png"
        local bgMatPng = Material(bgPathPng, "noclamp smooth")
        if bgMatPng and not bgMatPng:IsError() then
            table.insert(KARDS.CardEditor.Canvas.BackgroundImageList, bgPathPng)
            i = i + 1
        else
            -- 如果 .png 不存在，尝试 .jpg 格式
            local bgPathJpg = KARDS.CardEditor.Canvas.BackgroundImageFolder .. "editor_background_" .. i .. ".jpg"
            local bgMatJpg = Material(bgPathJpg, "noclamp smooth")
            if bgMatJpg and not bgMatJpg:IsError() then
                table.insert(KARDS.CardEditor.Canvas.BackgroundImageList, bgPathJpg)
                i = i + 1
            else
                -- 如果都不存在，停止
                break
            end
        end
    end
    
    -- 如果没有找到任何背景图片，我们至少保持一个空列表，以后用户可以添加
    return KARDS.CardEditor.Canvas.BackgroundImageList
end

-- 随机选择背景图片 - 为两个页面分别选择不同的背景
function KARDS.CardEditor.Canvas.SelectRandomBackground()
    if #KARDS.CardEditor.Canvas.BackgroundImageList == 0 then
        KARDS.CardEditor.Canvas.ScanBackgroundImages()
    end
    
    if #KARDS.CardEditor.Canvas.BackgroundImageList > 0 then
        -- 为 effect 页面选择第一个背景
        local effectIndex = math.random(1, #KARDS.CardEditor.Canvas.BackgroundImageList)
        KARDS.CardEditor.Canvas.SelectedBackgroundImages.effect = KARDS.CardEditor.Canvas.BackgroundImageList[effectIndex]
        
        -- 为 appearance 页面选择不同的背景
        local appearanceIndex
        if #KARDS.CardEditor.Canvas.BackgroundImageList >= 2 then
            -- 如果有多个背景，确保和 effect 页面不同
            repeat
                appearanceIndex = math.random(1, #KARDS.CardEditor.Canvas.BackgroundImageList)
            until appearanceIndex ~= effectIndex
        else
            -- 如果只有一个背景，就用同一个
            appearanceIndex = effectIndex
        end
        KARDS.CardEditor.Canvas.SelectedBackgroundImages.appearance = KARDS.CardEditor.Canvas.BackgroundImageList[appearanceIndex]
    end
end

KARDS.CardEditor.Canvas.CardAppearance = {
    name = T("editor.canvas.new_card"),
    nameEn = "", -- 英文卡牌名称（语言为 en 时显示/编辑；为空回退 name）
    cost = 1,
    actionCost = 0,
    country = "SandBox",
    cardType = "infantry", -- "infantry", "tank", "artillery", "fighter", "bomber", "command", "counter_command", "headquarter"
    attack = 0,
    defense = 0,
    quality = "normal", -- "normal", "limited", "special", "elite"
    keywords = { "blitz", "impact" },
    keywordValues = { -- 存储带有数值的词条的值
        intel = 0,
        countdown = 0,
        heavy_armor = 0
    },
    specialEffect = "",
    specialEffectEn = "", -- 英文效果描述（语言为 en 时显示/编辑；为空回退 specialEffect）
    imagePath = "",
    cardTemplate = "card", -- "card", "flash", "custom"
    customTemplatePath = "",
    nameIsBlack = false, -- 卡牌名称是否为黑色
    nameFontSize = 36, -- 卡牌名称字体大小
    descFontSize = 20, -- 卡牌描述字体大小
    nameIsEnglish = false, -- 卡牌名称是否使用英文字体
    pincerValue = "", -- 钳击目标对象名称
    imageOffsetX = 0, -- 插图X偏移
    imageOffsetY = 0, -- 插图Y偏移
    imageScale = 1, -- 插图缩放大小
    effectPath = "", -- 效果函数路径（指向 effects/ 目录下的 INE 函数文件）
    
    -- 伤害倍率配置（亨舍尔 HS 129 等卡牌固有战斗属性）
    -- 结构: { outgoing = { { targetPath, multiplier, targetName } }, incoming = { { sourcePath, multiplier, sourceName } } }
    combatModifiers = {
        outgoing = {}, -- 输出倍率：该卡牌攻击匹配 targetPath 的目标时造成 ×N 伤害
        incoming = {}, -- 受伤倍率：该卡牌受到匹配 sourcePath 的来源伤害时 ×N
    },

    -- 规模（2026-08-14 接入战斗系统：决定放牌/部署音效分配，见 KARDS.CardSounds）
    cardScale = "small", -- "small" 少量 / "medium" 中量 / "large" 巨大
    sounds = {}, -- 事件音效路径表（音效选择器保存；deploy/attack/death/play/activate/trigger）
    
    -- 历史文献数据
    historyImagePath = "", -- 历史插图路径
    historyImageOffsetX = 0, -- 历史插图X偏移
    historyImageOffsetY = 0, -- 历史插图Y偏移
    historyImageScale = 1, -- 历史插图缩放
    historyText = "", -- 历史文献描述文本
    
    canElevateToVeteran = false, -- 是否可以升级为老兵
    convertTarget = "", -- 转换目标卡文件名（转换效果作用后变成哪张卡；空字符串表示不换卡）
    isDefault = false, -- 是否为默认卡牌（锁定后不可修改、不可删除；仅测试版可设置/解锁）
    veteranAppearance = { -- 老兵外观数据 - 当卡牌升级为老兵后使用的外观数据
        name = T("editor.canvas.new_veteran_card"), -- 老兵卡牌名称
        nameEn = "", -- 老兵英文卡牌名称（为空回退 name）
        cost = 1, -- 老兵卡牌费用
        actionCost = 0, -- 老兵行动费用
        attack = 0, -- 老兵攻击力
        defense = 0, -- 老兵防御力
        quality = "special", -- 老兵品质
        keywords = { "veteran" }, -- 老兵词条列表
        keywordValues = { -- 老兵词条数值
            intel = 0, -- 情报数值
            countdown = 0, -- 倒计时数值
            heavy_armor = 0 -- 重甲数值
        },
        specialEffect = "", -- 老兵特殊效果描述
        specialEffectEn = "", -- 老兵英文效果描述（为空回退 specialEffect）
        imagePath = "", -- 老兵插图路径
        cardTemplate = "card", -- 老兵使用的卡牌模板
        customTemplatePath = "", -- 老兵自定义模板路径
        nameIsBlack = false, -- 老兵名称是否为黑色
        nameFontSize = 36, -- 老兵名称字体大小
        descFontSize = 20, -- 老兵描述字体大小
        nameIsEnglish = false, -- 老兵名称是否使用英文字体
        imageOffsetX = 0, -- 老兵插图X偏移
        imageOffsetY = 0, -- 老兵插图Y偏移
        imageScale = 1 -- 老兵插图缩放大小
    }
}

-- 字体大小离散值列表
KARDS.CardEditor.Canvas.FontSizes = {12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72}
-- Dday字体大小列表
KARDS.CardEditor.Canvas.DdayFontSizes = {12, 18, 24, 36, 48, 64, 72}

-- ============ 属性编辑区状态数据 ============
-- 攻击力 DTextEntry 状态（透明输入框用于 IME/键盘输入）
KARDS.CardEditor.Canvas._attrInputState = {
    active = false,
    text = "",
    lastValidValue = 0, -- 上次有效值，用于非数字输入回退
}
KARDS.CardEditor.Canvas._attrTextEntry = nil

-- 攻击力滑动进度条拖拽状态
KARDS.CardEditor.Canvas._attackSliderState = {
    isDragging = false,       -- 是否正在拖拽
    dragStartX = 0,            -- 拖拽起始屏幕X
    dragValueAtStart = 0,      -- 拖拽起始时的值
    displayMin = 0,            -- 当前可见范围最小值
    displayMax = 10,           -- 当前可见范围最大值
    animating = false,         -- 是否正在进行数轴平移动画
    animStartTime = 0,         -- 动画开始时间
    animDuration = 0.3,        -- 动画持续时间（秒）
    animDisplayMinFrom = 0,    -- 动画起始 displayMin
    animDisplayMaxFrom = 0,    -- 动画起始 displayMax
    animDisplayMinTo = 0,      -- 动画目标 displayMin
    animDisplayMaxTo = 0,      -- 动画目标 displayMax
    prevLeft = false,          -- 帧追踪：上一帧左键状态
}

-- 防御力 DTextEntry 状态
KARDS.CardEditor.Canvas._defenseInputState = {
    active = false,
    text = "",
    lastValidValue = 0,
}
KARDS.CardEditor.Canvas._defenseTextEntry = nil

-- 防御力滑动进度条拖拽状态
KARDS.CardEditor.Canvas._defenseSliderState = {
    isDragging = false,
    dragStartX = 0,
    dragValueAtStart = 0,
    displayMin = 0,
    displayMax = 10,
    animating = false,
    animStartTime = 0,
    animDuration = 0.3,
    animDisplayMinFrom = 0,
    animDisplayMaxFrom = 0,
    animDisplayMinTo = 0,
    animDisplayMaxTo = 0,
    prevLeft = false,
}

-- 设置花费 DTextEntry 状态
KARDS.CardEditor.Canvas._costInputState = {
    active = false,
    text = "",
    lastValidValue = 0,
}
KARDS.CardEditor.Canvas._costTextEntry = nil

-- 设置花费滑动进度条拖拽状态
KARDS.CardEditor.Canvas._costSliderState = {
    isDragging = false,
    dragStartX = 0,
    dragValueAtStart = 0,
    displayMin = 0,
    displayMax = 10,
    animating = false,
    animStartTime = 0,
    animDuration = 0.3,
    animDisplayMinFrom = 0,
    animDisplayMaxFrom = 0,
    animDisplayMinTo = 0,
    animDisplayMaxTo = 0,
    prevLeft = false,
}

-- 行动花费 DTextEntry 状态
KARDS.CardEditor.Canvas._actionCostInputState = {
    active = false,
    text = "",
    lastValidValue = 0,
}
KARDS.CardEditor.Canvas._actionCostTextEntry = nil

-- 行动花费滑动进度条拖拽状态
KARDS.CardEditor.Canvas._actionCostSliderState = {
    isDragging = false,
    dragStartX = 0,
    dragValueAtStart = 0,
    displayMin = 0,
    displayMax = 10,
    animating = false,
    animStartTime = 0,
    animDuration = 0.3,
    animDisplayMinFrom = 0,
    animDisplayMaxFrom = 0,
    animDisplayMinTo = 0,
    animDisplayMaxTo = 0,
    prevLeft = false,
}

-- ============ 老兵属性编辑区状态数据 ============
-- 老兵攻击力 DTextEntry 状态
KARDS.CardEditor.Canvas._vetAttrInputState = {
    active = false,
    text = "",
    lastValidValue = 0,
}
KARDS.CardEditor.Canvas._vetAttrTextEntry = nil

-- 老兵攻击力滑动进度条拖拽状态
KARDS.CardEditor.Canvas._vetAttackSliderState = {
    isDragging = false,
    dragStartX = 0,
    dragValueAtStart = 0,
    displayMin = 0,
    displayMax = 10,
    animating = false,
    animStartTime = 0,
    animDuration = 0.3,
    animDisplayMinFrom = 0,
    animDisplayMaxFrom = 0,
    animDisplayMinTo = 0,
    animDisplayMaxTo = 0,
    prevLeft = false,
}

-- 老兵防御力 DTextEntry 状态
KARDS.CardEditor.Canvas._vetDefenseInputState = {
    active = false,
    text = "",
    lastValidValue = 0,
}
KARDS.CardEditor.Canvas._vetDefenseTextEntry = nil

-- 老兵防御力滑动进度条拖拽状态
KARDS.CardEditor.Canvas._vetDefenseSliderState = {
    isDragging = false,
    dragStartX = 0,
    dragValueAtStart = 0,
    displayMin = 0,
    displayMax = 10,
    animating = false,
    animStartTime = 0,
    animDuration = 0.3,
    animDisplayMinFrom = 0,
    animDisplayMaxFrom = 0,
    animDisplayMinTo = 0,
    animDisplayMaxTo = 0,
    prevLeft = false,
}

-- 老兵行动花费 DTextEntry 状态
KARDS.CardEditor.Canvas._vetActionCostInputState = {
    active = false,
    text = "",
    lastValidValue = 0,
}
KARDS.CardEditor.Canvas._vetActionCostTextEntry = nil

-- 老兵行动花费滑动进度条拖拽状态
KARDS.CardEditor.Canvas._vetActionCostSliderState = {
    isDragging = false,
    dragStartX = 0,
    dragValueAtStart = 0,
    displayMin = 0,
    displayMax = 10,
    animating = false,
    animStartTime = 0,
    animDuration = 0.3,
    animDisplayMinFrom = 0,
    animDisplayMaxFrom = 0,
    animDisplayMinTo = 0,
    animDisplayMaxTo = 0,
    prevLeft = false,
}

-- 转换目标卡下拉列表状态（2026-09-26 缺口 J）
KARDS.CardEditor.Canvas._convertTargetExpanded = false -- 列表是否展开
KARDS.CardEditor.Canvas._convertTargetList = {}       -- 缓存的卡牌文件列表（展开时刷新）
KARDS.CardEditor.Canvas._convertTargetScroll = 0      -- 列表滚动偏移（条目数）

-- 插图 URL 输入框状态
KARDS.CardEditor.Canvas._urlInputState = {
    active = false,
    text = "",
}
KARDS.CardEditor.Canvas._urlTextEntry = nil

-- 图片下载状态
KARDS.CardEditor.Canvas._imageDownloadState = {
    status = "idle",        -- "idle" | "downloading" | "success" | "error"
    errorMsg = "",
    downloadedPath = "",
}

-- 插图拖拽状态
KARDS.CardEditor.Canvas._imageDragState = {
    isDragging = false,
    dragStartMX = 0,
    dragStartMY = 0,
    dragStartOffsetX = 0,
    dragStartOffsetY = 0,
}

-- 本地图片列表状态
KARDS.CardEditor.Canvas._localImageState = {
    files = {},
}

-- 历史文献输入框状态
KARDS.CardEditor.Canvas._historyInputState = {
    active = false,
    text = "",
    scrollY = 0,      -- 滚动偏移
    lineHeight = 20,   -- 行高
    maxHeight = 0,     -- 最大高度（触底后启用滚动时记录）
    lastActive = false,
}
KARDS.CardEditor.Canvas._historyTextEntry = nil
-- 历史插图拖拽状态（左侧编辑预览区）
KARDS.CardEditor.Canvas._historyEditDragState = {
    isDragging = false,
    dragStartMX = 0,
    dragStartMY = 0,
    dragStartOffsetX = 0,
    dragStartOffsetY = 0,
}
-- 历史插图拖拽状态（右侧展示区）
KARDS.CardEditor.Canvas._historyDisplayDragState = {
    isDragging = false,
    dragStartMX = 0,
    dragStartMY = 0,
    dragStartOffsetX = 0,
    dragStartOffsetY = 0,
}
-- 历史页 URL 输入状态
KARDS.CardEditor.Canvas._historyUrlInputState = {
    active = false,
    text = "",
    caretPos = nil,
}
-- 进入历史页时自动扫描历史图片的标记
KARDS.CardEditor.Canvas._historyAutoScanned = false

-- ============ 书签系统数据 ============
KARDS.CardEditor.Canvas.Bookmarks = {
    { id = "type",    shortName = T("editor.canvas.bookmark_type"), fullName = T("editor.canvas.bookmark_type_full"), color = Color(80, 140, 200) },
    { id = "attr",    shortName = T("editor.canvas.bookmark_attr"), fullName = T("editor.canvas.bookmark_attr_full"), color = Color(180, 120, 60) },
    { id = "country", shortName = T("editor.canvas.bookmark_country"), fullName = T("editor.canvas.bookmark_country_full"), color = Color(60, 160, 100) },
    { id = "keywords", shortName = T("editor.canvas.bookmark_keywords"), fullName = T("editor.canvas.bookmark_keywords_full"), color = Color(200, 150, 50) },
    { id = "description", shortName = T("editor.canvas.bookmark_description"), fullName = T("editor.canvas.bookmark_description_full"), color = Color(100, 150, 200) },
    { id = "illustration", shortName = T("editor.canvas.bookmark_illustration"), fullName = T("editor.canvas.bookmark_illustration_full"), color = Color(160, 100, 180) },
    { id = "history",  shortName = T("editor.canvas.bookmark_history"), fullName = T("editor.canvas.bookmark_history_full"), color = Color(140, 110, 80) },
    { id = "rarity",  shortName = T("editor.canvas.bookmark_rarity"), fullName = T("editor.canvas.bookmark_rarity_full"), color = Color(200, 180, 60) },
    { id = "damage",  shortName = T("editor.canvas.bookmark_damage"), fullName = T("editor.canvas.bookmark_damage_full"), color = Color(200, 90, 90) },
    { id = "manage",  shortName = T("editor.canvas.bookmark_manage"), fullName = T("editor.canvas.bookmark_manage_full"), color = Color(120, 120, 120) },
}
KARDS.CardEditor.Canvas.SelectedBookmark = "type"
-- 每个书签的动画状态（由 DrawCardAppearanceEditor 每帧更新）
KARDS.CardEditor.Canvas.BookmarkAnimStates = {}

-- 建议提示台文本
KARDS.CardEditor.Canvas.SuggestionText = ""

-- 规模选项数据（块单选使用）
KARDS.CardEditor.Canvas.CardScaleOptions = {
    { id = "small",  name = T("editor.canvas.scale_small"), desc = T("editor.canvas.scale_small_desc") },
    { id = "medium", name = T("editor.canvas.scale_medium"), desc = T("editor.canvas.scale_medium_desc") },
    { id = "large",  name = T("editor.canvas.scale_large"), desc = T("editor.canvas.scale_large_desc") },
}
KARDS.CardEditor.Canvas.SelectedCardScale = "small"

-- 效果/音效/子类型文件树（BuildEffectFileTree / BuildSoundFileTree / BuildSubtypeFileTree）已拆分至 effect_editor/cl_ca_file_manager.lua

-- 子类型文件管理器状态
KARDS.CardEditor.Canvas.SubtypeFileState = KARDS.CardEditor.Canvas.SubtypeFileState or {
    navStack = {},
    selectedEntry = nil,
    showConfirm = false,
    animOffset = 0,
    showOverlay = false,
    isSelectingSubtype = false,  -- 是否在子类型选择模式
    subtypeOptions = nil,        -- 从 lua 文件读取的子类型列表
    selectedSubtype = nil,       -- 选中的子类型名称
}

-- 闪卡开关状态
KARDS.CardEditor.Canvas.FlashCardToggle = KARDS.CardEditor.Canvas.FlashCardToggle or {
    isOn = false,
    anim = 1.0,
    isPressed = false,
    lastLeft = false,
}

-- 图片路径常量定义
KARDS.CardEditor.Canvas.ImagePaths = {
    -- 卡牌类型图标
    cardType = {
        infantry = "materials/kards/icons/cardtype_infantry.png",
        tank = "materials/kards/icons/cardtype_tank.png",
        artillery = "materials/kards/icons/cardtype_artillery.png",
        fighter = "materials/kards/icons/cardtype_fighter.png",
        bomber = "materials/kards/icons/cardtype_bomber.png",
        command = "materials/kards/icons/cardtype_command.png",
        counter_command = "materials/kards/icons/cardtype_counter_command.png"
    },
    -- 卡牌模板路径（根据cardType和cardTemplate组合）
    template = {
        -- 卡牌模板（card）
        card_infantry = "materials/kards/templates/card/unit_infantry_tank/infantry.png",
        card_tank = "materials/kards/templates/card/unit_infantry_tank/tank.png",
        card_artillery = "materials/kards/templates/card/unit_artillery_fighter_bomber/artillery.png",
        card_fighter = "materials/kards/templates/card/unit_artillery_fighter_bomber/fighter.png",
        card_bomber = "materials/kards/templates/card/unit_artillery_fighter_bomber/bomber.png",
        card_command = "materials/kards/templates/card/command/command.png",
        card_headquarter = "materials/kards/templates/card/headquarter/headquarter.png",
        card_counter_command = "materials/kards/templates/card/counter_command/counter_command.png",
        -- 闪卡模板（flash）
        flash_infantry = "materials/kards/templates/flash/unit_infantry_tank/infantry.png",
        flash_tank = "materials/kards/templates/flash/unit_infantry_tank/tank.png",
        flash_artillery = "materials/kards/templates/flash/unit_artillery_fighter_bomber/artillery.png",
        flash_fighter = "materials/kards/templates/flash/unit_artillery_fighter_bomber/fighter.png",
        flash_bomber = "materials/kards/templates/flash/unit_artillery_fighter_bomber/bomber.png",
        flash_command = "materials/kards/templates/flash/command/command.png",
        flash_counter_command = "materials/kards/templates/flash/counter_command/counter_command.png",
        -- 自定义模板
        custom = "materials/kards/templates/custom/custom.png"
    },
    -- 品质图标
    quality = {
        normal = "materials/kards/icons/quality_normal.png",
        limited = "materials/kards/icons/quality_limited.png",
        special = "materials/kards/icons/quality_special.png",
        elite = "materials/kards/icons/quality_elite.png"
    },
    -- 所属国图标
    country = {
        sandbox = "materials/kards/icons/country_sandbox.png",
        uk = "materials/kards/icons/country_uk.png",
        usa = "materials/kards/icons/country_usa.png",
        ussr = "materials/kards/icons/country_ussr.png",
        japan = "materials/kards/icons/country_japan.png",
        germany = "materials/kards/icons/country_germany.png"
    },
    -- 词条图标
    keyword = {
        blitz = "materials/kards/icons/keyword_blitz.png",
        impact = "materials/kards/icons/keyword_impact.png"
    }
}

-- ===== 关于页 BGM（2026-10-05）=====
-- 进入关于页时把编辑器 BGM 切到英国「Rule Bridiana」（发布视频的背景音乐），离开时恢复到
-- 进入前的国家风格。挂在 DrawEditor 每帧对账当前页，故标签点击、读档、选卡等所有进入路径
-- 都能覆盖；OpenEditor / CloseEditor 重置状态，避免跨会话残留。
KARDS.CardEditor.Canvas.AboutBGM = {
    active = false,               -- 是否处于「关于页 BGM」状态
    prevCountry = nil,            -- 进入关于页前的 BGM 国家（离开时恢复）
    country = "uk",               -- 关于页 BGM 国家
    trackName = "Rule Bridiana",  -- 曲名（文件名 <序号>.<音乐名>.ogg 中的音乐名）
}

function KARDS.CardEditor.Canvas.SyncAboutPageBGM(page)
    local about = KARDS.CardEditor.Canvas.AboutBGM
    local compat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
    if page == "about" then
        if about.active or not compat then return end
        about.active = true
        about.prevCountry = compat.CurrentCountry
        -- 按曲名定位英国曲目；找不到则退回该国家默认曲目
        local idx
        local data = compat.CountryMusic and compat.CountryMusic[about.country]
        if data and data.tracks then
            for i, t in ipairs(data.tracks) do
                if t.name and t.name:lower():find(about.trackName:lower(), 1, true) then
                    idx = i
                    break
                end
            end
        end
        if not (idx and compat.PlaySpecificTrack(about.country, idx)) then
            compat.SelectCountry(about.country)
        end
    elseif about.active then
        about.active = false
        if compat and about.prevCountry then
            compat.SelectCountry(about.prevCountry)
        end
        about.prevCountry = nil
    end
end

function KARDS.CardEditor.Canvas.OpenEditor()
    if KARDS.CardEditor.Canvas.Enabled then return end

    KARDS.CardEditor.Canvas.Enabled = true
    KARDS.CardEditor.Canvas.CreateRootPanel()
    KARDS.CardEditor.Canvas.CreateControls()
    KARDS.CardEditor.Canvas.AddHUDHook()

    -- 根据当前卡牌类型设置编辑器模式
    KARDS.CardEditor.Canvas.UpdateEditorModeFromCardType()

    -- 随机选择背景图片
    KARDS.CardEditor.Canvas.SelectRandomBackground()

    -- 播放打开编辑器音效
    KARDS.CardEditor.Audio.PlayOpen()

    -- 与 dynamic_BGM 兼容：淡出背景音乐并加载编辑器轨道
    if KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM then
        KARDS.CardEditor.Compat.DynamicBGM.FadeOut()
    end

    -- 随机选择一个国家风格的编辑器背景音乐（纯氛围，独立于卡牌国家书签，不弹通知）
    -- 国家候选来自 BGM 兼容模块的自动登记结果（sound/editor/ 扫描），新增国家无需改代码
    local bgmCompat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
    local countryOptions = bgmCompat and bgmCompat.GetAvailableCountries() or nil
    if not countryOptions or #countryOptions == 0 then
        -- 兜底：预设国家列表（仅当扫描未发现任何曲目时使用）
        countryOptions = {"uk", "usa", "ussr", "japan", "germany"}
    end
    KARDS.CardEditor.Canvas.SelectEditorBGM(countryOptions[math.random(1, #countryOptions)], false)

    if IsValid(KARDS.CardEditor.Canvas.RootPanel) then
        KARDS.CardEditor.Canvas.RootPanel:SetVisible(true)
    end

    -- 启用外貌编辑器，默认显示外貌编辑界面
    KARDS.CardEditor.Canvas.CurrentPage = "appearance"
    -- 重置关于页 BGM 状态（清除上次会话残留的恢复目标）
    KARDS.CardEditor.Canvas.AboutBGM.active = false
    KARDS.CardEditor.Canvas.AboutBGM.prevCountry = nil
    gui.EnableScreenClicker(false)

    -- 启动背景音效
    KARDS.CardEditor.Audio.StartBackgroundMusic()

    -- 编辑器待机动画已停用：打开编辑器时不再自动请求服务端播放。
    -- 需要单独验证动画时，可在控制台手动执行 kards_start_editor_anim。
    -- RunConsoleCommand("kards_start_editor_anim")

    -- 触发编辑器打开事件
    hook.Run("KARDS_EditorOpened")
end

function KARDS.CardEditor.Canvas.CloseEditor()
    if not KARDS.CardEditor.Canvas.Enabled then return end

    KARDS.CardEditor.Canvas.Enabled = false
    KARDS.CardEditor.Canvas.RemoveControls()
    -- 重置关于页 BGM 状态（不在此恢复，编辑器轨道由 KARDS_EditorClosed 钩子统一停止）
    KARDS.CardEditor.Canvas.AboutBGM.active = false
    KARDS.CardEditor.Canvas.AboutBGM.prevCountry = nil

    -- 与 dynamic_BGM 兼容：淡入恢复背景音乐
    if KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM then
        KARDS.CardEditor.Compat.DynamicBGM.FadeIn()
    end

    -- 停止背景音效
    KARDS.CardEditor.Audio.StopBackgroundMusic()

    -- 停止音效试听（2026-08-13：退出编辑器时若有预览音频需立即停止，BGM 音量渐变还原）
    if KARDS.CardEditor.Audio.StopPreviewSound then
        KARDS.CardEditor.Audio.StopPreviewSound()
    end

    -- 清理 F2 音效命名输入框 DTextEntry（已封装到 cl_ca_file_manager.lua，2026-10-04 拆分）
    if KARDS.CardEditor.Canvas.CleanupRenameInput then
        KARDS.CardEditor.Canvas.CleanupRenameInput()
    end

    if IsValid(KARDS.CardEditor.Canvas.RootPanel) then
        KARDS.CardEditor.Canvas.RootPanel:SetVisible(false)
    end
    gui.EnableScreenClicker(false)

    -- 清理描述输入框 DTextEntry
    local descEntry = KARDS.CardEditor.Canvas._descTextEntry
    if descEntry and IsValid(descEntry) then
        descEntry:Remove()
    end
    KARDS.CardEditor.Canvas._descTextEntry = nil
    KARDS.CardEditor.Canvas._descInputState = nil

    -- 清理插图 URL 输入框 DTextEntry
    local urlEntry = KARDS.CardEditor.Canvas._urlTextEntry
    if urlEntry and IsValid(urlEntry) then
        urlEntry:Remove()
    end
    KARDS.CardEditor.Canvas._urlTextEntry = nil
    KARDS.CardEditor.Canvas._urlInputState = nil

    -- 清理历史文献输入框 DTextEntry 并重置状态
    local historyEntry = KARDS.CardEditor.Canvas._historyTextEntry
    if historyEntry and IsValid(historyEntry) then
        historyEntry:Remove()
    end
    KARDS.CardEditor.Canvas._historyTextEntry = nil
    KARDS.CardEditor.Canvas._historyInputState = {
        active = false,
        text = "",
        scrollY = 0,
        lineHeight = 20,
        maxHeight = 0,
        lastActive = false,
    }

    -- 清理历史 URL 输入框 DTextEntry
    local hisUrlEntry = KARDS.CardEditor.Canvas._historyUrlTextEntry
    if hisUrlEntry and IsValid(hisUrlEntry) then
        hisUrlEntry:Remove()
    end
    KARDS.CardEditor.Canvas._historyUrlTextEntry = nil
    KARDS.CardEditor.Canvas._historyUrlInputState = nil

    -- 关闭卡牌编辑器时同时隐藏嵌入的 INE 节点编辑器，避免其继续通过 HUDPaint 绘制
    if SetNodeEditorHidden then
        SetNodeEditorHidden("card_effect_editor", true)
    end

    KARDS.CardEditor.Canvas.Nodes = {}
    KARDS.CardEditor.Canvas.Connections = {}
    KARDS.CardEditor.Canvas.NodeCounter = 0
    KARDS.CardEditor.Canvas.ConnectionCounter = 0
    KARDS.CardEditor.Canvas.TempNode = nil
    KARDS.CardEditor.Canvas.TempConnection = nil
    KARDS.CardEditor.Canvas.DraggingNode = nil
    KARDS.CardEditor.Canvas.HoveredConnection = nil

    -- 停止编辑器动画（除非保持动画标志为 true）
    if KARDS.CardEditor.Animation and KARDS.CardEditor.Animation.Client and not KARDS.CardEditor.Animation.Client.KeepAnimation then
        RunConsoleCommand("kards_stop_editor_anim")
    elseif KARDS.CardEditor.Animation and KARDS.CardEditor.Animation.Client then
        -- 重置保持动画标志
        KARDS.CardEditor.Animation.Client.KeepAnimation = false
    end

    -- 触发编辑器关闭事件
    hook.Run("KARDS_EditorClosed")
end

function KARDS.CardEditor.Canvas.ToggleEditor()
    if KARDS.CardEditor.Canvas.Enabled then
        KARDS.CardEditor.Canvas.CloseEditor()
    else
        KARDS.CardEditor.Canvas.OpenEditor()
    end
end

function KARDS.CardEditor.Canvas.CreateRootPanel()
    -- 先移除旧的面板
    if IsValid(KARDS.CardEditor.Canvas.RootPanel) then
        KARDS.CardEditor.Canvas.RootPanel:Remove()
    end
    
    -- 创建新的面板，使用不同的方式确保输入处理
    local root = vgui.Create("EditablePanel", GetHUDPanel())
    root:SetSize(ScrW(), ScrH())
    root:SetPos(0, 0)
    root:SetZPos(0)
    root:SetKeyboardInputEnabled(true)
    root:SetMouseInputEnabled(true)
    root:MakePopup() -- 确保面板获得焦点并接收键盘输入
    root:SetVisible(false)
    
    root.Paint = function(self, w, h)
        -- 空绘制函数，让 VGUI 处理自己的绘制
    end
    
    root.OnMousePressed = function(self, keyCode)
        -- 交互已移至自定义绘制
    end

    KARDS.CardEditor.Canvas.RootPanel = root
end

function KARDS.CardEditor.Canvas.AddHUDHook()
    if KARDS.CardEditor.Canvas.HUDHookAdded then return end
    KARDS.CardEditor.Canvas.HUDHookAdded = true
    hook.Add("HUDPaint", "KARDS_CanvasEditor_Draw", function()
        if KARDS.CardEditor.Canvas.Enabled then
            KARDS.CardEditor.Canvas.DrawEditor()
        end
    end)
end

-- 选择卡牌所属国家（外貌编辑器「国家」书签用）：只更新卡牌数据与 UI 状态，不触发背景音乐切换
function KARDS.CardEditor.Canvas.SelectCountry(countryId)
    if KARDS.CardEditor.Canvas.SelectedCountry == countryId then
        return
    end

    KARDS.CardEditor.Canvas.SelectedCountry = countryId

    -- 写回卡牌数据（卡背材质/保存/渲染使用所选国家）
    local app = KARDS.CardEditor.Canvas.CardAppearance
    if app then
        app.country = countryId
    end
end

-- 选择编辑器 BGM 国家风格（顶栏常驻国旗按钮用）：仅切换背景音乐，不改变卡牌国家
function KARDS.CardEditor.Canvas.SelectEditorBGM(countryId, showNotify)
    -- 先通过兼容性模块播放国家音乐（同步解析出即将播放的曲名）
    local bgmCompat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
    if bgmCompat then
        bgmCompat.SelectCountry(countryId)
    end

    -- 显示通知
    if showNotify ~= false then
        KARDS.CardEditor.Canvas.NotifyBGMPlaying(countryId)
    end
end

-- 显示 BGM 播放/停止通知（顶栏风格选择与曲目列表面板点选共用）
function KARDS.CardEditor.Canvas.NotifyBGMPlaying(countryId)
    local bgmCompat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM

    -- 播放选择音效
    surface.PlaySound("editor/chooseBGM.wav")

    local countryNames = {
        none = T("editor.canvas.country_none"),
        uk = T("editor.canvas.country_uk"),
        usa = T("editor.canvas.country_usa"),
        ussr = T("editor.canvas.country_ussr"),
        japan = T("editor.canvas.country_japan"),
        germany = T("editor.canvas.country_germany")
    }
    -- 展开的扩展国家名称并入通知映射
    for _, c in ipairs(KARDS.CardEditor.Canvas.BGMExpandCountries) do
        countryNames[c.id] = c.name
    end
    if countryId == "none" then
        KARDS.CardEditor.Canvas.AddNotification(T("editor.canvas.bgm_stopped"), Color(120, 120, 120), true)
    else
        local countryName = countryNames[countryId] or countryId
        -- 优先展示曲名：正在播放：<国家>：<曲名>（曲名来自文件名 <序号>.<音乐名>.ogg）
        local trackName = bgmCompat and bgmCompat.CurrentTrackName or nil
        if trackName then
            KARDS.CardEditor.Canvas.AddNotification(T("editor.canvas.bgm_now_playing", countryName, trackName), Color(80, 150, 250), true)
        else
            KARDS.CardEditor.Canvas.AddNotification(T("editor.canvas.bgm_playing_music", countryName), Color(80, 150, 250), true)
        end
        -- BGM 专属提示（右下角"播放：风格：名称"）——与通用通知并用
        if bgmCompat and bgmCompat.ShowBGMMessage then
            bgmCompat.ShowBGMMessage(T("editor.canvas.bgm_style_track", countryName, trackName or T("editor.canvas.music")), "play")
        end
    end
end

-- BGM 扩展国家菜单与曲目列表（ToggleBGMMenu / OpenBGMMenu / OpenBGMPlaylist 等）已拆分至 effect_editor/cl_ca_bgm_menu.lua

-- 移除所有已创建的控件（简化版，仅保留实际创建的控件）
function KARDS.CardEditor.Canvas.RemoveControls()
    -- 先关闭展开 BGM 菜单并清理其面板
    KARDS.CardEditor.Canvas.CloseBGMMenu()
    KARDS.CardEditor.Canvas.CloseBGMPlaylist()

    if IsValid(KARDS.CardEditor.Canvas.CloseButton) then
        KARDS.CardEditor.Canvas.CloseButton:Remove()
        KARDS.CardEditor.Canvas.CloseButton = nil
    end
    if IsValid(KARDS.CardEditor.Canvas.MinButton) then
        KARDS.CardEditor.Canvas.MinButton:Remove()
        KARDS.CardEditor.Canvas.MinButton = nil
    end
    -- 移除国家按钮
    if KARDS.CardEditor.Canvas.CountryButtons then
        for _, btn in ipairs(KARDS.CardEditor.Canvas.CountryButtons) do
            if IsValid(btn) then
                btn:Remove()
            end
        end
        KARDS.CardEditor.Canvas.CountryButtons = nil
    end
    -- 移除所有 DTextEntry 和 DNumberWang 输入控件
    local inputControls = {
        "NameInput", "CostInput", "ActionCostInput", "AttackInput", "DefenseInput",
        "ImagePathInput", "CustomTemplatePathInput",
        "IntelNumber", "CountdownNumber", "HeavyArmorNumber",
    }
    for _, name in ipairs(inputControls) do
        if IsValid(KARDS.CardEditor.Canvas[name]) then
            KARDS.CardEditor.Canvas[name]:Remove()
            KARDS.CardEditor.Canvas[name] = nil
        end
    end
    -- 移除切换按钮
    if IsValid(KARDS.CardEditor.Canvas.ToggleAppearanceDButton) then
        KARDS.CardEditor.Canvas.ToggleAppearanceDButton:Remove()
        KARDS.CardEditor.Canvas.ToggleAppearanceDButton = nil
    end
end

function KARDS.CardEditor.Canvas.UpdateControlPositions()
    local win = KARDS.CardEditor.Canvas.Window

    -- 仅保留关闭/最小化按钮和国旗按钮位置更新
    if IsValid(KARDS.CardEditor.Canvas.CloseButton) then
        KARDS.CardEditor.Canvas.CloseButton:SetPos(win.x + win.width - 35, win.y + 5)
    end
    if IsValid(KARDS.CardEditor.Canvas.MinButton) then
        KARDS.CardEditor.Canvas.MinButton:SetPos(win.x + win.width - 70, win.y + 5)
    end

    -- 国旗按钮位置更新（主行 = 扩展按钮 + 关闭音乐 + 5 个原有国家，共 7 个）
    local mainRowCount = 7
    local countryBtnSize = 30
    local countryBtnSpacing = 6
    local closeBtnX = win.x + win.width - 35
    local totalCountryWidth = mainRowCount * countryBtnSize + (mainRowCount - 1) * countryBtnSpacing
    local countryBtnStartX = closeBtnX - totalCountryWidth - 15
    local countryBtnY = win.y + 40 + (30 - countryBtnSize) / 2
    for i, btn in ipairs(KARDS.CardEditor.Canvas.CountryButtons or {}) do
        if IsValid(btn) then
            btn:SetPos(countryBtnStartX + (i - 1) * (countryBtnSize + countryBtnSpacing), countryBtnY)
        end
    end

    -- 所有外观编辑器控件（DTextEntry/DNumberWang）现在由 DrawCardAppearanceEditor 管理位置
    -- 旧的 DCheckBox/DLabel/DNumSlider 已不在 CreateControls 中创建
end

-- 背景图材质缓存：[图片路径] = Material。
-- DrawEditor 每帧为当前页取一次背景材质，成功结果缓存后不再重复查找与 IsError 检查；
-- 加载失败时不缓存，保留原有的每帧重试行为（背景图片可能在运行期才可用）。
local bgMaterialCache = {}

local function GetBackgroundMaterial(imagePath)
    local mat = bgMaterialCache[imagePath]
    if mat then return mat end

    mat = Material(imagePath, "noclamp smooth")
    if mat and not mat:IsError() then
        bgMaterialCache[imagePath] = mat
    else
        mat = nil
    end
    return mat
end

function KARDS.CardEditor.Canvas.DrawEditor()
    local win = KARDS.CardEditor.Canvas.Window
    -- 全局编辑器高度 = 窗口内容区高度（所有 totalEditorH 的统一来源）
    KARDS.CardEditor.Canvas.TotalEditorH = win.height - 80
    
    -- 更新背景音效系统
    KARDS.CardEditor.Audio.UpdateBackgroundMusic()

    draw.RoundedBox(8, win.x, win.y, win.width, win.height, Color(50, 50, 50))

    draw.RoundedBox(4, win.x, win.y, win.width, 40, Color(35, 35, 35))

    draw.SimpleText(T("editor.canvas.title"), "SourceHan_Heavy_36", win.x + 15, win.y + 20, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

    KARDS.CardEditor.Canvas.UpdateControlPositions()

    -- 标记这一帧是否有更新悬停提示
    KARDS.CardEditor.Canvas.HoverTooltipUpdated = false

    local contentX = win.x + 5
    local contentY = win.y + 75 -- 标签页下方
    local contentW = win.width - 10
    local contentH = win.height - 80

    draw.RoundedBox(4, contentX, contentY, contentW, contentH, Color(40, 40, 40))

    -- 绘制编辑器背景图片（位于窗口背景和方格背景之间）
    -- 根据当前页面选择对应的背景图片
    local currentBgImage
    if KARDS.CardEditor.Canvas.CurrentPage == "effect" then
        currentBgImage = KARDS.CardEditor.Canvas.SelectedBackgroundImages.effect
    elseif KARDS.CardEditor.Canvas.CurrentPage == "appearance" then
        currentBgImage = KARDS.CardEditor.Canvas.SelectedBackgroundImages.appearance
    end
    
    if currentBgImage then
        local bgMat = GetBackgroundMaterial(currentBgImage)
        if bgMat then
            surface.SetDrawColor(255, 255, 255, 50) -- 半透明
            surface.SetMaterial(bgMat)
            surface.DrawTexturedRect(contentX, contentY, contentW, contentH)
        end
    end

    surface.SetDrawColor(80, 80, 80, 100)
    for i = 0, contentW, 20 do
        surface.DrawLine(contentX + i, contentY, contentX + i, contentY + contentH)
    end
    for i = 0, contentH, 20 do
        surface.DrawLine(contentX, contentY + i, contentX + contentW, contentY + i)
    end
    surface.SetDrawColor(255, 255, 255, 255)

    KARDS.CardEditor.Canvas.DrawTabs()
    -- 关于页 BGM 对账（进入切英国 Rule Bridiana / 离开恢复，见 SyncAboutPageBGM）
    KARDS.CardEditor.Canvas.SyncAboutPageBGM(KARDS.CardEditor.Canvas.CurrentPage)
    
    -- 隐藏卡牌选择器在非appearance页面
    if KARDS.CardEditor.Canvas.CurrentPage ~= "appearance" then
        KARDS.CardEditor.Canvas.CardSelector.visible = false
    end
    
    if KARDS.CardEditor.Canvas.CurrentPage == "appearance" then
        -- 卡牌外貌编辑器页面（书签系统）
        KARDS.CardEditor.Canvas.CardSelector.visible = false
        -- 切换到外貌编辑器时隐藏 INE 节点编辑器面板
        local ineEditor = GetNodeEditor("card_effect_editor")
        if ineEditor then
            ineEditor.hidden = true
        end
        KARDS.CardEditor.Canvas.DrawCardAppearanceEditor(contentX, contentY, contentW, contentH)
    elseif KARDS.CardEditor.Canvas.CurrentPage == "effect" then
        -- 使用独立节点编辑器：面板由 INE:DrawAllEditorsInternal 统一绘制，
        -- 在 DrawEffectEditor 末尾显式调用（记录帧号防重），确保 INE 绘制在
        -- Canvas 内容之后（最顶层），不依赖 HUDPaint 钩子注册顺序
        KARDS.CardEditor.Canvas.DrawEffectEditor()
    elseif KARDS.CardEditor.Canvas.CurrentPage == "about" then
        -- 关于页（2026-10-05）：与卡牌外貌属性编辑器、卡牌效果编辑器并列，
        -- 不属于任一编辑器内部。先隐藏效果编辑器面板避免残留遮挡，再绘制整页内容
        local ineEditorAbout = GetNodeEditor("card_effect_editor")
        if ineEditorAbout then
            ineEditorAbout.hidden = true
        end
        KARDS.CardEditor.Canvas.DrawAboutPage(contentX, contentY, contentW, contentH)
    end
    
    KARDS.CardEditor.Canvas.DrawSaveWindow()
    KARDS.CardEditor.Canvas.DrawLoadWindow()
    KARDS.CardEditor.Canvas.DrawLoadConfirmDialog()

    -- 关于页的素材来源弹窗（2026-10-05）：画在这批弹层之后，保证压住关于页全部内容
    KARDS.CardEditor.Canvas.DrawAboutSourcesOverlay()

    -- 绘制文件按钮
    local fileBtnX = win.x + 300
    local fileBtnY = win.y + 5
    local fileBtnW = 80
    local fileBtnH = 30
    local isFileBtnHovered = gui.MouseX() >= fileBtnX and gui.MouseX() <= fileBtnX + fileBtnW and gui.MouseY() >= fileBtnY and gui.MouseY() <= fileBtnY + fileBtnH
    KARDS.CardEditor.Canvas.DrawHoverButton(fileBtnX, fileBtnY, fileBtnW, fileBtnH, T("editor.canvas.card_file"), isFileBtnHovered, { font = "SourceHan_Heavy_16" })

    -- 绘制文件菜单
    if KARDS.CardEditor.Canvas.FileMenu.visible then
        local menuX = win.x + 300
        local menuY = win.y + 40
        local menuW = 300
        local menuH = KARDS.CardEditor.Canvas.FileMenu.height
        
        KARDS.CardEditor.Canvas.FileMenu.x = menuX
        KARDS.CardEditor.Canvas.FileMenu.y = menuY
        KARDS.CardEditor.Canvas.FileMenu.width = menuW
        
        -- 绘制菜单背景
        draw.RoundedBox(4, menuX, menuY, menuW, menuH, Color(60, 60, 60))
        
        -- 绘制菜单标题
        draw.SimpleText(T("editor.canvas.file_operations"), "SourceHan_Heavy_16", menuX + 10, menuY + 10, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        
        -- 绘制按钮（卡牌编辑器只操作卡牌）
        local buttonY = menuY + 35
        local buttonSpacing = 5
        local fm = KARDS.CardEditor.Canvas.FileMenu
        
        for i, button in ipairs(fm.buttons) do
            button.x = menuX + 10
            button.y = buttonY
            
            -- 按钮文字（卡牌相关）
            local btnText = button.text
            
            local mouseX, mouseY = gui.MouseX(), gui.MouseY()
            button.hovered = mouseX >= button.x and mouseX <= button.x + button.width and mouseY >= button.y and mouseY <= button.y + button.height
            
            KARDS.CardEditor.Canvas.DrawHoverButton(button.x, button.y, button.width, button.height, btnText, button.hovered)
            
            if button.hovered then
                if button.id == "save" then
                    KARDS.CardEditor.Canvas.UpdateHoverTooltip(T("editor.canvas.save_tooltip"))
                elseif button.id == "load" then
                    KARDS.CardEditor.Canvas.UpdateHoverTooltip(T("editor.canvas.load_tooltip"))
                elseif button.id == "delete" then
                    KARDS.CardEditor.Canvas.UpdateHoverTooltip(T("editor.canvas.delete_tooltip"))
                end
            end
            
            buttonY = buttonY + button.height + buttonSpacing
        end
    end

    -- 绘制输入控件和其他 VGUI 元素（应该在最后绘制，确保在最上层）
    -- VGUI 控件会自动处理自己的绘制，不需要手动绘制

    KARDS.CardEditor.Canvas.RouteInput()
    
    -- 手动绘制VGUI元素
    if IsValid(KARDS.CardEditor.Canvas.RootPanel) then
        KARDS.CardEditor.Canvas.RootPanel:PaintManual()
    end

    -- 展开下拉框与多选下拉框已随编辑器会话在 INE 绘制阶段画出（见 ADR 0003），此处不再重复绘制

    -- 绘制卡牌选择器（在最上层）
    KARDS.CardEditor.Canvas.DrawCardSelector()

    -- 绘制通知（确保在VGUI元素上方）
    KARDS.CardEditor.Canvas.DrawNotifications()
    
    -- 如果这一帧没有更新过悬停提示，说明鼠标不在任何有提示的元素上，清除提示
    if not KARDS.CardEditor.Canvas.HoverTooltipUpdated then
        KARDS.CardEditor.Canvas.ClearHoverTooltip()
    end
    
    KARDS.CardEditor.Canvas.DrawHoverTooltip()

    -- BGM 专属提示（编辑器窗口右下角文字）与风格按钮悬停简介
    -- 需绘制在编辑器内容最上层：compat 模块此前自注册的 HUDPaint 钩子注册早于本钩子，
    -- 绘制被编辑器窗口覆盖而不可见，故改由本函数在内容绘制完成后统一调用（2026-10-04 修复）
    local bgmCompat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
    if bgmCompat then
        bgmCompat.DrawBGMMessages()
        bgmCompat.DrawBGMHoverTooltip()
    end
end

function KARDS.CardEditor.Canvas.DrawNodeSelector(x, y, w, h)
    local selectorW = 180

    draw.RoundedBox(4, x, y, selectorW, h, Color(55, 55, 55))
    draw.SimpleText(T("editor.canvas.node_selector"), "SourceHan_Heavy_18", x + selectorW / 2, y + 20, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 显示当前模式
    local modeText = T("editor.canvas.mode_prefix")
    if KARDS.CardEditor.Canvas.EditorMode == "unit" then
        modeText = modeText .. T("editor.canvas.mode_unit")
    elseif KARDS.CardEditor.Canvas.EditorMode == "command" then
        modeText = modeText .. T("editor.canvas.mode_command")
    elseif KARDS.CardEditor.Canvas.EditorMode == "counter_command" then
        modeText = modeText .. T("editor.canvas.mode_counter_command")
    elseif KARDS.CardEditor.Canvas.EditorMode == "headquarter" then
        modeText = modeText .. T("editor.canvas.mode_headquarter")
    end
    draw.SimpleText(modeText, "SourceHan_Heavy_14", x + selectorW / 2, y + 40, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    local templateY = y + 60
    for i, template in ipairs(KARDS.CardEditor.Canvas.Templates) do
        local templateH = 50
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        local isHovered = mouseX >= x + 10 and mouseX <= x + selectorW - 10 and
                        mouseY >= templateY and mouseY <= templateY + templateH
        
        -- 如果是事件监测节点且悬停了，显示提示
        if isHovered and template.type == "event_monitor" then
            local tooltipText
            if KARDS.CardEditor.Canvas.EditorMode == "unit" then
                tooltipText = T("editor.canvas.event_monitor_unit_tooltip")
            elseif KARDS.CardEditor.Canvas.EditorMode == "command" then
                tooltipText = T("editor.canvas.event_monitor_command_tooltip")
            elseif KARDS.CardEditor.Canvas.EditorMode == "counter_command" then
                tooltipText = T("editor.canvas.event_monitor_counter_tooltip")
            end
            KARDS.CardEditor.Canvas.UpdateHoverTooltip(tooltipText)
        end
        
        draw.RoundedBox(6, x + 10, templateY, selectorW - 20, templateH, template.color)
        draw.RoundedBox(6, x + 12, templateY + 2, selectorW - 24, templateH - 4, Color(40, 40, 40))
        draw.SimpleText(template.name, "SourceHan_Heavy_14", x + selectorW / 2, templateY + templateH / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        templateY = templateY + templateH + 10
    end
end



-- 绘制数字框组件
-- 数字型变量注册表
KARDS.CardEditor.NumericVariables = KARDS.CardEditor.NumericVariables or {}

-- 变量弹窗与卡牌对象选择器（DrawNumericVarPopup / DrawFuncVarPopup / DrawCardObjectSelector）已拆分至 effect_editor/cl_ca_var_popups.lua
-- （RegisterNumericVariable 及其文档注释一并移至该文件）

-- 13 个输入子函数（HandleCardSelectorInput 等）与 RouteInput 已并入 effect_editor/cl_ca_input_handling.lua

-- 文件管理器绘制（DrawFileManagerInternal / DrawEffectFileManager / DrawSoundFileManager / DrawSubtypeSelector）已拆分至 effect_editor/cl_ca_file_manager.lua

--[[
    向嵌入的 INE 节点编辑器发送节点相关提示。
    若 INE 编辑器存在，则使用 INE 的通知系统（位于最顶层绘制）；
    否则回退到旧的 Canvas 通知系统。
    
    @param  text     {string}   提示文本
    @param  color    {Color}    提示颜色
    @param  duration {number}   显示时长（秒），默认 3 秒
]]
function KARDS.CardEditor.Canvas.AddNodeEditorNotification(text, color, duration, isSuccess)
    local editor = GetNodeEditor and GetNodeEditor("card_effect_editor")
    if editor and INE and INE.AddNotification then
        INE:AddNotification(editor, text, color, duration, isSuccess)
    else
        KARDS.CardEditor.Canvas.AddNotification(text, color, false)
    end
end


-- 绘制卡牌效果编辑器（节点编辑器）
function KARDS.CardEditor.Canvas.DrawEffectEditor()
    -- 如果卡牌编辑器已关闭，不要重新创建或显示 INE 编辑器
    if not KARDS.CardEditor.Canvas.Enabled then return end
    if not IsValid(KARDS.CardEditor.Canvas.RootPanel) or not KARDS.CardEditor.Canvas.RootPanel:IsVisible() then return end
    
    local win = KARDS.CardEditor.Canvas.Window
    local contentX = win.x + 5
    local contentY = win.y + 75
    local contentW = win.width - 10
    local contentH = win.height - 80
    
    if IsValid(KARDS.CardEditor.Canvas.ToggleAppearanceDButton) then
        KARDS.CardEditor.Canvas.ToggleAppearanceDButton:SetVisible(false)
    end
    
    -- 检查是否已创建独立节点编辑器
    local editor = GetNodeEditor("card_effect_editor")
    if not editor then
        -- 创建独立节点编辑器，simplified=false 以显示关闭按钮
        local pos = {
            x = contentX,
            y = contentY,
            width = contentW,
            height = contentH
        }
        
        -- 使用已注册的节点类型（需要先注册）
        local allowedNodes = {}
        local INE = KARDS.CardEditor.IndependentNodeEditor
        
        for nodeName, nodeTpl in pairs(INE.RegisteredNodes) do
            -- 只收集非开始点节点，开始点会自动添加
            if not nodeTpl.isStartNode then
                table.insert(allowedNodes, nodeName)
            end
        end
        
        -- 从 JSON 文件注册所有模板节点（跳过已注册的），
        -- 必须独立于 #allowedNodes 检查以保证始终加载 JSON 模板文件。
        INE:RegisterTemplates()
        
        -- 重新收集 allowedNodes（开始点除外）
        allowedNodes = {}
        for nodeName, nodeTpl in pairs(INE.RegisteredNodes) do
            if not nodeTpl.isStartNode then
                table.insert(allowedNodes, nodeName)
            end
        end
        
        -- 确保 allowedNodes 包含 INE 内置的 start_point
        table.insert(allowedNodes, "start_point")
        
        -- 创建编辑器：simplified=false（显示关闭按钮），borderless=false（显示边框）
        CreateNewNodeEditor(
            "card_effect_editor",  -- panelID
            pos,                    -- pos
            1,                      -- scale
            allowedNodes,           -- allowedNodes
            false,                  -- hidden
            false,                  -- simplified（false = 显示关闭按钮）
            false,                  -- borderless
            true,                   -- showTitleMenu
            KARDS.CardEditor.Canvas.EditorMode or "unit",  -- editorMode
            true                    -- showCoordinates（默认显示坐标系，便于定位）
        )
    else
        -- 如果已存在，确保位置和大小正确（遵循视图模式）
        local ineEditor = GetNodeEditor("card_effect_editor")
        local viewMode = ineEditor and ineEditor._viewMode or "fullscreen"
        local posX, posY, posW, posH = contentX, contentY, contentW, contentH
        if viewMode == "half" then
            posW = math.floor(contentW / 2)
        elseif viewMode == "window" then
            local w = math.floor(contentW * 0.6)
            local h = math.floor(contentH * 0.6)
            posX = contentX + math.floor((contentW - w) / 2)
            posY = contentY + math.floor((contentH - h) / 2)
            posW = w
            posH = h
        end
        SetNodeEditorPosition("card_effect_editor", posX, posY, posW, posH)
        -- 确保显示
        SetNodeEditorHidden("card_effect_editor", false)
        
        -- 同时重新定位函数子编辑器，使其跟随主编辑器的位置与大小变化
        if ineEditor and ineEditor.functionSubEditors then
            for varName, subID in pairs(ineEditor.functionSubEditors) do
                local subEditor = GetNodeEditor(subID)
                if subEditor and not subEditor.hidden and not subEditor._titleDragging then
                    local subViewMode = subEditor._viewMode or "window"
                    local subW, subH, subX, subY

                    -- 如果用户拖拽过该子编辑器，使用拖拽保存的位置
                    if subEditor._dragEndX and subEditor._dragEndY then
                        subX, subY = subEditor._dragEndX, subEditor._dragEndY
                        subW = subEditor.width
                        subH = subEditor.height
                    elseif subViewMode == "fullscreen" then
                        subW, subH = posW, posH
                        subX, subY = posX, posY
                    elseif subViewMode == "half" then
                        subW = math.floor(posW / 2)
                        subH = posH
                        subX = posX + math.floor((posW - subW) / 2)
                        subY = posY
                    else -- "window"
                        subW = math.min(600, posW - 60)
                        subH = math.min(400, posH - 60)
                        subX = posX + (posW - subW) / 2
                        subY = posY + (posH - subH) / 2
                    end
                    SetNodeEditorPosition(subID, subX, subY, subW, subH)
                end
            end
        end
    end

    -- 应用暂存的效果导入（2026-08-14 修复）：加载卡牌时若尚未打开卡牌效果编辑器
    -- 页面（INE 面板未创建）则无法直接导入，效果数据暂存在 PendingEffectImport——
    -- 本帧面板就绪后恢复，保证"加载卡牌即恢复效果"不受页面切换顺序影响。
    local pending = KARDS.CardEditor.Canvas.PendingEffectImport
    if pending then
        KARDS.CardEditor.Canvas.PendingEffectImport = nil
        local inePending = KARDS.CardEditor.IndependentNodeEditor
        if inePending and inePending.ImportEffectData then
            inePending:ImportEffectData(GetNodeEditor("card_effect_editor"), pending)
        end
    end

    -- 显式绘制 INE 面板并记录帧号：确保 INE 绘制在 Canvas 内容之后（最顶层）。
    -- 不依赖 HUDPaint 钩子注册顺序（Lua pairs 遍历顺序不保证 FIFO），
    -- 避免 Canvas 的不透明内容区背景盖住 INE 面板导致面板不可见（此前出现过该问题）。
    -- INE_DrawEditors 钩子通过帧号防重跳过本帧，不会重复绘制。
    local ineDraw = KARDS.CardEditor.IndependentNodeEditor
    if ineDraw and ineDraw.DrawAllEditorsInternal then
        ineDraw:MarkDrawn()
        ineDraw:DrawAllEditorsInternal()
    end
end



-- 滚轮缩放标记（CreateMove 中设值，Draw 中消费）
-- 用于卡牌插图预览和卡牌预览图的滚轮缩放
hook.Add("CreateMove", "KARDS_Canvas_Wheel", function(cmd)
    -- BGM 菜单（曲目列表/展开面板）打开时滚轮由菜单消费：跳过缩放标记，
    -- 防止滚轮穿透到卡牌插图预览/预览图缩放（2026-08-14 用户反馈 INE 穿透同源）
    if IsValid(KARDS.CardEditor.Canvas.BGMTrackListMask) or IsValid(KARDS.CardEditor.Canvas.BGMMenuMask) then
        return
    end
    if input.WasMousePressed(MOUSE_WHEEL_UP) then
        KARDS.CardEditor.Canvas._wheelZoomIn = true
    elseif input.WasMousePressed(MOUSE_WHEEL_DOWN) then
        KARDS.CardEditor.Canvas._wheelZoomOut = true
    end
end)

-- 测试提示控制台指令
concommand.Add("kards_test_notification", function(ply, cmd, args)
    if #args == 0 then
        print("Usage: kards_test_notification <text> [r] [g] [b]")
        return
    end

    local text = args[1]
    local color = Color(50, 50, 50) -- 默认深灰色

    if #args >= 4 then
        local r = tonumber(args[2]) or 50
        local g = tonumber(args[3]) or 50
        local b = tonumber(args[4]) or 50
        color = Color(r, g, b)
    end

    KARDS.CardEditor.Canvas.AddNotification(text, color, false)
end)



-- 绘制加载确认对话框


-- 交互式鼠标悬停提示组件 - 状态管理数据结构
KARDS.CardEditor.Canvas.HoverTooltip = {
    visible = false,
    text = "",
    alpha = 0,
    targetAlpha = 0,
    lastUpdateTime = 0,
    idleTime = 0,
    triggerTime = 0,
    isTriggered = false,
    maxIdleTime = 0.25,
    fadeInTime = 0.5,
    fadeOutTime = 0.2,
    delayTime = 0.5,
    maxLineLength = 20,
    padding = 4,
    cornerRadius = 4,
    fontSize = 14,
    font = "SourceHan_Heavy_14"
}

-- 文字自动换行函数
local function WordWrap(text, maxLength)
    local lines = {}
    local currentLine = ""
    local words = string.Explode(" ", text)
    
    for _, word in ipairs(words) do
        if #currentLine == 0 then
            currentLine = word
        elseif #currentLine + #word + 1 <= maxLength then
            currentLine = currentLine .. " " .. word
        else
            table.insert(lines, currentLine)
            currentLine = word
        end
    end
    
    if #currentLine > 0 then
        table.insert(lines, currentLine)
    end
    
    return lines
end

-- 更新悬停提示内容（主触发函数）
function KARDS.CardEditor.Canvas.UpdateHoverTooltip(text)
    local tooltip = KARDS.CardEditor.Canvas.HoverTooltip
    KARDS.CardEditor.Canvas.HoverTooltipUpdated = true
    
    -- 如果文本为空，清除提示
    if not text or #text == 0 then
        tooltip.text = ""
        tooltip.isTriggered = false
        tooltip.visible = false
        tooltip.alpha = 0
        tooltip.targetAlpha = 0
        return
    end
    
    -- 如果文本没变，只更新时间
    if tooltip.text == text then
        tooltip.lastUpdateTime = SysTime()
        tooltip.idleTime = 0
        return
    end
    
    -- 新文本，重置状态并开始计时
    tooltip.text = text
    tooltip.lastUpdateTime = SysTime()
    tooltip.idleTime = 0
    tooltip.triggerTime = SysTime()
    tooltip.isTriggered = false
    tooltip.alpha = 0
    tooltip.targetAlpha = 0
end

-- 清除悬停提示
function KARDS.CardEditor.Canvas.ClearHoverTooltip()
    KARDS.CardEditor.Canvas.UpdateHoverTooltip("")
end

-- 绘制悬停提示组件
function KARDS.CardEditor.Canvas.DrawHoverTooltip()
    local tooltip = KARDS.CardEditor.Canvas.HoverTooltip
    local currentTime = SysTime()
    
    -- 如果没有文本，直接返回
    if #tooltip.text == 0 then
        return
    end
    
    -- 检查延迟时间是否已过
    if not tooltip.isTriggered then
        local timeSinceTrigger = currentTime - tooltip.triggerTime
        if timeSinceTrigger >= tooltip.delayTime then
            -- 延迟时间到，开始淡入
            tooltip.isTriggered = true
            tooltip.visible = true
            tooltip.targetAlpha = 255
        end
    end
    
    -- 闲置检测与淡出逻辑 - 立即响应闲置，不管淡入是否完成
    if tooltip.isTriggered then
        tooltip.idleTime = currentTime - tooltip.lastUpdateTime
        if tooltip.idleTime > tooltip.maxIdleTime then
            tooltip.targetAlpha = 0
            -- 立即开始淡出，不等待淡入完成
            if tooltip.alpha <= 0 then
                tooltip.visible = false
                tooltip.text = ""
                tooltip.isTriggered = false
            end
        end
    end
    
    -- 平滑透明度过渡动画
    local alphaDiff = tooltip.targetAlpha - tooltip.alpha
    if math.abs(alphaDiff) > 1 then
        local fadeTime = alphaDiff > 0 and tooltip.fadeInTime or tooltip.fadeOutTime
        local speed = 255 / fadeTime * FrameTime()
        if alphaDiff > 0 then
            tooltip.alpha = math.min(tooltip.alpha + speed, 255)
        else
            tooltip.alpha = math.max(tooltip.alpha - speed, 0)
        end
    else
        tooltip.alpha = tooltip.targetAlpha
    end
    
    if tooltip.alpha <= 0 and #tooltip.text == 0 then
        return
    end
    
    -- 如果还没触发或alpha为0，不绘制
    if not tooltip.isTriggered or tooltip.alpha <= 0 then
        return
    end
    
    local lines = WordWrap(tooltip.text, tooltip.maxLineLength)
    local lineHeight = draw.GetFontHeight(tooltip.font)
    local maxWidth = 0
    local totalHeight = 0
    
    for _, line in ipairs(lines) do
        local w, h = surface.GetTextSize(line)
        maxWidth = math.max(maxWidth, w)
        totalHeight = totalHeight + h
    end
    
    local contentWidth = maxWidth
    local contentHeight = totalHeight
    local boxWidth = contentWidth + tooltip.padding * 2
    local boxHeight = contentHeight + tooltip.padding * 2
    
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local boxX = mouseX - boxWidth
    local boxY = mouseY + 15
    
    local screenW, screenH = ScrW(), ScrH()
    if boxX < 0 then
        boxX = mouseX
    end
    if boxY + boxHeight > screenH then
        boxY = mouseY - boxHeight - 15
    end
    if boxX < 0 then boxX = 0 end
    if boxY < 0 then boxY = 0 end
    
    local bgColor = Color(40, 40, 40, tooltip.alpha)
    local borderColor = Color(80, 80, 80, tooltip.alpha)
    draw.RoundedBox(tooltip.cornerRadius, boxX, boxY, boxWidth, boxHeight, bgColor)
    draw.RoundedBox(tooltip.cornerRadius, boxX + 1, boxY + 1, boxWidth - 2, boxHeight - 2, borderColor)
    
    local textColor = Color(255, 255, 255, tooltip.alpha)
    local textX = boxX + tooltip.padding
    local textY = boxY + tooltip.padding
    
    for i, line in ipairs(lines) do
        draw.SimpleText(line, tooltip.font, textX, textY, textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        textY = textY + lineHeight
    end
end

-- ================================================================
-- RouteInput - 按三层动作表调用已拆分的局部子函数
-- 原单体函数已拆分为 13 个局部函数（见上方 HandleXxx 定义）
-- ================================================================

-- 13 个输入子函数（HandleCardSelectorInput 等）与 RouteInput 已并入 effect_editor/cl_ca_input_handling.lua
