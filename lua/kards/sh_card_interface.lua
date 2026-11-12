--[[
    卡牌句柄接口约定 (Card Interface)

    时间刻 / 战斗系统只依赖本接口操作卡牌，不依赖具体卡牌实现。
    当前提供 MockCard 占位实现供测试骨架使用；
    未来真实卡牌系统（牌桌/卡组/手牌）就绪后，实现相同方法即可替换
    MockCard —— 时间刻 / 钩子 / 测试脚本零改动迁移（依赖倒置）。

    卡牌规模音效（CardSounds：DeployMap/GetDeploySound/GetAttackSound 等）
    已拆分为独立模块 sh_card_sounds.lua（re.md 阶段二 B4）。

    接口方法（MockCard 已实现，真实卡牌需按此约定实现）：
      :GetID()             卡牌唯一标识
      :GetType()           卡牌类型："unit" / "command" / "counter_command" / "headquarter"
      :GetUnitType()       单位类型（readme 7.3）："fighter" / "tank" / "bomber" /
                           "infantry" / "artillery"；非单位卡恒为 nil
      :GetOwner()          归属玩家标识
      :SetOwner(owner)     转移归属（控制/召唤等效果用；返回新归属）
      :GetName()           显示名（Mock 回退为 ID；克隆卡回退源卡标识 _faceName）
      :GetStat(stat)       属性值（stat ∈ "attack" / "defense"）
      :GetCost()           卡牌花费（指挥点，打出/部署消耗，readme 7.1 操作；所有卡牌类型均有，缺省 0）
      :GetActionCost()     行动花费（指挥点，单位移动/攻击消耗，readme 7.1 操作）；
                           仅单位卡有，非单位卡（总部/指令/反制）恒为 nil
      :GetKeywords()       词条数组（readme 7.2.2 战斗词条能力 / 7.2.3 特别战斗词条 / 7.1 明牌）；
                           带数值词条（情报/倒计时/重甲）项为 { 词条id, 数值 }，其余为单独词条 id
      :HasKeyword(id)      是否具有指定词条
      :ApplyChange(stat, modifier, amount)
                           应用数值变更，返回新值
                           modifier ∈ "increase"（增加）/ "decrease"（减少）/ "set"（设为）
      :SetObserver(fn)    注入可插拔观察者（re.md B-M2）：数值变更后回调
                           fn(card, stat, modifier, amount, newValue)；
                           Mock 场景注入测试记录器，真实卡牌注入 NW 同步器等；
                           传 nil 移除观察者
      :IsAlive()           是否存活（防御 > 0）
      :AddCombatMultiplier(kind, path, multiplier, name?)
                           添加伤害/受伤害倍率规则
                           kind ∈ "outgoing"（伤害倍率）/ "incoming"（受伤害倍率）；
                           仅单位卡可配置（非单位卡两个数组恒空）；
                           倍率为 1 的规则不入数组（等价无规则，readme 无加成）；
                           同路径规则覆盖更新（覆盖为 1 时移除该条）；返回是否成功
      :GetCombatMultiplier(kind, path)
                           查询对目标（outgoing）或来源（incoming）的倍率；
                           未匹配返回 1（默认倍率，伤害计算解析用）
      :GetCombatModifiers() 倍率数组结构（与卡牌外貌属性编辑器的 combatModifiers 一致）
]]

KARDS = KARDS or {}
---@class CardInterface 卡牌句柄接口约定
KARDS.CardInterface = KARDS.CardInterface or {}

-- 合法属性名
KARDS.CardInterface.Stats = { attack = true, defense = true }

-- 战斗倍率类型（与卡牌外貌属性编辑器的 combatModifiers 一致）：
-- outgoing = 伤害倍率（该卡牌攻击匹配 targetPath 的目标时造成 ×N 伤害）
-- incoming = 受伤害倍率（该卡牌受到匹配 sourcePath 的来源伤害时 ×N）
KARDS.CardInterface.CombatKinds = { outgoing = true, incoming = true }

-- 单位类型白名单（readme 7.3 单位类型规则）
-- 战斗机 fighter：可攻击任意阵线目标，可拦截轰炸机；无法具有烟幕（readme 7.3，创建时校验剔除 smoke）
-- 坦克 tank：同一回合可移动并攻击
-- 轰炸机 bomber：攻击非战斗机目标不受反击；被攻击时不造成反击；可攻击被守护单位
-- 步兵 infantry：只能攻击相邻战线的敌人
-- 炮兵 artillery：攻击时不会受到反击伤害；可攻击被守护单位
KARDS.CardInterface.UnitTypes = {
    fighter = true,
    tank = true,
    bomber = true,
    infantry = true,
    artillery = true,
}

