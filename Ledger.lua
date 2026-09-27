-- Ledger.lua
-- Tracks purchases made through Buy.lua as a profit/loss ledger, and
-- auto-detects "auction sold" mail to close out entries with the actual
-- sale price -- no manual sale-price entry.
--
-- NOTE: unlike the ERR_* globals in Buy.lua (which the reference addons
-- in learning material actually reference), AUCTION_SOLD_MAIL_SUBJECT has
-- NOT been directly confirmed against this project's reference material
-- this session. It's a long-standing Blizzard global string, but verify
-- it in-game before trusting this feature fully:
--   /run print(AUCTION_SOLD_MAIL_SUBJECT)
-- should print something like "Auction successful: %s", not nil. If it IS
-- nil/renamed on this client, BuildFormatMatcher returns nil and this
-- whole feature goes quietly inert (ledger entries still get created on
-- purchase, they just never auto-close) rather than erroring.

local _, Auctionist = ...
local Util = Auctionist.Util

local Ledger = {}
Auctionist.Ledger = Ledger

local soldMatcher = Util.BuildFormatMatcher(AUCTION_SOLD_MAIL_SUBJECT)

--------------------------------------------------------------------------
-- Schema
--------------------------------------------------------------------------

function Ledger:Init()
	AuctionistDB.ledger = AuctionistDB.ledger or {}
	self.db = AuctionistDB.ledger
end

function Ledger:ScopeData(scopeKey, create)
	local data = self.db[scopeKey]
	if not data and create then
		data = { nextId = 1, entries = {} }
		self.db[scopeKey] = data
	end
	return data
end

--------------------------------------------------------------------------
-- Purchases
--------------------------------------------------------------------------

--- Called from Buy:Success() with the deal that was just bought.
function Ledger:RecordPurchase(scopeKey, deal)
	local data = self:ScopeData(scopeKey, true)
	local entry = {
		id = data.nextId,
		itemKey = deal.itemKey, itemID = deal.itemID, suffixID = deal.suffixID,
		name = deal.name, iconTexture = deal.iconTexture, count = deal.count,
		cost = deal.buyoutTotal, boughtAt = time(),
		status = "unsold", saleAmount = nil, soldAt = nil,
	}
	data.nextId = data.nextId + 1
	table.insert(data.entries, entry)
	return entry
end

function Ledger:GetEntries(scopeKey)
	local data = self:ScopeData(scopeKey, false)
	return data and data.entries or {}
end

--- @return { totalSpent, totalRevenue, totalProfit, soldCount, unsoldCount,
--            unsoldCost } (all money values in copper)
function Ledger:Summary(scopeKey)
	local s = { totalSpent = 0, totalRevenue = 0, totalProfit = 0,
		soldCount = 0, unsoldCount = 0, unsoldCost = 0 }

	for _, entry in ipairs(self:GetEntries(scopeKey)) do
		s.totalSpent = s.totalSpent + entry.cost
		if entry.status == "sold" then
			s.totalRevenue = s.totalRevenue + entry.saleAmount
			s.soldCount = s.soldCount + 1
		else
			s.unsoldCount = s.unsoldCount + 1
			s.unsoldCost = s.unsoldCost + entry.cost
		end
	end

	-- Profit only counts cost basis for items that have actually sold;
	-- unsold inventory's cost is tracked separately (unsoldCost) rather
	-- than counted as a loss.
	s.totalProfit = s.totalRevenue - (s.totalSpent - s.unsoldCost)
	return s
end

--------------------------------------------------------------------------
-- Mailbox auto-detect
--------------------------------------------------------------------------

--- Oldest unsold entry for `name`. FIFO: the earliest purchase of a given
-- item is assumed to be the one that sold first.
local function findOldestUnsold(entries, name)
	for _, entry in ipairs(entries) do
		if entry.status == "unsold" and entry.name == name then
			return entry
		end
	end
	return nil
end

--- Scans the currently-open mailbox for one auction-sold letter that can
-- be confidently attributed to a tracked unsold purchase, collects its
-- money via AutoLootMailItem, and closes out that ledger entry.
--
-- Processes at most ONE match per call: collecting mail can shift or
-- remove inbox indexes, so rather than keep going against now-possibly-
-- stale indexes, this relies on the MAIL_INBOX_UPDATE that collecting
-- triggers (or Ledger:OnUpdate's periodic re-scan while the mailbox is
-- open) to pick up the next one with fresh indexes.
--
-- A sold-mail whose item name doesn't match any unsold ledger entry is
-- left completely untouched (not collected, not marked processed) --
-- it's not something Auctionist tracked, and the player can collect it
-- normally. This also means the same still-uncollected mail is
-- deliberately re-examined on every scan; the risk that's usually solved
-- with a "seen this mail" fingerprint is avoided here differently -- once
-- an entry is matched, it's collected immediately, so a mail that funded
-- a sale can never be seen with money > 0 again and re-match a different,
-- newer entry.
--- @param verbose if true, prints why nothing happened when nothing did --
--        used by the manual "Rescan Sold Mail" button so clicking it is
--        never silently a no-op. The automatic call sites (OnMailShow,
--        the periodic OnUpdate rescan, MAIL_INBOX_UPDATE) pass nothing,
--        since those fire many times a minute and would otherwise spam
--        chat with "found nothing" on every ordinary tick.
function Ledger:ScanMailbox(verbose)
	if not soldMatcher then
		if verbose then
			print("Auctionist: mailbox auto-detect is inert on this client -- " ..
				"AUCTION_SOLD_MAIL_SUBJECT is nil. Run /run print(AUCTION_SOLD_MAIL_SUBJECT) " ..
				"and let me know what it prints.")
		end
		return
	end

	local scopeKey = Auctionist.PriceDB:ScopeKey()
	local data = self:ScopeData(scopeKey, false)
	if not data then
		if verbose then
			print("Auctionist: no tracked purchases yet -- nothing for the mailbox scan to match.")
		end
		return
	end

	local numItems = GetInboxNumItems()
	for index = 1, numItems do
		local _, _, _, subject, money = GetInboxHeaderInfo(index)
		if money and money > 0 then
			local matched, itemName = soldMatcher(subject or "")
			if matched and itemName and itemName ~= "" then
				local entry = findOldestUnsold(data.entries, itemName)
				if entry then
					entry.status = "sold"
					entry.saleAmount = money
					entry.soldAt = time()
					AutoLootMailItem(index)
					print(string.format("Auctionist: %s sold for %s, ledger entry closed.",
						itemName, Util.FormatMoney(money)))
					return
				end
			end
		end
	end

	if verbose then
		print("Auctionist: mailbox scan found no sold-auction mail matching a tracked unsold purchase.")
	end
end

--------------------------------------------------------------------------
-- Driver: called from Core.lua
--------------------------------------------------------------------------

local RESCAN_INTERVAL = 1.0

function Ledger:OnMailShow()
	self.mailboxOpen = true
	self.rescanElapsed = 0
	self:ScanMailbox()
end

function Ledger:OnMailClosed()
	self.mailboxOpen = false
end

--- A periodic safety net alongside the MAIL_INBOX_UPDATE-driven scan, in
-- case collecting mail doesn't reliably re-fire that event on every
-- client/server combination.
function Ledger:OnUpdate(elapsed)
	if not self.mailboxOpen then return end
	self.rescanElapsed = (self.rescanElapsed or 0) + elapsed
	if self.rescanElapsed < RESCAN_INTERVAL then return end
	self.rescanElapsed = 0
	self:ScanMailbox()
end

return Ledger
