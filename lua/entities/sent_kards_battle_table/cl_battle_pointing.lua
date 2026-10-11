--[[
    Kards 战斗牌桌客户端模块：指向机制（cl_battle_pointing.lua，2026-08-15 C1 拆分）

    自 cl_init.lua（lua/entities/sent_kards_battle_table/cl_init.lua）指向段迁移：
      - KARDS.GetCardEffectNodeInfo：读取卡牌效果节点信息（客户端指向判定）——
        保存文件链路遍历节点判定是否存在「选择卡牌单位目标（指向一个）」，结果
        缓存 KARDS.BattleState.effectCache（weak keys 随实体清理）
      - KARDS.GetPointingTarget：指向模式目标检测——鼠标射线命中合法战场单位按
        效果节点约束（阵营/类别）校验后返回目标实体
      - KARDS.PointingFailReason：指向失败原因（提示系统文案区分「不能指向此目标」
        /「请指向目标」/「隐蔽单位不受指令指向」）
      - KardsPointingDraw（HUDPaint）：指向连线绘制（拖拽指向模式 + 单位操作共用，
        见 cl_battle_ops.lua 的 unitOpSel/unitOpTarget）

    挂载：cl_init.lua include 本文件（KardsHandSlotFacing 段之后、文件末尾）。
    约定：全部走 KARDS 命名空间与 cl_battle_ops.lua 的 KARDS.UnitHitHalfW/L（本文件
    include 时 cl_battle_ops.lua 已先加载）；无文件级 local。
]]

--[[
    读取卡牌效果节点信息（客户端指向机制判定）

    从卡牌保存文件链路（Kards_CardFileName → card JSON → cardAppearance.effectPath →
    effect JSON）遍历节点，判定是否存在「选择卡牌单位目标（指向一个）」节点。
    结果缓存到 KARDS.BattleState.effectCache（weak keys 随实体清理；退出牌桌复位）。

    注意：客户端读的是保存文件「编辑器键」体系（与编辑器面板一致，不依赖阶段 A
    的 runtimeData）：指向方式 select_1==1（指向一个）、阵营 select_4（1 友方 / 2
    敌方 / 3 场上）、类别 select_5（1 单位 / 2 目标 / 3 总部）、单位类型 select_8
    （1 任意 / 2-6）。select 组件值优先取 data.dropdowns[compId].selectedIndex
    （DrawDropdownBox 写入的权威来源），回退顶层 data[compId]。

    @param cardEnt Entity 手牌实体（须携带 Kards_CardFileName NW，服务端 SpawnDeckDrawCard 写入）
    @return table { hasTargetSelector, select_1, campIdx, catIdx, typeIdx }
]]
function KARDS.GetCardEffectNodeInfo(cardEnt)
    if not IsValid(cardEnt) then return nil end
    local cached = KARDS.BattleState.effectCache[cardEnt]
    if cached then return cached end
    local info = { hasTargetSelector = false }
    -- 文件原名（服务端经 KardsTableDrawFace 定向发本方的卡文件 = URL 编码文件名，
    -- 2026-08-18 规划 B1 起手牌实体 NW 不再携带；Kards_DeckSafeName 已净化不可反推）：
    -- GetCardInfo 需该原名（cards/ 目录落盘名）。
    local fileName = select(2, KARDS.GetCardIdentity(cardEnt))
    if fileName ~= "" and KARDS.CardEditor and KARDS.CardEditor.SaveSystem then
        local cardInfo = KARDS.CardEditor.SaveSystem.GetCardInfo(fileName)
        local app = cardInfo and cardInfo.cardAppearance
        if app and app.effectPath and app.effectPath ~= "" then
            local effect = KARDS.CardEditor.SaveSystem.LoadEffect(app.effectPath)
            if effect and effect.nodes then
                for _, node in ipairs(effect.nodes) do
                    if node.name == "target_selector_node" then
                        local d = node.data or {}
                        local dd = d.dropdowns or {}
                        local function sel(k)
                            local box = dd[k]
                            if box and box.selectedIndex ~= nil then return box.selectedIndex end
                            return d[k]
                        end
                        if sel("select_1") == 1 then
                            info = {
                                hasTargetSelector = true,
                                select_1 = 1,
                                campIdx = sel("select_4"), -- 阵营：1 友方 / 2 敌方 / 3 场上
                                catIdx  = sel("select_5"), -- 类别：1 单位 / 2 目标 / 3 总部
                                typeIdx = sel("select_8"), -- 单位类型：1 任意 / 2-6
                            }
                        end
                        break
                    end
                end
            end
        end
    end
    KARDS.BattleState.effectCache[cardEnt] = info
    return info
