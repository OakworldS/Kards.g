--[[
    注册式效果框架 (Effect Registry)

    统一「注册式效果」的注册表骨架：按事件/时机挂起一段效果（条目），到点触发。
    重构前 sh_node_parser.lua 中四套独立注册表（KeepTriggers / EventHooks / AlwaysHooks /
    PendingTurns）各自实现注册/触发/清理，本框架统一其「注册表结构 + 注册/触发/清理」骨架，
    各系统的匹配逻辑作为条目 handler 注入（re.md B-H2）。

    事件源（EVENTS）：
      PlayCommand  打出指令成功（register_hook 总是触发 / 条件触发·打出指令）
      Counter      触发反制（拦截成功）
      Deploy       部署单位
      TurnBegin    回合开始（保持触发 / 条件触发·回合开始）
      TurnEnd      回合结束
      CardEnter    卡牌进入战场（渲染层订阅：入战场自动绑定实体）
      CardLeave    卡牌离开战场（渲染层订阅：离场自动移除实体）
      ReturnToHand 卡牌返回手牌（实体层订阅：广播返回手牌动画）
      ShuffleInto  洗入成功（实体层订阅：广播洗入动画，2026-09-26 缺口 D）
      PileCardRemoved 卡牌被弃掉/爆牌（实体层订阅：广播单卡飞出动画，2026-09-26 缺口 E）
      HandCardDiscarded 手牌被弃掉（实体层订阅：广播手牌飞出动画，2026-10-06 用户规格）
      FrontlineDenied 进入前线被拒（实体层订阅：向发起方发提示，2026-09-26 缺口 F）
      JoinField    卡牌加入阵线（实体层订阅：广播加入动画，2026-09-26 缺口 F）

    条目结构（Register 的 entry 参数）：
      id       string 注册项唯一 ID（同事件同 ID 重复注册覆盖，幂等）
      owner    string 注册者玩家（阵营匹配基准）
      side     number|nil 事件阵营：nil=任意（不按阵营过滤）
               1=敌方（触发者 != owner）/ 2=友方（触发者 == owner）
      entity   table|nil 绑定卡牌对象（保持触发用：目标实体拥有者回合开始执行；
               离场时经 UnregisterByEntity 自动注销——解决「保持触发目标离场不自动注销」缺陷）
      handler  function(payload) 触发时执行；payload 由 Trigger 传入
               （含 initiatorCard / player / card 等事件上下文）

    handler 异常经 pcall 防御，单个条目失败不影响其余条目。

    独立注册表（PendingTurns 等）经 ClearCallbacks 挂「每桌清理」钩子，
    StartBattle 只需调用 Clear(tableID) 一处完成全部清理（re.md B-H2 第 5 点）。

    加载：autorun/sh_card_editor_loader.lua LoadSharedFiles（sh_engine_hooks.lua 之后，
    供 sh_battle_stub.lua / sh_node_parser.lua 使用）
]]

KARDS = KARDS or {}
KARDS.EffectRegistry = KARDS.EffectRegistry or {}

