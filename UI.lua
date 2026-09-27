-- UI.lua
-- Builds Auctionist's own standalone window (title bar, drag-to-move,
-- resizable, remembered position) with two pages -- "Deals" and "Ledger"
-- -- switched by a small tab-button row, plus the separate buy-confirmation
-- dialog and the mailbox rescan button. No XML: everything here is small
-- enough to build with CreateFrame.
--
-- This window is intentionally independent of Blizzard's AuctionFrame: it
-- doesn't need Blizzard_AuctionUI loaded, isn't bound by AuctionFrame's
-- panel bounds, and doesn't rely on hooking AuctionFrameTab_OnClick (the
-- previous approach, whose exact calling convention was never verified).
-- Scan/Buy still require actually being at an auctioneer (gated by
-- CanSendAuctionQuery(), a game-state check independent of any UI frame),
-- so nothing about their behavior changes -- only how this window is
-- shown and laid out.
--
-- NOTE: the panel/dialog anchor offsets below are a reasonable starting
-- guess, not verified in-game yet -- the in-game test is exactly "does
-- this look right", and these are the first numbers to adjust if it
-- doesn't.

local _, Auctionist = ...
local Util = Auctionist.Util
local Deals = Auctionist.Deals
local Ledger = Auctionist.Ledger

local UI = {}
Auctionist.UI = UI

local ROW_HEIGHT = 18
local VISIBLE_ROWS = 20

local MAIN_WIDTH, MAIN_HEIGHT = 760, 520
local MIN_WIDTH, MIN_HEIGHT = 600, 400
local MAX_WIDTH, MAX_HEIGHT = 1100, 800

-- Vertical space eaten by the title bar + tab-button row before a page's
-- own content area starts.
local CONTENT_TOP_INSET = 24 + 24 + 14

UI.built = false

--------------------------------------------------------------------------
-- Sortable-column value extractors: one function per sort key, returning
-- the value to compare on (nil if not applicable/known -- see
-- compareSortValues in CreateColumnHeader below, which pushes nils last).
--------------------------------------------------------------------------

local DEAL_SORT_EXTRACTORS = {
	name = function(d) return d.name and d.name:lower() or nil end,
	count = function(d) return d.count end,
	buyoutTotal = function(d) return d.buyoutTotal end,
	-- "Deal" mixes three different display tags (vendor flip / material
	-- undercut / historical % off) into one column; sorting it ranks a
	-- guaranteed vendor flip above everything else, then by whichever
	-- discount percentage is actually shown.
	deal = function(d)
		if d.isVendorFlip then return math.huge end
		if d.isMaterialUndercut then return d.peerDiscountPct end
		return d.discountPct
	end,
	profit = function(d) return d.potentialProfit end,
}

local LEDGER_SORT_EXTRACTORS = {
	name = function(e) return e.name and e.name:lower() or nil end,
	cost = function(e) return e.cost end,
	sale = function(e) return e.status == "sold" and e.saleAmount or nil end,
	profit = function(e) return e.status == "sold" and (e.saleAmount - e.cost) or nil end,
}

--------------------------------------------------------------------------
-- Build (called once, from Core.lua's PLAYER_LOGIN handler -- this no
-- longer needs to wait for Blizzard_AuctionUI at all)
--------------------------------------------------------------------------

function UI:Build()
	if self.built then return end
	self.built = true

	self:CreateMainFrame()
	self:CreateDealsPanel()
	self:CreateLedgerPanel()
	self:SelectPage("deals")
	self:CreateBuyDialog()
	self:CreateMinimapButton()

	self.mainFrame:Hide()
end

--------------------------------------------------------------------------
-- Main window chrome: title bar (drag), close button, tab buttons,
-- resize grip, remembered position/size.
--------------------------------------------------------------------------

