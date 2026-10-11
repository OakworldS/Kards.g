--[[
    Kards 战斗牌桌客户端模块：提示系统（cl_battle_hint.lua）

    屏幕中心 toast 提示：以 textUnderground.png 横向渐变图为底（materials/kards/ui/
    textUnderground.png，与 cl_init.lua 重新调度横幅同材质）+ 白色文字。
    动画（用户规格）：淡入 1.5s → 停留 3s → 淡出 1.5s（总时长 6s）。
    堆叠：最新提示位于屏幕中心（row 0），每新增一条已有提示上移一行（row +1，
    平滑滑动），早的提示逐行上移、最终移出屏幕上边（y < 0 自然裁剪不绘制）。

    观战同步（2026-08-12）：本方对局中 Push 的提示经 KardsHintRelay 中继到服务端，
    服务端仅转发给观战者（非本桌双方牌手，对手不可见），观战端收 KardsHintObserver
    后在牌桌中心 z+ 上方以 ChatFont（GMod 聊天栏内置字体）打字机动画逐字显示
    「被提示玩家名：提示内容」（3D2D 平躺朝上 + 面向观战者相机）。

    调用：KARDS.BattleHint.Push(text)（客户端任意处；服务端操作失败原因经
    KardsTableMsg 接收器统一转本系统，见 cl_init.lua）；KARDS.BattleHint.Clear()
    清空全部（退出牌桌 / 新对局，见 cl_init.lua KardsTableExited /
    KardsTableBattleStart 复位段）。

    挂载：cl_init.lua include 本文件（cl_battle_hud.lua 之后、cl_battle_ops.lua
    之前，见加载链注释）。约定：常驻钩子挂 KARDS 命名空间，状态保持本文件
    local（与 cl_battle_hud.lua 同约定）。
]]

if not CLIENT then return end

KARDS = KARDS or {}

KARDS.BattleHint = KARDS.BattleHint or {}

-- 动画时长（秒）：淡入 / 停留 / 淡出（用户规格）
local FADE_IN, HOLD, FADE_OUT = 1.5, 3.0, 1.5
local HINT_LIFE = FADE_IN + HOLD + FADE_OUT
-- 横幅内边距（x/y）/ 行距 / 行位滑动速度（每帧向目标行逼近系数，越大越快）
local PAD_X, PAD_Y, GAP, SLIDE = 26, 10, 10, 8

local hintFont = "SourceHan_Heavy_32"
local hintMat = Material("materials/kards/ui/textUnderground.png", "noclamp smooth")

