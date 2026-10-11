--[[
=======================================================================================
独立节点编辑器系统 (Independent Node Editor)
=======================================================================================
一个完全独立的可视化节点编辑器系统，支持创建多个独立实例，每个实例拥有独立的
画布、节点和连接。基于 Garry's Mod HUDPaint 钩子进行2D渲染，支持节点拖拽、
连线、框选、画布平移缩放、导入导出等功能。

模块特性：
  - 多实例支持：可同时创建和管理多个独立的节点编辑器面板
  - 节点注册机制：通过 LogNewNode 注册自定义节点类型
  - 可视化交互：节点拖拽、端口连线、框选多选、右键平移画布
  - 数据序列化：支持 ExportNodeEditorData / ImportNodeEditorData 进行数据导入导出
  - 灵活配置：支持隐藏面板、简化模式、无边框模式、文件菜单等配置项
  - 导入校验：自动检测未注册节点和不属于当前面板的节点并给出警告

公共 API 函数（全局可用）：
  - LogNewNode(nodeParams, nodeName)        注册新的节点类型模板
  - CreateNewNodeEditor(panelID, pos, scale, allowedNodes, hidden, simplified, borderless, showTitleMenu, editorMode, showCoordinates)
                                            创建一个新的节点编辑器实例
  - SetNodeEditorHidden(panelID, hidden)    设置编辑器是否隐藏
  - SetNodeEditorSimplified(panelID, simplified) 设置编辑器是否为简化模式
  - SetNodeEditorBorderless(panelID, borderless) 设置编辑器是否为无边框模式
  - SetNodeEditorShowTitleMenu(panelID, show) 设置编辑器是否显示标题功能菜单
  - SetNodeEditorPosition(panelID, x, y, width, height) 设置编辑器位置和大小
  - SetNodeEditorScale(panelID, scale)      设置编辑器画布缩放比例
  - CloseNodeEditor(panelID)                关闭并销毁编辑器实例
  - GetNodeEditor(panelID)                  获取指定ID的编辑器实例
  - GetActiveNodeEditor()                   获取当前激活的编辑器实例
  - ExportNodeEditorData(panelID)           导出编辑器数据（节点和连接）
  - ImportNodeEditorData(panelID, data)     导入数据到编辑器
  - AddNodeToEditor(panelID, nodeName, x, y) 向编辑器添加节点
  - ClearNodeEditor(panelID)                清空编辑器（重置为初始状态）

=======================================================================================
]]

---@class IndependentNodeEditor 独立节点编辑器核心模块
KARDS.CardEditor.IndependentNodeEditor = KARDS.CardEditor.IndependentNodeEditor or {}
local INE = KARDS.CardEditor.IndependentNodeEditor

-- 已注册的节点类型模板表，键为节点名称，值为节点模板数据
INE.RegisteredNodes = INE.RegisteredNodes or {}

-- 所有活跃的编辑器实例表，键为panelID，值为编辑器对象
INE.Editors = INE.Editors or {}

-- 当前激活（最后创建/操作）的编辑器ID
INE.ActiveEditorID = nil

-- 是否已添加HUDPaint和Think钩子的标记
INE.HookAdded = false

-- HandleInput 函数桩（由 cl_ine_input_handling.lua 覆盖为完整实现）
-- 用于处理各编辑器实例的文件菜单、变量对话框、右键菜单等交互输入
-- 如果该文件未加载，此桩函数可防止 Think 崩溃，并提供基本的文件菜单交互
function INE:HandleInput(editor)
    -- 桩实现：仅处理文件菜单按钮切换，确保按钮可点击
    if not (editor and editor._fileBtnRect) then return end
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local btnX, btnY, btnW, btnH = editor._fileBtnRect.x, editor._fileBtnRect.y, editor._fileBtnRect.w, editor._fileBtnRect.h
    if mouseX >= btnX and mouseX <= btnX + btnW and mouseY >= btnY and mouseY <= btnY + btnH then
        if input.IsMouseDown(MOUSE_LEFT) and not editor._fileMenuClicked then
            editor._fileMenuClicked = true
            editor.fileMenuOpen = not editor.fileMenuOpen
        end
        if not input.IsMouseDown(MOUSE_LEFT) then
            editor._fileMenuClicked = false
        end
    end
end

-- 变量搜索输入框状态（DTextEntry IME 兼容方案）
INE.VarSearchState = {
    active = false,
    text = "",
    editorID = nil,
    typeId = nil,
    x = 0, y = 0, w = 0, h = 0,
}
INE.VarSearchTextEntry = nil

-- 数字变量对话框输入框状态（DTextEntry IME 兼容方案）
INE.NumVarFieldState = {
    active = false,     -- 是否正在编辑某个字段
    field = nil,        -- "name" / "iname" / "val"
    editorID = nil,
    varIdx = nil,
    x = 0, y = 0, w = 0, h = 0,
}
INE.NumVarTextEntry = nil

-- 函数变量对话框输入框状态（DTextEntry IME 兼容方案）
INE.FuncVarFieldState = {
    active = false,     -- 是否正在编辑函数名称
    text = "",
    editorID = nil,
    varIdx = nil,
    x = 0, y = 0, w = 0, h = 0,
}
INE.FuncVarTextEntry = nil

-- 函数变量对话框参数添加输入框状态（DTextEntry IME 兼容方案）
INE.FuncParamFieldState = {
    active = false,     -- 是否正在输入参数名
    text = "",
    editorID = nil,
    varIdx = nil,
    x = 0, y = 0, w = 0, h = 0,
}
INE.FuncParamTextEntry = nil

-- 数组变量对话框输入框状态（DTextEntry IME 兼容方案）
INE.ArrayVarFieldState = {
    active = false,     -- 是否正在编辑某个字段
    field = nil,        -- "name" / "iname" / "val_n" / "val_t"
    editorID = nil,
    varIdx = nil,
    x = 0, y = 0, w = 0, h = 0,
}
INE.ArrayVarTextEntry = nil

-- 卡牌对象变量对话框输入框状态（DTextEntry IME 兼容方案）
INE.CardVarFieldState = {
    active = false,     -- 是否正在编辑某个字段
    field = nil,        -- "name" / "iname"
    editorID = nil,
    varIdx = nil,
    x = 0, y = 0, w = 0, h = 0,
}
INE.CardVarTextEntry = nil

-- 字符串变量对话框输入框状态（DTextEntry IME 兼容方案）
INE.StringVarFieldState = {
    active = false,     -- 是否正在编辑某个字段
    field = nil,        -- "name" / "iname" / "text"
    editorID = nil,
    varIdx = nil,
    x = 0, y = 0, w = 0, h = 0,
}
INE.StringVarTextEntry = nil

-- 布尔值变量对话框输入框状态（DTextEntry IME 兼容方案）
INE.BoolVarFieldState = {
    active = false,     -- 是否正在编辑某个字段
    field = nil,        -- "name" / "iname"
    editorID = nil,
    varIdx = nil,
    x = 0, y = 0, w = 0, h = 0,
}
INE.BoolVarTextEntry = nil

-- 文本槽内联输入状态（2026-10-04 新增，DTextEntry IME 兼容方案）
-- 「抉择」等模板的 <> 文本槽：直接输入模式下点击值区进入内联编辑，
-- 编辑结果写回 node.data.slots[compId].literalValue 与扁平 data[compId]。
INE.TextSlotEditState = {
    active = false,     -- 是否正在编辑某个文本槽
    node = nil,         -- 所属节点
    compId = nil,       -- 文本槽组件 ID（textslot_N）
    text = "",          -- 当前输入文本（OnTextChanged 同步）
    x = 0, y = 0, w = 0, h = 0,  -- 值区屏幕坐标（绘制时更新，供 DTextEntry 定位）
}
INE.TextSlotTextEntry = nil

-- 数组变量对话框待添加项状态
INE.ArrayVarPendingType = nil  -- 当前选择的类型，nil表示未在选择状态
INE.ArrayVarItemValue = nil    -- 临时值文本
-- 数组变量嵌套创建上下文（f/g类型呼出嵌套对话框时使用）
INE.ArrayVarNestedCtx = nil   -- { parentEditor, parentVarIdx, tempType, tempVarIdx, savedDialogIdx, savedIsNew }

-- 各编辑器模式下自动创建的开始点定义
-- 键为模式名称，值为按 y 轴顺序排列的开始点标题数组
INE.StartNodeDefinitions = {
    unit = {"抽取", "部署", "在场", "升级", "阵亡", "移除", "弃牌", "钳击", "钳击对象"},
    command = {"抽取", "打出", "弃牌"},
    counter_command = {"抽取", "激活时", "弃牌"},
    headquarter = {"在场", "受到伤害", "防御变化"},
    ["function"] = {"调用"}
}

