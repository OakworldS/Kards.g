--[[
=======================================================================================
卡牌预览渲染系统 (Card Preview Rendering System)
=======================================================================================
实现卡牌预览图的绘制、离屏渲染、动态材质创建等功能。

模块特性：
  - 富文本绘制：支持关键词高亮、多字体、自动换行
  - 卡牌预览绘制：可在任意位置绘制完整的卡牌预览图
  - 离屏渲染：将卡牌渲染到 RenderTarget 并保存为图片
  - 动态材质：从 RenderTarget 创建动态材质供游戏使用
  - 测试实体：在玩家面前生成测试卡牌实体

依赖：
  - cl_ine_node_editor.lua：数据类型定义
  - cl_canvas_editor.lua：全局配置和图片路径
=======================================================================================
--]]

-- 高级文本绘制函数：支持多字体、换行、关键词高亮
-- （高亮词表与规则见 sh_card_data.lua：KeywordsForHighlight / SplitRichKeywords）

-- 引用全局词条枚举表（BuildKeywordsList 委托前重排为固定枚举顺序）
local booleanKeywordKeys = KARDS.CardEditor.Data.BooleanKeywordKeys
local numericKeywordKeys = KARDS.CardEditor.Data.NumericKeywordKeys

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- 数值文字统一颜色（近白色 C9C3A9，符合卡牌模板风格）：
-- 卡牌花费/行动花费/攻击/防御等所有白色数值文字统一使用
-- 与 3D2D 文字叠加层（cl_card_text_overlay.lua 的 COLOR_NUMBER）保持同色
local VALUE_TEXT_COLOR = Color(201, 195, 169)

-- 闪卡模式判定（2026-10-04）：闪卡模板下卡面文字配色反转，
-- 花费与行动花费用纯白，名称与攻防等其余文字用纯黑（词条与描述本就为纯黑）。
local function IsFlashTemplate(appearance)
    return appearance ~= nil and appearance.cardTemplate == "flash"
end

-- 注册斜体字体用于 HTML <i> 标签
surface.CreateFont("Calibri_Italic_20", {
    font = "Calibri",
    size = 20,
    weight = 400,
    italic = true,
    antialias = true,
})

-- 卡牌模板键（外貌数据 → ImagePaths.template 的键）：统一取值并容错。
-- 旧存档与卡牌对象变量里的外貌数据可能没有 cardTemplate（该字段是后加的），直接拼接会
-- 报 attempt to concatenate field 'cardTemplate'（a nil value）；缺失时回退 "custom"，
-- 与各调用点查不到键时回退 ImagePaths.template["custom"] 同一口径。
local function TemplateKeyOf(appearance)
    local app = appearance or {}
    return (app.cardTemplate or "custom") .. "_" .. (app.cardType or "unit")
end

-- 外貌数据规范化（2026-10-02）：节点编辑器的悬停预览传入的是缓存的 cardAppearance，可能来自
-- 旧存档或卡牌对象变量，字段不全。缺 cardTemplate 会在拼接模板键时报错，缺 imageScale 会在
-- 插图缩放的乘法上报错，缺 nameFontSize 会在字体名拼接时报错。绘制入口统一以本表为底补默认值，
-- 传入表覆盖其上，缺失字段一律取中性的默认值（不用编辑器当前卡牌的数据，避免串值）。
local PREVIEW_APPEARANCE_DEFAULTS = {
    name = "", nameEn = "", cost = 0, actionCost = 0, country = "", cardType = "infantry",
    attack = 0, defense = 0, quality = "normal",
    keywords = {}, keywordValues = {}, pincerValue = "",
    specialEffect = "", specialEffectEn = "", imagePath = "",
    cardTemplate = "custom", customTemplatePath = "",
    nameIsBlack = false, nameIsEnglish = false, nameFontSize = 36, descFontSize = 20,
    imageOffsetX = 0, imageOffsetY = 0, imageScale = 1, effectPath = "",
}

local function NormalizeAppearance(appearance)
    local out = {}
    for k, v in pairs(PREVIEW_APPEARANCE_DEFAULTS) do out[k] = v end
    for k, v in pairs(appearance or {}) do
        if v ~= nil then out[k] = v end
    end
    return out
end

-- 根据外貌数据获取卡牌模板材质路径
local function GetTemplatePath(appearance)
    local templateKey = TemplateKeyOf(appearance)
    local templatePath = KARDS.CardEditor.Canvas.ImagePaths.template[templateKey]
    if not templatePath then
        templatePath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
    end
    return templatePath
end

