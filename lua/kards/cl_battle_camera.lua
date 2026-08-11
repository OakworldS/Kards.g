--[[
    战斗系统相机控制（客户端，调试/模拟用）

    通过 CalcView 钩子在客户端接管本地玩家相机，供控制台模拟 / 预览战斗场景视角
    （牌桌俯瞰、正对牌桌、自由指定坐标角度）。相机以「玩家」为单位实例化：
    每个玩家一个摄像头对象（GetFor 获取），摄像头坐标与旋转（pos/ang）与卡牌的
    坐标与旋转一致，均为相对牌桌的世界坐标——可由动画系统（sh_animation.lua 的
    AnimateCard）直接渐变：渐变玩家摄像头与渐变卡牌共用同一套坐标系，渐变结果
    即时作用于 CalcView 渲染。

    进入动画（re.md 重构）：复用 KARDS.AnimPlayer 关键帧播放器，以摄像头对象为
    目标（writer 直接写 pos/ang 字段），两关键帧路径与旧实现一致——SetView 传入
    duration + fromPos/fromAng 时，相机从起点关键帧（玩家当前视角）经 smoothstep
    缓动插值到目标关键帧（加入后相机位），时长约 1.2s，见 cl_init.lua
    KardsTableEntered 的调用。

    控制台命令 kards_camera（客户端注册，本地执行，无需 net 同步）：
      kards_camera                      -- 显示当前相机状态
      kards_camera reset                -- 恢复默认相机（解除接管）
      kards_camera table                -- 预设：牌桌正上方垂直俯视
      kards_camera front                -- 预设：正对牌桌视角
      kards_camera x y z pitch yaw [fov]-- 直接指定：位置(x,y,z) + 朝向(pitch,yaw) + 视野(fov 可选)
]]

KARDS = KARDS or {}
---@class BattleCamera 战斗相机控制（客户端，按玩家实例化）
KARDS.BattleCamera = KARDS.BattleCamera or {}

-- 各玩家摄像头实例：
-- Cameras[player] = { player, pos=Vector, ang=Angle, fov=number, active=boolean }
-- 进入动画（re.md 重构）复用 KARDS.AnimPlayer：以本表为目标，writer 直接写
-- pos/ang 字段，动画结束后定格目标姿态（无残留 anim* 字段）
KARDS.BattleCamera.Cameras = KARDS.BattleCamera.Cameras or {}

-- 预设视角（牌桌正上方垂直俯视 / 正对牌桌；相对牌桌的世界坐标）
local Presets = {
    table = { pos = Vector(0, 0, 150), ang = Angle(90, 0, 0), fov = 75 },  -- 牌桌正上方垂直俯视（聚焦牌桌，覆盖半径约 115）
    front = { pos = Vector(0, -300, 100), ang = Angle(0, 0, 0), fov = 75 }, -- 正对牌桌
}

--[[
    获取指定玩家的摄像头实例（不存在则创建）

    摄像头对象携带 pos（位置 Vector）/ ang（旋转 Angle）/ fov / active，
    坐标与旋转均为相对牌桌的世界坐标；可直接作为动画系统 AnimateCard 的
    渐变对象（读写 pos.x/y/z、ang.p/y/r），渐变写回后即时作用于 CalcView 渲染。

    @param player Player|string 玩家对象或玩家标识
    @return table|nil 该玩家的摄像头实例（player 为 nil 时返回 nil）
]]
function KARDS.BattleCamera:GetFor(player)
    if not player then return nil end
    local cam = self.Cameras[player]
    if not cam then
        cam = {
            player = player,
            pos = Vector(0, 0, 0), -- 相对牌桌的世界坐标
            ang = Angle(0, 0, 0),
            fov = 75,
            active = false,       -- 是否接管该玩家相机
        }
        self.Cameras[player] = cam
    end
    return cam
end

-- 应用预设（未知名返回 false）
local function ApplyPreset(cam, name)
    local p = Presets[name]
    if not p then return false end
    cam.pos = p.pos
    cam.ang = p.ang
    cam.fov = p.fov
    cam.active = true
    return true
end

-- 打印相机状态（控制台反馈）
local function PrintState(cam)
    print("[KARDS Camera] " .. (cam.active and "接管中" or "未接管（默认相机）"))
    if cam.active then
        print(("[KARDS Camera] 位置=(%.0f, %.0f, %.0f) 角度=(%.0f, %.0f, %.0f) FOV=%.0f"):format(
            cam.pos.x, cam.pos.y, cam.pos.z,
            cam.ang.p, cam.ang.y, cam.ang.r,
            cam.fov))
    end
end

-- 打印用法
local function PrintUsage()
    print("[KARDS Camera] 用法: kards_camera [table | front | reset | x y z pitch yaw [fov]]")
end

