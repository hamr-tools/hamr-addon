-- HAMR: copies the raid list and the guild's tick notes out of the game for the HAMR Tools site, and lines up the site's
-- totals as a list of notes for officers to paste into the game's guild window, one after another. Since Blizzard's
-- March 2026 hotfix addons can't write guild notes (C_GuildInfo.SetNote is only allowed from the game's own, untouched
-- UI, even on a click), so HAMR never tries: it copies, the officer pastes, and HAMR watches the roster to tick it off.
-- Nothing leaves the game. The only messages are between guildies' copies of the addon (which notes are done, and
-- Events.lua's shared events).

local MAX_NOTE = 31
-- Exports say which game they came from, so the site won't match retail names against Forever's guild or the other way.
local GAME = (WOW_PROJECT_ID and WOW_PROJECT_MAINLINE and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE) and "retail" or "forever"
local GAME_LABEL = GAME == "retail" and "Retail" or "Forever"
local ADDON_NAME, ns = ...
ADDON_NAME, ns = ADDON_NAME or "HAMR", ns or {}      -- ns is shared with the addon's other files (Onboarding.lua)
local ICON = "Interface\\AddOns\\" .. ADDON_NAME .. "\\icon"
local KINDS = { { key = "cta", label = "CTA", pattern = "[Cc][Tt][Aa]" }, { key = "hw", label = "HW", pattern = "[Hh][Ww]" } }

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
local function lower(s) return string.lower(s or "") end
local function shortName(name) return name:match("^([^%-]+)") or name end
local function firstWord(name) return name:match("^(%S+)") or name end
local function now() return GetServerTime and GetServerTime() or time() end
local function say(text) DEFAULT_CHAT_FRAME:AddMessage("|cffe08a43HAMR|r " .. text) end

---------------------------------------------------------------------------------------------------------------------
-- Notes: "Main CTA:15 HW:", a blank meaning none.

local function noteCounts(note)
  local counts, found = {}, false
  for _, k in ipairs(KINDS) do
    local n = note:match(k.pattern .. "[%s:%.]*(%d*)")      -- "CTA:4", "CTA: 4", "CTA 4", "HW:.3"
    if n then found = true end
    counts[k.key] = tonumber(n) or 0
  end
  return found and counts or nil
end

-- Changes only the numbers, so "Main" and anything else the officers wrote stays as it was.
local function withCounts(note, counts)
  if not noteCounts(note) then
    note = "Main"
  end
  for _, k in ipairs(KINDS) do
    local text = counts[k.key] > 0 and tostring(counts[k.key]) or ""
    local out, n = note:gsub("(" .. k.pattern .. "[%s:%.]*)%d+", "%1" .. text, 1)     -- keeps however the number was written
    if n == 0 then out, n = note:gsub("(" .. k.pattern .. "%s*:)", "%1" .. text, 1) end     -- "CTA:" with nothing after
    note = n > 0 and out or (note .. " " .. k.label .. ":" .. text)
  end
  return note
end

---------------------------------------------------------------------------------------------------------------------
-- The guild roster. Offline members are only listed while "Show offline members" is on, so it is on while we work.

local savedShowOffline

local function showOffline()
  if SetGuildRosterShowOffline and GetGuildRosterShowOffline and savedShowOffline == nil then
    savedShowOffline = GetGuildRosterShowOffline()
    SetGuildRosterShowOffline(true)
  end
end

local function restoreOffline()
  if savedShowOffline ~= nil and SetGuildRosterShowOffline then
    SetGuildRosterShowOffline(savedShowOffline)
  end
  savedShowOffline = nil
end

local function rosterEntries()
  local list = {}
  for i = 1, (GetNumGuildMembers() or 0) do
    local name, rank, rankIndex, _, _, _, note, _, _, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
    if name then list[#list + 1] = { index = i, name = name, note = note or "", guid = guid, rank = rank or "", rankIndex = rankIndex } end
  end
  return list
end

local function askForRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
end

local pending, rosterChanged
local waiter = CreateFrame("Frame")
waiter:SetScript("OnEvent", function()
  if rosterChanged then rosterChanged() end
  if pending then local run = pending; pending = nil; run() end
end)
waiter:RegisterEvent("GUILD_ROSTER_UPDATE")

-- Runs fn with a fresh roster. The game only refreshes it every few seconds, so after a short wait we use what we have.
local function withRoster(fn)
  if not IsInGuild() then say("You're not in a guild.") return end
  showOffline()
  pending = fn
  askForRoster()
  C_Timer.After(2, function() if pending == fn then pending = nil; fn() end end)
end

local function canEditNotes()
  if C_GuildInfo and C_GuildInfo.CanEditPublicNote then return C_GuildInfo.CanEditPublicNote() end
  if CanEditPublicNote then return CanEditPublicNote() end
  return true
end

-- Finds a roster entry from a name as the site writes it: "Name", "Name Surname" or "Name-Realm".
local function rosterIndex(entries)
  local full, short, first = {}, {}, {}
  local function put(map, key, e) if map[key] == nil then map[key] = e elseif map[key] ~= e then map[key] = false end end
  for _, e in ipairs(entries) do
    full[lower(e.name)] = e
    put(short, lower(shortName(e.name)), e)
    put(first, lower(firstWord(shortName(e.name))), e)
  end
  return function(wanted)
    local w = lower(trim(wanted))
    return full[w] or short[lower(shortName(w))] or first[lower(firstWord(shortName(w)))] or nil
  end
end

---------------------------------------------------------------------------------------------------------------------
-- The window: three tabs, each a text box for copying and pasting, or a list of note changes with a Save button each.
-- Built from plain frames and textures plus three of the game's oldest templates, so a patch is unlikely to break it.

local frame = CreateFrame("Frame", "HAMRFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetSize(600, 500)
frame:SetPoint("CENTER")
frame:SetFrameStrata("DIALOG")
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) if not ns.locked then self:StartMoving() end end)      -- unless locked in the options
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                    tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
-- The dialog background texture is see-through even at full strength, so a solid layer sits under it: at 100% in the
-- options the window is fully opaque.
local solid = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
solid:SetPoint("TOPLEFT", 11, -12)
solid:SetPoint("BOTTOMRIGHT", -12, 11)
solid:SetColorTexture(0.05, 0.05, 0.05, 1)
frame:SetScript("OnHide", restoreOffline)
frame:Hide()
tinsert(UISpecialFrames, "HAMRFrame")       -- Escape closes it

local crest = frame:CreateTexture(nil, "ARTWORK")
crest:SetSize(30, 30)
crest:SetPoint("TOPLEFT", 20, -16)
crest:SetTexture(ICON)
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("LEFT", crest, "RIGHT", 8, 0)
title:SetText("HAMR Tools")
local gameTag = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
gameTag:SetPoint("LEFT", title, "RIGHT", 8, -1)
gameTag:SetText(GAME_LABEL)
local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

