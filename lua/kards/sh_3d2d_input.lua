--[[
    虚拟 3D2D 输入框通用模块 (3D2D Input Box)

    在牌桌平面内渲染一个半透明矩形输入框，所有玩家实时看到输入的文本。
    点击输入框时，客户端在投影屏幕坐标创建 DTextEntry 进行实际输入，
    输入内容经服务端广播给所有客户端。

    实例：
      KARDS.Input3D2D.Instances[tableID] = {
          owner = slot,         -- 输入者槽位（可输入）
          text = "",            -- 当前文本
          pos  = Vector(...),   -- 3D2D 位置（牌桌局部）
          ang  = Angle(...),    -- 3D2D 角度
          scale = 0.02,         -- 3D2D 缩放
          width  = 200,         -- 像素宽度
          height = 44,          -- 像素高度
          maxChars = 6,         -- 最大字符数
          placeholder = "搜索", -- 占位文字
          active = true,        -- 是否活跃
      }

    方法：
      KARDS.Input3D2D:Create(tableID, config)  → 创建输入框实例
      KARDS.Input3D3D:Destroy(tableID)          → 销毁实例
      KARDS.Input3D3D:SetText(tableID, text)    → 更新文本
      KARDS.Input3D3D:GetText(tableID)          → 获取文本
]]

KARDS = KARDS or {}
KARDS.Input3D2D = KARDS.Input3D2D or {}
KARDS.Input3D2D.Instances = KARDS.Input3D2D.Instances or {}

--- 创建 3D2D 输入框实例
-- @param tableID string 牌桌唯一标识符
-- @param config  table 配置表：
--   owner      = number 输入者槽位（nil 则无人可输入）
--   pos        = Vector 牌桌局部坐标
--   ang        = Angle 牌桌局部角度（缺省自动计算平面朝上）
--   scale      = number 3D2D 缩放（缺省 0.02）
--   width      = number 像素宽度（缺省 200）
--   height     = number 像素高度（缺省 44）
--   maxChars   = number 最大字符数（缺省 6）
--   placeholder= string 占位文字（缺省空）
-- @return table 创建的实例
function KARDS.Input3D2D:Create(tableID, config)
    config = config or {}
    self.Instances[tableID] = {
        owner       = config.owner,
        text        = config.text or "",
        pos         = config.pos,
        ang         = config.ang,
        scale       = config.scale or 0.02,
        width       = config.width or 200,
        height      = config.height or 44,
        maxChars    = config.maxChars or 6,
        placeholder = config.placeholder or "",
        active      = true,
    }
    return self.Instances[tableID]
end

--- 销毁 3D2D 输入框实例
function KARDS.Input3D2D:Destroy(tableID)
    self.Instances[tableID] = nil
end

--- 更新实例文本（自动截断至 maxChars）
function KARDS.Input3D2D:SetText(tableID, text)
    local inst = self.Instances[tableID]
    if inst then
        inst.text = tostring(text or ""):sub(1, inst.maxChars)
    end
end

--- 获取实例文本
function KARDS.Input3D2D:GetText(tableID)
    local inst = self.Instances[tableID]
    return inst and inst.text or ""
end

--- 获取实例
function KARDS.Input3D2D:Get(tableID)
    return self.Instances[tableID]
end