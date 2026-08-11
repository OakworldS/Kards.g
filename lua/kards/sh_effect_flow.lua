--[[
    节点解析系统：效果控制流与 e 类型数据线（ExecuteEffectFlow / ResolveEWires）

    自 sh_node_parser.lua 按职责拆分（re.md B-H3）：本文件承载
      - ResolveEWires：e 类型数据线运行时解析（上游 extract/target_selector 输出卡牌对象组 → 注入下游 targets）
      - ExecuteEffectFlow：控制流模式执行（沿 connections 连线执行；双输出节点按结果分支；
        跨刻挂起检测；startNodeId 跨刻恢复）
    文件末尾暴露 KARDS.NodeParser.ExecuteEffectFlow / KARDS.NodeParser.ResolveEWires
    （ExecuteEffect / ExecuteBaseNode（sh_node_parser.lua）与 ResumeEffect（sh_node_hooks.lua）
    经表访问调用，避免局部作用域顺序问题）。

    跨文件共享（GLua 无跨文件 local）：GetTemplateType 由 sh_node_parser.lua 暴露，
    本文件开头取本地引用。

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_node_parser.lua 之后）
]]

KARDS = KARDS or {}
KARDS.NodeParser = KARDS.NodeParser or {}

-- 跨文件共享（GLua 无跨文件 local）：主文件（sh_node_parser.lua）已暴露，本文件取本地引用
local GetTemplateType = KARDS.NodeParser.GetTemplateType

-- ====================================================================
-- e 类型数据线运行时解析（extract 输出卡牌对象组 → 下游消费）
-- ====================================================================
-- 数据线（dataConnections）编辑器导出格式 { id, fromNode, toNode, fromPortIndex,
-- toPortIndex, dataType, variableName }。当前运行时：
--   - n/p/t 等数字/布尔/文本线：经 variableName 指向全局变量（var_set/var_evaluate 消费）
--   - e 类型线（extract 首次产生真实对象组）：从上游节点 node.data[输出端口名] 读取
--     （variableName 即上游输出端口名，编辑器 fromPort.portData.name 同源），
--     结果直接注入下游节点的 targets（action 类节点以对象组为目标集执行）。
-- 依赖 ExecuteEffect / ExecuteEffectFlow 预置 ctx._nodesById（节点 id → 节点实例）。
-- @param ctx     table 执行上下文（含 dataConnections / _nodesById）
-- @param node    table 消费者节点实例（dc.toNode == node.id 时命中）
-- @param targets table|nil 原 targets（未接 e 线时原样返回）
-- @return table 注入后的目标集
local function ResolveEWires(ctx, node, targets)
    local t = targets or {}
    if not node or not ctx.dataConnections or not ctx._nodesById then return t end
    for _, dc in ipairs(ctx.dataConnections) do
        if dc.dataType == "e" and dc.toNode == node.id then
            local from = ctx._nodesById[dc.fromNode]
            local val = from and from.data and from.data[dc.variableName or ""]
            -- 兜底：输出端口名可能带 e 前缀（node.data["e提取的卡牌对象组"]）
            if val == nil and dc.variableName and dc.variableName:sub(1, 1) ~= "e" then
                val = from.data["e" .. dc.variableName]
            end
            if type(val) == "table" then
                t = val -- 卡牌对象组直接作为下游目标集
            end
        end
    end
    return t
end

-- 暴露给 ExecuteBaseNode（sh_node_parser.lua）经表访问调用（GLua 无跨文件 local）
KARDS.NodeParser.ResolveEWires = ResolveEWires

