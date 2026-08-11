-- Kards 卡牌编辑器多语言支持
-- 共享文件，实现多语言支持
-- 翻译文件存储于 data/kards/lang/ 目录下
-- 每个 JSON 文件对应一种语言，文件名为语言代码（如 zh.json, en.json, ja.json）
-- 添加新语言只需在 data/kards/lang/ 目录下新建一个 [lang_code].json 文件即可

KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.I18n = KARDS.CardEditor.I18n or {}

local I18N = KARDS.CardEditor.I18n

local LANG_SEARCH_PATHS = {
    "data/kards/lang/"
}

I18N.DefaultLanguage = "zh"
I18N.FallbackLanguage = "en"
I18N.CurrentLanguage = I18N.DefaultLanguage
I18N.Languages = {}
I18N.Translations = {}
I18N.LanguageMeta = {}

local FALLBACK_TRANSLATIONS = {
    zh = {
        editor_title = "Kards 卡牌编辑器",
        menu_file = "文件",
        menu_edit = "编辑",
        menu_view = "视图",
        menu_help = "帮助",
        menu_file_new = "新建卡牌",
        menu_file_save = "保存卡牌",
        menu_file_load = "加载卡牌",
        menu_file_delete = "删除卡牌",
        menu_file_exit = "退出",
        menu_edit_copy = "复制卡牌",
        menu_edit_reset = "重置",
        menu_view_node_editor = "切换节点编辑器",
        menu_view_preview = "切换预览",
        menu_help_about = "关于",
        toolbar_new = "新建",
        toolbar_save = "保存",
        toolbar_load = "加载",
        toolbar_delete = "删除",
        toolbar_mode = "模式:",
        toolbar_mode_unit = "单位效果",
        toolbar_mode_command = "指令效果",
        toolbar_mode_counter = "反制效果",
        prop_name = "卡牌名称:",
        prop_cost = "费用:",
        prop_attack = "攻击力:",
        prop_defense = "防御力:",
        prop_description = "描述:",
        prop_keywords = "对战词条:",
        prop_keyword_blitz = "闪击",
        prop_keyword_smoke = "烟幕",
        preview_import = "导入图片",
        preview_template = "模板路径:",
        dialog_confirm_delete = "你确定要删除这张卡牌吗？",
        dialog_confirm_reset = "你确定要重置这张卡牌吗？",
        dialog_title_delete = "删除卡牌",
        dialog_title_reset = "重置卡牌",
        dialog_title_import = "导入图片",
        dialog_title_about = "关于",
        dialog_title_load = "加载卡牌",
        dialog_title_success = "成功",
        dialog_title_error = "错误",
        dialog_btn_yes = "是",
        dialog_btn_no = "否",
        dialog_btn_ok = "确定",
        msg_import_coming_soon = "图片导入功能将在未来更新中实现",
        msg_card_loaded = "卡牌加载成功",
        msg_card_saved = "卡牌保存成功",
        msg_card_deleted = "卡牌删除成功",
        msg_card_not_found = "卡牌未找到",
        node_draw = "抽取",
        node_deploy = "部署",
        node_join_battle = "加入战场",
        node_realtime = "实时判断",
        node_condition = "条件",
        node_condition_start = "开始",
        node_condition_condition = "条件",
        node_condition_meet = "满足",
        node_condition_not_meet = "不满足",
        condition_friendly_first = "友方先手",
        condition_occupy_frontline = "占领前线"
    },
    en = {
        editor_title = "Kards Card Editor",
        menu_file = "File",
        menu_edit = "Edit",
        menu_view = "View",
        menu_help = "Help",
        menu_file_new = "New Card",
        menu_file_save = "Save Card",
        menu_file_load = "Load Card",
        menu_file_delete = "Delete Card",
        menu_file_exit = "Exit",
        menu_edit_copy = "Copy Card",
        menu_edit_reset = "Reset",
        menu_view_node_editor = "Toggle Node Editor",
        menu_view_preview = "Toggle Preview",
        menu_help_about = "About",
        toolbar_new = "New",
        toolbar_save = "Save",
        toolbar_load = "Load",
        toolbar_delete = "Delete",
        toolbar_mode = "Mode:",
        toolbar_mode_unit = "Unit Effect",
        toolbar_mode_command = "Command Effect",
        toolbar_mode_counter = "Counter Effect",
        prop_name = "Card Name:",
        prop_cost = "Cost:",
        prop_attack = "Attack:",
        prop_defense = "Defense:",
        prop_description = "Description:",
        prop_keywords = "Keywords:",
        prop_keyword_blitz = "Blitz",
        prop_keyword_smoke = "Smoke",
        preview_import = "Import Image",
        preview_template = "Template Path:",
        dialog_confirm_delete = "Are you sure you want to delete this card?",
        dialog_confirm_reset = "Are you sure you want to reset this card?",
        dialog_title_delete = "Delete Card",
        dialog_title_reset = "Reset Card",
        dialog_title_import = "Import Image",
        dialog_title_about = "About",
        dialog_title_load = "Load Card",
        dialog_title_success = "Success",
        dialog_title_error = "Error",
        dialog_btn_yes = "Yes",
        dialog_btn_no = "No",
        dialog_btn_ok = "OK",
        msg_import_coming_soon = "Image import functionality will be implemented in a future update",
        msg_card_loaded = "Card loaded successfully",
        msg_card_saved = "Card saved successfully",
        msg_card_deleted = "Card deleted successfully",
        msg_card_not_found = "Card not found",
        node_draw = "Draw",
        node_deploy = "Deploy",
        node_join_battle = "Join Battle",
        node_realtime = "Realtime",
        node_condition = "Condition",
        node_condition_start = "Start",
        node_condition_condition = "Condition",
        node_condition_meet = "Meet",
        node_condition_not_meet = "Not Meet",
        condition_friendly_first = "Friendly First",
        condition_occupy_frontline = "Occupy Frontline"
    }
}