-- 解析 HTML 加粗/斜体标签为格式化片段
local function ParseFormatTags(line)
    local segs = {}
    local pos = 1
    local bold, italic = false, false
    while pos <= #line do
        local minTag = nil
        local minTagEnd = nil
        local tagType = nil

        local startB, endB = line:find("<b>", pos)
        if startB and (not minTag or startB < minTag) then minTag = startB; minTagEnd = endB; tagType = "bOpen" end

        local closB, closBEnd = line:find("</b>", pos)
        if closB and (not minTag or closB < minTag) then minTag = closB; minTagEnd = closBEnd; tagType = "bClose" end

        local startI, endI = line:find("<i>", pos)
        if startI and (not minTag or startI < minTag) then minTag = startI; minTagEnd = endI; tagType = "iOpen" end

        local closI, closIEnd = line:find("</i>", pos)
        if closI and (not minTag or closI < minTag) then minTag = closI; minTagEnd = closIEnd; tagType = "iClose" end

        if not minTag then
            table.insert(segs, {text = line:sub(pos), bold = bold, italic = italic})
            break
        end

        -- 添加标签前的文本
        if minTag > pos then
            table.insert(segs, {text = line:sub(pos, minTag - 1), bold = bold, italic = italic})
        end

        -- 切换格式状态
        if tagType == "bOpen" then bold = true
        elseif tagType == "bClose" then bold = false
        elseif tagType == "iOpen" then italic = true
        elseif tagType == "iClose" then italic = false
        end

        pos = minTagEnd + 1
    end
    return segs
end

-- 简化版本：针对卡牌预览的特殊效果绘制（支持 HTML <b> <i> 标签）
local function FindVarByInternalName(internalName)
    -- 在所有 INE 编辑器中查找指定 internalName 的变量，返回其初始值的字符串表示
    if not internalName or internalName == "" then return nil end
    local editors = KARDS.CardEditor.IndependentNodeEditor and KARDS.CardEditor.IndependentNodeEditor.Editors
    if not editors then return nil end
    for _, editor in pairs(editors) do
        if editor.variables then
            for typeId, vars in pairs(editor.variables) do
                for _, vd in ipairs(vars) do
                    if vd.internalName == internalName then
                        if typeId == "n" then
                            return tostring(vd.initialValue or 0)
                        elseif typeId == "p" then
                            return tostring(vd.initialValue == true and "true" or "false")
                        elseif typeId == "t" then
                            return vd.initialValue or ""
                        elseif typeId == "e" then
                            return T("editor.preview.var_card_object")
                        elseif typeId == "g" then
                            return T("editor.preview.var_array")
                        elseif typeId == "f" then
                            return T("editor.preview.var_function")
                        else
                            return tostring(vd.initialValue or "")
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- 选择描述富文本分段字体：优先使用注册过的同字号字体，缺失时回退到思源黑体同字号（避免使用未注册字体）
local function PickDescSegmentFont(size, seg)
    if seg.isKeyword or seg.keyword or seg.bold then
        return "SourceHan_Heavy_" .. size
    end
    if seg.italic then
        local f = "Calibri_Italic_" .. size
        if CustomFonts and CustomFonts[f] then return f end
        return "SourceHan_Heavy_" .. size
    end
    local f = "Calibri_" .. size
    if CustomFonts and CustomFonts[f] then return f end
    return "SourceHan_Heavy_" .. size
end

-- 富文本断行：按行宽换行（与 3D2D 叠加层一致，委托 sh_card_data.WrapRichSegments；
-- 英文按空格断词、中文逐字断行，超长单词硬断）
local function WrapDescLines(segs, maxWidth, size)
    return KARDS.CardEditor.Data.WrapRichSegments(segs, function(text, bold, italic, keyword)
        surface.SetFont(PickDescSegmentFont(size, { isKeyword = keyword, bold = bold, italic = italic }))
        return surface.GetTextSize(text)
    end, maxWidth)
end

-- 字号自适应：按起始字号断行，行数超出可用高度时逐级缩小字号（步长 2，下限 12）。
-- @return lines, size, lineH 断行结果 / 最终字号 / 行高
local function FitDescLines(segs, maxWidth, startSize, maxHeight)
    local size = math.max(10, startSize or 20)
    while true do
        local lines = WrapDescLines(segs, maxWidth, size)
        local lineH = math.max(10, math.floor(18 * size / 20))
        if not maxHeight or #lines * lineH <= maxHeight or size <= 12 then
            return lines, size, lineH
        end
        size = size - 2
    end
end