local divider = frame:CreateTexture(nil, "ARTWORK")
divider:SetPoint("TOPLEFT", 20, -82)
divider:SetPoint("TOPRIGHT", -20, -82)
divider:SetHeight(1)
divider:SetColorTexture(1, 0.82, 0, 0.25)

local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
hint:SetPoint("TOPLEFT", 24, -94)
hint:SetPoint("RIGHT", -24, 0)
hint:SetJustifyH("LEFT")
local action = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
action:SetSize(130, 24)
action:SetPoint("BOTTOMRIGHT", -24, 18)
local second = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
second:SetSize(110, 24)
second:SetPoint("RIGHT", action, "LEFT", -8, 0)
local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
status:SetPoint("BOTTOMLEFT", 24, 24)
status:SetPoint("RIGHT", second, "LEFT", -10, 0)
status:SetJustifyH("LEFT")

-- Reading the roster can take a couple of seconds (the game sends it when it's ready), so say so while it happens,
-- and turn the crest like a spinner.
local busyText, busyDots, busySince, spin = nil, 0, 0, 0
local ticker = CreateFrame("Frame", nil, frame)
ticker:Hide()
ticker:SetScript("OnUpdate", function(_, elapsed)
  busySince, spin = busySince + elapsed, spin - elapsed * 4
  if crest.SetRotation then crest:SetRotation(spin) end
  if busySince > 0.3 then
    busySince, busyDots = 0, (busyDots % 3) + 1
    status:SetText(busyText .. string.rep(".", busyDots))
  end
end)

local function setBusy(text)
  if text then
    busyText, busyDots, busySince = text, 0, 0
    status:SetText(text .. "...")
    action:Disable()
    second:Disable()
    ticker:Show()
  else
    ticker:Hide()
    spin = 0
    if crest.SetRotation then crest:SetRotation(0) end
    action:Enable()
    second:Enable()
    status:SetText("")
  end
end

local textScroll = CreateFrame("ScrollFrame", "HAMRTextScroll", frame, "UIPanelScrollFrameTemplate")
textScroll:SetPoint("TOPLEFT", 24, -146)
textScroll:SetPoint("BOTTOMRIGHT", -44, 54)
local function well(scroll)        -- a darker well behind a scrolling area, so it reads as a box; hides with it
  local back = scroll:CreateTexture(nil, "BACKGROUND")
  back:SetPoint("TOPLEFT", scroll, "TOPLEFT", -6, 6)
  back:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 26, -6)
  back:SetColorTexture(0, 0, 0, 0.35)
end
well(textScroll)
local edit = CreateFrame("EditBox", nil, textScroll)
edit:SetMultiLine(true)
edit:SetAutoFocus(false)
edit:SetMaxLetters(0)
edit:SetFontObject(ChatFontNormal)
edit:SetWidth(510)
edit:SetScript("OnEscapePressed", function() frame:Hide() end)
textScroll:SetScrollChild(edit)
textScroll:EnableMouse(true)
textScroll:SetScript("OnMouseDown", function() edit:SetFocus() end)

local listScroll = CreateFrame("ScrollFrame", "HAMRListScroll", frame, "UIPanelScrollFrameTemplate")
listScroll:SetPoint("TOPLEFT", 24, -220)         -- under the note being copied (cur, below)
listScroll:SetPoint("BOTTOMRIGHT", -44, 54)
well(listScroll)
local list = CreateFrame("Frame", nil, listScroll)
list:SetSize(510, 10)
listScroll:SetScrollChild(list)
local rows = {}

-- Tabs: plain buttons with a gold line under the open one. Other files add theirs with ns.addTab.
local tabButtons, tabCount, currentTab, view = {}, 0, nil, 0
local tabOrder = {}
ns.panels, ns.tabs = {}, {}         -- frames hidden whenever a tab opens; {key = function that opens it}
ns.hiddenTabs = { raid = true }     -- the Raid list tab is off unless the options turn it on

-- Lines the tabs up left to right, leaving out hidden ones.
local function layoutTabs()
  local shown = 0
  for _, key in ipairs(tabOrder) do if not ns.hiddenTabs[key] then shown = shown + 1 end end
  local w = math.min(106, math.floor(556 / math.max(shown, 1)) - 4)       -- five at full width; six still fit
  local x = 0
  for _, key in ipairs(tabOrder) do
    local b = tabButtons[key]
    b:ClearAllPoints()
    if ns.hiddenTabs[key] then b:Hide() else
      b:SetWidth(w)
      b:SetPoint("BOTTOMLEFT", divider, "TOPLEFT", x * (w + 4), 0)
      b:Show()
      x = x + 1
    end
  end
end
ns.layoutTabs = layoutTabs

local function tabLook(b, selected)
  b.label:SetFontObject(selected and GameFontHighlight or GameFontNormal)
  b.back:SetColorTexture(1, 1, 1, selected and 0.08 or 0.03)
  if selected then b.line:Show() else b.line:Hide() end
end

