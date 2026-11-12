--[[
=======================================================================================
卡牌离屏渲染模块 (Card Render)
=======================================================================================
从 cl_canvas_editor.lua 拆分出的卡牌离屏渲染模块，负责将卡牌外观离屏渲染为纹理文件、
创建动态材质、缓存与清理，以及在玩家面前生成卡牌模型实体。

包含功能：
  - RenderToRenderTarget / CreateDynamicMaterialFromRT / SaveRTToFile（渲染目标与材质工具）
  - RenderAndSaveCard（离屏渲染并保存卡牌图片，同时创建动态材质）
  - EnsureCardTextures（保存卡牌前确保外观纹理已渲染落盘）
  - GetCardMaterial（获取卡牌的动态材质）
  - CleanupOldMaterials（清理过期的动态材质）
  - SpawnTestEntity（在玩家面前生成实际卡牌模型实体）

状态数据：
  - DynamicMaterials（动态材质缓存表）

源文件：cl_canvas_editor.lua
  - 状态数据与功能函数：行 363~756
=======================================================================================
]]

-- 防御性命名空间初始化：确保即使本文件在 GMod 自动加载阶段先于
-- sh_card_editor_loader.lua 被加载，KARDS.CardEditor.Canvas 也已就绪
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}
KARDS.CardEditor.Canvas = KARDS.CardEditor.Canvas or {}

-- 多语言查表（2026-10-17）：文案 key → 当前语言文本
local T = KARDS.Lang.T

-- 动态材质缓存
KARDS.CardEditor.Canvas.DynamicMaterials = KARDS.CardEditor.Canvas.DynamicMaterials or {}

-- 真正的离屏渲染函数
local function RenderToRenderTarget(appearance, rtName, width, height, hideNumbers)
    -- 获取或创建渲染目标
    local rt = GetRenderTarget(rtName, width, height)
    if not rt then
        print("[KARDS] 无法创建渲染目标: " .. rtName)
        return nil
    end
    
    -- 推送到渲染目标
    render.PushRenderTarget(rt)
        -- 清除渲染目标：alpha 清为 255，并禁用后续绘制的 alpha 写入
        -- （OverrideAlphaWriteEnable true,false）→ RT 全图 alpha 恒为 255，
        -- 保存的卡面 PNG 完全不透明（修复卡面透明度为 0：组卡卡面材质
        -- 渲染为全透明而露出卡背图片）
        render.Clear(0, 0, 0, 255, true, true)
        render.OverrideAlphaWriteEnable(true, false)
        
        -- 使用 cam.Start2D 来正确设置渲染上下文
        cam.Start2D()
            -- 绘制卡牌到渲染目标，使用正确的坐标，无边缘偏移
            KARDS.CardEditor.Canvas.DrawCardPreviewRender(appearance, 0, 0, width, height, false, hideNumbers, true)
        cam.End2D()
        
        render.OverrideAlphaWriteEnable(false)
    render.PopRenderTarget()
    
    return rt
end

-- 从渲染目标创建动态材质
local function CreateDynamicMaterialFromRT(rt, materialName)
    -- 创建或获取材质
    local mat = CreateMaterial(materialName, "UnlitGeneric", {
        ["$basetexture"] = rt:GetName(),
        ["$translucent"] = 1,
        ["$vertexalpha"] = 1,
        ["$vertexcolor"] = 1,
        ["$nolod"] = 1
    })
    
    return mat
end

-- 保存渲染目标为PNG
local function SaveRTToFile(rt, filePath)
    local success = false
    -- 先推送到渲染目标
    render.PushRenderTarget(rt)
        -- 捕获渲染目标内容：alpha=false 保存不含 alpha 通道的 PNG（完全不透明）。
        -- GMod 已知问题：render.Capture 的 PNG 模式配合 alpha=true 时前景会被渲染为透明
        -- （SetWriteDepthToDestAlpha 干扰），导致卡面纹理 alpha=0、组卡时露出卡背；
        -- 去掉 alpha 通道后加载即不透明，杜绝该问题。
        local data = render.Capture({
            format = "png",
            x = 0,
            y = 0,
            w = rt:Width(),
            h = rt:Height(),
            quality = 100,
            alpha = false
        })
        
        if data then
            file.Write(filePath, data)
            success = true
        end
    render.PopRenderTarget()
    
    return success
end

