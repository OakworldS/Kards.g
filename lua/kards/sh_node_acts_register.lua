--[[
    节点解析系统：注册/属性执行器（register_hook / trigger）

    自 sh_node_parser.lua 按职责拆分（re.md B-H3）：本文件承载「注册与属性域」模板的执行器表
    与配套辅助（ApplyModify / REGISTER_HOOK_EVENTS / TriggerStatOutNames）。
    各表在文件末尾合并 handlers 进 BaseSemantics 对应条目，
    ExecuteBaseNode（sh_node_parser.lua）经 sem.handlers 分派（行为与原 if/elseif 链一致）。

    跨文件共享（GLua 无跨文件 local）：ReadSlot 由 sh_node_parser.lua 暴露，本文件开头取本地引用。

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_node_parser.lua 之后）
]]

KARDS = KARDS or {}
KARDS.NodeParser = KARDS.NodeParser or {}

-- 跨文件共享（GLua 无跨文件 local）：主文件（sh_node_parser.lua）已暴露，本文件取本地引用
local ReadSlot = KARDS.NodeParser.ReadSlot

-- ====================================================================
-- 语义动作执行器（register_hook 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, targets, item, node)
--   ctx     执行上下文（含 tableID）
--   card    效果发起卡牌句柄（指令卡；同时作为「存活在场」作用域的绑定实体）
--   targets 未使用（register_hook 无对象槽输入）
--   item    语义项（registerModifier / registerEffect）
--   node    节点实例（组件 ID 见 BaseSemantics.register_hook 注释）
-- 一般属性修饰（registerModifier）经 KARDS.EngineHooks.Register 挂到引擎钩子点（sh_engine_hooks.lua）：
--   damage  → OnModifyDamage（args.attacker/defender/damage）
--   attack  → OnModifyStat（args.card/stat/value）
--   defense → OnModifyStat
local ApplyModify = function(op, value, amount)
    if op == 1 then return value + amount end -- 增加
    if op == 2 then return value - amount end -- 减少
    return amount -- 设为
end

-- 事件钩子事件键映射（register_hook 通用效果·条件触发，select_8 选项 1-5 → 骨架事件键）：
--   回合开始 turn_begin / 回合结束 turn_end / 部署单位 deploy /
--   打出指令 play_command / 触发反制 counter（拦截时 SimPlayCard 触发，M4b/M6）
-- 声明必须早于 RegisterHookActs（registerEffect 闭包内引用，见下）
local REGISTER_HOOK_EVENTS = {
    [1] = "turn_begin",
    [2] = "turn_end",
    [3] = "deploy",
    [4] = "play_command",
    [5] = "counter",
}

