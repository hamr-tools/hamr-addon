-- HAMR onboarding: welcoming a recruit. A recruit whispers an officer; they're listed here (guild members hidden,
-- unless asked), with their race. The officer sends the clan's messages one click each, tells the guild they're
-- coming, then invites them. The messages are the officer's own to edit. The list, and what was sent to whom, are kept
-- across reloads for a week. Built from plain frames like the rest of the window.

local _, ns = ...
if not (ns and ns.addTab) then return end

local ORANGE, GREY, GOLD, GREEN = ns.ORANGE, ns.GREY, ns.GOLD, ns.GREEN
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t "
local SHOWN = 6                 -- rows in the list
local KEEP = 20                 -- whisperers remembered
local KEEP_DAYS = 7
local HISTORY = 200             -- outcomes kept: joined, didn't join, went quiet
local RESULTS = { joined = "Joined", declined = "Didn't join", quiet = "Went quiet" }

-- Placeholders: the officers write the clan's own words, and they're kept.
local MESSAGES = {
  { key = "greet", title = "Greeting", text = "Lorem ipsum dolor sit amet, {name}. Consectetur adipiscing elit, {me}." },
  { key = "history", title = "Our history", text = "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua." },
  { key = "discord", title = "Discord", text = "Ut enim ad minim veniam, quis nostrud exercitation: (Discord invite link)" },
  { key = "next", title = "Next steps", text = "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum." },
}
local TO_GUILD = {
  new = "Lorem ipsum! {name} dolor sit amet, consectetur adipiscing elit.",
  alt = "Lorem ipsum: {name}, an alt, dolor sit amet.",
}

local function store()
  local d = ns.db()
  local w = type(d.welcome) == "table" and d.welcome or {}
  d.welcome = w
  w.texts = type(w.texts) == "table" and w.texts or {}
  w.recent = type(w.recent) == "table" and w.recent or {}       -- whisperers, newest first: {name, guid, race, raceKey, first, at, sent, told, invited}
  w.history = type(w.history) == "table" and w.history or {}     -- how each recruit turned out, newest first
  return w
end

local function textFor(key, default) return store().texts[key] or default end

local function recent() return store().recent end

local focus             -- the recruit being talked to: one of recent()

local function sentCount(p)
  local n = 0
  for _ in pairs(type(p.sent) == "table" and p.sent or {}) do n = n + 1 end
  return n
end

-- Takes someone off the list. With a result, it goes in the history; without one (not a recruit), they're just gone.
local function close(p, result)
  local list = recent()
  for i = #list, 1, -1 do if list[i] == p then table.remove(list, i) end end
  if focus == p then focus = nil end
  if not result then return end
  local h = store().history
  table.insert(h, 1, { name = p.name, race = p.race, first = p.first or p.at, at = ns.now(), result = result,
                       by = UnitName("player") or "", sent = sentCount(p), told = p.told, invited = p.invited })
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
    elseif (ns.now() - (p.at or 0)) > KEEP_DAYS * 86400 then close(p, (sentCount(p) > 0 or p.told) and "quiet" or nil) end
  end
end

local function firstName(name)
  local plain = (name or ""):match("^([^%-]+)") or name or ""
  return plain:match("^(%S+)") or plain
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

local function fill(text)
  local out = text:gsub("{name}", firstName(focus and focus.name)):gsub("{me}", UnitName("player") or "")
  return out
end

local function chat(text, kind, target)
  local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  local ok, err = pcall(send, text, kind, nil, target)
  if not ok then ns.status:SetText(ORANGE .. "The game didn't send it: " .. tostring(err) .. "|r") end
  return ok
end

---------------------------------------------------------------------------------------------------------------------
-- The panel: recent whispers down the left; the messages, the word to the guild and the invite on the right.

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
  local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT", box, "RIGHT", 2, 0)
  text:SetText(label)
  return box
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
local useTarget = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
useTarget:SetSize(150, 22)
useTarget:SetPoint("TOPLEFT", 0, -46 - SHOWN * 34)
useTarget:SetText("Use my target")

local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
header:SetPoint("TOPLEFT", 166, 0)
header:SetPoint("RIGHT", 0, 0)
header:SetJustifyH("LEFT")

local function textBox(x, y, width)
  local box = CreateFrame("EditBox", nil, panel)
  box:SetSize(width, 22)
  box:SetPoint("TOPLEFT", x, y)
  box:SetAutoFocus(false)
  box:SetMaxLetters(255)               -- the most one chat message holds
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

local function setBox(box, text)        -- shows the start of a long message, not its end
  if box:HasFocus() then return end
  box:SetText(text)
  box:SetCursorPosition(0)
end

local draw
local rows = {}
for i, m in ipairs(MESSAGES) do
  local y = -22 - (i - 1) * 44
  local r = {}
  r.label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  r.label:SetPoint("TOPLEFT", 166, y)
  r.label:SetText(m.title)
  r.box = textBox(166, y - 14, 300)
  r.box:SetScript("OnTextChanged", function(self, typed) if typed then store().texts[m.key] = self:GetText() end end)
  r.button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  r.button:SetSize(80, 22)
  r.button:SetPoint("LEFT", r.box, "RIGHT", 6, 0)
  r.button:SetScript("OnClick", function()
    local text = ns.trim(r.box:GetText())
    if text == "" then ns.status:SetText(ORANGE .. "Write something under " .. m.title .. " first.|r") return end
    if focus and chat(fill(text), "WHISPER", focus.name) then
      focus.sent = type(focus.sent) == "table" and focus.sent or {}
      focus.sent[m.key] = true
      draw()
    end
  end)
  r.key, r.default = m.key, m.text
  rows[i] = r
