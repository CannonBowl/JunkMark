-- Logic tests for JunkMark, run outside the game against a hand-written fake of the
-- WoW API. The game never loads this file (it is not listed in JunkMark.toc).
--
-- Run from the addon folder:
--     lua tests/mock_test.lua
-- It loads the files JunkMark.toc lists, in that order, the way the game does.
--
-- Limits worth knowing: the fake widgets accept any method name, and the fakes encode
-- assumptions about how the real API behaves, so a pass here shows the addon's logic
-- is self-consistent, not that it works in the client. The game runs Lua 5.1.

local files = {}
for raw in io.lines("JunkMark.toc") do
  local line = raw:gsub("%s+$", "")
  if line ~= "" and line:sub(1, 1) ~= "#" then files[#files + 1] = line end
end
-- Every file of an addon is passed the addon's folder name and one shared private table.
local function loadAddon() local ns = {}; for _, path in ipairs(files) do assert(loadfile(path))("RenamedFolder", ns) end end
local out, errors, fails = {}, {}, 0
local function check(name, cond) if cond then io.write("ok   ", name, "\n") else fails = fails + 1; io.write("FAIL ", name, "\n") end end

local bags = { [0] = {}, [1] = {} }
local function put(bag, slot, guid, price, o)
  o = o or {}
  bags[bag][slot] = { guid = guid, link = "[" .. guid .. "]", price = price, count = o.count or 1, noValue = o.noValue, quality = o.quality or 1, class = o.class or 0, tip = o.tip, id = o.id, icon = "icon:" .. guid }
end
local merchantOpen, money, tickers, inCombat, knowsDE, shift = false, 0, {}, false, true, false
local override = {} -- key -> command
local refused, refundable = {}, {}

print = function(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring((select(i, ...))) end out[#out+1] = table.concat(t, " ") end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 856, IG_MAINMENU_OPTION_CHECKBOX_OFF = 857 }
PlaySound = function(id) assert(id) end
SlashCmdList = {}
NUM_TOTAL_BAG_FRAMES = 1
Enum = { SpellBookSpellBank = { Player = "PlayerBank" }, ItemQuality = { Poor = 0, Uncommon = 2, Epic = 4 }, ItemClass = { Weapon = 2, Armor = 4 },
  BagIndex = { Keyring = -1, Backpack = 0, Bag_1 = 1, CharacterBankTab_1 = 6, AccountBankTab_1 = 15 } }
IsShiftKeyDown = function() return shift end
InCombatLockdown = function() return inCombat end
-- Which addon folders count as loaded, and the Ace addons that can be looked up by name.
local loaded, aceAddons = {}, {}
C_AddOns = { IsAddOnLoaded = function(name) return loaded[name] == true end }
-- Errors raised inside a protected listener call end up here instead of stopping the addon.
local caught = {}
geterrorhandler = function() return function(e) caught[#caught + 1] = tostring(e) end end
SetOverrideBinding = function(owner, priority, key, command) assert(not inCombat, "SetOverrideBinding in combat"); assert(owner and priority == true); override[key] = command end
ClearOverrideBindings = function(owner) assert(not inCombat, "ClearOverrideBindings in combat"); assert(owner); override = {} end

ItemLocation = {}
function ItemLocation:CreateEmpty() return { SetBagAndSlot = function(self, b, s) self.b, self.s = b, s end,
  SetEquipmentSlot = function(self, s) self.b, self.s = "equipped", s end } end -- worn gear lives in bags.equipped
local function at(loc) return bags[loc.b] and bags[loc.b][loc.s] end
local function byLink(link) for _, bag in pairs(bags) do for _, it in pairs(bag) do if it.link == link then return it end end end end
local elsewhere = {} -- GUIDs the game says the character holds although no slot shows them
ITEM_DISENCHANT_NOT_DISENCHANTABLE = "Cannot be disenchanted"
SPELL_FAILED_CANT_BE_DISENCHANTED = "Item cannot be disenchanted"
local clock = 100; GetTime = function() return clock end
date = os.date
C_TooltipInfo = { GetBagItem = function(b, s) local it = bags[b] and bags[b][s]; if not it then return nil end
  return { lines = { { leftText = it.link }, { leftText = "Binds when picked up" }, it.tip and { leftText = it.tip } or nil } } end }
C_Item = {
  DoesItemExist = function(loc) return at(loc) ~= nil end,
  GetItemGUID = function(loc) return at(loc).guid end,
  IsItemGUIDInInventory = function(guid) assert(type(guid) == "string"); if elsewhere[guid] then return true end
    for _, bag in pairs(bags) do for _, it in pairs(bag) do if it.guid == guid then return true end end end; return false end,
  GetItemInfo = function(link) local it = byLink(link); return "n", link, 1, 1, 1, "t", "st", 1, "", 1, it.price, it.class, 0, it.bind or 1 end, -- 14th: bind type, 4 = quest item
  GetItemInfoInstant = function(link) return 1, "t", "st", "", 1, byLink(link).class, 0 end,
}
C_Container = {
  GetContainerNumSlots = function() return 8 end,
  GetContainerItemInfo = function(b, s) local it = bags[b] and bags[b][s]; if not it then return nil end
    return { hyperlink = it.link, stackCount = it.count, hasNoValue = it.noValue or false, isLocked = false, quality = it.quality, iconFileID = it.icon, itemID = it.id or it.guid } end,
  GetContainerItemQuestInfo = function(b, s) return { isQuestItem = false, isActive = false } end,
  GetContainerItemLink = function(b, s) return bags[b][s] and bags[b][s].link end,
  UseContainerItem = function(b, s) assert(merchantOpen, "sold with no merchant"); local it = bags[b][s]; assert(not refundable[it.guid], "sold a refundable item"); if refused[it.guid] then return end; money = money + it.price * it.count; bags[b][s] = nil end,
  GetContainerItemPurchaseInfo = function(b, s, equipped) assert(equipped == false); local it = bags[b][s]; local r = it and refundable[it.guid]; return { money = r and 500 or 0, itemCount = 0, currencyCount = 0, refundSeconds = r and 3600 or 0, hasEnchants = false } end,
}
C_CurrencyInfo = { GetCoinTextureString = function(c) return c .. "c" end }
C_SpellBook = {
  IsSpellKnown = function(id) assert(id == 13262); return knowsDE end,
  ContainsAnyDisenchantSpell = function() return knowsDE end,
  GetSpellBookItemInfo = function(slot) local t = { [11] = { name = "Enchanting", spellID = 7411 }, [12] = { name = "Disenchant", spellID = 13262 } }; return t[slot] end,
}
GetProfessions = function() return 1, nil end
GetProfessionInfo = function() return "Enchanting", "tex", 150, 300, 2, 10 end
C_Spell = { GetSpellTexture = function(id) return "spellicon:" .. id end }
local timers = {} -- C_Timer.After callbacks waiting for the next frame
C_Timer = { NewTicker = function(_, fn) local t = { fn = fn, Cancel = function(self) self.cancelled = true end }; tickers[#tickers+1] = t; return t end,
  After = function(delay, fn) assert(type(delay) == "number" and delay >= 0); timers[#timers+1] = fn end } -- any delay runs on nextFrame()
local function pumpRaw(n) for _ = 1, n do for _, t in ipairs(tickers) do if not t.cancelled then t.fn() end end end end
local function nextFrame() local due = timers; timers = {}; for _, fn in ipairs(due) do fn() end end

local noop = function() end
local function widget()
  local w = { scripts = {}, attrs = {}, shown = true }
  function w:SetScript(n, fn) self.scripts[n] = fn end
  function w:SetAttribute(k, v) assert(not inCombat, "SetAttribute during combat lockdown"); self.attrs[k] = v end
  function w:Show() assert(not inCombat or not self.secure, "Show in combat"); self.shown = true end
  function w:Hide() assert(not inCombat or not self.secure, "Hide in combat"); self.shown = false end
  function w:IsShown() return self.shown end
  function w:SetShown(v)
    v = v and true or false
    if self.shown and not v and self.scripts.OnHide then self.shown = false; self.scripts.OnHide(self) end
    self.shown = v
  end
  function w:SetText(t) self.text = t end
  function w:SetTexture(t) self.tex = t end
  function w:SetAtlas(a) self.atlas = a end
  function w:SetEnabled(v) self.enabled = v end
  function w:GetFrameLevel() return 1 end
  function w:IsForbidden() return false end
  function w:CreateTexture() return widget() end
  function w:CreateFontString() return widget() end
  function w:GetPoint() return "CENTER", nil, "CENTER", 1, 2 end
  function w:ClearAllPoints() self.point = nil end
  function w:SetPoint(...) self.point = { ... } end
  function w:SetSize(width) self.width = width end
  function w:SetWidth(width) self.width = width end
  return setmetatable(w, { __index = function() return noop end })
end
local eventHandler, onUpdate
local childrenOf = {}
CreateFrame = function(_, name, parent, template)
  local f = widget()
  if template == "SecureActionButtonTemplate" then f.secure = true end
  local set = f.SetScript
  function f:SetScript(n, fn) set(self, n, fn); if n == "OnEvent" then eventHandler = fn elseif n == "OnUpdate" then onUpdate = fn end end
  if name then _G[name] = f end
  if parent then childrenOf[parent] = f end
  return f
end
UIParent = widget()
GameTooltip = widget()
GameTooltip_Hide = noop
MerchantFrame = widget()
UIErrorsFrame = { AddMessage = function(_, text) errors[#errors+1] = text end }

local function button(bag, slot)
  local b = { textures = {}, hooks = {} }
  function b:GetBagID() return bag end; function b:GetID() return slot end
  function b:GetFrameLevel() return 5 end
  function b:CreateTexture() local t = widget(); t.shown = false; self.textures[#self.textures+1] = t; return t end
  function b:HookScript(n, fn) self.hooks[n] = self.hooks[n] or {}; table.insert(self.hooks[n], fn) end
  function b:IsForbidden() return false end; function b:UpdateJunkItem() end
  function b:run(n, ...) for _, fn in ipairs(self.hooks[n] or {}) do fn(self, ...) end end
  -- textures are created in order: shade, coin, action, star
  function b:state()
    local t = self.textures
    if #t == 0 then return "none" end
    local shade, coin, action, star = t[1].shown, t[2].shown, t[3].shown, t[4].shown
    if not shade and not coin and not action and not star then return "none" end
    if shade and coin and not action and not star then return "sell" end
    if shade and action and not coin and not star then return "queue" end
    if star and not shade and not coin and not action then return "favorite" end
    return "broken"
  end
  function b:blocker() return childrenOf[self] end
  function b:blocked() local k = childrenOf[self]; return k ~= nil and k.shown end
  return b
end
local buttons = {}
for bag = 0, 1 do for slot = 1, 8 do buttons[#buttons+1] = button(bag, slot) end end
local function btn(bag, slot) return buttons[bag * 8 + slot] end
ContainerFrameCombinedBags = { IsShown = function() return true end, UpdateItems = function() end,
  EnumerateValidItems = function() return ipairs(buttons) end }
hooksecurefunc = function(t, name, hook)
  if type(t) == "string" then t, name, hook = _G, t, name end -- the two-argument form hooks a global function
  local orig = t[name]; t[name] = function(...) orig(...); hook(...) end
end
local foci = {}
GetMouseFoci = function() return foci end

put(0, 1, "graysword", 100, { class = 2 })
put(0, 2, "cloth", 5, { count = 20 })
put(0, 3, "greenhelm", 300, { quality = 2, class = 4 })
put(0, 4, "bluestaff", 900, { quality = 3, class = 2 })
put(1, 1, "questring", 0, { quality = 2, class = 4, noValue = true })
put(1, 2, "questjunk", 0, { noValue = true })
put(1, 3, "heirloom", 5000, { quality = 4, class = 4 })

JunkMarkDB = { marked = { cloth = true, bluestaff = { kind = "disenchant", order = 1 }, mystery = { kind = "keep" }, garbage = 7 }, nextOrder = 1 }
loadAddon()
local function fire(ev, ...) eventHandler(nil, ev, ...) end
local function pump(n) pumpRaw(n); fire("BAG_UPDATE_DELAYED") end
local function kind(g) return JunkMarkDB.marked[g] and JunkMarkDB.marked[g].kind end
-- press the hover key the way the game would: only does anything while the override binding is set
local function space() if override.SPACE == "JUNKMARK_TOGGLE" then JunkMark_ToggleHovered(); return true end return false end
local function hover(b) b:run("OnEnter") end
local function unhover(b) b:run("OnLeave") end
local function press(bag, slot, times) local b = btn(bag, slot); hover(b); for _ = 1, times or 1 do assert(space(), "hover key not bound") end; unhover(b) end
fire("ADDON_LOADED", "JunkMark"); check("ignores ADDON_LOADED for other addons", next(JunkMarkDB.marked.cloth == true and {} or {1}) == nil)
fire("ADDON_LOADED", "RenamedFolder"); fire("PLAYER_LOGIN"); fire("BAG_UPDATE_DELAYED")
ContainerFrameCombinedBags:UpdateItems()
local P, B = JunkMarkQueuePanel, JunkMarkProcessButton

check("0.1 and 0.2 saves migrate to junk", kind("cloth") == "junk" and kind("bluestaff") == "junk")
check("unknown mark kind is preserved, not turned into junk; garbage dropped; version stamped", kind("mystery") == "keep" and JunkMarkDB.marked.garbage == nil and JunkMarkDB.schemaVersion == 3)
check("migrated marks drawn by routing", btn(0, 2):state() == "sell" and btn(0, 4):state() == "queue")

-- hover key
check("Space is untouched when not hovering", next(override) == nil and not space())
hover(btn(0, 1)); check("hovering a bag item takes over Space", override.SPACE == "JUNKMARK_TOGGLE")
unhover(btn(0, 1)); check("leaving gives Space back", next(override) == nil)
hover(btn(0, 8)); check("empty slot does not take Space", next(override) == nil)
put(0, 8, "looted", 1); fire("BAG_UPDATE_DELAYED"); check("item arriving under a resting cursor takes Space", override.SPACE == "JUNKMARK_TOGGLE")
bags[0][8] = nil; fire("BAG_UPDATE_DELAYED"); check("item leaving under a resting cursor gives Space back", next(override) == nil); unhover(btn(0, 8))
hover(btn(0, 1)); btn(0, 1):run("OnHide"); check("closing bags while hovering gives Space back", next(override) == nil)

-- D4 cycle
press(0, 1); check("Space: none -> junk", kind("graysword") == "junk" and btn(0, 1):state() == "sell")
press(0, 1); check("Space: junk -> favorite", kind("graysword") == "favorite" and btn(0, 1):state() == "favorite")
press(0, 1); check("Space: favorite -> none", kind("graysword") == nil and btn(0, 1):state() == "none")
press(1, 2); check("unsellable non-gear skips junk: none -> favorite", kind("questjunk") == "favorite")
press(1, 2); check("...and favorite -> none", kind("questjunk") == nil)

-- smart routing for an enchanter
press(0, 1); press(0, 3, 2); press(1, 1)
check("gray weapon junk goes to the vendor pile", btn(0, 1):state() == "sell")
check("green armor junk is routed to disenchant", btn(0, 3):state() == "queue" and btn(0, 3).textures[3].tex == "spellicon:13262")
check("unsellable gear can still be junk, for disenchanting", kind("questring") == "junk" and btn(1, 1):state() == "queue")
P, B = JunkMarkQueuePanel, JunkMarkProcessButton
check("queue is first-marked first (migrated staff, then helm, then ring)", B.head.guid == "bluestaff" and B.attrs.spell == 13262 and B.attrs["target-bag"] == 0 and B.attrs["target-slot"] == 4 and P.countText.text == "3 items queued" and P.title.text == "Disenchant")

-- favorites at the vendor
-- gear a vendor will also buy steps through both kinds of junk before favorite
press(1, 3); check("Space on sellable gear: none -> junk for the vendor", kind("heirloom") == "junk" and btn(1, 3):state() == "sell" and JunkMarkDB.marked.heirloom.sellOnly == true)
press(1, 3); check("...-> junk queued for disenchant instead, vendor-only flag gone", kind("heirloom") == "junk" and btn(1, 3):state() == "queue" and JunkMarkDB.marked.heirloom.sellOnly == nil)
press(1, 3); check("...-> favorite", kind("heirloom") == "favorite" and btn(1, 3):state() == "favorite" and JunkMarkDB.marked.heirloom.sellOnly == nil)
check("no click blocker away from a vendor", not btn(1, 3):blocked())
JunkMarkDB.marked.banked = { kind = "favorite", order = 99 }; JunkMarkDB.marked.gone = { kind = "junk", order = 98 }
merchantOpen = true; fire("MERCHANT_SHOW")
check("vendor visit prunes missing junk but keeps an out-of-bag favorite", JunkMarkDB.marked.gone == nil and kind("banked") == "favorite")
check("favorite is covered by a click blocker at the vendor", btn(1, 3):blocked() and not btn(0, 1):blocked() and not btn(0, 3):blocked())
local K = btn(1, 3):blocker()
K.scripts.OnClick(K, "RightButton"); K.scripts.OnDragStart(K)
check("trying to sell a favorite shows a red error instead", #errors == 2 and errors[1]:find("favorite", 1, true) ~= nil and bags[1][3] ~= nil and money == 0)

check("vendor button counts only sell-routed junk", JunkMarkSellButton.text == "Sell Junk (2)" and JunkMarkSellButton.enabled)
JunkMarkSellButton.scripts.OnClick(JunkMarkSellButton); pump(4)
check("Sell Junk sells vendor junk only", money == 200 and not bags[0][1] and not bags[0][2] and bags[0][3] and bags[0][4] and bags[1][1] and bags[1][3])
check("button stays usable for Shift-click while items are held", JunkMarkSellButton.text == "Sell Junk (0)" and JunkMarkSellButton.enabled)

-- either mouse button processes the head; only Shift-right-click sends it to the vendor instead
check("the queue button casts for any button, and Shift-right-click is switched off for the cast", B.attrs.type == "spell" and B.attrs.type1 == nil and B.attrs["shift-type2"] == "" and B.attrs["shift-target-bag2"] == "" and B.attrs["shift-target-slot2"] == "")
B.scripts.PostClick(B, "RightButton", true); B.scripts.PostClick(B, "RightButton", false)
check("a plain right-click does not send the item to the vendor", B.head.guid == "bluestaff" and btn(0, 4):state() == "queue" and JunkMarkSellButton.text == "Sell Junk (0)")
shift = true; B.scripts.PostClick(B, "RightButton", true); check("Shift-right-click acts on release only", B.head.guid == "bluestaff")
B.scripts.PostClick(B, "RightButton", false); shift = false
check("skipped head moves to the vendor pile and stays junk", kind("bluestaff") == "junk" and btn(0, 4):state() == "sell" and B.head.guid == "greenhelm" and JunkMarkSellButton.text == "Sell Junk (1)")

-- hovering a favorite at the vendor goes through the blocker; ordering of enter/leave must not matter
hover(btn(1, 3)); K.scripts.OnEnter(K); unhover(btn(1, 3))
check("Space still bound when blocker's enter arrives before button's leave", override.SPACE == "JUNKMARK_TOGGLE")
space(); check("Space on a blocked favorite unmarks it and lifts the blocker", kind("heirloom") == nil and not btn(1, 3):blocked() and next(override) == nil)
hover(btn(1, 3)); space(); space(); space(); unhover(btn(1, 3)); K.scripts.OnLeave(K)
check("re-favorited at the vendor: blocker returns immediately", kind("heirloom") == "favorite" and btn(1, 3):blocked())

-- shift-click sells held items too, but never favorites
shift = true; JunkMarkSellButton.scripts.OnClick(JunkMarkSellButton); pump(4); shift = false
check("Shift-click sells queued junk as well", money == 200 + 900 + 300 and not bags[0][3] and not bags[0][4])
check("unsellable ring stays queued; favorite untouched", bags[1][1] and B.head.guid == "questring" and bags[1][3] and kind("heirloom") == "favorite")
local skippedAt = #out + 1; shift = true; B.scripts.PostClick(B, "RightButton", false); shift = false
check("skipping an unsellable item unmarks it and empties the queue", kind("questring") == nil and not P.shown and B.attrs.type == nil)
check("...and says so, rather than letting the mark vanish silently", table.concat(out, "\n", skippedAt):find("can't be sold to a vendor either, so its mark was removed.", 1, true) ~= nil)
merchantOpen = false; fire("MERCHANT_CLOSED")
check("blocker lifted when the vendor closes", not btn(1, 3):blocked())

-- combat
put(0, 5, "greenboots", 200, { quality = 2, class = 4 }); put(0, 6, "greenbelt", 150, { quality = 2, class = 4 })
press(0, 5, 2)
hover(btn(0, 6)); fire("PLAYER_REGEN_DISABLED"); inCombat = true
check("entering combat releases Space and disarms the queue button", next(override) == nil and B.attrs.type == nil)
check("Space does nothing on hover during combat", not space())
unhover(btn(0, 6)); hover(btn(0, 5)); unhover(btn(0, 5)); hover(btn(0, 6))
inCombat = false; fire("PLAYER_REGEN_ENABLED")
check("after combat Space works again on the item still hovered", override.SPACE == "JUNKMARK_TOGGLE" and B.attrs.type == "spell" and B.head.guid == "greenboots")
space(); space(); unhover(btn(0, 6))
check("queue grows in mark order", kind("greenbelt") == "junk" and B.head.guid == "greenboots" and P.countText.text == "2 items queued")
bags[0][5] = nil; fire("BAG_UPDATE_DELAYED")
check("queue advances after a disenchant", B.head.guid == "greenbelt" and B.attrs["target-slot"] == 6)

-- not an enchanter: all junk is vendor junk
knowsDE = false; fire("SPELLS_CHANGED")
check("without Disenchant the same junk goes to the vendor pile", btn(0, 6):state() == "sell" and not P.shown and B.attrs.type == nil)
put(0, 7, "greencloak", 120, { quality = 2, class = 4 }); fire("BAG_UPDATE_DELAYED")
press(0, 7); check("without Disenchant, gear is vendor junk", kind("greencloak") == "junk" and btn(0, 7):state() == "sell")
press(0, 7); check("...and has no second junk step: junk -> favorite", kind("greencloak") == "favorite")
press(0, 7, 2); check("(cloak marked for the vendor again)", kind("greencloak") == "junk" and btn(0, 7):state() == "sell")
knowsDE = true; fire("SPELLS_CHANGED")
check("learning Disenchant puts junk that was queued back in the queue", btn(0, 6):state() == "queue" and P.shown)
check("...but junk marked for the vendor stays vendor junk", btn(0, 7):state() == "sell" and P.countText.text == "1 item queued")
press(0, 7); check("...until Space sends it to the queue", btn(0, 7):state() == "queue" and P.countText.text == "2 items queued")
press(0, 7, 2); bags[0][7] = nil; fire("BAG_UPDATE_DELAYED")

-- gear a vendor won't buy can only be disenchanted, so it has no vendor step either
put(0, 7, "boundring", 0, { quality = 2, class = 4, noValue = true }); fire("BAG_UPDATE_DELAYED")
press(0, 7); check("unsellable gear: none -> junk, queued", kind("boundring") == "junk" and btn(0, 7):state() == "queue")
press(0, 7); check("...-> favorite, skipping the vendor step", kind("boundring") == "favorite")
press(0, 7); bags[0][7] = nil; fire("BAG_UPDATE_DELAYED")

-- gear whose tooltip says it cannot be disenchanted is never queued, whatever its quality
put(0, 7, "questblade", 0, { quality = 2, class = 2, noValue = true, tip = "Cannot be disenchanted" }); fire("BAG_UPDATE_DELAYED")
press(0, 7); check("refused gear nobody buys is never queued: none -> favorite", kind("questblade") == "favorite" and btn(0, 7):state() == "favorite" and P.countText.text == "1 item queued")
press(0, 7); check("...-> none", kind("questblade") == nil); bags[0][7] = nil
put(0, 7, "questcloak", 75, { quality = 2, class = 4, tip = "Cannot be disenchanted" }); fire("BAG_UPDATE_DELAYED")
press(0, 7); check("refused gear a vendor buys is vendor junk", kind("questcloak") == "junk" and btn(0, 7):state() == "sell")
press(0, 7); check("...with no disenchant step: junk -> favorite", kind("questcloak") == "favorite" and P.countText.text == "1 item queued")
-- a mark made for disenchant by an earlier version, before the tooltip was read
JunkMarkDB.marked.questcloak = { kind = "junk", order = 300 }; fire("SPELLS_CHANGED")
check("an old disenchant mark on refused gear falls back to the vendor pile", btn(0, 7):state() == "sell" and P.countText.text == "1 item queued")
JunkMarkDB.marked.questcloak = nil; bags[0][7] = nil; fire("BAG_UPDATE_DELAYED")
put(0, 7, "plaincloak", 75, { quality = 2, class = 4, tip = "Disenchantable" }); fire("BAG_UPDATE_DELAYED")
press(0, 7, 2); check("other tooltip lines do not stop a disenchant", btn(0, 7):state() == "queue" and P.countText.text == "2 items queued")
press(0, 7, 2); bags[0][7] = nil; fire("BAG_UPDATE_DELAYED")

-- a key the player bound themselves works without the hover binding
foci = { btn(0, 6) }; JunkMark_ToggleHovered(); foci = {}
check("user-bound key cycles the item under the cursor", kind("greenbelt") == "favorite" and not P.shown)

merchantOpen = true; fire("MERCHANT_SHOW"); JunkMarkDB.autoSell = true
SlashCmdList.JUNKMARK("sell all"); pump(2)
check("nothing left to sell; favorites survive 'sell all'", money == 1400 and bags[0][6] and bags[1][3])
local first = #out + 1
SlashCmdList.JUNKMARK("list"); SlashCmdList.JUNKMARK("professions"); SlashCmdList.JUNKMARK("")
local text = table.concat(out, "\n", first)
check("list shows favorites; professions shows routing", text:find("2 favorites:", 1, true) and text:find("queued for them: Disenchant", 1, true) and text:find("Disenchant (13262)", 1, true))

-- sale confirmation: an item the vendor does not take must stay marked and not be counted
merchantOpen = false; fire("MERCHANT_CLOSED"); JunkMarkDB.autoSell = false
put(0, 1, "stubborn", 40); put(0, 2, "easy", 60); put(0, 3, "receipt", 70)
press(0, 1); press(0, 2); press(0, 3)
refused.stubborn = true; refundable.receipt = true
merchantOpen = true; fire("MERCHANT_SHOW")
check("refundable junk is not offered for sale", JunkMarkSellButton.text == "Sell Junk (2)")
first = #out + 1; local before = money
SlashCmdList.JUNKMARK("sell"); pumpRaw(2)
check("run stays open while a sent item is still in the bags", not JunkMarkSellButton.enabled and kind("easy") == "junk")
pump(8); text = table.concat(out, "\n", first)
check("only the item that left the bags is counted and unmarked", money - before == 60 and kind("easy") == nil and text:find("Sold 1 item for 60c.", 1, true) ~= nil)
check("refused item is reported and keeps its junk mark", kind("stubborn") == "junk" and bags[0][1] ~= nil and text:find("1 item didn't sell and is still marked as junk.", 1, true) ~= nil)
check("refundable item is left alone and the player is told", kind("receipt") == "junk" and bags[0][3] ~= nil and text:find("Left 1 junk item alone because you can still return it for a refund.", 1, true) ~= nil)
check("button usable again after the run", JunkMarkSellButton.enabled)
local saleTrace = table.concat(JunkMarkDB.trace, "\n")
check("the trace records what the sale set out to do and how it ended", saleTrace:find("sale: 2 to send worth 100 copper, 0 kept for a profession, 1 refundable left alone", 1, true) ~= nil and saleTrace:find("sale: 2 sent, 1 sold for 60 copper, 1 still in the bags", 1, true) ~= nil)
refused.stubborn = nil; SlashCmdList.JUNKMARK("sell"); pumpRaw(1); merchantOpen = false; fire("MERCHANT_CLOSED")
check("closing the vendor mid-run still settles what sold", kind("stubborn") == nil and money - before == 100)

-- a look-alike frame under the cursor (Blizzard's PlayerChoice has an .itemButton field) is ignored
foci = { { itemButton = {}, IsForbidden = function() return false end } }
check("user-bound key over a look-alike frame does nothing and does not error", pcall(JunkMark_ToggleHovered))
foci = {}
SlashCmdList.JUNKMARK("clear"); check("clear removes favorites too and lifts blockers", next(JunkMarkDB.marked) == nil and not btn(1, 3):blocked())

-- a save written by a newer version must load untouched
JunkMarkDB = { schemaVersion = 99, marked = { future = { kind = "disenchant" }, other = { kind = "bank" } } }
fire("ADDON_LOADED", "RenamedFolder")
check("newer save is not migrated or re-stamped", JunkMarkDB.schemaVersion == 99 and JunkMarkDB.marked.future.kind == "disenchant" and JunkMarkDB.marked.other.kind == "bank")

--------------------------------------------------------------------------------
-- Identical items, stacks, and relogging
--
-- Marks are keyed by item GUID. These tests pin down that nothing in the addon falls
-- back to the item's link or ID, and that the saved format survives a logout. They
-- assume what the game is understood to do: every item instance, and every stack, has
-- its own GUID, and that GUID is the same after logging back in.
--------------------------------------------------------------------------------

-- What reaches disk at logout and comes back at login: plain data, no functions.
local function roundTrip(value)
  local function ser(v)
    if type(v) == "table" then
      local parts = {}
      for k, x in pairs(v) do parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
      return "{" .. table.concat(parts, ",") .. "}"
    elseif type(v) == "string" then
      return string.format("%q", v)
    end
    assert(type(v) == "number" or type(v) == "boolean", "saved data holds a " .. type(v))
    return tostring(v)
  end
  return (loadstring or load)("return " .. ser(value))() -- loadstring on Lua 5.1, the client's version
end

-- Log out and back in: saved data goes through the disk format, every frame is new,
-- and the addon file runs again from the top.
local function relog()
  merchantOpen, inCombat, override, tickers, foci, timers = false, false, {}, {}, {}, {}
  for i = 1, #buttons do buttons[i] = button(math.floor((i - 1) / 8), (i - 1) % 8 + 1) end
  ContainerFrameCombinedBags.UpdateItems = function() end
  JunkMarkQueuePanel, JunkMarkProcessButton, JunkMarkSellButton = nil, nil, nil
  JunkMarkDB = JunkMarkDB and roundTrip(JunkMarkDB)
  loadAddon()
  fire("ADDON_LOADED", "RenamedFolder"); fire("PLAYER_LOGIN"); fire("BAG_UPDATE_DELAYED")
  ContainerFrameCombinedBags:UpdateItems()
end

bags[0], bags[1] = {}, {}; JunkMarkDB = nil; knowsDE = false; money = 0
relog()

-- Two swords, and two stacks of cloth, that are the same item in every way a player can see.
put(0, 1, "sword-A", 100, { class = 2 }); put(0, 2, "sword-B", 100, { class = 2 })
bags[0][1].link, bags[0][2].link = "[Twin Sword]", "[Twin Sword]"
put(0, 3, "cloth-A", 5, { count = 20 }); put(0, 4, "cloth-B", 5, { count = 20 })
bags[0][3].link, bags[0][4].link = "[Linen Cloth]", "[Linen Cloth]"
ContainerFrameCombinedBags:UpdateItems()
press(0, 1); press(0, 4, 2)
check("marking one of two identical swords leaves the other alone", kind("sword-A") == "junk" and kind("sword-B") == nil and btn(0, 1):state() == "sell" and btn(0, 2):state() == "none")
check("marking one of two identical stacks leaves the other alone", kind("cloth-B") == "favorite" and kind("cloth-A") == nil and btn(0, 4):state() == "favorite" and btn(0, 3):state() == "none")

relog()
check("marks survive logout and login, on the same items only", kind("sword-A") == "junk" and kind("sword-B") == nil and kind("cloth-B") == "favorite" and kind("cloth-A") == nil
  and btn(0, 1):state() == "sell" and btn(0, 2):state() == "none" and btn(0, 4):state() == "favorite" and btn(0, 3):state() == "none")

-- Bags get sorted: the identical items trade places.
bags[0][1], bags[0][2] = bags[0][2], bags[0][1]; bags[0][3], bags[0][4] = bags[0][4], bags[0][3]
fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
local function swapped() return btn(0, 2):state() == "sell" and btn(0, 1):state() == "none" and btn(0, 3):state() == "favorite" and btn(0, 4):state() == "none" end
check("when identical items swap slots, the mark moves with the marked one", swapped())
relog()
check("...and it is still on the right one after another login", swapped())

merchantOpen = true; fire("MERCHANT_SHOW")
SlashCmdList.JUNKMARK("sell all"); pump(4)
check("selling junk takes only the marked twin", bags[0][2] == nil and bags[0][1] and bags[0][1].guid == "sword-B" and money == 100 and bags[0][3] and bags[0][4])
merchantOpen = false; fire("MERCHANT_CLOSED")

-- Stacks. Looting more of an item into a marked stack keeps the stack, so keeps the mark.
bags[0][3].count = 20 + 7; fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
check("a marked stack that grows keeps its mark", kind("cloth-B") == "favorite" and btn(0, 3):state() == "favorite")
-- Splitting makes a new stack, with a new GUID.
bags[0][3].count = 17; put(0, 5, "cloth-C", 5, { count = 10 }); bags[0][5].link = "[Linen Cloth]"
fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
check("splitting a marked stack: the original stays marked, the new stack starts unmarked", btn(0, 3):state() == "favorite" and kind("cloth-C") == nil and btn(0, 5):state() == "none")
-- Merging keeps the destination stack; the stack that was dragged ceases to exist.
press(0, 5); check("split-off stack can be marked on its own", kind("cloth-C") == "junk" and btn(0, 5):state() == "sell" and btn(0, 4):state() == "none")
bags[0][4].count = 30; bags[0][5] = nil; fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
check("merging a junk stack into an unmarked stack leaves the result unmarked", btn(0, 4):state() == "none" and btn(0, 5):state() == "none")
merchantOpen = true; fire("MERCHANT_SHOW")
check("the vanished stack's leftover mark is cleaned up, and nothing is offered for sale", JunkMarkDB.marked["cloth-C"] == nil and JunkMarkSellButton.text == "Sell Junk (0)")
merchantOpen = false; fire("MERCHANT_CLOSED")
relog()
check("final state survives login: one favorite stack, nothing else marked", kind("cloth-B") == "favorite" and kind("cloth-A") == nil and kind("sword-B") == nil and btn(0, 3):state() == "favorite" and btn(0, 4):state() == "none" and btn(0, 1):state() == "none")

-- Favorites whose item is gone are dropped, but only with the bank open, when everything
-- the character holds can be seen. Bags now hold cloth-B (a favorite) and little else.
local function fav(guid, order) JunkMarkDB.marked[guid] = { kind = "favorite", order = order } end
bags[6], bags.equipped = {}, {}
fav("banked", 201); put(6, 2, "banked", 1)
fav("worn", 202); put("equipped", 16, "worn", 1)
fav("lost", 203)
fav("odd", 204); elsewhere.odd = true -- no slot shows it, yet the game says the character holds it
merchantOpen = true; fire("MERCHANT_SHOW"); merchantOpen = false; fire("MERCHANT_CLOSED")
check("a vendor visit never drops a favorite", kind("lost") == "favorite" and kind("banked") == "favorite")
fire("BANKFRAME_OPENED"); fire("BANKFRAME_CLOSED"); nextFrame()
check("opening and shutting the bank before its contents arrive drops nothing", kind("lost") == "favorite")
local function lastTrace() return JunkMarkDB.trace[#JunkMarkDB.trace] end
check("...and the trace says the prune was skipped, and why", lastTrace():find("prune: skipped, the bank closed before it could be read", 1, true) ~= nil)
local realSlots = C_Container.GetContainerNumSlots; C_Container.GetContainerNumSlots = function() return 0 end
fire("BANKFRAME_OPENED"); nextFrame(); fire("BANKFRAME_CLOSED"); C_Container.GetContainerNumSlots = realSlots
check("a bank that reads as empty of slots drops nothing, and the trace says so", kind("lost") == "favorite" and lastTrace():find("prune: skipped, the bank read as 0 slots", 1, true) ~= nil)
local toldAt = #out + 1; fire("BANKFRAME_OPENED")
check("nothing is dropped the instant the bank opens", kind("lost") == "favorite"); nextFrame()
check("with the bank open, a favorite that is nowhere is dropped, and said so", kind("lost") == nil and table.concat(out, "\n", toldAt):find("Removed 1 favorite mark for item you no longer have.", 1, true) ~= nil)
check("...one in the bank, one being worn and one in the bags are kept", kind("banked") == "favorite" and kind("worn") == "favorite" and kind("cloth-B") == "favorite")
check("...and so is one the game still reports holding", kind("odd") == "favorite")
check("...and the trace accounts for every favorite", lastTrace():find("prune: 16 bank slots read, 5 favorites: 1 in bags, 2 in bank or worn, 1 held elsewhere per the game, 0 unsure, 1 dropped", 1, true) ~= nil)
local realHeld = C_Item.IsItemGUIDInInventory; C_Item.IsItemGUIDInInventory = function() error("no such item") end
fire("BANKFRAME_CLOSED"); fav("lost", 206); fire("BANKFRAME_OPENED"); nextFrame(); C_Item.IsItemGUIDInInventory = realHeld
check("a favorite the game cannot answer for is kept and counted as unsure", kind("lost") == "favorite" and lastTrace():find("2 unsure, 0 dropped", 1, true) ~= nil)
JunkMarkDB.marked.lost = nil
fire("BANKFRAME_CLOSED"); fav("lost", 205); bags[6] = {}; fire("BANKFRAME_OPENED"); nextFrame()
check("an item taken out of the bank and destroyed is dropped at the next bank visit", kind("lost") == nil and kind("banked") == nil and kind("worn") == "favorite")
fire("BANKFRAME_CLOSED"); JunkMarkDB.marked.worn, JunkMarkDB.marked.odd, elsewhere.odd = nil, nil, nil; bags[6], bags.equipped = nil, nil

-- Where Sell Junk sits: in the vendor window's tab row, beside whatever tabs are there.
-- The window spans x 100..436 with its bottom edge at y 200; tabs hang from y 202 to 170.
local function tab(right, shown) local t = { shown = shown ~= false }
  function t:IsForbidden() return false end; function t:IsShown() return self.shown end; function t:IsObjectType(kind) return kind == "Button" end
  function t:GetTop() return 202 end; function t:GetBottom() return 170 end; function t:GetRight() return right end
  return t end
local inside = tab(430); function inside:GetTop() return 260 end; function inside:GetBottom() return 215 end -- a button inside the window, not a tab
local vendorTabs = {}
function MerchantFrame:GetLeft() return 100 end; function MerchantFrame:GetBottom() return 200 end; function MerchantFrame:GetWidth() return 336 end
function MerchantFrame:GetChildren() return JunkMarkSellButton, inside, (unpack or table.unpack)(vendorTabs) end
local function openVendor(...) vendorTabs = { ... }; merchantOpen = true; fire("MERCHANT_SHOW") end
local function closeVendor() merchantOpen = false; fire("MERCHANT_CLOSED") end
local function sellSpot() local s = JunkMarkSellButton; return s.point[1] .. " " .. s.point[3] .. " " .. s.point[4] .. " " .. s.point[5] .. " w" .. s.width end
openVendor(tab(180), tab(262))
check("two tabs: Sell Junk sits in the tab row at full width", sellSpot() == "TOPRIGHT BOTTOMRIGHT -4 -2 w140")
closeVendor(); openVendor(tab(180), tab(262), tab(330))
check("a third tab from another addon: it narrows to fit beside it", sellSpot() == "TOPRIGHT BOTTOMRIGHT -4 -2 w100")
closeVendor(); openVendor(tab(180), tab(262), tab(330, false))
check("a hidden tab does not count", sellSpot() == "TOPRIGHT BOTTOMRIGHT -4 -2 w140")
closeVendor(); openVendor(tab(180), tab(262), tab(330), tab(400))
check("no room beside the tabs: it drops to a row of its own under them", sellSpot() == "TOPRIGHT BOTTOMRIGHT -4 -32 w140")
closeVendor(); openVendor(tab(180), tab(262)); vendorTabs[3] = tab(330)
check("(a tab added after the vendor opened is not seen yet)", sellSpot() == "TOPRIGHT BOTTOMRIGHT -4 -2 w140")
nextFrame(); check("...but is a frame later", sellSpot() == "TOPRIGHT BOTTOMRIGHT -4 -2 w100")
closeVendor(); vendorTabs = {}

-- Which corner the mark icon sits in. Textures are created in order: shade, coin, action, star.
local function corner(b, i) local p = b.textures[i] and b.textures[i].point; return p and p[1] end
check("mark icons sit in the bottom-left corner by default", corner(btn(0, 3), 2) == "BOTTOMLEFT" and corner(btn(0, 3), 3) == "BOTTOMLEFT" and corner(btn(0, 3), 4) == "BOTTOMLEFT")
SlashCmdList.JUNKMARK("corner topright")
check("'/jm corner' moves icons already drawn, and is saved", corner(btn(0, 3), 4) == "TOPRIGHT" and corner(btn(0, 3), 2) == "TOPRIGHT" and JunkMarkDB.corner == "topright")
press(0, 1); check("...and a newly marked item uses it", btn(0, 1):state() == "sell" and corner(btn(0, 1), 2) == "TOPRIGHT"); press(0, 1, 2)
local saidAt = #out + 1; SlashCmdList.JUNKMARK("corner middle"); SlashCmdList.JUNKMARK("corner")
check("an unknown corner changes nothing and the choices are listed", JunkMarkDB.corner == "topright" and corner(btn(0, 3), 4) == "TOPRIGHT" and table.concat(out, "\n", saidAt):find("topright corner. Change it with /jm corner <topleft, topright, bottomleft, bottomright>", 1, true) ~= nil)
relog(); check("the corner survives login", JunkMarkDB.corner == "topright" and corner(btn(0, 3), 4) == "TOPRIGHT")
SlashCmdList.JUNKMARK("corner bottomright")

-- Another bag addon (Bagnon, Baganator, EllesmereUIBags): its own window, with item
-- buttons made from the same Blizzard template. These frames are plain tables with only
-- the methods listed, so a call JunkMark has no business making fails instead of passing.
local function plain(parent)
  local f = { kids = {}, hooks = {}, shown = true }
  function f:IsForbidden() return false end
  function f:GetParent() return parent end
  function f:GetName() return self.name end
  function f:GetChildren() return (unpack or table.unpack)(self.kids) end
  function f:IsShown() return self.shown end
  function f:IsVisible() return self.shown and (parent == UIParent or parent:IsVisible()) end
  function f:HookScript(n, fn) self.hooks[n] = self.hooks[n] or {}; table.insert(self.hooks[n], fn) end
  function f:run(n) for _, fn in ipairs(self.hooks[n] or {}) do fn(self) end end
  if parent ~= UIParent then table.insert(parent.kids, f) end
  return f
end
-- Like those addons, each button sits in a holder frame of its own, and can be pointed at another slot.
local function theirButton(grid, bag, slot)
  local holder = plain(grid)
  local b = button(bag, slot); b.bag, b.slot, b.shown = bag, slot, true
  b.icon = { SetTexture = function() end, SetAtlas = function() end } -- what their addon paints the item's picture with
  function b:GetBagID() return self.bag end
  function b:GetID() return self.slot end
  function b:GetParent() return holder end
  function b:IsVisible() return self.shown and holder:IsVisible() end
  holder.kids[1] = b
  return b
end
local function ticks(n) for _ = 1, n do onUpdate(nil, 0.11) end end
local function hooked(f) return next(f.hooks) ~= nil end

local window = plain(UIParent); local grid = plain(window); window.name = "TheirBagWindow"
local T = {}; for slot = 1, 5 do T[slot] = theirButton(grid, 0, slot) end
-- bags now: (0,1) sword-B, (0,3) cloth-B favorite, (0,4) cloth-A
ticks(3)
check("another addon's buttons are left alone until the cursor finds one", not hooked(T[1]) and not hooked(T[3]) and T[3]:state() == "none")
foci = { T[1] }; ticks(1); foci = {}
check("resting the cursor on one adopts its whole window and draws the marks", hooked(T[5]) and T[3]:state() == "favorite" and T[1]:state() == "none" and T[4]:state() == "none")
check("...and Space works on that button straight away", override.SPACE == "JUNKMARK_TOGGLE")
space(); T[1]:run("OnLeave")
check("marking through their button draws on theirs and on the default one", kind("sword-B") == "junk" and T[1]:state() == "sell" and btn(0, 1):state() == "sell" and next(override) == nil)
T[4]:run("OnEnter"); check("their other buttons take Space through the hover hook", override.SPACE == "JUNKMARK_TOGGLE"); T[4]:run("OnLeave")
T[5]:run("OnEnter"); check("an empty slot of theirs does not take Space", next(override) == nil); T[5]:run("OnLeave")

-- their addon sorts: two buttons trade slots, and no game event says so
T[1].slot, T[3].slot = 3, 1
check("(stale until looked at again)", T[1]:state() == "sell" and T[3]:state() == "favorite")
ticks(3)
check("a button pointed at another slot is redrawn for what it now holds", T[1]:state() == "favorite" and T[3]:state() == "sell")

-- a bag update: their addon adds a button for a newly filled slot
put(0, 6, "gem", 50); JunkMarkDB.marked.gem = { kind = "junk", order = 50, sellOnly = true }
T[6] = theirButton(grid, 0, 6); fire("BAG_UPDATE_DELAYED")
check("a bag update is acted on a frame later, after their addon has caught up", not hooked(T[6]))
nextFrame()
check("...and then picks up the button they added", hooked(T[6]) and T[6]:state() == "sell")

-- their window is closed while a mark changes, then reopened
window.shown = false
ContainerFrameCombinedBags:UpdateItems(); press(0, 6)
check("a hidden window is not redrawn", kind("gem") == "favorite" and T[6]:state() == "sell")
window.shown = true; window:run("OnShow"); nextFrame()
check("reopening their window brings its marks up to date", T[6]:state() == "favorite")

merchantOpen = true; fire("MERCHANT_SHOW")
check("a favorite in their window gets the click blocker at a vendor", T[6]:blocked() and T[1]:blocked() and not T[3]:blocked())
merchantOpen = false; fire("MERCHANT_CLOSED")
check("...lifted when the vendor closes", not T[6]:blocked() and not T[1]:blocked())

-- their bank window uses the same buttons; bank slots are not markable
local bank = plain(UIParent); local bankSlot = theirButton(bank, 7, 1)
foci = { bankSlot }; ticks(1)
check("a bank slot under the cursor is not adopted", not hooked(bankSlot))
bankSlot = theirButton(grid, 7, 2); fire("BAG_UPDATE_DELAYED"); nextFrame(); bankSlot:run("OnEnter")
check("a bank slot inside a followed window does not take Space", hooked(bankSlot) and next(override) == nil)
local function markCount() local n = 0; for _ in pairs(JunkMarkDB.marked) do n = n + 1 end; return n end
local marksBefore = markCount(); put(1, 2, "decoy", 10) -- a real item at the slot number the bank button carries
foci = { bankSlot }; JunkMark_ToggleHovered(); foci = {}
check("...and a user-bound key does not mark it", markCount() == marksBefore and marksBefore == 3)

-- things that must not be mistaken for another addon's bag button
local stray = button(0, 4); function stray:GetParent() return ContainerFrameCombinedBags end
foci = { stray }; ticks(1)
check("a default-UI bag button is never adopted as another addon's", not hooked(stray))
local bagBar = plain(UIParent); function bagBar:GetBagID() return 0 end; function bagBar:GetID() return 1 end
foci = { bagBar }; ticks(1)
check("a frame that answers GetBagID but is not an item button is ignored", not hooked(bagBar) and next(override) == nil)
local window2 = plain(UIParent); local U = theirButton(window2, 0, 4); local glow = plain(U.GetParent(U)); function glow:GetParent() return U end
foci = { glow }; ticks(1); foci = {}
check("the cursor on a child of an unseen item button still finds the button", hooked(U) and override.SPACE == "JUNKMARK_TOGGLE")
U:run("OnLeave")

-- The next session: their window is remembered by name, so its marks need no hover.
check("a followed window with a name is remembered; one without is not", JunkMarkDB.bagWindows.TheirBagWindow == true and next(JunkMarkDB.bagWindows, "TheirBagWindow") == nil)
relog()
local again = plain(UIParent); again.name = "TheirBagWindow"; local grid2 = plain(again)
local N = {}; for slot = 1, 6 do N[slot] = theirButton(grid2, 0, slot) end
ticks(2); nextFrame()
check("(their window does not exist yet: nothing to follow)", not hooked(N[1]) and not hooked(N[3]))
TheirBagWindow = again; ticks(1)
check("once their window exists it is followed, a frame later, with no hover", not hooked(N[3]))
nextFrame()
check("...and its marks are drawn", hooked(N[3]) and N[3]:state() == "favorite" and N[6]:state() == "favorite" and N[1]:state() == "sell" and next(override) == nil)
JunkMarkDB.bagWindows.Gone = true; JunkMarkDB.bagWindows.NotAFrame = true; NotAFrame = "a string"; ticks(2)
check("a remembered name that is missing or is not a frame is harmless", true)
TheirBagWindow, NotAFrame = nil, nil

-- Gear the game refuses to disenchant although nothing says so in advance: the queue
-- button's attempt draws the game's error, and that teaches JunkMark about the item.
relog(); knowsDE = true; fire("SPELLS_CHANGED")
bags[0], bags[1] = {}, {}; JunkMarkDB.marked = {}; fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
put(0, 1, "cloak-A", 75, { quality = 2, class = 4, id = 5387 }); put(0, 2, "cloak-B", 75, { quality = 2, class = 4, id = 5387 })
put(0, 3, "belt", 40, { quality = 2, class = 4, id = 777 }); ContainerFrameCombinedBags:UpdateItems()
press(0, 1, 2); press(0, 3, 2); press(0, 2)
P, B = JunkMarkQueuePanel, JunkMarkProcessButton
check("(two items queued, the cloak first; its twin marked for the vendor)", B.head.guid == "cloak-A" and P.countText.text == "2 items queued" and btn(0, 2):state() == "sell")
fire("UI_ERROR_MESSAGE", 51, "Item cannot be disenchanted")
check("an error with no attempt behind it teaches nothing", kind("cloak-A") == "junk" and JunkMarkDB.refused == nil and JunkMarkDB.lastRefusal == nil)
B.scripts.PostClick(B, "LeftButton", false); fire("UI_ERROR_MESSAGE", 20, "Can't do that while moving")
check("an ordinary error after an attempt is recorded but teaches nothing", kind("cloak-A") == "junk" and JunkMarkDB.refused == nil and JunkMarkDB.lastRefusal.message == "Can't do that while moving" and JunkMarkDB.lastRefusal.itemID == 5387)
B.scripts.PostClick(B, "LeftButton", false); clock = clock + 5; fire("UI_ERROR_MESSAGE", 51, "Item cannot be disenchanted")
check("the game's refusal arriving long after the attempt is not tied to it", kind("cloak-A") == "junk" and JunkMarkDB.refused == nil)
local refusedAt = #out + 1
B.scripts.PostClick(B, "LeftButton", false); clock = clock + 0.3; fire("UI_ERROR_MESSAGE", 51, "Item cannot be disenchanted")
check("the game's refusal right after an attempt: the item is unmarked and remembered", kind("cloak-A") == nil and btn(0, 1):state() == "none" and JunkMarkDB.refused[13262][5387] == true and table.concat(out, "\n", refusedAt):find("can't be used with Disenchant", 1, true) ~= nil)
check("...the queue moves on to the next item", B.head.guid == "belt" and P.countText.text == "1 item queued")
check("...and its twin, marked for the vendor, keeps that mark", kind("cloak-B") == "junk" and btn(0, 2):state() == "sell")
press(0, 2); check("that kind of item no longer has a disenchant step: vendor junk -> favorite", kind("cloak-B") == "favorite")
press(0, 2); press(0, 1); press(0, 1); check("...on either copy", kind("cloak-A") == "favorite" and P.countText.text == "1 item queued")
relog(); P, B = JunkMarkQueuePanel, JunkMarkProcessButton
press(0, 1); press(0, 1); press(0, 1)
check("what was learned survives login", JunkMarkDB.refused[13262][5387] == true and kind("cloak-A") == "favorite" and B.head.guid == "belt")

-- What this client really says for such an item is a generic message whose string name is not known yet.
-- two of the client's strings hold this text; a third global with the same value is not a game string
ERR_INVALID_ITEM_TARGET, SPELL_FAILED_WRONG_ARTIFACT_EQUIPPED, another_value = "That item is not a valid target.", "That item is not a valid target.", "That item is not a valid target."
put(0, 4, "moonstalker", 0, { quality = 2, class = 4, noValue = true, id = 9001 }); ContainerFrameCombinedBags:UpdateItems()
press(0, 3, 2); press(0, 4)
check("(unsellable gear is queued on the first press, and is now next)", B.head.guid == "moonstalker" and kind("belt") == nil)
B.scripts.PostClick(B, "LeftButton", true); fire("UI_ERROR_MESSAGE", 414, "That item is not a valid target.")
check("'not a valid target' after an attempt is final too", kind("moonstalker") == nil and JunkMarkDB.refused[13262][9001] == true and not P.shown)
local trace = table.concat(JunkMarkDB.trace, "\n")
check("the trace shows the click, the game's answer and what was learned", trace:find("click LeftButton down head 9001", 1, true) ~= nil and trace:find("error 414 That item is not a valid target.", 1, true) ~= nil and trace:find("learned: item 9001 refused for Disenchant", 1, true) ~= nil)
check("...and the mark key's steps, with why", trace:find("mark key: item 9001 -> junk  [can be queued] [no sell value]", 1, true) ~= nil and #JunkMarkDB.trace <= 80)
check("...and the name of the game string that holds the text is recorded", #JunkMarkDB.lastRefusal.globals == 2 and JunkMarkDB.lastRefusal.globals[1] == "ERR_INVALID_ITEM_TARGET" and JunkMarkDB.lastRefusal.globals[2] == "SPELL_FAILED_WRONG_ARTIFACT_EQUIPPED" and JunkMarkDB.lastRefusal.errorType == 414 and JunkMarkDB.lastRefusal.lookupError == nil)
check("...as is how many times the queue button has been clicked to process an item", JunkMarkDB.attempts == 4)
press(0, 4); check("refused gear nobody buys now skips junk: none -> favorite", kind("moonstalker") == "favorite")
press(0, 4); SlashCmdList.JUNKMARK("forget"); press(0, 4)
check("'/jm forget' lets a refused item be queued again", JunkMarkDB.refused == nil and kind("moonstalker") == "junk" and B.head.guid == "moonstalker")
shift = true; B.scripts.PostClick(B, "RightButton", false); shift = false
check("Shift-right-click on gear nobody buys unmarks it and teaches nothing", kind("moonstalker") == nil and JunkMarkDB.refused == nil)
press(0, 4); B.scripts.PostClick(B, "RightButton", true); fire("UI_ERROR_MESSAGE", 414, "That item is not a valid target.")
check("a right-click is an attempt like a left-click: the game's refusal after it is learned", kind("moonstalker") == nil and JunkMarkDB.refused[13262][9001] == true and JunkMarkDB.attempts == 5)
check("...and the trace names the buttons", table.concat(JunkMarkDB.trace, "\n"):find("click Shift-RightButton up head 9001", 1, true) ~= nil and table.concat(JunkMarkDB.trace, "\n"):find("click RightButton down head 9001", 1, true) ~= nil)
-- a client in another language words the refusal differently; it is the string's name that is matched
ERR_INVALID_ITEM_TARGET = "Dieser Gegenstand ist kein gueltiges Ziel."
SlashCmdList.JUNKMARK("forget"); press(0, 4); B.scripts.PostClick(B, "LeftButton", true); fire("UI_ERROR_MESSAGE", 414, "Dieser Gegenstand ist kein gueltiges Ziel.")
check("the refusal is recognised by the name of the game's string, so in any language", kind("moonstalker") == nil and JunkMarkDB.refused[13262][9001] == true)
ERR_INVALID_ITEM_TARGET, SPELL_FAILED_WRONG_ARTIFACT_EQUIPPED = nil, nil
SlashCmdList.JUNKMARK("forget"); press(0, 4); B.scripts.PostClick(B, "LeftButton", true); fire("UI_ERROR_MESSAGE", 414, "That item is not a valid target.")
check("...and the English words alone, with no game string behind them, teach nothing", kind("moonstalker") == "junk" and JunkMarkDB.refused == nil)
shift = true; B.scripts.PostClick(B, "RightButton", false); shift = false
press(0, 3, 2)
another_value = nil

-- /jm debug writes what the game reports about each junk-marked item into the saved data
press(0, 2); SlashCmdList.JUNKMARK("debug")
local dump = JunkMarkDB.debug
check("'/jm debug' records each junk-marked item with the facts that decide its routing", #dump.items == 2 and type(dump.when) == "string")
local byID = {}; for _, it in ipairs(dump.items) do byID[it.itemID] = it end
check("...including where it is routed and its tooltip lines", byID[777].routedTo == "Disenchant" and byID[5387].routedTo == "sell" and byID[5387].sellOnly == true and byID[777].classID == 4 and byID[777].quality == 2 and byID[777].tooltip[2] == "Binds when picked up")
relog(); check("...and the dump survives the trip to disk", #JunkMarkDB.debug.items == 2)

--------------------------------------------------------------------------------
-- Other bag addons: a mark follows its item with no wait, and some need no hover
--------------------------------------------------------------------------------
do
bags[0], bags[1] = {}, {}; JunkMarkDB = nil; knowsDE = false; money = 0
relog()
put(0, 1, "axe", 100, { class = 2 }); put(0, 2, "boots", 60, { class = 4 }); put(0, 3, "gray-tooth", 10, { quality = 0 }); put(0, 4, "ring", 80)
fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
press(0, 2); press(0, 4, 2)

local win = plain(UIParent); win.name = "AnotherBagWindow"; local pane = plain(win)
local R = {}; for slot = 1, 5 do R[slot] = theirButton(pane, 0, slot) end
foci = { R[1] }; ticks(1); foci = {}; R[1]:run("OnLeave")
check("(their window is adopted and drawn: boots junk, ring favorite)", R[2]:state() == "sell" and R[4]:state() == "favorite")

-- Their addon sorts. It points each button at its new slot, then paints the new item's icon.
R[2].slot, R[4].slot = 4, 2; R[2].icon:SetTexture("icon"); R[4].icon:SetTexture("icon")
check("a button given another slot's icon is redrawn there and then, with no wait", R[2]:state() == "favorite" and R[4]:state() == "sell")
R[2].slot = 5; R[2].icon:SetAtlas("empty-slot")
check("a button emptied with an atlas background is redrawn at once too", R[2]:state() == "none")
R[2].icon:SetTexture("icon"); R[2].slot = 4
local early = R[2]:state(); onUpdate(nil, 0)
check("an addon that sets the icon before the slot is put right before the frame is drawn", early == "none" and R[2]:state() == "favorite")
R[5]:run("OnEnter"); R[5].slot = 1; R[5].icon:SetTexture("icon")
local beforeFrame = next(override) == nil; onUpdate(nil, 0)
check("a button under a resting cursor that is given an item takes Space as the frame ends", beforeFrame and override.SPACE == "JUNKMARK_TOGGLE")
R[5]:run("OnLeave"); R[5].slot = 5
win.shown = false; R[2].slot = 2; R[2].icon:SetTexture("icon"); onUpdate(nil, 0)
check("a hidden button is not drawn on", R[2]:state() == "favorite")
win.shown = true; win:run("OnShow"); nextFrame()
check("...and is brought up to date when its window is shown", R[2]:state() == "sell")

-- BetterBags and Bagnon give their item buttons numbered global names.
local bb0, bb1 = theirButton(plain(UIParent), 0, 2), theirButton(plain(UIParent), 0, 4)
BetterBagsItemButton0, BetterBagsItemButton1 = bb0, bb1
local cached = false
local bagnon = theirButton(plain(UIParent), 0, 4); function bagnon:IsCached() return cached end
BagBrotherContainerItem1 = bagnon
check("(buttons known by name are untouched until looked for)", not hooked(bb0) and not hooked(bagnon))
ticks(3)
check("buttons with numbered names are adopted and drawn with no hover, counting from 0 or from 1", bb0:state() == "sell" and bb1:state() == "favorite" and bagnon:state() == "favorite")
check("...and none of them is remembered as a window", JunkMarkDB.bagWindows.AnotherBagWindow == true and next(JunkMarkDB.bagWindows, "AnotherBagWindow") == nil)
BetterBagsItemButton2 = theirButton(plain(UIParent), 0, 2); fire("BAG_UPDATE_DELAYED"); nextFrame()
check("one created later is picked up at the next bag update", BetterBagsItemButton2:state() == "sell")
cached = true; bagnon.icon:SetTexture("icon"); bagnon:run("OnEnter")
check("Bagnon showing another character's bags: nothing is drawn and Space is not taken", bagnon:state() == "none" and next(override) == nil)
bagnon:run("OnLeave"); cached = false; bagnon.icon:SetTexture("icon")
check("...and the mark is back when it shows this character's bags again", bagnon:state() == "favorite")

-- ElvUI's bag window has a fixed global name.
local elv = plain(UIParent); elv.name = "ElvUI_ContainerFrame"; local E1 = theirButton(plain(elv), 0, 2)
ElvUI_ContainerFrame = elv; ticks(1); nextFrame()
check("a bag window known by name is followed with no hover, and is not saved as remembered", hooked(E1) and E1:state() == "sell" and JunkMarkDB.bagWindows.ElvUI_ContainerFrame == nil)

-- What other addons can ask, and /jm check with nothing else installed.
check("the API reads marks by bag and slot", JunkMarkAPI.GetMark(0, 4) == "favorite" and JunkMarkAPI.IsFavorite(0, 4) and JunkMarkAPI.IsJunk(0, 2) and JunkMarkAPI.GetMark(0, 1) == nil and JunkMarkAPI.GetMark(0, 8) == nil)
check("the API answers by item ID while a copy is a favorite", JunkMarkAPI.IsItemFavorite("ring") and not JunkMarkAPI.IsItemFavorite("axe"))
local changes = 0
JunkMarkAPI.OnChanged(function() changes = changes + 1 end)
JunkMarkAPI.OnChanged(function() error("listener blew up") end)
press(0, 1)
check("a mark change reaches listeners, and one that errors stops nothing", changes == 1 and kind("axe") == "junk" and #caught == 1 and caught[1]:find("listener blew up", 1, true) ~= nil)
press(0, 1, 2)
local from = #out + 1; SlashCmdList.JUNKMARK("check"); local report = table.concat(out, "\n", from)
check("/jm check names the windows followed and finds no sellers", report:find("following AnotherBagWindow, ElvUI_ContainerFrame", 1, true) and report:find("no other addon that sells junk", 1, true))
ElvUI_ContainerFrame, BetterBagsItemButton0, BetterBagsItemButton1, BetterBagsItemButton2, BagBrotherContainerItem1 = nil
end

--------------------------------------------------------------------------------
-- Other addons that sell junk, and Baganator's junk source
--
-- These fakes copy only the calls JunkMark makes, as read in each addon's code. A
-- pass shows JunkMark's side matches that reading. It says nothing about whether the
-- reading is right, or about how the real addons behave.
--------------------------------------------------------------------------------
do
caught = {}
local bgr = { refreshes = 0, junkActive = true }
Baganator = { API = {
  RegisterJunkPlugin = function(label, id, callback) assert(label == "JunkMark" and id == "junkmark"); bgr.junk = callback end,
  RequestItemButtonsRefresh = function() bgr.refreshes = bgr.refreshes + 1 end,
  IsJunkPluginActive = function(id) assert(id == "junkmark"); return bgr.junkActive end,
} }
EUI_CategoryManager = { markerOn = true }
function EUI_CategoryManager:IsJunk(itemID, quality) assert(self == EUI_CategoryManager and itemID); return quality == 0 end
function EUI_CategoryManager:IsJunkMarkerEnabled() return self.markerOn end
EUI_Bags = { SellJunk = function() end }
EllesmereUIDB = {}
local rxp = { inventoryManager = {} }
function rxp.inventoryManager:IsJunk(id) assert(self == rxp.inventoryManager and id); return true end
local bbSeller = {}
function bbSeller:StillThere(data, forSale) assert(self == bbSeller and data and forSale ~= nil); return 1 end
aceAddons.RXPGuides = rxp
aceAddons.BetterBags = { GetModule = function(_, name, silent) assert(name == "Seller" and silent == true); return bbSeller end }
LibStub = setmetatable({}, { __call = function(_, name, silent)
  assert(name == "AceAddon-3.0" and silent == true)
  return { GetAddon = function(_, addon, quiet) assert(quiet == true); return aceAddons[addon] end }
end })
Scrap = {}
function Scrap:IsJunk(id) assert(self == Scrap and id); return true end
SellJunk = { exceptions = { ring = true } }
function SellJunk:CheckItemIsJunk(link) assert(self == SellJunk and link); return true end
function SellJunk:isException(item) assert(self == SellJunk); return self.exceptions[item.itemID] == true end
-- How that version of SellJunk decides, copied from its Sell: gray and not an exception, or an exception that is not gray.
local function sellJunkSells(item) local gray = item.quality == 0; local ex = SellJunk:isException(item); return (gray and not ex) or ((not gray) and ex) end
DejunkApi = { junk = {} }
function DejunkApi:IsJunk(bag, slot) assert(self == DejunkApi); return self.junk[bag * 100 + slot] == true end
Vendor = { sell = {} }
Vendor.EvaluateItem = function(bag, slot) if bag == 1 and slot == 8 then error("vendor blew up") end; return Vendor.sell[bag * 100 + slot] and 2 or 0 end
LeaPlusDB = { AutoSellJunk = "Off" }
AutoSellGreyItems = true
C_MerchantFrame = { IsSellAllJunkEnabled = function() return true end }
loaded.EllesmereUIQoL, loaded.Peddler = true, true
relog()
-- bags: (0,1) axe, (0,2) boots junk, (0,3) gray-tooth, (0,4) ring favorite

local quiet = #out
check("Baganator's junk source, junk being manual: marked junk only, not an unmarked gray, a favorite or a plain item", bgr.junk(0, 2) == true and bgr.junk(0, 3) == false and bgr.junk(0, 4) == false and bgr.junk(0, 1) == false)
local asked = bgr.refreshes; press(0, 1)
check("a mark change asks Baganator to look again", bgr.refreshes == asked + 1 and bgr.junk(0, 1) == true)
press(0, 1, 2)

check("EllesmereUI's junk test: an item with a favorite copy is not junk, another gray still is", EUI_CategoryManager:IsJunk("ring", 0) == false and EUI_CategoryManager:IsJunk("gray-tooth", 0) == true)
check("RestedXP's junk test: not the favorite, by slot or by item ID; anything else as before",
  rxp.inventoryManager:IsJunk("ring", 0, 4) == false and rxp.inventoryManager:IsJunk("ring") == false
  and rxp.inventoryManager:IsJunk("axe", 0, 1) == true and rxp.inventoryManager:IsJunk("axe") == true)
check("Scrap: a favorite's slot is not junk; other slots, and its own list edits by item ID, are as before", Scrap:IsJunk("ring", 0, 4) == false and Scrap:IsJunk("axe", 0, 1) == true and Scrap:IsJunk("ring") == true)
check("BetterBags: a favorite is skipped when selling, and only then",
  bbSeller:StillThere({ bagid = 0, slotid = 4 }, true) == nil and bbSeller:StillThere({ bag = 0, slot = 4 }, true) == nil
  and bbSeller:StillThere({ bag = 0, slot = 4 }, false) == 1 and bbSeller:StillThere({ bag = 0, slot = 1 }, true) == 1)
check("SellJunk, asked by slot: a favorite is not junk", SellJunk:CheckItemIsJunk("[ring]", 0, 4) == false and SellJunk:CheckItemIsJunk("[axe]", 0, 1) == true)

put(0, 7, "twin-1", 20, { id = "twin" }); put(0, 8, "twin-2", 20, { id = "twin" }); fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
press(0, 7, 2)
check("with two copies: by item ID one favorite protects both, by slot only the favorite", kind("twin-1") == "favorite"
  and EUI_CategoryManager:IsJunk("twin", 0) == false and rxp.inventoryManager:IsJunk("twin", 0, 7) == false and rxp.inventoryManager:IsJunk("twin", 0, 8) == true)
press(0, 7)
check("unmarking lifts the protection", EUI_CategoryManager:IsJunk("twin", 0) == true and rxp.inventoryManager:IsJunk("twin", 0, 7) == true)
press(0, 7, 2); local whileCarried = EUI_CategoryManager:IsJunk("twin", 0)
bags[0][7] = nil; fire("BAG_UPDATE_DELAYED")
check("a favorite that leaves the bags stops protecting its item ID", whileCarried == false and EUI_CategoryManager:IsJunk("twin", 0) == true)
check("favoriting items no other addon wants printed nothing", #out == quiet)

-- Sellers of every gray item, which can only be warned about
put(0, 5, "gray-fav", 5, { quality = 0 }); put(1, 2, "gray-two", 5, { quality = 0 }); put(1, 3, "gray-three", 5, { quality = 0 })
fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
local from = #out + 1; press(0, 5, 2); local said = table.concat(out, "\n", from)
check("Peddler is warned about when a gray item is favorited", kind("gray-fav") == "favorite" and #out == from and said:find("Peddler sells every gray item", 1, true))
from = #out + 1; press(1, 2, 2)
check("the same seller is warned about once a session", kind("gray-two") == "favorite" and #out == from - 1)
LeaPlusDB.AutoSellJunk = "On"; EUI_CategoryManager.markerOn = false
press(1, 3, 2); said = table.concat(out, "\n", from)
check("Leatrix Plus, and EllesmereUI selling outside its junk marker, are warned about as well", #out == from + 1
  and said:find("Leatrix Plus sells every gray item", 1, true) and said:find("EllesmereUI's Auto Sell Junk sells every gray item", 1, true))
check("SellJunk, asked by item: a favorite on its sell list is kept, a gray favorite is kept, other grays still sell",
  sellJunkSells({ itemID = "ring", quality = 1 }) == false and sellJunkSells({ itemID = "gray-fav", quality = 0 }) == false
  and sellJunkSells({ itemID = "gray-tooth", quality = 0 }) == true)
press(0, 4)
check("SellJunk: its own answer returns once the item is no longer a favorite", sellJunkSells({ itemID = "ring", quality = 1 }) == true)
press(0, 4, 2)

-- Addons that cannot be stopped but can be asked
put(0, 6, "odd-gem", 300); put(1, 8, "far-gem", 300); fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
DejunkApi.junk[6], Vendor.sell[6] = true, true
from = #out + 1; press(0, 6, 2); said = table.concat(out, "\n", from)
check("a favorite that Dejunk or Vendor counts as junk is warned about by name", #out == from + 1
  and said:find("Dejunk counts this item as junk", 1, true) and said:find("Vendor counts this item as junk", 1, true))
from = #out + 1; press(1, 8, 2)
check("an error inside the addon being asked is not JunkMark's error and warns of nothing", kind("far-gem") == "favorite" and #out == from - 1)

from = #out + 1; SlashCmdList.JUNKMARK("check"); said = table.concat(out, "\n", from)
check("/jm check names every seller found and what was done about it",
  said:find("follow JunkMark", 1, true) and said:find("EllesmereUI's junk marker: guarded", 1, true) and said:find("RestedXP's inventory manager: guarded", 1, true)
  and said:find("Scrap: guarded", 1, true) and said:find("BetterBags' selling: guarded", 1, true) and said:find("SellJunk: guarded", 1, true)
  and said:find("Dejunk|r cannot be guarded, and counts 1 of your favorites", 1, true) and said:find("Vendor|r cannot be guarded, and counts 1 of your favorites", 1, true)
  and said:find("Peddler", 1, true) and said:find("Leatrix Plus", 1, true))
bgr.junkActive = false
from = #out + 1; SlashCmdList.JUNKMARK("check"); said = table.concat(out, "\n", from)
check("/jm check says when Baganator follows another junk source", said:find("follow another junk source", 1, true))
check("the game's own Sell All Junk button is never mentioned: leaving it alone was decided", not table.concat(out, "\n"):find("Sell All Junk", 1, true))
if #caught > 0 then io.write("listener error: ", caught[1], "\n") end
check("no listener raised an error", #caught == 0)
end

--------------------------------------------------------------------------------
-- What counts as junk: manual (only what is marked) or automatic (gray items too)
--------------------------------------------------------------------------------
do
caught = {}
Scrap, SellJunk, DejunkApi, Vendor, LeaPlusDB, EUI_CategoryManager, EUI_Bags, EllesmereUIDB, AutoSellGreyItems = nil
loaded.EllesmereUIQoL, loaded.Peddler, aceAddons.RXPGuides, aceAddons.BetterBags = nil, nil, nil, nil
local bgr = { refreshes = 0 }
Baganator = { API = {
  RegisterJunkPlugin = function(_, _, callback) bgr.junk = callback end,
  RequestItemButtonsRefresh = function() bgr.refreshes = bgr.refreshes + 1 end,
  IsJunkPluginActive = function() return true end,
} }
bags[0], bags[1] = {}, {}; JunkMarkDB = nil; knowsDE = false; money = 0
relog()
-- bags: (0,1) tooth, (0,2) fang, (0,5) hide are gray and sell; (0,3) dust is gray with no price; (0,4) sword is not gray
put(0, 1, "tooth", 7, { quality = 0 }); put(0, 2, "fang", 9, { quality = 0 }); put(0, 3, "dust", 0, { quality = 0, noValue = true })
put(0, 4, "sword", 100); put(0, 5, "hide", 3, { quality = 0 })
fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
local function marks() local n = 0; for _ in pairs(JunkMarkDB.marked) do n = n + 1 end; return n end
local function states(...) local t = {}; for _, s in ipairs({ ... }) do t[#t + 1] = btn(0, s):state() end; return table.concat(t, " ") end

check("a new save is manual: a gray item is not junk until it is marked", JunkMarkDB.mode == nil and states(1, 2, 3, 4, 5) == "none none none none none"
  and bgr.junk(0, 1) == false and JunkMarkAPI.IsJunk(0, 1) == false)
local from = #out + 1; SlashCmdList.JUNKMARK("mode"); SlashCmdList.JUNKMARK("mode sideways")
check("/jm mode says which it is, and an unknown mode changes nothing", JunkMarkDB.mode == nil and #out == from + 1
  and out[from]:find("Junk is manual", 1, true) and out[from + 1]:find("Junk is manual", 1, true))

local asked = bgr.refreshes; from = #out + 1; SlashCmdList.JUNKMARK("mode auto"); nextFrame()
check("/jm mode auto: gray items a vendor buys are junk at once, with no mark stored", JunkMarkDB.mode == "auto" and marks() == 0 and states(1, 2, 3, 4, 5) == "sell sell none none sell")
check("...the player is told how many, and Baganator is asked to look again", out[from]:find("3 in your bags now", 1, true) and bgr.refreshes == asked + 1)
check("...and Baganator and the API get the same answer the bags show", bgr.junk(0, 1) == true and bgr.junk(0, 3) == false and bgr.junk(0, 4) == false
  and JunkMarkAPI.GetMark(0, 2) == "junk" and JunkMarkAPI.GetMark(0, 4) == nil)

press(0, 1); local s1, k1, j1 = btn(0, 1):state(), kind("tooth"), bgr.junk(0, 1)
press(0, 1); local s2, k2, j2 = btn(0, 1):state(), kind("tooth"), bgr.junk(0, 1)
check("Space on automatic junk: favorite, then not junk, which is a mark of its own", s1 == "favorite" and k1 == "favorite" and j1 == false
  and s2 == "none" and k2 == "keep" and j2 == false and JunkMarkAPI.GetMark(0, 1) == nil)
press(0, 1)
check("...and once more makes it junk again by removing that mark", kind("tooth") == nil and btn(0, 1):state() == "sell" and bgr.junk(0, 1) == true)
press(0, 4); local w1 = kind("sword"); press(0, 4); local w2 = kind("sword"); press(0, 4)
check("an item that is not gray cycles as it always did", w1 == "junk" and w2 == "favorite" and kind("sword") == nil and btn(0, 4):state() == "none")
press(0, 3); local d1 = kind("dust"); press(0, 3)
check("a gray item no vendor buys is not automatic junk, and cycles as it always did", d1 == "favorite" and kind("dust") == nil and btn(0, 3):state() == "none")
local trace = table.concat(JunkMarkDB.trace, "\n")
check("the trace names the two new steps", trace:find("mark key: item tooth -> not junk", 1, true) and trace:find("mark key: item tooth -> automatic junk", 1, true))

press(0, 1, 2) -- tooth: not junk
merchantOpen = true; fire("MERCHANT_SHOW")
from = #out + 1; SlashCmdList.JUNKMARK("list")
check("the vendor button and /jm list count automatic junk, and not the item held out of it", JunkMarkSellButton.text == "Sell Junk (2)" and out[from]:find("2 junk items to sell, worth 12c", 1, true))
from = #out + 1; local before = money; SlashCmdList.JUNKMARK("sell"); pump(8)
check("Sell Junk sells automatic junk and leaves the item set to not junk", money - before == 12 and bags[0][2] == nil and bags[0][5] == nil
  and bags[0][1] ~= nil and bags[0][4] ~= nil and table.concat(out, "\n", from):find("Sold 2 items for 12c.", 1, true))
put(0, 2, "fang-2", 9, { quality = 0 }); put(0, 5, "hide-2", 3, { quality = 0 }); fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
before = money; SlashCmdList.JUNKMARK("sell") -- sends the last item in the queue at once
JunkMarkDB.marked["fang-2"] = { kind = "keep" }; pump(8)
check("an item set to not junk while a sale is running is not sold", money - before == 3 and bags[0][2] ~= nil and bags[0][5] == nil)
merchantOpen = false; fire("MERCHANT_CLOSED")

relog()
check("the mode and the not-junk marks survive a login", JunkMarkDB.mode == "auto" and kind("tooth") == "keep" and kind("fang-2") == "keep" and states(1, 2) == "none none")
put(0, 6, "claw", 4, { quality = 0 }); fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
check("a gray item looted later is junk without being touched", btn(0, 6):state() == "sell" and kind("claw") == nil)

SlashCmdList.JUNKMARK("mode manual")
check("/jm mode manual: nothing is junk unless marked; the not-junk marks are kept but mean nothing", JunkMarkDB.mode == "manual" and btn(0, 6):state() == "none"
  and kind("tooth") == "keep" and bgr.junk(0, 6) == false)
press(0, 1)
check("...so Space on such an item marks it junk as on any other", kind("tooth") == "junk" and btn(0, 1):state() == "sell")
SlashCmdList.JUNKMARK("mode auto"); press(0, 1); local e1 = kind("tooth"); press(0, 1); local e2 = kind("tooth"); press(0, 1)
check("a gray item marked by hand takes the same steps once junk is automatic", e1 == "favorite" and e2 == "keep" and kind("tooth") == nil and btn(0, 1):state() == "sell")

-- Not-junk marks are pruned like favorites: only at the bank, only when the item is nowhere.
bags[6], bags.equipped = {}, {}
JunkMarkDB.marked.gone = { kind = "keep" }; JunkMarkDB.marked.stashed = { kind = "keep" }; put(6, 1, "stashed", 2, { quality = 0 })
JunkMarkDB.marked.mailed = { kind = "keep" }; elsewhere.mailed = true -- no slot shows it, yet the game says the character holds it
merchantOpen = true; fire("MERCHANT_SHOW"); merchantOpen = false; fire("MERCHANT_CLOSED")
check("a vendor visit never drops a not-junk mark", kind("gone") == "keep" and kind("stashed") == "keep")
-- The game's own answer is made to know nothing of bags or bank here, so that seeing
-- the item in the bank and asking the game are each shown to matter by themselves.
local realHeld = C_Item.IsItemGUIDInInventory; C_Item.IsItemGUIDInInventory = function(guid) return elsewhere[guid] == true end
from = #out + 1; fire("BANKFRAME_OPENED"); nextFrame(); C_Item.IsItemGUIDInInventory = realHeld
check("at the bank a not-junk mark whose item is nowhere is dropped, without a chat line", kind("gone") == nil and #out == from - 1)
check("...one seen in the bank, one in the bags and one the game still reports holding are kept", kind("stashed") == "keep" and kind("fang-2") == "keep" and kind("mailed") == "keep")
check("...and the trace counts them", JunkMarkDB.trace[#JunkMarkDB.trace]:find("prune: 4 not-junk marks, 1 dropped", 1, true))
fire("BANKFRAME_CLOSED"); bags[6], bags.equipped = nil, nil; elsewhere.mailed = nil

from = #out + 1; SlashCmdList.JUNKMARK("clear")
check("/jm clear in automatic mode says the held-out items are junk again", marks() == 0 and btn(0, 2):state() == "sell" and out[from]:find("junk again", 1, true))
if #caught > 0 then io.write("listener error: ", caught[1], "\n") end
check("no listener raised an error", #caught == 0)
end

--------------------------------------------------------------------------------
-- One coin in Baganator's window, and the game's own Sell All Junk button
--
-- Both fakes copy what was read in the real code: a Baganator item button carries a
-- BGR table and the bag template's JunkIcon; the game's button has an Icon, and
-- MerchantFrame_Update enables it by the game's own count of gray items.
--------------------------------------------------------------------------------
do
caught = {}
local bgr = { active = true }
Baganator = { API = {
  RegisterJunkPlugin = function() end, RequestItemButtonsRefresh = function() end,
  IsJunkPluginActive = function() return bgr.active end,
} }
local grays, motion, countText = 0, nil, widget()
MerchantSellAllJunkButton = widget(); MerchantSellAllJunkButton.Icon = widget()
function MerchantSellAllJunkButton.Icon:SetDesaturated(v) self.gray = v end
function MerchantSellAllJunkButton:SetMotionScriptsWhileDisabled(v) motion = v end
function MerchantSellAllJunkButton:CreateFontString() return countText end
MerchantFrame_Update = function() MerchantSellAllJunkButton.Icon:SetDesaturated(grays == 0); MerchantSellAllJunkButton:SetEnabled(grays > 0) end
C_MerchantFrame = { IsSellAllJunkEnabled = function() return true end, SellAllJunkItems = function() error("the game's own sale ran") end }
bags[0], bags[1] = {}, {}; JunkMarkDB = nil; knowsDE = false; money = 0
relog()
-- bags: (0,1) tooth and (0,4) rock are unmarked grays, (0,2) vase is marked junk, (0,3) charm is a gray favorite
put(0, 1, "tooth", 7, { quality = 0 }); put(0, 2, "vase", 50); put(0, 3, "charm", 20, { quality = 0 }); put(0, 4, "rock", 5, { quality = 0 })
fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()
press(0, 2); press(0, 3, 2)

local function coin(alpha) local c = { alpha = alpha or 1 }; function c:SetAlpha(a) self.alpha = a end; return c end
local win = plain(UIParent); win.name = "TheirJunkCoinWindow"; local pane = plain(win)
local G = {}; for slot = 1, 4 do G[slot] = theirButton(pane, 0, slot); G[slot].BGR = {}; G[slot].JunkIcon = coin() end
local win2 = plain(UIParent); win2.name = "SomeOtherBags"; local O = theirButton(plain(win2), 0, 2); O.JunkIcon = coin(0.5) -- no BGR: not Baganator's
foci = { G[1] }; ticks(1); foci = { O }; ticks(1); foci = {}; G[1]:run("OnLeave"); O:run("OnLeave")
check("in Baganator's window, with JunkMark as its junk source, Baganator's own coin is invisible on every button and JunkMark's is drawn",
  G[1].JunkIcon.alpha == 0 and G[2].JunkIcon.alpha == 0 and G[4].JunkIcon.alpha == 0 and G[2]:state() == "sell" and G[3]:state() == "favorite")
check("another bag addon's coin is left exactly as that addon has it", O.JunkIcon.alpha == 0.5 and O:state() == "sell")
bgr.active = false; G[2].icon:SetTexture("icon"); G[3].icon:SetTexture("icon")
check("when the player picks another junk source in Baganator, its coin shows again as each button repaints", G[2].JunkIcon.alpha == 1 and G[3].JunkIcon.alpha == 1 and G[1].JunkIcon.alpha == 0)
bgr.active = true; G[2].icon:SetTexture("icon")
check("...and goes again when JunkMark is picked", G[2].JunkIcon.alpha == 0)
G[4].JunkIcon = nil; G[4].icon:SetTexture("icon")
check("a Baganator button with no coin of its own is drawn as usual", G[4]:state() == "none" and #caught == 0)

grays = 2; merchantOpen = true; fire("MERCHANT_SHOW")
check("where the game shows its own Sell All Junk button, JunkMark adds none and takes that one over", JunkMarkSellButton == nil and motion == true
  and type(MerchantSellAllJunkButton.scripts.OnClick) == "function" and type(MerchantSellAllJunkButton.scripts.OnEnter) == "function")
grays = 0; MerchantFrame_Update()
check("it is lit by what JunkMark would sell, with the count on it, after the game has set it by its own count of grays",
  MerchantSellAllJunkButton.enabled == true and MerchantSellAllJunkButton.Icon.gray == false and countText.text == "1")
local tip = {}; function GameTooltip:AddLine(text) tip[#tip + 1] = text end
MerchantSellAllJunkButton.scripts.OnEnter(MerchantSellAllJunkButton); local said = table.concat(tip, "\n")
check("its tooltip is JunkMark's, and says whose sale the button now runs", said:find("Sell marked junk", 1, true) and said:find("1 item worth 50c", 1, true) and said:find("JunkMark sells from this button", 1, true))
local before = money; MerchantSellAllJunkButton.scripts.OnClick(MerchantSellAllJunkButton, "LeftButton"); pump(8)
check("a click runs JunkMark's sale: the marked item, not the unmarked grays, not the gray favorite", money - before == 50 and bags[0][2] == nil
  and bags[0][1] ~= nil and bags[0][3] ~= nil and bags[0][4] ~= nil)
grays = 3; MerchantFrame_Update()
check("with nothing JunkMark would sell the button is gray, though the game counts gray items", MerchantSellAllJunkButton.enabled == false
  and MerchantSellAllJunkButton.Icon.gray == true and countText.text == "")
SlashCmdList.JUNKMARK("mode auto"); grays = 0; MerchantFrame_Update()
check("with junk automatic the same button counts the gray items, but not the favorite", MerchantSellAllJunkButton.enabled == true and countText.text == "2")
before = money; MerchantSellAllJunkButton.scripts.OnClick(MerchantSellAllJunkButton, "LeftButton"); pump(8)
check("...and sells them, keeping the gray favorite the game's own sale would have taken", money - before == 12 and bags[0][3] ~= nil and bags[0][1] == nil and bags[0][4] == nil)
local from = #out + 1; SlashCmdList.JUNKMARK("check"); said = table.concat(out, "\n", from)
check("/jm check says the game's button runs JunkMark's sale, and that Baganator's coin is hidden", said:find("Sell All Junk button runs JunkMark's sale", 1, true) and said:find("own junk coin is hidden", 1, true))
merchantOpen = false; fire("MERCHANT_CLOSED")

MerchantSellAllJunkButton = nil; relog(); merchantOpen = true; fire("MERCHANT_SHOW")
check("a client with no Sell All Junk button gets JunkMark's own button, as before", JunkMarkSellButton ~= nil and JunkMarkSellButton.text == "Sell Junk (0)")
merchantOpen = false; fire("MERCHANT_CLOSED")
C_MerchantFrame.IsSellAllJunkEnabled = function() return false end; MerchantSellAllJunkButton = widget(); relog(); merchantOpen = true; fire("MERCHANT_SHOW")
check("...and so does one where the game has that button switched off, which is then not touched", JunkMarkSellButton ~= nil and MerchantSellAllJunkButton.scripts.OnClick == nil)
merchantOpen = false; fire("MERCHANT_CLOSED"); MerchantSellAllJunkButton, MerchantFrame_Update = nil, nil
if #caught > 0 then io.write("listener error: ", caught[1], "\n") end
check("no listener raised an error", #caught == 0)
end

--------------------------------------------------------------------------------
-- EnhanceQoL: its exclusion list answers for favorites
--
-- The fake copies the one thing read in EnhanceQoL 13.23.0 that the guard rests on:
-- each of its sellers and deleters looks the item ID up in
-- EnhanceQoL.db.vendorExcludeSellList and leaves the item alone when that is set.
--------------------------------------------------------------------------------
do
caught = {}
Baganator, MerchantSellAllJunkButton = nil, nil
C_MerchantFrame = { IsSellAllJunkEnabled = function() return false end }
local list = { listed = "Listed Thing" }
EnhanceQoL = { db = { vendorExcludeSellList = list, sellAllJunk = false } }
loaded.EnhanceQoLVendor = true
-- As in its lookupItems and sellItems: skipped when the list answers for the item ID.
local function skips(itemID) local l = EnhanceQoL.db.vendorExcludeSellList; return (l and l[itemID]) and true or false end
local function entries(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function report() local from = #out + 1; SlashCmdList.JUNKMARK("check"); return table.concat(out, "\n", from) end
bags[0], bags[1] = {}, {}; JunkMarkDB = nil; knowsDE = false; money = 0
relog()
-- bags: (0,1) and (0,2) are two gray teeth, the same item; (0,3) vase; (0,4) an item the player excluded in EnhanceQoL
put(0, 1, "tooth-1", 7, { quality = 0, id = "tooth" }); put(0, 2, "tooth-2", 7, { quality = 0, id = "tooth" }); put(0, 3, "vase", 50); put(0, 4, "listed", 9)
fire("BAG_UPDATE_DELAYED"); ContainerFrameCombinedBags:UpdateItems()

local quiet = #out
check("EnhanceQoL: with no favorites its exclusion list answers only for what the player put in it", skips("listed") and not skips("tooth") and not skips("vase"))
press(0, 1, 2)
check("a favorite's item ID reads as excluded there, for every copy of it, and no other item does", kind("tooth-1") == "favorite" and skips("tooth") and not skips("vase") and skips("listed"))
check("nothing is put in the list: walking it, as its editor and the saved file do, finds only the player's entry",
  entries(list) == 1 and rawget(list, "tooth") == nil and entries(roundTrip(list)) == 1 and list.listed == "Listed Thing")
check("favoriting a gray item says nothing while EnhanceQoL's sell-all setting is off", #out == quiet)
press(0, 1)
check("unmarking lifts it", kind("tooth-1") == nil and not skips("tooth"))
press(0, 1, 2); local carried = skips("tooth"); local held = bags[0][1]; bags[0][1] = nil; fire("BAG_UPDATE_DELAYED")
check("a favorite that leaves the bags stops answering for its item ID", carried and not skips("tooth"))
bags[0][1] = held; fire("BAG_UPDATE_DELAYED")

-- EnhanceQoL swaps the list for another table, as a profile change does.
EnhanceQoL.db.vendorExcludeSellList = {}; local bare = not skips("tooth"); fire("BAG_UPDATE_DELAYED")
check("when EnhanceQoL swaps in another list, the guard is on it at the next bag change", bare and skips("tooth"))
EnhanceQoL.db.vendorExcludeSellList = {}; bare = not skips("tooth"); merchantOpen = true; fire("MERCHANT_SHOW")
check("...or as a vendor opens", bare and skips("tooth"))
merchantOpen = false; fire("MERCHANT_CLOSED")
EnhanceQoL.db.vendorExcludeSellList = {}; bare = not skips("tooth"); press(0, 3)
check("...or when a mark changes", bare and kind("vase") == "junk" and skips("tooth"))
check("/jm check says EnhanceQoL is guarded", report():find("EnhanceQoL's Vendor and Bags selling: guarded", 1, true))

local theirs = { __index = function() return nil end }
local locked = setmetatable({}, theirs); EnhanceQoL.db.vendorExcludeSellList = locked; fire("BAG_UPDATE_DELAYED")
check("a list that already has a metatable is left as it is, and /jm check says EnhanceQoL is not guarded",
  getmetatable(locked) == theirs and not skips("tooth") and report():find("EnhanceQoL|r is not guarded", 1, true))
EnhanceQoL.db.vendorExcludeSellList = nil; fire("BAG_UPDATE_DELAYED")
check("with no list there JunkMark makes none, and says the same", EnhanceQoL.db.vendorExcludeSellList == nil and report():find("EnhanceQoL|r is not guarded", 1, true))
EnhanceQoL.db.vendorExcludeSellList = list

-- Its "Automatically sell all junk items" runs the game's own sale, which no list stops.
EnhanceQoL.db.sellAllJunk = true
local from = #out + 1; press(0, 2, 2); local said = table.concat(out, "\n", from)
check("EnhanceQoL's sell-all setting is warned about when a gray item is favorited", kind("tooth-2") == "favorite" and #out == from
  and said:find("EnhanceQoL's \"Automatically sell all junk items\" sells every gray item", 1, true))
check("...and /jm check names it beside the guard", report():find("Automatically sell all junk items\"|r sells every gray item", 1, true))
loaded.EnhanceQoLVendor = nil
check("...but not when its Vendor module is not loaded", not report():find("Automatically sell all junk items", 1, true))
EnhanceQoL = nil; fire("BAG_UPDATE_DELAYED"); said = report()
check("with no EnhanceQoL nothing is said about it", not said:find("EnhanceQoL", 1, true) and said:find("no other addon that sells junk was found", 1, true))
if #caught > 0 then io.write("listener error: ", caught[1], "\n") end
check("no listener raised an error", #caught == 0)
end

io.write(fails == 0 and "ALL PASSED\n" or (fails .. " FAILED\n")); os.exit(fails == 0 and 0 or 1)
