--[[
=======================================================================================
卡牌外貌编辑器模块 (Appearance Editor) - 重写版
=======================================================================================
使用全自定义绘制替代 Gmod VGUI 控件（输入框除外），实现十字四象限布局。
保留：预览图、卡背、老兵预览图绘制与"渲染""生成"卡牌函数。

布局：
  纵向分割线坐标 = win.x + 5 + 180 (= win.x + 185)，与节点选择器分割线相同
  横向分割线坐标 = top 2/3, bottom 1/3

  左上象限(TL)：卡牌属性编辑（自定义绘制控件）
  右上象限(TR)：卡牌预览 + 卡背预览 + 渲染/生成按钮
  左下象限(BL)：额外设置（图片偏移、字号等）
  右下象限(BR)：老兵预览/编辑

=======================================================================================
]]

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- ============ 工厂函数：数据驱动创建控件 ============

-- 创建 DTextEntry 输入框，减少重复代码
-- @param key: 存储在 KARDS.CardEditor.Canvas[key] 的字段名
-- @param opts: 配置表
--   .defaultValue: 初始值 (string)
--   .onChange: 值改变时的回调 function(val)
--   .width: 宽度 (默认 180)
--   .height: 高度 (默认 20)
local function CreateTextEntry(key, opts)
    opts = opts or {}
    local input = vgui.Create("DTextEntry", KARDS.CardEditor.Canvas.RootPanel)
    input:SetSize(opts.width or 180, opts.height or 20)
    input:SetValue(opts.defaultValue or "")
    input:SetVisible(false)
    input:SetEnabled(true)
    input:SetZPos(100)
    input.OnMousePressed = function(self, code) self:RequestFocus() end
    input.OnTextChanged = function(self)
        if opts.onChange then opts.onChange(self:GetValue()) end
    end
    KARDS.CardEditor.Canvas[key] = input
    return input
end

-- 创建 DNumberWang 数字输入框，减少重复代码
-- @param key: 存储在 KARDS.CardEditor.Canvas[key] 的字段名
-- @param opts: 配置表
--   .defaultValue: 初始值 (number)
--   .onChange: 值改变时的回调 function(val)
--   .min: 最小值 (默认 0)
--   .max: 最大值 (默认 99)
--   .width: 宽度 (默认 55)
--   .height: 高度 (默认 20)
local function CreateNumberWang(key, opts)
    opts = opts or {}
    local input = vgui.Create("DNumberWang", KARDS.CardEditor.Canvas.RootPanel)
    input:SetSize(opts.width or 55, opts.height or 20)
    input:SetMin(opts.min or 0)
    input:SetMax(opts.max or 99)
    input:SetValue(opts.defaultValue or 0)
    input:SetVisible(false)
    input:SetEnabled(true)
    input:SetZPos(100)
    input.OnMousePressed = function(self, code) self:RequestFocus() end
    input.OnValueChanged = function(self)
        if opts.onChange then opts.onChange(self:GetValue()) end
    end
    KARDS.CardEditor.Canvas[key] = input
    return input
end

