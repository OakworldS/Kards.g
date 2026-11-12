--[[
=======================================================================================
Kards 卡牌编辑器 贡献者名单（共享层）
=======================================================================================
客户端「关于」页的贡献者卡读取本表，三组与 docs/CONTRIBUTING.md 的三类贡献一一对应：

  extensions  扩展贡献。横向排格，两行可见，多出的行用滚轮查看。
              url 填这位作者制作的其中一个扩展链接
  important   重要贡献。左栏竖排，五行可见。url 填作者个人主页
  regular     贡献。右栏竖排，五行可见。url 填作者个人主页

新增一位贡献者：
  1. 头像放到 materials/kards/ui/avatars/ 下，正方形，建议 128x128，png 或 jpg
  2. 在对应数组末尾追加一项：
       { name = "显示名", avatar = "materials/kards/ui/avatars/xxx.png",
         url = "https://...", note = "可选的一行说明" }
  3. extensions 的 note 建议写扩展名，显示在作者名下方；其余两组可留空
  4. url 必须写完整地址（带 http 或 https）。点击后用系统默认浏览器或 Steam 内置浏览器打开
  5. 三组都允许为空，为空时显示「暂无贡献」

「重要贡献」与「贡献」各只绘制前五行，超出的部分不显示。
=======================================================================================
]]
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}

KARDS.CardEditor.Contributors = {
    extensions = {},
    important = {},
    regular = {}
}
