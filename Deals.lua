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

-- Material (Trade Goods) peer-price undercut detection: need at least this
-- many current listings of an item to trust "far below the others" as a
-- real signal rather than ordinary price noise between two sellers.
local MATERIAL_MIN_LISTINGS = 3
-- The cheapest listing must be at least this much below the reference
-- price of the rest to count as an undercut worth flagging.
local MATERIAL_UNDERCUT_DISCOUNT = 0.35

Deals.flagged = {}      -- ordered array of flagged deal tables (see Evaluate)
Deals.flaggedByFingerprint = {} -- fingerprint -> the flagged deal table itself, for this scan's de-dup

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

--- Shared by Evaluate() and FlagMaterialUndercut(): computes every display/
-- decision field for a row (market value, vendor-flip flags, fingerprint)
-- without deciding whether it qualifies as a deal or inserting it anywhere.
local function buildRecord(itemKey, row)
	local scopeKey = PriceDB:ScopeKey()
	local marketValue, confidence, vendorFloor = PriceDB:GetMarketValue(scopeKey, itemKey)

	-- Vendor-price arbitrage is its own always-on check, independent of
	-- market history/confidence: a buyout at or below what a vendor pays
	-- is a guaranteed-profit flip the moment you buy it, no resale timing
	-- risk at all.
	local isVendorFlip = vendorFloor ~= nil and row.buyoutPerItem <= vendorFloor

	-- Minimum bid vs. vendor: informational only. Winning at the opening
	-- bid isn't guaranteed (someone else can outbid you), and our Buy
	-- engine only ever acts on a buyout, so this never changes whether a
	-- row is flagged -- it's a hint worth surfacing per the "buyout AND
	-- list price" request, not a buyable deal on its own.
	local minBidPerItem = (row.minBid and row.count and row.count > 0)
		and math.floor(row.minBid / row.count) or nil
	local isVendorFlipBid = vendorFloor ~= nil and minBidPerItem ~= nil and minBidPerItem <= vendorFloor

	local discountPct = marketValue and (1 - (row.buyoutPerItem / (marketValue * AH_CUT))) or nil

	-- De-dupe within this scan: the same physical auction can be seen
	-- more than once (a retried duplicate page, or an item appearing on
	-- more than one page boundary during a getAll). Fingerprint on
	-- everything that would make two sightings "the same auction".
	local fingerprint = table.concat({
		itemKey, row.link, row.count, row.buyoutPerItem, row.owner or "?",
	}, "|")

	return {
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
		vendorFloor = vendorFloor,
		isVendorFlip = isVendorFlip,
		minBidPerItem = minBidPerItem,
		isVendorFlipBid = isVendorFlipBid,
	}
end

--- Estimated copper profit for the whole stack if resold at the best price
-- basis currently available, cheapest-to-most-speculative:
--   1. Vendor flip: guaranteed -- vendor payout minus cost, no AH cut (you
--      don't pay the auction house's cut selling to a vendor).
--   2. Historical market value: expected -- resale at the recency-weighted
--      average price, minus the AH's cut.
--   3. Peer reference price (materials undercut, no history yet): a
--      same-scan estimate of "what everyone else is currently asking,"
--      minus the AH's cut.
-- Returns nil if none of the three are available (shouldn't normally
-- happen for anything that got flagged at all, but Threshold() and the
-- materials-undercut path are evaluated independently, so this stays
-- defensive rather than assuming one of the three is always set).
local function estimateProfit(record)
	if record.isVendorFlip then
		return (record.vendorFloor - record.buyoutPerItem) * record.count
	end

	local perItemResale = record.marketValue and (record.marketValue * AH_CUT)
		or (record.peerReferencePrice and (record.peerReferencePrice * AH_CUT))
	if not perItemResale then return nil end

	return (perItemResale - record.buyoutPerItem) * record.count
end

