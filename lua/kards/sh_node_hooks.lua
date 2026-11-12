--[[
    节点解析系统：函数调用 / 触发函数 / 跨刻回合 / 事件钩子（hooks 层）

    自 sh_node_parser.lua 按职责拆分（re.md B-H3）：本文件承载
      - 函数调用机制：FindFunctionData / CallFunctionData / CallFunction（funcslot → 函数子图）
      - trigger_function 执行器（触发一次 / 保持触发 / 停止保持触发 / 拦截一次 / 保持拦截）
      - turn 执行器（跨刻等待 / 使回合推进）+ PendingTurns 挂起注册表 + ResumeTurnNodes / ResumeEffect
      - 事件钩子：RegisterAlwaysHook / TriggerAlwaysHooks / RegisterEventHook / TriggerEventHooks
    保持触发（keepTrigger/stopTrigger）与事件钩子均以 KARDS.EffectRegistry（re.md B-H2）
    为注册骨架：keepTrigger → EVENTS.TurnBegin，总是触发 → EVENTS.PlayCommand，条件触发 → 对应事件源；
    KeepTriggers / EventHooks / AlwaysHooks 表保留空表占位（兼容外部防御性引用，不再写入）。
    各执行器表在文件末尾合并 handlers 进 BaseSemantics 对应条目，
    ExecuteBaseNode（sh_node_parser.lua）经 sem.handlers 分派（行为与原 if/elseif 链一致）。

    跨文件共享（GLua 无跨文件 local）：ReadSlot / EnemyOf 由 sh_node_parser.lua 暴露，
    EnsureCtx 由 sh_node_semantics.lua 暴露，本文件开头取本地引用；
    ExecuteEffectFlow 经 KARDS.NodeParser 表访问（定义于 sh_effect_flow.lua，运行期安全）。

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_node_parser.lua 之后）
]]

KARDS = KARDS or {}
KARDS.NodeParser = KARDS.NodeParser or {}

-- 跨文件共享（GLua 无跨文件 local）：主文件/语义文件已暴露，本文件取本地引用
local ReadSlot = KARDS.NodeParser.ReadSlot
local EnemyOf = KARDS.NodeParser.EnemyOf
local EnsureCtx = KARDS.NodeParser.EnsureCtx

-- ====================================================================
-- 函数调用机制（funcslot 函数槽 → 函数子图「调用」开始点）
-- ====================================================================
-- register_hook 通用效果等节点经 funcslot 引用函数（编辑器函数子编辑器保存的子图）。
-- 调用语义：在函数子图的「调用」开始点创建信号，执行函数内节点效果；
-- 调用者节点同步等待函数效果全部完成后，再继续传递信号（Lua 单线程天然同步）。
-- 函数定义来源（优先级）：
--   1 局部函数：函数子编辑器保存到节点槽（node.data.slots[compId]._localFuncRef.functionData / .functionData）
--   2 效果级 functions 表（导出收集的非数组项函数：functions[函数名] = 子图）
--   3 全局函数变量（effect.variables["f"]，internalName 已带 KARDS.User. 前缀，name 为显示名）
local function FindFunctionData(ctx, funcName, node, compId)
    if not funcName or funcName == "" then return nil end
    local slot = node and node.data and node.data.slots and node.data.slots[compId]
    if slot then
        local localData = (slot._localFuncRef and slot._localFuncRef.functionData) or slot.functionData
        if localData and localData.nodes then return localData end
    end
    if ctx and ctx.functions and ctx.functions[funcName] and ctx.functions[funcName].nodes then
        return ctx.functions[funcName]
    end
    local vars = ctx and ctx.variables
    if vars and vars.f then
        for _, fv in ipairs(vars.f) do
            local fvName = (fv.name ~= nil and fv.name ~= "") and fv.name or fv.internalName
            if (fvName == funcName or fv.internalName == funcName) and fv.functionData and fv.functionData.nodes then
                return fv.functionData
            end
        end
    end
    return nil
end

