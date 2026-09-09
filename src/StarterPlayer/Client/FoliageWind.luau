--!strict
-- Local leaf motion. Static trunks/collision never move or replicate updates.
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local Units = require(RS.Shared.Units)
local FoliageWind = {}
local TAG = "LR_WindFoliage"
local stopCurrent: (() -> ())? = nil

function FoliageWind.start(): () -> ()
	if stopCurrent then stopCurrent() end
	local cfg = Config.get("environmentArt").wind
	local radius = Units.metresToStuds(cfg.radiusMetres)
	local candidates: { [BasePart]: boolean } = {}
	local active: { [BasePart]: { rest: CFrame, phase: number, weight: number } } = {}
	local connections: { RBXScriptConnection } = {}
	local function add(item: Instance)
		if item:IsA("MeshPart") then candidates[item] = true end
	end
	local function restore(part: BasePart)
		local state = active[part]
		if state then
			if part.Parent then part.CFrame = state.rest end
			active[part] = nil
		end
	end
	local function remove(item: Instance)
		if item:IsA("BasePart") then
			restore(item)
			candidates[item] = nil
		end
	end
	table.insert(connections, CollectionService:GetInstanceAddedSignal(TAG):Connect(add))
	table.insert(connections, CollectionService:GetInstanceRemovedSignal(TAG):Connect(remove))
	for _, item in ipairs(CollectionService:GetTagged(TAG)) do add(item) end
	local function refresh(origin: Vector3)
		local nearby = {}
		for part in pairs(candidates) do
			if part:IsDescendantOf(workspace) then
				local distance = (part.CFrame.Position - origin).Magnitude
				if distance < radius then table.insert(nearby, { part = part, distance = distance }) end
			end
		end
		table.sort(nearby, function(a, b) return a.distance < b.distance end)
		local selected: { [BasePart]: boolean } = {}
		for i = 1, math.min(cfg.maxParts, #nearby) do
			local entry = nearby[i]
			local part = entry.part
			selected[part] = true
			local state = active[part]
			if not state then
				state = { rest = part.CFrame, phase = part.CFrame.Position.X * 0.13 + part.CFrame.Position.Z * 0.09, weight = 0 }
				active[part] = state
			end
			state.weight = math.clamp((radius - entry.distance) / (radius * 0.25), 0, 1)
		end
		for part in pairs(active) do if not selected[part] then restore(part) end end
	end
	local elapsed, sinceRefresh, time = 0, cfg.refreshSeconds, 0
	table.insert(connections, RunService.Heartbeat:Connect(function(dt: number)
		time += dt
		elapsed += dt
		sinceRefresh += dt
		if elapsed < cfg.intervalSeconds then return end
		elapsed %= cfg.intervalSeconds
		local camera = workspace.CurrentCamera
		if not camera then return end
		if sinceRefresh >= cfg.refreshSeconds then
			sinceRefresh %= cfg.refreshSeconds
			refresh(camera.CFrame.Position)
		end
		for part, state in pairs(active) do
			if not part:IsDescendantOf(workspace) then
				restore(part)
				continue
			end
			local wave = time * cfg.frequencyHz * math.pi * 2 + state.phase
			local amplitude = math.rad(cfg.amplitudeDegrees) * state.weight
			part.CFrame = state.rest * CFrame.Angles(math.sin(wave) * amplitude, 0, math.sin(wave * 0.73) * amplitude * 0.6)
		end
	end))
	local stopped = false
	local function stop()
		if stopped then return end
		stopped = true
		for _, connection in ipairs(connections) do connection:Disconnect() end
		for part in pairs(active) do restore(part) end
		table.clear(candidates)
		stopCurrent = nil
	end
	stopCurrent = stop
	return stop
end

return FoliageWind
