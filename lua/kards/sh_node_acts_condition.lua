--[[
    节点解析系统：判断/监测/选择语义动作执行器（condition / event_monitor / target_selector）

    自 sh_node_parser.lua 按职责拆分（re.md B-H3）：本文件承载「判断域」模板的执行器表
    与配套辅助（EVENT_MONITOR_INFO / TickAbilityIds / StatChangeMatchesAttr /
    TSGetAttr / TARGET_UNIT_TYPES / TSCollectUnits）。
    各表在文件末尾合并 handlers 进 BaseSemantics 对应条目，
    ExecuteBaseNode（sh_node_parser.lua）经 sem.handlers 分派（行为与原 if/elseif 链一致）。

    跨文件共享（GLua 无跨文件 local）：ReadSlot / EnemyOf 由 sh_node_parser.lua 暴露，
    本文件开头取本地引用。

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_node_parser.lua 之后）
]]

KARDS = KARDS or {}
KARDS.NodeParser = KARDS.NodeParser or {}

-- 跨文件共享（GLua 无跨文件 local）：主文件（sh_node_parser.lua）已暴露，本文件取本地引用
local ReadSlot = KARDS.NodeParser.ReadSlot
local EnemyOf = KARDS.NodeParser.EnemyOf

-- ====================================================================
-- 语义动作执行器（condition 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, targets, item, node)
--   ctx     执行上下文（含 tableID / _T）
--   card    效果发起卡牌句柄（指令卡）
--   targets 受影响卡牌列表（condition 不使用，忽略）
--   item    语义项（含 side/countType/operator/value 等组件 ID）
--   node    节点实例（经 ReadSlot 读取组件值）
-- 结果存储于 node.data 供下游数据线消费：
--   node.data["n比较结果"] = number（实际统计值 / 计数）
--   node.data["p布尔值"]   = boolean（比较结果）
--   node.data["p是否有关键字"] = boolean（关键字检查结果）
local ConditionActs = {
    -- 判断数量：统计指定阵营的某种数量，与比较值比较
    countCheck = function(ctx, card, targets, item, node)
        local tableID = ctx.tableID or ctx.table_id
        local owner = card:GetOwner()
        local side = ReadSlot(node, "select_2") or 1 -- 1 敌方 / 2 友方
        local targetPlayer = (side == 1) and EnemyOf(owner) or owner
        -- 收集目标阵营所有在场单位（支援阵线 + 前线，排除总部）
        -- 注意：阵线为固定槽数稀疏表（自动居中后槽 1/5 可能为空），须按槽号遍历，
        -- ipairs 在首个空槽即提前终止会漏掉后续槽位的单位
        local units = {}
        local supportLine = KARDS.Battlefield:GetSupport(tableID, targetPlayer)
        if supportLine then
            for i = 1, KARDS.Battlefield.SLOT_COUNT do
                local u = supportLine[i]
                if u and u:GetType() ~= "headquarter" then
                    table.insert(units, u)
                end
            end
        end
        if KARDS.Battlefield:GetFrontlineOwner(tableID) == targetPlayer then
            local frontline = KARDS.Battlefield:GetFrontline(tableID)
            if frontline then
                for i = 1, KARDS.Battlefield.SLOT_COUNT do
                    local u = frontline[i]
                    if u then table.insert(units, u) end
                end
            end
        end
        -- 解析 countType（number_1，[lib+5] 5 种统计方式）
        local rawType = ReadSlot(node, "number_1") or 1
        local countTypes = {
            [1] = "differentNation", -- 不同国籍单位数
            [2] = "maxAttack",       -- 最大攻击力单位
            [3] = "minAttack",       -- 最小攻击力单位
            [4] = "maxDefense",      -- 最大防御力单位
            [5] = "minDefense",      -- 最小防御力单位
        }
        local countType = (type(rawType) == "number" and rawType >= 1 and rawType <= 5)
            and countTypes[rawType] or "direct"
        -- 计算实际统计值
        local actualValue
        local function unitStat(u, stat)
            return (u.GetStat and u:GetStat(stat)) or 0
        end
        if type(rawType) == "string" and rawType:match("^var:") then
            -- 变量库变量模式（2026-10-04）：数值源为变量库变量，直接读其当前值（如「剩余指挥点」）
            actualValue = KARDS.NodeParser.ResolveNumberValue(ctx, rawType)
        elseif countType == "maxAttack" then
            actualValue = 0
            for _, u in ipairs(units) do
                actualValue = math.max(actualValue, unitStat(u, "attack"))
            end
        elseif countType == "minAttack" then
            actualValue = 99999
            for _, u in ipairs(units) do
                actualValue = math.min(actualValue, unitStat(u, "attack"))
            end
            if #units == 0 then actualValue = 0 end
        elseif countType == "maxDefense" then
            actualValue = 0
            for _, u in ipairs(units) do
                actualValue = math.max(actualValue, unitStat(u, "defense"))
            end
        elseif countType == "minDefense" then
            actualValue = 99999
            for _, u in ipairs(units) do
                actualValue = math.min(actualValue, unitStat(u, "defense"))
            end
            if #units == 0 then actualValue = 0 end
        elseif countType == "differentNation" then
            -- 不同国籍单位数：统计该方在场单位的不同国籍数量（readme 国籍/国家，
            -- H3 修复：按 GetCountry 去重，而非旧实现的按归属玩家去重）
            local seen = {}
            for _, u in ipairs(units) do
                local c = (u.GetCountry and u:GetCountry()) or nil
                if c then seen[c] = true end
            end
            actualValue = 0
            for _ in pairs(seen) do actualValue = actualValue + 1 end
        else
            -- direct：直接统计单位数量
            actualValue = #units
        end
        -- 解析比较值（number_2，[lib]；数字字面量或 "var:" 变量引用，2026-10-04）
        local compareValue = KARDS.NodeParser.ResolveNumberValue(ctx, ReadSlot(node, "number_2"))
        -- 解析运算符（select_3：1= 2> 3< 4>= 5<=）
        local opIdx = ReadSlot(node, "select_3") or 1
        local ops = { [1] = "==", [2] = ">", [3] = "<", [4] = ">=", [5] = "<=" }
        local opStr = ops[opIdx] or "=="
        -- 比较
        local result = false
        if opStr == ">" then
            result = actualValue > compareValue
        elseif opStr == "<" then
            result = actualValue < compareValue
        elseif opStr == ">=" then
            result = actualValue >= compareValue
        elseif opStr == "<=" then
            result = actualValue <= compareValue
        else
            result = actualValue == compareValue
        end
        -- 存储结果
        node.data["n比较结果"] = actualValue
        node.data["p布尔值"] = result
        node.data["p是否有关键字"] = false
        return result
    end,
    -- 关键字检查：检查目标卡牌是否具有指定关键字
    keywordCheck = function(ctx, card, targets, item, node)
        -- 目标优先取 e 输入数据线 targets[1]（对应 config/base 的 e 输入前缀），无注入时回退对象槽 select_4
        local target = targets and targets[1] or ReadSlot(node, "select_4")
        local keyword = ReadSlot(node, "select_5")
        local hasKeyword = target and target.HasKeyword and target:HasKeyword(keyword) or false
        node.data["n比较结果"] = 0
        node.data["p布尔值"] = false
        node.data["p是否有关键字"] = hasKeyword
        return hasKeyword
    end,
    -- 前线归属：判定前线当前归属方（友方/敌方/无主），结果存 node.data
    -- 数据源 KARDS.Battlefield:GetFrontlineOwner（sh_battlefield.lua:290-292），
    -- 前线为空时归属值为 nil（无主）。side：1 友方 / 2 敌方 / 3 无主
    frontlineOwnerCheck = function(ctx, card, targets, item, node)
        local tableID = ctx.tableID or ctx.table_id
        local owner = KARDS.Battlefield:GetFrontlineOwner(tableID)
        local mine = card and card.GetOwner and card:GetOwner() or nil
        local sel = tonumber(ReadSlot(node, item.side)) or 1
        local result
        if sel == 1 then
            result = (owner ~= nil and owner == mine)
        elseif sel == 2 then
            result = (owner ~= nil and owner ~= mine)
        else
            result = (owner == nil)
        end
        node.data["n比较结果"] = result and 1 or 0
        node.data["p布尔值"] = result
        node.data["p是否有关键字"] = false
        return result
    end,
}

