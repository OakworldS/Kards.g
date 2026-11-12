--[[
=======================================================================================
编辑器子系统：cl_ine_config_parser.lua
=======================================================================================
从 cl_ine_node_editor.lua 拆分出的子系统：配置 DSL 解析（Parse* 系列、条件分支匹配、ParseConfig 与 ConfigCache）。
源行范围：cl_ine_node_editor.lua 第 1106 至 1672 行（2026-10-18 拆分时点）。
=======================================================================================
]]

local INE = KARDS.CardEditor.IndependentNodeEditor
local T = KARDS.Lang.T

-- 配置缓存（用于 ParseConfig 结果缓存）
INE.ConfigCache = INE.ConfigCache or {}

--[[
特殊文本格式语法说明:
1. 输入数据类型定义（可选，放在开头）:
   - n: 数字
   - p: 布尔值
   - t: 字符串
   - g: 数组
   - e: 卡牌对象
   - f: 节点函数
   - 示例: nptg{...} 表示支持数字、布尔值、字符串、数组输入
   
2. 组件定义:
   - '文本': 固定文本组件
   - {选项1、选项2、选项3}: 单选组件
   - []: 数字输入组件
   
3. 条件分支:
   - if 条件 then ... elseif 条件 then ... else ... end
   
4. 输出数据类型定义（可选）:
   - (选项1、选项2): 多选数据类型，使用、分隔
   - 每个选项以数据类型标识符开头（n/p/t/g/e/f）
   - 示例: (n数字、p布尔值、t字符串)
]]

-- 解析输入数据类型标识符（开头的 n/p/t/g/e/f 字符）
function INE.ParseInputTypes(str, startPos, len)
    local inputTypes = {}
    local i = startPos
    
    while i <= len do
        local char = str:sub(i, i)
        if char == "n" or char == "p" or char == "t" or char == "g" or char == "e" or char == "f" then
            local dataType = INE.GetDataTypeById(char)
            if dataType then
                table.insert(inputTypes, dataType)
            end
            i = i + 1
        else
            break
        end
    end
    
    return inputTypes, i
end

-- 解析文本组件（单引号包裹）
function INE.ParseTextComponent(str, startPos, len, componentId)
    local j = startPos + 1
    while j <= len and str:sub(j, j) ~= "'" do
        j = j + 1
    end
    local text = str:sub(startPos + 1, j - 1)
    
    if text ~= "" then
        componentId = componentId + 1
        return {
            type = "text",
            id = "text_" .. componentId,
            text = text
        }, j + 1, componentId
    end
    
    return nil, j + 1, componentId
end

