--[[
    规则词汇表 (Rules Vocabulary)
    
    定义 Kards 基本规则中所有可被 INE 节点引用的选项组。
    每个章节对应 readme.md 中定义的规则分类。
    
    供 config DSL 使用 { @section_name } 语法引用规则选项列表。
    支持玩家自定义扩展选项。
]]

KARDS = KARDS or {}
KARDS.RulesVocabulary = KARDS.RulesVocabulary or {}

-- 规则章节 ID → 定义
KARDS.RulesVocabulary.Registry = {

    -- ======================================
    -- 7.1 综合规则 - 战场对象
    -- ======================================
    battlefield_objects = {
        label = { ["zh-CN"] = "战场对象", ["en"] = "Battlefield Objects" },
        options = {
            { id = "headquarter",    label = { ["zh-CN"] = "总部",     ["en"] = "Headquarter" } },
            { id = "frontline",      label = { ["zh-CN"] = "前线",     ["en"] = "Frontline" } },
            { id = "support_line",   label = { ["zh-CN"] = "支援阵线", ["en"] = "Support Line" } },
            { id = "hand",           label = { ["zh-CN"] = "手牌",     ["en"] = "Hand" } },
            { id = "deck",           label = { ["zh-CN"] = "卡组",     ["en"] = "Deck" } },
        },
        allowCustom = true,
        category = "game",
    },

    -- ======================================
    -- 7.1 综合规则 - 战场操作
    -- ======================================
    operations = {
        label = { ["zh-CN"] = "战场操作", ["en"] = "Operations" },
        options = {
            { id = "move",            label = { ["zh-CN"] = "移动",         ["en"] = "Move" } },
            { id = "attack",          label = { ["zh-CN"] = "攻击",         ["en"] = "Attack" } },
            { id = "retreat",         label = { ["zh-CN"] = "撤退",         ["en"] = "Retreat" } },
            { id = "engage",          label = { ["zh-CN"] = "交战",         ["en"] = "Engage" } },
            { id = "fight",           label = { ["zh-CN"] = "战斗",         ["en"] = "Fight" } },
            { id = "deploy",          label = { ["zh-CN"] = "部署",         ["en"] = "Deploy" } },
            { id = "join_battlefield", label = { ["zh-CN"] = "加入战场",    ["en"] = "Join Battlefield" } },
            { id = "join_frontline",  label = { ["zh-CN"] = "加入前线",     ["en"] = "Join Frontline" } },
            { id = "counterattack",   label = { ["zh-CN"] = "反击",         ["en"] = "Counterattack" } },
            { id = "overwatch",       label = { ["zh-CN"] = "明牌",         ["en"] = "Revealed" } },
        },
        allowCustom = true,
        category = "game",
    },

    -- ======================================
    -- 7.1 综合规则 - 玩家操作
    -- ======================================
    player_actions = {
        label = { ["zh-CN"] = "玩家操作", ["en"] = "Player Actions" },
        options = {
            { id = "draw",         label = { ["zh-CN"] = "抽牌",     ["en"] = "Draw" } },
            { id = "extra_draw",   label = { ["zh-CN"] = "额外抽牌", ["en"] = "Extra Draw" } },
            { id = "discard",      label = { ["zh-CN"] = "弃牌",     ["en"] = "Discard" } },
            { id = "burn",         label = { ["zh-CN"] = "爆牌",     ["en"] = "Burn" } },
        },
        allowCustom = true,
        category = "game",
    },

    -- ======================================
    -- 7.2.1 效果能力
    -- ======================================
    effect_abilities = {
        label = { ["zh-CN"] = "效果能力", ["en"] = "Effect Abilities" },
        options = {
            { id = "suppressed",     label = { ["zh-CN"] = "被压制",  ["en"] = "Suppressed" } },
            { id = "suppress",       label = { ["zh-CN"] = "压制",    ["en"] = "Suppress" } },
            { id = "guarded",        label = { ["zh-CN"] = "被守护",  ["en"] = "Guarded" } },
            { id = "neutralized",    label = { ["zh-CN"] = "抑制",    ["en"] = "Neutralized" } },
            { id = "trigger",        label = { ["zh-CN"] = "触发",    ["en"] = "Trigger" } },
            { id = "passive_effect", label = { ["zh-CN"] = "被动效果",["en"] = "Passive Effect" } },
            { id = "convert",        label = { ["zh-CN"] = "转换",    ["en"] = "Convert" } },
            { id = "repair",         label = { ["zh-CN"] = "修复",    ["en"] = "Repair" } },
            { id = "develop",        label = { ["zh-CN"] = "开发",    ["en"] = "Develop" } },
            { id = "control",        label = { ["zh-CN"] = "控制",    ["en"] = "Control" } },
            { id = "immune",         label = { ["zh-CN"] = "免疫",    ["en"] = "Immune" } },
            { id = "veteran",        label = { ["zh-CN"] = "老兵",    ["en"] = "Veteran" } },
            { id = "intelligence",   label = { ["zh-CN"] = "情报",    ["en"] = "Intelligence" } },
        },
        allowCustom = true,
        category = "ability",
    },

    -- ======================================
    -- 7.2.2 + 7.2.3 战斗词条（含特别词条）
    -- ======================================
    combat_keywords = {
        label = { ["zh-CN"] = "战斗词条", ["en"] = "Combat Keywords" },
        options = {
            { id = "mobilize",     label = { ["zh-CN"] = "动员",   ["en"] = "Mobilize" } },
            { id = "fight",        label = { ["zh-CN"] = "奋战",   ["en"] = "Fight" } },
            { id = "guard",        label = { ["zh-CN"] = "守护",   ["en"] = "Guard" } },
            { id = "mountain",     label = { ["zh-CN"] = "山地",   ["en"] = "Mountain" } },
            { id = "last_strike",  label = { ["zh-CN"] = "亡计",   ["en"] = "Last Strike" } },
            { id = "ambush",       label = { ["zh-CN"] = "伏击",   ["en"] = "Ambush" } },
            { id = "countdown",    label = { ["zh-CN"] = "倒计时", ["en"] = "Countdown" } },
            { id = "impact",       label = { ["zh-CN"] = "冲击",   ["en"] = "Impact" } },
            { id = "heavy_armor",  label = { ["zh-CN"] = "重甲",   ["en"] = "Heavy Armor" } },
            { id = "pincer",       label = { ["zh-CN"] = "钳击",   ["en"] = "Pincer" } },
            { id = "blitz",        label = { ["zh-CN"] = "闪击",   ["en"] = "Blitz" } },
            { id = "conceal",      label = { ["zh-CN"] = "隐蔽",   ["en"] = "Conceal" } },
            { id = "smoke_screen", label = { ["zh-CN"] = "烟幕",   ["en"] = "Smoke Screen" } },
            { id = "cooperate",    label = { ["zh-CN"] = "协力",   ["en"] = "Cooperate" } },
            { id = "intelligence", label = { ["zh-CN"] = "情报",   ["en"] = "Intelligence" } },
            { id = "exile",        label = { ["zh-CN"] = "流亡",   ["en"] = "Exile" } },
            { id = "veteran_elite",label = { ["zh-CN"] = "老兵(精英)", ["en"] = "Veteran(Elite)" } },
            { id = "navy",         label = { ["zh-CN"] = "海军",   ["en"] = "Navy" } },
            { id = "confiscate",   label = { ["zh-CN"] = "收缴",   ["en"] = "Confiscate" } },
            { id = "confiscated",  label = { ["zh-CN"] = "被收缴", ["en"] = "Confiscated" } },
        },
        allowCustom = true,
        category = "keyword",
    },

    -- ======================================
    -- 7.3 单位类型
    -- ======================================
    unit_types = {
        label = { ["zh-CN"] = "单位类型", ["en"] = "Unit Types" },
        options = {
            { id = "fighter",   label = { ["zh-CN"] = "战斗机", ["en"] = "Fighter" } },
            { id = "tank",      label = { ["zh-CN"] = "坦克",  ["en"] = "Tank" } },
            { id = "bomber",    label = { ["zh-CN"] = "轰炸机", ["en"] = "Bomber" } },
            { id = "artillery", label = { ["zh-CN"] = "炮兵",  ["en"] = "Artillery" } },
            { id = "infantry",  label = { ["zh-CN"] = "步兵",  ["en"] = "Infantry" } },
        },
        allowCustom = true,
        category = "unit",
    },

    -- ======================================
    -- 卡牌属性
    -- ======================================
    card_stats = {
        label = { ["zh-CN"] = "卡牌属性", ["en"] = "Card Stats" },
        options = {
            { id = "attack",       label = { ["zh-CN"] = "攻击力",   ["en"] = "Attack" } },
            { id = "defense",      label = { ["zh-CN"] = "防御力",   ["en"] = "Defense" } },
            { id = "max_defense",  label = { ["zh-CN"] = "最大防御力", ["en"] = "Max Defense" } },
            { id = "action_cost",  label = { ["zh-CN"] = "行动花费", ["en"] = "Action Cost" } },
            { id = "cost",         label = { ["zh-CN"] = "费用",     ["en"] = "Cost" } },
        },
        allowCustom = true,
        category = "card",
    },

    -- ======================================
    -- 国籍
    -- ======================================
    nationality = {
        label = { ["zh-CN"] = "国籍", ["en"] = "Nationality" },
        options = {
            { id = "usa",      label = { ["zh-CN"] = "美国",    ["en"] = "USA" } },
            { id = "germany",  label = { ["zh-CN"] = "德国",    ["en"] = "Germany" } },
            { id = "soviet",   label = { ["zh-CN"] = "苏联",    ["en"] = "Soviet Union" } },
            { id = "uk",       label = { ["zh-CN"] = "英国",    ["en"] = "UK" } },
            { id = "japan",    label = { ["zh-CN"] = "日本",    ["en"] = "Japan" } },
            { id = "italy",    label = { ["zh-CN"] = "意大利",  ["en"] = "Italy" } },
            { id = "france",   label = { ["zh-CN"] = "法国",    ["en"] = "France" } },
            { id = "poland",   label = { ["zh-CN"] = "波兰",    ["en"] = "Poland" } },
            -- 2026-08-16：流亡不作国籍（readme 7.2.3 特别战斗词条；流亡为卡组层面的
            -- 入组规则：流亡牌可投入包含本国或流亡国的卡组，国籍下拉不再提供流亡选项）
        },
        allowCustom = true,
        category = "card",
    },
}

