-- Kards 卡牌编辑器保存系统
-- 三目录结构：卡牌 / 效果函数 / 词条函数（词条函数未实现）
-- 兼容 StarfallEx 和 Gmod 原生 API

KARDS.CardEditor.SaveSystem = KARDS.CardEditor.SaveSystem or {}

-- ============ 默认卡牌锁定（测试版开关） ============
-- 「默认卡牌」= 随插件发布的官方卡牌：一旦标记为默认即被锁定，不可修改、不可删除，
-- 仅可通过「解锁默认卡牌」取消锁定后再编辑。
-- 测试版（true）：卡牌编辑器保留「设为默认卡牌」勾选与「解锁默认卡牌」完整功能，
--   便于设计与调试官方卡牌。
-- 正式版发布前：将本开关置为 false，并删除 cl_ca_save_load.lua / cl_canvas_editor.lua
--   中标注「【正式版移除】」的设为默认 / 解锁默认入口代码——此后默认卡牌对玩家永久
--   锁定（SaveCard / DeleteCard 始终拦截），且无法创建新的默认卡牌或解锁既有默认卡牌。
KARDS.CardEditor.DefaultCardTestMode = true

-- E 修复（2026-08-12）：GetAllCardsInfo 会话级缓存——原实现每次全量列目录（3 次 Find）+
-- 每文件读盘 + JSON decode（GetCardInfo 无缓存）。DeckFindCardInfo 在开局/抽牌/卡面
-- 初始化时每张卡调用一次 → 开局 9 卡 × 44 文件 ≈ 396 次读盘（sim 5.4s 卡顿归因大头，
-- 见 debug-cardtable-cardback.md Fix E）。卡牌文件仅随保存/删除变化 → 缓存到写操作
-- 失效（SaveCard / DeleteFile 置 nil，下期调用重建）。声明须先于 SaveCard（L137）——
-- 后者引用本变量，Lua 词法作用域下后置声明会解析为全局 nil。
local GetAllCardsInfoCache = nil

-- 单卡信息缓存（2026-08-14 性能优化）：GetCardInfo 每次从磁盘读卡牌 JSON +
-- 解码，开局建卡组（DeckCardHandleFromFile 39 张）、客户端拿起判定
--（GetCardEffectNodeInfo 每张新实体首次拿起）对同 fileName 反复读取。
-- 卡牌文件仅随保存/删除变化 → 与 GetAllCardsInfoCache 同点失效（SaveCard /
-- DeleteFile → InvalidateCaches）。注意：返回的 info 与 GetAllCardsInfoCache
-- 共享同一对象（原全量缓存已如此），调用方均为只读，禁止改写。
local GetCardInfoCache = {}

-- 效果文件缓存（2026-08-14 性能优化）：LoadEffect 每次从磁盘读效果 JSON +
-- 解码，开局建卡组（LoadEffectForRuntime 每张卡）+ 客户端拿起判定
--（GetCardEffectNodeInfo 每张新实体）反复读取同一文件。缓存保存原始解码结果，
-- 命中/未命中一律返回深拷贝——编辑器（INE ImportEffectData 原地改写 node.data）
-- 与 LoadEffectForRuntime（node.data = runtimeData）会修改返回表，深拷贝保证
-- 各调用方拿到独立副本，避免未保存的编辑器修改泄漏到战斗/后续加载
--（保持「读磁盘状态」原语义）。
local LoadEffectCache = {}

-- JSON 数据深拷贝（LoadEffect 分发独立副本用；效果 JSON 为纯数据表，键均为
-- 字符串，无需考虑 function/userdata/自引用）
-- 统一委托 Core.Utils.DeepCopy（sh_utils.lua，本文件在其后加载直接引用；
-- 纯数据 JSON 键均为字符串，键拷贝差异行为等价）
local DeepCopy = KARDS.CardEditor.Core.Utils.DeepCopy

-- 缓存失效（保存/删除卡牌、效果文件时调用，见 SaveCard / DeleteFile）
local function InvalidateCaches()
    GetAllCardsInfoCache = nil
    GetCardInfoCache = {}
    LoadEffectCache = {}
end

-- ============ 目录常量 ============
-- 注意：GMod 文件系统不支持中文路径，使用英文目录名，UI 显示中文标签

--- 卡牌保存目录：存放卡牌外貌+属性+词条+效果路径
local CARDS_DIR = "card_editor/cards"
--- 总部保存目录：总部卡单独存放（仅保存插图路径/名称/描述/防御，效果正式版再做）
local HQ_DIR = "card_editor/headquarters"
--- 效果函数目录：存放 INE 节点函数（卡牌效果绑定 INE 函数）
local EFFECTS_DIR = "card_editor/effects"
--- 词条函数目录：存放关键词触发函数（预留，未来战斗系统使用）
local KEYWORDS_DIR = "card_editor/keywords"

-- ============ StarfallEx 检测 ============

local function IsStarfallEx()
    return _G.json and _G.file and type(_G.file.Write) == "function" and type(_G.json.encode) == "function"
end

-- ============ 统一文件操作接口 ============

