--[[
    Kards 战斗牌桌客户端模块：单位操作交互（cl_battle_ops.lua）

    职责（readme 7.1 操作）：玩家按下在场单位 → 播放指向音效（sound/kards/aim.ogg，
    原「指向.ogg」接入后已转英文文件名）；按住期间按悬停目标显示箭头指向样式
    （与指向性指令一致，2026-08-12：绿线 + 目标描圈 = 合法，灰白线 = 不可指向，
    绘制见 cl_init.lua KardsPointingDraw）；松开时按悬停目标发送操作请求：
      - 悬停敌方单位 → KardsUnitEngage（交战：攻击另一个单位，攻击总部不算交战）
      - 悬停敌方总部 → KardsUnitAttackHQ（攻击总部）
      - 支援阵线单位指向前线区域 → KardsUnitMoveFront（移动至前线）
    约定（用户铁律）：所有判定与决策由服务端战斗系统完成——客户端只识别命中对象、
    发送请求，不进行任何战斗判定；服务端失败原因经 KardsTableMsg 返回 → Flash 显示
    （见 cl_init.lua KardsTableMsg 接收器）。

    挂载：cl_init.lua include 本文件（cl_battle_state.lua / cl_battle_hud.lua 之后，
    见加载链注释）。约定：常驻钩子挂 KARDS 命名空间，不新增 cl_init.lua main chunk
    局部槽压力；跨段落共享状态读写走 KARDS.BattleState。
]]

if not CLIENT then return end

KARDS = KARDS or {}

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

local BS = KARDS.BattleState

-- 单位短卡命中尺寸（basic_card_unit 世界 7.2×8.528 / 2 + 四周容差；手牌命中尺寸
-- KARDS.HandHit* 是完整卡 7.2×10.8 的半宽，单位短卡更矮，独立一组）
KARDS.UnitHitHalfW = 3.6 + 1.0
KARDS.UnitHitHalfL = 4.264 + 1.0

-- 前线区域判定容差（鼠标投影 y 到前线行 y 的最大距离）
local FrontlineHoverBand = 6

-- 左键上一帧状态（按下沿选中单位 / 松开沿发送操作）
local prevOpLeft = false

-- 复位（退出牌桌 / 新对局调用；见 cl_init.lua KardsTableExited / KardsTableBattleStart 段）
function KARDS.UnitOpsReset()
    BS.unitOpSel = nil
    BS.unitOpTarget = nil
    prevOpLeft = false
end

-- 总部实体识别：KARDS.HitTest.Filters.IsHQ（Kards_DeckRole="hq"，见 table_battledeck.lua
-- LoadPlayerBattleDeck）；战场单位实体无此 NW（Kards_CardAttack/Defense/ActionCost）

-- 射线命中多个候选场（表数组）中最近的一个实体；skipHQ 时跳过总部实体
-- @param fields  table 候选场数组（{ [ent] = 槽位 } 布局表）
-- @param skipHQ boolean 是否跳过总部实体
-- @param pos    Vector 射线起点（摄像机/眼睛位置）
-- @param dir    Vector 射线方向（鼠标视线）
-- @return Entity|nil 最近命中的实体
local function HitUnits(fields, skipHQ, pos, dir)
    local filter = skipHQ
        and KARDS.HitTest.All(KARDS.HitTest.Filters.Valid, KARDS.HitTest.Filters.NotHQ)
        or KARDS.HitTest.Filters.Valid
    return KARDS.HitTest.NearestCardFace(pos, dir, fields,
        KARDS.UnitHitHalfW, KARDS.UnitHitHalfL, nil, filter)
end

-- 鼠标投影到牌桌局部 z 平面（前线移动判定用；与 cl_init.lua MouseLocalZ 同法）
-- @param pos Vector 射线起点
-- @param dir Vector 射线方向
-- @param z   number 牌桌局部 z 平面高度
-- @return Vector|nil 投影的局部坐标
local function MouseLocal(pos, dir, z)
    if not BS.inTable or not IsValid(BS.inTable.ent) then return nil end
    if math.abs(dir.z) < 0.001 then return nil end
    local planeZ = BS.inTable.ent:LocalToWorld(Vector(0, 0, z)).z
    local world = pos + dir * ((planeZ - pos.z) / dir.z)
    return BS.inTable.ent:WorldToLocal(world)
end

