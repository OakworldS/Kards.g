--[[
    Kards 战斗系统 - 卡牌变换动画系统（共享，纯逻辑层）

    预设 3D 空间下卡牌的位置与三个角度（共 6 个值），并提供按时间曲线驱动的
    单值插值动画。本模块不直接写卡牌属性，渲染层（客户端）以采样值驱动显示，
    保持战斗骨架"卡牌对象只读"的依赖倒置（见 sh_card_interface.lua）。

    6 个值：
      pos.x / pos.y / pos.z   位置（3 个）
      ang.p / ang.y / ang.r   三个角度（pitch 俯仰 / yaw 偏航 / roll 翻滚）

    真实时间开关（KARDS.Animation.RealTime）：
      false（默认，测试/调试）——动画不等待真实秒数：ValueNow / ApplyNow
        直接返回/写入终值（等价 Apply(1)），断言不依赖真实时间流逝
      true（实装渲染层）——动画确实按 seconds 参数时长随时间推进：
        创建时记录 StartTime，ValueNow / ApplyNow 以 (CurTime()-StartTime)
        计算进度插值（未到时长返回中间值，超时 clamp 到终值）；渲染层
        每帧调用一次即可驱动真实渐变

    核心函数：
      Animate(seconds, axis, easing, mode, target, start)
        在 seconds 秒内将 6 值中的 axis 以 easing 曲线按 mode 变化到 target：
          axis   ∈ Axes 枚举（必须为 6 值之一）
          easing ∈ Easings 注册表：linear（线性）/ smooth（平滑），可 AddEasing 扩展任意曲线
          mode   ∈ Modes："to" 渐变到 / "add" 增加 / "sub" 减少
      AnimateCard(obj, seconds, axis, easing, mode, targetValue, start?)
        指定一张卡或一方玩家摄像头的一个坐标或旋转值渐变：在 seconds 秒内将
        obj 的 axis（pos.x/y/z 或 ang.p/y/r）以 easing 曲线按 mode 变化到
        目标值，起始值缺省取该对象当前值；返回的动画对象额外提供
        Apply(progress) / ApplyAt(elapsed)，直接把采样值写回该对象的对应轴。
        obj 可为卡牌对象（card.pos / card.ang）或玩家摄像头实例
        （BattleCamera:GetFor 获取）；两者 pos/ang 一致，均为相对牌桌的世界坐标
      GetValue(pose, axis) / SetValue(pose, axis, value)  读写 pose 中某轴的值
      GetPose(name)         取预设 pose 的副本（位置 + 三个角度，共 6 值）
]]

KARDS = KARDS or {}
KARDS.Animation = KARDS.Animation or {}

-- 6 值轴枚举（位置 3 + 角度 3）
KARDS.Animation.Axes = {
    "pos.x", "pos.y", "pos.z",
    "ang.p", "ang.y", "ang.r",
}

-- 真实时间开关：false = 测试/调试（ValueNow/ApplyNow 直接终值）；
-- true = 实装渲染层（按 seconds 参数时长随时间真实渐变，创建时记录 StartTime）
KARDS.Animation.RealTime = false

-- 变化模式（Animate 的 mode 参数）
KARDS.Animation.Modes = {
    To = "to",   -- 渐变到（target 为终值）
    Add = "add", -- 增加（target 为增量，终值 = 起始 + target）
    Sub = "sub", -- 减少（target 为减量，终值 = 起始 - target）
}

--[[
    曲线注册表（可扩展性入口）

    每项为 0→1 归一化缓动函数：t ∈ [0,1] 返回 [0,1] 的插值系数。
    - linear：线性
    - smooth：平滑（smoothstep，三次 Hermite 插值，缓入缓出）
    扩展新曲线：KARDS.Animation:AddEasing("ease_out_back", function(t) ... end)
]]
KARDS.Animation.Easings = {
    linear = function(t) return t end,
    smooth = function(t) return t * t * (3 - 2 * t) end,
}

