--!strict
-- Pure camo rules. Progress comes from server-confirmed mask hits, never gear,
-- client hit reports or purchases. The client may use the catalogue for display.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Courses = require(ReplicatedStorage.Shared.Courses)

local Camos = {}

function Camos.headshots(data: any): number
	local n = data.camoProgress and data.camoProgress.headshots
	if type(n) ~= "number" or n ~= n or n == math.huge or n < 0 then return 0 end
	return math.floor(n)
end

function Camos.visual(id: string): any?
	return Config.get("camos").camos[id]
end

--[[
	Two ladders, one predicate.

	Most finishes unlock on confirmed mask hits. A finish carrying a `requires`
	block unlocks on that instead -- currently gold medals on the Shoothouse
	courses -- and its requiredHeadshots is ignored. Both are earned; neither is
	purchasable; neither changes where paint goes.
]]
function Camos.isUnlocked(data: any, id: string): boolean
	local entry = Camos.visual(id)
	if entry == nil then
		return false
	end
	if entry.requires then
		return Courses.meets(data, entry.requires)
	end
	return Camos.headshots(data) >= entry.requiredHeadshots
end

--- What a locked finish is still waiting for, as display text. Returns nil for
--- anything already owned.
function Camos.requirementFor(data: any, id: string): string?
	local entry = Camos.visual(id)
	if entry == nil or Camos.isUnlocked(data, id) then
		return nil
	end
	if entry.requires then
		local left = Courses.remainingFor(data, entry.requires)
		local medal = if entry.requires.kind == "courseMedal" then entry.requires.medal else "gold"
		return `{left} more {medal} {if left == 1 then "medal" else "medals"} on the Shoothouse`
	end
	local left = math.max(0, entry.requiredHeadshots - Camos.headshots(data))
	return `{left} more confirmed {if left == 1 then "mask hit" else "mask hits"}`
end

--- The next HEADSHOT unlock. Course-earned finishes are deliberately absent:
--- they are not on this ladder and showing "35 to go" beside one would be a lie.
function Camos.nextUnlock(data: any): any?
	local config = Config.get("camos")
	local count = Camos.headshots(data)
	for _, id in ipairs(config.order) do
		local entry = config.camos[id]
		if not entry.requires and count < entry.requiredHeadshots then
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
			-- Course finishes are earned on a clock, not a hit count, so the
			-- board shows what each one is actually waiting for.
			earnedOn = if entry.requires then "course" else "headshots",
			requirement = Camos.requirementFor(data, id),
			layout = entry.layout,
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
