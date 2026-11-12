--[[
    Kards 战斗系统 - 3D 模型渲染接入层（共享：服务端生成实体 / 客户端相机联动）

    将前置模组「Simple Static Model Importer」（PMXStaticImporter，workshop
    3706539692）导入的静态模型接入战斗系统，用于快速测试。

    前置模组原理：Python 工具（PMXStaticImporter.exe）把 GLB/GLTF 转为自定义
    网格数据写入 garrysmod/data/pmx_static_importer/models/<model_id>/，
    游戏内以实体类 sent_pmx_static_imported 运行时渲染（非传统 Source .mdl，
    跳过编译管线）。服务端 ents.Create + ApplyImportedModel(modelID, scale)
    即可生成，客户端自动渲染。

    本模块提供：
      - 牌桌模型：SpawnTable 在牌桌原点（0,0,0）生成（相对牌桌世界坐标的原点）
      - 卡牌模型：SpawnCard 生成实体并绑定战斗卡牌对象，每帧采样
        card.pos / card.ang（与 sh_animation.lua 约定一致，相对牌桌的世界坐标）
        写入实体变换；由 KARDS.Animation:AnimateCard / ApplyNow 驱动时
        （真实时间模式 RealTime=true）按秒真实渐变
      - 一键演示：牌桌 + 6 张卡 发牌 → 1 张放置桌面 → 1 张移除动画
      - 相机联动：演示开始广播 kards_camera 预设视角（table 俯瞰）

    控制台命令（服务端）：
      kards_battle_list                         -- 列出已导入模型（model_id + display_name）
      kards_battle_table [scale] [modelID]      -- 在原点生成牌桌（scale 缺省 0.5）
      kards_battle_clear                        -- 移除全部牌桌/卡牌实体并恢复动画真实时间开关
      kards_battle_demo [cardScale] [tableScale]-- 一键演示（cardScale 缺省 1 / tableScale 缺省 0.5）

    模型发现：ListAvailableModels() 按 display_name / model_id 关键词匹配
    （牌桌关键词 table/kards_table/wooden，卡牌关键词 card/basic_card）；
    未导入或未匹配时打印可用模型列表，便于用 modelID 参数显式指定。
]]

KARDS = KARDS or {}
KARDS.BattleRender = KARDS.BattleRender or {}

-- 牌桌实体：TableEnts[tableID] = entity（缺省牌桌 "default"）
KARDS.BattleRender.TableEnts = KARDS.BattleRender.TableEnts or {}
-- 卡牌实体：CardEnts[tableID][card] = entity（card 为卡牌对象，缺省牌桌 "default"）
KARDS.BattleRender.CardEnts = KARDS.BattleRender.CardEnts or {}
-- 复用实体映射：ReuseEnts[tableID][card] = entity（2026-08-10，手牌拖拽打出）——
-- 拖拽中的手牌实体复用为战场卡时登记，CardEnter 事件消费：不新建实体、不广播
-- overlay（客户端保留 AddLocal），仅设置战场卡 NW 字段；复用实体不进 CardEnts
-- 位置驱动（客户端本地拥有变换，避免服务端每帧写回与客户端动画冲突）
KARDS.BattleRender.ReuseEnts = KARDS.BattleRender.ReuseEnts or {}
-- 活跃动画：ActiveAnims[tableID][anim] = true（按牌桌分表，多牌桌动画互不误伤），
-- Think 每帧 ApplyNow 驱动（真实时间模式采样）
KARDS.BattleRender.ActiveAnims = KARDS.BattleRender.ActiveAnims or {}
-- 演示状态（DemoState.cards = 演示创建的卡牌对象列表）
KARDS.BattleRender.DemoState = KARDS.BattleRender.DemoState or {}

-- 阵亡卡牌实体延迟销毁时长（秒，2026-09-26 缺口 C）：
-- 正式版此处会播死亡特效并立即销毁卡牌对象，仅留特效在播放；测试版无特效，
-- 故按 1 秒延迟销毁，让阵亡在画面上可被观察到。撤退 / 回手 / 洗入等其它离场立即销毁。
KARDS.BattleRender.FieldDeathRemoveDelay = 1.0

-- 按牌桌清理全部渲染状态（2026-08-18 规划 D8）：牌桌销毁/EntityRemoved 兜底调用，
-- 阻止 CardEnts 强引用卡牌对象阻止 GC，与 TableID 键随 EntIndex 递增永不回收。
-- 缺省牌桌 "default"（演示 kards_battle_demo 用）不在清理范围。
function KARDS.BattleRender:DestroyTable(tableID)
    if not tableID or tableID == "default" then return end
    self.TableEnts[tableID] = nil
    self.CardEnts[tableID] = nil
    self.ReuseEnts[tableID] = nil
    self.ActiveAnims[tableID] = nil
end

