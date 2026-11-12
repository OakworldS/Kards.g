--[[
=======================================================================================
牌桌消息收发契约离线测试
=======================================================================================
不依赖 GMod 环境，在仓库根目录执行：

    lua lua/kards/test/table_sync_test.lua

覆盖范围：
  - 标量字段往返：entity / string / bool / int / uint8 / uint16 / uint32 / float / vector / angle / color
  - 条件字段：cond 为真时传输，为假时跳过
  - 数组字段：长度与逐项往返
  - Broadcast 空接收者守卫：不调用 net.Start
  - Broadcast 过滤无效接收者与单个玩家目标
  - Broadcast 无目标时走 net.Broadcast
  - Notify 只写一个已本地化字符串
  - Register 建 net.Receive 且回调可后设

源文件：lua/kards/sh_table_sync.lua（新建 2026-11-08），对应 docs/adr/0007-牌桌消息收发契约.md
=======================================================================================
]]

CLIENT = true
NULL = setmetatable({}, { __tostring = function() return "NULL" end })

function Vector(x, y, z) return { x = x, y = y, z = z } end
function Angle(p, y, r) return { p = p, y = y, r = r } end
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a } end

function IsValid(v)
    return v ~= nil and v.valid ~= false
end

-- 网络桩：写入进流，读取按同一顺序出流，并按类型校验
local stream = {}
local calls = {}

