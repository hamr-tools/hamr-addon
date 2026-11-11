-- HAMR: copies the raid list and the guild's tick notes out of the game for the HAMR Tools site, and writes the site's
-- totals back into the public notes, one Save click at a time. It only reads the roster and writes notes; nothing is
-- sent anywhere: officers copy and paste.

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

local pending, confirmSaves
local waiter = CreateFrame("Frame")
waiter:SetScript("OnEvent", function()
  if confirmSaves then confirmSaves() end
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

local function writeNote(entry, note)
  if C_GuildInfo and C_GuildInfo.SetNote and entry.guid then
    C_GuildInfo.SetNote(entry.guid, note, true)
  else
    GuildRosterSetPublicNote(entry.index, note)
  end
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
listScroll:SetPoint("TOPLEFT", 24, -146)
listScroll:SetPoint("BOTTOMRIGHT", -44, 54)
well(listScroll)
local list = CreateFrame("Frame", nil, listScroll)
list:SetSize(510, 10)
listScroll:SetScrollChild(list)
local rows = {}

-- Tabs: plain buttons with a gold line under the open one. Other files add theirs with ns.addTab.
local tabButtons, tabCount, currentTab, view = {}, 0, nil, 0
ns.panels, ns.tabs = {}, {}         -- frames hidden whenever a tab opens; {key = function that opens it}

local function tabLook(b, selected)
  b.label:SetFontObject(selected and GameFontHighlight or GameFontNormal)
  b.back:SetColorTexture(1, 1, 1, selected and 0.08 or 0.03)
  if selected then b.line:Show() else b.line:Hide() end
end

function ns.addTab(key, label, run)
  tabCount = tabCount + 1
  local b = CreateFrame("Button", nil, frame)
  b:SetSize(132, 26)
  b:SetPoint("BOTTOMLEFT", divider, "TOPLEFT", (tabCount - 1) * 136, 0)
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
  ns.tabs[key] = run
  tabLook(b, false)
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

local function row(i)
  local r = rows[i]
  if not r then
    r = CreateFrame("Frame", nil, list)
    r:SetSize(510, 48)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * 50)
    if i % 2 == 0 then
      local stripe = r:CreateTexture(nil, "BACKGROUND")
      stripe:SetAllPoints()
      stripe:SetColorTexture(1, 1, 1, 0.04)
    end
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetPoint("LEFT", 6, 0)
    r.text:SetPoint("RIGHT", -100, 0)
    r.text:SetJustifyH("LEFT")
    r.button = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
    r.button:SetSize(90, 22)
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
  if item.info then item.state = "info" return end       -- something to look at, nothing to save
  local have = noteCounts(item.entry.note)
  item.after = withCounts(item.entry.note, item.want)
  item.problem, item.button = nil, "Save"
  if have and have.cta == item.want.cta and have.hw == item.want.hw then
    item.state = item.rankNote and "info" or "same"
  elseif #item.after > MAX_NOTE then
    item.state, item.problem = "long", "The new note would be longer than " .. MAX_NOTE .. " letters. Shorten it by hand."
  elseif not have then
    item.state, item.problem, item.button = "warn", "This isn't a tick note yet. Is it an alt? Pair it with its main on the site instead.", "Replace"
  elseif have.cta > item.want.cta or have.hw > item.want.hw then
    item.state, item.problem, item.button = "warn", "The note is higher than the site. Someone may have changed it by hand: compare with /hamr roster first.", "Lower it"
  else
    item.state = "change"
  end
end

local function drawItem(r, item)
  local note = item.entry.note ~= "" and item.entry.note or GREY .. "(empty)|r"
  local line = GOLD .. item.entry.name .. "|r   " .. note .. (item.state == "info" and "" or ("   ->   " .. item.after))
  local extra = ""
  if item.problem then extra = extra .. "\n" .. ORANGE .. item.problem .. "|r" end
  if item.info then extra = extra .. "\n" .. ORANGE .. item.info .. "|r" end
  if item.rankNote then extra = extra .. "\n" .. GREY .. item.rankNote .. "|r" end
  if item.saved then
    r.text:SetText(line .. "\n" .. GREEN .. "Saved: the game's roster shows the new note.|r")
    r.button:SetText("Saved")
    r.button:Disable()
    return
  elseif item.sending then
    r.text:SetText(line .. "\n" .. GREY .. "Saving, waiting for the game to show it...|r")
    r.button:SetText("Saving")
    r.button:Disable()
    return
  elseif item.unconfirmed then
    r.text:SetText(line .. "\n" .. ORANGE .. "Sent, but the game's roster doesn't show it yet. Retry, or check it in the guild window.|r")
    r.button:Show()
    r.button:SetText("Retry")
    r.button:Enable()
    return
  end
  if item.refused then extra = extra .. "\n" .. ORANGE .. item.refused .. "|r" end
  r.text:SetText(line .. extra)
  if item.state == "info" then r.button:Hide() return end
  r.button:Show()
  r.button:SetText(item.button)
  if item.state == "long" then r.button:Disable() else r.button:Enable() end
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