-- 解析下拉选项组件（花括号包裹）
function INE.ParseSelectComponent(str, startPos, len, componentId)
    local j = startPos + 1
    while j <= len and str:sub(j, j) ~= "}" do
        j = j + 1
    end
    local optionsStr = str:sub(startPos + 1, j - 1)
    local options = {}
    -- 将 、（UTF-8 三字节分隔符）替换为单字节分隔符后再拆分，
    -- 避免 [^、] 模式逐个排除字节（0xE3/0x80/0x81）时误拆中文UTF-8编码内的0x80/0x81字节。
    local safeStr = optionsStr:gsub("、", "\1")
    for opt in string.gmatch(safeStr, "([^\1]+)") do
        table.insert(options, opt)
    end
    
    if #options > 0 then
        componentId = componentId + 1
        local comp = {
            type = "select",
            id = "select_" .. componentId,
            cardObjectMode = false,
        }
        
        -- 扫描所有选项，检测 @section_id 语法（引用规则词汇表章节）
        -- 支持混用：{主动效果、被动效果、无、@combat_keywords} 会将词汇表选项与原选项合并
        local hasSectionRef = false
        local mergedOptions = {}
        local allSectionOptionIds = {}
        for _, opt in ipairs(options) do
            local trimmed = opt:match("^%s*(.-)%s*$") or ""
            if trimmed:sub(1, 1) == "@" then
                -- 提取 section_id（去掉 @ 和多余空白）
                local sectionId = trimmed:sub(2):match("^%s*(.-)%s*$") or trimmed:sub(2)
                -- 检查是否有 ~ filter 语法（暂不实现，仅保留以备扩展）
                local filterPos = sectionId:find("%s*~%s*")
                if filterPos then
                    sectionId = sectionId:sub(1, filterPos - 1):match("^%s*(.-)%s*$")
                end
                
                -- 从规则词汇表解析选项并合并
                if KARDS and KARDS.RulesVocabulary and KARDS.RulesVocabulary.GetOptions then
                    local lang = GetConVarString("gmod_language") or "zh-CN"
                    local sectionOptions = KARDS.RulesVocabulary.GetOptions(sectionId)
                    for _, sopt in ipairs(sectionOptions) do
                        local label = (sopt.label and sopt.label[lang]) or sopt.id or "?"
                        table.insert(mergedOptions, label)
                        table.insert(allSectionOptionIds, sopt.id)
                    end
                    hasSectionRef = true
                else
                    -- 词汇表不可用：@ 引用将退化为字面选项，打印警告便于定位
                    print(T("editor.nodeeditor.section_expand_failed", sectionId))
                end
            else
                -- 普通选项，直接加入
                table.insert(mergedOptions, trimmed)
            end
        end
        
        if hasSectionRef then
            -- 有词汇表引用：使用合并后的选项列表
            comp.options = mergedOptions
            comp._sectionRef = true
            if #allSectionOptionIds > 0 then
                comp._sectionOptionIds = allSectionOptionIds
            end
        else
            -- 纯普通选项列表
            comp.options = options
            
            -- 检测首选项是否以 $ 开头且结尾，标记为卡牌对象模式
            local firstOpt = options[1]
            if firstOpt and firstOpt:sub(1, 1) == "$" then
                comp.cardObjectMode = true
                if firstOpt == "$" then
                    comp.pureObjectMode = true
                    comp.objectLabel = T("editor.nodeeditor.select_object")
                elseif firstOpt:sub(-1, -1) == "$" then
                    comp.objectLabel = firstOpt:sub(2, -2)
                else
                    comp.objectLabel = firstOpt:sub(2)
                end
            end
        end
        
        return comp, j + 1, componentId
    end
    
    return nil, j + 1, componentId
end

