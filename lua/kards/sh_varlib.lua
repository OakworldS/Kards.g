-- Kards 全局变量库
-- 共享文件，服务端和客户端都会执行
-- 提供牌桌隔离的变量存储系统，每个牌桌拥有独立变量空间
-- 所有 Kards lua 文件均可通过 KARDS.VarLib 访问

KARDS = KARDS or {}
KARDS.VarLib = KARDS.VarLib or {}

-- ====================================================================
-- 配置
-- ====================================================================

-- 关键词列表（用于批量生成战斗特别变量）
-- 对应 markdown 中的：部署、守护、烟幕、闪击、伏击、亡计、重甲1/2/3、主动效果、
-- 被动效果、老兵、协力、情报、冲击、奋战、山地、收缴、被收缴、被压制、钳击、
-- 单位、指令、反制、步兵、炮兵、坦克、战斗机、轰炸机、被抑制
local KEYWORDS = {
    "Deploy", "Guard", "Smoke", "Blitz", "Ambush", "DeathPlan",
    "HeavyArmor1", "HeavyArmor2", "HeavyArmor3",
    "ActiveEffect", "PassiveEffect", "Veteran", "Cooperation", "Intel",
    "Impact", "FightHard", "Mountain",
    "Confiscate", "Confiscated", "Suppressed",
    "Pincer", "Unit", "Command", "Counter",
    "Infantry", "Artillery", "Tank", "Fighter", "Bomber",
    "Inhibited",
}

-- 关键词中文名映射（用于日志/调试）
local KEYWORD_CN = {
    Deploy = "部署", Guard = "守护", Smoke = "烟幕", Blitz = "闪击",
    Ambush = "伏击", DeathPlan = "亡计",
    HeavyArmor1 = "重甲1", HeavyArmor2 = "重甲2", HeavyArmor3 = "重甲3",
    ActiveEffect = "主动效果", PassiveEffect = "被动效果",
    Veteran = "老兵", Cooperation = "协力", Intel = "情报",
    Impact = "冲击", FightHard = "奋战", Mountain = "山地",
    Confiscate = "收缴", Confiscated = "被收缴", Suppressed = "被压制",
    Pincer = "钳击", Unit = "单位", Command = "指令", Counter = "反制",
    Infantry = "步兵", Artillery = "炮兵", Tank = "坦克",
    Fighter = "战斗机", Bomber = "轰炸机",
    Inhibited = "被抑制",
}

-- 关键词英文名映射（用于 Variables 英文显示名生成；与 keyword.<id>.name 的英文口径一致）
local KEYWORD_EN = {
    Deploy = "Deploy", Guard = "Guard", Smoke = "Smoke Screen", Blitz = "Blitz",
    Ambush = "Ambush", DeathPlan = "Last Strike",
    HeavyArmor1 = "Heavy Armor 1", HeavyArmor2 = "Heavy Armor 2", HeavyArmor3 = "Heavy Armor 3",
    ActiveEffect = "Active Effect", PassiveEffect = "Passive Effect",
    Veteran = "Veteran", Cooperation = "Cooperate", Intel = "Intelligence",
    Impact = "Impact", FightHard = "Fight", Mountain = "Mountain",
    Confiscate = "Confiscate", Confiscated = "Confiscated", Suppressed = "Suppressed",
    Pincer = "Pincer", Unit = "Unit", Command = "Order", Counter = "Counter",
    Infantry = "Infantry", Artillery = "Artillery", Tank = "Tank",
    Fighter = "Fighter", Bomber = "Bomber",
    Inhibited = "Neutralized",
}

-- 不需要"卡牌"相关变量的关键词（被压制、被收缴、被抑制）
-- 这些关键词只保留单位/场上相关变量，跳过手牌/牌库/卡牌相关变量
local SKIP_CARD_VARS = {
    Confiscated = true,
    Suppressed = true,
    Inhibited = true,
}

-- ====================================================================
-- 牌桌变量存储
-- ====================================================================

-- 所有牌桌的变量存储，以牌桌 ID 为键
-- KARDS.VarLib.Tables[tableID] = { Special = {}, Battle = {}, OffTable = {} }
KARDS.VarLib.Tables = KARDS.VarLib.Tables or {}

-- ====================================================================
-- 变量表工厂（B1：Create 与 ResetBattleVars 两段近 200 行重复收敛）
-- ====================================================================

-- 构建战斗特别变量表（Special，按关键词批量生成）
-- Create 与 ResetBattleVars 共用；每次调用重建全部关键词子表。
-- 传入 target 时复用其表引用（ResetBattleVars 保持 T.Special 引用不变，
-- 仅重填各子表——外部动态遍历 T.Special 的路径不受整体替换影响），
-- 否则新建返回。
-- @param target table|nil 复用目标表（可选；传入时先清空旧键）
-- @return table 填充完成的 Special 表
local function BuildSpecialVars(target)
    local special = target or {}
    if target then
        for k in pairs(special) do special[k] = nil end
    end

    for _, kw in ipairs(KEYWORDS) do
        local skipCard = SKIP_CARD_VARS[kw]
        local s = {}
        special[kw] = s

        if not skipCard then
            -- 手牌/牌库/卡组相关变量（被压制/被收缴/被抑制跳过这些）
            s.FriendlyHandCount    = 0      -- n己方手牌中具有"XX"卡牌数
            s.FriendlyDeckCount    = 0      -- n己方牌库中具有"XX"卡牌数
            s.EnemyHandCount       = 0      -- n对方手牌中具有"XX"卡牌数
            s.EnemyDeckCount       = 0      -- n对方牌库中具有"XX"卡牌数
            s.HasDeploy            = false  -- ?卡组中具有"XX"
            s.DeployCount          = 0      -- n卡组中具有"XX"数量
            s.EnemyHasDeploy       = false  -- ?敌方卡组中具有"XX"
            s.EnemyDeployCount     = 0      -- n敌方卡组中具有"XX"卡牌数量
            s.FieldHasDeploy       = false  -- ?场上具有"XX"卡牌
            s.HandCards            = {}     -- []手牌中具有"XX"变量的卡牌
            s.EnemyHandCards       = {}     -- []敌方手牌中具有"XX"效果的卡牌
            s.FieldCards           = {}     -- []场上具有"XX"的卡牌
            s.FriendlyFieldCards   = {}     -- []友方场上具有"XX"的卡牌
            s.EnemyFieldCards      = {}     -- []敌方场上具有"XX"的卡牌
        end

        -- 场上/单位相关变量（所有关键词都有）
        s.FieldUnitCount         = 0      -- n场上具有"XX"单位数
        s.HasFriendlyUnit        = false  -- ?己方具有"XX"单位
        s.FriendlyUnitCount      = 0      -- n己方具有"XX"单位数量
        s.HasEnemyUnit           = false  -- ?敌方具有"XX"单位
        s.EnemyUnitCount         = 0      -- n敌方具有"XX"单位数
    end

    return special
end