-- 模型关键词匹配表（display_name / model_id 包含任一关键词即命中）
local ModelKeywords = {
    table = { "table", "kards_table", "wooden" },
    card  = { "card", "basic_card" },
}

-- 默认参数（按需可调）
KARDS.BattleRender.Defaults = {
    TableScale = 3,   -- 牌桌缩放（wooden_table 实际约 20x8x10 单位，×3 后约 60x24x30）
    CardScale = 0.2,  -- 卡牌缩放（basic_card 约 120x1.5x180 单位，×0.2 后约 24x0.3x36）
    TableID = "default",
    YUpToZUp = true,  -- y-up 轴修正：标准 GLB（y 垂直）导入 Source（z 垂直）后模型竖立，
                      -- 实体绕 x 轴 -90°（pitch=-90）使其平躺（牌桌桌面/卡牌面朝上）
}

-- 检查前置模组是否可用
local function IsImporterAvailable()
    return PMXStaticImporter ~= nil and PMXStaticImporter.ListAvailableModels ~= nil
end

--[[
    读取模型 manifest 的 bounds 中心偏移（已按运行缩放与 y-up 轴修正换算）

    部分 GLB 模型几何不在原点（如 wooden_table 主体在 y≈-806 处），
    且标准 GLB 为 y-up 竖立坐标系（导入器 axis_preset 默认不转轴时模型
    在 Source 中竖立）。生成实体时按中心偏移 + 绕 x 轴修正旋转，可使
    模型几何中心对齐目标位置且平躺（可见居中）。

    @param modelID string 模型 ID（已规范化）
    @param scale   number|nil 运行缩放（ApplyImportedModel 的 scale 同时缩放几何与碰撞盒）
    @param fixAxis boolean|nil 是否做 y-up → z-up 轴修正（绕 x +90°）
    @return Vector 模型几何中心相对实体原点的偏移（已乘 scale 并含轴修正；读取失败返回零向量）
]]
local function GetModelCenter(modelID, scale, fixAxis)
    scale = scale or 1
    if not PMXStaticImporter or not PMXStaticImporter.DataRoot then return Vector(0, 0, 0) end
    local json = file.Read(PMXStaticImporter.DataRoot .. "/" .. modelID .. "/manifest.json", "DATA")
    if not json then return Vector(0, 0, 0) end
    local manifest = util.JSONToTable(json)
    if not manifest or not manifest.bounds then return Vector(0, 0, 0) end
    local b = manifest.bounds
    local cx = (b.mins[1] + b.maxs[1]) / 2
    local cy = (b.mins[2] + b.maxs[2]) / 2
    local cz = (b.mins[3] + b.maxs[3]) / 2
    if fixAxis then
        -- 绕 x 轴 +90°（GMod pitch=-90）：y-up 竖立 → z-up 平躺，旋转公式 x'=x, y'=-z, z'=y
        return Vector(cx, -cz, cy) * scale
    end
    return Vector(cx, cy, cz) * scale
end

--[[
    合成实体角度：先应用 y-up 轴修正（绕 x -90°），再按卡牌角度旋转

    卡牌角度相对牌桌世界坐标；GMod Angle 不支持 Angle*Angle（__mul 仅接受 number），
    用 Matrix 旋转矩阵合成（mCard * mFix 先应用修正再应用卡牌角度）。

    @param cardAng Angle 卡牌角度（相对牌桌世界坐标）
    @param fixAng  Angle 轴修正角度（y-up 修正为 Angle(-90, 0, 0)）
    @return Angle 实体角度
]]
local function ComposeAngles(cardAng, fixAng)
    local mCard = Matrix()
    mCard:Rotate(cardAng)
    local mFix = Matrix()
    mFix:Rotate(fixAng)
    return (mCard * mFix):GetAngles()
end

--[[
    查找已导入模型：按关键词匹配 display_name / model_id，返回 model_id

    @param kind string 模型类别（"table" / "card"，见 ModelKeywords）
    @return string|nil, string|nil model_id / 错误信息
]]
function KARDS.BattleRender:FindModel(kind)
    if not IsImporterAvailable() then
        return nil, "前置模组未加载（PMXStaticImporter 不可用，请确认已订阅 workshop 3706539692）"
    end
    local keywords = ModelKeywords[kind]
    local list = PMXStaticImporter.ListAvailableModels()
    if not list or #list == 0 then
        return nil, "尚未导入任何模型（请先运行 PMXStaticImporter.exe 导入 GLB/GLTF）"
    end
    for _, entry in ipairs(list) do
        local hay = tostring(entry.display_name or "") .. " " .. tostring(entry.model_id or "")
        for _, kw in ipairs(keywords) do
            if hay:find(kw, 1, true) then
                return entry.model_id
            end
        end
    end
    return nil, "未找到匹配「" .. kind .. "」关键词的模型"
end

