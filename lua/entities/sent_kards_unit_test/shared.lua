-- basic_card_unit 模型检查测试实体（Q 菜单放置，2026-08-11）
-- 用途：诊断 basic_card_unit 模型文件本身渲染是否正常（排查单位部署切换后不渲染的问题）。
-- 实现：本实体自身不渲染；Initialize 时创建 sent_pmx_static_imported 子实体并
--       ApplyImportedModel("basic_card_unit", 0.5)，SetParent 跟随本实体。
--       Q 菜单 → Entities → Kards → "basic_card_unit 模型测试"。

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "basic_card_unit 模型测试"
ENT.Author = "Kards"
ENT.Category = "Kards"
ENT.Spawnable = true
ENT.AdminOnly = false

if SERVER then
    list.Set("SpawnableEntities", "sent_kards_unit_test", {
        Name = "basic_card_unit 模型测试",
        Category = "Kards",
        Order = 1,
    })
end

if CLIENT then
    list.Set("SpawnableEntities", "sent_kards_unit_test", {
        Name = "basic_card_unit 模型测试",
        Category = "Kards",
        Order = 1,
    })
end
