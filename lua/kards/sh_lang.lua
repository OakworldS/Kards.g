--[[
    Kards 多语言基础设施（sh_lang.lua，2026-10-17）

    职责：
      1. 语言判定：控制台变量 kards_language 非空时以其为准；否则跟随
         Garry's Mod 语言（gmod_language）：zh* → zh-CN，en* → en，其余回退 zh-CN。
      2. 文案查表：KARDS.Lang.T(key, ...) 取当前语言文本并按 string.format 填充参数；
         缺 key 时回退 zh-CN 文本，再缺则原样返回 key。
      3. 服务端按玩家语言本地化：客户端把判定结果经 KardsClientLanguage 同步给服务端，
         服务端用 KARDS.Lang.TFor(ply, key, ...) / KARDS.Lang.ReasonFor(ply, code) 下发。
      4. 引擎错误码映射：reason.* 命名空间存放操作失败原因；引擎层返回
         "code" 或 "code|参数1|参数2"，服务端经 ReasonFor 转成本地化句子。

    文本表：lua/kards/lang/zh_cn.lua、lua/kards/lang/en.lua（扁平点分 key）。
    加载：sh_card_editor_loader.lua LoadSharedFiles 首个 include（先于 sh_card_data.lua）。
]]

KARDS = KARDS or {}
KARDS.Lang = KARDS.Lang or {}

-- 文本表：[语言标识] = { [key] = 文本 }
KARDS.Lang.Translations = KARDS.Lang.Translations or {
    ["zh-CN"] = {},
    ["en"] = {},
}

-- 语言变化监听（各 UI 模块注册：清空按语言缓存的测宽结果）
KARDS.Lang.Listeners = KARDS.Lang.Listeners or {}

--- 注册文本表（语言文件调用）
-- @param lang string 语言标识（"zh-CN" / "en"）
-- @param tbl  table 扁平 key → 文本
function KARDS.Lang.Register(lang, tbl)
    local dst = KARDS.Lang.Translations[lang]
    if not dst then
        dst = {}
        KARDS.Lang.Translations[lang] = dst
    end
    for k, v in pairs(tbl or {}) do
        dst[k] = v
    end
end

--- 规范化语言标识（"en" / "zh-CN"）；无法识别返回 nil
function KARDS.Lang.Normalize(value)
    if not value or value == "" then return nil end
    local v = string.lower(value)
    if v == "en" or v == "english" then return "en" end
    if v == "zh" or v == "zh-cn" or v == "zh_cn" or v == "chinese" then return "zh-CN" end
    return nil
end

--- 判定本地语言（客户端 / 服务端自身语言）
function KARDS.Lang.Detect()
    local cv = GetConVar and GetConVar("kards_language")
    local override = cv and cv:GetString() or ""
    local normalized = KARDS.Lang.Normalize(override)
    if normalized then return normalized end
    local gmod = string.lower(GetConVarString("gmod_language") or "")
    if string.sub(gmod, 1, 2) == "zh" then return "zh-CN" end
    if string.sub(gmod, 1, 2) == "en" then return "en" end
    return "zh-CN" -- 非中英文环境回退原始语言（中文）
end

--- 当前本地语言（带缓存；语言变化回调会清空缓存）
function KARDS.Lang.GetLanguage()
    if not KARDS.Lang.CurrentLanguage then
        KARDS.Lang.CurrentLanguage = KARDS.Lang.Detect()
    end
    return KARDS.Lang.CurrentLanguage
end

--- 服务端取玩家语言：优先玩家 userinfo 的 kards_language，其次客户端同步值，最后回退本地
-- @param ply Player|nil
function KARDS.Lang.GetPlayerLanguage(ply)
    if IsValid(ply) and ply.GetInfo then
        local info = ply:GetInfo("kards_language")
        local normalized = KARDS.Lang.Normalize(info)
        if normalized then return normalized end
        if ply._kardsLang then return ply._kardsLang end
    end
    return KARDS.Lang.GetLanguage()
end

--- 取指定语言文本（缺 key 回退 zh-CN，再缺返回 nil）
function KARDS.Lang.Get(lang, key)
    local t = KARDS.Lang.Translations[lang]
    local v = t and t[key]
    if v ~= nil then return v end
    local zh = KARDS.Lang.Translations["zh-CN"]
    return zh and zh[key]
end

--- 按指定语言查表并格式化
-- @param lang string 语言标识
-- @param key  string 文案 key
-- @param ...  任意 string.format 参数
function KARDS.Lang.Lookup(lang, key, ...)
    local v = KARDS.Lang.Get(lang, key)
    if v == nil then return tostring(key) end
    if select("#", ...) > 0 then
        local ok, out = pcall(string.format, v, ...)
        if ok then return out end
    end
    return v
