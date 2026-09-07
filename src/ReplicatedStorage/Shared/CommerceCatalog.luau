--!strict
-- Shared display policy; transactions always use the server's copy.
local Config = require(script.Parent.Config)
local CommerceCatalog = {}
local testOverride: any = nil

function CommerceCatalog.config(): any
	return testOverride or Config.get("monetization")
end

function CommerceCatalog.isFree(): boolean
	return CommerceCatalog.config().freeMode == true
end

function CommerceCatalog.shopCost(baseCost: any): number?
	-- nil denotes earned-only, never a zero-price shortcut past a challenge.
	if type(baseCost) ~= "number" or baseCost ~= baseCost or baseCost < 0 or baseCost == math.huge then
		return nil
	end
	return if CommerceCatalog.isFree() or CommerceCatalog.config().shopFree == true then 0 else baseCost
end

function CommerceCatalog.offer(id: any): any?
	if type(id) ~= "string" then return nil end
	return CommerceCatalog.config().offers[id]
end

function CommerceCatalog.validId(id: any): boolean
	return type(id) == "number" and id > 0 and id < math.huge and id == math.floor(id)
end

function CommerceCatalog.canPrompt(offer: any): boolean
	local cfg = CommerceCatalog.config()
	return cfg.freeMode == false and cfg.paidEnabled == true and offer ~= nil
		and offer.enabled == true and CommerceCatalog.validId(offer.marketplaceId)
end

function CommerceCatalog._setOverrideForTesting(value: any?)
	testOverride = value
end

return CommerceCatalog