-- 执行函数子图（调用者上下文隔离：函数内使用函数自己的 variables / dataConnections，执行后恢复调用者上下文）
-- @param ctx     table 执行上下文（EnsureCtx 防御）
-- @param card    table 调用时卡牌句柄（事件触发时为事件发起者，如敌方总部）
-- @param funcData table 函数子图 { nodes, connections, dataConnections, variables? }
-- @param targets table|nil 传递给函数内节点的目标集
-- @return boolean 函数效果是否至少成功执行一个节点
function KARDS.NodeParser.CallFunctionData(ctx, card, funcData, targets)
    ctx = EnsureCtx(ctx)
    if not funcData or not funcData.nodes then
        print("[NodeParser] CallFunctionData: 函数子图无效")
        return false
    end
    if #funcData.nodes == 0 then return true end -- 空函数视为成功
    -- 保存调用者上下文；函数内使用自己的 variables / dataConnections（隔离）
    local savedVars = ctx.variables
    local savedDC = ctx.dataConnections
    local savedNodesById = ctx._nodesById
    ctx.variables = funcData.variables or ctx.variables
    ctx.dataConnections = funcData.dataConnections or ctx.dataConnections
    local ok = KARDS.NodeParser.ExecuteEffect(ctx, card, targets or {}, funcData)
    ctx.variables = savedVars
    ctx.dataConnections = savedDC
    ctx._nodesById = savedNodesById
    return ok
end

-- 按函数名调用函数（查找函数定义 → 执行函数子图；同步等待完成后返回）
-- @param ctx      table 执行上下文
-- @param card     table 调用时卡牌句柄（效果发起卡）
-- @param funcName string 函数名（funcslot 槽值）
-- @param node     table|nil 引用函数的节点实例（局部函数定位用）
-- @param compId   string|nil funcslot 组件 ID（局部函数定位用）
-- @param targets  table|nil 传递给函数内节点的目标集
-- @return boolean 函数效果是否至少成功执行一个节点
function KARDS.NodeParser.CallFunction(ctx, card, funcName, node, compId, targets)
    ctx = EnsureCtx(ctx)
    local funcData = FindFunctionData(ctx, funcName, node, compId)
    if not funcData then
        print("[NodeParser] CallFunction: 找不到函数定义: " .. tostring(funcName))
        return false
    end
    return KARDS.NodeParser.CallFunctionData(ctx, card, funcData, targets)
end

-- ====================================================================
-- trigger_function 执行器（触发函数：立即执行 / 保持触发注册 / 拦截）
-- ====================================================================
-- 效果图标（select_5 选项，与模板 configs 顺序一致；拦截分支扩展后运行时 select 编号后移，
-- 见 sh_node_semantics.lua trigger_function 注释）：
--   1 主动效果 / 2 被动效果 / 3 无 / 4 @combat_keywords（引用战斗词条词汇表）
local TRIGGER_EFFECT_ICONS = {
    [1] = "主动效果",
    [2] = "被动效果",
    [3] = "无",
    [4] = "@combat_keywords",
}

-- 拦截分支操作类型选项（与模板 configs 拦截选择器选项顺序一致）：
-- 选项索引 → KARDS.TickLog.OpTypes 英文键（拦截注册按 args.opType 过滤）
local INTERCEPT_OPTYPES = {
    "play_command",     -- 打出指令
    "activate_counter", -- 激活反制
    "deploy",           -- 部署单位
    "move",             -- 移动
    "attack",           -- 攻击
    "retreat",          -- 撤退
    "engage",           -- 交战
    "fight",            -- 战斗
    "draw",             -- 抽取
    "discard",          -- 弃牌
    "summon",           -- 召唤
    "control",          -- 控制
    "deal_damage",      -- 伤害
    "stat_change",      -- 属性变更
    "remove",           -- 移除
    "return_to_hand",   -- 返回手牌
}

-- 保持触发注册表：已迁移至 KARDS.EffectRegistry（re.md B-H2）——
-- keepTrigger 注册到 EffectRegistry.EVENTS.TurnBegin，entry.entity 绑定目标实体，
-- entry.handler 判断「实体拥有者 == 当前回合玩家」时执行（保持触发语义不变）；
-- 目标实体离场自动注销（SimRemoveFromField 经 EffectRegistry.UnregisterByEntity，
-- 解决原「目标实体离场不自动注销」缺陷）。
-- KeepTriggers 表保留空表占位（兼容外部防御性引用，不再写入）。
KARDS.NodeParser.KeepTriggers = KARDS.NodeParser.KeepTriggers or {}

-- 触发保持触发：目标实体拥有者 == 当前回合玩家时，执行其注册的函数
-- @param tableID string 牌桌唯一标识符
-- @param player  string 当前回合玩家（SimBeginTurn 传入）
function KARDS.NodeParser.TriggerKeepTriggers(tableID, player)
    KARDS.EffectRegistry.Trigger(tableID, KARDS.EffectRegistry.EVENTS.TurnBegin, { player = player })
end