--[[
    打印已导入模型列表（控制台输出，模型未导入时提示导入步骤）
]]
function KARDS.BattleRender:PrintAvailableModels()
    if not IsImporterAvailable() then
        print("[KARDS BattleRender] 前置模组未加载（PMXStaticImporter 不可用）")
        return
    end
    local list = PMXStaticImporter.ListAvailableModels()
    if not list or #list == 0 then
        print("[KARDS BattleRender] 尚未导入任何模型（请先运行 PMXStaticImporter.exe 并选择模型文件夹导入）")
        return
    end
    print("[KARDS BattleRender] 已导入模型列表：")
    for _, entry in ipairs(list) do
        print(("  model_id=%s  display_name=%s  tris=%s"):format(
            tostring(entry.model_id), tostring(entry.display_name), tostring(entry.triangle_count)))
    end
end

--[[
    在指定位置生成牌桌实体

    @param tableID string|nil 牌桌标识（缺省 "default"）
    @param modelID string|nil 模型 ID（缺省按 "table" 关键词自动查找）
    @param scale   number|nil 缩放（缺省 Defaults.TableScale）
    @param pos     Vector|nil 位置（缺省原点 Vector(0,0,0)）
    @return Entity|nil, string|nil 实体 / 错误信息
]]
function KARDS.BattleRender:SpawnTable(tableID, modelID, scale, pos)
    tableID = tableID or self.Defaults.TableID
    scale = scale or self.Defaults.TableScale
    if not modelID then
        local err
        modelID, err = self:FindModel("table")
        if not modelID then
            self:PrintAvailableModels()
            return nil, err
        end
    end
    if not IsImporterAvailable() or not PMXStaticImporter.NormalizeModelID then
        return nil, "前置模组未加载（PMXStaticImporter 不可用）"
    end
    modelID = PMXStaticImporter.NormalizeModelID(modelID)
    if not modelID then
        return nil, "非法模型 ID"
    end
    if not SERVER then return nil, "仅服务端可创建实体（规划 D11 realm 纪律）" end
    local ent = ents.Create("sent_pmx_static_imported")
    if not IsValid(ent) then
        return nil, "创建实体失败（sent_pmx_static_imported）"
    end
    -- 按模型几何中心对齐目标位置（含运行缩放与 y-up 轴修正，见 GetModelCenter）
    local fix = self.Defaults.YUpToZUp
    local center = GetModelCenter(modelID, scale, fix)
    local targetPos = pos or Vector(0, 0, 0)
    ent:SetPos(targetPos - center)
    ent:SetAngles(fix and Angle(-90, 0, 0) or Angle(0, 0, 0))
    ent:Spawn()
    local ok, applyErr = ent:ApplyImportedModel(modelID, scale)
    if not ok then
        ent:Remove()
        return nil, applyErr
    end
    -- 清理同牌桌旧实体
    local old = self.TableEnts[tableID]
    if IsValid(old) then old:Remove() end
    self.TableEnts[tableID] = ent
    return ent
end

