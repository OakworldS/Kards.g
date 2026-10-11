-- Kards 卡牌编辑器核心数据结构
-- 共享文件，定义卡牌数据的结构
-- ============================================================================
-- 职责分区：辅助函数 | 工厂函数 | 验证与序列化 | 枚举定义 | 词条数据
-- ============================================================================

KARDS.CardEditor.Data = KARDS.CardEditor.Data or {}

-- ============================================================================
-- 辅助函数
-- ============================================================================

-- 生成唯一 ID（统一委托 Core.Utils.GenerateID，见 sh_utils.lua；本文件先于 sh_utils 加载，
-- 故保留本地委托，运行时 Core.Utils 已就绪——原实现缺 SysTime()，同秒批量创建碰撞概率更高）
local function generateId()
    return KARDS.CardEditor.Core.Utils.GenerateID()
end

-- ============================================================================
-- 数据结构工厂函数
-- ============================================================================

-- 卡牌数据结构
function KARDS.CardEditor.Data:CreateCardData()
    return {
        id = generateId(),
        name = "New Card",
        cost = 1,
        attack = 0,
        defense = 0,
        description = "Card description",
        imagePath = "",
        templatePath = "", -- 模板路径（待填充）
        keywords = {}, -- 对战词条
        effects = {},
        triggers = {},
        nodes = {},
        createdAt = os.time(),
        updatedAt = os.time()
    }
end

-- 效果数据结构
function KARDS.CardEditor.Data:CreateEffectData()
    return {
        id = generateId(),
        type = "damage",
        target = "enemy",
        value = 1,
        condition = nil,
        description = "Effect description"
    }
end

-- 触发条件数据结构
function KARDS.CardEditor.Data:CreateTriggerData()
    return {
        id = generateId(),
        type = "on_play",
        condition = nil,
        description = "Trigger description"
    }
end

-- 节点数据结构
function KARDS.CardEditor.Data:CreateNodeData()
    return {
        id = generateId(),
        type = "property",
        position = Vector(0, 0, 0),
        inputs = {},
        outputs = {},
        properties = {},
        name = "Node"
    }
end

-- 输入端口数据结构
function KARDS.CardEditor.Data:CreateInputPortData()
    return {
        id = generateId(),
        name = "Input",
        type = "number",
        value = 0,
        connectedTo = nil
    }
end

-- 输出端口数据结构
function KARDS.CardEditor.Data:CreateOutputPortData()
    return {
        id = generateId(),
        name = "Output",
        type = "number",
        value = 0,
        connections = {}
    }
end

-- ============================================================================
-- 验证与序列化
-- ============================================================================

-- 验证卡牌数据
function KARDS.CardEditor.Data:ValidateCardData(data)
    local errors = {}
    
    if not data.name or #data.name == 0 then
        table.insert(errors, "Card name is required")
    end
    
    if data.cost < 0 or data.cost > 10 then
        table.insert(errors, "Cost must be between 0 and 10")
    end
    
    if data.attack < 0 or data.attack > 10 then
        table.insert(errors, "Attack must be between 0 and 10")
    end
    
    if data.defense < 0 or data.defense > 10 then
        table.insert(errors, "Defense must be between 0 and 10")
    end
    
    return #errors == 0, errors
end

-- ============================================================================
-- 枚举定义
-- ============================================================================

-- 卡牌类型枚举
KARDS.CardEditor.Data.CardTypes = {
    UNIT = "unit",
    SPELL = "spell",
    TRAP = "trap"
}

-- 效果类型枚举
KARDS.CardEditor.Data.EffectTypes = {
    DAMAGE = "damage",
    HEAL = "heal",
    BUFF = "buff",
    DEBUFF = "debuff",
    DRAW = "draw",
    DISCARD = "discard",
    SUMMON = "summon",
    DESTROY = "destroy"
}

-- 目标类型枚举
KARDS.CardEditor.Data.TargetTypes = {
    SELF = "self",
    FRIENDLY = "friendly",
    ENEMY = "enemy",
    ALL = "all",
    NONE = "none"
}

-- 触发类型枚举
KARDS.CardEditor.Data.TriggerTypes = {
    ON_PLAY = "on_play",
    ON_ATTACK = "on_attack",
    ON_DEFEND = "on_defend",
    ON_DEATH = "on_death",
    ON_TURN_START = "on_turn_start",
    ON_TURN_END = "on_turn_end",
    ON_DRAW = "on_draw",
    ON_DEPLOY = "on_deploy",
    ON_JOIN_BATTLE = "on_join_battle",
    REALTIME = "realtime"
}

