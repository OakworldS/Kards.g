--[[
    Kards 战斗系统 - 卡牌 3D2D 属性文字叠加层（客户端）

    卡牌动态属性文字：卡牌实体正面纹理使用「无属性文字」的模板卡面（hideNumbers
    离屏渲染），属性数字与效果描述以 3D2D 文字（cam.Start3D2D + SourceHan_Heavy
    字体）实时悬浮在卡牌上方对应属性位置（费用左上 / 行动花费 / 攻击左下 /
    防御右下 / 描述底部），每帧从数据源读取当前属性 → 属性变化即外观变化
    （文字不烘焙进纹理，随卡牌实体朝向/位置悬浮）。

    数据源三种（ReadData 统一读取）：
      - 本地静态表（外观编辑器 app / cardData 表）            → AddLocal
      - 战斗卡牌对象（CardInterface mock，本地引用实时读）      → AddLocal（data 为卡牌对象）
      - 战场网络实体（属性经服务端 NW 变量同步，sh_battle_render）→ AddEntity

    使用方式：
      KARDS.CardTextOverlay:AddLocal(ent, data, worldW, worldH, renderW, renderH)
      KARDS.CardTextOverlay:AddEntity(ent, worldW, worldH)
      KARDS.CardTextOverlay:Remove(ent)
      KARDS.CardTextOverlay:Clear()
]]

if not CLIENT then return end

KARDS = KARDS or {}
KARDS.CardTextOverlay = KARDS.CardTextOverlay or {}
local Overlay = KARDS.CardTextOverlay

-- 注册表：Ents[ent] = { mode = "local" | "entity", data, worldW, worldH, renderW, renderH }
Overlay.Ents = Overlay.Ents or {}

-- 卡面世界尺寸缺省（basic_card manifest bounds 36x54x0.45 × 0.2 = 7.2x10.8x0.09；
-- 战场/编辑器实体卡面宽高可用此值，也可传参覆盖）
local DEFAULT_W, DEFAULT_H = 7.2, 10.8

-- 3D2D 属性文字像素位置（RT 左上原点、y 向下）。
-- 以离屏渲染（_Render 版，cl_card_preview.lua）的位置为基准，经多轮外观对齐微调定稿：
-- 费用 (15,12) 左上 / 行动花费 (29,20) / 攻击左下 X=53.5、自底部 73.5 /
-- 防御自右 55、自底部 73.5 / 词条锚点自底部 50；无词条描述锚点 40、有词条描述锚点 30；
-- 指令卡描述自顶部 250；指令卡费用独立 (18,11)（指令模板费用位与单位有微小差异）。
local COST_X, COST_Y = 15, 12          -- 费用（左上）
-- 指令卡费用独立位置：指令模板与单位模板的卡牌花费处位置有微小差异，故单独计算
local COMMAND_COST_X, COMMAND_COST_Y = 18, 11
local ACTION_X, ACTION_Y = 29, 20      -- 行动花费（费用右侧，非指令卡）
local ATTACK_X, ATTACK_BOTTOM = 53.5, 73.5  -- 攻击（左下，自底部向上偏移）
local DEFENSE_RIGHT, DEFENSE_BOTTOM = 55, 73.5 -- 防御（右下，自底部向上偏移）——总部防御位（不与其他卡型共用）
local KEYWORDS_BOTTOM = 50             -- 词条区域（自底部向上偏移）
local DESC_BOTTOM = 40                 -- 描述区域（自底部向上偏移，无词条时锚点）
local DESC_BOTTOM_KEYWORDS = 30        -- 描述区域（有词条时锚点，紧贴词条下方）
local DESC_COMMAND_TOP = 250            -- 描述区域（指令卡：名称下方）
local DESC_COMMAND_TOP_HQ = 262.5        -- 描述区域（总部：较指令卡下移量减半，原 25 降为 12.5）

-- 单位短卡专用坐标（2026-08-11）：单位部署后的战场小模型（basic_card_unit，渲染尺寸
-- 209×290 + UV 裁切 V 轴 229/290），像素布局与完整卡（默认 300×400 纹理）不同，故
-- 独立一组常量，微调单位短卡时不影响完整单位卡。攻击与防御 y 共享 UNIT_ATTACK_BOTTOM，
-- 保证二者水平对齐（用户要求攻击与防御 y 相等）。
local UNIT_COST_X, UNIT_COST_Y = 15, 40           -- 单位短卡行动花费（替代卡牌花费位置，左上）
local UNIT_ATTACK_X, UNIT_ATTACK_BOTTOM = 53.5, 40-- 单位短卡攻击（左下，自底部向上偏移）
local UNIT_DEFENSE_OFFSET = 99                    -- 单位短卡防御：x = 攻击 x + 偏移（y 与攻击相同）

