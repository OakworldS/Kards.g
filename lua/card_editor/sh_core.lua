-- Kards 卡牌编辑器核心共享代码
-- 共享文件，包含工具函数和核心逻辑

KARDS.CardEditor.Core = KARDS.CardEditor.Core or {}

-- 工具函数（定义于 sh_utils.lua）
-- 网络管理（定义于 sh_network.lua）

-- 卡牌管理
KARDS.CardEditor.Core.CardManager = {
    -- 创建新卡牌
    CreateCard = function()
        return KARDS.CardEditor.Data:CreateCardData()
    end,
    
    -- 复制卡牌
    CopyCard = function(cardData)
        local copy = KARDS.CardEditor.Core.Utils.DeepCopy(cardData)
        copy.id = KARDS.CardEditor.Core.Utils.GenerateID()
        copy.name = copy.name .. " (Copy)"
        copy.createdAt = os.time()
        copy.updatedAt = os.time()
        return copy
    end,
    
    -- 更新卡牌
    UpdateCard = function(cardData, updates)
        return KARDS.CardEditor.Core.Utils.TableMerge(cardData, updates)
    end,
    
    -- 验证卡牌
    ValidateCard = function(cardData)
        return KARDS.CardEditor.Data:ValidateCardData(cardData)
    end
}

-- 节点管理
KARDS.CardEditor.Core.NodeManager = {
    -- 创建节点
    CreateNode = function(nodeType, position)
        local node = KARDS.CardEditor.Data:CreateNodeData()
        node.type = nodeType
        node.position = position or Vector(0, 0, 0)
        node.name = KARDS.CardEditor.Core.NodeManager.GetNodeTypeName(nodeType)
        return node
    end,
    
    -- 获取节点类型名称
    GetNodeTypeName = function(nodeType)
        local names = {
            [KARDS.CardEditor.Data.NodeTypes.PROPERTY] = "Property",
            [KARDS.CardEditor.Data.NodeTypes.TRIGGER] = "Trigger",
            [KARDS.CardEditor.Data.NodeTypes.CONDITION] = "Condition",
            [KARDS.CardEditor.Data.NodeTypes.EFFECT] = "Effect"
        }
        return KARDS.CardEditor.Core.Utils.GetTypeName(names, nodeType, "Node")
    end,
    
    -- 执行节点
    ExecuteNode = function(node, cardData)
        -- 这里会在客户端实现具体的节点执行逻辑
    end
}

-- 效果管理
KARDS.CardEditor.Core.EffectManager = {
    -- 创建效果
    CreateEffect = function()
        return KARDS.CardEditor.Data:CreateEffectData()
    end,
    
    -- 获取效果类型名称
    GetEffectTypeName = function(effectType)
        local names = {
            [KARDS.CardEditor.Data.EffectTypes.DAMAGE] = "Damage",
            [KARDS.CardEditor.Data.EffectTypes.HEAL] = "Heal",
            [KARDS.CardEditor.Data.EffectTypes.BUFF] = "Buff",
            [KARDS.CardEditor.Data.EffectTypes.DEBUFF] = "Debuff",
            [KARDS.CardEditor.Data.EffectTypes.DRAW] = "Draw",
            [KARDS.CardEditor.Data.EffectTypes.DISCARD] = "Discard",
            [KARDS.CardEditor.Data.EffectTypes.SUMMON] = "Summon",
            [KARDS.CardEditor.Data.EffectTypes.DESTROY] = "Destroy"
        }
        return KARDS.CardEditor.Core.Utils.GetTypeName(names, effectType, "Effect")
    end
}

-- 触发管理
KARDS.CardEditor.Core.TriggerManager = {
    -- 创建触发
    CreateTrigger = function()
        return KARDS.CardEditor.Data:CreateTriggerData()
    end,
    
    -- 获取触发类型名称
    GetTriggerTypeName = function(triggerType)
        local names = {
            [KARDS.CardEditor.Data.TriggerTypes.ON_PLAY] = "On Play",
            [KARDS.CardEditor.Data.TriggerTypes.ON_ATTACK] = "On Attack",
            [KARDS.CardEditor.Data.TriggerTypes.ON_DEFEND] = "On Defend",
            [KARDS.CardEditor.Data.TriggerTypes.ON_DEATH] = "On Death",
            [KARDS.CardEditor.Data.TriggerTypes.ON_TURN_START] = "On Turn Start",
            [KARDS.CardEditor.Data.TriggerTypes.ON_TURN_END] = "On Turn End",
            [KARDS.CardEditor.Data.TriggerTypes.ON_DRAW] = "On Draw",
            [KARDS.CardEditor.Data.TriggerTypes.ON_DEPLOY] = "On Deploy",
            [KARDS.CardEditor.Data.TriggerTypes.ON_JOIN_BATTLE] = "On Join Battle",
            [KARDS.CardEditor.Data.TriggerTypes.REALTIME] = "Realtime"
        }
        return KARDS.CardEditor.Core.Utils.GetTypeName(names, triggerType, "Trigger")
    end
}

-- 初始化
function KARDS.CardEditor.Core:Initialize()
    KARDS.CardEditor:Log("Core initialized", "DEBUG")
end

-- 当 Lua 初始化时执行
KARDS.CardEditor.Core:Initialize()