end

--[[
    指向模式目标检测：鼠标射线命中合法战场单位 → 按效果节点约束校验后返回目标实体

    约束（编辑器键，见 GetCardEffectNodeInfo）：阵营（1 友方 / 2 敌方 / 3 场上 →
    按本方槽位过滤）、类别（1 单位 = 排除总部 / 3 总部 = 仅总部；2 目标视作非总部）。
    命中判定复用 KARDS.RayCardHit（单位短卡命中尺寸 KARDS.UnitHitHalfW/L，见
    cl_battle_ops.lua）+ 最近距离。单位类型（select_8）客户端不校验——服务端
    TSCollectUnits 收集候选时已按运行时值过滤，客户端宽松预检即可。

    @param cardEnt Entity 拖拽中的指令卡（仅作守卫）
    @param info    table  GetCardEffectNodeInfo 结果
    @param pos     Vector 视线起点（相机位置）
    @param dir     Vector 视线方向（鼠标射线）
    @return Entity|nil 合法目标实体（无 / 非法返回 nil）
]]
function KARDS.GetPointingTarget(cardEnt, info, pos, dir)
    if not info or not info.hasTargetSelector then return nil end
    if not KARDS.BattleState.inTable or not IsValid(KARDS.BattleState.inTable.ent) then return nil end
    local BS = KARDS.BattleState
    -- 候选场：双方支援阵线 + 前线（2026-08-15 C2 收敛至 KARDS.FieldCandidates，见 cl_init.lua）
    local fields = KARDS.FieldCandidates()
    -- 阵营约束 → 允许的槽位集合
    local ownSlot = BS.inTable.slot
    local enemySlot = (ownSlot == 1) and 2 or 1
    local campIdx = info.campIdx or 3
    local allowedSlots = {}
    if campIdx == 1 then
        allowedSlots[ownSlot] = true
    elseif campIdx == 2 then
        allowedSlots[enemySlot] = true
    else
        allowedSlots[1], allowedSlots[2] = true, true
    end
    -- 类别约束 → 总部匹配开关（1 单位 = 排除总部；3 总部 = 仅总部）
    local catIdx = info.catIdx or 1
    local wantHQ = (catIdx == 3)
    local bestD, hit = math.huge, nil
    for _, field in ipairs(fields) do
        for e in pairs(field or {}) do
            if IsValid(e) then
                local eSlot = e:GetNWInt("Kards_DeckSlot", 0)
                if allowedSlots[eSlot] then
                    local isHQ = (e:GetNWString("Kards_DeckRole", "") == "hq")
                    if (wantHQ and isHQ) or (not wantHQ and not isHQ) then
                        if KARDS.RayCardHit(pos, dir, e, KARDS.UnitHitHalfW, KARDS.UnitHitHalfL) then
                            local d = KARDS.RayPointDistSqr(pos, dir, e:GetPos())
                            if d < bestD then bestD, hit = d, e end
                        end
                    end
                end
            end
        end
    end
    -- 隐蔽单位不可作为指令目标（readme 7.2.2 + 2026-08-13 用户规格：指令指向隐蔽
    -- 单位始终提示「隐蔽单位不受指令指向」）：最近命中为隐蔽单位 → 视为无目标
    -- （返回 nil，松手回手牌 + PointingFailReason 提示本文案；悬停提示见拖拽 Think）。
    -- 注意：命中在前方的合法单位则正常返回——隐蔽卡在后、合法单位在前时以合法为准
    if hit and KARDS.Stealth and KARDS.Stealth.IsStealthEnt(hit) then return nil end
    return hit
end

