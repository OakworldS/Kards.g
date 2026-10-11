--[[
    Kards 战斗牌桌客户端模块：组卡卡组（堆叠）抗视差 + 保存成功动画
    （cl_deck_pile.lua）

    职责 1：抗视差（仅组卡构建者，即本端槽位 2 且牌桌处于组卡模式）
      卡组堆叠（含总部）各卡的原始相对坐标只沿 y 轴排开，组卡相机位于牌桌中心
      正上方垂直俯视，而堆叠偏在牌桌一角。于是屏幕投影里，除沿 y 的排开位移外，
      每张卡还额外带一个向左/右的固定偏移（卡越高离相机越近，横向投影越大）。
      本模块按「屏幕等距」反算世界坐标消除该偏移：各卡自己的 z（高度）保持不变，
      屏幕 x 统一到堆叠第一张（总部）的屏幕 x，屏幕 y 按第一张的一个 y 步长投影等距
      排开，再把屏幕坐标反投影回三维世界坐标写回实体局部坐标。
      非构建者（对手 / 观战）不写，看到的仍是服务端下发的原始堆叠坐标。

    职责 2：保存成功动画（本桌所有人可见，服务端广播 KardsDeckSaved 触发）
      帧1：所有堆叠卡 xy 收拢到总部（堆叠基准位），z 等距升起成一竖列
           （终点不使用抗视差），缓动 easeOut（先快后慢）。
      帧2：z 落下并摊回卡堆叠放外观，缓动 smooth（平滑）。
      动画由 KARDS.AnimPlayer 驱动（group = "deckSave"），动画期间职责 1 的抗视差
      驱动让位，动画播放完自动恢复。

    坐标约定（客户端读不到服务端 ENT 字段，常量与服务端 table_deckmode.lua 同步）：
      ENT.DeckPileBase  = Vector(27.5, 16.0, 18.43)
      ENT.DeckPileStepY = 1    ENT.DeckPileStepZ = 0.1
      ENT:DeckPileRelPos(idx) = (base.x, base.y - (idx-1)*stepY, base.z + (idx-1)*stepZ)
    堆叠序号由服务端 NW 变量 Kards_PileIndex 下发（UpdatePileTopFlags 统一写入）。

    挂载：cl_init.lua include 本文件（组卡保存按钮段之后）。
]]

KARDS = KARDS or {}

-- 卡组堆叠坐标常量（与服务端 ENT.DeckPileBase / DeckPileStepY / DeckPileStepZ 同步）
local PILE_BASE_X, PILE_BASE_Y, PILE_BASE_Z = 27.5, 16.0, 18.43
local PILE_STEP_Y, PILE_STEP_Z = 1, 0.1

-- 保存动画参数
local SAVE_ANIM_GROUP = "deckSave" -- 并行组名（同组并发播放；抗视差驱动据此让位）
local COLUMN_T1       = 0.8  -- 帧1 时长（秒）：xy 收拢到总部 + z 升起
local COLUMN_T2       = 0.6  -- 帧2 时长（秒）：z 落下 + 摊回卡堆
local COLUMN_LIFT     = 1.5  -- 竖列整体抬升（相对卡堆基准 z）
local COLUMN_GAP      = 0.5  -- 竖列相邻卡 z 间隔（等距，可见）
local COLUMN_MAX_RISE = 8.0  -- 竖列最高抬升上限（防升出相机视野，卡多时压缩间隔，间隔仍等距）

-- 卡组堆叠第 idx 张卡的原始相对坐标（与服务端 ENT:DeckPileRelPos 同式）
local function DeckPileRelPos(idx)
    return Vector(PILE_BASE_X,
                  PILE_BASE_Y - (idx - 1) * PILE_STEP_Y,
                  PILE_BASE_Z + (idx - 1) * PILE_STEP_Z)
end

