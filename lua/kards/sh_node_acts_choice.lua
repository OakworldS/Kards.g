--[[
    节点解析系统：抉择语义动作执行器（choice 模板，2026-10-04 新增）

    对应 data_static/kards/node_templates/choice.json（DSL：`'抉择：'<>'或'<>`，base `<><>`）。
    节点语义条目定义在 sh_node_semantics.lua 的 BaseSemantics.choice（act = "choice"，
    与 loop 同属「无语义分支表」的特例，见 ExecuteBaseNode 的 sem.act 分支）。

    执行语义：读取两个文本槽（效果一 T1 / 效果二 T2）→ 经 ctx.specify.choicePicker 询问
    玩家选择（真实玩家路径由 table_choice.lua 的 coroutine.yield 提供）→ 返回值作为
    双输出端口的分支结果：
      选择效果一 → true  → 端口 "satisfied"（INE 显示标签「效果一」）
      选择效果二 → false → 端口 "not_satisfied"（标签「效果二」）
    （端口分流见 sh_effect_flow.lua ExecuteEffectFlow）

    选择注入缺失时的缺省：取效果一（不卡死）——对齐开发/观星的缺省分支
    （sh_node_acts_field.lua 开发缺省取第 3 张候选 / 观星缺省取顶张），
    覆盖非协程路径（伪用户、节点测试）与未接线场景。

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_node_semantics.lua 之后）
]]

KARDS = KARDS or {}
KARDS.NodeParser = KARDS.NodeParser or {}

-- 跨文件共享（GLua 无跨文件 local）：主文件（sh_node_parser.lua）已暴露，本文件取本地引用
local ReadSlot = KARDS.NodeParser.ReadSlot

-- 解析文本槽值为最终文本：值为 "var:<文本变量名>" 时按显示名解析文本变量，
-- 否则按直接文本返回（与 sh_node_semantics.lua 文本槽属性 SET_OBJ_TEXT_SLOT_PROPS 同式）
-- @param ctx   table 执行上下文
-- @param value any 槽值（"var:<名>" 或直接文本）
-- @return string 最终文本（解析失败回退空串）
local function ResolveText(ctx, value)
    local raw = tostring(value or "")
    local refName = raw:match("^var:(.+)$")
    if not refName then return raw end
    local tgt = KARDS.NodeParser.ResolveTarget(ctx, "t", refName)
    local v = tgt and KARDS.NodeParser.GetTarget(ctx, tgt)
    return tostring(v or "")
end

local ChoiceActs = {
    -- 抉择：询问玩家二选一，返回值即分支结果（true = 效果一 / false = 效果二）
    -- @param ctx     table  执行上下文（含 specify 选择注入）
    -- @param card    table  效果发起卡牌句柄（抉择卡本体，供演出模块定位卡实体）
    -- @param targets table  受影响卡牌列表（本节点不消费）
    -- @param item    table  语义项（sem 自身：act/text1/text2）
    -- @param node    table  节点实例（node.data 为槽值存储）
    -- @return boolean 是否选择效果一
    choice = function(ctx, card, targets, item, node)
        local t1 = ResolveText(ctx, ReadSlot(node, item.text1))
        local t2 = ResolveText(ctx, ReadSlot(node, item.text2))
        local pick = ctx and ctx.specify and ctx.specify.choicePicker
        local idx = 1 -- 无选择注入：缺省效果一
        if pick then
            local r = pick(card, t1, t2)
            if r == 2 or r == false then idx = 2 else idx = 1 end
        end
        return idx == 1
    end,
}

-- 执行器合并：choice 模板 handlers 合并进 BaseSemantics 分派表
-- （ExecuteBaseNode 经 sem.handlers 分派）
KARDS.NodeParser.BaseSemantics.choice.handlers = ChoiceActs