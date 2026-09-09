--!strict
local e = require("./Harness").build()
local cfg = e.require(e.Shared.Config).get("overworld")
local p = e.require(e.Shared.GroundLayers).plan(cfg.zones,cfg.trails,cfg.surfaceLayerMetres.alternateMetres,cfg.barn)
print("max",p.maxHeight)
for i,t in ipairs(cfg.trails) do print(t.id,p.trails[i]) end
