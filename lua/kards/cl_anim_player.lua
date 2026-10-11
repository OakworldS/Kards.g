--[[
    通用 6 值关键帧动画播放器（客户端，re.md 重构）

    统一牌桌上 3D 世界的全部动画（实体变换 + 相机进入）为「6 值姿态关键帧」驱动：
    姿态 = pos.xyz（位置）+ ang.pyr（俯仰/偏航/翻滚），帧 = 姿态 + 时刻 + 缓动 + 事件。

    帧序列（frames，t 为相对动画起始的秒数，须升序）：
      { t = 秒数, pos = Vector?, ang = Angle?, easing = 曲线名?, event = 事件名? }
      - 首帧省略 pos/ang 时自动快照目标当前姿态（动画从当前位置/角度出发；快照在
        「动画实际开始」时进行，而非入队时）
      - 后续帧省略某轴（pos 或 ang）= 该轴保持上一帧值 → 仅位置 / 仅角度动画无需特殊开关
      - easing 作用于「到达本帧的段」（缺省取 opts.easing 或 "smooth"）
      - event 为命名关键帧：t 越过该帧时回调 opts.onKeyframe(target, 事件名, t)
      - 两帧姿态相同 = 停留（deckDraw 桌中停留 / 移除动画等待段）

    动画队列（2026-08-12 新增：全局 FIFO + 并行组 + 免排队标记）：
      - 默认所有动画按调用顺序进入全局 FIFO 队列：更晚的动画必须等更早的动画
        播放完成才能开始（非动画系统的操作——如打出指令的效果——仍即时生效，
        属服务端数据层，本模块不涉及；但若该生效伴随动画，动画同样排队）。
      - opts.group 兼作「并行组」调度语义：同一组内动画可并发（后入队的同组动画
        加入当前组并发播放）；不同组之间严格串行（后一组的动画必须等当前组全部
        播完才开播）。未分组（group=nil）的动画为独立批次（默认串行）。
      - 同一 target 再次 Play = 原位替换（不追加）：正在播的被重启（新帧立即生效）；
        已入队的原位覆盖帧（保留队列位置）。每 target 全局最多一个动画。
      - opts.noQueue = true：免排队——直接播放、不排队、也不阻挡队列（高频交互
        反馈，如拖拽腾位预览 fieldRepos）。

    opts：
      delay?      动画开始前延迟秒数（延迟期间保持首帧姿态；mulligan 发牌错峰）
      group?      组名（Active(target, 组名...) 按组判定；Any(组名) 判定某组是否有
                  动画在播；兼作并行组调度语义，见上）
      noQueue?    true = 免排队直接播放（默认 false）
      easing?     缺省曲线名
      onStart?    function(target)  延迟结束、动画实际开始时回调（发牌音效）
      onKeyframe? function(target, name, t)  命名关键帧到达回调（阶段事件）
      onComplete? function(target)  动画完成回调（登记/SetNoDraw 等收尾）

    API：
      Play(target, frames, opts)  播放/排队（同一 target 已有动画则原位替换）
      Get(target)                 取播放中或排队中的 clip（含 toPos/toAng 目标值）
      Active(target, ...groups)   是否在播或排队；给组名则仅当所属组命中任一给定组
      Any(group)                  是否存在某组动画在播或排队（mulligan 发牌完成判定）
      Stop(target)                停止（活跃或队列中移除，不写任何值）
      StopAll()                   停止全部（退出牌桌 / 新对局复位）

    写入端（writer）：
      - 实体对象（sent_pmx_static_imported 等）→ SetLocalPos / SetLocalAngles
      - 相机对象（cl_battle_camera.lua 的 Cameras[player]，携带 pos/ang 字段）→ 写字段
      判定依据：实体实例带 IsEntity 方法，相机/对象表没有。

    与数据层 KARDS.Animation（sh_animation.lua）的关系：
      后者为单值、对象绑定、纯逻辑（测试覆盖 ticklog_test 场景 14/17），保留不动；
      本播放器为多值、实体绑定、客户端渲染层，两者并存。Board2D / HandFanPos /
      MulliganFanPos / FieldPos 等姿态函数作为「帧生成器」沿用。
]]

KARDS = KARDS or {}
KARDS.AnimPlayer = KARDS.AnimPlayer or {}

-- 活跃播放中的动画（weak keys：实体 / 相机对象），[target] = clip
-- clip = { target, frames, opts, group, hasPos, hasAng, startPos, startAng,
--          toPos, toAng, fired, started, start, fromQueue }
-- fromQueue：true = 队列提升播放（参与组间串行门槛）；false = noQueue 即时播放
local clips = setmetatable({}, { __mode = "k" })