local FileOps = {
    GetPath = function(dir, fileName)
        return dir .. "/" .. fileName
    end,

    EnsureDir = function(dir)
        file.CreateDir(dir)
    end,

    Encode = function(data)
        if IsStarfallEx() then
            return json.encode(data, true)
        else
            return util.TableToJSON(data, true)
        end
    end,

    Decode = function(jsonString)
        if IsStarfallEx() then
            return pcall(json.decode, jsonString)
        else
            local data = util.JSONToTable(jsonString)
            return data ~= nil, data
        end
    end,

    Write = function(filePath, content)
        -- GMod 原生 file.Write 无返回值，不能依赖其返回判断成败；且父目录缺失时
        -- file.Write 会静默失败（不报错），仅表现为写入后 file.Exists 为 false。
        -- 修复：写入前逐级确保父目录存在（带尾斜杠创建——与成功落盘的
        -- kards/cards/ 目录创建方式一致），写入后再校验落盘。
        local dir = string.match(filePath, "^(.*)/[^/]+$")
        if dir and dir ~= "" then
            local cur = ""
            for _, part in ipairs(string.Explode("/", dir)) do
                cur = cur == "" and part or (cur .. "/" .. part)
                file.CreateDir(cur .. "/")
            end
        end
        file.Write(filePath, content)
        return file.Exists(filePath, "DATA")
    end,

    Read = function(filePath)
        return file.Read(filePath, "DATA")
    end,

    Exists = function(filePath)
        return file.Exists(filePath, "DATA")
    end,

    Find = function(pattern)
        return file.Find(pattern, "DATA")
    end
}

-- ============ 目录初始化 ============

function KARDS.CardEditor.SaveSystem.EnsureDirectories()
    FileOps.EnsureDir("card_editor")
    FileOps.EnsureDir(CARDS_DIR)
    FileOps.EnsureDir(HQ_DIR)
    FileOps.EnsureDir(EFFECTS_DIR)
    FileOps.EnsureDir(KEYWORDS_DIR)
end

-- 初始化（用 pcall 防止文件系统未就绪阻塞后续函数定义）
pcall(KARDS.CardEditor.SaveSystem.EnsureDirectories)
print("[CardEditor] Save system initialized (cards/ headquarters/ effects/ keywords/)")

-- ============ 工具函数 ============

local function ensureExt(fileName, ext)
    ext = ext or ".json"
    if not string.EndsWith(fileName, ext) then
        return fileName .. ext
    end
    return fileName
end

local function safeFileName(name)
    if not name or type(name) ~= "string" then return nil end
    local safe = string.gsub(name, "[<>:\"/\\|?*]", "_")
    safe = string.gsub(safe, "%.%.", "_")
    -- GMod 文件系统不支持非 ASCII 路径（中文等）：非 ASCII 字节转义为 %XX
    -- （URL 风格，可逆无歧义——原始 '%' 字符同样会被转义为 %25）。
    -- 保存/加载/删除均以转义名作为磁盘文件名；UI 显示时用 UnescapeFileName 还原。
    safe = string.gsub(safe, "([^%w%._%-])", function(c)
        return string.format("%%%02X", c:byte(1))
    end)
    return safe
end