local RegisterHookActs = {
    -- 一般属性修饰：向引擎钩子点注册持续数值修饰回调
    registerModifier = function(ctx, card, targets, item, node)
        local tableID = ctx.tableID or ctx.table_id
        local owner = card:GetOwner()
        local targetSel = tonumber(ReadSlot(node, "select_2")) or 1 -- 敌方1/友方2/所有3
        local object = tonumber(ReadSlot(node, "select_3")) or 1     -- 造成的伤害1/攻击力2/防御力3
        local op = tonumber(ReadSlot(node, "select_4")) or 1         -- 增加1/减少2/设为3
        local amount = tonumber(ReadSlot(node, "number_1")) or 0
        local scope = tonumber(ReadSlot(node, "select_5")) or 2      -- 存活在场1/永久2
        local binder = card -- 存活在场作用域绑定效果发起卡（离场即失效）
        -- 钩子ID：同节点重复执行覆盖旧注册（幂等）
        local hookID = "rh_" .. tostring(tableID) .. "_" .. tostring(node.id or node.name or "node")
        -- 输出端口名（p钩子ID）
        local struct = KARDS.NodeParser.ParseBaseStructure(node.base)
        local outName = (struct.outputTypes[1] and struct.outputTypes[1].name) or "钩子ID"
        -- 作用目标匹配：伤害来源 / 卡牌阵营 是否命中（以注册者 owner 为基准）
        local targetMode = (targetSel == 2) and "friendly" or (targetSel == 3) and "all" or "enemy"
        local function matchOwner(srcOwner)
            if not srcOwner then return false end
            if targetMode == "all" then return true end
            if targetMode == "friendly" then return srcOwner == owner end
            return srcOwner ~= owner -- 敌方
        end
        -- 作用域：存活在场时检查绑定实体是否仍在场
        local function binderAlive()
            if scope ~= 1 then return true end -- 永久
            return KARDS.Battlefield:FindCardZone(tableID, binder) ~= nil
        end
        if object == 1 then
            KARDS.EngineHooks.Register(tableID, KARDS.EngineHooks.HookPoints.OnModifyDamage, hookID, function(args)
                if not binderAlive() then return args end
                local src = args.attacker or args.source
                if src and not matchOwner(src:GetOwner()) then return args end
                args.damage = math.max(0, ApplyModify(op, tonumber(args.damage) or 0, amount))
                return args
            end, KARDS.EngineHooks.TYPE_MODIFY, binder)
        else
            local stat = (object == 2) and "attack" or "defense"
            KARDS.EngineHooks.Register(tableID, KARDS.EngineHooks.HookPoints.OnModifyStat, hookID, function(args)
                if not binderAlive() then return args end
                if args.stat ~= stat then return args end
                local c = args.card
                if not c or not matchOwner(c:GetOwner()) then return args end
                args.value = ApplyModify(op, tonumber(args.value) or 0, amount)
                return args
            end, KARDS.EngineHooks.TYPE_MODIFY, binder)
        end
        node.data[outName] = hookID
        return true
    end,
    -- 通用效果：调用函数（总是触发立即调用 / 条件触发注册事件钩子，事件发生时调用）
    registerEffect = function(ctx, card, targets, item, node)
        local tableID = ctx.tableID or ctx.table_id
        local owner = card:GetOwner()
        local triggerMode = tonumber(ReadSlot(node, "select_6")) or 1 -- 总是触发1 / 条件触发2
        local funcName = ReadSlot(node, "funcslot_1")                -- 函数槽选中的函数名
        if not funcName or funcName == "" then
            print("[NodeParser] register_hook(通用效果): 未选择函数（funcslot_1）")
            return false
        end
        -- 钩子ID：同节点重复执行覆盖旧注册（幂等）
        local hookID = "rh_eff_" .. tostring(tableID) .. "_" .. tostring(node.id or node.name or "node")
        if triggerMode == 1 then
            -- 总是触发：注册持续钩子（AlwaysHooks），此后每次打出指令（SimPlayCard 成功）都调用函数
            -- （含注册本次的打出；与「立即调用一次」的区别：注册后每次打出指令均触发，M5）
            local ok = KARDS.NodeParser.RegisterAlwaysHook(tableID, owner, funcName, node, "funcslot_1", ctx)
            if not ok then
                print("[NodeParser] register_hook(通用效果·总是触发): 函数注册失败: " .. tostring(funcName))
                return false
            end
        else
            -- 条件触发：注册事件钩子（select_7 事件阵营 × select_8 事件类型），事件发生时调用函数
            local side = tonumber(ReadSlot(node, "select_7")) or 1 -- 敌方1 / 友方2
            local eventIdx = tonumber(ReadSlot(node, "select_8")) or 1
            local eventKey = REGISTER_HOOK_EVENTS[eventIdx]
            if not eventKey then
                print("[NodeParser] register_hook(通用效果·条件触发): 未知事件类型: " .. tostring(eventIdx))
                return false
            end
            local ok = KARDS.NodeParser.RegisterEventHook(tableID, eventKey, owner, side, funcName, node, "funcslot_1", ctx)
            if not ok then
                print("[NodeParser] register_hook(通用效果·条件触发): 事件钩子注册失败: " .. tostring(funcName))
                return false
            end
        end
        -- 输出端口名（p钩子ID）
        local struct = KARDS.NodeParser.ParseBaseStructure(node.base)
        local outName = (struct.outputTypes[1] and struct.outputTypes[1].name) or "钩子ID"
        node.data[outName] = hookID
        return true
    end,
}

-- ====================================================================
-- trigger 执行器（属性与伤害：修改攻击/防御或造成伤害）
-- ====================================================================
-- 目标卡牌 = e 输入数据线 targets（模板 select_1 为卡牌对象选择 {$}，槽值恒 1）
-- 输出端口名解析（base 输出：(n攻击力、n防御力)），写入第一个目标的修改后属性值供数据线

-- 取 trigger 输出端口名（base 输出：(n攻击力、n防御力)）
-- @param node       table 节点实例
-- @param outAttack  string 缺省攻击力端口名
-- @param outDefense string 缺省防御力端口名
-- @return string, string 攻击力端口名, 防御力端口名
local function TriggerStatOutNames(node, outAttack, outDefense)
    local struct = KARDS.NodeParser.ParseBaseStructure(node.base)
    local ot = struct.outputTypes
    return (ot[1] and ot[1].name) or outAttack, (ot[2] and ot[2].name) or outDefense
end