-- 品质白名单（与卡牌外貌属性编辑器的品质选项一致，cl_ca_appearance_editors.lua）
KARDS.CardInterface.Qualities = {
    normal = true,  -- 普通
    limited = true, -- 受限
    special = true, -- 特殊
    elite = true,   -- 精英（「本国精英指令/本国精英单位」筛选用）
}

-- 词条白名单（readme 7.2.2 战斗词条能力 / 7.2.3 特别战斗词条 / 7.1 明牌 / 7.2.1 效果能力）
-- 带数值的词条（情报 X / 倒计时 X / 重甲 X）在词条数组中为 { 词条id, 数值 }，
-- 其余词条为单独 id 字符串。
-- 亡计 deathrattle / 倒计时 countdown：战斗系统仅标记词条，具体触发效果由节点编辑器配置。
KARDS.CardInterface.Keywords = {
    -- 7.2.2 战斗词条能力
    intel = true,       -- 情报 X（带数值）：情报触发时能显示敌方 X 张手牌，最多 9
    mobilize = true,    -- 动员：每回合开始时获得 +1+1，受到伤害后失去
    frenzy = true,      -- 奋战：一回合中可以攻击两次
    guard = true,       -- 守护：与守护单位相邻的非守护单位无法被轰炸机和炮兵以外的单位攻击
    mountain = true,    -- 山地：部署或加入战场时，每有一个其他友方山地单位，获得一次 +1+1
    deathrattle = true, -- 亡计：效果会在单位被消灭时触发（效果由节点编辑器配置）
    ambush = true,      -- 伏击：每回合首次被攻击时会首先造成反击伤害
    countdown = true,   -- 倒计时 X（带数值）：倒计时结束后触发一个事件，每回合 -1（效果由节点编辑器配置）
    shock = true,       -- 冲击：首次攻击时被攻击单位不会造成任何反击伤害，攻击单位后移除
    armor = true,       -- 重甲 X（带数值）：交战时受到的伤害减少 X，最多 3
    pincer = true,      -- 钳击：部署时可以选择另一个友方单位作为钳击同伴
    blitz = true,       -- 闪击：可以在进入战场的回合行动（移动/攻击）
    stealth = true,     -- 隐蔽：入场时背面朝上，揭示前不受效果影响且行动花费为 1
    smoke = true,       -- 烟幕：无法被敌方单位攻击，移动或攻击后失去
    unity = true,       -- 协力：效果触发时除非场上有相同国家的单位，否则总部将受到士气伤害
    -- 7.2.3 特别战斗词条
    exile = true,       -- 流亡：可投入包含本国或流亡国的卡组（构筑规则，战斗系统仅标记）
    -- 7.1 明牌
    overwatch = true,   -- 明牌：仅卡牌在手中时可具有效果，敌方可浏览
    -- 注：「抉择」（readme 7.1 综合规则）不是战斗词条（7.2.2/7.2.3），不登记于此白名单；
    -- 其效果由节点编辑器 choice 节点承担，卡面「抉择：T1 或 T2」文本由描述区手写，
    -- 加粗高亮由 KeywordsForHighlight 自动处理（2026-10-04 用户口径）
    -- 7.2.1 效果能力（老兵 / 被守护 / 免疫）
    veteran = true,     -- 老兵：进阶状态，触发条件由单卡定义
    can_elevate_to_veteran = true, -- 可升为老兵：标记卡牌可升级为老兵版本（升级条件由效果文本定义）
    guarded = true,     -- 被守护：只能被轰炸机和炮兵攻击（readme 7.2.1；拦截：战斗机有被守护则完全封锁该阵线，readme 7.3）
    immune = true,      -- 免疫：单位或总部具有免疫时不会受到伤害（readme 7.2.1）
    -- 收缴（readme 7.2.2）：授予瞬间触发收缴；带此词条的单位攻击并击杀目标时收缴目标
    confiscate = true,
    -- 被收缴（readme 7.2.1）：授予瞬间触发收缴；仅作触发标记，不留存常驻状态
    confiscated = true,
}

