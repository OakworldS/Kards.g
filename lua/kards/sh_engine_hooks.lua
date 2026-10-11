--[[
    引擎钩子系统 (Engine Hook System)

    为战斗系统提供可插拔的钩子点，使节点图可以在底层逻辑执行时插入修改。
    战斗系统（gamemode）在关键计算点调用 Trigger 触发钩子；
    节点通过 Register 注册回调（修饰/拦截）。

    钩子点（战斗系统预设，当前战斗系统尚未实现，仅提供 API 框架）：
      OnModifyDamage   -- 计算最终伤害值时 {来源, 目标, 伤害量}
      OnBeforePlayCard -- 打出卡牌生效前 {卡牌, 玩家, 效果}
      OnModifyStat     -- 读写卡牌属性时 {卡牌, 属性名, 当前值}

    钩子类型：
      TYPE_EFFECT  -- 效果钩子：事件生效前调用，可拦截/替换事件（Hx 权杖号）
      TYPE_MODIFY  -- 修饰钩子：数值计算时调用，可偏移数值（海鹰：敌方伤害 -1）

    使用示例（节点运行时）：
      KARDS.EngineHooks.Register(tableID, KARDS.EngineHooks.HookPoints.OnModifyDamage,
          "seahawk_mod", function(args)
              -- 敌方卡牌造成的伤害 -1
              args.damage = args.damage - 1
              return args
          end, KARDS.EngineHooks.TYPE_MODIFY, entity)
]]

KARDS = KARDS or {}
KARDS.EngineHooks = KARDS.EngineHooks or {}

-- 钩子点定义（战斗系统预设的触发位置）
KARDS.EngineHooks.HookPoints = {
    OnModifyDamage    = "OnModifyDamage",    -- 计算最终伤害值时
    OnBeforePlayCard  = "OnBeforePlayCard",  -- 打出卡牌生效前
    OnBeforeOperation = "OnBeforeOperation", -- 任一操作生效前（args.opType 为 KARDS.TickLog.OpTypes 键）
    OnModifyStat      = "OnModifyStat",      -- 读写卡牌属性时
}

-- 钩子类型
KARDS.EngineHooks.TYPE_EFFECT  = "effect"   -- 效果钩子：可拦截/替换事件
KARDS.EngineHooks.TYPE_MODIFY  = "modify"   -- 修饰钩子：数值偏移

-- 注册表：KARDS.EngineHooks.Registry[tableID][hookPoint][id] = { type, callback, boundEntity }
-- 按牌桌隔离，与 Varlib 的 tableID 体系一致
KARDS.EngineHooks.Registry = KARDS.EngineHooks.Registry or {}

-- 初始化指定牌桌的钩子注册表
-- @param tableID string 牌桌唯一标识符
function KARDS.EngineHooks.InitTable(tableID)
    if not KARDS.EngineHooks.Registry[tableID] then
        KARDS.EngineHooks.Registry[tableID] = {}
    end
end

--[[
    注册钩子到指定钩子点

    @param tableID    string 牌桌唯一标识符
    @param hookPoint  string 钩子点名称（KARDS.EngineHooks.HookPoints 之一）
    @param id         string 钩子唯一标识（注册者自定义），重复注册同一 id 会覆盖旧回调
    @param callback   function 回调函数，接收 args 表；返回 nil 表示不修改，
                                返回新 args 表表示修改结果（效果钩子可将 args.intercepted = true 表示已拦截）
    @param hookType   string 钩子类型（KARDS.EngineHooks.TYPE_*），默认 TYPE_EFFECT
    @param boundEntity Entity|nil 绑定的实体引用，实体销毁时自动注销该钩子（默认为 nil）
    @return boolean 是否注册成功
]]
function KARDS.EngineHooks.Register(tableID, hookPoint, id, callback, hookType, boundEntity)
    if not tableID or not hookPoint or not id or type(callback) ~= "function" then
        return false
    end
    KARDS.EngineHooks.InitTable(tableID)
    local registry = KARDS.EngineHooks.Registry[tableID]
    if not registry[hookPoint] then
        registry[hookPoint] = {}
    end
    registry[hookPoint][id] = {
        type = hookType or KARDS.EngineHooks.TYPE_EFFECT,
        callback = callback,
        boundEntity = boundEntity,
    }
    return true
end

--[[
    注销指定钩子

    @param tableID   string 牌桌唯一标识符
    @param hookPoint string 钩子点名称
    @param id        string 钩子唯一标识
    @return boolean 是否注销成功
]]
function KARDS.EngineHooks.Unregister(tableID, hookPoint, id)
    local registry = KARDS.EngineHooks.Registry[tableID]
    if not registry or not registry[hookPoint] or not registry[hookPoint][id] then
        return false
    end
    registry[hookPoint][id] = nil
    return true