-- 延时效果证明（2026-11-07 用户规格）：保持触发 / 跨刻等待即将执行时，把「来源卡」交给
-- 实体层展示证明动画（服务端只传身份，动画由客户端本地播放）。
-- 经 KARDS.Battle:NotifyDelayedProof 依赖倒置（牌桌实体注册回调，见 sh_battle_card.lua）；
-- 无牌桌实体（纯逻辑测试）时静默，不影响效果执行。
-- @param tableID string 牌桌唯一标识符
-- @param card    table|nil 延时效果来源卡牌句柄（缺省不展示）
local function NotifyDelayedProof(tableID, card)
    if not tableID or not card then return end
    local battle = KARDS.Battle
    if battle and battle.NotifyDelayedProof then
        battle:NotifyDelayedProof(tableID, card)
    end
end

-- 保持触发注册项 ID（同节点重复执行覆盖旧注册；停止保持触发按同 ID 移除）
-- @param tableID string 牌桌唯一标识符
-- @param node    table 节点实例
-- @return string 注册项 ID
local function KeepTriggerID(tableID, node)
    return "ktf_" .. tostring(tableID) .. "_" .. tostring(node.id or node.name or "node")
end

-- 取 trigger_function 输出端口名（base 输出：(e目标、t效果图标类型)）
-- @param node      table 节点实例
-- @param outTarget string 缺省目标端口名
-- @param outIcon   string 缺省效果图标端口名
-- @return string, string 目标端口名, 效果图标端口名
local function TriggerOutNames(node, outTarget, outIcon)
    local struct = KARDS.NodeParser.ParseBaseStructure(node.base)
    local ot = struct.outputTypes
    return (ot[1] and ot[1].name) or outTarget, (ot[2] and ot[2].name) or outIcon
end

-- 数值修饰计算（属性变更收尾）
-- 修饰索引：1 增加 / 2 减少 / 3 设为 / 4 至多 / 5 至少
-- @param current number 操作原数值
-- @param modIdx  number 修饰索引
-- @param value   number 编辑器填写的数值
-- @return number 取整并夹在 0 到 99 的新数值
local function ApplyNumericModifier(current, modIdx, value)
    local v = tonumber(value) or 0
    if modIdx == 2 then
        current = current - v
    elseif modIdx == 3 then
        current = v
    elseif modIdx == 4 then
        current = math.min(current, v)
    elseif modIdx == 5 then
        current = math.max(current, v)
    else
        current = current + v
    end
    return math.max(0, math.min(99, math.floor(current)))
end