-- 世界坐标 → 屏幕坐标（像素）。相机参数取 KARDS.BattleCamera 经 CalcView 记录的
-- 渲染相机（与 KARDS.MouseRay 同源，保证正反投影一致）；未接管或点在相机后方返回 nil
local function WorldToScreen(world)
    local ply = LocalPlayer()
    if not IsValid(ply) then return nil end
    local cam = KARDS.BattleCamera
    if not cam or not cam.ViewPos or not cam.ViewAng then return nil end
    local c = cam.Cameras[ply]
    local fov = (c and c.fov) or 75
    local v = world - cam.ViewPos
    local fwd, right, up = cam.ViewAng:Forward(), cam.ViewAng:Right(), cam.ViewAng:Up()
    local depth = v:Dot(fwd)
    if depth <= 0.01 then return nil end
    local tan = math.tan(math.rad(fov) * 0.5)
    local k = (ScrW() / ScrH()) * (3 / 4) -- 与 KARDS.MouseRay 的宽高比垂直半角修正一致
    local ndcX = (v:Dot(right) / depth) / (tan * k)
    local ndcY = (v:Dot(up) / depth) / (tan / k)
    return (ndcX * 0.5 + 0.5) * ScrW(), (0.5 - ndcY * 0.5) * ScrH()
end

-- 屏幕坐标 → 世界坐标（射线 ∩ 指定世界 z 平面）。相机未接管或射线不穿平面返回 nil
local function ScreenToWorldOnPlane(sx, sy, planeZ)
    local pos, dir = KARDS.MouseRay(sx, sy)
    if not pos or not dir or math.abs(dir.z) < 1e-4 then return nil end
    local t = (planeZ - pos.z) / dir.z
    if t <= 0 then return nil end
    return pos + dir * t
end

--[[
    抗视差落位：卡堆第 idx 张卡在本端的局部坐标（rawZ 为该卡自身高度，保持不变）。

    屏幕基准取第一张（总部）原始位的屏幕 x / y，以及一个 y 步长对应的屏幕竖直位移
    stepY；第 idx 张的屏幕落位 = (第一张屏幕 x, 第一张屏幕 y + (idx-1)*stepY)，
    即屏幕 x 全部对齐（消除向左/右的固定偏移）、屏幕 y 等距。再按该卡自身 z 平面
    反投影回世界坐标。相机未接管或反算失败时返回 nil（调用方回退原始坐标）。

    @param tableEnt Entity 牌桌实体
    @param idx      number 堆叠序号（1 起）
    @param rawZ     number 该卡原始相对 z（高度）
    @return Vector|nil 局部坐标
]]
local function PileParallaxRelPos(tableEnt, idx, rawZ)
    local baseLocal = DeckPileRelPos(1)
    local sx0, sy0 = WorldToScreen(tableEnt:LocalToWorld(baseLocal))
    if not sx0 then return nil end
    local sx1, sy1 = WorldToScreen(tableEnt:LocalToWorld(baseLocal - Vector(0, PILE_STEP_Y, 0)))
    if not sx1 then return nil end
    local stepY = sy1 - sy0
    local planeZ = tableEnt:LocalToWorld(Vector(0, 0, rawZ)).z
    local world = ScreenToWorldOnPlane(sx0, sy0 + (idx - 1) * stepY, planeZ)
    if not world then return nil end
    return tableEnt:WorldToLocal(world)
end

-- 遍历本桌堆叠卡（含总部），对每张按堆叠序号执行抗视差落位
local function ApplyPileParallax(tableEnt)
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWString("Kards_CardRole", "") == "deck" then
            local role = ent:GetNWString("Kards_DeckRole", "grid")
            if role == "pile" or role == "hq" then
                local idx = ent:GetNWInt("Kards_PileIndex", 0)
                if idx >= 1 then
                    local v = PileParallaxRelPos(tableEnt, idx, DeckPileRelPos(idx).z)
                    if v then
                        local cur = ent:GetLocalPos()
                        -- 已落位则跳过（避免每帧重复写入）
                        if (cur - v):LengthSqr() > 1e-6 then ent:SetLocalPos(v) end
                    end
                end
            end
        end
    end
end

