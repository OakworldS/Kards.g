--[[
=======================================================================================
编辑器会话状态收尾离线测试
=======================================================================================
不依赖 GMod 环境，在仓库根目录执行：

    lua lua/kards/test/session_ownership_test.lua

覆盖范围：
  - CreateEditorSession 的浮层字段与搜索框句柄完整性
  - GetOpenPopups 只返回非 nil 浮层、无编辑器时返回空表
  - MarkDrawn 与 IsDrawnThisFrame 的同帧判定与跨帧失效
  - 静态扫描 cl_ine_input_actions.lua 不再读取 Canvas 浮层字段

源文件：新建（2026-11-08），对应 docs/adr/0005-编辑器会话状态收尾.md
=======================================================================================
]]

-- 离线桩：仅提供加载 cl_ine_node_editor.lua 所需的最小全局
KARDS = {
    CardEditor = {},
    Lang = { T = function(key) return tostring(key) end },
}
local frame = 0
function FrameNumber() return frame end
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a } end
concommand = { Add = function() end }
FCVAR_ARCHIVE = 0
function CreateConVar(name, default, flags)
    return { GetBool = function() return false end }
end

dofile("lua/card_editor/ine_editor/cl_ine_node_editor.lua")

local INE = KARDS.CardEditor.IndependentNodeEditor
assert(INE, "IndependentNodeEditor 未创建")

local passed = 0
local function ok(cond, message)
    assert(cond, message)
    passed = passed + 1
end

-- 1. 会话字段完整
local session = INE:CreateEditorSession()
for _, kind in ipairs(INE.PopupKinds) do
    ok(session[kind] == nil, "会话应初始化 " .. kind .. " 为 nil")
end
ok(session._searchTextEntry == nil, "会话应含 _searchTextEntry")
ok(session._cardObjectSearchEntry == nil, "会话应含 _cardObjectSearchEntry")
ok(session._gvsSearchEntry == nil, "会话应含 _gvsSearchEntry")

-- 2. GetOpenPopups 只返回非 nil 浮层
local editor = { session = session }
ok(next(INE:GetOpenPopups(editor)) == nil, "空会话不应返回浮层")
session.FuncVarPopup = { kind = "func" }
session.KeywordMultiSelect = { kind = "kw" }
local open = INE:GetOpenPopups(editor)
ok(open.FuncVarPopup == session.FuncVarPopup, "应返回函数变量弹窗")
ok(open.KeywordMultiSelect == session.KeywordMultiSelect, "应返回词条多选浮层")
ok(open.NumericVarPopup == nil, "未打开的数字弹窗不应出现")
ok(open.CardObjectSelector == nil, "未打开的卡牌选择器不应出现")
ok(next(INE:GetOpenPopups(nil)) == nil, "无编辑器时应返回空表")

-- 3. 绘制帧号
frame = 100
ok(not INE:IsDrawnThisFrame(), "未标记时不应判定本帧已绘制")
INE:MarkDrawn()
ok(INE:IsDrawnThisFrame(), "标记后应判定本帧已绘制")
frame = 101
ok(not INE:IsDrawnThisFrame(), "跨帧后标记应失效")

-- 4. 静态扫描：动作表不再读取旧 Canvas 浮层字段
local sourceFile = assert(io.open("lua/card_editor/ine_editor/cl_ine_input_actions.lua", "r"))
local source = sourceFile:read("*a")
sourceFile:close()
for _, field in ipairs({
    "NumericVarPopup", "FuncVarPopup", "CardObjectSelector", "GlobalVarSelector",
    "KeywordMultiSelect", "_searchTextEntry", "_cardObjectSearchEntry",
    "_gvsSearchEntry", "_dropdownConsumedFrame",
}) do
    ok(not source:find("Canvas." .. field, 1, true), "动作表不应再读 Canvas." .. field)
end

local canvasFile = assert(io.open("lua/card_editor/canvas_editor/effect_editor/cl_canvas_editor.lua", "r"))
local canvasSource = canvasFile:read("*a")
canvasFile:close()
ok(not canvasSource:find("_canvasDrawnFrame", 1, true), "Canvas 不应再写 _canvasDrawnFrame")

print(string.format("[session_ownership_test] %d 项通过", passed))
