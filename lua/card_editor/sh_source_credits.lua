--[[
=======================================================================================
Kards 卡牌编辑器 素材来源名单（共享层）
=======================================================================================
客户端「关于」页的素材来源弹窗读取本表。数据来源是 e:\工作专用\关于 kards\关于页计划.md
的附录，此处硬编码一份，不在运行时读那个文档。

音乐组字段：
  author    B 站上传者昵称
  date      收藏日期（只有月日，年份为 2026）
  tracks    对应曲目，多项用顿号相连
  homepage  主页短串，形式 space.bilibili.com/<uid>
  used      是否真正进入项目。false 表示仅收藏未采用

音效组字段：
  source    来源昵称
  date      日期
  content   对应内容
  homepage  主页短串

notes 是三条声明，弹窗底部逐条显示。措辞刻意只写来源，不写「已获授权」。
=======================================================================================
]]
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}

KARDS.CardEditor.SourceCredits = {
    music = {
        { author = "風巻雪のカチューシャ",     date = "8月26日", tracks = "法国，不！莫洛托夫", homepage = "space.bilibili.com/3493122638088308" },
        { author = "可恶的安娜其",             date = "8月15日", tracks = "战斗系统上所有 Kards 风 BGM（评论区推测或为游戏内录音）", homepage = "space.bilibili.com/1650303056" },
        { author = "苍白洋甘菊-Aurora",        date = "8月15日", tracks = "We'll meet Again", homepage = "space.bilibili.com/1989100037" },
        { author = "Nimmermehr丨永不再會丨",   date = "8月15日", tracks = "德国血色玫瑰", homepage = "space.bilibili.com/304682270" },
        { author = "达科斯亚DAKOSIA",          date = "8月14日", tracks = "Suomi marssii，澳大利亚之歌", homepage = "space.bilibili.com/492028352" },
        { author = "维多利亚大秦",             date = "8月14日", tracks = "天国的军团，Over the hills and far away，Rule Britannia", homepage = "space.bilibili.com/3537111552625231" },
        { author = "甘城なつき重度依赖症",     date = "8月14日", tracks = "莫斯科 - 北京", homepage = "space.bilibili.com/674770475" },
        { author = "Hanskat_",                 date = "8月14日", tracks = "Ievan Polkka", homepage = "space.bilibili.com/3546954057386635" },
        { author = "贝亚没有蜜蜂",             date = "8月14日", tracks = "胜利日", homepage = "space.bilibili.com/2107046960" },
        { author = "Amoniako",                 date = "8月14日", tracks = "lili Marleen", homepage = "space.bilibili.com/296852332" },
        { author = "KleineMarleen",            date = "8月14日", tracks = "红浆果", homepage = "space.bilibili.com/3537117902801553" },
        { author = "网友玻璃路",               date = "8月12日", tracks = "登山缆车", homepage = "space.bilibili.com/3546835484412390" },
        { author = "东线传奇逃兵",             date = "8月12日", tracks = "To the Girl I Left Behind Me", homepage = "space.bilibili.com/3546554902252173" },
        { author = "Kiss-Keailssas",           date = "8月10日", tracks = "karjalan katjuusa", homepage = "space.bilibili.com/3546762826483989" },
        { author = "丘吉尔official",           date = "8月8日",  tracks = "英国掷弹兵进行曲", homepage = "space.bilibili.com/406263744" },
        { author = "Yvor",                     date = "8月8日",  tracks = "Waltzing Matilda", homepage = "space.bilibili.com/3546730826041957" },
        { author = "歪果仁sama",               date = "8月8日",  tracks = "莫斯科保卫者", homepage = "space.bilibili.com/3546876229978938" },
        { author = "宝马交战",                 date = "8月8日",  tracks = "Yankee Doodle，德国另一首歌，Песня о русском солдате，Священная война，Брянская улица，railway guerrilla，喀秋莎", homepage = "space.bilibili.com/3546685026339662" },
        { author = "黑见芹香",                 date = "8月8日",  tracks = "黑色的脸庞 Faccetta Nera，God Save the King", homepage = "space.bilibili.com/477936521" },
        { author = "北京姜世界",               date = "8月8日",  tracks = "那不勒斯的泰兰舞曲", homepage = "space.bilibili.com/3546620499069547" },
        { author = "尾刃康娜-志真心华",        date = "8月8日",  tracks = "维希法国赞颂贝当歌曲（Maréchal, nous voilà）", homepage = "space.bilibili.com/3546784592825080" },
        { author = "一只野生砖许矿",           date = "8月7日",  tracks = "未采用", homepage = "space.bilibili.com/3546764527274632", used = false },
        { author = "Asketen",                 date = "未记录",  tracks = "Moj karab", homepage = "space.bilibili.com/3546661777312136" },
        { author = "不开心的屑44",             date = "未记录",  tracks = "牢不可破的联盟", homepage = "space.bilibili.com/3546714839452214" }
    },

    sounds = {
        { source = "万丈光阴",     date = "3月28日",      content = "Kards 音效", homepage = "space.bilibili.com/123851088" },
        { source = "格马尔远征军", date = "2025年6月10日", content = "Kards 音效", homepage = "space.bilibili.com/3493279211457482" },
        { source = "棱礁",         date = "2023年7月24日", content = "背景音效", homepage = "space.bilibili.com/394929660" },
        { source = "风中之旗帜",   date = "2022年6月12日", content = "Kards 音效", homepage = "space.bilibili.com/30210348" }
    },

    notes = {
        "此处仅列出来源与上传者，不代表已获得再分发授权。",
        "上传者不等于权利人，收藏夹能证明来源，不能证明授权。",
        "若权利人有异议，请联系作者，会立即移除。"
    }
}