-- 等待队列（FIFO 数组）：[1..n] = clip（强引用；失效实体由调度清理）
local queue = {}
-- 队列反向索引（weak keys）：[target] = clip（O(1) 查找/替换/删除）
local queuedTargets = setmetatable({}, { __mode = "k" })

-- 缓动注册表（t ∈ [0,1] → [0,1]；与旧动画系统的曲线一一对应）
local Easings = {
    linear       = function(t) return t end,
    smooth       = function(t) return t * t * (3 - 2 * t) end, -- smoothstep（原 RevealEaseInOut）
    cos          = function(t) return 0.5 - 0.5 * math.cos(math.pi * t) end, -- cos easeInOut（原拖拽/腾位）
    easeOut      = function(t) return 1 - (1 - t) * (1 - t) * (1 - t) end, -- easeOutCubic（原 RevealEaseOut）
    easeOutBack  = function(t) -- 原 RevealEaseOutBack（先过冲再回落）
        local c1, c3 = 1.70158, 2.70158
        t = t - 1
        return 1 + c3 * t * t * t + c1 * t * t
    end,
}
KARDS.AnimPlayer.Easings = Easings

-- yaw 最短路径插值（避免跨 ±180 绕圈；等价原 cl_init LerpYaw）
local function LerpYaw(a, b, t)
    local d = ((b - a + 180) % 360) - 180
    return a + d * t
end

-- 全角最短弧插值（三轴均归一化到 [-180,180]；等价原 cl_battle_camera LerpAngle。
-- 翻面关键帧 pitch 180↔0 的差恰为 ±180，最短弧与线性一致，翻转方向不变）。
-- 注意不可用 GMod 内置全局 LerpAngle：其签名 LerpAngle(frac, angle1, angle2) 的
-- 第一个参数是「逼近角度增量」（number）而非 0..1 系数，参数顺序与语义均不适用。
local function LerpAngle(a, b, t)
    local dp = ((b.p - a.p + 180) % 360) - 180
    local dr = ((b.r - a.r + 180) % 360) - 180
    return Angle(a.p + dp * t, LerpYaw(a.y, b.y, t), a.r + dr * t)
end

-- 目标是否为实体对象（GMod 实体是 userdata，istable(target) 返回 false 会误判为
-- 相机/卡牌对象表；改用全局 IsEntity 判定——实体返回 true，相机/对象表返回 false）
local function IsEntityObj(target)
    return IsEntity(target)
end

-- 读取目标当前姿态（实体：局部坐标/角度；相机：pos/ang 字段）
local function ReadPose(target)
    if IsEntityObj(target) then
        return target:GetLocalPos(), target:GetLocalAngles()
    end
    return target.pos, target.ang
end

-- 写入目标姿态（pos/ang 为 nil 的轴不写 → 仅位置/仅角度动画不干扰另一轴）
local function WritePose(target, pos, ang)
    if pos then
        if IsEntityObj(target) then
            target:SetLocalPos(pos)
        else
            target.pos = pos
        end
    end
    if ang then
        if IsEntityObj(target) then
            target:SetLocalAngles(ang)
        else
            target.ang = ang
        end
    end
end

-- 立即开始播放 clip（Play 直接播放 / 队列提升 / 同 target 活跃替换重启）：
-- 设定 start（含 delay）+ 首帧省略轴在「此刻」快照起始姿态 + 登记活跃表
local function BeginClip(clip)
    local target = clip.target
    clip.start = CurTime() + (clip.opts.delay or 0)
    if not clip.frames[1].pos or not clip.frames[1].ang then
        local curPos, curAng = ReadPose(target)
        if not clip.frames[1].pos then clip.startPos = curPos end
        if not clip.frames[1].ang then clip.startAng = curAng end
    end
    clips[target] = clip
end

-- 调度推进（Play / 替换 / Stop / Think 完成 / 失效清理后调用）：
--   1. 清理队列中失效实体（服务端已移除的实体不播）
--   2. 无活跃 fromQueue clip → 提升队头开始播放
--   3. 有活跃 fromQueue clip → 仅当队头与活跃组同组（且队头有组名）→ 提升队头
--      加入并发；否则等待当前组播完（组间严格串行）
--   4. 未分组（group=nil）clip 为独立批次：仅自身一组（默认串行）
local function PromoteQueue()
    local i = 1
    while i <= #queue do
        local c = queue[i]
        if IsEntityObj(c.target) and not IsValid(c.target) then
            queuedTargets[c.target] = nil
            table.remove(queue, i)
        else
            i = i + 1
        end
    end
    if #queue == 0 then return end
    -- 活跃 fromQueue clip 的组（同组并发；若因替换出现多组并存，以先遇到的为准）
    local activeGroup = nil
    for _, c in pairs(clips) do
        if c.fromQueue then
            activeGroup = c.group
            break
        end
    end
    local head = queue[1]
    if activeGroup then
        -- 组间串行：当前组播完前不提升不同组的队头
        if not head.group or head.group ~= activeGroup then return end
    end
    -- 提升队头（队列 → 活跃）
    table.remove(queue, 1)
    queuedTargets[head.target] = nil
    BeginClip(head)
