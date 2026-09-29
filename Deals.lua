-- Deals.lua
-- Decides whether a single auction row is "underpriced" relative to the
-- item's market value (or vendor floor, with no history yet), and keeps
-- the in-memory list of currently flagged deals that UI.lua renders and
-- Buy.lua acts on. Deals are a snapshot of what scans have actually seen
-- -- PriceDB is the durable price-history data, this is "what's worth
-- buying" -- but the list itself now survives a /reload too (see
-- Init/RestoreFromDB), since entries carry a `seenAt` timestamp the UI
-- can use to show staleness rather than needing a fresh scan every time.

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

-- How old a flagged deal's last confirmed sighting can be before the UI
-- should treat it as "stale" (i.e. don't fully trust the price/existence
-- without re-checking) -- used for the Stale column and the Purge Stale
-- button. A restored-from-reload deal is exactly as stale as its age.
local STALE_SECONDS = 20 * 60

Deals.flagged = {}      -- ordered array of flagged deal tables (see Evaluate)
Deals.flaggedByFingerprint = {} -- fingerprint -> the flagged deal table itself, for this scan's de-dup
Deals.version = 0        -- bumped on every mutation; UI uses this to know when to redraw

--------------------------------------------------------------------------
-- Persistence: survive a /reload without needing a fresh scan first.
--------------------------------------------------------------------------

