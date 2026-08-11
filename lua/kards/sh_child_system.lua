-- Kards 子物体系统（共享）
-- 牌桌上的子物体（相对牌桌定位的实体）统一由该系统管理，坐标系分两类：
--   相对坐标 = 牌桌局部坐标（table:WorldToLocal / table:LocalToWorld，随牌桌位置/朝向）；
--   世界坐标 = Source 世界坐标（绝对）。
--   统一相对 z 轴：相对坐标的 z 恒为牌桌局部 z（牌桌顶面法线方向）——无论牌桌在
--   世界中如何移动/旋转，相对 z 始终垂直于桌面（这正是桌面卡牌定位的依据：
--   实测坐标固化为 sh_animation.lua 拟 2D 布局坐标系常量）。
-- 经 RegisterChild 注册为子物体的既有实体（组卡卡牌 / 卡组槽卡 / 手牌槽卡等
-- sent_pmx_static_imported）SetParent 绑定牌桌为父级——移动/旋转牌桌时子物体相对
-- 桌面始终不变（无需每帧同步）；定位用 SetLocalPos（父级相对坐标，GMod 官方
-- widget 实体同款模式：SetParent → Spawn → SetLocalPos）。
-- 删除：1 秒内透明度渐变为 0（RENDERMODE_TRANSALPHA + SetColor alpha 由 Think 逐帧
-- 递减），随后销毁并注销。淡出期间子物体仍属于本管理器（GetChildren 仍返回）。
-- 注（re.md T-M3）：空卡占位链路（CreateChild / CreateCardArray / 材质接口 /
-- ApplyChildMaterial / OnEntityCreated 钩子）已停用并删除——牌桌不再创建
-- sent_kards_battle_card 空卡（组卡卡牌走 RegisterChild 接入，见 init.lua
-- EnterDeckMode）；卡面/卡背纹理的现行有效链路是「模型副本 manifest + PNG 落盘 +
-- ClearCache 重建」（组卡 kards_deck、卡组槽 kards_battledeck、手牌槽 kards_handslot
-- 均按 manifest image_path 直接加载，见 cl_init.lua）。sent_kards_battle_card 实体
-- 保留——外观编辑器「生成3D2D卡牌」仍创建该实体（KARDS_Editor_SpawnCard，见
-- sent_kards_battle_card/init.lua），与子物体系统无关联。

KARDS = KARDS or {}
KARDS.ChildSystem = KARDS.ChildSystem or {}

-- 删除淡出时长（秒）：透明度从 255 线性渐变为 0 后销毁
KARDS.ChildSystem.FadeDuration = 1.0

local FadeDuration = KARDS.ChildSystem.FadeDuration

-- ====================================================================
-- 管理器（每张牌桌一个实例，由牌桌实体在 Initialize 创建）
-- ====================================================================
local Manager = {}
Manager.__index = Manager

-- 创建并绑定到一张牌桌的子物体管理器
-- @param tableEnt Entity 牌桌实体（sent_kards_battle_table）
-- @return manager
function KARDS.ChildSystem.New(tableEnt)
    return setmetatable({
        tableEnt = tableEnt, -- 宿主牌桌实体（相对坐标的坐标系基准）
        children = {},       -- 子物体注册表：child 实体 -> true
        fading = {},         -- 淡出中的子物体：child 实体 -> { start = 淡出起始 CurTime }
    }, Manager)
end

-- 子物体是否属于本管理器且仍有效
-- @param child Entity
-- @return boolean
function Manager:_isChild(child)
    return IsValid(child) and self.children[child] == true
end

-- ====================================================================
-- 坐标转换（相对坐标 = 牌桌局部坐标；相对 z 恒为牌桌局部 z，统一相对 z 轴）
-- ====================================================================

-- 世界坐标 → 相对坐标（牌桌局部；经 WorldToLocal，随牌桌位置/朝向换算）
-- @param worldPos Vector 世界坐标
-- @return Vector 相对坐标
function Manager:WorldToRelative(worldPos)
    return self.tableEnt:WorldToLocal(worldPos)
end

-- 相对坐标 → 世界坐标（经 LocalToWorld，随牌桌位置/朝向换算）
-- @param relPos Vector 相对坐标
-- @return Vector 世界坐标
function Manager:RelativeToWorld(relPos)
    return self.tableEnt:LocalToWorld(relPos)
