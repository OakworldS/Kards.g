--[[
    Kards 战斗牌桌客户端模块：单位操作交互（cl_battle_ops.lua）

    职责（readme 7.1 操作）：玩家按下在场单位 → 播放指向音效（sound/kards/aim.ogg，
    原「指向.ogg」接入后已转英文文件名）；松开时按悬停目标发送操作请求：
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
    prevOpLeft = false
end

-- 总部实体识别：服务端总部实体设置 Kards_DeckRole="hq"（见 table_battledeck.lua
-- LoadPlayerBattleDeck）；战场单位实体无此 NW（Kards_CardAttack/Defense/ActionCost）
local function IsHQ(ent)
    return IsValid(ent) and ent:GetNWString("Kards_DeckRole", "") == "hq"
end

hook.Add("Think", "KardsUnitOpThink", function()
    local ply = LocalPlayer()
    local view = KARDS.Perspective and KARDS.Perspective.LocalView
    local inBattle = BS.battleStarted and BS.inTable and IsValid(BS.inTable.ent)
    local guiBlocked = gui.IsConsoleVisible() or gui.IsGameUIVisible()
    local left = input.IsMouseDown(MOUSE_LEFT)

    -- 门控（与 KardsDragCardThink 同门控：我方回合 / 视角本方 / 无 GUI / 无拖拽 /
    -- 无待确认 / 未结束回合）
    local active = inBattle and BS.battleTurn == BS.inTable.slot
        and (view == 1 or view == 2) and not guiBlocked
        and not BS.dragCard and not BS.pendingPlayEnt and not BS.endedTurn

    if not active then
        -- 失活：清除选中（防残留）
        BS.unitOpSel = nil
        prevOpLeft = left
        return
    end

    local pos = (KARDS.BattleCamera and KARDS.BattleCamera.ViewPos) or ply:EyePos()
    local dir = gui.ScreenToVector(gui.MouseX(), gui.MouseY())
    if not dir or (dir.x == 0 and dir.y == 0 and dir.z == 0) then
        dir = (KARDS.BattleCamera and KARDS.BattleCamera.ViewAng or ply:EyeAngles()):Forward()
    end

    local ownSlot = BS.inTable.slot
    local enemySlot = (ownSlot == 1) and 2 or 1

    -- 射线命中多个候选场（表数组）中最近的一个实体；skipHQ 时跳过总部实体
    local function HitUnits(fields, skipHQ)
        local bestD, hit = math.huge, nil
        for _, field in ipairs(fields) do
            for e in pairs(field or {}) do
                if IsValid(e) and not (skipHQ and IsHQ(e)) then
                    if KARDS.RayCardHit(pos, dir, e, KARDS.UnitHitHalfW, KARDS.UnitHitHalfL) then
                        local d = KARDS.RayPointDistSqr(pos, dir, e:GetPos())
                        if d < bestD then bestD, hit = d, e end
                    end
                end
            end
        end
        return hit
    end

    -- 鼠标投影到牌桌局部 z 平面（前线移动判定用；与 cl_init.lua MouseLocalZ 同法）
    local function MouseLocal(z)
        if not BS.inTable or not IsValid(BS.inTable.ent) then return nil end
        if math.abs(dir.z) < 0.001 then return nil end
        local planeZ = BS.inTable.ent:LocalToWorld(Vector(0, 0, z)).z
        local world = pos + dir * ((planeZ - pos.z) / dir.z)
        return BS.inTable.ent:WorldToLocal(world)
    end

    -- 按下（左键上升沿）：命中本方在场单位（本方支援阵线 + 本方前线）→ 选中 + 指向音效
    if left and not prevOpLeft then
        local ownFields = { BS.fieldLayouts[ownSlot] }
        if BS.frontlineOwnerSlot == ownSlot then
            ownFields[#ownFields + 1] = BS.frontlineLayout
        end
        local hit = HitUnits(ownFields, true) -- 跳过总部（总部不可被操作）
        if hit then
            BS.unitOpSel = hit
            KARDS.PlayKardsSound("aim") -- 指向音效（原 指向.ogg 接入后转英文 aim.ogg）
        end
    end

    -- 松开（左键下降沿 + 有选中单位）：按悬停目标优先级发送操作
    if not left and prevOpLeft and BS.unitOpSel and IsValid(BS.unitOpSel) then
        -- 1) 悬停敌方单位 → 交战（readme 7.1：交战 = 攻击另一个单位；总部不算）
        local enemyFields = { BS.fieldLayouts[enemySlot] }
        if BS.frontlineOwnerSlot == enemySlot then
            enemyFields[#enemyFields + 1] = BS.frontlineLayout
        end
        local enemy = HitUnits(enemyFields, true) -- 跳过敌方总部（总部走攻击总部）
        if enemy then
            net.Start("KardsUnitEngage")
                net.WriteEntity(BS.inTable.ent)
                net.WriteEntity(BS.unitOpSel)
                net.WriteEntity(enemy)
            net.SendToServer()
        else
            -- 2) 悬停敌方总部 → 攻击总部（readme 7.1：攻击总部不算交战）
            local hq = HitUnits({ BS.fieldLayouts[enemySlot] }, false)
            if hq and IsHQ(hq) then
                net.Start("KardsUnitAttackHQ")
                    net.WriteEntity(BS.inTable.ent)
                    net.WriteEntity(BS.unitOpSel)
                net.SendToServer()
            else
                -- 3) 支援阵线单位指向前线区域 → 移动至前线（readme 7.1 操作；
                --    前线单位已在前线，不提供移动——仅本方支援阵线单位可移动）
                if BS.fieldLayouts[ownSlot] and BS.fieldLayouts[ownSlot][BS.unitOpSel] then
                    local lp = MouseLocal(KARDS.Animation.Board2D.CardZ)
                    if lp and math.abs(lp.y - KARDS.Animation.Board2D.RowY[0]) <= FrontlineHoverBand then
                        net.Start("KardsUnitMoveFront")
                            net.WriteEntity(BS.inTable.ent)
                            net.WriteEntity(BS.unitOpSel)
                        net.SendToServer()
                    end
                end
            end
        end
        BS.unitOpSel = nil
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
    end
    if KARDS.CardTextOverlay and KARDS.CardTextOverlay.Ents and KARDS.CardTextOverlay.Ents[ent] then
        KARDS.CardTextOverlay:Remove(ent)
    end
end)