function UI:CreateMainFrame()
	local main = CreateFrame("Frame", "AuctionistMainFrame", UIParent)
	main:SetSize(MAIN_WIDTH, MAIN_HEIGHT)
	main:SetFrameStrata("HIGH")
	main:SetToplevel(true)
	main:SetClampedToScreen(true)
	main:SetMovable(true)
	main:SetResizable(true)
	main:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
	main:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
	main:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	self.mainFrame = main

	local titleBar = CreateFrame("Frame", nil, main)
	titleBar:SetHeight(24)
	titleBar:SetPoint("TOPLEFT", main, "TOPLEFT", 8, -8)
	titleBar:SetPoint("TOPRIGHT", main, "TOPRIGHT", -8, -8)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() main:StartMoving() end)
	titleBar:SetScript("OnDragStop", function()
		main:StopMovingOrSizing()
		UI:SavePosition()
	end)

	local title = titleBar:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("LEFT", titleBar, "LEFT", 4, 0)
	title:SetText("Auctionist")

	local closeButton = CreateFrame("Button", "AuctionistMainFrameClose", main, "UIPanelCloseButton")
	closeButton:SetPoint("TOPRIGHT", main, "TOPRIGHT", -4, -4)
	closeButton:SetScript("OnClick", function() UI:Hide() end)

	local dealsTabButton = CreateFrame("Button", "AuctionistDealsTabButton", main, "UIPanelButtonTemplate")
	dealsTabButton:SetSize(100, 22)
	dealsTabButton:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -4)
	dealsTabButton:SetText("Deals")
	dealsTabButton:SetScript("OnClick", function() UI:SelectPage("deals") end)
	self.dealsTabButton = dealsTabButton

	local ledgerTabButton = CreateFrame("Button", "AuctionistLedgerTabButton", main, "UIPanelButtonTemplate")
	ledgerTabButton:SetSize(100, 22)
	ledgerTabButton:SetPoint("LEFT", dealsTabButton, "RIGHT", 16, 0)
	ledgerTabButton:SetText("Ledger")
	ledgerTabButton:SetScript("OnClick", function() UI:SelectPage("ledger") end)
	self.ledgerTabButton = ledgerTabButton

	local content = CreateFrame("Frame", nil, main)
	content:SetPoint("TOPLEFT", main, "TOPLEFT", 8, -CONTENT_TOP_INSET)
	content:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -8, 8)
	self.content = content

	-- Resize grip: bottom-right corner. VISIBLE_ROWS is a fixed count set
	-- at load time, though -- resizing changes how much blank space
	-- surrounds the list, not how many rows it shows.
	local resizeGrip = CreateFrame("Button", nil, main)
	resizeGrip:SetSize(16, 16)
	resizeGrip:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -4, 4)
	resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	resizeGrip:SetScript("OnMouseDown", function() main:StartSizing("BOTTOMRIGHT") end)
	resizeGrip:SetScript("OnMouseUp", function()
		main:StopMovingOrSizing()
		UI:SavePosition()
	end)

	self:RestorePosition()
end

--- Persists position + size to SavedVariables so the window reopens where
-- it was left. Called after every drag/resize, not on a timer.
function UI:SavePosition()
	local main = self.mainFrame
	local point, _, relativePoint, x, y = main:GetPoint(1)
	AuctionistDB.uiFrame = {
		point = point, relativePoint = relativePoint, x = x, y = y,
		width = main:GetWidth(), height = main:GetHeight(),
	}
end

function UI:RestorePosition()
	local main = self.mainFrame
	local saved = AuctionistDB.uiFrame
	main:ClearAllPoints()
	if saved then
		main:SetPoint(saved.point or "CENTER", UIParent, saved.relativePoint or "CENTER", saved.x or 0, saved.y or 0)
		if saved.width and saved.height then
			main:SetSize(saved.width, saved.height)
		end
	else
		main:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

function UI:SelectPage(pageName)
	self.activePage = pageName
	if pageName == "deals" then self.dealsPage:Show() else self.dealsPage:Hide() end
	if pageName == "ledger" then self.ledgerPage:Show() else self.ledgerPage:Hide() end
	if pageName == "deals" then self.dealsTabButton:Disable() else self.dealsTabButton:Enable() end
	if pageName == "ledger" then self.ledgerTabButton:Disable() else self.ledgerTabButton:Enable() end
end

function UI:Show()
	self.mainFrame:Show()
end

function UI:Hide()
	self.mainFrame:Hide()
end

function UI:Toggle()
	if self.mainFrame:IsShown() then self:Hide() else self:Show() end
