-- Kards 战斗卡牌实体（Q 菜单生成）
-- 包装前置模组「Simple Static Model Importer」的 sent_pmx_static_imported 实体：
-- 继承其运行时渲染（Draw）与箱体碰撞，生成时自动应用 basic_card 模型
-- （z-up 平躺几何，无需轴修正）。

ENT.Base = "sent_pmx_static_imported"
ENT.Type = "anim"
ENT.PrintName = "Kards 卡牌"
ENT.Author = "Kards Team"
ENT.Purpose = "通过前置模组导入的 basic_card 模型（运行时渲染）"
ENT.Instructions = "生成后自动应用卡牌模型，可动的薄箱体（可被物理枪抓取/推动）"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH -- 与前置一致：不透明 + 半透明双通道渲染