-- 绘制效果描述富文本（关键词高亮 + 源文本 \n 强制换行 + 按宽度自动换行 + 字号自适应）
-- maxWidth / maxHeight 由调用方按卡面可用文字区传入（屏幕像素）
local function DrawSpecialEffectRichText(text, x, y, xAlign, yAlign, fontSize, maxWidth, maxHeight)
    if not text or text == "" then return end
    fontSize = fontSize or 20
    -- 替换 (内部变量名) 为 (初始值)
    text = string.gsub(text, "%(([%w_]+)%)", function(match)
        local val = FindVarByInternalName(match)
        if val then
            return "(" .. val .. ")"
        end
        return "(" .. match .. ")"
    end)
    -- 先处理转义的换行符，再统一解析标签与关键词高亮（规则见 sh_card_data.lua）
    local processedText = string.gsub(text, "\\n", "\n")
    local finalSegs = KARDS.CardEditor.Data.SplitRichKeywords(ParseFormatTags(processedText))

    local lines, size, lineHeight = FitDescLines(finalSegs, maxWidth, fontSize, maxHeight)

    for lineIdx, line in ipairs(lines) do
        -- 计算行总宽度
        local totalWidth = 0
        for _, seg in ipairs(line) do
            local font = PickDescSegmentFont(size, seg)
            surface.SetFont(font)
            totalWidth = totalWidth + surface.GetTextSize(seg.text)
        end

        -- 绘制这一行（整体水平居中于 x，逐 token 左对齐累加）
        local currentX = x - totalWidth / 2
        local currentY = y + (lineIdx - 1) * lineHeight
        for _, seg in ipairs(line) do
            local font = PickDescSegmentFont(size, seg)
            surface.SetFont(font)
            local w = surface.GetTextSize(seg.text)
            draw.SimpleText(seg.text, font, currentX, currentY, Color(0, 0, 0), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            currentX = currentX + w
        end
    end
end

-- ===== 双版本布局配置（2026-08-15 编辑器重构 7.5-5 收敛） =====
-- preview：编辑器屏幕预览（DrawCardPreview）位置数值
-- render ：离屏渲染纹理（DrawCardPreviewRender）位置数值
-- 数值均为多年视觉调校结果、与模板像素级耦合，禁止改动；
-- 计算方式与重构前逐字等价（previewX/previewY ± 数值 * scaleFactor）
local LAYOUT = {
    preview = {
        nameTop = 35,                       -- 普通卡名称：距顶部
        nameCommand = 100,                  -- 指令卡名称：距底部
        nameHQ = 87.5,                      -- 总部名称：距底部
        costX = 35, costY = 35,             -- 花费（左上角）
        actionCostX = 51, actionCostY = 45, -- 行动花费（花费右侧）
        countryRight = 60, countryTop = 20, -- 国旗（右上角）
        attackLeft = 79.5, attackBottom = 109.5,  -- 攻击（左下）
        defenseRight = 88, defenseBottom = 109.5, -- 防御（右下）
        typeIconCenterX = 0, typeIconBottom = 125, -- 类型图标（攻防之间）
        hqDefenseRight = 150, hqDefenseBottom = 155, -- 总部防御（右下）
        keywordsBottom = 78,                -- 词条：距底部
        descAfterKeywords = 20,             -- 描述：有词条时紧贴词条下方
        descAfterName = 27,                 -- 描述：指令卡无词条时紧贴标题下方
        qualityBottom = 23,                 -- 品质图标：距底部
    },
    render = {
        nameTop = 25,
        nameCommand = 95,
        nameHQ = 82.5,
        costX = 25, costY = 25,
        actionCostX = 41, actionCostY = 35,
        countryRight = 50, countryTop = 15,
        attackLeft = 70.5, attackBottom = 105.5,
        defenseRight = 73, defenseBottom = 105.5,
        typeIconCenterX = 2, typeIconBottom = 119,
        hqDefenseRight = 150, hqDefenseBottom = 155,
        keywordsBottom = 75,
        descAfterKeywords = 20,
        descAfterName = 35,
        qualityBottom = 20,
    },
}

-- ===================== DrawCardPreview 子函数（双版本布局参数化） =====================
-- 说明：预览器与渲染器的 7 对同构子函数已收敛为单一函数，
-- 位置数值由调用方传入的 LAYOUT.preview / LAYOUT.render 决定（2026-08-15 编辑器重构 7.5-5）。

-- 构建词条列表并返回 keywordsText 和 hasKeywords
-- 拼接规则统一委托 BuildKeywordsText（sh_card_data.lua，战斗系统共用）；
-- 此处仅保留「固定枚举顺序」差异（appearance.keywords 为用户点击顺序，
-- 委托前重排为枚举顺序，保持与原 BuildKeywordsList 输出顺序一致）
local function BuildKeywordsList(appearance)
    local ordered = {}
    for _, key in ipairs(booleanKeywordKeys) do
        if table.HasValue(appearance.keywords, key) then
            table.insert(ordered, key)
        end
    end
    for _, key in ipairs(numericKeywordKeys) do
        if table.HasValue(appearance.keywords, key) then
            table.insert(ordered, key)
        end
    end
    -- veteran 不属布尔/数值枚举表，单独加入（BuildKeywordsText 内部置顶）
    if table.HasValue(appearance.keywords, "veteran") then
        table.insert(ordered, "veteran")
    end

    local keywordsText = KARDS.CardEditor.Data.BuildKeywordsText(ordered, appearance.keywordValues, appearance.pincerValue)
    return keywordsText, keywordsText ~= ""
end

-- 绘制卡牌名称（预览器/渲染器共用，位置数值取 layout）
-- 普通卡名称位于预览图顶部向下，指令卡位于预览图底部向上（距底数值见 LAYOUT）
-- 返回 nameY 供 DrawCardDescription 使用
local function DrawCardName(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, layout)
    -- 名称位置计算独立于名称内容：指令/总部卡无名称（name 为空）时也返回位置，
    -- 供 DrawCardDescription（指令卡无词条时紧贴标题下方锚定）使用，避免 nameY=nil 算术崩溃
    local nameY
    if isCommandCard then
        -- 总部名称下移（下移量减半：原 25 降为 12.5）
        nameY = (appearance.cardType == "headquarter") and (previewY + previewH - layout.nameHQ * scaleFactor) or (previewY + previewH - layout.nameCommand * scaleFactor)
    else
        nameY = previewY + layout.nameTop * scaleFactor
    end
    -- 卡名按当前语言取（英文环境优先 nameEn，为空回退 name）
    local displayName = KARDS.CardEditor.Data.GetLocalizedField(appearance, "name")
    if not (displayName and displayName ~= "") then return nameY end
    local nameColor = (IsFlashTemplate(appearance) or appearance.nameIsBlack or isCommandCard) and Color(0, 0, 0) or Color(255, 255, 255)

    local nameFont = "SourceHan_Heavy_" .. appearance.nameFontSize
    local useEnglishFont = false

    if appearance.nameIsEnglish then
        local actualSize = appearance.nameFontSize
        if actualSize == 64 then
            actualSize = 60
        end
        for _, size in ipairs(KARDS.CardEditor.Canvas.DdayFontSizes) do
            if size == actualSize then
                nameFont = "Dday_" .. actualSize
                useEnglishFont = true
                break
            end
        end
    end

    if not appearance.nameIsEnglish or useEnglishFont then
        draw.SimpleText(displayName, nameFont, previewX + previewW / 2, nameY, nameColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    return nameY
end

-- 绘制卡牌花费（如果hideNumbers为false；预览器/渲染器共用，位置数值取 layout）
-- 花费位置说明：位于预览图左上角，居中对齐
local function DrawCardCost(appearance, previewX, previewY, scaleFactor, isCommandCard, hideNumbers, layout)
    if hideNumbers or appearance.cardType == "headquarter" then return end

    local costText = tostring(appearance.cost)
    local costFont = #costText > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
    -- 闪卡模式：花费与行动花费改纯白（2026-10-04）
    local costColor = IsFlashTemplate(appearance) and Color(255, 255, 255) or VALUE_TEXT_COLOR
    draw.SimpleText(costText, costFont, previewX + layout.costX * scaleFactor, previewY + layout.costY * scaleFactor, costColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- 绘制行动花费（非指令卡才绘制）
    -- 行动花费位置说明：位于花费数字右侧，居中对齐
    -- 十位数以上用更小字号（18）避免与花费数字重叠
    if not isCommandCard then
        local actionCostText = tostring(appearance.actionCost)
        local actionCostFont = #actionCostText > 1 and "SourceHan_Heavy_18" or "SourceHan_Heavy_24"
        draw.SimpleText(actionCostText, actionCostFont, previewX + layout.actionCostX * scaleFactor, previewY + layout.actionCostY * scaleFactor, costColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

-- 绘制所属国图标（右上角；预览器/渲染器共用，位置数值取 layout）
-- 国旗位置说明：从预览图右侧向左偏移、从顶部向下偏移（数值见 LAYOUT）
local function DrawCardCountry(appearance, previewX, previewY, previewW, scaleFactor, layout)
    -- 按卡牌所属国选择图标，未知/缺失回退沙盒图标
    local countryKey = tostring(appearance and appearance.country or ""):lower()
    local countryIconPath = KARDS.CardEditor.Canvas.ImagePaths.country[countryKey]
        or KARDS.CardEditor.Canvas.ImagePaths.country["sandbox"]
    if not countryIconPath then return end

    local countryMat = Material(countryIconPath)
    if countryMat then
        local countryW = countryMat:Width() * scaleFactor
        local countryH = countryMat:Height() * scaleFactor
        surface.SetDrawColor(255, 255, 255, 255)
        surface.SetMaterial(countryMat)
        surface.DrawTexturedRect(previewX + previewW - layout.countryRight * scaleFactor, previewY + layout.countryTop * scaleFactor, countryW, countryH)
    end
end

-- 绘制攻击力、防御力和卡牌类型图标（预览器/渲染器共用，位置数值取 layout）
-- renderMode：离屏渲染模式（3D2D 文字卡 hideNumbers 时攻防/总部防御转 3D2D 叠加层，
--   但类型图标仍保留在纹理；预览模式 hideNumbers 时本函数整体跳过，行为同重构前）
local function DrawCardStats(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hideNumbers, layout, renderMode)
    -- 预览模式：hideNumbers 时整个攻防区域（含类型图标）不绘制（重构前预览器行为）
    if not renderMode and hideNumbers then return end

    -- 闪卡模式：攻防等数值改纯黑（2026-10-04）
    local statColor = IsFlashTemplate(appearance) and Color(0, 0, 0) or VALUE_TEXT_COLOR

    -- 总部：仅绘制防御力（不绘制攻击力/类型图标）；位置与屏幕预览一致（右下角）；防御力文字放大显示
    if appearance.cardType == "headquarter" then
        if not hideNumbers then
            local hqDefenseText = tostring(appearance.defense)
            local hqDefenseFont = #hqDefenseText > 1 and "SourceHan_Heavy_56" or "SourceHan_Heavy_72"
            draw.SimpleText(hqDefenseText, hqDefenseFont, previewX + previewW - layout.hqDefenseRight * scaleFactor, previewY + previewH - layout.hqDefenseBottom * scaleFactor, statColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        return
    end

    if isCommandCard then return end

    -- 绘制攻击力（偏下位置左侧）与防御力（偏下位置右侧）
    -- 攻击力位置说明：从预览图左侧偏移、从底部向上偏移；防御力同理从右侧偏移（数值见 LAYOUT）
    -- hideNumbers 时不烘焙攻防数字（转 3D2D 叠加层实时绘制）
    if not hideNumbers then
        local attackText = tostring(appearance.attack)
        local attackFont = #attackText > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
        draw.SimpleText(attackText, attackFont, previewX + layout.attackLeft * scaleFactor, previewY + previewH - layout.attackBottom * scaleFactor, statColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        local defenseText = tostring(appearance.defense)
        local defenseFont = #defenseText > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
        draw.SimpleText(defenseText, defenseFont, previewX + previewW - layout.defenseRight * scaleFactor, previewY + previewH - layout.defenseBottom * scaleFactor, statColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- 绘制卡牌类型图标（攻击力和防御力之间；hideNumbers 时仍保留在纹理）
    -- 类型图标位置说明：预览图水平居中（可相对中心偏移），从底部向上偏移（数值见 LAYOUT）
    local cardTypeScaleFactor = 0.32 * scaleFactor
    local cardTypeIconPath = KARDS.CardEditor.Canvas.ImagePaths.cardType[appearance.cardType]
    if cardTypeIconPath then
        local cardTypeMat = Material(cardTypeIconPath)
        if cardTypeMat then
            local cardTypeW = cardTypeMat:Width() * cardTypeScaleFactor
            local cardTypeH = cardTypeMat:Height() * cardTypeScaleFactor
            surface.SetDrawColor(255, 255, 255, 255)
            surface.SetMaterial(cardTypeMat)
            surface.DrawTexturedRect(previewX + previewW / 2 - cardTypeW / 2 + layout.typeIconCenterX * scaleFactor, previewY + previewH - layout.typeIconBottom * scaleFactor, cardTypeW, cardTypeH)
        end
    end
end

-- 词条位置说明：从预览图底部向上偏移（数值见 LAYOUT；预览器/渲染器共用）
-- 3D2D 文字卡（hideNumbers）：词条转由 3D2D 叠加层实时绘制（不烘焙进纹理）——仅离屏渲染模式
local function DrawCardKeywords(appearance, previewX, previewY, previewW, previewH, scaleFactor, cardCenterX, layout, hideNumbers)
    if hideNumbers then return false end
    local keywordsText, hasKeywords = BuildKeywordsList(appearance)
    if hasKeywords then
        local keywordsY = previewY + previewH - layout.keywordsBottom * scaleFactor
        -- 英文词条串更长：超出文字区宽度时逐级缩小字号（20 → 12，步长 2）
        local maxWidth = previewW - 40 * scaleFactor
        local kwSize = 20
        surface.SetFont("SourceHan_Heavy_" .. kwSize)
        while kwSize > 12 and surface.GetTextSize(keywordsText) > maxWidth do
            kwSize = kwSize - 2
            surface.SetFont("SourceHan_Heavy_" .. kwSize)
        end
        draw.SimpleText(keywordsText, "SourceHan_Heavy_" .. kwSize, cardCenterX, keywordsY, Color(0, 0, 0), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    return hasKeywords
end

-- 绘制卡牌描述（预览器/渲染器共用，位置数值取 layout）
-- 3D2D 文字卡（hideNumbers）：效果描述转由 3D2D 叠加层实时绘制（不烘焙进纹理）——仅离屏渲染模式
local function DrawCardDescription(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hasKeywords, nameY, cardCenterX, layout, hideNumbers)
    if hideNumbers then return end
    -- 描述按当前语言取（英文环境优先 specialEffectEn，为空回退 specialEffect）
    local effectText = KARDS.CardEditor.Data.GetLocalizedField(appearance, "specialEffect")
    if not (effectText and effectText ~= "") then return end

    local descY
    if hasKeywords then
        -- 有词条时：紧靠词条正下方
        descY = (previewY + previewH - layout.keywordsBottom * scaleFactor) + layout.descAfterKeywords * scaleFactor
    else
        -- 无词条时：
        if isCommandCard then
            -- 指令、反制指令：紧贴标题下方
            descY = nameY + layout.descAfterName * scaleFactor
        else
            -- 单位模式：上移到词条区域（微移半行填补词条空缺）
            descY = previewY + previewH - layout.keywordsBottom * scaleFactor
        end
    end
    -- 可用的文字区宽高（屏幕像素）：左右各留 20 渲染像素；指令卡向下绘制到卡底，
    -- 其余卡以锚点为中心向上下扩展（多行垂直居中，底部空间按两倍折算）
    local maxWidth = previewW - 40 * scaleFactor
    local bottomRoom = previewY + previewH - descY
    local maxHeight = isCommandCard and (bottomRoom - 30 * scaleFactor)
        or (bottomRoom * 2 - 12 * scaleFactor)
    DrawSpecialEffectRichText(effectText, cardCenterX, descY, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, appearance.descFontSize or 20, maxWidth, maxHeight)
end

-- 绘制品质图标（图片最底部；预览器/渲染器共用，位置数值取 layout）
-- 品质图标位置说明：预览图水平居中，从底部向上偏移（数值见 LAYOUT）
local function DrawCardQuality(appearance, previewX, previewY, previewW, previewH, scaleFactor, layout)
    local qualityScaleFactor = 0.4 * scaleFactor
    local qualityIconPath = KARDS.CardEditor.Canvas.ImagePaths.quality[appearance.quality]
    if not qualityIconPath then return end

    local qualityMat = Material(qualityIconPath)
    if qualityMat then
        local qualityW = qualityMat:Width() * qualityScaleFactor
        local qualityH = qualityMat:Height() * qualityScaleFactor
        surface.SetDrawColor(255, 255, 255, 255)
        surface.SetMaterial(qualityMat)
        surface.DrawTexturedRect(previewX + previewW / 2 - qualityW / 2, previewY + previewH - layout.qualityBottom * scaleFactor, qualityW, qualityH)
    end
end

-- ===================== DrawCardPreview 共享子函数（边框/插图/模板） =====================

-- 绘制卡牌边框和边缘
local function DrawCardBorder(previewX, previewY, previewW, previewH, scaleFactor, noEdgeOffset)
    local edgeOffset = noEdgeOffset and 0 or 5 * scaleFactor

    if not noEdgeOffset then
        surface.DrawOutlinedRect(previewX, previewY, previewW, previewH)
    end

    -- 绘制卡牌边框（从预览图边缘向内偏移）
    draw.RoundedBox(4, previewX + edgeOffset, previewY + edgeOffset, previewW - edgeOffset * 2, previewH - edgeOffset * 2, Color(60, 60, 60))
end

-- 绘制卡牌插图（下层）
-- 插图区域：与模板空心区域精确对齐（通过 GetTemplateHollowBounds 动态计算）
local function DrawCardImage(appearance, previewX, previewY, previewW, previewH, scaleFactor, hideNumbers, noEdgeOffset)
    -- 计算模板卡面渲染位置（与 DrawCardTemplate 一致）
    local drawX, drawY, drawW, drawH = previewX + 10 * scaleFactor, previewY + 10 * scaleFactor, 140 * scaleFactor, 110 * scaleFactor
    local hollowX, hollowY, hollowW, hollowH = 0, 0, 140 / 0.25, 110 / 0.25
    local cardMinX, cardMinY = 0, 0
    local cardW, cardH = 140 / 0.25, 110 / 0.25

    local templateKey = TemplateKeyOf(appearance)
    local templatePath = KARDS.CardEditor.Canvas.ImagePaths.template[templateKey]
    if not templatePath then
        templatePath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
    end
    if templatePath then
        local tempMat = Material(templatePath)
        if tempMat and not tempMat:IsError() then
            cardMinX, cardMinY, cardW, cardH = KARDS.CardEditor.Canvas.GetCardTextureBounds(tempMat)
            hollowX, hollowY, hollowW, hollowH = KARDS.CardEditor.Canvas.GetTemplateHollowBounds(tempMat)
            local tex = tempMat:GetTexture("$basetexture")

            if tex and tex.GetSize then
                local texW, texH = tex:GetSize()
                if texW and texH and cardW > 0 and cardH > 0 then
                    local ts = 0.25 * scaleFactor
                    local to = (noEdgeOffset and 0 or 10 * scaleFactor)
                    local ptw = tempMat:Width() * ts
                    local pth = tempMat:Height() * ts
                    local s = math.min(ptw / cardW, pth / cardH)
                    local cdw = cardW * s
                    local cdh = cardH * s
                    drawX = previewX + to + (ptw - cdw) / 2
                    drawY = previewY + to + (pth - cdh) / 2
                    drawW = cdw
                    drawH = cdh
                end
            end
        end
    end

    -- 计算插槽在卡面内的相对位置，转换为屏幕坐标
    local relX = (hollowX - cardMinX) / cardW
    local relY = (hollowY - cardMinY) / cardH
    local relW = hollowW / cardW
    local relH = hollowH / cardH

    local slotX = drawX + drawW * relX
    local slotY = drawY + drawH * relY
    local slotW = drawW * relW
    local slotH = drawH * relH

    -- 插图槽扩展：高度向下延伸3倍，宽度向右延伸2倍
    local expandedW = slotW * 2
    local expandedH = slotH * 3
    -- slotX 不变：只向右延伸
    slotW = expandedW
    -- slotY 不变：只向下延伸
    slotH = expandedH

    -- 保存插槽位置供外部使用（如卡牌预览图滚轮缩放）
    KARDS.CardEditor.Canvas._lastCardImageSlot = { x = slotX, y = slotY, w = slotW, h = slotH }

    -- 当插图为空且 hideNumbers 时，覆盖插槽区域（离屏渲染白色背景）
    if hideNumbers and (not appearance.imagePath or appearance.imagePath == "") then
        draw.RoundedBox(4, slotX, slotY, slotW, slotH, Color(255, 255, 255))
        return
    end

    -- 有插图时渲染
    if appearance.imagePath and appearance.imagePath ~= "" then
        local imgMat = Material(appearance.imagePath, "noclamp smooth")
        if imgMat and not imgMat:IsError() then
            -- 使用文件头解析的实际尺寸（避免 POT 纹理填充导致错误宽高）
            local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(appearance.imagePath)
            local imgW_orig = realW or imgMat:Width()
            local imgH_orig = realH or imgMat:Height()
            -- 保存图片原始尺寸供滚轮缩放使用
            KARDS.CardEditor.Canvas._lastCardImageSlot.texW = imgW_orig
            KARDS.CardEditor.Canvas._lastCardImageSlot.texH = imgH_orig
            -- 固定缩放比例 0.25（与卡牌模板一致），渲染原图后缩放
            local imgScale = 0.25 * scaleFactor * appearance.imageScale
            local imgW = imgW_orig * imgScale
            local imgH = imgH_orig * imgScale
            -- 插图在插槽内居中，加上拖拽偏移
            local imgX = slotX + (slotW - imgW) / 2 + appearance.imageOffsetX * scaleFactor
            local imgY = slotY + (slotH - imgH) / 2 + appearance.imageOffsetY * scaleFactor
            -- 裁剪到插槽区域
            render.SetScissorRect(slotX, slotY, slotX + slotW, slotY + slotH, true)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.SetMaterial(imgMat)
            surface.DrawTexturedRect(imgX, imgY, imgW, imgH)
            render.SetScissorRect(0, 0, 0, 0, false)
        end
    else
        -- 插图为空时显示深色占位背景
        draw.RoundedBox(4, slotX, slotY, slotW, slotH, Color(40, 40, 40))
        draw.SimpleText(T("editor.preview.no_illustration"), "SourceHan_Heavy_14", slotX + slotW / 2, slotY + slotH / 2, Color(100, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

-- 绘制卡牌模板（中层）
-- 模板位置说明：从预览图左上角偏移开始
local function DrawCardTemplate(appearance, previewX, previewY, previewW, previewH, scaleFactor, noEdgeOffset)
    local templatePath = GetTemplatePath(appearance)

    if templatePath and templatePath ~= "" then
        local templateMat = Material(templatePath)
        local templateScaleFactor = 0.25 * scaleFactor
        local templateOffset = noEdgeOffset and 0 or 10 * scaleFactor
        if templateMat and not templateMat:IsError() then
            local minX, minY, cardW, cardH = KARDS.CardEditor.Canvas.GetCardTextureBounds(templateMat)
            local tex = templateMat:GetTexture("$basetexture")

            if tex and tex.GetSize then
                local texW, texH = tex:GetSize()
                if texW and texH then
                    local previewTemplateW = templateMat:Width() * templateScaleFactor
                    local previewTemplateH = templateMat:Height() * templateScaleFactor
                    local scale = math.min(previewTemplateW / cardW, previewTemplateH / cardH)
                    local drawW = cardW * scale
                    local drawH = cardH * scale
                    local drawX = previewX + templateOffset + (previewTemplateW - drawW) / 2
                    local drawY = previewY + templateOffset + (previewTemplateH - drawH) / 2

                    surface.SetDrawColor(255, 255, 255, 255)
                    surface.SetMaterial(templateMat)
                    surface.DrawTexturedRectUV(drawX, drawY, drawW, drawH, minX / texW, minY / texH, (minX + cardW) / texW, (minY + cardH) / texH)
                end
            end

            if not tex or not tex.GetSize then
                local templateW = templateMat:Width() * templateScaleFactor
                local templateH = templateMat:Height() * templateScaleFactor
                surface.SetDrawColor(255, 255, 255, 255)
                surface.SetMaterial(templateMat)
                surface.DrawTexturedRect(previewX + templateOffset, previewY + templateOffset, templateW, templateH)
            end
        end
    end
end

-- ===================== DrawCardPreview 主函数 =====================

-- 卡牌预览图绘制函数 - 可根据指定数据在任何地方绘制
-- 参数说明：
--   appearance: 卡牌外观数据
--   previewX: 预览图左上角X坐标
--   previewY: 预览图左上角Y坐标
--   previewW: 预览图宽度
--   previewH: 预览图高度
-- 注：缩放因子已固定为外貌属性编辑器所使用的缩放逻辑，调用方无需传入。
-- 计算卡牌模板缩放因子（固定使用外貌属性编辑器的缩放逻辑）
local function ComputeCardScaleFactor(appearance, previewH)
    local scaleFactor = 1.0
    local templateKey = TemplateKeyOf(appearance)
    local templatePath = KARDS.CardEditor.Canvas.ImagePaths.template[templateKey]
    if not templatePath then
        templatePath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
    end
    if templatePath and templatePath ~= "" then
        local templateMat = Material(templatePath)
        if templateMat and not templateMat:IsError() then
            local texH = templateMat:Height()
            scaleFactor = (previewH - 10) / (texH * 0.25)
            scaleFactor = math.max(0.3, math.min(scaleFactor, 3.0))
        end
    end
    return scaleFactor
end

-- 导出供 cl_ca_appearance_editors.lua 等外部模块使用
KARDS.CardEditor.Canvas.ComputeCardScaleFactor = ComputeCardScaleFactor

-- 计算卡牌模板的视觉中心X坐标（模板居中，而非预览框居中；预览器/渲染器共用）
local function ComputeCardCenterX(appearance, previewX, previewW, scaleFactor, noEdgeOffset)
    local cardCenterX = previewX + previewW / 2  -- 默认回退
    local templatePath = GetTemplatePath(appearance)
    if templatePath and templatePath ~= "" then
        local templateMat = Material(templatePath)
        if templateMat then
            local templateOffset = noEdgeOffset and 0 or 10 * scaleFactor
            local templateScaleFactor = 0.25 * scaleFactor
            local previewTemplateW = templateMat:Width() * templateScaleFactor
            cardCenterX = previewX + templateOffset + previewTemplateW / 2
        end
    end
    return cardCenterX
end

-- 共享主绘制流程（2026-08-15 编辑器重构 7.5-5 收敛）：
-- 双版本共用边框/插图/模板/富文本绘制；
-- 名称/花费/国旗/攻防/类型/词条/描述/品质位置取传入 layout（LAYOUT.preview / LAYOUT.render）；
-- renderMode 区分离屏渲染的行为差异（3D2D 文字卡 hideNumbers 时词条/描述/攻防转 3D2D 叠加层）
local function DrawCardPreviewCommon(appearance, previewX, previewY, previewW, previewH, onlyTemplate, hideNumbers, noEdgeOffset, layout, renderMode)
    -- !!! 重要：previewH 必须为 TotalEditorH / 3，否则卡牌元素渲染将错位/异常 !!!
    -- 内部使用 math.floor(TotalEditorH / 3) 作为参考高度计算缩放因子，
    -- 传入的 previewW/previewH 仅用于绘制位置裁剪，不参与缩放计算。
    -- 所有调用方务必使用：local refH = math.floor(TotalEditorH / 3)
    -- 固定缩放：使用外貌属性编辑器的缩放逻辑
    -- 参考高度 = 编辑器实际内容高度 / 3（与 DrawPreviewArea 保持一致）
    -- 外貌数据规范化（2026-10-02）：悬停预览的缓存外貌可能字段不全，绘制前统一补默认值
    appearance = NormalizeAppearance(appearance)
    local referencePreviewH = math.floor((KARDS.CardEditor.Canvas.TotalEditorH or 720) / 3)
    local scaleFactor = ComputeCardScaleFactor(appearance, referencePreviewH)
    onlyTemplate = onlyTemplate or false
    hideNumbers = hideNumbers or false
    noEdgeOffset = noEdgeOffset or false

    local isCommandCard = appearance.cardType == "command" or appearance.cardType == "counter_command" or appearance.cardType == "headquarter"

    -- 1. 边框
    DrawCardBorder(previewX, previewY, previewW, previewH, scaleFactor, noEdgeOffset)

    -- 2. 插图（下层）
    if not onlyTemplate then
        DrawCardImage(appearance, previewX, previewY, previewW, previewH, scaleFactor, hideNumbers, noEdgeOffset)
    end

    -- 3. 模板（中层）
    DrawCardTemplate(appearance, previewX, previewY, previewW, previewH, scaleFactor, noEdgeOffset)

    if onlyTemplate then return end

    surface.SetDrawColor(255, 255, 255, 255)

    local cardCenterX = ComputeCardCenterX(appearance, previewX, previewW, scaleFactor, noEdgeOffset)

    -- 4. 名称
    local nameY = DrawCardName(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, layout)

    -- 5. 花费
    DrawCardCost(appearance, previewX, previewY, scaleFactor, isCommandCard, hideNumbers, layout)

    -- 6. 国旗（总部不绘制国籍）
    if appearance.cardType ~= "headquarter" then
        DrawCardCountry(appearance, previewX, previewY, previewW, scaleFactor, layout)
    end

    -- 7. 攻防 + 类型图标
    DrawCardStats(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hideNumbers, layout, renderMode)

    -- 8. 词条（预览模式始终绘制；离屏渲染模式 hideNumbers 时转 3D2D 叠加层）
    local hasKeywords = DrawCardKeywords(appearance, previewX, previewY, previewW, previewH, scaleFactor, cardCenterX, layout, renderMode and hideNumbers)

    -- 9. 描述（预览模式始终绘制；离屏渲染模式 hideNumbers 时转 3D2D 叠加层）
    DrawCardDescription(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hasKeywords, nameY, cardCenterX, layout, renderMode and hideNumbers)

    -- 10. 品质（总部不绘制品质）
    if appearance.cardType ~= "headquarter" then
        DrawCardQuality(appearance, previewX, previewY, previewW, previewH, scaleFactor, layout)
    end
end

-- 编辑器屏幕预览入口（preview 布局）
function KARDS.CardEditor.Canvas.DrawCardPreview(appearance, previewX, previewY, previewW, previewH, onlyTemplate, hideNumbers, noEdgeOffset)
    DrawCardPreviewCommon(appearance, previewX, previewY, previewW, previewH, onlyTemplate, hideNumbers, noEdgeOffset, LAYOUT.preview, false)
end

-- 离屏渲染专用入口（render 布局）：与预览器共用边框/插图/模板/富文本绘制，
-- 元素位置数值取 LAYOUT.render（独立于屏幕预览的多年调校值）
function KARDS.CardEditor.Canvas.DrawCardPreviewRender(appearance, previewX, previewY, previewW, previewH, onlyTemplate, hideNumbers, noEdgeOffset)
    DrawCardPreviewCommon(appearance, previewX, previewY, previewW, previewH, onlyTemplate, hideNumbers, noEdgeOffset, LAYOUT.render, true)
end

-- 离屏渲染（RenderAndSaveCard / GetCardMaterial / CleanupOldMaterials / SpawnTestEntity）
-- 已收敛至 canvas_editor/effect_editor/cl_canvas_editor.lua（2026-08-15 编辑器重构 7.5-1 删除本文件覆盖版死代码）
