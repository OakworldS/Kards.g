-- 射线命中统一模块（C-08，2026-11-08）：牌桌客户端「我点了哪张牌」的唯一解释者，
-- 见 docs/adr/0009-射线命中统一.md。
-- 只提供四个概念：鼠标射线、候选、命中阈值、筛选谓词。调用点不写距离公式，
-- 不写阈值数字，也不各自构造射线。
KARDS.HitTest = KARDS.HitTest or {}
local HT = KARDS.HitTest

-- 中心距离命中的阈值（射线到候选中心的垂距平方）。
-- 手感调参只改这里；调用点需要新阈值时必须在此新增具名常量，不得写字面量。
HT.Radii = {
    CardPick = 484,  -- 组卡网格点击（22 的平方）
    Button = 225,    -- 保存按钮与组卡搜索输入框（15 的平方）
    DeckPile = 196,  -- 卡堆悬停（14 的平方）
    Candidate = 100, -- 候选卡命中（10 的平方）
}

-- 鼠标射线：统一走抗视差实现 KARDS.MouseRay（cl_init.lua），消除旧写法在相机接管
-- 时屏幕边缘与鼠标所指偏离的问题。mx / my 省略时取当前鼠标位置。
-- @return Vector|nil 射线起点；Vector|nil 射线方向
function HT.MouseRay(mx, my)
    if not mx or not my then
        mx, my = gui.MouseX(), gui.MouseY()
    end
    return KARDS.MouseRay(mx, my)
end

-- 候选解析：candidates 支持以下形态，均无需调用方转换
--   1) 实体数组，值即实体；
--   2) 以实体为键的布局映射表，值为无关数据；
--   3) 世界坐标点数组，值为 Vector；
--   4) 以上任一形态再嵌套一层（例如 KARDS.FieldCandidates 返回的布局表数组）。
-- 值为 false 的占位（网络尚未传播的候选）自动跳过。
local function ResolveCandidate(key, value)
    if isentity(value) then return value end
    if isentity(key) then return key end
    return value
end

-- 逐项产出候选：实体与坐标点直接产出，表则向下展开一层
local function EachCandidate(candidates, fn)
    for key, value in pairs(candidates or {}) do
        local cand = ResolveCandidate(key, value)
        if cand ~= nil and cand ~= false then
            if isentity(cand) or isvector(cand) then
                fn(cand)
            elseif type(cand) == "table" then
                for innerKey, innerValue in pairs(cand) do
                    local inner = ResolveCandidate(innerKey, innerValue)
                    if inner ~= nil and inner ~= false and (isentity(inner) or isvector(inner)) then
                        fn(inner)
                    end
                end
            end
        end
    end
end

-- 点到射线的垂距平方（射线参数为负时按起点计）
local function DistToRaySqr(origin, dir, point)
    local toPoint = point - origin
    local t = math.max(toPoint:Dot(dir), 0)
    return (origin + dir * t):DistToSqr(point)
end

-- 实体候选的过滤：非实体候选（坐标点）不参与筛选
local function Accept(ent, filter)
    if not isentity(ent) then return true end
    if not IsValid(ent) then return false end
    return filter == nil or filter(ent)
end

-- 中心距离口径：取最近候选，超过 maxSq 不算命中。
-- @param origin Vector 射线起点
-- @param dir    Vector 射线方向
-- @param candidates table 候选表（形态见 EachCandidate）
-- @param maxSq  number|nil 垂距平方上限，省略时不设上限
-- @param filter function|nil 实体筛选谓词，签名 (ent) -> boolean
-- @return Entity|Vector|nil 最近候选；number|nil 对应的垂距平方
function HT.NearestInRay(origin, dir, candidates, maxSq, filter)
    local limit = maxSq or math.huge
    local best, bestD = nil, limit
    EachCandidate(candidates, function(cand)
        if Accept(cand, filter) then
            local point = isentity(cand) and cand:GetPos() or cand
            local d = DistToRaySqr(origin, dir, point)
            if d < bestD then
                best, bestD = cand, d
            end
        end
    end)
    if best == nil then return nil end
    return best, bestD
end

-- 卡面矩形口径：先判射线是否命中卡面矩形，再按中心距离排序。
-- 中心距离只用于排序，命中本身由 KARDS.RayCardHit 决定；非实体候选不参与。
-- @param origin Vector 射线起点
-- @param dir    Vector 射线方向
-- @param candidates table 候选表（形态见 EachCandidate）
-- @param halfW  number 卡面命中半宽
-- @param halfL  number 卡面命中半长
-- @param maxSq  number|nil 垂距平方上限，省略时不设上限
-- @param filter function|nil 实体筛选谓词，签名 (ent) -> boolean
-- @return Entity|nil 最近命中实体；number|nil 对应的垂距平方
function HT.NearestCardFace(origin, dir, candidates, halfW, halfL, maxSq, filter)
    local limit = maxSq or math.huge
    local best, bestD = nil, limit
    EachCandidate(candidates, function(cand)
        if isentity(cand) and Accept(cand, filter) then
            local hit = KARDS.RayCardHit(origin, dir, cand, halfW, halfL)
            if hit then
                local d = DistToRaySqr(origin, dir, cand:GetPos())
                if d < bestD then
                    best, bestD = cand, d
                end
            end
        end
    end)
    if best == nil then return nil end
    return best, bestD
end

-- 业务筛选谓词：调用点只表达「哪些候选算数」，NW 键名收在模块内
local F = {}
HT.Filters = F

function F.Valid(ent)
    return IsValid(ent)
end

function F.Role(role)
    return function(ent)
        return ent:GetNWString("Kards_CardRole", "") == role
    end
end

function F.NotFlipped(ent)
    return not ent:GetNWBool("Kards_GridFlipped", false)
end

function F.IsFlipped(ent)
    return ent:GetNWBool("Kards_GridFlipped", false)
end

function F.IsHQ(ent)
    return ent:GetNWString("Kards_DeckRole", "") == "hq"
end

function F.NotHQ(ent)
    return not F.IsHQ(ent)
end

function F.DeckPile(ent)
    return ent:GetNWBool("Kards_IsBattleDeckPile", false)
end

-- 与逻辑谓词：全部命中才算通过
function HT.All(...)
    local list = { ... }
    return function(ent)
        for i = 1, #list do
            if not list[i](ent) then return false end
        end
        return true
    end
end

-- 或逻辑谓词：任一命中即通过
function HT.Any(...)
    local list = { ... }
    return function(ent)
        for i = 1, #list do
            if list[i](ent) then return true end
        end
        return false
    end
end

-- 视角方向符号：与三选一、抉择两处的原实现一致，收此一处避免逐字重复
HT.Signs = {}
function HT.Signs.Left(viewSlot)
    return (viewSlot == 2) and -1 or 1
end

function HT.Signs.Side(slot)
    return (slot == 1) and 1 or -1
end