--[[
    生成卡牌实体并绑定到战斗卡牌对象（每帧采样 card.pos/ang 写入实体变换）

    @param tableID string|nil 牌桌标识（缺省 "default"）
    @param card    table 卡牌对象（须可写入 pos/ang 字段，缺省自动补齐 0）
    @param modelID string|nil 模型 ID（缺省按 "card" 关键词自动查找）
    @param scale   number|nil 缩放（缺省 Defaults.CardScale）
    @param pos     Vector|nil 初始位置（缺省读 card.pos）
    @param ang     Angle|nil  初始角度（缺省读 card.ang）
    @return Entity|nil, string|nil 实体 / 错误信息
]]
function KARDS.BattleRender:SpawnCard(tableID, card, modelID, scale, pos, ang)
    tableID = tableID or self.Defaults.TableID
    scale = scale or self.Defaults.CardScale
    if not card or type(card) ~= "table" then
        return nil, "卡牌对象无效"
    end
    if not modelID then
        local err
        modelID, err = self:FindModel("card")
        if not modelID then
            self:PrintAvailableModels()
            return nil, err
        end
    end
    if not IsImporterAvailable() or not PMXStaticImporter.NormalizeModelID then
        return nil, "前置模组未加载（PMXStaticImporter 不可用）"
    end
    modelID = PMXStaticImporter.NormalizeModelID(modelID)
    if not modelID then
        return nil, "非法模型 ID"
    end
    -- 3D 变换字段（缺省自动补齐 0，与 AnimateCard 行为一致）
    if not card.pos then card.pos = { x = 0, y = 0, z = 0 } end
    if not card.ang then card.ang = { p = 0, y = 0, r = 0 } end
    if not SERVER then return nil, "仅服务端可创建实体（规划 D11 realm 纪律）" end
    local ent = ents.Create("sent_pmx_static_imported")
    if not IsValid(ent) then
        return nil, "创建实体失败（sent_pmx_static_imported）"
    end
    local startPos = pos or Vector(card.pos.x, card.pos.y, card.pos.z)
    local startAng = ang or Angle(card.ang.p, card.ang.y, card.ang.r)
    -- 按模型几何中心对齐（basic_card 中心为原点无偏移；含运行缩放与 y-up 轴修正）
    local fix = self.Defaults.YUpToZUp
    local center = GetModelCenter(modelID, scale, fix)
    ent._kardsCenter = center -- Think 每帧写回需同款偏移
    ent:SetPos(startPos - center)
    ent:SetAngles(fix and ComposeAngles(startAng, Angle(-90, 0, 0)) or startAng)
    ent:Spawn()
    local ok, applyErr = ent:ApplyImportedModel(modelID, scale)
    if not ok then
        ent:Remove()
        return nil, applyErr
    end
    -- 视觉测试用：卡牌不参与碰撞（渲染由实体 Draw 完成，不受 SOLID 影响）
    ent:SetSolid(SOLID_NONE)
    -- 服务端：同步卡牌属性 NW 变量 + 广播 3D2D 文字叠加注册（客户端 cl_card_text_overlay.lua 接收）
    if SERVER and card then
        ent:SetNWString("Kards_CardName", tostring(card.GetName and card:GetName() or ""))
        ent:SetNWString("Kards_CardNameEn", tostring(card.GetNameEn and card:GetNameEn() or ""))
        ent:SetNWInt("Kards_CardCost", card.GetCost and card:GetCost() or 0)
        ent:SetNWInt("Kards_CardActionCost", card.GetActionCost and card:GetActionCost() or 0)
        ent:SetNWInt("Kards_CardAttack", (card.GetStat and card:GetStat("attack")) or 0)
        ent:SetNWInt("Kards_CardDefense", (card.GetStat and card:GetStat("defense")) or 0)
        -- 属性变更事件驱动同步（re.md B-M2）：注入可插拔观察者，卡牌攻击/防御变化时
        -- 直接更新 NW 变量（替代 Think 每帧增量同步）；实体销毁后回调经 IsValid 跳过
        if card.SetObserver then
            card:SetObserver(function(c, stat, modifier, amount, newValue)
                if not IsValid(ent) then return end
                if stat == "attack" then
                    ent:SetNWInt("Kards_CardAttack", newValue or 0)
                elseif stat == "defense" then
                    ent:SetNWInt("Kards_CardDefense", newValue or 0)
                end
            end)
        end
        ent:SetNWString("Kards_CardDescription", tostring(card.GetDescription and card:GetDescription() or ""))
        ent:SetNWString("Kards_CardDescriptionEn", tostring(card.GetDescriptionEn and card:GetDescriptionEn() or ""))
        ent:SetNWBool("Kards_CardIsCommand", (card.GetType and card:GetType()) == "command" or (card.GetType and card:GetType()) == "headquarter")
        ent:SetNWBool("Kards_CardIsHeadquarter", (card.GetType and card:GetType()) == "headquarter")
        -- 可见词条计数（次词条如海军不显示、不计入布局，见 KARDS.CardInterface.IsHiddenKeyword）
        local hasVisibleKw = false
        if card.GetKeywords then
            for _, kw in ipairs(card:GetKeywords() or {}) do
                local kwId = type(kw) == "table" and kw[1] or kw
                if not (KARDS.CardInterface and KARDS.CardInterface.IsHiddenKeyword and KARDS.CardInterface.IsHiddenKeyword(kwId)) then
                    hasVisibleKw = true
                    break
                end
            end
        end
        ent:SetNWBool("Kards_CardHasKeywords", hasVisibleKw)
        -- 词条同步串为词条 id（如 "blitz|intel:2"），客户端按本机语言重建显示文本
        -- （sh_card_data.lua SerializeKeywords / DeserializeKeywords）；不直接同步文本，
        -- 避免一条 NW 值只能容纳一种语言。
        ent:SetNWString("Kards_CardKeywords",
            (card.GetKeywords and KARDS.CardEditor and KARDS.CardEditor.Data
                and KARDS.CardEditor.Data.SerializeKeywords and KARDS.CardEditor.Data.SerializeKeywords(card:GetKeywords() or {}))
            or "")
        net.Start("KARDS_Battle_CardOverlayAdd")
        net.WriteEntity(ent)
        net.Broadcast()
    end
    -- 绑定映射（card → entity）
    self.CardEnts[tableID] = self.CardEnts[tableID] or {}
    self.CardEnts[tableID][card] = ent
    return ent
end

