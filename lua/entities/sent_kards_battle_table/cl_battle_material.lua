--[[
    Kards 战斗牌桌客户端模块：卡牌材质链路（cl_battle_material.lua，2026-08-15 C1 拆分）

    自 cl_init.lua（lua/entities/sent_kards_battle_table/cl_init.lua）材质段迁移：
      - 组卡卡牌材质/文字初始化（DeckPrepareCardFiles / DeckInitCard / ProcessDeckCard）：
        manifest 副本 → 卡面/卡背 PNG 落盘 → ClearCache → 前置模组按 image_path 加载
        不透明贴图 → Overlay:AddLocal 绑定 3D2D 文字（re.md T-M1/T-H3 链路）
      - 国家卡背 PNG 读取缓存（ReadCardbackPNG）：会话级 file.Read 缓存
      - 卡牌纹理落盘（WriteCardTextures）：目录创建 + 双面文件写 + ClearCache 重建
      - 牌桌卡牌材质就绪统一驱动（KardsTableCardMaterial Think + 实体自身驱动入队）：
        组卡 kards_deck_*（卡面 + 卡背 + 文字）/ 卡组槽 kards_battledeck_*（仅卡背）
      - 卡堆档位模型卡背预置（PrepareDeckPileFiles / KardsBattleDeckPileMaterial）
      - 手牌槽卡卡面预置（PrepareHandSlotFiles / KardsHandSlotCardMaterial）
      - 共享工具：PrefillBackFlip（back 槽 UV 镜像修正）、KARDS.PrefillUnitCrop
        （basic_card_unit UV 裁切）、KardsResetPerMatchDedup（per-modelID 去重表复位，
        占位声明在 cl_init.lua 顶部，本文件 include 时赋值）

    挂载：cl_init.lua include 本文件（KardsDeckCardView 段之后、手牌槽卡可见性段之前）。
    约定：段落自含 local 随本文件迁移；被 cl_init.lua 后续段（抽牌/总部动画）引用的
    local（PrefillBackFlip）因 include 词法展开仍在其声明点之后可见；跨段共享走
    KARDS 命名空间。
]]

-- ====================================================================
-- 组卡卡牌材质/文字初始化（客户端）：与编辑器「生成3D2D卡牌」同链路
-- ====================================================================
-- 卡面纹理在「保存卡牌」时已离屏渲染一次并落盘为不透明 RGB PNG（保存文件记录
-- texturePath/textureSize）。故此处对每张组卡卡牌：本地创建模型副本 manifest
-- （image_path 指向 data/kards_deck/<safeName>/front.png|back.png）→ 将保存文件指向的
-- 卡面渲染与卡背图复制到该路径 → ClearCache 销毁旧 renderable → 前置模组按 image_path
-- 直接加载不透明贴图（已实测：不预填 MaterialCache 时卡面正常；Material() 自动材质为
-- 半透明渲染，预填后卡面透明而露出卡背）→ Overlay:AddLocal 绑定文字（renderW/H
-- 用保存文件记录的渲染尺寸，与模板像素对齐）。全程不再离屏渲染，避免反复渲染的性能风险。
-- 注意：manifest + PNG 复制必须在实体首次 Draw 前完成（Think 阶段同步执行，见
-- DeckPrepareCardFiles / KardsDeckCardMaterial）——引擎材质按路径缓存，先缺后补无法刷新，
-- 否则新卡（本会话才落盘）会白屏无纹理直至重启。

-- 已初始化卡牌实体集合 / 排队处理中（weak keys：实体移除自动清理）
local deckCardReady = setmetatable({}, { __mode = "k" })
local deckCardPending = setmetatable({}, { __mode = "k" })
-- modelID 级就绪标记：同 modelID 副本（加卡复制）复用首次初始化成果（manifest/贴图/缓存），
-- 跳过重复文件 I/O 与 ClearCache 重建（后者销毁共享 renderable 强制重建是加卡卡顿主因）
local deckModelReady = {}
-- 组卡卡面准备等待起点（weak keys，2026-10-03 白图修复）：卡名 NW 与 modelID NW 不保证同帧
-- 到位（批量铺卡时 NW 同步可延迟 1 秒以上），名称未到位时查不到外观数据。此时不得先创建
-- manifest（PNG 未落盘而 manifest 已存在会让实体 Draw 以该路径请求材质，引擎把错误材质缓存
-- 到本会话结束，卡面永久纯白）。记录首次等待时刻，超过 DECK_PREP_WAIT_TIMEOUT 秒仍未解析
-- 则按旧格式卡兜底（白色），避免无限重试。
local deckPrepWaitStart = setmetatable({}, { __mode = "k" })
local DECK_PREP_WAIT_TIMEOUT = 3
-- 翻面变化（Kards_GridFlipped）改由 EntityNetworkedVarChanged 事件即时检测并处理
--（见下方统一驱动 KardsTableCardNWChanged），不再每帧轮询对比

-- 卡牌 manifest 副本统一由共享模块 KARDS.CardManifest 提供（EnsureDeck /
-- EnsureBattleDeck / EnsureHandSlot / EnsureDeckPileSingle，re.md T-H2）：
-- 服务端已创建则直接复用，远程客户端本地无副本时此处调用同样会自行创建；
-- 两端同一入口，不再维护同构薄包装。

-- 卡堆档位模型清单（与 init.lua ENT.DeckPileModelIDs 同步硬编码：客户端实体对象上
-- 不存在服务端 ENT 字段；PMXStaticImporter.exe 不支持数字命名，档位用罗马数字）
local DeckPileModelIDs = {
    "basic_card_xxxx", -- 40 张
    "basic_card_xxx",  -- 30 张
    "basic_card_xx",   -- 20 张
    "basic_card_x",    -- 10 张
    "basic_card_v",    -- 5 张
    "kards_deckpile_1",-- 单张（basic_card 副本）
}

-- 卡堆档位 tier 清单（与 init.lua ENT.DeckPileTiers 同步硬编码：客户端实体对象上
-- 不存在服务端 ENT 字段；与上方 DeckPileModelIDs 数组同序对应，DeckPileTiers[i]
-- ↔ DeckPileModelIDs[i]）
local DeckPileTiers = { 40, 30, 20, 10, 5, 1 }

-- 卡堆档位 manifest 的槽专属副本（2026-08-12 取消统一 usa 卡背）：原档位模型
-- manifest 全局唯一、两槽共用一份 image_path，无法分别表达两槽不同顶卡的国家卡背；
-- 现按槽克隆为 kards_deckpile_<tier>_s<slot>（服务端 SpawnDeckPile 按此 ID 建实体，
-- 见 table_battledeck.lua DeckPileModelIDForSlot）：
--   单张档（tier 1）= basic_card 副本（Clone，几何共享 basic_card mesh）
--   其余档        = 复制导入 manifest（mesh_file / bounds 原样保留，仅改 model_id
--                   / safe_display_name 与 front/back image_path）
-- imageDir 按顶卡国家变化（kards_deckpile/usa、kards_deckpile/uk …），幂等重写。
-- 顶层卡背（front 槽）即「最顶面的卡背图」，随数据层卡组顶卡（Kards_DeckTopBack
-- NW）动态改写。

