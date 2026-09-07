--!nolint
-- Prints the ballistics curve for every marker. Run after changing markers.json
-- or ballistics.json to see what the tuning actually does.
local Harness = require("./Harness")
local env = Harness.build()
local RS = env.ReplicatedStorage
local Ballistics = env.require(RS.Shared.Ballistics)
local BD = env.require(RS.Data.ballistics)
local Markers = env.require(RS.Data.markers)
local bw = BD.hitbox.bodyWidthMetres
local sprint = BD._designTargets.sprintSpeedMps

for _, name in ipairs(Markers.order) do
	local m = Markers.markers[name]
	local spec = Ballistics.specFromMarker(m, BD)
	print(string.format("\n%s  (v0=%.0f m/s, k=%.4f /m)", m.displayName, spec.muzzleVelocity, spec.dragK))
	print(string.format("  %5s %8s %8s %8s %10s", "dist", "tof(s)", "vel(m/s)", "drop(m)", "lead(bw)"))
	for _, d in ipairs({ 5, 10, 15, 20, 25, 30, 40, 50, 60, 75 }) do
		local t = Ballistics.timeOfFlight(spec, d)
		print(string.format("  %5.0f %8.3f %8.1f %8.3f %10.2f",
			d, t, Ballistics.speedAfter(spec, d), Ballistics.dropAt(spec, d),
			Ballistics.leadAt(spec, d, sprint) / bw))
	end
end
