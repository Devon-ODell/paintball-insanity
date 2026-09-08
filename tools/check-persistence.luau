--!strict
-- Exercise Profile's actual persistent adapter with controlled store boundaries.
-- This is deliberately separate from pure specs, which always use demo memory.
local Harness = require("./Harness")
local env = Harness.build()
env.ReplicatedStorage.DemoMode.Value = false
env.game:GetService("RunService").IsStudio = function() return false end
local kicked = false
env.game:GetService("Players").GetPlayerByUserId = function()
	return { Kick = function() kicked = true end }
end
local onEnd
local backing: any = {
	Data = { version = 1, currency = 720, ownedMarkers = { "mechanical", "pump" }, loadout = { marker = "pump" } },
	LastSavedData = {}, active = true, saveCalls = 0, writeSucceeds = false,
	AddUserId = function() end, Reconcile = function() end,
	IsActive = function(self) return self.active end,
	EndSession = function(self) self.active = false; if onEnd then onEnd() end end,
	OnSessionEnd = { Connect = function(_, callback) onEnd = callback end },
}
local package = env.Server.Vendor.ProfileStore
package._loaded = true
--[[
	The real ProfileStore object exposes DataStoreState, and Profile.isPersistent
	now requires it to read "Access" -- unavailable access must never become a
	temporary live save. The stub did not model that field, so this whole check
	died on "persistent dependency not selected" before testing anything.
]]
--[[
	DataStoreState lives on the ProfileStore MODULE, not on the store New()
	returns -- Profile.init keeps the module as its backend and isPersistent
	reads the field from there.
]]
package._result = {
	DataStoreState = "Access",
	New = function()
		return { StartSessionAsync = function() return backing end }
	end,
}
local Profile = env.require(env.Server.Economy.Profile)
local Pricing = env.require(env.Shared.CommerceCatalog)
local cfg = Profile.deepCopy(Pricing.config())
cfg.saveTimeoutSeconds = 0.01
Pricing._setOverrideForTesting(cfg)
env.require(env.Shared.Dev)._setOverrideForTesting({ enabled = false })
backing.Save = function(self)
	self.saveCalls += 1
	if self.writeSucceeds then self.LastSavedData = Profile.deepCopy(self.Data) end
end
--[[
	The checks run inside a driven coroutine.

	Profile.saveConfirmed waits on the save timeout, and the harness's task.wait
	is a real yield now rather than an inline call. Lune runs a script in a
	coroutine, so yielding at the top level suspends the whole tool -- which is
	why this check used to end silently, exit 0, and never print its own success
	line. Resuming until the thread is dead is the scheduler it needs.
]]
local function checks()
	local handle = Profile.load(42)
	assert(handle and Profile.isPersistent(), "persistent dependency not selected")
	assert(handle.data.currency == 720 and handle.data.loadout.marker == "pump", "migration replaced old progress")
	assert(handle.data.loadout.camo == "factory" and handle.data.commerce.receipts, "new fields not reconciled")
	handle.data.commerce.receipts.test = { productId = 123 }
	local function saved(data)
		return data and data.commerce and data.commerce.receipts.test ~= nil
	end
	assert(not Profile.saveConfirmed(handle, saved), "Save returning is not proof of a durable write")
	assert(backing.saveCalls == 1, "the adapter should schedule one save, not flood the store")
	backing.writeSucceeds = true
	assert(Profile.saveConfirmed(handle, saved), "confirmed saved receipt not acknowledged")
	local calls = backing.saveCalls
	assert(Profile.saveConfirmed(handle, saved) and calls == backing.saveCalls, "already-saved receipt triggered another write")
	backing.active = false
	onEnd()
	assert(kicked and Profile.get(42) == nil, "session loss must stop player mutations")
	assert(not Profile.saveConfirmed(handle, saved), "stale session acknowledged a purchase")
	print("Persistent adapter checks passed: migration, write confirmation, retries, save deduplication and session loss (mock store).")
end

local thread = coroutine.create(checks)
for _ = 1, 100000 do
	local ok, err = coroutine.resume(thread)
	if not ok then
		error(err, 0)
	end
	if coroutine.status(thread) == "dead" then
		break
	end
end
assert(coroutine.status(thread) == "dead", "persistence checks never finished")
