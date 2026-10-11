--[[
    卡牌规模音效 (Card Sounds)

    2026-08-14 用户规格：卡牌外貌属性编辑器「规模」接入战斗系统。
    规模（CardScaleOptions：small 少量 / medium 中量 / large 巨大）决定两类音效：
      1. 放置在场音效（放牌，按规模直接播放）：medium → place_medium.ogg、
         large → place_large.ogg、small → 无；
      2. 部署音效（单位变身为小模型单位时播放）：编辑器按「单位类型 × 规模」自动
         分配写入 app.sounds.deploy（见 AutoAssignDeploySound），缺失文件级联回退。
    原 放牌.ogg / 重放牌.ogg 因非 ASCII 文件名 BASS 无法播放（GMod Issue #2304）
    已重命名为 place_medium.ogg / place_large.ogg。

    拆分说明（re.md 阶段二 B4）：自 sh_card_interface.lua 独立成模块；
    依赖 KARDS.CardInterface.UnitTypes（sh_card_interface.lua 先于本文件加载）。
]]

KARDS = KARDS or {}
--- 卡牌规模音效（部署/攻击/放置在场音效按「单位类型 × 规模」分配与级联回退）
KARDS.CardSounds = KARDS.CardSounds or {}

-- 部署音效映射表（单位类型 → 规模 → 理想音效相对路径）
-- 战斗机/轰炸机共用 planes 目录音效；缺失文件（如 heavy_tank.ogg）在编辑器侧
-- 自动分配时提示用户准备，运行时按 large→medium→small 级联回退最近档位。
KARDS.CardSounds.DeployMap = {
    infantry = {
        small  = "sound/kards/unit/infantry/light_infantry.ogg",
        medium = "sound/kards/unit/infantry/medium_infantry.ogg",
        large  = "sound/kards/unit/infantry/heavy_infantry.ogg",
    },
    tank = {
        small  = "sound/kards/unit/tank/light_tank.ogg",
        medium = "sound/kards/unit/tank/medium_tank.ogg",
        large  = "sound/kards/unit/tank/heavy_tank.ogg",
    },
    artillery = {
        small  = "sound/kards/unit/artillery/light_artillery_deploy.ogg",
        medium = "sound/kards/unit/artillery/medium_artillery_deploy.ogg",
        large  = "sound/kards/unit/artillery/heavy_artillery_deploy.ogg",
    },
    fighter = {
        small  = "sound/kards/unit/planes/light_plane.ogg",
        medium = "sound/kards/unit/planes/medium_plane.ogg",
        large  = "sound/kards/unit/planes/heavy_plane.ogg",
    },
    bomber = {
        small  = "sound/kards/unit/planes/light_plane.ogg",
        medium = "sound/kards/unit/planes/medium_plane.ogg",
        large  = "sound/kards/unit/planes/heavy_plane.ogg",
    },
}

-- 规模 → 放置在场音效（放牌；small 少量规模不使用）
KARDS.CardSounds.PlaceSoundByScale = {
    medium = "sound/kards/other/place_medium.ogg",
    large  = "sound/kards/other/place_large.ogg",
}

-- 已提示过的缺失部署音频路径（会话内只提示一次，避免每次选择规模都刷屏）
KARDS.CardSounds._missingReported = {}

--- 规模 → 放置在场音效路径（medium/large；small 及未知规模 → nil 不放音效）
function KARDS.CardSounds.GetPlaceSound(scale)
    return KARDS.CardSounds.PlaceSoundByScale[scale]
end

--- (单位类型, 规模) → 部署音效路径；理想文件缺失时按 large→medium→small 级联
--- 回退到最近档位（不存在于 kards 的组合由编辑器 AutoAssignDeploySound 提示准备）
function KARDS.CardSounds.GetDeploySound(unitType, scale)
    local m = KARDS.CardSounds.DeployMap[unitType]
    if not m then return nil end
    local order
    if scale == "large" then order = { "large", "medium", "small" }
    elseif scale == "medium" then order = { "medium", "small" }
    else order = { "small" } end
    for _, s in ipairs(order) do
        local p = m[s]
        if p and file.Exists(p, "GAME") then return p end
    end
    return nil
end

-- 攻击音效映射表（单位类型 → 规模 → 理想音效相对路径）
-- 仅步兵/坦克/炮兵自动分配（2026-08-14 用户决策：planes 目录无明确攻击音效文件，
-- 飞机 fighter/bomber 攻击音效保持手动选择）；缺失文件（如 heavy_artillery_attack.ogg）
-- 在编辑器侧自动分配时提示用户准备，运行时按规模档位级联回退（GetAttackSound）。
KARDS.CardSounds.AttackMap = {
    infantry = {
        small  = "sound/kards/unit/infantry/light_infantry_attack.ogg",
        medium = "sound/kards/unit/infantry/infantry_attack.ogg",
        large  = "sound/kards/unit/infantry/heavy_infantry_attack.ogg",
    },
    tank = {
        small  = "sound/kards/unit/tank/light_tank_attack.ogg",
        medium = "sound/kards/unit/tank/tank_attack.ogg",
        large  = "sound/kards/unit/tank/tank_attack2.ogg",
    },
    artillery = {
        small  = "sound/kards/unit/artillery/light_artillery_attack.ogg",
        medium = "sound/kards/unit/artillery/medium_artillery_attack.ogg",
        large  = "sound/kards/unit/artillery/heavy_artillery_attack.ogg",
    },
}

