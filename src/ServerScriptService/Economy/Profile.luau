--!strict
--[[
	Profile -- server-side player data, session-locked.

	Backed by ProfileStore (madstudioroblox), the maintained successor to
	ProfileService. Verified 2026-09-06; see docs/PLATFORM_NOTES.md for the exact
	API surface this module depends on, because it changed from ProfileService's.

	Raw DataStoreService is not an option here: without session locking, a player
	whose server migrates mid-session loses currency, and currency is the only
	thing this game persists.

	When ProfileStore is absent (no `wally install` yet, or a headless spec run)
	this falls back to an in-memory store and says so loudly. The fallback exists
	so the rest of the game is testable, never so it can ship.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Dev = require(ReplicatedStorage.Shared.Dev)
local Log = require(ReplicatedStorage.Shared.Log)
local CommerceCatalog = require(ReplicatedStorage.Shared.CommerceCatalog)

local log = Log.scope("LiveRound.Economy")

local Profile = {}

export type Data = any

export type Handle = {
	userId: number,
	data: Data,
	release: (Handle) -> (),
	isActive: (Handle) -> boolean,
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = deepCopy(v)
	end
	return out
end

Profile.deepCopy = deepCopy

--------------------------------------------------------------------------------
-- Backend selection
--------------------------------------------------------------------------------

local store: any = nil
local memory: { [number]: Data } = {}
local sessions: { [number]: Handle } = {}
local usingFallback = false
local persistent = false
local backend: any = nil
local loading: { [number]: boolean } = {}

local function template(): Data
	local data = deepCopy(Config.require("economy", "profile.template"))
	if Dev.flag("infiniteCurrency") then
		data.currency = Dev.value("infiniteCurrency", "grantedBalance", 99999999)
	end
	return data
end

local function locateProfileStore(): any?
	local demo = ReplicatedStorage:FindFirstChild("DemoMode")
	if demo and (demo :: BoolValue).Value then return nil end
	local packages = ReplicatedStorage:FindFirstChild("Packages")
	if packages then
		local module = packages:FindFirstChild("ProfileStore")
		if module and module:IsA("ModuleScript") then
			return require(module) :: any
		end
	end
	local serverPackages = game:GetService("ServerScriptService"):FindFirstChild("ServerPackages")
	if serverPackages then
		local module = serverPackages:FindFirstChild("ProfileStore")
		if module and module:IsA("ModuleScript") then
			return require(module) :: any
		end
	end
	local vendor = script.Parent.Parent:FindFirstChild("Vendor")
	local pinned = vendor and vendor:FindFirstChild("ProfileStore")
	return if pinned then require(pinned :: ModuleScript) else nil
end

function Profile.init()
	if store or usingFallback then
		return
	end
	local module = locateProfileStore()
	if module then
		backend = module
		store = module.New(Config.require("economy", "profile.storeName"), template())
		persistent = not game:GetService("RunService"):IsStudio()
		if not persistent then
			store = store.Mock
			log.warn("Studio uses temporary ProfileStore.Mock progress; live saves are untouched.")
		end
		log.info("profile store ready (pinned ProfileStore)")
	else
		local demo = ReplicatedStorage:FindFirstChild("DemoMode")
		assert(demo and (demo :: BoolValue).Value, "The persistence dependency is missing; live temporary saves are refused.")
		usingFallback = true
		log.warn(
			"Temporary demo/headless progress is active. Player data will NOT persist in this session."
		)
	end
end

--- True only for the live backend with confirmed DataStore access.
function Profile.isPersistent(): boolean
	return persistent and backend ~= nil and backend.DataStoreState == "Access"
end

--- Adds new schema fields without replacing existing inventory or progression.
function Profile.reconcile(data: Data)
	local function merge(target: any, defaults: any)
		for key, value in pairs(defaults) do
			if target[key] == nil then
				target[key] = deepCopy(value)
			elseif type(value) == "table" and type(target[key]) == "table" and #value == 0 then
				merge(target[key], value)
			end
		end
	end
	merge(data, Config.require("economy", "profile.template"))
	data.version = Config.require("economy", "profile.template.version")
end

function Profile.get(userId: number): Handle?
	local handle = sessions[userId]
	return if handle and handle:isActive() then handle else nil
end

--- A Save call merely schedules work. Confirm the actual saved snapshot before
--- acknowledging a purchase. The receipt and inventory share the locked profile.
function Profile.saveConfirmed(handle: Handle, contains: (Data) -> boolean): boolean
	local backing = (handle :: any)._profile
	if not Profile.isPersistent() or not backing or not handle:isActive() then return false end
	if contains(backing.LastSavedData) then return true end
	local ok = pcall(function() backing:Save() end)
	if not ok then return false end
	local deadline = os.clock() + CommerceCatalog.config().saveTimeoutSeconds
	while handle:isActive() and os.clock() < deadline do
		if contains(backing.LastSavedData) then return true end
		task.wait(CommerceCatalog.config().savePollSeconds)
	end
	return false
end

--------------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------------

local FallbackHandle = {}
FallbackHandle.__index = FallbackHandle

function FallbackHandle.release(self: any)
	self._active = false
end
function FallbackHandle.isActive(self: any): boolean
	return self._active
end

local StoreHandle = {}
StoreHandle.__index = StoreHandle

function StoreHandle.release(self: any)
	self._profile:EndSession()
end
function StoreHandle.isActive(self: any): boolean
	return self._profile:IsActive()
end

--[[
	Opens a session for a player. Returns nil when the lock could not be taken,
	which the caller must treat as "kick politely and let them rejoin" -- never
	as "carry on with a fresh profile", which would silently wipe them.
]]
function Profile.load(userId: number): Handle?
	Profile.init()

	if persistent then
		while backend.DataStoreState == "NotReady" do
			if game:GetService("Players"):GetPlayerByUserId(userId) == nil then return nil end
			task.wait()
		end
		if not Profile.isPersistent() then
			log.warn("DataStore access unavailable; refusing temporary live progress.")
			return nil
		end
	end

	while loading[userId] do task.wait() end
	local existing = sessions[userId]
	if existing and existing:isActive() then
		return existing
	end

	if usingFallback then
		if not memory[userId] then
			memory[userId] = template()
		end
		if Dev.flag("infiniteCurrency") then
			memory[userId].currency = Dev.value("infiniteCurrency", "grantedBalance", 99999999)
		end
		Profile.reconcile(memory[userId])
		local handle = setmetatable({
			userId = userId,
			data = memory[userId],
			_active = true,
		}, FallbackHandle) :: any
		sessions[userId] = handle
		return handle
	end

	local key = Config.require("economy", "profile.keyPrefix") .. tostring(userId)
	loading[userId] = true
	local opened, profile = pcall(function() return store:StartSessionAsync(key, { Cancel = function()
		-- Give up if the player left while we were waiting for the lock.
		return game:GetService("Players"):GetPlayerByUserId(userId) == nil
	end }) end)
	loading[userId] = nil

	if not opened or not profile then
		log.warn(`could not open a profile session for {userId}`)
		return nil
	end

	if game:GetService("Players"):GetPlayerByUserId(userId) == nil then
		profile:EndSession()
		return nil
	end

	profile:AddUserId(userId)
	profile:Reconcile()
	Profile.reconcile(profile.Data)

	-- Top up an existing profile too, so the flag works on a save made before
	-- it was switched on.
	if Dev.flag("infiniteCurrency") then
		profile.Data.currency = Dev.value("infiniteCurrency", "grantedBalance", 99999999)
	end

	local handle = setmetatable({
		userId = userId,
		data = profile.Data,
		_profile = profile,
	}, StoreHandle) :: any
	sessions[userId] = handle
	profile.OnSessionEnd:Connect(function()
		if sessions[userId] ~= handle then return end
		sessions[userId] = nil
		local player = game:GetService("Players"):GetPlayerByUserId(userId)
		if player then player:Kick("Your field pass opened elsewhere. Please rejoin to keep progress safe.") end
	end)
	return handle
end

--- Ends the session. Must run after the match has finished crediting, never before.
function Profile.release(userId: number)
	local handle = sessions[userId]
	if not handle then
		return
	end
	sessions[userId] = nil
	handle:release()
end

--------------------------------------------------------------------------------
-- Mutations -- the ONLY way currency ever changes
--------------------------------------------------------------------------------

--[[
	Credits a match payout.

	Takes the computed total, not the inputs, and is called only from the match
	service after the server has finished the round. There is deliberately no
	path from a remote to this function.
]]
function Profile.credit(handle: Handle, amount: number, reason: string): number
	if type(amount) ~= "number" or amount ~= amount or math.abs(amount) == math.huge or amount < 0 then
		error("Profile.credit: negative amount -- use debit", 2)
	end
	if not handle:isActive() then error("Profile.credit: inactive session", 2) end
	local rounded = math.floor(amount + 0.5)
	handle.data.currency = math.min(CommerceCatalog.config().maxCurrency, handle.data.currency + rounded)
	log.info(`credit {handle.userId} +{rounded} ({reason}) -> {handle.data.currency}`)
	return handle.data.currency
end

--[[
	Debits a purchase. Returns false and changes nothing if the player cannot
	afford it, so callers cannot drive a balance negative by ignoring the result.

	Under the infiniteCurrency dev flag the debit is approved and the balance is
	restored afterwards. Everything upstream -- the ownership check, the category
	check, the server-side price lookup -- still runs, so the code being
	exercised in dev is the code that ships. Only the wallet is fake.
]]
function Profile.debit(handle: Handle, amount: number, reason: string): boolean
	if type(amount) ~= "number" or amount ~= amount or math.abs(amount) == math.huge or amount < 0 then
		error("Profile.debit: invalid amount", 2)
	end
	if not handle:isActive() then return false end
	if amount == 0 then return true end
	local rounded = math.floor(amount + 0.5)
	if rounded < 0 then
		error("Profile.debit: negative amount -- use credit", 2)
	end
	if Dev.flag("infiniteCurrency") then
		handle.data.currency = Dev.value("infiniteCurrency", "grantedBalance", 99999999)
		log.info(`debit {handle.userId} -{rounded} ({reason}) [DEV: wallet refilled]`)
		return true
	end
	if handle.data.currency < rounded then
		return false
	end
	handle.data.currency -= rounded
	log.info(`debit {handle.userId} -{rounded} ({reason}) -> {handle.data.currency}`)
	return true
end

--- Records a match into the lifetime totals and the best-clear table.
function Profile.recordMatch(handle: Handle, summary: any)
	if not handle:isActive() then return end
	local lifetime = handle.data.lifetime
	lifetime.matches += 1
	lifetime.shots += summary.shots
	lifetime.hits += summary.hits
	lifetime.eliminations += summary.eliminations
	lifetime.deaths += summary.deaths
	if summary.cleared and summary.deaths == 0 then
		lifetime.flawless += 1
	end

	if summary.cleared then
		local best = handle.data.bestClears[summary.map]
		if not best or summary.deaths < best.deaths then
			handle.data.bestClears[summary.map] = {
				deaths = summary.deaths,
				tier = summary.tier,
				marker = summary.marker,
				durationSeconds = summary.durationSeconds,
			}
		end
	end

	-- Rolling average of the six fundamentals, so the Range can show progress.
	for name, entry in pairs(summary.scores) do
		if entry.confident then
			local previous = handle.data.fundamentals[name] or 0
			handle.data.fundamentals[name] = previous * 0.8 + entry.score * 0.2
		end
	end

	--[[
		Keep the last prescription.

		The whole teaching loop is play, be told exactly what you are bad at,
		drill it, play again -- and the telling happens at the barn, between
		matches, when the session that produced the diagnosis is gone. Nothing
		persisted it, so the coach fell back to "not enough shots on record yet"
		no matter how much had been played.

		Only overwritten when a match actually produced a diagnosis. A round too
		short to be confident about leaves the previous advice standing, which is
		better than clearing it.
	]]
	if summary.prescription then
		handle.data.coaching = {
			line = summary.prescription.line,
			drill = summary.prescription.drill,
		}
	end
end

--- Whether a map is unlocked. Progression is by skill, never by time played.
function Profile.hasUnlocked(handle: Handle, map: string): boolean
	if Dev.flag("unlockEverything") then
		return true
	end
	local rule = Config.get("economy").unlocks[map]
	if not rule then
		return true
	end
	return handle.data.bestClears[rule.requiresClear] ~= nil
end

--- Test seam: wipes the in-memory fallback between specs.
function Profile._resetFallback()
	table.clear(memory)
	table.clear(sessions)
end

return Profile
