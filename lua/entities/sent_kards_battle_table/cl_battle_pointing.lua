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
      - KardsPointingDraw（HUDPaint）：指向反馈绘制（单位操作连线 + 两模式合法目标
        描圈；2026-10-24 起拖拽指向模式的连线/箭头由 KardsPointingArrow3D 的
        3D2D 贴图箭头承担，见文件末尾）

    挂载：cl_init.lua include 本文件（KardsHandSlotFacing 段之后、文件末尾）。
    约定：全部走 KARDS 命名空间与 cl_battle_ops.lua 的 KARDS.UnitHitHalfW/L（本文件
    include 时 cl_battle_ops.lua 已先加载）；无文件级 local。
]]

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

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
    -- 卡面矩形命中，再按中心距离取最近；槽位、总部与有效性均由筛选谓词表达
    local hit = KARDS.HitTest.NearestCardFace(pos, dir, fields,
        KARDS.UnitHitHalfW, KARDS.UnitHitHalfL, nil,
        KARDS.HitTest.All(KARDS.HitTest.Filters.Valid, function(e)
            if not allowedSlots[e:GetNWInt("Kards_DeckSlot", 0)] then return false end
            local isHQ = KARDS.HitTest.Filters.IsHQ(e)
            return (wantHQ and isHQ) or (not wantHQ and not isHQ)
        end))
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
        return T("battle.pointing.stealth")
    end
    -- 候选场：双方支援阵线 + 前线（2026-08-15 C2 收敛至 KARDS.FieldCandidates，见 cl_init.lua）
    local fields = KARDS.FieldCandidates()
    for _, field in ipairs(fields) do
        for e in pairs(field or {}) do
            if IsValid(e) and KARDS.RayCardHit(pos, dir, e, KARDS.UnitHitHalfW, KARDS.UnitHitHalfL) then
                return T("battle.pointing.invalid")
            end
        end
    end
    return T("battle.pointing.none")
end

-- 指向连线颜色（合法目标 / 普通），常量复用免每帧构造 Color（2026-10-16 性能优化）
local POINT_LINE_VALID = Color(80, 255, 120, 230)
local POINT_LINE_IDLE  = Color(230, 230, 230, 140)

-- 指向箭头贴图（2026-10-24 用户规格）：黑体白描边箭头图片（略向左弯、底部不描边、
-- 尾部自带透明度渐变，箭头朝 +x、尖端贴右缘垂直中点），3D2D 绘制时整张贴图映射到
-- 「卡牌 → 鼠标」矩形，经缩放使箭头头部落在鼠标处。
-- 染色（2026-10-24 二次规格）：SetDrawColor 乘法染色只作用于白色描边（黑色箭身不变），
-- 仅指向有效目标时染淡红，其余保持原色；整体 90% 不透明度（alpha 230）与尾部渐变相乘。
local arrowMat = Material("materials/kards/ui/pointing_arrow.png", "mips smooth")
local ARROW_TEX_W, ARROW_TEX_H = 256, 128
local ARROW_TINT_VALID = Color(255, 140, 140, 230) -- 淡红（指向有效目标）
local ARROW_TINT_IDLE  = Color(255, 255, 255, 230) -- 原色（其余）

