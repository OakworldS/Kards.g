-- Kards 战斗牌桌实体服务端代码：销毁清理段（re.md T-H1 拆分，由 init.lua include）
-- 职责：OnRemove（牌桌销毁清理）+ EntityRemoved 兜底清理。

local ENT = scripted_ents.GetStored("sent_kards_battle_table").t

-- ====================================================================
-- 卡牌句柄内存缓存（re.md B-M4）：
-- 曾按「fileName → 句柄」缓存；2026-08-10 起 DeckCardHandleFromFile 不再缓存
-- 句柄对象（同 fileName 多张卡须独立句柄，否则数据层战场按句柄引用登记会把
-- 同 ID 第二张误判已在场，部署报 already_on_field）。本表保留 Get/Set 接口与
-- InvalidateAll 回调（卡组编辑保存仍调用）——后续如恢复缓存应按「效果解析结果」
-- 缓存而非句柄对象。
-- ====================================================================
KARDS = KARDS or {}
KARDS.CardHandleCache = KARDS.CardHandleCache or {}
local Cache = KARDS.CardHandleCache

-- 读取缓存（fileName → 句柄|nil）
function Cache.Get(fileName)
    return Cache[fileName]
end

-- 写入缓存（保存卡组时随 InvalidateAll 清理）
function Cache.Set(fileName, card)
    Cache[fileName] = card
end

-- 全部失效（卡组编辑保存后调用：同卡再进出对局按最新文件重建句柄）
function Cache.InvalidateAll()
    for k in pairs(Cache) do
        if k ~= "Get" and k ~= "Set" and k ~= "InvalidateAll" then
            Cache[k] = nil
        end
    end
end

-- ====================================================================
-- 销毁清理
-- ====================================================================

--[[
    实体销毁清理（方案 A，规划 16.5）：经会话状态机强制退出全部槽内玩家
    （恢复移动/无敌/武器/位置/视角 + 清理卡组槽，幂等）、删除牌桌全局变量库（幂等），
    并透传前置实体清理。
]]
function ENT:OnRemove()
    -- 先解冻并恢复所有槽内玩家（会话状态机 ForceExitAll：恢复 + 广播 + 按需熄灭灯具）
    if self._kardsSession then
        self._kardsSession:ForceExitAll()
    end
    -- 兜底清理：子物体系统（桌面空卡占位等全部子物体，含删除淡出中未销毁的）一次性销毁
    -- + 牌桌上方灯具（幂等，ForceExitAll 已处理则此处无残留）+ 组卡模式卡牌
    if self._kardsChildSystem then
        self._kardsChildSystem:Destroy()
        self._kardsChildSystem = nil
    end
    self:ExitDeckMode()
    -- 兜底清理：卡组槽实体（battle 模式；正常退出已由会话状态机逐槽清理，
    -- 玩家断开等残留场景在此一并销毁：档位实体 + 总部 + 抽牌临时卡）
    if self._kardsBattleDecks then
        for _, bd in pairs(self._kardsBattleDecks) do
            for _, e in pairs(bd.pileEnts or {}) do
                if IsValid(e) then e:Remove() end
            end
            if IsValid(bd.hqEnt) then bd.hqEnt:Remove() end
            for _, e in ipairs(bd.drawEnts or {}) do
                if IsValid(e) then e:Remove() end
            end
        end
        self._kardsBattleDecks = nil
    end
    if IsValid(self._kardsLight) then
        self._kardsLight:Remove()
        self._kardsLight = nil
    end
    if self.TableID then
        KARDS.VarLib.Destroy(self.TableID)
    end
    if self.BaseClass and self.BaseClass.OnRemove then
        self.BaseClass.OnRemove(self)
    end
end

-- ====================================================================
-- net 消息注册（SERVER 段）：EntityRemoved 兜底
-- ====================================================================
if SERVER then
    -- 方案 B 兜底（规划 16.5）：牌桌异常移除时清理残留（OnRemove 未覆盖的极端情况）。
    -- 实体已无效，GetClass 经 pcall 保护；会话状态机 Exit / VarLib.Destroy 均幂等，重复执行安全。
    hook.Add("EntityRemoved", "KardsTableCleanup", function(ent)
        if not ent then return end
        local ok, cls = pcall(function() return ent:GetClass() end)
        if not ok or cls ~= "sent_kards_battle_table" then return end
        if ent._kardsSession then
            ent._kardsSession:ForceExitAll()
        else
            -- 兜底（状态机缺失的异常场景）：直接逐玩家释放槽位并清理卡组槽
            for _, ply in pairs(ent.Slots or {}) do
                if IsValid(ply) and ply:IsPlayer() then
                    ent:ExitSlot(ply)
                end
            end
        end
        if ent.TableID then
            KARDS.VarLib.Destroy(ent.TableID)
        end
    end)
end