-- 悬浮沿法线偏移（避免与卡面 Z-fighting）。
-- 取值需权衡：过大则微观尺度（卡面仅 7.2×10.8）下视差明显、从斜角观察文字相对卡面
-- 纹理错位；过小则深度竞争产生闪烁。0.06 ≈ 2.5 渲染像素（scale=0.024），约为卡面厚度
-- （0.09）的 2/3，接近贴面且能稳定通过深度测试。
local FLOAT_OFFSET = 0.06

-- 属性文字颜色：数字白字（与离屏渲染一致）；词条/描述纯黑字（全部无描边）
local COLOR_NUMBER = Color(201, 195, 169, 255)     -- 数值文字（花费/行动花费/攻击/防御）统一近白色 C9C3A9，符合卡牌模板风格；与 cl_card_preview.lua 的 VALUE_TEXT_COLOR 同色
local COLOR_DESC = Color(0, 0, 0, 255)              -- 词条/描述文字（纯黑）

--[[
    动态文字颜色系统（2026-08-10）：
    每个 3D2D 文字槽位（cost / actionCost / attack / defense / keywords / desc）
    可被代码随时设置目标颜色并以指定时长平滑渐变（Overlay:SetColor，时长 0 = 立即）；
    未设置时使用默认颜色（DefaultColors）。渐变由 DrawOverlay 每帧推进，
    颜色状态挂在 entry.colors[slot] = { cur=当前绘制色, from=渐变起点, target=目标色,
    start=渐变起始时间, dur=渐变时长 }。
]]
Overlay.ColorSlots = { "cost", "actionCost", "attack", "defense", "keywords", "desc" }
Overlay.DefaultColors = {
    cost = COLOR_NUMBER,
    actionCost = COLOR_NUMBER,
    attack = COLOR_NUMBER,
    defense = COLOR_NUMBER,
    keywords = COLOR_DESC,
    desc = COLOR_DESC,
}

-- 复制颜色值（返回新 Color 对象，避免渐变改写共享默认色对象）
local function CloneColor(c)
    return Color(c.r, c.g, c.b, c.a)
end

-- 新建槽位颜色状态（cur/from/target 初始均为默认色，无渐变）
local function NewColorState(color)
    local c = CloneColor(color)
    return { cur = c, from = c, target = c, start = 0, dur = 0 }
end