-- ====================================================================
-- 语义动作执行器（event_monitor 模板）
-- ====================================================================
-- 事件监测（判断节点，双输出）：在最近刻（TickLog）中检索「发起者属于监测阵营」且
-- 操作类型匹配指定事件的刻。命中 → 事件被监测到（p触发事件 = true）。
-- 结果存于 node.data 供下游数据线消费：
--   node.data["t事件类型"] = string 事件类型名（打出指令/加入/总部/...）
--   node.data["e事件目标"] = card|nil 最近匹配刻的发起者卡牌（受影响对象）
--   node.data["p触发事件"] = boolean 事件是否被监测到
-- 返回 boolean 供双输出分支（satisfied=触发 / not_satisfied=未触发）选择走向。
-- 事件 → 刻操作映射（对齐 sh_battle_stub.lua 的 TickLog:Push 白名单，见 sh_ticklog.lua）：
--   目标/单位：属性变化（stat_change）与触发（trigger/deathrattle/convert 等，按 select_3 分支区分，
--     「有变化的」仅 stat_change + select_4 属性过滤；「触发」按 select_6 能力/词条筛选，M2/M3）
--   总部：HQ 受伤（take_damage/deal_damage）或属性变化（stat_change）
--   打出指令：play_command（发起者为指令卡）；触发反制：counter（任一操作被拦截时，
--     拦截收尾 KARDS.Battle:InterceptOperation 推 {操作类型, "counter"} 刻，M1.4）
--   加入：deploy/join_battlefield/join_frontline/summon；玩家：draw/extra_draw/discard/burn（对齐 @player_actions）
--   回合：turn_begin / turn_end（按 select_9 开始/结束阶段过滤，M4a）
local EVENT_MONITOR_INFO = {
    target     = { name = "目标",     ops = { stat_change = true, trigger = true, convert = true, deathrattle = true } },
    unit       = { name = "单位",     ops = { stat_change = true, trigger = true, convert = true, deathrattle = true } },
    hq         = { name = "总部",     ops = { stat_change = true, take_damage = true, deal_damage = true } },
    play_order = { name = "打出指令", ops = { play_command = true } },
    counter    = { name = "触发反制", ops = { counter = true } },
    join       = { name = "加入",     ops = { deploy = true, join_battlefield = true, join_frontline = true, summon = true } },
    player     = { name = "玩家",     ops = { draw = true, extra_draw = true, discard = true, burn = true } },
    turn       = { name = "回合",     ops = { turn_begin = true, turn_end = true } },
}

