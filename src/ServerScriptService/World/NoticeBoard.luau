--!strict
--[[
	NoticeBoard -- the leaderboard, as a covered timber board beside the trail.

	Not a menu. It is a thing in the world you walk up to, and it cycles a page
	per map plus a personal-bests page so it is readable while you are walking
	past rather than only when you stop and press something.

	Data comes from Leaderboard.luau, which owns the DataStore access. This file
	only draws.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Units = require(ReplicatedStorage.Shared.Units)
local Log = require(ReplicatedStorage.Shared.Log)

local Leaderboard = require(script.Parent.Parent.Leaderboard.Leaderboard)

local log = Log.scope("LiveRound.Leaderboard")

local NoticeBoard = {}

export type Board = {
	model: Model,
	surface: SurfaceGui,
	setPage: (Board, string) -> (),
	refresh: (Board) -> (),
	destroy: (Board) -> (),
}

local INK = Color3.fromRGB(38, 30, 22)
local INK_SOFT = Color3.fromRGB(104, 88, 68)
local HIGHLIGHT = Color3.fromRGB(176, 104, 40)

local function row(parent: Instance, y: number, height: number): Frame
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, -60, 0, height)
	frame.Position = UDim2.fromOffset(30, y)
	frame.BackgroundTransparency = 1
	frame.Parent = parent
	return frame
end

local function text(parent: Instance, at: UDim2, size: UDim2, value: string, textSize: number, colour: Color3, bold: boolean?): TextLabel
	local label = Instance.new("TextLabel")
	label.Position = at
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextSize = textSize
	label.TextColor3 = colour
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = value
	label.Parent = parent
	return label
end

--------------------------------------------------------------------------------

function NoticeBoard.build(cfg: any, palette: { [string]: Color3 }, parent: Instance): Board
	local model = Instance.new("Model")
	model.Name = "NoticeBoard"

	local function colour(key: string): Color3
		return palette[key] or Color3.fromRGB(150, 150, 150)
	end

	local origin = CFrame.new(Units.vectorToStuds(Vector3.new(cfg.position[1], cfg.position[2], cfg.position[3])))
		* CFrame.Angles(0, math.rad(cfg.rotationY or 0), 0)

	local function slab(name: string, at: Vector3, size: Vector3, key: string, collide: boolean?): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Size = Units.vectorToStuds(size)
		part.CFrame = origin * CFrame.new(Units.vectorToStuds(at))
		part.Color = colour(key)
		part.Material = if key == "signBoard" then Enum.Material.SmoothPlastic else Enum.Material.Wood
		part.Anchored = true
		part.CanCollide = collide ~= false
		part.CanQuery = collide ~= false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		return part
	end

	local halfW = cfg.widthMetres / 2

	slab("PostLeft", Vector3.new(-halfW - 0.2, cfg.postHeightMetres / 2, 0), Vector3.new(0.28, cfg.postHeightMetres, 0.28), "signPost")
	slab("PostRight", Vector3.new(halfW + 0.2, cfg.postHeightMetres / 2, 0), Vector3.new(0.28, cfg.postHeightMetres, 0.28), "signPost")
	slab("Backer", Vector3.new(0, cfg.heightMetres / 2 + 0.5, 0), Vector3.new(cfg.widthMetres, cfg.heightMetres, 0.2), "barnWood")

	-- A little shingle roof, because a notice board in the woods that is not
	-- covered is a notice board that is unreadable in the rain.
	slab(
		"Roof",
		Vector3.new(0, cfg.postHeightMetres + 0.1, -cfg.roofOverhangMetres * 0.25),
		Vector3.new(cfg.widthMetres + 1.4, 0.16, cfg.roofOverhangMetres * 2),
		"barnWoodDark",
		false
	)

	local face = slab("Face", Vector3.new(0, cfg.heightMetres / 2 + 0.5, 0.12), Vector3.new(cfg.widthMetres - 0.5, cfg.heightMetres - 0.4, 0.06), "signBoard", false)

	local surface = Instance.new("SurfaceGui")
	surface.Face = Enum.NormalId.Front
	surface.CanvasSize = Vector2.new(900, 520)
	surface.LightInfluence = 0.2
	surface.Parent = face

	local canvas = Instance.new("Frame")
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundTransparency = 1
	canvas.Parent = surface

	local board: Board
	local currentPage = "speedball"
	local personalBests: { [string]: number } = {}
	local personalName = ""

	local function draw(pageId: string)
		canvas:ClearAllChildren()

		local maps: { string } = Config.mapNames()
		local isPersonal = pageId == "personal"

		local header = row(canvas, 18, 46)
		text(header, UDim2.fromScale(0, 0), UDim2.fromScale(0.7, 1),
			if isPersonal then "YOUR BEST TIMES" else `FASTEST FULL CLEAR  ·  {pageId:upper()}`,
			30, INK, true)
		text(header, UDim2.new(0.7, 0, 0, 0), UDim2.fromScale(0.3, 1),
			"ALL 5 ROUNDS", 20, INK_SOFT)

		local rule = Instance.new("Frame")
		rule.Size = UDim2.new(1, -60, 0, 2)
		rule.Position = UDim2.fromOffset(30, 70)
		rule.BorderSizePixel = 0
		rule.BackgroundColor3 = INK_SOFT
		rule.BackgroundTransparency = 0.4
		rule.Parent = canvas

		if isPersonal then
			text(canvas, UDim2.fromOffset(30, 84), UDim2.new(1, -60, 0, 26), personalName, 20, INK_SOFT)
			local y = 118
			for _, mapName in ipairs(maps) do
				local line = row(canvas, y, 40)
				text(line, UDim2.fromScale(0, 0), UDim2.fromScale(0.4, 1), mapName:upper(), 24, INK, true)
				local best = personalBests[mapName]
				text(line, UDim2.fromScale(0.42, 0), UDim2.fromScale(0.4, 1),
					if best then Leaderboard.formatTime(best) else "no full clear yet",
					24, if best then HIGHLIGHT else INK_SOFT, best ~= nil)
				y += 46
			end
			text(canvas, UDim2.fromOffset(30, 470), UDim2.new(1, -60, 0, 24),
				"A time means all five rounds, one match, no exceptions.", 17, INK_SOFT)
			return
		end

		local entries = Leaderboard.top(pageId)
		if #entries == 0 then
			text(canvas, UDim2.fromOffset(30, 120), UDim2.new(1, -60, 0, 40),
				"No full clears recorded yet.", 26, INK_SOFT, true)
			text(canvas, UDim2.fromOffset(30, 162), UDim2.new(1, -60, 0, 30),
				"Clear all five rounds and your name goes up here.", 20, INK_SOFT)
			return
		end

		local y = 88
		for _, entry in ipairs(entries) do
			local line = row(canvas, y, 36)
			text(line, UDim2.fromScale(0, 0), UDim2.fromScale(0.08, 1), `{entry.rank}.`, 22, INK_SOFT, true)
			text(line, UDim2.fromScale(0.08, 0), UDim2.fromScale(0.42, 1), entry.displayName, 22, INK, entry.rank <= 3)
			text(line, UDim2.fromScale(0.5, 0), UDim2.fromScale(0.22, 1),
				Leaderboard.formatTime(entry.seconds), 22,
				if entry.rank == 1 then HIGHLIGHT else INK, entry.rank == 1)
			text(line, UDim2.fromScale(0.72, 0), UDim2.fromScale(0.16, 1), entry.tier or "-", 19, INK_SOFT)
			text(line, UDim2.fromScale(0.88, 0), UDim2.fromScale(0.12, 1),
				if entry.deaths then `{entry.deaths} out` else "", 19, INK_SOFT)
			y += 38
		end
	end

	board = {
		model = model,
		surface = surface,

		setPage = function(self: Board, pageId: string)
			currentPage = pageId
			draw(pageId)
		end,

		refresh = function(self: Board)
			draw(currentPage)
		end,

		destroy = function(self: Board)
			self.model:Destroy()
		end,
	}

	--- The personal page is filled by the caller, which knows who is looking.
	function board.setPersonal(name: string, bests: { [string]: number })
		personalName = name
		personalBests = bests
		if currentPage == "personal" then
			draw(currentPage)
		end
	end

	model.PrimaryPart = face
	model.Parent = parent
	draw(currentPage)

	log.info("notice board raised")
	return board
end

--[[
	Starts the page cycle. Returns a stop function.

	Cycling on a timer rather than on input is deliberate: a board you have to
	operate is a board nobody reads. This one is legible from the trail.
]]
function NoticeBoard.startCycle(board: any): () -> ()
	local pages: { string } = {}
	for _, mapName in ipairs(Config.mapNames()) do
		table.insert(pages, mapName)
	end
	table.insert(pages, "personal")

	local pageSeconds = Config.require("leaderboard", "display.pageSeconds")
	local refreshSeconds = Config.require("leaderboard", "display.refreshSeconds")

	local running = true
	local index = 0
	local sinceRefresh = 0

	task.spawn(function()
		while running do
			index = (index % #pages) + 1
			board:setPage(pages[index])
			task.wait(pageSeconds)
			sinceRefresh += pageSeconds
			if sinceRefresh >= refreshSeconds then
				sinceRefresh = 0
				board:refresh()
			end
		end
	end)

	return function()
		running = false
	end
end

return NoticeBoard
