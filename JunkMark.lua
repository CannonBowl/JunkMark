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

-- Uncommon-to-epic weapons and armor. The game has the final say (skill level,
-- special items), so this only filters out things that can never be disenchanted.
local function IsDisenchantable(info)
	if not info.quality then
		return false;
	end
	if info.quality < Enum.ItemQuality.Uncommon or info.quality > Enum.ItemQuality.Epic then
		return false;
	end
	local classID = select(6, C_Item.GetItemInfoInstant(info.hyperlink));
	return classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor;
end

-- Profession abilities that are cast on a bag item and use it up. Junk is routed to
-- the first entry whose spell the character knows and whose IsEligible accepts the
-- item (it receives the slot's C_Container.GetContainerItemInfo table).
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
local function FindAction(info)
	for _, action in ipairs(ACTIONS) do
		if IsActionKnown(action) and action.IsEligible(info) then
			return action;
		end
	end
	return nil;
end

-- What will happen to a junk-marked item: an ACTIONS entry (it waits in the
-- profession queue), DISPOSAL_SELL, or nil if nothing can be done with it.
-- mark.sellOnly is set when the player sends a queued item to the vendor instead.
local function GetDisposal(mark, info)
	if not mark or mark.kind ~= KIND_JUNK or not info then
		return nil;
	end
	local action = not mark.sellOnly and FindAction(info) or nil;
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

local function CreateOverlay(button)
	local overlay = {};

	-- The lowest ARTWORK sublevel: above the item icon (BORDER), below the stack
	-- count (ARTWORK) and quality border (OVERLAY), which stay readable when dimmed.
	overlay.shade = button:CreateTexture(nil, "ARTWORK", nil, -8);
	overlay.shade:SetAllPoints(button);

	-- Junk bound for a vendor: the coin the default UI shows on gray items.
	overlay.coin = button:CreateTexture(nil, "OVERLAY", nil, 7);
	overlay.coin:SetAtlas("bags-junkcoin", true);
	overlay.coin:SetPoint("TOPLEFT", 1, 0);

	-- Junk bound for a profession: that ability's icon.
	overlay.action = button:CreateTexture(nil, "OVERLAY", nil, 7);
	overlay.action:SetSize(16, 16);
	overlay.action:SetPoint("TOPLEFT", 1, -1);

	overlay.star = button:CreateTexture(nil, "OVERLAY", nil, 7);
	overlay.star:SetAtlas("auctionhouse-icon-favorite");
	overlay.star:SetSize(16, 16);
	overlay.star:SetPoint("TOPLEFT", 1, -1);

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

	local disposal = isJunk and GetDisposal(mark, C_Container.GetContainerItemInfo(bag, slot)) or nil;
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

local function RefreshAllBags()
	ForEachContainerFrame(RefreshContainerFrame);
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
-- Junk that a profession can use and a vendor will also buy takes two steps: first
-- queued for the profession, then plain vendor junk, so the player can pick either.
function CycleSlot(bag, slot)
	local guid = GetSlotGUID(bag, slot);
	local info = guid and C_Container.GetContainerItemInfo(bag, slot);
	if not info then
		return;
	end

	local mark = db.marked[guid];
	local current = mark and mark.kind;
	local canSell = not info.hasNoValue;
	local hasAction = FindAction(info) ~= nil;

	local nextKind, sellOnly;
	if current == KIND_JUNK then
		if hasAction and canSell and not mark.sellOnly then
			nextKind, sellOnly = KIND_JUNK, true;
		else
			nextKind = KIND_FAVORITE;
		end
	elseif current == KIND_FAVORITE then
		nextKind = nil;
	else
		nextKind = (canSell or hasAction) and KIND_JUNK or KIND_FAVORITE;
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
	if button then
		CycleSlot(button:GetBagID(), button:GetID());
	end
end

-- Drops junk marks for items that are no longer in the bags (sold, traded, used up).
-- Favorites are kept even when the item is out of sight, since it may be in the bank.
local function PruneMarks()
	local present = GetBagGUIDs();
	for guid, mark in pairs(db.marked) do
		if mark.kind == KIND_JUNK and not present[guid] then
			db.marked[guid] = nil;
		end
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
		local disposal = GetDisposal(mark, info);
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

local function CreateSellButton()
	-- Hangs below the vendor window's bottom-right corner, one row under its tabs. The
	-- tab row itself is not safe: other addons add tabs of their own (Scrap adds a third,
	-- which reached this corner and covered the button).
	sellButton = CreateFrame("Button", "JunkMarkSellButton", MerchantFrame, "UIPanelButtonTemplate");
	sellButton:SetSize(140, 24);
	local tabHeight = MerchantFrameTab1 and MerchantFrameTab1:GetHeight() or 32;
	sellButton:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -4, -(tabHeight + 2));
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
		local disposal = mark and GetDisposal(mark, C_Container.GetContainerItemInfo(bag, slot));
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
		-- Nothing else can be done with an unsellable item, so just unmark it.
		db.marked[head.guid] = nil;
	end
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
	else
		Print(string.format("Hover a bag item and press %s to cycle its mark: junk, favorite, none.", HOVER_KEY_NAME));
		print("  Junk your professions can use is queued for them; the rest is sold at a vendor.");
		print("  /jm list        - show marked items");
		print("  /jm sell        - sell junk (at a vendor); '/jm sell all' includes queued items");
		print("  /jm auto        - toggle selling automatically when a vendor opens");
		print("  /jm professions - show your professions and how junk is routed");
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
eventFrame:SetScript("OnEvent", function(_, event, arg1)
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
	elseif event == "BAG_UPDATE_DELAYED" then
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
