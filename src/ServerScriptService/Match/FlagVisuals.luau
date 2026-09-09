--!strict
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local Units = require(RS.Shared.Units)
local FlagVisuals = {}

local function vec(t: any): Vector3 return Vector3.new(t[1], t[2], t[3]) end
local function part(parent: Instance, name: string, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name, p.Size, p.Color = name, Units.vectorToStuds(size), color
	p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.CastShadow = true, false, false, false, false
	p.Material = Enum.Material.SmoothPlastic
	p.Parent = parent
	return p
end

function FlagVisuals.new(parent: Instance, rules: any): any
	local cfg = Config.require("gamemodes", "captureTheFlag.presentation")
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "CTFObjectives", parent
	local visuals = {}
	for _, name in ipairs({ "enemy", "player" }) do
		local rgb = if name == "player" then cfg.playerColor else cfg.enemyColor
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local base = part(folder, name .. "Base", vec(cfg.baseSizeMetres), color)
		base.Position = Units.vectorToStuds(rules.flags[name].home + Vector3.new(0, cfg.baseSizeMetres[2] / 2, 0))
		local pole = part(folder, name .. "Pole", Vector3.new(cfg.poleWidthMetres, cfg.poleHeightMetres, cfg.poleWidthMetres), color)
		local cloth = part(folder, name .. "Flag", vec(cfg.clothSizeMetres), color)
		local gui = Instance.new("BillboardGui")
		gui.Name, gui.Size = "Objective", UDim2.fromOffset(cfg.labelPixels[1], cfg.labelPixels[2])
		gui.AlwaysOnTop = rules.cfg.flag.carrierVisibleToAll
		gui.StudsOffsetWorldSpace = Vector3.new(0, Units.metresToStuds(cfg.labelHeightMetres - cfg.poleHeightMetres / 2), 0)
		gui.Parent = pole
		local label = Instance.new("TextLabel")
		label.Size, label.BackgroundTransparency = UDim2.fromScale(1, 1), 1
		label.Font, label.TextSize, label.TextColor3 = Enum.Font.GothamBold, cfg.labelTextPixels, color
		label.TextStrokeTransparency = 0
		label.Parent = gui
		visuals[name] = { pole = pole, cloth = cloth, label = label }
	end
	local self = { folder = folder }
	function self:update()
		for name, flag in pairs(rules.flags) do
			local v = visuals[name]
			local at = flag.position + Vector3.new(0, if flag.state == "carried" then cfg.carryHeightMetres else 0, 0)
			v.pole.Position = Units.vectorToStuds(at + Vector3.new(0, cfg.poleHeightMetres / 2, 0))
			v.cloth.Position = Units.vectorToStuds(at + Vector3.new(cfg.clothSizeMetres[1] / 2, cfg.clothHeightMetres, 0))
			v.label.Text = (if name == "player" then "YOUR FLAG" else "ENEMY FLAG") .. " · " .. string.upper(flag.state)
		end
	end
	function self:destroy() folder:Destroy() end
	self:update()
	return self
end

return FlagVisuals
