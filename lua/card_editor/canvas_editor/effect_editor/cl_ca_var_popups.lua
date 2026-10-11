--[[
=======================================================================================
变量弹窗与对象选择器模块 (Variable Popups)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的变量弹窗与卡牌对象选择器模块，负责数字变量弹窗、
函数变量弹窗与卡牌对象选择弹窗的绘制、交互与状态管理。

包含功能：
  - RegisterNumericVariable（注册数字型变量供数字槽选择）
  - DrawNumericVarPopup（数字型变量选择弹窗）
  - DrawFuncVarPopup（函数变量选择弹窗）
  - DrawCardObjectSelector（卡牌对象选择器弹窗）

状态数据：
  - NumericVarPopup（数字变量弹窗状态）

源文件：cl_canvas_editor.lua
  - 状态数据与功能函数：行 2495~4017
=======================================================================================
]]

-- 防御性命名空间初始化：确保即使本文件在 GMod 自动加载阶段先于
-- sh_card_editor_loader.lua 被加载，KARDS.CardEditor.Canvas 也已就绪
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}

--[[
    注册数字型变量供数字槽选择
    name: 变量名称（显示在弹窗中）
    value: 变量数值
]]
function KARDS.CardEditor.RegisterNumericVariable(name, value)
    local vars = KARDS.CardEditor.NumericVariables
    table.insert(vars, {name = name, value = value})
end

-- 数字型变量选择弹窗状态
KARDS.CardEditor.Canvas.NumericVarPopup = nil  -- { numberId, nodeId, x, y, searchText, page, totalPages }

