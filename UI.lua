-- UI.lua
-- Builds the "Deals" tab on the Blizzard AuctionFrame, its scrollable
-- flagged-auction list, and the small buy-confirmation dialog. No XML:
-- everything here is small enough to build with CreateFrame, which keeps
-- this file self-contained and avoids XML/Lua load-order pitfalls
-- entirely.
--
-- NOTE: the panel/dialog anchor offsets below are a reasonable starting
-- guess, not verified in-game yet -- Milestone 0's in-game test is
-- exactly "does this look right", and these are the first numbers to
-- adjust if it doesn't.

local _, Auctionist = ...
local Util = Auctionist.Util
local Deals = Auctionist.Deals

local UI = {}
Auctionist.UI = UI

local ROW_HEIGHT = 18
local VISIBLE_ROWS = 14

UI.built = false

--------------------------------------------------------------------------
-- Build (called once, on the first AUCTION_HOUSE_SHOW after
-- Blizzard_AuctionUI is confirmed loaded)
--------------------------------------------------------------------------

function UI:Build()
	if self.built then return end
	self.built = true

	self:CreateTab()
	self:CreatePanel()
	self:CreateBuyDialog()
end

function UI:CreateTab()
	local n = 1
	while _G["AuctionFrameTab" .. n] do
		n = n + 1
	end

	local tab = CreateFrame("Button", "AuctionFrameTab" .. n, AuctionFrame, "AuctionTabTemplate")
	tab:SetID(n)
	tab:SetText("Deals")
	tab:SetPoint("LEFT", _G["AuctionFrameTab" .. (n - 1)], "RIGHT", -8, 0)
	PanelTemplates_SetNumTabs(AuctionFrame, n)
	PanelTemplates_EnableTab(AuctionFrame, n)
	self.tabIndex = n

	-- Post-hook only: Blizzard's own handler already hides every native
	-- panel it doesn't recognize the id for, so we only need to show/hide
	-- ours. Tolerate either calling convention (a bare id, or the tab
	-- frame itself) since this isn't verified in-game yet.
	hooksecurefunc("AuctionFrameTab_OnClick", function(arg)
		local id = (type(arg) == "table") and arg:GetID() or arg
		if id == UI.tabIndex then
			if AuctionFrameBrowse then AuctionFrameBrowse:Hide() end
			if AuctionFrameBid then AuctionFrameBid:Hide() end
			if AuctionFrameAuctions then AuctionFrameAuctions:Hide() end
			UI.panel:Show()
		else
			UI.panel:Hide()
		end
	end)
end

function UI:CreatePanel()
	local panel = CreateFrame("Frame", "AuctionistFrame", AuctionFrame)
	panel:SetPoint("TOPLEFT", AuctionFrame, "TOPLEFT", 10, -60)
	panel:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -32, 40)
	panel:Hide()
	self.panel = panel

	local scanBtn = CreateFrame("Button", "AuctionistScanButton", panel, "UIPanelButtonTemplate")
	scanBtn:SetSize(100, 22)
	scanBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	scanBtn:SetText("Scan Now")
	scanBtn:SetScript("OnClick", function() Auctionist.Scan:StartPaged() end)
	self.scanButton = scanBtn

	local getAllBtn = CreateFrame("Button", "AuctionistGetAllButton", panel, "UIPanelButtonTemplate")
	getAllBtn:SetSize(100, 22)
	getAllBtn:SetPoint("LEFT", scanBtn, "RIGHT", 8, 0)
	getAllBtn:SetText("Full Scan")
	getAllBtn:SetScript("OnClick", function() Auctionist.Scan:StartGetAll() end)
	self.getAllButton = getAllBtn

	local status = panel:CreateFontString("AuctionistStatusText", "ARTWORK", "GameFontNormalSmall")
	status:SetPoint("LEFT", getAllBtn, "RIGHT", 12, 0)
	status:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
	status:SetJustifyH("LEFT")
	self.statusText = status

	local scrollFrame = CreateFrame("ScrollFrame", "AuctionistScrollFrame", panel, "FauxScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -34)
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
	row.discount:SetWidth(70)
	row.discount:SetJustifyH("LEFT")

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
	if scanBusy then self.scanButton:Disable() else self.scanButton:Enable() end

	local _, canGetAll = CanSendAuctionQuery()
	if scanBusy or not canGetAll then self.getAllButton:Disable() else self.getAllButton:Enable() end

	local flaggedCount = #Deals:GetFlagged()
	if flaggedCount ~= self.lastFlaggedCount then
		self.lastFlaggedCount = flaggedCount
		self:Redisplay()
	end
end

function UI:Redisplay()
	local flagged = Deals:GetFlagged()
	FauxScrollFrame_Update(self.scrollFrame, #flagged, VISIBLE_ROWS, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(self.scrollFrame)

	for i = 1, VISIBLE_ROWS do
		local row = self.rows[i]
		local deal = flagged[offset + i]

		if deal then
			row.deal = deal
			row.icon:SetTexture(deal.iconTexture)
			row.name:SetText(deal.name or "?")
			row.count:SetText(tostring(deal.count))
			row.price:SetText(Util.FormatMoney(deal.buyoutTotal))
			if deal.discountPct then
				row.discount:SetText(string.format("%d%% off", math.floor(deal.discountPct * 100 + 0.5)))
			else
				row.discount:SetText("vendor")
			end
			row:Show()
		else
			row.deal = nil
			row:Hide()
		end
	end
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
