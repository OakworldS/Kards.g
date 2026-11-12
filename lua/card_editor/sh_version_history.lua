--[[
=======================================================================================
Kards 卡牌编辑器 版本历史数据（共享层）
=======================================================================================
客户端「关于」页读取本表，用于绘制数轴版本时间线。服务端不读，但放在共享层便于日后
控制台命令或启动横幅复用同一份数据。

字段说明：
  id        机器可读版本串，例如 "0.1.0-alpha"，供排查与日后兼容判断
  stage     阶段，取值 Alpha / Beta / Release，决定时间线节点的形状与徽章填充
  display   界面显示的人话名，例如 "Alpha 1"
  short     时间轴书签上的简称，两到三个字，收起时只显示它，悬停时向右展开完整 title
  date      版本日期，格式 YYYY-MM-DD
  title     一行标题。书签展开时显示它，受卡片宽度限制可能被裁切，完整内容始终由悬停面板给出
  notes     要点数组，每条一句话，写「做了什么」而不是「提升了什么」
  milestone 对应的开发日志里程碑名，不显示给玩家，仅用于和日志对账
  tags      可选，字符串数组。目前只识别 "Server"，命中时关于页会显示 Serve 标签
  shot      可选，项目截图材质路径。鼠标停在时间轴对应节点上时浮出预览，
            例如 "materials/kards/ui/about/alpha2.png"；不写则不浮出。
            原图不必预先裁成 16:9，悬停面板按容纳样式等比缩进图框，整张图都在。
            按文件内容认格式，PNG 与 JPEG 都能量出原始比例，扩展名不作数

当前版本取数组最后一项。版本串的真源仍是 sh_card_editor_loader.lua 的
KARDS.CardEditor.Version，本表只描述历史，不重复定义当前版本。
=======================================================================================
]]
KARDS = KARDS or {}
KARDS.CardEditor = KARDS.CardEditor or {}

local T = KARDS.Lang.T

KARDS.CardEditor.VersionHistory = {
    {
        id        = "0.1.0-alpha",
        stage     = "Alpha",
        display   = "Alpha 1",
        short     = T("editor.version.alpha1_short"),
        date      = "2026-04-25",
        title     = T("editor.version.alpha1_title"),
        notes     = {
            T("editor.version.alpha1_note1"),
            T("editor.version.alpha1_note2"),
            T("editor.version.alpha1_note3"),
            T("editor.version.alpha1_note4"),
            T("editor.version.alpha1_note5")
        },
        milestone = "第一阶段起步"
    },
    {
        id        = "0.2.0-alpha",
        stage     = "Alpha",
        display   = "Alpha 2",
        short     = "INE",
        date      = "2026-06-28",
        title     = T("editor.version.alpha2_title"),
        notes     = {
            T("editor.version.alpha2_note1"),
            T("editor.version.alpha2_note2"),
            T("editor.version.alpha2_note3")
        },
        milestone = "编辑器重构 7.5"
    },
    {
        id        = "0.3.0-alpha",
        stage     = "Alpha",
        display   = "Alpha 3",
        short     = T("editor.version.alpha3_short"),
        date      = "2026-08-03",
        title     = T("editor.version.alpha3_title"),
        notes     = {
            T("editor.version.alpha3_note1"),
            T("editor.version.alpha3_note2"),
            T("editor.version.alpha3_note3")
        },
        milestone = "暑假前半场"
    },
    {
        id        = "0.4.0-alpha",
        stage     = "Alpha",
        display   = "Alpha 4",
        short     = T("editor.version.alpha4_short"),
        date      = "2026-08-15",
        title     = T("editor.version.alpha4_title"),
        notes     = {
            T("editor.version.alpha4_note1"),
            T("editor.version.alpha4_note2"),
            T("editor.version.alpha4_note3"),
            T("editor.version.alpha4_note4")
        },
        milestone = "暑假后半场"
    },
    {
        id        = "0.5.0-alpha",
        stage     = "Alpha",
        display   = "Alpha 5",
        short     = T("editor.version.alpha5_short"),
        date      = "2026-10-03",
        title     = T("editor.version.alpha5_title"),
        notes     = {
            T("editor.version.alpha5_note1"),
            T("editor.version.alpha5_note2"),
            T("editor.version.alpha5_note3")
        },
        milestone = "国庆"
    },
    {
        -- 首次发布刻度：版本号沿用 Alpha 5，id 加 -publish 只为与上一刻度区分，不代表新版本
        id        = "0.5.0-alpha-publish",
        stage     = "Alpha",
        display   = "Alpha 5",
        short     = T("editor.version.release_short"),
        date      = "2026-11-12",
        title     = T("editor.version.release_title"),
        notes     = {
            T("editor.version.release_note1"),
            T("editor.version.release_note2"),
            T("editor.version.release_note3")
        },
        milestone = "首次发布"
    }
}

