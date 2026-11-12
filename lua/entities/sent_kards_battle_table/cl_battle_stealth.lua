--[[
    Kards 战斗牌桌客户端模块：隐蔽机制（cl_battle_stealth.lua，2026-08-13）

    职责（readme 7.2.2 + 2026-08-13 用户规格）：
      - 隐蔽单位部署时背面朝上（pitch=180 显示卡背，不渲染正面——3D2D 文字经
        hideWhenBack 在 pitch>90 时不绘制，见 cl_init.lua KardsCardPlayed 半程切换）；
        揭示前始终卡背朝上（KardsFieldFacing 每帧只改 yaw 保留 pitch）。
      - 揭示事件（KardsReveal net 接收）：服务端 SimAttack/SimEngage 数据层先揭示，
        此处仅视觉——播放翻面动画「pitch 180 → 90（翻到一半 z 抬升，防翻面穿入桌中）
        → 0」+ 揭示音效（sound/kards/kg_reveal.ogg，原「隐蔽单位揭示.ogg」转英文名，
        surface.PlaySound 不支持非 ASCII 文件名）；服务端延迟 RevealDelay 后才广播
        布局/属性（ApplyCombatOutcome），翻面完成才继续（被）攻击动画。
      - 指令指向提示：指向隐蔽单位时始终提示「隐蔽单位不受指令指向」（悬停即提示 +
        松手失败原因，见 cl_init.lua GetPointingTarget / PointingFailReason / 拖拽 Think）。

    挂载：cl_init.lua include 本文件（cl_battle_ops.lua 之后）。约定：常驻钩子挂
    KARDS 命名空间；跨段落共享状态读写走 KARDS.BattleState。
]]

if not CLIENT then return end

KARDS = KARDS or {}

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

KARDS.Stealth = KARDS.Stealth or {}
local BS = KARDS.BattleState

-- 翻面动画时长（秒）：两段各半（pitch 180→90→0）；服务端 RevealDelay（0.9s）须 ≥
-- 本值，保证 ApplyCombatOutcome 布局广播到达时翻面已完成（见 table_battledeck.lua）
local RevealFlipDur = 0.8
-- 翻面到一半（pitch 90）时的 z 抬升量：单位短卡长 8.528，半长 4.264——中心原点翻转
-- 时底边以半长为半径扫过桌面，不抬升会在 pitch 90 附近穿入桌中（用户规格）；+0.34 余量
local RevealFlipLift = 4.6

-- 悬停提示节流间隔（秒）：同文本 Push 会重置计时常驻（见 cl_battle_hint.lua），
-- 指向隐蔽单位期间按间隔推送即可常驻显示，防每帧 Push 的开销
local HintThrottle = 0.3
local lastHintT = 0

-- 揭示动画结束时刻表（实体 → 动画结束 CurTime；2026-08-13 用户规格：揭示动画
-- 开始令词条图标与矩形消失，动画结束后重新以正常入场动画出现）。weak keys 防泄漏
local RevealEnds = setmetatable({}, { __mode = "k" })

-- 词条模块查询/清除揭示动画结束时刻（cl_battle_keyword_icons.lua Draw 每帧调用）
function KARDS.Stealth.GetRevealEnd(ent)
    return RevealEnds[ent]
end

function KARDS.Stealth.ClearRevealEnd(ent)
    RevealEnds[ent] = nil
end

--[[
    是否处于隐蔽的战场单位（Kards_IsHidden NW，服务端部署时按 Hidden 词条初写、
    揭示时 BroadcastReveal 清除）

    @param ent Entity 战场单位实体
    @return boolean
]]
function KARDS.Stealth.IsStealthEnt(ent)
    return IsValid(ent) and ent:GetNWBool("Kards_IsHidden", false) == true
end

