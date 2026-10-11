--[[
    伪用户控制台彩色输出接收（2026-09-13）

    服务端 sv_fakeuser.lua 经 KardsFakeUserPrint 下发彩色文本片段
    （WriteUInt 片段数，逐段 WriteColor + WriteString），客户端 MsgC 打印到
    玩家自己的控制台。无游戏内 UI，仅控制台。
]]

net.Receive("KardsFakeUserPrint", function()
    local n = net.ReadUInt(8)
    local pieces = {}
    for i = 1, n do
        pieces[#pieces + 1] = net.ReadColor()
        pieces[#pieces + 1] = net.ReadString()
    end
    MsgC(unpack(pieces))
end)
