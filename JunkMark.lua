-- JunkMark: Diablo 4 style item marking for bags.
--
-- Hover a bag item and press Space to cycle its mark:
--   junk     - disposed of in bulk (see below)
--   favorite - protected: it cannot be sold while marked
--   (none)
--
-- What happens to junk depends on the character and the item:
--   * if the character knows a profession ability that uses the item up (see ACTIONS;
--     currently just Disenchant), the item joins a queue and is processed one item
--     per click or key press;
--   * otherwise it is sold at a vendor with one click.
--
-- Marks are stored per item instance (item GUID), not per item ID, so marking one
-- green sword does not mark the next one that drops. A mark follows the item when
-- bags are sorted and survives relogging.

-- The addon's folder name, as the game passes it to every file in the addon.
local addonName = ...;

BINDING_HEADER_JUNKMARK = "JunkMark";
BINDING_NAME_JUNKMARK_TOGGLE = "Cycle mark on hovered item";
_G["BINDING_NAME_CLICK JunkMarkProcessButton:LeftButton"] = "Process next queued item";

local CHAT_PREFIX = "|cffffd100JunkMark:|r ";

-- The key that cycles the mark of the hovered bag item. It is only taken over while
-- the cursor is on a bag item; everywhere else it keeps its normal binding (jump).
local HOVER_KEY = "SPACE";
local HOVER_KEY_NAME = "Space";

-- Seconds between sales. The server drops sell requests that arrive much faster than this.
local SELL_INTERVAL = 0.2;
-- After the last sale is sent, how many more intervals to wait for the items to
-- actually leave the bags before reporting the ones that didn't.
local SELL_SETTLE_TICKS = 5;

-- Version of the JunkMarkDB layout. Raise it, and add a step to
-- InitializeSavedVariables, whenever the saved format changes.
--   1: marked[guid] = true (junk only)
--   2: marked[guid] = { kind = "junk" | "disenchant", order = n }
--   3: marked[guid] = { kind = "junk" | "favorite", order = n, sellOnly = bool }
local SCHEMA_VERSION = 3;

local KIND_JUNK = "junk";
local KIND_FAVORITE = "favorite";

-- Item links whose tooltip says the item cannot be disenchanted. Only a "yes" is
-- remembered: it never changes, while a "no" read before the client has the item's
-- data could be wrong.
local disenchantRefused = {};

-- Whether the game itself says the item cannot be disenchanted. Some gear of the
-- right quality and type is refused (quest rewards kept for a quest, special items),
-- and only the game knows which: it says so with a line in the item's tooltip.
local function TooltipRefusesDisenchant(info, bag, slot)
	local refusal = ITEM_DISENCHANT_NOT_DISENCHANTABLE;
	if not refusal or not C_TooltipInfo or not bag or not slot then
		return false;
	end
	if disenchantRefused[info.hyperlink] then
		return true;
	end
	local data = C_TooltipInfo.GetBagItem(bag, slot);
	for _, line in ipairs(data and data.lines or {}) do
		if line.leftText == refusal then
			disenchantRefused[info.hyperlink] = true;
			return true;
		end
	end
	return false;
end

-- Uncommon-to-epic weapons and armor that the game does not refuse outright. The
-- game still has the final say (skill level), so a queued item can fail on the day.
local function IsDisenchantable(info, bag, slot)
	if not info.quality then
		return false;
	end
	if info.quality < Enum.ItemQuality.Uncommon or info.quality > Enum.ItemQuality.Epic then
		return false;
	end
	local classID = select(6, C_Item.GetItemInfoInstant(info.hyperlink));
	if classID ~= Enum.ItemClass.Weapon and classID ~= Enum.ItemClass.Armor then
		return false;
	end
	return not TooltipRefusesDisenchant(info, bag, slot);
end