-- 颜色线性插值（t ∈ [0,1]，返回新 Color 对象）
local function LerpColors(t, a, b)
    return Color(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
end

-- 每帧推进 entry 全部槽位颜色渐变（DrawOverlay 绘制前调用）
local function UpdateEntryColors(entry)
    local now = CurTime()
    for slot, cs in pairs(entry.colors) do
        if cs.dur > 0 then
            local t = (now - cs.start) / cs.dur
            if t >= 1 then
                cs.cur = CloneColor(cs.target)
                cs.dur = 0
            else
                cs.cur = LerpColors(t, cs.from, cs.target)
            end
        end
    end
end

-- 数字字体选择（与离屏渲染一致：单字符 48、多字符 36）
local function PickNumberFont(text)
    return #tostring(text) > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
end

-- 富文本关键词高亮列表（与预览层 cl_card_preview.lua 同源，sh_card_data.lua 定义）
local keywordsForHighlight = KARDS.CardEditor.Data.KeywordsForHighlight

-- 富文本字体选择（与预览层 DrawSpecialEffectRichText 规则一致：
-- 关键词/加粗 → SourceHan_Heavy_<size>；斜体 → Calibri_Italic_<size>；
-- 普通 → Calibri_<size>；指定字号字体未注册时回退到思源黑体同字号）
local function SegFont(bold, italic, keyword, size)
    size = size or 20
    if keyword or bold then return "SourceHan_Heavy_" .. size end
    if italic then
        local f = "Calibri_Italic_" .. size
        if CustomFonts and CustomFonts[f] then return f end
        return "SourceHan_Heavy_" .. size
    end
    local f = "Calibri_" .. size
    if CustomFonts and CustomFonts[f] then return f end
    return "SourceHan_Heavy_" .. size
end

-- 解析富文本 <b>/<i> 标签为格式段（与预览层 ParseFormatTags 规则一致），
-- 并把转义换行 \n 还原为真实换行符
local function ParseRichText(text)
    if not text then return {} end
    text = tostring(text):gsub("\\n", "\n")
    local segs = {}
    local pos = 1
    local bold, italic = false, false
    while pos <= #text do
        local minTag, minTagEnd, tagType = nil, nil, nil
        local startB, endB = text:find("<b>", pos, true)
        if startB and (not minTag or startB < minTag) then minTag, minTagEnd, tagType = startB, endB, "bOpen" end
        local closB, closBEnd = text:find("</b>", pos, true)
        if closB and (not minTag or closB < minTag) then minTag, minTagEnd, tagType = closB, closBEnd, "bClose" end
        local startI, endI = text:find("<i>", pos, true)
        if startI and (not minTag or startI < minTag) then minTag, minTagEnd, tagType = startI, endI, "iOpen" end
        local closI, closIEnd = text:find("</i>", pos, true)
        if closI and (not minTag or closI < minTag) then minTag, minTagEnd, tagType = closI, closIEnd, "iClose" end
        if not minTag then
            if pos <= #text then table.insert(segs, { text = text:sub(pos), bold = bold, italic = italic }) end
            break
        end
        if minTag > pos then
            table.insert(segs, { text = text:sub(pos, minTag - 1), bold = bold, italic = italic })
        end
        if tagType == "bOpen" then bold = true
        elseif tagType == "bClose" then bold = false
        elseif tagType == "iOpen" then italic = true
        elseif tagType == "iClose" then italic = false end
        pos = minTagEnd + 1
    end
    return segs
end

-- 对格式段做关键词高亮拆分（与预览层 DrawSpecialEffectRichText 规则一致：
-- 命中关键词的段标记 keyword=true，绘制时用 SourceHan_Heavy 加粗；
-- 部署/抉择命中时连后面的「：」一起高亮）
local function SplitKeywords(segs)
    local out = {}
    for _, seg in ipairs(segs) do
        local segText = seg.text
        local segLen = #segText
        local currentPos = 1
        while currentPos <= segLen do
            local matchKeyword = nil
            local matchEnd = 0
            for _, kw in ipairs(keywordsForHighlight) do
                local kwLen = #kw
                if currentPos + kwLen - 1 <= segLen and segText:sub(currentPos, currentPos + kwLen - 1) == kw then
                    matchKeyword = kw
                    matchEnd = currentPos + kwLen - 1
                    if (kw == "部署" or kw == "抉择") and matchEnd + 1 <= segLen and segText:sub(matchEnd + 1, matchEnd + 1) == "：" then
                        matchEnd = matchEnd + 1
                    end
                    break
                end
            end
            if matchKeyword then
                table.insert(out, { text = segText:sub(currentPos, matchEnd), bold = seg.bold, italic = seg.italic, keyword = true })
                currentPos = matchEnd + 1
            else
                -- 找到下一个关键词的起始位置，其前为普通文本段
                local nextKwPos = segLen + 1
                for _, kw in ipairs(keywordsForHighlight) do
                    local p = segText:find(kw, currentPos, true)
                    if p and p < nextKwPos then nextKwPos = p end
                end
                local endPos = nextKwPos - 1
                if endPos >= currentPos then
                    table.insert(out, { text = segText:sub(currentPos, endPos), bold = seg.bold, italic = seg.italic, keyword = false })
                end
                currentPos = endPos + 1
            end
        end
    end
    return out
end

-- 富文本段按源文本换行符断行：是否换行只由源文本 \n 决定，不做宽度自动换行
-- （与 2D 预览层 DrawSpecialEffectRichText 行为一致），返回行列表，每行 = { {ch, bold, italic, keyword}, ... }
local function WrapRichLines(segs)
    local lines = {}
    local curLine = {}
    local function flush()
        if #curLine > 0 then
            table.insert(lines, curLine)
            curLine = {}
        end
    end
    for _, seg in ipairs(segs) do
        -- 按 UTF-8 字符迭代（不能用 sub(i, i) 逐字节：中文等 3 字节字符会被拆碎成错误字符）
        for ch in string.gmatch(seg.text, "[%z\1-\127\194-\244][\128-\191]*") do
            if ch == "\n" then
                flush()
            else
                table.insert(curLine, { ch = ch, bold = seg.bold, italic = seg.italic, keyword = seg.keyword })
            end
        end
    end
    flush()
    return lines
end

-- 绘制一行富文本：按字符格式选字体，水平居中于 x（3D2D 内使用，无描边）
local function DrawRichLine(chars, x, y, color, size)
    local totalW = 0
    for _, c in ipairs(chars) do
        local font = SegFont(c.bold, c.italic, c.keyword, size)
        surface.SetFont(font)
        totalW = totalW + surface.GetTextSize(c.ch)
    end
    local cx = x - totalW / 2
    for _, c in ipairs(chars) do
        local font = SegFont(c.bold, c.italic, c.keyword, size)
        draw.SimpleText(c.ch, font, cx, y, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        surface.SetFont(font)
        cx = cx + surface.GetTextSize(c.ch)
    end
end

--[[
    统一读取卡牌属性数据（每帧调用 → 属性变化即外观变化）

    返回：{ cost, actionCost, attack, defense, description, descFontSize, isCommand, hasKeywords, keywordsText }
    词条文本由 KARDS.CardEditor.Data.BuildKeywordsText 构建（共享函数，sh_card_data.lua 定义）；
    战场实体词条文本由服务端构建后经 NW 变量同步（sh_battle_render.lua）。
]]
local function ReadData(entry, ent)
    if entry.mode == "entity" then
        -- 战场网络实体：属性由服务端 NW 变量同步（sh_battle_render.lua）
        return {
            cost = ent:GetNWInt("Kards_CardCost", 0),
            actionCost = ent:GetNWInt("Kards_CardActionCost", 0),
            attack = ent:GetNWInt("Kards_CardAttack", 0),
            defense = ent:GetNWInt("Kards_CardDefense", 0),
            description = ent:GetNWString("Kards_CardDescription", ""),
            descFontSize = 20,
            isCommand = ent:GetNWBool("Kards_CardIsCommand", false),
            isHeadquarter = ent:GetNWBool("Kards_CardIsHeadquarter", false),
            hasKeywords = ent:GetNWBool("Kards_CardHasKeywords", false),
            keywordsText = ent:GetNWString("Kards_CardKeywords", ""),
        }
    end

    local d = entry.data
    if d and d._unitMode then
        -- 单位短卡（战场部署模型 basic_card_unit，2026-08-11）：AddLocal 传入静态表
        -- 仅作 _unitMode 标志，属性每帧从服务端 NW 变量读取（table_battledeck.lua
        -- OnPlayCard 初写 + ApplyCombatOutcome SyncUnitNW 战斗后刷新）；只显示
        -- 攻击/防御/行动花费（行动花费替代卡牌花费位置，DrawOverlay 依 _unitMode 跳过
        -- cost/keywords/desc）
        return {
            cost = 0,
            actionCost = ent:GetNWInt("Kards_CardActionCost", 0),
            attack = ent:GetNWInt("Kards_CardAttack", 0),
            defense = ent:GetNWInt("Kards_CardDefense", 0),
            description = "",
            descFontSize = 20,
            isCommand = false,
            isHeadquarter = false,
            hasKeywords = false,
            keywordsText = "",
        }
    end

    if d and d.GetStat and d.GetCost then
        -- 战斗卡牌对象（CardInterface mock，本地引用实时读）
        local ctype = d.GetType and d:GetType() or "unit"
        local kwList = d.GetKeywords and d:GetKeywords() or {}
        return {
            cost = d:GetCost() or 0,
            actionCost = d:GetActionCost() or 0,
            attack = d:GetStat("attack") or 0,
            defense = d:GetStat("defense") or 0,
            description = (d.GetDescription and d:GetDescription()) or "",
            descFontSize = 20,
            isCommand = ctype == "command" or ctype == "headquarter",
            isHeadquarter = ctype == "headquarter",
            hasKeywords = #kwList > 0,
            keywordsText = KARDS.CardEditor.Data.BuildKeywordsText(kwList),
        }
    end

    -- 静态表（外观编辑器 app / cardData）
    return {
        cost = d and d.cost or 0,
        actionCost = d and d.actionCost or 0,
        attack = d and d.attack or 0,
        defense = d and d.defense or 0,
        description = d and d.specialEffect or "",
        descFontSize = d and d.descFontSize or 20,
        isCommand = d and (d.cardType == "command" or d.cardType == "counter_command" or d.cardType == "headquarter") or false,
        isHeadquarter = d and d.cardType == "headquarter" or false,
        hasKeywords = d and d.keywords and #d.keywords > 0 or false,
        keywordsText = KARDS.CardEditor.Data.BuildKeywordsText(d and d.keywords or {}, d and d.keywordValues, d and d.pincerValue),
    }
end

--[[
    绘制单个卡牌实体的属性文字（PostDrawOpaqueRenderables 钩子内逐实体调用）

    坐标系（GMod 官方约定 cam.Start3D2D）：
      2D 坐标为像素，引擎按 scale 换算世界单位（矩阵 SetScale(scale,-scale,1)）
      2D +x = 角度 forward、2D +y = -角度 right；角度构造式 dx:AngleEx(dx:Cross(-dy))
      （dx = 期望 2D+x 的世界方向，dy = 期望 2D+y 的世界方向）

    basic_card 模型为 z-up 平躺（manifest bounds 36×54×0.45，axis_preset "x,-z,y"）：
      卡面宽轴 = 实体局部 +X → ent:GetForward()（对应渲染像素宽 renderW）
      卡面长轴 = 实体局部 +Y → ent:GetRight()（对应渲染像素高 renderH）
      卡面法线 = 实体局部 +Z → ent:GetUp()
    渲染 RT 像素坐标（renderW×renderH，左上原点）经 PX 平移到卡面中心原点后
    由引擎缩放映射到卡面世界尺寸（worldW×worldH）。
]]
local function DrawOverlay(entry, ent)
    -- 从实体当前朝向直接派生卡面轴线（对平躺/倾斜/竖立任意姿态自适应）：
    -- 3D2D +x 沿卡宽（ent:GetForward()）、+y 沿卡长（ent:GetRight()），
    -- 避免旧实现 Angle(-90, y, 0) 的 forward 竖直导致 2D+x 沿世界 Z（文字垂直叠在卡面上）。
    local dx = ent:GetForward()
    local dy = ent:GetRight()
    local camAng = dx:AngleEx(dx:Cross(-dy))
    -- 悬浮偏移沿卡面法线（实体局部 +Z），避免与卡面 Z-fighting
    local pos = ent:GetPos() + ent:GetUp() * FLOAT_OFFSET

    local renderW = entry.renderW or 300
    local renderH = entry.renderH or 400
    local worldW = entry.worldW or DEFAULT_W
    local worldH = entry.worldH or DEFAULT_H
    local scale = worldW / renderW

    -- 3D2D 绘制包裹在 pcall 中：任何绘制异常都会先执行 cam.End3D2D，
    -- 避免 3D2D 模型矩阵残留在矩阵栈上污染后续 3D 渲染（曾导致卡面模型消失）
    cam.Start3D2D(pos, camAng, scale)
    local ok, err = pcall(function()
        -- 推进本卡全部槽位的文字颜色渐变（动态颜色系统，见 SetColor）
        UpdateEntryColors(entry)
        local data = ReadData(entry, ent)
        -- 单位模式（_unitMode）：仅绘制攻击/防御/行动花费，行动花费替代卡牌花费位置
        local unitMode = entry.data and entry.data._unitMode
        -- 总部短卡模式（hqShort）：仅绘制防御（总部无攻击/行动花费/词条/描述；
        -- 短卡模型切换后重绑时传入，见 cl_init.lua StartHQReveal onComplete）
        local hqShort = entry.hqShort


        -- 网格卡达携带上限已翻面（卡背朝上）：不绘制任何 3D2D 文字
        if ent:GetNWBool("Kards_GridFlipped", false) then
            return
        end

        -- 卡组堆叠非顶层卡（性能优化）：仅绘制卡牌花费，其余文字（行动花费/攻防/词条/描述）不绘制。
        -- 顶层卡（最后一张）与网格卡/总部卡不受影响；顶层标志由服务端 Kards_IsPileTop NW 维护
        local pileTopOnly = ent:GetNWString("Kards_CardRole", "") == "deck"
            and ent:GetNWString("Kards_DeckRole", "grid") == "pile"
            and not ent:GetNWBool("Kards_IsPileTop", false)

        -- 像素坐标（左上原点、y 向下）→ 3D2D 像素坐标（卡面中心为原点）。
        -- 注意：3D2D 上下文单位为像素，引擎按 scale 换算世界单位，
        -- 此处只做平移、不再乘 scale（旧实现重复乘 scale 导致所有文字聚在中心重叠）。
        -- y 映射翻转：模板顶部（py=0）映射到 3D2D -y 端（卡长 -Y 端）。上一版用
        -- renderH/2 - py 使模板顶部落到卡长 +Y 端，与卡面纹理视觉顶部相反（第六轮
        -- 观察：费用到左下、攻击防御偏上 = 上下颠倒、左右正常），故只翻转 y 映射；
        -- 不能改 camAng（dx:Cross(-dy)→dx:Cross(dy) 会同时翻转 2D+x 导致左右颠倒，
        -- 且 up 反向使文字字形在平面上镜像）。
        local function PX(px, py)
            return px - renderW / 2, py - renderH / 2
        end

        -- 1. 费用（左上；指令卡用独立位置，因指令模板与单位模板费用位有微小差异；总部无费用，不绘制；
        -- 单位模式跳过卡牌花费，由行动花费替代）
        if not data.isHeadquarter and not unitMode then
            local costText = tostring(data.cost)
            local costX = data.isCommand and COMMAND_COST_X or COST_X
            local costY = data.isCommand and COMMAND_COST_Y or COST_Y
            local cx, cy = PX(costX, costY)
            draw.SimpleText(costText, PickNumberFont(costText), cx, cy, entry.colors.cost.cur, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end

        -- 1.5 卡组计数（同卡 ≥2：该卡实体右上外侧显示 ×N 计数，带描边；
        -- 不受 pileTopOnly 限制，计数卡即使被上层卡盖住也显示）
        local pileCount = ent:GetNWInt("Kards_PileCount", 0)
        if pileCount >= 2 then
            local cpx, cpy = PX(renderW + 18, 10) -- 卡牌顶处、卡牌外部右侧
            draw.SimpleTextOutlined("×" .. pileCount, "SourceHan_Heavy_36", cpx, cpy, COLOR_NUMBER, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(0, 0, 0, 255))
        end

        -- 2. 行动花费（费用右侧，非指令卡；单位模式替代卡牌花费位置；总部短卡无行动花费）
        if not data.isCommand and not pileTopOnly and not hqShort then
            -- 单位短卡用专用左上坐标（UNIT_COST_X/Y），完整卡行动花费用 ACTION_X/Y。
            -- 注意：不能用 `cond and PX(...) or PX(...)` —— and/or 会把 PX 的多返回值
            -- 裁剪为单值，导致 ay 恒为 nil（2026-08-11 实测三文字全部画在 y=0 水平线）
            local ax, ay
            if unitMode then
                ax, ay = PX(UNIT_COST_X, UNIT_COST_Y)
            else
                ax, ay = PX(ACTION_X, ACTION_Y)
            end
            local actionCostText = tostring(data.actionCost)
            -- 单位模式：行动花费替代卡牌花费位置，字号沿用原卡牌花费字号（48/36，
            -- 与 PickNumberFont 一致）；普通卡行动花费维持 24/18
            local actionCostFont = unitMode and PickNumberFont(actionCostText)
                or (#actionCostText > 1 and "SourceHan_Heavy_18" or "SourceHan_Heavy_24")
            draw.SimpleText(actionCostText, actionCostFont, ax, ay, entry.colors.actionCost.cur, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end

        -- 3. 攻击（左下；总部无攻击，不绘制；总部短卡亦不绘制）
        if not data.isCommand and not pileTopOnly and not hqShort then
            -- 单位短卡用专用攻击坐标（UNIT_ATTACK_X/UNIT_ATTACK_BOTTOM）。
            -- 注意：不能 `cond and PX(...) or PX(...)`，会吞掉多返回值使 aty 为 nil
            local atx, aty
            if unitMode then
                atx, aty = PX(UNIT_ATTACK_X, renderH - UNIT_ATTACK_BOTTOM)
            else
                atx, aty = PX(ATTACK_X, renderH - ATTACK_BOTTOM)
            end
            local attackText = tostring(data.attack)
            draw.SimpleText(attackText, PickNumberFont(attackText), atx, aty, entry.colors.attack.cur, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end

        -- 4. 防御（总部与单位位置反转：总部在防御位，单位 x 与攻击力相同、y 自底 155）
        if (not data.isCommand or data.isHeadquarter) and not pileTopOnly then
            local defText = tostring(data.defense)
            local defX, defY
            if data.isHeadquarter then
                -- 总部：防御位（自右 55、自底 73.5 + 历史外观对齐微调偏移）
                defX, defY = PX(renderW - DEFENSE_RIGHT, renderH - DEFENSE_BOTTOM)
                defX, defY = defX - 50, defY - 37
                -- 总部短卡（UV 裁切后仅上部 229px 可见）：防御文字下移 15px 贴合裁切后区域
                -- （hqShort 分支独立偏移，不影响完整总部卡）
                if hqShort then defY = defY + 30 end
            else
                -- 单位：y 与攻击力相同；小模型单位（unitMode）用专用坐标
                --（x = 攻击 x + UNIT_DEFENSE_OFFSET，y 与攻击共享 UNIT_ATTACK_BOTTOM 保证水平对齐），
                -- 完整单位卡维持原偏移 99、自底 ATTACK_BOTTOM。
                -- 注意：不能 `cond and PX(...) or PX(...)`，会吞掉多返回值使 defY 为 nil
                if unitMode then
                    defX, defY = PX(UNIT_ATTACK_X + UNIT_DEFENSE_OFFSET, renderH - UNIT_ATTACK_BOTTOM)
                else
                    defX, defY = PX(ATTACK_X + 99, renderH - ATTACK_BOTTOM)
                end
            end
            local defFont = data.isHeadquarter and (#defText > 1 and "SourceHan_Heavy_56" or "SourceHan_Heavy_72") or PickNumberFont(defText)
            draw.SimpleText(defText, defFont, defX, defY, entry.colors.defense.cur, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end

        -- 5. 词条（底部上方，描述之前；纹理已不烘焙词条，转由本层实时绘制；单位模式跳过；总部短卡无词条）
        if data.keywordsText ~= "" and not pileTopOnly and not unitMode and not hqShort then
            local kx, ky = PX(renderW / 2, renderH - KEYWORDS_BOTTOM)
            draw.SimpleText(data.keywordsText, "SourceHan_Heavy_20", kx, ky, entry.colors.keywords.cur, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end

        -- 6. 效果描述（底部区域，富文本多行；是否换行只由源文本 \n 决定，纹理已不烘焙描述，转由本层实时绘制；
        -- 单位模式跳过；总部短卡无描述）
        -- 富文本继承节点编辑器格式：<b> 加粗 / <i> 斜体 / 关键词高亮（与预览层规则一致）
        local descSegs = SplitKeywords(ParseRichText(data.description))
        local hasText = false
        for _, s in ipairs(descSegs) do if s.text ~= "" then hasText = true break end end
        if hasText and not pileTopOnly and not unitMode and not hqShort then
            local lines = WrapRichLines(descSegs)
            local descSize = data.descFontSize or 20 -- 效果描述字号（外观编辑器 descFontSize，与 2D 预览一致）
            local lineH = math.max(10, math.floor(18 * descSize / 20)) -- 行高随字号缩放（与 2D 预览层一致，20 号约 18 像素）
            -- 描述锚点：指令卡在名称下方；单位有词条在词条下方；单位无词条在底部词条位
            local baseY
            if data.isCommand then
                baseY = data.isHeadquarter and DESC_COMMAND_TOP_HQ or DESC_COMMAND_TOP
            elseif data.hasKeywords then
                baseY = renderH - DESC_BOTTOM_KEYWORDS
            else
                baseY = renderH - DESC_BOTTOM
            end
            local startY = baseY - (#lines - 1) * lineH / 2 -- 多行垂直居中于锚点
            for i, ln in ipairs(lines) do
                local lx, ly = PX(renderW / 2, startY + (i - 1) * lineH)
                DrawRichLine(ln, lx, ly, entry.colors.desc.cur, descSize)
            end
        end
    end)
    cam.End3D2D()
    if not ok then
        print("[KARDS] CardTextOverlay 绘制异常: " .. tostring(err))
    end
end

--[[
    注册本地数据叠加（编辑器 3D2D 文字卡生成 / 本地卡牌对象）

    @param ent      Entity 卡牌实体
    @param data     table 静态属性表（app / cardData）或战斗卡牌对象
    @param worldW   number|nil 卡面世界宽（缺省 24 = basic_card×0.2）
    @param worldH   number|nil 卡面世界高（缺省 36）
    @param renderW  number|nil 无属性文字卡面渲染像素宽（缺省 300）
    @param renderH  number|nil 无属性文字卡面渲染像素高（缺省 400）
]]
function Overlay:AddLocal(ent, data, worldW, worldH, renderW, renderH)
    if not IsValid(ent) then return end
    local entry = {
        mode = "local",
        data = data,
        worldW = worldW or DEFAULT_W,
        worldH = worldH or DEFAULT_H,
        renderW = renderW or 300,
        renderH = renderH or 400,
    }
    entry.colors = {}
    for _, slot in ipairs(self.ColorSlots) do
        entry.colors[slot] = NewColorState(self.DefaultColors[slot])
    end
    self.Ents[ent] = entry
end

--[[
    注册战场网络实体叠加（属性经实体 NW 变量读取，服务端同步）

    @param ent     Entity 卡牌实体（sent_pmx_static_imported）
    @param worldW  number|nil 卡面世界宽（缺省 24）
    @param worldH  number|nil 卡面世界高（缺省 36）
    @param renderW number|nil 无属性文字卡面渲染像素宽（缺省 300；总部短卡 209）
    @param renderH number|nil 无属性文字卡面渲染像素高（缺省 400；总部短卡 290）
    @param hqShort boolean|nil 总部短卡模式（true = 仅绘制防御：总部无攻击/行动花费/
                   词条/描述，短卡模型切换后重绑时传入）
]]
function Overlay:AddEntity(ent, worldW, worldH, renderW, renderH, hqShort)
    if not IsValid(ent) then return end
    local entry = {
        mode = "entity",
        worldW = worldW or DEFAULT_W,
        worldH = worldH or DEFAULT_H,
        renderW = renderW or 300,
        renderH = renderH or 400,
        hqShort = hqShort or nil,
    }
    entry.colors = {}
    for _, slot in ipairs(self.ColorSlots) do
        entry.colors[slot] = NewColorState(self.DefaultColors[slot])
    end
    self.Ents[ent] = entry
end

-- 移除指定实体的文字叠加
function Overlay:Remove(ent)
    self.Ents[ent] = nil
end

-- 清空全部文字叠加
function Overlay:Clear()
    self.Ents = {}
end

--[[
    设置某张卡某个 3D2D 文字槽位的目标颜色（可随时调用，动态颜色系统）

    @param ent   Entity 卡牌实体（须已 AddLocal / AddEntity 注册）
    @param slot  string 槽位 id（Overlay.ColorSlots："cost"/"actionCost"/"attack"/"defense"/"keywords"/"desc"）
    @param color Color 目标颜色（nil 忽略）
    @param dur   number|nil 渐变时长（秒，缺省 0 = 立即生效；>0 从当前色平滑渐变到目标色）
]]
function Overlay:SetColor(ent, slot, color, dur)
    local entry = self.Ents[ent]
    if not entry or not entry.colors or not color then return end
    local cs = entry.colors[slot]
    if not cs then return end
    dur = dur or 0
    if dur <= 0 then
        cs.cur = CloneColor(color)
        cs.from = cs.cur
        cs.target = cs.cur
        cs.start = 0
        cs.dur = 0
    else
        cs.from = CloneColor(cs.cur)
        cs.target = CloneColor(color)
        cs.start = CurTime()
        cs.dur = dur
    end
end

-- 将某槽位颜色渐变回默认色（dur 缺省 0 = 立即恢复）
function Overlay:ResetColor(ent, slot, dur)
    local def = self.DefaultColors and self.DefaultColors[slot]
    if def then self:SetColor(ent, slot, def, dur) end
end

-- 返回当前（含渐变中途）颜色；未注册/无效槽位返回 nil
function Overlay:GetColor(ent, slot)
    local entry = self.Ents[ent]
    local cs = entry and entry.colors and entry.colors[slot]
    return cs and cs.cur or nil
end

-- 返回目标颜色（渐变完成后的颜色；未设置过返回默认色，调用方可据此避免重复设置重启渐变）
function Overlay:GetTargetColor(ent, slot)
    local entry = self.Ents[ent]
    local cs = entry and entry.colors and entry.colors[slot]
    return cs and cs.target or nil
end

--[[
    返回某卡牌的卡牌花费（数据源与绘制一致，供颜色判定等逻辑读取）：
      - 战场实体模式：NW 变量 Kards_CardCost
      - 本地外观表（手牌/编辑器 3D2D）：appearance.cost
      - 卡牌对象（CardInterface mock）：GetCost()
]]
function Overlay:GetCardCost(ent)
    local entry = self.Ents[ent]
    if not entry then return nil end
    if entry.mode == "entity" then
        return IsValid(ent) and ent:GetNWInt("Kards_CardCost", 0) or nil
    end
    local d = entry.data
    if d and d.GetCost then return d:GetCost() or 0 end
    return d and d.cost or 0
end

-- 渲染钩子：PostDrawOpaqueRenderables 中绘制 3D2D 文字（卡面 opaque 已画完，文字悬浮可见）
hook.Add("PostDrawOpaqueRenderables", "kards_card_text_overlay", function()
    for ent, entry in pairs(Overlay.Ents) do
        if not IsValid(ent) then
            Overlay.Ents[ent] = nil -- 实体失效自动清理
        else
            DrawOverlay(entry, ent)
        end
    end
end)

-- 网络：战场卡牌实体生成广播（服务端 → 全部客户端，sh_battle_render.lua SpawnCard 发送）
net.Receive("KARDS_Battle_CardOverlayAdd", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) then return end
    Overlay:AddEntity(ent)
end)

-- 网络：外观编辑器 3D2D 文字卡生成结果（服务端回传实体，客户端绑定本地 app 数据）
-- 服务端生成实体后立即回传时，新实体可能尚未网络化（net.ReadEntity 返回 NULL），
-- 故改读实体索引（服务端 net.WriteEntity 写入的是实体索引），延迟重试绑定直到网络化完成
net.Receive("KARDS_Editor_SpawnCardResult", function()
    local entIdx = net.ReadInt(16)
    local pending = Overlay._PendingLocal
    Overlay._PendingLocal = nil
    if not pending then return end
    local function tryBind(attempt)
        local ent = Entity(entIdx)
        if IsValid(ent) then
            Overlay:AddLocal(ent, pending.data, pending.worldW, pending.worldH, pending.renderW, pending.renderH)
        elseif attempt < 20 then
            timer.Simple(0.1, function() tryBind(attempt + 1) end)
        end
    end
    tryBind(1)
end)

-- 供 cl_canvas_editor.lua 预存待绑定数据（SpawnTestEntity 发送 net 前设置）
Overlay._PendingLocal = nil