-- 预设：3D 空间下卡牌的位置与三个角度（坐标单位 / 角度制，按实际牌桌可调）
KARDS.Animation.Poses = {
    hand    = { pos = { x = -40, y = 0,   z = 30 }, ang = { p = 0,  y = 0, r = 0 } }, -- 手牌区
    deck    = { pos = { x = 40,  y = 0,   z = 30 }, ang = { p = 0,  y = 0, r = 0 } }, -- 牌库区
    discard = { pos = { x = 0,   y = 40,  z = 30 }, ang = { p = 0,  y = 0, r = 0 } }, -- 弃牌堆
    table   = { pos = { x = 0,   y = 0,   z = 0 },  ang = { p = 90, y = 0, r = 0 } }, -- 桌面（平放）
    hq      = { pos = { x = 0,   y = -40, z = 0 },  ang = { p = 90, y = 0, r = 0 } }, -- 总部
}

-- 轴 → { 组, 键 } 静态查找表（pos 组 → x/y/z；ang 组 → p/y/r）
local AXIS_GROUPS = {
    ["pos.x"] = { "pos", "x" }, ["pos.y"] = { "pos", "y" }, ["pos.z"] = { "pos", "z" },
    ["ang.p"] = { "ang", "p" }, ["ang.y"] = { "ang", "y" }, ["ang.r"] = { "ang", "r" },
}

--[[
    解析轴名为 { 组, 键 }；非 6 值之一返回 nil

    @param axis string 6 值之一（Axes 枚举）
    @return table|nil { "pos"|"ang", "x"|"y"|"z"|"p"|"y"|"r" }
]]
function KARDS.Animation:ParseAxis(axis)
    return AXIS_GROUPS[axis]
end

--[[
    读取 pose 中某轴的值

    @param pose table { pos = { x, y, z }, ang = { p, y, r } }
    @param axis string 6 值之一
    @return number|nil 非法轴或缺少该组返回 nil
]]
function KARDS.Animation:GetValue(pose, axis)
    local g = self:ParseAxis(axis)
    if not g or not pose then return nil end
    local group = pose[g[1]]
    return group and group[g[2]] or nil
end

--[[
    写入 pose 中某轴的值（副作用：修改传入 pose；组缺失时自动补齐默认 0）

    @param pose  table 位置 + 角度结构
    @param axis  string 6 值之一
    @param value number 新值
    @return boolean 是否写入成功（非法轴返回 false）
]]
function KARDS.Animation:SetValue(pose, axis, value)
    local g = self:ParseAxis(axis)
    if not g or not pose then return false end
    if not pose[g[1]] then
        pose[g[1]] = (g[1] == "pos") and { x = 0, y = 0, z = 0 } or { p = 0, y = 0, r = 0 }
    end
    pose[g[1]][g[2]] = value
    return true
end

--[[
    取预设 pose 的副本（位置 + 三个角度，共 6 值；修改副本不影响预设表）

    @param name string 预设名（Poses 键）
    @return table|nil 副本；未知预设返回 nil
]]
function KARDS.Animation:GetPose(name)
    local p = self.Poses[name]
    if not p then return nil end
    return {
        pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z },
        ang = { p = p.ang.p, y = p.ang.y, r = p.ang.r },
    }
end

--[[
    注册新曲线（可扩展性入口）

    @param name string 曲线名（如 "ease_out"）
    @param fn   function 0→1 归一化缓动函数（t ∈ [0,1] → [0,1]）
]]
function KARDS.Animation:AddEasing(name, fn)
    self.Easings[name] = fn
end