end

--[[
    注销指定实体绑定的所有钩子（实体离场/销毁时调用）

    @param boundEntity Entity|string 绑定的实体引用（或唯一键）
    @return number 注销的钩子数量
]]
function KARDS.EngineHooks.UnregisterByEntity(boundEntity)
    if not boundEntity then return 0 end
    local count = 0
    for _, registry in pairs(KARDS.EngineHooks.Registry or {}) do
        for hookPoint, entries in pairs(registry) do
            for id, entry in pairs(entries) do
                if entry.boundEntity == boundEntity then
                    entries[id] = nil
                    count = count + 1
                end
            end
        end
    end
    return count
end

--[[
    触发指定钩子点，依次调用所有已注册回调并累计修改结果

    @param tableID   string 牌桌唯一标识符
    @param hookPoint string 钩子点名称
    @param args      table  钩子参数表（战斗系统传入）
    @return table 修改后的 args（未注册钩子时原样返回）
]]
function KARDS.EngineHooks.Trigger(tableID, hookPoint, args)
    local registry = KARDS.EngineHooks.Registry[tableID]
    if not registry or not registry[hookPoint] then
        return args
    end
    args = args or {}
    local current = args
    for _, entry in pairs(registry[hookPoint]) do
        if entry.callback then
            local ok, result = pcall(entry.callback, current)
            if ok and result ~= nil then
                current = result
            end
        end
    end
    return current
end

--[[
    统一操作拦截入口：任一操作生效前由战斗系统调用

    把操作类型写入 args.opType 后触发 OnBeforeOperation 钩子点，便于全部操作入口
    共用同一调用形态（反制可声明拦截的操作类型即 args.opType）。

    @param tableID string 牌桌唯一标识符
    @param opType  string 操作类型（KARDS.TickLog.OpTypes 键之一）
    @param args    table|nil 操作上下文（player / card / targets 等）
    @return table 修改后的 args（args.intercepted = true 表示该操作已被拦截）
]]
function KARDS.EngineHooks.TriggerOperation(tableID, opType, args)
    args = args or {}
    args.opType = opType
    return KARDS.EngineHooks.Trigger(tableID, KARDS.EngineHooks.HookPoints.OnBeforeOperation, args)
end

-- 获取指定钩子点的已注册数量（供调试/UI 显示）
-- @param tableID   string 牌桌唯一标识符
-- @param hookPoint string 钩子点名称
-- @return number 注册数量
function KARDS.EngineHooks.Count(tableID, hookPoint)
    local registry = KARDS.EngineHooks.Registry[tableID]
    if not registry or not registry[hookPoint] then return 0 end
    local count = 0
    for _ in pairs(registry[hookPoint]) do
        count = count + 1
    end
    return count
end

-- 清除指定牌桌的所有钩子（牌桌销毁时调用）
-- @param tableID string 牌桌唯一标识符
function KARDS.EngineHooks.ClearTable(tableID)
    KARDS.EngineHooks.Registry[tableID] = nil
end

--[[
    属性修饰钩子辅助（OnModifyStat）：卡牌读取属性时应用全局修饰

    卡牌对象不绑定牌桌（CardInterface.GetStat 无 tableID 上下文），因此遍历所有
    激活桌的 OnModifyStat 注册表，按卡牌阵营（owner）匹配作用目标后累计偏移。

    @param card  table 卡牌句柄
    @param stat  string 属性名（attack / defense 等）
    @param value number 当前属性值
    @return number 应用修饰后的属性值
]]
function KARDS.EngineHooks.OnStatRead(card, stat, value)
    local args = { card = card, stat = stat, value = value }
    for tableID, registry in pairs(KARDS.EngineHooks.Registry or {}) do
        if registry[KARDS.EngineHooks.HookPoints.OnModifyStat] then
            args = KARDS.EngineHooks.Trigger(tableID, KARDS.EngineHooks.HookPoints.OnModifyStat, args)
        end
    end
    return args.value
end

-- 服务器端：实体销毁时自动注销绑定的钩子（修饰与卡牌实体生命周期绑定，离场即失效）
if SERVER then
    hook.Add("EntityRemoved", "KARDS_EngineHooks_EntityRemoved", function(ent)
        if not IsValid(ent) and ent ~= nil then
            KARDS.EngineHooks.UnregisterByEntity(ent)
        end
    end)
end
