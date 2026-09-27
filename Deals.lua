-- Deals.lua
-- Decides whether a single auction row is "underpriced" relative to the
-- item's market value (or vendor floor, with no history yet), and keeps
-- the in-memory list of currently flagged deals that UI.lua renders and
-- Buy.lua acts on. Deals are a snapshot of the current scan, not
-- persisted -- PriceDB is the durable data, this is just "what's on the
-- AH right now that looks worth buying".

local _, Auctionist = ...
local Util = Auctionist.Util
local PriceDB = Auctionist.PriceDB

local Deals = {}
Auctionist.Deals = Deals

-- Discount tiers: how far below the (AH-cut-adjusted) market value a
-- buyout must be to count as a deal, by price band. Cheap items need a
-- much bigger relative discount to be worth the flip -- a few copper of
-- "profit" on a 50s item isn't worth a bag slot and a trip to the mailbox.
-- These are v1 placeholders, meant to be retuned once real data comes in;
-- the load-bearing property is the *shape* (discount required decreases as
-- price increases, floored at vendor sell), not these exact numbers.
local DISCOUNT_TIERS = {
	{ maxValue = 10000,    discount = 0.50 }, -- < 1g
	{ maxValue = 100000,   discount = 0.35 }, -- < 10g
	{ maxValue = 1000000,  discount = 0.25 }, -- < 100g
	{ maxValue = math.huge, discount = 0.15 }, -- >= 100g
}

-- Blizzard's auction house cut on a successful sale.
local AH_CUT = 0.95

Deals.flagged = {}      -- ordered array of flagged deal tables (see Evaluate)
Deals.flaggedByFingerprint = {} -- fingerprint -> true, for this scan's de-dup

--- Compute the buyout-per-item threshold at or below which an auction
-- counts as a deal.
-- @param marketValue copper per item, or nil if there's no scan history
-- @param confidence "none"|"low"|"high" (informational; the formula
--        itself doesn't currently vary by confidence beyond "none", but
--        callers use it to label deals as more or less trustworthy)
-- @param vendorFloor copper per item, or nil if unknown
-- @return threshold copper-per-item, or nil if no threshold can be
--         computed at all (no market value AND no vendor floor)
function Deals:Threshold(marketValue, confidence, vendorFloor)
	if not marketValue or confidence == "none" then
		-- No history at all yet. Only pure vendor-price arbitrage counts
		-- as a deal -- never guess a market-value-based threshold with
		-- zero data behind it.
		return vendorFloor
	end

	local effectiveResale = marketValue * AH_CUT
	local discount = DISCOUNT_TIERS[#DISCOUNT_TIERS].discount
	for _, tier in ipairs(DISCOUNT_TIERS) do
		if effectiveResale < tier.maxValue then
			discount = tier.discount
			break
		end
	end

	local threshold = effectiveResale * (1 - discount)
	if vendorFloor and vendorFloor > threshold then
		threshold = vendorFloor
	end
	return threshold
end

--- Clear the flagged-deal list. Called at the start of every scan (paged
-- or getAll) so stale deals from a previous scan don't linger after the
-- items they described have sold or changed price.
function Deals:Reset()
	self.flagged = {}
	self.flaggedByFingerprint = {}
end

--- Evaluate one accepted auction row and, if it's a deal, add it to the
-- flagged list. Called by Scan.lua as each row is accepted -- reads only
-- already-committed PriceDB data, never the in-progress scan's own
-- staged samples (see PriceDB.lua header notes / the plan's
-- self-referential-pricing fix).
function Deals:Evaluate(row)
	-- row = { itemID, suffixID, link, name, iconTexture, count,
	--         buyoutPerItem, buyoutTotal, owner }
	local itemKey = Util.ItemKey(row.itemID, row.suffixID)
	if not itemKey then return end

	local scopeKey = PriceDB:ScopeKey()
	local marketValue, confidence, vendorFloor = PriceDB:GetMarketValue(scopeKey, itemKey)
	local threshold = self:Threshold(marketValue, confidence, vendorFloor)
	if not threshold then return end

	if row.buyoutPerItem > threshold then return end

	-- De-dupe within this scan: the same physical auction can be seen
	-- more than once (a retried duplicate page, or an item appearing on
	-- more than one page boundary during a getAll). Fingerprint on
	-- everything that would make two sightings "the same auction".
	local fingerprint = table.concat({
		itemKey, row.link, row.count, row.buyoutPerItem, row.owner or "?",
	}, "|")
	if self.flaggedByFingerprint[fingerprint] then return end
	self.flaggedByFingerprint[fingerprint] = true

	local discountPct = marketValue and (1 - (row.buyoutPerItem / (marketValue * AH_CUT))) or nil

	table.insert(self.flagged, {
		fingerprint = fingerprint,
		itemKey = itemKey,
		itemID = row.itemID,
		suffixID = row.suffixID,
		link = row.link,
		name = row.name,
		iconTexture = row.iconTexture,
		count = row.count,
		buyoutPerItem = row.buyoutPerItem,
		buyoutTotal = row.buyoutTotal,
		owner = row.owner,
		marketValue = marketValue,
		confidence = confidence or "none",
		discountPct = discountPct,
	})
end

--- Remove a flagged deal (e.g. after a successful buy, or a definitive
-- "it's gone" failure from Buy.lua) so it stops showing in the list.
function Deals:Remove(fingerprint)
	for i, deal in ipairs(self.flagged) do
		if deal.fingerprint == fingerprint then
			table.remove(self.flagged, i)
			self.flaggedByFingerprint[fingerprint] = nil
			return
		end
	end
end

function Deals:GetFlagged()
	return self.flagged
end

return Deals