end

--------------------------------------------------------------------------
-- Minimap button
--
-- Left-click always toggles this addon's own window. It also, as a
-- best-effort extra, calls InteractUnit("target") -- the same trick
-- "interact" macros have used since Vanilla to open a vendor's/
-- auctioneer's/mailbox's window from within interact range without
-- walking up and right-clicking them again. This only does anything
-- useful if your current target actually IS the auctioneer and you're in
-- range; otherwise it's a harmless no-op (wrapped in pcall in case the
-- target isn't interactable at all).
--------------------------------------------------------------------------

local MINIMAP_BUTTON_RADIUS = 80

function UI:CreateMinimapButton()
	AuctionistDB.minimapButton = AuctionistDB.minimapButton or { angle = 220 }

	local button = CreateFrame("Button", "AuctionistMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	self.minimapButton = button

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER")
	icon:SetTexture("Interface\\MINIMAP\\TRACKING\\Auctioneer")

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	local function UpdatePosition()
		local angle = math.rad(AuctionistDB.minimapButton.angle or 220)
		button:ClearAllPoints()
		button:SetPoint("CENTER", Minimap, "CENTER",
			math.cos(angle) * MINIMAP_BUTTON_RADIUS, math.sin(angle) * MINIMAP_BUTTON_RADIUS)
	end

	button:SetScript("OnDragStart", function(dragSelf)
		dragSelf:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			px, py = px / scale, py / scale
			AuctionistDB.minimapButton.angle = math.deg(math.atan2(py - my, px - mx))
			UpdatePosition()
		end)
	end)
	button:SetScript("OnDragStop", function(dragSelf)
		dragSelf:SetScript("OnUpdate", nil)
	end)

	button:SetScript("OnClick", function()
		UI:Toggle()
		if UnitExists("target") and UnitIsFriend("player", "target") then
			pcall(InteractUnit, "target")
		end
	end)

	button:SetScript("OnEnter", function(tipOwner)
		GameTooltip:SetOwner(tipOwner, "ANCHOR_LEFT")
		GameTooltip:AddLine("Auctionist")
		GameTooltip:AddLine("Left-click: toggle window", 1, 1, 1)
		GameTooltip:AddLine("If your target is the auctioneer and you're in range, this also opens the Auction House.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	UpdatePosition()
end

--------------------------------------------------------------------------
-- Deals page
--------------------------------------------------------------------------

function UI:CreateDealsPanel()
	local panel = CreateFrame("Frame", nil, self.content)
	panel:SetAllPoints(self.content)
	self.dealsPage = panel

	local scanBtn = CreateFrame("Button", "AuctionistScanButton", panel, "UIPanelButtonTemplate")
	scanBtn:SetSize(100, 22)
	scanBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -6)
	scanBtn:SetText("Scan Now")
	scanBtn:SetScript("OnClick", function() Auctionist.Scan:StartPaged() end)
	self.scanButton = scanBtn

	local getAllBtn = CreateFrame("Button", "AuctionistGetAllButton", panel, "UIPanelButtonTemplate")
	getAllBtn:SetSize(100, 22)
	getAllBtn:SetPoint("LEFT", scanBtn, "RIGHT", 16, 0)
	getAllBtn:SetText("Full Scan")
	getAllBtn:SetScript("OnClick", function() Auctionist.Scan:StartGetAll() end)
	self.getAllButton = getAllBtn

	local stopBtn = CreateFrame("Button", "AuctionistStopButton", panel, "UIPanelButtonTemplate")
	stopBtn:SetSize(80, 22)
	stopBtn:SetPoint("LEFT", getAllBtn, "RIGHT", 16, 0)
	stopBtn:SetText("Stop Scan")
	stopBtn:SetScript("OnClick", function() Auctionist.Scan:Stop() end)
	self.stopButton = stopBtn

	local status = panel:CreateFontString("AuctionistStatusText", "ARTWORK", "GameFontNormalSmall")
	status:SetPoint("LEFT", stopBtn, "RIGHT", 16, 0)
	status:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
	status:SetJustifyH("LEFT")
	self.statusText = status

	-- Own row, below the scan buttons: keeps the status text (which can
	-- run long, e.g. "Processing page 12 (34 flagged so far)...") from
	-- fighting this for the same horizontal space.
	local vendorFlipCheck = CreateFrame("CheckButton", "AuctionistVendorFlipOnlyCheck", panel, "UICheckButtonTemplate")
	vendorFlipCheck:SetSize(22, 22)
	vendorFlipCheck:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -34)
	_G["AuctionistVendorFlipOnlyCheckText"]:SetText("Vendor flips only")
	vendorFlipCheck:SetScript("OnClick", function(checkSelf)
		self.vendorFlipsOnly = checkSelf:GetChecked() and true or false
		self:Redisplay()
	end)
	self.vendorFlipOnlyCheck = vendorFlipCheck

	self.dealsSortState = {}
	self:CreateColumnHeader(panel, -58, {
		{ x = 22, width = 220, text = "Item", key = "name" },
		{ x = 246, width = 30, text = "Qty", key = "count" },
		{ x = 280, width = 100, text = "Buyout", key = "buyoutTotal" },
		{ x = 384, width = 90, text = "Deal", key = "deal" },
		{ x = 478, width = 150, text = "Potential Profit", key = "profit" },
	}, self.dealsSortState, function() UI:Redisplay() end)

	local scrollFrame = CreateFrame("ScrollFrame", "AuctionistScrollFrame", panel, "FauxScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -58 - ROW_HEIGHT)
	scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -24, 0)
	scrollFrame:SetScript("OnVerticalScroll", function(scrollSelf, offset)
		FauxScrollFrame_OnVerticalScroll(scrollSelf, offset, ROW_HEIGHT, function() UI:Redisplay() end)
	end)
	self.scrollFrame = scrollFrame

	self.rows = {}
	for i = 1, VISIBLE_ROWS do
		self.rows[i] = self:CreateRow(panel, i, scrollFrame)
	end

	panel:SetScript("OnUpdate", function(_, elapsed) UI:OnPanelUpdate(elapsed) end)