-- 拦截注册实现（interceptOnce / keepIntercept 共用）
-- M1.3（2026-10-05 反制）：注册目标由 OnBeforePlayCard 改为统一操作钩子 OnBeforeOperation，
-- 按节点声明的操作类型（拦截分支内操作类型选择器）过滤 args.opType。
-- 收尾方式（2026-11-05 属性变更）：
--   反制 = 函数执行成功即取消操作（args.intercepted = true）；
--   属性变更 = 不取消操作，按修饰改写 args.amount（args.modified = true），不要求函数槽。
-- @param ctx  table 执行上下文
-- @param card table 效果发起卡牌句柄（拦截钩子绑定实体，实体离场自动注销）
-- @param node table 节点实例（funcslot_1 函数 / 拦截分支操作类型与收尾方式选择器）
-- @param once boolean 是否拦截一次（true = 首次拦截后注销钩子；false = 持续拦截）
-- @return boolean 是否注册成功
local function RegisterIntercept(ctx, card, node, once)
    local branchIdx = once and 4 or 5
    local sem = KARDS.NodeParser.BaseSemantics.trigger_function.branches[branchIdx]
    -- 收尾方式：1 反制 / 2 属性变更；旧卡无该槽时回退反制
    local finish = tonumber(ReadSlot(node, sem.finishSelect)) or 1
    local modIdx = tonumber(ReadSlot(node, sem.modSelect)) or 1
    local valueRaw = sem.valueNumber and ReadSlot(node, sem.valueNumber) or 0
    local funcName = ReadSlot(node, "funcslot_1")
    -- 反制必须有函数；属性变更只改数值，函数槽可空
    if finish ~= 2 and (not funcName or funcName == "") then
        print("[NodeParser] trigger_function(拦截): 未选择函数（funcslot_1）")
        return false
    end
    local tableID = ctx.tableID or ctx.table_id
    local owner = card:GetOwner()
    local funcData
    if finish ~= 2 then
        funcData = FindFunctionData(ctx, funcName, node, "funcslot_1")
        if not funcData then
            print("[NodeParser] trigger_function(拦截): 找不到函数定义: " .. tostring(funcName))
            return false
        end
    end
    -- 操作类型：语义表给出本分支的操作类型选择组件 id（拦截一次 select_2 / 保持拦截 select_3），
    -- 选项值索引映射为 TickLog.OpTypes 英文键；旧格式效果无该槽时回退打出指令（保持既有反制行为）
    local opType = INTERCEPT_OPTYPES[tonumber(ReadSlot(node, sem.opSelect))] or "play_command"
    -- 钩子ID：同节点重复执行覆盖旧注册（幂等）
    local hookID = "tfi_" .. tostring(tableID) .. "_" .. tostring(node.id or node.name or "node")
    KARDS.EngineHooks.Register(tableID, KARDS.EngineHooks.HookPoints.OnBeforeOperation, hookID, function(args)
        -- 操作类型过滤：仅拦截本节点声明的操作类型
        if args.opType ~= opType then return args end
        -- 发起方归属：优先 args.player（无主动卡的操作如抽取/回合），其次 args.card 归属；
        -- 己方发起不拦截（发起方未知时按可拦截处理，符合「敌方操作皆可被反制」）
        local actor = args.player
        if not actor and args.card and args.card.GetOwner then actor = args.card:GetOwner() end
        if actor == owner then return args end
        local triggered = false
        if finish == 2 then
            -- 属性变更：改写操作数值，不取消操作；操作无数值参数时不触发
            if type(args.amount) ~= "number" then return args end
            local value = tonumber(KARDS.NodeParser.ResolveNumberValue(ctx, valueRaw)) or 0
            args.amount = ApplyNumericModifier(args.amount, modIdx, value)
            args.modified = true
            triggered = true
        else
            -- 反制：调用拦截函数，函数效果执行成功即视为「已拦截」（骨架约定，见 templates.md 拦截扩展）
            local ok = KARDS.NodeParser.CallFunctionData(ctx, args.card or actor, funcData, { args.card or actor })
            if ok then
                args.intercepted = true
                triggered = true
            end
        end
        if triggered then
            -- 事件音效（2026-08-13）：反制拦截触发 trigger——通知牌桌实体广播音效
            -- （无事件源实体，客户端回退音源方位为牌桌 WorldCenter，见 table_session.lua
            -- SetSoundCallback 注册 / sh_battle_combat.lua NotifyEventSound）
            if KARDS.Battle and KARDS.Battle.NotifyEventSound then
                KARDS.Battle:NotifyEventSound(tableID, "trigger", card)
            end
            -- 拦截一次：先注销钩子，再播放反制，避免反制自身效果写入再次命中本钩子
            if once then
                KARDS.EngineHooks.Unregister(tableID, KARDS.EngineHooks.HookPoints.OnBeforeOperation, hookID)
            end
            -- 反制自动打出（M5.1）：绑定卡为已激活的反制时，命中敌方操作 → 自动打出
            -- （移出手牌、公开隐藏花费、按指令口径广播动画，见 sh_battle_card.lua FireCounter）
            if KARDS.Counter and KARDS.Counter:IsActive(tableID, card)
                and KARDS.Battle and KARDS.Battle.FireCounter then
                KARDS.Battle:FireCounter(tableID, card, args)
            end
        end
        return args
    end, KARDS.EngineHooks.TYPE_EFFECT, card)
    local outTarget, outIcon = TriggerOutNames(node, "目标", "效果图标类型")
    node.data[outTarget] = { card }
    node.data[outIcon] = TRIGGER_EFFECT_ICONS[tonumber(ReadSlot(node, "select_5")) or 2]
    return true
end

