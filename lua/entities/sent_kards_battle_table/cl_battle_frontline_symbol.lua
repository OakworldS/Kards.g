--[[
    Kards 战斗牌桌客户端模块：前线符号实体（cl_battle_frontline_symbol.lua）

    职责：将已导入的 4 个前线符号模型（frontline_nottaken_pi/pii、frontline_takend_pi/pii，
    PMXStaticImporter 模型，data/pmx_static_importer/models/ 下）渲染到牌桌前线区域，
    表达前线占领状态（客户端本地实体，服务端只广播归属数据，见 cl_perspective.lua 头注释）：

      - 模型选择：pi 实为 P2 侧样式、pii 实为 P1 侧样式（2026-08-11 实测对调：文件名
        末尾玩家名与侧向相反）；已占领（ownerSlot≠0）→ takend 且按归属方选侧（P1 占领
        → pii / P2 占领 → pi，敌方占领时显示对方的前线占领样式）；未占领 → nottaken
        且按本地视角选侧（P2 → pi / P1/观战 → pii）。
      - 位置：未占领位于前线行中间（牌桌相对 y=0）；已占领向「对边玩家」的支援阵线
        与前线之间间隔中点移动（P1 占领 → y=-6.40 靠 P2 侧；P2 占领 → y=+6.40 靠 P1 侧）。
      - 纹理：纯色 PNG（未占领黑 / 已占领深红 139,0,0），首次使用时写入并改写 manifest
        image_path + ClearCache（纹理链路顺序敏感，见 cl_init.lua 头注释；子网格名为
        平面/平面.063 非 front/back，用 KARDS.CardManifest.RewriteAllImagePaths 全子网格改写）。
      - 显示时机：除组卡模式（牌桌 Kards_Mode == "deck"）始终显示；状态切换时位置用
        KARDS.AnimPlayer 线性滑动（2026-10-27：时长随移动 / 撤退位移动画一并 ×1.5，
        与单位位移的基准时长 0.225s 一致），动画组名 "frontlineMove"
        与单位移动至前线同组（2026-08-12：单位与前线标识同时移动，见 cl_init.lua
        KardsFieldLayout slot=0 变体）。

    挂载：cl_init.lua include 本文件（cl_battle_ops.lua 之后，见加载链注释）。约定：
    常驻钩子挂 KARDS 命名空间；跨段落共享状态读写走 KARDS.BattleState。
]]

if not CLIENT then return end

KARDS = KARDS or {}
local BS = KARDS.BattleState

-- 4 个前线符号模型（后缀 pi=P1 视角 / pii=P2 视角；前缀 nottaken=未占领 / takend=已占领），
-- 子网格均为单网格（名 平面 / 平面.063），统一纯色纹理：未占领黑 / 已占领深红。
-- 模型 ID 提为常量（2026-10-16 性能优化）：选取时直接返回，不再每帧拼接字符串
local MODEL_NOTTAKEN_PI  = "frontline_nottaken_pi"
local MODEL_NOTTAKEN_PII = "frontline_nottaken_pii"
local MODEL_TAKEND_PI    = "frontline_takend_pi"
local MODEL_TAKEND_PII   = "frontline_takend_pii"
local SOLID_COLOR = {
    [MODEL_NOTTAKEN_PI]  = { 0, 0, 0 },
    [MODEL_NOTTAKEN_PII] = { 0, 0, 0 },
    [MODEL_TAKEND_PI]    = { 139, 0, 0 },
    [MODEL_TAKEND_PII]   = { 139, 0, 0 },
}

local FRONTLINE_SCALE = 0.0745 * 1.5 -- 前线行全宽 32.8 / 模型 bounds 宽 440 ×1.5（2026-08-11 放大）
local GAP_OFFSET_Y = 6.40        -- 行间距 12.80 的一半（支援阵线与前线间隔中点）
local FL_SYMBOL_MOVE_DUR = 0.15 * 1.5 -- 占领状态切换滑动时长（2026-10-27：随移动 / 撤退位移动画一并延长 1.5 倍，与单位位移的基准时长一致）
local SYMBOL_Z_OFFSET = 0.02     -- 略低于卡面 CardZ，避免与前线单位 z-fighting（卡覆盖其上）
local FL_SYMBOL_ANG = Angle(0, 0, 0) -- 符号平放朝向（常量，免每帧构造 Angle）