--[[
    代码 API：接管指定玩家摄像头并设置视角（供战斗渲染层调用）

    可选进入动画：传入 duration（秒）+ fromPos/fromAng（起点关键帧）时，相机从
    起点关键帧经 smoothstep 缓动插值到 origin/angles（两关键帧路径，re.md 重构：
    由 KARDS.AnimPlayer 关键帧播放器驱动，writer 直接写相机 pos/ang 字段）；不传
    则直接瞬切（保持原行为）。

    @param player   Player|string|nil 目标玩家（nil = 本地玩家；无本地玩家时返回 nil）
    @param origin   Vector 相机位置（相对牌桌世界坐标）
    @param angles   Angle 相机朝向
    @param fov      number|nil 视野（缺省保持当前值）
    @param duration number|nil 进入动画时长（秒），nil 为直接瞬切
    @param fromPos  Vector|nil 进入动画起点位置（缺省同 origin）
    @param fromAng  Angle|nil 进入动画起点朝向（缺省同 angles）
    @return table|nil 该玩家的摄像头实例
]]
function KARDS.BattleCamera:SetView(player, origin, angles, fov, duration, fromPos, fromAng)
    local cam = self:GetFor(player or (CLIENT and LocalPlayer() or nil))
    if not cam then return nil end
    cam.fov = fov or cam.fov
    cam.active = true
    -- 进入动画：指定时长且起点关键帧类型正确（位置 Vector / 朝向 Angle）时启动
    -- 两关键帧动画（缓动 smooth = 旧 EaseInOut smoothstep），否则清除残留动画直接定格目标
    if duration and duration > 0 and isvector(fromPos) and isangle(fromAng) then
        KARDS.AnimPlayer:Play(cam, {
            { t = 0, pos = fromPos, ang = fromAng },
            { t = duration, pos = origin, ang = angles },
        }, { group = "cameraEntry", easing = "smooth" })
    else
        KARDS.AnimPlayer:Stop(cam)
        cam.pos = origin
        cam.ang = angles
    end
    return cam
end

-- 代码 API：应用预设视角（"table" / "front"），成功返回 true
function KARDS.BattleCamera:SetPreset(player, name)
    local cam = self:GetFor(player or (CLIENT and LocalPlayer() or nil))
    if not cam then return false end
    return ApplyPreset(cam, name)
end

-- 代码 API：恢复默认相机（解除接管，并停止可能播放中的进入动画）
function KARDS.BattleCamera:Reset(player)
    local cam = self:GetFor(player or (CLIENT and LocalPlayer() or nil))
    if not cam then return end
    cam.active = false
    KARDS.AnimPlayer:Stop(cam) -- 停止进入动画（re.md 重构：动画由 KARDS.AnimPlayer 驱动）
end

-- CalcView：按本地玩家取摄像头实例，接管时生效（返回 nil 使用默认相机）
-- 同时记录当前视图（ViewPos/ViewAng，组卡构建点击的相机射线使用；未接管时清空）
hook.Add("CalcView", "kards_battle_camera", function(ply, pos, ang, fov)
    local cam = KARDS.BattleCamera.Cameras[ply]
    if not cam or not cam.active then
        KARDS.BattleCamera.ViewPos = nil
        KARDS.BattleCamera.ViewAng = nil
        return
    end
    local origin, angles = cam.pos, cam.ang
    -- 进入动画（re.md 重构）由 KARDS.AnimPlayer 驱动，逐帧写入 cam.pos/ang，
    -- 此处直接读取即可（动画结束定格目标姿态，无 animStart 插值状态）
    KARDS.BattleCamera.ViewPos = origin -- 记录当前视图（组卡点击相机射线使用）
    KARDS.BattleCamera.ViewAng = angles
    -- 回合切换轻微抖动（cl_init.lua 对方回合结束时设置 KARDS.BattleCamera.Shake）：
    -- 在 ViewPos/ViewAng 记录之后叠加（不影响相机射线精度）；幅度随进度线性衰减
    local shake = KARDS.BattleCamera.Shake
    if shake then
        local now = CurTime()
        if now < shake.endT then
            local p = (now - shake.start) / (shake.endT - shake.start)
            local amp = shake.amp * (1 - p)
            origin = origin + Vector(math.Rand(-amp, amp), math.Rand(-amp, amp), math.Rand(-amp, amp) * 0.5)
            angles = angles + Angle(math.Rand(-amp, amp) * 0.3, math.Rand(-amp, amp) * 0.3, 0)
        else
            KARDS.BattleCamera.Shake = nil -- 抖动结束，清理状态
        end
    end
    return {
        origin = origin, -- 相对牌桌的世界坐标
        angles = angles,
        fov = cam.fov,
        drawviewer = true, -- 第三人称观察，绘制本地玩家模型（同 GMod「工具 > 摄像头」的第三人称视角）
    }
end)

-- 控制台命令：kards_camera（仅客户端注册，玩家控制台输入时本地执行）
if CLIENT then
    concommand.Add("kards_camera", function(ply, cmd, args)
        local cam = KARDS.BattleCamera:GetFor(LocalPlayer())
        if not cam then return end
        local argc = #args
        if argc == 0 then
            PrintState(cam)
            return
        end

        local first = args[1]:lower()
        if first == "reset" then
            cam.active = false
            KARDS.AnimPlayer:Stop(cam) -- 停止进入动画（re.md 重构）
            print("[KARDS Camera] 已恢复默认相机")
            return
        end
        if first == "table" or first == "front" then
            if ApplyPreset(cam, first) then
                print("[KARDS Camera] 预设视角: " .. first)
                PrintState(cam)
            else
                PrintUsage()
            end
            return
        end

        -- 直接指定：x y z pitch yaw [fov]（GMod 控制台参数均为字符串，逐个 tonumber）
        local nums = {}
        for i = 1, argc do
            local n = tonumber(args[i])
            if not n then
                print("[KARDS Camera] 非法参数: " .. args[i])
                PrintUsage()
                return
            end
            nums[i] = n
        end
        if #nums < 5 then
            print("[KARDS Camera] 参数不足（需要 x y z pitch yaw，可选 fov）")
            PrintUsage()
            return
        end
        cam.pos = Vector(nums[1], nums[2], nums[3])
        cam.ang = Angle(nums[4], nums[5], 0)
        if nums[6] then cam.fov = nums[6] end
        cam.active = true
        print("[KARDS Camera] 已设置相机")
        PrintState(cam)
    end)
end
