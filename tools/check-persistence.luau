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
package._result = { New = function()
	return { StartSessionAsync = function() return backing end }
end }
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
