--!strict
-- Offline inspection only. Never executes scripts from downloaded models.
local r = require("@lune/roblox")
local fs = require("@lune/fs")
local roots = r.deserializeModel(fs.readFile(require("@lune/process").args[1]))
local counts = {}
for _, root in ipairs(roots) do
 for _, p in ipairs(root:GetDescendants()) do
  counts[p.ClassName] = (counts[p.ClassName] or 0) + 1
  if p:IsA("Model") or p:IsA("MaterialVariant") then print(p.ClassName, p:GetFullName()) end
 end
end
print(counts)
