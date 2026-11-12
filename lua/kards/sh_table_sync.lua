--[[
    牌桌消息收发契约（sh_table_sync.lua，2026-11-08，见 docs/adr/0007-牌桌消息收发契约.md）

    职责：把每个 net 事件的字段布局收成一份声明式描述符，发送端与接收端都从同一份
    描述符生成，写序不再有第二份实现。

    描述符是字段数组，按顺序决定线上字节布局：
      { type = "entity", key = "table" }
      { type = "uint8",  key = "firstSlot" }
      { type = "bool",   key = "hasEnemy" }
      { type = "string", key = "enemyNick", cond = "hasEnemy" }
      { type = "array",  key = "ents", of = "entity", countBits = 8 }

    cond 指向同 payload 内的布尔字段，仅在其为真时才读写与传输；判定用的是同一
    payload，收发两侧不可能判成不同结果。

    入口：
      KARDS.TableSync.Register(event, fields, handler) 登记通道，客户端建 net.Receive
      KARDS.TableSync.Handler(event, fn)              替换或补设接收回调
      KARDS.TableSync.Broadcast(event, payload, targets) 统一发送，含空接收者守卫
      KARDS.TableSync.Notify(ply, key, ...)           文本通道便捷入口
]]

KARDS = KARDS or {}
KARDS.TableSync = KARDS.TableSync or {}

local TS = KARDS.TableSync

-- 已登记通道：TS.Channels[event] = { fields = 描述符, handler = 接收回调|nil }
TS.Channels = TS.Channels or {}

-- NULL 由引擎提供；离线桩里可能没有，写入缺省实体时用它兜底
local function noneEntity()
    return NULL
end

-- 字段类型表：write 接收字段值，read 返回字段值
TS.Types = {
    entity = {
        write = function(v) net.WriteEntity(v or noneEntity()) end,
        read  = function() return net.ReadEntity() end,
    },
    string = {
        write = function(v) net.WriteString(v or "") end,
        read  = function() return net.ReadString() end,
    },
    bool = {
        write = function(v) net.WriteBool(v and true or false) end,
        read  = function() return net.ReadBool() end,
    },
    int = {
        write = function(v) net.WriteInt(v or 0, 32) end,
        read  = function() return net.ReadInt(32) end,
    },
    uint8 = {
        write = function(v) net.WriteUInt(v or 0, 8) end,
        read  = function() return net.ReadUInt(8) end,
    },
    uint16 = {
        write = function(v) net.WriteUInt(v or 0, 16) end,
        read  = function() return net.ReadUInt(16) end,
    },
    uint32 = {
        write = function(v) net.WriteUInt(v or 0, 32) end,
        read  = function() return net.ReadUInt(32) end,
    },
    float = {
        write = function(v) net.WriteFloat(v or 0) end,
        read  = function() return net.ReadFloat() end,
    },
    vector = {
        write = function(v) net.WriteVector(v or Vector(0, 0, 0)) end,
        read  = function() return net.ReadVector() end,
    },
    angle = {
        write = function(v) net.WriteAngle(v or Angle(0, 0, 0)) end,
        read  = function() return net.ReadAngle() end,
    },
    color = {
        write = function(v) net.WriteColor(v or Color(255, 255, 255, 255)) end,
        read  = function() return net.ReadColor() end,
    },
}

--- 字段是否参与本次传输（无 cond 恒真；有 cond 取 payload 内该布尔字段）
local function FieldActive(field, payload)
    if field.cond then
        return payload[field.cond] and true or false
    end
    return true
end