-- ====================================================================
-- 控制流模式执行：沿 connections 连线从入口节点依次执行
-- ====================================================================
-- 双输出节点（node.hasSecondOutput，如 condition / loop）按执行结果选择端口：
--   结果 true  → fromPort "satisfied"（condition 条件满足 / loop 继续循环）
--   结果 false → fromPort "not_satisfied"（condition 条件不满足 / loop 循环结束）
-- 其余节点沿 fromPort "output" 连接走。入口 = 无入边的节点（闭环时优先 loop 节点，再兜底首节点）。
-- 防死循环：visited 按「循环轮次」记录——loop 节点返回 true（继续循环）时轮次 +1，
-- 允许环内节点在下一轮重新执行（loop 循环图：第一输出点连回循环体）；非 loop 双输出/普通节点
-- 轮次不变（沿用原单轮去重语义，汇聚节点只执行一次）。
-- startNodeId（可选）：跨刻恢复模式——不执行入口，从该节点沿 output 连线继续
-- （turn「等待」挂起后由 ResumeEffect 传入挂起节点 id，挂起节点本身不再次执行）。
-- @param ctx         table 执行上下文（含 tableID / _T；_currentEffect 供 turn 挂起取效果数据）
-- @param card        table 效果发起卡牌句柄
-- @param targets     table 受影响卡牌列表
-- @param effect      table 效果数据（nodes / connections）
-- @param startNodeId any|nil 跨刻恢复起点节点 id（缺省从入口执行）
-- @return boolean 是否至少成功执行一个节点
local function ExecuteEffectFlow(ctx, card, targets, effect, startNodeId)
    ctx._currentEffect = effect -- 当前效果数据（turn「等待」挂起时保存，供达标后恢复）
    local nodesById, outEdges, hasIncoming = {}, {}, {}
    for _, node in ipairs(effect.nodes) do
        if node.id ~= nil then nodesById[node.id] = node end
    end
    ctx._nodesById = nodesById -- 供 ResolveEWires 定位上游节点输出
    for _, conn in ipairs(effect.connections or {}) do
        if conn.fromNode ~= nil and conn.toNode ~= nil then
            outEdges[conn.fromNode] = outEdges[conn.fromNode] or {}
            outEdges[conn.fromNode][conn.fromPort or "output"] = conn.toNode
            hasIncoming[conn.toNode] = true
        end
    end
    -- 入口节点：无入边的节点；全部有入边（闭环，如 loop 循环图）时优先 loop 节点，其次兜底首节点
    local entries = {}
    for _, node in ipairs(effect.nodes) do
        if not hasIncoming[node.id] then table.insert(entries, node) end
    end
    if #entries == 0 then
        for _, node in ipairs(effect.nodes) do
            if GetTemplateType(node) == "loop" then entries[1] = node break end
        end
        if #entries == 0 and effect.nodes[1] then entries[1] = effect.nodes[1] end
    end

    local executed, visited = false, {}
    local round = 1 -- 循环轮次（loop 节点返回 true 时 +1，允许环内节点重新执行）
    local function runNode(node)
        if not node or visited[node.id] == round then return end
        visited[node.id] = round
        local tplType = GetTemplateType(node)
        local ok = false
        local result = nil -- base 节点执行返回值（双输出节点用作分支选择）
        if node.type == "var_set" then
            ok = KARDS.NodeParser.ParseSetVariable(ctx, node)
        elseif node.type == "var_evaluate" then
            -- 判断节点自身不产生效果，结果为事件分支（正式版由事件系统消费）
            KARDS.NodeParser.ParseEvaluateVariable(ctx, node)
            ok = true
        elseif tplType and KARDS.NodeParser.BaseSemantics[tplType] then
            result = KARDS.NodeParser.ExecuteBaseNode(ctx, card, targets, node)
            -- 双输出节点（condition / loop）：完成判断即视为执行成功（结果 false 也是有效分支走向）
            ok = node.hasSecondOutput and true or (result or false)
        elseif node.type == "start" or node.name == "start_point" then
            ok = true -- 信号开始点（函数子图「调用」入口）：无语义，仅作为执行起点
        else
            print("[NodeParser] ExecuteEffect: 跳过未知节点（type=" .. tostring(node.type) ..
                  " name=" .. tostring(node.name) .. "）")
        end
        if ok then executed = true end
        -- 跨刻挂起检测：turn「等待」执行后信号停滞在该节点（效果挂起，等待时间刻推进恢复）
        if node.data and node.data._turnPaused then
            node.data._turnPaused = nil -- 清除挂起标记（恢复时从本节点 output 后继继续，不重入本节点）
            return
        end
        -- 选择下一节点：双输出节点按执行结果分支，普通节点走 output
        local nextPort = "output"
        if node.hasSecondOutput then
            if result == true then
                nextPort = "satisfied"
                -- loop 节点：循环未结束 → 下一轮允许已访问节点重新执行（走回循环体）
                if tplType == "loop" then round = round + 1 end
            else
                nextPort = "not_satisfied"
            end
        end
        local edges = outEdges[node.id]
        if edges then
            runNode(nodesById[edges[nextPort]])
        end
    end
    if startNodeId ~= nil then
        -- 跨刻恢复模式：从挂起节点沿 output 连线继续（挂起节点本身不再执行）
        local resumeEdges = outEdges[startNodeId]
        if resumeEdges and resumeEdges.output then
            runNode(nodesById[resumeEdges.output])
        end
        return executed
    end
    for _, entry in ipairs(entries) do
        runNode(entry)
    end
    return executed
end

-- 暴露给跨刻恢复流程（ResumeEffect 在 ExecuteEffectFlow 定义前引用，经表访问避免局部作用域顺序问题）
KARDS.NodeParser.ExecuteEffectFlow = ExecuteEffectFlow