--- 反解 ASCII 转义的文件名（%XX → 原始字节），用于 UI 显示中文文件名
--- @param fileName string 磁盘文件名（可能含 %XX 转义）
--- @return string 显示用文件名
function KARDS.CardEditor.SaveSystem.UnescapeFileName(fileName)
    return string.gsub(tostring(fileName or ""), "%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

--- 解析卡牌文件的磁盘路径（cards / headquarters / 根目录三级回退），
--- 入参兼容「已转义磁盘名」与「原始名称」两种形式（与 LoadCard 一致）。
--- @param fileName string 文件名（不含路径）
--- @return string|nil 磁盘路径；@return string|nil 命中的磁盘文件名
local function ResolveCardPath(fileName)
    if not fileName or type(fileName) ~= "string" then return nil end
    local name = ensureExt(fileName)
    if not name then return nil end
    local candidates = { name }
    local escaped = ensureExt(safeFileName(name))
    if escaped and escaped ~= name then
        table.insert(candidates, escaped)
    end
    for _, n in ipairs(candidates) do
        local p = FileOps.GetPath(CARDS_DIR, n)
        if FileOps.Exists(p) then return p, n end
        p = FileOps.GetPath(HQ_DIR, n)
        if FileOps.Exists(p) then return p, n end
        p = "card_editor/" .. n
        if FileOps.Exists(p) then return p, n end
    end
    return nil
end

-- ============ 第1类：卡牌保存/加载 ============

--- 保存卡牌（外貌、属性、词条、效果路径）
--- 不再保存 nodes/connections（这些放在效果函数文件中）
--- @param fileName string 文件名（不含路径）
--- @param textureInfo table|nil 卡面纹理信息 { full, template, w, h }
---   （DATA 相对路径 + 渲染像素尺寸；保存前由客户端 EnsureCardTextures 渲染一次落盘，
---   已点过「渲染」则仅指向其文件路径；组卡/生成环节直接引用，不再反复离屏渲染）
--- @return boolean 是否保存成功
function KARDS.CardEditor.SaveSystem.SaveCard(fileName, textureInfo)
    InvalidateCaches() -- E 修复：保存改卡面/名称，全量信息缓存失效；2026-08-14 扩展为单卡/效果缓存同点失效
    fileName = ensureExt(safeFileName(fileName))
    if not fileName then return false end

    -- 默认卡牌锁定（不可修改）：目标文件已存在且为默认卡牌时，禁止覆盖保存，
    -- 需先在保存窗口解锁后再保存。正式版同样生效——保护官方默认卡牌不被玩家篡改。
    if KARDS.CardEditor.SaveSystem.IsDefaultCard(fileName) then
        print("[CardEditor] SaveCard blocked: '" .. fileName .. "' 是默认卡牌，已锁定不可修改")
        return false, "locked"
    end

    KARDS.CardEditor.SaveSystem.EnsureDirectories()

    -- 默认卡牌标记随外观数据落盘；正式版开关关闭时强制为 false（禁止创建默认卡牌）
    local liveApp = KARDS.CardEditor.Canvas.CardAppearance
    if liveApp then
        liveApp.isDefault = (KARDS.CardEditor.DefaultCardTestMode == true) and (liveApp.isDefault == true) or false
    end

    local currentTime = os.date("%Y-%m-%d %H:%M")

    -- 总部卡：单独目录保存，仅保存插图路径/名称/描述/防御（效果正式版再做）
    local app = KARDS.CardEditor.Canvas.CardAppearance or {}
    if app.cardType == "headquarter" then
        local hqData = {
            cardType = "headquarter",
            cardAppearance = {
                cardType = "headquarter",
                imagePath = app.imagePath or "",
                name = app.name or "",
                specialEffect = app.specialEffect or "", -- 描述
                defense = app.defense or 20,
                isDefault = app.isDefault == true, -- 默认卡牌（锁定）标记
            },
            texturePath = textureInfo and {
                full = textureInfo.full,
                template = textureInfo.template,
            } or nil,
            textureSize = textureInfo and {
                w = textureInfo.w,
                h = textureInfo.h,
            } or nil,
            savedAt = currentTime,
            fileName = fileName,
        }
        local hqJson = FileOps.Encode(hqData)
        if not hqJson then
            print("[CardEditor] SaveCard (HQ) failed: JSON encode error")
            return false
        end
        local hqPath = FileOps.GetPath(HQ_DIR, fileName)
        local hqOk = FileOps.Write(hqPath, hqJson)
        if not hqOk then
            print("[CardEditor] SaveCard (HQ) failed: File write error -> " .. hqPath)
            return false
        end
        print("[CardEditor] HQ card saved: " .. fileName .. " at " .. currentTime)
        return true
    end

    local cardData = {
        cardAppearance = KARDS.CardEditor.Canvas.CardAppearance or {},
        -- 卡面纹理落盘路径 + 渲染像素尺寸（AddLocal/材质对齐用）
        texturePath = textureInfo and {
            full = textureInfo.full,
            template = textureInfo.template,
        } or nil,
        textureSize = textureInfo and {
            w = textureInfo.w,
            h = textureInfo.h,
        } or nil,
        currentPage = KARDS.CardEditor.Canvas.CurrentPage or "appearance",
        appearanceEditorActive = KARDS.CardEditor.Canvas.AppearanceEditorActive or false,
        savedAt = currentTime,
        fileName = fileName
    }

    local jsonString = FileOps.Encode(cardData)
    if not jsonString then
        print("[CardEditor] SaveCard failed: JSON encode error")
        return false
    end

    local filePath = FileOps.GetPath(CARDS_DIR, fileName)
    local success = FileOps.Write(filePath, jsonString)
    if not success then
        print("[CardEditor] SaveCard failed: File write error -> " .. filePath)
        return false
    end

    print("[CardEditor] Card saved: " .. fileName .. " at " .. currentTime)
    return true
end

-- 总部精简数据补全为编辑器可用的完整结构（缺失字段补默认）
-- 总部保存时仅落盘 cardType/imagePath/name/specialEffect(描述)/defense，
-- 其余字段在此按默认值补齐，保证编辑器渲染/属性区不因 nil 崩溃
local function EnsureHQAppearance(app)
    app.cardType = "headquarter"
    app.name = app.name or "总部"
    app.imagePath = app.imagePath or ""
    app.specialEffect = app.specialEffect or "" -- 描述
    app.defense = app.defense or 20
    app.cost = 0          -- 总部无费用
    app.actionCost = 0    -- 总部无行动费用
    app.attack = 0        -- 总部无攻击力
    app.country = ""      -- 总部无国籍
    app.quality = "normal" -- 总部无品质
    app.keywords = {}     -- 总部无词条
    app.keywordValues = app.keywordValues or { intel = 0, countdown = 0, heavy_armor = 0 }
    app.cardTemplate = "card"
    app.customTemplatePath = ""
    app.nameIsBlack = false
    app.nameFontSize = 36
    app.descFontSize = 20
    app.nameIsEnglish = false
    app.pincerValue = ""
    app.imageOffsetX = 0
    app.imageOffsetY = 0
    app.imageScale = 1
    app.effectPath = "" -- 总部效果正式版再做，暂不绑定
    app.combatModifiers = { outgoing = {}, incoming = {} }
    app.historyImagePath = app.historyImagePath or ""
    app.historyImageOffsetX = 0
    app.historyImageOffsetY = 0
    app.historyImageScale = 1
    app.historyText = app.historyText or ""
    app.canElevateToVeteran = false
    app.isDefault = app.isDefault or false -- 默认卡牌（锁定）标记，总部卡一并保留
    if not app.veteranAppearance or type(app.veteranAppearance) ~= "table" then
        app.veteranAppearance = {
            name = app.name .. "(老兵)", cost = 0, actionCost = 0, attack = 0, defense = 0,
            quality = "special", keywords = { "veteran" }, keywordValues = { intel = 0, countdown = 0, heavy_armor = 0 },
            specialEffect = "", imagePath = "", cardTemplate = "card", customTemplatePath = "",
            nameIsBlack = false, nameFontSize = 36, descFontSize = 20, nameIsEnglish = false,
            imageOffsetX = 0, imageOffsetY = 0, imageScale = 1,
        }
    end
    -- 转换目标卡（2026-09-26 缺口 J）：本卡被转换效果作用后变成哪张卡（卡文件名，
    -- 空字符串表示不换卡）。默认补齐，旧存档无此字段时保持不换卡语义
    app.convertTarget = app.convertTarget or ""
    return app
end

--- 加载卡牌
--- @param fileName string 文件名（不含路径）
--- @return boolean 是否加载成功
function KARDS.CardEditor.SaveSystem.LoadCard(fileName)
    if not fileName or type(fileName) ~= "string" then return false end
    fileName = ensureExt(fileName)
    if not fileName then return false end

    -- 入参兼容两种形式：
    --   1) 已转义磁盘文件名（GetCardFiles 返回，如 %E4%BA%94...json）——优先直接命中；
    --   2) 原始名称（中文等，如"五年计划"）——经 safeFileName 转义后命中。
    -- 不能直接对入参 safeFileName：磁盘名已含 %XX，会被二次转义成 %25 导致文件找不到。
    local candidates = { fileName }
    local escaped = ensureExt(safeFileName(fileName))
    if escaped ~= fileName then
        table.insert(candidates, escaped)
    end

    local filePath = nil
    for _, name in ipairs(candidates) do
        local p = FileOps.GetPath(CARDS_DIR, name)
        if FileOps.Exists(p) then filePath = p; fileName = name; break end
        -- 总部卡单独存放于 headquarters/ 目录
        p = FileOps.GetPath(HQ_DIR, name)
        if FileOps.Exists(p) then filePath = p; fileName = name; break end
        -- 回退检查根目录（兼容旧版本保存在 card_editor/ 下的文件）
        p = "card_editor/" .. name
        if FileOps.Exists(p) then filePath = p; fileName = name; break end
    end
    if not filePath then
        print("[CardEditor] LoadCard failed: File not found - " .. fileName)
        return false
    end

    local content = FileOps.Read(filePath)
    if not content then
        print("[CardEditor] LoadCard failed: File read error")
        return false
    end

    local success, data = FileOps.Decode(content)
    if not success or not data then
        print("[CardEditor] LoadCard failed: JSON decode error")
        return false
    end

    -- 还原数据
    if data.cardAppearance then
        if data.cardType == "headquarter" or data.cardAppearance.cardType == "headquarter" then
            -- 总部卡：精简数据补全为完整结构（不绑定效果）
            KARDS.CardEditor.Canvas.CardAppearance = EnsureHQAppearance(data.cardAppearance)
        else
            KARDS.CardEditor.Canvas.CardAppearance = data.cardAppearance
            -- 序列化兼容：旧版本保存的卡牌缺少 combatModifiers 字段，补默认空表
            -- （亨舍尔 HS 129 等卡牌固有战斗属性，结构见 cl_canvas_editor.lua CardAppearance）
            if not data.cardAppearance.combatModifiers then
                data.cardAppearance.combatModifiers = { outgoing = {}, incoming = {} }
            end
            -- 序列化兼容：旧版本保存的卡牌缺少 cardScale/sounds 字段，补默认
            -- （cardScale 决定放牌/部署音效分配，见 KARDS.CardSounds；sounds 为事件音效路径表）
            if not data.cardAppearance.cardScale then
                data.cardAppearance.cardScale = "small"
            end
            if not data.cardAppearance.sounds then
                data.cardAppearance.sounds = {}
            end
            -- 音效手动锁定兼容（2026-08-14）：旧卡无 _manual 标记，但自动分配
            -- （规模/类型）为本轮新增——已配置的 deploy/attack 必来自手动选择器，
            -- 视为手动锁定（五角星优先，规模/类型变更不再覆盖，见 KARDS.CardSounds.AutoAssignDeploySound / AutoAssignAttackSound）
            if not data.cardAppearance.sounds._manual then
                data.cardAppearance.sounds._manual = {}
                if data.cardAppearance.sounds.deploy then data.cardAppearance.sounds._manual.deploy = true end
                if data.cardAppearance.sounds.attack then data.cardAppearance.sounds._manual.attack = true end
            end
        end
    end
    if data.currentPage then
        KARDS.CardEditor.Canvas.CurrentPage = data.currentPage
    end
    if data.appearanceEditorActive ~= nil then
        KARDS.CardEditor.Canvas.AppearanceEditorActive = data.appearanceEditorActive
    end

    -- 记录当前编辑卡牌的磁盘文件名（默认卡牌解锁等操作需要按文件定位）；
    -- 已转义磁盘名，与 GetCardFiles 返回的列表项一致
    KARDS.CardEditor.Canvas.CurrentCardFile = fileName

    print("[CardEditor] Card loaded: " .. fileName)

    -- 加载效果函数（如果卡牌绑定了效果路径）
    local app = KARDS.CardEditor.Canvas.CardAppearance
    if app and app.effectPath and app.effectPath ~= "" then
        KARDS.CardEditor.SaveSystem.LoadEffect(app.effectPath)
    end

    -- 恢复 UI 状态
    if KARDS.CardEditor.Canvas.UpdateControlsFromAppearance then
        KARDS.CardEditor.Canvas.UpdateControlsFromAppearance()
    end
    if KARDS.CardEditor.Canvas.UpdateVeteranControlsFromAppearance then
        KARDS.CardEditor.Canvas.UpdateVeteranControlsFromAppearance()
    end

    -- 总部卡：同步编辑器模式与开始点（headquarter 模式）
    if data.cardType == "headquarter" or (data.cardAppearance and data.cardAppearance.cardType == "headquarter") then
        if KARDS.CardEditor.Canvas.UpdateEditorModeFromCardType then
            KARDS.CardEditor.Canvas.UpdateEditorModeFromCardType()
        end
    end

    return true