-- 触发刻 → 携带的能力/词条 id 集合（供 event_monitor「触发」分支 select_6 筛选，M3）：
--   骨架产生刻的能力/词条 id（对齐 sh_battle_stub.lua 的 TickLog:Push）：
--     trigger 刻（SimTriggerKeyword）受影响第 2 元素携带触发词条 id（如 deathrattle/mobilize）；
--     suppress 刻携带 "suppressed"（被压制）；countdown 刻（倒计时 -1/归零）；其余以操作类型同名 id 标识。
--   亡计（combat_keywords 词汇表 id = last_strike）在 trigger 刻中关键词为 deathrattle，互为别名。
local function TickAbilityIds(tick)
    local ids = {}
    local initiator = tick[1]
    for _, op in ipairs(initiator and initiator[2] or {}) do
        if op == "trigger" then
            ids["trigger"] = true
            local aff = (tick[2] or {})[1]
            -- 受影响项 = { 卡牌, 〔经受类型…〕, 操作? }；触发词条 id 在经受类型数组（aff[2]）首个元素
            local kw = aff and aff[2] and aff[2][1]
            if type(kw) == "string" then
                ids[kw] = true
                if kw == "deathrattle" then ids["last_strike"] = true end
            end
        elseif op == "deathrattle" then
            ids["deathrattle"] = true
            ids["last_strike"] = true
        elseif op == "suppress" then
            ids["suppress"] = true
            local aff = (tick[2] or {})[1]
            local kw = aff and aff[2] and aff[2][1] -- "suppressed"（被压制）
            if type(kw) == "string" then ids[kw] = true end -- "suppressed"（被压制）
        elseif op == "neutralized" then ids["neutralized"] = true
        elseif op == "convert" then ids["convert"] = true
        elseif op == "control" then ids["control"] = true
        elseif op == "immune" then ids["immune"] = true
        elseif op == "intelligence" then ids["intelligence"] = true
        elseif op == "deploy" then ids["deploy"] = true
        elseif op == "countdown" then
            ids["countdown"] = true
            ids["trigger"] = true -- 倒计时归零刻（countdown+trigger）
        elseif op == "stat_change" then
            ids["repair"] = true -- 修复（SimRepair 防御 +N 刻）
        end
    end
    return ids
