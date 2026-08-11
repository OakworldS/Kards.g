--[[
    Kards 战斗系统 - 客户端视角朝向基础模块（基础规则，2026-08-08 建立）

    三个客户端视角的战场卡牌朝向规则：
      - P1 视角（对战开始后的槽位 1 玩家）：场上所有卡牌文字朝向 P2（牌桌局部 -y，yaw=180）
      - P2 视角（对战开始后的槽位 2 玩家）：场上所有卡牌文字朝向 P1（牌桌局部 +y，yaw=0）
      - 观察者视角（LocalView=nil，含未进入牌桌 / 已加入但对战未开始）：P1 的牌朝向
        P1（yaw=0）、P2 的牌朝向 P2（yaw=180）——仅对战开始后才区分 P1/P2 槽位视角
    同一张战场卡在不同客户端本地朝向不同——朝向由客户端本地计算设置，
    服务端只发归属数据（不权威控制角度），符合「使用客户端实体实现，服务端只做数据」。

    战场卡识别与归属（服务端 NW 数据）：
      - Kards_IsFieldCard = true   战场卡标记（总部卡 / 未来的支援阵线·前线部署卡）
      - Kards_DeckSlot = 1|2       归属方（1 = P1 / 2 = P2）
    手牌槽卡（Kards_IsHandSlotCard，开始手牌扇形占位卡）同样参与三视角规则
    （保持服务端扇形分布算法不变，仅本地决定整体姿态/正反面）：
      - P1/P2 视角（LocalView=1/2）：本方手牌保持扇形姿态（正面朝上，看到
        front"正面"）；对方手牌在扇形姿态基础上绕卡长轴翻转 180°（背面朝上，
        看到 back 卡背）——各视角只看得到自己的牌面；
      - 观战视角（LocalView=nil）：使用独立于 P1/P2 视角的扇形分布计算方法
        （最早方法：135° 倾斜基准 + ψ 绕面法线、ψ 取负，保持最早"手拿手牌"
        观感）——角度由服务端 CreateHandCardSlots 独立计算写入
        Kards_LegacyFanAng NW，再绕卡长轴翻转 180° 使正面（front）朝上（观战
        看到的是卡正面空白占位，而非背面纹理）。
    手牌槽卡扇形基准角度由服务端 CreateHandCardSlots 计算后写
    Kards_HandBaseAng NW（Vector 存 p/y/r），客户端读取后本地翻转（不依赖时序）。
    卡组槽（Kards_CardRole="battledeck"）属卡组区不在「场上」，不参与本规则（保持各自
    美观角度：卡组槽 P1 −135° / P2 45°，见 init.lua ENT.DeckSlotYaw；未上场的
    总部卡保持卡组槽角度，上场后由本模块接管）。

    朝向基准：平躺卡（Angle(0,yaw,0)）文字底部朝卡牌局部 +y（= yaw 0）时，
    P1 玩家（牌桌南侧 +y）看到文字正立；yaw=180 时文字朝 -y，P2 玩家（北侧 -y）
    看到文字正立（与 3D2D 文字映射一致：模板顶部映射到卡长 -Y 端）。

    应用机制：本模块提供纯函数（视角状态 / 朝向计算 / 单卡应用），
    由牌桌实体 cl_init.lua 的 Think 钩子 KardsFieldFacing 每帧驱动
    （动画协调：总部对局开始动画 / 抽牌动画中的卡由动画驱动角度，本模块跳过）。
    未来部署卡实体只需设置 Kards_IsFieldCard + Kards_DeckSlot 即自动跟随本规则。
]]
if not CLIENT then return end

KARDS = KARDS or {}
KARDS.Perspective = KARDS.Perspective or {}
local P = KARDS.Perspective

-- 当前本地视角：1 = P1 / 2 = P2 / nil = 观察者（未进入牌桌，或已加入但对战未开始）
-- 仅对战开始后才区分 P1/P2 槽位视角；由牌桌实体 cl_init.lua 设置
--（KardsTableEntered 按对战状态初始、KardsTableBattleStart 切换、KardsTableExited 复位）
P.LocalView = nil

-- 设置/清除本地视角（进入牌桌未开始对战传 nil = 观察者；对战开始传槽位 1|2；
-- 退出牌桌传 nil = 观察者）
-- @param slot number|nil 槽位编号（1 = P1 / 2 = P2 / nil = 观察者）
function P:SetLocalView(slot)
    self.LocalView = slot
end

-- 战场卡牌目标 yaw（本地视角 × 归属方）
--   本地视角（1/2）：该视角玩家看场上所有牌文字都朝对方所在侧（P1 视角朝 P2 侧
--   -y / P2 视角朝 P1 侧 +y，2026-08-10 起反向）
--   观战视角（nil）：P1 的牌朝 P1（yaw 0）、P2 的牌朝 P2（yaw 180）
-- @param view number|nil 本地视角（1/2/nil）
-- @param ownerSlot number 卡牌归属方（1 = P1 / 2 = P2）
-- @return number 目标 yaw（0 或 180）
function P:FacingYaw(view, ownerSlot)
    if view == 1 then return 180 end  -- P1 视角：所有牌朝 P2（牌桌局部 -y）
    if view == 2 then return 0 end    -- P2 视角：所有牌朝 P1（牌桌局部 +y）
    -- 观战：按归属方朝向（P1 牌朝 P1 / P2 牌朝 P2）
    return (ownerSlot == 1) and 0 or 180
