--[[
=======================================================================================
基础变量操作节点系统 (Basic Variable Operation Node System)

实现 4 个底层变量操作节点，让玩家自由创建/修改/转换/判断变量。

设计原则：
  1. 组件优先使用原节点编辑器组件（DrawNumberBox, DrawDropdown 等）
  2. 动态内容使用 drawFunction，但视觉元素匹配标准组件
  3. 所有尺寸适配 INE 画布缩放
  4. 操作后必须同时重新计算节点宽度和高度
  5. 不干扰其他任何节点的正常功能
  6. 所有交互组件在绘制时注册 _interactiveRects，防止 INE 输入处理器误判为"点击节点体"

节点列表（测试版状态：新建变量与转换与提取为"正式版内容"未注册；判断变量关系仅支持数值比较；设置变量完整实现）：
  1. CreateVariable（新建变量）     — 创建任意类型变量并输出引用（正式版内容，测试版放弃）
  2. SetVariable（设置变量）        — 修改全局变量（测试版完整实现）
  3. ConvertExtractVariable（转换与提取变量）— 变量值转换/提取（正式版内容，测试版放弃，暂以"获取单位防御力/攻击力"替代）
  4. EvaluateRelationship（判断变量关系）— 数值比较（测试版仅支持数字，其余类型为正式版内容）

依赖：
  - INE 命名空间、INE.DataTypes、LogNewNode（cl_ine_node_editor.lua）
  - Canvas.DrawNumberBox、Canvas.DrawDropdown（cl_ca_ui_components.lua）
=======================================================================================
]]

local INE = KARDS.CardEditor.IndependentNodeEditor
local Canvas = KARDS.CardEditor.Canvas
local VarOp = KARDS.CardEditor.VarOpNodes or {}
KARDS.CardEditor.VarOpNodes = VarOp

-- 标准组件颜色常量
local COL_BG = Color(60, 60, 60)
local COL_BTN = Color(60, 90, 120)
local COL_BTN_HOVER = Color(80, 130, 180)
local COL_INPUT = Color(50, 55, 60)
local COL_INPUT_HOVER = Color(55, 60, 65)
local COL_LABEL = Color(180, 180, 180)
local COL_TEXT = Color(255, 255, 255)
local COL_SUB = Color(150, 150, 150)
local COL_LINK = Color(100, 200, 255)

-- "判断变量关系"节点：运算符按左操作数类型自适应（templates.md L1251-1258）
-- 正式版内容：测试版支持数值比较 + 对象比较（e）；布尔/文本/数组类型运算符已注释，留待正式版恢复
local EV_OPERATORS = {
    n = {"=", "≠", ">", "<", "≥", "≤"},
    e = {"=", "≠", "是空", "非空"},
    --[[ 正式版内容
    b = {"=", "≠"},
    t = {"=", "≠", "包含", "不包含", "开头为", "结尾为"},
    g = {"=", "≠", "包含", "不包含", "项目数=", "项目数>", "项目数<"},
    ]]
}
-- "判断变量关系"节点：右操作数默认模式
--   literal = 字面量输入（数字/文本输入框、布尔 true/false 选择）
--   var     = 同类型全局变量槽（对象/数组比较）
--   none    = 无右值（对象"是空/非空"）
-- 正式版内容：测试版支持数字（literal）+ 对象（var）默认模式，其余类型已注释
local EV_RIGHT_MODE = {
    n = "literal",
    e = "var",
    --[[ 正式版内容
    b = "literal", t = "literal",
    g = "var",
    ]]
}
-- "判断变量关系"节点：=、≠ 运算符下允许在 literal/var 间切换的类型
-- 正式版内容：literal/var 切换 UI 未实现，测试版仅数值比较（n 恒为数字字面量）
local EV_SWITCHABLE_TYPES = { n = true }

-- "设置变量"节点：类型→操作集（templates.md L1099-1143）
--   数字 {设为、增加、减少} / 布尔 {设为、反转} / 数组 {设为、第、最后一项}
--   对象（单位超集）{花费、行动花费、攻击力、防御力、单位类型、卡牌名称、词条、描述、品质、卡牌插图、历史插图、历史文本、子类型}
--   函数 '改为'（固定标签）/ 文本 无操作（直接输入框）
local SET_OPS = {
    n = {"设为", "增加", "减少"},
    b = {"设为", "反转"},
    g = {"设为", "第", "最后一项"},
    e = {"花费", "行动花费", "攻击力", "防御力", "单位类型", "卡牌名称", "词条", "描述", "品质", "卡牌插图", "历史插图", "历史文本", "子类型"},
    f = {"改为"},
}
-- "设置变量"节点：对象操作集按对象类别区分（templates.md L1107-1111）
--   单位 → 13 项超集；指令/反制 → 9 项子集；空对象 → 固定 '设为'（无下拉，见 SET_OBJ_EMPTY_OP）
local SET_OBJ_OPS = {
    unit = {"花费", "行动花费", "攻击力", "防御力", "单位类型", "卡牌名称", "词条", "描述", "品质", "卡牌插图", "历史插图", "历史文本", "子类型"},
    cmd  = {"花费", "卡牌名称", "词条", "描述", "品质", "卡牌插图", "历史插图", "历史文本", "子类型"},
}
local SET_OBJ_EMPTY_OP = "设为"  -- 空对象固定操作
-- "设置变量"节点：对象数值属性（值控件用 [lib] 数字槽，templates.md L1110）
local SET_OBJ_NUM_PROPS = {花费 = true, 行动花费 = true, 攻击力 = true, 防御力 = true}
-- "设置变量"节点：对象插图属性（值控件用插图槽：粉 p 字符 + 图片下拉 + 悬停预览，templates.md L1112-1113）
local SET_OBJ_IMG_PROPS = {卡牌插图 = true, 历史插图 = true}
-- "设置变量"节点：对象文本槽属性（绿 t 字符 + 文本变量下拉/直接输入，templates.md L1114-1115）
--   提示词原文写作"历史描述"，实际操作集为"历史文本"，此处按操作集应用
local SET_OBJ_TEXT_SLOT_PROPS = {卡牌名称 = true, 描述 = true, 历史文本 = true}
-- "设置变量"节点：对象词条属性（词条多选组件，templates.md L1120-1121）
local SET_OBJ_KEYWORD_PROPS = {词条 = true}

-- 单位类型单选映射：显示名 → 卡牌接口 UnitTypes 内部名（readme 7.3）
local UNIT_TYPE_CN_TO_EN = {
    步兵 = "infantry", 炮兵 = "artillery", 坦克 = "tank",
    战斗机 = "fighter", 轰炸机 = "bomber",
}

-- 子类型词库文件（data 下，每行一个子类型名，可随时文本调整）
local SUBTYPE_LIB_FILE = "kards_subtypes.txt"
-- 子类型下拉的"新建"尾项标记
local SUBTYPE_CREATE_OPT = "＋ 新建子类型…"

-- 读取子类型词库选项（data/kards_subtypes.txt 每行一个；词库为空时回退子类型文件系统
-- effects_data/subtypes 第一层条目，与外观编辑器同源）
-- @return table 子类型名数组（不含新建标记）
local function LoadSubtypeOptions()
    local opts = {}
    local content = file.Read(SUBTYPE_LIB_FILE, "DATA")
    if content then
        for line in content:gmatch("[^\r\n]+") do
            local s = line:gsub("^%s+", ""):gsub("%s+$", "")
            if s ~= "" then table.insert(opts, s) end
        end
    end
    if #opts == 0 then
        local dirs, files = file.Find("effects_data/subtypes/*", "DATA")
        for _, d in ipairs(dirs or {}) do table.insert(opts, d) end
        for _, f in ipairs(files or {}) do table.insert(opts, f) end
    end
    return opts
end

-- 追加子类型到词库（已存在则跳过）
-- @param name string 子类型名
local function AppendSubtypeOption(name)
    if not name or name == "" then return end
    local content = file.Read(SUBTYPE_LIB_FILE, "DATA")
    if content then
        for line in content:gmatch("[^\r\n]+") do
            if line:gsub("^%s+", ""):gsub("%s+$", "") == name then return end
        end
    end
    file.Append(SUBTYPE_LIB_FILE, name .. "\n", "DATA")
end

-- 辅助："设置变量"行值按类型取默认值
-- 布尔恒为 "false"（布尔不存在 true/false 之外的第三状态）；数字 0；文本 ""；其余 nil
local function SetEntryDefaultValue(varType)
    if varType == "b" then return "false"
    elseif varType == "n" then return 0
    elseif varType == "t" then return ""
    end
    return nil
end

-- 辅助：从变量选择器选项提取对象类别（templates.md L1106-1111）
--   unit   单位（13 项超集）
--   cmd    指令/反制（9 项子集）
--   empty  空对象（固定 '设为'，无操作下拉）
-- 来源：对象变量条目（editor.variables["e"]）的 _mode / cardAppearance.cardType；
--   VarLib 对象变量无 raw 条目，按单位处理（兜底）。
local function GetObjModeFromVar(v)
    local raw = v and v.raw
    if raw then
        if raw._mode == "empty" then return "empty" end
        if raw.cardAppearance and raw.cardAppearance.cardType then
            local ct = raw.cardAppearance.cardType
            if ct == "command" or ct == "counter_command" then return "cmd" end
        end
    end
    return "unit"
end

-- 编辑期当前卡牌是否为单位（卡牌专属固定变量 unitOnly 项展示判断；缺省视为单位）
-- 依据 Canvas.EditorMode（unit/command/counter_command/headquarter/function）
function VarOp.IsEditingUnit()
    local canvas = KARDS.CardEditor and KARDS.CardEditor.Canvas
    local mode = canvas and canvas.EditorMode
    return not mode or mode == "unit"
end

-- 辅助：收集文本变量选项（文本槽下拉，templates.md L1118-1119）
-- 来源：全局文本变量（editor.variables["t"]）+ 数据线传入的文本变量
--       （连接到本节点文本输入端口的数据线，variableName 即传入变量名）；去重。
local function GetTextVarOptions(editor, node)
    local opts = {}
    local function AddOpt(name)
        if name and name ~= "" then
            for _, o in ipairs(opts) do
                if o == name then return end
            end
            table.insert(opts, name)
        end
    end
    if editor and editor.variables and editor.variables["t"] then
        for _, v in ipairs(editor.variables["t"]) do
            AddOpt(VarOp.GetVarDisplayName(v))
        end
    end
    if editor and node and editor.dataConnections then
        for _, dc in ipairs(editor.dataConnections) do
            if dc.toNode == node.id and dc.variableName and dc.variableName ~= "" then
                local toPorts = node.selectedInputTypes or {}
                local tp = toPorts[dc.toPortIndex]
                local tpId = (type(tp) == "table" and tp.id) or tp
                if tpId == "t" then
                    AddOpt(dc.variableName)
                end
            end
        end
    end
    return opts
end

-- 词条显示数据（词条多选组件，templates.md L1122）：
--   有序词条 key 列表：布尔词条 → 数值词条 → 特殊词条（老兵/可升为老兵）
local KEYWORD_KEYS = nil
local function GetAllKeywordKeys()
    if KEYWORD_KEYS then return KEYWORD_KEYS end
    local seen = {}
    local out = {}
    local function Add(list)
        for _, k in ipairs(list or {}) do
            if not seen[k] and KARDS.CardEditor.Data.KeywordDisplayNames
               and KARDS.CardEditor.Data.KeywordDisplayNames[k] then
                seen[k] = true
                table.insert(out, k)
            end
        end
    end
    Add(KARDS.CardEditor.Data.BooleanKeywordKeys)
    Add(KARDS.CardEditor.Data.NumericKeywordKeys)
    Add({"veteran", "can_elevate_to_veteran"})
    KEYWORD_KEYS = out
    return out
end

-- 辅助：解析词条多选值（逗号分隔 key 字符串）为 key 集合（key→true）
local function ParseKeywordValue(value)
    local sel = {}
    local v = tostring(value or "")
    if v ~= "" then
        for k in v:gmatch("[^,]+") do sel[k] = true end
    end
    return sel
end

-- 辅助：词条 key 集合 → 逗号分隔字符串（按全部词条顺序，保持稳定）
local function SerializeKeywordValue(sel)
    local parts = {}
    for _, k in ipairs(GetAllKeywordKeys()) do
        if sel[k] then table.insert(parts, k) end
    end
    return table.concat(parts, ",")
end

-- 辅助：本帧是否已消费下拉框选项点击（Think 阶段选中选项即关闭下拉框时记录帧号）。
-- 下拉框选项与节点下方的按钮/行在屏幕上可能重叠（如"设置变量"最后一行操作下拉框的
-- 首选项恰好落在 "+ 修改全局变量" 按钮区域），若不忽略，绘制阶段同一帧会重复触发
-- 按钮/行点击，误开变量选择浮层。帧号比较自过期，无需手动重置。
local function DropdownConsumed()
    return Canvas._dropdownConsumedFrame == FrameNumber()
end

-- ====================================================================================
-- 内联输入框状态（glua-input-field 模式）
-- 使用透明 DTextEntry 捕获 IME/键盘输入，实现节点内文本编辑。
-- 参考 cl_ine_node_editor.lua 中 VarSearchState / NumVarFieldState 的既有模式。
-- ====================================================================================
VarOp.InputState = {
    active = false,     -- 是否有输入框激活
    node = nil,         -- 所属节点（用于有效性校验）
    entry = nil,        -- 所属变量条目（_varEntries 元素）
    field = "",         -- 字段类型: "name" / "internalName" / "initValue"
    text = "",          -- 当前输入文本（OnTextChanged 同步）
    x = 0, y = 0, w = 0, h = 0,  -- 输入框屏幕坐标（绘制时更新，供 DTextEntry 定位）
}
VarOp.InputEntry = nil  -- DTextEntry 实例（完全透明，仅用于捕获输入）

-- 辅助：收集数字全局变量显示名列表（[lib] 数字槽选项，templates.md L907-912）
-- 来源：编辑器用户自定义数字变量 + VarLib 数字变量（GetDisplayName 转译中文显示名）
local function GetNumericVarOptions(editor)
    local opts = {}
    if editor and editor.variables and editor.variables["n"] then
        for _, v in ipairs(editor.variables["n"]) do
            local dName = VarOp.GetVarDisplayName(v)
            if dName ~= "" then table.insert(opts, dName) end
        end
    end
    if KARDS.VarLib and KARDS.VarLib.GetVarPathsByType then
        local libByType = KARDS.VarLib.GetVarPathsByType("1")
        local paths = libByType and libByType["n"]
        if paths then
            for _, vp in ipairs(paths) do
                table.insert(opts, KARDS.VarLib.GetDisplayName(vp))
            end
        end
    end
    return opts
end

-- 辅助：带 [lib] 单选模式的数字槽（可输入数字或单选全局变量，templates.md L907-912）
-- 值存储于 node.data[field]：slot 模式存数字，select 模式存 "var:<显示名>"（变量引用）
-- DrawNumberBox 展开变量选择弹窗（NumericVarPopup）后，按 numData.selectedOptionIndex 回写
local function DrawLibNumberBox(node, field, x, y, size, defaultVal, font)
    local editor = node and node.editor
    local opts = GetNumericVarOptions(editor)
    node.data[field] = node.data[field] or defaultVal
    local raw = node.data[field]
    local nId = "libnum_" .. field
    local numData = node.data.numbers and node.data.numbers[nId]
    local isVarRef = type(raw) == "string" and raw:sub(1, 4) == "var:"
    if numData and isVarRef then
        -- 变量引用：数据驱动强制 select 模式，按显示名定位选项索引
        numData.mode = "select"
        local found = nil
        for oi, o in ipairs(opts) do
            if o == raw:sub(5) then found = oi break end
        end
        numData.selectedOptionIndex = found or 1
        numData.value = 0
    end
    -- 数字数据：不干预 numData.mode，保留用户手动切换（点 "n" 切 select、点下拉选变量）
    local newVal, slotW = Canvas.DrawNumberBox(x, y, size,
        isVarRef and 0 or (tonumber(raw) or 0), node, nId, opts, font)
    -- 槽 → 数据：select 模式保存变量引用，slot 模式保存数字
    if numData then
        if numData.mode == "select" and numData.selectedOptionIndex then
            node.data[field] = "var:" .. (opts[numData.selectedOptionIndex] or "")
        elseif numData.mode == "slot" and newVal ~= nil then
            node.data[field] = newVal
        end
    end
    -- 第二返回值：数字槽实际总宽（select 模式由选中文本决定，可能远超预留 boxW），
    -- 供调用方以实宽偏移后缀文字，避免文字与数字槽重合（V3）
    return node.data[field], slotW
end

-- ====================================================================================
-- 变量类型与数据端口管理
-- ====================================================================================
local DATA_TYPE_MAP = {
    n = "n", e = "e", g = "g", t = "t", b = "p", f = "f"
}
-- INE 数据类型 id（editor.variables/数据线/浮层 onSelect 使用，布尔为 p）→ VarTypes 内部 id（设置变量节点使用，布尔为 b）。
-- 与 DATA_TYPE_MAP 互为反向（仅布尔不同：p→b）。
local DATA_TYPE_MAP_REV = {
    n = "n", e = "e", g = "g", t = "t", p = "b", f = "f"
}

-- 辅助：INE 数据类型 id → VarTypes 内部 id（未知 id 原样返回）
local function INEToVarTypeId(ineId)
    return DATA_TYPE_MAP_REV[ineId] or ineId
end

VarOp.VarTypes = {
    { id = "n", name = "数字",   char = "n", color = Color(255, 165, 0) },
    { id = "e", name = "对象",   char = "e", color = Color(220, 100, 80) },
    { id = "g", name = "数组",   char = "g", color = Color(255, 200, 0) },
    { id = "t", name = "文本",   char = "t", color = Color(144, 238, 144) },
    { id = "b", name = "布尔值", char = "b", color = Color(135, 206, 250) },
    { id = "f", name = "函数",   char = "f", color = Color(200, 150, 255) },
}

-- 缓存 INE 数据类型引用
VarOp.TypeRefs = {}

local function InitTypeRefs()
    if not INE or not INE.GetDataTypeById then return end
    for _, vt in ipairs(VarOp.VarTypes) do
        local dtId = DATA_TYPE_MAP[vt.id]
        local ref = INE.GetDataTypeById(dtId)
        if ref then
            VarOp.TypeRefs[vt.id] = ref
            vt.dataTypeRef = ref
        end
    end
end

-- 辅助：获取缩放后的字体
local function GetScaledFont(scale, baseSize)
    return INE:GetScaledFont("SourceHan_Heavy", baseSize, scale)
end

-- 辅助：获取缩放后的文本宽度
local function GetTW(text, fontName)
    surface.SetFont(fontName)
    return surface.GetTextSize(text)
end

-- 辅助：读取激活输入框字段当前应显示的文本（从目标数据读取，用于 DTextEntry 文本同步）
function VarOp.GetInputFieldText()
    local st = VarOp.InputState
    if st.field == "ev_right" then
        -- "判断变量关系"条件行右操作数字面量
        local cond = st.node and st.node.data and st.node.data._conditions
                 and st.node.data._conditions[st.condIdx]
        if cond and cond.right then return tostring(cond.right.literal or "") end
        return ""
    elseif st.field == "sv_value" then
        -- "设置变量"节点值输入区文本（按条目读取，多设置行各自绑定不同条目）
        local e = st.entry
        return tostring(e and e.value or "")
    elseif st.field == "sv_itemName" then
        -- "设置变量"数组"第"子操作"类型→创建变量组件"的名称输入（绑定条目 itemName 字段）
        local e = st.entry
        return tostring(e and e.itemName or "")
    elseif st.field == "arrItemName" then
        -- "新建变量"数组"+"子操作"独立变量创建 UI 的项名输入（绑定条目 arrayItemName 字段）
        local e = st.entry
        return tostring(e and e.arrayItemName or "")
    end
    local e = st.entry
    if not e then return "" end
    if st.field == "name" then return e.name or ""
    elseif st.field == "internalName" then return e.internalName or ""
    elseif st.field == "initValue" then return tostring(e.initValue or "") end
    return ""
end

