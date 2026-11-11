-- HAMR onboarding: a hand for the officer welcoming a recruit, never a voice. Nothing is sent for you: the clan's
-- recruiting is people talking to people. A recruit whispers an officer; they're listed here (guild members hidden,
-- unless asked) with their race. Reply opens your chat box to them, and you write it yourself. The talking points are
-- your own reminders, ticked as you cover them in conversation, and the notes are yours too. Then invite, and the
-- outcome goes in the history. Kept across reloads for a week. Built from plain frames like the rest of the window.

local _, ns = ...
if not (ns and ns.addTab) then return end

local ORANGE, GREY, GOLD, GREEN = ns.ORANGE, ns.GREY, ns.GOLD, ns.GREEN
local SHOWN = 6                 -- rows in the list
local KEEP = 20                 -- whisperers remembered
local KEEP_DAYS = 7
local HISTORY = 200             -- outcomes kept: joined, didn't join, went quiet
local RESULTS = { joined = "Joined", declined = "Didn't join", quiet = "Went quiet" }

-- Reminders for the officer, in their own words: topics to cover, not messages. Each can be reworded and is kept.
local POINTS = {
  { key = "hello", text = "Say hello, and who we are" },
  { key = "history", text = "The clan's history and our King" },
  { key = "discord", text = "Our Discord" },
  { key = "cta", text = "Call to Arms, and how ranks are earned" },
}

local function store()
  local d = ns.db()
  local w = type(d.welcome) == "table" and d.welcome or {}
  d.welcome = w
  w.points = type(w.points) == "table" and w.points or {}       -- the officer's own wording of each talking point
  w.recent = type(w.recent) == "table" and w.recent or {}       -- whisperers, newest first: {name, guid, race, raceKey, first, at, covered, note, invited}
  w.history = type(w.history) == "table" and w.history or {}     -- how each recruit turned out, newest first
  return w
end

local function recent() return store().recent end

local focus             -- the recruit being talked to: one of recent()

local function coveredCount(p)
  local n = 0
  for _, done in pairs(type(p.covered) == "table" and p.covered or {}) do if done then n = n + 1 end end
  return n
end

-- Takes someone off the list. With a result, it goes in the history; without one (not a recruit), they're just gone.
local function close(p, result)
  local list = recent()
  for i = #list, 1, -1 do if list[i] == p then table.remove(list, i) end end
  if focus == p then focus = nil end
  if not result then return end
  local h = store().history
  table.insert(h, 1, { name = p.name, race = p.race, first = p.first or p.at, at = ns.now(), result = result, by = UnitName("player") or "",
                       covered = coveredCount(p), invited = p.invited, note = p.note })
  while #h > HISTORY do table.remove(h) end
end

local pruned = false
local function prune()          -- once a session: anyone silent for a week leaves the list; if we'd talked, they went quiet
  if pruned then return end
  pruned = true
  local list = recent()
  for i = #list, 1, -1 do
    local p = list[i]
    if type(p) ~= "table" then table.remove(list, i)
    elseif (ns.now() - (p.at or 0)) > KEEP_DAYS * 86400 then close(p, (coveredCount(p) > 0 or (p.note or "") ~= "") and "quiet" or nil) end
  end
end

local function isDwarf(raceKey) return raceKey ~= nil and raceKey:find("Dwarf") ~= nil end       -- Dark Iron dwarves too

local function guildNames()
  local names = {}
  if IsInGuild() then
    for i = 1, (GetNumGuildMembers() or 0) do
      local name = GetGuildRosterInfo(i)
      if name then
        names[ns.lower(name)] = true
        names[ns.lower(ns.shortName(name))] = true
      end
    end
  end
  return names
end

local function inGuild(p, names)
  return names[ns.lower(p.name)] or names[ns.lower(ns.shortName(p.name))] or false
end