-- 符号实体当前状态（模块级 local）：
local symbolEnt = nil    -- 前线符号客户端实体
local curModelID = nil   -- 已设置的模型 ID（实体移除分支必须一并置 nil，见 RemoveSymbol）
local curRel = nil       -- 当前目标相对坐标（AnimPlayer 动画起始判断；nil = 实体刚创建）
local prepared = false   -- 纹理预置完成标志（本会话一次性）

-- 符号 z（卡面下方）；Board2D 缺失时兜底旧常量
local function SymbolZ()
    local bd = KARDS.Animation and KARDS.Animation.Board2D
    return ((bd and bd.CardZ) or 18.43) - SYMBOL_Z_OFFSET
end

-- 写纯色 PNG（8×8 render target → file.Write，DATA 模式 → garrysmod/data/<path>；
-- alpha=false 规避透明 bug，与 cl_card_preview.lua SaveRTToFile 同法）
local function WriteSolidPNG(path, r, g, b)
    local rt = GetRenderTarget("kards_frontline_symbol_solid", 8, 8)
    if not rt then return false end
    render.PushRenderTarget(rt)
    render.Clear(r, g, b, 255, true, true)
    local data = render.Capture({
        format = "png", x = 0, y = 0, w = 8, h = 8, quality = 100, alpha = false,
    })
    render.PopRenderTarget()
    if not data then return false end
    return file.Write(path, data)
end

-- 预置 4 个模型的纯色纹理：PNG 落盘 → manifest 全子网格改写 → ClearCache 销毁旧
-- renderable（顺序敏感，见 cl_init.lua 头注释「纹理加载链路」；PNG 必须先于实体首次
-- Draw）。本会话一次性（prepared 标志）；用户重新导入模型覆盖 manifest 后重启会话重做。
local function EnsureTextures()
    if prepared then return true end
    if not (KARDS.CardManifest and KARDS.CardManifest.RewriteAllImagePaths) then return false end
    local okAll = true
    for modelID, rgb in pairs(SOLID_COLOR) do
        local dir = "pmx_static_importer/" .. modelID
        file.CreateDir(dir)
        local ok = WriteSolidPNG(dir .. "/front.png", rgb[1], rgb[2], rgb[3])
        if not ok then
            okAll = false
        else
            okAll = KARDS.CardManifest.RewriteAllImagePaths(modelID, "data/" .. dir .. "/front.png") and okAll
        end
        if PMXStaticImporter and PMXStaticImporter.ClearCache then
            PMXStaticImporter.ClearCache(modelID)
        end
    end
    prepared = okAll
    return okAll
end

-- 模型选择：pi 实为 P2 侧样式、pii 实为 P1 侧样式（2026-08-11 实测对调：文件名末尾
-- 玩家名与侧向相反，按侧向交换）。已占领（ownerSlot≠0）→ takend 且按归属方选侧
-- （P1 占领 → pii / P2 占领 → pi：敌方占领时显示对方的前线占领样式，2026-08-12
-- 反馈）；未占领 → nottaken 且按本地视角选侧（P2 视角 → pi / P1/观战 → pii）
local function PickModelID()
    local view = KARDS.Perspective and KARDS.Perspective.LocalView
    local owner = BS.frontlineOwnerSlot or 0
    if owner ~= 0 then
        return (owner == 1) and MODEL_TAKEND_PII or MODEL_TAKEND_PI
    end
    return (view == 2) and MODEL_NOTTAKEN_PI or MODEL_NOTTAKEN_PII
end

-- 目标相对坐标（牌桌局部）：未占领居中；P1 占领向对边（P2 侧 -y）/ P2 占领向 P1 侧 +y。
-- 三种坐标预置为共享向量（2026-10-16 性能优化），每帧只就地更新 z（Board2D 可能尚未就绪）。
-- 共享是安全的：调用方只把返回值与上一帧返回值比较或读取坐标，从不改写 xy
local REL_CENTER = Vector(0, 0, 0)
local REL_P1_OWNED = Vector(0, -GAP_OFFSET_Y, 0)
local REL_P2_OWNED = Vector(0, GAP_OFFSET_Y, 0)
local function PickRelPos()
    local owner = BS.frontlineOwnerSlot or 0
    local rel = (owner == 1) and REL_P1_OWNED
        or (owner == 2) and REL_P2_OWNED
        or REL_CENTER
    rel.z = SymbolZ()
    return rel