--[[
五条时间线。版本条目是轴上的主刻度，这五条线是轴上按颜色区分的阶段点。
  name    用于图例与悬停面板，控制在五个字以内；完整叫法写在版本条目的要点里
  color   需要五色在深色底上互相可分
  points  按时间顺序排列。单日写 date，一段密集期写 from 与 to（同格式），
          点画在时段中点；label 不超过十字，可选 notes 数组供悬停面板逐条展开说明。
          截图不写在数据里，路径由轨道 id 与日期推出：materials/kards/ui/about/
          <轨道 id>_<日期>.png，日期取 date 或时段点的 from，去掉连字符。
          图片不必预先裁成 16:9，悬停面板按容纳样式等比缩进图框，整张图都在。
          按规则推到的那张图不存在时，悬停面板只少播一段图片动画，其余三段照常
数据来源是 development log.md 的逐条时间戳，另参照测试版开发历史.md 与 Rec.md。
战斗线在 2026-08-05 之前完全没有记录；节点线与外貌线在 05-05 至 06-25 只有一份
6-25 补记，其余区间无记录。B 站线来自自媒体运营记录，独立于开发进度。
]]
KARDS.CardEditor.TimelineTracks = {
    {
        id = "node", name = T("editor.version.track_node_name"), color = Color(0, 102, 204),
        points = {
            { date = "2026-04-25", label = T("editor.version.node_label1"),
              notes = {
                  T("editor.version.node1_note1"),
                  T("editor.version.node1_note2"),
                  T("editor.version.node1_note3")
              }
            },
            { date = "2026-05-01", label = T("editor.version.node_label2"),
              notes = {
                  T("editor.version.node2_note1"),
                  T("editor.version.node2_note2"),
                  T("editor.version.node2_note3")
              }
            },
            { date = "2026-05-10", label = T("editor.version.node_label3"),
              notes = {
                  T("editor.version.node3_note1"),
                  T("editor.version.node3_note2"),
                  T("editor.version.node3_note3")
              }
            },
            { from = "2026-06-26", to = "2026-06-28", label = T("editor.version.node_label4"),
              notes = {
                  T("editor.version.node4_note1"),
                  T("editor.version.node4_note2"),
                  T("editor.version.node4_note3"),
                  T("editor.version.node4_note4"),
                  T("editor.version.node4_note5"),
                  T("editor.version.node4_note6"),
                  T("editor.version.node4_note7")
              }
            },
            { date = "2026-07-23", label = T("editor.version.node_label5"),
              notes = {
                  T("editor.version.node5_note1"),
                  T("editor.version.node5_note2"),
                  T("editor.version.node5_note3")
              }
            },
            { date = "2026-08-09", label = T("editor.version.node_label6"),
              notes = {
                  T("editor.version.node6_note1"),
                  T("editor.version.node6_note2"),
                  T("editor.version.node6_note3")
              }
            }
        }
    },
    {
        id = "look", name = T("editor.version.track_look_name"), color = Color(60, 190, 180),
        points = {
            { date = "2026-05-02", label = T("editor.version.look_label1"),
              notes = {
                  T("editor.version.look1_note1"),
                  T("editor.version.look1_note2"),
                  T("editor.version.look1_note3")
              }
            },
            { date = "2026-06-25", label = T("editor.version.look_label2"),
              notes = {
                  T("editor.version.look2_note1"),
                  T("editor.version.look2_note2")
              }
            },
            { date = "2026-06-27", label = T("editor.version.look_label3"),
              notes = {
                  T("editor.version.look3_note1"),
                  T("editor.version.look3_note2"),
                  T("editor.version.look3_note3")
              }
            },
            -- 6-30 的锚点据 .trae/documents/外观编辑器书签系统重写计划.md：该计划开篇把自绘四象限称作当前状态
            { date = "2026-06-30", label = T("editor.version.look_label4"),
              notes = {
                  T("editor.version.look4_note1"),
                  T("editor.version.look4_note2"),
                  T("editor.version.look4_note3")
              }
            },
            { date = "2026-08-05", label = T("editor.version.look_label5"),
              notes = {
                  T("editor.version.look5_note1"),
                  T("editor.version.look5_note2"),
                  T("editor.version.look5_note3")
              }
            },
            { date = "2026-08-08", label = T("editor.version.look_label6"),
              notes = {
                  T("editor.version.look6_note1"),
                  T("editor.version.look6_note2"),
                  T("editor.version.look6_note3")
              }
            },
            { date = "2026-08-14", label = T("editor.version.look_label7"),
              notes = {
                  T("editor.version.look7_note1"),
                  T("editor.version.look7_note2")
              }
            }
        }
    },
    {
        id = "battle", name = T("editor.version.track_battle_name"), color = Color(215, 90, 90),
        points = {
            -- 8 月 5 日至 11 日六天连做，五个点在轴上会挤成一团，并成一个时间段点，
            -- 在悬停面板里逐日写清这几天各自做了什么
            { from = "2026-08-05", to = "2026-08-11", label = T("editor.version.battle_label1"),
              notes = {
                  T("editor.version.battle1_note1"),
                  T("editor.version.battle1_note2"),
                  T("editor.version.battle1_note3"),
                  T("editor.version.battle1_note4"),
                  T("editor.version.battle1_note5"),
                  T("editor.version.battle1_note6")
              }
            },
            { date = "2026-08-15", label = T("editor.version.battle_label2"),
              notes = {
                  T("editor.version.battle2_note1"),
                  T("editor.version.battle2_note2"),
                  T("editor.version.battle2_note3")
              }
            },
            { date = "2026-09-26", label = T("editor.version.battle_label3"),
              notes = {
                  T("editor.version.battle3_note1"),
                  T("editor.version.battle3_note2")
              }
            }
        }
    },
    {
        id = "life", name = T("editor.version.track_life_name"), color = Color(170, 140, 210),
        points = {
            { date = "2026-04-25", label = T("editor.version.life_label1"),
              notes = {
                  T("editor.version.life1_note1"),
                  T("editor.version.life1_note2"),
                  T("editor.version.life1_note3")
              }
            },
            { date = "2026-05-01", label = T("editor.version.life_label2"),
              notes = {
                  T("editor.version.life2_note1"),
                  T("editor.version.life2_note2"),
                  T("editor.version.life2_note3")
              }
            },
            { date = "2026-05-05", label = T("editor.version.life_label3"),
              notes = {
                  T("editor.version.life3_note1"),
                  T("editor.version.life3_note2"),
                  T("editor.version.life3_note3")
              }
            },
            { from = "2026-05-08", to = "2026-05-30", label = T("editor.version.life_label4"),
              notes = {
                  T("editor.version.life4_note1"),
                  T("editor.version.life4_note2")
              }
            },
            { date = "2026-06-24", label = T("editor.version.life_label5"),
              notes = {
                  T("editor.version.life5_note1"),
                  T("editor.version.life5_note2"),
                  T("editor.version.life5_note3")
              }
            },
            { date = "2026-07-08", label = T("editor.version.life_label6"),
              notes = {
                  T("editor.version.life6_note1"),
                  T("editor.version.life6_note2"),
                  T("editor.version.life6_note3")
              }
            },
            { date = "2026-07-13", label = T("editor.version.life_label7"),
              notes = {
                  T("editor.version.life7_note1"),
                  T("editor.version.life7_note2"),
                  T("editor.version.life7_note3")
              }
            },
            { date = "2026-08-05", label = T("editor.version.life_label8"),
              notes = {
                  T("editor.version.life8_note1"),
                  T("editor.version.life8_note2"),
                  T("editor.version.life8_note3"),
                  T("editor.version.life8_note4")
              }
            },
            { date = "2026-08-18", label = T("editor.version.life_label9"),
              notes = {
                  T("editor.version.life9_note1"),
                  T("editor.version.life9_note2"),
                  T("editor.version.life9_note3"),
                  T("editor.version.life9_note4"),
                  T("editor.version.life9_note5"),
                  T("editor.version.life9_note6"),
                  T("editor.version.life9_note7")
              }
            },
            { date = "2026-09-01", label = T("editor.version.life_label10"),
              notes = {
                  T("editor.version.life10_note1"),
                  T("editor.version.life10_note2"),
                  T("editor.version.life10_note3")
              }
            },
            { date = "2026-09-25", label = T("editor.version.life_label11"),
              notes = {
                  T("editor.version.life11_note1"),
                  T("editor.version.life11_note2"),
                  T("editor.version.life11_note3")
              }
            },
            { date = "2026-10-01", label = T("editor.version.life_label12"),
              notes = {
                  T("editor.version.life12_note1"),
                  T("editor.version.life12_note2")
              }
            }
        }
    },
    {
        id = "bili", name = T("editor.version.track_bili_name"), color = Color(240, 180, 70),
        points = {
            { date = "2026-07-01", label = T("editor.version.bili_label1"),
              notes = {
                  T("editor.version.bili1_note1"),
                  T("editor.version.bili1_note2"),
                  T("editor.version.bili1_note3")
              }
            },
            { date = "2026-07-08", label = T("editor.version.bili_label2"),
              notes = {
                  T("editor.version.bili2_note1"),
                  T("editor.version.bili2_note2")
              }
            },
            { date = "2026-07-30", label = T("editor.version.bili_label3"),
              notes = {
                  T("editor.version.bili3_note1"),
                  T("editor.version.bili3_note2")
              }
            },
            { date = "2026-08-18", label = T("editor.version.bili_label4"),
              notes = {
                  T("editor.version.bili4_note1"),
                  T("editor.version.bili4_note2")
              }
            },
            { date = "2026-09-30", label = T("editor.version.bili_label5"),
              notes = {
                  T("editor.version.bili5_note1"),
                  T("editor.version.bili5_note2"),
                  T("editor.version.bili5_note3"),
                  T("editor.version.bili5_note4"),
                  T("editor.version.bili5_note5")
              }
            },
            { date = "2026-10-17", label = T("editor.version.bili_label6"),
              notes = {
                  T("editor.version.bili6_note1"),
                  T("editor.version.bili6_note2"),
                  T("editor.version.bili6_note3"),
                  T("editor.version.bili6_note4")
              }
            }
        }
    }
}