local TriggerFunctionActs = {
    -- 触发一次：立即同步调用函数子图（函数内节点效果全部完成后本节点再继续传递信号）
    triggerOnce = function(ctx, card, targets, item, node)
        local funcName = ReadSlot(node, "funcslot_1")
        if not funcName or funcName == "" then
            print("[NodeParser] trigger_function(触发一次): 未选择函数（funcslot_1）")
            return false
        end
        local ok = KARDS.NodeParser.CallFunction(ctx, card, funcName, node, "funcslot_1", targets)
        if not ok then
            print("[NodeParser] trigger_function(触发一次): 函数调用失败: " .. tostring(funcName))
            return false
        end
        local outTarget, outIcon = TriggerOutNames(node, "目标", "效果图标类型")
        node.data[outTarget] = targets
        node.data[outIcon] = TRIGGER_EFFECT_ICONS[tonumber(ReadSlot(node, "select_5")) or 2]
        return true
    end,
    -- 保持触发：将函数注册到目标实体（e 输入首个目标），实体拥有者回合开始自动执行
    keepTrigger = function(ctx, card, targets, item, node)
        local funcName = ReadSlot(node, "funcslot_1")
        if not funcName or funcName == "" then
            print("[NodeParser] trigger_function(保持触发): 未选择函数（funcslot_1）")
            return false
        end
        local entity = targets[1]
        if not entity then
            print("[NodeParser] trigger_function(保持触发): 缺少注册目标（e 输入为空）")
            return false
        end
        local tableID = ctx.tableID or ctx.table_id
        local funcData = FindFunctionData(ctx, funcName, node, "funcslot_1")
        if not funcData then
            print("[NodeParser] trigger_function(保持触发): 找不到函数定义: " .. tostring(funcName))
            return false
        end
        local regID = KeepTriggerID(tableID, node)
        local owner = card:GetOwner()
        -- 注册到 EffectRegistry（re.md B-H2）：事件源 TurnBegin，entity 绑定目标（离场自动注销），
        -- handler 判断实体拥有者 == 当前回合玩家（保持触发语义，同节点重复注册覆盖幂等）
        KARDS.EffectRegistry.Register(tableID, KARDS.EffectRegistry.EVENTS.TurnBegin, regID, {
            owner = owner,
            entity = entity,
            handler = function(payload)
                -- 仅注册者回合开始执行（如「方面军」友方回合开始）
                if entity:GetOwner() == payload.player then
                    -- 延时效果证明：执行前展示来源卡（2026-11-07 用户规格）
                    NotifyDelayedProof(tableID, card)
                    KARDS.NodeParser.CallFunctionData(ctx, entity, funcData, { entity })
                end
            end,
        })
        local outTarget, outIcon = TriggerOutNames(node, "目标", "效果图标类型")
        node.data[outTarget] = { entity }
        node.data[outIcon] = TRIGGER_EFFECT_ICONS[tonumber(ReadSlot(node, "select_5")) or 2]
        return true
    end,
    -- 停止保持触发：移除本节点注册的保持触发（同注册 ID，EffectRegistry 注销）
    stopTrigger = function(ctx, card, targets, item, node)
        local entity = targets[1]
        local tableID = ctx.tableID or ctx.table_id
        if not entity then return false end
        local regID = KeepTriggerID(tableID, node)
        return KARDS.EffectRegistry.Unregister(tableID, KARDS.EffectRegistry.EVENTS.TurnBegin, regID)
    end,
    -- 拦截一次：注册 OnBeforePlayCard 拦截钩子，首次拦截敌方指令后自动注销
    interceptOnce = function(ctx, card, targets, item, node)
        return RegisterIntercept(ctx, card, node, true)
    end,
    -- 保持拦截：持续拦截敌方打出指令（单位/总部卡在场期间）
    keepIntercept = function(ctx, card, targets, item, node)
        return RegisterIntercept(ctx, card, node, false)
    end,
}

-- ====================================================================
-- turn 执行器（回合：跨刻等待 / 使回合推进）
-- ====================================================================
-- 「等待」：效果跨刻挂起——注册到 PendingTurns[tableID]，本节点 data._turnPaused 置位；
--   ExecuteEffectFlow 检测到挂起标记后停止沿连线继续（信号停滞在该节点），
--   后续由 SimBeginTurn / SimEndTurn 触发 ResumeTurnNodes 推进计数，
--   达到要求次数后从本节点 output 后继恢复执行。
-- 「使」：立即推进回合——回合结束 = SimEndTurn(当前回合玩家)；跳过回合 = SimEndTurn(当前) + SimBeginTurn(对手)。
-- 当前回合玩家由战斗骨架记录（KARDS.Battle.CurTurnPlayer[tableID]，SimBeginTurn 写入）。

-- 跨刻挂起注册表：PendingTurns[tableID] = { { id, owner, side, phase, times, current,
--     effect, ctx, card, targets, nodeId } }
--   owner 打出指令的玩家（阵营匹配基准）；side 1 友方 / 2 敌方 / 3 任意
--   phase "turn_begin"（开始）/ "turn_end"（结束）；times 需等待次数；current 已匹配次数
--   effect / ctx / card / targets / nodeId 供达标后恢复执行（ResumeEffect）
KARDS.NodeParser.PendingTurns = KARDS.NodeParser.PendingTurns or {}
-- 挂接 EffectRegistry 每桌清理（StartBattle 经 EffectRegistry:Clear 统一清理，re.md B-H2）
KARDS.EffectRegistry.ClearCallbacks["node_parser_pending_turns"] = function(tableID)
    KARDS.NodeParser.PendingTurns[tableID] = nil
