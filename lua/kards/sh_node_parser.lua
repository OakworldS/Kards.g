--[[
=======================================================================================
节点解析系统：设置变量节点专属解析器 (Node Parser: Set Variable)
=======================================================================================
将「设置变量」(var_set) 节点的数据结构（node.data._setEntries）翻译为战斗系统操作。

数据来源（卡牌效果文件 effects/*.json，由 SaveEffect 保存）：
  - nodes            节点数组（含 type="var_set" 的节点，data._setEntries 为设置行数组）
  - dataConnections  数据线数组（含 variableName，设置行来源为数据线时据此定位目标变量）
  - variables        编辑器全局变量定义（internalName 已带 KARDS.User. 前缀）

节点数据结构（与 cl_ine_var_op_nodes.lua DrawSetVariable 保持一致）：
  _setEntries[i] = {
    id        = 条目 ID,
    varName   = 目标变量显示名（编辑器 GetVarDisplayName：name 优先，internalName 兜底）,
    varType   = n/b/t/g/e/f（目标变量类型）,
    source    = "global"（全局变量）/ "input"（数据线传入）,
    connId    = 数据线 ID（source == "input" 时）,
    opIdx     = 操作索引（SET_OPS / SET_OBJ_OPS 选项集内）,
    value     = 值（按类型语义不同，详见各处理函数）,
    subOpIdx  = 数组「第/最后一项」子操作（1=值 2=类型）,
    itemType  = 数组项类型（n/b/t/e/g/f）,
    itemName  = 数组项名（subOpIdx==2 时）,
    objMode   = 对象类别（unit/cmd/empty，仅 e 类型）,
    kwInit    = 词条初始值带出标记（编辑器内部用，解析忽略）,
  }

操作集（与 cl_ine_var_op_nodes.lua L75-97 常量一致）：
  n {设为、增加、减少} / b {设为、反转} / g {设为、第、最后一项}
  e（unit 13 项 / cmd 9 项 / empty 固定「设为」）/ f {改为}（占位）

值语义（与 DrawSetVariable 渲染一致）：
  n      entry.value = 数字 或 "var:<显示名>"（引用数字变量）
  b      设为 → "true"/"false"；反转 → 无值输入
  t      entry.value = 文本
  g      设为 → 数组变量显示名；第/最后一项 → 项索引 + 项值/项类型
  e      empty 设为 → 对象变量显示名；数值属性（花费/行动花费/攻击力/防御力）→ 数字或 "var:" 引用；
         插图属性 → "../data/kards_images/<文件>"；词条 → 逗号分隔词条 id；
         文本槽（卡牌名称/描述/历史文本）→ "var:<名>" 引用 或 直接文本；其余 → 文本
  f      「改为 #」占位（函数子编辑器未接入，解析跳过并告警）

映射原则（战斗系统规划）：
  - 数字/布尔/文本/数组变量写入 → KARDS.VarLib 变量库（用户自定义存 Battle/OffTable，
    scope=="longterm" 存 OffTable，否则存 Battle；internalName 即存储键）
  - 对象数值属性（攻击/防御）→ 卡牌句柄 :ApplyChange(stat, "set", N)
  - 对象花费/行动花费 → 卡牌句柄字段赋值（骨架卡牌接口暂无 setter，见 sh_card_interface.lua）
  - 对象词条/单位类型/名称/外观 → 卡牌句柄字段赋值（无公开 setter 的字段直接改内部字段）
  - 所有写入均记录 stat_change 刻（对齐规划：change 编码 "+N"/"-N"/"=N"）

依赖：
  - KARDS.VarLib（变量库读写）
  - KARDS.TickLog（stat_change 刻记录）
  - KARDS.CardInterface（卡牌句柄接口 / 词条白名单 / 单位类型白名单）
  - KARDS.Battle（可选：取当前牌桌 ID；由调用方通过 ctx 注入）

加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_battle_stub.lua 之后）
=======================================================================================
]]

KARDS = KARDS or {}
KARDS.NodeParser = KARDS.NodeParser or {}

-- ====================================================================
-- base 通用解析器（base 型节点：action / combat 等模板节点）
-- ====================================================================

-- 解析 base 结构串为组件树（纯结构，不含节点数据）
-- base 语法（对齐 INE._CompsToBase 固化输出，不含文本组件）：
--   <输入类型前缀 n/p/t/g/e/f 连续> {N} 下拉（N 个选项） [N] 数字槽（N 个预设选项，0=空槽）
--   [lib] / [lib+N] 变量库数字槽 # 函数槽 <> 文本槽（2026-10-04 新增，可填文本/引用文本变量）
--   if <分支序号> then ... elseif <分支序号> then ... else ... end（可嵌套）
--   (<输出类型+名，如 nResult、tName、可多个以、分隔>) 后缀
-- @param baseStr string 模板 base 结构串（如 action 模板的 base 字段）
-- @return table { inputTypes, outputTypes, components } 组件树
--   select:   { type, id, optionsCount }
--   number:   { type, id, optionsCount, useLib, extraCount }
--   funcslot: { type, id }
--   textslot: { type, id }（文本值由 FillBaseValues 从 node.data 读取）
--   if:       { type, id, boundSelectId, branches = { {index?, else?, components} } }
--             boundSelectId = 同一分支内 if 之前的最近 select（编辑器按最近 select 选中值匹配分支）
function KARDS.NodeParser.ParseBaseStructure(baseStr)
    local result = { inputTypes = {}, outputTypes = {}, components = {} }
    if not baseStr or baseStr == "" then return result end
    local str = baseStr:gsub("\n", " "):gsub("\r", " ")
    local i, len = 1, #str
    -- 各组件类型独立计数（对齐编辑器 ParseConfig 的 id 生成：select_1、number_1、funcslot_1 分别计数）
    local selectCount = 0
    local numberCount = 0
    local funcslotCount = 0
    local textCount = 0
    local ifId = 0

    -- 跳过开头空白，解析前缀输入类型（连续 n/p/t/g/e/f）
    while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
    while i <= len and str:sub(i, i):match("[nptgef]") do
        table.insert(result.inputTypes, str:sub(i, i))
        i = i + 1
    end

    -- 作用域栈：每层 = 一个 if 帧（分支数组 + 当前分支收集目标）
    -- 分支内 select 只更新该分支的 lastSelect（编辑器按同一 compList 内最近 select 判定分支）
    local ifStack = {}
    local topLastSelect = nil

    local function curFrame()
        return ifStack[#ifStack]
    end
    local function addComp(comp)
        local f = curFrame()
        if f then
            table.insert(f.curBranch.components, comp)
        else
            table.insert(result.components, comp)
        end
        if comp.type == "select" then
            if f then
                f.curBranch.lastSelect = comp.id
            else
                topLastSelect = comp.id
            end
        end
    end

    while i <= len do
        local c = str:sub(i, i)
        if c == "{" then
            local j = str:find("}", i, true)
            if not j then
                i = i + 1
            else
                local n = tonumber(str:sub(i + 1, j - 1))
                i = j + 1
                if n and n > 0 then
                    selectCount = selectCount + 1
                    addComp({ type = "select", id = "select_" .. selectCount, optionsCount = n })
                end
            end
        elseif c == "[" then
            local j = str:find("]", i, true)
            if not j then
                i = i + 1
            else
                local content = str:sub(i + 1, j - 1)
                i = j + 1
                numberCount = numberCount + 1
                local comp = { type = "number", id = "number_" .. numberCount, optionsCount = 0, useLib = false, extraCount = 0 }
                if content == "lib" then
                    comp.useLib = true
                elseif content:sub(1, 4) == "lib+" then
                    comp.useLib = true
                    comp.extraCount = tonumber(content:sub(5)) or 0
                else
                    comp.optionsCount = tonumber(content) or 0
                end
                addComp(comp)
            end
        elseif c == "#" then
            funcslotCount = funcslotCount + 1
            addComp({ type = "funcslot", id = "funcslot_" .. funcslotCount })
            i = i + 1
        elseif c == "<" then
            -- 文本槽（<>，2026-10-04 新增）：结构占位，槽值由 FillBaseValues 从 node.data 读取
            -- （编辑器侧对应 INE.ParseTextSlotComponent，base 由 _CompsToBase 固化为 <>）
            local j = str:find(">", i, true)
            if not j then
                i = i + 1
            else
                i = j + 1
                textCount = textCount + 1
                addComp({ type = "textslot", id = "textslot_" .. textCount })
            end
        elseif c == "i" then
            local s2 = str:sub(i)
            local consumed = s2:match("^(if%s+%d+%s+then)")
            if consumed then
                local num = tonumber(consumed:match("%d+"))
                i = i + #consumed
                ifId = ifId + 1
                local f = curFrame()
                local bound = f and f.curBranch.lastSelect or topLastSelect
                local frame = { id = "if_" .. ifId, boundSelect = bound, branches = {}, curBranch = nil }
                table.insert(frame.branches, { index = num, components = {} })
                frame.curBranch = frame.branches[1]
                table.insert(ifStack, frame)
            else
                i = i + 1
            end
        elseif c == "e" then
            local s2 = str:sub(i)
            local consumed = s2:match("^(elseif%s+%d+%s+then)")
            if consumed then
                local num = tonumber(consumed:match("%d+"))
                i = i + #consumed
                local f = curFrame()
                if f then
                    table.insert(f.branches, { index = num, components = {} })
                    f.curBranch = f.branches[#f.branches]
                end
            elseif s2:match("^else") then
                i = i + 4
                local f = curFrame()
                if f then
                    table.insert(f.branches, { ["else"] = true, components = {} })
                    f.curBranch = f.branches[#f.branches]
                end
            elseif s2:match("^end") then
                i = i + 3
                local f = table.remove(ifStack)
                if f then
                    f.curBranch = nil
                    addComp({ type = "if", id = f.id, boundSelectId = f.boundSelect, branches = f.branches })
                end
            else
                i = i + 1
            end
        elseif c == "(" then
            local j = str:find(")", i, true)
            if j then
                local content = str:sub(i + 1, j - 1)
                i = j + 1
                local safe = content:gsub("、", "\1")
                for item in string.gmatch(safe, "([^\1]+)") do
                    local trimmed = item:match("^%s*(.-)%s*$") or ""
                    if #trimmed >= 1 then
                        table.insert(result.outputTypes, { type = trimmed:sub(1, 1), name = trimmed:sub(2) })
                    end
                end
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end

    -- 容错：base 缺 end 时（非法），将残留 if 帧从内向外输出为组件
    while #ifStack > 0 do
        local f = table.remove(ifStack)
        if f then
            f.curBranch = nil
            addComp({ type = "if", id = f.id, boundSelectId = f.boundSelect, branches = f.branches })
        end
    end

    return result
end

-- 读取 base 型节点某组件的槽值（按编辑器存储优先级回退）
-- 优先级：统一槽 node.data.slots[compId] → 下拉 dropdowns[compId].selectedIndex → 数字槽 numbers[compId].value → data[compId]
-- @param node     table 节点实例（node.data 为槽值存储）
-- @param compType string 组件类型 select/number/funcslot
-- @param compId   string 组件 ID
-- @return any|nil 槽值（select 返回选中索引 number；number 返回数字或 "var:<名>"；funcslot 返回函数名）
function KARDS.NodeParser.GetBaseSlotValue(node, compType, compId)
    if not node or not node.data then return nil end
    local d = node.data
    local slot = d.slots and d.slots[compId]
    if slot then
        if slot.mode == "variable" then return slot.variableRef end
        if slot.literalValue ~= nil then return slot.literalValue end
        return nil
    end
    if compType == "select" then
        local dd = d.dropdowns and d.dropdowns[compId]
        if dd and dd.selectedIndex ~= nil then return dd.selectedIndex end
        local v = d[compId]
        return (type(v) == "number") and v or nil
    elseif compType == "number" then
        local num = d.numbers and d.numbers[compId]
        if num and num.value ~= nil then return num.value end
        return d[compId]
    elseif compType == "funcslot" then
        return d[compId]
    elseif compType == "textslot" then
        return d[compId]
    end
    return nil
end

-- 结构树填充节点数据 → 深拷贝通用操作树
-- @param struct table ParseBaseStructure 输出
-- @param node   table 节点实例（node.data 为槽值存储）
-- @return table 操作树（结构 + 槽值；select 含 selected、number 含 value、funcslot 含 funcName、if 含 boundSelectId 与全部 branches）
function KARDS.NodeParser.FillBaseValues(struct, node)
    local function fillComp(comp)
        local c = { type = comp.type, id = comp.id }
        if comp.type == "select" then
            c.optionsCount = comp.optionsCount
            c.selected = KARDS.NodeParser.GetBaseSlotValue(node, "select", comp.id)
        elseif comp.type == "number" then
            c.optionsCount = comp.optionsCount
            c.useLib = comp.useLib
            c.extraCount = comp.extraCount
            c.value = KARDS.NodeParser.GetBaseSlotValue(node, "number", comp.id)
        elseif comp.type == "funcslot" then
            c.funcName = KARDS.NodeParser.GetBaseSlotValue(node, "funcslot", comp.id)
        elseif comp.type == "textslot" then
            -- 文本槽：值为直接文本 或 "var:<变量名>"（编辑器统一槽优先，扁平键回退）
            c.text = KARDS.NodeParser.GetBaseSlotValue(node, "textslot", comp.id)
        elseif comp.type == "if" then
            c.boundSelectId = comp.boundSelectId
            c.branches = {}
            for _, b in ipairs(comp.branches) do
                local nb = { components = {} }
                if b.index then nb.index = b.index end
                if b["else"] then nb["else"] = true end
                for _, sub in ipairs(b.components) do
                    table.insert(nb.components, fillComp(sub))
                end
                table.insert(c.branches, nb)
            end
        end
        return c
    end
    local out = { inputTypes = {}, outputTypes = {}, components = {} }
    for _, t in ipairs(struct.inputTypes) do table.insert(out.inputTypes, t) end
    for _, o in ipairs(struct.outputTypes) do table.insert(out.outputTypes, { type = o.type, name = o.name }) end
    for _, c in ipairs(struct.components) do table.insert(out.components, fillComp(c)) end
    return out
end

-- 入口：解析 base 型节点 → 通用操作树
-- @param ctx  table 执行上下文（同 ParseSetVariable，EnsureCtx 防御）
-- @param node table 节点实例（node.base = 模板 base 结构串；node.data = 槽值存储）
-- @return table|nil 操作树（结构 + 槽值）；节点缺少 base 时 nil
function KARDS.NodeParser.ParseBaseNode(ctx, node)
    ctx = KARDS.NodeParser.EnsureCtx(ctx)
    if not node or not node.base then
        print("[NodeParser] ParseBaseNode: 节点缺少 base 结构串")
        return nil
    end
    local struct = KARDS.NodeParser.ParseBaseStructure(node.base)
    return KARDS.NodeParser.FillBaseValues(struct, node)
end

-- ====================================================================
-- base 型节点效果执行管线（BaseSemantics 语义表 + ExecuteEffect 分派）
-- ====================================================================
-- 目标：将 base 型模板节点（action / card）的槽值翻译为战斗系统操作，
-- 使节点效果能在真实战斗骨架中生效（区别于 ParseBaseNode 仅做结构解析）。
--
-- 分支解析说明（base 字符串仅含 if 分支序号，不含 config 分支文本）：
--   if 分支序号是「config 内所有 if/elseif/else 块按深度优先顺序的全局计数」
--   （对齐 INE._CompsToBase 的 branchCounter），与绑定的 select 选项值无
--   固定结构映射（如 card 的 select_2 选项 4「开发」对应 if 分支 10，而非 4）。
--   因此执行期不依赖 if 序号反推分支，而是由 BaseSemantics 语义表按
--   select 的「选项值」直接索引分支语义（mainSelect 选项值 → 分支语义，
--   子 select 选项值 → 具体动作），组件槽值一律经 ReadSlot 按组件 ID 读取。
--
-- 槽值存储（对齐编辑器 SaveEffect 与 GetBaseSlotValue）：
--   slots[compId]（统一槽）→ dropdowns[compId].selectedIndex（select）
--   → numbers[compId].value（number）→ data[compId]（select 索引 / number 值 /
--   对象槽引用 / 函数槽名 / 关键字 id）
--   对象槽（e 输入，如交战目标、召唤单位）在真实连线中由数据连接提供；
--   测试场景直接以卡牌句柄写入 node.data[compId]。

-- 模板类型识别：node.name 形如 "action_node"（编辑器注册名），
-- 或 node.templateType / node.type 直接为模板类型
-- @param node table 节点实例
-- @return string|nil 模板类型（"action" / "card" ...）
local function GetTemplateType(node)
    if not node then return nil end
    if node.templateType then return node.templateType end
    if type(node.name) == "string" then
        local t = node.name:match("^(.-)_node$")
        if t then return t end
        return node.name
    end
    if type(node.type) == "string" then
        return node.type
    end
    return nil
end

-- 读取节点槽值（统一槽 → dropdowns → numbers → data 直存）
-- @param node   table 节点实例（node.data 为槽值存储）
-- @param compId string 组件 ID
-- @return any|nil 槽值（select 返回选项索引；number 返回数字/变量引用；对象槽返回卡牌句柄）
local function ReadSlot(node, compId)
    if not node or not node.data or not compId then return nil end
    local d = node.data
    local slot = d.slots and d.slots[compId]
    if slot then
        if slot.mode == "variable" then return slot.variableRef end
        if slot.literalValue ~= nil then return slot.literalValue end
        return nil
    end
    local dd = d.dropdowns and d.dropdowns[compId]
    if dd and dd.selectedIndex ~= nil then return dd.selectedIndex end
    local num = d.numbers and d.numbers[compId]
    if num and num.value ~= nil then return num.value end
    return d[compId]
end

-- 敌方玩家解析（card 模板「敌方」选区用）
-- @param player string 当前玩家标识
-- @return string|nil 敌方玩家标识
local function EnemyOf(player)
    local players = KARDS.Battle and KARDS.Battle.Players or { "P1", "P2" }
    for _, p in ipairs(players) do
        if p ~= player then return p end
    end
    return nil
end

-- 跨文件共享（GLua 无跨文件 local）：acts / hooks / flow 等其它文件经 KARDS.NodeParser 访问
KARDS.NodeParser.GetTemplateType = GetTemplateType
KARDS.NodeParser.ReadSlot = ReadSlot
KARDS.NodeParser.EnemyOf = EnemyOf

-- ====================================================================
-- 入口：base 型节点执行（ExecuteBaseNode）+ 效果执行（ExecuteEffect）
-- ====================================================================

-- 入口：执行 base 型模板节点 → 语义执行器（BaseSemantics 分派）
-- @param ctx     table 执行上下文（同 ParseSetVariable，EnsureCtx 防御）
-- @param card    table 效果发起卡牌句柄（指令卡，决定「友方」阵营）
-- @param targets table 受影响卡牌列表（action 模板的 e 输入对象槽）
-- @param node    table 节点实例（node.base = 模板 base 结构串；node.data = 槽值存储）
-- @return boolean 是否至少成功执行一个语义项
function KARDS.NodeParser.ExecuteBaseNode(ctx, card, targets, node)
    ctx = KARDS.NodeParser.EnsureCtx(ctx)
    local tplType = GetTemplateType(node)
    local sem = tplType and KARDS.NodeParser.BaseSemantics[tplType]
    if not sem then
        print("[NodeParser] ExecuteBaseNode: 无语义表（templateType=" .. tostring(tplType) .. "）")
        return false
    end
    -- 结构校验：base 结构解析失败则无槽值可读（ParseBaseNode 打印缺失 base 告警）
    local tree = KARDS.NodeParser.ParseBaseNode(ctx, node)
    if not tree then return false end
    -- 数据线解析：e 类型数据线（extract/target_selector 输出对象组）注入下游 targets；
    -- 先置当前节点 id，供对象槽「数据线连接的对象」经 ResolveObject 定位 ctx._wireVars
    ctx._currentNodeId = node.id
    targets = KARDS.NodeParser.ResolveEWires(ctx, node, targets or {})
    -- 语义项定位：mainSelect 选中选项值 → 分支语义（loop 特例：无语义分支表，act 直接定义在 sem 上）
    local selIdx = sem.mainSelect and ReadSlot(node, sem.mainSelect)
    local item
    if sem.act then
        item = sem -- loop：{ act = "loop" }
    else
        local branch = (selIdx ~= nil) and sem.branches and sem.branches[selIdx]
        if not branch then
            print("[NodeParser] ExecuteBaseNode: 语义项缺失（mainSelect=" .. tostring(sem.mainSelect) ..
                  " 选中 " .. tostring(selIdx) .. "）")
            return false
        end
        item = branch
        -- 二级分派：分支含 subSelect 时按选中选项值取 items 条目（action「获得/取消」等两级结构）
        if item.subSelect then
            local subSel = ReadSlot(node, item.subSelect)
            item = (subSel ~= nil) and item.items and item.items[subSel] or nil
            if not item then
                print("[NodeParser] ExecuteBaseNode: 语义二级项缺失（subSelect=" .. tostring(branch.subSelect) ..
                      " 选中 " .. tostring(subSel) .. "，template=" .. tostring(tplType) .. "）")
                return false
            end
        end
    end
    -- 分派执行器（各模板执行器表由 sh_node_acts_*.lua / sh_node_hooks.lua 合并进 sem.handlers）
    local handlers = sem.handlers or {}
    local handler = item.act and handlers[item.act]
    if not handler then
        print("[NodeParser] ExecuteBaseNode: 未注册执行器（act=" .. tostring(item.act) ..
              " template=" .. tostring(tplType) .. "）")
        return false
    end
    -- card 模板：第三参为玩家（sideSelect select_1：1 友方 / 2 敌方），其余模板传 targets
    if tplType == "card" then
        local side = ReadSlot(node, sem.sideSelect) or 1
        local owner = (card and card.GetOwner and card:GetOwner()) or "P1"
        local player = (side == 2) and EnemyOf(owner) or owner
        -- 节点一刻（2026-09-27 用户规格：一个节点只能推一刻；指向、循环等纯数据节点不推刻）：
        -- 节点执行期间数据层 Sim* 的推刻合并为一刻（见 sh_ticklog.lua BeginBatch）。
        -- pcall 保证执行器异常时也结束合并，避免后续推刻被永久吞掉
        KARDS.TickLog:BeginBatch(ctx.tableID)
        local ok, res = pcall(handler, ctx, card, player, item, node)
        KARDS.TickLog:EndBatch(ctx.tableID)
        if not ok then error(res, 0) end
        return res
    end
    -- 隐蔽拦截（2026-08-13 用户规格：任何节点上作用到非自身的效果，无法作用到
    -- 隐蔽的单位；除非自身是隐蔽单位就能作用到自身）：targets = 本节点作用目标
    -- （action 模板 e 输入对象槽，含指令/反制/单位效果一切节点路径），过滤掉
    -- 处于隐蔽（Hidden 未揭示）且非效果发起者（自身）的目标——覆盖 readme 7.2.2
    -- 「不受指令/反制/单位效果影响」的统一数据层收口。攻击伤害（SimAttack/SimEngage）
    -- 不走节点执行器，不受此拦截（隐蔽不免疫攻击伤害）。
    -- 反制例证（readme 7.2.2 + 用户规格）：移动触发的反制作用于仍隐蔽的单位被过滤
    -- （「消灭」无效）；攻击触发的反制在单位已揭示（SimAttack 提前 SimReveal）后
    -- 结算 → 正常作用到已揭示的隐蔽单位。
    if #targets > 0 then
        local st = KARDS.Battle and KARDS.Battle.KeywordStates
            and KARDS.Battle.KeywordStates[ctx.tableID]
        if st then
            local filtered = {}
            for _, t in ipairs(targets) do
                if KARDS.KeywordStates.Hidden.Is(st, t) and t ~= card then
                    -- 隐蔽且非自身：本节点效果不作用于该目标（跳过）
                else
                    filtered[#filtered + 1] = t
                end
            end
            targets = filtered
        end
    end
    -- 节点一刻（同 card 分支：一个节点只能推一刻）
    KARDS.TickLog:BeginBatch(ctx.tableID)
    local ok, res = pcall(handler, ctx, card, targets, item, node)
    KARDS.TickLog:EndBatch(ctx.tableID)
    if not ok then error(res, 0) end
    return res
end

-- 入口：执行卡牌效果（节点数组），支持顺序模式与控制流模式
-- 顺序模式（无 connections 连线）：按节点数组保存顺序逐个执行（var_set 解析变量 /
--   var_evaluate 判断 / base 节点经 ExecuteBaseNode 分派语义执行器）；
--   遇到 turn「等待」挂起（node.data._turnPaused）时停止，等待时间刻推进恢复
--   （ResumeTurnNodes → ResumeEffect 从挂起节点后继继续）。
-- 控制流模式（有 connections 连线）：经 ExecuteEffectFlow 沿连线执行
--   （双输出节点按结果分支、跨刻挂起检测，见 sh_effect_flow.lua）。
-- @param ctx         table 执行上下文（含 tableID / initiatorCard / variables / dataConnections / functions / battle / specify）
-- @param card        table 效果发起卡牌句柄（指令卡）
-- @param targets     table 受影响卡牌列表（action 模板的 e 输入对象槽）
-- @param effect      table 效果数据（nodes / connections / variables / dataConnections）
-- @param startNodeId string|nil 指定入口节点 ID（缺省按 entryTitle 匹配或全部入口）
-- @param entryTitle  string|nil 开始点标题（如「部署」「阵亡」；缺省控制流取全部无入边入口）
-- @return boolean 是否至少成功执行一个节点
function KARDS.NodeParser.ExecuteEffect(ctx, card, targets, effect, startNodeId, entryTitle)
    ctx = KARDS.NodeParser.EnsureCtx(ctx)
    if not effect or not effect.nodes or #effect.nodes == 0 then return false end
    -- 顺序模式：无控制流连线时按节点数组顺序执行
    if not effect.connections or #effect.connections == 0 then
        local executed = false
        local nodesById = {}
        for _, node in ipairs(effect.nodes) do
            if node.id ~= nil then nodesById[node.id] = node end
        end
        ctx._nodesById = nodesById -- 供 ResolveEWires 定位上游节点输出（e 数据线注入 targets）
        ctx._currentEffect = effect -- 当前效果数据（turn「等待」挂起时保存，供达标后恢复；与控制流模式一致）
        -- 入口定位：指定 entryTitle 时从匹配开始点起执行（其之前的节点跳过，避免误执行其它开始点链）。
        -- 含开始点的效果若无匹配标题 → 不执行（开始点 = 触发点：触发一个不存在的开始点无意义）；
        -- 无开始点的效果（旧格式/测试的纯节点链）保持从首节点执行，向后兼容。
        local startIndex = 1
        local matchedStart, hasStartPoints = false, false
        if entryTitle then
            for i, node in ipairs(effect.nodes) do
                if node.type == "start" or node.name == "start_point" then
                    hasStartPoints = true
                    if not matchedStart and node.data and node.data.title == entryTitle then
                        startIndex = i
                        matchedStart = true
                    end
                end
            end
            if hasStartPoints and not matchedStart then return false end
        end
        for i = startIndex, #effect.nodes do
            local node = effect.nodes[i]
            -- 链边界：入口开始点之后遇到下一个开始点即停止（顺序模式多开始点隔离——
            -- 触发「部署」不会顺带执行「阵亡」等其它开始点链；控制流模式由连线天然隔离）
            if i > startIndex and (node.type == "start" or node.name == "start_point") then
                break
            end
            local ok = false
            if node.type == "var_set" then
                ok = KARDS.NodeParser.ParseSetVariable(ctx, node)
            elseif node.type == "var_evaluate" then
                -- 判断节点自身不产生效果，结果为事件分支（正式版由事件系统消费）
                KARDS.NodeParser.ParseEvaluateVariable(ctx, node)
                ok = true
            else
                local tplType = GetTemplateType(node)
                if tplType and KARDS.NodeParser.BaseSemantics[tplType] then
                    ok = KARDS.NodeParser.ExecuteBaseNode(ctx, card, targets, node)
                elseif node.type == "start" or node.name == "start_point" then
                    ok = true -- 信号开始点（函数子图「调用」入口）：无语义，仅作为执行起点
                else
                    print("[NodeParser] ExecuteEffect: 跳过未知节点（type=" .. tostring(node.type) ..
                          " name=" .. tostring(node.name) .. "）")
                end
            end
            if ok then executed = true end
            -- 跨刻挂起检测：turn「等待」执行后信号停滞在该节点（效果挂起，等待时间刻推进恢复）
            if node.data and node.data._turnPaused then
                break
            end
        end
        return executed
    end
    -- 控制流模式：沿 connections 连线执行（ExecuteEffectFlow 定义于 sh_effect_flow.lua，
    -- 此处经 KARDS.NodeParser 表访问；加载完成后由 ExecuteEffectFlow 定义处暴露）
    return KARDS.NodeParser.ExecuteEffectFlow(ctx, card, targets, effect, startNodeId, entryTitle)
end
