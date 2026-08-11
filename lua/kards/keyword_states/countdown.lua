-- 词条状态模块：倒计时（readme 7.2.2）
--
-- 状态字段：Countdowns（[card] = 倒计时当前值）
-- 联动规则：倒计时单位每回合结束后 -1（SimEndTurn 读取 Get 推算推进值），
--   归零时触发事件并移除单位（SimEndTurn 清除状态并 SimRemoveFromField）；
--   首次进入倒计时时以卡面词条数值为基数（SimEndTurn 经 GetKeywordValue 兜底）。

KARDS = KARDS or {}
local KS = KARDS.KeywordStates or {}
KARDS.KeywordStates = KS

KS.Countdown = {
    Field = "Countdowns",

    -- 倒计时当前值（未推进过返回 nil，调用方以卡面词条数值兜底）
    Get = function(st, card)
        return st ~= nil and st.Countdowns[card] or nil
    end,

    -- 设置倒计时当前值（每回合结束后 -1 后的新值）
    Set = function(st, card, value)
        st.Countdowns[card] = value
    end,

    -- 清除倒计时（归零触发事件并移除单位后）
    Clear = function(st, card)
        st.Countdowns[card] = nil
    end,
}
table.insert(KS.Modules, KS.Countdown)
