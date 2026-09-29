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
local Excessive = Auctionist.Excessive

local UI = {}
Auctionist.UI = UI

local ROW_HEIGHT = 18
local VISIBLE_ROWS = 20

-- Widened from 760 to fit separate Buyout/Bid profit columns without
-- wrapping (see CreateDealsPanel's column layout) -- Bid Profit needs room
-- for the longest case, e.g. "12g 34s 56c (if won)".
local MAIN_WIDTH, MAIN_HEIGHT = 960, 520
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
		if d.buyoutQualifies then
			if d.isVendorFlip then return math.huge end
			if d.isMaterialUndercut then return d.peerDiscountPct end
			return d.discountPct
		elseif d.bidQualifies then
			if d.isVendorFlipBid then return math.huge end
			return d.bidDiscountPct
		end
		return nil
	end,
	buyoutProfit = function(d) return d.buyoutQualifies and d.potentialProfit or nil end,
	bidProfit = function(d) return d.bidQualifies and d.bidPotentialProfit or nil end,
}

local LEDGER_SORT_EXTRACTORS = {
	name = function(e) return e.name and e.name:lower() or nil end,
	cost = function(e) return e.cost end,
	sale = function(e) return (e.status == "sold" or e.status == "vendored") and e.saleAmount or nil end,
	profit = function(e) return (e.status == "sold" or e.status == "vendored") and (e.saleAmount - e.cost) or nil end,
}

