-- 牌桌卡牌 manifest 共享模块（re.md T-H2）
-- 收敛服务端 init.lua 与客户端 cl_init.lua 各自维护的多份同构 Ensure*Manifest 实现：
-- 统一为「basic_card 副本克隆 + image_path 改写」单一实现（manifest 路径 + image_path
-- 目录参数化），两端仅保留薄包装调用，避免一端改动另一端漏改导致隐蔽不一致
-- （manifest 复制时序问题：PNG 落盘必须在实体首次 Draw 前，见 cl_init.lua 备注）。

KARDS = KARDS or {}
KARDS.CardManifest = KARDS.CardManifest or {}

-- basic_card 模板 manifest（所有副本克隆的几何/子网格来源）
local BASIC_MANIFEST = "pmx_static_importer/models/basic_card/manifest.json"

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
    local src = file.Read(BASIC_MANIFEST, "DATA")
    if not src then
        if errPrefix then print(errPrefix .. "：读取 basic_card manifest 失败") end
        return false
    end
    local m = util.JSONToTable(src)
    if not m then return false end
    m.model_id = modelID
    m.safe_display_name = modelID
    m.mesh_file = "pmx_static_importer/models/basic_card/mesh.json" -- 几何共享
    if m.submeshes then
        for _, sm in ipairs(m.submeshes) do
            if sm.name == "front" then
                sm.image_path = "data/" .. imageDir .. "/front.png"
            elseif sm.name == "back" then
                sm.image_path = "data/" .. imageDir .. "/back.png"
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