end

-- 是否战场卡（服务端 NW 数据标记：总部 / 未来部署卡）
-- @param ent Entity
-- @return boolean
function P:IsFieldCard(ent)
    return IsValid(ent) and ent:GetNWBool("Kards_IsFieldCard", false)
end

-- 对单张战场卡应用本地视角朝向：只改 yaw（保留现有 pitch/roll，
-- 平躺卡 pitch/roll=0；未来倾斜部署卡不受影响）。归属方无效（非 1/2）时不处理。
-- 幂等：yaw 已为目标值时跳过（避免每帧重复 SetLocalAngles）
-- @param ent Entity 战场卡实体（Kards_IsFieldCard + Kards_DeckSlot 已设置）
function P:ApplyFacing(ent)
    local owner = ent:GetNWInt("Kards_DeckSlot", 0)
    if owner ~= 1 and owner ~= 2 then return end
    local yaw = self:FacingYaw(self.LocalView, owner)
    local ang = ent:GetLocalAngles()
    if math.abs(ang.y - yaw) > 0.01 then
        ent:SetLocalAngles(Angle(ang.p, yaw, ang.r))
    end
end

-- 是否手牌槽卡（服务端 SpawnHandSlotCard 标记：开始手牌扇形占位卡）
-- @param ent Entity
-- @return boolean
function P:IsHandSlotCard(ent)
    return IsValid(ent) and ent:GetNWBool("Kards_IsHandSlotCard", false)
end

-- 绕卡面内长轴（Right）翻转 180°（卡面朝上 ⇄ 朝下，扇形张开形态保持）：
-- 平行于长轴的分量不变、垂直分量取反（f→−f、r→r、u→−u），再按
-- init.lua CreateHandCardSlots 同款公式重建角度（(−f):Angle() + roll 修正）。
-- @param base Angle 扇形基准角度（服务端 Kards_HandBaseAng NW）
-- @return Angle
local function FlipCardFace(base)
    local f = base:Forward() * -1
    local r = base:Right()
    local total = f:Angle()
    local r0 = total:Right()
    total.roll = total.roll + math.deg(math.atan2(f:Cross(r0):Dot(r), r0:Dot(r)))
    return total
end

--[[
    对单张手牌槽卡应用本地视角朝向（三视系统，适应各自阅读；保持服务端
    扇形分布算法不变，仅本地决定整体姿态/正反面）：
      - 本地视角 1/2（进入牌桌）：本方手牌（owner == LocalView）→ 保持扇形
        姿态（正面朝上，看到 front"正面"）；对方手牌 → 扇形姿态绕卡长轴翻转
        180°（背面朝上，看到 back 卡背）；
      - 观战（LocalView=nil）：双方手牌各自在 yz 平面（绕 x，roll）旋转 ±45°
        （P1 +45° / P2 −45°，对称镜像，模拟双方各自手持牌面向自己；在扇形
        基准角度上叠加 roll，扇形张开形态保持）。
    扇形基准角度来自服务端 Kards_HandBaseAng NW（CreateHandCardSlots 写入）；
    归属槽位来自 Kards_DeckSlot NW（SpawnHandSlotCard 写入）。NW 未同步时
    不驱动（保持服务端扇形角度，下一帧 NW 就绪后自动生效）。
    幂等：角度已为目标值时跳过（避免每帧重复 SetLocalAngles）。
    @param ent Entity 手牌槽卡实体（Kards_IsHandSlotCard + Kards_DeckSlot 已设置）
]]
function P:ApplyHandFacing(ent)
    local view = self.LocalView
    local owner = ent:GetNWInt("Kards_DeckSlot", 0)
    if owner ~= 1 and owner ~= 2 then return end
    local v = ent:GetNWVector("Kards_HandBaseAng")
    if not v then return end -- NW 未同步：暂不驱动
    local base = Angle(v.x, v.y, v.z)
    local target
    if view == 1 or view == 2 then
        -- P1/P2 视角：本方保持扇形姿态（正面朝上）、对方绕卡长轴翻转 180°（背面朝上）
        target = (owner == view) and base or FlipCardFace(base)
    else
        -- 观战视角：使用独立于 P1/P2 视角的扇形分布计算方法（最早方法，135° 倾斜
        -- 基准 + ψ 绕面法线、ψ 取负，保持最早"手拿手牌"观感），角度由服务端
        -- CreateHandCardSlots 独立计算写入 Kards_LegacyFanAng NW；再绕卡长轴翻转
        -- 180° 使正面（front）朝上——观战看到的是卡正面空白占位（front 白色），
        -- 而非背面纹理（back UK 卡背）。
        local lv = ent:GetNWVector("Kards_LegacyFanAng")
        if not lv then return end -- NW 未同步：暂不驱动
        target = FlipCardFace(Angle(lv.x, lv.y, lv.z))
    end
    local ang = ent:GetLocalAngles()
    if math.abs(ang.p - target.p) > 0.01 or math.abs(ang.y - target.y) > 0.01
        or math.abs(ang.r - target.r) > 0.01 then
        ent:SetLocalAngles(target)
    end
end
