--[[
=======================================================================================
C 键菜单入口（cl_kards_context_menu.lua）
=======================================================================================
GMod 里 Q 是 spawnmenu，C 是 context menu，两者不是一套东西。

C 菜单的图标按钮来自全局列表 DesktopWindows。沙盒的
gamemodes/sandbox/gamemode/spawnmenu/contextmenu.lua 在 CreateContextMenu 时遍历该列表，
每项生成一个 80x82 的图标按钮，点击后新建一个 DFrame 并调用该项的 init(icon, window)。

所以这里只做注册，不碰 spawnmenu 库。热重载后想让按钮出现，执行 spawnmenu_reload。

图标放在 materials/kards/ui/icons/card_editor.png，建议 64x64 的 PNG。
文件不存在时退回插件图标，避免界面出现紫黑格子。
=======================================================================================
]]
if not CLIENT then return end

local ICON          = "materials/kards/ui/icons/card_editor.png"
local FALLBACK_ICON = "materials/Kards.g_The_World_War_II.png"

-- 打开或关闭卡牌编辑器，与 kards_editor 命令走同一条路
local function OpenEditor()
    local editor = KARDS and KARDS.CardEditor
    if not editor then return end
    local canvas = editor.Canvas
    if canvas and canvas.ToggleEditor then
        canvas.ToggleEditor()
    elseif editor.OpenEditor then
        editor:OpenEditor()
    end
end

list.Set("DesktopWindows", "KardsCardEditor", {
    title  = "卡牌编辑器",
    icon   = file.Exists(ICON, "GAME") and ICON or FALLBACK_ICON,
    width  = 480,
    height = 320,
    init = function(icon, window)
        -- 只需要一个入口，不需要窗口内容，关掉后直接开编辑器
        window:Close()
        OpenEditor()
    end
})
