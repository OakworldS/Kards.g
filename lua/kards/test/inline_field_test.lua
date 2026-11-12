--[[
=======================================================================================
内联输入会话模块离线测试
=======================================================================================
不依赖 GMod 环境，在仓库根目录执行：

    lua lua/kards/test/inline_field_test.lua

覆盖范围：
  - 状态与句柄按编辑器实例隔离（多开不串扰）
  - 创建：定位、尺寸、规范文本、透明样式、弹置与光标
  - 同步：切换字段或外部改文本时更新句柄文本
  - 关闭：校验失败失活、ESC 关闭、Release 清空句柄
  - 焦点策略：每帧请求焦点与失焦重新弹置两种
  - 数组变量上下文按编辑器隔离

源文件：新建（2026-11-08），对应 docs/adr/0010-内联输入会话统一.md
=======================================================================================
]]

KEY_ESCAPE = 100
KEY_ENTER = 101
function Color(r, g, b, a) return { r or 0, g or 0, b or 0, a or 255 } end

KARDS = { CardEditor = { IndependentNodeEditor = {} } }
local INE = KARDS.CardEditor.IndependentNodeEditor
INE.FieldStateFactories = {
    NumVar = function()
        return { active = false, field = nil, editorID = nil, varIdx = nil, x = 0, y = 0, w = 0, h = 0 }
    end,
    TextSlot = function()
        return { active = false, node = nil, compId = nil, text = "", x = 0, y = 0, w = 0, h = 0 }
    end,
}

-- DTextEntry 桩：记录调用，暴露回调供测试触发
local function NewEntry()
    local e = {
        __entry = true, text = "", caret = 0, removed = false,
        pos = { 0, 0 }, size = { 0, 0 }, drawBackground = true, drawBorder = true,
        popup = false, focusRequested = false,
    }
    function e:SetPos(x, y) self.pos = { x, y } end
    function e:SetSize(w, h) self.size = { w, h } end
    function e:SetText(t) self.text = t end
    function e:GetText() return self.text end
    function e:SetCaretPos(n) self.caret = n end
    function e:SetDrawBackground(v) self.drawBackground = v end
    function e:SetDrawBorder(v) self.drawBorder = v end
    function e:SetTextColor() end
    function e:SetCursorColor() end
    function e:MakePopup() self.popup = true end
    function e:RequestFocus() self.focusRequested = true end
    function e:HasFocus() return self.__focus == true end
    function e:Remove() self.removed = true end
    return e
