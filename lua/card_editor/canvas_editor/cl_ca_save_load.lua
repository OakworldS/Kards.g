--[[
=======================================================================================
保存/加载窗口 (Save/Load Windows)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的子系统，负责卡牌文件保存和加载的窗口 UI。

包含功能：
  - DrawSaveWindow（保存窗口）
  - DrawLoadWindow（加载窗口）
  - DrawLoadConfirmDialog（加载确认对话框）

状态数据：
  - SaveWindow（行 1030~1062）
  - LoadWindow（行 1065~1096）
  - LoadConfirmDialog（行 1099~1125）

源文件：cl_canvas_editor.lua（行 9146~9380 + 状态数据 1030~1125）
=======================================================================================
]]

-- 此文件内容将剪切自 cl_canvas_editor.lua 行 9146~9380
-- 包含：DrawSaveWindow、DrawLoadWindow、DrawLoadConfirmDialog
-- 状态数据（行 1030~1125）需一并迁移
-- 绘制保存窗口
KARDS.CardEditor.Canvas.SaveWindow = {
    visible = false,
    x = 0,
    y = 0,
    width = 450,
    height = 340, -- 2026-10-02：新增「设为默认卡牌」勾选行，原 280
    inputText = "",
    isReplaceMode = false,
    errorMessage = "",
    -- 【默认卡牌】「设为默认卡牌」勾选状态（仅测试版可见可用，正式版移除）
    setDefault = false,
    checkbox = { x = 0, y = 0, size = 22, hovered = false, hitX = 0, hitY = 0, hitW = 0, hitH = 0 },
    -- 【默认卡牌】「解锁默认卡牌」按钮（仅测试版可见可用，正式版移除）
    unlockButton = { x = 0, y = 0, width = 130, height = 30, hovered = false },
    buttons = {
        {
            id = "confirm",
            text = "确定",
            x = 0,
            y = 0,
            width = 100,
            height = 35,
            hovered = false,
            enabled = true
        },
        {
            id = "cancel",
            text = "取消",
            x = 0,
            y = 0,
            width = 100,
            height = 35,
            hovered = false
        }
    },
    inputTextEntry = nil,
    inputPanel = nil
}

-- 加载窗口状态
KARDS.CardEditor.Canvas.LoadWindow = {
    visible = false,
    x = 0,
    y = 0,
    width = 600,
    height = 500,
    selectedFile = nil,
    files = {},
    scrollOffset = 0, -- 文件列表滚动偏移（行数）
    category = "card", -- "card" | "effect" | "keyword"
    deleteMode = false, -- true 表示删除模式（由文件菜单删除按钮设置）
    buttons = {
        {
            id = "load",
            text = "加载该卡牌文件",
            x = 0,
            y = 0,
            width = 180,
            height = 35,
            hovered = false,
            enabled = false
        },
        {
            id = "cancel",
            text = "取消",
            x = 0,
            y = 0,
            width = 100,
            height = 35,
            hovered = false
        }
    },
    headerHeight = 35,
    rowHeight = 30
}