end

--- Pushes non-nil values before nil ones (so e.g. unsold ledger rows or
-- deals with no computable profit sort to the bottom regardless of
-- direction), otherwise compares normally in the requested direction.
local function compareSortValues(a, b, ascending)
	if a == nil and b == nil then return false end
	if a == nil then return false end
	if b == nil then return true end
	if ascending then return a < b end
	return a > b
end
UI.CompareSortValues = compareSortValues

--- Shared by the Deals and Ledger pages: a row of column-label
-- FontStrings (or, for sortable columns, clickable buttons) above the
-- scrollable list, at the same x-offsets the data rows use for their own
-- columns (so labels line up with data).
--
-- `columns` is an array of { x, width, text, key }. A column with a `key`
-- becomes clickable: clicking it sorts the list by that key (toggling
-- ascending/descending on repeat clicks of the same column), tracked in
-- `sortState` ({ key, ascending }, shared with Redisplay/RedisplayLedger)
-- and applied by calling `onSortChanged` after each click. A column with
-- no `key` is a plain, non-interactive label.
function UI:CreateColumnHeader(panel, y, columns, sortState, onSortChanged)
	local header = CreateFrame("Frame", nil, panel)
	header:SetHeight(ROW_HEIGHT)
	header:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
	header:SetPoint("RIGHT", panel, "RIGHT", -24, 0)

	local labels = {}
	local function refreshLabels()
		for _, entry in ipairs(labels) do
			local text = entry.col.text
			if sortState.key == entry.col.key then
				text = text .. (sortState.ascending and " ^" or " v")
			end
			entry.fs:SetText(text)
		end
	end

	for _, col in ipairs(columns) do
		if col.key and sortState then
			local btn = CreateFrame("Button", nil, header)
			btn:SetPoint("LEFT", header, "LEFT", col.x, 0)
			btn:SetSize(col.width, ROW_HEIGHT)
			btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

			local fs = btn:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			fs:SetAllPoints(btn)
			fs:SetJustifyH("LEFT")
			fs:SetTextColor(1, 0.82, 0)
			fs:SetText(col.text)

			btn:SetScript("OnClick", function()
				if sortState.key == col.key then
					sortState.ascending = not sortState.ascending
				else
					sortState.key = col.key
					sortState.ascending = true
				end
				refreshLabels()
				onSortChanged()
			end)

			table.insert(labels, { col = col, fs = fs })
		else
			local fs = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			fs:SetPoint("LEFT", header, "LEFT", col.x, 0)
			fs:SetWidth(col.width)
			fs:SetJustifyH("LEFT")
			fs:SetTextColor(1, 0.82, 0)
			fs:SetText(col.text)
		end
	end

	return header