--[[
    移除指定牌桌的全部牌桌/卡牌实体，并恢复动画真实时间开关

    @param tableID string|nil 牌桌标识（缺省 "default"）
]]
function KARDS.BattleRender:Clear(tableID)
    tableID = tableID or self.Defaults.TableID
    local te = self.TableEnts[tableID]
    if IsValid(te) then te:Remove() end
    self.TableEnts[tableID] = nil
    local cards = self.CardEnts[tableID]
    if cards then
        for _, ent in pairs(cards) do
            if IsValid(ent) then ent:Remove() end
        end
    end
    self.CardEnts[tableID] = nil
    self.DemoState.cards = nil
    -- 清空本桌活跃动画（按 tableID 分表，不影响其他牌桌动画）并恢复动画系统
    -- 真实时间开关（演示开启过 RealTime=true）
    self.ActiveAnims[tableID] = nil
    if self._prevRealTime ~= nil then
        KARDS.Animation.RealTime = self._prevRealTime
        self._prevRealTime = nil
    end
end

--[[
    登记卡牌复用映射（手牌拖拽打出主路径，2026-08-10）

    拖拽中的手牌实体复用为战场卡时登记；下一次 CardEnter 事件（SimDeployFixed
    触发）被 spawnCard 拦截消费：不新建实体、不广播 overlay（客户端保留 AddLocal），
    仅设置战场卡 NW 字段。复用实体不进 CardEnts 位置驱动（客户端本地拥有变换，
    位置由客户端从 KardsFieldLayout 广播驱动）。

    @param tableID string 牌桌唯一标识符
    @param card    table  卡牌对象
    @param ent     Entity 复用的实体（拖拽中的手牌实体）
]]
function KARDS.BattleRender:ReuseCard(tableID, card, ent)
    if not tableID or not card or not IsValid(ent) then return false end
    self.ReuseEnts[tableID] = self.ReuseEnts[tableID] or {}
    self.ReuseEnts[tableID][card] = ent
    return true
end

-- 清除卡牌复用映射（部署失败回退 / 对局结束清理；幂等）
function KARDS.BattleRender:Unreuse(tableID, card)
    if not tableID or not card then return end
    local map = self.ReuseEnts[tableID]
    if map then map[card] = nil end
end

--[[
    生成另一战场卡实体（预留占位，2026-08-10）

    未来部署动画过半时切换为更简单、更聚焦重要属性的战场模型（用户计划给在场
    单位一个单独卡牌模型，更长/更短另行建模）时实现：以复用实体的 SpawnCard
    替代入口生成新实体并移交 CardEnts 绑定。本次返回 nil（未实现，仅占位）。
]]
function KARDS.BattleRender:CreateBattleCardEntity(tableID, card)
    -- TODO(2026-08-10): 部署动画过半切换简单战场模型时实现（本次复用实体，未启用）
    print("[BattleRender] CreateBattleCardEntity 未实现（当前复用拖拽实体为战场卡）")
    return nil
end