-- 辅助：绘制内联输入框（glua-input-field 模式）
-- 负责：背景（激活高亮+蓝色边框）、文本（有值白色/空值灰色占位）、
--       闪烁光标（激活时）、鼠标点击检测（激活/切换字段）。
-- 注意：x,y,w,h 为屏幕坐标，与 Think 中 DTextEntry 定位使用同一数据源，
--       保证两者完全重叠。
-- condIdx：可选，"判断变量关系"条件行右值输入框时传条件行索引以区分激活状态
local function DrawInputField(node, mX, mY, click, field, x, y, w, h, font, value, placeholder, targetEntry, condIdx)
    local state = VarOp.InputState
    local isActive = state.active and state.node == node
                 and state.entry == targetEntry and state.field == field
                 and (condIdx == nil or state.condIdx == condIdx)

    -- 激活字段每帧同步绘制位置（供 Think 中 DTextEntry 定位，跟随节点拖动/缩放）
    if isActive then
        state.x, state.y, state.w, state.h = x, y, w, h
    end

    -- 背景
    if isActive then
        draw.RoundedBox(3, x, y, w, h, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(x, y, w, h)
    else
        local hov = mX >= x and mX <= x + w and mY >= y and mY <= y + h
        draw.RoundedBox(3, x, y, w, h, hov and COL_INPUT_HOVER or COL_INPUT)
    end

    -- 文本：激活时显示输入状态文本，未激活显示数据值
    -- 超宽时向右滚动：文本尾部（光标处）始终对齐框内，左侧滚出部分用 scissor 裁剪（C4）
    local dispText = isActive and state.text or (value or "")
    if dispText == "" then
        draw.SimpleText(placeholder, font, x + 4, y + h / 2,
            isActive and Color(180, 180, 180) or Color(120, 120, 120),
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        surface.SetFont(font)
        local tw = surface.GetTextSize(dispText)
        local scroll = math.max(0, tw - (w - 8))
        if scroll > 0 then
            render.SetScissorRect(x, y, x + w, y + h, true)
        end
        draw.SimpleText(dispText, font, x + 4 - scroll, y + h / 2,
            COL_TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        if scroll > 0 then
            render.SetScissorRect(0, 0, 0, 0, false)
        end
    end

    -- 光标（激活时闪烁，与文本滚动偏移同步）
    if isActive and math.floor(SysTime() * 2) % 2 == 0 then
        surface.SetFont(font)
        local tw = surface.GetTextSize(dispText)
        local scroll = math.max(0, tw - (w - 8))
        local cursorX = x + 4 + tw - scroll
        surface.SetDrawColor(Color(200, 200, 200))
        surface.DrawLine(cursorX, y + 3, cursorX, y + h - 3)
    end

    -- 点击检测：激活/切换字段（拖动节点、下拉框展开或变量选择器浮层打开时忽略，避免误触）
    if click and not Canvas.DraggingNode and not Canvas.ExpandedDropdown
       and not Canvas.GlobalVarSelector and not DropdownConsumed() then
        if mX >= x and mX <= x + w and mY >= y and mY <= y + h then
            state.active = true
            state.node = node
            state.entry = targetEntry
            state.field = field
            state.condIdx = condIdx
            state.text = tostring(value or "")
            state.x, state.y, state.w, state.h = x, y, w, h
        end
    end
end

-- 辅助：注册交互元素 rect，防止 INE 输入处理器误判为"点击节点体"
-- 注意：必须使用 table.insert（数字索引），因为 GetNodeInteractiveElement 使用 ipairs 遍历。
-- 预条件：node.editor 和 node.editor._interactiveRects 必须存在
local function RegisterIR(editor, node, id, x, y, w, h)
    if not editor or not node then return end
    local rects = editor._interactiveRects
    if not rects then return end
    -- 注意：id 仅用于调试/去重参考，实际使用 table.insert（数字索引）
    -- 因为 GetNodeInteractiveElement(cl_ine_node_editor.lua:4063) 使用 ipairs 遍历。
    table.insert(rects, {
        nodeId = node.id,
        x = x, y = y, w = w, h = h,
        _id = id,  -- 调试标识，实际无功能作用
    })
end

-- 辅助：获取变量条目在数据端口上的显示名称
-- 优先使用自定义变量名（name），回退内部名（internalName），最后回退类型中文名。
-- 与 SetVariable 节点选择器的 GetVarDisplayName 命名约定保持一致。
local function GetEntryVarName(entry)
    if entry.name and entry.name ~= "" then return entry.name end
    if entry.internalName and entry.internalName ~= "" then return entry.internalName end
    local vt = VarOp.VarTypes[entry.varTypeIdx]
    return (vt and vt.name) or "?"
end

-- 辅助：比较两个数据端口是否等价（id 与 name 均相同视为相等）
-- 用于端口自愈比对：端口现为 {id=, name=} 表格式，不能直接使用 ~= 引用比较
local function PortDataEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return (a.id or "") == (b.id or "") and (a.name or "") == (b.name or "")
end

-- 辅助：按类型引用构造携带变量名的端口数据 {id=, name=}
local function BuildPortData(ref, name)
    return { id = ref.id, name = (name and name ~= "") and name or ref.name }
end

-- 辅助：同步已存在数据连接的变量名（变量名修改后，数据线传输名保持一致）
-- 端口索引与数据线 fromPortIndex 一一对应，取对应端口的 name 回写连接
local function SyncConnectionVarNames(node, ports)
    local editor = node.editor
    if not editor or not editor.dataConnections then return end
    for _, conn in ipairs(editor.dataConnections) do
        if conn.fromNode == node.id then
            local port = ports[conn.fromPortIndex]
            if port and port.name then
                conn.variableName = port.name
            end
        end
    end
end

-- 辅助：重建输出数据端口（每个变量创建一个输出点）
-- 端口格式为 {id=类型id, name=变量显示名}，使数据线能传输变量名，
-- 悬停提示（cl_ine_node_drawing.lua DrawDataPorts）显示 posData.data.name 即变量名。
local function RebuildOutputPorts(node)
    if not node then return end
    local newSelection = {}
    if node.data and node.data._varEntries then
        for _, entry in ipairs(node.data._varEntries) do
            local vt = VarOp.VarTypes[entry.varTypeIdx]
            if vt and vt.dataTypeRef then
                table.insert(newSelection, BuildPortData(vt.dataTypeRef, GetEntryVarName(entry)))
            end
        end
    end
    node.selectedOutputTypes = newSelection
    SyncConnectionVarNames(node, newSelection)
    if node.editor then
        INE:UpdateDataPortPositions(node.editor, node, "output")
    end
end

-- 辅助：确保"设置变量"节点保持默认数据输入点（数字 + 数组）
-- 数据输入点用于接入变量引用/值（templates.md L1147"数据线接入"：接入数据线立即按规则创建设置行）。
-- 原实现清空输入端口（旧设计"设置变量不生成数据输入点"），已按模板设计改为保留 n/g 默认输入点，
-- 用户仍可通过"+"按钮追加其他类型输入点（availableInputTypes = allTypes）。
local function EnsureSetVarInputPorts(node)
    if not node then return end
    node.selectedInputTypes = node.selectedInputTypes or {}
    local cur = node.selectedInputTypes
    for _, ref in ipairs({ VarOp.TypeRefs.n, VarOp.TypeRefs.g }) do
        if ref then
            local exists = false
            for _, p in ipairs(cur) do
                local pid = (type(p) == "table" and p.id) or p
                if pid == ref.id then exists = true break end
            end
            if not exists then
                table.insert(cur, BuildPortData(ref, nil))
            end
        end
    end
end

-- 辅助："设置变量"数据输入点接入数据线时，自动创建设置行（目标 = 刚接入的变量）
-- 已存在目标相同变量的设置行时仅更新来源为数据线（templates.md L1147"数据线接入"）。
-- 由 cl_ine_input_handling.lua 数据连接创建成功后调用（toPort.node.type == "var_set" 时触发）。
function VarOp.SetAutoFillFromWire(editor, node, connId, dataType, varName)
    if not node or not node.data then return end
    -- 数据线 dataType 为 INE 端口类型 id（布尔为 p），转回 VarTypes.id（b）后存入条目
    if dataType == "p" then dataType = "b" end
    if not VarOp.TypeRefs[dataType] then dataType = "n" end
    node.data._setEntries = node.data._setEntries or {}
    varName = varName or ""
    -- 对象类别提取：数据线只传变量名，能从编辑器对象变量中匹配到原始条目时区分
    -- 单位/指令反制/空对象（templates.md L1106-1111）；匹配不到按单位兜底
    local entryObjMode = nil
    if dataType == "e" and editor and editor.variables and editor.variables["e"] then
        for _, v in ipairs(editor.variables["e"]) do
            if VarOp.GetVarDisplayName(v) == varName then
                entryObjMode = GetObjModeFromVar({raw = v})
                break
            end
        end
    end
    for _, e in ipairs(node.data._setEntries) do
        if e.varName == varName and e.varType == dataType then
            e.source = "input"
            e.connId = connId
            e.opIdx = e.opIdx or 1
            if dataType == "e" and entryObjMode then e.objMode = entryObjMode end
            if e.value == nil then e.value = SetEntryDefaultValue(dataType) end
            return
        end
    end
    node.data._nextEntryId = node.data._nextEntryId or 1
    table.insert(node.data._setEntries, {
        id = "sv" .. node.data._nextEntryId,
        varName = varName,
        varType = dataType,
        objMode = entryObjMode,
        source = "input",
        connId = connId,
        opIdx = 1,
        value = SetEntryDefaultValue(dataType),
    })
    node.data._nextEntryId = node.data._nextEntryId + 1
end

-- 辅助：获取变量的显示名称（优先使用 name 字段，降级到 internalName）
function VarOp.GetVarDisplayName(v)
    if v.name and v.name ~= "" then return v.name end
    if v.internalName and v.internalName ~= "" then return v.internalName end
    return "?"
end

-- 辅助：颜色线性插值（用于渐变边框）
local function LerpColor(c1, c2, t)
    return Color(
        math.floor(c1.r + (c2.r - c1.r) * t),
        math.floor(c1.g + (c2.g - c1.g) * t),
        math.floor(c1.b + (c2.b - c1.b) * t)
    )
end

-- 辅助：沿矩形边缘绘制彩色渐变边框（颜色序列循环过渡，表示所有变量类型）
-- 调用两次（外圈 + 内缩 1px）可得到 2px 渐变边框。
local function DrawGradientBorder(x, y, w, h, colors)
    local n = #colors
    if n < 2 then return end
    local perim = 2 * (w + h)
    local steps = math.max(48, math.floor(perim / 2))
    local prevX, prevY
    for i = 0, steps do
        local t = i / steps
        local dist = t * perim
        local px, py
        if dist < w then
            px, py = x + dist, y
        elseif dist < w + h then
            px, py = x + w, y + (dist - w)
        elseif dist < 2 * w + h then
            px, py = x + w - (dist - w - h), y + h
        else
            px, py = x, y + h - (dist - 2 * w - h)
        end
        local seg = t * (n - 1) + 1
        local idx = math.min(math.floor(seg), n)
        local frac = seg - math.floor(seg)
        local c1 = colors[math.min(idx, n)]
        local c2 = colors[math.min(idx + 1, n)]
        local col = LerpColor(c1, c2, frac)
        if prevX then
            surface.SetDrawColor(col)
            surface.DrawLine(prevX, prevY, px, py)
        end
        prevX, prevY = px, py
    end
end

-- 辅助：按像素宽度裁剪文本（UTF-8 安全，超出加省略号）
local function ClipTextWidth(text, maxW, font)
    surface.SetFont(font)
    if surface.GetTextSize(text) <= maxW then return text end
    local out = ""
    local i = 1
    while i <= #text do
        local byte = text:byte(i)
        local cb = 1
        if byte >= 240 then cb = 4
        elseif byte >= 224 then cb = 3
        elseif byte >= 128 then cb = 2
        end
        local ch = text:sub(i, i + cb - 1)
        if surface.GetTextSize(out .. ch .. "…") > maxW then
            break
        end
        out = out .. ch
        i = i + cb
    end
    if out == "" then return "…" end
    return out .. "…"
end

-- 辅助：变量选择器浮层（GlobalVarSelector）尺寸估算
-- 固定高度：搜索行 + 5 行矩阵 + 分页导航行 + 上下内边距。
-- 浮层不参与节点宽高计算（下拉框不是永久组件），节点在未选定时保持纯按钮高度。
local function GVSLayout(scale)
    local rowH = math.max(16, math.floor(22 * scale))
    local navH = math.max(18, math.floor(24 * scale))
    local padTop = math.max(2, math.floor(4 * scale))
    local padBottom = math.max(2, math.floor(4 * scale))
    local searchGap = math.max(2, math.floor(3 * scale))
    local popupH = padTop + rowH + searchGap + rowH * 5 + navH + padBottom
    return rowH, navH, popupH
end

-- 打开全局变量选择器浮层（"设置变量"节点与"判断变量关系"条件行共用）
-- 浮层绘制在 DrawAllEditors 的浮层阶段（所有节点之上），打开/选择/关闭均不触发节点宽高重算。
-- @param  x,y,w      {number}  浮层锚定屏幕坐标（调用方按节点内容区换算，w 为浮层宽度）
-- @param  mode       {string}  "set"（设置变量）/ "eval"（判断变量关系）
-- @param  condIdx    {number|nil} eval 模式的条件行索引
-- @param  side       {string|nil} eval 模式的 "left"/"right"
-- @param  filterType {string|nil} 仅显示指定类型（eval 右操作数同类型比较用）
-- @param  extraGroups{table|nil}  附加分组（eval 左操作数的数据线输入）
-- @param  onSelect   {function} 选中回调 onSelect(varName, dataType, v)
-- @param  onClose    {function} 关闭回调（浮层自身生命周期由 Canvas.GlobalVarSelector 管理）
function VarOp.OpenGlobalVarSelector(editor, node, x, y, w, scale, mode, condIdx, side, filterType, extraGroups, onSelect, onClose)
    local rowH, navH, popupH = GVSLayout(scale)
    -- 屏幕边界钳制
    local popupX = x
    local popupY = y
    if popupX + w > ScrW() - 8 then popupX = ScrW() - w - 8 end
    if popupX < 4 then popupX = 4 end
    if popupY + popupH > ScrH() - 8 then popupY = ScrH() - popupH - 8 end
    if popupY < 4 then popupY = 4 end
    -- 关闭可能已展开的普通下拉框，避免与浮层冲突
    Canvas.ExpandedDropdown = nil
    Canvas.ExpandedDropdownInfo = nil
    -- 失活节点内联输入框（避免其 DTextEntry 与浮层搜索框 DTextEntry 抢焦点）
    if VarOp.InputState then VarOp.InputState.active = false end
    Canvas.GlobalVarSelector = {
        mode = mode, node = node, editor = editor,
        condIdx = condIdx, side = side,
        filterType = filterType, extraGroups = extraGroups,
        onSelect = onSelect, onClose = onClose,
        x = popupX, y = popupY, w = w, h = popupH,
        rowH = rowH, scale = scale,
        searchText = "", searchActive = false, page = 1,
        -- 打开当帧的点击是"打开动作"本身，不触发外部关闭（浮层绘制阶段消费一次）
        _skipClickClose = true,
        -- 供 Think 消费滚轮标志防止画布缩放（cl_ine_input_handling.lua）
        _filterAreaX = popupX, _filterAreaY = popupY,
        _filterAreaW = w, _filterAreaH = popupH,
    }
end

-- 绘制全局变量选择器浮层（由 INE:DrawAllEditors 在浮层阶段调用）
-- 布局：顶部搜索行（glua-input-field 透明 DTextEntry 捕获 IME 中文输入）→ 5×5 变量矩阵 → 底部翻页导航。
-- 矩阵样式：彩色渐变边框 + 每行左侧类型色竖条 + 类型切换立即换行 + 类型块首行左侧类型标签；
-- 搜索机制仿 NumericVarPopup：基于转译显示名过滤（大小写不敏感），搜索变化重置 page=1。
function VarOp.DrawGlobalVarSelectorPopup()
    local popup = Canvas.GlobalVarSelector
    -- 浮层关闭时兜底清理搜索框（Think 生命周期也会清理，双重保障）
    if not popup then
        local e = Canvas._gvsSearchEntry
        if e and IsValid(e) then e:Remove() end
        Canvas._gvsSearchEntry = nil
        return
    end
    local editor, node = popup.editor, popup.node
    if not editor or not node then
        local e = Canvas._gvsSearchEntry
        if e and IsValid(e) then e:Remove() end
        Canvas._gvsSearchEntry = nil
        Canvas.GlobalVarSelector = nil
        return
    end

    local mX, mY = gui.MouseX(), gui.MouseY()
    local click = INE._frameMouseJustPressed or false
    local scale = popup.scale or 1
    local smallFont = GetScaledFont(scale, 12)
    local selectorBg = Color(35, 40, 45)

    -- 悬停提示状态（挂浮层运行时字段，浮层关闭即重置）
    -- lastSeen 记录浮层最后被绘制的时刻：关闭后重新打开（间隔 > 0.4s）时重置悬停计时
    local hover = popup._hover or { key = nil, enter = 0, alpha = 0 }
    local now = SysTime()
    if hover.lastSeen and now - hover.lastSeen > 0.4 then
        hover.key, hover.enter, hover.alpha = nil, 0, 0
    end
    hover.lastSeen = now
    popup._hover = hover

    -- 缩放后的布局常量
    local rowH = popup.rowH or math.max(16, math.floor(22 * scale))
    local padX = math.max(4, math.floor(6 * scale))       -- 左右内边距
    local padTop = math.max(2, math.floor(4 * scale))
    local padBottom = math.max(2, math.floor(4 * scale))
    local barW = math.max(3, math.floor(4 * scale))        -- 左侧类型竖条宽
    local gapBar = math.max(2, math.floor(4 * scale))      -- 竖条与格子间距
    local cellGap = math.max(2, math.floor(3 * scale))     -- 格子间距
    local searchGap = math.max(2, math.floor(3 * scale))   -- 搜索行与矩阵间距
    local navH = math.max(18, math.floor(24 * scale))      -- 分页导航行高
    local px, py, pw, ph = popup.x, popup.y, popup.w, popup.h

    -- ============ 搜索文本（搜索行绘制与过滤共用，提前定义） ============
    local searchText = popup.searchText or ""

    -- ============ 收集变量 ============
    -- 遍历 VarOp.VarTypes 确保每个类型都有入口（filterType 时只收该类型）
    local varGroups = {}
    for _, vt in ipairs(VarOp.VarTypes) do
        -- filterType 为 INE 数据类型 id（如 "p"），与 VarTypes.id（如 "b"）经 DATA_TYPE_MAP 对齐比较
        if not popup.filterType or (DATA_TYPE_MAP[vt.id] or vt.id) == popup.filterType then
            local tid = vt.id
            -- 分组键与 dataType 统一使用 INE 数据类型 id（VarTypes.id 经 DATA_TYPE_MAP 映射，如 b→p），
            -- 保证能读取玩家自建变量（editor.variables 以 INE id 为键，布尔为 "p"）
            local varKey = DATA_TYPE_MAP[tid] or tid
            local dt = INE and INE.GetDataTypeById and INE.GetDataTypeById(varKey)
            local g = {vars = {}, typeColor = dt and dt.color or vt.color, typeName = dt and dt.name or vt.name}
            varGroups[varKey] = g
            -- 用户自定义全局变量
            if editor and editor.variables and editor.variables[varKey] then
                for _, v in ipairs(editor.variables[varKey]) do
                    local dName = VarOp.GetVarDisplayName(v)
                    table.insert(g.vars, {name = dName, internalName = v.internalName, dataType = varKey, raw = v})
                end
            end
            -- 卡牌专属固定变量（每张卡牌固有；unitOnly 数字仅单位卡编辑时展示，
            -- 数据层运行时按卡牌实际类型取值，此处仅编辑期展示过滤）
            if KARDS.NodeParser and KARDS.NodeParser.CARD_FIXED_VARS then
                local fixedList = KARDS.NodeParser.CARD_FIXED_VARS[varKey]
                if fixedList then
                    for _, fv in ipairs(fixedList) do
                        if not fv.unitOnly or VarOp.IsEditingUnit() then
                            local opt = {name = fv.name, internalName = fv.key, dataType = varKey, fixed = true}
                            if varKey == "e" then
                                -- raw 供 GetObjModeFromVar 按当前编辑卡牌类型分派对象操作集（单位/指令反制）
                                opt.raw = {_mode = "saved", cardAppearance = KARDS.CardEditor.Canvas.CardAppearance}
                            else
                                opt.raw = {fixed = true}
                            end
                            table.insert(g.vars, opt)
                        end
                    end
                end
            end
        end
    end
    -- 变量库默认变量（全部类型：n/b/t/g/eg，filterType 时只收该类型）
    if KARDS.VarLib and KARDS.VarLib.GetVarPathsByType then
        local libByType = KARDS.VarLib.GetVarPathsByType("1")
        -- typeMap 的值为 INE 数据类型 id（b→p），与 varGroups 分组键/玩家变量键一致
        local typeMap = { n = "n", b = "p", t = "t", g = "g", eg = "e" }
        for libTid, paths in pairs(libByType) do
            local varKey = typeMap[libTid]
            if varKey and (not popup.filterType or varKey == popup.filterType) and varGroups[varKey] then
                for _, vp in ipairs(paths) do
                    local libName = KARDS.VarLib.GetDisplayName(vp)  -- 转译为中文显示名
                    table.insert(varGroups[varKey].vars, {name = libName, internalName = vp, dataType = varKey})
                end
            end
        end
    end

    -- ============ 搜索过滤（基于转译后显示名，大小写不敏感） ============
    if searchText ~= "" then
        for tid, g in pairs(varGroups) do
            local filtered = {}
            for _, v in ipairs(g.vars) do
                if (v.name or ""):find(searchText, 1, true) then
                    table.insert(filtered, v)
                end
            end
            g.vars = filtered
        end
    end

    -- ============ 构建行序列 ============
    -- 每行最多 5 个选项；类型切换立即换行（每个类型块独立起行），
    -- 每个类型块的首行携带类型标签（label）。
    local rows = {}
    local function AddBlock(items, typeColor, typeName, typeId)
        local isFirstRow = true
        local row
        for i, v in ipairs(items) do
            if (i - 1) % 5 == 0 then
                row = { type = typeId, typeColor = typeColor, typeName = typeName, items = {} }
                if isFirstRow then row.label = typeName end
                isFirstRow = false
                table.insert(rows, row)
            end
            table.insert(row.items, v)
        end
    end
    -- 附加分组（如"判断变量关系"的数据线输入，置顶显示，竖条用分组色）
    if popup.extraGroups then
        for _, eg in ipairs(popup.extraGroups) do
            if eg.items and #eg.items > 0 then
                AddBlock(eg.items, eg.color or Color(100, 160, 220), eg.title, "ext")
            end
        end
    end
    for _, vt in ipairs(VarOp.VarTypes) do
        local g = varGroups[DATA_TYPE_MAP[vt.id] or vt.id]
        if g and #g.vars > 0 then
            AddBlock(g.vars, g.typeColor, g.typeName, DATA_TYPE_MAP[vt.id] or vt.id)
        end
    end

    -- ============ 分页计算（每页 5 行） ============
    local rowsPerPage = 5
    local totalPages = math.max(1, math.ceil(#rows / rowsPerPage))
    local page = math.min(popup.page or 1, totalPages)
    popup.page = page
    local startRow = (page - 1) * rowsPerPage + 1
    local endRow = math.min(startRow + rowsPerPage - 1, #rows)

    -- 渐变边框颜色序列（全部变量类型颜色）
    local gradColors = {}
    for _, vt in ipairs(VarOp.VarTypes) do
        table.insert(gradColors, vt.color)
    end

    -- ============ 滚轮翻页（浮层内消费滚轮，阻止画布缩放） ============
    -- _wheelScroll 由 CreateMove 钩子设置，Think 已通过 _filterArea 阻止画布缩放
    local wheelScroll = popup._wheelScroll
    popup._wheelScroll = nil
    if totalPages > 1 and mX >= px and mX <= px + pw and mY >= py and mY <= py + ph then
        if wheelScroll == "up" then
            page = math.max(1, page - 1)
        elseif wheelScroll == "down" then
            page = math.min(totalPages, page + 1)
        end
        popup.page = page
        startRow = (page - 1) * rowsPerPage + 1
        endRow = math.min(startRow + rowsPerPage - 1, #rows)
    end

    -- ============ 绘制背景 + 彩色渐变边框（2 层：外圈 + 内缩 1px） ============
    draw.RoundedBox(3, px, py, pw, ph, selectorBg)
    DrawGradientBorder(px, py, pw, ph, gradColors)
    DrawGradientBorder(px + 1, py + 1, pw - 2, ph - 2, gradColors)

    -- ============ 顶部搜索行（在背景之后绘制，激活亮背景+蓝色描边，未激活暗背景） ============
    local searchX = px + 4
    local searchY = py + padTop
    local inputW = pw - 8
    local inputH = rowH - 2
    local isSearchActive = popup.searchActive or false
    if isSearchActive then
        draw.RoundedBox(3, searchX, searchY, inputW, inputH, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(searchX, searchY, inputW, inputH)
    else
        draw.RoundedBox(3, searchX, searchY, inputW, inputH, Color(40, 40, 40))
    end
    if searchText == "" then
        draw.SimpleText("搜索变量...", smallFont, searchX + 6, searchY + inputH / 2,
            isSearchActive and Color(180, 180, 180) or Color(120, 120, 120),
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(searchText, smallFont, searchX + 6, searchY + inputH / 2,
            COL_TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    -- 闪烁光标（激活时）
    if isSearchActive and math.floor(SysTime() * 2) % 2 == 0 then
        surface.SetFont(smallFont)
        local cursorX = searchX + 6 + surface.GetTextSize(searchText)
        surface.SetDrawColor(Color(200, 200, 200))
        surface.DrawLine(cursorX, searchY + 3, cursorX, searchY + inputH - 3)
    end

    -- 内容区：搜索行下方固定 5 行矩阵 + 底部导航
    local contentY = py + padTop + rowH + searchGap
    local contentH = rowH * 5
    local navY = contentY + contentH

    -- 类型标签区宽度：本页所有类型块首行标签的最大文本宽度（固定宽度保证各行竖条对齐）
    local maxLabelW = 0
    for i = startRow, endRow do
        local r = rows[i]
        if r.label then
            surface.SetFont(smallFont)
            maxLabelW = math.max(maxLabelW, surface.GetTextSize(r.label))
        end
    end
    local typeNameW = maxLabelW + 8  -- 左右各留 4px
    -- 布局：类型名区（左）→ 竖条 → 格子区；格子宽度按类型名区扣减后重算
    local cellsStartX = px + padX + typeNameW + barW + gapBar
    local cellW = math.max(8, (pw - padX * 2 - typeNameW - barW - gapBar - cellGap * 4) / 5)

    if #rows == 0 then
        -- 空列表兜底（无变量或搜索无匹配）
        draw.SimpleText(searchText ~= "" and "无匹配变量" or "(暂无变量)", smallFont,
            px + pw / 2, contentY + contentH / 2,
            Color(100, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    else
        -- ============ 逐行绘制本页选项矩阵 ============
        local drawY = contentY
        local hoveredCell = nil  -- 本帧悬停的格子（供延迟淡入 tooltip 使用）
        for i = startRow, endRow do
            local r = rows[i]
            local rowY = drawY
            -- 类型标签：仅类型块首行；半透明同色矩形绘制在竖条左侧（顶边与竖条对齐），文字居中
            if r.label then
                draw.RoundedBox(2, px + padX, rowY, typeNameW, rowH,
                    Color(r.typeColor.r * 0.4, r.typeColor.g * 0.4, r.typeColor.b * 0.4, 110))
                draw.SimpleText(r.label, smallFont, px + padX + typeNameW / 2, rowY + rowH / 2,
                    r.typeColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
            -- 左侧类型色竖条（同页同类型统一颜色；位于类型名区右侧，所有行对齐）
            surface.SetDrawColor(r.typeColor)
            surface.DrawRect(px + padX + typeNameW, rowY, barW, rowH)
            -- 5 列选项格子
            for ci, v in ipairs(r.items) do
                local cellX = cellsStartX + (ci - 1) * (cellW + cellGap)
                local cellHov = mX >= cellX and mX <= cellX + cellW
                            and mY >= rowY and mY <= rowY + rowH
                if cellHov then
                    draw.RoundedBox(3, cellX, rowY, cellW, rowH,
                        Color(r.typeColor.r * 0.2, r.typeColor.g * 0.2, r.typeColor.b * 0.2, 160))
                    hoveredCell = { key = i .. "_" .. ci, name = v.name, color = r.typeColor,
                                    x = cellX, y = rowY, w = cellW, h = rowH }
                end
                draw.SimpleText(ClipTextWidth(v.name, cellW - 4, smallFont), smallFont,
                    cellX + cellW / 2, rowY + rowH / 2, COL_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                if click and cellHov and not Canvas.DraggingNode then
                    if popup.onSelect then popup.onSelect(v.name, v.dataType, v) end
                    -- 选中后关闭浮层（先清理搜索框再置空）
                    local e = Canvas._gvsSearchEntry
                    if e and IsValid(e) then e:Remove() end
                    Canvas._gvsSearchEntry = nil
                    Canvas.GlobalVarSelector = nil
                    if popup.onClose then popup.onClose() end
                    return
                end
            end
            drawY = rowY + rowH
        end

        -- ============ 悬停提示：延迟淡入临时矩形（覆盖原选项位置、长度自适应变量全名），全名靠上方显示 ============
        if hoveredCell then
            if hover.key ~= hoveredCell.key then
                hover.key, hover.enter, hover.alpha = hoveredCell.key, now, 0
            end
            if now - hover.enter >= 0.45 then
                hover.alpha = math.min(1, hover.alpha + FrameTime() * 6)
            end
            if hover.alpha > 0 then
                local tipW = GetTW(hoveredCell.name, smallFont) + padX * 2
                local tipX = hoveredCell.x
                if tipX + tipW > px + pw - padX then
                    tipX = px + pw - padX - tipW  -- 超出右边界时向左收缩
                end
                local a = math.floor(hover.alpha * 220)
                draw.RoundedBox(2, tipX, hoveredCell.y, tipW, hoveredCell.h, Color(28, 32, 36, a))
                surface.SetDrawColor(hoveredCell.color.r, hoveredCell.color.g, hoveredCell.color.b, a)
                surface.DrawLine(tipX, hoveredCell.y, tipX + tipW, hoveredCell.y)
                draw.SimpleText(hoveredCell.name, smallFont,
                    tipX + tipW / 2, hoveredCell.y + 2,
                    Color(255, 255, 255, math.min(255, a + 35)), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
            end
        else
            hover.key, hover.alpha = nil, 0
        end
    end

    -- ============ 底部导航（左右箭头 + 页码） ============
    local navCenterX = px + pw / 2
    local charW = GetTW("字", smallFont)
    if page > 1 then
        local leftArrowX = navCenterX - charW * 4
        local leftArrowY = navY + navH / 2
        local arrowHov = mX >= leftArrowX - 10 and mX <= leftArrowX + 10
                     and mY >= navY and mY <= navY + navH
        surface.SetDrawColor(arrowHov and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY - 4)
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY + 4)
        if click and arrowHov and not Canvas.DraggingNode then
            popup.page = page - 1
        end
    end
    draw.SimpleText(page .. "/" .. totalPages, smallFont, navCenterX, navY + navH / 2,
        Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if page < totalPages then
        local rightArrowX = navCenterX + charW * 4
        local rightArrowY = navY + navH / 2
        local arrowHov = mX >= rightArrowX - 10 and mX <= rightArrowX + 10
                     and mY >= navY and mY <= navY + navH
        surface.SetDrawColor(arrowHov and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY - 4)
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY + 4)
        if click and arrowHov and not Canvas.DraggingNode then
            popup.page = page + 1
        end
    end

    -- ============ 点击检测：搜索框焦点 / 外部关闭 ============
    -- 打开当帧的点击是"打开动作"本身，不触发外部关闭（_skipClickClose 仅消费一次）
    local skipClose = popup._skipClickClose or false
    popup._skipClickClose = false
    if click and not Canvas.DraggingNode then
        if mX >= searchX and mX <= searchX + inputW
           and mY >= searchY and mY <= searchY + inputH then
            -- 点击搜索框 → 激活（Think 创建透明 DTextEntry 捕获 IME 输入）
            popup.searchActive = true
        else
            local inPopup = mX >= px and mX <= px + pw and mY >= py and mY <= py + ph
            if inPopup then
                -- 点击浮层内非搜索区域 → 失活搜索框
                popup.searchActive = false
            elseif not skipClose then
                -- 点击浮层外 → 关闭
                local e = Canvas._gvsSearchEntry
                if e and IsValid(e) then e:Remove() end
                Canvas._gvsSearchEntry = nil
                Canvas.GlobalVarSelector = nil
                if popup.onClose then popup.onClose() end
            end
        end
    end
end

-- 打开词条多选浮层（"设置变量"节点"词条"操作的值控件，templates.md L1122）
-- 浮层状态挂 Canvas.KeywordMultiSelect，由 INE:DrawAllEditors 浮层阶段调用 DrawKeywordMultiSelect 绘制。
-- 每行一个词条（中文显示名 + key），点击行切换勾选；滚轮翻页；点击外部/ESC 关闭。
-- 值写入 entry.value（逗号分隔 key 字符串），切换即实时生效。
function VarOp.OpenKeywordMultiSelect(editor, node, entry, entryId, x, y, w, scale)
    local rowH = math.max(16, math.floor(22 * scale))
    local navH = math.max(18, math.floor(24 * scale))
    local padTop = math.max(2, math.floor(4 * scale))
    local padBottom = math.max(2, math.floor(4 * scale))
    local rowsPerPage = 8
    local popupW = math.max(w, math.floor(200 * scale))
    local popupH = padTop + rowH * 2 + rowH * rowsPerPage + navH + padBottom
    local popupX = x
    local popupY = y
    if popupX + popupW > ScrW() - 8 then popupX = ScrW() - popupW - 8 end
    if popupX < 4 then popupX = 4 end
    if popupY + popupH > ScrH() - 8 then popupY = ScrH() - popupH - 8 end
    if popupY < 4 then popupY = 4 end
    Canvas.ExpandedDropdown = nil
    Canvas.ExpandedDropdownInfo = nil
    Canvas.KeywordMultiSelect = {
        editor = editor, node = node, entry = entry, entryId = entryId,
        x = popupX, y = popupY, w = popupW, h = popupH,
        rowH = rowH, scale = scale, page = 1,
        rowsPerPage = rowsPerPage,
        selKeys = ParseKeywordValue(entry and entry.value),
        _skipClickClose = true,
        -- 供 Think 消费滚轮标志防止画布缩放（cl_ine_input_handling.lua）
        _filterAreaX = popupX, _filterAreaY = popupY,
        _filterAreaW = popupW, _filterAreaH = popupH,
    }
end

-- 绘制词条多选浮层（由 INE:DrawAllEditors 在浮层阶段调用）
-- 布局：标题行（词条多选 + 已选数）→ 每页 8 行词条 → 底部导航（页码 + 关闭提示）。
function VarOp.DrawKeywordMultiSelect()
    local kw = Canvas.KeywordMultiSelect
    if not kw then return end
    local editor, node = kw.editor, kw.node
    -- 节点被删除时关闭浮层
    local nodeValid = false
    if editor and editor.nodes and node then
        for _, nd in ipairs(editor.nodes) do
            if nd == node then nodeValid = true break end
        end
    end
    if not nodeValid then
        Canvas.KeywordMultiSelect = nil
        return
    end
    local mX, mY = gui.MouseX(), gui.MouseY()
    local click = INE._frameMouseJustPressed or false
    local scale = kw.scale or 1
    local smallFont = GetScaledFont(scale, 12)
    local rowH = kw.rowH or math.max(16, math.floor(22 * scale))
    local navH = math.max(18, math.floor(24 * scale))
    local padTop = math.max(2, math.floor(4 * scale))
    local px, py, pw, ph = kw.x, kw.y, kw.w, kw.h
    local keys = GetAllKeywordKeys()
    local selKeys = kw.selKeys or {}
    -- 已选计数
    local selCount = 0
    for _ in pairs(selKeys) do selCount = selCount + 1 end

    -- 渐变边框（复用 GVS 同款：全部变量类型颜色）
    local gradColors = {}
    for _, vt in ipairs(VarOp.VarTypes) do
        table.insert(gradColors, vt.color)
    end
    draw.RoundedBox(3, px, py, pw, ph, Color(35, 40, 45))
    DrawGradientBorder(px, py, pw, ph, gradColors)
    DrawGradientBorder(px + 1, py + 1, pw - 2, ph - 2, gradColors)

    -- ============ 标题行 ============
    local titleY = py + padTop
    draw.SimpleText("词条多选", smallFont, px + 6, titleY + rowH / 2,
        COL_TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    draw.SimpleText("已选 " .. selCount .. "/" .. #keys, smallFont, px + pw - 6, titleY + rowH / 2,
        Color(200, 180, 120), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

    -- ============ 滚轮翻页（浮层内消费，阻止画布缩放） ============
    local totalPages = math.max(1, math.ceil(#keys / kw.rowsPerPage))
    local wheel = kw._wheelScroll
    kw._wheelScroll = nil
    if totalPages > 1 and mX >= px and mX <= px + pw and mY >= py and mY <= py + ph then
        if wheel == "up" then kw.page = math.max(1, (kw.page or 1) - 1)
        elseif wheel == "down" then kw.page = math.min(totalPages, (kw.page or 1) + 1) end
    end
    local page = math.min(kw.page or 1, totalPages)
    kw.page = page
    local startIdx = (page - 1) * kw.rowsPerPage + 1
    local endIdx = math.min(startIdx + kw.rowsPerPage - 1, #keys)

    -- ============ 词条行 ============
    local listY = titleY + rowH
    for i = startIdx, endIdx do
        local k = keys[i]
        local name = KARDS.CardEditor.Data.KeywordDisplayNames[k] or k
        local rowY = listY + (i - startIdx) * rowH
        local isSel = selKeys[k] == true
        local rowHov = mX >= px and mX <= px + pw and mY >= rowY and mY <= rowY + rowH
        if rowHov then
            draw.RoundedBox(3, px + 3, rowY, pw - 6, rowH, Color(60, 70, 80))
        end
        -- 勾选框
        local boxX = px + 8
        local boxSize = math.max(10, rowH - 8)
        local boxY = rowY + (rowH - boxSize) / 2
        draw.RoundedBox(2, boxX, boxY, boxSize, boxSize, isSel and Color(120, 180, 120) or Color(55, 55, 55))
        if isSel then
            surface.SetDrawColor(255, 255, 255)
            surface.DrawLine(boxX + 2, boxY + boxSize / 2, boxX + boxSize / 2, boxY + boxSize - 3)
            surface.DrawLine(boxX + boxSize / 2, boxY + boxSize - 3, boxX + boxSize - 2, boxY + 2)
        end
        -- 中文名 + key（右侧灰色小字）
        draw.SimpleText(name, smallFont, boxX + boxSize + 6, rowY + rowH / 2,
            COL_TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText(k, smallFont, px + pw - 8, rowY + rowH / 2,
            Color(110, 110, 110), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        if click and rowHov and not Canvas.DraggingNode then
            if isSel then selKeys[k] = nil else selKeys[k] = true end
            -- 实时写回条目值（按全部词条顺序序列化，保持稳定）
            if kw.entry then kw.entry.value = SerializeKeywordValue(selKeys) end
        end
    end

    -- ============ 底部导航（页码 + 关闭提示） ============
    local navY = listY + kw.rowsPerPage * rowH
    local navCenterX = px + pw / 2
    local charW = GetTW("字", smallFont)
    if page > 1 then
        local arrowX = navCenterX - charW * 4
        local arrowY = navY + navH / 2
        local arrowHov = mX >= arrowX - 10 and mX <= arrowX + 10 and mY >= navY and mY <= navY + navH
        surface.SetDrawColor(arrowHov and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(arrowX - 4, arrowY, arrowX, arrowY - 4)
        surface.DrawLine(arrowX - 4, arrowY, arrowX, arrowY + 4)
        if click and arrowHov and not Canvas.DraggingNode then kw.page = page - 1 end
    end
    draw.SimpleText(page .. "/" .. totalPages, smallFont, navCenterX, navY + navH / 2,
        Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if page < totalPages then
        local arrowX = navCenterX + charW * 4
        local arrowY = navY + navH / 2
        local arrowHov = mX >= arrowX - 10 and mX <= arrowX + 10 and mY >= navY and mY <= navY + navH
        surface.SetDrawColor(arrowHov and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(arrowX + 4, arrowY, arrowX, arrowY - 4)
        surface.DrawLine(arrowX + 4, arrowY, arrowX, arrowY + 4)
        if click and arrowHov and not Canvas.DraggingNode then kw.page = page + 1 end
    end
    draw.SimpleText("点击词条切换 · 外部/ESC 关闭", smallFont, px + 8, navY + navH / 2,
        Color(110, 110, 110), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

    -- ============ 外部点击 / ESC 关闭 ============
    -- 打开当帧的点击是"打开动作"本身，不触发外部关闭（_skipClickClose 仅消费一次）
    local skipClose = kw._skipClickClose or false
    kw._skipClickClose = false
    if input.WasKeyPressed(KEY_ESCAPE) then
        Canvas.KeywordMultiSelect = nil
        return
    end
    if click and not Canvas.DraggingNode then
        local inPopup = mX >= px and mX <= px + pw and mY >= py and mY <= py + ph
        if not inPopup and not skipClose then
            Canvas.KeywordMultiSelect = nil
        end
    end
end

-- ====================================================================================
-- 函数面板连线闪烁动画（templates.md L1088）
-- "新建变量"f 类型"编辑函数"按钮：点击后若函数 INE 面板已打开，从鼠标位置到面板中心
-- 绘制临时线段（函数类型色紫），透明度随时间闪烁约 2 秒后自动消失。
-- 仅视觉引导，非数据线、不产生任何数据连接。由 INE:DrawAllEditorsInternal 在浮层阶段调用。
-- ====================================================================================
VarOp.FunctionLinkFlash = nil  -- {start=SysTime(), x, y, subID}：subID 为函数子编辑器 ID

function VarOp.DrawFunctionLinkFlash()
    local fl = VarOp.FunctionLinkFlash
    if not fl then return end
    local elapsed = SysTime() - fl.start
    if elapsed > 2 then
        VarOp.FunctionLinkFlash = nil
        return
    end
    local sub = fl.subID and INE.Editors and INE.Editors[fl.subID]
    if not sub then
        -- 面板已关闭/不存在 → 动画立即结束
        VarOp.FunctionLinkFlash = nil
        return
    end
    local cx2 = sub.x + (sub.width or 0) / 2
    local cy2 = sub.y + (sub.height or 0) / 2
    -- 透明度：整体随 2 秒线性衰减 + 高频明暗闪烁（闪烁节奏约 12Hz）
    local fade = math.max(0, 1 - elapsed / 2)
    local blinkOn = (math.floor(SysTime() * 12) % 2 == 0)
    local alpha = math.floor(255 * fade * (blinkOn and 1 or 0.35))
    if alpha > 0 then
        surface.SetDrawColor(200, 150, 255, alpha)  -- 函数类型色（紫）
        surface.DrawLine(fl.x, fl.y, cx2, cy2)
    end
end

-- 辅助：将节点上引用指定变量的组件值重置为初始状态
-- 用于删除变量时联动清理：数据线目标节点为普通节点时，
-- 其组件值（如数字槽选中的变量选项）等于被删变量的显示名或内部名则重置为初始值。
-- 注意：普通节点组件存储的变量引用是内部名优先（cl_ine_node_editor.lua 数字槽逻辑），
-- 因此需同时匹配显示名（varName）与内部名（varInternal）。
local function ResetNodeComponentVar(node, varName, varInternal)
    if not (node and node.parsedConfig and node.parsedConfig.components) then return end
    local function resetComp(comp)
        local cur = node.data and node.data[comp.id]
        if cur ~= nil and (tostring(cur) == varName
            or (varInternal and varInternal ~= "" and tostring(cur) == varInternal)) then
            if comp.type == "number" then
                node.data[comp.id] = 0
            elseif comp.type == "text" then
                node.data[comp.id] = ""
            else
                node.data[comp.id] = 1
            end
        end
    end
    for _, comp in ipairs(node.parsedConfig.components) do
        if comp.type == "if" then
            if comp.branches then
                for _, branch in ipairs(comp.branches) do
                    if branch.components then
                        for _, subComp in ipairs(branch.components) do
                            resetComp(subComp)
                        end
                    end
                end
            end
        else
            resetComp(comp)
        end
    end
end

-- 辅助：删除新建变量节点中的一个变量条目（点击条目"-"按钮触发）
-- 联动清理：
--   1. 断开从该输出点发出的所有数据线（fromPortIndex 对应条目索引），后续端口索引前移
--   2. 基础变量系统节点联动：
--      - 转换与提取（var_convert）：撤回操作行（重置操作索引），输入断开后输出数据点由自愈逻辑清空
--      - 设置变量（var_set）：目标变量名匹配被删变量时撤回操作行（清空目标与端口）
--   3. 其他节点：将与变量关联的组件值重置为初始状态
local function RemoveVarEntry(node, entryIdx)
    if not node or not node.data or not node.data._varEntries then return end
    local editor = node.editor
    local entries = node.data._varEntries
    local entry = entries[entryIdx]
    if not entry then return end
    local deletedName = GetEntryVarName(entry)
    local deletedInternal = entry.internalName or ""

    -- 断开从被删输出点发出的数据线，并记录受影响的目标节点 ID（去重）
    -- 注意：dataConnections 的 fromNode/toNode 存的是节点 ID（见 cl_ine_input_handling.lua
    -- 连接创建处 fromNode = fromPort.node.id），联动清理时需经 editor.nodes 反查节点引用。
    local affectedToNodeIds = {}
    if editor and editor.dataConnections then
        local i = 1
        while i <= #editor.dataConnections do
            local conn = editor.dataConnections[i]
            if conn.fromNode == node.id then
                if conn.fromPortIndex == entryIdx then
                    local already = false
                    for _, tnId in ipairs(affectedToNodeIds) do
                        if tnId == conn.toNode then already = true break end
                    end
                    if not already then table.insert(affectedToNodeIds, conn.toNode) end
                    table.remove(editor.dataConnections, i)
                else
                    if conn.fromPortIndex > entryIdx then
                        conn.fromPortIndex = conn.fromPortIndex - 1
                    end
                    i = i + 1
                end
            else
                i = i + 1
            end
        end
    end

    -- 移除条目
    table.remove(entries, entryIdx)

    -- 联动清理受影响的目标节点（按 ID 从 editor.nodes 反查节点引用）
    for _, tnId in ipairs(affectedToNodeIds) do
        local tn = nil
        if editor and editor.nodes then
            for _, n in ipairs(editor.nodes) do
                if n.id == tnId then tn = n break end
            end
        end
        if tn and tn.data then
            if tn.type == "var_convert" then
                -- 撤回操作行：重置操作索引，输入断开后输出数据点自动清空
                tn.data._selectedOpIdx = nil
            elseif tn.type == "var_set" then
                -- 移除引用被删变量的设置行（多设置行按 varName 匹配，source 为 global 或 input 均移除）
                local sEntries = tn.data._setEntries
                if sEntries then
                    for i = #sEntries, 1, -1 do
                        local se = sEntries[i]
                        if se.varName == deletedName
                            or (deletedInternal ~= "" and se.varName == deletedInternal) then
                            table.remove(sEntries, i)
                        end
                    end
                end
            elseif tn.type == "var_evaluate" then
                -- 撤回引用被删变量的条件行：
                -- 旧数据（left/right 为字符串）重置为默认文本；新结构（左/右操作数槽）重置为未选择状态
                local conds = tn.data._conditions
                if conds then
                    for ci, cond in ipairs(conds) do
                        local didReset = false
                        if type(cond.left) ~= "table" then
                            if cond.left == deletedName
                                or (deletedInternal ~= "" and cond.left == deletedInternal) then
                                cond.left = "变量" .. ci
                                didReset = true
                            end
                        else
                            -- 数据线输入行（source="input"）的值来自数据线连接，不受全局变量删除影响
                            if (cond.left.source or "global") ~= "input" then
                                local ln = cond.left.varName or ""
                                if ln == deletedName
                                    or (deletedInternal ~= "" and ln == deletedInternal) then
                                    cond.left = { source = "global", varName = "", dataType = "" }
                                    didReset = true
                                end
                            end
                        end
                        if type(cond.right) ~= "table" then
                            if cond.right == deletedName
                                or (deletedInternal ~= "" and cond.right == deletedInternal) then
                                cond.right = "值"
                                didReset = true
                            end
                        elseif (cond.right.mode or "") == "var" then
                            -- 仅 var 模式匹配变量引用；literal 模式（字面量）不受影响
                            local rn = cond.right.varName or ""
                            if rn == deletedName
                                or (deletedInternal ~= "" and rn == deletedInternal) then
                                cond.right.varName = ""
                                cond.right.dataType = ""
                                didReset = true
                            end
                        end
                        -- 被重置的条件行若展开着选择器则一并关闭
                        if didReset and tn.data._condSelector
                            and tn.data._condSelector.condIdx == ci then
                            tn.data._condSelector = nil
                        end
                    end
                end
            else
                -- 其他节点：将与变量关联的组件值重置为初始状态
                ResetNodeComponentVar(tn, deletedName, deletedInternal)
            end
        end
    end

    -- 重建输出端口（移除被删条目的数据输出点）
    if node.editor then
        RebuildOutputPorts(node)
    end
end

-- 辅助：动态计算节点高度
local function RecalcVarHeight(node, baseH, entries, rowH, padding, spacing, btnH)
    -- f 类型条目多一行（函数预览 + 编辑函数按钮），其余条目固定 3 行
    local total = 0
    for _, e2 in ipairs(entries) do
        local v2 = VarOp.VarTypes[e2.varTypeIdx]
        local eH2 = ((v2 and v2.id == "f") and (rowH * 4 + padding * 3)) or (rowH * 3 + padding * 2)
        total = total + eH2 + spacing
    end
    node.height = math.max(baseH or 100, 40 + total + btnH + 10)
end

-- ====================================================================================
-- 注册所有变量操作节点
-- ====================================================================================
function VarOp.RegisterAll()
    InitTypeRefs()

    local allTypes = {}
    for _, ref in pairs(VarOp.TypeRefs) do
        table.insert(allTypes, ref)
    end

    --[[ 正式版内容：新建变量节点（var_create）测试版放弃实现（templates.md 标注"正式版再做"）
    -- CreateVariable
    -- outputTypes = allTypes 让 INE 系统知道支持的数据类型（用于绘制端口图标等），
    -- availableOutputTypes = {} 防止 INE 显示"添加数据点"按钮，
    -- 输出端口数量完全由 RebuildOutputPorts 根据 _varEntries 动态管理。
    LogNewNode({
        type = "var_create",
        name = "新建变量",
        color = Color(70, 150, 200),
        width = 280, height = 100,
        hasInput = false, hasOutput = true,
        outputTypes = allTypes,
        availableOutputTypes = {},
        drawFunction = VarOp.DrawCreateVariable,
        dataFields = {_nextVarId = 1},
    }, "create_variable")
    ]]

    -- SetVariable
    LogNewNode({
        type = "var_set",
        name = "设置变量",
        color = Color(200, 140, 60),
        width = 300, height = 100,
        hasInput = true, hasOutput = true,
        inputTypes = allTypes,
        outputTypes = allTypes,
        availableInputTypes = allTypes,
        -- availableOutputTypes = {} 防止 INE 显示"添加数据点"按钮，
        -- 全局变量可被任何节点直接使用，设置变量节点不生成数据输出端口（仅保留输入端口，值接入）
        availableOutputTypes = {},
        drawFunction = VarOp.DrawSetVariable,
        dataFields = {_setEntries = {}, _nextEntryId = 1},
    }, "set_variable")

    --[[ 正式版内容：转换与提取节点（var_convert）测试版放弃实现（templates.md 标注"正式版再做"；
    -- 暂以既有节点"获取单位防御力""获取单位攻击力"替代）
    -- ConvertExtractVariable
    LogNewNode({
        type = "var_convert",
        name = "转换与提取",
        color = Color(100, 180, 140),
        width = 280, height = 80,
        hasInput = true, hasOutput = true,
        inputTypes = {VarOp.TypeRefs.n, VarOp.TypeRefs.g, VarOp.TypeRefs.t},
        outputTypes = {VarOp.TypeRefs.n, VarOp.TypeRefs.t, VarOp.TypeRefs.p or VarOp.TypeRefs.b},
        availableInputTypes = {VarOp.TypeRefs.n, VarOp.TypeRefs.g, VarOp.TypeRefs.t},
        -- availableOutputTypes = {} 防止 INE 显示"添加数据点"按钮，
        -- 输出数据点完全由 DrawConvertExtractVariable 末尾的自动接管逻辑管理（类型 + 变量名）
        availableOutputTypes = {},
        drawFunction = VarOp.DrawConvertExtractVariable,
        dataFields = {},
    }, "convert_extract_variable")
    ]]

    -- EvaluateRelationship
    -- hasInput = true（执行输入点，接收上游执行链触发）/ hasOutput = true（执行输出点，串联下游）
    -- inputTypes = allTypes 供 INE 端口系统参考，availableInputTypes = allTypes 显示标准"添加数据输入点"按钮，
    -- 输入点由用户通过按钮+多选下拉框配置（可选全部类型，一个输入点可接入无限条同类型数据线）；
    -- 条件行左操作数从"全局变量 / 数据线输入"中选择（templates.md L1244"也可通过数据线输入"）；
    -- dataFields 默认一行条件，新节点拖出即有条件行。
    LogNewNode({
        type = "var_evaluate",
        name = "判断变量关系",
        color = Color(140, 100, 200),
        width = 320, height = 120,
        hasInput = true, hasOutput = true,
        inputTypes = allTypes,
        -- 输出数据点名称"结果"（templates.md L1303 (p结果)；E16）
        outputTypes = {BuildPortData(VarOp.TypeRefs.p or VarOp.TypeRefs.b, "结果")},
        availableInputTypes = allTypes,
        availableOutputTypes = {VarOp.TypeRefs.p or VarOp.TypeRefs.b},
        drawFunction = VarOp.DrawEvaluateRelationship,
        dataFields = {_conditions = {{left = {varName = "", dataType = ""}, operator = "=", lastOperator = "=", right = {mode = "literal", varName = "", dataType = "", literal = ""}}}, _connectors = {}},
    }, "evaluate_variable")

    -- 标记基础变量系统节点：节点选择器主列表不显示，改由"高级"上拉框固定展示
    -- （cl_ine_variable_dialogs.lua 绘制 / cl_ine_input_handling.lua 点击 通过 template._varOpNode 识别）
    -- 内置清单保存到 INE._varOpNodeKeys：节点选择器统计/绘制/点击均按此顺序遍历
    -- （不再依赖面板 allowedNodes，任何 INE 面板固定内置展示）
    -- 正式版内容：测试版仅注册 set_variable / evaluate_variable（新建变量与转换与提取放弃，见 templates.md）
    local varOpTemplateKeys = {
        "set_variable", "evaluate_variable",
    }
    INE._varOpNodeKeys = varOpTemplateKeys
    for _, tKey in ipairs(varOpTemplateKeys) do
        if INE.RegisteredNodes[tKey] then
            INE.RegisteredNodes[tKey]._varOpNode = true
        end
    end
end

-- ====================================================================================
-- 1. CreateVariable 节点（正式版内容：测试版放弃实现，见 templates.md"正式版再做"；
--    下方整个函数块已用 --[[ ]] 注释跳过，正式版恢复时删除注释标记并取消 RegisterAll 中对应注册注释）
-- ====================================================================================
--[[ 正式版内容：新建变量节点（测试版放弃，函数体保留供正式版恢复）
function VarOp.DrawCreateVariable(node, cx, cy, cw, ch, scale)
    local mX, mY = gui.MouseX(), gui.MouseY()
    local click = INE._frameMouseJustPressed or false
    local editor = node and node.editor
    local compFont = GetScaledFont(scale, 14)
    local smallFont = GetScaledFont(scale, 12)
    local charW = GetTW("字", compFont)

    local rowH = math.max(16, math.floor(20 * scale))
    local padding = math.max(2, math.floor(4 * scale))
    local entrySpacing = math.max(3, math.floor(4 * scale))
    local btnH = math.max(20, math.floor(26 * scale))

    node.data = node.data or {}
    node.data._varEntries = node.data._varEntries or {}
    node.data._nextVarId = node.data._nextVarId or 1

    local yOff = cy
    local hasChange = false

    -- 类型名称列表（供 DrawDropdown 使用）
    local typeNameList = {}
    for _, t in ipairs(VarOp.VarTypes) do
        table.insert(typeNameList, t.name)
    end

    -- 遍历绘制每个变量条目
    local deleteIdx = nil  -- 点击"-"待删除的条目索引（循环结束后统一执行）
    for idx, entry in ipairs(node.data._varEntries) do
        local vt = VarOp.VarTypes[entry.varTypeIdx]
        local vtId = vt and vt.id or "n"
        -- f 类型条目多一行：函数预览信息初始值 + "编辑函数"按钮（templates.md L1086）
        local entryH = (vtId == "f") and (rowH * 4 + padding * 3) or (rowH * 3 + padding * 2)
        local bgCol = vt and vt.color or Color(100, 100, 100)
        local entBg = Color(bgCol.r * 0.12, bgCol.g * 0.12, bgCol.b * 0.12, 180)
        draw.RoundedBox(4, cx, yOff, cw, entryH, entBg)

        -- 注册整个条目区域为交互 rect
        local entryRid = "cr_entry_" .. (entry.id or idx)
        RegisterIR(editor, node, entryRid, cx, yOff, cw, entryH)

        -- ==== 第1行：类型选择（字符图标 + DrawDropdown） ====
        local row1Y = yOff + padding
        local char = vt and vt.char or "n"
        local col = vt and vt.color or Color(255, 165, 0)

        local iconW = charW * 1.5
        draw.RoundedBox(3, cx + 3, row1Y, iconW, rowH, COL_BG)
        draw.SimpleText(char, compFont, cx + 3 + iconW/2, row1Y + rowH/2, col,
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        -- 注册字符图标为交互 rect
        RegisterIR(editor, node, "cr_icon_" .. (entry.id or idx), cx + 3, row1Y, iconW, rowH)

        -- 类型名称下拉框（右侧预留删除按钮空间）
        local delBtnW = charW * 2
        local typeLblX = cx + 3 + iconW + 6
        local typeDdW = math.min(math.max(cw - iconW - delBtnW - 18, charW), charW * 8)
        local typeId = "create_type_" .. (entry.id or idx)

        -- 注册下拉框按钮区域
        RegisterIR(editor, node, "cr_type_dd_" .. (entry.id or idx), typeLblX, row1Y, typeDdW, rowH)

        local oldDD = node.data.dropdowns and node.data.dropdowns[typeId]
        local oldTypeIdx = entry.varTypeIdx  -- 使用 entry 实际值而非 oldDD.selectedIndex（防止新选中后 curIdx==oldTypeIdx 导致更新永不触发）

        Canvas.DrawDropdown(typeLblX, row1Y, typeDdW, rowH,
            typeNameList, entry.varTypeIdx or 1, node, typeId, nil, nil, smallFont, scale)

        local curDD = node.data.dropdowns and node.data.dropdowns[typeId]
        if curDD then
            local curIdx = curDD.selectedIndex
            if curIdx ~= oldTypeIdx then
                entry.varTypeIdx = curIdx
                -- 根据新类型设置合适的初始值
                local newVt = VarOp.VarTypes[curIdx]
                if newVt then
                    if newVt.id == "n" then entry.initValue = 0
                    elseif newVt.id == "b" then entry.initValue = false
                    elseif newVt.id == "t" then entry.initValue = ""
                    elseif newVt.id == "e" then entry.initValue = nil
                    elseif newVt.id == "g" then entry.initValue = nil
                    elseif newVt.id == "f" then entry.initValue = nil
                    end
                else
                    entry.initValue = 0
                end
                -- 清理旧槽状态
                local initId = "create_var_init_" .. (entry.id or idx)
                local boolId = "create_bool_" .. (entry.id or idx)
                if node.data.numbers then node.data.numbers[initId] = nil end
                if node.data.dropdowns then node.data.dropdowns[boolId] = nil end
                hasChange = true
                RebuildOutputPorts(node)
                RecalcVarHeight(node, 100, node.data._varEntries, rowH, padding, entrySpacing, btnH)
            end
        end

        -- 删除该变量条目按钮（"-"）：删除局部变量并移除对应数据输出点
        -- 联动：断开向外数据线并重置目标节点状态（RemoveVarEntry 统一处理）
        -- 按钮贴内容区最右侧，与类型下拉框右侧保持 6px 间隙
        local delBtnX = cx + cw - delBtnW - 3
        local delBtnHov = mX >= delBtnX and mX <= delBtnX + delBtnW
                      and mY >= row1Y and mY <= row1Y + rowH
        draw.RoundedBox(3, delBtnX, row1Y, delBtnW, rowH,
            delBtnHov and Color(160, 70, 70) or Color(85, 52, 52))
        draw.SimpleText("-", compFont, delBtnX + delBtnW / 2, row1Y + rowH / 2, COL_TEXT,
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        RegisterIR(editor, node, "cr_del_" .. (entry.id or idx), delBtnX, row1Y, delBtnW, rowH)

        -- 点击删除：下拉框展开时忽略，防止误触；仅记录待删索引，循环结束后统一执行
        -- （不在循环内直接删除，避免 ipairs 遍历中修改数组导致的条目错位/绘制闪烁）
        if click and delBtnHov and not Canvas.DraggingNode and not DropdownConsumed() then
            local expInfo = Canvas.ExpandedDropdownInfo
            local inExpDropdown = false
            if expInfo then
                local inOpt = mX >= expInfo.dropdownX and mX <= expInfo.dropdownX + expInfo.totalWidth
                          and mY >= expInfo.dropdownY and mY <= expInfo.dropdownY + expInfo.dropdownH
                inExpDropdown = inOpt or (Canvas.ExpandedDropdown ~= nil)
            end
            if not inExpDropdown then
                deleteIdx = idx
            end
        end

        -- ==== 第2行：变量名 + 内部变量名 ====
        local row2Y = yOff + padding + rowH + padding
        -- 变量名
        local nLblW = GetTW("名:", smallFont) + 2
        draw.SimpleText("名:", smallFont, cx + 4, row2Y + rowH/2, COL_LABEL,
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        local nX = cx + 4 + nLblW
        local nW = (cw - 8 - nLblW - 4) * 0.5
        -- 内联输入框（glua-input-field 模式，支持 IME 中文输入）
        DrawInputField(node, mX, mY, click, "name", nX, row2Y, nW, rowH,
            smallFont, entry.name or "", "名称", entry)
        -- 注册变量名输入框
        RegisterIR(editor, node, "cr_name_" .. (entry.id or idx), nX, row2Y, nW, rowH)

        -- 内部变量名
        local iLblX = nX + nW + 4
        local iLblW = GetTW("内:", smallFont) + 2
        draw.SimpleText("内:", smallFont, iLblX, row2Y + rowH/2, COL_LABEL,
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        local iX = iLblX + iLblW
        local iW = cw - (iX - cx) - 4
        -- 内联输入框（glua-input-field 模式，支持 IME 中文输入）
        DrawInputField(node, mX, mY, click, "internalName", iX, row2Y, iW, rowH,
            smallFont, entry.internalName or "", "内部名", entry)
        -- 注册内部变量名输入框
        RegisterIR(editor, node, "cr_intname_" .. (entry.id or idx), iX, row2Y, iW, rowH)

        -- ==== 第3行：初始值（根据类型变化） ====
        local row3Y = yOff + padding + (rowH + padding) * 2

        if vtId == "n" then
            -- 数字：DrawNumberBox
            draw.SimpleText("初始值:", smallFont, cx + 4, row3Y + rowH/2, COL_LABEL,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            local ivLblW = GetTW("初始值:", smallFont)
            local nId = "create_var_init_" .. (entry.id or idx)
            RegisterIR(editor, node, "cr_init_" .. (entry.id or idx),
                cx + 4 + ivLblW + 4, row3Y, rowH * 3, rowH)
            local newNumVal = Canvas.DrawNumberBox(cx + 4 + ivLblW + 4, row3Y, rowH,
                entry.initValue or 0, node, nId, nil, compFont)
            if newNumVal ~= nil then entry.initValue = newNumVal end
        elseif vtId == "t" then
            -- 文本：内联输入框占据整行（glua-input-field 模式，支持 IME 中文输入）
            local tX = cx + 4
            local tW = cw - 8
            DrawInputField(node, mX, mY, click, "initValue", tX, row3Y, tW, rowH,
                smallFont, tostring(entry.initValue or ""), "输入默认文本", entry)
            RegisterIR(editor, node, "cr_text_" .. (entry.id or idx), tX, row3Y, tW, rowH)
        elseif vtId == "b" then
            -- 布尔值：DrawDropdown true/false
            local bId = "create_bool_" .. (entry.id or idx)
            local bOpts = {"true", "false"}
            local bIdx = entry.initValue and 1 or 2
            local bW = math.min(charW * 6, cw - 8)
            RegisterIR(editor, node, "cr_bool_" .. (entry.id or idx), cx + 4, row3Y, bW, rowH)
            Canvas.DrawDropdown(cx + 4, row3Y, bW, rowH, bOpts, bIdx, node, bId, nil, nil, smallFont, scale)
            local bDD = node.data.dropdowns and node.data.dropdowns[bId]
            if bDD then entry.initValue = (bDD.selectedIndex == 1) end
        elseif vtId == "e" then
            -- 对象："空对象"按钮 + $ 对象变量槽（templates.md L1082）
            -- 空对象点亮 → 右侧槽亮度减半；槽选中对象后 → 空对象取消点亮
            local eBtnW = math.min(charW * 5, math.floor((cw - 8) * 0.4))
            local eX = cx + 4
            local emptyOn = entry.emptyObj == true
            local eHov = mX >= eX and mX <= eX + eBtnW and mY >= row3Y and mY <= row3Y + rowH
            draw.RoundedBox(3, eX, row3Y, eBtnW, rowH,
                emptyOn and Color(110, 75, 52) or (eHov and Color(80, 60, 50) or Color(60, 45, 40)))
            draw.SimpleText("空对象", smallFont, eX + eBtnW / 2, row3Y + rowH / 2,
                emptyOn and Color(255, 215, 140) or COL_SUB,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            RegisterIR(editor, node, "cr_obj_" .. (entry.id or idx), eX, row3Y, eBtnW, rowH)
            -- $ 对象变量槽（点击展开仅对象变量的选择器；空对象点亮时整体降亮度）
            local slotX = eX + eBtnW + 6
            local slotW = math.max(10, (cx + cw - 4) - slotX)
            local slotText = (entry.initValue and entry.initValue ~= "") and tostring(entry.initValue) or "$ 对象变量槽"
            local slotHov = mX >= slotX and mX <= slotX + slotW and mY >= row3Y and mY <= row3Y + rowH
            local dim = emptyOn and 0.45 or 1
            draw.RoundedBox(3, slotX, row3Y, slotW, rowH,
                slotHov and Color(math.floor(70 * dim + 20), math.floor(55 * dim + 20), math.floor(55 * dim + 20))
                          or Color(math.floor(50 * dim + 20), math.floor(40 * dim + 20), math.floor(40 * dim + 20)))
            draw.SimpleText(ClipTextWidth(slotText, math.max(8, slotW - 8), smallFont), smallFont,
                slotX + slotW / 2, row3Y + rowH / 2,
                (entry.initValue and entry.initValue ~= "") and Color(math.floor(255 * dim), math.floor(170 * dim), math.floor(170 * dim))
                    or Color(math.floor(150 * dim), math.floor(105 * dim), math.floor(105 * dim)),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            RegisterIR(editor, node, "cr_objslot_" .. (entry.id or idx), slotX, row3Y, slotW, rowH)
            if click and not Canvas.DraggingNode and not Canvas.ExpandedDropdown and not DropdownConsumed() then
                if eHov then
                    entry.emptyObj = not emptyOn
                    -- 空对象点亮：清除已选对象变量（槽回到占位状态并降亮度）
                    if entry.emptyObj then entry.initValue = nil end
                elseif slotHov and not Canvas.GlobalVarSelector then
                    VarOp.OpenGlobalVarSelector(editor, node,
                        slotX, row3Y, slotW, scale, "set", nil, nil, "e", nil,
                        function(varName, dataType)
                            entry.initValue = varName
                            entry.emptyObj = false
                        end,
                        function() end)
                end
            end
        elseif vtId == "g" then
            -- 数组：+ 按钮 → 右侧独立变量创建 UI（额外圆角矩形包裹，templates.md L1083）
            local plusW = math.max(20, charW * 1.6)
            local plusX = cx + 4
            local plusHov = mX >= plusX and mX <= plusX + plusW and mY >= row3Y and mY <= row3Y + rowH
            draw.RoundedBox(3, plusX, row3Y, plusW, rowH, plusHov and COL_BTN_HOVER or COL_BTN)
            draw.SimpleText("+", compFont, plusX + plusW / 2, row3Y + rowH / 2,
                Color(220, 230, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            RegisterIR(editor, node, "cr_gplus_" .. (entry.id or idx), plusX, row3Y, plusW, rowH)
            if click and plusHov and not Canvas.DraggingNode and not Canvas.ExpandedDropdown and not DropdownConsumed() then
                -- 收起时失活该项名输入框，防止 DTextEntry 残留
                if entry._arrOpen == true and VarOp.InputState.active
                   and VarOp.InputState.node == node and VarOp.InputState.entry == entry
                   and VarOp.InputState.field == "arrItemName" then
                    VarOp.InputState.active = false
                end
                entry._arrOpen = not (entry._arrOpen == true)
            end
            local restX = plusX + plusW + 6
            local restW = math.max(10, (cx + cw - 4) - restX)
            if entry._arrOpen == true then
                -- 独立变量创建 UI：类型下拉 + 名称输入（额外圆角矩形包裹）
                local createW = math.min(math.max(restW * 0.8, charW * 8), restW)
                draw.RoundedBox(3, restX, row3Y, createW, rowH, Color(50, 52, 58))
                -- 类型下拉（n/b/t/e/g/f 字符+名称，与新建变量类型一致）
                local aTypeList = {}
                for _, vt2 in ipairs(VarOp.VarTypes) do
                    table.insert(aTypeList, vt2.char .. " " .. vt2.name)
                end
                local aMaxW = 0
                for _, o in ipairs(aTypeList) do
                    aMaxW = math.max(aMaxW, GetTW(o, smallFont))
                end
                local aTypeW = math.min(math.max(aMaxW + charW, charW * 3), math.floor(createW * 0.45))
                entry.arrayItemType = entry.arrayItemType or "n"
                local aSel = 1
                for ai, vt2 in ipairs(VarOp.VarTypes) do
                    if vt2.id == entry.arrayItemType then aSel = ai break end
                end
                local aTypeId = "cr_arritem_type_" .. (entry.id or idx)
                RegisterIR(editor, node, aTypeId, restX + 3, row3Y, aTypeW, rowH)
                Canvas.DrawDropdown(restX + 3, row3Y, aTypeW, rowH, aTypeList, aSel, node, aTypeId, nil, nil, smallFont, scale)
                local aDD = node.data.dropdowns and node.data.dropdowns[aTypeId]
                if aDD then
                    local aVt = VarOp.VarTypes[aDD.selectedIndex]
                    if aVt then entry.arrayItemType = aVt.id end
                end
                -- 名称输入（arrItemName 字段绑定条目 arrayItemName）
                local aNameX = restX + 3 + aTypeW + 4
                local aNameW = math.max(10, createW - (aNameX - restX) - 3)
                DrawInputField(node, mX, mY, click, "arrItemName", aNameX, row3Y, aNameW, rowH,
                    smallFont, entry.arrayItemName or "", "项名", entry)
                RegisterIR(editor, node, "cr_arritem_name_" .. (entry.id or idx), aNameX, row3Y, aNameW, rowH)
            elseif entry.arrayItemName and entry.arrayItemName ~= "" then
                -- 已创建数组项：显示摘要（类型字符 + 名称）
                local sumVt = nil
                for _, vt2 in ipairs(VarOp.VarTypes) do
                    if vt2.id == (entry.arrayItemType or "n") then sumVt = vt2 break end
                end
                local sumCol = sumVt and sumVt.color or Color(255, 200, 0)
                local sumCh = sumVt and sumVt.char or "g"
                draw.SimpleText(sumCh .. " " .. ClipTextWidth(entry.arrayItemName, math.max(8, restW - 24), smallFont),
                    smallFont, restX, row3Y + rowH / 2, sumCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
        elseif vtId == "f" then
            -- 函数：预览信息初始值（行3）+ "编辑函数"按钮（行4，templates.md L1086）
            -- 预览：已保存函数数据 → GenerateFunctionDescription；否则占位提示
            local fVarName = entry.name and entry.name ~= "" and entry.name
                or (entry.internalName and entry.internalName ~= "" and entry.internalName)
                or ("func" .. (entry.id or idx))
            local fDesc = ""
            local fData = editor and editor._savedFunctionData and editor._savedFunctionData[fVarName]
            if fData then
                local ok, desc = pcall(INE.GenerateFunctionDescription, INE, fData)
                if ok and desc and desc ~= "—" then fDesc = desc end
            end
            if fDesc == "" then fDesc = "（空函数）点击编辑函数内容" end
            draw.SimpleText(ClipTextWidth(fDesc, math.max(8, cw - 16), smallFont), smallFont,
                cx + 4, row3Y + rowH / 2, COL_LINK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            -- 第4行：编辑函数按钮（点击打开函数 INE 面板，已打开则记录闪烁连线）
            local row4Y = row3Y + rowH + padding
            local fBtnW = math.min(charW * 7, cw - 8)
            local fBtnX = cx + 4
            local fBtnHov = mX >= fBtnX and mX <= fBtnX + fBtnW and mY >= row4Y and mY <= row4Y + rowH
            draw.RoundedBox(3, fBtnX, row4Y, fBtnW, rowH, fBtnHov and COL_BTN_HOVER or COL_BTN)
            RegisterIR(editor, node, "cr_func_" .. (entry.id or idx), fBtnX, row4Y, fBtnW, rowH)
            draw.SimpleText("编辑函数", smallFont, fBtnX + fBtnW / 2, row4Y + rowH / 2,
                Color(200, 220, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if click and fBtnHov and not Canvas.DraggingNode and not Canvas.ExpandedDropdown and not DropdownConsumed() then
                -- 规格：点击即打开函数 INE 面板；若面板已打开，则从鼠标到面板中心创建
                -- 闪烁连线 2 秒后消失（templates.md L1086/L1088，仅视觉引导）
                local subID = "ine_func_" .. (editor and editor.id or "?") .. "_" .. fVarName
                local alreadyOpen = INE.Editors and INE.Editors[subID] ~= nil
                if INE.OpenFunctionSubEditor then
                    INE:OpenFunctionSubEditor(editor, fVarName)
                end
                if alreadyOpen then
                    VarOp.FunctionLinkFlash = { start = SysTime(), x = mX, y = mY, subID = subID }
                end
            end
        end

        yOff = yOff + entryH + entrySpacing
    end

    -- 循环结束后统一执行条目删除（避免循环内删除导致后续条目索引错位/绘制闪烁）
    if deleteIdx then
        RemoveVarEntry(node, deleteIdx)
        RecalcVarHeight(node, 100, node.data._varEntries, rowH, padding, entrySpacing, btnH)
    end

    -- "+ 新建变量" 按钮
    local addBtnY = yOff + 2
    local addBtnW = cw - 4
    local addBtnH = btnH
    local addBtnX = cx + 2
    local bHov = mX >= addBtnX and mX <= addBtnX + addBtnW
            and mY >= addBtnY and mY <= addBtnY + addBtnH
    draw.RoundedBox(4, addBtnX, addBtnY, addBtnW, addBtnH, bHov and COL_BTN_HOVER or COL_BTN)
    draw.SimpleText("+ 新建变量", compFont, cx + cw / 2, addBtnY + addBtnH / 2,
        Color(200, 220, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    -- 注册按钮 rect
    RegisterIR(editor, node, "cr_add_btn", addBtnX, addBtnY, addBtnW, addBtnH)

    -- 防止与下拉框重叠误触：只有当鼠标在按钮区域内且没有任何 DrawDropdown 展开时才触发
    if click and bHov and not Canvas.DraggingNode and not DropdownConsumed() then
        -- 检查是否有下拉框展开：Canvas.ExpandedDropdown 只在下拉框展开期间非 nil
        -- 注意：DrawDropdown 可能会在本帧清除 ExpandedDropdown（如果点击选项），
        -- 因此额外检查刚才点击的坐标是否在某个下拉框展开区域内。
        local expInfo = Canvas.ExpandedDropdownInfo
        local inExpDropdown = false
        if expInfo then
            local inOpt = mX >= expInfo.dropdownX and mX <= expInfo.dropdownX + expInfo.totalWidth
                      and mY >= expInfo.dropdownY and mY <= expInfo.dropdownY + expInfo.dropdownH
            inExpDropdown = inOpt or (Canvas.ExpandedDropdown ~= nil)
        end
        if not inExpDropdown then
            table.insert(node.data._varEntries, {
                id = node.data._nextVarId,
                varTypeIdx = 1,
                name = "",
                internalName = "",
                initValue = 0,
            })
            node.data._nextVarId = node.data._nextVarId + 1
            RecalcVarHeight(node, 100, node.data._varEntries, rowH, padding, entrySpacing, btnH)
            RebuildOutputPorts(node)
        end
    end

    -- 高度每帧按当前画布缩放重算（世界单位 = 内容像素 / scale，含标题栏偏移 40）：
    -- 画布缩放变化时节点高度立即贴合内容（R2），不依赖操作时触发的 RecalcVarHeight
    local needPx = 0
    for _, e2 in ipairs(node.data._varEntries) do
        -- f 类型条目多一行（函数预览 + 编辑函数按钮），其余条目固定 3 行
        local v2 = VarOp.VarTypes[e2.varTypeIdx]
        local eH2 = ((v2 and v2.id == "f") and (rowH * 4 + padding * 3)) or (rowH * 3 + padding * 2)
        needPx = needPx + eH2 + entrySpacing
    end
    needPx = needPx + btnH + 10  -- "+ 新建变量"按钮 + 底部留白
    node.height = math.max(100, math.floor(40 + needPx / scale))

    -- 检查端口是否需要更新（逐字段比较 id/name，避免端口表重建导致的每帧重建）
    local expected = {}
    for _, e in ipairs(node.data._varEntries) do
        local vt = VarOp.VarTypes[e.varTypeIdx]
        if vt and vt.dataTypeRef then
            table.insert(expected, BuildPortData(vt.dataTypeRef, GetEntryVarName(e)))
        end
    end
    local cur = node.selectedOutputTypes or {}
    if #expected ~= #cur then
        hasChange = true
    else
        for i, ref in ipairs(expected) do
            if not PortDataEqual(cur[i], ref) then
                hasChange = true
                break
            end
        end
    end
    if hasChange then
        RebuildOutputPorts(node)
    end
end
-- 正式版内容：新建变量节点函数体注释结束（下方单行 双右方括号 关闭上方 --[[ 注释块）
]]

-- ====================================================================================
-- 2. SetVariable 节点
-- ====================================================================================
function VarOp.DrawSetVariable(node, cx, cy, cw, ch, scale)
    local mX, mY = gui.MouseX(), gui.MouseY()
    local click = INE._frameMouseJustPressed or false
    local editor = node and node.editor
    local compFont = GetScaledFont(scale, 14)
    local smallFont = GetScaledFont(scale, 12)
    local charW = GetTW("字", compFont)

    -- 缩放后的尺寸
    local rowH = math.max(16, math.floor(22 * scale))
    local btnH = math.max(20, math.floor(26 * scale))
    local spacing = math.max(2, math.floor(4 * scale))
    local entrySpacing = math.max(3, math.floor(5 * scale))
    local padding = math.max(2, math.floor(4 * scale))

    node.data = node.data or {}

    -- 旧存档迁移：旧版单目标行（_targetVar）→ _setEntries 数组（多设置行，templates.md L1091"按钮下移、原位插入"）
    if node.data._targetVar and not node.data._setEntries then
        local legacyType = node.data._targetType or "n"
        local legacyValue = node.data._setValue
        if legacyType == "b" and legacyValue ~= "true" and legacyValue ~= "false" then
            legacyValue = "false"
        end
        node.data._setEntries = {{
            id = "sv_legacy",
            varName = node.data._targetVar,
            varType = legacyType,
            source = "global",
            opIdx = node.data._setOpIdx or 1,
            value = legacyValue,
        }}
        node.data._targetVar = nil
        node.data._targetType = nil
        node.data._setOpIdx = nil
        node.data._setValue = nil
    end
    node.data._showSelector = nil  -- 旧版内嵌选择器状态，新版浮层化不再使用
    node.data._setEntries = node.data._setEntries or {}
    node.data._nextEntryId = node.data._nextEntryId or 1
    -- 确保默认数据输入点（数字 + 数组，templates.md L1147"数据线接入"）
    EnsureSetVarInputPorts(node)

    local yOff = cy
    local deleteIdx = nil

    for idx, entry in ipairs(node.data._setEntries) do
        -- 数据线来源防御：对应数据连接已不存在时回退为全局来源（断线/删除后"←"标记不残留）
        if entry.source == "input" and entry.connId then
            local stillExists = false
            if editor and editor.dataConnections then
                for _, dc in ipairs(editor.dataConnections) do
                    if dc.id == entry.connId then stillExists = true break end
                end
            end
            if not stillExists then
                entry.source = "global"
                entry.connId = nil
            end
        end
        local entryId = entry.id or idx
        local varType = entry.varType or "n"
        -- 浮层/数据线可能写入 INE 数据类型 id（布尔 p），归一化为内部 id（b）后再走类型分支
        varType = INEToVarTypeId(varType)
        if not VarOp.TypeRefs[varType] then varType = "n" end
        entry.varType = varType
        entry.opIdx = entry.opIdx or 1
        local dtRef = VarOp.TypeRefs[varType]
        local tColor = dtRef and dtRef.color or Color(255, 170, 60)

        -- ============ 行1：目标变量（点击重选）+ 删除按钮 ============
        local targetHov = mX >= cx and mX <= cx + cw and mY >= yOff and mY <= yOff + rowH
        draw.RoundedBox(4, cx, yOff, cw, rowH, targetHov and Color(50, 60, 75) or Color(40, 50, 60))
        RegisterIR(editor, node, "sv_target_" .. entryId, cx, yOff, cw, rowH)

        -- 左侧类型色矩形（颜色 = 目标变量类型颜色；_targetType 经 VarOp.TypeRefs 取 INE 类型引用）
        local barW = math.max(3, math.floor(4 * scale))
        local barX = cx + 4
        surface.SetDrawColor(tColor)
        surface.DrawRect(barX, yOff + 2, barW, rowH - 4)
        local delBtnW = charW * 1.8
        local nameMaxW = cw - (barX + barW + 4 - cx) - delBtnW - 8
        local varDisplay = entry.varName or ""
        local clipName = ClipTextWidth(varDisplay, math.max(8, nameMaxW), smallFont)
        draw.SimpleText(clipName, smallFont, barX + barW + 4, yOff + rowH / 2, tColor,
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        -- 数据线接入标记（来源 = 数据线）：变量名后显示蓝色 ←
        if entry.source == "input" and clipName ~= "" then
            local tagX = barX + barW + 4 + GetTW(clipName, smallFont) + 4
            draw.SimpleText("←", smallFont, tagX, yOff + rowH / 2, COL_LINK,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        -- "点击修改"提示（贴近删除按钮左侧）
        local hintW = GetTW("点击修改", smallFont)
        local hintX = cx + cw - delBtnW - 6 - hintW
        draw.SimpleText("点击修改", smallFont, hintX, yOff + rowH / 2,
            targetHov and COL_LINK or Color(100, 100, 100), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 删除按钮（"-"）
        local delBtnX = cx + cw - delBtnW - 3
        local delBtnHov = mX >= delBtnX and mX <= delBtnX + delBtnW
                      and mY >= yOff and mY <= yOff + rowH
        draw.RoundedBox(3, delBtnX, yOff + 2, delBtnW, rowH - 4,
            delBtnHov and Color(160, 70, 70) or Color(85, 52, 52))
        draw.SimpleText("-", compFont, delBtnX + delBtnW / 2, yOff + rowH / 2, COL_TEXT,
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        RegisterIR(editor, node, "sv_del_" .. entryId, delBtnX, yOff, delBtnW, rowH)

        -- 点击：删除优先；目标行打开重选浮层（浮层已打开或下拉框展开/本帧已消费下拉框选项点击时忽略）
        if click and not Canvas.DraggingNode and not Canvas.ExpandedDropdown and not DropdownConsumed() then
            if delBtnHov then
                deleteIdx = idx
            elseif targetHov and not Canvas.GlobalVarSelector then
                VarOp.OpenGlobalVarSelector(editor, node,
                    cx, yOff, cw, scale, "set", nil, nil, nil, nil,
                    function(varName, dataType, v)
                        -- 浮层 dataType 为 INE id（布尔 p），转回内部 id（b）后存入条目
                        dataType = INEToVarTypeId(dataType)
                        entry.varName = varName
                        entry.varType = dataType
                        -- 对象类别：单位/指令反制/空对象（templates.md L1106-1111）；非对象类型置空
                        entry.objMode = (dataType == "e") and GetObjModeFromVar(v) or nil
                        -- 重选目标后：词条初始值需重新带出（新对象的词条），重置标记
                        entry.kwInit = nil
                        entry.opIdx = 1
                        entry.value = SetEntryDefaultValue(dataType)
                        -- 对象数值属性子操作重置（1=设为 2=增加 3=减少）
                        entry.objOpIdx = 1
                        -- 数组"第/最后一项"子操作状态重置（项类型/项名/子操作索引/项索引）
                        entry.subOpIdx = 1
                        entry.itemType = nil
                        entry.itemName = nil
                        entry.itemIndex = nil
                        entry.source = "global"
                        entry.connId = nil
                        -- 类型切换后清空操作下拉框/数字槽残留状态（选项集变化防错位，E5 同款保护）
                        local opId = "sv_op_" .. entryId
                        local gsubId = "sv_gsub_" .. entryId
                        local gtypeId = "sv_gtype_" .. entryId
                        if node.data.dropdowns then
                            node.data.dropdowns[opId] = nil
                            node.data.dropdowns[gsubId] = nil
                            node.data.dropdowns[gtypeId] = nil
                        end
                        local nf = "sv_num_" .. entryId
                        local gvalNf = "sv_gval_" .. entryId
                        if node.data.numbers then
                            node.data.numbers["libnum_" .. nf] = nil
                            node.data.numbers["libnum_" .. gvalNf] = nil
                        end
                    end,
                    function() end)
            end
        end
        yOff = yOff + rowH + spacing

        -- ============ 行2：操作下拉 + 值输入（同排；无"操作/值"标签、无值区背景，templates.md L1099-1143） ============
        -- 对象操作集按对象类别区分（templates.md L1106-1111）：
        --   单位 → 13 项超集；指令/反制 → 9 项子集；空对象 → 固定 '设为'（无下拉）
        local ops
        if varType == "e" then
            if entry.objMode == "empty" then
                ops = {SET_OBJ_EMPTY_OP}
            else
                ops = SET_OBJ_OPS[entry.objMode] or SET_OBJ_OPS.unit
            end
        else
            ops = SET_OPS[varType] or {"设为"}
        end
        local hasOpRow = (varType ~= "t" and varType ~= "f")
        if varType == "e" and entry.objMode == "empty" then hasOpRow = false end
        local valX = cx + 4
        if hasOpRow then
            -- 下拉框宽度按当前类型最长操作文本自适应（去掉"操作:"标签后直接左对齐）
            local maxOpW = 0
            for _, op in ipairs(ops) do
                maxOpW = math.max(maxOpW, GetTW(op, smallFont))
            end
            local opW = math.min(cw - 8, maxOpW + charW * 1.6)
            -- 索引越界保护（类型切换后选项集变化，残留索引重置为"设为"）
            if entry.opIdx < 1 or entry.opIdx > #ops then entry.opIdx = 1 end
            local opId = "sv_op_" .. entryId
            RegisterIR(editor, node, "sv_op_dd_" .. entryId, cx + 4, yOff, opW, rowH)
            Canvas.DrawDropdown(cx + 4, yOff, opW, rowH, ops, entry.opIdx, node, opId, nil, nil, smallFont, scale)
            local curDD = node.data.dropdowns and node.data.dropdowns[opId]
            if curDD then entry.opIdx = curDD.selectedIndex end
            valX = cx + 4 + opW + 6
        end
        local valW = math.max(10, (cx + cw - 4) - valX)
        local opLabel = ops[entry.opIdx] or "设为"
        -- 值区兜底交互 rect（控件仅占部分宽度时，点击行内空白不触发节点拖动）
        RegisterIR(editor, node, "sv_value_" .. entryId, valX, yOff, valW, rowH)

        if varType == "n" then
            -- 数字：[lib] 数字槽（可输入数字或单选数字全局变量；值镜像到 entry.value）
            local numField = "sv_num_" .. entryId
            if entry.value == nil or entry.value == "" then
                node.data[numField] = 0
            else
                node.data[numField] = entry.value
            end
            local _, slotW = DrawLibNumberBox(node, numField, valX, yOff, rowH, 0, smallFont)
            entry.value = node.data[numField]
            RegisterIR(editor, node, "sv_num_" .. entryId, valX, yOff, slotW or valW, rowH)
        elseif varType == "b" then
            if opLabel == "反转" then
                -- 反转：无值输入（templates.md L1144-1145）
                draw.SimpleText("—", smallFont, valX, yOff + rowH / 2, Color(100, 100, 100),
                    TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            else
                -- 布尔"设为"：真/假按钮（templates.md L1143）；初始值恒为 false（布尔不存在第三状态）
                local curV = entry.value
                if curV ~= "true" and curV ~= "false" then curV = "false" end
                entry.value = curV
                local btnW = math.max(28, math.floor(valW * 0.42))
                local bTrueX = valX
                local bFalseX = valX + btnW + 4
                local tHov = mX >= bTrueX and mX <= bTrueX + btnW and mY >= yOff and mY <= yOff + rowH
                local fHov = mX >= bFalseX and mX <= bFalseX + btnW and mY >= yOff and mY <= yOff + rowH
                local tActive = (curV == "true")
                local fActive = (curV == "false")
                draw.RoundedBox(3, bTrueX, yOff, btnW, rowH,
                    tActive and Color(90, 140, 90) or (tHov and Color(60, 90, 60) or Color(45, 50, 55)))
                draw.SimpleText("真", smallFont, bTrueX + btnW / 2, yOff + rowH / 2,
                    tActive and Color(255, 255, 255) or COL_TEXT,
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                RegisterIR(editor, node, "sv_btrue_" .. entryId, bTrueX, yOff, btnW, rowH)
                draw.RoundedBox(3, bFalseX, yOff, btnW, rowH,
                    fActive and Color(140, 90, 90) or (fHov and Color(90, 60, 60) or Color(45, 50, 55)))
                draw.SimpleText("假", smallFont, bFalseX + btnW / 2, yOff + rowH / 2,
                    fActive and Color(255, 255, 255) or COL_TEXT,
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                RegisterIR(editor, node, "sv_bfalse_" .. entryId, bFalseX, yOff, btnW, rowH)
                if click and not Canvas.DraggingNode and not Canvas.ExpandedDropdown and not DropdownConsumed() then
                    if tHov then entry.value = "true"
                    elseif fHov then entry.value = "false" end
                end
            end
        elseif varType == "t" then
            -- 文本：内联输入框（无操作行，直接输入，templates.md L1122）
            DrawInputField(node, mX, mY, click, "sv_value", valX, yOff, valW, rowH, smallFont,
                tostring(entry.value or ""), "文本", entry)
            RegisterIR(editor, node, "sv_text_" .. entryId, valX, yOff, valW, rowH)
        elseif varType == "g" then
            if opLabel == "设为" then
                -- 数组槽：仅选择数组变量（templates.md L1131"设为 → 仅能选择数组的修改变量组件（数组槽）"）
                local slotText = (entry.value and entry.value ~= "") and entry.value or "选择数组变量"
                local slotHov = mX >= valX and mX <= valX + valW and mY >= yOff and mY <= yOff + rowH
                draw.RoundedBox(3, valX, yOff, valW, rowH, slotHov and Color(60, 70, 60) or Color(45, 50, 45))
                draw.SimpleText(ClipTextWidth(slotText, math.max(8, valW - 8), smallFont), smallFont,
                    valX + valW / 2, yOff + rowH / 2,
                    (entry.value and entry.value ~= "") and Color(255, 200, 120) or Color(120, 120, 120),
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                RegisterIR(editor, node, "sv_gslot_" .. entryId, valX, yOff, valW, rowH)
                if click and slotHov and not Canvas.DraggingNode and not Canvas.GlobalVarSelector and not DropdownConsumed() then
                    VarOp.OpenGlobalVarSelector(editor, node,
                        valX, yOff, valW, scale, "set", nil, nil, "g", nil,
                        function(varName, dataType)
                            entry.value = varName
                        end,
                        function() end)
                end
            else
                -- 第 / 最后一项："[lib] 项 为 {类型、值}"（templates.md L1141-1145）
                -- '为' 组件：无论选择"值"还是"类型"，先渲染静态前置标签"为"（templates.md L1142），不参与交互
                -- 值：按项类型（entry.itemType，默认 n）渲染对应值控件（templates.md L1144）：
                --     数字→[lib] 数字槽 / 布尔→真/假按钮 / 文本→输入框 / 对象→对象变量槽 /
                --     数组→数组变量槽 / 函数→'改为 #'
                -- 类型：创建变量组件（templates.md L1145）：行内类型下拉（n/b/t/e/g/f，字符+颜色与
                --     新建变量类型一致）+ "#名称" 输入；选中类型即设置项类型，值区按新类型重新编排
                local _, idxW = DrawLibNumberBox(node, "sv_gidx_" .. entryId, valX, yOff, rowH, 0, smallFont)
                -- 镜像索引到 entry.itemIndex（战斗解析器据此定位数组项；值槽仍用 entry.value）
                entry.itemIndex = node.data["sv_gidx_" .. entryId]
                local itemX = valX + (idxW or math.max(charW * 2, math.floor(rowH * 1.8))) + 4
                draw.SimpleText("项", smallFont, itemX, yOff + rowH / 2, COL_SUB,
                    TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local weiX = itemX + GetTW("项", smallFont) + 4
                draw.SimpleText("为", smallFont, weiX, yOff + rowH / 2, COL_SUB,
                    TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local subOpX = weiX + GetTW("为", smallFont) + 6
                local subOpW = math.min(math.max(valW - (subOpX - valX) - 4, charW * 2), charW * 3)
                local subOpts = {"值", "类型"}
                entry.subOpIdx = entry.subOpIdx or 1
                if entry.subOpIdx < 1 or entry.subOpIdx > #subOpts then entry.subOpIdx = 1 end
                local subId = "sv_gsub_" .. entryId
                RegisterIR(editor, node, "sv_gsub_" .. entryId, subOpX, yOff, subOpW, rowH)
                Canvas.DrawDropdown(subOpX, yOff, subOpW, rowH, subOpts, entry.subOpIdx, node, subId, nil, nil, smallFont, scale)
                local subDD = node.data.dropdowns and node.data.dropdowns[subId]
                if subDD then entry.subOpIdx = subDD.selectedIndex end
                local subValX = subOpX + subOpW + 6
                local subValW = math.max(10, (cx + cw - 4) - subValX)
                local curSubOp = subOpts[entry.subOpIdx] or "值"
                -- 子操作切换/项类型变更时失活内联输入框（防止残留 DTextEntry 悬浮于旧字段位置）
                local keepInputActive = false
                if VarOp.InputState.active and VarOp.InputState.node == node and VarOp.InputState.entry == entry then
                    if curSubOp == "类型" and VarOp.InputState.field == "sv_itemName" then
                        keepInputActive = true
                    elseif curSubOp == "值" and VarOp.InputState.field == "sv_value"
                           and (entry.itemType or "n") == "t" then
                        keepInputActive = true
                    end
                    if not keepInputActive then VarOp.InputState.active = false end
                end
                if curSubOp == "值" then
                    local itemType = entry.itemType or "n"
                    if itemType == "n" then
                        -- 数字：值项 [lib] 数字槽（可直接输入数字或单选数字全局变量）
                        if entry.value == nil or entry.value == "" then
                            node.data["sv_gval_" .. entryId] = 0
                        else
                            node.data["sv_gval_" .. entryId] = entry.value
                        end
                        DrawLibNumberBox(node, "sv_gval_" .. entryId, subValX, yOff, rowH, 0, smallFont)
                        entry.value = node.data["sv_gval_" .. entryId]
                        RegisterIR(editor, node, "sv_gval_" .. entryId, subValX, yOff, subValW, rowH)
                    elseif itemType == "b" then
                        -- 布尔：真/假按钮（templates.md L1152"设为 → 直接渲染 true/false 选择"）
                        local curV = entry.value
                        if curV ~= "true" and curV ~= "false" then curV = "false" end
                        entry.value = curV
                        local btnW2 = math.max(24, math.floor(subValW * 0.42))
                        local bTrueX = subValX
                        local bFalseX = subValX + btnW2 + 4
                        local tHov2 = mX >= bTrueX and mX <= bTrueX + btnW2 and mY >= yOff and mY <= yOff + rowH
                        local fHov2 = mX >= bFalseX and mX <= bFalseX + btnW2 and mY >= yOff and mY <= yOff + rowH
                        draw.RoundedBox(3, bTrueX, yOff, btnW2, rowH,
                            (curV == "true") and Color(90, 140, 90) or (tHov2 and Color(60, 90, 60) or Color(45, 50, 55)))
                        draw.SimpleText("真", smallFont, bTrueX + btnW2 / 2, yOff + rowH / 2,
                            (curV == "true") and Color(255, 255, 255) or COL_TEXT,
                            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        RegisterIR(editor, node, "sv_gbtrue_" .. entryId, bTrueX, yOff, btnW2, rowH)
                        draw.RoundedBox(3, bFalseX, yOff, btnW2, rowH,
                            (curV == "false") and Color(140, 90, 90) or (fHov2 and Color(90, 60, 60) or Color(45, 50, 55)))
                        draw.SimpleText("假", smallFont, bFalseX + btnW2 / 2, yOff + rowH / 2,
                            (curV == "false") and Color(255, 255, 255) or COL_TEXT,
                            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        RegisterIR(editor, node, "sv_gbfalse_" .. entryId, bFalseX, yOff, btnW2, rowH)
                        if click and not Canvas.DraggingNode and not Canvas.ExpandedDropdown and not DropdownConsumed() then
                            if tHov2 then entry.value = "true"
                            elseif fHov2 then entry.value = "false" end
                        end
                    elseif itemType == "t" then
                        -- 文本：内联输入框
                        DrawInputField(node, mX, mY, click, "sv_value", subValX, yOff, subValW, rowH, smallFont,
                            tostring(entry.value or ""), "文本", entry)
                        RegisterIR(editor, node, "sv_gt_" .. entryId, subValX, yOff, subValW, rowH)
                    elseif itemType == "e" then
                        -- 对象：对象变量槽（点击展开仅对象变量的选择器）
                        local slotText = (entry.value and entry.value ~= "") and entry.value or "$ 对象变量槽"
                        local slotHov = mX >= subValX and mX <= subValX + subValW and mY >= yOff and mY <= yOff + rowH
                        draw.RoundedBox(3, subValX, yOff, subValW, rowH, slotHov and Color(70, 55, 55) or Color(50, 40, 40))
                        draw.SimpleText(ClipTextWidth(slotText, math.max(8, subValW - 8), smallFont), smallFont,
                            subValX + subValW / 2, yOff + rowH / 2,
                            (entry.value and entry.value ~= "") and Color(255, 170, 170) or Color(140, 100, 100),
                            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        RegisterIR(editor, node, "sv_ge_" .. entryId, subValX, yOff, subValW, rowH)
                        if click and slotHov and not Canvas.DraggingNode and not Canvas.GlobalVarSelector and not DropdownConsumed() then
                            VarOp.OpenGlobalVarSelector(editor, node,
                                subValX, yOff, subValW, scale, "set", nil, nil, "e", nil,
                                function(varName, dataType)
                                    entry.value = varName
                                end,
                                function() end)
                        end
                    elseif itemType == "g" then
                        -- 数组：数组变量槽（点击展开仅数组变量的选择器）
                        local slotText = (entry.value and entry.value ~= "") and entry.value or "选择数组变量"
                        local slotHov = mX >= subValX and mX <= subValX + subValW and mY >= yOff and mY <= yOff + rowH
                        draw.RoundedBox(3, subValX, yOff, subValW, rowH, slotHov and Color(60, 70, 60) or Color(45, 50, 45))
                        draw.SimpleText(ClipTextWidth(slotText, math.max(8, subValW - 8), smallFont), smallFont,
                            subValX + subValW / 2, yOff + rowH / 2,
                            (entry.value and entry.value ~= "") and Color(255, 200, 120) or Color(120, 120, 120),
                            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        RegisterIR(editor, node, "sv_gg_" .. entryId, subValX, yOff, subValW, rowH)
                        if click and slotHov and not Canvas.DraggingNode and not Canvas.GlobalVarSelector and not DropdownConsumed() then
                            VarOp.OpenGlobalVarSelector(editor, node,
                                subValX, yOff, subValW, scale, "set", nil, nil, "g", nil,
                                function(varName, dataType)
                                    entry.value = varName
                                end,
                                function() end)
                        end
                    else
                        -- 函数：'改为 #' 占位
                        draw.SimpleText("改为 #", smallFont, subValX, yOff + rowH / 2, COL_LINK,
                            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    end
                else
                    -- 类型 → 创建变量组件（templates.md L1145）：
                    -- 行内类型下拉（"n 数字" 等，字符+颜色与新建变量类型一致）+ "#名称" 输入（sv_itemName）
                    local typeNameList = {}
                    for _, vt in ipairs(VarOp.VarTypes) do
                        table.insert(typeNameList, vt.char .. " " .. vt.name)
                    end
                    local maxTOptW = 0
                    for _, o in ipairs(typeNameList) do
                        maxTOptW = math.max(maxTOptW, GetTW(o, smallFont))
                    end
                    local typeDdW = math.min(math.max(maxTOptW + charW, charW * 3), math.max(36, subValW - 40))
                    local curItemType = entry.itemType or "n"
                    local typeSel = 1
                    for ti, vt in ipairs(VarOp.VarTypes) do
                        if vt.id == curItemType then typeSel = ti break end
                    end
                    local typeId = "sv_gtype_" .. entryId
                    RegisterIR(editor, node, typeId, subValX, yOff, typeDdW, rowH)
                    Canvas.DrawDropdown(subValX, yOff, typeDdW, rowH, typeNameList, typeSel, node, typeId, nil, nil, smallFont, scale)
                    local typeDD = node.data.dropdowns and node.data.dropdowns[typeId]
                    if typeDD then
                        local newVt = VarOp.VarTypes[typeDD.selectedIndex]
                        if newVt and newVt.id ~= curItemType then
                            entry.itemType = newVt.id
                            -- 类型变更：值按新类型重新编排（默认值重置，数字槽状态清空）
                            entry.value = SetEntryDefaultValue(newVt.id)
                            local gvalNf = "sv_gval_" .. entryId
                            if node.data.numbers then node.data.numbers["libnum_" .. gvalNf] = nil end
                        end
                    end
                    local nameX = subValX + typeDdW + 4
                    local nameW = math.max(10, (cx + cw - 4) - nameX)
                    DrawInputField(node, mX, mY, click, "sv_itemName", nameX, yOff, nameW, rowH, smallFont,
                        tostring(entry.itemName or ""), "项名", entry)
                    RegisterIR(editor, node, "sv_gitemname_" .. entryId, nameX, yOff, nameW, rowH)
                end
            end
        elseif varType == "e" then
            -- 对象属性（templates.md L1106-1123）
            if entry.objMode == "empty" then
                -- 空对象：固定 '设为' + $ 对象变量槽（templates.md L1111）
                -- 无操作下拉（hasOpRow=false 整行作为值区）；"设为"标签 + 右侧仅选对象变量的槽
                draw.SimpleText(SET_OBJ_EMPTY_OP, smallFont, valX, yOff + rowH / 2, COL_SUB,
                    TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local lblW = GetTW(SET_OBJ_EMPTY_OP, smallFont)
                local slotX = valX + lblW + 8
                local slotW2 = math.max(10, (cx + cw - 4) - slotX)
                local slotText = (entry.value and entry.value ~= "") and entry.value or "$ 对象变量槽"
                local slotHov = mX >= slotX and mX <= slotX + slotW2 and mY >= yOff and mY <= yOff + rowH
                draw.RoundedBox(3, slotX, yOff, slotW2, rowH, slotHov and Color(70, 55, 55) or Color(50, 40, 40))
                draw.SimpleText(ClipTextWidth(slotText, math.max(8, slotW2 - 8), smallFont), smallFont,
                    slotX + slotW2 / 2, yOff + rowH / 2,
                    (entry.value and entry.value ~= "") and Color(255, 170, 170) or Color(140, 100, 100),
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                RegisterIR(editor, node, "sv_eempty_" .. entryId, slotX, yOff, slotW2, rowH)
                if click and slotHov and not Canvas.DraggingNode and not Canvas.GlobalVarSelector and not DropdownConsumed() then
                    VarOp.OpenGlobalVarSelector(editor, node,
                        slotX, yOff, slotW2, scale, "set", nil, nil, "e", nil,
                        function(varName, dataType)
                            entry.value = varName
                        end,
                        function() end)
                end
            elseif SET_OBJ_NUM_PROPS[opLabel] then
                -- 数值属性：{设为、增加、减少} 子操作下拉 + [lib] 数字槽（templates.md L1110）
                -- 子操作索引存 entry.objOpIdx（1=设为 2=增加 3=减少），解析器据此分派
                local subOps = {"设为", "增加", "减少"}
                if entry.objOpIdx == nil or entry.objOpIdx < 1 or entry.objOpIdx > #subOps then entry.objOpIdx = 1 end
                local subMaxW = 0
                for _, so in ipairs(subOps) do
                    subMaxW = math.max(subMaxW, GetTW(so, smallFont))
                end
                local subDdW = math.min(valW, subMaxW + charW * 1.6)
                local subId = "sv_eop_" .. entryId
                RegisterIR(editor, node, "sv_eop_dd_" .. entryId, valX, yOff, subDdW, rowH)
                Canvas.DrawDropdown(valX, yOff, subDdW, rowH, subOps, entry.objOpIdx, node, subId, nil, nil, smallFont, scale)
                local curSub = node.data.dropdowns and node.data.dropdowns[subId]
                if curSub then entry.objOpIdx = curSub.selectedIndex end
                local numX = valX + subDdW + 6
                local numW = math.max(10, (cx + cw - 4) - numX)
                local numField = "sv_e_" .. entryId
                if entry.value == nil or entry.value == "" then
                    node.data[numField] = 0
                else
                    node.data[numField] = entry.value
                end
                local _, slotW = DrawLibNumberBox(node, numField, numX, yOff, rowH, 0, smallFont)
                entry.value = node.data[numField]
                RegisterIR(editor, node, "sv_e_" .. entryId, numX, yOff, slotW or numW, rowH)
            elseif SET_OBJ_IMG_PROPS[opLabel] then
                -- 插图属性：插图槽组件（'为' + 粉 p 字符 + 图片下拉 + 悬停预览，templates.md L1120-1121）
                -- 下拉框选项为 data/kards_images 下的图片文件（draw 检测），悬停预览缩略图
                -- 切换检测：从其他属性（含插图间切换）进入插图属性时默认选中"无插图"，
                -- 不保留上一属性/上一次的残留值（entry.value 置空）；同属性连续帧不重置
                if entry._prevOpLabel ~= opLabel then
                    entry.value = ""
                end
                local weiW = GetTW("为", smallFont) + 6
                draw.SimpleText("为", smallFont, valX, yOff + rowH / 2, COL_SUB,
                    TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local pCharW = math.max(14, charW * 1.4)
                local pBtnX = valX + weiW
                local pHov = mX >= pBtnX and mX <= pBtnX + pCharW and mY >= yOff and mY <= yOff + rowH
                draw.RoundedBox(3, pBtnX, yOff, pCharW, rowH,
                    pHov and Color(120, 70, 90) or Color(60, 45, 50))
                draw.SimpleText("p", smallFont, pBtnX + pCharW / 2, yOff + rowH / 2,
                    Color(255, 150, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                local imgSlotX = pBtnX + pCharW + 4
                local imgSlotW = math.max(10, (cx + cw - 4) - imgSlotX)
                -- 当前选中图片：entry.value 存完整路径（与外观编辑器 imagePath 一致），显示取文件名；
                -- 值为空表示"无插图"（下拉首项）
                local curImg = tostring(entry.value or "")
                local curName = curImg:match("kards_images/(.+)$") or (curImg ~= "" and curImg or "")
                local slotHov = mX >= imgSlotX and mX <= imgSlotX + imgSlotW and mY >= yOff and mY <= yOff + rowH
                draw.RoundedBox(3, imgSlotX, yOff, imgSlotW, rowH, slotHov and Color(60, 70, 60) or Color(45, 50, 45))
                draw.SimpleText(ClipTextWidth(curName ~= "" and curName or "无插图", math.max(8, imgSlotW - 8), smallFont),
                    smallFont, imgSlotX + imgSlotW / 2, yOff + rowH / 2,
                    curName ~= "" and Color(255, 200, 120) or Color(120, 120, 120),
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                RegisterIR(editor, node, "sv_eimg_p_" .. entryId, pBtnX, yOff, pCharW, rowH)
                RegisterIR(editor, node, "sv_eimg_" .. entryId, imgSlotX, yOff, imgSlotW, rowH)
                -- 点击 p 或槽 → 展开图片下拉框（首项"无插图"，后续为 data/kards_images 文件；
                -- _imagePreview 启用悬停预览）
                if click and not Canvas.DraggingNode and not Canvas.ExpandedDropdown and not DropdownConsumed()
                   and (pHov or slotHov) then
                    local imgFiles, _ = file.Find("kards_images/*", "DATA")
                    local optList = { "无插图" }
                    if imgFiles then
                        for _, f in ipairs(imgFiles) do
                            if f and f ~= "" then
                                local dup = false
                                for _, o in ipairs(optList) do
                                    if o == f then dup = true break end
                                end
                                if not dup then table.insert(optList, f) end
                            end
                        end
                    end
                    if #optList > 0 then
                        surface.SetFont(smallFont)
                        local maxOptW = 0
                        for _, o in ipairs(optList) do
                            maxOptW = math.max(maxOptW, surface.GetTextSize(o))
                        end
                        local colW2 = math.max(maxOptW + 22, 100)
                        local screenH = ScrH()
                        local ddY = yOff + rowH + 2
                        local maxRows = math.floor((screenH - ddY - 5) / rowH)
                        maxRows = math.max(1, math.min(maxRows, #optList))
                        local numCols = math.ceil(#optList / maxRows)
                        local totalDropW2 = numCols * colW2
                        local dropH = numCols == 1 and (#optList * rowH + 10) or (maxRows * rowH + 10)
                        local dropX = valX
                        if dropX + totalDropW2 > ScrW() then
                            dropX = ScrW() - totalDropW2 - 10
                        end
                        Canvas.ExpandedDropdown = (node.id or "?") .. "_sv_eimg_" .. entryId
                        Canvas.ExpandedDropdownInfo = {
                            x = valX, y = yOff, width = valW, height = rowH,
                            nodeId = node.id, dropdownId = "sv_eimg_" .. entryId,
                            options = optList,
                            dropdownX = dropX, dropdownY = ddY,
                            totalWidth = totalDropW2, expandedColumnWidth = colW2,
                            maxRowsPerColumn = maxRows, dropdownH = dropH,
                            numColumns = numCols,
                            tooltipMap = nil,
                            optFont = smallFont, canvasScale = scale or 1,
                            dropdownData = {
                                selectedIndex = 1,
                                lastClickTime = 0,
                                options = optList,
                                _imagePreview = true,
                                _onSelect = function(idx, ddState)
                                    local sel = ddState.options and ddState.options[idx]
                                    if sel then
                                        if sel == "无插图" then
                                            entry.value = ""
                                        else
                                            entry.value = "../data/kards_images/" .. sel
                                        end
                                    end
                                end,
                            },
                        }
                    end
                end
            elseif SET_OBJ_KEYWORD_PROPS[opLabel] then
                -- 词条属性：词条多选组件（templates.md L1122）
                -- 首次进入时带出目标对象变量的现有词条作为初始值；点击槽打开多选浮层
                if entry.kwInit ~= true then
                    entry.kwInit = true
                    local initKeys = nil
                    if editor and editor.variables and editor.variables["e"] then
                        for _, v in ipairs(editor.variables["e"]) do
                            if VarOp.GetVarDisplayName(v) == entry.varName then
                                initKeys = v.cardAppearance and v.cardAppearance.keywords
                                break
                            end
                        end
                    end
                    if initKeys and type(initKeys) == "table" and #initKeys > 0 then
                        local parts = {}
                        for _, k in ipairs(initKeys) do
                            if KARDS.CardEditor.Data.KeywordDisplayNames[k] then
                                table.insert(parts, k)
                            end
                        end
                        if #parts > 0 then entry.value = table.concat(parts, ",") end
                    end
                end
                -- 显示：已选词条中文名（逗号拼接，截断）
                local kwSel = ParseKeywordValue(entry.value)
                local kwParts = {}
                for _, k in ipairs(GetAllKeywordKeys()) do
                    if kwSel[k] then
                        table.insert(kwParts, KARDS.CardEditor.Data.KeywordDisplayNames[k] or k)
                    end
                end
                local kwText = #kwParts > 0 and table.concat(kwParts, "、") or "选择词条"
                local kwHov = mX >= valX and mX <= valX + valW and mY >= yOff and mY <= yOff + rowH
                draw.RoundedBox(3, valX, yOff, valW, rowH,
                    kwHov and Color(60, 70, 60) or Color(45, 50, 45))
                draw.SimpleText(ClipTextWidth(kwText, math.max(8, valW - 8), smallFont), smallFont,
                    valX + valW / 2, yOff + rowH / 2,
                    #kwParts > 0 and Color(200, 220, 150) or Color(120, 120, 120),
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                RegisterIR(editor, node, "sv_ekw_" .. entryId, valX, yOff, valW, rowH)
                if click and kwHov and not Canvas.DraggingNode and not Canvas.KeywordMultiSelect and not DropdownConsumed() then
                    VarOp.OpenKeywordMultiSelect(editor, node, entry, entryId, valX, yOff, valW, scale)
                end
            elseif SET_OBJ_TEXT_SLOT_PROPS[opLabel] then
                -- 文本槽属性（卡牌名称/描述/历史文本）：文本槽组件（templates.md L1118-1119）
                -- 左侧绿色 t 字符：点击在"直接输入 / 文本变量引用"间切换
                --   直接输入模式 → 展开文本变量下拉框（全局文本变量 + 数据线传入）；选中后
                --     输入框填充变量名（值存 "var:<变量名>"，即引用模式）
                --   引用模式 → 再次点击 t 或输入区，清空进入直接输入
                local isTextRef = tostring(entry.value or ""):sub(1, 4) == "var:"
                local tCharW = math.max(14, charW * 1.4)
                local tBtnX = valX
                local tHov = mX >= tBtnX and mX <= tBtnX + tCharW and mY >= yOff and mY <= yOff + rowH
                draw.RoundedBox(3, tBtnX, yOff, tCharW, rowH,
                    tHov and Color(70, 120, 80) or Color(45, 60, 50))
                draw.SimpleText("t", smallFont, tBtnX + tCharW / 2, yOff + rowH / 2,
                    Color(144, 238, 144), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                local textInX = valX + tCharW + 4
                local textInW = math.max(10, (cx + cw - 4) - textInX)
                RegisterIR(editor, node, "sv_ets_t_" .. entryId, tBtnX, yOff, tCharW, rowH)
                RegisterIR(editor, node, "sv_ets_" .. entryId, textInX, yOff, textInW, rowH)
                if click and not Canvas.DraggingNode and not Canvas.ExpandedDropdown and not DropdownConsumed() then
                    if isTextRef then
                        -- 引用模式：点击 t 或输入区均清空进入直接输入
                        local inHov = mX >= textInX and mX <= textInX + textInW and mY >= yOff and mY <= yOff + rowH
                        if tHov or inHov then entry.value = "" end
                    elseif tHov then
                        -- 直接输入模式：点击 t 展开文本变量下拉框
                        local tOpts = GetTextVarOptions(editor, node)
                        if #tOpts > 0 then
                            surface.SetFont(smallFont)
                            local maxOptW = 0
                            for _, o in ipairs(tOpts) do
                                maxOptW = math.max(maxOptW, surface.GetTextSize(o))
                            end
                            local colW2 = math.max(maxOptW + 22, 100)
                            local screenH = ScrH()
                            local ddY = yOff + rowH + 2
                            local maxRows = math.floor((screenH - ddY - 5) / rowH)
                            maxRows = math.max(1, math.min(maxRows, #tOpts))
                            local numCols = math.ceil(#tOpts / maxRows)
                            local totalDropW2 = numCols * colW2
                            local dropH = numCols == 1 and (#tOpts * rowH + 10) or (maxRows * rowH + 10)
                            local dropX = valX
                            if dropX + totalDropW2 > ScrW() then
                                dropX = ScrW() - totalDropW2 - 10
                            end
                            Canvas.ExpandedDropdown = (node.id or "?") .. "_sv_ets_" .. entryId
                            Canvas.ExpandedDropdownInfo = {
                                x = valX, y = yOff, width = valW, height = rowH,
                                nodeId = node.id, dropdownId = "sv_ets_" .. entryId,
                                options = tOpts,
                                dropdownX = dropX, dropdownY = ddY,
                                totalWidth = totalDropW2, expandedColumnWidth = colW2,
                                maxRowsPerColumn = maxRows, dropdownH = dropH,
                                numColumns = numCols,
                                tooltipMap = nil,
                                optFont = smallFont, canvasScale = scale or 1,
                                dropdownData = {
                                    selectedIndex = 1,
                                    lastClickTime = 0,
                                    options = tOpts,
                                    _onSelect = function(idx, ddState)
                                        local sel = ddState.options and ddState.options[idx]
                                        if sel then entry.value = "var:" .. sel end
                                    end,
                                },
                            }
                        end
                    end
                end
                if isTextRef then
                    -- 引用模式：输入区只读显示变量名（点击清空，见上方点击处理）
                    draw.SimpleText(ClipTextWidth(tostring(entry.value):sub(5), math.max(8, textInW - 8), smallFont),
                        smallFont, textInX + 4, yOff + rowH / 2,
                        Color(144, 238, 144), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                else
                    -- 直接输入模式：内联输入框
                    DrawInputField(node, mX, mY, click, "sv_value", textInX, yOff, textInW, rowH, smallFont,
                        tostring(entry.value or ""), "文本", entry)
                end
            elseif opLabel == "单位类型" then
                -- 单位类型：单选 {步兵、炮兵、坦克、战斗机、轰炸机}（readme 7.3）
                -- 值存英文内部名（与卡牌接口 UnitTypes 一致），显示中文
                local utList = {"步兵", "炮兵", "坦克", "战斗机", "轰炸机"}
                local utIdx = 1
                for i, cn in ipairs(utList) do
                    if UNIT_TYPE_CN_TO_EN[cn] == entry.value then utIdx = i break end
                end
                local utId = "sv_eut_" .. entryId
                RegisterIR(editor, node, "sv_eut_dd_" .. entryId, valX, yOff, valW, rowH)
                Canvas.DrawDropdown(valX, yOff, valW, rowH, utList, utIdx, node, utId, nil, nil, smallFont, scale)
                local curUT = node.data.dropdowns and node.data.dropdowns[utId]
                if curUT then
                    entry.value = UNIT_TYPE_CN_TO_EN[utList[curUT.selectedIndex] or "步兵"]
                end
            elseif opLabel == "子类型" then
                -- 子类型：单选（data/kards_subtypes.txt 词库，随时可调整）+ 新建
                -- 值存子类型名；切换进入本属性时重置新建状态与残留值
                if entry._prevOpLabel ~= opLabel then
                    entry._subtypeNew = false
                    entry._subtypeNewName = nil
                    entry.value = ""
                end
                if entry._subtypeNew ~= true then
                    -- 槽显示当前子类型；点击展开下拉（词库项 + "＋ 新建子类型…"尾项）
                    local slotText = (entry.value and entry.value ~= "") and entry.value or "选择子类型"
                    local slotHov = mX >= valX and mX <= valX + valW and mY >= yOff and mY <= yOff + rowH
                    draw.RoundedBox(3, valX, yOff, valW, rowH, slotHov and Color(60, 60, 70) or Color(45, 45, 50))
                    draw.SimpleText(ClipTextWidth(slotText, math.max(8, valW - 8), smallFont), smallFont,
                        valX + valW / 2, yOff + rowH / 2,
                        (entry.value and entry.value ~= "") and Color(200, 200, 255) or Color(120, 120, 120),
                        TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    RegisterIR(editor, node, "sv_est_" .. entryId, valX, yOff, valW, rowH)
                    if click and slotHov and not Canvas.DraggingNode and not Canvas.ExpandedDropdown and not DropdownConsumed() then
                        local stOpts = LoadSubtypeOptions()
                        table.insert(stOpts, SUBTYPE_CREATE_OPT)
                        -- 复用插图式多列下拉（选项多时自动分列）
                        surface.SetFont(smallFont)
                        local maxOptW = 0
                        for _, o in ipairs(stOpts) do
                            maxOptW = math.max(maxOptW, surface.GetTextSize(o))
                        end
                        local colW2 = math.max(maxOptW + 22, 100)
                        local screenH = ScrH()
                        local ddY = yOff + rowH + 2
                        local maxRows = math.floor((screenH - ddY - 5) / rowH)
                        maxRows = math.max(1, math.min(maxRows, #stOpts))
                        local numCols = math.ceil(#stOpts / maxRows)
                        local totalDropW2 = numCols * colW2
                        local dropH = numCols == 1 and (#stOpts * rowH + 10) or (maxRows * rowH + 10)
                        local dropX = valX
                        if dropX + totalDropW2 > ScrW() then
                            dropX = ScrW() - totalDropW2 - 10
                        end
                        Canvas.ExpandedDropdown = (node.id or "?") .. "_sv_est_" .. entryId
                        Canvas.ExpandedDropdownInfo = {
                            x = valX, y = yOff, width = valW, height = rowH,
                            nodeId = node.id, dropdownId = "sv_est_" .. entryId,
                            options = stOpts,
                            dropdownX = dropX, dropdownY = ddY,
                            totalWidth = totalDropW2, expandedColumnWidth = colW2,
                            maxRowsPerColumn = maxRows, dropdownH = dropH,
                            numColumns = numCols,
                            tooltipMap = nil,
                            optFont = smallFont, canvasScale = scale or 1,
                            dropdownData = {
                                selectedIndex = 1,
                                lastClickTime = 0,
                                options = stOpts,
                                _onSelect = function(idx, ddState)
                                    local sel = ddState.options and ddState.options[idx]
                                    if sel then
                                        if sel == SUBTYPE_CREATE_OPT then
                                            entry._subtypeNew = true
                                            entry.value = ""
                                        else
                                            entry.value = sel
                                        end
                                    end
                                end,
                            },
                        }
                    end
                else
                    -- 新建模式：行内输入框（实时写 entry.value）+ 右侧确认按钮（追加词库并退出）
                    local inW = math.max(10, valW - btnH - 6)
                    DrawInputField(node, mX, mY, click, "sv_value", valX, yOff, inW, rowH, smallFont,
                        tostring(entry.value or ""), "新子类型", entry)
                    local okBtnX = valX + inW + 6
                    local okBtnW = math.max(20, valW - inW - 6)
                    local okHov = mX >= okBtnX and mX <= okBtnX + okBtnW and mY >= yOff and mY <= yOff + rowH
                    draw.RoundedBox(3, okBtnX, yOff, okBtnW, rowH, okHov and Color(90, 120, 90) or Color(55, 70, 55))
                    draw.SimpleText("✓", smallFont, okBtnX + okBtnW / 2, yOff + rowH / 2,
                        Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    RegisterIR(editor, node, "sv_est_ok_" .. entryId, okBtnX, yOff, okBtnW, rowH)
                    if click and okHov and not Canvas.DraggingNode then
                        local newName = tostring(entry.value or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if newName ~= "" then
                            entry.value = newName
                            AppendSubtypeOption(newName)
                        else
                            entry.value = nil
                        end
                        entry._subtypeNew = false
                    end
                end
            else
                -- 未单独定义控件的属性（品质等）：文本输入框（templates.md L1125）
                DrawInputField(node, mX, mY, click, "sv_value", valX, yOff, valW, rowH, smallFont,
                    tostring(entry.value or ""), "文本", entry)
                RegisterIR(editor, node, "sv_et_" .. entryId, valX, yOff, valW, rowH)
            end
        elseif varType == "f" then
            -- 函数：'改为' #（简化：函数值选择未接入函数子编辑器，仅占位显示，见验收）
            draw.SimpleText("改为 #", smallFont, valX, yOff + rowH / 2, COL_LINK,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        else
            draw.SimpleText("—", smallFont, valX, yOff + rowH / 2, Color(100, 100, 100),
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        -- 记录本帧操作标签（插图/子类型切换检测用：属性切换时重置默认值/新建状态）
        entry._prevOpLabel = opLabel
        yOff = yOff + rowH + spacing
    end

    -- 循环结束后统一执行条目删除（避免 ipairs 遍历中修改数组导致错位）
    if deleteIdx then
        table.remove(node.data._setEntries, deleteIdx)
    end

    -- "+ 修改全局变量" 按钮（常驻底部，可添加多个设置行，templates.md L1087"按钮下移、原位插入"）
    local addBtnY = yOff + 2
    local addBtnW = cw - 4
    local addBtnH = btnH
    local addBtnX = cx + 2
    local bHov = mX >= addBtnX and mX <= addBtnX + addBtnW
            and mY >= addBtnY and mY <= addBtnY + addBtnH
    draw.RoundedBox(4, addBtnX, addBtnY, addBtnW, addBtnH, bHov and COL_BTN_HOVER or COL_BTN)
    draw.SimpleText("+ 修改全局变量", compFont, cx + cw / 2, addBtnY + addBtnH / 2,
        Color(200, 220, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    RegisterIR(editor, node, "sv_add_btn", addBtnX, addBtnY, addBtnW, addBtnH)
    -- 本帧已消费下拉框选项点击时忽略：最后一行下拉框选项与按钮区域重叠，防止误开浮层
    if click and bHov and not Canvas.DraggingNode and not Canvas.GlobalVarSelector and not DropdownConsumed() then
        VarOp.OpenGlobalVarSelector(editor, node,
            addBtnX, addBtnY, addBtnW, scale, "set", nil, nil, nil, nil,
            function(varName, dataType, v)
                -- 浮层 dataType 为 INE id（布尔 p），转回内部 id（b）后存入条目
                dataType = INEToVarTypeId(dataType)
                table.insert(node.data._setEntries, {
                    id = "sv" .. node.data._nextEntryId,
                    varName = varName,
                    varType = dataType,
                    -- 对象类别：单位/指令反制/空对象（templates.md L1106-1111）；非对象类型置空
                    objMode = (dataType == "e") and GetObjModeFromVar(v) or nil,
                    source = "global",
                    opIdx = 1,
                    objOpIdx = 1,
                    value = SetEntryDefaultValue(dataType),
                })
                node.data._nextEntryId = node.data._nextEntryId + 1
            end,
            function() end)
    end

    -- 高度每帧按当前画布缩放重算（世界单位 = 内容像素 / scale，含标题栏偏移 40）：
    -- 画布缩放变化时节点高度立即贴合内容（R2）
    local totalPx = padding
    for _ in ipairs(node.data._setEntries) do
        -- 每行固定 2 行：目标变量行 + 操作/值行（值控件与操作下拉同排，不再单独占行）
        totalPx = totalPx + rowH * 2 + spacing + entrySpacing
    end
    totalPx = totalPx + btnH + spacing + padding
    node.height = math.max(120, math.floor(40 + totalPx / scale))
end

-- ====================================================================================
-- 3. ConvertExtractVariable 节点（正式版内容：测试版放弃实现，见 templates.md"正式版再做"；
--    暂以"获取单位防御力""获取单位攻击力"两个节点替代；下方整个函数块已用 --[[ ]] 注释跳过）
-- ====================================================================================
--[[ 正式版内容：转换与提取节点（测试版放弃，函数体保留供正式版恢复）
function VarOp.DrawConvertExtractVariable(node, cx, cy, cw, ch, scale)
    local mX, mY = gui.MouseX(), gui.MouseY()
    local click = INE._frameMouseJustPressed or false
    local editor = node and node.editor
    local compFont = GetScaledFont(scale, 14)
    local smallFont = GetScaledFont(scale, 12)
    local charW = GetTW("字", compFont)

    local rowH = math.max(16, math.floor(22 * scale))
    local spacing = math.max(2, math.floor(4 * scale))

    node.data = node.data or {}

    -- 根据输入类型与操作索引计算输出数据类型（nil 表示无输出点）
    -- 供输出数据点自动接管使用：输出端口名称格式 [输入类型:变量名]，如 "n:x"
    local function GetConvertOutputType(inputType, opIdx)
        if inputType == "n" then
            if opIdx == 1 then return "t" end  -- 转为文本 → 文本
            return "n"  -- 四舍五入/向上取整/向下取整/保留/相对于 → 数字
        elseif inputType == "g" then
            if opIdx == 1 then return "n" end  -- 提取项目总数 → 数字
            return nil  -- 提取第n项 → 元素类型未知，无输出点
        elseif inputType == "t" then
            if opIdx == 1 then return "n" end  -- 字符数 → 数字
            return "t"  -- 第n个字符/最后一个字符 → 文本
        elseif inputType == "f" then
            return "t"  -- 提取转译文本 → 文本
        end
        return nil
    end

    -- 检测数据输入点的类型与变量名：从 dataConnections 中查找连接到本节点的数据线
    local connectedInputType = nil
    local connectedInputName = nil
    if editor and editor.dataConnections then
        for _, conn in ipairs(editor.dataConnections) do
            if conn.toNode == node.id then
                connectedInputType = conn.dataType
                connectedInputName = conn.variableName
                break
            end
        end
    end

    local yOff = cy
    local contentBottom = yOff  -- 跟踪内容底部，用于高度计算

    if connectedInputType then
        -- 有数据接入：显示输入类型标签 + 横版操作单选组件
        -- 标签格式 [类型:变量名]，优先使用数据线传输的变量名，回退类型中文名
        local inputDisplayName = connectedInputName
        if not inputDisplayName or inputDisplayName == "" then
            inputDisplayName = connectedInputType
            for _, vt in ipairs(VarOp.VarTypes) do
                if vt.id == connectedInputType then
                    inputDisplayName = vt.name
                    break
                end
            end
        end
        local labelText = "输入: [" .. connectedInputType .. ":" .. inputDisplayName .. "]"
        local lblW = GetTW(labelText, smallFont) + 8

        draw.SimpleText(labelText, smallFont, cx + 4, yOff + rowH/2, COL_LINK,
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 操作列表（根据输入类型）
        local opList = {}
        if connectedInputType == "n" then
            opList = {"转为文本", "四舍五入", "向上取整", "向下取整", "保留", "相对于"}
        elseif connectedInputType == "g" then
            opList = {"提取项目总数", "提取第n项"}
        elseif connectedInputType == "t" then
            opList = {"字符数", "第n个字符", "最后一个字符"}
        elseif connectedInputType == "f" then
            opList = {"提取转译文本"}
        else
            opList = {"无可用操作"}
        end

        -- 操作下拉框（横版：标签后面紧接下拉框）
        local opDdX = cx + 4 + lblW
        local opDdW = math.min(cw - lblW - 8, charW * 6)

        local opId = "cv_op_dd_" .. node.id
        local oldOpIdx = node.data._selectedOpIdx or 1

        RegisterIR(editor, node, "cv_op_dd", opDdX, yOff, opDdW, rowH)

        Canvas.DrawDropdown(opDdX, yOff, opDdW, rowH, opList, oldOpIdx, node,
            opId, nil, nil, smallFont, scale)

        local curOpDD = node.data.dropdowns and node.data.dropdowns[opId]
        if curOpDD then
            local curIdx = curOpDD.selectedIndex
            if curIdx ~= oldOpIdx then
                node.data._selectedOpIdx = curIdx
                -- 下拉框选中变化即视为选中，不设"取消选中"
                -- 输出数据点由函数末尾的自动接管逻辑统一更新（类型 + 变量名）
            end
        end

        local curOpIdx = node.data._selectedOpIdx or 1
        local selectedOpLabel = opList[curOpIdx] or opList[1]

        yOff = yOff + rowH + spacing
        contentBottom = yOff + math.max(2, math.floor(4 * scale))

        -- 子组件（根据选中操作显示参数输入区域）
        local hasSubComponent = false

        if connectedInputType == "n" and selectedOpLabel == "保留" then
            hasSubComponent = true
            -- "保留 N 位小数"（横版：标签 + [lib] 数字槽 + 后缀）
            local subLbl = "保留"
            local subLblW = GetTW(subLbl, smallFont) + 6
            draw.SimpleText(subLbl, smallFont, cx + 4, yOff + rowH/2, COL_LABEL,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            -- [lib] 数字槽带箭头区，boxW 为预留宽度；select 模式实宽由选中文本决定，
            -- 以 DrawLibNumberBox 返回的实宽偏移后缀文字，避免文字与数字槽重合（V3）
            local boxW = math.min(math.max(charW * 3, math.floor(rowH * 1.6)),
                cw - subLblW - charW * 5 - 12)
            local _, numSlotW = DrawLibNumberBox(node, "_subNumVal", cx + 4 + subLblW, yOff, rowH, 2, compFont)
            local slotW = numSlotW or boxW
            RegisterIR(editor, node, "cv_sub_num", cx + 4 + subLblW, yOff, slotW, rowH)
            draw.SimpleText("位小数", smallFont, cx + 4 + subLblW + slotW + 4,
                yOff + rowH/2, COL_SUB, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        elseif connectedInputType == "n" and selectedOpLabel == "相对于" then
            hasSubComponent = true
            -- "相对于 N 归一化"（横版：标签 + [lib] 数字槽 + 后缀）
            local subLbl = "相对于"
            local subLblW = GetTW(subLbl, smallFont) + 6
            draw.SimpleText(subLbl, smallFont, cx + 4, yOff + rowH/2, COL_LABEL,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            local boxW = math.min(math.max(charW * 3, math.floor(rowH * 1.6)),
                cw - subLblW - charW * 5 - 12)
            local _, refSlotW = DrawLibNumberBox(node, "_subRefVal", cx + 4 + subLblW, yOff, rowH, 100, compFont)
            local slotW = refSlotW or boxW
            RegisterIR(editor, node, "cv_sub_ref", cx + 4 + subLblW, yOff, slotW, rowH)
            draw.SimpleText("归一化", smallFont, cx + 4 + subLblW + slotW + 4,
                yOff + rowH/2, COL_SUB, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        elseif connectedInputType == "g" and selectedOpLabel == "提取第n项" then
            hasSubComponent = true
            -- "第 N 项内容"（横版：标签 + 数字槽 + 后缀）
            local subLbl = "第"
            local subLblW = GetTW(subLbl, smallFont) + 6
            draw.SimpleText(subLbl, smallFont, cx + 4, yOff + rowH/2, COL_LABEL,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            local boxW = math.min(charW * 3, cw - subLblW - charW * 5 - 12)
            local nId = "cv_sub_idx_" .. node.id
            RegisterIR(editor, node, "cv_sub_idx", cx + 4 + subLblW, yOff, boxW, rowH)
            local oldVal = node.data._subIdxVal or 1
            local newVal = Canvas.DrawNumberBox(cx + 4 + subLblW, yOff, rowH,
                oldVal, node, nId, nil, compFont)
            if newVal ~= nil then node.data._subIdxVal = newVal end
            draw.SimpleText("项内容", smallFont, cx + 4 + subLblW + boxW + 4,
                yOff + rowH/2, COL_SUB, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        elseif connectedInputType == "t" and selectedOpLabel == "第n个字符" then
            hasSubComponent = true
            -- "第 N 个字"（横版：标签 + 数字槽 + 后缀）
            local subLbl = "第"
            local subLblW = GetTW(subLbl, smallFont) + 6
            draw.SimpleText(subLbl, smallFont, cx + 4, yOff + rowH/2, COL_LABEL,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            local boxW = math.min(charW * 3, cw - subLblW - charW * 5 - 12)
            local nId = "cv_sub_char_" .. node.id
            RegisterIR(editor, node, "cv_sub_char", cx + 4 + subLblW, yOff, boxW, rowH)
            local oldVal = node.data._subCharVal or 1
            local newVal = Canvas.DrawNumberBox(cx + 4 + subLblW, yOff, rowH,
                oldVal, node, nId, nil, compFont)
            if newVal ~= nil then node.data._subCharVal = newVal end
            draw.SimpleText("个字", smallFont, cx + 4 + subLblW + boxW + 4,
                yOff + rowH/2, COL_SUB, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end

        if hasSubComponent then
            contentBottom = yOff + rowH + spacing
        end

        -- 计算节点高度：从 cy 到 contentBottom（世界单位 = 内容像素 / scale，含标题栏偏移 40，R2）
        local totalH = (contentBottom - cy) + math.max(4, math.floor(8 * scale))
        node.height = math.max(80, math.floor(40 + totalH / scale))

        -- 输出数据点自动接管：
        -- 按输入类型+选中操作计算输出端口（类型 + 名称），名称规则：
        -- 输入与输出同类型时名称直接为变量名（如四舍五入 n→n → "数量"），
        -- 异类型时名称带输入类型前缀（如数字x转为文本 → "n:x"），
        -- 与当前端口逐字段比较（PortDataEqual），变化才重建，
        -- 覆盖数据线增删、变量改名、操作切换、端口表重建等所有情况。
        local outRef = nil
        local outTypeId = GetConvertOutputType(connectedInputType, node.data._selectedOpIdx or 1)
        if outTypeId then
            outRef = VarOp.TypeRefs[outTypeId]
        end
        local expectedPort = nil
        if outRef then
            -- 输入与输出同类型时不带类型前缀，名称直接为变量显示名
            local portName = inputDisplayName
            if outRef.id ~= connectedInputType then
                portName = connectedInputType .. ":" .. inputDisplayName
            end
            expectedPort = { id = outRef.id, name = portName }
        end
        local curPorts = node.selectedOutputTypes or {}
        local needRebuild = false
        if expectedPort then
            if #curPorts ~= 1 then
                needRebuild = true
            elseif not PortDataEqual(curPorts[1], expectedPort) then
                needRebuild = true
            end
        elseif #curPorts ~= 0 then
            needRebuild = true
        end
        if needRebuild then
            node.selectedOutputTypes = expectedPort and {expectedPort} or {}
            SyncConnectionVarNames(node, node.selectedOutputTypes)
            if editor then
                INE:UpdateDataPortPositions(editor, node, "output")
            end
        end
    else
        -- 无数据接入：显示初始提示（居中显示防止溢出）
        local hintH = math.max(math.min(ch or 80, 80), 60) - 8
        local msgFont = GetScaledFont(scale, 13)
        draw.SimpleText("从左侧数据输入点接入数据线", msgFont, cx + cw / 2, cy + hintH / 2 - math.max(6, math.floor(8 * scale)),
            COL_SUB, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        local hintFont = GetScaledFont(scale, 11)
        draw.SimpleText("支持: 数字・数组・文本・函数", hintFont, cx + cw / 2, cy + hintH / 2 + math.max(6, math.floor(8 * scale)),
            Color(100, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        -- 重置高度到初始值
        node.height = 80
        -- 无输入时清空输出数据点（自动接管：不残留上一数据线的输出端口）
        if node.selectedOutputTypes and #node.selectedOutputTypes > 0 then
            node.selectedOutputTypes = {}
            if editor then
                INE:UpdateDataPortPositions(editor, node, "output")
            end
        end
    end
end
-- 正式版内容：转换与提取节点函数体注释结束（下方单行 双右方括号 关闭上方 --[[ 注释块）
]]

-- ====================================================================================
-- 4. EvaluateRelationship 节点
-- ====================================================================================

-- 辅助：获取数据类型颜色（用于操作数槽的类型标签）
local function GetDataTypeColor(dataType)
    if dataType then
        for _, vt in ipairs(VarOp.VarTypes) do
            if vt.id == dataType then
                local dt = INE and INE.GetDataTypeById and INE.GetDataTypeById(dataType)
                return (dt and dt.color) or vt.color
            end
        end
    end
    return COL_LINK
end

-- 辅助：右值模式推导（由左类型 + 运算符决定，templates.md L1259-1260）
--   n        → literal（数字[lib]槽）
--   e        → "是空/非空" 无右值（none）；=、≠ 同类型变量槽（var）
--   b/t/g    → 正式版内容（nil，运算符与右值均不绘制）
-- @param lType string 左操作数类型 id（"" = 未选择）
-- @param op    string 当前运算符
-- @return string|nil 右值模式（nil = 不支持的类型，运算符与右值不绘制）
local function EvalExpectMode(lType, op)
    if lType == "n" then return "literal" end
    if lType == "e" then
        if op == "是空" or op == "非空" then return "none" end
        return "var"
    end
    return nil
end

-- 辅助：动态计算 EvaluateRelationship 节点高度
-- 布局：条件行×N + 添加按钮（无"条件:"总标题行，每行自带"条件N:"序号）
-- 注意：条件行的变量选择器为浮层（非组件），展开/关闭不参与节点宽高计算（cl_ine_var_op_nodes.lua L386）
local function RecalcEvaluateHeight(node, scale)
    local rowH = math.max(16, math.floor(22 * scale))
    local btnH = math.max(20, math.floor(24 * scale))
    local spacing = math.max(2, math.floor(3 * scale))
    local count = node.data and node.data._conditions and #node.data._conditions or 0
    -- 内容需求（屏幕像素）：条件行 + 添加按钮（含按钮上方间距与底部余量）
    local need = count * (rowH + spacing) + (2 + btnH) + 10
    -- node.height 为世界单位：nodeH = height*scale，内容区起点 cy = nodeY + 30*scale（标题栏），
    -- 可用内容高 = nodeH - 40*scale（DrawNode 传入 ch），故 height 需 ≥ 40 + 内容需求/scale
    node.height = math.max(120, math.floor(40 + need / scale))
end

-- 辅助："判断变量关系"数据输入点接入数据线时，自动创建/填充比较项（左侧值 = 刚接入的值）
-- 优先填充已有的空比较项（左侧未选择），否则在末尾新建一行（自动携带 AND 连接符）。
-- 由 cl_ine_input_handling.lua 数据连接创建成功后调用。
function VarOp.EvalAutoFillLeft(editor, node, connId, dataType, varName)
    if not node or not node.data then return end
    local conds = node.data._conditions
    if not conds then return end
    -- 查找空比较项：左侧未选择（varName 与 dataType 均为空）
    local target = nil
    for _, c in ipairs(conds) do
        if (c.left.varName or "") == "" and (c.left.dataType or "") == "" then
            target = c
            break
        end
    end
    if not target then
        target = {
            left = { varName = "", dataType = "" },
            operator = "=",
            lastOperator = "=",
            right = { mode = "literal", varName = "", dataType = "", literal = "" },
        }
        table.insert(conds, target)
        if node.data._connectors then
            table.insert(node.data._connectors, "AND")
        end
    end
    -- 填充左侧为数据线输入（与 OpenEvalSelector 选择回调一致）
    target.left = {
        source = "input",
        connId = connId,
        varName = varName,
        dataType = dataType,
    }
    target.operator = "="
    target.lastOperator = "="
    target.right = {
        mode = EV_RIGHT_MODE[dataType] or "literal",
        varName = "", dataType = "", literal = "",
    }
    -- 重算节点高度（新增行后按钮不溢出）
    local scale = editor and editor.canvasScale or 1
    RecalcEvaluateHeight(node, scale)
end

-- 辅助：打开"判断变量关系"条件行的变量选择器浮层（左/右操作数共用）
-- 左操作数附带"数据线输入"分组（列出所有连入本节点的数据线，一个输入点可接入多条）；
-- 右操作数按左类型过滤（同类型比较）。
-- 浮层为临时元素（非组件），打开/选择/关闭均不触发节点宽高重算（cl_ine_var_op_nodes.lua L386）。
local function OpenEvalSelector(editor, node, cond, idx, side, x, y, w, scale)
    local isLeft = (side == "left")
    -- 左操作数选择器附带"数据线输入"分组
    local extraGroups = nil
    if isLeft and editor and editor.dataConnections then
        local items = {}
        for _, conn in ipairs(editor.dataConnections) do
            if conn.toNode == node.id then
                local dName = conn.variableName or ""
                if dName == "" then
                    for _, vt in ipairs(VarOp.VarTypes) do
                        -- 数据类型比较用映射后的 INE 类型 id（VarTypes.id 如 b 对应 p）
                        if (DATA_TYPE_MAP[vt.id] or vt.id) == conn.dataType then dName = vt.name break end
                    end
                end
                local srcName = nil
                local srcNode = INE:GetNodeByID(editor, conn.fromNode)
                if srcNode then
                    srcName = srcNode.displayName or srcNode.name
                end
                table.insert(items, {
                    name = dName, dataType = conn.dataType,
                    connId = conn.id, fromNodeName = srcName,
                })
            end
        end
        if #items > 0 then
            extraGroups = {{
                title = "数据线输入",
                color = Color(100, 200, 255),
                items = items,
            }}
        end
    end
    -- 右操作数按左类型过滤（同类型比较）；左操作数未选择时 dataType 为空串，
    -- 必须转 nil——空串为 truthy，会导致收集循环 `vt.id == ""` 全 false，浮层空白
    local rFilter = isLeft and nil or (cond.left.dataType or "")
    if rFilter == "" then rFilter = nil end
    VarOp.OpenGlobalVarSelector(editor, node,
        x, y, w, scale, "eval", idx, side,
        rFilter, extraGroups,
        function(varName, dataType, v)
            if isLeft then
                -- 左操作数：数据线输入（v.connId）或全局变量
                if v and v.connId then
                    cond.left = {
                        source = "input",
                        connId = v.connId,
                        varName = v.name,
                        dataType = v.dataType,
                    }
                else
                    cond.left = {
                        source = "global",
                        varName = varName,
                        dataType = dataType,
                        internalName = v and v.internalName or nil,
                    }
                end
                cond.operator = "="
                cond.lastOperator = "="
                cond.right = {
                    mode = EV_RIGHT_MODE[dataType] or "literal",
                    varName = "", dataType = "", literal = "",
                }
                -- 清空运算符下拉框残留状态（选中索引/选项快照/选中快照），
                -- 否则下拉框仍显示上一变量的旧运算符，与重置后的 "=" 不一致（E5/E6/E7）
                local opId = "eval_op_" .. idx
                if node.data.dropdowns then node.data.dropdowns[opId] = nil end
                if node.data._evalOpOpts then node.data._evalOpOpts[idx] = nil end
                if node.data._evalOpSel then node.data._evalOpSel[idx] = nil end
            else
                -- 右操作数：写入同类型变量
                cond.right.varName = varName
                cond.right.dataType = dataType
            end
            RecalcEvaluateHeight(node, scale)
        end,
        function()
            RecalcEvaluateHeight(node, scale)
        end)
end

-- 辅助："判断变量关系"右操作数字面量数字槽（数字比较 / 数组"项目数*"比较共用）
-- 值写入 cond.right.literal（数字或 "var:<名>" 变量引用，[lib] 单选模式）；
-- 清理本行残留的 ev_right 输入框激活状态；RegisterIR 注册交互防止误判"点击节点体"。
local function DrawEvalNumRight(node, cond, idx, x, y, w, h, scale, font)
    local editor = node and node.editor
    RegisterIR(editor, node, "ev_rnum_" .. idx, x, y, w, h)
    -- 本行从文本输入切换为数字槽时，清理残留的 ev_right 输入框激活状态
    if VarOp.InputState.active and VarOp.InputState.condIdx == idx
       and VarOp.InputState.field == "ev_right" then
        VarOp.InputState.active = false
    end
    local numId = "ev_num_" .. idx
    local numData = node.data.numbers and node.data.numbers[numId]
    -- [lib] 数字槽：options = 可选的数字全局变量（单选模式，templates.md L907-912）
    local opts = GetNumericVarOptions(editor)
    local lit = cond.right.literal or ""
    local isVarRef = lit:sub(1, 4) == "var:"
    if numData then
        -- NumericVarPopup 选中本槽变量后的窗口期：popup 只更新 numData（selectedOptionIndex 等），
        -- 变量引用（var:<名>）要下一帧 DrawNumberBox 回写后才写入 literal；此窗口期 literal 仍为旧值/空，
        -- 若照常执行数据驱动同步/复位会覆盖 popup 的选择（E2：单选数字槽始终回退到第一项）
        local popupPending = numData._popupSelected
        if isVarRef then
            if not popupPending then
                -- 变量引用：数据驱动强制 select 模式，按显示名定位选项索引
                numData.mode = "select"
                local found = nil
                for oi, o in ipairs(opts) do
                    if o == lit:sub(5) then found = oi break end
                end
                numData.selectedOptionIndex = found or 1
                numData.value = 0
            end
        elseif lit == "" then
            if not popupPending then
                -- 字面量被外部重置（运算符/左类型切换清空数据）：复位槽为 slot 模式并清除残留选中
                numData.mode = "slot"
                numData.selectedOptionIndex = nil
                numData.value = 0
            end
        end
    end
    local numSize = math.min(h, w)
    local newVal = Canvas.DrawNumberBox(x, y, numSize,
        isVarRef and 0 or (tonumber(lit) or 0), node, numId, opts, font)
    -- 槽 → 数据：select 模式保存变量引用（var:<名>），slot 模式保存数字
    if numData then
        if numData.mode == "select" and numData.selectedOptionIndex then
            cond.right.literal = "var:" .. (opts[numData.selectedOptionIndex] or "")
        elseif numData.mode == "slot" and newVal ~= nil then
            cond.right.literal = tostring(newVal)
        end
        -- 消费 popup 选中窗口期标记（literal 已回写，恢复数据驱动同步）
        numData._popupSelected = nil
    end
end

function VarOp.DrawEvaluateRelationship(node, cx, cy, cw, ch, scale)
    local mX, mY = gui.MouseX(), gui.MouseY()
    local click = INE._frameMouseJustPressed or false
    local editor = node and node.editor
    local compFont = GetScaledFont(scale, 14)
    local smallFont = GetScaledFont(scale, 12)
    local charW = GetTW("字", compFont)

    local rowH = math.max(16, math.floor(22 * scale))
    local btnH = math.max(20, math.floor(24 * scale))
    local spacing = math.max(2, math.floor(3 * scale))

    node.data = node.data or {}
    node.data._conditions = node.data._conditions or {}
    node.data._connectors = node.data._connectors or {}
    node.data._condSelector = node.data._condSelector or nil

    -- 旧数据迁移：left/right 为字符串（旧纯文本行）时重置为新结构，不崩溃
    for _, cond in ipairs(node.data._conditions) do
        if type(cond.left) ~= "table" then
            cond.left = { varName = "", dataType = "" }
        end
        -- 左操作数来源：global=全局变量（默认）/ input=数据线输入（引用具体数据连接 connId）
        cond.left.source = cond.left.source or "global"
        if type(cond.right) ~= "table" then
            cond.right = { mode = "literal", varName = "", dataType = "", literal = "" }
        end
        cond.operator = cond.operator or "="
        cond.right.mode = cond.right.mode or "literal"
        cond.right.literal = cond.right.literal or ""
        cond.right.varName = cond.right.varName or ""
        cond.right.dataType = cond.right.dataType or ""
    end

    -- 展开的选择器对应的条件行被删除时清除
    local sel = node.data._condSelector
    if sel and not node.data._conditions[sel.condIdx] then
        node.data._condSelector = nil
        sel = nil
    end

    local yOff = cy
    -- 高度每帧按当前画布缩放重算（世界单位 = 内容像素 / scale，含标题栏偏移 40）：
    -- 画布缩放变化时节点高度立即贴合内容（R2），不依赖操作时触发的 RecalcEvaluateHeight
    local needPx = #node.data._conditions * (rowH + spacing) + (2 + btnH) + 10
    node.height = math.max(120, math.floor(40 + needPx / scale))

    -- 输出端口自愈：确保"结果"输出端口存在（RegisterAll 定义 outputTypes = {结果}，E16）
    -- 新建节点时 selectedOutputTypes 为空端口不显示；若由"+"添加按钮补入的是原始类型引用，
    -- 悬停提示将显示类型名"布尔值"而非端口名"结果"——此处统一重建为携带名称的端口表
    local resRef = VarOp.TypeRefs.p or VarOp.TypeRefs.b
    local curOut = node.selectedOutputTypes or {}
    if #curOut ~= 1 or not PortDataEqual(curOut[1], BuildPortData(resRef, "结果")) then
        node.selectedOutputTypes = { BuildPortData(resRef, "结果") }
        if editor then
            INE:UpdateDataPortPositions(editor, node, "output")
        end
    end
    -- 行内固定列宽（所有条件行对齐，templates.md L1238 [连接符][操作数A][运算符][操作数B]）：
    -- [连接符区（非首行显示）] [条件N:序号区] [左操作数槽] [运算符] [右操作数]
    local connW = GetTW("和", smallFont) + 10
    local condLblW = GetTW("条件9:", smallFont) + 6
    local lSlotX = cx + 4 + connW + condLblW
    local lSlotW = math.max(charW * 2, math.floor((cw - connW - condLblW - 16) * 0.38))
    local opDDW = math.min(charW * 4, cw - connW - condLblW - lSlotW - 16)
    local opX = lSlotX + lSlotW + 6
    local rX = opX + opDDW + 6
    local rW = cx + cw - 4 - rX

    for idx, cond in ipairs(node.data._conditions) do
        -- 数据线引用失效检测：左操作数引用的数据连接被断开时重置为未选择
        if cond.left.source == "input" and cond.left.connId
        and editor and editor.dataConnections then
            local stillValid = false
            for _, conn in ipairs(editor.dataConnections) do
                if conn.id == cond.left.connId then stillValid = true break end
            end
            if not stillValid then
                cond.left = { source = "global", varName = "", dataType = "" }
            end
        end
        -- 左操作数类型：全局变量或数据线输入的数据类型
        local lType = cond.left.dataType or ""

        -- 旧存档迁移：旧版 _condSelector（内嵌选择器展开）→ 一次性转换为打开浮层
        -- 浮层已打开（同节点）时不重复打开
        if node.data._condSelector and node.data._condSelector.condIdx == idx
           and (not Canvas.GlobalVarSelector or Canvas.GlobalVarSelector.node ~= node) then
            local mSide = node.data._condSelector.side or "left"
            node.data._condSelector = nil
            OpenEvalSelector(editor, node, cond, idx, mSide,
                cx, yOff + rowH + spacing, cw, scale)
        end

        -- 右值模式：由左类型+运算符强制推导（templates.md L1259-1260）：
        --   n     → literal 字面量输入（数字[lib]槽）
        --   e     → "是空/非空" 无右值（none）；=、≠ 同类型变量槽（var）
        -- 正式版内容：布尔/文本/数组右值模式（literal/var）已砍掉；
        --   左操作数为不支持类型（b/t/g）或未选择时 expectMode 为 nil——运算符与右值均不绘制
        local expectMode = EvalExpectMode(lType, cond.operator)
        -- 模式变化（由运算符切换触发）：同步模式并清空右值数据，防旧模式数据残留
        if cond.right.mode ~= expectMode then
            if expectMode then
                cond.right.mode = expectMode
                cond.right.varName = ""
                cond.right.dataType = ""
                cond.right.literal = ""
                -- 模式切换关闭本行可能打开的右操作数浮层（旧存档 _condSelector 标记一并清除）
                if Canvas.GlobalVarSelector and Canvas.GlobalVarSelector.node == node
                   and Canvas.GlobalVarSelector.condIdx == idx then
                    local gvsE = Canvas._gvsSearchEntry
                    if gvsE and IsValid(gvsE) then gvsE:Remove() end
                    Canvas._gvsSearchEntry = nil
                    Canvas.GlobalVarSelector = nil
                end
                node.data._condSelector = nil
            end
        end
        local rightMode = cond.right.mode

        -- 条件行背景
        draw.RoundedBox(3, cx, yOff, cw, rowH, Color(45, 50, 55))

        -- === 连接符（非首行条件前方、行首；最后一行不显示，templates.md L1262-1267） ===
        if idx > 1 then
            local cn = node.data._connectors[idx - 1] or "AND"
            local cnText = (cn == "OR") and "或" or "和"
            local cnX = cx + 4
            local cnHov = mX >= cnX and mX <= cnX + connW and mY >= yOff and mY <= yOff + rowH
            if cnHov then
                draw.RoundedBox(3, cnX, yOff + (rowH - 18) / 2, connW, 18, Color(255, 255, 255, 30))
            end
            draw.SimpleText(cnText, smallFont, cnX + connW / 2, yOff + rowH/2,
                cnHov and Color(180, 220, 255) or COL_LINK,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            RegisterIR(editor, node, "ev_conn_" .. (idx - 1), cnX, yOff, connW, rowH)
            if click and cnHov and not Canvas.DraggingNode and not Canvas.GlobalVarSelector then
                node.data._connectors[idx - 1] = (cn == "AND") and "OR" or "AND"
            end
        end
        -- === 条件序号标签（条件N:） ===
        draw.SimpleText("条件" .. idx .. ":", smallFont, cx + 4 + connW + condLblW / 2, yOff + rowH/2,
            COL_LABEL, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        -- === 左操作数槽（全局变量 / 数据线输入） ===
        local lSlotHov = mX >= lSlotX and mX <= lSlotX + lSlotW and mY >= yOff and mY <= yOff + rowH
        RegisterIR(editor, node, "ev_left_" .. idx, lSlotX, yOff, lSlotW, rowH)
        if lType ~= "" and cond.left.varName ~= "" then
            -- 外貌同设置变量目标行：左侧类型色矩形 + 同色变量名（templates.md L1243）
            local lTypeCol = GetDataTypeColor(lType)
            local barW = math.max(3, math.floor(4 * scale))
            local barX = lSlotX + 4
            local barY = yOff + 2
            local barH = rowH - 4
            surface.SetDrawColor(lTypeCol)
            surface.DrawRect(barX, barY, barW, barH)
            local isGlobal = (cond.left.source ~= "input")
            local textX = barX + barW + 4
            if isGlobal then
                -- 全局变量：类型色矩形上叠加半透明黑色三角形（顶点在矩形左上/右上/左下），
                -- 三角形向右扩展到可见宽度 triW（矩形本身仅 4px 宽，直接画三个角几乎不可见），
                -- 作为全局变量标记，明显区别于接入变量（无三角）
                local triW = math.max(barW, math.floor(8 * scale))
                surface.SetDrawColor(Color(0, 0, 0, 170))
                -- 必须先 draw.NoTexture() 绑定白色纹理，否则 surface.DrawPoly 沿用当前
                -- 纹理（字体/按钮贴图）导致多边形绘制失败、完全不可见
                draw.NoTexture()
                surface.DrawPoly({
                    { x = barX, y = barY },
                    { x = barX + triW, y = barY },
                    { x = barX, y = barY + barH },
                })
                textX = barX + triW + 4
                -- 变量名加纯黑阴影（主文字右下偏移 2px，增强可见度）
                local sh = math.max(2, math.floor(2 * scale))
                draw.SimpleText(cond.left.varName, smallFont,
                    textX + sh, yOff + rowH / 2 + sh,
                    Color(0, 0, 0), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
            draw.SimpleText(cond.left.varName, smallFont, textX, yOff + rowH/2,
                lTypeCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        else
            draw.SimpleText("选择变量", smallFont, lSlotX + 4, yOff + rowH/2,
                Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        -- 点击打开变量选择器浮层（全局变量 + 数据线输入分组，不触发节点宽高重算）
        -- 浮层覆盖节点区域：旧浮层开着时点击本槽会落入浮层内部（只失活搜索框不关闭），
        -- 若直接放弃打开会被旧浮层过滤状态"锁死"（如右侧布尔过滤浮层覆盖本槽），
        -- 故点击时强制关闭旧浮层再打开全类型浮层（类型锁定修复）
        if click and lSlotHov and not Canvas.DraggingNode and not Canvas.ExpandedDropdown then
            if Canvas.GlobalVarSelector then
                local gvsE = Canvas._gvsSearchEntry
                if gvsE and IsValid(gvsE) then gvsE:Remove() end
                Canvas._gvsSearchEntry = nil
                Canvas.GlobalVarSelector = nil
            end
            if VarOp.InputState.active then VarOp.InputState.active = false end
            OpenEvalSelector(editor, node, cond, idx, "left",
                cx, yOff + rowH + spacing, cw, scale)
        end

        -- === 运算符下拉框（类型自适应；测试版支持数字 + 对象——左操作数为 n/e 才绘制运算符） ===
        -- 正式版内容：布尔/文本/数组类型（b/t/g）运算符已砍掉，见 templates.md"正式版再做"
        local opId = "eval_op_" .. idx
        if EV_OPERATORS[lType] then
            local opOpts = EV_OPERATORS[lType] or {"="}
            local curOpIdx = 1
            local opFound = false
            for oi, o in ipairs(opOpts) do
                if o == cond.operator then curOpIdx = oi; opFound = true; break end
            end
            if not opFound then cond.operator = "=" end
            RegisterIR(editor, node, "ev_dd_" .. idx, opX, yOff, opDDW, rowH)
            local oldOpDD = node.data.dropdowns and node.data.dropdowns[opId]
            -- 选项列表随左类型变化：用选项快照比较检测列表变化（而非比较选中项与运算符）。
            -- 点击选项后选中索引由 Think 先行更新，若按"选中项 ~= 运算符"复位，
            -- 会把用户刚选中的选项打回第一项，导致运算符永远无法切换（E5/E6/E7）
            node.data._evalOpOpts = node.data._evalOpOpts or {}
            local lastOpts = node.data._evalOpOpts[idx]
            local optsChanged = not lastOpts
            if not optsChanged and #lastOpts == #opOpts then
                for oi2, o2 in ipairs(opOpts) do
                    if lastOpts[oi2] ~= o2 then optsChanged = true break end
                end
            end
            if oldOpDD and (oldOpDD.selectedIndex < 1 or oldOpDD.selectedIndex > #opOpts
               or optsChanged) then
                oldOpDD.selectedIndex = curOpIdx
            end
            node.data._evalOpOpts[idx] = opOpts
            local oldOpIdx = oldOpDD and oldOpDD.selectedIndex or curOpIdx
            Canvas.DrawDropdown(opX, yOff, opDDW, rowH, opOpts, curOpIdx, node,
                opId, nil, nil, smallFont, scale)
            local curOpDD = node.data.dropdowns and node.data.dropdowns[opId]
            local curSel = curOpDD and curOpDD.selectedIndex or curOpIdx
            -- 同步：与持久化的上一帧选中索引比较（同帧读取的 selectedIndex 已被
            -- Think 更新为新值，oldOpIdx delta 比较必然失效），变化即回写运算符
            node.data._evalOpSel = node.data._evalOpSel or {}
            local lastSel = node.data._evalOpSel[idx]
            if lastSel ~= nil and curSel ~= lastSel then
                cond.operator = opOpts[curSel] or cond.operator
            end
            node.data._evalOpSel[idx] = curSel
        else
            -- 左操作数为不支持类型（b/t/g）或未选择：不绘制运算符，清理残留下拉状态防复用错位
            -- 正式版内容：非数值非对象类型运算符留待正式版（templates.md 标注"正式版再做"）
            if node.data.dropdowns then node.data.dropdowns[opId] = nil end
            if node.data._evalOpOpts then node.data._evalOpOpts[idx] = nil end
            if node.data._evalOpSel then node.data._evalOpSel[idx] = nil end
        end

        -- === 右操作数 ===
        if lType == "" then
            -- 左操作数未选择：右侧无内容（右值形式由左类型决定，templates.md L1259；E9）
        elseif not EV_OPERATORS[lType] then
            -- 正式版内容：布尔/文本/数组类型比较（b/t/g）测试版砍掉，留待正式版（templates.md 标注"正式版再做"）
            draw.SimpleText("正式版支持", smallFont, rX, yOff + rowH/2,
                Color(90, 90, 90), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        elseif rightMode == "none" then
            -- 无右值（对象"是空/非空"）：右侧完全不绘制（E5/E7）
        elseif rightMode == "var" then
            -- 同类型全局变量槽（对象 =、≠ 比较；n 恒为 literal 不可达）
            local rSlotHov = mX >= rX and mX <= rX + rW and mY >= yOff and mY <= yOff + rowH
            RegisterIR(editor, node, "ev_right_" .. idx, rX, yOff, rW, rowH)
            if cond.right.dataType ~= "" and cond.right.varName ~= "" then
                -- 外貌同设置变量目标行：左侧类型色矩形 + 同色变量名（templates.md L1243）
                local rTypeCol = GetDataTypeColor(cond.right.dataType)
                local barW = math.max(3, math.floor(4 * scale))
                surface.SetDrawColor(rTypeCol)
                surface.DrawRect(rX + 4, yOff + 2, barW, rowH - 4)
                draw.SimpleText(cond.right.varName, smallFont, rX + 4 + barW + 4, yOff + rowH/2,
                    rTypeCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            else
                draw.SimpleText("选择变量", smallFont, rX + 4, yOff + rowH/2,
                    Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
            if click and rSlotHov and not Canvas.DraggingNode and not Canvas.ExpandedDropdown then
                -- 同左操作数：强制关闭旧浮层再打开同类型过滤浮层（浮层覆盖节点区域，防被旧浮层锁死）
                if Canvas.GlobalVarSelector then
                    local gvsE = Canvas._gvsSearchEntry
                    if gvsE and IsValid(gvsE) then gvsE:Remove() end
                    Canvas._gvsSearchEntry = nil
                    Canvas.GlobalVarSelector = nil
                end
                if VarOp.InputState.active then VarOp.InputState.active = false end
                -- 右操作数：同类型变量过滤（filterType = 左类型）
                OpenEvalSelector(editor, node, cond, idx, "right",
                    cx, yOff + rowH + spacing, cw, scale)
            end
        else
            -- literal：数字[lib]槽（测试版仅数值比较；布尔/文本 literal 为正式版内容）
            if lType == "b" then
                local btnW = math.max(28, math.floor(rW * 0.42))
                local bTrueX = rX
                local bFalseX = rX + btnW + 4
                local curLit = cond.right.literal
                local tHov = mX >= bTrueX and mX <= bTrueX + btnW and mY >= yOff and mY <= yOff + rowH
                local fHov = mX >= bFalseX and mX <= bFalseX + btnW and mY >= yOff and mY <= yOff + rowH
                local tActive = (curLit == "true")
                local fActive = (curLit == "false")
                draw.RoundedBox(3, bTrueX, yOff, btnW, rowH,
                    tActive and Color(90, 140, 90) or (tHov and Color(60, 90, 60) or Color(45, 50, 55)))
                draw.SimpleText("真", smallFont, bTrueX + btnW/2, yOff + rowH/2,
                    tActive and Color(255, 255, 255) or COL_TEXT,
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                RegisterIR(editor, node, "ev_btrue_" .. idx, bTrueX, yOff, btnW, rowH)
                draw.RoundedBox(3, bFalseX, yOff, btnW, rowH,
                    fActive and Color(140, 90, 90) or (fHov and Color(90, 60, 60) or Color(45, 50, 55)))
                draw.SimpleText("假", smallFont, bFalseX + btnW/2, yOff + rowH/2,
                    fActive and Color(255, 255, 255) or COL_TEXT,
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                RegisterIR(editor, node, "ev_bfalse_" .. idx, bFalseX, yOff, btnW, rowH)
                if click and not Canvas.DraggingNode and not Canvas.ExpandedDropdown then
                    if tHov then cond.right.literal = "true"
                    elseif fHov then cond.right.literal = "false" end
                end
            elseif lType == "n" then
                -- 数字：INE 数字槽（kards 数字范围 0~99，左键 ±1、右键 ±5；t4 升级 [lib] 单选）
                DrawEvalNumRight(node, cond, idx, rX, yOff, rW, rowH, scale, smallFont)
            elseif lType == "g" then
                -- 数组"项目数=/>/<"：数字字面量比较（templates.md L1257；E6）
                DrawEvalNumRight(node, cond, idx, rX, yOff, rW, rowH, scale, smallFont)
            else
                -- 文本：内联输入框（glua-input-field 模式）
                DrawInputField(node, mX, mY, click, "ev_right",
                    rX, yOff, rW, rowH, smallFont,
                    cond.right.literal or "", "文本", nil, idx)
            end
        end

        yOff = yOff + rowH + spacing
    end

    -- "+ 增加全局变量条件" 按钮
    local btnY = yOff + 2
    local bH = btnH
    local bHov = mX >= cx+2 and mX <= cx+2+cw-4 and mY >= btnY and mY <= btnY+bH
    draw.RoundedBox(4, cx+2, btnY, cw-4, bH, bHov and COL_BTN_HOVER or COL_BTN)
    RegisterIR(editor, node, "ev_add_btn", cx+2, btnY, cw-4, bH)
    draw.SimpleText("+ 增加全局变量条件", compFont, cx + cw/2, btnY + bH/2,
        Color(200, 220, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    if click and bHov and not Canvas.DraggingNode and not Canvas.GlobalVarSelector then
        table.insert(node.data._conditions, {
            left = { varName = "", dataType = "" },
            operator = "=",
            lastOperator = "=",
            right = { mode = "literal", varName = "", dataType = "", literal = "" },
        })
        table.insert(node.data._connectors, "AND")
        RecalcEvaluateHeight(node, scale)
    end
end

-- ====================================================================================
-- 内联输入框 DTextEntry 生命周期管理（Think 钩子）
-- 激活时创建/保持透明 DTextEntry 捕获 IME/键盘输入；失活、点击外部或节点被删除时销毁。
-- 多字段复用同一 DTextEntry 时同步文本，防止旧字段文本残留拼接（多输入框文本污染）。
-- ====================================================================================
local function ManageVarOpInputEntry()
    local st = VarOp.InputState
    local entry = VarOp.InputEntry

    -- 校验激活节点与目标仍有效（节点可能被删除/数据被重置）
    -- ev_right 绑定条件行（无 _varEntries 条目），其余字段绑定 _varEntries 条目
    if st.active and st.node then
        local ed = st.node.editor
        local nodeExists = false
        if ed and ed.nodes then
            for _, n in ipairs(ed.nodes) do
                if n == st.node then nodeExists = true break end
            end
        end
        local targetValid = false
        if st.field == "ev_right" then
            local cond = st.node.data and st.node.data._conditions
                     and st.node.data._conditions[st.condIdx]
            targetValid = nodeExists and cond ~= nil and cond.right ~= nil
        elseif st.field == "sv_value" or st.field == "sv_itemName" then
            -- "设置变量"节点值输入框 / 数组"第"项名称输入：均绑定 _setEntries 条目（多设置行各自校验）
            local entryExists = false
            if nodeExists and st.entry and st.node.data and st.node.data._setEntries then
                for _, e in ipairs(st.node.data._setEntries) do
                    if e == st.entry then entryExists = true break end
                end
            end
            targetValid = nodeExists and entryExists
        else
            local entryExists = false
            if nodeExists and st.entry and st.node.data and st.node.data._varEntries then
                for _, e in ipairs(st.node.data._varEntries) do
                    if e == st.entry then entryExists = true break end
                end
            end
            targetValid = nodeExists and entryExists
        end
        if not targetValid then
            st.active = false
        end
    end

    if st.active and (st.entry or st.field == "ev_right") then
        -- 创建 DTextEntry（如果不存在或已失效）
        if not entry or not IsValid(entry) then
            entry = vgui.Create("DTextEntry")
            entry:SetPos(st.x, st.y)
            entry:SetSize(st.w, st.h)
            entry:SetText(st.text or "")
            entry:SetCaretPos(#(st.text or ""))
            entry:SetDrawBackground(false)
            entry:SetDrawBorder(false)
            entry:SetTextColor(Color(255, 255, 255, 0))
            entry:SetCursorColor(Color(255, 255, 255, 0))
            entry.Paint = nil
            entry:MakePopup()

            entry.OnTextChanged = function(self)
                local txt = self:GetText()
                local st2 = VarOp.InputState
                -- ev_right 字段无 _varEntries 条目（st2.entry 为 nil），需单独放行
                if not (st2 and st2.active and (st2.entry or st2.field == "ev_right")) then return end
                st2.text = txt
                local e = st2.entry
                if st2.field == "name" then e.name = txt
                elseif st2.field == "internalName" then e.internalName = txt
                elseif st2.field == "initValue" then e.initValue = txt
                elseif st2.field == "ev_right" then
                    -- "判断变量关系"条件行右操作数字面量
                    local cond = st2.node and st2.node.data and st2.node.data._conditions
                             and st2.node.data._conditions[st2.condIdx]
                    if cond and cond.right then cond.right.literal = txt end
                elseif st2.field == "sv_value" then
                    -- "设置变量"节点值输入区：写回条目 value
                    if e then e.value = txt end
                elseif st2.field == "sv_itemName" then
                    -- "设置变量"数组"第"子操作"类型→创建变量组件"的名称输入：写回条目 itemName
                    if e then e.itemName = txt end
                elseif st2.field == "arrItemName" then
                    -- "新建变量"数组"+"子操作"独立变量创建 UI 的项名输入：写回条目 arrayItemName
                    if e then e.arrayItemName = txt end
                end
            end

            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    VarOp.InputState.active = false
                end
            end

            VarOp.InputEntry = entry
        else
            -- 已存在：同步位置/尺寸/文本（防止多输入框复用污染），并保持焦点
            entry:SetPos(st.x, st.y)
            entry:SetSize(st.w, st.h)

            local expected = VarOp.GetInputFieldText()
            if entry:GetText() ~= expected then
                entry:SetText(expected)
                entry:SetCaretPos(#expected)
            end

            if not entry:HasFocus() then
                local mx, my = gui.MousePos()
                local inRect = mx >= st.x and mx <= st.x + st.w
                           and my >= st.y and my <= st.y + st.h
                if inRect then
                    entry:MakePopup()
                else
                    -- 鼠标点击了输入框外部（popup 已失去焦点）→ 失活
                    st.active = false
                end
            end
        end
    else
        if entry and IsValid(entry) then
            entry:Remove()
        end
        VarOp.InputEntry = nil
    end
end
hook.Add("Think", "VarOpManageInputEntry", ManageVarOpInputEntry)

-- ====================================================================================
-- 自动注册
-- ====================================================================================
VarOp.RegisterAll()
print("[CardEditor] cl_ine_var_op_nodes.lua loaded (create_variable, set_variable, convert_extract_variable, evaluate_variable)")