-- 构建战斗基础变量表（Battle）
-- Create 与 ResetBattleVars 共用（字段完全一致）；仅 ResetBattleVars 需保留
-- 玩家选的国家与重新调度状态（preserved 传入），Create 缺省按初始值
-- （国家 "" / 重新调度 false）。
-- @param preserved table|nil 保留字段：
--   { FriendlyMainCountry, EnemyMainCountry, FriendlyAllyCountry, EnemyAllyCountry,
--     FriendlyReshuffled, EnemyReshuffled }
-- @return table 新的 Battle 表
local function BuildBattleVars(preserved)
    return {
        -- 全局战斗变量
        Turn                = 0,      -- n回合数
        IsFriendlyTurn      = false,  -- ?友方回合
        FieldUnitCount      = 0,      -- n场上单位数
        FriendlyUnitCount   = 0,      -- n友方单位数
        TotalDeployedThisGame = 0,    -- n本局已部署单位
        GameDuration        = 0,      -- n本局局时长（秒）
        FrontlineUnitCount  = 0,      -- n前线单位数

        -- E 前缀变量（友方/敌方各一份）

        -- 手牌/卡组
        FriendlyHandCount   = 0,      -- nE手牌数
        EnemyHandCount      = 0,
        FriendlyDeckCount   = 0,      -- nE卡组内牌数
        EnemyDeckCount      = 0,

        -- 总血量
        FriendlyTotalHP     = 0,      -- nE总血量
        EnemyTotalHP        = 0,

        -- 本回合使用指令次数
        FriendlyCommandUsed    = 0,   -- nE本回合使用指令次
        EnemyCommandUsed       = 0,

        -- 本回合部署单位数
        FriendlyDeployCount    = 0,   -- nE本回合部署单位数
        EnemyDeployCount       = 0,

        -- 总部署单位数（整局）
        FriendlyDeployTotal    = 0,   -- nE部署单位数
        EnemyDeployTotal       = 0,

        -- 支援阵线
        FriendlySupportCount   = 0,   -- nE支援阵线单位数
        EnemySupportCount      = 0,

        -- 在场单位列表
        FriendlyUnits          = {},  -- []E在场单位
        EnemyUnits             = {},
        FriendlySupportUnits   = {},  -- []E支援阵线上的单位
        EnemySupportUnits      = {},
        FriendlyFrontlineUnits = {},  -- []E前线上的单位
        EnemyFrontlineUnits    = {},

        -- 宏观对象/对象组变量（亨舍尔伤害倍率等方案的数据源）
        -- 对象：单个实体引用（目标/总部）
        FriendlyTarget         = nil, -- e友方可选目标（单位 or 总部）
        EnemyTarget            = nil, -- e敌方可选目标（单位 or 总部）
        FriendlyHeadquarter    = nil, -- e友方总部
        EnemyHeadquarter       = nil, -- e敌方总部

        -- 对象组：按战斗类型
        FriendlyGroundUnits    = {},  -- []E友方陆军单位（步兵/坦克/炮兵）
        EnemyGroundUnits       = {},  -- []E敌方陆军单位
        FriendlyAirUnits       = {},  -- []E友方空军单位（战斗机/轰炸机）
        EnemyAirUnits          = {},  -- []E敌方空军单位
        FriendlyInfantry       = {},  -- []E友方步兵
        EnemyInfantry          = {},  -- []E敌方步兵
        FriendlyTank           = {},  -- []E友方坦克
        EnemyTank              = {},  -- []E敌方坦克
        FriendlyArtillery      = {},  -- []E友方炮兵
        EnemyArtillery         = {},  -- []E敌方炮兵
        FriendlyFighter        = {},  -- []E友方战斗机
        EnemyFighter           = {},  -- []E敌方战斗机
        FriendlyBomber         = {},  -- []E友方轰炸机
        EnemyBomber            = {},  -- []E敌方轰炸机

        -- 对象组：按卡牌类型（含手牌/牌库/场上）
        FriendlyUnitCards      = {},  -- []E友方单位卡牌
        EnemyUnitCards         = {},  -- []E敌方单位卡牌
        FriendlyCommandCards   = {},  -- []E友方指令卡牌
        EnemyCommandCards      = {},  -- []E敌方指令卡牌
        FriendlyCounterCards   = {},  -- []E友方反制卡牌
        EnemyCounterCards      = {},  -- []E敌方反制卡牌

        -- 抽牌/弃牌/爆牌
        FriendlyDrawCount     = 0,    -- nE本回合抽牌数
        EnemyDrawCount        = 0,
        FriendlyDiscardCount  = 0,    -- nE本回合弃牌数
        EnemyDiscardCount     = 0,
        FriendlyBurnCount     = 0,    -- nE本回合爆牌数
        EnemyBurnCount        = 0,

        -- 士气伤害积累
        FriendlyMoraleDamage  = 0,    -- nE士气伤害积累值
        EnemyMoraleDamage     = 0,

        -- 国家（文本）
        FriendlyMainCountry   = preserved and preserved.FriendlyMainCountry or "",   -- tE主国
        EnemyMainCountry      = preserved and preserved.EnemyMainCountry or "",
        FriendlyAllyCountry   = preserved and preserved.FriendlyAllyCountry or "",   -- tE盟国
        EnemyAllyCountry      = preserved and preserved.EnemyAllyCountry or "",

        -- 重新调度
        FriendlyReshuffled    = preserved and preserved.FriendlyReshuffled or false, -- ?E重新调度完成
        EnemyReshuffled       = preserved and preserved.EnemyReshuffled or false,

        -- 总部累计伤害
        FriendlyHQLastTurnDamage = 0, -- nE总部本回合累计受到伤害
        EnemyHQLastTurnDamage    = 0,

        -- 剩余指挥点
        FriendlyCommandPoints    = 0, -- nE剩余指挥点
        EnemyCommandPoints       = 0,
    }
end

-- ====================================================================
-- 剩余指挥点 → 变量库事实（2026-10-04）
-- ====================================================================

--[[
    把当前指挥点写入变量库 Battle 区事实变量（FriendlyCommandPoints / EnemyCommandPoints）。

    「友方」取 KARDS.Battle.Players[1]，「敌方」取 Players[2]（与既有事实变量默认视角一致）。
    直接赋值（不经 SetFactOverride），使剩余指挥点为跨回合持续的真实事实；
    由 KARDS.CommandPoints.OnChanged 在指挥点/槽变更时回调（注册见 VarLib.Create）。
]]
function KARDS.VarLib.SyncCommandPoints(tableID)
    local T = KARDS.VarLib.Tables[tableID]
    if not T or not T.Battle then return end
    if not KARDS.CommandPoints then return end
    local players = (KARDS.Battle and KARDS.Battle.Players) or { "P1", "P2" }
    if players[1] then
        T.Battle.FriendlyCommandPoints = KARDS.CommandPoints:GetPoints(tableID, players[1]) or 0
    end
    if players[2] then
        T.Battle.EnemyCommandPoints = KARDS.CommandPoints:GetPoints(tableID, players[2]) or 0
    end
end

-- ====================================================================
-- 创建牌桌变量库
-- ====================================================================

-- 为指定牌桌创建完整的变量库
-- @param tableID string 牌桌唯一标识符（如 "1", "2"）
-- @return table 创建的变量库，若已存在则返回现有库
function KARDS.VarLib.Create(tableID)
    if KARDS.VarLib.Tables[tableID] then
        return KARDS.VarLib.Tables[tableID]
    end

    local T = {}
    KARDS.VarLib.Tables[tableID] = T

    -- 浮点变量追踪表（记录可能出现小数的数字型变量路径）
    T._floatVars = {}

    -- 事实变量一回合覆盖登记：[path] = { prev = 覆盖前的值, hasPrev = 覆盖前是否存在 }
    -- 「设置变量」节点改写 Battle.* / Special.* 时登记，回合边界还原（见本文件事实变量段）
    T.FactOverrides = {}

    -- 卡牌实例变量空间（global 作用域用户变量：每张卡牌实例隔离，不受其他全等卡牌设置影响）
    -- 结构：T.CardVars[卡牌ID][internalName] = 值；战斗结束随 ResetBattleVars 清空
    T.CardVars = {}

    -- ====================================================================
    -- 战斗特别变量（按关键词批量生成）
    -- ====================================================================
    T.Special = BuildSpecialVars()

    -- ====================================================================
    -- 战斗时基础变量
    -- ====================================================================
    T.Battle = BuildBattleVars()

    -- ====================================================================
    -- 场外变量
    -- ====================================================================
    T.OffTable = {
        -- 玩家数据表（按 SteamID 索引）
        -- 每个玩家包含：
        --   HP          - n玩家血量
        --   Armor       - n玩家防护衣护甲
        --   Name        - t玩家名
        --   SteamID     - t玩家 Steam 数据
        --   SteamID64   - t玩家 Steam64 数据
        Players = {},

        ServerPlayerCount = 0,    -- n服务器玩家数
        ServerName        = "",   -- t服务器名

        -- 当前时间
        Year   = 0,               -- n当前时间（年）
        Month  = 0,               -- n当前时间（月）
        Day    = 0,               -- n当前时间（日）
        Hour   = 0,               -- n当前时间（时）
        Minute = 0,               -- n当前时间（分）
        Second = 0,               -- n当前时间（秒）

        NearbyPlayerCount = 0,    -- n牌桌附近玩家数
    }

    -- 构建对象/对象组变量路径列表（亨舍尔伤害倍率等方案的数据源）
    KARDS.VarLib.RebuildObjectVarPaths(tableID)

    -- 剩余指挥点同步（2026-10-04）：注册指挥点变更回调并立即同步一次
    if KARDS.CommandPoints then
        KARDS.CommandPoints.OnChanged = function(tid, player)
            if tid == tableID then KARDS.VarLib.SyncCommandPoints(tid) end
        end
        KARDS.VarLib.SyncCommandPoints(tableID)
    end

    return T
