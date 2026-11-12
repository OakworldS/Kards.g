--[[
=======================================================================================
编辑器子系统：cl_ine_think.lua
=======================================================================================
从 cl_ine_node_editor.lua 拆分出的子系统：每帧逻辑更新 INE:Think（各对话框 DTextEntry 的生命周期管理）。
源行范围：cl_ine_node_editor.lua 第 3887 至 4655 行（2026-10-18 拆分时点）。
2026-11-08：九类输入的重复生命周期收进 KARDS.CardEditor.InlineField，状态与句柄按
编辑器实例存放在 editor.session，见 docs/adr/0010-内联输入会话统一.md。
=======================================================================================
]]

local INE = KARDS.CardEditor.IndependentNodeEditor
local T = KARDS.Lang.T
local IF = KARDS.CardEditor.InlineField

-- 内部名显示规则：默认生成名（带类型前缀）不显示，用户自定义名原样显示
local function InameText(iname, defaultPattern)
    return (iname and not iname:match(defaultPattern)) and iname or ""
end

-- 取当前会话指向的变量定义
local function VarOf(state, typeKey)
    local ed = INE.Editors[state.editorID]
    return ed and (ed.variables[typeKey] or {})[state.varIdx], ed
end

--[[
    九类内联输入的描述表。
    各输入只有三点差异：规范文本从哪读、输入写回到哪、如何判断目标仍有效。
    关闭键与焦点策略也在此声明，默认 ESC 关闭、创建后弹置、失焦时重新弹置。
]]
local Specs = {
    -- 变量搜索：搜索框由全局变量面板持有，规范文本即 state.text
    VarSearch = {
        kind = "VarSearch",
        caretOnCreate = false,      -- 原实现创建时不设光标
        focusExisting = "request",  -- 原实现每帧主动请求焦点
        text = function(state)
            return state.text or ""
        end,
        commit = function(state, txt)
            state.text = txt
            -- 同步到编辑器的搜索文本
            local edID = state.editorID
            local typeId = state.typeId
            if edID and typeId then
                local ed = INE.Editors[edID]
                if ed then ed._varSearchText[typeId] = txt end
            end
        end,
    },

    -- 数字变量：name / iname / val 三个字段，数值允许保留非数字原文
    NumVar = {
        kind = "NumVar",
        validate = function(state)
            return VarOf(state, "n")
        end,
        text = function(state)
            local vd = VarOf(state, "n")
            if not vd then return "" end
            if state.field == "name" then return vd.name or "" end
            if state.field == "iname" then return InameText(vd.internalName, "^n_var_") end
            if state.field == "val" then return tostring(vd.initialValue or 0) end
            return ""
        end,
        commit = function(state, txt)
            local vd = VarOf(state, "n")
            if not vd then return end
            local f = state.field
            if f == "name" then vd.name = txt
            elseif f == "iname" then vd.internalName = txt
            elseif f == "val" then
                local num = tonumber(txt)
                vd.initialValue = (num ~= nil) and num or txt
            end
        end,
    },

    -- 函数变量：名称直接写回变量定义
    FuncVar = {
        kind = "FuncVar",
        validate = function(state)
            return VarOf(state, "f")
        end,
        text = function(state)
            return state.text or ""
        end,
        commit = function(state, txt)
            state.text = txt
            local vd = VarOf(state, "f")
            if vd then vd.name = txt end
        end,
    },

    -- 函数参数添加：只暂存输入文本，提交由对话框按钮完成
    FuncParam = {
        kind = "FuncParam",
        validate = function(state)
            return VarOf(state, "f")
        end,
        text = function(state)
            return state.text or ""
        end,
        commit = function(state, txt)
            state.text = txt
        end,
    },

    -- 数组变量：name / iname 写回定义，val_n / val_t 写回会话临时值
    ArrayVar = {
        kind = "ArrayVar",
        validate = function(state)
            return VarOf(state, "g")
        end,
        text = function(state)
            local vd = VarOf(state, "g")
            if not vd then return "" end
            if state.field == "name" then return vd.name or "" end
            if state.field == "iname" then return InameText(vd.internalName, "^g_var_") end
            if state.field == "val_n" or state.field == "val_t" then
                local ctx = INE:ArrayVarCtx(INE.Editors[state.editorID])
                return tostring(ctx and ctx.itemValue or "")
            end
            return ""
        end,
        commit = function(state, txt)
            local vd = VarOf(state, "g")
            if not vd then return end
            local f = state.field
            if f == "name" then vd.name = txt
            elseif f == "iname" then vd.internalName = txt
            elseif f == "val_n" or f == "val_t" then
                local ctx = INE:ArrayVarCtx(INE.Editors[state.editorID])
                if ctx then ctx.itemValue = txt end
            end
        end,
    },

    -- 卡牌对象变量：name / iname 两个字段
    CardVar = {
        kind = "CardVar",
        validate = function(state)
            return VarOf(state, "e")
        end,
        text = function(state)
            local vd = VarOf(state, "e")
            if not vd then return "" end
            if state.field == "name" then return vd.name or "" end
            if state.field == "iname" then return vd.internalName or "" end
            return ""
        end,
        commit = function(state, txt)
            local vd = VarOf(state, "e")
            if not vd then return end
            local f = state.field
            if f == "name" then vd.name = txt
            elseif f == "iname" then vd.internalName = txt
            end
        end,
    },

    -- 字符串变量：name / iname / text 三个字段
    StringVar = {
        kind = "StringVar",
        validate = function(state)
            return VarOf(state, "t")
        end,
        text = function(state)
            local vd = VarOf(state, "t")
            if not vd then return "" end
            if state.field == "name" then return vd.name or "" end
            if state.field == "iname" then return InameText(vd.internalName, "^t_var_") end
            if state.field == "text" then return vd.initialValue or "" end
            return ""
        end,
        commit = function(state, txt)
            local vd = VarOf(state, "t")
            if not vd then return end
            local f = state.field
            if f == "name" then vd.name = txt
            elseif f == "iname" then vd.internalName = txt
            elseif f == "text" then vd.initialValue = txt
            end
        end,
    },

    -- 布尔值变量：name / iname 两个字段
    BoolVar = {
        kind = "BoolVar",
        validate = function(state)
            return VarOf(state, "p")
        end,
        text = function(state)
            local vd = VarOf(state, "p")
            if not vd then return "" end
            if state.field == "name" then return vd.name or "" end
            if state.field == "iname" then return InameText(vd.internalName, "^p_var_") end
            return ""
        end,
        commit = function(state, txt)
            local vd = VarOf(state, "p")
            if not vd then return end
            local f = state.field
            if f == "name" then vd.name = txt
            elseif f == "iname" then vd.internalName = txt
            end
        end,
    },

    -- 文本槽：写回节点槽数据与扁平键，ENTER 也结束编辑
    TextSlot = {
        kind = "TextSlot",
        closeKeys = { KEY_ENTER },
        validate = function(state)
            if not (state.node and state.compId) then return false end
            local ed = state.node.editor
            if not (ed and ed.nodes) then return false end
            for _, n in ipairs(ed.nodes) do
                if n == state.node then return true end
            end
            return false
        end,
        text = function(state)
            return state.text or ""
        end,
        commit = function(state, txt)
            state.text = txt
            local node = state.node
            local data = node and node.data
            if not data then return end
            data[state.compId] = txt
            data.slots = data.slots or {}
            local slot = data.slots[state.compId]
            if not slot then
                slot = INE.GetOrCreateSlotData("text", node, state.compId, txt)
            end
            slot.mode = "literal"
            slot.literalValue = txt
            slot.variableRef = nil
        end,
    },
}

--[[
    每帧逻辑更新函数。
    遍历所有可见编辑器，调用各自的输入处理逻辑。
    由Think钩子每帧调用。
]]
function INE:Think()
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
            -- 输入会话：每编辑器一份，路由前先让句柄就位
            for _, spec in ipairs(Specs) do
                IF.Update(spec, editor)
            end
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
                INE:RouteInput(editor)
            end
        else
            -- 隐藏面板不留输入句柄
            for _, spec in ipairs(Specs) do
                IF.Release(spec, editor)
            end
        end
    end
end