--[[
    绑定战斗事件到渲染层（渲染事件驱动接缝，re.md 三 / B-M3）

    订阅注册式效果框架的 CardEnter / CardLeave 事件（见 sh_effect_registry.lua）：
      CardEnter  进入战场 → SpawnCard 生成实体并绑定 card → 实体
      CardLeave  离开战场 → 摘除 CardEnts 中该卡绑定实体；载荷 reason == "death"
                 时延迟 FieldDeathRemoveDelay 秒销毁实体，其余立即销毁
    由牌桌在 StartBattle 后调用（BindBattleEvents(tableID)），实现「渲染表生命周期
    集中管理」——战斗系统只负责触发事件，渲染层自取所需。订阅条目随 StartBattle 的
    EffectRegistry.Clear(tableID) 一并清理（同牌桌重复调用幂等，同 ID 覆盖）。

    @param tableID   string 牌桌唯一标识符
    @param spawnOpts table|nil 传给 SpawnCard 的附加参数（modelID / scale / pos / ang；
                缺省时 SpawnCard 按 card.pos/ang 与 "card" 关键词自动查找模型）
]]
function KARDS.BattleRender:BindBattleEvents(tableID, spawnOpts)
    if not tableID then return end
    local function spawnCard(card)
        if not card then return end
        -- 复用拦截（手牌拖拽打出）：复用实体已登记 → 不新建实体、不广播 overlay，
        -- 仅设置战场卡 NW 字段；一次性消费映射
        local reuse = self.ReuseEnts[tableID] and self.ReuseEnts[tableID][card]
        if reuse then
            self.ReuseEnts[tableID][card] = nil
            if IsValid(reuse) then
                -- SetNW 仅服务端有效（realm 门控 2026-08-18 规划 D11）；本分支由
                -- CardEnter 事件驱动（服务端数据层），客户端不会进入
                if SERVER then
                    reuse:SetNWBool("Kards_IsFieldCard", true)
                    reuse:SetNWInt("Kards_DeckSlot",
                        (card.GetOwner and card:GetOwner() == "P2") and 2 or 1)
                    local ctype = card.GetType and card:GetType() or ""
                    reuse:SetNWBool("Kards_CardIsCommand",
                        ctype == "command" or ctype == "headquarter")
                    -- 攻击/防御/花费 NW（未来 overlay AddEntity 用；复用卡当前走 AddLocal，
                    -- 同步无副作用，亦供敌方客户端朝向/属性展示）
                    reuse:SetNWInt("Kards_CardAttack", (card.GetStat and card:GetStat("attack")) or 0)
                    reuse:SetNWInt("Kards_CardDefense", (card.GetStat and card:GetStat("defense")) or 0)
                    reuse:SetNWInt("Kards_CardCost", (card.GetCost and card:GetCost()) or 0)
                    reuse:SetNWInt("Kards_CardActionCost", (card.GetActionCost and card:GetActionCost()) or 0)
                end
            end
            return
        end
        self.CardEnts[tableID] = self.CardEnts[tableID] or {}
        if self.CardEnts[tableID][card] then return end -- 已在场（避免重复绑定）
        self:SpawnCard(tableID, card,
            spawnOpts and spawnOpts.modelID, spawnOpts and spawnOpts.scale,
            spawnOpts and spawnOpts.pos, spawnOpts and spawnOpts.ang)
    end
    -- 离场移除（2026-09-26 缺口 C）：载荷携带 reason（SimRemoveFromField 传 "death"
    -- / "remove"，SimRetreat 传 "retreat"，SimReturnToHand 传 "return_to_hand"）。
    -- 阵亡走延迟销毁（测试版无死亡特效，延 1 秒便于观察）；其余立即销毁。
    -- 无论哪条路径都先摘除 CardEnts 映射：延迟闭包持有旧实体引用，若同卡在这 1 秒内
    -- 重新入场并新建实体，旧实体的延迟销毁不会误伤新实体。
    local function removeCard(payload)
        local card = (type(payload) == "table") and payload.card or payload
        local reason = (type(payload) == "table") and payload.reason or nil
        local ents = self.CardEnts[tableID]
        local ent = ents and ents[card]
        if ents then ents[card] = nil end
        if not IsValid(ent) then return end
        if reason == "death" then
            local delay = self.FieldDeathRemoveDelay
            timer.Simple(delay, function()
                if IsValid(ent) then ent:Remove() end
            end)
        else
            ent:Remove()
        end
    end
    KARDS.EffectRegistry.Register(tableID, KARDS.EffectRegistry.EVENTS.CardEnter,
        "render_card_enter", { handler = function(payload) spawnCard(payload.card) end })
    KARDS.EffectRegistry.Register(tableID, KARDS.EffectRegistry.EVENTS.CardLeave,
        "render_card_leave", { handler = function(payload) removeCard(payload) end })
end

--[[
    2D 网格移动动画：将卡牌平滑移至指定网格格（列 1~5 × 行 P1=+1 / 前线=0 / P2=-1）

    建立拟 2D 布局坐标系（KARDS.Animation.Board2D，sh_animation.lua）与战斗系统
    动画驱动的联系：Board2D:MoveTo 按网格坐标计算目标世界坐标并创建 pos.x / pos.y
    渐变动画，本函数将其注册进 ActiveAnims——Think 钩子（kards_battle_render_drive）
    每帧 ApplyNow 驱动（真实时间模式按秒渐变，写回 card.pos/ang 后同步卡牌实体变换）。

    @param tableID string 牌桌标识（缺省 Defaults.TableID）
    @param card    table 卡牌对象（携带 pos/ang 字段）
    @param col     number 目标列号 1~5
    @param row     number 目标行号 +1（P1）/ 0（前线）/ -1（P2）
    @param seconds number 时长（秒，必须 > 0）
    @param easing  string|function|nil 曲线（缺省 "smooth"）
    @return table|nil { x, y } 两个轴动画对象（已注册 ActiveAnims）；网格越界 /
            牌桌未生成返回 nil
]]
function KARDS.BattleRender:MoveCardTo(tableID, card, col, row, seconds, easing)
    tableID = tableID or self.Defaults.TableID
    local tableEnt = self.TableEnts[tableID]
    if not IsValid(tableEnt) then return nil end
    local anims = KARDS.Animation.Board2D:MoveTo(card, tableEnt, col, row, seconds, easing)
    if not anims then return nil end
    local active = self.ActiveAnims[tableID] or {}
    self.ActiveAnims[tableID] = active
    if anims.x then active[anims.x] = true end
    if anims.y then active[anims.y] = true end
    return anims
end

