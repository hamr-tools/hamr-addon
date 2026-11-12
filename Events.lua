-- HAMR events: a named event anyone in the guild can create (its creator's rank is shown with it), shared with every
-- guildie running the addon. "Open raid" ties your raid to an event, so overlapping events never mix: from then on
-- everyone in your raid is added to that event's list and stays on it (people swap raids to change layers, so the list
-- only grows), with a mark for anyone who had raid assist. Each tied raid tells the others how many it has right now,
-- so the event shows one live total across all its raids. "Copy for the site" gives a list the event page's "Who was
-- there" box takes as it is; the Raid list tab stays for doing it by hand. Archived events stay here to look back on.
--
-- Shared over the guild's addon channel (prefix HAMR, see HAMR.lua), one message per line of tab-separated fields:
--   E  id  title  by  rank  created  status  changed  changedBy    an event, or its new status: the latest change wins
--   P  id  name,name*,...                                            people seen (* had raid assist): lists only grow
--   L  id  leader  count                                             a tied raid's size now (0: closed), every minute
-- An addon that logs in asks with Q (HAMR.lua); the others whisper it what's open or changed lately. Messages go out
-- through a small queue, a few at once and then one a second, so the game never drops them for coming too fast.

local _, ns = ...
if not (ns and ns.addTab) then return end

local ORANGE, GREY, GOLD, GREEN = ns.ORANGE, ns.GREY, ns.GOLD, ns.GREEN
local SHOWN = 5
local LIVE_FOR = 150          -- seconds a raid's count is believed without news (it repeats it every BEAT)
local BEAT = 60
local SCAN = 10               -- how often a tied raid's members are read, besides when the group changes
local SHARE_DAYS = 3          -- archived events whispered to someone logging in, if changed this recently
local KEEP_DAYS = 120         -- archived events forgotten after this
local MAX_TITLE = 48
local MAX_MESSAGE = 250       -- the game's limit is 255

local function store()
  local d = ns.db()
  d.events = type(d.events) == "table" and d.events or {}
  d.tied = type(d.tied) == "table" and d.tied or {}       -- character -> the event their raid is tied to
  return d
end
local function events() return store().events end
local function me() return UnitName("player") or "?" end
local function tiedId() return store().tied[me()] end
local function clean(s, n) return ns.trim((tostring(s or ""):gsub("[\t\r\n|]", " "))):sub(1, n) end      -- | starts the game's text codes

---------------------------------------------------------------------------------------------------------------------
-- Ranks, from the guild roster: the creator's rank comes from our own roster when we can see them, so it can't be faked.

local ranks, ranksAt = {}, -100
local function rankOf(name)
  if not name then return nil end
  if GetTime() - ranksAt > 30 then
    ranks, ranksAt = {}, GetTime()
    for i = 1, (GetNumGuildMembers() or 0) do
      local n, r = GetGuildRosterInfo(i)
      if n and r then
        ranks[ns.lower(n)] = r
        local s = ns.lower(ns.shortName(n))
        if ranks[s] == nil then ranks[s] = r end
      end
    end
  end
  return ranks[ns.lower(name)] or ranks[ns.lower(ns.shortName(name))]
end

---------------------------------------------------------------------------------------------------------------------
-- Sending: a few at once, then one a second. A newer count for a raid replaces one still waiting to go.

local queue, tokens, lastFill = {}, 5, 0
local pump = CreateFrame("Frame")
pump:Hide()
local function refill()
  local t = GetTime()
  tokens, lastFill = math.min(5, tokens + (t - lastFill)), t
end
pump:SetScript("OnUpdate", function(self)
  refill()
  while tokens >= 1 and queue[1] do
    tokens = tokens - 1
    local m = table.remove(queue, 1)
    ns.sendAddon(m[1], m[2], m[3])
  end
  if not queue[1] then self:Hide() end
end)