end

-- ====================================================================
-- 销毁牌桌变量库
-- ====================================================================

-- 销毁指定牌桌的变量库（牌桌被外因销毁时调用）
-- @param tableID string 牌桌唯一标识符
function KARDS.VarLib.Destroy(tableID)
    KARDS.VarLib.Tables[tableID] = nil
    KARDS.VarLib.ObjectVarPaths[tableID] = nil
end

-- 销毁所有牌桌的变量库
function KARDS.VarLib.DestroyAll()
    KARDS.VarLib.Tables = {}
    KARDS.VarLib.ObjectVarPaths = {}
end

-- ====================================================================
-- 获取牌桌变量库
-- ====================================================================

-- 获取指定牌桌的变量库
-- @param tableID string 牌桌唯一标识符
-- @return table|nil 变量库，若未创建则返回 nil
function KARDS.VarLib.Get(tableID)
    return KARDS.VarLib.Tables[tableID]
end

-- 获取或创建牌桌变量库
-- @param tableID string 牌桌唯一标识符
-- @return table 变量库
function KARDS.VarLib.GetOrCreate(tableID)
    if not KARDS.VarLib.Tables[tableID] then
        return KARDS.VarLib.Create(tableID)
    end
    return KARDS.VarLib.Tables[tableID]
end

-- ====================================================================
-- 牌桌变量库状态查询
-- ====================================================================

-- 检查牌桌变量库是否存在
-- @param tableID string 牌桌唯一标识符
-- @return boolean
function KARDS.VarLib.Exists(tableID)
    return KARDS.VarLib.Tables[tableID] ~= nil
end

-- 获取所有已创建的牌桌 ID 列表
-- @return table 牌桌 ID 数组
function KARDS.VarLib.GetAllTableIDs()
    local ids = {}
    for id, _ in pairs(KARDS.VarLib.Tables) do
        table.insert(ids, id)
    end
    return ids
end

-- 获取已创建的牌桌数量
-- @return number
function KARDS.VarLib.GetTableCount()
    local count = 0
    for _ in pairs(KARDS.VarLib.Tables) do
        count = count + 1
    end
    return count
end

-- ====================================================================
-- 浮点变量追踪
-- ====================================================================

-- 将变量标记为浮点类型（可能出现小数）
-- @param tableID string 牌桌唯一标识符
-- @param varPath string 变量路径，如 "Battle.GameDuration"
function KARDS.VarLib.MarkFloat(tableID, varPath)
    local T = KARDS.VarLib.Get(tableID)
    if T then
        T._floatVars[varPath] = true
    end
end

-- 检查变量是否被标记为浮点类型
-- @param tableID string 牌桌唯一标识符
-- @param varPath string 变量路径
-- @return boolean
function KARDS.VarLib.IsFloat(tableID, varPath)
    local T = KARDS.VarLib.Get(tableID)
    return T and T._floatVars[varPath] or false
end

-- 获取指定牌桌所有浮点类型变量路径的列表
-- @param tableID string 牌桌唯一标识符
-- @return table 变量路径字符串数组
function KARDS.VarLib.GetFloatVars(tableID)
    local T = KARDS.VarLib.Get(tableID)
    local result = {}
    if T then
        for path, _ in pairs(T._floatVars) do
            table.insert(result, path)
        end
    end
    return result
end

-- ====================================================================
-- 事实变量一回合覆盖（断言变量，2026-10-04 用户规格）
-- ====================================================================
-- 「设置变量」节点改写系统事实变量（Battle.* / Special.*，如「友方有老兵单位」
-- Special.Veteran.HasFriendlyUnit）时，写入只在本回合内生效：写前快照覆盖前的值，
-- 回合边界（SimEndTurn，见 sh_battle_stub.lua）调用 ClearFactOverrides 还原为
-- 覆盖前的值（即当前事实）。用户自定义变量与卡牌实例变量（CardVars / KARDS.User.*）
-- 不在此列，保持原有持久语义。

