-- Core.lua
-- Loads last. Waits for Blizzard_AuctionUI, builds the UI lazily on first
-- AUCTION_HOUSE_SHOW, drives Scan/Buy from one master OnUpdate frame, and
-- dispatches the AH events both engines depend on. Also owns the slash
-- commands, which are the fastest way to exercise Scan/PriceDB before the
-- UI buttons are confirmed working in-game (see the plan's Milestone 1).

local addonName, Auctionist = ...
local PriceDB = Auctionist.PriceDB
local Scan = Auctionist.Scan
local Buy = Auctionist.Buy

local Core = CreateFrame("Frame", "AuctionistCoreFrame")
Auctionist.Core = Core

Core.blizzardAHLoaded = false

Core:RegisterEvent("ADDON_LOADED")
Core:RegisterEvent("PLAYER_LOGIN")
Core:RegisterEvent("AUCTION_HOUSE_SHOW")
Core:RegisterEvent("AUCTION_HOUSE_CLOSED")
Core:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
Core:RegisterEvent("CHAT_MSG_SYSTEM")
Core:RegisterEvent("UI_ERROR_MESSAGE")

local function TryBuildUI()
	if Core.blizzardAHLoaded and Auctionist.UI and not Auctionist.UI.built then
		Auctionist.UI:Build()
	end
end

Core:SetScript("OnEvent", function(self, event, arg1, ...)
	if event == "ADDON_LOADED" then
		if arg1 == addonName then
			PriceDB:Init()
		elseif arg1 and string.lower(arg1) == "blizzard_auctionui" then
			Core.blizzardAHLoaded = true
			TryBuildUI()
		end
	elseif event == "PLAYER_LOGIN" then
		if IsAddOnLoaded("Blizzard_AuctionUI") then
			Core.blizzardAHLoaded = true
		end
	elseif event == "AUCTION_HOUSE_SHOW" then
		TryBuildUI()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		Scan:Cancel()
		Buy:OnAuctionHouseClosed()
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
	end
end)

Core:SetScript("OnUpdate", function(self, elapsed)
	Scan:OnUpdate(elapsed)
	Buy:OnUpdate(elapsed)
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
	else
		print("Auctionist commands: /auctionist scan | fullscan | dbstats | status")
	end
end
