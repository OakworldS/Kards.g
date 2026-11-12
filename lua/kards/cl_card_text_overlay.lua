--[[
    Kards 战斗系统 - 卡牌 3D2D 属性文字叠加层（客户端）

    卡牌动态属性文字：卡牌实体正面纹理使用「无属性文字」的模板卡面（hideNumbers
    离屏渲染），属性数字与效果描述以 3D2D 文字（cam.Start3D2D + SourceHan_Heavy
    字体）实时悬浮在卡牌上方对应属性位置（费用左上 / 行动花费 / 攻击左下 /
    防御右下 / 描述底部），每帧从数据源读取当前属性 → 属性变化即外观变化
    （文字不烘焙进纹理，随卡牌实体朝向/位置悬浮）。

    数据源三种（ReadData 统一读取）：
      - 本地静态表（外观编辑器 app / cardData 表）            → AddLocal
      - 战斗卡牌对象（CardInterface mock，本地引用实时读）      → AddLocal（data 为卡牌对象）
      - 战场网络实体（属性经服务端 NW 变量同步，sh_battle_render）→ AddEntity

    使用方式：
      KARDS.CardTextOverlay:AddLocal(ent, data, worldW, worldH, renderW, renderH)
      KARDS.CardTextOverlay:AddEntity(ent, worldW, worldH)
      KARDS.CardTextOverlay:Remove(ent)
      KARDS.CardTextOverlay:Clear()
]]

if not CLIENT then return end

KARDS = KARDS or {}
KARDS.CardTextOverlay = KARDS.CardTextOverlay or {}
local Overlay = KARDS.CardTextOverlay

-- 注册表：Ents[ent] = { mode = "local" | "entity", data, worldW, worldH, renderW, renderH }
Overlay.Ents = Overlay.Ents or {}

-- 卡面世界尺寸缺省（basic_card manifest bounds 36x54x0.45 × 0.2 = 7.2x10.8x0.09；
-- 战场/编辑器实体卡面宽高可用此值，也可传参覆盖）
local DEFAULT_W, DEFAULT_H = 7.2, 10.8

-- 3D2D 属性文字像素位置（RT 左上原点、y 向下）。
-- 以离屏渲染（_Render 版，cl_card_preview.lua）的位置为基准，经多轮外观对齐微调定稿：
-- 费用 (15,12) 左上 / 行动花费 (29,20) / 攻击左下 X=53.5、自底部 73.5 /
-- 防御自右 55、自底部 73.5 / 词条锚点自底部 50；无词条描述锚点 40、有词条描述锚点 30；
-- 指令卡描述自顶部 250；指令卡费用独立 (18,11)（指令模板费用位与单位有微小差异）。
local COST_X, COST_Y = 15, 12          -- 费用（左上）
-- 指令卡费用独立位置：指令模板与单位模板的卡牌花费处位置有微小差异，故单独计算
local COMMAND_COST_X, COMMAND_COST_Y = 18, 11
local ACTION_X, ACTION_Y = 29, 20      -- 行动花费（费用右侧，非指令卡）
local ATTACK_X, ATTACK_BOTTOM = 53.5, 73.5  -- 攻击（左下，自底部向上偏移）
local DEFENSE_RIGHT, DEFENSE_BOTTOM = 55, 73.5 -- 防御（右下，自底部向上偏移）——总部防御位（不与其他卡型共用）
local KEYWORDS_BOTTOM = 50             -- 词条区域（自底部向上偏移）
local DESC_BOTTOM = 40                 -- 描述区域（自底部向上偏移，无词条时锚点）
local DESC_BOTTOM_KEYWORDS = 30        -- 描述区域（有词条时锚点，紧贴词条下方）
local DESC_COMMAND_TOP = 250            -- 描述区域（指令卡：名称下方）
local DESC_COMMAND_TOP_HQ = 262.5        -- 描述区域（总部：较指令卡下移量减半，原 25 降为 12.5）

-- 单位短卡专用坐标（2026-08-11）：单位部署后的战场小模型（basic_card_unit，渲染尺寸
-- 209×290 + UV 裁切 V 轴 229/290），像素布局与完整卡（默认 300×400 纹理）不同，故
-- 独立一组常量，微调单位短卡时不影响完整单位卡。攻击与防御 y 共享 UNIT_ATTACK_BOTTOM，
-- 保证二者水平对齐（用户要求攻击与防御 y 相等）。
local UNIT_COST_X, UNIT_COST_Y = 15, 40           -- 单位短卡行动花费（替代卡牌花费位置，左上）
local UNIT_ATTACK_X, UNIT_ATTACK_BOTTOM = 53.5, 40-- 单位短卡攻击（左下，自底部向上偏移）
local UNIT_DEFENSE_OFFSET = 99                    -- 单位短卡防御：x = 攻击 x + 偏移（y 与攻击相同）

-- 悬浮沿法线偏移（避免与卡面 Z-fighting）。
-- 取值需权衡：过大则微观尺度（卡面仅 7.2×10.8）下视差明显、从斜角观察文字相对卡面
-- 纹理错位；过小则深度竞争产生闪烁。0.06 ≈ 2.5 渲染像素（scale=0.024），约为卡面厚度
-- （0.09）的 2/3，接近贴面且能稳定通过深度测试。
local FLOAT_OFFSET = 0.06

-- 飘字背景图像（2026-08-14）：materials/kards/ui/ 下预设三张背景图（攻击/防御/行动花费，
-- 用户提供），在 DrawFX 3D2D 上下文中以 surface.SetMaterial + draw.DrawTexturedRect 绘于
-- 飘字文字背衬；颜色与飘字文字同色（surface.SetDrawColor 用飘字色，见 DrawFX）。
-- 与 textUndergroundMat（cl_init.lua）同款加载方式；"noclamp smooth" 关过滤钳制。
-- 每项含预设原始像素尺寸（w/h，2026-08-14 用户规格「保持原宽高比」）：绘制用常量尺寸
-- 而非 Material:Width()/Height()——后者在纹理打包为 2 的幂尺寸时返回非原始值导致
-- 图标被拉伸；34×38 / 34×38 / 35×35 为用户提供的原始像素尺寸。
local FLOAT_BG_MATS = {
    attack = { mat = Material("materials/kards/ui/attack.png", "noclamp smooth"), w = 34, h = 38 },
    defense = { mat = Material("materials/kards/ui/defense.png", "noclamp smooth"), w = 34, h = 38 },
    actionCost = { mat = Material("materials/kards/ui/action_cost.png", "noclamp smooth"), w = 35, h = 35 },
}

-- 属性文字颜色：数字白字（与离屏渲染一致）；词条/描述纯黑字（全部无描边）
local COLOR_NUMBER = Color(201, 195, 169, 255)     -- 数值文字（花费/行动花费/攻击/防御）统一近白色 C9C3A9，符合卡牌模板风格；与 cl_card_preview.lua 的 VALUE_TEXT_COLOR 同色
local COLOR_DESC = Color(0, 0, 0, 255)              -- 词条/描述文字（纯黑）

-- 抑制删除线（2026-10-17）：被抑制单位的效果描述 3D2D 文字上叠加手绘删除线图像
-- （materials/kards/effects/other/strikethrough.png，858x236 手绘横划），
-- 绘于描述文字之后，按绘制顺序压住文字。
local STRIKE_MAT = Material("materials/kards/effects/other/strikethrough.png", "noclamp smooth")
local STRIKE_PAD_X = 7
local STRIKE_PAD_Y = 4

-- 数值变动特效（t5，2026-08-12；时长结构 2026-08-13 调整）：单位短卡/总部短卡攻防
-- （及行动花费）变动时，在原位复制一份「全等」3D2D 文字，沿卡面法线 z 上移并淡出
-- （用户规格："数值变动时…将一个全等的特效3D2D文字复制在原位…使该文字在1秒内，z向上移动，淡出"；
--   2026-08-13 延长配置："z放大途中，前1秒仅放大，后0.75秒开始淡出（保持z放大），放大速率不变"；
--   2026-08-14 修正：z 关键帧改「卡面高度倍数」——纯放大阶段（前 1 秒）线性放大到
--   一倍（= 卡面世界高度，逐卡取 entry.worldH），去掉 easeOut（其端点导数归零造成
--   「放大中途停顿」观感）；淡出阶段（后 0.75 秒）z **继续保持相同速率放大**
--   （2026-08-14 用户追加规格）至终点 FX_DURATION/FX_ZOOM_DURATION 倍＝1.75 倍，
--   alpha 淡出至 0）。
local FX_ZOOM_DURATION = 1.0                         -- 仅放大阶段（秒）：期间 alpha 保持满值
local FX_FADE_DURATION = 0.75                        -- 淡出阶段（秒）：期间 z 继续同速率放大，alpha 淡出
local FX_DURATION = FX_ZOOM_DURATION + FX_FADE_DURATION -- 特效总时长（秒）＝ 1.75
-- 飘字序列间隔（2026-08-14 用户规格「多个飘字时开始时间不相同……每个飘字间隔0.5秒」）：
-- 服务端按节点作用顺序广播（节点顺序 → 节点内对象组正序），客户端按到达顺序排队，
-- 每个飘字在前一个开始 0.5 秒后开始；间隔超过 0.5 秒到达的飘字立即开始。
local FX_QUEUE_INTERVAL = 0.5
local FX_FRAMES = {                                  -- 关键帧（t 归一化 0..1；z 为卡面高度倍数
    { t = 0, z = 0, a = 255 },                       --   0 = 卡面原位，1 = 一倍=卡面高度；
    { t = FX_ZOOM_DURATION / FX_DURATION, z = 1,     --   段内线性（无 easing）→ 纯放大阶段
      a = 255 },                                     --   连续匀速放大，1 秒处恰为一倍
    { t = 1, z = FX_DURATION / FX_ZOOM_DURATION,     --   淡出阶段 z 同速率继续放大（归一化
      a = 0 },                                       --   轴上两段速率均为 FX_DURATION/…），
}                                                    --   终点 = 1.75 倍 + alpha 淡出至 0
local STAT_COLOR_UP = Color(96, 200, 96, 255)        -- 攻防升（当前 > 源保存文件值）绿色
local STAT_COLOR_DOWN = Color(220, 80, 80, 255)      -- 攻防降（当前 < 源保存文件值）红色
local STAT_COLOR_WHITE = Color(255, 255, 255, 255)   -- 飘字白（2026-08-14：设为/减少（节点）白色飘字）
local STAT_COLOR_FADE = 0.25                         -- 攻防着色渐变时长（秒）

