--[[
=======================================================================================
射线命中模块离线测试
=======================================================================================
不依赖 GMod 环境，在仓库根目录执行：

    lua lua/kards/test/hit_test_test.lua

覆盖范围：
  - 中心距离口径：命中、阈值边界、最近排序
  - 四种候选形态：实体数组、实体为键的映射、坐标点、嵌套布局表
  - 筛选谓词：All / Any 真值表、无效实体跳过
  - 卡面矩形口径：仅矩形命中参与，按中心距离排序
  - 视角符号与鼠标射线转调

源文件：新建（2026-11-08），对应 docs/adr/0009-射线命中统一.md
=======================================================================================
]]

-- 向量桩：只需满足 HitTest 用到的运算符与方法
local VectorMeta = {}
VectorMeta.__index = VectorMeta
local function Vec(x, y, z)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0, __vector = true }, VectorMeta)
end
function VectorMeta.__sub(a, b) return Vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function VectorMeta.__add(a, b) return Vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function VectorMeta.__mul(a, b)
    if type(a) == "number" then return Vec(b.x * a, b.y * a, b.z * a) end
    return Vec(a.x * b, a.y * b, a.z * b)
end
function VectorMeta:Dot(other) return self.x * other.x + self.y * other.y + self.z * other.z end
function VectorMeta:DistToSqr(other)
    local dx, dy, dz = self.x - other.x, self.y - other.y, self.z - other.z
    return dx * dx + dy * dy + dz * dz
end

-- 环境桩
function isvector(v) return type(v) == "table" and v.__vector == true end
function isentity(v) return type(v) == "table" and v.__entity == true end
function IsValid(ent) return isentity(ent) and ent.__valid ~= false end

local function Ent(x, y, z, valid)
    local e = { __entity = true, __valid = (valid ~= false), __pos = Vec(x, y, z) }
    function e:GetPos() return self.__pos end
    function e:GetNWString() return "" end
    function e:GetNWBool() return false end
    return e
end

KARDS = {}
KARDS.MouseRay = function(mx, my)
    return Vec(0, 0, 0), Vec(mx or 1, my or 0, 0)
end
-- 卡面矩形桩：由实体自身标记是否命中，便于精确控制参与集合
KARDS.RayCardHit = function(origin, dir, ent, halfW, halfL)
    if ent.__face == false then return nil end
    return 1
end

dofile("lua/entities/sent_kards_battle_table/cl_hit_test.lua")
local HT = KARDS.HitTest
assert(HT, "命中模块未注册 KARDS.HitTest")

local passed = 0
local function ok(cond, message)
    assert(cond, message)
    passed = passed + 1
end

-- 1. 阈值常量
ok(HT.Radii.CardPick == 484, "组卡点击阈值应为 22 的平方")
ok(HT.Radii.Button == 225, "按钮阈值应为 15 的平方")
ok(HT.Radii.DeckPile == 196, "卡堆阈值应为 14 的平方")
ok(HT.Radii.Candidate == 100, "候选阈值应为 10 的平方")

-- 2. 中心距离口径与边界
local origin, dir = Vec(0, 0, 0), Vec(1, 0, 0)
local a = Ent(5, 3, 0) -- 垂距平方 9
local hit, d = HT.NearestInRay(origin, dir, { a }, 10)
ok(hit == a and d == 9, "垂距平方 9 应在阈值 10 内命中")
ok(HT.NearestInRay(origin, dir, { a }, 8) == nil, "垂距平方 9 超过阈值 8 不应命中")
ok(HT.NearestInRay(origin, dir, { a }, 9) == nil, "等于阈值不算命中（与原实现一致）")

-- 3. 最近排序
local nearEnt, farEnt = Ent(5, 2, 0), Ent(5, 4, 0)
local best, bestD = HT.NearestInRay(origin, dir, { farEnt, nearEnt }, 100)
ok(best == nearEnt and bestD == 4, "应取中心距离更近的候选")

-- 4. 四种候选形态
local e1, e2 = Ent(5, 0, 0), Ent(5, 1, 0)
ok(HT.NearestInRay(origin, dir, { e1, e2 }, 100) == e1, "实体数组应可解析")

local map = {}
map[e2] = "slot"
ok(HT.NearestInRay(origin, dir, map, 100) == e2, "以实体为键的映射应可解析")

local p1 = Vec(5, 1, 0)
ok(HT.NearestInRay(origin, dir, { p1 }, 100) == p1, "坐标点数组应可解析")

local layoutA = { [e2] = 1 }
local layoutB = { [e1] = 2 }
ok(HT.NearestInRay(origin, dir, { layoutA, layoutB }, 100) == e1, "嵌套布局表应可解析")

-- 5. false 占位跳过
ok(HT.NearestInRay(origin, dir, { false, e1 }, 100) == e1, "false 占位应跳过")

-- 6. 筛选谓词
ok(HT.Filters.Valid(e1) == true, "有效实体应通过 Valid")
ok(HT.Filters.Valid(Ent(0, 0, 0, false)) == false, "无效实体不应通过 Valid")
local invalid = Ent(5, 0, 0, false)
ok(HT.NearestInRay(origin, dir, { invalid }, 100) == nil, "无效实体不应作为候选")

local roleEnt = Ent(5, 0, 0)
roleEnt.GetNWString = function() return "deck" end
ok(HT.Filters.Role("deck")(roleEnt) == true, "Role 应匹配 NW 角色")
ok(HT.Filters.Role("hq")(roleEnt) == false, "Role 不应匹错角色")

local all = HT.All(HT.Filters.Valid, HT.Filters.NotHQ)
ok(all(roleEnt) == true, "All 全部为真时通过")
ok(all(Ent(0, 0, 0, false)) == false, "All 任一为假时不通过")
local any = HT.Any(HT.Filters.Valid, HT.Filters.NotHQ)
ok(any(roleEnt) == true, "Any 任一为真时通过")
ok(HT.Any(function() return false end, function() return false end)(roleEnt) == false, "Any 全假时不通过")

-- 7. 卡面矩形口径
local face1, face2, noFace = Ent(5, 0, 0), Ent(5, 2, 0), Ent(5, 0, 0)
noFace.__face = false
ok(HT.NearestCardFace(origin, dir, { noFace }, 10, 10, nil) == nil, "矩形未命中的实体不应入选")
local faceBest = HT.NearestCardFace(origin, dir, { face2, face1 }, 10, 10, nil)
ok(faceBest == face1, "矩形命中的候选应按中心距离取最近")
local faceFar = Ent(5, 3, 0) -- 垂距平方 9
ok(HT.NearestCardFace(origin, dir, { faceFar }, 10, 10, 4) == nil, "矩形命中但中心距离超出上限不应入选")

-- 8. 视角符号
ok(HT.Signs.Left(2) == -1 and HT.Signs.Left(1) == 1, "视角左侧符号不符")
ok(HT.Signs.Side(1) == 1 and HT.Signs.Side(2) == -1, "发起方一侧符号不符")

-- 9. 鼠标射线转调
local mo, md = HT.MouseRay(10, 20)
ok(mo and md and md.x == 10 and md.y == 20, "鼠标射线应转调 KARDS.MouseRay")

-- 10. 阈值下限与无候选
ok(HT.NearestInRay(origin, dir, {}, 100) == nil, "空候选应返回 nil")
ok(HT.NearestInRay(origin, dir, nil, 100) == nil, "候选为 nil 应返回 nil")

print(string.format("hit_test_test: %d 项通过", passed))
