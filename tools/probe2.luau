local Harness = require("./Harness")
local env = Harness.build()
print("tree ok")
for _, c in ipairs(env.ReplicatedStorage:GetChildren()) do print(" RS ->", c.Name, c.ClassName) end
for _, c in ipairs(env.Data:GetChildren()) do print(" Data ->", c.Name, c.ClassName) end
local ball = env.require(env.Data.ballistics)
print("gravity =", ball.gravity, "studsPerMetre =", ball.studsPerMetre)