-- 次词条（隐藏词条，2026-10-04）：不在卡面与战场 3D2D 显示、不建立词条状态，
-- 仅作内部标记，供条件「关键字检查」与动作读写（如亡计「使其算作海军」）。
-- id 与战斗词条同构（HasKeyword/GetKeywords 可直接命中）。
KARDS.CardInterface.HiddenKeywords = {
    navy = true, -- 海军：算作海军（隐藏词条，不显示在卡面）
}

-- 是否为隐藏词条（次词条）：显示与状态建立处应据此跳过
-- @param id string 词条 id
-- @return boolean
function KARDS.CardInterface.IsHiddenKeyword(id)
    return KARDS.CardInterface.HiddenKeywords[id] == true
end

-- 编辑器词条 key → 战斗系统词条 id 翻译映射（2026-08-11）：
-- 卡牌外貌属性编辑器保存的词条 key（sh_card_data.lua）与战斗系统白名单 id 不一致
-- （亡计 death_plan vs deathrattle / 奋战 fight_hard vs frenzy / 冲击 impact vs shock /
--  重甲 heavy_armor vs armor / 隐蔽 conceal vs stealth / 协力 cooperation vs unity），
-- 卡组加载（table_battledeck.lua DeckCardHandleFromFile）直接透传编辑器 key 到
-- CreateMockCard 校验，未翻译即被误判为非法词条剔除——亡计被剔除后其节点效果
-- （SimTriggerKeyword "deathrattle" 刻）无法触发。统一翻译为战斗系统规范 id。
KARDS.CardInterface.EditorKeywordToBattle = {
    death_plan  = "deathrattle", -- 亡计
    fight_hard  = "frenzy",      -- 奋战
    impact      = "shock",       -- 冲击
    heavy_armor = "armor",       -- 重甲
    conceal     = "stealth",     -- 隐蔽
    cooperation = "unity",       -- 协力
}

-- Mock 卡牌方法表（re.md 阶段二 B4：CreateMockCard 的闭包方法收敛为共享方法表，
-- card 经 setmetatable 挂接本表；真实卡牌系统就绪后按 CardInterface 接口约定
-- 实现相同方法替换 MockCard）
KARDS.MockCardMethods = {}

function KARDS.MockCardMethods:GetID()
    return self._id
end

function KARDS.MockCardMethods:GetType()
    return self._type
end

-- 单位类型（readme 7.3）；非单位卡（总部/指令/反制）恒为 nil
function KARDS.MockCardMethods:GetUnitType()
    return self._stats.unitType
end

-- 国籍（readme 国籍/国家）；未配置为 nil
function KARDS.MockCardMethods:GetCountry()
    return self._country
end

-- 品质（编辑器外观属性 quality）：normal/limited/special/elite；缺省 "normal"
function KARDS.MockCardMethods:GetQuality()
    return self._quality
end

-- 事件音效路径表（编辑器属性页音效选择器保存；键见 sh_battle_combat.lua
-- NotifyEventSound：deploy/attack/death/play/activate/trigger，未配置槽位恒缺省）
function KARDS.MockCardMethods:GetSounds()
    return self._sounds
end

-- 规模（卡牌外貌属性编辑器「规模」：small 少量 / medium 中量 / large 巨大；缺省 "small"）
-- 放置在场音效（放牌）与部署音效按规模分配（见 KARDS.CardSounds.GetPlaceSound / GetDeploySound）
function KARDS.MockCardMethods:GetCardScale()
    return self._cardScale
end

-- 是否可升为老兵（编辑器词条 can_elevate_to_veteran；升级后词条被替换为老兵词条，随即失效）
function KARDS.MockCardMethods:CanElevateToVeteran()
    return self:HasKeyword("can_elevate_to_veteran")
end

-- 老兵外观数据（升级时套用：费用/攻防/行动花费/词条/品质等，结构同编辑器 veteranAppearance）
function KARDS.MockCardMethods:GetVeteranAppearance()
    return self._veteranAppearance
end

-- 转换目标卡文件名（2026-09-26 缺口 J）：本卡被转换效果作用后变成哪张卡；
-- 空/nil 表示不换卡（维持既有「仅记录 convert 刻」语义）
function KARDS.MockCardMethods:GetConvertTarget()
    return self._convertTarget
end

