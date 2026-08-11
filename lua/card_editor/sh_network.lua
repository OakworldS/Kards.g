-- Kards 卡牌编辑器网络管理
-- 共享文件，服务端和客户端都会执行

KARDS.CardEditor.Core = KARDS.CardEditor.Core or {}

-- 网络管理
KARDS.CardEditor.Core.Network = {
    -- 发送消息（使用 net.WriteTable 确保数据顺序一致）
    SendMessage = function(ply, messageType, data)
        if SERVER then
            net.Start(messageType)
            net.WriteTable(data or {})
            net.Send(ply)
        end
    end,
    
    -- 广播消息（使用 net.WriteTable 确保数据顺序一致）
    BroadcastMessage = function(messageType, data)
        if SERVER then
            net.Start(messageType)
            net.WriteTable(data or {})
            net.Broadcast()
        end
    end
}