end

--[[
    播放 6 值关键帧动画（同一 target 已有动画则原位替换；参数非法返回 nil）

    @param target 实体 | 相机对象
    @param frames 帧序列（见文件头约定）
    @param opts   { delay?, group?, noQueue?, easing?, onStart?, onKeyframe?, onComplete? }
    @return table clip（含 toPos/toAng：末帧目标值，供调用方比对目标是否变化）
]]
function KARDS.AnimPlayer:Play(target, frames, opts)
    if not target or not frames or #frames < 1 then return nil end
    opts = opts or {}
    -- 校验帧时刻升序（首帧 t 缺省 0）
    for i, f in ipairs(frames) do
        frames[i] = { t = f.t or 0, pos = f.pos, ang = f.ang, easing = f.easing, event = f.event }
    end
    table.sort(frames, function(a, b) return a.t < b.t end)
    -- 轴存在性：帧序列中出现过 pos/ang 的轴才参与写入
    local hasPos, hasAng = false, false
    for _, f in ipairs(frames) do
        if f.pos then hasPos = true end
        if f.ang then hasAng = true end
    end
    local curPos, curAng = ReadPose(target)
    local last = frames[#frames]
    local clip = {
        target = target,
        frames = frames,
        opts = opts,
        group = opts.group,
        hasPos = hasPos,
        hasAng = hasAng,
        -- 起始姿态：首帧明确给定则用给定值，否则占位（实际开始时快照当前姿态）
        startPos = frames[1].pos or curPos,
        startAng = frames[1].ang or curAng,
        -- 目标姿态：末帧给定值（该轴未参与动画则沿用起始姿态）
        toPos = hasPos and (last.pos or frames[1].pos or curPos) or nil,
        toAng = hasAng and (last.ang or frames[1].ang or curAng) or nil,
        fired = {},
        started = false,
    }
    -- 同 target 已有动画（活跃或排队）→ 原位替换（保留现有「同 target 替换」语义）
    if clips[target] then
        -- 活跃中：重启（继承 fromQueue 状态；新 delay 重排 start、此刻快照姿态）
        clip.fromQueue = clips[target].fromQueue
        BeginClip(clip)
        return clip
    end
    -- 免排队：直接播放（高频交互反馈；不排队、不阻挡队列；同 target 若在排队则
    -- 移除——保证「免排队即播」且每 target 全局唯一）
    if opts.noQueue then
        clip.fromQueue = false
        if queuedTargets[target] then
            for i, c in ipairs(queue) do
                if c.target == target then
                    table.remove(queue, i)
                    break
                end
            end
            queuedTargets[target] = nil
            PromoteQueue() -- 移除后队头可能变化
        end
        BeginClip(clip)
        return clip
    end
    if queuedTargets[target] then
        -- 排队中：原位覆盖队列项（保留队列位置；组可能变化 → 重评估调度）
        clip.fromQueue = true
        for i, c in ipairs(queue) do
            if c.target == target then
                queue[i] = clip
                break
            end
        end
        queuedTargets[target] = clip
        PromoteQueue()
        return clip
    end
    -- 入队（全局 FIFO；若其组正活跃，PromoteQueue 立即提升加入并发）
    clip.fromQueue = true
    queue[#queue + 1] = clip
    queuedTargets[target] = clip
    PromoteQueue()
    return clip
end

-- 取目标播放中或排队中的 clip（无则 nil；调用方可用 clip.toPos/toAng 与目标值比对）
function KARDS.AnimPlayer:Get(target)
    return clips[target] or queuedTargets[target]
end

--[[
    目标是否在播放或排队动画。给组名则仅当所属组命中任一给定组时返回 true：
      Active(ent)           → 任何动画在播/排队
      Active(ent, "hq")     → 仅总部对局开始动画
      Active(ent, "a", "b") → 属于 a 或 b 组（保留旧代码按动画表逐个判定的精确语义）
    排队中视为忙碌：拖拽拿起判定 / mulligan 落位等自动生效。
]]
function KARDS.AnimPlayer:Active(target, ...)
    local clip = clips[target] or queuedTargets[target]
    if not clip then return false end
    local n = select("#", ...)
    if n == 0 then return true end
    for i = 1, n do
        if clip.group == select(i, ...) then return true end
    end
    return false
end

-- 是否存在某组动画在播或排队（mulligan 发牌全部完成 = 无 "mulliganDeal" 组动画；
-- 含排队项：发牌未播完前选择/确认不会提前解锁）
function KARDS.AnimPlayer:Any(group)
    for _, clip in pairs(clips) do
        if clip.group == group then return true end
    end
    for _, clip in ipairs(queue) do
        if clip.group == group then return true end
    end
    return false
end

-- 停止目标动画（活跃或队列中移除，立即清表，不写任何值；目标留在当前姿态）
function KARDS.AnimPlayer:Stop(target)
    local clip = clips[target]
    if clip then
        clips[target] = nil
        if clip.fromQueue then PromoteQueue() end -- 组可能少成员 → 重评估调度
        return
    end
    if queuedTargets[target] then
        for i, c in ipairs(queue) do
            if c.target == target then
                table.remove(queue, i)
                break
            end
        end
        queuedTargets[target] = nil
        PromoteQueue() -- 队头可能变化
    end
end

-- 停止全部动画（退出牌桌 / 新对局复位；队列一并清空）
function KARDS.AnimPlayer:StopAll()
    for target in pairs(clips) do
        clips[target] = nil
    end
    for i = #queue, 1, -1 do
        queuedTargets[queue[i].target] = nil
        queue[i] = nil
    end
end

-- 触发 t 已越过的命名关键帧事件（按帧序，每帧只触发一次）
local function FireEvents(clip, t, target)
    for i, f in ipairs(clip.frames) do
        if f.event and not clip.fired[i] and t >= f.t then
            clip.fired[i] = true
            if clip.opts.onKeyframe then
                clip.opts.onKeyframe(target, f.event, f.t)
            end
        end
    end
end

-- 单帧推进（now = CurTime()）
local function UpdateClip(clip, now)
    local target = clip.target
    local t = now - clip.start
    -- 延迟等待：保持起始姿态（mulligan 发牌错峰期间卡停在卡堆顶初始姿态）
    if t < 0 then
        WritePose(target,
            clip.hasPos and clip.startPos or nil,
            clip.hasAng and clip.startAng or nil)
        return
    end
    -- 实际开始（延迟结束）回调
    if not clip.started then
        clip.started = true
        if clip.opts.onStart then clip.opts.onStart(target) end
    end
    local frames = clip.frames
    local last = frames[#frames]
    if t >= last.t then
        -- 完成：定格最终姿态 + 触发未触发事件 + 清表
        WritePose(target, clip.toPos, clip.toAng)
        FireEvents(clip, t, target)
        clips[target] = nil
        if clip.opts.onComplete then clip.opts.onComplete(target) end
        return
    end
    -- 定位所在帧段 [fi, fj] 并插值
    local fi, fj = frames[1], frames[2]
    for i = 2, #frames do
        if t <= frames[i].t then
            fi, fj = frames[i - 1], frames[i]
            break
        end
    end
    local segLen = fj.t - fi.t
    local p = (segLen > 0) and (t - fi.t) / segLen or 1
    local ease = Easings[fj.easing or clip.opts.easing or "smooth"] or Easings.smooth
    local e = ease(p)
    -- 仅插值帧序列中出现过的轴；省略的轴保持（fj 无该轴则不写）
    local pos, ang = nil, nil
    if fj.pos then
        pos = (fi.pos or clip.startPos) + (fj.pos - (fi.pos or clip.startPos)) * e
    end
    if fj.ang then
        local fromAng = fi.ang or clip.startAng
        ang = LerpAngle(fromAng, fj.ang, e)
    end
    WritePose(target, pos, ang)
    -- 命名关键帧事件（t 已越过即触发）
    FireEvents(clip, t, target)
end

-- 每帧驱动全部播放中的动画（单一 Think；实体失效即清表；结束后推进队列）
hook.Add("Think", "KARDS_AnimPlayer", function()
    local now = CurTime()
    for target, clip in pairs(clips) do
        if IsEntityObj(target) and not IsValid(target) then
            clips[target] = nil
        else
            UpdateClip(clip, now)
        end
    end
    PromoteQueue() -- 队列推进：当前组播完 → 下个组开始
end)