end

-- stat_change 刻是否匹配所选属性（event_monitor「有变化的」分支 select_4，M2）：
--   select_4：1 属性（统称，任意）/ 2 攻防（攻击或防御）/ 3 攻击 / 4 防御 / 5 行动花费
--   受影响第 4 元素为变化属性标注（attack/defense/actionCost，见 sh_battle_stub.lua stat_change 刻）。
local function StatChangeMatchesAttr(node, item, tick)
    local attrIdx = tonumber(ReadSlot(node, item.attr)) or 1
    if attrIdx == 1 then return true end
    local want = (attrIdx == 3) and "attack" or (attrIdx == 4) and "defense"
        or (attrIdx == 5) and "actionCost" or nil -- 2 攻防：attack 或 defense 均可
    local annotated = false
    for _, aff in ipairs(tick[2] or {}) do
        local attr = aff[4]
        if attr then
            annotated = true
            if attrIdx == 2 and (attr == "attack" or attr == "defense") then return true end
            if attr == want then return true end
        end
    end
    return not annotated -- 无属性标注的刻无法区分，宽松视为匹配（兼容旧刻）
end
local EventMonitorActs = {
    -- 事件监测：检索最近刻中匹配「阵营 + 事件操作类型（+ 可选约束）」的刻
    monitor = function(ctx, card, targets, item, node)
        local tableID = ctx.tableID or ctx.table_id
        local owner = card:GetOwner()
        local side = ReadSlot(node, "select_1") or 1 -- 1 友方 / 2 敌方
        local monitorPlayer = (side == 1) and owner or EnemyOf(owner)
        local info = EVENT_MONITOR_INFO[item.event] or { name = tostring(item.event), ops = {} }
        -- 回合阶段过滤（M4a）：select_9 开始(1)/结束(2) → 只匹配对应刻（turn_begin / turn_end）
        if item.event == "turn" then
            local phase = ReadSlot(node, item.phase) or 1
            info = { name = info.name, ops = (phase == 2) and { turn_end = true } or { turn_begin = true } }
        end
        -- 目标/单位分支（M2/M3）：select_3「有变化的/触发」区分操作范围；
        -- 「有变化的」仅 stat_change 刻 + select_4 属性过滤；「触发」按 select_6 能力/词条筛选
        local branch3 = nil
        local selfOnly = false
        if item.event == "target" or item.event == "unit" then
            -- 1 有变化的 / 2 触发 / 3 自身有变化的 / 4 自身触发（2026-10-04：自身变体限定受影响卡为发起者）
            branch3 = ReadSlot(node, "select_3") or 1
            selfOnly = (branch3 == 3 or branch3 == 4)
        end
        local triggered = false
        local eventTarget = nil
        local total = KARDS.TickLog:Count(tableID)
        local startIdx = math.max(1, total - 29) -- 仅检索最近 30 刻
        for i = total, startIdx, -1 do
            local tick = KARDS.TickLog:GetTick(tableID, i)
            local initiator = tick and tick[1]
            local initiatorCard = initiator and initiator[1]
            if initiatorCard then
                -- 阵营匹配：总部比对「监测阵营的总部」，其余比对卡牌归属
                local isHQ = initiatorCard:GetType() == "headquarter"
                local campMatched = isHQ and KARDS.Battlefield:GetHQ(tableID, monitorPlayer) == initiatorCard
                    or (not isHQ) and initiatorCard:GetOwner() == monitorPlayer
                if campMatched then
                    -- 操作类型匹配（打出指令「时：触发情报」匹配 intelligence 刻，H1）
                    local wantIntel = (item.event == "play_order")
                        and ((ReadSlot(node, "select_7") or 1) == 3)
                    local opMatched = false
                    if branch3 then
                        if branch3 == 1 or branch3 == 3 then
                            -- 有变化的：仅 stat_change 刻，且按 select_4 属性过滤（M2）
                            for _, op in ipairs(initiator[2] or {}) do
                                if op == "stat_change" and StatChangeMatchesAttr(node, item, tick) then
                                    opMatched = true break
                                end
                            end
                        else
                            -- 触发：按 select_6 能力/词条筛选（M3）；未选 select_6 时任意触发刻均匹配
                            local sel6 = ReadSlot(node, "select_6")
                            local ids = TickAbilityIds(tick)
                            if not sel6 or sel6 == "" then
                                for id in pairs(ids) do opMatched = true break end
                            else
                                opMatched = ids[sel6] or false
                            end
                        end
                    else
                        for _, op in ipairs(initiator[2] or {}) do
                            if info.ops[op] or (wantIntel and op == "intelligence") then opMatched = true break end
                        end
                    end
                    -- 自身变体（branch3 3/4）：该刻受影响卡须为发起者自身（2026-10-04，柴郡团「该单位受到伤害」）
                    if opMatched and selfOnly then
                        local aff = (tick[2] or {})[1]
                        local affCard = aff and aff[1]
                        if affCard ~= card then opMatched = false end
                    end
                    if opMatched then
                        -- 附加约束（三类约束互斥，按事件类型只启用其一；未配置或值 ≤ 0 视为不约束）
                        local pass = true
                        if item.defense then -- 总部：防御 == number_1
                            local want = tonumber(ReadSlot(node, item.defense)) or 0
                            if want > 0 and not (initiatorCard.GetStat and initiatorCard:GetStat("defense") == want) then
                                pass = false
                            end
                        elseif item.cost then -- 打出指令：select_7 的花费(2) / 时：触发情报(3)（H1）
                            local sel7 = ReadSlot(node, "select_7") or 1
                            local want = tonumber(ReadSlot(node, item.cost)) or 0
                            if sel7 == 2 then -- 的花费：指令花费 == number_3
                                if initiatorCard:GetCost() ~= want then pass = false end
                            elseif sel7 == 3 then -- 时：触发情报：该刻情报数 == number_3
                                local infoCount = 0
                                local ch = initiator[3] -- intelligence 刻发起者变更文本 "+N"（SimUseIntel 记录）
                                if type(ch) == "string" then
                                    local sign, num = ch:match("^([+-=])(%d+)$")
                                    if sign == "+" then infoCount = tonumber(num) end
                                end
                                if infoCount ~= want then pass = false end
                            end
                        elseif item.change then -- 目标/单位：属性变化约束（H4，select_5 的值/增加了/减少了/为）
                            local changeIdx = ReadSlot(node, item.change) or 1
                            local want = tonumber(ReadSlot(node, item.value)) or 0
                            local tgt = (tick[2] or {})[1]
                            local tgtCard = tgt and tgt[1]
                            local changeText = tgt and tgt[3]
                            if want > 0 and tgtCard then
                                if changeIdx == 2 then -- 增加了：变化量 == +N
                                    local sign, num = tostring(changeText or ""):match("^([+-=])(%d+)$")
                                    if not (sign == "+" and tonumber(num) == want) then pass = false end
                                elseif changeIdx == 3 then -- 减少了：变化量 == -N
                                    local sign, num = tostring(changeText or ""):match("^([+-=])(%d+)$")
                                    if not (sign == "-" and tonumber(num) == want) then pass = false end
                                else -- 的值(1)/为(4)：变化后数值变为 N（读受影响目标当前属性）
                                    local attrIdx = ReadSlot(node, item.attr) or 1
                                    local statName = (attrIdx == 4) and "defense"
                                        or (attrIdx == 5) and "actionCost" or "attack"
                                    local cur = (tgtCard.GetStat and tgtCard:GetStat(statName)) or 0
                                    if cur ~= want then pass = false end
                                end
                            end
                        elseif item.count then -- 玩家：监测一刻内该玩家手牌变化量 == number_4（H2 修复，2026-08-08）
                            local want = tonumber(ReadSlot(node, item.count)) or 0
                            if want > 0 then
                                -- @player_actions（select_8）：1 抽牌 / 2 额外抽牌 / 3 弃牌 / 4 爆牌
                                -- 抽牌/额外抽牌 → 手牌 +N；弃牌/爆牌 → 手牌 -N
                                local action = ReadSlot(node, "select_8") or 1
                                local expectSign = (action == 3 or action == 4) and "-" or "+"
                                local matched = false
                                for _, rc in ipairs(KARDS.TickLog:GetResourceChanges(tick)) do
                                    if rc[1] == monitorPlayer and rc[2] == "hand" and rc[3] then
                                        local sign, num = rc[3]:match("^([+-=])(%d+)$")
                                        if sign == expectSign and tonumber(num) == want then
                                            matched = true
                                            break
                                        end
                                    end
                                end
                                if not matched then pass = false end
                            end
                        end
                        if pass then
                            triggered = true
                            eventTarget = initiatorCard
                            break
                        end
                    end
                end
            end
        end
        node.data["t事件类型"] = info.name
        node.data["e事件目标"] = eventTarget
        node.data["p触发事件"] = triggered
        return triggered
    end,
}