-- 解析数字输入组件（方括号包裹）
-- [] 为基本数字组件，[x、y、z、...] 为带选项的数字槽组件
function INE.ParseNumberComponent(str, startPos, len, componentId)
    local j = startPos + 1
    while j <= len and str:sub(j, j) ~= "]" do
        j = j + 1
    end
    
    -- 没有找到 ] 则不视为数字组件（单独的 [ 被忽略）
    if j > len then
        return nil, j + 1, componentId
    end
    
    local content = str:sub(startPos + 1, j - 1)
    
    componentId = componentId + 1
    local comp = {
        type = "number",
        id = "number_" .. componentId
    }
    
    -- 如果 [] 内有内容，解析为选项列表
    if content and content ~= "" then
        -- 检查是否为 [lib] 或 [lib+额外变量...] 语法
        if content == "lib" then
            -- [lib]：接入 VarLib 所有数字变量
            comp.useLib = true
            comp.extraOptions = nil
        elseif content:sub(1, 4) == "lib+" then
            -- [lib+x、y、z]：VarLib 数字变量 + 额外选项
            comp.useLib = true
            local extraStr = content:sub(5)
            local safeStr = extraStr:gsub("、", "\1")
            local extraOptions = {}
            for opt in string.gmatch(safeStr, "([^\1]+)") do
                table.insert(extraOptions, opt)
            end
            if #extraOptions > 0 then
                comp.extraOptions = extraOptions
            end
        else
            -- 普通选项列表 [x、y、z]
            local safeStr = content:gsub("、", "\1")
            local options = {}
            for opt in string.gmatch(safeStr, "([^\1]+)") do
                table.insert(options, opt)
            end
            if #options > 0 then
                comp.options = options
            end
        end
    end
    
    return comp, j + 1, componentId
end

-- 解析文本槽组件（尖括号 <>，2026-10-04 新增）
-- 与数字槽 [] 对称：每个 <> 为一个可填文本 / 可引用文本变量的槽位。
-- 提示：`<`/`>` 若出现在 `'...'` 文本组件或 `{...}` 下拉选项内，会被
-- ParseTextComponent / ParseSelectComponent 先行消费，不会进入本分支（现有模板
-- condition.json 的下拉 `{=、>、<、>=、<=}` 即属此类，故新增分派是安全的）。
function INE.ParseTextSlotComponent(str, startPos, len, componentId)
    local j = startPos + 1
    while j <= len and str:sub(j, j) ~= ">" do
        j = j + 1
    end

    -- 没有找到 > 则不视为文本槽组件（单独的 < 被忽略）
    if j > len then
        return nil, j + 1, componentId
    end

    componentId = componentId + 1
    return {
        type = "textslot",
        id = "textslot_" .. componentId
    }, j + 1, componentId
end

-- 解析函数槽组件（井号 #）
-- 标记一个函数变量选择位置，用户可从编辑器已定义函数变量中选择
-- 组件本身不包含额外文本，选中后存储函数变量引用
-- @param  componentId {number} 当前组件 ID 计数器
-- @return {table} 函数槽组件对象
function INE.ParseFuncSlot(pos, componentId)
    componentId = componentId + 1
    return {
        type = "funcslot",
        id = "funcslot_" .. componentId
    }, pos, componentId
end

-- 解析输出类型定义（圆括号包裹）
function INE.ParseOutputTypes(str, startPos, len)
    local j = startPos + 1
    while j <= len and str:sub(j, j) ~= ")" do
        j = j + 1
    end
    local optionsStr = str:sub(startPos + 1, j - 1)
    local newOutputTypes = {}
    
    -- 同 ParseSelectComponent，用单字节分隔符避免 [^、] 误拆中文UTF-8编码内的 0x80/0x81 字节
    local safeStr = optionsStr:gsub("、", "\1")
    for opt in string.gmatch(safeStr, "([^\1]+)") do
        local firstChar = opt:sub(1, 1)
        local dataType = INE.GetDataTypeById(firstChar)
        if dataType then
            local displayName = opt:sub(2)
            if displayName == "" then
                displayName = dataType.name
            end
            table.insert(newOutputTypes, {
                id = dataType.id,
                name = displayName,
                color = dataType.color,
                shape = dataType.shape
            })
        end
    end
    
    return newOutputTypes, j + 1
end

-- 解析条件分支组件（if/elseif/else/end）
function INE.ParseConditionalComponent(str, startPos, len, componentId)
    local depth = 1
    local j = startPos + 2
    local branches = {}
    
    -- 解析第一个 if 条件
    local condStart = j
    while j <= len and not (str:sub(j, j + 3) == "then") do
        j = j + 1
    end
    local condition = str:sub(condStart, j - 1)
    condition = condition:gsub("^%s+", ""):gsub("%s+$", "")
    j = j + 4
    
    local currentBranch = {
        condition = condition,
        content = ""
    }
    
    -- 解析所有分支
    while j <= len and depth > 0 do
        local sub6 = str:sub(j, j + 5)
        if sub6 == "elseif" and depth == 1 then
            -- 开始一个新的 elseif 分支（与初始 if 同级，仅在外层深度处理，嵌套 if 内部的 elseif 由递归解析）
            table.insert(branches, currentBranch)
            local eiStart = j + 6
            j = j + 6
            while j <= len and not (str:sub(j, j + 3) == "then") do
                j = j + 1
            end
            condition = str:sub(eiStart, j - 1)
            condition = condition:gsub("^%s+", ""):gsub("%s+$", "")
            currentBranch = {
                condition = condition,
                content = ""
            }
            j = j + 4
        elseif sub6:sub(1, 4) == "else" and depth == 1 then
            -- "else" 分支（但不是 "elseif"，后者已在上面处理；仅在外层深度处理，嵌套 if 内部的 else 由递归解析）
            table.insert(branches, currentBranch)
            currentBranch = {
                condition = "else",
                content = ""
            }
            j = j + 4
        elseif str:sub(j, j + 2) == "if " or str:sub(j, j + 2) == "if\t" then
            -- 嵌套 if 开始，深度 +1，以便内部 end 不会错误结束外层
            depth = depth + 1
            currentBranch.content = currentBranch.content .. "if"
            j = j + 2
        elseif str:sub(j, j + 2) == "end" then
            depth = depth - 1
            if depth == 0 then
                table.insert(branches, currentBranch)
                break
            end
            currentBranch.content = currentBranch.content .. "end"
            j = j + 3
        else
            currentBranch.content = currentBranch.content .. str:sub(j, j)
            j = j + 1
        end
    end
    
    -- 递归解析每个分支的内容
    componentId = componentId + 1
    local ifComp = {
        type = "if",
        id = "if_" .. componentId,
        branches = {}
    }
    
    local outputTypes = {}
    for _, branch in ipairs(branches) do
        -- 传递当前 componentId，确保分支内部组件获得唯一的递增ID
        local branchResult = INE.ParseConfig(branch.content, componentId)
        table.insert(ifComp.branches, {
            condition = branch.condition,
            components = branchResult.components
        })
        if #branchResult.outputTypes > 0 then
            outputTypes = branchResult.outputTypes
        end
    end
    
    return ifComp, j + 1, componentId, outputTypes
end

-- 拆分 if/elseif 条件文本（支持 "条件A or 条件B" 格式）
-- @param condition string 条件文本，如 "卡组中 or 卡组顶"
-- @return table 条件子项数组，如 {"卡组中", "卡组顶"}
function INE.SplitCondition(condition)
    local parts = {}
    local startPos = 1
    while true do
        local orPos = string.find(condition, " or ", startPos, true)
        if not orPos then
            local part = condition:sub(startPos):match("^%s*(.-)%s*$")
            if part and part ~= "" then
                table.insert(parts, part)
            end
            break
        end
        local part = condition:sub(startPos, orPos - 1):match("^%s*(.-)%s*$")
        if part and part ~= "" then
            table.insert(parts, part)
        end
        startPos = orPos + 4
    end
    return parts
end

-- 判断条件文本是否与选中的选项值匹配（支持 "条件A or 条件B" 与 if input/output 扩展）
-- @param condition string 条件文本（"else" 表示无条件分支）
-- @param selectedValue string|nil 前方 select 组件当前选中的选项文本
-- @param context table|nil 节点连接上下文 { inputNames = {...}, outputNames = {...} }，
--                          供 `if input={...}` / `if output={...}` 条件判断
-- @return boolean 是否匹配
function INE.ConditionMatches(condition, selectedValue, context)
    if condition == "else" then
        return true
    end
    local condParts = INE.SplitCondition(condition)
    for _, cond in ipairs(condParts) do
        -- if input={名称1、名称2} / if output={名称1、名称2} 条件扩展：
        -- 所连接节点/开始点的内部名称与右侧数组无序相等（右侧每项均被实际连接覆盖）即通过
        local ioMatch = cond:match("^input%s*=%s*%{(.+)%}$") or cond:match("^output%s*=%s*%{(.+)%}$")
        if ioMatch then
            local isInput = cond:sub(1, 5) == "input"
            local names = {}
            for part in ioMatch:gmatch("[^、,]+") do
                part = part:match("^%s*(.-)%s*$")
                if part ~= "" then
                    table.insert(names, part)
                end
            end
            local actualNames = isInput and context and context.inputNames or (context and context.outputNames)
            if actualNames and #names > 0 then
                local allFound = true
                for _, name in ipairs(names) do
                    local found = false
                    for _, an in ipairs(actualNames) do
                        if an == name then
                            found = true
                            break
                        end
                    end
                    if not found then
                        allFound = false
                        break
                    end
                end
                if allFound then
                    return true
                end
            end
        elseif selectedValue ~= nil and cond == selectedValue then
            return true
        end
    end
    return false
end

--[[
    构建节点的输入/输出连接名称上下文（供 `if input={...}` / `if output={...}` 判断）

    输入连接：连入当前节点的来源（开始点/节点）内部名称
    输出连接：当前节点连出的目标节点内部名称
    内部名称优先取 data.title（开始点如"在场"、"激活时"），无 title 时回退节点 name。

    @param editor table 编辑器实例
    @param nodeId string 节点 ID
    @return table { inputNames = {...}, outputNames = {...} }
]]
function INE:GetNodeIOContext(editor, nodeId)
    local ctx = { inputNames = {}, outputNames = {} }
    if not editor or not editor.connections or not nodeId then
        return ctx
    end
    for _, conn in ipairs(editor.connections) do
        local isInput = conn.toNode == nodeId
        local isOutput = conn.fromNode == nodeId
        if isInput or isOutput then
            local otherId = isInput and conn.fromNode or conn.toNode
            local otherNode = self:GetNodeByID(editor, otherId)
            if otherNode then
                local name = otherNode.data and otherNode.data.title
                if not name or name == "" then
                    name = otherNode.name
                end
                if name then
                    table.insert(isInput and ctx.inputNames or ctx.outputNames, name)
                end
            end
        end
    end
    return ctx
end

-- 解析配置字符串为主函数
function INE.ParseConfig(configString, startComponentId)
    if not configString or configString == "" then
        return {
            components = {},
            inputTypes = {},
            outputTypes = {}
        }
    end
    
    -- 检查缓存（仅对顶层调用缓存，分支递归调用不缓存，因ID依赖外层componentId）
    if not startComponentId and INE.ConfigCache[configString] then
        if type(INE.ConfigCache[configString]) == "table" and not INE.ConfigCache[configString].components then
            return {
                components = INE.ConfigCache[configString],
                inputTypes = {},
                outputTypes = {}
            }
        end
        return INE.ConfigCache[configString]
    end
    
    local components = {}
    local inputTypes = {}
    local outputTypes = {}
    local str = configString:gsub("\n", " "):gsub("\r", " ")
    local i = 1
    local len = #str
    local componentId = startComponentId or 0
    
    -- 跳过开头的空白字符
    while i <= len and str:sub(i, i):match("%s") do
        i = i + 1
    end
    
    -- 1. 解析开头的输入数据类型
    inputTypes, i = INE.ParseInputTypes(str, i, len)
    
    -- 2. 解析剩余的组件
    while i <= len do
        local char = str:sub(i, i)
        local component = nil
        
        if char == "'" then
            component, i, componentId = INE.ParseTextComponent(str, i, len, componentId)
        elseif char == "{" then
            component, i, componentId = INE.ParseSelectComponent(str, i, len, componentId)
        elseif char == "[" then
            component, i, componentId = INE.ParseNumberComponent(str, i, len, componentId)
        elseif char == "<" then
            component, i, componentId = INE.ParseTextSlotComponent(str, i, len, componentId)
        elseif char == "(" then
            outputTypes, i = INE.ParseOutputTypes(str, i, len)
        elseif char == "#" then
            component, i, componentId = INE.ParseFuncSlot(i, componentId)
            i = i + 1
        elseif char == "i" and str:sub(i, i + 1) == "if" then
            local branchOutputTypes
            component, i, componentId, branchOutputTypes = INE.ParseConditionalComponent(str, i, len, componentId)
            if #branchOutputTypes > 0 then
                outputTypes = branchOutputTypes
            end
        elseif char:match("%s") then
            i = i + 1
        else
            i = i + 1
        end
        
        if component then
            table.insert(components, component)
        end
    end
    
    local result = {
        components = components,
        inputTypes = inputTypes,
        outputTypes = outputTypes
    }
    
    if not startComponentId then
        INE.ConfigCache[configString] = result
    end
    return result
end