end

--- 本地语言文案（客户端 UI 统一入口）
function KARDS.Lang.T(key, ...)
    return KARDS.Lang.Lookup(KARDS.Lang.GetLanguage(), key, ...)
end

--- 服务端按玩家语言取文案
function KARDS.Lang.TFor(ply, key, ...)
    return KARDS.Lang.Lookup(KARDS.Lang.GetPlayerLanguage(ply), key, ...)
end

--- 本地语言下的操作失败原因（"code" / "code|参数" → reason.<code> 文案）
function KARDS.Lang.Reason(reason)
    return KARDS.Lang.ReasonLookup(KARDS.Lang.GetLanguage(), reason)
end

--- 服务端按玩家语言解析操作失败原因
function KARDS.Lang.ReasonFor(ply, reason)
    return KARDS.Lang.ReasonLookup(KARDS.Lang.GetPlayerLanguage(ply), reason)
end

--- 失败原因码解析核心：code 或 code|arg1|arg2；未登记的码原样返回
function KARDS.Lang.ReasonLookup(lang, reason)
    if type(reason) ~= "string" or reason == "" then return reason end
    local code, rest = reason:match("^([%w_]+)|(.*)$")
    if code then
        local key = "reason." .. code
        if KARDS.Lang.Get(lang, key) ~= nil then
            local args = {}
            for part in rest:gmatch("[^|]+") do args[#args + 1] = part end
            return KARDS.Lang.Lookup(lang, key, unpack(args))
        end
        return reason
    end
    if reason:match("^[%w_]+$") then
        local key = "reason." .. reason
        if KARDS.Lang.Get(lang, key) ~= nil then
            return KARDS.Lang.Lookup(lang, key)
        end
    end
    return reason
end

--- 注册语言变化监听
-- @param fn function 语言变化时调用（清空测宽缓存 / 重新格式化缓存文本）
function KARDS.Lang.OnLanguageChanged(fn)
    table.insert(KARDS.Lang.Listeners, fn)
end

--- 通知语言变化（清缓存 + 逐个监听回调）
local function NotifyLanguageChanged()
    KARDS.Lang.CurrentLanguage = nil
    for _, fn in ipairs(KARDS.Lang.Listeners) do
        local ok, err = pcall(fn)
        if not ok then
            print("[Kards] 语言变化回调失败: " .. tostring(err))
        end
    end
end

-- ====================================================================
-- 控制台变量与语言同步
-- ====================================================================
if CLIENT then
    -- userinfo = true：服务端可直接经 Player:GetInfo("kards_language") 读取
    CreateClientConVar("kards_language", "", true, true,
        "Kards 界面语言：zh-CN / en（留空跟随 Garry's Mod 语言）", 0, 0)
    -- 语言变化：清缓存 + 通知各模块 + 重新同步服务端
    cvars.AddChangeCallback("kards_language", function()
        NotifyLanguageChanged()
        net.Start("KardsClientLanguage")
            net.WriteString(KARDS.Lang.GetLanguage())
        net.SendToServer()
    end, "KardsLanguageChanged")
    cvars.AddChangeCallback("gmod_language", function()
        if KARDS.Lang.Normalize(GetConVar("kards_language") and GetConVar("kards_language"):GetString() or "") then
            return -- kards_language 覆盖中，游戏语言变化不影响
        end
        NotifyLanguageChanged()
        net.Start("KardsClientLanguage")
            net.WriteString(KARDS.Lang.GetLanguage())
        net.SendToServer()
    end, "KardsGmodLanguageChanged")
    -- 进服同步一次判定结果（服务端按此本地化下发文案）
    hook.Add("InitPostEntity", "KardsLanguageSync", function()
        net.Start("KardsClientLanguage")
            net.WriteString(KARDS.Lang.GetLanguage())
        net.SendToServer()
    end)
elseif SERVER then
    util.AddNetworkString("KardsClientLanguage")
    net.Receive("KardsClientLanguage", function(_, ply)
        if not IsValid(ply) then return end
        ply._kardsLang = KARDS.Lang.Normalize(net.ReadString()) or "zh-CN"
    end)
    -- 玩家首次生成时补同步（客户端 InitPostEntity 已发，此处兜底 userinfo 值）
    hook.Add("PlayerInitialSpawn", "KardsLanguageInit", function(ply)
        local normalized = KARDS.Lang.Normalize(ply:GetInfo("kards_language"))
        if normalized then ply._kardsLang = normalized end
    end)
end

-- 加载文本表（必须在 T/TFor 首次调用前完成）
include("kards/lang/zh_cn.lua")
include("kards/lang/en.lua")
