-- PriceDB.lua
-- Owns the AuctionistDB SavedVariables schema and everything that reads or
-- writes it: committing scan results, computing a market-value estimate
-- with a confidence rating, tracking vendor sell price as a floor, and
-- pruning old data so the file stays bounded.
--
-- Deliberately NOT keyed by item name (see lessonslearned.md-driven design
-- notes in the plan): everything is keyed by Util.ItemKey(itemID, suffixID).

local _, Auctionist = ...
local Util = Auctionist.Util

local PriceDB = {}
Auctionist.PriceDB = PriceDB

-- How many days of daily buckets we read when computing market value.
local WINDOW_DAYS = 14
-- How many days of daily buckets we keep on disk before deleting them
-- (a little past the read window, in case the player skips scanning for
-- a while and we don't want to throw away data we'd otherwise still use).
local PRUNE_DAYS = 30
-- A single very-high-volume scan day shouldn't permanently dominate every
-- future average; cap the weight any one day's sample count contributes.
local SAMPLE_WEIGHT_CAP = 50
-- Mild recency decay so a two-week-old data point counts for less than
-- yesterday's, without falling off a cliff.
local RECENCY_DECAY = 0.90

-- Confidence thresholds.
local LOW_CONFIDENCE_MIN_SAMPLES = 20
local LOW_CONFIDENCE_MIN_DAYS = 3

--------------------------------------------------------------------------
-- Schema init
--------------------------------------------------------------------------

function PriceDB:Init()
	if type(AuctionistDB) ~= "table" then
		AuctionistDB = { version = 1, scopes = {} }
	end
	if type(AuctionistDB.scopes) ~= "table" then
		AuctionistDB.scopes = {}
	end
	self.db = AuctionistDB
end

--- Realm+faction scope key. Neutral (goblin) AH auctions get folded into
-- the character's home-faction scope -- a known, accepted v1 limitation
-- (noted in the plan), not something this function tries to solve.
function PriceDB:ScopeKey()
	local realm = GetRealmName() or "UnknownRealm"
	local faction = UnitFactionGroup("player") or "Neutral"
	return realm .. "-" .. faction
end

function PriceDB:GetScope(scopeKey, create)
	local scopes = self.db.scopes
	local scope = scopes[scopeKey]
	if not scope and create then
		scope = { items = {} }
		scopes[scopeKey] = scope
	end
	return scope
end

function PriceDB:GetItemEntry(scopeKey, itemKey, create)
	local scope = self:GetScope(scopeKey, create)
	if not scope then return nil end

	local item = scope.items[itemKey]
	if not item and create then
		item = { days = {} }
		scope.items[itemKey] = item
	end
	return item
end

--------------------------------------------------------------------------
-- Commit
--------------------------------------------------------------------------
-- `staged` shape (built by Scan.lua over the course of one scan run):
--   staged[itemKey] = {
--     itemID = number, suffixID = number,
--     name = string, iconTexture = string,
--     prices = { unitPrice1, unitPrice2, ... },   -- one per accepted row
--   }
-- One call to Commit condenses each item's full sample list down to a
-- single day-bucket record. This is what keeps the SavedVariables file
-- bounded regardless of how many rows a getAll scan walked.

local function computePercentile(sortedPrices, pct)
	local n = #sortedPrices
	if n == 0 then return nil end
	local idx = math.ceil(pct * n)
	if idx < 1 then idx = 1 end
	if idx > n then idx = n end
	return sortedPrices[idx]
end

-- A lone ask priced far above every other current listing of the same
-- item is far more likely to be a seller who mis-priced (or is squatting
-- on) their auction than a genuine shift in the item's value. Left in,
-- even a single such listing can single-handedly become an item's entire
-- p10/market-value estimate (especially for a rarely-listed item), which
-- then makes a completely unrelated, legitimately-priced stack of the
-- same item look like an enormous "deal" against a price nobody is
-- actually paying. Needs at least this many concurrent listings to have
-- any real basis for comparison -- with only 1-2 prices, there's no way
-- to tell a genuine price from an outlier, so nothing is stripped.
local OUTLIER_MIN_SAMPLES = 3
-- More than this many times the sample's own median counts as an outlier.
local OUTLIER_MULTIPLIER = 4

