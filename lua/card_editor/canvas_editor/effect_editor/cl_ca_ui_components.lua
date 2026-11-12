--[[
=======================================================================================
UI 组件模块 (UI Components)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的 UI 组件模块，负责通用 UI 控件的绘制和交互。

包含功能：
  - DrawNumberBox（数字框/数字槽绘制）
  - DrawComparison（比较组件绘制）
  - DrawDropdown / DrawExpandedDropdowns（下拉框绘制）
  - DrawMultiDropdown / DrawExpandedMultiDropdowns（多选下拉框绘制）
  - CloseAllDropdowns / CloseAllMultiDropdowns（下拉框关闭）
  - HandleDropdownClickOutside / HandleMultiDropdownClickOutside（外部点击检测）
  - DrawConnections / DrawConnection / DrawTempNode / DrawTempConnection（连线绘制）
  - BezierCurve / GetCurveNormals / DrawThickCurve（曲线工具）
  - IsMouseNearCurve / PointToLineDistance（碰撞检测工具）

全局样式：
  - DropdownStyle（行 3399~3411）

状态数据：
  - ExpandedDropdown / ExpandedDropdownInfo（已迁入 editor.session，见 ADR 0003）
  - ExpandedMultiDropdown / ExpandedMultiDropdownInfo（已迁入 editor.session，见 ADR 0003）
  - LastMouseState（行 4198）

源文件：cl_canvas_editor.lua
  - 全局样式：行 3399~3411
  - 状态数据：行 3413~3414、3740~3742、4198
  - 功能函数：行 2815~4196
=======================================================================================
]]

-- 防御性命名空间初始化：确保即使本文件在 GMod 自动加载阶段先于
-- sh_card_editor_loader.lua 被加载，KARDS.CardEditor.Canvas 也已就绪
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