-- 按路径逐层设置值（与 sh_node_semantics.lua SetByPath 同式；value 为 nil 时把叶子置 nil）
local function SetPathValue(section, path, value)
    if type(section) ~= "table" or type(path) ~= "string" or path == "" then return false end
    local segs = {}
    for seg in string.gmatch(path, "[^.]+") do table.insert(segs, seg) end
    local cur = section
    for i = 1, #segs - 1 do
        if type(cur[segs[i]]) ~= "table" then cur[segs[i]] = {} end
        cur = cur[segs[i]]
    end
    cur[segs[#segs]] = value
    return true
end

-- 拆分事实变量路径 → 区域名 + 区域内的键路径（"Battle.Turn" → "Battle", "Turn"）
local function SplitFactPath(path)
    local dot = path:find(".", 1, true)
    if not dot then return nil, nil end
    return path:sub(1, dot - 1), path:sub(dot + 1)
end

-- 路径是否为系统事实变量（Battle.* / Special.*）
-- @param path string 变量路径
-- @return boolean
function KARDS.VarLib.IsFactPath(path)
    if type(path) ~= "string" then return false end
    local head = path:match("^([^.]+)")
    return head == "Battle" or head == "Special"
end

-- 该事实变量本回合是否已被「设置变量」覆盖（覆盖期间事实刷新应让位，见 SetFact）
-- @param tableID string 牌桌唯一标识符
-- @param path    string 变量路径
-- @return boolean
function KARDS.VarLib.IsFactOverridden(tableID, path)
    local T = KARDS.VarLib.Get(tableID)
    return (T and T.FactOverrides and T.FactOverrides[path]) and true or false
end

-- 登记事实变量的一回合覆盖（写前快照覆盖前值；同回合重复写入只记录首次的旧值）
-- @param tableID   string 牌桌唯一标识符
-- @param path      string 变量路径
-- @param prevValue any 覆盖前的值（nil 表示该路径原本不存在）
function KARDS.VarLib.SetFactOverride(tableID, path, prevValue)
    if not KARDS.VarLib.IsFactPath(path) then return end
    local T = KARDS.VarLib.GetOrCreate(tableID)
    T.FactOverrides = T.FactOverrides or {}
    if T.FactOverrides[path] == nil then
        T.FactOverrides[path] = { prev = prevValue, hasPrev = (prevValue ~= nil) }
    end
end

-- 事实写入（供未来的战场事实刷新器使用）：该路径本回合被覆盖时让位（不写入），
-- 未覆盖时正常写值。回合边界清覆盖后，刷新器重跑即可写回真实事实。
-- @param tableID string 牌桌唯一标识符
-- @param path    string 变量路径
-- @param value   any 事实值
-- @return boolean 是否写入（false = 已被设置变量覆盖，让位）
function KARDS.VarLib.SetFact(tableID, path, value)
    if KARDS.VarLib.IsFactOverridden(tableID, path) then return false end
    local T = KARDS.VarLib.Get(tableID)
    if not T then return false end
    local section, key = SplitFactPath(path)
    if not section or not T[section] then return false end
    return SetPathValue(T[section], key, value)
end

-- 还原全部事实变量覆盖（回合边界 SimEndTurn 调用）：按登记的覆盖前值写回，清空登记
-- @param tableID string 牌桌唯一标识符
function KARDS.VarLib.ClearFactOverrides(tableID)
    local T = KARDS.VarLib.Get(tableID)
    if not T or not T.FactOverrides then return end
    for path, rec in pairs(T.FactOverrides) do
        local section, key = SplitFactPath(path)
        if section and key and T[section] then
            SetPathValue(T[section], key, rec.hasPrev and rec.prev or nil)
        end
    end
    T.FactOverrides = {}
end

-- ====================================================================
-- 玩家数据管理
-- ====================================================================

-- 添加或更新牌桌上的玩家数据
-- @param tableID string 牌桌唯一标识符
-- @param steamID string 玩家 SteamID
-- @param data table 玩家数据 { HP, Armor, Name, SteamID, SteamID64 }
function KARDS.VarLib.SetPlayerData(tableID, steamID, data)
    local T = KARDS.VarLib.GetOrCreate(tableID)
    T.OffTable.Players[steamID] = data
end

-- 获取牌桌上指定玩家的数据
-- @param tableID string 牌桌唯一标识符
-- @param steamID string 玩家 SteamID
-- @return table|nil
function KARDS.VarLib.GetPlayerData(tableID, steamID)
    local T = KARDS.VarLib.Get(tableID)
    if not T then return nil end
    return T.OffTable.Players[steamID]
end

-- 从牌桌上移除玩家
-- @param tableID string 牌桌唯一标识符
-- @param steamID string 玩家 SteamID
function KARDS.VarLib.RemovePlayer(tableID, steamID)
    local T = KARDS.VarLib.Get(tableID)
    if T then
        T.OffTable.Players[steamID] = nil
    end
end

-- 获取牌桌上所有玩家数据
-- @param tableID string 牌桌唯一标识符
-- @return table 玩家数据表（SteamID -> data）
function KARDS.VarLib.GetAllPlayers(tableID)
    local T = KARDS.VarLib.Get(tableID)
    if not T then return {} end
    return T.OffTable.Players
end

-- ====================================================================
-- 快捷访问函数
-- ====================================================================

-- 重置牌桌的战斗变量（每局开始前调用）
-- 保留牌桌和玩家信息，只清空战斗相关变量
-- @param tableID string 牌桌唯一标识符
function KARDS.VarLib.ResetBattleVars(tableID)
    local T = KARDS.VarLib.Get(tableID)
    if not T then return end

    -- 获取当前国家和玩家数据的引用
    local oldMainCountryF = T.Battle.FriendlyMainCountry
    local oldMainCountryE = T.Battle.EnemyMainCountry
    local oldAllyCountryF = T.Battle.FriendlyAllyCountry
    local oldAllyCountryE = T.Battle.EnemyAllyCountry
    local oldReshuffledF  = T.Battle.FriendlyReshuffled
    local oldReshuffledE  = T.Battle.EnemyReshuffled
    local players = T.OffTable.Players

    -- 重新创建 Special 部分（复用原表引用，仅重填各关键词子表，B1 工厂）
    BuildSpecialVars(T.Special)

    -- 重新创建 Battle 部分，保留国家（玩家选的）和重新调度状态（B1 工厂）
    T.Battle = BuildBattleVars({
        FriendlyMainCountry = oldMainCountryF,
        EnemyMainCountry    = oldMainCountryE,
        FriendlyAllyCountry = oldAllyCountryF,
        EnemyAllyCountry    = oldAllyCountryE,
        FriendlyReshuffled  = oldReshuffledF,
        EnemyReshuffled     = oldReshuffledE,
    })

    -- 恢复玩家数据引用
    T.OffTable.Players = players

    -- 清空卡牌实例变量空间（global 作用域用户变量，战斗结束重置）
    T.CardVars = {}

    -- 清空事实变量一回合覆盖登记（新对局重新开始，旧覆盖不跨局残留）
    T.FactOverrides = {}

    -- 重建对象/对象组变量路径列表
    KARDS.VarLib.RebuildObjectVarPaths(tableID)
end

-- ====================================================================
-- 变量名翻译系统
-- ====================================================================

-- 当前语言（默认跟随 Kards 界面语言）
KARDS.VarLib.CurrentLanguage = KARDS.VarLib.CurrentLanguage
    or (KARDS.Lang and KARDS.Lang.GetLanguage())
    or "zh-CN"

-- 翻译表：变量路径 -> 显示名称
-- 支持多语言：KARDS.VarLib.Translations["zh-CN"]["Battle.Turn"] = "回合数"
KARDS.VarLib.Translations = KARDS.VarLib.Translations or {}

-- 初始化中文翻译表
local function InitChineseTranslations()
    local t = {}
    KARDS.VarLib.Translations["zh-CN"] = t

    -- Battle 基础变量
    t["Battle.Turn"] = "回合数"
    t["Battle.IsFriendlyTurn"] = "是否友方回合"
    t["Battle.FieldUnitCount"] = "场上单位数"
    t["Battle.FriendlyUnitCount"] = "友方单位数"
    t["Battle.TotalDeployedThisGame"] = "本局已部署单位"
    t["Battle.GameDuration"] = "本局时长(秒)"
    t["Battle.FrontlineUnitCount"] = "前线单位数"
    t["Battle.FriendlyHandCount"] = "友方手牌数"
    t["Battle.EnemyHandCount"] = "敌方手牌数"
    t["Battle.FriendlyDeckCount"] = "友方卡组牌数"
    t["Battle.EnemyDeckCount"] = "敌方卡组牌数"
    t["Battle.FriendlyTotalHP"] = "友方总血量"
    t["Battle.EnemyTotalHP"] = "敌方总血量"
    t["Battle.FriendlyCommandUsed"] = "友方本回合指令数"
    t["Battle.EnemyCommandUsed"] = "敌方本回合指令数"
    t["Battle.FriendlyDeployCount"] = "友方本回合部署数"
    t["Battle.EnemyDeployCount"] = "敌方本回合部署数"
    t["Battle.FriendlyDeployTotal"] = "友方部署总数"
    t["Battle.EnemyDeployTotal"] = "敌方部署总数"
    t["Battle.FriendlySupportCount"] = "友方支援单位数"
    t["Battle.EnemySupportCount"] = "敌方支援单位数"
    t["Battle.FriendlyDrawCount"] = "友方本回合抽牌数"
    t["Battle.EnemyDrawCount"] = "敌方本回合抽牌数"
    t["Battle.FriendlyDiscardCount"] = "友方本回合弃牌数"
    t["Battle.EnemyDiscardCount"] = "敌方本回合弃牌数"
    t["Battle.FriendlyBurnCount"] = "友方本回合爆牌数"
    t["Battle.EnemyBurnCount"] = "敌方本回合爆牌数"
    t["Battle.FriendlyMoraleDamage"] = "友方士气伤害"
    t["Battle.EnemyMoraleDamage"] = "敌方士气伤害"
    t["Battle.FriendlyReshuffled"] = "友方重新调度"
    t["Battle.EnemyReshuffled"] = "敌方重新调度"
    t["Battle.FriendlyHQLastTurnDamage"] = "友方总部本回合受伤"
    t["Battle.EnemyHQLastTurnDamage"] = "敌方总部本回合受伤"
    t["Battle.FriendlyCommandPoints"] = "友方剩余指挥点"
    t["Battle.EnemyCommandPoints"] = "敌方剩余指挥点"

    -- Battle 对象组变量
    t["Battle.FriendlyUnits"] = "友方在场单位"
    t["Battle.EnemyUnits"] = "敌方在场单位"
    t["Battle.FriendlySupportUnits"] = "友方支援单位"
    t["Battle.EnemySupportUnits"] = "敌方支援单位"
    t["Battle.FriendlyFrontlineUnits"] = "友方前线单位"
    t["Battle.EnemyFrontlineUnits"] = "敌方前线单位"

    -- 宏观对象/对象组变量
    t["Battle.FriendlyTarget"] = "友方可选目标"
    t["Battle.EnemyTarget"] = "敌方可选目标"
    t["Battle.FriendlyHeadquarter"] = "友方总部"
    t["Battle.EnemyHeadquarter"] = "敌方总部"
    t["Battle.FriendlyGroundUnits"] = "友方陆军单位"
    t["Battle.EnemyGroundUnits"] = "敌方陆军单位"
    t["Battle.FriendlyAirUnits"] = "友方空军单位"
    t["Battle.EnemyAirUnits"] = "敌方空军单位"
    t["Battle.FriendlyInfantry"] = "友方步兵"
    t["Battle.EnemyInfantry"] = "敌方步兵"
    t["Battle.FriendlyTank"] = "友方坦克"
    t["Battle.EnemyTank"] = "敌方坦克"
    t["Battle.FriendlyArtillery"] = "友方炮兵"
    t["Battle.EnemyArtillery"] = "敌方炮兵"
    t["Battle.FriendlyFighter"] = "友方战斗机"
    t["Battle.EnemyFighter"] = "敌方战斗机"
    t["Battle.FriendlyBomber"] = "友方轰炸机"
    t["Battle.EnemyBomber"] = "敌方轰炸机"
    t["Battle.FriendlyUnitCards"] = "友方单位卡牌"
    t["Battle.EnemyUnitCards"] = "敌方单位卡牌"
    t["Battle.FriendlyCommandCards"] = "友方指令卡牌"
    t["Battle.EnemyCommandCards"] = "敌方指令卡牌"
    t["Battle.FriendlyCounterCards"] = "友方反制卡牌"
    t["Battle.EnemyCounterCards"] = "敌方反制卡牌"

    -- Battle 文本变量（字符串）
    t["Battle.FriendlyMainCountry"] = "友方主国"
    t["Battle.EnemyMainCountry"] = "敌方主国"
    t["Battle.FriendlyAllyCountry"] = "友方盟国"
    t["Battle.EnemyAllyCountry"] = "敌方盟国"

    -- OffTable 变量
    t["OffTable.ServerPlayerCount"] = "服务器玩家数"
    t["OffTable.ServerName"] = "服务器名"
    t["OffTable.Players"] = "玩家列表"
    t["OffTable.Year"] = "当前年份"
    t["OffTable.Month"] = "当前月份"
    t["OffTable.Day"] = "当前日期"
    t["OffTable.Hour"] = "当前小时"
    t["OffTable.Minute"] = "当前分钟"
    t["OffTable.Second"] = "当前秒数"
    t["OffTable.NearbyPlayerCount"] = "附近玩家数"

    -- Special 关键词变量（按关键词批量生成）
    for _, kw in ipairs(KEYWORDS) do
        local kwCN = KEYWORD_CN[kw] or kw
        local skipCard = SKIP_CARD_VARS[kw]

        if not skipCard then
            t["Special." .. kw .. ".FriendlyHandCount"] = "友方手牌" .. kwCN .. "数"
            t["Special." .. kw .. ".FriendlyDeckCount"] = "友方卡组" .. kwCN .. "数"
            t["Special." .. kw .. ".EnemyHandCount"] = "敌方手牌" .. kwCN .. "数"
            t["Special." .. kw .. ".EnemyDeckCount"] = "敌方卡组" .. kwCN .. "数"
            t["Special." .. kw .. ".HasDeploy"] = "卡组有" .. kwCN
            t["Special." .. kw .. ".DeployCount"] = "卡组" .. kwCN .. "数量"
            t["Special." .. kw .. ".EnemyHasDeploy"] = "敌方卡组有" .. kwCN
            t["Special." .. kw .. ".EnemyDeployCount"] = "敌方卡组" .. kwCN .. "数"
            t["Special." .. kw .. ".FieldHasDeploy"] = "场有" .. kwCN .. "卡"
            -- Special 对象组变量
            t["Special." .. kw .. ".HandCards"] = "手牌" .. kwCN .. "卡牌"
            t["Special." .. kw .. ".EnemyHandCards"] = "敌方手牌" .. kwCN .. "卡牌"
            t["Special." .. kw .. ".FieldCards"] = "场上" .. kwCN .. "卡牌"
            t["Special." .. kw .. ".FriendlyFieldCards"] = "友方场上" .. kwCN .. "卡牌"
            t["Special." .. kw .. ".EnemyFieldCards"] = "敌方场上" .. kwCN .. "卡牌"
        end

        t["Special." .. kw .. ".FieldUnitCount"] = "场上" .. kwCN .. "单位数"
        t["Special." .. kw .. ".HasFriendlyUnit"] = "友方有" .. kwCN .. "单位"
        t["Special." .. kw .. ".FriendlyUnitCount"] = "友方" .. kwCN .. "单位数"
        t["Special." .. kw .. ".HasEnemyUnit"] = "敌方有" .. kwCN .. "单位"
        t["Special." .. kw .. ".EnemyUnitCount"] = "敌方" .. kwCN .. "单位数"
    end
end

-- 初始化英文翻译表（与中文表同构，变量路径一一对应）
local function InitEnglishTranslations()
    local t = {}
    KARDS.VarLib.Translations["en"] = t

    -- Battle base variables
    t["Battle.Turn"] = "Turn"
    t["Battle.IsFriendlyTurn"] = "Is Friendly Turn"
    t["Battle.FieldUnitCount"] = "Units on Field"
    t["Battle.FriendlyUnitCount"] = "Friendly Units"
    t["Battle.TotalDeployedThisGame"] = "Units Deployed This Game"
    t["Battle.GameDuration"] = "Game Duration (s)"
    t["Battle.FrontlineUnitCount"] = "Frontline Units"
    t["Battle.FriendlyHandCount"] = "Friendly Hand Size"
    t["Battle.EnemyHandCount"] = "Enemy Hand Size"
    t["Battle.FriendlyDeckCount"] = "Friendly Deck Size"
    t["Battle.EnemyDeckCount"] = "Enemy Deck Size"
    t["Battle.FriendlyTotalHP"] = "Friendly Total HP"
    t["Battle.EnemyTotalHP"] = "Enemy Total HP"
    t["Battle.FriendlyCommandUsed"] = "Friendly Orders This Turn"
    t["Battle.EnemyCommandUsed"] = "Enemy Orders This Turn"
    t["Battle.FriendlyDeployCount"] = "Friendly Deploys This Turn"
    t["Battle.EnemyDeployCount"] = "Enemy Deploys This Turn"
    t["Battle.FriendlyDeployTotal"] = "Friendly Total Deploys"
    t["Battle.EnemyDeployTotal"] = "Enemy Total Deploys"
    t["Battle.FriendlySupportCount"] = "Friendly Support Units"
    t["Battle.EnemySupportCount"] = "Enemy Support Units"
    t["Battle.FriendlyDrawCount"] = "Friendly Cards Drawn This Turn"
    t["Battle.EnemyDrawCount"] = "Enemy Cards Drawn This Turn"
    t["Battle.FriendlyDiscardCount"] = "Friendly Cards Discarded This Turn"
    t["Battle.EnemyDiscardCount"] = "Enemy Cards Discarded This Turn"
    t["Battle.FriendlyBurnCount"] = "Friendly Cards Burned This Turn"
    t["Battle.EnemyBurnCount"] = "Enemy Cards Burned This Turn"
    t["Battle.FriendlyMoraleDamage"] = "Friendly Morale Damage"
    t["Battle.EnemyMoraleDamage"] = "Enemy Morale Damage"
    t["Battle.FriendlyReshuffled"] = "Friendly Mulligan"
    t["Battle.EnemyReshuffled"] = "Enemy Mulligan"
    t["Battle.FriendlyHQLastTurnDamage"] = "Friendly HQ Damage Last Turn"
    t["Battle.EnemyHQLastTurnDamage"] = "Enemy HQ Damage Last Turn"
    t["Battle.FriendlyCommandPoints"] = "Friendly Command Points"
    t["Battle.EnemyCommandPoints"] = "Enemy Command Points"

    -- Battle object group variables
    t["Battle.FriendlyUnits"] = "Friendly Units on Field"
    t["Battle.EnemyUnits"] = "Enemy Units on Field"
    t["Battle.FriendlySupportUnits"] = "Friendly Support Units"
    t["Battle.EnemySupportUnits"] = "Enemy Support Units"
    t["Battle.FriendlyFrontlineUnits"] = "Friendly Frontline Units"
    t["Battle.EnemyFrontlineUnits"] = "Enemy Frontline Units"

    -- Macro object / object group variables
    t["Battle.FriendlyTarget"] = "Friendly Valid Targets"
    t["Battle.EnemyTarget"] = "Enemy Valid Targets"
    t["Battle.FriendlyHeadquarter"] = "Friendly HQ"
    t["Battle.EnemyHeadquarter"] = "Enemy HQ"
    t["Battle.FriendlyGroundUnits"] = "Friendly Ground Units"
    t["Battle.EnemyGroundUnits"] = "Enemy Ground Units"
    t["Battle.FriendlyAirUnits"] = "Friendly Air Units"
    t["Battle.EnemyAirUnits"] = "Enemy Air Units"
    t["Battle.FriendlyInfantry"] = "Friendly Infantry"
    t["Battle.EnemyInfantry"] = "Enemy Infantry"
    t["Battle.FriendlyTank"] = "Friendly Tank"
    t["Battle.EnemyTank"] = "Enemy Tank"
    t["Battle.FriendlyArtillery"] = "Friendly Artillery"
    t["Battle.EnemyArtillery"] = "Enemy Artillery"
    t["Battle.FriendlyFighter"] = "Friendly Fighter"
    t["Battle.EnemyFighter"] = "Enemy Fighter"
    t["Battle.FriendlyBomber"] = "Friendly Bomber"
    t["Battle.EnemyBomber"] = "Enemy Bomber"
    t["Battle.FriendlyUnitCards"] = "Friendly Unit Cards"
    t["Battle.EnemyUnitCards"] = "Enemy Unit Cards"
    t["Battle.FriendlyCommandCards"] = "Friendly Order Cards"
    t["Battle.EnemyCommandCards"] = "Enemy Order Cards"
    t["Battle.FriendlyCounterCards"] = "Friendly Counter Cards"
    t["Battle.EnemyCounterCards"] = "Enemy Counter Cards"

    -- Battle text variables (strings)
    t["Battle.FriendlyMainCountry"] = "Friendly Main Nation"
    t["Battle.EnemyMainCountry"] = "Enemy Main Nation"
    t["Battle.FriendlyAllyCountry"] = "Friendly Ally Nation"
    t["Battle.EnemyAllyCountry"] = "Enemy Ally Nation"

    -- OffTable variables
    t["OffTable.ServerPlayerCount"] = "Server Player Count"
    t["OffTable.ServerName"] = "Server Name"
    t["OffTable.Players"] = "Player List"
    t["OffTable.Year"] = "Current Year"
    t["OffTable.Month"] = "Current Month"
    t["OffTable.Day"] = "Current Day"
    t["OffTable.Hour"] = "Current Hour"
    t["OffTable.Minute"] = "Current Minute"
    t["OffTable.Second"] = "Current Second"
    t["OffTable.NearbyPlayerCount"] = "Nearby Player Count"

    -- Special keyword variables (generated per keyword)
    for _, kw in ipairs(KEYWORDS) do
        local name = KEYWORD_EN[kw] or kw
        local skipCard = SKIP_CARD_VARS[kw]

        if not skipCard then
            t["Special." .. kw .. ".FriendlyHandCount"] = "Friendly " .. name .. " Cards in Hand"
            t["Special." .. kw .. ".FriendlyDeckCount"] = "Friendly " .. name .. " Cards in Deck"
            t["Special." .. kw .. ".EnemyHandCount"] = "Enemy " .. name .. " Cards in Hand"
            t["Special." .. kw .. ".EnemyDeckCount"] = "Enemy " .. name .. " Cards in Deck"
            t["Special." .. kw .. ".HasDeploy"] = "Deck Has " .. name
            t["Special." .. kw .. ".DeployCount"] = "Number of " .. name .. " in Deck"
            t["Special." .. kw .. ".EnemyHasDeploy"] = "Enemy Deck Has " .. name
            t["Special." .. kw .. ".EnemyDeployCount"] = "Number of " .. name .. " in Enemy Deck"
            t["Special." .. kw .. ".FieldHasDeploy"] = name .. " on Field"
            -- Special object group variables
            t["Special." .. kw .. ".HandCards"] = name .. " Cards in Hand"
            t["Special." .. kw .. ".EnemyHandCards"] = "Enemy " .. name .. " Cards in Hand"
            t["Special." .. kw .. ".FieldCards"] = name .. " Cards on Field"
            t["Special." .. kw .. ".FriendlyFieldCards"] = "Friendly " .. name .. " Cards on Field"
            t["Special." .. kw .. ".EnemyFieldCards"] = "Enemy " .. name .. " Cards on Field"
        end

        t["Special." .. kw .. ".FieldUnitCount"] = name .. " Units on Field"
        t["Special." .. kw .. ".HasFriendlyUnit"] = "Friendly " .. name .. " Unit Present"
        t["Special." .. kw .. ".FriendlyUnitCount"] = "Friendly " .. name .. " Unit Count"
        t["Special." .. kw .. ".HasEnemyUnit"] = "Enemy " .. name .. " Unit Present"
        t["Special." .. kw .. ".EnemyUnitCount"] = "Enemy " .. name .. " Unit Count"
    end
end

-- 初始化翻译表
InitChineseTranslations()
InitEnglishTranslations()

-- 界面语言变化时同步变量显示名语言
if KARDS.Lang and KARDS.Lang.OnLanguageChanged then
    KARDS.Lang.OnLanguageChanged(function()
        KARDS.VarLib.CurrentLanguage = KARDS.Lang.GetLanguage()
    end)
end

-- 获取变量的显示名称
-- @param varPath string 变量路径，如 "Battle.Turn"
-- @param lang string 语言代码，默认使用当前语言
-- @return string 显示名称（若未翻译则返回原路径）
function KARDS.VarLib.GetDisplayName(varPath, lang)
    lang = lang or KARDS.VarLib.CurrentLanguage
    local translations = KARDS.VarLib.Translations[lang]
    if translations and translations[varPath] then
        return translations[varPath]
    end
    return varPath  -- 未翻译时返回原路径
end

-- ====================================================================
-- 获取所有数字类型变量路径
-- ====================================================================

-- 递归收集表中所有数值类型变量的路径
-- @param tbl table 要遍历的表
-- @param prefix string 当前路径前缀
-- @param result table 收集结果的数组
local function CollectNumericPaths(tbl, prefix, result)
    for k, v in pairs(tbl) do
        if type(k) == "string" and k:sub(1, 1) ~= "_" then
            local path = prefix ~= "" and (prefix .. "." .. k) or k
            if type(v) == "number" then
                table.insert(result, path)
            elseif type(v) == "table" then
                CollectNumericPaths(v, path, result)
            end
        end
    end
end

-- 获取指定牌桌所有数字类型变量的路径列表
-- @param tableID string 牌桌唯一标识符
-- @return table 变量路径字符串数组（按字母排序）
function KARDS.VarLib.GetNumericVarPaths(tableID)
    local T = KARDS.VarLib.GetOrCreate(tableID)  -- 使用 GetOrCreate 确保牌桌存在

    local result = {}
    -- 收集 Special 下的数字变量（以 Special.关键词.字段名 格式）
    if T.Special then
        CollectNumericPaths(T.Special, "Special", result)
    end
    -- 收集 Battle 下的数字变量
    if T.Battle then
        CollectNumericPaths(T.Battle, "Battle", result)
    end
    -- 收集 OffTable 下的数字变量
    if T.OffTable then
        CollectNumericPaths(T.OffTable, "OffTable", result)
    end

    table.sort(result)
    return result
end

-- ====================================================================
-- 获取所有类型变量路径（按类型分组）
-- ====================================================================

-- 判断变量是否为卡牌对象数组（数组内只有卡牌对象，归类为对象组 eg）
local function IsObjectArrayKey(key)
    return key:match("Units$") ~= nil or key:match("Cards$") ~= nil
end

-- 按值类型返回变量类型 id（与 CollectLibVarsByType 的分类规则一致）
-- @param key string 变量键名；value any 变量值
-- @return string 类型 id：n=数字 b=布尔 t=文本 g=数组 eg=对象组
local function GetVarTypeId(key, value)
    local vt = type(value)
    if vt == "number" then return "n" end
    if vt == "boolean" then return "b" end
    if vt == "string" then return "t" end
    if IsObjectArrayKey(key) then return "eg" end
    return "g"
end

-- 收集单个区域的变量路径（跳过 _ 开头内部字段），按类型分组
-- @param section table 区域表（Battle/OffTable 的字段层，或 Special 的关键词子表）
-- @param prefix string 路径前缀（如 "Battle" / "Special.Deploy"）
-- @param result table 分组收集结果
local function CollectSectionPaths(section, prefix, result)
    for k, v in pairs(section) do
        if type(k) == "string" and k:sub(1, 1) ~= "_" then
            local tid = GetVarTypeId(k, v)
            table.insert(result[tid], prefix .. "." .. k)
        end
    end
end

-- 获取指定牌桌全部类型变量的路径列表（按类型分组）
-- @param tableID string 牌桌唯一标识符
-- @return table { n = {...}, b = {...}, t = {...}, g = {...}, eg = {...} } 各分组为变量路径字符串数组（按字母排序）
function KARDS.VarLib.GetVarPathsByType(tableID)
    local T = KARDS.VarLib.GetOrCreate(tableID)
    local result = { n = {}, b = {}, t = {}, g = {}, eg = {} }

    -- Special：展平各关键词子表（字段层）
    if T.Special then
        for _, kw in ipairs(KEYWORDS) do
            if T.Special[kw] then
                CollectSectionPaths(T.Special[kw], "Special." .. kw, result)
            end
        end
    end
    -- Battle / OffTable：直接遍历字段层
    if T.Battle then
        CollectSectionPaths(T.Battle, "Battle", result)
    end
    if T.OffTable then
        CollectSectionPaths(T.OffTable, "OffTable", result)
    end

    for _, list in pairs(result) do
        table.sort(list)
    end
    return result
end

-- ====================================================================
-- 对象/对象组变量收集（ObjectVarPaths）
-- ====================================================================

-- 宏观对象/对象组变量路径白名单（亨舍尔伤害倍率等方案的数据源）
-- key 为 Battle 中的变量路径，值为 true 表示对象组（数组），false 表示单个对象
local BATTLE_OBJECT_PATHS = {
    -- 对象（单个实体引用）
    ["Battle.FriendlyTarget"]      = false,
    ["Battle.EnemyTarget"]         = false,
    ["Battle.FriendlyHeadquarter"] = false,
    ["Battle.EnemyHeadquarter"]    = false,
    -- 对象组（数组）
    ["Battle.FriendlyUnits"]          = true,
    ["Battle.EnemyUnits"]             = true,
    ["Battle.FriendlySupportUnits"]   = true,
    ["Battle.EnemySupportUnits"]      = true,
    ["Battle.FriendlyFrontlineUnits"] = true,
    ["Battle.EnemyFrontlineUnits"]    = true,
    ["Battle.FriendlyGroundUnits"]    = true,
    ["Battle.EnemyGroundUnits"]       = true,
    ["Battle.FriendlyAirUnits"]       = true,
    ["Battle.EnemyAirUnits"]          = true,
    ["Battle.FriendlyInfantry"]       = true,
    ["Battle.EnemyInfantry"]          = true,
    ["Battle.FriendlyTank"]           = true,
    ["Battle.EnemyTank"]              = true,
    ["Battle.FriendlyArtillery"]      = true,
    ["Battle.EnemyArtillery"]         = true,
    ["Battle.FriendlyFighter"]        = true,
    ["Battle.EnemyFighter"]           = true,
    ["Battle.FriendlyBomber"]         = true,
    ["Battle.EnemyBomber"]            = true,
    ["Battle.FriendlyUnitCards"]      = true,
    ["Battle.EnemyUnitCards"]         = true,
    ["Battle.FriendlyCommandCards"]   = true,
    ["Battle.EnemyCommandCards"]      = true,
    ["Battle.FriendlyCounterCards"]   = true,
    ["Battle.EnemyCounterCards"]      = true,
}

-- ====================================================================
-- 开发池对象组变量（card 模板「开发」，readme 7.2.1 开发 = 从特定卡池随机 3 选 1）
-- ====================================================================
-- 组合维度（对齐 problem.md H5 修复方案）：
--   {卡组中、卡组顶、卡组底} × {国籍} × {单位、指令、任意} × {单位类型、任意}
--   + {本国指令、本国精英指令、本国精英单位}（本国 = 该方玩家主国国籍，隐含国籍维度）
-- 路径约定：Battle.DevelopPool.<位置>[.<国籍>.<卡牌类型>[.<单位类型>]]
-- 变量值为对象组（数组）标记（isGroup=true），但运行时卡池由卡组动态筛选
-- （GetDevelopPoolCards），不预存数组，避免数百个空数组污染变量库。
local DEVELOP_POSITIONS = {
    deck   = "卡组中",
    top    = "卡组顶",
    bottom = "卡组底",
}
local DEVELOP_OWN = {
    own_command       = "本国指令",
    own_elite_command = "本国精英指令",
    own_elite_unit    = "本国精英单位",
}
-- 国籍维度（2026-08-16：流亡不作国籍——流亡为部队状态而非国家，
-- 不参与开发池/伤害倍率配置的国籍筛选）
local DEVELOP_COUNTRIES = {
    usa = "美国", germany = "德国", soviet = "苏联", uk = "英国", japan = "日本",
    italy = "意大利", france = "法国", poland = "波兰", any = "任意国籍",
}
local DEVELOP_TYPES = {
    unit = "单位", command = "指令", any = "任意",
}
local DEVELOP_UNIT_TYPES = {
    infantry = "步兵", tank = "坦克", artillery = "火炮", fighter = "战斗机", bomber = "轰炸机", any = "任意",
}

-- 开发池英文维度名（与上方中文表同构；unit 维度留空以拼出
-- 「Deck German Infantry」而非「Deck German Unit Infantry」）
local DEVELOP_POSITIONS_EN = {
    deck = "Deck",
    top = "Top of Deck",
    bottom = "Bottom of Deck",
}
local DEVELOP_OWN_EN = {
    own_command       = "Own Order",
    own_elite_command = "Own Elite Order",
    own_elite_unit    = "Own Elite Unit",
}
local DEVELOP_COUNTRIES_EN = {
    usa = "American", germany = "German", soviet = "Soviet", uk = "British", japan = "Japanese",
    italy = "Italian", france = "French", poland = "Polish", any = "Any",
}
local DEVELOP_TYPES_EN = {
    unit = "", command = "Order", any = "Any",
}
local DEVELOP_UNIT_TYPES_EN = {
    infantry = "Infantry", tank = "Tank", artillery = "Artillery", fighter = "Fighter", bomber = "Bomber", any = "Any",
}

-- 开发池显示名拼接（2026-10-02 用户规格）：去掉「·」分隔与「任意」维度，只保留位置与具体维度
-- 直接相连，如「卡组中德国单位步兵」「卡组中」。「任意国籍」与「任意」两档不写入名称。
-- 英文维度以空格连接（如「Deck German Infantry」），故 sep 由调用方指定。
-- @param sep string 维度连接符（中文为空串，英文为空格）
-- @param ... string 各维度显示名（依次为位置、国籍、卡牌类型、单位类型）
-- @return string 拼接后的显示名
local function PoolDisplayName(sep, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        local seg = select(i, ...)
        if type(seg) == "string" and seg ~= "" and seg ~= "Any" and not seg:find("任意") then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, sep)
end

-- 枚举全部开发池组合路径（含显示名）
-- @param positions table|nil 位置维度名表（省略用中文表）
-- @param countries table|nil 国籍维度名表（省略用中文表）
-- @param types table|nil 卡牌类型维度名表（省略用中文表）
-- @param unitTypes table|nil 单位类型维度名表（省略用中文表）
-- @param own table|nil 本国三档维度名表（省略用中文表）
-- @param sep string|nil 维度连接符（省略为空串）
-- @return table { [path] = displayName, ... }（路径为 Battle.DevelopPool.xxx）
local function BuildDevelopPoolPaths(positions, countries, types, unitTypes, own, sep)
    positions = positions or DEVELOP_POSITIONS
    countries = countries or DEVELOP_COUNTRIES
    types = types or DEVELOP_TYPES
    unitTypes = unitTypes or DEVELOP_UNIT_TYPES
    own = own or DEVELOP_OWN
    sep = sep or ""
    local paths = {}
    -- 卡组中/卡组顶/卡组底 × 国籍 × 卡牌类型 × 单位类型（仅单位维度有单位类型）
    for posKey, posCN in pairs(positions) do
        for countryKey, countryCN in pairs(countries) do
            for typeKey, typeCN in pairs(types) do
                if typeKey == "unit" then
                    for utKey, utCN in pairs(unitTypes) do
                        paths["Battle.DevelopPool." .. posKey .. "." .. countryKey .. ".unit." .. utKey]
                            = PoolDisplayName(sep, posCN, countryCN, typeCN, utCN)
                    end
                else
                    paths["Battle.DevelopPool." .. posKey .. "." .. countryKey .. "." .. typeKey]
                        = PoolDisplayName(sep, posCN, countryCN, typeCN)
                end
            end
        end
    end
    -- 本国指令 / 本国精英指令 / 本国精英单位（本国 = 该方玩家主国国籍）
    for ownKey, ownCN in pairs(own) do
        paths["Battle.DevelopPool." .. ownKey] = ownCN
    end
    return paths
end

-- 解析开发池路径 → 组合定义
-- @param path string 开发池路径（Battle.DevelopPool.<位置>[.<国籍>.<类型>[.<单位类型>]]）
-- @return table|nil { position, country, cardType, unitType }（本国* 的 country = "own"）
function KARDS.VarLib.ParseDevelopPoolPath(path)
    local segs = {}
    for seg in string.gmatch(path or "", "[^.]+") do table.insert(segs, seg) end
    if #segs < 3 or segs[1] ~= "Battle" or segs[2] ~= "DevelopPool" then return nil end
    local position = segs[3]
    if DEVELOP_OWN[position] then
        return { position = position, country = "own" }
    end
    if not DEVELOP_POSITIONS[position] then return nil end
    local def = { position = position, country = segs[4], cardType = segs[5], unitType = segs[6] }
    if not DEVELOP_COUNTRIES[def.country] then def.country = "any" end
    if not DEVELOP_TYPES[def.cardType] then def.cardType = "any" end
    if not DEVELOP_UNIT_TYPES[def.unitType] then def.unitType = "any" end
    return def
end

-- 按开发池组合定义筛选玩家卡池（readme 7.2.1 开发 = 从特定卡池随机 3 选 1）
-- 本国* 位置：country 取该玩家主国国籍（Battle.FriendlyMainCountry / EnemyMainCountry），
-- 并按位置固定卡牌类型（本国指令 → command；本国精英指令 → command+elite；本国精英单位 → unit+elite）
-- 位置维度（2026-10-02 补上筛选）：先按国籍、卡牌类型、单位类型、精英筛完整副卡组得到对象组，
-- 再在对象组里取端头。卡组中 = 筛选结果整组；卡组顶 = 筛选结果里最靠卡组顶的那一张；
-- 卡组底 = 筛选结果里最靠卡组底的那一张。位置是相对「筛选后的对象组」而非绝对卡组
-- （用户规格）：卡组顶·德国·单位·步兵 取的是卡组里所有德国步兵中最靠顶的那张，
-- 而不是「卡组顶那一张恰好是德国步兵」。牌组约定与 Deck 一致（末项为顶，抽牌 / Peek 取末项；
-- 首项为底）。本国* 三档不按位置收窄，仍用整个卡组的筛选结果。
-- @param tableID string 牌桌唯一标识符
-- @param player  string 玩家标识
-- @param def     table 组合定义（ParseDevelopPoolPath 结果）
-- @return table 匹配卡牌数组（不取走，卡组不变）
function KARDS.VarLib.GetDevelopPoolCards(tableID, player, def)
    if not def then return {} end
    local T = KARDS.VarLib.Get(tableID)
    local deck = KARDS.Deck and KARDS.Deck:GetDeck(tableID, player) or {}
    local country = def.country
    local cardType = def.cardType
    local unitType = def.unitType
    local elite = nil
    if def.country == "own" then
        -- 本国：取该玩家主国国籍；玩家 P1（先手）→ FriendlyMainCountry，其余 → EnemyMainCountry
        local players = KARDS.Battle and KARDS.Battle.Players or {}
        local isFriendly = players[1] == player
        country = T and T.Battle and (isFriendly and T.Battle.FriendlyMainCountry or T.Battle.EnemyMainCountry)
        if def.position == "own_command" then
            cardType = "command"
        elseif def.position == "own_elite_command" then
            cardType, elite = "command", true
        elseif def.position == "own_elite_unit" then
            cardType, elite = "unit", true
        end
    end
    local pool = {}
    for _, c in ipairs(deck) do
        if (not country or country == "any" or c:GetCountry() == country)
            and (not cardType or cardType == "any" or c:GetType() == cardType)
            and (not unitType or unitType == "any" or c:GetUnitType() == unitType)
            and (not elite or c:GetQuality() == "elite") then
            table.insert(pool, c)
        end
    end
    -- 位置取端头（相对筛选后的对象组，2026-10-02 用户规格）：卡组顶 = 对象组里最靠卡组顶的
    -- 那一张（数组末项），卡组底 = 最靠卡组底的那一张（首项）；对象组为空则返回空表，
    -- 卡组中与本国* 三档返回整组
    if def.position == "top" then
        return pool[#pool] and { pool[#pool] } or {}
    elseif def.position == "bottom" then
        return pool[1] and { pool[1] } or {}
    end
    return pool
end

-- 开发池对象组变量翻译（card 模板「开发」，H5 修复：位置 × 国籍 × 类型 × 单位类型的所有组合）
-- 显示名如「卡组中德国单位步兵」「卡组中」（2026-10-02 起去掉「·」分隔与「任意」维度）；
-- 「本国精英指令」等本国三档不变；与 Battle.DevelopPool.* 路径一一对应，
-- 供 {$} 卡牌对象选择器列出与运行时 BuildDisplayIndex 反查路径。
for path, display in pairs(BuildDevelopPoolPaths()) do
    KARDS.VarLib.Translations["zh-CN"][path] = display
end
-- 开发池对象组变量英文显示名（路径与中文表一一对应，维度以空格连接）
for path, display in pairs(BuildDevelopPoolPaths(
    DEVELOP_POSITIONS_EN, DEVELOP_COUNTRIES_EN, DEVELOP_TYPES_EN,
    DEVELOP_UNIT_TYPES_EN, DEVELOP_OWN_EN, " ")) do
    KARDS.VarLib.Translations["en"][path] = display
end

-- 对象/对象组变量收集结果存储（按牌桌隔离）
-- KARDS.VarLib.ObjectVarPaths[tableID] = { { path = "Battle.X", isGroup = bool }, ... }（按路径字母排序）
KARDS.VarLib.ObjectVarPaths = KARDS.VarLib.ObjectVarPaths or {}

-- 重新构建指定牌桌的对象/对象组变量路径列表
-- 收集 Battle/Special 中所有对象类型（单实体引用）与对象组类型（数组）变量：
--   1. 白名单 BATTLE_OBJECT_PATHS 中的宏观变量
--   2. 运行时动态注册的对象/对象组（table 值，非数字/布尔/文本；数组归为对象组）
-- @param tableID string 牌桌唯一标识符
-- @return table 构建结果 [{path, isGroup}]（按路径字母排序）
function KARDS.VarLib.RebuildObjectVarPaths(tableID)
    local T = KARDS.VarLib.Get(tableID)
    local result = {}

    -- 1. 白名单中的宏观对象/对象组变量（直接遍历白名单：
    --    总部/目标等键默认值为 nil，在 Lua 中不产生表键，pairs(T.Battle) 遍历不到，
    --    若仅靠运行时键匹配则编辑器模板库（总部未填充）将永远看不到总部）
    for path, isGroup in pairs(BATTLE_OBJECT_PATHS) do
        table.insert(result, { path = path, isGroup = isGroup })
    end

    if T and T.Battle then
        -- 2. 动态注册的对象/对象组（table 值，非数字/布尔/文本；数组归为对象组，
        --    跳过白名单已列路径避免重复）
        for k, v in pairs(T.Battle) do
            if type(k) == "string" and k:sub(1, 1) ~= "_" then
                local path = "Battle." .. k
                if BATTLE_OBJECT_PATHS[path] == nil then
                    if type(v) == "table" then
                        -- 动态注册的对象/对象组：数组归为对象组，非数组且含 isUnit 标记归为对象
                        local isArray = #v > 0 or next(v) == nil
                        if not isArray then
                            isArray = false
                            for _, item in pairs(v) do
                                if type(item) == "table" then isArray = true break end
                            end
                        end
                        local isUnitObject = type(v) == "table" and v.isUnit == true
                        if isArray and not isUnitObject then
                            table.insert(result, { path = path, isGroup = true })
                        elseif isUnitObject then
                            table.insert(result, { path = path, isGroup = false })
                        end
                    end
                end
            end
        end
    end

    table.sort(result, function(a, b) return a.path < b.path end)
    -- 开发池对象组变量（card 模板「开发」卡池，isGroup=true；组合路径全部列出供 {$} 选择器选用）
    for path in pairs(BuildDevelopPoolPaths()) do
        table.insert(result, { path = path, isGroup = true })
    end
    table.sort(result, function(a, b) return a.path < b.path end)
    KARDS.VarLib.ObjectVarPaths[tableID] = result
    return result
end

-- 获取指定牌桌的对象/对象组变量路径列表（若未构建则自动重建）
-- @param tableID string 牌桌唯一标识符
-- @return table [{path, isGroup}]
function KARDS.VarLib.GetObjectVarPaths(tableID)
    if not KARDS.VarLib.ObjectVarPaths[tableID] then
        KARDS.VarLib.RebuildObjectVarPaths(tableID)
    end
    return KARDS.VarLib.ObjectVarPaths[tableID] or {}
end

-- ====================================================================
-- 初始化打印
-- ====================================================================

-- 记录变量库加载状态
local varCount = #KEYWORDS * 19  -- 每个关键词约 19 个变量
print("[KARDS VarLib] 全局变量库已加载，关键词数: " .. #KEYWORDS .. "，总变量数约: " .. varCount)
