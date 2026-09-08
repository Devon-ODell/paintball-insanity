--!strict
-- Exercise the real Profile adapter with a controlled persistence boundary.
local Harness = require("./Harness")
for _, access in ipairs({ "Access", "NoAccess", "NoInternet" }) do
	local env = Harness.build()
	env.ReplicatedStorage.DemoMode.Value = false
	local present = true
	local ended = false
	local calls = 0
	local profile = {
		Data = {},
		AddUserId = function() end,
		Reconcile = function() end,
		IsActive = function() return not ended end,
		EndSession = function() ended = true end,
		OnSessionEnd = { Connect = function() end },
	}
	local backend = {
		DataStoreState = access,
		New = function() return {
			StartSessionAsync = function()
				calls += 1
				return profile
			end,
		} end,
	}
	local vendor = env.Server.Vendor.ProfileStore
	vendor._loaded, vendor._result = true, backend
	env.game:GetService("RunService").IsStudio = function() return false end
	env.game:GetService("Players").GetPlayerByUserId = function() return if present then {} else nil end
	local Profile = env.require(env.Server.Economy.Profile)
	local handle = Profile.load(123)
	assert(Profile.isPersistent() == (access == "Access"))
	if access == "Access" then
		assert(handle ~= nil and calls == 1)
		assert(Profile.load(123) == handle and calls == 1, "reuse the active session")
		Profile.release(123)
		assert(ended and Profile.get(123) == nil)
		present = false
		ended = false
		assert(Profile.load(123) == nil and ended, "release a session returned after departure")
	else
		assert(handle == nil and calls == 0, "never open volatile live progress without DataStore access")
	end
end
print("Profile adapter checks passed: access failures, reuse, release and departure (mock backend).")
