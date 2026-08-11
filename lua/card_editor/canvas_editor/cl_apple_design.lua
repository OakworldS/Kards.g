--[[
=======================================================================================
Apple 设计系统 - 全局配色与间距常量（暗色模式）
遵循 DESIGN.md 中定义的 Apple Design Language 规范
Action Blue (#0066cc) 作为唯一的交互色
=======================================================================================
此文件自动加载于所有 cl_* 文件之前（cl_ap < cl_ca），供 canvas_editor/ 下各模块共享。
cl_apple_design（行 11~71）在所有 cl_ca_* 文件之前自动加载，确保 APPLE_* 常量全局可用。
]]
-- Apple 品牌色
APPLE_BLUE        = Color(0, 102, 204)     -- Action Blue（唯一交互色）
APPLE_BLUE_HOVER  = Color(0, 113, 227)     -- #0071e3 hover 微亮
APPLE_BLUE_DARK   = Color(41, 151, 255)    -- #2997ff 深色背景上用
APPLE_TEXT_ON_BLUE = Color(255, 255, 255)  -- 蓝色按钮/选中态上的纯白文字

-- Apple 文字色
APPLE_INK         = Color(245, 245, 247)   -- #f5f5f7 浅色文字（暗色模式正文）
APPLE_INK_MUTED   = Color(204, 204, 204)   -- #cccccc 禁用文字/法律声明
APPLE_INK_MUTED80 = Color(160, 160, 160)   -- #a0a0a0 珍珠按钮上的文字
APPLE_MUTED       = Color(204, 204, 204)   -- #cccccc 辅助文字

-- Apple 表面色
APPLE_WHITE       = Color(42, 42, 44)      -- #2a2a2c 卡片/表面底色
APPLE_PARCHMENT   = Color(39, 39, 41)      -- #272729 画布底色
APPLE_PEARL       = Color(37, 37, 39)      -- #252527 辅助表面

-- Apple 分隔线与边框
APPLE_HAIRLINE    = Color(60, 60, 62)      -- #3a3a3c 分割线/边框
APPLE_DIVIDER     = Color(68, 68, 70)      -- #444446 软分割

-- Apple 深色背景层级
APPLE_DARK_BG     = Color(39, 39, 41)      -- #272729 深色区块1
APPLE_DARK_BG2    = Color(42, 42, 44)      -- #2a2a2c 深色区块2
APPLE_DARK_BG3    = Color(37, 37, 39)      -- #252527 深色区块3
APPLE_BLACK       = Color(0, 0, 0)         -- 纯黑（仅nav使用）
APPLE_DARK_HOVER  = Color(55, 55, 57)      -- 暗色模式悬停色
APPLE_DARK_DISABLED = Color(60, 60, 65)    -- 暗色模式禁用按钮底色

-- Apple 圆角半径
APPLE_RADII = {
    none = 0,
    xs   = 5,
    sm   = 8,
    md   = 11,
    lg   = 18,
    pill = 9999,
}

-- Apple 间距系统（基于8px单位）
APPLE_SPACE = {
    xxs = 4,
    xs  = 8,
    sm  = 12,
    md  = 17,
    lg  = 24,
    xl  = 32,
    xxl = 48,
}

-- Apple 按钮阴影（仅用于产品图片）
APPLE_PRODUCT_SHADOW = {
    offsetX = 3,
    offsetY = 5,
    blur = 30,
    color = Color(0, 0, 0, 56),
}

-- 鼠标命中检测
function IsMouseIn(mx, my, rx, ry, rw, rh)
    return mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh
end
