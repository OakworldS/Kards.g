-- 牌桌卡牌 manifest 共享模块（re.md T-H2）
-- 收敛服务端 init.lua 与客户端 cl_init.lua 各自维护的多份同构 Ensure*Manifest 实现：
-- 统一为「basic_card 副本克隆 + image_path 改写」单一实现（manifest 路径 + image_path
-- 目录参数化），两端仅保留薄包装调用，避免一端改动另一端漏改导致隐蔽不一致
-- （manifest 复制时序问题：PNG 落盘必须在实体首次 Draw 前，见 cl_init.lua 备注）。

KARDS = KARDS or {}
KARDS.CardManifest = KARDS.CardManifest or {}

-- basic_card 模板 manifest（所有副本克隆的几何/子网格来源）
local BASIC_MANIFEST = "pmx_static_importer/models/basic_card/manifest.json"

-- basic_card 模板 manifest 解析结果缓存（2026-08-14 性能优化）：
-- Clone 在每次抽牌/建卡/建卡堆都会克隆 basic_card manifest，原实现每次
-- file.Read + util.JSONToTable 重新解析。模板文件随插件发布、运行时无人改写，
-- 解析结果缓存后每次克隆仅结构深拷贝，省去重复磁盘读取与 JSON 解析
--（抽牌每张卡在服务端 EnsureBattleDeck 与客户端 EnsureDeck 各克隆一次）。
local BasicManifestCache = nil

local function LoadBasicManifest()
    if BasicManifestCache then return BasicManifestCache end
    local src = file.Read(BASIC_MANIFEST, "DATA")
    if not src then return nil end
    local m = util.JSONToTable(src)
    if not m then return nil end
    BasicManifestCache = m
    return m
end

-- 深拷贝 submeshes（Clone 会改写 front/back image_path，不能直接复用缓存表内的子网格）
local function CopySubmeshes(src)
    local out = {}
    if src then
        for _, sm in ipairs(src) do
            table.insert(out, table.Copy(sm))
        end
    end
    return out
end

--[[
    业务包装：组卡卡牌 manifest 副本（克隆 basic_card + front/back → data/kards_deck/
    <safeName>/）。服务端 / 客户端共用同一入口（re.md T-H2），不再各自维护同构薄包装。
    @param modelID  string 目标模型 ID
    @param safeName string 卡牌安全标识（DeckSafeName）
    @return boolean
]]
function KARDS.CardManifest.EnsureDeck(modelID, safeName)
    return KARDS.CardManifest.Clone(modelID, "kards_deck/" .. safeName, "[Kards] 组卡卡牌")
end

--[[
    业务包装：卡组槽卡 manifest 副本（仅显示卡背，front=back → data/kards_battledeck/
    <safeName>/，纹理目录与 kards_deck/ 隔离避免同卡 path 互相污染）
    @param modelID  string 目标模型 ID
    @param safeName string 卡牌安全标识
    @return boolean
]]
function KARDS.CardManifest.EnsureBattleDeck(modelID, safeName)
    return KARDS.CardManifest.Clone(modelID, "kards_battledeck/" .. safeName, "[Kards] 卡组槽卡牌")
end

--[[
    业务包装：手牌槽卡 manifest 副本（front 缺失白色兜底、back → data/kards_handslot/，
    纹理目录与 kards_battledeck/ 隔离）
    @param modelID string 目标模型 ID（唯一 kards_handslot）
    @return boolean
]]
function KARDS.CardManifest.EnsureHandSlot(modelID)
    return KARDS.CardManifest.Clone(modelID, "kards_handslot", "[Kards] 手牌槽卡")
end

--[[
    业务包装：卡堆单张档（tier 1）manifest 副本（basic_card 副本，front/back →
    data/kards_deckpile/usa/ 卡背图）
    @return boolean
]]
function KARDS.CardManifest.EnsureDeckPileSingle()
    return KARDS.CardManifest.Clone("kards_deckpile_1", "kards_deckpile/usa", "[Kards] 卡堆单张档")
end