-- 活跃提示：[1] = 最新（row 0 屏幕中心）… [#] = 最早（行号最大、最靠上）
-- 每项 { text, start = CurTime, row = 当前行（动画值）, targetRow = 目标行 }
local hints = {}

-- 观战端牌桌中心提示（2026-08-12）：非本桌双方牌手收到 KardsHintObserver 后登记，
-- 在牌桌中心 z+ 上方用 ChatFont（GMod 聊天栏内置字体）以打字机动画逐字显示
-- 「被提示玩家名：提示内容」，早的提示沿牌桌 +Y 逐行堆叠上移；对手不可见。
-- 每项 { tableEnt, text, start = CurTime, row = 当前行（动画值）, targetRow = 目标行 }
local obs = {}

-- 观战端 3D2D 文字：目标世界字高（卡宽 7.2 的约一半，俯视可读）/ 堆叠行距 / 浮空高度
local OBS_CHAR_H, OBS_ROW_STEP = 4.0, 6.0
-- 打字机速度：至少 24 字符/秒，长文本保证 ~1.8s 内打完
local function TypewriterCPS(len)
    return math.max(24, len / 1.8)
end

-- 透明度包络：1.5s 淡入 → 3s 全显 → 1.5s 淡出（0..1）
local function HintAlpha(life)
    if life < FADE_IN then return life / FADE_IN end
    if life <= FADE_IN + HOLD then return 1 end
    return math.max(0, 1 - (life - FADE_IN - HOLD) / FADE_OUT)
end

-- 列表 [1] 入队（最新在前，Push / Observer 两套同构列表操作收敛，阶段五 P3）：
-- 匹配项（matches 谓词）移除后整体上移一行再置顶；无匹配则全体上移一行后置顶。
-- @param list table 活跃项列表（[1] = 最新 / row 0）
-- @param item table 新项 { ..., row = 0, targetRow = 0 }
-- @param matches function(h) 谓词：h 是否为与新项等价的旧项（同文重置）
local function EnqueueUnique(list, item, matches)
    for i, h in ipairs(list) do
        if matches(h) then
            table.remove(list, i)
            for _, o in ipairs(list) do o.targetRow = o.targetRow + 1 end
            table.insert(list, 1, item)
            return
        end
    end
    for _, o in ipairs(list) do
        o.targetRow = o.targetRow + 1
    end
    table.insert(list, 1, item)
end

--[[
    推送一条提示：最新提示显示在屏幕中心（row 0），已存在的提示整体上移一行；
    相同文字的提示重置计时并回到中心（防连点刷屏堆叠）。

    @param text string 提示文字（空 / nil 忽略）
    @param noRelay boolean|nil 不中继观战者（2026-08-12：爆牌等由服务端统一给
      观战者发 KardsHintObserver 的提示——本方/对方视角化文字（你的/敌方）对观战者
      无意义且会与服务端提示重复，故跳过 KardsHintRelay）
]]
function KARDS.BattleHint.Push(text, noRelay)
    if text == nil or text == "" then return end
    -- 本方正式对局中的提示：中继给观战者（服务端转广播，对手不可见；组卡模式/
    -- 未开战提示不中继，见 table_battledeck.lua net.Receive KardsHintRelay）
    local BS = KARDS.BattleState
    if not noRelay and BS.battleStarted and BS.inTable and IsValid(BS.inTable.ent) and BS.inTable.slot then
        net.Start("KardsHintRelay")
            net.WriteEntity(BS.inTable.ent)
            net.WriteString(text)
        net.SendToServer()
    end
    local now = CurTime()
    -- 同文重置 / 常规入队统一走 EnqueueUnique（相同文字已在显示 → 移除后整体
    -- 上移一行重新置于中心并重置计时；否则已有提示全部上移一行后置顶）
    EnqueueUnique(hints, { text = text, start = now, row = 0, targetRow = 0 },
        function(h) return h.text == text end)
end

-- 清空全部提示（退出牌桌 / 新对局）：同时清空观战端牌桌中心提示
function KARDS.BattleHint.Clear()
    hints = {}
    obs = {}
end

-- 过期清理：全部提示同寿命（6s），最早推送的（表尾）最先过期——从尾向前删防索引错乱
hook.Add("Think", "KardsBattleHintThink", function()
    local now = CurTime()
    for i = #hints, 1, -1 do
        if now - hints[i].start >= HINT_LIFE then
            table.remove(hints, i)
        end
    end
    for i = #obs, 1, -1 do
        if now - obs[i].start >= HINT_LIFE then
            table.remove(obs, i)
        end
    end
end)

-- 绘制：最新提示在屏幕中心（row 0），旧提示向上逐行滑动（早的移出屏幕上边）
hook.Add("HUDPaint", "KardsBattleHintDraw", function()
    if #hints == 0 then return end
    local now = CurTime()
    local dt = FrameTime()
    local cx, cy = ScrW() * 0.5, ScrH() * 0.5
    surface.SetFont(hintFont)
    for _, h in ipairs(hints) do
        -- 行位向目标行平滑滑动（新增提示时旧提示整体上移）
        h.row = h.row + (h.targetRow - h.row) * math.min(1, dt * SLIDE)
        local life = now - h.start
        local alpha = HintAlpha(life)
        if alpha > 0.01 then
            local tw, th = surface.GetTextSize(h.text)
            local w, hh = tw + PAD_X * 2, th + PAD_Y * 2
            local x = cx - w / 2
            local y = cy - h.row * (hh + GAP) - hh / 2
            -- 已移出屏幕上边的提示不再绘制（虽 alpha 未到 0）
            if y + hh > 0 then
                local a = math.Round(255 * alpha)
                surface.SetMaterial(hintMat)
                surface.SetDrawColor(255, 255, 255, a)
                surface.DrawTexturedRect(x, y, w, hh)
                draw.SimpleText(h.text, hintFont, cx, y + hh / 2,
                    Color(255, 255, 255, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end
    end
end)

-- 观战端提示接收（2026-08-12）：服务端广播给非本桌双方牌手；同文字同牌桌重置计时
-- 并回到首行（防连点刷屏堆叠），其余整体上移一行
net.Receive("KardsHintObserver", function()
    local ent = net.ReadEntity()
    local name = net.ReadString()
    local text = net.ReadString()
    if not IsValid(ent) or text == "" then return end
    local full = name .. "：" .. text
    local now = CurTime()
    -- 同牌桌同文字重置计时并回到首行，其余整体上移一行（同 EnqueueUnique）
    EnqueueUnique(obs, { tableEnt = ent, text = full, start = now, row = 0, targetRow = 0 },
        function(o) return o.tableEnt == ent and o.text == full end)
end)

-- 观战端绘制：牌桌中心 z+ 上方 3D2D 文字（ChatFont 内置字体 + 打字机动画），
-- 平躺朝上（法线沿世界 +Z）且始终面向观战者相机，早的提示沿牌桌 +Y 逐行上移
hook.Add("HUDPaint", "KardsBattleHintObserverDraw", function()
    if #obs == 0 then return end
    local now = CurTime()
    local dt = FrameTime()
    local camPos = (KARDS.BattleCamera and KARDS.BattleCamera.ViewPos)
        or (IsValid(LocalPlayer()) and LocalPlayer():EyePos() or Vector())
    local cardZ = KARDS.Animation and KARDS.Animation.Board2D and KARDS.Animation.Board2D.CardZ or 18.43
    surface.SetFont("ChatFont")
    for _, o in ipairs(obs) do
        if IsValid(o.tableEnt) then
            o.row = o.row + (o.targetRow - o.row) * math.min(1, dt * SLIDE)
            local life = now - o.start
            if life < HINT_LIFE then
                -- 牌桌中心上方，逐行沿牌桌 +Y 堆叠（早的提示向牌桌外侧上移）
                local pos = o.tableEnt:LocalToWorld(Vector(0, o.row * OBS_ROW_STEP, cardZ + OBS_CHAR_H * 1.5))
                -- 打字机动画：逐字显示
                local n = math.floor(life * TypewriterCPS(#o.text))
                local shown = n >= #o.text and o.text or string.sub(o.text, 1, n)
                -- 3D2D：+x 水平朝向观战者相机、+y 朝下（世界 -Z）→ 文字平躺朝上且正向可读
                local _, th = surface.GetTextSize(shown)
                local scale = th > 0 and (OBS_CHAR_H / th) or 0.25
                local dx = camPos - pos
                dx.z = 0
                if dx:LengthSqr() < 0.001 then dx = Vector(1, 0, 0) else dx:Normalize() end
                local camAng = dx:AngleEx(dx:Cross(Vector(0, 0, 1)))
                cam.Start3D2D(pos, camAng, scale)
                draw.SimpleText(shown, "ChatFont", 0, 0, Color(255, 255, 255, 255),
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                cam.End3D2D()
            end
        end
    end
end)