-- 绘制数字型变量选择弹窗
function KARDS.CardEditor.Canvas.DrawNumericVarPopup()
    local popup = KARDS.CardEditor.Canvas.NumericVarPopup
    
    -- 弹窗关闭时清理 DTextEntry
    if not popup then
        if KARDS.CardEditor.Canvas._searchTextEntry then
            if IsValid(KARDS.CardEditor.Canvas._searchTextEntry) then
                KARDS.CardEditor.Canvas._searchTextEntry:Remove()
            end
            KARDS.CardEditor.Canvas._searchTextEntry = nil
        end
        return
    end
    
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local fontName = "SourceHan_Heavy_14"
    surface.SetFont(fontName)
    local charW = surface.GetTextSize("字")
    local popupW = charW * 30  -- 固定30个文字宽度
    local rowH = 22  -- 每行高度
    local popupH = rowH * 5 + 8  -- 5行 + 上下边距
    
    local px = popup.x
    local py = popup.y
    
    -- 背景
    draw.RoundedBox(4, px, py, popupW, popupH, Color(50, 50, 50, 240))
    surface.SetDrawColor(Color(230, 200, 30))  -- 黄色描边
    surface.DrawOutlinedRect(px, py, popupW, popupH)
    
    -- 第1行：搜索框
    local searchY = py + 4
    local inputW = popupW - 8
    local inputH = rowH - 2
    local isSearchActive = popup.searchActive or false
    local searchText = popup.searchText or ""
    
    if isSearchActive then
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(px + 4, searchY, inputW, inputH)
    else
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(40, 40, 40))
    end
    
    -- 搜索文本绘制
    local displayText = searchText
    if displayText == "" then
        draw.SimpleText("搜索变量...", fontName, px + 8, searchY + inputH / 2, isSearchActive and Color(180, 180, 180) or Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(displayText, fontName, px + 8, searchY + inputH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    
    -- 搜索框激活时绘制闪烁光标
    if isSearchActive and math.floor(SysTime() * 2) % 2 == 0 then
        local cursorX = px + 8 + surface.GetTextSize(searchText)
        surface.SetDrawColor(Color(200, 200, 200))
        surface.DrawLine(cursorX, searchY + 3, cursorX, searchY + inputH - 3)
    end
    
    -- 变量来源：槽选项或全局变量库
    local allVars = {}
    if popup.slotOptions then
        -- 槽选项模式：将选项文本作为虚拟变量
        for idx, optText in ipairs(popup.slotOptions) do
            table.insert(allVars, { name = optText, value = tonumber(optText) or 0, _index = idx })
        end
    else
        allVars = KARDS.CardEditor.NumericVariables or {}
    end
    local filteredVars = {}
    for _, v in ipairs(allVars) do
        local searchName = v.name
        if KARDS.VarLib and KARDS.VarLib.GetDisplayName then
            searchName = KARDS.VarLib.GetDisplayName(searchName)
        end
        if searchText == "" or searchName:find(searchText, 1, true) then
            table.insert(filteredVars, v)
        end
    end
    
    -- 分页计算
    local varsPerPage = 9
    local totalPages = math.max(1, math.ceil(#filteredVars / varsPerPage))
    local currentPage = math.min(popup.page or 1, totalPages)
    popup.page = currentPage  -- 同步当前页
    
    -- ============================================================
    -- 鼠标点击检测：使用状态追踪（比 WasMousePressed 更可靠）
    -- ============================================================
    local mouseDown = input.IsMouseDown(MOUSE_LEFT)
    local mouseClicked = false
    if KARDS.CardEditor.Canvas._mousePrevLeft == nil then
        KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown
    end
    if mouseDown and not KARDS.CardEditor.Canvas._mousePrevLeft then
        mouseClicked = true
    end
    KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown
    
    -- 处理弹窗内部选项点击和外部关闭
    if mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
        local insideW = popup.filterExpanded and (popupW + charW * 18 + 2) or popupW
        local insideH = popup.filterExpanded and (popupH + rowH * 4) or popupH
        local inside = mouseX >= px and mouseX <= px + insideW and
                       mouseY >= py and mouseY <= py + insideH
        if inside then
            -- 点击弹窗内部 → 检测选项选中
            if popup.slotOptions then
                local gridY = py + 4 + rowH + 2
                local colW = popupW / 3
                local startIdx = (currentPage - 1) * varsPerPage + 1
                local endIdx = math.min(startIdx + varsPerPage - 1, #filteredVars)
                
                for i = startIdx, endIdx do
                    local var = filteredVars[i]
                    local row = math.floor((i - startIdx) / 3)
                    local col = (i - startIdx) % 3
                    local cellX = px + 4 + col * colW
                    local cellY = gridY + row * rowH
                    local cellW_val = colW - 4
                    local cellH_val = rowH - 2
                    
                    if mouseX >= cellX and mouseX <= cellX + cellW_val and
                       mouseY >= cellY and mouseY <= cellY + cellH_val then
                        -- 选中选项：使用 popup.nodeRef 直接更新（创建时已存储引用）
                        local node = popup.nodeRef
                        if node and node.data and node.data.numbers and node.data.numbers[popup.numberId] then
                            local numData = node.data.numbers[popup.numberId]
                            numData.selectedOptionIndex = var._index
                            numData.value = var.value
                            node.data[popup.numberId] = var.value
                            -- 标记 popup 选中窗口期：变量引用（var:<名>）要下一帧回写数据源，
                            -- 消费方（如 cl_ine_var_op_nodes.lua DrawEvalNumRight）据此跳过本帧数据驱动同步/复位（E2）
                            numData._popupSelected = true
                            -- 立即重新计算节点宽度
                            if node.parsedConfig and node.parsedConfig.components and node.editor and INE and INE.CalculateSize then
                                local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput or false, node.editor, node.id)
                                node.width = nw
                                node.height = nh
                            end
                            KARDS.CardEditor.Canvas.NumericVarPopup = nil
                        end
                        return
                    end
                end
                -- 没有命中任何单元格 → 检测搜索框焦点
                local searchY = py + 4
                local inputW = popupW - 8
                local inputH = rowH - 2
                if mouseX >= px + 4 and mouseX <= px + 4 + inputW and
                   mouseY >= searchY and mouseY <= searchY + inputH then
                    popup.searchActive = true
                else
                    popup.searchActive = false
                end
            end
        else
            -- 点击弹窗外区域 → 关闭
            popup.searchActive = false
            KARDS.CardEditor.Canvas.NumericVarPopup = nil
            return
        end
    end
    
    -- 第2-4行：变量网格（3列）
    local gridY = py + 4 + rowH + 2
    local colW = popupW / 3
    local startIdx = (currentPage - 1) * varsPerPage + 1
    local endIdx = math.min(startIdx + varsPerPage - 1, #filteredVars)
    
    for i = startIdx, endIdx do
        local var = filteredVars[i]
        local row = math.floor((i - startIdx) / 3)
        local col = (i - startIdx) % 3
        local cellX = px + 4 + col * colW
        local cellY = gridY + row * rowH
        local cellW_val = colW - 4
        local cellH_val = rowH - 2
        
        local isHovered = mouseX >= cellX and mouseX <= cellX + cellW_val and
                          mouseY >= cellY and mouseY <= cellY + cellH_val
        
        if isHovered then
            draw.RoundedBox(3, cellX, cellY, cellW_val, cellH_val, Color(70, 70, 70))
        end
        
        -- 变量名截断（最多10个字符）
        local varName = var.name
        -- 如果有翻译函数，使用翻译后的显示名称
        if KARDS.VarLib and KARDS.VarLib.GetDisplayName then
            varName = KARDS.VarLib.GetDisplayName(varName)
        end
        local maxChars = 10
        local displayName = varName
        -- 计算 UTF-8 字符数（中文3字节，ASCII 1字节）
        local charCount = 0
        local byteLen = 0
        local i = 1
        while i <= #varName do
            local byte = varName:byte(i)
            local charBytes = 1
            if byte >= 240 then
                charBytes = 4
            elseif byte >= 224 then
                charBytes = 3  -- 中文通常是3字节
            elseif byte >= 128 then
                charBytes = 2
            end

            charCount = charCount + 1
            byteLen = i + charBytes - 1

            if charCount >= maxChars then
                displayName = varName:sub(1, byteLen) .. "…"
                break
            end

            i = i + charBytes
        end
        
        draw.SimpleText(displayName, fontName, cellX + 4, cellY + cellH_val / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        
        -- 悬停时显示完整变量名
        if isHovered then
            KARDS.CardEditor.Canvas.UpdateHoverTooltip(varName)
        end
    end
    
    -- 第5行：分页导航
    local navY = py + popupH - rowH - 2
    local navCenterX = px + popupW / 2
    
    -- 判断是否为第一页/最后一页
    local isFirstPage = currentPage <= 1
    local isLastPage = currentPage >= totalPages
    
    if not isFirstPage then
        local leftArrowX = navCenterX - charW * 4
        local leftArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= leftArrowX - 10 and mouseX <= leftArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY - 4)
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY + 4)
        
        -- 使用 mouseClicked 检测点击事件，避免持续切换
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.page = math.max(1, currentPage - 1)
        end
    end
    
    -- 页码
    draw.SimpleText(currentPage .. "/" .. totalPages, fontName, navCenterX, navY + rowH / 2, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    if not isLastPage then
        local rightArrowX = navCenterX + charW * 4
        local rightArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= rightArrowX - 10 and mouseX <= rightArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY - 4)
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY + 4)
        
        -- 使用 mouseClicked 检测点击事件，避免持续切换
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.page = currentPage + 1
        end
    end

    -- ============================================================
    -- 筛选面板（仅 slotOptions 模式，展开时绘制在右侧）
    -- ============================================================
    -- 确保筛选状态字段存在（兼容旧弹窗）
    if popup.filterExpanded == nil then popup.filterExpanded = false end
    if popup.filterFaction == nil then popup.filterFaction = nil end
    if popup.filterLocation == nil then popup.filterLocation = nil end
    if popup.filterType == nil then popup.filterType = nil end
    if popup.filterKeyword == nil then popup.filterKeyword = nil end

    -- 筛选关键词列表（与对象选择器共享）
    local FILTER_KEYWORDS_NUM = {
        "部署","守护","烟幕","闪击","伏击","亡计",
        "重甲1","重甲2","重甲3",
        "主动效果","被动效果","老兵","协力","情报",
        "冲击","奋战","山地",
        "收缴","钳击",
        "步兵","炮兵","坦克","战斗机","轰炸机",
    }

    -- ">>"/"<<" 筛选展开按钮（仅 slotOptions 模式，页面导航行最右侧）
    if popup.slotOptions then
        local navY = py + popupH - rowH - 2
        local filterBtnX = px + popupW - charW * 3 - 4
        local filterBtnW = charW * 3
        local filterBtnLabel = popup.filterExpanded and "<<" or ">>"
        local filterBtnHovered = mouseX >= filterBtnX and mouseX <= filterBtnX + filterBtnW and
                                 mouseY >= navY and mouseY <= navY + rowH
        draw.RoundedBox(3, filterBtnX, navY + 2, filterBtnW, rowH - 4, filterBtnHovered and Color(80, 90, 100) or Color(55, 55, 60))
        surface.SetDrawColor(Color(80, 80, 80))
        surface.DrawOutlinedRect(filterBtnX, navY + 2, filterBtnW, rowH - 4)
        draw.SimpleText(filterBtnLabel, fontName, filterBtnX + filterBtnW / 2, navY + rowH / 2, filterBtnHovered and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if filterBtnHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.filterExpanded = not popup.filterExpanded
            if not popup.filterExpanded then
                popup.filterFaction = nil
                popup.filterLocation = nil
                popup.filterType = nil
                popup.filterKeyword = nil
                popup.searchText = ""
                popup.page = 1
            end
        end
    end

    -- 筛选面板展开内容
    if popup.filterExpanded and popup.slotOptions then
        local filterPW = charW * 18
        local filterPX = px + popupW + 2
        local filterPY = py
        local filterPH = popupH + rowH * 4

        -- 存储筛选面板边界供 Think 检测鼠标位置使用
        popup._filterAreaX, popup._filterAreaY = filterPX, filterPY
        popup._filterAreaW, popup._filterAreaH = filterPW, filterPH

        -- 背景
        draw.RoundedBox(4, filterPX, filterPY, filterPW, filterPH, Color(50, 50, 50, 240))
        surface.SetDrawColor(Color(80, 80, 80))
        surface.DrawOutlinedRect(filterPX, filterPY, filterPW, filterPH)

        -- 标题
        local inputH = rowH - 2
        draw.SimpleText("筛选", fontName, filterPX + filterPW / 2, filterPY + inputH / 2 + 2, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        local fRowY = filterPY + inputH + 6
        local fRowH = rowH - 2
        local fPad = 4
        local fBtnH = fRowH - 2

        -- 辅助函数：重建筛选搜索文本
        local function RebuildFilterSearchNum()
            local parts = {}
            if popup.filterFaction then table.insert(parts, popup.filterFaction) end
            if popup.filterLocation then table.insert(parts, popup.filterLocation) end
            if popup.filterType then table.insert(parts, popup.filterType) end
            if popup.filterKeyword then table.insert(parts, popup.filterKeyword) end
            popup.searchText = table.concat(parts)
            popup.page = 1
        end

        -- 辅助函数：绘制筛选按钮
        local function DrawFilterBtnNum(btnX, btnY, btnW, label, isActive, isDisabled)
            if isDisabled then return false end
            local bHovered = mouseX >= btnX and mouseX <= btnX + btnW and
                             mouseY >= btnY and mouseY <= btnY + fBtnH
            local bColor = isActive and Color(70, 110, 160) or (bHovered and Color(65, 65, 70) or Color(45, 45, 50))
            draw.RoundedBox(3, btnX, btnY, btnW, fBtnH, bColor)
            if isActive then
                surface.SetDrawColor(Color(100, 150, 220, 200))
                surface.DrawOutlinedRect(btnX, btnY, btnW, fBtnH)
            end
            draw.SimpleText(label, fontName, btnX + btnW / 2, btnY + fBtnH / 2, isActive and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if bHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                return true
            end
            return false
        end

        -- Row 1：阵营（友方/敌方）
        local f1Y = fRowY
        local f1ColW = (filterPW - fPad * 3) / 2
        if DrawFilterBtnNum(filterPX + fPad, f1Y, f1ColW, "友方", popup.filterFaction == "友方") then
            if popup.filterFaction == "友方" then popup.filterFaction = nil else popup.filterFaction = "友方" end
            RebuildFilterSearchNum()
        end
        if DrawFilterBtnNum(filterPX + fPad * 2 + f1ColW, f1Y, f1ColW, "敌方", popup.filterFaction == "敌方") then
            if popup.filterFaction == "敌方" then popup.filterFaction = nil else popup.filterFaction = "敌方" end
            RebuildFilterSearchNum()
        end

        -- Row 2：位置（手牌/本回合/总部）
        local f2Y = f1Y + fRowH + 2
        local f2ColW = (filterPW - fPad * 4) / 3
        if DrawFilterBtnNum(filterPX + fPad, f2Y, f2ColW, "手牌", popup.filterLocation == "手牌") then
            if popup.filterLocation == "手牌" then popup.filterLocation = nil else popup.filterLocation = "手牌" end
            RebuildFilterSearchNum()
        end
        if DrawFilterBtnNum(filterPX + fPad * 2 + f2ColW, f2Y, f2ColW, "本回合", popup.filterLocation == "本回合") then
            if popup.filterLocation == "本回合" then popup.filterLocation = nil else popup.filterLocation = "本回合" end
            RebuildFilterSearchNum()
        end
        if DrawFilterBtnNum(filterPX + fPad * 3 + f2ColW * 2, f2Y, f2ColW, "总部", popup.filterLocation == "总部") then
            if popup.filterLocation == "总部" then popup.filterLocation = nil else popup.filterLocation = "总部" end
            RebuildFilterSearchNum()
        end

        -- Row 3：类型（单位/指令/反制）
        local f3Y = f2Y + fRowH + 2
        local showCmdAndCounter = true
        local typeColW = showCmdAndCounter and (filterPW - fPad * 4) / 3 or (filterPW - fPad * 2)
        if DrawFilterBtnNum(filterPX + fPad, f3Y, typeColW, "单位", popup.filterType == "单位") then
            if popup.filterType == "单位" then popup.filterType = nil else popup.filterType = "单位" end
            RebuildFilterSearchNum()
        end
        if showCmdAndCounter then
            if DrawFilterBtnNum(filterPX + fPad * 2 + typeColW, f3Y, typeColW, "指令", popup.filterType == "指令") then
                if popup.filterType == "指令" then popup.filterType = nil else popup.filterType = "指令" end
                RebuildFilterSearchNum()
            end
            if DrawFilterBtnNum(filterPX + fPad * 3 + typeColW * 2, f3Y, typeColW, "反制", popup.filterType == "反制") then
                if popup.filterType == "反制" then popup.filterType = nil else popup.filterType = "反制" end
                RebuildFilterSearchNum()
            end
        end

        -- 关键词标签网格
        local tagY = f3Y + fRowH + 6
        local tagH = rowH - 4
        local tagCols = math.floor(filterPW / (charW * 5 + 4))
        tagCols = math.max(1, tagCols)
        local tagColW = (filterPW - fPad * (tagCols + 1)) / tagCols

        -- 关键词滚动
        if popup.filterKwScroll == nil then popup.filterKwScroll = 0 end
        local kwPerPage = math.floor((filterPY + filterPH - tagY - 4) / (tagH + 2)) * tagCols
        local totalKw = 0
        -- 先统计可见关键词数量（无位置过滤限制，全部显示）
        for _, kw in ipairs(FILTER_KEYWORDS_NUM) do
            totalKw = totalKw + 1
        end
        local maxKwScroll = math.max(0, math.ceil((totalKw - kwPerPage) / tagCols) * (tagH + 2))
        popup.filterKwScroll = math.Clamp(popup.filterKwScroll or 0, 0, maxKwScroll)

        -- 用裁切限制关键词标签的渲染区域
        render.SetScissorRect(filterPX, tagY, filterPX + filterPW, filterPY + filterPH, true)

        local kwIdx = 0
        local scrollOffset = -(popup.filterKwScroll or 0)
        for _, kw in ipairs(FILTER_KEYWORDS_NUM) do
            -- 无位置过滤限制，全部显示
            local isFiltered = false
            if not isFiltered then
                kwIdx = kwIdx + 1
                local col = (kwIdx - 1) % tagCols
                local row = math.floor((kwIdx - 1) / tagCols)
                local kx = filterPX + fPad + col * (tagColW + fPad)
                local ky = tagY + row * (tagH + 2) + scrollOffset

                -- 裁剪：只绘制可见范围内的标签
                if ky + tagH >= filterPY and ky <= filterPY + filterPH then
                    local isActive = popup.filterKeyword == kw
                    local isHov = mouseX >= kx and mouseX <= kx + tagColW and
                                  mouseY >= ky and mouseY <= ky + tagH
                    local bCol = isActive and Color(70, 110, 160) or (isHov and Color(60, 60, 65) or Color(40, 40, 45))
                    draw.RoundedBox(3, kx, ky, tagColW, tagH, bCol)
                    if isActive then
                        surface.SetDrawColor(Color(100, 150, 220, 200))
                        surface.DrawOutlinedRect(kx, ky, tagColW, tagH)
                    end
                    draw.SimpleText(kw, "SourceHan_Heavy_12", kx + tagColW / 2, ky + tagH / 2, isActive and Color(255, 255, 255) or Color(170, 170, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    if isHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                        if popup.filterKeyword == kw then popup.filterKeyword = nil else popup.filterKeyword = kw end
                        RebuildFilterSearchNum()
                    end
                end
            end
        end

        -- 关键词滚动按钮
        if maxKwScroll > 0 then
            local scrollBtnSize = rowH - 4
            local scrollUpY = tagY
            local scrollDownY = filterPY + filterPH - scrollBtnSize - 2
            local scrollBtnsX = filterPX + filterPW - scrollBtnSize - fPad
            -- 上滚
            local upHov = mouseX >= scrollBtnsX and mouseX <= scrollBtnsX + scrollBtnSize and
                          mouseY >= scrollUpY and mouseY <= scrollUpY + scrollBtnSize
            draw.RoundedBox(3, scrollBtnsX, scrollUpY, scrollBtnSize, scrollBtnSize, upHov and Color(75, 75, 85) or Color(50, 50, 55))
            draw.SimpleText("▲", "SourceHan_Heavy_10", scrollBtnsX + scrollBtnSize / 2, scrollUpY + scrollBtnSize / 2, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if upHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                popup.filterKwScroll = math.max(0, (popup.filterKwScroll or 0) - (tagH + 2) * 2)
            end
            -- 下滚
            local downHov = mouseX >= scrollBtnsX and mouseX <= scrollBtnsX + scrollBtnSize and
                            mouseY >= scrollDownY and mouseY <= scrollDownY + scrollBtnSize
            draw.RoundedBox(3, scrollBtnsX, scrollDownY, scrollBtnSize, scrollBtnSize, downHov and Color(75, 75, 85) or Color(50, 50, 55))
            draw.SimpleText("▼", "SourceHan_Heavy_10", scrollBtnsX + scrollBtnSize / 2, scrollDownY + scrollBtnSize / 2, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if downHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                popup.filterKwScroll = math.min(maxKwScroll, (popup.filterKwScroll or 0) + (tagH + 2) * 2)
            end
        end

        -- 鼠标滚轮滚动关键词标签（滚轮标志由 CreateMove 中的 INE_WheelCapture 在 popup._wheelScroll 上设值）
        if popup._wheelScroll then
            if popup._wheelScroll == "up" then
                popup.filterKwScroll = math.max(0, (popup.filterKwScroll or 0) - (tagH + 2) * 2)
            elseif popup._wheelScroll == "down" then
                popup.filterKwScroll = math.min(maxKwScroll, (popup.filterKwScroll or 0) + (tagH + 2) * 2)
            end
            popup._wheelScroll = nil
        end

        -- 关闭裁切
        render.SetScissorRect(0, 0, 0, 0, false)
    end

    -- 搜索框的键盘输入由 HandleInput 中的按键事件处理
end

-- ================================================================
-- 函数变量选择弹窗（funcslot 函数槽单选下拉）
-- 外观与 DrawNumericVarPopup 相同：搜索框 + 3列网格 + 分页导航
-- 选项为函数变量（全局函数变量 + 当前槽局部函数）
-- ================================================================
function KARDS.CardEditor.Canvas.DrawFuncVarPopup()
    local INE = KARDS.CardEditor.IndependentNodeEditor
    local popup = KARDS.CardEditor.Canvas.FuncVarPopup
    if not popup then return end

    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local fontName = "SourceHan_Heavy_14"
    surface.SetFont(fontName)
    local charW = surface.GetTextSize("字")
    local popupW = charW * 30  -- 固定30个文字宽度
    local rowH = 22  -- 每行高度
    local popupH = rowH * 5 + 8  -- 5行 + 上下边距

    local px = popup.x
    local py = popup.y

    -- 背景
    draw.RoundedBox(4, px, py, popupW, popupH, Color(50, 50, 50, 240))
    surface.SetDrawColor(Color(180, 70, 200))  -- 紫色描边（函数主题色）
    surface.DrawOutlinedRect(px, py, popupW, popupH)

    -- 第1行：搜索框
    local searchY = py + 4
    local inputW = popupW - 8
    local inputH = rowH - 2
    local isSearchActive = popup.searchActive or false
    local searchText = popup.searchText or ""

    if isSearchActive then
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(px + 4, searchY, inputW, inputH)
    else
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(40, 40, 40))
    end

    if searchText == "" then
        draw.SimpleText("搜索函数...", fontName, px + 8, searchY + inputH / 2, isSearchActive and Color(180, 180, 180) or Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(searchText, fontName, px + 8, searchY + inputH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    -- 搜索框激活时绘制闪烁光标
    if isSearchActive and math.floor(SysTime() * 2) % 2 == 0 then
        local cursorX = px + 8 + surface.GetTextSize(searchText)
        surface.SetDrawColor(Color(200, 200, 200))
        surface.DrawLine(cursorX, searchY + 3, cursorX, searchY + inputH - 3)
    end

    -- 过滤选项（函数名大小写不敏感匹配）
    local filteredOpts = {}
    for _, fo in ipairs(popup.funcOptions or {}) do
        local label = fo.label or ""
        if searchText == "" or label:lower():find(searchText:lower(), 1, true) then
            table.insert(filteredOpts, fo)
        end
    end

    -- 分页计算
    local varsPerPage = 9
    local totalPages = math.max(1, math.ceil(#filteredOpts / varsPerPage))
    local currentPage = math.min(popup.page or 1, totalPages)
    popup.page = currentPage  -- 同步当前页

    -- ============================================================
    -- 鼠标点击检测：使用状态追踪（比 WasMousePressed 更可靠）
    -- ============================================================
    local mouseDown = input.IsMouseDown(MOUSE_LEFT)
    local mouseClicked = false
    if KARDS.CardEditor.Canvas._mousePrevLeft == nil then
        KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown
    end
    if mouseDown and not KARDS.CardEditor.Canvas._mousePrevLeft then
        mouseClicked = true
    end
    KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown

    -- 处理弹窗内部点击和外部关闭
    if mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
        local inside = mouseX >= px and mouseX <= px + popupW and
                       mouseY >= py and mouseY <= py + popupH
        if inside then
            -- 检测选项选中
            local gridY = py + 4 + rowH + 2
            local colW = popupW / 3
            local startIdx = (currentPage - 1) * varsPerPage + 1
            local endIdx = math.min(startIdx + varsPerPage - 1, #filteredOpts)

            local hitCell = false
            for i = startIdx, endIdx do
                local fo = filteredOpts[i]
                local row = math.floor((i - startIdx) / 3)
                local col = (i - startIdx) % 3
                local cellX = px + 4 + col * colW
                local cellY = gridY + row * rowH
                local cellW_val = colW - 4
                local cellH_val = rowH - 2

                if mouseX >= cellX and mouseX <= cellX + cellW_val and
                   mouseY >= cellY and mouseY <= cellY + cellH_val then
                    hitCell = true
                    -- 选中函数：更新节点槽数据
                    local node = popup.nodeRef
                    local slotData = popup.slotDataRef
                    if node and slotData then
                        slotData.variableRef = fo.label
                        slotData.mode = "variable"
                        -- 选中的是全局函数变量时清除局部函数引用
                        if not fo.isLocal then
                            slotData._localFuncRef = nil
                        end
                        node.data[popup.compId] = fo.label
                        -- 立即重新计算节点宽度
                        if node.parsedConfig and node.parsedConfig.components and node.editor and INE and INE.CalculateSize then
                            local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput or false, node.editor, node.id)
                            node.width = nw
                            node.height = nh
                        end
                    end
                    KARDS.CardEditor.Canvas.FuncVarPopup = nil
                    return
                end
            end
            -- 没有命中任何单元格 → 检测搜索框焦点
            if not hitCell then
                if mouseX >= px + 4 and mouseX <= px + 4 + inputW and
                   mouseY >= searchY and mouseY <= searchY + inputH then
                    popup.searchActive = true
                else
                    popup.searchActive = false
                end
            end
        else
            -- 点击弹窗外区域 → 关闭
            popup.searchActive = false
            KARDS.CardEditor.Canvas.FuncVarPopup = nil
            return
        end
    end

    -- 第2-4行：函数网格（3列）
    local gridY = py + 4 + rowH + 2
    local colW = popupW / 3
    local startIdx = (currentPage - 1) * varsPerPage + 1
    local endIdx = math.min(startIdx + varsPerPage - 1, #filteredOpts)

    for i = startIdx, endIdx do
        local fo = filteredOpts[i]
        local row = math.floor((i - startIdx) / 3)
        local col = (i - startIdx) % 3
        local cellX = px + 4 + col * colW
        local cellY = gridY + row * rowH
        local cellW_val = colW - 4
        local cellH_val = rowH - 2

        local isHovered = mouseX >= cellX and mouseX <= cellX + cellW_val and
                          mouseY >= cellY and mouseY <= cellY + cellH_val

        if isHovered then
            draw.RoundedBox(3, cellX, cellY, cellW_val, cellH_val, Color(70, 70, 70))
        end

        -- 函数名截断（最多10个字符）
        local varName = fo.label or ""
        local maxChars = 10
        local displayName = varName
        -- 计算 UTF-8 字符数（中文3字节，ASCII 1字节）
        local charCount = 0
        local byteLen = 0
        local j = 1
        while j <= #varName do
            local byte = varName:byte(j)
            local charBytes = 1
            if byte >= 240 then
                charBytes = 4
            elseif byte >= 224 then
                charBytes = 3  -- 中文通常是3字节
            elseif byte >= 128 then
                charBytes = 2
            end

            charCount = charCount + 1
            byteLen = j + charBytes - 1

            if charCount >= maxChars then
                displayName = varName:sub(1, byteLen) .. "…"
                break
            end

            j = j + charBytes
        end

        draw.SimpleText(displayName, fontName, cellX + 4, cellY + cellH_val / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 悬停时显示完整函数名
        if isHovered then
            KARDS.CardEditor.Canvas.UpdateHoverTooltip(varName)
        end
    end

    -- 第5行：分页导航
    local navY = py + popupH - rowH - 2
    local navCenterX = px + popupW / 2

    local isFirstPage = currentPage <= 1
    local isLastPage = currentPage >= totalPages

    if not isFirstPage then
        local leftArrowX = navCenterX - charW * 4
        local leftArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= leftArrowX - 10 and mouseX <= leftArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY - 4)
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY + 4)

        -- 使用 mouseClicked 检测点击事件，避免持续切换
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.page = math.max(1, currentPage - 1)
        end
    end

    -- 页码
    draw.SimpleText(currentPage .. "/" .. totalPages, fontName, navCenterX, navY + rowH / 2, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    if not isLastPage then
        local rightArrowX = navCenterX + charW * 4
        local rightArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= rightArrowX - 10 and mouseX <= rightArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY - 4)
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY + 4)

        -- 使用 mouseClicked 检测点击事件，避免持续切换
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            popup.page = currentPage + 1
        end
    end
end

-- ================================================================
-- 卡牌对象选择器弹窗（INE 编辑器单选组件的卡牌对象模式）
-- 外观与 DrawNumericVarPopup 相同，但选项为已保存卡牌/卡牌对象变量/数据连接变量
-- ================================================================
function KARDS.CardEditor.Canvas.DrawCardObjectSelector()
    local INE = KARDS.CardEditor.IndependentNodeEditor
    local sel = KARDS.CardEditor.Canvas.CardObjectSelector
    if not sel then return end
    if not sel.options or #sel.options == 0 then
        KARDS.CardEditor.Canvas.CardObjectSelector = nil
        return
    end

    -- 初始化状态
    if sel.multiSelect == nil then sel.multiSelect = false end
    if sel.includeGlobal == nil then sel.includeGlobal = false end
    if not sel.selectedIndices then sel.selectedIndices = {} end
    if sel.filterExpanded == nil then sel.filterExpanded = false end

    -- 筛选关键词列表（中文名）
    local FILTER_KEYWORDS = {
        "部署","守护","烟幕","闪击","伏击","亡计",
        "重甲1","重甲2","重甲3",
        "主动效果","被动效果","老兵","协力","情报",
        "冲击","奋战","山地",
        "收缴","钳击",
        "步兵","炮兵","坦克","战斗机","轰炸机",
    }

    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local fontName = "SourceHan_Heavy_14"
    surface.SetFont(fontName)
    local charW = surface.GetTextSize("字")
    local popupW = charW * 30
    local rowH = 22
    local popupH = rowH * 6 + 8  -- +1行用于底部按钮

    local px = sel.x
    local py = sel.y
    sel.popupW = popupW
    sel.popupH = popupH

    -- 背景
    draw.RoundedBox(4, px, py, popupW, popupH, Color(50, 50, 50, 240))
    surface.SetDrawColor(Color(200, 60, 60))  -- 红色描边
    surface.DrawOutlinedRect(px, py, popupW, popupH)

    -- 第1行：搜索框
    local searchY = py + 4
    local inputW = popupW - 8
    local inputH = rowH - 2
    local isSearchActive = sel.searchActive or false
    local searchText = sel.searchText or ""

    if isSearchActive then
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(60, 60, 70))
        surface.SetDrawColor(Color(100, 150, 255, 200))
        surface.DrawOutlinedRect(px + 4, searchY, inputW, inputH)
    else
        draw.RoundedBox(3, px + 4, searchY, inputW, inputH, Color(40, 40, 40))
    end

    if searchText == "" then
        draw.SimpleText("搜索卡牌...", fontName, px + 8, searchY + inputH / 2, isSearchActive and Color(180, 180, 180) or Color(120, 120, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    else
        draw.SimpleText(searchText, fontName, px + 8, searchY + inputH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    if isSearchActive and math.floor(SysTime() * 2) % 2 == 0 then
        local cursorX = px + 8 + surface.GetTextSize(searchText)
        surface.SetDrawColor(Color(200, 200, 200))
        surface.DrawLine(cursorX, searchY + 3, cursorX, searchY + inputH - 3)
    end

    -- 过滤选项：搜索文本 + includeGlobal
    -- 搜索匹配函数，支持 . 作为通配符（跳过任意一个字符位置）
    local function matchSearch(name, search)
        if search == "" then return true end
        -- 不含点号时使用快速匹配
        if not search:find("%.") then
            return name:find(search, 1, true) ~= nil
        end
        -- 将字符串按 UTF-8 字符分割
        local function toChars(s)
            local chars = {}
            local i = 1
            while i <= #s do
                local b = s:byte(i)
                local len = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
                chars[#chars + 1] = s:sub(i, i + len - 1)
                i = i + len
            end
            return chars
        end
        local nameChars = toChars(name)
        local searchChars = toChars(search)
        if #searchChars > #nameChars then return false end
        -- 在 name 的每个位置尝试匹配
        for start = 1, #nameChars - #searchChars + 1 do
            local matched = true
            for j = 1, #searchChars do
                local sc = searchChars[j]
                if sc ~= "." and sc ~= nameChars[start + j - 1] then
                    matched = false
                    break
                end
            end
            if matched then return true end
        end
        return false
    end

    local filteredOpts = {}
    local isGlobalOpt = {}  -- filteredOpts 中对应位置是否为全局变量（仅 VarLib 全局对象变量）
    for _, opt in ipairs(sel.options) do
        -- 包括全局关闭时仅跳过 VarLib 全局对象变量（isLibVar）；
        -- 数据线连接的对象（isWire，本地数据线）始终显示，对象槽可直接选用线传入的对象
        if not sel.includeGlobal and opt.isLibVar then
        else
            local optName = opt.label or opt.name or ""
            if matchSearch(optName, searchText) then
                table.insert(filteredOpts, opt)
                table.insert(isGlobalOpt, opt.isLibVar == true)
            end
        end
    end

    -- 在 multiSelect 模式下也要处理包括全局关闭时的自动移除逻辑（在点击按钮时处理）

    -- 分页（每页9个，3列）
    local varsPerPage = 9
    local totalPages = math.max(1, math.ceil(#filteredOpts / varsPerPage))
    local currentPage = math.min(sel.page or 1, totalPages)
    sel.page = currentPage

    -- 鼠标点击检测
    local mouseDown = input.IsMouseDown(MOUSE_LEFT)
    local mouseClicked = false
    if KARDS.CardEditor.Canvas._mousePrevLeft == nil then
        KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown
    end
    if mouseDown and not KARDS.CardEditor.Canvas._mousePrevLeft then
        mouseClicked = true
    end
    KARDS.CardEditor.Canvas._mousePrevLeft = mouseDown

    -- 处理点击
    if mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
        local insideW = sel.filterExpanded and (popupW + charW * 18 + 2) or popupW
        local insideH = sel.filterExpanded and (popupH + rowH * 4) or popupH
        local inside = mouseX >= px and mouseX <= px + insideW and
                       mouseY >= py and mouseY <= py + insideH
        if inside then
            -- 点击按钮行
            local btnY = py + popupH - rowH - 2
            local btnH = rowH - 2
            local btnMargin = 4
            local halfBtnW = (popupW - btnMargin * 3) / 2
            local multiBtnX = px + btnMargin
            local globalBtnX = px + btnMargin * 2 + halfBtnW

            if mouseY >= btnY and mouseY <= btnY + btnH then
                -- "多选"按钮点击
                if mouseX >= multiBtnX and mouseX <= multiBtnX + halfBtnW then
                    sel.multiSelect = not sel.multiSelect
                    if not sel.multiSelect then
                        -- 单选模式下只保留第一个选中项
                        local firstIdx = nil
                        for idx in pairs(sel.selectedIndices) do
                            if firstIdx == nil or idx < firstIdx then
                                firstIdx = idx
                            end
                        end
                        local newSel = {}
                        if firstIdx then newSel[firstIdx] = true end
                        sel.selectedIndices = newSel
                    end
                    return
                end
                -- "包括全局"按钮点击
                if mouseX >= globalBtnX and mouseX <= globalBtnX + halfBtnW then
                    local wasOn = sel.includeGlobal
                    sel.includeGlobal = not sel.includeGlobal
                    if wasOn and not sel.includeGlobal then
                        -- 关闭包括全局：移除所有连接变量的选中
                        if sel.multiSelect then
                            -- 多选：移除所有全局选项
                            local newSelected = {}
                            for idx, _ in pairs(sel.selectedIndices) do
                                if not isGlobalOpt[idx] then
                                    newSelected[idx] = true
                                end
                            end
                            sel.selectedIndices = newSelected
                        else
                            -- 单选：若当前选中是全局变量，重置到第一个非全局选项
                            local anyGlobal = false
                            for idx, _ in pairs(sel.selectedIndices) do
                                if isGlobalOpt[idx] then
                                    anyGlobal = true
                                    break
                                end
                            end
                            if anyGlobal then
                                sel.selectedIndices = {}
                                -- 找第一个非全局选项
                                for idx, opt in ipairs(filteredOpts) do
                                    if not isGlobalOpt[idx] then
                                        sel.selectedIndices[idx] = true
                                        break
                                    end
                                end
                            end
                        end
                        -- 关闭包括全局时收回筛选面板
                        sel.filterExpanded = false
                        sel.filterFaction = nil
                        sel.filterLocation = nil
                        sel.filterType = nil
                        sel.filterKeyword = nil
                        sel.searchText = ""
                    end
                    -- 页面重置到第1页（选项数量变化）
                    sel.page = 1
                    return
                end
            end

            -- 点击选项网格
            local gridY = py + 4 + rowH + 2
            local colW = popupW / 3
            local startIdx = (currentPage - 1) * varsPerPage + 1
            local endIdx = math.min(startIdx + varsPerPage - 1, #filteredOpts)

            for i = startIdx, endIdx do
                local opt = filteredOpts[i]
                local row = math.floor((i - startIdx) / 3)
                local col = (i - startIdx) % 3
                local cellX = px + 4 + col * colW
                local cellY = gridY + row * rowH
                local cellW_val = colW - 4
                local cellH_val = rowH - 2

                if mouseX >= cellX and mouseX <= cellX + cellW_val and
                   mouseY >= cellY and mouseY <= cellY + cellH_val then
                    local node = sel.nodeRef
                    if node and node.data then
                        if sel.multiSelect then
                            -- 多选模式：切换选中状态，不关闭弹窗
                            if sel.selectedIndices[i] then
                                sel.selectedIndices[i] = nil  -- 取消选中
                            else
                                sel.selectedIndices[i] = true  -- 选中
                            end
                            -- 立即写入 node.data 以便其他组件读取
                            local labels = {}
                            local files = {}
                            local appearances = {}
                            for idx, _ in pairs(sel.selectedIndices) do
                                local o = filteredOpts[idx]
                                if o then
                                    table.insert(labels, o.label or o.name or "?")
                                    if o.cardFile then table.insert(files, o.cardFile) end
                                    if o.cardAppearance then table.insert(appearances, o.cardAppearance) end
                                end
                            end
                            table.sort(labels)
                            if #labels > 0 then
                                local displayText = "多选(" .. #labels .. ")"
                                node.data[sel.compId] = displayText
                                node.data[sel.compId .. "_files"] = files
                                node.data[sel.compId .. "_appearances"] = appearances
                                node.data[sel.compId .. "_labels"] = labels
                            else
                                node.data[sel.compId] = nil
                                node.data[sel.compId .. "_files"] = nil
                                node.data[sel.compId .. "_appearances"] = nil
                                node.data[sel.compId .. "_labels"] = nil
                            end
                            if node.parsedConfig and node.parsedConfig.components and node.editor and INE and INE.CalculateSize then
                                local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput or false, node.editor, node.id)
                                node.width = nw
                                node.height = nh
                            end
                        else
                            -- 单例模式：直接选中并关闭弹窗
                            node.data[sel.compId] = opt.label or opt.name or "?"
                            node.data[sel.compId .. "_file"] = opt.cardFile
                            node.data[sel.compId .. "_appearance"] = opt.cardAppearance
                            node.data[sel.compId .. "_files"] = nil
                            node.data[sel.compId .. "_appearances"] = nil
                            node.data[sel.compId .. "_labels"] = nil
                            -- 同步到统一槽 SlotData（如果存在）
                            if sel._slotData then
                                sel._slotData.variableRef = opt.label or opt.name or "?"
                                sel._slotData.mode = "variable"
                            end
                            if node.parsedConfig and node.parsedConfig.components and node.editor and INE and INE.CalculateSize then
                                local nw, nh = INE.CalculateSize(node.parsedConfig.components, node.data, node.hasSecondOutput or false, node.editor, node.id)
                                node.width = nw
                                node.height = nh
                            end
                            KARDS.CardEditor.Canvas.CardObjectSelector = nil
                        end
                    end
                    return
                end
            end
            -- 点击搜索框
            if mouseX >= px + 4 and mouseX <= px + 4 + inputW and
               mouseY >= searchY and mouseY <= searchY + inputH then
                sel.searchActive = true
                -- 搜索框获得焦点时收回筛选面板
                if sel.filterExpanded then
                    sel.filterExpanded = false
                    sel.filterFaction = nil
                    sel.filterLocation = nil
                    sel.filterType = nil
                    sel.filterKeyword = nil
                end
            else
                sel.searchActive = false
            end
        else
            -- 点击外部：关闭弹窗，在 multiSelect 模式下已写入数据
            sel.searchActive = false
            KARDS.CardEditor.Canvas.CardObjectSelector = nil
            return
        end
    end

    -- 第2-4行：选项网格
    local gridY = py + 4 + rowH + 2
    _deferredPreview = nil  -- 重置延迟预览
    local colW = popupW / 3
    local startIdx = (currentPage - 1) * varsPerPage + 1
    local endIdx = math.min(startIdx + varsPerPage - 1, #filteredOpts)

    for i = startIdx, endIdx do
        local opt = filteredOpts[i]
        local row = math.floor((i - startIdx) / 3)
        local col = (i - startIdx) % 3
        local cellX = px + 4 + col * colW
        local cellY = gridY + row * rowH
        local cellW_val = colW - 4
        local cellH_val = rowH - 2

        local isHovered = mouseX >= cellX and mouseX <= cellX + cellW_val and
                          mouseY >= cellY and mouseY <= cellY + cellH_val

        -- 多选模式下高亮已选中的项
        local isSelected = sel.selectedIndices and sel.selectedIndices[i]

        if isSelected then
            draw.RoundedBox(3, cellX, cellY, cellW_val, cellH_val, Color(60, 100, 140))
        elseif isHovered then
            draw.RoundedBox(3, cellX, cellY, cellW_val, cellH_val, Color(70, 70, 70))
        end

        -- 名称截断
        local optName = opt.label or opt.name or ""
        local displayName = optName
        local charCount = 0
        local byteEnd = 0
        local byteIdx = 1
        while byteIdx <= #optName do
            local byte = optName:byte(byteIdx)
            local charBytes = 1
            if byte >= 240 then charBytes = 4
            elseif byte >= 224 then charBytes = 3
            elseif byte >= 128 then charBytes = 2
            end
            charCount = charCount + 1
            byteEnd = byteIdx + charBytes - 1
            if charCount >= 10 then
                displayName = optName:sub(1, byteEnd) .. "…"
                break
            end
            byteIdx = byteIdx + charBytes
        end

        -- 选中标记
        if isSelected then
            displayName = "✓ " .. displayName
        end

        draw.SimpleText(displayName, fontName, cellX + 4, cellY + cellH_val / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 收集悬停时的卡牌预览数据（推迟到所有 UI 元素绘制完成后渲染，确保预览图始终在最上层）
        if isHovered and opt.cardAppearance then
            local refH = math.floor((KARDS.CardEditor.Canvas.TotalEditorH or 720) / 3)
            local previewH = refH
            local previewW = math.floor(previewH * 3 / 4)
            local previewX = mouseX - previewW / 2
            local previewY = mouseY + 16
            if previewX + previewW > ScrW() then
                previewX = ScrW() - previewW - 8
            end
            if previewX < 0 then
                previewX = 8
            end
            if previewY + previewH > ScrH() then
                previewY = mouseY - previewH - 10
            end
            if previewY < 0 then
                previewY = 10
            end
            _deferredPreview = { appearance = opt.cardAppearance, x = previewX, y = previewY, w = previewW, h = previewH }
        end

        -- 悬停在接收的对象（数据连接传入）选项上时，从源节点的数据输出点绘制连线到该选项
        if isHovered and opt.type == "connection" and opt.fromNodeId then
            local editor = sel.nodeRef and sel.nodeRef.editor
            if editor then
                local srcNode = nil
                for _, n in ipairs(editor.nodes) do
                    if n.id == opt.fromNodeId then
                        srcNode = n
                        break
                    end
                end
                if srcNode then
                    local portPos = srcNode._outputDataPortPositions and srcNode._outputDataPortPositions[opt.fromPortIndex or 1]
                    if portPos then
                        local fromX, fromY = portPos.x, portPos.y
                        local toX, toY = cellX + cellW_val, cellY + cellH_val / 2
                        local distance = toY - fromY
                        local cp1x = fromX
                        local cp1y = fromY + distance / 3 + 30
                        local cp2x = toX
                        local cp2y = toY - distance / 3 - 30
                        local steps = 20
                        local points = {}
                        for i = 0, steps do
                            local t = i / steps
                            local x = (1-t)^3 * fromX + 3*(1-t)^2*t*cp1x + 3*(1-t)*t^2*cp2x + t^3*toX
                            local y = (1-t)^3 * fromY + 3*(1-t)^2*t*cp1y + 3*(1-t)*t^2*cp2y + t^3*toY
                            table.insert(points, {x = x, y = y})
                        end
                        if INE and INE.DrawThickCurve then
                            INE:DrawThickCurve(points, Color(255, 200, 0, 180), math.max(1, 2 * (editor.canvasScale or 1)))
                        end
                    end
                end
            end
        end
    end

    -- 第5行：分页导航（向上移一行，给底部按钮留空间）
    local navY = py + popupH - rowH * 2 - 2
    local navCenterX = px + popupW / 2
    local isFirstPage = currentPage <= 1
    local isLastPage = currentPage >= totalPages

    if not isFirstPage then
        local leftArrowX = navCenterX - charW * 4
        local leftArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= leftArrowX - 10 and mouseX <= leftArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY - 4)
        surface.DrawLine(leftArrowX - 4, leftArrowY, leftArrowX, leftArrowY + 4)
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            sel.page = math.max(1, currentPage - 1)
        end
    end

    draw.SimpleText(currentPage .. "/" .. totalPages, fontName, navCenterX, navY + rowH / 2, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    if not isLastPage then
        local rightArrowX = navCenterX + charW * 4
        local rightArrowY = navY + rowH / 2
        local arrowHovered = mouseX >= rightArrowX - 10 and mouseX <= rightArrowX + 10 and
                             mouseY >= navY and mouseY <= navY + rowH
        surface.SetDrawColor(arrowHovered and Color(200, 200, 200) or Color(150, 150, 150))
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY - 4)
        surface.DrawLine(rightArrowX + 4, rightArrowY, rightArrowX, rightArrowY + 4)
        if arrowHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
            sel.page = currentPage + 1
        end
    end

    -- ">>"/"<<" 筛选展开按钮（行5最右侧，仅包括全局时可用）
    if sel.includeGlobal then
    local filterBtnX = px + popupW - charW * 3 - 4
    local filterBtnW = charW * 3
    local filterBtnLabel = sel.filterExpanded and "<<" or ">>"
    local filterBtnHovered = mouseX >= filterBtnX and mouseX <= filterBtnX + filterBtnW and
                             mouseY >= navY and mouseY <= navY + rowH
    draw.RoundedBox(3, filterBtnX, navY + 2, filterBtnW, rowH - 4, filterBtnHovered and Color(80, 90, 100) or Color(55, 55, 60))
    surface.SetDrawColor(Color(80, 80, 80))
    surface.DrawOutlinedRect(filterBtnX, navY + 2, filterBtnW, rowH - 4)
    draw.SimpleText(filterBtnLabel, fontName, filterBtnX + filterBtnW / 2, navY + rowH / 2, filterBtnHovered and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if filterBtnHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
        sel.filterExpanded = not sel.filterExpanded
        if not sel.filterExpanded then
            -- 收回时清除筛选并重置搜索
            sel.filterFaction = nil
            sel.filterLocation = nil
            sel.filterType = nil
            sel.filterKeyword = nil
            sel.searchText = ""
            sel.page = 1
        end
        -- 不再处理后续点击
    end
    end -- end includeGlobal check

    -- 第6行：底部按钮（多选 / 包括全局）
    local btnY = py + popupH - rowH - 2
    local btnH = rowH - 2
    local btnMargin = 4
    local halfBtnW = (popupW - btnMargin * 3) / 2
    local multiBtnX = px + btnMargin
    local globalBtnX = px + btnMargin * 2 + halfBtnW

    -- "多选"按钮
    local multiActive = sel.multiSelect
    draw.RoundedBox(3, multiBtnX, btnY, halfBtnW, btnH, multiActive and Color(70, 110, 160) or Color(45, 45, 45))
    surface.SetDrawColor(multiActive and Color(100, 150, 220, 200) or Color(70, 70, 70))
    surface.DrawOutlinedRect(multiBtnX, btnY, halfBtnW, btnH)
    draw.SimpleText("多选", fontName, multiBtnX + halfBtnW / 2, btnY + btnH / 2, multiActive and Color(255, 255, 255) or Color(160, 160, 160), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- "包括全局"按钮
    local globalActive = sel.includeGlobal
    draw.RoundedBox(3, globalBtnX, btnY, halfBtnW, btnH, globalActive and Color(70, 110, 160) or Color(45, 45, 45))
    surface.SetDrawColor(globalActive and Color(100, 150, 220, 200) or Color(70, 70, 70))
    surface.DrawOutlinedRect(globalBtnX, btnY, halfBtnW, btnH)
    draw.SimpleText("包括全局", fontName, globalBtnX + halfBtnW / 2, btnY + btnH / 2, globalActive and Color(255, 255, 255) or Color(160, 160, 160), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- ================================================================
    -- 筛选面板（展开时绘制在右侧）
    -- ================================================================
    -- 先清除筛选面板边界，展开时再设置
    sel._filterAreaX, sel._filterAreaY = nil, nil
    sel._filterAreaW, sel._filterAreaH = nil, nil
    if sel.filterExpanded then
        local filterPW = charW * 18
        local filterPX = px + popupW + 2
        local filterPY = py
        local filterPH = popupH + rowH * 4  -- 向下扩展以容纳关键词

        -- 存储筛选面板边界供 Think 检测鼠标位置使用
        sel._filterAreaX, sel._filterAreaY = filterPX, filterPY
        sel._filterAreaW, sel._filterAreaH = filterPW, filterPH

        -- 背景（红色描边，与对象选择器主体一致）
        draw.RoundedBox(4, filterPX, filterPY, filterPW, filterPH, Color(50, 50, 50, 240))
        surface.SetDrawColor(Color(200, 60, 60))
        surface.DrawOutlinedRect(filterPX, filterPY, filterPW, filterPH)

        -- 标题
        draw.SimpleText("筛选", fontName, filterPX + filterPW / 2, filterPY + inputH / 2 + 2, Color(220, 220, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        local fRowY = filterPY + inputH + 6
        local fRowH = rowH - 2
        local fPad = 4
        local fColW = (filterPW - fPad * 3) / 2  -- 2列
        local fBtnH = fRowH - 2

        -- 辅助函数：构建搜索文本
        local function RebuildFilterSearch()
            local parts = {}
            if sel.filterFaction then table.insert(parts, sel.filterFaction) end
            if sel.filterLocation then table.insert(parts, sel.filterLocation) end
            if sel.filterType then table.insert(parts, sel.filterType) end
            if sel.filterKeyword then table.insert(parts, sel.filterKeyword) end
            sel.searchText = table.concat(parts)
            sel.page = 1
        end

        -- 辅助函数：绘制筛选按钮
        local function DrawFilterBtn(btnX, btnY, btnW, label, isActive, isDisabled)
            if isDisabled then return end
            local bHovered = mouseX >= btnX and mouseX <= btnX + btnW and
                             mouseY >= btnY and mouseY <= btnY + fBtnH
            local bColor = isActive and Color(70, 110, 160) or (bHovered and Color(65, 65, 70) or Color(45, 45, 50))
            draw.RoundedBox(3, btnX, btnY, btnW, fBtnH, bColor)
            if isActive then
                surface.SetDrawColor(Color(100, 150, 220, 200))
                surface.DrawOutlinedRect(btnX, btnY, btnW, fBtnH)
            end
            draw.SimpleText(label, fontName, btnX + btnW / 2, btnY + fBtnH / 2, isActive and Color(255, 255, 255) or Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if bHovered and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                return true
            end
            return false
        end

        -- Row 1: 阵营（友方/敌方）
        local f1Y = fRowY
        local f1ColW = (filterPW - fPad * 3) / 2
        if DrawFilterBtn(filterPX + fPad, f1Y, f1ColW, "友方", sel.filterFaction == "友方") then
            if sel.filterFaction == "友方" then sel.filterFaction = nil else sel.filterFaction = "友方" end
            RebuildFilterSearch()
        end
        if DrawFilterBtn(filterPX + fPad * 2 + f1ColW, f1Y, f1ColW, "敌方", sel.filterFaction == "敌方") then
            if sel.filterFaction == "敌方" then sel.filterFaction = nil else sel.filterFaction = "敌方" end
            RebuildFilterSearch()
        end

        -- Row 2: 位置（手牌/场上）
        local f2Y = f1Y + fRowH + 2
        if DrawFilterBtn(filterPX + fPad, f2Y, f1ColW, "手牌", sel.filterLocation == "手牌") then
            if sel.filterLocation == "手牌" then sel.filterLocation = nil else sel.filterLocation = "手牌" end
            -- 清除不兼容的类型/关键词
            if sel.filterLocation == "手牌" and sel.filterKeyword == "老兵" then sel.filterKeyword = nil end
            RebuildFilterSearch()
        end
        if DrawFilterBtn(filterPX + fPad * 2 + f1ColW, f2Y, f1ColW, "场上", sel.filterLocation == "场上") then
            if sel.filterLocation == "场上" then sel.filterLocation = nil else sel.filterLocation = "场上" end
            -- 场上时清除不兼容的类型/关键词
            if sel.filterLocation == "场上" then
                if sel.filterType == "指令" or sel.filterType == "反制" then sel.filterType = nil end
                if sel.filterKeyword == "指令" or sel.filterKeyword == "反制" then sel.filterKeyword = nil end
            end
            RebuildFilterSearch()
        end

        -- Row 3: 类型（单位/指令/反制，选择"场上"时下一行不显示指令/反制）
        local f3Y = f2Y + fRowH + 2
        local showCmdAndCounter = sel.filterLocation ~= "场上"
        local typeColW = showCmdAndCounter and (filterPW - fPad * 4) / 3 or (filterPW - fPad * 2)

        if DrawFilterBtn(filterPX + fPad, f3Y, typeColW, "单位", sel.filterType == "单位") then
            if sel.filterType == "单位" then sel.filterType = nil else sel.filterType = "单位" end
            RebuildFilterSearch()
        end
        if showCmdAndCounter then
            if DrawFilterBtn(filterPX + fPad * 2 + typeColW, f3Y, typeColW, "指令", sel.filterType == "指令") then
                if sel.filterType == "指令" then sel.filterType = nil else sel.filterType = "指令" end
                RebuildFilterSearch()
            end
            if DrawFilterBtn(filterPX + fPad * 3 + typeColW * 2, f3Y, typeColW, "反制", sel.filterType == "反制") then
                if sel.filterType == "反制" then sel.filterType = nil else sel.filterType = "反制" end
                RebuildFilterSearch()
            end
        end

        -- 关键词标签网格
        local tagY = f3Y + fRowH + 6
        local tagH = rowH - 4
        local tagCols = math.floor(filterPW / (charW * 5 + 4))
        tagCols = math.max(1, tagCols)
        local tagColW = (filterPW - fPad * (tagCols + 1)) / tagCols

        -- 关键词滚动
        if sel.filterKwScroll == nil then sel.filterKwScroll = 0 end
        local kwPerPage = math.floor((filterPY + filterPH - tagY - 4) / (tagH + 2)) * tagCols
        local totalKw = 0
        -- 先统计可见关键词数量
        for _, kw in ipairs(FILTER_KEYWORDS) do
            local skip = false
            if sel.filterLocation == "手牌" and kw == "老兵" then skip = true end
            if sel.filterLocation == "场上" and (kw == "指令" or kw == "反制") then skip = true end
            if not skip then totalKw = totalKw + 1 end
        end
        local maxKwScroll = math.max(0, math.ceil((totalKw - kwPerPage) / tagCols) * (tagH + 2))
        sel.filterKwScroll = math.Clamp(sel.filterKwScroll or 0, 0, maxKwScroll)

        -- 用裁切限制关键词标签的渲染区域，防止滚动时标签覆盖上方的筛选项
        render.SetScissorRect(filterPX, tagY, filterPX + filterPW, filterPY + filterPH, true)

        local kwIdx = 0
        local drawnInView = 0
        local scrollOffset = -(sel.filterKwScroll or 0)
        for _, kw in ipairs(FILTER_KEYWORDS) do
            -- 过滤不兼容的关键词
            local isFiltered = (sel.filterLocation == "手牌" and kw == "老兵") or
                              (sel.filterLocation == "场上" and (kw == "指令" or kw == "反制"))
            if not isFiltered then
                kwIdx = kwIdx + 1
                local col = (kwIdx - 1) % tagCols
                local row = math.floor((kwIdx - 1) / tagCols)
                local kx = filterPX + fPad + col * (tagColW + fPad)
                local ky = tagY + row * (tagH + 2) + scrollOffset

                -- 裁剪：只绘制可见范围内的标签
                if ky + tagH >= filterPY and ky <= filterPY + filterPH then
                    drawnInView = drawnInView + 1
                    local isActive = sel.filterKeyword == kw
                    local isHov = mouseX >= kx and mouseX <= kx + tagColW and
                                  mouseY >= ky and mouseY <= ky + tagH

                    local bCol = isActive and Color(70, 110, 160) or (isHov and Color(60, 60, 65) or Color(40, 40, 45))
                    draw.RoundedBox(3, kx, ky, tagColW, tagH, bCol)
                    if isActive then
                        surface.SetDrawColor(Color(100, 150, 220, 200))
                        surface.DrawOutlinedRect(kx, ky, tagColW, tagH)
                    end
                    draw.SimpleText(kw, "SourceHan_Heavy_12", kx + tagColW / 2, ky + tagH / 2, isActive and Color(255, 255, 255) or Color(170, 170, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

                    if isHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                        if sel.filterKeyword == kw then
                            sel.filterKeyword = nil
                        else
                            sel.filterKeyword = kw
                        end
                        RebuildFilterSearch()
                    end
                end
            end
        end

        -- 关键词滚动按钮（有滚动时显示）
        if maxKwScroll > 0 then
            local scrollBtnSize = rowH - 4
            local scrollUpY = tagY
            local scrollDownY = filterPY + filterPH - scrollBtnSize - 2
            local scrollBtnsX = filterPX + filterPW - scrollBtnSize - fPad

            -- 上滚
            local upHov = mouseX >= scrollBtnsX and mouseX <= scrollBtnsX + scrollBtnSize and
                          mouseY >= scrollUpY and mouseY <= scrollUpY + scrollBtnSize
            draw.RoundedBox(3, scrollBtnsX, scrollUpY, scrollBtnSize, scrollBtnSize, upHov and Color(75, 75, 85) or Color(50, 50, 55))
            draw.SimpleText("▲", "SourceHan_Heavy_10", scrollBtnsX + scrollBtnSize / 2, scrollUpY + scrollBtnSize / 2, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if upHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                sel.filterKwScroll = math.max(0, (sel.filterKwScroll or 0) - (tagH + 2) * 2)
            end

            -- 下滚
            local downHov = mouseX >= scrollBtnsX and mouseX <= scrollBtnsX + scrollBtnSize and
                            mouseY >= scrollDownY and mouseY <= scrollDownY + scrollBtnSize
            draw.RoundedBox(3, scrollBtnsX, scrollDownY, scrollBtnSize, scrollBtnSize, downHov and Color(75, 75, 85) or Color(50, 50, 55))
            draw.SimpleText("▼", "SourceHan_Heavy_10", scrollBtnsX + scrollBtnSize / 2, scrollDownY + scrollBtnSize / 2, Color(180, 180, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            if downHov and mouseClicked and not KARDS.CardEditor.Canvas.DraggingNode then
                sel.filterKwScroll = math.min(maxKwScroll, (sel.filterKwScroll or 0) + (tagH + 2) * 2)
            end
        end

        -- 鼠标滚轮滚动关键词标签
        -- 检测鼠标是否在关键词标签区域内
        if mouseX >= filterPX and mouseX <= filterPX + filterPW and
           mouseY >= tagY and mouseY <= filterPY + filterPH then
            if INE._filterWheelUp then
                INE._filterWheelUp = false
                sel.filterKwScroll = math.max(0, (sel.filterKwScroll or 0) - (tagH + 2) * 2)
            end
            if INE._filterWheelDown then
                INE._filterWheelDown = false
                sel.filterKwScroll = math.min(maxKwScroll, (sel.filterKwScroll or 0) + (tagH + 2) * 2)
            end
        end

        -- 关闭裁切，恢复正常渲染
        render.SetScissorRect(0, 0, 0, 0, false)

        -- 延迟渲染卡牌预览图（在所有 UI 元素绘制完成后执行，确保预览图始终在最上层）
        if _deferredPreview then
            KARDS.CardEditor.Canvas.DrawCardPreview(
                _deferredPreview.appearance,
                _deferredPreview.x, _deferredPreview.y,
                _deferredPreview.w, _deferredPreview.h,
                false, false, false
            )
        end
    end
end