function KARDS.CardEditor.Canvas.DrawNumberBox(x, y, size, value, node, numberId, options, canvasFont)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    -- 确保节点有data字段
    node.data = node.data or {}
    node.data.numbers = node.data.numbers or {}
    
    -- 确保数字数据存在
    if not node.data.numbers[numberId] then
        node.data.numbers[numberId] = {
            value = value or 0,
            lastUpClickTime = 0,
            lastDownClickTime = 0,
            mode = "slot",  -- "slot" | "select"
            slotOptions = options,  -- 数字槽选项列表（如有）
            selectedOptionIndex = nil,  -- 当前选中的选项索引
            showVarPopup = false,  -- 是否显示变量选择弹窗
            slotToggleTime = 0,  -- 模式切换防抖
            dropdownExpandTime = 0,  -- 下拉框展开防抖
            lastArrowClickTime = 0,  -- 箭头点击防抖
        }
    else
        -- 确保所有必须字段存在（兼容旧数据）
        local numData = node.data.numbers[numberId]
        if numData.dropdownExpandTime == nil then numData.dropdownExpandTime = 0 end
        if numData.slotToggleTime == nil then numData.slotToggleTime = 0 end
        if numData.lastArrowClickTime == nil then numData.lastArrowClickTime = 0 end
        if numData.mode == nil then numData.mode = "slot" end
        if numData.slotOptions == nil then numData.slotOptions = options end
    end
    
    local numberData = node.data.numbers[numberId]
    -- 浮层状态归属：NodeBase 旧节点没有编辑器会话，此时跳过状态写入（旧渲染路径已弃用）
    local session = node.editor and node.editor.session
    local currentValue = numberData.value
    local currentTime = SysTime()
    
    -- 限制值范围
    currentValue = math.max(0, math.min(99, currentValue))
    numberData.value = currentValue
    
    -- 计算数字槽总宽（用于变量覆盖层的点击/绘制区域）
    local hasOptions = options and #options > 0
    local slotTotalW = size  -- 无选项时只有数字框宽度
    if hasOptions then
        slotTotalW = size + 3 + (size / 2 - 3)  -- 槽模式：数字框 + 间隙 + 箭头区
    end

    -- 检测全局变量页面中是否有选中数字变量，若有则在数字槽上绘制覆盖层
    local overlayClicked = false
    local isNumVarSelected = false
    local varName = nil
    local varValue = nil
    do
        local editor = node and node.editor
        if editor and editor._selectedVarItem then
            local selKey = editor._selectedVarItem
            if selKey:find("^var_item_n_") then
                -- 用户自定义数字变量："var_item_n_<index>"
                local vi = tonumber(selKey:match("^var_item_n_(%d+)$"))
                if vi then
                    local vars = editor.variables and editor.variables["n"]
                    local var = vars and vars[vi]
                    if var then
                        isNumVarSelected = true
                        varName = (var.internalName ~= nil and var.internalName ~= "") and var.internalName or var.name
                        varValue = var.initialValue or 0
                    end
                end
            elseif selKey:find("^lib_var_") then
                -- 变量库数字变量：通过 editor._selectedLibVar 获取类型和名称
                local libVar = editor._selectedLibVar
                if libVar and libVar.varType == "n" then
                    isNumVarSelected = true
                    varName = libVar.path
                    varValue = 0
                end
            elseif selKey:find("^param_item_n_") then
                -- 函数参数数字变量："param_item_n_<index>"
                local pi = tonumber(selKey:match("^param_item_n_(%d+)$"))
                if pi then
                    local params = editor._functionParams and editor._functionParams["n"]
                    local param = params and params[pi]
                    if param then
                        isNumVarSelected = true
                        varName = param.name
                        varValue = param.defaultValue or 0
                    end
                end
            end
        end
    end

    -- 若数字变量已选中，检测是否点击在数字槽覆盖层上
    if isNumVarSelected then
        -- 覆盖层区域覆盖整个数字槽（含箭头区/按钮区）
        local overlayAreaW = slotTotalW
        local isOverHovered = mouseX >= x and mouseX <= x + overlayAreaW and
                              mouseY >= y and mouseY <= y + size
        local mouseActive = input.IsMouseDown(MOUSE_LEFT) or input.WasMousePressed(MOUSE_LEFT)
        local editor = node and node.editor
        if mouseActive and isOverHovered and editor then
            overlayClicked = true
            -- 分配变量到数字槽
            if hasOptions then
                -- 切换到 select 模式（如果本就在 select 模式则保持）
                numberData.mode = "select"
                -- 在选项列表中查找变量
                local foundIdx = nil
                for idx, opt in ipairs(options) do
                    local displayOpt = opt
                    if KARDS.VarLib and KARDS.VarLib.GetDisplayName then
                        displayOpt = KARDS.VarLib.GetDisplayName(opt)
                    end
                    if displayOpt == varName or opt == varName then
                        foundIdx = idx
                        break
                    end
                end
                if foundIdx then
                    numberData.selectedOptionIndex = foundIdx
                elseif varName then
                    -- 若不在选项列表中则追加
                    table.insert(options, varName)
                    numberData.selectedOptionIndex = #options
                end
                numberData.value = varValue
                node.data[numberId] = varValue
            else
                -- 无选项：仅设置数值
                numberData.value = varValue
                node.data[numberId] = varValue
            end
            -- 取消选中全局变量
            editor._selectedVarItem = nil
            -- 如果变量选择弹窗打开了，关闭它
            if session and session.NumericVarPopup then
                session.NumericVarPopup = nil
            end
        end
        if not overlayClicked then
            -- 记录覆盖层悬停状态供绘制使用
            numberData._varOverlayHover = isOverHovered
        end
    else
        if numberData._varOverlayHover ~= nil then
            numberData._varOverlayHover = nil
        end
    end

    -- 如果没有选项或是 []（空括号），使用标准数字框
    if not options or #options == 0 then
        -- == 原始 DrawNumberBox 逻辑 ==
        -- 绘制数字框背景
        draw.RoundedBox(4, x, y, size, size, Color(60, 60, 60))
        
        -- 绘制数字
        local text = tostring(currentValue)
        local font = canvasFont or "SourceHan_Heavy_16"
        if not canvasFont and currentValue >= 10 then
            font = "SourceHan_Heavy_14"
        end
        draw.SimpleText(text, font, x + size / 2, y + size / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        
        -- 绘制上按钮（三角形）
        local upButtonX = x + size + 3
        local upButtonY = y + 3
        local buttonSize = size / 2 - 3
        
        -- 上按钮悬停检测
        local isUpHovered = mouseX >= upButtonX and mouseX <= upButtonX + buttonSize and
                            mouseY >= upButtonY and mouseY <= upButtonY + buttonSize
        
        -- 绘制上按钮
        surface.SetDrawColor(isUpHovered and Color(100, 150, 255, 200) or Color(100, 100, 100))
        surface.DrawLine(upButtonX + buttonSize / 2, upButtonY, upButtonX, upButtonY + buttonSize)
        surface.DrawLine(upButtonX + buttonSize / 2, upButtonY, upButtonX + buttonSize, upButtonY + buttonSize)
        surface.DrawLine(upButtonX, upButtonY + buttonSize, upButtonX + buttonSize, upButtonY + buttonSize)
        
        -- 绘制下按钮（三角形）
        local downButtonX = x + size + 3
        local downButtonY = y + size / 2 + 3
        
        -- 下按钮悬停检测
        local isDownHovered = mouseX >= downButtonX and mouseX <= downButtonX + buttonSize and
                              mouseY >= downButtonY and mouseY <= downButtonY + buttonSize
        
        -- 绘制下按钮
        surface.SetDrawColor(isDownHovered and Color(255, 100, 100, 200) or Color(100, 100, 100))
        surface.DrawLine(downButtonX, downButtonY, upButtonX + buttonSize, downButtonY)
        surface.DrawLine(downButtonX, downButtonY, upButtonX + buttonSize / 2, downButtonY + buttonSize)
        surface.DrawLine(upButtonX + buttonSize, downButtonY, upButtonX + buttonSize / 2, downButtonY + buttonSize)
        
        -- 上下箭头数值调整（同时使用 IsMouseDown + WasMousePressed 兜底，
        -- 确保无论鼠标状态在哪个钩子阶段消耗，点击均能正常触发）
        if not overlayClicked and not KARDS.CardEditor.Canvas.DraggingNode and currentTime - numberData.lastArrowClickTime > 0.3 then
            local mouseActive = input.IsMouseDown(MOUSE_LEFT) or input.WasMousePressed(MOUSE_LEFT)
            if mouseActive then
                local arrowClicked = false
                if isUpHovered then
                    if currentValue < 99 then
                        numberData.value = currentValue + 1
                    else
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.ui.number_max_notice"), Color(50, 50, 50), false)
                    end
                    arrowClicked = true
                elseif isDownHovered then
                    if currentValue > 0 then
                        numberData.value = currentValue - 1
                    else
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.ui.number_min_notice"), Color(50, 50, 50), false)
                    end
                    arrowClicked = true
                end
                if arrowClicked then
                    numberData.lastArrowClickTime = currentTime
                end
            end
        end

        -- 右键：同时使用 IsMouseDown + WasMousePressed 兜底
        if not overlayClicked and not KARDS.CardEditor.Canvas.DraggingNode and currentTime - numberData.lastArrowClickTime > 0.3 then
            local mouseActive = input.IsMouseDown(MOUSE_RIGHT) or input.WasMousePressed(MOUSE_RIGHT)
            if mouseActive then
                local arrowClicked = false
                if isUpHovered then
                    if currentValue < 99 then
                        numberData.value = math.min(99, currentValue + 5)
                    else
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.ui.number_max_notice"), Color(50, 50, 50), false)
                    end
                    arrowClicked = true
                elseif isDownHovered then
                    if currentValue > 0 then
                        numberData.value = math.max(0, currentValue - 5)
                    else
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.ui.number_min_notice"), Color(50, 50, 50), false)
                    end
                    arrowClicked = true
                end
                if arrowClicked then
                    numberData.lastArrowClickTime = currentTime
                end
            end
        end
        
        return numberData.value
    end
    
    -- == 以下为带选项的数字槽逻辑 ==
    
    -- 检查是否在 select 模式或显示变量弹窗
    if numberData.showVarPopup then
        -- 显示变量选择弹窗，弹窗自身处理绘制和交互
        -- 但数字框主体仍然需要绘制
    end
    
    if numberData.mode == "select" then
        -- ========== 选择模式：n | 选项列表 ==========
        local optFont = canvasFont or "SourceHan_Heavy_14"
        surface.SetFont(optFont)
        local charW = surface.GetTextSize("字")
        local nBtnW = charW * 1.5  -- "n" 按钮宽度
        local sepW = charW * 0.5  -- "|" 分隔符宽度
        local totalPrefixW = nBtnW + sepW

        -- 使用当前选中选项的文字宽度（而非所有选项最大宽度），
        -- 使切换选项时下拉框和节点宽度动态自适应。
        local selectedIdx = numberData.selectedOptionIndex or 1
        -- 空选项兜底：options 为空表时 selectedOpt 为 nil 会导致
        -- GetDisplayName(nil) 返回 nil 传入 surface.GetTextSize 崩溃
        local selectedOpt = options[selectedIdx] or options[1] or ""
        local displayOpt = selectedOpt
        if KARDS.VarLib and KARDS.VarLib.GetDisplayName then
            displayOpt = KARDS.VarLib.GetDisplayName(selectedOpt)
        end
        local selectedTextW = surface.GetTextSize(displayOpt)
        local dropDownW = math.max(selectedTextW + 24, size)  -- 至少与数字框同宽，+24 为文字内边距+箭头预留空间

        -- 总宽度 = 前缀 + 下拉框
        local totalW = totalPrefixW + dropDownW
        slotTotalW = totalW  -- 更新覆盖层宽度为 select 模式宽度

        -- 绘制统一背景矩形（覆盖整个 n | 下拉框 区域）
        -- 悬停检测排除 n 按钮区域，只在悬停下拉框部分时提高亮度
        local isDropdownHovered = mouseX >= (x + totalPrefixW) and mouseX <= x + totalW and
                                  mouseY >= y and mouseY <= y + size
        draw.RoundedBox(4, x, y, totalW, size, isDropdownHovered and Color(80, 80, 80) or Color(60, 60, 60))

        -- 绘制 "n" 按钮区域（悬停检测）
        local nBtnH = size
        local nBtnX = x
        local nBtnY = y
        local isNHovered = mouseX >= nBtnX and mouseX <= nBtnX + nBtnW and
                           mouseY >= nBtnY and mouseY <= nBtnY + nBtnH

        -- n 按钮悬停时绘制半透明白色矩形（共用背景不变亮）
        -- 半透明矩形在共用矩形左边与 | 之间居中
        if isNHovered then
            local sepX = x + nBtnW
            local centerX = (x + sepX) / 2
            local hoverW = nBtnW * 0.8  -- 稍窄一些以突出居中效果
            local hoverX = centerX - hoverW / 2
            draw.RoundedBox(3, hoverX, nBtnY, hoverW, nBtnH, Color(255, 255, 255, 40))
        end

        -- 绘制 "n" 字符本身为橙色（使用缩放后的字体）
        draw.SimpleText("n", optFont, nBtnX + nBtnW / 2, nBtnY + nBtnH / 2, Color(230, 120, 30), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        -- 点击 n 切换回 Slot 模式
        if not overlayClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            local mouseActive = input.IsMouseDown(MOUSE_LEFT) or input.WasMousePressed(MOUSE_LEFT)
            if mouseActive and isNHovered and currentTime - numberData.slotToggleTime > 0.2 then
                numberData.mode = "slot"
                numberData.slotToggleTime = currentTime
                -- 关闭可能展开的下拉框
                if session then
                    session.ExpandedDropdown = nil
                    session.ExpandedDropdownInfo = nil
                end
                return numberData.value
            end
        end

        -- 绘制 "|" 分隔符（竖线 UI 元素）
        local sepX = x + nBtnW
        surface.SetDrawColor(Color(150, 150, 150))
        surface.DrawLine(sepX + sepW / 2, y + 2, sepX + sepW / 2, y + size - 2)

        -- 绘制下拉框区域（已在统一背景中绘制，此处只绘制文字和箭头）
        local ddX = sepX + sepW
        local ddY = y
        local ddW = dropDownW
        local ddH = size

        -- 当前选中选项
        local selectedIdx = numberData.selectedOptionIndex or 1
        local selectedText = options[selectedIdx] or options[1]
        -- 翻译变量路径为显示名称
        if KARDS.VarLib and KARDS.VarLib.GetDisplayName then
            selectedText = KARDS.VarLib.GetDisplayName(selectedText)
        end

        draw.SimpleText(selectedText, optFont, ddX + 8, ddY + ddH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        
        -- 下拉箭头
        local arrowX = ddX + ddW - 6 - 4
        local arrowY = ddY + ddH / 2
        surface.SetDrawColor(Color(150, 150, 150))
        surface.DrawLine(arrowX - 3, arrowY - 3, arrowX + 3, arrowY - 3)
        surface.DrawLine(arrowX - 3, arrowY - 3, arrowX, arrowY + 3)
        surface.DrawLine(arrowX + 3, arrowY - 3, arrowX, arrowY + 3)
        
        -- 点击下拉框打开变量选择弹窗
        if not overlayClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            local mouseActive = input.IsMouseDown(MOUSE_LEFT) or input.WasMousePressed(MOUSE_LEFT)
            if mouseActive and isDropdownHovered and currentTime - numberData.dropdownExpandTime > 0.3 then
                -- 关闭可能已展开的普通下拉框
                if session then
                    session.ExpandedDropdown = nil
                    session.ExpandedDropdownInfo = nil
                end
                -- 打开变量选择弹窗
                surface.SetFont(optFont)
                local popupCharW = surface.GetTextSize("字")
                local popupW = popupCharW * 30
                local popupX = ddX
                local popupY = ddY + ddH + 2
                if popupX + popupW > ScrW() then
                    popupX = ScrW() - popupW - 10
                end
                if session then
                    session.NumericVarPopup = {
                        nodeId = node.id,
                        numberId = numberId,
                        nodeRef = node,  -- 直接存储节点引用，避免后续遍历查找
                        x = popupX,
                        y = popupY,
                        searchText = "",
                        page = 1,
                        searchActive = false,  -- 搜索框是否激活
                        slotOptions = options,  -- 槽的选项列表
                        -- 筛选面板状态
                        filterExpanded = false,
                        filterFaction = nil,
                        filterLocation = nil,
                        filterType = nil,
                        filterKeyword = nil,
                        filterKwScroll = nil,
                    }
                end
                numberData.dropdownExpandTime = currentTime
            end
        end
        
        -- 返回当前值
        return currentValue, ddW + totalPrefixW
    else
        -- ========== 槽模式：数字框 + 缩短的箭头 + 选项按钮 ==========
        -- 绘制数字框背景
        draw.RoundedBox(4, x, y, size, size, Color(60, 60, 60))
        
        -- 绘制数字
        local text = tostring(currentValue)
        local font = canvasFont or "SourceHan_Heavy_16"
        if not canvasFont and currentValue >= 10 then
            font = "SourceHan_Heavy_14"
        end
        draw.SimpleText(text, font, x + size / 2, y + size / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        
        -- 按钮区域：上下箭头和空心选项按钮各占 1/3 元素高度
        local btnAreaX = x + size + 3
        local arrowW = size / 2 - 3  -- 箭头宽度（原始 7px）
        local optBtnW = arrowW  -- 选项按钮宽度与箭头宽度相同
        local thirdH = size / 3  -- 每部分高度 = 1/3 元素高度
        
        -- 上箭头
        local upBtnX = btnAreaX
        local upBtnY = y
        local upBtnH = thirdH
        local isUpHovered = mouseX >= upBtnX and mouseX <= upBtnX + arrowW and
                            mouseY >= upBtnY and mouseY <= upBtnY + upBtnH
        
        surface.SetDrawColor(isUpHovered and Color(100, 150, 255, 200) or Color(100, 100, 100))
        surface.DrawLine(upBtnX + arrowW / 2, upBtnY, upBtnX, upBtnY + upBtnH)
        surface.DrawLine(upBtnX + arrowW / 2, upBtnY, upBtnX + arrowW, upBtnY + upBtnH)
        surface.DrawLine(upBtnX, upBtnY + upBtnH, upBtnX + arrowW, upBtnY + upBtnH)

        -- 下箭头
        local downBtnX = btnAreaX
        local downBtnY = y + thirdH * 2
        local downBtnH = thirdH
        local isDownHovered = mouseX >= downBtnX and mouseX <= downBtnX + arrowW and
                              mouseY >= downBtnY and mouseY <= downBtnY + downBtnH

        surface.SetDrawColor(isDownHovered and Color(255, 100, 100, 200) or Color(100, 100, 100))
        surface.DrawLine(downBtnX, downBtnY, downBtnX + arrowW, downBtnY)
        surface.DrawLine(downBtnX, downBtnY, downBtnX + arrowW / 2, downBtnY + downBtnH)
        surface.DrawLine(downBtnX + arrowW, downBtnY, downBtnX + arrowW / 2, downBtnY + downBtnH)

        -- 选项按钮（空心矩形）- 最后绘制以确保位于最上层
        local optBtnX = btnAreaX
        local optBtnY = y + thirdH + 1  -- 向下偏移 1px，避免与上箭头底部线条重叠
        local optBtnH = thirdH - 1  -- 高度相应减少，保持与下箭头间距
        local isOptHovered = mouseX >= optBtnX and mouseX <= optBtnX + optBtnW and
                             mouseY >= optBtnY and mouseY <= optBtnY + optBtnH

        if isOptHovered then
            surface.SetDrawColor(Color(255, 200, 50))
        else
            surface.SetDrawColor(Color(150, 150, 150))
        end
        -- 使用 DrawLine 绘制空心矩形，确保与箭头渲染方式一致
        surface.DrawLine(optBtnX, optBtnY, optBtnX + optBtnW, optBtnY)  -- 上边
        surface.DrawLine(optBtnX, optBtnY + optBtnH, optBtnX + optBtnW, optBtnY + optBtnH)  -- 下边
        surface.DrawLine(optBtnX, optBtnY, optBtnX, optBtnY + optBtnH)  -- 左边
        surface.DrawLine(optBtnX + optBtnW, optBtnY, optBtnX + optBtnW, optBtnY + optBtnH)  -- 右边

        -- 点击选项按钮切换模式（同时使用 IsMouseDown + WasMousePressed 兜底）
        if not overlayClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            local mouseActive = input.IsMouseDown(MOUSE_LEFT) or input.WasMousePressed(MOUSE_LEFT)
            if mouseActive and isOptHovered and currentTime - numberData.slotToggleTime > 0.2 then
                numberData.mode = "select"
                numberData.selectedOptionIndex = numberData.selectedOptionIndex or 1
                numberData.slotToggleTime = currentTime
            end
        end
        
        -- 上下箭头数值调整（同时使用 IsMouseDown + WasMousePressed 兜底）
        if not overlayClicked and not KARDS.CardEditor.Canvas.DraggingNode and currentTime - numberData.lastArrowClickTime > 0.3 then
            local mouseActive = input.IsMouseDown(MOUSE_LEFT) or input.WasMousePressed(MOUSE_LEFT)
            if mouseActive then
                local arrowClicked = false
                if isUpHovered then
                    if currentValue < 99 then
                        numberData.value = currentValue + 1
                    else
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.ui.number_max_notice"), Color(50, 50, 50), false)
                    end
                    arrowClicked = true
                elseif isDownHovered then
                    if currentValue > 0 then
                        numberData.value = currentValue - 1
                    else
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.ui.number_min_notice"), Color(50, 50, 50), false)
                    end
                    arrowClicked = true
                end
                if arrowClicked then
                    numberData.lastArrowClickTime = currentTime
                end
            end
        end
        
        -- 右键：同时使用 IsMouseDown + WasMousePressed 兜底
        if not overlayClicked and not KARDS.CardEditor.Canvas.DraggingNode and currentTime - numberData.lastArrowClickTime > 0.3 then
            local mouseActive = input.IsMouseDown(MOUSE_RIGHT) or input.WasMousePressed(MOUSE_RIGHT)
            if mouseActive then
                if isUpHovered then
                    if currentValue < 99 then
                        numberData.value = math.min(99, currentValue + 5)
                    else
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.ui.number_max_notice"), Color(50, 50, 50), false)
                    end
                elseif isDownHovered then
                    if currentValue > 0 then
                        numberData.value = math.max(0, currentValue - 5)
                    else
                        KARDS.CardEditor.Canvas.AddNotification(T("editor.ui.number_min_notice"), Color(50, 50, 50), false)
                    end
                end
            end
        end
        
        return numberData.value, size + 3 + arrowW
    end
    
    -- ========== 变量选择覆盖层绘制 ==========
    -- 当全局变量页面有选中的数字变量时，在数字槽上方叠加蓝色高亮矩形
    if isNumVarSelected and not overlayClicked then
        local overlayW = slotTotalW
        -- Select 模式时覆盖层宽度需要包含整个 n|下拉框区域
        if hasOptions and numberData.mode == "select" then
            -- select 模式的总宽度已在上面计算，使用已有的 totalW
            -- 如果 totalW 不在当前作用域内，使用保守宽度
        end
        -- 厚边框（2px 蓝色边框）
        local borderThick = 2
        surface.SetDrawColor(Color(50, 120, 255, 200))
        for bi = 0, borderThick - 1 do
            surface.DrawOutlinedRect(x - bi, y - bi, overlayW + bi * 2, size + bi * 2)
        end
        -- 浅深渐变填充（从上到下：浅蓝→深蓝）
        local isHov = numberData._varOverlayHover or false
        if isHov then
            -- 悬停：半透明实心
            draw.RoundedBox(4, x, y, overlayW, size, Color(50, 120, 255, 100))
        else
            -- 非悬停：逐行渐变
            for gi = 0, size - 1 do
                local t = gi / size
                local alpha = 20 + t * 50
                surface.SetDrawColor(50, 120, 255, alpha)
                surface.DrawLine(x, y + gi, x + overlayW, y + gi)
            end
        end
    end
end

-- 绘制比较组件
function KARDS.CardEditor.Canvas.DrawComparison(x, y, width, height, node, comparisonId)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    -- 确保节点有data字段
    node.data = node.data or {}
    node.data.comparisons = node.data.comparisons or {}
    
    -- 比较操作符
    local operators = {"=", "≠", "＞", "＜", "≥", "≤"}
    
    -- 确保比较数据存在
    if not node.data.comparisons[comparisonId] then
        node.data.comparisons[comparisonId] = {
            operatorIndex = 1,
            lastClickTime = 0
        }
    end
    
    local comparisonData = node.data.comparisons[comparisonId]
    local currentIndex = comparisonData.operatorIndex
    local currentOperator = operators[currentIndex]
    local currentTime = SysTime()
    
    -- 绘制比较框背景
    draw.RoundedBox(4, x, y, width, height, Color(60, 60, 60))
    
    -- 绘制操作符
    draw.SimpleText(currentOperator, "SourceHan_Heavy_16", x + width / 2, y + height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 检查是否点击了比较组件（防止长按）
    if input.IsMouseDown(MOUSE_LEFT) and not KARDS.CardEditor.Canvas.DraggingNode then
        if mouseX >= x and mouseX <= x + width and
           mouseY >= y and mouseY <= y + height then
            if currentTime - comparisonData.lastClickTime > 0.3 then -- 300ms间隔
                -- 切换到下一个操作符
                currentIndex = currentIndex % #operators + 1
                comparisonData.operatorIndex = currentIndex
                comparisonData.lastClickTime = currentTime
            end
        end
    end
    
    -- 绘制悬停效果
    if mouseX >= x and mouseX <= x + width and
       mouseY >= y and mouseY <= y + height then
        draw.RoundedBox(4, x, y, width, height, Color(80, 80, 80, 150))
    end
    
    return currentOperator
end

-- 下拉选项卡全局样式参数
KARDS.CardEditor.Canvas.DropdownStyle = {
    rowHeight = 22,
    padding = 6,
    cornerRadius = 4,
    mainButtonColor = Color(60, 60, 60),
    mainButtonHoverColor = Color(80, 80, 80),
    dropdownBgColor = Color(50, 50, 50),
    dropdownHoverColor = Color(70, 70, 70),
    textColor = Color(255, 255, 255),
    arrowColor = Color(150, 150, 150),
    arrowSize = 6
}

-- 展开下拉框状态已迁入编辑器会话（editor.session.ExpandedDropdown / ExpandedDropdownInfo）
-- 见 docs/adr/0003-节点图值与编辑器会话分离.md

function KARDS.CardEditor.Canvas.DrawDropdown(x, y, width, height, options, selectedIndex, node, dropdownId, isUnitType, tooltipMap, canvasFont, canvasScale)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local style = KARDS.CardEditor.Canvas.DropdownStyle

    node.data = node.data or {}
    node.data.dropdowns = node.data.dropdowns or {}

    if not node.data.dropdowns[dropdownId] then
        node.data.dropdowns[dropdownId] = {
            selectedIndex = selectedIndex or 1,
            lastClickTime = 0,
            options = options
        }
    end

    local dropdownData = node.data.dropdowns[dropdownId]
    dropdownData.options = options
    -- 浮层状态归属：NodeBase 旧节点没有编辑器会话，此时跳过状态写入（旧渲染路径已弃用）
    local session = node.editor and node.editor.session
    local currentIndex = dropdownData.selectedIndex
    local isExpanded = session and session.ExpandedDropdown == (node.id .. "_" .. dropdownId)
    local currentTime = SysTime()

    local mainButtonX = x
    local mainButtonY = y
    local mainButtonW = width
    local mainButtonH = height

    local isMainHovered = mouseX >= mainButtonX and mouseX <= mainButtonX + mainButtonW and
                          mouseY >= mainButtonY and mouseY <= mainButtonY + mainButtonH

    draw.RoundedBox(style.cornerRadius, mainButtonX, mainButtonY, mainButtonW, mainButtonH,
        isMainHovered and style.mainButtonHoverColor or style.mainButtonColor)

    local selectedText = options[currentIndex] or options[1]
    -- 去除 $...$ 包裹的 $ 符号（用于卡牌对象模式选项的显示）
    local displayText = selectedText
    if displayText:sub(1,1) == "$" and displayText:sub(-1,-1) == "$" and #displayText >= 2 then
        displayText = displayText:sub(2, -2)
    end
    local ddFont = canvasFont or "SourceHan_Heavy_14"
    draw.SimpleText(displayText, ddFont, mainButtonX + 8, mainButtonY + mainButtonH / 2,
        style.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

    if isMainHovered then
        -- 检查是否有自定义 tooltip 映射
        if tooltipMap and tooltipMap[selectedText] then
            KARDS.CardEditor.Canvas.UpdateHoverTooltip(tooltipMap[selectedText])
        -- 检查是否有单位类型规则
        elseif KARDS.CardEditor.Canvas.UnitTypeRules[selectedText] then
            KARDS.CardEditor.Canvas.UpdateHoverTooltip(KARDS.CardEditor.Canvas.UnitTypeRules[selectedText])
        -- 通用术语释义：整词优先，其次直接匹配选项内文字（近义词区分）
        else
            local termTip = KARDS.CardEditor.Canvas.LookupTermTooltip(selectedText)
            if termTip then
                KARDS.CardEditor.Canvas.UpdateHoverTooltip(termTip)
            end
        end
    end

    local cs = canvasScale or 1
    local arrowSize = style.arrowSize * cs
    local arrowX = mainButtonX + mainButtonW - arrowSize - 8 * cs
    local arrowY = mainButtonY + mainButtonH / 2
    surface.SetDrawColor(style.arrowColor)
    surface.DrawLine(arrowX - arrowSize / 2, arrowY - arrowSize / 2, arrowX + arrowSize / 2, arrowY - arrowSize / 2)
    surface.DrawLine(arrowX - arrowSize / 2, arrowY - arrowSize / 2, arrowX, arrowY + arrowSize / 2)
    surface.DrawLine(arrowX + arrowSize / 2, arrowY - arrowSize / 2, arrowX, arrowY + arrowSize / 2)

    -- 拖拽临时连线、数据点、节点或框选期间不展开下拉框（2026-11-08，INE 编辑器）
    local ineModule = KARDS.CardEditor.IndependentNodeEditor
    local pointerBusy = node.editor and ineModule and ineModule.IsPointerBusy
        and ineModule:IsPointerBusy(node.editor)
    if input.IsMouseDown(MOUSE_LEFT) and not KARDS.CardEditor.Canvas.DraggingNode and not pointerBusy then
        if isMainHovered then
            if currentTime - dropdownData.lastClickTime > 0.3 then
                if isExpanded then
                    if session then
                        session.ExpandedDropdown = nil
                        session.ExpandedDropdownInfo = nil
                    end
                else
                    if not session then return currentIndex end
                    session.ExpandedDropdown = node.id .. "_" .. dropdownId
                    -- 计算多列信息
                local style = KARDS.CardEditor.Canvas.DropdownStyle
                local screenH = ScrH()
                local cs = canvasScale or 1
                local dropdownY = y + height + 2
                local maxRowsPerColumn = math.floor((screenH - dropdownY - style.padding * 2 * cs) / (style.rowHeight * cs))
                maxRowsPerColumn = math.max(1, maxRowsPerColumn)
                
                -- 计算所有选项中最长的文字宽度，使展开列宽能容纳所有选项
                -- 使用缩放后的字体（ddFont）确保展开宽度与画布缩放同步
                local optFont = ddFont or "SourceHan_Heavy_14"
                surface.SetFont(optFont)
                local maxOptPixelW = 0
                for _, opt in ipairs(options) do
                    local tw = surface.GetTextSize(opt)
                    maxOptPixelW = math.max(maxOptPixelW, tw)
                end
                -- 展开列宽 = 最长选项文字宽度 + 左右边距（8px左 + 6px箭头 + 8px右 = 22px）
                local expandedColumnWidth = math.max(maxOptPixelW + 22, width)
                local numColumns = math.ceil(#options / maxRowsPerColumn)
                local totalWidth = numColumns * expandedColumnWidth
                
                -- 计算实际需要的高度
                local dropdownH
                if numColumns == 1 then
                    -- 单列时，高度根据实际选项数量
                    dropdownH = #options * style.rowHeight * cs + style.padding * 2 * cs
                else
                    -- 多列时，保持完整列高度以保持视觉对齐
                    dropdownH = maxRowsPerColumn * style.rowHeight * cs + style.padding * 2 * cs
                end
                
                -- 计算下拉框实际位置
                local dropdownX = x
                if dropdownX + totalWidth > ScrW() then
                    dropdownX = x - (numColumns - 1) * expandedColumnWidth
                    if dropdownX < 0 then dropdownX = 0 end
                end
                
                session.ExpandedDropdownInfo = {
                    x = x,
                    y = y,
                    width = width,
                    height = height,
                    nodeId = node.id,
                    dropdownId = dropdownId,
                    options = options,
                    isUnitType = isUnitType,
                    tooltipMap = tooltipMap,
                    -- 多列信息
                    dropdownX = dropdownX,
                    dropdownY = dropdownY,
                    totalWidth = totalWidth,
                    expandedColumnWidth = expandedColumnWidth,
                    maxRowsPerColumn = maxRowsPerColumn,
                    dropdownH = dropdownH,
                    numColumns = numColumns,
                    -- 存储 dropdownData 的直接引用，用于 INE（独立节点编辑器）节点查找
                    -- INE 的节点不在 Canvas.Nodes 中，GetNodeById 无法找到
                    dropdownData = dropdownData,
                    -- 保存缩放后的字体名，DrawExpandedDropdowns 中绘制选项文本时使用
                    optFont = optFont,
                    -- 保存画布缩放值，用于调整展开选项的行高
                    canvasScale = canvasScale or 1,
                }
                end
                dropdownData.lastClickTime = currentTime
            end
        end
    end

    return currentIndex
end

function KARDS.CardEditor.Canvas.CloseAllDropdowns(session)
    if not session then return end
    session.ExpandedDropdown = nil
    session.ExpandedDropdownInfo = nil
end

function KARDS.CardEditor.Canvas.HandleDropdownClickOutside(mouseX, mouseY, session)
    local info = session and session.ExpandedDropdownInfo
    if not info then return false end

    local style = KARDS.CardEditor.Canvas.DropdownStyle

    local inMainButton = mouseX >= info.x and mouseX <= info.x + info.width and
                          mouseY >= info.y and mouseY <= info.y + info.height

    -- 使用保存的多列信息进行检测
    local inDropdown = false
    if info.dropdownX and info.dropdownY and info.totalWidth and info.dropdownH then
        inDropdown = mouseX >= info.dropdownX and mouseX <= info.dropdownX + info.totalWidth and
                   mouseY >= info.dropdownY and mouseY <= info.dropdownY + info.dropdownH
    else
        -- 降级到单列检测
        local dropdownY = info.y + info.height + 2
        local singleColumnH = style.rowHeight * #info.options + style.padding * 2
        inDropdown = mouseX >= info.x and mouseX <= info.x + info.width and
                   mouseY >= dropdownY and mouseY <= dropdownY + singleColumnH
    end

    if not inMainButton and not inDropdown then
        session.ExpandedDropdown = nil
        session.ExpandedDropdownInfo = nil
        return true
    end

    return false
end

function KARDS.CardEditor.Canvas.DrawExpandedDropdowns(info, editor)
    if not info then return end
    local session = editor and editor.session

    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local style = KARDS.CardEditor.Canvas.DropdownStyle
    local currentTime = SysTime()
    
    -- 使用保存的多列信息
    local dropdownX = info.dropdownX
    local dropdownY = info.dropdownY
    local totalWidth = info.totalWidth
    local maxRowsPerColumn = info.maxRowsPerColumn
    -- 展开下拉框使用基于最长选项文字计算的列宽，确保所有选项文字不超出背景
    local columnWidth = info.expandedColumnWidth or info.width
    -- 选项行高随缩放变化
    local scaledRowHeight = style.rowHeight * (info.canvasScale or 1)
    local scaledPadding = style.padding * (info.canvasScale or 1)
    -- 背景高度忽略存储的旧值，使用当前缩放后的行高重新计算
    local dropdownH
    if info.numColumns and info.numColumns == 1 then
        dropdownH = #info.options * scaledRowHeight + scaledPadding * 2
    else
        dropdownH = maxRowsPerColumn * scaledRowHeight + scaledPadding * 2
    end

    -- 绘制背景
    draw.RoundedBox(style.cornerRadius, dropdownX, dropdownY, totalWidth, dropdownH, style.dropdownBgColor)

    -- 根据下拉框类型绘制不同颜色的描边
    -- 数字槽→黄色，函数槽→紫色，普通→无特殊描边
    if info.isNumberSlot then
        surface.SetDrawColor(Color(230, 200, 30))
        surface.DrawOutlinedRect(dropdownX, dropdownY, totalWidth, dropdownH)
    elseif info.isTextSlot then
        -- 文本槽（INE <> 组件，2026-10-04）：绿色描边，与槽类型标识色一致
        surface.SetDrawColor(Color(76, 175, 80))
        surface.DrawOutlinedRect(dropdownX, dropdownY, totalWidth, dropdownH)
    elseif info.dropdownData and info.dropdownData._funcOptions then
        surface.SetDrawColor(Color(180, 70, 200))
        surface.DrawOutlinedRect(dropdownX, dropdownY, totalWidth, dropdownH)
    end

    local dropdownData = info.dropdownData
    local isNumberSlot = info.isNumberSlot
    if isNumberSlot then
        -- 数字槽下拉框：通过保存的节点引用获取 numberData
        local node = info.nodeRef
        if not node or not node.data or not node.data.numbers or not node.data.numbers[info.numberSlotNumberId] then
            return
        end
        local numData = node.data.numbers[info.numberSlotNumberId]
        -- 创建代理 dropdownData 复用选中逻辑
        dropdownData = {
            selectedIndex = numData.selectedOptionIndex or 1,
            lastClickTime = 0,
            numberData = numData,
            numberNode = node,
        }
    elseif not dropdownData then
        -- 降级：通过节点ID查找（对 Canvas 原生节点有效，INE 节点需通过 info.dropdownData 传入）
        local node = KARDS.CardEditor.Canvas.GetNodeById(info.nodeId)
        if not node then return end
        node.data = node.data or {}
        node.data.dropdowns = node.data.dropdowns or {}
        dropdownData = node.data.dropdowns[info.dropdownId]
        if not dropdownData then return end
    end

    local optionClicked = false
    for i, optionText in ipairs(info.options) do
        local col = math.floor((i - 1) / maxRowsPerColumn)
        local rowInCol = (i - 1) % maxRowsPerColumn
        
        local colX = dropdownX + col * columnWidth
        local optionY = dropdownY + scaledPadding + rowInCol * scaledRowHeight
        local optionH = scaledRowHeight
        local optionX = colX

        local isHovered = mouseX >= optionX and mouseX <= optionX + columnWidth and
                         mouseY >= optionY and mouseY <= optionY + optionH

        if isHovered then
            draw.RoundedBox(style.cornerRadius, optionX + 2, optionY, columnWidth - 4, optionH, style.dropdownHoverColor)

            -- 插图槽下拉框悬停预览（INE 插图槽组件：dropdownData._imagePreview = true）
            -- 选项文本为 data/kards_images 下的文件名，悬停时在鼠标左上处绘制缩略图
            if dropdownData and dropdownData._imagePreview and optionText and optionText ~= "" then
                local imgPath = "../data/kards_images/" .. optionText
                local previewMat = Material(imgPath, "noclamp smooth")
                if previewMat and not previewMat:IsError() then
                    local realW, realH = KARDS.CardEditor.Canvas.GetImageDimensions(imgPath)
                    local texW = realW or previewMat:Width()
                    local texH = realH or previewMat:Height()
                    -- 预览缩略图大小（最大 160x120，保持宽高比）
                    local thumbMaxW = 160
                    local thumbMaxH = 120
                    local thumbScale = math.min(thumbMaxW / texW, thumbMaxH / texH, 1.0)
                    local thumbW = texW * thumbScale
                    local thumbH = texH * thumbScale
                    -- 定位到鼠标坐标左上处，避免超出屏幕边缘
                    local thumbX = math.max(dropdownX + 4, mouseX - thumbW - 8)
                    local thumbY = math.max(dropdownY + 4, mouseY - thumbH - 8)
                    draw.RoundedBox(4, thumbX - 4, thumbY - 4, thumbW + 8, thumbH + 8, Color(40, 40, 40, 220))
                    surface.SetDrawColor(255, 255, 255, 255)
                    surface.SetMaterial(previewMat)
                    surface.DrawTexturedRect(thumbX, thumbY, thumbW, thumbH)
                end
            end

            if info.tooltipMap and info.tooltipMap[optionText] then
                KARDS.CardEditor.Canvas.UpdateHoverTooltip(info.tooltipMap[optionText])
            elseif KARDS.CardEditor.Canvas.UnitTypeRules[optionText] then
                KARDS.CardEditor.Canvas.UpdateHoverTooltip(KARDS.CardEditor.Canvas.UnitTypeRules[optionText])
            -- 通用术语释义：整词优先，其次直接匹配选项内文字（近义词区分）
            else
                local termTip = KARDS.CardEditor.Canvas.LookupTermTooltip(optionText)
                if termTip then
                    KARDS.CardEditor.Canvas.UpdateHoverTooltip(termTip)
                end
            end

            if input.WasMousePressed(MOUSE_LEFT) and not KARDS.CardEditor.Canvas.DraggingNode and not optionClicked then
                if isNumberSlot then
                    -- 数字槽选项选中
                    local numData = dropdownData.numberData
                    numData.selectedOptionIndex = i
                    numData.lastClickTime = currentTime
                    -- 尝试将选项文本解析为数值
                    local optVal = tonumber(optionText)
                    if optVal then
                        numData.value = optVal
                        dropdownData.numberNode.data[info.numberSlotNumberId] = optVal
                    end
                else
                    dropdownData.selectedIndex = i
                    dropdownData.lastClickTime = currentTime
                end
                if session then
                    session.ExpandedDropdown = nil
                    session.ExpandedDropdownInfo = nil
                end
                optionClicked = true
            end
        end

        -- 去除 $...$ 包裹的 $ 符号（用于卡牌对象模式选项的显示）
        local optDisplayText = optionText
        if optDisplayText:sub(1,1) == "$" and optDisplayText:sub(-1,-1) == "$" and #optDisplayText >= 2 then
            optDisplayText = optDisplayText:sub(2, -2)
        end
        -- 使用缩放后的字体绘制选项文本（与展开列宽保持一致）
        local optFont = info.optFont or "SourceHan_Heavy_14"
        draw.SimpleText(optDisplayText, optFont, optionX + 8, optionY + optionH / 2,
            style.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
end

-- 多选下拉框状态已迁入编辑器会话（editor.session.ExpandedMultiDropdown 与 ExpandedMultiDropdownInfo）
-- 见 docs/adr/0003-节点图值与编辑器会话分离.md

-- 绘制多选下拉框主按钮
function KARDS.CardEditor.Canvas.DrawMultiDropdown(x, y, width, height, dataTypes, selectedTypes, node, dropdownId)
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local style = KARDS.CardEditor.Canvas.DropdownStyle

    node.data = node.data or {}
    node.data.multiDropdowns = node.data.multiDropdowns or {}

    if not node.data.multiDropdowns[dropdownId] then
        node.data.multiDropdowns[dropdownId] = {
            selectedTypes = selectedTypes or {},
            lastClickTime = 0,
            dataTypes = dataTypes
        }
    end

    local dropdownData = node.data.multiDropdowns[dropdownId]
    dropdownData.dataTypes = dataTypes
    -- 浮层状态归属：NodeBase 旧节点没有编辑器会话，此时跳过状态写入（旧渲染路径已弃用）
    local session = node.editor and node.editor.session
    local isExpanded = session and session.ExpandedMultiDropdown == (node.id .. "_" .. dropdownId)
    local currentTime = SysTime()

    local mainButtonX = x
    local mainButtonY = y
    local mainButtonW = width
    local mainButtonH = height

    local isMainHovered = mouseX >= mainButtonX and mouseX <= mainButtonX + mainButtonW and
                          mouseY >= mainButtonY and mouseY <= mainButtonY + mainButtonH

    draw.RoundedBox(style.cornerRadius, mainButtonX, mainButtonY, mainButtonW, mainButtonH,
        isMainHovered and style.mainButtonHoverColor or style.mainButtonColor)

    -- 显示已选择的数量
    local selectedCount = #dropdownData.selectedTypes
    local displayText = selectedCount > 0 and T("editor.ui.selected_count", selectedCount) or T("editor.ui.please_select")
    draw.SimpleText(displayText, "SourceHan_Heavy_14", mainButtonX + 8, mainButtonY + mainButtonH / 2,
        style.textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

    local arrowX = mainButtonX + mainButtonW - style.arrowSize - 8
    local arrowY = mainButtonY + mainButtonH / 2
    surface.SetDrawColor(style.arrowColor)
    surface.DrawLine(arrowX - style.arrowSize / 2, arrowY - style.arrowSize / 2, arrowX + style.arrowSize / 2, arrowY - style.arrowSize / 2)
    surface.DrawLine(arrowX - style.arrowSize / 2, arrowY - style.arrowSize / 2, arrowX, arrowY + style.arrowSize / 2)
    surface.DrawLine(arrowX + style.arrowSize / 2, arrowY - style.arrowSize / 2, arrowX, arrowY + style.arrowSize / 2)

    if input.IsMouseDown(MOUSE_LEFT) and not KARDS.CardEditor.Canvas.DraggingNode then
        if isMainHovered and session then
            if currentTime - dropdownData.lastClickTime > 0.3 then
                if isExpanded then
                    session.ExpandedMultiDropdown = nil
                    session.ExpandedMultiDropdownInfo = nil
                else
                    session.ExpandedMultiDropdown = node.id .. "_" .. dropdownId
                    -- 计算多列信息
                    local style = KARDS.CardEditor.Canvas.DropdownStyle
                    local screenH = ScrH()
                    local dropdownY = y + height + 2
                    local optionWidth = 160 -- 固定选项宽度
                    local maxRowsPerColumn = math.floor((screenH - dropdownY - style.padding * 2) / style.rowHeight)
                    maxRowsPerColumn = math.max(1, maxRowsPerColumn)
                    local numColumns = math.ceil(#dataTypes / maxRowsPerColumn)
                    local totalWidth = numColumns * optionWidth
                    
                    local dropdownH
                    if numColumns == 1 then
                        dropdownH = #dataTypes * style.rowHeight + style.padding * 2
                    else
                        dropdownH = maxRowsPerColumn * style.rowHeight + style.padding * 2
                    end
                    
                    local dropdownX = x
                    if dropdownX + totalWidth > ScrW() then
                        dropdownX = x - (numColumns - 1) * optionWidth
                        if dropdownX < 0 then dropdownX = 0 end
                    end
                    
                    session.ExpandedMultiDropdownInfo = {
                        x = x,
                        y = y,
                        width = width,
                        height = height,
                        nodeId = node.id,
                        dropdownId = dropdownId,
                        dataTypes = dataTypes,
                        dropdownX = dropdownX,
                        dropdownY = dropdownY,
                        totalWidth = totalWidth,
                        maxRowsPerColumn = maxRowsPerColumn,
                        dropdownH = dropdownH,
                        numColumns = numColumns,
                        optionWidth = optionWidth
                    }
                end
                dropdownData.lastClickTime = currentTime
            end
        end
    end

    return dropdownData.selectedTypes
end

-- 绘制展开的多选下拉框。状态由 INE 会话持有，本函数只负责绘制与交互
function KARDS.CardEditor.Canvas.DrawExpandedMultiDropdowns(info, editor)
    if not info then return end

    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local style = KARDS.CardEditor.Canvas.DropdownStyle
    local currentTime = SysTime()
    
    local dropdownX = info.dropdownX
    local dropdownY = info.dropdownY
    local totalWidth = info.totalWidth
    local maxRowsPerColumn = info.maxRowsPerColumn
    local optionWidth = info.optionWidth
    local dropdownH = info.dropdownH
    local numColumns = info.numColumns

    -- 绘制背景
    draw.RoundedBox(style.cornerRadius, dropdownX, dropdownY, totalWidth, dropdownH, style.dropdownBgColor)

    local node = KARDS.CardEditor.Canvas.GetNodeById(info.nodeId)
    if not node then return end

    -- 获取选中的类型数组
    local selectedTypes
    if info.dropdownId == "output" then
        selectedTypes = node.selectedOutputTypes
    elseif info.dropdownId == "input" then
        selectedTypes = node.selectedInputTypes
    else
        -- 传统的 multiDropdowns 模式
        node.data = node.data or {}
        node.data.multiDropdowns = node.data.multiDropdowns or {}
        local dropdownData = node.data.multiDropdowns[info.dropdownId]
        if not dropdownData then return end
        selectedTypes = dropdownData.selectedTypes
    end

    -- 确保有 lastClickTime 存储
    local lastClickTime = 0
    if info.dropdownId == "output" or info.dropdownId == "input" then
        node.data = node.data or {}
        node.data.dataPortClickTimes = node.data.dataPortClickTimes or {}
        lastClickTime = node.data.dataPortClickTimes[info.dropdownId] or 0
    else
        node.data = node.data or {}
        node.data.multiDropdowns = node.data.multiDropdowns or {}
        local dropdownData = node.data.multiDropdowns[info.dropdownId]
        lastClickTime = dropdownData.lastClickTime or 0
    end

    for i, dataType in ipairs(info.dataTypes) do
        -- 计算当前选项在哪一列哪一行
        local col = math.floor((i - 1) / maxRowsPerColumn)
        local rowInCol = (i - 1) % maxRowsPerColumn
        
        local colX = dropdownX + col * optionWidth
        local optionY = dropdownY + style.padding + rowInCol * style.rowHeight
        local optionH = style.rowHeight
        local optionX = colX

        local isSelected = false
        for _, selectedId in ipairs(selectedTypes) do
            if selectedId == dataType.id then
                isSelected = true
                break
            end
        end

        local isHovered = mouseX >= optionX and mouseX <= optionX + optionWidth and
                         mouseY >= optionY and mouseY <= optionY + optionH

        -- 绘制高亮背景
        if isSelected or isHovered then
            local bgColor
            if isSelected and isHovered then
                -- 已选中且悬停：更强的高亮
                bgColor = Color(100, 150, 100)
            elseif isSelected then
                -- 已选中：绿色高亮
                bgColor = Color(70, 120, 70)
            elseif isHovered then
                -- 悬停：普通高亮
                bgColor = style.dropdownHoverColor
            end
            
            if bgColor then
                draw.RoundedBox(style.cornerRadius, optionX + 2, optionY, optionWidth - 4, optionH, bgColor)
            end
        end

        -- 处理点击
        if input.IsMouseDown(MOUSE_LEFT) and not KARDS.CardEditor.Canvas.DraggingNode then
            if isHovered and currentTime - lastClickTime > 0.3 then
                -- 切换选中状态
                local found = false
                for j, selectedId in ipairs(selectedTypes) do
                    if selectedId == dataType.id then
                        table.remove(selectedTypes, j)
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(selectedTypes, dataType.id)
                end
                
                -- 更新点击时间
                if info.dropdownId == "output" or info.dropdownId == "input" then
                    node.data.dataPortClickTimes = node.data.dataPortClickTimes or {}
                    node.data.dataPortClickTimes[info.dropdownId] = currentTime
                else
                    node.data.multiDropdowns = node.data.multiDropdowns or {}
                    node.data.multiDropdowns[info.dropdownId].lastClickTime = currentTime
                end
            end
        end

        -- 绘制文字（已选的用浅绿色）
        local textColor = isSelected and Color(144, 238, 144) or style.textColor
        draw.SimpleText(dataType.name, "SourceHan_Heavy_14", optionX + 8, optionY + optionH / 2,
            textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 绘制数据类型图标
        local iconX = optionX + optionWidth - 20
        local iconY = optionY + optionH / 2
        NodeBase.DrawDataTypeIcon(dataType, iconX, iconY, 16)
    end
end

-- 关闭所有多选下拉框
function KARDS.CardEditor.Canvas.CloseAllMultiDropdowns(session)
    if not session then return end
    session.ExpandedMultiDropdown = nil
    session.ExpandedMultiDropdownInfo = nil
end

-- 处理多选下拉框的外部点击
function KARDS.CardEditor.Canvas.HandleMultiDropdownClickOutside(mouseX, mouseY, session)
    local info = session and session.ExpandedMultiDropdownInfo
    if not info then return false end

    local style = KARDS.CardEditor.Canvas.DropdownStyle

    local inMainButton = mouseX >= info.x and mouseX <= info.x + info.width and
                          mouseY >= info.y and mouseY <= info.y + info.height

    local inDropdown = false
    if info.dropdownX and info.dropdownY and info.totalWidth and info.dropdownH then
        inDropdown = mouseX >= info.dropdownX and mouseX <= info.dropdownX + info.totalWidth and
                   mouseY >= info.dropdownY and mouseY <= info.dropdownY + info.dropdownH
    end

    if not inMainButton and not inDropdown then
        session.ExpandedMultiDropdown = nil
        session.ExpandedMultiDropdownInfo = nil
        return true
    end

    return false
end

function KARDS.CardEditor.Canvas.DrawConnections()
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    KARDS.CardEditor.Canvas.HoveredConnection = nil
    
    for _, conn in ipairs(KARDS.CardEditor.Canvas.Connections) do
        local fromNode = KARDS.CardEditor.Canvas.GetNodeById(conn.fromNode)
        local toNode = KARDS.CardEditor.Canvas.GetNodeById(conn.toNode)
        
        if fromNode and toNode then
            -- 使用NodeBase计算连线点
            local points = NodeBase.GetConnectionPoints(fromNode, toNode, conn.fromPort)
            local isHovered = NodeBase.IsMouseNearCurve(points, mouseX, mouseY, 15)
            
            if isHovered then
                KARDS.CardEditor.Canvas.HoveredConnection = conn
            end
            
            -- 使用NodeBase绘制连线
            NodeBase.DrawConnection(fromNode, toNode, conn.fromPort, isHovered)
        end
    end
end

-- 采样实现已迁至共享几何模块（ADR 0006），此处保留签名供既有调用方使用
function KARDS.CardEditor.Canvas.BezierCurve(p1x, p1y, p2x, p2y, p3x, p3y, p4x, p4y, steps)
    return KARDS.CardEditor.Geometry.SampleCubic(p1x, p1y, p2x, p2y, p3x, p3y, p4x, p4y, steps or 20)
end

function KARDS.CardEditor.Canvas.GetCurveNormals(points, thickness)
    thickness = thickness or 5
    local normals = {}
    for i = 1, #points do
        local prev = points[math.max(1, i - 1)]
        local next = points[math.min(#points, i + 1)]
        local dx = next.x - prev.x
        local dy = next.y - prev.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0 then
            local nx = -dy / len
            local ny = dx / len
            table.insert(normals, {x = nx, y = ny})
        else
            table.insert(normals, {x = 0, y = 0})
        end
    end
    return normals
end

function KARDS.CardEditor.Canvas.DrawThickCurve(points, color, thickness)
    thickness = thickness or 5
    local normals = KARDS.CardEditor.Canvas.GetCurveNormals(points, thickness)
    
    for offset = -thickness, thickness do
        local offsetPoints = {}
        for i = 1, #points do
            table.insert(offsetPoints, {
                x = points[i].x + normals[i].x * offset,
                y = points[i].y + normals[i].y * offset
            })
        end
        
        surface.SetDrawColor(color)
        for i = 1, #offsetPoints - 1 do
            surface.DrawLine(offsetPoints[i].x, offsetPoints[i].y, offsetPoints[i+1].x, offsetPoints[i+1].y)
        end
    end
end

function KARDS.CardEditor.Canvas.IsMouseNearCurve(points, mouseX, mouseY, threshold)
    threshold = threshold or 10
    for i = 1, #points - 1 do
        local p1 = points[i]
        local p2 = points[i + 1]
        local dist = KARDS.CardEditor.Canvas.PointToLineDistance(mouseX, mouseY, p1.x, p1.y, p2.x, p2.y)
        if dist < threshold then
            return true
        end
    end
    return false
end

function KARDS.CardEditor.Canvas.PointToLineDistance(px, py, x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local len2 = dx * dx + dy * dy
    if len2 == 0 then
        return math.sqrt((px - x1) ^ 2 + (py - y1) ^ 2)
    end
    local t = math.max(0, math.min(1, ((px - x1) * dx + (py - y1) * dy) / len2))
    local nearX = x1 + t * dx
    local nearY = y1 + t * dy
    return math.sqrt((px - nearX) ^ 2 + (py - nearY) ^ 2)
end

function KARDS.CardEditor.Canvas.DrawConnection(conn, isHovered)
    local fromNode = KARDS.CardEditor.Canvas.GetNodeById(conn.fromNode)
    local toNode = KARDS.CardEditor.Canvas.GetNodeById(conn.toNode)

    if not fromNode or not toNode then return end

    local win = KARDS.CardEditor.Canvas.Window
    local contentX = win.x + 5
    local selectorW = 180
    local nodeEditorX = contentX + selectorW
    local portRadius = 6

    local fromX, fromY
    if fromNode.isStartNode then
        local absoluteNodeX = win.x + fromNode.x
        if fromNode.type == "condition" or fromNode.type == "event_monitor" or fromNode.type == "loop" then
            if conn.fromPort == "output1" then
                fromX = absoluteNodeX + fromNode.width
                fromY = win.y + fromNode.y + fromNode.height / 3 + portRadius
            elseif conn.fromPort == "output2" then
                fromX = absoluteNodeX + fromNode.width
                fromY = win.y + fromNode.y + fromNode.height * 2 / 3 + portRadius
            else
                fromX = absoluteNodeX + fromNode.width
                fromY = win.y + fromNode.y + fromNode.height / 2
            end
        else
            fromX = absoluteNodeX + fromNode.width
            fromY = win.y + fromNode.y + fromNode.height / 2
        end
    else
        local absoluteNodeX = nodeEditorX + fromNode.x
        if fromNode.type == "condition" or fromNode.type == "event_monitor" or fromNode.type == "loop" then
            if conn.fromPort == "output1" then
                fromX = absoluteNodeX + fromNode.width
                fromY = win.y + fromNode.y + fromNode.height / 3 + portRadius
            elseif conn.fromPort == "output2" then
                fromX = absoluteNodeX + fromNode.width
                fromY = win.y + fromNode.y + fromNode.height * 2 / 3 + portRadius
            else
                fromX = absoluteNodeX + fromNode.width
                fromY = win.y + fromNode.y + fromNode.height / 2
            end
        else
            fromX = absoluteNodeX + fromNode.width
            fromY = win.y + fromNode.y + fromNode.height / 2
        end
    end

    local toX = nodeEditorX + toNode.x
    local toY = win.y + toNode.y + toNode.height / 2

    local distance = toX - fromX
    local controlPoint1X = fromX + distance / 3
    local controlPoint1Y = fromY
    local controlPoint2X = fromX + distance * 2 / 3
    local controlPoint2Y = toY

    local points = KARDS.CardEditor.Canvas.BezierCurve(fromX, fromY, controlPoint1X, controlPoint1Y, controlPoint2X, controlPoint2Y, toX, toY)

    -- 所有连接线统一使用浅蓝色
    local connectionColor = Color(100, 200, 255)

    if isHovered then
        KARDS.CardEditor.Canvas.DrawThickCurve(points, Color(255, 255, 255), 4) -- 缩小1/3
    end

    KARDS.CardEditor.Canvas.DrawThickCurve(points, connectionColor, 2) -- 缩小1/3
end

function KARDS.CardEditor.Canvas.DrawTempNode()
    if not KARDS.CardEditor.Canvas.TempNode then return end

    local template = KARDS.CardEditor.Canvas.TempNode.template
    local x, y = KARDS.CardEditor.Canvas.TempNode.x, KARDS.CardEditor.Canvas.TempNode.y

    NodeBase.DrawTempNode(template, x, y)
end

function KARDS.CardEditor.Canvas.DrawTempConnection()
    if not KARDS.CardEditor.Canvas.TempConnection then return end

    local conn = KARDS.CardEditor.Canvas.TempConnection
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()

    local fromNode = KARDS.CardEditor.Canvas.GetNodeById(conn.fromNode)
    if not fromNode then return end

    NodeBase.DrawTempConnection(fromNode, conn.fromPort, mouseX, mouseY)
end

KARDS.CardEditor.Canvas.LastMouseState = KARDS.CardEditor.Canvas.LastMouseState or false

-- ================================================================
-- 弹窗渲染注册（ADR 0003 决策 3）
-- 展开下拉框与多选下拉框状态在编辑器会话，绘制仍由 Canvas 提供
-- ================================================================
local INE_PopupReg = KARDS.CardEditor.IndependentNodeEditor
if INE_PopupReg and INE_PopupReg.RegisterPopupRenderer then
    INE_PopupReg:RegisterPopupRenderer("ExpandedDropdownInfo", KARDS.CardEditor.Canvas.DrawExpandedDropdowns)
    INE_PopupReg:RegisterPopupRenderer("ExpandedMultiDropdownInfo", KARDS.CardEditor.Canvas.DrawExpandedMultiDropdowns)
end