-- ======================================
-- 辅助函数
-- ======================================

--[[
    获取指定章节的所有选项
    @param sectionId {string} 章节 ID
    @return {table} 选项列表 [{id, label, isCustom?}]
]]
function KARDS.RulesVocabulary.GetOptions(sectionId)
    local section = KARDS.RulesVocabulary.Registry[sectionId]
    if not section then return {} end

    local result = {}
    local seen = {}
    -- 内置选项
    for _, opt in ipairs(section.options or {}) do
        table.insert(result, opt)
        seen[opt.id] = true
    end
    -- 合并自定义选项（按 ID 去重，2026-10-04：AddCustomOption 同时写入 section.options 与
    -- CustomAdditions，若不按 ID 去重，列表会同时出现内置插入项与持久化项两条）
    local customs = KARDS.RulesVocabulary.CustomAdditions[sectionId]
    if customs then
        for customId, data in pairs(customs) do
            if not seen[customId] then
                table.insert(result, {
                    id = customId,
                    label = data.label,
                    isCustom = true,
                })
                seen[customId] = true
            end
        end
    end
    return result
end

--[[
    获取指定章节的选项 ID → 多语言标签映射
    @param sectionId {string} 章节 ID
    @param lang      {string} 语言代码（如 "zh-CN"），可选
    @return {table} 选项 ID → 标签字符串
]]
function KARDS.RulesVocabulary.GetOptionLabels(sectionId, lang)
    lang = lang or "zh-CN"
    local result = {}
    local section = KARDS.RulesVocabulary.Registry[sectionId]
    if not section then return result end
    for _, opt in ipairs(section.options or {}) do
        result[opt.id] = (opt.label and opt.label[lang]) or opt.id
    end
    return result