-- @param tier    number 档位（40/30/20/10/5/1，见 DeckPileTiers）
-- @param slot    number 槽位编号（1/2）
-- @param imageDir string data/ 相对目录（front/back → data/<imageDir>/{front,back}.png）
-- @return boolean
local function EnsureDeckPileManifestSlot(tier, slot, imageDir)
    local slotID = "kards_deckpile_" .. tier .. "_s" .. slot
    if tier == 1 then
        return KARDS.CardManifest.Clone(slotID, imageDir, "[Kards] 卡堆单张档")
    end
    local srcID = nil
    for i, t in ipairs(DeckPileTiers) do
        if t == tier then srcID = DeckPileModelIDs[i] break end
    end
    if not srcID then return false end
    local src = file.Read("pmx_static_importer/models/" .. srcID .. "/manifest.json", "DATA")
    if not src then return false end
    local m = util.JSONToTable(src)
    if not m then return false end
    m.model_id = slotID
    m.safe_display_name = slotID
    if m.submeshes then
        for _, sm in ipairs(m.submeshes) do
            if sm.name == "front" or sm.name == "back" then
                sm.image_path = "data/" .. imageDir .. "/" .. sm.name .. ".png"
            end
        end
    end
    file.CreateDir("pmx_static_importer/models/" .. slotID)
    return file.Write("pmx_static_importer/models/" .. slotID .. "/manifest.json", util.TableToJSON(m, true))
end

-- 卡堆档位 manifest 顶面卡背改写为目标国家（从槽专属 modelID 解析 tier/slot）
-- @param modelID string 槽专属档位 modelID（kards_deckpile_<tier>_s<slot>）
-- @param country string 顶卡国家（Kards_DeckTopBack NW，路径段白名单校验）
-- @return boolean
local function ApplyDeckPileTopBack(modelID, country)
    local tier, slot = modelID:match("^kards_deckpile_(%d+)_s(%d)$")
    if not tier or not tostring(country or ""):match("^[%w_]+$") then return false end
    return EnsureDeckPileManifestSlot(tonumber(tier), tonumber(slot), "kards_deckpile/" .. country)
end

--[[
    back 槽 UV 镜像修正（2026-08-09）：basic_card 家族模型（含卡堆档位模型）的
    back 子网格从 -z 方向采样的 UV 相对图片是水平镜像的（建模时 back 面 UV 未按
    背向重映射——U 仍沿模型 +X，而从 -z 观察 +X 落在屏幕左侧，图像左右颠倒；
    front 槽从 +z 观察正常，故卡组槽卡 front=卡背图显示正常、而手牌/组卡/翻面卡
    的 back 槽卡背图镜像）。卡背图须在 back 槽水平翻转才能从 -z 方向正常显示。
    前置模组 Draw 时优先使用 MaterialCache（cl_canvas_editor.lua 预填实测生效，
    "预填后卡面透明"现象即预填材质被使用），故在此为 back 槽预填带
    $basetexturetransform 水平翻转的 UnlitGeneric 材质——不透明（无
    $vertexcolor/$vertexalpha/$translucent：mesh 顶点流仅 pos3+normal3+uv2，带颜色
    流会读垃圾数据致透明，配方同 cl_canvas_editor.lua 的 mesh 专用材质）。
    调用时机：必须在 PMXStaticImporter.ClearCache(modelID) 之后——ClearCache 清空
    MaterialCache，实体 Draw 重建 renderable 时才会读取本函数预填的翻转材质。

    @param modelID string 模型副本 ID（manifest 已就绪；无 back 子网格则跳过）
]]
local function PrefillBackFlip(modelID)
    if not PMXStaticImporter or not PMXStaticImporter.MaterialCache then return end
    local path = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    local src = file.Read(path, "DATA")
    if not src then
        -- 附加包 GAME 随包分发副本回退（同 cl_canvas_editor.lua 的 manifest 读取方式）
        src = file.Read("data_static/" .. path, "GAME")
    end
    if not src then return end
    local m = util.JSONToTable(src)
    if not m or not m.submeshes then return end
    local cache = PMXStaticImporter.MaterialCache
    for idx, sm in ipairs(m.submeshes) do
        if sm.name == "back" then
            local imagePath = tostring(sm.image_path or "")
            local key = modelID .. "|" .. tostring(idx) .. "|" .. imagePath
            local cur = cache[key]
            -- 幂等：已预填过同名材质则跳过（CreateMaterial 同名会更新，避免反复重建）
            if not (cur and cur.GetName and cur:GetName() == ("Kards_BackFlip_" .. modelID)) then
                -- 与前置 cl_runtime.lua get_image_material 同款纹理解析：Material() 加载
                -- data/ PNG（克隆 manifest 的 image_path = "data/<imageDir>/back.png"），
                -- 再以 GetName() 作为 $basetexture，保证材质系统解析到同一纹理
                -- （直接写路径可能因大小写/别名解析不一致导致纹理解析失败）
                local base = Material(imagePath, "vertexlitgeneric noclamp smooth")
                if base and not base:IsError() then
                    cache[key] = CreateMaterial("Kards_BackFlip_" .. modelID, "UnlitGeneric", {
                        ["$basetexture"] = base:GetName(),
                        -- 绕纹理中心 (0.5, 0.5) 水平翻转（scale -1 1）：修正 back 槽水平镜像
                        ["$basetexturetransform"] = "center 0.5 0.5 scale -1 1 rotate 0 translate 0 0",
                        ["$nolod"] = 1,
                    })
                end
            end
            return
        end
    end
end
-- 2026-08-15 桥接：PrefillBackFlip 被 cl_init.lua（InitDrawCardFace 等）与后续
-- 拆分文件调用——GMod include 独立编译执行，不共享本文件词法作用域，经 KARDS
-- 命名空间暴露（local 本体保留，本文件内继续词法使用）。
KARDS.PrefillBackFlip = PrefillBackFlip

