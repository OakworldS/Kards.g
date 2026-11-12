--[[
    Kards 战斗牌桌客户端模块：单位词条图标（cl_battle_keyword_icons.lua，2026-08-13）

    服务端把单位/总部的词条 + 动态状态编码为 "id[:数值][,id[:数值]...]" 串
    （table_battledeck.lua BuildUnitKeywordsStr / SyncUnitNW 的 Kards_UnitKeywords NW），
    本模块在 3D2D 上下文内（cl_card_text_overlay.lua DrawOverlay 的 cam.Start3D2D 块，
    单位小模型 / 总部短卡分支）把词条图标绘制在卡面右上角外侧、垂直单列：
      - 只绘制 materials/kards/effects/3d2d/ 目录内的图标（白名单外或文件不存在 → 跳过）
      - 统一圆角矩形为底（灰色，不随词条变色），长度随已展示图标数逐格增长；
        词条颜色作用于图标贴图本身：亡计红 / 单位防御 0 亡计浅红 / 奋战·冲击黄
        （奋战第二次攻击后恢复白色原样）/ 烟幕·老兵灰 / 倒计时橙白 / 其余白色原样
      - 5 个图标总列长 ≈ 一张小模型卡面可视长（245 ≈ 247.6px）
      - 重甲 / 倒计时中央绘制数值数字，数字颜色与矩形相同（灰色，镂空效果）
      - 倒计时数值变化时图标在橙白间高频闪烁 2 次；稳定态：值 1 → 橙，否则白
      - 冲击已使用（shock:1）后高频闪烁 2 次再消失（冲击一次性词条）
      - 词条 > 5 个时绘制前 4 个图标 + 第 5 格省略号，后续不绘制
      - 部署 / 加入动画完成后首次绘制：矩形立即出现 → 第 1 个词条图标高频闪烁 3 次
        → 矩形增一格 → 等 0.3s → 下一个图标闪烁，依此类推；每个图标出现瞬间随机播放
        sound/kards/effect_icon1/2/3.ogg（「展示效果图标 x」的英文名副本，
        BASS 不支持中文文件名，见 cl_init.lua KARDS.PlayKardsSound）
    仅小模型单位（_unitMode）或总部短卡（hqShort）绘制词条图标。
]]
if not CLIENT then return end

KARDS = KARDS or {}
KARDS.KeywordIcons = KARDS.KeywordIcons or {}
local Icons = KARDS.KeywordIcons

-- 词条 id 白名单（2026-08-13：图标文件已按词条参数名命名——3d2d 目录下
-- deathrattle.png / ambush.png … / active_effect.png / passive_effect.png，
-- 见 materials/kards/effects/3d2d/；与 table_battledeck.lua KeywordIconFile 一致）
local IconIds = {
    deathrattle = true, ambush = true, countdown = true, immune = true,
    shock = true, mobilize = true, frenzy = true, guard = true,
    smoke = true, veteran = true, guarded = true, armor = true,
    pincer = true, stealth = true,
    suppress = true, -- 动态状态（被压制）
    control = true, -- 动态状态（被控制）
    neutralized = true, -- 动态状态（被抑制）
}

-- 图标/布局常量（3D2D 像素单位，卡面 renderW×renderH 坐标系，右上角外侧竖排）
-- 注：3D2D 等比缩放 scale = worldW/renderW = 7.2/209，故卡面世界高 8.528 在像素坐标
-- 中可视长为 8.528/scale ≈ 247.6px（≠ renderH=290）——总列长须以卡面可视长为准（2026-08-13）
local ICON_SIZE = 37                -- 图标贴图边长
local RECT_PAD = 4                  -- 矩形内边距（矩形边长 = 图标 + 2×内边距）
local RECT = ICON_SIZE + RECT_PAD * 2 -- 矩形边长 45
local GAP = 5                       -- 相邻图标间距
                                    -- （5 图标总列长 = 5×45+4×5 = 245 ≈ 卡面可视长 247.6）
