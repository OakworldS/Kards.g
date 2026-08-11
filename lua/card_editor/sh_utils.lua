-- Kards 卡牌编辑器通用工具函数
-- 共享文件，服务端和客户端都会执行

KARDS.CardEditor.Core = KARDS.CardEditor.Core or {}

-- 添加string.EndsWith函数
if not string.EndsWith then
    function string.EndsWith(str, suffix)
        return suffix == "" or string.sub(str, -#suffix) == suffix
    end
end

-- 工具函数
KARDS.CardEditor.Core.Utils = {
    -- 生成唯一ID
    GenerateID = function()
        return util.CRC(os.time() .. math.random() .. SysTime())
    end,
    
    -- 深拷贝
    DeepCopy = function(tbl)
        if type(tbl) ~= "table" then return tbl end
        local copy = {}
        for k, v in pairs(tbl) do
            copy[k] = KARDS.CardEditor.Core.Utils.DeepCopy(v)
        end
        return copy
    end,
    
    -- 表格合并
    TableMerge = function(tbl1, tbl2)
        for k, v in pairs(tbl2) do
            if type(v) == "table" and type(tbl1[k]) == "table" then
                KARDS.CardEditor.Core.Utils.TableMerge(tbl1[k], v)
            else
                tbl1[k] = v
            end
        end
        return tbl1
    end,
    
    -- 格式化时间
    FormatTime = function(timestamp)
        return os.date("%Y-%m-%d %H:%M:%S", timestamp)
    end,
    
    -- 验证文件路径
    ValidateFilePath = function(path)
        return path and string.len(path) > 0
    end,
    
    -- 获取文件扩展名
    GetFileExtension = function(path)
        return string.match(path, "%.([^%.]+)$")
    end,
    
    -- 检查是否为图片文件
    IsImageFile = function(path)
        local ext = KARDS.CardEditor.Core.Utils.GetFileExtension(path)
        if not ext then return false end
        local imageExts = { "jpg", "jpeg", "png", "gif", "bmp", "tga" }
        return table.HasValue(imageExts, string.lower(ext))
    end,
    
    -- 通用类型名称查找
    GetTypeName = function(lookupTable, typeKey, defaultName)
        return lookupTable[typeKey] or defaultName
    end
}