end

-- ====================================================================
-- 注册 / 定位 / 删除
-- ====================================================================

-- 注册一个已存在的实体为牌桌子物体（相对坐标定位 + SetParent 绑定牌桌为父级，
-- 移动/旋转牌桌时相对桌面始终不变）。供组卡卡牌等需要独立模型/材质的子物体接入；
-- 已注册的子物体再次调用仅更新相对坐标。
-- @param child  Entity 已 Spawn 的实体（应已无碰撞无物理，见调用方设置）
-- @param relPos Vector 相对坐标（相对 z 为牌桌局部 z）
-- @return boolean 是否成功
function Manager:RegisterChild(child, relPos)
    if not IsValid(child) then return false end
    if self.children[child] == true then
        return self:SetChildRelPos(child, relPos)
    end
    child:SetParent(self.tableEnt)       -- 父级绑定：保持当前世界偏移并转为相对牌桌的局部偏移
    child:SetLocalPos(relPos)            -- 相对坐标定位（父级相对坐标，官方 widget 实体同款模式）
    child:SetLocalAngles(Angle(0, 0, 0)) -- 平躺面朝上（相对牌桌局部朝向，随牌桌旋转）
    self.children[child] = true
    return true
end

-- 设置一个子物体的相对坐标（相对 z 为牌桌局部 z，始终垂直于桌面）
-- @param child Entity 本管理器的子物体
-- @param relPos Vector 相对坐标
-- @return boolean 是否成功
function Manager:SetChildRelPos(child, relPos)
    if not self:_isChild(child) then return false end
    child:SetLocalPos(relPos)
    return true
end

-- 获得一个子物体的相对坐标
-- @param child Entity
-- @return Vector|nil 相对坐标（非法子物体返回 nil）
function Manager:GetChildRelPos(child)
    if not self:_isChild(child) then return nil end
    return child:GetLocalPos()
end

-- 设置一个子物体的世界坐标（内部转相对坐标后定位，等价 SetChildRelPos + WorldToRelative）
-- @param child Entity
-- @param worldPos Vector 世界坐标
-- @return boolean 是否成功
function Manager:SetChildWorldPos(child, worldPos)
    return self:SetChildRelPos(child, self:WorldToRelative(worldPos))
end

-- 获得一个子物体的世界坐标
-- @param child Entity
-- @return Vector|nil 世界坐标（非法子物体返回 nil）
function Manager:GetChildWorldPos(child)
    if not self:_isChild(child) then return nil end
    return child:GetPos()
end

-- 删除一个子物体：1 秒内透明度渐变为 0，随后销毁（由 Manager:Think 驱动）
-- @param child Entity
-- @return boolean 是否已开始淡出（已在淡出中 / 非法子物体返回 false）
function Manager:RemoveChild(child)
    if not self:_isChild(child) then return false end
    if self.fading[child] then return false end -- 已在淡出中，幂等
    self.fading[child] = { start = CurTime() }
    child:SetRenderMode(RENDERMODE_TRANSALPHA) -- 走透明通道，配合 SetColor alpha 渐变
    return true
end

-- 驱动删除淡出：透明度 255 → 0（FadeDuration 秒），完成后销毁并注销（由牌桌 Think 调用）
function Manager:Think()
    local now = CurTime()
    for child, info in pairs(self.fading) do
        if not IsValid(child) then
            self.fading[child] = nil
            self.children[child] = nil
        else
            local t = (now - info.start) / FadeDuration
            if t >= 1 then
                child:Remove()
                self.fading[child] = nil
                self.children[child] = nil
            else
                -- 透明度线性递减（255 → 0）；SetColor 自动同步到客户端
                child:SetColor(Color(255, 255, 255, math.floor(255 * (1 - t))))
            end
        end
    end
end

-- 返回全部子物体（含淡出中未销毁的）实体列表
-- @return table 子物体实体数组
function Manager:GetChildren()
    local list = {}
    for child in pairs(self.children) do
        if IsValid(child) then
            table.insert(list, child)
        end
    end
    return list
end

-- 立即移除全部子物体（牌桌销毁时调用，不走淡出）
function Manager:Destroy()
    for child in pairs(self.children) do
        if IsValid(child) then child:Remove() end
    end
    self.children = {}
    self.fading = {}
end
