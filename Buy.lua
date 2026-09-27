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

--- Build a Lua pattern that matches a "%s"-format success string like
-- ERR_AUCTION_WON_S ("You won an auction for %s") against a delivered
-- CHAT_MSG_SYSTEM line. Escapes pattern-magic characters in the literal
-- portions and turns the literal two-character "%s" into a ".*" capture.
local function buildFormatPattern(fmt)
	local function esc(s)
		return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
	end
	local prefix, suffix = fmt:match("^(.-)%%s(.*)$")
	if not prefix then
		return "^" .. esc(fmt) .. "$"
	end
	return "^" .. esc(prefix) .. ".*" .. esc(suffix) .. "$"
end

local wonPattern
if type(ERR_AUCTION_WON_S) == "string" then
	local ok, patt = pcall(buildFormatPattern, ERR_AUCTION_WON_S)
	if ok then wonPattern = patt end
end

--------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------

--- Begin trying to buy a flagged deal (a table from Deals.flagged).
function Buy:Start(deal)
	if self.state ~= "IDLE" and self.state ~= "DONE" and self.state ~= "FAILED" then
		return false, "already busy with another purchase"
	end

	self.deal = deal
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
		local name, texture, count, _, _, _, _, _, buyoutPrice, _, _, owner = GetAuctionItemInfo("list", i)
		local link = GetAuctionItemLink("list", i)

		if link and buyoutPrice and count then
			local itemID, _, suffixID = Util.ParseItemLink(link)
			local key = itemID and Util.ItemKey(itemID, suffixID)

			if key == self.deal.itemKey and count == self.deal.count
				and buyoutPrice == self.deal.buyoutTotal and owner ~= playerName then
				self.armedIndex = i
				self.armedLink = link
				self.armedCount = count
				self.armedBuyout = buyoutPrice
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

	local name, _, count, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", self.armedIndex)
	local link = GetAuctionItemLink("list", self.armedIndex)

	if not link or link ~= self.armedLink or count ~= self.armedCount or buyoutPrice ~= self.armedBuyout then
		-- The listing changed between arming and this click; don't guess,
		-- go re-find it fresh.
		self.state = "LOCATING"
		return false, "listing changed, re-locating"
	end

	if GetMoney() < buyoutPrice then
		return false, "not enough money"
	end

	PlaceAuctionBid("list", self.armedIndex, buyoutPrice)
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
	if msg == ERR_AUCTION_BID_PLACED or (wonPattern and string.find(msg, wonPattern)) then
		self:Success()
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
	Deals:Remove(self.deal.fingerprint)
	Auctionist.Arbiter:ReleaseControl()
	self.resultText = "Bought " .. tostring(self.deal.name) .. " for " .. Util.FormatMoney(self.deal.buyoutTotal)
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