end

function UI:CreateRow(parent, index, scrollFrame)
	local row = CreateFrame("Button", "AuctionistRow" .. index, parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
	row:SetPoint("RIGHT", scrollFrame, "RIGHT", 0, 0)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
	row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)

	row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
	row.name:SetWidth(220)
	row.name:SetJustifyH("LEFT")

	row.count = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.count:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
	row.count:SetWidth(30)

	row.price = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.price:SetPoint("LEFT", row.count, "RIGHT", 4, 0)
	row.price:SetWidth(100)
	row.price:SetJustifyH("LEFT")

	row.discount = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.discount:SetPoint("LEFT", row.price, "RIGHT", 4, 0)
	row.discount:SetWidth(90)
	row.discount:SetJustifyH("LEFT")

	row.profit = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.profit:SetPoint("LEFT", row.discount, "RIGHT", 4, 0)
	row.profit:SetWidth(100)
	row.profit:SetJustifyH("LEFT")

	row.buyButton = CreateFrame("Button", "AuctionistRow" .. index .. "Buy", row, "UIPanelButtonTemplate")
	row.buyButton:SetSize(50, ROW_HEIGHT - 2)
	row.buyButton:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	row.buyButton:SetText("Buy")
	row.buyButton:SetScript("OnClick", function()
		if row.deal then UI:OpenBuyDialog(row.deal) end
	end)

	row:Hide()
	return row
end

--------------------------------------------------------------------------
-- Per-frame refresh
--------------------------------------------------------------------------

function UI:OnPanelUpdate(elapsed)
	self.updateElapsed = (self.updateElapsed or 0) + elapsed
	if self.updateElapsed < 0.5 then return end
	self.updateElapsed = 0

	self.statusText:SetText(Auctionist.Scan:GetStatusText())

	local scanState = Auctionist.Scan.state
	local scanBusy = scanState ~= "IDLE" and scanState ~= "FAILED"
	local canQuery, canGetAll = CanSendAuctionQuery()

	if scanBusy or not canQuery then self.scanButton:Disable() else self.scanButton:Enable() end
	if scanBusy or not canGetAll then self.getAllButton:Disable() else self.getAllButton:Enable() end
	if scanBusy then self.stopButton:Enable() else self.stopButton:Disable() end

	local flaggedCount = #Deals:GetFlagged()
	if flaggedCount ~= self.lastFlaggedCount then
		self.lastFlaggedCount = flaggedCount
		self:Redisplay()
	end
end