-- 创建所有输入控件（仅限输入框 DTextEntry / DNumberWang）
-- 其余控件使用自定义绘制，在 DrawCardAppearanceEditor 中处理
function KARDS.CardEditor.Canvas.CreateControls()
    local win = KARDS.CardEditor.Canvas.Window

    -- 关闭按钮位置
    local closeBtnX = win.x + win.width - 35
    local closeBtnY = win.y + 5
    local closeBtnW = 30
    local closeBtnH = 30

    -- Apple 风格关闭按钮（button-icon-circular - 44x44 圆形）
    local closeBtn = vgui.Create("DButton", KARDS.CardEditor.Canvas.RootPanel)
    closeBtn:SetPos(closeBtnX, closeBtnY)
    closeBtn:SetSize(closeBtnW, closeBtnH)
    closeBtn:SetText("")
    closeBtn:SetZPos(100)
    closeBtn.Paint = function(self, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(180, 60, 60))
        draw.SimpleText("X", "SourceHan_Heavy_16", w / 2, h / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    closeBtn.DoClick = function()
        KARDS.CardEditor.Canvas.CloseEditor()
    end
    KARDS.CardEditor.Canvas.CloseButton = closeBtn

    -- 最小化按钮
    local minBtn = vgui.Create("DButton", KARDS.CardEditor.Canvas.RootPanel)
    minBtn:SetPos(win.x + win.width - 70, win.y + 5)
    minBtn:SetSize(30, 30)
    minBtn:SetText("")
    minBtn:SetZPos(100)
    minBtn.Paint = function(self, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(80, 80, 80))
        draw.SimpleText("-", "SourceHan_Heavy_20", w / 2, h / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    minBtn.DoClick = function()
        KARDS.CardEditor.Canvas.CloseEditor()
    end
    KARDS.CardEditor.Canvas.MinButton = minBtn

    -- 国家选择按钮（圆形）；description = 二战简介，悬停按钮时在常驻5国按钮行左侧以打字机动画显示
    local countries = {
        { id = "none", name = T("editor.appearanceedit.country_none"), icon = nil, color = nil },
        { id = "uk", name = T("editor.appearanceedit.country_uk"), icon = "materials/kards/flags/uk.png", color = Color(100, 180, 255), description = T("editor.appearanceedit.country_uk_desc") },
        { id = "usa", name = T("editor.appearanceedit.country_usa"), icon = "materials/kards/flags/usa.png", color = Color(60, 80, 60), description = T("editor.appearanceedit.country_usa_desc") },
        { id = "ussr", name = T("editor.appearanceedit.country_ussr"), icon = "materials/kards/flags/ussr.png", color = Color(80, 30, 30), description = T("editor.appearanceedit.country_ussr_desc") },
        { id = "japan", name = T("editor.appearanceedit.country_japan"), icon = "materials/kards/flags/japan.png", color = Color(100, 70, 30), description = T("editor.appearanceedit.country_japan_desc") },
        { id = "germany", name = T("editor.appearanceedit.country_germany"), icon = "materials/kards/flags/germany.png", color = Color(80, 80, 80), description = T("editor.appearanceedit.country_germany_desc") }
    }

    KARDS.CardEditor.Canvas.CountryButtons = {}
    local countryBtnSize = 30
    local countryBtnSpacing = 6
    -- 主行 = 扩展按钮 + 关闭音乐 + 5 个原有国家，共 7 个
    local mainRowCount = #countries + 1
    local totalCountryWidth = mainRowCount * countryBtnSize + (mainRowCount - 1) * countryBtnSpacing
    local countryBtnStartX = closeBtnX - totalCountryWidth - 15
    local countryBtnY = win.y + 40 + (30 - countryBtnSize) / 2

    -- 最左侧：倒三角扩展按钮（关闭音乐按钮左侧）
    -- 当前 BGM 为扩展国家时显示该国圆按钮（外貌与展开所选的相同），点击仍展开面板
    local extendBtn = vgui.Create("DButton", KARDS.CardEditor.Canvas.RootPanel)
    extendBtn:SetPos(countryBtnStartX, countryBtnY)
    extendBtn:SetSize(countryBtnSize, countryBtnSize)
    extendBtn:SetText("")
    extendBtn:SetZPos(100)
    extendBtn.Paint = function(self, w, h)
        local bgmCompat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
        local bgmCountry = bgmCompat and bgmCompat.CurrentCountry or "none"
        local currentExpand = nil
        for _, c in ipairs(KARDS.CardEditor.Canvas.BGMExpandCountries or {}) do
            if c.id == bgmCountry then
                currentExpand = c
                break
            end
        end

        if currentExpand then
            -- 外貌与展开面板所选按钮一致（含颜色高亮）
            local iconMat = currentExpand.iconMat
            local bgColor = Color(60, 60, 60)
            if currentExpand.color then
                bgColor = Color(math.min(currentExpand.color.r + 40, 255), math.min(currentExpand.color.g + 40, 255), math.min(currentExpand.color.b + 40, 255))
            end
            draw.RoundedBox(countryBtnSize / 2, 0, 0, w, h, bgColor)
            if iconMat and not iconMat:IsError() then
                surface.SetDrawColor(255, 255, 255, 255)
                surface.SetMaterial(iconMat)
                local padding = 3
                surface.DrawTexturedRect(padding, padding, w - padding * 2, h - padding * 2)
            else
                -- 无图标时显示简称（外部注册风格可用 shortName，如 "C"），否则显示名称首字
                draw.SimpleText(currentExpand.shortName or currentExpand.name:sub(1, 1), "SourceHan_Heavy_12", w / 2, h / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        else
            -- 倒三角
            draw.RoundedBox(countryBtnSize / 2, 0, 0, w, h, self:IsHovered() and Color(80, 80, 80) or Color(60, 60, 60))
            surface.SetDrawColor(255, 255, 255, 255)
            surface.DrawPoly({
                { x = w / 2 - 6, y = h / 2 - 3 },
                { x = w / 2 + 6, y = h / 2 - 3 },
                { x = w / 2, y = h / 2 + 5 }
            })
        end
    end
    extendBtn.DoClick = function()
        KARDS.CardEditor.Canvas.ToggleBGMMenu()
    end
    extendBtn.DoRightClick = function()
        -- 右键：在鼠标处展开当前播放风格的曲目列表面板
        local bgmCompat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
        local bgmCountry = bgmCompat and bgmCompat.CurrentCountry or "none"
        if bgmCountry and bgmCountry ~= "none" then
            KARDS.CardEditor.Canvas.OpenBGMPlaylist(bgmCountry)
        end
    end
    KARDS.CardEditor.Canvas.BGMExtendButton = extendBtn
    table.insert(KARDS.CardEditor.Canvas.CountryButtons, extendBtn)

    for i, country in ipairs(countries) do
        -- 原国家按钮从扩展按钮右侧开始排列
        local btnX = countryBtnStartX + i * (countryBtnSize + countryBtnSpacing)
        local countryBtn = vgui.Create("DButton", KARDS.CardEditor.Canvas.RootPanel)
        countryBtn:SetPos(btnX, countryBtnY)
        countryBtn:SetSize(countryBtnSize, countryBtnSize)
        countryBtn:SetText("")
        countryBtn:SetZPos(100)
        countryBtn.countryData = country -- 悬停简介（打字机动画）读取的国家数据（含二战简介 description）

        -- file.Exists 预判图标文件存在才创建材质，缺失时回退显示国家简称首字
        local iconMat = country.icon and file.Exists(country.icon, "GAME") and Material(country.icon, "noclamp smooth") or nil
        countryBtn.Paint = function(self, w, h)
            -- 顶栏国旗按钮是 BGM 国家风格选择（与卡牌国家书签无关）：高亮跟随当前播放的 BGM 国家
            local bgmCompat = KARDS.CardEditor.Compat and KARDS.CardEditor.Compat.DynamicBGM
            local bgmCountry = bgmCompat and bgmCompat.CurrentCountry or "none"
            local isSelected = bgmCountry == country.id
            local isHovered = self:IsHovered()
            local bgColor = Color(60, 60, 60)
            if isSelected and country.color then
                bgColor = Color(math.min(country.color.r + 40, 255), math.min(country.color.g + 40, 255), math.min(country.color.b + 40, 255))
            elseif isHovered and country.color then
                bgColor = Color(math.min(country.color.r + 20, 255), math.min(country.color.g + 20, 255), math.min(country.color.b + 20, 255))
            elseif isHovered then
                bgColor = Color(80, 80, 80)
            end
            draw.RoundedBox(countryBtnSize / 2, 0, 0, w, h, bgColor)
            if iconMat and not iconMat:IsError() then
                surface.SetDrawColor(255, 255, 255, 255)
                surface.SetMaterial(iconMat)
                local padding = 3
                surface.DrawTexturedRect(padding, padding, w - padding * 2, h - padding * 2)
            else
                draw.SimpleText(country.name:sub(1, 1), "SourceHan_Heavy_12", w / 2, h / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end
        countryBtn.DoClick = function()
            -- 切换编辑器 BGM 国家风格（不改变卡牌国家）
            KARDS.CardEditor.Canvas.SelectEditorBGM(country.id)
        end
        countryBtn.DoRightClick = function()
            -- 右键：在鼠标处展开该国家风格的曲目列表面板（"无"风格无曲目，不弹出）
            if country.id ~= "none" then
                KARDS.CardEditor.Canvas.OpenBGMPlaylist(country.id)
            end
        end
        table.insert(KARDS.CardEditor.Canvas.CountryButtons, countryBtn)
    end

    -- 切换编辑器状态按钮
    local toggleBtn = vgui.Create("DButton", KARDS.CardEditor.Canvas.RootPanel)
    toggleBtn:SetSize(200, 40)
    toggleBtn:SetText(T("editor.appearanceedit.disable_editor"))
    toggleBtn:SetVisible(false)
    toggleBtn.DoClick = function()
        RunConsoleCommand("kards_toggle_appearance")
    end
    KARDS.CardEditor.Canvas.ToggleAppearanceDButton = toggleBtn

    -- ============ 使用工厂函数创建输入框控件 ============
    -- DTextEntry: 卡牌名称输入框（按当前语言读写 name / nameEn）
    CreateTextEntry("NameInput", {
        defaultValue = KARDS.CardEditor.Data.GetLocalizedField(KARDS.CardEditor.Canvas.CardAppearance, "name"),
        onChange = function(val)
            KARDS.CardEditor.Data.SetLocalizedField(KARDS.CardEditor.Canvas.CardAppearance, "name", val)
        end
    })

    -- DNumberWang: 花费输入框
    CreateNumberWang("CostInput", {
        max = 99,
        defaultValue = KARDS.CardEditor.Canvas.CardAppearance.cost,
        onChange = function(val)
            KARDS.CardEditor.Canvas.CardAppearance.cost = val
            KARDS.CardEditor.Canvas.CardAppearance.veteranAppearance.cost = val
        end
    })

    -- DNumberWang: 行动花费输入框
    CreateNumberWang("ActionCostInput", {
        max = 9,
        defaultValue = KARDS.CardEditor.Canvas.CardAppearance.actionCost,
        onChange = function(val)
            KARDS.CardEditor.Canvas.CardAppearance.actionCost = val
            KARDS.CardEditor.Canvas.CardAppearance.veteranAppearance.actionCost = val
        end
    })

    -- DNumberWang: 防御力输入框
    CreateNumberWang("DefenseInput", {
        max = 99,
        defaultValue = KARDS.CardEditor.Canvas.CardAppearance.defense,
        onChange = function(val) KARDS.CardEditor.Canvas.CardAppearance.defense = val end
    })

    -- DTextEntry: 插图路径输入框
    CreateTextEntry("ImagePathInput", {
        defaultValue = KARDS.CardEditor.Canvas.CardAppearance.imagePath,
        onChange = function(val)
            KARDS.CardEditor.Canvas.CardAppearance.imagePath = val
            KARDS.CardEditor.Canvas.CardAppearance.veteranAppearance.imagePath = val
        end
    })

    -- DTextEntry: 自定义模板路径输入框
    CreateTextEntry("CustomTemplatePathInput", {
        defaultValue = KARDS.CardEditor.Canvas.CardAppearance.customTemplatePath,
        onChange = function(val)
            KARDS.CardEditor.Canvas.CardAppearance.customTemplatePath = val
            KARDS.CardEditor.Canvas.CardAppearance.veteranAppearance.customTemplatePath = val
        end
    })

    -- DNumberWang: 数值词条 - 情报X
    CreateNumberWang("IntelNumber", {
        width = 50, max = 10,
        defaultValue = KARDS.CardEditor.Canvas.CardAppearance.keywordValues.intel,
        onChange = function(val)
            KARDS.CardEditor.Canvas.CardAppearance.keywordValues.intel = val
            local kw = KARDS.CardEditor.Canvas.CardAppearance.keywords
            if val > 0 and not table.HasValue(kw, "intel") then table.insert(kw, "intel")
            elseif val <= 0 then table.RemoveByValue(kw, "intel") end
        end
    })

    -- DNumberWang: 数值词条 - 倒计时X
    CreateNumberWang("CountdownNumber", {
        width = 50, max = 10,
        defaultValue = KARDS.CardEditor.Canvas.CardAppearance.keywordValues.countdown,
        onChange = function(val)
            KARDS.CardEditor.Canvas.CardAppearance.keywordValues.countdown = val
            local kw = KARDS.CardEditor.Canvas.CardAppearance.keywords
            if val > 0 and not table.HasValue(kw, "countdown") then table.insert(kw, "countdown")
            elseif val <= 0 then table.RemoveByValue(kw, "countdown") end
        end
    })

    -- DNumberWang: 数值词条 - 重甲X
    CreateNumberWang("HeavyArmorNumber", {
        width = 50, max = 3,
        defaultValue = KARDS.CardEditor.Canvas.CardAppearance.keywordValues.heavy_armor,
        onChange = function(val)
            KARDS.CardEditor.Canvas.CardAppearance.keywordValues.heavy_armor = val
            local kw = KARDS.CardEditor.Canvas.CardAppearance.keywords
            if val > 0 and not table.HasValue(kw, "heavy_armor") then table.insert(kw, "heavy_armor")
            elseif val <= 0 then table.RemoveByValue(kw, "heavy_armor") end
        end
    })

end

-- 从 CardAppearance 更新所有剩余输入框的状态
function KARDS.CardEditor.Canvas.UpdateControlsFromAppearance()
    local a = KARDS.CardEditor.Canvas.CardAppearance
    -- 同步卡牌国家到外貌编辑器书签显示（只更新 UI 状态，不触发 BGM 切换）
    -- 键小写化兼容默认值 "SandBox" 与书签写回的小写 id
    local validCountries = { sandbox = true, uk = true, usa = true, ussr = true, japan = true, germany = true }
    local cKey = a and tostring(a.country):lower() or ""
    KARDS.CardEditor.Canvas.SelectedCountry = validCountries[cKey] and cKey or "none"
    if IsValid(KARDS.CardEditor.Canvas.NameInput) then
        KARDS.CardEditor.Canvas.NameInput:SetValue(KARDS.CardEditor.Data.GetLocalizedField(a, "name"))
    end
    if IsValid(KARDS.CardEditor.Canvas.CostInput) then
        KARDS.CardEditor.Canvas.CostInput:SetValue(a.cost or 0)
    end
    if IsValid(KARDS.CardEditor.Canvas.ActionCostInput) then
        KARDS.CardEditor.Canvas.ActionCostInput:SetValue(a.actionCost or 0)
    end
    if IsValid(KARDS.CardEditor.Canvas.DefenseInput) then
        KARDS.CardEditor.Canvas.DefenseInput:SetValue(a.defense or 0)
    end
    if IsValid(KARDS.CardEditor.Canvas.ImagePathInput) then
        KARDS.CardEditor.Canvas.ImagePathInput:SetValue(a.imagePath or "")
    end
    if IsValid(KARDS.CardEditor.Canvas.CustomTemplatePathInput) then
        KARDS.CardEditor.Canvas.CustomTemplatePathInput:SetValue(a.customTemplatePath or "")
    end
    if IsValid(KARDS.CardEditor.Canvas.IntelNumber) then
        KARDS.CardEditor.Canvas.IntelNumber:SetValue(a.keywordValues and a.keywordValues.intel or 0)
    end
    if IsValid(KARDS.CardEditor.Canvas.CountdownNumber) then
        KARDS.CardEditor.Canvas.CountdownNumber:SetValue(a.keywordValues and a.keywordValues.countdown or 0)
    end
    if IsValid(KARDS.CardEditor.Canvas.HeavyArmorNumber) then
        KARDS.CardEditor.Canvas.HeavyArmorNumber:SetValue(a.keywordValues and a.keywordValues.heavy_armor or 0)
    end
    -- 同步卡牌名称状态（按当前语言：英文环境为 nameEn）
    local nameText = KARDS.CardEditor.Data.GetLocalizedField(a, "name")
    local cnis = KARDS.CardEditor.Canvas._cardNameInputState
    if cnis then
        cnis.text = nameText
    else
        KARDS.CardEditor.Canvas._cardNameInputState = { text = nameText, active = false, caretPos = 0 }
    end

    -- 同步描述状态（按当前语言：英文环境为 specialEffectEn）
    local descText = KARDS.CardEditor.Data.GetLocalizedField(a, "specialEffect")
    local ds = KARDS.CardEditor.Canvas._descInputState
    if ds then
        ds.text = descText
    else
        KARDS.CardEditor.Canvas._descInputState = { text = descText, active = false, caretPos = 0 }
    end

    -- 同步老兵描述状态（透明输入框）
    -- 序列化兼容：旧版本保存的卡牌缺少 veteranAppearance 字段，补默认老兵外观
    -- （结构与 cl_canvas_editor.lua CardAppearance.veteranAppearance 一致）
    local va = KARDS.CardEditor.Canvas.CardAppearance.veteranAppearance
    if not va then
        va = {
            name = "新卡牌(老兵)", cost = 1, actionCost = 0, attack = 0, defense = 0,
            quality = "special", keywords = { "veteran" },
            keywordValues = { intel = 0, countdown = 0, heavy_armor = 0 },
            specialEffect = "", imagePath = "", cardTemplate = "card", customTemplatePath = "",
            nameIsBlack = false, nameFontSize = 36, descFontSize = 20, nameIsEnglish = false,
            imageOffsetX = 0, imageOffsetY = 0, imageScale = 1
        }
        KARDS.CardEditor.Canvas.CardAppearance.veteranAppearance = va
    end

    -- 序列化兼容：旧版本保存的卡牌缺少 convertTarget 字段，补默认空字符串（不换卡）
    -- （与 cl_canvas_editor.lua CardAppearance.convertTarget 一致）
    if not KARDS.CardEditor.Canvas.CardAppearance.convertTarget then
        KARDS.CardEditor.Canvas.CardAppearance.convertTarget = ""
    end
    -- 换卡/重置时收起可能展开的转换目标卡列表
    KARDS.CardEditor.Canvas._convertTargetExpanded = false

    local vetDescText = KARDS.CardEditor.Data.GetLocalizedField(va, "specialEffect")
    local vds = KARDS.CardEditor.Canvas._vetDescInputState
    if vds then
        vds.text = vetDescText
    else
        KARDS.CardEditor.Canvas._vetDescInputState = { text = vetDescText, active = false, caretPos = 0 }
    end
end
function KARDS.CardEditor.Canvas.DrawCardAppearanceEditor(cx, cy, cw, ch)
    local app = KARDS.CardEditor.Canvas.CardAppearance
    local mx, my = gui.MouseX(), gui.MouseY()
    local dt = FrameTime() or 0.016

    -- 鼠标点击检测（使用本地帧追踪，避免 input.WasMousePressed 的跨帧问题）
    local lastLeft = KARDS.CardEditor.Canvas._AppearanceLastLeft or false
    local isLeftDown = input.IsMouseDown(MOUSE_LEFT)
    local isLeftPressed = isLeftDown and not lastLeft
    KARDS.CardEditor.Canvas._AppearanceLastLeft = isLeftDown

    -- BGM 展开面板/曲目列表面板打开时，面板区域内的点击由 vgui 按钮处理：
    -- 抑制本帧自定义点击检测，防止点击 BGM 菜单交互时穿透到下方总控台（如误设卡牌类型）
    if isLeftPressed then
        -- 任一 BGM 全屏遮罩有效（曲目列表/展开面板）→ 整帧抑制：遮罩拦截外部点击，不穿透总控台
        if IsValid(KARDS.CardEditor.Canvas.BGMTrackListMask) or IsValid(KARDS.CardEditor.Canvas.BGMMenuMask) then
            isLeftPressed = false
        else
            local bgmPanel = KARDS.CardEditor.Canvas.BGMMenuPanel
            if IsValid(bgmPanel) then
                local px, py = bgmPanel:GetPos()
                local pw, ph = bgmPanel:GetSize()
                if mx >= px and mx <= px + pw and my >= py and my <= py + ph then
                    isLeftPressed = false
                end
            end
            -- BGM 曲目列表面板（右键菜单）同款抑制
            local trackPanel = KARDS.CardEditor.Canvas.BGMTrackListPanel
            if isLeftPressed and IsValid(trackPanel) then
                local px, py = trackPanel:GetPos()
                local pw, ph = trackPanel:GetSize()
                if mx >= px and mx <= px + pw and my >= py and my <= py + ph then
                    isLeftPressed = false
                end
            end
        end
    end

    -- 十字四象限分割
    local sepX = cx + 180
    -- 横向分割线高度：精确匹配卡背图片的实际渲染高度
    -- 卡背图片原始尺寸: 1091x1530（已验证 sandbox.png）
    -- DrawCardTemplate 中 templateScaleFactor = 0.25 * scaleFactor(=1.0) = 0.25
    -- 实际渲染高度 = 1530 * 0.25 = 382.5 像素
    -- 从 sepY 到图片底部总高度 = 5(prevY偏移) + 24(卡背预览标题) + 10(模板偏移) + 382.5(图片) = 421.5
    local rightW = cx + cw - sepX
    local prevW = math.min(180, rightW * 0.35)
    local cardBackImageH = 1530  -- 卡背图片原始高度
    local renderedCardBackH = cardBackImageH * 0.25  -- 渲染后的实际高度 = 382.5
    local bottomAreaH = math.ceil((5 + 10 + renderedCardBackH) * 0.8)  -- = 318（移除标题后整体缩小 1/5）
    local sepY = cy + ch - bottomAreaH

    -- ===== TL：书签栏（Apple configurator-option-chip 风格） =====
    local bookmarks = KARDS.CardEditor.Canvas.Bookmarks
    local animStates = KARDS.CardEditor.Canvas.BookmarkAnimStates
    local selectedId = KARDS.CardEditor.Canvas.SelectedBookmark

    -- 初始化动画状态
    if #animStates == 0 then
        for i, bm in ipairs(bookmarks) do
            animStates[i] = { hoverProgress = 0 }
        end
    end

    local bmStartY = cy + 12
    local bmHeight = 28
    local bmGap = 6
    local bmNormalW = 40

    -- 根据卡牌类型动态计算书签前缀
    local typePrefix = T("editor.appearanceedit.type_unit")
    if app.cardType == "command" then
        typePrefix = T("editor.appearanceedit.type_command")
    elseif app.cardType == "counter_command" then
        typePrefix = T("editor.appearanceedit.type_counter")
    elseif app.cardType == "headquarter" then
        typePrefix = T("editor.appearanceedit.type_headquarter")
    end

    -- 总部模式：仅显示 属性/历史/插图/描述 四个书签
    local isHQ = app.cardType == "headquarter"
    local HQBookmarkIds = { attr = true, history = true, illustration = true, description = true }
    -- 伤害倍率仅单位卡可配置（2026-08-16：指令/反制/总部不参与攻击倍率）
    -- 修复（2026-10-04）：「单位卡」判定原写作 `app.cardType == "unit"`，而 app.cardType 的
    -- 实际取值是 infantry/tank/artillery/fighter/bomber（"unit" 是编辑器模式名，不是卡牌类型，
    -- 见 cl_canvas_editor.lua 默认外观注释与类型选择器 cl_ca_appearance_editors.lua），
    -- 条件恒为假导致「伤害」书签无论何种卡牌都不显示；改为与其它处一致的 5 种单位类型判定
    local isUnitCard = app.cardType == "infantry" or app.cardType == "tank"
        or app.cardType == "artillery" or app.cardType == "fighter" or app.cardType == "bomber"
    -- 总部模式下若当前选中的书签被过滤，自动切到「属性」
    if isHQ and not HQBookmarkIds[KARDS.CardEditor.Canvas.SelectedBookmark] then
        KARDS.CardEditor.Canvas.SelectedBookmark = "attr"
    end
    -- 非单位卡当前停在「伤害」书签 → 自动切走（书签已隐藏，本帧即生效）
    if not isUnitCard and KARDS.CardEditor.Canvas.SelectedBookmark == "damage" then
        KARDS.CardEditor.Canvas.SelectedBookmark = "attr"
    end
    selectedId = KARDS.CardEditor.Canvas.SelectedBookmark
    -- 构建可见书签列表（元素：{ bm, stateIdx }，stateIdx 指向 animStates 原索引）
    local visibleBookmarks = {}
    for i, bm in ipairs(bookmarks) do
        if not (isHQ and not HQBookmarkIds[bm.id])
            and (isUnitCard or bm.id ~= "damage") then
            table.insert(visibleBookmarks, { bm = bm, stateIdx = i })
        end
    end

    for idx, item in ipairs(visibleBookmarks) do
        local bm = item.bm
        local state = animStates[item.stateIdx]
        local bmY = bmStartY + (idx - 1) * (bmHeight + bmGap)
        local isSelected = (selectedId == bm.id)

        -- 动态 fullName：将 "单位" 替换为当前类型前缀
        local dynamicFullName = string.gsub(bm.fullName, "单位", typePrefix, 1)

        -- 根据 dynamicFullName 文字长度计算每个书签的目标展开宽度
        surface.SetFont("SourceHan_Heavy_16")
        local textW = surface.GetTextSize(dynamicFullName)
        local targetW = textW + APPLE_SPACE.lg  -- 左右各12px内边距
        local targetExtendW = math.max(0, targetW - bmNormalW)

        -- 先根据当前动画进度计算书签位置，用于悬停检测
        local curExtendW = state.hoverProgress * targetExtendW
        local bmW = bmNormalW + curExtendW
        local bmX = sepX - bmW

        -- 使用实际书签矩形检测悬停（精确匹配绘制区域）
        local isHovered = IsMouseIn(mx, my, bmX, bmY, bmW, bmHeight)

        -- 更新悬停进度
        local animSpeed = isSelected and 12 or (isHovered and 8 or 6)
        if isHovered or isSelected then
            state.hoverProgress = math.min(1, state.hoverProgress + dt * animSpeed)
        else
            state.hoverProgress = math.max(0, state.hoverProgress - dt * animSpeed)
        end

        -- 根据更新后的进度重新计算最终绘制位置
        curExtendW = state.hoverProgress * targetExtendW
        bmW = bmNormalW + curExtendW
        bmX = sepX - bmW

        -- Apple 风格：选中 = Action Blue pill，未选中 = Parchment pill
        local bgColor, textColor
        if isSelected then
            bgColor = isHovered and APPLE_BLUE_HOVER or APPLE_BLUE
            textColor = APPLE_TEXT_ON_BLUE
        else
            bgColor = isHovered and APPLE_DARK_HOVER or APPLE_PARCHMENT
            textColor = APPLE_INK
        end

        -- Apple pill 圆角（左侧圆角，右侧直角以贴合边界）
        draw.RoundedBoxEx(APPLE_RADII.pill, bmX, bmY, bmW, bmHeight, bgColor, true, false, true, false)

        -- 绘制文字（打字机动画与矩形延长同步）
        if state.hoverProgress > 0.3 then
            local fullName = dynamicFullName
            local shortName = bm.shortName
            local sPos, ePos = string.find(fullName, shortName, 1, true)
            local beforeStr = sPos and string.sub(fullName, 1, sPos - 1) or ""
            local afterStr = sPos and string.sub(fullName, ePos + 1) or ""
            local totalExtra = #beforeStr + #afterStr
            local totalChars = math.max(1, totalExtra / 3)

            local progress = (state.hoverProgress - 0.3) / 0.7
            progress = math.max(0, math.min(1, progress))
            local typedChars = math.floor(progress * totalChars)
            local typewriterIdx = typedChars * 3

            local displayText = shortName
            if typewriterIdx > 0 then
                local typedAfter = string.sub(afterStr, 1, math.min(typewriterIdx, #afterStr))
                local remaining = math.max(0, typewriterIdx - #afterStr)
                local typedBefore = string.sub(beforeStr, 1, math.min(remaining, #beforeStr))
                displayText = typedBefore .. shortName .. typedAfter
            end
            draw.SimpleText(displayText, "SourceHan_Heavy_16", bmX + APPLE_SPACE.sm, bmY + bmHeight / 2, textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        else
            draw.SimpleText(bm.shortName, "SourceHan_Heavy_16", sepX - bmNormalW / 2, bmY + bmHeight / 2, textColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end

        -- 点击选择书签
        if isLeftPressed and isHovered then
            if KARDS.CardEditor.Canvas.SelectedBookmark ~= bm.id then
                -- 切换书签时关闭共享透明输入框（否则其在其它书签页隐形残留并截获键盘，2026-10-04）
                local uiState = KARDS.CardEditor.Canvas._uiInputState
                if uiState then
                    uiState.active = false
                    uiState.id = nil
                    uiState.onCommit = nil
                end
            end
            KARDS.CardEditor.Canvas.SelectedBookmark = bm.id
        end
    end

    -- ===== TR：编辑区（Apple 白色画布） =====
    local trX = sepX
    local trY = cy
    local trW = cx + cw - sepX
    local trH = sepY - cy

    -- 右侧分割1/4作为总控台
    local controlW = math.max(120, math.floor(trW / 4))
    local editW = trW - controlW

    -- 先绘制总控台（右侧1/4）
    DrawControlPanel(trX + editW, trY, controlW, trH, app, mx, my, isLeftPressed)

    -- Apple 白色画布编辑区背景（带轻微阴影/边框）
    draw.RoundedBox(APPLE_RADII.sm, trX + 2, trY + 2, editW - 4, trH - 4, APPLE_WHITE)
    surface.SetDrawColor(APPLE_HAIRLINE)
    surface.DrawOutlinedRect(trX + 2, trY + 2, editW - 4, trH - 4)

    -- 根据所选书签绘制不同内容
    if selectedId == "type" then
        DrawTypeEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    elseif selectedId == "attr" then
        DrawAttrEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    elseif selectedId == "country" then
        DrawCountryEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    elseif selectedId == "keywords" then
        DrawKeywordsEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    elseif selectedId == "description" then
        DrawDescriptionEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    elseif selectedId == "illustration" then
        DrawIllustrationEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    elseif selectedId == "history" then
        DrawHistoryEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    elseif selectedId == "rarity" then
        DrawRarityEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    elseif selectedId == "damage" then
        DrawDamageModifierEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    elseif selectedId == "manage" then
        DrawManageEditArea(trX, trY, editW, trH, app, mx, my, isLeftPressed, dt)
    end

    -- 不稳定警告悬停提示：在页面内容全部绘制完成后统一绘制，保证最高层不被遮挡（2026-10-05）
    KARDS.CardEditor.Canvas.DrawPendingUnstableWarnTooltip()

    -- ===== 透明 DTextEntry 生命周期管理辅助函数 =====
    local function manageTransparentEntry(cfg)
        local entry = KARDS.CardEditor.Canvas[cfg.entryKey]
        if cfg.isActive then
            if not entry or not IsValid(entry) then
                local px, py, pw, ph = cfg.getPos()
                entry = vgui.Create("DTextEntry", KARDS.CardEditor.Canvas.RootPanel)
                entry:SetPos(px, py)
                entry:SetSize(pw, ph)
                entry:SetText(cfg.getText() or "")
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil
                entry:RequestFocus()
                cfg.onCreate(entry)
                KARDS.CardEditor.Canvas[cfg.entryKey] = entry
            else
                if not entry:HasFocus() then entry:RequestFocus() end
                if cfg.onFocus then cfg.onFocus(entry) end
            end
        else
            if entry and IsValid(entry) then entry:Remove() end
            KARDS.CardEditor.Canvas[cfg.entryKey] = nil
            if not cfg.keepState then KARDS.CardEditor.Canvas[cfg.stateKey] = nil end
        end
    end

    local function makeNumericCbs(fieldName, stateKey)
        return function(entry)
            entry.OnTextChanged = function(self)
                local s = KARDS.CardEditor.Canvas[stateKey]
                if not s then return end
                s.text = self:GetText()
                local num = tonumber(s.text)
                if num ~= nil then
                    num = math.floor(math.Clamp(num, 0, 99))
                    local a = KARDS.CardEditor.Canvas.CardAppearance
                    if a then
                        a[fieldName] = num
                    end
                    s.lastValidValue = num
                end
            end
            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    local s = KARDS.CardEditor.Canvas[stateKey]
                    if s then
                        s.active = false
                        s.text = tostring(s.lastValidValue)
                        local a = KARDS.CardEditor.Canvas.CardAppearance
                        if a then
                            a[fieldName] = s.lastValidValue
                        end
                    end
                end
            end
            entry.OnLoseFocus = function(self)
                local s = KARDS.CardEditor.Canvas[stateKey]
                if s then
                    local num = tonumber(s.text)
                    if num == nil or num ~= math.floor(num) or num < 0 or num > 99 then
                        s.text = tostring(s.lastValidValue)
                        local a = KARDS.CardEditor.Canvas.CardAppearance
                        if a then
                            a[fieldName] = s.lastValidValue
                        end
                    else
                        s.lastValidValue = num
                    end
                    s.active = false
                end
            end
        end
    end

    local function makeVetNumericCbs(fieldName, stateKey)
        return function(entry)
            entry.OnTextChanged = function(self)
                local s = KARDS.CardEditor.Canvas[stateKey]
                if not s then return end
                s.text = self:GetText()
                local num = tonumber(s.text)
                if num ~= nil then
                    num = math.floor(math.Clamp(num, 0, 99))
                    local a = KARDS.CardEditor.Canvas.CardAppearance
                    if a and a.veteranAppearance then
                        a.veteranAppearance[fieldName] = num
                    end
                    s.lastValidValue = num
                end
            end
            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    local s = KARDS.CardEditor.Canvas[stateKey]
                    if s then
                        s.active = false
                        s.text = tostring(s.lastValidValue)
                        local a = KARDS.CardEditor.Canvas.CardAppearance
                        if a and a.veteranAppearance then
                            a.veteranAppearance[fieldName] = s.lastValidValue
                        end
                    end
                end
            end
            entry.OnLoseFocus = function(self)
                local s = KARDS.CardEditor.Canvas[stateKey]
                if s then
                    local num = tonumber(s.text)
                    if num == nil or num ~= math.floor(num) or num < 0 or num > 99 then
                        s.text = tostring(s.lastValidValue)
                        local a = KARDS.CardEditor.Canvas.CardAppearance
                        if a and a.veteranAppearance then
                            a.veteranAppearance[fieldName] = s.lastValidValue
                        end
                    else
                        s.lastValidValue = num
                    end
                    s.active = false
                end
            end
        end
    end

    -- ===== 攻击力输入框 =====
    manageTransparentEntry({
        entryKey = "_attrTextEntry",
        stateKey = "_attrInputState",
        isActive = (selectedId == "attr") and KARDS.CardEditor.Canvas._attrInputState and KARDS.CardEditor.Canvas._attrInputState.active,
        getPos = function()
            local colW = math.floor(((editW - 30) - 12) / 2)
            local sliderW = math.floor((colW - 50) / 2)
            return trX + 15 + sliderW + 6, trY + 15 + 26 + (36 / 2) - 10, 36, 20
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._attrInputState; return s and s.text or ""
        end,
        onCreate = makeNumericCbs("attack", "_attrInputState"),
    })
    -- ===== 防御力输入框 =====
    manageTransparentEntry({
        entryKey = "_defenseTextEntry",
        stateKey = "_defenseInputState",
        isActive = (selectedId == "attr") and KARDS.CardEditor.Canvas._defenseInputState and KARDS.CardEditor.Canvas._defenseInputState.active,
        getPos = function()
            local colW = math.floor(((editW - 30) - 12) / 2)
            local sliderW = math.floor((colW - 50) / 2)
            return trX + 15 + colW + 12 + sliderW + 6, trY + 15 + 26 + (36 / 2) - 10, 36, 20
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._defenseInputState; return s and s.text or ""
        end,
        onCreate = makeNumericCbs("defense", "_defenseInputState"),
    })

    -- ===== 设置花费输入框 =====
    manageTransparentEntry({
        entryKey = "_costTextEntry",
        stateKey = "_costInputState",
        isActive = (selectedId == "attr") and KARDS.CardEditor.Canvas._costInputState and KARDS.CardEditor.Canvas._costInputState.active,
        getPos = function()
            local colW = math.floor(((editW - 30) - 12) / 2)
            local sliderW = math.floor((colW - 50) / 2)
            return trX + 15 + sliderW + 6, trY + 15 + 26 + 36 + 14 + 26 + (36 / 2) - 10, 36, 20
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._costInputState; return s and s.text or ""
        end,
        onCreate = function(entry)
            -- 花费也同步到老兵
            entry.OnTextChanged = function(self)
                local s = KARDS.CardEditor.Canvas._costInputState
                if not s then return end
                s.text = self:GetText()
                local num = tonumber(s.text)
                if num ~= nil then
                    num = math.floor(math.Clamp(num, 0, 99))
                    local a = KARDS.CardEditor.Canvas.CardAppearance
                    if a then
                        a.cost = num
                        if a.veteranAppearance then a.veteranAppearance.cost = num end
                    end
                    s.lastValidValue = num
                end
            end
            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    local s = KARDS.CardEditor.Canvas._costInputState
                    if s then
                        s.active = false
                        s.text = tostring(s.lastValidValue)
                        local a = KARDS.CardEditor.Canvas.CardAppearance
                        if a then
                            a.cost = s.lastValidValue
                            if a.veteranAppearance then a.veteranAppearance.cost = s.lastValidValue end
                        end
                    end
                end
            end
            entry.OnLoseFocus = function(self)
                local s = KARDS.CardEditor.Canvas._costInputState
                if s then
                    local num = tonumber(s.text)
                    if num == nil or num ~= math.floor(num) or num < 0 or num > 99 then
                        s.text = tostring(s.lastValidValue)
                        local a = KARDS.CardEditor.Canvas.CardAppearance
                        if a then
                            a.cost = s.lastValidValue
                            if a.veteranAppearance then a.veteranAppearance.cost = s.lastValidValue end
                        end
                    else
                        s.lastValidValue = num
                    end
                    s.active = false
                end
            end
        end,
    })

    -- ===== 行动花费输入框 =====
    manageTransparentEntry({
        entryKey = "_actionCostTextEntry",
        stateKey = "_actionCostInputState",
        isActive = (selectedId == "attr") and KARDS.CardEditor.Canvas._actionCostInputState and KARDS.CardEditor.Canvas._actionCostInputState.active,
        getPos = function()
            local colW = math.floor(((editW - 30) - 12) / 2)
            local sliderW = math.floor((colW - 50) / 2)
            return trX + 15 + colW + 12 + sliderW + 6, trY + 15 + 26 + 36 + 14 + 26 + (36 / 2) - 10, 36, 20
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._actionCostInputState; return s and s.text or ""
        end,
        onCreate = makeNumericCbs("actionCost", "_actionCostInputState"),
    })

    -- ===== 老兵属性透明输入框（仅在老兵模式 "attr" 页时激活） =====
    local aVet = KARDS.CardEditor.Canvas.CardAppearance
    local isVetAttr = aVet and (aVet.cardType == "infantry" or aVet.cardType == "tank" or aVet.cardType == "artillery" or aVet.cardType == "fighter" or aVet.cardType == "bomber") and table.HasValue(aVet.keywords or {}, "can_elevate_to_veteran")
    -- 老兵攻击力输入框（属性区第三行左列）
    manageTransparentEntry({
        entryKey = "_vetAttrTextEntry",
        stateKey = "_vetAttrInputState",
        isActive = isVetAttr and (selectedId == "attr") and (KARDS.CardEditor.Canvas._vetAttrInputState or {}).active,
        getPos = function()
            local cw = math.floor(((editW - 30) - 12) / 2)
            local sw = math.floor((cw - 50) / 2)
            local rh = 76
            local vetTitleH = 28
            local vetSectionH = vetTitleH + 10 + rh * 2
            local vetStartY = trY + trH - 15 - 172 - 20 - vetSectionH -- 与绘制端 sepY 对齐（底部条 172 + 间距 20，2026-10-04）
            local sepY = vetStartY
            local vetRow1Y = sepY + vetTitleH + 6
            return trX + 15 + sw + 6, vetRow1Y + 34, 36, 20
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._vetAttrInputState; return s and s.text or ""
        end,
        onCreate = makeVetNumericCbs("attack", "_vetAttrInputState"),
    })
    -- 老兵防御力输入框（属性区第三行右列）
    manageTransparentEntry({
        entryKey = "_vetDefenseTextEntry",
        stateKey = "_vetDefenseInputState",
        isActive = isVetAttr and (selectedId == "attr") and (KARDS.CardEditor.Canvas._vetDefenseInputState or {}).active,
        getPos = function()
            local cw = math.floor(((editW - 30) - 12) / 2)
            local sw = math.floor((cw - 50) / 2)
            local rh = 76
            local vetTitleH = 28
            local vetSectionH = vetTitleH + 10 + rh * 2
            local vetStartY = trY + trH - 15 - 172 - 20 - vetSectionH -- 与绘制端 sepY 对齐（底部条 172 + 间距 20，2026-10-04）
            local sepY = vetStartY
            local vetRow1Y = sepY + vetTitleH + 6
            return trX + 15 + cw + 12 + sw + 6, vetRow1Y + 34, 36, 20
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._vetDefenseInputState; return s and s.text or ""
        end,
        onCreate = makeVetNumericCbs("defense", "_vetDefenseInputState"),
    })
    -- 老兵行动花费输入框（属性区第四行右列）
    manageTransparentEntry({
        entryKey = "_vetActionCostTextEntry",
        stateKey = "_vetActionCostInputState",
        isActive = isVetAttr and (selectedId == "attr") and (KARDS.CardEditor.Canvas._vetActionCostInputState or {}).active,
        getPos = function()
            local cw = math.floor(((editW - 30) - 12) / 2)
            local sw = math.floor((cw - 50) / 2)
            local rh = 76
            local vetTitleH = 28
            local vetSectionH = vetTitleH + 10 + rh * 2
            local vetStartY = trY + trH - 15 - 172 - 20 - vetSectionH -- 与绘制端 sepY 对齐（底部条 172 + 间距 20，2026-10-04）
            local sepY = vetStartY
            local vetRow1Y = sepY + vetTitleH + 6
            local vetRow2Y = vetRow1Y + rh
            return trX + 15 + cw + 12 + sw + 6, vetRow2Y + 34, 36, 20
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._vetActionCostInputState; return s and s.text or ""
        end,
        onCreate = makeVetNumericCbs("actionCost", "_vetActionCostInputState"),
    })

    -- ===== 描述输入框 =====
    manageTransparentEntry({
        entryKey = "_descTextEntry",
        stateKey = "_descInputState",
        isActive = (selectedId == "description") and (KARDS.CardEditor.Canvas._descInputState or {}).active,
        getPos = function()
            local a_ = KARDS.CardEditor.Canvas.CardAppearance
            local isVet_ = a_ and (a_.cardType == "infantry" or a_.cardType == "tank" or a_.cardType == "artillery" or a_.cardType == "fighter" or a_.cardType == "bomber") and table.HasValue(a_.keywords or {}, "can_elevate_to_veteran")
            -- 与绘制端 descTextY（anchorY + 60 + 26）对齐，高度同 descInputH（trH - 226，2026-10-04）
            if isVet_ then
                local halfW = math.floor((editW - 30 - 12) / 2)
                return trX + 15, cy + 15 + 60 + 26, halfW, trH - 226
            end
            return trX + 15, cy + 15 + 60 + 26, editW - 30, trH - 226
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._descInputState; return s and s.text or ""
        end,
        onCreate = function(entry)
            local s = KARDS.CardEditor.Canvas._descInputState or {}
            s.caretPos = utf8.len(s.text or "") or 0
            KARDS.CardEditor.Canvas._descInputState = s
            entry.OnTextChanged = function(self)
                local ds = KARDS.CardEditor.Canvas._descInputState
                if ds then
                    ds.text = self:GetText()
                    if self.GetCaretPos then
                        local cp = self:GetCaretPos()
                        if cp ~= nil then ds.caretPos = cp end
                    end
                    local a = KARDS.CardEditor.Canvas.CardAppearance
                    if a then KARDS.CardEditor.Data.SetLocalizedField(a, "specialEffect", ds.text) end
                end
            end
            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    local ds = KARDS.CardEditor.Canvas._descInputState
                    if ds then ds.active = false end
                end
            end
        end,
        onFocus = function(entry)
            local ds = KARDS.CardEditor.Canvas._descInputState
            if ds and entry.GetCaretPos then
                local cp = entry:GetCaretPos()
                if cp ~= nil then ds.caretPos = cp end
            end
        end,
        keepState = true,
    })

    -- ===== 老兵描述输入框（仅在老兵模式时激活） =====
    local a = KARDS.CardEditor.Canvas.CardAppearance
    local isVet = a and (a.cardType == "infantry" or a.cardType == "tank" or a.cardType == "artillery" or a.cardType == "fighter" or a.cardType == "bomber") and table.HasValue(a.keywords or {}, "can_elevate_to_veteran")
    manageTransparentEntry({
        entryKey = "_vetDescTextEntry",
        stateKey = "_vetDescInputState",
        isActive = isVet and (selectedId == "description") and (KARDS.CardEditor.Canvas._vetDescInputState or {}).active,
        getPos = function()
            local halfW = math.floor((editW - 30 - 12) / 2)
            return trX + 15 + halfW + 12, cy + 15 + 60 + 26, halfW, trH - 226
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._vetDescInputState; return s and s.text or ""
        end,
        onCreate = function(entry)
            local s = KARDS.CardEditor.Canvas._vetDescInputState or {}
            s.caretPos = utf8.len(s.text or "") or 0
            KARDS.CardEditor.Canvas._vetDescInputState = s
            entry.OnTextChanged = function(self)
                local ds = KARDS.CardEditor.Canvas._vetDescInputState
                if ds then
                    ds.text = self:GetText()
                    if self.GetCaretPos then
                        local cp = self:GetCaretPos()
                        if cp ~= nil then ds.caretPos = cp end
                    end
                    local a = KARDS.CardEditor.Canvas.CardAppearance
                    if a and a.veteranAppearance then
                        KARDS.CardEditor.Data.SetLocalizedField(a.veteranAppearance, "specialEffect", ds.text)
                    end
                end
            end
            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    local ds = KARDS.CardEditor.Canvas._vetDescInputState
                    if ds then ds.active = false end
                end
            end
        end,
        onFocus = function(entry)
            local ds = KARDS.CardEditor.Canvas._vetDescInputState
            if ds and entry.GetCaretPos then
                local cp = entry:GetCaretPos()
                if cp ~= nil then ds.caretPos = cp end
            end
        end,
        keepState = true,
    })

    -- ===== 卡牌名称输入框（描述页） =====
    manageTransparentEntry({
        entryKey = "_cardNameTextEntry",
        stateKey = "_cardNameInputState",
        isActive = (selectedId == "description") and (KARDS.CardEditor.Canvas._cardNameInputState or {}).active,
        getPos = function()
            return trX + 15, cy + 15 + 22, editW - 30, 26
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._cardNameInputState; return s and s.text or ""
        end,
        onCreate = function(entry)
            local s = KARDS.CardEditor.Canvas._cardNameInputState or {}
            s.caretPos = utf8.len(s.text or "") or 0
            KARDS.CardEditor.Canvas._cardNameInputState = s
            entry.OnTextChanged = function(self)
                local ns = KARDS.CardEditor.Canvas._cardNameInputState
                if ns then
                    ns.text = self:GetText()
                    if self.GetCaretPos then
                        local cp = self:GetCaretPos()
                        if cp ~= nil then ns.caretPos = cp end
                    end
                    local a = KARDS.CardEditor.Canvas.CardAppearance
                    if a then KARDS.CardEditor.Data.SetLocalizedField(a, "name", ns.text) end
                end
            end
            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    local ns = KARDS.CardEditor.Canvas._cardNameInputState
                    if ns then ns.active = false end
                end
            end
        end,
        onFocus = function(entry)
            local ns = KARDS.CardEditor.Canvas._cardNameInputState
            if ns and entry.GetCaretPos then
                local cp = entry:GetCaretPos()
                if cp ~= nil then ns.caretPos = cp end
            end
        end,
        keepState = true,
    })

    -- ===== 插图 URL 输入框 =====
    manageTransparentEntry({
        entryKey = "_urlTextEntry",
        stateKey = "_urlInputState",
        isActive = (selectedId == "illustration") and (KARDS.CardEditor.Canvas._urlInputState or {}).active,
        getPos = function()
            local colGap = 20
            local localEditW = editW - 30
            local colW = (localEditW - colGap) / 2
            return trX + 15 + colW + colGap, trY + 15 + 66, colW, 32
        end,
        getText = function()
            local s = KARDS.CardEditor.Canvas._urlInputState; return s and s.text or ""
        end,
        onCreate = function(entry)
            local us = KARDS.CardEditor.Canvas._urlInputState or {}
            us.caretPos = utf8.len(us.text or "") or 0
            KARDS.CardEditor.Canvas._urlInputState = us
            entry.OnTextChanged = function(self)
                local us = KARDS.CardEditor.Canvas._urlInputState
                if us then
                    us.text = self:GetText()
                    if self.GetCaretPos then
                        local cp = self:GetCaretPos()
                        if cp ~= nil then us.caretPos = cp end
                    end
                end
            end
            entry.OnKeyCodeTyped = function(self, keyCode)
                local us = KARDS.CardEditor.Canvas._urlInputState
                if keyCode == KEY_ESCAPE then
                    if us then us.active = false end
                elseif keyCode == KEY_ENTER then
                    -- 回车提交时才下载（2026-10-04：原先每键入一个字符即发起下载，产生大量失败请求与残缺 URL）
                    if us and us.text and us.text ~= "" then
                        StartImageDownload(us.text)
                    end
                end
            end
        end,
        onFocus = function(entry)
            local us = KARDS.CardEditor.Canvas._urlInputState
            if us and entry.GetCaretPos then
                local cp = entry:GetCaretPos()
                if cp ~= nil then us.caretPos = cp end
            end
        end,
        keepState = true,
    })

    -- ===== BL：建议提示台 =====
    DrawSuggestionBoard(cx, sepY, sepX - cx, cy + ch - sepY, mx, my)

    -- ===== BR：预览区 =====
    DrawPreviewArea(sepX, sepY, cx + cw - sepX, cy + ch - sepY, app, mx, my, isLeftPressed)

    -- 隐藏旧VGUI控件

    local oldVGUI = {
        "NameBlackCheckBox", "NameBlackLabel", "NameFontSizeSlider", "NameEnglishCheckBox", "NameEnglishLabel",
        "CardTypeCheckBoxes", "CardTypeLabels", "QualityCheckBoxes", "QualityLabels",
        "KeywordCheckBoxes", "KeywordLabels", "CardTemplateCheckBox", "CardTemplateLabel",
        "FlashTemplateCheckBox", "FlashTemplateLabel", "CustomTemplateCheckBox", "CustomTemplateLabel",
        "CountryCheckBox", "CountryLabel", "DescFontSizeSlider", "ImageOffsetXSlider",
        "ImageOffsetYSlider", "ImageScaleSlider", "ImageUploadBtn", "CustomTemplateUploadBtn",
        "VeteranTitleLabel", "VeteranKeywordCheckBoxes", "VeteranKeywordLabels",
        "VeteranIntelNumber", "VeteranCountdownNumber", "VeteranHeavyArmorNumber",
        "VeteranDescFontSizeSlider"
    }
    for _, name in ipairs(oldVGUI) do
        local ctrl = KARDS.CardEditor.Canvas[name]
        if type(ctrl) == "table" then
            for _, sub in ipairs(ctrl) do
                if IsValid(sub) then sub:SetVisible(false) end
            end
        elseif IsValid(ctrl) then
            ctrl:SetVisible(false)
        end
    end
end

hook.Add("PlayerButtonDown", "KARDS_CanvasEditor_Keys", function(ply, button)
    if button == KEY_E and not ply:IsTyping() and not ply:IsTalking() then
        KARDS.CardEditor.Canvas.ToggleEditor()
    end
end)

hook.Add("KARDS_CardEditor_Open", "KARDS_CanvasEditor_Network", function()
    KARDS.CardEditor.Canvas.OpenEditor()
end)

-- 控制台命令：切换卡牌外貌编辑器激活状态
concommand.Add("kards_toggle_appearance", function()
    if KARDS.CardEditor.Canvas.Enabled then
        KARDS.CardEditor.Canvas.AppearanceEditorActive = not KARDS.CardEditor.Canvas.AppearanceEditorActive
        
        if KARDS.CardEditor.Canvas.AppearanceEditorActive then
            gui.EnableScreenClicker(false)
        else
            gui.EnableScreenClicker(true)
        end
    end
end)
