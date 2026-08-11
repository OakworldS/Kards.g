--[[
    Kards 游戏模式 — 共享代码
    继承自 Sandbox，确保 Sandbox 全部功能可用。
    未来计划：当服务器以 Kards 为玩法模式时，自动启用全部卡牌编辑器内容。
]]

GM.Name     = "Kards"
GM.Author   = "Kards Team"

-- 继承 Sandbox 游戏模式（保留沙盒的所有功能）
DeriveGamemode("sandbox")

--[[
    以下是后续扩展预留钩子/变量，请勿删除。
    当 Kards 游戏模式激活时，将在此处注册服务器端内容加载逻辑：

    -- hook.Add("Initialize", "Kards_EnableContent", function()
    --     if SERVER then
    --         -- 启用卡牌编辑器全部内容
    --         -- 注册 net 消息
    --         -- 加载 sv_storage.lua 等服务器端模块
    --     end
    -- end)

    -- 标记当前运行在 Kards 模式
    -- KARDS_GM_ACTIVE = true
]]