end

--- 获取卡牌目录下的所有文件列表
--- 搜索 card_editor/cards/（普通卡）、card_editor/headquarters/（总部卡），
--- 并回退搜索 card_editor/（兼容旧文件）
--- @return table 文件名列表
function KARDS.CardEditor.SaveSystem.GetCardFiles()
    local result = {}
    -- 普通卡：cards 子目录
    local files = FileOps.Find(CARDS_DIR .. "/*") or {}
    for _, f in ipairs(files) do
        if string.EndsWith(f, ".json") then
            result[f] = true  -- 用临时集合去重
        end
    end
    -- 总部卡：headquarters 子目录（独立存放）
    local hqFiles = FileOps.Find(HQ_DIR .. "/*") or {}
    for _, f in ipairs(hqFiles) do
        if string.EndsWith(f, ".json") then
            result[f] = true
        end
    end
    -- 回退搜索根目录（兼容旧版本保存在 card_editor/ 下的文件）
    local rootFiles = FileOps.Find("card_editor/*") or {}
    for _, f in ipairs(rootFiles) do
        if string.EndsWith(f, ".json") then
            result[f] = true
        end
    end
    -- 转回列表
    local list = {}
    for f in pairs(result) do
        table.insert(list, f)
    end
    table.sort(list)
    return list
