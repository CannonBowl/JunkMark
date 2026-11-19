-- JunkMark: working with other addons that deal in junk.
--
-- JunkMark's own selling never touches a favorite, and its click blocker stops the
-- player selling one by hand. Neither stops another addon. This file deals with the
-- ones it knows, in one of three ways:
--
--   * Guarded. The addon asks one function of its own whether to sell an item, and
--     that function can be reached. JunkMark wraps it so it answers "no" for a
--     favorite, and otherwise answers as before. Nothing is written to that addon's
--     saved settings, and JunkMark's junk marks are not passed to it: JunkMark sells
--     its own junk.
--   * Asked. The addon cannot be stopped, but it will say whether it counts an item
--     as junk. JunkMark asks about each new favorite and warns if the answer is yes.
--   * Warned about. The addon sells every gray item through code that cannot be
--     reached or asked. JunkMark says so when a gray item is made a favorite.
--
-- The game's own Sell All Junk button is not in any of these lists: since 0.9.0
-- JunkMark.lua takes that button over, so a click runs JunkMark's sale. Addons that
-- call the game's sell-all-junk function themselves are still only warned about.
--
-- Last in the file, JunkMark offers itself to Baganator as a source of what is junk.
--
-- /jm check reports what was found. Each addon was read at the version named with
-- it; everything touched is checked for first, so a version that has moved things is
-- skipped rather than raising errors. None of it has been run in the game.

local _, ns = ...;

local guarded = {}; -- one /jm check line for each addon whose test was wrapped

-- Replaces owner[method] with a function that is handed the original first.
-- Returns whether there was such a method to replace.
local function Wrap(owner, method, replacement)
	if type(owner) ~= "table" or type(owner[method]) ~= "function" then
		return false;
	end
	local original = owner[method];
	owner[method] = function(...)
		return replacement(original, ...);
	end;
	return true;
end

-- Addons built on the Ace libraries keep their table private, but can be looked up
-- by name.
local function GetAceAddon(name)
	local ace = LibStub and LibStub("AceAddon-3.0", true);
	return ace and ace:GetAddon(name, true) or nil;
end

local function IsAddOnLoaded(name)
	return C_AddOns ~= nil and C_AddOns.IsAddOnLoaded ~= nil and C_AddOns.IsAddOnLoaded(name) == true;
end

local function IsFavoriteSlot(bag, slot)
	return bag ~= nil and slot ~= nil and ns.GetSlotMarkKind(bag, slot) == ns.KIND_FAVORITE;
end

--------------------------------------------------------------------------------
-- Guarded
--------------------------------------------------------------------------------

