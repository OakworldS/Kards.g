--[[
=======================================================================================
变量对话框系统 (Variable Dialog System)
=======================================================================================
从 cl_ine_node_editor.lua 拆分出的子系统，负责变量创建/编辑对话框。

包含功能：
  - ShowNumberVarDialog（数字变量创建/编辑对话框）
  - ShowFuncVarDialog（函数变量创建/编辑对话框）
  - ShowArrayVarDialog（数组变量创建/编辑对话框）
  - ShowCardVarDialog（卡牌对象变量创建/编辑对话框）
  - ShowStringVarDialog（字符串变量创建/编辑对话框）

依赖：
  - INE:ShowOverlayWindow（在 cl_ine_node_editor.lua 中定义）
  - INE.VarSearchState、INE.NumVarFieldState、INE.FuncVarFieldState、INE.ArrayVarFieldState
    （DTextEntry IME 兼容方案状态，在 cl_ine_node_editor.lua 行 54~100 声明）

源文件：cl_ine_node_editor.lua（行 2183~2817）
=======================================================================================
]]

-- 此文件内容将剪切自 cl_ine_node_editor.lua 行 2183~2817
-- 包含：ShowNumberVarDialog、ShowFuncVarDialog、ShowArrayVarDialog
local INE = KARDS.CardEditor.IndependentNodeEditor

-- 节点选择器"高级"上拉框辅助：统计固定展示的基础变量系统节点数量
-- 基础变量系统节点由 cl_ine_var_op_nodes.lua RegisterAll 标记 _varOpNode 并保存内置清单
-- INE._varOpNodeKeys，主列表不显示，仅展开"高级"后在底部上拉框中固定展示。
-- 内置节点不依赖面板 allowedNodes：任何 INE 面板固定展示，无需在 allowedNodes 中显式注册。
-- cl_ine_input_handling.lua 的点击/滚轮区域计算共用本函数，保证两处一致。
-- 获取内置基础变量节点模板列表（{name=, template=}，按 INE._varOpNodeKeys 顺序）
function INE:GetAdvVarOpNodes()
    local list = {}
    for _, tKey in ipairs(INE._varOpNodeKeys or {}) do
        local template = INE.RegisteredNodes and INE.RegisteredNodes[tKey]
        if template and template._varOpNode then
            table.insert(list, { name = tKey, template = template })
        end
    end
    return list
end

function INE:GetAdvVarOpCount(editor)
    return #INE:GetAdvVarOpNodes()
