-- Scan.lua
-- Paged-search and getAll scan state machines. Both share the same
-- pipeline: send a query (gated on CanSendAuctionQuery), wait for
-- AUCTION_ITEM_LIST_UPDATE, collect the page's rows in budgeted chunks
-- (never all at once -- this is the fix for Auctionator's client-freezing
-- full-scan loop), detect a stale/duplicate page BEFORE trusting its data,
-- and only then stage samples + evaluate deals for the accepted rows.
--
-- Driven entirely from Core.lua's OnUpdate frame and its
-- AUCTION_ITEM_LIST_UPDATE handler; Scan itself never registers events.

local _, Auctionist = ...
local Util = Auctionist.Util
local PriceDB = Auctionist.PriceDB
local Deals = Auctionist.Deals
local Excessive = Auctionist.Excessive

local Scan = {}
Auctionist.Scan = Scan

local PAGE_SIZE = 50

local WAIT_TIMEOUT_PAGED = 10
local WAIT_TIMEOUT_GETALL = 30
local MAX_QUERY_RETRIES = 8

local MAX_ROW_RETRY_TICKS = 5
local MAX_DUP_PAGE_RETRIES = 10

local ROW_BUDGET_PAGED = 50
local ROW_BUDGET_GETALL = 300

Scan.state = "IDLE"
Scan.stats = {}

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

local function fingerprintRow(name, count, minBid, buyoutPrice, bidAmount)
	return table.concat({
		tostring(name), tostring(count), tostring(minBid),
		tostring(buyoutPrice), tostring(bidAmount),
	}, "_")
end

local function fingerprintsEqual(a, b)
	if not a or not b or #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function allIdentical(fingerprints)
	if #fingerprints == 0 then return false end
	local first = fingerprints[1]
	for i = 2, #fingerprints do
		if fingerprints[i] ~= first then return false end
	end
	return true
end

--------------------------------------------------------------------------
-- Entry points
--------------------------------------------------------------------------

--- Begin a paged search scan. `filters` is optional; an empty/omitted
-- table sweeps the whole AH page by page (no name/class/level filter).
function Scan:StartPaged(filters)
	if self.state ~= "IDLE" and self.state ~= "FAILED" then return false, "scan already in progress" end

	self.mode = "paged"
	self.filters = filters or {}
	self:ResetRun()
	self.state = "STARTING"
	return true
end

--- Begin a getAll scan. Availability (CanSendAuctionQuery's second
-- return) is checked continuously while waiting to send; there is no
-- timeout on that wait, since Blizzard's ~15-minute server-side cadence
-- is a legitimate long wait, not a stall.
function Scan:StartGetAll()
	if self.state ~= "IDLE" and self.state ~= "FAILED" then return false, "scan already in progress" end

	self.mode = "getall"
	self.filters = {}
	self:ResetRun()
	self.state = "STARTING"
	return true
end

function Scan:ResetRun()
	self.page = 0
	self.dayKey = Util.TodayKey()
	self.scopeKey = PriceDB:ScopeKey()
	self.startedAt = time()
	self.staged = {}
	self.prevPageFingerprints = nil
	self.dupPageRetries = 0
	self.queryRetries = 0
	self.waitElapsed = 0
	self.stats = { rowsAccepted = 0, rowsSkipped = 0, pagesProcessed = 0, itemsStaged = 0 }
end