local function sendAddon(message, channel, target)
  local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if send and IsInGuild() then pcall(send, PREFIX, message, channel, target) end      -- never worth an error
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
  if p[1] == "A" then
    remember(p[2], p[3], p[4], p[5], p[6])
  elseif p[1] == "Q" and shortName(sender or "") ~= UnitName("player") then      -- someone just logged in
    for _, r in ipairs(recentApplied(5)) do sendAddon(wireRecord(r), "WHISPER", sender) end
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

local checking = {}        -- notes sent to the game, waiting for its roster to show them: {item = row}

local function save(r, item)
  local fresh
  for _, e in ipairs(rosterEntries()) do
    if e.name == item.entry.name then fresh = e break end
  end
  if not fresh then
    r.text:SetText(GOLD .. item.entry.name .. "|r\n" .. ORANGE .. "Not in the guild any more.|r")
    r.button:Disable()
    return
  end
  if fresh.note == item.after then              -- a Retry, and the first one went through after all
    item.sending, item.unconfirmed, item.refused, item.saved = nil, nil, nil, true
    markApplied(item.event)
    drawItem(r, item)
    return
  end
  if fresh.note ~= item.entry.note then        -- someone else changed it since the check
    item.entry = fresh
    judge(item)
    drawItem(r, item)
    status:SetText(ORANGE .. item.entry.name .. "'s note changed since you checked. Look again before saving.|r")
    return
  end
  if not canEditNotes() then
    status:SetText(ORANGE .. "Your guild rank can't edit public notes.|r")
    return
  end
  if InCombatLockdown and InCombatLockdown() then
    status:SetText(ORANGE .. "Notes can't be saved in combat. Try again once it's over.|r")
    return
  end
  -- Saved only once the game's own roster shows the new note: that's the proof it was written.
  item.sending, item.unconfirmed, item.refused = true, nil, nil
  checking[item] = r
  drawItem(r, item)
  local ok, err = pcall(writeNote, fresh, item.after)
  if not ok then
    checking[item], item.sending = nil, nil
    item.refused = "The game refused the change: " .. tostring(err)
    drawItem(r, item)
    return
  end
  if not item.sending then return end           -- the game blocked it while we called (see blocked below)
  status:SetText("Saving " .. item.entry.name .. "...")
  askForRoster()
  C_Timer.After(4, function() confirmSaves(item) end)
end

-- Every roster update checks the notes we sent. After a few seconds without the new note, the row says so.
confirmSaves = function(giveUp)
  if not next(checking) then return end
  local notes = {}
  for _, e in ipairs(rosterEntries()) do notes[e.name] = e.note end
  for item, r in pairs(checking) do
    if notes[item.entry.name] == item.after then
      checking[item] = nil
      item.sending, item.saved = nil, true
      markApplied(item.event)
      drawItem(r, item)
      status:SetText("Saved " .. item.entry.name .. ".")
    elseif giveUp == item then
      checking[item] = nil
      item.sending, item.unconfirmed = nil, true
      drawItem(r, item)
    end
  end
end

-- If Blizzard ever stops addons writing notes, the game says so with this event instead of an error.
local blocked = CreateFrame("Frame")
blocked:RegisterEvent("ADDON_ACTION_FORBIDDEN")
blocked:RegisterEvent("ADDON_ACTION_BLOCKED")
blocked:SetScript("OnEvent", function(_, event, addon, what)
  if addon ~= ADDON_NAME then return end
  for item, r in pairs(checking) do
    checking[item], item.sending = nil, nil
    item.refused = "The game doesn't let addons write notes right now (" .. tostring(what) .. "). Change it by hand in the guild window."
    drawItem(r, item)
  end
  status:SetText(ORANGE .. "The game blocked HAMR from saving a note.|r")
end)

local importNotes
local lastNotes, lastSummary         -- the checked list stays while you look at another tab

-- Where you are in updating the notes: paste, check, save. Done steps are green, the current one gold.
local STEPS = { "Paste", "Check", "Save" }
local function steps(current)
  local parts = {}
  for i, name in ipairs(STEPS) do
    local text = "Step " .. i .. ": " .. name
    parts[i] = (i < current and (GREEN .. text .. "|r")) or (i == current and (GOLD .. text .. "|r")) or (GREY .. text .. "|r")
  end
  return table.concat(parts, GREY .. "    >    |r")
end