end

--[[
    获取章节列表，用于编辑器下拉选择
    @param lang {string} 语言代码
    @return {table} [{id, label}]
]]
function KARDS.RulesVocabulary.GetSectionList(lang)
    lang = lang or "zh-CN"
    local result = {}
    for id, section in pairs(KARDS.RulesVocabulary.Registry) do
        table.insert(result, {
            id = id,
            label = (section.label and section.label[lang]) or id,
        })
    end
    table.sort(result, function(a, b) return a.label < b.label end)
    return result
end

--[[
    添加自定义选项到指定章节（玩家扩展）
    @param sectionId {string} 章节 ID
    @param customId  {string} 自定义选项 ID
    @param label     {table}  多语言标签 {["zh-CN"]="...", ["en"]="..."}
    @return {boolean} 是否成功
]]
function KARDS.RulesVocabulary.AddCustomOption(sectionId, customId, label)
    local section = KARDS.RulesVocabulary.Registry[sectionId]
    if not section then return false end
    if not section.allowCustom then return false end

    -- 记录到自定义持久化存储
    local customs = KARDS.RulesVocabulary.CustomAdditions[sectionId] or {}
    KARDS.RulesVocabulary.CustomAdditions[sectionId] = customs
    customs[customId] = { label = label }
    KARDS.RulesVocabulary.SaveCustomAdditions()

    -- 检查是否已存在
    for _, opt in ipairs(section.options) do
        if opt.id == customId then
            -- 已存在，覆盖标签
            opt.label = label
            return true
        end
    end

    -- 新增
    table.insert(section.options, {
        id = customId,
        label = label,
        isCustom = true,
    })
    return true