-- ====================================================================
-- 语义动作执行器（target_selector 模板）
-- ====================================================================
-- 各执行器签名：fn(ctx, card, targets, item, node)
--   ctx     执行上下文（含 tableID）
--   card    效果发起卡牌句柄（决定「友方」阵营）
--   targets 打出指令时选择的目标（「指向一个」「目标」类别的数据来源）
--   item    语义项（mode：one / random / all / highest / lowest）
--   node    节点实例（select_3 阵营范围 / select_4 卡牌类别 / select_5 单位类型 /
--           select_2 属性 + number_1 名次 / number_2 随机数量经 ReadSlot 读取）
-- 属性读取（@card_stats 选项：攻击力/防御力/最大防御力/行动花费/费用；最大防御力骨架无独立字段，以防御力兜底）
-- 独立为 chunk 顶层 local，避免执行器表内闭包自引用（sort 比较器直接引用）
local function TSGetAttr(u, attr)
    if attr == 1 then return (u.GetStat and u:GetStat("attack")) or 0 end
    if attr == 2 then return (u.GetStat and u:GetStat("defense")) or 0 end
    if attr == 3 then return (u.GetStat and u:GetStat("defense")) or 0 end -- 最大防御力（骨架 defense 即最大）
    if attr == 4 then return u:GetActionCost() or 0 end
    return u:GetCost() or 0
