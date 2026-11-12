--[[
=======================================================================================
编辑器几何模块离线测试
=======================================================================================
不依赖 GMod 环境，在仓库根目录执行：

    lua lua/kards/test/editor_geometry_test.lua

覆盖范围：
  - 画布区域与视图变换往返
  - 端口矩形：普通节点、开始点、缩放、加号按钮、下拉框、旧字段回写
  - 几何惰性缓存：同帧复用、跨帧重算、端口数量变化失效
  - 曲线采样：端点、步数、水平与垂直模式
  - 折线距离

源文件：新建（2026-11-08），对应 docs/adr/0006-节点几何深模块.md
=======================================================================================
]]

KARDS = { CardEditor = {} }
local frame = 1
function FrameNumber() return frame end

local Geometry = dofile("lua/card_editor/sh_editor_geometry.lua")
assert(Geometry, "几何模块未返回")

local passed = 0
local function ok(cond, message)
    assert(cond, message)
    passed = passed + 1
end

local function near(a, b, tolerance)
    return math.abs(a - b) <= (tolerance or 0.001)
end

local editor = {
    x = 0, y = 0, width = 1000, height = 500, borderless = true,
    canvasOffsetX = 0, canvasOffsetY = 0, canvasScale = 1,
}

-- 1. 画布区域与视图变换
local rect = Geometry.GetCanvasRect(editor)
ok(rect.x == 5 and rect.y == 0 and rect.w == 990 and rect.h == 500, "画布区域应扣掉边距与标题栏")

local sx, sy = Geometry.WorldToScreen(editor, 10, 20)
ok(sx == 15 and sy == 20, "世界坐标转屏幕坐标应加上画布偏移")
local wx, wy = Geometry.ScreenToWorld(editor, sx, sy)
ok(near(wx, 10) and near(wy, 20), "屏幕坐标转世界坐标应往返一致")

editor.canvasScale = 2
editor.canvasOffsetX = 30
editor.canvasOffsetY = 40
sx, sy = Geometry.WorldToScreen(editor, 10, 20)
ok(sx == 85 and sy == 120, "缩放与平移后的屏幕坐标不符")
wx, wy = Geometry.ScreenToWorld(editor, sx, sy)
ok(near(wx, 10) and near(wy, 20), "缩放与平移后应往返一致")

-- 2. 端口矩形
editor.canvasScale = 1
editor.canvasOffsetX = 0
editor.canvasOffsetY = 0

local node = {
    x = 0, y = 0, width = 100, height = 40,
    availableOutputTypes = { "a", "b" },
    selectedOutputTypes = { "a", "b" },
    availableInputTypes = { "c" },
    selectedInputTypes = { "c" },
}
local geometry = Geometry.GetPortRects(editor, node)
ok(#geometry.output.positions == 2, "输出端口数量不符")
ok(near(geometry.output.positions[1].x, 37) and near(geometry.output.positions[1].y, 40), "首个输出端口位置不符")
ok(near(geometry.output.positions[2].x, 53), "第二个输出端口位置不符")
ok(near(geometry.output.positions[1].radius, 6), "端口半径不符")

local outputButton = geometry.output.buttonRect
ok(outputButton ~= nil, "有可用输出类型时应生成加号按钮矩形")
ok(near(outputButton.x, 65) and near(outputButton.y, 32), "输出加号按钮矩形位置不符")
ok(near(outputButton.w, 16) and near(outputButton.h, 16), "输出加号按钮矩形尺寸不符")

ok(#geometry.input.positions == 1, "输入端口数量不符")
ok(near(geometry.input.positions[1].x, 45) and near(geometry.input.positions[1].y, 0), "输入端口位置不符")
ok(geometry.input.buttonRect ~= nil, "有可用输入类型时应生成加号按钮矩形")

-- 旧字段回写
ok(node._outputDataPortPositions == geometry.output.positions, "输出端口旧字段应指向几何结果")
ok(node._dataPortButtonRect == geometry.output.buttonRect, "输出按钮旧字段应指向几何结果")
ok(node._inputDataPortPositions == geometry.input.positions, "输入端口旧字段应指向几何结果")
ok(node._dataPortDropdownRect == nil, "未展开时下拉框矩形应为 nil")

-- 下拉框矩形
node.dataPortDropdownActive = true
geometry = Geometry.GetPortRects(editor, node)
ok(geometry.output.dropdownRect ~= nil, "展开时应生成下拉框矩形")
ok(near(geometry.output.dropdownRect.w, 368) and near(geometry.output.dropdownRect.h, 28), "下拉框矩形尺寸不符")

-- 缓存：同帧复用
local cached = Geometry.GetPortRects(editor, node)
ok(cached == geometry, "同帧应复用缓存")

-- 缓存：端口数量变化立即失效
table.insert(node.selectedOutputTypes, "d")
local updated = Geometry.GetPortRects(editor, node)
ok(updated ~= geometry, "端口数量变化应使缓存失效")
ok(#updated.output.positions == 3, "端口数量变化后应重新计算")

-- 缓存：跨帧重算
frame = frame + 1
local nextFrame = Geometry.GetPortRects(editor, node)
ok(nextFrame ~= updated, "跨帧应重新计算")

-- 开始点：输出端口固定在左边缘
local startNode = {
    x = 0, y = 0, width = 100, height = 40, isStartNode = true,
    availableOutputTypes = { "a" },
    selectedOutputTypes = { "a" },
    selectedInputTypes = {},
    availableInputTypes = {},
}
local startGeometry = Geometry.GetPortRects(editor, startNode)
ok(near(startGeometry.output.positions[1].x, 5), "开始点输出端口应固定在节点左边缘")
ok(startGeometry.output.buttonRect == nil, "开始点不应生成输出加号按钮")
ok(near(startGeometry.output.positions[1].y, 20), "开始点输出端口应垂直居中")

-- 3. 曲线采样
local horizontal = Geometry.BuildCurvePoints(0, 0, 100, 50, "horizontal")
ok(#horizontal == 41, "执行线默认应为 40 步")
ok(near(horizontal[1].x, 0) and near(horizontal[1].y, 0), "曲线起点不符")
ok(near(horizontal[#horizontal].x, 100) and near(horizontal[#horizontal].y, 50), "曲线终点不符")

local vertical = Geometry.BuildCurvePoints(0, 0, 100, 50, "vertical")
ok(#vertical == 21, "数据线默认应为 20 步")
ok(near(vertical[1].x, 0) and near(vertical[1].y, 0), "数据线起点不符")
ok(near(vertical[#vertical].x, 100) and near(vertical[#vertical].y, 50), "数据线终点不符")

local custom = Geometry.BuildCurvePoints(0, 0, 10, 0, "horizontal", 5)
ok(#custom == 6, "自定义步数应得到 steps + 1 个点")

-- 4. 折线距离
local polyline = { { x = 0, y = 0 }, { x = 100, y = 0 } }
ok(near(Geometry.DistanceToPolyline(50, 10, polyline), 10), "折线距离不符")
ok(near(Geometry.DistanceToPolyline(-5, 0, polyline), 5), "折线外侧距离不符")
ok(Geometry.DistanceToPolyline(0, 0, {}) == math.huge, "空折线应返回 math.huge")

print(string.format("[editor_geometry_test] %d 项通过", passed))