--[[
    basic_card_unit UV 裁切预填（2026-08-11）：单位部署战场模型 basic_card_unit 复用手牌
    卡牌纹理（209×290），通过 V 轴缩放 229/290 ≈ 0.789655（锚定 v=0）裁切底部
    品质/效果描述/词条区域（209×61），仅保留上部 209×229。
    调用时机：必须在 PMXStaticImporter.ClearCache(modelID) 之后。

    @param modelID string 模型副本 ID（basic_card_unit 克隆，manifest 已就绪）
]]
-- 挂 KARDS 命名空间（非顶层 local）：main chunk 局部变量接近 GLua 200 上限
-- （2026-08-11 实测 local function 声明会占用槽位触发超限报错），故不占局部槽
function KARDS.PrefillUnitCrop(modelID)
    if not PMXStaticImporter or not PMXStaticImporter.MaterialCache then return end
    local path = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    local src = file.Read(path, "DATA")
    if not src then return end
    local m = util.JSONToTable(src)
    if not m or not m.submeshes then return end
    local cache = PMXStaticImporter.MaterialCache
    for idx, sm in ipairs(m.submeshes) do
        if sm.name == "front" or sm.name == "back" then
            local imagePath = tostring(sm.image_path or "")
            local key = modelID .. "|" .. tostring(idx) .. "|" .. imagePath
            local matName = "Kards_UnitCrop_" .. modelID .. "_" .. sm.name
            local cur = cache[key]
            if not (cur and cur.GetName and cur:GetName() == matName) then
                local base = Material(imagePath, "vertexlitgeneric noclamp smooth")
                if base and not base:IsError() then
                    -- V 轴缩放 229/290 ≈ 0.789655，锚定 v=0；back 槽需同时水平翻转
                    local scaleX = (sm.name == "back") and -1 or 1
                    local transform = ("center 0.5 0 scale %s 0.789655 rotate 0 translate 0 0"):format(scaleX)
                    cache[key] = CreateMaterial(matName, "UnlitGeneric", {
                        ["$basetexture"] = base:GetName(),
                        ["$basetexturetransform"] = transform,
                        ["$nolod"] = 1,
                    })
                end
            end
        end
    end
end

-- ====================================================================
-- 国家卡背 PNG 读取缓存（E 修复 2026-08-12）：materials/kards/cardbacks/<country>.png
-- （~163KB）在 ProcessBattleDeckCard / InitDrawCardFace / DeckPrepareCardFiles /
-- PrepareHandSlotFiles 每卡重复 file.Read——开局 9+ 卡 × 读盘为卡顿来源之一；国家数
-- 有限（键为 country 字符串），会话内缓存 file.Read 结果。缺失文件返回 nil 并缓存
-- （材料文件静态，不会后续出现；nil 与「未缓存」用键存在性区分）。
-- ====================================================================
local CardbackPNGCache = {}
local function ReadCardbackPNG(country)
    country = tostring(country or "usa"):lower()
    if CardbackPNGCache[country] ~= nil then return CardbackPNGCache[country] end
    local data = file.Read("materials/kards/cardbacks/" .. country .. ".png", "GAME")
    CardbackPNGCache[country] = data
    return data
end
-- 2026-08-15 桥接：被 cl_init.lua（InitDrawCardFace 等）调用——include 独立编译
-- 执行不共享本文件词法作用域，经 KARDS 命名空间暴露（同 PrefillBackFlip）。
KARDS.ReadCardbackPNG = ReadCardbackPNG

-- ====================================================================
-- 卡牌纹理落盘（re.md T-M1 共享）：组卡与卡组槽两套「材质/贴图链路」共用的原子操作
-- —— 把卡面/卡背 PNG 复制到 manifest image_path 对应的真实文件 + ClearCache 重建。
-- 两链路差异（卡面来源/是否绑文字）在调用方（DeckPrepareCardFiles /
-- ProcessBattleDeckCard），本函数仅统一「目录创建 + 双面文件写 + 缓存重建」。
-- 卡背缺失用卡面兜底（保证 back.png 真实存在，避免卡背棋盘格）；卡面缺失不写 front
-- （旧格式卡 / 卡组槽卡背缺失 → 前置模组白色兜底，维持原回退行为）。
--
-- @param dir        string PNG 落盘目录（data 相对路径，= manifest image_path 目录，
--                    如 "kards_deck/<safeName>" / "kards_battledeck/<safeName>"）
-- @param frontData  string|nil 卡面 PNG 数据（nil → 不写 front.png）
-- @param backData   string|nil 卡背 PNG 数据（nil → 用 frontData 兜底写 back.png）
-- @param modelID    string|nil 模型副本 ID（非 nil → PMXStaticImporter.ClearCache 重建
--                    renderable，使实体 Draw 重建时按 image_path 加载新贴图）
local function WriteCardTextures(dir, frontData, backData, modelID)
    file.CreateDir(dir)
    if frontData then file.Write(dir .. "/front.png", frontData) end
    if backData then file.Write(dir .. "/back.png", backData)
    elseif frontData then file.Write(dir .. "/back.png", frontData) end -- 卡背缺失 → 卡面兜底
    if modelID and PMXStaticImporter and PMXStaticImporter.ClearCache then
        PMXStaticImporter.ClearCache(modelID)
        -- back 槽 UV 镜像修正：ClearCache 清空 MaterialCache 后预填翻转材质
        PrefillBackFlip(modelID)
    end
end

-- 卡牌信息查找索引（2026-08-14 性能优化）：按归一化显示名/文件名建哈希，
-- 避免每次抽牌/建卡对全部卡牌信息线性扫描（抽牌 InitDrawCardFace 每张卡调一次）。
-- 索引以 GetAllCardsInfo 返回的表身份为校验键：SaveSystem 保存/删除卡牌后重建
-- 全量表（身份变化）自动触发重建，无需额外失效钩子。冲突键保持首张命中
-- （与原线性遍历「首个命中 break」一致）。
local DeckCardIndexCache, DeckCardIndexFor = nil, nil

-- 本地保存文件按名称匹配外观数据（卡面纹理路径 + 渲染尺寸 + 文字叠加数据源）。
-- 支持两种卡标识（Kards_CardName NW 因生成链路而异）：
--   组卡（table_deckmode）→ 卡牌显示名 app.name；battle 抽卡/卡组槽（table_battledeck）
--   → 保存文件名（card:GetName() = fileName）。故先精确匹配显示名，再按归一化
--   （去目录/扩展名）匹配显示名与文件名，保证两端都能命中。
local function DeckFindCardInfo(cardName)
    local appearance, texturePath, textureSize = nil, nil, nil
    if KARDS.CardEditor and KARDS.CardEditor.SaveSystem then
        -- 归一化卡标识：去目录前缀、去 .json/.txt 扩展名（保存文件名可能带扩展名）
        local function norm(s)
            local n = tostring(s or ""):match("[^/\\]+$") or tostring(s or "")
            -- 2026-08-12（调试会话 card-face-blank 修复）：统一小写比较——info.fileName 来自
            -- 磁盘文件名（GetCardFiles），Windows 磁盘大小写不定（血红镰刀落盘小写
            -- %e8%a1%80…，卡组条目/JSON fileName 字段大写 %E8%A1%80…）；原大小写敏感比较
            -- 未命中 → appearance nil → 不写 front.png → 卡面白色兜底。
            return (n:gsub("%.json$", ""):gsub("%.txt$", "")):lower()
        end
        local target = norm(cardName)
        local infos = KARDS.CardEditor.SaveSystem.GetAllCardsInfo() or {}
        if infos ~= DeckCardIndexFor then
            DeckCardIndexFor = infos
            DeckCardIndexCache = {}
            for _, info in ipairs(infos) do
                local k1 = info.name and info.name:lower() or ""
                local k2 = norm(info.name)
                local k3 = norm(info.fileName)
                if k1 ~= "" and not DeckCardIndexCache[k1] then DeckCardIndexCache[k1] = info end
                if k2 ~= "" and not DeckCardIndexCache[k2] then DeckCardIndexCache[k2] = info end
                if k3 ~= "" and not DeckCardIndexCache[k3] then DeckCardIndexCache[k3] = info end
            end
        end
        local info = (DeckCardIndexCache[cardName:lower()] or DeckCardIndexCache[target])
        if info then
            appearance = info.cardAppearance
            texturePath = info.texturePath
            textureSize = info.textureSize
        end
    end
    return appearance, texturePath, textureSize