function UI:Redisplay()
	local list = Deals:GetFlagged()

	if self.vendorFlipsOnly then
		local filtered = {}
		for _, deal in ipairs(list) do
			if deal.isVendorFlip then table.insert(filtered, deal) end
		end
		list = filtered
	end

	local sortState = self.dealsSortState
	if sortState.key then
		local sorted = {}
		for i, deal in ipairs(list) do sorted[i] = deal end
		local extractor = DEAL_SORT_EXTRACTORS[sortState.key]
		local ascending = sortState.ascending
		table.sort(sorted, function(a, b)
			return compareSortValues(extractor(a), extractor(b), ascending)
		end)
		list = sorted
	end

	FauxScrollFrame_Update(self.scrollFrame, #list, VISIBLE_ROWS, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(self.scrollFrame)

	for i = 1, VISIBLE_ROWS do
		local row = self.rows[i]
		local deal = list[offset + i]

		if deal then
			row.deal = deal
			row.icon:SetTexture(deal.iconTexture)
			row.name:SetText(deal.name or "?")
			row.count:SetText(tostring(deal.count))
			row.price:SetText(Util.FormatMoney(deal.buyoutTotal))
			if deal.isVendorFlip then
				-- Guaranteed-profit vendor arbitrage: called out distinctly
				-- and independently of any market-value discount, since it
				-- carries no resale-timing risk at all.
				row.discount:SetText(deal.isVendorFlipBid and "Vendor flip!*" or "Vendor flip!")
				row.discount:SetTextColor(0.15, 1, 0.15)
			elseif deal.isMaterialUndercut then
				-- Crafting material priced far below what other sellers
				-- are currently asking for the same item this scan --
				-- resale-timing risk still applies (unlike a vendor flip),
				-- but needs no price history at all to spot.
				row.discount:SetText(string.format("Material -%d%%",
					math.floor((deal.peerDiscountPct or 0) * 100 + 0.5)))
				row.discount:SetTextColor(1, 0.82, 0)
			elseif deal.discountPct then
				row.discount:SetText(string.format("%d%% off", math.floor(deal.discountPct * 100 + 0.5)))
				row.discount:SetTextColor(1, 1, 1)
			else
				row.discount:SetText("vendor")
				row.discount:SetTextColor(1, 1, 1)
			end

			if deal.potentialProfit then
				row.profit:SetText(Util.FormatMoney(deal.potentialProfit))
				if deal.potentialProfit >= 0 then
					row.profit:SetTextColor(0.15, 1, 0.15)
				else
					row.profit:SetTextColor(1, 0.3, 0.3)
				end
			else
				row.profit:SetText("-")
				row.profit:SetTextColor(1, 1, 1)
			end
			row:Show()
		else
			row.deal = nil
			row:Hide()
		end
	end
end

--------------------------------------------------------------------------
-- Ledger page (profit/loss)
--------------------------------------------------------------------------

function UI:CreateLedgerPanel()
	local panel = CreateFrame("Frame", nil, self.content)
	panel:SetAllPoints(self.content)
	self.ledgerPage = panel

	-- No mailbox-scan button here: GetInboxNumItems()/GetInboxHeaderInfo()
	-- only reflect real data while the actual mailbox UI is open, and you
	-- can't have this window and the mailbox interacting at the same
	-- auctioneer/mailbox NPC at once anyway. The manual rescan trigger
	-- lives on the real MailFrame instead (see EnsureMailboxButton below);
	-- this page is read-only summary/history.
	local summary = panel:CreateFontString("AuctionistLedgerSummaryText", "ARTWORK", "GameFontNormalSmall")
	summary:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -10)
	summary:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
	summary:SetJustifyH("LEFT")
	self.ledgerSummaryText = summary

	self.ledgerSortState = {}
	self:CreateColumnHeader(panel, -34, {
		{ x = 22, width = 190, text = "Item", key = "name" },
		{ x = 216, width = 90, text = "Cost", key = "cost" },
		{ x = 310, width = 90, text = "Sale", key = "sale" },
		{ x = 404, width = 100, text = "Profit", key = "profit" },
	}, self.ledgerSortState, function() UI:RedisplayLedger() end)

	local scrollFrame = CreateFrame("ScrollFrame", "AuctionistLedgerScrollFrame", panel, "FauxScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -34 - ROW_HEIGHT)
	scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -24, 0)
	scrollFrame:SetScript("OnVerticalScroll", function(scrollSelf, offset)
		FauxScrollFrame_OnVerticalScroll(scrollSelf, offset, ROW_HEIGHT, function() UI:RedisplayLedger() end)
	end)
	self.ledgerScrollFrame = scrollFrame

	self.ledgerRows = {}
	for i = 1, VISIBLE_ROWS do
		self.ledgerRows[i] = self:CreateLedgerRow(panel, i, scrollFrame)
	end

	panel:SetScript("OnUpdate", function(_, elapsed) UI:OnLedgerPanelUpdate(elapsed) end)
end