local function medianOf(sortedPrices)
	local n = #sortedPrices
	if n == 0 then return nil end
	if n % 2 == 1 then return sortedPrices[(n + 1) / 2] end
	return (sortedPrices[n / 2] + sortedPrices[n / 2 + 1]) / 2
end

--- Strips high-side price outliers from an already-sorted price list
-- before it's used to compute a day's p10/min/n. Returns the (possibly
-- shorter) surviving list and how many prices were stripped (0 if none,
-- or if there weren't enough samples to judge). Never strips everything
-- -- if every price is somehow "an outlier" relative to the median, that
-- median itself isn't a trustworthy baseline, so the original list is
-- kept as-is rather than committing an empty day.
local function stripHighOutliers(sortedPrices)
	if #sortedPrices < OUTLIER_MIN_SAMPLES then
		return sortedPrices, 0
	end

	local median = medianOf(sortedPrices)
	if not median or median <= 0 then return sortedPrices, 0 end

	local kept = {}
	for _, p in ipairs(sortedPrices) do
		if p <= median * OUTLIER_MULTIPLIER then
			table.insert(kept, p)
		end
	end

	if #kept == 0 or #kept == #sortedPrices then
		return sortedPrices, 0
	end
	return kept, #sortedPrices - #kept
end

--- Merge a freshly-committed day-bucket with whatever was already recorded
-- for that item today. Raw prices from an earlier commit this same day
-- aren't kept around (that would defeat the point of condensing at all),
-- so the merge is a sample-count-weighted average of the two p10s rather
-- than a true recomputed percentile of the combined raw data -- a
-- reasonable approximation for combining two independent scans of the
-- same day, and far better than letting the second scan silently erase
-- the first's contribution to today's bucket.
local function mergeDayBucket(existing, freshP10, freshMin, freshN)
	if not existing then
		return { p10 = freshP10, min = freshMin, n = freshN }
	end
	local totalN = existing.n + freshN
	local mergedP10 = (existing.p10 * existing.n + freshP10 * freshN) / totalN
	return {
		p10 = mergedP10,
		min = math.min(existing.min, freshMin),
		n = totalN,
	}
end

function PriceDB:Commit(scopeKey, staged, dayKey)
	dayKey = dayKey or Util.TodayKey()
	local now = time()

	for itemKey, data in pairs(staged) do
		local prices = data.prices
		if prices and #prices > 0 then
			table.sort(prices)

			local kept, stripped = stripHighOutliers(prices)
			if stripped > 0 then
				print(string.format(
					"Auctionist: ignored %d insanely overpriced listing%s of %s when updating its market value.",
					stripped, stripped > 1 and "s" or "", data.name or "?"))
			end

			local item = self:GetItemEntry(scopeKey, itemKey, true)
			item.itemID = data.itemID
			item.suffixID = data.suffixID
			if data.name then item.name = data.name end
			if data.iconTexture then item.iconTexture = data.iconTexture end
			item.lastSeen = now

			item.days[dayKey] = mergeDayBucket(item.days[dayKey],
				computePercentile(kept, 0.10), kept[1], #kept)
		end
	end
end

--------------------------------------------------------------------------
-- Market value
--------------------------------------------------------------------------

--- @return value (copper per item, or nil if no data at all),
--         confidence ("none"|"low"|"high"),
--         vendorFloor (copper per item, or nil if unknown)
function PriceDB:GetMarketValue(scopeKey, itemKey)
	local item = self:GetItemEntry(scopeKey, itemKey, false)
	local vendorFloor = item and item.vendorSell
	if not vendorFloor or vendorFloor <= 0 then vendorFloor = nil end

	if not item or not item.days then
		return nil, "none", vendorFloor
	end

	local todayOrdinal = math.floor(time() / 86400)
	local weightedSum, weightedWeight = 0, 0
	local totalSamples, distinctDays = 0, 0

	for dayKey, bucket in pairs(item.days) do
		if bucket.p10 then
			local y, m, d = dayKey:sub(1, 4), dayKey:sub(5, 6), dayKey:sub(7, 8)
			local bucketTime = time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
			local ageDays = math.max(0, todayOrdinal - math.floor(bucketTime / 86400))

			if ageDays <= WINDOW_DAYS then
				local n = math.min(bucket.n or 0, SAMPLE_WEIGHT_CAP)
				local weight = n * (RECENCY_DECAY ^ ageDays)
				weightedSum = weightedSum + bucket.p10 * weight
				weightedWeight = weightedWeight + weight
				totalSamples = totalSamples + (bucket.n or 0)
				distinctDays = distinctDays + 1
			end
		end
	end

	if weightedWeight <= 0 then
		return nil, "none", vendorFloor
	end

	local value = weightedSum / weightedWeight

	local confidence
	if totalSamples < LOW_CONFIDENCE_MIN_SAMPLES or distinctDays < LOW_CONFIDENCE_MIN_DAYS then
		confidence = "low"
	else
		confidence = "high"
	end

	return value, confidence, vendorFloor
end

--------------------------------------------------------------------------
-- Vendor sell price
--------------------------------------------------------------------------

function PriceDB:SetVendorSell(scopeKey, itemKey, copperPerItem)
	if not copperPerItem or copperPerItem <= 0 then return end
	local item = self:GetItemEntry(scopeKey, itemKey, true)
	item.vendorSell = copperPerItem
end

function PriceDB:GetVendorSell(scopeKey, itemKey)
	local item = self:GetItemEntry(scopeKey, itemKey, false)
	return item and item.vendorSell or nil
end

-- GetItemInfo's 11th return (vendor sell price) is nil until the client
-- has cached that item's info -- very likely already true for anything
-- an auction link resolves, but not guaranteed. When it's missing, queue
-- an async resolve: a hidden GameTooltip:SetHyperlink primes the cache,
-- retried in small batches (never the whole queue at once, which could
-- be thousands of distinct items deep into a getAll scan) until
-- GetItemInfo answers.
local VENDOR_LOOKUP_INTERVAL = 0.2
local VENDOR_LOOKUP_BATCH = 15

--- Look up (and cache) an item's vendor sell price and item-type string.
-- Safe to call for every accepted scan row -- a no-op if the sell price is
-- already known, and resolution for an unknown one happens asynchronously
-- via OnUpdate. Piggybacks the item-type capture (GetItemInfo's 6th
-- return) onto the same call, since it's needed for material-class
-- detection (see IsMaterial below) and comes from the exact same cached
-- item-info lookup as the sell price -- no separate queue needed.
function PriceDB:ResolveVendorSell(scopeKey, itemKey, link)
	if self:GetVendorSell(scopeKey, itemKey) then return end

	local info = { GetItemInfo(link) }
	local itemType, sellPrice = info[6], info[11]
	if itemType then
		self:GetItemEntry(scopeKey, itemKey, true).itemType = itemType
	end
	if sellPrice and sellPrice > 0 then
		self:SetVendorSell(scopeKey, itemKey, sellPrice)
		return
	end

	self.pendingVendorLookups = self.pendingVendorLookups or {}
	for _, q in ipairs(self.pendingVendorLookups) do
		if q.scopeKey == scopeKey and q.itemKey == itemKey then return end -- already queued
	end
	table.insert(self.pendingVendorLookups, { scopeKey = scopeKey, itemKey = itemKey, link = link })
end

--- Driven from Core.lua's master OnUpdate. Processes a bounded,
-- round-robin slice of the pending-lookup queue every
-- VENDOR_LOOKUP_INTERVAL seconds rather than the whole queue every
-- frame.
function PriceDB:OnUpdate(elapsed)
	self:ResolveTradeGoodsLabel()

	local pending = self.pendingVendorLookups
	if not pending or #pending == 0 then return end

	self.vendorLookupElapsed = (self.vendorLookupElapsed or 0) + elapsed
	if self.vendorLookupElapsed < VENDOR_LOOKUP_INTERVAL then return end
	self.vendorLookupElapsed = 0

	if not self.vendorLookupTooltip then
		local tt = CreateFrame("GameTooltip", "AuctionistVendorScanTooltip", nil, "GameTooltipTemplate")
		tt:SetOwner(UIParent, "ANCHOR_NONE")
		self.vendorLookupTooltip = tt
	end

	local batch = math.min(VENDOR_LOOKUP_BATCH, #pending)
	local still = {}
	for i = batch + 1, #pending do
		table.insert(still, pending[i])
	end
	for i = 1, batch do
		local q = pending[i]
		local info = { GetItemInfo(q.link) }
		local itemType, sellPrice = info[6], info[11]
		if itemType then
			self:GetItemEntry(q.scopeKey, q.itemKey, true).itemType = itemType
		end
		if sellPrice and sellPrice > 0 then
			self:SetVendorSell(q.scopeKey, q.itemKey, sellPrice)
		else
			self.vendorLookupTooltip:SetHyperlink(q.link)
			table.insert(still, q) -- goes to the back -- round-robin, not starved
		end
	end
	self.pendingVendorLookups = still
end

--------------------------------------------------------------------------
-- Material (Trade Goods) classification
--------------------------------------------------------------------------
-- "Is this a crafting material" needs to compare an item's itemType string
-- (GetItemInfo's 6th return, e.g. localized "Trade Goods") against the
-- right category name -- but that name is locale-dependent and this
-- project has no verified reference for the exact string, or for which
-- position "Trade Goods" occupies in GetAuctionItemClasses()'s array (both
-- would be guesses). Instead, this learns the label at runtime from a
-- known-Trade-Goods reference item (Copper Ore), the same way Auctionator
-- resolves item-type-to-class (AuctionatorLocalize.lua's
-- Atr_ItemType2AuctionClass): read the real API's own answer for a known
-- item, rather than hardcode an assumption about it.
local TRADE_GOODS_REFERENCE_ITEM_ID = 2770 -- Copper Ore

--- Learns this client's localized "Trade Goods" item-type string, if not
-- already known. Cheap/no-op once resolved; called every PriceDB:OnUpdate
-- tick alongside the vendor-lookup queue.
function PriceDB:ResolveTradeGoodsLabel()
	if self.tradeGoodsLabel then return end

	local itemType = select(6, GetItemInfo(TRADE_GOODS_REFERENCE_ITEM_ID))
	if itemType then
		self.tradeGoodsLabel = itemType
		return
	end

	if not self.tradeGoodsLabelTooltip then
		local tt = CreateFrame("GameTooltip", "AuctionistTradeGoodsLabelTooltip", nil, "GameTooltipTemplate")
		tt:SetOwner(UIParent, "ANCHOR_NONE")
		self.tradeGoodsLabelTooltip = tt
	end
	self.tradeGoodsLabelTooltip:SetHyperlink("item:" .. TRADE_GOODS_REFERENCE_ITEM_ID)
end

function PriceDB:GetItemType(scopeKey, itemKey)
	local item = self:GetItemEntry(scopeKey, itemKey, false)
	return item and item.itemType or nil
end

--- @return true/false once both the item's own type and the reference
--         label are known, or nil if either isn't resolved yet (callers
--         must treat nil as "don't know, skip" -- never as "not a
--         material").
function PriceDB:IsMaterial(scopeKey, itemKey)
	local itemType = self:GetItemType(scopeKey, itemKey)
	if not itemType or not self.tradeGoodsLabel then return nil end
	return itemType == self.tradeGoodsLabel
end

--------------------------------------------------------------------------
-- Pruning
--------------------------------------------------------------------------

--- Drop day-buckets older than PRUNE_DAYS, and drop whole item entries
-- that have no vendor price cached and haven't been seen in a scan for
-- PRUNE_DAYS either (cheap junk that appeared once and will never matter
-- again -- otherwise these would accumulate in the file forever).
function PriceDB:Prune(scopeKey)
	local scope = self:GetScope(scopeKey, false)
	if not scope then return end

	local todayOrdinal = math.floor(time() / 86400)

	for itemKey, item in pairs(scope.items) do
		if item.days then
			for dayKey, _ in pairs(item.days) do
				local y, m, d = dayKey:sub(1, 4), dayKey:sub(5, 6), dayKey:sub(7, 8)
				local ok, bucketTime = pcall(time, { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
				if not ok or math.max(0, todayOrdinal - math.floor(bucketTime / 86400)) > PRUNE_DAYS then
					item.days[dayKey] = nil
				end
			end
		end

		local hasDays = item.days and next(item.days) ~= nil
		local lastSeenAge = item.lastSeen and (time() - item.lastSeen) / 86400 or math.huge
		local hasVendorPrice = item.vendorSell and item.vendorSell > 0

		if not hasDays and not hasVendorPrice and lastSeenAge > PRUNE_DAYS then
			scope.items[itemKey] = nil
		end
	end
end

return PriceDB