--[[
    在 seconds 秒内将 6 值中的 axis 以 easing 曲线按 mode 变化到 target

    在 x（seconds）秒内将 y（axis，必须为 6 值之一）
    {线性、平滑}（easing，可扩展）{渐变到、增加、减少}（mode）z（target）。
    纯逻辑层：返回动画对象，不写卡牌属性；渲染层用 Eval / ValueAt 采样驱动显示。

    @param seconds number 时长（秒，必须 > 0）
    @param axis    string 6 值之一（Axes 枚举）
    @param easing  string|function 曲线名（Easings 注册表）或自定义缓动函数
    @param mode    string 变化模式（Modes：to 渐变到 / add 增加 / sub 减少）
    @param target  number 目标值（mode=to 为终值；add/sub 为变化量）
    @param start   number|nil 起始值（缺省 0）
    @return table|nil 动画对象，含 Eval(progress) / ValueAt(elapsed) / ValueNow()；
                      参数非法返回 nil

    动画对象字段：
      axis / start / delta / target / seconds / easing
      StartTime          真实时间模式（RealTime=true）下记录创建时刻 CurTime()
      delay              延迟开始秒数（缺省 0）：真实时间模式下等待期保持起始值，
                         如移除动画的阶段 3（升 z 0.25s + 等待 0.5s 后同时左移与旋转，
                         delay = 0.75）；非真实时间模式（直接终值）不受 delay 影响
      Eval(progress)      progress ∈ [0,1] → 该进度下的当前值（自动 clamp）
      ValueAt(elapsed)    已过 elapsed 秒 → 当前值（自动 clamp 到时长）
      ValueNow()          按真实时间开关取当前值：
                          RealTime=false → 直接终值 Eval(1)
                          RealTime=true  → (CurTime()-StartTime-delay) 插值（每帧调用即真实渐变）
]]
function KARDS.Animation:Animate(seconds, axis, easing, mode, target, start)
    if not (type(seconds) == "number" and seconds > 0) then return nil end
    if not self:ParseAxis(axis) then return nil end
    local fn = easing
    if type(easing) ~= "function" then
        fn = self.Easings[easing]
        if not fn then return nil end
    end
    if mode ~= self.Modes.To and mode ~= self.Modes.Add and mode ~= self.Modes.Sub then
        return nil
    end
    start = start or 0
    local delta
    if mode == self.Modes.To then
        delta = target - start
    elseif mode == self.Modes.Add then
        delta = target
    else
        delta = -target
    end
    local anim = {
        axis = axis,
        start = start,
        delta = delta,
        target = start + delta,
        seconds = seconds,
        easing = fn,
        StartTime = KARDS.Animation.RealTime and CurTime() or nil, -- 真实时间模式记录起点
    }
    anim.Eval = function(self, progress)
        progress = math.max(0, math.min(1, progress))
        return start + delta * fn(progress)
    end
    anim.ValueAt = function(self, elapsed)
        return self:Eval(elapsed / self.seconds)
    end
    anim.ValueNow = function(self)
        if not KARDS.Animation.RealTime then
            return self:Eval(1) -- 非真实时间：直接终值（等价 Apply(1)）
        end
        -- 延迟开始（delay 字段，缺省 0）：等待期（elapsed < 0）保持起始值
        local elapsed = CurTime() - self.StartTime - (self.delay or 0)
        if elapsed <= 0 then return start end
        return self:Eval(elapsed / self.seconds) -- 超时由 Eval clamp 到终值
    end
    return anim
end

--[[
    指定一张卡或一方玩家摄像头的一个坐标或旋转值渐变

    在 seconds 秒内将 target 的 axis（pos.x/y/z 或 ang.p/y/r）以 easing 曲线
    按 mode 变化到目标值，起始值缺省取该对象当前值；
    与 Animate 不同：AnimateCard 直接绑定渐变对象，返回的动画对象额外提供
    Apply(progress) / ApplyAt(elapsed)，将当前采样值写回该对象的对应轴。
    渐变对象约定携带 3D 变换字段 pos = { x, y, z } 与 ang = { p, y, r }
    （缺省自动补齐 0；渲染层 / 动画驱动共用，非战斗规则数据）。
    pos/ang 均为相对牌桌的世界坐标：卡牌对象与玩家摄像头实例
    （BattleCamera:GetFor 获取）共用同一坐标系，渐变结果即时作用于渲染。

    @param obj     table 渐变对象：卡牌对象或玩家摄像头实例
                  （需可读写 obj.pos / obj.ang 字段）
    @param seconds number 时长（秒，必须 > 0）
    @param axis    string 6 值之一（Axes 枚举）
    @param easing  string|function 曲线名（Easings 注册表）或自定义缓动函数
    @param mode    string 变化模式（Modes：to 渐变到 / add 增加 / sub 减少）
    @param target  number 目标值（mode=to 为终值；add/sub 为变化量）
    @param start   number|nil 起始值（缺省 = 对象当前值）
    @return table|nil 动画对象，含 Eval(progress) / ValueAt(elapsed) /
                      Apply(progress) / ApplyAt(elapsed) / ApplyNow()；
                      参数非法返回 nil
]]
function KARDS.Animation:AnimateCard(obj, seconds, axis, easing, mode, target, start)
    if not obj or type(obj) ~= "table" then return nil end
    if not self:ParseAxis(axis) then return nil end
    -- 3D 变换字段（缺省自动补齐 0，不影响既有数据）
    if not obj.pos then obj.pos = { x = 0, y = 0, z = 0 } end
    if not obj.ang then obj.ang = { p = 0, y = 0, r = 0 } end
    local pose = { pos = obj.pos, ang = obj.ang }
    local current = self:GetValue(pose, axis) or 0
    local anim = self:Animate(seconds, axis, easing, mode, target, start or current)
    if not anim then return nil end
    -- 对象绑定应用：将动画当前采样值写回该对象的对应轴
    anim.Apply = function(self, progress)
        local v = self:Eval(progress)
        KARDS.Animation:SetValue(pose, axis, v)
        return v
    end
    anim.ApplyAt = function(self, elapsed)
        return self:Apply(elapsed / self.seconds)
    end
    anim.ApplyNow = function(self)
        local v = self:ValueNow() -- 按真实时间开关取值：false=直接终值 / true=随时间渐变
        KARDS.Animation:SetValue(pose, axis, v)
        return v
    end
    return anim