local function raceLine(p, member)
  local line
  if not p.race then line = GREY .. "race unknown|r"
  elseif isDwarf(p.raceKey) then line = GREEN .. p.race .. "|r"
  else line = ORANGE .. p.race .. ": not a dwarf|r" end
  return member and (line .. GREY .. " · in the guild|r") or line
end

---------------------------------------------------------------------------------------------------------------------
-- The panel: recent whispers down the left; on the right the recruit, your talking points, your notes and the invite.

local panel = CreateFrame("Frame", nil, ns.frame)
panel:SetPoint("TOPLEFT", 24, -132)
panel:SetPoint("BOTTOMRIGHT", -24, 54)
panel:Hide()
table.insert(ns.panels, panel)

local function checkbox(x, y, label)
  local box = CreateFrame("CheckButton", nil, panel)
  box:SetSize(22, 22)
  box:SetPoint("TOPLEFT", x, y)
  box:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
  box:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
  box:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
  box:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
  if label then
    local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", box, "RIGHT", 2, 0)
    text:SetText(label)
  end
  return box
end

local function textBox(x, y, width)
  local box = CreateFrame("EditBox", nil, panel)
  box:SetSize(width, 22)
  box:SetPoint("TOPLEFT", x, y)
  box:SetAutoFocus(false)
  box:SetMaxLetters(200)
  box:SetFontObject(ChatFontNormal)
  box:SetTextInsets(6, 6, 0, 0)
  local back = box:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints()
  back:SetColorTexture(0, 0, 0, 0.45)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEditFocusLost", function(self) self:SetCursorPosition(0) end)
  return box
end

local function setBox(box, text)        -- shows the start of a long line, not its end
  if box:HasFocus() then return end
  box:SetText(text)
  box:SetCursorPosition(0)
end

local function button(width, text)
  local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  return b
end

local whoLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
whoLabel:SetPoint("TOPLEFT", 0, 0)
whoLabel:SetPoint("RIGHT", panel, "LEFT", 150, 0)
whoLabel:SetJustifyH("LEFT")
local picks = {}
for i = 1, SHOWN do
  local b = CreateFrame("Button", nil, panel)
  b:SetSize(150, 32)
  b:SetPoint("TOPLEFT", 0, -16 - (i - 1) * 34)
  b.back = b:CreateTexture(nil, "BACKGROUND")
  b.back:SetAllPoints()
  local glow = b:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetColorTexture(1, 0.82, 0, 0.1)
  b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.name:SetPoint("TOPLEFT", 6, -4)
  b.name:SetPoint("RIGHT", -4, 0)
  b.name:SetJustifyH("LEFT")
  b.race = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.race:SetPoint("BOTTOMLEFT", 6, 4)
  b.race:SetPoint("RIGHT", -4, 0)
  b.race:SetJustifyH("LEFT")
  picks[i] = b
end
local showGuild = checkbox(0, -18 - SHOWN * 34, "Show guild members")
local useTarget = button(150, "Use my target")
useTarget:SetPoint("TOPLEFT", 0, -46 - SHOWN * 34)

local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
header:SetPoint("TOPLEFT", 166, -4)
header:SetPoint("RIGHT", -92, 0)
header:SetJustifyH("LEFT")
local reply = button(86, "Reply")
reply:SetPoint("TOPRIGHT", 0, 0)

local pointsLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
pointsLabel:SetPoint("TOPLEFT", 166, -32)
pointsLabel:SetText("Talking points " .. GREY .. "· yours to tick as you go; nothing is sent|r")
local points = {}
for i, pt in ipairs(POINTS) do
  local y = -48 - (i - 1) * 28
  local row = { key = pt.key, default = pt.text }
  row.check = checkbox(166, y)
  row.box = textBox(192, y, 360)
  row.box:SetScript("OnTextChanged", function(self, typed) if typed then store().points[pt.key] = self:GetText() end end)
  row.check:SetScript("OnClick", function(self)
    if not focus then self:SetChecked(false) return end
    focus.covered = type(focus.covered) == "table" and focus.covered or {}
    focus.covered[pt.key] = self:GetChecked() and true or false
  end)
  points[i] = row