-- 是否已是老兵状态（防止重复升级）
function KARDS.MockCardMethods:IsVeteran()
    return self._isVeteran
end

-- 标记为老兵（SimVeteran 套用外观后调用）
function KARDS.MockCardMethods:SetVeteran()
    self._isVeteran = true
end

-- 转移归属（控制/召唤等效果用，readme 7.1 控制规则；返回新归属）
function KARDS.MockCardMethods:SetOwner(owner)
    if owner ~= nil then self._owner = owner end
    return self._owner
end

-- 设置国籍（收缴：被收缴体国籍改为收缴方主国，2026-10-15 用户规格；返回新国籍）
function KARDS.MockCardMethods:SetCountry(country)
    self._country = country
    return self._country
end

-- 更换单位类型（转换效果用，readme 7.3）；非单位卡拒绝，非法类型拒绝并返回 nil
function KARDS.MockCardMethods:SetUnitType(unitType)
    if self._type ~= "unit" then return nil end
    if unitType ~= nil and not KARDS.CardInterface.UnitTypes[unitType] then
        print("[MockCard] 错误: 非法单位类型: " .. tostring(unitType) .. "（readme 7.3：fighter/tank/bomber/infantry/artillery）")
        return nil
    end
    self._stats.unitType = unitType
    return unitType
end

function KARDS.MockCardMethods:GetOwner()
    return self._owner
end

function KARDS.MockCardMethods:GetName()
    -- 克隆卡（节点「复制」）：ID 带 _copy 后缀以隔离实例（卡牌全局变量按 ID 分桶、
    -- 对象比较按 ID 判等），卡面标识则须沿用源卡（_faceName，见 sh_node_acts_field.lua
    -- CloneCard）——卡面外观 / 3D2D 文字 / 效果链（指向）均按显示名查卡牌信息。
    return self._faceName or self._id
end

-- 英文卡牌名（卡面文本英文化，2026-10-17）：未配置时返回空字符串（调用方回退 GetName）
function KARDS.MockCardMethods:GetNameEn()
    return self._nameEn or ""
end

-- 卡牌效果描述（卡面文本；未配置时返回空字符串）
function KARDS.MockCardMethods:GetDescription()
    return self._description or ""
end

-- 英文效果描述（未配置时返回空字符串，调用方回退 GetDescription）
function KARDS.MockCardMethods:GetDescriptionEn()
    return self._descriptionEn or ""
end

function KARDS.MockCardMethods:GetStat(stat)
    local v = self._stats[stat] or 0
    -- 属性修饰钩子（OnModifyStat）：读取属性时应用 register_hook 注册的攻击力/防御力修饰
    if KARDS.EngineHooks and KARDS.EngineHooks.OnStatRead then
        v = KARDS.EngineHooks.OnStatRead(self, stat, v)
    end
    return v
end

-- 卡牌花费（指挥点，打出/部署消耗，readme 7.1 操作）
function KARDS.MockCardMethods:GetCost()
    return self._cost
end

-- 行动花费（指挥点，单位移动/攻击消耗）；非单位卡（总部/指令/反制）恒为 nil
function KARDS.MockCardMethods:GetActionCost()
    return self._actionCost
end

-- 词条数组（readme 7.2.2 战斗词条能力 / 7.2.3 特别战斗词条 / 7.1 明牌）
-- 带数值词条（情报/倒计时/重甲）项为 { 词条id, 数值 }，其余为单独词条 id
function KARDS.MockCardMethods:GetKeywords()
    return self._keywords
end

-- 是否具有指定词条（词条项为 { id, x } 数组时取其 [1] 作 id）
function KARDS.MockCardMethods:HasKeyword(id)
    for _, kw in ipairs(self._keywords) do
        if (type(kw) == "table" and kw[1] or kw) == id then
            return true
        end
    end
    return false
end