-- 离屏渲染并保存卡牌图片，同时创建动态材质
function KARDS.CardEditor.Canvas.RenderAndSaveCard(appearance)
    -- 定义保存目录：总部与普通卡并列（kards/headquarters/ vs kards/cards/）
    local saveDir = (appearance.cardType == "headquarter") and "kards/headquarters/" or "kards/cards/"
    -- 确保目录存在
    if not file.Exists(saveDir, "DATA") then
        file.CreateDir(saveDir)
    end
    
    -- 卡牌名称作为文件名（替换非法字符）
    local cardName = appearance.name or "unnamed_card"
    -- 替换非法字符
    local safeName = string.gsub(cardName, "[^%w]", "_")
    safeName = string.gsub(safeName, "%s+", "_")
    safeName = string.gsub(safeName, "^_+", "")
    safeName = string.gsub(safeName, "_+$", "")
    if safeName == nil or safeName == "" then
        safeName = "unnamed_card"
    end
    
    -- 渲染尺寸：必须等于模板缩放尺寸，不能固定 300x400。
    -- DrawCardPreview 内部元素（名称居中/国旗右上/攻防/词条）以 previewW/previewH 为基准布局，
    -- 模板则以"模板像素 * 0.25 * scaleFactor"为基准；两者仅当 previewW ≈ 模板缩放宽度时对齐。
    -- 固定 300x400 时（模板缩放宽约 172）元素与模板整体错位约 64px（表现为渲染图元素偏移、预览图正常）。
    -- 故按模板缩放尺寸渲染：名称中心 = previewW/2 = 模板缩放宽/2 = 模板中心，完全对齐。
    local renderRefH = math.floor((KARDS.CardEditor.Canvas.TotalEditorH or 720) / 3)
    local templateKey = appearance.cardTemplate .. "_" .. appearance.cardType
    local renderTemplatePath = KARDS.CardEditor.Canvas.ImagePaths.template[templateKey]
    if not renderTemplatePath then
        renderTemplatePath = KARDS.CardEditor.Canvas.ImagePaths.template["custom"]
    end
    local renderWidth = 300
    local renderHeight = 400
    if renderTemplatePath and renderTemplatePath ~= "" then
        local renderTemplateMat = Material(renderTemplatePath)
        if renderTemplateMat and not renderTemplateMat:IsError() then
            local renderScaleFactor = KARDS.CardEditor.Canvas.ComputeCardScaleFactor(appearance, renderRefH)
            renderWidth = math.max(1, math.ceil(renderTemplateMat:Width() * 0.25 * renderScaleFactor))
            renderHeight = math.max(1, math.ceil(renderTemplateMat:Height() * 0.25 * renderScaleFactor))
        end
    end
    
    -- 保存图片
    local timestamp = os.time()
    local fullFileName = safeName .. "_full_" .. timestamp .. ".png"
    local templateFileName = safeName .. "_template_" .. timestamp .. ".png"
    local fullPath = saveDir .. fullFileName
    local noNumbersPath = saveDir .. templateFileName
    
    print("[KARDS] 开始真正的离屏渲染...")
    print("[KARDS] 渲染尺寸: " .. renderWidth .. "x" .. renderHeight)
    
    -- 1. 渲染完整卡牌
    local rtFullName = "Kards_Full_" .. safeName .. "_" .. timestamp
    local rtFull = RenderToRenderTarget(appearance, rtFullName, renderWidth, renderHeight, false)
    
    -- 2. 渲染模板卡牌
    local rtTemplateName = "Kards_Template_" .. safeName .. "_" .. timestamp
    local rtTemplate = RenderToRenderTarget(appearance, rtTemplateName, renderWidth, renderHeight, true)
    
    if rtFull and rtTemplate then
        -- 3. 保存到文件
        local success1 = SaveRTToFile(rtFull, fullPath)
        local success2 = SaveRTToFile(rtTemplate, noNumbersPath)
        
        -- 4. 创建动态材质
        local matFullName = "Kards_Mat_Full_" .. safeName .. "_" .. timestamp
        local matTemplateName = "Kards_Mat_Template_" .. safeName .. "_" .. timestamp
        
        local matFull = CreateDynamicMaterialFromRT(rtFull, matFullName)
        local matTemplate = CreateDynamicMaterialFromRT(rtTemplate, matTemplateName)
        
        -- 5. 缓存材质
        KARDS.CardEditor.Canvas.DynamicMaterials[safeName] = {
            full = matFull,
            template = matTemplate,
            timestamp = timestamp
        }
        
        print("[KARDS] 离屏渲染完成！")
        print("[KARDS] 完整卡牌已保存: garrysmod/data/" .. fullPath)
        print("[KARDS] 模板卡牌已保存: garrysmod/data/" .. noNumbersPath)
        print("[KARDS] 动态材质已创建: " .. matFullName .. ", " .. matTemplateName)
        
        -- 在聊天框显示
        if IsValid(LocalPlayer()) then
            LocalPlayer():ChatPrint(T("editor.render.card_rendered"))
            LocalPlayer():ChatPrint(T("editor.render.files_saved"))
            LocalPlayer():ChatPrint(T("editor.render.material_created"))
        end
        
        -- 记录本次渲染落盘路径（保存卡牌时"仅指向"复用，不再重复渲染；组卡/生成直接应用文件路径）。
        -- key = 渲染时卡标识（名称|类型|插图）：仅当当前卡与上次渲染的标识一致才复用路径，
        -- 避免同名卡（如总部"新卡牌"与普通卡"新卡牌"）渲染路径串用
        KARDS.CardEditor.Canvas.LastRenderedPaths = {
            full = fullPath,
            template = noNumbersPath,
            key = (appearance and (tostring(appearance.name) .. "|" .. tostring(appearance.cardType) .. "|" .. tostring(appearance.imagePath))) or "",
        }
        
        return {
            full = fullPath,
            template = noNumbersPath,
            fullMaterial = matFull,
            templateMaterial = matTemplate,
            renderWidth = renderWidth,
            renderHeight = renderHeight,
        }
    else
        print("[KARDS] 离屏渲染失败！")
        return nil
    end
