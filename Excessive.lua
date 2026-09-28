-- Excessive.lua
-- Flags auction listings priced far above an item's known market value --
-- the mirror image of Deals.lua's underpriced-deal detection. Surfaces
-- listings that are almost certainly just one seller's outrageous ask
-- rather than a real price move, reusing the same 4x-multiplier convention
-- already established elsewhere in this addon for exactly that judgment
-- call (PriceDB:Commit's stripHighOutliers, Deals.lua's own
-- stripHighOutliers), rather than inventing a second definition of
-- "outrageous". Session-only: not persisted to SavedVariables and not
-- linked to Deals.flagged at all -- a fresh scan simply rebuilds this list
-- from what it currently sees, the same "don't wipe until re-scanned"
-- pattern Deals.lua uses (see RemoveUnconfirmed).

local _, Auctionist = ...
local Util = Auctionist.Util
local PriceDB = Auctionist.PriceDB

local Excessive = {}
Auctionist.Excessive = Excessive

local EXCESSIVE_MULTIPLIER = 4

Excessive.flagged = {}              -- ordered array of flagged records
Excessive.flaggedByFingerprint = {} -- fingerprint -> record, for this scan's de-dup
Excessive.version = 0               -- bumped on every mutation; UI redraws when this moves

--- Evaluate one accepted auction row (same shape Scan.lua builds for
-- Deals:Evaluate) and flag/refresh/drop it depending on whether its buyout
-- is priced far above the item's known market value. Needs real price
-- history (confidence ~= "none") -- with no history at all there's nothing
-- to call "inflated" relative to, so bid-only rows and unpriced items are
-- silently skipped, same as Deals.lua does for its own no-history case.
function Excessive:Evaluate(row)
	if not row.buyoutPerItem or row.buyoutPerItem <= 0 then return end

	local itemKey = Util.ItemKey(row.itemID, row.suffixID)
	if not itemKey then return end

	local scopeKey = PriceDB:ScopeKey()
	local marketValue, confidence = PriceDB:GetMarketValue(scopeKey, itemKey)

	local fingerprint = table.concat({
		itemKey, row.link, row.count, row.buyoutPerItem, row.owner or "?",
	}, "|")

	if not marketValue or confidence == "none" or row.buyoutPerItem < marketValue * EXCESSIVE_MULTIPLIER then
		-- No history to judge against, or no longer (or never was)
		-- excessive -- drop a stale entry if one exists rather than leave
		-- it shown after the price corrected or history arrived.
		local existing = self.flaggedByFingerprint[fingerprint]
		if existing then self:Remove(fingerprint) end
		return
	end

	local existing = self.flaggedByFingerprint[fingerprint]
	local record = existing or {
		fingerprint = fingerprint,
		itemKey = itemKey,
		itemID = row.itemID,
		suffixID = row.suffixID,
		link = row.link,
		name = row.name,
		iconTexture = row.iconTexture,
		count = row.count,
		owner = row.owner,
	}

	record.buyoutPerItem = row.buyoutPerItem
	record.buyoutTotal = row.buyoutTotal
	record.marketValue = marketValue
	record.multiple = row.buyoutPerItem / marketValue
	record.seenAt = time()

	if not existing then
		self.flaggedByFingerprint[fingerprint] = record
		table.insert(self.flagged, record)
	end
	self.version = self.version + 1
end

--- Mirrors Deals:RemoveUnconfirmed -- only safe to call after a just-
-- completed, unfiltered, full sweep of the AH (see Scan:Finish()), since a
-- filtered scan only ever looked at a subset and can't safely conclude
-- anything outside it is gone.
function Excessive:RemoveUnconfirmed(sinceTime)
	local removed = 0
	for i = #self.flagged, 1, -1 do
		local record = self.flagged[i]
		if not record.seenAt or record.seenAt < sinceTime then
			table.remove(self.flagged, i)
			self.flaggedByFingerprint[record.fingerprint] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		self.version = self.version + 1
	end
	return removed
end

function Excessive:Remove(fingerprint)
	for i, record in ipairs(self.flagged) do
		if record.fingerprint == fingerprint then
			table.remove(self.flagged, i)
			self.flaggedByFingerprint[fingerprint] = nil
			self.version = self.version + 1
			return
		end
	end
end

function Excessive:GetFlagged()
	return self.flagged
end

return Excessive
