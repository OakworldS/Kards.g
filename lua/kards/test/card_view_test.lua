--[[
=======================================================================================
卡面视图离线测试
=======================================================================================
不依赖 GMod 环境，在仓库根目录执行：

    lua lua/kards/test/card_view_test.lua

覆盖范围：
  - 完整实体的字段读取
  - 定向表命中：身份取自 KARDS.GetCardIdentity 而非直读 NW
  - NW 键缺失时返回类型默认值，字段永不为 nil
  - 无效实体返回全默认表
  - 描述经 PickLocalized 择一
  - 防回潮：四个渲染文件不得再出现卡面 NW 字面量

源文件：lua/entities/sent_kards_battle_table/cl_card_view.lua（新建 2026-11-08），
对应 docs/adr/0008-卡面视图层.md
=======================================================================================
]]

function IsValid(v)
    return v ~= nil and v.valid ~= false
end

-- 桩实体：NW 键存在则返回，缺失则返回调用方给的默认值
local function MakeEnt(nw, face)
    local ent = { valid = true, nw = nw or {}, face = face }
    ent.GetNWString = function(self, key, default)
        local v = self.nw[key]
        if v == nil then return default end
        return v
    end
    ent.GetNWInt = function(self, key, default)
        local v = self.nw[key]
        if v == nil then return default end
        return v
    end
    ent.GetNWBool = function(self, key, default)
        local v = self.nw[key]
        if v == nil then return default end
        return v
    end
    return ent
end

local pickCalls = 0
KARDS = {
    -- 身份桩：有定向表则走定向表，否则回退 NW，模拟真实的两级来源
    GetCardIdentity = function(ent)
        if ent.face then
            return ent.face.name, ent.face.fileName, ent.face.ctype
        end
        return ent:GetNWString("Kards_CardName", ""),
            ent:GetNWString("Kards_CardFileName", ""),
            ent:GetNWString("Kards_CardType", "")
    end,
    CardEditor = {
        Data = {
            PickLocalized = function(zh, en)
                pickCalls = pickCalls + 1
                return "L(" .. tostring(zh) .. "," .. tostring(en) .. ")"
            end,
        },
    },
}

dofile("lua/entities/sent_kards_battle_table/cl_card_view.lua")
local CV = KARDS.CardView
assert(CV, "卡面视图未挂到 KARDS.CardView")

local passed = 0
local function ok(cond, message)
    assert(cond, message)
    passed = passed + 1
end

local EXPECTED_KEYS = {
    "name", "nameEn", "fileName", "ctype", "country",
    "description", "descriptionEn", "keywords", "unitKeywords",
    "cost", "actionCost", "attack", "defense",
    "isCommand", "isHeadquarter", "hasKeywords",
}

-- 1. 完整实体
local fullEnt = MakeEnt({
    Kards_CardName = "第55团",
    Kards_CardNameEn = "55th Regiment",
    Kards_CardFileName = "infantry55.json",
    Kards_CardType = "unit",
    Kards_CardCountry = "soviet",
    Kards_CardDescription = "入场时抽一张牌。",
    Kards_CardDescriptionEn = "Draw a card on deploy.",
    Kards_CardKeywords = "blitz|1",
    Kards_UnitKeywords = "guard|neutralized",
    Kards_CardCost = 3,
    Kards_CardActionCost = 1,
    Kards_CardAttack = 4,
    Kards_CardDefense = 5,
    Kards_CardIsCommand = true,
    Kards_CardIsHeadquarter = false,
    Kards_CardHasKeywords = true,
})
local view = CV.Read(fullEnt)
ok(view.name == "第55团" and view.nameEn == "55th Regiment", "身份名称读取失败")
ok(view.fileName == "infantry55.json" and view.ctype == "unit", "身份文件与类型读取失败")
ok(view.country == "soviet", "国家读取失败")
ok(view.keywords == "blitz|1", "卡牌词条串读取失败")
ok(view.unitKeywords == "guard|neutralized", "单位词条串读取失败")
ok(view.cost == 3 and view.actionCost == 1, "费用与行动花费读取失败")
ok(view.attack == 4 and view.defense == 5, "攻防读取失败")
ok(view.isCommand == true and view.isHeadquarter == false and view.hasKeywords == true, "类型标记读取失败")
ok(pickCalls == 1, "描述应恰好经过一次 PickLocalized")
ok(view.description == "L(入场时抽一张牌。,Draw a card on deploy.)", "描述本地化结果不符")
ok(view.descriptionEn == "Draw a card on deploy.", "英文描述应原样保留")

