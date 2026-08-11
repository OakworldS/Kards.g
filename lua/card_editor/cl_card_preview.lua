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
local keywordsForHighlight = KARDS.CardEditor.Data.KeywordsForHighlight

-- 引用全局词条映射表
local KeywordDisplayNames = KARDS.CardEditor.Data.KeywordDisplayNames
local booleanKeywordKeys = KARDS.CardEditor.Data.BooleanKeywordKeys
local numericKeywordKeys = KARDS.CardEditor.Data.NumericKeywordKeys

-- 数值文字统一颜色（近白色 C9C3A9，符合卡牌模板风格）：
-- 卡牌花费/行动花费/攻击/防御等所有白色数值文字统一使用
-- 与 3D2D 文字叠加层（cl_card_text_overlay.lua 的 COLOR_NUMBER）保持同色
local VALUE_TEXT_COLOR = Color(201, 195, 169)

-- 注册斜体字体用于 HTML <i> 标签
surface.CreateFont("Calibri_Italic_20", {
    font = "Calibri",
    size = 20,
    weight = 400,
    italic = true,
    antialias = true,
})

-- 根据外貌数据获取卡牌模板材质路径
local function GetTemplatePath(appearance)
    local templateKey = appearance.cardTemplate .. "_" .. appearance.cardType
    local templatePath = KARDS.CardEditor.Canvas.ImagePaths.template[templateKey]
    if not templatePath then
        templatePath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
    end
    return templatePath
end

local function GetTextSizeForFont(text, font)
    surface.SetFont(font)
    return surface.GetTextSize(text)
end

local function DrawRichText(text, x, y, defaultFont, defaultColor, xAlign, yAlign, maxWidth)
    if not text then return end
    defaultFont = defaultFont or "Calibri_20"
    defaultColor = defaultColor or Color(0, 0, 0)

    local segments = {}
    local currentPos = 1
    local textLength = #text

    while currentPos <= textLength do
        local foundKeyword = false
        local bestMatch = nil
        local bestMatchEnd = 0

        for _, keyword in ipairs(keywordsForHighlight) do
            local keywordStart, keywordEnd = string.find(text, keyword, currentPos, true)
            if keywordStart == currentPos then
                if (not bestMatch) or (keywordEnd > bestMatchEnd) then
                    bestMatch = keyword
                    bestMatchEnd = keywordEnd
                end
                foundKeyword = true
            end
        end

        if foundKeyword and bestMatch then
            local hasColon = false
            if (bestMatch == "部署" or bestMatch == "抉择") and bestMatchEnd + 1 <= textLength then
                if text:sub(bestMatchEnd + 1, bestMatchEnd + 1) == "：" then
                    bestMatchEnd = bestMatchEnd + 1
                    hasColon = true
                end
            end

            table.insert(segments, {
                text = text:sub(currentPos, bestMatchEnd),
                font = "SourceHan_Heavy_20",
                color = Color(0, 0, 0)
            })
            currentPos = bestMatchEnd + 1
        else
            local nextKeywordPos = textLength + 1
            for _, keyword in ipairs(keywordsForHighlight) do
                local keywordStart = string.find(text, keyword, currentPos, true)
                if keywordStart and keywordStart < nextKeywordPos then
                    nextKeywordPos = keywordStart
                end
            end

            local endPos = nextKeywordPos - 1
            if endPos >= currentPos then
                table.insert(segments, {
                    text = text:sub(currentPos, endPos),
                    font = defaultFont,
                    color = defaultColor
                })
            end
            currentPos = endPos + 1
        end
    end

    if maxWidth and maxWidth > 0 then
        local lineHeight = select(2, GetTextSizeForFont("测试", defaultFont))
        local currentX = x
        local currentY = y
        local startX = x

        for _, segment in ipairs(segments) do
            local segW, segH = GetTextSizeForFont(segment.text, segment.font)

            for char in string.gmatch(segment.text, "[%z\1-\127\194-\244][\128-\191]*") do
                local charW = GetTextSizeForFont(char, segment.font)
                if currentX + charW > startX + maxWidth and currentX > startX then
                    currentX = startX
                    currentY = currentY + lineHeight
                end
                draw.SimpleText(char, segment.font, currentX, currentY, segment.color, TEXT_ALIGN_LEFT, yAlign)
                currentX = currentX + charW
            end
        end
    else
        local currentX = x
        for _, segment in ipairs(segments) do
            draw.SimpleText(segment.text, segment.font, currentX, y, segment.color, xAlign, yAlign)
            local w = GetTextSizeForFont(segment.text, segment.font)
            currentX = currentX + w
        end
    end
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
                            return "卡牌对象"
                        elseif typeId == "g" then
                            return "数组"
                        elseif typeId == "f" then
                            return "函数"
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
    if seg.isKeyword or seg.bold then
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