end

-- 创建前线符号实体（客户端本地实体；失败返回 nil）。位置由 Think 每帧跟随牌桌落位
local function CreateSymbol()
    local e = ents.CreateClientside("sent_pmx_static_imported")
    if not IsValid(e) then return nil end
    e:Spawn()
    -- 客户端实体 SetupDataTables 的 SERVER 分支不执行（PMXColor 缺省 Vector(0,0,0)），
    -- 需显式置白，与前置模组服务端默认一致，避免渲染全黑（见 cl_init.lua 头注释）
    e:SetPMXScale(FRONTLINE_SCALE)
    e:SetPMXColor(Vector(1, 1, 1))
    -- 无碰撞无物理（同战场单位实体）
    e:SetSolid(SOLID_NONE)
    local phys = e:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    return e
end

-- 移除符号实体（退出牌桌 / 组卡模式 / 无牌桌实体）；curModelID 一并复位，
-- 否则下一场对局新实体不会触发首次 SetPMXModelID（新实体缺省空 modelID 渲染空白）
local function RemoveSymbol()
    if symbolEnt and IsValid(symbolEnt) then
        symbolEnt:Remove()
    end
    symbolEnt = nil
    curModelID = nil
    curRel = nil
end

-- 牌桌实体来源：进入牌桌时用 inTable.ent；未进入（观战/组卡旁观）退化为首个有效牌桌实体
local function FindTableEnt()
    if BS.inTable and IsValid(BS.inTable.ent) then
        return BS.inTable.ent
    end
    for _, e in ipairs(ents.FindByClass("sent_kards_battle_table")) do
        if IsValid(e) then return e end
    end
    return nil
end

hook.Add("Think", "KardsFrontlineSymbolThink", function()
    local tableEnt = FindTableEnt()
    if not tableEnt then
        RemoveSymbol()
        return
    end
    -- 组卡模式（Kards_Mode == "deck"）隐藏符号；切回对战模式自动恢复（curModelID 复位）
    if tableEnt:GetNWString("Kards_Mode", "battle") == "deck" then
        RemoveSymbol()
        return
    end
    -- 纹理预置必须先于实体首次 Draw（文件 → manifest → ClearCache，见 cl_init.lua 头注释）
    EnsureTextures()
    if not symbolEnt or not IsValid(symbolEnt) then
        symbolEnt = CreateSymbol()
        if not symbolEnt then return end
    end
    -- 模型选择（视角 × 占领状态；实体 Think 按 PMXModelID 自动更新渲染包围盒）
    local modelID = PickModelID()
    if modelID ~= curModelID then
        if symbolEnt.SetPMXModelID then
            symbolEnt:SetPMXModelID(modelID)
        end
        curModelID = modelID
    end
    -- 位置：状态切换时 AnimPlayer 线性滑动，否则每帧跟随牌桌落位
    local targetRel = PickRelPos()
    if KARDS.AnimPlayer and KARDS.AnimPlayer:Get(symbolEnt) then
        -- 滑动动画中：AnimPlayer 驱动，本帧不覆盖
    elseif curRel and curRel:DistToSqr(targetRel) > 0.001 then
        -- 目标相对坐标变化（占领状态切换）：从当前位置线性滑动到新目标。组名
        -- "frontlineMove"（阶段五 P7 组名英文化，原"前线变动"）与单位移动至前线
        -- 动画一致（cl_init.lua KardsFieldLayout slot=0 变体）：同组并发，
        -- 单位与前线标识同时移动
        KARDS.AnimPlayer:Play(symbolEnt, {
            { t = 0, pos = symbolEnt:GetPos() },
            { t = FL_SYMBOL_MOVE_DUR, pos = tableEnt:LocalToWorld(targetRel), easing = "linear" },
        }, { group = "frontlineMove" })
        curRel = targetRel
    else
        symbolEnt:SetPos(tableEnt:LocalToWorld(targetRel))
        symbolEnt:SetAngles(tableEnt:LocalToWorldAngles(FL_SYMBOL_ANG))
        curRel = curRel or targetRel
    end
end)
