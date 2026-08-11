--[[
=======================================================================================
统一槽系统 - 数据定义 (Unified Slot System - Data Definitions)
=======================================================================================
本文件仅保留统一槽系统的数据模型定义，不包含任何绘制或交互逻辑。
各槽类型的绘制和交互已内联到 cl_ine_node_editor.lua 的 DrawComponents 中。

定义内容：
  1. INE.SlotTypes - 槽类型定义表（字符、颜色、支持模式）
  2. INE.CreateSlotData - 创建默认槽数据结构
  3. INE.GetOrCreateSlotData - 获取或创建槽数据
  4. INE.SyncNumberSlotToSlotData - 数字槽到统一槽数据的同步
  5. INE._CollectLibVarsByType - 按类型收集 VarLib 变量

依赖：cl_ine_node_editor.lua（INE 命名空间在加载时必须已存在）
=======================================================================================
]]

local INE = KARDS.CardEditor.IndependentNodeEditor

-- ====================================================================================
-- 槽类型定义
-- ====================================================================================
INE.SlotTypes = INE.SlotTypes or {
    number = {
        id = "number",
        char = "n",
        color = Color(230, 200, 30),
        colorHex = "#E6C81E",
        supportsLiteral = true,   -- 字面量模式：输入数值
        supportsVariable = true,  -- 变量模式：选择 Varlib 数字变量
        hasSeparator = true,      -- 类型标识与值区域之间显示分隔符
    },
    ["function"] = {
        id = "function",
        char = "f",
        color = Color(180, 70, 200),
        colorHex = "#B446C8",
        supportsLiteral = false,
        supportsVariable = true,
        hasSeparator = true,
    },
    object = {
        id = "object",
        char = "o",
        color = Color(200, 60, 60),
        colorHex = "#C83C3C",
        supportsLiteral = false,
        supportsVariable = true,
        hasSeparator = true,
    },
    text = {
        id = "text",
        char = "t",
        color = Color(76, 175, 80),
        colorHex = "#4CAF50",
        supportsLiteral = true,
        supportsVariable = true,
        hasSeparator = true,
    },
    boolean = {
        id = "boolean",
        char = "b",
        color = Color(158, 158, 158),
        colorHex = "#9E9E9E",
        supportsLiteral = true,   -- true/false 单选
        supportsVariable = true,
        hasSeparator = true,
    },
    array = {
        id = "array",
        char = "[]",
        color = Color(255, 152, 0),
        colorHex = "#FF9800",
        supportsLiteral = false,
        supportsVariable = true,
        hasSeparator = true,
    },
    image = {
        id = "image",
        char = "p",
        color = Color(233, 30, 99),
        colorHex = "#E91E63",
        supportsLiteral = false,
        supportsVariable = true,
        hasSeparator = true,
    },
}

-- ====================================================================================
-- 创建默认槽数据
-- ====================================================================================
--- 创建默认的槽数据结构
--- @param slotType string 槽类型 ("number"|"function"|"object"|"text"|"boolean"|"array"|"image")
--- @param extraOptions table|nil 附加选项（仅数字槽有，JSON 模板中的预设选项）
--- @param useLib boolean|nil 是否使用 VarLib（仅数字槽有）
--- @param defaultLiteral any|nil 字面量默认值
--- @return table SlotData
function INE.CreateSlotData(slotType, extraOptions, useLib, defaultLiteral)
    local slotTypeDef = INE.SlotTypes[slotType]
    if not slotTypeDef then
        error("INE.CreateSlotData: 未知的槽类型 '" .. tostring(slotType) .. "'")
    end

    local slotData = {
        type = slotType,
        -- 模式：仅支持字面量时默认 literal，仅支持变量时默认 variable，两者都支持时默认 literal
        mode = (slotTypeDef.supportsLiteral and not slotTypeDef.supportsVariable) and "literal"
               or (not slotTypeDef.supportsLiteral and slotTypeDef.supportsVariable) and "variable"
               or "literal",
        literalValue = defaultLiteral,
        variableRef = nil,
        extraOptions = extraOptions,  -- {table} 附加预设选项（如数字槽的预设选项列表）
        useLib = useLib,              -- {boolean} 数字槽是否接入 VarLib
    }

    -- 类型特定默认值
    if slotType == "number" then
        slotData.literalValue = slotData.literalValue or 0
    elseif slotType == "boolean" then
        slotData.literalValue = slotData.literalValue or false
    elseif slotType == "text" then
        slotData.literalValue = slotData.literalValue or ""
    end

    return slotData