-- 节点类型枚举
KARDS.CardEditor.Data.NodeTypes = {
    PROPERTY = "property",
    TRIGGER = "trigger",
    CONDITION = "condition",
    EFFECT = "effect"
}

-- 节点输入类型枚举
KARDS.CardEditor.Data.InputTypes = {
    NUMBER = "number",
    STRING = "string",
    BOOLEAN = "boolean",
    CARD = "card",
    EFFECT = "effect",
    TRIGGER = "trigger"
}

-- ============================================================================
-- 对战词条数据
-- ============================================================================

-- 词条 key 枚举
KARDS.CardEditor.Data.Keywords = {
    BLITZ = "blitz", -- 闪击
    SMOKE = "smoke", -- 烟幕
    INTEL = "intel", -- 情报X
    MOBILIZE = "mobilize", -- 动员
    FIGHT_HARD = "fight_hard", -- 奋战
    GUARD = "guard", -- 守护
    MOUNTAIN = "mountain", -- 山地
    DEATH_PLAN = "death_plan", -- 亡计
    AMBUSH = "ambush", -- 伏击
    COUNTDOWN = "countdown", -- 倒计时X
    IMPACT = "impact", -- 冲击
    HEAVY_ARMOR = "heavy_armor", -- 重甲X
    PINCER = "pincer", -- 钳击
    CONCEAL = "conceal", -- 隐蔽
    VETERAN = "veteran", -- 老兵（用于老兵卡牌）- 表示该卡牌为已升级的老兵版本
    CAN_ELEVATE_TO_VETERAN = "can_elevate_to_veteran", -- 可升为老兵（用于主卡牌）- 标记基础卡牌可以升级为老兵版本
    COOPERATION = "cooperation", -- 协力：触发效果时，除非上一回合存在与卡牌相同国家单位，否则总部就会受到士气伤害
    EXILE = "exile", -- 流亡：流亡牌可投入包含本国的卡组，也可投入包含流亡国的卡组
    FORECAST = "forecast", -- 预报：您可以从 3 张不同的天气牌中选择一个，然后选择该天气类型的延伸卡牌
    NAVY = "navy", -- 海军（隐藏词条：算作海军，不出现在卡面）
}

-- 对战词条详细描述
KARDS.CardEditor.Data.KeywordDescriptions = {
    blitz = "单位进入场地后可立即行动",
    smoke = "具有烟幕的单位无法被其他敌方攻击，单位移动或攻击后，失去烟幕。在前线的单位不能具有烟幕。",
    intel = "情报X：情报牌使用时能显示敌方X张手牌",
    mobilize = "动员：动员单位回合开始时获得+1+1，受到伤害后会失去动员",
    fight_hard = "奋战：奋战单位一回合中可以攻击两次",
    guard = "守护：与守护单位相邻的非守护单位无法被轰炸机和炮兵以外的单位攻击",
    mountain = "山地：山地单位部署或加入战场时，每有一个其他友方山地单位，获得一次+1+1",
    death_plan = "亡计：亡计效果会在单位被消灭时触发",
    ambush = "伏击：伏击单位每回合首次被攻击时，会首先造成反击伤害。若敌方单位因此被消灭，则其无法对伏击单位造成伤害",
    countdown = "倒计时：倒计时结束后，此单位将触发一个事件",
    impact = "冲击：冲击单位首次攻击时，被攻击单位不会造成任何反击伤害。冲击单位攻击单位后，移除冲击",
    heavy_armor = "重甲：重甲单位交战时，受到的伤害减少X。每个单位最多可拥有3重甲",
    pincer = "钳击：部署钳击单位时，可以选择另一个友方单位作为钳击同伴，两者将具有钳击加成，直到其中一个单位离场或失去钳击",
    conceal = "隐蔽：隐蔽单位入场时背面朝上，揭示前不受指令、反制或单位效果影响且行动花费为1。隐蔽单位在发起攻击或被攻击后揭示并失去隐蔽",
    veteran = "老兵：老兵状态的卡牌，表示该卡牌已升级为增强版本，拥有独立的外观和效果",
    can_elevate_to_veteran = "可升为老兵：该卡牌可以升级为老兵状态，拥有一套独立的老兵外观和升级效果",
    cooperation = "协力：触发效果时，除非上一回合存在与卡牌相同国家单位，否则总部就会受到士气伤害",
    exile = "流亡：流亡牌可投入包含本国的卡组，也可投入包含流亡国的卡组",
    forecast = "预报：您可以从 3 张不同的天气牌中选择一个，然后选择该天气类型的延伸卡牌",
    navy = "海军：算作海军（隐藏词条，不显示在卡面）",
}