local TriggerActs = {
    -- 攻击：目标卡牌攻击力 设为1/增加2/减少3 number_1（复用 SetCardField + stat_change 刻）
    modifyAttack = function(ctx, card, targets, item, node)
        local amount = KARDS.NodeParser.ResolveNumberValue(ctx, ReadSlot(node, item.amount)) or 0
        local op = tonumber(ReadSlot(node, item.op)) or 1 -- 设为1/增加2/减少3
        local modifier = (op == 2) and "increase" or (op == 3) and "decrease" or "set"
        local ok = false
        for _, t in ipairs(targets) do
            if t then
                local old = t:GetStat("attack") or 0
                if KARDS.NodeParser.SetCardField(t, "attack", amount, modifier) then
                    local change = (op == 2) and ("+" .. amount) or (op == 3) and ("-" .. amount) or ("=" .. amount)
                    KARDS.NodeParser.PushStatChange(ctx, t, change)
                    -- 2026-08-12（t4 3D2D 数值同步）：SetCardField 直接改数据层属性，
                    -- 不经 SimDealDamage/SimFight → 按桌触发回调刷新战场实体 NW
                    -- （牌桌实体注册，见 table_battledeck.lua OnBattleStatsChanged）
                    KARDS.Battle:NotifyStatsChangedByTable(ctx.tableID, t)
                    -- 2026-08-13（stat_change.ogg 播放时机）：属性与伤害节点「攻击」分支 →
                    -- 触发属性变化音效（客户端播 stat_change.ogg，见 sh_battle_combat.lua
                    -- NotifyStatSound / table_battledeck.lua BroadcastStatChangeSound）
                    KARDS.Battle:NotifyStatSound(ctx.tableID)
                    -- 飘字（2026-08-14）：节点「攻击」分支 → 设为/减少白色、增加绿色
                    KARDS.Battle:NotifyStatFXByTable(ctx.tableID, t, "attack", (t:GetStat("attack") or 0) - old, modifier, "node")
                    ok = true
                end
            end
        end
        local outAttack, outDefense = TriggerStatOutNames(node, "攻击力", "防御力")
        local first = targets[1]
        node.data[outAttack] = first and first:GetStat("attack") or nil
        node.data[outDefense] = first and first:GetStat("defense") or nil
        return ok
    end,
    -- 防御：目标卡牌防御力 受到1/设为2/增加3/减少4 number_2
    --   「受到」= 受到伤害（SimDealDamage 伤害结算，触发 OnModifyDamage 修饰 + deal_damage 刻）
    modifyDefense = function(ctx, card, targets, item, node)
        local amount = KARDS.NodeParser.ResolveNumberValue(ctx, ReadSlot(node, item.amount)) or 0
        local op = tonumber(ReadSlot(node, item.op)) or 1 -- 受到1/设为2/增加3/减少4
        local ok = false
        for _, t in ipairs(targets) do
            if not t then break end
            if op == 1 then -- 受到：伤害结算（防御 -N）
                KARDS.Battle:SimDealDamage(card, t, amount)
                ok = true
            else
                local modifier = (op == 3) and "increase" or (op == 4) and "decrease" or "set"
                local old = t:GetStat("defense") or 0
                if KARDS.NodeParser.SetCardField(t, "defense", amount, modifier) then
                    local change = (op == 3) and ("+" .. amount) or (op == 4) and ("-" .. amount) or ("=" .. amount)
                    KARDS.NodeParser.PushStatChange(ctx, t, change)
                    -- 2026-08-12（t4 3D2D 数值同步）：同 modifyAttack，SetCardField 直接改
                    -- 数据层属性 → 按桌触发回调刷新战场实体 NW
                    KARDS.Battle:NotifyStatsChangedByTable(ctx.tableID, t)
                    -- 2026-08-13（stat_change.ogg 播放时机）：属性与伤害节点「防御」分支
                    -- （非「受到」）→ 触发属性变化音效；「受到」走 SimDealDamage 不触发
                    KARDS.Battle:NotifyStatSound(ctx.tableID)
                    -- 飘字（2026-08-14）：节点「防御」分支（非「受到」）→ 设为/减少白色、增加绿色
                    KARDS.Battle:NotifyStatFXByTable(ctx.tableID, t, "defense", (t:GetStat("defense") or 0) - old, modifier, "node")
                    ok = true
                end
            end
        end
        local outAttack, outDefense = TriggerStatOutNames(node, "攻击力", "防御力")
        local first = targets[1]
        node.data[outAttack] = first and first:GetStat("attack") or nil
        node.data[outDefense] = first and first:GetStat("defense") or nil
        return ok
    end,
    -- 受到伤害：目标卡牌受到 number_3 点伤害（SimDealDamage 伤害结算，总部亦可为目标）
    damage = function(ctx, card, targets, item, node)
        local amount = KARDS.NodeParser.ResolveNumberValue(ctx, ReadSlot(node, item.amount)) or 0
        local ok = false
        for _, t in ipairs(targets) do
            if t then
                KARDS.Battle:SimDealDamage(card, t, amount)
                ok = true
            end
        end
        local outAttack, outDefense = TriggerStatOutNames(node, "攻击力", "防御力")
        local first = targets[1]
        node.data[outAttack] = first and first:GetStat("attack") or nil
        node.data[outDefense] = first and first:GetStat("defense") or nil
        return ok
    end,
}

-- ====================================================================
-- 执行器合并：各模板 handlers 合并进 BaseSemantics 分派表
-- （ExecuteBaseNode 经 sem.handlers 分派，行为与原 if/elseif 链一致）
-- ====================================================================
KARDS.NodeParser.BaseSemantics.register_hook.handlers = RegisterHookActs
KARDS.NodeParser.BaseSemantics.trigger.handlers = TriggerActs