end

local notesLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
notesLabel:SetPoint("TOPLEFT", 166, -166)
notesLabel:SetText("Notes " .. GREY .. "· for you: what they play, when, who brought them|r")
local notes = textBox(166, -182, 386)
notes:SetScript("OnTextChanged", function(self, typed) if typed and focus then focus.note = self:GetText() end end)

local invite = button(130, "Guild invite")
invite:SetPoint("TOPLEFT", 166, -222)
local declined = button(110, "Didn't join")
declined:SetPoint("LEFT", invite, "RIGHT", 6, 0)
local notRecruit = button(110, "Not a recruit")
notRecruit:SetPoint("LEFT", declined, "RIGHT", 6, 0)

local draw

local function enable(b, on) if on then b:Enable() else b:Disable() end end

draw = function()
  prune()
  showGuild:SetChecked(store().showGuild == true)
  local members, shown, joined = guildNames(), {}, {}
  for _, p in ipairs(recent()) do
    p.member = inGuild(p, members)
    if p.invited and p.member then joined[#joined + 1] = p end         -- invited, and now in the roster: they joined
  end
  for _, p in ipairs(joined) do close(p, "joined") end
  local hidden = 0
  for _, p in ipairs(recent()) do
    if (store().showGuild or not p.member) and #shown < SHOWN then shown[#shown + 1] = p end
    if p.member then hidden = hidden + 1 end
  end
  if #shown > 0 then whoLabel:SetText("Recent whispers")
  elseif hidden > 0 and not store().showGuild then whoLabel:SetText(GREY .. "Only guild members so far|r")
  else whoLabel:SetText(GREY .. "No whispers yet|r") end
  for i, b in ipairs(picks) do
    local p = shown[i]
    if p then
      b.name:SetText(p.name)
      b.race:SetText(raceLine(p, p.member))
      b.back:SetColorTexture(1, 0.82, 0, p == focus and 0.18 or 0.04)
      b:SetScript("OnClick", function() focus = p; draw() end)
      b:Show()
    else
      b:Hide()
    end
  end
  if focus then
    header:SetText(GOLD .. focus.name .. "|r   " .. raceLine(focus, focus.member))
  else
    header:SetText(GREY .. "When a recruit whispers you, pick them on the left.|r")
  end
  local covered = focus and type(focus.covered) == "table" and focus.covered or {}
  for _, row in ipairs(points) do
    setBox(row.box, store().points[row.key] or row.default)
    row.check:SetChecked(covered[row.key] == true)
    enable(row.check, focus)
  end
  setBox(notes, focus and focus.note or "")
  enable(notes, focus)
  enable(reply, focus)
  invite:SetText(focus and focus.invited and "Invited" or "Guild invite")
  enable(invite, focus and not focus.invited)
  enable(declined, focus)
  enable(notRecruit, focus)
end

-- Opens the chat box addressed to them, like clicking their name in chat. The words are the officer's.
reply:SetScript("OnClick", function()
  if not focus then return end
  if ChatFrame_SendTell then ChatFrame_SendTell(focus.name)
  elseif ChatFrameUtil and ChatFrameUtil.SendTell then ChatFrameUtil.SendTell(focus.name) end
end)

invite:SetScript("OnClick", function()
  if not focus then return end
  if CanGuildInvite and not CanGuildInvite() then
    ns.status:SetText(ORANGE .. "Your guild rank can't invite.|r")
    return
  end
  local send = (C_GuildInfo and C_GuildInfo.Invite) or GuildInvite
  local ok, err = pcall(send, focus.name)
  if not ok then ns.status:SetText(ORANGE .. "The game didn't send the invite: " .. tostring(err) .. "|r") return end
  focus.invited = true
  ns.status:SetText("Invited " .. focus.name .. ". They'll move to the history once they've joined.")
  draw()
end)

declined:SetScript("OnClick", function()
  if focus then ns.status:SetText(focus.name .. ": didn't join, in the history."); close(focus, "declined"); draw() end
end)
notRecruit:SetScript("OnClick", function()
  if focus then ns.status:SetText(focus.name .. " is off the list."); close(focus, nil); draw() end
end)
showGuild:SetScript("OnClick", function(self) store().showGuild = self:GetChecked() and true or false; draw() end)

---------------------------------------------------------------------------------------------------------------------
-- The history: how each recruit turned out, as text to copy.

local showWelcome
local function historyText()
  local lines = {}
  for _, h in ipairs(store().history) do
    local what = { RESULTS[h.result] or h.result }
    if h.invited then what[#what + 1] = "invited" end
    if h.covered and h.covered > 0 then what[#what + 1] = h.covered .. " of " .. #POINTS .. " points covered" end
    lines[#lines + 1] = date("%Y-%m-%d", h.at) .. "  " .. h.name .. (h.race and (" (" .. h.race .. ")") or "") .. "  " .. table.concat(what, ", ")
                        .. (h.by ~= "" and ("  · " .. h.by) or "") .. ((h.note or "") ~= "" and ("  · " .. h.note) or "")
  end
  return #lines > 0 and table.concat(lines, "\n") or "Nobody yet. Recruits land here when they join, say no, or go quiet for a week."
end

local function showHistory()
  ns.showText("welcome", "Recruits you've talked to, newest first. Press Ctrl+C to copy.", historyText(), "Back", function() showWelcome() end)
end

---------------------------------------------------------------------------------------------------------------------
-- Who's been whispering: newest first, with their race when the game knows it. Kept in HAMRDB, so a reload or the
-- next evening still has them, with your ticks and notes.

local function remember(name, guid, race, raceKey)
  if not name or name == "" then return end
  prune()
  local list, p = recent(), nil
  for i = #list, 1, -1 do
    if list[i].name == name then p = table.remove(list, i) end
  end
  p = p or { name = name, covered = {}, first = ns.now() }
  p.guid, p.race, p.raceKey, p.at = guid or p.guid, race or p.race, raceKey or p.raceKey, ns.now()
  table.insert(list, 1, p)
  while #list > KEEP do table.remove(list) end
  return p
end

local listener = CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_WHISPER")
listener:SetScript("OnEvent", function(_, event, _, sender, ...)
  if event ~= "CHAT_MSG_WHISPER" then return end
  local guid = select(10, ...)       -- the event's 12th value
  pcall(function()          -- chat details can be off limits to addons at times: then the whisper just isn't listed
    local race, raceKey
    if guid and GetPlayerInfoByGUID then
      local _, _, r, key = GetPlayerInfoByGUID(guid)
      race, raceKey = r, key
    end
    local p = remember(sender, guid, race, raceKey)
    p.member = inGuild(p, guildNames())
    if not focus and not p.member then focus = p end       -- a recruit, not a clanmate saying hello
    if panel:IsShown() then draw() end
  end)
end)

useTarget:SetScript("OnClick", function()
  if not (UnitExists("target") and UnitIsPlayer("target")) then
    ns.status:SetText(ORANGE .. "Target a player first.|r")
    return
  end
  local name = (GetUnitName and GetUnitName("target", true)) or UnitName("target")
  local race, raceKey = UnitRace("target")
  focus = remember(name, UnitGUID and UnitGUID("target"), race, raceKey)        -- picked on purpose: shown even if in the guild
  draw()
end)

showWelcome = function()
  ns.open("welcome", "When a recruit whispers you, they're listed here. Talk to them yourself: Reply opens your chat to them.\n"
          .. GREY .. "Nothing here is sent for you. The talking points and notes are your own reminders.|r")
  panel:Show()
  ns.second:SetText("History")
  ns.second:SetScript("OnClick", showHistory)
  ns.second:Show()
  draw()
end
ns.addTab("welcome", "Onboarding", function() showWelcome() end)