--[[
    动态文字颜色系统（2026-08-10）：
    每个 3D2D 文字槽位（cost / actionCost / attack / defense / keywords / desc）
    可被代码随时设置目标颜色并以指定时长平滑渐变（Overlay:SetColor，时长 0 = 立即）；
    未设置时使用默认颜色（DefaultColors）。渐变由 DrawOverlay 每帧推进，
    颜色状态挂在 entry.colors[slot] = { cur=当前绘制色, from=渐变起点, target=目标色,
    start=渐变起始时间, dur=渐变时长 }。
]]
Overlay.ColorSlots = { "cost", "actionCost", "attack", "defense", "keywords", "desc" }
Overlay.DefaultColors = {
    cost = COLOR_NUMBER,
    actionCost = COLOR_NUMBER,
    attack = COLOR_NUMBER,
    defense = COLOR_NUMBER,
    keywords = COLOR_DESC,
    desc = COLOR_DESC,
}

-- 反制激活标记（M3）：CounterActive[ent] = true 表示该手牌卡处于激活状态，
-- 花费文字转纯黑且在文字下方绘制黄色矩形（见 DrawBlockCost）。用弱键表而非 entry.data
-- 字段，避免卡面条目重建时丢标记；写入见 Overlay:SetCounterActive（cl_battle_hud.lua
-- CounterClientToggle 与 KardsCounterActive 回执）。
Overlay.CounterActive = Overlay.CounterActive or setmetatable({}, { __mode = "k" })

-- 反制激活的花色（黄色矩形，与可打出花费色一致）
local COUNTER_BG_COLOR = Color(255, 210, 60, 255)

-- 复制颜色值（返回新 Color 对象，避免渐变改写共享默认色对象）
local function CloneColor(c)
    return Color(c.r, c.g, c.b, c.a)
end

-- 新建槽位颜色状态（cur/from/target 初始均为默认色，无渐变）
local function NewColorState(color)
    local c = CloneColor(color)
    return { cur = c, from = c, target = c, start = 0, dur = 0 }
end

-- 闪卡配色（2026-10-04）：闪卡模板的 3D2D 文字层与 2D 预览层一致，
-- 花费与行动花费用纯白，其余槽位（攻/防/词条/描述）用纯黑。
-- 攻防若正处于绿/红变动着色（cur 与默认色不同），保留变动色以不丢战斗反馈。
local FLASH_COLOR_WHITE = Color(255, 255, 255, 255)
local FLASH_COLOR_BLACK = Color(0, 0, 0, 255)

local function EntryIsFlash(entry)
    return entry ~= nil and entry.data ~= nil and entry.data.cardTemplate == "flash"
end

-- 取槽位实际绘制色：非闪卡返回渐变当前色；闪卡按上述规则返回覆盖色
local function SlotColorFor(entry, slot)
    local cur = entry.colors and entry.colors[slot] and entry.colors[slot].cur
    if not EntryIsFlash(entry) then return cur end
    if slot == "cost" or slot == "actionCost" then
        return FLASH_COLOR_WHITE
    end
    if (slot == "attack" or slot == "defense") and cur then
        local def = Overlay.DefaultColors and Overlay.DefaultColors[slot]
        if def and (cur.r ~= def.r or cur.g ~= def.g or cur.b ~= def.b) then
            return cur
        end
    end
    return FLASH_COLOR_BLACK
end

-- 颜色线性插值：收敛自本文件原 LerpColors，共用 KARDS.ColorLerp（cl_battle_command_points.lua
-- 阶段五 P1 定义，运行期已加载）

-- 每帧推进 entry 全部槽位颜色渐变（DrawOverlay 绘制前调用）
local function UpdateEntryColors(entry)
    local now = CurTime()
    for slot, cs in pairs(entry.colors) do
        if cs.dur > 0 then
            local t = (now - cs.start) / cs.dur
            if t >= 1 then
                cs.cur = CloneColor(cs.target)
                cs.dur = 0
            else
                cs.cur = KARDS.ColorLerp(t, cs.from, cs.target)
            end
        end
    end
end

