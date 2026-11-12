--[[
=======================================================================================
函数子编辑器 (Function Sub-Editor)
=======================================================================================
从 cl_ine_node_editor.lua 拆分出的子系统，负责函数变量的子编辑器管理。

包含功能：
  - OpenFunctionSubEditor（打开/激活函数变量的子编辑器）
  - GenerateFunctionDescription（为函数类型变量生成内容描述）

源文件：cl_ine_node_editor.lua
  - OpenFunctionSubEditor：行 3407~3542
  - GenerateFunctionDescription：行 4072~4315
=======================================================================================
]]

-- 此文件内容将剪切自 cl_ine_node_editor.lua 以下片段：
--   行 3407~3542（OpenFunctionSubEditor）
--   行 4072~4315（GenerateFunctionDescription）
local INE = KARDS.CardEditor.IndependentNodeEditor

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

--[[
    打开或激活函数变量的子编辑器。
    当用户新增函数变量或点击已有函数变量时调用。
    创建一个新的 INE 编辑器实例作为函数编辑页面，
    仅包含"调用"开始点，采用 function 模式。
    
    @param  editor      {table}    父编辑器实例
    @param  varName     {string}   函数变量名称
    @param  arrayItem   {table}    （可选）数组项引用，当函数作为数组项自包含时传入
]]
function INE:OpenFunctionSubEditor(editor, varName, arrayItem)
    if not editor or not varName then return end
    
    local isArrayItem = arrayItem ~= nil
    local subID
    
    if isArrayItem then
        -- 局部函数槽（arrayItem._subKey 存在）：使用稳定 ID，保证同一槽重复打开时复用同一面板
        if arrayItem._subKey then
            subID = "ine_func_" .. editor.id .. "_loc_" .. arrayItem._subKey
        else
            -- 普通数组项中的函数：使用计数器生成唯一子编辑器ID
            editor._arrayFuncCounter = (editor._arrayFuncCounter or 0) + 1
            subID = "ine_func_" .. editor.id .. "_arr_" .. editor._arrayFuncCounter
        end
        -- 注册数组项引用到追踪表
        editor._arrayFuncItemRegistry = editor._arrayFuncItemRegistry or {}
        editor._arrayFuncItemRegistry[subID] = arrayItem
    else
        subID = "ine_func_" .. editor.id .. "_" .. varName
    end
    
    -- 检查是否已存在，若存在则激活并返回
    if INE.Editors[subID] then
        editor.functionSubEditors = editor.functionSubEditors or {}
        editor.functionSubEditors[varName] = subID
        editor.activeFunctionEditor = subID
        INE.Editors[subID].hidden = false
        return
    end
    
    -- 确保 function 模式的开始点已注册
    if not INE.RegisteredNodes["start_point"] then
        return
    end
    
    -- 计算子编辑器位置（在父编辑器内部居中，略小于父编辑器）
    local subW = math.min(600, editor.width - 60)
    local subH = math.min(400, editor.height - 60)
    local subX = editor.x + (editor.width - subW) / 2
    local subY = editor.y + (editor.height - subH) / 2
    
    -- 收集所有非开始点节点，允许在函数编辑器中使用
    local allowedNodes = {}
    for nodeName, nodeTpl in pairs(INE.RegisteredNodes) do
        if not nodeTpl.isStartNode then
            table.insert(allowedNodes, nodeName)
        end
    end
    table.insert(allowedNodes, "start_point")
    
    -- 创建子编辑器，采用 function 模式（只有"调用"开始点）
    INE:CreateEditor(
        subID,
        {x = subX, y = subY, width = subW, height = subH},
        1,
        allowedNodes,
        false,   -- hidden
        false,   -- simplified
        false,   -- borderless
        true,   -- showTitleMenu（函数模式显示"函数"按钮）
        "function",  -- editorMode (只有"调用"开始点)
        false,   -- showCoordinates
        true     -- draggable：函数面板可通过标题栏拖动
    )
    
    -- 设置标题为函数名称
    local subEditor = INE.Editors[subID]
    if subEditor then
        subEditor.customTitle = T("editor.nodesub.function_title", varName)
        -- 所有函数子编辑器不可被关闭按钮关闭（由父编辑器管理）
        subEditor._isFunctionSubEditor = true
        -- 保存父编辑器和函数变量名引用，便于"编辑基础函数"等功能使用
        subEditor._parentEditorID = editor.id
        subEditor._funcVarName = varName
        
        -- 添加到父编辑器的子编辑器跟踪表
        editor.functionSubEditors = editor.functionSubEditors or {}
        editor.activeFunctionEditor = subID
        
        if isArrayItem then
            -- 数组项中的函数：使用 subID 作为跟踪键
            editor.functionSubEditors[subID] = subID
            -- 数组项中的函数：从数组项读取数据
            subEditor._arrayItemRef = arrayItem
            if arrayItem.functionData then
                subEditor._savedFunctionData = arrayItem.functionData
                ImportNodeEditorData(subID, arrayItem.functionData)
            end
            -- 从数组项加载参数
            if arrayItem.params and #arrayItem.params > 0 then
                subEditor._funcParams = arrayItem.params
            end
        else
            -- 普通函数变量：使用变量名作为跟踪键
            editor.functionSubEditors[varName] = subID
            -- 普通函数变量：从编辑器保存的函数数据中读取
            -- 检查是否有已保存的函数数据（优先已保存的，再检查从导入恢复的）
            if editor._savedFunctionData and editor._savedFunctionData[varName] then
                subEditor._savedFunctionData = editor._savedFunctionData[varName]
                -- 将已保存的节点和连接恢复到子编辑器中
                ImportNodeEditorData(subID, editor._savedFunctionData[varName])
            elseif editor._importedFunctionData and editor._importedFunctionData[varName] then
                subEditor._savedFunctionData = editor._importedFunctionData[varName]
                ImportNodeEditorData(subID, editor._importedFunctionData[varName])
            end
            
            -- 查找函数变量定义，将参数复制到子编辑器的只读变量列表
            local funcVars = editor.variables["f"] or {}
            for _, fv in ipairs(funcVars) do
                if fv.name == varName and fv.params and #fv.params > 0 then
                    subEditor._funcParams = fv.params
                    break
                end
            end
        end
    end
