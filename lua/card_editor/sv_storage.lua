-- Kards 卡牌编辑器服务端存储系统
-- 服务端文件，处理卡牌数据的存储和管理
-- 使用与客户端相同的目录结构（card_editor/cards/）

KARDS.CardEditor.Storage = KARDS.CardEditor.Storage or {}

local CARDS_DIR = "card_editor/cards"

-- 确保存储目录存在
function KARDS.CardEditor.Storage:EnsureDirectory()
    if not file.Exists(CARDS_DIR, "DATA") then
        file.CreateDir(CARDS_DIR)
    end
end

-- 保存卡牌（使用与客户端一致的完整 CardAppearance 格式）
function KARDS.CardEditor.Storage:SaveCard(cardData)
    self:EnsureDirectory()

    local filePath = CARDS_DIR .. "/" .. (cardData.id or tostring(os.time())) .. ".json"
    local jsonData = util.TableToJSON(cardData, true)

    file.Write(filePath, jsonData)
    KARDS.CardEditor:Log("Saved card: " .. (cardData.name or "unnamed") .. " (" .. (cardData.id or "?") .. ")", "DEBUG")
    return true
end

-- 加载卡牌
function KARDS.CardEditor.Storage:LoadCard(cardId)
    local filePath = CARDS_DIR .. "/" .. cardId .. ".json"

    if not file.Exists(filePath, "DATA") then
        KARDS.CardEditor:Log("Card not found: " .. cardId, "WARNING")
        return nil
    end

    local jsonData = file.Read(filePath, "DATA")
    local cardData = util.JSONToTable(jsonData)

    if cardData then
        KARDS.CardEditor:Log("Loaded card: " .. (cardData.name or "unnamed") .. " (" .. cardId .. ")", "DEBUG")
    end

    return cardData
end

-- 删除卡牌
function KARDS.CardEditor.Storage:DeleteCard(cardId)
    local filePath = CARDS_DIR .. "/" .. cardId .. ".json"

    if file.Exists(filePath, "DATA") then
        file.Delete(filePath)
        KARDS.CardEditor:Log("Deleted card: " .. cardId, "DEBUG")
        return true
    end

    KARDS.CardEditor:Log("Card not found for deletion: " .. cardId, "WARNING")
    return false
end

-- 获取所有卡牌列表
function KARDS.CardEditor.Storage:GetCardList()
    self:EnsureDirectory()

    local files = file.Find(CARDS_DIR .. "/*.json", "DATA")
    local cardList = {}

    for _, fileName in ipairs(files or {}) do
        local filePath = CARDS_DIR .. "/" .. fileName
        local jsonData = file.Read(filePath, "DATA")
        local cardData = jsonData and util.JSONToTable(jsonData)
        if cardData then
            local app = cardData.cardAppearance or cardData
            table.insert(cardList, {
                id = fileName,
                name = app.name or "Unnamed",
                cost = app.cost or 0,
                createdAt = cardData.savedAt or "unknown",
                updatedAt = cardData.savedAt or "unknown"
            })
        end
    end

    table.sort(cardList, function(a, b)
        return a.updatedAt > b.updatedAt
    end)

    return cardList
end

-- 清理cardId防止路径遍历
local function SanitizeCardId(cardId)
    if not cardId or type(cardId) ~= "string" then return nil end
    cardId = string.gsub(cardId, "%.%.", "")
    cardId = string.gsub(cardId, "[/\\]", "")
    cardId = string.gsub(cardId, ":", "")
    return cardId
end

-- 检查玩家是否有权限编辑卡牌
local function HasEditPermission(ply)
    if not IsValid(ply) then return false end
    return ply:IsAdmin() or ply:IsSuperAdmin()
end

-- 网络消息处理
if SERVER then
    -- 保存卡牌
    net.Receive("KARDS_Editor_SaveCard", function(len, ply)
        if not HasEditPermission(ply) then
            net.Start("KARDS_Editor_SaveCard")
                net.WriteBool(false)
                net.WriteString("Permission denied")
            net.Send(ply)
            return
        end

        local cardJson = net.ReadString()
        local cardData = util.JSONToTable(cardJson)
        if not cardData then
            net.Start("KARDS_Editor_SaveCard")
                net.WriteBool(false)
                net.WriteString("Invalid card data")
            net.Send(ply)
            return
        end

        local cardId = cardData.id or tostring(os.time())
        cardData.id = SanitizeCardId(cardId)
        if not cardData.id then
            net.Start("KARDS_Editor_SaveCard")
                net.WriteBool(false)
                net.WriteString("Invalid card ID")
            net.Send(ply)
            return
        end

        cardData.savedAt = os.date("%Y-%m-%d %H:%M")
        KARDS.CardEditor.Storage:SaveCard(cardData)

        net.Start("KARDS_Editor_SaveCard")
            net.WriteBool(true)
            net.WriteString("Card saved successfully")
            net.WriteTable(cardData)
        net.Send(ply)
    end)

    -- 加载卡牌
    net.Receive("KARDS_Editor_LoadCard", function(len, ply)
        local cardId = SanitizeCardId(net.ReadString())
        if not cardId then
            net.Start("KARDS_Editor_LoadCard")
                net.WriteBool(false)
                net.WriteString("Invalid card ID")
            net.Send(ply)
            return
        end

        local cardData = KARDS.CardEditor.Storage:LoadCard(cardId)

        net.Start("KARDS_Editor_LoadCard")
            if cardData then
                net.WriteBool(true)
                net.WriteTable(cardData)
            else
                net.WriteBool(false)
                net.WriteString("Card not found")
            end
        net.Send(ply)
    end)

    -- 删除卡牌
    net.Receive("KARDS_Editor_DeleteCard", function(len, ply)
        if not HasEditPermission(ply) then
            net.Start("KARDS_Editor_DeleteCard")
                net.WriteBool(false)
                net.WriteString("Permission denied")
            net.Send(ply)
            return
        end

        local cardId = SanitizeCardId(net.ReadString())
        if not cardId then
            net.Start("KARDS_Editor_DeleteCard")
                net.WriteBool(false)
                net.WriteString("Invalid card ID")
            net.Send(ply)
            return
        end

        local success = KARDS.CardEditor.Storage:DeleteCard(cardId)

        net.Start("KARDS_Editor_DeleteCard")
            net.WriteBool(success)
            net.WriteString(success and "Card deleted successfully" or "Card not found")
        net.Send(ply)
    end)

    -- 获取卡牌列表
    net.Receive("KARDS_Editor_CardList", function(len, ply)
        local cardList = KARDS.CardEditor.Storage:GetCardList()

        net.Start("KARDS_Editor_CardList")
            net.WriteTable(cardList)
        net.Send(ply)
    end)
end
