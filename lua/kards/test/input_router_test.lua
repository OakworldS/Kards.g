--[[
=======================================================================================
输入路由共享引擎离线测试
=======================================================================================
不依赖 GMod 环境，在仓库根目录执行：

    lua lua/kards/test/input_router_test.lua

覆盖范围：
  - 上下文组装与左键按下、释放的跨帧计算
  - 三层遍历顺序与层内顺序
  - 消费短路与动作名返回
  - enabled 条件跳过
  - 无动作消费时的返回值

源文件：新建（2026-11-08），对应 docs/adr/0004-输入路由共享引擎.md
=======================================================================================
]]

dofile("lua/card_editor/sh_input_router.lua")

local Router = KARDS.CardEditor.InputRouter
assert(Router, "InputRouter 未创建")

local passed = 0
local function ok(cond, message)
    assert(cond, message)
    passed = passed + 1
end

-- 1. 首帧按下
local editor = { name = "test" }
local ctx = Router.BuildContext(editor, { x = 10, y = 20, leftDown = true })
ok(ctx.x == 10 and ctx.y == 20, "上下文应保留坐标")
ok(ctx.leftPressed == true, "首帧按下应判定为 leftPressed")
ok(ctx.leftReleased == false, "首帧不应判定为 leftReleased")
ok(ctx.wheel == 0, "未提供滚轮时应为 0")

-- 2. 提交后释放
Router.Commit(editor, ctx)
local ctx2 = Router.BuildContext(editor, { x = 12, y = 22, leftDown = false })
ok(ctx2.leftPressed == false, "释放帧不应判定为 leftPressed")
ok(ctx2.leftReleased == true, "释放帧应判定为 leftReleased")
Router.Commit(editor, ctx2)

-- 3. 层顺序：模态优先于窗口级与画布
local hits = {}
local actions = {
    canvas = {
        { name = "canvas_1", run = function() table.insert(hits, "canvas_1") return false end }
    },
    chrome = {
        { name = "chrome_1", run = function() table.insert(hits, "chrome_1") return false end }
    },
    modal = {
        { name = "modal_1", run = function() table.insert(hits, "modal_1") return true end }
    }
}
local consumed = Router.Route(editor, ctx2, actions)
ok(consumed == "modal_1", "应返回被消费的动作名")
ok(#hits == 1 and hits[1] == "modal_1", "模态消费后不应继续执行后续层")

-- 4. 层内顺序与短路
hits = {}
actions = {
    canvas = {
        { name = "a", run = function() table.insert(hits, "a") return false end },
        { name = "b", run = function() table.insert(hits, "b") return true end },
        { name = "c", run = function() table.insert(hits, "c") return true end }
    }
}
consumed = Router.Route(editor, ctx2, actions)
ok(consumed == "b", "应返回层内首个消费者")
ok(#hits == 2 and hits[2] == "b", "消费点之后不应继续执行")

-- 5. enabled 条件跳过
hits = {}
actions = {
    modal = {
        { name = "skipped", enabled = function() return false end, run = function() table.insert(hits, "skipped") return true end },
        { name = "next", run = function() return true end }
    }
}
consumed = Router.Route(editor, ctx2, actions)
ok(consumed == "next", "enabled 为 false 的动作应跳过")
ok(#hits == 0, "被跳过的动作不应执行")

-- 6. 无人消费
consumed = Router.Route(editor, ctx2, { canvas = { { name = "x", run = function() return false end } } })
ok(consumed == nil, "无消费者时应返回 nil")

-- 7. 缺失层与空动作表
consumed = Router.Route(editor, ctx2, {})
ok(consumed == nil, "空动作表应安全返回 nil")
consumed = Router.Route(editor, ctx2, nil)
ok(consumed == nil, "nil 动作表应安全返回 nil")

print("input_router_test: " .. passed .. " 项断言全部通过")