function KARDS.MockCardMethods:ApplyChange(stat, modifier, amount)
    if not KARDS.CardInterface.Stats[stat] then
        print("[MockCard] 错误: 非法属性名: " .. tostring(stat))
        return self._stats[stat] or 0
    end
    local cur = self._stats[stat] or 0
    if modifier == "increase" then
        self._stats[stat] = cur + amount
    elseif modifier == "decrease" then
        self._stats[stat] = cur - amount
    elseif modifier == "set" then
        self._stats[stat] = amount
    else
        print("[MockCard] 错误: 非法修饰符: " .. tostring(modifier) .. "（应为 increase / decrease / set）")
        return cur
    end
    -- kards 数值上限（2026-08-13）：所有数值最大 99，不防负值（允许负属性，
    -- 如防御被扣成负数即不存活；编辑器输入约定 0~99 不在此层）。
    self._stats[stat] = math.min(99, self._stats[stat])
    -- 变更记录剥离为可插拔观察者（re.md B-M2）：测试断言记录 / 真实卡牌 NW 同步
    -- 均由调用方经 SetObserver 注入，卡牌接口本身不再承载测试职责
    if self._observer then
        self._observer(self, stat, modifier, amount, self._stats[stat])
    end
    return self._stats[stat]
end

-- 注入/移除可插拔观察者（re.md B-M2）：数值变更后回调 fn(card, stat, modifier, amount, newValue)
function KARDS.MockCardMethods:SetObserver(fn)
    self._observer = fn
end

function KARDS.MockCardMethods:IsAlive()
    return (self._stats.defense or 0) > 0
end

--[[
    添加伤害/受伤害倍率规则（与卡牌外貌属性编辑器的 combatModifiers 一致）

    @param kind       string "outgoing"（伤害倍率）/ "incoming"（受伤害倍率）
    @param path       string 目标（outgoing）/ 来源（incoming）的 Varlib 路径，如 "Battle.EnemyGroundUnits"
    @param multiplier number 倍率（必须 > 0）
    @param name       string|nil 目标/来源显示名（缺省用 path）
    @return boolean 是否成功；倍率为 1 时视为无规则（不入数组，覆盖时移除同路径条目）
]]
function KARDS.MockCardMethods:AddCombatMultiplier(kind, path, multiplier, name)
    -- 仅单位卡可配置倍率（非单位卡两个数组恒空）
    if self._type ~= "unit" then
        print("[MockCard] 错误: 非单位卡不能配置伤害/受伤害倍率（两个数组恒空）")
        return false
    end
    if not KARDS.CardInterface.CombatKinds[kind] then
        print("[MockCard] 错误: 非法倍率类型: " .. tostring(kind) .. "（应为 outgoing / incoming）")
        return false
    end
    if type(path) ~= "string" or path == "" then
        print("[MockCard] 错误: 倍率规则缺少目标/来源路径")
        return false
    end
    if type(multiplier) ~= "number" or multiplier <= 0 then
        print("[MockCard] 错误: 非法倍率: " .. tostring(multiplier) .. "（应 > 0）")
        return false
    end
    local list = self._combat[kind]
    local isOutgoing = kind == "outgoing"
    -- 规范化：倍率为 1 不入数组（等价无规则）——移除已存在的同路径条目后视为完成
    if multiplier == 1 then
        for i = #list, 1, -1 do
            local rule = list[i]
            if (isOutgoing and rule.targetPath or rule.sourcePath) == path then
                table.remove(list, i)
            end
        end
        return true
    end
    -- 同路径规则覆盖更新（条目结构随类型：outgoing 用 targetPath/targetName，incoming 用 sourcePath/sourceName）
    for _, rule in ipairs(list) do
        if (isOutgoing and rule.targetPath or rule.sourcePath) == path then
            rule.multiplier = multiplier
            return true
        end
    end
    local entry = isOutgoing
        and { targetPath = path, multiplier = multiplier, targetName = name or path }
        or  { sourcePath = path, multiplier = multiplier, sourceName = name or path }
    table.insert(list, entry)
    return true
end

--[[
    查询伤害/受伤害倍率（伤害计算解析用）

    遍历匹配 path 的规则返回其倍率；未匹配返回 1（默认倍率——
    伤害计算解析时发现不存在则默认 1 倍率，与倍率 1 不入数组的规范一致）。

    @param kind string "outgoing" / "incoming"
    @param path string 目标（outgoing）/ 来源（incoming）的 Varlib 路径
    @return number 倍率（未匹配默认 1）
]]
function KARDS.MockCardMethods:GetCombatMultiplier(kind, path)
    if not KARDS.CardInterface.CombatKinds[kind] then
        print("[MockCard] 错误: 非法倍率类型: " .. tostring(kind) .. "（应为 outgoing / incoming）")
        return 1
    end
    local isOutgoing = kind == "outgoing"
    for _, rule in ipairs(self._combat[kind]) do
        if (isOutgoing and rule.targetPath or rule.sourcePath) == path then
            return rule.multiplier
        end
    end
    return 1 -- 默认倍率
