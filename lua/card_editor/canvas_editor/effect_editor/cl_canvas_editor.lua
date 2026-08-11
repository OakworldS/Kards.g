KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}

-- 滚轮缩放标记（CreateMove 中设值，Draw 中消费）
-- 用于卡牌插图预览和卡牌预览图的滚轮缩放
KARDS.CardEditor.Canvas._wheelZoomIn = false
KARDS.CardEditor.Canvas._wheelZoomOut = false

-- 展开的 BGM 国家配置（顶栏倒三角按钮展开的更多国家音乐组）
-- 与主行按钮同款圆钮样式；flags 图标缺失时自动回退为名称首字
-- iconMat 用 file.Exists 预判：文件存在才创建材质，否则为 nil（Material 对不存在文件返回的材质不可靠）
KARDS.CardEditor.Canvas.BGMExpandCountries = {
    { id = "finland", name = "芬兰", icon = "materials/kards/flags/finland.png", iconMat = file.Exists("materials/kards/flags/finland.png", "GAME") and Material("materials/kards/flags/finland.png", "noclamp smooth") or nil, color = Color(70, 110, 200), description = "冬季战争与继续战争中顽强抵抗苏联，以劣势兵力坚守国境，最终被迫停战" },
    { id = "italy", name = "意大利", icon = "materials/kards/flags/italy.png", iconMat = file.Exists("materials/kards/flags/italy.png", "GAME") and Material("materials/kards/flags/italy.png", "noclamp smooth") or nil, color = Color(40, 140, 70), description = "轴心国成员，北非与地中海战场的主力，1943 年倒戈后同盟国从意大利登陆欧洲" },
    { id = "australia", name = "澳大利亚", icon = "materials/kards/flags/australia.png", iconMat = file.Exists("materials/kards/flags/australia.png", "GAME") and Material("materials/kards/flags/australia.png", "noclamp smooth") or nil, color = Color(30, 60, 160), description = "英联邦军队重要成员，活跃于北非、太平洋与欧洲战场，本土在珊瑚海与巴布亚挫败日军攻势" },
    { id = "france", name = "法国", icon = "materials/kards/flags/france.png", iconMat = file.Exists("materials/kards/flags/france.png", "GAME") and Material("materials/kards/flags/france.png", "noclamp smooth") or nil, color = Color(50, 90, 200), description = "1940 年本土沦陷，戴高乐领导的自由法国与抵抗运动坚持抗战，随盟军解放巴黎" },
    { id = "poland", name = "波兰", icon = "materials/kards/flags/poland.png", iconMat = file.Exists("materials/kards/flags/poland.png", "GAME") and Material("materials/kards/flags/poland.png", "noclamp smooth") or nil, color = Color(190, 40, 40), description = "1939 年遭德苏两面夹击，亡国后流亡政府与本土抵抗运动坚持斗争，直至战后复国" }
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

-- 高级文本绘制函数：支持多字体、换行、关键词高亮
local keywordsForHighlight = KARDS.CardEditor.Data.KeywordsForHighlight

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

-- 注册斜体字体用于 HTML <i> 标签
surface.CreateFont("Calibri_Italic_20", {
    font = "Calibri",
    size = 20,
    weight = 400,
    italic = true,
    antialias = true,
})

-- 解析 HTML 加粗/斜体标签为格式化片段
-- 使用 plain=true 确保字符串字面匹配，避免任何 Lua pattern 干扰
local function ParseFormatTags(line)
    local segs = {}
    local pos = 1
    local bold, italic = false, false
    local len = #line
    while pos <= len do
        local earliest = len + 1
        local earliestEnd = 0
        local tagType = nil

        local b1, b2 = line:find("<b>", pos, true)
        if b1 and b1 < earliest then earliest = b1; earliestEnd = b2; tagType = "bOpen" end

        local cb1, cb2 = line:find("</b>", pos, true)
        if cb1 and cb1 < earliest then earliest = cb1; earliestEnd = cb2; tagType = "bClose" end

        local i1, i2 = line:find("<i>", pos, true)
        if i1 and i1 < earliest then earliest = i1; earliestEnd = i2; tagType = "iOpen" end

        local ci1, ci2 = line:find("</i>", pos, true)
        if ci1 and ci1 < earliest then earliest = ci1; earliestEnd = ci2; tagType = "iClose" end

        if earliest > len then
            table.insert(segs, {text = line:sub(pos), bold = bold, italic = italic})
            break
        end

        -- 添加标签前的文本
        if earliest > pos then
            table.insert(segs, {text = line:sub(pos, earliest - 1), bold = bold, italic = italic})
        end

        -- 切换格式状态
        if tagType == "bOpen" then bold = true
        elseif tagType == "bClose" then bold = false
        elseif tagType == "iOpen" then italic = true
        elseif tagType == "iClose" then italic = false
        end

        pos = earliestEnd + 1
    end
    return segs
end

-- 简化版本：针对卡牌预览的特殊效果绘制（支持 HTML <b> <i> 标签）
local function FindVarByInternalName_CE(internalName)
    if not internalName or internalName == "" then return nil end
    local editors = KARDS.CardEditor.IndependentNodeEditor and KARDS.CardEditor.IndependentNodeEditor.Editors
    if not editors then return nil end
    for _, editor in pairs(editors) do
        if editor.variables then
            for typeId, vars in pairs(editor.variables) do
                for _, vd in ipairs(vars) do
                    if vd.internalName == internalName then
                        if typeId == "n" then return tostring(vd.initialValue or 0)
                        elseif typeId == "p" then return tostring(vd.initialValue == true and "true" or "false")
                        elseif typeId == "t" then return vd.initialValue or ""
                        elseif typeId == "e" then return "卡牌对象"
                        elseif typeId == "g" then return "数组"
                        elseif typeId == "f" then return "函数"
                        else return tostring(vd.initialValue or "") end
                    end
                end
            end
        end
    end
    return nil
end

local function DrawSpecialEffectRichText(text, x, y, xAlign, yAlign)
    -- 替换 (内部变量名) 为 (初始值)
    text = string.gsub(text, "%(([%w_]+)%)", function(match)
        local val = FindVarByInternalName_CE(match)
        if val then return "(" .. val .. ")" end
        return "(" .. match .. ")"
    end)
    print("[HTML Debug] DrawSpecialEffectRichText received: [" .. tostring(text) .. "]")
    -- 先处理转义的换行符
    local processedText = string.gsub(text, "\\n", "\n")
    print("[HTML Debug] processedText: [" .. processedText .. "]")
    -- 分割成行
    local lines = string.Explode("\n", processedText)

    local lineHeight = 18  -- 减小行间距

    for lineIdx, line in ipairs(lines) do
        -- 先解析 HTML 格式标签
        local formatSegs = ParseFormatTags(line)
        print("[HTML Debug] line " .. lineIdx .. ": [" .. line .. "] -> " .. #formatSegs .. " segs")
        for si, seg in ipairs(formatSegs) do
            print("[HTML Debug]   seg " .. si .. ": text=[" .. seg.text .. "] bold=" .. tostring(seg.bold) .. " italic=" .. tostring(seg.italic))
        end

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
            local font = seg.isKeyword and "SourceHan_Heavy_20"
                or seg.bold and "SourceHan_Heavy_20"
                or seg.italic and "Calibri_Italic_20"
                or "Calibri_20"
            surface.SetFont(font)
            local w = surface.GetTextSize(seg.text)
            totalWidth = totalWidth + w
        end

        -- DEBUG: 输出最终绘制的片段
        print("[HTML Debug] Drawing line " .. lineIdx .. " with " .. #finalSegs .. " finalSegs:")
        for si, seg in ipairs(finalSegs) do
            print("[HTML Debug]   draw seg " .. si .. ": text=[" .. seg.text .. "] bold=" .. tostring(seg.bold) .. " italic=" .. tostring(seg.italic) .. " isKeyword=" .. tostring(seg.isKeyword))
        end

        -- 绘制这一行
        local currentX = x - totalWidth / 2
        local currentY = y + (lineIdx - 1) * lineHeight

        for _, seg in ipairs(finalSegs) do
            local font = seg.isKeyword and "SourceHan_Heavy_20"
                or seg.bold and "SourceHan_Heavy_20"
                or seg.italic and "Calibri_Italic_20"
                or "Calibri_20"
            surface.SetFont(font)
            local w, h = surface.GetTextSize(seg.text)
            draw.SimpleText(seg.text, font, currentX, currentY, Color(0, 0, 0), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            currentX = currentX + w
        end
    end
end

-- 从 CardAppearance 更新所有剩余输入框的状态（由 cl_appearance_editor.lua 定义）
-- 此函数在 cl_appearance_editor.lua 中已重写为简化版本，
-- 这里作为备用保留，确保加载顺序不影响功能

-- 从 veteranAppearance 更新老兵输入框的状态（由 cl_appearance_editor.lua 定义）
-- 此函数在 cl_appearance_editor.lua 中已重写为简化版本，
-- 这里作为备用保留，确保加载顺序不影响功能

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
    
    -- 渲染尺寸：必须等于模板缩放尺寸，不能固定 300x400。
    -- DrawCardPreview 内部元素（名称居中/国旗右上/攻防/词条）以 previewW/previewH 为基准布局，
    -- 模板则以"模板像素 * 0.25 * scaleFactor"为基准；两者仅当 previewW ≈ 模板缩放宽度时对齐。
    -- 固定 300x400 时（模板缩放宽约 172）元素与模板整体错位约 64px（表现为渲染图元素偏移、预览图正常）。
    -- 故按模板缩放尺寸渲染：名称中心 = previewW/2 = 模板缩放宽/2 = 模板中心，完全对齐。
    local renderRefH = math.floor((KARDS.CardEditor.Canvas.TotalEditorH or 720) / 3)
    local templateKey = appearance.cardTemplate .. "_" .. appearance.cardType
    local renderTemplatePath = KARDS.CardEditor.Canvas.ImagePaths.template[templateKey]
    if not renderTemplatePath then
        renderTemplatePath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
    end
    local renderWidth = 300
    local renderHeight = 400
    if renderTemplatePath and renderTemplatePath ~= "" then
        local renderTemplateMat = Material(renderTemplatePath)
        if renderTemplateMat and not renderTemplateMat:IsError() then
            local renderScaleFactor = KARDS.CardEditor.Canvas.ComputeCardScaleFactor(appearance, renderRefH)
            renderWidth = math.max(1, math.ceil(renderTemplateMat:Width() * 0.25 * renderScaleFactor))
            renderHeight = math.max(1, math.ceil(renderTemplateMat:Height() * 0.25 * renderScaleFactor))
        end
    end
    
    -- 保存图片
    local timestamp = os.time()
    local fullFileName = safeName .. "_full_" .. timestamp .. ".png"
    local templateFileName = safeName .. "_template_" .. timestamp .. ".png"
    local fullPath = saveDir .. fullFileName
    local noNumbersPath = saveDir .. templateFileName
    
    print("[KARDS] 开始真正的离屏渲染...")
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
        
        -- 记录本次渲染落盘路径（保存卡牌时"仅指向"复用，不再重复渲染；组卡/生成直接应用文件路径）。
        -- key = 渲染时卡标识（名称|类型|插图）：仅当当前卡与上次渲染的标识一致才复用路径，
        -- 避免同名卡（如总部"新卡牌"与普通卡"新卡牌"）渲染路径串用
        KARDS.CardEditor.Canvas.LastRenderedPaths = {
            full = fullPath,
            template = noNumbersPath,
            key = (appearance and (tostring(appearance.name) .. "|" .. tostring(appearance.cardType) .. "|" .. tostring(appearance.imagePath))) or "",
        }
        
        return {
            full = fullPath,
            template = noNumbersPath,
            fullMaterial = matFull,
            templateMaterial = matTemplate,
            renderWidth = renderWidth,
            renderHeight = renderHeight,
        }
    else
        print("[KARDS] 离屏渲染失败！")
        return nil
    end
end

--[[
    确保当前卡牌的外观纹理已渲染落盘（保存卡牌前调用）：
    - 已点过「渲染」按钮（LastRenderedPaths 存在且文件仍在）→ 仅指向，不重复渲染；
    - 未渲染过 → 立即离屏渲染并保存 PNG（耗时一次性，保存后组卡/生成直接引用文件路径）。
    @return table|nil { full, template, w, h }（DATA 相对路径 + 渲染像素尺寸）
]]
function KARDS.CardEditor.Canvas.EnsureCardTextures()
    local app = KARDS.CardEditor.Canvas.CardAppearance
    local key = app and (tostring(app.name) .. "|" .. tostring(app.cardType) .. "|" .. tostring(app.imagePath)) or ""
    local paths = KARDS.CardEditor.Canvas.LastRenderedPaths
    -- 仅当缓存路径属于当前卡（标识一致）且文件仍在时才复用，否则重新渲染（防止同名卡串用）
    if paths and paths.key == key and file.Exists(paths.full, "DATA") and file.Exists(paths.template, "DATA") then
        local size = KARDS.CardEditor.Canvas.LastRenderedCardSize
        return {
            full = paths.full,
            template = paths.template,
            w = size and size.w or 300,
            h = size and size.h or 400,
        }
    end
    local result = KARDS.CardEditor.Canvas.RenderAndSaveCard(KARDS.CardEditor.Canvas.CardAppearance)
    if not result then return nil end
    KARDS.CardEditor.Canvas.LastRenderedMaterial = result.fullMaterial
    KARDS.CardEditor.Canvas.LastRenderedTemplateMaterial = result.templateMaterial
    KARDS.CardEditor.Canvas.LastRenderedCardSize = { w = result.renderWidth or 300, h = result.renderHeight or 400 }
    return {
        full = result.full,
        template = result.template,
        w = result.renderWidth or 300,
        h = result.renderHeight or 400,
    }
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

-- 生成：在玩家面前生成实际卡牌模型实体（basic_card），
-- 使其 front(0)/back(1)/side(2) 三个纹理槽分别应用渲染出的卡面/卡背纹理。
-- 基础卡 manifest 中三子网格 image_path 相同（共用占位纹理），无法靠同名材质
-- 覆盖，改为预填前置模组的 MaterialCache（cacheKey = modelID|子网格序号|imagePath），
-- 各槽使用独立材质对象；随后请求服务端生成实体，客户端 Draw 重建 renderable 时
-- 命中预填缓存，三槽各得其所。
-- mode：缺省 "full"（全图像生成：完整卡面，属性文字烘焙进纹理）；
--       "3d2d"（3D2D文字卡生成：无属性文字模板卡面 + 3D2D 文字实时悬浮叠加，
--        服务端回传实体后由 cl_card_text_overlay.lua 注册本地数据）。
function KARDS.CardEditor.Canvas.SpawnTestEntity(app, mode)
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    mode = mode or "full"

    -- 前置模组可用性检查（MaterialCache/ClearCache 由 cl_runtime.lua 提供）
    if not PMXStaticImporter or not PMXStaticImporter.MaterialCache or not PMXStaticImporter.ClearCache then
        print("[KARDS] 前置模组 PMX Static Model Importer 未加载，无法生成卡牌模型")
        return
    end

    -- 卡面材质选择：全图像 = 完整卡面动态材质；3D2D 文字卡 = 无属性文字的模板卡面（hideNumbers 离屏渲染）
    local matFront
    if mode == "3d2d" then
        matFront = KARDS.CardEditor.Canvas.LastRenderedTemplateMaterial
        if not matFront then
            print("[KARDS] 3D2D文字卡需要「无属性文字」模板卡面，请先点击渲染按钮（生成模板卡面）")
            return
        end
    else
        matFront = KARDS.CardEditor.Canvas.LastRenderedMaterial
        if not matFront then
            print("[KARDS] 没有找到卡牌材质，请先渲染卡牌")
            return
        end
    end

    -- 卡背：materials/kards/cardbacks/<country>.png（与预览区一致，缺失时回退卡面）
    local countryName = tostring(app and app.country or ""):lower()
    local cardbackPath = "materials/kards/cardbacks/" .. countryName .. ".png"
    local matBack = Material(cardbackPath, "vertexlitgeneric noclamp smooth")
    if not matBack or matBack:IsError() then
        matBack = matFront
    end

    -- front 槽专用材质：LastRenderedMaterial 是给 surface 2D 绘制用的动态材质，
    -- 带 $vertexcolor=1/$vertexalpha=1/$translucent=1，而前置 mesh 顶点流仅 pos3+normal3+uv2
    -- （无颜色流），直接使用会读取垃圾颜色/alpha 导致 front 面透明、透出背面卡背
    -- （表现为"双面都是卡背"）。故为 mesh 重建材质：
    --  - 去掉 $vertexcolor/$vertexalpha（无颜色流）
    --  - 不用 $translucent（RT 背景被 render.Clear 清为 alpha=0，$translucent 会整体混合透明；
    --    且 front 子网格 translucent=false 在 opaque pass 渲染）
    --  - 改用 $alphatest 按 alpha 裁剪：卡面区域 alpha=255 显示，背景 alpha=0 裁掉
    -- RT 名用 GetTexture 取真实注册名（GetString 返回小写规范化值，直接用作 $basetexture
    -- 可能与 RT 注册名不匹配导致纹理解析失败）。
    local meshFrontMat = matFront
    local rtTexture = matFront:GetTexture("$basetexture")
    local rtName = rtTexture and rtTexture:GetName() or matFront:GetString("$basetexture")
    if rtName and rtName ~= "" then
        meshFrontMat = CreateMaterial(
            "Kards_Mesh_Front_" .. tostring(math.floor(SysTime() * 1000)),
            "UnlitGeneric",
            {
                ["$basetexture"] = rtName,
                ["$alphatest"] = 1,
                ["$alphatestreference"] = 0.5,
                ["$nolod"] = 1,
            }
        )
        print("[KARDS] front 槽 mesh 专用材质已创建，basetexture = " .. rtName)
    end

    -- 基础卡模型：3 子网格，front 卡面 / back 卡背 / side 侧面
    -- 前置 cl_runtime.lua 的 read_mesh_file 以 `for i = 1, submeshCount` 传 submeshIndex，
    -- 故 cacheKey 的序号段从 1 开始（对应 manifest.submeshes 数组顺序）。
    -- 为避免硬编码序号/占位图路径，直接读取 manifest 按名称匹配槽位。
    local modelID = "basic_card"

    -- 先清空旧缓存（销毁旧 renderable 与材质缓存），再预填，顺序不可颠倒
    PMXStaticImporter.ClearCache(modelID)
    local cache = PMXStaticImporter.MaterialCache

    -- 读取 manifest（DATA 优先，回退 GAME data_static 随包分发路径）
    local manifestPath = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    local manifestContent = file.Read(manifestPath, "DATA")
    if not manifestContent then
        manifestContent = file.Read("data_static/" .. manifestPath, "GAME")
    end
    local manifest = manifestContent and util.JSONToTable(manifestContent)
    if manifest and manifest.submeshes then
        for idx, submesh in ipairs(manifest.submeshes) do
            local subName = tostring(submesh.name or submesh.safe_name or "")
            local key = modelID .. "|" .. tostring(idx) .. "|" .. tostring(submesh.image_path or "")
            if subName == "front" then
                cache[key] = meshFrontMat -- front：卡面成品（mesh 专用材质，避免顶点流无颜色导致的透明/异常）
            elseif subName == "back" then
                cache[key] = matBack  -- back：卡背（side 按需求暂不填，走前置默认占位纹理）
            end
            print("[KARDS] 预填纹理槽 " .. idx .. " (" .. subName .. ") -> " .. key)
        end
    else
        print("[KARDS] 警告：读取 basic_card manifest 失败，无法预填纹理槽（" .. tostring(manifestPath) .. "）")
    end

    -- 视线前方定位（与旧临时显示一致）
    local tr = ply:GetEyeTraceNoCursor()
    local eye = ply:EyePos()
    -- 异常判定改为相对距离：未命中、或命中点距玩家过远（>3000，编辑器全屏 VGUI 射线可能射向虚空深处）。
    -- 注意不能用绝对 z 阈值（如 pos.z < -500）：虚空地图的地板平面就在 z≈-12287，
    -- 绝对阈值会把正常的地板命中误判为异常，回退位置（EyePos+Forward*100-25）反而
    -- 把卡牌埋入地板之下（z=-12310 < 地板 -12287）导致实体完全不可见
    local pos
    if not tr.Hit or (tr.HitPos - eye):Length() > 3000 or tr.HitPos.z > 100000 then
        pos = eye + ply:EyeAngles():Forward() * 100 -- 玩家视线正前方固定位置，保证卡牌进入视野
        print("[KARDS] 生成位置异常，已回退到视线前方（z=" .. string.format("%.1f", pos.z) .. "）")
    else
        pos = tr.HitPos + tr.HitNormal * 5
    end
    -- 兜底：任何情况下卡牌不低于命中平面/玩家视线高度 +5 单位，避免埋入地板/虚空底部
    local floorZ = (tr.Hit and tr.HitPos.z or eye.z) + 5
    if pos.z < floorZ then pos.z = floorZ end
    local ang = ply:GetAngles()
    ang.y = ang.y + 180

    -- 3D2D 文字卡：预存待绑定数据，服务端回传实体后由 cl_card_text_overlay 注册本地叠加
    if mode == "3d2d" and KARDS.CardTextOverlay then
        local cardSize = KARDS.CardEditor.Canvas.LastRenderedCardSize
        KARDS.CardTextOverlay._PendingLocal = {
            data = app,
            worldW = 7.2, -- basic_card manifest bounds 36x54 × 0.2（与 sent_kards_battle_card.KardsScale 一致）
            worldH = 10.8,
            renderW = cardSize and cardSize.w or 300,
            renderH = cardSize and cardSize.h or 400,
        }
    end

    -- 请求服务端生成实际卡牌模型实体（sent_kards_battle_card 固定应用 basic_card，
    -- 服务端负责替换上一次生成的预览实体），客户端 Draw 命中预填材质
    net.Start("KARDS_Editor_SpawnCard")
    net.WriteVector(pos)
    net.WriteAngle(ang)
    net.SendToServer()

    -- 添加一些效果
    local effectdata = EffectData()
    effectdata:SetOrigin(pos)
    util.Effect("balloon_pop", effectdata)

    print("[KARDS] 已生成实际卡牌模型（卡面/卡背/侧面纹理已应用渲染结果，模式：" .. mode .. "）")
end

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
KARDS.CardEditor.Canvas.ContextMenu = nil
KARDS.CardEditor.Canvas.CurrentPage = "appearance" -- "effect" or "appearance"
KARDS.CardEditor.Canvas.AppearanceEditorActive = false -- 卡牌外貌编辑器是否激活
-- 多选节点相关状态
KARDS.CardEditor.Canvas.SelectionState = {
    isSelecting = false,       -- 是否正在框选
    startX = 0,                -- 框选起始点X
    startY = 0,                -- 框选起始点Y
    selectedNodes = {},        -- 选中的节点列表
    deleteButton = nil,        -- 删除按钮状态
    deleteButtonVisible = false -- 删除按钮是否可见
}
KARDS.CardEditor.Canvas.ToggleAppearanceBtn = {
    x = 0,
    y = 0,
    width = 200,
    height = 40,
    text = "启动卡牌外貌编辑器",
    hovered = false
}

-- 文件菜单状态（卡牌编辑器只保存卡牌，效果由 INE 编辑器处理）
KARDS.CardEditor.Canvas.FileMenu = {
    visible = false,
    x = 0,
    y = 0,
    width = 280,
    height = 180,
    buttons = {
        {
            id = "save",
            text = "保存",
            x = 0,
            y = 0,
            width = 260,
            height = 30,
            hovered = false
        },
        {
            id = "load",
            text = "加载",
            x = 0,
            y = 0,
            width = 260,
            height = 30,
            hovered = false
        },
        {
            id = "delete",
            text = "删除",
            x = 0,
            y = 0,
            width = 260,
            height = 30,
            hovered = false
        },
        {
            id = "reset",
            text = "重置节点",
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
        name = "卡牌外貌属性编辑器",
        width = 40,
        height = 150
    },
    {
        id = "effect",
        name = "卡牌效果编辑器",
        width = 40,
        height = 150
    }
}



-- 保存窗口状态

KARDS.CardEditor.Canvas.LastInputPortClickTime = 0

-- 纹理边界计算结果缓存
local TextureBoundsCache = {}
local TextureBoundsCacheTimeout = 300

-- 自动裁切素材的透明空白，获取卡牌的实际有效区域
-- 优化版本：使用降采样策略提升大纹理性能
function KARDS.CardEditor.Canvas.GetCardTextureBounds(material)
    if not material then
        return 0, 0, 0, 0
    end
    
    local tex = material:GetTexture("$basetexture")
    local matName = material:GetName() or tostring(material)
    
    local cacheEntry = TextureBoundsCache[matName]
    local now = SysTime()
    if cacheEntry and (now - cacheEntry.timestamp) < TextureBoundsCacheTimeout then
        return cacheEntry.minX, cacheEntry.minY, cacheEntry.width, cacheEntry.height
    end
    
    if not tex or not tex.GetSize then
        local defaultW, defaultH = material:Width(), material:Height()
        TextureBoundsCache[matName] = { minX = 0, minY = 0, width = defaultW, height = defaultH, timestamp = now }
        return 0, 0, defaultW, defaultH
    end
    
    local w, h = tex:GetSize()
    if not w or not h then
        local defaultW, defaultH = material:Width(), material:Height()
        TextureBoundsCache[matName] = { minX = 0, minY = 0, width = defaultW, height = defaultH, timestamp = now }
        return 0, 0, defaultW, defaultH
    end
    
    -- 根据纹理尺寸动态计算采样步长
    -- 对于大纹理（>512），使用更大步长提升性能
    local step = 1
    local maxDimension = math.max(w, h)
    if maxDimension > 1024 then
        step = 8  -- 超大纹理：每 8 像素采样一次
    elseif maxDimension > 512 then
        step = 4  -- 大纹理：每 4 像素采样一次
    elseif maxDimension > 256 then
        step = 2  -- 中等纹理：每 2 像素采样一次
    end
    
    local minX, minY = w, h
    local maxX, maxY = 0, 0

    -- 第一阶段：降采样快速扫描，找到近似边界
    for x = 0, w - 1, step do
        for y = 0, h - 1, step do
            local r, g, b, a = tex:GetPixel(x, y)
            if a > 10 then
                minX = math.min(minX, x)
                minY = math.min(minY, y)
                maxX = math.max(maxX, x)
                maxY = math.max(maxY, y)
            end
        end
    end
    
    -- 第二阶段：如果使用了降采样，在近似边界的四条边带区域精细扫描
    -- 只扫描边界条带（宽 step 像素），修正粗扫描可能遗漏的边缘像素
    if step > 1 and maxX > 0 and maxY > 0 then
        local clampMinX = math.max(0, minX - step)
        local clampMaxX = math.min(w - 1, maxX + step)
        local clampMinY = math.max(0, minY - step)
        local clampMaxY = math.min(h - 1, maxY + step)
        
        -- 左侧边带：修正 minX / minY / maxY
        for x = clampMinX, minX do
            for y = clampMinY, clampMaxY do
                local r, g, b, a = tex:GetPixel(x, y)
                if a > 10 then
                    minX = math.min(minX, x)
                    minY = math.min(minY, y)
                    maxY = math.max(maxY, y)
                end
            end
        end
        
        -- 右侧边带：修正 maxX / minY / maxY
        for x = maxX, clampMaxX do
            for y = clampMinY, clampMaxY do
                local r, g, b, a = tex:GetPixel(x, y)
                if a > 10 then
                    maxX = math.max(maxX, x)
                    minY = math.min(minY, y)
                    maxY = math.max(maxY, y)
                end
            end
        end
        
        -- 上侧边带：修正 minY（跳过已被左右边带扫描的区域）
        for x = minX + 1, maxX - 1 do
            for y = clampMinY, minY do
                local r, g, b, a = tex:GetPixel(x, y)
                if a > 10 then
                    minY = math.min(minY, y)
                end
            end
        end
        
        -- 下侧边带：修正 maxY（跳过已被左右边带扫描的区域）
        for x = minX + 1, maxX - 1 do
            for y = maxY, clampMaxY do
                local r, g, b, a = tex:GetPixel(x, y)
                if a > 10 then
                    maxY = math.max(maxY, y)
                end
            end
        end
    end
    
    local boundW, boundH = maxX - minX, maxY - minY
    if boundW <= 0 or boundH <= 0 then
        minX, minY, boundW, boundH = 0, 0, w, h
    end
    
    TextureBoundsCache[matName] = { minX = minX, minY = minY, width = boundW, height = boundH, timestamp = now }
    return minX, minY, boundW, boundH
end

-- 模板空心区域缓存
local HollowBoundsCache = {}
local HollowBoundsCacheTimeout = 60

-- 获取模板纹理的空心区域（透明插图区域）的位置和尺寸
-- 返回: hollowX, hollowY, hollowW, hollowH（纹理像素坐标，相对于纹理左上角）
function KARDS.CardEditor.Canvas.GetTemplateHollowBounds(material)
    if not material then
        return 0, 0, 0, 0
    end

    local matName = material:GetName() or tostring(material)
    local cacheEntry = HollowBoundsCache[matName]
    local now = SysTime()
    if cacheEntry and (now - cacheEntry.timestamp) < HollowBoundsCacheTimeout then
        return cacheEntry.hollowX, cacheEntry.hollowY, cacheEntry.hollowW, cacheEntry.hollowH
    end

    local tex = material:GetTexture("$basetexture")
    if not tex or not tex.GetSize then
        local defaultW, defaultH = material:Width(), material:Height()
        HollowBoundsCache[matName] = { hollowX = 0, hollowY = 0, hollowW = defaultW, hollowH = defaultH, timestamp = now }
        return 0, 0, defaultW, defaultH
    end

    local w, h = tex:GetSize()
    if not w or not h then
        local defaultW, defaultH = material:Width(), material:Height()
        HollowBoundsCache[matName] = { hollowX = 0, hollowY = 0, hollowW = defaultW, hollowH = defaultH, timestamp = now }
        return 0, 0, defaultW, defaultH
    end

    -- 获取卡面边界
    local cardMinX, cardMinY, cardW, cardH = KARDS.CardEditor.Canvas.GetCardTextureBounds(material)
    local cardMaxX = cardMinX + cardW - 1
    local cardMaxY = cardMinY + cardH - 1

    -- 动态计算步长，大纹理用大步长快速扫描
    local step = 1
    local maxDimension = math.max(w, h)
    if maxDimension > 1024 then
        step = 8
    elseif maxDimension > 512 then
        step = 4
    elseif maxDimension > 256 then
        step = 2
    end

    local threshold = 0.8  -- 透明像素比例超过此值认为是空心区域

    -- === 垂直方向扫描：找到空心区域的上下边界 ===
    local hollowTopY = cardMinY
    local hollowBottomY = cardMaxY
    local foundTop = false
    local foundBottom = false

    -- 从顶部向下扫描，找到第一个大部分透明的行
    for y = cardMinY, cardMaxY, step do
        local transparentCount = 0
        local sampleCount = 0
        for x = cardMinX, cardMaxX, step do
            local r, g, b, a = tex:GetPixel(x, y)
            sampleCount = sampleCount + 1
            if a < 5 then
                transparentCount = transparentCount + 1
            end
        end
        if sampleCount > 0 and transparentCount / sampleCount > threshold then
            hollowTopY = y
            foundTop = true
            break
        end
    end

    -- 从底部向上扫描，找到最后一个大部分透明的行
    for y = cardMaxY, cardMinY, -step do
        local transparentCount = 0
        local sampleCount = 0
        for x = cardMinX, cardMaxX, step do
            local r, g, b, a = tex:GetPixel(x, y)
            sampleCount = sampleCount + 1
            if a < 5 then
                transparentCount = transparentCount + 1
            end
        end
        if sampleCount > 0 and transparentCount / sampleCount > threshold then
            hollowBottomY = y
            foundBottom = true
            break
        end
    end

    -- 如果大步长没找到，回退到整个卡面高度
    if not foundTop then hollowTopY = cardMinY end
    if not foundBottom then hollowBottomY = cardMaxY end

    -- 如果用了大步长，在边界附近精细扫描修正
    if step > 1 and foundTop and foundBottom then
        -- 修正上边界：从上方向下找
        local clampTop = math.max(cardMinY, hollowTopY - step)
        for y = clampTop, hollowTopY do
            local transparentCount = 0
            local sampleCount = 0
            for x = cardMinX, cardMaxX, step do
                local r, g, b, a = tex:GetPixel(x, y)
                sampleCount = sampleCount + 1
                if a < 5 then
                    transparentCount = transparentCount + 1
                end
            end
            if sampleCount > 0 and transparentCount / sampleCount > threshold then
                hollowTopY = y
                break
            end
        end

        -- 修正下边界：从下方向上找
        local clampBottom = math.min(cardMaxY, hollowBottomY + step)
        for y = clampBottom, hollowBottomY, -1 do
            local transparentCount = 0
            local sampleCount = 0
            for x = cardMinX, cardMaxX, step do
                local r, g, b, a = tex:GetPixel(x, y)
                sampleCount = sampleCount + 1
                if a < 5 then
                    transparentCount = transparentCount + 1
                end
            end
            if sampleCount > 0 and transparentCount / sampleCount > threshold then
                hollowBottomY = y
                break
            end
        end
    end

    -- === 水平方向扫描：在空心区域中间行找左右边界 ===
    local midY = math.floor((hollowTopY + hollowBottomY) / 2)
    local hollowLeftX = cardMinX
    local hollowRightX = cardMaxX
    local foundLeft = false
    local foundRight = false

    -- 从左向右扫描
    for x = cardMinX, cardMaxX, step do
        local r, g, b, a = tex:GetPixel(x, midY)
        if a < 5 then
            hollowLeftX = x
            foundLeft = true
            break
        end
    end

    -- 从右向左扫描
    for x = cardMaxX, cardMinX, -step do
        local r, g, b, a = tex:GetPixel(x, midY)
        if a < 5 then
            hollowRightX = x
            foundRight = true
            break
        end
    end

    -- 精细修正水平边界
    if step > 1 and foundLeft and foundRight then
        local clampLeft = math.max(cardMinX, hollowLeftX - step)
        for x = clampLeft, hollowLeftX do
            local r, g, b, a = tex:GetPixel(x, midY)
            if a < 5 then
                hollowLeftX = x
                break
            end
        end

        local clampRight = math.min(cardMaxX, hollowRightX + step)
        for x = clampRight, hollowRightX, -1 do
            local r, g, b, a = tex:GetPixel(x, midY)
            if a < 5 then
                hollowRightX = x
                break
            end
        end
    end

    if not foundLeft then hollowLeftX = cardMinX end
    if not foundRight then hollowRightX = cardMaxX end

    local hollowW = hollowRightX - hollowLeftX + 1
    local hollowH = hollowBottomY - hollowTopY + 1

    if hollowW <= 0 or hollowH <= 0 then
        hollowLeftX, hollowTopY = cardMinX, cardMinY
        hollowW, hollowH = cardW, cardH
    end

    HollowBoundsCache[matName] = {
        hollowX = hollowLeftX,
        hollowY = hollowTopY,
        hollowW = hollowW,
        hollowH = hollowH,
        timestamp = now
    }
    return hollowLeftX, hollowTopY, hollowW, hollowH
end

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
                title = "事件监测",
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
    { type = "trigger", name = "执行", color = Color(70, 130, 180), hasInput = true, hasOutput = true,
      config = "'使这个(这些)卡牌' {攻击、防御} {设置为、增加、减少} [] (n攻击力、n防御力)" },
    { type = "condition", name = "判断数量", color = Color(60, 179, 113), hasInput = true, hasOutput = true,
      config = "n'当' {敌方、友方} {单位数量、总部血量、不同国籍单位数、最大攻击力单位、最小攻击力单位、最大防御力单位、最小防御力单位} {=、>、<、>=、<=} [lib] (n比较结果、p布尔值)" },
    { type = "target_selector", name = "选择卡牌单位目标", color = Color(20, 90, 50), hasInput = true, hasOutput = true,
      config = "e'{指向一个、随机、所有} if 随机 then [] end {友方、敌方、场上} {单位、目标、总部} if 单位 then ':' {战斗机、坦克、轰炸机、炮兵、步兵} end (e选中的卡牌)" },
    { type = "loop", name = "循环", color = Color(255, 215, 0), hasInput = true, hasOutput = true,
      config = "'重复信号' [] '次' (n循环次数)" },
    { type = "card", name = "卡牌", color = Color(220, 20, 60), hasInput = true, hasOutput = true,
      config = "e'{抽取、复制、弃掉、开发、选择、爆牌、洗切卡组、洗入} if 抽取 then [] '张' {卡组顶、卡组底、随机、指定} '的卡牌' elseif 复制 then [] '张' {卡组顶、卡组底、随机、指定} '的卡牌' elseif 弃掉 then [] '张' {卡组顶、卡组底、随机、指定} '的卡牌' elseif 开发 then [] '次' {卡组中、卡组顶、卡组底、本国指令、本国精英指令、本国精英单位} '的牌' elseif 选择 then [] '次' '观星' elseif 爆牌 then [] '次' elseif 洗入 then {手牌中、指定的} if 手牌中 then {随机、指定} '的' [] '张牌' else [] '张牌' end end (e影响的卡牌)" },
    { type = "property", name = "特殊执行操作", color = Color(148, 0, 211), hasInput = true, hasOutput = true,
      config = "{随机排列所有} {单位、友方单位、敌方单位}" },
    { type = "event_monitor", name = "事件监测", color = Color(180, 100, 180), hasInput = true, hasOutput = true,
      config = "{友方、敌方} {目标、单位、总部、打出指令、触发反制、玩家、回合} if 总部 then '防御' '=' [] elseif 目标 or 单位 then {有变化的、触发} if 有变化的 then {属性、攻防、攻击、防御、行动花费} {变化了、增加了、减少了、为} '=' [] else {抑制、老兵、部署、触发、被动效果、转换、修复、开发、控制、免疫、情报、动员、奋战、守护、山地、亡计、伏击、倒计时、冲击、重甲、钳击、闪击、隐蔽、烟幕、协力} end elseif 打出指令 or 触发反制 then {时、的花费、的情报} if 的花费 or 的情报 then '=' [] end elseif 玩家 then {抽牌、额外抽牌、弃牌、爆牌} '=' [] '张时' elseif 回合 then {开始、结束} '时' end (t事件类型、e事件目标、p触发事件)" }
}

-- 当前编辑器模式
-- "unit" = 单位模式
-- "command" = 指令模式
-- "counter_command" = 反制指令模式
KARDS.CardEditor.Canvas.EditorMode = "unit"


KARDS.CardEditor.Canvas.UnitTypeRules = {

    ["战斗机"] = "可以攻击任意阵线的目标，且能够拦截敌方轰炸机攻击同一阵线的友军。无法具有烟幕",
    ["坦克"] = "可以在同一回合移动并攻击",
    ["轰炸机"] = "攻击除战斗机以外的目标时不会受到反击伤害，但被攻击时也不会造成反击伤害。可以攻击被守护的单位，但会被战斗机拦截",
    ["炮兵"] = "攻击时不会受到反击伤害，且可以攻击被守护的单位",
    ["步兵"] = "只能攻击相邻战线的敌人"
}

-- 术语悬停释义表（依据 readme 七、Kards 基本规则 7.1/7.2/7.3；zh-CN 键）
-- 供 select 下拉（DrawDropdown / DrawExpandedDropdowns）悬停选项时提示名词含义，
-- 便于玩家区分近义词（交战/战斗、压制/抑制、攻击/攻击力、弃掉/弃牌等）。
-- 匹配方式见 LookupTermTooltip：整词优先，其次取选项文本内最长包含的术语。
KARDS.CardEditor.Canvas.TermTooltips = {

    -- 7.1 综合规则（readme.md L114-139）
    ["总部"] = "游戏胜利条件是摧毁敌方总部",
    ["目标"] = "“目标”即为当前的前线、支援阵线的所有卡牌，包含总部",
    ["单位"] = "“单位”为当前前线、支援阵线的所有单位卡牌，这不包含总部",
    ["战斗"] = "当两个单位战斗时，对彼此造成等同于其攻击的伤害。这不算作攻击或对战，且无视单位类型规则",
    ["交战"] = "交战是指一个单位攻击另一个单位，无论是否造成伤害。攻击总部不算交战。交战计入单位类型规则和词条规则",
    ["撤退"] = "前线单位撤退时退回到支援阵线。若支援阵线已满或本就从支援阵线撤退，则返回所有者手牌",
    ["移动"] = "将单位移动至前线",
    ["攻击"] = "令单位攻击指定目标，使目标受到等同于该单位攻击力的伤害",
    ["反击"] = "当非单位所有者回合时，单位被攻击，使攻击者受到等同于该单位攻击力的伤害",
    ["部署"] = "部署效果会在单位被部署时触发",
    ["指令"] = "使用时一次性触发效果，然后移除",
    ["反制"] = "反制可在手中激活，敌方无法查看。激活后，敌方回合达成相应条件即可触发记述的效果",
    ["前线"] = "前线位于双方支援阵线之间，同一时间只允许一方占领。前线最多可容纳 5 个单位",
    ["支援阵线"] = "双方玩家均有其各自的支援阵线，可同时容纳四个单位。玩家不能将单位移动至对手的支援阵线",
    ["手牌"] = "手牌上限为 9 张，达到上限后无法增加手牌",
    ["卡组"] = "卡组必须携带 40 张牌",
    ["指挥点"] = "玩家每回合获得 1 个指挥点槽，直到达到 12 个。回合开始时指挥点会调整至与指挥点槽相等。指挥点槽最多可拥有 24 个",
    ["指挥点槽"] = "玩家每回合获得 1 个指挥点槽，直到达到 12 个。回合开始时指挥点会调整至与指挥点槽相等",
    ["士气伤害"] = "卡组为空时抽牌，总部会受到士气伤害。第一次失去 1，第二次失去 2，以此类推",
    ["重新调度"] = "重新调度发生在对局开始时，可更换一次起始卡牌：选择不想要的手牌并确认，然后抽取等量的卡牌替换。先手方开始 4 手牌，后手方开始 5 手牌",
    ["伤害"] = "造成伤害 = 攻击者攻击力 - 目标重甲等减伤；目标防御力 - 造成伤害 ≤ 0 时单位被消灭",
    ["加入战场"] = "使单位入场到本方支援阵线",
    ["加入前线"] = "使单位直接入场到前线",
    ["返回手牌"] = "使目标从场上返回其所有者手牌",
    ["召唤单位"] = "召唤一个单位入场到本方阵线",
    ["触发关键字效果"] = "触发目标单位的关键字效果（如亡计、倒计时），效果由节点编辑器配置",

    -- 7.2.1 效果能力（readme.md L145-156）
    ["被压制"] = "被压制的单位不能移动或攻击。压制会于单位所有者下个回合结束时移除",
    ["压制"] = "同“被压制”：被压制的单位不能移动或攻击。压制会于单位所有者下个回合结束时移除",
    ["被守护"] = "被守护单位只能被轰炸机和炮兵攻击",
    ["抑制"] = "被抑制的卡牌失去所有关键词和效果，同时重置其攻击力、最大防御力以及行动花费",
    ["触发"] = "在场时有特殊主动效果",
    ["被动效果"] = "在场时有特殊被动效果",
    ["转换"] = "转换会把一张牌换成新的一张卡牌。伤害、花费和其他效果都将重置",
    ["修复"] = "单位被完全修复时其防御力增加至防御力上限。防御力上限为基础防御力加上此前获得的增益数值",
    ["开发"] = "从特定卡池（对象(组)）中的随机 3 张牌（允许重复）中选择 1 张，并将其加入手牌",
    ["控制"] = "接管控制权后新控制者可随意使用被控制的单位，直到效果解除。接管控制权时，除非被控制的单位是唯一在前线的单位，否则会移至新控制者的支援阵线。只能控制敌方单位",
    ["免疫"] = "单位或总部具有免疫时不会受到伤害",
    ["老兵"] = "此类单位在满足卡面记述的条件后会升为老兵。升为老兵会重置花费、攻击力和防御力",
    ["老兵(精英)"] = "老兵的进阶状态：触发条件由单卡定义，进阶后会完全重置单位的基础属性（花费、攻击力、防御力），原有的增益和减益全部清除",
    ["情报"] = "情报 X：情报触发时能显示敌方 X 张手牌，最多 9",

    -- 7.2.2 / 7.2.3 战斗词条能力（readme.md L160-179）
    ["动员"] = "动员单位每回合开始时获得 +1+1，受到伤害后会失去动员",
    ["奋战"] = "奋战单位一回合中可以攻击两次",
    ["守护"] = "与守护单位相邻的非守护单位无法被轰炸机和炮兵以外的单位攻击",
    ["山地"] = "山地单位部署或加入战场时，每有一个其他友方山地单位，获得一次 +1+1",
    ["亡计"] = "亡计效果会在单位被消灭时触发",
    ["伏击"] = "伏击单位每回合首次被攻击时会首先造成反击伤害。若敌方单位因此被消灭，则其无法对伏击单位造成伤害",
    ["倒计时"] = "倒计时结束后此单位将触发一个事件，每回合 -1",
    ["冲击"] = "冲击单位首次攻击时被攻击单位不会造成任何反击伤害。冲击单位攻击单位后移除冲击",
    ["重甲"] = "重甲单位交战时受到的伤害减少 X。每个单位最多可拥有 3 重甲",
    ["钳击"] = "部署钳击单位时可以选择另一个友方单位作为钳击同伴，两者将具有钳击加成，直到其中一个单位离场或失去钳击",
    ["闪击"] = "闪击单位可以在进入战场的回合行动（移动/攻击）",
    ["隐蔽"] = "隐蔽单位入场时背面朝上，揭示前不受指令、反制或单位效果影响且行动花费为 1。隐蔽单位在发起攻击或被攻击后揭示并失去隐蔽",
    ["烟幕"] = "烟幕单位无法被敌方单位攻击。单位移动或攻击后将失去烟幕。守护单位和位于前线的单位不能具有烟幕",
    ["协力"] = "效果触发时除非场上有相同国家的单位，否则总部将受到士气伤害",
    ["流亡"] = "流亡牌可投入包含本国的卡组，也可投入包含流亡国的卡组",

    -- 卡牌操作（card 节点动作）
    ["抽取"] = "令卡组中的一张或多张牌抽到手牌，只有手牌才能在本回合使用。卡牌造成的“抽取”效果全部归类为“额外抽牌”效果。",
    ["额外抽牌"] = "卡牌效果造成的抽牌，全部归类为“额外抽牌”效果。",
    ["复制"] = "令卡组中的一张或多张牌复制一份放到手牌，这不会改变当前卡组结构，也不算做“额外抽牌”。",
    ["弃掉"] = "令手牌中的一张或多张牌从手牌移除。",
    ["弃牌"] = "弃牌是手牌减少事件，可作卡牌效果的条件；与动作“弃掉”同义。",
    ["选择"] = "从卡组顶的 3 张卡牌中，选择一张加入手牌，其余两张放回卡组底，这算做“额外抽牌”。",
    ["爆牌"] = "使下一个回合抽到的牌直接弃掉，这算作“弃牌”事件。",
    ["洗切卡组"] = "重新随机化卡组的结构，洗切卡组事件也能作为卡牌效果的条件。",
    ["洗入"] = "将一个卡牌随机放到卡组中的任意一个地点，这不算做触发了“洗切卡组”。",

    -- 卡牌属性（card_stats 词汇表）
    ["攻击力"] = "单位攻击时造成伤害的基准数值（交战时伤害 = 攻击者攻击力 - 目标重甲等减伤）。",
    ["防御力"] = "单位的防御数值：受到的伤害从防御力扣除，≤ 0 时被消灭。",
    ["防御"] = "同“防御力”：单位的防御数值，受到的伤害从防御力扣除，≤ 0 时被消灭。",
    ["最大防御力"] = "防御力可恢复的上限：基础防御力加上此前获得的增益数值。",
    ["行动花费"] = "操作单位移动或攻击所消耗的指挥点。",
    ["费用"] = "打出该卡牌所需消耗的指挥点。",
    ["花费"] = "同“费用”：打出该卡牌所需消耗的指挥点。",

    -- 通用操作词（多节点共用，便于区分近义/动词搭配）
    ["获得"] = "使目标单位获得下列动作之一（如撤退/交战/战斗等）。",
    ["受到"] = "使目标受到指定效果（伤害/防御变化等）。",
    ["设为"] = "将数值直接设置为指定值（覆盖原值）。",
    ["增加"] = "将数值增加指定量（在原值基础上）。",
    ["减少"] = "将数值减少指定量（在原值基础上）。",
    ["任意"] = "不区分具体对象/阵营/类型，任意符合者均可。",

    -- 回合相关（turn 节点）
    ["回合"] = "对局按回合轮换进行：每回合开始时指挥点调整至与指挥点槽相等。",
    ["回合开始"] = "每回合开始的时刻（指挥点调整至与指挥点槽相等）。",
    ["回合结束"] = "当前玩家回合结束的时刻，随后进入对方回合。",
    ["跳过回合"] = "跳过本回合，不进行本回合的行动阶段。",
    ["等待"] = "挂起后续节点，直到指定回合事件发生指定次数后才继续。",
    ["使"] = "主动执行一次回合控制操作（回合结束/跳过回合）。",

    -- 事件监测（event_monitor 节点）
    ["有变化的"] = "指属性发生变化的那一刻（事件），用于监测变化量或变化后的值。",
    ["属性"] = "单位属性的统称：攻击力、防御力、行动花费等。",
    ["攻防"] = "攻击力与防御力（任一发生变化即命中）。",
    ["的值"] = "读取目标当前属性值作为事件监测条件。",
    ["增加了"] = "属性相比之前增加（按变化量比较）。",
    ["减少了"] = "属性相比之前减少（按变化量比较）。",
    ["为"] = "属性当前值等于指定值（设置条件，而非变化）。",
    ["时：触发情报"] = "打出指令时触发情报 X：显示敌方 X 张手牌（最多 9）。",
    ["总部防御力"] = "总部的耐久值：降至 0 时该总部被摧毁，其所有者对局失败。",

    -- 目标选择（target_selector 节点）
    ["指向"] = "由玩家指定一个目标（“指定一个”）：不能指向的目标显示为黑白、无法选择。",
    ["指定"] = "由玩家从候选目标中选择（同“指向”）。",
    ["随机"] = "从候选目标中等概率随机选取一个。",
    ["场上"] = "战场上所有单位（不分友方/敌方）。",
    ["属性最高"] = "选取指定属性值最高的单位。",
    ["属性最低"] = "选取指定属性值最低的单位。",

    -- 注册钩子（register_hook 节点）
    ["作用域"] = "钩子生效的范围或时长。",
    ["存活在场"] = "钩子仅在注册卡牌存活在场期间生效。",
    ["永久"] = "钩子持续生效直到对局结束。",
    ["总是触发"] = "注册后每次打出指令（含注册本次）都调用函数。",
    ["条件触发"] = "注册后当指定事件发生时调用函数（回合开始/结束、部署单位、打出指令、触发反制）。",
    ["部署单位"] = "任意一方部署单位时（事件）。",
    ["打出指令"] = "任意一方打出指令时（事件）。",

    -- 触发函数（trigger_function 节点）
    ["触发一次"] = "调用函数一次。",
    ["保持触发"] = "每次指定事件发生时调用函数（目标离场前持续）。",
    ["停止保持触发"] = "停止此前“保持触发”的持续调用。",
    ["拦截一次"] = "拦截下一次指令打出，在其效果结算前调用函数。",
    ["保持拦截"] = "持续拦截指令打出，直到被停止。",
    ["效果图标"] = "函数在卡面上显示的效果图标类型（主动效果/被动效果/词条）。",
    ["主动效果"] = "在场时玩家可主动激活的特殊效果（同“触发”）。",

    -- 其余节点专用词
    ["随机排列"] = "将目标方阵线单位的顺序随机重排。",
    ["判断数量"] = "统计满足条件的单位数量并与指定数值比较。",
    ["关键字检查"] = "检查指定单位是否具有指定关键字。",
    ["重复信号"] = "循环开始信号：每收到一次执行下方循环体指定次数。",
    ["观星"] = "从卡组顶查看 3 张牌，选择 1 张加入手牌，其余放回卡组底（同“选择”）。",
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
    name = "新卡牌",
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
    
    -- 历史文献数据
    historyImagePath = "", -- 历史插图路径
    historyImageOffsetX = 0, -- 历史插图X偏移
    historyImageOffsetY = 0, -- 历史插图Y偏移
    historyImageScale = 1, -- 历史插图缩放
    historyText = "", -- 历史文献描述文本
    
    canElevateToVeteran = false, -- 是否可以升级为老兵
    veteranAppearance = { -- 老兵外观数据 - 当卡牌升级为老兵后使用的外观数据
        name = "新卡牌(老兵)", -- 老兵卡牌名称
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
    { id = "type",    shortName = "类型", fullName = "单位卡牌类型", color = Color(80, 140, 200) },
    { id = "attr",    shortName = "属性", fullName = "单位卡牌属性", color = Color(180, 120, 60) },
    { id = "country", shortName = "国家", fullName = "单位卡牌原所属国家", color = Color(60, 160, 100) },
    { id = "keywords", shortName = "词条", fullName = "单位卡牌所具有的战斗词条", color = Color(200, 150, 50) },
    { id = "description", shortName = "描述", fullName = "单位卡牌其他效果描述", color = Color(100, 150, 200) },
    { id = "illustration", shortName = "插图", fullName = "卡牌插图", color = Color(160, 100, 180) },
    { id = "history",  shortName = "历史", fullName = "卡牌历史文献", color = Color(140, 110, 80) },
    { id = "rarity",  shortName = "稀有", fullName = "卡牌稀有度", color = Color(200, 180, 60) },
    { id = "damage",  shortName = "伤害", fullName = "单位伤害倍率配置", color = Color(200, 90, 90) },
    { id = "manage",  shortName = "管理", fullName = "规则词汇表管理", color = Color(120, 120, 120) },
}
KARDS.CardEditor.Canvas.SelectedBookmark = "type"
-- 每个书签的动画状态（由 DrawCardAppearanceEditor 每帧更新）
KARDS.CardEditor.Canvas.BookmarkAnimStates = {}

-- 建议提示台文本
KARDS.CardEditor.Canvas.SuggestionText = ""

-- 规模选项数据（块单选使用）
KARDS.CardEditor.Canvas.CardScaleOptions = {
    { id = "small",  name = "少量规模", desc = "一般的部署方式，将卡牌正常放在桌面" },
    { id = "medium", name = "中量规模", desc = "中等规模的部署，可放置更强力的卡牌" },
    { id = "large",  name = "巨大规模", desc = "大规模部署，需消耗大量资源" },
}
KARDS.CardEditor.Canvas.SelectedCardScale = "small"

-- 特效文件系统：英文名→中文显示名映射（GMod 文件系统不支持中文名）
local EffectDisplayNames = {
    infantry = "步兵",
    tank = "坦克",
    artillery = "炮兵",
    fighter = "战斗机",
    bomber = "轰炸机",
    attack = "攻击特效",
}

-- 构建特效文件树（从真实文件系统读取）
local function BuildEffectFileTree()
    local rootPath = "effects_data/effects"
    local function scanDir(dirPath)
        local files, dirs = file.Find(dirPath .. "/*", "DATA")
        local children = {}
        if dirs then
            table.sort(dirs)
            for _, dirName in ipairs(dirs) do
                local subPath = dirPath .. "/" .. dirName
                local display = EffectDisplayNames[dirName] or dirName
                table.insert(children, {
                    name = dirName,
                    display = display,
                    type = "folder",
                    children = scanDir(subPath)
                })
            end
        end
        if files then
            table.sort(files)
            for _, fileName in ipairs(files) do
                local display = EffectDisplayNames[fileName] or fileName
                table.insert(children, {
                    name = fileName,
                    display = display,
                    type = "file"
                })
            end
        end
        return children
    end
    local children = scanDir(rootPath)
    return {
        name = "特效",
        type = "folder",
        children = children
    }
end

-- 初始化特效文件树
KARDS.CardEditor.Canvas.EffectFileSystem = BuildEffectFileTree()
-- 特效文件管理器状态
KARDS.CardEditor.Canvas.EffectFileState = KARDS.CardEditor.Canvas.EffectFileState or {
    navStack = {},          -- 导航路径栈，存储 folder entry
    selectedEntry = nil,    -- 当前选中的 file entry
    showConfirm = false,    -- 是否显示确认/取消按钮
    animOffset = 0,         -- 页面滑动偏移量（像素）
    showOverlay = false,    -- 是否显示选择成功叠加层
}

-- 子类型文件系统（英文名→中文显示名映射）
local SubtypeDisplayNames = {
    sandbox = "Sandbox(所有国家)",
}

-- 构建子类型文件树（从真实文件系统读取）
local function BuildSubtypeFileTree()
    local rootPath = "effects_data/subtypes"
    local function scanDir(dirPath)
        local files, dirs = file.Find(dirPath .. "/*", "DATA")
        local children = {}
        if dirs then
            table.sort(dirs)
            for _, dirName in ipairs(dirs) do
                local subPath = dirPath .. "/" .. dirName
                local display = SubtypeDisplayNames[dirName] or dirName
                table.insert(children, {
                    name = dirName,
                    display = display,
                    type = "folder",
                    fullPath = subPath,
                    children = scanDir(subPath)
                })
            end
        end
        if files then
            table.sort(files)
            for _, fileName in ipairs(files) do
                table.insert(children, {
                    name = fileName,
                    type = "file",
                    fullPath = dirPath .. "/" .. fileName
                })
            end
        end
        return children
    end
    local children = scanDir(rootPath)
    return {
        name = "子类型",
        type = "folder",
        children = children
    }
end

-- 初始化子类型文件树
KARDS.CardEditor.Canvas.SubtypeFileSystem = BuildSubtypeFileTree()
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
    gui.EnableScreenClicker(false)

    -- 启动背景音效
    KARDS.CardEditor.Audio.StartBackgroundMusic()

    -- 开始编辑器动画
    RunConsoleCommand("kards_start_editor_anim")

    -- 触发编辑器打开事件
    hook.Run("KARDS_EditorOpened")
end

function KARDS.CardEditor.Canvas.CloseEditor()
    if not KARDS.CardEditor.Canvas.Enabled then return end

    KARDS.CardEditor.Canvas.Enabled = false
    KARDS.CardEditor.Canvas.RemoveControls()

    -- 与 dynamic_BGM 兼容：淡入恢复背景音乐
    if KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM then
        KARDS.CardEditor.Compat.DynamicBGM.FadeIn()
    end

    -- 停止背景音效
    KARDS.CardEditor.Audio.StopBackgroundMusic()

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
        -- 播放选择音效
        surface.PlaySound("editor/chooseBGM.wav")

        local countryNames = {
            none = "无",
            uk = "英国",
            usa = "美国",
            ussr = "苏联",
            japan = "日本",
            germany = "德国"
        }
        -- 展开的扩展国家名称并入通知映射
        for _, c in ipairs(KARDS.CardEditor.Canvas.BGMExpandCountries) do
            countryNames[c.id] = c.name
        end
        if countryId == "none" then
            KARDS.CardEditor.Canvas.AddNotification("已停止播放背景音乐", Color(120, 120, 120), true)
        else
            local countryName = countryNames[countryId] or countryId
            -- 优先展示曲名：正在播放：<国家>：<曲名>（曲名来自文件名 <序号>.<音乐名>.ogg）
            local trackName = bgmCompat and bgmCompat.CurrentTrackName or nil
            if trackName then
                KARDS.CardEditor.Canvas.AddNotification("正在播放：" .. countryName .. "：" .. trackName, Color(80, 150, 250), true)
            else
                KARDS.CardEditor.Canvas.AddNotification("正在播放‘" .. countryName .. "’的音乐", Color(80, 150, 250), true)
            end
            -- 初次播放风格：BGM 专属提示（右下角"播放：风格：名称"）——与通用通知并用
            if bgmCompat and bgmCompat.ShowBGMMessage then
                bgmCompat.ShowBGMMessage(countryName .. "：" .. (trackName or "音乐"), "play")
            end
        end
    end
end

-- ===== 展开 BGM 国家菜单（顶栏倒三角按钮） =====

-- 切换展开面板显隐
function KARDS.CardEditor.Canvas.ToggleBGMMenu()
    if KARDS.CardEditor.Canvas.BGMMenuExpanded then
        KARDS.CardEditor.Canvas.CloseBGMMenu()
    else
        KARDS.CardEditor.Canvas.OpenBGMMenu()
    end
end

-- 打开展开面板：遮罩（点击外部关闭） + 横向一排扩展国家圆按钮
function KARDS.CardEditor.Canvas.OpenBGMMenu()
    local root = KARDS.CardEditor.Canvas.RootPanel
    if not IsValid(root) then return end

    local btnSize = 30
    local spacing = 6
    local padding = 5
    local perRow = 5 -- 每行按钮数，超过自动换行
    local expandCountries = KARDS.CardEditor.Canvas.BGMExpandCountries
    local colCount = math.min(#expandCountries, perRow)
    local rowCount = math.ceil(#expandCountries / perRow)
    local totalW = colCount * btnSize + (colCount - 1) * spacing
    local totalH = rowCount * btnSize + (rowCount - 1) * spacing

    -- 遮罩：拦截外部点击并关闭菜单（低于按钮 zpos，不影响按钮点击）
    local mask = vgui.Create("DPanel", root)
    mask:SetPos(0, 0)
    mask:SetSize(root:GetWide(), root:GetTall())
    mask:SetZPos(90)
    mask:SetMouseInputEnabled(true)
    mask.Paint = function() end
    mask.OnMousePressed = function()
        KARDS.CardEditor.Canvas.CloseBGMMenu()
    end
    KARDS.CardEditor.Canvas.BGMMenuMask = mask

    -- 面板定位：位于扩展按钮正下方，右移 2 个按钮直径
    local panelX, panelY = 0, 0
    local extendBtn = KARDS.CardEditor.Canvas.BGMExtendButton
    if IsValid(extendBtn) then
        local bx, by = extendBtn:GetPos()
        panelX = bx + 2 * btnSize
        panelY = by + extendBtn:GetTall() + 6
    end

    local panel = vgui.Create("DPanel", root)
    panel:SetPos(panelX, panelY)
    panel:SetSize(totalW + padding * 2, totalH + padding * 2)
    panel:SetZPos(110)
    panel:SetMouseInputEnabled(true)
    panel.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(42, 42, 42, 240))
        draw.RoundedBox(2, 1, 1, w - 2, h - 2, Color(110, 110, 110, 160))
    end
    KARDS.CardEditor.Canvas.BGMMenuPanel = panel

    -- 扩展国家圆按钮网格布局（每行 perRow 个，与主行按钮同款样式）
    KARDS.CardEditor.Canvas.BGMMenuButtons = {}
    for i, country in ipairs(expandCountries) do
        local col = (i - 1) % perRow
        local row = math.floor((i - 1) / perRow)
        local btn = vgui.Create("DButton", panel)
        btn:SetPos(padding + col * (btnSize + spacing), padding + row * (btnSize + spacing))
        btn:SetSize(btnSize, btnSize)
        btn:SetText("")
        btn.countryData = country -- 悬停简介（打字机动画）读取的国家数据（含二战简介 description）
        btn.Paint = function(self, w, h)
            local iconMat = country.iconMat
            local isHovered = self:IsHovered()
            local bgColor = Color(60, 60, 60)
            if isHovered and country.color then
                bgColor = Color(math.min(country.color.r + 20, 255), math.min(country.color.g + 20, 255), math.min(country.color.b + 20, 255))
            elseif isHovered then
                bgColor = Color(80, 80, 80)
            end
            draw.RoundedBox(btnSize / 2, 0, 0, w, h, bgColor)
            if iconMat and not iconMat:IsError() then
                surface.SetDrawColor(255, 255, 255, 255)
                surface.SetMaterial(iconMat)
                local pad = 3
                surface.DrawTexturedRect(pad, pad, w - pad * 2, h - pad * 2)
            else
                -- 无图标时显示简称（外部注册风格可用 shortName，如 "C"），否则显示名称首字
                draw.SimpleText(country.shortName or country.name:sub(1, 1), "SourceHan_Heavy_12", w / 2, h / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end
        btn.DoClick = function()
            KARDS.CardEditor.Canvas.SelectEditorBGM(country.id)
            KARDS.CardEditor.Canvas.CloseBGMMenu()
        end
        table.insert(KARDS.CardEditor.Canvas.BGMMenuButtons, btn)
    end

    KARDS.CardEditor.Canvas.BGMMenuExpanded = true
end

-- 关闭展开面板并清理
function KARDS.CardEditor.Canvas.CloseBGMMenu()
    KARDS.CardEditor.Canvas.BGMMenuExpanded = false
    -- 清空悬停简介状态（菜单关闭时提示随按钮一并消失）
    if KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM then
        KARDS.CardEditor.Compat.DynamicBGM.BGMHoverState = nil
    end
    if IsValid(KARDS.CardEditor.Canvas.BGMMenuMask) then
        KARDS.CardEditor.Canvas.BGMMenuMask:Remove()
    end
    KARDS.CardEditor.Canvas.BGMMenuMask = nil
    if IsValid(KARDS.CardEditor.Canvas.BGMMenuPanel) then
        KARDS.CardEditor.Canvas.BGMMenuPanel:Remove()
    end
    KARDS.CardEditor.Canvas.BGMMenuPanel = nil
    KARDS.CardEditor.Canvas.BGMMenuButtons = nil
end

-- 移除所有已创建的控件（简化版，仅保留实际创建的控件）
function KARDS.CardEditor.Canvas.RemoveControls()
    -- 先关闭展开 BGM 菜单并清理其面板
    KARDS.CardEditor.Canvas.CloseBGMMenu()

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

function KARDS.CardEditor.Canvas.DrawEditor()
    local win = KARDS.CardEditor.Canvas.Window
    -- 全局编辑器高度 = 窗口内容区高度（所有 totalEditorH 的统一来源）
    KARDS.CardEditor.Canvas.TotalEditorH = win.height - 80
    
    -- 更新背景音效系统
    KARDS.CardEditor.Audio.UpdateBackgroundMusic()

    draw.RoundedBox(8, win.x, win.y, win.width, win.height, Color(50, 50, 50))

    draw.RoundedBox(4, win.x, win.y, win.width, 40, Color(35, 35, 35))

    draw.SimpleText("Kards 卡牌编辑器", "SourceHan_Heavy_36", win.x + 15, win.y + 20, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

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
        local bgMat = Material(currentBgImage, "noclamp smooth")
        if bgMat and not bgMat:IsError() then
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
    end
    
    KARDS.CardEditor.Canvas.DrawContextMenu()
    KARDS.CardEditor.Canvas.DrawSaveWindow()
    KARDS.CardEditor.Canvas.DrawLoadWindow()
    KARDS.CardEditor.Canvas.DrawLoadConfirmDialog()

    -- 绘制文件按钮
    local fileBtnX = win.x + 300
    local fileBtnY = win.y + 5
    local fileBtnW = 80
    local fileBtnH = 30
    local isFileBtnHovered = gui.MouseX() >= fileBtnX and gui.MouseX() <= fileBtnX + fileBtnW and gui.MouseY() >= fileBtnY and gui.MouseY() <= fileBtnY + fileBtnH
    KARDS.CardEditor.Canvas.DrawHoverButton(fileBtnX, fileBtnY, fileBtnW, fileBtnH, "卡牌文件", isFileBtnHovered, { font = "SourceHan_Heavy_16" })

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
        draw.SimpleText("文件操作", "SourceHan_Heavy_16", menuX + 10, menuY + 10, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        
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
                    KARDS.CardEditor.Canvas.UpdateHoverTooltip("保存当前卡牌到文件（外貌、属性、词条、效果路径）")
                elseif button.id == "load" then
                    KARDS.CardEditor.Canvas.UpdateHoverTooltip("加载卡牌（会覆盖当前内容）")
                elseif button.id == "delete" then
                    KARDS.CardEditor.Canvas.UpdateHoverTooltip("删除已保存的卡牌文件")
                elseif button.id == "reset" then
                    KARDS.CardEditor.Canvas.UpdateHoverTooltip("重置编辑器，清除所有节点")
                end
            end
            
            buttonY = buttonY + button.height + buttonSpacing
        end
    end

    -- 绘制输入控件和其他 VGUI 元素（应该在最后绘制，确保在最上层）
    -- VGUI 控件会自动处理自己的绘制，不需要手动绘制

    KARDS.CardEditor.Canvas.HandleInput()
    
    -- 手动绘制VGUI元素
    if IsValid(KARDS.CardEditor.Canvas.RootPanel) then
        KARDS.CardEditor.Canvas.RootPanel:PaintManual()
    end

    KARDS.CardEditor.Canvas.DrawExpandedDropdowns()
    KARDS.CardEditor.Canvas.DrawExpandedMultiDropdowns()

    -- 绘制卡牌选择器（在最上层）
    KARDS.CardEditor.Canvas.DrawCardSelector()

    -- 绘制通知（确保在VGUI元素上方）
    KARDS.CardEditor.Canvas.DrawNotifications()
    
    -- 如果这一帧没有更新过悬停提示，说明鼠标不在任何有提示的元素上，清除提示
    if not KARDS.CardEditor.Canvas.HoverTooltipUpdated then
        KARDS.CardEditor.Canvas.ClearHoverTooltip()
    end
    
    KARDS.CardEditor.Canvas.DrawHoverTooltip()
end

function KARDS.CardEditor.Canvas.DrawNodeSelector(x, y, w, h)
    local selectorW = 180

    draw.RoundedBox(4, x, y, selectorW, h, Color(55, 55, 55))
    draw.SimpleText("节点选择器", "SourceHan_Heavy_18", x + selectorW / 2, y + 20, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 显示当前模式
    local modeText = "模式: "
    if KARDS.CardEditor.Canvas.EditorMode == "unit" then
        modeText = modeText .. "单位"
    elseif KARDS.CardEditor.Canvas.EditorMode == "command" then
        modeText = modeText .. "指令"
    elseif KARDS.CardEditor.Canvas.EditorMode == "counter_command" then
        modeText = modeText .. "反制指令"
    elseif KARDS.CardEditor.Canvas.EditorMode == "headquarter" then
        modeText = modeText .. "总部"
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
                tooltipText = "单位模式下，事件监测节点只能连接到「在场」开始点"
            elseif KARDS.CardEditor.Canvas.EditorMode == "command" then
                tooltipText = "指令模式下，事件监测节点只能连接到「打出」开始点"
            elseif KARDS.CardEditor.Canvas.EditorMode == "counter_command" then
                tooltipText = "反制指令模式下，事件监测节点只能连接到「激活时」开始点"
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

--[[
    注册数字型变量供数字槽选择
    name: 变量名称（显示在弹窗中）
    value: 变量数值
]]
function KARDS.CardEditor.RegisterNumericVariable(name, value)
    local vars = KARDS.CardEditor.NumericVariables
    table.insert(vars, {name = name, value = value})
end

-- 数字型变量选择弹窗状态
KARDS.CardEditor.Canvas.NumericVarPopup = nil  -- { numberId, nodeId, x, y, searchText, page, totalPages }

-- 绘制数字型变量选择弹窗
function KARDS.CardEditor.Canvas.DrawNumericVarPopup()
    local popup = KARDS.CardEditor.Canvas.NumericVarPopup
    
    -- 弹窗关闭时清理 DTextEntry
    if not popup then
        if KARDS.CardEditor.Canvas._searchTextEntry then
            if IsValid(KARDS.CardEditor.Canvas._searchTextEntry) then
                KARDS.CardEditor.Canvas._searchTextEntry:Remove()
            end
            KARDS.CardEditor.Canvas._searchTextEntry = nil
        end
        return
    end
    
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local fontName = "SourceHan_Heavy_14"
    surface.SetFont(fontName)
    local charW = surface.GetTextSize("字")
    local popupW = charW * 30  -- 固定30个文字宽度
    local rowH = 22  -- 每行高度
    local popupH = rowH * 5 + 8  -- 5行 + 上下边距
    
    local px = popup.x
    local py = popup.y
    
    -- 背景
    draw.RoundedBox(4, px, py, popupW, popupH, Color(50, 50, 50, 240))
    surface.SetDrawColor(Color(230, 200, 30))  -- 黄色描边
    surface.DrawOutlinedRect(px, py, popupW, popupH)
    
    -- 第1行：搜索框
    local searchY = py + 4
    local inputW = popupW - 8
    local inputH = rowH - 2
    local isSearchActive = popup.searchActive or false
    local searchText = popup.searchText or ""
    
    if isSearchActive then
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(px + 4, searchY, inputW, inputH)
    else
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(40, 40, 40))
    end
    
    -- 搜索文本绘制
    local displayText = searchText
    if displayText == "" then
        draw.SimpleText("搜索变量...", fontName, px + 8, searchY + inputH / 2, isSearchActive and Color(180, 180, 180) or Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(displayText, fontName, px + 8, searchY + inputH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    
    -- 搜索框激活时绘制闪烁光标
    if isSearchActive and math.floor(SysTime() * 2) % 2 == 0 then
        local cursorX = px + 8 + surface.GetTextSize(searchText)
        surface.SetDrawColor(Color(200, 200, 200))
        surface.DrawLine(cursorX, searchY + 3, cursorX, searchY + inputH - 3)
    end
    
    -- 变量来源：槽选项或全局变量库
    local allVars = {}
    if popup.slotOptions then
        -- 槽选项模式：将选项文本作为虚拟变量
        for idx, optText in ipairs(popup.slotOptions) do
            table.insert(allVars, { name = optText, value = tonumber(optText) or 0, _index = idx })
        end
    else
        allVars = KARDS.CardEditor.NumericVariables or {}
    end
    local filteredVars = {}
    for _, v in ipairs(allVars) do
        local searchName = v.name
        if KARDS.VarLib and KARDS.VarLib.GetDisplayName then
            searchName = KARDS.VarLib.GetDisplayName(searchName)
        end
        if searchText == "" or searchName:find(searchText, 1, true) then
            table.insert(filteredVars, v)
        end
    end
    
    -- 分页计算
    local varsPerPage = 9
    local totalPages = math.max(1, math.ceil(#filteredVars / varsPerPage))
    local currentPage = math.min(popup.page or 1, totalPages)
    popup.page = currentPage  -- 同步当前页
    
    -- ============================================================
    -- 鼠标点击检测：使用状态追踪（比 WasMousePressed 更可靠）
    -- ============================================================
    local mouseDown = input.IsMouseDown(MOUSE_LEFT)
    local mouseClicked = false
    if KARDS.CardEditor.Canvas._mousePrevLeft == nil then
        KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown
    end
    if mouseDown and not KARDS.CardEditor.Canvas._mousePrevLeft then
        mouseClicked = true
    end
    KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown
    
    -- 处理弹窗内部选项点击和外部关闭
    if mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
        local insideW = popup.filterExpanded and (popupW + charW * 18 + 2) or popupW
        local insideH = popup.filterExpanded and (popupH + rowH * 4) or popupH
        local inside = mouseX >= px and mouseX <= px + insideW and
                       mouseY >= py and mouseY <= py + insideH
        if inside then
            -- 点击弹窗内部 → 检测选项选中
            if popup.slotOptions then
                local gridY = py + 4 + rowH + 2
                local colW = popupW / 3
                local startIdx = (currentPage - 1) * varsPerPage + 1
                local endIdx = math.min(startIdx + varsPerPage - 1, #filteredVars)
                
                for i = startIdx, endIdx do
                    local var = filteredVars[i]
                    local row = math.floor((i - startIdx) / 3)
                    local col = (i - startIdx) % 3
                    local cellX = px + 4 + col * colW
                    local cellY = gridY + row * rowH
                    local cellW_val = colW - 4
                    local cellH_val = rowH - 2
                    
                    if mouseX >= cellX and mouseX <= cellX + cellW_val and
                       mouseY >= cellY and mouseY <= cellY + cellH_val then
                        -- 选中选项：使用 popup.nodeRef 直接更新（创建时已存储引用）
                        local node = popup.nodeRef
                        if node and node.data and node.data.numbers and node.data.numbers[popup.numberId] then
                            local numData = node.data.numbers[popup.numberId]
                            numData.selectedOptionIndex = var._index
                            numData.value = var.value
                            node.data[popup.numberId] = var.value
                            -- 标记 popup 选中窗口期：变量引用（var:<名>）要下一帧回写数据源，
                            -- 消费方（如 cl_ine_var_op_nodes.lua DrawEvalNumRight）据此跳过本帧数据驱动同步/复位（E2）
                            numData._popupSelected = true
                            -- 立即重新计算节点宽度
                            if node.parsedConfig and node.parsedConfig.components and node.editor and INE and INE.CalculateSize then
                                local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput or false, node.editor, node.id)
                                node.width = nw
                                node.height = nh
                            end
                            KARDS.CardEditor.Canvas.NumericVarPopup = nil
                        end
                        return
                    end
                end
                -- 没有命中任何单元格 → 检测搜索框焦点
                local searchY = py + 4
                local inputW = popupW - 8
                local inputH = rowH - 2
                if mouseX >= px + 4 and mouseX <= px + 4 + inputW and
                   mouseY >= searchY and mouseY <= searchY + inputH then
                    popup.searchActive = true
                else
                    popup.searchActive = false
                end
            end
        else
            -- 点击弹窗外区域 → 关闭
            popup.searchActive = false
            KARDS.CardEditor.Canvas.NumericVarPopup = nil
            return
        end
    end
    
    -- 第2-4行：变量网格（3列）
    local gridY = py + 4 + rowH + 2
    local colW = popupW / 3
    local startIdx = (currentPage - 1) * varsPerPage + 1
    local endIdx = math.min(startIdx + varsPerPage - 1, #filteredVars)
    
    for i = startIdx, endIdx do
        local var = filteredVars[i]
        local row = math.floor((i - startIdx) / 3)
        local col = (i - startIdx) % 3
        local cellX = px + 4 + col * colW
        local cellY = gridY + row * rowH
        local cellW_val = colW - 4
        local cellH_val = rowH - 2
        
        local isHovered = mouseX >= cellX and mouseX <= cellX + cellW_val and
                          mouseY >= cellY and mouseY <= cellY + cellH_val
        
        if isHovered then
            draw.RoundedBox(3, cellX, cellY, cellW_val, cellH_val, Color(70, 70, 70))
        end
        
        -- 变量名截断（最多10个字符）
        local varName = var.name
        -- 如果有翻译函数，使用翻译后的显示名称
        if KARDS.VarLib and KARDS.VarLib.GetDisplayName then
            varName = KARDS.VarLib.GetDisplayName(varName)
        end
        local maxChars = 10
        local displayName = varName
        -- 计算 UTF-8 字符数（中文3字节，ASCII 1字节）
        local charCount = 0
        local byteLen = 0
        local i = 1
        while i <= #varName do
            local byte = varName:byte(i)
            local charBytes = 1
            if byte >= 240 then
                charBytes = 4
            elseif byte >= 224 then
                charBytes = 3  -- 中文通常是3字节
            elseif byte >= 128 then
                charBytes = 2
            end

            charCount = charCount + 1
            byteLen = i + charBytes - 1

            if charCount >= maxChars then
                displayName = varName:sub(1, byteLen) .. "…"
                break
            end

            i = i + charBytes
        end
        
        draw.SimpleText(displayName, fontName, cellX + 4, cellY + cellH_val / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        
        -- 悬停时显示完整变量名
        if isHovered then
            KARDS.CardEditor.Canvas.UpdateHoverTooltip(varName)
        end
    end
    
    -- 第5行：分页导航
    local navY = py + popupH - rowH - 2
    local navCenterX = px + popupW / 2
    
    -- 判断是否为第一页/最后一页
    local isFirstPage = currentPage <= 1
    local isLastPage = currentPage >= totalPages
    
    if not isFirstPage then
        local leftArrowX = navCenterX - charW * 4
        local leftArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= leftArrowX - 10 and mouseX <= leftArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY - 4)
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY + 4)
        
        -- 使用 mouseClicked 检测点击事件，避免持续切换
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.page = math.max(1, currentPage - 1)
        end
    end
    
    -- 页码
    draw.SimpleText(currentPage .. "/" .. totalPages, fontName, navCenterX, navY + rowH / 2, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    if not isLastPage then
        local rightArrowX = navCenterX + charW * 4
        local rightArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= rightArrowX - 10 and mouseX <= rightArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY - 4)
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY + 4)
        
        -- 使用 mouseClicked 检测点击事件，避免持续切换
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.page = currentPage + 1
        end
    end

    -- ============================================================
    -- 筛选面板（仅 slotOptions 模式，展开时绘制在右侧）
    -- ============================================================
    -- 确保筛选状态字段存在（兼容旧弹窗）
    if popup.filterExpanded == nil then popup.filterExpanded = false end
    if popup.filterFaction == nil then popup.filterFaction = nil end
    if popup.filterLocation == nil then popup.filterLocation = nil end
    if popup.filterType == nil then popup.filterType = nil end
    if popup.filterKeyword == nil then popup.filterKeyword = nil end

    -- 筛选关键词列表（与对象选择器共享）
    local FILTER_KEYWORDS_NUM = {
        "部署","守护","烟幕","闪击","伏击","亡计",
        "重甲1","重甲2","重甲3",
        "主动效果","被动效果","老兵","协力","情报",
        "冲击","奋战","山地",
        "收缴","钳击",
        "步兵","炮兵","坦克","战斗机","轰炸机",
    }

    -- ">>"/"<<" 筛选展开按钮（仅 slotOptions 模式，页面导航行最右侧）
    if popup.slotOptions then
        local navY = py + popupH - rowH - 2
        local filterBtnX = px + popupW - charW * 3 - 4
        local filterBtnW = charW * 3
        local filterBtnLabel = popup.filterExpanded and "<<" or ">>"
        local filterBtnHovered = mouseX >= filterBtnX and mouseX <= filterBtnX + filterBtnW and
                                 mouseY >= navY and mouseY <= navY + rowH
        draw.RoundedBox(3, filterBtnX, navY + 2, filterBtnW, rowH - 4, filterBtnHovered and Color(80, 90, 100) or Color(55, 55, 60))
        surface.SetDrawColor(Color(80, 80, 80))
        surface.DrawOutlinedRect(filterBtnX, navY + 2, filterBtnW, rowH - 4)
        draw.SimpleText(filterBtnLabel, fontName, filterBtnX + filterBtnW / 2, navY + rowH / 2, filterBtnHovered and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if filterBtnHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.filterExpanded = not popup.filterExpanded
            if not popup.filterExpanded then
                popup.filterFaction = nil
                popup.filterLocation = nil
                popup.filterType = nil
                popup.filterKeyword = nil
                popup.searchText = ""
                popup.page = 1
            end
        end
    end

    -- 筛选面板展开内容
    if popup.filterExpanded and popup.slotOptions then
        local filterPW = charW * 18
        local filterPX = px + popupW + 2
        local filterPY = py
        local filterPH = popupH + rowH * 4

        -- 存储筛选面板边界供 Think 检测鼠标位置使用
        popup._filterAreaX, popup._filterAreaY = filterPX, filterPY
        popup._filterAreaW, popup._filterAreaH = filterPW, filterPH

        -- 背景
        draw.RoundedBox(4, filterPX, filterPY, filterPW, filterPH, Color(50, 50, 50, 240))
        surface.SetDrawColor(Color(80, 80, 80))
        surface.DrawOutlinedRect(filterPX, filterPY, filterPW, filterPH)

        -- 标题
        local inputH = rowH - 2
        draw.SimpleText("筛选", fontName, filterPX + filterPW / 2, filterPY + inputH / 2 + 2, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        local fRowY = filterPY + inputH + 6
        local fRowH = rowH - 2
        local fPad = 4
        local fBtnH = fRowH - 2

        -- 辅助函数：重建筛选搜索文本
        local function RebuildFilterSearchNum()
            local parts = {}
            if popup.filterFaction then table.insert(parts, popup.filterFaction) end
            if popup.filterLocation then table.insert(parts, popup.filterLocation) end
            if popup.filterType then table.insert(parts, popup.filterType) end
            if popup.filterKeyword then table.insert(parts, popup.filterKeyword) end
            popup.searchText = table.concat(parts)
            popup.page = 1
        end

        -- 辅助函数：绘制筛选按钮
        local function DrawFilterBtnNum(btnX, btnY, btnW, label, isActive, isDisabled)
            if isDisabled then return false end
            local bHovered = mouseX >= btnX and mouseX <= btnX + btnW and
                             mouseY >= btnY and mouseY <= btnY + fBtnH
            local bColor = isActive and Color(70, 110, 160) or (bHovered and Color(65, 65, 70) or Color(45, 45, 50))
            draw.RoundedBox(3, btnX, btnY, btnW, fBtnH, bColor)
            if isActive then
                surface.SetDrawColor(Color(100, 150, 220, 200))
                surface.DrawOutlinedRect(btnX, btnY, btnW, fBtnH)
            end
            draw.SimpleText(label, fontName, btnX + btnW / 2, btnY + fBtnH / 2, isActive and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if bHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                return true
            end
            return false
        end

        -- Row 1：阵营（友方/敌方）
        local f1Y = fRowY
        local f1ColW = (filterPW - fPad * 3) / 2
        if DrawFilterBtnNum(filterPX + fPad, f1Y, f1ColW, "友方", popup.filterFaction == "友方") then
            if popup.filterFaction == "友方" then popup.filterFaction = nil else popup.filterFaction = "友方" end
            RebuildFilterSearchNum()
        end
        if DrawFilterBtnNum(filterPX + fPad * 2 + f1ColW, f1Y, f1ColW, "敌方", popup.filterFaction == "敌方") then
            if popup.filterFaction == "敌方" then popup.filterFaction = nil else popup.filterFaction = "敌方" end
            RebuildFilterSearchNum()
        end

        -- Row 2：位置（手牌/本回合/总部）
        local f2Y = f1Y + fRowH + 2
        local f2ColW = (filterPW - fPad * 4) / 3
        if DrawFilterBtnNum(filterPX + fPad, f2Y, f2ColW, "手牌", popup.filterLocation == "手牌") then
            if popup.filterLocation == "手牌" then popup.filterLocation = nil else popup.filterLocation = "手牌" end
            RebuildFilterSearchNum()
        end
        if DrawFilterBtnNum(filterPX + fPad * 2 + f2ColW, f2Y, f2ColW, "本回合", popup.filterLocation == "本回合") then
            if popup.filterLocation == "本回合" then popup.filterLocation = nil else popup.filterLocation = "本回合" end
            RebuildFilterSearchNum()
        end
        if DrawFilterBtnNum(filterPX + fPad * 3 + f2ColW * 2, f2Y, f2ColW, "总部", popup.filterLocation == "总部") then
            if popup.filterLocation == "总部" then popup.filterLocation = nil else popup.filterLocation = "总部" end
            RebuildFilterSearchNum()
        end

        -- Row 3：类型（单位/指令/反制）
        local f3Y = f2Y + fRowH + 2
        local showCmdAndCounter = true
        local typeColW = showCmdAndCounter and (filterPW - fPad * 4) / 3 or (filterPW - fPad * 2)
        if DrawFilterBtnNum(filterPX + fPad, f3Y, typeColW, "单位", popup.filterType == "单位") then
            if popup.filterType == "单位" then popup.filterType = nil else popup.filterType = "单位" end
            RebuildFilterSearchNum()
        end
        if showCmdAndCounter then
            if DrawFilterBtnNum(filterPX + fPad * 2 + typeColW, f3Y, typeColW, "指令", popup.filterType == "指令") then
                if popup.filterType == "指令" then popup.filterType = nil else popup.filterType = "指令" end
                RebuildFilterSearchNum()
            end
            if DrawFilterBtnNum(filterPX + fPad * 3 + typeColW * 2, f3Y, typeColW, "反制", popup.filterType == "反制") then
                if popup.filterType == "反制" then popup.filterType = nil else popup.filterType = "反制" end
                RebuildFilterSearchNum()
            end
        end

        -- 关键词标签网格
        local tagY = f3Y + fRowH + 6
        local tagH = rowH - 4
        local tagCols = math.floor(filterPW / (charW * 5 + 4))
        tagCols = math.max(1, tagCols)
        local tagColW = (filterPW - fPad * (tagCols + 1)) / tagCols

        -- 关键词滚动
        if popup.filterKwScroll == nil then popup.filterKwScroll = 0 end
        local kwPerPage = math.floor((filterPY + filterPH - tagY - 4) / (tagH + 2)) * tagCols
        local totalKw = 0
        -- 先统计可见关键词数量（无位置过滤限制，全部显示）
        for _, kw in ipairs(FILTER_KEYWORDS_NUM) do
            totalKw = totalKw + 1
        end
        local maxKwScroll = math.max(0, math.ceil((totalKw - kwPerPage) / tagCols) * (tagH + 2))
        popup.filterKwScroll = math.Clamp(popup.filterKwScroll or 0, 0, maxKwScroll)

        -- 用裁切限制关键词标签的渲染区域
        render.SetScissorRect(filterPX, tagY, filterPX + filterPW, filterPY + filterPH, true)

        local kwIdx = 0
        local scrollOffset = -(popup.filterKwScroll or 0)
        for _, kw in ipairs(FILTER_KEYWORDS_NUM) do
            -- 无位置过滤限制，全部显示
            local isFiltered = false
            if not isFiltered then
                kwIdx = kwIdx + 1
                local col = (kwIdx - 1) % tagCols
                local row = math.floor((kwIdx - 1) / tagCols)
                local kx = filterPX + fPad + col * (tagColW + fPad)
                local ky = tagY + row * (tagH + 2) + scrollOffset

                -- 裁剪：只绘制可见范围内的标签
                if ky + tagH >= filterPY and ky <= filterPY + filterPH then
                    local isActive = popup.filterKeyword == kw
                    local isHov = mouseX >= kx and mouseX <= kx + tagColW and
                                  mouseY >= ky and mouseY <= ky + tagH
                    local bCol = isActive and Color(70, 110, 160) or (isHov and Color(60, 60, 65) or Color(40, 40, 45))
                    draw.RoundedBox(3, kx, ky, tagColW, tagH, bCol)
                    if isActive then
                        surface.SetDrawColor(Color(100, 150, 220, 200))
                        surface.DrawOutlinedRect(kx, ky, tagColW, tagH)
                    end
                    draw.SimpleText(kw, "SourceHan_Heavy_12", kx + tagColW / 2, ky + tagH / 2, isActive and Color(255, 255, 255) or Color(170, 170, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    if isHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                        if popup.filterKeyword == kw then popup.filterKeyword = nil else popup.filterKeyword = kw end
                        RebuildFilterSearchNum()
                    end
                end
            end
        end

        -- 关键词滚动按钮
        if maxKwScroll > 0 then
            local scrollBtnSize = rowH - 4
            local scrollUpY = tagY
            local scrollDownY = filterPY + filterPH - scrollBtnSize - 2
            local scrollBtnsX = filterPX + filterPW - scrollBtnSize - fPad
            -- 上滚
            local upHov = mouseX >= scrollBtnsX and mouseX <= scrollBtnsX + scrollBtnSize and
                          mouseY >= scrollUpY and mouseY <= scrollUpY + scrollBtnSize
            draw.RoundedBox(3, scrollBtnsX, scrollUpY, scrollBtnSize, scrollBtnSize, upHov and Color(75, 75, 85) or Color(50, 50, 55))
            draw.SimpleText("▲", "SourceHan_Heavy_10", scrollBtnsX + scrollBtnSize / 2, scrollUpY + scrollBtnSize / 2, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if upHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                popup.filterKwScroll = math.max(0, (popup.filterKwScroll or 0) - (tagH + 2) * 2)
            end
            -- 下滚
            local downHov = mouseX >= scrollBtnsX and mouseX <= scrollBtnsX + scrollBtnSize and
                            mouseY >= scrollDownY and mouseY <= scrollDownY + scrollBtnSize
            draw.RoundedBox(3, scrollBtnsX, scrollDownY, scrollBtnSize, scrollBtnSize, downHov and Color(75, 75, 85) or Color(50, 50, 55))
            draw.SimpleText("▼", "SourceHan_Heavy_10", scrollBtnsX + scrollBtnSize / 2, scrollDownY + scrollBtnSize / 2, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if downHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                popup.filterKwScroll = math.min(maxKwScroll, (popup.filterKwScroll or 0) + (tagH + 2) * 2)
            end
        end

        -- 鼠标滚轮滚动关键词标签（滚轮标志由 CreateMove 中的 INE_WheelCapture 在 popup._wheelScroll 上设值）
        if popup._wheelScroll then
            if popup._wheelScroll == "up" then
                popup.filterKwScroll = math.max(0, (popup.filterKwScroll or 0) - (tagH + 2) * 2)
            elseif popup._wheelScroll == "down" then
                popup.filterKwScroll = math.min(maxKwScroll, (popup.filterKwScroll or 0) + (tagH + 2) * 2)
            end
            popup._wheelScroll = nil
        end

        -- 关闭裁切
        render.SetScissorRect(0, 0, 0, 0, false)
    end

    -- 搜索框的键盘输入由 HandleInput 中的按键事件处理
end

-- ================================================================
-- 函数变量选择弹窗（funcslot 函数槽单选下拉）
-- 外观与 DrawNumericVarPopup 相同：搜索框 + 3列网格 + 分页导航
-- 选项为函数变量（全局函数变量 + 当前槽局部函数）
-- ================================================================
function KARDS.CardEditor.Canvas.DrawFuncVarPopup()
    local INE = KARDS.CardEditor.IndependentNodeEditor
    local popup = KARDS.CardEditor.Canvas.FuncVarPopup
    if not popup then return end

    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local fontName = "SourceHan_Heavy_14"
    surface.SetFont(fontName)
    local charW = surface.GetTextSize("字")
    local popupW = charW * 30  -- 固定30个文字宽度
    local rowH = 22  -- 每行高度
    local popupH = rowH * 5 + 8  -- 5行 + 上下边距

    local px = popup.x
    local py = popup.y

    -- 背景
    draw.RoundedBox(4, px, py, popupW, popupH, Color(50, 50, 50, 240))
    surface.SetDrawColor(Color(180, 70, 200))  -- 紫色描边（函数主题色）
    surface.DrawOutlinedRect(px, py, popupW, popupH)

    -- 第1行：搜索框
    local searchY = py + 4
    local inputW = popupW - 8
    local inputH = rowH - 2
    local isSearchActive = popup.searchActive or false
    local searchText = popup.searchText or ""

    if isSearchActive then
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(px + 4, searchY, inputW, inputH)
    else
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(40, 40, 40))
    end

    if searchText == "" then
        draw.SimpleText("搜索函数...", fontName, px + 8, searchY + inputH / 2, isSearchActive and Color(180, 180, 180) or Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(searchText, fontName, px + 8, searchY + inputH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    -- 搜索框激活时绘制闪烁光标
    if isSearchActive and math.floor(SysTime() * 2) % 2 == 0 then
        local cursorX = px + 8 + surface.GetTextSize(searchText)
        surface.SetDrawColor(Color(200, 200, 200))
        surface.DrawLine(cursorX, searchY + 3, cursorX, searchY + inputH - 3)
    end

    -- 过滤选项（函数名大小写不敏感匹配）
    local filteredOpts = {}
    for _, fo in ipairs(popup.funcOptions or {}) do
        local label = fo.label or ""
        if searchText == "" or label:lower():find(searchText:lower(), 1, true) then
            table.insert(filteredOpts, fo)
        end
    end

    -- 分页计算
    local varsPerPage = 9
    local totalPages = math.max(1, math.ceil(#filteredOpts / varsPerPage))
    local currentPage = math.min(popup.page or 1, totalPages)
    popup.page = currentPage  -- 同步当前页

    -- ============================================================
    -- 鼠标点击检测：使用状态追踪（比 WasMousePressed 更可靠）
    -- ============================================================
    local mouseDown = input.IsMouseDown(MOUSE_LEFT)
    local mouseClicked = false
    if KARDS.CardEditor.Canvas._mousePrevLeft == nil then
        KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown
    end
    if mouseDown and not KARDS.CardEditor.Canvas._mousePrevLeft then
        mouseClicked = true
    end
    KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown

    -- 处理弹窗内部点击和外部关闭
    if mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
        local inside = mouseX >= px and mouseX <= px + popupW and
                       mouseY >= py and mouseY <= py + popupH
        if inside then
            -- 检测选项选中
            local gridY = py + 4 + rowH + 2
            local colW = popupW / 3
            local startIdx = (currentPage - 1) * varsPerPage + 1
            local endIdx = math.min(startIdx + varsPerPage - 1, #filteredOpts)

            local hitCell = false
            for i = startIdx, endIdx do
                local fo = filteredOpts[i]
                local row = math.floor((i - startIdx) / 3)
                local col = (i - startIdx) % 3
                local cellX = px + 4 + col * colW
                local cellY = gridY + row * rowH
                local cellW_val = colW - 4
                local cellH_val = rowH - 2

                if mouseX >= cellX and mouseX <= cellX + cellW_val and
                   mouseY >= cellY and mouseY <= cellY + cellH_val then
                    hitCell = true
                    -- 选中函数：更新节点槽数据
                    local node = popup.nodeRef
                    local slotData = popup.slotDataRef
                    if node and slotData then
                        slotData.variableRef = fo.label
                        slotData.mode = "variable"
                        -- 选中的是全局函数变量时清除局部函数引用
                        if not fo.isLocal then
                            slotData._localFuncRef = nil
                        end
                        node.data[popup.compId] = fo.label
                        -- 立即重新计算节点宽度
                        if node.parsedConfig and node.parsedConfig.components and node.editor and INE and INE.CalculateSize then
                            local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput or false, node.editor, node.id)
                            node.width = nw
                            node.height = nh
                        end
                    end
                    KARDS.CardEditor.Canvas.FuncVarPopup = nil
                    return
                end
            end
            -- 没有命中任何单元格 → 检测搜索框焦点
            if not hitCell then
                if mouseX >= px + 4 and mouseX <= px + 4 + inputW and
                   mouseY >= searchY and mouseY <= searchY + inputH then
                    popup.searchActive = true
                else
                    popup.searchActive = false
                end
            end
        else
            -- 点击弹窗外区域 → 关闭
            popup.searchActive = false
            KARDS.CardEditor.Canvas.FuncVarPopup = nil
            return
        end
    end

    -- 第2-4行：函数网格（3列）
    local gridY = py + 4 + rowH + 2
    local colW = popupW / 3
    local startIdx = (currentPage - 1) * varsPerPage + 1
    local endIdx = math.min(startIdx + varsPerPage - 1, #filteredOpts)

    for i = startIdx, endIdx do
        local fo = filteredOpts[i]
        local row = math.floor((i - startIdx) / 3)
        local col = (i - startIdx) % 3
        local cellX = px + 4 + col * colW
        local cellY = gridY + row * rowH
        local cellW_val = colW - 4
        local cellH_val = rowH - 2

        local isHovered = mouseX >= cellX and mouseX <= cellX + cellW_val and
                          mouseY >= cellY and mouseY <= cellY + cellH_val

        if isHovered then
            draw.RoundedBox(3, cellX, cellY, cellW_val, cellH_val, Color(70, 70, 70))
        end

        -- 函数名截断（最多10个字符）
        local varName = fo.label or ""
        local maxChars = 10
        local displayName = varName
        -- 计算 UTF-8 字符数（中文3字节，ASCII 1字节）
        local charCount = 0
        local byteLen = 0
        local j = 1
        while j <= #varName do
            local byte = varName:byte(j)
            local charBytes = 1
            if byte >= 240 then
                charBytes = 4
            elseif byte >= 224 then
                charBytes = 3  -- 中文通常是3字节
            elseif byte >= 128 then
                charBytes = 2
            end

            charCount = charCount + 1
            byteLen = j + charBytes - 1

            if charCount >= maxChars then
                displayName = varName:sub(1, byteLen) .. "…"
                break
            end

            j = j + charBytes
        end

        draw.SimpleText(displayName, fontName, cellX + 4, cellY + cellH_val / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 悬停时显示完整函数名
        if isHovered then
            KARDS.CardEditor.Canvas.UpdateHoverTooltip(varName)
        end
    end

    -- 第5行：分页导航
    local navY = py + popupH - rowH - 2
    local navCenterX = px + popupW / 2

    local isFirstPage = currentPage <= 1
    local isLastPage = currentPage >= totalPages

    if not isFirstPage then
        local leftArrowX = navCenterX - charW * 4
        local leftArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= leftArrowX - 10 and mouseX <= leftArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY - 4)
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY + 4)

        -- 使用 mouseClicked 检测点击事件，避免持续切换
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.page = math.max(1, currentPage - 1)
        end
    end

    -- 页码
    draw.SimpleText(currentPage .. "/" .. totalPages, fontName, navCenterX, navY + rowH / 2, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    if not isLastPage then
        local rightArrowX = navCenterX + charW * 4
        local rightArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= rightArrowX - 10 and mouseX <= rightArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY - 4)
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY + 4)

        -- 使用 mouseClicked 检测点击事件，避免持续切换
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.page = currentPage + 1
        end
    end
end

-- ================================================================
-- 卡牌对象选择器弹窗（INE 编辑器单选组件的卡牌对象模式）
-- 外观与 DrawNumericVarPopup 相同，但选项为已保存卡牌/卡牌对象变量/数据连接变量
-- ================================================================
function KARDS.CardEditor.Canvas.DrawCardObjectSelector()
    local INE = KARDS.CardEditor.IndependentNodeEditor
    local sel = KARDS.CardEditor.Canvas.CardObjectSelector
    if not sel then return end
    if not sel.options or #sel.options == 0 then
        KARDS.CardEditor.Canvas.CardObjectSelector = nil
        return
    end

    -- 初始化状态
    if sel.multiSelect == nil then sel.multiSelect = false end
    if sel.includeGlobal == nil then sel.includeGlobal = false end
    if not sel.selectedIndices then sel.selectedIndices = {} end
    if sel.filterExpanded == nil then sel.filterExpanded = false end

    -- 筛选关键词列表（中文名）
    local FILTER_KEYWORDS = {
        "部署","守护","烟幕","闪击","伏击","亡计",
        "重甲1","重甲2","重甲3",
        "主动效果","被动效果","老兵","协力","情报",
        "冲击","奋战","山地",
        "收缴","钳击",
        "步兵","炮兵","坦克","战斗机","轰炸机",
    }

    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local fontName = "SourceHan_Heavy_14"
    surface.SetFont(fontName)
    local charW = surface.GetTextSize("字")
    local popupW = charW * 30
    local rowH = 22
    local popupH = rowH * 6 + 8  -- +1行用于底部按钮

    local px = sel.x
    local py = sel.y
    sel.popupW = popupW
    sel.popupH = popupH

    -- 背景
    draw.RoundedBox(4, px, py, popupW, popupH, Color(50, 50, 50, 240))
    surface.SetDrawColor(Color(200, 60, 60))  -- 红色描边
    surface.DrawOutlinedRect(px, py, popupW, popupH)

    -- 第1行：搜索框
    local searchY = py + 4
    local inputW = popupW - 8
    local inputH = rowH - 2
    local isSearchActive = sel.searchActive or false
    local searchText = sel.searchText or ""

    if isSearchActive then
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(px + 4, searchY, inputW, inputH)
    else
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(40, 40, 40))
    end

    if searchText == "" then
        draw.SimpleText("搜索卡牌...", fontName, px + 8, searchY + inputH / 2, isSearchActive and Color(180, 180, 180) or Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(searchText, fontName, px + 8, searchY + inputH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    if isSearchActive and math.floor(SysTime() * 2) % 2 == 0 then
        local cursorX = px + 8 + surface.GetTextSize(searchText)
        surface.SetDrawColor(Color(200, 200, 200))
        surface.DrawLine(cursorX, searchY + 3, cursorX, searchY + inputH - 3)
    end

    -- 过滤选项：搜索文本 + includeGlobal
    -- 搜索匹配函数，支持 . 作为通配符（跳过任意一个字符位置）
    local function matchSearch(name, search)
        if search == "" then return true end
        -- 不含点号时使用快速匹配
        if not search:find("%.") then
            return name:find(search, 1, true) ~= nil
        end
        -- 将字符串按 UTF-8 字符分割
        local function toChars(s)
            local chars = {}
            local i = 1
            while i <= #s do
                local b = s:byte(i)
                local len = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
                chars[#chars + 1] = s:sub(i, i + len - 1)
                i = i + len
            end
            return chars
        end
        local nameChars = toChars(name)
        local searchChars = toChars(search)
        if #searchChars > #nameChars then return false end
        -- 在 name 的每个位置尝试匹配
        for start = 1, #nameChars - #searchChars + 1 do
            local matched = true
            for j = 1, #searchChars do
                local sc = searchChars[j]
                if sc ~= "." and sc ~= nameChars[start + j - 1] then
                    matched = false
                    break
                end
            end
            if matched then return true end
        end
        return false
    end

    local filteredOpts = {}
    local isGlobalOpt = {}  -- filteredOpts 中对应位置是否为全局变量
    for _, opt in ipairs(sel.options) do
        if not sel.includeGlobal and opt.type == "connection" then
            -- 包括全局关闭时跳过连接变量（全局对象变量）
        else
            local optName = opt.label or opt.name or ""
            if matchSearch(optName, searchText) then
                table.insert(filteredOpts, opt)
                table.insert(isGlobalOpt, opt.type == "connection")
            end
        end
    end

    -- 在 multiSelect 模式下也要处理包括全局关闭时的自动移除逻辑（在点击按钮时处理）

    -- 分页（每页9个，3列）
    local varsPerPage = 9
    local totalPages = math.max(1, math.ceil(#filteredOpts / varsPerPage))
    local currentPage = math.min(sel.page or 1, totalPages)
    sel.page = currentPage

    -- 鼠标点击检测
    local mouseDown = input.IsMouseDown(MOUSE_LEFT)
    local mouseClicked = false
    if KARDS.CardEditor.Canvas._mousePrevLeft == nil then
        KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown
    end
    if mouseDown and not KARDS.CardEditor.Canvas._mousePrevLeft then
        mouseClicked = true
    end
    KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown

    -- 处理点击
    if mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
        local insideW = sel.filterExpanded and (popupW + charW * 18 + 2) or popupW
        local insideH = sel.filterExpanded and (popupH + rowH * 4) or popupH
        local inside = mouseX >= px and mouseX <= px + insideW and
                       mouseY >= py and mouseY <= py + insideH
        if inside then
            -- 点击按钮行
            local btnY = py + popupH - rowH - 2
            local btnH = rowH - 2
            local btnMargin = 4
            local halfBtnW = (popupW - btnMargin * 3) / 2
            local multiBtnX = px + btnMargin
            local globalBtnX = px + btnMargin * 2 + halfBtnW

            if mouseY >= btnY and mouseY <= btnY + btnH then
                -- "多选"按钮点击
                if mouseX >= multiBtnX and mouseX <= multiBtnX + halfBtnW then
                    sel.multiSelect = not sel.multiSelect
                    if not sel.multiSelect then
                        -- 单选模式下只保留第一个选中项
                        local firstIdx = nil
                        for idx in pairs(sel.selectedIndices) do
                            if firstIdx == nil or idx < firstIdx then
                                firstIdx = idx
                            end
                        end
                        local newSel = {}
                        if firstIdx then newSel[firstIdx] = true end
                        sel.selectedIndices = newSel
                    end
                    return
                end
                -- "包括全局"按钮点击
                if mouseX >= globalBtnX and mouseX <= globalBtnX + halfBtnW then
                    local wasOn = sel.includeGlobal
                    sel.includeGlobal = not sel.includeGlobal
                    if wasOn and not sel.includeGlobal then
                        -- 关闭包括全局：移除所有连接变量的选中
                        if sel.multiSelect then
                            -- 多选：移除所有全局选项
                            local newSelected = {}
                            for idx, _ in pairs(sel.selectedIndices) do
                                if not isGlobalOpt[idx] then
                                    newSelected[idx] = true
                                end
                            end
                            sel.selectedIndices = newSelected
                        else
                            -- 单选：若当前选中是全局变量，重置到第一个非全局选项
                            local anyGlobal = false
                            for idx, _ in pairs(sel.selectedIndices) do
                                if isGlobalOpt[idx] then
                                    anyGlobal = true
                                    break
                                end
                            end
                            if anyGlobal then
                                sel.selectedIndices = {}
                                -- 找第一个非全局选项
                                for idx, opt in ipairs(filteredOpts) do
                                    if not isGlobalOpt[idx] then
                                        sel.selectedIndices[idx] = true
                                        break
                                    end
                                end
                            end
                        end
                        -- 关闭包括全局时收回筛选面板
                        sel.filterExpanded = false
                        sel.filterFaction = nil
                        sel.filterLocation = nil
                        sel.filterType = nil
                        sel.filterKeyword = nil
                        sel.searchText = ""
                    end
                    -- 页面重置到第1页（选项数量变化）
                    sel.page = 1
                    return
                end
            end

            -- 点击选项网格
            local gridY = py + 4 + rowH + 2
            local colW = popupW / 3
            local startIdx = (currentPage - 1) * varsPerPage + 1
            local endIdx = math.min(startIdx + varsPerPage - 1, #filteredOpts)

            for i = startIdx, endIdx do
                local opt = filteredOpts[i]
                local row = math.floor((i - startIdx) / 3)
                local col = (i - startIdx) % 3
                local cellX = px + 4 + col * colW
                local cellY = gridY + row * rowH
                local cellW_val = colW - 4
                local cellH_val = rowH - 2

                if mouseX >= cellX and mouseX <= cellX + cellW_val and
                   mouseY >= cellY and mouseY <= cellY + cellH_val then
                    local node = sel.nodeRef
                    if node and node.data then
                        if sel.multiSelect then
                            -- 多选模式：切换选中状态，不关闭弹窗
                            if sel.selectedIndices[i] then
                                sel.selectedIndices[i] = nil  -- 取消选中
                            else
                                sel.selectedIndices[i] = true  -- 选中
                            end
                            -- 立即写入 node.data 以便其他组件读取
                            local labels = {}
                            local files = {}
                            local appearances = {}
                            for idx, _ in pairs(sel.selectedIndices) do
                                local o = filteredOpts[idx]
                                if o then
                                    table.insert(labels, o.label or o.name or "?")
                                    if o.cardFile then table.insert(files, o.cardFile) end
                                    if o.cardAppearance then table.insert(appearances, o.cardAppearance) end
                                end
                            end
                            table.sort(labels)
                            if #labels > 0 then
                                local displayText = "多选(" .. #labels .. ")"
                                node.data[sel.compId] = displayText
                                node.data[sel.compId .. "_files"] = files
                                node.data[sel.compId .. "_appearances"] = appearances
                                node.data[sel.compId .. "_labels"] = labels
                            else
                                node.data[sel.compId] = nil
                                node.data[sel.compId .. "_files"] = nil
                                node.data[sel.compId .. "_appearances"] = nil
                                node.data[sel.compId .. "_labels"] = nil
                            end
                            if node.parsedConfig and node.parsedConfig.components and node.editor and INE and INE.CalculateSize then
                                local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput or false, node.editor, node.id)
                                node.width = nw
                                node.height = nh
                            end
                        else
                            -- 单例模式：直接选中并关闭弹窗
                            node.data[sel.compId] = opt.label or opt.name or "?"
                            node.data[sel.compId .. "_file"] = opt.cardFile
                            node.data[sel.compId .. "_appearance"] = opt.cardAppearance
                            node.data[sel.compId .. "_files"] = nil
                            node.data[sel.compId .. "_appearances"] = nil
                            node.data[sel.compId .. "_labels"] = nil
                            -- 同步到统一槽 SlotData（如果存在）
                            if sel._slotData then
                                sel._slotData.variableRef = opt.label or opt.name or "?"
                                sel._slotData.mode = "variable"
                            end
                            if node.parsedConfig and node.parsedConfig.components and node.editor and INE and INE.CalculateSize then
                                local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput or false, node.editor, node.id)
                                node.width = nw
                                node.height = nh
                            end
                            KARDS.CardEditor.Canvas.CardObjectSelector = nil
                        end
                    end
                    return
                end
            end
            -- 点击搜索框
            if mouseX >= px + 4 and mouseX <= px + 4 + inputW and
               mouseY >= searchY and mouseY <= searchY + inputH then
                sel.searchActive = true
                -- 搜索框获得焦点时收回筛选面板
                if sel.filterExpanded then
                    sel.filterExpanded = false
                    sel.filterFaction = nil
                    sel.filterLocation = nil
                    sel.filterType = nil
                    sel.filterKeyword = nil
                end
            else
                sel.searchActive = false
            end
        else
            -- 点击外部：关闭弹窗，在 multiSelect 模式下已写入数据
            sel.searchActive = false
            KARDS.CardEditor.Canvas.CardObjectSelector = nil
            return
        end
    end

    -- 第2-4行：选项网格
    local gridY = py + 4 + rowH + 2
    _deferredPreview = nil  -- 重置延迟预览
    local colW = popupW / 3
    local startIdx = (currentPage - 1) * varsPerPage + 1
    local endIdx = math.min(startIdx + varsPerPage - 1, #filteredOpts)

    for i = startIdx, endIdx do
        local opt = filteredOpts[i]
        local row = math.floor((i - startIdx) / 3)
        local col = (i - startIdx) % 3
        local cellX = px + 4 + col * colW
        local cellY = gridY + row * rowH
        local cellW_val = colW - 4
        local cellH_val = rowH - 2

        local isHovered = mouseX >= cellX and mouseX <= cellX + cellW_val and
                          mouseY >= cellY and mouseY <= cellY + cellH_val

        -- 多选模式下高亮已选中的项
        local isSelected = sel.selectedIndices and sel.selectedIndices[i]

        if isSelected then
            draw.RoundedBox(3, cellX, cellY, cellW_val, cellH_val, Color(60, 100, 140))
        elseif isHovered then
            draw.RoundedBox(3, cellX, cellY, cellW_val, cellH_val, Color(70, 70, 70))
        end

        -- 名称截断
        local optName = opt.label or opt.name or ""
        local displayName = optName
        local charCount = 0
        local byteEnd = 0
        local byteIdx = 1
        while byteIdx <= #optName do
            local byte = optName:byte(byteIdx)
            local charBytes = 1
            if byte >= 240 then charBytes = 4
            elseif byte >= 224 then charBytes = 3
            elseif byte >= 128 then charBytes = 2
            end
            charCount = charCount + 1
            byteEnd = byteIdx + charBytes - 1
            if charCount >= 10 then
                displayName = optName:sub(1, byteEnd) .. "…"
                break
            end
            byteIdx = byteIdx + charBytes
        end

        -- 选中标记
        if isSelected then
            displayName = "✓ " .. displayName
        end

        draw.SimpleText(displayName, fontName, cellX + 4, cellY + cellH_val / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 收集悬停时的卡牌预览数据（推迟到所有 UI 元素绘制完成后渲染，确保预览图始终在最上层）
        if isHovered and opt.cardAppearance then
            local refH = math.floor((KARDS.CardEditor.Canvas.TotalEditorH or 720) / 3)
            local previewH = refH
            local previewW = math.floor(previewH * 3 / 4)
            local previewX = mouseX - previewW / 2
            local previewY = mouseY + 16
            if previewX + previewW > ScrW() then
                previewX = ScrW() - previewW - 8
            end
            if previewX < 0 then
                previewX = 8
            end
            if previewY + previewH > ScrH() then
                previewY = mouseY - previewH - 10
            end
            if previewY < 0 then
                previewY = 10
            end
            _deferredPreview = { appearance = opt.cardAppearance, x = previewX, y = previewY, w = previewW, h = previewH }
        end

        -- 悬停在接收的对象（数据连接传入）选项上时，从源节点的数据输出点绘制连线到该选项
        if isHovered and opt.type == "connection" and opt.fromNodeId then
            local editor = sel.nodeRef and sel.nodeRef.editor
            if editor then
                local srcNode = nil
                for _, n in ipairs(editor.nodes) do
                    if n.id == opt.fromNodeId then
                        srcNode = n
                        break
                    end
                end
                if srcNode then
                    local portPos = srcNode._outputDataPortPositions and srcNode._outputDataPortPositions[opt.fromPortIndex or 1]
                    if portPos then
                        local fromX, fromY = portPos.x, portPos.y
                        local toX, toY = cellX + cellW_val, cellY + cellH_val / 2
                        local distance = toY - fromY
                        local cp1x = fromX
                        local cp1y = fromY + distance / 3 + 30
                        local cp2x = toX
                        local cp2y = toY - distance / 3 - 30
                        local steps = 20
                        local points = {}
                        for i = 0, steps do
                            local t = i / steps
                            local x = (1-t)^3 * fromX + 3*(1-t)^2*t*cp1x + 3*(1-t)*t^2*cp2x + t^3*toX
                            local y = (1-t)^3 * fromY + 3*(1-t)^2*t*cp1y + 3*(1-t)*t^2*cp2y + t^3*toY
                            table.insert(points, {x = x, y = y})
                        end
                        if INE and INE.DrawThickCurve then
                            INE:DrawThickCurve(points, Color(255, 200, 0, 180), math.max(1, 2 * (editor.canvasScale or 1)))
                        end
                    end
                end
            end
        end
    end

    -- 第5行：分页导航（向上移一行，给底部按钮留空间）
    local navY = py + popupH - rowH * 2 - 2
    local navCenterX = px + popupW / 2
    local isFirstPage = currentPage <= 1
    local isLastPage = currentPage >= totalPages

    if not isFirstPage then
        local leftArrowX = navCenterX - charW * 4
        local leftArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= leftArrowX - 10 and mouseX <= leftArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY - 4)
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY + 4)
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            sel.page = math.max(1, currentPage - 1)
        end
    end

    draw.SimpleText(currentPage .. "/" .. totalPages, fontName, navCenterX, navY + rowH / 2, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    if not isLastPage then
        local rightArrowX = navCenterX + charW * 4
        local rightArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= rightArrowX - 10 and mouseX <= rightArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY - 4)
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY + 4)
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            sel.page = currentPage + 1
        end
    end

    -- ">>"/"<<" 筛选展开按钮（行5最右侧，仅包括全局时可用）
    if sel.includeGlobal then
    local filterBtnX = px + popupW - charW * 3 - 4
    local filterBtnW = charW * 3
    local filterBtnLabel = sel.filterExpanded and "<<" or ">>"
    local filterBtnHovered = mouseX >= filterBtnX and mouseX <= filterBtnX + filterBtnW and
                             mouseY >= navY and mouseY <= navY + rowH
    draw.RoundedBox(3, filterBtnX, navY + 2, filterBtnW, rowH - 4, filterBtnHovered and Color(80, 90, 100) or Color(55, 55, 60))
    surface.SetDrawColor(Color(80, 80, 80))
    surface.DrawOutlinedRect(filterBtnX, navY + 2, filterBtnW, rowH - 4)
    draw.SimpleText(filterBtnLabel, fontName, filterBtnX + filterBtnW / 2, navY + rowH / 2, filterBtnHovered and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if filterBtnHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
        sel.filterExpanded = not sel.filterExpanded
        if not sel.filterExpanded then
            -- 收回时清除筛选并重置搜索
            sel.filterFaction = nil
            sel.filterLocation = nil
            sel.filterType = nil
            sel.filterKeyword = nil
            sel.searchText = ""
            sel.page = 1
        end
        -- 不再处理后续点击
    end
    end -- end includeGlobal check

    -- 第6行：底部按钮（多选 / 包括全局）
    local btnY = py + popupH - rowH - 2
    local btnH = rowH - 2
    local btnMargin = 4
    local halfBtnW = (popupW - btnMargin * 3) / 2
    local multiBtnX = px + btnMargin
    local globalBtnX = px + btnMargin * 2 + halfBtnW

    -- "多选"按钮
    local multiActive = sel.multiSelect
    draw.RoundedBox(3, multiBtnX, btnY, halfBtnW, btnH, multiActive and Color(70, 110, 160) or Color(45, 45, 45))
    surface.SetDrawColor(multiActive and Color(100, 150, 220, 200) or Color(70, 70, 70))
    surface.DrawOutlinedRect(multiBtnX, btnY, halfBtnW, btnH)
    draw.SimpleText("多选", fontName, multiBtnX + halfBtnW / 2, btnY + btnH / 2, multiActive and Color(255, 255, 255) or Color(160, 160, 160), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- "包括全局"按钮
    local globalActive = sel.includeGlobal
    draw.RoundedBox(3, globalBtnX, btnY, halfBtnW, btnH, globalActive and Color(70, 110, 160) or Color(45, 45, 45))
    surface.SetDrawColor(globalActive and Color(100, 150, 220, 200) or Color(70, 70, 70))
    surface.DrawOutlinedRect(globalBtnX, btnY, halfBtnW, btnH)
    draw.SimpleText("包括全局", fontName, globalBtnX + halfBtnW / 2, btnY + btnH / 2, globalActive and Color(255, 255, 255) or Color(160, 160, 160), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- ================================================================
    -- 筛选面板（展开时绘制在右侧）
    -- ================================================================
    -- 先清除筛选面板边界，展开时再设置
    sel._filterAreaX, sel._filterAreaY = nil, nil
    sel._filterAreaW, sel._filterAreaH = nil, nil
    if sel.filterExpanded then
        local filterPW = charW * 18
        local filterPX = px + popupW + 2
        local filterPY = py
        local filterPH = popupH + rowH * 4  -- 向下扩展以容纳关键词

        -- 存储筛选面板边界供 Think 检测鼠标位置使用
        sel._filterAreaX, sel._filterAreaY = filterPX, filterPY
        sel._filterAreaW, sel._filterAreaH = filterPW, filterPH

        -- 背景（红色描边，与对象选择器主体一致）
        draw.RoundedBox(4, filterPX, filterPY, filterPW, filterPH, Color(50, 50, 50, 240))
        surface.SetDrawColor(Color(200, 60, 60))
        surface.DrawOutlinedRect(filterPX, filterPY, filterPW, filterPH)

        -- 标题
        draw.SimpleText("筛选", fontName, filterPX + filterPW / 2, filterPY + inputH / 2 + 2, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        local fRowY = filterPY + inputH + 6
        local fRowH = rowH - 2
        local fPad = 4
        local fColW = (filterPW - fPad * 3) / 2  -- 2列
        local fBtnH = fRowH - 2

        -- 辅助函数：构建搜索文本
        local function RebuildFilterSearch()
            local parts = {}
            if sel.filterFaction then table.insert(parts, sel.filterFaction) end
            if sel.filterLocation then table.insert(parts, sel.filterLocation) end
            if sel.filterType then table.insert(parts, sel.filterType) end
            if sel.filterKeyword then table.insert(parts, sel.filterKeyword) end
            sel.searchText = table.concat(parts)
            sel.page = 1
        end

        -- 辅助函数：绘制筛选按钮
        local function DrawFilterBtn(btnX, btnY, btnW, label, isActive, isDisabled)
            if isDisabled then return end
            local bHovered = mouseX >= btnX and mouseX <= btnX + btnW and
                             mouseY >= btnY and mouseY <= btnY + fBtnH
            local bColor = isActive and Color(70, 110, 160) or (bHovered and Color(65, 65, 70) or Color(45, 45, 50))
            draw.RoundedBox(3, btnX, btnY, btnW, fBtnH, bColor)
            if isActive then
                surface.SetDrawColor(Color(100, 150, 220, 200))
                surface.DrawOutlinedRect(btnX, btnY, btnW, fBtnH)
            end
            draw.SimpleText(label, fontName, btnX + btnW / 2, btnY + fBtnH / 2, isActive and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if bHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                return true
            end
            return false
        end

        -- Row 1: 阵营（友方/敌方）
        local f1Y = fRowY
        local f1ColW = (filterPW - fPad * 3) / 2
        if DrawFilterBtn(filterPX + fPad, f1Y, f1ColW, "友方", sel.filterFaction == "友方") then
            if sel.filterFaction == "友方" then sel.filterFaction = nil else sel.filterFaction = "友方" end
            RebuildFilterSearch()
        end
        if DrawFilterBtn(filterPX + fPad * 2 + f1ColW, f1Y, f1ColW, "敌方", sel.filterFaction == "敌方") then
            if sel.filterFaction == "敌方" then sel.filterFaction = nil else sel.filterFaction = "敌方" end
            RebuildFilterSearch()
        end

        -- Row 2: 位置（手牌/场上）
        local f2Y = f1Y + fRowH + 2
        if DrawFilterBtn(filterPX + fPad, f2Y, f1ColW, "手牌", sel.filterLocation == "手牌") then
            if sel.filterLocation == "手牌" then sel.filterLocation = nil else sel.filterLocation = "手牌" end
            -- 清除不兼容的类型/关键词
            if sel.filterLocation == "手牌" and sel.filterKeyword == "老兵" then sel.filterKeyword = nil end
            RebuildFilterSearch()
        end
        if DrawFilterBtn(filterPX + fPad * 2 + f1ColW, f2Y, f1ColW, "场上", sel.filterLocation == "场上") then
            if sel.filterLocation == "场上" then sel.filterLocation = nil else sel.filterLocation = "场上" end
            -- 场上时清除不兼容的类型/关键词
            if sel.filterLocation == "场上" then
                if sel.filterType == "指令" or sel.filterType == "反制" then sel.filterType = nil end
                if sel.filterKeyword == "指令" or sel.filterKeyword == "反制" then sel.filterKeyword = nil end
            end
            RebuildFilterSearch()
        end

        -- Row 3: 类型（单位/指令/反制，选择"场上"时下一行不显示指令/反制）
        local f3Y = f2Y + fRowH + 2
        local showCmdAndCounter = sel.filterLocation ~= "场上"
        local typeColW = showCmdAndCounter and (filterPW - fPad * 4) / 3 or (filterPW - fPad * 2)

        if DrawFilterBtn(filterPX + fPad, f3Y, typeColW, "单位", sel.filterType == "单位") then
            if sel.filterType == "单位" then sel.filterType = nil else sel.filterType = "单位" end
            RebuildFilterSearch()
        end
        if showCmdAndCounter then
            if DrawFilterBtn(filterPX + fPad * 2 + typeColW, f3Y, typeColW, "指令", sel.filterType == "指令") then
                if sel.filterType == "指令" then sel.filterType = nil else sel.filterType = "指令" end
                RebuildFilterSearch()
            end
            if DrawFilterBtn(filterPX + fPad * 3 + typeColW * 2, f3Y, typeColW, "反制", sel.filterType == "反制") then
                if sel.filterType == "反制" then sel.filterType = nil else sel.filterType = "反制" end
                RebuildFilterSearch()
            end
        end

        -- 关键词标签网格
        local tagY = f3Y + fRowH + 6
        local tagH = rowH - 4
        local tagCols = math.floor(filterPW / (charW * 5 + 4))
        tagCols = math.max(1, tagCols)
        local tagColW = (filterPW - fPad * (tagCols + 1)) / tagCols

        -- 关键词滚动
        if sel.filterKwScroll == nil then sel.filterKwScroll = 0 end
        local kwPerPage = math.floor((filterPY + filterPH - tagY - 4) / (tagH + 2)) * tagCols
        local totalKw = 0
        -- 先统计可见关键词数量
        for _, kw in ipairs(FILTER_KEYWORDS) do
            local skip = false
            if sel.filterLocation == "手牌" and kw == "老兵" then skip = true end
            if sel.filterLocation == "场上" and (kw == "指令" or kw == "反制") then skip = true end
            if not skip then totalKw = totalKw + 1 end
        end
        local maxKwScroll = math.max(0, math.ceil((totalKw - kwPerPage) / tagCols) * (tagH + 2))
        sel.filterKwScroll = math.Clamp(sel.filterKwScroll or 0, 0, maxKwScroll)

        -- 用裁切限制关键词标签的渲染区域，防止滚动时标签覆盖上方的筛选项
        render.SetScissorRect(filterPX, tagY, filterPX + filterPW, filterPY + filterPH, true)

        local kwIdx = 0
        local drawnInView = 0
        local scrollOffset = -(sel.filterKwScroll or 0)
        for _, kw in ipairs(FILTER_KEYWORDS) do
            -- 过滤不兼容的关键词
            local isFiltered = (sel.filterLocation == "手牌" and kw == "老兵") or
                              (sel.filterLocation == "场上" and (kw == "指令" or kw == "反制"))
            if not isFiltered then
                kwIdx = kwIdx + 1
                local col = (kwIdx - 1) % tagCols
                local row = math.floor((kwIdx - 1) / tagCols)
                local kx = filterPX + fPad + col * (tagColW + fPad)
                local ky = tagY + row * (tagH + 2) + scrollOffset

                -- 裁剪：只绘制可见范围内的标签
                if ky + tagH >= filterPY and ky <= filterPY + filterPH then
                    drawnInView = drawnInView + 1
                    local isActive = sel.filterKeyword == kw
                    local isHov = mouseX >= kx and mouseX <= kx + tagColW and
                                  mouseY >= ky and mouseY <= ky + tagH

                    local bCol = isActive and Color(70, 110, 160) or (isHov and Color(60, 60, 65) or Color(40, 40, 45))
                    draw.RoundedBox(3, kx, ky, tagColW, tagH, bCol)
                    if isActive then
                        surface.SetDrawColor(Color(100, 150, 220, 200))
                        surface.DrawOutlinedRect(kx, ky, tagColW, tagH)
                    end
                    draw.SimpleText(kw, "SourceHan_Heavy_12", kx + tagColW / 2, ky + tagH / 2, isActive and Color(255, 255, 255) or Color(170, 170, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

                    if isHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                        if sel.filterKeyword == kw then
                            sel.filterKeyword = nil
                        else
                            sel.filterKeyword = kw
                        end
                        RebuildFilterSearch()
                    end
                end
            end
        end

        -- 关键词滚动按钮（有滚动时显示）
        if maxKwScroll > 0 then
            local scrollBtnSize = rowH - 4
            local scrollUpY = tagY
            local scrollDownY = filterPY + filterPH - scrollBtnSize - 2
            local scrollBtnsX = filterPX + filterPW - scrollBtnSize - fPad

            -- 上滚
            local upHov = mouseX >= scrollBtnsX and mouseX <= scrollBtnsX + scrollBtnSize and
                          mouseY >= scrollUpY and mouseY <= scrollUpY + scrollBtnSize
            draw.RoundedBox(3, scrollBtnsX, scrollUpY, scrollBtnSize, scrollBtnSize, upHov and Color(75, 75, 85) or Color(50, 50, 55))
            draw.SimpleText("▲", "SourceHan_Heavy_10", scrollBtnsX + scrollBtnSize / 2, scrollUpY + scrollBtnSize / 2, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if upHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                sel.filterKwScroll = math.max(0, (sel.filterKwScroll or 0) - (tagH + 2) * 2)
            end

            -- 下滚
            local downHov = mouseX >= scrollBtnsX and mouseX <= scrollBtnsX + scrollBtnSize and
                            mouseY >= scrollDownY and mouseY <= scrollDownY + scrollBtnSize
            draw.RoundedBox(3, scrollBtnsX, scrollDownY, scrollBtnSize, scrollBtnSize, downHov and Color(75, 75, 85) or Color(50, 50, 55))
            draw.SimpleText("▼", "SourceHan_Heavy_10", scrollBtnsX + scrollBtnSize / 2, scrollDownY + scrollBtnSize / 2, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if downHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                sel.filterKwScroll = math.min(maxKwScroll, (sel.filterKwScroll or 0) + (tagH + 2) * 2)
            end
        end

        -- 鼠标滚轮滚动关键词标签
        -- 检测鼠标是否在关键词标签区域内
        if mouseX >= filterPX and mouseX <= filterPX + filterPW and
           mouseY >= tagY and mouseY <= filterPY + filterPH then
            if INE._filterWheelUp then
                INE._filterWheelUp = false
                sel.filterKwScroll = math.max(0, (sel.filterKwScroll or 0) - (tagH + 2) * 2)
            end
            if INE._filterWheelDown then
                INE._filterWheelDown = false
                sel.filterKwScroll = math.min(maxKwScroll, (sel.filterKwScroll or 0) + (tagH + 2) * 2)
            end
        end

        -- 关闭裁切，恢复正常渲染
        render.SetScissorRect(0, 0, 0, 0, false)

        -- 延迟渲染卡牌预览图（在所有 UI 元素绘制完成后执行，确保预览图始终在最上层）
        if _deferredPreview then
            KARDS.CardEditor.Canvas.DrawCardPreview(
                _deferredPreview.appearance,
                _deferredPreview.x, _deferredPreview.y,
                _deferredPreview.w, _deferredPreview.h,
                false, false, false
            )
        end
    end
end

KARDS.CardEditor.Canvas.LastMouseState = KARDS.CardEditor.Canvas.LastMouseState or false

-- ================================================================
-- 从 HandleInput 拆分的 13 个局部子函数（P0-1.2 重构）
-- ================================================================

-- 1. 处理卡牌选择器输入
local function HandleCardSelectorInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    local selector = KARDS.CardEditor.Canvas.CardSelector
    if selector.visible then
        if isLeftReleased then
            -- 主按钮区域
            local buttonY = selector.y + 2
            local buttonHeight = selector.height - 4
            local buttonWidth = selector.width - 4
            local buttonX = selector.x + 2
            
            local isButtonClicked = mouseX >= buttonX and mouseX <= buttonX + buttonWidth and mouseY >= buttonY and mouseY <= buttonY + buttonHeight
            
            if isButtonClicked then
                -- 切换展开状态
                selector.expanded = not selector.expanded
                -- 如果展开，刷新列表
                if selector.expanded then
                    KARDS.CardEditor.Canvas.CardSelector.RefreshList()
                end
                return true
            end
            
            -- 如果展开，处理列表项点击
            if selector.expanded then
                local listX = selector.x + 2
                local listY = buttonY + buttonHeight + 4
                local listWidth = selector.width - 4
                local listHeight = selector.expandedHeight - selector.height - 8
                local itemHeight = 45
                local previewWidth = 150
                
                -- 检查是否点击了外部区域
                local isOutsideClick = not (mouseX >= selector.x and mouseX <= selector.x + selector.width and mouseY >= selector.y and mouseY <= selector.y + selector.expandedHeight)
                if isOutsideClick then
                    selector.expanded = false
                    return true
                end
                
                -- 检查列表项点击
                local visibleItems = math.floor(listHeight / itemHeight)
                local scrollOffset = selector.scrollOffset
                
                for i = 1 + scrollOffset, math.min(#selector.cardsList, visibleItems + scrollOffset) do
                    local card = selector.cardsList[i]
                    local itemIndex = i - scrollOffset
                    local itemY = listY + (itemIndex - 1) * itemHeight
                    
                    if itemY + itemHeight > listY + listHeight then break end
                    
                    local isItemClicked = mouseX >= listX and mouseX <= listX + listWidth - previewWidth and mouseY >= itemY and mouseY <= itemY + itemHeight
                    if isItemClicked then
                        selector.selectedCard = card
                        selector.expanded = false
                        
                        -- 加载卡牌数据到编辑器
                        if card.fullData then
                            if card.fullData.nodes then
                                KARDS.CardEditor.Canvas.Nodes = card.fullData.nodes
                            end
                            if card.fullData.connections then
                                KARDS.CardEditor.Canvas.Connections = card.fullData.connections
                            end
                            if card.fullData.cardAppearance then
                                KARDS.CardEditor.Canvas.CardAppearance = card.fullData.cardAppearance
                                -- 同步钳击输入框
                                if KARDS.CardEditor.Canvas.PincerInputState then
                                    local app = card.fullData.cardAppearance
                                    KARDS.CardEditor.Canvas.PincerInputState.text = app.pincerValue or ""
                                    KARDS.CardEditor.Canvas.PincerInputState.active = false
                                end
                            end
                            if card.fullData.currentPage then
                                KARDS.CardEditor.Canvas.CurrentPage = card.fullData.currentPage
                            end
                            if card.fullData.appearanceEditorActive ~= nil then
                                KARDS.CardEditor.Canvas.AppearanceEditorActive = card.fullData.appearanceEditorActive
                            end
                            
                            -- 更新VGUI控件
                            KARDS.CardEditor.Canvas.UpdateControlsFromAppearance()
                            
                            -- 重新创建 INE 开始点（使"钳击"等词条相关的开始点与卡牌关键词同步）
                            local INE = KARDS.CardEditor.IndependentNodeEditor
                            if INE then
                                local ineEditor = GetNodeEditor("card_effect_editor")
                                if ineEditor then
                                    INE:CreateStartNodesForEditor(ineEditor)
                                end
                            end
                            
                            KARDS.CardEditor.Canvas.AddNotification("卡牌加载成功", Color(50, 200, 50), true)
                            KARDS.CardEditor.Audio.PlayLoad()
                        end
                        
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- 2. 处理文件按钮和菜单
local function HandleFileMenuInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if isLeftReleased then
        local fm = KARDS.CardEditor.Canvas.FileMenu
        -- 文件菜单点击处理（如果菜单已打开）
        if fm.visible then
            local menuX = fm.x
            local menuY = fm.y
            local menuW = fm.width
            local menuH = fm.height
            
            -- 检查是否点击了菜单内的按钮
            for _, button in ipairs(fm.buttons) do
                if mouseX >= button.x and mouseX <= button.x + button.width and mouseY >= button.y and mouseY <= button.y + button.height then
                    if button.id == "save" then
                        KARDS.CardEditor.Canvas.SaveWindow.visible = true
                        KARDS.CardEditor.Canvas.SaveWindow.inputText = ""
                        KARDS.CardEditor.Canvas.SaveWindow.errorMessage = ""
                        KARDS.CardEditor.Canvas.SaveWindow.isReplaceMode = false
                        if IsValid(KARDS.CardEditor.Canvas.SaveWindow.inputPanel) then
                            KARDS.CardEditor.Canvas.SaveWindow.inputPanel:SetVisible(true)
                        end
                        timer.Simple(0.1, function()
                            if IsValid(KARDS.CardEditor.Canvas.SaveWindow.inputTextEntry) then
                                KARDS.CardEditor.Canvas.SaveWindow.inputTextEntry:SetText("")
                                KARDS.CardEditor.Canvas.SaveWindow.inputTextEntry:RequestFocus()
                            end
                        end)
                    elseif button.id == "load" then
                        KARDS.CardEditor.Canvas.LoadWindow.visible = true
                        KARDS.CardEditor.Canvas.LoadWindow.selectedFile = nil
                        KARDS.CardEditor.Canvas.LoadWindow.scrollOffset = 0
                        KARDS.CardEditor.Canvas.LoadWindow.category = "card"
                        KARDS.CardEditor.Canvas.LoadWindow.files = KARDS.CardEditor.SaveSystem.GetCardFiles()
                    elseif button.id == "delete" then
                        KARDS.CardEditor.Canvas.LoadWindow.visible = true
                        KARDS.CardEditor.Canvas.LoadWindow.selectedFile = nil
                        KARDS.CardEditor.Canvas.LoadWindow.scrollOffset = 0
                        KARDS.CardEditor.Canvas.LoadWindow.category = "card"
                        KARDS.CardEditor.Canvas.LoadWindow.deleteMode = true
                        KARDS.CardEditor.Canvas.LoadWindow.files = KARDS.CardEditor.SaveSystem.GetCardFiles()
                    elseif button.id == "reset" then
                        KARDS.CardEditor.Canvas.Nodes = {}
                        KARDS.CardEditor.Canvas.Connections = {}
                        KARDS.CardEditor.Canvas.NodeCounter = 0
                        KARDS.CardEditor.Canvas.ConnectionCounter = 0
                        KARDS.CardEditor.Canvas.TempNode = nil
                        KARDS.CardEditor.Canvas.TempConnection = nil
                        KARDS.CardEditor.Canvas.DraggingNode = nil
                        KARDS.CardEditor.Canvas.HoveredConnection = nil
                    end
                    fm.visible = false
                    return true
                end
            end
            
            -- 如果点击了外部，隐藏菜单
            if not (mouseX >= menuX and mouseX <= menuX + menuW and mouseY >= menuY and mouseY <= menuY + menuH) then
                fm.visible = false
            end
        else
            -- 文件按钮点击（打开菜单）
            local win = KARDS.CardEditor.Canvas.Window
            local fileBtnX = win.x + 300
            local fileBtnY = win.y + 5
            local fileBtnW = 80
            local fileBtnH = 30
            if mouseX >= fileBtnX and mouseX <= fileBtnX + fileBtnW and mouseY >= fileBtnY and mouseY <= fileBtnY + fileBtnH then
                fm.visible = true
                return true
            end
        end
    end
    return false
end

-- 3. 处理保存窗口（卡牌编辑器只保存卡牌）
local function HandleSaveWindowInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if KARDS.CardEditor.Canvas.SaveWindow.visible then
        if isLeftReleased then
            local confirmBtn = KARDS.CardEditor.Canvas.SaveWindow.buttons[1]
            if mouseX >= confirmBtn.x and mouseX <= confirmBtn.x + confirmBtn.width and mouseY >= confirmBtn.y and mouseY <= confirmBtn.y + confirmBtn.height then
                if KARDS.CardEditor.Canvas.SaveWindow.inputText == "" then
                    KARDS.CardEditor.Canvas.AddNotification("文件名不能为空", Color(200, 50, 50), false)
                    KARDS.CardEditor.Audio.PlayNotification()
                else
                    local fileName = KARDS.CardEditor.Canvas.SaveWindow.inputText
                    -- 联动保存 INE 效果：先把节点编辑器内容导出为效果文件，
                    -- 将返回的保存路径绑定为卡牌 effectPath（编辑器无有效效果节点或导出失败时绑定为空）
                    local effectPath = ""
                    local ineEditor = GetNodeEditor and GetNodeEditor("card_effect_editor")
                    local INE = KARDS.CardEditor.IndependentNodeEditor
                    if ineEditor and INE and INE.ExportEditorToFile then
                        local hasEffectNode = false
                        for _, n in ipairs(ineEditor.nodes or {}) do
                            if not n.isStartNode then hasEffectNode = true break end
                        end
                        if hasEffectNode then
                            effectPath = INE:ExportEditorToFile(ineEditor, fileName) or ""
                        end
                    end
                    KARDS.CardEditor.Canvas.CardAppearance.effectPath = effectPath
                    -- 保存时确保卡面纹理已渲染落盘（已点过「渲染」则仅指向其文件路径，不重复渲染；
                    -- 未渲染则本次离屏渲染一次并保存 PNG），纹理路径随保存文件入库，组卡/生成直接引用
                    local textureInfo = KARDS.CardEditor.Canvas.EnsureCardTextures()
                    local success = KARDS.CardEditor.SaveSystem.SaveCard(fileName, textureInfo)
                    if success then
                        KARDS.CardEditor.Canvas.AddNotification("卡牌保存成功", Color(50, 200, 50), true)
                        KARDS.CardEditor.Audio.PlaySave()
                    else
                        KARDS.CardEditor.Canvas.AddNotification("卡牌保存失败", Color(200, 50, 50), false)
                        KARDS.CardEditor.Audio.PlayNotification()
                    end
                    
                    KARDS.CardEditor.Canvas.SaveWindow.visible = false
                    if IsValid(KARDS.CardEditor.Canvas.SaveWindow.inputPanel) then
                        KARDS.CardEditor.Canvas.SaveWindow.inputPanel:SetVisible(false)
                    end
                end
            end
            
            local cancelBtn = KARDS.CardEditor.Canvas.SaveWindow.buttons[2]
            if mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height then
                KARDS.CardEditor.Canvas.SaveWindow.visible = false
                if IsValid(KARDS.CardEditor.Canvas.SaveWindow.inputPanel) then
                    KARDS.CardEditor.Canvas.SaveWindow.inputPanel:SetVisible(false)
                end
            end
        end
        return true
    end
    return false
end

-- 4. 处理加载确认对话框（卡牌编辑器只加载卡牌）
local function HandleLoadConfirmInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if KARDS.CardEditor.Canvas.LoadConfirmDialog.visible then
        if isLeftReleased then
            local dialog = KARDS.CardEditor.Canvas.LoadConfirmDialog
            
            -- 先更新按钮位置
            local continueBtn = dialog.buttons[1]
            continueBtn.x = dialog.x + dialog.width / 2 - 115
            continueBtn.y = dialog.y + dialog.height - 50
            continueBtn.hovered = mouseX >= continueBtn.x and mouseX <= continueBtn.x + continueBtn.width and mouseY >= continueBtn.y and mouseY <= continueBtn.y + continueBtn.height
            
            local cancelBtn = dialog.buttons[2]
            cancelBtn.x = dialog.x + dialog.width / 2 + 15
            cancelBtn.y = dialog.y + dialog.height - 50
            cancelBtn.hovered = mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height
            
            -- 检测点击
            if mouseX >= continueBtn.x and mouseX <= continueBtn.x + continueBtn.width and mouseY >= continueBtn.y and mouseY <= continueBtn.y + continueBtn.height then
                local fileName = dialog.selectedFile
                local success = KARDS.CardEditor.SaveSystem.LoadCard(fileName)
                if success then
                    -- 同步导入卡牌绑定的效果数据到 INE 面板（替换当前画布效果，实现加载卡牌即恢复效果）
                    local app = KARDS.CardEditor.Canvas.CardAppearance
                    local INE = KARDS.CardEditor.IndependentNodeEditor
                    local ineEditor = GetNodeEditor and GetNodeEditor("card_effect_editor")
                    if app and app.effectPath and app.effectPath ~= "" and INE and ineEditor and INE.ImportEffectData then
                        local effectData = KARDS.CardEditor.SaveSystem.LoadEffect(app.effectPath)
                        if effectData and effectData.nodes then
                            INE:ImportEffectData(ineEditor, effectData)
                        end
                    end
                    KARDS.CardEditor.Canvas.AddNotification("卡牌加载成功", Color(50, 200, 50), true)
                    KARDS.CardEditor.Audio.PlayLoad()
                else
                    KARDS.CardEditor.Canvas.AddNotification("卡牌加载失败", Color(200, 50, 50), false)
                    KARDS.CardEditor.Audio.PlayNotification()
                end
                
                dialog.visible = false
                KARDS.CardEditor.Canvas.LoadWindow.visible = false
                KARDS.CardEditor.Canvas.LoadWindow.selectedFile = nil
                KARDS.CardEditor.Canvas.LoadWindow.files = {}
            end
            
            if mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height then
                dialog.visible = false
            end
        end
        return true
    end
    return false
end

-- 5. 处理加载窗口
local function HandleFileSelectInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if KARDS.CardEditor.Canvas.LoadWindow.visible then
        local loadWindow = KARDS.CardEditor.Canvas.LoadWindow
        local listX = loadWindow.x + 40
        local listY = loadWindow.y + 80 + loadWindow.headerHeight
        local listW = loadWindow.width - 80
        local listH = loadWindow.height - 180 - loadWindow.headerHeight
        local rowH = loadWindow.rowHeight

        -- 滚轮滚动文件列表（消费 CreateMove 设置的缩放标记；仅鼠标位于列表区域内时生效，
        -- 避免与卡牌插图预览的滚轮缩放冲突）
        local mouseInList = mouseX >= listX and mouseX <= listX + listW and mouseY >= listY and mouseY <= listY + listH
        if mouseInList and KARDS.CardEditor.Canvas._wheelZoomIn then
            KARDS.CardEditor.Canvas._wheelZoomIn = false
            local maxScroll = math.max(0, #loadWindow.files - math.max(1, math.floor(listH / rowH)))
            if loadWindow.scrollOffset > 0 then
                loadWindow.scrollOffset = loadWindow.scrollOffset - 1
                KARDS.CardEditor.Audio.PlayClick()
            end
        elseif mouseInList and KARDS.CardEditor.Canvas._wheelZoomOut then
            KARDS.CardEditor.Canvas._wheelZoomOut = false
            local maxScroll = math.max(0, #loadWindow.files - math.max(1, math.floor(listH / rowH)))
            if loadWindow.scrollOffset < maxScroll then
                loadWindow.scrollOffset = loadWindow.scrollOffset + 1
                KARDS.CardEditor.Audio.PlayClick()
            end
        end

        if isLeftReleased then
            if mouseX >= listX and mouseX <= listX + listW and mouseY >= listY and mouseY <= listY + listH then
                local itemIndex = loadWindow.scrollOffset + math.floor((mouseY - listY) / rowH) + 1
                if itemIndex >= 1 and itemIndex <= #loadWindow.files then
                    loadWindow.selectedFile = loadWindow.files[itemIndex]
                    KARDS.CardEditor.Audio.PlayClick()
                end
            end
            
            local actionBtn = loadWindow.buttons[1]
            if actionBtn.enabled and loadWindow.selectedFile and mouseX >= actionBtn.x and mouseX <= actionBtn.x + actionBtn.width and mouseY >= actionBtn.y and mouseY <= actionBtn.y + actionBtn.height then
                if loadWindow.deleteMode then
                    -- 删除模式：直接删除卡牌文件
                    local fileName = loadWindow.selectedFile
                    local delSuccess = KARDS.CardEditor.SaveSystem.DeleteCard(fileName)
                    if delSuccess then
                        KARDS.CardEditor.Canvas.AddNotification("文件删除成功", Color(50, 200, 50), true)
                        KARDS.CardEditor.Audio.PlaySave()
                    else
                        KARDS.CardEditor.Canvas.AddNotification("文件删除失败", Color(200, 50, 50), false)
                        KARDS.CardEditor.Audio.PlayNotification()
                    end
                    loadWindow.visible = false
                    loadWindow.selectedFile = nil
                    loadWindow.files = {}
                    loadWindow.deleteMode = false
                else
                    -- 加载模式：显示确认对话框
                    local dialog = KARDS.CardEditor.Canvas.LoadConfirmDialog
                    dialog.visible = true
                    dialog.selectedFile = loadWindow.selectedFile
                    dialog.x = loadWindow.x + (loadWindow.width - dialog.width) / 2
                    dialog.y = loadWindow.y + (loadWindow.height - dialog.height) / 2
                    KARDS.CardEditor.Audio.PlayClick()
                end
            end
            
            local cancelBtn = loadWindow.buttons[2]
            if mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height then
                loadWindow.visible = false
                loadWindow.selectedFile = nil
                loadWindow.files = {}
                loadWindow.deleteMode = false
                KARDS.CardEditor.Audio.PlayClick()
            end
        end
        return true
    end
    return false
end

-- 6. 处理标签页和数据端口按钮点击
local function HandleTabAndPortClick(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if isLeftReleased then
        if KARDS.CardEditor.Canvas.CheckTabClick(mouseX, mouseY) then
            return true
        end
        
        -- 处理数据端口按钮点击
        for _, node in ipairs(KARDS.CardEditor.Canvas.Nodes) do
            if not node.isStartNode then
                local nodeX, nodeY = NodeBase.GetScreenPosition(node)
                local portRadius = NodeBase.Config.portRadius
                local clickRadius = NodeBase.Config.clickRadius
                
                -- 检查输出数据点添加按钮
                if node.showAddOutputButton and #node.availableOutputTypes > 0 then
                    local addButtonX = nodeX + node.width / 2 - portRadius
                    local addButtonY = nodeY + node.height + portRadius * 2 + 4
                    if #node.selectedOutputTypes > 0 then
                        addButtonY = addButtonY + portRadius * 3 + 8
                    end
                    
                    local isAddButtonHovered = NodeBase.IsMouseOverPort(addButtonX, addButtonY, mouseX, mouseY, portRadius, clickRadius)
                    if isAddButtonHovered then
                        -- 打开多选下拉框
                        KARDS.CardEditor.Canvas.ExpandedMultiDropdown = node.id .. "_output"
                        
                        -- 计算多列布局
                        local style = KARDS.CardEditor.Canvas.DropdownStyle
                        local screenH = ScrH()
                        local dropdownY = addButtonY + portRadius * 2 + 4
                        local optionWidth = 160
                        local maxRowsPerColumn = math.floor((screenH - dropdownY - style.padding * 2) / style.rowHeight)
                        maxRowsPerColumn = math.max(1, maxRowsPerColumn)
                        local numColumns = math.ceil(#node.availableOutputTypes / maxRowsPerColumn)
                        local totalWidth = numColumns * optionWidth
                        
                        local dropdownH
                        if numColumns == 1 then
                            dropdownH = #node.availableOutputTypes * style.rowHeight + style.padding * 2
                        else
                            dropdownH = maxRowsPerColumn * style.rowHeight + style.padding * 2
                        end
                        
                        local dropdownX = addButtonX + portRadius - totalWidth / 2
                        if dropdownX < 0 then dropdownX = 0 end
                        if dropdownX + totalWidth > ScrW() then dropdownX = ScrW() - totalWidth end
                        
                        KARDS.CardEditor.Canvas.ExpandedMultiDropdownInfo = {
                            x = addButtonX, y = addButtonY, width = portRadius * 2, height = portRadius * 2,
                            nodeId = node.id, dropdownId = "output", dataTypes = node.availableOutputTypes,
                            dropdownX = dropdownX, dropdownY = dropdownY, totalWidth = totalWidth,
                            maxRowsPerColumn = maxRowsPerColumn, dropdownH = dropdownH,
                            numColumns = numColumns, optionWidth = optionWidth
                        }
                        
                        return true
                    end
                end
                
                -- 检查输入数据点添加按钮
                if node.showAddInputButton and #node.availableInputTypes > 0 then
                    local inputPortX = nodeX + node.width / 2 - portRadius
                    local inputPortY = nodeY - portRadius * 2 - 4
                    
                    local isInputButtonHovered = NodeBase.IsMouseOverPort(inputPortX, inputPortY, mouseX, mouseY, portRadius, clickRadius)
                    if isInputButtonHovered then
                        KARDS.CardEditor.Canvas.ExpandedMultiDropdown = node.id .. "_input"
                        
                        local style = KARDS.CardEditor.Canvas.DropdownStyle
                        local screenH = ScrH()
                        local dropdownY = inputPortY - 8
                        local optionWidth = 160
                        local maxRowsPerColumn = math.floor((screenH - dropdownY - style.padding * 2) / style.rowHeight)
                        maxRowsPerColumn = math.max(1, maxRowsPerColumn)
                        local numColumns = math.ceil(#node.availableInputTypes / maxRowsPerColumn)
                        local totalWidth = numColumns * optionWidth
                        
                        local dropdownH
                        if numColumns == 1 then
                            dropdownH = #node.availableInputTypes * style.rowHeight + style.padding * 2
                        else
                            dropdownH = maxRowsPerColumn * style.rowHeight + style.padding * 2
                        end
                        
                        local dropdownX = inputPortX + portRadius - totalWidth / 2
                        if dropdownX < 0 then dropdownX = 0 end
                        if dropdownX + totalWidth > ScrW() then dropdownX = ScrW() - totalWidth end
                        
                        dropdownY = inputPortY - dropdownH - 8
                        
                        KARDS.CardEditor.Canvas.ExpandedMultiDropdownInfo = {
                            x = inputPortX, y = inputPortY, width = portRadius * 2, height = portRadius * 2,
                            nodeId = node.id, dropdownId = "input", dataTypes = node.availableInputTypes,
                            dropdownX = dropdownX, dropdownY = dropdownY, totalWidth = totalWidth,
                            maxRowsPerColumn = maxRowsPerColumn, dropdownH = dropdownH,
                            numColumns = numColumns, optionWidth = optionWidth
                        }
                        
                        return true
                    end
                end
            end
        end
        
        if KARDS.CardEditor.Canvas.HandleDropdownClickOutside(mouseX, mouseY) then
            return true
        end
        
        if KARDS.CardEditor.Canvas.HandleMultiDropdownClickOutside(mouseX, mouseY) then
            return true
        end
    end
    return false
end

-- 7. 处理删除按钮点击
local function HandleDeleteButtonClick(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown)
    if KARDS.CardEditor.Canvas.CurrentPage == "effect" and isLeftReleased and 
       KARDS.CardEditor.Canvas.SelectionState.deleteButtonVisible and 
       KARDS.CardEditor.Canvas.SelectionState.deleteButton then
        local btn = KARDS.CardEditor.Canvas.SelectionState.deleteButton
        if mouseX >= btn.x and mouseX <= btn.x + btn.width and 
           mouseY >= btn.y and mouseY <= btn.y + btn.height then
            KARDS.CardEditor.Canvas.DeleteSelectedNodes()
            return true
        end
    end
    return false
end

-- 8. 处理多选框选逻辑
local function HandleBoxSelection(mouseX, mouseY, isLeftDown, isLeftReleased, isRightDown, isRightReleased)
    if KARDS.CardEditor.Canvas.CurrentPage == "effect" then
        local win = KARDS.CardEditor.Canvas.Window
        local contentX = win.x + 5
        local contentY = win.y + 75
        local selectorW = 180
        local contentH = win.height - 80
        local nodeEditorX = contentX + selectorW
        local nodeEditorW = win.width - 10 - selectorW
        
        local isInNodeEditor = mouseX >= nodeEditorX and mouseX <= nodeEditorX + nodeEditorW and
                              mouseY >= contentY and mouseY <= contentY + contentH
        
        local isOverNodeOrConnection = false
        for _, node in ipairs(KARDS.CardEditor.Canvas.Nodes) do
            local nX, nY
            if node.isStartNode then
                nX = win.x + node.x
                nY = win.y + node.y
            else
                nX = nodeEditorX + node.x
                nY = win.y + node.y
            end
            if mouseX >= nX and mouseX <= nX + node.width and mouseY >= nY and mouseY <= nY + node.height then
                isOverNodeOrConnection = true
                break
            end
        end
        
        if not isOverNodeOrConnection then
            for _, conn in ipairs(KARDS.CardEditor.Canvas.Connections) do
                if KARDS.CardEditor.Canvas.HoveredConnection == conn then
                    isOverNodeOrConnection = true
                    break
                end
            end
        end
        
        -- 处理框选开始
        if isLeftDown and not KARDS.CardEditor.Canvas.SelectionState.isSelecting and
           not KARDS.CardEditor.Canvas.TempNode and not KARDS.CardEditor.Canvas.DraggingNode and
           not KARDS.CardEditor.Canvas.TempConnection and not KARDS.CardEditor.Canvas.ContextMenu and
           not KARDS.CardEditor.Canvas.SelectionState.deleteButtonVisible and
           isInNodeEditor and not isOverNodeOrConnection then
            KARDS.CardEditor.Canvas.SelectionState.isSelecting = true
            KARDS.CardEditor.Canvas.SelectionState.startX = mouseX
            KARDS.CardEditor.Canvas.SelectionState.startY = mouseY
            KARDS.CardEditor.Canvas.SelectionState.selectedNodes = {}
            return true
        end
        
        if KARDS.CardEditor.Canvas.SelectionState.isSelecting then
            local startX = KARDS.CardEditor.Canvas.SelectionState.startX
            local startY = KARDS.CardEditor.Canvas.SelectionState.startY
            local rectLeft = math.min(startX, mouseX)
            local rectTop = math.min(startY, mouseY)
            local rectRight = math.max(startX, mouseX)
            local rectBottom = math.max(startY, mouseY)
            KARDS.CardEditor.Canvas.SelectionState.selectedNodes = {}
            for _, node in ipairs(KARDS.CardEditor.Canvas.Nodes) do
                if not node.isStartNode and node.canDelete ~= false then
                    local nX = nodeEditorX + node.x
                    local nY = win.y + node.y
                    local nodeRight = nX + node.width
                    local nodeBottom = nY + node.height
                    if not (nodeRight < rectLeft or nX > rectRight or nodeBottom < rectTop or nY > rectBottom) then
                        table.insert(KARDS.CardEditor.Canvas.SelectionState.selectedNodes, node)
                    end
                end
            end
        end
        
        if isLeftReleased and KARDS.CardEditor.Canvas.SelectionState.isSelecting then
            KARDS.CardEditor.Canvas.SelectionState.isSelecting = false
            if #KARDS.CardEditor.Canvas.SelectionState.selectedNodes > 0 then
                KARDS.CardEditor.Canvas.SelectionState.deleteButtonVisible = true
                KARDS.CardEditor.Canvas.SelectionState.deleteButton = {
                    x = mouseX + 10, y = mouseY + 10, width = 140, height = 35
                }
            end
            return true
        end
        
        if isLeftReleased and KARDS.CardEditor.Canvas.SelectionState.deleteButtonVisible then
            local btn = KARDS.CardEditor.Canvas.SelectionState.deleteButton
            if not btn or not (mouseX >= btn.x and mouseX <= btn.x + btn.width and 
                               mouseY >= btn.y and mouseY <= btn.y + btn.height) then
                KARDS.CardEditor.Canvas.SelectionState.selectedNodes = {}
                KARDS.CardEditor.Canvas.SelectionState.deleteButtonVisible = false
            end
        end
    end
    return false
end

-- 9. 处理节点选择器拖拽和端口点击
local function HandleNodeDragDrop(mouseX, mouseY, isLeftDown, isRightDown)
    if isLeftDown and KARDS.CardEditor.Canvas.CurrentPage == "effect" and 
       not KARDS.CardEditor.Canvas.SelectionState.isSelecting then
        if KARDS.CardEditor.Canvas.CheckNodeSelectorClick(mouseX, mouseY) then
            return true
        end
        if not KARDS.CardEditor.Canvas.TempNode and not KARDS.CardEditor.Canvas.DraggingNode and KARDS.CardEditor.Canvas.CheckPortClick(mouseX, mouseY) then
            return true
        end
        if not KARDS.CardEditor.Canvas.TempNode and not KARDS.CardEditor.Canvas.TempConnection and not KARDS.CardEditor.Canvas.DraggingNode and KARDS.CardEditor.Canvas.CheckNodeDragStart(mouseX, mouseY) then
            return true
        end
    end
    return false
end

-- 10. 处理临时节点拖拽和连接完成
local function HandleTempNodeAndConnection(mouseX, mouseY, isLeftDown, isLeftReleased, isRightDown)
    if KARDS.CardEditor.Canvas.TempNode and isLeftDown then
        KARDS.CardEditor.Canvas.TempNode.x = mouseX - 100
        KARDS.CardEditor.Canvas.TempNode.y = mouseY - 40
    end
    
    if isLeftReleased then
        if KARDS.CardEditor.Canvas.TempNode then
            KARDS.CardEditor.Canvas.FinishTempNode(mouseX, mouseY)
        elseif KARDS.CardEditor.Canvas.TempConnection then
            KARDS.CardEditor.Canvas.FinishTempConnection(mouseX, mouseY)
        end
        
        if KARDS.CardEditor.Canvas.DraggingNode then
            local win = KARDS.CardEditor.Canvas.Window
            local node = KARDS.CardEditor.Canvas.DraggingNode
            local contentX = win.x + 5
            local contentY = win.y + 75
            local selectorW = 180
            local contentH = win.height - 80
            local isInSelector = mouseX >= contentX and mouseX <= contentX + selectorW and
                               mouseY >= contentY and mouseY <= contentY + contentH
            if isInSelector then
                local connectionsToRemove = {}
                for i, conn in ipairs(KARDS.CardEditor.Canvas.Connections) do
                    if conn.fromNode == node.id or conn.toNode == node.id then table.insert(connectionsToRemove, i) end
                end
                for i = #connectionsToRemove, 1, -1 do
                    table.remove(KARDS.CardEditor.Canvas.Connections, connectionsToRemove[i])
                end
                for i, n in ipairs(KARDS.CardEditor.Canvas.Nodes) do
                    if n.id == node.id then table.remove(KARDS.CardEditor.Canvas.Nodes, i) break end
                end
            end
            node.dragging = false
            KARDS.CardEditor.Canvas.DraggingNode = nil
        end
    end
end

-- 11. 处理节点拖拽位置更新
local function HandleNodePositionUpdate(mouseX, mouseY, isLeftDown)
    if KARDS.CardEditor.Canvas.DraggingNode and KARDS.CardEditor.Canvas.DraggingNode.dragging then
        local win = KARDS.CardEditor.Canvas.Window
        local node = KARDS.CardEditor.Canvas.DraggingNode
        local dx = mouseX - node.dragStartX
        local dy = mouseY - node.dragStartY
        local contentX = win.x + 5
        local contentY = win.y + 45
        local selectorW = 180
        local nodeEditorX = contentX + selectorW
        local nodeEditorW = win.width - 10 - selectorW
        local nodeEditorH = win.height - 50
        local newX = node.startX + dx
        local newY = node.startY + dy
        newX = math.max(0, math.min(newX, nodeEditorW - node.width))
        newY = math.max(0, math.min(newY, nodeEditorH - node.height))
        node.x = newX
        node.y = newY
    end
end

-- 12. 处理悬停连接检测
local function HandleHoverConnection(mouseX, mouseY)
    local hoveredConn = nil
    local win = KARDS.CardEditor.Canvas.Window
    local contentX = win.x + 5
    local selectorW = 180
    local nodeEditorX = contentX + selectorW
    for _, conn in ipairs(KARDS.CardEditor.Canvas.Connections) do
        local fromNode = KARDS.CardEditor.Canvas.GetNodeById(conn.fromNode)
        local toNode = KARDS.CardEditor.Canvas.GetNodeById(conn.toNode)
        if fromNode and toNode then
            local fromX, fromY
            local portRadius = 6
            if fromNode.isStartNode then
                local absoluteNodeX = win.x + fromNode.x
                if fromNode.type == "condition" or fromNode.type == "event_monitor" or fromNode.type == "loop" then
                    if conn.fromPort == "output1" then
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height / 3 + portRadius
                    elseif conn.fromPort == "output2" then
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height * 2 / 3 + portRadius
                    else
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height / 2
                    end
                else
                    fromX = absoluteNodeX + fromNode.width
                    fromY = win.y + fromNode.y + fromNode.height / 2
                end
            else
                local absoluteNodeX = nodeEditorX + fromNode.x
                if fromNode.type == "condition" or fromNode.type == "event_monitor" or fromNode.type == "loop" then
                    if conn.fromPort == "output1" then
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height / 3 + portRadius
                    elseif conn.fromPort == "output2" then
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height * 2 / 3 + portRadius
                    else
                        fromX = absoluteNodeX + fromNode.width
                        fromY = win.y + fromNode.y + fromNode.height / 2
                    end
                else
                    fromX = absoluteNodeX + fromNode.width
                    fromY = win.y + fromNode.y + fromNode.height / 2
                end
            end
            local toX = nodeEditorX + toNode.x
            local toY = win.y + toNode.y + toNode.height / 2
            local distance = toX - fromX
            local controlPoint1X = fromX + distance / 3
            local controlPoint1Y = fromY
            local controlPoint2X = fromX + distance * 2 / 3
            local controlPoint2Y = toY
            local points = KARDS.CardEditor.Canvas.BezierCurve(fromX, fromY, controlPoint1X, controlPoint1Y, controlPoint2X, controlPoint2Y, toX, toY)
            if KARDS.CardEditor.Canvas.IsMouseNearCurve(points, mouseX, mouseY, 15) then
                hoveredConn = conn
                break
            end
        end
    end
    KARDS.CardEditor.Canvas.HoveredConnection = hoveredConn
end

-- 13. 处理右键菜单
local function HandleContextMenu(mouseX, mouseY, isRightReleased, isLeftDown, isRightDown)
    if isRightReleased then
        local hoveredConn = KARDS.CardEditor.Canvas.HoveredConnection
        local hoveredNode = KARDS.CardEditor.Canvas.HoveredNode
        if hoveredConn then
            KARDS.CardEditor.Canvas.ContextMenu = {
                x = mouseX + 10, y = mouseY + 10, width = 100, height = 30,
                visible = true, connection = hoveredConn
            }
        elseif hoveredNode and hoveredNode.canDelete ~= false then
            KARDS.CardEditor.Canvas.ContextMenu = {
                x = mouseX + 10, y = mouseY + 10, width = 100, height = 30,
                visible = true, node = hoveredNode
            }
        end
    end

    if isLeftDown and not isRightDown then
        if KARDS.CardEditor.Canvas.ContextMenu and KARDS.CardEditor.Canvas.ContextMenu.visible then
            local menu = KARDS.CardEditor.Canvas.ContextMenu
            if mouseX >= menu.x and mouseX <= menu.x + menu.width and
               mouseY >= menu.y and mouseY <= menu.y + menu.height then
                if menu.connection then
                    local conn = menu.connection
                    for i, c in ipairs(KARDS.CardEditor.Canvas.Connections) do
                        if c.id == conn.id then
                            table.remove(KARDS.CardEditor.Canvas.Connections, i)
                            KARDS.CardEditor.Audio.PlayDelete()
                            break
                        end
                    end
                elseif menu.node then
                    local node = menu.node
                    local connectionsToRemove = {}
                    for i, conn in ipairs(KARDS.CardEditor.Canvas.Connections) do
                        if conn.fromNode == node.id or conn.toNode == node.id then
                            table.insert(connectionsToRemove, i)
                        end
                    end
                    for i = #connectionsToRemove, 1, -1 do
                        table.remove(KARDS.CardEditor.Canvas.Connections, connectionsToRemove[i])
                    end
                    for i, n in ipairs(KARDS.CardEditor.Canvas.Nodes) do
                        if n.id == node.id then
                            table.remove(KARDS.CardEditor.Canvas.Nodes, i)
                            KARDS.CardEditor.Audio.PlayDelete()
                            break
                        end
                    end
                end
            end
            KARDS.CardEditor.Canvas.ContextMenu = nil
        end
    end
end

local function DrawFileManagerInternal(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt, fs, state)

    -- 绘制背景
    draw.RoundedBox(6, fmX, fmY, fmW, fmH, Color(25, 25, 30))
    draw.RoundedBox(6, fmX + 1, fmY + 1, fmW - 2, fmH - 2, Color(30, 30, 35))

    -- 获取当前文件夹内容
    local currentFolder = fs
    for _, idx in ipairs(state.navStack) do
        if currentFolder.children and currentFolder.children[idx] then
            currentFolder = currentFolder.children[idx]
        else
            break
        end
    end

    -- 构建显示列表
    local items = {}
    if #state.navStack > 0 then
        table.insert(items, { name = ".. 返回上一级", type = "back" })
    end
    for i, child in ipairs(currentFolder.children or {}) do
        table.insert(items, { entry = child, name = child.name, type = child.type, idx = i })
    end

    -- 更新滑动动画（从右侧平移到左侧）
    if state.animOffset > 0 then
        state.animOffset = math.max(0, state.animOffset - dt * 2000)
    end

    -- 启用剪切矩形，确保内容只在文件管理器矩形内渲染
    render.SetScissorRect(fmX, fmY, fmX + fmW, fmY + fmH, true)

    -- 绘制项目列表
    local itemH = 20
    local listStartY = fmY + 5
    local hoveredItem = nil

    for i, item in ipairs(items) do
        local iy = listStartY + (i - 1) * itemH
        -- X方向偏移实现从右侧平移到
        local ix = fmX + 4 + state.animOffset
        if ix < fmX + fmW - 4 then
            local isHov = IsMouseIn(mx, my, ix, iy, fmW - 8, itemH)
            if isHov then
                hoveredItem = item
            end

            local textColor = Color(200, 200, 200)
            local prefix = ""
            local isSelected = false

            if item.type == "back" then
                textColor = Color(180, 180, 100)
                prefix = "← "
            elseif item.type == "folder" then
                textColor = Color(180, 200, 255)
                prefix = "+ "
            elseif item.type == "file" then
                isSelected = state.selectedEntry and state.selectedEntry.name == item.name
                if isSelected then
                    textColor = Color(80, 180, 255)
                else
                    textColor = Color(200, 200, 200)
                end
            end

            if isHov then
                draw.RoundedBox(4, ix, iy, fmW - 8, itemH, Color(55, 55, 65))
            end

            local displayText = prefix .. (item.entry and item.entry.display or item.name)
            if isSelected then
                displayText = "✓ " .. (item.entry and item.entry.display or item.name)
            end
            draw.SimpleText(displayText, "SourceHan_Heavy_12", ix + 6, iy + itemH / 2, textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end

    -- 禁用剪切矩形
    render.SetScissorRect(0, 0, 0, 0, false)

    -- 点击处理
    if isLeftPressed and hoveredItem then
        if hoveredItem.type == "back" then
            table.remove(state.navStack)
            state.selectedEntry = nil
            state.showConfirm = false
            state.showOverlay = false
        elseif hoveredItem.type == "folder" then
            if hoveredItem.entry and hoveredItem.idx then
                table.insert(state.navStack, hoveredItem.idx)
                state.animOffset = fmW
                state.selectedEntry = nil
                state.showConfirm = false
                state.showOverlay = false
            end
        elseif hoveredItem.type == "file" then
            state.selectedEntry = hoveredItem.entry
            state.showConfirm = true
            state.showOverlay = false
        end
    end

    -- 确认/取消按钮行
    if state.showConfirm and state.selectedEntry then
        local confirmY = fmY + fmH - 52
        draw.RoundedBox(4, fmX + 4, confirmY, fmW - 8, 48, Color(20, 20, 25, 230))

        local fileName = state.selectedEntry.display or state.selectedEntry.name
        draw.SimpleText("选择 '" .. fileName .. "'？", "SourceHan_Heavy_12", fmX + fmW / 2, confirmY + 8, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        local btnW = 55
        local btnH = 20
        local btnGap = 8
        local totalBtnW = btnW * 2 + btnGap
        local btnStartX = fmX + (fmW - totalBtnW) / 2
        local btnY2 = confirmY + 26

        local selBtnX = btnStartX
        local selHov = IsMouseIn(mx, my, selBtnX, btnY2, btnW, btnH)
        KARDS.CardEditor.Canvas.DrawHoverButton(selBtnX, btnY2, btnW, btnH, "选择", selHov, { hoverBg = Color(80, 170, 80), normalBg = Color(60, 130, 60), font = "SourceHan_Heavy_12" })

        local noBtnX = btnStartX + btnW + btnGap
        local noHov = IsMouseIn(mx, my, noBtnX, btnY2, btnW, btnH)
        KARDS.CardEditor.Canvas.DrawHoverButton(noBtnX, btnY2, btnW, btnH, "不选", noHov, { hoverBg = Color(170, 80, 80), normalBg = Color(130, 60, 60), font = "SourceHan_Heavy_12" })

        if isLeftPressed then
            if selHov then
                state.showOverlay = true
                state.showConfirm = false
            elseif noHov then
                state.selectedEntry = nil
                state.showConfirm = false
            end
        end
    end

    -- 选择成功叠加层（全等半透明黑色 + 五角星）
    if state.showOverlay and state.selectedEntry then
        draw.RoundedBox(6, fmX, fmY, fmW, fmH, Color(0, 0, 0, 180))

        local starCX = fmX + fmW / 2
        local starCY = fmY + fmH / 2 - 18
        local starOuterR = 22
        local starInnerR = 9

        -- 构建五角星顶点
        local starVerts = {}
        for i = 0, 9 do
            local angle = math.rad(-90 + i * 36)
            local r = (i % 2 == 0) and starOuterR or starInnerR
            table.insert(starVerts, {
                x = starCX + math.cos(angle) * r,
                y = starCY + math.sin(angle) * r
            })
        end

        local isStarHov = IsMouseIn(mx, my, starCX - starOuterR, starCY - starOuterR, starOuterR * 2, starOuterR * 2)

        if isStarHov then
            -- 悬停时只绘制厚描边空心星（不绘制实心星）
            surface.SetDrawColor(255, 220, 0)
            draw.NoTexture()
            for i = 1, #starVerts do
                local next = i % #starVerts + 1
                surface.DrawLine(starVerts[i].x, starVerts[i].y, starVerts[next].x, starVerts[next].y)
                -- 加粗描边
                surface.DrawLine(starVerts[i].x + 1, starVerts[i].y, starVerts[next].x + 1, starVerts[next].y)
                surface.DrawLine(starVerts[i].x, starVerts[i].y + 1, starVerts[next].x, starVerts[next].y + 1)
            end
        else
            -- 未悬停时绘制实心五角星
            surface.SetDrawColor(255, 220, 0)
            draw.NoTexture()
            for i = 1, #starVerts do
                local next = starVerts[i % #starVerts + 1]
                surface.DrawPoly({
                    {x = starCX, y = starCY},
                    starVerts[i],
                    next
                })
            end
        end

        -- 下方文字
        local fileName = state.selectedEntry.display or state.selectedEntry.name
        draw.SimpleText("已选择", "SourceHan_Heavy_16", starCX, starCY + starOuterR + 12, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        draw.SimpleText(fileName, "SourceHan_Heavy_14", starCX, starCY + starOuterR + 34, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        if isLeftPressed and isStarHov then
            state.selectedEntry = nil
            state.showOverlay = false
            state.showConfirm = false
        end
    end
end

-- 特效文件管理器封装器
local function DrawEffectFileManager(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt)
    DrawFileManagerInternal(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt,
        KARDS.CardEditor.Canvas.EffectFileSystem,
        KARDS.CardEditor.Canvas.EffectFileState)
end

-- 子类型文件管理器封装器
-- 子类型选择器（继承文件管理器，支持选择文件后读取子类型）
local function DrawSubtypeSelector(fmX, fmY, fmW, fmH, mx, my, isLeftPressed, dt)
    local state = KARDS.CardEditor.Canvas.SubtypeFileState
    local fs = KARDS.CardEditor.Canvas.SubtypeFileSystem

    -- 绘制背景
    draw.RoundedBox(6, fmX, fmY, fmW, fmH, Color(25, 25, 30))
    draw.RoundedBox(6, fmX + 1, fmY + 1, fmW - 2, fmH - 2, Color(30, 30, 35))

    -- ===== 模式 3: 选择成功叠加层 =====
    if state.showOverlay and state.selectedSubtype then
        draw.RoundedBox(6, fmX, fmY, fmW, fmH, Color(0, 0, 0, 180))

        local starCX = fmX + fmW / 2
        local starCY = fmY + fmH / 2 - 18
        local starOuterR = 22
        local starInnerR = 9

        local starVerts = {}
        for i = 0, 9 do
            local angle = math.rad(-90 + i * 36)
            local r = (i % 2 == 0) and starOuterR or starInnerR
            table.insert(starVerts, {
                x = starCX + math.cos(angle) * r,
                y = starCY + math.sin(angle) * r
            })
        end

        local isStarHov = IsMouseIn(mx, my, starCX - starOuterR, starCY - starOuterR, starOuterR * 2, starOuterR * 2)

        if isStarHov then
            surface.SetDrawColor(255, 220, 0)
            draw.NoTexture()
            for i = 1, #starVerts do
                local next = i % #starVerts + 1
                surface.DrawLine(starVerts[i].x, starVerts[i].y, starVerts[next].x, starVerts[next].y)
                surface.DrawLine(starVerts[i].x + 1, starVerts[i].y, starVerts[next].x + 1, starVerts[next].y)
                surface.DrawLine(starVerts[i].x, starVerts[i].y + 1, starVerts[next].x, starVerts[next].y + 1)
            end
        else
            surface.SetDrawColor(255, 220, 0)
            draw.NoTexture()
            for i = 1, #starVerts do
                local next = starVerts[i % #starVerts + 1]
                surface.DrawPoly({
                    {x = starCX, y = starCY},
                    starVerts[i],
                    next
                })
            end
        end

        draw.SimpleText("已选择", "SourceHan_Heavy_16", starCX, starCY + starOuterR + 12, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        draw.SimpleText(state.selectedSubtype, "SourceHan_Heavy_14", starCX, starCY + starOuterR + 34, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        if isLeftPressed and isStarHov then
            state.selectedSubtype = nil
            state.showOverlay = false
            state.isSelectingSubtype = false
            state.subtypeOptions = nil
            state.selectedEntry = nil
            state.showConfirm = false
        end
        return
    end

    -- ===== 模式 2: 子类型选择列表 =====
    if state.isSelectingSubtype and state.subtypeOptions then
        local itemH = 20
        local listStartY = fmY + 5

        -- "< 返回文件选择" 选项
        local backY = listStartY
        local backHov = IsMouseIn(mx, my, fmX + 4, backY, fmW - 8, itemH)
        draw.RoundedBox(3, fmX + 4, backY, fmW - 8, itemH - 2, backHov and Color(50, 50, 55) or Color(0, 0, 0, 0))
        draw.SimpleText("< 返回文件选择", "SourceHan_Heavy_12", fmX + 10, backY + itemH / 2, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        if isLeftPressed and backHov then
            state.isSelectingSubtype = false
            state.subtypeOptions = nil
            state.selectedEntry = nil
            state.showConfirm = false
        end

        -- 子类型选项列表
        for i, subtypeName in ipairs(state.subtypeOptions) do
            local iy = listStartY + i * itemH
            if iy + itemH <= fmY + fmH - 4 then
                local isHov = IsMouseIn(mx, my, fmX + 4, iy, fmW - 8, itemH)
                draw.RoundedBox(3, fmX + 4, iy, fmW - 8, itemH - 2, isHov and Color(60, 60, 65) or Color(0, 0, 0, 0))
                draw.SimpleText(subtypeName, "SourceHan_Heavy_14", fmX + 10, iy + itemH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

                if isLeftPressed and isHov then
                    state.selectedSubtype = subtypeName
                    state.showOverlay = true
                end
            end
        end
        return
    end

    -- ===== 模式 1: 文件浏览（复用文件管理器逻辑） =====
    local currentFolder = fs
    for _, idx in ipairs(state.navStack) do
        if currentFolder.children and currentFolder.children[idx] then
            currentFolder = currentFolder.children[idx]
        else break end
    end

    -- 构建显示列表
    local items = {}
    if #state.navStack > 0 then
        table.insert(items, { name = ".. 返回上一级", type = "back" })
    end
    for i, child in ipairs(currentFolder.children or {}) do
        table.insert(items, { entry = child, name = child.name, type = child.type, idx = i })
    end

    -- 滑动动画（从右向左平移）
    if state.animOffset > 0 then
        state.animOffset = math.max(0, state.animOffset - dt * 2000)
    end

    -- 裁剪渲染区域（只在矩形内渲染）
    render.SetScissorRect(fmX, fmY, fmX + fmW, fmY + fmH, true)

    local itemH = 20
    local listStartY = fmY + 5
    local hoveredItem = nil

    for i, item in ipairs(items) do
        local ix = fmX + 4 + state.animOffset
        local iy = listStartY + (i - 1) * itemH

        if iy + itemH >= fmY and iy <= fmY + fmH then
            local isHov = IsMouseIn(mx, my, ix, iy, fmW - 8, itemH - 2)
            if isHov then hoveredItem = item end

            local prefix = ""
            if item.type == "folder" then
                prefix = "📁 "
            elseif item.type == "file" and state.selectedEntry and state.selectedEntry == item.entry then
                prefix = "✓ "
            end

            draw.RoundedBox(3, ix, iy, fmW - 8, itemH - 2, isHov and Color(50, 50, 55) or Color(0, 0, 0, 0))

            local textColor = Color(220, 220, 220)
            if item.type == "file" and state.selectedEntry and state.selectedEntry == item.entry then
                textColor = Color(80, 140, 220)
            end

            local displayText = prefix .. (item.entry and (item.entry.display or item.entry.name) or item.name)
            draw.SimpleText(displayText, "SourceHan_Heavy_14", ix + 4, iy + itemH / 2, textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end

    render.SetScissorRect(0, 0, 0, 0, false)

    -- 点击处理
    if isLeftPressed and hoveredItem then
        if hoveredItem.type == "back" then
            table.remove(state.navStack)
            state.selectedEntry = nil
            state.showConfirm = false
            state.animOffset = 0
        elseif hoveredItem.type == "folder" then
            table.insert(state.navStack, hoveredItem.idx)
            state.animOffset = fmW
            state.selectedEntry = nil
            state.showConfirm = false
        elseif hoveredItem.type == "file" then
            state.selectedEntry = hoveredItem.entry
            if not state.showConfirm then
                state.showConfirm = true
            else
                state.showConfirm = false
            end
        end
    end

    -- 确认/取消按钮行
    if state.showConfirm and state.selectedEntry then
        local btnY = fmY + fmH - 44
        draw.RoundedBox(4, fmX + 2, btnY, fmW - 4, 42, Color(20, 20, 25, 200))

        local fileName = state.selectedEntry.display or state.selectedEntry.name
        draw.SimpleText("选择 '" .. fileName .. "'？", "SourceHan_Heavy_12", fmX + fmW / 2, btnY + 6, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        local btnW = 50
        local btnH = 20
        local btnGap = 10
        local btnStartX = fmX + (fmW - btnW * 2 - btnGap) / 2
        local btnY2 = btnY + 20

        -- "选择" 按钮：读取 lua 文件并进入子类型选择模式
        local selHov = IsMouseIn(mx, my, btnStartX, btnY2, btnW, btnH)
        KARDS.CardEditor.Canvas.DrawHoverButton(btnStartX, btnY2, btnW, btnH, "选择", selHov, { hoverBg = Color(60, 160, 60), normalBg = Color(50, 110, 50), font = "SourceHan_Heavy_12" })

        -- "不选" 按钮：取消
        local noBtnX = btnStartX + btnW + btnGap
        local noHov = IsMouseIn(mx, my, noBtnX, btnY2, btnW, btnH)
        KARDS.CardEditor.Canvas.DrawHoverButton(noBtnX, btnY2, btnW, btnH, "不选", noHov, { hoverBg = Color(170, 80, 80), normalBg = Color(130, 60, 60), font = "SourceHan_Heavy_12" })

        if isLeftPressed then
            if selHov then
                -- 读取 lua 文件获取子类型列表
                local filePath = state.selectedEntry.fullPath
                if filePath then
                    local content = file.Read(filePath, "DATA")
                    if content then
                        local ok, func = CompileString(content, "subtype_loader")
                        if ok then
                            local success, data = pcall(func)
                            if success and type(data) == "table" then
                                -- 过滤出有效子类型（去掉空的）
                                local validTypes = {}
                                for _, v in ipairs(data) do
                                    if v and #tostring(v) > 0 then
                                        table.insert(validTypes, v)
                                    end
                                end
                                state.subtypeOptions = validTypes
                                state.isSelectingSubtype = true
                                state.showConfirm = false
                            end
                        end
                    end
                end
            elseif noHov then
                state.selectedEntry = nil
                state.showConfirm = false
            end
        end
    end
end

-- 导出文件管理器和子类型选择器供 cl_ca_appearance_editors.lua 使用
KARDS.CardEditor.Canvas.DrawEffectFileManager = DrawEffectFileManager
KARDS.CardEditor.Canvas.DrawSubtypeSelector = DrawSubtypeSelector

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
    
    -- 显式绘制 INE 面板并记录帧号：确保 INE 绘制在 Canvas 内容之后（最顶层）。
    -- 不依赖 HUDPaint 钩子注册顺序（Lua pairs 遍历顺序不保证 FIFO），
    -- 避免 Canvas 的不透明内容区背景盖住 INE 面板导致面板不可见（此前出现过该问题）。
    -- INE_DrawEditors 钩子通过帧号防重跳过本帧，不会重复绘制。
    local ineDraw = KARDS.CardEditor.IndependentNodeEditor
    if ineDraw and ineDraw.DrawAllEditorsInternal then
        ineDraw._canvasDrawnFrame = FrameNumber()
        ineDraw:DrawAllEditorsInternal()
    end
end



-- 滚轮缩放标记（CreateMove 中设值，Draw 中消费）
-- 用于卡牌插图预览和卡牌预览图的滚轮缩放
hook.Add("CreateMove", "KARDS_Canvas_Wheel", function(cmd)
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
-- HandleInput - 调用已拆分的局部子函数
-- 原单体函数已拆分为 13 个局部函数（见上方 HandleXxx 定义）
-- ================================================================
function KARDS.CardEditor.Canvas.HandleInput()
    -- 更新提示状态
    KARDS.CardEditor.Canvas.UpdateNotifications()
    
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local isLeftDown = input.IsMouseDown(MOUSE_LEFT)
    local isLeftReleased = not isLeftDown and KARDS.CardEditor.Canvas.LastMouseState
    local isRightDown = input.IsMouseDown(MOUSE_RIGHT)
    local isRightReleased = not isRightDown and KARDS.CardEditor.Canvas.LastRightMouseState

    -- 依次处理各输入子模块（若返回 true 表示已消费该输入，不再继续处理）
    if HandleCardSelectorInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown) then
        KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
        KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
        return
    end
    
    if HandleFileMenuInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown) then
        KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
        KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
        return
    end
    
    if HandleSaveWindowInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown) then
        KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
        KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
        return
    end
    
    if HandleLoadConfirmInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown) then
        KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
        KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
        return
    end
    
    if HandleFileSelectInput(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown) then
        KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
        KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
        return
    end
    
    if HandleTabAndPortClick(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown) then
        KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
        KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
        return
    end
    
    if HandleDeleteButtonClick(mouseX, mouseY, isLeftReleased, isLeftDown, isRightDown) then
        KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
        KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
        return
    end
    
    if HandleBoxSelection(mouseX, mouseY, isLeftDown, isLeftReleased, isRightDown, isRightReleased) then
        KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
        KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
        return
    end
    
    if HandleNodeDragDrop(mouseX, mouseY, isLeftDown, isRightDown) then
        KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
        KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
        return
    end
    
    -- 以下函数不提前返回（仅更新状态/位置）
    HandleTempNodeAndConnection(mouseX, mouseY, isLeftDown, isLeftReleased, isRightDown)
    HandleNodePositionUpdate(mouseX, mouseY, isLeftDown)
    HandleHoverConnection(mouseX, mouseY)
    HandleContextMenu(mouseX, mouseY, isRightReleased, isLeftDown, isRightDown)

    KARDS.CardEditor.Canvas.LastRightMouseState = isRightDown
    KARDS.CardEditor.Canvas.LastMouseState = isLeftDown
end