end
-- 2026-08-15 桥接：被 cl_init.lua（InitDrawCardFace / 悬停预览卡）调用——include
-- 独立编译执行不共享本文件词法作用域，经 KARDS 命名空间暴露（同 PrefillBackFlip）。
KARDS.DeckFindCardInfo = DeckFindCardInfo

-- 组卡卡牌文件准备（manifest 副本 + 卡面/卡背 PNG 落盘）：
-- 必须在实体首次 Draw（前置模组按 manifest image_path 调 Material() 建材质）之前完成——
-- GMod 材质系统按路径名缓存：若在 PNG 落盘前先以该路径请求过材质，引擎层会缓存错误材质
-- 直到本次会话结束（之后复制文件 + ClearCache 只能清前置模组的 Lua 缓存，无法刷新引擎层
-- 材质缓存，卡面呈现前置模组的白色兜底 =「没有纹理」；重启后文件已存在才正常）。
-- 故本函数须在 Think 阶段（先于当帧渲染）同步调用，保证首次 Draw 时文件已存在。
-- 返回是否处理完成（成功后同 modelID 副本不再重复文件 I/O 与 ClearCache）。
local function DeckPrepareCardFiles(modelID, safeName, appearance, texturePath, force)
    -- 身份未解析（卡名 NW 未就绪 → 查不到外观数据）时不得先创建 manifest：manifest 一旦落盘，
    -- 实体 Draw 就会按 image_path 请求 PNG，而此刻 PNG 尚未落盘，引擎会缓存该路径的错误材质到
    -- 本会话结束，卡面永久纯白（ClearCache 只清前置模组 Lua 缓存，刷新不了引擎层）。
    -- 故先返回未完成、由调用方保持重试；force 为真表示已超过等待上限，按旧格式卡兜底继续。
    if not appearance and not force then return false end
    if not KARDS.CardManifest.EnsureDeck(modelID, safeName) then
        print("[Kards] 组卡卡牌 manifest 副本创建失败: " .. modelID)
        return false
    end
    -- 卡面纹理：直接应用保存文件指向的路径（保存时已离屏渲染落盘为不透明 RGB PNG）。
    -- 前置模组按 manifest image_path 从 data/kards_deck/<safeName>/front.png 直接加载贴图
    -- （ClearCache 后重建 renderable 命中真实文件，实测卡面正常）；不再预填 MaterialCache——
    -- Material() 自动创建的 data/ PNG 材质为半透明渲染，预填后卡面透明而露出卡背（已实测回退）
    local tmplPath = appearance and texturePath and texturePath.template or nil
    if not (tmplPath and file.Exists(tmplPath, "DATA")) then
        return true -- 旧格式卡（无卡面文件）：前置模组按 image_path 加载缺失即白色兜底，维持原回退行为
    end
    -- 复制卡面/卡背 PNG 到 manifest image_path 对应的真实文件（data/kards_deck/<safeName>/）：
    -- 卡面 = 保存文件指向的模板渲染；卡背 = materials/kards/cardbacks/<country>.png（缺失用卡面兜底）
    -- （WriteCardTextures 共享函数，re.md T-M1）
    local frontData = file.Read(tmplPath, "DATA")
    local country = tostring(appearance.country or ""):lower()
    local backData = ReadCardbackPNG(country)
    WriteCardTextures("kards_deck/" .. safeName, frontData, backData, modelID)
    -- 副本诊断：front.png（manifest image_path 指向）是否复制成功（与模板渲染文件大小一致）
    local copyData = file.Read("kards_deck/" .. safeName .. "/front.png", "DATA")
    print("[Kards] 组卡卡牌副本诊断: template_size=" .. tostring(frontData and #frontData or 0)
        .. " | front_copy_size=" .. tostring(copyData and #copyData or 0)
        .. " | match=" .. tostring(frontData and copyData and #frontData == #copyData or false))
    return true
end

-- 初始化单张组卡卡牌：manifest 副本 → 复制卡面/卡背到 image_path 对应文件 → ClearCache
-- 重建 → 前置模组直接加载不透明贴图 → 绑定 3D2D 文字。
-- 性能：同 modelID 副本（加卡复制）仅首次执行文件 I/O 与 ClearCache，后续实体只绑定文字。
-- 文件准备（manifest + PNG 复制）已由首次发现实体时的 Think 同步完成，此处兜底再确认一次。
local function DeckInitCard(ent, modelID)
    deckCardPending[ent] = nil
    if not IsValid(ent) then return end
    -- 已就绪（可能已被其他初始化路径处理）则直接返回，避免重复绑定文字
    if deckCardReady[ent] then return end
    -- 翻面卡守卫：0.1s 延迟初始化期间翻面的卡不绑定 3D2D 文字
    -- （NW 事件 KardsTableCardNWChanged 已移除文字并标记就绪）
    if ent:GetNWBool("Kards_GridFlipped", false) then
        deckCardReady[ent] = true
        return
    end
    local safeName = modelID:match("^kards_deck_(.+)$")
    if not safeName then return end
    local appearance, texturePath, textureSize = DeckFindCardInfo(ent:GetNWString("Kards_CardName", ""))
    -- 首次初始化该 modelID：写 manifest + 复制卡面/卡背 + 清缓存重建（仅一次；通常已由
    -- 首次发现时的同步准备完成，此处兜底——如当时保存文件尚未就绪）
    if not deckModelReady[modelID] then
        if not DeckPrepareCardFiles(modelID, safeName, appearance, texturePath) then
            return -- 准备失败：不标记就绪，下帧 Think 会重新尝试（如保存文件稍后可用）
        end
        deckModelReady[modelID] = true
    end
    if not appearance or not KARDS.CardTextOverlay then
        -- 无本地外观数据 / 叠加层未加载：回退实体模式（3D2D 文字从 NW 变量读取）
        if KARDS.CardTextOverlay then KARDS.CardTextOverlay:AddEntity(ent) end
        deckCardReady[ent] = true
        return
    end
    -- 3D2D 文字：编辑器同款本地绑定（appearance 静态表实时读：费用/攻防/词条/描述富文本）；
    -- renderW/H 用保存文件记录的渲染尺寸（与模板像素对齐，避免文字错位）
    local texW, texH = 300, 400
    if textureSize and textureSize.w and textureSize.h then
        texW, texH = textureSize.w, textureSize.h
    end
    KARDS.CardTextOverlay:AddLocal(ent, appearance, 7.2, 10.8, texW, texH)
    deckCardReady[ent] = true
    print("[Kards] 组卡卡牌纹理已应用: " .. tostring(ent:GetNWString("Kards_CardName", "")))
end

-- ====================================================================
-- 牌桌卡牌材质就绪统一驱动（re.md T-H3）：
-- 原两个 Think 钩子（KardsDeckCardMaterial / KardsBattleDeckCardMaterial）每帧对全部
-- sent_pmx_static_imported 实体全量扫描匹配属性；现改为「实体自身驱动」——实体创建
-- （OnEntityCreated）或 NW 属性变更（EntityNetworkedVarChanged）时注册到待初始化集合，
-- 下方单一 Think 钩子只处理集合成员、完成即移除，不再每帧全量扫描。两类卡牌按属性
-- 区分初始化路径：组卡 kards_deck_*（卡面 + 卡背 + 3D2D 文字）/ 卡组槽 kards_battledeck_*
--（仅卡背，不渲染正面纹理、不绑定文字）。
-- ====================================================================

-- 待初始化集合（weak keys：实体移除自动清理）：新实体创建或卡属性 NW 变更时入队，
-- 处理完成即移除；非卡牌实体（卡堆/手牌槽/牌桌模型等）入队后快速移出。
local cardPendingEntities = setmetatable({}, { __mode = "k" })
-- 实体 NW 初始值等待超时（秒）：批量创建卡牌时 NW 同步可能延迟 1 秒以上才全部到位，
-- 超时后仍未识别为卡牌（role 空）的实体从待初始化集合移除（见 Think KardsTableCardMaterial）
local KARDS_CARD_INIT_TIMEOUT = 3

-- 已处理卡组槽卡实体集合 / modelID 级就绪标记（weak keys：实体移除自动清理）
local battleDeckReady = setmetatable({}, { __mode = "k" })
local battleDeckModelReady = {}

-- 2026-08-15 桥接：battleDeckReady / battleDeckModelReady 被 cl_init.lua 的
-- InitDrawCardFace（抽牌段，本文件 include 点之后）表索引访问——GMod include 独立
-- 编译执行，不共享本文件词法作用域，经 KARDS 命名空间暴露（local 本体保留，本文件
-- 内继续词法使用；引用位于函数体内运行时求值，晚于本 include 执行，无时序问题）。
KARDS.battleDeckReady = battleDeckReady
KARDS.battleDeckModelReady = battleDeckModelReady

-- E 修复（2026-08-12）：kards_battledeck 目录贴图「会话级已写」标记（键 = 目录路径
-- kards_battledeck/<safeName>_d<serial>）。不能按 file.Exists 判断是否跳过写入：serial
-- 目录跨桌/跨会话复用，可能残留 Fix A2 之前写死的旧 usa 卡背文件（用户反馈：步兵55团
-- 手牌显示 usa 卡背——旧 usa 残留 + file.Exists 误跳过覆盖）。同 safeName 首卡写入
-- （覆盖旧内容），后续同卡跳过（卡背内容按国家整局幂等）。不复位：跨对局内容不变，
-- manifest 重写仍由 battleDeckModelReady 复位驱动（B 修复）。
local battleDeckFilesWritten = {}

-- B 修复（2026-08-12）：per-modelID 去重表随对局复位（KardsTableBattleStart 调用，
-- 占位声明见 hqRevealStarted 附近）。污染链：modelID = kards_battledeck_<safeName>_d<serial>
--（serial 每桌从 1 递增）→ 跨桌复用同一 modelID → 上一桌 battleDeckModelReady 残留
-- true 使新桌 ProcessBattleDeckCard 跳过 EnsureBattleDeck 重写 manifest → 保留上一桌
-- InitDrawCardFace 写成的真实卡面 manifest（kards_deck/<safeName>，同一 modelID 下
-- EnsureDeck 与 EnsureBattleDeck 写同一 manifest.json 路径）→ 卡组槽顶卡渲染成上一桌
-- 卡面（血红镰刀整局延续）。deckModelReady 同模式（组卡初始化）一并复位。
-- 复位用就地清空（保留引用）：local 别名 deckModelReady / battleDeckModelReady
-- 仍指向原表。weak-key 表（battleDeckReady / drawFaceReady / cardPendingEntities）
-- 随实体销毁自动清理，无需复位；deckPileBackReady 键含 country（manifest 内容由
-- country 幂等重写决定），跨桌无污染。
-- 2026-08-15：改挂 KARDS 命名空间（原无 local 全局赋值 + cl_init.lua 顶部占位
-- local 的方案在 include 独立编译执行下失效——两处不共享作用域）。
KARDS.KardsResetPerMatchDedup = function()
    for k in pairs(battleDeckModelReady) do battleDeckModelReady[k] = nil end
    for k in pairs(deckModelReady) do deckModelReady[k] = nil end
end

-- 注册实体到待初始化集合（去重；NW 同步晚于实体创建，仅靠创建事件可能漏掉初始
-- NW 值，故 NW 变更事件（EntityNetworkedVarChanged）会再次入队兜底）
local function EnqueueCardEntity(ent)
    if IsValid(ent) and ent:GetClass() == "sent_pmx_static_imported" then
        cardPendingEntities[ent] = CurTime()
        -- 竞态兜底：初始 NW 同步晚于 OnEntityCreated（GetNWString 此时返回空），且 NW 值
        -- 作为初始状态到达时 EntityNetworkedVarChanged 不触发——若实体在 Think 的 else 分支
        -- 被移出集合（role 暂空），将永远不再处理（卡面文件不落盘、3D2D 文字不绑定）。
        -- 故入队后延迟复检：NW 就绪（role 为 deck/battledeck）后重新入队；非卡牌实体复检为空直接跳过。
        -- 已处理实体（deckCardReady 命中）复检入队为无害空转（ProcessDeckCard 守卫直接返回）。
        timer.Simple(0.5, function()
            if not IsValid(ent) then return end
            local role = ent:GetNWString("Kards_CardRole", "")
            if role == "deck" or role == "battledeck" then
                cardPendingEntities[ent] = CurTime()
            end
        end)
    end
end

hook.Add("OnEntityCreated", "KardsTableCardEnqueue", function(ent)
    EnqueueCardEntity(ent)
end)

-- NW 属性变更：卡属性就绪/更新 → 重新入队；翻面切换（Kards_GridFlipped）→ 即时
-- 移除/恢复 3D2D 文字并重新入队（原每帧对比 deckCardFlipped 检测变化，现事件驱动）
hook.Add("EntityNetworkedVarChanged", "KardsTableCardNWChanged", function(ent, key, oldv, newv)
    if not IsValid(ent) or ent:GetClass() ~= "sent_pmx_static_imported" then return end
    if key == "Kards_CardRole" or key == "Kards_DeckModelID" then
        cardPendingEntities[ent] = CurTime()
    elseif key == "Kards_GridFlipped" then
        if newv and KARDS.CardTextOverlay then
            KARDS.CardTextOverlay:Remove(ent) -- 翻面：移除已绑定的 3D2D 文字
        end
        deckCardReady[ent] = nil -- 翻面/恢复正面均清空就绪标记，重新初始化
        deckCardPending[ent] = nil
        cardPendingEntities[ent] = CurTime()
    end
end)

-- 组卡卡牌（kards_deck_*）单实体初始化：返回 true 表示本实体处理完成可从集合移除。
-- 同步准备（DeckPrepareCardFiles：manifest + PNG 复制）必须先于实体首次 Draw：Think
-- 阶段先于当帧渲染，保证前置模组首次 Material() 时文件已存在，避免引擎层缓存错误
-- 材质导致卡面白屏无纹理（见 DeckPrepareCardFiles 注释）。文字先以实体模式绑定
-- （NW 数据）：卡牌出现即文字出现，避免延迟初始化期间文字空白（随后 DeckInitCard
-- 无缝覆盖为本地富文本模式）。翻面卡（Kards_GridFlipped，达携带上限）：不渲染卡面
-- 与 3D2D 文字——卡面朝下由服务端 180° 旋转实现（init.lua SetGridFlipped，正面子网格
-- 转至 -z 朝下不可见），仅保证卡背纹理落盘；翻面/恢复正面变化由 NW 事件即时处理。
local function ProcessDeckCard(ent)
    local modelID = ent:GetNWString("Kards_DeckModelID", "")
    if modelID == "" then return false end -- NW 未就绪：保持入队等待后续 NW 事件
    local flipped = ent:GetNWBool("Kards_GridFlipped", false)
    if not deckCardReady[ent] and not deckCardPending[ent] then
        -- 卡面 PNG 落盘须早于实体首次 Draw：此处 Think 先于渲染阶段同步复制，
        -- 保证当帧渲染时文件已存在（新卡首帧即正常显示纹理，无需重启）。
        -- 翻面卡同样须先落盘卡背纹理（正面朝下不可见，卡背朝上需真实卡背图）
        local safeName = modelID:match("^kards_deck_(.+)$")
        if safeName and not deckModelReady[modelID] then
            -- 卡名 NW 与 modelID NW 不保证同帧到位（批量铺卡时 NW 可延迟 1 秒以上）。名称未到位
            -- 时 DeckFindCardInfo 查不到外观数据，此时若继续准备会先落 manifest 而 PNG 缺失，
            -- 实体当帧 Draw 请求该路径即被引擎永久缓存为错误材质（卡面纯白且重启前不可恢复）。
            -- 故保持入队重试到名称为止；超过 DECK_PREP_WAIT_TIMEOUT 仍未解析则按旧格式卡兜底。
            local waitStart = deckPrepWaitStart[ent]
            if not waitStart then
                waitStart = CurTime()
                deckPrepWaitStart[ent] = waitStart
            end
            local force = (CurTime() - waitStart) > DECK_PREP_WAIT_TIMEOUT
            local appearance, texturePath = DeckFindCardInfo(ent:GetNWString("Kards_CardName", ""))
            if not appearance and not force then return false end -- 身份未解析：不落 manifest 不锁存
            -- 总部卡（battle 模式 Kards_DeckRole="hq"）卡背固定 usa（测试版暂定）：
            -- 临时改写 country 写卡背，同步执行完立即还原，不影响其他卡
            local hqFixed = ent:GetNWString("Kards_DeckRole", "") == "hq" and appearance
            local savedCountry = hqFixed and appearance.country or nil
            if hqFixed then appearance.country = "usa" end
            local prepOk = DeckPrepareCardFiles(modelID, safeName, appearance, texturePath, force)
            if hqFixed then appearance.country = savedCountry end
            if not prepOk then return false end -- 准备未完成：不锁存，下帧重试
            deckModelReady[modelID] = true
            deckPrepWaitStart[ent] = nil
        end
        if flipped then
            -- 翻面卡：仅保证卡背纹理就绪，不绑定任何 3D2D 文字
            deckCardReady[ent] = true
        else
            deckCardPending[ent] = true
            if KARDS.CardTextOverlay then KARDS.CardTextOverlay:AddEntity(ent) end
            timer.Simple(0.1, function()
                if IsValid(ent) then DeckInitCard(ent, modelID) end
            end)
        end
    end
    return true
end

-- 卡组槽卡牌（kards_battledeck_*）单实体初始化：仅复制卡背 PNG（front=back=卡背图，
-- 2026-08-12 起按该卡国家卡背 materials/kards/cardbacks/<country>.png（用户反馈对手
-- 新抽卡/卡组槽卡背应为该卡原卡背；卡堆顶面 SyncDeckTopBack/ApplyDeckPileTopBack 同
-- 为国家卡背逻辑）；外观缺失/卡名未就绪兜底 usa）落盘到 data/kards_battledeck/<safeName>/，
-- 再 ClearCache 重建 renderable 使前置模组按 manifest image_path 加载卡背——不绑定任何
-- 3D2D 文字、不渲染正面纹理（性能优化）。卡背 PNG 缺失时直接不写文件 → 前置模组按
-- image_path 加载缺失 → 白色兜底（与组卡「旧格式卡无卡面」回退行为一致）。同 modelID
-- 副本仅首次执行文件 I/O 与 ClearCache（battleDeckModelReady 去重）；本实体处理完成
-- 才置位 battleDeckReady（卡名 NW 未就绪时保持入队重试，避免卡背写死 usa 兜底）。
-- 返回 true 表示可从集合移除。
local function ProcessBattleDeckCard(ent)
    local modelID = ent:GetNWString("Kards_DeckModelID", "")
    if modelID == "" then return false end -- NW 未就绪：保持入队等待后续 NW 事件
    -- 卡背国家（2026-08-18，规划 B1）：优先取服务端下发的 Kards_CardCountry NW
    --（抽牌/返回手牌实体：非敏感国家标识，卡背视觉本就公开）；卡组槽卡无该字段
    -- → 回退卡名（本地定向表优先，其次 NW）查外观国家。均未就绪 → 保持入队重试
    --（battleDeckReady 不置位），下帧 Think 重试。
    local country = ent:GetNWString("Kards_CardCountry", "")
    if country == "" then
        local cardName = KARDS.GetCardIdentity(ent)
        if cardName == "" then return false end
        local appearance = DeckFindCardInfo(cardName)
        country = tostring((appearance and appearance.country) or "usa"):lower()
    else
        country = tostring(country):lower()
    end
    if battleDeckReady[ent] then return true end
    battleDeckReady[ent] = true
    local safeName = modelID:match("^kards_battledeck_(.+)$")
    if safeName and not battleDeckModelReady[modelID] then
        -- 卡背 = 该卡国家卡背（2026-08-12：原统一 usa——卡组槽/对手手牌卡背应显示
        -- 该卡原卡背；对手抽牌分支 faceUp=false 不改写 manifest，卡背即本目录内容）
        if KARDS.CardManifest.EnsureBattleDeck(modelID, safeName) then
            local dir = "kards_battledeck/" .. safeName
            -- E 修复（2026-08-12）：同 safeName 写文件去重（卡背内容按国家幂等，整局
            -- 不变）——原每 modelID 无条件 WriteCardTextures（file.CreateDir + 2×file.Write
            -- 同一路径），开局/多张同卡重复写盘为卡顿来源之一。
            -- E 修复（2026-08-12 修正）：按「本会话已写」标记（battleDeckFilesWritten）而非
            -- file.Exists 去重——serial 目录跨桌/跨会话复用，残留 Fix A2 前旧 usa 卡背文件时
            -- file.Exists=true 会误跳过覆盖（用户反馈：步兵55团手牌显示 usa 卡背）。同 safeName
            -- 首卡写入覆盖旧内容，后续同卡跳过。已写 → 仅 ClearCache 重建本 modelID renderable
            --（每 modelID 仍须一次）。
            if not battleDeckFilesWritten[dir] then
                -- front=back=卡背图（WriteCardTextures 共享函数，re.md T-M1）：
                -- 卡背 PNG 缺失时不写文件 → 前置模组按 image_path 加载缺失 → 白色兜底
                local backData = ReadCardbackPNG(country)
                if not backData then
                    backData = ReadCardbackPNG("usa")
                end
                if backData then
                    WriteCardTextures(dir, backData, backData, modelID)
                end
                -- 已尝试写入（卡背缺失兜底时也标记：本会话该卡无卡背数据可写，后续同卡跳过）
                battleDeckFilesWritten[dir] = true
            else
                if PMXStaticImporter and PMXStaticImporter.ClearCache then
                    PMXStaticImporter.ClearCache(modelID)
                    -- back 槽 UV 镜像修正：ClearCache 清空 MaterialCache 后预填翻转材质
                    PrefillBackFlip(modelID)
                end
            end
            battleDeckModelReady[modelID] = true
        end
    end
    return true
end

-- 单一 Think：只处理待初始化集合（实体自身驱动，完成即移除；无新卡时集合为空，
-- 不再每帧全量扫描全部 sent_pmx_static_imported 实体）
hook.Add("Think", "KardsTableCardMaterial", function()
    for ent in pairs(cardPendingEntities) do
        if not IsValid(ent) then
            cardPendingEntities[ent] = nil
        elseif ent:GetNWString("Kards_CardRole", "") == "deck" then
            if ProcessDeckCard(ent) then cardPendingEntities[ent] = nil end
        elseif ent:GetNWString("Kards_CardRole", "") == "battledeck" then
            if ProcessBattleDeckCard(ent) then cardPendingEntities[ent] = nil end
        else
            -- NW 尚未就绪（role 空）：实体保留在集合中等待初始 NW 到达（批量创建时
            -- NW 同步可延迟 1 秒以上才全部到位，且初始值到达不触发
            -- EntityNetworkedVarChanged——立即移出将永久漏掉）。超过
            -- KARDS_CARD_INIT_TIMEOUT 仍无 role 才移出（非卡牌实体），后续 NW 变更再入队。
            -- 时间戳由 EnqueueCardEntity / EntityNetworkedVarChanged 入队时刷新（CurTime）
            local enqTime = cardPendingEntities[ent]
            if not enqTime or CurTime() - enqTime > KARDS_CARD_INIT_TIMEOUT then
                cardPendingEntities[ent] = nil
            end
        end
    end
end)

-- ====================================================================
-- 卡堆档位模型卡背文件预置（session 级，InitPostEntity 执行，同手牌槽
-- PrepareHandSlotFiles 的时序理由）：引擎材质按路径缓存——若 PNG/manifest 在实体
-- 首次请求材质后才落盘，本会话白屏无纹理直至重启。故在地图加载后、任何人进入对战
-- 之前，把 usa 卡背 PNG 复制到 data/kards_deckpile/usa/ 并改写全部档位模型 manifest
--（含单张档 basic_card 副本），保证卡堆实体首次 Draw 时文件已在。实体钩子
-- KardsBattleDeckPileMaterial 的 ClearCache 仅作兜底重建，不承担首发材质职责。
-- 幂等：成功后同会话不再重复文件 I/O；失败可重试。
-- ====================================================================
local deckPileFilesReady = false
local function PrepareDeckPileFiles()
    if deckPileFilesReady then return true end
    -- 1) 预复制全部国家卡背 PNG：materials/kards/cardbacks/<name>.png → data/
    --    kards_deckpile/<name>/{front,back}.png（front=back=卡背图；卡堆顶面按顶卡
    --    国家动态指向对应目录，缺失时前置模组白色兜底）
    for _, fileName in ipairs(file.Find("materials/kards/cardbacks/*.png", "GAME")) do
        local name = fileName:match("^(.+)%.png$")
        if name and name ~= "" then
            local backData = ReadCardbackPNG(name)
            if backData then
                file.CreateDir("kards_deckpile/" .. name)
                file.Write("kards_deckpile/" .. name .. "/front.png", backData)
                file.Write("kards_deckpile/" .. name .. "/back.png", backData)
            end
        end
    end
    -- 2) 预置两槽档位 manifest 副本（image_path 初始 usa 占位；实体钩子
    --    KardsBattleDeckPileMaterial 按各槽顶卡 NW 改写为对应国家卡背目录）
    for slot = 1, 2 do
        for _, tier in ipairs(DeckPileTiers) do
            if not EnsureDeckPileManifestSlot(tier, slot, "kards_deckpile/usa") then return false end
        end
    end
    -- 3) 预加载全部国家卡背材质（2026-08-12 闪白修复）：卡堆顶面按顶卡国家改写
    --    manifest + ClearCache 后，Draw 重建时首次加载该国卡背 PNG——引擎材质首次
    --    编译/纹理上传发生在那帧渲染内 → 敌方卡组顶闪白一帧（本方顶面 country 开局
    --    即确定、开局已加载过故不闪）。此处按 manifest image_path 同款路径
    --    （"data/kards_deckpile/<name>/{front,back}.png"）预加载全部国家材质 →
    --    引擎按路径缓存 → 后续任意国家改写即时命中，消除闪白。
    for _, fileName in ipairs(file.Find("materials/kards/cardbacks/*.png", "GAME")) do
        local name = fileName:match("^(.+)%.png$")
        if name and name ~= "" then
            Material("data/kards_deckpile/" .. name .. "/front.png", "vertexlitgeneric noclamp smooth")
            Material("data/kards_deckpile/" .. name .. "/back.png", "vertexlitgeneric noclamp smooth")
        end
    end
    deckPileFilesReady = true
    return true
end
hook.Add("InitPostEntity", "KardsDeckPileFiles", PrepareDeckPileFiles)


-- 卡堆档位实体卡背处理（每帧）：档位 manifest 与卡背 PNG 已由 PrepareDeckPileFiles
-- 在 InitPostEntity 预置（各国家卡背 + 两槽槽专属 manifest 骨架）。此处对出现的卡堆
-- 实体按其槽位顶卡国家（Kards_DeckTopBack NW，服务端 SyncDeckTopBack 下发，观战者
-- 同样收到）改写 manifest image_path → 对应国家卡背目录 + ClearCache 重建一次
--（按 slotID@country 去重：顶卡变化即 country 变化 → 重新改写重建，顶面卡背随数据层
-- 卡组顶卡样式切换，取消统一 usa 卡背）。前置模组 renderable 按 manifest 重建时读取
-- 该国卡背图；back 槽朝下，ClearCache 后预填翻转材质（PrefillBackFlip）。
local deckPileBackReady = {}
hook.Add("Think", "KardsBattleDeckPileMaterial", function()
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWBool("Kards_IsBattleDeckPile", false) then
            local modelID = ent:GetNWString("Kards_DeckModelID", "")
            if modelID ~= "" then
                local country = ent:GetNWString("Kards_DeckTopBack", "usa")
                -- 空国家（无卡组 / 卡组抽空，服务端 SyncDeckTopBack 下发 ""）不改写：
                -- 空堆时卡堆档位已全部隐藏（SetDeckPileTier tier 0），顶面不可见
                if country ~= "" then
                    local key = modelID .. "@" .. country
                    if not deckPileBackReady[key] then
                        if PrepareDeckPileFiles() and ApplyDeckPileTopBack(modelID, country) then
                            deckPileBackReady[key] = true
                            -- 销毁该 modelID 旧 renderable：manifest（image_path）已就绪，
                            -- 强制实体 Draw 重建时按 image_path 加载该国卡背（每槽每档唯一）
                            if PMXStaticImporter and PMXStaticImporter.ClearCache then
                                PMXStaticImporter.ClearCache(modelID)
                                PrefillBackFlip(modelID) -- back 槽 UV 镜像修正（卡堆 back 槽朝下）
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ====================================================================
-- 手牌槽卡牌卡面文件预置（session 级，回合开始即执行）：
-- 引擎材质按路径缓存——若 PNG/manifest 在实体首次请求材质后才落盘，本会话白屏无纹理
-- 直至重启（详见 DeckPrepareCardFiles 注释）。故在 InitPostEntity（地图加载后、任何人
-- 进入对战的牌桌实体与手牌槽卡创建之前）提前把 UK 卡背 PNG 复制到 data/kards_handslot/
-- 并写好 kards_handslot manifest，保证实体首次 ApplyImportedModel / Draw 时文件已在；
-- 实体钩子 KardsHandSlotCardMaterial 的 ClearCache 仅作兜底重建，不承担首发材质职责。
-- 仅写 back（朝下，-z 卡背子网格）：back 槽就是卡背——卡背 = UK 卡背图（卡背图片
-- 放卡背槽）；front（朝上，+z 卡面）不写文件 → 缺失白色兜底"正面"占位（卡牌平躺
-- 卡面朝上时俯视见 front，即"正面"，避免"正反两面都是卡背"；并删除旧会话可能残留的
-- front.png，否则引擎按路径缓存会继续加载旧卡背）。
-- 幂等：成功后同会话不再重复文件 I/O；失败可重试。
-- ====================================================================
local handSlotFilesReady = false
local function PrepareHandSlotFiles()
    -- 防御旧残留：front 槽=卡面，任何时候都不应存在卡背图（缺失 → 白色兜底"正面"）。
    -- 每次调用都删除 front.png（文件删除幂等，开销可忽略）：旧版本曾把卡背图写进
    -- front 槽（卡面方向 UV），卡背图按卡面方向采样会左右镜像；且引擎材质按路径缓存，
    -- 同会话内已加载的 front 卡背材质无法刷新，须靠删除文件 + 重启规避。
    file.Delete("kards_handslot/front.png")
    if handSlotFilesReady then return true end
    if not KARDS.CardManifest.EnsureHandSlot("kards_handslot") then
        return false
    end
    file.CreateDir("kards_handslot")
    local backData = ReadCardbackPNG("uk")
    if backData then
        file.Write("kards_handslot/back.png", backData)
    end
    handSlotFilesReady = true
    return true
end
hook.Add("InitPostEntity", "KardsHandSlotFiles", PrepareHandSlotFiles)

-- ====================================================================
-- 手牌槽卡牌卡背初始化（battle 模式）：模型副本 kards_handslot（front 缺失白色
-- 兜底"正面"占位、back=UK 卡背图，服务端 CreateHandCardSlots 创建）。卡面文件已
-- 在 InitPostEntity 预置
-- （PrepareHandSlotFiles），此处对出现的实体仅作兜底重试 + ClearCache 重建一次
-- （两槽共享 modelID，同 modelID 仅首次执行）。
-- ====================================================================
local handSlotModelReady = {}
hook.Add("Think", "KardsHandSlotCardMaterial", function()
    for _, ent in ipairs(ents.FindByClass("sent_pmx_static_imported")) do
        if IsValid(ent) and ent:GetNWBool("Kards_IsHandSlotCard", false) then
            local modelID = ent:GetNWString("Kards_DeckModelID", "")
            if modelID ~= "" and not handSlotModelReady[modelID] then
                if PrepareHandSlotFiles() then
                    handSlotModelReady[modelID] = true
                    -- 销毁该 modelID 旧 renderable：manifest（image_path）已就绪，
                    -- 强制实体 Draw 重建时按 image_path 加载 UK 卡背（两槽共享 modelID）
                    if PMXStaticImporter and PMXStaticImporter.ClearCache then
                        PMXStaticImporter.ClearCache(modelID)
                        -- back 槽 UV 镜像修正：ClearCache 后预填翻转材质（手牌槽卡背朝下）
                        PrefillBackFlip(modelID)
                    end
                end
            end
        end
    end
end)
