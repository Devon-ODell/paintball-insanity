--!strict
-- Cosmetic overlays follow native R6/R15 limbs. No physics or hit-test effect.
local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local PlayerAppearance = {}

local function vector(values: { number }): Vector3
	return Vector3.new(values[1], values[2], values[3])
end

function PlayerAppearance.apply(character: Model, loadout: any)
	local previous = character:FindFirstChild("FieldKitAppearance")
	if previous then previous:Destroy() end
	local cfg = Config.get("playerAppearance")
	local folder = Instance.new("Folder")
	folder.Name = "FieldKitAppearance"
	for slot, items in pairs(cfg.slots) do
		local id = loadout[slot] or cfg.defaults[slot]
		local item = items[id] or items[cfg.defaults[slot]]
		for index, spec in ipairs(cfg.templates[item.template]) do
			if item.count and index > item.count then break end
			local anchor: BasePart? = nil
			for _, name in ipairs(cfg.anchors[spec.anchor]) do
				local candidate = character:FindFirstChild(name)
				if candidate and candidate:IsA("BasePart") then
					anchor = candidate
					break
				end
			end
			if not anchor then continue end
			local part = Instance.new("Part")
			part.Name = `{slot}_{id}_{index}`
			part.Size = anchor.Size * vector(spec.size)
			part.CFrame = anchor.CFrame * CFrame.new(anchor.Size * vector(spec.at))
			local rgb = if item.lensColors and index > 1 then item.lensColors[index - 1] else item.color
			part.Color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
			part.Material = Enum.Material[spec.material]
			part.Shape = Enum.PartType[spec.shape]
			part.Anchored = false
			part.Massless = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.CastShadow = false
			part.Parent = folder
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = anchor
			weld.Part1 = part
			weld.Parent = part
		end
	end
	folder.Parent = character
end

return PlayerAppearance
