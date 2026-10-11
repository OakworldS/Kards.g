--[[
    Kards 战斗牌桌客户端模块：老兵升级动画（cl_battle_veteran.lua，2026-09-26 缺口 I）

    数据层 SimVeteran 套用老兵外观后触发 UnitElevate 事件，实体层经 BroadcastUnitElevate
    广播 KardsUnitElevate，本模块播「z 上升 → 依次白色飘字 → 回落」，三方视角一致
    （服务端 net.Broadcast，模块内不做视角分支）。

    载荷：牌桌实体 / 单位实体 / 行动花费是否变化（Bool）/
          行动花费变动值与新值 / 攻击力变动值与新值 / 防御力变动值与新值

    动画分支：
      阶段一（上升）：单位 z 上升 LiftZ，cos 缓动 RiseDur 秒。
      阶段二（飘字）：上升完成后依次白色飘字。行动花费仅在发生变动时飘，显示带符号
        变动值；攻击力与防御力无论是否变化都飘，白字语义为「设为」，显示老兵化之后
        的新值。飘字之间的 0.5 秒错峰由 cl_card_text_overlay.lua 的既有队列完成，
        本模块不额外推迟飘字的开始时间。
      阶段三（回落）：待本次实际发出的全部飘字播放完毕后回落（等待时长按飘字条数、
        0.5 秒错峰间隔与单条 1.75 秒播放时长算出，而非固定 FallDur；首帧省略 pos，
        自动快照当前姿态）。
    角度不动，卡牌全程保持平躺（老兵只改 z 不改平面位置，故布局守卫无需额外处理）。

    挂载：cl_init.lua include 本文件（cl_battle_join.lua 之后）。
    依赖 cl_init.lua 末尾桥接导出（KARDS.AnimPlayer / BattleState）与
    cl_card_text_overlay.lua 的 KARDS.CardTextOverlay.PlayStatFXWhite。
]]

KARDS = KARDS or {}

-- 动画常量（时长秒 / 距离世界单位）
local VeteranGroup = "unitVeteran" -- 老兵动画组名
local RiseDur      = 0.4           -- z 上升时长
local FallDur      = 0.4           -- z 回落时长
local LiftZ        = 1.5           -- z 上升量
-- 飘字节奏常量（与 cl_card_text_overlay.lua 的 FX_QUEUE_INTERVAL / FX_DURATION 一致）：
local FXQueueInterval = 0.5        -- 相邻飘字开始的错峰间隔（秒）
local FXDuration      = 1.75       -- 单条飘字播放时长（秒）

-- 老兵升级动画接收（服务端 BroadcastUnitElevate）
net.Receive("KardsUnitElevate", function()
    local tableEnt = net.ReadEntity()
    local ent = net.ReadEntity()
    local ackChanged = net.ReadBool()
    local ackDelta = net.ReadInt(16)
    local ackNew = net.ReadInt(16)
    local atkDelta = net.ReadInt(16)
    local atkNew = net.ReadInt(16)
    local defDelta = net.ReadInt(16)
    local defNew = net.ReadInt(16)
    if not IsValid(tableEnt) or not KARDS.BattleState:IsLocalTable(tableEnt) then return end
    if not IsValid(ent) then return end
    local cur = ent:GetLocalPos()
    -- 阶段一：z 上升，完成后进入阶段二
    KARDS.AnimPlayer:Play(ent, {
        { t = 0, pos = cur },
        { t = RiseDur, pos = cur + Vector(0, 0, LiftZ), easing = "cos" },
    }, {
        group = VeteranGroup,
        noQueue = true,
        onComplete = function()
            local overlay = KARDS.CardTextOverlay
            if not (overlay and overlay.PlayStatFXWhite) then return end
            -- 阶段二：依次白色飘字（0.5 秒错峰由 Overlay 内部队列完成），统计实际发出条数
            local count = 0
            if ackChanged then
                if overlay:PlayStatFXWhite(ent, "actionCost", ackDelta) then count = count + 1 end
            end
            if overlay:PlayStatFXWhite(ent, "attack", atkNew) then count = count + 1 end  -- 攻防：设为后的新值
            if overlay:PlayStatFXWhite(ent, "defense", defNew) then count = count + 1 end
            -- 阶段三：等待本次全部飘字播放完毕再回落。第 i 条在第 1 条开始后
            -- 0.5*(i-1) 秒开始，单条播放 1.75 秒，故总时长 = 错峰间隔*(条数-1) + 单条时长
            local waitDur = (count > 0) and ((count - 1) * FXQueueInterval + FXDuration) or 0
            -- 首帧省略 pos 自动快照当前姿态
            timer.Simple(waitDur, function()
                if not IsValid(ent) then return end
                KARDS.AnimPlayer:Play(ent, {
                    { t = 0 },
                    { t = FallDur, pos = cur, easing = "cos" },
                }, { group = VeteranGroup, noQueue = true })
            end)
        end,
    })
end)