end

-- 挂起注册项 ID（同效果同节点重复挂起覆盖旧注册，幂等）
-- @param tableID string 牌桌唯一标识符
-- @param node    table 节点实例
-- @return string 注册项 ID
local function TurnPendingID(tableID, node)
    return "tpn_" .. tostring(tableID) .. "_" .. tostring(node.id or node.name or "node")
end

local TurnActs = {
    -- 等待：注册跨刻挂起（总是挂起，不检查当前时刻；后续由时间刻入口推进计数）
    waitTurn = function(ctx, card, targets, item, node)
        local side = tonumber(ReadSlot(node, item.side)) or 3 -- 友方1/敌方2/任意3
        local phaseNum = tonumber(ReadSlot(node, item.phase)) or 1 -- 开始1/结束2
        local times = tonumber(KARDS.NodeParser.ResolveNumberValue(ctx, ReadSlot(node, item.times))) or 1
        local tableID = ctx.tableID or ctx.table_id
        local owner = card and card:GetOwner()
        local effect = ctx._currentEffect
        if not effect or not effect.nodes then
            print("[NodeParser] turn(等待): 缺少当前效果数据（ctx._currentEffect 未设置）")
            return false
        end
        local list = KARDS.NodeParser.PendingTurns[tableID] or {}
        local pendID = TurnPendingID(tableID, node)
        for i = #list, 1, -1 do -- 同节点重复挂起覆盖旧注册（幂等）
            if list[i].id == pendID then table.remove(list, i) end
        end
        table.insert(list, {
            id = pendID, owner = owner, side = side,
            phase = (phaseNum == 2) and "turn_end" or "turn_begin",
            times = times, current = 0,
            effect = effect, ctx = ctx, card = card, targets = targets or {},
            nodeId = node.id,
        })
        KARDS.NodeParser.PendingTurns[tableID] = list
        node.data._turnPaused = true -- 信号停滞标记（ExecuteEffectFlow 检测后停止沿连线继续）
        return true
    end,
    -- 使：立即推进目标归属的回合（不挂起，本节点执行后信号正常继续）
    -- 2026-08-14 增加归属维度：side 归属（友方1=效果拥有者 / 敌方2=其对手）× op 动作
    -- （回合结束1 / 跳过回合2）
    makeTurn = function(ctx, card, targets, item, node)
        local side = tonumber(ReadSlot(node, item.side)) or 1 -- 友方1/敌方2
        local op = tonumber(ReadSlot(node, item.op)) or 1 -- 回合结束1/跳过回合2
        local battle = ctx.battle or KARDS.Battle
        local tableID = ctx.tableID or battle.TableID
        local owner = card and card:GetOwner()
        if not owner then
            print("[NodeParser] turn(使): 缺少效果拥有者（card:GetOwner() 为空）")
            return false
        end
        local target = (side == 1) and owner or EnemyOf(owner)
        if op == 1 then -- 回合结束：结束目标归属回合（友方=效果拥有者 / 敌方=其对手）
            return battle:SimEndTurn(target) ~= false
        end
        -- 跳过回合：结束目标归属回合 + 开始其对手回合
        local ok = battle:SimEndTurn(target) ~= false
        local opp = EnemyOf(target)
        if opp then
            ok = battle:SimBeginTurn(opp) ~= false and ok
        end
        return ok
    end,
}

-- 推进跨刻挂起：回合时间刻入口（SimBeginTurn / SimEndTurn）调用
-- 匹配挂起条目的阵营要求与时刻（phase）后 current+1；达标（current >= times）则恢复效果执行
-- @param tableID  string 牌桌唯一标识符
-- @param player   string 当前回合玩家（开始回合的玩家 / 结束回合的玩家）
-- @param eventKey string 时刻键（"turn_begin" 开始 / "turn_end" 结束）
function KARDS.NodeParser.ResumeTurnNodes(tableID, player, eventKey)
    local list = KARDS.NodeParser.PendingTurns and KARDS.NodeParser.PendingTurns[tableID]
    if not list then return end
    for i = #list, 1, -1 do
        local p = list[i]
        if p.phase == eventKey then
            -- 阵营匹配：任意 恒匹配；友方 = 回合玩家 == 注册者；敌方 = 回合玩家 ~= 注册者
            local matched = (p.side == 3)
                or (p.side == 1 and player == p.owner)
                or (p.side == 2 and player ~= p.owner)
            if matched then
                p.current = p.current + 1
                if p.current >= p.times then
                    table.remove(list, i)
                    -- 延时效果证明：恢复执行前展示来源卡（2026-11-07 用户规格）
                    NotifyDelayedProof(tableID, p.card)
                    KARDS.NodeParser.ResumeEffect(p.ctx, p.card, p.targets, p.effect, p.nodeId)
                end
            end
        end
    end
    if #list == 0 then
        KARDS.NodeParser.PendingTurns[tableID] = nil
    end
