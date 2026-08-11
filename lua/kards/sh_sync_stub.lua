--[[
    联机防作弊与同步骨架 (Net Sync Stub)（readme 四：联机防作弊与同步规则）

    在真实网络层就绪前，用纯 Lua 数据层模拟"客户端请求 → 服务端权威执行 +
    实时同步校验 + 异常同步处理"，验证 readme 四三条规则的语义：

      ① 服务端权威判定：玩家在牌桌上的所有操作仅可向客户端发送执行请求，最终由服务端统一执行
         → ClientRequest(tableID, player, operation, clientSig)：玩家请求入口只提交执行意图
           （由服务端构造的内核闭包），服务端统一执行（如 Battle:SimDeploy），
           成功后重算权威签名并向所有客户端分发（骨架：更新 ClientViews 模拟广播）。
      ② 实时同步校验：对局过程中，服务端持续校验玩家数据与服务端数据是否一致，防止本地网络作弊与参数篡改
         → 每次请求必须携带客户端本地状态签名（clientSig），服务端与权威签名 BuildSignature 比对；
           不一致 → 判定不同步（desync）。
      ③ 异常同步处理：检测到双方数据不同步时，暂停客户端玩家所有操作，先对客户端执行全服数据同步，
           同步完成后再开放玩家操作权限
         → 判定 desync 后 Suspended[player] = true（暂停该客户端所有操作）；
           SyncClient(player) 将权威快照写入客户端视图并清除暂停，恢复操作权限。

    多牌桌按 tableID 实例隔离（与 TickLog / EngineHooks / Battlefield / CommandPoints 一致）。
    与规则层作弊检测（Battlefield.Stop，前线阵营冲突 → 停止对局）区分：
    desync 只暂停异常客户端并触发全量同步，对局继续。
    真实网络层（net.Receive / net.Start 等）为正式版接缝，本文件仅提供数据层与语义验证。
]]

KARDS = KARDS or {}
KARDS.NetSync = KARDS.NetSync or {}

-- 实例：KARDS.NetSync.Instances[tableID] = {
--   ClientViews = { [player] = string }, -- 服务端分发给各客户端的最近状态签名（骨架：广播记录）
--   Suspended  = { [player] = boolean }, -- 是否暂停该客户端所有操作（异常同步处理中）
-- }
KARDS.NetSync.Instances = KARDS.NetSync.Instances or {}

--[[
    初始化牌桌的联机同步空间（对局开始调用；Battle:StartBattle 已接入）

    开局即向所有客户端分发一次权威快照（ClientViews = 初始权威签名），
    模拟"对局开始服务端向客户端全量同步建立视图"。

    @param tableID string 牌桌唯一标识符
    @param players table|nil 玩家标识列表（缺省 {"P1", "P2"}）
    @return table 新创建的同步实例
]]
function KARDS.NetSync:InitTable(tableID, players)
    local sig = self:BuildSignature(tableID)
    local views, suspended = {}, {}
    for _, p in ipairs(players or { "P1", "P2" }) do
        views[p] = sig
        suspended[p] = false
    end
    self.Instances[tableID] = { ClientViews = views, Suspended = suspended }
    return self.Instances[tableID]
end

-- 获取指定牌桌的同步实例（不存在返回 nil）
function KARDS.NetSync:Get(tableID)
    return self.Instances[tableID]
end