local function DrawSpecialEffectRichText(text, x, y, xAlign, yAlign, fontSize)
    fontSize = fontSize or 20
    -- 替换 (内部变量名) 为 (初始值)
    text = string.gsub(text, "%(([%w_]+)%)", function(match)
        local val = FindVarByInternalName(match)
        if val then
            return "(" .. val .. ")"
        end
        return "(" .. match .. ")"
    end)
    -- 先处理转义的换行符
    local processedText = string.gsub(text, "\\n", "\n")
    -- 分割成行
    local lines = string.Explode("\n", processedText)

    local lineHeight = math.max(10, math.floor(18 * fontSize / 20))  -- 行间距随字号缩放

    for lineIdx, line in ipairs(lines) do
        -- 先解析 HTML 格式标签
        local formatSegs = ParseFormatTags(line)

        -- 对每个格式化片段再应用关键词高亮
        local finalSegs = {}
        for _, fseg in ipairs(formatSegs) do
            local segText = fseg.text
            local segLen = #segText
            local currentPos = 1

            while currentPos <= segLen do
                local matchFound = false
                local matchKeyword = nil
                local matchEnd = 0

                -- 在当前片段内查找关键词
                for _, keyword in ipairs(keywordsForHighlight) do
                    local kwLen = #keyword
                    if currentPos + kwLen - 1 <= segLen then
                        if segText:sub(currentPos, currentPos + kwLen - 1) == keyword then
                            matchKeyword = keyword
                            matchEnd = currentPos + kwLen - 1
                            -- 检查部署：或抉择：的情况
                            if (keyword == "部署" or keyword == "抉择") and matchEnd + 1 <= segLen then
                                if segText:sub(matchEnd + 1, matchEnd + 1) == "：" then
                                    matchEnd = matchEnd + 1
                                end
                            end
                            matchFound = true
                            break
                        end
                    end
                end

                if matchFound then
                    table.insert(finalSegs, {
                        text = segText:sub(currentPos, matchEnd),
                        isKeyword = true,
                        bold = fseg.bold,
                        italic = fseg.italic,
                    })
                    currentPos = matchEnd + 1
                else
                    -- 查找下一个关键词的位置
                    local nextKeywordPos = segLen + 1
                    for _, keyword in ipairs(keywordsForHighlight) do
                        local p = segText:find(keyword, currentPos, true)
                        if p and p < nextKeywordPos then
                            nextKeywordPos = p
                        end
                    end

                    -- 添加普通文本段
                    local endPos = nextKeywordPos - 1
                    if endPos >= currentPos then
                        table.insert(finalSegs, {
                            text = segText:sub(currentPos, endPos),
                            isKeyword = false,
                            bold = fseg.bold,
                            italic = fseg.italic,
                        })
                    end
                    currentPos = endPos + 1
                end
            end
        end

        -- 计算行总宽度
        local totalWidth = 0
        for _, seg in ipairs(finalSegs) do
            local font = PickDescSegmentFont(fontSize, seg)
            surface.SetFont(font)
            local w = surface.GetTextSize(seg.text)
            totalWidth = totalWidth + w
        end

        -- 绘制这一行
        local currentX = x - totalWidth / 2
        local currentY = y + (lineIdx - 1) * lineHeight

        for _, seg in ipairs(finalSegs) do
            local font = PickDescSegmentFont(fontSize, seg)
            surface.SetFont(font)
            local w, h = surface.GetTextSize(seg.text)
            draw.SimpleText(seg.text, font, currentX, currentY, Color(0, 0, 0), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            currentX = currentX + w
        end
    end
end

-- ===================== DrawCardPreview 子函数（预览器版本） =====================
-- 说明：预览器与渲染器使用各自独立的位置数值。
-- 以下无后缀函数为预览器版本，使用未调整±5 的原始位置数值；
-- 渲染器版本见同名函数加 _Render 后缀（用于离屏渲染，数值不同）。

-- 构建词条列表并返回 keywordsText 和 hasKeywords
local function BuildKeywordsList(appearance)
    local keywordsList = {}

    -- 普通词条（无数值）
    for _, key in ipairs(booleanKeywordKeys) do
        if table.HasValue(appearance.keywords, key) then
            if key == "pincer" and appearance.pincerValue and appearance.pincerValue ~= "" then
                table.insert(keywordsList, "钳击：" .. appearance.pincerValue)
            else
                table.insert(keywordsList, KeywordDisplayNames[key])
            end
        end
    end

    -- 带数值的词条（排除"倒计时"，不在预览图上显示）
    for _, key in ipairs(numericKeywordKeys) do
        if key ~= "countdown" and table.HasValue(appearance.keywords, key) and appearance.keywordValues and appearance.keywordValues[key] > 0 then
            table.insert(keywordsList, KeywordDisplayNames[key] .. appearance.keywordValues[key])
        end
    end

    -- 老兵词条：放在最前面
    if table.HasValue(appearance.keywords, "veteran") then
        table.insert(keywordsList, 1, KeywordDisplayNames.veteran)
    end

    local keywordsText = table.concat(keywordsList, "，")
    return keywordsText, keywordsText ~= ""
end

-- 绘制卡牌名称
-- 名称位置说明：普通卡位于预览图顶部向下35像素，指令卡位于预览图底部向上100像素
-- 返回 nameY 供 DrawCardDescription 使用
local function DrawCardName(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard)
    -- 名称位置计算独立于名称内容：指令/总部卡无名称（name 为空）时也返回位置，
    -- 供 DrawCardDescription（指令卡无词条时紧贴标题下方锚定）使用，避免 nameY=nil 算术崩溃
    local nameY
    if isCommandCard then
        -- 总部名称下移（下移量减半：原 25 降为 12.5）
        nameY = (appearance.cardType == "headquarter") and (previewY + previewH - 87.5 * scaleFactor) or (previewY + previewH - 100 * scaleFactor)
    else
        nameY = previewY + 35 * scaleFactor
    end
    if not (appearance.name and appearance.name ~= "") then return nameY end
    local nameColor = (appearance.nameIsBlack or isCommandCard) and Color(0, 0, 0) or Color(255, 255, 255)

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
        draw.SimpleText(appearance.name, nameFont, previewX + previewW / 2, nameY, nameColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    return nameY
end

-- 绘制卡牌花费（如果hideNumbers为false）
-- 花费位置说明：位于预览图左上角(35, 35)，居中对齐
local function DrawCardCost(appearance, previewX, previewY, scaleFactor, isCommandCard, hideNumbers)
    if hideNumbers or appearance.cardType == "headquarter" then return end

    local costText = tostring(appearance.cost)
    local costFont = #costText > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
    draw.SimpleText(costText, costFont, previewX + 35 * scaleFactor, previewY + 35 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- 绘制行动花费（非指令卡才绘制）
    -- 行动花费位置说明：位于花费数字右侧，(51, 45)，居中对齐
    -- 十位数以上用更小字号（18）避免与花费数字重叠
    if not isCommandCard then
        local actionCostText = tostring(appearance.actionCost)
        local actionCostFont = #actionCostText > 1 and "SourceHan_Heavy_18" or "SourceHan_Heavy_24"
        draw.SimpleText(actionCostText, actionCostFont, previewX + 51 * scaleFactor, previewY + 45 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

-- 绘制所属国图标（右上角）
-- 国旗位置说明：从预览图右侧向左偏移60像素，从顶部向下偏移20像素
local function DrawCardCountry(appearance, previewX, previewY, previewW, scaleFactor)
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
        surface.DrawTexturedRect(previewX + previewW - 60 * scaleFactor, previewY + 20 * scaleFactor, countryW, countryH)
    end
end

-- 绘制攻击力、防御力和卡牌类型图标
local function DrawCardStats(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hideNumbers)
    if hideNumbers then return end

    -- 总部：仅绘制防御力（不绘制攻击力/类型图标）；位置暂用防御位，可按需调整；防御力文字放大显示
    if appearance.cardType == "headquarter" then
        local hqDefenseText = tostring(appearance.defense)
        local hqDefenseFont = #hqDefenseText > 1 and "SourceHan_Heavy_56" or "SourceHan_Heavy_72"
        draw.SimpleText(hqDefenseText, hqDefenseFont, previewX + previewW - 150 * scaleFactor, previewY + previewH - 155 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        return
    end

    if isCommandCard then return end

    -- 绘制攻击力（偏下位置左侧）
    -- 攻击力位置说明：从预览图左侧偏移79.5像素，从底部向上偏移109.5像素
    local attackText = tostring(appearance.attack)
    local attackFont = #attackText > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
    draw.SimpleText(attackText, attackFont, previewX + 79.5 * scaleFactor, previewY + previewH - 109.5 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- 绘制防御力（偏下位置右侧）
    -- 防御力位置说明：从预览图右侧向左偏移88像素，从底部向上偏移109.5像素
    local defenseText = tostring(appearance.defense)
    local defenseFont = #defenseText > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
    draw.SimpleText(defenseText, defenseFont, previewX + previewW - 88 * scaleFactor, previewY + previewH - 109.5 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- 绘制卡牌类型图标（攻击力和防御力之间）
    -- 类型图标位置说明：预览图水平居中，从底部向上偏移125像素
    local cardTypeScaleFactor = 0.32 * scaleFactor
    local cardTypeIconPath = KARDS.CardEditor.Canvas.ImagePaths.cardType[appearance.cardType]
    if cardTypeIconPath then
        local cardTypeMat = Material(cardTypeIconPath)
        if cardTypeMat then
            local cardTypeW = cardTypeMat:Width() * cardTypeScaleFactor
            local cardTypeH = cardTypeMat:Height() * cardTypeScaleFactor
            surface.SetDrawColor(255, 255, 255, 255)
            surface.SetMaterial(cardTypeMat)
            surface.DrawTexturedRect(previewX + previewW / 2 - cardTypeW / 2, previewY + previewH - 125 * scaleFactor, cardTypeW, cardTypeH)
        end
    end
end

-- 词条位置说明：从预览图底部向上偏移78像素
local function DrawCardKeywords(appearance, previewX, previewY, previewW, previewH, scaleFactor, cardCenterX)
    local keywordsText, hasKeywords = BuildKeywordsList(appearance)
    if hasKeywords then
        local keywordsY = previewY + previewH - 78 * scaleFactor
        draw.SimpleText(keywordsText, "SourceHan_Heavy_20", cardCenterX, keywordsY, Color(0, 0, 0), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    return hasKeywords
end

-- 绘制卡牌描述
local function DrawCardDescription(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hasKeywords, nameY, cardCenterX)
    if not (appearance.specialEffect and appearance.specialEffect ~= "") then return end

    local descY
    if hasKeywords then
        -- 有词条时：紧靠词条正下方
        descY = (previewY + previewH - 78 * scaleFactor) + 20 * scaleFactor
    else
        -- 无词条时：
        if isCommandCard then
            -- 指令、反制指令：紧贴标题下方
            descY = nameY + 27 * scaleFactor
        else
            -- 单位模式：上移到词条区域（微移半行填补词条空缺）
            descY = previewY + previewH - 78 * scaleFactor
        end
    end
    DrawSpecialEffectRichText(appearance.specialEffect, cardCenterX, descY, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, appearance.descFontSize or 20)
end

-- 绘制品质图标（图片最底部）
-- 品质图标位置说明：预览图水平居中，从底部向上偏移23像素
local function DrawCardQuality(appearance, previewX, previewY, previewW, previewH, scaleFactor)
    local qualityScaleFactor = 0.4 * scaleFactor
    local qualityIconPath = KARDS.CardEditor.Canvas.ImagePaths.quality[appearance.quality]
    if not qualityIconPath then return end

    local qualityMat = Material(qualityIconPath)
    if qualityMat then
        local qualityW = qualityMat:Width() * qualityScaleFactor
        local qualityH = qualityMat:Height() * qualityScaleFactor
        surface.SetDrawColor(255, 255, 255, 255)
        surface.SetMaterial(qualityMat)
        surface.DrawTexturedRect(previewX + previewW / 2 - qualityW / 2, previewY + previewH - 23 * scaleFactor, qualityW, qualityH)
    end
end

-- ===================== DrawCardPreview 子函数（渲染器版本 _Render） =====================

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

    local templateKey = appearance.cardTemplate .. "_" .. appearance.cardType
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
        draw.SimpleText("无插图", "SourceHan_Heavy_14", slotX + slotW / 2, slotY + slotH / 2, Color(100, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
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

-- 绘制卡牌名称
-- 名称位置说明：普通卡位于预览图顶部向下25像素，指令卡位于预览图底部向上95像素（原110下移30后撤回15，共下移15）
-- 返回 nameY 供 DrawCardDescription 使用
local function DrawCardName_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard)
    -- 名称位置计算独立于名称内容：指令/总部卡无名称（name 为空）时也返回位置，
    -- 供 DrawCardDescription_Render（指令卡无词条时紧贴标题下方锚定）使用，避免 nameY=nil 算术崩溃
    local nameY
    if isCommandCard then
        -- 总部名称下移（下移量减半：原 25 降为 12.5）
        nameY = (appearance.cardType == "headquarter") and (previewY + previewH - 82.5 * scaleFactor) or (previewY + previewH - 95 * scaleFactor)
    else
        nameY = previewY + 25 * scaleFactor
    end
    if not (appearance.name and appearance.name ~= "") then return nameY end
    local nameColor = (appearance.nameIsBlack or isCommandCard) and Color(0, 0, 0) or Color(255, 255, 255)

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
        draw.SimpleText(appearance.name, nameFont, previewX + previewW / 2, nameY, nameColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    return nameY
end

-- 绘制卡牌花费（如果hideNumbers为false）
-- 花费位置说明：位于预览图左上角(25, 25)，居中对齐
local function DrawCardCost_Render(appearance, previewX, previewY, scaleFactor, isCommandCard, hideNumbers)
    if hideNumbers or appearance.cardType == "headquarter" then return end

    local costText = tostring(appearance.cost)
    local costFont = #costText > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
    draw.SimpleText(costText, costFont, previewX + 25 * scaleFactor, previewY + 25 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- 绘制行动花费（非指令卡才绘制）
    -- 行动花费位置说明：位于花费数字右侧，(41, 35)，居中对齐
    -- 十位数以上用更小字号（18）避免与花费数字重叠
    if not isCommandCard then
        local actionCostText = tostring(appearance.actionCost)
        local actionCostFont = #actionCostText > 1 and "SourceHan_Heavy_18" or "SourceHan_Heavy_24"
        draw.SimpleText(actionCostText, actionCostFont, previewX + 41 * scaleFactor, previewY + 35 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

-- 绘制所属国图标（右上角）
-- 国旗位置说明：从预览图右侧向左偏移50像素，从顶部向下偏移15像素
local function DrawCardCountry_Render(appearance, previewX, previewY, previewW, scaleFactor)
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
        surface.DrawTexturedRect(previewX + previewW - 50 * scaleFactor, previewY + 15 * scaleFactor, countryW, countryH)
    end
end

-- 绘制攻击力、防御力和卡牌类型图标
-- 3D2D 文字卡（hideNumbers）：攻防数字转由 3D2D 叠加层实时绘制（不烘焙进纹理），
-- 但卡牌类型图标仍保留在纹理上（纹理分工：类型/品质/名称/国籍在纹理，词条/效果/攻防/花费转 3D2D）
local function DrawCardStats_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hideNumbers)
    -- 总部：仅绘制防御力（不绘制攻击力/类型图标）；位置与屏幕预览一致（右下角 -150/-155），可按需调整；防御力文字放大显示
    if appearance.cardType == "headquarter" then
        if not hideNumbers then
            local hqDefenseText = tostring(appearance.defense)
            local hqDefenseFont = #hqDefenseText > 1 and "SourceHan_Heavy_56" or "SourceHan_Heavy_72"
            draw.SimpleText(hqDefenseText, hqDefenseFont, previewX + previewW - 150 * scaleFactor, previewY + previewH - 155 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        return
    end

    -- 攻防数字（指令卡不画；hideNumbers 时不烘焙，转 3D2D 叠加层绘制）
    if not isCommandCard and not hideNumbers then
        -- 绘制攻击力（偏下位置左侧）
        -- 攻击力位置说明：从预览图左侧偏移70.5像素，从底部向上偏移105.5像素
        local attackText = tostring(appearance.attack)
        local attackFont = #attackText > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
        draw.SimpleText(attackText, attackFont, previewX + 70.5 * scaleFactor, previewY + previewH - 105.5 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        -- 绘制防御力（偏下位置右侧）
        -- 防御力位置说明：从预览图右侧向左偏移73像素，从底部向上偏移105.5像素
        local defenseText = tostring(appearance.defense)
        local defenseFont = #defenseText > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
        draw.SimpleText(defenseText, defenseFont, previewX + previewW - 73 * scaleFactor, previewY + previewH - 105.5 * scaleFactor, VALUE_TEXT_COLOR, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- 卡牌类型图标（攻击力和防御力之间；指令卡不画；hideNumbers 时仍保留在纹理）
    if isCommandCard then return end
    -- 类型图标位置说明：预览图水平居中并相对中心右移2像素，从底部向上偏移119像素
    local cardTypeScaleFactor = 0.32 * scaleFactor
    local cardTypeIconPath = KARDS.CardEditor.Canvas.ImagePaths.cardType[appearance.cardType]
    if cardTypeIconPath then
        local cardTypeMat = Material(cardTypeIconPath)
        if cardTypeMat then
            local cardTypeW = cardTypeMat:Width() * cardTypeScaleFactor
            local cardTypeH = cardTypeMat:Height() * cardTypeScaleFactor
            surface.SetDrawColor(255, 255, 255, 255)
            surface.SetMaterial(cardTypeMat)
            surface.DrawTexturedRect(previewX + previewW / 2 - cardTypeW / 2 + 2 * scaleFactor, previewY + previewH - 119 * scaleFactor, cardTypeW, cardTypeH)
        end
    end
end

-- 词条位置说明：从预览图底部向上偏移75像素
-- 3D2D 文字卡（hideNumbers）：词条转由 3D2D 叠加层实时绘制（不烘焙进纹理）
local function DrawCardKeywords_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor, cardCenterX, hideNumbers)
    if hideNumbers then return false end
    local keywordsText, hasKeywords = BuildKeywordsList(appearance)
    if hasKeywords then
        local keywordsY = previewY + previewH - 75 * scaleFactor
        draw.SimpleText(keywordsText, "SourceHan_Heavy_20", cardCenterX, keywordsY, Color(0, 0, 0), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    return hasKeywords
end

-- 绘制卡牌描述
-- 3D2D 文字卡（hideNumbers）：效果描述转由 3D2D 叠加层实时绘制（不烘焙进纹理）
local function DrawCardDescription_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hasKeywords, nameY, cardCenterX, hideNumbers)
    if hideNumbers then return end
    if not (appearance.specialEffect and appearance.specialEffect ~= "") then return end

    local descY
    if hasKeywords then
        -- 有词条时：紧靠词条正下方
        descY = (previewY + previewH - 75 * scaleFactor) + 20 * scaleFactor
    else
        -- 无词条时：
        if isCommandCard then
            -- 指令、反制指令：紧贴标题下方
            descY = nameY + 35 * scaleFactor
        else
            -- 单位模式：上移到词条区域（微移半行填补词条空缺）
            descY = previewY + previewH - 75 * scaleFactor
        end
    end
    DrawSpecialEffectRichText(appearance.specialEffect, cardCenterX, descY, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, appearance.descFontSize or 20)
end

-- 绘制品质图标（图片最底部）
-- 品质图标位置说明：预览图水平居中，从底部向上偏移20像素
local function DrawCardQuality_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor)
    local qualityScaleFactor = 0.4 * scaleFactor
    local qualityIconPath = KARDS.CardEditor.Canvas.ImagePaths.quality[appearance.quality]
    if not qualityIconPath then return end

    local qualityMat = Material(qualityIconPath)
    if qualityMat then
        local qualityW = qualityMat:Width() * qualityScaleFactor
        local qualityH = qualityMat:Height() * qualityScaleFactor
        surface.SetDrawColor(255, 255, 255, 255)
        surface.SetMaterial(qualityMat)
        surface.DrawTexturedRect(previewX + previewW / 2 - qualityW / 2, previewY + previewH - 20 * scaleFactor, qualityW, qualityH)
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
    local templateKey = appearance.cardTemplate .. "_" .. appearance.cardType
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

function KARDS.CardEditor.Canvas.DrawCardPreview(appearance, previewX, previewY, previewW, previewH, onlyTemplate, hideNumbers, noEdgeOffset)
    -- !!! 重要：previewH 必须为 TotalEditorH / 3，否则卡牌元素渲染将错位/异常 !!!
    -- 内部使用 math.floor(TotalEditorH / 3) 作为参考高度计算缩放因子，
    -- 传入的 previewW/previewH 仅用于绘制位置裁剪，不参与缩放计算。
    -- 所有调用方务必使用：local refH = math.floor(TotalEditorH / 3)
    -- 固定缩放：使用外貌属性编辑器的缩放逻辑
    -- 参考高度 = 编辑器实际内容高度 / 3（与 DrawPreviewArea 保持一致）
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

    -- 计算卡牌模板的视觉中心X坐标（模板居中，而非预览框居中）
    local cardCenterX = previewX + previewW / 2  -- 默认回退
    local templateKey = appearance.cardTemplate .. "_" .. appearance.cardType
    local templatePath = KARDS.CardEditor.Canvas.ImagePaths.template[templateKey]
    if not templatePath then
        templatePath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
    end
    if templatePath and templatePath ~= "" then
        local templateMat = Material(templatePath)
        if templateMat then
            local templateOffset = noEdgeOffset and 0 or 10 * scaleFactor
            local templateScaleFactor = 0.25 * scaleFactor
            local previewTemplateW = templateMat:Width() * templateScaleFactor
            cardCenterX = previewX + templateOffset + previewTemplateW / 2
        end
    end

    -- 4. 名称
    local nameY = DrawCardName(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard)

    -- 5. 花费
    DrawCardCost(appearance, previewX, previewY, scaleFactor, isCommandCard, hideNumbers)

    -- 6. 国旗（总部不绘制国籍）
    if appearance.cardType ~= "headquarter" then
        DrawCardCountry(appearance, previewX, previewY, previewW, scaleFactor)
    end

    -- 7. 攻防 + 类型图标
    DrawCardStats(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hideNumbers)

    -- 8. 词条
    local hasKeywords = DrawCardKeywords(appearance, previewX, previewY, previewW, previewH, scaleFactor, cardCenterX)

    -- 9. 描述
    DrawCardDescription(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hasKeywords, nameY, cardCenterX)

    -- 10. 品质（总部不绘制品质）
    if appearance.cardType ~= "headquarter" then
        DrawCardQuality(appearance, previewX, previewY, previewW, previewH, scaleFactor)
    end
end

-- 离屏渲染专用入口：与预览器共用边框/插图/模板/富文本绘制，
-- 但名称/花费/国旗/攻防/类型/词条/描述/品质使用 _Render 版本（独立位置数值）。
function KARDS.CardEditor.Canvas.DrawCardPreviewRender(appearance, previewX, previewY, previewW, previewH, onlyTemplate, hideNumbers, noEdgeOffset)
    -- !!! 重要：previewH 必须为 TotalEditorH / 3，否则卡牌元素渲染将错位/异常 !!!
    -- 内部使用 math.floor(TotalEditorH / 3) 作为参考高度计算缩放因子，
    -- 传入的 previewW/previewH 仅用于绘制位置裁剪，不参与缩放计算。
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

    -- 计算卡牌模板的视觉中心X坐标（模板居中，而非预览框居中）
    local cardCenterX = previewX + previewW / 2  -- 默认回退
    local templateKey = appearance.cardTemplate .. "_" .. appearance.cardType
    local templatePath = KARDS.CardEditor.Canvas.ImagePaths.template[templateKey]
    if not templatePath then
        templatePath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
    end
    if templatePath and templatePath ~= "" then
        local templateMat = Material(templatePath)
        if templateMat then
            local templateOffset = noEdgeOffset and 0 or 10 * scaleFactor
            local templateScaleFactor = 0.25 * scaleFactor
            local previewTemplateW = templateMat:Width() * templateScaleFactor
            cardCenterX = previewX + templateOffset + previewTemplateW / 2
        end
    end

    -- 4. 名称
    local nameY = DrawCardName_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard)

    -- 5. 花费
    DrawCardCost_Render(appearance, previewX, previewY, scaleFactor, isCommandCard, hideNumbers)

    -- 6. 国旗（总部不绘制国籍）
    if appearance.cardType ~= "headquarter" then
        DrawCardCountry_Render(appearance, previewX, previewY, previewW, scaleFactor)
    end

    -- 7. 攻防 + 类型图标
    DrawCardStats_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hideNumbers)

    -- 8. 词条
    local hasKeywords = DrawCardKeywords_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor, cardCenterX, hideNumbers)

    -- 9. 描述
    DrawCardDescription_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor, isCommandCard, hasKeywords, nameY, cardCenterX, hideNumbers)

    -- 10. 品质（总部不绘制品质）
    if appearance.cardType ~= "headquarter" then
        DrawCardQuality_Render(appearance, previewX, previewY, previewW, previewH, scaleFactor)
    end
end

-- 动态材质缓存
KARDS.CardEditor.Canvas.DynamicMaterials = KARDS.CardEditor.Canvas.DynamicMaterials or {}

-- 真正的离屏渲染函数
local function RenderToRenderTarget(appearance, rtName, width, height, hideNumbers)
    -- 获取或创建渲染目标
    local rt = GetRenderTarget(rtName, width, height)
    if not rt then
        print("[KARDS] 无法创建渲染目标: " .. rtName)
        return nil
    end

    -- 推送到渲染目标
    render.PushRenderTarget(rt)
        -- 清除渲染目标：alpha 清为 255，并禁用后续绘制的 alpha 写入
        -- （OverrideAlphaWriteEnable true,false）→ RT 全图 alpha 恒为 255，
        -- 保存的卡面 PNG 完全不透明（修复卡面透明度为 0：组卡卡面材质
        -- 渲染为全透明而露出卡背图片）
        render.Clear(0, 0, 0, 255, true, true)
        render.OverrideAlphaWriteEnable(true, false)

        -- 使用 cam.Start2D 来正确设置渲染上下文
        cam.Start2D()
            -- 绘制卡牌到渲染目标，使用正确的坐标，无边缘偏移
            KARDS.CardEditor.Canvas.DrawCardPreviewRender(appearance, 0, 0, width, height, false, hideNumbers, true)
        cam.End2D()

        render.OverrideAlphaWriteEnable(false)
    render.PopRenderTarget()

    return rt
end

-- 从渲染目标创建动态材质
local function CreateDynamicMaterialFromRT(rt, materialName)
    -- 创建或获取材质
    local mat = CreateMaterial(materialName, "UnlitGeneric", {
        ["$basetexture"] = rt:GetName(),
        ["$translucent"] = 1,
        ["$vertexalpha"] = 1,
        ["$vertexcolor"] = 1,
        ["$nolod"] = 1
    })

    return mat
end

-- 保存渲染目标为PNG
local function SaveRTToFile(rt, filePath)
    local success = false
    -- 先推送到渲染目标
    render.PushRenderTarget(rt)
        -- 捕获渲染目标内容：alpha=false 保存不含 alpha 通道的 PNG（完全不透明）。
        -- GMod 已知问题：render.Capture 的 PNG 模式配合 alpha=true 时前景会被渲染为透明
        -- （SetWriteDepthToDestAlpha 干扰），导致卡面纹理 alpha=0、组卡时露出卡背；
        -- 去掉 alpha 通道后加载即不透明，杜绝该问题。
        local data = render.Capture({
            format = "png",
            x = 0,
            y = 0,
            w = rt:Width(),
            h = rt:Height(),
            quality = 100,
            alpha = false
        })

        if data then
            file.Write(filePath, data)
            success = true
        end
    render.PopRenderTarget()

    return success
end

-- 离屏渲染并保存卡牌图片，同时创建动态材质
function KARDS.CardEditor.Canvas.RenderAndSaveCard(appearance)
    -- 定义保存目录：总部与普通卡并列（kards/headquarters/ vs kards/cards/）
    local saveDir = (appearance.cardType == "headquarter") and "kards/headquarters/" or "kards/cards/"
    -- 确保目录存在
    if not file.Exists(saveDir, "DATA") then
        file.CreateDir(saveDir)
    end

    -- 卡牌名称作为文件名（替换非法字符）
    local cardName = appearance.name or "unnamed_card"
    -- 替换非法字符
    local safeName = string.gsub(cardName, "[^%w]", "_")
    safeName = string.gsub(safeName, "%s+", "_")
    safeName = string.gsub(safeName, "^_+", "")
    safeName = string.gsub(safeName, "_+$", "")
    if safeName == nil or safeName == "" then
        safeName = "unnamed_card"
    end

    -- 渲染尺寸（与编辑器预览一致）
    local renderWidth = 300
    local renderHeight = 400

    -- 保存图片
    local timestamp = os.time()
    local fullFileName = safeName .. "_full_" .. timestamp .. ".png"
    local templateFileName = safeName .. "_template_" .. timestamp .. ".png"
    local fullPath = saveDir .. fullFileName
    local noNumbersPath = saveDir .. templateFileName

    print("[KARDS] 开始离屏渲染...")
    print("[KARDS] 渲染尺寸: " .. renderWidth .. "x" .. renderHeight)

    -- 1. 渲染完整卡牌
    local rtFullName = "Kards_Full_" .. safeName .. "_" .. timestamp
    local rtFull = RenderToRenderTarget(appearance, rtFullName, renderWidth, renderHeight, false)

    -- 2. 渲染模板卡牌
    local rtTemplateName = "Kards_Template_" .. safeName .. "_" .. timestamp
    local rtTemplate = RenderToRenderTarget(appearance, rtTemplateName, renderWidth, renderHeight, true)

    if rtFull and rtTemplate then
        -- 3. 保存到文件
        local success1 = SaveRTToFile(rtFull, fullPath)
        local success2 = SaveRTToFile(rtTemplate, noNumbersPath)

        -- 4. 创建动态材质
        local matFullName = "Kards_Mat_Full_" .. safeName .. "_" .. timestamp
        local matTemplateName = "Kards_Mat_Template_" .. safeName .. "_" .. timestamp

        local matFull = CreateDynamicMaterialFromRT(rtFull, matFullName)
        local matTemplate = CreateDynamicMaterialFromRT(rtTemplate, matTemplateName)

        -- 5. 缓存材质
        KARDS.CardEditor.Canvas.DynamicMaterials[safeName] = {
            full = matFull,
            template = matTemplate,
            timestamp = timestamp
        }

        print("[KARDS] 离屏渲染完成！")
        print("[KARDS] 完整卡牌已保存: garrysmod/data/" .. fullPath)
        print("[KARDS] 模板卡牌已保存: garrysmod/data/" .. noNumbersPath)
        print("[KARDS] 动态材质已创建: " .. matFullName .. ", " .. matTemplateName)

        -- 在聊天框显示
        if IsValid(LocalPlayer()) then
            LocalPlayer():ChatPrint("卡牌渲染完成！")
            LocalPlayer():ChatPrint("文件保存在 garrysmod/data/kards/cards/")
            LocalPlayer():ChatPrint("动态材质已创建，可在游戏中使用")
        end

        return {
            full = fullPath,
            template = noNumbersPath,
            fullMaterial = matFull,
            templateMaterial = matTemplate
        }
    else
        print("[KARDS] 离屏渲染失败！")
        return nil
    end
end

-- 获取卡牌的动态材质
function KARDS.CardEditor.Canvas.GetCardMaterial(cardName)
    local safeName = string.gsub(cardName, "[^%w]", "_")
    safeName = string.gsub(safeName, "%s+", "_")
    safeName = string.gsub(safeName, "^_+", "")
    safeName = string.gsub(safeName, "_+$", "")

    return KARDS.CardEditor.Canvas.DynamicMaterials[safeName]
end

-- 清理旧的动态材质
function KARDS.CardEditor.Canvas.CleanupOldMaterials(maxAgeSeconds)
    maxAgeSeconds = maxAgeSeconds or 3600 -- 默认1小时
    local now = os.time()

    for name, data in pairs(KARDS.CardEditor.Canvas.DynamicMaterials) do
        if data.timestamp and (now - data.timestamp) > maxAgeSeconds then
            KARDS.CardEditor.Canvas.DynamicMaterials[name] = nil
            print("[KARDS] 清理过期材质: " .. name)
        end
    end
end

-- 测试：在玩家面前生成一个带有动态材质的实体
function KARDS.CardEditor.Canvas.SpawnTestEntity(cardName)
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    -- 使用直接保存的 LastRenderedMaterial（更可靠）
    local mat = KARDS.CardEditor.Canvas.LastRenderedMaterial
    if not mat then
        print("[KARDS] 没有找到卡牌材质，请先渲染卡牌")
        return
    end

    -- 客户端也创建一个客户端实体来预览
    local tr = ply:GetEyeTraceNoCursor()
    local pos = tr.HitPos + tr.HitNormal * 5
    local ang = ply:GetAngles()
    ang.y = ang.y + 180

    -- 创建一个简单的客户端实体用于显示
    -- 使用更适合的模型或只用 DrawOverlay
    print("[KARDS] 创建测试卡牌显示")

    -- 保存数据到 hook 中
    local testDisplay = {
        pos = pos,
        ang = ang,
        mat = mat,
        start = CurTime(),
        duration = 5
    }

    -- 添加渲染 hook
    hook.Add("PostDrawOpaqueRenderables", "Kards_TestCardDisplay", function()
        if not testDisplay or CurTime() - testDisplay.start > testDisplay.duration then
            hook.Remove("PostDrawOpaqueRenderables", "Kards_TestCardDisplay")
            return
        end

        -- 绘制卡牌
        cam.Start3D2D(testDisplay.pos + testDisplay.ang:Up() * 0.1, testDisplay.ang, 0.1)
            surface.SetMaterial(testDisplay.mat)
            surface.SetDrawColor(255, 255, 255, 255)
            surface.DrawTexturedRect(-150, -200, 300, 400) -- 300x400 是渲染尺寸
        cam.End3D2D()
    end)

    -- 添加一些效果
    local effectdata = EffectData()
    effectdata:SetOrigin(pos)
    util.Effect("balloon_pop", effectdata)

    print("[KARDS] 已在你面前显示测试卡牌（5秒）")
end