end

-- 收集变量库变量，按数据类型归类（n/b/t/g/e/f）
-- 判断变量是否为卡牌对象数组（数组内只有卡牌对象）
local function IsObjectArrayVar(key, value)
    if type(value) ~= "table" then return false end
    -- Battle 中的 Units 类变量（如 FriendlyUnits, EnemyUnits 等）
    if key:match("Units$") then return true end
    -- Special 中的 Cards 类变量（如 HandCards, FieldCards 等）
    if key:match("Cards$") then return true end
    return false
end

-- 获取变量类型标识
local function GetVarType(key, value)
    if type(value) == "number" then return "n" end
    if type(value) == "boolean" then return "b" end
    if type(value) == "string" then return "t" end
    if IsObjectArrayVar(key, value) then return "eg" end
    return "g"
end

function CollectLibVarsByType(editor)
    local result = {n = {}, b = {}, t = {}, g = {}, e = {}, f = {}, eg = {}}
    local varLib = KARDS.VarLib.Get("__ine_template__" .. editor.id)
    if not varLib then
        varLib = KARDS.VarLib.Create("__ine_template__" .. editor.id)
    end

    -- Battle
    if varLib.Battle then
        for k, v in pairs(varLib.Battle) do
            if type(k) == "string" and k:sub(1,1) ~= "_" then
                local varType = GetVarType(k, v)
                local path = "Battle." .. k
                local displayName = (KARDS.VarLib.GetDisplayName and KARDS.VarLib.GetDisplayName(path)) or k
                table.insert(result[varType], {key = k, name = displayName, path = path})
            end
        end
    end

    -- OffTable
    if varLib.OffTable then
        for k, v in pairs(varLib.OffTable) do
            if type(k) == "string" and k:sub(1,1) ~= "_" then
                local varType = GetVarType(k, v)
                local path = "OffTable." .. k
                local displayName = (KARDS.VarLib.GetDisplayName and KARDS.VarLib.GetDisplayName(path)) or k
                table.insert(result[varType], {key = k, name = displayName, path = path})
            end
        end
    end

    -- Special（展平所有关键词下的变量，按类型归类）
    if varLib.Special then
        for _, kw in ipairs({"Deploy","Guard","Smoke","Blitz","Ambush","DeathPlan","HeavyArmor1","HeavyArmor2","HeavyArmor3","ActiveEffect","PassiveEffect","Veteran","Cooperation","Intel","Impact","FightHard","Mountain","Confiscate","Confiscated","Suppressed","Pincer","Unit","Command","Counter","Infantry","Artillery","Tank","Fighter","Bomber","Inhibited"}) do
            if varLib.Special[kw] then
                for k, v in pairs(varLib.Special[kw]) do
                    local varType = GetVarType(k, v)
                    local path = "Special." .. kw .. "." .. k
                    local displayName = (KARDS.VarLib.GetDisplayName and KARDS.VarLib.GetDisplayName(path)) or (kw .. "." .. k)
                    table.insert(result[varType], {key = kw .. "." .. k, name = displayName, path = path})
                end
            end
        end
    end

    -- 按 key 排序
    for _, list in pairs(result) do
        table.sort(list, function(a, b) return a.key < b.key end)
    end
    return result