local PAD_X = 3                     -- 整体矩形横向外边距（矩形宽 = RECT + 2×PAD_X）
local X_OFFSET = RECT / 2 + PAD_X + 2 -- 右缘外侧偏移（须 > 矩形半宽使整体落在卡面右缘外）
local TOP_SHIFT = 125                -- 矩形列整体上移量
local MAX_ICONS = 5                 -- 最多绘制图标数；超出后第 6 位画省略号
local DEPLOY_WAIT = 0.3             -- 出场动画：图标闪烁完成后到下一个图标出现的等待（秒）
local FLASHES_DEPLOY = 3            -- 出场每个图标闪烁次数
local FLASHES_COUNTDOWN = 2         -- 倒计时变更闪烁次数
local FLASHES_SHOCK = 2             -- 冲击已用闪烁次数
local FLASH_PERIOD = 0.1            -- 高频闪烁周期（秒；半周期 on / 半周期 off）
local DEPLOY_PERIOD = FLASHES_DEPLOY * FLASH_PERIOD + DEPLOY_WAIT -- 每图标出场周期 0.6s

-- 矩形底色：统一灰色（2026-08-13：颜色要求作用于图标本身，矩形不随词条变色）
local RECT_BG = Color(55, 55, 55, 235)
local ELLIPSIS_COLOR = RECT_BG -- 省略号文字与矩形同色

-- 图标着色（词条颜色作用于图标贴图：白色符号贴图被 surface.SetDrawColor 染色）
local ICON_WHITE   = Color(255, 255, 255, 255) -- 默认（原样）
local ICON_RED     = Color(225, 75, 75, 255)   -- 亡计红
local ICON_LIGHT_RED = Color(255, 160, 160, 255) -- 亡计浅红（单位防御 0）
local ICON_YELLOW  = Color(240, 200, 70, 255)  -- 奋战/冲击黄
local ICON_GRAY    = Color(165, 165, 165, 255) -- 烟幕/老兵灰
local ICON_ORANGE  = Color(250, 170, 50, 255)  -- 倒计时橙
local ICON_WHITE_C = Color(255, 255, 255, 255) -- 倒计时白

-- 材质缓存：id → Material | false（文件不存在/加载失败）
-- 注意：Material 第二参数 "noclamp smooth" 必须带——项目先例（flags / textUnderground）
-- 均带此参数；缺失时 PNG 以默认材质类型创建，surface.DrawTexturedRect 画不出贴图
--（只显示矩形底，2026-08-13 实测）
local MatCache = {}
local function IconMat(id)
    if not IconIds[id] then return nil end
    if MatCache[id] == nil then
        local path = "materials/kards/effects/3d2d/" .. id .. ".png"
        MatCache[id] = file.Exists(path, "GAME") and Material(path, "noclamp smooth") or false
    end
    return MatCache[id] or nil
end