local FALLBACK_LANGUAGE_NAMES = {
    zh = "中文",
    en = "English"
}

local function GetFileExtension(path)
    return string.match(path, "%.([^%.]+)$")
end

local function GetFileNameWithoutExt(path)
    return string.match(path, "([^/\\]+)%.[^%.]+$") or path
end

local function FindFiles(pattern, searchPath)
    local files = file.Find(pattern, searchPath)
    return files or {}
end

local function ReadFile(path, searchPath)
    return file.Read(path, searchPath)
end

local function LoadLanguageFile(fileName, basePath, searchPath)
    local langCode = GetFileNameWithoutExt(fileName)
    local fullPath = basePath .. fileName
    local content = ReadFile(fullPath, searchPath)

    if not content then return false end

    local data = util.JSONToTable(content)
    if not data then
        ErrorNoHalt("[Kards I18n] Failed to parse language file: " .. fullPath .. "\n")
        return false
    end

    local meta = data._meta or {}
    local langName = meta.name or meta.native_name or FALLBACK_LANGUAGE_NAMES[langCode] or langCode

    I18N.Languages[langCode] = langName
    I18N.LanguageMeta[langCode] = meta

    if not I18N.Translations[langCode] then
        I18N.Translations[langCode] = {}
    end

    for key, value in pairs(data) do
        if key ~= "_meta" and type(value) == "string" then
            I18N.Translations[langCode][key] = value
        end
    end

    return true, langCode
end

local function LoadFromJsonFiles()
    local loadedLanguages = {}
    local foundFiles = false

    for _, basePath in ipairs(LANG_SEARCH_PATHS) do
        for _, searchPath in ipairs({"GAME"}) do
            local files = FindFiles(basePath .. "*.json", searchPath)
            for _, fileName in ipairs(files) do
                if GetFileExtension(fileName) == "json" and not string.StartWith(fileName, "_") then
                    foundFiles = true
                    local success, langCode = LoadLanguageFile(fileName, basePath, searchPath)
                    if success and langCode then
                        loadedLanguages[langCode] = true
                    end
                end
            end
        end
    end

    return loadedLanguages, foundFiles
