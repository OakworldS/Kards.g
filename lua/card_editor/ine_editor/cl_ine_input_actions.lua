--[[
=======================================================================================
INE 输入动作表 (INE Input Actions)
=======================================================================================
按 ADR 0004 组织的 INE 输入动作表，分三层：
  - modal：模态与浮层，导入警告、下拉选项、变量弹窗、卡牌对象选择器、叠加窗口
  - chrome：编辑器窗口级，删除与断开按钮、右键菜单、文件与视图菜单、关闭按钮、
    标题拖拽、节点选择面板
  - canvas：画布内部，平移、右键菜单构建、左键按下、滚轮、删除键

约定：
  - 每个动作项形如 { name = "动作名", run = function(editor, ctx) return consumed end }。
  - run 返回 true 表示已消费该输入，路由立即停止。
  - 上下文 ctx 只含原始输入，跨动作共享状态仍挂 editor。

迁移状态（绞杀者式，2026-11-08）：
  阶段 2 搬入模态层，阶段 3 搬入窗口层，阶段 4 搬入画布层并删除
  INE:HandleInputLegacy。三层动作已全部就位，输入顺序由层内顺序表达。

源文件：新建（2026-11-08），决策见 docs/adr/0004-输入路由共享引擎.md
=======================================================================================
]]

local INE = KARDS.CardEditor.IndependentNodeEditor