--- Called once from Core.lua's PLAYER_LOGIN handler, after PriceDB is
-- already initialized. Deliberately NOT at ADDON_LOADED -- ScopeKey()
-- depends on the player's faction, which isn't reliably known that early
-- (see PriceDB.lua's own ScopeKey comment), and getting that wrong here
-- would restore into (or later save under) the wrong realm-faction scope.
function Deals:Init()
	AuctionistDB.deals = AuctionistDB.deals or {}
	self.db = AuctionistDB.deals
	self:RestoreFromDB(PriceDB:ScopeKey())
end

--- Loads whatever was persisted for this scope back into the live
-- in-memory list. Entries keep their original `seenAt`, so anything old
-- enough shows up as stale immediately -- restoring is not the same as
-- re-confirming.
function Deals:RestoreFromDB(scopeKey)
	local saved = self.db and self.db[scopeKey]
	self.flagged = (saved and saved.flagged) or {}
	self.flaggedByFingerprint = {}
	for _, deal in ipairs(self.flagged) do
		self.flaggedByFingerprint[deal.fingerprint] = deal
	end
	self.lastSavedVersion = self.version
end

--- Writes the current flagged list back to SavedVariables. Cheap to call
-- often (Core.lua's OnUpdate calls this on a slow timer, only actually
-- writing when `version` has moved since the last save) since a scan can
-- mutate the list many times a second.
function Deals:SaveToDB()
	if not self.db then return end
	local scopeKey = PriceDB:ScopeKey()
	self.db[scopeKey] = self.db[scopeKey] or {}
	self.db[scopeKey].flagged = self.flagged
	self.lastSavedVersion = self.version
end

local SAVE_CHECK_INTERVAL = 5

--- Driven from Core.lua's master OnUpdate.
function Deals:OnUpdate(elapsed)
	self.saveCheckElapsed = (self.saveCheckElapsed or 0) + elapsed
	if self.saveCheckElapsed < SAVE_CHECK_INTERVAL then return end
	self.saveCheckElapsed = 0

	if self.version ~= self.lastSavedVersion then
		self:SaveToDB()
	end
end

--- @return true/false/nil (nil only if the deal was never actually
--         confirmed by a scan at all, which shouldn't normally happen).
function Deals:IsStale(deal)
	if not deal.seenAt then return true end
	return (time() - deal.seenAt) > STALE_SECONDS
end

--- Manual "Purge Stale" button: drops every currently-stale entry.
function Deals:PurgeStale()
	local removed = 0
	for i = #self.flagged, 1, -1 do
		local deal = self.flagged[i]
		if self:IsStale(deal) then
			table.remove(self.flagged, i)
			self.flaggedByFingerprint[deal.fingerprint] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		self.version = self.version + 1
	end
	return removed
end

--- Called from Scan:Finish() after a just-completed, unfiltered, full
-- sweep of the AH (never after a filtered, partial, or stopped-early
-- scan -- those don't see enough of the AH to safely conclude anything
-- is gone). Anything not re-confirmed (seenAt bumped) during that sweep
-- presumably sold, expired, or was moved, and is dropped.
function Deals:RemoveUnconfirmed(sinceTime)
	local removed = 0
	for i = #self.flagged, 1, -1 do
		local deal = self.flagged[i]
		if not deal.seenAt or deal.seenAt < sinceTime then
			table.remove(self.flagged, i)
			self.flaggedByFingerprint[deal.fingerprint] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		self.version = self.version + 1
	end
	return removed
end

--------------------------------------------------------------------------
-- Threshold / record building
--------------------------------------------------------------------------

--- Compute the per-item threshold at or below which a price (buyout or
-- bid) counts as a deal.
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

--- Clear the flagged-deal list entirely. NOT called automatically at the
-- start of every scan (that used to blank the list for the scan's whole
-- duration, which is exactly the "blank until I scan" experience this was
-- built to avoid) -- it's here for a manual full reset if ever needed.
-- In-place clearing (not `self.flagged = {}`), so a persisted-table
-- binding never gets orphaned.
function Deals:Reset()
	for i = #self.flagged, 1, -1 do
		table.remove(self.flagged, i)
	end
	for k in pairs(self.flaggedByFingerprint) do
		self.flaggedByFingerprint[k] = nil
	end
	self.version = self.version + 1
end

--- Shared by Evaluate() and FlagMaterialUndercut(): computes every display/
-- decision field for a row (market value, vendor-flip flags, fingerprint)
-- without deciding whether it qualifies as a deal or inserting it anywhere.
-- `row.buyoutPerItem`/`row.buyoutTotal` are nil for a bid-only auction
-- (no buyout set) -- every buyout-dependent field below tolerates that.
local function buildRecord(itemKey, row)
	local scopeKey = PriceDB:ScopeKey()
	local marketValue, confidence, vendorFloor = PriceDB:GetMarketValue(scopeKey, itemKey)

	local hasBuyout = row.buyoutPerItem ~= nil and row.buyoutPerItem > 0

	-- Vendor-price arbitrage is its own always-on check, independent of
	-- market history/confidence: a price below what a vendor pays is a
	-- guaranteed-profit flip the moment you buy it, no resale timing risk
	-- at all. Strictly less-than, not less-or-equal -- exactly equal to
	-- the vendor price is a real 0-copper-profit break-even, not an
	-- actual flip, and shouldn't be tagged as one.
	local isVendorFlip = hasBuyout and vendorFloor ~= nil and row.buyoutPerItem < vendorFloor

	-- row.minBid, as passed in from Scan.lua, is already "the price you'd
	-- actually need to bid right now to take the lead" (bidAmount +
	-- minIncrement once someone's bid, the original minBid otherwise) --
	-- not necessarily the auction's original starting bid.
	local minBidPerItem = (row.minBid and row.count and row.count > 0)
		and math.floor(row.minBid / row.count) or nil
	local isVendorFlipBid = vendorFloor ~= nil and minBidPerItem ~= nil and minBidPerItem < vendorFloor

	local discountPct = (hasBuyout and marketValue) and (1 - (row.buyoutPerItem / (marketValue * AH_CUT))) or nil
	local bidDiscountPct = (minBidPerItem and marketValue) and (1 - (minBidPerItem / (marketValue * AH_CUT))) or nil

	-- De-dupe within this scan: the same physical auction can be seen
	-- more than once (a retried duplicate page, or an item appearing on
	-- more than one page boundary during a getAll). Fingerprint on
	-- everything that would make two sightings "the same auction". A
	-- bid-only row has no buyout to key on, so minBid substitutes.
	local fingerprint = table.concat({
		itemKey, row.link, row.count, row.buyoutPerItem or ("bid" .. tostring(row.minBid)), row.owner or "?",
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
		minBid = row.minBid,
		minBidPerItem = minBidPerItem,
		owner = row.owner,
		marketValue = marketValue,
		confidence = confidence or "none",
		discountPct = discountPct,
		bidDiscountPct = bidDiscountPct,
		vendorFloor = vendorFloor,
		isVendorFlip = isVendorFlip,
		isVendorFlipBid = isVendorFlipBid,
		scanClassIndex = row.scanClassIndex,
		scanSubclassIndex = row.scanSubclassIndex,
	}
end

--- The per-item resale price to judge profit against, cheapest-to-most-
-- speculative: for a materials-undercut record, the same-scan peer
-- reference price is the whole basis that flagged it in the first place,
-- so it takes priority over a historical market value here -- an
-- unrelated, thin/stale marketValue (e.g. from a single old outlier day)
-- must never override the very comparison that made this look like a
-- deal. Otherwise, historical market value if there's any history, else
-- the peer reference price (e.g. a materials-undercut record that also
-- happens to have no separate marketValue at all).
local function resaleBasis(record)
	if record.isMaterialUndercut and record.peerReferencePrice then
		return record.peerReferencePrice * AH_CUT
	end
	if record.marketValue then
		return record.marketValue * AH_CUT
	end
	if record.peerReferencePrice then
		return record.peerReferencePrice * AH_CUT
	end
	return nil
end

--- Estimated copper profit for the whole stack if bought at its buyout
-- and resold at resaleBasis() above. Vendor flips are guaranteed instead
-- (vendor payout minus cost, no AH cut -- you don't pay the auction
-- house's cut selling to a vendor). Returns nil if no resale basis is
-- available at all.
local function estimateProfit(record)
	if not record.buyoutPerItem then return nil end
	if record.isVendorFlip then
		return (record.vendorFloor - record.buyoutPerItem) * record.count
	end

	local perItemResale = resaleBasis(record)
	if not perItemResale then return nil end
	return (perItemResale - record.buyoutPerItem) * record.count
end

--- Same as estimateProfit, but for winning the auction via bid instead of
-- buyout. This is inherently speculative even when guaranteed-profit-
-- looking (isVendorFlipBid): someone else can always outbid you before
-- the auction ends, so winning at all is never certain the way a buyout
-- is -- UI.lua labels this distinctly ("if won") rather than as a plain
-- profit figure.
local function estimateBidProfit(record)
	if not record.minBidPerItem then return nil end
	if record.isVendorFlipBid then
		return (record.vendorFloor - record.minBidPerItem) * record.count
	end

	local perItemResale = resaleBasis(record)
	if not perItemResale then return nil end
	return (perItemResale - record.minBidPerItem) * record.count
end

--- Evaluate one accepted auction row and, if either its buyout or its
-- current minimum bid qualifies as a deal, add/update it in the flagged
-- list. Called by Scan.lua for every row with a usable link+count,
-- buyout-having or bid-only alike -- reads only already-committed PriceDB
-- data, never the in-progress scan's own staged samples (see PriceDB.lua
-- header notes / the plan's self-referential-pricing fix).
function Deals:Evaluate(row)
	-- row = { itemID, suffixID, link, name, iconTexture, count,
	--         buyoutPerItem (nil if bid-only), buyoutTotal, owner, minBid }
	local itemKey = Util.ItemKey(row.itemID, row.suffixID)
	if not itemKey then return end

	local scopeKey = PriceDB:ScopeKey()
	local marketValue, confidence, vendorFloor = PriceDB:GetMarketValue(scopeKey, itemKey)
	local threshold = self:Threshold(marketValue, confidence, vendorFloor)
	if not threshold then return end

	local minBidPerItem = (row.minBid and row.count and row.count > 0)
		and math.floor(row.minBid / row.count) or nil
	local hasBuyout = row.buyoutPerItem ~= nil and row.buyoutPerItem > 0

	local buyoutQualifies = hasBuyout and row.buyoutPerItem <= threshold
	local bidQualifies = minBidPerItem ~= nil and minBidPerItem <= threshold
	if not buyoutQualifies and not bidQualifies then return end

	local record = buildRecord(itemKey, row)
	local potentialProfit = buyoutQualifies and estimateProfit(record) or nil
	local bidPotentialProfit = bidQualifies and estimateBidProfit(record) or nil

	-- Threshold() can qualify a row purely because the vendor floor
	-- pushed the cutoff up, without the resale math actually clearing a
	-- profit (e.g. the vendor price exceeds what the item currently
	-- fetches on the AH) -- never flag/show something we'd actually take
	-- a loss on just because some threshold technically passed.
	if buyoutQualifies and (not potentialProfit or potentialProfit <= 0) then
		buyoutQualifies, potentialProfit = false, nil
	end
	if bidQualifies and (not bidPotentialProfit or bidPotentialProfit <= 0) then
		bidQualifies, bidPotentialProfit = false, nil
	end

	local existing = self.flaggedByFingerprint[record.fingerprint]
	if not buyoutQualifies and not bidQualifies then
		-- No longer actually profitable either way -- if this was
		-- previously flagged (e.g. market value shifted since), drop it
		-- rather than leave a stale, no-longer-valid entry in the list.
		if existing then self:Remove(record.fingerprint) end
		return
	end

	if existing then
		-- Already flagged (from an earlier row this same scan, or
		-- restored from before a reload) -- refresh it in place rather
		-- than inserting a duplicate.
		existing.buyoutQualifies = buyoutQualifies
		existing.bidQualifies = bidQualifies
		existing.potentialProfit = potentialProfit
		existing.bidPotentialProfit = bidPotentialProfit
		existing.scanClassIndex = record.scanClassIndex
		existing.scanSubclassIndex = record.scanSubclassIndex
		existing.seenAt = time()
		self.version = self.version + 1
		return
	end

	record.buyoutQualifies = buyoutQualifies
	record.bidQualifies = bidQualifies
	record.potentialProfit = potentialProfit
	record.bidPotentialProfit = bidPotentialProfit
	record.seenAt = time()

	self.flaggedByFingerprint[record.fingerprint] = record
	table.insert(self.flagged, record)
	self.version = self.version + 1
end

--- Flags a row as a materials peer-price undercut: not compared against
-- historical market value at all, but against what OTHER sellers are
-- currently asking for the same item in this same scan (see
-- EvaluateMaterialUndercuts below). If the row already got flagged via the
-- normal historical-value path, this just adds the tag to the existing
-- record rather than inserting a second copy. Always buyout-based --
-- EvaluateMaterialUndercuts only ever compares buyout listings.
function Deals:FlagMaterialUndercut(row, peerReferencePrice, peerDiscountPct)
	local itemKey = Util.ItemKey(row.itemID, row.suffixID)
	if not itemKey then return end

	-- Build a scratch record first to check the actual resale math before
	-- touching anything -- the peer-comparison discount alone doesn't
	-- guarantee a real profit (e.g. an unrelated, thinner historical
	-- market value can still undercut it; see resaleBasis()'s priority
	-- fix, which should prevent this, but never trust it blindly).
	local candidate = buildRecord(itemKey, row)
	candidate.isMaterialUndercut = true
	candidate.peerReferencePrice = peerReferencePrice
	local profit = estimateProfit(candidate)
	if not profit or profit <= 0 then return end

	local existing = self.flaggedByFingerprint[candidate.fingerprint]
	local record = existing or candidate
	if not existing then
		self.flaggedByFingerprint[record.fingerprint] = record
		table.insert(self.flagged, record)
	end

	record.isMaterialUndercut = true
	record.peerReferencePrice = peerReferencePrice
	record.peerDiscountPct = peerDiscountPct
	record.buyoutQualifies = true
	record.potentialProfit = profit
	record.scanClassIndex = candidate.scanClassIndex
	record.scanSubclassIndex = candidate.scanSubclassIndex
	record.seenAt = time()
	self.version = self.version + 1
end

local function median(sorted)
	local n = #sorted
	if n == 0 then return nil end
	if n % 2 == 1 then return sorted[(n + 1) / 2] end
	return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

-- Same protection PriceDB.lua applies before committing market-value
-- history (see its stripHighOutliers): a single ask priced far above the
-- rest shouldn't be allowed to drag the reference price used below up
-- with it -- with only 2 "other" listings (the minimum this function ever
-- sees), a median is just their average, which one overpriced ask can
-- skew badly on its own.
local OUTLIER_MULTIPLIER = 4

local function stripHighOutliers(sorted)
	if #sorted < 3 then return sorted end
	local m = median(sorted)
	if not m or m <= 0 then return sorted end
	local kept = {}
	for _, p in ipairs(sorted) do
		if p <= m * OUTLIER_MULTIPLIER then table.insert(kept, p) end
	end
	if #kept == 0 then return sorted end
	return kept
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

			local reference = median(stripHighOutliers(rest))
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
			self.version = self.version + 1
			return
		end
	end
end

function Deals:GetFlagged()
	return self.flagged
end

return Deals
