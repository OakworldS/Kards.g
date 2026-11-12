--[[
    节点解析系统：语义层（Node Parser: Semantics）

    自 sh_node_parser.lua 按职责拆分（re.md B-H3）：本文件承载
      - 设置变量（var_set）解析：操作集常量（SET_OPS 等）+ 变量定位/读写 + 各类型处理器
      - 判断变量关系（var_evaluate）解析：运算符 + 单行/组合条件评估
      - BaseSemantics 语义表（模板类型 → select 选项值 → 语义动作）
    执行器表（sh_node_acts_*.lua）加载后各自合并 handlers 进 BaseSemantics 对应条目，
    ExecuteBaseNode（sh_node_parser.lua）经 sem.handlers 分派（行为与原 if/elseif 链一致）。

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_node_parser.lua 之后，先于 acts 文件）
]]

KARDS = KARDS or {}
KARDS.NodeParser = KARDS.NodeParser or {}

-- ====================================================================
-- 操作集常量（与 cl_ine_var_op_nodes.lua L75-97 保持一致，供解析器独立判断）
-- ====================================================================
KARDS.NodeParser.SET_OPS = {
    n = { "设为", "增加", "减少" },
    b = { "设为", "反转" },
    t = {},  -- 文本无操作行（直接输入，见 HandleText）
    g = { "设为", "第", "最后一项" },
    e = { "花费", "行动花费", "攻击力", "防御力", "单位类型", "卡牌名称", "词条", "描述", "品质", "卡牌插图", "历史插图", "历史文本", "子类型" },
    f = { "改为" },
}
KARDS.NodeParser.SET_OBJ_OPS = {
    unit = { "花费", "行动花费", "攻击力", "防御力", "单位类型", "卡牌名称", "词条", "描述", "品质", "卡牌插图", "历史插图", "历史文本", "子类型" },
    cmd  = { "花费", "卡牌名称", "词条", "描述", "品质", "卡牌插图", "历史插图", "历史文本", "子类型" },
}
KARDS.NodeParser.SET_OBJ_EMPTY_OP = "设为"
-- 对象数值属性（值 = 数字或 "var:" 引用）
KARDS.NodeParser.SET_OBJ_NUM_PROPS = { ["花费"] = true, ["行动花费"] = true, ["攻击力"] = true, ["防御力"] = true }
-- 对象插图属性（值 = "../data/kards_images/<文件>"）
KARDS.NodeParser.SET_OBJ_IMG_PROPS = { ["卡牌插图"] = true, ["历史插图"] = true }
-- 对象文本槽属性（值 = "var:<名>" 引用 或 直接文本）
KARDS.NodeParser.SET_OBJ_TEXT_SLOT_PROPS = { ["卡牌名称"] = true, ["描述"] = true, ["历史文本"] = true }
-- 对象词条属性（值 = 逗号分隔词条 id）
KARDS.NodeParser.SET_OBJ_KEYWORD_PROPS = { ["词条"] = true }

-- ====================================================================
-- 卡牌专属固定变量（每张卡牌固定存在的专属全局变量）
-- ====================================================================
-- 数据层按用户自定义变量语义解析：ResolveTarget 可按显示名定位（fixed 兜底），
-- GetTarget/SetTarget 从发起卡牌实时读写（不落 CardVars/Battle 存储空间）。
-- key 为内部名（带 KARDS.User. 前缀，与用户变量同构）；unitOnly = true 的变量
-- 仅单位卡编辑时展示（编辑期 UI 判断），数据层运行时按卡牌实际类型取值。
KARDS.NodeParser.CARD_FIXED_VARS = {
    t = {
        { name = "名称",     key = "KARDS.User.名称" },
        { name = "效果描述", key = "KARDS.User.效果描述" },
        { name = "历史描述", key = "KARDS.User.历史描述" },
        { name = "词条组合", key = "KARDS.User.词条组合" },
        { name = "品质",     key = "KARDS.User.品质" },
    },
    e = {
        { name = "自身", key = "KARDS.User.自身" },
    },
    n = {
        { name = "卡牌花费", key = "KARDS.User.卡牌花费" },
        { name = "行动花费", key = "KARDS.User.行动花费", unitOnly = true },
        { name = "攻击",     key = "KARDS.User.攻击",     unitOnly = true },
        { name = "防御",     key = "KARDS.User.防御",     unitOnly = true },
    },
}

-- 定位卡牌专属固定变量定义（按显示名 + 类型匹配）
-- @param varType string 变量类型（n/b/t/g/e/f）
-- @param varName string 显示名
-- @return table|nil { name, key, unitOnly? }
function KARDS.NodeParser.FindCardFixedVar(varType, varName)
    local list = KARDS.NodeParser.CARD_FIXED_VARS and KARDS.NodeParser.CARD_FIXED_VARS[varType]
    if not list then return nil end
    for _, fv in ipairs(list) do
        if fv.name == varName then return fv end
    end
    return nil
end

-- 读取卡牌句柄携带的外观表（无则返回 nil）
local function GetCardApp(card)
    if card and card.cardAppearance and type(card.cardAppearance) == "table" then
        return card.cardAppearance
    end
    return nil
end

-- 读取卡牌专属固定变量当前值（数据层，从卡牌句柄实时读取）
-- @param card    table 卡牌句柄（发起卡）
-- @param varType string 变量类型
-- @param key     string 内部名（KARDS.User. 前缀）
-- @return any|nil 值（e 返回卡牌句柄本身）
function KARDS.NodeParser.GetFixedVarValue(card, varType, key)
    if not card then return nil end
    local app = GetCardApp(card)
    if varType == "e" then
        return card -- 自身：对象指向发起卡牌本身
    elseif varType == "n" then
        if key == "KARDS.User.卡牌花费" then
            return (card.GetCost and card:GetCost()) or (app and app.cost) or 0
        elseif key == "KARDS.User.行动花费" then
            return (card.GetActionCost and card:GetActionCost()) or (app and app.actionCost)
        elseif key == "KARDS.User.攻击" then
            return (card.GetStat and card:GetStat("attack")) or (app and app.attack) or 0
        elseif key == "KARDS.User.防御" then
            return (card.GetStat and card:GetStat("defense")) or (app and app.defense) or 0
        end
    elseif varType == "t" then
        if key == "KARDS.User.名称" then
            local n = app and app.name
            if (not n or n == "") and card.GetName then n = card:GetName() end
            return n or ""
        elseif key == "KARDS.User.效果描述" then
            return (app and app.specialEffect) or ""
        elseif key == "KARDS.User.历史描述" then
            return (app and app.historyText) or ""
        elseif key == "KARDS.User.词条组合" then
            -- 词条组合文本：优先外观词条表，兜底卡牌词条接口（与 sh_card_data.lua BuildKeywordsText 同源）
            if app and KARDS.CardEditor and KARDS.CardEditor.Data
               and KARDS.CardEditor.Data.BuildKeywordsText then
                return KARDS.CardEditor.Data.BuildKeywordsText(app.keywords, app.keywordValues, app.pincerValue)
            end
            if card.GetKeywords and KARDS.CardEditor and KARDS.CardEditor.Data
               and KARDS.CardEditor.Data.BuildKeywordsText then
                return KARDS.CardEditor.Data.BuildKeywordsText(card:GetKeywords())
            end
            return ""
        elseif key == "KARDS.User.品质" then
            return (card.GetQuality and card:GetQuality()) or (app and app.quality) or "normal"
        end
    end
    return nil
end

-- 词条集合快照（id → true）：用于判断一次「词条」写入是否新获得某词条
-- @param card table 卡牌句柄
-- @return table id → true
-- 说明：词条元素可为字符串 id，也可为 { id, ... } 表，统一取 kw[1] 作为键。
local function SnapshotKeywords(card)
    local set = {}
    if card and card.GetKeywords then
        for _, kw in ipairs(card:GetKeywords() or {}) do
            set[type(kw) == "table" and kw[1] or kw] = true
        end
    end
    return set
end

-- 收缴触发（readme 7.2.2 + 2026-10-15 用户规格）：「词条」写入使卡牌新获得 收缴/被收缴 时，
-- 立即使该单位阵亡并收缴进效果发起方手牌。收缴方 = 效果发起卡归属（缺省 = 目标自身归属）；
-- 收缴不限定目标归属（本方也可以收缴本方单位）。
-- @param ctx    table|nil 执行上下文（含 _srcCard）
-- @param card   table 目标卡牌句柄
-- @param before table 写入前的词条集合快照（SnapshotKeywords 结果）
-- @return nil 无返回值（触发的收缴由 KARDS.Battle:SimConfiscate 执行）
-- 说明：仅在本次新增 confiscate 或 confiscated 词条（写入前快照中不存在）时触发一次；
--       收缴方优先取 ctx._srcCard 归属，缺省退回目标自身归属。
local function MaybeTriggerConfiscate(ctx, card, before)
    if not card or not card.GetKeywords then return end
    if not (KARDS.Battle and KARDS.Battle.SimConfiscate) then return end
    before = before or {}
    local gained = false
    for _, kw in ipairs(card:GetKeywords() or {}) do
        local id = type(kw) == "table" and kw[1] or kw
        if (id == "confiscate" or id == "confiscated") and not before[id] then
            gained = true
            break
        end
    end
    if not gained then return end
    local src = ctx and ctx._srcCard
    local newOwner = (src and src.GetOwner and src:GetOwner())
        or (card.GetOwner and card:GetOwner())
    KARDS.Battle:SimConfiscate(card, newOwner)
end

