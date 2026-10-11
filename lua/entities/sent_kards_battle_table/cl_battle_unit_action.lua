--[[
    Kards 战斗牌桌客户端模块：单位攻击冲刺动画（cl_battle_unit_action.lua，2026-09-26 缺口 G）

    手动路径（点击交战 / 攻击总部，见 table_battledeck.lua 的 OnUnitEngage / OnUnitAttackHQ）
    与效果路径（节点「交战」「战斗」经 UnitAction 事件桥接）共用 ENT:BroadcastUnitAction，
    广播 KardsUnitAction，本模块按攻击方单位类型播冲刺动画。

    载荷：牌桌实体 / 攻击方实体 / 目标实体 / 攻击方单位类型字符串

    几何（用户 2026-09-26 定义）：delta = 目标局部坐标 - 攻击方局部坐标，即「向量」
    （攻击者到目标质点，箭头指向目标）；len = delta 长度；冲刺沿「向量的反向」进行，
    dir = -delta / len，终点 endPos = start + dir * len = start - delta（起点关于攻击者
    镜像，与目标等距且在相反侧）。向量由两个实体的局部坐标现算，三方视角方向一致。

    动画分支（仅位置，角度不动，卡牌保持平躺）：
      坦克 / 炮兵（战斗机 / 轰炸机正式版另行描述，测试版暂用坦克方法）：0.1 秒内线性
        移到反向终点，再用 easeOutBack 回弹曲线 0.7 秒返回起点（先沿回程方向过冲再回落）。
      步兵：先 0.1 秒向终点靠近一部分（不到终点），随后 0.5 秒内在起终点之间高频
        往复（固定系数表，高低交替且互不相等，振幅接近整段距离并逼近终点但不接触），
        最后 0.6 秒返回起点。
    反击没有动画：反击在数据层 SimEngage 内部完成，不经本模块广播。

    挂载：cl_init.lua include 本文件（cl_battle_join.lua 之后）。
    依赖 cl_init.lua 末尾桥接导出（KARDS.AnimPlayer / BattleState）与
    KardsFieldLayout 接收器的冲刺守卫（KARDS.AnimPlayer:Active(e, "unitLunge")）。
]]

KARDS = KARDS or {}

-- 动画常量（时长秒 / 距离世界单位）
local LungeGroup    = "unitLunge" -- 冲刺组名（布局守卫按此组名跳过复位动画）
local InfStartDur   = 0.1         -- 步兵「向终点靠近一部分」时长
local InfJitterDur  = 0.5         -- 步兵往复段总时长（10 段 × 0.05 秒）
local InfJitterSteps = 10         -- 步兵往复采样段数
local InfBackDur    = 0.6         -- 步兵返回起点时长
local TankOutDur    = 0.1         -- 坦克 / 炮兵去程时长
local TankBackDur   = 0.7         -- 坦克 / 炮兵回程时长（easeOutBack 回弹）
-- 步兵往复系数（占比：位置 = start + dir * (len * k)），高低交替且互不相等；
-- 上限 0.92 保证逼近终点但不接触（用户答复「接近整段距离，逼近终点」）。
-- 用固定系数表而非随机数：三方视角与复现结果一致。
local InfJitterK = { 0.22, 0.88, 0.16, 0.92, 0.30, 0.79, 0.19, 0.90, 0.26, 0.85 }

--[[
    坦克 / 炮兵冲刺帧序列：0.1 秒线性移到反向终点，0.7 秒 easeOutBack 回弹返回起点

    @param start  Vector 起点（攻击方局部坐标）
    @param endPos Vector 反向终点
    @return table 帧序列
]]
local function TankFrames(start, endPos)
    return {
        { t = 0, pos = start },
        { t = TankOutDur, pos = endPos, easing = "linear" },
        { t = TankOutDur + TankBackDur, pos = start, easing = "easeOutBack" },
    }
end

--[[
    步兵冲刺帧序列：靠近一部分 → 起终点之间高频往复 → 返回起点

    @param start  Vector 起点（攻击方局部坐标）
    @param dir    Vector 单位反向（起始点指向反向终点）
    @param len    number 向量长度（起点到反向终点的距离）
    @return table 帧序列
]]
local function InfantryFrames(start, dir, len)
    local frames = {
        { t = 0, pos = start },
        -- 向终点靠近一部分（不到终点）
        { t = InfStartDur, pos = start + dir * (len * 0.3), easing = "linear" },
    }
    -- 高频往复：每段 0.05 秒，覆盖 t = 0.1 至 0.6
    local stepDur = InfJitterDur / InfJitterSteps
    for i = 1, InfJitterSteps do
        frames[#frames + 1] = {
            t = InfStartDur + stepDur * i,
            pos = start + dir * (len * InfJitterK[i]),
            easing = "linear",
        }
    end
    -- 返回起点
    frames[#frames + 1] = {
        t = InfStartDur + InfJitterDur + InfBackDur,
        pos = start,
        easing = "cos",
    }
    return frames
end

-- 单位攻击冲刺接收（服务端 BroadcastUnitAction）：牌桌 → 攻击方实体 → 目标实体 → 单位类型。
-- 仅关注桌消费；两个实体任一无效（如目标已离场且实体已销毁）时退化为无动画。
net.Receive("KardsUnitAction", function()
    local tableEnt = net.ReadEntity()
    local attackerEnt = net.ReadEntity()
    local targetEnt = net.ReadEntity()
    local unitType = net.ReadString()
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    if not IsValid(attackerEnt) or not IsValid(targetEnt) then return end
    local start = attackerEnt:GetLocalPos()
    local delta = targetEnt:GetLocalPos() - start
    local len = delta:Length()
    if len < 0.01 then return end -- 两卡重合：无方向可言，不播
    local dir = delta * (-1 / len) -- 向量的反向（单位矢量，指向反向终点）
    local endPos = start + dir * len -- 反向终点（起点关于攻击者镜像）
    local frames
    if unitType == "infantry" then
        frames = InfantryFrames(start, dir, len)
    else
        -- 坦克 / 炮兵 / 战斗机 / 轰炸机（战斗机与轰炸机正式版另行描述，测试版暂用坦克方法）
        frames = TankFrames(start, endPos)
    end
    KARDS.AnimPlayer:Play(attackerEnt, frames, {
        group = LungeGroup,
        noQueue = true, -- 免排队：冲刺立即播放，不阻塞其它卡的布局复位动画
    })
end)