end

local guildLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
guildLabel:SetPoint("TOPLEFT", 166, -206)
guildLabel:SetText("To the guild")
local alt = checkbox(400, -201, "It's an alt")
local guildBox = textBox(166, -222, 300)
local tell = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
tell:SetSize(80, 22)
tell:SetPoint("LEFT", guildBox, "RIGHT", 6, 0)
local invite = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
invite:SetSize(150, 24)
invite:SetPoint("TOPLEFT", 166, -256)
local declined = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
declined:SetSize(110, 24)
declined:SetPoint("LEFT", invite, "RIGHT", 6, 0)
declined:SetText("Didn't join")
local notRecruit = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
notRecruit:SetSize(110, 24)
notRecruit:SetPoint("LEFT", declined, "RIGHT", 6, 0)
notRecruit:SetText("Not a recruit")

local function guildKey() return alt:GetChecked() and "alt" or "new" end
guildBox:SetScript("OnTextChanged", function(self, typed) if typed then store().texts["guild_" .. guildKey()] = self:GetText() end end)
alt:SetScript("OnClick", function() guildBox:SetText(textFor("guild_" .. guildKey(), TO_GUILD[guildKey()])); guildBox:SetCursorPosition(0) end)
showGuild:SetScript("OnClick", function(self) store().showGuild = self:GetChecked() and true or false; draw() end)

local function sentButton(button, done, label, doneLabel)
  button:SetText(done and (CHECK .. doneLabel) or label)
  if focus then button:Enable() else button:Disable() end
end

draw = function()
  prune()
  showGuild:SetChecked(store().showGuild == true)
  local members, shown, joined = guildNames(), {}, {}
  for _, p in ipairs(recent()) do
    p.member = inGuild(p, members)
    if p.invited and p.member then joined[#joined + 1] = p end         -- invited, and now in the roster: they joined
  end
  for _, p in ipairs(joined) do close(p, "joined") end
  for _, p in ipairs(recent()) do
    if (store().showGuild or not p.member) and #shown < SHOWN then shown[#shown + 1] = p end
  end
  local hidden = 0
  for _, p in ipairs(recent()) do if p.member then hidden = hidden + 1 end end
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
    header:SetText(GREY .. "When a recruit whispers you, pick them on the left (or target them).|r")
  end
  local sent = focus and type(focus.sent) == "table" and focus.sent or {}
  for _, r in ipairs(rows) do
    setBox(r.box, textFor(r.key, r.default))
    sentButton(r.button, sent[r.key], "Whisper", "Sent")
  end
  setBox(guildBox, textFor("guild_" .. guildKey(), TO_GUILD[guildKey()]))
  sentButton(tell, focus and focus.told, "Tell guild", "Told")
  invite:SetText(focus and focus.invited and (CHECK .. "Invited") or "Guild invite")
  if focus and focus.told and not focus.invited then invite:Enable() else invite:Disable() end      -- lights up once the guild knows
  if focus then declined:Enable(); notRecruit:Enable() else declined:Disable(); notRecruit:Disable() end
end

declined:SetScript("OnClick", function()
  if focus then ns.status:SetText(focus.name .. ": didn't join, in the history."); close(focus, "declined"); draw() end
end)
notRecruit:SetScript("OnClick", function()
  if focus then ns.status:SetText(focus.name .. " is off the list."); close(focus, nil); draw() end
end)

local showWelcome
local function historyText()
  local lines = {}
  for _, h in ipairs(store().history) do
    local what = { RESULTS[h.result] or h.result }
    if h.invited then what[#what + 1] = "invited" end
    if h.sent and h.sent > 0 then what[#what + 1] = h.sent .. (h.sent == 1 and " message" or " messages") end
    lines[#lines + 1] = date("%Y-%m-%d", h.at) .. "  " .. h.name .. (h.race and (" (" .. h.race .. ")") or "") .. "  " .. table.concat(what, ", ")
                        .. (h.by ~= "" and ("  · " .. h.by) or "")
  end
  return #lines > 0 and table.concat(lines, "\n") or "Nobody yet. Recruits land here when they join, say no, or go quiet for a week."
end

local function showHistory()
  ns.showText("welcome", "Recruits you've talked to, newest first. Press Ctrl+C to copy.", historyText(), "Back", function() showWelcome() end)
end

tell:SetScript("OnClick", function()
  local text = ns.trim(guildBox:GetText())
  if text == "" or not focus then return end
  if chat(fill(text), "GUILD") then
    focus.told = true
    draw()
  end
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
  ns.status:SetText("Invited " .. focus.name .. ".")
  draw()
end)

---------------------------------------------------------------------------------------------------------------------
-- Who's been whispering: newest first, with their race when the game knows it. Kept in HAMRDB, so a reload or the
-- next evening still has them, along with what was already sent.

local function remember(name, guid, race, raceKey)
  if not name or name == "" then return end
  prune()
  local list, p = recent(), nil
  for i = #list, 1, -1 do
    if list[i].name == name then p = table.remove(list, i) end
  end
  p = p or { name = name, sent = {} }
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
    p.first = p.first or p.at
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
  focus.first = focus.first or focus.at
  draw()
end)

showWelcome = function()
  ns.open("welcome", "Welcome a recruit: when they whisper you, whisper what fits, tell the guild, then invite.\n"
          .. GREY .. "Edit any message and it's kept. {name} becomes their name, {me} yours.|r")
  panel:Show()
  ns.second:SetText("History")
  ns.second:SetScript("OnClick", showHistory)
  ns.second:Show()
  draw()
end
ns.addTab("welcome", "Onboarding", function() showWelcome() end)