-- 解析单位操作指向目标（箭头样式反馈 + 松开发送共用，2026-08-12）：
-- 按悬停目标优先级：敌方单位 → 交战 / 敌方总部 → 攻击总部 / 本方支援阵线单位
-- 指向前线区域 → 移动。目标判定与发送请求使用同一函数，保证所见即所得。
-- @param pos       Vector 射线起点
-- @param dir       Vector 射线方向
-- @param unitOpSel Entity 当前按下的本方单位实体
-- @return table|nil 指向目标 { kind = "engage"|"hq"|"move", ent = 目标实体|nil }；无合法目标返回 nil
local function ResolveUnitOpTarget(pos, dir, unitOpSel)
    if not IsValid(unitOpSel) then return nil end
    local ownSlot = BS.inTable.slot
    local enemySlot = (ownSlot == 1) and 2 or 1
    -- 1) 敌方候选场：单位与总部各取最近（2026-10-16 优化，原实现分两次遍历；
    --    本处仍按「两次取最近」表达，优先级不变：单位先于总部）
    --    （readme 7.1：交战 = 攻击另一个单位；总部不算交战，攻击总部不算交战）
    local support = BS.fieldLayouts[enemySlot]
    local enemyFields = { support }
    if BS.frontlineOwnerSlot == enemySlot then
        enemyFields[#enemyFields + 1] = BS.frontlineLayout
    end
    local enemy = KARDS.HitTest.NearestCardFace(pos, dir, enemyFields,
        KARDS.UnitHitHalfW, KARDS.UnitHitHalfL, nil,
        KARDS.HitTest.All(KARDS.HitTest.Filters.Valid, KARDS.HitTest.Filters.NotHQ))
    -- 总部只可能在本方 / 敌方支援阵线；与原第二次遍历的口径一致
    local hq = KARDS.HitTest.NearestCardFace(pos, dir, { support },
        KARDS.UnitHitHalfW, KARDS.UnitHitHalfL, nil,
        KARDS.HitTest.All(KARDS.HitTest.Filters.Valid, KARDS.HitTest.Filters.IsHQ))
    if enemy then return { kind = "engage", ent = enemy } end
    -- 2) 敌方总部 → 攻击总部
    if hq then return { kind = "hq", ent = hq } end
    -- 3) 支援阵线单位指向前线区域 → 移动至前线（readme 7.1 操作；
    --    前线单位已在前线，不提供移动——仅本方支援阵线单位可移动）
    if BS.fieldLayouts[ownSlot] and BS.fieldLayouts[ownSlot][unitOpSel] then
        local lp = MouseLocal(pos, dir, KARDS.Animation.Board2D.CardZ)
        if lp and math.abs(lp.y - KARDS.Animation.Board2D.RowY[0]) <= FrontlineHoverBand then
            return { kind = "move" }
        end
    end
    -- 4) 前线单位拖回本方支援阵线区域 → 撤退（readme 7.1 操作：前线单位撤回本方
    --    支援阵线，未满时移到/插入最右侧；满则服务端拒绝提示。前方分支已排除
    --    敌方单位/总部命中，本方支援阵线单位悬停不冲突）
    if BS.frontlineOwnerSlot == ownSlot and BS.frontlineLayout
        and BS.frontlineLayout[unitOpSel] then
        local sign = (ownSlot == 1) and 1 or -1
        local lp = MouseLocal(pos, dir, KARDS.Animation.Board2D.CardZ)
        if lp and math.abs(lp.y - KARDS.Animation.Board2D.RowY[sign]) <= FrontlineHoverBand then
            return { kind = "retreat" }
        end
    end
    return nil
end