--[[
    指向失败原因（2026-08-12 提示系统）：指向模式松手时未指向合法目标，据此区分
    「悬停了实体但不可选」与「悬停空位」。命中双方支援阵线 + 前线的任一战场实体
    （单位/总部）→ "不能指向此目标"；否则 → "请指向目标"。

    @param pos Vector 视线起点（相机位置）
    @param dir Vector 视线方向（鼠标射线）
    @return string|nil 提示文字（未在牌桌 / 无目标选择器时 nil，不提示）
]]
function KARDS.PointingFailReason(pos, dir)
    local BS = KARDS.BattleState
    if not BS.inTable or not IsValid(BS.inTable.ent) then return nil end
    -- 指向隐蔽单位（2026-08-13 用户规格）：始终提示「隐蔽单位不受指令指向」——须在
    -- 通用「不能指向此目标」之前判定（隐蔽单位已被 GetPointingTarget 剔除候选，但
    -- 此处射线仍命中其卡面，故优先返回本文案）
    if KARDS.Stealth and KARDS.Stealth.HitStealthTarget(pos, dir) then
        return "隐蔽单位不受指令指向"
    end
    -- 候选场：双方支援阵线 + 前线（2026-08-15 C2 收敛至 KARDS.FieldCandidates，见 cl_init.lua）
    local fields = KARDS.FieldCandidates()
    for _, field in ipairs(fields) do
        for e in pairs(field or {}) do
            if IsValid(e) and KARDS.RayCardHit(pos, dir, e, KARDS.UnitHitHalfW, KARDS.UnitHitHalfL) then
                return "不能指向此目标"
            end
        end
    end
    return "请指向目标"
end

-- 指向连线绘制（2026-08-12 阶段 B）：拖拽中的指向模式卡 → 卡牌原点与鼠标之间直线
-- + 鼠标端箭头；指向合法目标时绿线 + 目标描圈，否则灰白线（可指向性反馈）。
-- 2026-08-12 扩展：单位操作（按下在场单位，cl_battle_ops.lua）同样走指向样式——
-- 起点 = 选中的本方单位实体，合法性 = BS.unitOpTarget（engage/hq/move），样式一致。
hook.Add("HUDPaint", "KardsPointingDraw", function()
    local dragCard = KARDS.BattleState.dragCard
    local opSel = KARDS.BattleState.unitOpSel
    local pointing = (dragCard and dragCard.pointing) or (opSel and IsValid(opSel))
    if not pointing then return end
    -- 起点实体：指向模式 = 拖拽卡；单位操作 = 选中的本方单位
    local ent = (dragCard and dragCard.pointing and dragCard.ent) or opSel
    if not IsValid(ent) then return end
    -- 卡牌原点 3D → 屏幕 2D 投影
    local sp = ent:GetPos():ToScreen()
    local mx, my = gui.MouseX(), gui.MouseY()
    -- 合法目标判定：指向模式 → dragCard.validTarget；单位操作 → unitOpTarget
    local valid, validEnt = false, nil
    if dragCard and dragCard.pointing then
        valid = dragCard.validTarget and IsValid(dragCard.validTarget)
        if valid then validEnt = dragCard.validTarget end
    else
        local t = KARDS.BattleState.unitOpTarget
        valid = t ~= nil
        if valid and t.ent then validEnt = t.ent end
    end
    -- 直线：起点 → 鼠标
    surface.SetDrawColor(valid and Color(80, 255, 120, 230) or Color(230, 230, 230, 140))
    surface.DrawLine(sp.x, sp.y, mx, my)
    -- 鼠标端箭头（两条短线成箭头角）
    local ang = math.atan2(my - sp.y, mx - sp.x)
    local alen = 12
    local a1, a2 = ang + math.pi * 0.75, ang - math.pi * 0.75
    surface.DrawLine(mx, my, mx + math.cos(a1) * alen, my + math.sin(a1) * alen)
    surface.DrawLine(mx, my, mx + math.cos(a2) * alen, my + math.sin(a2) * alen)
    -- 合法目标描圈（圆环，16 段短线近似；示意可指向的目标；移动无实体目标不描圈）
    if validEnt then
        local tsp = validEnt:GetPos():ToScreen()
        local r, segs = 14, 16
        for i = 1, segs do
            local ta1 = (i - 1) / segs * math.pi * 2
            local ta2 = i / segs * math.pi * 2
            surface.DrawLine(
                tsp.x + math.cos(ta1) * r, tsp.y + math.sin(ta1) * r,
                tsp.x + math.cos(ta2) * r, tsp.y + math.sin(ta2) * r)
        end
    end
end)