--[[
    属性写入拦截（反制「属性变更」）

    编辑器属性写入前经统一操作钩子 OnBeforeOperation（opType = stat_change），
    反制卡可选择两种收尾：取消本次写入（args.intercepted）或改写写入数值（args.amount）。
    只挂在编辑器属性写入的两个入口（本函数数值字段与 HandleObjectEntry 数值属性分支），
    不放进 SetCardField，避免修复 / 伤害 / 词条写入被误判为属性变更，也避免递归拦截。

    @param ctx      table 执行上下文（需 tableID；_srcCard 用于解析发起方玩家）
    @param card     table 目标卡牌句柄
    @param field    string 字段名（attack / defense / cost / actionCost）
    @param modifier string 变更方式（set / increase / decrease）
    @param amount   number 写入或变动数值
    @return number 改写后的数值（amount 非数字或未注册钩子时原样返回）
    @return boolean 是否被取消
]]
local function InterceptStatWrite(ctx, card, field, modifier, amount)
    if type(amount) ~= "number" then return amount, false end
    local tableID = ctx and ctx.tableID
    if not tableID or not (KARDS.EngineHooks and KARDS.EngineHooks.TriggerOperation) then
        return amount, false
    end
    local src = ctx._srcCard
    local actor = (src and src.GetOwner and src:GetOwner())
        or (card and card.GetOwner and card:GetOwner())
    local args = KARDS.EngineHooks.TriggerOperation(tableID, "stat_change", {
        player = actor, card = card, field = field, modifier = modifier, amount = amount,
    })
    if args.intercepted then return amount, true end
    return tonumber(args.amount) or amount, false
end

-- 写入卡牌专属固定变量（数据层，写回发起卡牌）
-- @param value any 新值
-- @param ctx   table|nil 执行上下文（「词条组合」写入触发收缴时判定收缴方；缺省退回卡牌归属）
-- @return boolean 是否成功（品质/自身等无写入通道字段提示但不视为成功）
function KARDS.NodeParser.SetFixedVarValue(card, varType, key, value, ctx)
    if not card then return false end
    local app = GetCardApp(card)
    if varType == "n" then
        -- 属性变更反制（2026-11-05）：数值字段写入前经统计写入拦截，可取消或改写
        local function writeNumeric(field, modifier)
            local v, blocked = InterceptStatWrite(ctx, card, field, modifier, value)
            if blocked then return false end
            return KARDS.NodeParser.SetCardField(card, field, v, modifier)
        end
        if key == "KARDS.User.卡牌花费" then
            return writeNumeric("cost", "set")
        elseif key == "KARDS.User.行动花费" then
            return writeNumeric("actionCost", "set")
        elseif key == "KARDS.User.攻击" then
            return writeNumeric("attack", "set")
        elseif key == "KARDS.User.防御" then
            return writeNumeric("defense", "set")
        end
    elseif varType == "t" then
        if key == "KARDS.User.名称" then
            if app then app.name = tostring(value) return true end
        elseif key == "KARDS.User.效果描述" then
            if app then app.specialEffect = tostring(value) return true end
        elseif key == "KARDS.User.历史描述" then
            if app then app.historyText = tostring(value) return true end
        elseif key == "KARDS.User.词条组合" then
            -- 值 = 逗号分隔词条 id（对齐对象属性「词条」写入通道）
            local before = SnapshotKeywords(card)
            local ok = KARDS.NodeParser.SetCardField(card, "keywords", value)
            if ok then MaybeTriggerConfiscate(ctx, card, before) end
            return ok
        elseif key == "KARDS.User.品质" then
            print("[NodeParser] 提示: 卡牌专属固定变量「品质」无写入通道（外观字段，运行时只读）")
            return false
        end
    elseif varType == "e" then
        print("[NodeParser] 提示: 卡牌专属固定变量「自身」不可赋值（对象指向发起卡牌本身）")
        return false
    end
    print("[NodeParser] 提示: 卡牌专属固定变量「" .. tostring(key) .. "」无写入通道（卡牌句柄无对应字段）")
    return false
end

-- ====================================================================
-- 内部辅助：变量定位
-- ====================================================================