end

local function LoadAllTranslations()
    I18N.Translations = {}
    I18N.Languages = {}
    I18N.LanguageMeta = {}

    for langCode, translations in pairs(FALLBACK_TRANSLATIONS) do
        I18N.Translations[langCode] = table.Copy(translations)
        I18N.Languages[langCode] = FALLBACK_LANGUAGE_NAMES[langCode] or langCode
    end

    local loadedLanguages, foundFiles = LoadFromJsonFiles()

    local count = 0
    for _ in pairs(loadedLanguages) do count = count + 1 end

    if foundFiles and count > 0 then
        if KARDS.CardEditor.Log then
            KARDS.CardEditor:Log("Loaded " .. count .. " language file(s) from data/kards/lang/ directory", "DEBUG")
        end
    else
        if KARDS.CardEditor.Log then
            KARDS.CardEditor:Log("No language files found in data/kards/lang/ directory, using built-in translations", "DEBUG")
        end
    end

    if not I18N.Translations[I18N.CurrentLanguage] then
        I18N.CurrentLanguage = I18N.DefaultLanguage
    end
    if not I18N.Translations[I18N.CurrentLanguage] then
        I18N.CurrentLanguage = I18N.FallbackLanguage
    end
end

LoadAllTranslations()

function I18N:Get(key, default)
    local lang = self.CurrentLanguage

    if self.Translations[lang] and self.Translations[lang][key] then
        return self.Translations[lang][key]
    end

    if self.Translations[self.FallbackLanguage] and self.Translations[self.FallbackLanguage][key] then
        return self.Translations[self.FallbackLanguage][key]
    end

    if self.Translations[self.DefaultLanguage] and self.Translations[self.DefaultLanguage][key] then
        return self.Translations[self.DefaultLanguage][key]
    end

    return default or key
end

function I18N:SetLanguage(lang)
    if self.Translations[lang] then
        self.CurrentLanguage = lang
        return true
    end

    for code, _ in pairs(self.Languages) do
        if string.StartWith(code, lang) or string.StartWith(lang, code) then
            self.CurrentLanguage = code
            return true
        end
    end

    return false
end

function I18N:GetCurrentLanguage()
    return self.CurrentLanguage
end

function I18N:GetLanguages()
    return self.Languages
end

function I18N:GetLanguageMeta(lang)
    lang = lang or self.CurrentLanguage
    return self.LanguageMeta[lang] or {}
end

function I18N:Reload()
    LoadAllTranslations()
end

function I18N:AddLanguage(code, name)
    if not self.Languages[code] then
        self.Languages[code] = name
        self.Translations[code] = self.Translations[code] or {}
    end
end

function I18N:AddTranslation(lang, key, value)
    if not self.Translations[lang] then
        self.Translations[lang] = {}
    end
    self.Translations[lang][key] = value
end

function I18N:LoadLanguageFile(filePath)
    local basePath, fileName = string.match(filePath, "^(.+/)([^/]+)$")
    if not basePath then
        basePath = ""
        fileName = filePath
    end
    local success, langCode = LoadLanguageFile(fileName, basePath, "GAME")
    if not success then
        success, langCode = LoadLanguageFile(fileName, basePath, "LUA")
    end
    return success, langCode
end

function I18N:HasTranslation(key, lang)
    lang = lang or self.CurrentLanguage
    return self.Translations[lang] and self.Translations[lang][key] ~= nil
end

function I18N:GetAvailableLanguages()
    local result = {}
    for code, name in pairs(self.Languages) do
        table.insert(result, {
            code = code,
            name = name,
            meta = self.LanguageMeta[code] or {}
        })
    end
    table.SortByMember(result, "name", true)
    return result
end