-- 词条显示名称映射（key → 中文显示名）
KARDS.CardEditor.Data.KeywordDisplayNames = {
    blitz = "闪击",
    smoke = "烟幕",
    intel = "情报",
    mobilize = "动员",
    fight_hard = "奋战",
    guard = "守护",
    mountain = "山地",
    death_plan = "亡计",
    ambush = "伏击",
    countdown = "倒计时",
    impact = "冲击",
    heavy_armor = "重甲",
    pincer = "钳击",
    conceal = "隐蔽",
    veteran = "老兵",
    can_elevate_to_veteran = "可升为老兵",
    cooperation = "协力",
    exile = "流亡",
    forecast = "预报",
    navy = "海军",
}

-- 富文本高亮关键词列表（用于文本绘制时自动加粗）
KARDS.CardEditor.Data.KeywordsForHighlight = {
    "部署", "抉择", "亡计", "或", "且", "开发", "压制", "抑制", "老兵", "转换", "控制", "免疫",
    "情报", "动员", "奋战", "守护", "山地", "伏击", "倒计时", "冲击", "重甲", "钳击", "闪击", "隐蔽", "烟幕", "协力", "流亡", "预报"
}

-- 普通词条 key 列表（无数值的布尔词条）
KARDS.CardEditor.Data.BooleanKeywordKeys = {
    "blitz", "impact", "mobilize", "fight_hard",
    "guard", "mountain", "death_plan", "ambush",
    "pincer", "smoke", "conceal", "cooperation", "exile", "forecast",
}

-- 带数值的词条 key 列表
KARDS.CardEditor.Data.NumericKeywordKeys = {
    "intel", "countdown", "heavy_armor",
}

--[[
    构建词条显示文本（共享：客户端 3D2D 叠加层 / 服务端战场 NW 同步共用）

    兼容两种词条项格式：
      - 词条 id 字符串（如 "blitz"）
      - { 词条id, 数值 } 数组（如 { "pincer", 3 }，情报/重甲等带数值词条）

    规则与 cl_card_preview.lua 的 BuildKeywordsList 一致：
      - 老兵词条置顶
      - 钳击显示为「钳击：值」（值来自项第 2 位或 pincerValue 参数）
      - 数值词条（情报/重甲，排除倒计时）显示名后直接拼接数值，值 >0 才显示
      - 倒计时不在卡面显示

    @param kwList      table|nil 词条项数组（id 字符串或 { id, x }）
    @param values      table|nil 数值词条值表 { 词条id = 数值 }（外观编辑器 app.keywordValues 格式）
    @param pincerValue string|number|nil 钳击值（外观编辑器 app.pincerValue 格式）
    @return string 以「，」连接的词条显示文本（无词条时返回空字符串）
]]
KARDS.CardEditor.Data.BuildKeywordsText = function(kwList, values, pincerValue)
    local names = KARDS.CardEditor.Data.KeywordDisplayNames
    local numericKeys = KARDS.CardEditor.Data.NumericKeywordKeys
    local list = {}

    -- 老兵词条置顶
    for _, kw in ipairs(kwList or {}) do
        if (type(kw) == "table" and kw[1] or kw) == "veteran" then
            table.insert(list, names.veteran)
            break
        end
    end

    for _, kw in ipairs(kwList or {}) do
        local id = type(kw) == "table" and kw[1] or kw
        local x = type(kw) == "table" and kw[2] or nil
        local name = names[id]
        if KARDS.CardInterface and KARDS.CardInterface.IsHiddenKeyword and KARDS.CardInterface.IsHiddenKeyword(id) then
            -- 次词条（隐藏词条，如海军）不在卡面显示
        elseif id == "veteran" or id == "countdown" then
            -- 老兵已置顶；倒计时不在卡面显示（与 BuildKeywordsList 一致）
        elseif id == "pincer" then
            local v = x or pincerValue
            if v and v ~= "" then
                table.insert(list, "钳击：" .. tostring(v))
            elseif name then
                table.insert(list, name)
            end
        elseif name then
            local v = x or (values and values[id]) or 0
            if table.HasValue(numericKeys, id) then
                if v > 0 then
                    table.insert(list, name .. tostring(v))
                end
            else
                table.insert(list, name)
            end
        end
    end

    return table.concat(list, "，")
end