-- EllesmereUI, read at 9.8.9. Its Bags module marks junk by item ID, account-wide,
-- and counts unmarked gray items as junk too. Its Sell Junk button, its automatic
-- selling while the Junk Marker is on, and the marked items in its Junk Items window
-- all ask EUI_CategoryManager:IsJunk(itemID, quality). That call carries no bag slot,
-- so the guard works by item ID: no copy is junk while one copy is a favorite.
local function GuardEllesmere()
	if Wrap(EUI_CategoryManager, "IsJunk", function(original, self, itemID, ...)
		if ns.IsItemIDFavorite(itemID) then
			return false;
		end
		return original(self, itemID, ...);
	end) then
		-- Its Junk Items window lists by quality first, without asking IsJunk, so a
		-- gray favorite can still appear there. That window deletes only on a Ctrl-click.
		guarded[#guarded + 1] = "EllesmereUI's junk marker: guarded. Its Sell Junk button and automatic selling skip an item while a copy of it is a favorite. Its Junk Items window can still list a gray favorite.";
	end
end

-- RestedXP Guides, read at 4.11.36. Its inventory manager treats gray items, and
-- items the player marks, as junk. With its options on it sells them at a vendor and
-- deletes the cheapest when the bags are full. Both ask
-- inventoryManager:IsJunk(id, bag, slot).
local function GuardRestedXP()
	local rxp = GetAceAddon("RXPGuides");
	if Wrap(rxp and rxp.inventoryManager, "IsJunk", function(original, self, id, bag, slot, ...)
		if bag and slot then
			if IsFavoriteSlot(bag, slot) then
				return false;
			end
		elseif ns.IsItemIDFavorite(id) then
			return false;
		end
		return original(self, id, bag, slot, ...);
	end) then
		guarded[#guarded + 1] = "RestedXP's inventory manager: guarded. It will not sell or delete a favorite.";
	end
end

-- Scrap, read at 12.1.10. Selling and destroying both walk Scrap:IterateJunk, which
-- asks Scrap:IsJunk(id, bag, slot) for each slot. Calls without a slot are Scrap's own
-- list editing and are left alone.
local function GuardScrap()
	if Wrap(Scrap, "IsJunk", function(original, self, id, bag, slot, ...)
		if IsFavoriteSlot(bag, slot) then
			return false;
		end
		return original(self, id, bag, slot, ...);
	end) then
		guarded[#guarded + 1] = "Scrap: guarded. It will not sell or destroy a favorite.";
	end
end

-- BetterBags, read at the development version of 2026-11-18. Every sale it makes goes
-- through its Seller module, which asks Seller:StillThere(data, forSale) just before
-- sending each item and skips the item when the answer is nil.
local function GuardBetterBags()
	local addon = GetAceAddon("BetterBags");
	local seller = type(addon) == "table" and type(addon.GetModule) == "function" and addon:GetModule("Seller", true) or nil;
	if Wrap(seller, "StillThere", function(original, self, data, forSale, ...)
		if forSale and type(data) == "table" and IsFavoriteSlot(data.bagid or data.bag, data.slotid or data.slot) then
			return nil;
		end
		return original(self, data, forSale, ...);
	end) then
		guarded[#guarded + 1] = "BetterBags' selling: guarded. It will not sell a favorite.";
	end
end

-- SellJunk. Two versions are about. One asks SellJunk:CheckItemIsJunk(link, bag, slot)
-- (as Baganator 864 calls it). The other, read in the Beast-Masters copy of
-- 2026-11-08, sells an item when it is gray and not an exception, or not gray and an
-- exception, and asks SellJunk:isException(item) with the item's container info. That
-- carries no bag slot, so there the guard works by item ID, and answers whichever way
-- keeps the item: a gray favorite is an exception, another favorite is not.
local function GuardSellJunk()
	local done = Wrap(SellJunk, "CheckItemIsJunk", function(original, self, link, bag, slot, ...)
		if IsFavoriteSlot(bag, slot) then
			return false;
		end
		return original(self, link, bag, slot, ...);
	end);
	done = Wrap(SellJunk, "isException", function(original, self, item, ...)
		if type(item) == "table" and ns.IsItemIDFavorite(item.itemID) then
			return item.quality == Enum.ItemQuality.Poor;
		end
		return original(self, item, ...);
	end) or done;
	if done then
		guarded[#guarded + 1] = "SellJunk: guarded. It will not sell or destroy a favorite.";
	end
end

--------------------------------------------------------------------------------
-- Asked: addons that cannot be stopped but will say what they count as junk
--------------------------------------------------------------------------------

local RULE_SELLERS = {
	{
		-- Read at 3.5.1. Its seller is private; DejunkApi is its public table.
		name = "Dejunk",
		advice = "Add the item to Dejunk's exclusions.",
		IsPresent = function()
			return type(DejunkApi) == "table" and type(DejunkApi.IsJunk) == "function";
		end,
		CountsAsJunk = function(bag, slot)
			return DejunkApi:IsJunk(bag, slot) == true;
		end,
	},
	{
		-- Read at 6.14.0. Vendor.EvaluateItem returns 0 for an item it will leave alone.
		name = "Vendor",
		advice = "Add the item to Vendor's Keep list.",
		IsPresent = function()
			return type(Vendor) == "table" and type(Vendor.EvaluateItem) == "function";
		end,
		CountsAsJunk = function(bag, slot)
			return (Vendor.EvaluateItem(bag, slot) or 0) ~= 0;
		end,
	},
};

-- Protected, because the answer comes from another addon's code.
local function CountsAsJunk(seller, bag, slot)
	local ok, result = pcall(seller.CountsAsJunk, bag, slot);
	return ok and result == true;
end

--------------------------------------------------------------------------------
-- Warned about: sellers of every gray item
--------------------------------------------------------------------------------

local GRAY_SELLERS = {
	{
		-- Read at version 1.60.32. Its selling loop is a local function.
		name = "Leatrix Plus",
		advice = "Turn off \"Sell junk automatically\" in Leatrix Plus, or add the item to its exclusions.",
		IsActive = function()
			return type(LeaPlusDB) == "table" and LeaPlusDB["AutoSellJunk"] == "On";
		end,
	},
	{
		-- Read at version 9.8.9. With its Bags module's Junk Marker on, automatic
		-- selling goes through the junk test guarded above. Otherwise it calls the
		-- game's own "sell all junk".
		name = "EllesmereUI's Auto Sell Junk",
		advice = "Turn off Auto Sell Junk in EllesmereUI's Quality of Life options, or turn on the Junk Icon in its Bags options so that it sells through its junk marker, which JunkMark guards.",
		IsActive = function()
			if type(EllesmereUIDB) ~= "table" or EllesmereUIDB.autoSellJunk == false or not IsAddOnLoaded("EllesmereUIQoL") then
				return false;
			end
			local bags, manager = EUI_Bags, EUI_CategoryManager;
			local throughMarker = type(bags) == "table" and bags.SellJunk ~= nil
				and type(manager) == "table" and type(manager.IsJunkMarkerEnabled) == "function"
				and manager:IsJunkMarkerEnabled();
			return not throughMarker;
		end,
	},
	{
		-- Read in Cartas's copy of 2026-11-09. Its table is private. It sells gray
		-- items unless that is switched off or the item is unmarked in Peddler.
		name = "Peddler",
		advice = "Unmark the item in Peddler, or turn off its automatic selling of gray items.",
		IsActive = function()
			return IsAddOnLoaded("Peddler") and AutoSellGreyItems ~= false;
		end,
	},
};

local warned = {}; -- gray seller name -> true once warned about this session

local function OnFavorited(bag, slot, info)
	for _, seller in ipairs(RULE_SELLERS) do
		if seller.IsPresent() and CountsAsJunk(seller, bag, slot) then
			ns.Print(string.format("|cffff4040%s counts this item as junk, and JunkMark cannot stop it selling or destroying it.|r %s", seller.name, seller.advice));
		end
	end

	-- A gray item with a vendor price is the only kind the gray sellers take.
	if not info or info.quality ~= Enum.ItemQuality.Poor or info.hasNoValue then
		return;
	end
	for _, seller in ipairs(GRAY_SELLERS) do
		if not warned[seller.name] and seller.IsActive() then
			warned[seller.name] = true;
			ns.Print(string.format("|cffff4040%s sells every gray item, and JunkMark cannot stop it.|r This favorite is not safe from it. %s", seller.name, seller.advice));
		end
	end
end

--------------------------------------------------------------------------------
-- Baganator's junk source (read at version 864, checked against 865)
--
-- Baganator lets another addon say which items are junk. Its junk category, its
-- "junk" search word, its sort order and its own junk coin then follow that addon.
-- JunkMark's answer is exactly what JunkMark itself counts as junk: what the player
-- marked, plus gray items when junk is automatic (/jm mode), and never a favorite or
-- an item set to not junk. So there is one idea of junk, JunkMark's, and Baganator's
-- own gray-item rule no longer runs beside it. (0.7.0 answered "junk" for every
-- unmarked gray whatever the mode, which the player could not clear.)
--
-- Registering makes JunkMark Baganator's junk source unless the player has picked
-- another: Baganator itself switches its "Junk detection" setting (General tab of its
-- settings; API/Main.lua, AutoSet) to a newly registered source when the current
-- choice is not a registered one, and its default is not.
--
-- JunkMark still draws its own marks in Baganator's window, the same way as in any
-- other bag addon. Baganator's own junk coin would then sit on the same items and say
-- the same thing, so while JunkMark is the source that coin is made invisible
-- (ns.HidesJunkCoin, used by JunkMark.lua): one coin for junk, JunkMark's. A junk
-- source cannot ask Baganator not to draw the coin, which is the player's "Icon
-- Corners" setting there, and JunkMark does not write to that setting. If the player
-- picks another junk source in Baganator, its coin shows again.
--------------------------------------------------------------------------------

local BAGANATOR_ID = "junkmark";
local baganator; -- Baganator.API once registered

local function OfferJunkToBaganator()
	local api = Baganator and Baganator.API;
	if type(api) ~= "table" or type(api.RegisterJunkPlugin) ~= "function" or type(api.RequestItemButtonsRefresh) ~= "function" then
		return;
	end
	baganator = api;
	api.RegisterJunkPlugin("JunkMark", BAGANATOR_ID, function(bag, slot)
		return ns.GetSlotMarkKind(bag, slot) == ns.KIND_JUNK;
	end);
	ns.On("changed", function()
		api.RequestItemButtonsRefresh();
	end);
end

-- Whether another addon's own junk coin on this item button only repeats JunkMark's
-- verdict, and so should not be seen. True for a Baganator item button (they carry a
-- BGR table, ItemViewCommon/ItemButton.lua) while JunkMark is Baganator's junk source.
function ns.HidesJunkCoin(button)
	if not baganator or type(button.BGR) ~= "table" then
		return false;
	end
	return baganator.IsJunkPluginActive == nil or baganator.IsJunkPluginActive(BAGANATOR_ID) == true;
end

--------------------------------------------------------------------------------

ns.On("login", function()
	GuardEllesmere();
	GuardRestedXP();
	GuardScrap();
	GuardBetterBags();
	GuardSellJunk();
	OfferJunkToBaganator();
end);

ns.On("favorited", OnFavorited);

ns.checks[#ns.checks + 1] = function(lines)
	if baganator then
		if baganator.IsJunkPluginActive and not baganator.IsJunkPluginActive(BAGANATOR_ID) then
			lines[#lines + 1] = "Baganator: its junk coin, search and junk category follow another junk source, not JunkMark. That is the Junk detection setting on the General tab of Baganator's settings.";
		else
			lines[#lines + 1] = "Baganator: its junk category, search, sort and junk coin follow JunkMark, whichever way /jm mode is set. Baganator's own junk coin is hidden while that is so, since JunkMark's mark already says it.";
		end
	end

	local found = #guarded;
	for _, line in ipairs(guarded) do
		lines[#lines + 1] = line;
	end
	for _, seller in ipairs(RULE_SELLERS) do
		if seller.IsPresent() then
			found = found + 1;
			local count = 0;
			ns.ForEachFavorite(function(bag, slot)
				if CountsAsJunk(seller, bag, slot) then
					count = count + 1;
				end
			end);
			if count > 0 then
				lines[#lines + 1] = string.format("|cffff4040%s|r cannot be guarded, and counts %d of your favorites as junk right now. %s", seller.name, count, seller.advice);
			else
				lines[#lines + 1] = string.format("%s: cannot be guarded, but counts none of your favorites as junk right now.", seller.name);
			end
		end
	end
	for _, seller in ipairs(GRAY_SELLERS) do
		if seller.IsActive() then
			found = found + 1;
			lines[#lines + 1] = string.format("|cffff4040%s|r sells every gray item, favorites included, and JunkMark cannot stop it. %s", seller.name, seller.advice);
		end
	end
	if found == 0 then
		lines[#lines + 1] = "Sellers: no other addon that sells junk was found.";
	end
end;
