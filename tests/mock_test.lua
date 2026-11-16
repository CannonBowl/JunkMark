-- Logic tests for JunkMark, run outside the game against a hand-written fake of the
-- WoW API. The game never loads this file (it is not listed in JunkMark.toc).
--
-- Run from the addon folder:
--     lua tests/mock_test.lua JunkMark.lua
--
-- Limits worth knowing: the fake widgets accept any method name, and the fakes encode
-- assumptions about how the real API behaves, so a pass here shows the addon's logic
-- is self-consistent, not that it works in the client. The game runs Lua 5.1.

local addonPath = arg[1]
local out, errors, fails = {}, {}, 0
local function check(name, cond) if cond then io.write("ok   ", name, "\n") else fails = fails + 1; io.write("FAIL ", name, "\n") end end

local bags = { [0] = {}, [1] = {} }
local function put(bag, slot, guid, price, o)
  o = o or {}
  bags[bag][slot] = { guid = guid, link = "[" .. guid .. "]", price = price, count = o.count or 1, noValue = o.noValue, quality = o.quality or 1, class = o.class or 0, icon = "icon:" .. guid }
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
Enum = { SpellBookSpellBank = { Player = "PlayerBank" }, ItemQuality = { Uncommon = 2, Epic = 4 }, ItemClass = { Weapon = 2, Armor = 4 } }
IsShiftKeyDown = function() return shift end
InCombatLockdown = function() return inCombat end
SetOverrideBinding = function(owner, priority, key, command) assert(not inCombat, "SetOverrideBinding in combat"); assert(owner and priority == true); override[key] = command end
ClearOverrideBindings = function(owner) assert(not inCombat, "ClearOverrideBindings in combat"); assert(owner); override = {} end

