--!strict
-- Rojo packages source but does not compile it. Check every source file without
-- executing scripts, including client code that pure specs do not require.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local count = 0
local function walk(path: string)
	for _, entry in ipairs(fs.readDir(path)) do
		local file = path .. "/" .. entry
		if fs.isDir(file) then walk(file)
		elseif entry:match("%.luau$") then
			luau.load(fs.readFile(file), { debugName = file })
			count += 1
		end
	end
end
walk("src"); walk("tests"); walk("tools")
print(`Compiled {count} Luau files successfully (syntax check, not engine type analysis).`)