-- 节点模板配置
-- 每个模板定义节点类型、名称、颜色、输入输出端口、适用模式和配置字符串
--
-- config DSL 语法说明（支持换行，换行符在解析时被替换为空格）：
--   语法元素：
--     '固定文本'          → 文本组件（单引号包裹，照原样显示）
--     {选项A、选项B}      → 下拉选择组件（中文顿号分隔）
--     {$选项$、选项A}     → 卡牌对象模式选择（首尾加 $ 的首选项触发，
--                            界面显示红色 e 按钮 + 卡牌对象选择器）
--     []                  → 数字输入组件
--     [选项A、选项B]      → 数字槽选择（带固定选项）
--     [lib]               → 数字槽选择（接入 VarLib 数字变量库）
--     [lib+选项A、选项B]   → 数字槽选择（VarLib + 额外固定选项）
--     (t输出名)           → 输出端口（小括号包裹，前缀数据类型的首字母）
--                           支持多输出：(n攻击力、n防御力)2
--     if 条件 then ... elseif 条件 then ... else ... end
--                         → 条件分支（基于前一个选择组件的选中值切换显示）
--   数据类型前缀（config 字符串开头）：
--     e{n选项}  → 卡牌对象输入
--     n{选项}   → 数字输入
--     p{选项}   → 布尔值输入
--     t{选项}   → 字符串输入
--     无前缀     → 无输入端口
--
-- 模板项中的其它字段：
--   type      → 节点类型标识符（用于序列化/反序列化）
--   name      → 节点在界面中显示的名称
--   color     → 节点背景色
--   hasInput  → 是否有输入端口（连线流入）
--   hasOutput → 是否有输出端口（连线流出）
--   config    → DSL 配置字符串，定义节点的 UI 组件布局、输入输出端口和分支逻辑
--   输入/输出端口数据类型：n=数字, p=布尔值, t=字符串, g=数组, e=卡牌对象, f=节点函数
--[[
    从 data/kards/node_templates/ 加载所有节点模板 JSON 文件。
    
    初始化步骤：
    1. 确保本地 data/kards/node_templates/ 目录存在（玩家自定义副本）
    2. 从 data 文件系统读取所有 JSON 模板（addon data_static/ 只读默认 + 本地
       data/ 副本覆盖，DATA 模式自动合并、本地优先）
    3. 根据当前游戏语言选择对应的 name 和 config
    4. 调用 LogNewNode 注册每个有效节点
    5. 报告错误（JSON 解析错误、缺少字段、DSL 解析错误）
    
    （2026-08-14：模板源由 lua/node_templates/ 移入 data_static/kards/node_templates/
    ——gmad 打包白名单拒绝 lua/ 下非 .lua 文件，移动后才可打包分发）
]]
function INE:LoadNodeTemplatesFromFiles()
    -- 模板源文件随 addon 只读分发（data_static/kards/node_templates/）；本地
    -- data/kards/node_templates/ 为玩家自定义副本（覆盖 addon 默认，file.Write
    -- 可直接修改）。DATA 模式 file.Find/Read 自动合并两者、本地副本优先——修改
    -- addon 模板后重开编辑器或 kards_reload_templates 即可生效（配置未变化的
    -- 模板静默跳过，配置变化的覆盖重新注册）。
    
    -- 确保本地 data/kards/node_templates/ 目录存在（供玩家自定义副本写入）
    file.CreateDir("kards/node_templates")
    
    -- 从 data 文件系统读取所有 JSON 模板（addon data_static/ + 本地 data/ 合并，本地优先）
    local dataFiles = file.Find("kards/node_templates/*.json", "DATA")
    if not dataFiles or #dataFiles == 0 then
        print("[INE] 警告: 未在 data 目录（addon data_static 或本地 data）找到任何节点模板 JSON 文件")
        return {}
    end
    
    local registered = {}
    local errors = {}
    
    print("[INE] 节点模板来源: data 目录（" .. #dataFiles .. " 个文件）")
    -- 获取当前游戏语言
    local lang = GetConVarString("gmod_language") or "zh-CN"
    
    for _, fileName in ipairs(dataFiles) do
        local ok, result = pcall(function()
            local content = file.Read("kards/node_templates/" .. fileName, "DATA")
            if not content then
                error("无法读取文件")
            end
            
            local tpl = util.JSONToTable(content)
            if not tpl then
                error("JSON 解析失败")
            end
            
            -- 验证必填字段
            if not tpl.type then error("缺少 type 字段") end
            if not tpl.color or #tpl.color < 3 then
                error("缺少或无效的 color 字段（需要 [r, g, b] 数组）")
            end
            if tpl.hasInput == nil then error("缺少 hasInput 字段") end
            if tpl.hasOutput == nil then error("缺少 hasOutput 字段") end
            if not tpl.names then error("缺少 names 字段（多语言名称对象）") end
            if not tpl.configs then error("缺少 configs 字段（多语言配置对象）") end
            
            -- 根据当前语言选择 name
            local nodeDisplayName = tpl.names[lang] or tpl.names["zh-CN"]
            if not nodeDisplayName then
                for _, v in pairs(tpl.names) do
                    nodeDisplayName = v
                    break
                end
            end
            
            -- 根据当前语言选择 config
            local configStr = tpl.configs[lang] or tpl.configs["zh-CN"]
            if not configStr then
                for _, v in pairs(tpl.configs) do
                    configStr = v
                    break
                end
            end
            
            -- 验证 config DSL 是否能被正确解析
    if configStr and configStr ~= "" then
        local parseResult = INE.ParseConfig(configStr)
        if not parseResult or not parseResult.components then
            error("config DSL 解析失败: 无法生成有效的组件列表")
        end
        
        -- 自动生成 base（AUTO:lang 模式）
        local baseToValidate = tpl.base
        -- AUTO base 由 config 自动生成，结构与 config 一致，无需再执行验证
        if baseToValidate and baseToValidate:match("^AUTO:") then
            local autoLang = baseToValidate:match("^AUTO:(.+)$")
            local autoConfig = tpl.configs[autoLang] or tpl.configs["zh-CN"]
            if autoConfig then
                local generatedBase = INE.GenerateBaseFromConfig(autoConfig)
                print("[INE] AUTO base for " .. tpl.type .. ".json (" .. (autoLang or "zh-CN") .. "): " .. generatedBase)
                -- 跳过验证（AUTO base 由 config 生成，结构必然匹配）
                baseToValidate = nil
            end
        end
        
        -- 验证手动编写的 base 是否遵循 config 结构
        if baseToValidate and baseToValidate ~= "" then
            local ok, err = INE:ValidateConfigAgainstBase(configStr, baseToValidate)
            if not ok then
                error("config 不遵循 base 结构: " .. tostring(err))
            end
        end
    end
    
            -- 生成节点注册名称
            local nodeRegName = tpl.type .. "_node"
            
            -- 已注册且配置未变化：静默跳过（不报错，避免重复加载噪音）
            local existingTpl = INE.RegisteredNodes[nodeRegName]
            if existingTpl and existingTpl._configSource == configStr then
                return nodeRegName
            end
            
            -- 调用 LogNewNode 注册节点（已注册但配置变化的会直接覆盖更新）
            LogNewNode({
                type = tpl.type,
                name = nodeDisplayName,
                color = Color(tpl.color[1], tpl.color[2], tpl.color[3]),
                hasInput = tpl.hasInput,
                hasOutput = tpl.hasOutput,
                hasSecondOutput = tpl.hasSecondOutput or false,
                outputLabels = tpl.outputLabels,
                config = configStr,
            }, nodeRegName)
            
            -- 记录本次注册使用的 config，用于下次加载时的变化检测
            INE.RegisteredNodes[nodeRegName]._configSource = configStr
            
            -- 记录模板 base（保存端 ExportEditorToFile 写 node.base 用；
            -- 无 base 或 AUTO: 前缀的模板保存时由 config 自动生成）
            INE.RegisteredNodes[nodeRegName]._templateBase = tpl.base
            
            return nodeRegName
        end)
        
        if ok then
            table.insert(registered, result)
            print("[INE] 成功注册节点模板: " .. fileName .. " → " .. result)
        else
            table.insert(errors, fileName .. ": " .. tostring(result))
            print("[INE] 错误: " .. fileName .. " - " .. tostring(result))
        end
    end
    
    -- 如果有错误，在控制台输出汇总
    if #errors > 0 then
        print("[INE] ======== 节点模板加载错误汇总 ========")
        for _, err in ipairs(errors) do
            print("[INE]   ✗ " .. err)
        end
        print("[INE] ====================================")
        
        -- 尝试显示游戏内通知
        local notifOk, notifErr = pcall(function()
            if KARDS and KARDS.CardEditor and KARDS.CardEditor.Canvas
               and KARDS.CardEditor.Canvas.AddNotification then
                KARDS.CardEditor.Canvas.AddNotification(
                    #errors .. " 个节点模板加载失败（详情见控制台）",
                    Color(200, 50, 50), false
                )
            end
        end)
        if not notifOk then
            print("[INE] 显示游戏内通知失败: " .. tostring(notifErr))
        end
    end
    
    return registered
end

--[[
    验证 config DSL 是否遵循 base 结构骨架。
    在初始化时调用，检测 config 与 base 的组件结构是否一致。
    
    @param  configStr   {string}    DSL 配置字符串
    @param  baseStr     {string}    Base 结构字符串（单行，不含文本组件）
    @return {boolean, string}       成功返回 true，失败返回 false 和错误描述
]]
function INE:ValidateConfigAgainstBase(configStr, baseStr)
    if not baseStr or baseStr == "" then return true end
    
    local configResult = INE.ParseConfig(configStr)
    local baseResult = INE.ParseConfig(baseStr)
    
    if not configResult or not configResult.components then
        return false, "config 解析失败"
    end
    if not baseResult or not baseResult.components then
        return false, "base 解析失败"
    end
    
    local ok, err = INE:_CompareComponentLists(configResult.components, baseResult.components)
    if not ok then
        return false, err
    end
    
    return true
end

--[[
    递归比较两个组件列表的结构一致性。
    从 config 组件列表中过滤掉 text 类型，然后逐位置与 base 比较。
    支持 select/number/if 各类型的深度比较。
]]
function INE:_CompareComponentLists(configComps, baseComps)
    -- 过滤掉 config 中的 text 组件
    local filtered = {}
    for _, comp in ipairs(configComps) do
        if comp.type ~= "text" then
            table.insert(filtered, comp)
        end
    end
    
    if #filtered ~= #baseComps then
        return false, string.format("组件数量不匹配: config 有 %d 个非文本组件, base 有 %d 个", #filtered, #baseComps)
    end
    
    for i = 1, #filtered do
        local cComp = filtered[i]
        local bComp = baseComps[i]
        
        if cComp.type ~= bComp.type then
            return false, string.format("位置 %d 组件类型不匹配: config 是 '%s', base 是 '%s'", i, cComp.type, bComp.type)
        end
        
        if cComp.type == "select" then
            -- base select 格式：{N} 或 {N,M}
            -- config 的选项数应等于 N
            -- 跳过 {@section} 引用的选项数检查（选项数由词汇表动态决定）
            if not cComp._sectionRef then
                local bOpts = bComp.options or {}
                local bCount = tonumber(bOpts[1]) or 0
                local cCount = #(cComp.options or {})
                if bCount ~= cCount then
                    return false, string.format("位置 %d 选择组件选项数不匹配: config 有 %d 个选项, base 登记 %d 个", i, cCount, bCount)
                end
            end
            
        elseif cComp.type == "number" then
            local bOpts = bComp.options or {}
            
            if #bOpts == 0 and not bComp.useLib then
                -- base 无内容 = 空槽 [0]
                if cComp.useLib or (cComp.options and #cComp.options > 0) then
                    return false, string.format("位置 %d 数字组件: base 为空槽, 但 config 不为空", i)
                end
            elseif bComp.useLib then
                -- base [lib] 或 [lib+N]
                if not cComp.useLib then
                    return false, string.format("位置 %d 数字组件: base 为 [lib], 但 config 不是", i)
                end
                local bExtraOptions = bComp.extraOptions or {}
                local cExtraCount = #(cComp.extraOptions or {})
                local bExpectedCount
                -- 如果 base [lib+N] 中的 N 是单个数字，将其解析为选项数量而非文字选项
                if #bExtraOptions == 1 then
                    local numVal = tonumber(bExtraOptions[1])
                    if numVal then
                        bExpectedCount = numVal
                    end
                end
                if not bExpectedCount then
                    bExpectedCount = #bExtraOptions
                end
                if bExpectedCount ~= cExtraCount then
                    return false, string.format("位置 %d 数字组件: base 附加选项数 %d, config 为 %d", i, bExpectedCount, cExtraCount)
                end
            else
                -- base [N] = 带 N 个预设选项的数字槽
                local bCount = tonumber(bOpts[1]) or 0
                if bCount == 0 then
                    -- base [0] 应为空槽
                    if cComp.useLib or (cComp.options and #cComp.options > 0) then
                        return false, string.format("位置 %d 数字组件: base 是空槽 [0], 但 config 不为空", i)
                    end
                else
                    -- base [N] 选项数对比
                    local cCount = #(cComp.options or {})
                    if bCount ~= cCount then
                        return false, string.format("位置 %d 数字组件: base 登记 %d 个选项, config 有 %d 个", i, bCount, cCount)
                    end
                end
            end
            
        elseif cComp.type == "if" then
            local cBranches = cComp.branches or {}
            local bBranches = bComp.branches or {}
            if #cBranches ~= #bBranches then
                return false, string.format("位置 %d 条件分支数量不匹配: config 有 %d 个分支, base 有 %d 个", i, #cBranches, #bBranches)
            end
            for j = 1, #cBranches do
                local ok, err = INE:_CompareComponentLists(cBranches[j].components or {}, bBranches[j].components or {})
                if not ok then
                    return false, string.format("位置 %d 分支 %d: %s", i, j, err)
                end
            end
        end
    end
    
    return true
end

--[[
    从 config DSL 自动生成 base 结构字符串。
    用于 AUTO:zh-CN / AUTO:en 模式：在模板加载时自动生成 base 并输出到控制台，
    用户可将生成的 base 复制到 JSON 文件中以固化结构。
]]
function INE.GenerateBaseFromConfig(configStr)
    if not configStr or configStr == "" then return "" end
    
    local result = INE.ParseConfig(configStr)
    if not result or not result.components then return configStr end
    
    local base = ""
    
    -- 添加输入类型标识符（n/p/t/g/e/f）
    for _, it in ipairs(result.inputTypes or {}) do
        base = base .. it.id
    end
    
    -- 处理组件树
    local branchCounter = {value = 0}
    base = base .. INE._CompsToBase(result.components, branchCounter)
    
    -- 添加输出类型 (nName、tName)
    if result.outputTypes and #result.outputTypes > 0 then
        base = base .. "("
        local parts = {}
        for _, ot in ipairs(result.outputTypes) do
            table.insert(parts, ot.id .. ot.name)
        end
        base = base .. table.concat(parts, "、")
        base = base .. ")"
    end
    
    return base
end

-- 递归将组件列表转换为 base 字符串
function INE._CompsToBase(components, branchCounter)
    local function ensureSpc(s)
        if #s > 0 and s:sub(-1) ~= " " then return s .. " " end
        return s
    end
    
    local base = ""
    for _, comp in ipairs(components) do
        if comp.type == "text" then
            -- 省略文本组件（_CompareComponentLists 会过滤 config 中的文本）
        elseif comp.type == "select" then
            if comp._sectionRef then
                base = base .. "{1}"
            else
                base = base .. "{" .. #(comp.options or {}) .. "}"
            end
        elseif comp.type == "number" then
            if comp.useLib then
                local extraCount = #(comp.extraOptions or {})
                if extraCount > 0 then
                    base = base .. "[lib+" .. extraCount .. "]"
                else
                    base = base .. "[lib]"
                end
            else
                local optCount = #(comp.options or {})
                base = base .. "[" .. optCount .. "]"
            end
        elseif comp.type == "textslot" then
            -- 文本槽：每个槽一个 <>（结构标记，不含文本内容；内容存 node.data）
            base = base .. "<>"
        elseif comp.type == "funcslot" then
            base = base .. "#"
        elseif comp.type == "if" then
            local branches = comp.branches or {}
            for j, branch in ipairs(branches) do
                branchCounter.value = branchCounter.value + 1
                if j == 1 then
                    base = ensureSpc(base) .. "if " .. branchCounter.value .. " then "
                elseif branch.condition == "else" then
                    base = ensureSpc(base) .. "else "
                else
                    base = ensureSpc(base) .. "elseif " .. branchCounter.value .. " then "
                end
                local branchBase = INE._CompsToBase(branch.components or {}, branchCounter)
                base = base .. branchBase
                if branchBase ~= "" then
                    base = base .. " "
                end
            end
            base = base .. "end"
        end
    end
    return base:gsub("%s+$", "")
end

--[[
    构建节点运行时数据（保存端键迁移，修复编辑器/运行时组件 ID 计数不一致）。

    背景：编辑器 INE.ParseConfig 对 text/select/number/if 使用「全组件混合计数」
    （id = select_4 / number_9，text 组件也占位递增），而运行时
    KARDS.NodeParser.ParseBaseStructure 按类型独立计数（select_1 / number_1，
    base 串不含 text）。当 config 含文本组件时两者键错位——同一槽位的保存键与
    运行时读取键不同（如血红镰刀 target_selector 的 select_4=3「场上」被运行时
    误读为类别 select_4=3「总部」）。本函数在保存端把节点 data 迁移为运行时键
    （runtimeData），服务端 LoadEffectForRuntime 直接应用；编辑器加载（LoadEffect）
    保持原 data 不受影响。

    配对策略：config 与 base 结构并行（模板加载时 ValidateConfigAgainstBase 保证），
    采用「分支感知锁定步进」——两棵组件树同步遍历，text 仅存在于 config 侧（跳过），
    if 处按「最近前置 select 的选中值」匹配 config 分支条件，只深入被选中分支。
    编辑器 if/elseif 各分支共享同一批组件 id（如 card 节点各分支的 number_4/select_6
    从同一 componentId 重新计数），若按全局位置配对会因重复 id 错位到其它分支的
    运行时槽位，故必须按分支选中态对齐。未被选中的分支（含嵌套组件）不配对、
    其数据不迁移，运行时使用默认值。

    组件来源权威性（每组件只保留一种表示，避免陈旧 slots 值污染运行时）：
      select: slots(mode=variable) → dropdowns.selectedIndex → slots → 扁平
      number: numbers.value → slots(mode=variable) → slots → 扁平
      funcslot: 扁平
    编辑器数字框实时写 numbers[compId].value，而 slots 可能滞后（节点创建时写入默认
    literalValue=0，之后 SyncNumberSlotToSlotData 仅同步 mode 不同步值），
    故 numbers/dropdowns 优先于字面量 slots。

    @param config string|nil 节点 config DSL（编辑器组件定义）
    @param base   string|nil 节点模板 base 结构串（缺失时由 config 自动生成）
    @param data   table 编辑器节点数据（node.data）
    @return table runtimeData（组件键已按运行时键迁移；非组件键原样拷贝）
]]
function INE.BuildRuntimeData(config, base, data)
    local rd = {}
    if not data then return rd end
    if not config or config == "" then
        -- 无 config（开始点/数据源等）：无组件键可迁移，原样拷贝
        for k, v in pairs(data) do rd[k] = v end
        return rd
    end

    -- 1. 解析 config 与 base 组件树（结构并行，base 缺失时由 config 派生）
    local configRes = INE.ParseConfig(config)
    local baseStr = base
    if not baseStr or baseStr == "" then
        baseStr = INE.GenerateBaseFromConfig(config)
    end
    local baseRes = KARDS.NodeParser.ParseBaseStructure(baseStr)

    -- 2. 分支感知锁定步进：编辑器组件 id → 运行时组件 id
    local idMap = {}

    -- 读取 select 组件的选中值文本（分支条件判定用；对象槽为扁平字符串直取）
    local function selectValueText(comp)
        local id = comp.id
        local dd = data.dropdowns and data.dropdowns[id]
        if dd and dd.selectedIndex ~= nil then
            local opts = (dd.options and #dd.options > 0) and dd.options or comp.options
            return opts and opts[dd.selectedIndex]
        end
        local v = data[id]
        if type(v) == "number" then
            return comp.options and comp.options[v]
        end
        return v
    end

    -- 注：if input={...}/if output={...} 条件依赖节点连接上下文，保存时无法判定，
    -- ConditionMatches 传 nil context 返回 false，该分支按未选中处理（当前模板未使用）
    local function walk(cList, bList, lastVal)
        local ci, bi = 1, 1
        while ci <= #cList and bi <= #bList do
            local cc, bc = cList[ci], bList[bi]
            if cc.type == "text" then
                ci = ci + 1 -- base 无 text，仅推进 config 侧
            elseif cc.type == "if" then
                local chosen = nil
                if bc.type == "if" then
                    -- 用进入 if 前的最近 select 选中值匹配 config 分支条件（else 恒匹配）
                    for i2, br in ipairs(cc.branches or {}) do
                        if br.condition == "else" or INE.ConditionMatches(br.condition, lastVal, nil) then
                            chosen = i2
                            break
                        end
                    end
                end
                if chosen and bc.branches and bc.branches[chosen] then
                    walk(cc.branches[chosen].components or {}, bc.branches[chosen].components or {}, lastVal)
                end
                ci, bi = ci + 1, bi + 1
            elseif cc.type == "select" then
                idMap[cc.id] = bc.id
                lastVal = selectValueText(cc) -- 更新最近 select 选中值（供后续 if 判定）
                ci, bi = ci + 1, bi + 1
            elseif cc.type == "number" or cc.type == "funcslot" then
                idMap[cc.id] = bc.id
                ci, bi = ci + 1, bi + 1
            elseif cc.type == "textslot" then
                -- 文本槽（2026-10-04 新增）：base 侧同位置一个 textslot 组件，直接配对
                -- （必须显式映射，否则落入下方 else 只推进不映射 → 文本值在 runtimeData 丢失）
                idMap[cc.id] = bc.id
                ci, bi = ci + 1, bi + 1
            else
                ci, bi = ci + 1, bi + 1
            end
        end
    end
    walk(configRes.components or {}, baseRes.components or {}, nil)

    -- 3. 收集所有组件 id（扁平键 + 子表键）
    local compIds = {}
    local function markId(k)
        if type(k) == "string" then
            local id = k:match("^(select_%d+)$") or k:match("^(number_%d+)$") or k:match("^(funcslot_%d+)$") or k:match("^(textslot_%d+)$")
            if id then compIds[id] = true end
        end
    end
    for k in pairs(data) do markId(k) end
    for _, sub in ipairs({ "dropdowns", "numbers", "slots" }) do
        if type(data[sub]) == "table" then
            for k in pairs(data[sub]) do markId(k) end
        end
    end

    -- 4. 按权威来源写入 runtimeData；仅迁移配对成功的组件
    --    （未配对 = 未被选中分支的遗留组件，不迁移，运行时用默认值）
    for compId in pairs(compIds) do
        local newId = idMap[compId]
        if newId then
            local compType = compId:match("^([a-z]+)")
            local slot = data.slots and data.slots[compId]
            local slotEssential
            if slot and slot.mode == "variable" then
                slotEssential = { mode = "variable", variableRef = slot.variableRef, type = slot.type }
            elseif slot then
                slotEssential = { mode = "literal", literalValue = slot.literalValue, type = slot.type }
            end
            if compType == "select" then
                local dd = data.dropdowns and data.dropdowns[compId]
                if dd and dd.selectedIndex ~= nil then
                    rd.dropdowns = rd.dropdowns or {}
                    rd.dropdowns[newId] = { selectedIndex = dd.selectedIndex }
                elseif slotEssential then
                    rd.slots = rd.slots or {}
                    rd.slots[newId] = slotEssential
                elseif data[compId] ~= nil then
                    rd[newId] = data[compId]
                end
            elseif compType == "number" then
                local num = data.numbers and data.numbers[compId]
                if num and num.value ~= nil then
                    rd.numbers = rd.numbers or {}
                    rd.numbers[newId] = { value = num.value, mode = num.mode }
                elseif slotEssential then
                    rd.slots = rd.slots or {}
                    rd.slots[newId] = slotEssential
                elseif data[compId] ~= nil then
                    rd[newId] = data[compId]
                end
            elseif compType == "textslot" then
                -- 文本槽（2026-10-04 新增）：统一槽优先（literalValue 直接文本 / variableRef "var:<名>"），
                -- 其次扁平键 data[compId]；运行时 ReadSlot 按同一优先级读取
                if slotEssential then
                    rd.slots = rd.slots or {}
                    rd.slots[newId] = slotEssential
                elseif data[compId] ~= nil then
                    rd[newId] = data[compId]
                end
            else -- funcslot
                if data[compId] ~= nil then
                    rd[newId] = data[compId]
                end
            end
        end
    end

    -- 5. 非组件键原样拷贝（title / 数据线输出名「选中的卡牌」/ _setEntries 等）
    --    dropdowns/numbers/slots 是组件存储子表，组件键已由步骤 4 全量处理，不再拷贝
    for k, v in pairs(data) do
        local isCompKey = type(k) == "string"
            and (k:match("^select_%d+$") or k:match("^number_%d+$") or k:match("^funcslot_%d+$") or k:match("^textslot_%d+$"))
        if not isCompKey then
            if k ~= "dropdowns" and k ~= "numbers" and k ~= "slots" then
                rd[k] = v
            end
        end
    end

    return rd
end

-- 全局节点ID自增计数器，用于生成唯一节点ID
INE.NodeIDCounter = 0

-- 全局连接ID自增计数器，用于生成唯一连接ID
INE.ConnectionIDCounter = 0

-- 缩放系统配置
-- 固定缩放步进值：1.05 = 21/20，是有理数、非循环小数、正数
INE.ZOOM_STEP = 1.05
INE.ZOOM_MIN = 0.1
INE.ZOOM_MAX = 5.0

-- 滚轮缩放标记（CreateMove 中设值，Think 中消费）
INE._wheelZoomIn = false
INE._wheelZoomOut = false

-- 筛选面板滚轮标记（CreateMove 中设值，HUDPaint 中消费）
INE._filterWheelUp = false
INE._filterWheelDown = false

-- 矩阵层级定义
-- worldSize: 网格间距（世界坐标单位）
-- minScale/maxScale: 可见缩放范围，超出范围不绘制（即"销毁"）
INE.GRID_LAYERS = {
    { worldSize = 100, minScale = 0.1,  maxScale = 0.6 },   -- 粗矩阵：缩小时显现
    { worldSize = 20,  minScale = 0.15, maxScale = 3.5 },   -- 默认矩阵：始终可见
    { worldSize = 5,   minScale = 1.5,  maxScale = 5.0 },   -- 细矩阵：放大时显现
}

-- 可用字体尺寸列表（需与 sh_fonts.lua 注册的尺寸一致）
INE.AVAILABLE_FONT_SIZES = {2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 40, 44, 48, 52, 56, 60, 64, 68, 72}

-- 矩阵颜色（固定）挂载到 INE 命名空间，供子系统文件访问
INE.GRID_COLORS = {
    [100] = Color(80, 80, 90),
    [20]  = Color(45, 45, 50),
    [5]   = Color(60, 60, 75),
}

--[[
    根据缩放比例计算指定矩阵层级的透明度。

    透明度随缩放值平滑变化：
    - 粗矩阵（100px）：缩放小于 0.6 时显现，越接近 0.1 越明显
    - 默认矩阵（20px）：缩放为 1.0 时最明显，向两端递减
    - 细矩阵（5px）：  缩放大于 1.5 时显现，越接近 5.0 越明显

    @param  worldSize {number} 矩阵间距
    @param  scale     {number} 当前画布缩放比例
    @return {number}  透明度值（0 表示不绘制/销毁）
]]
function CalculateGridAlpha(worldSize, scale)
    if worldSize == 100 then
        if scale >= 0.6 then return 0 end
        local t = (0.6 - scale) / (0.6 - 0.1)
        return math.floor(80 * math.min(1, math.max(0, t)))
    elseif worldSize == 20 then
        if scale < 0.15 or scale > 3.5 then return 0 end
        local ratio
        if scale > 1.0 then
            ratio = (3.5 - scale) / (3.5 - 1.0)
        else
            ratio = (scale - 0.15) / (1.0 - 0.15)
        end
        return math.floor(120 * math.max(0, math.min(1, ratio)))
    elseif worldSize == 5 then
        if scale <= 1.5 then return 0 end
        local t = (scale - 1.5) / (5.0 - 1.5)
        return math.floor(100 * math.min(1, math.max(0, t)))
    end
    return 0
end

--[[
    根据缩放比例获取最接近的可用字体标识符。
    用于在缩放时动态选择合适字号，使文字视觉大小随缩放同步变化。

    @param  fontPrefix {string}  字体前缀，如 "SourceHan_Heavy"
    @param  baseSize   {number}  基准字体大小（缩放为 1.0 时使用的字号）
    @param  scale      {number}  当前画布缩放比例
    @return {string}  字体标识符，如 "SourceHan_Heavy_28"
]]
function INE:GetScaledFont(fontPrefix, baseSize, scale)
    local targetSize = math.floor(baseSize * scale + 0.5)
    targetSize = math.max(targetSize, INE.AVAILABLE_FONT_SIZES[1])

    local bestSize = INE.AVAILABLE_FONT_SIZES[1]
    local minDiff = math.abs(bestSize - targetSize)
    for _, size in ipairs(INE.AVAILABLE_FONT_SIZES) do
        local diff = math.abs(size - targetSize)
        if diff < minDiff then
            minDiff = diff
            bestSize = size
        end
    end
    return fontPrefix .. "_" .. bestSize
end

-- 背景图片相关配置（每个编辑器面板独立使用）
INE.BackgroundImageFolder = "materials/kards/editor_backgrounds/"
INE.BackgroundImageList = {}

--[[
    动态检测背景图片数量。
    扫描默认 editor_background.png 和 editor_backgrounds 文件夹中的序列命名图片。
]]
function INE:ScanBackgroundImages()
    INE.BackgroundImageList = {}
    
    -- 首先添加默认的editor_background.png作为备选
    local defaultPath = "materials/kards/editor_background.png"
    local defaultMat = Material(defaultPath, "noclamp smooth")
    if defaultMat and not defaultMat:IsError() then
        table.insert(INE.BackgroundImageList, defaultPath)
    end
    
    -- 扫描editor_backgrounds文件夹中的背景图片
    local i = 1
    while true do
        local bgPathPng = INE.BackgroundImageFolder .. "editor_background_" .. i .. ".png"
        local bgMatPng = Material(bgPathPng, "noclamp smooth")
        if bgMatPng and not bgMatPng:IsError() then
            table.insert(INE.BackgroundImageList, bgPathPng)
            i = i + 1
        else
            local bgPathJpg = INE.BackgroundImageFolder .. "editor_background_" .. i .. ".jpg"
            local bgMatJpg = Material(bgPathJpg, "noclamp smooth")
            if bgMatJpg and not bgMatJpg:IsError() then
                table.insert(INE.BackgroundImageList, bgPathJpg)
                i = i + 1
            else
                break
            end
        end
    end
    
    return INE.BackgroundImageList
end

--[[
    为指定编辑器随机选择一张背景图片。
    不同编辑器会随机选到不同的背景。
]]
function INE:SelectRandomBackground(editor)
    if #INE.BackgroundImageList == 0 then
        INE:ScanBackgroundImages()
    end
    
    if #INE.BackgroundImageList > 0 then
        local index = math.random(1, #INE.BackgroundImageList)
        editor.selectedBackgroundImage = INE.BackgroundImageList[index]
    end
end

-- 数据类型定义（用于端口类型标识和绘制）
INE.DataTypes = {
    NUMBER = {
        id = "n",
        name = "数字",
        color = Color(255, 165, 0),
        shape = "circle"
    },
    BOOLEAN = {
        id = "p",
        name = "布尔值",
        color = Color(135, 206, 250),
        shape = "triangle"
    },
    STRING = {
        id = "t",
        name = "字符串",
        color = Color(144, 238, 144),
        shape = "hollow_circle"
    },
    ARRAY = {
        id = "g",
        name = "数组",
        color = Color(255, 255, 0),
        shape = "hollow_square"
    },
    CARD_OBJECT = {
        id = "e",
        name = "卡牌对象",
        color = Color(220, 100, 80),
        shape = "hexagon"
    },
    FUNCTION = {
        id = "f",
        name = "节点函数",
        color = Color(200, 150, 255),
        shape = "diamond"
    }
}

--[[
    绘制多选下拉框
    横竖均匀布局，固定选项宽度，选择后不关闭，已选选项显示浅绿色文字和高亮背景。
    
    @param  editor          {table}  编辑器实例对象
    @param  x               {number} 下拉框左上角 X 坐标
    @param  y               {number} 下拉框左上角 Y 坐标
    @param  options         {table}  选项列表，每项包含 {id, name, color, shape}
    @param  selectedIndices {table}  已选选项的索引集合（key-value 形式，如 {[1]=true, [3]=true}）
    @param  callback        {function} 选择回调 function(optionIndex, isSelected)
    @param  scale           {number} 缩放比例（可选，默认为 1）
    @return {table} 下拉框的矩形信息 {x, y, w, h}
]]
function INE:DrawMultiSelectDropdown(editor, x, y, options, selectedIndices, callback, scale)
    scale = scale or 1
    selectedIndices = selectedIndices or {}
    
    local optCount = #options
    -- 根据选项数量动态调整列数（最多3列，至少1列）
    local columns = math.min(3, math.max(1, optCount))
    if columns == 0 then return {x = x, y = y, w = 0, h = 0} end
    
    -- 固定选项宽度和高度
    local optionW = 180 * scale
    local optionH = 28 * scale
    local padding = 8 * scale
    local iconSize = 12 * scale
    
    local rows = math.ceil(optCount / columns)
    
    local totalW = columns * optionW + (columns - 1) * padding
    local totalH = rows * optionH + (rows - 1) * padding
    
    -- 绘制背景
    draw.RoundedBox(4, x, y, totalW, totalH, Color(40, 40, 50, 240))
    
    -- 获取鼠标位置
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    -- 检测是否刚按下左键（用于单击检测，避免按住时反复触发）
    local justPressed = input.IsMouseDown(MOUSE_LEFT) and not editor._dataPortClickProcessed
    
    -- 绘制每个选项
    for i, option in ipairs(options) do
        local col = (i - 1) % columns
        local row = math.floor((i - 1) / columns)
        
        local optX = x + col * (optionW + padding)
        local optY = y + row * (optionH + padding)
        
        local isSelected = selectedIndices[i]
        local isHovered = mouseX >= optX and mouseX <= optX + optionW and
                         mouseY >= optY and mouseY <= optY + optionH
        
        -- 绘制选项背景
        if isSelected then
            local bgColor = isHovered and Color(80, 120, 80, 200) or Color(60, 100, 60, 180)
            draw.RoundedBox(3, optX, optY, optionW, optionH, bgColor)
        elseif isHovered then
            draw.RoundedBox(3, optX, optY, optionW, optionH, Color(70, 70, 80, 200))
        end
        
        -- 绘制选项文字
        local textColor = isSelected and Color(144, 238, 144) or Color(220, 220, 220)
        local textX = optX + 8 * scale
        local textY = optY + optionH / 2
        local optFont = self:GetScaledFont("SourceHan_Heavy", 14, scale)
        draw.SimpleText(option.name, optFont, textX, textY, textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        
        -- 绘制数据类型图标（在选项右侧）
        local iconX = optX + optionW - iconSize - 8 * scale
        local iconY = optY + optionH / 2
        INE.DrawDataTypeIcon(option, iconX, iconY, iconSize)
        
        -- 单击检测：只在鼠标刚刚按下时触发一次
        if isHovered and justPressed then
            if callback then
                callback(i, not isSelected)
            end
            editor._dataPortClickProcessed = true
        end
    end
    
    return {x = x, y = y, w = totalW, h = totalH}
end

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
                    print("[INE] 警告: @section 引用 '" .. sectionId .. "' 无法展开（RulesVocabulary 未加载）")
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
                    comp.objectLabel = "选择对象"
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

-- 获取文本宽度
function INE.GetTextWidth(text, font)
    font = font or "SourceHan_Heavy_14"
    surface.SetFont(font)
    local w, _ = surface.GetTextSize(text)
    return w
end

-- 调试开关：控制台输入 ine_node_debug 1 启用宽度计算调试输出
local ineNodeDebug = CreateConVar("kards_ine_node_debug", "0", {FCVAR_ARCHIVE})
local function dbgPrint(...)
    if ineNodeDebug:GetBool() then
        print(...)
    end
end

-- 计算组件尺寸
function INE.CalculateSize(components, nodeData, hasSecondOutput, editor, nodeId)
    local padding = 20
    local minWidth = 200
    local minHeight = 80
    
    local maxX = padding
    local selectIndex = 0
    local callDepth = 0
    
    -- 节点输入/输出连接上下文（供 if input/output 条件判断，整棵树共享）
    local ioCtx = INE.GetNodeIOContext(INE, editor, nodeId)
    
    local function processCompList(compList, data)
        callDepth = callDepth + 1
        local depth = callDepth
        local cx = padding
        local mx = maxX
        
        for _, comp in ipairs(compList) do
            if comp.type == "text" then
                local w = INE.GetTextWidth(comp.text)
                cx = cx + w + 5
                mx = math.max(mx, cx)
                dbgPrint("[DBG:WIDTH:" .. depth .. "] text id=" .. tostring(comp.id or "?") .. " text=" .. tostring(comp.text) .. " w=" .. tostring(w) .. " cx=" .. tostring(cx))
            elseif comp.type == "select" then
                selectIndex = selectIndex + 1
                if comp.cardObjectMode then
                    local charW = INE.GetTextWidth("字")
                    local rawVal = data and data[comp.id]
                    -- 判断是否处于"指定"模式（与 DrawComponents 中的 isCardMode 逻辑一致）
                    local isCardMode = comp.pureObjectMode
                    if not isCardMode then
                        if rawVal and type(rawVal) == "string" then
                            isCardMode = true
                        elseif rawVal == nil or rawVal == 1 then
                            isCardMode = true
                        end
                    end
                    if isCardMode then
                        -- 指定模式/纯对象模式：e 按钮宽度
                        local displayText
                        if rawVal and type(rawVal) == "string" then
                            displayText = rawVal
                        else
                            displayText = comp.objectLabel or comp.options[1]
                        end
                        if displayText and displayText:sub(1,1) == "$" and displayText:sub(-1,-1) == "$" and #displayText >= 2 then
                            displayText = displayText:sub(2, -2)
                        end
                        if comp.pureObjectMode and (not rawVal or (type(rawVal) ~= "string" or rawVal == "")) and displayText == "" then
                            displayText = "选择对象"
                        end
                        local textW = INE.GetTextWidth(displayText)
                        local w = charW * 1.5 + charW * 0.5 + textW + charW * 2  -- eBtn + sep + text + arrow
                        cx = cx + w + 5
                        mx = math.max(mx, cx)
                    else
                        -- 非指定模式：正常下拉框宽度
                        local selectedText
                        if rawVal and type(rawVal) == "number" then
                            selectedText = comp.options[rawVal] or comp.options[1]
                        else
                            selectedText = comp.options[1]
                        end
                        if data and data.dropdowns and data.dropdowns[comp.id] and data.dropdowns[comp.id].selectedIndex then
                            local dropdownIdx = data.dropdowns[comp.id].selectedIndex
                            selectedText = comp.options[dropdownIdx] or selectedText
                        end
                        local w = INE.GetTextWidth(selectedText) + charW * 3
                        cx = cx + w + 5
                        mx = math.max(mx, cx)
                    end
                    dbgPrint("[DBG:WIDTH:" .. depth .. "] select id=" .. tostring(comp.id or "?") .. " sel=" .. tostring(selectedText or "?") .. " w=" .. tostring(w) .. " cx=" .. tostring(cx))
                else
                    -- 普通下拉框：选项文本宽度 + 下拉箭头留白（与 DrawComponents 普通模式公式一致）
                    local charW = INE.GetTextWidth("字")
                    local selectedText
                    if data and type(data[comp.id]) == "number" then
                        selectedText = comp.options[data[comp.id]] or comp.options[1]
                    else
                        selectedText = comp.options[1]
                    end
                    local w = INE.GetTextWidth(selectedText) + charW * 3
                    cx = cx + w + 5
                    mx = math.max(mx, cx)
                    dbgPrint("[DBG:WIDTH:" .. depth .. "] select id=" .. tostring(comp.id or "?") .. " sel=" .. tostring(selectedText or "?") .. " w=" .. tostring(w) .. " cx=" .. tostring(cx))
                end
            elseif comp.type == "number" then
                -- 数字槽：宽度由 DrawNumberBox 自行计算，此处使用保守估算
                local charW = INE.GetTextWidth("字")
                local w
                -- 单选模式（select/变量）：宽度按选中项显示名自适应
                -- （公式与 DrawNumberBox select 模式一致：n 按钮 + 分隔符 + 下拉框，见 cl_ca_ui_components.lua L294-316）
                local numData = nodeData and nodeData.numbers and nodeData.numbers[comp.id]
                if numData and numData.mode == "select" and editor then
                    -- 构建选项列表（[lib] 时从 VarLib/数据线/用户变量收集，与 DrawComponents L1971-2013 一致）
                    local options = comp.options or {}
                    if comp.useLib then
                        options = {}
                        if KARDS.VarLib and KARDS.VarLib.GetNumericVarPaths then
                            for _, varPath in ipairs(KARDS.VarLib.GetNumericVarPaths("1")) do
                                table.insert(options, varPath)
                            end
                        end
                        if comp.extraOptions then
                            for _, extraOpt in ipairs(comp.extraOptions) do
                                table.insert(options, extraOpt)
                            end
                        end
                    end
                    if editor.dataConnections then
                        for _, dc in ipairs(editor.dataConnections) do
                            if dc.toNode == nodeId and dc.dataType == "n" and dc.variableName then
                                local exists = false
                                for _, opt in ipairs(options) do
                                    if opt == dc.variableName then exists = true break end
                                end
                                if not exists then table.insert(options, dc.variableName) end
                            end
                        end
                    end
                    if editor.variables and editor.variables["n"] then
                        for _, userVar in ipairs(editor.variables["n"]) do
                            local varName = (userVar.internalName ~= nil and userVar.internalName ~= "") and userVar.internalName or userVar.name
                            if varName then
                                local exists = false
                                for _, opt in ipairs(options) do
                                    if opt == varName then exists = true break end
                                end
                                if not exists then table.insert(options, varName) end
                            end
                        end
                    end
                    local selectedIdx = numData.selectedOptionIndex or 1
                    -- 空选项兜底：VarLib 无数字变量且无数据线/用户变量时 options 为空表，
                    -- selectedOpt 为 nil 会导致 GetDisplayName(nil) 返回 nil 传入 GetTextWidth 崩溃
                    local selectedOpt = options[selectedIdx] or options[1] or ""
                    local displayOpt = selectedOpt
                    if KARDS.VarLib and KARDS.VarLib.GetDisplayName then
                        displayOpt = KARDS.VarLib.GetDisplayName(selectedOpt)
                    end
                    local selectedTextW = INE.GetTextWidth(displayOpt)
                    local nBtnW = charW * 1.5
                    local sepW = charW * 0.5
                    local dropDownW = math.max(selectedTextW + 24, math.max(charW * 4, 20))
                    w = nBtnW + sepW + dropDownW
                else
                    w = charW * 1.5 + charW * 0.5 + math.max(charW * 4, 20)
                end
                cx = cx + w + 5
                mx = math.max(mx, cx)
            elseif comp.type == "funcslot" then
                -- 函数槽：内联宽度计算
                local charW = INE.GetTextWidth("字")
                local fBtnW = charW * 1.5
                local sepW = charW * 0.5
                local totalPrefixW = fBtnW + sepW
                local funcName = data and data[comp.id] or "选择函数"
                if not funcName or funcName == "" then funcName = "选择函数" end
                local textW = INE.GetTextWidth(funcName)
                if textW < charW * 4 then textW = charW * 4 end
                local dropDownW = math.max(textW + 24, 20)
                local w = totalPrefixW + dropDownW
                cx = cx + w + 5
                mx = math.max(mx, cx)
            elseif comp.type == "textslot" then
                -- 文本槽：绿色 t 按钮 + 间隔 + 值区（直接输入文本 / "var:<名>" 引用显示变量名）
                -- 公式与 DrawComponents 的 textslot 分支保持一致（未缩放估算）
                local charW = INE.GetTextWidth("字")
                local tCharW = math.max(14, charW * 1.4)
                local rawVal = data and data[comp.id]
                local disp = ""
                if type(rawVal) == "string" then
                    disp = (rawVal:sub(1, 4) == "var:") and rawVal:sub(5) or rawVal
                end
                local textW = math.max(INE.GetTextWidth(disp), INE.GetTextWidth("文本"))
                local w = tCharW + 4 + textW + 4
                cx = cx + w + 5
                mx = math.max(mx, cx)
            elseif comp.type == "if" then
                local selectedValue = nil
                for idx = #compList, 1, -1 do
                    local c = compList[idx]
                    if c.type == "select" then
                        local dataKey = c.id
                        if data and data[dataKey] then
                            selectedValue = c.options[data[dataKey]] or c.options[1]
                        else
                            selectedValue = c.options[1]
                        end
                        break
                    end
                end
                
                for _, branch in ipairs(comp.branches) do
                    local cond = branch.condition
                    local matches = INE.ConditionMatches(cond, selectedValue, ioCtx)
                    
                    if matches then
                        -- 递归处理分支组件，processCompList 返回分支的最终 cx
                        -- （包含 padding + 所有组件的宽度 + 间距）
                        local branchCx = processCompList(branch.components, data)
                        -- 分支净宽度 = 分支最终 cx - padding（减去分支自身的起始 padding）
                        local branchW = branchCx - padding
                        cx = cx + branchW
                        mx = math.max(mx, cx)
                        dbgPrint("[DBG:WIDTH:" .. depth .. "] if id=" .. tostring(comp.id or "?") .. " branchCx=" .. tostring(branchCx) .. " branchW=" .. tostring(branchW) .. " cx=" .. tostring(cx))
                        break
                    end
                end
            end
        end
        
        maxX = math.max(maxX, mx)
        return cx
    end
    
    processCompList(components, nodeData)
    
    -- 双分支输出点增加额外宽度（"满足"/"不满足"标签绘制在节点内部右侧，
    -- 见 DrawNodePorts hasSecondOutput 分支：TEXT_ALIGN_RIGHT 对齐到输出端口左侧）。
    -- 额外宽度按最宽标签（"不满足"）的实际文本宽度测量 + 标签间距 + 端口半径 + 余量，
    -- 不使用固定值，避免内容较短的节点右侧出现大段空白。
    local dualExtra = 0
    if hasSecondOutput then
        local labelFont = INE:GetScaledFont("SourceHan_Heavy", 11, 1)
        local labelW = INE.GetTextWidth("不满足", labelFont)
        dualExtra = math.max(labelW + 4 + 6 + 4, 40)  -- 标签文本 + 标签间距(4) + 端口半径(6) + 余量(4)
    end
    local width = math.max(minWidth, maxX + padding + dualExtra)
    local height = minHeight
    dbgPrint("[DBG:WIDTH:" .. callDepth .. "] final: maxX=" .. tostring(maxX) .. " padding=" .. tostring(padding) .. " dual=" .. tostring(hasSecondOutput) .. " w=" .. tostring(width) .. " h=" .. tostring(height))
    
    return width, height
end

-- 初始化节点数据
function INE.InitNodeData(components, nodeData)
    nodeData = nodeData or {}
    local selectIndex = 0
    
    local function processCompList(compList, data)
        for _, comp in ipairs(compList) do
            if comp.type == "select" then
                selectIndex = selectIndex + 1
                if not data[comp.id] then
                    data[comp.id] = 1
                end
            elseif comp.type == "number" then
                if not data[comp.id] then
                    data[comp.id] = 0
                end
            elseif comp.type == "textslot" then
                if not data[comp.id] then
                    data[comp.id] = ""  -- 文本槽：直接输入文本 或 "var:<变量名>" 引用
                end
            elseif comp.type == "funcslot" then
                if not data[comp.id] then
                    data[comp.id] = ""  -- 函数引用名
                end
            elseif comp.type == "if" then
                for _, branch in ipairs(comp.branches) do
                    processCompList(branch.components, data)
                end
            end
        end
    end
    
    processCompList(components, nodeData)
    return nodeData
end

--[[
    绘制节点的配置内容（文本、下拉选项、数字输入等DSL组件）。
    当节点有 parsedConfig 时自动调用，渲染所有 DSL 组件到节点内容区域。
    
    @param  editor  {table}   编辑器实例对象
    @param  node    {table}   节点实例
]]
function INE:DrawNodeContent(editor, node)
    if node.isStartNode then return end
    if not node.parsedConfig or not node.parsedConfig.components then return end
    if #node.parsedConfig.components == 0 then return end

    local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
    local scale = editor.canvasScale

    -- 节点内容区域：标题栏下方 30px * scale，左边距 20px * scale
    local startX = nodeX + 20 * scale
    local startY = nodeY + 40 * scale

    self:DrawComponents(editor, node, startX, startY, node.parsedConfig.components, node.data)
end

--[[
    收集文本槽可引用的文本变量显示名（2026-10-04 新增）：
      1. 编辑器全局文本变量 editor.variables["t"]
      2. 连接到本节点的 t 类型数据线（变量名）
    与「设置变量」节点文本槽的 GetTextVarOptions（cl_ine_var_op_nodes.lua）语义一致，去重。
    @param  editor {table} 编辑器实例
    @param  node   {table} 节点实例
    @return {table} 显示名数组
]]
function INE.GetTextSlotVarOptions(editor, node)
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
            -- 显示名口径与 VarOp.GetVarDisplayName / 运行时 ResolveTarget（FindUserVar 按显示名匹配）
            -- 一致：优先 name，其次 internalName
            local disp = (v.name ~= nil and v.name ~= "") and v.name or v.internalName
            AddOpt(disp)
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

--[[
    绘制组件列表（text、select、number、if 分支），在节点内部区域流式布局。
    递归处理 if 分支，根据当前选项值匹配对应分支并渲染。
    
    @param  editor      {table}   编辑器实例对象
    @param  node        {table}   节点实例
    @param  startX      {number}  绘制起始X坐标（屏幕空间）
    @param  startY      {number}  绘制起始Y坐标（屏幕空间）
    @param  components  {table}   DSL 解析后的组件列表
    @param  nodeData    {table}   节点数据表（持久化组件状态）
]]
function INE:DrawComponents(editor, node, startX, startY, components, nodeData)
    local x = startX
    local y = startY
    local scale = editor.canvasScale
    local spacing = 5 * scale
    local compH = 20 * scale  -- 组件高度基准，随缩放变化
    local selectIndices = {}
    local currentSelectIdx = 0

    -- 节点输入/输出连接上下文（供 if input/output 条件判断，整棵树共享）
    local ioCtx = self:GetNodeIOContext(editor, node.id)

    -- 使用缩放后的字体测量文本宽度
    local function getScaledTextWidth(text, fontPrefix, baseSize)
        local fontName = INE:GetScaledFont(fontPrefix, baseSize, scale)
        surface.SetFont(fontName)
        local w, _ = surface.GetTextSize(text)
        return w
    end

    local function processCompList(compList, data)
        local cx = x
        local cy = y

        local compFont = INE:GetScaledFont("SourceHan_Heavy", 14, editor.canvasScale)
        for _, comp in ipairs(compList) do
            if comp.type == "text" then
                -- 固定文本组件：绘制描述性文本，垂直居中于 compH 行高
                draw.SimpleText(comp.text, compFont, cx, cy + compH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local w = getScaledTextWidth(comp.text, "SourceHan_Heavy", 14)
                cx = cx + w + spacing
            elseif comp.type == "select" then
                -- 下拉选项组件：绘制可交互下拉框
                currentSelectIdx = currentSelectIdx + 1
                table.insert(selectIndices, comp)
                if comp.cardObjectMode then
                    -- =======================================================
                    -- 卡牌对象模式（{$} 或 {$指定$、...}）
                    -- =======================================================
                    local charW = getScaledTextWidth("字", "SourceHan_Heavy", 14)
                    local rawVal = data[comp.id]
                    -- 判断当前是否处于"指定"模式（显示 e 按钮 + 卡牌对象选择）
                    -- 条件：纯对象模式 或 选了 $指定$ 选项(索引1) 或 已通过 CardObjectSelector 选择了卡牌名称(字符串)
                    local isCardMode = comp.pureObjectMode
                    if not isCardMode then
                        if rawVal and type(rawVal) == "string" then
                            isCardMode = true  -- 已选择卡牌对象
                        elseif rawVal == nil or rawVal == 1 then
                            isCardMode = true  -- 默认第一个选项是 $指定$
                        end
                    end
                    -- 在混合模式下，若当前不在指定模式，使用 DrawDropdown 绘制普通下拉框
                    if not isCardMode then
                        local selectedIdx = (type(rawVal) == "number" and rawVal) or 1
                        local selectedText = comp.options[selectedIdx] or comp.options[1]
                        local w = getScaledTextWidth(selectedText, "SourceHan_Heavy", 14) + charW * 3
                        local newIdx = KARDS.CardEditor.Canvas.DrawDropdown(cx, cy, w, compH, comp.options, selectedIdx,
                            node, comp.id, nil, nil, compFont, editor.canvasScale)
                        if newIdx then data[comp.id] = newIdx end
                        table.insert(editor._interactiveRects, {x = cx, y = cy, w = w, h = compH,
                            nodeId = node.id, compId = comp.id, type = "select"})
                        local expandedKey = node.id .. "_" .. comp.id
                        if KARDS.CardEditor.Canvas.ExpandedDropdown == expandedKey then
                            local expInfo = KARDS.CardEditor.Canvas.ExpandedDropdownInfo
                            if expInfo and expInfo.dropdownX then
                                table.insert(editor._interactiveRects, {
                                    x = expInfo.dropdownX, y = expInfo.dropdownY,
                                    w = expInfo.totalWidth, h = expInfo.dropdownH or 100,
                                    nodeId = node.id, compId = comp.id, type = "select_expanded"
                                })
                            end
                        end
                        cx = cx + w + spacing
                    else
                    -- 指定模式或纯对象模式：e 按钮 + | + 对象名称 + ▼
                    -- 确定显示文本
                    local displayText
                    if rawVal and type(rawVal) == "string" then
                        displayText = rawVal  -- 从 CardObjectSelector 选择的卡牌名称
                    else
                        displayText = comp.objectLabel or comp.options[1]
                    end
                    -- 去除 $...$ 包裹符号
                    if displayText and displayText:sub(1,1) == "$" and displayText:sub(-1,-1) == "$" and #displayText >= 2 then
                        displayText = displayText:sub(2, -2)
                    end
                    -- 若纯对象模式且未选择，显示"选择对象"
                    if comp.pureObjectMode and (not rawVal or (type(rawVal) ~= "string" or rawVal == "")) and displayText == "" then
                        displayText = "选择对象"
                    end
                    local textW = getScaledTextWidth(displayText, "SourceHan_Heavy", 14)
                    local eBtnW = charW * 1.5
                    local sepW = charW * 0.5
                    local totalW = eBtnW + sepW + textW + charW * 2
                    local eBtnX = cx
                    local eBtnY = cy
                    -- 获取鼠标位置
                    local mX, mY = gui.MouseX(), gui.MouseY()
                    local isEHit = mX >= eBtnX and mX <= eBtnX + eBtnW and mY >= eBtnY and mY <= eBtnY + compH
                    local sepX = eBtnX + eBtnW + sepW
                    local textEndX = eBtnX + totalW
                    local isTextHit = mX >= sepX and mX <= textEndX and mY >= eBtnY and mY <= eBtnY + compH
                    -- 绘制整体背景（统一深色底色）
                    draw.RoundedBox(4, eBtnX, eBtnY, totalW, compH, Color(60, 60, 60))
                    -- 绘制 e 按钮（红色文字，悬停时背景变亮）
                    local eBtnColor = isEHit and Color(55, 55, 55) or Color(35, 35, 35)
                    draw.RoundedBox(3 * scale, eBtnX, eBtnY, eBtnW, compH, eBtnColor)
                    draw.SimpleText("e", compFont, eBtnX + eBtnW / 2, eBtnY + compH / 2, Color(220, 60, 60), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    -- 分隔符 |
                    draw.SimpleText("|", compFont, sepX, eBtnY + compH / 2, Color(120, 120, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    -- 卡牌名称
                    draw.SimpleText(displayText, compFont, sepX + sepW, eBtnY + compH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    -- 下拉箭头 ▼
                    draw.SimpleText("▼", compFont, textEndX - charW * 0.7, eBtnY + compH / 2, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    -- 点击检测：使用 DrawAllEditors 在 HUDPaint 开始时统一采样的鼠标状态
                    local mouseJustPressed = INE._frameMouseJustPressed or false
                    if mouseJustPressed and not KARDS.CardEditor.Canvas.DraggingNode then
                        -- 点击 e 按钮：打开 CardObjectSelector（纯对象模式下点击任意区域也打开）
                        local shouldOpenSelector = isEHit or (comp.pureObjectMode and isTextHit)
                        if shouldOpenSelector and not KARDS.CardEditor.Canvas.CardObjectSelector then
                            local popupW = charW * 30
                            local popupX = cx
                            local popupY = cy + compH + 2
                            if popupX + popupW > ScrW() then
                                popupX = ScrW() - popupW - 10
                            end
                            -- 收集选项数据
                            local opts = {}
                            -- 1. 已保存卡牌
                            if KARDS.CardEditor.SaveSystem and KARDS.CardEditor.SaveSystem.GetAllCardsInfo then
                                local savedCards = KARDS.CardEditor.SaveSystem.GetAllCardsInfo()
                                for _, cardInfo in ipairs(savedCards or {}) do
                                    table.insert(opts, {label = cardInfo.name, type = "saved_card",
                                        cardFile = cardInfo.fileName, cardName = cardInfo.name,
                                        cardAppearance = cardInfo.cardAppearance})
                                end
                            end
                            -- 2. 卡牌对象变量
                            if editor.variables and editor.variables["e"] then
                                for _, var in ipairs(editor.variables["e"]) do
                                    local varName = (var.name ~= nil and var.name ~= "") and var.name or var.internalName or ""
                                    table.insert(opts, {label = varName, type = "variable",
                                        variableName = varName, cardFile = var.cardFile,
                                        cardName = var.cardName, cardAppearance = var.cardAppearance})
                                end
                            end
                            -- 3. 数据连接传入的对象变量
                            --    （isWire=true：数据线连接的对象始终显示，不受「包括全局」开关控制；
                            --      与 VarLib 全局对象变量（isLibVar）区分，见 DrawCardObjectSelector 过滤）
                            if editor.dataConnections then
                                for _, dc in ipairs(editor.dataConnections) do
                                    if dc.toNode == node.id and dc.dataType == "e" and dc.variableName then
                                        table.insert(opts, {label = dc.variableName, type = "connection",
                                            variableName = dc.variableName, fromNodeId = dc.fromNode,
                                            fromPortIndex = dc.fromPortIndex, isWire = true})
                                    end
                                end
                            end
                            -- 4. 当前卡牌（内置对象变量）
                            local ccAppearance = KARDS.CardEditor.Canvas.CardAppearance
                            local ccName = (ccAppearance and ccAppearance.name) or "新卡牌"
                            table.insert(opts, {label = "当前卡牌：" .. ccName, type = "variable",
                                variableName = ccName, cardName = ccName, cardAppearance = ccAppearance,
                                isCurrentCard = true})
                            -- 5. VarLib 全局对象/对象组变量（e 单个对象 + eg 对象组）
                            --    基于 GetObjectVarPaths 白名单（总部/目标为 e，Units/Cards 为 eg，含开发池），
                            --    与 CollectLibVarsByType 按默认值推断不同——总部等默认 nil 的变量在白名单下正确归为 e
                            local objVars = {}
                            if KARDS.VarLib and KARDS.VarLib.GetObjectVarPaths then
                                objVars = KARDS.VarLib.GetObjectVarPaths("__ine_template__" .. editor.id)
                            end
                            for _, ov in ipairs(objVars) do
                                local display = ov.path
                                if KARDS.VarLib.GetDisplayName then
                                    local dn = KARDS.VarLib.GetDisplayName(ov.path)
                                    if dn and dn ~= "" then display = dn end
                                end
                                table.insert(opts, {label = display, type = "connection",
                                    variableName = ov.path, isLibVar = true, isGroup = ov.isGroup})
                            end
                            KARDS.CardEditor.Canvas.CardObjectSelector = {
                                nodeId = node.id, compId = comp.id, nodeRef = node,
                                x = popupX, y = popupY, searchText = "", page = 1, searchActive = false,
                                options = opts, filterExpanded = false,
                                filterFaction = nil, filterLocation = nil,
                                filterType = nil, filterKeyword = nil,
                            }
                        elseif isTextHit and not comp.pureObjectMode and not KARDS.CardEditor.Canvas.CardObjectSelector then
                            -- 点击文本区域（混合模式）：打开普通下拉选择
                            local currentTime = SysTime()
                            if not node.data.dropdowns then node.data.dropdowns = {} end
                            if not node.data.dropdowns[comp.id] then
                                node.data.dropdowns[comp.id] = {selectedIndex = data[comp.id] or 1, lastClickTime = 0, options = comp.options}
                            end
                            local ddData = node.data.dropdowns[comp.id]
                            ddData.options = comp.options
                            if currentTime - ddData.lastClickTime > 0.3 then
                                if KARDS.CardEditor.Canvas.ExpandedDropdown == (node.id .. "_" .. comp.id) then
                                    KARDS.CardEditor.Canvas.ExpandedDropdown = nil
                                    KARDS.CardEditor.Canvas.ExpandedDropdownInfo = nil
                                else
                                    KARDS.CardEditor.Canvas.ExpandedDropdown = node.id .. "_" .. comp.id
                                    local ddStyle = KARDS.CardEditor.Canvas.DropdownStyle
                                    local screenH = ScrH()
                                    local ddY = cy + compH + 2
                                    local maxRows = math.floor((screenH - ddY - ddStyle.padding * 2) / (ddStyle.rowHeight))
                                    maxRows = math.max(1, maxRows)
                                    local optFont = compFont or "SourceHan_Heavy_14"
                                    surface.SetFont(optFont)
                                    local maxOptW = 0
                                    for _, opt in ipairs(comp.options) do
                                        local tw = surface.GetTextSize(opt)
                                        maxOptW = math.max(maxOptW, tw)
                                    end
                                    local colW = math.max(maxOptW + 22, totalW)
                                    local numCols = math.ceil(#comp.options / maxRows)
                                    local totalDropW = numCols * colW
                                    local dropX = cx
                                    if dropX + totalDropW > ScrW() then
                                        dropX = cx - (numCols - 1) * colW
                                        if dropX < 0 then dropX = 0 end
                                    end
                                    local dropH = numCols == 1 and (#comp.options * ddStyle.rowHeight + ddStyle.padding * 2) or (maxRows * ddStyle.rowHeight + ddStyle.padding * 2)
                                    KARDS.CardEditor.Canvas.ExpandedDropdownInfo = {
                                        x = cx, y = cy, width = totalW, height = compH,
                                        nodeId = node.id, dropdownId = comp.id,
                                        options = comp.options,
                                        dropdownX = dropX, dropdownY = ddY,
                                        totalWidth = totalDropW, expandedColumnWidth = colW,
                                        maxRowsPerColumn = maxRows, dropdownH = dropH,
                                        numColumns = numCols, dropdownData = ddData,
                                        optFont = optFont, canvasScale = editor.canvasScale or 1,
                                    }
                                end
                                ddData.lastClickTime = currentTime
                            end
                        end
                    end
                    -- 当混合模式的普通下拉选中项改变时，同步回 data[comp.id]
                    -- 注意：当 data[comp.id] 为字符串（由 CardObjectSelector 设置）时，不覆盖
                    if not comp.pureObjectMode then
                        if type(data[comp.id]) ~= "string" then
                            local ddKey = node.id .. "_" .. comp.id
                            if KARDS.CardEditor.Canvas.ExpandedDropdown ~= ddKey then
                                -- 检查 dropdownData 中是否有更新
                                local ddData = node.data.dropdowns and node.data.dropdowns[comp.id]
                                if ddData and ddData.selectedIndex then
                                    local newIdx = ddData.selectedIndex
                                    if newIdx ~= data[comp.id] then
                                        data[comp.id] = newIdx
                                    end
                                end
                            end
                        end
                    end
                    -- 记录交互包围盒
                    table.insert(editor._interactiveRects, {x = eBtnX, y = eBtnY, w = eBtnW, h = compH,
                        nodeId = node.id, compId = comp.id, type = "select_e_button"})
                    table.insert(editor._interactiveRects, {x = sepX, y = eBtnY, w = totalW - eBtnW, h = compH,
                        nodeId = node.id, compId = comp.id, type = "select_text_area"})
                    -- 悬停时绘制卡牌预览
                    local isHoverOverComponent = mX >= eBtnX and mX <= eBtnX + totalW and mY >= eBtnY and mY <= eBtnY + compH
                    if isHoverOverComponent and not KARDS.CardEditor.Canvas.CardObjectSelector then
                        local cardAppearance = data[comp.id .. "_appearance"]
                        if cardAppearance then
                            local refH = math.floor((KARDS.CardEditor.Canvas.TotalEditorH or 720) / 3)
                            local previewH = refH
                            local previewW = math.floor(previewH * 3 / 4)
                            local previewX = eBtnX + totalW / 2 - previewW / 2
                            local previewY = eBtnY + compH + 4
                            if previewX + previewW > ScrW() then
                                previewX = ScrW() - previewW - 8
                            end
                            if previewX < 0 then
                                previewX = 8
                            end
                            if previewY + previewH > ScrH() then
                                previewY = eBtnY - previewH - 4
                            end
                            KARDS.CardEditor.Canvas.DrawCardPreview(cardAppearance, previewX, previewY, previewW, previewH, false, false, false)
                        end
                    end
                    cx = cx + totalW + spacing
                    end  -- end isCardMode else
                else
                    -- 普通模式
                    local selectedIdx = data[comp.id] or 1
                    local selectedText = comp.options[selectedIdx] or comp.options[1]
                    local w = getScaledTextWidth(selectedText, "SourceHan_Heavy", 14) + getScaledTextWidth("字", "SourceHan_Heavy", 14) * 3
                    local newIdx = KARDS.CardEditor.Canvas.DrawDropdown(cx, cy, w, compH, comp.options, selectedIdx, node, comp.id, nil, nil, compFont, editor.canvasScale)
                    if newIdx then data[comp.id] = newIdx end
                    table.insert(editor._interactiveRects, {x = cx, y = cy, w = w, h = compH, nodeId = node.id, compId = comp.id, type = "select"})
                    local expandedKey = node.id .. "_" .. comp.id
                    if KARDS.CardEditor.Canvas.ExpandedDropdown == expandedKey then
                        local expInfo = KARDS.CardEditor.Canvas.ExpandedDropdownInfo
                        if expInfo and expInfo.dropdownX then
                            table.insert(editor._interactiveRects, {
                                x = expInfo.dropdownX, y = expInfo.dropdownY,
                                w = expInfo.totalWidth, h = expInfo.dropdownH or 100,
                                nodeId = node.id, compId = comp.id, type = "select_expanded"
                            })
                        end
                    end
                    cx = cx + w + spacing
                end
            elseif comp.type == "number" then
                -- 数字输入组件：归类为数字槽（类型标识"n" + 原始 DrawNumberBox 行为）
                INE.SyncNumberSlotToSlotData(node, comp.id)
                -- 支持基本数字框（[]）和带选项的数字槽（[x、y、z、...]）
                local val = data[comp.id] or 0
                -- 解析选项：支持 [lib] 和 [lib+额外变量] 语法
                local resolvedOptions = comp.options
                if comp.useLib then
                    resolvedOptions = {}
                    if KARDS.VarLib and KARDS.VarLib.GetNumericVarPaths then
                        local tableID = "1"
                        local libVars = KARDS.VarLib.GetNumericVarPaths(tableID)
                        for _, varPath in ipairs(libVars) do
                            table.insert(resolvedOptions, varPath)
                        end
                    end
                    if comp.extraOptions then
                        for _, extraOpt in ipairs(comp.extraOptions) do
                            table.insert(resolvedOptions, extraOpt)
                        end
                    end
                end
                -- 添加数据连接传入的变量
                if editor.dataConnections then
                    for _, dc in ipairs(editor.dataConnections) do
                        if dc.toNode == node.id and dc.dataType == "n" and dc.variableName then
                            resolvedOptions = resolvedOptions or {}
                            local alreadyExists = false
                            for _, opt in ipairs(resolvedOptions) do
                                if opt == dc.variableName then alreadyExists = true break end
                            end
                            if not alreadyExists then table.insert(resolvedOptions, dc.variableName) end
                        end
                    end
                end
                -- 添加用户自定义数字变量
                if editor.variables and editor.variables["n"] then
                    for _, userVar in ipairs(editor.variables["n"]) do
                        local varName = (userVar.internalName ~= nil and userVar.internalName ~= "") and userVar.internalName or userVar.name
                        if varName then
                            resolvedOptions = resolvedOptions or {}
                            local alreadyExists = false
                            for _, opt in ipairs(resolvedOptions) do
                                if opt == varName then alreadyExists = true break end
                            end
                            if not alreadyExists then table.insert(resolvedOptions, varName) end
                        end
                    end
                end
                local newVal, actualW = KARDS.CardEditor.Canvas.DrawNumberBox(cx, cy, compH, val, node, comp.id, resolvedOptions, compFont)
                if newVal then data[comp.id] = newVal end
                -- [lib+N] 数字槽选值回写统一槽（2026-10-04）：变量库变量 → "var:<名>"；附加预设 → 预设索引。
                -- ReadSlot 优先读 node.data.slots[compId]，据此在运行时解析变量值（如「剩余指挥点」）或预设索引。
                do
                    local numData = node.data.numbers and node.data.numbers[comp.id]
                    local slot = node.data.slots and node.data.slots[comp.id]
                    if numData and slot then
                        local libCount = 0
                        if comp.useLib and KARDS.VarLib and KARDS.VarLib.GetNumericVarPaths then
                            libCount = #KARDS.VarLib.GetNumericVarPaths("1")
                        end
                        local extraCount = (comp.extraOptions and #comp.extraOptions) or 0
                        if numData.mode == "select" and numData.selectedOptionIndex then
                            local idx = numData.selectedOptionIndex
                            local opt = resolvedOptions and resolvedOptions[idx]
                            if comp.useLib and idx <= libCount then
                                -- 变量库变量（选项区段首位为数字变量路径）
                                slot.mode = "variable"
                                slot.variableRef = "var:" .. ((KARDS.VarLib and KARDS.VarLib.GetDisplayName and KARDS.VarLib.GetDisplayName(opt)) or opt or "")
                                slot.literalValue = nil
                            elseif comp.extraOptions and idx > libCount and idx <= libCount + extraCount then
                                -- 附加预设（[lib+N] 的 N 个预设选项）：存 1 基预设索引
                                slot.mode = "literal"
                                slot.literalValue = idx - libCount
                                slot.variableRef = nil
                            elseif opt then
                                -- 数据线/用户自定义变量
                                slot.mode = "variable"
                                slot.variableRef = "var:" .. opt
                                slot.literalValue = nil
                            end
                        else
                            -- 字面量（slot 模式）：存数字
                            slot.mode = "literal"
                            slot.literalValue = numData.value
                            slot.variableRef = nil
                        end
                    end
                end
                -- 立即重新计算节点宽度
                if node.parsedConfig and node.parsedConfig.components then
                    local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput, editor, node.id)
                    dbgPrint("[DBG:WIDTH] DrawComponents node.id=" .. tostring(node.id) .. " oldW=" .. tostring(node.width) .. " newW=" .. tostring(nw))
                    node.width = nw
                    node.height = nh
                end
                local numTotalW = actualW or (compH + 3 * scale + (compH / 2 - 3 * scale))
                -- 记录交互元素包围盒
                table.insert(editor._interactiveRects, {x = cx, y = cy, w = numTotalW, h = compH, nodeId = node.id, compId = comp.id, type = "number"})
                cx = cx + numTotalW + spacing
            elseif comp.type == "textslot" then
                -- 文本槽组件（2026-10-04 新增）：对照数字槽样式——左侧绿色 t 类型按钮 +
                -- 间隔 + 值区。交互（与「设置变量」节点文本槽一致）：
                --   直接输入模式：点值区进入内联输入（透明 DTextEntry，见 INE:Think）
                --   引用模式（值 "var:<名>"）：值区只读显示变量名；点 t 按钮或值区清空回直接输入
                --   直接输入模式下点 t 按钮：展开文本变量下拉（全局文本变量 + 传入的 t 数据线）
                -- 值存储：统一槽 node.data.slots[comp.id]（mode/literalValue/variableRef）与
                -- 扁平 data[comp.id] 双写（运行时 ReadSlot 优先统一槽，末位回退扁平键）。
                local slotData = INE.GetOrCreateSlotData("text", node, comp.id, data[comp.id])
                local rawVal = data[comp.id]
                if type(rawVal) ~= "string" then
                    if slotData.mode == "variable" and slotData.variableRef then
                        rawVal = slotData.variableRef
                    elseif slotData.literalValue ~= nil then
                        rawVal = tostring(slotData.literalValue)
                    else
                        rawVal = ""
                    end
                    data[comp.id] = rawVal
                end
                local isRef = rawVal:sub(1, 4) == "var:"
                if isRef then
                    slotData.mode = "variable"
                    slotData.variableRef = rawVal
                    slotData.literalValue = nil
                else
                    slotData.mode = "literal"
                    slotData.literalValue = rawVal
                    slotData.variableRef = nil
                end
                local editing = INE.TextSlotEditState.active
                    and INE.TextSlotEditState.node == node
                    and INE.TextSlotEditState.compId == comp.id
                local dispText = isRef and rawVal:sub(5) or rawVal
                if editing then dispText = INE.TextSlotEditState.text end
                local charW = getScaledTextWidth("字", "SourceHan_Heavy", 14)
                local tCharW = math.max(14 * scale, charW * 1.4)
                local tBtnX = cx
                local valX = tBtnX + tCharW + 4 * scale
                local measured = getScaledTextWidth(dispText ~= "" and dispText or "文本", "SourceHan_Heavy", 14)
                local valW = math.max(measured + 8 * scale, charW * 4)
                -- 交互矩形先注册：避免点击被判定为节点体拖拽/框选
                table.insert(editor._interactiveRects, {x = tBtnX, y = cy, w = tCharW, h = compH,
                    nodeId = node.id, compId = comp.id, type = "textslot_t"})
                table.insert(editor._interactiveRects, {x = valX, y = cy, w = valW, h = compH,
                    nodeId = node.id, compId = comp.id, type = "textslot"})
                -- 文本变量选项（下拉与选中回写共用）
                local tOpts = INE.GetTextSlotVarOptions(editor, node)
                local ddKey = node.id .. "_textslot_" .. comp.id
                -- 绘制
                local mX, mY = gui.MouseX(), gui.MouseY()
                local tHov = mX >= tBtnX and mX <= tBtnX + tCharW and mY >= cy and mY <= cy + compH
                draw.RoundedBox(3 * scale, tBtnX, cy, tCharW, compH,
                    tHov and Color(70, 120, 80) or Color(45, 60, 50))
                draw.SimpleText("t", compFont, tBtnX + tCharW / 2, cy + compH / 2,
                    Color(144, 238, 144), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                draw.SimpleText("|", compFont, tBtnX + tCharW + 2 * scale, cy + compH / 2,
                    Color(120, 120, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                if isRef and not editing then
                    -- 引用模式：绿色只读变量名
                    draw.RoundedBox(3 * scale, valX, cy, valW, compH, Color(45, 60, 50))
                    draw.SimpleText(dispText, compFont, valX + 4 * scale, cy + compH / 2,
                        Color(144, 238, 144), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                elseif editing then
                    -- 编辑中：高亮 + 蓝框（DTextEntry 完全透明，叠加在其上）
                    draw.RoundedBox(3 * scale, valX, cy, valW, compH, Color(60, 60, 70))
                    surface.SetDrawColor(Color(100, 150, 255, 200))
                    surface.DrawOutlinedRect(valX, cy, valW, compH)
                    draw.SimpleText(dispText, compFont, valX + 4 * scale, cy + compH / 2,
                        Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                else
                    -- 直接输入模式：文本 / 空值灰占位「文本」
                    draw.RoundedBox(3 * scale, valX, cy, valW, compH, Color(45, 45, 50))
                    draw.SimpleText(dispText ~= "" and dispText or "文本", compFont,
                        valX + 4 * scale, cy + compH / 2,
                        dispText ~= "" and Color(220, 220, 220) or Color(120, 120, 120),
                        TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                end
                -- 点击处理（帧级鼠标刚按下标记，与 select 组件同源）
                local mouseJustPressed = INE._frameMouseJustPressed or false
                if mouseJustPressed and not KARDS.CardEditor.Canvas.DraggingNode then
                    local valHov = mX >= valX and mX <= valX + valW and mY >= cy and mY <= cy + compH
                    if isRef then
                        -- 引用模式：点 t 按钮或值区均清空 → 回到直接输入
                        if tHov or valHov then
                            data[comp.id] = ""
                            slotData.mode = "literal"
                            slotData.literalValue = ""
                            slotData.variableRef = nil
                            INE.TextSlotEditState.active = false
                        end
                    elseif tHov then
                        -- 直接输入模式点 t：展开文本变量下拉
                        if #tOpts > 0 then
                            local currentTime = SysTime()
                            if not node.data.dropdowns then node.data.dropdowns = {} end
                            local ddData = node.data.dropdowns[ddKey]
                            if not ddData then
                                ddData = { selectedIndex = 1, appliedIndex = 1, lastClickTime = 0 }
                                node.data.dropdowns[ddKey] = ddData
                            end
                            ddData.options = tOpts
                            if currentTime - (ddData.lastClickTime or 0) > 0.3 then
                                ddData.lastClickTime = currentTime
                                if KARDS.CardEditor.Canvas.ExpandedDropdown == ddKey then
                                    KARDS.CardEditor.Canvas.ExpandedDropdown = nil
                                    KARDS.CardEditor.Canvas.ExpandedDropdownInfo = nil
                                else
                                    local ddStyle = KARDS.CardEditor.Canvas.DropdownStyle
                                    local ddY = cy + compH + 2
                                    local maxRows = math.max(1,
                                        math.floor((ScrH() - ddY - ddStyle.padding * 2) / ddStyle.rowHeight))
                                    surface.SetFont(compFont)
                                    local maxOptW = 0
                                    for _, o in ipairs(tOpts) do
                                        maxOptW = math.max(maxOptW, surface.GetTextSize(o))
                                    end
                                    local colW = math.max(maxOptW + 22, valW)
                                    local numCols = math.ceil(#tOpts / maxRows)
                                    local totalDropW = numCols * colW
                                    local dropX = valX
                                    if dropX + totalDropW > ScrW() then
                                        dropX = math.max(0, ScrW() - totalDropW - 10)
                                    end
                                    local dropH = numCols == 1
                                        and (#tOpts * ddStyle.rowHeight + ddStyle.padding * 2)
                                        or (maxRows * ddStyle.rowHeight + ddStyle.padding * 2)
                                    KARDS.CardEditor.Canvas.ExpandedDropdown = ddKey
                                    KARDS.CardEditor.Canvas.ExpandedDropdownInfo = {
                                        x = valX, y = cy, width = valW, height = compH,
                                        nodeId = node.id, dropdownId = ddKey,
                                        options = tOpts,
                                        dropdownX = dropX, dropdownY = ddY,
                                        totalWidth = totalDropW, expandedColumnWidth = colW,
                                        maxRowsPerColumn = maxRows, dropdownH = dropH,
                                        numColumns = numCols,
                                        isTextSlot = true,  -- 绿色描边（见 cl_ca_ui_components.lua）
                                        dropdownData = ddData,
                                        optFont = compFont, canvasScale = editor.canvasScale or 1,
                                    }
                                end
                            end
                        end
                    elseif valHov then
                        -- 直接输入模式点值区：进入内联输入
                        INE.TextSlotEditState.active = true
                        INE.TextSlotEditState.node = node
                        INE.TextSlotEditState.compId = comp.id
                        INE.TextSlotEditState.text = rawVal
                        INE.TextSlotEditState.x = valX
                        INE.TextSlotEditState.y = cy
                        INE.TextSlotEditState.w = valW
                        INE.TextSlotEditState.h = compH
                    end
                end
                -- 下拉选中回写（下拉关闭后按 selectedIndex 变化写引用，与 select 组件同式）
                do
                    local ddData = node.data.dropdowns and node.data.dropdowns[ddKey]
                    if ddData and ddData.selectedIndex then
                        if ddData.appliedIndex == nil then ddData.appliedIndex = ddData.selectedIndex end
                        if ddData.selectedIndex ~= ddData.appliedIndex then
                            ddData.appliedIndex = ddData.selectedIndex
                            local sel = tOpts[ddData.selectedIndex]
                            if sel then
                                local ref = "var:" .. sel
                                data[comp.id] = ref
                                slotData.mode = "variable"
                                slotData.variableRef = ref
                                slotData.literalValue = nil
                            end
                        end
                    end
                end
                -- 立即重新计算节点宽度（与数字槽同式：文本槽宽度随内容变化）
                if node.parsedConfig and node.parsedConfig.components then
                    local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data,
                        node.hasSecondOutput, editor, node.id)
                    node.width = nw
                    node.height = nh
                end
                cx = cx + tCharW + 4 * scale + valW + spacing
            elseif comp.type == "funcslot" then
                -- 函数槽组件：使用统一槽数据模型，但绘制和交互内联实现
                local slotData = INE.GetOrCreateSlotData("function", node, comp.id, data[comp.id])
                -- 同步 slotData 和 data[comp.id]
                if slotData.variableRef and slotData.variableRef ~= "" then
                    data[comp.id] = slotData.variableRef
                elseif data[comp.id] and data[comp.id] ~= "" and not slotData.variableRef then
                    slotData.variableRef = data[comp.id]
                end
                -- 内联绘制函数槽
                local charW = getScaledTextWidth("字", "SourceHan_Heavy", 14)
                local mX, mY = gui.MouseX(), gui.MouseY()
                -- 生成不与现有全局函数变量/局部函数冲突的局部函数名
                local function genLocalFuncName()
                    local taken = {}
                    if editor.variables and editor.variables["f"] then
                        for _, v in ipairs(editor.variables["f"]) do
                            if v.name and v.name ~= "" then taken[v.name] = true end
                            if v.internalName and v.internalName ~= "" then taken[v.internalName] = true end
                        end
                    end
                    for _, n in ipairs(editor.nodes) do
                        if n.data and n.data.slots then
                            for _, s in pairs(n.data.slots) do
                                if s.type == "function" and s.variableRef and s._localFuncRef then
                                    taken[s.variableRef] = true
                                end
                            end
                        end
                    end
                    local i = 1
                    local name = "局部函数"
                    while taken[name] do
                        i = i + 1
                        name = "局部函数" .. i
                    end
                    return name
                end
                local fChar = "f"
                local fColor = Color(180, 70, 200)
                local fBtnW = charW * 1.5
                local sepW = charW * 0.5
                local funcName = (slotData.variableRef and slotData.variableRef ~= "") and slotData.variableRef or "选择函数"
                local fnTextW = surface.GetTextSize(funcName)
                local minDropW = charW * 4
                local dropDownW = math.max(fnTextW + 24, minDropW, compH)
                local totalW = fBtnW + sepW + dropDownW
                -- 背景
                draw.RoundedBox(4, cx, cy, totalW, compH, Color(60, 60, 60))
                -- f 按钮
                local isFHovered = mX >= cx and mX <= cx + fBtnW and mY >= cy and mY <= cy + compH
                if isFHovered then
                    local hW = fBtnW * 0.8
                    local hX = cx + (fBtnW - hW) / 2
                    draw.RoundedBox(3, hX, cy, hW, compH, Color(255, 255, 255, 40))
                end
                draw.SimpleText(fChar, compFont, cx + fBtnW / 2, cy + compH / 2, fColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                -- 分隔符
                local sepX = cx + fBtnW
                surface.SetDrawColor(Color(150, 150, 150))
                surface.DrawLine(sepX + sepW / 2, cy + 2, sepX + sepW / 2, cy + compH - 2)
                -- 函数名称
                local ddX = sepX + sepW
                local fnColor = Color(100, 200, 255)
                draw.SimpleText(funcName, compFont, ddX + 8, cy + compH / 2, fnColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                -- 下拉箭头
                local arrowX = ddX + dropDownW - 6 - 4
                local arrowY = cy + compH / 2
                surface.SetDrawColor(Color(150, 150, 150))
                surface.DrawLine(arrowX - 3, arrowY - 3, arrowX + 3, arrowY - 3)
                surface.DrawLine(arrowX - 3, arrowY - 3, arrowX, arrowY + 3)
                surface.DrawLine(arrowX + 3, arrowY - 3, arrowX, arrowY + 3)
                -- 点击检测：使用 _frameMouseJustPressed
                if INE._frameMouseJustPressed and not KARDS.CardEditor.Canvas.DraggingNode then
                    local isValueHit = mX >= ddX and mX <= cx + totalW and mY >= cy and mY <= cy + compH
                    -- f 按钮：打开函数编辑器。未绑定时创建局部函数（数据嵌入槽，不进入全局函数变量列表）
                    if isFHovered then
                        local fVarName = slotData.variableRef
                        if not fVarName or fVarName == "" then
                            fVarName = genLocalFuncName()
                            slotData.variableRef = fVarName
                            data[comp.id] = fVarName
                            slotData._localFuncRef = { functionData = nil, _subKey = fVarName }
                        end
                        -- 局部函数：若该槽对应的子编辑器已打开，按下 f 按钮时触发
                        -- 子编辑器外部描边矩形闪烁（视觉引导定位，约 2 秒后消失）。
                        if slotData._localFuncRef and slotData._localFuncRef._subKey then
                            local fSubID = "ine_func_" .. editor.id .. "_loc_" .. slotData._localFuncRef._subKey
                            local fSub = INE.Editors and INE.Editors[fSubID]
                            if fSub and not fSub.hidden then
                                fSub._flashOutlineStart = SysTime()
                                fSub._flashOutlineUntil = SysTime() + 2
                            end
                        end
                        if INE.OpenFunctionSubEditor then
                            INE:OpenFunctionSubEditor(editor, fVarName, slotData._localFuncRef)
                        end
                    elseif isValueHit then
                        -- 收集函数选项：当前槽局部函数 + 全局函数变量
                        local funcOptions = {}
                        if slotData.variableRef and slotData._localFuncRef then
                            table.insert(funcOptions, { label = slotData.variableRef, isLocal = true })
                        end
                        if editor.variables and editor.variables["f"] then
                            for _, fv in ipairs(editor.variables["f"]) do
                                local fvName = (fv.name ~= nil and fv.name ~= "") and fv.name or fv.internalName or "未命名函数"
                                table.insert(funcOptions, { label = fvName, isLocal = false })
                            end
                        end
                        -- 没有可选的函数变量：回退为新建局部函数并打开编辑器（与 f 按钮行为一致）
                        if #funcOptions == 0 then
                            local fVarName = genLocalFuncName()
                            slotData.variableRef = fVarName
                            data[comp.id] = fVarName
                            slotData._localFuncRef = { functionData = nil, _subKey = fVarName }
                            if INE.OpenFunctionSubEditor then
                                INE:OpenFunctionSubEditor(editor, fVarName, slotData._localFuncRef)
                            end
                        else
                            -- 打开函数变量选择弹窗（样式与数字槽单选模式的下拉框相同）
                            surface.SetFont(compFont)
                            local popupCharW = surface.GetTextSize("字")
                            local popupW = popupCharW * 30
                            local popupX = ddX
                            local popupY = cy + compH + 2
                            if popupX + popupW > ScrW() then
                                popupX = ScrW() - popupW - 10
                            end
                            KARDS.CardEditor.Canvas.FuncVarPopup = {
                                nodeRef = node,
                                slotDataRef = slotData,
                                compId = comp.id,
                                x = popupX,
                                y = popupY,
                                searchText = "",
                                page = 1,
                                searchActive = false,
                                funcOptions = funcOptions,
                            }
                            -- 关闭可能展开的普通下拉框
                            KARDS.CardEditor.Canvas.ExpandedDropdown = nil
                            KARDS.CardEditor.Canvas.ExpandedDropdownInfo = nil
                        end
                    end
                end
                -- 同步 variableRef 回 data[comp.id]
                if slotData.variableRef and slotData.variableRef ~= "" then
                    data[comp.id] = slotData.variableRef
                end
                -- 记录交互元素包围盒
                table.insert(editor._interactiveRects, {x = cx, y = cy, w = totalW, h = compH, nodeId = node.id, compId = comp.id, type = "funcslot"})
                cx = cx + totalW + spacing
            elseif comp.type == "if" then
                -- 条件分支组件：根据前方最近 select 组件的选中值匹配分支
                local selectedValue = nil
                for idx = #selectIndices, 1, -1 do
                    local selComp = selectIndices[idx]
                    if data[selComp.id] then
                        selectedValue = selComp.options[data[selComp.id]] or selComp.options[1]
                        break
                    end
                end

                for _, branch in ipairs(comp.branches) do
                    local cond = branch.condition
                    local matches = INE.ConditionMatches(cond, selectedValue, ioCtx)

                    if matches then
                        -- 递归处理匹配分支的组件
                        local savedX = cx
                        local savedY = cy
                        local savedSelects = {unpack(selectIndices)}
                        local savedSelIdx = currentSelectIdx
                        x = cx
                        y = cy
                        processCompList(branch.components, data)
                        cx = x
                        cy = y
                        selectIndices = savedSelects
                        currentSelectIdx = savedSelIdx
                        break
                    end
                end
            end
        end

        x = cx
        y = cy
    end

    processCompList(components, nodeData)
end

--[[
    根据标识符获取数据类型。
    
    @param  id  {string}    数据类型标识符（n/p/t/g/e/f）
    @return {table|nil}     数据类型定义表，未找到返回 nil
]]
function INE.GetDataTypeById(id)
    for _, dataType in pairs(INE.DataTypes) do
        if dataType.id == id then
            return dataType
        end
    end
    return nil
end

--[[
    绘制数据类型图标。
    
    @param  dataType    {table}     数据类型定义表（包含 shape 和 color 字段）
    @param  x           {number}    图标中心 X 坐标
    @param  y           {number}    图标中心 Y 坐标
    @param  size        {number}    图标尺寸（像素）
]]
function INE.DrawDataTypeIcon(dataType, x, y, size)
    if not dataType then return end
    
    local halfSize = size / 2
    surface.SetDrawColor(dataType.color)
    
    if dataType.shape == "circle" then
        -- 圆形
        draw.RoundedBox(halfSize, x - halfSize, y - halfSize, size, size, dataType.color)
    elseif dataType.shape == "triangle" then
        -- 正三角形
        local points = {
            {x = x, y = y - halfSize},
            {x = x + halfSize, y = y + halfSize},
            {x = x - halfSize, y = y + halfSize}
        }
        draw.NoTexture()
        surface.SetDrawColor(dataType.color)
        surface.DrawPoly(points)
    elseif dataType.shape == "square" then
        -- 正方形
        surface.DrawRect(x - halfSize, y - halfSize, size, size)
    elseif dataType.shape == "hollow_circle" then
        -- 空心圆形
        draw.RoundedBox(halfSize, x - halfSize, y - halfSize, size, size, dataType.color)
        draw.RoundedBox(halfSize - 2, x - halfSize + 2, y - halfSize + 2, size - 4, size - 4, Color(50, 50, 50))
    elseif dataType.shape == "hollow_square" then
        -- 空心正方形
        surface.DrawRect(x - halfSize, y - halfSize, size, size)
        surface.SetDrawColor(Color(50, 50, 50))
        surface.DrawRect(x - halfSize + 2, y - halfSize + 2, size - 4, size - 4)
    elseif dataType.shape == "diamond" then
        -- 菱形
        local points = {
            {x = x, y = y - halfSize},
            {x = x + halfSize, y = y},
            {x = x, y = y + halfSize},
            {x = x - halfSize, y = y}
        }
        draw.NoTexture()
        surface.SetDrawColor(dataType.color)
        surface.DrawPoly(points)
    elseif dataType.shape == "hexagon" then
        -- 六边形
        local r = halfSize
        local points = {}
        for i = 0, 5 do
            local angle = math.rad(60 * i - 30)
            table.insert(points, {x = x + r * math.cos(angle), y = y + r * math.sin(angle)})
        end
        draw.NoTexture()
        surface.SetDrawColor(dataType.color)
        surface.DrawPoly(points)
    elseif dataType.shape == "eg_hex_square" then
        -- 空心正方形内接六边形（对象组图标）
        -- 先画空心正方形
        surface.SetDrawColor(dataType.color)
        surface.DrawRect(x - halfSize, y - halfSize, size, size)
        surface.SetDrawColor(Color(50, 50, 50))
        surface.DrawRect(x - halfSize + 2, y - halfSize + 2, size - 4, size - 4)
        -- 再画内接六边形
        local r = halfSize * 0.75
        local points = {}
        for i = 0, 5 do
            local angle = math.rad(60 * i - 30)
            table.insert(points, {x = x + r * math.cos(angle), y = y + r * math.sin(angle)})
        end
        draw.NoTexture()
        surface.SetDrawColor(dataType.color)
        surface.DrawPoly(points)
    end
end

--[[
    统一计算画布区域，返回画布在屏幕上的位置和尺寸。
    
    @param  editor  {table}     编辑器实例对象
    
    @return {table} 画布区域 {x, y, w, h}
]]
function INE:GetCanvasRect(editor)
    local canvasX = editor.x + 5 + (editor.borderless and 0 or 160)
    local canvasY = editor.borderless and editor.y or (editor.y + 45)
    local canvasW = editor.width - 10 - (editor.borderless and 0 or 160)
    local canvasH = editor.borderless and editor.height or (editor.height - 45)
    return {x = canvasX, y = canvasY, w = canvasW, h = canvasH}
end

--[[
    将画布世界坐标转换为屏幕坐标。
    
    @param  editor  {table}     编辑器实例对象
    @param  worldX  {number}    画布世界X坐标
    @param  worldY  {number}    画布世界Y坐标
    
    @return {number, number} 屏幕X, Y坐标
]]
function INE:WorldToScreen(editor, worldX, worldY)
    local rect = self:GetCanvasRect(editor)
    local screenX = rect.x + (worldX + editor.canvasOffsetX) * editor.canvasScale
    local screenY = rect.y + (worldY + editor.canvasOffsetY) * editor.canvasScale
    -- 四舍五入到整数坐标以避免缩放/平移后小数坐标导致鼠标命中检测失败
    -- gui.MouseX()/MouseY() 返回整数，若坐标含小数则 100 >= 100.3 为 false
    return math.Round(screenX), math.Round(screenY)
end

--[[
    将屏幕坐标转换为画布世界坐标。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {number, number} 画布世界X, Y坐标
]]
function INE:ScreenToWorld(editor, screenX, screenY)
    local rect = self:GetCanvasRect(editor)
    local worldX = (screenX - rect.x) / editor.canvasScale - editor.canvasOffsetX
    local worldY = (screenY - rect.y) / editor.canvasScale - editor.canvasOffsetY
    return worldX, worldY
end

--[[
    检测节点是否在画布视口内（部分可见也算可见）。
    
    @param  editor  {table}   编辑器实例对象
    @param  node    {table}   节点实例对象
    
    @return {boolean} 节点可见返回true，完全在视口外返回false
]]
function INE:IsNodeVisible(editor, node)
    local rect = self:GetCanvasRect(editor)
    local nodeScreenX, nodeScreenY = self:WorldToScreen(editor, node.x, node.y)
    local nodeScreenW = node.width * editor.canvasScale
    local nodeScreenH = node.height * editor.canvasScale
    
    if nodeScreenX + nodeScreenW < rect.x then return false end
    if nodeScreenX > rect.x + rect.w then return false end
    if nodeScreenY + nodeScreenH < rect.y then return false end
    if nodeScreenY > rect.y + rect.h then return false end
    
    return true
end

--[[
    检测连接线是否可见（连接的两个节点至少有一个部分可见，或线段端点在画布扩展范围内）。
    
    @param  editor    {table}   编辑器实例对象
    @param  fromNode  {table}   起始节点
    @param  toNode    {table}   目标节点
    
    @return {boolean} 连接线可见返回true，否则返回false
]]
function INE:IsConnectionVisible(editor, fromNode, toNode)
    if self:IsNodeVisible(editor, fromNode) or self:IsNodeVisible(editor, toNode) then
        return true
    end
    local fromScreenX, fromScreenY = self:WorldToScreen(editor, fromNode.x + fromNode.width, fromNode.y + fromNode.height / 2)
    local toScreenX, toScreenY = self:WorldToScreen(editor, toNode.x, toNode.y + toNode.height / 2)
    local rect = self:GetCanvasRect(editor)
    local margin = 100
    local minX = math.min(fromScreenX, toScreenX) - margin
    local maxX = math.max(fromScreenX, toScreenX) + margin
    local minY = math.min(fromScreenY, toScreenY) - margin
    local maxY = math.max(fromScreenY, toScreenY) + margin
    return maxX >= rect.x and minX <= rect.x + rect.w and maxY >= rect.y and minY <= rect.y + rect.h
end

--[[
    将视图居中到指定世界坐标点
    
    @param  editor  {table}   编辑器实例对象
    @param  worldX  {number}  世界X坐标
    @param  worldY  {number}  世界Y坐标
]]
function INE:CenterViewOn(editor, worldX, worldY)
    local rect = self:GetCanvasRect(editor)
    editor.canvasOffsetX = rect.w / (2 * editor.canvasScale) - worldX
    editor.canvasOffsetY = rect.h / (2 * editor.canvasScale) - worldY
end

--[[
    返回原点：将世界坐标原点居中显示在画布面板中央
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:ResetView(editor)
    local rect = self:GetCanvasRect(editor)
    editor.canvasOffsetX = rect.w / 2
    editor.canvasOffsetY = rect.h / 2
    editor.canvasScale = 1
end

--[[
    适配所有节点：调整视图以显示所有节点。
    计算所有节点的包围盒，将视图居中并缩放至合适比例。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:FitAllNodes(editor)
    if #editor.nodes == 0 then
        INE:ResetView(editor)
        return
    end
    
    local minX, minY, maxX, maxY = nil, nil, nil, nil
    for _, node in ipairs(editor.nodes) do
        local nx1, ny1 = node.x, node.y
        local nx2, ny2 = node.x + node.width, node.y + node.height
        minX = (minX == nil) and nx1 or math.min(minX, nx1)
        minY = (minY == nil) and ny1 or math.min(minY, ny1)
        maxX = (maxX == nil) and nx2 or math.max(maxX, nx2)
        maxY = (maxY == nil) and ny2 or math.max(maxY, ny2)
    end
    
    local rect = self:GetCanvasRect(editor)
    local contentW = rect.w - 40
    local contentH = rect.h - 40
    local bboxW = maxX - minX
    local bboxH = maxY - minY
    
    local scaleX = contentW / math.max(bboxW, 100)
    local scaleY = contentH / math.max(bboxH, 100)
    local scale = math.min(scaleX, scaleY, 1.0)
    editor.canvasScale = math.Clamp(scale, INE.ZOOM_MIN, INE.ZOOM_MAX)
    
    local centerX = (minX + maxX) / 2
    local centerY = (minY + maxY) / 2
    editor.canvasOffsetX = rect.w / (2 * editor.canvasScale) - centerX
    editor.canvasOffsetY = rect.h / (2 * editor.canvasScale) - centerY
end

--[[
    缩放视图
    
    @param  editor  {table}   编辑器实例对象
    @param  factor  {number}  缩放因子（>1放大，<1缩小）
]]
function INE:ZoomView(editor, factor)
    local oldScale = editor.canvasScale
    
    -- 沿鼠标缩放：先记录鼠标下方的世界坐标（使用旧缩放值计算）
    local worldX, worldY
    if editor._viewZoomFollowMouse then
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        local rect = self:GetCanvasRect(editor)
        if mouseX >= rect.x and mouseX <= rect.x + rect.w and mouseY >= rect.y and mouseY <= rect.y + rect.h then
            -- 使用旧缩放计算世界坐标
            worldX = (mouseX - rect.x) / oldScale - editor.canvasOffsetX
            worldY = (mouseY - rect.y) / oldScale - editor.canvasOffsetY
        end
    end
    
    editor.canvasScale = math.Clamp(editor.canvasScale * factor, INE.ZOOM_MIN, INE.ZOOM_MAX)
    
    -- 缩放时关闭展开的下拉框、变量弹窗和对象选择器
    KARDS.CardEditor.Canvas.ExpandedDropdown = nil
    KARDS.CardEditor.Canvas.ExpandedDropdownInfo = nil
    KARDS.CardEditor.Canvas.NumericVarPopup = nil
    KARDS.CardEditor.Canvas.CardObjectSelector = nil
    
    -- 沿鼠标缩放：调整偏移使世界坐标点保持在鼠标下
    if editor._viewZoomFollowMouse and worldX then
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        local rect = self:GetCanvasRect(editor)
        local newScreenX = rect.x + (worldX + editor.canvasOffsetX) * editor.canvasScale
        local newScreenY = rect.y + (worldY + editor.canvasOffsetY) * editor.canvasScale
        editor.canvasOffsetX = editor.canvasOffsetX + (mouseX - newScreenX) / editor.canvasScale
        editor.canvasOffsetY = editor.canvasOffsetY + (mouseY - newScreenY) / editor.canvasScale
    end
end

--[[
    定位到极端节点
    
    @param  editor     {table}   编辑器实例对象
    @param  direction  {string}  方向："left"/"right"/"top"/"bottom"
]]
function INE:FocusExtremeNode(editor, direction)
    if #editor.nodes == 0 then return end
    local targetNode = editor.nodes[1]
    for _, node in ipairs(editor.nodes) do
        if direction == "left" and node.x < targetNode.x then
            targetNode = node
        elseif direction == "right" and node.x + node.width > targetNode.x + targetNode.width then
            targetNode = node
        elseif direction == "top" and node.y < targetNode.y then
            targetNode = node
        elseif direction == "bottom" and node.y + node.height > targetNode.y + targetNode.height then
            targetNode = node
        end
    end
    self:CenterViewOn(editor, targetNode.x + targetNode.width/2, targetNode.y + targetNode.height/2)
end

--[[
=======================================================================================
INE 通知与悬停提示系统
=======================================================================================
独立的通知系统，用于替代旧的 NodeBase / Canvas 提示系统，确保提示显示在最顶层。
支持弹出通知（自动淡出）和鼠标跟随的悬停提示。
=======================================================================================
]]

--[[
    向指定编辑器添加一条弹出通知。
    
    @param  editor   {table}    编辑器实例对象
    @param  text     {string}   通知文本
    @param  color    {Color}    通知颜色（用于左侧色条和文字）
    @param  duration {number}   显示时长（秒），默认 3 秒
]]
-- 通知系统配置（每个编辑器面板独立使用）
INE.NotificationConfig = {
    animationDuration = 0.4,       -- 滑入/滑出动画持续时间（秒）
    displayDuration = 2.0,         -- 显示持续时间（秒）
    minWidth = 150,                -- 最小宽度
    maxWidth = 320,                -- 最大宽度
    padding = 12,                  -- 内边距
    titleHeight = 20,              -- 标题框高度
    rowSpacing = 8,                -- 通知间距
    cornerRadius = 6,              -- 圆角半径
    titleColor = Color(60, 60, 65), -- 标题框颜色
    textColor = Color(230, 230, 230),  -- 文本颜色
    flashDuration = 0.4,           -- 闪烁持续时间
    flashCount = 3,                -- 闪烁次数
    fontSize = "SourceHan_Heavy_14" -- 字体
}

--[[
    缓动函数：Back Out（带回弹效果）。
    用于通知滑入/滑出动画，形成自然的弹性效果。
]]
function INE:EaseOutBack(t, b, c, d, s)
    s = s or 1.70158
    local t2 = t / d - 1
    return c * (t2 * t2 * ((s + 1) * t2 + s) + 1) + b
end

--[[
    向指定编辑器添加通知。
    具备以下特性：
    - 声音反馈（成功/失败音频）
    - 重复文本自动合并并计数
    - 自动执行三阶段动画（进入→显示→退出）
    - 宽度根据文本内容自适应
    
    @param  editor   {table}    编辑器实例对象
    @param  text     {string}   通知文本
    @param  color    {Color}    通知颜色（用于标题框和背景）
    @param  duration {number}   显示时长（秒），默认 3 秒
    @param  isSuccess {boolean} 是否为成功通知（播放成功音效），默认 false
]]
function INE:AddNotification(editor, text, color, duration, isSuccess)
    if not editor or not text then return end
    editor.notifications = editor.notifications or {}
    color = color or Color(200, 200, 200)
    duration = duration or 3
    local config = INE.NotificationConfig
    local currentTime = SysTime()

    -- 播放音效
    if isSuccess then
        if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayNotificationSuccess then
            KARDS.CardEditor.Audio.PlayNotificationSuccess()
        end
    else
        if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayNotification then
            KARDS.CardEditor.Audio.PlayNotification()
        end
    end

    -- 检查是否有重复的通知（2秒内的相同文本自动合并）
    for _, notif in ipairs(editor.notifications) do
        if notif.text == text and currentTime - notif.createdTime < 2 then
            notif.count = (notif.count or 1) + 1
            notif.createdTime = currentTime
            notif.animationTime = 0
            notif.state = "entering"
            notif.flashTime = 0
            notif.flashCount = 0
            return
        end
    end

    -- 计算通知框尺寸
    surface.SetFont(config.fontSize)
    local textWidth, textHeight = surface.GetTextSize(text)
    local notifWidth = math.Clamp(textWidth + config.padding * 2, config.minWidth, config.maxWidth)
    local notifHeight = textHeight + config.padding * 2 + config.titleHeight

    -- 创建新通知
    local notif = {
        text = text,
        color = color,
        count = 1,
        createdTime = currentTime,
        animationTime = 0,
        state = "entering",
        position = 0,
        flashTime = 0,
        flashCount = 0,
        width = notifWidth,
        height = notifHeight
    }
    table.insert(editor.notifications, notif)

    -- 限制通知数量，避免过多堆积
    while #editor.notifications > 5 do
        table.remove(editor.notifications, 1)
    end
end

--[[
    更新指定编辑器的通知状态。
    管理三阶段动画（进入→显示→退出）的生命周期，
    以及闪烁效果和过期清除。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:UpdateNotifications(editor)
    if not editor.notifications or #editor.notifications == 0 then return end
    local config = INE.NotificationConfig
    local notifications = editor.notifications

    -- 过滤过期的通知
    local valid = {}
    for _, notif in ipairs(notifications) do
        notif.animationTime = (notif.animationTime or 0) + FrameTime()

        local shouldSkip = false
        if notif.state == "entering" then
            if notif.animationTime >= config.animationDuration then
                notif.state = "active"
                notif.animationTime = 0
            end
        elseif notif.state == "active" then
            if notif.animationTime >= config.displayDuration then
                notif.state = "exiting"
                notif.animationTime = 0
            end
        elseif notif.state == "exiting" then
            if notif.animationTime >= config.animationDuration then
                shouldSkip = true
            end
        end

        if not shouldSkip then
            -- 更新闪烁状态
            if notif.count > 1 then
                notif.flashTime = (notif.flashTime or 0) + FrameTime()
            end
            table.insert(valid, notif)
        end
    end

    -- 按创建时间排序，新通知在上
    table.sort(valid, function(a, b)
        return a.createdTime > b.createdTime
    end)

    -- 更新位置索引
    for i, notif in ipairs(valid) do
        notif.position = i - 1
    end

    editor.notifications = valid
end

--[[
    绘制指定编辑器的通知列表。
    通知显示在编辑器面板的右上角，相对于面板边缘定位。
    支持滑入/滑出动画、计数徽标、闪烁效果。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:DrawNotifications(editor)
    if not editor.notifications or #editor.notifications == 0 then return end
    local config = INE.NotificationConfig
    local notifications = editor.notifications

    for _, notif in ipairs(notifications) do
        local totalWidth = notif.width
        local totalHeight = notif.height
        
        -- 垂直位置：相对于编辑器面板顶部，每行依次向下排列
        local y = editor.y + (editor.borderless and 10 or 45) + notif.position * (totalHeight + config.rowSpacing)

        -- 计算水平滑入/滑出动画偏移
        local xOffset = 0
        if notif.state == "entering" then
            local progress = math.min(notif.animationTime / config.animationDuration, 1)
            xOffset = INE:EaseOutBack(progress, totalWidth, -totalWidth * 2, 1)
        elseif notif.state == "active" then
            xOffset = -totalWidth
        elseif notif.state == "exiting" then
            local progress = math.min(notif.animationTime / config.animationDuration, 1)
            xOffset = INE:EaseOutBack(progress, -totalWidth, totalWidth * 2, 1)
        end

        -- x 是通知框的左边缘位置（从右侧滑入）
        local x = editor.x + editor.width + xOffset

        -- 绘制背景圆角框
        draw.RoundedBox(config.cornerRadius, x, y, totalWidth, totalHeight, notif.color)

        -- 绘制标题框
        draw.RoundedBoxEx(config.cornerRadius, x, y, totalWidth, config.titleHeight, config.titleColor, true, true, false, false)

        -- 绘制标题文本
        local titleText = "提示  -Tip-"
        draw.SimpleText(titleText, config.fontSize, x + config.padding, y + config.titleHeight / 2, config.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 绘制计数徽标在标题框中
        if notif.count > 1 then
            local countText = "×" .. notif.count
            surface.SetFont(config.fontSize)
            local countWidth, countHeight = surface.GetTextSize(countText)
            local countX = x + totalWidth - config.padding - countWidth

            draw.RoundedBox(4, countX - 4, y + config.titleHeight / 2 - countHeight / 2 - 2, countWidth + 8, countHeight + 4, Color(0, 0, 0, 150))
            draw.SimpleText(countText, config.fontSize, countX, y + config.titleHeight / 2, config.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end

        -- 绘制通知文本
        draw.SimpleText(notif.text, config.fontSize, x + config.padding, y + config.titleHeight + config.padding, config.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        -- 绘制闪烁边框（计数 > 1 时的闪烁提示）
        if notif.count > 1 and (notif.flashTime or 0) < config.flashDuration then
            local flashProgress = notif.flashTime / (config.flashDuration / (config.flashCount * 2))
            local flashState = math.floor(flashProgress) % 2

            if flashState == 0 then
                surface.SetDrawColor(255, 255, 255, 200)
                surface.DrawOutlinedRect(x - 2, y - 2, totalWidth + 4, totalHeight + 4)
            end
        end
    end
end

--[[
    更新指定编辑器的悬停提示文本。
    
    @param  editor  {table}   编辑器实例对象
    @param  text    {string}  提示文本，传入空字符串或 nil 清除提示
]]
function INE:UpdateHoverTooltip(editor, text)
    if not editor then return end
    editor.hoverTooltip = editor.hoverTooltip or { text = "", updated = false, x = 0, y = 0 }
    editor.hoverTooltip.text = text or ""
    editor.hoverTooltip.updated = true
end

--[[
    清除指定编辑器的悬停提示。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:ClearHoverTooltip(editor)
    if not editor then return end
    editor.hoverTooltip = editor.hoverTooltip or { text = "", updated = false, x = 0, y = 0 }
    editor.hoverTooltip.text = ""
    editor.hoverTooltip.updated = true
end

--[[
    在绘制开始前标记悬停提示为“本帧未更新”，用于自动清除过期的提示。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:BeginHoverTooltipFrame(editor)
    if not editor then return end
    editor.hoverTooltip = editor.hoverTooltip or { text = "", updated = false, x = 0, y = 0 }
    editor.hoverTooltip.updated = false
end

--[[
    绘制指定编辑器的悬停提示。
    提示显示在鼠标右下方，并限制在屏幕范围内。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:DrawHoverTooltip(editor)
    if not editor or not editor.hoverTooltip then return end
    local tooltip = editor.hoverTooltip
    if tooltip.text == "" or tooltip.text == nil then return end
    
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local text = tooltip.text
    local font = "SourceHan_Heavy_14"
    local padding = 8
    
    surface.SetFont(font)
    local textW, textH = surface.GetTextSize(text)
    local boxW = textW + padding * 2
    local boxH = textH + padding * 2
    
    local boxX = mouseX + 15
    local boxY = mouseY + 15
    
    -- 防止超出屏幕右/下边界
    if boxX + boxW > ScrW() then
        boxX = mouseX - boxW - 10
    end
    if boxY + boxH > ScrH() then
        boxY = mouseY - boxH - 10
    end
    
    draw.RoundedBox(4, boxX, boxY, boxW, boxH, Color(30, 30, 35, 240))
    draw.SimpleText(text, font, boxX + padding, boxY + padding, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
end

function INE:GetFilteredNodeList(editor)
    local searchText = string.lower(editor._findNodeSearchText or "")
    local result = {}
    for _, node in ipairs(editor.nodes) do
        if searchText == "" or string.find(string.lower(node.name), searchText, 1, true) then
            table.insert(result, node)
        end
    end
    return result
end

function INE:ReadKeyboardChar(editor)
    editor._findKeyStates = editor._findKeyStates or {}
    local ch = nil
    
    for i = 1, 26 do
        local key = KEY_A + i - 1
        local keyDown = input.IsKeyDown(key)
        if keyDown and not editor._findKeyStates[key] then
            editor._findKeyStates[key] = true
            local char = string.char(96 + i)
            if input.IsKeyDown(KEY_LSHIFT) or input.IsKeyDown(KEY_RSHIFT) then
                char = string.upper(char)
            end
            if input.IsKeyDown(KEY_CAPSLOCK) then
                char = string.upper(char)
            end
            ch = char
            break
        elseif not keyDown then
            editor._findKeyStates[key] = false
        end
    end
    
    if not ch then
        for i = 0, 9 do
            local key = KEY_0 + i
            local keyDown = input.IsKeyDown(key)
            if keyDown and not editor._findKeyStates[key] then
                editor._findKeyStates[key] = true
                ch = tostring(i)
                break
            elseif not keyDown then
                editor._findKeyStates[key] = false
            end
        end
    end
    
    if not ch then
        local key = KEY_SPACE
        local keyDown = input.IsKeyDown(key)
        if keyDown and not editor._findKeyStates[key] then
            editor._findKeyStates[key] = true
            ch = " "
        elseif not keyDown then
            editor._findKeyStates[key] = false
        end
    end
    
    if not ch then
        local key = KEY_MINUS
        local keyDown = input.IsKeyDown(key)
        if keyDown and not editor._findKeyStates[key] then
            editor._findKeyStates[key] = true
            ch = (input.IsKeyDown(KEY_LSHIFT) or input.IsKeyDown(KEY_RSHIFT)) and "_" or "-"
        elseif not keyDown then
            editor._findKeyStates[key] = false
        end
    end
    
    return ch
end

function INE:OpenFindNodeWindow(editor)
    editor._findNodeWindowOpen = true
    editor._findNodeSearchText = ""
    editor._findNodeSelectedIndex = 0
    editor._findNodeInputFocused = true
    editor._findKeyStates = {}
    
    local rect = self:GetCanvasRect(editor)
    INE:ShowOverlayWindow(editor, {
        id = "find_node_window",
        title = "查找节点",
        x = rect.x + rect.w/2 - 175,
        y = rect.y + 80,
        width = 350,
        height = 300,
        content = function(editor, win, wx, wy, ww, wh)
            INE:DrawFindNodeContent(editor, win, wx, wy, ww, wh)
        end,
        onClose = function(win)
            editor._findNodeWindowOpen = false
        end
    })
end

function INE:DrawFindNodeContent(editor, win, wx, wy, ww, wh)
    local searchText = editor._findNodeSearchText or ""
    
    draw.RoundedBox(4, wx + 5, wy + 5, ww - 10, 28, Color(40, 40, 45))
    
    if searchText ~= "" then
        draw.SimpleText(searchText, "Calibri_20", wx + 12, wy + 19, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText("输入节点名称搜索...", "Calibri_20", wx + 12, wy + 19, Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    
    if editor._findNodeInputFocused and CurTime() % 1 < 0.5 then
        local textW = 0
        if searchText ~= "" then
            surface.SetFont("Calibri_20")
            textW = surface.GetTextSize(searchText)
        end
        local cursorX = wx + 12 + textW + 2
        surface.SetDrawColor(Color(220, 220, 220))
        surface.DrawRect(cursorX, wy + 10, 2, 18)
    end
    
    local listStartY = wy + 40
    local itemH = 26
    local filteredNodes = INE:GetFilteredNodeList(editor)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    if #filteredNodes == 0 then
        draw.SimpleText("未找到匹配的节点", "SourceHan_Heavy_14", wx + ww/2, listStartY + 20, Color(120, 120, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    else
        for i, node in ipairs(filteredNodes) do
            local itemY = listStartY + (i - 1) * itemH
            if itemY + itemH > wy + wh then break end
            
            local itemX = wx + 2
            local itemW = ww - 4
            
            local itemHovered = mouseX >= itemX and mouseX <= itemX + itemW and
                               mouseY >= itemY and mouseY <= itemY + itemH
            local itemSelected = (i == editor._findNodeSelectedIndex)
            
            local bgColor = nil
            if itemSelected then
                bgColor = Color(70, 100, 150)
            elseif itemHovered then
                bgColor = Color(60, 60, 70)
            end
            
            if bgColor then
                draw.RoundedBox(2, itemX, itemY, itemW, itemH, bgColor)
            end
            
            draw.SimpleText(node.name, "SourceHan_Heavy_14", wx + 10, itemY + itemH/2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end
end

--[[
    启用画布裁剪区域，限制后续绘制只在画布区域内显示。
]]
function INE:BeginCanvasScissor(editor)
    local rect = self:GetCanvasRect(editor)
    -- 使用整数坐标避免浮点精度导致裁剪区域异常
    local x1 = math.floor(rect.x)
    local y1 = math.floor(rect.y)
    local x2 = math.ceil(rect.x + rect.w)
    local y2 = math.ceil(rect.y + rect.h)
    render.SetScissorRect(x1, y1, x2, y2, true)
end

--[[
    禁用画布裁剪区域，恢复正常绘制。
]]
function INE:EndCanvasScissor()
    render.SetScissorRect(0, 0, 0, 0, false)
end

--[[
    显示一个叠加窗口。
    
    @param  editor      {table}     编辑器实例
    @param  windowData  {table}     窗口数据表，至少包含id, title, x, y, width, height, content
]]
function INE:ShowOverlayWindow(editor, windowData)
    windowData.visible = true
    windowData.draggable = windowData.draggable ~= false
    editor.overlayWindows = editor.overlayWindows or {}
    -- 先删除旧条目再重新插入，确保新窗口在 pairs 迭代中排在最后（即绘制在最上层）
    if editor.overlayWindows[windowData.id] then
        editor.overlayWindows[windowData.id] = nil
    end
    editor.overlayWindows[windowData.id] = windowData
    -- 记录创建序号用于确定绘制顺序（后创建的在上层）
    INE._overlayOrderCounter = (INE._overlayOrderCounter or 0) + 1
    windowData._order = INE._overlayOrderCounter
end

--[[
    隐藏/关闭叠加窗口。
    
    @param  editor    {table}   编辑器实例
    @param  windowId  {string}  窗口ID
]]
function INE:CloseOverlayWindow(editor, windowId)
    if editor.overlayWindows and editor.overlayWindows[windowId] then
        local win = editor.overlayWindows[windowId]
        win.visible = false
        if win.onClose then win:onClose() end
        editor.overlayWindows[windowId] = nil
    end
end

--[[
    获取指定位置上方的叠加窗口（用于命中检测，逆序遍历后创建的窗口在上层）。
    
    @param  editor   {table}   编辑器实例
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中的窗口实例，未命中返回nil
]]
function INE:GetOverlayWindowAt(editor, screenX, screenY)
    if not editor.overlayWindows then return nil end
    local windows = {}
    for _, win in pairs(editor.overlayWindows) do
        if win.visible then table.insert(windows, win) end
    end
    -- 按创建顺序排序，后创建的在上层（与绘制顺序一致）
    table.sort(windows, function(a, b) return (a._order or 0) < (b._order or 0) end)
    for i = #windows, 1, -1 do
        local win = windows[i]
        if screenX >= win.x and screenX <= win.x + win.width and
           screenY >= win.y and screenY <= win.y + win.height then
            return win
        end
    end
    return nil
end

--[[
    判断鼠标是否在任何叠加窗口上。
    
    @param  editor   {table}   编辑器实例
    @param  mouseX   {number}  鼠标X坐标
    @param  mouseY   {number}  鼠标Y坐标
    
    @return {boolean} 鼠标在叠加窗口上返回true
]]
function INE:IsMouseOverOverlayWindow(editor, mouseX, mouseY)
    return self:GetOverlayWindowAt(editor, mouseX, mouseY) ~= nil
end

--[[
    绘制单个叠加窗口。
    
    @param  editor  {table}   编辑器实例
    @param  win     {table}   窗口实例
]]
function INE:DrawOverlayWindow(editor, win)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    draw.RoundedBox(8, win.x + 2, win.y + 2, win.width, win.height, Color(0, 0, 0, 100))
    draw.RoundedBox(8, win.x, win.y, win.width, win.height, Color(55, 55, 60, 250))
    draw.RoundedBoxEx(8, win.x, win.y, win.width, 32, Color(65, 65, 75), true, true, false, false)
    local titleMaxX = win.x + win.width
    draw.SimpleText(win.title, "SourceHan_Heavy_16", win.x + 10, win.y + 16, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    
    local closeX = win.x + win.width - 30
    local closeY = win.y + 3
    local closeW = 25
    local closeH = 25
    local closeHovered = mouseX >= closeX and mouseX <= closeX + closeW and
                        mouseY >= closeY and mouseY <= closeY + closeH
    draw.RoundedBox(4, closeX, closeY, closeW, closeH, closeHovered and Color(200, 70, 70) or Color(180, 60, 60))
    draw.SimpleText("X", "SourceHan_Heavy_14", closeX + closeW/2, closeY + closeH/2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    win._closeBtn = {x = closeX, y = closeY, w = closeW, h = closeH}
    
    -- 变量分类选择器（仅变量对话框显示）
    if win.showScope then
        local scope = win.scope or "global"
        local btnW, btnH = 32, 22
        local btnY = win.y + 5
        local gap = 4
        -- 长期按钮
        local longX = closeX - btnW - gap
        local longHov = mouseX >= longX and mouseX <= longX + btnW and mouseY >= btnY and mouseY <= btnY + btnH
        local longActive = (scope == "longterm")
        draw.RoundedBox(4, longX, btnY, btnW, btnH,
            longActive and Color(180, 120, 60) or (longHov and Color(90, 85, 80) or Color(65, 65, 75)))
        draw.SimpleText("长期", "SourceHan_Heavy_10", longX + btnW/2, btnY + btnH/2,
            longActive and Color(255, 230, 180) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        win._scopeLongtermBtn = {x = longX, y = btnY, w = btnW, h = btnH}
        -- 全局按钮
        local globalX = longX - btnW - gap
        local globalHov = mouseX >= globalX and mouseX <= globalX + btnW and mouseY >= btnY and mouseY <= btnY + btnH
        local globalActive = (scope == "global" or not scope)
        draw.RoundedBox(4, globalX, btnY, btnW, btnH,
            globalActive and Color(80, 120, 180) or (globalHov and Color(85, 85, 90) or Color(65, 65, 75)))
        draw.SimpleText("全局", "SourceHan_Heavy_10", globalX + btnW/2, btnY + btnH/2,
            globalActive and Color(180, 210, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        win._scopeGlobalBtn = {x = globalX, y = btnY, w = btnW, h = btnH}
    end
    
    local clientX = win.x
    local clientY = win.y + 32
    local clientW = win.width
    local clientH = win.height - 32
    if win.content then
        win.content(editor, win, clientX, clientY, clientW, clientH)
    end
end

--[[
    绘制导入文件选择窗口的内容（文件列表 + 按钮）。
    
    @param  editor  {table}   编辑器实例
    @param  win     {table}   窗口实例
    @param  cx      {number}  客户区X
    @param  cy      {number}  客户区Y
    @param  cw      {number}  客户区宽度
    @param  ch      {number}  客户区高度
]]
function INE:DrawImportWindowContent(editor, win, cx, cy, cw, ch)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    -- 绘制提示文字
    draw.SimpleText("选择要导入的文件:", "SourceHan_Heavy_16", cx + 15, cy + 15, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    
    -- 文件列表区域
    local listX = cx + 10
    local listY = cy + 40
    local listW = cw - 20
    local listH = ch - 110
    
    -- 列表背景
    draw.RoundedBox(4, listX, listY, listW, listH, Color(45, 45, 50))
    
    -- 文件列表
    local files = editor._importFiles or {}
    local itemH = 30
    local startY = listY + 5
    local scrollOffset = editor._importScrollOffset or 0
    
    -- 存储文件行矩形用于点击检测
    editor._importFileRects = {}
    
    for i = 1, #files do
        local idx = i + scrollOffset
        if idx < 1 then idx = 1 end
        if idx > #files then break end
        
        local itemY = startY + (i - 1) * itemH
        if itemY + itemH > listY + listH then break end
        
        local fileName = files[idx]
        local isSelected = editor._importSelectedFile == fileName
        local isHovered = mouseX >= listX and mouseX <= listX + listW and mouseY >= itemY and mouseY <= itemY + itemH
        
        local itemColor = isSelected and Color(80, 80, 120) or (isHovered and Color(65, 65, 70) or Color(45, 45, 50))
        draw.RoundedBox(2, listX + 2, itemY, listW - 4, itemH - 2, itemColor)
        
        draw.SimpleText(fileName, "SourceHan_Heavy_14", listX + 15, itemY + itemH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        
        -- 存储矩形用于点击检测
        table.insert(editor._importFileRects, {x = listX + 2, y = itemY, w = listW - 4, h = itemH - 2, idx = idx})
    end
    
    -- 按钮区域
    local btnY = cy + ch - 45
    
    -- 加载按钮
    local loadBtnX = cx + cw / 2 - 175
    local loadBtnW = 160
    local loadBtnH = 35
    local loadEnabled = editor._importSelectedFile ~= nil
    local loadHovered = mouseX >= loadBtnX and mouseX <= loadBtnX + loadBtnW and mouseY >= btnY and mouseY <= btnY + loadBtnH
    
    editor._importLoadBtnRect = {x = loadBtnX, y = btnY, w = loadBtnW, h = loadBtnH}
    
    local loadColor = loadEnabled and (loadHovered and Color(100, 150, 255) or Color(80, 120, 200)) or Color(70, 70, 75)
    draw.RoundedBox(6, loadBtnX, btnY, loadBtnW, loadBtnH, loadColor)
    draw.SimpleText("加载", "SourceHan_Heavy_16", loadBtnX + loadBtnW / 2, btnY + loadBtnH / 2, loadEnabled and Color(255, 255, 255) or Color(150, 150, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 取消按钮
    local cancelBtnX = cx + cw / 2 + 15
    local cancelBtnW = 160
    local cancelBtnH = 35
    local cancelHovered = mouseX >= cancelBtnX and mouseX <= cancelBtnX + cancelBtnW and mouseY >= btnY and mouseY <= btnY + cancelBtnH
    
    editor._importCancelBtnRect = {x = cancelBtnX, y = btnY, w = cancelBtnW, h = cancelBtnH}
    
    local cancelColor = cancelHovered and Color(100, 100, 100) or Color(80, 80, 85)
    draw.RoundedBox(6, cancelBtnX, btnY, cancelBtnW, cancelBtnH, cancelColor)
    draw.SimpleText("取消", "SourceHan_Heavy_16", cancelBtnX + cancelBtnW / 2, btnY + cancelBtnH / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end





--[[
    每帧逻辑更新函数。
    遍历所有可见编辑器，调用各自的输入处理逻辑。
    由Think钩子每帧调用。
]]
function INE:Think()
    -- ============================================================
    -- 变量搜索 DTextEntry 生命周期管理
    -- ============================================================
    local vsState = INE.VarSearchState
    local vsEntry = INE.VarSearchTextEntry
    if vsState.active then
        if not vsEntry or not IsValid(vsEntry) then
            local entry = vgui.Create("DTextEntry")
            entry:SetPos(vsState.x, vsState.y)
            entry:SetSize(vsState.w, vsState.h)
            entry:SetText(vsState.text or "")
            entry:SetDrawBackground(false)
            entry:SetDrawBorder(false)
            entry:SetTextColor(Color(255, 255, 255, 0))
            entry:SetCursorColor(Color(255, 255, 255, 0))
            entry.Paint = nil
            entry:MakePopup()

            entry.OnTextChanged = function(self)
                local txt = self:GetText()
                if INE.VarSearchState then
                    INE.VarSearchState.text = txt
                    -- 同步到编辑器的搜索文本
                    local edID = INE.VarSearchState.editorID
                    local typeId = INE.VarSearchState.typeId
                    if edID and typeId then
                        local ed = INE.Editors[edID]
                        if ed then
                            ed._varSearchText[typeId] = txt
                        end
                    end
                end
            end

            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE then
                    if INE.VarSearchState then
                        INE.VarSearchState.active = false
                    end
                end
            end

            INE.VarSearchTextEntry = entry
        else
            -- 已存在，确保位置同步（因滚动位置会变）
            vsEntry:SetPos(vsState.x, vsState.y)
            vsEntry:SetSize(vsState.w, vsState.h)
            if not vsEntry:HasFocus() then
                vsEntry:RequestFocus()
            end
        end
    else
        if vsEntry and IsValid(vsEntry) then
            vsEntry:Remove()
        end
        INE.VarSearchTextEntry = nil
    end

    -- ============================================================
    -- 数字变量对话框 DTextEntry 生命周期管理
    -- ============================================================
    local nvState = INE.NumVarFieldState
    local nvEntry = INE.NumVarTextEntry
    if nvState.active then
        -- 检查编辑器/变量是否仍有效
        local ed = INE.Editors[nvState.editorID]
        local vd = ed and (ed.variables["n"] or {})[nvState.varIdx]
        if not vd then
            nvState.active = false
        else
            if not nvEntry or not IsValid(nvEntry) then
                local currentText = ""
                if nvState.field == "name" then currentText = vd.name or ""
                elseif nvState.field == "iname" then currentText = (vd.internalName and not vd.internalName:match("^n_var_")) and vd.internalName or ""
                elseif nvState.field == "val" then currentText = tostring(vd.initialValue or 0) end

                local entry = vgui.Create("DTextEntry")
                entry:SetPos(nvState.x, nvState.y)
                entry:SetSize(nvState.w, nvState.h)
                entry:SetText(currentText)
                entry:SetCaretPos(#currentText)
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil
                entry:MakePopup()

                entry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    if INE.NumVarFieldState and INE.NumVarFieldState.active then
                        local e = INE.Editors[INE.NumVarFieldState.editorID]
                        local v = e and (e.variables["n"] or {})[INE.NumVarFieldState.varIdx]
                        if v then
                            local f = INE.NumVarFieldState.field
                            if f == "name" then v.name = txt
                            elseif f == "iname" then v.internalName = txt
                            elseif f == "val" then
                                local num = tonumber(txt)
                                v.initialValue = (num ~= nil) and num or txt
                            end
                        end
                    end
                end

                entry.OnKeyCodeTyped = function(self, keyCode)
                    if keyCode == KEY_ESCAPE then
                        if INE.NumVarFieldState then
                            INE.NumVarFieldState.active = false
                        end
                    end
                end

                INE.NumVarTextEntry = entry
            else
                -- 更新位置（对话框位置可能不变，但确保同步）
                nvEntry:SetPos(nvState.x, nvState.y)
                nvEntry:SetSize(nvState.w, nvState.h)
                -- 同步文本：切换字段（name↔iname↔val）时 DTextEntry 残留旧字段文本
                local ed2 = INE.Editors[nvState.editorID]
                local vd2 = ed2 and (ed2.variables["n"] or {})[nvState.varIdx]
                if vd2 then
                    local expected = ""
                    if nvState.field == "name" then expected = vd2.name or ""
                    elseif nvState.field == "iname" then expected = (vd2.internalName and not vd2.internalName:match("^n_var_")) and vd2.internalName or ""
                    elseif nvState.field == "val" then expected = tostring(vd2.initialValue or 0) end
                    if nvEntry:GetText() ~= expected then
                        nvEntry:SetText(expected)
                        nvEntry:SetCaretPos(#expected)
                    end
                end
                if not nvEntry:HasFocus() then
                    nvEntry:MakePopup()
                end
            end
        end
    else
        if nvEntry and IsValid(nvEntry) then
            nvEntry:Remove()
        end
        INE.NumVarTextEntry = nil
    end

    -- ============================================================
    -- 函数变量对话框 DTextEntry 生命周期管理（函数名称）
    -- ============================================================
    local fvState = INE.FuncVarFieldState
    local fvEntry = INE.FuncVarTextEntry
    if fvState.active then
        local ed = INE.Editors[fvState.editorID]
        local vd = ed and (ed.variables["f"] or {})[fvState.varIdx]
        if not vd then
            fvState.active = false
        else
            if not fvEntry or not IsValid(fvEntry) then
                local entry = vgui.Create("DTextEntry")
                entry:SetPos(fvState.x, fvState.y)
                entry:SetSize(fvState.w, fvState.h)
                entry:SetText(fvState.text or "")
                entry:SetCaretPos(#(fvState.text or ""))
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil
                entry:MakePopup()

                entry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    if INE.FuncVarFieldState and INE.FuncVarFieldState.active then
                        INE.FuncVarFieldState.text = txt
                        local e = INE.Editors[INE.FuncVarFieldState.editorID]
                        local v = e and (e.variables["f"] or {})[INE.FuncVarFieldState.varIdx]
                        if v then
                            v.name = txt
                        end
                    end
                end

                entry.OnKeyCodeTyped = function(self, keyCode)
                    if keyCode == KEY_ESCAPE and INE.FuncVarFieldState then
                        INE.FuncVarFieldState.active = false
                    end
                end

                INE.FuncVarTextEntry = entry
            else
                fvEntry:SetPos(fvState.x, fvState.y)
                fvEntry:SetSize(fvState.w, fvState.h)
                if not fvEntry:HasFocus() then
                    fvEntry:MakePopup()
                end
            end
        end
    else
        if fvEntry and IsValid(fvEntry) then
            fvEntry:Remove()
        end
        INE.FuncVarTextEntry = nil
    end

    -- ============================================================
    -- 函数变量对话框 DTextEntry 生命周期管理（参数添加）
    -- ============================================================
    local fpState = INE.FuncParamFieldState
    local fpEntry = INE.FuncParamTextEntry
    if fpState.active then
        local ed = INE.Editors[fpState.editorID]
        local vd = ed and (ed.variables["f"] or {})[fpState.varIdx]
        if not vd then
            fpState.active = false
        else
            if not fpEntry or not IsValid(fpEntry) then
                local entry = vgui.Create("DTextEntry")
                entry:SetPos(fpState.x, fpState.y)
                entry:SetSize(fpState.w, fpState.h)
                entry:SetText(fpState.text or "")
                entry:SetCaretPos(#(fpState.text or ""))
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil
                entry:MakePopup()

                entry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    if INE.FuncParamFieldState and INE.FuncParamFieldState.active then
                        INE.FuncParamFieldState.text = txt
                    end
                end

                entry.OnKeyCodeTyped = function(self, keyCode)
                    if keyCode == KEY_ESCAPE and INE.FuncParamFieldState then
                        INE.FuncParamFieldState.active = false
                    end
                end

                INE.FuncParamTextEntry = entry
            else
                fpEntry:SetPos(fpState.x, fpState.y)
                fpEntry:SetSize(fpState.w, fpState.h)
                if not fpEntry:HasFocus() then
                    fpEntry:MakePopup()
                end
            end
        end
    else
        if fpEntry and IsValid(fpEntry) then
            fpEntry:Remove()
        end
        INE.FuncParamTextEntry = nil
    end

    -- ============================================================
    -- 数组变量对话框 DTextEntry 生命周期管理
    -- ============================================================
    local avState = INE.ArrayVarFieldState
    local avEntry = INE.ArrayVarTextEntry
    if avState.active then
        local ed = INE.Editors[avState.editorID]
        local vd = ed and (ed.variables["g"] or {})[avState.varIdx]
        if not vd then
            avState.active = false
        else
            if not avEntry or not IsValid(avEntry) then
                local currentText = ""
                if avState.field == "name" then currentText = vd.name or ""
                elseif avState.field == "iname" then currentText = (vd.internalName and not vd.internalName:match("^g_var_")) and vd.internalName or ""
                elseif avState.field == "val_n" or avState.field == "val_t" then currentText = tostring(INE.ArrayVarItemValue or "") end

                local entry = vgui.Create("DTextEntry")
                entry:SetPos(avState.x, avState.y)
                entry:SetSize(avState.w, avState.h)
                entry:SetText(currentText)
                entry:SetCaretPos(#currentText)
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil
                entry:MakePopup()

                entry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    if INE.ArrayVarFieldState and INE.ArrayVarFieldState.active then
                        local e = INE.Editors[INE.ArrayVarFieldState.editorID]
                        local v = e and (e.variables["g"] or {})[INE.ArrayVarFieldState.varIdx]
                        if v then
                            local f = INE.ArrayVarFieldState.field
                            if f == "name" then v.name = txt
                            elseif f == "iname" then v.internalName = txt
                            elseif f == "val_n" or f == "val_t" then INE.ArrayVarItemValue = txt
                            end
                        end
                    end
                end

                entry.OnKeyCodeTyped = function(self, keyCode)
                    if keyCode == KEY_ESCAPE then
                        if INE.ArrayVarFieldState then
                            INE.ArrayVarFieldState.active = false
                        end
                    end
                end

                INE.ArrayVarTextEntry = entry
            else
                avEntry:SetPos(avState.x, avState.y)
                avEntry:SetSize(avState.w, avState.h)
                -- 同步文本：切换字段（name↔iname↔val）时 DTextEntry 残留旧字段文本
                local ed2 = INE.Editors[avState.editorID]
                local vd2 = ed2 and (ed2.variables["g"] or {})[avState.varIdx]
                if vd2 then
                    local expected = ""
                    if avState.field == "name" then expected = vd2.name or ""
                    elseif avState.field == "iname" then expected = (vd2.internalName and not vd2.internalName:match("^g_var_")) and vd2.internalName or ""
                    elseif avState.field == "val_n" or avState.field == "val_t" then expected = tostring(INE.ArrayVarItemValue or "") end
                    if avEntry:GetText() ~= expected then
                        avEntry:SetText(expected)
                        avEntry:SetCaretPos(#expected)
                    end
                end
                if not avEntry:HasFocus() then
                    avEntry:MakePopup()
                end
            end
        end
    else
        if avEntry and IsValid(avEntry) then
            avEntry:Remove()
        end
        INE.ArrayVarTextEntry = nil
    end

    -- ============================================================
    -- 卡牌对象变量对话框 DTextEntry 生命周期管理
    -- ============================================================
    local cvState = INE.CardVarFieldState
    local cvEntry = INE.CardVarTextEntry
    if cvState.active then
        local ed = INE.Editors[cvState.editorID]
        local vd = ed and (ed.variables["e"] or {})[cvState.varIdx]
        if not vd then
            cvState.active = false
        else
            if not cvEntry or not IsValid(cvEntry) then
                local currentText = ""
                if cvState.field == "name" then currentText = vd.name or ""
                elseif cvState.field == "iname" then currentText = vd.internalName or "" end

                local entry = vgui.Create("DTextEntry")
                entry:SetPos(cvState.x, cvState.y)
                entry:SetSize(cvState.w, cvState.h)
                entry:SetText(currentText)
                entry:SetCaretPos(#currentText)
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil
                entry:MakePopup()

                entry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    if INE.CardVarFieldState and INE.CardVarFieldState.active then
                        local e = INE.Editors[INE.CardVarFieldState.editorID]
                        local v = e and (e.variables["e"] or {})[INE.CardVarFieldState.varIdx]
                        if v then
                            local f = INE.CardVarFieldState.field
                            if f == "name" then v.name = txt
                            elseif f == "iname" then v.internalName = txt
                            end
                        end
                    end
                end

                entry.OnKeyCodeTyped = function(self, keyCode)
                    if keyCode == KEY_ESCAPE then
                        if INE.CardVarFieldState then
                            INE.CardVarFieldState.active = false
                        end
                    end
                end

                INE.CardVarTextEntry = entry
            else
                cvEntry:SetPos(cvState.x, cvState.y)
                cvEntry:SetSize(cvState.w, cvState.h)
                -- 同步文本：切换字段（name↔iname）时 DTextEntry 残留旧字段文本
                local ed2 = INE.Editors[cvState.editorID]
                local vd2 = ed2 and (ed2.variables["e"] or {})[cvState.varIdx]
                if vd2 then
                    local expected = ""
                    if cvState.field == "name" then expected = vd2.name or ""
                    elseif cvState.field == "iname" then expected = vd2.internalName or "" end
                    if cvEntry:GetText() ~= expected then
                        cvEntry:SetText(expected)
                        cvEntry:SetCaretPos(#expected)
                    end
                end
                if not cvEntry:HasFocus() then
                    cvEntry:MakePopup()
                end
            end
        end
    else
        if cvEntry and IsValid(cvEntry) then
            cvEntry:Remove()
        end
        INE.CardVarTextEntry = nil
    end

    -- ============================================================
    -- 字符串变量对话框 DTextEntry 生命周期管理
    -- ============================================================
    local svState = INE.StringVarFieldState
    local svEntry = INE.StringVarTextEntry
    if svState.active then
        -- 检查编辑器/变量是否仍有效
        local ed = INE.Editors[svState.editorID]
        local vd = ed and (ed.variables["t"] or {})[svState.varIdx]
        if not vd then
            svState.active = false
        else
            if not svEntry or not IsValid(svEntry) then
                local currentText = ""
                if svState.field == "name" then currentText = vd.name or ""
                elseif svState.field == "iname" then currentText = (vd.internalName and not vd.internalName:match("^t_var_")) and vd.internalName or ""
                elseif svState.field == "text" then currentText = vd.initialValue or "" end

                local entry = vgui.Create("DTextEntry")
                entry:SetPos(svState.x, svState.y)
                entry:SetSize(svState.w, svState.h)
                entry:SetText(currentText)
                entry:SetCaretPos(#currentText)
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil
                entry:MakePopup()

                entry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    if INE.StringVarFieldState and INE.StringVarFieldState.active then
                        local e = INE.Editors[INE.StringVarFieldState.editorID]
                        local v = e and (e.variables["t"] or {})[INE.StringVarFieldState.varIdx]
                        if v then
                            local f = INE.StringVarFieldState.field
                            if f == "name" then v.name = txt
                            elseif f == "iname" then v.internalName = txt
                            elseif f == "text" then v.initialValue = txt
                            end
                        end
                    end
                end

                entry.OnKeyCodeTyped = function(self, keyCode)
                    if keyCode == KEY_ESCAPE then
                        if INE.StringVarFieldState then
                            INE.StringVarFieldState.active = false
                        end
                    end
                end

                INE.StringVarTextEntry = entry
            else
                -- 更新位置
                svEntry:SetPos(svState.x, svState.y)
                svEntry:SetSize(svState.w, svState.h)
                -- 同步文本：切换字段时 DTextEntry 残留旧字段文本
                local ed2 = INE.Editors[svState.editorID]
                local vd2 = ed2 and (ed2.variables["t"] or {})[svState.varIdx]
                if vd2 then
                    local expected = ""
                    if svState.field == "name" then expected = vd2.name or ""
                    elseif svState.field == "iname" then expected = (vd2.internalName and not vd2.internalName:match("^t_var_")) and vd2.internalName or ""
                    elseif svState.field == "text" then expected = vd2.initialValue or "" end
                    if svEntry:GetText() ~= expected then
                        svEntry:SetText(expected)
                        svEntry:SetCaretPos(#expected)
                    end
                end
                if not svEntry:HasFocus() then
                    svEntry:MakePopup()
                end
            end
        end
    else
        if svEntry and IsValid(svEntry) then
            svEntry:Remove()
        end
        INE.StringVarTextEntry = nil
    end

    -- ============================================================
    -- 布尔值变量对话框 DTextEntry 生命周期管理
    -- ============================================================
    local bvState = INE.BoolVarFieldState
    local bvEntry = INE.BoolVarTextEntry
    if bvState.active then
        local ed = INE.Editors[bvState.editorID]
        local vd = ed and (ed.variables["p"] or {})[bvState.varIdx]
        if not vd then
            bvState.active = false
        else
            if not bvEntry or not IsValid(bvEntry) then
                local currentText = ""
                if bvState.field == "name" then currentText = vd.name or ""
                elseif bvState.field == "iname" then currentText = (vd.internalName and not vd.internalName:match("^p_var_")) and vd.internalName or "" end

                local entry = vgui.Create("DTextEntry")
                entry:SetPos(bvState.x, bvState.y)
                entry:SetSize(bvState.w, bvState.h)
                entry:SetText(currentText)
                entry:SetCaretPos(#currentText)
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil
                entry:MakePopup()

                entry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    if INE.BoolVarFieldState and INE.BoolVarFieldState.active then
                        local e = INE.Editors[INE.BoolVarFieldState.editorID]
                        local v = e and (e.variables["p"] or {})[INE.BoolVarFieldState.varIdx]
                        if v then
                            local f = INE.BoolVarFieldState.field
                            if f == "name" then v.name = txt
                            elseif f == "iname" then v.internalName = txt
                            end
                        end
                    end
                end

                entry.OnKeyCodeTyped = function(self, keyCode)
                    if keyCode == KEY_ESCAPE then
                        if INE.BoolVarFieldState then
                            INE.BoolVarFieldState.active = false
                        end
                    end
                end

                INE.BoolVarTextEntry = entry
            else
                bvEntry:SetPos(bvState.x, bvState.y)
                bvEntry:SetSize(bvState.w, bvState.h)
                local ed2 = INE.Editors[bvState.editorID]
                local vd2 = ed2 and (ed2.variables["p"] or {})[bvState.varIdx]
                if vd2 then
                    local expected = ""
                    if bvState.field == "name" then expected = vd2.name or ""
                    elseif bvState.field == "iname" then expected = (vd2.internalName and not vd2.internalName:match("^p_var_")) and vd2.internalName or "" end
                    if bvEntry:GetText() ~= expected then
                        bvEntry:SetText(expected)
                        bvEntry:SetCaretPos(#expected)
                    end
                end
                if not bvEntry:HasFocus() then
                    bvEntry:MakePopup()
                end
            end
        end
    else
        if bvEntry and IsValid(bvEntry) then
            bvEntry:Remove()
        end
        INE.BoolVarTextEntry = nil
    end

    -- 手动追踪鼠标左键按下的跨帧状态（比 input.WasMousePressed 更可靠）
    local mouseWasDown = INE._mouseButtonPrevDown or false
    INE._mouseButtonPrevDown = input.IsMouseDown(MOUSE_LEFT)
    local mouseJustPressed = not mouseWasDown and INE._mouseButtonPrevDown

    -- 预扫描：在所有编辑器 HandleInput 之前，检查是否有可拖动面板正要被标题栏拖拽
    -- 这样即使父编辑器在遍历中排在前面（子编辑器在后再插入），也能在鼠标按下的同一帧阻止其交互
    local draggedEditorID = nil
    for _, ed in pairs(INE.Editors) do
        if ed.draggable and not ed.borderless and not ed._titleDragging then
            local mx, my = gui.MouseX(), gui.MouseY()
            local onTitleBar = mx >= ed.x and mx <= ed.x + ed.width - 35 and
                               my >= ed.y and my <= ed.y + 35
            if onTitleBar and mouseJustPressed then
                ed._titleDragging = true
                ed._titleDragStartX = mx
                ed._titleDragStartY = my
                ed._titleDragStartEditorX = ed.x
                ed._titleDragStartEditorY = ed.y
                draggedEditorID = ed.id
            end
        end
    end

    for id, editor in pairs(INE.Editors) do
        if not editor.hidden then
            local mouseX, mouseY = gui.MouseX(), gui.MouseY()
            -- 检测鼠标是否在任何可见函数子编辑器区域内（不论视图模式），若是则非子编辑器一律阻止鼠标交互
            local mouseBlockedBySubEditor = false
            if not editor._isFunctionSubEditor then
                for _, otherEditor in pairs(INE.Editors) do
                    if otherEditor._isFunctionSubEditor and not otherEditor.hidden then
                        if otherEditor.x and otherEditor.y and otherEditor.width and otherEditor.height and
                           mouseX >= otherEditor.x and mouseX <= otherEditor.x + otherEditor.width and
                           mouseY >= otherEditor.y and mouseY <= otherEditor.y + otherEditor.height then
                            mouseBlockedBySubEditor = true
                            break
                        end
                    end
                end
            end

            -- 检测是否有函数子面板正在被拖动，若是则阻止所有非被拖面板的鼠标交互（预扫+实时检测）
            local mouseBlockedByTitleDrag = draggedEditorID ~= nil and id ~= draggedEditorID
            if not mouseBlockedByTitleDrag and draggedEditorID == nil then
                for _, otherEditor in pairs(INE.Editors) do
                    if otherEditor._titleDragging then
                        mouseBlockedByTitleDrag = id ~= otherEditor.id
                        break
                    end
                end
            end
            
            if editor._findNodeWindowOpen then
                if editor.overlayWindows and not editor.overlayWindows["find_node_window"] then
                    INE:OpenFindNodeWindow(editor)
                end
                
                local ch = INE:ReadKeyboardChar(editor)
                if ch then
                    editor._findNodeSearchText = (editor._findNodeSearchText or "") .. ch
                    editor._findNodeSelectedIndex = 0
                end
                
                if input.IsKeyDown(KEY_ESCAPE) and not editor._findNodeEscPressed then
                    INE:CloseOverlayWindow(editor, "find_node_window")
                    editor._findNodeEscPressed = true
                end
                if not input.IsKeyDown(KEY_ESCAPE) then
                    editor._findNodeEscPressed = false
                end
                
                if input.IsKeyDown(KEY_BACKSPACE) and not editor._findNodeBackspacePressed then
                    editor._findNodeSearchText = string.sub(editor._findNodeSearchText or "", 1, -2)
                    editor._findNodeSelectedIndex = 0
                    editor._findNodeBackspacePressed = true
                end
                if not input.IsKeyDown(KEY_BACKSPACE) then
                    editor._findNodeBackspacePressed = false
                end
                
                local filteredNodes = INE:GetFilteredNodeList(editor)
                if input.IsKeyDown(KEY_UP) and not editor._findNodeUpPressed then
                    editor._findNodeSelectedIndex = math.max(1, (editor._findNodeSelectedIndex or 1) - 1)
                    editor._findNodeUpPressed = true
                end
                if not input.IsKeyDown(KEY_UP) then editor._findNodeUpPressed = false end
                if input.IsKeyDown(KEY_DOWN) and not editor._findNodeDownPressed then
                    editor._findNodeSelectedIndex = math.min(#filteredNodes, (editor._findNodeSelectedIndex or 0) + 1)
                    editor._findNodeDownPressed = true
                end
                if not input.IsKeyDown(KEY_DOWN) then editor._findNodeDownPressed = false end
                
                if input.IsKeyDown(KEY_ENTER) and not editor._findNodeEnterPressed then
                    editor._findNodeEnterPressed = true
                    local selectedIdx = editor._findNodeSelectedIndex or 0
                    if selectedIdx >= 1 and selectedIdx <= #filteredNodes then
                        local node = filteredNodes[selectedIdx]
                        INE:CenterViewOn(editor, node.x + node.width/2, node.y + node.height/2)
                        editor.selectedNodes = {node}
                        INE:CloseOverlayWindow(editor, "find_node_window")
                    end
                end
                if not input.IsKeyDown(KEY_ENTER) then editor._findNodeEnterPressed = false end
            end
            
            -- 若函数子面板正在被拖动，或鼠标位于函数子编辑器区域内，阻止非子编辑器的所有鼠标交互
            if mouseBlockedByTitleDrag or mouseBlockedBySubEditor then
                editor._mouseOverOverlayWindow = true
            end

            INE:UpdateNotifications(editor)
            if not mouseBlockedByTitleDrag and not mouseBlockedBySubEditor then
                INE:HandleInput(editor)
            end
        end
    end

    -- ============================================================
    -- 文本槽内联输入 DTextEntry 生命周期管理（2026-10-04 新增）
    -- 「抉择」等模板 <> 文本槽：直接输入模式下点击值区激活，透明 DTextEntry 捕获
    -- IME/键盘输入（与上方各变量对话框输入框同方案），OnTextChanged 写回统一槽与扁平键。
    -- ============================================================
    local tsState = INE.TextSlotEditState
    local tsEntry = INE.TextSlotTextEntry
    if tsState.active and tsState.node and tsState.compId then
        -- 校验节点仍有效（可能被删除）且组件仍属该节点配置
        local ed = tsState.node.editor
        local nodeExists = false
        if ed and ed.nodes then
            for _, n in ipairs(ed.nodes) do
                if n == tsState.node then nodeExists = true break end
            end
        end
        if not nodeExists then
            tsState.active = false
        elseif not tsEntry or not IsValid(tsEntry) then
            local entry = vgui.Create("DTextEntry")
            entry:SetPos(tsState.x, tsState.y)
            entry:SetSize(tsState.w, tsState.h)
            entry:SetText(tsState.text or "")
            entry:SetCaretPos(#(tsState.text or ""))
            entry:SetDrawBackground(false)
            entry:SetDrawBorder(false)
            entry:SetTextColor(Color(255, 255, 255, 0))
            entry:SetCursorColor(Color(255, 255, 255, 0))
            entry.Paint = nil
            entry:MakePopup()

            entry.OnTextChanged = function(self)
                local txt = self:GetText()
                local st = INE.TextSlotEditState
                if not (st and st.active and st.node and st.compId) then return end
                st.text = txt
                local node = st.node
                local data = node.data
                if not data then return end
                data[st.compId] = txt
                data.slots = data.slots or {}
                local slot = data.slots[st.compId]
                if not slot then
                    slot = INE.GetOrCreateSlotData("text", node, st.compId, txt)
                end
                slot.mode = "literal"
                slot.literalValue = txt
                slot.variableRef = nil
            end

            entry.OnKeyCodeTyped = function(self, keyCode)
                if keyCode == KEY_ESCAPE or keyCode == KEY_ENTER then
                    if INE.TextSlotEditState then INE.TextSlotEditState.active = false end
                end
            end

            INE.TextSlotTextEntry = entry
        else
            -- 跟随节点拖动 / 缩放更新位置与尺寸
            tsEntry:SetPos(tsState.x, tsState.y)
            tsEntry:SetSize(tsState.w, tsState.h)
            if not tsEntry:HasFocus() then
                tsEntry:MakePopup()
            end
        end
    else
        if tsEntry and IsValid(tsEntry) then
            tsEntry:Remove()
        end
        INE.TextSlotTextEntry = nil
    end
end

--[[
    处理单个编辑器的鼠标和键盘输入。
    支持以下交互：
      - 关闭按钮点击
      - 节点选择面板点击拖拽创建节点
      - 中键拖拽平移画布
      - 左键点击节点=选中输出点（一次只选中一个）
      - 已选中输出点时，再次点击有输入点的节点=建立连接
      - 已选中输出点时，点击非输入节点=取消选择
      - 空白处拖拽进行框选
      - Delete键删除选中节点
      - Shift+点击多选/取消多选节点
    
    @param  editor  {table}   编辑器实例对象
]]


--[[
    判断一个点是否在矩形区域内（碰撞检测工具函数）。
    
    @param  px    {number}  点的X坐标（屏幕坐标）
    @param  py    {number}  点的Y坐标（屏幕坐标）
    @param  rect  {table}   矩形区域 {x, y, w, h}
    
    @return {boolean} 点在矩形内返回true，否则返回false
]]
function INE:IsPointInRect(px, py, rect)
    return px >= rect.x and px <= rect.x + rect.w and py >= rect.y and py <= rect.y + rect.h
end

--[[
    判断点是否在圆形内。
    用于检测鼠标是否悬停在圆形按钮或数据点上。
    
    @param  px      {number}  点X坐标
    @param  py      {number}  点Y坐标
    @param  cx      {number}  圆心X坐标
    @param  cy      {number}  圆心Y坐标
    @param  radius  {number}  圆半径
    
    @return {boolean} 点在圆内返回true，否则返回false
]]
function INE:IsPointInCircle(px, py, cx, cy, radius)
    local dx = px - cx
    local dy = py - cy
    return (dx * dx + dy * dy) <= (radius * radius)
end

--[[
    判断鼠标是否在节点的标题栏区域。
    标题栏高度为 24px（乘以画布缩放后的屏幕坐标）。
    开始点（isStartNode）没有标题栏，始终返回 false。
    
    @param  editor  {table}   编辑器实例对象
    @param  node    {table}   节点实例
    @param  mouseX  {number}  鼠标X坐标（屏幕坐标）
    @param  mouseY  {number}  鼠标Y坐标（屏幕坐标）
    
    @return {boolean} 鼠标在标题栏区域内返回 true
]]
function INE:IsMouseOnNodeTitle(editor, node, mouseX, mouseY)
    if node.isStartNode then return false end
    local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
    local nodeW = node.width * editor.canvasScale
    local titleH = 24 * editor.canvasScale
    return mouseX >= nodeX and mouseX <= nodeX + nodeW and
           mouseY >= nodeY and mouseY <= nodeY + titleH
end

--[[
    检测鼠标是否在节点的内容区域（标题栏下方、非端口区域）。
    用于区分"点击节点体选中输出点"与"拖拽连线从端口开始"。
    
    @param  editor  {table}   编辑器实例对象
    @param  node    {table}   要检测的节点
    @param  mouseX  {number}  鼠标屏幕X坐标
    @param  mouseY  {number}  鼠标屏幕Y坐标
    
    @return {boolean} 是否在节点内容区域
]]
function INE:IsMouseOnNodeBody(editor, node, mouseX, mouseY)
    if node.isStartNode then return false end
    local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
    local nodeW = node.width * editor.canvasScale
    local nodeH = node.height * editor.canvasScale
    local titleH = 24 * editor.canvasScale
    return mouseX >= nodeX + 20 * editor.canvasScale and mouseX <= nodeX + nodeW - 20 * editor.canvasScale and
           mouseY >= nodeY + titleH and mouseY <= nodeY + nodeH - 20 * editor.canvasScale
end

--[[
    根据节点ID在编辑器中查找节点实例。
    
    @param  editor  {table}   编辑器实例对象
    @param  nodeID  {string}  要查找的节点ID
    
    @return {table|nil} 找到的节点实例，未找到返回nil
]]
function INE:GetNodeByID(editor, nodeID)
    for _, node in ipairs(editor.nodes) do
        if node.id == nodeID then
            return node
        end
    end
    return nil
end

--[[
    获取指定屏幕坐标处的数据点（用于数据连接拖拽释放检测）。
    根据拖拽的数据点类型，检测相反类型的数据点（输出拖到输入，输入拖到输出）。

    @param  editor      {table}   编辑器实例对象
    @param  screenX     {number}  屏幕X坐标
    @param  screenY     {number}  屏幕Y坐标
    @param  fromType    {string}  拖拽起点类型 ("output" 或 "input")

    @return {table|nil} 命中的数据点信息 {node, portData, portType, portIndex}，未命中返回nil
]]
function INE:GetDataPortAtPosition(editor, screenX, screenY, fromType)
    -- 根据拖拽起点类型，检测相反类型的数据点
    local targetType = (fromType == "output") and "input" or "output"
    local clickPadding = 4 * editor.canvasScale  -- 点击容差

    -- 逆序遍历节点：后创建/后绘制的节点在上层，优先检测
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        if not node.isUnregistered then
            if targetType == "input" and node._inputDataPortPositions then
                for j, portPos in ipairs(node._inputDataPortPositions) do
                    local clickRadius = (portPos.radius or 0) + clickPadding
                    if self:IsPointInCircle(screenX, screenY, portPos.x, portPos.y, clickRadius) then
                        return {
                            node = node,
                            portData = portPos.data,
                            portType = "input",
                            portIndex = j
                        }
                    end
                end
            elseif targetType == "output" and node._outputDataPortPositions then
                for j, portPos in ipairs(node._outputDataPortPositions) do
                    local clickRadius = (portPos.radius or 0) + clickPadding
                    if self:IsPointInCircle(screenX, screenY, portPos.x, portPos.y, clickRadius) then
                        return {
                            node = node,
                            portData = portPos.data,
                            portType = "output",
                            portIndex = j
                        }
                    end
                end
            end
        end
    end
    return nil
end

--[[
    获取指定屏幕坐标处的节点（从上到下逆序遍历，优先返回最上层节点）。

    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标

    @return {table|nil} 命中的节点实例，未命中返回nil
]]
function INE:GetNodeAtPosition(editor, screenX, screenY)
    -- 逆序遍历：后创建/后绘制的节点在上层，优先检测
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        -- 跳过开始点节点（只能通过端口圆点选中，不由 GetNodeAtPosition 处理）
        if not node.isStartNode then
            local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
            local nodeW = node.width * editor.canvasScale
            local nodeH = node.height * editor.canvasScale

            if screenX >= nodeX and screenX <= nodeX + nodeW and
               screenY >= nodeY and screenY <= nodeY + nodeH then
                return node
            end
        end
    end
    return nil
end

--[[
    检测屏幕坐标是否在某个节点的"添加数据点"按钮（绿色/深蓝色圆形）上。
    数据点按钮位于节点边线上，半径超出节点边界。
    用于在 GetNodeAtPosition 之前优先检测，确保点击数据点按钮能正确触发。

    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标

    @return {table|nil} 命中的节点实例（数据点按钮属于该节点），未命中返回nil
]]
function INE:GetDataPortButtonNodeAtPosition(editor, screenX, screenY)
    -- 逆序遍历：后创建的节点在上层
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        if not node.isStartNode then
            -- 检查输出数据点按钮（绿色"+"号）
            if node._dataPortButtonRect then
                if self:IsPointInRect(screenX, screenY, node._dataPortButtonRect) then
                    return node
                end
            end
            -- 检查输入数据点按钮（深蓝色"+"号）
            if node._inputDataPortButtonRect then
                if self:IsPointInRect(screenX, screenY, node._inputDataPortButtonRect) then
                    return node
                end
            end
        end
    end
    return nil
end

--[[
    全局检测屏幕坐标是否在任意节点的数据点图标上（输出或输入）。
    数据点图标位于节点边线上，半径超出节点边界，GetNodeAtPosition 无法命中。
    需要在 GetNodeAtPosition 之前独立检测。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中的数据点信息 {node, portData, portType, portIndex}，未命中返回nil
]]
function INE:GetDataPortIconAtPosition(editor, screenX, screenY)
    local clickPadding = 4 * editor.canvasScale
    -- 逆序遍历：后创建/后绘制的节点在上层，优先检测
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        -- 允许开始点（含数据源开始点如"钳击对象"）的数据端口作为拖线起点；
        -- 普通开始点无数据端口，不受影响
        if not node.isUnregistered then
            -- 检测输出数据点
            if node._outputDataPortPositions then
                for j, portPos in ipairs(node._outputDataPortPositions) do
                    local clickRadius = (portPos.radius or 0) + clickPadding
                    if self:IsPointInCircle(screenX, screenY, portPos.x, portPos.y, clickRadius) then
                        return {
                            node = node,
                            portData = portPos.data,
                            portType = "output",
                            portIndex = j
                        }
                    end
                end
            end
            -- 检测输入数据点
            if node._inputDataPortPositions then
                for j, portPos in ipairs(node._inputDataPortPositions) do
                    local clickRadius = (portPos.radius or 0) + clickPadding
                    if self:IsPointInCircle(screenX, screenY, portPos.x, portPos.y, clickRadius) then
                        return {
                            node = node,
                            portData = portPos.data,
                            portType = "input",
                            portIndex = j
                        }
                    end
                end
            end
        end
    end
    return nil
end

--[[
    检测屏幕坐标是否在节点的交互式元素（下拉框、数字框）上。
    用于 HandleInput 中拦截点击，避免穿透到输出点选中逻辑。
    
    @param  editor   {table}   编辑器实例对象
    @param  node     {table}   要检测的节点
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {boolean} 点击在交互式元素上返回 true，否则返回 false
]]
function INE:GetNodeInteractiveElement(editor, node, screenX, screenY)
    -- 使用绘制阶段记录的交互元素包围盒进行命中检测，
    -- 避免重复布局逻辑导致的位置偏差。
    local rects = editor._interactiveRects
    if not rects then return false end
    
    for _, rect in ipairs(rects) do
        if rect.nodeId == node.id and
           screenX >= rect.x and screenX <= rect.x + rect.w and
           screenY >= rect.y and screenY <= rect.y + rect.h then
            return true
        end
    end
    return false
end

--[[
    检测屏幕坐标是否在指定节点的输出端口上。
    
    @param  editor   {table}   编辑器实例对象
    @param  node     {table}   要检测的节点
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {string|nil} 命中返回端口标识 "output"，未命中返回nil
]]
function INE:GetOutputPortAtPosition(editor, node, screenX, screenY)
    if not node.hasOutput then return nil end
    
    local portR = 6 * editor.canvasScale
    local clickR = 24 * editor.canvasScale
    
    if node.hasSecondOutput then
        -- 双分支：检测两个端口
        local nodeScreenX, nodeScreenY = self:WorldToScreen(editor, node.x, node.y)
        local nodeW = node.width * editor.canvasScale
        local nodeH = node.height * editor.canvasScale
        local portScreenX = nodeScreenX + nodeW
        
        -- 满足分支（上）
        local topPortScreenY = nodeScreenY + nodeH / 3
        local dx = screenX - portScreenX
        local dy = screenY - topPortScreenY
        if dx * dx + dy * dy <= clickR * clickR then
            return "satisfied"
        end
        
        -- 不满足分支（下）
        local botPortScreenY = nodeScreenY + nodeH * 2 / 3
        dy = screenY - botPortScreenY
        if dx * dx + dy * dy <= clickR * clickR then
            return "not_satisfied"
        end
        
        return nil
    else
        -- 单输出端口：圆形距离检测
        local portScreenX, portScreenY = self:WorldToScreen(editor, node.x + node.width, node.y + node.height / 2)
        local dx = screenX - portScreenX
        local dy = screenY - portScreenY
        if dx * dx + dy * dy <= clickR * clickR then
            return "output"
        end
        return nil
    end
end

--[[
    检测屏幕坐标是否在某个开始点节点的输出端口圆点上。
    开始点仅通过端口圆点（而非整个节点矩形）进行选中。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中的开始点节点实例，未命中返回nil
]]
function INE:GetStartNodeAtPort(editor, screenX, screenY)
    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        -- 数据源开始点（钳击对象）无执行输出端口，其中数据端口由 GetDataPortIconAtPosition 处理
        if node.isStartNode and node.name ~= "data_start_point" then
            local nodeX, nodeY = self:WorldToScreen(editor, node.x, node.y)
            local portR = 6 * editor.canvasScale
            local portCX = nodeX  -- 端口圆心在 Y 轴（node.x = 0）
            local portCY = nodeY + node.height * editor.canvasScale / 2  -- 端口圆心Y（垂直居中）

            -- 检测鼠标是否在端口圆点范围内（使用 24*scale 的圆形命中半径）
            local hitR = 24 * editor.canvasScale
            local dx = screenX - portCX
            local dy = screenY - portCY
            if dx * dx + dy * dy <= hitR * hitR then
                return node
            end
        end
    end
    return nil
end

--[[
    检测屏幕坐标是否在任意节点的输入端口上（返回节点，用于拖拽连线检测悬停）。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中输入端口的节点，未命中返回nil
]]
function INE:GetInputNodeAtPosition(editor, screenX, screenY)
    local hitR = 24 * editor.canvasScale

    for i = #editor.nodes, 1, -1 do
        local node = editor.nodes[i]
        if not node.isStartNode and node.hasInput then
            local portScreenX, portScreenY = self:WorldToScreen(editor, node.x, node.y + node.height / 2)
            local dx = screenX - portScreenX
            local dy = screenY - portScreenY
            if dx * dx + dy * dy <= hitR * hitR then
                return node
            end
        end
    end
    return nil
end

--[[
    检测屏幕坐标是否在任意节点的输入端口上。
    
    @param  editor   {table}   编辑器实例对象
    @param  screenX  {number}  屏幕X坐标
    @param  screenY  {number}  屏幕Y坐标
    
    @return {table|nil} 命中返回 {node = 目标节点}，未命中返回nil
]]
function INE:GetInputPortAtPosition(editor, screenX, screenY)
    local hitR = 24 * editor.canvasScale
    
    for _, node in ipairs(editor.nodes) do
        if node.hasInput then
            local portScreenX, portScreenY = self:WorldToScreen(editor, node.x, node.y + node.height / 2)
            local dx = screenX - portScreenX
            local dy = screenY - portScreenY
            if dx * dx + dy * dy <= hitR * hitR then
                return {node = node}
            end
        end
    end
    return nil
end

--[[
    从编辑器中移除指定节点及其所有关联的连接。
    
    @param  editor   {table}   编辑器实例对象
    @param  nodeID   {string}  要移除的节点ID
]]
function INE:RemoveNode(editor, nodeID)
    -- 先移除所有与该节点相关的连接（遍历连接表，删除引用该节点的连接）
    for i = #editor.connections, 1, -1 do
        local conn = editor.connections[i]
        if conn.fromNode == nodeID or conn.toNode == nodeID then
            table.remove(editor.connections, i)
        end
    end
    
    -- 移除所有与该节点相关的数据连接
    if editor.dataConnections then
        for i = #editor.dataConnections, 1, -1 do
            local dc = editor.dataConnections[i]
            if dc.fromNode == nodeID or dc.toNode == nodeID then
                table.remove(editor.dataConnections, i)
            end
        end
    end
    
    -- 如果已删除的节点在 selectedOutputs 中，清理引用
    if editor.selectedOutputs then
        local i = 1
        while i <= #editor.selectedOutputs do
            if editor.selectedOutputs[i].node.id == nodeID then
                table.remove(editor.selectedOutputs, i)
            else
                i = i + 1
            end
        end
    end
    
    -- 如果已删除的节点正在被拖拽，清理 draggingFrom
    if editor.draggingFrom and editor.draggingFrom.node.id == nodeID then
        editor.draggingFrom = nil
    end
    -- 如果已删除的节点是数据点拖拽源，清理 draggingDataPort
    if editor.draggingDataPort and editor.draggingDataPort.node.id == nodeID then
        editor.draggingDataPort = nil
    end
    
    -- 再从节点表中移除节点
    for i = #editor.nodes, 1, -1 do
        if editor.nodes[i].id == nodeID then
            table.remove(editor.nodes, i)
            return
        end
    end
end

--[[
    应用导入警告后的处理：根据用户确认导入数据。
    将待导入数据中的节点和连接加载到编辑器中，正确处理未注册节点
    和不属于当前面板的节点（标记为isInvalid或isUnregistered）。
    
    @param  editor  {table}   编辑器实例对象
]]
function INE:ApplyImportWarnings(editor)
    local warnings = editor.importWarnings
    local data = editor._pendingImportData
    
    if not data then
        editor.importWarnings = nil
        return
    end
    
    -- 清空编辑器现有内容
    editor.nodes = {}
    editor.connections = {}
    editor.selectedOutputs = {}
    editor.draggingFrom = nil
    editor.draggingDataPort = nil
    editor.dataConnections = {}
    
    -- 恢复画布视图状态
    if data.view then
        editor.canvasOffsetX = data.view.canvasOffsetX or 0
        editor.canvasOffsetY = data.view.canvasOffsetY or 0
        editor.canvasScale = math.Clamp(data.view.canvasScale or 1, INE.ZOOM_MIN, INE.ZOOM_MAX)
        editor.showCoordinates = data.view.showCoordinates
        if editor.showCoordinates == nil then
            editor.showCoordinates = false
        end
    else
        editor.canvasOffsetX = 0
        editor.canvasOffsetY = 0
        editor.canvasScale = 1
        editor.showCoordinates = false
    end
    
    -- 构建允许节点类型的快速查找表
    local allowedMap = {}
    for _, name in ipairs(editor.allowedNodes) do
        allowedMap[name] = true
    end
    
    -- 导入节点数据
    for _, nodeData in ipairs(data.nodes or {}) do
        local node
        if INE.RegisteredNodes[nodeData.name] then
            -- 节点类型已注册：正常创建实例
            node = INE:CreateNewNodeInstance(nodeData.name, editor, nodeData.x, nodeData.y)
            node.data = nodeData.data or {}
            -- 如果节点类型不属于当前面板的allowedNodes，标记为无效
            -- 基础变量操作节点为内置节点（template._varOpNode），任何面板均视为有效
            if not allowedMap[nodeData.name] and not (INE.RegisteredNodes[nodeData.name]._varOpNode) then
                node.isInvalid = true
                editor.hasInvalidNodes = true
            end
        else
            -- 节点类型未注册：创建占位节点（暗红色显示，不可交互）
            node = {
                id = INE:GenerateNodeID(),
                name = nodeData.name,
                type = nodeData.type or "unknown",
                color = Color(100, 50, 50),
                x = nodeData.x or 0,
                y = nodeData.y or 0,
                width = nodeData.width or 200,
                height = nodeData.height or 80,
                hasInput = nodeData.hasInput,
                hasOutput = nodeData.hasOutput,
                isStartNode = false,
                canDelete = true,
                data = nodeData.data or {},
                dragging = false,
                isUnregistered = true,
                editor = editor
            }
            editor.hasUnregisteredNodes = true
        end
        
        -- 保留原始节点ID（如果有），以维持连接引用
        node.id = nodeData.id or node.id
        table.insert(editor.nodes, node)
    end
    
    -- 导入连接数据（仅导入两端节点都存在的连接）
    for _, connData in ipairs(data.connections or {}) do
        local fromExists = INE:GetNodeByID(editor, connData.fromNode) ~= nil
        local toExists = INE:GetNodeByID(editor, connData.toNode) ~= nil
        if fromExists and toExists then
            table.insert(editor.connections, {
                id = connData.id or INE:GenerateConnectionID(),
                fromNode = connData.fromNode,
                toNode = connData.toNode,
                fromPort = connData.fromPort or "output"
            })
        end
    end
    
    -- 清除警告状态和待导入数据
    editor.importWarnings = nil
    editor._pendingImportData = nil
end

-- ====================================
-- 公共 API 函数（全局命名空间，可直接调用）
-- ====================================

--[[
    创建一个新的独立节点编辑器实例。
    如果指定ID已存在编辑器，会先关闭旧实例再创建新的。
    创建后编辑器立即激活并可见（除非hidden参数为true）。
    
    @param  panelID         {string}    编辑器唯一标识符，用于后续操作
    @param  pos             {table}     【可选】编辑器在屏幕上的位置和尺寸，格式：{x=number, y=number, width=number, height=number}
                                        默认值：{x=50, y=50, width=ScrW()-100, height=ScrH()-100}
    @param  scale           {number}    【可选】编辑器UI缩放比例，默认为1
    @param  allowedNodes    {table}     【可选】允许使用的节点类型名称数组，数组中的节点必须已通过LogNewNode注册
                                        其中isStartNode=true的节点会自动创建在画布上
    @param  hidden          {boolean}   【可选】创建后是否立即隐藏，默认为false
    @param  simplified      {boolean}   【可选】是否为简化模式（隐藏关闭按钮等UI元素），默认为false
    @param  borderless      {boolean}   【可选】是否为无边框模式（隐藏标题栏和节点选择面板，仅显示画布），默认为false
    @param  showTitleMenu    {boolean}   【可选】是否在标题栏显示标题功能菜单按钮，默认为false
    @param  editorMode      {string}    【可选】编辑器模式，决定自动创建哪些开始点，可选 "unit"/"command"/"counter_command"/"headquarter"，默认 "unit"
    @param  showCoordinates {boolean}   【可选】是否显示平面直角坐标系，默认为false
    @param  draggable       {boolean}   【可选】是否允许通过标题栏拖动面板位置，默认为false

    @return {table}         新创建的编辑器实例对象

    @usage  示例：
        -- 先注册普通节点类型
        LogNewNode({type="action", color=Color(80,120,200)}, "action_node")
        LogNewNode({type="end", color=Color(150,80,80), hasOutput=false}, "end_node")

        -- 创建单位模式编辑器（自动在 y 轴上创建抽取/部署/在场/阵亡/移除/弃牌开始点）
        local editor = CreateNewNodeEditor("my_editor", nil, 1, {"start_point", "action_node", "end_node"}, false, false, false, false, "unit")
]]
function CreateNewNodeEditor(panelID, pos, scale, allowedNodes, hidden, simplified, borderless, showTitleMenu, editorMode, showCoordinates, draggable)
    if not panelID then
        error("[IndependentNodeEditor] CreateNewNodeEditor: panelID 不能为 nil")
    end

    -- 验证所有允许的节点类型是否已注册
    for _, nodeName in ipairs(allowedNodes or {}) do
        if not INE.RegisteredNodes[nodeName] then
            error("[IndependentNodeEditor] 节点 '" .. tostring(nodeName) .. "' 未注册，请先使用 LogNewNode 注册")
        end
    end

    return INE:CreateEditor(panelID, pos, scale, allowedNodes, hidden, simplified, borderless, showTitleMenu, editorMode, showCoordinates, draggable)
end

--[[
    设置编辑器的显示/隐藏状态。
    隐藏的编辑器不会进行绘制和输入处理，但数据仍然保留。
    
    @param  panelID {string}    编辑器ID
    @param  hidden  {boolean}   true为隐藏，false为显示
    
    @return {boolean} 操作成功返回true，编辑器不存在返回false
]]
function SetNodeEditorHidden(panelID, hidden)
    local editor = INE.Editors[panelID]
    if not editor then return false end
    editor.hidden = hidden
    -- 级联设置函数子编辑器隐藏状态：父编辑器隐藏时子面板一并隐藏，
    -- 父编辑器恢复显示时已打开的子面板一并恢复（函数子编辑器由父编辑器管理生命周期）。
    if editor.functionSubEditors then
        for _, subID in pairs(editor.functionSubEditors) do
            local subEditor = INE.Editors[subID]
            if subEditor then
                subEditor.hidden = hidden
            end
        end
    end
    return true
end

--[[
    设置编辑器是否为简化模式。
    简化模式下隐藏关闭按钮等UI控件，适用于嵌入其他面板的场景。
    
    @param  panelID     {string}    编辑器ID
    @param  simplified  {boolean}   true为简化模式，false为正常模式
    
    @return {boolean} 操作成功返回true，编辑器不存在返回false
]]
function SetNodeEditorSimplified(panelID, simplified)
    local editor = INE.Editors[panelID]
    if not editor then return false end
    editor.simplified = simplified
    return true
end

--[[
    设置编辑器是否为无边框模式。
    无边框模式下隐藏标题栏、关闭按钮和左侧节点选择面板，仅显示纯画布区域，
    适用于需要自定义UI包裹的场景。
    
    @param  panelID     {string}    编辑器ID
    @param  borderless  {boolean}   true为无边框模式，false为正常模式
    
    @return {boolean} 操作成功返回true，编辑器不存在返回false
]]
function SetNodeEditorBorderless(panelID, borderless)
    local editor = INE.Editors[panelID]
    if not editor then return false end
    editor.borderless = borderless
    return true
end

--[[
    设置编辑器标题栏是否显示文件菜单按钮。
    
    @param  panelID {string}    编辑器ID
    @param  show    {boolean}   true显示文件菜单，false隐藏
    
    @return {boolean} 操作成功返回true，编辑器不存在返回false
]]
function SetNodeEditorShowTitleMenu(panelID, show)
    local editor = INE.Editors[panelID]
    if not editor then return false end
    editor.showTitleMenu = show
    return true
end

--[[
    设置编辑器是否显示平面直角坐标系。

    @param  panelID         {string}    编辑器ID
    @param  showCoordinates {boolean}   true显示坐标系，false隐藏

    @return {boolean} 操作成功返回true，编辑器不存在返回false
]]
function SetNodeEditorShowCoordinates(panelID, showCoordinates)
    local editor = INE.Editors[panelID]
    if not editor then return false end
    editor.showCoordinates = showCoordinates
    return true
end

--[[
    设置编辑器在屏幕上的位置和尺寸。
    
    @param  panelID {string}    编辑器ID
    @param  x       {number}    左上角X坐标（屏幕坐标）
    @param  y       {number}    左上角Y坐标（屏幕坐标）
    @param  width   {number}    【可选】编辑器宽度，不传则保持原宽度
    @param  height  {number}    【可选】编辑器高度，不传则保持原高度
    
    @return {boolean} 操作成功返回true，编辑器不存在返回false
]]
function SetNodeEditorPosition(panelID, x, y, width, height)
    local editor = INE.Editors[panelID]
    if not editor then return false end
    editor.x = x
    editor.y = y
    if width then editor.width = width end
    if height then editor.height = height end
    return true
end

--[[
    设置编辑器画布的缩放比例。
    注意：此缩放仅影响画布内容（节点、连线等），不影响编辑器面板本身。
    
    @param  panelID {string}    编辑器ID
    @param  scale   {number}    缩放比例，1.0为原始大小，0.5为缩小一半，2.0为放大一倍
    
    @return {boolean} 操作成功返回true，编辑器不存在返回false
]]
function SetNodeEditorScale(panelID, scale)
    local editor = INE.Editors[panelID]
    if not editor then return false end
    editor.canvasScale = scale
    return true
end

--[[
    关闭并销毁指定的编辑器实例。
    关闭后编辑器的所有数据（节点、连接等）将被清除。
    如果这是最后一个编辑器实例，相关的HUDPaint和Think钩子也会被移除。
    
    @param  panelID {string}    要关闭的编辑器ID
    
    @usage  示例：
        CloseNodeEditor("my_editor")
]]
function CloseNodeEditor(panelID)
    INE:CloseEditor(panelID)
end

--[[
    获取指定ID的编辑器实例对象。
    可用于直接访问编辑器的nodes、connections等数据进行自定义操作。
    
    @param  panelID {string}    编辑器ID
    
    @return {table|nil} 编辑器实例对象，不存在返回nil
    
    @usage  示例：
        local editor = GetNodeEditor("my_editor")
        if editor then
            PrintTable(editor.nodes)  -- 打印所有节点
        end
]]
function GetNodeEditor(panelID)
    return INE.Editors[panelID]
end

--[[
    获取当前激活的编辑器实例。
    "激活"指最后创建的编辑器，或用户最近操作的编辑器。
    
    @return {table|nil} 当前激活的编辑器实例，无激活编辑器时返回nil
]]
function GetActiveNodeEditor()
    if INE.ActiveEditorID then
        return INE.Editors[INE.ActiveEditorID]
    end
    return nil
end

--[[
    导出编辑器的节点和连接数据为可序列化的表。
    导出时会跳过标记为无效（isInvalid）和未注册（isUnregistered）的节点及相关连接。
    导出的数据可通过ImportNodeEditorData重新导入。
    
    @param  panelID {string}    编辑器ID
    
    @return {table|nil} 导出数据表，格式为 {nodes={...}, connections={...}}，编辑器不存在返回nil
    
    导出节点数据格式：
    {
        id = "ine_node_1",       -- 节点唯一ID
        name = "action_node",    -- 节点类型名称
        type = "action",         -- 节点类型标识
        x = 100,                 -- 画布X坐标
        y = 50,                  -- 画布Y坐标
        width = 200,             -- 节点宽度
        height = 80,             -- 节点高度
        hasInput = true,         -- 是否有输入端口
        hasOutput = true,        -- 是否有输出端口
        data = {...}             -- 节点自定义数据
    }
    
    导出连接数据格式：
    {
        id = "ine_conn_1",       -- 连接唯一ID
        fromNode = "ine_node_1", -- 起始节点ID
        toNode = "ine_node_2",   -- 目标节点ID
        fromPort = "output"      -- 输出端口标识
    }
    
    @usage  示例：
        local data = ExportNodeEditorData("my_editor")
        if data then
            local json = util.TableToJSON(data)  -- 序列化为JSON用于保存
            file.Write("node_data.json", json)
        end
]]
-- 命名空间前缀：所有用户内部变量在保存到文件时使用此前缀，避免与系统变量冲突
local INTERNAL_VAR_PREFIX = "KARDS.User."

-- 递归为变量的 internalName 添加 KARDS.User. 前缀（深拷贝，不修改原表）
function INE:PrefixInternalNames(vars)
    if type(vars) ~= "table" then return vars end
    local seen = {}
    local function deepCopy(t)
        if type(t) ~= "table" then return t end
        if seen[t] then return seen[t] end
        local r = {}
        seen[t] = r
        for k, v in pairs(t) do
            if k == "internalName" and type(v) == "string" and v ~= "" then
                if not v:find("^" .. INTERNAL_VAR_PREFIX) then
                    r[k] = INTERNAL_VAR_PREFIX .. v
                else
                    r[k] = v
                end
            elseif k == "items" and type(v) == "table" then
                r[k] = {}
                for i, item in ipairs(v) do
                    r[k][i] = deepCopy(item)
                end
            else
                r[k] = deepCopy(v)
            end
        end
        return r
    end
    return deepCopy(vars)
end

-- 递归去除 internalName 的 KARDS.User. 前缀（原地修改）
function INE:StripInternalNames(vars)
    if type(vars) ~= "table" then return end
    for _, typeList in pairs(vars) do
        if type(typeList) == "table" then
            for _, vd in ipairs(typeList) do
                if type(vd) == "table" then
                    if vd.internalName and type(vd.internalName) == "string" then
                        vd.internalName = vd.internalName:gsub("^" .. INTERNAL_VAR_PREFIX, "")
                    end
                    if vd.items and type(vd.items) == "table" then
                        for _, item in ipairs(vd.items) do
                            if type(item) == "table" then
                                if item.value and type(item.value) == "table" then
                                    INE:StripInternalNames({["_"] = item.value})
                                end
                                if item.functionData and type(item.functionData) == "table" and item.functionData.variables then
                                    INE:StripInternalNames(item.functionData.variables)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function ExportNodeEditorData(panelID)
    local editor = INE.Editors[panelID]
    if not editor then return nil end
    
    -- 导出有效节点（跳过无效和未注册节点）
    local nodes = {}
    for _, node in ipairs(editor.nodes) do
        if not node.isInvalid and not node.isUnregistered then
            table.insert(nodes, {
                id = node.id,
                name = node.name,
                type = node.type,
                x = node.x,
                y = node.y,
                width = node.width,
                height = node.height,
                hasInput = node.hasInput,
                hasOutput = node.hasOutput,
                hasSecondOutput = node.hasSecondOutput or false,
                data = node.data
            })
        end
    end
    
    -- 导出有效连接（两端节点都必须有效）
    local connections = {}
    for _, conn in ipairs(editor.connections) do
        local fromNode = INE:GetNodeByID(editor, conn.fromNode)
        local toNode = INE:GetNodeByID(editor, conn.toNode)
        if fromNode and toNode and not fromNode.isInvalid and not fromNode.isUnregistered and not toNode.isInvalid and not toNode.isUnregistered then
            table.insert(connections, {
                id = conn.id,
                fromNode = conn.fromNode,
                toNode = conn.toNode,
                fromPort = conn.fromPort
            })
        end
    end
    
    return {
        nodes = nodes,
        connections = connections,
        editorMode = editor.editorMode,
        view = {
            canvasOffsetX = editor.canvasOffsetX,
            canvasOffsetY = editor.canvasOffsetY,
            canvasScale = editor.canvasScale,
            showCoordinates = editor.showCoordinates
        }
    }
end

--[[
    导入节点和连接数据到编辑器。
    导入前会进行数据校验：
      - 若包含未注册的节点类型，显示警告对话框，用户确认后以红色占位节点导入
      - 若包含不属于当前编辑器allowedNodes的节点类型，显示警告对话框，用户确认后标记为无效
      - 正常数据直接导入，清空原有内容
    
    @param  panelID {string}    编辑器ID
    @param  data    {table}     要导入的数据表，格式同ExportNodeEditorData的返回值
    
    @return {boolean, string}   第一个返回值表示操作是否接受；第二个返回值为状态字符串：
                                - "success"：导入成功
                                - "warning_unregistered"：检测到未注册节点，等待用户确认
                                - "warning_invalid"：检测到不属于当前面板的节点，等待用户确认
                                - "编辑器不存在"：指定ID的编辑器不存在
                                - "无效的数据"：数据格式不正确
    
    @usage  示例：
        local json = file.Read("node_data.json", "DATA")
        local data = util.JSONToTable(json)
        local success, status = ImportNodeEditorData("my_editor", data)
        if success and status == "success" then
            print("导入成功！")
        end
]]
function ImportNodeEditorData(panelID, data)
    local editor = INE.Editors[panelID]
    if not editor then return false, "编辑器不存在" end
    
    if not data or not data.nodes then
        return false, "无效的数据"
    end
    
    -- 构建允许节点类型的快速查找表
    local allowedMap = {}
    for _, name in ipairs(editor.allowedNodes) do
        allowedMap[name] = true
    end
    
    -- 检测数据中是否有问题节点
    local hasInvalidButRegistered = false
    local hasUnregistered = false
    local invalidNodeNames = {}
    local unregisteredNodeNames = {}
    
    for _, nodeData in ipairs(data.nodes) do
        local nodeName = nodeData.name
        if INE.RegisteredNodes[nodeName] then
            -- 节点类型已注册但不属于当前面板
            -- 基础变量操作节点为内置节点（template._varOpNode），任何面板均视为有效
            if not allowedMap[nodeName] and not (INE.RegisteredNodes[nodeName]._varOpNode) then
                hasInvalidButRegistered = true
                table.insert(invalidNodeNames, nodeName)
            end
        else
            -- 节点类型完全未注册
            hasUnregistered = true
            table.insert(unregisteredNodeNames, nodeName)
        end
    end
    
    -- 发现未注册节点：显示警告并暂存数据等待用户确认
    if hasUnregistered then
        editor.importWarnings = {
            hasUnregistered = true,
            unregisteredNodes = unregisteredNodeNames,
            hasInvalid = false
        }
        editor._pendingImportData = data
        return true, "warning_unregistered"
    elseif hasInvalidButRegistered then
        -- 发现不属于当前面板的节点：显示警告并暂存数据等待用户确认
        editor.importWarnings = {
            hasUnregistered = false,
            invalidNodes = invalidNodeNames,
            hasInvalid = true
        }
        editor._pendingImportData = data
        return true, "warning_invalid"
    end
    
    -- 数据无问题：清空编辑器并导入
    editor.nodes = {}
    editor.connections = {}
    editor.selectedOutputs = {}
    editor.draggingFrom = nil
    editor.draggingDataPort = nil
    editor.dataConnections = {}
    
    -- 恢复编辑器模式（旧数据无此字段则保持当前模式）
    if data.editorMode and INE.StartNodeDefinitions[data.editorMode] then
        editor.editorMode = data.editorMode
    end
    
    -- 恢复画布视图状态
    if data.view then
        editor.canvasOffsetX = data.view.canvasOffsetX or 0
        editor.canvasOffsetY = data.view.canvasOffsetY or 0
        editor.canvasScale = math.Clamp(data.view.canvasScale or 1, INE.ZOOM_MIN, INE.ZOOM_MAX)
        editor.showCoordinates = data.view.showCoordinates
        if editor.showCoordinates == nil then
            editor.showCoordinates = false
        end
    else
        editor.canvasOffsetX = 0
        editor.canvasOffsetY = 0
        editor.canvasScale = 1
        editor.showCoordinates = false
    end
    
    for _, nodeData in ipairs(data.nodes) do
        local node = INE:CreateNewNodeInstance(nodeData.name, editor, nodeData.x, nodeData.y)
        node.id = nodeData.id or node.id  -- 保留原始ID以维持连接引用
        node.data = nodeData.data or {}
        table.insert(editor.nodes, node)
    end
    
    -- 检查加载的数据中是否已有开始点节点
    local hasLoadedStartPoint = false
    for _, nodeData in ipairs(data.nodes) do
        if nodeData.name == "start_point" then
            hasLoadedStartPoint = true
            break
        end
    end
    
    -- 只有加载的数据中没有开始点时，才自动创建（避免新ID导致连接引用失效）
    if not hasLoadedStartPoint then
        INE:CreateStartNodesForEditor(editor)
    end
    
    for _, connData in ipairs(data.connections or {}) do
        table.insert(editor.connections, {
            id = connData.id or INE:GenerateConnectionID(),
            fromNode = connData.fromNode,
            toNode = connData.toNode,
            fromPort = connData.fromPort or "output"
        })
    end
    
    return true, "success"
end

--[[
    向编辑器中通过代码添加一个节点（非用户拖拽操作）。
    
    @param  panelID   {string}    编辑器ID
    @param  nodeName  {string}    要添加的节点类型名称（必须已注册）
    @param  x         {number}    【可选】节点在画布上的X坐标，默认为0
    @param  y         {number}    【可选】节点在画布上的Y坐标，默认为0
    
    @return {table|nil} 新创建的节点实例，编辑器不存在返回nil
    
    @usage  示例：
        local node = AddNodeToEditor("my_editor", "action_node", 200, 100)
        if node then
            node.data.actionType = "move"  -- 设置节点数据
        end
]]
function AddNodeToEditor(panelID, nodeName, x, y)
    local editor = INE.Editors[panelID]
    if not editor then return nil end
    if not INE.RegisteredNodes[nodeName] then
        error("[IndependentNodeEditor] 节点未注册: " .. tostring(nodeName))
    end
    
    local node = INE:CreateNewNodeInstance(nodeName, editor, x or 0, y or 0)
    table.insert(editor.nodes, node)
    return node
end

--[[
    清空编辑器内容，重置为初始状态。
    清除所有节点和连接，重置画布平移偏移和缩放为默认值，
    并自动重新创建所有起始节点（isStartNode=true的节点）。
    
    @param  panelID {string}    编辑器ID
    
    @return {boolean} 操作成功返回true，编辑器不存在返回false
    
    @usage  示例：
        ClearNodeEditor("my_editor")  -- 清空画布，恢复初始状态
]]
function ClearNodeEditor(panelID)
    local editor = INE.Editors[panelID]
    if not editor then return false end
    
    -- 清空所有节点、连接和选中状态
    editor.nodes = {}
    editor.connections = {}
    editor.selectedNodes = {}
    editor.selectedOutputs = {}  -- 清空输出点选择，防止 stale 引用
    editor.draggingFrom = nil    -- 清空拖拽连线状态
    editor.draggingDataPort = nil  -- 清空数据点拖拽状态
    editor.dataConnections = {}  -- 清空数据连接
    -- 重置画布视图
    editor.canvasOffsetX = 0
    editor.canvasOffsetY = 0
    editor.canvasScale = 1
    
    -- 重新自动创建当前模式对应的开始点
    INE:CreateStartNodesForEditor(editor)
    
    return true
end

--[[
    获取所有已保存的默认变量列表。
    默认变量由用户在"所有变量模式"下通过"设为默认"按钮保存。
    数据以 JSON 格式存储在 data/ 目录下，可在 GMod 外访问以迁移到 Kards 变量库。
    
    @return {table} 默认变量表 { path = { path, name, varType }, ... }，若无可返回空表
]]
function GetDefaultVarList()
    if not KARDS.CardEditor or not KARDS.CardEditor.SaveSystem then return {} end
    local defaults = KARDS.CardEditor.SaveSystem.LoadData("ine_default_vars")
    return defaults or {}
end

-- ====================================
-- 全局节点注册函数（定义在此处确保所有 LogNewNode 调用前可用）
-- ====================================
function LogNewNode(nodeParams, nodeName)
    if not nodeParams then
        error("[IndependentNodeEditor] LogNewNode: nodeParams 不能为 nil")
    end
    if not nodeName then
        error("[IndependentNodeEditor] LogNewNode: nodeName 不能为 nil")
    end

    -- 构建节点模板（注册后用于创建节点实例的原型）
    local nodeTemplate = {
        name = nodeName,                                 -- 节点类型唯一名称（如 "card_node"）
        displayName = nodeParams.name or nodeName,       -- 节点显示名称（如 "卡牌"，用于UI标题）
        type = nodeParams.type or "custom",              -- 节点类型标识
        color = nodeParams.color or Color(100, 100, 100),-- 节点主体颜色
        width = nodeParams.width or 200,                 -- 节点宽度（像素）
        height = nodeParams.height or 80,                -- 节点高度（像素）
        hasInput = nodeParams.hasInput ~= false,         -- 是否显示左侧输入端口
        hasOutput = nodeParams.hasOutput ~= false,       -- 是否显示右侧输出端口
        hasSecondOutput = nodeParams.hasSecondOutput or false, -- 是否有第二个输出点（双分支：满足/不满足）
        outputLabels = nodeParams.outputLabels,          -- 双输出端口显示标签（可选，缺省 {"满足","不满足"}；「抉择」用 {"效果一","效果二"}）
        hasInputs = nodeParams.hasInputs or false,       -- 是否显示多个输入端口（保留）
        hasOutputs = nodeParams.hasOutputs or false,     -- 是否显示多个输出端口（保留）
        inputTypes = nodeParams.inputTypes or {},        -- 输入端口类型列表
        outputTypes = nodeParams.outputTypes or {},      -- 输出端口类型列表
        config = nodeParams.config or "",                -- 节点配置字符串
        isStartNode = nodeParams.isStartNode or false,   -- 是否为起始节点（自动创建、不可删除）
        canDelete = nodeParams.canDelete ~= false,       -- 是否允许用户删除
        drawFunction = nodeParams.drawFunction,          -- 自定义绘制函数
        dataFields = nodeParams.dataFields or {},        -- 节点数据字段默认值
        availableInputTypes = nodeParams.availableInputTypes or {},  -- 可用输入数据类型（来自 params）
        availableOutputTypes = nodeParams.availableOutputTypes or {}, -- 可用输出数据类型（来自 params）
    }

    -- 如果有配置字符串，解析配置并计算初始尺寸
    if nodeTemplate.config and nodeTemplate.config ~= "" then
        local configResult = INE.ParseConfig(nodeTemplate.config)
        nodeTemplate.parsedConfig = configResult
        nodeTemplate.availableInputTypes = configResult.inputTypes or {}
        nodeTemplate.availableOutputTypes = configResult.outputTypes or {}

        -- 检查是否有数字槽组件，自动添加数字类型输入支持
        local function checkNumberSlot(components)
            for _, comp in ipairs(components) do
                if comp.type == "number" then
                    return true
                elseif comp.type == "if" then
                    for _, branch in ipairs(comp.branches) do
                        if checkNumberSlot(branch.components) then
                            return true
                        end
                    end
                end
            end
            return false
        end

        if checkNumberSlot(configResult.components) then
            -- 检查是否已有数字类型
            local hasNumberType = false
            for _, inputType in ipairs(nodeTemplate.availableInputTypes) do
                if inputType.id == "n" then
                    hasNumberType = true
                    break
                end
            end
            -- 如果没有，添加数字类型
            if not hasNumberType then
                local numberType = INE.GetDataTypeById("n")
                if numberType then
                    table.insert(nodeTemplate.availableInputTypes, numberType)
                end
            end
        end

        -- 检查是否有文本槽组件（<>），自动添加文本类型输入支持（2026-10-04 新增）
        local function checkTextSlot(components)
            for _, comp in ipairs(components) do
                if comp.type == "textslot" then
                    return true
                elseif comp.type == "if" then
                    for _, branch in ipairs(comp.branches) do
                        if checkTextSlot(branch.components) then
                            return true
                        end
                    end
                end
            end
            return false
        end

        if checkTextSlot(configResult.components) then
            local hasTextType = false
            for _, inputType in ipairs(nodeTemplate.availableInputTypes) do
                if inputType.id == "t" then
                    hasTextType = true
                    break
                end
            end
            if not hasTextType then
                local textType = INE.GetDataTypeById("t")
                if textType then
                    table.insert(nodeTemplate.availableInputTypes, textType)
                end
            end
        end

        -- 初始化默认数据并计算尺寸
        local initData = INE.InitNodeData(configResult.components, {})
        local calcWidth, calcHeight = INE.CalculateSize(configResult.components, initData)

        -- 如果没有显式指定宽高，则使用计算值
        if not nodeParams.width then
            nodeTemplate.width = calcWidth
        end
        if not nodeParams.height then
            nodeTemplate.height = calcHeight
        end

        -- 将配置解析出的数据字段合并到 dataFields 中
        for key, val in pairs(initData) do
            if nodeTemplate.dataFields[key] == nil then
                nodeTemplate.dataFields[key] = val
            end
        end
    end

    -- 存储到节点模板注册表（INE.RegisteredNodes）
    INE.RegisteredNodes[nodeName] = nodeTemplate
end

-- ====================================
-- 内置节点类型注册
-- ====================================

--[[
    注册通用的开始点节点类型。
    开始点是特殊输出点，作为事件触发器使用，根据 editorMode 自动排列在 y 轴上。
    不同模式（单位/指令/反制）拥有不同的开始点集合。
]]
LogNewNode({
    type = "start",
    color = Color(70, 130, 180),
    width = 200,
    height = 100,
    hasInput = false,
    hasOutput = true,
    isStartNode = true,
    canDelete = false,
    dataFields = {title = "开始点"}
}, "start_point")

--[[
    注册数据源开始点节点类型。
    数据源开始点仅提供数据输出（如"钳击对象"），无执行输出。
    与普通开始点一样自动创建且不可删除。
]]
LogNewNode({
    type = "data_source",
    color = Color(60, 160, 120),
    width = 200,
    height = 100,
    hasInput = false,
    hasOutput = false,
    isStartNode = true,
    canDelete = false,
    dataFields = {title = "数据源"}
}, "data_start_point")