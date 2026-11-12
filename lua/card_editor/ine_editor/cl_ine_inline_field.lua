-- 内联输入会话统一模块（C-05，2026-11-08）：INE 的透明 DTextEntry 生命周期唯一实现处，
-- 见 docs/adr/0010-内联输入会话统一.md。
-- 状态表与句柄按编辑器实例存放在 editor.session，避免多个编辑器同时打开同类对话框时
-- 互相覆盖焦点与文本。调用方只描述差异点：规范文本、写回、校验、关闭键与焦点策略。
KARDS.CardEditor = KARDS.CardEditor or {}
local INE = KARDS.CardEditor.IndependentNodeEditor
local IF = {}
KARDS.CardEditor.InlineField = IF

-- 取某编辑器的输入状态表，缺失时用工厂惰性建表
function IF.Field(editor, kind)
    local session = editor and editor.session
    if not session then return nil end
    session.fields = session.fields or {}
    local st = session.fields[kind]
    if not st then
        local factory = INE.FieldStateFactories and INE.FieldStateFactories[kind]
        st = factory and factory() or {}
        session.fields[kind] = st
    end
    return st
end

-- 取某编辑器的透明 DTextEntry 句柄
function IF.Entry(editor, kind)
    local session = editor and editor.session
    local entries = session and session.entries
    return entries and entries[kind]
end

-- 销毁句柄并清空条目
function IF.ClearEntry(editor, kind)
    local session = editor and editor.session
    local entries = session and session.entries
    if not entries then return end
    local entry = entries[kind]
    if entry and IsValid(entry) then entry:Remove() end
    entries[kind] = nil
end

-- 关闭某类输入：状态失活并销毁句柄（调用方关闭对话框时使用）
function IF.Drop(editor, kind)
    local st = IF.Field(editor, kind)
    if st then
        st.active = false
        st.editorID = nil
        st.field = nil
    end
    IF.ClearEntry(editor, kind)
end

-- 取编辑器的数组变量临时上下文
function IF.ArrayVarCtx(editor)
    local session = editor and editor.session
    if not session then return nil end
    session.arrayVar = session.arrayVar or {}
    return session.arrayVar
end

-- 解析 spec 的状态、句柄存放表与条目名
-- 传入 editor 时从 editor.session 取（按编辑器隔离）；否则用 spec 内联字段（离线测试用）
local function Resolve(spec, editor)
    if editor then
        local st = IF.Field(editor, spec.kind)
        local session = editor.session
        session.entries = session.entries or {}
        return st, session.entries, spec.kind
    end
    return spec.state, spec.storage, spec.key
end

-- 关闭键判定：默认只有 ESC，spec.closeKeys 可追加（如文本槽的 ENTER）
local function IsCloseKey(spec, keyCode)
    if keyCode == KEY_ESCAPE then return true end
    local extra = spec.closeKeys
    if extra then
        for i = 1, #extra do
            if keyCode == extra[i] then return true end
        end
    end
    return false
end

-- 销毁句柄并清空条目；editor 为空时用 spec 内联字段（离线测试用）
function IF.Release(spec, editor)
    local st, storage, key = Resolve(spec, editor)
    if not storage then return end
    local entry = storage[key]
    if entry and IsValid(entry) then entry:Remove() end
    storage[key] = nil
    if st and not editor then st.active = false end
end

-- 逐帧推进一份输入会话：失活或校验失败则销毁，否则保证句柄存在、位置与规范文本同步
function IF.Update(spec, editor)
    local st, storage, key = Resolve(spec, editor)
    if not st or not storage then return end
    if not st.active or (spec.validate and not spec.validate(st)) then
        st.active = false
        IF.Release(spec, editor)
        return
    end
    local entry = storage[key]
    if not entry or not IsValid(entry) then
        -- 新建：透明输入层，绘制由自绘界面完成，控件本身不可见但接管 IME 与剪贴板
        local txt = (spec.text and spec.text(st)) or ""
        entry = vgui.Create("DTextEntry")
        entry:SetPos(st.x, st.y)
        entry:SetSize(st.w, st.h)
        entry:SetText(txt)
        if spec.caretOnCreate ~= false then entry:SetCaretPos(#txt) end
        entry:SetDrawBackground(false)
        entry:SetDrawBorder(false)
        entry:SetTextColor(Color(255, 255, 255, 0))
        entry:SetCursorColor(Color(255, 255, 255, 0))
        entry.Paint = nil
        entry:MakePopup()
        -- 焦点策略：搜索框创建后立即请求焦点，其余依赖弹置即可
        if spec.focusExisting == "request" then
            entry:RequestFocus()
        end

        entry.OnTextChanged = function(self)
            if st.active then spec.commit(st, self:GetText()) end
        end
        entry.OnKeyCodeTyped = function(self, keyCode)
            if IsCloseKey(spec, keyCode) then st.active = false end
        end

        storage[key] = entry
        return
    end
    -- 已存在：跟随滚动 / 拖动同步位置与尺寸
    entry:SetPos(st.x, st.y)
    entry:SetSize(st.w, st.h)
    -- 同步文本：切换字段时 DTextEntry 会残留旧字段文本
    local expected = (spec.text and spec.text(st)) or ""
    if entry:GetText() ~= expected then
        entry:SetText(expected)
        entry:SetCaretPos(#expected)
    end
    -- 焦点策略：搜索框每帧主动请求焦点；其余仅在失焦时重新弹置
    if spec.focusExisting == "request" then
        entry:RequestFocus()
    elseif not entry:HasFocus() then
        entry:MakePopup()
    end
end

-- 暴露给 INE 内部
INE.Field = IF.Field
INE.Entry = IF.Entry
INE.ArrayVarCtx = IF.ArrayVarCtx
INE.DropField = IF.Drop
