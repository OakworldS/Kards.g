--[[
=======================================================================================
变量面板 (Variable Page)
=======================================================================================
从 cl_ine_node_editor.lua 拆分出的子系统，负责变量页面的绘制。

包含功能：
  - DrawGlobalVarPage（节点选择器右侧的"变量"切换页内容）

依赖：
  - INE.DataTypes（数据类型注册表）
  - editor.variables（编辑器变量数据）
  - CollectLibVarsByType（变量库收集函数）

源文件：cl_ine_node_editor.lua（行 3546~4062）
=======================================================================================
]]

-- 此文件内容将剪切自 cl_ine_node_editor.lua 行 3546~4062
-- 包含：DrawGlobalVarPage
local INE = KARDS.CardEditor.IndependentNodeEditor
local T = KARDS.Lang.T

-- 编辑期当前卡牌是否为单位（固定变量 unitOnly 项展示判断；缺省视为单位）
-- 依据 Canvas.EditorMode（unit/command/counter_command/headquarter/function）
local function IsEditingUnit()
    local canvas = KARDS.CardEditor and KARDS.CardEditor.Canvas
    local mode = canvas and canvas.EditorMode
    return not mode or mode == "unit"
end

-- 获取编辑期应展示的卡牌专属固定变量（按类型；unitOnly 项仅单位卡展示）
-- 来源：KARDS.NodeParser.CARD_FIXED_VARS（数据层定义，客户端共享）
-- @param typeId string INE 数据类型 id（t/e/n 有固定变量）
-- @return table 固定变量定义数组
local function GetEditingFixedVars(typeId)
    local defs = KARDS.NodeParser and KARDS.NodeParser.CARD_FIXED_VARS
    local list = defs and defs[typeId] or nil
    if not list then return {} end
    local out = {}
    for _, fv in ipairs(list) do
        if not fv.unitOnly or IsEditingUnit() then
            table.insert(out, fv)
        end
    end
    return out
end

-- 编辑期从当前卡牌外观读取固定变量当前值（悬停预览用；数据层运行时另有 GetFixedVarValue）
-- @param fv table 固定变量定义 { name, key }
-- @return any 当前值（无法读取返回 nil）
local function GetEditingFixedVarValue(fv)
    local app = KARDS.CardEditor and KARDS.CardEditor.Canvas and KARDS.CardEditor.Canvas.CardAppearance
    local key = fv and fv.key
    if not app or not key then return nil end
    if key == "KARDS.User.名称" then return app.name
    elseif key == "KARDS.User.效果描述" then return app.specialEffect
    elseif key == "KARDS.User.历史描述" then return app.historyText
    elseif key == "KARDS.User.词条组合" then
        if KARDS.CardEditor.Data and KARDS.CardEditor.Data.BuildKeywordsText then
            return KARDS.CardEditor.Data.BuildKeywordsText(app.keywords, app.keywordValues, app.pincerValue)
        end
        return ""
    elseif key == "KARDS.User.品质" then return app.quality
    elseif key == "KARDS.User.卡牌花费" then return app.cost
    elseif key == "KARDS.User.行动花费" then return app.actionCost
    elseif key == "KARDS.User.攻击" then return app.attack
    elseif key == "KARDS.User.防御" then return app.defense
    end
    return nil