local function send(message, channel, target)
  if message:sub(1, 2) == "L\t" then
    local key = message:match("^(L\t[^\t]*\t[^\t]*\t)")
    for i, m in ipairs(queue) do
      if m[2] == channel and m[1]:sub(1, #key) == key then queue[i] = { message, channel, target } return end
    end
  end
  if not pump:IsShown() then refill() end
  queue[#queue + 1] = { message, channel, target }
  pump:Show()
end

local function eventLine(e)
  return table.concat({ "E", e.id, e.title, e.by, e.rank or "", e.created, e.status, e.changed, e.changedBy or "" }, "\t")
end

local function peopleLines(e, names)
  local out, cur, head = {}, {}, "P\t" .. e.id .. "\t"
  local len = #head
  for _, n in ipairs(names) do
    local item = n .. ((e.people[n] and e.people[n].assist) and "*" or "")
    if #cur > 0 and len + #item + 1 > MAX_MESSAGE then
      out[#out + 1] = head .. table.concat(cur, ",")
      cur, len = {}, #head
    end
    cur[#cur + 1] = item
    len = len + #item + 1
  end
  if #cur > 0 then out[#out + 1] = head .. table.concat(cur, ",") end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- The events and their lists. Merging is simple on purpose: the latest status change wins, and people only get added.

local function upsert(id, title, by, rank, created, status, changed, changedBy)
  created, changed = tonumber(created), tonumber(changed)
  if not (id and id ~= "" and created and changed) or (status ~= "open" and status ~= "archived") then return nil end
  title = clean(title, MAX_TITLE)
  if title == "" then return nil end
  local e = events()[id]
  if not e then
    e = { id = clean(id, 60), title = title, by = clean(by, 40), rank = clean(rank, 30), created = created, people = {},
          status = status, changed = changed, changedBy = clean(changedBy, 40) }
    events()[e.id] = e
    return e, true
  end
  if changed > (e.changed or 0) then
    e.status, e.changed, e.changedBy = status, changed, clean(changedBy, 40)
    return e, true
  end
  return e, false
end

-- Adds "Name" or "Name*" (had assist). Returns who was new, or newly had assist, to pass on.
local function addPeople(e, items, at)
  local fresh = {}
  for _, item in ipairs(items) do
    local name, star = tostring(item):match("^([^%*,%s|]+)(%*?)$")
    if name then
      local p = e.people[name]
      local new = not p
      if new then p = { at = at }; e.people[name] = p end
      if star == "*" and not p.assist then p.assist, new = true, true end
      if new then fresh[#fresh + 1] = name end
    end
  end
  return fresh
end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local function assists(e)
  local list = {}
  for name, p in pairs(e.people) do if p.assist then list[#list + 1] = name end end
  table.sort(list)
  return list
end

-- Live counts: event id -> raid leader -> { leader, count, at }. Keyed by the raid's leader, so two officers who
-- tied the same raid count it once.
local live = {}

local function setLive(id, leader, n)
  if not (id and leader) then return end
  live[id] = live[id] or {}
  if (tonumber(n) or 0) > 0 then live[id][leader] = { leader = leader, count = tonumber(n), at = GetTime() }
  else live[id][leader] = nil end
end

local function liveOf(e)
  local total, raids, t = 0, {}, GetTime()
  for leader, r in pairs(live[e.id] or {}) do
    if t - r.at <= LIVE_FOR then
      total = total + r.count
      raids[#raids + 1] = r
    else
      live[e.id][leader] = nil
    end
  end
  table.sort(raids, function(a, b) return a.count > b.count end)
  return total, raids
end

local function prune()
  for id, e in pairs(events()) do
    if type(e) ~= "table" or type(e.people) ~= "table" then events()[id] = nil
    elseif e.status == "archived" and ns.now() - (e.changed or 0) > KEEP_DAYS * 86400 then events()[id] = nil end
  end
  for who, id in pairs(store().tied) do
    if not events()[id] then store().tied[who] = nil end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Your tied raid: everyone in it goes on the event's list, and its size goes out to everyone else.

local draw
-- What the others were last told about our raid (its leader is the key they count it under), and when.
local sentCount, sentLeader, lastBeat, lastId = -1, nil, -100, nil

local function groupNow()          -- name -> had assist, and who leads
  local names, leader = {}, nil
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local name, rank = GetRaidRosterInfo(i)
      if name then
        names[name] = (rank or 0) >= 1
        if rank == 2 then leader = name end
      end
    end
  elseif IsInGroup() then
    local function add(unit)
      local n, realm = UnitName(unit)
      if not n then return end
      local full = (realm and realm ~= "") and (n .. "-" .. realm) or n
      names[full] = false
      if UnitIsGroupLeader(unit) then leader = full end
    end
    add("player")
    for i = 1, GetNumSubgroupMembers() do add("party" .. i) end
  end
  return names, leader
end

local function sendCount(id, leader, n)
  setLive(id, leader, n)
  send(table.concat({ "L", id, leader, n }, "\t"), "GUILD")
end

local function scan(force)
  local id = tiedId()
  local e = id and events()[id]
  if id and (not e or e.status ~= "open") then store().tied[me()], id, e = nil, nil, nil end
  if lastId ~= id then
    if lastId and sentLeader then sendCount(lastId, sentLeader, 0) end      -- closed, or tied to another event
    sentCount, sentLeader = -1, nil
  end
  lastId = id
  if not e then return end
  local names, leader = groupNow()
  local n = count(names)
  if n == 0 then           -- left the group: the raid is gone, but stays tied for the next one
    if sentLeader then sendCount(id, sentLeader, 0) end
    sentCount, sentLeader = 0, nil
    return
  end
  leader = leader or me()
  local items = {}
  for name, assist in pairs(names) do items[#items + 1] = name .. (assist and "*" or "") end
  local fresh = addPeople(e, items, ns.now())
  table.sort(fresh)
  for _, m in ipairs(peopleLines(e, fresh)) do send(m, "GUILD") end
  if sentLeader and sentLeader ~= leader then          -- the lead changed hands: the old key goes
    sendCount(id, sentLeader, 0)
    sentLeader = nil
  end
  setLive(id, leader, n)
  local t = GetTime()
  if force or t - lastBeat >= BEAT or ((n ~= sentCount or leader ~= sentLeader) and t - lastBeat >= 3) then
    sendCount(id, leader, n)          -- a change held back for coming too soon goes out on the next scan
    sentCount, sentLeader, lastBeat = n, leader, t
  end
  if #fresh > 0 and draw then draw() end
end

local function closeRaid()
  store().tied[me()] = nil
  scan()
end

local function openRaid(e)
  store().tied[me()] = e.id
  if IsInGroup() and not IsInRaid() and UnitIsGroupLeader("player") then
    local convert = (C_PartyInfo and C_PartyInfo.ConvertToRaid) or ConvertToRaid
    if convert then pcall(convert) end
  end
  scan(true)
  if IsInGroup() then
    ns.status:SetText(GREEN .. "Your raid is tied to " .. e.title .. ": everyone in it goes on the list.|r")
  else
    ns.status:SetText("Tied to " .. e.title .. ". Invite people: whoever joins your group goes on its list.")
  end
end

local function setStatus(e, status)
  e.status, e.changed, e.changedBy = status, math.max(ns.now(), (e.changed or 0) + 1), me()
  send(eventLine(e), "GUILD")
  if status ~= "open" and tiedId() == e.id then closeRaid() end
end

local function create(title)
  title = clean(title, MAX_TITLE)
  if title == "" then ns.status:SetText(ORANGE .. "Give the event a name first.|r") return nil end
  if not IsInGuild() then ns.status:SetText(ORANGE .. "You're not in a guild.|r") return nil end
  local t = ns.now()
  local _, rank = GetGuildInfo("player")
  local e = upsert(me() .. ":" .. t, title, me(), rank or rankOf(me()) or "", t, "open", t, me())
  if e then send(eventLine(e), "GUILD") end
  return e
end

local function exportText(e)
  local names = {}
  for name in pairs(e.people) do names[#names + 1] = name end
  table.sort(names)
  return "HAMR-EVENT " .. ns.now() .. " " .. ns.GAME .. " " .. me() .. " " .. e.title .. "\n" .. table.concat(names, "\n"), #names
end

---------------------------------------------------------------------------------------------------------------------
-- Messages from the other addons (HAMR.lua hands over everything but its own A and Q).

local function fromStranger(channel, sender)       -- a whisper from outside the guild is ignored, once we know the roster
  if channel ~= "WHISPER" then return false end
  local known = rankOf(sender)          -- reads the roster first, if it's been a while
  return not known and next(ranks) ~= nil
end

function ns.onEventMessage(p, channel, sender)
  if fromStranger(channel, sender) then return end
  local kind, changed = p[1], false
  if kind == "E" then
    local e, new = upsert(p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9])
    if e and new and tiedId() == e.id and e.status ~= "open" then scan() end
    changed = new
  elseif kind == "P" then
    local e = events()[p[2] or ""]
    if e then
      local items = {}
      for item in (p[3] or ""):gmatch("[^,]+") do items[#items + 1] = item end
      changed = #addPeople(e, items, ns.now()) > 0
    end
  elseif kind == "L" then
    if events()[p[2] or ""] and p[3] and p[3] ~= "" then setLive(p[2], clean(p[3], 40), tonumber(p[4]) or 0); changed = true end
  end
  if changed and draw then draw() end
end

function ns.onQuery(sender)        -- someone just logged in: tell them what's open, or changed in the last few days
  local list = {}
  for _, e in pairs(events()) do
    if e.status == "open" or ns.now() - (e.changed or 0) < SHARE_DAYS * 86400 then list[#list + 1] = e end
  end
  if #list == 0 then return end
  C_Timer.After(1 + math.random() * 5, function()        -- so the officers online don't all answer in the same instant
    for _, e in ipairs(list) do
      send(eventLine(e), "WHISPER", sender)
      local names = {}
      for name in pairs(e.people) do names[#names + 1] = name end
      table.sort(names)
      for _, m in ipairs(peopleLines(e, names)) do send(m, "WHISPER", sender) end
    end
    if tiedId() and sentLeader and sentCount > 0 then send(table.concat({ "L", tiedId(), sentLeader, sentCount }, "\t"), "WHISPER", sender) end
  end)
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("GROUP_ROSTER_UPDATE")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_ENTERING_WORLD" then prune() end
  scan()
end)
C_Timer.NewTicker(SCAN, function()
  scan()
  if draw then draw() end           -- counts from raids that went quiet fade away
end)

---------------------------------------------------------------------------------------------------------------------
-- The tab: create an event, pick one, open a raid for it. Built from plain frames like the rest of the window.

local panel = CreateFrame("Frame", nil, ns.frame)
panel:SetPoint("TOPLEFT", 24, -146)
panel:SetPoint("BOTTOMRIGHT", -24, 54)
panel:Hide()
table.insert(ns.panels, panel)

local nameBox = CreateFrame("EditBox", nil, panel)
nameBox:SetSize(250, 22)
nameBox:SetPoint("TOPLEFT", 0, 0)
nameBox:SetAutoFocus(false)
nameBox:SetMaxLetters(MAX_TITLE)
nameBox:SetFontObject(ChatFontNormal)
nameBox:SetTextInsets(6, 6, 0, 0)
local nameBack = nameBox:CreateTexture(nil, "BACKGROUND")
nameBack:SetAllPoints()
nameBack:SetColorTexture(0, 0, 0, 0.45)
local namePrompt = nameBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
namePrompt:SetPoint("LEFT", 7, 0)
namePrompt:SetText("New event's name, e.g. Help Wanted: RFD")
nameBox:SetScript("OnEditFocusGained", function() namePrompt:Hide() end)
nameBox:SetScript("OnEditFocusLost", function(self) if self:GetText() == "" then namePrompt:Show() end end)
nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local createButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
createButton:SetSize(80, 22)
createButton:SetPoint("LEFT", nameBox, "RIGHT", 6, 0)
createButton:SetText("Create")

local archived = CreateFrame("CheckButton", nil, panel)
archived:SetSize(22, 22)
archived:SetPoint("LEFT", createButton, "RIGHT", 10, 0)
archived:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
archived:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
archived:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
archived:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
local archivedLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
archivedLabel:SetPoint("LEFT", archived, "RIGHT", 2, 0)
archivedLabel:SetText("Archived")
local pager = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
pager:SetPoint("TOPRIGHT", 0, -5)

local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("TOPLEFT", 4, -44)
empty:SetPoint("RIGHT", -4, 0)
empty:SetJustifyH("LEFT")

local picks = {}
for i = 1, SHOWN do
  local b = CreateFrame("Button", nil, panel)
  b:SetSize(552, 48)
  b:SetPoint("TOPLEFT", 0, -32 - (i - 1) * 52)
  b.back = b:CreateTexture(nil, "BACKGROUND")
  b.back:SetAllPoints()
  local glow = b:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetColorTexture(1, 0.82, 0, 0.08)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 8, 0)
  b.text:SetPoint("RIGHT", -104, 0)
  b.text:SetJustifyH("LEFT")
  b.tie = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
  b.tie:SetSize(92, 22)
  b.tie:SetPoint("RIGHT", -6, 0)
  picks[i] = b
end

local selected, offset = nil, 0

local function shownList()
  local list, wantArchived = {}, archived:GetChecked() and true or false
  for _, e in pairs(events()) do
    if (e.status == "archived") == wantArchived then list[#list + 1] = e end
  end
  table.sort(list, function(a, b) return a.created > b.created end)
  return list
end

local function when(t)
  local days = math.floor((ns.now() - t) / 86400)
  return date(days < 6 and "%a %H:%M" or "%d %b %Y", t)
end

local function rowText(e)
  local rank = rankOf(e.by) or e.rank
  local seen, helpers = count(e.people), #assists(e)
  local lines = { GOLD .. e.title .. "|r" .. (tiedId() == e.id and (GREEN .. "   your raid|r") or "")
                  .. (e.status == "archived" and (GREY .. "   archived by " .. (e.changedBy or "?") .. "|r") or "") }
  lines[2] = GREY .. "by " .. e.by .. ((rank or "") ~= "" and (", " .. rank) or "") .. " · " .. when(e.created) .. " · " .. seen
             .. (seen == 1 and " person" or " people") .. (helpers > 0 and (", " .. helpers .. " with assist") or "") .. "|r"
  local total, raids = liveOf(e)
  if total > 0 then
    local parts = {}
    for _, r in ipairs(raids) do parts[#parts + 1] = r.leader .. " " .. r.count end
    lines[3] = GREEN .. total .. " in " .. (#raids == 1 and "1 raid" or (#raids .. " raids")) .. " now|r " .. GREY .. "(" .. table.concat(parts, ", ") .. ")|r"
  elseif e.status == "open" then
    lines[3] = GREY .. "No raid open for it right now.|r"
  end
  return table.concat(lines, "\n")
end

local showEvents

draw = function()
  if not panel:IsShown() then return end
  local list = shownList()
  offset = math.max(0, math.min(offset, #list - SHOWN))
  for i, b in ipairs(picks) do
    local e = list[i + offset]
    if e then
      b.text:SetText(rowText(e))
      b.back:SetColorTexture(1, 0.82, 0, e.id == selected and 0.16 or (i % 2 == 0 and 0.03 or 0.06))
      b:SetScript("OnClick", function() selected = e.id; draw() end)
      if e.status == "open" then
        local mine = tiedId() == e.id
        b.tie:SetText(mine and "Close raid" or "Open raid")
        b.tie:SetScript("OnClick", function()
          selected = e.id
          if mine then closeRaid(); ns.status:SetText("Your raid isn't tied to " .. e.title .. " any more. Its list stays.") else openRaid(e) end
          draw()
        end)
        b.tie:Show()
      else
        b.tie:Hide()
      end
      b:Show()
    else
      b:Hide()
    end
  end
  if #list == 0 then
    empty:SetText(archived:GetChecked() and "No archived events yet." or "No open events. Name one above and press Create: everyone in the guild with the addon sees it.")
    empty:Show()
  else
    empty:Hide()
  end
  pager:SetText(#list > SHOWN and ((offset + 1) .. "-" .. math.min(offset + SHOWN, #list) .. " of " .. #list .. ", scroll for more") or "")
  local e = selected and events()[selected]
  if e and ((e.status == "archived") == (archived:GetChecked() and true or false)) then
    ns.action:SetText("Copy for the site")
    ns.action:SetScript("OnClick", function()
      local text, n = exportText(e)
      local helpers = assists(e)
      ns.showText("events", "Press Ctrl+C to copy, then paste it into the event's \"Who was there\" on the site. " .. n .. (n == 1 and " name." or " names.")
                  .. (#helpers > 0 and ("\n" .. GREY .. "Had raid assist: " .. table.concat(helpers, ", ") .. "|r") or ""),
                  text, "Back", function() showEvents() end)
    end)
    ns.action:Show()
    ns.second:SetText(e.status == "open" and "Archive" or "Reopen")
    ns.second:SetScript("OnClick", function()
      setStatus(e, e.status == "open" and "archived" or "open")
      ns.status:SetText(e.title .. (e.status == "open" and " is open again." or " is archived: tick Archived to see it."))
      draw()
    end)
    ns.second:Show()
  else
    ns.action:Hide()
    ns.second:Hide()
  end
end

createButton:SetScript("OnClick", function()
  local e = create(nameBox:GetText())
  if not e then return end
  nameBox:SetText("")
  nameBox:ClearFocus()
  namePrompt:Show()
  archived:SetChecked(false)
  selected, offset = e.id, 0
  ns.status:SetText(e.title .. " is created and shared with the guild. Open raid ties your raid to it.")
  draw()
end)
nameBox:SetScript("OnEnterPressed", function() createButton:Click() end)
archived:SetScript("OnClick", function() offset = 0; draw() end)
panel:EnableMouseWheel(true)
panel:SetScript("OnMouseWheel", function(_, delta) offset = offset - delta; draw() end)

showEvents = function()
  ns.open("events", "Events shared with everyone in the guild who has the addon. Open raid ties your raid to one: everyone in it\n"
          .. "goes on its list and stays on it, even if they swap raids. " .. GREY .. "The Raid list tab still works on its own.|r")
  panel:Show()
  draw()
end
ns.addTab("events", "Events", function() showEvents() end)

-- For tests and other files.
ns.events = { create = create, openRaid = openRaid, closeRaid = closeRaid, setStatus = setStatus, scan = scan, liveOf = liveOf,
              exportText = exportText, all = events, upsert = upsert, addPeople = addPeople, send = send }