end

-- 单位类型（select_5 选项：1 任意 / 2-6 战斗机/坦克/轰炸机/炮兵/步兵，readme 7.3；
-- 「任意」不映射类型 = 不做单位类型过滤）
local TARGET_UNIT_TYPES = {
    [2] = "fighter", [3] = "tank", [4] = "bomber", [5] = "artillery", [6] = "infantry",
}

-- 收集战场单位（支援阵线除总部 + 控制方前线，同 extract）
-- @param tableID string 牌桌标识
-- @param players table 玩家标识列表
-- @return table 单位列表
local function TSCollectUnits(tableID, players)
    local out = {}
    for _, p in ipairs(players) do
        local support = KARDS.Battlefield:GetSupport(tableID, p)
        if support then
            for i = 1, KARDS.Battlefield.SLOT_COUNT do
                local u = support[i]
                if u and u:GetType() ~= "headquarter" then table.insert(out, u) end
            end
        end
        if KARDS.Battlefield:GetFrontlineOwner(tableID) == p then
            local frontline = KARDS.Battlefield:GetFrontline(tableID)
            if frontline then
                for i = 1, KARDS.Battlefield.SLOT_COUNT do
                    local u = frontline[i]
                    if u then table.insert(out, u) end
                end
            end
        end
    end
    return out
end

