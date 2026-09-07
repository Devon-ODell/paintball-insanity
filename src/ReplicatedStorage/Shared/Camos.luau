--!strict
-- Pure camo rules. Progress comes from server-confirmed mask hits, never gear,
-- client hit reports or purchases. The client may use the catalogue for display.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local Camos = {}

function Camos.headshots(data: any): number
	local n = data.camoProgress and data.camoProgress.headshots
	if type(n) ~= "number" or n ~= n or n == math.huge or n < 0 then return 0 end
	return math.floor(n)
end

function Camos.visual(id: string): any?
	return Config.get("camos").camos[id]
end

function Camos.isUnlocked(data: any, id: string): boolean
	local entry = Camos.visual(id)
	return entry ~= nil and Camos.headshots(data) >= entry.requiredHeadshots
end

function Camos.nextUnlock(data: any): any?
	local config = Config.get("camos")
	local count = Camos.headshots(data)
	for _, id in ipairs(config.order) do
		local entry = config.camos[id]
		if count < entry.requiredHeadshots then
			return {
				id = id,
				displayName = entry.displayName,
				requiredHeadshots = entry.requiredHeadshots,
				remaining = entry.requiredHeadshots - count,
			}
		end
	end
	return nil
end

function Camos.catalogue(data: any): { any }
	local config = Config.get("camos")
	local count = Camos.headshots(data)
	local equipped = data.loadout and data.loadout.camo or config.default
	local out = {}
	for _, id in ipairs(config.order) do
		local entry = config.camos[id]
		local owned = Camos.isUnlocked(data, id)
		table.insert(out, {
			id = id,
			displayName = entry.displayName,
			blurb = entry.blurb,
			cost = 0,
			purchasable = false,
			earnedOnly = true,
			owned = owned,
			locked = not owned,
			equipped = owned and equipped == id,
			reactive = entry.reactive,
			headshots = count,
			requiredHeadshots = entry.requiredHeadshots,
			remaining = math.max(0, entry.requiredHeadshots - count),
			color = entry.accentColor,
		})
	end
	return out
end

-- The broad body capsule decides whether paint landed. A smaller ellipsoid
-- aligned with the visible mask decides whether that same impact is a headshot.
-- Shoulder grazes and the generous top of the body capsule do not earn camos.
function Camos.classifyHeadshot(impact: Vector3, ground: Vector3, velocity: Vector3?): boolean
	local rule = Config.get("camos").headshot
	local hitbox = Config.get("ballistics").hitbox
	local center = ground + Vector3.new(0, hitbox.headTopMetres - rule.centerBelowHeadTopMetres, 0)
	-- A broad capsule can register before the paint reaches the smaller mask.
	-- Project only through that body's depth along the authoritative flight,
	-- so the fixed-step endpoint cannot turn the same mask shot into a body tag.
	if velocity and velocity.Magnitude > 0 then
		local direction = velocity.Unit
		impact += direction * math.clamp((center - impact):Dot(direction), 0, hitbox.bodyWidthMetres)
	end
	local delta = impact - center
	local horizontal = (delta.X * delta.X + delta.Z * delta.Z) / (rule.horizontalRadiusMetres * rule.horizontalRadiusMetres)
	local vertical = delta.Y * delta.Y / (rule.verticalRadiusMetres * rule.verticalRadiusMetres)
	return horizontal + vertical <= 1
end

return Camos
