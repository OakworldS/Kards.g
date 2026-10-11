-- 指定（Specify）通用操作模块
-- ====================================================================
-- 「指定」是一种选择卡牌的操作，未来战斗系统 UI 提供两种指定方式：
--   指定手牌（HandCard）：由「重新调度」与「指定 N 张牌」（洗入等）使用；
--     未来 UI：弹出选择面板，玩家点击手牌选择后按「确定」提交。
--   指定目标（Target）：由「指定一个……」调取（target_selector「指向一个」等）；
--     未来 UI：该卡牌与鼠标之间创建箭头，指向选定目标，不能指向的目标显示为黑白。
-- 两个指定为通用操作，供任意模板/系统复用（shuffleInto / target_selector /
-- 重新调度等）。本模块只负责「选择」并返回结果，不产生副作用（不移除、不移动卡牌），
-- 后续操作（洗入、弃掉、造成伤害等）由调用方执行。
-- 骨架阶段无 UI：选择结果经 picker 注入（测试注入 / 未来 UI 回调提交），
-- 缺省采用确定性骨架策略（手牌取前 count 张 / 候选取第一张）。
-- 依赖：KARDS.Deck（GetHand）—— 加载顺序位于 sh_deck.lua 之后。
-- ====================================================================
KARDS.Specify = KARDS.Specify or {}

-- 指定手牌：从玩家手牌中选择 count 张牌（只选择，不移除）
-- @param tableID string       牌桌唯一标识符
-- @param player  string       玩家标识
-- @param count   number|nil   指定张数（默认 1；超出手牌数时截断）
-- @param picker  function|nil 选择注入：function(hand) -> chosen[]
--               骨架/测试可注入模拟选择；真实 UI 就绪后由选择面板「确定」回调提交
-- @return table 选中的牌数组（未从手牌移除，移除由调用方执行）
function KARDS.Specify.HandCard(tableID, player, count, picker)
    local hand = KARDS.Deck:GetHand(tableID, player)
    if not hand or #hand == 0 then return {} end
    count = math.min(math.max(1, math.floor(count or 1)), #hand)
    local chosen = {}
    if type(picker) == "function" then
        local picked = picker(hand)
        if type(picked) == "table" then
            for i = 1, math.min(#picked, count) do
                chosen[i] = picked[i]
            end
        end
    else
        for i = 1, count do
            chosen[i] = hand[i]
        end
    end
    return chosen
end

-- 指定目标：从合法候选目标中选择一个（只选择，无副作用）
-- @param tableID    string       牌桌唯一标识符
-- @param player     string       发起玩家
-- @param candidates table        合法目标列表（不可指向的目标已由调用方过滤；UI 层以黑白显示）
-- @param picker     function|nil 选择注入：function(candidates) -> target
-- @return table|nil 选中的目标；无候选时返回 nil
function KARDS.Specify.Target(tableID, player, candidates, picker)
    if not candidates or #candidates == 0 then return nil end
    if type(picker) == "function" then
        -- 严格失败：picker 显式返回 false 表示选定目标不合法（测试控制台指向非法
        -- 槽位用），不回退候选首项；返回 nil 仍按缺省回退候选首项
        local picked = picker(candidates)
        if picked == false then return nil end
        return picked or candidates[1]
    end
    return candidates[1]
end
