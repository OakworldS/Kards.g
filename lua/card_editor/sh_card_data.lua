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

-- 对战词条详细描述 / 显示名称：文本存于语言表（keyword.<id>.name / keyword.<id>.desc），
-- 按当前语言取用；英文表缺失时 KARDS.Lang.Get 自动回退中文表。
-- 词条 id 枚举见上方 KARDS.CardEditor.Data.Keywords。

--- 取词条显示名（当前语言；未登记返回 nil）
-- @param id   string 词条 id
-- @param lang string|nil 语言标识（缺省当前语言）
function KARDS.CardEditor.Data.GetKeywordName(id, lang)
    if not id or not KARDS.Lang then return nil end
    return KARDS.Lang.Get(lang or KARDS.Lang.GetLanguage(), "keyword." .. id .. ".name")
end

--- 取词条说明（当前语言；未登记返回空字符串）
function KARDS.CardEditor.Data.GetKeywordDescription(id, lang)
    if not id or not KARDS.Lang then return "" end
    return KARDS.Lang.Get(lang or KARDS.Lang.GetLanguage(), "keyword." .. id .. ".desc") or ""
end

--- 按语言选择卡牌文本：英文环境优先英文，英文为空/缺失时回退中文
-- @param zhText string|nil 中文文本
-- @param enText string|nil 英文文本
-- @param lang   string|nil 语言标识（缺省当前语言）
function KARDS.CardEditor.Data.PickLocalized(zhText, enText, lang)
    lang = lang or (KARDS.Lang and KARDS.Lang.GetLanguage()) or "zh-CN"
    if lang == "en" and enText ~= nil and enText ~= "" then return enText end
    return zhText or ""
end

--- 取卡面文本字段（名称/描述）：英文环境读 <base>En，为空时回退 <base>
-- @param tbl  table|nil 外观数据表（含 name / nameEn 或 specialEffect / specialEffectEn）
-- @param base string 基础字段名（"name" / "specialEffect"）
function KARDS.CardEditor.Data.GetLocalizedField(tbl, base, lang)
    if not tbl then return "" end
    lang = lang or (KARDS.Lang and KARDS.Lang.GetLanguage()) or "zh-CN"
    if lang == "en" then
        local v = tbl[base .. "En"]
        if v ~= nil and v ~= "" then return v end
    end
    return tbl[base] or ""
end

--- 写卡面文本字段：英文环境写 <base>En，中文环境写 <base>（编辑器输入按当前语言落库）
function KARDS.CardEditor.Data.SetLocalizedField(tbl, base, val, lang)
    if not tbl then return end
    lang = lang or (KARDS.Lang and KARDS.Lang.GetLanguage()) or "zh-CN"
    tbl[lang == "en" and (base .. "En") or base] = val
end

-- 富文本高亮关键词列表（中文）：卡面描述由作者自由填写，故中英文两份词表合并匹配，
-- 描述无论以哪种语言书写都能高亮。
KARDS.CardEditor.Data.KeywordsForHighlightZh = {
    "部署", "抉择", "亡计", "或", "且", "开发", "压制", "抑制", "老兵", "转换", "控制", "免疫",
    "情报", "动员", "奋战", "守护", "山地", "伏击", "倒计时", "冲击", "重甲", "钳击", "闪击", "隐蔽", "烟幕", "协力", "流亡", "预报",
    "收缴", "被收缴"
}

-- 富文本高亮关键词列表（英文，与中文表一一对应）
KARDS.CardEditor.Data.KeywordsForHighlightEn = {
    "Deploy", "Choose", "Last Strike", "or", "and", "Develop", "Suppress", "Neutralized",
    "Veteran", "Convert", "Control", "Immune", "Intelligence", "Mobilize", "Fight", "Guard",
    "Mountain", "Ambush", "Countdown", "Impact", "Heavy Armor", "Pincer", "Blitz", "Conceal",
    "Smoke Screen", "Smoke", "Cooperate", "Exile", "Forecast", "Confiscate", "Confiscated",
}