end
local created = {}
vgui = { Create = function()
    local e = NewEntry()
    created[#created + 1] = e
    return e
end }
function IsValid(v) return v ~= nil and v.removed ~= true end

dofile("lua/card_editor/ine_editor/cl_ine_inline_field.lua")
local IF = KARDS.CardEditor.InlineField
assert(IF, "内联输入模块未注册 KARDS.CardEditor.InlineField")

local passed = 0
local function ok(cond, message)
    assert(cond, message)
    passed = passed + 1
end

local function NewEditor(id)
    return { id = id, session = { fields = {}, entries = {}, arrayVar = {} } }
end

-- 1. 按编辑器隔离
local ed1, ed2 = NewEditor("a"), NewEditor("b")
local st1 = IF.Field(ed1, "NumVar")
st1.active = true
local st2 = IF.Field(ed2, "NumVar")
ok(st1 ~= st2, "两编辑器的同类状态应各自独立")
ok(st2.active == false, "新编辑器的状态应来自工厂初值")
ok(IF.Field(ed1, "NumVar") == st1, "同一编辑器的状态应复用")

-- 2. 创建：定位、尺寸、文本、透明样式
st1.x, st1.y, st1.w, st1.h = 10, 20, 30, 12
st1.field = "name"
local spec = {
    kind = "NumVar",
    text = function(st) return "示例名" end,
    commit = function() end,
}
IF.Update(spec, ed1)
local entry = IF.Entry(ed1, "NumVar")
ok(entry ~= nil, "激活后应创建句柄")
ok(entry.pos[1] == 10 and entry.pos[2] == 20, "句柄位置应与状态一致")
ok(entry.size[1] == 30 and entry.size[2] == 12, "句柄尺寸应与状态一致")
ok(entry:GetText() == "示例名", "句柄文本应取自规范文本")
ok(entry.drawBackground == false and entry.drawBorder == false, "句柄应为无背景无边框")
ok(entry.popup == true, "默认应弹置句柄")
ok(entry.caret == #"示例名", "默认应把光标放到文本末尾")

-- 3. 文本同步
st1.field = "iname"
spec.text = function(st) return "内部名" end
IF.Update(spec, ed1)
ok(entry:GetText() == "内部名", "切换字段后句柄文本应同步")
ok(entry.caret == #"内部名", "同步文本后光标应移到末尾")

-- 4. 输入写回
entry:SetText("改过的名字")
entry.OnTextChanged(entry)
ok(true, "OnTextChanged 已触发（写回由 commit 负责）")

-- 5. 校验失败失活
spec.validate = function() return false end
IF.Update(spec, ed1)
ok(st1.active == false, "校验失败应使状态失活")
ok(IF.Entry(ed1, "NumVar") == nil, "校验失败应销毁句柄")
ok(entry.removed == true, "被销毁的句柄应调用 Remove")

-- 6. ESC 关闭
spec.validate = nil
st1.active = true
IF.Update(spec, ed1)
local escEntry = IF.Entry(ed1, "NumVar")
escEntry.OnKeyCodeTyped(escEntry, KEY_ESCAPE)
ok(st1.active == false, "ESC 应关闭输入")
IF.Update(spec, ed1)
ok(IF.Entry(ed1, "NumVar") == nil, "关闭后的下一帧应销毁句柄")

-- 7. 追加关闭键
st1.active = true
spec.closeKeys = { KEY_ENTER }
IF.Update(spec, ed1)
local enterEntry = IF.Entry(ed1, "NumVar")
enterEntry.OnKeyCodeTyped(enterEntry, KEY_ENTER)
ok(st1.active == false, "closeKeys 中的键应关闭输入")
spec.closeKeys = nil

-- 8. 焦点策略
st1.active = true
st1.focusExisting = nil
IF.Update(spec, ed1)
local focusEntry = IF.Entry(ed1, "NumVar")
ok(focusEntry.popup == true, "失焦时应重新弹置")
focusEntry.__focus = true
focusEntry.popup = false
IF.Update(spec, ed1)
ok(focusEntry.popup == false, "已聚焦时不应重复弹置")

st1.active = false
local specRequest = {
    kind = "TextSlot",
    focusExisting = "request",
    text = function(st) return st.text or "" end,
}
local ts = IF.Field(ed2, "TextSlot")
ts.active = true
ts.text = "x"
IF.Update(specRequest, ed2)
local reqEntry = IF.Entry(ed2, "TextSlot")
ok(reqEntry.focusRequested == true, "focusExisting=request 时应每帧请求焦点")

-- 9. 释放与清空
IF.Release(specRequest, ed2)
ok(IF.Entry(ed2, "TextSlot") == nil, "Release 应清空句柄条目")
ok(reqEntry.removed == true, "Release 应销毁句柄")

IF.ClearEntry(ed1, "NumVar")
ok(IF.Entry(ed1, "NumVar") == nil, "ClearEntry 应清空句柄条目")

-- 10. Drop 使状态失活
st1.active = true
IF.Drop(ed1, "NumVar")
ok(st1.active == false and st1.editorID == nil and st1.field == nil, "Drop 应使状态失活并清空标识")

-- 11. 数组变量上下文按编辑器隔离
local ctx1 = IF.ArrayVarCtx(ed1)
ctx1.pendingType = "n"
local ctx2 = IF.ArrayVarCtx(ed2)
ok(ctx1 ~= ctx2 and ctx2.pendingType == nil, "数组变量上下文应按编辑器隔离")
ok(IF.ArrayVarCtx(ed1).pendingType == "n", "同一编辑器的上下文应复用")
ok(IF.ArrayVarCtx(nil) == nil, "无编辑器时上下文应为 nil")

print(string.format("inline_field_test: %d 项通过", passed))