-- 数值变动特效注册表（t5）：FX[#FX+1] = 特效条目（见 PlayStatChangeFX）；
-- 每帧在 PostDrawOpaqueRenderables 钩子尾部 DrawFX 中按关键帧插值绘制。
Overlay.FX = Overlay.FX or {}

-- 飘字待播队列（2026-08-14 用户规格「多个飘字时开始时间不相同」）：
-- PlayStatChangeFX 不立即入 FX，而是按到达顺序计算 start（前一飘字 + FX_QUEUE_INTERVAL）
-- 后存入 _pendingFX；每帧 DrawFX 前 FlushPendingFX 把到期的移入 Overlay.FX 开始播放，
-- start 前不绘制。_nextFXTime = 下一飘字最早可用开始时间（单调递增，保证顺序）。
Overlay._pendingFX = Overlay._pendingFX or {}
Overlay._nextFXTime = Overlay._nextFXTime or 0

-- 关键帧求值（t5，2026-08-12）：frames = { { t, z, a, easing? }, ... }，t ∈ [0,1]
-- 归一化时刻（特效时间 / 总时长）。逐段线性插值；段缓动复用 KARDS.AnimPlayer.Easings
-- （关键帧动画系统——与实体动画同一套缓动曲线；飘字关键帧 z 为卡面高度倍数 0..1，
--   2026-08-14 起不设 easing 保证纯放大阶段线性连续，见 FX_FRAMES）。
-- 返回 { z = 帧定义单位（飘字：卡面高度倍数）, a = alpha 0-255 }。
local function EvalKeyframes(frames, t)
    local f0 = frames[1]
    if t <= f0.t then return f0 end
    for i = 2, #frames do
        local f = frames[i]
        if t <= f.t then
            local a, b = frames[i - 1], f
            local k = (t - a.t) / (b.t - a.t)
            local ease = KARDS.AnimPlayer and KARDS.AnimPlayer.Easings
                and KARDS.AnimPlayer.Easings[b.easing]
            if ease then k = ease(k) end
            return { z = a.z + (b.z - a.z) * k, a = a.a + (b.a - a.a) * k }
        end
    end
    return frames[#frames]
end

--[[
    攻防常驻着色（t4，2026-08-12；变动检测 2026-08-14 移除——飘字改由服务端
    KardsStatChangeFX 广播事件驱动，见文件尾 net.Receive）：仅单位短卡（_unitMode）/
    总部短卡（hqShort）参与。每帧按用户规格「对于攻防，若大于源保存文件的值，则为
    绿色，否则为红色」着色：当前 > 源值（baseStats）→ 绿色；当前 < 源值 → 红色；
    当前 == 源值 → 恢复默认色（源值 = 部署/揭晓注册时快照，见 cl_init.lua SetBaseStat 调用）。
    飘字特效（t5）不再经本函数触发：颜色/数值须区分伤害（红）/节点设为或减少（白）/
    增加（绿）——每帧 diff 无法判断来源，改由服务端各来源点广播（见 sh_battle_combat.lua
    NotifyStatFX 注释）。需在槽位文字绘制前调用。
]]
local function UpdateStatFX(entry, ent, data)
    if not entry or not (entry.data and entry.data._unitMode or entry.hqShort) then return end
    -- 攻防常驻颜色（仅登记过源值的槽位参与）
    for _, slot in ipairs({ "attack", "defense" }) do
        local base = entry.baseStats and entry.baseStats[slot]
        if base ~= nil and data[slot] ~= base then
            local target = data[slot] > base and STAT_COLOR_UP or STAT_COLOR_DOWN
            local ct = Overlay:GetTargetColor(ent, slot)
            if not ct or ct.r ~= target.r or ct.g ~= target.g or ct.b ~= target.b or ct.a ~= target.a then
                Overlay:SetColor(ent, slot, target, STAT_COLOR_FADE)
            end
        elseif base ~= nil then
            local ct = Overlay:GetTargetColor(ent, slot)
            local def = Overlay.DefaultColors and Overlay.DefaultColors[slot]
            if ct and def and (ct.r ~= def.r or ct.g ~= def.g or ct.b ~= def.b or ct.a ~= def.a) then
                Overlay:ResetColor(ent, slot, STAT_COLOR_FADE)
            end
        end
    end
end

--[[
    槽位 3D2D 像素位置（飘字用，2026-08-14）：与 DrawOverlay 各绘制块的布局常量保持一致
    （单位短卡 UNIT_* / 完整卡 ACTION_X / 总部完整卡 DEFENSE_*；总部短卡 hqShort 与
    普通卡共用 ATTACK_X+99/ATTACK_BOTTOM，见 defense 分支），
    供服务端 KardsStatChangeFX 广播驱动的飘字在对应属性原位升起。缺省渲染尺寸 300×400
    （战场单位短卡/总部短卡 209×290 由 AddLocal/AddEntity 写入 entry）。

    @param entry 叠加条目（Overlay.Ents[ent]）
    @param ent   卡牌实体（防御位总部判定与 DrawOverlay 同源：读 entry.data，非 NW）
    @param slot  "attack" / "defense" / "actionCost"
    @return x, y, ok（总部短卡无攻击/行动花费槽位 → ok = false，调用方跳过）
]]
-- 渲染像素坐标（左上原点、y 向下）→ 3D2D 像素坐标（卡面中心为原点）。
-- 注意：3D2D 上下文单位为像素，引擎按 scale 换算世界单位，
-- 此处只做平移、不再乘 scale（旧实现重复乘 scale 导致所有文字聚在中心重叠）。
-- y 映射翻转：模板顶部（py=0）映射到 3D2D -y 端（卡长 -Y 端）。上一版用
-- renderH/2 - py 使模板顶部落到卡长 +Y 端，与卡面纹理视觉顶部相反（第六轮
-- 观察：费用到左下、攻击防御偏上 = 上下颠倒、左右正常），故只翻转 y 映射；
-- 不能改 camAng（dx:Cross(-dy)→dx:Cross(dy) 会同时翻转 2D+x 导致左右颠倒，
-- 且 up 反向使文字字形在平面上镜像）。
-- 2026-08-15 阶段四 C7 收敛：DrawOverlay 与 SlotPixelPos 的原内联 PX 合并至此。
local function CardPixel(px, py, renderW, renderH)
    return px - renderW / 2, py - renderH / 2
end

-- 某槽位的 3D2D 像素坐标（飘字 FX 锚点，见 PlayStatChangeFX；与 DrawOverlay 各绘制
-- 块坐标同源——统一经 CardPixel 换算。注意：防御坐标 hqShort 行为与 DrawOverlay
-- 不完全一致——本函数 hqShort 无 entry.data → isHQ=false 走普通分支（2026-08-14
-- 修复保证飘字锚点与常驻文字一致），DrawOverlay 防御经 ReadData 的 NW isHeadquarter
-- 走总部分支 + hqShort 下移 30，两处语义保留原样）
local function SlotPixelPos(entry, ent, slot)
    local renderW = entry.renderW or 300
    local renderH = entry.renderH or 400
    local unitMode = entry.data and entry.data._unitMode
    local hqShort = entry.hqShort
    if slot == "actionCost" then
        if hqShort then return 0, 0, false end
        if unitMode then
            return CardPixel(UNIT_COST_X, UNIT_COST_Y, renderW, renderH)
        end
        return CardPixel(ACTION_X, ACTION_Y, renderW, renderH)
    elseif slot == "attack" then
        if hqShort then return 0, 0, false end
        if unitMode then
            return CardPixel(UNIT_ATTACK_X, renderH - UNIT_ATTACK_BOTTOM, renderW, renderH)
        end
        return CardPixel(ATTACK_X, renderH - ATTACK_BOTTOM, renderW, renderH)
    elseif slot == "defense" then
        local defX, defY
        -- 总部完整卡判定与 DrawOverlay/ReadData 同源（entry.data 分支）：
        -- mock（GetStat/GetCost）按 GetType()=="headquarter"、静态表按 cardType。
        -- 总部短卡（hqShort：AddEntity 无 data → isHeadquarter=false）与普通卡共用
        -- ATTACK_X+99/ATTACK_BOTTOM 位置——保证飘字锚点与常驻文字一致（2026-08-14
        -- 修复：hqShort 原走总部分支 + -50 把 x 拉到 ≈0 几何中心，与常驻文字不符）
        local d = entry.data
        local isHQ = (d and d.GetStat and d.GetType and d:GetType() == "headquarter")
            or (d and not d.GetStat and d.cardType == "headquarter")
        if isHQ then
            defX, defY = CardPixel(renderW - DEFENSE_RIGHT, renderH - DEFENSE_BOTTOM, renderW, renderH)
            defX, defY = defX - 50, defY - 37
        elseif unitMode then
            defX, defY = CardPixel(UNIT_ATTACK_X + UNIT_DEFENSE_OFFSET, renderH - UNIT_ATTACK_BOTTOM, renderW, renderH)
        else
            defX, defY = CardPixel(ATTACK_X + 99, renderH - ATTACK_BOTTOM, renderW, renderH)
        end
        return defX, defY, true
    end
    return 0, 0, false
end

-- 数字字体选择（与离屏渲染一致：单字符 48、多字符 36）
local function PickNumberFont(text)
    return #tostring(text) > 1 and "SourceHan_Heavy_36" or "SourceHan_Heavy_48"
end

-- 富文本关键词高亮词表与拆分规则见 sh_card_data.lua（KeywordsForHighlight / SplitRichKeywords）

-- 富文本字体选择（与预览层 DrawSpecialEffectRichText 规则一致：
-- 关键词/加粗 → SourceHan_Heavy_<size>；斜体 → Calibri_Italic_<size>；
-- 普通 → Calibri_<size>；指定字号字体未注册时回退到思源黑体同字号）
local function SegFont(bold, italic, keyword, size)
    size = size or 20
    if keyword or bold then return "SourceHan_Heavy_" .. size end
    if italic then
        local f = "Calibri_Italic_" .. size
        if CustomFonts and CustomFonts[f] then return f end
        return "SourceHan_Heavy_" .. size
    end
    local f = "Calibri_" .. size
    if CustomFonts and CustomFonts[f] then return f end
    return "SourceHan_Heavy_" .. size
end

-- 解析富文本 <b>/<i> 标签为格式段（与预览层 ParseFormatTags 规则一致），
-- 并把转义换行 \n 还原为真实换行符
local function ParseRichText(text)
    if not text then return {} end
    text = tostring(text):gsub("\\n", "\n")
    local segs = {}
    local pos = 1
    local bold, italic = false, false
    while pos <= #text do
        local minTag, minTagEnd, tagType = nil, nil, nil
        local startB, endB = text:find("<b>", pos, true)
        if startB and (not minTag or startB < minTag) then minTag, minTagEnd, tagType = startB, endB, "bOpen" end
        local closB, closBEnd = text:find("</b>", pos, true)
        if closB and (not minTag or closB < minTag) then minTag, minTagEnd, tagType = closB, closBEnd, "bClose" end
        local startI, endI = text:find("<i>", pos, true)
        if startI and (not minTag or startI < minTag) then minTag, minTagEnd, tagType = startI, endI, "iOpen" end
        local closI, closIEnd = text:find("</i>", pos, true)
        if closI and (not minTag or closI < minTag) then minTag, minTagEnd, tagType = closI, closIEnd, "iClose" end
        if not minTag then
            if pos <= #text then table.insert(segs, { text = text:sub(pos), bold = bold, italic = italic }) end
            break
        end
        if minTag > pos then
            table.insert(segs, { text = text:sub(pos, minTag - 1), bold = bold, italic = italic })
        end
        if tagType == "bOpen" then bold = true
        elseif tagType == "bClose" then bold = false
        elseif tagType == "iOpen" then italic = true
        elseif tagType == "iClose" then italic = false end
        pos = minTagEnd + 1
    end
    return segs
end

-- 对格式段做关键词高亮拆分（规则统一委托 sh_card_data.lua 的 SplitRichKeywords：
-- 中英双语词表、英文词边界匹配、部署/抉择连带冒号高亮）。
local function SplitKeywords(segs)
    return KARDS.CardEditor.Data.SplitRichKeywords(segs)
end

-- 富文本断行：按行宽换行（maxWidth 非空时英文按空格断词、中文逐字断行）；
-- 换行逻辑统一委托 sh_card_data.lua 的 WrapRichSegments，此处只提供字体测宽。
-- maxWidth 为 nil 时仅按源文本 \n 断行（与 2D 预览层行为一致）。
local function WrapRichLines(segs, maxWidth, size)
    return KARDS.CardEditor.Data.WrapRichSegments(segs, function(text, bold, italic, keyword)
        surface.SetFont(SegFont(bold, italic, keyword, size))
        return surface.GetTextSize(text)
    end, maxWidth)
end

-- 字号自适应：按起始字号断行，行数超出可用高度时逐级缩小字号（步长 2，下限 12）。
-- 英文文本通常比中文长约一倍，固定字号下换行过多会溢出卡面。
-- @return lines, size, lineH 断行结果 / 最终字号 / 行高
local function FitDescLines(segs, maxWidth, startSize, maxHeight)
    local size = math.max(10, startSize or 20)
    while true do
        local lines = WrapRichLines(segs, maxWidth, size)
        local lineH = math.max(10, math.floor(18 * size / 20))
        if not maxHeight or #lines * lineH <= maxHeight or size <= 12 then
            return lines, size, lineH
        end
        size = size - 2
    end
end

-- 绘制一行富文本：按 token 格式选字体，水平居中于 x（3D2D 内使用，无描边）
-- token 为单词或单字（WrapRichSegments 输出），逐 token 测宽避免拆断英文单词。
-- @return number 该行总宽度（渲染像素），抑制删除线据此确定覆盖宽度
local function DrawRichLine(tokens, x, y, color, size)
    local totalW = 0
    for _, t in ipairs(tokens) do
        surface.SetFont(SegFont(t.bold, t.italic, t.keyword, size))
        totalW = totalW + surface.GetTextSize(t.text)
    end
    local cx = x - totalW / 2
    for _, t in ipairs(tokens) do
        local font = SegFont(t.bold, t.italic, t.keyword, size)
        surface.SetFont(font)
        draw.SimpleText(t.text, font, cx, y, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        cx = cx + surface.GetTextSize(t.text)
    end
    return totalW
end

-- 卡牌是否被抑制：服务端 BuildUnitKeywordsStr 把 neutralized 写入 Kards_UnitKeywords，
-- 悬停预览复制卡在 HoverPreviewCreate 中从源卡复制该 NW 串。
local function IsInhibited(ent)
    if not IsValid(ent) then return false end
    local raw = KARDS.CardView.Read(ent).unitKeywords
    return raw ~= "" and string.find(raw, "neutralized", 1, true) ~= nil
end

--[[
    统一读取卡牌属性数据（每帧调用 → 属性变化即外观变化）

    返回：{ cost, actionCost, attack, defense, description, descFontSize, isCommand, hasKeywords, keywordsText }
    词条文本由 KARDS.CardEditor.Data.BuildKeywordsText 构建（共享函数，sh_card_data.lua 定义）；
    战场实体词条文本由服务端构建后经 NW 变量同步（sh_battle_render.lua）。
]]
-- 按实体的效果描述文本覆盖表（2026-10-04 抉择）：ent → 文本
-- 演出期间由 cl_battle_choice.lua 写入两张效果卡的 T1/T2，结算后按配置写入所选 T；
-- 覆盖优先于一切数据来源（实体 NW / 战斗句柄 / 静态外观表），见下方 ReadData 包装。
-- 弱键表：实体销毁后条目自动回收，调用方无需（也不能依赖）显式清理。
local textOverrides = setmetatable({}, { __mode = "k" })

local function ReadDataRaw(entry, ent)
    local Data = KARDS.CardEditor.Data
    if entry.mode == "entity" then
        -- 战场网络实体：属性由服务端 NW 变量同步（sh_battle_render.lua）。
        -- 卡面文本按本机语言择一，词条 NW 串为 id 列表（SerializeKeywords），
        -- 需反序列化后按当前语言重建显示文本。
        local view = KARDS.CardView.Read(ent)
        local kwList = view.keywords ~= "" and Data.DeserializeKeywords(view.keywords) or {}
        return {
            cost = view.cost,
            actionCost = view.actionCost,
            attack = view.attack,
            defense = view.defense,
            description = view.description,
            descFontSize = 20,
            isCommand = view.isCommand,
            isHeadquarter = view.isHeadquarter,
            hasKeywords = view.hasKeywords,
            keywordsText = #kwList > 0 and Data.BuildKeywordsText(kwList) or "",
        }
    end

    local d = entry.data
    if d and d._unitMode then
        -- 单位短卡（战场部署模型 basic_card_unit，2026-08-11）：AddLocal 传入静态表
        -- 仅作 _unitMode 标志，属性每帧从服务端 NW 变量读取（table_battledeck.lua
        -- OnPlayCard 初写 + ApplyCombatOutcome SyncUnitNW 战斗后刷新）；只显示
        -- 攻击/防御/行动花费（行动花费替代卡牌花费位置，DrawOverlay 依 _unitMode 跳过
        -- cost/keywords/desc）
        local view = KARDS.CardView.Read(ent)
        return {
            cost = 0,
            actionCost = view.actionCost,
            attack = view.attack,
            defense = view.defense,
            description = "",
            descFontSize = 20,
            isCommand = false,
            isHeadquarter = false,
            hasKeywords = false,
            keywordsText = "",
        }
    end

    if d and d.GetStat and d.GetCost then
        -- 战斗卡牌对象（CardInterface mock，本地引用实时读）
        local ctype = d.GetType and d:GetType() or "unit"
        local kwList = d.GetKeywords and d:GetKeywords() or {}
        return {
            cost = d:GetCost() or 0,
            actionCost = d:GetActionCost() or 0,
            attack = d:GetStat("attack") or 0,
            defense = d:GetStat("defense") or 0,
            description = Data.PickLocalized(d.GetDescription and d:GetDescription() or "",
                d.GetDescriptionEn and d:GetDescriptionEn() or ""),
            descFontSize = 20,
            isCommand = ctype == "command" or ctype == "headquarter",
            isHeadquarter = ctype == "headquarter",
            hasKeywords = #kwList > 0,
            keywordsText = KARDS.CardEditor.Data.BuildKeywordsText(kwList),
        }
    end

    -- 静态表（外观编辑器 app / cardData）
    return {
        cost = d and d.cost or 0,
        actionCost = d and d.actionCost or 0,
        attack = d and d.attack or 0,
        defense = d and d.defense or 0,
        description = Data.GetLocalizedField(d, "specialEffect"),
        descFontSize = d and d.descFontSize or 20,
        isCommand = d and (d.cardType == "command" or d.cardType == "counter_command" or d.cardType == "headquarter") or false,
        isHeadquarter = d and d.cardType == "headquarter" or false,
        hasKeywords = d and d.keywords and #d.keywords > 0 or false,
        keywordsText = KARDS.CardEditor.Data.BuildKeywordsText(d and d.keywords or {}, d and d.keywordValues, d and d.pincerValue),
    }
end

--[[
    设置 / 清除某卡牌实体的效果描述文本覆盖（2026-10-04 抉择演出用）。
    传入 nil 等价于清除；覆盖生效于本客户端全部叠加来源（entity / local / 战斗句柄）。

    @param ent  Entity 卡牌实体
    @param text string|nil 覆盖文本（nil = 清除）
]]
function Overlay:SetTextOverride(ent, text)
    if not IsValid(ent) then return end
    if text == nil then
        textOverrides[ent] = nil
    else
        textOverrides[ent] = tostring(text)
    end
end

function Overlay:ClearTextOverride(ent)
    textOverrides[ent] = nil
end

-- 读取叠加数据（对外入口）：原始数据 + 按实体文本覆盖
local function ReadData(entry, ent)
    local data = ReadDataRaw(entry, ent)
    local ov = textOverrides[ent]
    if ov ~= nil then data.description = ov end
    return data
end

--[[
    绘制单个卡牌实体的属性文字（PostDrawOpaqueRenderables 钩子内逐实体调用）

    坐标系（GMod 官方约定 cam.Start3D2D）：
      2D 坐标为像素，引擎按 scale 换算世界单位（矩阵 SetScale(scale,-scale,1)）
      2D +x = 角度 forward、2D +y = -角度 right；角度构造式 dx:AngleEx(dx:Cross(-dy))
      （dx = 期望 2D+x 的世界方向，dy = 期望 2D+y 的世界方向）

    basic_card 模型为 z-up 平躺（manifest bounds 36×54×0.45，axis_preset "x,-z,y"）：
      卡面宽轴 = 实体局部 +X → ent:GetForward()（对应渲染像素宽 renderW）
      卡面长轴 = 实体局部 +Y → ent:GetRight()（对应渲染像素高 renderH）
      卡面法线 = 实体局部 +Z → ent:GetUp()
    渲染 RT 像素坐标（renderW×renderH，左上原点）经 PX 平移到卡面中心原点后
    由引擎缩放映射到卡面世界尺寸（worldW×worldH）。
]]
--[[
    绘制块拆分（2026-08-15 阶段四 C7）：DrawOverlay 长函数按绘制块拆为文件级函数。
    公共上下文打包为 ctx（data/entry/ent/renderW/renderH/unitMode/hqShort/pileTopOnly），
    各块按自身条件守卫后绘制；坐标统一经 CardPixel 换算（原内联 PX）。
]]

-- 块 1：费用（左上；指令卡用独立位置，因指令模板与单位模板费用位有微小差异；
-- 总部无费用，不绘制；单位模式跳过卡牌花费，由行动花费替代）
local function DrawBlockCost(ctx)
    local data, entry = ctx.data, ctx.entry
    if data.isHeadquarter or ctx.unitMode then return end
    local costText = tostring(data.cost)
    local costX = data.isCommand and COMMAND_COST_X or COST_X
    local costY = data.isCommand and COMMAND_COST_Y or COST_Y
    local cx, cy = CardPixel(costX, costY, ctx.renderW, ctx.renderH)
    local font = PickNumberFont(costText)
    -- 反制激活（M3）：花费文字转纯黑，且在文字下方绘制黄色矩形（先画矩形后画文字，
    -- 矩形作文字底衬）。矩形尺寸由字体测量加内边距（左右各 6px、上下各 4px）
    if ctx.ent and Overlay.CounterActive[ctx.ent] then
        surface.SetFont(font)
        local tw, th = surface.GetTextSize(costText)
        local padX, padY = 6, 4
        local rw, rh = tw + padX * 2, th + padY * 2
        surface.SetDrawColor(COUNTER_BG_COLOR)
        surface.DrawRect(cx - rw / 2, cy - rh / 2, rw, rh)
        draw.SimpleText(costText, font, cx, cy, Color(0, 0, 0, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        return
    end
    draw.SimpleText(costText, font, cx, cy, SlotColorFor(entry, "cost"), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- 块 1.5：卡组计数（同卡 ≥2：该卡实体右上外侧显示 ×N 计数，带描边；
-- 不受 pileTopOnly 限制，计数卡即使被上层卡盖住也显示）
local function DrawBlockPileCount(ctx)
    local pileCount = ctx.ent:GetNWInt("Kards_PileCount", 0)
    if pileCount >= 2 then
        local cpx, cpy = CardPixel(ctx.renderW + 18, 10, ctx.renderW, ctx.renderH) -- 卡牌顶处、卡牌外部右侧
        draw.SimpleTextOutlined("×" .. pileCount, "SourceHan_Heavy_36", cpx, cpy, COLOR_NUMBER, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(0, 0, 0, 255))
    end
end

-- 块 2：行动花费（费用右侧，非指令卡；单位模式替代卡牌花费位置；总部短卡无行动花费）
local function DrawBlockActionCost(ctx)
    local data, entry = ctx.data, ctx.entry
    if data.isCommand or ctx.pileTopOnly or ctx.hqShort then return end
    -- 单位短卡用专用左上坐标（UNIT_COST_X/Y），完整卡行动花费用 ACTION_X/Y。
    -- 注意：不能用 `cond and CardPixel(...) or CardPixel(...)` —— and/or 会把多返回值
    -- 裁剪为单值，导致 ay 恒为 nil（2026-08-11 实测三文字全部画在 y=0 水平线）
    local ax, ay
    if ctx.unitMode then
        ax, ay = CardPixel(UNIT_COST_X, UNIT_COST_Y, ctx.renderW, ctx.renderH)
    else
        ax, ay = CardPixel(ACTION_X, ACTION_Y, ctx.renderW, ctx.renderH)
    end
    local actionCostText = tostring(data.actionCost)
    -- 单位模式：行动花费替代卡牌花费位置，字号沿用原卡牌花费字号（48/36，
    -- 与 PickNumberFont 一致）；普通卡行动花费维持 24/18
    local actionCostFont = ctx.unitMode and PickNumberFont(actionCostText)
        or (#actionCostText > 1 and "SourceHan_Heavy_18" or "SourceHan_Heavy_24")
    draw.SimpleText(actionCostText, actionCostFont, ax, ay, SlotColorFor(entry, "actionCost"), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- 块 3：攻击（左下；总部无攻击，不绘制；总部短卡亦不绘制）
local function DrawBlockAttack(ctx)
    local data, entry = ctx.data, ctx.entry
    if data.isCommand or ctx.pileTopOnly or ctx.hqShort then return end
    -- 单位短卡用专用攻击坐标（UNIT_ATTACK_X/UNIT_ATTACK_BOTTOM）。
    -- 注意：不能 `cond and CardPixel(...) or CardPixel(...)`，会吞掉多返回值使 aty 为 nil
    local atx, aty
    if ctx.unitMode then
        atx, aty = CardPixel(UNIT_ATTACK_X, ctx.renderH - UNIT_ATTACK_BOTTOM, ctx.renderW, ctx.renderH)
    else
        atx, aty = CardPixel(ATTACK_X, ctx.renderH - ATTACK_BOTTOM, ctx.renderW, ctx.renderH)
    end
    local attackText = tostring(data.attack)
    draw.SimpleText(attackText, PickNumberFont(attackText), atx, aty, SlotColorFor(entry, "attack"), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- 块 4：防御（总部与单位位置反转：总部在防御位，单位 x 与攻击力相同、y 自底 155）
local function DrawBlockDefense(ctx)
    local data, entry = ctx.data, ctx.entry
    if (data.isCommand and not data.isHeadquarter) or ctx.pileTopOnly then return end
    local defText = tostring(data.defense)
    local defX, defY
    if data.isHeadquarter then
        -- 总部：防御位（自右 55、自底 73.5 + 历史外观对齐微调偏移）
        defX, defY = CardPixel(ctx.renderW - DEFENSE_RIGHT, ctx.renderH - DEFENSE_BOTTOM, ctx.renderW, ctx.renderH)
        defX, defY = defX - 50, defY - 37
        -- 总部短卡（UV 裁切后仅上部 229px 可见）：防御文字下移 15px 贴合裁切后区域
        -- （hqShort 分支独立偏移，不影响完整总部卡）
        if ctx.hqShort then defY = defY + 30 end
    else
        -- 单位：y 与攻击力相同；小模型单位（unitMode）用专用坐标
        --（x = 攻击 x + UNIT_DEFENSE_OFFSET，y 与攻击共享 UNIT_ATTACK_BOTTOM 保证水平对齐），
        -- 完整单位卡维持原偏移 99、自底 ATTACK_BOTTOM。
        -- 注意：不能 `cond and CardPixel(...) or CardPixel(...)`，会吞掉多返回值使 defY 为 nil
        if ctx.unitMode then
            defX, defY = CardPixel(UNIT_ATTACK_X + UNIT_DEFENSE_OFFSET, ctx.renderH - UNIT_ATTACK_BOTTOM, ctx.renderW, ctx.renderH)
        else
            defX, defY = CardPixel(ATTACK_X + 99, ctx.renderH - ATTACK_BOTTOM, ctx.renderW, ctx.renderH)
        end
    end
    local defFont = data.isHeadquarter and (#defText > 1 and "SourceHan_Heavy_56" or "SourceHan_Heavy_72") or PickNumberFont(defText)
    draw.SimpleText(defText, defFont, defX, defY, SlotColorFor(entry, "defense"), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- 块 5：词条（底部上方，描述之前；纹理已不烘焙词条，转由本层实时绘制；单位模式跳过；总部短卡无词条）
-- 卡面文字区可用宽度（与编辑器预览/离线渲染同基准，2026-11-01 修复折行不一致）：
-- 编辑器侧为 `previewW - 40 * s`（s = ComputeCardScaleFactor，边距随缩放），
-- 而本层此前固定用 `renderW - 40`，s < 1 时实体可用宽度更窄，同一段描述会多折一行。
-- 由 RT 高反推 s（基准 300×400，RT 高 = 400 * s）；编辑器预览高 = RT 高 + 10，
-- 4:3 下预览宽 = RT 宽 + 7.5，一并补回，使两侧折行结果完全一致。
-- @return number 描述/词条可用宽度（渲染像素）
local function DescMaxWidth(ctx)
    local s = math.max(ctx.renderH / 400, 0.1)
    return ctx.renderW + 7.5 - 40 * s
end

local function DrawBlockKeywords(ctx)
    local data, entry = ctx.data, ctx.entry
    if data.keywordsText == "" or ctx.pileTopOnly or ctx.unitMode or ctx.hqShort then return end
    -- 词条单行居中；英文词条串更长，超出卡面文字区时逐级缩小字号（20 → 12，步长 2）
    local maxWidth = DescMaxWidth(ctx)
    local kwSize = 20
    surface.SetFont("SourceHan_Heavy_" .. kwSize)
    while kwSize > 12 and surface.GetTextSize(data.keywordsText) > maxWidth do
        kwSize = kwSize - 2
        surface.SetFont("SourceHan_Heavy_" .. kwSize)
    end
    local kx, ky = CardPixel(ctx.renderW / 2, ctx.renderH - KEYWORDS_BOTTOM, ctx.renderW, ctx.renderH)
    draw.SimpleText(data.keywordsText, "SourceHan_Heavy_" .. kwSize, kx, ky, SlotColorFor(entry, "keywords"), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- 块 6：效果描述（底部区域，富文本多行；源文本 \n 强制换行 + 按卡面宽度自动换行，
-- 纹理已不烘焙描述，转由本层实时绘制；单位模式跳过；总部短卡无描述）
-- 富文本继承节点编辑器格式：<b> 加粗 / <i> 斜体 / 关键词高亮（与预览层规则一致）
local function DrawBlockDescription(ctx)
    local data, entry = ctx.data, ctx.entry
    local descSegs = SplitKeywords(ParseRichText(data.description))
    local hasText = false
    for _, s in ipairs(descSegs) do if s.text ~= "" then hasText = true break end end
    if not hasText or ctx.pileTopOnly or ctx.unitMode or ctx.hqShort then return end
    -- 描述锚点：指令卡在名称下方；单位有词条在词条下方；单位无词条在底部词条位
    local baseY
    if data.isCommand then
        baseY = data.isHeadquarter and DESC_COMMAND_TOP_HQ or DESC_COMMAND_TOP
    elseif data.hasKeywords then
        baseY = ctx.renderH - DESC_BOTTOM_KEYWORDS
    else
        baseY = ctx.renderH - DESC_BOTTOM
    end
    -- 卡面文字区可用宽度（与编辑器预览/离线渲染同基准，见 DescMaxWidth）；英文长文本按宽度断词
    local maxWidth = DescMaxWidth(ctx)
    -- 可用高度：指令卡向下绘制到卡底（预留品质图标区）；其余卡以锚点为中心向上下扩展
    -- （多行垂直居中绘制，底部空间按两倍折算）；预留量随卡面缩放因子同比例，与编辑器一致
    local descScale = math.max(ctx.renderH / 400, 0.1)
    local bottomRoom = ctx.renderH - baseY
    local maxHeight = data.isCommand and (bottomRoom - 30 * descScale) or (bottomRoom * 2 - 12 * descScale)
    local lines, descSize, lineH = FitDescLines(descSegs, maxWidth, data.descFontSize or 20, maxHeight)
    local startY = baseY - (#lines - 1) * lineH / 2 -- 多行垂直居中于锚点
    local maxLineW = 0
    for i, ln in ipairs(lines) do
        local lx, ly = CardPixel(ctx.renderW / 2, startY + (i - 1) * lineH, ctx.renderW, ctx.renderH)
        local lineW = DrawRichLine(ln, lx, ly, SlotColorFor(entry, "desc"), descSize)
        if lineW > maxLineW then maxLineW = lineW end
    end
    -- 抑制删除线：在描述文字之后绘制（压住文字），覆盖整块描述区域
    if IsInhibited(ctx.ent) then
        local blockW = maxLineW + STRIKE_PAD_X * 2
        local blockH = #lines * lineH + STRIKE_PAD_Y * 2
        local cx, cy = CardPixel(ctx.renderW / 2, startY + (#lines - 1) * lineH / 2, ctx.renderW, ctx.renderH)
        surface.SetMaterial(STRIKE_MAT)
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRect(cx - blockW / 2, cy - blockH / 2, blockW, blockH)
    end
end

-- 块 7：词条图标（2026-08-13）：仅小模型单位或总部短卡；右上角外侧竖排、
-- 深灰底 + 颜色规则 / 数值数字 / 出场与变更闪烁，见 cl_battle_keyword_icons.lua。
-- 隐蔽单位部署期卡背朝上（hideWhenBack 已提前 return），揭示后首次绘制
-- 模块内自动触发出场动画，不在此额外处理
local function DrawBlockKeywordIcons(ctx)
    if (ctx.unitMode or ctx.hqShort) and KARDS.KeywordIcons then
        KARDS.KeywordIcons:Draw(ctx.ent, ctx.renderW, ctx.renderH)
    end
end

local function DrawOverlay(entry, ent)
    -- 卡背朝上（hideWhenBack）判定移入下方 cam.Start3D2D 块内：隐蔽单位卡背朝上
    -- 期间仍需绘制词条图标（只显示「隐蔽」，见 2026-08-13 用户规格 / KeywordIcons:Draw）
    -- 从实体当前朝向直接派生卡面轴线（对平躺/倾斜/竖立任意姿态自适应）：
    -- 3D2D +x 沿卡宽（ent:GetForward()）、+y 沿卡长（ent:GetRight()），
    -- 避免旧实现 Angle(-90, y, 0) 的 forward 竖直导致 2D+x 沿世界 Z（文字垂直叠在卡面上）。
    local dx = ent:GetForward()
    local dy = ent:GetRight()
    local camAng = dx:AngleEx(dx:Cross(-dy))
    -- 悬浮偏移沿卡面法线（实体局部 +Z），避免与卡面 Z-fighting
    local pos = ent:GetPos() + ent:GetUp() * FLOAT_OFFSET

    local renderW = entry.renderW or 300
    local renderH = entry.renderH or 400
    local worldW = entry.worldW or DEFAULT_W
    local worldH = entry.worldH or DEFAULT_H
    local scale = worldW / renderW

    -- 3D2D 绘制包裹在 pcall 中：任何绘制异常都会先执行 cam.End3D2D，
    -- 避免 3D2D 模型矩阵残留在矩阵栈上污染后续 3D 渲染（曾导致卡面模型消失）
    cam.Start3D2D(pos, camAng, scale)
    local ok, err = pcall(function()
        -- 推进本卡全部槽位的文字颜色渐变（动态颜色系统，见 SetColor）
        UpdateEntryColors(entry)
        local data = ReadData(entry, ent)
        -- 单位模式（_unitMode）：仅绘制攻击/防御/行动花费，行动花费替代卡牌花费位置
        local unitMode = entry.data and entry.data._unitMode
        -- 总部短卡模式（hqShort）：仅绘制防御（总部无攻击/行动花费/词条/描述；
        -- 短卡模型切换后重绑时传入，见 cl_init.lua StartHQReveal onComplete）
        local hqShort = entry.hqShort

        -- 卡背朝上（hideWhenBack，2026-08-12）：抽牌动画等待/翻面阶段不绘制 3D2D
        -- 文字——抽牌卡动画可排队/delay（AnimPlayer 首帧快照此刻姿态），等待期间实体
        -- 停在卡组顶且卡背朝上（服务端 SpawnDeckDrawCard 初始 pitch=180），若照常
        -- 绘制文字会在卡组顶泄露所抽牌的攻击/防御/费用。翻面过程 pitch 越过 ±90 后
        -- 文字随卡面一起出现。隐蔽单位（卡背朝上 + Kards_IsHidden）例外：词条图标
        -- 仍需绘制——隐蔽期服务端词条串=stealth，只显示「隐蔽」图标（2026-08-13
        -- 用户规格）；揭示动画期间由词条模块 RevealEnd 屏蔽，动画结束后正常入场
        if entry.hideWhenBack then
            local pitch = ent:GetAngles().pitch
            if math.abs(math.NormalizeAngle(pitch)) > 90 then
                if (unitMode or hqShort) and KARDS.KeywordIcons then
                    KARDS.KeywordIcons:Draw(ent, renderW, renderH)
                end
                return
            end
        end
        -- 攻防常驻着色（t4）：升绿/降红/持平默认色；飘字特效（t5）由服务端
        -- KardsStatChangeFX 广播事件驱动，不再经本函数 diff 触发（见 UpdateStatFX 注释）
        UpdateStatFX(entry, ent, data)


        -- 网格卡达携带上限已翻面（卡背朝上）：不绘制任何 3D2D 文字
        if ent:GetNWBool("Kards_GridFlipped", false) then
            return
        end

        -- 卡组堆叠非顶层卡（性能优化）：仅绘制卡牌花费，其余文字（行动花费/攻防/词条/描述）不绘制。
        -- 顶层卡（最后一张）与网格卡/总部卡不受影响；顶层标志由服务端 Kards_IsPileTop NW 维护
        local pileTopOnly = ent:GetNWString("Kards_CardRole", "") == "deck"
            and ent:GetNWString("Kards_DeckRole", "grid") == "pile"
            and not ent:GetNWBool("Kards_IsPileTop", false)

        -- 绘制块公共上下文（2026-08-15 C7 拆分：7 个绘制块文件级函数共用，各块按
        -- 自身条件守卫后绘制；坐标经共享 CardPixel 换算，原内联 PX 已移除）
        local ctx = {
            data = data, entry = entry, ent = ent,
            renderW = renderW, renderH = renderH,
            unitMode = unitMode, hqShort = hqShort, pileTopOnly = pileTopOnly,
        }
        DrawBlockCost(ctx)          -- 1. 费用
        DrawBlockPileCount(ctx)     -- 1.5 卡组计数
        DrawBlockActionCost(ctx)    -- 2. 行动花费
        DrawBlockAttack(ctx)        -- 3. 攻击
        DrawBlockDefense(ctx)       -- 4. 防御
        DrawBlockKeywords(ctx)      -- 5. 词条
        DrawBlockDescription(ctx)   -- 6. 效果描述
        DrawBlockKeywordIcons(ctx)  -- 7. 词条图标
    end)
    cam.End3D2D()
    if not ok then
        print("[KARDS] CardTextOverlay 绘制异常: " .. tostring(err))
    end
end

--[[
    注册本地数据叠加（编辑器 3D2D 文字卡生成 / 本地卡牌对象）

    @param ent      Entity 卡牌实体
    @param data     table 静态属性表（app / cardData）或战斗卡牌对象
    @param worldW   number|nil 卡面世界宽（缺省 24 = basic_card×0.2）
    @param worldH   number|nil 卡面世界高（缺省 36）
    @param renderW  number|nil 无属性文字卡面渲染像素宽（缺省 300）
    @param renderH  number|nil 无属性文字卡面渲染像素高（缺省 400）
    @param hideWhenBack boolean|nil 卡背朝上（pitch 翻面）时不绘制文字（抽牌动画
           等待/翻面阶段用：卡背朝上期间不泄露牌面信息，见 cl_init.lua InitDrawCardFace）
]]
function Overlay:AddLocal(ent, data, worldW, worldH, renderW, renderH, hideWhenBack)
    if not IsValid(ent) then return end
    local entry = {
        mode = "local",
        data = data,
        worldW = worldW or DEFAULT_W,
        worldH = worldH or DEFAULT_H,
        renderW = renderW or 300,
        renderH = renderH or 400,
        hideWhenBack = hideWhenBack or nil,
        baseStats = {}, -- 源保存文件值（t4 攻防颜色规则基准，SetBaseStat 写入）
    }
    entry.colors = {}
    for _, slot in ipairs(self.ColorSlots) do
        entry.colors[slot] = NewColorState(self.DefaultColors[slot])
    end
    self.Ents[ent] = entry
end

--[[
    注册战场网络实体叠加（属性经实体 NW 变量读取，服务端同步）

    @param ent     Entity 卡牌实体（sent_pmx_static_imported）
    @param worldW  number|nil 卡面世界宽（缺省 24）
    @param worldH  number|nil 卡面世界高（缺省 36）
    @param renderW number|nil 无属性文字卡面渲染像素宽（缺省 300；总部短卡 209）
    @param renderH number|nil 无属性文字卡面渲染像素高（缺省 400；总部短卡 290）
    @param hqShort boolean|nil 总部短卡模式（true = 仅绘制防御：总部无攻击/行动花费/
                   词条/描述，短卡模型切换后重绑时传入）
]]
function Overlay:AddEntity(ent, worldW, worldH, renderW, renderH, hqShort)
    if not IsValid(ent) then return end
    local entry = {
        mode = "entity",
        worldW = worldW or DEFAULT_W,
        worldH = worldH or DEFAULT_H,
        renderW = renderW or 300,
        renderH = renderH or 400,
        hqShort = hqShort or nil,
        baseStats = {}, -- 源保存文件值（t4 攻防颜色规则基准，SetBaseStat 写入）
    }
    entry.colors = {}
    for _, slot in ipairs(self.ColorSlots) do
        entry.colors[slot] = NewColorState(self.DefaultColors[slot])
    end
    self.Ents[ent] = entry
end

--[[
    设置某槽位的「源保存文件值」（t4 攻防颜色规则基准，2026-08-12）：攻防当前值与之
    比较 → 大于绿色 / 小于红色 / 持平恢复默认色（UpdateStatFX）。源值 = 卡牌保存文件
    中的属性值（单位部署 / 总部揭晓注册时快照服务端初写 NW，见 cl_init.lua 调用处）。

    @param ent   Entity 卡牌实体（须已 AddLocal / AddEntity 注册）
    @param slot  string 槽位（attack / defense）
    @param value number 源保存文件值
]]
function Overlay:SetBaseStat(ent, slot, value)
    local entry = self.Ents[ent]
    if not entry then return end
    entry.baseStats[slot] = value
end

-- 移除指定实体的文字叠加
function Overlay:Remove(ent)
    self.Ents[ent] = nil
    self.CounterActive[ent] = nil -- 反制激活标记（M3）：随叠加一并清理
    -- 清理该实体的数值变动特效（实体失效/文字重绑时残留特效会引用失效实体）
    for i = #self.FX, 1, -1 do
        if self.FX[i].ent == ent then table.remove(self.FX, i) end
    end
    -- 同步清理待播队列中该实体的飘字（2026-08-14 飘字序列）
    for i = #self._pendingFX, 1, -1 do
        if self._pendingFX[i].ent == ent then table.remove(self._pendingFX, i) end
    end
end

-- 清空全部文字叠加
function Overlay:Clear()
    self.Ents = {}
    self.FX = {}
    self._pendingFX = {}   -- 飘字序列：一并清空待播队列（2026-08-14）
    self._nextFXTime = 0
    self._fxBatch = {}    -- 同一刻飘字收集批：清空未入队的条目（2026-10-27）
    self.CounterActive = {} -- 反制激活标记（M3）：随叠加一并清空
end

--[[
    设置某张卡某个 3D2D 文字槽位的目标颜色（可随时调用，动态颜色系统）

    @param ent   Entity 卡牌实体（须已 AddLocal / AddEntity 注册）
    @param slot  string 槽位 id（Overlay.ColorSlots："cost"/"actionCost"/"attack"/"defense"/"keywords"/"desc"）
    @param color Color 目标颜色（nil 忽略）
    @param dur   number|nil 渐变时长（秒，缺省 0 = 立即生效；>0 从当前色平滑渐变到目标色）
]]
function Overlay:SetColor(ent, slot, color, dur)
    local entry = self.Ents[ent]
    if not entry or not entry.colors or not color then return end
    local cs = entry.colors[slot]
    if not cs then return end
    dur = dur or 0
    if dur <= 0 then
        cs.cur = CloneColor(color)
        cs.from = cs.cur
        cs.target = cs.cur
        cs.start = 0
        cs.dur = 0
    else
        cs.from = CloneColor(cs.cur)
        cs.target = CloneColor(color)
        cs.start = CurTime()
        cs.dur = dur
    end
end

-- 将某槽位颜色渐变回默认色（dur 缺省 0 = 立即恢复）
function Overlay:ResetColor(ent, slot, dur)
    local def = self.DefaultColors and self.DefaultColors[slot]
    if def then self:SetColor(ent, slot, def, dur) end
end

-- 返回当前（含渐变中途）颜色；未注册/无效槽位返回 nil
function Overlay:GetColor(ent, slot)
    local entry = self.Ents[ent]
    local cs = entry and entry.colors and entry.colors[slot]
    return cs and cs.cur or nil
end

-- 返回目标颜色（渐变完成后的颜色；未设置过返回默认色，调用方可据此避免重复设置重启渐变）
function Overlay:GetTargetColor(ent, slot)
    local entry = self.Ents[ent]
    local cs = entry and entry.colors and entry.colors[slot]
    return cs and cs.target or nil
end

--[[
    设置/查询反制激活标记（M3）：标记为真时，该卡花费文字转纯黑且在文字下方绘制
    黄色矩形（见 DrawBlockCost）。用弱键表而非 entry.data 字段，避免卡面条目重建
    时丢标记。写入见 cl_battle_hud.lua CounterClientToggle 与 KardsCounterActive 回执。

    @param ent    Entity 卡牌实体
    @param active boolean 是否处于激活状态
]]
function Overlay:SetCounterActive(ent, active)
    if active then
        self.CounterActive[ent] = true
    else
        self.CounterActive[ent] = nil
    end
end

function Overlay:IsCounterActive(ent)
    return self.CounterActive[ent] == true
end

--[[
    数值变动特效（t5，2026-08-12）：在原位复制一份「全等」3D2D 文字（内容/字体/位置/
    起始颜色与源槽位一致），FX_DURATION 秒内沿卡面法线 z 上移并淡出（关键帧动画系统
    FX_FRAMES，EvalKeyframes 逐帧插值；音效自 2026-08-13 起由服务端 KardsStatChangeSound
    广播驱动，见 cl_init.lua net.Receive，不再随特效播放）。
    2026-08-14：改为 3D2D 方案——文字背衬按槽位绘制 FLOAT_BG_MATS 背景图像
    （materials/kards/ui/ 预设，颜色与文字同色），不再使用 floating_text 模型。

    @param ent   Entity 卡牌实体
    @param slot  string 槽位（attack / defense / actionCost）
    @param text  string 文字内容（与源槽位全等）
    @param font  string 字体
    @param x,y   number 绘制像素坐标（3D2D 中心原点）
    @param color Color  起始颜色（通常 = 该槽位当前绘制色）
]]
function Overlay:PlayStatChangeFX(ent, slot, text, font, x, y, color)
    if not IsValid(ent) then return end
    -- 飘字序列（2026-08-14 用户规格）：多个飘字开始时间不相同，按入队顺序排队，
    -- 每个飘字在前一个开始 FX_QUEUE_INTERVAL（0.5 秒）后开始；间隔超过 0.5 秒
    -- 入队的飘字立即开始。入队顺序由调用方决定：同一刻的飘字先由 KardsStatChangeFX
    -- 接收器按对象分组洗牌（组内攻击力先于防御力），再逐条调用本函数（2026-10-27）。
    local now = CurTime()
    local start = math.max(now, self._nextFXTime or now)
    self._nextFXTime = start + FX_QUEUE_INTERVAL
    -- 待播队列：start 前不绘制（不入 Overlay.FX），每帧 DrawFX 前 FlushPendingFX 到期移入
    local entry = self.Ents[ent]
    self._pendingFX[#self._pendingFX + 1] = {
        ent = ent,
        slot = slot,
        text = text,
        font = font,
        x = x, y = y,
        color = CloneColor(color or COLOR_NUMBER),
        start = start,
        -- 2026-08-14 用户规格「纯 z 放大阶段终点 z 放大一倍 + 淡出时继续保持相同速率放大」：
        -- 一倍 = 卡面世界高度（逐卡取 entry.worldH，完整卡 10.8 / 单位短卡 8.528；未登记回退
        -- DEFAULT_H）；1 秒处恰为一倍，淡出阶段 z 同速率继续放大至终点 1.75 倍（见 FX_FRAMES）
        zUp = entry and entry.worldH or DEFAULT_H,
    }
end

--[[
    白色飘字（设为语义）包装（2026-09-26 缺口 I）：供外部模块（cl_battle_veteran.lua）
    在老兵升级动画中按槽位原位飘出白色数字。

    value 为要显示的数值本身（不是变动量）：攻防传老兵化之后的新值（白字语义为
    「设为」）；行动花费传带符号变动值（沿用既有约定）。颜色恒为白色，绕开
    KardsStatChangeFX 接收器的增红减绿规则。多次连调由 PlayStatChangeFX 内部的
    0.5 秒错峰队列依次播出。

    @param ent   Entity 卡牌实体
    @param slot  string 槽位（attack / defense / actionCost）
    @param value number 要显示的数值
    @return boolean 是否已触发飘字
]]
function KARDS.CardTextOverlay:PlayStatFXWhite(ent, slot, value)
    if not IsValid(ent) or value == nil then return false end
    local entry = Overlay.Ents[ent]
    if not entry then return false end -- 未登记 3D2D 叠加的实体（如手牌/未网络化）不飘字
    local text = tostring(value)
    local x, y, ok = SlotPixelPos(entry, ent, slot)
    if not ok then return false end -- 总部短卡无对应槽位 → 跳过
    Overlay:PlayStatChangeFX(ent, slot, text, PickNumberFont(text), x, y, STAT_COLOR_WHITE)
    return true
end

-- 飘字待播队列到期移入（2026-08-14）：把 _pendingFX 中 start <= now 的条目移入
-- Overlay.FX 开始绘制（实体已失效的丢弃）；未到期保留，下一帧继续检查。
local function FlushPendingFX(now)
    local pending = Overlay._pendingFX
    local i = 1
    while i <= #pending do
        local fx = pending[i]
        if fx.start <= now then
            if IsValid(fx.ent) then
                Overlay.FX[#Overlay.FX + 1] = {
                    ent = fx.ent,
                    entry = Overlay.Ents[fx.ent],
                    slot = fx.slot,
                    text = fx.text,
                    font = fx.font,
                    x = fx.x, y = fx.y,
                    color = fx.color,
                    start = fx.start,
                    dur = FX_DURATION,
                    frames = FX_FRAMES,
                    zUp = fx.zUp,
                }
            end
            table.remove(pending, i)
        else
            i = i + 1
        end
    end
end

-- 数值变动特效绘制（t5）：每条特效独立 3D2D 上下文（z 上移 → 不能与源文字
-- 同一上下文），按关键帧插值 z/alpha（文字与 FLOAT_BG_MATS 背景图像同色同淡出）；
-- 1.75 秒后清理。z 上升方向带视差对抗（2026-08-14 用户规格）：牌桌玩家视角沿
-- 「卡面文字锚点 → 相机」视线方向上升，观战者视角保持沿卡面法线（见下方 pos 分支）。
local function DrawFX()
    local now = CurTime()
    FlushPendingFX(now) -- 飘字序列：到期的待播飘字移入 FX 开始绘制（2026-08-14）
    for i = #Overlay.FX, 1, -1 do
        local fx = Overlay.FX[i]
        local ent = fx.ent
        if not IsValid(ent) then
            table.remove(Overlay.FX, i)
        else
            local t = (now - fx.start) / fx.dur
            if t >= 1 then
                table.remove(Overlay.FX, i)
            else
                local kv = EvalKeyframes(fx.frames, t)
                -- 与 DrawOverlay 同一套卡面轴线派生（3D2D +x 沿卡宽 forward、+y 沿卡长 right）
                local dx = ent:GetForward()
                local dy = ent:GetRight()
                local camAng = dx:AngleEx(dx:Cross(-dy))
                local entry = fx.entry
                local renderW = entry and entry.renderW or 209
                local worldW = entry and entry.worldW or 7.2
                local scale = worldW / renderW
                -- z 上移方向（视差对抗，2026-08-14 用户规格）：
                --   沿「卡面文字锚点 → 相机视线」方向上升——飘字 3D2D 原点始终在
                --   锚点→相机的射线上，屏幕投影固定在源文字原位放大；文字与背景图
                --   绘制居中 (0,0)（2026-08-16 修复：原实现从卡面中心 base 起步、
                --   方向基准却是带像素偏移的 anchor，两者不一致导致投影向屏幕下方
                --   漂移；且文字绘制在 (fx.x,fx.y)，放大时平面内偏移同步外扩，
                --   观感变为「向下移动 + 放大」而非「仅放大」。统一两视角同一方案：
                --   玩家视角用 BattleCamera 渲染相机，观战/牌桌外回退 EyePos()）
                local zv = kv.z * (fx.zUp or 1.0)
                local base = ent:GetPos() + ent:GetUp() * FLOAT_OFFSET
                -- 源文字世界点（= 常驻文字位置，与 DrawOverlay 同公式：
                -- 原点 + dx·px·scale − dy·py·scale）——飘字起点与视线方向基准
                local anchor = base + dx * (fx.x * scale) - dy * (fx.y * scale)
                -- 相机位置：BattleCamera 经 CalcView 接管渲染时须用其记录的
                -- ViewPos（渲染相机，牌桌上空）——EyePos() 是玩家肉身位置
                -- （进入牌桌后玩家停在槽位边缘，与渲染相机不一致），用它作
                -- 视差对抗会把飘字拉向错误方向；未接管（观战/牌桌外）回退 EyePos()
                local camPos = (KARDS.BattleCamera and KARDS.BattleCamera.ViewPos) or EyePos()
                local toCam = camPos - anchor
                local dir = toCam:LengthSqr() > 1e-8 and toCam:GetNormalized() or ent:GetUp()
                local pos = anchor + dir * zv
                cam.Start3D2D(pos, camAng, scale)
                -- 飘字背景图像（2026-08-14，3D2D 方案）：materials/kards/ui/ 预设三张
                -- 背景图（攻击/防御/行动花费）按槽位选取，以文字为中心绘制、颜色与飘字
                -- 文字同色（surface.SetDrawColor 用 fx.color，alpha 随淡出同步）；统一朝向
                -- 本方——3D2D 上下文随卡牌朝向（卡面朝本方），不额外处理 yaw。
                -- 尺寸用 FLOAT_BG_MATS 预设原始像素（w/h）保持原宽高比（2026-08-14 用户规格）。
                -- 2026-08-16：3D2D 原点已在源文字世界点，文字/背景图均绘制居中 (0,0)
                -- → 投影固定在源文字原位，仅随 z 上移视差放大、无屏幕位移。
                local bg = FLOAT_BG_MATS[fx.slot]
                if bg then
                    local tw, th = bg.w, bg.h
                    surface.SetMaterial(bg.mat)
                    surface.SetDrawColor(fx.color.r, fx.color.g, fx.color.b, kv.a)
                    surface.DrawTexturedRect(-tw / 2, -th / 2, tw, th)
                end
                draw.SimpleText(fx.text, fx.font, 0, 0,
                    Color(fx.color.r, fx.color.g, fx.color.b, kv.a),
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                cam.End3D2D()
            end
        end
    end
end

--[[
    返回某卡牌的卡牌花费（数据源与绘制一致，供颜色判定等逻辑读取）：
      - 战场实体模式：卡面视图 KARDS.CardView.Read(ent).cost
      - 本地外观表（手牌/编辑器 3D2D）：appearance.cost
      - 卡牌对象（CardInterface mock）：GetCost()
]]
function Overlay:GetCardCost(ent)
    local entry = self.Ents[ent]
    if not entry then return nil end
    if entry.mode == "entity" then
        if not IsValid(ent) then return nil end
        return KARDS.CardView.Read(ent).cost
    end
    local d = entry.data
    if d and d.GetCost then return d:GetCost() or 0 end
    return d and d.cost or 0
end

-- 渲染钩子：PostDrawOpaqueRenderables 中绘制 3D2D 文字（卡面 opaque 已画完，文字悬浮可见）
hook.Add("PostDrawOpaqueRenderables", "kards_card_text_overlay", function()
    for ent, entry in pairs(Overlay.Ents) do
        if not IsValid(ent) then
            Overlay.Ents[ent] = nil -- 实体失效自动清理
        else
            DrawOverlay(entry, ent)
        end
    end
    DrawFX() -- 数值变动特效（t5）：独立 3D2D 上下文，z 上移 + 淡出
end)

-- 网络：战场卡牌实体生成广播（服务端 → 全部客户端，sh_battle_render.lua SpawnCard 发送）
net.Receive("KARDS_Battle_CardOverlayAdd", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) then return end
    Overlay:AddEntity(ent)
end)

-- 网络：外观编辑器 3D2D 文字卡生成结果（服务端回传实体，客户端绑定本地 app 数据）
-- 服务端生成实体后立即回传时，新实体可能尚未网络化（net.ReadEntity 返回 NULL），
-- 故改读实体索引（服务端 net.WriteEntity 写入的是实体索引），延迟重试绑定直到网络化完成
net.Receive("KARDS_Editor_SpawnCardResult", function()
    local entIdx = net.ReadInt(16)
    local pending = Overlay._PendingLocal
    Overlay._PendingLocal = nil
    if not pending then return end
    local function tryBind(attempt)
        local ent = Entity(entIdx)
        if IsValid(ent) then
            Overlay:AddLocal(ent, pending.data, pending.worldW, pending.worldH, pending.renderW, pending.renderH)
        elseif attempt < 20 then
            timer.Simple(0.1, function() tryBind(attempt + 1) end)
        end
    end
    tryBind(1)
end)

-- 供 cl_canvas_editor.lua 预存待绑定数据（SpawnTestEntity 发送 net 前设置）
Overlay._PendingLocal = nil

--[[
    属性变化 3D2D 飘字接收（2026-08-14）：服务端各属性变动来源点（伤害 / 节点设增减 /
    词条 / 修复 / 老兵 / HQ 防御等，见 sh_battle_combat.lua NotifyStatFX）→ 牌桌实体
    BroadcastStatChangeFX（目标实体 + 槽位 + 变动值 + mod + 来源类型，见 table_battledeck.lua）
    → 此处解码后在对应槽位原位触发飘字（PlayStatChangeFX：3D2D 文字 + 背景图像）。
    目标须在场（服务端已按 fieldCardEnts / hqEnt 映射过滤，手牌无战场实体 → 不广播
    不飘字，用户规格「手牌的属性变动不使用飘字」）。

    颜色规则（用户规格 2026-08-14；数值口径 2026-09-26 修正）：
      攻击/防御：增加 → 绿色，显示变动绝对值；减少（因受到伤害，kind=dmg）→ 红色，
                显示变动绝对值；设为或减少（属性与伤害节点 trigger，kind=node）→ 白色，
                显示设置后的新值（白色飘字的意义为「设为」，见 PlayStatFXWhite）
      行动花费：增加 → 红色；减少 → 绿色；显示变动值（减少带 "-" 负号）

    随机顺序（2026-10-27 用户规格）：同一刻（同一帧内批量到达）的多条飘字先按
    到达顺序收集，帧末按对象分组并随机对象顺序后入播放队列。随机排序只计入对象：
    同一对象的飘字连续播出，且组内固定「攻击力飘字先于防御力飘字」（其余槽位保持
    到达顺序），不再固定按服务端节点/对象顺序。
]]
-- 同一刻飘字收集批（见上方「随机顺序」）：本帧收到的条目在此暂存，帧末按对象分组洗牌入队
Overlay._fxBatch = Overlay._fxBatch or {}
Overlay._fxBatchScheduled = Overlay._fxBatchScheduled or false

local function FlushFxBatch()
    Overlay._fxBatchScheduled = false
    local batch = Overlay._fxBatch
    Overlay._fxBatch = {}
    -- 按对象分组：groups[ent] = 该对象本刻的飘字列表；keys 保留对象首次出现顺序
    local groups, keys = {}, {}
    for _, item in ipairs(batch) do
        local g = groups[item.ent]
        if not g then
            g = {}
            groups[item.ent] = g
            keys[#keys + 1] = item.ent
        end
        g[#g + 1] = item
    end
    -- 组内固定顺序：攻击力飘字先于防御力飘字，其余槽位保持到达顺序（只重排
    -- attack/defense 占用的位置，不影响行动花费等其他槽位的相对次序）
    for _, ent in ipairs(keys) do
        local g = groups[ent]
        local slots = {}
        for i, item in ipairs(g) do
            if item.slot == "attack" or item.slot == "defense" then
                slots[#slots + 1] = i
            end
        end
        if #slots > 1 then
            local attacks, defenses = {}, {}
            for _, i in ipairs(slots) do
                if g[i].slot == "attack" then attacks[#attacks + 1] = g[i]
                else defenses[#defenses + 1] = g[i] end
            end
            local k = 0
            for _, item in ipairs(attacks) do k = k + 1; g[slots[k]] = item end
            for _, item in ipairs(defenses) do k = k + 1; g[slots[k]] = item end
        end
    end
    -- Fisher-Yates 洗牌：只洗对象顺序
    for i = #keys, 2, -1 do
        local j = math.random(i)
        keys[i], keys[j] = keys[j], keys[i]
    end
    for _, ent in ipairs(keys) do
        for _, item in ipairs(groups[ent]) do
            Overlay:PlayStatChangeFX(item.ent, item.slot, item.text, item.font, item.x, item.y, item.color)
        end
    end
end

net.Receive("KardsStatChangeFX", function()
    local ent = net.ReadEntity()
    local slotIdx = net.ReadUInt(4)
    local delta = net.ReadInt(16)
    local modIdx = net.ReadUInt(4)
    local kindIdx = net.ReadUInt(4)
    local newValue = net.ReadInt(16) -- 改动后的当前值（白字显示用，2026-09-26）
    if not IsValid(ent) then return end
    local entry = Overlay.Ents[ent]
    if not entry then return end -- 未登记 3D2D 叠加的实体（如手牌/未网络化）不飘字
    local slot = (slotIdx == 1) and "attack" or (slotIdx == 2) and "defense" or "actionCost"
    local mod = (modIdx == 1) and "increase" or (modIdx == 2) and "decrease" or "set"
    local kind = (kindIdx == 1) and "dmg" or (kindIdx == 2) and "node" or "other"
    -- 颜色（用户规格）
    local color
    if slot == "actionCost" then
        color = delta > 0 and STAT_COLOR_DOWN or STAT_COLOR_UP -- 行动花费 增→红 / 减→绿
    elseif mod == "increase" then
        color = STAT_COLOR_UP    -- 攻防增加 → 绿
    elseif kind == "dmg" then
        color = STAT_COLOR_DOWN  -- 攻防减少（因受到伤害）→ 红
    else
        color = STAT_COLOR_WHITE -- 攻防设为或减少（节点）→ 白
    end
    -- 数值三分支（2026-09-26 用户口径）：白字语义为「设为」→ 显示设置后的新值；
    -- 行动花费显示变动值（减少时 tostring 自带负号）；攻防绿增 / 红伤显示变动绝对值
    local text
    if slot == "actionCost" then
        text = tostring(delta)
    elseif color == STAT_COLOR_WHITE then
        text = tostring(newValue)
    else
        text = tostring(math.abs(delta))
    end
    local x, y, ok = SlotPixelPos(entry, ent, slot)
    if not ok then return end -- 总部短卡无攻击/行动花费槽位 → 跳过
    -- 先入本帧收集批，帧末按对象分组、随机对象顺序后入播放队列（同一刻多条飘字
    -- 随机顺序，见上方「随机顺序」）
    local batch = Overlay._fxBatch
    batch[#batch + 1] = {
        ent = ent, slot = slot, text = text, font = PickNumberFont(text),
        x = x, y = y, color = color,
    }
    if not Overlay._fxBatchScheduled then
        Overlay._fxBatchScheduled = true
        timer.Simple(0, FlushFxBatch)
    end
end)