function UI:CreateLedgerRow(parent, index, scrollFrame)
	local row = CreateFrame("Frame", "AuctionistLedgerRow" .. index, parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
	row:SetPoint("RIGHT", scrollFrame, "RIGHT", 0, 0)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
	row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)

	row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
	row.name:SetWidth(190)
	row.name:SetJustifyH("LEFT")

	row.cost = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.cost:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
	row.cost:SetWidth(90)
	row.cost:SetJustifyH("LEFT")

	row.sale = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.sale:SetPoint("LEFT", row.cost, "RIGHT", 4, 0)
	row.sale:SetWidth(90)
	row.sale:SetJustifyH("LEFT")

	row.profit = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.profit:SetPoint("LEFT", row.sale, "RIGHT", 4, 0)
	row.profit:SetWidth(100)
	row.profit:SetJustifyH("LEFT")

	row:Hide()
	return row
end

function UI:OnLedgerPanelUpdate(elapsed)
	self.ledgerUpdateElapsed = (self.ledgerUpdateElapsed or 0) + elapsed
	if self.ledgerUpdateElapsed < 0.5 then return end
	self.ledgerUpdateElapsed = 0

	local scopeKey = Auctionist.PriceDB:ScopeKey()
	local entries = Ledger:GetEntries(scopeKey)
	if #entries ~= self.lastLedgerCount then
		self.lastLedgerCount = #entries
		self:RedisplayLedger()
	end
end