local EXCESSIVE_SORT_EXTRACTORS = {
	name = function(r) return r.name and r.name:lower() or nil end,
	count = function(r) return r.count end,
	buyoutTotal = function(r) return r.buyoutTotal end,
	marketValue = function(r) return r.marketValue end,
	multiple = function(r) return r.multiple end,
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
	self:CreateExcessivePanel()
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
	-- x=8, not 0: lines the tab buttons up directly above Scan Now/Full
	-- Scan below (which sit 8px inset into `content`, itself already
	-- 8px inset into `main` the same as titleBar -- so this 8 is the
	-- extra step to match content's own inset, not titleBar's).
	dealsTabButton:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 8, -4)
	dealsTabButton:SetText("Deals")
	dealsTabButton:SetScript("OnClick", function() UI:SelectPage("deals") end)
	self.dealsTabButton = dealsTabButton

	local ledgerTabButton = CreateFrame("Button", "AuctionistLedgerTabButton", main, "UIPanelButtonTemplate")
	ledgerTabButton:SetSize(100, 22)
	ledgerTabButton:SetPoint("LEFT", dealsTabButton, "RIGHT", 16, 0)
	ledgerTabButton:SetText("Ledger")
	ledgerTabButton:SetScript("OnClick", function() UI:SelectPage("ledger") end)
	self.ledgerTabButton = ledgerTabButton

	local excessiveTabButton = CreateFrame("Button", "AuctionistExcessiveTabButton", main, "UIPanelButtonTemplate")
	excessiveTabButton:SetSize(100, 22)
	excessiveTabButton:SetPoint("LEFT", ledgerTabButton, "RIGHT", 16, 0)
	excessiveTabButton:SetText("Excessive")
	excessiveTabButton:SetScript("OnClick", function() UI:SelectPage("excessive") end)
	self.excessiveTabButton = excessiveTabButton

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
	if pageName == "excessive" then self.excessivePage:Show() else self.excessivePage:Hide() end
	if pageName == "deals" then self.dealsTabButton:Disable() else self.dealsTabButton:Enable() end
	if pageName == "ledger" then self.ledgerTabButton:Disable() else self.ledgerTabButton:Enable() end
	if pageName == "excessive" then self.excessiveTabButton:Disable() else self.excessiveTabButton:Enable() end
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
-- Left-click toggles this addon's own window. (An earlier version also
-- called InteractUnit("target") as a "reopen the auctioneer" shortcut --
-- removed, since InteractUnit can only be called by Blizzard's default
-- UI and always throws a blocked-action error from an addon.)
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
	end)

	button:SetScript("OnEnter", function(tipOwner)
		GameTooltip:SetOwner(tipOwner, "ANCHOR_LEFT")
		GameTooltip:AddLine("Auctionist")
		GameTooltip:AddLine("Left-click: toggle window", 1, 1, 1)
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
	scanBtn:SetScript("OnClick", function()
		local filters = {}
		if UI.selectedClassIndex then filters.classIndex = UI.selectedClassIndex end
		if UI.selectedSubclassIndex then filters.subclassIndex = UI.selectedSubclassIndex end
		Auctionist.Scan:StartPaged(filters)
	end)
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

	-- Item-name search: a filtered Scan Now under the hood (same
	-- StartPaged(filters) path, just with f.name set), so it still requires
	-- being at an auctioneer and still respects the category/subcategory
	-- dropdowns if one's set -- a separate button rather than folding into
	-- Scan Now itself since typing a name and clicking a distinct "Search"
	-- is the more obvious affordance.
	local searchBox = CreateFrame("EditBox", "AuctionistSearchBox", panel, "InputBoxTemplate")
	searchBox:SetSize(90, 20)
	searchBox:SetPoint("LEFT", stopBtn, "RIGHT", 20, -1)
	searchBox:SetAutoFocus(false)
	searchBox:SetMaxLetters(50)
	self.searchBox = searchBox

	local searchBtn = CreateFrame("Button", "AuctionistSearchButton", panel, "UIPanelButtonTemplate")
	searchBtn:SetSize(60, 22)
	searchBtn:SetPoint("LEFT", searchBox, "RIGHT", 4, 1)
	searchBtn:SetText("Search")
	searchBtn:SetScript("OnClick", function()
		local text = searchBox:GetText()
		local filters = {}
		if text and text ~= "" then filters.name = text end
		if UI.selectedClassIndex then filters.classIndex = UI.selectedClassIndex end
		if UI.selectedSubclassIndex then filters.subclassIndex = UI.selectedSubclassIndex end
		Auctionist.Scan:StartPaged(filters)
		searchBox:ClearFocus()
	end)
	self.searchButton = searchBtn

	searchBox:SetScript("OnEnterPressed", function() searchBtn:Click() end)
	searchBox:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)

	local status = panel:CreateFontString("AuctionistStatusText", "ARTWORK", "GameFontNormalSmall")
	status:SetPoint("LEFT", searchBtn, "RIGHT", 16, 0)
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

	local purgeBtn = CreateFrame("Button", "AuctionistPurgeStaleButton", panel, "UIPanelButtonTemplate")
	purgeBtn:SetSize(100, 22)
	purgeBtn:SetPoint("LEFT", vendorFlipCheck, "RIGHT", 170, 0)
	purgeBtn:SetText("Purge Stale")
	purgeBtn:SetScript("OnClick", function()
		local removed = Deals:PurgeStale()
		print(string.format("Auctionist: purged %d stale deal(s).", removed))
	end)
	self.purgeStaleButton = purgeBtn

	-- Category filter: top-level categories (e.g. "Trade Goods", "Armor")
	-- plus an optional subcategory drill-down -- Scan Now only, since a
	-- getAll (Full Scan) always sweeps the whole AH by design/API
	-- constraint and can't be class-filtered. Scan:Finish() already skips
	-- the auto stale-sweep for any filtered scan (see Scan.lua), so using
	-- this never wrongly prunes deals outside the chosen category.
	local categoryDropdown = CreateFrame("Frame", "AuctionistCategoryDropdown", panel, "UIDropDownMenuTemplate")
	categoryDropdown:SetPoint("LEFT", purgeBtn, "RIGHT", 90, -2)
	UIDropDownMenu_SetWidth(categoryDropdown, 130)
	UIDropDownMenu_SetText(categoryDropdown, "All Categories")

	-- Subcategory is optional and only meaningful once a top-level category
	-- is picked (QueryAuctionItems ignores a subclassIndex without a
	-- matching classIndex), so it starts disabled/reset and only offers
	-- entries for the currently-selected class.
	local subcategoryDropdown = CreateFrame("Frame", "AuctionistSubcategoryDropdown", panel, "UIDropDownMenuTemplate")
	subcategoryDropdown:SetPoint("LEFT", categoryDropdown, "RIGHT", -8, 0)
	UIDropDownMenu_SetWidth(subcategoryDropdown, 130)
	UIDropDownMenu_SetText(subcategoryDropdown, "All Subcategories")

	local function OnSubcategorySelect(entrySelf)
		UI.selectedSubclassIndex = entrySelf.value
		UIDropDownMenu_SetText(subcategoryDropdown, entrySelf:GetText())
		CloseDropDownMenus()
		UI:Redisplay()
		UI:RedisplayExcessive()
	end

	local function ResetSubcategoryDropdown()
		UI.selectedSubclassIndex = nil
		UIDropDownMenu_SetText(subcategoryDropdown, "All Subcategories")
		if UI.selectedClassIndex then
			UIDropDownMenu_EnableDropDown(subcategoryDropdown)
		else
			UIDropDownMenu_DisableDropDown(subcategoryDropdown)
		end
	end

	local function OnCategorySelect(entrySelf)
		UI.selectedClassIndex = entrySelf.value
		UIDropDownMenu_SetText(categoryDropdown, entrySelf:GetText())
		CloseDropDownMenus()
		ResetSubcategoryDropdown()
		UI:Redisplay()
		UI:RedisplayExcessive()
	end

	UIDropDownMenu_Initialize(categoryDropdown, function()
		local info = UIDropDownMenu_CreateInfo()
		info.text = "All Categories"
		info.value = nil
		info.func = OnCategorySelect
		UIDropDownMenu_AddButton(info)

		-- GetAuctionItemClasses()'s 1-based position IS the classIndex
		-- QueryAuctionItems expects (confirmed against Auctionator's own
		-- Atr_ItemType2AuctionClass/QueryAuctionItems usage) -- top-level
		-- categories only, no subclass drill-down.
		for i, name in ipairs({ GetAuctionItemClasses() }) do
			info = UIDropDownMenu_CreateInfo()
			info.text = name
			info.value = i
			info.func = OnCategorySelect
			UIDropDownMenu_AddButton(info)
		end
	end)
	self.categoryDropdown = categoryDropdown

	UIDropDownMenu_Initialize(subcategoryDropdown, function()
		local info = UIDropDownMenu_CreateInfo()
		info.text = "All Subcategories"
		info.value = nil
		info.func = OnSubcategorySelect
		UIDropDownMenu_AddButton(info)

		if UI.selectedClassIndex then
			-- Same 1-based-position-as-index assumption as the top-level
			-- class list above, applied to GetAuctionItemSubClasses --
			-- unverified in-game like the rest of this dropdown's offsets.
			for i, name in ipairs({ GetAuctionItemSubClasses(UI.selectedClassIndex) }) do
				info = UIDropDownMenu_CreateInfo()
				info.text = name
				info.value = i
				info.func = OnSubcategorySelect
				UIDropDownMenu_AddButton(info)
			end
		end
	end)
	ResetSubcategoryDropdown()
	self.subcategoryDropdown = subcategoryDropdown

	self.dealsSortState = {}
	self:CreateColumnHeader(panel, -58, {
		{ x = 22, width = 220, text = "Item", key = "name" },
		{ x = 246, width = 30, text = "Qty", key = "count" },
		{ x = 280, width = 100, text = "Buyout", key = "buyoutTotal" },
		{ x = 384, width = 90, text = "Deal", key = "deal" },
		{ x = 478, width = 110, text = "Buyout Profit", key = "buyoutProfit" },
		{ x = 592, width = 140, text = "Bid Profit", key = "bidProfit" },
		{ x = 736, width = 40, text = "Age" },
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

	-- Buyout and bid are independent qualifying paths (see Deals.lua), so a
	-- row can offer both at once with different profit figures -- separate
	-- columns rather than cramming both into one field (which used to wrap
	-- onto a second line and bleed into the row below).
	row.buyoutProfit = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.buyoutProfit:SetPoint("LEFT", row.discount, "RIGHT", 4, 0)
	row.buyoutProfit:SetWidth(110)
	row.buyoutProfit:SetJustifyH("LEFT")

	row.bidProfit = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.bidProfit:SetPoint("LEFT", row.buyoutProfit, "RIGHT", 4, 0)
	row.bidProfit:SetWidth(140)
	row.bidProfit:SetJustifyH("LEFT")

	row.stale = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.stale:SetPoint("LEFT", row.bidProfit, "RIGHT", 4, 0)
	row.stale:SetWidth(40)
	row.stale:SetJustifyH("LEFT")

	-- Two independent buttons, not one: a listing can qualify as a deal
	-- via its buyout, its current minimum bid, or both, and each needs
	-- its own action (see Buy:Start's mode parameter). Anchored
	-- separately (not chained off each other) so hiding one doesn't
	-- shift the other.
	row.bidButton = CreateFrame("Button", "AuctionistRow" .. index .. "Bid", row, "UIPanelButtonTemplate")
	row.bidButton:SetSize(46, ROW_HEIGHT - 2)
	row.bidButton:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	row.bidButton:SetText("Bid")
	row.bidButton:SetScript("OnClick", function()
		if row.deal then UI:OpenBuyDialog(row.deal, "bid") end
	end)

	row.buyoutButton = CreateFrame("Button", "AuctionistRow" .. index .. "Buyout", row, "UIPanelButtonTemplate")
	row.buyoutButton:SetSize(56, ROW_HEIGHT - 2)
	row.buyoutButton:SetPoint("RIGHT", row, "RIGHT", -52, 0)
	row.buyoutButton:SetText("Buyout")
	row.buyoutButton:SetScript("OnClick", function()
		if row.deal then UI:OpenBuyDialog(row.deal, "buyout") end
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
	if scanBusy or not canQuery then self.searchButton:Disable() else self.searchButton:Enable() end
	if scanBusy then self.stopButton:Enable() else self.stopButton:Disable() end

	local flaggedCount = #Deals:GetFlagged()
	if flaggedCount ~= self.lastFlaggedCount then
		self.lastFlaggedCount = flaggedCount
		self:Redisplay()
	end
end

function UI:Redisplay()
	local list = Deals:GetFlagged()

	-- A selected category/subcategory only ever restricted what a NEW scan
	-- asked the AH for -- it never pruned deals already flagged from a
	-- broader (or differently-filtered) earlier scan, which made the
	-- dropdown look like it did nothing. Filter the display itself too, by
	-- the category each deal's own scan was restricted to (nil -- i.e. an
	-- unfiltered Scan Now or a getAll Full Scan -- never matches a selected
	-- category, so those need a re-scan under that filter to show here).
	if UI.selectedClassIndex then
		local filtered = {}
		for _, deal in ipairs(list) do
			if deal.scanClassIndex == UI.selectedClassIndex
				and (not UI.selectedSubclassIndex or deal.scanSubclassIndex == UI.selectedSubclassIndex) then
				table.insert(filtered, deal)
			end
		end
		list = filtered
	end

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
			row.price:SetText(deal.buyoutTotal and Util.FormatMoney(deal.buyoutTotal) or "no buyout")

			if deal.buyoutQualifies then
				if deal.isVendorFlip then
					-- Guaranteed-profit vendor arbitrage: called out
					-- distinctly and independently of any market-value
					-- discount, since it carries no resale-timing risk at all.
					row.discount:SetText("Vendor flip!")
					row.discount:SetTextColor(0.15, 1, 0.15)
				elseif deal.isMaterialUndercut then
					-- Crafting material priced far below what other sellers
					-- are currently asking for the same item this scan --
					-- resale-timing risk still applies (unlike a vendor
					-- flip), but needs no price history at all to spot.
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
			elseif deal.bidQualifies then
				-- No buyout deal here (or its buyout isn't attractive), but
				-- the current minimum bid is -- distinctly colored and
				-- labeled "if won" since, unlike a buyout, winning a bid is
				-- never guaranteed.
				if deal.isVendorFlipBid then
					row.discount:SetText("Bid: vendor flip!*")
				else
					row.discount:SetText(string.format("Bid: %d%% off",
						math.floor((deal.bidDiscountPct or 0) * 100 + 0.5)))
				end
				row.discount:SetTextColor(0.4, 0.7, 1)
			else
				row.discount:SetText("-")
				row.discount:SetTextColor(1, 1, 1)
			end

			-- Buyout and bid are independent qualifying paths (see
			-- Deals.lua) with their own dedicated columns, so a row can show
			-- both profit figures at once instead of one hiding the other.
			if deal.buyoutQualifies then
				row.buyoutProfit:SetText(Util.FormatMoney(deal.potentialProfit))
				row.buyoutProfit:SetTextColor(0.15, 1, 0.15)
			else
				row.buyoutProfit:SetText("-")
				row.buyoutProfit:SetTextColor(1, 1, 1)
			end

			if deal.bidQualifies then
				row.bidProfit:SetText(Util.FormatMoney(deal.bidPotentialProfit) .. " (if won)")
				row.bidProfit:SetTextColor(0.4, 0.7, 1)
			else
				row.bidProfit:SetText("-")
				row.bidProfit:SetTextColor(1, 1, 1)
			end

			if Deals:IsStale(deal) then
				row.stale:SetText("Stale")
				row.stale:SetTextColor(1, 0.5, 0.2)
			else
				row.stale:SetText("")
			end

			if deal.buyoutQualifies then row.buyoutButton:Show() else row.buyoutButton:Hide() end
			if deal.bidQualifies then row.bidButton:Show() else row.bidButton:Hide() end

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

			if entry.status == "sold" or entry.status == "vendored" then
				local saleText = Util.FormatMoney(entry.saleAmount)
				if entry.status == "vendored" then saleText = saleText .. " (vendor)" end
				row.sale:SetText(saleText)
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
-- Excessive page: listings priced far above known market value (see
-- Excessive.lua) -- informational only, no buy actions, since these are
-- exactly the auctions NOT worth buying.
--------------------------------------------------------------------------

function UI:CreateExcessivePanel()
	local panel = CreateFrame("Frame", nil, self.content)
	panel:SetAllPoints(self.content)
	self.excessivePage = panel

	local note = panel:CreateFontString("AuctionistExcessiveNoteText", "ARTWORK", "GameFontNormalSmall")
	note:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -10)
	note:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
	note:SetJustifyH("LEFT")
	note:SetText("Listings priced 4x+ above known market value -- likely one seller's outrageous ask, not a real price.")
	self.excessiveNoteText = note

	self.excessiveSortState = {}
	self:CreateColumnHeader(panel, -34, {
		{ x = 22, width = 220, text = "Item", key = "name" },
		{ x = 246, width = 30, text = "Qty", key = "count" },
		{ x = 280, width = 100, text = "Buyout", key = "buyoutTotal" },
		{ x = 384, width = 100, text = "Market Value", key = "marketValue" },
		{ x = 488, width = 80, text = "Multiple", key = "multiple" },
	}, self.excessiveSortState, function() UI:RedisplayExcessive() end)

	local scrollFrame = CreateFrame("ScrollFrame", "AuctionistExcessiveScrollFrame", panel, "FauxScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -34 - ROW_HEIGHT)
	scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -24, 0)
	scrollFrame:SetScript("OnVerticalScroll", function(scrollSelf, offset)
		FauxScrollFrame_OnVerticalScroll(scrollSelf, offset, ROW_HEIGHT, function() UI:RedisplayExcessive() end)
	end)
	self.excessiveScrollFrame = scrollFrame

	self.excessiveRows = {}
	for i = 1, VISIBLE_ROWS do
		self.excessiveRows[i] = self:CreateExcessiveRow(panel, i, scrollFrame)
	end

	panel:SetScript("OnUpdate", function(_, elapsed) UI:OnExcessivePanelUpdate(elapsed) end)
end

function UI:CreateExcessiveRow(parent, index, scrollFrame)
	local row = CreateFrame("Frame", "AuctionistExcessiveRow" .. index, parent)
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

	row.buyoutTotal = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.buyoutTotal:SetPoint("LEFT", row.count, "RIGHT", 4, 0)
	row.buyoutTotal:SetWidth(100)
	row.buyoutTotal:SetJustifyH("LEFT")

	row.marketValue = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.marketValue:SetPoint("LEFT", row.buyoutTotal, "RIGHT", 4, 0)
	row.marketValue:SetWidth(100)
	row.marketValue:SetJustifyH("LEFT")

	row.multiple = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	row.multiple:SetPoint("LEFT", row.marketValue, "RIGHT", 4, 0)
	row.multiple:SetWidth(80)
	row.multiple:SetJustifyH("LEFT")

	row:Hide()
	return row
end

function UI:OnExcessivePanelUpdate(elapsed)
	self.excessiveUpdateElapsed = (self.excessiveUpdateElapsed or 0) + elapsed
	if self.excessiveUpdateElapsed < 0.5 then return end
	self.excessiveUpdateElapsed = 0

	local count = #Excessive:GetFlagged()
	if count ~= self.lastExcessiveCount then
		self.lastExcessiveCount = count
		self:RedisplayExcessive()
	end
end

function UI:RedisplayExcessive()
	local list = Excessive:GetFlagged()

	-- Same category-dropdown display filter as the Deals tab (see
	-- UI:Redisplay) -- the dropdown lives on the Deals toolbar but restricts
	-- what any scan searches for regardless of which tab is open, so it
	-- should filter this tab's display too.
	if UI.selectedClassIndex then
		local filtered = {}
		for _, record in ipairs(list) do
			if record.scanClassIndex == UI.selectedClassIndex
				and (not UI.selectedSubclassIndex or record.scanSubclassIndex == UI.selectedSubclassIndex) then
				table.insert(filtered, record)
			end
		end
		list = filtered
	end

	local sortState = self.excessiveSortState
	if sortState.key then
		local sorted = {}
		for i, record in ipairs(list) do sorted[i] = record end
		local extractor = EXCESSIVE_SORT_EXTRACTORS[sortState.key]
		local ascending = sortState.ascending
		table.sort(sorted, function(a, b)
			return compareSortValues(extractor(a), extractor(b), ascending)
		end)
		list = sorted
	end

	FauxScrollFrame_Update(self.excessiveScrollFrame, #list, VISIBLE_ROWS, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(self.excessiveScrollFrame)

	for i = 1, VISIBLE_ROWS do
		local row = self.excessiveRows[i]
		local record = list[offset + i]

		if record then
			row.icon:SetTexture(record.iconTexture)
			row.name:SetText(record.name or "?")
			row.count:SetText(tostring(record.count))
			row.buyoutTotal:SetText(Util.FormatMoney(record.buyoutTotal))
			row.marketValue:SetText(Util.FormatMoney(record.marketValue))
			row.multiple:SetText(string.format("%.1fx", record.multiple or 0))
			row.multiple:SetTextColor(1, 0.3, 0.3)
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

--- `mode` is "buyout" (default) or "bid" -- see Buy:Start.
function UI:OpenBuyDialog(deal, mode)
	local ok, err = Auctionist.Buy:Start(deal, mode)
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
	local isBid = Buy.mode == "bid"

	if state == "LOCATING" or state == "WAIT_LOCATE" then
		dlg.text:SetText(isBid and "Locating auction (bid)..." or "Locating auction...")
		dlg.confirmButton:SetText("Confirm")
		dlg.confirmButton:Disable()
	elseif state == "ARMED" then
		local deal = Buy.deal
		local amount = isBid and Buy.armedMinBid or Buy.armedBuyout
		dlg.text:SetText((deal and deal.name or "?") .. "\n" ..
			(isBid and "Bid: " or "Buyout: ") .. Util.FormatMoney(amount) ..
			(isBid and "\n(not guaranteed -- you can be outbid)" or ""))
		dlg.confirmButton:SetText(isBid and "Place Bid" or "Confirm")
		dlg.confirmButton:Enable()
	elseif state == "BID_SENT" then
		dlg.text:SetText(isBid and "Placing bid..." or "Buying...")
		dlg.confirmButton:Disable()
	elseif state == "DONE" or state == "FAILED" then
		dlg.text:SetText(Buy.resultText or "")
		dlg.confirmButton:Disable()
	end
end

return UI
