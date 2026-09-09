--!strict
--[[
	Squad callouts.

	The bearing is the part worth pinning. `Chatter.bearingWord` was written,
	carefully commented, and then never called from anywhere -- so every callout
	that interpolates `{bearing}` fell through to its default and the squad
	reported every contact in the game as "Contact! front!" regardless of where
	the player actually was. "I'm rotating front." is not even English.

	It is wired now, measured from the speaker's own facing. These assert the
	boundaries rather than the middles: a word that is right at 90 degrees and
	wrong at 100 is the kind of thing that reads as "the bots are a bit stupid"
	rather than as a bug.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Chatter = require(game:GetService("ServerScriptService").Server.Bots.Chatter)
local Config = require(ReplicatedStorage.Shared.Config)

return function()
	describe("bearing words", function()
		it("names the four cardinals from the speaker's facing", function()
			expect(Chatter.bearingWord(0)).to.equal("front")
			expect(Chatter.bearingWord(90)).to.equal("right")
			expect(Chatter.bearingWord(-90)).to.equal("left")
			expect(Chatter.bearingWord(180)).to.equal("behind")
		end)

		it("names the diagonals", function()
			expect(Chatter.bearingWord(45)).to.equal("front right")
			expect(Chatter.bearingWord(-45)).to.equal("front left")
		end)

		--- Coarse on purpose: a squad calling exact degrees is a wallhack.
		it("stays coarse -- six words, no more", function()
			local words: { [string]: boolean } = {}
			for degrees = -180, 180 do
				words[Chatter.bearingWord(degrees)] = true
			end
			local count = 0
			for _ in pairs(words) do
				count += 1
			end
			expect(count).to.equal(6)
		end)

		it("wraps, so a bearing past a full turn is still a word", function()
			expect(Chatter.bearingWord(360)).to.equal("front")
			expect(Chatter.bearingWord(-270)).to.equal("right")
			expect(Chatter.bearingWord(450)).to.equal("right")
		end)

		--- Every angle has to produce something. A nil here is a callout that
		--- interpolates the word "nil" into the middle of a sentence.
		it("never returns nothing", function()
			for degrees = -720, 720, 3 do
				expect(type(Chatter.bearingWord(degrees))).to.equal("string")
			end
		end)
	end)

	describe("the shipped bank", function()
		--[[
			If a line interpolates a placeholder nothing fills, the player reads
			the placeholder. `{bearing}` was effectively in that state for the
			whole project until it was wired.
		]]
		it("only interpolates placeholders the game actually fills", function()
			local allowed = { name = true, alive = true, bearing = true }
			local function scan(node: any)
				if type(node) == "string" then
					for placeholder in string.gmatch(node, "{(%a+)}") do
						expect(allowed[placeholder]).to.equal(true)
					end
				elseif type(node) == "table" then
					for key, value in pairs(node) do
						if type(key) ~= "string" or string.sub(key, 1, 1) ~= "_" then
							scan(value)
						end
					end
				end
			end
			scan(Config.get("chatter").banks)
			scan(Config.get("chatter").callouts)
		end)
	end)
end
