--[[
=======================================================================================
叠加窗口输入处理子系统 (Overlay Window Input Handler)
=======================================================================================
从 cl_ine_input_handling.lua 拆分出的子系统，负责 INE 编辑器叠加窗口交互处理。
包含数字变量、函数变量、数组变量对话框、导入窗口、查找节点窗口等所有弹窗的输入逻辑。

依赖：
  - INE 模块 (self)
  - editor 实例的状态字段
  - OverlayWindow 系统 (GetOverlayWindowAt, CloseOverlayWindow, etc.)

源文件：cl_ine_input_handling.lua 行 159~993
=======================================================================================
]]
local INE = KARDS.CardEditor.IndependentNodeEditor

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- 处理叠加窗口交互：窗口拖拽、按钮点击、对话框输入等
-- 提取为大函数以减轻 HandleInput 的 GLua 局部变量限制压力
function INE:HandleOverlayInteraction(editor, mouseX, mouseY)
    -- 检测鼠标是否在叠加窗口上
    local hoveredWindow
    -- 全屏函数子编辑器覆盖时，阻止所有鼠标交互（含叠加窗口）
    -- mouseBlockedByFullscreen 当前未启用，保留逻辑结构供后续扩展
    local mouseBlockedByFullscreen = false
    if mouseBlockedByFullscreen then
        editor._mouseOverOverlayWindow = true
        hoveredWindow = nil
    else
        hoveredWindow = self:GetOverlayWindowAt(editor, mouseX, mouseY)
        editor._mouseOverOverlayWindow = hoveredWindow ~= nil
    end

    -- 处理叠加窗口交互
    local draggingWin = nil
    if hoveredWindow then
        local onTitleBar = hoveredWindow.draggable and mouseY >= hoveredWindow.y and mouseY <= hoveredWindow.y + 30 and mouseX < hoveredWindow.x + hoveredWindow.width - 30
        local onCloseBtn = hoveredWindow._closeBtn and INE:IsPointInRect(mouseX, mouseY, hoveredWindow._closeBtn)

        -- 处理关闭按钮点击
        if onCloseBtn then
            if input.IsMouseDown(MOUSE_LEFT) and not editor._overlayCloseClicked then
                editor._overlayCloseClicked = true
                -- 处理嵌套对话框的关闭（等同于取消）
                if INE:ArrayVarCtx(editor).nestedCtx then
                    if INE:ArrayVarCtx(editor).nestedCtx.tempType == "f" and hoveredWindow.id == "ine_funcvar_dialog" then
                        -- 清理临时函数变量
                        local ctx = INE:ArrayVarCtx(editor).nestedCtx
                        local funcVars = editor.variables["f"] or {}
                        if funcVars[editor._numVarDialogIdx] then
                            table.remove(funcVars, editor._numVarDialogIdx)
                        end
                        editor._numVarDialogIdx = ctx.savedDialogIdx
                        editor._numVarDialogIsNew = ctx.savedIsNew
                        INE:ArrayVarCtx(editor).nestedCtx = nil
                        INE:ArrayVarCtx(editor).pendingType = nil
                        INE:ArrayVarCtx(editor).itemValue = nil
                    elseif INE:ArrayVarCtx(editor).nestedCtx.tempType == "g" and hoveredWindow.id == "ine_arrayvar_dialog" then
                        -- 清理临时数组变量
                        local ctx = INE:ArrayVarCtx(editor).nestedCtx
                        local gVars = editor.variables["g"] or {}
                        if gVars[editor._numVarDialogIdx] then
                            table.remove(gVars, editor._numVarDialogIdx)
                        end
                        local parentEditor = ctx.parentEditor
                        parentEditor._numVarDialogIdx = ctx.savedDialogIdx
                        parentEditor._numVarDialogIsNew = ctx.savedIsNew
                        INE:ArrayVarCtx(editor).nestedCtx = nil
                        INE:ArrayVarCtx(editor).pendingType = nil
                        INE:ArrayVarCtx(editor).itemValue = nil
                        -- 重新打开父数组对话框
                        INE:ShowArrayVarDialog(parentEditor, ctx.savedDialogIdx)
                    end
                end
                self:CloseOverlayWindow(editor, hoveredWindow.id)
            end
        elseif hoveredWindow.showScope then
            -- 变量分类选择器（全局/长期）点击处理
            local onGlobalBtn = hoveredWindow._scopeGlobalBtn and INE:IsPointInRect(mouseX, mouseY, hoveredWindow._scopeGlobalBtn)
            local onLongtermBtn = hoveredWindow._scopeLongtermBtn and INE:IsPointInRect(mouseX, mouseY, hoveredWindow._scopeLongtermBtn)
            if (onGlobalBtn or onLongtermBtn) and input.IsMouseDown(MOUSE_LEFT) and not editor._overlayCloseClicked then
                editor._overlayCloseClicked = true
                if onGlobalBtn then
                    hoveredWindow.scope = "global"
                elseif onLongtermBtn then
                    hoveredWindow.scope = "longterm"
                end
                -- 同步到对应变量的 scope 字段
                local function updateVarScope(varType, varIdx)
                    if varIdx and editor.variables[varType] and editor.variables[varType][varIdx] then
                        editor.variables[varType][varIdx].scope = hoveredWindow.scope
                    end
                end
                if hoveredWindow.id == "ine_numvar_dialog" then
                    updateVarScope("n", editor._numVarDialogIdx)
                elseif hoveredWindow.id == "ine_funcvar_dialog" then
                    local dataEditor = editor._funcDialogDataEditor or editor
                    local vi = editor._numVarDialogIdx
                    if vi and dataEditor.variables["f"] and dataEditor.variables["f"][vi] then
                        dataEditor.variables["f"][vi].scope = hoveredWindow.scope
                    end
                elseif hoveredWindow.id == "ine_arrayvar_dialog" then
                    updateVarScope("g", editor._numVarDialogIdx)
                elseif hoveredWindow.id == "ine_cardvar_dialog" then
                    updateVarScope("e", editor._numVarDialogIdx)
                elseif hoveredWindow.id == "ine_stringvar_dialog" then
                    updateVarScope("t", editor._stringVarDialogIdx)
                elseif hoveredWindow.id == "ine_boolvar_dialog" then
                    updateVarScope("p", editor._boolVarDialogIdx)
                end
            end
        else
            -- 处理标题栏拖拽
            if onTitleBar and input.IsMouseDown(MOUSE_LEFT) then
                if not hoveredWindow._dragging then
                    hoveredWindow._dragging = true
                    hoveredWindow._dragStartX = mouseX
                    hoveredWindow._dragStartY = mouseY
                    hoveredWindow._dragStartWinX = hoveredWindow.x
                    hoveredWindow._dragStartWinY = hoveredWindow.y
                end
            end

            if hoveredWindow._dragging then
                draggingWin = hoveredWindow
            end
        end

        if not input.IsMouseDown(MOUSE_LEFT) then
            editor._overlayCloseClicked = false
        end
    end

    -- 处理窗口拖拽（即使鼠标移出窗口区域也要继续更新）
    if not draggingWin then
        for _, win in pairs(editor.overlayWindows or {}) do
            if win._dragging then
                draggingWin = win
                break
            end
        end
    end

    if draggingWin then
        if input.IsMouseDown(MOUSE_LEFT) then
            local dx = mouseX - draggingWin._dragStartX
            local dy = mouseY - draggingWin._dragStartY
            draggingWin.x = draggingWin._dragStartWinX + dx
            draggingWin.y = draggingWin._dragStartWinY + dy
            editor._mouseOverOverlayWindow = true
        else
            draggingWin._dragging = false
        end
    end

    if hoveredWindow and input.IsMouseDown(MOUSE_LEFT) and not editor._overlayClientClickHandled then
        local clientY1 = hoveredWindow.y + 30
        local clientX1 = hoveredWindow.x
        local clientX2 = hoveredWindow.x + hoveredWindow.width
        local clientY2 = hoveredWindow.y + hoveredWindow.height
        if mouseX >= clientX1 and mouseX <= clientX2 and mouseY >= clientY1 and mouseY <= clientY2 then
            editor._overlayClientClickHandled = true
            if hoveredWindow.id == "find_node_window" then
                local listStartY = hoveredWindow.y + 30 + 40
                local itemH = 26
                local idx = math.floor((mouseY - listStartY) / itemH) + 1
                local filteredNodes = INE:GetFilteredNodeList(editor)
                if idx >= 1 and idx <= #filteredNodes then
                    local node = filteredNodes[idx]
                    INE:CenterViewOn(editor, node.x + node.width/2, node.y + node.height/2)
                    editor.selectedNodes = {node}
                    INE:CloseOverlayWindow(editor, "find_node_window")
                end
            elseif hoveredWindow.id == "ine_import_window" then
                -- 检测文件列表点击
                if editor._importFileRects then
                    for _, rect in ipairs(editor._importFileRects) do
                        if mouseX >= rect.x and mouseX <= rect.x + rect.w and mouseY >= rect.y and mouseY <= rect.y + rect.h then
                            local files = editor._importFiles or {}
                            if rect.idx >= 1 and rect.idx <= #files then
                                editor._importSelectedFile = files[rect.idx]
                            end
                            break
                        end
                    end
                end
                -- 检测加载按钮点击
                if editor._importLoadBtnRect and editor._importSelectedFile then
                    local btn = editor._importLoadBtnRect
                    if mouseX >= btn.x and mouseX <= btn.x + btn.w and mouseY >= btn.y and mouseY <= btn.y + btn.h then
                        local fileName = editor._importSelectedFile
                        INE:CloseOverlayWindow(editor, "ine_import_window")
                        local data = KARDS.CardEditor.SaveSystem.LoadEffect(fileName)
                        if data and data.nodes then
                            -- 反序列化并替换编辑器内容（复用 ImportEffectData，与卡牌加载联动同一套逻辑）
                            INE:ImportEffectData(editor, data)
                            INE:AddNotification(editor, T("editor.nodeoverlay.import_success"), Color(100, 255, 100), 3, true)
                        else
                            INE:AddNotification(editor, T("editor.nodeoverlay.import_failed", fileName), Color(255, 100, 100), 3)
                        end
                    end
                end
                -- 检测取消按钮点击
                if editor._importCancelBtnRect then
                    local btn = editor._importCancelBtnRect
                    if mouseX >= btn.x and mouseX <= btn.x + btn.w and mouseY >= btn.y and mouseY <= btn.y + btn.h then
                        INE:CloseOverlayWindow(editor, "ine_import_window")
                    end
                end
            elseif hoveredWindow.id == "ine_numvar_dialog" then
                -- 数字变量对话框字段点击编辑（激活 DTextEntry 内联输入）
                if editor._numVarField_name and INE:IsPointInRect(mouseX, mouseY, editor._numVarField_name) then
                    local vars = editor.variables["n"] or {}
                    local vd = vars[editor._numVarDialogIdx]
                    if vd then
                        INE:Field(editor, "NumVar").active = true
                        INE:Field(editor, "NumVar").field = "name"
                        INE:Field(editor, "NumVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "NumVar").varIdx = editor._numVarDialogIdx
                        INE:Field(editor, "NumVar").x = editor._numVarField_name.x
                        INE:Field(editor, "NumVar").y = editor._numVarField_name.y
                        INE:Field(editor, "NumVar").w = editor._numVarField_name.w
                        INE:Field(editor, "NumVar").h = editor._numVarField_name.h
                    end
                elseif editor._numVarField_iname and INE:IsPointInRect(mouseX, mouseY, editor._numVarField_iname) then
                    local vars = editor.variables["n"] or {}
                    local vd = vars[editor._numVarDialogIdx]
                    if vd then
                        INE:Field(editor, "NumVar").active = true
                        INE:Field(editor, "NumVar").field = "iname"
                        INE:Field(editor, "NumVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "NumVar").varIdx = editor._numVarDialogIdx
                        INE:Field(editor, "NumVar").x = editor._numVarField_iname.x
                        INE:Field(editor, "NumVar").y = editor._numVarField_iname.y
                        INE:Field(editor, "NumVar").w = editor._numVarField_iname.w
                        INE:Field(editor, "NumVar").h = editor._numVarField_iname.h
                    end
                elseif editor._numVarField_val and INE:IsPointInRect(mouseX, mouseY, editor._numVarField_val) then
                    local vars = editor.variables["n"] or {}
                    local vd = vars[editor._numVarDialogIdx]
                    if vd then
                        INE:Field(editor, "NumVar").active = true
                        INE:Field(editor, "NumVar").field = "val"
                        INE:Field(editor, "NumVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "NumVar").varIdx = editor._numVarDialogIdx
                        INE:Field(editor, "NumVar").x = editor._numVarField_val.x
                        INE:Field(editor, "NumVar").y = editor._numVarField_val.y
                        INE:Field(editor, "NumVar").w = editor._numVarField_val.w
                        INE:Field(editor, "NumVar").h = editor._numVarField_val.h
                    end
                elseif editor._numVarConfirmRect and INE:IsPointInRect(mouseX, mouseY, editor._numVarConfirmRect) then
                    -- 确定前验证初始值是否为有效数字
                    local vars = editor.variables["n"] or {}
                    local vd = vars[editor._numVarDialogIdx]
                    if vd then
                        local num = tonumber(vd.initialValue)
                        if num == nil then
                            INE:AddNotification(editor, T("editor.nodeoverlay.initial_value_invalid"), Color(255, 100, 100), 2)
                            -- 激活初始值字段让用户修改
                            INE:Field(editor, "NumVar").active = true
                            INE:Field(editor, "NumVar").field = "val"
                            INE:Field(editor, "NumVar").editorID = editor.panelID or editor.id
                            INE:Field(editor, "NumVar").varIdx = editor._numVarDialogIdx
                            INE:Field(editor, "NumVar").x = editor._numVarField_val.x
                            INE:Field(editor, "NumVar").y = editor._numVarField_val.y
                            INE:Field(editor, "NumVar").w = editor._numVarField_val.w
                            INE:Field(editor, "NumVar").h = editor._numVarField_val.h
                        else
                            -- 确保存储为数字类型
                            vd.initialValue = num
                            -- 关闭前清理 DTextEntry
                            local entry = INE:Entry(editor, "NumVar")
                            if entry and IsValid(entry) then entry:Remove() end
                            INE:ClearEntry(editor, "NumVar")
                            INE:Field(editor, "NumVar").active = false
                            INE:Field(editor, "NumVar").editorID = nil
                            INE:CloseOverlayWindow(editor, "ine_numvar_dialog")
                        end
                    end
                elseif editor._numVarCancelRect and INE:IsPointInRect(mouseX, mouseY, editor._numVarCancelRect) then
                    -- 取消时清理 DTextEntry
                    local entry = INE:Entry(editor, "NumVar")
                    if entry and IsValid(entry) then entry:Remove() end
                    INE:ClearEntry(editor, "NumVar")
                    INE:Field(editor, "NumVar").active = false
                    INE:Field(editor, "NumVar").editorID = nil
                    -- 取消时删除变量（若为新创建的，用 _numVarDialogIsNew 判别）
                    local vars = editor.variables["n"] or {}
                    if editor._numVarDialogIsNew and vars[editor._numVarDialogIdx] then
                        table.remove(vars, editor._numVarDialogIdx)
                    end
                    editor._numVarDialogIsNew = nil
                    INE:CloseOverlayWindow(editor, "ine_numvar_dialog")
                end
            elseif hoveredWindow.id == "ine_funcvar_dialog" then
                -- 函数变量对话框交互
                -- 使用 handled 标志确保类型按钮不堵塞后续元素
                local handled = false
                -- 数据编辑器：当对话框显示在子编辑器上时，使用父编辑器数据
                local dataEditor = editor._funcDialogDataEditor or editor

                -- 函数名称字段点击
                if not handled and editor._funcVarField_name and INE:IsPointInRect(mouseX, mouseY, editor._funcVarField_name) then
                    local vars = dataEditor.variables["f"] or {}
                    local vd = vars[dataEditor._numVarDialogIdx]
                    if vd then
                        -- 停用参数输入框，确保只有一个 DTextEntry 激活
                        INE:Field(dataEditor, "FuncParam").active = false
                        INE:Field(dataEditor, "FuncVar").active = true
                        INE:Field(dataEditor, "FuncVar").text = vd.name or ""
                        -- 使用 dataEditor ID 确保 Think 生命周期能正确找到变量数据
                        INE:Field(dataEditor, "FuncVar").editorID = dataEditor.panelID or dataEditor.id
                        INE:Field(dataEditor, "FuncVar").varIdx = dataEditor._numVarDialogIdx
                        INE:Field(dataEditor, "FuncVar").x = editor._funcVarField_name.x
                        INE:Field(dataEditor, "FuncVar").y = editor._funcVarField_name.y
                        INE:Field(dataEditor, "FuncVar").w = editor._funcVarField_name.w
                        INE:Field(dataEditor, "FuncVar").h = editor._funcVarField_name.h
                        handled = true
                    end
                end

                -- 参数类型按钮点击（仅在待确认添加参数时出现，点击后直接创建参数）
                if not handled and editor._funcVarPendingParam and editor._funcVarTypeBtns then
                    local clickedType = nil
                    for typeId, btnRect in pairs(editor._funcVarTypeBtns) do
                        if INE:IsPointInRect(mouseX, mouseY, btnRect) then
                            clickedType = typeId
                            break
                        end
                    end
                    if clickedType then
                        local vars = dataEditor.variables["f"] or {}
                        local vd = vars[dataEditor._numVarDialogIdx]
                        if vd then
                            vd.params = vd.params or {}
                            table.insert(vd.params, {name = editor._funcVarPendingParam, type = clickedType})
                            editor._funcVarPendingParam = nil
                            editor._funcDialogSelectedType = nil
                            -- 清除参数输入框文本
                            INE:Field(dataEditor, "FuncParam").text = ""
                            local entry = INE:Entry(dataEditor, "FuncParam")
                            if entry and IsValid(entry) then
                                entry:SetText("")
                            end
                        end
                        handled = true
                    end
                end

                -- 参数输入框点击
                if not handled and editor._funcVarField_param and INE:IsPointInRect(mouseX, mouseY, editor._funcVarField_param) then
                    local vars = dataEditor.variables["f"] or {}
                    local vd = vars[dataEditor._numVarDialogIdx]
                    if vd then
                        -- 停用函数名称输入框，确保只有一个 DTextEntry 激活
                        INE:Field(dataEditor, "FuncVar").active = false
                        INE:Field(dataEditor, "FuncParam").active = true
                        INE:Field(dataEditor, "FuncParam").text = ""
                        -- 使用 dataEditor ID 确保 Think 生命周期能正确找到变量数据
                        INE:Field(dataEditor, "FuncParam").editorID = dataEditor.panelID or dataEditor.id
                        INE:Field(dataEditor, "FuncParam").varIdx = dataEditor._numVarDialogIdx
                        INE:Field(dataEditor, "FuncParam").x = editor._funcVarField_param.x
                        INE:Field(dataEditor, "FuncParam").y = editor._funcVarField_param.y
                        INE:Field(dataEditor, "FuncParam").w = editor._funcVarField_param.w
                        INE:Field(dataEditor, "FuncParam").h = editor._funcVarField_param.h
                        handled = true
                    end
                end

                -- 添加按钮点击：不立即创建参数，而是显示类型选择按钮
                if not handled and editor._funcVarField_addBtn and INE:IsPointInRect(mouseX, mouseY, editor._funcVarField_addBtn) then
                    local vars = dataEditor.variables["f"] or {}
                    local vd = vars[dataEditor._numVarDialogIdx]
                    if vd then
                        local paramText = INE:Field(dataEditor, "FuncParam") and INE:Field(dataEditor, "FuncParam").text or ""
                        if paramText ~= "" then
                            -- 设置待确认参数名称，显示类型选择器
                            editor._funcVarPendingParam = paramText
                            editor._funcDialogSelectedType = "n"
                            INE:Field(dataEditor, "FuncParam").text = ""
                            local entry = INE:Entry(dataEditor, "FuncParam")
                            if entry and IsValid(entry) then
                                entry:SetText("")
                            end
                        end
                        handled = true
                    end
                end

                -- 参数删除按钮点击
                if not handled and editor._funcVarParamDel then
                    local vars = dataEditor.variables["f"] or {}
                    local vd = vars[dataEditor._numVarDialogIdx]
                    if vd then
                        for pi, delRect in pairs(editor._funcVarParamDel) do
                            if INE:IsPointInRect(mouseX, mouseY, delRect) then
                                vd.params = vd.params or {}
                                table.remove(vd.params, pi)
                                handled = true
                                break
                            end
                        end
                    end
                end

                -- 确定按钮
                if not handled and editor._funcVarConfirmRect and INE:IsPointInRect(mouseX, mouseY, editor._funcVarConfirmRect) then
                    local vars = dataEditor.variables["f"] or {}
                    local vd = vars[dataEditor._numVarDialogIdx]
                    if vd then
                        -- 清理 DTextEntry
                        local entry1 = INE:Entry(dataEditor, "FuncVar")
                        if entry1 and IsValid(entry1) then entry1:Remove() end
                        INE:ClearEntry(dataEditor, "FuncVar")
                        INE:Field(dataEditor, "FuncVar").active = false
                        INE:Field(dataEditor, "FuncVar").editorID = nil
                        local entry2 = INE:Entry(dataEditor, "FuncParam")
                        if entry2 and IsValid(entry2) then entry2:Remove() end
                        INE:ClearEntry(dataEditor, "FuncParam")
                        INE:Field(dataEditor, "FuncParam").active = false
                        INE:Field(dataEditor, "FuncParam").editorID = nil
                        -- 清除待确认参数状态
                        editor._funcVarPendingParam = nil
                        -- 清除数据编辑器引用
                        editor._funcDialogDataEditor = nil

                        -- 检测是否在数组变量嵌套创建上下文中
                        if INE:ArrayVarCtx(editor).nestedCtx and INE:ArrayVarCtx(editor).nestedCtx.tempType == "f" then
                            local ctx = INE:ArrayVarCtx(editor).nestedCtx
                            local parentEditor = ctx.parentEditor
                            local parentVars = parentEditor.variables["g"] or {}
                            local parentVd = parentVars[ctx.parentVarIdx]
                            local newItem = nil
                            if parentVd then
                                -- 确保函数名称不为空
                                if vd.name == "" or not vd.name then vd.name = "func" end
                                local funcName = vd.name
                                -- 创建自包含的数组项：函数数据完全存储在项内，不创建外部函数变量
                                newItem = {type = "f", value = funcName, params = vd.params or {}, functionData = {}}
                                parentVd.items = parentVd.items or {}
                                table.insert(parentVd.items, newItem)
                            end
                            -- 移除临时函数变量（方案B：数组项自包含，不需要外部函数变量）
                            local fVars = editor.variables["f"] or {}
                            if fVars[editor._numVarDialogIdx] then
                                table.remove(fVars, editor._numVarDialogIdx)
                            end
                            -- 清除父数组对话框的添加状态
                            INE:ArrayVarCtx(editor).pendingType = nil
                            INE:ArrayVarCtx(editor).itemValue = nil
                            -- 恢复父编辑器状态
                            local funcName = vd.name or "func"
                            parentEditor._numVarDialogIdx = ctx.savedDialogIdx
                            parentEditor._numVarDialogIsNew = ctx.savedIsNew
                            INE:ArrayVarCtx(editor).nestedCtx = nil
                            -- 关闭函数对话框
                            INE:CloseOverlayWindow(editor, "ine_funcvar_dialog")
                            -- 使用数组项引用打开函数子编辑器，让用户编辑函数内部逻辑
                            if newItem then
                                INE:OpenFunctionSubEditor(parentEditor, funcName, newItem)
                            end
                            handled = true
                            return
                        end

                        -- 确保函数名称不为空
                        if vd.name == "" or not vd.name then vd.name = "func_" .. dataEditor._numVarDialogIdx end
                        -- 关闭对话框
                        INE:CloseOverlayWindow(editor, "ine_funcvar_dialog")
                        -- 清除 _numVarDialogIsNew 标记（已创建成功）
                        dataEditor._numVarDialogIsNew = nil
                        INE:OpenFunctionSubEditor(dataEditor, vd.name)
                        handled = true
                    end
                end

                -- 取消按钮
                if not handled and editor._funcVarCancelRect and INE:IsPointInRect(mouseX, mouseY, editor._funcVarCancelRect) then
                    -- 清理 DTextEntry
                    local entry1 = INE:Entry(dataEditor, "FuncVar")
                    if entry1 and IsValid(entry1) then entry1:Remove() end
                    INE:ClearEntry(dataEditor, "FuncVar")
                    INE:Field(dataEditor, "FuncVar").active = false
                    INE:Field(dataEditor, "FuncVar").editorID = nil
                    local entry2 = INE:Entry(dataEditor, "FuncParam")
                    if entry2 and IsValid(entry2) then entry2:Remove() end
                    INE:ClearEntry(dataEditor, "FuncParam")
                    INE:Field(dataEditor, "FuncParam").active = false
                    INE:Field(dataEditor, "FuncParam").editorID = nil
                    -- 清除待确认参数状态
                    editor._funcVarPendingParam = nil
                    -- 清除数据编辑器引用
                    editor._funcDialogDataEditor = nil

                    -- 检测是否在数组变量嵌套创建上下文中
                    if INE:ArrayVarCtx(editor).nestedCtx and INE:ArrayVarCtx(editor).nestedCtx.tempType == "f" then
                        local ctx = INE:ArrayVarCtx(editor).nestedCtx
                        -- 移除临时函数变量
                        local funcVars = dataEditor.variables["f"] or {}
                        if funcVars[dataEditor._numVarDialogIdx] then
                            table.remove(funcVars, dataEditor._numVarDialogIdx)
                        end
                        -- 清除父数组对话框的添加状态
                        INE:ArrayVarCtx(editor).pendingType = nil
                        INE:ArrayVarCtx(editor).itemValue = nil
                        -- 恢复父编辑器状态
                        local parentEditor = ctx.parentEditor
                        parentEditor._numVarDialogIdx = ctx.savedDialogIdx
                        parentEditor._numVarDialogIsNew = ctx.savedIsNew
                        INE:ArrayVarCtx(editor).nestedCtx = nil
                        -- 关闭函数对话框
                        INE:CloseOverlayWindow(editor, "ine_funcvar_dialog")
                        handled = true
                        return
                    end

                    -- 取消时删除新创建的变量
                    local vars = dataEditor.variables["f"] or {}
                    if dataEditor._numVarDialogIsNew and vars[dataEditor._numVarDialogIdx] then
                        table.remove(vars, dataEditor._numVarDialogIdx)
                    end
                    dataEditor._numVarDialogIsNew = nil
                    INE:CloseOverlayWindow(editor, "ine_funcvar_dialog")
                    handled = true
                end
            elseif hoveredWindow.id == "ine_arrayvar_dialog" then
                -- 数组变量对话框交互
                local handled = false
                local vars = editor.variables["g"] or {}
                local vd = vars[editor._numVarDialogIdx]

                -- 名称字段点击
                if not handled and editor._arrayVarField_name and INE:IsPointInRect(mouseX, mouseY, editor._arrayVarField_name) then
                    if vd then
                        INE:Field(editor, "ArrayVar").active = true
                        INE:Field(editor, "ArrayVar").field = "name"
                        INE:Field(editor, "ArrayVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "ArrayVar").varIdx = editor._numVarDialogIdx
                        INE:Field(editor, "ArrayVar").x = editor._arrayVarField_name.x
                        INE:Field(editor, "ArrayVar").y = editor._arrayVarField_name.y
                        INE:Field(editor, "ArrayVar").w = editor._arrayVarField_name.w
                        INE:Field(editor, "ArrayVar").h = editor._arrayVarField_name.h
                        handled = true
                    end
                end

                -- 内部名称字段点击
                if not handled and editor._arrayVarField_iname and INE:IsPointInRect(mouseX, mouseY, editor._arrayVarField_iname) then
                    if vd then
                        INE:Field(editor, "ArrayVar").active = true
                        INE:Field(editor, "ArrayVar").field = "iname"
                        INE:Field(editor, "ArrayVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "ArrayVar").varIdx = editor._numVarDialogIdx
                        INE:Field(editor, "ArrayVar").x = editor._arrayVarField_iname.x
                        INE:Field(editor, "ArrayVar").y = editor._arrayVarField_iname.y
                        INE:Field(editor, "ArrayVar").w = editor._arrayVarField_iname.w
                        INE:Field(editor, "ArrayVar").h = editor._arrayVarField_iname.h
                        handled = true
                    end
                end

                -- 项删除按钮点击
                if not handled and editor._arrayVarItemDel then
                    if vd then
                        for ii, delRect in pairs(editor._arrayVarItemDel) do
                            if INE:IsPointInRect(mouseX, mouseY, delRect) then
                                table.remove(vd.items, ii)
                                handled = true
                                break
                            end
                        end
                    end
                end

                -- "添加项"按钮点击
                if not handled and editor._arrayVarAddBtn and INE:IsPointInRect(mouseX, mouseY, editor._arrayVarAddBtn) then
                    if vd then
                        INE:ArrayVarCtx(editor).pendingType = "n"
                        INE:ArrayVarCtx(editor).itemValue = nil
                        INE:Field(editor, "ArrayVar").active = false
                        handled = true
                    end
                end

                -- 类型按钮点击
                if not handled and INE:ArrayVarCtx(editor).pendingType and editor._arrayVarTypeBtns then
                    if vd then
                        local clickedType = nil
                        for typeId, btnRect in pairs(editor._arrayVarTypeBtns) do
                            if INE:IsPointInRect(mouseX, mouseY, btnRect) then
                                clickedType = typeId
                                break
                            end
                        end
                        if clickedType then
                            if clickedType == "f" or clickedType == "g" or clickedType == "e" then
                                -- 复杂类型：呼出该类型变量的创建窗口
                                INE:Field(editor, "ArrayVar").active = false
                                -- 复杂类型不需要设置数组变量上下文的待选类型，否则嵌套对话框会错误显示类型选择器
                                -- 嵌套对话框应由数组变量上下文的 nestedCtx 管理状态
                                -- 保存当前数组对话框状态
                                local savedDialogIdx = editor._numVarDialogIdx
                                local savedIsNew = editor._numVarDialogIsNew
                                if clickedType == "f" then
                                    -- 创建临时函数变量并打开函数创建对话框
                                    INE:ArrayVarCtx(editor).pendingType = nil
                                    INE:ArrayVarCtx(editor).itemValue = nil
                                    local funcVars = editor.variables["f"] or {}
                                    local tempFunc = {name = "", params = {}}
                                    table.insert(funcVars, tempFunc)
                                    editor.variables["f"] = funcVars
                                    local tempIdx = #funcVars
                                    INE:ArrayVarCtx(editor).nestedCtx = {
                                        parentEditor = editor,
                                        parentVarIdx = savedDialogIdx,
                                        tempType = "f",
                                        tempVarIdx = tempIdx,
                                        savedDialogIdx = savedDialogIdx,
                                        savedIsNew = savedIsNew,
                                    }
                                    editor._numVarDialogIdx = tempIdx
                                    editor._numVarDialogIsNew = true
                                    INE:ShowFuncVarDialog(editor, tempIdx)
                                elseif clickedType == "e" then
                                    -- 创建临时卡牌对象变量并打开卡牌对象创建对话框
                                    INE:ArrayVarCtx(editor).pendingType = nil
                                    INE:ArrayVarCtx(editor).itemValue = nil
                                    local cardVars = editor.variables["e"] or {}
                                    local tempCard = {name = "", internalName = "", _mode = "empty"}
                                    table.insert(cardVars, tempCard)
                                    editor.variables["e"] = cardVars
                                    local tempIdx = #cardVars
                                    INE:ArrayVarCtx(editor).nestedCtx = {
                                        parentEditor = editor,
                                        parentVarIdx = savedDialogIdx,
                                        tempType = "e",
                                        tempVarIdx = tempIdx,
                                        savedDialogIdx = savedDialogIdx,
                                        savedIsNew = savedIsNew,
                                    }
                                    editor._numVarDialogIdx = tempIdx
                                    editor._numVarDialogIsNew = true
                                    INE:ShowCardVarDialog(editor, tempIdx)
                                else -- clickedType == "g"
                                    -- 创建临时数组变量并打开数组创建对话框（递归）
                                    INE:ArrayVarCtx(editor).pendingType = nil
                                    INE:ArrayVarCtx(editor).itemValue = nil
                                    local arrayVars = editor.variables["g"] or {}
                                    local tempArr = {name = "", internalName = "", items = {}}
                                    table.insert(arrayVars, tempArr)
                                    editor.variables["g"] = arrayVars
                                    local tempIdx = #arrayVars
                                    INE:ArrayVarCtx(editor).nestedCtx = {
                                        parentEditor = editor,
                                        parentVarIdx = savedDialogIdx,
                                        tempType = "g",
                                        tempVarIdx = tempIdx,
                                        savedDialogIdx = savedDialogIdx,
                                        savedIsNew = savedIsNew,
                                    }
                                    editor._numVarDialogIdx = tempIdx
                                    editor._numVarDialogIsNew = true
                                    INE:ShowArrayVarDialog(editor, tempIdx)
                                end
                            else
                                -- 简单类型：当前内联输入行为
                                INE:ArrayVarCtx(editor).pendingType = clickedType
                                INE:ArrayVarCtx(editor).itemValue = ""
                            end
                            handled = true
                        end
                    end
                end

                -- 布尔值按钮点击
                if not handled and INE:ArrayVarCtx(editor).pendingType == "p" then
                    if editor._arrayVarField_boolTrue and INE:IsPointInRect(mouseX, mouseY, editor._arrayVarField_boolTrue) then
                        INE:ArrayVarCtx(editor).itemValue = true
                        handled = true
                    elseif editor._arrayVarField_boolFalse and INE:IsPointInRect(mouseX, mouseY, editor._arrayVarField_boolFalse) then
                        INE:ArrayVarCtx(editor).itemValue = false
                        handled = true
                    end
                end

                -- 值输入框点击（val_n/val_t）
                if not handled and INE:ArrayVarCtx(editor).pendingType and editor._arrayVarField_val and INE:IsPointInRect(mouseX, mouseY, editor._arrayVarField_val) then
                    if vd then
                        local fieldType = (INE:ArrayVarCtx(editor).pendingType == "n") and "val_n" or "val_t"
                        INE:Field(editor, "ArrayVar").active = true
                        INE:Field(editor, "ArrayVar").field = fieldType
                        INE:Field(editor, "ArrayVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "ArrayVar").varIdx = editor._numVarDialogIdx
                        INE:Field(editor, "ArrayVar").x = editor._arrayVarField_val.x
                        INE:Field(editor, "ArrayVar").y = editor._arrayVarField_val.y
                        INE:Field(editor, "ArrayVar").w = editor._arrayVarField_val.w
                        INE:Field(editor, "ArrayVar").h = editor._arrayVarField_val.h
                        handled = true
                    end
                end

                -- "确认添加"按钮（仅对简单类型 n/p/t/e 生效）
                if not handled and INE:ArrayVarCtx(editor).pendingType and editor._arrayVarAddConfirmRect and INE:IsPointInRect(mouseX, mouseY, editor._arrayVarAddConfirmRect) then
                    if vd then
                        local itemType = INE:ArrayVarCtx(editor).pendingType
                        local itemValue = nil
                        if itemType == "n" then
                            itemValue = tonumber(INE:ArrayVarCtx(editor).itemValue) or 0
                        elseif itemType == "t" then
                            itemValue = tostring(INE:ArrayVarCtx(editor).itemValue or "")
                        elseif itemType == "p" then
                            itemValue = (INE:ArrayVarCtx(editor).itemValue == true)
                        end
                        local newItem = {type = itemType, value = itemValue}
                        vd.items = vd.items or {}
                        table.insert(vd.items, newItem)
                        INE:ArrayVarCtx(editor).pendingType = nil
                        INE:ArrayVarCtx(editor).itemValue = nil
                        INE:Field(editor, "ArrayVar").active = false
                        handled = true
                    end
                end

                -- 确定按钮
                if not handled and editor._arrayVarConfirmRect and INE:IsPointInRect(mouseX, mouseY, editor._arrayVarConfirmRect) then
                    -- 检测是否在数组变量嵌套创建上下文中
                    if INE:ArrayVarCtx(editor).nestedCtx and INE:ArrayVarCtx(editor).nestedCtx.tempType == "g" then
                        local ctx = INE:ArrayVarCtx(editor).nestedCtx
                        local parentEditor = ctx.parentEditor
                        local parentVars = parentEditor.variables["g"] or {}
                        local parentVd = parentVars[ctx.parentVarIdx]
                        if parentVd then
                            -- 从嵌套数组提取数据创建数组项
                            local nestedData = {name = vd.name or "", internalName = vd.internalName or "", items = vd.items or {}}
                            local newItem = {type = "g", value = nestedData}
                            parentVd.items = parentVd.items or {}
                            table.insert(parentVd.items, newItem)
                        end
                        -- 清理当前对话框的 DTextEntry
                        local entry = INE:Entry(editor, "ArrayVar")
                        if entry and IsValid(entry) then entry:Remove() end
                        INE:ClearEntry(editor, "ArrayVar")
                        INE:Field(editor, "ArrayVar").active = false
                        INE:Field(editor, "ArrayVar").editorID = nil
                        -- 清除父数组对话框的添加状态
                        INE:ArrayVarCtx(editor).pendingType = nil
                        INE:ArrayVarCtx(editor).itemValue = nil
                        -- 移除临时数组变量
                        local gVars = editor.variables["g"] or {}
                        if gVars[editor._numVarDialogIdx] then
                            table.remove(gVars, editor._numVarDialogIdx)
                        end
                        -- 恢复父编辑器状态
                        parentEditor._numVarDialogIdx = ctx.savedDialogIdx
                        parentEditor._numVarDialogIsNew = ctx.savedIsNew
                        INE:ArrayVarCtx(editor).nestedCtx = nil
                        -- 关闭当前（嵌套）数组对话框
                        INE:CloseOverlayWindow(editor, "ine_arrayvar_dialog")
                        -- 重新打开父数组对话框（被嵌套对话框覆盖了）
                        INE:ShowArrayVarDialog(parentEditor, ctx.savedDialogIdx)
                        handled = true
                        return
                    end

                    if vd then
                        local entry = INE:Entry(editor, "ArrayVar")
                        if entry and IsValid(entry) then entry:Remove() end
                        INE:ClearEntry(editor, "ArrayVar")
                        INE:Field(editor, "ArrayVar").active = false
                        INE:Field(editor, "ArrayVar").editorID = nil
                        INE:ArrayVarCtx(editor).pendingType = nil
                        INE:ArrayVarCtx(editor).itemValue = nil
                        vd.items = vd.items or {}
                        if #vd.items == 0 then
                            table.insert(vd.items, {type = "n", value = 0})
                        end
                        INE:CloseOverlayWindow(editor, "ine_arrayvar_dialog")
                        editor._numVarDialogIsNew = nil
                        handled = true
                    end
                end

                -- 取消按钮
                if not handled and editor._arrayVarCancelRect and INE:IsPointInRect(mouseX, mouseY, editor._arrayVarCancelRect) then
                    -- 检测是否在数组变量嵌套创建上下文中
                    if INE:ArrayVarCtx(editor).nestedCtx and INE:ArrayVarCtx(editor).nestedCtx.tempType == "g" then
                        local ctx = INE:ArrayVarCtx(editor).nestedCtx
                        -- 清理当前对话框的 DTextEntry
                        local entry = INE:Entry(editor, "ArrayVar")
                        if entry and IsValid(entry) then entry:Remove() end
                        INE:ClearEntry(editor, "ArrayVar")
                        INE:Field(editor, "ArrayVar").active = false
                        INE:Field(editor, "ArrayVar").editorID = nil
                        -- 移除临时数组变量
                        local gVars = editor.variables["g"] or {}
                        if gVars[editor._numVarDialogIdx] then
                            table.remove(gVars, editor._numVarDialogIdx)
                        end
                        -- 恢复父编辑器状态
                        local parentEditor = ctx.parentEditor
                        parentEditor._numVarDialogIdx = ctx.savedDialogIdx
                        parentEditor._numVarDialogIsNew = ctx.savedIsNew
                        INE:ArrayVarCtx(editor).nestedCtx = nil
                        -- 关闭当前（嵌套）数组对话框
                        INE:CloseOverlayWindow(editor, "ine_arrayvar_dialog")
                        -- 重新打开父数组对话框（被嵌套对话框覆盖了）
                        INE:ShowArrayVarDialog(parentEditor, ctx.savedDialogIdx)
                        handled = true
                        return
                    end

                    local entry = INE:Entry(editor, "ArrayVar")
                    if entry and IsValid(entry) then entry:Remove() end
                    INE:ClearEntry(editor, "ArrayVar")
                    INE:Field(editor, "ArrayVar").active = false
                    INE:Field(editor, "ArrayVar").editorID = nil
                    INE:ArrayVarCtx(editor).pendingType = nil
                    INE:ArrayVarCtx(editor).itemValue = nil
                    local gVars = editor.variables["g"] or {}
                    if editor._numVarDialogIsNew and gVars[editor._numVarDialogIdx] then
                        table.remove(gVars, editor._numVarDialogIdx)
                    end
                    editor._numVarDialogIsNew = nil
                    INE:CloseOverlayWindow(editor, "ine_arrayvar_dialog")
                    handled = true
                end
            elseif hoveredWindow.id == "ine_cardvar_dialog" then
                -- 卡牌对象对话框交互
                -- 变量名编辑
                if editor._cardVarField_name and INE:IsPointInRect(mouseX, mouseY, editor._cardVarField_name) then
                    INE:Field(editor, "CardVar").active = true
                    INE:Field(editor, "CardVar").field = "name"
                    INE:Field(editor, "CardVar").editorID = editor.panelID or editor.id
                    INE:Field(editor, "CardVar").varIdx = editor._numVarDialogIdx
                    INE:Field(editor, "CardVar").x = editor._cardVarField_name.x
                    INE:Field(editor, "CardVar").y = editor._cardVarField_name.y
                    INE:Field(editor, "CardVar").w = editor._cardVarField_name.w
                    INE:Field(editor, "CardVar").h = editor._cardVarField_name.h
                    handled = true
                -- 内部变量名编辑
                elseif editor._cardVarField_internalName and INE:IsPointInRect(mouseX, mouseY, editor._cardVarField_internalName) then
                    INE:Field(editor, "CardVar").active = true
                    INE:Field(editor, "CardVar").field = "iname"
                    INE:Field(editor, "CardVar").editorID = editor.panelID or editor.id
                    INE:Field(editor, "CardVar").varIdx = editor._numVarDialogIdx
                    INE:Field(editor, "CardVar").x = editor._cardVarField_internalName.x
                    INE:Field(editor, "CardVar").y = editor._cardVarField_internalName.y
                    INE:Field(editor, "CardVar").w = editor._cardVarField_internalName.w
                    INE:Field(editor, "CardVar").h = editor._cardVarField_internalName.h
                    handled = true
                -- 空对象单选按钮
                elseif editor._cardVarEmptyRadio and INE:IsPointInRect(mouseX, mouseY, editor._cardVarEmptyRadio) then
                    local vars = editor.variables["e"] or {}
                    local vd = vars[editor._numVarDialogIdx]
                    if vd then
                        vd._mode = "empty"
                        -- 清空已选卡牌
                        editor._cardVarSelectedFile = nil
                        vd.cardFile = nil
                        vd.cardName = nil
                        vd.cardAppearance = nil
                    end
                    handled = true
                -- 已保存的卡牌单选按钮
                elseif editor._cardVarSavedRadio and INE:IsPointInRect(mouseX, mouseY, editor._cardVarSavedRadio) then
                    local vars = editor.variables["e"] or {}
                    local vd = vars[editor._numVarDialogIdx]
                    if vd then
                        vd._mode = "saved"
                        -- 刷新卡牌列表缓存
                        editor._cardVarCardInfos = nil
                    end
                    handled = true
                end
                -- 卡牌列表项点击（独立 if，不阻塞后续按钮）
                if editor._cardVarItemRects then
                    for idx, itemRect in pairs(editor._cardVarItemRects) do
                        if INE:IsPointInRect(mouseX, mouseY, itemRect) then
                            local infos = editor._cardVarCardInfos or {}
                            local info = infos[idx]
                            if info then
                                editor._cardVarSelectedFile = info.fileName
                                local vars = editor.variables["e"] or {}
                                local vd = vars[editor._numVarDialogIdx]
                                if vd then
                                    vd.cardFile = info.fileName
                                    vd.cardName = info.name
                                    vd.cardAppearance = info.cardAppearance
                                end
                            end
                            break
                        end
                    end
                end
                -- 确定按钮
                if editor._cardVarConfirmRect and INE:IsPointInRect(mouseX, mouseY, editor._cardVarConfirmRect) then
                    local vars = editor.variables["e"] or {}
                    local vd = vars[editor._numVarDialogIdx]
                    if vd then
                        -- 确保变量名不为空
                        if vd.name == "" or not vd.name then vd.name = "card_obj" end
                        -- 如果选择了已保存卡牌但未选具体卡牌，默认转为空对象
                        if vd._mode == "saved" and not vd.cardFile then
                            vd._mode = "empty"
                        end

                        -- 检测是否在数组变量嵌套创建上下文中
                        if INE:ArrayVarCtx(editor).nestedCtx and INE:ArrayVarCtx(editor).nestedCtx.tempType == "e" then
                            local ctx = INE:ArrayVarCtx(editor).nestedCtx
                            local parentEditor = ctx.parentEditor
                            local parentVars = parentEditor.variables["g"] or {}
                            local parentVd = parentVars[ctx.parentVarIdx]
                            if parentVd then
                                -- 构建卡牌对象值
                                local cardValue = {}
                                if vd._mode == "empty" then
                                    cardValue.isEmpty = true
                                else
                                    cardValue.cardFile = vd.cardFile
                                    cardValue.cardName = vd.cardName
                                    cardValue.cardAppearance = vd.cardAppearance
                                end
                                -- 创建自包含的卡牌对象数组项
                                local newItem = {type = "e", value = cardValue}
                                parentVd.items = parentVd.items or {}
                                table.insert(parentVd.items, newItem)
                            end
                            -- 移除临时卡牌对象变量
                            local cardVars = editor.variables["e"] or {}
                            if cardVars[editor._numVarDialogIdx] then
                                table.remove(cardVars, editor._numVarDialogIdx)
                            end
                            -- 清除父数组对话框的添加状态
                            INE:ArrayVarCtx(editor).pendingType = nil
                            INE:ArrayVarCtx(editor).itemValue = nil
                            -- 恢复父编辑器状态
                            parentEditor._numVarDialogIdx = ctx.savedDialogIdx
                            parentEditor._numVarDialogIsNew = ctx.savedIsNew
                            INE:ArrayVarCtx(editor).nestedCtx = nil
                            -- 关闭卡牌对话框
                            local cardEntry = INE:Entry(editor, "CardVar")
                            if cardEntry and IsValid(cardEntry) then cardEntry:Remove() end
                            INE:ClearEntry(editor, "CardVar")
                            INE:Field(editor, "CardVar").active = false
                            INE:Field(editor, "CardVar").editorID = nil
                            INE:CloseOverlayWindow(editor, "ine_cardvar_dialog")
                            handled = true
                            return
                        end

                        -- 清理 DTextEntry 状态
                        local cardEntry = INE:Entry(editor, "CardVar")
                        if cardEntry and IsValid(cardEntry) then cardEntry:Remove() end
                        INE:ClearEntry(editor, "CardVar")
                        INE:Field(editor, "CardVar").active = false
                        INE:Field(editor, "CardVar").editorID = nil

                        -- 清理状态
                        editor._cardVarCardInfos = nil
                        editor._cardVarSelectedFile = nil
                        editor._cardVarScrollOffset = nil
                        editor._numVarDialogIsNew = nil
                        INE:CloseOverlayWindow(editor, "ine_cardvar_dialog")
                    end
                    handled = true
                -- 取消按钮
                elseif editor._cardVarCancelRect and INE:IsPointInRect(mouseX, mouseY, editor._cardVarCancelRect) then
                    -- 检测是否在数组变量嵌套创建上下文中
                    if INE:ArrayVarCtx(editor).nestedCtx and INE:ArrayVarCtx(editor).nestedCtx.tempType == "e" then
                        local ctx = INE:ArrayVarCtx(editor).nestedCtx
                        -- 移除临时卡牌对象变量
                        local cardVars = editor.variables["e"] or {}
                        if cardVars[editor._numVarDialogIdx] then
                            table.remove(cardVars, editor._numVarDialogIdx)
                        end
                        -- 清除父数组对话框的添加状态
                        INE:ArrayVarCtx(editor).pendingType = nil
                        INE:ArrayVarCtx(editor).itemValue = nil
                        -- 恢复父编辑器状态
                        local parentEditor = ctx.parentEditor
                        parentEditor._numVarDialogIdx = ctx.savedDialogIdx
                        parentEditor._numVarDialogIsNew = ctx.savedIsNew
                        INE:ArrayVarCtx(editor).nestedCtx = nil
                        -- 关闭卡牌对话框
                        local cardEntry = INE:Entry(editor, "CardVar")
                        if cardEntry and IsValid(cardEntry) then cardEntry:Remove() end
                        INE:ClearEntry(editor, "CardVar")
                        INE:Field(editor, "CardVar").active = false
                        INE:Field(editor, "CardVar").editorID = nil
                        INE:CloseOverlayWindow(editor, "ine_cardvar_dialog")
                        handled = true
                        return
                    end
                    -- 清理 DTextEntry 状态
                    local cardEntry = INE:Entry(editor, "CardVar")
                    if cardEntry and IsValid(cardEntry) then cardEntry:Remove() end
                    INE:ClearEntry(editor, "CardVar")
                    INE:Field(editor, "CardVar").active = false
                    INE:Field(editor, "CardVar").editorID = nil
                    -- 取消时删除变量（若为新创建的）
                    local vars = editor.variables["e"] or {}
                    if editor._numVarDialogIsNew and vars[editor._numVarDialogIdx] then
                        table.remove(vars, editor._numVarDialogIdx)
                    end
                    editor._numVarDialogIsNew = nil
                    editor._cardVarCardInfos = nil
                    editor._cardVarSelectedFile = nil
                    editor._cardVarScrollOffset = nil
                    INE:CloseOverlayWindow(editor, "ine_cardvar_dialog")
                    handled = true
                end
            elseif hoveredWindow.id == "ine_stringvar_dialog" then
                -- 字符串变量对话框字段点击编辑（激活 DTextEntry 内联输入）
                if editor._stringVarField_name and INE:IsPointInRect(mouseX, mouseY, editor._stringVarField_name) then
                    local vars = editor.variables["t"] or {}
                    local vd = vars[editor._stringVarDialogIdx]
                    if vd then
                        INE:Field(editor, "StringVar").active = true
                        INE:Field(editor, "StringVar").field = "name"
                        INE:Field(editor, "StringVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "StringVar").varIdx = editor._stringVarDialogIdx
                        INE:Field(editor, "StringVar").x = editor._stringVarField_name.x
                        INE:Field(editor, "StringVar").y = editor._stringVarField_name.y
                        INE:Field(editor, "StringVar").w = editor._stringVarField_name.w
                        INE:Field(editor, "StringVar").h = editor._stringVarField_name.h
                    end
                elseif editor._stringVarField_iname and INE:IsPointInRect(mouseX, mouseY, editor._stringVarField_iname) then
                    local vars = editor.variables["t"] or {}
                    local vd = vars[editor._stringVarDialogIdx]
                    if vd then
                        INE:Field(editor, "StringVar").active = true
                        INE:Field(editor, "StringVar").field = "iname"
                        INE:Field(editor, "StringVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "StringVar").varIdx = editor._stringVarDialogIdx
                        INE:Field(editor, "StringVar").x = editor._stringVarField_iname.x
                        INE:Field(editor, "StringVar").y = editor._stringVarField_iname.y
                        INE:Field(editor, "StringVar").w = editor._stringVarField_iname.w
                        INE:Field(editor, "StringVar").h = editor._stringVarField_iname.h
                    end
                elseif editor._stringVarField_text and INE:IsPointInRect(mouseX, mouseY, editor._stringVarField_text) then
                    local vars = editor.variables["t"] or {}
                    local vd = vars[editor._stringVarDialogIdx]
                    if vd then
                        INE:Field(editor, "StringVar").active = true
                        INE:Field(editor, "StringVar").field = "text"
                        INE:Field(editor, "StringVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "StringVar").varIdx = editor._stringVarDialogIdx
                        INE:Field(editor, "StringVar").x = editor._stringVarField_text.x
                        INE:Field(editor, "StringVar").y = editor._stringVarField_text.y
                        INE:Field(editor, "StringVar").w = editor._stringVarField_text.w
                        INE:Field(editor, "StringVar").h = editor._stringVarField_text.h
                    end
                elseif editor._stringVarConfirmRect and INE:IsPointInRect(mouseX, mouseY, editor._stringVarConfirmRect) then
                    -- 确定：关闭前清理 DTextEntry
                    local entry = INE:Entry(editor, "StringVar")
                    if entry and IsValid(entry) then entry:Remove() end
                    INE:ClearEntry(editor, "StringVar")
                    INE:Field(editor, "StringVar").active = false
                    INE:Field(editor, "StringVar").editorID = nil
                    INE:CloseOverlayWindow(editor, "ine_stringvar_dialog")
                elseif editor._stringVarCancelRect and INE:IsPointInRect(mouseX, mouseY, editor._stringVarCancelRect) then
                    -- 取消时清理 DTextEntry
                    local entry = INE:Entry(editor, "StringVar")
                    if entry and IsValid(entry) then entry:Remove() end
                    INE:ClearEntry(editor, "StringVar")
                    INE:Field(editor, "StringVar").active = false
                    INE:Field(editor, "StringVar").editorID = nil
                    -- 取消时删除变量（若为新创建的）
                    local vars = editor.variables["t"] or {}
                    if editor._stringVarDialogIsNew and vars[editor._stringVarDialogIdx] then
                        table.remove(vars, editor._stringVarDialogIdx)
                    end
                    editor._stringVarDialogIsNew = nil
                    INE:CloseOverlayWindow(editor, "ine_stringvar_dialog")
                end
            elseif hoveredWindow.id == "ine_boolvar_dialog" then
                -- 布尔值变量对话框字段点击编辑（激活 DTextEntry 内联输入）
                if editor._boolVarField_name and INE:IsPointInRect(mouseX, mouseY, editor._boolVarField_name) then
                    local vars = editor.variables["p"] or {}
                    local vd = vars[editor._boolVarDialogIdx]
                    if vd then
                        INE:Field(editor, "BoolVar").active = true
                        INE:Field(editor, "BoolVar").field = "name"
                        INE:Field(editor, "BoolVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "BoolVar").varIdx = editor._boolVarDialogIdx
                        INE:Field(editor, "BoolVar").x = editor._boolVarField_name.x
                        INE:Field(editor, "BoolVar").y = editor._boolVarField_name.y
                        INE:Field(editor, "BoolVar").w = editor._boolVarField_name.w
                        INE:Field(editor, "BoolVar").h = editor._boolVarField_name.h
                    end
                elseif editor._boolVarField_iname and INE:IsPointInRect(mouseX, mouseY, editor._boolVarField_iname) then
                    local vars = editor.variables["p"] or {}
                    local vd = vars[editor._boolVarDialogIdx]
                    if vd then
                        INE:Field(editor, "BoolVar").active = true
                        INE:Field(editor, "BoolVar").field = "iname"
                        INE:Field(editor, "BoolVar").editorID = editor.panelID or editor.id
                        INE:Field(editor, "BoolVar").varIdx = editor._boolVarDialogIdx
                        INE:Field(editor, "BoolVar").x = editor._boolVarField_iname.x
                        INE:Field(editor, "BoolVar").y = editor._boolVarField_iname.y
                        INE:Field(editor, "BoolVar").w = editor._boolVarField_iname.w
                        INE:Field(editor, "BoolVar").h = editor._boolVarField_iname.h
                    end
                elseif editor._boolVarField_true and INE:IsPointInRect(mouseX, mouseY, editor._boolVarField_true) then
                    local vars = editor.variables["p"] or {}
                    local vd = vars[editor._boolVarDialogIdx]
                    if vd then
                        vd.initialValue = true
                    end
                elseif editor._boolVarField_false and INE:IsPointInRect(mouseX, mouseY, editor._boolVarField_false) then
                    local vars = editor.variables["p"] or {}
                    local vd = vars[editor._boolVarDialogIdx]
                    if vd then
                        vd.initialValue = false
                    end
                elseif editor._boolVarConfirmRect and INE:IsPointInRect(mouseX, mouseY, editor._boolVarConfirmRect) then
                    -- 确定：关闭前清理 DTextEntry
                    local entry = INE:Entry(editor, "BoolVar")
                    if entry and IsValid(entry) then entry:Remove() end
                    INE:ClearEntry(editor, "BoolVar")
                    INE:Field(editor, "BoolVar").active = false
                    INE:Field(editor, "BoolVar").editorID = nil
                    INE:CloseOverlayWindow(editor, "ine_boolvar_dialog")
                elseif editor._boolVarCancelRect and INE:IsPointInRect(mouseX, mouseY, editor._boolVarCancelRect) then
                    -- 取消时清理 DTextEntry
                    local entry = INE:Entry(editor, "BoolVar")
                    if entry and IsValid(entry) then entry:Remove() end
                    INE:ClearEntry(editor, "BoolVar")
                    INE:Field(editor, "BoolVar").active = false
                    INE:Field(editor, "BoolVar").editorID = nil
                    -- 取消时删除变量（若为新创建的）
                    local vars = editor.variables["p"] or {}
                    if editor._boolVarDialogIsNew and vars[editor._boolVarDialogIdx] then
                        table.remove(vars, editor._boolVarDialogIdx)
                    end
                    editor._boolVarDialogIsNew = nil
                    INE:CloseOverlayWindow(editor, "ine_boolvar_dialog")
                end
            end
        end
    end
end

--[[
    将效果数据（LoadEffect 返回）反序列化并替换编辑器内容。
    供 INE 导入窗口（ine_import_window）与卡牌加载联动（canvas 加载卡牌后导入绑定的效果）复用，
    完整恢复节点/连接/数据线/视图/变量（含数组变量）与函数子编辑器数据。

    @param editor INE 编辑器实例
    @param data   table 效果数据（含 nodes/connections/dataConnections/variables/functions/view）
    @return boolean 是否导入成功（editor 或 data.nodes 缺失返回 false）
]]
function INE:ImportEffectData(editor, data)
    if not editor or not data or not data.nodes then return false end

    -- 反序列化节点（保留原始 id 以维持连接引用，含开始点/删除标记等字段）
    local newNodeCounter = 0
    local newNodes = {}
    for _, nd in ipairs(data.nodes) do
        local template = INE.RegisteredNodes[nd.name]
        local node = {
            id = nd.id,
            name = nd.name,
            displayName = template and template.displayName or nd.name,
            type = nd.type or nd.name,
            color = template and Color(template.color.r, template.color.g, template.color.b, template.color.a or 255) or Color(150, 150, 150),
            x = nd.x or 0,
            y = nd.y or 0,
            width = nd.width or 200,
            height = nd.height or 80,
            hasInput = nd.hasInput,
            hasOutput = nd.hasOutput,
            hasInputs = nd.hasInputs,
            hasOutputs = nd.hasOutputs,
            inputTypes = nd.inputTypes or {},
            outputTypes = nd.outputTypes or {},
            config = nd.config or "",
            parsedConfig = template and template.parsedConfig or nil,
            availableInputTypes = (template and template.availableInputTypes) or {},
            availableOutputTypes = (template and template.availableOutputTypes) or {},
            selectedInputTypes = nd.selectedInputTypes or {},
            selectedOutputTypes = nd.selectedOutputTypes or {},
            dataPortDropdownActive = false,
            inputDataPortDropdownActive = false,
            isStartNode = nd.isStartNode or false,
            canDelete = (nd.canDelete == nil) and true or nd.canDelete,
            drawFunction = template and template.drawFunction or nil,
            data = nd.data or {},
            dragging = false,
            dragStartX = 0,
            dragStartY = 0,
            startX = 0,
            startY = 0,
            isInvalid = false,
            isUnregistered = false,
            editor = editor
        }
        table.insert(newNodes, node)
        local num = tonumber(node.id:match("ine_node_(%d+)"))
        if num and num > newNodeCounter then
            newNodeCounter = num
        end
    end

    -- 反序列化连接
    local newConns = {}
    for _, cd in ipairs(data.connections or {}) do
        table.insert(newConns, {
            id = cd.id,
            fromNode = cd.fromNode,
            toNode = cd.toNode,
            fromPort = cd.fromPort
        })
    end

    -- 反序列化数据连接
    local newDataConns = {}
    for _, cd in ipairs(data.dataConnections or {}) do
        table.insert(newDataConns, {
            id = cd.id,
            fromNode = cd.fromNode,
            toNode = cd.toNode,
            fromPortIndex = cd.fromPortIndex,
            toPortIndex = cd.toPortIndex,
            dataType = cd.dataType,
            variableName = cd.variableName
        })
    end

    -- 替换编辑器内容
    editor.nodes = newNodes
    editor.connections = newConns
    editor.dataConnections = newDataConns
    editor.nodeCounter = math.max(newNodeCounter, data.nodeCounter or 0)
    editor.dataConnectionCounter = data.dataConnectionCounter or 0

    -- 恢复视图状态
    if data.view then
        editor.canvasOffsetX = data.view.canvasOffsetX or 0
        editor.canvasOffsetY = data.view.canvasOffsetY or 0
        editor.canvasScale = data.view.canvasScale or 1
    end

    -- 恢复变量数据（含数组变量及其项内的 functionData）
    if data.variables then
        editor.variables = data.variables
        -- 去除 KARDS.User. 前缀，还原为用户输入的原值
        INE:StripInternalNames(editor.variables)
    end

    -- 恢复函数子编辑器的已保存数据
    if data.functions then
        editor._importedFunctionData = data.functions
        for varName, funcData in pairs(data.functions) do
            local subID = "ine_func_" .. editor.id .. "_" .. varName
            local subEditor = INE.Editors[subID]
            if subEditor then
                subEditor._savedFunctionData = funcData
            end
        end
    end

    return true
end