--- (单位类型, 规模) → 攻击音效路径；理想文件缺失时按规模档位级联回退到最近档位
--- （与 GetDeploySound 同款回退：large→medium→small、medium→small、small 仅查自身）。
--- 无映射类型（飞机 fighter/bomber）→ nil（攻击音效保持手动配置，不自动分配）
function KARDS.CardSounds.GetAttackSound(unitType, scale)
    local m = KARDS.CardSounds.AttackMap[unitType]
    if not m then return nil end
    local order
    if scale == "large" then order = { "large", "medium", "small" }
    elseif scale == "medium" then order = { "medium", "small" }
    else order = { "small" } end
    for _, s in ipairs(order) do
        local p = m[s]
        if p and file.Exists(p, "GAME") then return p end
    end
    return nil
end

--- 编辑器侧：按当前 (单位类型, 规模) 自动分配攻击音效到 app.sounds.attack
--- （选择规模 / 变更单位类型时调用；非单位卡清除攻击音效；飞机不自动分配不动原值）。
--- 手动锁定（音效选择器五角星 _manual.attack=true）优先不覆盖；
--- 理想文件不存在于 kards 时提示未准备的音频名（用户随后补入文件即可自愈）。
function KARDS.CardSounds.AutoAssignAttackSound(app)
    if not app then return end
    app.sounds = app.sounds or {}
    local unitType = app.cardType
    if not KARDS.CardInterface.UnitTypes[unitType] then
        app.sounds.attack = nil -- 指令/反制/总部等非单位卡：无攻击音效
        return
    end
    -- 手动锁定优先（与部署音效同款）：五角星锁定过攻击音效后自动分配不再覆盖
    if app.sounds._manual and app.sounds._manual.attack then return end
    local m = KARDS.CardSounds.AttackMap[unitType]
    if not m then return end -- 飞机（fighter/bomber）不自动分配：保持手动配置不动
    local scale = app.cardScale or (KARDS.CardEditor and KARDS.CardEditor.Canvas
        and KARDS.CardEditor.Canvas.SelectedCardScale) or "small"
    local ideal = m[scale]
    app.sounds.attack = ideal or nil
    -- 缺失报告：理想文件不存在 → 提示用户准备（运行时 GetAttackSound 会级联回退）
    if ideal and not file.Exists(ideal, "GAME") and not KARDS.CardSounds._missingReported[ideal] then
        KARDS.CardSounds._missingReported[ideal] = true
        local msg = "[Kards] 未准备的攻击音频: " .. ideal
        print(msg)
        if notification and notification.AddLegacy then
            notification.AddLegacy("未准备的攻击音频: " .. ideal, 1, 8)
        end
    end
end

--- 编辑器侧：按当前 (单位类型, 规模) 自动分配部署音效到 app.sounds.deploy
--- （选择规模 / 变更单位类型时调用；非单位卡清除部署音效）。
--- 理想文件不存在于 kards 时提示未准备的音频名（用户随后补入文件即可自愈）。
function KARDS.CardSounds.AutoAssignDeploySound(app)
    if not app then return end
    app.sounds = app.sounds or {}
    local unitType = app.cardType
    if not KARDS.CardInterface.UnitTypes[unitType] then
        app.sounds.deploy = nil -- 指令/反制/总部等非单位卡：无部署音效
        return
    end
    -- 手动锁定优先（2026-08-14）：编辑器音效选择器五角星锁定过部署音效（写
    -- _manual.deploy=true）后，规模/单位类型变更的自动分配不再覆盖手动选择——
    -- 最终生效的是五角星（手动）显示的选项。旧卡无该标记 → 自动分配照常。
    if app.sounds._manual and app.sounds._manual.deploy then return end
    local scale = app.cardScale or (KARDS.CardEditor and KARDS.CardEditor.Canvas
        and KARDS.CardEditor.Canvas.SelectedCardScale) or "small"
    local m = KARDS.CardSounds.DeployMap[unitType]
    local ideal = m and m[scale]
    app.sounds.deploy = ideal or nil
    -- 缺失报告：理想文件不存在 → 提示用户准备（运行时 GetDeploySound 会级联回退）
    if ideal and not file.Exists(ideal, "GAME") and not KARDS.CardSounds._missingReported[ideal] then
        KARDS.CardSounds._missingReported[ideal] = true
        local msg = "[Kards] 未准备的部署音频: " .. ideal
        print(msg)
        if notification and notification.AddLegacy then
            notification.AddLegacy("未准备的部署音频: " .. ideal, 1, 8)
        end
    end
end
