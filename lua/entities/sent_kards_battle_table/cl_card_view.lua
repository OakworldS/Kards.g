--[[
    卡面视图（cl_card_view.lua，2026-11-08，见 docs/adr/0008-卡面视图层.md）

    职责：渲染层读取卡牌数据的唯一入口。NW 键名收在本文件，渲染层只吃返回的纯表，
    因此改 NW 键只需改这里，卡面渲染也能用桩实体离线断言。

    KARDS.CardView.Read(ent) 返回扁平表，字段永不为 nil：
      name / nameEn / fileName / ctype   身份，委托 KARDS.GetCardIdentity（含定向表回退链）
      country                            国家标识
      description / descriptionEn        效果描述，description 已按本机语言择一
      keywords                           词条 NW 串（id 列表，调用方反序列化后重建文本）
      unitKeywords                       战场单位词条 NW 串（含 neutralized 等状态）
      cost / actionCost / attack / defense 数值
      isCommand / isHeadquarter / hasKeywords 类型与词条标记

    不做缓存：GetNW 是哈希查表加类型转换，开销远小于一张卡每帧的 3D2D 绘制；
    保持纯函数便于离线断言。
]]

KARDS = KARDS or {}
KARDS.CardView = KARDS.CardView or {}

local CV = KARDS.CardView

--- 读取一张卡牌实体的卡面字段
-- @param ent Entity 卡牌实体
-- @return table 卡面视图，字段见文件头
function CV.Read(ent)
    local view = {
        name = "",
        nameEn = "",
        fileName = "",
        ctype = "",
        country = "",
        description = "",
        descriptionEn = "",
        keywords = "",
        unitKeywords = "",
        cost = 0,
        actionCost = 0,
        attack = 0,
        defense = 0,
        isCommand = false,
        isHeadquarter = false,
        hasKeywords = false,
    }
    if not IsValid(ent) then return view end

    -- 身份三项走统一入口，手牌卡面定向表的回退链由此自动生效
    if KARDS.GetCardIdentity then
        view.name, view.fileName, view.ctype = KARDS.GetCardIdentity(ent)
    end
    view.nameEn = ent:GetNWString("Kards_CardNameEn", "")
    view.country = ent:GetNWString("Kards_CardCountry", "")

    local desc = ent:GetNWString("Kards_CardDescription", "")
    local descEn = ent:GetNWString("Kards_CardDescriptionEn", "")
    view.descriptionEn = descEn
    local Data = KARDS.CardEditor and KARDS.CardEditor.Data
    view.description = (Data and Data.PickLocalized) and Data.PickLocalized(desc, descEn) or desc

    view.keywords = ent:GetNWString("Kards_CardKeywords", "")
    view.unitKeywords = ent:GetNWString("Kards_UnitKeywords", "")

    view.cost = ent:GetNWInt("Kards_CardCost", 0)
    view.actionCost = ent:GetNWInt("Kards_CardActionCost", 0)
    view.attack = ent:GetNWInt("Kards_CardAttack", 0)
    view.defense = ent:GetNWInt("Kards_CardDefense", 0)

    view.isCommand = ent:GetNWBool("Kards_CardIsCommand", false)
    view.isHeadquarter = ent:GetNWBool("Kards_CardIsHeadquarter", false)
    view.hasKeywords = ent:GetNWBool("Kards_CardHasKeywords", false)

    return view
end