--[[
    导入警告对话框：对话框显示时独占输入，只处理仍然导入与取消导入两个按钮。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 true，对话框存在时阻止后续动作
]]
local function ActionImportWarnings(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    if input.IsMouseDown(MOUSE_LEFT) then
        local btns = editor._importDialogButtons
        if btns then
            if INE:IsPointInRect(mouseX, mouseY, btns["continue"]) then
                -- 点击"仍然导入"，应用导入数据
                INE:ApplyImportWarnings(editor)
            elseif INE:IsPointInRect(mouseX, mouseY, btns.cancel) then
                -- 点击"取消导入"，清除待导入数据和警告
                editor.importWarnings = nil
                if editor._pendingImportData then
                    editor._pendingImportData = nil
                end
            end
        end
    end
    return true
end

--[[
    下拉框展开后的选项点击。
    使用 input.IsMouseDown 替代 WasMousePressed 以避免可能的鼠标状态消耗问题，
    点击后立即清除 ExpandedDropdownInfo，后续帧不会再处理。
    注意：INE 的浮层状态存放在 editor.session 中（ADR 0003），不能读旧的 Canvas 全局表。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 命中选项卡时返回 true
]]
local function ActionDropdownOption(editor, ctx)
    local dropdownSession = editor and editor.session
    if not dropdownSession then return false end
    local expandedInfo = dropdownSession.ExpandedDropdownInfo
    -- 拖拽临时连线、数据点、节点或框选期间不响应选项选择（2026-11-08）
    if not (expandedInfo and expandedInfo.dropdownData and ctx.leftDown) then
        return false
    end
    if INE:IsPointerBusy(editor) then
        return false
    end

    local mouseX, mouseY = ctx.x, ctx.y
    local mouseInDropdown = mouseX >= expandedInfo.dropdownX and mouseX <= expandedInfo.dropdownX + expandedInfo.totalWidth
                        and mouseY >= expandedInfo.dropdownY and mouseY <= expandedInfo.dropdownY + expandedInfo.dropdownH
    if mouseInDropdown then
        local dropdownStyle = KARDS.CardEditor.Canvas.DropdownStyle
        local cs = expandedInfo.canvasScale or 1
        local maxRows = expandedInfo.maxRowsPerColumn
        local columnWidth = expandedInfo.expandedColumnWidth or expandedInfo.width
        local padding = (dropdownStyle.padding or 6) * cs
        local rowHeight = (dropdownStyle.rowHeight or 22) * cs

        for i, _ in ipairs(expandedInfo.options) do
            local col = math.floor((i - 1) / maxRows)
            local colX = expandedInfo.dropdownX + col * columnWidth
            local optionY = expandedInfo.dropdownY + padding + ((i - 1) % maxRows) * rowHeight

            if mouseX >= colX and mouseX <= colX + columnWidth
               and mouseY >= optionY and mouseY <= optionY + rowHeight then
                expandedInfo.dropdownData.selectedIndex = i
                -- 记录本帧已消费下拉框选项点击：绘制阶段同帧的按钮/行点击需忽略，
                -- 防止下拉框选项与下方按钮/行重叠时重复触发（如"设置变量"最后一行
                -- 操作下拉框首选项被误判为点击 "+ 修改全局变量" 展开浮层）
                dropdownSession._dropdownConsumedFrame = FrameNumber()
                -- 触发 onSelect 回调（用于 funcslot 等自定义选择行为）
                if expandedInfo.dropdownData._onSelect then
                    expandedInfo.dropdownData._onSelect(i, expandedInfo.dropdownData)
                end
                dropdownSession.ExpandedDropdown = nil
                dropdownSession.ExpandedDropdownInfo = nil
                return true
            end
        end
    end
    return false
end

--[[
    变量选择弹窗（NumericVarPopup 与 FuncVarPopup 共用）的搜索输入生命周期。
    管理透明 DTextEntry 以支持 IME 中文输入，并处理 ESC 关闭。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，仅做帧内状态维护
]]
local function ActionVarPopupLifecycle(editor, ctx)
    local session = editor and editor.session
    if not session then return false end
    local varPopup = session.NumericVarPopup
    local funcPopup = session.FuncVarPopup
    local activePopup = varPopup or funcPopup
    if activePopup then
        -- 管理 DTextEntry 支持 IME 中文输入
        local oldEntry = session._searchTextEntry
        if activePopup.searchActive then
            if not oldEntry or not IsValid(oldEntry) then
                -- 计算搜索框位置（与 HUDPaint 中 DrawNumericVarPopup 的计算一致）
                surface.SetFont("SourceHan_Heavy_14")
                local charW = surface.GetTextSize("字")
                local popupW = charW * 30
                local searchX = activePopup.x + 4
                local searchY = activePopup.y + 4
                local searchW = popupW - 8
                local searchH = 22 - 2  -- rowH - 2

                -- 创建 DTextEntry 放在搜索框位置，捕获键盘/IME 输入
                local entry = vgui.Create("DTextEntry", KARDS.CardEditor.Canvas.RootPanel)
                entry:SetPos(searchX, searchY)
                entry:SetSize(searchW, searchH)
                entry:SetText(activePopup.searchText or "")
                -- 完全不可见（不绘制任何内容），仅用于捕获 IME/键盘输入
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil  -- 不绘制任何内容
                entry:RequestFocus()
                entry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    local p = session.NumericVarPopup or session.FuncVarPopup
                    if p then
                        p.searchText = txt
                        p.page = 1
                    end
                end
                session._searchTextEntry = entry
            else
                -- 已有 DTextEntry，确保其持有焦点
                if not oldEntry:HasFocus() then
                    oldEntry:RequestFocus()
                end
            end
        else
            -- searchActive 为 false → 清理 DTextEntry
            if oldEntry and IsValid(oldEntry) then
                oldEntry:Remove()
            end
            session._searchTextEntry = nil
        end

        -- ESC 关闭弹窗
        if input.WasKeyPressed(KEY_ESCAPE) then
            session.NumericVarPopup = nil
            session.FuncVarPopup = nil
        end
    else
        -- 弹窗不存在 → 确保 DTextEntry 被清理
        local oldEntry = session._searchTextEntry
        if oldEntry and IsValid(oldEntry) then
            oldEntry:Remove()
        end
        session._searchTextEntry = nil
    end
    return false
end

--[[
    全局变量选择器浮层（GlobalVarSelector）的搜索输入生命周期与 ESC 关闭。
    搜索输入框使用 glua-input-field 模式：透明 DTextEntry 捕获 IME/键盘输入。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，仅做帧内状态维护
]]
local function ActionGlobalVarSelector(editor, ctx)
    local session = editor and editor.session
    if not session then return false end
    local gvs = session.GlobalVarSelector
    if gvs then
        -- 校验浮层所属节点仍有效（节点被删除时关闭浮层）
        local gvsNodeValid = false
        if gvs.editor and gvs.editor.nodes and gvs.node then
            for _, nd in ipairs(gvs.editor.nodes) do
                if nd == gvs.node then gvsNodeValid = true break end
            end
        end
        if not gvsNodeValid then
            local gvsE = session._gvsSearchEntry
            if gvsE and IsValid(gvsE) then gvsE:Remove() end
            session._gvsSearchEntry = nil
            session.GlobalVarSelector = nil
        else
            -- 管理 DTextEntry（搜索框位置与绘制函数中一致：px+4, py+padTop, pw-8, rowH-2）
            local oldEntry = session._gvsSearchEntry
            if gvs.searchActive then
                if not oldEntry or not IsValid(oldEntry) then
                    local padTop = math.max(2, math.floor(4 * (gvs.scale or 1)))
                    local rowH = gvs.rowH or math.max(16, math.floor(22 * (gvs.scale or 1)))
                    local searchX = gvs.x + 4
                    local searchY = gvs.y + padTop
                    local searchW = gvs.w - 8
                    local searchH = rowH - 2
                    local entry = vgui.Create("DTextEntry", KARDS.CardEditor.Canvas.RootPanel)
                    entry:SetPos(searchX, searchY)
                    entry:SetSize(searchW, searchH)
                    entry:SetText(gvs.searchText or "")
                    -- 完全不可见（不绘制任何内容），仅用于捕获 IME/键盘输入
                    entry:SetDrawBackground(false)
                    entry:SetDrawBorder(false)
                    entry:SetTextColor(Color(255, 255, 255, 0))
                    entry:SetCursorColor(Color(255, 255, 255, 0))
                    entry.Paint = nil  -- 不绘制任何内容
                    entry:RequestFocus()
                    entry.OnTextChanged = function(self)
                        local txt = self:GetText()
                        local p = session.GlobalVarSelector
                        if p then
                            p.searchText = txt
                            p.page = 1
                        end
                    end
                    entry.OnKeyCodeTyped = function(self, keyCode)
                        if keyCode == KEY_ESCAPE and session.GlobalVarSelector then
                            session.GlobalVarSelector.searchActive = false
                        end
                    end
                    session._gvsSearchEntry = entry
                else
                    -- 已有 DTextEntry：同步位置（浮层可被拖出屏幕边界钳制）并确保持有焦点
                    local padTop = math.max(2, math.floor(4 * (gvs.scale or 1)))
                    local rowH = gvs.rowH or math.max(16, math.floor(22 * (gvs.scale or 1)))
                    oldEntry:SetPos(gvs.x + 4, gvs.y + padTop)
                    oldEntry:SetSize(gvs.w - 8, rowH - 2)
                    -- 同步文本：防止复用 DTextEntry 时残留旧文本污染（多输入框文本污染）
                    local expected = gvs.searchText or ""
                    if oldEntry:GetText() ~= expected then
                        oldEntry:SetText(expected)
                    end
                    if not oldEntry:HasFocus() then
                        oldEntry:RequestFocus()
                    end
                end
            else
                -- searchActive 为 false → 清理 DTextEntry
                if oldEntry and IsValid(oldEntry) then
                    oldEntry:Remove()
                end
                session._gvsSearchEntry = nil
            end
        end

        -- ESC 关闭浮层（搜索框内 ESC 由 OnKeyCodeTyped 失活搜索框；搜索框外 ESC 关闭浮层）
        if input.WasKeyPressed(KEY_ESCAPE) and not gvs.searchActive then
            local gvsE = session._gvsSearchEntry
            if gvsE and IsValid(gvsE) then gvsE:Remove() end
            session._gvsSearchEntry = nil
            session.GlobalVarSelector = nil
        end
    else
        -- 浮层不存在 → 确保 DTextEntry 被清理
        local oldEntry = session._gvsSearchEntry
        if oldEntry and IsValid(oldEntry) then
            oldEntry:Remove()
        end
        session._gvsSearchEntry = nil
    end
    return false
end

--[[
    卡牌对象选择器弹窗的搜索输入生命周期与 ESC 关闭。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，仅做帧内状态维护
]]
local function ActionCardObjectSelector(editor, ctx)
    local session = editor and editor.session
    if not session then return false end
    local cardSel = session.CardObjectSelector
    if cardSel then
        local oldEntry = session._cardObjectSearchEntry
        if cardSel.searchActive then
            if not oldEntry or not IsValid(oldEntry) then
                surface.SetFont("SourceHan_Heavy_14")
                local charW = surface.GetTextSize("字")
                local popupW = charW * 30
                local searchX = cardSel.x + 4
                local searchY = cardSel.y + 4
                local searchW = popupW - 8
                local searchH = 22 - 2

                local entry = vgui.Create("DTextEntry", KARDS.CardEditor.Canvas.RootPanel)
                entry:SetPos(searchX, searchY)
                entry:SetSize(searchW, searchH)
                entry:SetText(cardSel.searchText or "")
                entry:SetDrawBackground(false)
                entry:SetDrawBorder(false)
                entry:SetTextColor(Color(255, 255, 255, 0))
                entry:SetCursorColor(Color(255, 255, 255, 0))
                entry.Paint = nil
                entry:RequestFocus()
                entry.OnTextChanged = function(self)
                    local txt = self:GetText()
                    local s = session.CardObjectSelector
                    if s then
                        s.searchText = txt
                        s.page = 1
                    end
                end
                session._cardObjectSearchEntry = entry
            else
                if not oldEntry:HasFocus() then
                    oldEntry:RequestFocus()
                end
            end
        else
            if oldEntry and IsValid(oldEntry) then
                oldEntry:Remove()
            end
            session._cardObjectSearchEntry = nil
        end

        -- ESC 关闭弹窗
        if input.WasKeyPressed(KEY_ESCAPE) then
            session.CardObjectSelector = nil
        end
    else
        local oldEntry = session._cardObjectSearchEntry
        if oldEntry and IsValid(oldEntry) then
            oldEntry:Remove()
        end
        session._cardObjectSearchEntry = nil
    end
    return false
end

--[[
    叠加窗口交互：窗口拖拽、按钮、字段输入与关闭。
    具体弹窗逻辑在 cl_ine_input_overlay.lua，本动作只负责调用与帧状态清除。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，遮挡状态通过 editor._mouseOverOverlayWindow 传递
]]
local function ActionOverlayWindow(editor, ctx)
    INE:HandleOverlayInteraction(editor, ctx.x, ctx.y)
    -- 叠加窗口点击状态帧清除
    if not ctx.leftDown then
        editor._overlayClientClickHandled = false
    end
    return false
end

--[[
    框选删除按钮与右键菜单：删除选中节点、断开连接，以及节点与连接线的删除项。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 消费输入时返回 true
]]
local function ActionSelectionAndContextMenu(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    -- 优先处理框选删除按钮与右键菜单（2026-11-08）
    -- 放在顶部文件/视图菜单之前，避免菜单点击被右键菜单的关闭逻辑吞掉
    if INE:HandleSelectionDeleteButtonInput(editor, mouseX, mouseY) then
        return true
    end
    if editor.contextMenu then
        INE:UpdateContextMenuState(editor, mouseX, mouseY)
        if INE:HandleContextMenuInput(editor, mouseX, mouseY) then
            return true
        end
    end

    return false
end

--[[
    顶部文件菜单：按钮切换、菜单项执行与点击外部关闭。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，菜单为常驻窗口级交互
]]
local function ActionFileMenu(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    -- 处理文件菜单交互
    local mouseOverFileMenu = false
    local mouseOverFileBtn = false
    
    if editor._fileBtnRect then
        mouseOverFileBtn = INE:IsPointInRect(mouseX, mouseY, editor._fileBtnRect)
        if editor._fileMenuRect and editor.fileMenuOpen then
            mouseOverFileMenu = INE:IsPointInRect(mouseX, mouseY, editor._fileMenuRect)
        end
    end
    
    -- 如果鼠标在文件菜单上，阻止底层操作
    if mouseOverFileMenu then
        editor._mouseOverOverlayWindow = true
    end
    
    -- 处理文件菜单按钮点击
    if input.IsMouseDown(MOUSE_LEFT) and not editor._fileMenuClicked then
        editor._fileMenuClicked = true
        
        if mouseOverFileBtn then
            -- 点击文件按钮，切换菜单状态
            editor.fileMenuOpen = not editor.fileMenuOpen
        elseif mouseOverFileMenu then
            -- 点击菜单区域
            if editor._fileMenuHoveredItem and editor._fileMenuHoveredItem > 0 then
                local itemIndex = editor._fileMenuHoveredItem
                editor.fileMenuOpen = false
                INE:ExecuteFileMenuItem(editor, itemIndex)
            end
        else
            -- 点击其他区域，关闭文件菜单
            editor.fileMenuOpen = false
        end
    end
    
    if not input.IsMouseDown(MOUSE_LEFT) then
        editor._fileMenuClicked = false
    end
    
    return false
end

--[[
    顶部视图菜单：按钮切换、菜单项执行与点击外部关闭。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，菜单为常驻窗口级交互
]]
local function ActionViewMenu(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    -- 处理视图菜单交互
    local mouseOverViewMenu = false
    local mouseOverViewBtn = false
    
    if editor._viewBtnRect then
        mouseOverViewBtn = INE:IsPointInRect(mouseX, mouseY, editor._viewBtnRect)
        if editor._viewMenuRect and editor._viewMenuOpen then
            mouseOverViewMenu = INE:IsPointInRect(mouseX, mouseY, editor._viewMenuRect)
        end
    end
    
    -- 如果鼠标在视图菜单上，阻止底层操作
    if mouseOverViewMenu then
        editor._mouseOverOverlayWindow = true
    end
    
    -- 处理视图菜单按钮点击
    if input.IsMouseDown(MOUSE_LEFT) and not editor._viewMenuClicked then
        editor._viewMenuClicked = true
        
        if mouseOverViewBtn then
            -- 点击视图按钮，切换菜单状态
            editor._viewMenuOpen = not editor._viewMenuOpen
        elseif mouseOverViewMenu then
            -- 点击菜单区域
            if editor._viewMenuHoveredItem > 0 then
                -- 点击了菜单项，执行对应操作
                local itemIndex = editor._viewMenuHoveredItem
                editor._viewMenuOpen = false
                INE:ExecuteViewMenuItem(editor, itemIndex)
            end
            -- 点击菜单空白区域，不做任何操作，保持菜单打开
        else
            -- 点击其他区域（非按钮、非菜单），关闭菜单
            editor._viewMenuOpen = false
        end
    end
    
    if not input.IsMouseDown(MOUSE_LEFT) then
        editor._viewMenuClicked = false
    end
    
    return false
end

--[[
    标题栏关闭按钮：按下与释放成对检测，关闭成功时消费输入。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 关闭编辑器时返回 true
]]
local function ActionCloseButton(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    -- 处理关闭按钮点击（非简化、非无边框模式）
    -- 使用按下-释放检测，确保单击即可关闭，避免持续按住才能关闭的假象
    if not editor.simplified and not editor.borderless and not editor._mouseOverOverlayWindow then
        local closeBtnX = editor.x + editor.width - 35
        local closeBtnY = editor.y + 5
        local closeBtnW = 25
        local closeBtnH = 25
        local onCloseBtn = mouseX >= closeBtnX and mouseX <= closeBtnX + closeBtnW and
                           mouseY >= closeBtnY and mouseY <= closeBtnY + closeBtnH
        
        if onCloseBtn and input.IsMouseDown(MOUSE_LEFT) and not editor._closeBtnPressed then
            editor._closeBtnPressed = true
        end
        
        if editor._closeBtnPressed and not input.IsMouseDown(MOUSE_LEFT) then
            editor._closeBtnPressed = false
            if onCloseBtn then
                -- 当 INE 编辑器嵌入在卡牌编辑器中使用时，关闭按钮改为关闭整个卡牌编辑器面板，
                -- 避免 DrawEffectEditor 在下一帧立即重新创建该编辑器导致按钮“按住才关闭”的现象
                if editor.id == "card_effect_editor" and KARDS.CardEditor.Canvas and KARDS.CardEditor.Canvas.CloseEditor then
                    local success, err = pcall(KARDS.CardEditor.Canvas.CloseEditor)
                    if not success then
                        INE:CloseEditor(editor.id)
                    end
                else
                    INE:CloseEditor(editor.id)
                end
                return true
            end
        end
    elseif not input.IsMouseDown(MOUSE_LEFT) then
        editor._closeBtnPressed = false
    end

    return false
end

--[[
    标题栏拖拽：按起点偏移更新编辑器位置，释放时记录终点位置。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，拖拽为持续状态
]]
local function ActionTitleDrag(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    -- 拖拽中更新位置（由 Think 预扫描启动，此处仅做更新与释放）
    if editor._titleDragging then
        if input.IsMouseDown(MOUSE_LEFT) then
            local dx = mouseX - editor._titleDragStartX
            local dy = mouseY - editor._titleDragStartY
            editor.x = editor._titleDragStartEditorX + dx
            editor.y = editor._titleDragStartEditorY + dy
        else
            editor._titleDragging = false
            -- 保存拖拽结束时的位置，供外部（如 DrawEffectEditor）使用
            editor._dragEndX = editor.x
            editor._dragEndY = editor.y
        end
    end

    return false
end

--[[
    节点选择面板：页签切换、高级上拉框、节点拖拽创建与变量页交互。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，面板为常驻窗口级交互
]]
local function ActionNodePalette(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    -- 处理节点选择面板的点击（非无边框模式）
    if not editor.borderless and not editor._mouseOverOverlayWindow then
        local selectorX = editor.x + 5
        local selectorY = editor.y + 45  -- 与绘制保持一致（cl_ine_variable_dialogs.lua DrawEditor：contentY=y+40，selectorY=contentY+5=y+45）
        local selectorW = 150
        
        -- 处理页面切换单选按钮点击
        local toggleY = selectorY + 24
        local toggleH = 18
        local toggleW = (selectorW - 16) / 2
        local toggleX1 = selectorX + 6
        local toggleX2 = selectorX + 6 + toggleW
        
        if input.IsMouseDown(MOUSE_LEFT) and not editor._mouseDown then
            if mouseX >= toggleX1 and mouseX <= toggleX1 + toggleW and
               mouseY >= toggleY and mouseY <= toggleY + toggleH then
                editor.selectorPage = "nodes"
                editor._mouseDown = true
            elseif mouseX >= toggleX2 and mouseX <= toggleX2 + toggleW and
                   mouseY >= toggleY and mouseY <= toggleY + toggleH then
                if editor.selectorPage == "variables" then
                    editor._allVarMode = not editor._allVarMode
                else
                    editor.selectorPage = "variables"
                end
                editor._mouseDown = true
            end
        end
        
        if editor.selectorPage == "nodes" then
            -- 计算"高级"上拉框固定基础变量节点数量与占用高度（与 cl_ine_variable_dialogs.lua 绘制侧保持一致）
            local advCount = INE:GetAdvVarOpCount(editor)
            local advBoxH = advCount > 0 and (advCount * 50 + (advCount - 1) * 10) or 0
            local advBtnH = 24
            local advBtnW = selectorW - 12
            local advBtnX = selectorX + 6
            local advBtnY = selectorY + (editor.borderless and editor.height or (editor.height - 45)) - 10 - advBtnH - 4
            -- 展开时按钮上移（上移量 = 上拉框高度），上拉框占据按钮下方到面板底部的区域
            if editor._advPanelOpen then advBtnY = advBtnY - advBoxH end

            -- 节点选择页：处理节点拖拽创建（考虑滚动偏移，跳过不可见节点与基础变量节点）
            local nodeListStartY = selectorY + 48
            local nodeListEndY = selectorY + (editor.borderless and editor.height or (editor.height - 45)) - 10
            -- 展开"高级"上拉框时，主列表底部让位于上拉框与按钮
            if editor._advPanelOpen then
                nodeListEndY = nodeListEndY - advBoxH - advBtnH - 8
            end

            -- 命中检测按绘制层级从上到下：先"高级"按钮与上拉框固定节点，再主节点列表。
            -- 主列表条目的命中矩形未按滚动裁剪区裁剪（完整 50 高），会延伸到"高级"按钮/上拉框区域，
            -- 若主列表优先会被误判为拖出节点，导致点击"高级"穿透失败。

            -- "高级"按钮：点击切换上拉框展开/收起（固定基础变量节点区）
            if input.IsMouseDown(MOUSE_LEFT) and not editor._mouseDown then
                if mouseX >= advBtnX and mouseX <= advBtnX + advBtnW and
                   mouseY >= advBtnY and mouseY <= advBtnY + advBtnH then
                    editor._advPanelOpen = not editor._advPanelOpen
                    editor._mouseDown = true
                end
            end

            -- 上拉框固定基础变量节点：展开时支持拖拽创建（与主列表条目行为一致）
            if editor._advPanelOpen and advCount > 0 then
                local advListY = advBtnY + advBtnH
                for _, advEntry in ipairs(INE:GetAdvVarOpNodes()) do
                    local template = advEntry.template
                    if template then
                        if mouseX >= selectorX + 10 and mouseX <= selectorX + selectorW - 10 and
                           mouseY >= advListY and mouseY <= advListY + 50 then
                            if input.IsMouseDown(MOUSE_LEFT) and not editor._mouseDown then
                                editor.tempNode = advEntry.name
                                editor._mouseDown = true
                            end
                        end
                        advListY = advListY + 50 + 10
                    end
                end
            end

            -- 主节点列表（最下层）：处理节点拖拽创建
            local nodeListY = nodeListStartY - editor.selectorScrollOffset
            for _, nodeName in ipairs(editor.allowedNodes) do
                local template = INE.RegisteredNodes[nodeName]
                if template and not template.isStartNode and not template._varOpNode then
                    local nodeEntryH = 50
                    -- 仅在可见区域内检测点击
                    if nodeListY + nodeEntryH >= nodeListStartY and nodeListY <= nodeListEndY then
                        if mouseX >= selectorX + 10 and mouseX <= selectorX + selectorW - 10 and
                           mouseY >= nodeListY and mouseY <= nodeListY + nodeEntryH then
                            if input.IsMouseDown(MOUSE_LEFT) and not editor._mouseDown then
                                editor.tempNode = nodeName
                                editor._mouseDown = true
                            end
                        end
                    end
                    nodeListY = nodeListY + nodeEntryH + 10
                end
            end
        else
            -- 变量页：处理变量列表交互
            if input.IsMouseDown(MOUSE_LEFT) and not editor._mouseDown then
                -- 从上一帧绘制的 _interactiveRects 中查找点击
                if editor._interactiveRects then
                    for key, rect in pairs(editor._interactiveRects) do
                        if INE:IsPointInRect(mouseX, mouseY, rect) then
                            local handled = false
                            
                            -- [+]/[▲▼] 按钮和类型标题头点击
                            if type(key) ~= "string" then
                                -- 跳过非字符串键（如 DrawComponents 注册的数字索引条目）
                            elseif key:find("^var_add_") then
                                local typeId = key:sub(9)
                                -- 懒初始化：确保该类型的变量列表存在（使用编辑器实例独立的变量数据）
                                if not editor.variables[typeId] then editor.variables[typeId] = {} end
                                local vars = editor.variables[typeId]
                                local newName = typeId .. "_var_" .. (#vars + 1)
                                if typeId == "n" then
                                    -- 数字变量：创建并弹出编辑窗口
                                    local varData = {name = newName, desc = "", internalName = "", initialValue = 0, scope = "global"}
                                    table.insert(vars, varData)
                                    editor.expandedVarTypes[typeId] = true
                                    editor._numVarDialogIdx = #vars
                                    editor._numVarDialogIsNew = true
                                    INE:ShowNumberVarDialog(editor, #vars, varData)
                                elseif typeId == "f" then
                                    -- 函数变量：弹出确认对话框，让用户编辑名称和参数
                                    local varData = {name = newName, desc = "", params = {}, scope = "global"}
                                    table.insert(vars, varData)
                                    editor.expandedVarTypes[typeId] = true
                                    editor._numVarDialogIdx = #vars
                                    editor._numVarDialogIsNew = true
                                    INE:ShowFuncVarDialog(editor, #vars)
                                elseif typeId == "g" then
                                    -- 数组变量：弹出创建对话框
                                    local varData = {name = newName, desc = "", internalName = "", items = {}, scope = "global"}
                                    table.insert(vars, varData)
                                    editor.expandedVarTypes[typeId] = true
                                    editor._numVarDialogIdx = #vars
                                    editor._numVarDialogIsNew = true
                                    INE:ShowArrayVarDialog(editor, #vars)
                                elseif typeId == "e" then
                                    -- 卡牌对象变量：弹出创建对话框
                                    local varData = {name = newName, internalName = "", _mode = "empty", scope = "global"}
                                    table.insert(vars, varData)
                                    editor.expandedVarTypes[typeId] = true
                                    editor._numVarDialogIdx = #vars
                                    editor._numVarDialogIsNew = true
                                    INE:ShowCardVarDialog(editor, #vars)
                                elseif typeId == "t" then
                                    -- 字符串变量：弹出创建对话框
                                    local varData = {name = newName, internalName = "", initialValue = "", scope = "global"}
                                    table.insert(vars, varData)
                                    editor.expandedVarTypes[typeId] = true
                                    editor._stringVarDialogIdx = #vars
                                    editor._stringVarDialogIsNew = true
                                    INE:ShowStringVarDialog(editor, #vars, varData)
                                elseif typeId == "p" then
                                    -- 布尔值变量：弹出创建对话框
                                    local varData = {name = newName, internalName = "", initialValue = false, scope = "global"}
                                    table.insert(vars, varData)
                                    editor.expandedVarTypes[typeId] = true
                                    editor._boolVarDialogIdx = #vars
                                    editor._boolVarDialogIsNew = true
                                    INE:ShowBoolVarDialog(editor, #vars, varData)
                                else
                                    table.insert(vars, {name = newName, desc = ""})
                                    -- 其他类型自动展开以显示新变量
                                    editor.expandedVarTypes[typeId] = true
                                end
                                handled = true
                            elseif key:find("^var_exp_") then
                                local typeId = key:sub(9)
                                editor.expandedVarTypes[typeId] = not editor.expandedVarTypes[typeId]
                                handled = true
                            elseif key:find("^var_item_") then
                                -- 变量条目点击：先选中，已选中的再次点击则编辑
                                if editor._selectedVarItem == key then
                                    -- 已选中则编辑（当前卡牌/卡牌专属固定变量是内置变量，不可编辑）
                                    if rect.isCurrentCard or rect.isFixed then
                                        editor._selectedVarItem = nil
                                    elseif rect.varType == "f" then
                                        INE:OpenFunctionSubEditor(editor, rect.varName)
                                        if not editor._allVarMode then editor._selectedVarItem = nil end
                                    elseif rect.varType == "n" then
                                        local vars = editor.variables["n"] or {}
                                        local vi = rect.varIndex
                                        if vars[vi] then
                                            editor._numVarDialogIdx = vi
                                            editor._numVarDialogIsNew = false
                                            INE:ShowNumberVarDialog(editor, vi, vars[vi])
                                        end
                                    elseif rect.varType == "g" then
                                        -- 数组变量：打开编辑对话框
                                        editor._numVarDialogIdx = rect.varIndex
                                        editor._numVarDialogIsNew = false
                                        INE:ShowArrayVarDialog(editor, rect.varIndex)
                                    elseif rect.varType == "e" then
                                        -- 卡牌对象变量：打开编辑对话框
                                        editor._numVarDialogIdx = rect.varIndex
                                        editor._numVarDialogIsNew = false
                                        -- 从已有数据恢复选中状态
                                        local eVar = (editor.variables["e"] or {})[rect.varIndex]
                                        if eVar and eVar._mode == "saved" and eVar.cardFile then
                                            editor._cardVarSelectedFile = eVar.cardFile
                                        else
                                            editor._cardVarSelectedFile = nil
                                        end
                                        INE:ShowCardVarDialog(editor, rect.varIndex)
                                    elseif rect.varType == "t" then
                                        -- 字符串变量：打开编辑对话框
                                        editor._stringVarDialogIdx = rect.varIndex
                                        editor._stringVarDialogIsNew = false
                                        INE:ShowStringVarDialog(editor, rect.varIndex)
                                    elseif rect.varType == "p" then
                                        -- 布尔值变量：打开编辑对话框
                                        editor._boolVarDialogIdx = rect.varIndex
                                        editor._boolVarDialogIsNew = false
                                        INE:ShowBoolVarDialog(editor, rect.varIndex)
                                    end
                                else
                                    -- 未选中则先选中
                                    editor._selectedVarItem = key
                                end
                                handled = true
                            elseif key:find("^param_item_") then
                                -- 参数条目点击：选中/取消选中
                                if editor._selectedVarItem == key then
                                    editor._selectedVarItem = nil
                                else
                                    editor._selectedVarItem = key
                                end
                                handled = true
                            elseif key:find("^lib_var_") then
                                -- 选择库变量（用于后续设为默认/解除默认）
                                editor._selectedVarItem = key
                                editor._selectedLibVar = rect
                                handled = true
                            elseif key == "lib_set_default" then
                                -- 设为默认：将选中变量保存到默认变量存储
                                if editor._selectedLibVar and editor._selectedLibVar.path then
                                    local defaults = KARDS.CardEditor.SaveSystem.LoadData("ine_default_vars") or {}
                                    defaults[editor._selectedLibVar.path] = {
                                        path = editor._selectedLibVar.path,
                                        name = editor._selectedLibVar.varName,
                                        varType = editor._selectedLibVar.varType
                                    }
                                    KARDS.CardEditor.SaveSystem.SaveData(defaults, "ine_default_vars")
                                    INE:AddNotification(editor, "已设为默认变量: " .. editor._selectedLibVar.path, Color(100, 255, 100), 2)
                                end
                                handled = true
                            elseif key == "lib_unset_default" then
                                -- 解除默认：从默认变量存储中移除
                                if editor._selectedLibVar and editor._selectedLibVar.path then
                                    local defaults = KARDS.CardEditor.SaveSystem.LoadData("ine_default_vars") or {}
                                    if defaults[editor._selectedLibVar.path] then
                                        defaults[editor._selectedLibVar.path] = nil
                                        KARDS.CardEditor.SaveSystem.SaveData(defaults, "ine_default_vars")
                                        INE:AddNotification(editor, "已解除默认: " .. editor._selectedLibVar.path, Color(255, 200, 100), 2)
                                    end
                                end
                                handled = true
                            end
                            
                            if handled then
                                editor._mouseDown = true
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    
    return false
end

-- 画布层动作共用的网格吸附
local GRID_SIZE = 20
local function SnapToGrid(value)
    return math.Round(value / GRID_SIZE) * GRID_SIZE
end

--[[
    计算画布矩形、鼠标是否在画布内、是否在标题栏按钮区域。
    画布层动作共用的前置派生值，等价于拆分前 legacy 顶部的同名计算。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {table, boolean, boolean} 画布矩形、是否在画布内、是否在标题栏
]]
local function GetCanvasGeometry(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    local canvasRect = INE:GetCanvasRect(editor)
    local canvasX, canvasY = canvasRect.x, canvasRect.y
    local canvasW, canvasH = canvasRect.w, canvasRect.h
    local inCanvas = mouseX >= canvasX and mouseX <= canvasX + canvasW and
                     mouseY >= canvasY and mouseY <= canvasY + canvasH
    local onTitleBar = false
    if not editor.borderless then
        -- 文件按钮区域
        if mouseX >= editor.x + 200 and mouseX <= editor.x + 260 and mouseY >= editor.y + 5 and mouseY <= editor.y + 30 then
            onTitleBar = true
        end
        -- 视图按钮区域
        if mouseX >= editor.x + 270 and mouseX <= editor.x + 330 and mouseY >= editor.y + 5 and mouseY <= editor.y + 30 then
            onTitleBar = true
        end
        -- 关闭按钮区域
        if not editor.simplified then
            if mouseX >= editor.x + editor.width - 35 and mouseX <= editor.x + editor.width - 10 and
               mouseY >= editor.y + 5 and mouseY <= editor.y + 30 then
                onTitleBar = true
            end
        end
    end
    return canvasRect, inCanvas, onTitleBar
end

--[[
    中键平移画布：按下时记录起点，按住期间按位移更新偏移，松开时结束。
    鼠标下有函数子编辑器时，只有该子编辑器自身可以平移。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，平移不消费输入
]]
local function ActionMiddlePan(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    local _, inCanvas, onTitleBar = GetCanvasGeometry(editor, ctx)

    -- 中键按下且在画布内，开始平移画布
    if ctx.middleDown and inCanvas and not onTitleBar and not editor._mouseOverOverlayWindow then
        -- 检查鼠标下是否有函数子编辑器，若有则只有该子编辑器自身可以平移
        local panMouseOverFuncEditor = false
        for _, otherEditor in pairs(INE.Editors) do
            if otherEditor._isFunctionSubEditor and not otherEditor.hidden then
                if mouseX >= otherEditor.x and mouseX <= otherEditor.x + otherEditor.width and
                   mouseY >= otherEditor.y and mouseY <= otherEditor.y + otherEditor.height then
                    panMouseOverFuncEditor = true
                    break
                end
            end
        end
        if not panMouseOverFuncEditor or editor._isFunctionSubEditor then
            if not editor._middleMouseDown then
                editor.panningCanvas = true
                editor.panStartX = mouseX
                editor.panStartY = mouseY
                editor.panStartOffsetX = editor.canvasOffsetX
                editor.panStartOffsetY = editor.canvasOffsetY
                editor._middleMouseDown = true
            end
        end
    end

    -- 画布平移中：根据鼠标位移更新画布偏移
    if editor.panningCanvas and not editor._mouseOverOverlayWindow then
        local dx = (mouseX - editor.panStartX) / editor.canvasScale
        local dy = (mouseY - editor.panStartY) / editor.canvasScale
        editor.canvasOffsetX = editor.panStartOffsetX + dx
        editor.canvasOffsetY = editor.panStartOffsetY + dy
    end

    -- 中键释放，结束平移
    if not ctx.middleDown then
        editor.panningCanvas = false
        editor._middleMouseDown = false
    end
    return false
end

--[[
    右键释放：构建节点、连线或空白处的右键菜单。
    只有从画布内按下才记录，避免画布外按下、画布内松开误触发。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，菜单构建不阻塞后续动作
]]
local function ActionRightReleaseMenu(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    local _, inCanvas = GetCanvasGeometry(editor, ctx)
    if ctx.rightDown then
        -- 只有从画布内按下才记录，避免画布外按下、画布内松开误触发
        if inCanvas and not editor._mouseOverOverlayWindow then
            editor._rightMouseDown = true
        end
    elseif editor._rightMouseDown then
        editor._rightMouseDown = false
        local openPopupMap = INE:GetOpenPopups(editor)
        if inCanvas
        and not editor._mouseOverOverlayWindow
        and not openPopupMap.CardObjectSelector
        and not openPopupMap.GlobalVarSelector
        and not editor.draggingNode
        and not editor.draggingFrom
        and not editor.draggingDataPort then
            -- 函数子编辑器覆盖时，只由最上层子编辑器处理
            local overFuncEditor = false
            if not editor._isFunctionSubEditor then
                for _, otherEditor in pairs(INE.Editors) do
                    if otherEditor._isFunctionSubEditor and not otherEditor.hidden then
                        if mouseX >= otherEditor.x and mouseX <= otherEditor.x + otherEditor.width and
                           mouseY >= otherEditor.y and mouseY <= otherEditor.y + otherEditor.height then
                            overFuncEditor = true
                            break
                        end
                    end
                end
            end
            if not overFuncEditor then
                local node = INE:GetNodeAtPosition(editor, mouseX, mouseY)
                if node and node.canDelete and not node.isStartNode then
                    INE:BuildContextMenu(editor, mouseX, mouseY, "node", node, nil, false)
                else
                    local conn, isData = INE:GetConnectionAtPosition(editor, mouseX, mouseY, 8 * editor.canvasScale)
                    if conn then
                        INE:BuildContextMenu(editor, mouseX, mouseY, "connection", nil, conn, isData)
                    else
                        INE:BuildContextMenu(editor, mouseX, mouseY, "none", nil, nil, false)
                    end
                end
                editor._selectionDeleteBtn = nil
                editor._selectionDisconnectBtn = nil
            end
        end
    end
    return false
end

--[[
    左键首次按下：维护按下锁存器、收起展开的下拉框、清理数据点下拉状态，
    并计算本帧是否进入画布交互分发。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false，仅做准备
]]
local function ActionLeftPressPrepare(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    editor._leftPressDispatch = false
    if not ctx.leftDown then return false end
    if editor._mouseDown then return false end

    -- 左键首次按下（按下瞬间）
    editor._mouseDown = true
    editor._clickStartX = mouseX
    editor._clickStartY = mouseY
    editor._dataPortClickProcessed = false
    -- 本次按下的分发状态：后续子交互依次检查，处理后置为 true
    editor._leftPressHandled = false
    editor._leftPressClickedNode = nil
    editor._leftPressClickedDataPort = false

    -- 点击展开下拉框与它自己的按钮之外的地方时收起下拉框（2026-11-08）
    -- 选项点击已在模态层处理并消费，此处只负责空白处取消
    local ddSession = editor.session
    local ddInfo = ddSession and ddSession.ExpandedDropdownInfo
    if ddInfo then
        local inExpanded = mouseX >= ddInfo.dropdownX and mouseX <= ddInfo.dropdownX + ddInfo.totalWidth
                       and mouseY >= ddInfo.dropdownY and mouseY <= ddInfo.dropdownY + (ddInfo.dropdownH or 0)
        local inMainButton = mouseX >= ddInfo.x and mouseX <= ddInfo.x + ddInfo.width
                         and mouseY >= ddInfo.y and mouseY <= ddInfo.y + ddInfo.height
        if not inExpanded and not inMainButton then
            ddSession.ExpandedDropdown = nil
            ddSession.ExpandedDropdownInfo = nil
        end
    end

    -- CardObjectSelector / GlobalVarSelector 打开时，跳过画布点击处理（浮层点击由绘制函数处理）
    local openPopups = INE:GetOpenPopups(editor)
    if openPopups.CardObjectSelector
    or openPopups.GlobalVarSelector then
        return false
    end

    -- 处理下拉框外部点击关闭（pcall 保护，Canvas 方法未定义时静默忽略）
    pcall(KARDS.CardEditor.Canvas.HandleDropdownClickOutside, KARDS.CardEditor.Canvas, mouseX, mouseY, editor.session)

    -- 点击任意处时，如果未命中特定数据点按钮/下拉框，关闭所有数据点下拉框
    -- 先记录哪些下拉框当前是展开的，防止后续使用过期 rect 误展开
    local prevDropdownActive = {}
    local prevInputDropdownActive = {}
    for _, n in ipairs(editor.nodes) do
        prevDropdownActive[n] = n.dataPortDropdownActive
        prevInputDropdownActive[n] = n.inputDataPortDropdownActive
        n.dataPortDropdownActive = false
        n.inputDataPortDropdownActive = false
    end

    -- 若点击在某个数据点多选下拉框区域内，保持它打开（支持多选连续选择）
    -- 注意：此处读取几何模块上一帧写入的矩形，因为下拉框激活状态刚被清零，
    -- 重新调用 GetPortRects 会把矩形算成 nil（ADR 0006）
    local clickInAnyDropdown = false
    for _, n in ipairs(editor.nodes) do
        if prevDropdownActive[n] and n._dataPortDropdownRect and
            mouseX >= n._dataPortDropdownRect.x and mouseX <= n._dataPortDropdownRect.x + n._dataPortDropdownRect.w and
            mouseY >= n._dataPortDropdownRect.y and mouseY <= n._dataPortDropdownRect.y + n._dataPortDropdownRect.h then
            n.dataPortDropdownActive = true
            clickInAnyDropdown = true
        end
        if prevInputDropdownActive[n] and n._inputDataPortDropdownRect and
            mouseX >= n._inputDataPortDropdownRect.x and mouseX <= n._inputDataPortDropdownRect.x + n._inputDataPortDropdownRect.w and
            mouseY >= n._inputDataPortDropdownRect.y and mouseY <= n._inputDataPortDropdownRect.y + n._inputDataPortDropdownRect.h then
            n.inputDataPortDropdownActive = true
            clickInAnyDropdown = true
        end
    end
    -- 点击在某个下拉框内时，跳过后续节点交互处理，避免干扰选项选择
    if clickInAnyDropdown then return false end

    if editor._mouseOverOverlayWindow then return false end

    local _, inCanvas, onTitleBar = GetCanvasGeometry(editor, ctx)
    -- 不在画布内、在标题栏上或正在拖拽节点，跳过节点/连线/框选交互
    if not inCanvas or onTitleBar or editor.draggingNode then return false end

    editor._leftPressDispatch = true
    return false
end

--[[
    左键按下时命中开始点的输出端口：开始拖拽连线。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false
]]
local function ActionLeftPressStartNode(editor, ctx)
    if not editor._leftPressDispatch or editor._leftPressHandled then return false end
    local mouseX, mouseY = ctx.x, ctx.y
    local startNode = INE:GetStartNodeAtPort(editor, mouseX, mouseY)
    if not startNode then return false end

    print("[DBG] 执行连接: 命中开始点端口! node=" .. startNode.id .. " title=" .. tostring(startNode.data and startNode.data.title))
    -- 点击到开始点的输出端口：开始拖拽连线
    local hasSelectedOutput = editor.selectedOutputs and #editor.selectedOutputs > 0
    if hasSelectedOutput then
        -- 已有选中输出点：清除
        editor.selectedOutputs = {}
    end
    editor.draggingFrom = {node = startNode, port = "output"}
    editor.selectedNodes = {}
    editor._leftPressHandled = true
    return false
end

--[[
    左键按下时命中数据点图标：开始拖拽数据点连线，并关闭其他节点的下拉框。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false
]]
local function ActionLeftPressDataPort(editor, ctx)
    if not editor._leftPressDispatch or editor._leftPressHandled then return false end
    local mouseX, mouseY = ctx.x, ctx.y
    -- 数据点图标位于节点边线上，部分超出节点边界，GetNodeAtPosition 无法命中，需优先独立检测
    local info = INE:GetDataPortIconAtPosition(editor, mouseX, mouseY)
    if not info then return false end

    print("[DBG] 数据点按下: node=" .. info.node.id .. " type=" .. info.portType .. " idx=" .. info.portIndex .. " dataType=" .. tostring(info.portData and info.portData.id))
    editor.draggingDataPort = info
    editor._leftPressClickedDataPort = true
    -- 关闭所有节点的下拉框
    for _, otherNode in ipairs(editor.nodes) do
        otherNode.dataPortDropdownActive = false
        otherNode.inputDataPortDropdownActive = false
    end
    editor._leftPressHandled = true
    return false
end

--[[
    左键按下时命中节点：先处理数据点按钮，再处理标题拖拽与输出点选中/连接。
    数据点按钮位于节点边线上，半径超出节点边界，需先于节点体命中检测。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false
]]
local function ActionLeftPressNode(editor, ctx)
    if not editor._leftPressDispatch or editor._leftPressHandled then return false end
    local mouseX, mouseY = ctx.x, ctx.y

    -- 先检测数据点按钮（位于节点边线上，半径超出节点边界）
    local clickedNode = INE:GetDataPortButtonNodeAtPosition(editor, mouseX, mouseY)
    if not clickedNode then
        -- 检测是否点击到了普通节点（开始点已被跳过）
        clickedNode = INE:GetNodeAtPosition(editor, mouseX, mouseY)
        if clickedNode then
            print("[DBG] 执行连接: GetNodeAtPosition 命中 node=" .. clickedNode.id .. " title=" .. tostring(clickedNode.data and clickedNode.data.title) .. " type=" .. tostring(clickedNode.type) .. " isStartNode=" .. tostring(clickedNode.isStartNode))
        end
    end
    if not clickedNode then return false end

    editor._leftPressClickedNode = clickedNode
    editor._leftPressHandled = true

    -- 检测"增加数据点"按钮点击
    local clickedDataButton = false
    local clickedGeometry = KARDS.CardEditor.Geometry.GetPortRects(editor, clickedNode)
    local outputButtonRect = clickedGeometry.output.buttonRect
    if outputButtonRect and not clickedNode.isStartNode then
        if INE:IsPointInRect(mouseX, mouseY, outputButtonRect) then
            if #clickedNode.availableOutputTypes == 1 then
                -- 仅一种类型：直接全选/取消全选，不展开下拉框
                if #clickedNode.selectedOutputTypes == 0 then
                    table.insert(clickedNode.selectedOutputTypes, clickedNode.availableOutputTypes[1])
                else
                    clickedNode.selectedOutputTypes = {}
                    -- 清理与该节点相关的所有输出数据连接
                    if editor.dataConnections then
                        local i = 1
                        while i <= #editor.dataConnections do
                            local dc = editor.dataConnections[i]
                            if dc.fromNode == clickedNode.id then
                                table.remove(editor.dataConnections, i)
                            else
                                i = i + 1
                            end
                        end
                    end
                end
            else
                clickedNode.dataPortDropdownActive = not clickedNode.dataPortDropdownActive
            end
            clickedDataButton = true
        end
    end

    local inputButtonRect = clickedGeometry.input.buttonRect
    if not clickedDataButton and inputButtonRect and not clickedNode.isStartNode then
        if INE:IsPointInRect(mouseX, mouseY, inputButtonRect) then
            if #clickedNode.availableInputTypes == 1 then
                -- 仅一种类型：直接全选/取消全选，不展开下拉框
                if #clickedNode.selectedInputTypes == 0 then
                    table.insert(clickedNode.selectedInputTypes, clickedNode.availableInputTypes[1])
                else
                    clickedNode.selectedInputTypes = {}
                    -- 清理与该节点相关的所有输入数据连接
                    if editor.dataConnections then
                        local i = 1
                        while i <= #editor.dataConnections do
                            local dc = editor.dataConnections[i]
                            if dc.toNode == clickedNode.id then
                                table.remove(editor.dataConnections, i)
                            else
                                i = i + 1
                            end
                        end
                    end
                end
            else
                clickedNode.inputDataPortDropdownActive = not clickedNode.inputDataPortDropdownActive
            end
            clickedDataButton = true
        end
    end

    -- 如果点击了数据点按钮，不进行后续节点操作
    if clickedDataButton then
        -- 关闭其他节点的下拉框
        for _, otherNode in ipairs(editor.nodes) do
            if otherNode ~= clickedNode then
                otherNode.dataPortDropdownActive = false
                otherNode.inputDataPortDropdownActive = false
            end
        end
        return false
    end

    -- 没有点击数据点按钮，继续正常的节点交互逻辑
    -- 检查是否点在标题栏区域（用于拖拽）
    local onTitle = INE:IsMouseOnNodeTitle(editor, clickedNode, mouseX, mouseY)

    if onTitle and not clickedNode.isStartNode then
        -- 点在标题栏上：开始拖拽节点（不选中输出点）
        clickedNode.dragging = true
        clickedNode.dragStartX = mouseX
        clickedNode.dragStartY = mouseY
        clickedNode.startX = clickedNode.x
        clickedNode.startY = clickedNode.y
        editor.draggingNode = clickedNode
        editor.selectedOutputs = {}  -- 清除输出点选择
        return false
    end

    -- 点在节点非标题区域：执行输出点选中/连接逻辑
    local hasSelectedOutput = editor.selectedOutputs and #editor.selectedOutputs > 0

    if hasSelectedOutput then
        -- 检查是否点击在交互元素上，若是则不做连接操作
        if INE:GetNodeInteractiveElement(editor, clickedNode, mouseX, mouseY) then
            -- 点击在交互元素上，保持选择状态，不进行连接
        elseif clickedNode.hasInput then
            local fromOutput = editor.selectedOutputs[1]  -- 当前只支持单选
            local fromNode = fromOutput.node
            local toNode = clickedNode

            -- 如果点击的是同一个双输出节点：循环切换输出端口
            if fromNode == toNode and clickedNode.hasSecondOutput then
                if fromOutput.port == "satisfied" then
                    editor.selectedOutputs = {{node = clickedNode, port = "not_satisfied"}}
                else
                    editor.selectedOutputs = {}
                end
            else
                -- 点击到不同的有输入点节点：建立连接
                print("[DBG] 执行连接: hasSelectedOutput true fromNode.id=" .. fromNode.id .. "(" .. tostring(fromNode.data and fromNode.data.title) .. ") isStartNode=" .. tostring(fromNode.isStartNode) .. " toNode.id=" .. toNode.id .. "(" .. tostring(toNode.data and toNode.data.title) .. ") isStartNode=" .. tostring(toNode.isStartNode))

                -- 禁止自连接
                if fromNode.id ~= toNode.id then
                    -- 「激活时」开始点只能连接事件监测或注册钩子节点（反制画布连接约束）
                    local connOK, connMsg = INE.ValidateCounterStartConnection(fromNode, toNode)
                    if not connOK then
                        INE:AddNotification(editor, connMsg, Color(200, 100, 100), 3)
                    else
                        print("[DBG] 执行连接: 检查连接 from=" .. fromNode.id .. " to=" .. toNode.id)
                        -- 检查连接是否已存在
                        local exists = false
                        for _, conn in ipairs(editor.connections) do
                            if conn.fromNode == fromNode.id and conn.toNode == toNode.id then
                                exists = true
                                break
                            end
                        end
                        if not exists then
                            print("[DBG] 执行连接: 创建连接! from=" .. fromNode.id .. "(" .. (fromNode.data and fromNode.data.title or "?") .. ") -> to=" .. toNode.id .. "(" .. (toNode.data and toNode.data.title or "?") .. ")")
                            -- 创建新连接
                            table.insert(editor.connections, {
                                id = INE:GenerateConnectionID(),
                                fromNode = fromNode.id,
                                toNode = toNode.id,
                                fromPort = fromOutput.port or "output"
                            })
                            if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayConnect then
                                KARDS.CardEditor.Audio.PlayConnect()
                            end
                        end
                    end
                else
                    INE:AddNotification(editor, "同一个节点上不能连接两点！", Color(200, 100, 100), 3)
                end
                -- 连接完成后清除选中状态
                editor.selectedOutputs = {}
            end
        else
            -- 点击到没有输入点的节点：取消选择
            editor.selectedOutputs = {}
        end
        return false
    end

    -- 没有输出点被选中：检查是否点击在输出端口上（拖拽连线）或节点体上（选中输出点）
    if clickedNode.hasOutput and not clickedNode.isUnregistered then
        -- 检测是否精确点击到输出端口圆点
        local port = INE:GetOutputPortAtPosition(editor, clickedNode, mouseX, mouseY)
        if port then
            -- 精确点击到输出端口：开始拖拽连线（按住并移动到输入点松开）
            print("[DBG] 执行连接: 按下输出端口 node=" .. clickedNode.id .. " port=" .. tostring(port))
            editor.draggingFrom = {node = clickedNode, port = port}
            editor.selectedOutputs = {}  -- 清除旧的输出点选中
            editor.selectedNodes = {}
        elseif INE:IsMouseOnNodeBody(editor, clickedNode, mouseX, mouseY) then
            -- 检查是否点击在交互元素（下拉框、数字框）上，若是则不选中输出点
            if not INE:GetNodeInteractiveElement(editor, clickedNode, mouseX, mouseY) then
                -- 点击在节点体上（非端口、非标题、非元素）：选中该节点的输出点
                print("[DBG] 执行连接: 选中输出点 node=" .. clickedNode.id)
                local defaultPort = clickedNode.hasSecondOutput and "satisfied" or "output"
                editor.selectedOutputs = {{node = clickedNode, port = defaultPort}}
                editor.selectedNodes = {}
            end
        end
    end
    return false
end

--[[
    左键按下时未命中任何节点：取消输出点选中，或开始框选。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false
]]
local function ActionLeftPressEmpty(editor, ctx)
    if not editor._leftPressDispatch or editor._leftPressHandled or editor._leftPressClickedNode then return false end
    local mouseX, mouseY = ctx.x, ctx.y
    if editor.selectedOutputs and #editor.selectedOutputs > 0 then
        -- 有输出点被选中：取消选择
        editor.selectedOutputs = {}
    elseif not editor._leftPressClickedDataPort then
        -- 没有输出点被选中且没有点击数据点：开始框选
        editor.isSelecting = true
        editor.selectionStartX = mouseX
        editor.selectionStartY = mouseY
        editor.selectedNodes = {}
        editor._selectionDeleteBtn = nil
        editor._selectionDisconnectBtn = nil
    end
    return false
end

--[[
    左键按住期间拖拽节点：按位移更新节点位置并吸附网格。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false
]]
local function ActionLeftDragUpdate(editor, ctx)
    if not ctx.leftDown then return false end
    if editor.draggingNode and not editor._mouseOverOverlayWindow then
        local node = editor.draggingNode
        local mouseX, mouseY = ctx.x, ctx.y
        local dx = (mouseX - node.dragStartX) / editor.canvasScale
        local dy = (mouseY - node.dragStartY) / editor.canvasScale
        node.x = SnapToGrid(node.startX + dx)
        node.y = SnapToGrid(node.startY + dy)
    end
    return false
end

--[[
    左键释放：完成连线、数据点连接、节点拖拽落点、临时节点创建与框选收尾。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false
]]
local function ActionLeftRelease(editor, ctx)
    if ctx.leftDown then return false end
    local mouseX, mouseY = ctx.x, ctx.y
    local canvasRect = INE:GetCanvasRect(editor)
    local canvasX = canvasRect.x

    if INE:GetOpenPopups(editor).CardObjectSelector then
        -- CardObjectSelector 打开时，仅重置鼠标状态，跳过所有画布释放操作
        if editor._mouseDown then
            editor._mouseDown = false
        end
        if editor.draggingNode then
            editor.draggingNode.dragging = false
            editor.draggingNode = nil
        end
        if editor.draggingFrom then
            editor.draggingFrom = nil
        end
        if editor.draggingDataPort then
            editor.draggingDataPort = nil
        end
        editor.tempNode = nil
        editor.isSelecting = false
        return false
    end

    -- 左键释放处理
    if editor._mouseDown then
        editor._mouseDown = false

        -- 处理拖拽连线释放：检查是否在输入端口上松开
        if editor.draggingFrom then
            local fromNode = editor.draggingFrom.node
            local fromPort = editor.draggingFrom.port
            print("[DBG] 执行连接: 释放拖拽 fromNode=" .. fromNode.id .. "(" .. (fromNode.data and fromNode.data.title or "?") .. ") port=" .. tostring(fromPort))
            local toNode = INE:GetInputNodeAtPosition(editor, mouseX, mouseY)
            if toNode then
                print("[DBG] 执行连接: 释放找到目标 toNode=" .. toNode.id .. "(" .. (toNode.data and toNode.data.title or "?") .. ")")
                -- 在输入端口上松开：创建连接
                if fromNode.id ~= toNode.id then
                    -- 「激活时」开始点只能连接事件监测或注册钩子节点（反制画布连接约束）
                    local connOK, connMsg = INE.ValidateCounterStartConnection(fromNode, toNode)
                    if not connOK then
                        INE:AddNotification(editor, connMsg, Color(200, 100, 100), 3)
                    else
                        local exists = false
                        for _, conn in ipairs(editor.connections) do
                            if conn.fromNode == fromNode.id and conn.toNode == toNode.id then
                                exists = true
                                break
                            end
                        end
                        if not exists then
                            print("[DBG] 执行连接: 拖拽创建连接! from=" .. fromNode.id .. " -> to=" .. toNode.id)
                            table.insert(editor.connections, {
                                id = INE:GenerateConnectionID(),
                                fromNode = fromNode.id,
                                toNode = toNode.id,
                                fromPort = fromPort or "output"
                            })
                            if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayConnect then
                                KARDS.CardEditor.Audio.PlayConnect()
                            end
                        end
                    end
                else
                    INE:AddNotification(editor, "同一个节点上不能连接两点！", Color(200, 100, 100), 3)
                end
            else
                print("[DBG] 执行连接: 释放未找到目标输入端口")
            end
            editor.draggingFrom = nil
            -- 如果只点击了输出端口但没有拖动（快速点击），选中输出点
        end

        -- 处理数据点拖拽释放：检查是否在兼容的数据点上松开
        if editor.draggingDataPort then
            local fromPort = editor.draggingDataPort
            print("[DBG] 数据点释放: from node=" .. fromPort.node.id .. " type=" .. fromPort.portType .. " idx=" .. fromPort.portIndex)
            local toPort = INE:GetDataPortAtPosition(editor, mouseX, mouseY, fromPort.portType)
            if toPort then
                print("[DBG] 数据点释放: 找到目标 node=" .. toPort.node.id .. " type=" .. toPort.portType .. " idx=" .. toPort.portIndex .. " dataType=" .. tostring(toPort.portData and toPort.portData.id))
            else
                print("[DBG] 数据点释放: 未找到目标数据点")
            end
            if toPort and toPort.node ~= fromPort.node then
                -- 检查数据类型兼容性
                -- 兼容多种端口格式：{id=} / {type=}（如"钳击对象"数据源端口）/ 类型引用 / 字符串
                local fromTypeId = fromPort.portData.id or fromPort.portData.type or fromPort.portData
                local toTypeId = toPort.portData.id or toPort.portData.type or toPort.portData
                local fromType = INE.GetDataTypeById(fromTypeId)
                local toType = INE.GetDataTypeById(toTypeId)

                if fromType and toType and fromType.id == toType.id then
                    -- 数据类型匹配，创建数据连接
                    print("[DBG] 数据点连接: 类型匹配 " .. fromType.id .. " -> " .. toType.id)
                    local exists = false
                    for _, conn in ipairs(editor.dataConnections) do
                        if conn.fromNode == fromPort.node.id and conn.toNode == toPort.node.id
                           and conn.fromPortIndex == fromPort.portIndex and conn.toPortIndex == toPort.portIndex then
                            exists = true
                            break
                        end
                    end
                    if not exists then
                        editor.dataConnectionCounter = editor.dataConnectionCounter + 1
                        -- 获取变量名（来自输出端口自定义名称，如"循环次数"）
                        local variableName = nil
                        if fromPort.portData and fromPort.portData.name and fromPort.portData.name ~= fromType.name then
                            variableName = fromPort.portData.name
                        elseif fromPort.portData and fromPort.portData.name then
                            variableName = fromPort.portData.name
                        end
                        table.insert(editor.dataConnections, {
                            id = "data_conn_" .. editor.dataConnectionCounter,
                            fromNode = fromPort.node.id,
                            toNode = toPort.node.id,
                            fromPortIndex = fromPort.portIndex,
                            toPortIndex = toPort.portIndex,
                            dataType = fromType.id,
                            variableName = variableName  -- 存储变量名供数字槽引用
                        })
                        print("[DBG] 数据点连接: 成功创建! id=data_conn_" .. editor.dataConnectionCounter)
                        if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayConnect then
                            KARDS.CardEditor.Audio.PlayConnect()
                        end
                        -- "判断变量关系"节点：数据线接入时自动创建/填充比较项（左侧值 = 刚接入的值）
                        local vop = KARDS.CardEditor.VarOpNodes
                        if vop and vop.EvalAutoFillLeft and toPort.node.type == "var_evaluate" then
                            vop.EvalAutoFillLeft(editor, toPort.node,
                                "data_conn_" .. editor.dataConnectionCounter,
                                fromType.id, variableName or fromType.name)
                        end
                        -- "设置变量"节点：数据线接入时自动创建设置行（templates.md L1147"数据线接入"）
                        if vop and vop.SetAutoFillFromWire and toPort.node.type == "var_set" then
                            vop.SetAutoFillFromWire(editor, toPort.node,
                                "data_conn_" .. editor.dataConnectionCounter,
                                fromType.id, variableName or fromType.name)
                        end
                    else
                        print("[DBG] 数据点连接: 连接已存在")
                    end
                else
                    print("[DBG] 数据点连接: 类型不匹配 from=" .. tostring(fromType and fromType.id) .. " to=" .. tostring(toType and toType.id))
                    INE:AddNotification(editor, "数据类型不匹配！", Color(200, 100, 100), 3)
                end
            end
            editor.draggingDataPort = nil
        end

        -- 清除节点拖拽状态
        if editor.draggingNode then
            editor.draggingNode.dragging = false
            editor.draggingNode = nil
        end

        -- 如果有临时拖拽的节点且鼠标已离开选择面板区域，在画布上创建节点
        if editor.tempNode and not editor._mouseOverOverlayWindow and not INE:IsPointInRect(mouseX, mouseY, {x=editor.x+5, y=editor.y+45, w=150, h=editor.height-55}) then
            -- 将屏幕坐标转换为画布本地坐标
            local canvasLocalX, canvasLocalY = INE:ScreenToWorld(editor, mouseX, mouseY)

            -- 仅在画布区域内创建节点
            if mouseX >= canvasX then
                local newNodeX = SnapToGrid(canvasLocalX - 100)
                local newNodeY = SnapToGrid(canvasLocalY - 40)
                local newNode = INE:CreateNewNodeInstance(editor.tempNode, editor, newNodeX, newNodeY)
                table.insert(editor.nodes, newNode)
                if KARDS.CardEditor.Audio and KARDS.CardEditor.Audio.PlayDragNewNode then
                    KARDS.CardEditor.Audio.PlayDragNewNode()
                end
            end
        end
        editor.tempNode = nil
    end

    -- 处理框选：选中选区内的所有节点
    if editor.isSelecting then
        local rect = INE:GetCanvasRect(editor)

        local selSX = math.max(rect.x, math.min(editor.selectionStartX, mouseX))
        local selSY = math.max(rect.y, math.min(editor.selectionStartY, mouseY))
        local selEX = math.min(rect.x + rect.w, math.max(editor.selectionStartX, mouseX))
        local selEY = math.min(rect.y + rect.h, math.max(editor.selectionStartY, mouseY))

        editor.selectedNodes = {}
        editor.selectedOutputs = {}  -- 框选时清除输出点选择
        for _, node in ipairs(editor.nodes) do
            local nodeSX, nodeSY = INE:WorldToScreen(editor, node.x, node.y)
            local nodeEX = nodeSX + node.width * editor.canvasScale
            local nodeEY = nodeSY + node.height * editor.canvasScale

            if nodeEX >= selSX and nodeSX <= selEX and
               nodeEY >= selSY and nodeSY <= selEY then
                -- 未注册的占位节点与开始点不参与框选，开始点不可删除也不可选中
                if not node.isUnregistered and not node.isStartNode then
                    table.insert(editor.selectedNodes, node)
                end
            end
        end

        -- 框选结束：有选中节点时在松手位置显示操作按钮（2026-11-08）
        -- 只在本次框选真正结束时生成，之后位置固定，避免按钮跟随鼠标
        if #editor.selectedNodes > 0 then
            local btnW, btnH = 120, 30
            local btnX = math.Clamp(mouseX + 10, 4, ScrW() - btnW - 4)
            local btnY = math.Clamp(mouseY + 10, 4, ScrH() - btnH - 4)
            editor._selectionDeleteBtn = {x = btnX, y = btnY, w = btnW, h = btnH}
            -- 断开连接按钮放在删除按钮正上方，空间不足时放在正下方
            local disconnectY = btnY - btnH - 6
            if disconnectY < 4 then
                disconnectY = btnY + btnH + 6
            end
            editor._selectionDisconnectBtn = {
                x = btnX,
                y = math.Clamp(disconnectY, 4, ScrH() - btnH - 4),
                w = btnW, h = btnH
            }
        else
            editor._selectionDeleteBtn = nil
            editor._selectionDisconnectBtn = nil
        end
    end

    -- 清除框选状态
    editor.isSelecting = false
    return false
end

--[[
    滚轮：叠加窗口列表滚动、节点选择面板与变量页滚动、画布缩放。
    顺序与拆分前一致，先处理叠加窗口与面板，最后才是画布缩放。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false
]]
local function ActionWheel(editor, ctx)
    local mouseX, mouseY = ctx.x, ctx.y
    local _, inCanvas, onTitleBar = GetCanvasGeometry(editor, ctx)

    -- 导入窗口滚轮滚动
    if editor._mouseOverOverlayWindow then
        local importWin = editor.overlayWindows and editor.overlayWindows["ine_import_window"]
        if importWin and importWin.visible then
            local files = editor._importFiles or {}
            if mouseX >= importWin.x and mouseX <= importWin.x + importWin.width and
               mouseY >= importWin.y + 30 and mouseY <= importWin.y + importWin.height then
                if INE._wheelZoomIn then
                    INE._wheelZoomIn = false
                    local maxOffset = math.max(0, #files - math.floor((importWin.height - 30 - 110) / 30))
                    editor._importScrollOffset = math.max(0, (editor._importScrollOffset or 0) - 1)
                elseif INE._wheelZoomOut then
                    INE._wheelZoomOut = false
                    local maxOffset = math.max(0, #files - math.floor((importWin.height - 30 - 110) / 30))
                    editor._importScrollOffset = math.min(maxOffset, (editor._importScrollOffset or 0) + 1)
                end
            end
        end
    end

    -- 数组变量对话框滚轮滚动
    if editor._mouseOverOverlayWindow then
        local arrayWin = editor.overlayWindows and editor.overlayWindows["ine_arrayvar_dialog"]
        if arrayWin and arrayWin.visible then
            local r = editor._arrayItemListRect
            if r and mouseX >= r.x and mouseX <= r.x + r.w and mouseY >= r.y and mouseY <= r.y + r.h then
                local varIdx = editor._arrayVarDialogVarIdx
                if varIdx then
                    local vars = editor.variables["g"] or {}
                    local vd = vars[varIdx]
                    if vd and vd.items then
                        local cy = arrayWin.y + 30
                        local ch = arrayWin.height - 10
                        local itemStartY = (cy + 115) + 18
                        local itemH = 22
                        local maxVisible = math.floor((ch - 45 - (itemStartY - cy) - 40) / itemH)
                        local maxOffset = math.max(0, #vd.items - maxVisible)
                        if INE._wheelZoomIn then
                            INE._wheelZoomIn = false
                            editor._arrayVarScrollOffset = math.max(0, (editor._arrayVarScrollOffset or 0) - 1)
                        elseif INE._wheelZoomOut then
                            INE._wheelZoomOut = false
                            editor._arrayVarScrollOffset = math.min(maxOffset, (editor._arrayVarScrollOffset or 0) + 1)
                        end
                    end
                end
            end
        end
    end

    -- 卡牌对象对话框滚轮滚动
    if editor._mouseOverOverlayWindow then
        local cardWin = editor.overlayWindows and editor.overlayWindows["ine_cardvar_dialog"]
        if cardWin and cardWin.visible then
            local r = editor._cardVarListRect
            if r and mouseX >= r.x and mouseX <= r.x + r.w and mouseY >= r.y and mouseY <= r.y + r.h then
                local infos = editor._cardVarCardInfos
                if infos and #infos > 0 then
                    local cy = cardWin.y + 30
                    local ch = cardWin.height - 10
                    local listY = cy + 70 + 20 + 32  -- modeY + 20 + 32 = radioY + 32
                    local itemH = 28
                    local maxVisible = math.floor((ch - (listY - cy) - 45 - 40) / itemH)
                    local maxOffset = math.max(0, #infos - maxVisible)
                    if INE._wheelZoomIn then
                        INE._wheelZoomIn = false
                        editor._cardVarScrollOffset = math.max(0, (editor._cardVarScrollOffset or 0) - 1)
                    elseif INE._wheelZoomOut then
                        INE._wheelZoomOut = false
                        editor._cardVarScrollOffset = math.min(maxOffset, (editor._cardVarScrollOffset or 0) + 1)
                    end
                end
            end
        end
    end

    -- 节点选择器滚轮滚动（鼠标位于节点列表区域内时，滚轮滚动列表而非缩放画布）
    if not editor.borderless and not editor._mouseOverOverlayWindow and editor.selectorPage == "nodes" then
        local selX = editor.x + 5
        local selY = editor.y + 45
        local selW = 150
        local contentH = editor.borderless and editor.height or (editor.height - 45)
        local nodeListStartY = selY + 48
        local nodeListEndY = selY + contentH - 10
        -- 展开"高级"上拉框时，主列表底部让位于上拉框与按钮（与绘制侧一致）
        if editor._advPanelOpen then
            local advCount = INE:GetAdvVarOpCount(editor)
            local advBoxH = advCount > 0 and (advCount * 50 + (advCount - 1) * 10) or 0
            nodeListEndY = nodeListEndY - advBoxH - 24 - 8
        end
        -- 检测鼠标是否在节点列表的裁剪区域内
        if mouseX >= selX + 10 and mouseX <= selX + selW - 10 and
           mouseY >= nodeListStartY and mouseY <= nodeListEndY then
            if INE._wheelZoomIn then
                INE._wheelZoomIn = false
                editor.selectorScrollOffset = editor.selectorScrollOffset - 40
            elseif INE._wheelZoomOut then
                INE._wheelZoomOut = false
                editor.selectorScrollOffset = editor.selectorScrollOffset + 40
            end
        end
    end

    -- 变量页滚轮滚动（鼠标位于变量列表区域内时）
    if not editor.borderless and not editor._mouseOverOverlayWindow and editor.selectorPage == "variables" then
        local selX = editor.x + 5
        local selY = editor.y + 45
        local selW = 150
        local contentH = editor.borderless and editor.height or (editor.height - 45)
        local varListStartY = selY + 48
        local varListEndY = selY + contentH - 10
        if mouseX >= selX + 10 and mouseX <= selX + selW - 10 and
           mouseY >= varListStartY and mouseY <= varListEndY then
            if INE._wheelZoomIn then
                INE._wheelZoomIn = false
                editor.varScrollOffset = editor.varScrollOffset - 40
            elseif INE._wheelZoomOut then
                INE._wheelZoomOut = false
                editor.varScrollOffset = editor.varScrollOffset + 40
            end
        end
    end

    -- 鼠标滚轮缩放（在画布区域内）
    -- 通过 CreateMove 中 WasMousePressed 设置的标记触发
    if inCanvas and not onTitleBar and not editor._mouseOverOverlayWindow then
        -- 检查鼠标下是否有函数子编辑器，若有则只有该子编辑器自身处理缩放
        local mouseOverFuncEditor = false
        for _, otherEditor in pairs(INE.Editors) do
            if otherEditor._isFunctionSubEditor and not otherEditor.hidden then
                if mouseX >= otherEditor.x and mouseX <= otherEditor.x + otherEditor.width and
                   mouseY >= otherEditor.y and mouseY <= otherEditor.y + otherEditor.height then
                    mouseOverFuncEditor = true
                    break
                end
            end
        end
        -- 检测鼠标是否在任意筛选面板内（CardObjectSelector / NumericVarPopup / GlobalVarSelector / KeywordMultiSelect）
        -- 筛选面板在 HUDPaint 中绘制，提前在 Think 中消费滚轮标志防止触发缩放
        local filterPopups = INE:GetOpenPopups(editor)
        for _, kind in ipairs({ "CardObjectSelector", "NumericVarPopup", "GlobalVarSelector", "KeywordMultiSelect" }) do
            local popup = filterPopups[kind]
            if popup and popup._filterAreaX then
                if mouseX >= popup._filterAreaX and mouseX <= popup._filterAreaX + popup._filterAreaW and
                   mouseY >= popup._filterAreaY and mouseY <= popup._filterAreaY + popup._filterAreaH then
                    if INE._wheelZoomIn then INE._wheelZoomIn = false end
                    if INE._wheelZoomOut then INE._wheelZoomOut = false end
                end
            end
        end

        -- 仅在鼠标下没有函数子编辑器，或本编辑器就是该子编辑器时，处理缩放
        if not mouseOverFuncEditor or editor._isFunctionSubEditor then
            if INE._wheelZoomIn then
                INE._wheelZoomIn = false
                INE:ZoomView(editor, INE.ZOOM_STEP)
            elseif INE._wheelZoomOut then
                INE._wheelZoomOut = false
                INE:ZoomView(editor, 1 / INE.ZOOM_STEP)
            end
        end
    end
    return false
end

--[[
    Delete 键删除选中节点，带防重复触发锁存。

    @param  editor {table} 编辑器实例对象
    @param  ctx    {table} 原始输入上下文
    @return {boolean} 恒为 false
]]
local function ActionDeleteKey(editor, ctx)
    if input.IsKeyDown(KEY_DELETE) and not editor._deletePressed then
        editor._deletePressed = true
        INE:DeleteSelectedNodes(editor)
    end
    if not input.IsKeyDown(KEY_DELETE) then
        editor._deletePressed = false
    end
    return false
end

INE.InputActions = {
    modal = {
        {
            name = "import_warnings",
            enabled = function(editor, ctx) return editor.importWarnings ~= nil end,
            run = ActionImportWarnings
        },
        { name = "dropdown_option", run = ActionDropdownOption },
        { name = "var_popup_lifecycle", run = ActionVarPopupLifecycle },
        { name = "global_var_selector", run = ActionGlobalVarSelector },
        { name = "card_object_selector", run = ActionCardObjectSelector },
        { name = "overlay_window", run = ActionOverlayWindow }
    },
    chrome = {
        { name = "selection_context_menu", run = ActionSelectionAndContextMenu },
        { name = "file_menu", run = ActionFileMenu },
        { name = "view_menu", run = ActionViewMenu },
        { name = "close_button", run = ActionCloseButton },
        { name = "title_drag", run = ActionTitleDrag },
        { name = "node_palette", run = ActionNodePalette }
    },
    canvas = {
        -- 层内顺序即拆分前的执行顺序：平移、右键菜单、左键按下分发、
        -- 左键按住拖拽、左键释放、滚轮、Delete。
        { name = "middle_pan", run = ActionMiddlePan },
        { name = "right_release_menu", run = ActionRightReleaseMenu },
        { name = "left_press_prepare", run = ActionLeftPressPrepare },
        { name = "left_press_start_node", run = ActionLeftPressStartNode },
        { name = "left_press_data_port", run = ActionLeftPressDataPort },
        { name = "left_press_node", run = ActionLeftPressNode },
        { name = "left_press_empty", run = ActionLeftPressEmpty },
        { name = "left_drag_update", run = ActionLeftDragUpdate },
        { name = "left_release", run = ActionLeftRelease },
        { name = "wheel", run = ActionWheel },
        { name = "delete_key", run = ActionDeleteKey }
    }
}