--[[
    克隆 basic_card manifest 到目标 modelID（幂等：每次重写，保证 image_path 指向真实
    存在的 data/ PNG——旧格式副本是虚拟路径，前置渲染加载不到贴图会显示紫黑棋盘格）。
    批量多卡共用 basic_card 会互相覆盖 image_path，故每张卡克隆独立 manifest
    （独立 model_id 与独立 image_path，几何共享 basic_card 的 mesh.json）。

    @param modelID   string 目标模型 ID（同时作为 model_id / safe_display_name）
    @param imageDir  string manifest image_path 的 data/ 相对目录，front/back 子网格
                     分别指向 "data/<imageDir>/front.png" / "data/<imageDir>/back.png"
    @param errPrefix string|nil 失败日志前缀（nil 则不打印）
    @return boolean
]]
function KARDS.CardManifest.Clone(modelID, imageDir, errPrefix)
    local path = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    local frontPath = "data/" .. imageDir .. "/front.png"
    local backPath = "data/" .. imageDir .. "/back.png"

    -- 幂等优化（2026-08-14）：目标 manifest 已存在且 image_path 已指向目标目录时
    -- 跳过重写。同 modelID 重复克隆（如卡组槽卡/组卡重初始化）不再重复
    -- file.Read + JSON 编解码 + file.Write；校验失败（旧格式虚拟路径/字段缺失）
    -- 仍会重写一次自愈，保持原「保证 image_path 指向真实 data/ PNG」的语义。
    local existing = file.Read(path, "DATA")
    if existing then
        local em = util.JSONToTable(existing)
        if em and em.model_id == modelID and em.safe_display_name == modelID
            and em.mesh_file == "pmx_static_importer/models/basic_card/mesh.json" and em.submeshes then
            local ok, needFront, needBack = true, false, false
            for _, sm in ipairs(em.submeshes) do
                if sm.name == "front" then
                    needFront = true
                    if sm.image_path ~= frontPath then ok = false break end
                elseif sm.name == "back" then
                    needBack = true
                    if sm.image_path ~= backPath then ok = false break end
                end
            end
            if ok and needFront and needBack then return true end
        end
    end

    local base = LoadBasicManifest()
    if not base then
        if errPrefix then print(errPrefix .. "：读取 basic_card manifest 失败") end
        return false
    end
    local m = table.Copy(base)
    m.submeshes = CopySubmeshes(base.submeshes)
    m.model_id = modelID
    m.safe_display_name = modelID
    m.mesh_file = "pmx_static_importer/models/basic_card/mesh.json" -- 几何共享
    if m.submeshes then
        for _, sm in ipairs(m.submeshes) do
            if sm.name == "front" then
                sm.image_path = frontPath
            elseif sm.name == "back" then
                sm.image_path = backPath
            end
        end
    end
    file.CreateDir("pmx_static_importer/models/" .. modelID)
    return file.Write(path, util.TableToJSON(m, true))
end

--[[
    克隆 basic_card_unit manifest 到目标 modelID（单位部署战场模型，2026-08-11）。
    与 Clone 不同：Clone 克隆 basic_card 模板，CloneUnit 克隆 basic_card_unit 模板
    （mesh_file 指向 basic_card_unit/mesh.json，bounds 为 120×142.137×1.5）。

    @param modelID  string 目标模型 ID
    @param imageDir string data/ 相对目录（front/back 分别指向 "data/<imageDir>/front.png"）
    @return boolean
]]
function KARDS.CardManifest.CloneUnit(modelID, imageDir)
    local srcPath = "pmx_static_importer/models/basic_card_unit/manifest.json"
    local src = file.Read(srcPath, "DATA")
    if not src then return false end
    local m = util.JSONToTable(src)
    if not m or not m.submeshes then return false end
    m.model_id = modelID
    m.safe_display_name = modelID
    m.mesh_file = "pmx_static_importer/models/basic_card_unit/mesh.json"
    if m.submeshes then
        for _, sm in ipairs(m.submeshes) do
            if sm.name == "front" then
                sm.image_path = "data/" .. imageDir .. "/front.png"
            elseif sm.name == "back" then
                sm.image_path = "data/" .. imageDir .. "/back.png"
            end
        end
    end
    local outPath = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    file.CreateDir("pmx_static_importer/models/" .. modelID)
    return file.Write(outPath, util.TableToJSON(m, true))
end