end

--[[
    移除自定义选项
    @param sectionId {string} 章节 ID
    @param customId  {string} 自定义选项 ID
    @return {boolean} 是否成功
]]
function KARDS.RulesVocabulary.RemoveCustomOption(sectionId, customId)
    local section = KARDS.RulesVocabulary.Registry[sectionId]
    if not section then return false end

    -- 从自定义持久化存储移除
    local customs = KARDS.RulesVocabulary.CustomAdditions[sectionId]
    if customs and customs[customId] then
        customs[customId] = nil
        if not next(customs) then
            KARDS.RulesVocabulary.CustomAdditions[sectionId] = nil
        end
        KARDS.RulesVocabulary.SaveCustomAdditions()
    end

    for i, opt in ipairs(section.options) do
        if opt.id == customId and opt.isCustom then
            table.remove(section.options, i)
            return true
        end
    end
    return false
end

-- ======================================
-- 自定义选项持久化
-- ======================================

-- 自定义选项持久化存储（跨启动保留，编辑器管理 UI 添加的规则项）
-- 结构: { [sectionId] = { [customId] = { label = { ["zh-CN"]="...", ["en"]="..." } } } }
KARDS.RulesVocabulary.CustomAdditions = KARDS.RulesVocabulary.CustomAdditions or {}

-- 自定义选项持久化文件路径（DATA 目录）
-- @return {string} 文件路径
function KARDS.RulesVocabulary.GetCustomAdditionsPath()
    return "kards/rules_vocabulary_custom.json"
end

--[[
    保存自定义选项到 data 文件
    @return {boolean} 是否成功
]]
function KARDS.RulesVocabulary.SaveCustomAdditions()
    local ok, err = pcall(function()
        file.CreateDir("kards")
        file.Write(KARDS.RulesVocabulary.GetCustomAdditionsPath(), util.TableToJSON(KARDS.RulesVocabulary.CustomAdditions))
    end)
    if not ok then
        print("[RulesVocabulary] 保存自定义选项失败: " .. tostring(err))
    end
    return ok
end

--[[
    从 data 文件加载自定义选项并合并到运行时选项列表
    @return {table} 加载后的 CustomAdditions
]]
function KARDS.RulesVocabulary.LoadCustomAdditions()
    KARDS.RulesVocabulary.CustomAdditions = KARDS.RulesVocabulary.CustomAdditions or {}
    local path = KARDS.RulesVocabulary.GetCustomAdditionsPath()
    if file.Exists(path, "DATA") then
        local content = file.Read(path, "DATA")
        if content then
            local ok, data = pcall(util.JSONToTable, content)
            if ok and type(data) == "table" then
                KARDS.RulesVocabulary.CustomAdditions = data
            end
        end
    end

    -- 合并到运行时选项列表（避免重复插入）
    for sectionId, customs in pairs(KARDS.RulesVocabulary.CustomAdditions) do
        local section = KARDS.RulesVocabulary.Registry[sectionId]
        if section then
            for customId, data in pairs(customs) do
                local exists = false
                for _, opt in ipairs(section.options) do
                    if opt.id == customId then
                        exists = true
                        break
                    end
                end
                if not exists then
                    table.insert(section.options, {
                        id = customId,
                        label = data.label,
                        isCustom = true,
                    })
                end
            end
        end
    end
    return KARDS.RulesVocabulary.CustomAdditions
end

-- 加载已保存的自定义选项（文件系统可用后调用；在 autorun 阶段 include 时直接执行）
KARDS.RulesVocabulary.LoadCustomAdditions()