end

--- 获取所有卡牌文件信息
--- @return table { fileName, name, savedAt, cardAppearance }[]
function KARDS.CardEditor.SaveSystem.GetAllCardsInfo()
    if GetAllCardsInfoCache then return GetAllCardsInfoCache end
    local files = KARDS.CardEditor.SaveSystem.GetCardFiles()
    local infos = {}
    for _, fileName in ipairs(files) do
        local info = KARDS.CardEditor.SaveSystem.GetCardInfo(fileName)
        if info then
            table.insert(infos, info)
        end
    end
    GetAllCardsInfoCache = infos
    return infos
end

--- 获取单张卡牌文件信息
function KARDS.CardEditor.SaveSystem.GetCardInfo(fileName)
    local cached = GetCardInfoCache[fileName]
    if cached ~= nil then return cached end

    local filePath = FileOps.GetPath(CARDS_DIR, fileName)
    if not FileOps.Exists(filePath) then
        -- 总部卡单独存放于 headquarters/ 目录
        filePath = FileOps.GetPath(HQ_DIR, fileName)
        if not FileOps.Exists(filePath) then
            -- 回退检查根目录（兼容旧版本保存在 card_editor/ 下的文件）
            filePath = "card_editor/" .. fileName
            if not FileOps.Exists(filePath) then return nil end
        end
    end

    local content = FileOps.Read(filePath)
    if not content then return nil end

    local success, data = FileOps.Decode(content)
    if not success or not data then return nil end

    local info = {
        fileName = fileName,
        name = "",
        savedAt = data.savedAt or "未知时间",
        cardAppearance = data.cardAppearance or {},
        -- 卡面纹理落盘路径 + 渲染像素尺寸（组卡环节直接引用，避免反复离屏渲染）
        texturePath = data.texturePath or nil,
        textureSize = data.textureSize or nil,
        -- 默认卡牌（锁定）标记：卡牌列表展示锁定状态用
        isDefault = data.cardAppearance and data.cardAppearance.isDefault == true or false,
    }
    if data.cardAppearance and data.cardAppearance.name then
        info.name = data.cardAppearance.name
    end
    GetCardInfoCache[fileName] = info -- 2026-08-14：单卡结果缓存（SaveCard/DeleteFile 失效）
    return info
