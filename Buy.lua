-- Buy.lua
-- Two things live here:
--   1. Arbiter: the shared "who's allowed to trust the AH list buffer
--      right now" tracker, used by both Scan.lua and this module, since
--      the buffer is one global resource any addon's QueryAuctionItems
--      call can replace out from under us.
--   2. Buy: the locate -> arm -> bid state machine. PlaceAuctionBid must
--      run synchronously inside a real hardware-event click, so this is
--      necessarily two separate user actions (click a deal, then click
--      Confirm), not one automated flow.

local _, Auctionist = ...
local Util = Auctionist.Util
local Deals = Auctionist.Deals

--------------------------------------------------------------------------
-- Arbiter
--------------------------------------------------------------------------

local Arbiter = {
	queryToken = 0,
	lastOwner = nil,
	pendingOwner = nil,
	buyControl = false,
}
Auctionist.Arbiter = Arbiter

hooksecurefunc("QueryAuctionItems", function()
	Arbiter.queryToken = Arbiter.queryToken + 1
	Arbiter.lastOwner = Arbiter.pendingOwner or "foreign"
	Arbiter.pendingOwner = nil
end)

--- Call immediately before our own QueryAuctionItems so the hook above
-- can tell "our call" apart from a foreign one.
function Arbiter:BeforeQuery(owner)
	self.pendingOwner = owner
end

--- Buy takes exclusive control while it needs a guaranteed-fresh index;
-- Scan checks this flag at the top of every tick and does nothing at all
-- while it's set (not "finish the current page then pause").
function Arbiter:RequestControl(owner)
	self.buyControl = (owner == "buy")
end

function Arbiter:ReleaseControl()
	self.buyControl = false
end

--------------------------------------------------------------------------
-- Buy state machine
--------------------------------------------------------------------------

local Buy = {}
Auctionist.Buy = Buy

Buy.state = "IDLE"

local WAIT_TIMEOUT_LOCATE = 5
local MAX_LOCATE_RETRIES = 3
local BID_RESULT_TIMEOUT = 10
local RESULT_DISPLAY_SECONDS = 4
local PAGE_SIZE = 50

local DATABASE_ERROR_BACKOFF = { 2, 5 }

--------------------------------------------------------------------------
-- Known ERR_* outcomes. Built defensively: on 3.3.5 these are plain
-- string globals (not the LE_GAME_ERR_* numeric enum retail uses), but a
-- missing/renamed global must not crash addon load, and must never end up
-- as a nil table key (which is itself an error).
--------------------------------------------------------------------------

local FAILURE_ACTIONS = {}
local function addFailure(msg, action)
	if type(msg) == "string" and msg ~= "" then
		FAILURE_ACTIONS[msg] = action
	end
end
-- "definitive": the auction is gone/invalid, remove the flagged deal.
addFailure(ERR_ITEM_NOT_FOUND, "definitive")
addFailure(ERR_AUCTION_BID_OWN, "definitive")
-- "retry": transient server hiccup, says nothing about whether the
-- auction still exists -- re-run the locate phase with backoff.
addFailure(ERR_AUCTION_DATABASE_ERROR, "retry")
-- "surface": real problem, but not about the auction itself -- report it,
-- leave the deal flagged.
addFailure(ERR_NOT_ENOUGH_MONEY, "surface")
addFailure(ERR_ITEM_MAX_COUNT, "surface")
addFailure(ERR_AUCTION_HIGHER_BID, "surface")

-- Matches ERR_AUCTION_WON_S ("You won an auction for %s") against a
-- delivered CHAT_MSG_SYSTEM line. See Util.BuildFormatMatcher.
local wonMatcher = Util.BuildFormatMatcher(ERR_AUCTION_WON_S)

--------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------

--- Begin trying to buy or bid on a flagged deal (a table from
-- Deals.flagged). `mode` is "buyout" (default) or "bid" -- a bid is never
-- a guaranteed purchase (someone else can always outbid you before the
-- auction ends), unlike a buyout.
function Buy:Start(deal, mode)
	if self.state ~= "IDLE" and self.state ~= "DONE" and self.state ~= "FAILED" then
		return false, "already busy with another purchase"
	end

	mode = mode or "buyout"
	if mode == "buyout" and not deal.buyoutQualifies then
		return false, "no buyout deal available for this item"
	end
	if mode == "bid" and not deal.bidQualifies then
		return false, "no bid deal available for this item"
	end

	self.deal = deal
	self.mode = mode
	self.locateRetries = 0
	self.dbErrorRetries = 0
	self.page = 0

	Auctionist.Arbiter:RequestControl("buy")
	self.state = "LOCATING"
	return true
end

--------------------------------------------------------------------------
-- Driver: called every frame from Core.lua
--------------------------------------------------------------------------