-- Profession abilities that are cast on a bag item and use it up. Junk is routed to
-- the first entry whose spell the character knows and whose IsEligible accepts the
-- item (it receives the slot's C_Container.GetContainerItemInfo table).
--
-- finalRefusals names the game's own error strings that mean "never, for this kind of
-- item". Nothing the client exposes says in advance which gear that is: some carries
-- a tooltip line, some (quest gear such as the Enchanted Moonstalker Cloak) carries
-- nothing. So when a queued item draws one of these errors, JunkMark remembers the
-- item's ID and stops offering the ability for it (see "Refused items").
--
-- Forever has the original nine professions, and Disenchant is the only one of
-- their abilities that works this way. Adding another is one more entry here.
local ACTIONS = {
	{
		label = "Disenchant",
		spellID = 13262,
		fallbackIcon = [[Interface\Icons\INV_Enchant_Disenchant]],
		tint = { 0.35, 0.1, 0.55 },
		IsEligible = IsDisenchantable,
		-- Names of the game's own strings, so the match holds in every language.
		finalRefusals = { "SPELL_FAILED_CANT_BE_DISENCHANTED" },
		-- What this client actually answered for the Enchanted Moonstalker Cloak
		-- (2026-11-16, enUS): a generic "can't target that item", error type 414. Its
		-- string's name is not known yet, so it is matched as English text for now;
		-- lastRefusal.globals records the name the next time it is seen.
		finalRefusalTexts = { "That item is not a valid target." },
	},
};

-- GetDisposal result for junk that goes to a vendor.
local DISPOSAL_SELL = "sell";

local db; -- JunkMarkDB, assigned on ADDON_LOADED
local overlays = setmetatable({}, { __mode = "k" }); -- bag item button -> textures
local blockers = setmetatable({}, { __mode = "k" }); -- bag item button -> click blocker
local blockerOwners = setmetatable({}, { __mode = "k" }); -- click blocker -> bag item button
local hookedButtons = setmetatable({}, { __mode = "k" }); -- every bag item button seen so far
local scratchLocation = ItemLocation:CreateEmpty();
local merchantOpen = false;
local sellRun; -- the sale in progress: { queue, sent, settleTicks }
local sellTicker;
local sellButton;
local queuePanel, processButton;
local queuePanelDirty = false;

local UpdateSellButton, UpdateQueuePanel, CycleSlot;

local function Print(message)
	print(CHAT_PREFIX .. message);
end

local function Plural(count)
	return count == 1 and "" or "s";
end

local function GetSlotGUID(bag, slot)
	if not bag or not slot then
		return nil;
	end
	scratchLocation:SetBagAndSlot(bag, slot);
	if C_Item.DoesItemExist(scratchLocation) then
		return C_Item.GetItemGUID(scratchLocation);
	end
	return nil;
end

local function ForEachBagItem(callback)
	for bag = 0, (NUM_TOTAL_BAG_FRAMES or 4) do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local guid = GetSlotGUID(bag, slot);
			if guid then
				callback(bag, slot, guid);
			end
		end
	end
end

-- The set of item GUIDs currently in the bags.
local function GetBagGUIDs()
	local present = {};
	ForEachBagItem(function(_, _, guid)
		present[guid] = true;
	end);
	return present;
end

local function FormatMoney(copper)
	return C_CurrencyInfo.GetCoinTextureString(copper);
end

local function IsActionKnown(action)
	return C_SpellBook.IsSpellKnown(action.spellID);
end

local function GetActionIcon(action)
	return C_Spell.GetSpellTexture(action.spellID) or action.fallbackIcon;
end

-- The profession action this character can use on the item, if any.
-- Whether the game has already refused this ability for this kind of item.
local function IsRefused(action, itemID)
	local refused = db and db.refused and db.refused[action.spellID];
	return refused ~= nil and itemID ~= nil and refused[itemID] == true;
end

local function FindAction(info, bag, slot)
	for _, action in ipairs(ACTIONS) do
		if IsActionKnown(action) and not IsRefused(action, info.itemID) and action.IsEligible(info, bag, slot) then
			return action;
		end
	end
	return nil;
end

-- What will happen to a junk-marked item: an ACTIONS entry (it waits in the
-- profession queue), DISPOSAL_SELL, or nil if nothing can be done with it.
-- mark.sellOnly is set when the player sends a queued item to the vendor instead.
local function GetDisposal(mark, info, bag, slot)
	if not mark or mark.kind ~= KIND_JUNK or not info then
		return nil;
	end
	local action = not mark.sellOnly and FindAction(info, bag, slot) or nil;
	if action then
		return action;
	end
	if not info.hasNoValue then
		return DISPOSAL_SELL;
	end
	return nil;
end

--------------------------------------------------------------------------------
-- Hover key
--
-- An override binding hands the hover key to JunkMark only while the cursor is on a
-- bag item. Bindings cannot change during combat, so the key is released when combat
-- starts and marking with it is unavailable until combat ends.
--------------------------------------------------------------------------------

local hoverOwner = CreateFrame("Frame");
local hoverFrame; -- the bag item button (or its blocker) under the cursor
local hoverBound = false;

-- The bag item button a hovered frame stands for: itself, or the one under a blocker.
local function GetItemButton(frame)
	return blockerOwners[frame] or frame;
end

-- Takes the key while the cursor is on a slot that holds an item, and releases it
-- otherwise. Also run on bag updates, since the slot under a resting cursor can
-- empty (the item was sold) or fill (an item was looted into it).
local function ApplyHoverKey()
	local want = false;
	if hoverFrame then
		local button = GetItemButton(hoverFrame);
		want = GetSlotGUID(button:GetBagID(), button:GetID()) ~= nil;
	end
	if want == hoverBound or InCombatLockdown() then
		return;
	end
	if want then
		SetOverrideBinding(hoverOwner, true, HOVER_KEY, "JUNKMARK_TOGGLE");
	else
		ClearOverrideBindings(hoverOwner);
	end
	hoverBound = want;
end

local function HoverEnter(frame)
	hoverFrame = frame;
	ApplyHoverKey();
end

-- Compares against the current frame because, when one frame replaces another under
-- the cursor, the new frame's OnEnter can arrive before the old frame's OnLeave.
local function HoverLeave(frame)
	if hoverFrame == frame then
		hoverFrame = nil;
		ApplyHoverKey();
	end
end

--------------------------------------------------------------------------------
-- Favorite protection
--
-- An addon cannot veto the default UI's sale of an item, so while a vendor is open
-- each favorite is covered by an invisible button that swallows the clicks and drags
-- that would sell it.
--------------------------------------------------------------------------------

local function WarnFavorite()
	UIErrorsFrame:AddMessage(string.format("That item is a favorite. Hover it and press %s to change its mark.", HOVER_KEY_NAME), 1.0, 0.1, 0.1, 1.0);
end

local function CreateBlocker(button)
	local blocker = CreateFrame("Button", nil, button);
	blocker:SetAllPoints(button);
	blocker:SetFrameLevel(button:GetFrameLevel() + 10);
	blocker:RegisterForClicks("AnyUp");
	blocker:RegisterForDrag("LeftButton");
	blockerOwners[blocker] = button;
	blocker:SetScript("OnClick", WarnFavorite);
	blocker:SetScript("OnDragStart", WarnFavorite);
	blocker:SetScript("OnEnter", function(self)
		-- The blocker hides the item button from the mouse, so show its tooltip here.
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
		GameTooltip:SetBagItem(button:GetBagID(), button:GetID());
		GameTooltip:AddLine("Favorite: can't be sold", 1, 0.82, 0);
		GameTooltip:Show();
		HoverEnter(self);
	end);
	blocker:SetScript("OnLeave", function(self)
		GameTooltip_Hide();
		HoverLeave(self);
	end);
	blocker:SetScript("OnHide", HoverLeave);
	blockers[button] = blocker;
	return blocker;
end

local function UpdateBlocker(button, protect)
	local blocker = blockers[button];
	if not blocker then
		if not protect then
			return;
		end
		blocker = CreateBlocker(button);
	end
	blocker:SetShown(protect);
end

--------------------------------------------------------------------------------
-- Bag overlays
--------------------------------------------------------------------------------

-- Where the mark icon sits on an item button: db.corner, changed with /jm corner.
-- It is a setting because bag addons put things of their own in the corners; both
-- Baganator and EllesmereUIBags write the item level top-left, where the icon used to be.
local CORNERS = {
	topleft = { "TOPLEFT", 2, -2 },
	topright = { "TOPRIGHT", -2, -2 },
	bottomleft = { "BOTTOMLEFT", 2, 2 },
	bottomright = { "BOTTOMRIGHT", -2, 2 },
};
local CORNER_NAMES = "topleft, topright, bottomleft, bottomright";
local DEFAULT_CORNER = "bottomright";

local function AnchorMarkIcons(overlay)
	local corner = CORNERS[db.corner] or CORNERS[DEFAULT_CORNER];
	for _, icon in ipairs({ overlay.coin, overlay.action, overlay.star }) do
		icon:ClearAllPoints();
		icon:SetPoint(corner[1], corner[2], corner[3]);
	end
end

local function CreateOverlay(button)
	local overlay = {};

	-- The lowest ARTWORK sublevel: above the item icon (BORDER), below the stack
	-- count (ARTWORK) and quality border (OVERLAY), which stay readable when dimmed.
	overlay.shade = button:CreateTexture(nil, "ARTWORK", nil, -8);
	overlay.shade:SetAllPoints(button);

	-- The mark icons are in ARTWORK as well, above the shade. The stack count is text
	-- in the same layer and text draws over textures, so with the icon in the count's
	-- corner (bottom right) the number stays readable on top of it.

	-- Junk bound for a vendor: the coin the default UI shows on gray items.
	overlay.coin = button:CreateTexture(nil, "ARTWORK", nil, 1);
	overlay.coin:SetAtlas("bags-junkcoin", true);

	-- Junk bound for a profession: that ability's icon.
	overlay.action = button:CreateTexture(nil, "ARTWORK", nil, 1);
	overlay.action:SetSize(16, 16);

	overlay.star = button:CreateTexture(nil, "ARTWORK", nil, 1);
	overlay.star:SetAtlas("auctionhouse-icon-favorite");
	overlay.star:SetSize(16, 16);

	AnchorMarkIcons(overlay);
	overlays[button] = overlay;
	return overlay;
end

local function UpdateButtonOverlay(button)
	local bag, slot = button:GetBagID(), button:GetID();
	local guid = GetSlotGUID(bag, slot);
	local mark = guid and db.marked[guid];
	local isJunk = mark ~= nil and mark.kind == KIND_JUNK;
	local isFavorite = mark ~= nil and mark.kind == KIND_FAVORITE;

	UpdateBlocker(button, isFavorite and merchantOpen);

	local overlay = overlays[button];
	if not overlay then
		if not isJunk and not isFavorite then
			return;
		end
		overlay = CreateOverlay(button);
	end

	local disposal = isJunk and GetDisposal(mark, C_Container.GetContainerItemInfo(bag, slot), bag, slot) or nil;
	local action = disposal ~= DISPOSAL_SELL and disposal or nil;
	if action then
		overlay.shade:SetColorTexture(action.tint[1], action.tint[2], action.tint[3], 0.55);
		overlay.action:SetTexture(GetActionIcon(action));
	else
		overlay.shade:SetColorTexture(0, 0, 0, 0.6);
	end
	overlay.shade:SetShown(isJunk);
	overlay.coin:SetShown(isJunk and not action);
	overlay.action:SetShown(action ~= nil);
	overlay.star:SetShown(isFavorite);
end

local function RefreshContainerFrame(frame)
	if not db or not frame:IsShown() then
		return;
	end
	for _, button in frame:EnumerateValidItems() do
		if button then
			if not hookedButtons[button] then
				hookedButtons[button] = true;
				button:HookScript("OnEnter", HoverEnter);
				button:HookScript("OnLeave", HoverLeave);
				button:HookScript("OnHide", HoverLeave);
			end
			UpdateButtonOverlay(button);
		end
	end
end

-- The bag frames are read directly rather than through ContainerFrameUtil_Enumerate*,
-- because those helpers cache a table on first use and an addon triggering that
-- would taint the default UI's own item clicks.
local function ForEachContainerFrame(callback)
	if ContainerFrameCombinedBags then
		callback(ContainerFrameCombinedBags);
	end
	local frames = ContainerFrameContainer and ContainerFrameContainer.ContainerFrames;
	if frames then
		for _, frame in ipairs(frames) do
			callback(frame);
		end
	end
end

--------------------------------------------------------------------------------
-- Other bag addons
--
-- Bagnon, Baganator, EllesmereUIBags and the like hide the default bag frames and
-- draw their own. They all build their item buttons from Blizzard's own template
-- (ContainerFrameItemButtonTemplate), because that is what keeps the game's secure
-- item click working, and for the same reason each button reports its real slot
-- through GetBagID() and GetID(). So such a button can be hooked and decorated
-- exactly like a default one, with no code specific to any of those addons.
--
-- What differs is finding the buttons: there is no shared list and they are created
-- lazily. JunkMark notices a window the first time the cursor rests on one of its
-- item buttons, then follows that window. Nothing is hooked on the buttons beyond
-- script hooks; a button being reused for another slot (sorting, categories) is
-- caught by comparing what each visible button holds against what was last drawn.
--------------------------------------------------------------------------------

local WATCH_INTERVAL = 0.1; -- seconds between looks at what is under the cursor
local RECHECK_TICKS = 3; -- every this many looks, visible buttons are compared too
local PARENT_CLIMB = 3; -- the cursor may be on a child frame of the item button

local foreignWindows = setmetatable({}, { __mode = "k" }); -- top-level bag window -> true
local foreignButtons = setmetatable({}, { __mode = "k" }); -- item button -> GUID last drawn, or false
local buttonVerdicts = setmetatable({}, { __mode = "k" }); -- frame -> is it a bag item button
local foreignRefreshQueued = false;

-- A button made from Blizzard's bag item template. Bag-bar slot buttons and others
-- answer GetBagID as well; only item buttons also carry the junk-coin method.
local function IsBagItemButton(frame)
	local verdict = buttonVerdicts[frame];
	if verdict == nil then
		verdict = not frame:IsForbidden()
			and type(frame.GetBagID) == "function"
			and type(frame.UpdateJunkItem) == "function";
		buttonVerdicts[frame] = verdict;
	end
	return verdict;
end

-- The button's slot if it is in the player's bags. The same template is used for
-- bank slots, which JunkMark does not mark.
local function GetPlayerBagSlot(button)
	local bag, slot = button:GetBagID(), button:GetID();
	if type(bag) == "number" and bag >= 0 and bag <= (NUM_TOTAL_BAG_FRAMES or 4) and slot and slot >= 1 then
		return bag, slot;
	end
	return nil;
end

-- The default UI's own bag and bank frames. Their buttons are handled through
-- UpdateItems above and must never be treated as another addon's.
local function IsDefaultBagFrame(frame)
	if frame == ContainerFrameCombinedBags or frame == ContainerFrameContainer or frame == BankFrame then
		return true;
	end
	local frames = ContainerFrameContainer and ContainerFrameContainer.ContainerFrames;
	if frames then
		for _, containerFrame in ipairs(frames) do
			if containerFrame == frame then
				return true;
			end
		end
	end
	return false;
end

local function ForeignEnter(button)
	if GetPlayerBagSlot(button) then
		HoverEnter(button);
	end
end

local function DrawForeignButton(button)
	foreignButtons[button] = GetSlotGUID(button:GetBagID(), button:GetID()) or false;
	UpdateButtonOverlay(button);
end

local function AdoptForeignButton(button)
	if hookedButtons[button] then
		return;
	end
	hookedButtons[button] = true;
	foreignButtons[button] = false;
	button:HookScript("OnEnter", ForeignEnter);
	button:HookScript("OnLeave", HoverLeave);
	button:HookScript("OnHide", HoverLeave);
end

-- Adopts every bag item button under a frame. Hidden ones are adopted too, since a
-- window can show them later without being reopened.
local function CollectForeignButtons(frame, depth)
	if frame:IsForbidden() then
		return;
	end
	if IsBagItemButton(frame) then
		AdoptForeignButton(frame);
		return;
	end
	if depth < 12 then
		for _, child in ipairs({ frame:GetChildren() }) do
			CollectForeignButtons(child, depth + 1);
		end
	end
end

-- Re-collects the buttons of every open window being followed and redraws them.
local function RefreshForeignButtons()
	foreignRefreshQueued = false;
	if not db then
		return;
	end
	for window in pairs(foreignWindows) do
		if window:IsShown() then
			CollectForeignButtons(window, 0);
		end
	end
	for button in pairs(foreignButtons) do
		if button:IsVisible() then
			DrawForeignButton(button);
		end
	end
end

-- Runs RefreshForeignButtons on the next frame, once, however often it is asked. The
-- delay lets the bag addon finish its own update first: on a bag event JunkMark may
-- be told before the addon has moved its buttons to their new slots.
local function QueueForeignRefresh()
	if not foreignRefreshQueued and next(foreignWindows) then
		foreignRefreshQueued = true;
		C_Timer.After(0, RefreshForeignButtons);
	end
end

-- A followed window was shown (or has just been found). Its buttons are collected on
-- the next frame, and once more a little later for an addon that lays them out late.
local FOREIGN_SECOND_LOOK_SECONDS = 0.5;
local function OnForeignWindowShown()
	QueueForeignRefresh();
	C_Timer.After(FOREIGN_SECOND_LOOK_SECONDS, RefreshForeignButtons);
end

-- Starts following the window a newly seen item button belongs to: the frame just
-- below UIParent in its parent chain. Returns false for the default UI's own frames.
local function FollowForeignWindow(button)
	local window, parent = button, button:GetParent();
	while parent and parent ~= UIParent do
		if IsDefaultBagFrame(parent) then
			return false;
		end
		window, parent = parent, parent:GetParent();
	end
	if not foreignWindows[window] then
		foreignWindows[window] = true;
		window:HookScript("OnShow", OnForeignWindowShown);
		-- Remembered by name, so the next session can follow it before any hover.
		local name = window:GetName();
		if name then
			db.bagWindows = db.bagWindows or {};
			db.bagWindows[name] = true;
		end
	end
	return true;
end

-- Follows the windows remembered from earlier sessions as soon as they exist. Bag
-- addons create their window lazily, often on the first open, so this is asked on
-- every look until each name has turned up. Without it a window would show no marks
-- after a login or /reload until the cursor first touched one of its items.
local rememberedFound = {}; -- window name -> followed this session
local function FollowRememberedWindows()
	local found = false;
	for name in pairs(db.bagWindows or {}) do
		if not rememberedFound[name] then
			local window = _G[name];
			if type(window) == "table" and type(window.IsForbidden) == "function" and not window:IsForbidden()
				and type(window.HookScript) == "function" and type(window.GetChildren) == "function" then
				rememberedFound[name] = true;
				if not IsDefaultBagFrame(window) and not foreignWindows[window] then
					foreignWindows[window] = true;
					window:HookScript("OnShow", OnForeignWindowShown);
					found = true;
				end
			end
		end
	end
	if found then
		OnForeignWindowShown();
	end
end

-- Redraws any visible button whose slot now holds a different item than was drawn.
local function RecheckForeignButtons()
	local changed = false;
	for button, drawn in pairs(foreignButtons) do
		if button:IsVisible() then
			local guid = GetSlotGUID(button:GetBagID(), button:GetID()) or false;
			if guid ~= drawn then
				DrawForeignButton(button);
				changed = true;
			end
		end
	end
	if changed then
		ApplyHoverKey();
	end
end

-- Looks for a bag item button under the cursor that has not been seen before.
local function WatchCursor()
	local frame = GetMouseFoci()[1];
	for _ = 1, PARENT_CLIMB do
		if not frame or frame:IsForbidden() or hookedButtons[frame] or blockerOwners[frame] then
			return;
		end
		if IsBagItemButton(frame) then
			break;
		end
		frame = frame:GetParent();
	end
	if not frame or frame:IsForbidden() or hookedButtons[frame] or not IsBagItemButton(frame) then
		return;
	end
	if GetPlayerBagSlot(frame) and FollowForeignWindow(frame) then
		RefreshForeignButtons();
		-- The cursor was already on this button before it was hooked.
		if hookedButtons[frame] then
			ForeignEnter(frame);
		end
	end
end

local watcher = CreateFrame("Frame");
local sinceWatch, watchTicks = 0, 0;
watcher:SetScript("OnUpdate", function(_, elapsed)
	sinceWatch = sinceWatch + elapsed;
	if sinceWatch < WATCH_INTERVAL or not db then
		return;
	end
	sinceWatch = 0;
	FollowRememberedWindows();
	WatchCursor();
	watchTicks = watchTicks + 1;
	if watchTicks >= RECHECK_TICKS then
		watchTicks = 0;
		RecheckForeignButtons();
	end
end);

local function RefreshAllBags()
	ForEachContainerFrame(RefreshContainerFrame);
	RefreshForeignButtons();
end

local function OnMarksChanged()
	RefreshAllBags();
	UpdateSellButton();
	UpdateQueuePanel();
end

--------------------------------------------------------------------------------
-- Marking
--------------------------------------------------------------------------------

local function SetMark(guid, kind, sellOnly)
	if kind then
		-- The order number makes the profession queue first-marked, first-processed.
		db.nextOrder = (db.nextOrder or 0) + 1;
		db.marked[guid] = { kind = kind, order = db.nextOrder, sellOnly = sellOnly or nil };
	else
		db.marked[guid] = nil;
	end
end

-- Steps an item through: unmarked -> junk -> favorite -> unmarked.
-- Junk is skipped for an item that can be neither sold nor used by a profession.
-- Junk that a vendor will buy and a profession can also use takes two steps: first
-- plain vendor junk, then queued for the profession, so the player can pick either.
function CycleSlot(bag, slot)
	local guid = GetSlotGUID(bag, slot);
	local info = guid and C_Container.GetContainerItemInfo(bag, slot);
	if not info then
		return;
	end

	local mark = db.marked[guid];
	local current = mark and mark.kind;
	local canSell = not info.hasNoValue;
	local hasAction = FindAction(info, bag, slot) ~= nil;

	local nextKind, sellOnly;
	if current == KIND_JUNK then
		if mark.sellOnly and hasAction then
			nextKind = KIND_JUNK;
		else
			nextKind = KIND_FAVORITE;
		end
	elseif current == KIND_FAVORITE then
		nextKind = nil;
	elseif canSell then
		-- Always sellOnly, even with no profession to hold the item back from: junk the
		-- player marked for the vendor stays vendor junk if a profession is learned later.
		nextKind, sellOnly = KIND_JUNK, true;
	else
		nextKind = hasAction and KIND_JUNK or KIND_FAVORITE;
	end

	SetMark(guid, nextKind, sellOnly);
	PlaySound(nextKind and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF);
	OnMarksChanged();
end

-- Key binding target (Bindings.xml), also what the hover key is pointed at.
function JunkMark_ToggleHovered()
	if not db then
		return;
	end

	local frame = hoverFrame;
	if not frame then
		-- Reached through a key the player bound themselves: look under the cursor.
		-- Only frames JunkMark itself has registered count: its blockers and the bag
		-- item buttons it has hooked. Other frames can look similar but are not bags.
		for _, region in ipairs(GetMouseFoci()) do
			if blockerOwners[region] or hookedButtons[region] then
				frame = region;
				break;
			end
		end
	end

	local button = frame and GetItemButton(frame);
	-- Another addon's bank buttons are hooked along with its bag buttons, so the
	-- slot is checked here rather than assumed to be in the bags.
	if button and GetPlayerBagSlot(button) then
		CycleSlot(button:GetBagID(), button:GetID());
	end
end

-- Drops junk marks for items that are no longer in the bags (sold, traded, used up).
-- Favorites are kept even when the item is out of sight, since it may be in the bank;
-- PruneFavorites deals with those.
local function PruneMarks()
	local present = GetBagGUIDs();
	for guid, mark in pairs(db.marked) do
		if mark.kind == KIND_JUNK and not present[guid] then
			db.marked[guid] = nil;
		end
	end
end

local bankOpen = false;
local equipLocation = ItemLocation:CreateEmpty();
local BANK_SETTLE_SECONDS = 1; -- between the bank opening and looking through it

-- The GUID of everything the character holds outside its bags that can be looked at:
-- what it is wearing and what is in the bank. Also returns how many bank slots were
-- looked at, which is 0 when the bank cannot be read. The bank's containers are taken
-- from the client's own list of bag indexes, so this follows whatever bank it has.
local function GetStoredGUIDs()
	local stored, bankSlots = {}, 0;
	for slot = (INVSLOT_FIRST_EQUIPPED or 1), (INVSLOT_LAST_EQUIPPED or 19) do
		equipLocation:SetEquipmentSlot(slot);
		if C_Item.DoesItemExist(equipLocation) then
			stored[C_Item.GetItemGUID(equipLocation)] = true;
		end
	end
	for name, bag in pairs(Enum.BagIndex or {}) do
		if type(name) == "string" and name:lower():find("banktab_", 1, true) then
			local slots = C_Container.GetContainerNumSlots(bag) or 0;
			bankSlots = bankSlots + slots;
			for slot = 1, slots do
				local guid = GetSlotGUID(bag, slot);
				if guid then
					stored[guid] = true;
				end
			end
		end
	end
	return stored, bankSlots;
end

-- Drops favorite marks whose item no longer exists (sold by hand, destroyed, traded,
-- mailed away), so the saved data does not grow forever. A favorite out of the bags is
-- usually just in the bank, so this only runs while the bank is open, and a mark is
-- dropped only if the item is in none of bags, bank and worn gear AND the game itself
-- says the character no longer holds it. If either look fails, the mark is kept.
local function PruneFavorites()
	if not db or not bankOpen or not C_Item.IsItemGUIDInInventory then
		return;
	end
	local stored, bankSlots = GetStoredGUIDs();
	if bankSlots == 0 then
		return;
	end
	local present = GetBagGUIDs();
	local dropped = 0;
	for guid, mark in pairs(db.marked) do
		if mark.kind == KIND_FAVORITE and not present[guid] and not stored[guid] then
			local ok, held = pcall(C_Item.IsItemGUIDInInventory, guid);
			if ok and held == false then
				db.marked[guid] = nil;
				dropped = dropped + 1;
			end
		end
	end
	if dropped > 0 then
		Print(string.format("Removed %d favorite mark%s for item%s you no longer have.", dropped, Plural(dropped), Plural(dropped)));
	end
end

--------------------------------------------------------------------------------
-- Selling
--------------------------------------------------------------------------------

-- An item bought from a vendor recently enough to be returned for a refund. The
-- default UI asks before selling one (the refund is lost), so JunkMark never does;
-- this is the same test ContainerFrame_GetExtendedPriceString applies.
local function IsRefundable(bag, slot)
	local info = C_Container.GetContainerItemPurchaseInfo(bag, slot, false);
	if not info or not info.refundSeconds then
		return false;
	end
	return info.money > 0 or info.itemCount > 0 or info.currencyCount > 0;
end

-- Returns the junk to sell, its total value, how many sellable junk items are being
-- held back for a profession, and how many were left out because they are still
-- refundable. includeHeld sells the held ones as well.
local function CollectJunk(includeHeld)
	local queue, totalValue, heldCount, refundableCount = {}, 0, 0, 0;
	ForEachBagItem(function(bag, slot, guid)
		local mark = db.marked[guid];
		local info = mark and C_Container.GetContainerItemInfo(bag, slot);
		local disposal = GetDisposal(mark, info, bag, slot);
		if disposal and not info.hasNoValue then
			if IsRefundable(bag, slot) then
				refundableCount = refundableCount + 1;
			elseif disposal == DISPOSAL_SELL or includeHeld then
				local sellPrice = select(11, C_Item.GetItemInfo(info.hyperlink)) or 0;
				local value = sellPrice * info.stackCount;
				queue[#queue + 1] = { bag = bag, slot = slot, guid = guid, link = info.hyperlink, count = info.stackCount, value = value };
				totalValue = totalValue + value;
			else
				heldCount = heldCount + 1;
			end
		end
	end);
	return queue, totalValue, heldCount, refundableCount;
end

-- Ends the sale in progress and reports it. An item only counts as sold once it has
-- left the bags: asking the vendor to take it is no guarantee, since the game can
-- refuse an item or stop to ask the player for confirmation.
local function FinishSelling()
	local run = sellRun;
	if not run then
		return;
	end
	sellRun = nil;
	sellTicker:Cancel();
	sellTicker = nil;

	local present = GetBagGUIDs();
	local sold, earned, unsold = 0, 0, 0;
	for _, entry in ipairs(run.sent) do
		if present[entry.guid] then
			unsold = unsold + 1;
		else
			-- Unmark, so an item bought back from the vendor returns unmarked.
			db.marked[entry.guid] = nil;
			sold = sold + 1;
			earned = earned + entry.value;
		end
	end

	if sold > 0 then
		Print(string.format("Sold %d item%s for %s.", sold, Plural(sold), FormatMoney(earned)));
	end
	if unsold > 0 then
		Print(string.format("%d item%s didn't sell and %s still marked as junk.", unsold, Plural(unsold), unsold == 1 and "is" or "are"));
	end
	UpdateSellButton();
end

local function HaveSentItemsLeftBags(run)
	local present = GetBagGUIDs();
	for _, entry in ipairs(run.sent) do
		if present[entry.guid] then
			return false;
		end
	end
	return true;
end

-- One step of a sale: sends the next item to the vendor, or, once all have been
-- sent, waits for the bags to catch up before finishing.
local function SellTick()
	local run = sellRun;
	if not merchantOpen then
		FinishSelling();
		return;
	end

	local entry = table.remove(run.queue);
	if entry then
		-- Bags can change mid-run, so confirm the slot still holds a junk-marked item.
		local mark = db.marked[entry.guid];
		if mark and mark.kind == KIND_JUNK and GetSlotGUID(entry.bag, entry.slot) == entry.guid then
			local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot);
			if info and not info.isLocked then
				C_Container.UseContainerItem(entry.bag, entry.slot);
				run.sent[#run.sent + 1] = entry;
			end
		end
		return;
	end

	run.settleTicks = run.settleTicks + 1;
	if run.settleTicks >= SELL_SETTLE_TICKS or HaveSentItemsLeftBags(run) then
		FinishSelling();
	end
end

local function SellJunk(includeHeld)
	if sellRun then
		return;
	end
	if not merchantOpen then
		Print("Visit a vendor to sell marked junk.");
		return;
	end

	local queue, _, _, refundableCount = CollectJunk(includeHeld);
	if refundableCount > 0 then
		Print(string.format("Left %d junk item%s alone because you can still return %s for a refund.", refundableCount, Plural(refundableCount), refundableCount == 1 and "it" or "them"));
	end
	if #queue == 0 then
		if refundableCount == 0 then
			Print("There is no junk to sell.");
		end
		return;
	end

	sellRun = { queue = queue, sent = {}, settleTicks = 0 };
	sellTicker = C_Timer.NewTicker(SELL_INTERVAL, SellTick);
	UpdateSellButton();
	SellTick();
end

function UpdateSellButton()
	if not sellButton or not merchantOpen then
		return;
	end
	local queue, _, heldCount = CollectJunk(false);
	sellButton:SetText(string.format("Sell Junk (%d)", #queue));
	-- Stays clickable with only held items, so Shift-click can still sell those.
	sellButton:SetEnabled((#queue > 0 or heldCount > 0) and not sellRun);
end

local SELL_BUTTON_WIDTH = 140;
local SELL_BUTTON_MIN_WIDTH = 80; -- about what "Sell Junk (12)" needs
local SELL_BUTTON_MARGIN = 4; -- in from the window's right edge
local SELL_BUTTON_TAB_GAP = 2; -- between the last tab and the button

-- Puts the button under the vendor window's bottom-right corner, in the same row as
-- the window's tabs, and as wide as the space right of the last tab allows. Other
-- addons add tabs of their own (Scrap adds a third), so the tabs are measured rather
-- than assumed: anything that hangs below the window's bottom edge counts. Only when
-- there is no room beside them does the button drop to a row of its own underneath.
local function PlaceSellButton()
	if not sellButton then
		return;
	end
	local frameLeft, frameBottom, frameWidth = MerchantFrame:GetLeft(), MerchantFrame:GetBottom(), MerchantFrame:GetWidth();
	if not frameLeft or not frameBottom or not frameWidth then
		return; -- the window has no position yet
	end

	local tabsRight, tabsBottom = frameLeft, frameBottom;
	for _, child in ipairs({ MerchantFrame:GetChildren() }) do
		if child ~= sellButton and not child:IsForbidden() and child:IsShown() and child:IsObjectType("Button") then
			local top, bottom, right = child:GetTop(), child:GetBottom(), child:GetRight();
			if top and bottom and right and (top + bottom) / 2 < frameBottom then
				tabsRight = math.max(tabsRight, right);
				tabsBottom = math.min(tabsBottom, bottom);
			end
		end
	end

	local room = (frameLeft + frameWidth - SELL_BUTTON_MARGIN) - (tabsRight + SELL_BUTTON_TAB_GAP);
	sellButton:ClearAllPoints();
	if room >= SELL_BUTTON_MIN_WIDTH then
		sellButton:SetWidth(math.min(SELL_BUTTON_WIDTH, room));
		sellButton:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -SELL_BUTTON_MARGIN, -2);
	else
		sellButton:SetWidth(SELL_BUTTON_WIDTH);
		sellButton:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -SELL_BUTTON_MARGIN, tabsBottom - frameBottom - 2);
	end
end

local function CreateSellButton()
	sellButton = CreateFrame("Button", "JunkMarkSellButton", MerchantFrame, "UIPanelButtonTemplate");
	sellButton:SetSize(SELL_BUTTON_WIDTH, 24);
	sellButton:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -SELL_BUTTON_MARGIN, -2);
	sellButton:SetScript("OnClick", function()
		SellJunk(IsShiftKeyDown());
	end);
	sellButton:SetScript("OnEnter", function(self)
		local queue, totalValue, heldCount = CollectJunk(false);
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
		GameTooltip:AddLine("Sell marked junk");
		if #queue > 0 then
			GameTooltip:AddLine(string.format("%d item%s worth %s", #queue, Plural(#queue), FormatMoney(totalValue)), 1, 1, 1);
		elseif heldCount == 0 then
			GameTooltip:AddLine(string.format("Hover a bag item and press %s to mark it as junk.", HOVER_KEY_NAME), 1, 1, 1, true);
		end
		if heldCount > 0 then
			GameTooltip:AddLine(string.format("%d item%s kept for your professions. Shift-click to sell those too.", heldCount, Plural(heldCount)), 0.7, 0.5, 1, true);
		end
		GameTooltip:Show();
	end);
	sellButton:SetScript("OnLeave", GameTooltip_Hide);
end

--------------------------------------------------------------------------------
-- Profession queue
--
-- Casting a spell needs a real click or key press, so an addon cannot work through
-- the queue by itself. Instead a secure button is kept aimed at the item at the head
-- of the queue: each press processes one item, then the button re-aims at the next.
--------------------------------------------------------------------------------

-- Junk that GetDisposal routes to a profession action, first-marked first.
local function CollectProcessQueue()
	local queue = {};
	ForEachBagItem(function(bag, slot, guid)
		local mark = db.marked[guid];
		local disposal = mark and GetDisposal(mark, C_Container.GetContainerItemInfo(bag, slot), bag, slot);
		if disposal and disposal ~= DISPOSAL_SELL then
			queue[#queue + 1] = { bag = bag, slot = slot, guid = guid, action = disposal, order = mark.order or 0 };
		end
	end);
	table.sort(queue, function(a, b)
		return a.order < b.order;
	end);
	return queue;
end

-- Points the secure button at a bag slot, or disarms it when head is nil.
-- Secure attributes can only change out of combat; callers check InCombatLockdown.
--
-- Every attribute carries the "1" suffix, which limits it to the left button. The
-- secure click handler applies an unsuffixed target-bag/target-slot after ANY click
-- while an item-targeting spell is on the cursor, so without the suffix a right-click
-- ("sell it instead") made with Disenchant already on the cursor would use it on the item.
local function AimProcessButton(head)
	processButton.head = head;
	processButton:SetAttribute("type1", head and "spell" or nil);
	processButton:SetAttribute("spell1", head and head.action.spellID or nil);
	processButton:SetAttribute("target-bag1", head and head.bag or nil);
	processButton:SetAttribute("target-slot1", head and head.slot or nil);
end

-- Sends the item at the head of the queue to the vendor pile instead.
local function SkipQueueHead()
	local head = processButton.head;
	local mark = head and db.marked[head.guid];
	if not mark then
		return;
	end
	local info = C_Container.GetContainerItemInfo(head.bag, head.slot);
	if info and not info.hasNoValue then
		mark.sellOnly = true;
	else
		-- Nothing else can be done with an unsellable item, so unmark it, and say so:
		-- a mark that vanishes without a word looks like a bug.
		db.marked[head.guid] = nil;
		Print(string.format("%s can't be sold to a vendor either, so its mark was removed.", info and info.hyperlink or "That item"));
	end
	OnMarksChanged();
end

--------------------------------------------------------------------------------
-- Refused items
--
-- The game refuses to disenchant some gear of the right quality and type, and gives
-- an addon no way to know beforehand. What it does give is the error it shows when
-- the attempt is made. So the queue button notes each attempt, and an error that
-- arrives right after one, for the item that was tried, is taken as the game's answer
-- about that item. Only the errors an ability lists as final teach JunkMark anything;
-- every other error ("can't do that while moving") is just recorded.
--------------------------------------------------------------------------------

local REFUSAL_WINDOW_SECONDS = 1.5;
local lastAttempt; -- the last left-click on the queue button: { guid, bag, slot, action, time }

local function NoteAttempt()
	local head = processButton and processButton.head;
	lastAttempt = head and { guid = head.guid, bag = head.bag, slot = head.slot, action = head.action, time = GetTime() } or nil;
	-- A running count, saved, so a report of "nothing happened" can be told apart
	-- from "the button was never left-clicked".
	if db then
		db.attempts = (db.attempts or 0) + 1;
	end
end

local function IsFinalRefusal(action, message)
	for _, name in ipairs(action.finalRefusals or {}) do
		if _G[name] ~= nil and _G[name] == message then
			return true;
		end
	end
	for _, text in ipairs(action.finalRefusalTexts or {}) do
		if text == message then
			return true;
		end
	end
	return false;
end

-- The names of the game's global strings that hold exactly this text, for the record
-- kept in lastRefusal. A walk over every global, so only done when an attempt fails.
local function FindGlobalStringNames(message)
	local names = {};
	for name, value in pairs(_G) do
		if value == message and type(name) == "string" and name:match("^[A-Z][A-Z0-9_]+$") then
			names[#names + 1] = name;
		end
	end
	table.sort(names);
	return names;
end

local function OnErrorMessage(errorType, message)
	local attempt = lastAttempt;
	if not attempt or not db or GetTime() - attempt.time > REFUSAL_WINDOW_SECONDS then
		return;
	end
	if GetSlotGUID(attempt.bag, attempt.slot) ~= attempt.guid then
		return;
	end
	local info = C_Container.GetContainerItemInfo(attempt.bag, attempt.slot);
	if not info then
		return;
	end

	-- Kept so a report of "it won't disenchant X" can be matched to what the game said.
	-- The name lookup walks every global the client has, which is not something to
	-- trust blindly: if it fails, the failure is recorded and the rest carries on.
	local found, names = pcall(FindGlobalStringNames, message);
	db.lastRefusal = {
		message = message,
		errorType = errorType,
		itemID = info.itemID,
		link = info.hyperlink,
		globals = found and names or nil,
		lookupError = not found and tostring(names) or nil,
	};

	if not info.itemID or not IsFinalRefusal(attempt.action, message) then
		return;
	end
	lastAttempt = nil;
	db.refused = db.refused or {};
	db.refused[attempt.action.spellID] = db.refused[attempt.action.spellID] or {};
	db.refused[attempt.action.spellID][info.itemID] = true;

	-- The marks on this kind of item come off rather than falling back to the vendor
	-- pile: the player asked for a disenchant, which is not a request to sell.
	ForEachBagItem(function(bag, slot, guid)
		local mark = db.marked[guid];
		if mark and mark.kind == KIND_JUNK and not mark.sellOnly then
			local other = C_Container.GetContainerItemInfo(bag, slot);
			if other and other.itemID == info.itemID then
				db.marked[guid] = nil;
			end
		end
	end);
	Print(string.format("%s can't be used with %s. Its mark was removed, and JunkMark won't offer that for it again.", info.hyperlink, attempt.action.label));
	OnMarksChanged();
end

local function CreateQueuePanel()
	queuePanel = CreateFrame("Frame", "JunkMarkQueuePanel", UIParent);
	queuePanel:SetSize(160, 52);
	local pos = db.panelPos;
	if pos then
		queuePanel:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y);
	else
		queuePanel:SetPoint("CENTER", UIParent, "CENTER", 320, -120);
	end
	queuePanel:SetClampedToScreen(true);
	queuePanel:SetMovable(true);
	queuePanel:EnableMouse(true);
	queuePanel:RegisterForDrag("LeftButton");
	queuePanel:SetScript("OnDragStart", function(self)
		-- A frame holding a secure button cannot be moved in combat.
		if not InCombatLockdown() then
			self:StartMoving();
		end
	end);
	queuePanel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing();
		local point, _, relativePoint, x, y = self:GetPoint(1);
		db.panelPos = { point = point, relativePoint = relativePoint, x = x, y = y };
	end);

	local background = queuePanel:CreateTexture(nil, "BACKGROUND");
	background:SetAllPoints(queuePanel);
	background:SetColorTexture(0, 0, 0, 0.7);

	-- Names the ability the next press will use, e.g. "Disenchant".
	queuePanel.title = queuePanel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall");
	queuePanel.title:SetPoint("TOPLEFT", 52, -10);

	queuePanel.countText = queuePanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
	queuePanel.countText:SetPoint("TOPLEFT", queuePanel.title, "BOTTOMLEFT", 0, -4);

	processButton = CreateFrame("Button", "JunkMarkProcessButton", queuePanel, "SecureActionButtonTemplate");
	processButton:SetSize(36, 36);
	processButton:SetPoint("LEFT", 8, 0);
	-- Both edges are registered because the secure handler acts on key-down or
	-- key-up depending on the player's "cast on key down" setting.
	processButton:RegisterForClicks("AnyUp", "AnyDown");

	processButton.icon = processButton:CreateTexture(nil, "ARTWORK");
	processButton.icon:SetAllPoints(processButton);
	processButton:SetHighlightTexture([[Interface\Buttons\ButtonHilight-Square]], "ADD");

	processButton:SetScript("OnEnter", function(self)
		if not self.head then
			return;
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
		GameTooltip:SetBagItem(self.head.bag, self.head.slot);
		GameTooltip:AddLine(" ");
		GameTooltip:AddLine("Click: " .. self.head.action.label:lower() .. " this item", 0.4, 1, 0.4);
		GameTooltip:AddLine("Right-click: sell it to a vendor instead", 0.4, 1, 0.4);
		GameTooltip:Show();
	end);
	processButton:SetScript("OnLeave", GameTooltip_Hide);
	processButton:SetScript("PostClick", function(_, mouseButton, down)
		if mouseButton == "RightButton" and not down and not InCombatLockdown() then
			SkipQueueHead();
		elseif mouseButton == "LeftButton" then
			NoteAttempt();
		end
	end);

	queuePanel:Hide();
end

function UpdateQueuePanel()
	if not db then
		return;
	end
	if InCombatLockdown() then
		queuePanelDirty = true;
		return;
	end
	queuePanelDirty = false;

	local queue = CollectProcessQueue();
	local head = queue[1];
	if not head then
		if queuePanel then
			-- Disarm, so a key bound to the button can never hit a leftover slot.
			AimProcessButton(nil);
			queuePanel:Hide();
		end
		return;
	end

	if not queuePanel then
		CreateQueuePanel();
	end
	AimProcessButton(head);
	local info = C_Container.GetContainerItemInfo(head.bag, head.slot);
	processButton.icon:SetTexture(info and info.iconFileID or nil);
	queuePanel.title:SetText(head.action.label);
	queuePanel.countText:SetText(string.format("%d item%s queued", #queue, Plural(#queue)));
	queuePanel:Show();
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

-- Prints the character's professions with the abilities each one puts in the
-- spellbook, then how junk is routed on this character.
-- /jm debug: writes what the game reports about every junk-marked item in the bags
-- into the saved data, where it can be read from disk after a /reload. For working
-- out why an item is routed the way it is; nothing reads it back.
local function WriteDebugDump()
	local items = {};
	ForEachBagItem(function(bag, slot, guid)
		local mark = db.marked[guid];
		if not mark or mark.kind ~= KIND_JUNK then
			return;
		end
		local info = C_Container.GetContainerItemInfo(bag, slot);
		local disposal = GetDisposal(mark, info, bag, slot);
		local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(info.hyperlink);
		local quest = C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot);
		local lines = {};
		local tooltip = C_TooltipInfo and C_TooltipInfo.GetBagItem(bag, slot);
		for _, line in ipairs(tooltip and tooltip.lines or {}) do
			lines[#lines + 1] = (line.leftText or "") .. (line.rightText and line.rightText ~= "" and (" | " .. line.rightText) or "");
		end
		items[#items + 1] = {
			link = info.hyperlink,
			itemID = info.itemID,
			quality = info.quality,
			hasNoValue = info.hasNoValue,
			isBound = info.isBound,
			classID = classID,
			subclassID = subclassID,
			bindType = select(14, C_Item.GetItemInfo(info.hyperlink)),
			isQuestItem = quest and quest.isQuestItem,
			questID = quest and quest.questID,
			sellOnly = mark.sellOnly,
			routedTo = disposal == DISPOSAL_SELL and "sell" or disposal and disposal.label or "nothing",
			tooltip = lines,
		};
	end);
	db.debug = { when = date("%Y-%m-%d %H:%M:%S"), items = items };
	Print(string.format("Wrote details of %d junk-marked item%s to the saved data. /reload to put it on disk.", #items, Plural(#items)));
end

local function PrintProfessions()
	local function PrintProfession(index)
		local name, _, rank, maxRank, numSpells, spellOffset = GetProfessionInfo(index);
		local abilities = {};
		for offset = 1, numSpells or 0 do
			local spell = C_SpellBook.GetSpellBookItemInfo(spellOffset + offset, Enum.SpellBookSpellBank.Player);
			if spell and spell.spellID then
				abilities[#abilities + 1] = string.format("%s (%d)", spell.name, spell.spellID);
			end
		end
		print(string.format("  %s %d/%d: %s", name, rank, maxRank, #abilities > 0 and table.concat(abilities, ", ") or "no abilities"));
	end

	local function PrintEach(...)
		local found = false;
		for i = 1, select("#", ...) do
			-- GetProfessions returns nil for an empty profession slot.
			local index = select(i, ...);
			if index then
				PrintProfession(index);
				found = true;
			end
		end
		return found;
	end

	Print("Your professions, with each ability's spell ID:");
	if not PrintEach(GetProfessions()) then
		print("  none");
	end

	local known = {};
	for _, action in ipairs(ACTIONS) do
		if IsActionKnown(action) then
			known[#known + 1] = action.label;
		end
	end
	if #known > 0 then
		Print("Junk these abilities can use is queued for them: " .. table.concat(known, ", ") .. ". The rest is sold.");
	else
		Print("None of your abilities use up items, so all junk is sold.");
	end

	-- The game can say whether the character has a Disenchant spell without naming
	-- it, which catches this addon having the wrong spell ID for this client.
	local disenchant = ACTIONS[1];
	if C_SpellBook.ContainsAnyDisenchantSpell() and not IsActionKnown(disenchant) then
		Print(string.format("|cffff4040You can disenchant, but not with spell %d.|r Find Disenchant's ID in the list above and set it in JunkMark.lua.", disenchant.spellID));
	end
end

local function PrintMarks()
	local junk, totalValue = CollectJunk(false);
	local queued = CollectProcessQueue();
	local favorites = {};
	ForEachBagItem(function(bag, slot, guid)
		local mark = db.marked[guid];
		if mark and mark.kind == KIND_FAVORITE then
			favorites[#favorites + 1] = C_Container.GetContainerItemLink(bag, slot) or "?";
		end
	end);

	if #junk == 0 and #queued == 0 and #favorites == 0 then
		Print("Nothing in your bags is marked.");
		return;
	end
	if #junk > 0 then
		Print(string.format("%d junk item%s to sell, worth %s:", #junk, Plural(#junk), FormatMoney(totalValue)));
		for _, entry in ipairs(junk) do
			print("  " .. entry.link .. (entry.count > 1 and (" x" .. entry.count) or ""));
		end
	end
	if #queued > 0 then
		Print(string.format("%d junk item%s queued for your professions:", #queued, Plural(#queued)));
		for index, entry in ipairs(queued) do
			print(string.format("  %d. %s: %s", index, entry.action.label, C_Container.GetContainerItemLink(entry.bag, entry.slot) or "?"));
		end
	end
	if #favorites > 0 then
		Print(string.format("%d favorite%s:", #favorites, Plural(#favorites)));
		for _, link in ipairs(favorites) do
			print("  " .. link);
		end
	end
end

SLASH_JUNKMARK1 = "/junkmark";
SLASH_JUNKMARK2 = "/jm";
SlashCmdList["JUNKMARK"] = function(message)
	local command = strtrim(message or ""):lower();

	if command == "list" then
		PrintMarks();
	elseif command == "clear" then
		wipe(db.marked);
		OnMarksChanged();
		Print("All marks cleared, favorites included.");
	elseif command == "sell" then
		SellJunk(false);
	elseif command == "sell all" then
		SellJunk(true);
	elseif command == "auto" then
		db.autoSell = not db.autoSell;
		Print("Auto-sell when a vendor opens is now " .. (db.autoSell and "|cff40ff40on|r" or "|cffff4040off|r") .. ".");
	elseif command == "professions" or command == "prof" then
		PrintProfessions();
	elseif command == "debug" then
		WriteDebugDump();
	elseif command == "forget" then
		-- The way back if the game refused an item for a reason that has since passed.
		db.refused = nil;
		OnMarksChanged();
		Print("Forgot which items the game refused. They can be queued again.");
	elseif command:match("^corner") then
		local corner = command:match("^corner%s+(%a+)$");
		if corner and CORNERS[corner] then
			db.corner = corner;
			for _, overlay in pairs(overlays) do
				AnchorMarkIcons(overlay);
			end
			Print("Mark icons now sit in the " .. corner .. " corner.");
		else
			Print(string.format("Mark icons sit in the %s corner. Change it with /jm corner <%s>.", db.corner or DEFAULT_CORNER, CORNER_NAMES));
		end
	else
		Print(string.format("Hover a bag item and press %s to cycle its mark: junk, favorite, none.", HOVER_KEY_NAME));
		print("  Junk your professions can use is queued for them; the rest is sold at a vendor.");
		print("  /jm list        - show marked items");
		print("  /jm sell        - sell junk (at a vendor); '/jm sell all' includes queued items");
		print("  /jm auto        - toggle selling automatically when a vendor opens");
		print("  /jm professions - show your professions and how junk is routed");
		print("  /jm corner      - show or set which corner of an item the mark icon sits in");
		print("  /jm forget      - forget which items the game refused to disenchant");
		print("  /jm debug       - write details of junk-marked items to the saved data, for a bug report");
		print("  /jm clear       - remove every mark");
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function InitializeSavedVariables()
	JunkMarkDB = JunkMarkDB or {};
	db = JunkMarkDB;
	db.marked = db.marked or {};
	if db.autoSell == nil then
		db.autoSell = false;
	end

	-- Saves from before versioning (0.1 to 0.3) carry no number; treating them as
	-- version 1 is safe because each step below only touches the shape it names.
	local version = db.schemaVersion or 1;

	if version < 2 then
		-- Version 1 stored a bare `true` for a junk mark.
		for guid, mark in pairs(db.marked) do
			if mark == true then
				db.marked[guid] = { kind = KIND_JUNK };
			elseif type(mark) ~= "table" then
				db.marked[guid] = nil;
			end
		end
	end

	if version < 3 then
		-- Version 2 had a separate "disenchant" mark; junk now covers it.
		for _, mark in pairs(db.marked) do
			if mark.kind == "disenchant" then
				mark.kind = KIND_JUNK;
			end
		end
	end

	-- A mark of a kind this version doesn't know is left exactly as it is, and the
	-- rest of the code treats it as unmarked. It must never be turned into junk: it
	-- may come from a newer version, and junk gets sold. For the same reason a save
	-- from a newer version keeps its own version number.
	if version < SCHEMA_VERSION then
		db.schemaVersion = SCHEMA_VERSION;
	end
end

local eventFrame = CreateFrame("Frame");
eventFrame:RegisterEvent("ADDON_LOADED");
eventFrame:RegisterEvent("PLAYER_LOGIN");
eventFrame:RegisterEvent("MERCHANT_SHOW");
eventFrame:RegisterEvent("MERCHANT_CLOSED");
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED");
eventFrame:RegisterEvent("SPELLS_CHANGED");
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED");
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED");
eventFrame:RegisterEvent("UI_ERROR_MESSAGE");
eventFrame:RegisterEvent("BANKFRAME_OPENED");
eventFrame:RegisterEvent("BANKFRAME_CLOSED");
eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 == addonName then
			InitializeSavedVariables();
		end
	elseif event == "PLAYER_LOGIN" then
		ForEachContainerFrame(function(frame)
			hooksecurefunc(frame, "UpdateItems", RefreshContainerFrame);
		end);
	elseif event == "MERCHANT_SHOW" then
		merchantOpen = true;
		if not sellButton then
			CreateSellButton();
		end
		-- Now, and again a frame later: an addon may add its tab while handling this
		-- same event, after JunkMark has measured.
		PlaceSellButton();
		C_Timer.After(0, PlaceSellButton);
		PruneMarks();
		RefreshAllBags(); -- puts the click blockers on favorites
		UpdateSellButton();
		if db.autoSell then
			SellJunk(false);
		end
	elseif event == "MERCHANT_CLOSED" then
		merchantOpen = false;
		FinishSelling();
		RefreshAllBags();
	elseif event == "UI_ERROR_MESSAGE" then
		OnErrorMessage(arg1, arg2);
	elseif event == "BANKFRAME_OPENED" then
		-- Not straight away: the bank's contents arrive just after it opens.
		bankOpen = true;
		C_Timer.After(BANK_SETTLE_SECONDS, PruneFavorites);
	elseif event == "BANKFRAME_CLOSED" then
		bankOpen = false;
	elseif event == "BAG_UPDATE_DELAYED" then
		QueueForeignRefresh();
		ApplyHoverKey();
		UpdateSellButton();
		UpdateQueuePanel();
	elseif event == "SPELLS_CHANGED" then
		-- Learning or dropping a profession changes where junk is routed.
		if db then
			OnMarksChanged();
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- This fires just before combat lockdown starts, the last moment bindings and
		-- secure attributes can change. Release the hover key so it cannot stay stuck
		-- on JunkMark, and disarm the queue button rather than leave it pointing at a
		-- slot whose contents might change.
		if hoverBound then
			ClearOverrideBindings(hoverOwner);
			hoverBound = false;
		end
		if processButton then
			AimProcessButton(nil);
			queuePanelDirty = true;
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		ApplyHoverKey();
		if queuePanelDirty then
			UpdateQueuePanel();
		end
	end
end);
