# 所属模块

Kards .g 具有三大类模块和分模块。

- Kards 卡牌编辑器
  - 卡牌外貌属性编辑器
  - 卡牌效果编辑器
- 关于
- 战斗系统
- 组卡

每一项（包括分项）都是一个模块，你的 issue 一定涉及其中至少一个模块。

# Bug

当你在使用插件时，遇到任何本插件 lua 错误、卡牌纹理不正确，请把 lua 报错或保存的卡牌json数据与实际渲染的卡面截图贴入 issue，并具体描述当时做了什么。如果有可能，也说明你认为可能与哪个插件冲突。

完成后提 Bug 类型 issue。通常，这是处理最快，也是我最优先处理的类型。

# 建议

你认为可加入的新功能，或者可以进行性能优化的部分。

新增可扩展类别。

# 修正

> \[!IMPORTANT]
> 
> 卡牌模型动画的修正投贡献类型 issue
> 
> **预报**尚未开发完成，在开发完成前，不受理**预报**修正

如果你发现，本插件战斗系统行为、卡牌词条等规则、隐性规则（Kards 没明文写出的，例如**开发**时，手牌满了会如何）与 Kards 不符，或 Kards 推出的新版本规则未出现在插件时，提修正 issue。

虽然优先级不高，但修正类改动范围很小，通常处理很快。

> *如果你了解如何给 Gmod 导入特效和模型，可将方法通过issue告诉我并投为修正。当我了解如何给 Gmod 导入模型后，就不需要简单模型导入器的前置模组。*

# 贡献

若你确有意为本插件贡献资源，让插件更优质，请详读此文档，然后即可提贡献类 issue。

如果你贡献了加粗部分的资源，你将进入“重要贡献”名单。

- 图片。应用范围：
  - 背景图
  - 牌桌的桌布
  - 卡牌底部模板
  - **在场单位卡牌底部模板**
  - 卡背
  - 指向箭头
  - **卡牌编辑器 C 键图标**
  - **本插件封面图**