function UI:RedisplayLedger()
	local scopeKey = Auctionist.PriceDB:ScopeKey()
	local entries = Ledger:GetEntries(scopeKey)
	local summary = Ledger:Summary(scopeKey)

	self.ledgerSummaryText:SetText(string.format(
		"Spent %s | Revenue %s | Profit %s | %d sold, %d unsold (%s tied up)",
		Util.FormatMoney(summary.totalSpent), Util.FormatMoney(summary.totalRevenue),
		Util.FormatMoney(summary.totalProfit), summary.soldCount, summary.unsoldCount,
		Util.FormatMoney(summary.unsoldCost)))
	if summary.totalProfit < 0 then
		self.ledgerSummaryText:SetTextColor(1, 0.3, 0.3)
	else
		self.ledgerSummaryText:SetTextColor(0.6, 1, 0.6)
	end

	-- Newest first by default; overridden below if a column is sorted.
	local ordered = {}
	for i = #entries, 1, -1 do
		table.insert(ordered, entries[i])
	end

	local sortState = self.ledgerSortState
	if sortState.key then
		local extractor = LEDGER_SORT_EXTRACTORS[sortState.key]
		local ascending = sortState.ascending
		table.sort(ordered, function(a, b)
			return compareSortValues(extractor(a), extractor(b), ascending)
		end)
	end

	FauxScrollFrame_Update(self.ledgerScrollFrame, #ordered, VISIBLE_ROWS, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(self.ledgerScrollFrame)

	for i = 1, VISIBLE_ROWS do
		local row = self.ledgerRows[i]
		local entry = ordered[offset + i]

		if entry then
			row.icon:SetTexture(entry.iconTexture)
			row.name:SetText((entry.name or "?") .. (entry.count and entry.count > 1 and (" x" .. entry.count) or ""))
			row.cost:SetText(Util.FormatMoney(entry.cost))

			if entry.status == "sold" then
				row.sale:SetText(Util.FormatMoney(entry.saleAmount))
				local profit = entry.saleAmount - entry.cost
				row.profit:SetText(Util.FormatMoney(profit))
				row.profit:SetTextColor(profit >= 0 and 0.15 or 1, profit >= 0 and 1 or 0.3, profit >= 0 and 0.15 or 0.3)
			else
				row.sale:SetText("unsold")
				row.profit:SetText("-")
				row.profit:SetTextColor(1, 1, 1)
			end
			row:Show()
		else
			row:Hide()
		end
	end
end

--------------------------------------------------------------------------
-- Mailbox rescan button
--
-- Lives on the real MailFrame, NOT our own window: ScanMailbox() reads
-- GetInboxNumItems()/GetInboxHeaderInfo(), which only reflect real data
-- while the mailbox UI is actually open. Auto-detection (MAIL_SHOW /
-- MAIL_INBOX_UPDATE / a periodic re-scan while the mailbox is open, all in
-- Ledger.lua) already covers the normal case; this button is only for
-- forcing an on-demand check.
--
-- MailFrame is base FrameXML (always loaded), so this is created lazily
-- on first MAIL_SHOW rather than at load time, purely to avoid touching
-- the frame before it's ever relevant.
--------------------------------------------------------------------------

function UI:EnsureMailboxButton()
	if self.mailRescanButton then return end

	-- Anchor offset is a first guess, not verified in-game yet (same
	-- caveat as the other panel anchors in this file) -- adjust if it
	-- overlaps MailFrame's own close button or inbox scroll list.
	local btn = CreateFrame("Button", "AuctionistMailRescanButton", MailFrame, "UIPanelButtonTemplate")
	btn:SetSize(120, 22)
	btn:SetPoint("TOPRIGHT", MailFrame, "TOPRIGHT", -34, -30)
	btn:SetText("Rescan Sold Mail")
	btn:SetScript("OnClick", function() Ledger:ScanMailbox(true) end)
	self.mailRescanButton = btn
end

--------------------------------------------------------------------------
-- Buy confirmation dialog
--------------------------------------------------------------------------

function UI:CreateBuyDialog()
	-- Plain Frame + SetBackdrop, not BackdropTemplate: SetBackdrop is
	-- native on 3.3.5, no template inherit needed (lessonslearned.md).
	local dlg = CreateFrame("Frame", "AuctionistBuyDialog", UIParent)
	dlg:SetSize(300, 130)
	dlg:SetPoint("CENTER")
	dlg:SetFrameStrata("DIALOG")
	dlg:EnableMouse(true)
	dlg:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	dlg:Hide()

	dlg.text = dlg:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	dlg.text:SetPoint("TOP", dlg, "TOP", 0, -24)
	dlg.text:SetWidth(260)
	dlg.text:SetJustifyH("CENTER")

	dlg.confirmButton = CreateFrame("Button", "AuctionistBuyDialogConfirm", dlg, "UIPanelButtonTemplate")
	dlg.confirmButton:SetSize(90, 22)
	dlg.confirmButton:SetPoint("BOTTOMLEFT", dlg, "BOTTOMLEFT", 30, 16)
	dlg.confirmButton:SetText("Confirm")
	dlg.confirmButton:SetScript("OnClick", function()
		-- Must run directly from this OnClick -- PlaceAuctionBid requires
		-- a real hardware-event click, not a timer/event callback.
		Auctionist.Buy:Confirm()
	end)

	dlg.closeButton = CreateFrame("Button", "AuctionistBuyDialogClose", dlg, "UIPanelButtonTemplate")
	dlg.closeButton:SetSize(90, 22)
	dlg.closeButton:SetPoint("BOTTOMRIGHT", dlg, "BOTTOMRIGHT", -30, 16)
	dlg.closeButton:SetText("Close")
	dlg.closeButton:SetScript("OnClick", function() dlg:Hide() end)

	dlg:SetScript("OnUpdate", function() UI:UpdateBuyDialog() end)

	self.buyDialog = dlg
end

function UI:OpenBuyDialog(deal)
	local ok, err = Auctionist.Buy:Start(deal)
	if not ok then
		if UIErrorsFrame then
			UIErrorsFrame:AddMessage(err or "Cannot start purchase", 1, 0.2, 0.2)
		end
		return
	end

	self.buyDialog:Show()
	self:UpdateBuyDialog()
end

function UI:UpdateBuyDialog()
	local dlg = self.buyDialog
	if not dlg or not dlg:IsShown() then return end

	local Buy = Auctionist.Buy
	local state = Buy.state

	if state == "LOCATING" or state == "WAIT_LOCATE" then
		dlg.text:SetText("Locating auction...")
		dlg.confirmButton:Disable()
	elseif state == "ARMED" then
		local deal = Buy.deal
		dlg.text:SetText((deal and deal.name or "?") .. "\n" .. Util.FormatMoney(Buy.armedBuyout))
		dlg.confirmButton:Enable()
	elseif state == "BID_SENT" then
		dlg.text:SetText("Placing bid...")
		dlg.confirmButton:Disable()
	elseif state == "DONE" or state == "FAILED" then
		dlg.text:SetText(Buy.resultText or "")
		dlg.confirmButton:Disable()
	end
end

return UI