ItemLocation = {}
function ItemLocation:CreateEmpty() return { SetBagAndSlot = function(self, b, s) self.b, self.s = b, s end } end
local function at(loc) return bags[loc.b] and bags[loc.b][loc.s] end
local function byLink(link) for _, bag in pairs(bags) do for _, it in pairs(bag) do if it.link == link then return it end end end end
C_Item = {
  DoesItemExist = function(loc) return at(loc) ~= nil end,
  GetItemGUID = function(loc) return at(loc).guid end,
  GetItemInfo = function(link) return "n", link, 1, 1, 1, "t", "st", 1, "", 1, byLink(link).price end,
  GetItemInfoInstant = function(link) return 1, "t", "st", "", 1, byLink(link).class, 0 end,
}
C_Container = {
  GetContainerNumSlots = function() return 8 end,
  GetContainerItemInfo = function(b, s) local it = bags[b] and bags[b][s]; if not it then return nil end
    return { hyperlink = it.link, stackCount = it.count, hasNoValue = it.noValue or false, isLocked = false, quality = it.quality, iconFileID = it.icon } end,
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
C_Timer = { NewTicker = function(_, fn) local t = { fn = fn, Cancel = function(self) self.cancelled = true end }; tickers[#tickers+1] = t; return t end }
local function pumpRaw(n) for _ = 1, n do for _, t in ipairs(tickers) do if not t.cancelled then t.fn() end end end end

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
  return setmetatable(w, { __index = function() return noop end })
end
local eventHandler
local childrenOf = {}
CreateFrame = function(_, name, parent, template)
  local f = widget()
  if template == "SecureActionButtonTemplate" then f.secure = true end
  local set = f.SetScript
  function f:SetScript(n, fn) set(self, n, fn); if n == "OnEvent" then eventHandler = fn end end
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
hooksecurefunc = function(t, name, hook) local orig = t[name]; t[name] = function(...) orig(...); hook(...) end end
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
assert(loadfile(addonPath))("RenamedFolder", {})
local function fire(ev, a) eventHandler(nil, ev, a) end
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
press(0, 1); press(0, 3); press(1, 1)
check("gray weapon junk goes to the vendor pile", btn(0, 1):state() == "sell")
check("green armor junk is routed to disenchant", btn(0, 3):state() == "queue" and btn(0, 3).textures[3].tex == "spellicon:13262")
check("unsellable gear can still be junk, for disenchanting", kind("questring") == "junk" and btn(1, 1):state() == "queue")
P, B = JunkMarkQueuePanel, JunkMarkProcessButton
check("queue is first-marked first (migrated staff, then helm, then ring)", B.head.guid == "bluestaff" and B.attrs.spell1 == 13262 and B.attrs["target-bag1"] == 0 and B.attrs["target-slot1"] == 4 and P.countText.text == "3 items queued" and P.title.text == "Disenchant")

-- favorites at the vendor
press(1, 3, 2); check("heirloom favorited", kind("heirloom") == "favorite")
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

-- right-click the queue head: send it to the vendor instead
B.scripts.PostClick(B, "RightButton", true); check("right-click acts on release only", B.head.guid == "bluestaff")
B.scripts.PostClick(B, "RightButton", false)
check("skipped head moves to the vendor pile and stays junk", kind("bluestaff") == "junk" and btn(0, 4):state() == "sell" and B.head.guid == "greenhelm" and JunkMarkSellButton.text == "Sell Junk (1)")

-- hovering a favorite at the vendor goes through the blocker; ordering of enter/leave must not matter
hover(btn(1, 3)); K.scripts.OnEnter(K); unhover(btn(1, 3))
check("Space still bound when blocker's enter arrives before button's leave", override.SPACE == "JUNKMARK_TOGGLE")
space(); check("Space on a blocked favorite unmarks it and lifts the blocker", kind("heirloom") == nil and not btn(1, 3):blocked() and next(override) == nil)
hover(btn(1, 3)); space(); space(); unhover(btn(1, 3)); K.scripts.OnLeave(K)
check("re-favorited at the vendor: blocker returns immediately", kind("heirloom") == "favorite" and btn(1, 3):blocked())

-- shift-click sells held items too, but never favorites
shift = true; JunkMarkSellButton.scripts.OnClick(JunkMarkSellButton); pump(4); shift = false
check("Shift-click sells queued junk as well", money == 200 + 900 + 300 and not bags[0][3] and not bags[0][4])
check("unsellable ring stays queued; favorite untouched", bags[1][1] and B.head.guid == "questring" and bags[1][3] and kind("heirloom") == "favorite")
B.scripts.PostClick(B, "RightButton", false)
check("skipping an unsellable item just unmarks it and empties the queue", kind("questring") == nil and not P.shown and B.attrs.type1 == nil)
merchantOpen = false; fire("MERCHANT_CLOSED")
check("blocker lifted when the vendor closes", not btn(1, 3):blocked())

-- combat
put(0, 5, "greenboots", 200, { quality = 2, class = 4 }); put(0, 6, "greenbelt", 150, { quality = 2, class = 4 })
press(0, 5)
hover(btn(0, 6)); fire("PLAYER_REGEN_DISABLED"); inCombat = true
check("entering combat releases Space and disarms the queue button", next(override) == nil and B.attrs.type1 == nil)
check("Space does nothing on hover during combat", not space())
unhover(btn(0, 6)); hover(btn(0, 5)); unhover(btn(0, 5)); hover(btn(0, 6))
inCombat = false; fire("PLAYER_REGEN_ENABLED")
check("after combat Space works again on the item still hovered", override.SPACE == "JUNKMARK_TOGGLE" and B.attrs.type1 == "spell" and B.head.guid == "greenboots")
space(); unhover(btn(0, 6))
check("queue grows in mark order", kind("greenbelt") == "junk" and B.head.guid == "greenboots" and P.countText.text == "2 items queued")
bags[0][5] = nil; fire("BAG_UPDATE_DELAYED")
check("queue advances after a disenchant", B.head.guid == "greenbelt" and B.attrs["target-slot1"] == 6)

-- not an enchanter: all junk is vendor junk
knowsDE = false; fire("SPELLS_CHANGED")
check("without Disenchant the same junk goes to the vendor pile", btn(0, 6):state() == "sell" and not P.shown and B.attrs.type1 == nil)
knowsDE = true; fire("SPELLS_CHANGED")
check("learning Disenchant re-routes existing junk", btn(0, 6):state() == "queue" and P.shown)

-- a key the player bound themselves works without the hover binding
foci = { btn(0, 6) }; JunkMark_ToggleHovered(); foci = {}
check("user-bound key cycles the item under the cursor", kind("greenbelt") == "favorite")

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
io.write(fails == 0 and "ALL PASSED\n" or (fails .. " FAILED\n")); os.exit(fails == 0 and 0 or 1)