-- 解析词条串 "id[:数值][,id[:数值]...]" → { { id = string, val = number|nil }, ... }
local function ParseKeywords(str)
    if not str or str == "" then return {} end
    local list = {}
    for seg in string.gmatch(str, "[^,]+") do
        local id, val = seg:match("^(.-):(%d+)$")
        if id then
            list[#list + 1] = { id = id, val = tonumber(val) }
        else
            list[#list + 1] = { id = seg, val = nil }
        end
    end
    return list
end

-- 高频闪烁透明度：从 start 起 flashes 个 on/off 周期（半周期可见），之后稳定 255
local function FlashAlpha(start, now, flashes)
    local dt = now - start
    if dt <= 0 then return 0 end
    if dt >= flashes * FLASH_PERIOD then return 255 end
    local k = dt % FLASH_PERIOD
    return (k < FLASH_PERIOD / 2) and 255 or 0
end

-- 词条图标颜色与透明度系数（返回 nil 表示该词条当前不绘制——冲击已用且闪烁结束）。
-- 颜色作用于图标贴图本身，矩形统一灰色（2026-08-13）
local function IconColor(item, defense, st, now)
    local id = item.id
    if id == "deathrattle" then
        return (defense == 0) and ICON_LIGHT_RED or ICON_RED, 255
    elseif id == "frenzy" then
        -- 奋战：第二次攻击后（服务端编码 2 - 已攻击次数 = 0）恢复原色（白色）
        return ((item.val or 0) > 0) and ICON_YELLOW or ICON_WHITE, 255
    elseif id == "shock" then
        if (item.val or 0) == 0 then
            return ICON_YELLOW, 255 -- 未攻击：黄
        end
        -- 已使用：攻击后高频闪烁 2 次 → 移除（冲击一次性，闪烁结束不绘制）
        local sa = FlashAlpha(st.shockStart or now, now, FLASHES_SHOCK)
        if sa <= 0 then return nil end
        return ICON_WHITE, sa
    elseif id == "smoke" or id == "veteran" then
        return ICON_GRAY, 255
    elseif id == "control" then
        -- 控制（动态状态）：控制动画到达中心时（TriggerControlFlash 置 ctlFlashStart）
        -- 高频闪烁 3 次，之后稳定白色显示（2026-08-16 用户规格「播放控制图标动画」）
        if st.ctlFlashStart then
            local ca = FlashAlpha(st.ctlFlashStart, now, FLASHES_DEPLOY)
            if ca < 255 then return ICON_WHITE, ca end
            st.ctlFlashStart = nil -- 闪烁结束，清除（图标稳定显示）
        end
        return ICON_WHITE, 255
    elseif id == "countdown" then
        -- 数值变更时图标在橙白间高频闪烁 2 次；稳定态：值 1 → 橙，否则白
        local fs = st.cdFlashStart
        if fs and (now - fs) < FLASHES_COUNTDOWN * FLASH_PERIOD then
            local k = math.floor((now - fs) / (FLASH_PERIOD / 2)) % 2
            return (k == 0) and ICON_ORANGE or ICON_WHITE_C, 255
        end
        return ((item.val or 0) == 1) and ICON_ORANGE or ICON_WHITE_C, 255
    end
    return ICON_WHITE, 255
end

-- 统一圆角矩形底（灰色；长度 = 已展示图标数 × 格高，随出场动画逐格增长；
-- 圆角半径 12 增强软边强度，2026-08-13）
local function DrawBackRect(cx, topY, height)
    local rectW = RECT + PAD_X * 2
    draw.RoundedBox(12, cx - rectW / 2, topY, rectW, height, RECT_BG)
end

-- 词条图标贴图着色（居中；alpha 为 0..255 整体透明度）
local function DrawIcon(id, cx, cy, iconColor, alpha)
    local mat = IconMat(id)
    if mat then
        surface.SetMaterial(mat)
        surface.SetDrawColor(iconColor.r, iconColor.g, iconColor.b, alpha)
        surface.DrawTexturedRect(cx - ICON_SIZE / 2, cy - ICON_SIZE / 2, ICON_SIZE, ICON_SIZE)
    end
end

-- 重甲 / 倒计时中央数值数字（颜色与矩形相同（统一灰）→ 在着色图标上呈镂空底色效果）
local function DrawIconNumber(item, cx, cy, alpha)
    if item.id ~= "armor" and item.id ~= "countdown" then return end
    local a = math.floor(RECT_BG.a * alpha / 255)
    draw.SimpleText(tostring(item.val or 0), "SourceHan_Heavy_24", cx, cy,
        Color(RECT_BG.r, RECT_BG.g, RECT_BG.b, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- 随机播放「展示效果图标 x」英文名副本（sound/kards/effect_icon1/2/3.ogg）
local function PlayIconSound()
    if KARDS.PlayKardsSound then
        KARDS.PlayKardsSound("effect_icon" .. math.random(1, 3))
    end
end

-- 绘制状态（按实体索引；出场 / 倒计时 / 冲击动画计时；weak keys 防泄漏）
local States = setmetatable({}, { __mode = "k" })

--[[
    在 3D2D 上下文内绘制单位/总部词条图标（由 cl_card_text_overlay.lua DrawOverlay
    的单位小模型 / 总部短卡分支调用，处于同一 cam.Start3D2D 块内）。

    @param ent      Entity 卡牌实体（经 KARDS.CardView.Read 取 unitKeywords / defense）
    @param renderW  number 卡面渲染像素宽（单位/总部短卡 209）
    @param renderH  number 卡面渲染像素高（单位/总部短卡 290）
]]
function Icons:Draw(ent, renderW, renderH)
    if not IsValid(ent) then return end
    local raw = KARDS.CardView.Read(ent).unitKeywords
    local list = ParseKeywords(raw)
    if #list == 0 then
        States[ent] = nil -- 词条清空：清理动画状态
        return
    end
    local now = CurTime()
    -- 揭示动画期间：词条图标与矩形消失；动画结束后清除记录，词条区重新以
    -- 正常入场动画出现（隐蔽揭示，2026-08-13 用户规格；见 cl_battle_stealth.lua）
    if KARDS.Stealth and KARDS.Stealth.GetRevealEnd then
        local revealEnd = KARDS.Stealth.GetRevealEnd(ent)
        if revealEnd then
            if now < revealEnd then
                States[ent] = nil
                return
            end
            KARDS.Stealth.ClearRevealEnd(ent)
        end
    end
    local st = States[ent]
    -- 首次可绘制（部署 / 加入 / 隐蔽揭示后）→ 启动出场动画；此后词条串变化（倒计时
    -- -1 / 压制出现 / 冲击 0→1 等）只走下方变更检测，不重播出场动画
    if not st then
        st = {
            str = raw,
            deployStart = now,
            sounded = {},     -- 出场音效已播标记（按词条序号）
            lastCd = nil,     -- 上次倒计时值（变更检测）
            cdFlashStart = nil,
            lastShock = nil,  -- 上次冲击已用状态（0→1 检测）
            shockStart = nil,
        }
        States[ent] = st
    else
        st.str = raw
    end

    -- 倒计时数值变更检测 → 触发橙白闪烁
    for _, it in ipairs(list) do
        if it.id == "countdown" then
            if st.lastCd ~= it.val then
                st.cdFlashStart = now
                st.lastCd = it.val
            end
            break
        end
    end
    -- 冲击已使用（shock:1，服务端编码）→ 触发闪烁后消失
    for _, it in ipairs(list) do
        if it.id == "shock" and it.val == 1 then
            if not st.lastShock then
                st.shockStart = now
                st.lastShock = true
            end
            break
        end
    end

    local defense = KARDS.CardView.Read(ent).defense
    -- 词条 > 5 个时第 5 格画省略号（只绘制前 4 个图标）
    local showEllipsis = #list > MAX_ICONS
    local visible = showEllipsis and (MAX_ICONS - 1) or #list -- 实际绘制图标数
    local rectSlots = showEllipsis and MAX_ICONS or visible -- 矩形总格数（含省略号格）
    -- 右上角外侧竖排：矩形列整体上移（第 1 格中心 y = RECT/2 - TOP_SHIFT）
    local startY = RECT / 2 - TOP_SHIFT
    local cx = renderW / 2 + X_OFFSET
    -- 出场动画已展示格数：每图标周期 = 闪烁 3 次 + 等待 0.3s，闪烁结束即刻矩形增一格
    local nShown = 1
    if st.deployStart then
        local t = now - st.deployStart
        nShown = math.max(1, math.min(math.floor((t + DEPLOY_WAIT) / DEPLOY_PERIOD) + 1, rectSlots))
    end

    -- 统一圆角矩形：立即出现（不闪烁），长度随已展示格数增长
    DrawBackRect(cx, startY - RECT / 2, nShown * RECT + (nShown - 1) * GAP)

    for i = 1, visible do
        local item = list[i]
        local cy = startY + (i - 1) * (RECT + GAP)
        -- 出场：第 i 个图标出现时刻 = deployStart + (i-1)×DEPLOY_PERIOD，
        -- 出现即高频闪烁 3 次；未到出现时刻 alpha=0 不绘制
        local appear = st.deployStart + (i - 1) * DEPLOY_PERIOD
        local alpha = FlashAlpha(appear, now, FLASHES_DEPLOY)
        if not st.sounded[i] and now >= appear then
            st.sounded[i] = true
            PlayIconSound()
        end
        if alpha > 0 then
            local iconColor, aScale = IconColor(item, defense, st, now)
            if iconColor then
                alpha = math.min(alpha, aScale or 255)
                DrawIcon(item.id, cx, cy, iconColor, alpha)
                DrawIconNumber(item, cx, cy, alpha)
            end
        end
    end
    -- 省略号：词条 > 5 个时第 5 格画省略号（前 4 个图标；省略号格随出场动画节奏出现）
    if showEllipsis then
        local cy = startY + (MAX_ICONS - 1) * (RECT + GAP)
        local appear = st.deployStart + (MAX_ICONS - 1) * DEPLOY_PERIOD
        if now >= appear then
            draw.SimpleText("...", "SourceHan_Heavy_24", cx, cy, ELLIPSIS_COLOR,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    end
end

--[[
    触发控制图标闪烁（2026-08-16）：控制动画到达牌桌中心时调用
    （cl_init.lua net.Receive KardsControlAnim 的 onKeyframe "center"），
    使新出现的「控制」词条图标高频闪烁 3 次后稳定显示。
    图标绘制状态（States[ent]）不存在时静默（词条串尚未到达/无词条历史，此时
    图标首次出现走正常出场动画，见 Draw 的首次绘制分支）。

    @param ent Entity 单位卡牌实体
]]
function Icons:TriggerControlFlash(ent)
    local st = States[ent]
    if not st then return end
    st.ctlFlashStart = CurTime()
end
