--!strict
-- Persistent camo mutations. Only MatchService calls recordHeadshot, after a
-- live bot is eliminated by its authoritative projectile simulation.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Rules = require(ReplicatedStorage.Shared.Camos)

local Camos = {}

local function reconcile(data: any)
	local config = Config.get("camos")
	data.camoProgress = data.camoProgress or {}
	data.camoProgress.headshots = Rules.headshots(data)
	data.ownedCamos = data.ownedCamos or {}
	data.loadout = data.loadout or {}
	for _, id in ipairs(config.order) do
		if Rules.isUnlocked(data, id) and not table.find(data.ownedCamos, id) then
			table.insert(data.ownedCamos, id)
		end
	end
	if not Rules.isUnlocked(data, data.loadout.camo or "") then
		data.loadout.camo = config.default
	end
end

function Camos.recordHeadshot(handle: any): any?
	if not handle:isActive() then return nil end
	reconcile(handle.data)
	local config = Config.get("camos")
	local previous = Rules.headshots(handle.data)
	handle.data.camoProgress.headshots = previous + 1
	local unlocked = {}
	for _, id in ipairs(config.order) do
		local threshold = config.camos[id].requiredHeadshots
		if previous < threshold and handle.data.camoProgress.headshots >= threshold then
			table.insert(unlocked, id)
		end
	end
	reconcile(handle.data)
	-- Introduce the first earned finish immediately, preserving the player's
	-- choice once they already have one. Later finishes are selected in supply.
	if config.autoEquipFirstUnlock and #unlocked > 0 and previous < config.camos[config.order[2]].requiredHeadshots then
		handle.data.loadout.camo = unlocked[1]
	end
	return {
		headshots = handle.data.camoProgress.headshots,
		unlockedCamos = unlocked,
		equippedCamo = handle.data.loadout.camo,
		nextUnlock = Rules.nextUnlock(handle.data),
	}
end

function Camos.equip(handle: any, id: string): (boolean, string?)
	if not handle:isActive() then return false, "profile session unavailable" end
	if not Rules.visual(id) then return false, "unknown camo" end
	-- Checking progress again closes ownership-list and dev-unlock bypasses.
	if not Rules.isUnlocked(handle.data, id) then return false, "earn more confirmed headshots to unlock this camo" end
	reconcile(handle.data)
	handle.data.loadout.camo = id
	return true, nil
end

return Camos
