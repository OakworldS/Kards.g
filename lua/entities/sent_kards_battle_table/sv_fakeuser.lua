--[[
    伪用户控制台命令系统（kards_fakeuser_*，2026-09-13）

    用途：无对手测试牌桌（对方槽为虚拟对手 bd.virtual）中，管理把虚拟对手接管为
    「伪用户」，用控制台指令替对手出牌，供测试敌方卡牌动画。仅 operator 及以上可用。

    接管后（ent._kardsFakeUser = { ply, slot }）：
      - kards_switch 交换操作位置失效（table_session.lua 门控）
      - 回合超时定时器失效（StartTurnTimer 门控）
      - 玩家经下列指令操作对方槽手牌 / 结束对方回合

    指令一览（均带 kards_fakeuser_ 前缀；x 额外注册同名短指令）：
      kards_fakeuser [0|1]       启停接管（无参数或 1 = 启动，0 = 关闭）
      kards_fakeuser_hand        列出对方手牌（卡序数/名称/花费/反制激活/属性/词条/效果）
      kards_fakeuser_play <序数> 选定手牌：指挥点不足拒绝；单位缓存待部署；指令立即打出
                                 （开发三选一 / 指向选择经协程挂起，由 x 续选）；
                                 反制仅切换激活状态
      kards_fakeuser_x <数字>    续选：单位=部署槽 1..5；开发=候选序号 1..3；
                                 指向=两位编码（友方阵线 11..15 / 前线 1..5 /
                                 敌方阵线 -1..-5 或 -11..-15）
      kards_fakeuser_endturn     结束对方回合

    彩色输出经 KardsFakeUserPrint 网络串下发客户端 MsgC（见 cl_fakeuser_console.lua）。

    协程说明：指令效果中的「开发」与「指向一个」在数据层执行途中选择。协程在
    picker 内 yield 等待，控制台 x 指令 resume 提交选择，OnPlayCard 全流程在同一
    协程内跑完（实体创建/net 广播均为协程友好调用）。
]]

local ENT = scripted_ents.GetStored("sent_kards_battle_table").t

-- ====================================================================
-- 彩色控制台输出
-- ====================================================================
local C = {
    head    = Color(255, 165, 60),   -- 标题/块名 橙
    label   = Color(170, 170, 170),  -- 字段标签 灰
    name    = Color(255, 230, 120),  -- 卡名 黄
    cost    = Color(255, 255, 255),  -- 花费 白
    ok      = Color(120, 220, 120),  -- 正常状态 绿
    bad     = Color(240, 90, 90),    -- 警告/失败 红
    info    = Color(120, 180, 255),  -- 提示 蓝
    dim     = Color(140, 140, 140),  -- 无内容 暗灰
    quality = {
        normal  = Color(190, 190, 190),
        limited = Color(90, 200, 90),
        special = Color(90, 150, 230),
        elite   = Color(220, 140, 60),
    },
}