- **文字：ttf 格式等**。
- 文本：KARDS 固定聊天中各国各维度各等级的聊天固定文字表
- 音频：BGM（战斗与编辑器）和卡牌音效。
  - 音效
    - 卡牌操作音效。即当抽牌，开发，选中手牌（重新调度）时，卡牌的物理音效
    - 指令音效。
    - 反制触发音效
    - **单位阵亡音效**
    - 背景音效
  - BGM
    - **KARDS 的背景音乐，它分国家。需要了解哪一个国家**
    - [WARDS](https://qwq.wards.mom/) 的背景音乐，似乎不分国家。目前不完善
    - BGM 歌词 lrc
- **特效**
- 卡牌运动动画配置方案（能用到代码中的卡牌关键帧表）
- **卡牌动作特效**。例如
- 模型
- 轰炸机攻击时的轰炸弹药

> \[!TIP]
> 
> 文本、动画外，提供的资源是有分发权的资源，或标来源。

## 扩展

如果你为本项目制作了扩展模组，将进入“扩展贡献”名单，且会在关于页告示你的插件链接。

可扩展类别：

> \[!TIP]
> 
> 随插件更新会开放更多可扩展。如果你有新增可扩展类别的想法，并且↔可行，可提**建议 issue。**

- 编辑器 BGM 背景音乐

### 扩展方法

#### 编辑器 BGM 背景音乐

BGM 扫描开始在 [cl\_dynamic\_bgm\_compat.lua](lua\card_editor\cl_dynamic_bgm_compat.lua)。

##### 目录结构

```
kards_bgm_extra/
  sound/editor/<风格id>/<序号>.<曲名>.ogg
  data_static/kards/bgm_lyrics/<风格id>/<序号>.<曲名>.txt   （可选）
  materials/kards/flags/<风格id>.png
```

例：

```
sound/editor/finland_extra/1.Sakura.ogg
data_static/kards/bgm_lyrics/finland_extra/1.Sakura.txt
materials/kards/flags/finland_extra.png
```

要点：

- 风格 id 是文件夹名，序号决定排序，曲名在编辑器提示里。
- 歌词可选，是 LRC 文本，路径与音频镜像，同一时间戳连写两行即原文与译文。文件后缀不能是 lrc （gmad 编译不通过）。
- 音频用 OGG Vorbis，44.1kHz 立体声。文件名为 ASCII 字符。
- 扩展模组用于客户端。

曲目会被自动登记，顶栏的风格按钮来自 BGMExpandCountries。要让扩展风格按钮出现，需要注册。

```lua
-- lua/autorun/client/kards_bgm_extra.lua
local function Register()
    local editor = KARDS and KARDS.CardEditor
    local compat = editor and editor.Compat and editor.Compat.DynamicBGM
    local canvas = editor and editor.Canvas
    if not compat or not canvas or not canvas.BGMExpandCountries then
        return false
    end

    compat.RegisterCountry("finland_extra", {
        name = "芬兰（扩展）",  --风格名
        shortName = "芬",
        icon = "materials/kards/flags/finland_extra.png",
        description = "冬季战争与继续战争时期的芬兰军乐",
        color = Color(120, 160, 220),  --在选中后，按钮背面呈现的颜色
        backgroundVolume = 0.6
    })
    compat.RegisterTrack("finland_extra", "sound/editor/finland_extra/1.Sakura.ogg", "Sakura")
    return true
end

hook.Add("InitPostEntity", "KardsBgmExtra", function()
    if Register() then return end
    timer.Create("KardsBgmExtraRetry", 1, 10, function()
        if Register() then timer.Remove("KardsBgmExtraRetry") end
    end)
end)
```

RegisterCountry 与 RegisterTrack 两函数要在画布创建之后调用才有效，所以代码里带重试。`RegisterTrack` 的路径要带 `sound/` 前缀，函数会用 `file.Exists` 校验，路径不正确会在编辑器右下提示。

同一路径只登记一次，`icon` 用 `materials/` 前缀，文件不存在时退回显示 `shortName`。

音频须是拥有分发权的音频，并在注释里标注来源。

# 状态

我们约定，状态用标签表示：状态标签以特殊符号开头，一个 issue 同一时刻只存在一个。

## Open

↔ 正在进行

你的 issue 正在进行。Bug 的正在修复，建议与修正的正在实施，贡献的正在加入

‖ 暂停

你的 issue 可以并已计划进行。因为正在进行的过多或其他原因，当前尚未进行。

## Close

¶ 已完成

你的 issue 已经处理完成

Ø 已取消

你的 issue 因为某种原因，已被放弃实施

ꟿ 中断

你的 issue 在实施过程中因为某种原因，并未实现完全

Ꞡ 拒绝

你的 issue 被我拒绝实施

## Bug 类出现

### Open

‽ 待复现

这意味着我无法在我的 Gmod 复现出你遇到的问题，需要你更可能详细描述当时情况以及发生前你在做什么，以及控制台日志内容。也不排除可能是你的 Gmod 环境（订阅的插件）与我不同为缘由

## 建议类出现

### Open

‼ 推进受阻

需要数月、年级时长才可完成这个建议。意味着你的建议是庞大构想或撬动了底层极限，需要底层重构的建议

### Close

₲ 无法完成

你的建议合理，可行，但改动面过于庞大，或触达 Glua 功能极限，以我的能力无法完成。

₼ 不可行

建议看起来不可行，没有可具体改动的地方。需要更加具体的实施建议

## 修正类出现

### Open

ᵺ 无从考证

你描述的修正我找不到，并没有在 Kards 观察和发现这个规则或操作存在。建议你提供视频查看

### Close

₭ 错误修正

据我在 Kards 的观察或你的确认，你描述的修正与 Kards 明确不符合。虽然未实施，但也确保了相关该 issue 提及的规则的准确性