end
--[[
    显示数字变量创建/编辑对话框。
    提供一个覆盖窗口，显示变量名、内部名称、初始值三个可点击编辑的字段。
    点击字段会弹出 Derma_StringRequest 进行编辑。
    
    @param  editor  {table}   编辑器实例
    @param  varIdx  {number}  变量在 editor.variables["n"] 中的索引
    @param  varData {table}   变量数据 {name, desc, internalName, initialValue}
]]
function INE:ShowNumberVarDialog(editor, varIdx, varData)
    local dialogW, dialogH = 400, 250
    INE:ShowOverlayWindow(editor, {
        id = "ine_numvar_dialog",
        title = "数字变量",
        showScope = true, scope = varData.scope or "global",
        x = editor.x + (editor.width - dialogW) / 2,
        y = editor.y + (editor.height - dialogH) / 2,
        width = dialogW,
        height = dialogH,
        content = function(ed, win, cx, cy, cw, ch)
            local mx, my = gui.MouseX(), gui.MouseY()
            local vars = ed.variables["n"] or {}
            local vd = vars[varIdx]
            if not vd then return end
            local activeField = INE.NumVarFieldState and INE.NumVarFieldState.active and INE.NumVarFieldState.field

            -- 变量名
            draw.SimpleText("变量名:", "SourceHan_Heavy_12", cx + 15, cy + 15, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local nameX, nameY, nameW, nameH = cx + 15, cy + 35, cw - 30, 30
            local nameHov = mx >= nameX and mx <= nameX + nameW and my >= nameY and my <= nameY + nameH
            local nameActive = activeField == "name"
            draw.RoundedBox(4, nameX, nameY, nameW, nameH, nameActive and Color(60, 65, 80) or (nameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if nameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(nameX, nameY, nameW, nameH)
            end
            local nameText = vd.name or ""
            draw.SimpleText(nameText, "SourceHan_Heavy_14", nameX + 10, nameY + nameH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            -- 光标（激活时闪烁）
            if nameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_14")
                local cursorX = nameX + 10 + surface.GetTextSize(nameText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, nameY + 4, cursorX, nameY + nameH - 4)
            end
            ed._numVarField_name = {x = nameX, y = nameY, w = nameW, h = nameH}

            -- 内部名称
            draw.SimpleText("内部名称（代码中使用，留空自动分配唯一ID）:", "SourceHan_Heavy_10", cx + 15, cy + 75, Color(160, 160, 160), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local inameX, inameY, inameW, inameH = cx + 15, cy + 92, cw - 30, 28
            local inameHov = mx >= inameX and mx <= inameX + inameW and my >= inameY and my <= inameY + inameH
            local inameActive = activeField == "iname"
            draw.RoundedBox(4, inameX, inameY, inameW, inameH, inameActive and Color(60, 65, 80) or (inameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if inameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(inameX, inameY, inameW, inameH)
            end
            local displayIname = (vd.internalName and not vd.internalName:match("^n_var_")) and vd.internalName or ""
            draw.SimpleText(displayIname, "SourceHan_Heavy_12", inameX + 10, inameY + inameH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            -- 光标（激活时闪烁）
            if inameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_12")
                local cursorX = inameX + 10 + surface.GetTextSize(displayIname)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, inameY + 3, cursorX, inameY + inameH - 3)
            end
            ed._numVarField_iname = {x = inameX, y = inameY, w = inameW, h = inameH}

            -- 初始值
            draw.SimpleText("初始值:", "SourceHan_Heavy_12", cx + 15, cy + 130, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local valX, valY, valW, valH = cx + 15, cy + 150, cw - 30, 28
            local valHov = mx >= valX and mx <= valX + valW and my >= valY and my <= valY + valH
            local valActive = activeField == "val"
            draw.RoundedBox(4, valX, valY, valW, valH, valActive and Color(60, 65, 80) or (valHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if valActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(valX, valY, valW, valH)
            end
            local valText = tostring(vd.initialValue or 0)
            draw.SimpleText(valText, "SourceHan_Heavy_12", valX + 10, valY + valH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            -- 光标（激活时闪烁）
            if valActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_12")
                local cursorX = valX + 10 + surface.GetTextSize(valText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, valY + 3, cursorX, valY + valH - 3)
            end
            ed._numVarField_val = {x = valX, y = valY, w = valW, h = valH}
            
            -- 确定 / 取消按钮
            local btnY = cy + ch - 40
            local confirmHov = mx >= cx + cw/2 - 80 and mx <= cx + cw/2 - 80 + 70 and my >= btnY and my <= btnY + 28
            local cancelHov = mx >= cx + cw/2 + 10 and mx <= cx + cw/2 + 10 + 70 and my >= btnY and my <= btnY + 28
            draw.RoundedBox(6, cx + cw/2 - 80, btnY, 70, 28, confirmHov and Color(70, 120, 70) or Color(55, 65, 55))
            draw.SimpleText("确定", "SourceHan_Heavy_14", cx + cw/2 - 45, btnY + 14, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.RoundedBox(6, cx + cw/2 + 10, btnY, 70, 28, cancelHov and Color(100, 60, 60) or Color(65, 55, 55))
            draw.SimpleText("取消", "SourceHan_Heavy_14", cx + cw/2 + 45, btnY + 14, Color(255, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            ed._numVarConfirmRect = {x = cx + cw/2 - 80, y = btnY, w = 70, h = 28}
            ed._numVarCancelRect = {x = cx + cw/2 + 10, y = btnY, w = 70, h = 28}
        end
    })
end

--[[
    显示函数变量创建/编辑对话框。
    提供叠加窗口，让用户编辑函数名称和参数列表。
    参数列表以 DTextEntry 方式添加。
    
    @param  editor  {table}   编辑器实例
    @param  varIdx  {number}  变量在 editor.variables["f"] 中的索引
]]
function INE:ShowFuncVarDialog(editor, varIdx)
    local dialogW, dialogH = 400, 380
    local dataEditor = editor._funcDialogDataEditor or editor
    local funcVars = dataEditor.variables["f"] or {}
    local funcVarData = funcVars[varIdx]
    local funcScope = funcVarData and funcVarData.scope or "global"
    INE:ShowOverlayWindow(editor, {
        id = "ine_funcvar_dialog",
        title = "函数变量",
        showScope = true, scope = funcScope,
        x = editor.x + (editor.width - dialogW) / 2,
        y = editor.y + (editor.height - dialogH) / 2,
        width = dialogW,
        height = dialogH,
        content = function(ed, win, cx, cy, cw, ch)
            local mx, my = gui.MouseX(), gui.MouseY()
            local dataEditor = ed._funcDialogDataEditor or ed
            local vars = dataEditor.variables["f"] or {}
            local vd = vars[varIdx]
            if not vd then return end

            -- 函数名称
            draw.SimpleText("函数名称:", "SourceHan_Heavy_12", cx + 15, cy + 10, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local nameX, nameY, nameW, nameH = cx + 15, cy + 28, cw - 30, 28
            local nameHov = mx >= nameX and mx <= nameX + nameW and my >= nameY and my <= nameY + nameH
            local nameActive = INE.FuncVarFieldState and INE.FuncVarFieldState.active and INE.FuncVarFieldState.editorID == (ed.panelID or ed.id)
            draw.RoundedBox(4, nameX, nameY, nameW, nameH, nameActive and Color(60, 65, 80) or (nameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if nameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(nameX, nameY, nameW, nameH)
            end
            local nameText = vd.name or ""
            draw.SimpleText(nameText, "SourceHan_Heavy_14", nameX + 10, nameY + nameH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            -- 光标
            if nameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_14")
                local cursorX = nameX + 10 + surface.GetTextSize(nameText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, nameY + 3, cursorX, nameY + nameH - 3)
            end
            ed._funcVarField_name = {x = nameX, y = nameY, w = nameW, h = nameH}

            -- 参数列表标题
            local listTitleY = cy + 65
            draw.SimpleText("参数列表:", "SourceHan_Heavy_12", cx + 15, listTitleY, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

            -- 参数列表（每项显示：类型图标 + 参数名 + 删除按钮）
            local params = vd.params or {}
            ed._funcVarParamDel = {}
            -- 建立类型ID→DataTypes的反查表
            local idToDt = {}
            for _, dt in pairs(INE.DataTypes) do
                idToDt[dt.id] = dt
            end
            local paramStartY = listTitleY + 18
            local paramItemH = 22
            for pi, param in ipairs(params) do
                local py = paramStartY + (pi - 1) * paramItemH
                draw.RoundedBox(4, cx + 15, py, cw - 50, paramItemH, Color(50, 55, 60))
                -- 类型图标
                local dt = idToDt[param.type] or idToDt["n"]
                INE.DrawDataTypeIcon(dt, cx + 22, py + paramItemH / 2, 10)
                -- 参数名
                draw.SimpleText(param.name or "", "SourceHan_Heavy_12", cx + 36, py + paramItemH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                -- 删除按钮
                local delX = cx + cw - 40
                local delHov = mx >= delX and mx <= delX + 22 and my >= py and my <= py + paramItemH
                draw.RoundedBox(4, delX, py + 2, 22, paramItemH - 4, delHov and Color(180, 60, 60) or Color(70, 50, 50))
                draw.SimpleText("x", "SourceHan_Heavy_12", delX + 11, py + paramItemH / 2, Color(220, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                ed._funcVarParamDel[pi] = {x = delX, y = py + 2, w = 22, h = paramItemH - 4}
            end

            -- 添加参数输入框
            local addFieldY = paramStartY + #params * paramItemH + 6
            local paramFieldActive = INE.FuncParamFieldState and INE.FuncParamFieldState.active and INE.FuncParamFieldState.editorID == (ed.panelID or ed.id)
            local pfieldX, pfieldY, pfieldW, pfieldH = cx + 15, addFieldY, cw - 100, 24
            draw.RoundedBox(4, pfieldX, pfieldY, pfieldW, pfieldH, paramFieldActive and Color(60, 65, 80) or Color(45, 45, 50))
            if paramFieldActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(pfieldX, pfieldY, pfieldW, pfieldH)
            end
            local paramInputText = INE.FuncParamFieldState and INE.FuncParamFieldState.text or ""
            if paramInputText ~= "" then
                draw.SimpleText(paramInputText, "SourceHan_Heavy_12", pfieldX + 8, pfieldY + pfieldH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            else
                draw.SimpleText("输入参数名...", "SourceHan_Heavy_12", pfieldX + 8, pfieldY + pfieldH / 2, Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
            -- 光标
            if paramFieldActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_12")
                local cursorX = pfieldX + 8 + surface.GetTextSize(paramInputText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, pfieldY + 3, cursorX, pfieldY + pfieldH - 3)
            end
            ed._funcVarField_param = {x = pfieldX, y = pfieldY, w = pfieldW, h = pfieldH}

            -- 添加按钮
            local addBtnX = pfieldX + pfieldW + 6
            local addBtnHov = mx >= addBtnX and mx <= addBtnX + 50 and my >= pfieldY and my <= pfieldY + pfieldH
            draw.RoundedBox(4, addBtnX, pfieldY, 50, pfieldH, addBtnHov and Color(70, 120, 70) or Color(55, 65, 55))
            draw.SimpleText("添加", "SourceHan_Heavy_12", addBtnX + 25, pfieldY + pfieldH / 2, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            ed._funcVarField_addBtn = {x = addBtnX, y = pfieldY, w = 50, h = pfieldH}

            -- 参数类型选择器（仅在待确认添加参数时显示）
            ed._funcVarTypeBtns = {}
            if ed._funcVarPendingParam then
                local pendingY = pfieldY + pfieldH + 8
                draw.SimpleText("选择参数类型:", "SourceHan_Heavy_10", cx + 15, pendingY + 11, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local typeBtnSize2 = 22
                local typeBtnGap2 = 6
                local typeStartX2 = cx + 110
                local typeStartY2 = pendingY
                local sortedTypes2 = {}
                for _, dt in pairs(INE.DataTypes) do
                    table.insert(sortedTypes2, dt)
                end
                table.sort(sortedTypes2, function(a, b) return a.id < b.id end)
                ed._funcDialogSelectedType = ed._funcDialogSelectedType or "n"
                for ti, dataType in ipairs(sortedTypes2) do
                    local btnX = typeStartX2 + (ti - 1) * (typeBtnSize2 + typeBtnGap2)
                    local isSelected = (ed._funcDialogSelectedType == dataType.id)
                    local btnHov = mx >= btnX and mx <= btnX + typeBtnSize2 and my >= typeStartY2 and my <= typeStartY2 + typeBtnSize2
                    if isSelected then
                        draw.RoundedBox(4, btnX, typeStartY2, typeBtnSize2, typeBtnSize2, Color(60, 70, 90))
                        surface.SetDrawColor(Color(100, 150, 255, 180))
                        surface.DrawOutlinedRect(btnX, typeStartY2, typeBtnSize2, typeBtnSize2)
                    elseif btnHov then
                        draw.RoundedBox(4, btnX, typeStartY2, typeBtnSize2, typeBtnSize2, Color(60, 65, 75))
                    else
                        draw.RoundedBox(4, btnX, typeStartY2, typeBtnSize2, typeBtnSize2, Color(50, 55, 65))
                    end
                    INE.DrawDataTypeIcon(dataType, btnX + typeBtnSize2 / 2, typeStartY2 + typeBtnSize2 / 2, 12)
                    ed._funcVarTypeBtns[dataType.id] = {x = btnX, y = typeStartY2, w = typeBtnSize2, h = typeBtnSize2}
                end
            end

            -- 确定 / 取消按钮
            local btnY = cy + ch - 40
            local confirmHov = mx >= cx + cw/2 - 80 and mx <= cx + cw/2 - 80 + 70 and my >= btnY and my <= btnY + 28
            local cancelHov = mx >= cx + cw/2 + 10 and mx <= cx + cw/2 + 10 + 70 and my >= btnY and my <= btnY + 28
            draw.RoundedBox(6, cx + cw/2 - 80, btnY, 70, 28, confirmHov and Color(70, 120, 70) or Color(55, 65, 55))
            draw.SimpleText("确定", "SourceHan_Heavy_14", cx + cw/2 - 45, btnY + 14, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.RoundedBox(6, cx + cw/2 + 10, btnY, 70, 28, cancelHov and Color(100, 60, 60) or Color(65, 55, 55))
            draw.SimpleText("取消", "SourceHan_Heavy_14", cx + cw/2 + 45, btnY + 14, Color(255, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            ed._funcVarConfirmRect = {x = cx + cw/2 - 80, y = btnY, w = 70, h = 28}
            ed._funcVarCancelRect = {x = cx + cw/2 + 10, y = btnY, w = 70, h = 28}
        end
    })
end

--[[
    显示数组变量创建/编辑对话框。
    提供叠加窗口，让用户编辑数组变量名称和成员项。
    
    @param  editor  {table}   编辑器实例
    @param  varIdx  {number}  变量在 editor.variables["g"] 中的索引
]]
function INE:ShowArrayVarDialog(editor, varIdx)
    local dialogW, dialogH = 420, 500
    editor._arrayVarDialogVarIdx = varIdx
    editor._arrayVarScrollOffset = 0
    local arrVarData = (editor.variables["g"] or {})[varIdx]
    local arrScope = arrVarData and arrVarData.scope or "global"
    INE:ShowOverlayWindow(editor, {
        id = "ine_arrayvar_dialog",
        title = "数组变量",
        showScope = true, scope = arrScope,
        x = editor.x + (editor.width - dialogW) / 2,
        y = editor.y + (editor.height - dialogH) / 2,
        width = dialogW,
        height = dialogH,
        content = function(ed, win, cx, cy, cw, ch)
            local mx, my = gui.MouseX(), gui.MouseY()
            local vars = ed.variables["g"] or {}
            local vd = vars[varIdx]
            if not vd then return end
            local activeField = INE.ArrayVarFieldState and INE.ArrayVarFieldState.active and INE.ArrayVarFieldState.field

            -- 变量名
            draw.SimpleText("变量名:", "SourceHan_Heavy_12", cx + 15, cy + 10, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local nameX, nameY, nameW, nameH = cx + 15, cy + 28, cw - 30, 28
            local nameHov = mx >= nameX and mx <= nameX + nameW and my >= nameY and my <= nameY + nameH
            local nameActive = activeField == "name"
            draw.RoundedBox(4, nameX, nameY, nameW, nameH, nameActive and Color(60, 65, 80) or (nameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if nameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(nameX, nameY, nameW, nameH)
            end
            local nameText = vd.name or ""
            draw.SimpleText(nameText, "SourceHan_Heavy_14", nameX + 10, nameY + nameH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if nameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_14")
                local cursorX = nameX + 10 + surface.GetTextSize(nameText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, nameY + 4, cursorX, nameY + nameH - 4)
            end
            ed._arrayVarField_name = {x = nameX, y = nameY, w = nameW, h = nameH}

            -- 内部名称
            draw.SimpleText("内部名称（代码中使用，留空自动分配唯一ID）:", "SourceHan_Heavy_10", cx + 15, cy + 62, Color(160, 160, 160), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local inameX, inameY, inameW, inameH = cx + 15, cy + 78, cw - 30, 28
            local inameHov = mx >= inameX and mx <= inameX + inameW and my >= inameY and my <= inameY + inameH
            local inameActive = activeField == "iname"
            draw.RoundedBox(4, inameX, inameY, inameW, inameH, inameActive and Color(60, 65, 80) or (inameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if inameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(inameX, inameY, inameW, inameH)
            end
            local displayIname = (vd.internalName and not vd.internalName:match("^g_var_")) and vd.internalName or ""
            draw.SimpleText(displayIname, "SourceHan_Heavy_12", inameX + 10, inameY + inameH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if inameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_12")
                local cursorX = inameX + 10 + surface.GetTextSize(displayIname)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, inameY + 3, cursorX, inameY + inameH - 3)
            end
            ed._arrayVarField_iname = {x = inameX, y = inameY, w = inameW, h = inameH}

            -- 项列表标题
            local listTitleY = cy + 115
            draw.SimpleText("数组成员:", "SourceHan_Heavy_12", cx + 15, listTitleY, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

            -- 建立类型ID→DataTypes的反查表
            local idToDt = {}
            for _, dt in pairs(INE.DataTypes) do
                idToDt[dt.id] = dt
            end

            -- 项列表（支持滚动）
            local items = vd.items or {}
            ed._arrayVarItemDel = {}
            local itemStartY = listTitleY + 18
            local itemH = 22
            -- 可用高度 = 总客户区高度 - 底部按钮区域(45) - 顶部区域(itemStartY - cy) - 添加区域最小高度(40)
            local maxVisible = math.floor((ch - 45 - (itemStartY - cy) - 40) / itemH)
            local maxOffset = math.max(0, #items - maxVisible)
            local scrollOffset = math.min(ed._arrayVarScrollOffset or 0, maxOffset)
            ed._arrayVarScrollOffset = scrollOffset
            local visibleItems = math.min(#items - scrollOffset, maxVisible)
            -- 存储项列表区域用于滚轮检测
            ed._arrayItemListRect = {x = cx + 15, y = itemStartY, w = cw - 50, h = visibleItems * itemH}
            -- 超过11项时显示滚动指示器
            if maxOffset > 0 then
                local indicatorColor = Color(150, 150, 160)
                if scrollOffset > 0 then
                    draw.SimpleText("▲", "SourceHan_Heavy_10", cx + cw - 18, itemStartY - 8, indicatorColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                end
                local lastItemBottom = itemStartY + visibleItems * itemH
                if scrollOffset + visibleItems < #items then
                    draw.SimpleText("▼", "SourceHan_Heavy_10", cx + cw - 18, lastItemBottom + 2, indicatorColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                end
            end
            for ii = 1, visibleItems do
                local realIdx = ii + scrollOffset
                local item = items[realIdx]
                local iy = itemStartY + (ii - 1) * itemH
                draw.RoundedBox(4, cx + 15, iy, cw - 50, itemH, Color(50, 55, 60))
                local dt = idToDt[item.type] or idToDt["n"]
                INE.DrawDataTypeIcon(dt, cx + 22, iy + itemH / 2, 10)
                local previewStr = ""
                if item.type == "n" then
                    previewStr = tostring(item.value or 0)
                elseif item.type == "t" then
                    previewStr = "\"" .. tostring(item.value or "") .. "\""
                elseif item.type == "p" then
                    previewStr = tostring(item.value or false)
                elseif item.type == "f" then
                    local fname = item.value or ""
                    previewStr = fname .. "()"
                elseif item.type == "g" then
                    previewStr = "[...]"
                elseif item.type == "e" then
                    local cv = item.value or {}
                    if cv.isEmpty then
                        previewStr = "空对象"
                    else
                        previewStr = cv.cardName or (cv.cardFile and cv.cardFile:gsub("%.json$", "") or "已保存卡牌")
                    end
                end
                -- 截断过长的预览文本
                if #previewStr > 20 then
                    previewStr = string.sub(previewStr, 1, 18) .. ".."
                end
                draw.SimpleText(previewStr, "SourceHan_Heavy_10", cx + 36, iy + itemH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local delX = cx + cw - 40
                local delHov = mx >= delX and mx <= delX + 22 and my >= iy and my <= iy + itemH
                draw.RoundedBox(4, delX, iy + 2, 22, itemH - 4, delHov and Color(180, 60, 60) or Color(70, 50, 50))
                draw.SimpleText("x", "SourceHan_Heavy_12", delX + 11, iy + itemH / 2, Color(220, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                ed._arrayVarItemDel[realIdx] = {x = delX, y = iy + 2, w = 22, h = itemH - 4}
            end

            -- 添加区域
            local addAreaY = itemStartY + visibleItems * itemH + 6
            if addAreaY + 40 < cy + ch - 45 then
                -- "添加项"按钮
                local addBtnX, addBtnY, addBtnW, addBtnH = cx + 15, addAreaY, 70, 24
                local addBtnHov = mx >= addBtnX and mx <= addBtnX + addBtnW and my >= addBtnY and my <= addBtnY + addBtnH
                draw.RoundedBox(4, addBtnX, addBtnY, addBtnW, addBtnH, addBtnHov and Color(70, 120, 70) or Color(55, 65, 55))
                draw.SimpleText("添加项", "SourceHan_Heavy_12", addBtnX + addBtnW / 2, addBtnY + addBtnH / 2, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                ed._arrayVarAddBtn = {x = addBtnX, y = addBtnY, w = addBtnW, h = addBtnH}

                -- 类型选择器（点击"添加项"后显示）
                ed._arrayVarTypeBtns = {}
                local selectedType = INE.ArrayVarPendingType
                if selectedType then
                    local typeBtnSize2 = 22
                    local typeBtnGap2 = 6
                    local typeStartX2 = cx + 90
                    local typeStartY2 = addAreaY
                    local sortedTypes2 = {}
                    for _, dt in pairs(INE.DataTypes) do
                        table.insert(sortedTypes2, dt)
                    end
                    table.sort(sortedTypes2, function(a, b) return a.id < b.id end)
                    for ti, dataType in ipairs(sortedTypes2) do
                        local btnX = typeStartX2 + (ti - 1) * (typeBtnSize2 + typeBtnGap2)
                        local isSelected = (selectedType == dataType.id)
                        local btnHov = mx >= btnX and mx <= btnX + typeBtnSize2 and my >= typeStartY2 and my <= typeStartY2 + typeBtnSize2
                        if isSelected then
                            draw.RoundedBox(4, btnX, typeStartY2, typeBtnSize2, typeBtnSize2, Color(60, 70, 90))
                            surface.SetDrawColor(Color(100, 150, 255, 180))
                            surface.DrawOutlinedRect(btnX, typeStartY2, typeBtnSize2, typeBtnSize2)
                        elseif btnHov then
                            draw.RoundedBox(4, btnX, typeStartY2, typeBtnSize2, typeBtnSize2, Color(60, 65, 75))
                        else
                            draw.RoundedBox(4, btnX, typeStartY2, typeBtnSize2, typeBtnSize2, Color(50, 55, 65))
                        end
                        INE.DrawDataTypeIcon(dataType, btnX + typeBtnSize2 / 2, typeStartY2 + typeBtnSize2 / 2, 12)
                        ed._arrayVarTypeBtns[dataType.id] = {x = btnX, y = typeStartY2, w = typeBtnSize2, h = typeBtnSize2}
                    end

                    -- 值输入区域（在类型按钮下方）
                    local valInputY = typeStartY2 + typeBtnSize2 + 8
                    local valActive = activeField == "val_n" or activeField == "val_t"
                    if selectedType == "n" then
                        draw.SimpleText("值:", "SourceHan_Heavy_12", cx + 15, valInputY + 12, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                        local valX, valY, valW, valH = cx + 40, valInputY, cw - 160, 24
                        local valHov = mx >= valX and mx <= valX + valW and my >= valY and my <= valY + valH
                        draw.RoundedBox(4, valX, valY, valW, valH, valActive and Color(60, 65, 80) or (valHov and Color(60, 65, 70) or Color(50, 55, 60)))
                        if valActive then
                            surface.SetDrawColor(Color(100, 150, 255, 150))
                            surface.DrawOutlinedRect(valX, valY, valW, valH)
                        end
                        local valText = tostring(INE.ArrayVarItemValue or "")
                        draw.SimpleText(valText, "SourceHan_Heavy_12", valX + 8, valY + valH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                        if valActive and math.floor(SysTime() * 2) % 2 == 0 then
                            surface.SetFont("SourceHan_Heavy_12")
                            local cursorX = valX + 8 + surface.GetTextSize(valText)
                            surface.SetDrawColor(Color(200, 200, 200))
                            surface.DrawLine(cursorX, valY + 3, cursorX, valY + valH - 3)
                        end
                        ed._arrayVarField_val = {x = valX, y = valY, w = valW, h = valH}
                    elseif selectedType == "t" then
                        draw.SimpleText("文本:", "SourceHan_Heavy_12", cx + 15, valInputY + 12, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                        local valX, valY, valW, valH = cx + 50, valInputY, cw - 170, 24
                        local valHov = mx >= valX and mx <= valX + valW and my >= valY and my <= valY + valH
                        draw.RoundedBox(4, valX, valY, valW, valH, valActive and Color(60, 65, 80) or (valHov and Color(60, 65, 70) or Color(50, 55, 60)))
                        if valActive then
                            surface.SetDrawColor(Color(100, 150, 255, 150))
                            surface.DrawOutlinedRect(valX, valY, valW, valH)
                        end
                        local valText = tostring(INE.ArrayVarItemValue or "")
                        draw.SimpleText(valText, "SourceHan_Heavy_12", valX + 8, valY + valH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                        if valActive and math.floor(SysTime() * 2) % 2 == 0 then
                            surface.SetFont("SourceHan_Heavy_12")
                            local cursorX = valX + 8 + surface.GetTextSize(valText)
                            surface.SetDrawColor(Color(200, 200, 200))
                            surface.DrawLine(cursorX, valY + 3, cursorX, valY + valH - 3)
                        end
                        ed._arrayVarField_val = {x = valX, y = valY, w = valW, h = valH}
                    elseif selectedType == "p" then
                        draw.SimpleText("值:", "SourceHan_Heavy_12", cx + 15, valInputY + 12, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                        local curBool = (INE.ArrayVarItemValue == true) or (INE.ArrayVarItemValue == nil)
                        local trueX, trueY, trueW, trueH = cx + 40, valInputY, 50, 24
                        local falseX = trueX + trueW + 6
                        local trueHov = mx >= trueX and mx <= trueX + trueW and my >= trueY and my <= trueY + trueH
                        local falseHov = mx >= falseX and mx <= falseX + trueW and my >= trueY and my <= trueY + trueH
                        draw.RoundedBox(4, trueX, trueY, trueW, trueH, curBool and Color(60, 100, 60) or Color(50, 55, 60))
                        draw.SimpleText("true", "SourceHan_Heavy_12", trueX + trueW / 2, trueY + trueH / 2, curBool and Color(200, 255, 200) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        draw.RoundedBox(4, falseX, trueY, trueW, trueH, not curBool and Color(100, 60, 60) or Color(50, 55, 60))
                        draw.SimpleText("false", "SourceHan_Heavy_12", falseX + trueW / 2, trueY + trueH / 2, not curBool and Color(255, 200, 200) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        ed._arrayVarField_boolTrue = {x = trueX, y = trueY, w = trueW, h = trueH}
                        ed._arrayVarField_boolFalse = {x = falseX, y = trueY, w = trueW, h = trueH}
                    elseif selectedType == "f" then
                        draw.SimpleText("→ 正在打开函数变量创建窗口...", "SourceHan_Heavy_12", cx + 15, valInputY + 14, Color(180, 200, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    elseif selectedType == "g" then
                        draw.SimpleText("→ 正在打开数组变量创建窗口...", "SourceHan_Heavy_12", cx + 15, valInputY + 14, Color(180, 200, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    end

                    -- "确认添加"按钮（仅对简单类型显示）
                    local confirmAddY = valInputY + 30
                    if selectedType == "n" or selectedType == "t" or selectedType == "p" then
                        local confirmAddHov = mx >= cx + cw - 100 and mx <= cx + cw - 100 + 70 and my >= confirmAddY and my <= confirmAddY + 24
                        draw.RoundedBox(4, cx + cw - 100, confirmAddY, 70, 24, confirmAddHov and Color(70, 120, 70) or Color(55, 65, 55))
                        draw.SimpleText("确认添加", "SourceHan_Heavy_12", cx + cw - 65, confirmAddY + 12, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        ed._arrayVarAddConfirmRect = {x = cx + cw - 100, y = confirmAddY, w = 70, h = 24}
                    end
                end
            end

            -- 确定 / 取消按钮
            local btnY = cy + ch - 40
            local confirmHov = mx >= cx + cw/2 - 80 and mx <= cx + cw/2 - 80 + 70 and my >= btnY and my <= btnY + 28
            local cancelHov = mx >= cx + cw/2 + 10 and mx <= cx + cw/2 + 10 + 70 and my >= btnY and my <= btnY + 28
            draw.RoundedBox(6, cx + cw/2 - 80, btnY, 70, 28, confirmHov and Color(70, 120, 70) or Color(55, 65, 55))
            draw.SimpleText("确定", "SourceHan_Heavy_14", cx + cw/2 - 45, btnY + 14, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.RoundedBox(6, cx + cw/2 + 10, btnY, 70, 28, cancelHov and Color(100, 60, 60) or Color(65, 55, 55))
            draw.SimpleText("取消", "SourceHan_Heavy_14", cx + cw/2 + 45, btnY + 14, Color(255, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            ed._arrayVarConfirmRect = {x = cx + cw/2 - 80, y = btnY, w = 70, h = 28}
            ed._arrayVarCancelRect = {x = cx + cw/2 + 10, y = btnY, w = 70, h = 28}
        end
    })
end

--[[
    显示卡牌对象变量创建/编辑对话框。
    提供两种模式：
      1. 空对象：创建一个空的卡牌对象
      2. 已保存的卡牌：从已保存的卡牌列表中选择，悬停时绘制卡牌预览
    
    @param  editor  {table}   编辑器实例
    @param  varIdx  {number}  变量在 editor.variables["e"] 中的索引
]]
function INE:ShowCardVarDialog(editor, varIdx)
    local dialogW, dialogH = 420, 480
    local cardVarData = (editor.variables["e"] or {})[varIdx]
    local cardScope = cardVarData and cardVarData.scope or "global"
    INE:ShowOverlayWindow(editor, {
        id = "ine_cardvar_dialog",
        title = "卡牌对象",
        showScope = true, scope = cardScope,
        x = editor.x + (editor.width - dialogW) / 2,
        y = editor.y + (editor.height - dialogH) / 2,
        width = dialogW,
        height = dialogH,
        content = function(ed, win, cx, cy, cw, ch)
            local mx, my = gui.MouseX(), gui.MouseY()
            local vars = ed.variables["e"] or {}
            local vd = vars[varIdx]
            if not vd then return end
            local activeField = INE.CardVarFieldState and INE.CardVarFieldState.active and INE.CardVarFieldState.field

            -- 变量名
            draw.SimpleText("变量名:", "SourceHan_Heavy_12", cx + 15, cy + 10, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local nameX, nameY, nameW, nameH = cx + 15, cy + 28, cw - 30, 28
            local nameHov = mx >= nameX and mx <= nameX + nameW and my >= nameY and my <= nameY + nameH
            local nameActive = activeField == "name"
            draw.RoundedBox(4, nameX, nameY, nameW, nameH, nameActive and Color(60, 65, 80) or (nameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if nameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(nameX, nameY, nameW, nameH)
            end
            local nameText = vd.name or ""
            draw.SimpleText(nameText, "SourceHan_Heavy_14", nameX + 10, nameY + nameH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if nameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_14")
                local cursorX = nameX + 10 + surface.GetTextSize(nameText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, nameY + 4, cursorX, nameY + nameH - 4)
            end
            ed._cardVarField_name = {x = nameX, y = nameY, w = nameW, h = nameH}

            -- 内部变量名
            draw.SimpleText("内部变量:", "SourceHan_Heavy_12", cx + 15, cy + 64, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local inameX, inameY, inameW, inameH = cx + 15, cy + 82, cw - 30, 28
            local inameHov = mx >= inameX and mx <= inameX + inameW and my >= inameY and my <= inameY + inameH
            local inameActive = activeField == "internalName"
            draw.RoundedBox(4, inameX, inameY, inameW, inameH, inameActive and Color(60, 65, 80) or (inameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if inameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(inameX, inameY, inameW, inameH)
            end
            local inameText = vd.internalName or ""
            draw.SimpleText(inameText, "SourceHan_Heavy_14", inameX + 10, inameY + inameH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if inameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_14")
                local cursorX = inameX + 10 + surface.GetTextSize(inameText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, inameY + 4, cursorX, inameY + inameH - 4)
            end
            ed._cardVarField_internalName = {x = inameX, y = inameY, w = inameW, h = inameH}

            -- 模式选择
            local modeY = cy + 124
            draw.SimpleText("卡牌来源:", "SourceHan_Heavy_12", cx + 15, modeY, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local mode = vd._mode or "empty"
            local radioY = modeY + 20
            -- 空对象
            local emptyRadioX = cx + 20
            local emptyHov = mx >= emptyRadioX - 10 and mx <= emptyRadioX + 140 and my >= radioY - 4 and my <= radioY + 24
            draw.RoundedBox(8, emptyRadioX, radioY + 2, 14, 14, mode == "empty" and Color(100, 150, 255) or Color(60, 65, 75))
            if mode == "empty" then
                draw.RoundedBox(4, emptyRadioX + 4, radioY + 6, 6, 6, Color(180, 200, 255))
            end
            draw.SimpleText("空对象", "SourceHan_Heavy_12", emptyRadioX + 22, radioY + 9, emptyHov and Color(220, 220, 220) or Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            ed._cardVarEmptyRadio = {x = emptyRadioX - 10, y = radioY - 4, w = 150, h = 24}

            -- 已保存的卡牌
            local savedRadioX = cx + 180
            local savedHov = mx >= savedRadioX - 10 and mx <= savedRadioX + 160 and my >= radioY - 4 and my <= radioY + 24
            draw.RoundedBox(8, savedRadioX, radioY + 2, 14, 14, mode == "saved" and Color(100, 150, 255) or Color(60, 65, 75))
            if mode == "saved" then
                draw.RoundedBox(4, savedRadioX + 4, radioY + 6, 6, 6, Color(180, 200, 255))
            end
            draw.SimpleText("已保存的卡牌", "SourceHan_Heavy_12", savedRadioX + 22, radioY + 9, savedHov and Color(220, 220, 220) or Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            ed._cardVarSavedRadio = {x = savedRadioX - 10, y = radioY - 4, w = 180, h = 24}

            -- 当选择"已保存的卡牌"时，显示卡牌列表
            ed._cardVarHoverInfo = nil
            if mode == "saved" then
                ed._cardVarItemRects = {}
                local listY = radioY + 32
                draw.SimpleText("选择卡牌:", "SourceHan_Heavy_12", cx + 15, listY, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

                -- 获取已保存卡牌列表（缓存）
                if not ed._cardVarCardInfos then
                    ed._cardVarCardInfos = KARDS.CardEditor.SaveSystem.GetAllCardsInfo() or {}
                    table.sort(ed._cardVarCardInfos, function(a, b)
                        return (a.name or "") < (b.name or "")
                    end)
                end
                local cardInfos = ed._cardVarCardInfos

                -- 计算可见区域
                local itemH = 28
                local listX = cx + 15
                local listW = cw - 30
                local maxVisible = math.floor((ch - (listY - cy) - 45 - 40) / itemH)
                local maxOffset = math.max(0, #cardInfos - maxVisible)
                local scrollOffset = math.min(ed._cardVarScrollOffset or 0, maxOffset)
                ed._cardVarScrollOffset = scrollOffset
                local visibleItems = math.min(#cardInfos - scrollOffset, maxVisible)

                -- 滚动指示器
                if maxOffset > 0 then
                    if scrollOffset > 0 then
                        draw.SimpleText("▲", "SourceHan_Heavy_10", cx + cw - 18, listY - 5, Color(150, 150, 160), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    end
                    if scrollOffset + visibleItems < #cardInfos then
                        draw.SimpleText("▼", "SourceHan_Heavy_10", cx + cw - 18, listY + visibleItems * itemH + 2, Color(150, 150, 160), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    end
                end
                -- 存储列表区域用于滚轮检测
                ed._cardVarListRect = {x = listX, y = listY, w = listW, h = visibleItems * itemH}

                for ii = 1, visibleItems do
                    local realIdx = ii + scrollOffset
                    local info = cardInfos[realIdx]
                    local iy = listY + (ii - 1) * itemH
                    local isSelected = (ed._cardVarSelectedFile == info.fileName)
                    local isHovered = mx >= listX and mx <= listX + listW and my >= iy and my <= iy + itemH

                    -- 行背景
                    if isSelected then
                        draw.RoundedBox(4, listX, iy, listW, itemH, Color(50, 70, 100))
                        surface.SetDrawColor(Color(80, 120, 200, 150))
                        surface.DrawOutlinedRect(listX, iy, listW, itemH)
                    elseif isHovered then
                        draw.RoundedBox(4, listX, iy, listW, itemH, Color(55, 60, 70))
                    else
                        draw.RoundedBox(4, listX, iy, listW, itemH, Color(45, 50, 58))
                    end

                    -- 卡牌名称
                    local displayName = (info.name ~= "") and info.name or (KARDS.CardEditor.SaveSystem.UnescapeFileName(info.fileName):gsub("%.json$", ""))
                    draw.SimpleText(displayName, "SourceHan_Heavy_12", listX + 10, iy + itemH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

                    -- 文件名（灰色小字）
                    draw.SimpleText(KARDS.CardEditor.SaveSystem.UnescapeFileName(info.fileName), "SourceHan_Heavy_10", listX + listW - 10, iy + itemH / 2, Color(120, 120, 130), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

                    -- 注册交互区域和悬停信息
                    ed._cardVarItemRects[realIdx] = {x = listX, y = iy, w = listW, h = itemH}
                    if isHovered then
                        ed._cardVarHoverInfo = info
                    end
                end

                -- 如果没有卡牌
                if #cardInfos == 0 then
                    draw.SimpleText("暂无已保存的卡牌", "SourceHan_Heavy_12", cx + cw / 2, listY + 15, Color(120, 120, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                end
            end

            -- 确定 / 取消按钮（在卡牌列表下方绘制，预览图上方）
            local btnY = cy + ch - 40
            local confirmHov = mx >= cx + cw/2 - 80 and mx <= cx + cw/2 - 80 + 70 and my >= btnY and my <= btnY + 28
            local cancelHov = mx >= cx + cw/2 + 10 and mx <= cx + cw/2 + 10 + 70 and my >= btnY and my <= btnY + 28
            draw.RoundedBox(6, cx + cw/2 - 80, btnY, 70, 28, confirmHov and Color(70, 120, 70) or Color(55, 65, 55))
            draw.SimpleText("确定", "SourceHan_Heavy_14", cx + cw/2 - 45, btnY + 14, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.RoundedBox(6, cx + cw/2 + 10, btnY, 70, 28, cancelHov and Color(100, 60, 60) or Color(65, 55, 55))
            draw.SimpleText("取消", "SourceHan_Heavy_14", cx + cw/2 + 45, btnY + 14, Color(255, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            ed._cardVarConfirmRect = {x = cx + cw/2 - 80, y = btnY, w = 70, h = 28}
            ed._cardVarCancelRect = {x = cx + cw/2 + 10, y = btnY, w = 70, h = 28}

            -- 悬停卡牌预览（在最高层绘制，确保不被按钮遮挡）
            if mode == "saved" and ed._cardVarHoverInfo and ed._cardVarHoverInfo.cardAppearance then
                local app = ed._cardVarHoverInfo.cardAppearance
                -- 使用与外貌属性编辑器一致的缩放：参考高度 = TotalEditorH/3
                local refH = math.floor((KARDS.CardEditor.Canvas.TotalEditorH or 720) / 3)
                local previewH = refH
                local previewW = math.floor(previewH * 3 / 4)
                local previewX = mx - previewW / 2  -- 鼠标水平居中
                local previewY = my + 16             -- 鼠标下方

                -- 确保不超出屏幕边界
                if previewX + previewW > ScrW() then
                    previewX = ScrW() - previewW - 8
                end
                if previewX < 0 then
                    previewX = 8
                end
                if previewY + previewH > ScrH() then
                    previewY = my - previewH - 8
                end

                -- 半透明背景
                draw.RoundedBox(6, previewX - 4, previewY - 4, previewW + 8, previewH + 8, Color(30, 30, 40, 220))
                surface.SetDrawColor(Color(80, 80, 100, 200))
                surface.DrawOutlinedRect(previewX - 4, previewY - 4, previewW + 8, previewH + 8)

                -- 调用卡牌预览绘制（不更改缩放）
                local ok, err = pcall(KARDS.CardEditor.Canvas.DrawCardPreview, app, previewX, previewY, previewW, previewH)
                if not ok then
                    draw.SimpleText("预览加载失败", "SourceHan_Heavy_10", previewX + previewW / 2, previewY + previewH / 2, Color(255, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                end
            end
        end
    })
end

--[[
    显示字符串变量创建/编辑对话框。
    提供叠加窗口，显示变量名、内部变量名、文本三个可点击编辑的字段。
    点击字段会激活 DTextEntry 内联输入，支持 IME 中文输入。
    
    @param  editor  {table}   编辑器实例
    @param  varIdx  {number}  变量在 editor.variables["t"] 中的索引
    @param  varData {table}   变量数据 {name, internalName, initialValue}
]]
function INE:ShowStringVarDialog(editor, varIdx, varData)
    local dialogW, dialogH = 400, 250
    INE:ShowOverlayWindow(editor, {
        id = "ine_stringvar_dialog",
        title = "字符串变量",
        showScope = true, scope = varData.scope or "global",
        x = editor.x + (editor.width - dialogW) / 2,
        y = editor.y + (editor.height - dialogH) / 2,
        width = dialogW,
        height = dialogH,
        content = function(ed, win, cx, cy, cw, ch)
            local mx, my = gui.MouseX(), gui.MouseY()
            local vars = ed.variables["t"] or {}
            local vd = vars[varIdx]
            if not vd then return end
            local activeField = INE.StringVarFieldState and INE.StringVarFieldState.active and INE.StringVarFieldState.field

            -- 变量名
            draw.SimpleText("变量名:", "SourceHan_Heavy_12", cx + 15, cy + 15, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local nameX, nameY, nameW, nameH = cx + 15, cy + 35, cw - 30, 30
            local nameHov = mx >= nameX and mx <= nameX + nameW and my >= nameY and my <= nameY + nameH
            local nameActive = activeField == "name"
            draw.RoundedBox(4, nameX, nameY, nameW, nameH, nameActive and Color(60, 65, 80) or (nameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if nameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(nameX, nameY, nameW, nameH)
            end
            local nameText = vd.name or ""
            draw.SimpleText(nameText, "SourceHan_Heavy_14", nameX + 10, nameY + nameH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if nameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_14")
                local cursorX = nameX + 10 + surface.GetTextSize(nameText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, nameY + 4, cursorX, nameY + nameH - 4)
            end
            ed._stringVarField_name = {x = nameX, y = nameY, w = nameW, h = nameH}

            -- 内部变量名
            draw.SimpleText("内部变量名（代码中使用，留空自动分配唯一ID）:", "SourceHan_Heavy_10", cx + 15, cy + 75, Color(160, 160, 160), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local inameX, inameY, inameW, inameH = cx + 15, cy + 92, cw - 30, 28
            local inameHov = mx >= inameX and mx <= inameX + inameW and my >= inameY and my <= inameY + inameH
            local inameActive = activeField == "iname"
            draw.RoundedBox(4, inameX, inameY, inameW, inameH, inameActive and Color(60, 65, 80) or (inameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if inameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(inameX, inameY, inameW, inameH)
            end
            local displayIname = (vd.internalName and not vd.internalName:match("^t_var_")) and vd.internalName or ""
            draw.SimpleText(displayIname, "SourceHan_Heavy_12", inameX + 10, inameY + inameH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if inameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_12")
                local cursorX = inameX + 10 + surface.GetTextSize(displayIname)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, inameY + 3, cursorX, inameY + inameH - 3)
            end
            ed._stringVarField_iname = {x = inameX, y = inameY, w = inameW, h = inameH}

            -- 文本内容
            draw.SimpleText("文本:", "SourceHan_Heavy_12", cx + 15, cy + 130, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local valX, valY, valW, valH = cx + 15, cy + 150, cw - 30, 28
            local valHov = mx >= valX and mx <= valX + valW and my >= valY and my <= valY + valH
            local valActive = activeField == "text"
            draw.RoundedBox(4, valX, valY, valW, valH, valActive and Color(60, 65, 80) or (valHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if valActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(valX, valY, valW, valH)
            end
            local valText = vd.initialValue or ""
            draw.SimpleText(valText, "SourceHan_Heavy_12", valX + 10, valY + valH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if valActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_12")
                local cursorX = valX + 10 + surface.GetTextSize(valText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, valY + 3, cursorX, valY + valH - 3)
            end
            ed._stringVarField_text = {x = valX, y = valY, w = valW, h = valH}

            -- 确定 / 取消按钮
            local btnY = cy + ch - 40
            local confirmHov = mx >= cx + cw/2 - 80 and mx <= cx + cw/2 - 80 + 70 and my >= btnY and my <= btnY + 28
            local cancelHov = mx >= cx + cw/2 + 10 and mx <= cx + cw/2 + 10 + 70 and my >= btnY and my <= btnY + 28
            draw.RoundedBox(6, cx + cw/2 - 80, btnY, 70, 28, confirmHov and Color(70, 120, 70) or Color(55, 65, 55))
            draw.SimpleText("确定", "SourceHan_Heavy_14", cx + cw/2 - 45, btnY + 14, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.RoundedBox(6, cx + cw/2 + 10, btnY, 70, 28, cancelHov and Color(100, 60, 60) or Color(65, 55, 55))
            draw.SimpleText("取消", "SourceHan_Heavy_14", cx + cw/2 + 45, btnY + 14, Color(255, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            ed._stringVarConfirmRect = {x = cx + cw/2 - 80, y = btnY, w = 70, h = 28}
            ed._stringVarCancelRect = {x = cx + cw/2 + 10, y = btnY, w = 70, h = 28}
        end
    })
end

-- 显示布尔值变量创建/编辑对话框。
-- 提供叠加窗口，显示变量名、内部变量名两个可编辑字段，以及真假值切换。
-- 点击文本字段激活 DTextEntry 内联输入，支持 IME 中文输入。
-- 真假值通过 true/false 按钮切换。
--
-- @param  editor  {table}   编辑器实例
-- @param  varIdx  {number}  变量在 editor.variables["p"] 中的索引
-- @param  varData {table}   变量数据 {name, internalName, initialValue}
function INE:ShowBoolVarDialog(editor, varIdx, varData)
    local dialogW, dialogH = 400, 250
    INE:ShowOverlayWindow(editor, {
        id = "ine_boolvar_dialog",
        title = "布尔值变量",
        showScope = true, scope = varData.scope or "global",
        x = editor.x + (editor.width - dialogW) / 2,
        y = editor.y + (editor.height - dialogH) / 2,
        width = dialogW,
        height = dialogH,
        content = function(ed, win, cx, cy, cw, ch)
            local mx, my = gui.MouseX(), gui.MouseY()
            local vars = ed.variables["p"] or {}
            local vd = vars[varIdx]
            if not vd then return end
            local activeField = INE.BoolVarFieldState and INE.BoolVarFieldState.active and INE.BoolVarFieldState.field

            -- 变量名
            draw.SimpleText("变量名:", "SourceHan_Heavy_12", cx + 15, cy + 15, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local nameX, nameY, nameW, nameH = cx + 15, cy + 35, cw - 30, 30
            local nameHov = mx >= nameX and mx <= nameX + nameW and my >= nameY and my <= nameY + nameH
            local nameActive = activeField == "name"
            draw.RoundedBox(4, nameX, nameY, nameW, nameH, nameActive and Color(60, 65, 80) or (nameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if nameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(nameX, nameY, nameW, nameH)
            end
            local nameText = vd.name or ""
            draw.SimpleText(nameText, "SourceHan_Heavy_14", nameX + 10, nameY + nameH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if nameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_14")
                local cursorX = nameX + 10 + surface.GetTextSize(nameText)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, nameY + 4, cursorX, nameY + nameH - 4)
            end
            ed._boolVarField_name = {x = nameX, y = nameY, w = nameW, h = nameH}

            -- 内部变量
            draw.SimpleText("内部变量（代码中使用，留空自动分配唯一ID）:", "SourceHan_Heavy_10", cx + 15, cy + 75, Color(160, 160, 160), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local inameX, inameY, inameW, inameH = cx + 15, cy + 92, cw - 30, 28
            local inameHov = mx >= inameX and mx <= inameX + inameW and my >= inameY and my <= inameY + inameH
            local inameActive = activeField == "iname"
            draw.RoundedBox(4, inameX, inameY, inameW, inameH, inameActive and Color(60, 65, 80) or (inameHov and Color(60, 65, 70) or Color(50, 55, 60)))
            if inameActive then
                surface.SetDrawColor(Color(100, 150, 255, 150))
                surface.DrawOutlinedRect(inameX, inameY, inameW, inameH)
            end
            local displayIname = (vd.internalName and not vd.internalName:match("^p_var_")) and vd.internalName or ""
            draw.SimpleText(displayIname, "SourceHan_Heavy_12", inameX + 10, inameY + inameH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            if inameActive and math.floor(SysTime() * 2) % 2 == 0 then
                surface.SetFont("SourceHan_Heavy_12")
                local cursorX = inameX + 10 + surface.GetTextSize(displayIname)
                surface.SetDrawColor(Color(200, 200, 200))
                surface.DrawLine(cursorX, inameY + 3, cursorX, inameY + inameH - 3)
            end
            ed._boolVarField_iname = {x = inameX, y = inameY, w = inameW, h = inameH}

            -- 真假值（true/false 按钮）
            draw.SimpleText("真假值:", "SourceHan_Heavy_12", cx + 15, cy + 130, Color(180, 180, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            local boolVal = (vd.initialValue == true)
            local boolBtnY = cy + 150
            local trueX, trueW, trueH = cx + 15, 60, 28
            local falseX = trueX + trueW + 8
            local trueHov = mx >= trueX and mx <= trueX + trueW and my >= boolBtnY and my <= boolBtnY + trueH
            local falseHov = mx >= falseX and mx <= falseX + trueW and my >= boolBtnY and my <= boolBtnY + trueH
            draw.RoundedBox(6, trueX, boolBtnY, trueW, trueH, boolVal and Color(60, 100, 60) or Color(50, 55, 60))
            draw.SimpleText("true", "SourceHan_Heavy_14", trueX + trueW / 2, boolBtnY + trueH / 2, boolVal and Color(200, 255, 200) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.RoundedBox(6, falseX, boolBtnY, trueW, trueH, not boolVal and Color(100, 60, 60) or Color(50, 55, 60))
            draw.SimpleText("false", "SourceHan_Heavy_14", falseX + trueW / 2, boolBtnY + trueH / 2, not boolVal and Color(255, 200, 200) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            ed._boolVarField_true = {x = trueX, y = boolBtnY, w = trueW, h = trueH}
            ed._boolVarField_false = {x = falseX, y = boolBtnY, w = trueW, h = trueH}

            -- 确定 / 取消按钮
            local btnY = cy + ch - 40
            local confirmHov = mx >= cx + cw/2 - 80 and mx <= cx + cw/2 - 80 + 70 and my >= btnY and my <= btnY + 28
            local cancelHov = mx >= cx + cw/2 + 10 and mx <= cx + cw/2 + 10 + 70 and my >= btnY and my <= btnY + 28
            draw.RoundedBox(6, cx + cw/2 - 80, btnY, 70, 28, confirmHov and Color(70, 120, 70) or Color(55, 65, 55))
            draw.SimpleText("确定", "SourceHan_Heavy_14", cx + cw/2 - 45, btnY + 14, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.RoundedBox(6, cx + cw/2 + 10, btnY, 70, 28, cancelHov and Color(100, 60, 60) or Color(65, 55, 55))
            draw.SimpleText("取消", "SourceHan_Heavy_14", cx + cw/2 + 45, btnY + 14, Color(255, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            ed._boolVarConfirmRect = {x = cx + cw/2 - 80, y = btnY, w = 70, h = 28}
            ed._boolVarCancelRect = {x = cx + cw/2 + 10, y = btnY, w = 70, h = 28}
        end
    })
end

--[[
    注册一个新的节点类型到节点编辑器系统。
    必须在使用 CreateNewNodeEditor 或 AddNodeToEditor 创建节点前先注册对应类型。
    
    @param  nodeParams  {table}    节点参数配置表，可包含以下字段：
        - type          {string}   节点类型标识，默认为 "custom"
        - color         {Color}    节点主体颜色，默认为 Color(100, 100, 100)
        - width         {number}   节点宽度（像素），默认为 200
        - height        {number}   节点高度（像素），默认为 80
        - hasInput      {boolean}  是否显示左侧输入端口，默认为 true
        - hasOutput     {boolean}  是否显示右侧输出端口，默认为 true
        - hasInputs     {boolean} 是否显示多个输入端口，默认为 false（保留字段）
        - hasOutputs    {boolean} 是否显示多个输出端口，默认为 false（保留字段）
        - inputTypes    {table}    输入端口类型列表，默认为空表
        - outputTypes   {table}    输出端口类型列表，默认为空表
        - config        {string}   节点配置字符串，默认为空字符串
        - isStartNode   {boolean}  是否为起始节点（创建编辑器时自动添加且不可删除），默认为 false
        - canDelete     {boolean}  节点是否可被用户删除，默认为 true
        - drawFunction  {function} 自定义绘制函数，签名为 function(node, x, y, w, h, scale)
        - dataFields    {table}    节点数据字段默认值表，键为字段名，值为默认值
    @param  nodeName    {string}    节点类型的唯一名称标识，用于后续创建节点实例
    
    @return {boolean}   注册成功返回 true
    
    @usage  示例：
        LogNewNode({
            type = "action",
            color = Color(80, 120, 200),
            width = 180,
            height = 100,
            isStartNode = false,
            dataFields = {actionType = "attack", damage = 10},
            drawFunction = function(node, x, y, w, h, scale)
                draw.SimpleText("攻击节点", "DermaDefault", x + w/2, y + h/2, color_white, TEXT_ALIGN_CENTER)
            end
        }, "attack_node")
]]
-- LogNewNode 已移至 cl_ine_node_editor.lua（全局函数，定义于内置节点类型注册之前）

--[[
    从 data/kards/node_templates/ 的 JSON 文件中加载并注册所有节点模板。
    会根据模板的 type 字段生成节点名称（type 后缀 _node）。
    
    @param  mode    {string}    【可选】编辑器模式，只注册支持该模式的节点
    @return {table}             注册成功的节点名称列表
]]
function INE:RegisterTemplates()
    -- 确保规则词汇表模块已加载（config DSL 的 @section 引用依赖它）。
    -- 若词汇表文件是 GMod 启动后才新增的，启动扫描不会包含它，需要手动加载。
    if not (KARDS and KARDS.RulesVocabulary) then
        local ok, err = pcall(include, "kards/sh_rules_vocabulary.lua")
        if ok then
            print("[INE] 已手动加载规则词汇表 (kards/sh_rules_vocabulary.lua)")
            -- 词汇表状态变化会改变 @section 引用的解析结果，必须清空解析缓存
            INE.ConfigCache = {}
        else
            print("[INE] 警告: 规则词汇表加载失败: " .. tostring(err))
        end
    end
    -- 从 JSON 文件加载所有节点模板（注册所有节点，mode 过滤由调用者处理）
    local registered = INE:LoadNodeTemplatesFromFiles()
    
    return registered
end

-- 手动重载节点模板的控制台命令（修改 lua/node_templates/*.json 后无需重启游戏）
concommand.Add("kards_reload_templates", function()
    local INE = KARDS.CardEditor.IndependentNodeEditor
    if not INE then
        print("[INE] 错误: IndependentNodeEditor 未加载")
        return
    end
    -- 确保规则词汇表模块已加载（@section 引用依赖它）
    if not (KARDS and KARDS.RulesVocabulary) then
        local ok, err = pcall(include, "kards/sh_rules_vocabulary.lua")
        if ok then
            print("[INE] 已手动加载规则词汇表 (kards/sh_rules_vocabulary.lua)")
            -- 词汇表状态变化会改变 @section 引用的解析结果，必须清空解析缓存
            INE.ConfigCache = {}
        else
            print("[INE] 警告: 规则词汇表加载失败: " .. tostring(err))
        end
    end
    -- 诊断：词汇表加载状态（@section 引用依赖此模块）
    print("[INE] 词汇表诊断: KARDS=" .. tostring(KARDS)
        .. " RulesVocabulary=" .. tostring(KARDS and KARDS.RulesVocabulary)
        .. " GetOptions=" .. tostring(KARDS and KARDS.RulesVocabulary and KARDS.RulesVocabulary.GetOptions))
    if KARDS and KARDS.RulesVocabulary and KARDS.RulesVocabulary.GetOptions then
        print("[INE] 词汇表 combat_keywords 选项数: " .. #(KARDS.RulesVocabulary.GetOptions("combat_keywords") or {}))
    end
    -- 清除所有 JSON 模板注册（保留 isStartNode 内置节点）
    local cleared = 0
    for name, tpl in pairs(INE.RegisteredNodes) do
        if not tpl.isStartNode then
            INE.RegisteredNodes[name] = nil
            cleared = cleared + 1
        end
    end
    print("[INE] 模板重载: 已清除 " .. cleared .. " 个旧模板注册")
    local registered = INE:LoadNodeTemplatesFromFiles()
    print("[INE] 模板重载完成，成功注册 " .. #registered .. " 个节点（若仍有疑问请查看上方 [INE] 错误输出）")
    -- 提示关闭并重新打开效果编辑器以应用新模板
    print("[INE] 提示: 请关闭并重新打开卡牌效果编辑器，新建节点将使用新模板")
end)

--[[
    生成唯一的节点ID。
    内部使用自增计数器保证ID唯一性。
    
    @return {string} 格式为 "ine_node_<数字>" 的唯一节点ID
]]
function INE:GenerateNodeID()
    INE.NodeIDCounter = INE.NodeIDCounter + 1
    return "ine_node_" .. INE.NodeIDCounter
end

--[[
    生成唯一的连接ID。
    内部使用自增计数器保证ID唯一性。
    
    @return {string} 格式为 "ine_conn_<数字>" 的唯一连接ID
]]
function INE:GenerateConnectionID()
    INE.ConnectionIDCounter = INE.ConnectionIDCounter + 1
    return "ine_conn_" .. INE.ConnectionIDCounter
end

--[[
    根据已注册的节点模板创建一个新的节点实例。
    
    @param  nodeName    {string}    已注册的节点类型名称
    @param  editor      {table}     所属的编辑器实例对象
    @param  x           {number}    节点在画布上的X坐标（画布本地坐标）
    @param  y           {number}    节点在画布上的Y坐标（画布本地坐标）
    
    @return {table}     新创建的节点实例对象
    
    节点实例字段说明：
        - id                    {string}    节点唯一ID
        - name                  {string}    节点类型名称
        - type                  {string}    节点类型标识
        - color                 {Color}     节点显示颜色（独立Color副本）
        - x, y                  {number}    节点在画布上的位置
        - width, height         {number}    节点尺寸
        - hasInput              {boolean}  是否有输入端口
        - hasOutput             {boolean}  是否有输出端口
        - hasInputs             {boolean} 是否有多输入端口（保留）
        - hasOutputs            {boolean} 是否有多输出端口（保留）
        - isStartNode           {boolean}  是否为起始节点
        - canDelete             {boolean}  是否可删除
        - drawFunction          {function} 自定义绘制函数
        - data                  {table}     节点自定义数据字段存储
        - selectedInputTypes    {table}     已选择的输入端口类型映射
        - selectedOutputTypes   {table}     已选择的输出端口类型映射
        - dragging              {boolean}   节点是否正在被拖拽
        - dragStartX, dragStartY {number}  拖拽起始鼠标位置
        - startX, startY        {number}    拖拽起始节点位置
        - isInvalid             {boolean}   节点是否无效（不属于当前面板）
        - isUnregistered        {boolean}   节点类型是否未注册
        - editor                {table}     所属编辑器引用
]]
function INE:CreateNewNodeInstance(nodeName, editor, x, y)
    local template = INE.RegisteredNodes[nodeName]
    if not template then
        error("[IndependentNodeEditor] 节点未注册: " .. tostring(nodeName))
    end
    
    -- 创建节点实例（从模板复制属性，并添加运行时状态字段）
    local node = {
        id = INE:GenerateNodeID(),                        -- 节点唯一ID
        name = template.name,                             -- 节点类型名称
        displayName = template.displayName,               -- 节点显示名称（中文，用于UI标题）
        type = template.type,                             -- 节点类型标识
        color = Color(template.color.r, template.color.g, template.color.b, template.color.a or 255), -- 独立颜色副本
        x = x or 0,                                       -- 画布X坐标
        y = y or 0,                                       -- 画布Y坐标
        width = template.width,                           -- 节点宽度
        height = template.height,                         -- 节点高度
        hasInput = template.hasInput,                     -- 是否有输入端口
        hasOutput = template.hasOutput,                   -- 是否有输出端口
        hasInputs = template.hasInputs,                   -- 是否有多输入端口（保留）
        hasOutputs = template.hasOutputs,                 -- 是否有多输出端口（保留）
        inputTypes = template.inputTypes or {},           -- 输入端口类型列表
        outputTypes = template.outputTypes or {},         -- 输出端口类型列表
        config = template.config or "",                   -- 节点配置字符串
        parsedConfig = template.parsedConfig,             -- 解析后的配置（组件列表）
        availableInputTypes = template.availableInputTypes or {},  -- 可用输入数据类型
        availableOutputTypes = template.availableOutputTypes or {}, -- 可用输出数据类型
        selectedInputTypes = {},                          -- 已选输入端口类型映射
        selectedOutputTypes = {},                         -- 已选输出端口类型映射
        dataPortDropdownActive = false,                   -- 数据点下拉框是否激活
        inputDataPortDropdownActive = false,              -- 输入数据点下拉框是否激活
        isStartNode = template.isStartNode,               -- 是否为起始节点
        canDelete = template.canDelete,                   -- 是否可删除
        drawFunction = template.drawFunction,             -- 自定义绘制函数
        data = {},                                        -- 节点自定义数据存储
        dragging = false,                                 -- 是否正在被拖拽
        dragStartX = 0,                                   -- 拖拽起始鼠标X位置
        dragStartY = 0,                                   -- 拖拽起始鼠标Y位置
        startX = 0,                                       -- 拖拽起始节点X位置
        startY = 0,                                       -- 拖拽起始节点Y位置
        isInvalid = false,                                -- 是否标记为无效（不属于当前面板）
        isUnregistered = false,                           -- 是否节点类型未注册
        editor = editor,                                   -- 所属编辑器引用
        hasSecondOutput = template.hasSecondOutput or false -- 是否有第二个输出点（双分支：满足/不满足，来自模板字段）
    }
    
    -- 兼容旧式 config 末尾 "2" 标记：无显式 hasSecondOutput 字段时，config 末尾为 "2" 也视为双分支输出点
    if not node.hasSecondOutput and template.config and #template.config > 0 and template.config:sub(-1) == "2" then
        node.hasSecondOutput = true
        node.config = template.config:sub(1, -2)  -- 去除末尾的 "2"，不干扰组件解析
    end
    
    -- 初始化节点自定义数据字段默认值
    for fieldName, fieldDefault in pairs(template.dataFields) do
        if type(fieldDefault) == "table" then
            -- 深度复制表格，避免同类节点间共享引用（如 _varEntries、_conditions 等）
            node.data[fieldName] = table.Copy(fieldDefault)
        else
            node.data[fieldName] = fieldDefault
        end
    end
    
    -- 如果有解析后的配置，确保数据完整初始化
    if node.parsedConfig and node.parsedConfig.components then
        INE.InitNodeData(node.parsedConfig.components, node.data)
    end
    
    return node
end

--[[
    创建一个新的编辑器实例（内部方法）。
    如果指定ID已存在编辑器，会先关闭旧的再创建新的。
    自动将起始节点（isStartNode=true）添加到画布上。
    首次创建编辑器时自动注册HUDPaint和Think钩子。
    
    @param  panelID         {string}    编辑器唯一标识符
    @param  pos             {table}     位置和尺寸表 {x, y, width, height}，可选
    @param  scale           {number}    初始UI缩放比例，默认为1
    @param  allowedNodes    {table}     允许使用的节点类型名称数组
    @param  hidden          {boolean}   创建后是否立即隐藏，默认为false
    @param  simplified      {boolean}   是否为简化模式（无关闭按钮等），默认为false
    @param  borderless      {boolean}   是否为无边框模式（无标题栏和节点选择面板），默认为false
    @param  showTitleMenu    {boolean}   是否显示标题功能菜单按钮，默认为false
    @param  editorMode      {string}    编辑器模式，决定自动创建哪些开始点，可选 "unit"/"command"/"counter_command"/"headquarter"，默认 "unit"
    
    @return {table}         新创建的编辑器实例对象
    
    编辑器实例字段说明：
        - id                    {string}    编辑器唯一ID
        - x, y                  {number}    编辑器在屏幕上的位置
        - width, height         {number}    编辑器尺寸
        - scale                 {number}    UI缩放比例（暂未完全使用）
        - hidden                {boolean}   是否隐藏
        - simplified            {boolean}   是否为简化模式
        - borderless            {boolean}   是否为无边框模式
        - showTitleMenu          {boolean}   是否显示标题功能菜单
        - allowedNodes          {table}     允许的节点类型名称列表
        - editorMode            {string}    编辑器模式
        - nodes                 {table}     画布上的节点实例数组
        - connections           {table}     节点间连接数据数组
        - nodeCounter           {number}    节点计数器
        - connectionCounter     {number}    连接计数器
        - tempNode              {string}    临时拖拽中的节点名称
        - tempConnection        {table}     临时连线数据 {node, port}
        - draggingNode          {table}     当前正在拖拽的节点引用
        - hoveredConnection     {table}     当前悬停的连接
        - hoveredNode           {table}     当前悬停的节点
        - selectedNodes         {table}     当前选中的节点数组
        - isSelecting           {boolean}   是否正在进行框选
        - selectionStartX/Y     {number}    框选起始位置
        - fileMenuOpen          {boolean}   文件菜单是否打开
        - contextMenu           {table}     右键菜单对象
        - canvasOffsetX/Y       {number}    画布平移偏移量
        - canvasScale           {number}    画布缩放比例
        - panningCanvas         {boolean}   是否正在平移画布
        - panStartX/Y           {number}    平移起始鼠标位置
        - panStartOffsetX/Y     {number}    平移起始偏移量
        - zooming               {boolean}   是否正在缩放
        - importWarnings        {table}     导入警告对话框数据
        - hasInvalidNodes       {boolean}   是否存在无效节点
        - hasUnregisteredNodes  {boolean}   是否存在未注册节点
]]
function INE:CreateEditor(panelID, pos, scale, allowedNodes, hidden, simplified, borderless, showTitleMenu, editorMode, showCoordinates, draggable)
    if INE.Editors[panelID] then
        INE:CloseEditor(panelID)
    end

    -- 创建编辑器实例对象，初始化所有字段
    local editor = {
        id = panelID,                                    -- 编辑器唯一ID
        x = pos and pos.x or 50,                         -- 屏幕X位置
        y = pos and pos.y or 50,                         -- 屏幕Y位置
        width = (pos and pos.width) or (ScrW() - 100),   -- 编辑器宽度
        height = (pos and pos.height) or (ScrH() - 100), -- 编辑器高度
        scale = scale or 1,                              -- UI缩放比例
        hidden = hidden or false,                        -- 是否隐藏
        simplified = simplified or false,                -- 是否为简化模式
        borderless = borderless or false,                -- 是否为无边框模式
        showTitleMenu = showTitleMenu or false,            -- 是否显示标题功能菜单
        allowedNodes = allowedNodes or {},               -- 允许的节点类型列表
        editorMode = editorMode or "unit",               -- 编辑器模式
        showCoordinates = showCoordinates or false,      -- 是否显示平面直角坐标系
        nodes = {},                                      -- 画布节点数组
        connections = {},                                -- 节点连接数组
        nodeCounter = 0,                                 -- 节点计数器
        connectionCounter = 0,                           -- 连接计数器
        tempNode = nil,                                  -- 临时拖拽节点名称
        tempConnection = nil,                            -- 临时连线数据 {node, port}
        draggingNode = nil,                              -- 当前拖拽中的节点引用
        hoveredConnection = nil,                         -- 鼠标悬停的连接
        hoveredNode = nil,                               -- 鼠标悬停的节点
        selectedNodes = {},                              -- 当前选中的节点数组
        selectedOutputs = {},                            -- 当前选中的输出点数组（每项 {node, port}，为未来多选预留数组结构）
        isSelecting = false,                             -- 是否正在进行框选
        selectionStartX = 0,                             -- 框选起始X位置
        selectionStartY = 0,                             -- 框选起始Y位置
        fileMenuOpen = false,                            -- 文件菜单是否打开
        contextMenu = nil,                               -- 右键上下文菜单对象
        canvasOffsetX = 0,                               -- 画布平移X偏移量
        canvasOffsetY = 0,                               -- 画布平移Y偏移量
        canvasScale = 1,                                 -- 画布缩放比例
        panningCanvas = false,                           -- 是否正在平移画布
        panStartX = 0,                                   -- 平移起始鼠标X
        panStartY = 0,                                   -- 平移起始鼠标Y
        panStartOffsetX = 0,                             -- 平移起始偏移X
        panStartOffsetY = 0,                             -- 平移起始偏移Y
        zooming = false,                                 -- 是否正在缩放
        importWarnings = nil,                            -- 导入警告对话框数据
        hasInvalidNodes = false,                         -- 是否存在无效节点标记
        hasUnregisteredNodes = false,                    -- 是否存在未注册节点标记
        overlayWindows = {},                             -- 叠加窗口表
        _viewMenuOpen = false,                           -- 视图菜单是否打开
        _viewMenuHoveredItem = 0,                        -- 视图菜单当前悬停项索引
        _viewZoomFollowMouse = INE._viewZoomFollowMouse or false,  -- 是否沿鼠标缩放（全局记忆）
        _viewConnectionMode = INE._viewConnectionMode or false,    -- 绘制顺序模式：false=查看内容，true=查看连线（全局记忆）
        _viewMode = nil,                                 -- 视图模式：nil=全屏, "half"=半屏, "window"=窗口
        _arrayVarScrollOffset = 0,                       -- 数组变量对话框项列表滚动偏移
        _findNodeWindowOpen = false,                     -- 查找节点窗口是否打开
        _findNodeSearchText = "",                        -- 查找节点搜索文字
        _findNodeSelectedIndex = 0,                      -- 查找节点选中索引
        _findKeyStates = {},                             -- 查找窗口按键状态表
        _findNodeInputFocused = true,                    -- 查找窗口输入框焦点
        _findNodeEscPressed = false,                     -- ESC键防抖标记
        _findNodeBackspacePressed = false,               -- BACKSPACE键防抖标记
        _findNodeUpPressed = false,                      -- UP键防抖标记
        _findNodeDownPressed = false,                    -- DOWN键防抖标记
        _findNodeEnterPressed = false,                   -- ENTER键防抖标记
        _overlayClientClickHandled = false,              -- 叠加窗口客户区点击防抖标记
        _wheelZoomHandled = false,                       -- 滚轮缩放防抖标记
        _closeBtnPressed = false,                        -- 关闭按钮是否处于按下状态（用于点击释放检测）
        selectedBackgroundImage = nil,                   -- 编辑器背景图片路径
        notifications = {},                              -- INE 弹出通知列表
        hoverTooltip = { text = "", updated = false },   -- INE 悬停提示状态
        dataConnections = {},                            -- 数据连接数组
        dataConnectionCounter = 0,                       -- 数据连接计数器
        draggingDataPort = nil,                          -- 正在拖拽的数据点 {node, portData, portType}
        tempDataConnection = nil,                        -- 临时数据连接数据
        -- 变量页面相关
        selectorPage = "nodes",                          -- 选择器页面: "nodes" 或 "variables"
        selectorScrollOffset = 0,                        -- 节点列表滚动偏移
        _advPanelOpen = false,                           -- 节点选择器"高级"上拉框展开状态（固定基础变量节点）
        expandedVarTypes = {},                           -- 已展开的变量类型集合 { [typeId] = true }
        _allVarMode = false,                             -- 变量全变量模式（展示所有sh_varlib变量）
        varScrollOffset = 0,                             -- 变量列表滚动偏移
        _selectedVarItem = nil,                          -- 当前选中的用户变量key
        _varSearchText = {},                             -- 变量搜索文本 { [typeId] = "text" }
        _varHoverPreview = {                             -- 变量悬停预览状态 { hoverKey, hoverStart, alpha, hoverData }
            hoverKey = nil,
            hoverStart = 0,
            alpha = 0,
            hoverData = nil,
        },
        varTypeScrollOffset = 0,                         -- 变量类型列表滚动偏移
        functionSubEditors = {},                         -- 函数子编辑器表 { varName = editorID }
        activeFunctionEditor = nil,                      -- 当前激活的函数编辑器ID
        renamingVarType = nil,                           -- 正在重命名的变量类型（操作时临时标记）
        renamingVarName = nil,                           -- 正在重命名的变量名
        variables = {}                                   -- 该编辑器实例独立的变量数据 { typeId = { {name, desc}, ... } }
    }

    -- 从传入参数合并可拖动等配置项
    if pos and pos.draggable ~= nil then
        editor.draggable = pos.draggable
    elseif draggable ~= nil then
        editor.draggable = draggable
    else
        editor.draggable = false
    end

    -- 自动创建当前模式对应的开始点（沿 y 轴排列在 x=0 上）
    INE:CreateStartNodesForEditor(editor)
    
    -- 自动适配视图以确保起始节点在新创建的编辑器中可见
    INE:FitAllNodes(editor)
    
    -- 为新编辑器随机选择一张背景图片
    INE:SelectRandomBackground(editor)
    
    INE.Editors[panelID] = editor
    
    -- 每次创建编辑器都调用 AddHooks（内部先移除再重加钩子）：
    -- 确保 INE 的 HUDPaint 钩子始终位于所有其他 HUDPaint 之后注册（后注册后绘制=最顶层），
    -- 否则本会话已创建过 INE 编辑器（HookAdded=true）后再打开卡牌编辑器时，
    -- 其不透明内容区背景会绘制在 INE 面板之上，导致面板不可见。
    INE:AddHooks()
    
    INE.ActiveEditorID = panelID
    
    return editor
end

--[[
    关闭并销毁指定的编辑器实例。
    如果关闭的是最后一个编辑器实例，会同时移除已注册的钩子。
    
    @param  panelID {string}    要关闭的编辑器ID
]]
function INE:CloseEditor(panelID)
    local editor = INE.Editors[panelID]
    if not editor then return end

    -- 清理 DTextEntry 搜索输入框
    if INE.VarSearchState and INE.VarSearchState.editorID == panelID then
        INE.VarSearchState.active = false
        INE.VarSearchState.editorID = nil
        INE.VarSearchState.typeId = nil
        local entry = INE.VarSearchTextEntry
        if entry and IsValid(entry) then
            entry:Remove()
        end
        INE.VarSearchTextEntry = nil
    end
    
    -- 清理数字变量对话框 DTextEntry
    if INE.NumVarFieldState and INE.NumVarFieldState.editorID == panelID then
        INE.NumVarFieldState.active = false
        INE.NumVarFieldState.editorID = nil
        INE.NumVarFieldState.field = nil
        local entry = INE.NumVarTextEntry
        if entry and IsValid(entry) then
            entry:Remove()
        end
        INE.NumVarTextEntry = nil
    end
    
    -- 清理函数变量对话框 DTextEntry
    if INE.FuncVarFieldState and INE.FuncVarFieldState.editorID == panelID then
        INE.FuncVarFieldState.active = false
        INE.FuncVarFieldState.editorID = nil
        local entry = INE.FuncVarTextEntry
        if entry and IsValid(entry) then
            entry:Remove()
        end
        INE.FuncVarTextEntry = nil
    end
    if INE.FuncParamFieldState and INE.FuncParamFieldState.editorID == panelID then
        INE.FuncParamFieldState.active = false
        INE.FuncParamFieldState.editorID = nil
        local entry = INE.FuncParamTextEntry
        if entry and IsValid(entry) then
            entry:Remove()
        end
        INE.FuncParamTextEntry = nil
    end

    -- 清理卡牌对象变量对话框 DTextEntry
    if INE.CardVarFieldState and INE.CardVarFieldState.editorID == panelID then
        INE.CardVarFieldState.active = false
        INE.CardVarFieldState.editorID = nil
        INE.CardVarFieldState.field = nil
        local entry = INE.CardVarTextEntry
        if entry and IsValid(entry) then
            entry:Remove()
        end
        INE.CardVarTextEntry = nil
    end

    -- 清理布尔值变量对话框 DTextEntry
    if INE.BoolVarFieldState and INE.BoolVarFieldState.editorID == panelID then
        INE.BoolVarFieldState.active = false
        INE.BoolVarFieldState.editorID = nil
        INE.BoolVarFieldState.field = nil
        local entry = INE.BoolVarTextEntry
        if entry and IsValid(entry) then
            entry:Remove()
        end
        INE.BoolVarTextEntry = nil
    end

    -- 清理基础变量操作节点内联输入框 DTextEntry
    local varOp = KARDS.CardEditor.VarOpNodes
    if varOp and varOp.InputState and varOp.InputState.active then
        varOp.InputState.active = false
        varOp.InputState.node = nil
        varOp.InputState.entry = nil
        varOp.InputState.field = nil
        local entry = varOp.InputEntry
        if entry and IsValid(entry) then
            entry:Remove()
        end
        varOp.InputEntry = nil
    end
    -- 清理函数变量对话框待确认参数状态
    if editor._funcVarPendingParam then
        editor._funcVarPendingParam = nil
    end
    if editor._funcDialogDataEditor then
        editor._funcDialogDataEditor = nil
    end
    
    -- 如果是函数子编辑器且非继承关闭，从父编辑器的跟踪表中移除
    if editor._isFunctionSubEditor and not editor._inheritedClose then
        for _, parentEditor in pairs(INE.Editors) do
            if parentEditor.functionSubEditors then
                for varName, subID in pairs(parentEditor.functionSubEditors) do
                    if subID == panelID then
                        parentEditor.functionSubEditors[varName] = nil
                        if parentEditor.activeFunctionEditor == panelID then
                            parentEditor.activeFunctionEditor = nil
                        end
                        break
                    end
                end
            end
        end
    end
    
    -- 如果关闭的是父编辑器，同时关闭所有函数子编辑器
    if editor.functionSubEditors then
        for varName, subID in pairs(editor.functionSubEditors) do
            local subEditor = INE.Editors[subID]
            if subEditor then
                subEditor._inheritedClose = true   -- 标记继承关闭，避免递归清理父表
                INE:CloseEditor(subID)
            end
        end
        editor.functionSubEditors = {}
        editor.activeFunctionEditor = nil
    end
    
    -- 如果关闭的是当前激活的编辑器，清空激活ID
    if INE.ActiveEditorID == panelID then
        INE.ActiveEditorID = nil
    end
    
    -- 从编辑器表中移除
    INE.Editors[panelID] = nil
    
    -- 检查是否还有其他编辑器存在
    local hasOtherEditors = false
    for _ in pairs(INE.Editors) do
        hasOtherEditors = true
        break
    end
    
    -- 如果没有其他编辑器了，移除钩子以节省性能
    if not hasOtherEditors and INE.HookAdded then
        INE:RemoveHooks()
    end
end

--[[
    注册HUDPaint和Think钩子。
    每次创建编辑器时都会调用（内部先移除再重加），确保钩子始终位于注册序末尾。
]]
function INE:AddHooks()
    -- 如果钩子已注册，先移除并重新添加，确保 INE 的 HUDPaint 钩子始终位于最后，
    -- 避免被其他 HUDPaint（例如卡牌编辑器）覆盖，从而保证节点和提示在最顶层绘制。
    if INE.HookAdded then
        hook.Remove("HUDPaint", "INE_DrawEditors")
        hook.Remove("Think", "INE_Think")
        hook.Remove("CreateMove", "INE_WheelCapture")
    end
    INE.HookAdded = true
    
    -- 注册鼠标滚轮捕获钩子（使用 CreateMove 因为 WasMousePressed 仅在 Move 钩子中生效）
    hook.Add("CreateMove", "INE_WheelCapture", function(cmd)
        if input.WasMousePressed(MOUSE_WHEEL_UP) then
            INE._wheelZoomIn = true
            INE._filterWheelUp = true
            -- 直接标志 NumericVarPopup / GlobalVarSelector，绕开 INE 变量作用域问题
            local nvp = KARDS.CardEditor.Canvas.NumericVarPopup
            if nvp then nvp._wheelScroll = "up" end
            local gvs = KARDS.CardEditor.Canvas.GlobalVarSelector
            if gvs then gvs._wheelScroll = "up" end
            local kw = KARDS.CardEditor.Canvas.KeywordMultiSelect
            if kw then kw._wheelScroll = "up" end
        elseif input.WasMousePressed(MOUSE_WHEEL_DOWN) then
            INE._wheelZoomOut = true
            INE._filterWheelDown = true
            local nvp = KARDS.CardEditor.Canvas.NumericVarPopup
            if nvp then nvp._wheelScroll = "down" end
            local gvs = KARDS.CardEditor.Canvas.GlobalVarSelector
            if gvs then gvs._wheelScroll = "down" end
            local kw = KARDS.CardEditor.Canvas.KeywordMultiSelect
            if kw then kw._wheelScroll = "down" end
        end
    end)
    
    -- 注册绘制钩子：每帧绘制所有可见编辑器。
    -- 鼠标左键状态统一采样在 DrawAllEditors 开头进行（每帧仅一次，本钩子是唯一调用方）。
    hook.Add("HUDPaint", "INE_DrawEditors", function()
        INE:DrawAllEditors()
    end)
    
    -- 注册逻辑钩子：每帧处理输入和更新逻辑
    hook.Add("Think", "INE_Think", function()
        INE:Think()
    end)
end

--[[
    移除HUDPaint和Think钩子。
    在最后一个编辑器关闭时调用，释放钩子资源。
]]
function INE:RemoveHooks()
    INE.HookAdded = false
    hook.Remove("HUDPaint", "INE_DrawEditors")
    hook.Remove("Think", "INE_Think")
    hook.Remove("CreateMove", "INE_WheelCapture")
end

--[[
    为指定编辑器创建当前模式对应的开始点。
    开始点固定排列在 x=0 的 y 轴上，间距为节点高度 + 10。
    仅当 allowedNodes 包含 "start_point" 时才会创建。
    
    @param  editor  {table} 编辑器实例对象
]]
function INE:CreateStartNodesForEditor(editor)
    if not editor then return end
    
    -- 检查编辑器是否允许使用 start_point 节点类型
    local hasStartPoint = false
    for _, nodeName in ipairs(editor.allowedNodes) do
        if nodeName == "start_point" then
            hasStartPoint = true
            break
        end
    end
    if not hasStartPoint then return end
    
    if not INE.RegisteredNodes["start_point"] then
        error("[IndependentNodeEditor] 开始点节点类型 'start_point' 未注册")
    end
    
    -- 移除已有的 start_point 和 data_start_point 节点，避免重复
    local i = 1
    while i <= #editor.nodes do
        if editor.nodes[i].name == "start_point" or editor.nodes[i].name == "data_start_point" then
            table.remove(editor.nodes, i)
        else
            i = i + 1
        end
    end
    
    local startNodeDefs = INE.StartNodeDefinitions[editor.editorMode or "unit"] or INE.StartNodeDefinitions.unit
    local spacing = 120
    
    for idx, title in ipairs(startNodeDefs) do
        -- 钳击及钳击对象开始点仅在卡牌选中"钳击"词条时显示
        local skipNode = false
        if title == "钳击" or title == "钳击对象" then
            local keywords = KARDS.CardEditor.Canvas.CardAppearance.keywords or {}
            if not table.HasValue(keywords, "pincer") then
                skipNode = true
            end
        end
        
        if not skipNode then
            local nodeName
            if title == "钳击对象" then
                nodeName = "data_start_point"
            else
                nodeName = "start_point"
            end
            local node = INE:CreateNewNodeInstance(nodeName, editor, 0, (idx - 1) * spacing)
            node.data.title = title
            node.canDelete = false
            
            -- 为"钳击对象"数据源开始点配置数据输出端口
            if title == "钳击对象" then
                node.availableOutputTypes = node.availableOutputTypes or {}
                table.insert(node.availableOutputTypes, {
                    type = "e",
                    name = "钳击对象",
                    label = "钳击对象"
                })
                node.selectedOutputTypes = node.selectedOutputTypes or {}
                table.insert(node.selectedOutputTypes, {
                    type = "e",
                    name = "钳击对象",
                    label = "钳击对象"
                })
            end
            
            table.insert(editor.nodes, node)
        end
    end
    
    -- 反制模式：自动创建一个事件监测节点并连接到「激活时」开始点。
    -- 该节点仅为快捷起点，用户可删除（反制可改用注册钩子节点路径）。
    if editor.editorMode == "counter_command" then
        -- 检查是否已存在事件监测节点（避免重复创建）
        local hasEventMonitor = false
        for _, n in ipairs(editor.nodes) do
            if n.type == "event_monitor" then
                hasEventMonitor = true
                break
            end
        end
        
        if not hasEventMonitor then
            -- 创建事件监测节点（放置在激活时开始点右侧）
            local monitorNode = INE:CreateNewNodeInstance("event_monitor_node", editor, 220, spacing)  -- 与「激活时」同行
            table.insert(editor.nodes, monitorNode)
            
            -- 初始化节点数据：第一个单选固定为「敌方」(index=2)
            if monitorNode.data then
                monitorNode.data.select_1 = 2
            end
            
            -- 查找「激活时」开始点
            local triggerNode = nil
            for _, n in ipairs(editor.nodes) do
                if n.isStartNode and n.data and n.data.title == "激活时" then
                    triggerNode = n
                    break
                end
            end
            
            -- 创建固定连接（激活时 → 事件监测）
            if triggerNode then
                table.insert(editor.connections, {
                    id = INE:GenerateConnectionID(),
                    fromNode = triggerNode.id,
                    toNode = monitorNode.id,
                    fromPort = "output"
                })
            end
        end
    end
end

--[[
    绘制所有未隐藏的编辑器实例。
    由HUDPaint钩子每帧调用。
]]
-- 本帧 INE 面板是否已由卡牌编辑器（Canvas）显式绘制（帧号防重）。
-- 卡牌编辑器在 DrawEffectEditor 内显式调用 DrawAllEditorsInternal 并记录帧号，
-- INE_DrawEditors 钩子据此跳过，保证 INE 面板始终绘制在 Canvas 内容之后（最顶层），
-- 不依赖 HUDPaint 钩子注册顺序（Lua pairs 遍历顺序不保证 FIFO，此前 Canvas 的不透明
-- 背景曾盖住 INE 面板导致面板不可见）。
INE._canvasDrawnFrame = 0

function INE:DrawAllEditors()
    -- 本帧已由卡牌编辑器显式绘制（见 cl_canvas_editor.lua DrawEffectEditor），跳过避免重复
    if INE._canvasDrawnFrame == FrameNumber() then return end
    INE:DrawAllEditorsInternal()
end

function INE:DrawAllEditorsInternal()
    -- 在 HUDPaint 开始时统一采样鼠标左键状态，供后续所有 cardObjectMode 组件与
    -- 节点内组件的点击检测使用。本函数每帧仅执行一次（INE_DrawEditors 钩子
    -- 与卡牌编辑器显式绘制互斥，见 DrawAllEditors 帧号防重）。
    local mouseDown = input.IsMouseDown(MOUSE_LEFT)
    -- 独立运行模式（无卡牌编辑器，Canvas.Enabled 为 false）时，由 INE 负责
    -- Canvas 悬停提示的帧首重置：下拉框悬停写入的术语提示在本帧末尾统一绘制
    --（见下方 Canvas.DrawHoverTooltip 补绘），并在无悬停时自动清除过期提示。
    -- 嵌入模式（Canvas 显式驱动）下 Canvas.DrawEditor 已每帧重置该标记，
    -- INE 不干预，仅末尾补绘，避免误清 Canvas 自身元素的悬停提示。
    local canvasActive = KARDS.CardEditor.Canvas and KARDS.CardEditor.Canvas.Enabled
    if not canvasActive then
        KARDS.CardEditor.Canvas.HoverTooltipUpdated = false
    end
    -- 首次初始化：确保 _prevCardObjectMD 为 false 而非 nil，让首次点击也能正确触发边缘检测
    if KARDS.CardEditor.Canvas._prevCardObjectMD == nil then
        KARDS.CardEditor.Canvas._prevCardObjectMD = false
    end
    self._frameMouseJustPressed = mouseDown and not KARDS.CardEditor.Canvas._prevCardObjectMD
    KARDS.CardEditor.Canvas._prevCardObjectMD = mouseDown

    for id, editor in pairs(INE.Editors) do
        if not editor.hidden then
            INE:DrawEditor(editor)
        end
    end

    -- 绘制函数子编辑器外部描边矩形闪烁动画：
    -- 函数槽 f 按钮在对应局部函数子编辑器已打开时再次按下，子编辑器外部绘制
    -- 紫色闪烁描边矩形（透明度随时间衰减 + 高频明暗闪烁，约 2 秒后自动消失，
    -- 仅视觉引导定位，与 FunctionLinkFlash 连线闪烁并列使用）。
    local flashNow = SysTime()
    for id, editor in pairs(INE.Editors) do
        local untilT = editor._flashOutlineUntil
        if untilT then
            if untilT > flashNow and not editor.hidden then
                local startT = editor._flashOutlineStart or untilT
                local elapsed = flashNow - startT
                local fade = math.max(0, 1 - elapsed / 2)
                local blinkOn = (math.floor(flashNow * 12) % 2 == 0)
                local alpha = math.floor(255 * fade * (blinkOn and 1 or 0.35))
                if alpha > 0 then
                    local fx, fy = editor.x - 3, editor.y - 3
                    local fw, fh = (editor.width or 0) + 6, (editor.height or 0) + 6
                    surface.SetDrawColor(200, 150, 255, alpha)  -- 函数类型色（紫）
                    surface.DrawOutlinedRect(fx, fy, fw, fh)
                    -- 加厚一层（外扩 1px）增强可见度
                    surface.SetDrawColor(200, 150, 255, math.floor(alpha * 0.6))
                    surface.DrawOutlinedRect(fx - 1, fy - 1, fw + 2, fh + 2)
                end
            else
                -- 已过期或面板已隐藏：清除闪烁标记
                editor._flashOutlineUntil = nil
                editor._flashOutlineStart = nil
            end
        end
    end
    
    -- 在所有编辑器面板绘制完成后再绘制已展开的下拉选项列表，
    -- 确保选项图层在所有面板矩形之上，避免 z-order 问题。
    KARDS.CardEditor.Canvas.DrawExpandedDropdowns()
    
    -- 绘制数字槽变量选择弹窗
    KARDS.CardEditor.Canvas.DrawNumericVarPopup()
    
    -- 绘制函数变量选择弹窗（funcslot 函数槽单选下拉，样式与数字槽弹窗相同）
    KARDS.CardEditor.Canvas.DrawFuncVarPopup()
    
    -- 绘制卡牌对象选择器弹窗（INE 单选组件的卡牌对象模式）
    KARDS.CardEditor.Canvas.DrawCardObjectSelector()
    
    -- 绘制全局变量选择器浮层（"设置变量"/"判断变量关系"共用，浮层绘制在所有节点之上）
    if KARDS.CardEditor.VarOpNodes and KARDS.CardEditor.VarOpNodes.DrawGlobalVarSelectorPopup then
        KARDS.CardEditor.VarOpNodes.DrawGlobalVarSelectorPopup()
    end
    
    -- 绘制词条多选浮层（"设置变量"节点"词条"操作，templates.md L1122）
    if KARDS.CardEditor.VarOpNodes and KARDS.CardEditor.VarOpNodes.DrawKeywordMultiSelect then
        KARDS.CardEditor.VarOpNodes.DrawKeywordMultiSelect()
    end

    -- 绘制函数面板连线闪烁动画（"新建变量"f 类型"编辑函数"按钮，templates.md L1088）
    if KARDS.CardEditor.VarOpNodes and KARDS.CardEditor.VarOpNodes.DrawFunctionLinkFlash then
        KARDS.CardEditor.VarOpNodes.DrawFunctionLinkFlash()
    end

    -- 补绘 Canvas 系统悬停提示（术语释义等）到最顶层：
    -- DrawDropdown / DrawExpandedDropdowns（含 INE 复用）悬停时写入
    -- KARDS.CardEditor.Canvas.HoverTooltip。独立模式（无 Canvas 驱动）下该提示
    -- 没有其他绘制方，在此补绘一次确保可见；
    -- 嵌入模式下 Canvas.DrawEditor 帧末已在 INE 面板之后统一绘制
    -- （cl_canvas_editor.lua L2769，晚于 INE 面板不会被遮挡），此处不再补绘，
    -- 避免同一提示被绘制两次（单选组件悬停提示出现两次）。
    -- 清除逻辑仅在独立模式执行（嵌入模式由 Canvas.DrawEditor 帧末负责，
    -- cl_canvas_editor.lua L2764-2767）；补绘仅独立模式。
    if not canvasActive then
        if not KARDS.CardEditor.Canvas.HoverTooltipUpdated then
            KARDS.CardEditor.Canvas.ClearHoverTooltip()
        end
        KARDS.CardEditor.Canvas.DrawHoverTooltip()
    end
end

--[[
    绘制单个编辑器的完整界面，包括：背景边框、标题栏、节点选择面板、
    网格背景、连接线、节点、选区框、临时节点预览、导入警告对话框。
    
    @param  editor  {table}     编辑器实例对象
]]
function INE:DrawEditor(editor)
    local x, y = editor.x, editor.y
    local w, h = editor.width, editor.height
    
    -- 兼容旧编辑器实例：确保新字段有默认值
    if not editor.selectorPage then editor.selectorPage = "nodes" end
    if not editor.expandedVarTypes then editor.expandedVarTypes = {} end
    if editor._allVarMode == nil then editor._allVarMode = false end
    if not editor.varScrollOffset then editor.varScrollOffset = 0 end
    if editor._selectedVarItem == nil then editor._selectedVarItem = nil end
    if not editor._varSearchText then editor._varSearchText = {} end
    if editor._viewZoomFollowMouse == nil then editor._viewZoomFollowMouse = INE._viewZoomFollowMouse or false end
    if editor._viewConnectionMode == nil then editor._viewConnectionMode = INE._viewConnectionMode or false end
    
    -- 每帧开始时重置悬停提示更新标记，若本帧没有更新则自动清除
    INE:BeginHoverTooltipFrame(editor)
    
    -- 清除上一帧的交互元素包围盒记录，由 DrawComponents 在本帧重新填充
    editor._interactiveRects = {}
    
    -- 绘制编辑器边框和背景（非无边框模式）
    if not editor.borderless then
        -- 外层阴影/边框
        draw.RoundedBox(8, x, y, w, h, Color(40, 40, 45, 240))
        draw.RoundedBox(8, x + 2, y + 2, w - 4, h - 4, Color(50, 50, 55, 255))
        
        -- 绘制标题栏背景
        surface.SetDrawColor(Color(60, 60, 70))
        surface.DrawRect(x, y, w, 35)

        -- 可拖动面板显示拖动手柄指示符（紧凑型三点，避免被标题文字遮罩）
        if editor.draggable then
            surface.SetDrawColor(Color(120, 120, 130))
            for i = 0, 2 do
                surface.DrawRect(x + 5 + i * 5, y + 16, 2, 2)
            end
        end

        -- 标题文字（显示节点数量便于调试定位）
        local nodeCount = #editor.nodes
        local titleText = editor.customTitle or "节点编辑器"
        draw.SimpleText(titleText, "SourceHan_Heavy_16", x + 10, y + 17, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText("[节点:" .. nodeCount .. "]", "SourceHan_Heavy_14", x + w - 45, y + 17, Color(180, 180, 180), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        
        -- 绘制文件菜单按钮（如果启用）
        if editor.showTitleMenu then
            local fileBtnX = x + 200
            local fileBtnY = y + 5
            local fileBtnW = 60
            local fileBtnH = 25
            local mouseX, mouseY = gui.MouseX(), gui.MouseY()
            
            local hovered = mouseX >= fileBtnX and mouseX <= fileBtnX + fileBtnW and
                           mouseY >= fileBtnY and mouseY <= fileBtnY + fileBtnH
            
            local isFuncMode = editor.editorMode == "function"
            local btnLabel = isFuncMode and "函数" or "效果文件"
            local tooltipText = isFuncMode and "函数操作（保存/导入/清空）" or "效果文件操作（导入/导出/清空）"
            
            draw.RoundedBox(4, fileBtnX, fileBtnY, fileBtnW, fileBtnH, (hovered or editor.fileMenuOpen) and Color(80, 80, 90) or Color(70, 70, 80))
            draw.SimpleText(btnLabel, "SourceHan_Heavy_14", fileBtnX + fileBtnW/2, fileBtnY + fileBtnH/2, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            
            if hovered then
                INE:UpdateHoverTooltip(editor, tooltipText)
            end
            
            editor._fileBtnRect = {x = fileBtnX, y = fileBtnY, w = fileBtnW, h = fileBtnH}
            
            -- 绘制视图菜单按钮
            local viewBtnX = x + 270
            local viewBtnY = y + 5
            local viewBtnW = 60
            local viewBtnH = 25
            
            local viewHovered = mouseX >= viewBtnX and mouseX <= viewBtnX + viewBtnW and
                              mouseY >= viewBtnY and mouseY <= viewBtnY + viewBtnH
            
            draw.RoundedBox(4, viewBtnX, viewBtnY, viewBtnW, viewBtnH, (viewHovered or editor._viewMenuOpen) and Color(80, 80, 90) or Color(70, 70, 80))
            draw.SimpleText("视图", "SourceHan_Heavy_14", viewBtnX + viewBtnW/2, viewBtnY + viewBtnH/2, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            
            if viewHovered then
                INE:UpdateHoverTooltip(editor, "视图操作（重置/适配/查找节点）")
            end
            
            editor._viewBtnRect = {x = viewBtnX, y = viewBtnY, w = viewBtnW, h = viewBtnH}
        end
        
        -- 绘制关闭按钮（非简化模式）
        if not editor.simplified then
            local closeBtnX = x + w - 35
            local closeBtnY = y + 5
            local closeBtnW = 25
            local closeBtnH = 25
            local mouseX, mouseY = gui.MouseX(), gui.MouseY()
            
            local hovered = mouseX >= closeBtnX and mouseX <= closeBtnX + closeBtnW and
                           mouseY >= closeBtnY and mouseY <= closeBtnY + closeBtnH
            
            draw.RoundedBox(4, closeBtnX, closeBtnY, closeBtnW, closeBtnH, hovered and Color(200, 70, 70) or Color(180, 60, 60))
            draw.SimpleText("X", "SourceHan_Heavy_14", closeBtnX + closeBtnW/2, closeBtnY + closeBtnH/2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            
            if hovered then
                INE:UpdateHoverTooltip(editor, "关闭节点编辑器")
            end
        end
    end
    
    -- 计算内容区域位置
    local contentX = x + 5
    local contentY = editor.borderless and y or (y + 40)
    local contentW = w - 10
    local contentH = editor.borderless and h or (h - 45)
    
    -- 绘制内容区域背景
    if not editor.borderless then
        draw.RoundedBox(4, contentX, contentY, contentW, contentH, Color(35, 35, 40))
    end
    
    -- 绘制左侧节点选择面板（非无边框模式）
    local selectorW = 150
    local selectorX = contentX
    local selectorY = contentY + 5
    
    if not editor.borderless then
        -- 选择面板背景
        draw.RoundedBox(4, selectorX, selectorY, selectorW, contentH - 10, Color(45, 45, 50))
        draw.SimpleText("可用节点", "SourceHan_Heavy_14", selectorX + selectorW/2, selectorY + 12, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        
        -- 页面切换单选按钮：节点选择 | 变量
        local toggleY = selectorY + 24
        local toggleH = 18
        local toggleW = (selectorW - 16) / 2  -- 两个按钮平分宽度
        local toggleX1 = selectorX + 6
        local toggleX2 = selectorX + 6 + toggleW
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        local isNodesPage = editor.selectorPage == "nodes"
        local isVarsPage = editor.selectorPage == "variables"
        
        -- "节点选择" 按钮
        local nodesHov = mouseX >= toggleX1 and mouseX <= toggleX1 + toggleW and
                        mouseY >= toggleY and mouseY <= toggleY + toggleH
        draw.RoundedBox(4, toggleX1, toggleY, toggleW, toggleH, isNodesPage and Color(0, 102, 204) or Color(55, 55, 60))
        draw.SimpleText("节点选择", "SourceHan_Heavy_12", toggleX1 + toggleW/2, toggleY + toggleH/2, isNodesPage and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        editor._toggleNodesRect = {x = toggleX1, y = toggleY, w = toggleW, h = toggleH}
        
        -- "变量" 按钮（悬停时显示"展示所有？"，全变量模式显示"还原？"）
        local varsHov = mouseX >= toggleX2 and mouseX <= toggleX2 + toggleW and
                       mouseY >= toggleY and mouseY <= toggleY + toggleH
        local varBtnLabel = "变量"
        if isVarsPage and editor._allVarMode then
            varBtnLabel = "还原？"
        elseif isVarsPage and varsHov then
            varBtnLabel = "展示所有？"
        end
        local varBtnColor = isVarsPage and (editor._allVarMode and Color(180, 50, 50) or Color(0, 102, 204)) or Color(55, 55, 60)
        draw.RoundedBox(4, toggleX2, toggleY, toggleW, toggleH, varBtnColor)
        draw.SimpleText(varBtnLabel, "SourceHan_Heavy_12", toggleX2 + toggleW/2, toggleY + toggleH/2, isVarsPage and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        editor._toggleVarsRect = {x = toggleX2, y = toggleY, w = toggleW, h = toggleH}
        
        if isNodesPage then
            -- 计算"高级"上拉框固定基础变量节点数量与占用高度
            -- 基础变量节点从主列表移除，仅展开"高级"后在底部上拉框中固定展示；
            -- 条目样式与主列表一致（50 高 + 10 间距），上拉框高度随节点数动态计算。
            local advCount = INE:GetAdvVarOpCount(editor)
            local advBoxH = advCount > 0 and (advCount * 50 + (advCount - 1) * 10) or 0
            local advBtnH = 24
            local advBtnW = selectorW - 12
            local advBtnX = selectorX + 6
            -- 展开时按钮上移（上移量 = 上拉框高度），上拉框占据按钮下方到面板底部的区域
            local advBtnY = selectorY + contentH - 10 - advBtnH - 4
            if editor._advPanelOpen then advBtnY = advBtnY - advBoxH end

            -- 绘制可拖拽的节点列表（跳过起始节点与基础变量节点，支持裁剪与滚动）
            local nodeListStartY = selectorY + 48
            local nodeListEndY = selectorY + contentH - 10
            -- 展开"高级"上拉框时，主列表底部让位于上拉框与按钮
            if editor._advPanelOpen then
                nodeListEndY = nodeListEndY - advBoxH - advBtnH - 8
            end
            local listClipH = nodeListEndY - nodeListStartY

            -- 计算所有可见节点总高度
            local totalNodesHeight = 0
            for _, nodeName in ipairs(editor.allowedNodes) do
                local template = INE.RegisteredNodes[nodeName]
                if template and not template.isStartNode and not template._varOpNode then
                    totalNodesHeight = totalNodesHeight + 50 + 10
                end
            end
            if totalNodesHeight > 0 then totalNodesHeight = totalNodesHeight - 10 end

            -- 限制滚动偏移
            local maxScroll = math.max(0, totalNodesHeight - listClipH)
            editor.selectorScrollOffset = math.Clamp(editor.selectorScrollOffset, 0, maxScroll)

            -- 启用裁剪，防止节点条目溢出面板
            render.SetScissorRect(selectorX, nodeListStartY, selectorX + selectorW, nodeListEndY, true)

            local nodeListY = nodeListStartY - editor.selectorScrollOffset
            for _, nodeName in ipairs(editor.allowedNodes) do
                local template = INE.RegisteredNodes[nodeName]
                if template and not template.isStartNode and not template._varOpNode then
                    local nodeEntryH = 50

                    -- 只在可见区域内绘制，优化性能
                    if nodeListY + nodeEntryH >= nodeListStartY and nodeListY <= nodeListEndY then
                        local hovered = mouseX >= selectorX + 10 and mouseX <= selectorX + selectorW - 10 and
                                       mouseY >= nodeListY and mouseY <= nodeListY + nodeEntryH

                        -- 使用节点模板颜色作为外框，内部深色填充
                        local displayColor = template.color or Color(100, 100, 100)
                        if hovered then
                            displayColor = Color(math.min(displayColor.r + 30, 255), math.min(displayColor.g + 30, 255), math.min(displayColor.b + 30, 255))
                        end

                        draw.RoundedBox(6, selectorX + 10, nodeListY, selectorW - 20, nodeEntryH, displayColor)
                        draw.RoundedBox(6, selectorX + 12, nodeListY + 2, selectorW - 24, nodeEntryH - 4, Color(40, 40, 40))
                        draw.SimpleText(template.displayName or template.name, "SourceHan_Heavy_14", selectorX + selectorW / 2, nodeListY + nodeEntryH / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

                        if hovered then
                            INE:UpdateHoverTooltip(editor, "拖动以创建 " .. (template.displayName or template.name) .. " 节点")
                        end
                    end

                    nodeListY = nodeListY + nodeEntryH + 10
                end
            end

            -- 恢复裁剪
            render.SetScissorRect(0, 0, 0, 0, false)

            -- 绘制"高级"上拉框（固定基础变量节点，仅展开时显示）
            if editor._advPanelOpen and advCount > 0 then
                local boxTop = math.max(selectorY, advBtnY + advBtnH)
                render.SetScissorRect(selectorX, boxTop, selectorX + selectorW, selectorY + contentH - 10, true)
                local advListY = advBtnY + advBtnH
                for _, advEntry in ipairs(INE:GetAdvVarOpNodes()) do
                    local template = advEntry.template
                    if template then
                        local advHovered = mouseX >= selectorX + 10 and mouseX <= selectorX + selectorW - 10 and
                                           mouseY >= advListY and mouseY <= advListY + 50
                        -- 使用节点模板颜色作为外框，内部深色填充（与主列表条目一致）
                        local displayColor = template.color or Color(100, 100, 100)
                        if advHovered then
                            displayColor = Color(math.min(displayColor.r + 30, 255), math.min(displayColor.g + 30, 255), math.min(displayColor.b + 30, 255))
                        end
                        draw.RoundedBox(6, selectorX + 10, advListY, selectorW - 20, 50, displayColor)
                        draw.RoundedBox(6, selectorX + 12, advListY + 2, selectorW - 24, 46, Color(40, 40, 40))
                        draw.SimpleText(template.displayName or template.name, "SourceHan_Heavy_14", selectorX + selectorW / 2, advListY + 25, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        if advHovered then
                            INE:UpdateHoverTooltip(editor, "拖动以创建 " .. (template.displayName or template.name) .. " 节点")
                        end
                        advListY = advListY + 50 + 10
                    end
                end
                render.SetScissorRect(0, 0, 0, 0, false)
            end

            -- 绘制"高级"按钮（面板底部；展开时上移，兼作收起开关）
            local advHovered = mouseX >= advBtnX and mouseX <= advBtnX + advBtnW and
                               mouseY >= advBtnY and mouseY <= advBtnY + advBtnH
            draw.RoundedBox(4, advBtnX, advBtnY, advBtnW, advBtnH,
                (advHovered or editor._advPanelOpen) and Color(80, 80, 90) or Color(55, 55, 60))
            draw.SimpleText("高级", "SourceHan_Heavy_14", advBtnX + advBtnW / 2, advBtnY + advBtnH / 2,
                Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if advHovered then
                INE:UpdateHoverTooltip(editor, editor._advPanelOpen and "收起基础变量节点固定区" or "展开基础变量节点固定区")
            end
        else
            -- 变量页面
            DrawGlobalVarPage(editor, selectorX, selectorY + 48, selectorW, contentH - 58, mouseX, mouseY)
        end
    end
    
    -- 计算画布区域位置（使用GetCanvasRect）
    local canvasRect = INE:GetCanvasRect(editor)
    local canvasX, canvasY, canvasW, canvasH = canvasRect.x, canvasRect.y, canvasRect.w, canvasRect.h
    
    -- 启用画布裁剪区域
    INE:BeginCanvasScissor(editor)
    
    -- 绘制背景图片（位于网格和节点之下，以填充模式覆盖画布区域）
    if editor.selectedBackgroundImage then
        local bgMat = Material(editor.selectedBackgroundImage, "noclamp smooth")
        if bgMat and not bgMat:IsError() then
            surface.SetDrawColor(255, 255, 255, 50) -- 半透明
            surface.SetMaterial(bgMat)
            surface.DrawTexturedRect(canvasX, canvasY, canvasW, canvasH)
        end
    end
    
    -- 绘制多层矩阵网格背景（透视矩阵系统）
    -- 矩阵任何放大与缩小，只改变矩阵疏密度和透明度（或亮度），不改变每个连接线的缩放
    local worldLeft, worldTop = INE:ScreenToWorld(editor, canvasX, canvasY)
    local worldRight, worldBottom = INE:ScreenToWorld(editor, canvasX + canvasW, canvasY + canvasH)
    local canvasScale = editor.canvasScale
    
    for _, layer in ipairs(INE.GRID_LAYERS) do
        local alpha = CalculateGridAlpha(layer.worldSize, canvasScale)
        if alpha > 0 then
            local gridColor = INE.GRID_COLORS[layer.worldSize] or Color(45, 45, 50)
            surface.SetDrawColor(gridColor.r, gridColor.g, gridColor.b, alpha)
            local gridWorldSize = layer.worldSize
            
            -- 找到画布范围内第一条网格线的世界坐标
            local startGridX = math.floor(worldLeft / gridWorldSize) * gridWorldSize
            local startGridY = math.floor(worldTop / gridWorldSize) * gridWorldSize
            
            -- 绘制垂直线
            for worldGX = startGridX, worldRight, gridWorldSize do
                local screenGX, _ = INE:WorldToScreen(editor, worldGX, 0)
                surface.DrawLine(screenGX, canvasY, screenGX, canvasY + canvasH)
            end
            -- 绘制水平线
            for worldGY = startGridY, worldBottom, gridWorldSize do
                local _, screenGY = INE:WorldToScreen(editor, 0, worldGY)
                surface.DrawLine(canvasX, screenGY, canvasX + canvasW, screenGY)
            end
        end
    end

    -- 绘制平面直角坐标系（x轴、y轴、刻度与标签）
    if editor.showCoordinates then
        local axisColor = Color(200, 200, 200, 180)
        local tickColor = Color(180, 180, 180, 120)
        local labelColor = Color(220, 220, 220, 200)
        local tickHalfSize = 5
        local scale = editor.canvasScale

        -- 自适应刻度间隔：使屏幕空间刻度间距保持在约 60~120 像素
        local targetScreenSpacing = 80
        local function niceNumber(num, roundUp)
            local exp = math.floor(math.log10(num))
            local f = num / (10 ^ exp)
            local nf
            if roundUp then
                if f < 1.5 then nf = 1
                elseif f < 3.5 then nf = 2
                elseif f < 7.5 then nf = 5
                else nf = 10 end
            else
                if f <= 1 then nf = 1
                elseif f <= 2 then nf = 2
                elseif f <= 5 then nf = 5
                else nf = 10 end
            end
            return nf * (10 ^ exp)
        end
        local idealInterval = targetScreenSpacing / scale
        local tickInterval = niceNumber(idealInterval, false)

        -- 固定字号（不随缩放变化）
        local labelFont = "SourceHan_Heavy_12"

        -- 计算原点屏幕坐标
        local originScreenX, originScreenY = INE:WorldToScreen(editor, 0, 0)

        -- 绘制 x 轴（水平）和 y 轴（垂直），限制在画布区域内
        surface.SetDrawColor(axisColor)
        if originScreenY >= canvasY and originScreenY <= canvasY + canvasH then
            surface.DrawLine(canvasX, originScreenY, canvasX + canvasW, originScreenY)
        end
        if originScreenX >= canvasX and originScreenX <= canvasX + canvasW then
            surface.DrawLine(originScreenX, canvasY, originScreenX, canvasY + canvasH)
        end

        -- 绘制刻度与标签
        surface.SetDrawColor(tickColor)
        local tickStartX = math.floor(worldLeft / tickInterval) * tickInterval
        local tickStartY = math.floor(worldTop / tickInterval) * tickInterval

        for worldTX = tickStartX, worldRight, tickInterval do
            if worldTX ~= 0 then
                local screenTX, _ = INE:WorldToScreen(editor, worldTX, 0)
                if screenTX >= canvasX and screenTX <= canvasX + canvasW then
                    surface.DrawLine(screenTX, originScreenY - tickHalfSize, screenTX, originScreenY + tickHalfSize)
                    draw.SimpleText(tostring(worldTX), labelFont, screenTX, originScreenY + tickHalfSize + 2, labelColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
                end
            end
        end

        for worldTY = tickStartY, worldBottom, tickInterval do
            if worldTY ~= 0 then
                local _, screenTY = INE:WorldToScreen(editor, 0, worldTY)
                if screenTY >= canvasY and screenTY <= canvasY + canvasH then
                    surface.DrawLine(originScreenX - tickHalfSize, screenTY, originScreenX + tickHalfSize, screenTY)
                    -- Y轴标签取反使上方为正（数学坐标系惯例）
                    draw.SimpleText(tostring(-worldTY), labelFont, originScreenX - tickHalfSize - 2, screenTY, labelColor, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
                end
            end
        end

        -- 在原点处绘制 "O" 标签
        draw.SimpleText("O", labelFont, originScreenX - 4, originScreenY + 4, labelColor, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
    end

    -- 根据绘制模式选择绘制顺序
    if editor._viewConnectionMode then
        -- 查看连线模式：先绘节点全部内容，再绘连接线在上层，便于查看连接状态
        for _, node in ipairs(editor.nodes) do
            if INE:IsNodeVisible(editor, node) then
                INE:DrawNode(editor, node)
            end
        end
        for _, conn in ipairs(editor.connections) do
            local fromNode = INE:GetNodeByID(editor, conn.fromNode)
            local toNode = INE:GetNodeByID(editor, conn.toNode)
            if fromNode and toNode and INE:IsConnectionVisible(editor, fromNode, toNode) then
                INE:DrawConnection(editor, fromNode, toNode, conn.fromPort)
            end
        end
        if editor.draggingFrom then
            local fromNode = editor.draggingFrom.node
            local fromPort = editor.draggingFrom.port
            local hoverInput = INE:GetInputNodeAtPosition(editor, gui.MouseX(), gui.MouseY())
            INE:DrawTempConnection(editor, fromNode, fromPort, hoverInput ~= nil)
        end
        for _, conn in ipairs(editor.dataConnections) do
            local fromNode = INE:GetNodeByID(editor, conn.fromNode)
            local toNode = INE:GetNodeByID(editor, conn.toNode)
            if fromNode and toNode then
                INE:DrawDataConnection(editor, fromNode, toNode, conn.fromPortIndex, conn.toPortIndex)
            end
        end
        if editor.draggingDataPort then
            local fromPort = editor.draggingDataPort
            local hoverPort = INE:GetDataPortAtPosition(editor, gui.MouseX(), gui.MouseY(), fromPort.portType)
            INE:DrawTempDataConnection(editor, fromPort, hoverPort)
        end
    else
        -- 查看内容模式：保持原有绘制顺序（连接线在最底，节点在上）
        for _, conn in ipairs(editor.connections) do
            local fromNode = INE:GetNodeByID(editor, conn.fromNode)
            local toNode = INE:GetNodeByID(editor, conn.toNode)
            if fromNode and toNode and INE:IsConnectionVisible(editor, fromNode, toNode) then
                INE:DrawConnection(editor, fromNode, toNode, conn.fromPort)
            end
        end
        if editor.draggingFrom then
            local fromNode = editor.draggingFrom.node
            local fromPort = editor.draggingFrom.port
            local hoverInput = INE:GetInputNodeAtPosition(editor, gui.MouseX(), gui.MouseY())
            INE:DrawTempConnection(editor, fromNode, fromPort, hoverInput ~= nil)
        end
        for _, conn in ipairs(editor.dataConnections) do
            local fromNode = INE:GetNodeByID(editor, conn.fromNode)
            local toNode = INE:GetNodeByID(editor, conn.toNode)
            if fromNode and toNode then
                INE:DrawDataConnection(editor, fromNode, toNode, conn.fromPortIndex, conn.toPortIndex)
            end
        end
        if editor.draggingDataPort then
            local fromPort = editor.draggingDataPort
            local hoverPort = INE:GetDataPortAtPosition(editor, gui.MouseX(), gui.MouseY(), fromPort.portType)
            INE:DrawTempDataConnection(editor, fromPort, hoverPort)
        end
        for _, node in ipairs(editor.nodes) do
            if INE:IsNodeVisible(editor, node) then
                INE:DrawNode(editor, node)
            end
        end
    end
    
    -- 端口始终在最上层绘制（覆盖连接线和节点内容的遮挡），不受查看模式影响
    for _, node in ipairs(editor.nodes) do
        if INE:IsNodeVisible(editor, node) then
            INE:DrawNodePorts(editor, node)
        end
    end
    
    -- 结束画布裁剪区域
    INE:EndCanvasScissor()
    
    -- 绘制选区框（框选时半透明矩形），裁剪在画布区域内
    if editor.isSelecting then
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        local rect = INE:GetCanvasRect(editor)
        
        local sx = math.max(rect.x, math.min(editor.selectionStartX, mouseX))
        local sy = math.max(rect.y, math.min(editor.selectionStartY, mouseY))
        local ex = math.min(rect.x + rect.w, math.max(editor.selectionStartX, mouseX))
        local ey = math.min(rect.y + rect.h, math.max(editor.selectionStartY, mouseY))
        local sw = ex - sx
        local sh = ey - sy
        
        if sw > 1 and sh > 1 then
            surface.SetDrawColor(Color(100, 150, 255, 50))
            draw.RoundedBox(0, sx, sy, sw, sh, Color(100, 150, 255, 50))
            surface.SetDrawColor(Color(100, 150, 255, 200))
            surface.DrawOutlinedRect(sx, sy, sw, sh)
        end
    end
    
    -- 绘制临时节点预览（从节点面板拖拽时跟随鼠标）
    if editor.tempNode then
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        INE:DrawTempNodePreview(editor, editor.tempNode, mouseX, mouseY)
    end
    
    -- 绘制导入警告对话框
    if editor.importWarnings then
        INE:DrawImportWarningDialog(editor)
    end
    
    -- 绘制视图下拉菜单
    if editor._viewMenuOpen and editor._viewBtnRect then
        local menuItems = {
            "返回原点",
            "适配所有节点",
            "最左节点",
            "最右节点",
            "最上节点",
            "最下节点",
            "放大",
            "缩小",
            "还原缩放",
            "沿鼠标缩放",
            "查看顺序",
            "查找节点...",
            "切换坐标系",
            "--",
            "全屏",
            "半屏",
            "窗口"
        }
        local menuX = editor._viewBtnRect.x
        local menuY = editor._viewBtnRect.y + editor._viewBtnRect.h + 2
        local menuW = 160
        local menuItemH = 28
        local menuH = menuItemH * #menuItems
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        
        draw.RoundedBox(4, menuX, menuY, menuW, menuH, Color(55, 55, 65))
        
        editor._viewMenuHoveredItem = 0
        editor._viewMenuRect = {x = menuX, y = menuY, w = menuW, h = menuH}
        
        for i, itemText in ipairs(menuItems) do
            local itemY = menuY + (i - 1) * menuItemH
            local itemHovered = mouseX >= menuX and mouseX <= menuX + menuW and
                               mouseY >= itemY and mouseY <= itemY + menuItemH
            
            if itemText == "--" then
                -- 绘制分隔线
                draw.RoundedBox(0, menuX + 10, itemY + menuItemH / 2, menuW - 20, 1, Color(80, 80, 90))
            elseif itemText == "查看顺序" then
                -- "查看顺序"单选按钮：两段文字，激活的文字放大居左，未激活的文字缩小暗色居右
                if itemHovered then
                    draw.RoundedBox(0, menuX, itemY, menuW, menuItemH, Color(75, 75, 85))
                    editor._viewMenuHoveredItem = i
                end
                local isConnectMode = editor._viewConnectionMode  -- true=查看连线，false=查看内容
                -- 激活文字（左侧）：大号，高亮
                local activeLabel = isConnectMode and "查看连线" or "查看内容"
                draw.SimpleText(activeLabel, "SourceHan_Heavy_16", menuX + 10, itemY + menuItemH / 2,
                    Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                -- 未激活文字（右侧）：小号，暗色
                local inactiveLabel = isConnectMode and "查看内容" or "查看连线"
                draw.SimpleText(inactiveLabel, "SourceHan_Heavy_12", menuX + menuW - 10, itemY + menuItemH / 2,
                    Color(120, 120, 120), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
            else
                if itemHovered then
                    draw.RoundedBox(0, menuX, itemY, menuW, menuItemH, Color(75, 75, 85))
                    editor._viewMenuHoveredItem = i
                end
                local textOffset = 10
                if itemText == "沿鼠标缩放" then
                    -- 绘制复选框
                    local cbSize = 12
                    local cbX = menuX + 10
                    local cbY = itemY + (menuItemH - cbSize) / 2
                    local checked = editor._viewZoomFollowMouse
                    draw.RoundedBox(2, cbX, cbY, cbSize, cbSize, checked and Color(80, 140, 80) or Color(60, 60, 70))
                    if checked then
                        draw.SimpleText("✔", "SourceHan_Heavy_10", cbX + cbSize/2, cbY + cbSize/2, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    end
                    textOffset = 10 + cbSize + 6
                end
                draw.SimpleText(itemText, "SourceHan_Heavy_14", menuX + textOffset, itemY + menuItemH/2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
        end
    end
    
    -- 绘制文件下拉菜单
    if editor.fileMenuOpen and editor._fileBtnRect then
        local isFuncMode = editor.editorMode == "function"
        local menuItems = isFuncMode and {"编辑基础函数", "保存", "导入...", "清空画布"} or {"导出...", "导入...", "清空画布"}
        local menuX = editor._fileBtnRect.x
        local menuY = editor._fileBtnRect.y + editor._fileBtnRect.h + 2
        local menuW = 120
        local menuItemH = 28
        local menuH = menuItemH * #menuItems
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        
        draw.RoundedBox(4, menuX, menuY, menuW, menuH, Color(55, 55, 65))
        
        editor._fileMenuHoveredItem = 0
        editor._fileMenuRect = {x = menuX, y = menuY, w = menuW, h = menuH}
        
        for i, itemText in ipairs(menuItems) do
            local itemY = menuY + (i - 1) * menuItemH
            local itemHovered = mouseX >= menuX and mouseX <= menuX + menuW and
                               mouseY >= itemY and mouseY <= itemY + menuItemH
            
            if itemHovered then
                draw.RoundedBox(0, menuX, itemY, menuW, menuItemH, Color(75, 75, 85))
                editor._fileMenuHoveredItem = i
            end
            
            draw.SimpleText(itemText, "SourceHan_Heavy_14", menuX + 10, itemY + menuItemH/2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end
    
    -- 绘制叠加窗口（在所有其他内容之上，按创建顺序绘制，后创建的在上层）
    if editor.overlayWindows then
        local orderedWins = {}
        for _, win in pairs(editor.overlayWindows) do
            if win.visible then
                table.insert(orderedWins, win)
            end
        end
        table.sort(orderedWins, function(a, b) return (a._order or 0) < (b._order or 0) end)
        for _, win in ipairs(orderedWins) do
            INE:DrawOverlayWindow(editor, win)
        end
    end
    
    -- 绘制通知（位于编辑器右上角，在叠加窗口之上）
    INE:DrawNotifications(editor)
    
    -- 绘制悬停提示（最顶层）
    if not editor.hoverTooltip.updated then
        INE:ClearHoverTooltip(editor)
    end
    INE:DrawHoverTooltip(editor)
end