end

-- ============ 默认卡牌锁定判定与解锁 ============

--- 判断卡牌文件是否为「默认卡牌」（锁定）。直接读盘、不经缓存，用于锁定判定。
--- @param fileName string 文件名（不含路径，兼容转义名与原始名）
--- @return boolean
function KARDS.CardEditor.SaveSystem.IsDefaultCard(fileName)
    local path = ResolveCardPath(fileName)
    if not path then return false end
    local content = FileOps.Read(path)
    if not content then return false end
    local ok, data = FileOps.Decode(content)
    if not ok or not data then return false end
    return data.cardAppearance and data.cardAppearance.isDefault == true or false
end

--- 解锁「默认卡牌」（取消锁定）：清除卡牌文件中的 isDefault 标记，使其恢复可修改/可删除。
--- 仅测试版可用（KARDS.CardEditor.DefaultCardTestMode）；正式版直接拒绝。
--- 【正式版移除】本函数即为「解锁默认」相关逻辑，正式版发布前可整段删除
---（调用处 cl_ca_save_load.lua / cl_canvas_editor.lua 的解锁入口一并删除）。
--- @param fileName string 文件名（不含路径，兼容转义名与原始名）
--- @return boolean 是否解锁成功
function KARDS.CardEditor.SaveSystem.UnlockDefaultCard(fileName)
    if KARDS.CardEditor.DefaultCardTestMode ~= true then
        print("[CardEditor] UnlockDefaultCard 已禁用（正式版）")
        return false
    end
    local path, name = ResolveCardPath(fileName)
    if not path then return false end
    local content = FileOps.Read(path)
    if not content then return false end
    local ok, data = FileOps.Decode(content)
    if not ok or not data or type(data) ~= "table" then return false end
    if not (data.cardAppearance and data.cardAppearance.isDefault == true) then return false end
    data.cardAppearance.isDefault = false
    local json = FileOps.Encode(data)
    if not json or not FileOps.Write(path, json) then return false end
    InvalidateCaches()
    print("[CardEditor] 默认卡牌已解锁: " .. tostring(name))
    return true
end

-- ============ 第2类：效果函数保存/加载 ============

--- 保存效果函数（INE 节点函数数据）
--- 如果函数包含子函数变量，在同目录创建子文件夹存放
--- @param fileName string 文件名（不含路径）
--- @param exportData table { nodes, connections, dataConnections, functions, ... }
--- @return string|boolean 保存成功返回效果文件完整相对路径（"card_editor/effects/xxx.json"，含安全转义后的磁盘名），失败返回 false
function KARDS.CardEditor.SaveSystem.SaveEffect(fileName, exportData)
    InvalidateCaches() -- 2026-08-14：效果文件改写，效果解析缓存失效（否则编辑器保存后战斗读到旧效果）
    fileName = ensureExt(safeFileName(fileName))
    if not fileName then return false end

    KARDS.CardEditor.SaveSystem.EnsureDirectories()

    local currentTime = os.date("%Y-%m-%d %H:%M")
    local saveData = table.Copy(exportData)
    saveData.savedAt = currentTime
    saveData.fileName = fileName

    -- 处理子函数：如果有子函数变量，保存到子目录
    if saveData.functions and type(saveData.functions) == "table" then
        local baseName = string.gsub(fileName, "%.json$", "")
        local subDir = EFFECTS_DIR .. "/" .. baseName .. "_sub"
        saveData.functions = {}  -- 先清空，改为存储路径

        for varName, funcData in pairs(exportData.functions or {}) do
            FileOps.EnsureDir(subDir)
            local subFileName = safeFileName(varName) .. ".json"
            if subFileName then
                local subData = funcData
                subData._varName = varName
                local subJson = FileOps.Encode(subData)
                if subJson then
                    FileOps.Write(subDir .. "/" .. subFileName, subJson)
                    -- 存完整相对路径（与 LoadEffect 直接 FileOps.Read(path) 的读取方式一致）
                    saveData.functions[varName] = EFFECTS_DIR .. "/" .. baseName .. "_sub/" .. subFileName
                end
            end
        end
    end

    local jsonString = FileOps.Encode(saveData)
    if not jsonString then
        print("[CardEditor] SaveEffect failed: JSON encode error")
        return false
    end

    local filePath = FileOps.GetPath(EFFECTS_DIR, fileName)
    local success = FileOps.Write(filePath, jsonString)
    if not success then
        print("[CardEditor] SaveEffect failed: File write error")
        return false
    end

    print("[CardEditor] Effect saved: " .. fileName .. " at " .. currentTime)
    -- 返回完整相对路径（"card_editor/effects/xxx.json"），
    -- 供调用方绑定卡牌 effectPath：LoadEffect 以 "^card_editor/effects/" 前缀判断
    -- 直接使用该路径，无需二次拼接
    return filePath