-- 加载确认对话框状态
KARDS.CardEditor.Canvas.LoadConfirmDialog = {
    visible = false,
    x = 0,
    y = 0,
    width = 400,
    height = 150,
    selectedFile = nil,
    buttons = {
        {
            id = "continue",
            text = "继续加载",
            x = 0,
            y = 0,
            width = 120,
            height = 30,
            hovered = false
        },
        {
            id = "cancel",
            text = "取消加载",
            x = 0,
            y = 0,
            width = 120,
            height = 30,
            hovered = false
        }
    }
}
function KARDS.CardEditor.Canvas.DrawSaveWindow()
    local saveWindow = KARDS.CardEditor.Canvas.SaveWindow
    if not saveWindow.visible then return end
    
    local win = KARDS.CardEditor.Canvas.Window
    saveWindow.x = win.x + (win.width - saveWindow.width) / 2
    saveWindow.y = win.y + (win.height - saveWindow.height) / 2
    
    -- 绘制窗口背景
    draw.RoundedBox(8, saveWindow.x, saveWindow.y, saveWindow.width, saveWindow.height, Color(0, 0, 0, 220))
    draw.RoundedBox(8, saveWindow.x + 2, saveWindow.y + 2, saveWindow.width - 4, saveWindow.height - 4, Color(45, 45, 45))
    
    -- 绘制标题
    draw.SimpleText("保存卡牌", "SourceHan_Heavy_24", saveWindow.x + saveWindow.width / 2, saveWindow.y + 35, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 绘制提示文字
    draw.SimpleText("请输入保存到卡牌的文件名称:", "SourceHan_Heavy_16", saveWindow.x + 40, saveWindow.y + 80, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    
    -- 创建/更新输入框（使用 Gmod 原版 DTextEntry）
    if not IsValid(saveWindow.inputPanel) then
        saveWindow.inputPanel = vgui.Create("DPanel", KARDS.CardEditor.Canvas.RootPanel)
        saveWindow.inputPanel:SetSize(saveWindow.width - 80, 40)
        saveWindow.inputPanel:SetPos(saveWindow.x + 40, saveWindow.y + 105)
        saveWindow.inputPanel.Paint = function(self, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(60, 60, 60))
        end
        
        local textEntry = vgui.Create("DTextEntry", saveWindow.inputPanel)
        textEntry:SetSize(saveWindow.width - 90, 30)
        textEntry:SetPos(5, 5)
        textEntry:SetFont("SourceHan_Heavy_16")
        textEntry:SetText("")
        textEntry.Paint = function(self, w, h)
            draw.RoundedBox(2, 0, 0, w, h, Color(70, 70, 70))
            self:DrawTextEntryText(Color(255, 255, 255), Color(100, 150, 255), Color(200, 200, 200))
        end
        textEntry.OnTextChanged = function(self)
            saveWindow.inputText = self:GetText()
            if saveWindow.inputText ~= "" and KARDS.CardEditor.SaveSystem.FileExists(saveWindow.inputText) then
                saveWindow.isReplaceMode = true
                saveWindow.errorMessage = "'" .. saveWindow.inputText .. "' 已经存在了，要使用这个名称，你需要替换该卡牌文件"
            else
                saveWindow.isReplaceMode = false
                saveWindow.errorMessage = ""
            end
        end
        saveWindow.inputTextEntry = textEntry
    end
    
    if IsValid(saveWindow.inputPanel) then
        saveWindow.inputPanel:SetVisible(true)
        saveWindow.inputPanel:SetPos(saveWindow.x + 40, saveWindow.y + 105)
        saveWindow.inputPanel:SetSize(saveWindow.width - 80, 40)
        if IsValid(saveWindow.inputTextEntry) then
            saveWindow.inputTextEntry:SetSize(saveWindow.width - 90, 30)
        end
    end
    
    -- 绘制冲突提示文字（仅在有冲突时显示）
    if saveWindow.errorMessage ~= "" then
        draw.SimpleText(saveWindow.errorMessage, "SourceHan_Heavy_14", saveWindow.x + 40, saveWindow.y + 160, Color(255, 50, 50), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end
    
    -- 绘制按钮
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()

    -- 【默认卡牌】「设为默认卡牌」勾选行 + 「解锁默认卡牌」按钮（仅测试版；正式版移除本段）
    if KARDS.CardEditor.DefaultCardTestMode then
        local cb = saveWindow.checkbox
        cb.size = 22
        cb.x = saveWindow.x + 40
        cb.y = saveWindow.y + 176
        cb.hitX = saveWindow.x + 36
        cb.hitY = saveWindow.y + 170
        cb.hitW = saveWindow.width - 72
        cb.hitH = 34
        cb.hovered = mouseX >= cb.hitX and mouseX <= cb.hitX + cb.hitW and mouseY >= cb.hitY and mouseY <= cb.hitY + cb.hitH

        local boxColor = saveWindow.setDefault and Color(80, 140, 220) or (cb.hovered and Color(85, 85, 85) or Color(60, 60, 60))
        draw.RoundedBox(3, cb.x, cb.y, cb.size, cb.size, boxColor)
        if saveWindow.setDefault then
            surface.SetDrawColor(255, 255, 255)
            surface.DrawLine(cb.x + 4, cb.y + cb.size * 0.55, cb.x + cb.size * 0.45, cb.y + cb.size - 5)
            surface.DrawLine(cb.x + cb.size * 0.45, cb.y + cb.size - 5, cb.x + cb.size - 4, cb.y + 4)
        end
        draw.SimpleText("设为默认卡牌", "SourceHan_Heavy_16", cb.x + cb.size + 10, cb.y + cb.size / 2, Color(235, 235, 235), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText("默认卡牌将锁定，不可修改、不可删除", "SourceHan_Heavy_12", cb.x + cb.size + 10, cb.y + cb.size + 15, Color(150, 150, 150), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- 当前编辑卡牌为默认卡牌：提示已锁定并提供解锁入口
        local isDefault = KARDS.CardEditor.Canvas.CardAppearance and KARDS.CardEditor.Canvas.CardAppearance.isDefault == true
        if isDefault then
            draw.SimpleText("当前卡牌为默认卡牌（已锁定）", "SourceHan_Heavy_14", saveWindow.x + 40, saveWindow.y + 240, Color(230, 180, 90), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            local ub = saveWindow.unlockButton
            ub.x = saveWindow.x + saveWindow.width - 40 - ub.width
            ub.y = saveWindow.y + 225
            ub.hovered = mouseX >= ub.x and mouseX <= ub.x + ub.width and mouseY >= ub.y and mouseY <= ub.y + ub.height
            local ubColor = ub.hovered and Color(210, 160, 75) or Color(175, 125, 55)
            draw.RoundedBox(6, ub.x, ub.y, ub.width, ub.height, ubColor)
            draw.SimpleText("解锁默认卡牌", "SourceHan_Heavy_14", ub.x + ub.width / 2, ub.y + ub.height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    end

    -- 确定/替换按钮
    local confirmBtn = saveWindow.buttons[1]
    confirmBtn.x = saveWindow.x + saveWindow.width / 2 - 115
    confirmBtn.y = saveWindow.y + saveWindow.height - 70
    confirmBtn.hovered = mouseX >= confirmBtn.x and mouseX <= confirmBtn.x + confirmBtn.width and mouseY >= confirmBtn.y and mouseY <= confirmBtn.y + confirmBtn.height
    
    if saveWindow.isReplaceMode then
        confirmBtn.text = "替换"
        local replaceColor = confirmBtn.hovered and Color(200, 80, 80) or Color(180, 60, 60)
        draw.RoundedBox(6, confirmBtn.x, confirmBtn.y, confirmBtn.width, confirmBtn.height, replaceColor)
        draw.SimpleText(confirmBtn.text, "SourceHan_Heavy_16", confirmBtn.x + confirmBtn.width / 2, confirmBtn.y + confirmBtn.height / 2, Color(255, 100, 100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    else
        confirmBtn.text = "确定"
        local confirmColor = confirmBtn.hovered and Color(100, 150, 255) or Color(80, 120, 200)
        draw.RoundedBox(6, confirmBtn.x, confirmBtn.y, confirmBtn.width, confirmBtn.height, confirmColor)
        draw.SimpleText(confirmBtn.text, "SourceHan_Heavy_16", confirmBtn.x + confirmBtn.width / 2, confirmBtn.y + confirmBtn.height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    
    -- 取消按钮
    local cancelBtn = saveWindow.buttons[2]
    cancelBtn.x = saveWindow.x + saveWindow.width / 2 + 15
    cancelBtn.y = saveWindow.y + saveWindow.height - 70
    cancelBtn.hovered = mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height
    
    local cancelColor = cancelBtn.hovered and Color(100, 100, 100) or Color(80, 80, 80)
    draw.RoundedBox(6, cancelBtn.x, cancelBtn.y, cancelBtn.width, cancelBtn.height, cancelColor)
    draw.SimpleText(cancelBtn.text, "SourceHan_Heavy_16", cancelBtn.x + cancelBtn.width / 2, cancelBtn.y + cancelBtn.height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- 绘制加载窗口
function KARDS.CardEditor.Canvas.DrawLoadWindow()
    local loadWindow = KARDS.CardEditor.Canvas.LoadWindow
    if not loadWindow.visible then return end
    
    local win = KARDS.CardEditor.Canvas.Window
    loadWindow.x = win.x + (win.width - loadWindow.width) / 2
    loadWindow.y = win.y + (win.height - loadWindow.height) / 2
    
    -- 绘制窗口背景
    draw.RoundedBox(8, loadWindow.x, loadWindow.y, loadWindow.width, loadWindow.height, Color(0, 0, 0, 220))
    draw.RoundedBox(8, loadWindow.x + 2, loadWindow.y + 2, loadWindow.width - 4, loadWindow.height - 4, Color(45, 45, 45))
    
    -- 绘制标题（根据 deleteMode 动态显示）
    local loadTitle = loadWindow.deleteMode and "删除卡牌" or "加载卡牌"
    draw.SimpleText(loadTitle, "SourceHan_Heavy_24", loadWindow.x + loadWindow.width / 2, loadWindow.y + 35, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 加载保存的文件列表
    if #loadWindow.files == 0 then
        loadWindow.files = KARDS.CardEditor.SaveSystem.GetCardFiles()
    end
    
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local listX = loadWindow.x + 40
    local listY = loadWindow.y + 80
    local listW = loadWindow.width - 80
    local listH = loadWindow.height - 180
    local headerH = loadWindow.headerHeight
    local rowH = loadWindow.rowHeight
    
    -- 绘制表头背景
    draw.RoundedBoxEx(4, listX, listY, listW, headerH, Color(60, 60, 60), true, true, false, false)
    
    -- 绘制表头分隔线
    local fileNameColW = listW * 0.55
    surface.SetDrawColor(100, 100, 100, 255)
    surface.DrawLine(listX + fileNameColW, listY, listX + fileNameColW, listY + headerH)
    surface.SetDrawColor(255, 255, 255, 255)
    
    -- 绘制表头文字
    draw.SimpleText("文件名", "SourceHan_Heavy_16", listX + 15, listY + headerH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    draw.SimpleText("卡牌名称", "SourceHan_Heavy_16", listX + fileNameColW + 15, listY + headerH / 2, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    
    -- 绘制表格背景
    draw.RoundedBoxEx(4, listX, listY + headerH, listW, listH - headerH, Color(50, 50, 50), false, false, true, true)
    
    -- 绘制文件列表（带滚动：可视行数由窗口高度决定，超出的行通过 scrollOffset 滚动查看）
    local startY = listY + headerH + 5
    local scrollableH = listH - headerH - 10
    local visibleRows = math.max(1, math.floor(scrollableH / rowH))
    local maxScroll = math.max(0, #loadWindow.files - visibleRows)
    loadWindow.scrollOffset = math.max(0, math.min(loadWindow.scrollOffset or 0, maxScroll))
    
    for i = 1, visibleRows do
        local fileIndex = loadWindow.scrollOffset + i
        local fileName = loadWindow.files[fileIndex]
        if not fileName then break end
        local itemY = startY + (i - 1) * rowH
        
        local isSelected = loadWindow.selectedFile == fileName
        local isHovered = mouseX >= listX and mouseX <= listX + listW and mouseY >= itemY and mouseY <= itemY + rowH - 2
        
        local itemColor = isSelected and Color(80, 80, 120) or (isHovered and Color(65, 65, 65) or Color(50, 50, 50))
        draw.RoundedBox(2, listX + 2, itemY, listW - 4, rowH - 2, itemColor)
        
        -- 获取卡牌名称与默认卡牌锁定标记
        local cardInfo = KARDS.CardEditor.SaveSystem.GetCardInfo(fileName)
        local displayName = cardInfo and cardInfo.name or ""
        if displayName == "" then
            displayName = "无名称"
        end
        local isDefaultCard = cardInfo and cardInfo.isDefault == true
        
        -- 绘制行分隔线
        if i < visibleRows and loadWindow.files[fileIndex + 1] then
            surface.SetDrawColor(70, 70, 70, 255)
            surface.DrawLine(listX + 5, itemY + rowH - 1, listX + listW - 5, itemY + rowH - 1)
            surface.SetDrawColor(255, 255, 255, 255)
        end
        
        draw.SimpleText(KARDS.CardEditor.SaveSystem.UnescapeFileName(fileName), "SourceHan_Heavy_14", listX + 15, itemY + (rowH - 2) / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText(displayName, "SourceHan_Heavy_14", listX + fileNameColW + 15, itemY + (rowH - 2) / 2, Color(150, 150, 150), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        -- 默认卡牌（锁定）标记
        if isDefaultCard then
            draw.SimpleText("默认·锁定", "SourceHan_Heavy_12", listX + fileNameColW - 10, itemY + (rowH - 2) / 2, Color(230, 180, 90), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        end
    end
    
    -- 绘制滚动条（列表超出可视区域时显示）
    if maxScroll > 0 then
        local barX = listX + listW - 10
        local barH = scrollableH - 4
        local trackY = startY + 2
        local thumbH = math.max(24, barH * visibleRows / #loadWindow.files)
        local thumbY = trackY + (barH - thumbH) * (loadWindow.scrollOffset / maxScroll)
        draw.RoundedBox(3, barX, trackY, 6, barH, Color(70, 70, 70))
        draw.RoundedBox(3, barX, thumbY, 6, thumbH, Color(150, 150, 160))
    end
    
    -- 绘制按钮
    -- 加载/删除按钮（根据 deleteMode 切换）
    local actionBtn = loadWindow.buttons[1]
    actionBtn.x = loadWindow.x + loadWindow.width / 2 - 175
    actionBtn.y = loadWindow.y + loadWindow.height - 70
    actionBtn.hovered = mouseX >= actionBtn.x and mouseX <= actionBtn.x + actionBtn.width and mouseY >= actionBtn.y and mouseY <= actionBtn.y + actionBtn.height
    actionBtn.enabled = loadWindow.selectedFile ~= nil
    
    if loadWindow.deleteMode then
        actionBtn.text = "删除该文件"
        local delColor = actionBtn.enabled and (actionBtn.hovered and Color(200, 80, 80) or Color(180, 60, 60)) or Color(70, 70, 70)
        draw.RoundedBox(6, actionBtn.x, actionBtn.y, actionBtn.width, actionBtn.height, delColor)
        draw.SimpleText(actionBtn.text, "SourceHan_Heavy_16", actionBtn.x + actionBtn.width / 2, actionBtn.y + actionBtn.height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    else
        actionBtn.text = "加载该文件"
        local loadColor = actionBtn.enabled and (actionBtn.hovered and Color(100, 150, 255) or Color(80, 120, 200)) or Color(70, 70, 70)
        draw.RoundedBox(6, actionBtn.x, actionBtn.y, actionBtn.width, actionBtn.height, loadColor)
        draw.SimpleText(actionBtn.text, "SourceHan_Heavy_16", actionBtn.x + actionBtn.width / 2, actionBtn.y + actionBtn.height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    
    -- 取消按钮
    local cancelBtn = loadWindow.buttons[2]
    cancelBtn.x = loadWindow.x + loadWindow.width / 2 + 15
    cancelBtn.y = loadWindow.y + loadWindow.height - 70
    cancelBtn.hovered = mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height
    
    local cancelColor = cancelBtn.hovered and Color(100, 100, 100) or Color(80, 80, 80)
    draw.RoundedBox(6, cancelBtn.x, cancelBtn.y, cancelBtn.width, cancelBtn.height, cancelColor)
    draw.SimpleText(cancelBtn.text, "SourceHan_Heavy_16", cancelBtn.x + cancelBtn.width / 2, cancelBtn.y + cancelBtn.height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

function KARDS.CardEditor.Canvas.DrawLoadConfirmDialog()
    local dialog = KARDS.CardEditor.Canvas.LoadConfirmDialog
    if not dialog.visible then return end
    
    local win = KARDS.CardEditor.Canvas.Window
    dialog.x = win.x + (win.width - dialog.width) / 2
    dialog.y = win.y + (win.height - dialog.height) / 2
    
    -- 绘制窗口背景
    draw.RoundedBox(8, dialog.x, dialog.y, dialog.width, dialog.height, Color(0, 0, 0, 220))
    draw.RoundedBox(8, dialog.x + 2, dialog.y + 2, dialog.width - 4, dialog.height - 4, Color(45, 45, 45))
    
    -- 绘制标题
    draw.SimpleText("确认加载", "SourceHan_Heavy_24", dialog.x + dialog.width / 2, dialog.y + 35, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 绘制提示文字
    draw.SimpleText("加载该卡牌将覆盖当前内容，确定继续吗？", "SourceHan_Heavy_16", dialog.x + dialog.width / 2, dialog.y + 80, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 绘制按钮
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    
    -- 继续加载按钮
    local continueBtn = dialog.buttons[1]
    continueBtn.x = dialog.x + dialog.width / 2 - 115
    continueBtn.y = dialog.y + dialog.height - 50
    continueBtn.hovered = mouseX >= continueBtn.x and mouseX <= continueBtn.x + continueBtn.width and mouseY >= continueBtn.y and mouseY <= continueBtn.y + continueBtn.height
    
    local continueColor = continueBtn.hovered and Color(100, 150, 255) or Color(80, 120, 200)
    draw.RoundedBox(6, continueBtn.x, continueBtn.y, continueBtn.width, continueBtn.height, continueColor)
    draw.SimpleText(continueBtn.text, "SourceHan_Heavy_16", continueBtn.x + continueBtn.width / 2, continueBtn.y + continueBtn.height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    
    -- 取消加载按钮
    local cancelBtn = dialog.buttons[2]
    cancelBtn.x = dialog.x + dialog.width / 2 + 15
    cancelBtn.y = dialog.y + dialog.height - 50
    cancelBtn.hovered = mouseX >= cancelBtn.x and mouseX <= cancelBtn.x + cancelBtn.width and mouseY >= cancelBtn.y and mouseY <= cancelBtn.y + cancelBtn.height
    
    local cancelColor = cancelBtn.hovered and Color(100, 100, 100) or Color(80, 80, 80)
    draw.RoundedBox(6, cancelBtn.x, cancelBtn.y, cancelBtn.width, cancelBtn.height, cancelColor)
    draw.SimpleText(cancelBtn.text, "SourceHan_Heavy_16", cancelBtn.x + cancelBtn.width / 2, cancelBtn.y + cancelBtn.height / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end