--- Commit whatever's been staged so far, if anything. Shared by a normal
-- finish, a user-requested Stop, and every failure path -- a timeout or
-- too-many-duplicate-pages error deep into a long sweep must not throw
-- away the (possibly thousands of items') worth of data already gathered.
function Scan:CommitStaged()
	if not self.staged or not next(self.staged) then return end
	local scopeKey = self.scopeKey or PriceDB:ScopeKey()
	Deals:EvaluateMaterialUndercuts(self.staged, scopeKey)
	PriceDB:Commit(scopeKey, self.staged, self.dayKey)
	PriceDB:Prune(scopeKey)
end

--- Reset to IDLE. Used when the AH frame closes. Commits whatever's
-- staged so far first -- there's no reason to discard already-gathered
-- pricing data just because the window closed mid-scan.
function Scan:Cancel()
	if self.state ~= "IDLE" and self.state ~= "FAILED" then
		self:CommitStaged()
	end
	self.state = "IDLE"
	self.pageRows = nil
end

--- User-requested "Stop Scan". Same as Cancel, but only valid while a
-- scan is actually running, and reported back to the caller so the UI
-- can show/hide the button correctly.
function Scan:Stop()
	if self.state == "IDLE" or self.state == "FAILED" then
		return false, "no scan is running"
	end
	self:CommitStaged()
	self.stats.lastScanTime = time()
	self.stats.lastScanMode = self.mode
	self.stats.stoppedEarly = true
	self.state = "IDLE"
	self.pageRows = nil
	return true
end

--------------------------------------------------------------------------
-- Driver: called every frame from Core.lua
--------------------------------------------------------------------------

function Scan:OnUpdate(elapsed)
	if self.state == "IDLE" or self.state == "FAILED" then return end
	if Auctionist.Arbiter.buyControl then return end -- Buy holds exclusive control of the list buffer

	if self.state == "STARTING" then
		self:DoStarting()
	elseif self.state == "QUERY_PENDING" then
		self:DoQueryPending()
	elseif self.state == "WAIT_RESULT" then
		self:DoWaitResult(elapsed)
	elseif self.state == "COLLECT_PAGE" then
		self:DoCollectPage()
	elseif self.state == "STAGE_PAGE" then
		self:DoStagePage()
	end
end

function Scan:DoStarting()
	SortAuctionClearSort("list")
	self.state = "QUERY_PENDING"
end

function Scan:DoQueryPending()
	local canQuery, canGetAll = CanSendAuctionQuery()
	if not canQuery then return end
	if self.mode == "getall" and not canGetAll then return end

	Auctionist.Arbiter:BeforeQuery("scan")

	if self.mode == "getall" then
		QueryAuctionItems("", nil, nil, 0, 0, 0, 0, 0, 0, true)
	else
		local f = self.filters
		QueryAuctionItems(f.name or "", f.minLevel, f.maxLevel, f.invTypeIndex,
			f.classIndex, f.subclassIndex, self.page, f.isUsable, f.minQuality)
	end

	self.myToken = Auctionist.Arbiter.queryToken
	self.waitElapsed = 0
	self.state = "WAIT_RESULT"
end

function Scan:DoWaitResult(elapsed)
	self.waitElapsed = self.waitElapsed + elapsed
	local timeout = (self.mode == "getall") and WAIT_TIMEOUT_GETALL or WAIT_TIMEOUT_PAGED
	if self.waitElapsed >= timeout then
		self:RetryQuery("timed out waiting for auction results")
	end
end

--- Called from Core's AUCTION_ITEM_LIST_UPDATE handler.
function Scan:OnAuctionUpdate()
	if self.state ~= "WAIT_RESULT" then return end
	-- While Buy holds exclusive control we're fully paused (see OnUpdate);
	-- ignore this update rather than burning a retry on it. Scan resumes
	-- from QUERY_PENDING (re-sending this same page) once Buy releases
	-- control, since Buy's own queries invalidated our in-flight result
	-- anyway.
	if Auctionist.Arbiter.buyControl then
		self.state = "QUERY_PENDING"
		return
	end
	if Auctionist.Arbiter.queryToken ~= self.myToken then
		-- A foreign QueryAuctionItems call landed and replaced the list
		-- buffer before ours resolved; our token is stale.
		self:RetryQuery("a different addon queried the auction house")
		return
	end

	self.numBatchAuctions, self.totalAuctions = GetNumAuctionItems("list")
	self.pageRows = {}
	self.pendingIndexes = {}
	self.rowRetryTicks = {}
	for i = 1, self.numBatchAuctions do
		self.pendingIndexes[i] = i
	end
	self.state = "COLLECT_PAGE"
end

function Scan:RetryQuery(reason)
	self.queryRetries = self.queryRetries + 1
	if self.queryRetries > MAX_QUERY_RETRIES then
		self:CommitStaged()
		self.state = "FAILED"
		self.failureReason = reason
		return
	end
	self.state = "QUERY_PENDING"
end

--------------------------------------------------------------------------
-- Collect: read every row on the page, chunked. Nothing is staged into
-- PriceDB or evaluated as a deal yet -- we don't know until every row has
-- been read whether this page is a stale duplicate of the last one.
--------------------------------------------------------------------------

function Scan:DoCollectPage()
	if Auctionist.Arbiter.queryToken ~= self.myToken then
		self:RetryQuery("a different addon queried the auction house")
		return
	end

	local budget = (self.mode == "getall") and ROW_BUDGET_GETALL or ROW_BUDGET_PAGED
	local stillPending = {}

	for n = 1, math.min(budget, #self.pendingIndexes) do
		local i = self.pendingIndexes[n]
		local name, texture, count, quality, _, _, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner =
			GetAuctionItemInfo("list", i)
		local link = GetAuctionItemLink("list", i)

		local complete = (link ~= nil) and (buyoutPrice ~= nil) and (count ~= nil)

		if complete then
			self.pageRows[i] = {
				link = link, name = name, iconTexture = texture, count = count,
				quality = quality, minBid = minBid, minIncrement = minIncrement,
				buyoutPrice = buyoutPrice, bidAmount = bidAmount, highBidder = highBidder,
				owner = owner,
				fingerprint = fingerprintRow(name, count, minBid, buyoutPrice, bidAmount),
			}
		else
			local tries = (self.rowRetryTicks[i] or 0) + 1
			self.rowRetryTicks[i] = tries
			if tries < MAX_ROW_RETRY_TICKS then
				table.insert(stillPending, i)
			else
				-- Gave up on this index for this page; record whatever
				-- fingerprint we can so duplicate-page comparison still
				-- has a stable value to compare against.
				self.stats.rowsSkipped = self.stats.rowsSkipped + 1
				self.pageRows[i] = {
					fingerprint = fingerprintRow(name, count, minBid, buyoutPrice, bidAmount),
				}
			end
		end
	end

	-- Whatever we didn't get to this tick (beyond the budget) stays
	-- pending too.
	for n = math.min(budget, #self.pendingIndexes) + 1, #self.pendingIndexes do
		table.insert(stillPending, self.pendingIndexes[n])
	end
	self.pendingIndexes = stillPending

	if #self.pendingIndexes > 0 then return end

	-- Page fully read. Decide duplicate-vs-fresh before touching PriceDB.
	local currentFingerprints = {}
	for i = 1, self.numBatchAuctions do
		currentFingerprints[i] = self.pageRows[i] and self.pageRows[i].fingerprint or ""
	end

	local isDuplicate = fingerprintsEqual(currentFingerprints, self.prevPageFingerprints)
		and not allIdentical(currentFingerprints)

	if isDuplicate then
		self.dupPageRetries = self.dupPageRetries + 1
		if self.dupPageRetries > MAX_DUP_PAGE_RETRIES then
			self:CommitStaged()
			self.state = "FAILED"
			self.failureReason = "too many duplicate pages from the server"
			return
		end
		self.pageRows = nil
		self.state = "QUERY_PENDING" -- re-send the SAME page
		return
	end

	self.prevPageFingerprints = currentFingerprints
	self.dupPageRetries = 0
	self.stageCursor = 1
	self.state = "STAGE_PAGE"
end

--------------------------------------------------------------------------
-- Stage: apply already-collected rows to the in-memory staging table and
-- to Deals:Evaluate. No more API calls happen here, but it's still
-- chunked across ticks for very large getAll pages.
--------------------------------------------------------------------------

function Scan:DoStagePage()
	local budget = (self.mode == "getall") and ROW_BUDGET_GETALL or ROW_BUDGET_PAGED
	local last = math.min(self.stageCursor + budget - 1, self.numBatchAuctions)

	for i = self.stageCursor, last do
		local row = self.pageRows[i]
		-- highBidder means the player is already the top bidder on this
		-- listing -- nothing useful to flag or re-bid on there.
		if row and row.link and row.count and not row.highBidder then
			local itemID, _, suffixID = Util.ParseItemLink(row.link)
			if itemID then
				local itemKey = Util.ItemKey(itemID, suffixID)
				-- Safe to call for every accepted row (buyout or bid-only
				-- alike) -- it's a no-op once known, and Deals:Evaluate
				-- below needs it either way for the vendor-flip check.
				PriceDB:ResolveVendorSell(self.scopeKey, itemKey, row.link)

				local hasBuyout = row.buyoutPrice and row.buyoutPrice > 0
				local unitPrice = hasBuyout and math.floor(row.buyoutPrice / row.count) or nil

				-- "Next required bid": once someone's already bid, minBid
				-- no longer reflects what YOU would need to bid to take
				-- the lead -- that's bidAmount + minIncrement instead.
				local nextBid = (row.bidAmount and row.bidAmount > 0)
					and (row.bidAmount + (row.minIncrement or 0))
					or row.minBid

				if hasBuyout then
					-- Price history and the materials-undercut peer
					-- comparison stay buyout-only: a minimum bid isn't a
					-- real asking price, just wherever the auction
					-- happened to start, and letting a 0-ish bid-only
					-- "price" into either would corrupt both.
					local entry = self.staged[itemKey]
					if not entry then
						entry = { itemID = itemID, suffixID = suffixID, name = row.name,
							iconTexture = row.iconTexture, prices = {} }
						self.staged[itemKey] = entry
						self.stats.itemsStaged = self.stats.itemsStaged + 1
					end
					table.insert(entry.prices, unitPrice)

					-- Track the cheapest full row seen this scan for this
					-- item, so the post-scan materials peer-price undercut
					-- pass (Deals:EvaluateMaterialUndercuts, called from
					-- CommitStaged) has enough detail to build a buyable
					-- deal from it, not just a bare unit-price number.
					if not entry.cheapestRow or unitPrice < entry.cheapestRow.buyoutPerItem then
						entry.cheapestRow = {
							itemID = itemID, suffixID = suffixID, link = row.link,
							name = row.name, iconTexture = row.iconTexture, count = row.count,
							buyoutPerItem = unitPrice, buyoutTotal = row.buyoutPrice,
							owner = row.owner, minBid = nextBid,
						}
					end
				end

				local evalRow = {
					itemID = itemID, suffixID = suffixID, link = row.link,
					name = row.name, iconTexture = row.iconTexture,
					count = row.count, buyoutPerItem = unitPrice,
					buyoutTotal = hasBuyout and row.buyoutPrice or nil,
					owner = row.owner, minBid = nextBid,
				}
				Deals:Evaluate(evalRow)
				Excessive:Evaluate(evalRow)

				self.stats.rowsAccepted = self.stats.rowsAccepted + 1
			end
		end
	end

	self.stageCursor = last + 1
	if self.stageCursor <= self.numBatchAuctions then return end

	self.stats.pagesProcessed = self.stats.pagesProcessed + 1
	self.pageRows = nil

	if self.mode == "getall" then
		self:Finish()
		return
	end

	local isLastPage = (self.numBatchAuctions < PAGE_SIZE)
		or ((self.page + 1) * PAGE_SIZE >= self.totalAuctions)
		or (self.numBatchAuctions == 0)

	if isLastPage then
		self:Finish()
	else
		self.page = self.page + 1
		self.state = "QUERY_PENDING"
	end
end

function Scan:Finish()
	self:CommitStaged()

	-- A just-completed, unfiltered, full sweep of the AH saw everything --
	-- anything flagged that wasn't re-confirmed during it (Deals.Evaluate
	-- bumps seenAt on every sighting) is presumably sold, expired, or
	-- moved. Never run this after a filtered scan (StartPaged(filters)),
	-- which only ever looked at a subset and can't safely conclude
	-- anything outside it is gone.
	if not next(self.filters) then
		Deals:RemoveUnconfirmed(self.startedAt)
		Excessive:RemoveUnconfirmed(self.startedAt)
	end

	self.stats.lastScanTime = time()
	self.stats.lastScanMode = self.mode
	self.state = "IDLE"
end

--------------------------------------------------------------------------
-- Status text for UI.lua
--------------------------------------------------------------------------

function Scan:GetStatusText()
	if self.state == "IDLE" then
		if self.stats.lastScanTime then
			local mins = math.floor((time() - self.stats.lastScanTime) / 60)
			return string.format("Idle - last scan %dm ago (%d items)", mins, self.stats.itemsStaged or 0)
		end
		return "Idle - no scan yet"
	elseif self.state == "FAILED" then
		return "Scan failed: " .. tostring(self.failureReason) .. " (partial results saved)"
	elseif self.mode == "getall" and (self.state == "QUERY_PENDING" or self.state == "STARTING") then
		local _, canGetAll = CanSendAuctionQuery()
		if not canGetAll then
			return "Waiting for full-scan availability..."
		end
		return "Starting full scan..."
	elseif self.state == "WAIT_RESULT" or self.state == "QUERY_PENDING" then
		return string.format("Scanning page %d...", (self.page or 0) + 1)
	elseif self.state == "COLLECT_PAGE" or self.state == "STAGE_PAGE" then
		return string.format("Processing page %d (%d flagged so far)...", (self.page or 0) + 1, #Deals.flagged)
	end
	return self.state
end

return Scan