end

-- 恢复跨刻挂起的效果：从挂起节点（startNodeId，turn「等待」）沿 output 连线继续执行
-- （挂起节点本身不再次执行；顺序模式从挂起节点后一节点继续）
-- @param ctx         table 执行上下文（挂起时保存）
-- @param card        table 效果发起卡牌句柄
-- @param targets     table 受影响卡牌列表
-- @param effect      table 效果数据（nodes / connections）
-- @param startNodeId any|nil 挂起的 turn 节点 id（缺省从入口执行）
-- @return boolean 是否至少成功执行一个节点
function KARDS.NodeParser.ResumeEffect(ctx, card, targets, effect, startNodeId)
    ctx = EnsureCtx(ctx)
    if not effect or not effect.nodes or #effect.nodes == 0 then return false end
    ctx.variables = effect.variables or ctx.variables
    ctx.dataConnections = effect.dataConnections or ctx.dataConnections
    if effect.connections and #effect.connections > 0 then
        -- 控制流模式：从挂起节点沿 output 连线继续（ExecuteEffectFlow 定义于 sh_effect_flow.lua，
        -- 此处经 KARDS.NodeParser 表访问；加载完成后由 ExecuteEffectFlow 定义处暴露）
        return KARDS.NodeParser.ExecuteEffectFlow(ctx, card, targets, effect, startNodeId)
    end
    -- 顺序模式：定位挂起节点，从其数组后继继续执行（无连线时的「信号继续」语义）
    local startIdx = nil
    for i, n in ipairs(effect.nodes) do
        if n.id == startNodeId then startIdx = i break end
    end
    if not startIdx then return false end
    local executed = false
    for i = startIdx + 1, #effect.nodes do
        local node = effect.nodes[i]
        local ok = KARDS.NodeParser.ExecuteBaseNode(ctx, card, targets, node)
        if ok then executed = true end
        if node.data and node.data._turnPaused then
            node.data._turnPaused = nil -- 清除挂起标记（本次恢复停止，等待下一次时间刻推进）
            break
        end
    end
    return executed
end

-- ====================================================================
-- 事件钩子注册表（register_hook 通用效果·条件触发）
-- ====================================================================
-- 条件触发注册的事件监听：事件发生时（战斗骨架入口触发 TriggerEventHooks）调用函数。
-- 事件键映射 REGISTER_HOOK_EVENTS 见上方（RegisterHookActs 之前声明）。

-- 事件钩子注册表：已迁移至 KARDS.EffectRegistry（re.md B-H2）——
-- 条件触发（RegisterEventHook）注册到 eventKey 事件源，side 匹配由框架按 initiatorCard 判定；
-- 总是触发（RegisterAlwaysHook）注册到独立事件源（打出指令成功时经 TriggerAlwaysHooks 触发），
-- 不与条件钩子共用 PlayCommand 事件键——否则 SimPlayCard 中 TriggerEventHooks("play_command")
-- 与 TriggerAlwaysHooks 会各自触发一次，造成同一打出调用函数两次（side=nil 恒匹配）。
-- EventHooks / AlwaysHooks 表保留空表占位（兼容外部防御性引用，不再写入）。
KARDS.NodeParser.EventHooks = KARDS.NodeParser.EventHooks or {}
KARDS.NodeParser.AlwaysHooks = KARDS.NodeParser.AlwaysHooks or {}

-- 总是触发钩子的 EffectRegistry 事件键（独立于 EVENTS.PlayCommand，见上注释）
local ALWAYS_TRIGGER_EVENT = "always_trigger"