--- Evaluate one accepted auction row and, if it's a deal, add it to the
-- flagged list. Called by Scan.lua as each row is accepted -- reads only
-- already-committed PriceDB data, never the in-progress scan's own
-- staged samples (see PriceDB.lua header notes / the plan's
-- self-referential-pricing fix).
function Deals:Evaluate(row)
	-- row = { itemID, suffixID, link, name, iconTexture, count,
	--         buyoutPerItem, buyoutTotal, owner, minBid }
	local itemKey = Util.ItemKey(row.itemID, row.suffixID)
	if not itemKey then return end

	local scopeKey = PriceDB:ScopeKey()
	local marketValue, confidence, vendorFloor = PriceDB:GetMarketValue(scopeKey, itemKey)
	local threshold = self:Threshold(marketValue, confidence, vendorFloor)
	if not threshold then return end
	if row.buyoutPerItem > threshold then return end

	local record = buildRecord(itemKey, row)
	if self.flaggedByFingerprint[record.fingerprint] then return end
	record.potentialProfit = estimateProfit(record)
	self.flaggedByFingerprint[record.fingerprint] = record
	table.insert(self.flagged, record)
end

--- Flags a row as a materials peer-price undercut: not compared against
-- historical market value at all, but against what OTHER sellers are
-- currently asking for the same item in this same scan (see
-- EvaluateMaterialUndercuts below). If the row already got flagged via the
-- normal historical-value path, this just adds the tag to the existing
-- record rather than inserting a second copy.
function Deals:FlagMaterialUndercut(row, peerReferencePrice, peerDiscountPct)
	local itemKey = Util.ItemKey(row.itemID, row.suffixID)
	if not itemKey then return end

	local record = buildRecord(itemKey, row)
	local existing = self.flaggedByFingerprint[record.fingerprint]
	if existing then
		record = existing
	else
		self.flaggedByFingerprint[record.fingerprint] = record
		table.insert(self.flagged, record)
	end

	record.isMaterialUndercut = true
	record.peerReferencePrice = peerReferencePrice
	record.peerDiscountPct = peerDiscountPct
	record.potentialProfit = estimateProfit(record)
end

local function median(sorted)
	local n = #sorted
	if n == 0 then return nil end
	if n % 2 == 1 then return sorted[(n + 1) / 2] end
	return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

--- Crafting-material peer-price undercut detection: unlike Evaluate()
-- above (which compares a listing to *historical* market value), this
-- compares every current listing of an item this scan against each other.
-- A stack of ore priced far below every other current ore listing is
-- buyable-and-relistable profit the moment the scan sees it, even with
-- zero price history yet -- this needs no PriceDB history at all, only
-- what's on the AH right now.
--
-- Restricted to Trade Goods-class items (ore/bars/cloth/leather/herbs/
-- elemental motes/etc.) since that's what "crafting materials" means
-- here, and because comparing arbitrary junk items to each other this way
-- produces far more noise than signal.
--
-- Called once per scan commit (see Scan:CommitStaged) with the scan's
-- full `staged` table: staged[itemKey] = { prices = {...}, cheapestRow =
-- {...}, ... } (see Scan.lua's DoStagePage).
function Deals:EvaluateMaterialUndercuts(staged, scopeKey)
	for itemKey, entry in pairs(staged) do
		local prices = entry.prices
		local cheapestRow = entry.cheapestRow
		if prices and cheapestRow and #prices >= MATERIAL_MIN_LISTINGS
			and PriceDB:IsMaterial(scopeKey, itemKey) then

			local sorted = {}
			for i, p in ipairs(prices) do sorted[i] = p end
			table.sort(sorted)

			-- Reference price = median of every OTHER listing (drop one
			-- instance of the cheapest price so it can't drag down its
			-- own comparison point).
			local rest, removedOne = {}, false
			for _, p in ipairs(sorted) do
				if not removedOne and p == cheapestRow.buyoutPerItem then
					removedOne = true
				else
					table.insert(rest, p)
				end
			end

			local reference = median(rest)
			if reference and reference > 0 then
				local discount = 1 - (cheapestRow.buyoutPerItem / reference)
				if discount >= MATERIAL_UNDERCUT_DISCOUNT then
					self:FlagMaterialUndercut(cheapestRow, reference, discount)
				end
			end
		end
	end
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