function Buy:OnUpdate(elapsed)
	if self.state == "LOCATING" then
		self:DoLocating()
	elseif self.state == "WAIT_LOCATE" then
		self:DoWaitLocate(elapsed)
	elseif self.state == "BID_SENT" then
		self:DoWaitBidResult(elapsed)
	elseif self.state == "DONE" or self.state == "FAILED" then
		self:DoShowResult(elapsed)
	end
end

function Buy:DoLocating()
	local canQuery = CanSendAuctionQuery()
	if not canQuery then return end

	Auctionist.Arbiter:BeforeQuery("buy")
	QueryAuctionItems(self.deal.name, "", "", nil, nil, nil, self.page, nil, nil)

	self.myToken = Auctionist.Arbiter.queryToken
	self.waitElapsed = 0
	self.state = "WAIT_LOCATE"
end

function Buy:DoWaitLocate(elapsed)
	self.waitElapsed = self.waitElapsed + elapsed
	if self.waitElapsed >= WAIT_TIMEOUT_LOCATE then
		self:RetryLocate("timed out waiting for search results")
	end
end

function Buy:RetryLocate(reason)
	self.locateRetries = self.locateRetries + 1
	if self.locateRetries > MAX_LOCATE_RETRIES then
		self:Fail(reason, false)
		return
	end
	self.state = "LOCATING"
end

--- Called from Core's AUCTION_ITEM_LIST_UPDATE handler.
function Buy:OnAuctionUpdate()
	if self.state ~= "WAIT_LOCATE" then return end
	if Auctionist.Arbiter.queryToken ~= self.myToken then
		self:RetryLocate("a different addon queried the auction house")
		return
	end

	local numBatch, total = GetNumAuctionItems("list")
	local playerName = UnitName("player")

	for i = 1, numBatch do
		local name, texture, count, _, _, _, minBid, minIncrement, buyoutPrice, bidAmount, _, owner =
			GetAuctionItemInfo("list", i)
		local link = GetAuctionItemLink("list", i)

		if link and buyoutPrice and count then
			local itemID, _, suffixID = Util.ParseItemLink(link)
			local key = itemID and Util.ItemKey(itemID, suffixID)

			local nextBid = (bidAmount and bidAmount > 0) and (bidAmount + (minIncrement or 0)) or minBid

			local matches = key == self.deal.itemKey and count == self.deal.count and owner ~= playerName
			if matches then
				if self.mode == "buyout" then
					matches = buyoutPrice == self.deal.buyoutTotal
				else
					matches = nextBid == self.deal.minBid
				end
			end

			if matches then
				self.armedIndex = i
				self.armedLink = link
				self.armedCount = count
				self.armedBuyout = buyoutPrice
				self.armedMinBid = nextBid
				self.state = "ARMED"
				return
			end
		end
	end

	local exhausted = (numBatch < PAGE_SIZE) or (total == 0) or ((self.page + 1) * PAGE_SIZE >= total)
	if exhausted then
		self:NotFound()
	else
		self.page = self.page + 1
		self.state = "LOCATING"
	end
end

function Buy:NotFound()
	Deals:Remove(self.deal.fingerprint)
	Auctionist.Arbiter:ReleaseControl()
	self.resultText = "That auction is no longer available."
	self.resultOk = false
	self.state = "FAILED"
	self.resultTime = time()
end

--------------------------------------------------------------------------
-- Confirm: MUST be called directly from a button's OnClick handler
-- (UI.lua), never from a timer/event -- PlaceAuctionBid requires a real
-- hardware event.
--------------------------------------------------------------------------

function Buy:Confirm()
	if self.state ~= "ARMED" then return false, "nothing armed" end

	local name, _, count, _, _, _, minBid, minIncrement, buyoutPrice, bidAmount = GetAuctionItemInfo("list", self.armedIndex)
	local link = GetAuctionItemLink("list", self.armedIndex)
	local nextBid = (bidAmount and bidAmount > 0) and (bidAmount + (minIncrement or 0)) or minBid

	if not link or link ~= self.armedLink or count ~= self.armedCount
		or buyoutPrice ~= self.armedBuyout or nextBid ~= self.armedMinBid then
		-- The listing changed between arming and this click (someone else
		-- bid, bought it, etc.) -- don't guess, go re-find it fresh.
		self.state = "LOCATING"
		return false, "listing changed, re-locating"
	end

	local amount = (self.mode == "bid") and nextBid or buyoutPrice
	if not amount or amount <= 0 then
		self.state = "LOCATING"
		return false, "listing changed, re-locating"
	end

	if GetMoney() < amount then
		return false, "not enough money"
	end

	PlaceAuctionBid("list", self.armedIndex, amount)
	self.state = "BID_SENT"
	self.bidWaitElapsed = 0
	return true
end