-- 注册「总是触发」持续钩子（同函数名重复注册覆盖，幂等）
-- @param tableID  string 牌桌唯一标识符
-- @param owner    string 注册者玩家（保留字段，未来「总是触发」阵营限定扩展用）
-- @param funcName string 函数名
-- @param node     table|nil 引用函数的节点实例（局部函数定位用）
-- @param compId   string|nil funcslot 组件 ID
-- @param ctx      table 执行上下文（调用函数用，存引用）
-- @return boolean 是否注册成功（函数定义不存在返回 false）
function KARDS.NodeParser.RegisterAlwaysHook(tableID, owner, funcName, node, compId, ctx)
    ctx = EnsureCtx(ctx)
    local funcData = FindFunctionData(ctx, funcName, node, compId)
    if not funcData then
        print("[NodeParser] RegisterAlwaysHook: 找不到函数定义: " .. tostring(funcName))
        return false
    end
    local hookID = "rah_" .. tostring(tableID) .. "_" .. tostring(funcName)
    -- 注册到 EffectRegistry：独立事件源（打出指令成功经 TriggerAlwaysHooks 触发，含注册本次的打出）
    return KARDS.EffectRegistry.Register(tableID, ALWAYS_TRIGGER_EVENT, hookID, {
        owner = owner,
        handler = function(payload)
            KARDS.NodeParser.CallFunctionData(ctx, payload.initiatorCard, funcData, {})
        end,
    })
end

-- 触发「总是触发」钩子：打出指令成功时（SimPlayCard 结尾）调用所有已注册函数
-- @param tableID       string 牌桌唯一标识符
-- @param initiatorCard table 本次打出指令卡牌句柄（作为函数发起者传入）
function KARDS.NodeParser.TriggerAlwaysHooks(tableID, initiatorCard)
    if not initiatorCard then return end
    KARDS.EffectRegistry.Trigger(tableID, ALWAYS_TRIGGER_EVENT, { initiatorCard = initiatorCard })
end

-- 注册条件触发事件钩子（同钩子ID重复注册覆盖，幂等）
-- @param tableID  string 牌桌唯一标识符
-- @param eventKey string 事件键（REGISTER_HOOK_EVENTS 之一）
-- @param owner    string 注册者玩家（阵营匹配基准）
-- @param side     number 事件阵营（1 敌方 / 2 友方）
-- @param funcName string 函数名
-- @param node     table|nil 引用函数的节点实例（局部函数定位用）
-- @param compId   string|nil funcslot 组件 ID
-- @param ctx      table 执行上下文（调用函数用，存引用）
-- @return boolean 是否注册成功（函数定义不存在返回 false）
function KARDS.NodeParser.RegisterEventHook(tableID, eventKey, owner, side, funcName, node, compId, ctx)
    ctx = EnsureCtx(ctx)
    local funcData = FindFunctionData(ctx, funcName, node, compId)
    if not funcData then
        print("[NodeParser] RegisterEventHook: 找不到函数定义: " .. tostring(funcName))
        return false
    end
    local hookID = "rhe_" .. tostring(tableID) .. "_" .. eventKey .. "_" .. tostring(funcName)
    -- 注册到 EffectRegistry：side 匹配（1 敌方 = 发起者≠owner / 2 友方 = 发起者==owner）由框架按 initiatorCard 判定
    return KARDS.EffectRegistry.Register(tableID, eventKey, hookID, {
        owner = owner,
        side = side,
        handler = function(payload)
            KARDS.NodeParser.CallFunctionData(ctx, payload.initiatorCard, funcData, {})
        end,
    })
end

-- 触发事件钩子：战斗骨架入口在事件发生时调用（SimBeginTurn / SimEndTurn / SimDeploy / SimPlayCard）
-- 阵营匹配（side：1 敌方 = 发起者 ≠ 注册者 / 2 友方 = 发起者 == 注册者）由 EffectRegistry 框架判定
-- @param tableID       string 牌桌唯一标识符
-- @param eventKey      string 事件键
-- @param initiatorCard table 事件发起者卡牌句柄（阵营匹配基准）
function KARDS.NodeParser.TriggerEventHooks(tableID, eventKey, initiatorCard)
    if not initiatorCard then return end
    KARDS.EffectRegistry.Trigger(tableID, eventKey, { initiatorCard = initiatorCard })
end

-- ====================================================================
-- 执行器合并：各模板 handlers 合并进 BaseSemantics 分派表
-- （ExecuteBaseNode 经 sem.handlers 分派，行为与原 if/elseif 链一致）
-- ====================================================================
KARDS.NodeParser.BaseSemantics.trigger_function.handlers = TriggerFunctionActs
KARDS.NodeParser.BaseSemantics.turn.handlers = TurnActs