-- 合并后的高亮词表：按字节长度降序，保证长词优先命中（如「被收缴」先于「收缴」、
-- 「Smoke Screen」先于「Smoke」）；绘制层在模块加载时取用。
KARDS.CardEditor.Data.KeywordsForHighlight = (function()
    local list = {}
    for _, kw in ipairs(KARDS.CardEditor.Data.KeywordsForHighlightZh) do list[#list + 1] = kw end
    for _, kw in ipairs(KARDS.CardEditor.Data.KeywordsForHighlightEn) do list[#list + 1] = kw end
    table.sort(list, function(a, b)
        if #a ~= #b then return #a > #b end
        return a < b
    end)
    return list
end)()

-- 冒号连带高亮的词（「部署：」「Deploy:」整段加粗）；冒号支持中英文两种
KARDS.CardEditor.Data.ColonKeywords = {
    ["部署"] = true, ["抉择"] = true,
    Deploy = true, Choose = true,
}
KARDS.CardEditor.Data.ColonChars = { ["："] = true, [":"] = true }

-- ASCII 词字符（字母/数字/下划线）：英文关键词需词边界，避免 or 命中 for、Guard 命中 Guarded
local function IsAsciiWordByte(b)
    if not b or b >= 128 then return false end
    return string.char(b):match("[%w_]") ~= nil
end

--- 判断 text 的 pos（字节位置）处是否命中关键词 kw（英文词附加词边界校验）
-- @return boolean
function KARDS.CardEditor.Data.KeywordMatchesAt(text, pos, kw)
    if not kw or kw == "" then return false end
    if text:sub(pos, pos + #kw - 1) ~= kw then return false end
    local first = kw:byte(1)
    if first < 128 and IsAsciiWordByte(first) and IsAsciiWordByte(text:byte(pos - 1)) then
        return false
    end
    local last = kw:byte(#kw)
    if last < 128 and IsAsciiWordByte(last) and IsAsciiWordByte(text:byte(pos + #kw)) then
        return false
    end
    return true
end

--[[
    富文本关键词高亮拆分（共享纯逻辑：3D2D 叠加层与 2D 预览共用）

    输入格式段（text/bold/italic，见 ParseFormatTags），输出按关键词切细的段：
      - 命中关键词的段 keyword = true；
      - 部署/抉择命中时连同后面的冒号（中文「：」3 字节 / 英文「:」1 字节）一起高亮；
      - 英文关键词按词边界匹配（KeywordMatchesAt），避免 or / Guard 命中普通单词内部。

    @param segs table 格式段数组 { { text, bold, italic }, ... }
    @return table 段数组 { { text, bold, italic, keyword }, ... }
]]
KARDS.CardEditor.Data.SplitRichKeywords = function(segs)
    local Data = KARDS.CardEditor.Data
    local keywords = Data.KeywordsForHighlight
    local out = {}
    for _, seg in ipairs(segs or {}) do
        local segText = seg.text or ""
        local i = 1
        local plainStart = 1
        while i <= #segText do
            local matchKw = nil
            for _, kw in ipairs(keywords) do
                if Data.KeywordMatchesAt(segText, i, kw) then
                    matchKw = kw
                    break
                end
            end
            if matchKw then
                if plainStart < i then
                    table.insert(out, { text = segText:sub(plainStart, i - 1), bold = seg.bold, italic = seg.italic, keyword = false })
                end
                local matchEnd = i + #matchKw - 1
                local colonLen = 0
                if Data.ColonKeywords[matchKw] then
                    if segText:sub(matchEnd + 1, matchEnd + 3) == "：" then
                        colonLen = 3
                    elseif segText:sub(matchEnd + 1, matchEnd + 1) == ":" then
                        colonLen = 1
                    end
                end
                table.insert(out, { text = segText:sub(i, matchEnd + colonLen), bold = seg.bold, italic = seg.italic, keyword = true })
                i = matchEnd + colonLen + 1
                plainStart = i
            else
                local ch = segText:match("^[%z\1-\127\194-\244][\128-\191]*", i)
                i = i + (ch and #ch or 1)
            end
        end
        if plainStart <= #segText then
            table.insert(out, { text = segText:sub(plainStart), bold = seg.bold, italic = seg.italic, keyword = false })
        end
    end
    return out
end

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

    显示名与分隔符按语言取用（中文「，」/ 英文「, 」）。

    @param kwList      table|nil 词条项数组（id 字符串或 { id, x }）
    @param values      table|nil 数值词条值表 { 词条id = 数值 }（外观编辑器 app.keywordValues 格式）
    @param pincerValue string|number|nil 钳击值（外观编辑器 app.pincerValue 格式）
    @param lang        string|nil 语言标识（缺省当前语言）
    @return string 以语言分隔符连接的词条显示文本（无词条时返回空字符串）
]]
KARDS.CardEditor.Data.BuildKeywordsText = function(kwList, values, pincerValue, lang)
    local Data = KARDS.CardEditor.Data
    local numericKeys = Data.NumericKeywordKeys
    local separator = (KARDS.Lang and KARDS.Lang.Get(lang or KARDS.Lang.GetLanguage(), "keyword.separator")) or "，"
    -- 数值词条名与数值的拼接格式（中文无空格「情报2」，英文有空格「Intelligence 2」）
    local numericFormat = (KARDS.Lang and KARDS.Lang.Get(lang or KARDS.Lang.GetLanguage(), "keyword.numeric.format")) or "%s%s"
    local list = {}

    -- 老兵词条置顶
    for _, kw in ipairs(kwList or {}) do
        if (type(kw) == "table" and kw[1] or kw) == "veteran" then
            table.insert(list, Data.GetKeywordName("veteran", lang))
            break
        end
    end

    for _, kw in ipairs(kwList or {}) do
        local id = type(kw) == "table" and kw[1] or kw
        local x = type(kw) == "table" and kw[2] or nil
        local name = Data.GetKeywordName(id, lang)
        if KARDS.CardInterface and KARDS.CardInterface.IsHiddenKeyword and KARDS.CardInterface.IsHiddenKeyword(id) then
            -- 次词条（隐藏词条，如海军）不在卡面显示
        elseif id == "veteran" or id == "countdown" then
            -- 老兵已置顶；倒计时不在卡面显示（与 BuildKeywordsList 一致）
        elseif id == "pincer" then
            local v = x or pincerValue
            if v and v ~= "" then
                local fmt = (KARDS.Lang and KARDS.Lang.Get(lang or KARDS.Lang.GetLanguage(), "keyword.pincer.with_value")) or "钳击：%s"
                table.insert(list, string.format(fmt, tostring(v)))
            elseif name then
                table.insert(list, name)
            end
        elseif name then
            local v = x or (values and values[id]) or 0
            if table.HasValue(numericKeys, id) then
                if v > 0 then
                    table.insert(list, string.format(numericFormat, name, tostring(v)))
                end
            else
                table.insert(list, name)
            end
        end
    end

    return table.concat(list, separator)
end

--[[
    序列化词条数组为 NW 同步串（服务端写、客户端按本机语言重建显示文本）

    格式：id 或 id:数值，多个以 | 分隔，如 "blitz|intel:2|pincer:3"。
    不直接同步显示文本，避免一条 NW 值只能容纳一种语言。

    @param kwList table|nil 词条项数组（id 字符串或 { id, x }）
    @return string
]]
KARDS.CardEditor.Data.SerializeKeywords = function(kwList)
    local parts = {}
    for _, kw in ipairs(kwList or {}) do
        local id = type(kw) == "table" and kw[1] or kw
        local v = type(kw) == "table" and kw[2] or nil
        if id and id ~= "" then
            if v ~= nil and v ~= "" then
                parts[#parts + 1] = tostring(id) .. ":" .. tostring(v)
            else
                parts[#parts + 1] = tostring(id)
            end
        end
    end
    return table.concat(parts, "|")
end

--- 反序列化词条 NW 串（SerializeKeywords 的逆操作）
-- @return table 词条项数组（id 字符串或 { id, 数值 }）
KARDS.CardEditor.Data.DeserializeKeywords = function(str)
    local list = {}
    if type(str) ~= "string" or str == "" then return list end
    for part in str:gmatch("[^|]+") do
        local id, v = part:match("^([^:]+):(.*)$")
        if id then
            list[#list + 1] = { id, tonumber(v) or v }
        else
            list[#list + 1] = part
        end
    end
    return list
end

--[[
    富文本断行（共享纯逻辑：3D2D 叠加层与 2D 预览共用，绘制层传入测宽回调）

    - 源文本 \n 强制换行；
    - maxWidth 非空时按行宽换行：ASCII 单词整体不拆（按空格断词），
      非 ASCII 字符逐字断行，超长单词在行内按字符硬断；
    - 行尾空格丢弃，行首空格不保留。

    @param segs     table 格式段数组 { { text, bold, italic, keyword（或 isKeyword） }, ... }
    @param measure  function(text, bold, italic, keyword) -> number 测宽回调（maxWidth 非空时必需）
    @param maxWidth number|nil 最大行宽（像素）；nil 时仅按 \n 断行
    @return table 行数组，每行 = { token, ... }，token = { text, bold, italic, keyword }
]]
KARDS.CardEditor.Data.WrapRichSegments = function(segs, measure, maxWidth)
    -- 逐 UTF-8 字符取下一个字符（不能用 sub(i, i)：中文等 3 字节字符会被拆碎）
    local function NextChar(s, i)
        local b = s:byte(i)
        if not b then return nil, nil end
        local len = 1
        if b >= 240 then len = 4
        elseif b >= 224 then len = 3
        elseif b >= 192 then len = 2 end
        return s:sub(i, i + len - 1), i + len
    end

    -- 切分换行单元：空格单独成词（换行时丢弃）；ASCII 连续非空格字符为一个单词；
    -- 非 ASCII 字符（中文等）逐字成词。
    local tokens = {}
    for _, seg in ipairs(segs or {}) do
        local text = seg.text or ""
        local kw = seg.keyword
        if kw == nil then kw = seg.isKeyword end
        local i = 1
        while i <= #text do
            local b = text:byte(i)
            if b == 10 then -- \n
                tokens[#tokens + 1] = { newline = true }
                i = i + 1
            elseif b == 32 then -- 空格
                tokens[#tokens + 1] = { text = " ", space = true, bold = seg.bold, italic = seg.italic, keyword = kw }
                i = i + 1
            elseif b < 128 then
                local j = i
                while j <= #text do
                    local cb = text:byte(j)
                    if cb == 32 or cb == 10 or cb >= 128 then break end
                    j = j + 1
                end
                tokens[#tokens + 1] = { text = text:sub(i, j - 1), bold = seg.bold, italic = seg.italic, keyword = kw }
                i = j
            else
                local ch, ni = NextChar(text, i)
                tokens[#tokens + 1] = { text = ch, bold = seg.bold, italic = seg.italic, keyword = kw }
                i = ni
            end
        end
    end

    local lines = {}
    local cur, curW = {}, 0
    local function Flush()
        while #cur > 0 and cur[#cur].space do cur[#cur] = nil end
        if #cur > 0 then lines[#lines + 1] = cur end
        cur, curW = {}, 0
    end
    local function WidthOf(text, tok)
        if not maxWidth or not measure then return 0 end
        return measure(text, tok.bold, tok.italic, tok.keyword) or 0
    end

    for _, tok in ipairs(tokens) do
        if tok.newline then
            Flush()
        elseif tok.space then
            if #cur > 0 then
                cur[#cur + 1] = tok
                curW = curW + WidthOf(tok.text, tok)
            end
        else
            local w = WidthOf(tok.text, tok)
            if maxWidth and #cur > 0 and curW + w > maxWidth then Flush() end
            if maxWidth and w > maxWidth then
                -- 超长单词（无空格可断）：逐字符硬断
                local i = 1
                while i <= #tok.text do
                    local ch, ni = NextChar(tok.text, i)
                    local cw = WidthOf(ch, tok)
                    if maxWidth and #cur > 0 and curW + cw > maxWidth then Flush() end
                    cur[#cur + 1] = { text = ch, bold = tok.bold, italic = tok.italic, keyword = tok.keyword }
                    curW = curW + cw
                    i = ni
                end
            else
                cur[#cur + 1] = tok
                curW = curW + w
            end
        end
    end
    Flush()
    return lines
end
