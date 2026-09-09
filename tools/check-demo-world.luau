--!strict
-- Validate code-built world/avatar properties against Lune's Roblox datatype database.
local Harness = require("./Harness")
local roblox = require("@lune/roblox")
local env = Harness.build()
env.globals.Instance = roblox.Instance
local lighting = roblox.Instance.new("Lighting")
local getService = env.game.GetService
env.game.GetService = function(self: any, name: string): any
    return if name == "Lighting" then lighting else getService(self, name)
end
env.globals.UDim2 = roblox.UDim2
env.globals.Enum = roblox.Enum
local WorldBuilder = env.require(env.Server.Match.WorldBuilder)
local FieldDetails = env.require(env.Server.Match.FieldDetails)
local BotAvatar = env.require(env.Server.Match.BotAvatar)
local root = roblox.Instance.new("Folder")
local Config = env.require(env.Shared.Config)
local Units = env.require(env.Shared.Units)
for _, name in ipairs(Config.mapNames()) do
    local world = WorldBuilder.build(name, root)
    local venue = FieldDetails.build(name, world)
    assert(venue.exit.Interact and venue.enter.Interact and venue.counter.Interact)
    local map = Config.map(name)
    local geometryCount = 0
    for _, group in ipairs({ map.terrain or {}, map.geometry or {} }) do
        for _, piece in ipairs(group) do
            geometryCount += (if piece.mirrorX then 2 else 1) * (if piece.mirrorZ then 2 else 1)
        end
    end
    assert(#world.Geometry:GetChildren() == geometryCount, name .. ": lost gameplay geometry")
    for _, part in ipairs(world.Presentation:GetDescendants()) do
        if part:IsA("BasePart") then
            assert(not part.CanCollide and not part.CanQuery and not part.CanTouch,
                name .. ": cosmetic dressing entered physics/raycasts")
            assert(not part.CastShadow, name .. ": detail became an unbudgeted shadow caster")
            if part.Name:find("TreeLine") then
                local p = Units.vectorToMetres(part.CFrame.Position)
                assert(math.abs(p.X) > map.bounds.widthMetres / 2 or math.abs(p.Z) > map.bounds.lengthMetres / 2,
                    name .. ": perimeter tree moved onto a gameplay lane")
            end
        end
    end
    assert((venue.model:FindFirstChild("MownTurf") ~= nil) == map.presentation.groundStripes,
        name .. ": inappropriate tournament stripes")
    local displays = 0
    for _, part in ipairs(venue.model:GetChildren()) do
        if part.Name:sub(1, 8) == "Display_" then
            displays += 1
            assert(math.abs(Units.vectorToMetres(part.Position).X) < Config.get("presentation").venue.displayWidthMetres / 2,
                name .. ": marker display escaped the counter")
        end
    end
    assert(displays == #Config.get("markers").order, name .. ": missing catalogue display")
    assert(#lighting:GetChildren() == 6, "map changes stacked lighting effects")
    assert(lighting.LiveRoundSky:IsA("Sky"), "missing sky and reflection environment")
    assert(not lighting.LiveRoundDof.Enabled, "combat depth of field blurred distant targets")
    local avatar = BotAvatar.new("bot1", "Demo Bot", world)
    avatar:setPosition(roblox.Vector3.zero, roblox.Vector3.zAxis)
    avatar:splatter(roblox.Vector3.new(0, 1, 0))
    local partCount, shadows, touches = 0, 0, 0
    for _, part in ipairs(world:GetDescendants()) do
        if part:IsA("BasePart") then
            partCount += 1
            if part.CastShadow then shadows += 1 end
            if part.CanTouch then touches += 1 end
        end
    end
    print(`Built {name}: {partCount} parts / {shadows} shadow casters / {touches} touch-enabled parts`)
    world:Destroy()
end

local Foliage = env.require(env.Server.World.Foliage)
local hub = Config.get("overworld")
local palette = {}
for key, rgb in pairs(hub.palette) do
    if type(rgb) == "table" then palette[key] = roblox.Color3.fromRGB(rgb[1], rgb[2], rgb[3]) end
end
local forest = roblox.Instance.new("Folder")
local plants = Foliage.scatter(hub.scatter, palette, hub.trails, forest)
local parts, shadows = 0, 0
for _, part in ipairs(forest:GetDescendants()) do
    if part:IsA("BasePart") then
        parts += 1
        if part.CastShadow then shadows += 1 end
        assert(not part.CanTouch, "foliage should never subscribe to physics touches")
        if part.Name:find("Frond") or part.Name:find("Blade") or part.Name == "Stem" or part.Name == "Head" then
            assert(not part.CastShadow, "small undergrowth should not cast shadows")
        end
    end
end
print(`Hub foliage: {plants} plants / {parts} parts / {shadows} shadow casters (was {parts})`)
forest:Destroy()
print("All five maps, their lighting, displays, decoration contracts and hub foliage construct successfully.")