function ns.addTab(key, label, run)
  tabCount = tabCount + 1
  local b = CreateFrame("Button", nil, frame)
  b:SetSize(106, 26)          -- five fit across the window
  b:SetPoint("BOTTOMLEFT", divider, "TOPLEFT", (tabCount - 1) * 110, 0)
  b.back = b:CreateTexture(nil, "BACKGROUND")
  b.back:SetAllPoints()
  local glow = b:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetColorTexture(1, 0.82, 0, 0.1)
  b.line = b:CreateTexture(nil, "ARTWORK")
  b.line:SetPoint("BOTTOMLEFT")
  b.line:SetPoint("BOTTOMRIGHT")
  b.line:SetHeight(2)
  b.line:SetColorTexture(1, 0.82, 0, 1)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.label:SetPoint("CENTER", 0, 1)
  b.label:SetText(label)
  b.key = key
  b:SetScript("OnClick", function() ns.showTab(key) end)
  tabButtons[key] = b
  tabOrder[#tabOrder + 1] = key
  ns.tabs[key] = run
  tabLook(b, false)
  layoutTabs()
  return b
end

-- Opens a tab with a fresh screen. Returns a number that changes with every screen, so a roster that arrives after
-- someone has moved on to another tab is dropped instead of drawn over it.
local function open(key, hintText)
  view = view + 1
  setBusy(nil)
  currentTab = key
  for k, b in pairs(tabButtons) do tabLook(b, k == key) end
  hint:SetText(hintText)
  textScroll:Hide()
  listScroll:Hide()
  for _, p in ipairs(ns.panels) do p:Hide() end
  action:Hide()
  action:SetScript("OnClick", nil)
  second:Hide()
  second:SetScript("OnClick", nil)
  frame:Show()
  return view
end

local function showText(key, hintText, text, againText, again)
  open(key, hintText)
  listScroll:Hide()
  textScroll:Show()
  edit:SetText(text)
  edit:SetFocus()
  edit:HighlightText()
  action:SetText("Select all")
  action:SetScript("OnClick", function() edit:SetFocus(); edit:HighlightText() end)
  action:Show()
  if again then
    second:SetText(againText)
    second:SetScript("OnClick", again)
    second:Show()
  end
end

local function showPaste(key, hintText, buttonText, onRead)
  open(key, hintText)
  listScroll:Hide()
  textScroll:Show()
  edit:SetText("")
  edit:SetFocus()
  action:SetText(buttonText)
  action:SetScript("OnClick", function() onRead(edit:GetText()) end)
  action:Show()
end

local ROW_H = 42
local function row(i)
  local r = rows[i]
  if not r then
    r = CreateFrame("Frame", nil, list)
    r:SetSize(510, ROW_H - 2)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    if i % 2 == 0 then
      local stripe = r:CreateTexture(nil, "BACKGROUND")
      stripe:SetAllPoints()
      stripe:SetColorTexture(1, 1, 1, 0.04)
    end
    r.mark = r:CreateTexture(nil, "BACKGROUND", nil, 1)      -- the row being copied now
    r.mark:SetAllPoints()
    r.mark:SetColorTexture(1, 0.82, 0, 0.14)
    r.mark:Hide()
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetPoint("LEFT", 6, 0)
    r.text:SetPoint("RIGHT", -90, 0)
    r.text:SetJustifyH("LEFT")
    r.button = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.button:SetSize(80, 22)
    r.button:SetPoint("RIGHT", -4, 0)
    rows[i] = r
  end
  r:Show()
  return r
end

---------------------------------------------------------------------------------------------------------------------
-- /hamr notes: the site's totals, checked against each note before anything is written.

local ORANGE, GREY, GOLD, GREEN = "|cffff9a2e", "|cff9d9d9d", "|cffffd100", "|cff4fd86a"

local function judge(item)
  if item.info then item.state = "info" return end       -- something to look at, nothing to change
  local have = noteCounts(item.entry.note)
  item.after = withCounts(item.entry.note, item.want)
  item.problem = nil
  if have and have.cta == item.want.cta and have.hw == item.want.hw then
    item.state = item.rankNote and "info" or "same"
  elseif #item.after > MAX_NOTE then
    item.state, item.problem = "long", "The new note is longer than the game's " .. MAX_NOTE .. " letters: shorten it as you paste."
  elseif not have and trim(item.entry.note) ~= "" then       -- an empty note is just someone new
    item.state, item.problem = "warn", "This note has no ticks yet. Is it an alt? Then skip it, and pair it with its main on the site."
  elseif have and (have.cta > item.want.cta or have.hw > item.want.hw) then
    item.state, item.problem = "warn", "The note is higher than the site. Someone may have changed it by hand: check before lowering it."
  else
    item.state = "change"
  end
end

local function drawItem(r, item, current)
  local note = item.entry.note ~= "" and item.entry.note or (item.info and "" or (GREY .. "(empty)|r"))
  local line = GOLD .. item.entry.name .. "|r   " .. note .. (item.state == "info" and "" or ("   ->   " .. item.after))
  local extra = ""
  if item.saved then
    extra = "\n" .. GREEN .. "Done: the guild roster shows it.|r"
  else
    if item.mismatch then
      extra = extra .. "\n" .. ORANGE .. "The note now reads \"" .. item.mismatch .. "\": the numbers don't match. Fix it in the guild window.|r"
    elseif item.passed then
      extra = extra .. "\n" .. GREY .. "Waiting for the guild roster to show it (a few seconds). Skipped it? Press Go to.|r"
    end
    if item.problem then extra = extra .. "\n" .. ORANGE .. item.problem .. "|r" end
    if item.info then extra = extra .. "\n" .. ORANGE .. item.info .. "|r" end
    if item.rankNote then extra = extra .. "\n" .. GREY .. item.rankNote .. "|r" end
  end
  r.text:SetText(line .. extra)
  if current then r.mark:Show() else r.mark:Hide() end
  if item.all then r.button:SetText("Show all"); r.button:Show()
  elseif item.state == "info" or item.saved or current then r.button:Hide() else r.button:SetText("Go to"); r.button:Show() end
end

---------------------------------------------------------------------------------------------------------------------
-- Which events' notes are done. An event's export from the site says which event it is; the first officer to save a
-- note from it records that, and tells every other officer's addon in the guild. An addon that logs in later asks
-- the others for what it missed. Running an event again is always safe; this only says it's been done.

local PREFIX = "HAMR"

local function db()
  HAMRDB = type(HAMRDB) == "table" and HAMRDB or {}
  return HAMRDB
end

local function applied()
  local d = db()
  d.applied = type(d.applied) == "table" and d.applied or {}
  return d.applied
end

local function ago(at)
  local s = math.max(0, now() - (at or 0))
  if s < 90 then return "just now" end
  if s < 5400 then return math.floor(s / 60 + 0.5) .. " min ago" end
  if s < 129600 then return math.floor(s / 3600 + 0.5) .. " h ago" end
  return math.floor(s / 86400 + 0.5) .. " days ago"
end

local function split(text)
  local parts = {}
  for part in (text .. "\t"):gmatch("(.-)\t") do parts[#parts + 1] = part end
  return parts
end

-- Returns what the game said, so Events.lua's queue can tell a throttled message (retail returns a result code) and
-- send it again later. Never worth an error.
local function sendAddon(message, channel, target)
  local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not (send and IsInGuild()) then return true end
  local ok, result = pcall(send, PREFIX, message, channel, target)
  return ok, result
end

local function remember(game, id, at, by, title)
  id, at = tonumber(id), tonumber(at) or 0
  if not (game and id and by) then return end
  local key = game .. ":" .. id
  local old = applied()[key]
  if old and old.at <= at then return end           -- keep the first officer who did it
  applied()[key] = { game = game, id = id, at = at, by = by, title = title or "" }
end

local function wireRecord(r)
  return table.concat({ "A", r.game, r.id, r.at, r.by, (r.title or ""):sub(1, 60) }, "\t")
end

local function markApplied(ev)
  if not ev or ev.marked then return end
  ev.marked = true
  remember(GAME, ev.id, now(), UnitName("player") or "?", ev.title)
  sendAddon(wireRecord(applied()[GAME .. ":" .. ev.id]), "GUILD")
end

local function recentApplied(limit)
  local list = {}
  for _, r in pairs(applied()) do if r.game == GAME then list[#list + 1] = r end end
  table.sort(list, function(a, b) return a.at > b.at end)
  while #list > limit do table.remove(list) end
  return list
end

local comms = CreateFrame("Frame")
comms:RegisterEvent("CHAT_MSG_ADDON")
comms:SetScript("OnEvent", function(_, event, prefix, message, channel, sender)
  if event ~= "CHAT_MSG_ADDON" or prefix ~= PREFIX or type(message) ~= "string" then return end
  local p = split(message)
  local fromMe = shortName(sender or "") == UnitName("player")
  if p[1] == "A" then
    remember(p[2], p[3], p[4], p[5], p[6])
  elseif p[1] == "Q" then      -- someone just logged in
    if fromMe then return end
    for _, r in ipairs(recentApplied(5)) do sendAddon(wireRecord(r), "WHISPER", sender) end
    if ns.onQuery then ns.onQuery(sender) end
  elseif ns.onEventMessage and not fromMe then       -- Events.lua's: events, who's on them, raid sizes
    ns.onEventMessage(p, channel, sender)
  end
end)

function ns.startComms()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  elseif RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(PREFIX) end
  for key, r in pairs(applied()) do         -- forget events done more than 60 days ago
    if type(r) ~= "table" or (now() - (r.at or 0)) > 60 * 86400 then applied()[key] = nil end
  end
  C_Timer.After(15, function() sendAddon("Q", "GUILD") end)
end

---------------------------------------------------------------------------------------------------------------------
-- Updating notes by hand, down the list. The note being copied sits in a box, already selected: Ctrl+C, then in the
-- game's guild window click the member, their note, Ctrl+V, Enter. HAMR sees the roster change, ticks the row off and
-- selects the next. The list is in name order, like the guild window sorted by Name, so both go down together.
-- HAMR never touches the guild window itself: an addon reaching into it could stop the game's own note saving too.

local cur = CreateFrame("Frame", nil, frame)
cur:SetPoint("TOPLEFT", 24, -150)
cur:SetPoint("RIGHT", -24, 0)
cur:SetHeight(62)
cur:Hide()
table.insert(ns.panels, cur)
local curBack = cur:CreateTexture(nil, "BACKGROUND")
curBack:SetAllPoints()
curBack:SetColorTexture(1, 0.82, 0, 0.1)
cur.name = cur:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
cur.name:SetPoint("TOPLEFT", 10, -8)
cur.was = cur:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
cur.was:SetPoint("LEFT", cur.name, "RIGHT", 12, 0)
cur.was:SetPoint("RIGHT", cur, "RIGHT", -110, 0)
cur.was:SetJustifyH("LEFT")
cur.box = CreateFrame("EditBox", nil, cur)
cur.box:SetSize(250, 22)
cur.box:SetPoint("BOTTOMLEFT", 12, 8)
cur.box:SetFontObject(ChatFontNormal)
cur.box:SetAutoFocus(false)
cur.box:SetMaxLetters(100)
if cur.box.SetTextInsets then cur.box:SetTextInsets(4, 4, 0, 0) end
local boxBack = cur.box:CreateTexture(nil, "BACKGROUND")
boxBack:SetPoint("TOPLEFT", -2, 2)
boxBack:SetPoint("BOTTOMRIGHT", 2, -2)
boxBack:SetColorTexture(0, 0, 0, 0.6)
cur.tip = cur:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
cur.tip:SetPoint("LEFT", cur.box, "RIGHT", 12, 0)
cur.tip:SetPoint("RIGHT", cur, "RIGHT", -110, 0)
cur.tip:SetJustifyH("LEFT")
cur.next = CreateFrame("Button", nil, cur, "UIPanelButtonTemplate")
cur.next:SetSize(96, 24)
cur.next:SetPoint("RIGHT", -8, 0)
cur.next:SetText("Next")

local lastNotes, lastSummary, curIndex        -- the checked list stays while you look at another tab

local function actionable(item) return item.state ~= "info" and item.state ~= "same" end
local function todo(item) return actionable(item) and not item.saved and not item.passed end

-- Puts the keyboard in the box with the note selected, unless the officer is typing somewhere else (the guild
-- window's note): then it waits for them.
local function focusBox()
  if not cur:IsShown() or not cur.item then return end
  local f = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
  if f and f ~= cur.box then return end
  cur.box:SetFocus()
  cur.box:HighlightText()
end

-- The first row still to do after `from`, round to the top again.
local function nextTodo(from)
  local items = lastNotes or {}
  for k = 0, #items - 1 do
    local j = ((from or 0) + k) % #items + 1
    if todo(items[j]) then return j end
  end
end

local function drawNotes()
  local items = lastNotes or {}
  local total, done = 0, 0
  for i, item in ipairs(items) do
    drawItem(row(i), item, i == curIndex)
    if actionable(item) then
      total = total + 1
      if item.saved then done = done + 1 end
    end
  end
  local item = curIndex and items[curIndex]
  cur.item = item
  if item then
    cur.name:SetText(item.entry.name)
    cur.was:SetText(GREY .. "Now:|r " .. (item.entry.note ~= "" and item.entry.note or (GREY .. "(empty)|r")))
    cur.box:SetText(item.after)
    if cur.box:HasFocus() then cur.box:HighlightText() end
    cur.box:Show()
    cur.next:Show()
    cur.tip:SetText("Ctrl+C, then in the guild window: their note, Ctrl+V, Enter. Next comes up by itself.")
  else
    cur.name:SetText((done == total) and (total == 0 and "Nothing to change" or "All done") or "Waiting for the roster")
    cur.was:SetText("")
    cur.box:SetText("")
    cur.box:Hide()
    cur.next:Hide()
    cur.tip:SetText(done == total and "" or "The rest turn green once the game's roster shows them. Go to any row to do it again.")
  end
  if total > 0 then status:SetText(done .. " of " .. total .. " done" .. (done == total and ": every note matches the site." or ".")) end
end

-- Makes row i the one being copied, scrolled into view.
local function pick(i, focus)
  curIndex = i
  if not cur:IsShown() then return end
  drawNotes()
  if i then
    local top, height, at = (i - 1) * ROW_H, listScroll:GetHeight() or 200, listScroll:GetVerticalScroll()
    if top < at or top + ROW_H > at + height then
      listScroll:SetVerticalScroll(math.max(0, math.min(top - ROW_H, listScroll:GetVerticalScrollRange() or 0)))
    end
  end
  if focus then focusBox() end
end

-- Next (or Enter in the box): this one's pasted, on to the next. It goes green when the roster shows it.
local function passOn()
  local item = cur.item
  if not item then return end
  item.passed = true
  pick(nextTodo(curIndex), true)
end
cur.next:SetScript("OnClick", passOn)
cur.box:SetScript("OnEnterPressed", passOn)
cur.box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
cur.box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
cur.box:SetScript("OnTextChanged", function(self, typed)      -- it's for copying: typing puts the note back
  if typed and cur.item then self:SetText(cur.item.after); self:HighlightText() end
end)

-- Every roster update ticks off the notes that now carry the site's numbers, whoever changed them (two officers can
-- split the list). A note that changed to other numbers is flagged: a typo, or someone else got there first.
rosterChanged = function()
  if not lastNotes then return end
  local notes = {}
  for _, e in ipairs(rosterEntries()) do notes[e.name] = e.note end
  local moved = false
  for i, item in ipairs(lastNotes) do
    local note = notes[item.entry.name]
    if actionable(item) and not item.saved and note then
      local has = noteCounts(note)
      if has and has.cta == item.want.cta and has.hw == item.want.hw then
        item.saved, item.mismatch = true, nil
        markApplied(item.event)
        if i == curIndex then moved = true end
      elseif note ~= item.entry.note then
        item.mismatch = note
      else
        item.mismatch = nil
      end
    end
  end
  if moved then pick(nextTodo(curIndex), true) elseif cur:IsShown() then drawNotes() end
end

-- The game only sends the roster when asked (and at most every few seconds), so keep asking while there's work left.
local sinceAsked = 0
cur:SetScript("OnUpdate", function(_, elapsed)
  sinceAsked = sinceAsked + elapsed
  if sinceAsked < 5 then return end
  sinceAsked = 0
  for _, item in ipairs(lastNotes or {}) do
    if actionable(item) and not item.saved then askForRoster() return end
  end
end)

local importNotes

-- Where you are in updating the notes: paste, check, update. Done steps are green, the current one gold.
local STEPS = { "Paste", "Check", "Update by hand" }
local function steps(current)
  local parts = {}
  for i, name in ipairs(STEPS) do
    local text = "Step " .. i .. ": " .. name
    parts[i] = (i < current and (GREEN .. text .. "|r")) or (i == current and (GOLD .. text .. "|r")) or (GREY .. text .. "|r")
  end
  return table.concat(parts, GREY .. "    >    |r")
end

local function showNotes(items, summary)
  if items ~= lastNotes then curIndex = nil end
  lastNotes, lastSummary = items, summary
  open("notes", steps(3) .. "\n" .. summary)
  edit:ClearFocus()         -- the paste box had the keyboard; the note to copy gets it now
  textScroll:Hide()
  cur:Show()
  listScroll:Show()
  for _, r in ipairs(rows) do r:Hide() end
  for i, item in ipairs(items) do
    row(i).button:SetScript("OnClick", function()
      if item.all then         -- the names the site has that this guild doesn't: to copy or read
        showText("notes", item.entry.name .. ". Press Back to return to the list.", table.concat(item.all, "\n"), "Back", function() showNotes(lastNotes, lastSummary) end)
        return
      end
      item.passed = nil
      pick(i, true)
    end)
  end
  list:SetHeight(math.max(#items * ROW_H, 10))
  listScroll:SetVerticalScroll(0)
  second:SetText("Paste again")
  second:SetScript("OnClick", function() lastNotes = nil; importNotes() end)
  second:Show()
  pick((curIndex and items[curIndex] and todo(items[curIndex])) and curIndex or nextTodo(0), true)
  if not canEditNotes() then status:SetText(ORANGE .. "Your guild rank can't edit public notes: ask someone whose rank can.|r") end
end

local function readTotals(text)
  local lines = {}
  for line in text:gmatch("[^\r\n]+") do lines[#lines + 1] = trim(line) end
  if not lines[1] or not lines[1]:match("^HAMR%-NOTES") then
    status:SetText(ORANGE .. "That isn't the export from the site. Copy all of it, including the first line.|r")
    return
  end
  local from = lines[1]:match("^HAMR%-NOTES%s+%d+%s+(%a+)")
  if from and from ~= GAME then
    status:SetText(ORANGE .. "Those totals are from the " .. from .. " site. Copy them from this game's site: " .. GAME_LABEL .. ".|r")
    return
  end
  if not IsInGuild() then status:SetText(ORANGE .. "You're not in a guild.|r") return end
  db().lastPaste = { text = text, at = now() }        -- survives a /reload halfway down the list
  local eventId, eventTitle = lines[1]:match("event=(%d+)%s*(.-)$")
  local ev = eventId and { id = tonumber(eventId), title = (eventTitle ~= "" and eventTitle) or ("event " .. eventId) } or nil
  hint:SetText(steps(2) .. "\nChecking each name against the guild roster. Nothing is saved yet.")
  setBusy("Checking against the guild roster")
  local asked = view
  withRoster(function()
    if asked ~= view then return end        -- they went to another tab meanwhile
    setBusy(nil)
    local find = rosterIndex(rosterEntries())
    local items, same, missing = {}, 0, {}
    for i = 2, #lines do
      local alt, main = lines[i]:match("^(.-)=alt,(.+)$")
      local name, cta, hw, rank = lines[i]:match("^(.-)=(%d+),(%d+),?(.*)$")
      if alt then
        -- The site counts this character as an alt: its ticks belong on its main's note. Only flag a tick note left here.
        local entry = find(alt)
        local counts = entry and noteCounts(entry.note)
        if counts and (counts.cta > 0 or counts.hw > 0) then
          items[#items + 1] = { entry = entry, info = "The site has this as an alt of " .. main .. ", whose note keeps the count. Was the main changed?", state = "info" }
        end
      elseif name then
        local entry = find(name)
        if entry then
          local item = { entry = entry, want = { cta = tonumber(cta), hw = tonumber(hw) }, event = ev }
          rank = trim(rank or "")
          if rank ~= "" and lower(rank) ~= lower(entry.rank) then
            item.rankNote = "Rank: " .. (entry.rank ~= "" and entry.rank or "none") .. " here, " .. rank .. " in the other game. Change it by hand if it should match."
          end
          judge(item)
          if item.state == "same" then same = same + 1 else items[#items + 1] = item end
        else
          missing[#missing + 1] = name
        end
      end
    end
    table.sort(items, function(a, b)          -- name order, like the guild window sorted by Name; nothing-to-do rows last
      local ia, ib = a.state == "info", b.state == "info"
      if ia ~= ib then return ib end
      return lower(a.entry.name) < lower(b.entry.name)
    end)
    if #missing > 0 then
      local shown = table.concat(missing, ", ", 1, math.min(#missing, 4)) .. (#missing > 4 and (" and " .. (#missing - 4) .. " more") or "")
      items[#items + 1] = { entry = { name = #missing .. " not in the guild", note = "" }, state = "info", info = shown, all = missing }
    end
    local changes, flags = 0, 0
    for _, item in ipairs(items) do if item.state == "info" then flags = flags + 1 else changes = changes + 1 end end
    local summary = changes .. " to change, " .. same .. " already right" .. (flags > 0 and (", " .. flags .. " to look at at the end.") or ".")
      .. " In name order: sort the guild window by Name."
    if #missing > 0 then summary = summary .. " " .. #missing .. " not in the guild." end
    if changes == 0 and same == 0 and #missing > 0 then
      summary = ORANGE .. "None of these names are in this guild. Is it the export from another guild's site?|r"
    end
    local done = ev and applied()[GAME .. ":" .. ev.id]
    if done then
      summary = GOLD .. ev.title .. " was already done by " .. done.by .. ", " .. ago(done.at) .. ". Running it again is safe.|r\n" .. summary
    end
    showNotes(items, summary)
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- The raid list and the guild's notes: text to copy into the site.

local function groupNames()
  local names = {}
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local name = GetRaidRosterInfo(i)
      if name then names[#names + 1] = name end
    end
  else
    local function add(unit)
      local name, realm = UnitName(unit)
      if name then names[#names + 1] = (realm and realm ~= "") and (name .. "-" .. realm) or name end
    end
    add("player")
    for i = 1, GetNumSubgroupMembers() do add("party" .. i) end
  end
  table.sort(names)
  return names
end

local exportRaid, exportRoster

exportRaid = function()
  local names = groupNames()
  showText("raid", "Press Ctrl+C to copy, then paste it into the event's list on the site. " .. #names .. " names.",
           "HAMR " .. now() .. " " .. GAME .. " " .. (UnitName("player") or "") .. "\n" .. table.concat(names, "\n"),       -- whose raid, for the site
           "Refresh", function() exportRaid() end)
end

exportRoster = function()
  if not IsInGuild() then
    open("roster", ORANGE .. "You're not in a guild.|r")
    textScroll:Hide()
    listScroll:Hide()
    return
  end
  local asked = open("roster", "Reading everyone's notes. Offline members are shown while this window is open.")
  textScroll:Show()
  listScroll:Hide()
  edit:SetText("")
  setBusy("Reading the guild roster")
  withRoster(function()
    if asked ~= view then return end
    setBusy(nil)
    local lines, count = { "HAMR-ROSTER " .. now() .. " " .. GAME }, 0
    if GuildControlGetNumRanks and GuildControlGetRankName then        -- so the site can check its rank names against the game's
      local ranks = {}
      for i = 1, GuildControlGetNumRanks() do ranks[#ranks + 1] = GuildControlGetRankName(i) or "" end
      lines[#lines + 1] = "RANKS=" .. table.concat(ranks, ";")
    end
    for _, e in ipairs(rosterEntries()) do
      if noteCounts(e.note) then
        lines[#lines + 1] = e.name .. ";" .. (e.rankIndex or "") .. ";" .. e.rank .. "=" .. e.note
        count = count + 1
      end
    end
    local said = count > 0 and (count .. " tick notes.")
      or (ORANGE .. "No note in this guild has CTA: or HW: in it yet|r, so the site has nothing to compare: it reads notes like \"Main CTA:3 HW:1\".")
    showText("roster", "Press Ctrl+C to copy, then paste it under \"Compare with the game\" on the site's Tallies page. " .. said,
             table.concat(lines, "\n"), "Read again", function() exportRoster() end)
  end)
end

importNotes = function()
  local last = recentApplied(1)[1]
  showPaste("notes", steps(1) .. "\nOn the site, press \"Copy for the addon\" (a published event, or \"Copy all\" on Tallies), paste it here (Ctrl+V), then Check.",
            "Check", readTotals)
  local kept = db().lastPaste
  if type(kept) == "table" and type(kept.text) == "string" and now() - (kept.at or 0) < 86400 then
    edit:SetText(kept.text)
    edit:HighlightText()
    status:SetText(GREY .. "Your last paste (" .. ago(kept.at) .. ") is still here: Check carries on where you left off, or paste a new one.|r")
  elseif last then
    status:SetText(GREY .. "Last done: " .. last.title .. ", by " .. last.by .. ", " .. ago(last.at) .. ". /hamr done lists more.|r")
  end
end

ns.addTab("raid", "Raid list", function() exportRaid() end)
ns.addTab("roster", "Guild notes", function() exportRoster() end)
ns.addTab("notes", "Update notes", function() if lastNotes then showNotes(lastNotes, lastSummary) else importNotes() end end)

local options          -- below, with the options page
local lastTab = "events"
local function showTab(key)
  if not ns.tabs[key] then key = "events" end
  lastTab = key
  db().lastTab = key
  ns.tabs[key]()
end
ns.showTab = showTab

local function toggleWindow()
  if frame:IsShown() then frame:Hide() else showTab(options().keepTab and lastTab or "events") end      -- Events, unless they keep the last tab
end

---------------------------------------------------------------------------------------------------------------------
-- A HAMR tab on the side of the game's guild window, for Update notes. It's our own button that only sits beside it:
-- nothing of the guild window is changed or called, so the game still lets that window save notes.

local docked = {}
local function dockTab(parentName)
  local parent = _G[parentName]
  if docked[parentName] or type(parent) ~= "table" or not parent.CreateTexture then return end
  docked[parentName] = true
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(36, 36)
  b:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", 0, 48)
  local edge = b:CreateTexture(nil, "BACKGROUND", nil, -8)
  edge:SetPoint("TOPLEFT", -1, 1)
  edge:SetPoint("BOTTOMRIGHT", 1, -1)
  edge:SetColorTexture(1, 0.82, 0, 0.6)
  local back = b:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints()
  back:SetColorTexture(0.05, 0.05, 0.05, 0.95)
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("TOPLEFT", 3, -3)
  icon:SetPoint("BOTTOMRIGHT", -3, 3)
  icon:SetTexture(ICON)
  local glow = b:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetColorTexture(1, 0.82, 0, 0.2)
  b:SetScript("OnClick", function()
    if frame:IsShown() then frame:Hide() else showTab(options().keepTab and lastTab or "events") end
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("HAMR Tools")
    GameTooltip:AddLine("Open or close HAMR", 1, 1, 1)
    GameTooltip:AddLine("Drag the HAMR window beside this one; it stays where you put it.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
local docker = CreateFrame("Frame")
docker:RegisterEvent("PLAYER_LOGIN")
docker:RegisterEvent("ADDON_LOADED")        -- the guild window loads when first opened on some clients
docker:SetScript("OnEvent", function()
  dockTab("GuildFrame")
  dockTab("CommunitiesFrame")
end)

---------------------------------------------------------------------------------------------------------------------
-- The minimap button: the clan's crossed hammers. Click to open, drag it round the edge. Retail also lists the addon
-- under the minimap's addon menu (the TOC's AddonCompartmentFunc).

local mini = CreateFrame("Button", "HAMRMinimapButton", Minimap)
mini:SetSize(28, 28)
mini:SetFrameStrata("MEDIUM")
mini:SetFrameLevel(8)
mini:RegisterForClicks("AnyUp")
mini:RegisterForDrag("LeftButton")
local miniIcon = mini:CreateTexture(nil, "ARTWORK")
miniIcon:SetAllPoints()
miniIcon:SetTexture(ICON)
mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local function settings()
  db()
  HAMRDB.minimap = type(HAMRDB.minimap) == "table" and HAMRDB.minimap or {}
  if type(HAMRDB.minimap.angle) ~= "number" then HAMRDB.minimap.angle = 205 end      -- lower left, clear of the clock and mail
  if HAMRDB.minimap.hide == nil then HAMRDB.minimap.hide = true end     -- off at first: the tab on the guild window and /hamr open it
  return HAMRDB.minimap
end

local function placeButton()
  local angle = math.rad(settings().angle)
  local r = (Minimap:GetWidth() or 140) / 2 + 5
  local x, y = math.cos(angle), math.sin(angle)
  if GetMinimapShape and GetMinimapShape() == "SQUARE" then        -- some UIs square the minimap: follow its edge
    x, y = math.max(-r, math.min(r, x * r * 1.42)), math.max(-r, math.min(r, y * r * 1.42))
  else
    x, y = x * r, y * r
  end
  mini:ClearAllPoints()
  mini:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local atan2 = math.atan2 or math.atan
local function followCursor()
  local mx, my = Minimap:GetCenter()
  local scale = Minimap:GetEffectiveScale()
  local cx, cy = GetCursorPosition()
  settings().angle = math.deg(atan2(cy / scale - my, cx / scale - mx))
  placeButton()
end

mini:SetScript("OnDragStart", function(self) self:LockHighlight(); self:SetScript("OnUpdate", followCursor) end)
mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil); self:UnlockHighlight() end)
mini:SetScript("OnClick", function(_, which) if which == "RightButton" then ns.openOptions() else toggleWindow() end end)
mini:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("HAMR Tools")
  GameTooltip:AddLine("Click to open or close", 1, 1, 1)
  GameTooltip:AddLine("Right-click for options", 0.7, 0.7, 0.7)
  GameTooltip:AddLine("Drag to move this button", 0.7, 0.7, 0.7)
  GameTooltip:Show()
end)
mini:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------------------------------------------------------
-- Options: in the game's own Options > AddOns > HAMR, not in the HAMR window. Built from plain frames too: a slider
-- here is a Slider with its own track and the game's long-standing thumb texture, so no template can go missing.

options = function()
  local d = db()
  d.options = type(d.options) == "table" and d.options or {}
  local o = d.options
  if type(o.opacity) ~= "number" then o.opacity = 1 end
  if type(o.scale) ~= "number" then o.scale = 1 end
  return o
end

local function applyOptions()
  local o = options()
  frame:SetScale(o.scale)
  if frame.SetBackdropColor then
    frame:SetBackdropColor(1, 1, 1, o.opacity)
    frame:SetBackdropBorderColor(1, 1, 1, math.max(o.opacity, 0.5))     -- the border stays visible, so the window has an edge
  end
  solid:SetAlpha(o.opacity * o.opacity)       -- solid at 100%, fading faster than the texture so low settings stay clear
  ns.locked = o.locked == true
  ns.raidInvites = o.raidInvites ~= false          -- on unless turned off
  ns.whisperInvites = o.whisperInvites ~= false
  ns.guildChatInvites = o.guildChat ~= false
  ns.outsiders = o.outsiders == true
  ns.autoAssist = o.autoAssist ~= false
  ns.assistRank = (type(o.assistRank) == "string" and trim(o.assistRank) ~= "") and trim(o.assistRank):sub(1, 30) or "Herald"
  local word = trim(tostring(o.keyword or "")):gsub("[^%w]", "")
  ns.keyword = word ~= "" and word:sub(1, 12) or "RFD"
  ns.hiddenTabs.raid = not o.raidTab
  layoutTabs()
  if ns.onOptions then ns.onOptions() end
  if settings().hide then mini:Hide() else mini:Show() end
end

local optionsPanel = CreateFrame("Frame")
optionsPanel:Hide()          -- so the options window's first show of it counts as a show, and fills in the values
optionsPanel.name = "HAMR"
local refreshers = {}

local optTitle = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
optTitle:SetPoint("TOPLEFT", 16, -16)
optTitle:SetText("HAMR Tools")
local optSub = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
optSub:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -6)
optSub:SetWidth(580)
optSub:SetJustifyH("LEFT")
optSub:SetText("Open HAMR with the HAMR tab on the right of the game's guild window, or type /hamr. It opens on Events. "
               .. "These settings are yours alone: nothing here changes anything for other officers.")

local function optSlider(y, label, low, high, step, get, set, shown)
  local s = CreateFrame("Slider", nil, optionsPanel)
  s:SetOrientation("HORIZONTAL")
  s:SetSize(260, 16)
  s:SetPoint("TOPLEFT", 20, y)
  s:SetMinMaxValues(low, high)
  s:SetValueStep(step)
  if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
  s:EnableMouse(true)
  local track = s:CreateTexture(nil, "BACKGROUND")
  track:SetPoint("LEFT")
  track:SetPoint("RIGHT")
  track:SetHeight(6)
  track:SetColorTexture(0, 0, 0, 0.6)
  s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  local title = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 6)
  title:SetText(label)
  local value = s:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  value:SetPoint("LEFT", s, "RIGHT", 12, 0)
  s:SetScript("OnValueChanged", function(_, v)
    v = math.floor(v / step + 0.5) * step
    value:SetText(shown(v))
    set(v)
    applyOptions()
  end)
  refreshers[#refreshers + 1] = function() s:SetValue(get()); value:SetText(shown(get())) end
  return s
end

local function optCheck(y, label, get, set)
  local c = CreateFrame("CheckButton", nil, optionsPanel)
  c:SetSize(24, 24)
  c:SetPoint("TOPLEFT", 16, y)
  c:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
  c:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
  c:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
  c:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
  local text = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("LEFT", c, "RIGHT", 4, 0)
  text:SetText(label)
  c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false); applyOptions() end)
  refreshers[#refreshers + 1] = function() c:SetChecked(get()) end
  return c
end

local function percent(v) return math.floor(v * 100 + 0.5) .. "%" end
optSlider(-90, "Window background", 0.2, 1, 0.05, function() return options().opacity end, function(v) options().opacity = v end, percent)
optSlider(-150, "Window size", 0.7, 1.4, 0.05, function() return options().scale end, function(v) options().scale = v end, percent)
optCheck(-190, "Show the button by the minimap", function() return not settings().hide end, function(on) settings().hide = not on end)
optCheck(-220, "Lock the window in place", function() return options().locked == true end, function(on) options().locked = on end)
optCheck(-250, "Open on the tab I used last, even after logging out", function() return options().keepTab == true end, function(on) options().keepTab = on end)
optCheck(-280, "Show the Raid list tab", function() return options().raidTab == true end, function(on) options().raidTab = on end)
optCheck(-310, "Raid invites on the Events tab (Rebuild, Invite missing); off leaves it to another addon",
         function() return options().raidInvites ~= false end, function(on) options().raidInvites = on end)
optCheck(-338, "Invite whoever whispers the keyword, while you track an event that has it ticked",
         function() return options().whisperInvites ~= false end, function(on) options().whisperInvites = on end)
optCheck(-366, "Also when they say the keyword in guild chat",
         function() return options().guildChat ~= false end, function(on) options().guildChat = on end)
optCheck(-394, "Also whispers from outside the guild (for testing)",
         function() return options().outsiders == true end, function(on) options().outsiders = on end)

-- Raid assist by rank: the rank's name, as this guild calls it (Herald by default); that rank and every one above it.
optCheck(-422, "Raid assist for this guild rank and above, in raids you lead:",
         function() return options().autoAssist ~= false end, function(on) options().autoAssist = on end)
local rankBox = CreateFrame("EditBox", nil, optionsPanel)
rankBox:SetSize(110, 22)
rankBox:SetPoint("TOPLEFT", 470, -423)
rankBox:SetAutoFocus(false)
rankBox:SetMaxLetters(30)
rankBox:SetFontObject(ChatFontNormal)
if rankBox.SetTextInsets then rankBox:SetTextInsets(6, 6, 0, 0) end
local rankBack = rankBox:CreateTexture(nil, "BACKGROUND")
rankBack:SetAllPoints()
rankBack:SetColorTexture(0, 0, 0, 0.5)
local function saveRank(self)
  options().assistRank = self:GetText()
  applyOptions()
  self:SetText(ns.assistRank)
  self:ClearFocus()
end
rankBox:SetScript("OnEnterPressed", saveRank)
rankBox:SetScript("OnEditFocusLost", function(self) if self:GetText() ~= ns.assistRank then saveRank(self) end end)
rankBox:SetScript("OnEscapePressed", function(self) self:SetText(ns.assistRank or "Herald"); self:ClearFocus() end)
refreshers[#refreshers + 1] = function() rankBox:SetText(ns.assistRank or "Herald") end

-- The keyword: the tick beside each event, events named with it start ticked, and the whisper that asks for an invite.
local keyLabel = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
keyLabel:SetPoint("TOPLEFT", 20, -462)
keyLabel:SetText("Keyword")
local keyBox = CreateFrame("EditBox", nil, optionsPanel)
keyBox:SetSize(110, 22)
keyBox:SetPoint("LEFT", keyLabel, "RIGHT", 10, 0)
keyBox:SetAutoFocus(false)
keyBox:SetMaxLetters(12)
keyBox:SetFontObject(ChatFontNormal)
if keyBox.SetTextInsets then keyBox:SetTextInsets(6, 6, 0, 0) end
local keyBack = keyBox:CreateTexture(nil, "BACKGROUND")
keyBack:SetAllPoints()
keyBack:SetColorTexture(0, 0, 0, 0.5)
local keyNote = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
keyNote:SetPoint("TOPLEFT", keyLabel, "BOTTOMLEFT", 0, -10)
keyNote:SetWidth(560)
keyNote:SetJustifyH("LEFT")
keyNote:SetText("The tick's name beside each event, and the word people ask with. Letters and numbers; Enter keeps it; blank is RFD.")
local function saveKeyword(self)
  options().keyword = self:GetText()
  applyOptions()
  self:SetText(ns.keyword)
  self:ClearFocus()
end
keyBox:SetScript("OnEnterPressed", saveKeyword)
keyBox:SetScript("OnEditFocusLost", function(self) if self:GetText() ~= ns.keyword then saveKeyword(self) end end)
keyBox:SetScript("OnEscapePressed", function(self) self:SetText(ns.keyword or "RFD"); self:ClearFocus() end)
refreshers[#refreshers + 1] = function() keyBox:SetText(ns.keyword or "RFD") end

local resetPos = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
resetPos:SetSize(280, 24)
resetPos:SetPoint("TOPLEFT", 20, -518)
resetPos:SetText("Put the window back in the middle")
resetPos:SetScript("OnClick", function()
  if frame.SetUserPlaced then frame:SetUserPlaced(false) end
  frame:ClearAllPoints()
  frame:SetPoint("CENTER")
end)
-- Each control shows the saved value. One that fails doesn't stop the rest, and says why in chat (once).
local refreshFailed
local function refreshOptions()
  for _, refresh in ipairs(refreshers) do
    local ok, err = pcall(refresh)
    if not ok and not refreshFailed then refreshFailed = true; say("Options couldn't show a setting: " .. tostring(err)) end
  end
end
optionsPanel:SetScript("OnShow", refreshOptions)

local optionsCategory
local function registerOptions()
  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsPanel, "HAMR")
    Settings.RegisterAddOnCategory(optionsCategory)
  elseif InterfaceOptions_AddCategory then           -- clients from before the new settings window
    InterfaceOptions_AddCategory(optionsPanel)
  end
end

function ns.openOptions()
  if Settings and Settings.OpenToCategory and optionsCategory then
    local id = optionsCategory.GetID and optionsCategory:GetID() or optionsCategory.ID
    pcall(Settings.OpenToCategory, id)
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    InterfaceOptionsFrame_OpenToCategory(optionsPanel)        -- the old window needs asking twice the first time
  end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
  if event ~= "ADDON_LOADED" or name ~= ADDON_NAME then return end
  self:UnregisterEvent("ADDON_LOADED")
  placeButton()
  applyOptions()
  registerOptions()
  refreshOptions()
  if options().keepTab and type(db().lastTab) == "string" then lastTab = db().lastTab end
  ns.startComms()
end)

function HAMR_OnAddonCompartmentClick()
  toggleWindow()
end

SLASH_HAMR1 = "/hamr"
SlashCmdList.HAMR = function(msg)
  local command = lower(trim(msg or ""))
  if command == "raid" then showTab("raid")
  elseif command == "roster" then showTab("roster")
  elseif command == "notes" then lastNotes = nil; showTab("notes")
  elseif command == "minimap" then
    local s = settings()
    s.hide = not s.hide
    if s.hide then mini:Hide(); say("Minimap button hidden. /hamr minimap brings it back.") else mini:Show() end
    refreshOptions()
  elseif command == "welcome" then showTab("welcome")
  elseif command == "events" then showTab("events")
  elseif command == "options" then ns.openOptions()
  elseif command == "done" then
    local list = recentApplied(10)
    if #list == 0 then say("No event's notes recorded as done yet.") end
    for _, r in ipairs(list) do say(r.title .. ": done by " .. r.by .. ", " .. ago(r.at)) end
  elseif command == "" then toggleWindow()
  else
    say("/hamr - open or close the window (or click the hammers by the minimap)")
    say("/hamr events - the guild's events: start one, track your raid, rebuild a raid, copy the list for the site")
    say("/hamr raid - copy who's in your raid or party, for an event's list")
    say("/hamr roster - copy everyone's tick notes, to check against the site")
    say("/hamr notes - paste the site's totals, then copy each new note into the guild window (also its HAMR tab)")
    say("/hamr welcome - the Onboarding tab, for talking with a recruit")
    say("/hamr done - which events' notes have been updated, and by whom")
    say("/hamr minimap - hide or show the minimap button")
    say("/hamr options - window opacity, size and more (also under Options > AddOns > HAMR)")
  end
end

-- What the addon's other files need from this one.
ns.frame, ns.open, ns.status, ns.hint, ns.action, ns.second = frame, open, status, hint, action, second
ns.showText = showText
ns.applyOptions = applyOptions
ns.sendAddon = sendAddon
ns.say, ns.db, ns.now, ns.trim, ns.lower, ns.shortName = say, db, now, trim, lower, shortName
ns.GAME, ns.ORANGE, ns.GREY, ns.GOLD, ns.GREEN = GAME, ORANGE, GREY, GOLD, GREEN
