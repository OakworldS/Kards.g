--[[
=======================================================================================
输入路由共享引擎 (Input Router)
=======================================================================================
画布编辑器与独立节点编辑器共用的输入分发结构。

包含功能：
  - BuildContext：把当帧原始输入组装为上下文，并计算左键按下与释放
  - Route：按 模态与浮层、编辑器窗口级、画布内部 三层顺序遍历动作表，
    遇到返回 true 的动作即停止并返回动作名
  - Commit：路由结束后记录本帧按键状态，供下一帧计算按下与释放

约定：
  - 本文件不依赖任何 GMod API，可用 lua 命令离线运行与断言。
  - 上下文只装原始输入与一次性派生值，跨动作共享的编辑器状态仍挂 editor。
  - 动作项形如 { name = "动作名", run = function(editor, ctx) return consumed end }，
    run 返回 true 表示已消费该输入。

源文件：新建（2026-11-08），决策见 docs/adr/0004-输入路由共享引擎.md
=======================================================================================
]]

KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}

local Router = {}
KARDS.CardEditor.InputRouter = Router

--- 层遍历顺序，前一层优先
Router.LayerOrder = { "modal", "chrome", "canvas" }

--[[
    取得或创建编辑器的路由状态（只记录上一帧原始按键状态）。

    @param  editor {table} 编辑器实例对象
    @return {table} 路由状态表
]]
local function GetState(editor)
    local state = editor._inputRouterState
    if not state then
        state = {
            prevLeft = false,
            prevRight = false,
            prevMiddle = false
        }
        editor._inputRouterState = state
    end
    return state
end

--[[
    组装原始输入上下文。

    @param  editor {table} 编辑器实例对象
    @param  raw    {table} 当帧原始输入 { x, y, leftDown, rightDown, middleDown, wheel }
    @return {table} 上下文表
]]
function Router.BuildContext(editor, raw)
    raw = raw or {}
    local state = GetState(editor)
    local leftDown = raw.leftDown and true or false
    local rightDown = raw.rightDown and true or false
    local middleDown = raw.middleDown and true or false
    return {
        x = raw.x or 0,
        y = raw.y or 0,
        leftDown = leftDown,
        rightDown = rightDown,
        middleDown = middleDown,
        leftPressed = leftDown and not state.prevLeft,
        leftReleased = (not leftDown) and state.prevLeft,
        rightPressed = rightDown and not state.prevRight,
        rightReleased = (not rightDown) and state.prevRight,
        wheel = raw.wheel or 0
    }
end

--[[
    记录本帧按键状态，供下一帧计算按下与释放。
    路由无论是否被消费都要调用，否则下一帧的按下判定会错位。

    @param editor {table} 编辑器实例对象
    @param ctx    {table} 上下文表
]]
function Router.Commit(editor, ctx)
    local state = GetState(editor)
    state.prevLeft = ctx.leftDown
    state.prevRight = ctx.rightDown
    state.prevMiddle = ctx.middleDown
end

--[[
    按层路由一帧输入。

    @param  editor  {table} 编辑器实例对象
    @param  ctx     {table} 上下文表
    @param  actions {table} 动作表，形如 { modal = {...}, chrome = {...}, canvas = {...} }
    @return {string|nil} 被消费的动作名，无人消费则返回 nil
]]
function Router.Route(editor, ctx, actions)
    actions = actions or {}
    for _, layerName in ipairs(Router.LayerOrder) do
        local list = actions[layerName]
        if list then
            for _, action in ipairs(list) do
                local enabled = true
                if action.enabled then
                    enabled = action.enabled(editor, ctx)
                end
                if enabled and action.run(editor, ctx) then
                    return action.name
                end
            end
        end
    end
    return nil
end