end

-- ====================================================================================
-- 从组件数据创建或获取 SlotData
-- ====================================================================================
--- 从节点数据中获取或创建统一的 SlotData
--- 如果 node.data.slots[compId] 已存在则直接返回，否则根据组件类型创建新数据
--- @param slotType string 槽类型
--- @param node table 节点实例
--- @param compId string 组件 ID
--- @param initialValue any|nil 初始值
--- @param extraOptions table|nil 附加选项
--- @param useLib boolean|nil 是否使用 VarLib
--- @return table SlotData
function INE.GetOrCreateSlotData(slotType, node, compId, initialValue, extraOptions, useLib)
    node.data = node.data or {}
    node.data.slots = node.data.slots or {}

    if node.data.slots[compId] then
        return node.data.slots[compId]
    end

    local slotData = INE.CreateSlotData(slotType, extraOptions, useLib)
    
    -- 如果提供了初始值，设置到 slotData
    if initialValue ~= nil then
        if slotData.mode == "literal" then
            slotData.literalValue = initialValue
        else
            slotData.variableRef = initialValue
        end
    elseif slotData.mode == "variable" and slotType == "function" then
        -- 函数槽没有字面量模式，默认显示 "选择函数" 
        slotData.variableRef = nil
    end

    node.data.slots[compId] = slotData
    return slotData
end

-- ====================================================================================
-- 数字槽过渡辅助
-- ====================================================================================
--- 从现有的数字槽数据创建/同步统一槽 SlotData
--- 用于过渡期：当 DrawNumberBox 渲染后，同步其 mode/value 到统一槽数据
--- @param node table 节点实例
--- @param numberId string 数字组件 ID
--- @return table|nil SlotData（如果已存在则返回已有的）
function INE.SyncNumberSlotToSlotData(node, numberId)
    if not node or not node.data then return nil end
    if not node.data.numbers or not node.data.numbers[numberId] then return nil end
    
    node.data.slots = node.data.slots or {}
    if node.data.slots[numberId] then
        -- 已存在统一槽数据，同步 mode
        local numData = node.data.numbers[numberId]
        if numData.mode == "slot" then
            node.data.slots[numberId].mode = "literal"
        elseif numData.mode == "select" then
            node.data.slots[numberId].mode = "variable"
        end
        return node.data.slots[numberId]
    end
    
    -- 创建统一槽数据
    local numData = node.data.numbers[numberId]
    local slotData = INE.CreateSlotData("number", numData.slotOptions, false, numData.value)
    slotData.mode = (numData.mode == "select") and "variable" or "literal"
    node.data.slots[numberId] = slotData
    return slotData
end

-- ====================================================================================
-- 辅助函数：按数据类型收集 VarLib 变量（从原 cl_ine_node_editor.lua 移植）
-- ====================================================================================
function INE._CollectLibVarsByType(editor)
    if not editor then return {} end
    if not KARDS.VarLib then return {} end

    local result = {}
    -- 收集对象组变量（eg 类型）
    local egVars = KARDS.VarLib.GetVarsByType and KARDS.VarLib.GetVarsByType("eg")
    if egVars then
        result["eg"] = egVars
    end

    -- 可扩展其他 VarLib 变量类型
    return result
end

-- ====================================================================================
-- 调试/日志
-- ====================================================================================
print("[CardEditor] cl_ine_unified_slot.lua loaded")
