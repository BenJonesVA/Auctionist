-- Util.lua
-- Small dependency-free helpers shared by every other module: item-link
-- parsing, safe string truncation, money formatting/rounding, and a plain
-- deep-copy for SavedVariables work. Nothing here touches AH-specific
-- globals, so this file is the cheapest to unit-test outside the client
-- (see lessonslearned.md's "Testing without a client").

local _, Auctionist = ...

local Util = {}
Auctionist.Util = Util

--------------------------------------------------------------------------
-- Item link parsing
--------------------------------------------------------------------------
-- 3.3.5 item link body (inside |H...|h) is:
--   item:itemID:enchantID:gem1:gem2:gem3:gem4:suffixID:uniqueID:linkLevel
-- We only need itemID/suffixID/uniqueID for keying the price DB and for
-- exact-match verification before a bid, but parse the rest too since it's
-- free once we've split the string.

--- Extract the |H...|h payload from a full hyperlink string.
-- @return the itemString ("item:1234:0:0:...") or nil if link is not a
--         well-formed item link.
function Util.GetItemString(link)
	if not link then return nil end
	local _, _, itemString = string.find(link, "^|c%x+|H(.+)|h%[.*%]")
	return itemString
end

--- Parse an item link (or a raw itemString) into its component fields.
-- @return itemID, enchantID, suffixID, uniqueID, linkLevel (numbers), or
--         nil if the link could not be parsed. Any individual field that
--         is blank in the string (rare, but seen with some links) comes
--         back as 0 rather than nil, so callers can compare numbers safely.
function Util.ParseItemLink(link)
	local itemString = Util.GetItemString(link) or link
	if not itemString then return nil end

	local kind, itemID, enchantID, gem1, gem2, gem3, gem4, suffixID, uniqueID, linkLevel =
		strsplit(":", itemString)

	if kind ~= "item" or not itemID then return nil end

	local function toNum(s)
		return tonumber(s) or 0
	end

	return toNum(itemID), toNum(enchantID), toNum(suffixID), toNum(uniqueID), toNum(linkLevel)
end

--- The key used everywhere in PriceDB/Deals/Buy to identify "the same item"
-- for pricing purposes. Suffix is included (a +12 agility ring is not the
-- same item as a +8 agility ring of the same base ID); uniqueID is NOT
-- included here on purpose -- that would fragment history across every
-- individually rolled item instance instead of tracking the item type.
function Util.ItemKey(itemID, suffixID)
	if not itemID then return nil end
	return tostring(itemID) .. ":" .. tostring(suffixID or 0)
end

--- Convenience: parse a link straight to its ItemKey.
function Util.ItemKeyFromLink(link)
	local itemID, _, suffixID = Util.ParseItemLink(link)
	if not itemID then return nil end
	return Util.ItemKey(itemID, suffixID)
end

--------------------------------------------------------------------------
-- UTF-8 safe string truncation
--------------------------------------------------------------------------
-- Auctionator's zc.UTF8_Truncate returns nil for a long plain-ASCII string
-- (its continuation-byte scan never finds anything to stop on), which then
-- gets handed straight to QueryAuctionItems as a nil name. This version
-- always returns a string no longer than maxBytes, ASCII or not.

--- Truncate a string to at most maxBytes bytes without splitting a
-- multi-byte UTF-8 sequence.
-- @return the (possibly unmodified) truncated string. Never nil for a
--         non-nil input.
function Util.UTF8Truncate(str, maxBytes)
	if not str then return str end
	if string.len(str) <= maxBytes then return str end

	local cut = maxBytes
	-- Continuation bytes are 10xxxxxx (0x80-0xBF). Back up while the byte
	-- at `cut` is a continuation byte, so we never split a multi-byte
	-- sequence. This terminates immediately (cut == maxBytes) for plain
	-- ASCII, unlike Auctionator's version.
	while cut > 0 do
		local b = string.byte(str, cut + 1)
		if not b or b < 0x80 or b >= 0xC0 then
			break
		end
		cut = cut - 1
	end

	return string.sub(str, 1, cut)
end

--------------------------------------------------------------------------
-- Money
--------------------------------------------------------------------------

--- Format a copper amount as "Xg Ys Zc" (only the leading non-zero units
-- through copper are shown, matching the game's own convention closely
-- enough for status text; not intended to replace MoneyFrame widgets).
function Util.FormatMoney(copper)
	copper = math.floor((copper or 0) + 0.5)
	local negative = copper < 0
	copper = math.abs(copper)

	local gold = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local bronze = copper % 100

	local parts = {}
	if gold > 0 then table.insert(parts, gold .. "g") end
	if silver > 0 then table.insert(parts, silver .. "s") end
	if bronze > 0 or #parts == 0 then table.insert(parts, bronze .. "c") end

	local text = table.concat(parts, " ")
	if negative then text = "-" .. text end
	return text
end

--------------------------------------------------------------------------
-- Table helpers
--------------------------------------------------------------------------

--- Recursive deep copy of a plain (non-cyclic) table. Used for
-- SavedVariables schema migration and for snapshotting small tables in
-- tests; not meant for hot paths.
function Util.DeepCopy(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for k, v in pairs(value) do
		copy[Util.DeepCopy(k)] = Util.DeepCopy(v)
	end
	return copy
end

--- Today's date key in the "YYYYMMDD" form used to bucket PriceDB samples.
-- Kept here (rather than inline in PriceDB) so tests can override it.
function Util.TodayKey(t)
	return date("%Y%m%d", t)
end

--------------------------------------------------------------------------
-- %s-format string matching
--------------------------------------------------------------------------

--- Build a matcher for a Blizzard "%s"-format global string (e.g.
-- ERR_AUCTION_WON_S, AUCTION_SOLD_MAIL_SUBJECT) so a runtime string can be
-- tested against it and the %s payload extracted. Defensive: returns nil
-- if `fmt` isn't a usable string, so callers can treat a missing/renamed
-- global as "this one feature is inert", never a load-time crash.
-- @return function(msg) -> matched (boolean), capture (string or nil)
function Util.BuildFormatMatcher(fmt)
	if type(fmt) ~= "string" or fmt == "" then return nil end

	local function esc(s)
		return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
	end

	local prefix, suffix = fmt:match("^(.-)%%s(.*)$")
	if not prefix then
		-- No %s placeholder at all; only an exact match is meaningful.
		return function(msg) return msg == fmt, nil end
	end

	local pattern = "^" .. esc(prefix) .. "(.-)" .. esc(suffix) .. "$"
	return function(msg)
		if type(msg) ~= "string" then return false, nil end
		local capture = msg:match(pattern)
		return capture ~= nil, capture
	end
end

return Util