hook.Add("Think", "KardsUnitOpThink", function()
    local ply = LocalPlayer()
    local view = KARDS.Perspective and KARDS.Perspective.LocalView
    local inBattle = BS.battleStarted and BS.inTable and IsValid(BS.inTable.ent)
    local guiBlocked = gui.IsConsoleVisible() or gui.IsGameUIVisible()
    local left = input.IsMouseDown(MOUSE_LEFT)

    -- 门控（与 KardsDragCardThink 同门控：我方回合 / 视角本方 / 无 GUI / 无拖拽 /
    -- 无待确认 / 未结束回合 / 非结算中）
    local active = inBattle and BS.battleTurn == BS.inTable.slot
        and (view == 1 or view == 2) and not guiBlocked
        and not BS.dragCard and not BS.pendingPlayEnt and not BS.endedTurn and not BS.gameOver

    if not active then
        -- 失活：清除选中与指向目标（防残留）；指向音效未播完立即停止
        BS.unitOpSel = nil
        BS.unitOpTarget = nil
        if KARDS.StopAimSound then KARDS.StopAimSound() end
        prevOpLeft = left
        return
    end

    -- 相机射线统一走抗视差实现（KARDS.HitTest.MouseRay）
    local pos, dir = KARDS.HitTest.MouseRay()
    if not pos then
        prevOpLeft = left
        return
    end

    local ownSlot = BS.inTable.slot

    -- 按下（左键上升沿）：命中本方在场单位（本方支援阵线 + 本方前线）→ 选中 + 指向音效
    if left and not prevOpLeft then
        local ownFields = { BS.fieldLayouts[ownSlot] }
        if BS.frontlineOwnerSlot == ownSlot then
            ownFields[#ownFields + 1] = BS.frontlineLayout
        end
        local hit = HitUnits(ownFields, true, pos, dir) -- 跳过总部（总部不可被操作）
        if hit then
            BS.unitOpSel = hit
            -- 指向音效（2026-08-13：与指令指向统一走 KARDS.PlayAimSound——原
            -- PlayKardsSound("aim") 无法中途停止；本方法可停止，指向结束立即停）
            KARDS.PlayAimSound()
        end
    end

    -- 指向目标状态（箭头样式反馈，2026-08-12）：选中单位期间每帧按悬停目标解析，
    -- 与指向性指令一致（cl_init.lua KardsPointingDraw 读 unitOpTarget 画绿/灰白线 + 目标描圈）
    if BS.unitOpSel and IsValid(BS.unitOpSel) then
        BS.unitOpTarget = ResolveUnitOpTarget(pos, dir, BS.unitOpSel)
    else
        BS.unitOpTarget = nil
    end

    -- 松开（左键下降沿 + 有选中单位）：按本帧指向目标发送操作（与箭头反馈同一判定）
    if not left and prevOpLeft and BS.unitOpSel and IsValid(BS.unitOpSel) then
        local t = BS.unitOpTarget
        if t then
            if t.kind == "engage" then
                net.Start("KardsUnitEngage")
                    net.WriteEntity(BS.inTable.ent)
                    net.WriteEntity(BS.unitOpSel)
                    net.WriteEntity(t.ent)
                net.SendToServer()
            elseif t.kind == "hq" then
                net.Start("KardsUnitAttackHQ")
                    net.WriteEntity(BS.inTable.ent)
                    net.WriteEntity(BS.unitOpSel)
                net.SendToServer()
            elseif t.kind == "move" then
                net.Start("KardsUnitMoveFront")
                    net.WriteEntity(BS.inTable.ent)
                    net.WriteEntity(BS.unitOpSel)
                net.SendToServer()
            elseif t.kind == "retreat" then
                net.Start("KardsUnitRetreat")
                    net.WriteEntity(BS.inTable.ent)
                    net.WriteEntity(BS.unitOpSel)
                net.SendToServer()
            end
        else
            -- 无合法目标：指向了不可指向处 / 空位 → 提示（2026-08-12 提示系统）。
            -- 命中选中单位本体（简单点击选中/取消）不提示
            local allFields = { BS.fieldLayouts[1], BS.fieldLayouts[2] }
            if BS.frontlineOwnerSlot ~= 0 then
                allFields[#allFields + 1] = BS.frontlineLayout
            end
            local hit = HitUnits(allFields, false, pos, dir)
            if IsValid(hit) then
                if hit ~= BS.unitOpSel then
                    KARDS.BattleHint.Push(T("battle.pointing.invalid"))
                end
            else
                KARDS.BattleHint.Push(T("battle.pointing.none"))
            end
        end
        BS.unitOpSel = nil
        BS.unitOpTarget = nil
        if KARDS.StopAimSound then KARDS.StopAimSound() end -- 指向结束（松手）：未播完立即停止
    end

    prevOpLeft = left
end)

-- 实体移除清理：选中单位被消灭 / 退出等 → 清除选中 + 移除其 3D2D 文字
-- （单位实体为手动创建（table_battledeck.lua OnPlayCard），被消灭后服务端 Remove，
--  overlay 条目残留，须随实体移除清理）
hook.Add("EntityRemoved", "KardsUnitOpEntityRemoved", function(ent)
    if not ent then return end
    if BS.unitOpSel == ent then
        BS.unitOpSel = nil
        BS.unitOpTarget = nil
        if KARDS.StopAimSound then KARDS.StopAimSound() end -- 选中单位移除：指向音效停止
    end
    if KARDS.CardTextOverlay and KARDS.CardTextOverlay.Ents and KARDS.CardTextOverlay.Ents[ent] then
        KARDS.CardTextOverlay:Remove(ent)
    end
end)