-- 2. 定向表命中：NW 名称为空，身份仍须来自定向表
local faceEnt = MakeEnt({
    Kards_CardName = "",
    Kards_CardAttack = 2,
    Kards_CardDefense = 2,
}, { name = "定向卡名", fileName = "face.json", ctype = "unit" })
local faceView = CV.Read(faceEnt)
ok(faceView.name == "定向卡名", "定向表命中时不应回退到空 NW 名称")
ok(faceView.fileName == "face.json" and faceView.ctype == "unit", "定向表身份字段读取失败")
ok(faceView.attack == 2 and faceView.defense == 2, "定向表实体数值仍应读 NW")

-- 3. NW 全缺失：返回类型默认值
local bare = MakeEnt({})
local bareView = CV.Read(bare)
ok(bareView.name == "" and bareView.country == "", "缺失字符串字段应给空串")
ok(bareView.cost == 0 and bareView.actionCost == 0 and bareView.attack == 0 and bareView.defense == 0,
    "缺失数字字段应给 0")
ok(bareView.isCommand == false and bareView.isHeadquarter == false and bareView.hasKeywords == false,
    "缺失布尔字段应给 false")

-- 4. 字段永不为 nil
for _, key in ipairs(EXPECTED_KEYS) do
    ok(view[key] ~= nil, "完整实体缺少字段 " .. key)
    ok(bareView[key] ~= nil, "空实体缺少字段 " .. key)
end

-- 5. 无效实体返回全默认表
local nilView = CV.Read(nil)
for _, key in ipairs(EXPECTED_KEYS) do
    ok(nilView[key] ~= nil, "无效实体缺少字段 " .. key)
end
ok(nilView.cost == 0 and nilView.name == "" and nilView.hasKeywords == false, "无效实体字段默认值不符")

-- 6. 防回潮扫描：四个渲染文件里不得再出现卡面 NW 字面量
local FACE_KEYS = {
    "Kards_CardName", "Kards_CardNameEn", "Kards_CardFileName", "Kards_CardType",
    "Kards_CardCountry", "Kards_CardDescription", "Kards_CardKeywords",
    "Kards_CardCost", "Kards_CardActionCost", "Kards_CardAttack", "Kards_CardDefense",
    "Kards_CardIsCommand", "Kards_CardIsHeadquarter", "Kards_CardHasKeywords",
}
local RENDER_FILES = {
    "lua/kards/cl_card_text_overlay.lua",
    "lua/kards/cl_battle_keyword_icons.lua",
    "lua/entities/sent_kards_battle_table/cl_battle_convert.lua",
    "lua/entities/sent_kards_battle_table/cl_battle_hud.lua",
}
for _, path in ipairs(RENDER_FILES) do
    local fh = assert(io.open(path, "r"), "无法打开渲染文件 " .. path)
    local content = fh:read("*a")
    fh:close()
    -- 注释行允许保留历史说明，只查代码行
    local codeOnly = content:gsub("%-%-[^\n]*", "")
    for _, key in ipairs(FACE_KEYS) do
        ok(not codeOnly:find(key, 1, true), path .. " 仍出现卡面 NW 字面量 " .. key)
    end
end

print(string.format("卡面视图测试通过 %d 项", passed))