-- 按路径逐层取变量库值（"Battle.Turn" / "Special.Deploy.FriendlyHandCount"）
-- @param T    table 变量库（KARDS.VarLib.Tables[tableID]）
-- @param path string 变量路径
-- @return any 变量值（不存在返回 nil）
local function GetByPath(T, path)
    local cur = T
    for seg in string.gmatch(path or "", "[^.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[seg]
    end
    return cur
end

-- 按路径逐层设置变量库值（不存在的中层自动建表）
-- @return boolean 是否成功（T 或 path 非法返回 false）
local function SetByPath(T, path, value)
    if type(T) ~= "table" or not path or path == "" then return false end
    local segs = {}
    for seg in string.gmatch(path, "[^.]+") do table.insert(segs, seg) end
    local cur = T
    for i = 1, #segs - 1 do
        if type(cur[segs[i]]) ~= "table" then cur[segs[i]] = {} end
        cur = cur[segs[i]]
    end
    cur[segs[#segs]] = value
    return true
end

-- 构建预定义变量「显示名 → 路径」反向索引（源自 VarLib.Translations）
-- @return table 显示名 → 路径（首个匹配）
local function BuildDisplayIndex()
    local index = {}
    local translations = KARDS.VarLib.Translations[KARDS.VarLib.CurrentLanguage] or {}
    for path, display in pairs(translations) do
        if type(display) == "string" and not index[display] then
            index[display] = path
        end
    end
    return index
end

-- 从编辑器变量定义中按显示名定位变量
-- @param variables table 编辑器变量定义（internalName 带 KARDS.User. 前缀）
-- @param varType   string 变量类型（n/b/t/g/e/f）
-- @param varName   string 显示名（name 优先，internalName 兜底）
-- @return table|nil { internalName, scope }（scope 缺省 "global"）
local function FindUserVar(variables, varType, varName)
    if not variables or not variables[varType] then return nil end
    for _, v in ipairs(variables[varType]) do
        local display = (v.name ~= nil and v.name ~= "") and v.name or v.internalName
        if display == varName then
            return { internalName = v.internalName, scope = v.scope, initialValue = v.initialValue }
        end
    end
    return nil
end

-- ====================================================================
-- 解析器入口
-- ====================================================================

-- 补全执行上下文（幂等）：tableID / _T 变量库 / _displayIndex 反向索引
-- 供 ParseSetVariable 与 ParseSetEntry 独立调用（直接解析单条时无需先走入口）
-- @param ctx table|nil 执行上下文
-- @return table 补全后的执行上下文
local function EnsureCtx(ctx)
    ctx = ctx or {}
    if not ctx._T then
        local tableID = ctx.tableID
        if not tableID then
            local battle = ctx.battle or KARDS.Battle
            tableID = battle and battle.TableID or "1"
        end
        ctx.tableID = tableID
        ctx._T = KARDS.VarLib.GetOrCreate(tableID)
        ctx._displayIndex = BuildDisplayIndex()
    end
    return ctx
end
-- 跨文件共享（GLua 无跨文件 local）：hooks / 入口等其它文件经 KARDS.NodeParser.EnsureCtx 访问
KARDS.NodeParser.EnsureCtx = EnsureCtx

--[[
    解析「设置变量」节点：遍历 _setEntries 逐条执行设置操作。

    @param ctx table 执行上下文（由调用方/战斗系统提供）：
        tableID          string|nil 牌桌唯一标识符（缺省 KARDS.Battle.TableID）
        initiatorCard    table|nil  发起卡牌句柄（TickLog 记录用；缺省用目标对象或首条受影响卡）
        variables        table|nil  卡牌效果数据中的编辑器变量定义（带 KARDS.User. 前缀）
        dataConnections  table|nil  数据线数组（含 variableName）
        battle           table|nil  战斗系统实例（缺省 KARDS.Battle）
    @param node  table 设置变量节点（含 node.data._setEntries）
    @return boolean 是否至少成功执行一条设置
]]
function KARDS.NodeParser.ParseSetVariable(ctx, node)
    ctx = EnsureCtx(ctx)
    local entries = node and node.data and node.data._setEntries
    if not entries or #entries == 0 then
        print("[NodeParser] ParseSetVariable: 节点无设置条目（_setEntries 为空）")
        return false
    end

    local successCount = 0

    for _, entry in ipairs(entries) do
        local ok = KARDS.NodeParser.ParseSetEntry(ctx, entry)
        if ok then successCount = successCount + 1 end
    end

    return successCount > 0
end

--[[
    解析单条设置行（_setEntries[i]）。

    @param ctx   table 执行上下文（缺省自动补全 tableID/_T/_displayIndex，见 EnsureCtx）
    @param entry table 设置行条目
    @return boolean 是否成功执行
]]
function KARDS.NodeParser.ParseSetEntry(ctx, entry)
    ctx = EnsureCtx(ctx)
    if not entry then return false end
    local varType = entry.varType or "n"
    local ops = KARDS.NodeParser.SET_OPS[varType]
    if not ops then
        print("[NodeParser] 错误: 非法目标变量类型: " .. tostring(varType))
        return false
    end
    local opLabel = ops[entry.opIdx] or ops[1]

    -- 目标变量名：数据线来源时用数据线携带的 variableName
    local varName = entry.varName or ""
    if entry.source == "input" and entry.connId and ctx.dataConnections then
        for _, dc in ipairs(ctx.dataConnections) do
            if dc.id == entry.connId and dc.variableName and dc.variableName ~= "" then
                varName = dc.variableName
                break
            end
        end
    end
    if varName == "" then
        print("[NodeParser] 错误: 设置行缺少目标变量名（varName 为空）")
        return false
    end

    -- 分派：对象类型走对象属性处理，其余按类型
    if varType == "e" then
        return KARDS.NodeParser.HandleObjectEntry(ctx, entry, varName)
    end

    -- 定位目标变量（预定义翻译表反查 / 用户自定义变量）
    local target = KARDS.NodeParser.ResolveTarget(ctx, varType, varName)

    if varType == "n" then
        return KARDS.NodeParser.HandleNumber(ctx, target, entry, opLabel)
    elseif varType == "b" then
        return KARDS.NodeParser.HandleBool(ctx, target, entry, opLabel)
    elseif varType == "t" then
        return KARDS.NodeParser.HandleText(ctx, target, entry)
    elseif varType == "g" then
        return KARDS.NodeParser.HandleArray(ctx, target, entry, opLabel)
    elseif varType == "f" then
        print("[NodeParser] 提示: 函数类型（f）「改为 #」为占位操作（函数子编辑器未接入），跳过: " .. varName)
        return false
    end
    return false
end

--[[
    定位目标变量：预定义系统变量（翻译表反查）或用户自定义变量。

    用户自定义变量作用域（scope 字段）：
      - "global"（全局）：每张卡牌实例隔离（存 T.CardVars[卡牌ID][internalName]），
        初始值取编辑器变量定义的 initialValue，不受其他全等卡牌设置影响
      - "longterm"（长期）：全等卡牌共用（存 T.Battle[internalName]），战斗结束重置
    两种作用域战斗结束后变量都会重置（Battle 重建 / CardVars 清空，见 sh_varlib.lua）。

    @param ctx     table 执行上下文
    @param varType string 变量类型
    @param varName string 变量显示名
    @return table|nil { section, key, path, cardKey?, varName?, isUser? }
            （section = 变量库区域；key = 存储键；path = 完整路径）
]]
function KARDS.NodeParser.ResolveTarget(ctx, varType, varName)
    -- 1. 预定义系统变量：显示名 → 路径（如 "回合数" → "Battle.Turn"）
    local path = ctx._displayIndex and ctx._displayIndex[varName]
    if path then
        local dotPos = path:find(".", 1, true)
        if dotPos then
            -- 路径含点：section = 区域前缀，key = 去前缀后的存储键（与 Get/SetByPath 逐层路径一致）
            return { section = path:sub(1, dotPos - 1), key = path:sub(dotPos + 1), path = path }
        end
        return { section = "Battle", key = path, path = path }
    end
    -- 2. 用户自定义变量：编辑器变量定义中按显示名匹配
    local uv = FindUserVar(ctx.variables, varType, varName)
    if uv and uv.internalName and uv.internalName ~= "" then
        if uv.scope == "longterm" then
            -- 长期变量：全等卡牌共用，存 Battle 区（战斗结束随 Battle 重建重置）
            return { section = "Battle", key = uv.internalName, path = uv.internalName, varName = varName, isUser = true }
        end
        -- 全局变量：按卡牌实例隔离（T.CardVars[卡牌ID]），初始值 = initialValue
        local card = ctx.initiatorCard
        local cardKey = card and (card.GetID and card:GetID() or tostring(card)) or "?"
        if not ctx.initiatorCard then
            print("[NodeParser] 警告: 无发起者卡牌，全局变量「" .. varName .. "」将存储于共享键 '?'（可能跨卡牌串扰）")
        end
        return { section = "CardVars", key = uv.internalName, path = uv.internalName,
                 cardKey = cardKey, varName = varName, isUser = true, varType = varType }
    end
    -- 3. 卡牌专属固定变量：显示名匹配（每张卡牌固有，按用户自定义变量语义解析，
    --    值不落 CardVars/Battle 存储，GetTarget/SetTarget 从发起卡牌实时读写）
    local fv = KARDS.NodeParser.FindCardFixedVar(varType, varName)
    if fv then
        return { fixed = true, varType = varType, varName = varName, key = fv.key }
    end
    print("[NodeParser] 警告: 无法定位目标变量「" .. varName .. "」（非预定义变量且变量定义中无匹配）")
    return nil
end

-- 读取目标变量值
-- 全局（CardVars）变量未设置过时返回编辑器变量定义的 initialValue（每张卡牌调用时均为初始值）
-- @return any|nil 变量值（目标不存在返回 nil）
function KARDS.NodeParser.GetTarget(ctx, target)
    if not target then return nil end
    ctx = EnsureCtx(ctx)
    -- 卡牌专属固定变量：从发起卡牌实时读取（不落存储）
    if target.fixed then
        return KARDS.NodeParser.GetFixedVarValue(ctx.initiatorCard, target.varType, target.key)
    end
    local T = ctx._T
    if target.section == "CardVars" then
        local cardVars = T.CardVars or {}
        local cardT = cardVars[target.cardKey]
        if cardT and cardT[target.key] ~= nil then return cardT[target.key] end
        -- 未设置过：返回全局变量初始值（编辑器变量定义 initialValue）
        local uv = FindUserVar(ctx.variables, target.varType, target.varName)
        return uv and uv.initialValue or nil
    end
    local section = T[target.section]
    if section == nil then return nil end
    if target.isUser then
        -- 用户自定义变量：internalName 含点但必须作为单键（如 "KARDS.User.BOARD"）
        return section[target.key]
    end
    -- 预定义变量：路径逐层解（key 为去区域前缀后的剩余路径，如 "Battle.Turn" → "Turn"）
    return GetByPath(section, target.key)
end

-- 写入目标变量（记录 stat_change 刻）
-- @param value  any 新值
-- @param change string|nil 变更文本（缺省 "=值"；增加/减少调用方传入 "+N"/"-N"）
-- @return boolean 是否成功
function KARDS.NodeParser.SetTarget(ctx, target, value, change)
    if not target then return false end
    ctx = EnsureCtx(ctx)
    -- 卡牌专属固定变量：写回发起卡牌（不落存储）
    if target.fixed then
        -- 飘字旧值快照（2026-08-14）：固定变量 n 型（攻击/防御/行动花费）写入前的旧值
        local fxOld
        if target.varType == "n" and ctx.initiatorCard then
            local fk = target.key
            if fk == "KARDS.User.攻击" then fxOld = ctx.initiatorCard:GetStat("attack") or 0
            elseif fk == "KARDS.User.防御" then fxOld = ctx.initiatorCard:GetStat("defense") or 0
            elseif fk == "KARDS.User.行动花费" then fxOld = ctx.initiatorCard._actionCost or 0 end
        end
        local ok = KARDS.NodeParser.SetFixedVarValue(ctx.initiatorCard, target.varType, target.key, value, ctx)
        if ok then
            KARDS.NodeParser.PushStatChange(ctx, ctx.initiatorCard, change or ("=" .. tostring(value)))
            -- 飘字（2026-08-14）：固定变量 n 型（攻击/防御/行动花费）设为 → 攻防白色、
            -- 行动花费按变动符号（增红/减绿）
            if fxOld ~= nil then
                local field = (target.key == "KARDS.User.攻击") and "attack"
                    or (target.key == "KARDS.User.防御") and "defense"
                    or (target.key == "KARDS.User.行动花费") and "actionCost"
                    or nil
                if field then
                    local new = (field == "actionCost") and (ctx.initiatorCard._actionCost or 0)
                        or (ctx.initiatorCard:GetStat(field) or 0)
                    KARDS.Battle:NotifyStatFXByTable(ctx.tableID, ctx.initiatorCard, field, new - fxOld, "set", "node")
                end
            end
        end
        return ok
    end
    local T = ctx._T
    if target.section == "CardVars" then
        T.CardVars = T.CardVars or {}
        T.CardVars[target.cardKey] = T.CardVars[target.cardKey] or {}
        T.CardVars[target.cardKey][target.key] = value
    else
        if not T[target.section] then return false end
        if target.isUser then
            -- 用户自定义变量：单键存储（internalName 含点但不可拆分，如 "KARDS.User.BOARD"）
            T[target.section][target.key] = value
        else
            -- 系统事实变量（Battle.* / Special.*，如「友方有老兵单位」Special.Veteran.HasFriendlyUnit）：
            -- 写入只在本回合内生效。写前快照覆盖前的值登记一回合覆盖，回合边界
            -- （SimEndTurn）由 VarLib.ClearFactOverrides 还原为事实（2026-10-04 用户规格）
            if KARDS.VarLib and KARDS.VarLib.SetFactOverride
                and KARDS.VarLib.IsFactPath and KARDS.VarLib.IsFactPath(target.path) then
                KARDS.VarLib.SetFactOverride(ctx.tableID, target.path,
                    KARDS.NodeParser.GetTarget(ctx, target))
            end
            -- 预定义变量：按 key（去区域前缀后的剩余路径）逐层写入
            SetByPath(T[target.section], target.key, value)
        end
    end
    KARDS.NodeParser.PushStatChange(ctx, nil, change or ("=" .. tostring(value)))
    return true
end

-- 目标变量增减（记录 stat_change 刻，change 编码 "+N"/"-N"，对齐战斗系统规划）
-- @param op string "increase" / "decrease"
function KARDS.NodeParser.ChangeTarget(ctx, target, op, amount)
    if not target then return false end
    ctx = EnsureCtx(ctx)
    local cur = KARDS.NodeParser.GetTarget(ctx, target)
    if type(cur) ~= "number" then cur = 0 end
    local newVal = (op == "increase") and (cur + amount) or (cur - amount)
    local change = (op == "increase") and ("+" .. tostring(amount)) or ("-" .. tostring(amount))
    KARDS.NodeParser.SetTarget(ctx, target, newVal, change)
    return true
end

-- 记录 stat_change 刻（对齐战斗系统规划：change 编码 "+N"/"-N"/"=N"）
-- @param affectedCard table|nil 受影响卡牌（缺省用 ctx.initiatorCard）
-- @param change       string 变更文本（"+N"/"-N"/"=N"）
function KARDS.NodeParser.PushStatChange(ctx, affectedCard, change)
    ctx = EnsureCtx(ctx)
    local card = affectedCard or ctx.initiatorCard
    if not card then
        print("[NodeParser] 警告: 无发起者卡牌，跳过 stat_change 刻记录（change=" .. tostring(change) .. "）")
        return
    end
    -- 非数值变更（布尔/文本/数组等）无法编码为 +N/-N/=N，跳过刻记录（对齐规划 stat_change 数值语义）
    if not change or not change:match("^[+-=]%d+$") then
        print("[NodeParser] 提示: 跳过 stat_change 刻（非数值 change: " .. tostring(change) .. "）")
        return
    end
    KARDS.TickLog:Push(ctx.tableID, card, { "stat_change" },
        { { card, { "stat_change" }, change } })
end

-- ====================================================================
-- 数字变量（n）
-- ====================================================================

-- 解析值：数字字面量 或 "var:<显示名>" 引用（读取被引用变量当前值）
function KARDS.NodeParser.ResolveNumberValue(ctx, value)
    if type(value) == "number" then return value end
    if type(value) == "string" then
        local refName = value:match("^var:(.+)$")
        if refName then
            local target = KARDS.NodeParser.ResolveTarget(ctx, "n", refName)
            local v = target and KARDS.NodeParser.GetTarget(ctx, target)
            if v == nil then
                -- 兜底：refName 为变量库路径（如 "Battle.FriendlyCommandPoints"，
                -- 当 GetDisplayName 无翻译返回路径时，显示名索引无法命中，改为逐层取路径值，2026-10-04）
                ctx = EnsureCtx(ctx)
                local byPath = GetByPath(ctx._T, refName)
                if type(byPath) == "number" then v = byPath end
            end
            if type(v) ~= "number" then
                print("[NodeParser] 警告: 数字引用「" .. refName .. "」无数字值（当前: " .. tostring(v) .. "），按 0 处理")
                return 0
            end
            return v
        end
        local n = tonumber(value)
        if n ~= nil then return n end
    end
    print("[NodeParser] 警告: 非法数字值: " .. tostring(value) .. "，按 0 处理")
    return 0
end

function KARDS.NodeParser.HandleNumber(ctx, target, entry, opLabel)
    if not target then return false end
    local amount = KARDS.NodeParser.ResolveNumberValue(ctx, entry.value)
    if opLabel == "增加" then
        KARDS.NodeParser.ChangeTarget(ctx, target, "increase", amount)
    elseif opLabel == "减少" then
        KARDS.NodeParser.ChangeTarget(ctx, target, "decrease", amount)
    else -- 设为
        KARDS.NodeParser.SetTarget(ctx, target, amount)
    end
    return true
end

-- ====================================================================
-- 布尔变量（b）
-- ====================================================================

function KARDS.NodeParser.HandleBool(ctx, target, entry, opLabel)
    if not target then return false end
    if opLabel == "反转" then
        local cur = KARDS.NodeParser.GetTarget(ctx, target)
        local newVal = not (cur == true)
        KARDS.NodeParser.SetTarget(ctx, target, newVal)
    else -- 设为
        local v
        if type(entry.value) == "string" and entry.value:match("^var:") then
            -- 引用另一布尔变量（2026-10-04：跨回合轮转「上回合 = 本回合」）
            local refName = entry.value:match("^var:(.+)$")
            local src = KARDS.NodeParser.ResolveTarget(ctx, "b", refName)
            v = (src and KARDS.NodeParser.GetTarget(ctx, src) == true) or false
        else
            v = (entry.value == "true") or (entry.value == true)
        end
        KARDS.NodeParser.SetTarget(ctx, target, v)
    end
    return true
end

-- ====================================================================
-- 文本变量（t）
-- ====================================================================

function KARDS.NodeParser.HandleText(ctx, target, entry)
    if not target then return false end
    KARDS.NodeParser.SetTarget(ctx, target, tostring(entry.value or ""))
    return true
end

-- ====================================================================
-- 数组变量（g）
-- ====================================================================

-- 解析数组项值（按项类型 itemType）
-- @return any 数组项值（e 类型返回对象卡牌句柄或 nil）
function KARDS.NodeParser.ResolveItemValue(ctx, itemType, entry)
    if itemType == "n" then
        return KARDS.NodeParser.ResolveNumberValue(ctx, entry.value)
    elseif itemType == "b" then
        return (entry.value == "true") or (entry.value == true)
    elseif itemType == "t" then
        return tostring(entry.value or "")
    elseif itemType == "e" then
        -- 项为对象：entry.value 是对象变量显示名 → 解析卡牌句柄
        return KARDS.NodeParser.ResolveObject(ctx, tostring(entry.value or ""))
    elseif itemType == "g" then
        -- 项为数组：entry.value 是数组变量显示名 → 拷贝其值
        local src = KARDS.NodeParser.ResolveTarget(ctx, "g", tostring(entry.value or ""))
        local v = src and KARDS.NodeParser.GetTarget(ctx, src)
        return (type(v) == "table") and v or {}
    elseif itemType == "f" then
        print("[NodeParser] 提示: 数组项函数类型（f）为占位，项值置 nil")
        return nil
    end
    return entry.value
end

function KARDS.NodeParser.HandleArray(ctx, target, entry, opLabel)
    if not target then return false end
    -- 数组赋值前确保目标存在
    local arr = KARDS.NodeParser.GetTarget(ctx, target)
    if type(arr) ~= "table" then arr = {} end

    if opLabel == "设为" then
        -- 数组整体复制：value = 源数组变量显示名
        local src = KARDS.NodeParser.ResolveTarget(ctx, "g", tostring(entry.value or ""))
        local srcVal = src and KARDS.NodeParser.GetTarget(ctx, src)
        if type(srcVal) ~= "table" then
            print("[NodeParser] 警告: 数组「设为」源「" .. tostring(entry.value) .. "」不是数组，按空数组处理")
            srcVal = {}
        end
        local copy = {}
        for i, item in ipairs(srcVal) do copy[i] = item end
        KARDS.NodeParser.SetTarget(ctx, target, copy)
        return true
    end

    -- 第 / 最后一项
    local index
    if opLabel == "最后一项" then
        index = #arr
    else -- 第（索引来自编辑器 sv_gidx_ 数字槽，镜像于 entry.itemIndex）
        index = math.floor(tonumber(entry.itemIndex) or 0)
    end
    if index < 1 then
        print("[NodeParser] 警告: 数组「" .. tostring(target.key) .. "」项索引非法（" .. tostring(index) .. "），跳过")
        return false
    end

    if entry.subOpIdx == 2 then
        -- 子操作「类型」：数组项 = { itemType, itemName } 结构化标记（编辑器数组项建模）
        arr[index] = {
            _varType = entry.itemType or "n",
            _varName = entry.itemName or "",
        }
    else
        -- 子操作「值」：数组项 = 按 itemType 解析的值
        arr[index] = KARDS.NodeParser.ResolveItemValue(ctx, entry.itemType or "n", entry)
    end
    KARDS.NodeParser.SetTarget(ctx, target, arr)
    return true
end

-- ====================================================================
-- 对象变量（e）
-- ====================================================================

-- 解析对象变量 → 对象值（卡牌句柄或对象组）
-- 顺序：数据线注入的对象（对象槽选「数据线传入的对象变量」时，槽值 = 线输出端口名，
--      经 ResolveEWires 写入 ctx._wireVars[当前节点][变量名]；wantSingle=false 整组返回，
--      wantSingle=true 取对象组首项）
--      → 预定义对象变量（翻译表反查，如「友方可选目标」→ Battle.FriendlyTarget）
--      → 用户自定义 e 变量（longterm → Battle[internalName]；global → CardVars[卡牌ID][internalName]）
--      → 卡牌专属固定对象变量（自身）
-- @param varName    string 对象变量显示名
-- @param wantSingle boolean 数据线分支是否取对象组首项（单个对象语义；false 返回整组）
-- @return table|nil 卡牌句柄（或对象组表）
local function ResolveObjectValue(ctx, varName, wantSingle)
    if not varName or varName == "" then return nil end
    ctx = EnsureCtx(ctx)
    -- 数据线连接的对象：本节点 e 线解析结果（ResolveEWires 已注入 ctx._wireVars），
    -- wantSingle=true 对象组取首项（如 var_set 属性修改需单个句柄）；
    -- wantSingle=false 整组返回（对象槽逐张语义，2026-08-14 与数据线统一）
    local nodeWires = ctx._wireVars and ctx._currentNodeId and ctx._wireVars[ctx._currentNodeId]
    if nodeWires then
        local wv = nodeWires[varName]
        if wv ~= nil then
            if wantSingle and type(wv) == "table" then return wv[1] end
            return wv
        end
    end
    local path = ctx._displayIndex and ctx._displayIndex[varName]
    if path then
        return GetByPath(ctx._T, path)
    end
    local uv = FindUserVar(ctx.variables, "e", varName)
    if uv and uv.internalName and uv.internalName ~= "" then
        local T = ctx._T
        if uv.scope == "longterm" then
            if T.Battle then return T.Battle[uv.internalName] end
        else
            -- 全局对象变量：按卡牌实例隔离
            local card = ctx.initiatorCard
            local cardKey = card and (card.GetID and card:GetID() or tostring(card)) or "?"
            local cardVars = T.CardVars or {}
            local cardT = cardVars[cardKey]
            if cardT then return cardT[uv.internalName] end
            return nil
        end
    end
    -- 卡牌专属固定对象变量「自身」：返回发起卡牌句柄
    if KARDS.NodeParser.FindCardFixedVar("e", varName) then
        return ctx.initiatorCard
    end
    print("[NodeParser] 警告: 无法解析对象变量「" .. varName .. "」为卡牌句柄")
    return nil
end

-- 解析对象变量名 → 卡牌句柄（单个对象语义：数据线对象组取首项）
-- @param varName string 对象变量显示名
-- @return table|nil 卡牌句柄
function KARDS.NodeParser.ResolveObject(ctx, varName)
    return ResolveObjectValue(ctx, varName, true)
end

-- 解析对象变量名 → 对象值（数据线分支返回整组而非首项；对象槽逐张语义用）
-- @param varName string 对象变量显示名
-- @return table|nil 卡牌句柄（或对象组表）
function KARDS.NodeParser.ResolveObjectGroup(ctx, varName)
    return ResolveObjectValue(ctx, varName, false)
end

-- 对象值 → 正序对象列表（2026-08-14 对象槽/数据线统一逐张语义）
-- 单个卡牌句柄（Mock 句柄为纯字段表，v[1] 恒 nil）→ {句柄}；
-- 对象组表（元素为卡牌句柄）→ 原样返回；空表/非表 → {}
-- @param v any 对象槽直写值 / 对象变量解析结果
-- @return table 正序对象列表（可为空表）
function KARDS.NodeParser.NormalizeObjectList(v)
    if type(v) ~= "table" then return {} end
    if next(v) == nil then return {} end -- 空对象组
    if v[1] ~= nil then return v end     -- 对象组（元素为卡牌句柄）
    return { v }                         -- 单个卡牌句柄
end

-- 读取对象槽并解析为对象列表（正序逐张语义，2026-08-14 与数据线统一）
-- 优先级：直写卡牌句柄/对象组（测试与数据线直写）→ 字符串（数据线变量名 / 用户对象变量 /
-- 预定义对象变量名，经 ResolveObjectGroup 解析）→ 其余（索引等）返回空表
-- @param ctx    table 执行上下文
-- @param node   table 节点实例
-- @param compId string 对象槽组件 ID
-- @return table 正序对象列表（可为空表）
function KARDS.NodeParser.ResolveObjectSlot(ctx, node, compId)
    local v = KARDS.NodeParser.ReadSlot(node, compId)
    if type(v) == "table" then
        return KARDS.NodeParser.NormalizeObjectList(v)
    end
    if type(v) == "string" and v ~= "" then
        return KARDS.NodeParser.NormalizeObjectList(KARDS.NodeParser.ResolveObjectGroup(ctx, v))
    end
    return {}
end

-- 卡牌对象字段写入（骨架 MockCard 内部字段；公开接口见 sh_card_interface.lua）
-- 支持：attack/defense（ApplyChange，modifier 缺省 set）/ cost / actionCost / unitType / keywords
-- 其余外观字段（名称/描述/品质/插图/历史/子类型）卡牌句柄通常不具备 → 记录日志
-- @param field    string 字段名
-- @param value    any 值
-- @param modifier string|nil 变更方式（"set"/"increase"/"decrease"，仅 attack/defense 生效，缺省 "set"）
-- @return boolean 是否成功
function KARDS.NodeParser.SetCardField(card, field, value, modifier)
    if not card then return false end
    modifier = modifier or "set"
    if field == "attack" or field == "defense" then
        if card.ApplyChange then
            card:ApplyChange(field, modifier, value)
            return true
        end
    elseif field == "cost" then
        -- kards 数值上限 99（2026-08-13）：数据层统一上限，不防负值
        if card._cost ~= nil then card._cost = math.min(99, value) return true end
    elseif field == "actionCost" then
        if card._actionCost ~= nil then card._actionCost = math.min(99, value) return true end
    elseif field == "unitType" then
        if card._stats then
            local ut = tostring(value or "")
            if ut == "" then
                card._stats.unitType = nil
            elseif KARDS.CardInterface.UnitTypes[ut] then
                card._stats.unitType = ut
            else
                print("[NodeParser] 警告: 非法单位类型「" .. ut .. "」（readme 7.3），忽略")
                return false
            end
            return true
        end
    elseif field == "keywords" then
        if card._keywords then
            -- 词条值：逗号分隔词条 id；带数值词条保留 {id, x}（值无数值时按纯 id 处理）
            local newKw = {}
            for part in string.gmatch(tostring(value or ""), "[^,，]+") do
                local id = part:gsub("^%s+", ""):gsub("%s+$", "")
                if id ~= "" then
                    if KARDS.CardInterface.Keywords[id] or KARDS.CardInterface.IsHiddenKeyword(id) then
                        table.insert(newKw, id)
                    else
                        print("[NodeParser] 警告: 非法词条「" .. id .. "」（已忽略）")
                    end
                end
            end
            -- 战斗机无法具有烟幕（readme 7.3）
            if card:GetUnitType() == "fighter" then
                for i = #newKw, 1, -1 do
                    if newKw[i] == "smoke" then table.remove(newKw, i) end
                end
            end
            card._keywords = newKw
            return true
        end
    end
    -- 未实现字段：卡牌句柄一般无外观字段，提示但不视为失败（骨架阶段）
    print("[NodeParser] 提示: 卡牌句柄无字段「" .. tostring(field) .. "」的写入通道（骨架卡牌接口未实现，见 sh_card_interface.lua）")
    return false
end

-- 对象条目处理（按 objMode 与操作标签分派）
function KARDS.NodeParser.HandleObjectEntry(ctx, entry, varName)
    local objMode = entry.objMode or "unit"

    -- 空对象：固定「设为」—— 将目标空对象变量赋值为 value 解析出的卡牌句柄
    if objMode == "empty" then
        local target = KARDS.NodeParser.ResolveTarget(ctx, "e", varName)
        if not target then return false end
        local card = KARDS.NodeParser.ResolveObject(ctx, tostring(entry.value or ""))
        KARDS.NodeParser.SetTarget(ctx, target, card)
        return true
    end

    -- 单位 / 指令反制：按操作标签取属性
    local ops = KARDS.NodeParser.SET_OBJ_OPS[objMode] or KARDS.NodeParser.SET_OBJ_OPS.unit
    local opLabel = ops[entry.opIdx] or ops[1]

    -- 目标对象卡牌句柄
    local card = KARDS.NodeParser.ResolveObject(ctx, varName)
    if not card then
        print("[NodeParser] 警告: 对象「" .. varName .. "」解析为空（对象变量未指向任何卡牌），跳过属性「" .. opLabel .. "」")
        return false
    end

    -- 数值属性（花费/行动花费/攻击力/防御力）：{设为、增加、减少}（entry.objOpIdx，缺省设为）
    if KARDS.NodeParser.SET_OBJ_NUM_PROPS[opLabel] then
        local amount = KARDS.NodeParser.ResolveNumberValue(ctx, entry.value)
        local field = (opLabel == "花费") and "cost"
            or (opLabel == "行动花费") and "actionCost"
            or (opLabel == "攻击力") and "attack"
            or "defense"
        local objOp = entry.objOpIdx or 1
        -- 攻击/防御：卡牌接口 ApplyChange 原生支持 set/increase/decrease
        local modifier = (objOp == 2) and "increase" or (objOp == 3) and "decrease" or "set"
        -- 属性变更反制（2026-11-05）：写入前经 stat_change 钩子，可取消或改写写入数值
        local blocked
        amount, blocked = InterceptStatWrite(ctx, card, field, modifier, amount)
        if blocked then return false end
        local ok
        local change
        if field == "attack" or field == "defense" then
            local old = card:GetStat(field) or 0
            ok = KARDS.NodeParser.SetCardField(card, field, amount, modifier)
            -- 飘字（2026-08-14）：对象数值属性（攻击/防御）→ 设为/减少白色、增加绿色
            if ok then
                KARDS.Battle:NotifyStatFXByTable(ctx.tableID, card, field, (card:GetStat(field) or 0) - old, modifier, "node")
            end
        else
            -- 花费/行动花费：卡牌接口无 setter，直接字段增减（set 时 amount 原样）
            if objOp == 2 or objOp == 3 then
                local cur = (field == "cost") and card._cost or card._actionCost
                if type(cur) ~= "number" then cur = 0 end
                amount = (objOp == 2) and (cur + amount) or (cur - amount)
            end
            local oldCost = (field == "actionCost") and card._actionCost or nil
            ok = KARDS.NodeParser.SetCardField(card, field, amount)
            -- 飘字（2026-08-14）：对象数值属性（行动花费）→ 增红/减绿（显示带符号变动值）
            if ok and field == "actionCost" and oldCost ~= nil then
                KARDS.Battle:NotifyStatFXByTable(ctx.tableID, card, "actionCost", card._actionCost - oldCost,
                    (objOp == 2) and "increase" or (objOp == 3) and "decrease" or "set", "node")
            end
        end
        if ok then
            change = (objOp == 2) and ("+" .. tostring(entry.value)) or (objOp == 3) and ("-" .. tostring(entry.value)) or ("=" .. tostring(amount))
            KARDS.NodeParser.PushStatChange(ctx, card, change)
        end
        return ok
    end

    -- 词条属性
    if KARDS.NodeParser.SET_OBJ_KEYWORD_PROPS[opLabel] then
        local before = SnapshotKeywords(card)
        local ok = KARDS.NodeParser.SetCardField(card, "keywords", entry.value)
        if ok then
            KARDS.NodeParser.PushStatChange(ctx, card, "=" .. tostring(entry.value))
            -- 收缴 / 被收缴：授予瞬间触发收缴（2026-10-15 用户规格）
            MaybeTriggerConfiscate(ctx, card, before)
        end
        return ok
    end

    -- 文本槽属性（卡牌名称/描述/历史文本）：值 "var:<名>" 引用 或 直接文本
    if KARDS.NodeParser.SET_OBJ_TEXT_SLOT_PROPS[opLabel] then
        local raw = tostring(entry.value or "")
        local refName = raw:match("^var:(.+)$")
        local text = raw
        if refName then
            local tgt = KARDS.NodeParser.ResolveTarget(ctx, "t", refName)
            local v = tgt and KARDS.NodeParser.GetTarget(ctx, tgt)
            text = tostring(v or "")
        end
        -- 卡牌名称/描述等字段：卡牌句柄无写入通道（骨架阶段提示）；数据定义对象写 cardAppearance
        if card.cardAppearance and type(card.cardAppearance) == "table" then
            local appField = (opLabel == "卡牌名称") and "name"
                or (opLabel == "描述") and "description"
                or "historyText"
            if appField then card.cardAppearance[appField] = text end
        else
            print("[NodeParser] 提示: 卡牌句柄无「" .. opLabel .. "」字段（外观字段写入通道未实现）")
            return false
        end
        return true
    end

    -- 插图属性（卡牌插图/历史插图）：值 "../data/kards_images/<文件>"
    if KARDS.NodeParser.SET_OBJ_IMG_PROPS[opLabel] then
        local imgPath = tostring(entry.value or "")
        if card.cardAppearance and type(card.cardAppearance) == "table" then
            card.cardAppearance.imagePath = imgPath
            return true
        end
        print("[NodeParser] 提示: 卡牌句柄无「" .. opLabel .. "」字段（插图写入通道未实现）")
        return false
    end

    -- 单位类型 / 子类型：文本字段（子类型数据定义对象写 cardAppearance.subtype）
    if opLabel == "单位类型" then
        local ok = KARDS.NodeParser.SetCardField(card, "unitType", entry.value)
        if ok then KARDS.NodeParser.PushStatChange(ctx, card, "=" .. tostring(entry.value)) end
        return ok
    end
    if opLabel == "子类型" then
        if card.cardAppearance and type(card.cardAppearance) == "table" then
            card.cardAppearance.subtype = tostring(entry.value or "")
            return true
        end
        print("[NodeParser] 提示: 卡牌句柄无「子类型」字段（外观字段写入通道未实现）")
        return false
    end

    -- 品质：卡牌句柄无通道
    if opLabel == "品质" then
        print("[NodeParser] 提示: 卡牌句柄无「品质」字段（写入通道未实现）")
        return false
    end

    print("[NodeParser] 警告: 未识别的对象属性「" .. tostring(opLabel) .. "」")
    return false
end

-- ====================================================================
-- 判断变量关系节点（var_evaluate）— 测试版支持数值比较 + 对象比较
-- ====================================================================

-- 运算符集（与编辑器 EV_OPERATORS 一致；测试版支持数字 + 对象比较，布尔/文本/数组为正式版内容）
KARDS.NodeParser.EV_OPERATORS = { n = { "=", "≠", ">", "<", "≥", "≤" }, e = { "=", "≠", "是空", "非空" } }

-- 对象相等比较：优先卡牌 ID（不同句柄同一实例视为相等），否则引用相等
-- @param a,b any 对象值（卡牌句柄 / nil）
-- @return boolean
local function ObjEqual(a, b)
    if a == b then return true end
    local aid = (type(a) == "table" and a.GetID and a:GetID()) or nil
    local bid = (type(b) == "table" and b.GetID and b:GetID()) or nil
    if aid and bid then return aid == bid end
    return false
end

-- 解析条件行左操作数值（按左类型）
-- 来源：global（全局变量，cond.left.varName 显示名）/ input（数据线输入）
-- 数据线取值分两类（对齐 ResolveEWires 语义）：
--   - e 对象线：variableName = 上游输出端口名（如"事件目标"），值为上游节点 data 中的对象/对象组，
--     须经 ctx._nodesById 从上游节点输出读取（var_evaluate 不走 ResolveEWires，需自行解析）
--   - n/b/t 线：variableName = 全局变量名（var_set/var_evaluate 输出数字线时写入），走 ResolveTarget 解析
-- @param ctx  table 执行上下文
-- @param cond table 条件行
-- @param lType string 左操作数类型（"n" 数字 / "e" 对象）
-- @return any 左值（未选择/无法解析时返回 nil；数字类型由调用方按 0 处理）
local function ResolveEvalLeft(ctx, cond, lType)
    local varName = cond.left and cond.left.varName or ""
    local source = cond.left and cond.left.source or "global"
    if source == "input" and cond.left.connId and ctx.dataConnections then
        for _, dc in ipairs(ctx.dataConnections) do
            if dc.id == cond.left.connId and dc.variableName and dc.variableName ~= "" then
                -- 对象数据线：直接读上游节点输出值（单对象/对象组），不走变量定位
                if lType == "e" then
                    local from = ctx._nodesById and ctx._nodesById[dc.fromNode]
                    local val = from and from.data and from.data[dc.variableName]
                    -- 兜底：输出端口名可能带 e 前缀（node.data["e提取的卡牌对象组"]）
                    if val == nil and dc.variableName:sub(1, 1) ~= "e" then
                        val = from.data["e" .. dc.variableName]
                    end
                    return val
                end
                -- 数字/布尔/文本数据线：variableName 即全局变量名，走 ResolveTarget
                varName = dc.variableName
                break
            end
        end
    end
    if varName == "" then
        print("[NodeParser] 提示: 判断条件行左侧未选择变量，返回 nil")
        return nil
    end
    local target = KARDS.NodeParser.ResolveTarget(ctx, lType, varName)
    if not target then
        print("[NodeParser] 警告: 判断左操作数「" .. varName .. "」定位失败")
        return nil
    end
    return KARDS.NodeParser.GetTarget(ctx, target)
end

-- 数值比较（=、≠、>、<、≥、≤）
-- @return boolean 条件是否成立（未知运算符按不成立处理）
local function CompareValues(lval, op, rval)
    if op == "=" then return lval == rval
    elseif op == "≠" then return lval ~= rval
    elseif op == ">" then return lval > rval
    elseif op == "<" then return lval < rval
    elseif op == "≥" then return lval >= rval
    elseif op == "≤" then return lval <= rval end
    print("[NodeParser] 错误: 未知比较运算符「" .. tostring(op) .. "」，条件按不成立处理")
    return false
end

-- 单行条件评估（测试版：数值比较 + 对象比较）
-- 左操作数：数字/对象变量（global 全局 / input 数据线）；右操作数：数字字面量（n）或同类型对象变量（e）
-- 对象运算符：=、≠（右值变量槽）/ 是空、非空（无右值）
-- @param cond table 条件行 { left, operator, right }
-- @return boolean 单行条件结果（左操作数类型不支持或未选择时按 false）
function KARDS.NodeParser.EvaluateCondition(ctx, cond)
    if not cond or type(cond) ~= "table" then return false end
    ctx = EnsureCtx(ctx)
    local lType = cond.left and cond.left.dataType or ""
    if lType == "n" then
        local lval = ResolveEvalLeft(ctx, cond, "n")
        if lval == nil then lval = 0 end -- 未选择/无数字值按 0 处理（兼容旧行为）
        local rval = KARDS.NodeParser.ResolveNumberValue(ctx, cond.right and cond.right.literal)
        return CompareValues(lval, cond.operator, rval)
    elseif lType == "e" then
        -- 对象比较：左操作数解析为对象（卡牌句柄 / nil）
        local lobj = ResolveEvalLeft(ctx, cond, "e")
        local op = cond.operator or "="
        if op == "是空" then return lobj == nil end
        if op == "非空" then return lobj ~= nil end
        -- =、≠：右操作数为同类型对象变量（var 模式，cond.right.varName）
        local rName = cond.right and cond.right.varName or ""
        local robj = nil
        if rName ~= "" then
            local rtarget = KARDS.NodeParser.ResolveTarget(ctx, "e", rName)
            robj = rtarget and KARDS.NodeParser.GetTarget(ctx, rtarget) or nil
        end
        local equal = (lobj == nil and robj == nil)
            or (lobj ~= nil and robj ~= nil and ObjEqual(lobj, robj))
        if op == "=" then return equal end
        if op == "≠" then return not equal end
        print("[NodeParser] 错误: 未知对象比较运算符「" .. tostring(op) .. "」，条件按不成立处理")
        return false
    end
    print("[NodeParser] 警告: 判断变量关系测试版仅支持数字/对象比较（当前左类型: " .. tostring(lType or "未选择") .. "），条件按 false 处理")
    return false
end

-- 解析「判断变量关系」节点：逐行评估条件，按 _connectors 左结合组合，返回布尔结果
-- 左结合语义（templates.md L1311）：条件1 AND 条件2 OR 条件3 = (条件1 AND 条件2) OR 条件3
-- 输出 (p结果) 布尔值，由调用方（战斗系统）决定执行分支 / 数据线传值
-- @param ctx  table 执行上下文（同 ParseSetVariable）
-- @param node table 判断变量关系节点（node.data._conditions / node.data._connectors）
-- @return boolean 组合后的布尔结果（无条件行时 false）
function KARDS.NodeParser.ParseEvaluateVariable(ctx, node)
    ctx = EnsureCtx(ctx)
    local conds = node and node.data and node.data._conditions
    if not conds or #conds == 0 then
        print("[NodeParser] ParseEvaluateVariable: 节点无条件行（_conditions 为空）")
        return false
    end
    local conns = node.data._connectors or {}
    local result = KARDS.NodeParser.EvaluateCondition(ctx, conds[1])
    for i = 2, #conds do
        local c = KARDS.NodeParser.EvaluateCondition(ctx, conds[i])
        if (conns[i - 1] or "AND") == "OR" then
            result = result or c
        else
            result = result and c
        end
    end
    return result
end

-- ====================================================================
-- BaseSemantics 语义表：模板类型 → select 选项值 → 语义动作
-- ====================================================================
-- action（data_static/kards/node_templates/action.json）：
--   mainSelect select_2（获得/取消/被消灭）
--     获得 → subSelect select_3（20 项动作），items 键 = select_3 选项值
--     取消 → subSelect select_10（被压制/被抑制/被控制/免疫 状态），items 键 = 选项值
--     被消灭 → 直接动作 destroy
KARDS.NodeParser.BaseSemantics = {
    action = {
        mainSelect = "select_2",
        branches = {
            [1] = { -- 获得
                subSelect = "select_3",
                items = {
                    [1]  = { act = "retreat" },             -- 撤退
                    [2]  = { act = "moveToFront" },         -- 移动(到前线)
                    [3]  = { act = "engage",       target = "select_4" }, -- 交战
                    [4]  = { act = "fight",        target = "select_5" }, -- 战斗
                    [5]  = { act = "joinBattlefield" },    -- 加入战场
                    [6]  = { act = "joinFrontline" },      -- 加入前线
                    [7]  = { act = "suppress" },           -- 压制
                    [8]  = { act = "neutralize" },         -- 抑制
                    [9]  = { act = "convert" },            -- 转换
                    [10] = { act = "repair" },             -- 修复
                    [11] = { act = "control" },            -- 控制
                    [12] = { act = "immune" },             -- 免疫
                    [13] = { act = "intelligence", amount = "number_1" }, -- 情报（[lib] 情报数）
                    [14] = { act = "dealDamage", amount = "number_2" }, -- 造成伤害
                    [15] = { act = "triggerKeyword", target = "select_6", keyword = "select_7" }, -- 触发关键字效果
                    [16] = { act = "returnToHand" },       -- 返回手牌
                    [17] = { act = "summonUnit", unit = "select_8", zone = "select_9" }, -- 召唤单位
                    [18] = { act = "elevateToVeteran" },    -- 升为老兵
                    [19] = { act = "returnToDeckTop" },     -- 返回卡组顶（放到所有者牌堆顶）
                    [20] = { act = "confiscate" },           -- 收缴
                },
            },
            [2] = { -- 取消
                subSelect = "select_10",
                items = {
                    [1] = { act = "unsuppress" },   -- 被压制 → 解除压制
                    [2] = { act = "unneutralize" }, -- 被抑制 → 解除抑制
                    [3] = { act = "uncontrol" },    -- 被控制 → 解除控制
                    [4] = { act = "unimmune" },     -- 免疫 → 解除免疫
                },
            },
            [3] = { act = "destroy" }, -- 被消灭
        },
    },
    -- card（data_static/kards/node_templates/card.json）：
    --   sideSelect select_1（友方/敌方）+ mainSelect select_2（抽取/复制/弃掉/开发/选择/爆牌/洗切卡组/洗入）
    --   弃掉（2026-10-06 扩展手牌来源）：select_7 位置 1=手中 2=卡组顶 3=卡组底 4=随机 5=指定；
    --     选「手中」时 select_8 二级 1=自选的一张卡（无值 → 经指定操作让玩家选择）/ 2=第（number_4 数值序数）
    card = {
        sideSelect = "select_1",
        mainSelect = "select_2",
        branches = {
            [1] = { act = "draw",          count = "number_1", position = "select_3",
                    typeSelect = "select_4", typeSelectFallback = "select_5", specifiedIndex = 4 }, -- 抽取
            [2] = { act = "copy",          count = "number_2", position = "select_6" }, -- 复制
            -- 弃掉：position 1=手中（handKind 1=自选的一张卡 / 2=第 ordinal 张），2=卡组顶 3=卡组底 4=随机 5=指定
            [3] = { act = "discard",       count = "number_3", position = "select_7",
                    handKind = "select_8", ordinal = "number_4" }, -- 弃掉
            [4] = { act = "develop",       count = "number_5", pool = "select_9" }, -- 开发（{$} 开发池对象组变量）
            [5] = { act = "scry",          count = "number_6" }, -- 选择（观星）
            [6] = { act = "burn",          count = "number_7" }, -- 爆牌
            [7] = { act = "shuffleDeck" },                       -- 洗切卡组
            -- 洗入（2026-09-26 缺口 D：三来源；2026-09-27 补充「对象组」来源）
            --   select_10 来源 1=手牌中 2=指定的 3=凭空生成 4=对象组
            --   手牌中：select_11 随机1/指定2 + number_8 张数
            --   凭空生成：select_12 {$} 开发池对象组变量 + number_9 张数
            --   指定的：select_13 手牌1/场上2 + number_10 张数
            --   对象组：select_14 {$} 对象(组)变量 + number_11 张数
            --     （张数留空或 0 = 该对象(组)全部；列表仅 1 张而张数大于 1 时按克隆补足到该张数）
            [8] = { act = "shuffleInto",   source = "select_10", randomKind = "select_11",
                    randomCount = "number_8", genPool = "select_12", genCount = "number_9",
                    specifiedZone = "select_13", specifiedCount = "number_10",
                    groupVar = "select_14", groupCount = "number_11" }, -- 洗入
        },
    },
    -- command（data_static/kards/node_templates/command.json）：
    --   mainSelect select_1（阵营 友方1/敌方2/双方3）+ resourceSelect select_2（指挥点1/指挥点槽2）
    --   + opSelect select_3（增加1/减少2/设为3）+ amount number_1（[lib] 数值）
    command = {
        mainSelect = "select_1",
        resourceSelect = "select_2",
        opSelect = "select_3",
        amount = "number_1",
        branches = {
            [1] = { act = "commandPoint", side = "friendly" }, -- 友方
            [2] = { act = "commandPoint", side = "enemy" },    -- 敌方
            [3] = { act = "commandPoint", side = "both" },     -- 双方
        },
    },
    -- condition（data_static/kards/node_templates/condition.json）：
    --   mainSelect select_1（判断数量1/关键字检查2/前线归属3）
    --   分支 1（判断数量）：side select_2（敌方1/友方2）+ countType number_1（[lib+5] 5 种统计方式）
    --     + operator select_3（=1/>2/<3/>=4/<=5）+ value number_2（[lib] 比较值）
    --   分支 2（关键字检查）：target select_4（卡牌对象槽）+ keyword select_5（@combat_keywords 下拉）
    --   分支 3（前线归属）：side select_6（友方1/敌方2/无主3，读 GetFrontlineOwner 判定）
    --   结果输出：n比较结果、p布尔值、p是否有关键字
    condition = {
        mainSelect = "select_1",
        branches = {
            [1] = { act = "countCheck",   side = "select_2", countType = "number_1",
                    operator = "select_3", value = "number_2" },
            [2] = { act = "keywordCheck", target = "select_4", keyword = "select_5" },
            [3] = { act = "frontlineOwnerCheck", side = "select_6" },
        },
    },
    -- event_monitor（data_static/kards/node_templates/event_monitor.json）：
    --   sideSelect select_1（友方1/敌方2）+ eventTypeSelect select_2（8 种事件类型）
    --   分支按 select_2 选项值索引：目标1/单位2（共分支，监听属性变化/触发；H4：属性 select_4 +
    --   变化类型 select_5 + 变化值 number_2）、总部3（含防御约束 number_1）、
    --   打出指令4（select_7 时/花费/情报，花费约束 number_3；H1：「时：触发情报」约束情报数）、
    --   触发反制5（M1.4：任一操作被拦截时触发，拦截收尾 KARDS.Battle:InterceptOperation
    --   推 {操作类型, "counter"} 刻并调 TriggerEventHooks(tableID, "counter", card)）、加入6（部署/召唤/加入战场）、
    --   玩家7（@player_actions，手牌张数约束 number_4）、回合8（select_9 开始/结束）
    --   结果输出：t事件类型、e事件目标、p触发事件；返回值供双输出分支（触发/未触发）
    event_monitor = {
        sideSelect = "select_1",
        mainSelect = "select_2", -- 主分支 = 事件类型（1..8）
        branches = {
            [1] = { act = "monitor", event = "target", attr = "select_4", change = "select_5", value = "number_2" },
            [2] = { act = "monitor", event = "unit",   attr = "select_4", change = "select_5", value = "number_2" },
            [3] = { act = "monitor", event = "hq",         defense = "number_1" },
            [4] = { act = "monitor", event = "play_order", cost = "number_3" },
            [5] = { act = "monitor", event = "counter" },
            [6] = { act = "monitor", event = "join" },
            [7] = { act = "monitor", event = "player",     count = "number_4" },
            [8] = { act = "monitor", event = "turn",       phase = "select_9" },
        },
    },
    -- extract（data_static/kards/node_templates/extract.json）：
    --   select_1 阵营（友方1/敌方2/双方3，执行器内自行展开，不走 sideSelect）+ mainSelect select_2（卡牌类型）
    --   单位分支（1）：属性条件 attr select_3（攻击力1/防御力2/卡牌花费3/行动花费4）+ 属性值 number_1
    --   指令（2）/反制（3）分支：卡牌花费 number_2
    --   总部分支（4）：无属性条件，直接提取该方总部卡
    --   输出：e 卡牌对象组（单位取战场支援阵线+前线，指令/反制取手牌，总部取总部卡），存 node.data[输出端口名] 供数据线消费
    extract = {
        mainSelect = "select_2",
        branches = {
            [1] = { act = "extract", cardType = "unit",            attr = "select_3", value = "number_1" },
            [2] = { act = "extract", cardType = "command",         cost = "number_2" },
            [3] = { act = "extract", cardType = "counter_command", cost = "number_2" },
            [4] = { act = "extract", cardType = "headquarter" },
        },
    },
    -- headquarter（data_static/kards/node_templates/headquarter.json）：
    --   mainSelect select_1（阵营 友方1/敌方2/双方3）+ opSelect select_2（增加1/减少2/设为3）
    --   + amount number_1（[lib] 数值；总部防御可低于 0，总部始终驻留）
    headquarter = {
        mainSelect = "select_1",
        opSelect = "select_2",
        amount = "number_1",
        branches = {
            [1] = { act = "hqDefense", side = "friendly" }, -- 友方
            [2] = { act = "hqDefense", side = "enemy" },    -- 敌方
            [3] = { act = "hqDefense", side = "both" },     -- 双方
        },
    },
    -- loop（data_static/kards/node_templates/loop.json）：
    --   无 select 分支；单一动作 loop，number_1 为循环计数（[0] 数字槽）
    --   双输出节点（hasSecondOutput）：未结束（>0）→ 计数 -1 返回 true（第一输出点继续循环），
    --   已结束（=0）→ 返回 false（第二输出点循环结束）
    loop = { act = "loop" },
    -- choice（data_static/kards/node_templates/choice.json，2026-10-04 新增）：
    --   无 select 分支（同 loop：单一动作 act 直接定义在 sem 上）
    --   双输出节点（hasSecondOutput）：玩家选择「效果一」→ 返回 true（第一输出点/端口 satisfied），
    --   选择「效果二」→ 返回 false（第二输出点/端口 not_satisfied）
    --   text1/text2 = 两个文本槽组件 id（值为直接文本 或 "var:<文本变量名>"，由执行器解析）
    choice = {
        act = "choice",
        text1 = "textslot_1",
        text2 = "textslot_2",
    },
    -- property（data_static/kards/node_templates/property.json，base 带 e 输入前缀）：
    --   mainSelect select_1（随机排列所有1/战斗2）；随机排列所有 → select_2 单位1/友方2/敌方3
    --   「随机排列」在目标方控制的阵线范围（支援阵线 + 控制的前线）随机重排所有单位（总部不参与）
    --   战斗 → 攻击者 = e 数据线 targets[1]（target_selector 选出的对象组，无注入时回退 select_3 对象槽）
    --     × 防御者 = select_4 对象槽的单位，双方互相战斗（SimFight）
    property = {
        mainSelect = "select_1",
        branches = {
            [1] = { act = "shuffleUnits", side = "select_2" }, -- 随机排列所有（对象方由 select_2 决定）
            [2] = { act = "battle", attacker = "select_3", defender = "select_4" }, -- 战斗（与对象槽单位战斗）
        },
    },
    -- register_hook（data_static/kards/node_templates/register_hook.json）：
    --   「注册钩子」双分支（mainSelect select_1：通用效果1/一般属性修饰2）
    --   一般属性修饰（分支2）：select_2 作用目标（敌方/友方/所有）、select_3 修饰对象（造成的伤害/攻击力/防御力）、
    --     select_4 修饰方式（增加/减少/设为）、number_1 数值、select_5 作用域（存活在场/永久）→ 引擎钩子持续修饰
    --   通用效果（分支1）：select_6 触发模式（总是触发/条件触发）、条件触发时 select_7 事件阵营（敌方/友方）
    --     × select_8 事件（回合开始/回合结束/部署单位/打出指令/触发反制）、funcslot_1 函数 → 调用函数
    --   造成的伤害 → OnModifyDamage 钩子；攻击力/防御力 → OnModifyStat 钩子；输出 p钩子ID
    register_hook = {
        mainSelect = "select_1",
        branches = {
            [1] = { act = "registerEffect" },   -- 通用效果：调用函数（总是触发立即调用 / 条件触发注册事件钩子）
            [2] = { act = "registerModifier" }, -- 一般属性修饰：引擎钩子持续数值修饰
        },
    },
    -- target_selector（data_static/kards/node_templates/target_selector.json）：
    --   「选择卡牌单位目标」：mainSelect select_1（选择方式 指向一个1/随机2/所有3/属性最高4/属性最低5）
    --   属性最高/最低 → select_2 属性（@card_stats）+ number_1 名次；随机 → number_2 数量
    --   select_3 阵营范围（友方1/敌方2/场上3）× select_4 卡牌类别（单位1/目标2/总部3），
    --   单位时 select_5 单位类型（1 任意 / 2-6 战斗机/坦克/轰炸机/炮兵/步兵）过滤；
    --   输出 e选中的卡牌（对象组，供下游 action 消费）
    target_selector = {
        mainSelect = "select_1",
        branches = {
            [1] = { act = "select", mode = "one" },     -- 指向一个：从候选取第 1 个
            [2] = { act = "select", mode = "random" },  -- 随机：随机取 number_2 个（不重复）
            [3] = { act = "select", mode = "all" },     -- 所有：全部候选
            [4] = { act = "select", mode = "highest" }, -- 属性最高：按 select_2 属性取第 number_1 名
            [5] = { act = "select", mode = "lowest" },  -- 属性最低：同上（升序）
        },
    },
    -- trigger_function（data_static/kards/node_templates/trigger_function.json）：
    --   「触发函数」：mainSelect select_1（触发模式 触发一次1/保持触发2/停止保持触发3/拦截一次4/保持拦截5）
    --   e 输入注册/触发的目标实体；funcslot_1 函数；select_5 效果图标（主动效果/被动效果/无/@combat_keywords）
    --   拦截分支（4/5）内另有操作类型选择：拦截一次 select_2 / 保持拦截 select_3（16 种操作，见
    --   sh_node_hooks.lua INTERCEPT_OPTYPES），决定拦截 args.opType 命中的操作类型
    --   收尾方式：拦截一次 select_6 / 保持拦截 select_8（反制1/属性变更2）
    --   属性变更数值：拦截一次 select_7 修饰 + number_1 数值 / 保持拦截 select_9 修饰 + number_2 数值
    --   输出 e目标、t效果图标类型（base 输出端口）
    --   触发一次 = 立即同步调用函数子图；保持触发 = 注册到目标实体每回合自动执行；
    --   停止保持触发 = 移除目标实体上的注册；
    --   拦截一次/保持拦截 = 注册 OnBeforeOperation 引擎钩子并按操作类型过滤（复用 args.intercepted；
    --   反制直接取消操作，属性变更则改写 args.amount，拦截一次首次命中后自动注销，见 sh_node_hooks.lua RegisterIntercept）
    trigger_function = {
        mainSelect = "select_1",
        branches = {
            [1] = { act = "triggerOnce" },   -- 触发一次：立即执行函数子图（同步，函数完成后本节点再继续）
            [2] = { act = "keepTrigger" },   -- 保持触发：注册到目标实体，实体拥有者回合开始自动执行
            [3] = { act = "stopTrigger" },   -- 停止保持触发：从目标实体移除本节点注册的保持触发
            [4] = { act = "interceptOnce", opSelect = "select_2", finishSelect = "select_6", modSelect = "select_7", valueNumber = "number_1" }, -- 拦截一次：按操作类型拦截或改写数值，首次命中后自动注销
            [5] = { act = "keepIntercept", opSelect = "select_3", finishSelect = "select_8", modSelect = "select_9", valueNumber = "number_2" }, -- 保持拦截：按操作类型持续拦截或改写敌方操作
        },
    },
    -- trigger（data_static/kards/node_templates/trigger.json）：
    --   「属性与伤害」：目标卡牌 = e 输入数据线 targets（select_1 为卡牌对象选择 {$}，槽值恒 1）
    --   mainSelect select_2（攻击1/防御2/受到伤害3）
    --   分支 1（攻击）：select_3 操作（设为1/增加2/减少3）+ number_1 数值 → 目标攻击力修改
    --   分支 2（防御）：select_4 操作（受到1/设为2/增加3/减少4）+ number_2 数值 → 目标防御力修改
    --     「受到」= 受到伤害（SimDealDamage 伤害结算，触发 OnModifyDamage 修饰）
    --   分支 3（受到伤害）：number_3 数值 → 目标受到 N 点伤害（SimDealDamage；总部可为目标）
    --   输出 n攻击力、n防御力（base 输出端口，写入第一个目标的修改后属性值，供数据线）
    trigger = {
        mainSelect = "select_2",
        branches = {
            [1] = { act = "modifyAttack",  op = "select_3", amount = "number_1" }, -- 攻击
            [2] = { act = "modifyDefense", op = "select_4", amount = "number_2" }, -- 防御
            [3] = { act = "damage", amount = "number_3" }, -- 受到伤害：目标受到 N 点伤害
        },
    },
    -- turn（data_static/kards/node_templates/turn.json）：
    --   「回合」实在的时间刻节点（跨刻执行）：mainSelect select_1（等待1/使2）
    --   分支 1（等待）：select_2 阵营（友方1/敌方2/任意3）× select_3 时刻（开始1/结束2）
    --     × number_1 次数（数字槽，缺省 1）
    --     → 效果跨刻挂起：信号停滞在 turn 节点，后续符合条件的时间刻计数 +1，达标后继续效果
    --   分支 2（使，2026-08-14 增加归属）：select_4 归属（友方1/敌方2）× select_5 动作
    --     （回合结束1/跳过回合2）→ 立即推进目标归属的当前回合（不走挂起）
    turn = {
        mainSelect = "select_1",
        branches = {
            [1] = { act = "waitTurn", side = "select_2", phase = "select_3", times = "number_1" }, -- 等待
            [2] = { act = "makeTurn", side = "select_4", op = "select_5" }, -- 使：归属×动作
        },
    },
}