--[[
    一键演示：牌桌 + 6 张卡 发牌 → 第 3 张放置桌面 → 第 5 张移除动画

    演示流程（真实时间模式，RealTime=true）：
      1. 牌库区（deck，x=40）6 张卡堆叠
      2. 每 0.3s 错峰发牌到手上扇形（hand，x=-40，y 扇形展开），单张 0.6s 平滑
      3. 发牌结束后第 3 张 0.8s 平滑放置桌面（table，x=0 y=0 z=12.5 桌面高度，平放面朝上）
      4. 第 5 张执行移除动画组（CreateRemovalAnimations：升 z → 等待 → 左移出场 + 翻转）
      5. 广播相机预设视角（kards_camera table 俯瞰）

    @param cardScale  number|nil 卡牌缩放（缺省 Defaults.CardScale）
    @param tableScale number|nil 牌桌缩放（缺省 Defaults.TableScale）
    @return boolean 是否成功启动演示
]]
function KARDS.BattleRender:RunDemo(cardScale, tableScale)
    self:Clear(self.Defaults.TableID)
    cardScale = cardScale or self.Defaults.CardScale
    tableScale = tableScale or self.Defaults.TableScale

    local tableEnt, tableErr = self:SpawnTable(self.Defaults.TableID, nil, tableScale)
    if not tableEnt then
        print("[KARDS BattleRender] 牌桌生成失败: " .. tostring(tableErr))
        return false
    end
    local cardModel, cardErr = self:FindModel("card")
    if not cardModel then
        print("[KARDS BattleRender] 卡牌模型未找到: " .. tostring(cardErr))
        self:PrintAvailableModels()
        return false
    end

    -- 记录并开启真实时间动画（演示结束 / Clear 时恢复）
    self._prevRealTime = KARDS.Animation.RealTime
    KARDS.Animation.RealTime = true

    -- 本桌活跃动画表（ActiveAnims 按 tableID 分表，演示注册到默认桌）
    local active = self.ActiveAnims[self.Defaults.TableID] or {}
    self.ActiveAnims[self.Defaults.TableID] = active
    local anims = active
    local count = 6
    local cards = {}
    -- 牌库区（deck）堆叠起点：x=40，z 逐张抬高 0.5 避免穿模
    for i = 1, count do
        local card = KARDS.CardInterface.CreateMockCard("demo_card_" .. i, "unit", "p1", {
            attack = 1, defense = 1, unitType = "infantry",
        })
        card.pos = { x = 40, y = 0, z = 30 + 0.5 * i }
        card.ang = { p = 0, y = 0, r = 0 }
        local ent, spawnErr = self:SpawnCard(self.Defaults.TableID, card, cardModel, cardScale)
        if not ent then
            print("[KARDS BattleRender] 卡牌实体生成失败: " .. tostring(spawnErr))
            return false
        end
        cards[i] = card
    end
    self.DemoState.cards = cards

    -- 发牌动画：每张延迟 (i-1)*0.3s，单张 0.6s 平滑 从牌库 → 手上扇形
    for i, card in ipairs(cards) do
        local delay = (i - 1) * 0.3
        local handY = -15 + (i - 1) * 6 -- 手上扇形：y 从 -15 到 +15 展开
        local function deal(axis, target)
            local a = KARDS.Animation:AnimateCard(card, 0.6, axis, "smooth", "to", target)
            a.delay = delay
            anims[a] = true
            return a
        end
        deal("pos.x", -40)
        deal("pos.y", handY)
        deal("pos.z", 30)
    end

    -- 发牌结束（5*0.3 + 0.6 = 2.1s）后，第 3 张 0.8s 平滑移至战场前线第 3 列
    -- （经拟 2D 布局坐标系 Board2D → BattleRender:MoveCardTo 注册 ActiveAnims：
    -- 目标位置取实测 2D 网格坐标——前线 row=0 第 3 列，z 恒为桌面顶 CardZ=18.43）
    local placeDelay = 2.2
    local c3 = cards[3]
    if c3 then
        local anims2d = self:MoveCardTo(self.Defaults.TableID, c3, 3, 0, 0.8)
        if anims2d then
            for _, a in pairs(anims2d) do
                if a then a.delay = (a.delay or 0) + placeDelay end
            end
        end
    end

    -- 第 5 张执行移除动画组（Kards 语义移除）：升 z → 等待 → 左移出场 + 翻转
    local c5 = cards[5]
    if c5 then
        local removalDelay = placeDelay + 0.8 + 0.3 -- 放置结束后 0.3s
        local removal = KARDS.Animation:CreateRemovalAnimations(c5, 10, -60)
        if removal then
            for _, a in pairs(removal) do
                a.delay = (a.delay or 0) + removalDelay
                anims[a] = true
            end
        end
    end

    print("[KARDS BattleRender] 演示已启动：牌桌 + " .. count .. " 张卡（发牌 → 放置 → 移除）")
    print("[KARDS BattleRender] 输入 kards_battle_clear 清理；kards_camera 可调整视角")

    -- 广播相机预设视角（table 俯瞰）给所有客户端
    if SERVER then
        net.Start("KARDS_Battle_CamPreset")
        net.WriteString("table")
        net.Broadcast()
    end
    return true
