--[[
    战场阵线偶数偏移驱动 (Battlefield Center Shift，共享，纯逻辑层)

    客户端"偶数阵线整线右移"机制的纯逻辑驱动（2026-08-05 定，来源：用户自动居中需求）：
      - 自动居中时，偶数张牌的阵线"居中靠左"（右端多出 1 个空槽，见 sh_battlefield.lua）
      - 为在视觉上保持对称，当造成某阵线上为偶数的时间刻结束后，该阵线全部卡牌
        同时于 0.3 秒内线性向右移动 0.5 * SPACING（= 0.5）
      - 本模块只记录 / 返回移量（GetShift），不直接写卡牌属性；渲染层（客户端）
        在时间刻结束后调用 OnTickEnd 刷新记录，再以 GetShift 采样驱动整线卡牌做
        0.3 秒线性右移动画（复用 KARDS.Animation:Animate(0.3, "pos.x", "linear", "add", shift)）

    阵线奇偶判定与 sh_battlefield.lua 的 CountUnits 一致（含总部）：
      - 支援阵线按 owner 独立判定
      - 前线取 FrontlineOwner 判定（前线为空不偏移）
      - 空阵线（0 张卡）不偏移

    多牌桌按 tableID 分实例隔离（与 TickLog / Battlefield / NetSync 的 tableID 隔离体系一致）。
    纯 Lua 实现，不依赖 GMod API。
]]

KARDS = KARDS or {}
---@class BattlefieldCenter 战场阵线偶数偏移驱动
KARDS.BattlefieldCenter = KARDS.BattlefieldCenter or {}

-- 偶数阵线全卡整线右移的动画时长（秒）
KARDS.BattlefieldCenter.SHIFT_SECONDS = 0.3

-- 各牌桌实例：Instances[tableID] = { [zoneKey] = shift }
-- zoneKey = zone .. ":" .. owner（前线 owner 固定取 FrontlineOwner）
KARDS.BattlefieldCenter.Instances = KARDS.BattlefieldCenter.Instances or {}

-- 阵线非空卡牌计数（含总部；复刻 sh_battlefield.lua 的 CountUnits 语义）
-- @param line table 阵线数组（支援阵线或前线）
-- @return number 非空槽位数
local function CountUnits(line)
    local n = 0
    for i = 1, KARDS.Battlefield.SLOT_COUNT do
        if line[i] ~= nil then n = n + 1 end
    end
    return n
end

-- 计算某阵线的水平移量：偶数张（≥2）→ 0.5 * SPACING；奇数张或空阵线 → 0
-- @param line table 阵线数组
-- @return number 移量
local function ComputeShift(line)
    local n = CountUnits(line)
    if n > 0 and n % 2 == 0 then
        return 0.5 * KARDS.Battlefield.SPACING
    end
    return 0
end

--[[
    时间刻结束：刷新指定阵线的偶数偏移记录

    渲染层（客户端）在每个时间刻结束后，对本局涉及的各阵线调用本函数，
    使本模块记录该阵线当前的移量（偶数 0.5*SPACING / 奇数或空 0）；
    随后用 GetShift 采样驱动整线卡牌 0.3 秒线性右移动画。

    @param tableID string 牌桌唯一标识符
    @param zone    string 阵线（"support" 支援阵线 / "frontline" 前线）
    @param owner   string 阵线归属玩家（支援阵线必传；前线可省略，取 FrontlineOwner）
    @return number 该阵线本次记录的水平移量（0 = 奇数 / 空阵线，无需偏移）
]]
function KARDS.BattlefieldCenter:OnTickEnd(tableID, zone, owner)
    local inst = self.Instances[tableID]
    if not inst then
        inst = {}
        self.Instances[tableID] = inst
    end
    local line
    if zone == "support" then
        if not owner then return 0 end
        line = KARDS.Battlefield:GetSupport(tableID, owner)
    elseif zone == "frontline" then
        owner = KARDS.Battlefield:GetFrontlineOwner(tableID)
        line = KARDS.Battlefield:GetFrontline(tableID)
    else
        return 0 -- 未知阵线
    end
    if not line then return 0 end
    local shift = ComputeShift(line)
    inst[zone .. ":" .. tostring(owner)] = shift
    return shift
end

--[[
    查询指定阵线当前的偶数偏移移量（渲染层动画驱动采样入口）

    @param tableID string 牌桌唯一标识符
    @param zone    string 阵线（"support" / "frontline"）
    @param owner   string|nil 阵线归属玩家（支援阵线必传；前线可省略，取 FrontlineOwner）
    @return number 移量：偶数阵线 0.5*SPACING；奇数 / 空阵线 / 未记录 → 0
]]
function KARDS.BattlefieldCenter:GetShift(tableID, zone, owner)
    local inst = self.Instances[tableID]
    if not inst then return 0 end
    if zone == "frontline" then
        owner = KARDS.Battlefield:GetFrontlineOwner(tableID)
    end
    return inst[zone .. ":" .. tostring(owner)] or 0
end

--[[
    重置指定牌桌的全部偶数偏移记录（对局结束时调用）

    @param tableID string 牌桌唯一标识符
]]
function KARDS.BattlefieldCenter:Reset(tableID)
    self.Instances[tableID] = nil
end