end
-- 绘制变量页面（节点选择器右侧的"变量"切换页内容）
-- 显示所有数据类型及其已定义变量的树状列表
function DrawGlobalVarPage(editor, sX, sY, sW, sH, mx, my)
    local rowH = 24
    local iconSize = 12
    local padL = 6
    local btnSize = 16

    -- ============================================================
    -- 用户自定义变量（始终显示）
    -- ============================================================
    local sortedTypes = {}
    for _, dt in pairs(INE.DataTypes) do
        table.insert(sortedTypes, dt)
    end
    table.sort(sortedTypes, function(a, b) return a.id < b.id end)

    -- 收集变量库变量（全变量模式）
    local libVarsByType = editor._allVarMode and CollectLibVarsByType(editor) or nil

    -- 悬停预览跟踪变量（在变量绘制循环中更新）
    local currentHoverKey = nil
    local currentHoverData = nil

    -- 预计算每个类型的总数（含变量库和函数参数）
    local typeTotalCount = {}
    for _, dataType in ipairs(sortedTypes) do
        local typeId = dataType.id
        local userVars = editor.variables[typeId] or {}
        local libCount = (libVarsByType and libVarsByType[typeId] and #libVarsByType[typeId]) or 0
        typeTotalCount[typeId] = #userVars + libCount
        -- 卡牌专属固定变量计数（每张卡牌固有，按编辑期展示集合）
        typeTotalCount[typeId] = typeTotalCount[typeId] + #GetEditingFixedVars(typeId)
        -- eg 子类型（对象组）计数计入 e 类型
        if typeId == "e" and libVarsByType and libVarsByType["eg"] then
            typeTotalCount[typeId] = typeTotalCount[typeId] + #libVarsByType["eg"]
        end
        -- 加入该类型的函数参数
        if editor._funcParams then
            for _, param in ipairs(editor._funcParams) do
                if param.type == typeId then
                    typeTotalCount[typeId] = typeTotalCount[typeId] + 1
                end
            end
        end
        -- 当前卡牌将作为独立分类计数，不计入 e 类型
    end

    -- 预计算内容总高度（用于滚动）
    local totalContentHeight = 0
    for _, dataType in ipairs(sortedTypes) do
        local typeId = dataType.id
        totalContentHeight = totalContentHeight + rowH
        local isExpanded = editor.expandedVarTypes[typeId]
        if isExpanded then
            local searchH = 0
            if typeTotalCount[typeId] > 7 then
                searchH = 22  -- 搜索框高度
            end
            totalContentHeight = totalContentHeight + searchH
            -- 函数参数高度
            if editor._funcParams then
                local typeParamCount = 0
                for _, param in ipairs(editor._funcParams) do
                    if param.type == typeId then
                        typeParamCount = typeParamCount + 1
                    end
                end
                if typeParamCount > 0 then
                    totalContentHeight = totalContentHeight + 6 + typeParamCount * 20
                end
            end
            local vars = editor.variables[typeId] or {}
            totalContentHeight = totalContentHeight + math.max(#vars, 1) * 20 + 2
            -- 卡牌专属固定变量高度（小组标题 + 条目行）
            local fixedVarsH = #GetEditingFixedVars(typeId)
            if fixedVarsH > 0 then
                totalContentHeight = totalContentHeight + 6 + fixedVarsH * 20 + 2
            end
            if libVarsByType and libVarsByType[typeId] and #libVarsByType[typeId] > 0 then
                totalContentHeight = totalContentHeight + 4 + #libVarsByType[typeId] * 20
            end
            -- eg 子类型（对象组）显示在 e 分类下
            if typeId == "e" and libVarsByType and libVarsByType["eg"] and #libVarsByType["eg"] > 0 then
                totalContentHeight = totalContentHeight + 4 + #libVarsByType["eg"] * 20
            end
        end
    end
    -- "当前卡牌"条目高度
    totalContentHeight = totalContentHeight + 20 + 2

    -- 滚动限制与裁剪
    local listClipH = sH - (editor._allVarMode and 40 or 0)
    local maxScroll = math.max(0, totalContentHeight - listClipH)
    editor.varScrollOffset = math.Clamp(editor.varScrollOffset, 0, maxScroll)
    render.SetScissorRect(sX, sY, sX + sW, sY + listClipH, true)

    local y = sY - editor.varScrollOffset

    for _, dataType in ipairs(sortedTypes) do
        local typeId = dataType.id
        local typeName = dataType.name
        local vars = editor.variables[typeId] or {}
        local totalCount = typeTotalCount[typeId]
        local searchText = editor._varSearchText[typeId] or ""

        -- 可见性检测
        local headerEnd = y + rowH
        if headerEnd >= sY and y <= sY + listClipH then
            -- 类型标题行
            draw.RoundedBox(4, sX + 2, y, sW - 4, rowH, Color(50, 50, 55))
            INE.DrawDataTypeIcon(dataType, sX + padL + 6, y + rowH / 2, iconSize)
            draw.SimpleText(typeName, "SourceHan_Heavy_12", sX + padL + iconSize + 12, y + rowH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            -- 计数含变量库变量
            draw.SimpleText("(" .. totalCount .. ")", "SourceHan_Heavy_12", sX + padL + iconSize + 12 + 50, y + rowH / 2, Color(140, 140, 140), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

            -- [+] 新增按钮
            local addBX = sX + sW - 18 - 18 - 2
            local addHov = mx >= addBX and mx <= addBX + btnSize and my >= y + 3 and my <= y + rowH - 3
            draw.RoundedBox(4, addBX, y + 3, btnSize, rowH - 6, addHov and Color(70, 120, 70) or Color(60, 60, 65))
            draw.SimpleText("+", "SourceHan_Heavy_12", addBX + btnSize / 2, y + rowH / 2, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

            -- [▲/▼] 展开/收拢按钮
            local expBX = sX + sW - 18
            local expHov = mx >= expBX and mx <= expBX + btnSize and my >= y + 3 and my <= y + rowH - 3
            local isExpanded = editor.expandedVarTypes[typeId]
            draw.RoundedBox(4, expBX, y + 3, btnSize, rowH - 6, expHov and Color(75, 75, 85) or Color(60, 60, 65))
            draw.SimpleText(isExpanded and "▼" or "▲", "SourceHan_Heavy_12", expBX + btnSize / 2, y + rowH / 2, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

            editor._interactiveRects["var_add_" .. typeId] = {x = addBX, y = y + 3, w = btnSize, h = rowH - 6}
            editor._interactiveRects["var_exp_" .. typeId] = {x = expBX, y = y + 3, w = btnSize, h = rowH - 6}
            editor._interactiveRects["var_header_" .. typeId] = {x = sX, y = y, w = sW, h = rowH}
        end

        y = y + rowH

        local isExpanded = editor.expandedVarTypes[typeId]
        if isExpanded then
            -- 搜索框（总数 > 7 时显示）
            if totalCount > 7 then
                local searchH = 22
                if y >= sY and y <= sY + listClipH then
                    local searchBX = sX + 6
                    local searchBW = sW - 12
                    local isActiveSearch = editor._varSearchActiveType == typeId

                    -- 背景
                    if isActiveSearch then
                        draw.RoundedBox(4, searchBX, y, searchBW, searchH, Color(60, 60, 70))
                        surface.SetDrawColor(Color(100, 150, 255, 200))
                        surface.DrawOutlinedRect(searchBX, y, searchBW, searchH)
                    else
                        draw.RoundedBox(4, searchBX, y, searchBW, searchH, Color(40, 40, 40))
                    end

                    -- 文本
                    local font = "SourceHan_Heavy_12"
                    if searchText ~= "" then
                        draw.SimpleText(searchText, font, searchBX + 8, y + searchH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    else
                        draw.SimpleText(T("editor.globalvar.search_placeholder"), font, searchBX + 8, y + searchH / 2,
                            isActiveSearch and Color(180, 180, 180) or Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    end

                    -- 光标（激活时闪烁）
                    if isActiveSearch and math.floor(SysTime() * 2) % 2 == 0 then
                        surface.SetFont(font)
                        local cursorX = searchBX + 8 + surface.GetTextSize(searchText)
                        surface.SetDrawColor(Color(200, 200, 200))
                        surface.DrawLine(cursorX, y + 3, cursorX, y + searchH - 3)
                    end

                    -- 点击检测（使用帧追踪）
                    INE._prevMouseLeft = INE._prevMouseLeft ~= nil and INE._prevMouseLeft or false
                    local isLeftPressed = input.IsMouseDown(MOUSE_LEFT) and not INE._prevMouseLeft
                    INE._prevMouseLeft = input.IsMouseDown(MOUSE_LEFT)
                    local mx2, my2 = gui.MousePos()

                    if isLeftPressed then
                         local inRect = mx2 >= searchBX and mx2 <= searchBX + searchBW and my2 >= y and my2 <= y + searchH
                         if inRect then
                             -- 激活此搜索框
                             editor._varSearchActiveType = typeId
                             INE:Field(editor, "VarSearch").active = true
                             INE:Field(editor, "VarSearch").text = searchText
                             INE:Field(editor, "VarSearch").editorID = editor.panelID or editor.id
                             INE:Field(editor, "VarSearch").typeId = typeId
                             INE:Field(editor, "VarSearch").x = searchBX
                             INE:Field(editor, "VarSearch").y = y
                             INE:Field(editor, "VarSearch").w = searchBW
                             INE:Field(editor, "VarSearch").h = searchH
                         elseif isActiveSearch then
                             -- 点击当前激活搜索框外部 → 取消激活
                             editor._varSearchActiveType = nil
                             INE:Field(editor, "VarSearch").active = false
                         end
                    end
                end
                y = y + searchH + 2
            end



            -- 函数参数（按数据类型分类显示在该类型中）
            if editor._funcParams then
                local typeParams = {}
                for _, param in ipairs(editor._funcParams) do
                    if param.type == typeId then
                        table.insert(typeParams, param)
                    end
                end
                if #typeParams > 0 then
                    -- 建立类型ID→DataTypes的反查表（一次性）
                    local idToDt = {}
                    for _, dt in pairs(INE.DataTypes) do
                        idToDt[dt.id] = dt
                    end
                    -- 参数标题
                    if y >= sY and y <= sY + listClipH then
                        draw.SimpleText(T("editor.globalvar.param_section"), "SourceHan_Heavy_10", sX + padL + 16, y + 4, Color(140, 140, 160), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
                    end
                    y = y + 6
                    for pi, param in ipairs(typeParams) do
                        local paramH = 20
                        local itemKey = "param_item_" .. typeId .. "_" .. pi
                        local isParamSelected = (editor._selectedVarItem == itemKey)
                        if y + paramH >= sY and y <= sY + listClipH then
                            if isParamSelected then
                                draw.RoundedBox(4, sX + 6, y, sW - 12, paramH, Color(60, 70, 90))
                            else
                                draw.RoundedBox(4, sX + 6, y, sW - 12, paramH, Color(45, 45, 55))
                            end
                            surface.SetDrawColor(Color(255, 255, 255, 8))
                            surface.DrawOutlinedRect(sX + 6, y, sW - 12, paramH)
                            -- 类型图标
                            local dt = idToDt[param.type] or idToDt["n"]
                            INE.DrawDataTypeIcon(dt, sX + padL + 20, y + paramH / 2, 10)
                            -- 参数名
                            draw.SimpleText(param.name or "", "SourceHan_Heavy_12", sX + padL + 34, y + paramH / 2, Color(160, 160, 180), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                            draw.SimpleText(T("editor.globalvar.param_tag"), "SourceHan_Heavy_10", sX + padL + 34 + 130, y + paramH / 2, Color(100, 100, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                        end
                        -- 注册交互区域（支持点击选中）
                        editor._interactiveRects[itemKey] = {x = sX + 4, y = y, w = sW - 8, h = paramH, paramIndex = pi, paramType = typeId, paramName = param.name}
                        y = y + paramH
                    end
                    y = y + 2
                end
            end

            -- 用户自定义变量（支持搜索过滤）
            if #vars == 0 then
                if y >= sY and y <= sY + listClipH then
                    draw.SimpleText(T("editor.globalvar.no_variables"), "SourceHan_Heavy_12", sX + sW / 2, y + 10, Color(120, 120, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                end
                y = y + 20
            else
                for vi, var in ipairs(vars) do
                    local varH = 20
                    -- 搜索过滤（不匹配的跳过绘制但保持 y 推进）
                    local matched = true
                    if searchText ~= "" then
                        local matchName = var.name and var.name:lower():find(searchText:lower())
                        local matchIname = var.internalName and var.internalName:lower():find(searchText:lower())
                        matched = matchName or matchIname
                    end

                    if matched then
                        local itemKey = "var_item_" .. typeId .. "_" .. vi
                        local isSelected = (editor._selectedVarItem == itemKey)

                        if y + varH >= sY and y <= sY + listClipH then
                            local varHov = mx >= sX + 4 and mx <= sX + sW - 4 and my >= y and my <= y + varH

                            if varHov then
                                currentHoverKey = itemKey
                                currentHoverData = {
                                    isDefault = false,
                                    y = y,
                                    h = varH,
                                    typeId = typeId,
                                    name = var.name or "",
                                    internalName = (typeId == "n" and var.internalName and not var.internalName:match("^n_var_")) and var.internalName
                                        or (typeId == "e" and (var.internalName or "")) or nil,
                                    initialValue = var.initialValue,
                                    scope = var.scope or "global",
                                    -- 卡牌对象额外数据
                                    cardMode = (typeId == "e") and (var._mode or "empty") or nil,
                                    cardName = (typeId == "e") and var.cardName or nil,
                                    cardFile = (typeId == "e") and var.cardFile or nil,
                                    cardAppearance = (typeId == "e") and var.cardAppearance or nil,
                                }
                            end

                            if isSelected then
                                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(60, 70, 90))
                            elseif varHov then
                                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(55, 55, 60))
                            end

                            local nameColor = (var.scope == "longterm") and Color(255, 200, 80) or Color(220, 220, 220)
                            INE.DrawDataTypeIcon(dataType, sX + padL + 16, y + varH / 2, 8)

                            if typeId == "n" and var.internalName and not var.internalName:match("^n_var_") then
                                draw.SimpleText(var.name, "SourceHan_Heavy_12", sX + padL + 30, y + varH / 2, nameColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                                draw.SimpleText(var.internalName, "SourceHan_Heavy_10", sX + padL + 30 + 100, y + varH / 2, Color(130, 130, 130), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                            elseif typeId == "e" then
                                -- 卡牌对象变量：显示模式/卡牌名预览
                                local cardPreview = ""
                                local mode = var._mode or "empty"
                                if mode == "empty" then
                                    cardPreview = T("editor.globalvar.empty_object_bracketed")
                                elseif mode == "saved" and var.cardName and var.cardName ~= "" then
                                    cardPreview = " [" .. var.cardName .. "]"
                                elseif mode == "saved" and var.cardFile then
                                    cardPreview = " [" .. var.cardFile:gsub("%.json$", "") .. "]"
                                end
                                draw.SimpleText(var.name .. cardPreview, "SourceHan_Heavy_12", sX + padL + 30, y + varH / 2, nameColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                                if var.internalName and var.internalName ~= "" then
                                    draw.SimpleText(var.internalName, "SourceHan_Heavy_10", sX + padL + 30 + 160, y + varH / 2, Color(130, 130, 130), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                                end
                            else
                                draw.SimpleText(var.name, "SourceHan_Heavy_12", sX + padL + 30, y + varH / 2, nameColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                            end

                            editor._interactiveRects[itemKey] = {x = sX + 4, y = y, w = sW - 8, h = varH, varIndex = vi, varType = typeId, varName = var.name}
                        end
                    end
                    y = y + varH
                end
            end

            -- 卡牌专属固定变量（每张卡牌固有，不可编辑不可删除；悬停显示当前值）
            local fixedVars = GetEditingFixedVars(typeId)
            if #fixedVars > 0 then
                if y >= sY and y <= sY + listClipH then
                    draw.SimpleText(T("editor.globalvar.card_specific_section"), "SourceHan_Heavy_10", sX + padL + 16, y + 4, Color(140, 140, 160), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
                end
                y = y + 6
                for fi, fv in ipairs(fixedVars) do
                    local varH = 20
                    local itemKey = "var_item_fixed_" .. typeId .. "_" .. fi
                    local isSelected = (editor._selectedVarItem == itemKey)

                    if y + varH >= sY and y <= sY + listClipH then
                        local varHov = mx >= sX + 4 and mx <= sX + sW - 4 and my >= y and my <= y + varH

                        if varHov then
                            currentHoverKey = itemKey
                            currentHoverData = {
                                isDefault = false, isFixed = true,
                                y = y, h = varH,
                                typeId = typeId,
                                name = fv.name or "",
                                internalName = fv.key or "",
                                initialValue = GetEditingFixedVarValue(fv),
                                scope = "global",
                                -- e 类型（自身）：预览显示当前卡牌
                                cardMode = (typeId == "e") and "saved" or nil,
                                cardName = (typeId == "e") and T("editor.globalvar.current_card") or nil,
                                cardAppearance = (typeId == "e") and KARDS.CardEditor.Canvas.CardAppearance or nil,
                            }
                        end

                        if isSelected then
                            draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(60, 70, 90))
                        elseif varHov then
                            draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(55, 55, 60))
                        end

                        INE.DrawDataTypeIcon(dataType, sX + padL + 16, y + varH / 2, 8)
                        draw.SimpleText(fv.name, "SourceHan_Heavy_12", sX + padL + 30, y + varH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                        draw.SimpleText(T("editor.globalvar.card_specific"), "SourceHan_Heavy_10", sX + padL + 30 + 100, y + varH / 2, Color(120, 160, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    end

                    editor._interactiveRects[itemKey] = {x = sX + 4, y = y, w = sW - 8, h = varH, varType = typeId, varName = fv.name, isFixed = true}
                    y = y + varH
                end
                y = y + 2
            end

            -- 全变量模式：在该类型下追加变量库中的同类型变量（支持搜索过滤）
            if libVarsByType and libVarsByType[typeId] and #libVarsByType[typeId] > 0 then
                local libVars = libVarsByType[typeId]
                y = y + 2
                for _, libVar in ipairs(libVars) do
                    local varH = 20
                    -- 搜索过滤（不匹配的跳过绘制但保持 y 推进）
                    local matched = true
                    if searchText ~= "" then
                        local matchName = libVar.name and libVar.name:lower():find(searchText:lower())
                        local matchKey = libVar.key and libVar.key:lower():find(searchText:lower())
                        matched = matchName or matchKey
                    end

                    if matched then
                        local itemKey = "lib_var_" .. libVar.path
                        local isSelected = (editor._selectedVarItem == itemKey)

                        if y + varH >= sY and y <= sY + listClipH then
                            local varHov = mx >= sX + 4 and mx <= sX + sW - 4 and my >= y and my <= y + varH

                            if varHov then
                                currentHoverKey = itemKey
                                currentHoverData = {
                                    isDefault = true,
                                    y = y,
                                    h = varH,
                                    typeId = typeId,
                                    name = libVar.name or "",
                                    internalName = libVar.key or "",
                                    initialValue = nil,
                                }
                            end

                            if isSelected then
                                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(60, 70, 90))
                            elseif varHov then
                                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(50, 50, 55))
                            else
                                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(45, 45, 50))
                            end

                            surface.SetDrawColor(Color(255, 255, 255, 20))
                            for sl = 0, sW, 20 do
                                surface.DrawLine(sX + sl, y, sX + sl + 20, y + varH)
                            end

                            local dt = INE.DataTypes[libVar.type or typeId]
                            if dt then INE.DrawDataTypeIcon(dt, sX + padL + 16, y + varH / 2, 8) end

                            draw.SimpleText(libVar.name, "SourceHan_Heavy_12", sX + padL + 30, y + varH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                            draw.SimpleText(libVar.key, "SourceHan_Heavy_10", sX + padL + 30 + 120, y + varH / 2, Color(130, 130, 130), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

                            editor._interactiveRects[itemKey] = {x = sX + 4, y = y, w = sW - 8, h = varH, path = libVar.path, varName = libVar.name, varType = typeId, isDefault = true}
                        end
                    end
                    y = y + varH
                end
            end

            -- eg（对象组）子类型：显示在 e 分类下
            if typeId == "e" and libVarsByType and libVarsByType["eg"] and #libVarsByType["eg"] > 0 then
                local egVars = libVarsByType["eg"]
                local egDt = {color = dataType.color, shape = "eg_hex_square"}
                y = y + 2
                for _, libVar in ipairs(egVars) do
                    local varH = 20
                    local matched = true
                    if searchText ~= "" then
                        local matchName = libVar.name and libVar.name:lower():find(searchText:lower())
                        local matchKey = libVar.key and libVar.key:lower():find(searchText:lower())
                        matched = matchName or matchKey
                    end

                    if matched then
                        local itemKey = "lib_var_" .. libVar.path
                        local isSelected = (editor._selectedVarItem == itemKey)

                        if y + varH >= sY and y <= sY + listClipH then
                            local varHov = mx >= sX + 4 and mx <= sX + sW - 4 and my >= y and my <= y + varH

                            if isSelected then
                                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(60, 70, 90))
                            elseif varHov then
                                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(50, 50, 55))
                            else
                                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(45, 45, 50))
                            end

                            surface.SetDrawColor(Color(255, 255, 255, 20))
                            for sl = 0, sW, 20 do
                                surface.DrawLine(sX + sl, y, sX + sl + 20, y + varH)
                            end

                            INE.DrawDataTypeIcon(egDt, sX + padL + 16, y + varH / 2, 8)

                            draw.SimpleText(libVar.name, "SourceHan_Heavy_12", sX + padL + 30, y + varH / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                            draw.SimpleText(libVar.key, "SourceHan_Heavy_10", sX + padL + 30 + 120, y + varH / 2, Color(130, 130, 130), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

                            editor._interactiveRects[itemKey] = {x = sX + 4, y = y, w = sW - 8, h = varH, path = libVar.path, varName = libVar.name, varType = "eg", isDefault = true}
                        end
                    end
                    y = y + varH
                end
            end

            y = y + 2
        end
    end

    -- ============================================================
    -- 内置对象变量：当前卡牌（直接绘制为变量选项，无标题行）
    -- ============================================================
    do
        local varH = 20
        local currentCardName = (KARDS.CardEditor.Canvas.CardAppearance and KARDS.CardEditor.Canvas.CardAppearance.name) or T("editor.globalvar.new_card")
        local itemKey = "var_item_e_currentCard"
        local isSelected = (editor._selectedVarItem == itemKey)

        if y + varH >= sY and y <= sY + listClipH then
            local varHov = mx >= sX + 4 and mx <= sX + sW - 4 and my >= y and my <= y + varH

            if varHov then
                currentHoverKey = itemKey
                currentHoverData = {
                    isDefault = false,
                    y = y,
                    h = varH,
                    typeId = "e",
                    name = T("editor.globalvar.current_card"),
                    internalName = currentCardName,
                    initialValue = nil,
                    cardMode = "saved",
                    cardName = currentCardName,
                    cardFile = nil,
                    cardAppearance = KARDS.CardEditor.Canvas.CardAppearance,
                }
            end

            if isSelected then
                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(60, 70, 90))
            elseif varHov then
                draw.RoundedBox(4, sX + 6, y, sW - 12, varH, Color(55, 55, 60))
            end

            local eDataType = INE.DataTypes["e"]
            if eDataType then
                INE.DrawDataTypeIcon(eDataType, sX + padL + 16, y + varH / 2, 8)
            end

            draw.SimpleText(T("editor.globalvar.current_card"), "SourceHan_Heavy_12", sX + padL + 30, y + varH / 2, Color(220, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            draw.SimpleText("[" .. currentCardName .. "]", "SourceHan_Heavy_10", sX + padL + 30 + 100, y + varH / 2, Color(130, 130, 130), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

            editor._interactiveRects[itemKey] = {x = sX + 4, y = y, w = sW - 8, h = varH, varType = "e", varName = currentCardName, isCurrentCard = true}
        end
        y = y + varH + 2
    end

    render.SetScissorRect(0, 0, 0, 0, false)

    -- 全变量模式底部按钮（固定面板底部，不受滚动影响）
    if editor._allVarMode then
        local btnY = sY + sH - 35
        local btnW = (sW - 40) / 2
        local defaultHov = mx >= sX + 6 and mx <= sX + 6 + btnW and my >= btnY and my <= btnY + 28
        local undefaultHov = mx >= sX + sW - 6 - btnW and mx <= sX + sW - 6 and my >= btnY and my <= btnY + 28
        draw.RoundedBox(6, sX + 6, btnY, btnW, 28, defaultHov and Color(70, 100, 70) or Color(55, 65, 55))
        draw.SimpleText(T("editor.globalvar.set_default"), "SourceHan_Heavy_12", sX + 6 + btnW/2, btnY + 14, Color(200, 255, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.RoundedBox(6, sX + sW - 6 - btnW, btnY, btnW, 28, undefaultHov and Color(100, 60, 60) or Color(65, 55, 55))
        draw.SimpleText(T("editor.globalvar.unset_default"), "SourceHan_Heavy_12", sX + sW - 6 - btnW/2, btnY + 14, Color(255, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        editor._interactiveRects["lib_set_default"] = {x = sX + 6, y = btnY, w = btnW, h = 28}
        editor._interactiveRects["lib_unset_default"] = {x = sX + sW - 6 - btnW, y = btnY, w = btnW, h = 28}
    end

    -- ============================================================
    -- 变量悬停预览：鼠标悬停在变量上一段时间后，在右侧淡入预览矩形
    -- ============================================================
    local preview = editor._varHoverPreview
    if currentHoverKey then
        if currentHoverKey == preview.hoverKey then
            -- 同一变量：检查悬停时长
            local elapsed = SysTime() - preview.hoverStart
            if elapsed > 0.6 then
                -- 超过悬停延迟，淡入（0.3秒从0到255）
                local fadeDuration = 0.3
                local fadeElapsed = math.min(elapsed - 0.6, fadeDuration)
                preview.alpha = math.Clamp((fadeElapsed / fadeDuration) * 255, 0, 255)

                -- 准备预览数据
                local hoverY = currentHoverData.y
                local rowH2 = 18
                local rowGap = 2
                local numRows = 4
                if currentHoverData.isDefault then numRows = 5 end

                -- 函数类型变量：生成内容描述
                local isFuncType = currentHoverData.typeId == "f"
                local functionDesc = nil
                if isFuncType then
                    local savedFuncData = editor._savedFunctionData and editor._savedFunctionData[currentHoverData.name]
                    if savedFuncData then
                        local ok, desc = pcall(INE.GenerateFunctionDescription, INE, savedFuncData)
                        if ok and desc then
                            functionDesc = desc
                        end
                    end
                    functionDesc = functionDesc or "—"
                end

                local pad = 8
                local previewW = 200

                -- 函数类型：根据描述文字宽度自动扩展预览框
                if isFuncType and functionDesc and functionDesc ~= "—" then
                    surface.SetFont("SourceHan_Heavy_12")
                    local tw, _ = surface.GetTextSize(functionDesc)
                    local neededWidth = tw + 45 + pad * 2 + 10  -- 45为标签宽度，10为余量
                    previewW = math.max(previewW, math.min(neededWidth, 400))
                end

                -- 卡牌对象：预留卡牌预览图空间（渐变完成后显示）
                local showCardPreview = currentHoverData.typeId == "e" and currentHoverData.cardAppearance ~= nil
                local cardPreviewH = 0
                local cardPreviewW = 0
                if showCardPreview then
                    local refH = math.floor((KARDS.CardEditor.Canvas.TotalEditorH or 720) / 3)
                    cardPreviewH = refH
                    cardPreviewW = math.floor(cardPreviewH * 3 / 4)
                    previewW = math.max(previewW, cardPreviewW + pad * 2)
                end

                local previewH = numRows * rowH2 + (numRows - 1) * rowGap + pad * 2
                if showCardPreview then
                    previewH = previewH + 6 + cardPreviewH + 4  -- 间隔 + 预览图高度 + 底部边距
                end
                local previewX = sX + sW + 8
                local previewY = math.Clamp(hoverY, sY + 10, sY + sH - previewH - 10)

                -- 确保不超出编辑器右边界
                local editorRight = (editor.x or 0) + (editor.width or sX + sW + 300)
                if previewX + previewW > editorRight then
                    previewX = editorRight - previewW - 8
                end
                -- 如果超出编辑器右边界，改到左侧显示
                if previewX + previewW > ScrW() then
                    previewX = sX - previewW - 8
                end
                -- 如果左侧也不够，仍在右侧显示但截断
                if previewX < 0 then previewX = sX + sW + 4 end

                -- 背景半透明框
                local alpha = math.floor(preview.alpha)
                draw.RoundedBox(6, previewX, previewY, previewW, previewH,
                    Color(35, 35, 45, math.min(alpha + 80, 235)))
                surface.SetDrawColor(Color(80, 80, 100, alpha))
                surface.DrawOutlinedRect(previewX, previewY, previewW, previewH)

                local contentX = previewX + pad
                local contentY = previewY + pad
                local labelColor = Color(180, 180, 180, alpha)
                local valueColor = Color(220, 220, 220, alpha)

                -- 第1行：名称
                draw.SimpleText(T("editor.globalvar.preview_name_label"), "SourceHan_Heavy_12", contentX, contentY + rowH2 / 2,
                    labelColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                draw.SimpleText(currentHoverData.name, "SourceHan_Heavy_12", contentX + 45, contentY + rowH2 / 2,
                    valueColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                contentY = contentY + rowH2 + rowGap

                -- 第2行：内部名
                local iname = currentHoverData.internalName or "—"
                draw.SimpleText(T("editor.globalvar.preview_internal_name_label"), "SourceHan_Heavy_12", contentX, contentY + rowH2 / 2,
                    labelColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                draw.SimpleText(iname, "SourceHan_Heavy_12", contentX + 45, contentY + rowH2 / 2,
                    valueColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                contentY = contentY + rowH2 + rowGap

                if isFuncType then
                    -- 第3行（函数类型）：内容描述
                    draw.SimpleText(T("editor.globalvar.preview_description_label"), "SourceHan_Heavy_12", contentX, contentY + rowH2 / 2,
                        labelColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    draw.SimpleText(functionDesc or "—", "SourceHan_Heavy_12", contentX + 45, contentY + rowH2 / 2,
                        valueColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                elseif currentHoverData.typeId == "e" then
                    -- 第3行（卡牌对象）：卡牌值
                    local cardMode = currentHoverData.cardMode or "empty"
                    local cardValText = "—"
                    if cardMode == "empty" then
                        cardValText = T("editor.globalvar.empty_object")
                    elseif currentHoverData.cardName and currentHoverData.cardName ~= "" then
                        cardValText = currentHoverData.cardName
                    elseif currentHoverData.cardFile then
                        cardValText = currentHoverData.cardFile:gsub("%.json$", "")
                    end
                    draw.SimpleText(T("editor.globalvar.preview_card_value_label"), "SourceHan_Heavy_12", contentX, contentY + rowH2 / 2,
                        labelColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    draw.SimpleText(cardValText, "SourceHan_Heavy_12", contentX + 45, contentY + rowH2 / 2,
                        valueColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                else
                    -- 第3行（普通类型）：初始值
                    local initVal = currentHoverData.initialValue
                    if initVal == nil then
                        -- 对于非数字变量，尝试从描述取初始值占位
                        local vars = editor.variables[currentHoverData.typeId] or {}
                        for _, v in ipairs(vars) do
                            if v.name == currentHoverData.name and v.initialValue ~= nil then
                                initVal = v.initialValue
                                break
                            end
                        end
                    end
                    local valText = (initVal ~= nil) and tostring(initVal) or "—"
                    draw.SimpleText(T("editor.globalvar.preview_initial_value_label"), "SourceHan_Heavy_12", contentX, contentY + rowH2 / 2,
                        labelColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    draw.SimpleText(valText, "SourceHan_Heavy_12", contentX + 45, contentY + rowH2 / 2,
                        valueColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                end
                contentY = contentY + rowH2 + rowGap

                -- 第4行：变量类型（全局/长期）
                local scopeLabel = (currentHoverData.scope == "longterm") and T("editor.globalvar.longterm_variable") or T("editor.globalvar.global_variable")
                local scopeColor = (currentHoverData.scope == "longterm") and Color(255, 200, 120, alpha) or Color(150, 200, 255, alpha)
                draw.SimpleText(T("editor.globalvar.preview_variable_type_label"), "SourceHan_Heavy_12", contentX, contentY + rowH2 / 2,
                    labelColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                draw.SimpleText(scopeLabel, "SourceHan_Heavy_12", contentX + 45, contentY + rowH2 / 2,
                    scopeColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                contentY = contentY + rowH2 + rowGap

                -- 第5行（仅默认变量）：不可修改
                if currentHoverData.isDefault then
                    draw.SimpleText(T("editor.globalvar.not_modifiable"), "SourceHan_Heavy_12", contentX, contentY + rowH2 / 2,
                        Color(255, 100, 100, alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                end

                -- 卡牌预览图（卡牌对象变量，在信息框底部绘制）
                if showCardPreview then
                    local cpX = previewX + previewW / 2 - cardPreviewW / 2
                    local cpY = contentY + 6
                    local ok, err = pcall(function()
                        KARDS.CardEditor.Canvas.DrawCardPreview(
                            currentHoverData.cardAppearance,
                            cpX, cpY,
                            cardPreviewW, cardPreviewH,
                            false, false, false)
                    end)
                    if not ok then
                        draw.SimpleText(T("editor.globalvar.preview_failed"), "SourceHan_Heavy_12", cpX + cardPreviewW/2, cpY + cardPreviewH/2,
                            Color(255, 80, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    end
                end
            else
                -- 未达到悬停延迟，逐渐降低 alpha
                preview.alpha = math.max(preview.alpha - 8, 0)
            end
        else
            -- 悬停到不同变量，重置计时
            preview.hoverKey = currentHoverKey
            preview.hoverStart = SysTime()
            preview.alpha = 0
            preview.hoverData = currentHoverData
        end
    else
        -- 未悬停任何变量，逐渐淡出
        if preview.alpha > 0 then
            preview.alpha = math.max(preview.alpha - 8, 0)
            -- 如果 alpha 变为 0，清除 hoverKey
            if preview.alpha <= 0 then
                preview.hoverKey = nil
                preview.hoverStart = 0
                preview.hoverData = nil
            end
        else
            preview.hoverKey = nil
            preview.hoverStart = 0
            preview.hoverData = nil
        end
    end
end