end

--[[
    确保当前卡牌的外观纹理已渲染落盘（保存卡牌前调用）：
    - 已点过「渲染」按钮（LastRenderedPaths 存在且文件仍在）→ 仅指向，不重复渲染；
    - 未渲染过 → 立即离屏渲染并保存 PNG（耗时一次性，保存后组卡/生成直接引用文件路径）。
    @return table|nil { full, template, w, h }（DATA 相对路径 + 渲染像素尺寸）
]]
function KARDS.CardEditor.Canvas.EnsureCardTextures()
    local app = KARDS.CardEditor.Canvas.CardAppearance
    local key = app and (tostring(app.name) .. "|" .. tostring(app.cardType) .. "|" .. tostring(app.imagePath)) or ""
    local paths = KARDS.CardEditor.Canvas.LastRenderedPaths
    -- 仅当缓存路径属于当前卡（标识一致）且文件仍在时才复用，否则重新渲染（防止同名卡串用）
    if paths and paths.key == key and file.Exists(paths.full, "DATA") and file.Exists(paths.template, "DATA") then
        local size = KARDS.CardEditor.Canvas.LastRenderedCardSize
        return {
            full = paths.full,
            template = paths.template,
            w = size and size.w or 300,
            h = size and size.h or 400,
        }
    end
    local result = KARDS.CardEditor.Canvas.RenderAndSaveCard(KARDS.CardEditor.Canvas.CardAppearance)
    if not result then return nil end
    KARDS.CardEditor.Canvas.LastRenderedMaterial = result.fullMaterial
    KARDS.CardEditor.Canvas.LastRenderedTemplateMaterial = result.templateMaterial
    KARDS.CardEditor.Canvas.LastRenderedCardSize = { w = result.renderWidth or 300, h = result.renderHeight or 400 }
    return {
        full = result.full,
        template = result.template,
        w = result.renderWidth or 300,
        h = result.renderHeight or 400,
    }
end

-- 获取卡牌的动态材质
function KARDS.CardEditor.Canvas.GetCardMaterial(cardName)
    local safeName = string.gsub(cardName, "[^%w]", "_")
    safeName = string.gsub(safeName, "%s+", "_")
    safeName = string.gsub(safeName, "^_+", "")
    safeName = string.gsub(safeName, "_+$", "")
    
    return KARDS.CardEditor.Canvas.DynamicMaterials[safeName]
end

-- 清理旧的动态材质
function KARDS.CardEditor.Canvas.CleanupOldMaterials(maxAgeSeconds)
    maxAgeSeconds = maxAgeSeconds or 3600 -- 默认1小时
    local now = os.time()
    
    for name, data in pairs(KARDS.CardEditor.Canvas.DynamicMaterials) do
        if data.timestamp and (now - data.timestamp) > maxAgeSeconds then
            KARDS.CardEditor.Canvas.DynamicMaterials[name] = nil
            print("[KARDS] 清理过期材质: " .. name)
        end
    end
