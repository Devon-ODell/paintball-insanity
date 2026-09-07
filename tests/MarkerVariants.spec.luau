--!strict
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS.Shared.Config)
local MarkerState = require(RS.Shared.MarkerState)
local Ballistics = require(RS.Shared.Ballistics)
local Payout = require(game:GetService("ServerScriptService").Server.Economy.Payout)

return function()
	describe("five Yardline paintball markers", function()
		local ids = { "yardTeal", "yardOchre", "yardOlive", "yardCobalt", "yardCoral" }
		it("provides five distinct colors and handling combinations", function()
			local colors, handling = {}, {}
			for _, id in ipairs(ids) do
				local marker = Config.get("markers").markers[id]
				expect(table.find(Config.get("markers").order, id) ~= nil).to.equal(true)
				expect(marker.archetype).to.equal("mechanical")
				local color = table.concat(marker.model.color, ",")
				local stats = `{marker.roundsPerMinute}/{marker.hopperCapacity}/{marker.reloadSeconds}`
				expect(colors[color]).to.equal(nil); colors[color] = true
				expect(handling[stats]).to.equal(nil); handling[stats] = true
				expect(marker.firstShotSpreadDeg).to.equal(Config.get("markers").markers.mechanical.firstShotSpreadDeg)
			end
		end)
		it("uses functioning marker state, ballistics and payout paths for every variant", function()
			for _, id in ipairs(ids) do
				local marker = Config.get("markers").markers[id]
				local state = MarkerState.new(marker)
				expect(state:fire(0)).to.equal(true)
				expect(state.ammo).to.equal(marker.hopperCapacity - 1)
				expect(state:fire(0)).to.equal(false)
				local spec = Ballistics.specFromMarker(marker, Config.get("ballistics"))
				expect(spec.muzzleVelocity > 0).to.equal(true)
				local result = Payout.compute({ map = "speedball", tier = "rec", marker = id,
					deaths = 0, shots = 100, hits = 20, longestStreak = 2, cleared = true })
				expect(result.total > 0).to.equal(true)
			end
		end)
	end)
end