--[[
    射线命中隐蔽单位（指令指向提示用）：遍历双方支援阵线 + 前线布局，返回被命中的
    隐蔽单位实体（最近者；无命中 / 命中的非隐蔽单位返回 nil）。

    @param pos Vector 视线起点（相机位置）
    @param dir Vector 视线方向（鼠标射线）
    @return Entity|nil 命中的隐蔽单位实体
]]
function KARDS.Stealth.HitStealthTarget(pos, dir)
    if not BS.inTable or not IsValid(BS.inTable.ent) then return nil end
    -- 候选场：双方支援阵线 + 前线（2026-08-15 C2 收敛至 KARDS.FieldCandidates，见 cl_init.lua）
    return KARDS.HitTest.NearestCardFace(pos, dir, KARDS.FieldCandidates(),
        KARDS.UnitHitHalfW, KARDS.UnitHitHalfL, nil,
        KARDS.HitTest.All(KARDS.HitTest.Filters.Valid, KARDS.Stealth.IsStealthEnt))
end

--[[
    指令指向隐蔽单位时始终提示「隐蔽单位不受指令指向」（2026-08-13 用户规格）：
    悬停命中隐蔽单位 → 按 HintThrottle 间隔节流推送（同文本提示常驻不闪断，见
    cl_battle_hint.lua Push 同文本重置计时）；无命中不提示。松手失败原因由
    cl_init.lua PointingFailReason 单独检测（返回同文案）。

    @param pos Vector 视线起点（相机位置）
    @param dir Vector 视线方向（鼠标射线）
]]
function KARDS.Stealth.HintIfPointing(pos, dir)
    if not KARDS.Stealth.HitStealthTarget(pos, dir) then return end
    local now = CurTime()
    if now - lastHintT >= HintThrottle then
        lastHintT = now
        KARDS.BattleHint.Push(T("battle.pointing.stealth"))
    end
end

-- 隐蔽揭示事件（服务端 BroadcastReveal）：所有客户端本地播放翻面动画 + 揭示音效。
-- 读序：牌桌 → 数量 → 单位实体（只含需翻面的隐蔽单位；攻击方非隐蔽则不含）。
net.Receive("KardsReveal", function()
    local ent = net.ReadEntity()
    local n = net.ReadUInt(8)
    if not IsValid(ent) then return end
    local list = {}
    for _ = 1, n do
        local e = net.ReadEntity()
        if IsValid(e) then list[#list + 1] = e end
    end
    if #list == 0 then return end
    -- 揭示音效（一次事件一次；原「隐蔽单位揭示.ogg」转英文名 kg_reveal.ogg）
    KARDS.PlayKardsSound("kg_reveal")
    -- 翻面动画（同组 + 免排队：即时播放不排队；服务端延迟 RevealDelay 才广播布局，
    -- 攻击动画自然排在本翻面之后）：帧 1 保持卡背（pitch 180）→ 帧 2 翻到一半
    -- （pitch 90 + z 抬升）→ 帧 3 落回正面（pitch 0）。yaw 取当前（KardsFieldFacing
    -- 驱动值），翻面只改 pitch 不干扰 yaw；3D2D 文字经 hideWhenBack 在 pitch 越过
    -- 90° 时随卡面一起出现（先渲染正面 → 翻面 → 攻击动画）。
    for _, e in ipairs(list) do
        -- 记录揭示动画结束时刻：动画期间词条图标与矩形隐藏，结束后词条模块
        -- 重置入场动画重新出现（见 cl_battle_keyword_icons.lua Draw）
        RevealEnds[e] = CurTime() + RevealFlipDur
        local curPos = e:GetLocalPos()
        local cur = e:GetLocalAngles()
        KARDS.AnimPlayer:Play(e, {
            { t = 0, pos = curPos, ang = Angle(180, cur.y, cur.r) },
            { t = RevealFlipDur * 0.5, pos = curPos + Vector(0, 0, RevealFlipLift), ang = Angle(90, cur.y, cur.r) },
            { t = RevealFlipDur, pos = curPos, ang = Angle(0, cur.y, cur.r) },
        }, { group = "stealthReveal", noQueue = true })
    end
end)