end

-- 每帧驱动：活跃动画采样（ApplyNow 写回 card.pos/ang）→ 同步卡牌实体变换
hook.Add("Think", "kards_battle_render_drive", function()
    if not SERVER then return end -- realm 门控（2026-08-18 规划 D11）：实体创建/SetPos/SetAngles
    -- 为服务端权威，客户端 CardEnts/ActiveAnims 均为空表（无本地注册），跳过整个钩子
    local BR = KARDS.BattleRender
    -- 1. 驱动活跃动画（真实时间模式下 ApplyNow 按秒渐变，写回 card.pos/ang；
    --    ActiveAnims 按 tableID 分表，遍历全部牌桌的动画）
    for _, anims in pairs(BR.ActiveAnims) do
        for anim in pairs(anims) do
            if anim and anim.ApplyNow then
                anim:ApplyNow()
            end
        end
    end
    -- 2. 采样 card.pos/ang（相对牌桌世界坐标，牌桌位于原点）写入实体变换
    for tableID, cards in pairs(BR.CardEnts) do
        for card, ent in pairs(cards) do
            if IsValid(ent) and card.pos and card.ang then
                -- 位置减几何中心偏移（SpawnCard 存于 ent._kardsCenter），角度叠加 y-up 轴修正
                local center = ent._kardsCenter or Vector(0, 0, 0)
                ent:SetPos(Vector(card.pos.x, card.pos.y, card.pos.z) - center)
                local ang = Angle(card.ang.p, card.ang.y, card.ang.r)
                ent:SetAngles(BR.Defaults.YUpToZUp and ComposeAngles(ang, Angle(-90, 0, 0)) or ang)
                -- 卡牌攻击/防御 NW 同步已事件驱动（re.md B-M2）：SpawnCard 注入的
                -- 可插拔观察者（SetObserver）在 ApplyChange 时直接更新 NW 变量，
                -- 不再每帧采样比对（3D2D 文字叠加读取的 Kards_CardAttack/Kards_CardDefense）
            end
        end
    end
end)

-- 服务端：注册网络消息与控制台命令
if SERVER then
    util.AddNetworkString("KARDS_Battle_CamPreset")
    -- 战场卡牌 3D2D 文字叠加：实体生成广播（客户端 cl_card_text_overlay.lua 接收注册）
    util.AddNetworkString("KARDS_Battle_CardOverlayAdd")

    -- 开发命令权限：服务器控制台（ply 无效）放行，玩家需 operator 及以上，
    -- 判定见 init.lua 的 KARDS.CanUseDevCommand
    local function denied(ply, name)
        if KARDS.CanUseDevCommand(ply) then return false end
        print(("[KARDS BattleRender] %s：需要 operator 及以上权限"):format(name))
        return true
    end

    concommand.Add("kards_battle_list", function(ply)
        if denied(ply, "kards_battle_list") then return end
        KARDS.BattleRender:PrintAvailableModels()
    end)

    concommand.Add("kards_battle_table", function(ply, cmd, args)
        if denied(ply, "kards_battle_table") then return end
        local scale = tonumber(args[1]) or KARDS.BattleRender.Defaults.TableScale
        local modelID = args[2]
        local ent, err = KARDS.BattleRender:SpawnTable(KARDS.BattleRender.Defaults.TableID, modelID, scale)
        if ent then
            print("[KARDS BattleRender] 牌桌已生成（scale=" .. scale .. "，modelID=" .. tostring(modelID or "自动") .. "）")
        else
            print("[KARDS BattleRender] 牌桌生成失败: " .. tostring(err))
        end
    end)

    concommand.Add("kards_battle_clear", function(ply)
        if denied(ply, "kards_battle_clear") then return end
        KARDS.BattleRender:Clear(KARDS.BattleRender.Defaults.TableID)
        print("[KARDS BattleRender] 已清理牌桌与卡牌实体")
    end)

    concommand.Add("kards_battle_demo", function(ply, cmd, args)
        if denied(ply, "kards_battle_demo") then return end
        local cardScale = tonumber(args[1]) or KARDS.BattleRender.Defaults.CardScale
        local tableScale = tonumber(args[2]) or KARDS.BattleRender.Defaults.TableScale
        KARDS.BattleRender:RunDemo(cardScale, tableScale)
    end)
end

-- 客户端：接收相机预设广播并应用（复用 BattleCamera:SetPreset）
if CLIENT then
    net.Receive("KARDS_Battle_CamPreset", function()
        local name = net.ReadString()
        if KARDS.BattleCamera and KARDS.BattleCamera.SetPreset then
            KARDS.BattleCamera:SetPreset(LocalPlayer(), name)
            print("[KARDS BattleRender] 相机预设视角: " .. tostring(name))
        end
    end)
end