-- 事件源枚举（战斗骨架入口在事件发生时 Trigger；卡牌入/离场见 sh_battle_stub.lua Sim* 入口）
KARDS.EffectRegistry.EVENTS = {
    PlayCommand = "play_command", -- 打出指令成功（SimPlayCard 结尾）
    Counter     = "counter",      -- 触发反制（任一操作被拦截时，KARDS.Battle:InterceptOperation）
    Deploy      = "deploy",       -- 部署单位（SimDeploy）
    TurnBegin   = "turn_begin",   -- 回合开始（SimBeginTurn）
    TurnEnd     = "turn_end",     -- 回合结束（SimEndTurn）
    CardEnter   = "card_enter",   -- 卡牌进入战场（SimDeploy/SimJoinBattlefield/SimJoinFrontline/SimSummonUnit）
    CardLeave   = "card_leave",   -- 卡牌离开战场（SimRemoveFromField/SimRetreat/SimReturnToHand）
    ReturnToHand = "return_to_hand_anim", -- 卡牌返回手牌（SimReturnToHand；实体层订阅广播返回手牌动画）
    LayoutChanged = "layout_changed", -- 战场布局重排（SimShuffleField 随机排列；实体层订阅补布局广播，2026-08-18 规划 C1）
    CountsChanged = "counts_changed", -- 手牌/卡组计数变化（节点效果 burn / shuffleInto 直接改数组；实体层订阅补 SyncBattleCounts，2026-08-18 规划 C5）
    CommandPointsChanged = "command_points_changed", -- 指挥点/指挥点槽变更（SimChangeCommandPoints/SimChangeCommandSlots；实体层订阅补指挥点广播，2026-08-18 规划 C6）
    BattleStopped = "battle_stopped", -- 作弊停止对局（Battlefield:Stop；实体层订阅向参战玩家广播冻结提示，2026-08-18 规划 D7）
    GameOver    = "game_over",    -- 对局结束（总部被摧毁，CheckHQDestroyed判定胜负后触发；实体层订阅广播结算）
    ShuffleInto = "shuffle_into", -- 洗入成功（2026-09-26 缺口 D：card 模板洗入分支；实体层订阅广播洗入动画）
    PileCardRemoved = "pile_card_removed", -- 卡牌被节点效果弃掉/爆牌（2026-09-26 缺口 E：实体层订阅广播单卡飞出动画）
    HandCardDiscarded = "hand_card_discarded", -- 手牌被弃掉（2026-10-06 用户规格：实体层订阅广播手牌飞出动画，牌移到右槽停留 1 秒后顺时针出场）
    FrontlineDenied = "frontline_denied", -- 进入前线被拒（2026-09-26 缺口 F：前线已被敌方占领；实体层订阅向发起方发提示）
    JoinField = "join_field",     -- 卡牌加入阵线（2026-09-26 缺口 F：实体层订阅广播加入动画，与部署动画分流）
    UnitAction = "unit_action",   -- 单位攻击冲刺（2026-09-26 缺口 G：效果路径与手动路径共用一个广播函数）
    UnitElevate = "unit_elevate", -- 单位升为老兵（2026-09-26 缺口 I：实体层订阅广播老兵升级动画与白色飘字）
    UnitConvert = "unit_convert", -- 卡牌整体转换（2026-09-26 缺口 J：实体层订阅生成新实体并广播翻面交接动画）
}

-- 注册表：Instances[tableID][event][id] = entry（按牌桌隔离，与 TickLog / EngineHooks 的 tableID 体系一致）
KARDS.EffectRegistry.Instances = KARDS.EffectRegistry.Instances or {}

-- 每桌清理回调：Clear(tableID) 时调用（key → function(tableID)），供未迁移的独立注册表挂清理
KARDS.EffectRegistry.ClearCallbacks = KARDS.EffectRegistry.ClearCallbacks or {}

-- 初始化指定牌桌的注册空间（防御性：Register 前调用）
function KARDS.EffectRegistry.InitTable(tableID)
    if not KARDS.EffectRegistry.Instances[tableID] then
        KARDS.EffectRegistry.Instances[tableID] = {}
    end
end

--[[
    注册条目到指定事件源（同事件同 ID 重复注册覆盖旧条目，幂等）

    @param tableID string 牌桌唯一标识符
    @param event   string 事件源（KARDS.EffectRegistry.EVENTS 之一）
    @param id      string 注册项唯一 ID
    @param entry   table 条目 { id, owner, side?, entity?, handler }
    @return boolean 是否注册成功（参数非法返回 false）
]]
function KARDS.EffectRegistry.Register(tableID, event, id, entry)
    if not tableID or not event or not id or not entry or type(entry.handler) ~= "function" then
        return false
    end
    KARDS.EffectRegistry.InitTable(tableID)
    local byEvent = KARDS.EffectRegistry.Instances[tableID]
    byEvent[event] = byEvent[event] or {}
    entry.id = id
    byEvent[event][id] = entry
    return true
end

--[[
    注销指定条目（同注册 ID 移除；停止保持触发 / 拦截一次后注销）

    @param tableID string 牌桌唯一标识符
    @param event   string 事件源
    @param id      string 注册项唯一 ID
    @return boolean 是否注销成功
]]
function KARDS.EffectRegistry.Unregister(tableID, event, id)
    local byEvent = KARDS.EffectRegistry.Instances and KARDS.EffectRegistry.Instances[tableID]
    if not byEvent or not byEvent[event] or not byEvent[event][id] then return false end
    byEvent[event][id] = nil
    return true
