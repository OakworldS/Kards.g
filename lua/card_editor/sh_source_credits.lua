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

notes 是弹窗底部的说明，目前只有一条：权利人有异议时移除。
=======================================================================================
]]
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}

local T = KARDS.Lang.T

KARDS.CardEditor.SourceCredits = {
    music = {
        { author = "風巻雪のカチューシャ",     date = T("editor.credits.date_aug_26"), tracks = T("editor.credits.track_france_no_molotov"), homepage = "space.bilibili.com/3493122638088308" },
        { author = T("editor.credits.author_annoying_anarchist"), date = T("editor.credits.date_aug_15"), tracks = T("editor.credits.track_all_kards_bgm"), homepage = "space.bilibili.com/1650303056" },
        { author = T("editor.credits.author_pale_chamomile_aurora"), date = T("editor.credits.date_aug_15"), tracks = "We'll meet Again", homepage = "space.bilibili.com/1989100037" },
        { author = T("editor.credits.author_nimmermehr"), date = T("editor.credits.date_aug_15"), tracks = T("editor.credits.track_german_blood_rose"), homepage = "space.bilibili.com/304682270" },
        { author = T("editor.credits.author_dakosiya"), date = T("editor.credits.date_aug_14"), tracks = T("editor.credits.track_suomi_marssii_australia"), homepage = "space.bilibili.com/492028352" },
        { author = T("editor.credits.author_victoria_daqin"), date = T("editor.credits.date_aug_14"), tracks = T("editor.credits.track_heavenly_legion"), homepage = "space.bilibili.com/3537111552625231" },
        { author = T("editor.credits.author_amagi_natsuki_addict"), date = T("editor.credits.date_aug_14"), tracks = T("editor.credits.track_moscow_beijing"), homepage = "space.bilibili.com/674770475" },
        { author = "Hanskat_",                 date = T("editor.credits.date_aug_14"), tracks = "Ievan Polkka", homepage = "space.bilibili.com/3546954057386635" },
        { author = T("editor.credits.author_beya_no_bees"), date = T("editor.credits.date_aug_14"), tracks = T("editor.credits.track_victory_day"), homepage = "space.bilibili.com/2107046960" },
        { author = "Amoniako",                 date = T("editor.credits.date_aug_14"), tracks = "lili Marleen", homepage = "space.bilibili.com/296852332" },
        { author = "KleineMarleen",            date = T("editor.credits.date_aug_14"), tracks = T("editor.credits.track_red_berries"), homepage = "space.bilibili.com/3537117902801553" },
        { author = T("editor.credits.author_netizen_glass_road"), date = T("editor.credits.date_aug_12"), tracks = T("editor.credits.track_funicular"), homepage = "space.bilibili.com/3546835484412390" },
        { author = T("editor.credits.author_eastern_front_deserter"), date = T("editor.credits.date_aug_12"), tracks = "To the Girl I Left Behind Me", homepage = "space.bilibili.com/3546554902252173" },
        { author = "Kiss-Keailssas",           date = T("editor.credits.date_aug_10"), tracks = "karjalan katjuusa", homepage = "space.bilibili.com/3546762826483989" },
        { author = T("editor.credits.author_churchill_official"), date = T("editor.credits.date_aug_8"), tracks = T("editor.credits.track_british_grenadiers"), homepage = "space.bilibili.com/406263744" },
        { author = "Yvor",                     date = T("editor.credits.date_aug_8"),  tracks = "Waltzing Matilda", homepage = "space.bilibili.com/3546730826041957" },
        { author = T("editor.credits.author_foreigner_sama"), date = T("editor.credits.date_aug_8"), tracks = T("editor.credits.track_defenders_of_moscow"), homepage = "space.bilibili.com/3546876229978938" },
        { author = T("editor.credits.author_baoma_battle"), date = T("editor.credits.date_aug_8"),  tracks = T("editor.credits.track_yankee_doodle_mix"), homepage = "space.bilibili.com/3546685026339662" },
        { author = T("editor.credits.author_kurose_serika"), date = T("editor.credits.date_aug_8"),  tracks = T("editor.credits.track_faccetta_nera"), homepage = "space.bilibili.com/477936521" },
        { author = T("editor.credits.author_beijing_ginger_world"), date = T("editor.credits.date_aug_8"),  tracks = T("editor.credits.track_neapolitan_tarantella"), homepage = "space.bilibili.com/3546620499069547" },
        { author = T("editor.credits.author_okana_kanna"), date = T("editor.credits.date_aug_8"),  tracks = T("editor.credits.track_vichy_petain_song"), homepage = "space.bilibili.com/3546784592825080" },
        { author = T("editor.credits.author_wild_brick_ore"), date = T("editor.credits.date_aug_7"),  tracks = T("editor.credits.track_not_used"), homepage = "space.bilibili.com/3546764527274632", used = false },
        { author = "Asketen",                 date = T("editor.credits.date_not_recorded"),  tracks = "Moj karab", homepage = "space.bilibili.com/3546661777312136" },
        { author = T("editor.credits.author_unhappy_scum_44"), date = T("editor.credits.date_not_recorded"),  tracks = T("editor.credits.track_unbreakable_union"), homepage = "space.bilibili.com/3546714839452214" }
    },

    sounds = {
        { source = T("editor.credits.source_eternal_time"), date = T("editor.credits.date_mar_28"), content = T("editor.credits.content_kards_sfx"), homepage = "space.bilibili.com/123851088" },
        { source = T("editor.credits.source_gemar_expedition"), date = T("editor.credits.date_2025_06_10"), content = T("editor.credits.content_kards_sfx"), homepage = "space.bilibili.com/3493279211457482" },
        { source = T("editor.credits.source_reef"), date = T("editor.credits.date_2023_07_24"), content = T("editor.credits.content_background_sfx"), homepage = "space.bilibili.com/394929660" },
        { source = T("editor.credits.source_flag_in_wind"), date = T("editor.credits.date_2022_06_12"), content = T("editor.credits.content_kards_sfx"), homepage = "space.bilibili.com/30210348" }
    },

    notes = {
        T("editor.credits.note_remove_on_request")
    }
}
