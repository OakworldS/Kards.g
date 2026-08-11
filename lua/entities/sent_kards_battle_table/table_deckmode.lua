-- Kards 战斗牌桌实体服务端代码：组卡模式段（re.md T-H1 拆分，由 init.lua include）
-- 职责：组卡/对战模式切换、卡牌平铺（5×3 网格）、卡组堆叠（加入/移除/计数/翻面）、
-- 卡组存档保存、组卡卡牌实体与轻量卡牌对象构造。
-- 跨文件共享的 ENT 方法 helper（DeckSafeName / DeckPlayerFileName / EnsureDeckManifest）
-- 亦定义于此（battledeck 段通过 self:xxx 调用）。

local ENT = scripted_ents.GetStored("sent_kards_battle_table").t

-- ====================================================================
-- net 消息注册（SERVER 段）：组卡点击 / 保存 / 模式切换
-- ====================================================================
if SERVER then
    -- 组卡构建点击：网格卡（非总部）→ 复制加入卡组；卡组堆叠卡 → 移回销毁并重排
    net.Receive("KardsDeckCardClick", function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) then return end
        local data = ply._kardsTable
        if not data or not IsValid(data.ent) then return end
        local tableEnt = data.ent
        if tableEnt.Mode ~= "deck" then return end
        if data.slot ~= 2 then return end -- 仅 P2（槽位 2）可构建卡组
        -- 网格卡（非总部）→ 加入卡组；已翻面（达携带上限）的网格卡禁止继续加入
        for _, entry in ipairs(tableEnt._kardsDeckCards or {}) do
            if entry.ent == ent then
                if not ent:GetNWBool("Kards_CardIsHeadquarter", false)
                and not ent:GetNWBool("Kards_GridFlipped", false) then
                    tableEnt:DeckAddToPile(entry)
                end
                return
            end
        end
        -- 卡组堆叠卡 → 移回（副本销毁），后续卡重排；总部（isHQ）不可移出
        for _, entry in ipairs(tableEnt._kardsDeckPile or {}) do
            if entry.ent == ent and not entry.isHQ then
                tableEnt:DeckRemoveFromPile(entry)
                return
            end
        end
    end)

    -- 组卡保存：P2 点击"保存"按钮输入卡组名 → 校验满 40 张（总部算 1 张）→ 覆盖写入单卡组文件
    net.Receive("KardsDeckSave", function(_, ply)
        local name = net.ReadString()
        local data = ply._kardsTable
        if not data or not IsValid(data.ent) then return end
        local tableEnt = data.ent
        if tableEnt.Mode ~= "deck" then return end
        if data.slot ~= 2 then return end -- 仅 P2（构建者）可保存
        name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then
            net.Start("KardsTableMsg") net.WriteString("卡组名不能为空") net.Send(ply)
            return
        end
        -- 汇总卡组数据：总部（pile[1]）+ 普通卡（fileName → count）
        local hqFile = nil
        local nameByModel = {} -- modelID → fileName（网格卡映射，modelID 的 safeName 不可逆）
        for _, g in ipairs(tableEnt._kardsDeckCards or {}) do
            nameByModel[g.modelID] = g.card:GetID()
        end
        local cards = {}
        local total = 0
        local pile = tableEnt._kardsDeckPile or {}
        if pile[1] and pile[1].isHQ then
            hqFile = pile[1].card:GetID()
            total = total + 1
        end
        for modelID, count in pairs(tableEnt._kardsDeckCounts or {}) do
            local fn = nameByModel[modelID]
            if fn and count > 0 then
                cards[#cards + 1] = { fileName = fn, count = count }
                total = total + count
            end
        end
        if total ~= 40 then
            net.Start("KardsTableMsg") net.WriteString(("卡组需满 40 张（总部算 1 张），当前 %d 张"):format(total)) net.Send(ply)
            return
        end
        -- 按玩家分文件保存：每位玩家拥有自己的卡组存档（文件名 = SteamID 安全化），
        -- 不同玩家保存互不覆盖（战斗系统按 fileName 重建句柄喂给 SimSetupDeck）
        local deckFileName = tableEnt:DeckPlayerFileName(ply)
        file.CreateDir("card_editor/decks")
        local ok, err = file.Write("card_editor/decks/" .. deckFileName, util.TableToJSON({
            name = name,
            owner = ply:Nick(),
            steamID = ply:SteamID(),
            savedAt = os.time(),
            hq = hqFile,
            cards = cards,
            total = total,
        }, true))
        if ok then
            -- B-M4：卡组已保存，句柄缓存失效（同卡再进出对局按最新文件重建句柄）
            if KARDS.CardHandleCache and KARDS.CardHandleCache.InvalidateAll then
                KARDS.CardHandleCache.InvalidateAll()
            end
            net.Start("KardsTableMsg") net.WriteString(("卡组「%s」已保存（%d 张）"):format(name, total)) net.Send(ply)
            print(("[Kards] 卡组保存: %s（%d 张，归属 %s）"):format(name, total, deckFileName))
        else
            net.Start("KardsTableMsg") net.WriteString("卡组保存失败: " .. tostring(err)) net.Send(ply)
        end
    end)

    net.Receive("KardsTableToggleMode", function(_, ply)
        local ent = net.ReadEntity()
        if IsValid(ent) and ent:GetClass() == "sent_kards_battle_table" then
            ent:ToggleMode(ply)
        end
    end)
end

-- ====================================================================
-- 组卡模式 helper（ENT 方法，跨文件共享；battledeck 段同样调用）
-- ====================================================================

-- 卡牌文件名 → 安全标识（与客户端 GetCardMaterial 同款规范化，两端推导一致）
function ENT:DeckSafeName(fileName)
    local name = tostring(fileName or ""):gsub("%.json$", "")
    name = string.gsub(name, "[^%w]", "_")
    name = string.gsub(name, "%s+", "_")
    name = string.gsub(name, "^_+", "")
    name = string.gsub(name, "_+$", "")
    if name == "" then name = "unnamed" end
    return name
end

-- 卡组存档文件名（按玩家区分）：SteamID（如 STEAM_0:1:12345）中非文件名字符替换为 _
-- （Windows 文件名不允许 ':' 等字符），保证每位玩家拥有独立的卡组存档、互不覆盖。
-- SteamID 获取失败时回退 UserID（本会话内唯一）。
function ENT:DeckPlayerFileName(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return "unknown.json" end
    local sid = ply:SteamID()
    if sid == "" or not sid then sid = tostring(ply:UserID()) end
    return string.gsub(sid, "[^%w]", "_") .. ".json"
end

-- ====================================================================
-- 牌桌模式切换（组卡 deck / 对战 battle）
-- ====================================================================

--[[
    切换牌桌模式（组卡 ↔ 对战）：服务端权威，仅宽面（x 侧，shared.lua IsAtWideSide）
    玩家可触发（客户端 kards_enter 在宽面发送 KardsTableToggleMode 请求）。
    切到组卡：加载玩家已保存卡牌平铺桌面（5×3 网格）；切回对战：清空组卡卡牌。
    模式经 NW 变量 Kards_Mode 同步客户端（宽面提示 / 组卡浏览面板读取）。

    @param ply Player 请求玩家（服务端校验其位于宽面）
]]
function ENT:ToggleMode(ply)
    if not IsValid(ply) then return end
    if not self:IsAtWideSide(ply) then return end
    local newMode = (self.Mode == "battle") and "deck" or "battle"
    self.Mode = newMode
    self:SetNWString("Kards_Mode", newMode)
    if newMode == "deck" then
        self:EnterDeckMode(ply)
    else
        self:ExitDeckMode()
    end
    net.Start("KardsTableModeChanged")
        net.WriteEntity(self)
        net.WriteString(newMode)
    net.Broadcast()
    print(("[Kards] 牌桌 %s 切换模式：%s"):format(self.TableID, newMode))
end

--[[
    进入组卡模式：把玩家已保存卡牌平铺在桌面上（拟 2D 网格 5×3，桌面顶中心居中）。
    卡牌实体与编辑器「生成3D2D卡牌」同链路：实体经牌桌子物体系统 RegisterChild 绑定
    牌桌为父级、SetLocalPos 相对坐标定位（随牌桌移动/旋转相对桌面不变），相对角度
    (0,0,0) 平躺面朝上（basic_card 经导入器转轴为 z-up 平躺，无需 y-up 轴修正——
    SpawnCard 的 ComposeAngles(-90) 会把卡竖起来，故不走 SpawnCard），SOLID_NONE
    无碰撞、物理冻结无运动；每张卡用独立 modelID 副本（image_path 无卡牌维度，批量
    多卡需分 modelID 才能各自显示卡面/卡背），客户端复制贴图落盘后由前置模组按
    image_path 加载，并绑定 3D2D 文字（cl_init.lua 组卡卡牌材质初始化）。
    实体与卡牌对象存 self._kardsDeckCards（退出组卡 / 牌桌销毁时统一移除）。

    @param ply Player 请求玩家（当前仅用于日志）
]]
function ENT:EnterDeckMode(ply)
    self:ExitDeckMode()
    if not KARDS.BattleRender or not KARDS.Animation or not KARDS.Animation.Board2D then
        print("[Kards] 组卡模式失败：BattleRender / Board2D 未加载")
        return
    end
    if not KARDS.CardEditor or not KARDS.CardEditor.SaveSystem then
        print("[Kards] 组卡模式失败：卡牌保存系统未加载")
        return
    end
    local infos = KARDS.CardEditor.SaveSystem.GetAllCardsInfo() or {}
    local rows = { -1, 0, 1 } -- 2D 网格行：P2(-1) / 前线(0) / P1(+1)
    local cards = {}
    local maxSlots = 15 -- 测试版：5×3 网格最多铺 15 张
    -- 拆分：第一张总部卡 → 卡组第一张；其余（非总部）→ 5×3 网格
    local hqInfo = nil
    local gridIndex = 0
    for i = 1, #infos do
        local info = infos[i] -- { fileName, name, savedAt, cardAppearance }
        -- 用只读的 GetCardInfo（禁用编辑器 LoadCard：它会写回 KARDS.CardEditor.Canvas，
        -- 编辑器未打开时 Canvas 为 nil 报错）；cardAppearance 已含卡头全部字段
        if info and info.cardAppearance then
            if info.cardAppearance.cardType == "headquarter" then
                -- 总部卡：仅取第一张作为卡组第一张总部，不占 5×3 网格
                if not hqInfo then hqInfo = info end
            elseif gridIndex < maxSlots then
                gridIndex = gridIndex + 1
                local card = self:_CreateDeckCard(info)
                local col = (gridIndex - 1) % 5 + 1
                local row = rows[math.floor((gridIndex - 1) / 5) + 1]
                -- 2D 网格坐标（牌桌局部）→ 相对坐标（子物体系统：SetParent + SetLocalPos，
                -- card.pos 即牌桌相对坐标，随牌桌位置/朝向）
                local relPos = KARDS.Animation.Board2D:RelPos(col, row)
                card.pos = { x = relPos.x, y = relPos.y, z = relPos.z }
                card.ang = { p = 0, y = 0, r = 0 } -- 平躺面朝上（相对牌桌局部朝向）
                -- 每张卡独立模型副本（先确保 manifest 存在于 data，供 ApplyImportedModel 读取）
                local safeName = self:DeckSafeName(info.fileName)
                local modelID = "kards_deck_" .. safeName
                if not KARDS.CardManifest.EnsureDeck(modelID, safeName) then
                    print("[Kards] 组卡卡牌模型副本创建失败: " .. modelID)
                end
                local ent, err = self:SpawnDeckCardEntity(card, modelID, relPos)
                if IsValid(ent) then
                    -- 接入牌桌子物体系统：RegisterChild 将卡牌 SetParent 绑定牌桌 + 相对坐标
                    -- 定位（移动/旋转牌桌时卡牌相对桌面不变）；注册失败则移除该卡
                    if self._kardsChildSystem and self._kardsChildSystem:RegisterChild(ent, relPos) then
                        cards[#cards + 1] = { card = card, ent = ent, relPos = relPos, modelID = modelID }
                    else
                        ent:Remove()
                        print("[Kards] 组卡模式子物体注册失败: " .. modelID)
                    end
                else
                    print("[Kards] 组卡模式铺卡失败: " .. tostring(err))
                end
            end
        end
    end
    -- 卡组第一张 = 总部（卡组内第一张始终是总部，暂时使用第一个保存的总部卡；
    -- 原「总部槽」展示已取消，总部仅作为卡组堆叠第一张存在）
    local pileHQ = nil
    if hqInfo then
        local card = self:_CreateDeckCard(hqInfo)
        local safeName = self:DeckSafeName(hqInfo.fileName)
        -- 总部 modelID 带 hq_ 前缀，manifest 的 safeName 同步带 hq_ 前缀：
        -- 客户端 DeckInitCard 从 modelID 提取 safeName（hq_xxx）复制贴图到同一目录
        local modelID = "kards_deck_hq_" .. safeName
        if not KARDS.CardManifest.EnsureDeck(modelID, "hq_" .. safeName) then
            print("[Kards] 总部卡模型副本创建失败: " .. modelID)
        end
        -- 卡组第一张 = 总部（堆叠第 1 位；role=hq 客户端点击跳过，不可移出）
        local pilePos = self:DeckPileRelPos(1)
        local pent, perr = self:SpawnDeckCardEntity(card, modelID, pilePos)
        if IsValid(pent) then
            pent:SetNWString("Kards_DeckRole", "hq")
            pent:SetNWInt("Kards_PileCount", 0)
            if self._kardsChildSystem and self._kardsChildSystem:RegisterChild(pent, pilePos) then
                pileHQ = { card = card, ent = pent, srcEntry = nil, modelID = modelID, isHQ = true }
            else
                pent:Remove()
                print("[Kards] 卡组总部卡子物体注册失败: " .. modelID)
            end
        else
            print("[Kards] 卡组总部卡放置失败: " .. tostring(perr))
        end
    end
    self._kardsDeckCards = cards
    self._kardsDeckPile = {}
    if pileHQ then self._kardsDeckPile[1] = pileHQ end -- 卡组第一张始终是总部（不占网格）
    self._kardsDeckCounts = {} -- 卡组各卡携带数量（modelID → 总数，品质上限判定）
    print(("[Kards] 组卡模式：铺 %d/%d 张卡（5×3 网格）+ 总部 1 张"):format(#cards, math.min(#infos, maxSlots)))
end

--[[
    生成单张组卡卡牌实体（与编辑器「生成3D2D卡牌」同链路，无物理无碰撞）：
    直接应用模型副本 modelID（z-up 平躺 → 相对牌桌局部角度 (0,0,0) 即平躺，不走
    SpawnCard 的 y-up 轴修正），SOLID_NONE 无碰撞（准星浏览用 HitPos 距离判定），
    物理冻结无运动；NW 同步卡头属性（名称/费用/攻防/词条/描述）+ 模型副本标识 +
    组卡标记，客户端据此复制卡面/卡背贴图落盘（前置模组按 image_path 加载）并绑定
    3D2D 文字叠加。实体随后由 EnterDeckMode 经牌桌子物体系统 RegisterChild 绑定
    牌桌为父级（相对坐标定位，随牌桌移动/旋转）。

    @param card    table 组卡卡牌对象（pos/ang 为牌桌相对坐标 + Card Interface 方法）
    @param modelID string 卡牌模型副本标识（kards_deck_<safeName>）
    @param relPos  Vector 相对坐标（牌桌局部，z = 桌面顶）
    @return Entity|nil, string|nil 实体 / 错误信息
]]
function ENT:SpawnDeckCardEntity(card, modelID, relPos)
    if not card or not relPos then return nil, "卡牌对象/相对坐标无效" end
    if not PMXStaticImporter or not PMXStaticImporter.NormalizeModelID then
        return nil, "前置模组未加载（PMXStaticImporter 不可用）"
    end
    local ent = ents.Create("sent_pmx_static_imported")
    if not IsValid(ent) then return nil, "创建实体失败（sent_pmx_static_imported）" end
    -- 初始世界位置/朝向 = 相对坐标经牌桌换算（随后 EnterDeckMode 经子物体系统
    -- RegisterChild 转为 SetParent + SetLocalPos 相对定位；此初始值保证生成即落位无跳变）
    ent:SetPos(self:LocalToWorld(relPos))
    ent:SetAngles(self:LocalToWorldAngles(Angle(0, 0, 0)))
    ent:Spawn()
    local ok, applyErr = ent:ApplyImportedModel(modelID, KARDS.BattleRender.Defaults.CardScale)
    if not ok then
        ent:Remove()
        return nil, applyErr or "模型应用失败"
    end
    -- 无碰撞无物理：SOLID_NONE（射线不命中，准星落点 HitPos 最近距离判定选中）；
    -- ApplyImportedModel 已冻结运动，显式再冻结一次保证无物理运动
    ent:SetSolid(SOLID_NONE)
    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    -- NW 同步卡头属性（客户端：材质渲染数据源 + 3D2D 文字叠加；无本地卡文件时回退
    -- Overlay:AddEntity 从 NW 读取）
    ent:SetNWString("Kards_CardName", card:GetName())
    ent:SetNWString("Kards_DeckModelID", modelID)
    ent:SetNWInt("Kards_CardCost", card:GetCost() or 0)
    ent:SetNWInt("Kards_CardActionCost", card:GetActionCost() or 0)
    ent:SetNWInt("Kards_CardAttack", card:GetStat("attack") or 0)
    ent:SetNWInt("Kards_CardDefense", card:GetStat("defense") or 0)
    ent:SetNWString("Kards_CardDescription", (card.GetDescription and card:GetDescription()) or "")
    ent:SetNWBool("Kards_CardIsCommand", card:GetType() == "command" or card:GetType() == "headquarter")
    ent:SetNWBool("Kards_CardIsHeadquarter", card:GetType() == "headquarter")
    local kws = card:GetKeywords() or {}
    ent:SetNWBool("Kards_CardHasKeywords", #kws > 0)
    ent:SetNWString("Kards_CardKeywords",
        (KARDS.CardEditor.Data and KARDS.CardEditor.Data.BuildKeywordsText
            and KARDS.CardEditor.Data.BuildKeywordsText(kws)) or "")
    ent:SetNWString("Kards_CardRole", "deck") -- 卡牌大类枚举（re.md T-M1）：deck 组卡卡牌 / battledeck 卡组槽卡；组卡材质钩子据此分流
    ent:SetNWString("Kards_DeckRole", "grid") -- 角色：grid 网格卡 / hq 总部卡 / pile 卡组堆叠卡
    return ent
end

--[[
    退出组卡模式：移除全部组卡卡牌实体并清空对应渲染表（幂等，OnRemove 兜底调用）
]]
function ENT:ExitDeckMode()
    if not self._kardsDeckCards then return end
    for _, entry in ipairs(self._kardsDeckCards) do
        if IsValid(entry.ent) then
            entry.ent:Remove()
        end
    end
    self._kardsDeckCards = nil
    -- 卡组堆叠
    for _, e in ipairs(self._kardsDeckPile or {}) do
        if IsValid(e.ent) then e.ent:Remove() end
    end
    self._kardsDeckPile = nil
    self._kardsDeckCounts = nil
    if KARDS.BattleRender and self._kardsDeckTableID then
        KARDS.BattleRender:Clear(self._kardsDeckTableID)
    end
end

--[[
    从卡牌文件信息构造组卡卡牌对象（轻量 Card Interface 实现，供渲染/浏览所需；
    仅实现所需方法，不参与战斗结算）

    @param info table 卡牌文件信息（GetAllCardsInfo 返回项：{ fileName, name, savedAt, cardAppearance }；
                只用只读信息，不触碰编辑器 Canvas 状态）
    @return table 卡牌对象（pos/ang 为牌桌相对坐标 + GetID/GetType/GetName/GetStat/GetCost/GetActionCost/GetKeywords）
]]
function ENT:_CreateDeckCard(info)
    local app = info.cardAppearance or {}
    local card = {
        _fileName = info.fileName,
        _app = app,
        pos = { x = 0, y = 0, z = 0 }, -- 牌桌相对坐标（EnterDeckMode 按 2D 网格写入）
        ang = { p = 0, y = 0, r = 0 }, -- 相对牌桌局部朝向（平躺面朝上）
    }

    function card:GetID()
        return self._fileName
    end

    function card:GetType()
        return self._app.cardType or "unit"
    end

    function card:GetUnitType()
        return nil -- 组卡浏览不参与战斗，单位类型非必需
    end

    function card:GetName()
        return self._app.name or self._fileName or ""
    end

    function card:GetDescription()
        return self._app.specialEffect or ""
    end

    function card:GetStat(stat)
        return self._app[stat] or 0
    end

    function card:GetCost()
        return self._app.cost or 0
    end

    function card:GetActionCost()
        if self:GetType() ~= "unit" then return nil end
        return self._app.actionCost or 0
    end

    -- 词条数组：带数值词条（情报/倒计时/重甲）项为 { 词条id, 数值 }，其余为词条 id
    function card:GetKeywords()
        local kwValues = self._app.keywordValues or {}
        local list = {}
        for _, kw in ipairs(self._app.keywords or {}) do
            if kwValues[kw] ~= nil then
                table.insert(list, { kw, kwValues[kw] })
            else
                table.insert(list, kw)
            end
        end
        return list
    end

    function card:HasKeyword(id)
        for _, kw in ipairs(self:GetKeywords()) do
            if (type(kw) == "table" and kw[1] or kw) == id then return true end
        end
        return false
    end

    return card
end

-- ====================================================================
-- 卡组堆叠（放置卡组处）：牌桌相对坐标常量（可调，按实测微调）
-- ====================================================================
ENT.DeckPileBase  = Vector(27.5, 16.0, 18.43) -- 卡组堆叠基准：P2 视角右侧（+x）长边边缘（组卡模式由 P2 进入，-x 侧在其左侧会偏左；+x 与总部槽同侧但 y 不同不重叠；x=27.5 较原 22.5 右移 5，可微调）
ENT.DeckPileStepY = 1  -- 每张卡 y 减少量（向 -y 方向叠放；间隔紧凑）
ENT.DeckPileStepZ = 0.1  -- 每张卡 z 升高量（叠放高度；间隔紧凑）
ENT.DeckSavePos   = Vector(24.68, -12.80, 18.43) -- "保存"按钮位置（原总部槽坐标，牌桌相对；客户端 3D2D 描边文字 + 点击判定）
ENT.DeckPileMax   = 40   -- 卡组容量上限（40 张：总部 1 + 普通卡 39；同卡 ≥2 仅占 1 实体，实体数上限同总张数）

--[[
    卡组堆叠第 idx 张卡的相对坐标（第 1 张在基准位，后续每张 z 升高 / y 减少）

    @param idx number 堆叠序号（1 起）
    @return Vector
]]
function ENT:DeckPileRelPos(idx)
    return Vector(self.DeckPileBase.x,
                  self.DeckPileBase.y - (idx - 1) * self.DeckPileStepY,
                  self.DeckPileBase.z + (idx - 1) * self.DeckPileStepZ)
end

-- 卡组携带上限（按品质）：普通 4 / 限定 3 / 特殊 2 / 精英 1
ENT.DeckQualityLimit = { normal = 4, limited = 3, special = 2, elite = 1 }

-- 卡牌品质对应的卡组携带上限（未知品质回退普通 4）
function ENT:GetQualityLimit(card)
    local q = card and card._app and card._app.quality or "normal"
    return self.DeckQualityLimit[q] or 4
end

-- 更新卡组计数文字：同卡 >2 时在堆叠中该卡最后一张实体右上外侧显示 ×N（N=总数）
function ENT:SetPileCountNW(modelID, count)
    local pile = self._kardsDeckPile or {}
    local last = nil
    for _, e in ipairs(pile) do
        if e.modelID == modelID and IsValid(e.ent) then last = e.ent end
    end
    if IsValid(last) then
        last:SetNWInt("Kards_PileCount", count)
    end
end

-- 网格卡翻面：达携带上限翻面（视觉旋转 180° 显示卡背），移出恢复正面
function ENT:SetGridFlipped(srcEntry, flipped)
    if srcEntry and IsValid(srcEntry.ent) then
        srcEntry.ent:SetNWBool("Kards_GridFlipped", flipped)
        -- 视觉翻面：绕卡宽轴（局部 pitch）翻转 180°，背面朝上（卡背子网格在 -z）
        srcEntry.ent:SetLocalAngles(flipped and Angle(180, 0, 0) or Angle(0, 0, 0))
    end
end

-- 按 modelID 更新网格卡翻面状态（加入/移出后调用：达上限翻面、低于上限恢复）
function ENT:UpdateGridFlip(modelID)
    local count = (self._kardsDeckCounts or {})[modelID] or 0
    for _, entry in ipairs(self._kardsDeckCards or {}) do
        if entry.modelID == modelID then
            self:SetGridFlipped(entry, count >= self:GetQualityLimit(entry.card))
            break
        end
    end
end

-- 更新卡组堆叠顶层标志：仅最后一张（最顶层）为 true，其余 false。
-- 客户端据此给非顶层堆叠卡只绘制卡牌花费，其余文字不绘制（性能优化）
function ENT:UpdatePileTopFlags()
    local pile = self._kardsDeckPile or {}
    for i, e in ipairs(pile) do
        if IsValid(e.ent) then
            e.ent:SetNWBool("Kards_IsPileTop", i == #pile)
        end
    end
end

--[[
    从 5×3 网格卡复制一张到卡组堆叠（复用源卡 modelID，瞬时定位；副本由客户端
    DeckInitCard 扫描自动初始化材质与 3D2D 文字）

    品质携带上限：普通 4 / 限定 3 / 特殊 2 / 精英 1；同卡 ≥2 张后不再复制实体
    （仅第 1 张创建实体），改为在堆叠中该卡实体右上外侧显示 ×N 计数文字
    （Kards_PileCount NW）；达上限后网格卡翻面（Kards_GridFlipped + 视觉翻转 180°），
    客户端点击跳过。

    @param srcEntry table 网格卡条目 { card, ent, relPos, modelID }
    @return boolean 是否成功
]]
function ENT:DeckAddToPile(srcEntry)
    local pile = self._kardsDeckPile or {}
    if #pile >= self.DeckPileMax then return false end
    local modelID = srcEntry.modelID
    local count = (self._kardsDeckCounts or {})[modelID] or 0
    local limit = self:GetQualityLimit(srcEntry.card)
    if count >= limit then
        return false -- 已达携带上限（网格卡已翻面，客户端点击跳过）
    end
    count = count + 1
    self._kardsDeckCounts[modelID] = count
    if count >= 2 then
        -- 同卡 ≥2：不再复制实体（仅第 1 张建实体），更新该卡计数文字（×count）
        self:SetPileCountNW(modelID, count)
    else
        local idx = #pile + 1
        local relPos = self:DeckPileRelPos(idx)
        local ent = self:SpawnDeckCardEntity(srcEntry.card, modelID, relPos)
        if not IsValid(ent) then
            self._kardsDeckCounts[modelID] = count - 1 -- 回滚
            return false
        end
        ent:SetNWString("Kards_DeckRole", "pile")
        ent:SetNWBool("Kards_IsPileTop", false) -- 顶层标志随后统一更新
        ent:SetNWInt("Kards_PileCount", 0)
        if not (self._kardsChildSystem and self._kardsChildSystem:RegisterChild(ent, relPos)) then
            ent:Remove()
            self._kardsDeckCounts[modelID] = count - 1 -- 回滚
            return false
        end
        pile[idx] = { card = srcEntry.card, ent = ent, srcEntry = srcEntry, modelID = modelID }
        self._kardsDeckPile = pile
        self:UpdatePileTopFlags()
    end
    -- 达上限 → 网格卡翻面
    if count >= limit then
        self:UpdateGridFlip(modelID)
    end
    print(("[Kards] 卡组加入: %s（共 %d/%d 张）"):format(srcEntry.card:GetName(), count, limit))
    return true
end

--[[
    从卡组堆叠移除一张（副本 1 秒淡出销毁），其后卡牌相对位置重新计算并瞬时移动。
    同卡 ≥2（计数阶段）：不销毁实体（实体仅表示 1 张占位），仅减计数并更新 ×N 文字；
    常规（仅 1 张实体阶段）：销毁实体 + 重排。移除后若低于品质上限则网格卡恢复正面。

    @param pileEntry table 堆叠条目 { card, ent, srcEntry, modelID }
]]
function ENT:DeckRemoveFromPile(pileEntry)
    local pile = self._kardsDeckPile or {}
    local modelID = pileEntry.modelID
    local count = (self._kardsDeckCounts or {})[modelID] or 0
    if count >= 2 then
        -- 计数阶段（同卡 ≥2，实体仅 1 张占位）：不销毁实体，仅减计数并更新 ×N 文字
        count = count - 1
        self._kardsDeckCounts[modelID] = count
        self:SetPileCountNW(modelID, count >= 2 and count or 0)
        self:UpdateGridFlip(modelID) -- 低于上限恢复网格卡正面
        print(("[Kards] 卡组移除: %s（计数 %d/%d 张）"):format(pileEntry.card:GetName(), count, self:GetQualityLimit(pileEntry.card)))
        return
    end
    -- 常规移出（仅 1 张实体阶段）：销毁实体并重排
    local idx = nil
    for i, e in ipairs(pile) do
        if e == pileEntry then idx = i break end
    end
    if not idx then return end
    table.remove(pile, idx)
    if self._kardsChildSystem then
        if IsValid(pileEntry.ent) then
            self._kardsChildSystem:RemoveChild(pileEntry.ent) -- 1 秒淡出后销毁
            -- 通知客户端立即移除该卡 3D2D 文字（避免淡出期间文字残留晚于卡牌删除；
            -- 计数阶段移出不走本分支，不通知，文字保留）
            net.Start("KardsPileCardRemoved")
                net.WriteEntity(pileEntry.ent)
            net.Broadcast()
        end
        -- 后续卡相对位置重新计算并移动（瞬时 SetLocalPos）
        for i = idx, #pile do
            self._kardsChildSystem:SetChildRelPos(pile[i].ent, self:DeckPileRelPos(i))
        end
        self:UpdatePileTopFlags() -- 移除后顶层变化，更新各卡顶层标志
    end
    self._kardsDeckCounts[modelID] = math.max(0, count - 1)
    self:UpdateGridFlip(modelID) -- 低于上限恢复网格卡正面
    print(("[Kards] 卡组移除: %s（余 %d 张）"):format(pileEntry.card:GetName(), self._kardsDeckCounts[modelID]))
end
