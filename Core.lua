-- Core.lua
-- Loads last. Builds Auctionist's standalone window at PLAYER_LOGIN (it no
-- longer needs Blizzard_AuctionUI at all -- see UI.lua), drives Scan/Buy
-- from one master OnUpdate frame, and dispatches the AH events both
-- engines depend on. Also owns the slash commands, which are the fastest
-- way to exercise Scan/PriceDB before the UI buttons are confirmed
-- working in-game (see the plan's Milestone 1).

local addonName, Auctionist = ...
local Util = Auctionist.Util
local PriceDB = Auctionist.PriceDB
local Scan = Auctionist.Scan
local Buy = Auctionist.Buy
local Ledger = Auctionist.Ledger
local UI = Auctionist.UI

local Core = CreateFrame("Frame", "AuctionistCoreFrame")
Auctionist.Core = Core

Core:RegisterEvent("ADDON_LOADED")
Core:RegisterEvent("PLAYER_LOGIN")
Core:RegisterEvent("AUCTION_HOUSE_SHOW")
Core:RegisterEvent("AUCTION_HOUSE_CLOSED")
Core:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
Core:RegisterEvent("CHAT_MSG_SYSTEM")
Core:RegisterEvent("UI_ERROR_MESSAGE")
Core:RegisterEvent("MAIL_SHOW")
Core:RegisterEvent("MAIL_CLOSED")
Core:RegisterEvent("MAIL_INBOX_UPDATE")

Core:SetScript("OnEvent", function(self, event, arg1, ...)
	if event == "ADDON_LOADED" then
		if arg1 == addonName then
			PriceDB:Init()
			Ledger:Init()
		end
	elseif event == "PLAYER_LOGIN" then
		UI:Build()
	elseif event == "AUCTION_HOUSE_SHOW" then
		UI:Show()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		Scan:Cancel()
		Buy:OnAuctionHouseClosed()
		UI:Hide()
	elseif event == "AUCTION_ITEM_LIST_UPDATE" then
		-- Both engines check their own state before acting, so it's safe
		-- to notify both unconditionally rather than tracking which one
		-- "owns" the current query separately from the Arbiter itself.
		Scan:OnAuctionUpdate()
		Buy:OnAuctionUpdate()
	elseif event == "CHAT_MSG_SYSTEM" then
		Buy:OnChatMessage(arg1)
	elseif event == "UI_ERROR_MESSAGE" then
		Buy:OnUIErrorMessage(arg1)
	elseif event == "MAIL_SHOW" then
		UI:EnsureMailboxButton()
		Ledger:OnMailShow()
	elseif event == "MAIL_CLOSED" then
		Ledger:OnMailClosed()
	elseif event == "MAIL_INBOX_UPDATE" then
		Ledger:ScanMailbox()
	end
end)

Core:SetScript("OnUpdate", function(self, elapsed)
	Scan:OnUpdate(elapsed)
	Buy:OnUpdate(elapsed)
	PriceDB:OnUpdate(elapsed)
	Ledger:OnUpdate(elapsed)
end)

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

SLASH_AUCTIONIST1 = "/auctionist"
SLASH_AUCTIONIST2 = "/aist"

SlashCmdList["AUCTIONIST"] = function(msg)
	msg = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))

	if msg == "scan" then
		local ok, err = Scan:StartPaged()
		if not ok then print("Auctionist: " .. err) end
	elseif msg == "fullscan" then
		local ok, err = Scan:StartGetAll()
		if not ok then print("Auctionist: " .. err) end
	elseif msg == "dbstats" then
		local stats = Scan.stats or {}
		print(string.format(
			"Auctionist: last scan - items staged=%d, rows accepted=%d, rows skipped=%d, pages=%d",
			stats.itemsStaged or 0, stats.rowsAccepted or 0, stats.rowsSkipped or 0, stats.pagesProcessed or 0))
	elseif msg == "status" then
		print("Auctionist: " .. Scan:GetStatusText())
	elseif msg == "stop" then
		local ok, err = Scan:Stop()
		if not ok then print("Auctionist: " .. err) end
	elseif msg == "pnl" then
		local s = Ledger:Summary(PriceDB:ScopeKey())
		print(string.format(
			"Auctionist P&L: spent=%s revenue=%s profit=%s sold=%d unsold=%d (%s tied up)",
			Util.FormatMoney(s.totalSpent), Util.FormatMoney(s.totalRevenue), Util.FormatMoney(s.totalProfit),
			s.soldCount, s.unsoldCount, Util.FormatMoney(s.unsoldCost)))
	elseif msg == "ui" or msg == "show" then
		UI:Toggle()
	else
		print("Auctionist commands: /auctionist scan | fullscan | stop | dbstats | status | pnl | ui")
	end
end