--[[
    改写已有 manifest 的 front/back image_path（幂等：已指向目标目录则跳过写入）。
    用于卡堆档位模型（PMXStaticImporter.exe 导入的专属模型，manifest 已存在，
    仅需把可见面改写为卡背图）。

    @param modelID  string 目标模型 ID
    @param imageDir string data/ 相对目录（front/back 分别指向 "data/<imageDir>/front.png"）
    @return boolean
]]
function KARDS.CardManifest.RewriteImagePaths(modelID, imageDir)
    local path = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    local src = file.Read(path, "DATA")
    if not src then return false end
    local m = util.JSONToTable(src)
    if not m or not m.submeshes then return false end
    local dirty = false
    for _, sm in ipairs(m.submeshes) do
        if sm.name == "front" and sm.image_path ~= "data/" .. imageDir .. "/front.png" then
            sm.image_path = "data/" .. imageDir .. "/front.png"
            dirty = true
        elseif sm.name == "back" and sm.image_path ~= "data/" .. imageDir .. "/back.png" then
            sm.image_path = "data/" .. imageDir .. "/back.png"
            dirty = true
        end
    end
    if not dirty then return true end
    return file.Write(path, util.TableToJSON(m, true))
end

--[[
    改写已有 manifest 的「全部」子网格 image_path 为单一值（幂等：已指向则跳过写入）。
    用于非 front/back 子网格名的模型（如前线符号模型子网格名为 平面/平面.063，
    RewriteImagePaths 只匹配 front/back 无法命中）——统一改写所有子网格指向同一张
    纯色纹理图。

    @param modelID   string 目标模型 ID
    @param imagePath string 新 image_path（manifest 相对 GAME 目录，如
                      "data/pmx_static_importer/<modelID>/front.png"）
    @return boolean
]]
function KARDS.CardManifest.RewriteAllImagePaths(modelID, imagePath)
    local path = "pmx_static_importer/models/" .. modelID .. "/manifest.json"
    local src = file.Read(path, "DATA")
    if not src then return false end
    local m = util.JSONToTable(src)
    if not m or not m.submeshes then return false end
    local dirty = false
    for _, sm in ipairs(m.submeshes) do
        if sm.image_path ~= imagePath then
            sm.image_path = imagePath
            dirty = true
        end
    end
    if not dirty then return true end
    return file.Write(path, util.TableToJSON(m, true))
end

--[[
    组卡卡牌卡面/卡背 PNG 落盘（2026-10-03 白图修复；服务端与客户端共用的单份实现）

    背景：manifest 的 image_path 指向 data/kards_deck/<safeName>/{front,back}.png，前置模组经
    Material(image_path) 加载。若请求材质时文件尚未落盘，引擎会把该路径的「错误材质」缓存到
    本会话结束（ClearCache 只清前置模组的 Lua 缓存，刷新不了引擎层），卡面将永久呈现前置模组
    的纯白兜底。

    监听服务器上服务端与客户端共用同一 data 目录，而服务端铺卡时先创建了 manifest：客户端实体
    一旦渲染就会以该路径请求材质，若 PNG 未落盘即被永久缓存（表现为约一半卡牌纯白，具体张数随
    实体创建与落盘的先后浮动）。故服务端在生成组卡实体之前先调用本函数写就 PNG，使客户端首次
    渲染时文件必然存在。dedicated 场景下客户端本地无副本，由客户端准备流程自行落盘
    （cl_battle_material.lua 的 DeckPrepareCardFiles）。

    @param safeName     string 安全标识（ENT:DeckSafeName 结果；总部卡带 hq_ 前缀）
    @param templatePath string|nil 模板渲染 PNG 的 DATA 路径（卡面来源）
    @param country      string|nil 国家（卡背来源 materials/kards/cardbacks/<country>.png）
    @return boolean 是否写入卡面（无模板文件返回 false，维持既有白色兜底）
]]
function KARDS.CardManifest.WriteDeckCardImages(safeName, templatePath, country)
    if not safeName or safeName == "" then return false end
    if not (templatePath and file.Exists(templatePath, "DATA")) then return false end
    local frontData = file.Read(templatePath, "DATA")
    if not frontData then return false end
    local cbPath = "materials/kards/cardbacks/" .. tostring(country or "usa"):lower() .. ".png"
    local backData = file.Exists(cbPath, "GAME") and file.Read(cbPath, "GAME") or nil
    local dir = "kards_deck/" .. safeName
    file.CreateDir(dir)
    file.Write(dir .. "/front.png", frontData)
    file.Write(dir .. "/back.png", backData or frontData) -- 卡背缺失用卡面兜底（同客户端行为）
    return true
end