local function Push(kind, value)
    stream[#stream + 1] = { kind = kind, value = value }
end

local function Pop(kind)
    local frame = table.remove(stream, 1)
    assert(frame, "读取时流已空")
    assert(frame.kind == kind, "读写类型不一致，期望 " .. kind .. " 实际 " .. frame.kind)
    return frame.value
end

local receivers = {}
net = {
    Start = function(event) calls[#calls + 1] = "start:" .. event end,
    Send = function(targets) calls[#calls + 1] = "send:" .. tostring(#targets) end,
    Broadcast = function() calls[#calls + 1] = "broadcast" end,
    Receive = function(event, fn) receivers[event] = fn end,

    WriteEntity = function(v) Push("entity", v) end,
    WriteString = function(v) Push("string", v) end,
    WriteBool = function(v) Push("bool", v) end,
    WriteInt = function(v, bits) Push("int:" .. bits, v) end,
    WriteUInt = function(v, bits) Push("uint:" .. bits, v) end,
    WriteFloat = function(v) Push("float", v) end,
    WriteVector = function(v) Push("vector", v) end,
    WriteAngle = function(v) Push("angle", v) end,
    WriteColor = function(v) Push("color", v) end,

    ReadEntity = function() return Pop("entity") end,
    ReadString = function() return Pop("string") end,
    ReadBool = function() return Pop("bool") end,
    ReadInt = function(bits) return Pop("int:" .. bits) end,
    ReadUInt = function(bits) return Pop("uint:" .. bits) end,
    ReadFloat = function() return Pop("float") end,
    ReadVector = function() return Pop("vector") end,
    ReadAngle = function() return Pop("angle") end,
    ReadColor = function() return Pop("color") end,
}

-- 语言桩：把键加前缀，验证 Notify 走的是本地化结果
KARDS = {
    Lang = {
        TFor = function(ply, key) return "T:" .. key end,
    },
}

dofile("lua/kards/sh_table_sync.lua")
local TS = KARDS.TableSync
assert(TS, "收发契约模块未挂到 KARDS.TableSync")

local passed = 0
local function ok(cond, message)
    assert(cond, message)
    passed = passed + 1
end

local function reset()
    stream = {}
    calls = {}
end

-- 1. 标量字段往返
local scalars = {
    { type = "entity", key = "ent" },
    { type = "string", key = "text" },
    { type = "bool", key = "flag" },
    { type = "int", key = "ival" },
    { type = "uint8", key = "u8" },
    { type = "uint16", key = "u16" },
    { type = "uint32", key = "u32" },
    { type = "float", key = "fval" },
    { type = "vector", key = "vec" },
    { type = "angle", key = "ang" },
    { type = "color", key = "col" },
}
local entityA = { name = "entA" }
local payload = {
    ent = entityA,
    text = "手牌卡名",
    flag = true,
    ival = -17,
    u8 = 250,
    u16 = 60000,
    u32 = 4000000000,
    fval = 3.25,
    vec = Vector(1, 2, 3),
    ang = Angle(10, 20, 30),
    col = Color(10, 20, 30, 255),
}
reset()
TS.Write(scalars, payload)
local back = TS.Read(scalars)
ok(back.ent == entityA, "实体字段往返失败")
ok(back.text == "手牌卡名", "字符串字段往返失败")
ok(back.flag == true, "布尔字段往返失败")
ok(back.ival == -17, "有符号整数字段往返失败")
ok(back.u8 == 250 and back.u16 == 60000 and back.u32 == 4000000000, "各宽无符号整数字段往返失败")
ok(math.abs(back.fval - 3.25) < 0.0001, "浮点字段往返失败")
ok(back.vec.x == 1 and back.vec.y == 2 and back.vec.z == 3, "向量字段往返失败")
ok(back.ang.p == 10 and back.ang.y == 20 and back.ang.r == 30, "角度字段往返失败")
ok(back.col.r == 10 and back.col.a == 255, "颜色字段往返失败")
ok(#stream == 0, "往返后流应读空，读写次数不一致")

-- 2. 条件字段，条件为真
local conditional = {
    { type = "bool", key = "hasEnemy" },
    { type = "string", key = "enemyNick", cond = "hasEnemy" },
    { type = "string", key = "enemySteamID", cond = "hasEnemy" },
    { type = "string", key = "tail" },
}
reset()
TS.Write(conditional, { hasEnemy = true, enemyNick = "对手", enemySteamID = "7656", tail = "尾" })
local condBack = TS.Read(conditional)
ok(condBack.hasEnemy == true, "条件为真时布尔字段应传出")
ok(condBack.enemyNick == "对手" and condBack.enemySteamID == "7656", "条件为真时条件字段应传出")
ok(condBack.tail == "尾", "条件字段之后的常规字段应仍对齐")

-- 3. 条件字段，条件为假
reset()
TS.Write(conditional, { hasEnemy = false, tail = "尾" })
local condBack2 = TS.Read(conditional)
ok(condBack2.hasEnemy == false, "条件为假时布尔字段应传出")
ok(condBack2.enemyNick == nil and condBack2.enemySteamID == nil, "条件为假时条件字段不应传出")
ok(condBack2.tail == "尾", "条件为假时后续常规字段仍应正确对齐")
ok(#stream == 0, "条件分支后流应读空")

-- 4. 数组字段往返
local withArray = {
    { type = "uint8", key = "countHint" },
    { type = "array", key = "ents", of = "entity", countBits = 8 },
    { type = "array", key = "names", of = "string", countBits = 8 },
}
reset()
TS.Write(withArray, { countHint = 9, ents = { entityA, entityA }, names = { "甲", "乙", "丙" } })
local arrBack = TS.Read(withArray)
ok(arrBack.countHint == 9, "数组前置字段往返失败")
ok(#arrBack.ents == 2 and arrBack.ents[1] == entityA, "实体数组往返失败")
ok(#arrBack.names == 3 and arrBack.names[3] == "丙", "字符串数组往返失败")

-- 5. 空接收者守卫：不调用 net.Start
local playerA = { valid = true, IsPlayer = function() return true end }
local playerDead = { valid = false, IsPlayer = function() return true end }
local playerStub = { valid = true, IsPlayer = function() return false end }

reset()
TS.Broadcast("KardsTableMsg", { text = "x" }, {})
ok(#calls == 0, "空接收者时不应调用 net.Start")
reset()
TS.Broadcast("KardsTableMsg", { text = "x" }, { playerDead })
ok(#calls == 0, "无效接收者过滤后为空时不应调用 net.Start")
reset()
TS.Broadcast("KardsTableMsg", { text = "x" }, { playerStub })
ok(#calls == 0, "非玩家实体过滤后为空时不应调用 net.Start")

-- 6. 有效接收者与单个玩家目标
reset()
TS.Broadcast("KardsTableMsg", { text = "y" }, { playerA })
ok(calls[1] == "start:KardsTableMsg", "有效接收者应开始消息")
ok(calls[2] == "send:1", "有效接收者应以玩家数组发送")
reset()
TS.Broadcast("KardsTableMsg", { text = "y" }, playerA)
ok(calls[1] == "start:KardsTableMsg" and calls[2] == "send:1", "单个玩家目标应被包成数组发送")

-- 7. 无目标时走 net.Broadcast
reset()
TS.Broadcast("KardsTableMsg", { text = "z" }, nil)
ok(calls[1] == "start:KardsTableMsg" and calls[2] == "broadcast", "无目标时应走 net.Broadcast")

-- 8. Notify 只写一个已本地化字符串
reset()
TS.Notify(playerA, "msg.opponent_offline")
ok(#calls == 2, "Notify 应只构成一次发送")
ok(calls[1] == "start:KardsTableMsg" and calls[2] == "send:1", "Notify 发送形态不符")
ok(#stream == 1 and stream[1].kind == "string", "Notify 线上应只有一个字符串")
ok(stream[1].value == "T:msg.opponent_offline", "Notify 应写入本地化后的文本")
reset()
TS.Notify(playerDead, "msg.opponent_offline")
ok(#calls == 0, "Notify 对无效接收者不应发送")

-- 9. Register 建 net.Receive，回调可后设
local got = nil
ok(receivers["KardsTableMsg"] ~= nil, "提示通道应在加载时登记 net.Receive")
TS.Handler("KardsTableMsg", function(payload) got = payload end)
reset()
net.WriteString("回调文本")
receivers["KardsTableMsg"]()
ok(got and got.text == "回调文本", "接收回调应收到描述符读出的 payload")

print(string.format("牌桌消息收发契约测试通过 %d 项", passed))