end

-- 倍率数组结构（与卡牌外貌属性编辑器的 combatModifiers 一致，调用方可读取）
function KARDS.MockCardMethods:GetCombatModifiers()
    return self._combat
end

--[[
    创建 Mock 卡牌（测试占位实现）

    @param id       string 卡牌唯一标识
    @param cardType string 卡牌类型（"unit" / "command" / "counter_command" / "headquarter"）
    @param owner    string 归属玩家标识
    @param stats    table|nil 初始属性 { attack = 数值, defense = 数值, cost = 卡牌花费?, actionCost = 行动花费?, unitType = 单位类型?, keywords = 词条数组?, combatModifiers = 倍率数组?, country = 国籍?, quality = 品质?, name = 卡牌名?, nameEn = 英文卡牌名?, description = 效果描述?, descriptionEn = 英文效果描述? }
                    unitType 仅在 cardType = "unit" 时有效（readme 7.3），
                    非单位卡（总部/指令/反制）强制为 nil；
                    actionCost 同样仅单位卡可有，非单位卡恒为 nil（readme 7.1 操作）；
                    keywords 为词条数组（readme 7.2.2/7.2.3/7.1）：带数值词条项为 { 词条id, 数值 }，
                    其余为单独词条 id 字符串；非法词条被剔除；
                    combatModifiers 为倍率数组（与卡牌外貌属性编辑器的 combatModifiers 一致）：
                    { outgoing = { { targetPath, multiplier, targetName? } },
                      incoming = { { sourcePath, multiplier, sourceName? } } }；
                    仅单位卡接收，非单位卡两数组恒空；倍率为 1 的条目被丢弃（规范化）；
                    country 为国籍 id（readme 国籍/国家，缺省 nil）；quality 为品质
                    （缺省 "normal"，非法品质剔除）
    @return table Mock 卡牌句柄
]]
function KARDS.CardInterface.CreateMockCard(id, cardType, owner, stats)
    cardType = cardType or "unit"
    -- 国籍：缺省 nil（未配置国籍的卡牌不参与「不同国籍单位数」统计）
    local country = stats and stats.country
    -- 品质：缺省 "normal"；非法品质剔除（置 "normal"）
    local quality = (stats and stats.quality) or "normal"
    if not KARDS.CardInterface.Qualities[quality] then
        print("[MockCard] 错误: 非法品质: " .. tostring(quality) .. "（normal/limited/special/elite），已回退 normal")
        quality = "normal"
    end
    -- 单位类型：仅单位卡可有；非法单位类型拒绝（置 nil）
    local unitType = nil
    if cardType == "unit" then
        unitType = stats and stats.unitType
        if unitType ~= nil and not KARDS.CardInterface.UnitTypes[unitType] then
            print("[MockCard] 错误: 非法单位类型: " .. tostring(unitType) .. "（readme 7.3：fighter/tank/bomber/infantry/artillery）")
            unitType = nil
        end
    end
    -- 词条（readme 7.2.2/7.2.3/7.1）：数组；带数值词条项为 { 词条id, 数值 }，其余为 id 字符串；非法词条剔除
    -- 战斗机无法具有烟幕（readme 7.3 单位类型规则），创建时校验剔除 smoke
    local keywords = {}
    if stats and stats.keywords then
        for _, kw in ipairs(stats.keywords) do
            local kwId = type(kw) == "table" and kw[1] or kw
            -- 编辑器词条 key → 战斗系统词条 id（见 EditorKeywordToBattle 映射说明，
            -- 卡组加载透传编辑器保存的 key，翻译后战斗机制按战斗 id 命中）
            kwId = KARDS.CardInterface.EditorKeywordToBattle[kwId] or kwId
            if unitType == "fighter" and kwId == "smoke" then
                print("[MockCard] 错误: 战斗机无法具有烟幕（readme 7.3），已剔除")
            elseif not KARDS.CardInterface.Keywords[kwId] and not KARDS.CardInterface.IsHiddenKeyword(kwId) then
                print("[MockCard] 错误: 非法词条: " .. tostring(kwId) .. "（已剔除）")
            else
                table.insert(keywords, type(kw) == "table" and { kwId, kw[2] } or kwId)
            end
        end
    end
    local card = {
        _id = id,
        _name = (stats and stats.name) or nil,           -- 卡牌名（编辑器保存的 name）
        _nameEn = (stats and stats.nameEn) or nil,       -- 英文卡牌名（nameEn）
        _description = (stats and stats.description) or nil,     -- 效果描述（specialEffect）
        _descriptionEn = (stats and stats.descriptionEn) or nil, -- 英文效果描述（specialEffectEn）
        _type = cardType,
        _owner = owner or "P1",
        -- 国籍 / 品质（readme 国籍/国家 与 编辑器外观属性 quality）；
        -- GetCountry/GetQuality 读取，H3「不同国籍单位数」与 H5「本国精英」筛选依赖
        _country = country,
        _quality = quality,
        _stats = {
            attack = (stats and stats.attack) or 0,
            defense = (stats and stats.defense) or 0,
            unitType = unitType, -- 非单位卡恒为 nil
        },
        _cost = (stats and stats.cost) or 0,                    -- 卡牌花费（指挥点；所有卡牌类型均有）
        _actionCost = (cardType == "unit") and ((stats and stats.actionCost) or 0) or nil, -- 行动花费仅单位
        _keywords = keywords, -- 词条数组（带数值词条为 { id, x }，其余为 id 字符串）
        -- 老兵（readme 7.2.1）：编辑器词条 can_elevate_to_veteran 标记「可升为老兵」，
        -- 升级条件由效果文本（节点效果）定义，升为老兵时套用 veteranAppearance 重置属性；
        -- 可升为老兵判定直接查词条（见 CanElevateToVeteran）
        _veteranAppearance = (stats and stats.veteranAppearance) or nil, -- 老兵外观数据（升级时套用）
        _isVeteran = false, -- 是否已是老兵状态（防止重复升级）
        -- 转换目标卡（2026-09-26 缺口 J）：编辑器「转换目标卡」字段（卡文件名），
        -- 非空时转换效果会把本卡整体置换为该卡（见 sh_battle_unit.lua SimConvert）
        _convertTarget = (stats and stats.convertTarget) or nil,
        -- 伤害/受伤害倍率数组（与卡牌外貌属性编辑器的 combatModifiers 一致）：
        -- outgoing = { { targetPath, multiplier, targetName } }（该卡牌攻击匹配目标 ×N 伤害）
        -- incoming = { { sourcePath, multiplier, sourceName } }（受到匹配来源伤害 ×N）
        -- 规范：倍率为 1 的规则不入数组（一般伤害/受伤为 1 倍率）；非单位卡两数组恒空
        _combat = { outgoing = {}, incoming = {} },
        -- 可插拔观察者（re.md B-M2）：数值变更后回调（测试记录 / NW 同步等由调用方注入）
        _observer = nil,
        -- 事件音效路径表（编辑器属性页音效选择器保存，sounds = { deploy/attack/death/play/activate/trigger = 相对路径 }）
        -- 键与 sh_battle_combat.lua 事件音效回调一致；未配置槽位恒缺省；非单位卡同样挂上（指令=play、反制=activate/trigger）
        _sounds = (stats and stats.sounds) or {},
        -- 规模（卡牌外貌属性编辑器「规模」：small 少量 / medium 中量 / large 巨大；缺省 "small"）
        -- 决定放置在场音效（放牌）与部署音效分配（见 KARDS.CardSounds），随卡牌持久化
        _cardScale = (stats and stats.cardScale) or "small",
    }
    -- 挂接共享方法表（re.md 阶段二 B4：方法收敛为 KARDS.MockCardMethods，避免逐卡闭包）
    setmetatable(card, { __index = KARDS.MockCardMethods })

    -- 创建时规范化倍率数组（在方法定义之后调用，复用 AddCombatMultiplier 的规则；
    -- 仅单位卡接收，倍率 1 的条目由 AddCombatMultiplier 丢弃，非单位卡两数组恒空）
    if cardType == "unit" and stats and stats.combatModifiers then
        for _, rule in ipairs(stats.combatModifiers.outgoing or {}) do
            card:AddCombatMultiplier("outgoing", rule.targetPath, rule.multiplier, rule.targetName)
        end
        for _, rule in ipairs(stats.combatModifiers.incoming or {}) do
            card:AddCombatMultiplier("incoming", rule.sourcePath, rule.multiplier, rule.sourceName)
        end
    end

    return card
end