function Buy:DoWaitBidResult(elapsed)
	self.bidWaitElapsed = self.bidWaitElapsed + elapsed
	if self.bidWaitElapsed >= BID_RESULT_TIMEOUT then
		self.resultText = "Unknown result - check your inventory/mailbox."
		self.resultOk = nil -- neither confirmed success nor confirmed failure
		Auctionist.Arbiter:ReleaseControl()
		self.state = "FAILED"
		self.resultTime = time()
	end
end

function Buy:DoShowResult(elapsed)
	if self.resultTime and (time() - self.resultTime) >= RESULT_DISPLAY_SECONDS then
		self.state = "IDLE"
		self.deal = nil
	end
end

--------------------------------------------------------------------------
-- Event hooks: called from Core.lua only while state == "BID_SENT".
--------------------------------------------------------------------------

function Buy:OnChatMessage(msg)
	if self.state ~= "BID_SENT" then return end
	if wonMatcher and wonMatcher(msg) then
		-- An actual win message -- always means the item is yours now,
		-- for both a buyout (instant) and, much more rarely, a real bid
		-- that happened to be the only/final one.
		self:Success()
	elseif msg == ERR_AUCTION_BID_PLACED then
		if self.mode == "buyout" then
			-- A buyout is placed as a bid mechanically, so this message
			-- alone already means "bought" for buyout mode (the win
			-- message above may or may not also fire).
			self:Success()
		else
			-- A real bid was accepted, but that's not a purchase -- you
			-- don't own the item yet, and might get outbid before the
			-- auction ends.
			self:BidPlaced()
		end
	end
end

function Buy:OnUIErrorMessage(msg)
	if self.state ~= "BID_SENT" then return end
	local action = FAILURE_ACTIONS[msg]
	if not action then return end

	if action == "definitive" then
		self:Fail(msg, true)
	elseif action == "retry" then
		self.dbErrorRetries = (self.dbErrorRetries or 0) + 1
		if self.dbErrorRetries > #DATABASE_ERROR_BACKOFF then
			self:Fail(msg, false)
		else
			-- Re-arm via the locate phase again; a fresh index is needed
			-- regardless, and this naturally spaces out retries because
			-- locating itself takes a beat.
			self.state = "LOCATING"
			self.locateRetries = 0
		end
	else -- "surface"
		self:Fail(msg, false)
	end
end

function Buy:Success()
	-- Usually the deal's own buyoutTotal, but a bid can occasionally win
	-- outright too (see OnChatMessage) -- if so, what was actually paid
	-- is whatever bid was armed, not the (possibly nil, for a bid-only
	-- deal) buyout figure.
	local paid = (self.mode == "bid") and self.armedMinBid or self.deal.buyoutTotal

	Deals:Remove(self.deal.fingerprint)
	if Auctionist.Ledger then
		Auctionist.Ledger:RecordPurchase(Auctionist.PriceDB:ScopeKey(), self.deal, paid)
	end
	Auctionist.Arbiter:ReleaseControl()
	self.resultText = "Bought " .. tostring(self.deal.name) .. " for " .. Util.FormatMoney(paid)
	self.resultOk = true
	self.state = "DONE"
	self.resultTime = time()
end

--- A real (non-buyout) bid was successfully registered -- NOT a purchase.
-- You don't own the item yet, and might get outbid before the auction
-- ends (WoW automatically refunds an outbid bid). No Ledger entry, since
-- nothing is guaranteed won yet; the deal is still removed from the
-- flagged list since it's already been acted on, just not resolved.
function Buy:BidPlaced()
	Deals:Remove(self.deal.fingerprint)
	Auctionist.Arbiter:ReleaseControl()
	self.resultText = "Bid placed on " .. tostring(self.deal.name) .. " for " ..
		Util.FormatMoney(self.armedMinBid) .. ". You'll be notified if you win."
	self.resultOk = true
	self.state = "DONE"
	self.resultTime = time()
end

--- @param removeDeal true if this failure is definitive (the listing is
--        gone/invalid) and the flagged deal should stop showing.
function Buy:Fail(msg, removeDeal)
	if removeDeal and self.deal then
		Deals:Remove(self.deal.fingerprint)
	end
	Auctionist.Arbiter:ReleaseControl()
	self.resultText = msg or "Purchase failed."
	self.resultOk = false
	self.state = "FAILED"
	self.resultTime = time()
end

--- Called from Core on AUCTION_HOUSE_CLOSED. A bid already in flight
-- (BID_SENT) is left alone -- the chat/error events that resolve it don't
-- depend on the AH frame being open. Only the phases that depend on the
-- list buffer are abandoned.
function Buy:OnAuctionHouseClosed()
	if self.state == "LOCATING" or self.state == "WAIT_LOCATE" or self.state == "ARMED" then
		Auctionist.Arbiter:ReleaseControl()
		self.state = "IDLE"
		self.deal = nil
	end
end

return Buy