-- 向玩家控制台输出彩色文本：pieces = { { Color, "文本" }, ... }，自动补换行
local function fsPrint(ply, pieces)
    if not IsValid(ply) then return end
    net.Start("KardsFakeUserPrint")
        net.WriteUInt(#pieces, 8)
        for _, p in ipairs(pieces) do
            net.WriteColor(p[1] or color_white)
            net.WriteString(p[2] or "")
        end
    net.Send(ply)
end

local function fsLine(ply, ...)
    local pieces = { ... }
    pieces[#pieces + 1] = { C.dim, "\n" }
    fsPrint(ply, pieces)
end

-- ====================================================================
-- 词汇（类型/品质/词条中文名）
-- ====================================================================
local TYPE_NAME = {
    unit = "单位", command = "指令", counter_command = "反制", headquarter = "总部",
}
local QUALITY_NAME = {
    normal = "普通", limited = "限定", special = "特制", elite = "精英",
}
local KeywordLabels = nil
local function kwLabel(id)
    if not KeywordLabels then
        KeywordLabels = KARDS.RulesVocabulary.GetOptionLabels
            and KARDS.RulesVocabulary.GetOptionLabels("combat_keywords") or {}
    end
    return KeywordLabels[id] or id
end

-- 取卡牌编辑器外观（名称/效果文字；MockCard 句柄不携带外观文本，按文件回查）
local function cardAppearance(card)
    local ok, info = pcall(function()
        return KARDS.CardEditor and KARDS.CardEditor.SaveSystem
            and KARDS.CardEditor.SaveSystem.GetCardInfo(card:GetID())
    end)
    if ok and info then return info.cardAppearance or info end
    return nil
end

local function cardDisplayName(card)
    local app = cardAppearance(card)
    if app and app.name and app.name ~= "" then return app.name end
    return card:GetName() or card:GetID()
end

local function cardEffectText(card)
    local app = cardAppearance(card)
    if app and app.specialEffect and app.specialEffect ~= "" then
        return app.specialEffect
    end
    return "（无效果文字）"
end

-- 词条列表串：带数值词条（重甲/倒计时/情报等 {id, x}）追加数值
local function keywordText(card)
    local kws = (card.GetKeywords and card:GetKeywords()) or {}
    if #kws == 0 then return "（无词条）" end
    local parts = {}
    for _, kw in ipairs(kws) do
        if type(kw) == "table" then
            parts[#parts + 1] = kwLabel(kw[1]) .. tostring(kw[2] or "")
        else
            parts[#parts + 1] = kwLabel(kw)
        end
    end
    return table.concat(parts, "，")
end

-- ====================================================================
-- 会话辅助
-- ====================================================================
local function fakeState(ply)
    local data = ply._kardsTable
    local ent = data and data.ent
    local fs = IsValid(ent) and ent._kardsFakeUser or nil
    if fs and fs.ply == ply then return ent, fs end
    return nil, nil
end

-- 反制激活状态存于卡牌句柄（伪用户本地标记，不进数据层）
local function counterActiveText(card)
    if card:GetType() ~= "counter_command" then return "无反制", C.dim end
    if card._kardsFakeCounterActive then return "反制已激活", C.ok end
    return "反制未激活", C.dim
end

-- ====================================================================
-- 列手牌
-- ====================================================================
local function listHand(ply, ent, fs)
    local pid = (fs.slot == 1) and "P1" or "P2"
    local hand = KARDS.Deck:GetHand(ent.TableID, pid) or {}
    if #hand == 0 then
        fsLine(ply, { C.head, "[伪用户] " }, { C.dim, "对方手牌为空" })
        return
    end
    local cp = KARDS.CommandPoints:GetPoints(ent.TableID, pid) or 0
    fsLine(ply, { C.head, ("[伪用户] 对方手牌 %d 张，当前指挥点 %dk"):format(#hand, cp) })
    for i, card in ipairs(hand) do
        local ctype = card:GetType()
        local actText, actColor = counterActiveText(card)
        fsLine(ply, { C.head, "{" })
        fsLine(ply, { C.cost, tostring(i) })
        fsLine(ply,
            { C.name, cardDisplayName(card) }, { C.label, "  " },
            { C.cost, tostring(card:GetCost() or 0) }, { C.label, "k | " },
            { actColor, actText })
        if ctype == "unit" then
            fsLine(ply, { C.label, "行动花费：" }, { C.cost, tostring(card:GetActionCost() or 0) }, { C.label, "k" })
        end
        -- 类型行：单位为单位类型（步兵/坦克…），其余为卡牌大类
        local typeLine = TYPE_NAME[ctype] or tostring(ctype)
        if ctype == "unit" then
            local labels = KARDS.RulesVocabulary.GetOptionLabels("unit_types")
            typeLine = labels[card:GetUnitType()] or "单位"
        end
        fsLine(ply, { C.info, typeLine })
        if ctype == "unit" then
            fsLine(ply, { C.cost, tostring(card:GetStat("attack")) }, { C.label, "|" },
                { C.cost, tostring(card:GetStat("defense")) })
        end
        fsLine(ply, { C.label, keywordText(card) })
        fsLine(ply, { C.dim, cardEffectText(card) })
        local q = card.GetQuality and card:GetQuality() or "normal"
        fsLine(ply, { C.quality[q] or C.dim, QUALITY_NAME[q] or tostring(q) },
            { C.label, TYPE_NAME[ctype] or tostring(ctype) })
        fsLine(ply, { C.head, "}" })
    end
end

-- ====================================================================
-- 阵线打印（名称简表 / 全局势）
-- ====================================================================
local function slotName(ent, slot, card)
    if not card then return "nil" end
    if card:GetType() == "headquarter" then return "总部·" .. cardDisplayName(card) end
    return cardDisplayName(card)
end

-- 打印一条阵线（固定 SLOT_COUNT 槽，形如 [nil,nil,{名称},nil,nil]）
local function dumpLine(ply, title, titleColor, line)
    local parts = { { titleColor, title }, { C.label, " [" } }
    local n = KARDS.Battlefield.SLOT_COUNT
    for i = 1, n do
        if i > 1 then parts[#parts + 1] = { C.dim, "," } end
        if line and line[i] then
            parts[#parts + 1] = { C.name, "{" .. slotName(nil, nil, line[i]) .. "}" }
        else
            parts[#parts + 1] = { C.dim, "nil" }
        end
    end
    parts[#parts + 1] = { C.label, "]" }
    fsLine(ply, unpack(parts))
end

-- 单位部署前：输出敌方（伪用户）自己的支援阵线数据（仅项目名）
local function dumpDeployLine(ply, ent, fs)
    local line = KARDS.Battlefield:GetSupport(ent.TableID, (fs.slot == 1) and "P1" or "P2")
    fsLine(ply, { C.head, "[伪用户] " }, { C.label, "选择部署槽位（1..5，3 常为总部；输入 kards_fakeuser_x 槽位）" })
    dumpLine(ply, "友方支援阵线", C.ok, line)
end

-- 指向选择前：敌方视角全战场（友方支援 → 前线 → 敌方支援）
local function dumpBattlefield(ply, ent, fs, candidates)
    local friendPid = (fs.slot == 1) and "P1" or "P2"
    local enemyPid = (fs.slot == 1) and "P2" or "P1"
    dumpLine(ply, "友方支援阵线（编码 11..15）", C.ok,
        KARDS.Battlefield:GetSupport(ent.TableID, friendPid))
    local inst = KARDS.Battlefield:Get(ent.TableID)
    local ownerTxt = inst and inst.FrontlineOwner and ("，占领方 " .. tostring(inst.FrontlineOwner)) or ""
    dumpLine(ply, "前线（编码 1..5" .. ownerTxt .. "）", C.info,
        KARDS.Battlefield:GetFrontline(ent.TableID))
    dumpLine(ply, "敌方支援阵线（编码 -1..-5 或 -11..-15）", C.bad,
        KARDS.Battlefield:GetSupport(ent.TableID, enemyPid))
    if candidates then
        local names = {}
        for _, c in ipairs(candidates) do
            names[#names + 1] = cardDisplayName(c)
        end
        fsLine(ply, { C.label, "本指令合法指向目标：" }, { C.name, table.concat(names, "，") })
    end
end

-- ====================================================================
-- 续选（x）
-- ====================================================================
-- 指向编码解析：n<0 且绝对值>=10 → 敌方阵线槽位（个位）；n<0 个位 → 敌方阵线；
-- n>=10 十位 1 → 友方阵线槽位（个位）；n 为 1..9 → 前线槽位
local function decodeTargetCode(n)
    if n == nil then return nil end
    if n < 0 then
        local a = -n
        if a >= 10 then return "enemy", a - 10 end
        return "enemy", a
    end
    if n >= 10 then
        local tens = math.floor(n / 10)
        if tens == 1 then return "friend", n - 10 end
        return nil
    end
    return "front", n
end

-- 续跑后的收尾：输出下一次挂起提示，或提示结算完成。抽为独立函数供两条续跑路径
-- 共用（直接 resume 与经 table_pick.lua ResolvePick 提交）
local function afterResume(ply, ent, fs, ok, req)
    if not ok then
        fsLine(ply, { C.bad, "[伪用户] 指令执行出错：" }, { C.dim, tostring(req) })
        fs.pending, fs.co = nil, nil
        return
    end
    if fs.co and coroutine.status(fs.co) == "suspended" and type(req) == "table" then
        -- 效果链存在多个选择点（如多次开发）：继续挂起等待下一次 x
        fs.pending = req
        if req.kind == "develop" then
            local parts = { { C.head, "[伪用户] " }, { C.label, "开发：选择一张加入手牌（kards_fakeuser_x 1..3）\n" } }
            for i, c in ipairs(req.candidates or {}) do
                parts[#parts + 1] = { C.cost, "  " .. i .. ". " }
                parts[#parts + 1] = { C.name, cardDisplayName(c) .. "\n" }
            end
            fsPrint(ply, parts)
        elseif req.kind == "scry" then
            local parts = { { C.head, "[伪用户] " },
                { C.label, "观星：选择一张加入手牌，其余返回卡组底（kards_fakeuser_x 1.."
                    .. #(req.candidates or {}) .. "）\n" } }
            for i, c in ipairs(req.candidates or {}) do
                parts[#parts + 1] = { C.cost, "  " .. i .. ". " }
                parts[#parts + 1] = { C.name, cardDisplayName(c) .. "\n" }
            end
            fsPrint(ply, parts)
        elseif req.kind == "target" then
            fsLine(ply, { C.head, "[伪用户] " }, { C.label, "选择指向目标（编码见阵线列表后输入 kards_fakeuser_x 数字）" })
            dumpBattlefield(ply, ent, fs, req.candidates)
        end
        return
    end
    fs.pending, fs.co = nil, nil
    fsLine(ply, { C.ok, "[伪用户] 选择已提交，指令结算完成" })
end

local function resumePending(ply, ent, fs, value)
    local pending = fs.pending
    if not pending or not fs.co then return end
    local ok, req = coroutine.resume(fs.co, value)
    afterResume(ply, ent, fs, ok, req)
end

local function cmdX(ply, numRaw)
    local ent, fs = fakeState(ply)
    if not ent then
        fsLine(ply, { C.bad, "[伪用户] 未接管对方，或已离开牌桌" })
        return
    end
    local pending = fs.pending
    if not pending then
        fsLine(ply, { C.bad, "[伪用户] 当前没有等待续选的操作（先 kards_fakeuser_play 选定卡牌）" })
        return
    end
    local n = tonumber(numRaw)
    if not n then
        fsLine(ply, { C.bad, "[伪用户] 请输入数字" })
        return
    end
    n = math.floor(n)

    if pending.kind == "deploy" then
        if n < 1 or n > KARDS.Battlefield.SLOT_COUNT then
            fsLine(ply, { C.bad, ("[伪用户] 部署槽位须为 1..%d"):format(KARDS.Battlefield.SLOT_COUNT) })
            return
        end
        fs.pending, fs.co = nil, nil
        local card, cardEnt = pending.card, pending.cardEnt
        if not (card and IsValid(cardEnt)) then
            fsLine(ply, { C.bad, "[伪用户] 缓存的卡牌已失效，请重新选定" })
            return
        end
        local ok = ent:OnPlayCard(ply, fs.slot, cardEnt, n, nil)
        -- OnPlayCard 无返回值；SimDeploy 失败由其内部 reject/提示处理
        fsLine(ply, { C.ok, "[伪用户] 单位部署请求已提交至槽位 " .. n })
        return
    end

    -- 开发 / 观星：候选来自服务端三选一会话（table_pick.lua BeginPick）。提交走
    -- ResolvePick（与客户端点击同一条收尾路径：广播结果 + 回收未选中候选），使第二段
    -- 动画与实体生命周期一致；会话已不在（超时自动结算）时兜底直接 resume
    if pending.kind == "develop" or pending.kind == "scry" then
        local cand = pending.candidates or {}
        local chosen = cand[n]
        if not chosen then
            fsLine(ply, { C.bad, ("[伪用户] %s候选序号须为 1..%d"):format(
                pending.kind == "develop" and "开发" or "观星", #cand) })
            return
        end
        if pending.co and ent._kardsPick == pending then
            local ok, req = ent:ResolvePick(pending, chosen, n)
            afterResume(ply, ent, fs, ok, req)
        else
            resumePending(ply, ent, fs, chosen)
        end
        return
    end

    if pending.kind == "target" then
        local lineKey, slotIdx = decodeTargetCode(n)
        if not lineKey or slotIdx < 1 or slotIdx > KARDS.Battlefield.SLOT_COUNT then
            fsLine(ply, { C.bad, "[伪用户] 指向编码无效：友方 11..15 / 前线 1..5 / 敌方 -1..-5（或 -11..-15）" })
            return
        end
        local pid
        if lineKey == "friend" then
            pid = (fs.slot == 1) and "P1" or "P2"
        elseif lineKey == "enemy" then
            pid = (fs.slot == 1) and "P2" or "P1"
        end
        local card
        if lineKey == "front" then
            card = (KARDS.Battlefield:GetFrontline(ent.TableID) or {})[slotIdx]
        else
            card = (KARDS.Battlefield:GetSupport(ent.TableID, pid) or {})[slotIdx]
        end
        if not card then
            fsLine(ply, { C.dim, "（指向了空位）" })
            resumePending(ply, ent, fs, false)
            return
        end
        local legal = false
        for _, c in ipairs(pending.candidates or {}) do
            if c == card then legal = true break end
        end
        if not legal then
            local zoneName = ({ friend = "友方阵线", enemy = "敌方阵线", front = "前线" })[lineKey]
            fsLine(ply, { C.bad, ("指向失败：%s 槽位 %d 的「%s」不是本指令的合法指向目标"):format(
                zoneName, slotIdx, cardDisplayName(card)) })
            resumePending(ply, ent, fs, false)
            return
        end
        resumePending(ply, ent, fs, card)
        return
    end

    fsLine(ply, { C.bad, "[伪用户] 未知的待选状态" })
    fs.pending, fs.co = nil, nil
end

-- ====================================================================
-- 选定手牌（play 序数）
-- ====================================================================
local function cmdPlay(ply, idxRaw)
    local ent, fs = fakeState(ply)
    if not ent then
        fsLine(ply, { C.bad, "[伪用户] 未接管对方，或已离开牌桌" })
        return
    end
    if fs.pending then
        fsLine(ply, { C.bad, "[伪用户] 上一张卡仍在等待续选，请先用 kards_fakeuser_x 完成" })
        return
    end
    if not ent._kardsFormalBattleStarted or not ent._kardsFirstTurnStarted then
        fsLine(ply, { C.bad, "[伪用户] 对局尚未正式开始" })
        return
    end
    if ent._kardsTurnSlot ~= fs.slot then
        fsLine(ply, { C.bad, "[伪用户] 尚未轮到对方回合，不能替对方出牌" })
        return
    end
    local idx = tonumber(idxRaw)
    idx = idx and math.floor(idx) or nil
    local pid = (fs.slot == 1) and "P1" or "P2"
    local hand = KARDS.Deck:GetHand(ent.TableID, pid) or {}
    local card = idx and hand[idx]
    if not card then
        fsLine(ply, { C.bad, "[伪用户] 手牌序数无效（1.." .. #hand .. "），用 kards_fakeuser_hand 查看" })
        return
    end
    -- 指挥点预检（确认足够打出后才进入后续流程）
    if not KARDS.CommandPoints:CanPay(ent.TableID, pid, card:GetCost() or 0) then
        local cp = KARDS.CommandPoints:GetPoints(ent.TableID, pid) or 0
        fsLine(ply, { C.bad, ("[伪用户] 指挥点不足：「%s」需要 %dk，当前 %dk"):format(
            cardDisplayName(card), card:GetCost() or 0, cp) })
        return
    end
    local deck = ent._kardsBattleDecks and ent._kardsBattleDecks[fs.slot]
    local cardEnt = deck and deck.cardEnt and deck.cardEnt[card]
    if not IsValid(cardEnt) then
        fsLine(ply, { C.bad, "[伪用户] 该卡缺少手牌世界实体，无法播放打出动画" })
        return
    end
    local ctype = card:GetType()

    -- 反制：只切换激活状态（取反），不打出
    if ctype == "counter_command" then
        card._kardsFakeCounterActive = not card._kardsFakeCounterActive
        local txt, col = counterActiveText(card)
        fsLine(ply, { C.head, "[伪用户] " }, { C.name, cardDisplayName(card) },
            { C.label, " 激活状态取反 → " }, { col, txt })
        return
    end

    -- 单位：缓存卡牌，输出本方（伪用户视角友方）支援阵线，等待 x 指定部署槽
    if ctype == "unit" then
        fs.pending = { kind = "deploy", card = card, cardEnt = cardEnt }
        fsLine(ply, { C.head, "[伪用户] " }, { C.name, cardDisplayName(card) },
            { C.label, " 已缓存，等待部署位置" })
        dumpDeployLine(ply, ent, fs)
        return
    end

    -- 指令：在协程内立即打出（开发/指向 picker 会挂起等待 x）
    if ctype ~= "command" then
        fsLine(ply, { C.bad, "[伪用户] 该卡牌类型（" .. tostring(ctype) .. "）不能打出" })
        return
    end
    local bridge = {
        -- 开发/观星选择走服务端三选一会话（table_pick.lua BeginPick）：生成候选卡实体
        -- 并广播 offer，使本方同样看到「敌方开发牌三张卡背」的演出；yield 值为选中卡。
        -- 目标选择仍由本控制台协程挂起（不经世界实体反查）
        developPicker = function(candidates)
            return ent:BeginPick(ply, fs.slot, "develop", candidates)
        end,
        scryPicker = function(candidates)
            return ent:BeginPick(ply, fs.slot, "scry", candidates)
        end,
        targetPicker = function(candidates)
            return coroutine.yield({ kind = "target", candidates = candidates })
        end,
    }
    local co = coroutine.create(function()
        ent:OnPlayCard(ply, fs.slot, cardEnt, 0, nil, { specify = bridge })
    end)
    local ok, req = coroutine.resume(co)
    if not ok then
        fsLine(ply, { C.bad, "[伪用户] 指令执行出错：" }, { C.dim, tostring(req) })
        return
    end
    if coroutine.status(co) == "suspended" and type(req) == "table" then
        fs.co, fs.pending = co, req
        if req.kind == "develop" then
            local parts = { { C.head, "[伪用户] " }, { C.name, cardDisplayName(card) },
                { C.label, " 触发开发：选择一张加入手牌（kards_fakeuser_x 1..3）\n" } }
            for i, c in ipairs(req.candidates or {}) do
                parts[#parts + 1] = { C.cost, "  " .. i .. ". " }
                parts[#parts + 1] = { C.name, cardDisplayName(c) .. "\n" }
            end
            fsPrint(ply, parts)
        elseif req.kind == "scry" then
            local parts = { { C.head, "[伪用户] " }, { C.name, cardDisplayName(card) },
                { C.label, " 触发观星：选择一张加入手牌，其余返回卡组底（kards_fakeuser_x 1.."
                    .. #(req.candidates or {}) .. "）\n" } }
            for i, c in ipairs(req.candidates or {}) do
                parts[#parts + 1] = { C.cost, "  " .. i .. ". " }
                parts[#parts + 1] = { C.name, cardDisplayName(c) .. "\n" }
            end
            fsPrint(ply, parts)
        elseif req.kind == "target" then
            fsLine(ply, { C.head, "[伪用户] " }, { C.name, cardDisplayName(card) },
                { C.label, " 需要指向目标" })
            dumpBattlefield(ply, ent, fs, req.candidates)
        end
        return
    end
    fsLine(ply, { C.ok, "[伪用户] 指令「" .. cardDisplayName(card) .. "」已打出结算" })
end

-- ====================================================================
-- 启停 / 结束回合
-- ====================================================================
local function cmdToggle(ply, arg)
    local data = ply._kardsTable
    local ent = data and data.ent
    if not IsValid(ent) then
        fsLine(ply, { C.bad, "[伪用户] 未在牌桌内" })
        return
    end
    -- 关闭
    if arg == "0" then
        if ent._kardsFakeUser and ent._kardsFakeUser.ply == ply then
            ent._kardsFakeUser = nil
            fsLine(ply, { C.ok, "[伪用户] 已关闭伪用户接管，恢复 kards_switch 与回合超时" })
        else
            fsLine(ply, { C.dim, "[伪用户] 当前未接管" })
        end
        return
    end
    -- 启动（无参数或 1）
    if ent._kardsFakeUser then
        fsLine(ply, { C.bad, "[伪用户] 本桌已处于伪用户接管中" })
        return
    end
    if not ent._kardsFormalBattleStarted then
        fsLine(ply, { C.bad, "[伪用户] 对局尚未开始，无法接管" })
        return
    end
    if ent:GetPlayerCount() ~= 1 then
        fsLine(ply, { C.bad, "[伪用户] 仅无对手模式（牌桌内一名玩家）可接管" })
        return
    end
    local mySlot = data.physSlot or data.slot
    local fakeSlot = 3 - mySlot
    local fdeck = ent._kardsBattleDecks and ent._kardsBattleDecks[fakeSlot]
    if not (fdeck and fdeck.virtual) then
        fsLine(ply, { C.bad, "[伪用户] 对方槽位不是虚拟对手，无法接管" })
        return
    end
    ent._kardsFakeUser = { ply = ply, slot = fakeSlot }
    ent:ClearTurnTimer() -- 接管即刻起回合超时失效
    fsLine(ply, { C.ok, "========================================" })
    fsLine(ply, { C.ok, ("[伪用户] 已接管 P%d 虚拟对手；kards_switch 与回合超时已禁用"):format(fakeSlot) })
    fsLine(ply, { C.info, "指令：" })
    fsLine(ply, { C.label, "  kards_fakeuser_hand        列出对方手牌" })
    fsLine(ply, { C.label, "  kards_fakeuser_play <序数> 选定手牌（单位选位/指令打出/反制切换激活）" })
    fsLine(ply, { C.label, "  kards_fakeuser_x <数字>    续选（也可用短指令 x <数字>）" })
    fsLine(ply, { C.label, "  kards_fakeuser_endturn     结束对方回合" })
    fsLine(ply, { C.label, "  kards_fakeuser 0           关闭接管" })
    fsLine(ply, { C.ok, "========================================" })
end

local function cmdEndTurn(ply)
    local ent, fs = fakeState(ply)
    if not ent then
        fsLine(ply, { C.bad, "[伪用户] 未接管对方，或已离开牌桌" })
        return
    end
    if fs.pending then
        fsLine(ply, { C.bad, "[伪用户] 仍有卡牌等待续选，不能结束回合" })
        return
    end
    if ent._kardsGameOver then
        fsLine(ply, { C.bad, "[伪用户] 对局已结束" })
        return
    end
    if ent._kardsTurnSlot ~= fs.slot then
        fsLine(ply, { C.bad, "[伪用户] 尚未轮到对方回合" })
        return
    end
    ent:EndTurn()
    fsLine(ply, { C.ok, ("[伪用户] P%d 回合已结束"):format(fs.slot) })
end

-- ====================================================================
-- 指令注册（仅 operator 及以上；SERVER 段一次）
-- 判定走 KARDS.IsOperator（2026-10-03 修复：管理插件未装时回退内建管理员判定，
-- 原先直接调 Player:IsOperator 在该情形下报 nil 方法错误）
-- ====================================================================
local function reg(name, fn, needsArg)
    concommand.Add(name, function(ply, _, args)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        if not KARDS.IsOperator(ply) then
            fsPrint(ply, { { C.bad, "[伪用户] 权限不足（需 operator 及以上）\n" } })
            return
        end
        if needsArg and (not args[1] or args[1] == "") then
            fsPrint(ply, { { C.bad, "[伪用户] 缺少参数\n" } })
            return
        end
        fn(ply, args[1])
    end)
end

reg("kards_fakeuser",         cmdToggle,  false)
reg("kards_fakeuser_hand",    function(ply)
    local ent, fs = fakeState(ply)
    if not ent then fsLine(ply, { C.bad, "[伪用户] 未接管对方，或已离开牌桌" }) return end
    listHand(ply, ent, fs)
end, false)
reg("kards_fakeuser_play",    cmdPlay,    true)
reg("kards_fakeuser_x",       cmdX,       true)
reg("kards_fakeuser_endturn", cmdEndTurn, false)
-- 短指令 x：仅在有等待续选时生效（避免与其他模组指令语义冲突）
reg("x", function(ply, arg)
    local _, fs = fakeState(ply)
    if not fs or not fs.pending then
        fsLine(ply, { C.bad, "[伪用户] 当前没有等待续选的操作" })
        return
    end
    cmdX(ply, arg)
end, true)