-- 拖拽指向 3D2D 箭头（2026-10-24）：在牌桌板平面（KARDS.Animation.Board2D.CardZ 对应的
-- 世界高度）绘制贴图箭头——起点 = 拖拽卡原点投影到平面，终点 = 鼠标射线 ∩ 平面（该点
-- 在鼠标射线上，屏幕投影恰为鼠标位置，即「箭头头部在鼠标处」）；箭头长度 = 两点距离
--（贴图整幅映射，头部尖端贴矩形右缘中点 = 终点），宽度按贴图纵横比随长度缩放；
-- ignoreZ（OverrideDepthEnable）绘制保证不被卡牌/模型遮挡（与原 HUD 连线同级可见性）。
-- 仅拖拽指向模式（dragCard.pointing）；单位操作（cl_battle_ops.lua）仍走原 HUD 连线样式。
hook.Add("PostDrawTranslucentRenderables", "KardsPointingArrow3D", function(_, bSkybox)
    if bSkybox then return end
    local dragCard = KARDS.BattleState.dragCard
    if not dragCard or not dragCard.pointing then return end
    local ent = dragCard.ent
    local inTable = KARDS.BattleState.inTable
    if not IsValid(ent) or not inTable or not IsValid(inTable.ent) then return end
    local tableEnt = inTable.ent
    local planeZ = tableEnt:LocalToWorld(Vector(0, 0, KARDS.Animation.Board2D.CardZ)).z
    local cardPos = ent:GetPos()
    local startW = Vector(cardPos.x, cardPos.y, planeZ)
    -- 鼠标射线 ∩ 板平面（射线朝向桌面之外时无解，跳过本帧）
    local vp, vd = KARDS.MouseRay(gui.MouseX(), gui.MouseY())
    if not vd or vd.z == 0 then return end
    local t = (planeZ - vp.z) / vd.z
    if t <= 0 then return end
    local endW = vp + vd * t
    local dir = Vector(endW.x - startW.x, endW.y - startW.y, 0)
    local len = dir:Length()
    if len < 4 then return end -- 鼠标压在卡上，箭头过短不绘制
    local yaw = math.deg(math.atan2(dir.y, dir.x))
    local valid = dragCard.validTarget and IsValid(dragCard.validTarget)
    local h = len * ARROW_TEX_H / ARROW_TEX_W
    render.OverrideDepthEnable(true, false) -- 无深度测试（恒可见，同原 HUD 连线）
    cam.Start3D2D(startW, Angle(0, yaw, 0), 1)
        surface.SetMaterial(arrowMat)
        surface.SetDrawColor(valid and ARROW_TINT_VALID or ARROW_TINT_IDLE)
        surface.DrawTexturedRect(0, -h / 2, len, h)
    cam.End3D2D()
    render.OverrideDepthEnable(false, false)
end)

-- 指向反馈绘制（2026-08-12 阶段 B，2026-10-24 改版）：
--   拖拽指向模式：连线与鼠标端箭头改为 3D2D 贴图箭头（KardsPointingArrow3D，头部缩放
--     到鼠标处、颜色随可指向性染色），本 HUD 钩子仅保留合法目标描圈；
--   单位操作（按下在场单位，cl_battle_ops.lua）：维持原样式——起点 = 选中的本方单位
--     实体，合法性 = BS.unitOpTarget（engage/hq/move），直线 + 鼠标端箭头角 + 目标描圈。
-- 指向时的目标文字提示已取消（2026-10-24 用户规格，见 cl_battle_drag.lua 指向段注释），
-- 指向反馈统一为箭头染色 + 目标描圈；松手失败原因提示（PointingFailReason）不变。
hook.Add("HUDPaint", "KardsPointingDraw", function()
    local dragCard = KARDS.BattleState.dragCard
    local opSel = KARDS.BattleState.unitOpSel
    local isPointing = dragCard and dragCard.pointing
    local pointing = isPointing or (opSel and IsValid(opSel))
    if not pointing then return end
    -- 合法目标判定：指向模式 → dragCard.validTarget；单位操作 → unitOpTarget
    local valid, validEnt = false, nil
    if isPointing then
        valid = dragCard.validTarget and IsValid(dragCard.validTarget)
        if valid then validEnt = dragCard.validTarget end
    else
        local t = KARDS.BattleState.unitOpTarget
        valid = t ~= nil
        if valid and t.ent then validEnt = t.ent end
    end
    -- 单位操作连线：起点实体 3D → 屏幕 2D 投影 → 鼠标直线 + 鼠标端箭头角
    if not isPointing then
        local sp = opSel:GetPos():ToScreen()
        local mx, my = gui.MouseX(), gui.MouseY()
        surface.SetDrawColor(valid and POINT_LINE_VALID or POINT_LINE_IDLE)
        surface.DrawLine(sp.x, sp.y, mx, my)
        local ang = math.atan2(my - sp.y, mx - sp.x)
        local alen = 12
        local a1, a2 = ang + math.pi * 0.75, ang - math.pi * 0.75
        surface.DrawLine(mx, my, mx + math.cos(a1) * alen, my + math.sin(a1) * alen)
        surface.DrawLine(mx, my, mx + math.cos(a2) * alen, my + math.sin(a2) * alen)
    end
    -- 合法目标描圈（圆环，16 段短线近似；示意可指向的目标；移动无实体目标不描圈）
    if validEnt then
        surface.SetDrawColor(valid and POINT_LINE_VALID or POINT_LINE_IDLE)
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