end

--[[
    为函数类型变量生成内容描述。
    通过遍历函数节点图中的执行路径，依次访问每个节点并提取配置文本，
    最终拼接成描述函数行为的自然语言。
    
    @param  savedData   {table}     从 _savedFunctionData 获取的节点图数据
    @return {string}                函数行为描述文本，失败时返回 "—"
]]
function INE:GenerateFunctionDescription(savedData)
    -- 数据有效性检查
    if not savedData or not savedData.nodes or #savedData.nodes == 0 then
        return "—"
    end
    
    -- 1. 构建节点ID -> 节点查找表
    local nodesById = {}
    for _, node in ipairs(savedData.nodes) do
        nodesById[node.id] = node
    end
    
    -- 2. 构建执行连接邻接表（fromNode -> {toNode, fromPort}[]）
    local adjList = {}
    for _, conn in ipairs(savedData.connections or {}) do
        if not adjList[conn.fromNode] then
            adjList[conn.fromNode] = {}
        end
        table.insert(adjList[conn.fromNode], {
            toNode = conn.toNode,
            fromPort = conn.fromPort or "output"
        })
    end
    
    -- 3. 查找所有 start_point 节点（函数模式的起始节点）
    local startNodes = {}
    for _, node in ipairs(savedData.nodes) do
        if node.name == "start_point" then
            table.insert(startNodes, node)
        end
    end
    if #startNodes == 0 then
        return "—"
    end
    
    -- 提取组件文本的助手函数
    local function getComponentText(comp, data)
        if comp.type == "text" then
            return comp.text or ""
        elseif comp.type == "select" then
            local idx = data[comp.id] or 1
            return comp.options[idx] or comp.options[1] or ""
        elseif comp.type == "number" then
            if data.numbers and data.numbers[comp.id] and data.numbers[comp.id].selectedOptionIndex then
                local idx = data.numbers[comp.id].selectedOptionIndex
                -- 优先使用 comp.options（解析自 DSL 配置的静态选项）
                if comp.options and comp.options[idx] then
                    return comp.options[idx]
                end
                -- 回退到 slotOptions（运行时解析的选项，如 [lib] 模式下的变量库变量名）
                if data.numbers[comp.id].slotOptions and data.numbers[comp.id].slotOptions[idx] then
                    return data.numbers[comp.id].slotOptions[idx]
                end
                return ""
            end
            if data[comp.id] and comp.options then
                return comp.options[data[comp.id]] or ""
            end
            if comp.options then
                return comp.options[1] or ""
            end
            -- 基本数字输入（无选项列表）：返回存储的数值
            return data[comp.id] ~= nil and tostring(data[comp.id]) or ""
        end
        return ""
    end
    
    -- 拆分条件文本（支持 "条件A or 条件B" 格式）
    local function splitCondition(condition)
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

    -- 递归处理组件列表（支持 if 分支）
    -- lastSelectText 跟踪前一个 select 组件选中的文本，用于筛选 if 分支
    local function processComponents(compList, data, outTexts, lastSelectText)
        lastSelectText = lastSelectText or ""
        
        for _, comp in ipairs(compList) do
            if comp.type == "if" then
                -- 根据前一个 select 选中文本筛选分支
                local branchStrs = {}
                local matchedBranch = nil
                local hasElseBranch = false
                
                for _, branch in ipairs(comp.branches) do
                    local condition = branch.condition or ""
                    if condition == "else" then
                        hasElseBranch = true
                    elseif matchedBranch == nil and lastSelectText ~= "" then
                        -- 检查该分支的条件是否匹配选中的文本
                        local condParts = splitCondition(condition)
                        for _, cond in ipairs(condParts) do
                            if cond == lastSelectText then
                                matchedBranch = branch
                                break
                            end
                        end
                    end
                end
                
                -- 使用匹配的分支，或回退到 else 分支
                local targetBranch = matchedBranch
                if not targetBranch and hasElseBranch then
                    -- 没有匹配的分支，使用 else 分支
                    for _, branch in ipairs(comp.branches) do
                        if branch.condition == "else" then
                            targetBranch = branch
                            break
                        end
                    end
                end
                
                -- 处理选中的分支
                if targetBranch then
                    local subTexts = {}
                    processComponents(targetBranch.components, data, subTexts, lastSelectText)
                    local branchStr = table.concat(subTexts, "")
                    if branchStr and branchStr ~= "" then
                        table.insert(branchStrs, branchStr)
                    end
                end
                
                if #branchStrs > 0 then
                    table.insert(outTexts, table.concat(branchStrs, ""))
                end
            elseif comp.type == "select" then
                -- 更新 lastSelectText 为当前选中的选项文本
                local idx = data[comp.id] or 1
                lastSelectText = comp.options[idx] or comp.options[1] or ""
                
                local text = getComponentText(comp, data)
                if text and text ~= "" then
                    table.insert(outTexts, text)
                end
            else
                local text = getComponentText(comp, data)
                if text and text ~= "" then
                    table.insert(outTexts, text)
                end
            end
        end
    end
    
    -- 提取单个节点的显示文本
    local function getNodeText(node)
        if not node then return "" end
        -- 开始点节点没有内容文本，跳过
        if node.name == "start_point" then return "" end
        if not node.config or node.config == "" then
            -- 尝试使用节点注册时的显示名称
            local template = INE.RegisteredNodes[node.name]
            if template and template.displayName then
                return template.displayName
            end
            return ""
        end
        
        -- 使用 pcall 保护，防止解析失败
        local ok, configResult = pcall(INE.ParseConfig, node.config)
        if not ok or not configResult or not configResult.components then return "" end
        
        local texts = {}
        local nodeData = node.data or {}
        pcall(processComponents, configResult.components, nodeData, texts)
        return table.concat(texts, "")
    end
    
    -- 5. DFS 遍历执行路径（跟踪 visited 避免死循环）
    local visited = {}
    local allPaths = {}
    
    local function dfs(nodeId, currentPath)
        if not nodeId then return end
        if visited[nodeId] then return end  -- 避免死循环
        
        local node = nodesById[nodeId]
        if not node then return end
        
        visited[nodeId] = true
        table.insert(currentPath, node)
        
        local outgoing = adjList[nodeId]
        if not outgoing or #outgoing == 0 then
            -- 到达路径终点，保存当前路径的副本
            local pathCopy = {}
            for _, n in ipairs(currentPath) do
                table.insert(pathCopy, n)
            end
            table.insert(allPaths, pathCopy)
        else
            -- 有多个输出分支时，每条连接作为独立分支遍历
            for _, edge in ipairs(outgoing) do
                dfs(edge.toNode, currentPath)
            end
        end
        
        -- 回溯
        table.remove(currentPath)
        visited[nodeId] = false
    end
    
    for _, startNode in ipairs(startNodes) do
        dfs(startNode.id, {})
    end
    
    -- 6. 将每条路径转为文本片段
    local pathFragments = {}
    for _, path in ipairs(allPaths) do
        local nodeTexts = {}
        for _, node in ipairs(path) do
            local text = getNodeText(node)
            if text and text ~= "" then
                table.insert(nodeTexts, text)
            end
        end
        if #nodeTexts > 0 then
            table.insert(pathFragments, table.concat(nodeTexts, "，"))
        end
    end
    
    if #pathFragments == 0 then
        return "—"
    end
    
    return table.concat(pathFragments, "。且")
end