end

--[[
    注销绑定指定卡牌对象的所有条目（卡牌离开战场时调用；
    解决「保持触发目标离场不自动注销」缺陷，re.md B-H2）

    @param cardObj table|Entity 绑定的卡牌对象（entry.entity）
    @return number 注销的条目数量
]]
function KARDS.EffectRegistry.UnregisterByEntity(cardObj)
    if not cardObj then return 0 end
    local count = 0
    for _, byEvent in pairs(KARDS.EffectRegistry.Instances or {}) do
        for _, entries in pairs(byEvent) do
            for id, entry in pairs(entries) do
                if entry.entity == cardObj then
                    entries[id] = nil
                    count = count + 1
                end
            end
        end
    end
    return count
end

--[[
    触发指定事件源：按注册顺序调用匹配条目的 handler

    阵营匹配（entry.side）：payload.initiatorCard 存在时
      side==1（敌方）→ initiatorCard:GetOwner() ~= entry.owner
      side==2（友方）→ initiatorCard:GetOwner() == entry.owner
      side==nil（任意）→ 恒匹配
    匹配后调用 entry.handler(payload)；handler 异常 pcall 防御（单个失败不影响其余）。

    @param tableID string 牌桌唯一标识符
    @param event   string 事件源
    @param payload table|nil 事件上下文（initiatorCard 阵营匹配基准 / player 回合玩家 / card 入离场卡牌）
]]
function KARDS.EffectRegistry.Trigger(tableID, event, payload)
    local byEvent = KARDS.EffectRegistry.Instances and KARDS.EffectRegistry.Instances[tableID]
    if not byEvent or not byEvent[event] then return end
    payload = payload or {}
    local entries = byEvent[event]
    for _, entry in pairs(entries) do
        -- 阵营匹配（事件发起者存在时按 owner 判定）
        local src = payload.initiatorCard
        if entry.side then
            -- 阵营过滤条目：必须同时具备发起者与注册者才能判定；缺发起者（如 TriggerKeepTriggers
            -- 以 { player = player } 触发同一事件源）时跳过——否则无条件触发会让条件钩子拿到 nil
            -- initiatorCard（曾导致事件内 headquarter 等执行器对 nil 卡牌调用报错）。
            if src and entry.owner then
                local srcOwner = src:GetOwner()
                if entry.side == 1 and srcOwner == entry.owner then
                    -- 敌方事件：发起者是注册者自己 → 不匹配
                elseif entry.side == 2 and srcOwner ~= entry.owner then
                    -- 友方事件：发起者不是注册者 → 不匹配
                else
                    local ok, err = pcall(entry.handler, payload)
                    if not ok then
                        print("[EffectRegistry] 事件条目执行失败: " .. tostring(err))
                    end
                end
            end
        else
            -- 无阵营过滤（side=nil）：恒匹配（总是触发 / 保持触发，保持触发按实体拥有者自行判定）
            local ok, err = pcall(entry.handler, payload)
            if not ok then
                print("[EffectRegistry] 事件条目执行失败: " .. tostring(err))
            end
        end
    end
end

-- 获取指定事件源的条目数量（供调试/UI 显示）
function KARDS.EffectRegistry.Count(tableID, event)
    local byEvent = KARDS.EffectRegistry.Instances and KARDS.EffectRegistry.Instances[tableID]
    if not byEvent or not byEvent[event] then return 0 end
    local count = 0
    for _ in pairs(byEvent[event]) do count = count + 1 end
    return count
end

-- 清除指定牌桌的全部注册条目 + 触发每桌清理回调（StartBattle / 牌桌销毁时调用）
-- @param tableID string 牌桌唯一标识符
function KARDS.EffectRegistry.Clear(tableID)
    KARDS.EffectRegistry.Instances[tableID] = nil
    for _, cb in pairs(KARDS.EffectRegistry.ClearCallbacks or {}) do
        pcall(cb, tableID)
    end
end