end

-- 生成：在玩家面前生成实际卡牌模型实体（basic_card），
-- 使其 front(0)/back(1)/side(2) 三个纹理槽分别应用渲染出的卡面/卡背纹理。
-- 基础卡 manifest 中三子网格 image_path 相同（共用占位纹理），无法靠同名材质
-- 覆盖，改为预填前置模组的 MaterialCache（cacheKey = modelID|子网格序号|imagePath），
-- 各槽使用独立材质对象；随后请求服务端生成实体，客户端 Draw 重建 renderable 时
-- 命中预填缓存，三槽各得其所。
-- mode：缺省 "full"（全图像生成：完整卡面，属性文字烘焙进纹理）；
--       "3d2d"（3D2D文字卡生成：无属性文字模板卡面 + 3D2D 文字实时悬浮叠加，
--        服务端回传实体后由 cl_card_text_overlay.lua 注册本地数据）。
function KARDS.CardEditor.Canvas.SpawnTestEntity(app, mode)
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    mode = mode or "full"

    -- 前置模组可用性检查（MaterialCache/ClearCache 由 cl_runtime.lua 提供）
    if not PMXStaticImporter or not PMXStaticImporter.MaterialCache or not PMXStaticImporter.ClearCache then
        print("[KARDS] 前置模组 PMX Static Model Importer 未加载，无法生成卡牌模型")
        return
    end

    -- 卡面材质选择：全图像 = 完整卡面动态材质；3D2D 文字卡 = 无属性文字的模板卡面（hideNumbers 离屏渲染）
    local matFront
    if mode == "3d2d" then
        matFront = KARDS.CardEditor.Canvas.LastRenderedTemplateMaterial
        if not matFront then
            print("[KARDS] 3D2D文字卡需要「无属性文字」模板卡面，请先点击渲染按钮（生成模板卡面）")
            return
        end
    else
        matFront = KARDS.CardEditor.Canvas.LastRenderedMaterial
        if not matFront then
            print("[KARDS] 没有找到卡牌材质，请先渲染卡牌")
            return
        end
    end

    -- 卡背：materials/kards/cardbacks/<country>.png（与预览区一致，缺失时回退卡面）
    local countryName = tostring(app and app.country or ""):lower()
    local cardbackPath = "materials/kards/cardbacks/" .. countryName .. ".png"
    local matBack = Material(cardbackPath, "vertexlitgeneric noclamp smooth")
    if not matBack or matBack:IsError() then
        matBack = matFront
    end

    -- front 槽专用材质：LastRenderedMaterial 是给 surface 2D 绘制用的动态材质，
    -- 带 $vertexcolor=1/$vertexalpha=1/$translucent=1，而前置 mesh 顶点流仅 pos3+normal3+uv2
    -- （无颜色流），直接使用会读取垃圾颜色/alpha 导致 front 面透明、透出背面卡背
    -- （表现为"双面都是卡背"）。故为 mesh 重建材质：
    --  - 去掉 $vertexcolor/$vertexalpha（无颜色流）
    --  - 不用 $translucent（RT 背景被 render.Clear 清为 alpha=0，$translucent 会整体混合透明；
    --    且 front 子网格 translucent=false 在 opaque pass 渲染）
    --  - 改用 $alphatest 按 alpha 裁剪：卡面区域 alpha=255 显示，背景 alpha=0 裁掉
    -- RT 名用 GetTexture 取真实注册名（GetString 返回小写规范化值，直接用作 $basetexture
    -- 可能与 RT 注册名不匹配导致纹理解析失败）。
    local meshFrontMat = matFront
    local rtTexture = matFront:GetTexture("$basetexture")
    local rtName = rtTexture and rtTexture:GetName() or matFront:GetString("$basetexture")
    if rtName and rtName ~= "" then
        meshFrontMat = CreateMaterial(
            "Kards_Mesh_Front_" .. tostring(math.floor(SysTime() * 1000)),
            "UnlitGeneric",
            {
                ["$basetexture"] = rtName,
                ["$alphatest"] = 1,
                ["$alphatestreference"] = 0.5,
                ["$nolod"] = 1,
            }
        )
        print("[KARDS] front 槽 mesh 专用材质已创建，basetexture = " .. rtName)
    end

    -- 基础卡模型：3 子网格，front 卡面 / back 卡背 / side 侧面
    -- 前置 cl_runtime.lua 的 read_mesh_file 以 `for i = 1, submeshCount` 传 submeshIndex，
    -- 故 cacheKey 的序号段从 1 开始（对应 manifest.submeshes 数组顺序）。
    -- 为避免硬编码序号/占位图路径，直接读取 manifest 按名称匹配槽位。
    local modelID = "basic_card"

    -- 先清空旧缓存（销毁旧 renderable 与材质缓存），再预填，顺序不可颠倒
    PMXStaticImporter.ClearCache(modelID)
    local cache = PMXStaticImporter.MaterialCache

    -- 读取 manifest（DATA 优先，回退 GAME data_static 随包分发路径）
    local manifestPath = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    local manifestContent = file.Read(manifestPath, "DATA")
    if not manifestContent then
        manifestContent = file.Read("data_static/" .. manifestPath, "GAME")
    end
    local manifest = manifestContent and util.JSONToTable(manifestContent)
    if manifest and manifest.submeshes then
        for idx, submesh in ipairs(manifest.submeshes) do
            local subName = tostring(submesh.name or submesh.safe_name or "")
            local key = modelID .. "|" .. tostring(idx) .. "|" .. tostring(submesh.image_path or "")
            if subName == "front" then
                cache[key] = meshFrontMat -- front：卡面成品（mesh 专用材质，避免顶点流无颜色导致的透明/异常）
            elseif subName == "back" then
                cache[key] = matBack  -- back：卡背（side 按需求暂不填，走前置默认占位纹理）
            end
            print("[KARDS] 预填纹理槽 " .. idx .. " (" .. subName .. ") -> " .. key)
        end
    else
        print("[KARDS] 警告：读取 basic_card manifest 失败，无法预填纹理槽（" .. tostring(manifestPath) .. "）")
    end

    -- 视线前方定位（与旧临时显示一致）
    local tr = ply:GetEyeTraceNoCursor()
    local eye = ply:EyePos()
    -- 异常判定改为相对距离：未命中、或命中点距玩家过远（>3000，编辑器全屏 VGUI 射线可能射向虚空深处）。
    -- 注意不能用绝对 z 阈值（如 pos.z < -500）：虚空地图的地板平面就在 z≈-12287，
    -- 绝对阈值会把正常的地板命中误判为异常，回退位置（EyePos+Forward*100-25）反而
    -- 把卡牌埋入地板之下（z=-12310 < 地板 -12287）导致实体完全不可见
    local pos
    if not tr.Hit or (tr.HitPos - eye):Length() > 3000 or tr.HitPos.z > 100000 then
        pos = eye + ply:EyeAngles():Forward() * 100 -- 玩家视线正前方固定位置，保证卡牌进入视野
        print("[KARDS] 生成位置异常，已回退到视线前方（z=" .. string.format("%.1f", pos.z) .. "）")
    else
        pos = tr.HitPos + tr.HitNormal * 5
    end
    -- 兜底：任何情况下卡牌不低于命中平面/玩家视线高度 +5 单位，避免埋入地板/虚空底部
    local floorZ = (tr.Hit and tr.HitPos.z or eye.z) + 5
    if pos.z < floorZ then pos.z = floorZ end
    local ang = ply:GetAngles()
    ang.y = ang.y + 180

    -- 3D2D 文字卡：预存待绑定数据，服务端回传实体后由 cl_card_text_overlay 注册本地叠加
    if mode == "3d2d" and KARDS.CardTextOverlay then
        local cardSize = KARDS.CardEditor.Canvas.LastRenderedCardSize
        KARDS.CardTextOverlay._PendingLocal = {
            data = app,
            worldW = 7.2, -- basic_card manifest bounds 36x54 × 0.2（与 sent_kards_battle_card.KardsScale 一致）
            worldH = 10.8,
            renderW = cardSize and cardSize.w or 300,
            renderH = cardSize and cardSize.h or 400,
        }
    end

    -- 请求服务端生成实际卡牌模型实体（sent_kards_battle_card 固定应用 basic_card，
    -- 服务端负责替换上一次生成的预览实体），客户端 Draw 命中预填材质
    net.Start("KARDS_Editor_SpawnCard")
    net.WriteVector(pos)
    net.WriteAngle(ang)
    net.SendToServer()

    -- 添加一些效果
    local effectdata = EffectData()
    effectdata:SetOrigin(pos)
    util.Effect("balloon_pop", effectdata)

    print("[KARDS] 已生成实际卡牌模型（卡面/卡背/侧面纹理已应用渲染结果，模式：" .. mode .. "）")
end
