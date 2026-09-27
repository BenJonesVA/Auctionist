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

function PriceDB:Commit(scopeKey, staged, dayKey)
	dayKey = dayKey or Util.TodayKey()
	local now = time()

	for itemKey, data in pairs(staged) do
		local prices = data.prices
		if prices and #prices > 0 then
			table.sort(prices)

			local item = self:GetItemEntry(scopeKey, itemKey, true)
			item.itemID = data.itemID
			item.suffixID = data.suffixID
			if data.name then item.name = data.name end
			if data.iconTexture then item.iconTexture = data.iconTexture end
			item.lastSeen = now

			item.days[dayKey] = {
				p10 = computePercentile(prices, 0.10),
				min = prices[1],
				n = #prices,
			}
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