end

--[[
    创建"移除"动画组（Kards 语义的移除，阵亡不触发；渲染层在"移除"操作发生时创建并驱动）

    三段时间线：
      阶段 1（0~0.25s）：0.25s 线性向上（pos.z 增加 rise）
      阶段 2（0.25~0.75s）：等待 0.5s（不动）
      阶段 3（0.75~1.75s）：1s 平滑曲线同时进行——
        卡牌向左移动到场外（pos.x 渐变到 offscreenX）
        在 xy 平面逆时针旋转 180°（ang.r 增加 180，绕 z 轴正向）

    阶段 3 的两个动画经 delay = 0.75（0.25s 升 z + 0.5s 等待）延迟开始；
    配合真实时间开关（RealTime=true）每帧调用 :ValueNow() 采样 /
    :ApplyNow() 写回即真实渐变。

    @param card       table 卡牌对象（须携带 pos/ang 字段，缺省自动补齐 0）
    @param rise       number z 轴上升量（向上）
    @param offscreenX number 场外目标 x（向左移动到场外）
    @return table|nil { rise, shift, roll } 三个动画对象；参数非法返回 nil
]]
function KARDS.Animation:CreateRemovalAnimations(card, rise, offscreenX)
    if type(card) ~= "table" or type(rise) ~= "number" or type(offscreenX) ~= "number" then
        return nil
    end
    local curZ = (card.pos and card.pos.z) or 0
    local curX = (card.pos and card.pos.x) or 0
    local curR = (card.ang and card.ang.r) or 0
    -- 阶段 1：0.25s 线性向上（pos.z +rise）
    local riseAnim = self:AnimateCard(card, 0.25, "pos.z", "linear", "add", rise, curZ)
    -- 阶段 3：1s 平滑左移到场外（pos.x → offscreenX）
    local shiftAnim = self:AnimateCard(card, 1, "pos.x", "smooth", "to", offscreenX, curX)
    shiftAnim.delay = 0.75 -- 升 z(0.25s) + 等待(0.5s) 后开始
    -- 阶段 3：1s 平滑 xy 平面逆时针旋转 180°（ang.r +180，与左移同时）
    local rollAnim = self:AnimateCard(card, 1, "ang.r", "smooth", "add", 180, curR)
    rollAnim.delay = 0.75 -- 与左移同时进行
    return { rise = riseAnim, shift = shiftAnim, roll = rollAnim }
end

-- ====================================================================
-- 拟 2D 布局坐标系（卡牌战场网格）
-- ====================================================================

--[[
    Kards 战斗系统 - 拟 2D 布局坐标系（卡牌战场网格）

    对局时玩家俯视牌桌，战场抽象为 2D 网格：列（x 方向）1~5、行（y 方向）
    P1=+1 / 前线=0 / P2=-1。网格坐标与实测空卡阵列相对坐标一一对应
    （相对坐标 = 牌桌局部坐标，z 恒为桌面顶 CardZ）；世界坐标经牌桌
    LocalToWorld 换算后与卡牌对象 pos/ang 对接（卡牌对象 pos/ang 均为
    相对牌桌的世界坐标，见 AnimateCard）。

    坐标来源（2026-08-06 实测打印，牌桌相对坐标，z 为 AABB 局部顶部 + 0.05）：
      列 x（P1 视角左→右）：列1 +16.48 / 列2 +8.28 / 列3 +0.08 / 列4 -8.12 / 列5 -16.32
      行 y：P1(+1) +12.80 / 前线(0) 0.00 / P2(-1) -12.80
      z：18.43（桌面顶，恒定）
    列/行步长与子物体系统常量一致：列步长 8.20（CardWidth 7.2 + SpacingX 1.0）、
    行步长 12.80（CardLength 10.8 + SpacingY 2.0）；网格以桌面顶中心强制居中。
]]
KARDS.Animation.Board2D = KARDS.Animation.Board2D or {}