--[[
    客户端请求入口（服务端权威判定 + 实时同步校验 + 暂停拦截，readme 四）

    @param tableID    string 牌桌唯一标识符
    @param player     string 发起请求的玩家
    @param operation  function 服务端内核闭包（由服务端构造，执行统一操作语义，
                      如 function() return KARDS.Battle:SimDeploy(card, 1) end）
    @param clientSig  string 客户端本地状态签名（随请求上报，服务端校验是否与服务端一致）
    @return boolean, string|nil 是否执行成功；失败原因（"suspended" 暂停中 / "desync" 数据不同步）
]]
function KARDS.NetSync:ClientRequest(tableID, player, operation, clientSig)
    local inst = self.Instances[tableID]
    if not inst then return false, "no_table" end
    -- ③ 暂停中的客户端：拒绝所有操作（readme 四-3 暂停客户端玩家所有操作）
    if inst.Suspended[player] then return false, "suspended" end
    -- ② 实时同步校验：客户端上报签名必须与服务端权威签名一致（readme 四-2 防参数篡改）
    local authSig = self:BuildSignature(tableID)
    if clientSig ~= authSig then
        -- 数据不同步：暂停该客户端所有操作，写 desync 刻供审计（readme 四-3）
        inst.Suspended[player] = true
        local hq = KARDS.Battlefield:GetHQ(tableID, player)
        if hq then KARDS.TickLog:Push(tableID, hq, { "desync" }, {}) end
        return false, "desync"
    end
    -- ① 服务端权威执行（客户端仅发送执行请求，最终由服务端统一执行，readme 四-1）
    local ok, reason = operation()
    if ok then
        -- 服务端执行后向所有客户端分发最新权威签名（骨架：广播记录；正式版为网络推送）
        local newSig = self:BuildSignature(tableID)
        for p in pairs(inst.Suspended) do inst.ClientViews[p] = newSig end
    end
    return ok, reason
end

--[[
    异常同步处理：对客户端执行全服数据同步，同步完成后再开放操作权限（readme 四-3）

    将服务端权威快照写入该客户端视图（骨架：ClientViews[player] = 权威签名），
    清除暂停标志，写 sync 刻供审计。

    @param tableID string 牌桌唯一标识符
    @param player  string 待同步的客户端玩家
    @return boolean 是否成功
]]
function KARDS.NetSync:SyncClient(tableID, player)
    local inst = self.Instances[tableID]
    if not inst then return false end
    inst.ClientViews[player] = self:BuildSignature(tableID)
    inst.Suspended[player] = false
    local hq = KARDS.Battlefield:GetHQ(tableID, player)
    if hq then KARDS.TickLog:Push(tableID, hq, { "sync" }, {}) end
    return true
end

-- 查询：该客户端是否被暂停（异常同步处理中）
function KARDS.NetSync:IsSuspended(tableID, player)
    local inst = self.Instances[tableID]
    return inst and inst.Suspended[player] or false
end

-- 查询：服务端持有的该客户端最近视图签名（骨架广播记录；客户端据此上报 clientSig）
function KARDS.NetSync:GetClientView(tableID, player)
    local inst = self.Instances[tableID]
    return inst and inst.ClientViews[player] or nil
end

--[[
    服务端权威签名：对影响对局结果的玩家数据做稳定摘要（战场布局 + 指挥点）

    骨架范围：战场（支援阵线 ×2 的 5 槽 + 前线 5 槽 + 控制方 + 作弊/停止标志）、
    指挥点（槽 / 点数）。时间刻不计入——刻度是服务端 append-only 审计记录，
    客户端不可篡改，不属于"玩家数据"（readme 四-2）。正式版纳入手牌 / 卡组等全部玩家数据。
    客户端本地视图与之不一致 → 判定不同步。

    @param tableID string 牌桌唯一标识符
    @return string 签名
]]
function KARDS.NetSync:BuildSignature(tableID)
    local parts = {}
    local bf = KARDS.Battlefield:Get(tableID)
    if bf then
        local owners = {}
        for o in pairs(bf.SupportLines) do table.insert(owners, o) end
        table.sort(owners)
        for _, o in ipairs(owners) do
            for i = 1, KARDS.Battlefield.SLOT_COUNT do
                local c = bf.SupportLines[o][i]
                table.insert(parts, (c and c:GetID()) or "nil")
            end
        end
        for i = 1, KARDS.Battlefield.MAX_FRONTLINE_SLOTS do
            local c = bf.Frontline[i]
            table.insert(parts, (c and c:GetID()) or "nil")
        end
        table.insert(parts, tostring(bf.FrontlineOwner or "nil"))
        table.insert(parts, tostring(bf.Cheater or "nil"))
        table.insert(parts, tostring(bf.Stopped))
    end
    local cp = KARDS.CommandPoints:Get(tableID)
    if cp then
        local players = {}
        for p in pairs(cp.Points) do table.insert(players, p) end
        table.sort(players)
        for _, p in ipairs(players) do
            table.insert(parts, tostring(cp.Slots[p] or 0) .. "/" .. tostring(cp.Points[p] or 0))
        end
    end
    return table.concat(parts, "|")
end