local TargetSelectorActs = {
    getAttr = TSGetAttr,
    unitTypeByIndex = TARGET_UNIT_TYPES,
    -- 目标选择：收集候选（阵营范围 × 卡牌类别 × 单位类型）→ 按选择方式输出 e 对象组
    select = function(ctx, card, targets, item, node)
        local tableID = ctx.tableID or ctx.table_id
        local owner = card:GetOwner()
        local enemy = EnemyOf(owner)
        -- 阵营范围（select_3：1 友方 / 2 敌方 / 3 场上=双方）
        local side = tonumber(ReadSlot(node, "select_3")) or 1
        local players = {}
        if side == 2 then
            if enemy then players[1] = enemy end
        else
            players[1] = owner
            if side == 3 and enemy then players[2] = enemy end
        end
        -- 卡牌类别（select_4：1 单位 / 2 目标 / 3 总部）
        local cat = tonumber(ReadSlot(node, "select_4")) or 1
        local group = {}
        if cat == 1 then
            -- 单位：战场（支援阵线除总部 + 所属前线）
            group = TSCollectUnits(tableID, players)
            -- 单位类型过滤（select_5：1 任意 / 2-6 战斗机/坦克/轰炸机/炮兵/步兵，
            -- 仅「单位」类别生效；「任意」不映射类型 = 不过滤）
            local ut = tonumber(ReadSlot(node, "select_5"))
            local want = ut and TARGET_UNIT_TYPES[ut]
            if want then
                local filtered = {}
                for _, u in ipairs(group) do
                    if u:GetUnitType() == want then table.insert(filtered, u) end
                end
                group = filtered
            end
        elseif cat == 3 then
            -- 总部
            for _, p in ipairs(players) do
                local hq = KARDS.Battlefield:GetHQ(tableID, p)
                if hq then table.insert(group, hq) end
            end
        else
            -- 目标：打出指令时选择的目标（targets 参数；e 输入数据线已由 ResolveEWires 注入）
            group = targets or {}
        end
        -- 选择方式（mode）
        local result = group
        local mode = item.mode
        if mode == "one" then
            -- 指向一个：通用指定目标操作（选择注入 ctx.specify.targetPicker，
            -- 未来 UI 使发起卡牌与鼠标间创建箭头指向目标，不可指向的目标显示黑白）
            local t = KARDS.Specify.Target(tableID, owner, group,
                ctx.specify and ctx.specify.targetPicker)
            result = t and { t } or {}
        elseif mode == "random" then
            local n = math.min(tonumber(ReadSlot(node, "number_2")) or 1, #group)
            result = {}
            local pool = {}
            for i, g in ipairs(group) do pool[i] = g end
            for i = 1, n do -- 洗牌取前 n 个（不重复）
                local j = math.random(#pool)
                table.insert(result, pool[j])
                table.remove(pool, j)
            end
        elseif mode == "highest" or mode == "lowest" then
            local attr = tonumber(ReadSlot(node, "select_2")) or 1
            local rank = math.max(1, tonumber(ReadSlot(node, "number_1")) or 1)
            local sorted = {}
            for _, g in ipairs(group) do table.insert(sorted, g) end
            -- 同排名随机择一（2026-10-04）：先以 Fisher-Yates 洗牌打散，使排序后等值元素顺序随机
            for i = #sorted, 2, -1 do
                local j = math.random(i)
                sorted[i], sorted[j] = sorted[j], sorted[i]
            end
            local descending = (mode == "highest")
            table.sort(sorted, function(a, b)
                local va, vb = TSGetAttr(a, attr), TSGetAttr(b, attr)
                if va == vb then return false end
                -- 不可写成 `descending and (va > vb) or (va < vb)`：降序时若 va <= vb，
                -- `and` 的结果为 false 会继续走 `or (va < vb)`，把降序比较退化成升序（Lua and/or 陷阱）
                if descending then return va > vb end
                return va < vb
            end)
            -- 取第 rank 名后，在同值的并列项中随机择一（属性最高/最低 同排名随机）
            if sorted[rank] then
                local rankVal = TSGetAttr(sorted[rank], attr)
                local ties = {}
                for _, g in ipairs(sorted) do
                    if TSGetAttr(g, attr) == rankVal then table.insert(ties, g) end
                end
                result = { ties[math.random(#ties)] }
            else
                result = {}
            end
        end
        -- 输出端口名（e选中的卡牌）：base 输出类型首项
        local outName = "选中的卡牌"
        if node.base and node.base ~= "" then
            local struct = KARDS.NodeParser.ParseBaseStructure(node.base)
            if struct and struct.outputTypes and struct.outputTypes[1] then
                outName = struct.outputTypes[1].name
            end
        end
        node.data[outName] = result
        return #result > 0
    end,
}

-- ====================================================================
-- 执行器合并：各模板 handlers 合并进 BaseSemantics 分派表
-- （ExecuteBaseNode 经 sem.handlers 分派，行为与原 if/elseif 链一致）
-- ====================================================================
KARDS.NodeParser.BaseSemantics.condition.handlers = ConditionActs
KARDS.NodeParser.BaseSemantics.event_monitor.handlers = EventMonitorActs
KARDS.NodeParser.BaseSemantics.target_selector.handlers = TargetSelectorActs