--- 按描述符顺序写入 payload
-- @param fields table 字段描述符数组
-- @param payload table 字段值表
function TS.Write(fields, payload)
    payload = payload or {}
    for _, field in ipairs(fields) do
        if FieldActive(field, payload) then
            if field.type == "array" then
                local arr = payload[field.key] or {}
                local item = assert(TS.Types[field.of], "TableSync 未知数组元素类型: " .. tostring(field.of))
                net.WriteUInt(#arr, field.countBits or 8)
                for i = 1, #arr do item.write(arr[i]) end
            else
                local scalar = assert(TS.Types[field.type], "TableSync 未知字段类型: " .. tostring(field.type))
                scalar.write(payload[field.key])
            end
        end
    end
end

--- 按描述符顺序读出 payload
-- @param fields table 字段描述符数组
-- @return table payload
function TS.Read(fields)
    local payload = {}
    for _, field in ipairs(fields) do
        if FieldActive(field, payload) then
            if field.type == "array" then
                local item = assert(TS.Types[field.of], "TableSync 未知数组元素类型: " .. tostring(field.of))
                local n = net.ReadUInt(field.countBits or 8)
                local arr = {}
                for i = 1, n do arr[i] = item.read() end
                payload[field.key] = arr
            else
                local scalar = assert(TS.Types[field.type], "TableSync 未知字段类型: " .. tostring(field.type))
                payload[field.key] = scalar.read()
            end
        end
    end
    return payload
end

--- 登记通道
-- 客户端创建 net.Receive；回调在接收时从通道表现取，允许后置 Handler。
-- @param event string net 事件名
-- @param fields table 字段描述符数组
-- @param handler function|nil 接收回调 function(payload, ply)
function TS.Register(event, fields, handler)
    assert(type(event) == "string" and event ~= "", "TableSync.Register 需要事件名")
    assert(type(fields) == "table", "TableSync.Register 需要字段描述符数组")
    local ch = { fields = fields, handler = handler }
    TS.Channels[event] = ch
    if CLIENT and net and net.Receive then
        net.Receive(event, function()
            local payload = TS.Read(ch.fields)
            if ch.handler then ch.handler(payload) end
        end)
    end
end

--- 替换或补设接收回调
function TS.Handler(event, handler)
    local ch = assert(TS.Channels[event], "TableSync.Handler 未登记的通道: " .. tostring(event))
    ch.handler = handler
end

--- 收集有效接收者
-- 目标可为单个玩家、玩家数组或 nil（nil 表示全服广播）。
-- 用 IsPlayer 方法存在与否区分单个实体与数组，避免把空数组误判成单个目标。
local function CollectTargets(targets)
    if targets == nil then return nil end
    if targets.IsPlayer then targets = { targets } end
    local list = {}
    for _, p in ipairs(targets) do
        if IsValid and IsValid(p) and p.IsPlayer and p:IsPlayer() then list[#list + 1] = p end
    end
    return list
end

--- 统一发送
-- 空接收者守卫：目标过滤后为空则直接返回，不调用 net.Start，避免污染
-- 服务端 net.messageStarted（见 table_battledeck.lua 相关注释）。
-- @param event string 已登记的事件名
-- @param payload table 字段值表
-- @param targets player|table|nil 单个玩家、玩家数组或 nil（nil 为 net.Broadcast）
function TS.Broadcast(event, payload, targets)
    local ch = assert(TS.Channels[event], "TableSync.Broadcast 未登记的通道: " .. tostring(event))
    local list = CollectTargets(targets)
    if list ~= nil and #list == 0 then return end
    net.Start(event)
    TS.Write(ch.fields, payload)
    if list == nil then
        net.Broadcast()
    else
        net.Send(list)
    end
end

--- 文本通道（提示通道）便捷入口：服务端按接收者语言解析后只传一个字符串
-- @param ply player 接收者
-- @param key string 翻译键
-- @param ... any string.format 参数
function TS.Notify(ply, key, ...)
    if not (IsValid and IsValid(ply) and ply:IsPlayer()) then return end
    local text = key
    if KARDS.Lang and KARDS.Lang.TFor then
        text = KARDS.Lang.TFor(ply, key, ...)
    end
    TS.Broadcast("KardsTableMsg", { text = text }, { ply })
end

-- 提示通道由本模块自持：Notify 依赖它，调用方只需补设接收回调
TS.Register("KardsTableMsg", {
    { type = "string", key = "text" },
})