-- 网格尺寸：列（宽/x）5、行（长/y）3
KARDS.Animation.Board2D.ColCount = 5
KARDS.Animation.Board2D.RowCount = 3

-- 列 x（列号 1~5 → 牌桌相对坐标 x；P1 视角左→右）
KARDS.Animation.Board2D.ColX = { 16.48, 8.28, 0.08, -8.12, -16.32 }
-- 行 y（行号 +1 P1 / 0 前线 / -1 P2 → 牌桌相对坐标 y）
KARDS.Animation.Board2D.RowY = { [1] = 12.80, [0] = 0.00, [-1] = -12.80 }
-- 卡牌相对 z（桌面顶，恒定）
KARDS.Animation.Board2D.CardZ = 18.43

--[[
    列号 1~5 → 牌桌相对坐标 x（越界返回 nil）

    @param col number 列号
    @return number|nil
]]
function KARDS.Animation.Board2D:ColToX(col)
    return self.ColX[col]
end

--[[
    行号 +1/0/-1 → 牌桌相对坐标 y（未知返回 nil）

    @param row number 行号（P1=+1 / 前线=0 / P2=-1）
    @return number|nil
]]
function KARDS.Animation.Board2D:RowToY(row)
    return self.RowY[row]
end

--[[
    2D 网格坐标 → 牌桌相对坐标（局部坐标，z = CardZ）

    @param col number 列号 1~5
    @param row number 行号 +1（P1）/ 0（前线）/ -1（P2）
    @return Vector|nil 越界返回 nil
]]
function KARDS.Animation.Board2D:RelPos(col, row)
    local x, y = self:ColToX(col), self:RowToY(row)
    if not x or not y then return nil end
    return Vector(x, y, self.CardZ)
end

--[[
    2D 网格坐标 → 世界坐标（经牌桌 LocalToWorld，随牌桌位置/朝向）

    @param tableEnt Entity 牌桌实体
    @param col      number 列号 1~5
    @param row      number 行号 +1/0/-1
    @return Vector|nil 越界返回 nil
]]
function KARDS.Animation.Board2D:WorldPos(tableEnt, col, row)
    local rel = self:RelPos(col, row)
    if not rel then return nil end
    return tableEnt:LocalToWorld(rel)
end

--[[
    2D 移动动画：将卡牌从当前位置平滑移至目标网格格（pos.x / pos.y 渐变）

    基于 AnimateCard（pos/ang 均为相对牌桌的世界坐标），目标值取 WorldPos
    经牌桌 LocalToWorld 换算；z 不变（俯视视角下恒定贴桌面）。

    @param card     table 卡牌对象（携带 pos/ang 字段）
    @param tableEnt Entity 牌桌实体
    @param col      number 目标列号 1~5
    @param row      number 目标行号 +1/0/-1
    @param seconds  number 时长（秒，必须 > 0）
    @param easing   string|function|nil 曲线（缺省 "smooth"）
    @return table|nil { x, y } 两个轴动画对象；参数非法返回 nil
]]
function KARDS.Animation.Board2D:MoveTo(card, tableEnt, col, row, seconds, easing)
    if type(card) ~= "table" or not IsValid(tableEnt) then return nil end
    local world = self:WorldPos(tableEnt, col, row)
    if not world then return nil end
    local curX = (card.pos and card.pos.x) or 0
    local curY = (card.pos and card.pos.y) or 0
    local animX = KARDS.Animation:AnimateCard(card, seconds, "pos.x", easing or "smooth", "to", world.x, curX)
    local animY = KARDS.Animation:AnimateCard(card, seconds, "pos.y", easing or "smooth", "to", world.y, curY)
    return { x = animX, y = animY }
end
