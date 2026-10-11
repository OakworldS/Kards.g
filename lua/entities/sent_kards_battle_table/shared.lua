-- Kards 战斗牌桌实体（Q 菜单生成）
-- 包装前置模组「Simple Static Model Importer」的 sent_pmx_static_imported 实体：
-- 继承其运行时渲染（Draw）与箱体碰撞（ApplyImportedModel → PhysicsInitBox），
-- 生成时自动应用 wooden_table 模型并做 y-up → z-up 轴修正（GLB 竖立模型平躺）。

ENT.Base = "sent_pmx_static_imported"
ENT.Type = "anim"
ENT.PrintName = "Kards牌桌"
ENT.Author = "Kards Team"
ENT.Purpose = "通过前置模组导入的 wooden_table 模型（运行时渲染）"
ENT.Instructions = "生成后自动应用牌桌模型，带静态箱体碰撞（可站立，不可推动）"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.Category = "Kards"
ENT.RenderGroup = RENDERGROUP_BOTH -- 与前置一致：不透明 + 半透明双通道渲染

-- 自注册显示名短语：GMod 名称显示经 language.GetPhrase 处理，未注册短语会被加 # 前缀
-- （如 #Kards牌桌）；同键同值注册后 GetPhrase 原样返回，保证 Q 菜单/属性面板显示正确
if CLIENT then
    language.Add("Kards牌桌", "Kards牌桌")
end

-- ====================================================================
-- 玩家槽位区域（共享：服务端校验进入、客户端渲染提示共用同一套判定）
-- ====================================================================

-- 玩家槽数量（两个玩家槽，位于牌桌长轴两端）
ENT.SlotCount = 2

-- 槽位中心在牌桌局部坐标的位置（local 单位）
-- 玩家槽分布在牌桌**长边（y 轴）两侧**（玩家隔着桌子面对面）：槽中心在长边外 29 单位处
-- 轴依据（Blender 实测 + 游戏内验证）：wooden_table 实体几何**长边沿 y 轴**（约 ±45）、宽边沿 x 轴（约 ±22.5）；
--   （manifest bounds x ±15 / y ±7.5 为导入前原始数据，实测实际朝向长边为 y 轴）
ENT.SlotLocalPos = {
    [1] = Vector(0, 52, 0),  -- 槽位 1：+y 端（长边一侧）
    [2] = Vector(0, -52, 0), -- 槽位 2：-y 端（长边另一侧）
}

-- 槽位检测半径（玩家位置到槽中心的 3D 距离，含走动余量）
-- 取 40：槽中心在长边外 29 单位处，半径 40 覆盖长边两侧站立区（y 端 12~92），
-- 且不会把牌桌短边侧（x 侧）误判为槽位（x=40,y=0 处到槽中心距离 ≈66>40）
ENT.SlotRadius = 40

-- 槽位中心的世界坐标（经 LocalToWorld 随牌桌位置/朝向旋转）
-- @param slot number 槽位编号（1/2）
-- @return Vector
function ENT:GetSlotWorldPos(slot)
    return self:LocalToWorld(self.SlotLocalPos[slot] or Vector(0, 0, 0))
end

-- 返回玩家所在的槽位编号（1/2）；不在任何槽位范围内返回 nil
-- 判定规则：玩家水平投影在牌桌碰撞盒内（走上/站在牌桌上）不算槽位——槽位只在牌桌两侧
-- @param ply Player
-- @return number|nil
function ENT:GetPlayerSlot(ply)
    if not IsValid(ply) then return nil end
    local pos = ply:GetPos()
    -- 排除牌桌本体：玩家水平投影在桌体碰撞盒（OBB）内即视为在牌桌上，不算槽位
    local localPos = self:WorldToLocal(pos)
    local mins, maxs = self:OBBMins(), self:OBBMaxs()
    if localPos.x >= mins.x and localPos.x <= maxs.x and
       localPos.y >= mins.y and localPos.y <= maxs.y then
        return nil
    end
    -- 槽位半径判定（玩家在牌桌两侧的槽位区域）
    local r2 = self.SlotRadius * self.SlotRadius
    for i = 1, self.SlotCount do
        if pos:DistToSqr(self:GetSlotWorldPos(i)) <= r2 then
            return i
        end
    end
    return nil
end

-- 宽面判定：玩家是否站在牌桌**宽边（x 轴）**外侧中段（组卡模式切换入口）
-- 与槽位判定（长边 y 两端）互斥：宽面限制 |y| < 12（宽边中段），槽位区 y 从 ±12 起
-- （槽中心 y=±52、半径 40 → y ∈ 12~92）；宽面 |x| 在桌宽外 40 单位内
-- @param ply Player
-- @return boolean
function ENT:IsAtWideSide(ply)
    if not IsValid(ply) then return false end
    local localPos = self:WorldToLocal(ply:GetPos())
    -- 排除牌桌本体（同上）：在桌体上不算宽面
    local mins, maxs = self:OBBMins(), self:OBBMaxs()
    if localPos.x >= mins.x and localPos.x <= maxs.x and
       localPos.y >= mins.y and localPos.y <= maxs.y then
        return false
    end
    local halfW = (maxs.x - mins.x) / 2
    local distX = math.abs(localPos.x) - halfW
    return distX >= 0 and distX <= 40 and math.abs(localPos.y) < 12
end

-- ====================================================================
-- 进入后摄像头视角（共享：客户端进入接管时计算视角）
-- ====================================================================

-- 进入后摄像头位置（牌桌局部坐标）：宽边（x 轴）外侧上方，面向牌桌中心俯视。
-- 宽边为 x 轴（半宽约 22.5），取 x=-70 在宽边外、z=30 高处（桌面顶约 z=18，30 为继续下移后的贴近桌面的平视高度，配合视角上抬）；fov 75 可覆盖全桌。
-- 注：P1/P2 位置相同，双方视角差异由相机 yaw（xy 平面旋转角）区分，见
-- cl_init.lua KardsTableBattleStart 对局开始动画的目标相机角度。
ENT.SlotCameraLocalPos = Vector(-70, 0, 30)

-- 进入后摄像头世界坐标（经 LocalToWorld 随牌桌位置/朝向旋转）
-- @return Vector
function ENT:GetSlotCameraWorldPos()
    return self:LocalToWorld(self.SlotCameraLocalPos)
end

-- Q 菜单显式注册（2026-09-13 修复：与 sent_kards_unit_test 同款写法）。
-- GMod 引擎对 Spawnable=true 的实体自动 list.Set("SpawnableEntities")，Category 取
-- ENT.Category；此处显式注册为双保险，保证 Q 菜单 → Entities → Kards 分类显示，
-- 且覆盖自动注册的 Name（避免 # 前缀问题）。两端各自注册（Q 菜单列表在客户端填充）
if SERVER then
    list.Set("SpawnableEntities", "sent_kards_battle_table", {
        Name = "Kards牌桌",
        Category = "Kards",
        Order = 1,
    })
end

if CLIENT then
    list.Set("SpawnableEntities", "sent_kards_battle_table", {
        Name = "Kards牌桌",
        Category = "Kards",
        Order = 1,
    })
end