end

--- 加载效果函数
--- 自动加载子函数（从保存的路径读取）
--- @param fileName string 文件名（不含路径，或完整相对路径如 'effects/foo.json'）
--- @return table|nil 效果函数数据
function KARDS.CardEditor.SaveSystem.LoadEffect(fileName)
    fileName = ensureExt(fileName)
    if not fileName then return nil end

    -- 如果 fileName 已经包含 effects/ 前缀，直接使用；否则拼接
    local filePath
    if string.find(fileName, "^" .. EFFECTS_DIR .. "/") then
        filePath = fileName
    else
        filePath = FileOps.GetPath(EFFECTS_DIR, fileName)
    end

    -- 2026-08-14：效果解析结果缓存（SaveEffect/DeleteFile 经 InvalidateCaches 失效）。
    -- 缓存保存原始解码结果，一律返回深拷贝——编辑器与运行时路径会原地修改返回表
    --（INE ImportEffectData 改写 node.data、LoadEffectForRuntime 替换为 runtimeData），
    -- 深拷贝保证各调用方独立，缓存保持「磁盘状态」不被污染。
    local cached = LoadEffectCache[filePath]
    if cached ~= nil then return DeepCopy(cached) end

    if not FileOps.Exists(filePath) then
        print("[CardEditor] LoadEffect failed: File not found - " .. fileName)
        return nil
    end

    local content = FileOps.Read(filePath)
    if not content then
        print("[CardEditor] LoadEffect failed: File read error")
        return nil
    end

    local success, data = FileOps.Decode(content)
    if not success or not data then
        print("[CardEditor] LoadEffect failed: JSON decode error")
        return nil
    end

    -- 加载子函数
    if data.functions and type(data.functions) == "table" then
        for varName, path in pairs(data.functions) do
            if type(path) == "string" then
                -- 从保存的相对路径读取
                local subContent = FileOps.Read(path)
                if subContent then
                    local ok, subData = FileOps.Decode(subContent)
                    if ok and subData then
                        data.functions[varName] = subData
                    end
                end
            end
        end
    end

    LoadEffectCache[filePath] = data
    print("[CardEditor] Effect loaded: " .. fileName)
    return DeepCopy(data)
end

--- 加载效果函数（运行时模式）：应用保存端 BuildRuntimeData 迁移的节点运行时数据
--- 编辑器加载路径（LoadEffect 原样返回，保持编辑器组件键供面板显示）不受影响；
--- 服务端打出指令时用本函数获得 base + runtimeData（runtimeData 含按运行时
--- 类型独立计数迁移后的槽键），效果节点即按运行时键执行。
--- 旧格式（无 base/runtimeData）告警提示重新保存（否则 ParseBaseNode 返回 nil，效果不执行）。
--- @param fileName string 文件名
--- @return table|nil 效果函数数据（含 runtimeData 的节点 data 已替换为 runtimeData）
function KARDS.CardEditor.SaveSystem.LoadEffectForRuntime(fileName)
    local data = KARDS.CardEditor.SaveSystem.LoadEffect(fileName)
    if not data or not data.nodes then return data end
    for _, node in ipairs(data.nodes) do
        if node.runtimeData ~= nil then
            node.data = node.runtimeData
        elseif node.config and node.config ~= "" and not node.base then
            print(("[CardEditor] 警告: 效果节点「%s」为旧格式（无 base/runtimeData），效果将不执行，请重新保存"):format(
                tostring(node.name)))
        end
    end
    return data
end

--- 获取效果函数目录下的所有文件列表
function KARDS.CardEditor.SaveSystem.GetEffectFiles()
    local files = FileOps.Find(EFFECTS_DIR .. "/*") or {}
    local result = {}
    for _, f in ipairs(files) do
        if string.EndsWith(f, ".json") then
            table.insert(result, f)
        end
    end
    return result
end

-- ============ 第3类：词条函数（预留） ============

--- 获取词条函数目录下的所有文件列表
function KARDS.CardEditor.SaveSystem.GetKeywordFiles()
    local files = FileOps.Find(KEYWORDS_DIR .. "/*") or {}
    local result = {}
    for _, f in ipairs(files) do
        if string.EndsWith(f, ".json") then
            table.insert(result, f)
        end
    end
    return result
end

-- ============ 删除文件 ============

--- 删除任意目录下的文件
function KARDS.CardEditor.SaveSystem.DeleteFile(dir, fileName)
    InvalidateCaches() -- E 修复：删除卡牌，全量信息缓存失效；2026-08-14 扩展为单卡/效果缓存同点失效
    fileName = ensureExt(fileName)
    if not fileName then return false end

    local filePath = dir .. "/" .. fileName
    if FileOps.Exists(filePath) then
        file.Delete(filePath)
        print("[CardEditor] Deleted: " .. filePath)
        return true
    end
    return false
end