-- 抗视差驱动（每帧）：仅本端为组卡构建者（槽位 2 + 组卡模式）时执行；
-- 保存动画播放期间让位（AnimPlayer 正在写位姿），动画播完自动恢复
hook.Add("Think", "KardsDeckPileParallax", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local st = KARDS.BattleState
    if not st or not st.inTable or not IsValid(st.inTable.ent) then return end
    if st.inTable.slot ~= 2 then return end
    local tableEnt = st.inTable.ent
    if tableEnt:GetNWString("Kards_Mode", "battle") ~= "deck" then return end
    if KARDS.AnimPlayer and KARDS.AnimPlayer:Any(SAVE_ANIM_GROUP) then return end
    ApplyPileParallax(tableEnt)
end)

--[[
    保存成功动画：收集堆叠卡（含总部）按堆叠序号升序，逐张 3 关键帧播放。
      t=0：当前位姿（省略 pos，由 AnimPlayer 在实际开始时快照）
      t=COLUMN_T1：帧1 终点，xy 收拢到总部（堆叠基准位），z 等距升起成一竖列
                  （不使用抗视差），缓动 easeOut（先快后慢）
      t=COLUMN_T1+COLUMN_T2：帧2 终点，摊回卡堆叠放外观，缓动 smooth（平滑）
    卡堆终点：构建者用抗视差落位（与常驻外观一致，避免动画末跳变），
    非构建者用原始堆叠坐标（与服务端下发布局一致）。
]]
net.Receive("KardsDeckSaved", function()
    local tableEnt = net.ReadEntity()
    if not IsValid(tableEnt) then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    -- 本桌才播：参战桌 / 观战追踪桌，或宽面（组卡查看位置）的旁观者
    local relevant = (KARDS.BattleState and KARDS.BattleState:IsLocalTable(tableEnt))
        or tableEnt:IsAtWideSide(ply)
    if not relevant then return end
    if not KARDS.AnimPlayer then return end
    local isBuilder = KARDS.BattleState and KARDS.BattleState.inTable
        and KARDS.BattleState.inTable.ent == tableEnt and KARDS.BattleState.inTable.slot == 2

    -- 收集堆叠卡（含总部）并按序号升序
    local list = {}
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWString("Kards_CardRole", "") == "deck" then
            local role = ent:GetNWString("Kards_DeckRole", "grid")
            if role == "pile" or role == "hq" then
                local idx = ent:GetNWInt("Kards_PileIndex", 0)
                if idx >= 1 then list[#list + 1] = { ent = ent, idx = idx } end
            end
        end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b) return a.idx < b.idx end)

    -- 竖列等距间隔：卡数多时压缩，避免整列升出相机视野（间隔仍等距、可见）
    local n = #list
    local gap = COLUMN_GAP
    if n > 1 and (n - 1) * gap > COLUMN_MAX_RISE - COLUMN_LIFT then
        gap = math.max(0.05, (COLUMN_MAX_RISE - COLUMN_LIFT) / (n - 1))
    end

    for order, e in ipairs(list) do
        local raw = DeckPileRelPos(e.idx)
        -- 帧1 终点：xy 收拢到总部（堆叠基准位），z 按可见顺序等距升起（不使用抗视差）
        local colPos = Vector(PILE_BASE_X, PILE_BASE_Y,
                             PILE_BASE_Z + COLUMN_LIFT + (order - 1) * gap)
        -- 帧2 终点：摊回卡堆。构建者用抗视差落位，非构建者用原始堆叠坐标
        local endPos = raw
        if isBuilder then
            local v = PileParallaxRelPos(tableEnt, e.idx, raw.z)
            if v then endPos = v end
        end
        KARDS.AnimPlayer:Play(e.ent, {
            { t = 0 },
            { t = COLUMN_T1, pos = colPos, easing = "easeOut" },
            { t = COLUMN_T1 + COLUMN_T2, pos = endPos, easing = "smooth" },
        }, { group = SAVE_ANIM_GROUP })
    end
end)