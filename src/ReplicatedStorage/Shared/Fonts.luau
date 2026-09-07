--!strict
--[[
	Fonts -- one resolver, used by the HUD and by everything in the world.

	Font choices were hardcoded across nine files, which breaks the project's own
	rule that presentation values live in Data. They are named in Data/ui.json
	(interface) and Data/presentation.json (world signage) now, and resolved
	here.

	Resolution never errors. A name that stops existing should make a sign look
	slightly different, not stop the barn from building -- so an unknown name
	falls back to the role's default and says so once.

	Every name shipped in the data was checked against Enum.Font on 2026-09-07;
	the list is recorded in docs/PLATFORM_NOTES.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.scope("LiveRound.Fonts")

local Fonts = {}

local DEFAULTS: { [string]: Enum.Font } = {
	body = Enum.Font.GothamMedium,
	bold = Enum.Font.GothamBold,
	title = Enum.Font.GothamBlack,
	numeric = Enum.Font.GothamBold,
	signTitle = Enum.Font.GothamBold,
	signBody = Enum.Font.GothamMedium,
	handLettered = Enum.Font.GothamMedium,
	nameplate = Enum.Font.GothamBold,
	tabular = Enum.Font.GothamMedium,
}

local warned: { [string]: boolean } = {}

--- An Enum.Font by name, or nil when the engine does not have one.
function Fonts.byName(name: string?): Enum.Font?
	if type(name) ~= "string" then
		return nil
	end
	return (Enum.Font :: any)[name]
end

local function resolve(file: string, role: string): Enum.Font
	local ok, table_ = pcall(function()
		return Config.get(file).fonts
	end)
	local name = ok and type(table_) == "table" and table_[role] or nil
	local font = Fonts.byName(name)
	if font then
		return font
	end
	if name ~= nil and not warned[role] then
		warned[role] = true
		log.warn(`no Enum.Font named '{tostring(name)}' for role '{role}' -- falling back`)
	end
	return DEFAULTS[role] or Enum.Font.GothamMedium
end

--- Interface roles: body, bold, title, numeric.
function Fonts.ui(role: string): Enum.Font
	return resolve("ui", role)
end

--- World roles: signTitle, signBody, handLettered, nameplate, tabular.
function Fonts.world(role: string): Enum.Font
	return resolve("presentation", role)
end

--- Test seam: forget which roles have already warned.
function Fonts._resetWarnings()
	table.clear(warned)
end

return Fonts