local function showNotes(items, summary)
  lastNotes, lastSummary = items, summary
  open("notes", steps(3) .. "\n" .. summary)
  textScroll:Hide()
  listScroll:Show()
  for _, r in ipairs(rows) do r:Hide() end
  for i, item in ipairs(items) do
    local r = row(i)
    drawItem(r, item)
    r.button:SetScript("OnClick", function() save(r, item) end)
  end
  list:SetHeight(math.max(#items * 50, 10))
  listScroll:SetVerticalScroll(0)
  if #items == 0 then status:SetText("Every note already matches the site.") end
  second:SetText("Paste again")
  second:SetScript("OnClick", function() lastNotes = nil; importNotes() end)
  second:Show()
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
    local order = { change = 1, warn = 2, long = 3, info = 4 }
    table.sort(items, function(a, b)
      if order[a.state] ~= order[b.state] then return order[a.state] < order[b.state] end
      return a.entry.name < b.entry.name
    end)
    local changes, flags = 0, 0
    for _, item in ipairs(items) do if item.state == "info" then flags = flags + 1 else changes = changes + 1 end end
    local summary = changes .. " to change, " .. same .. " already right" .. (flags > 0 and (", " .. flags .. " to look at (nothing to save).") or ".")
    if #missing > 0 then summary = summary .. " Not in the guild: " .. table.concat(missing, ", ", 1, math.min(#missing, 8)) .. (#missing > 8 and "..." or "") end
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
    showText("roster", "Press Ctrl+C to copy, then paste it under \"Compare with the game\" on the site's Tallies page. " .. count .. " tick notes.",
             table.concat(lines, "\n"), "Read again", function() exportRoster() end)
  end)
end

importNotes = function()
  local last = recentApplied(1)[1]
  showPaste("notes", steps(1) .. "\nOn the site, press \"Copy for the addon\" (a published event, or \"Copy all\" on Tallies), paste it here (Ctrl+V), then Check.",
            "Check", readTotals)
  if last then status:SetText(GREY .. "Last done: " .. last.title .. ", by " .. last.by .. ", " .. ago(last.at) .. ". /hamr done lists more.|r") end
end

ns.addTab("raid", "Raid list", function() exportRaid() end)
ns.addTab("roster", "Guild notes", function() exportRoster() end)
ns.addTab("notes", "Update notes", function() if lastNotes then showNotes(lastNotes, lastSummary) else importNotes() end end)

local lastTab = "raid"
local function showTab(key)
  if not ns.tabs[key] then key = "raid" end
  lastTab = key
  db().lastTab = key
  ns.tabs[key]()
end
ns.showTab = showTab

local function toggleWindow()
  if frame:IsShown() then frame:Hide() else showTab(lastTab) end
end

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

local function options()
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
  if settings().hide then mini:Hide() else mini:Show() end
end

local optionsPanel = CreateFrame("Frame")
optionsPanel.name = "HAMR"
local refreshers = {}

local optTitle = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
optTitle:SetPoint("TOPLEFT", 16, -16)
optTitle:SetText("HAMR Tools")
local optSub = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
optSub:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -6)
optSub:SetText("Type /hamr, or click the hammers by the minimap, to open the window.")

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
local resetPos = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
resetPos:SetSize(280, 24)
resetPos:SetPoint("TOPLEFT", 20, -292)
resetPos:SetText("Put the window back in the middle")
resetPos:SetScript("OnClick", function()
  if frame.SetUserPlaced then frame:SetUserPlaced(false) end
  frame:ClearAllPoints()
  frame:SetPoint("CENTER")
end)
optionsPanel:SetScript("OnShow", function() for _, refresh in ipairs(refreshers) do refresh() end end)

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
  elseif command == "welcome" then showTab("welcome")
  elseif command == "options" then ns.openOptions()
  elseif command == "done" then
    local list = recentApplied(10)
    if #list == 0 then say("No event's notes recorded as done yet.") end
    for _, r in ipairs(list) do say(r.title .. ": done by " .. r.by .. ", " .. ago(r.at)) end
  elseif command == "" then toggleWindow()
  else
    say("/hamr - open or close the window (or click the hammers by the minimap)")
    say("/hamr raid - copy who's in your raid or party, for an event's list")
    say("/hamr roster - copy everyone's tick notes, to check against the site")
    say("/hamr notes - paste the site's totals and save the notes that changed, one at a time")
    say("/hamr welcome - the Onboarding tab, for talking with a recruit")
    say("/hamr done - which events' notes have been updated, and by whom")
    say("/hamr minimap - hide or show the minimap button")
    say("/hamr options - window opacity, size and more (also under Options > AddOns > HAMR)")
  end
end

-- What the addon's other files need from this one.
ns.frame, ns.open, ns.status, ns.hint, ns.action, ns.second = frame, open, status, hint, action, second
ns.showText = showText
ns.say, ns.db, ns.now, ns.trim, ns.lower, ns.shortName = say, db, now, trim, lower, shortName
ns.GAME, ns.ORANGE, ns.GREY, ns.GOLD, ns.GREEN = GAME, ORANGE, GREY, GOLD, GREEN