function KARDS.CardEditor.SaveSystem.DeleteCard(fileName)
    -- 默认卡牌锁定（不可删除）：已锁定卡牌一律拒绝删除，需先解锁。
    -- 正式版同样生效——保护官方默认卡牌不被玩家删除。
    if KARDS.CardEditor.SaveSystem.IsDefaultCard(fileName) then
        print("[CardEditor] DeleteCard blocked: '" .. tostring(fileName) .. "' 是默认卡牌，已锁定不可删除")
        return false, "locked"
    end
    if KARDS.CardEditor.SaveSystem.DeleteFile(CARDS_DIR, fileName) then return true end
    -- 总部卡单独存放于 headquarters/ 目录
    if KARDS.CardEditor.SaveSystem.DeleteFile(HQ_DIR, fileName) then return true end
    -- 回退删除根目录文件（兼容旧版本）
    return KARDS.CardEditor.SaveSystem.DeleteFile("card_editor", fileName)
end

function KARDS.CardEditor.SaveSystem.DeleteEffect(fileName)
    -- Also clean up sub-function directory if exists
    local baseName = string.gsub(ensureExt(fileName) or fileName, "%.json$", "")
    local subDir = EFFECTS_DIR .. "/" .. baseName .. "_sub"
    if file.Exists(subDir, "DATA") then
        local subFiles = FileOps.Find(subDir .. "/*") or {}
        for _, f in ipairs(subFiles) do
            file.Delete(subDir .. "/" .. f)
        end
        -- Can't delete directory in GMod, but clearing files is enough
    end
    return KARDS.CardEditor.SaveSystem.DeleteFile(EFFECTS_DIR, fileName)
end

-- ============ 旧接口兼容（委托到新接口） ============

--- 旧 Save() 委托到 SaveCard()
function KARDS.CardEditor.SaveSystem.Save(fileName)
    return KARDS.CardEditor.SaveSystem.SaveCard(fileName)
end

--- 旧 Load() 委托到 LoadCard()
function KARDS.CardEditor.SaveSystem.Load(fileName)
    return KARDS.CardEditor.SaveSystem.LoadCard(fileName)
end

--- 旧 GetSavedFiles() → 返回卡牌文件列表
function KARDS.CardEditor.SaveSystem.GetSavedFiles()
    return KARDS.CardEditor.SaveSystem.GetCardFiles()
end

--- 旧 GetAllSavedCardsInfo() → 返回卡牌信息列表
function KARDS.CardEditor.SaveSystem.GetAllSavedCardsInfo()
    return KARDS.CardEditor.SaveSystem.GetAllCardsInfo()
end

--- 旧 GetCardInfoFromFile()
function KARDS.CardEditor.SaveSystem.GetCardInfoFromFile(fileName)
    return KARDS.CardEditor.SaveSystem.GetCardInfo(fileName)
end

--- 旧 GetCardNameFromFile()
function KARDS.CardEditor.SaveSystem.GetCardNameFromFile(fileName)
    local info = KARDS.CardEditor.SaveSystem.GetCardInfo(fileName)
    return info and info.name or ""
end

--- 旧保存任意数据（用于 INE 默认变量等）
function KARDS.CardEditor.SaveSystem.SaveData(data, fileName)
    if not fileName or type(fileName) ~= "string" then return false end
    fileName = ensureExt(fileName)

    KARDS.CardEditor.SaveSystem.EnsureDirectories()

    local jsonString = FileOps.Encode(data)
    if not jsonString then
        print("[CardEditor] SaveData failed: JSON encode error")
        return false
    end

    local filePath = "card_editor/" .. fileName
    local success = FileOps.Write(filePath, jsonString)
    if not success then
        print("[CardEditor] SaveData failed: File write error")
        return false
    end

    print("[CardEditor] SaveData successful: " .. fileName)
    return true
end

--- 旧加载任意数据
function KARDS.CardEditor.SaveSystem.LoadData(fileName)
    if not fileName or type(fileName) ~= "string" then return nil end
    fileName = ensureExt(fileName)

    local filePath = "card_editor/" .. fileName
    if not FileOps.Exists(filePath) then
        print("[CardEditor] LoadData: File not found - " .. fileName)
        return nil
    end

    local content = FileOps.Read(filePath)
    if not content then
        print("[CardEditor] LoadData failed: File read error")
        return nil
    end

    local success, data = FileOps.Decode(content)
    if not success or not data then
        print("[CardEditor] LoadData failed: JSON decode error")
        return nil
    end

    print("[CardEditor] LoadData successful: " .. fileName)
    return data
end

--- 检查卡牌文件是否存在（使用 CARDS_DIR / HQ_DIR 路径）
function KARDS.CardEditor.SaveSystem.FileExists(fileName)
    fileName = ensureExt(fileName)
    if not fileName then return false end
    -- 优先检查 cards 子目录
    local filePath = FileOps.GetPath(CARDS_DIR, fileName)
    if FileOps.Exists(filePath) then return true end
    -- 检查总部 headquarters 子目录
    filePath = FileOps.GetPath(HQ_DIR, fileName)
    if FileOps.Exists(filePath) then return true end
    -- 回退检查根目录（兼容旧版本保存在 card_editor/ 下的文件）
    filePath = "card_editor/" .. fileName
    return FileOps.Exists(filePath)
end
