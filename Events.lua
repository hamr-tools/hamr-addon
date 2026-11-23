-- HAMR events: a named event anyone in the guild can start (its creator's rank is shown with it), shared with every
-- guildie running the addon. Starting one tracks your group for it: everyone in it goes on the event's list and stays
-- on it (people swap raids to change layers, so the list only grows), with a mark for anyone who had raid assist.
--
-- An event has raids. Each group you track is one raid, remembered with everyone who was ever in it, so an officer who
-- builds several raids (one after another, to keep everyone on one layer) can disband one and rebuild it: Rebuild
-- invites its people back, Invite missing fills a raid that lost some. A group is recognised as one of the event's
-- raids when most of it was in that raid; otherwise it's the event's next raid. Each tracked raid tells the others how
-- many it has right now, so the event shows one live total. "Copy for the site" gives a list the event page's "Who was
-- there" box takes as it is; the Raid list tab stays for doing it by hand. Ended events stay here to look back on.
--
-- Shared over the guild's addon channel (prefix HAMR, see HAMR.lua), one message per line of tab-separated fields:
--   E  id  title  by  rank  created  status  changed  changedBy    an event, or its new status: the latest change wins
--   P  id  name,name*,...                                            people seen (* had raid assist): lists only grow
--   R  id  raid  name,name,...                                       who was in one of its raids ("Name:time"): grows
--   L  id  leader  count  raid                                       a tracked raid's size now (0: closed), every minute
--   F  id  officer  count  marker                                    an officer filling raids for it (-1: stopped)
--   W  id  name,name,...                                             taken off the waiting list (invited)
-- An addon that logs in asks with Q (HAMR.lua); the others whisper it what's open or changed lately. Messages go out
-- through a queue, a few at once and then one a second; one the game reports as throttled waits and goes again.
-- Invites go out one at a time, a little apart, and slow down if the game complains.

local _, ns = ...
if not (ns and ns.addTab) then return end

local ORANGE, GREY, GOLD, GREEN = ns.ORANGE, ns.GREY, ns.GOLD, ns.GREEN
local SHOWN = 3               -- events listed at once (scroll for more)
local RAIDS_SHOWN = 5         -- raids listed under the selected event
local LIVE_FOR = 150          -- seconds a raid's count is believed without news (it repeats it every BEAT)
local BEAT = 60
local SCAN = 10               -- how often a tracked raid's members are read, besides when the group changes
local SHARE_DAYS = 3          -- ended events whispered to someone logging in, if changed this recently
local KEEP_DAYS = 120         -- ended events forgotten after this
local MAX_TITLE = 48
local MAX_MESSAGE = 250       -- the game's limit is 255
local INVITE_GAP = 0.4        -- seconds between invites, doubled (up to 3) whenever the game complains
local RAID_MAX = 40

local function store()
  local d = ns.db()
  d.events = type(d.events) == "table" and d.events or {}
  d.tied = type(d.tied) == "table" and d.tied or {}       -- character -> the event their group is tracked for
  d.raid = type(d.raid) == "table" and d.raid or {}       -- character -> which of that event's raids their group is
  d.rfd = type(d.rfd) == "table" and d.rfd or {}          -- event -> true/false: raid building (invites) on your side
  return d
end
local function events() return store().events end
local function me() return UnitName("player") or "?" end
-- The keyword tick (RFD unless the options change it): this officer builds raids for this event (Rebuild, Invite
-- missing, invites for whispers of the keyword). Each officer ticks it for themselves; an event with the keyword in
-- its name starts ticked. The options' Raid invites switch turns it off everywhere.
local function keyword() return ns.keyword or "RFD" end
local function rfdOn(e)
  if ns.raidInvites == false then return false end
  local v = store().rfd[e.id]
  if v == nil then return (e.title or ""):upper():find(keyword():upper(), 1, true) ~= nil end
  return v
end
local function tiedId() return store().tied[me()] end
local function clean(s, n) return ns.trim((tostring(s or ""):gsub("[\t\r\n|]", " "))):sub(1, n) end      -- | starts the game's text codes
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

---------------------------------------------------------------------------------------------------------------------
-- Ranks and who's online, from the guild roster: the creator's rank comes from our own roster when we can see them, so
-- it can't be faked.

-- Forever's names have a surname: the roster and raid list say "Uthark Wintersworn", but the character's own name,
-- the one the game whispers from and invites by, is "Uthark". So people are matched by their first word (keeping a
-- realm: retail's "Name-Realm" has no space), stored with the fullest name seen, and invited by the first word.
local function firstWord(s) s = tostring(s or "") return s:match("^(%S+)") or s end
local function nameKey(n) return ns.lower(firstWord(n)) end
local function inviteName(n) return firstWord(n) end
local function isMe(n) return nameKey(n) == nameKey(me()) end

local ranks, online, byKey, rankIdx, ranksAt = {}, {}, {}, {}, -100
local function readRoster()
  if GetTime() - ranksAt <= 30 then return end
  ranks, online, byKey, rankIdx, ranksAt = {}, {}, {}, {}, GetTime()
  for i = 1, (GetNumGuildMembers() or 0) do
    local n, r, ri, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
    if n and r then
      local on = isOnline and true or false
      for _, k in ipairs({ ns.lower(n), ns.lower(ns.shortName(n)), nameKey(n), nameKey(ns.shortName(n)) }) do
        if ranks[k] == nil then ranks[k], online[k] = r, on end
      end
      rankIdx[ns.lower(ns.shortName(n))] = tonumber(ri)
      local k = nameKey(ns.shortName(n))
      byKey[k] = (byKey[k] == nil) and ns.shortName(n) or false      -- false: two members share that first name
    end
  end
end
local function rankOf(name)
  if not name then return nil end
  readRoster()
  return ranks[ns.lower(name)] or ranks[ns.lower(ns.shortName(name))] or ranks[nameKey(ns.shortName(name))]
end
local function isOffline(name)          -- only when the roster says so: someone outside the guild is worth a try
  readRoster()
  local v = online[ns.lower(name)]
  if v == nil then v = online[nameKey(name)] end
  return v == false
end
-- The rank's place in the guild (0: Guild Master), by full name, or by first name when only one member has it.
local function rankIndexOf(name)
  readRoster()
  local full = ns.lower(ns.shortName(name))
  if rankIdx[full] then return rankIdx[full] end
  local only = byKey[nameKey(full)]
  return only and rankIdx[ns.lower(only)] or nil
end
-- The guild roster's full name for "Uthark", when only one member is called that.
local function fullName(name)
  if tostring(name):find(" ", 1, true) then return name end
  readRoster()
  return byKey[nameKey(name)] or name
end

---------------------------------------------------------------------------------------------------------------------
-- Sending: a few at once, then one a second. A newer count for a raid replaces one still waiting to go. Retail tells
-- us when a message was throttled: it goes back in front, and the queue rests a couple of seconds.

local queue, tokens, lastFill = {}, 5, 0
local throttles = {}
if Enum and Enum.SendAddonMessageResult then
  for _, k in ipairs({ "AddonMessageThrottle", "ChannelThrottle" }) do
    if Enum.SendAddonMessageResult[k] then throttles[Enum.SendAddonMessageResult[k]] = true end
  end
end
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
    local _, result = ns.sendAddon(m[1], m[2], m[3])
    if throttles[result] then
      table.insert(queue, 1, m)
      tokens = -2            -- about three seconds before the next try
      break
    end
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

-- Splits a list of names over as many messages as it takes.
local function chunked(head, items)
  local out, cur, len = {}, {}, #head
  for _, item in ipairs(items) do
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

local function peopleLines(e, names)
  local items = {}
  for i, n in ipairs(names) do items[i] = n .. ((e.people[n] and e.people[n].assist) and "*" or "") end
  return chunked("P\t" .. e.id .. "\t", items)
end

local function raidLines(e, key, names)
  return chunked("R\t" .. e.id .. "\t" .. key .. "\t", names)
end

---------------------------------------------------------------------------------------------------------------------
-- Each event belongs to one guild: HAMRDB is shared by all the account's characters, and a character only sees and
-- shares its own guild's events. Events from before this have no guild yet: they go to the guild their creator is in,
-- as soon as a character in that guild sees the roster.

local function guildName()
  local g = GetGuildInfo and GetGuildInfo("player")
  return (g and g ~= "") and g or nil
end

local function belongs(e)
  local g = guildName()
  if not (g and e) then return false end
  if e.guild then return e.guild == g end
  if rankOf(e.by) then e.guild = g return true end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- The events, their lists and raids. Merging is simple on purpose: the latest status change wins, and people only
-- get added. A deleted event stays as a short record (no names), so another officer's copy can't bring it back.

local function upsert(id, title, by, rank, created, status, changed, changedBy)
  created, changed = tonumber(created), tonumber(changed)
  if not (id and id ~= "" and created and changed) or (status ~= "open" and status ~= "archived" and status ~= "deleted") then return nil end
  title = clean(title, MAX_TITLE)
  if title == "" then return nil end
  local e = events()[id]
  if not e then
    e = { id = clean(id, 60), title = title, by = clean(by, 40), rank = clean(rank, 30), created = created, people = {},
          raids = {}, status = status, changed = changed, changedBy = clean(changedBy, 40), guild = guildName() }
    events()[e.id] = e
    return e, true
  end
  if e.status == "deleted" then return e, false end          -- deleted stays deleted
  if changed > (e.changed or 0) then
    e.status, e.changed, e.changedBy = status, changed, clean(changedBy, 40)
    if status == "deleted" then e.people, e.raids = {}, {} end
    return e, true
  end
  return e, false
end

-- Adds "Name" or "Name*" (had assist). Returns who was new, or newly had assist, to pass on.
local function addPeople(e, items, at)
  local fresh = {}
  for _, item in ipairs(items) do
    local name, star = ns.trim(tostring(item)):match("^(.-)(%*?)$")
    name = ns.trim(name or "")
    if name ~= "" and not name:find("[,|\t\r\n]") then
      local p = e.people[name]
      local new = not p
      if new then p = { at = at }; e.people[name] = p end
      if star == "*" and not p.assist then p.assist, new = true, true end
      if new then fresh[#fresh + 1] = name end
    end
  end
  return fresh
end

-- A raid's key is "whoever started it:when", the same in every officer's copy.
local function raidOf(e, key)
  e.raids = type(e.raids) == "table" and e.raids or {}
  key = clean(key, 60)
  local r = e.raids[key]
  if r then return r end
  local by, at = key:match("^(.+):(%d+)$")
  if not by then return nil end
  r = { key = key, by = by, at = tonumber(at), people = {} }
  e.raids[key] = r
  return r
end

local function addToRaid(r, names)
  local fresh = {}
  for _, name in ipairs(names) do
    name = ns.trim((tostring(name):gsub("%*$", "")))
    if name ~= "" and not name:find("[,|\t\r\n]") and not r.people[name] then r.people[name] = true; fresh[#fresh + 1] = name end
  end
  return fresh
end

local function raidSize(r)
  local seen, n = {}, 0
  for name in pairs(r.people) do local k = nameKey(name) if not seen[k] then seen[k], n = true, n + 1 end end
  return n
end

-- The event's raids in the order they were started: Raid 1, Raid 2...
local function raidList(e)
  local list = {}
  for _, r in pairs(e.raids or {}) do list[#list + 1] = r end
  table.sort(list, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.key < b.key end)
  return list
end

local function assists(e)
  local list = {}
  for name, p in pairs(e.people) do if p.assist then list[#list + 1] = name end end
  table.sort(list)
  return list
end

-- Live counts: event id -> raid leader -> { leader, count, raid, at }. Keyed by the raid's leader, so two officers who
-- track the same raid count it once.
local live = {}

local function setLive(id, leader, n, raid)
  if not (id and leader) then return end
  live[id] = live[id] or {}
  if (tonumber(n) or 0) > 0 then live[id][leader] = { leader = leader, count = tonumber(n), raid = raid, at = GetTime() }
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
    elseif e.status ~= "open" and ns.now() - (e.changed or 0) > KEEP_DAYS * 86400 then events()[id] = nil
    elseif type(e.raids) ~= "table" then e.raids = {} end
  end
  for id in pairs(store().rfd) do if not events()[id] then store().rfd[id] = nil end end
  for who, id in pairs(store().tied) do
    if not events()[id] then store().tied[who], store().raid[who] = nil, nil end
  end
end

-- The waiting list: whoever asks while no filling raid has room is remembered for WAIT_FOR seconds, in the order they
-- asked, and invited as soon as you're the officer filling with room (a raid reformed, someone left, another officer
-- started filling). A whisper to you while your raid is full waits for yours (mine). Someone taken from the list goes
-- out as W, so the other officers' lists drop them; so does anyone seen joining one of the event's raids.
local WAIT_FOR = 600
local waiting = {}          -- { name, where, at, id, mine }, oldest first
local function unwait(name)
  for i = #waiting, 1, -1 do if nameKey(waiting[i].name) == nameKey(name) then table.remove(waiting, i) end end
end
local function addWaiting(e, name, where, mine, front)
  for _, w in ipairs(waiting) do if nameKey(w.name) == nameKey(name) then w.mine = w.mine or mine return end end
  table.insert(waiting, front and 1 or (#waiting + 1), { name = name, where = where, at = GetTime(), id = e.id, mine = mine })
end
local function waitingFor(e)
  local list, t = {}, GetTime()
  for i = #waiting, 1, -1 do if t - waiting[i].at > WAIT_FOR then table.remove(waiting, i) end end
  for _, w in ipairs(waiting) do if w.id == e.id then list[#list + 1] = w end end
  return list
end

---------------------------------------------------------------------------------------------------------------------
-- Your tracked group: everyone in it goes on the event's list and its raid's, and its size goes out to everyone else.

local draw, invites, deleteEvent
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

-- Which of the event's raids this group is: the one most of it was in (at least two others, and half of them).
local function matchRaid(e, names)
  local best, bestN, others = nil, 0, count(names) - 1
  for key, r in pairs(e.raids or {}) do
    local was, n = {}, 0
    for name in pairs(r.people) do was[nameKey(name)] = true end
    for name in pairs(names) do if not isMe(name) and was[nameKey(name)] then n = n + 1 end end
    if n > bestN then best, bestN = key, n end
  end
  if best and bestN >= 2 and bestN * 2 >= others then return best end
end

local function newRaid(e)
  local t, key = ns.now(), nil
  repeat key = me() .. ":" .. t; t = t + 1 until not (e.raids or {})[key]
  return raidOf(e, key).key
end

local function sendCount(id, leader, n, raid)
  setLive(id, leader, n, raid)
  send(table.concat({ "L", id, leader, n, raid or "" }, "\t"), "GUILD")
end

local function scan(force)
  local id = tiedId()
  local e = id and events()[id]
  if id and (not e or e.status ~= "open" or not belongs(e)) then store().tied[me()], store().raid[me()], id, e = nil, nil, nil, nil end
  if lastId ~= id then
    if lastId and sentLeader then sendCount(lastId, sentLeader, 0) end      -- closed, or tracking another event
    sentCount, sentLeader = -1, nil
  end
  lastId = id
  if not e then return end
  local names, leader = groupNow()
  local n = count(names)
  if n == 0 then           -- left the group: that raid is done, the next group is the event's next raid (or a rebuild)
    if sentLeader then sendCount(id, sentLeader, 0) end
    sentCount, sentLeader = 0, nil
    if not (invites.run and invites.run.e == e) then store().raid[me()] = nil end
    return
  end
  local key = store().raid[me()]
  if not (key and e.raids[key]) then
    key = matchRaid(e, names) or newRaid(e)
    store().raid[me()] = key
  end
  leader = leader or me()
  local items, plain = {}, {}
  for name, assist in pairs(names) do
    items[#items + 1] = name .. (assist and "*" or "")
    plain[#plain + 1] = name
  end
  local fresh = addPeople(e, items, ns.now())
  table.sort(fresh)
  for _, m in ipairs(peopleLines(e, fresh)) do send(m, "GUILD") end
  for _, name in ipairs(plain) do unwait(name) end
  local freshRaid = addToRaid(e.raids[key], plain)
  table.sort(freshRaid)
  for _, m in ipairs(raidLines(e, key, freshRaid)) do send(m, "GUILD") end
  if sentLeader and sentLeader ~= leader then          -- the lead changed hands: the old key goes
    sendCount(id, sentLeader, 0)
    sentLeader = nil
  end
  setLive(id, leader, n, key)
  local t = GetTime()
  if force or t - lastBeat >= BEAT or ((n ~= sentCount or leader ~= sentLeader) and t - lastBeat >= 3) then
    sendCount(id, leader, n, key)          -- a change held back for coming too soon goes out on the next scan
    sentCount, sentLeader, lastBeat = n, leader, t
  end
  if (#fresh > 0 or #freshRaid > 0) and draw then draw() end
end

local function convertToRaid()
  if ns.raidInvites == false then return end          -- another addon does the raid building
  if IsInGroup() and not IsInRaid() and UnitIsGroupLeader("player") then
    local convert = (C_PartyInfo and C_PartyInfo.ConvertToRaid) or ConvertToRaid
    if convert then pcall(convert) end
  end
end

-- Raid assist by guild rank: while you lead a raid you track for an event, guildies of the options' rank (Herald by
-- default) and above get raid assist as they join, one every half second. Nothing happens when this guild has no rank
-- by that name, and it stops for the session if the game blocks it.
local promoted, promoteBlocked, promoteSoon = {}, false, false
local function assistRank()
  local want = ns.lower(ns.trim(ns.assistRank or ""))
  if want == "" or not (GuildControlGetNumRanks and GuildControlGetRankName) then return nil end
  for i = 1, (GuildControlGetNumRanks() or 0) do
    if ns.lower(ns.trim(GuildControlGetRankName(i) or "")) == want then return i - 1 end
  end
end
local function promoteAssists()
  local promote = PromoteToAssistant
  if ns.autoAssist == false or promoteBlocked or not promote or promoteSoon then return end
  if not (IsInRaid() and UnitIsGroupLeader("player")) then return end
  local e = tiedId() and events()[tiedId()]
  if not (e and e.status == "open" and belongs(e)) then return end
  local top = assistRank()
  if not top then return end
  for i = 1, GetNumGroupMembers() do
    local name, rank = GetRaidRosterInfo(i)
    local k = name and nameKey(name)
    if name and (rank or 0) == 0 and not isMe(name) and GetTime() - (promoted[k] or -100) > 15 then
      local idx = rankIndexOf(name)
      if idx and idx <= top then
        promoted[k] = GetTime()
        pcall(promote, "raid" .. i)
        promoteSoon = true          -- the rest in a moment: one at a time
        C_Timer.After(0.5, function() promoteSoon = false; promoteAssists() end)
        return
      end
    end
  end
end

local function closeRaid()
  store().tied[me()], store().raid[me()] = nil, nil
  scan()
  if ns.announceFill then ns.announceFill(true) end
end

local function openRaid(e)
  if tiedId() ~= e.id then store().raid[me()] = nil end
  store().tied[me()] = e.id
  convertToRaid()
  scan(true)
  if ns.announceFill then ns.announceFill(true) end
  if IsInGroup() then
    ns.status:SetText(GREEN .. "Tracking your raid for " .. e.title .. ": everyone in it goes on the list.|r")
  else
    ns.status:SetText("Tracking for " .. e.title .. ". Invite people: whoever joins your group goes on its list.")
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
  local id = me() .. ":" .. t
  while events()[id] do t = t + 1; id = me() .. ":" .. t end         -- two made in the same second stay two
  local e = upsert(id, title, me(), rank or rankOf(me()) or "", t, "open", t, me())
  if e then send(eventLine(e), "GUILD") end
  return e
end

-- Everyone ever on the event, once each: its list and its raids' (raid lists from before 0.7.0's fix hold first names
-- only), with the fullest name known.
local function everyone(e)
  local best = {}
  local function take(name)
    local k, full = nameKey(name), fullName(name)
    if not best[k] or (#full > #best[k]) then best[k] = full end
  end
  for name in pairs(e.people) do take(name) end
  for _, r in pairs(e.raids or {}) do for name in pairs(r.people) do take(name) end end
  local names = {}
  for _, n in pairs(best) do names[#names + 1] = n end
  table.sort(names)
  return names
end

local function exportText(e)
  local names = everyone(e)
  -- when the event was made, not now: every officer's copy carries the same time, so the site's Import finds one event
  return "HAMR-EVENT " .. (e.created or ns.now()) .. " " .. ns.GAME .. " " .. me() .. " " .. e.title .. "\n" .. table.concat(names, "\n"), #names
end

---------------------------------------------------------------------------------------------------------------------
-- Invites: Rebuild (you're not in a group: invite everyone who was in that raid) and Invite missing (you're in it:
-- invite whoever left). One invite at a time, INVITE_GAP apart; a party is turned into a raid as soon as someone
-- accepts. Offline guildies are skipped. If the game blocks addons from inviting, each click invites one instead.
-- Answers come back as system messages ("X is already in a group"), counted for the summary.

-- Who asked, and what came of it, for the keyword's tab: newest first, the last 15.
local asks = {}
local function noteAsk(name, where, outcome)
  for i, a in ipairs(asks) do
    if nameKey(a.name) == nameKey(name) and GetTime() - a.at < 120 then
      table.remove(asks, i)
      break
    end
  end
  table.insert(asks, 1, { name = name, where = where, outcome = outcome, at = GetTime() })
  while #asks > 15 do table.remove(asks) end
end
local function answerAsk(name, outcome)
  for _, a in ipairs(asks) do
    if nameKey(a.name) == nameKey(name) then a.outcome = outcome return true end
  end
end

invites = { run = nil, byClick = false }
local inviteFrame = CreateFrame("Frame")
inviteFrame:Hide()

local function pattern(fmt)            -- "%s is already in a group." -> "^(.+) is already in a group%.$"
  if type(fmt) ~= "string" then return nil end
  local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
  return "^" .. p .. "$"
end
local ANSWERS = {}
for _, a in ipairs({ { "ERR_ALREADY_IN_GROUP_S", "busy" }, { "ERR_BAD_PLAYER_NAME_S", "missing" },
                     { "ERR_DECLINE_GROUP_S", "declined" }, { "ERR_JOINED_GROUP_S", "joined" },
                     { "ERR_RAID_MEMBER_ADDED_S", "joined" }, { "ERR_PLAYER_WRONG_FACTION", "missing" } }) do
  local p = pattern(_G[a[1]])
  if p then ANSWERS[#ANSWERS + 1] = { p, a[2] } end
end

local function inviteCall(name)
  local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
  if not invite then return false end
  return pcall(invite, name)
end

local function canInvite()
  if not IsInGroup() then return true end
  if UnitIsGroupLeader("player") then return true end
  return IsInRaid() and UnitIsGroupAssistant and UnitIsGroupAssistant("player") or false
end

local function summary(run)
  local c = run.counts
  local parts = { (c.sent or 0) .. " invited" }
  if (c.joined or 0) > 0 then parts[#parts + 1] = c.joined .. " joined" end
  if #run.busy > 0 then parts[#parts + 1] = #run.busy .. " already in a group (" .. table.concat(run.busy, ", ", 1, math.min(#run.busy, 6)) .. (#run.busy > 6 and "..." or "") .. ")" end
  if (c.declined or 0) > 0 then parts[#parts + 1] = c.declined .. " declined" end
  if (c.missing or 0) > 0 then parts[#parts + 1] = c.missing .. " not found" end
  if run.offline > 0 then parts[#parts + 1] = run.offline .. " offline, skipped" end
  return table.concat(parts, ", ")
end

local function stopInvites(why)
  local run = invites.run
  if not run then return end
  invites.run = nil
  inviteFrame:Hide()
  ns.status:SetText((why and (why .. " ") or "") .. summary(run) .. ".")
  if draw then draw() end
end

-- Who of raid r isn't in your group now, online as far as the roster knows.
local function missingFrom(r)
  local here, list, offline, seen = {}, {}, 0, {}
  for name in pairs(groupNow()) do here[nameKey(name)] = true end
  for name in pairs(r.people) do
    local k = nameKey(name)
    if not isMe(name) and not here[k] and not seen[k] then
      seen[k] = true
      if isOffline(name) then offline = offline + 1 else list[#list + 1] = fullName(name) end
    end
  end
  table.sort(list)
  return list, offline
end

-- Everyone on the event who isn't in your group now (online as far as the roster knows), for Invite all: people of
-- the latest raid first, then the one before, then the rest of the list.
local function missingFromAll(e)
  local here, list, offline, seen = {}, {}, 0, {}
  for name in pairs(groupNow()) do here[nameKey(name)] = true end
  local function take(names)
    table.sort(names)
    for _, name in ipairs(names) do
      local k = nameKey(name)
      if not isMe(name) and not here[k] and not seen[k] then
        seen[k] = true
        if isOffline(name) then offline = offline + 1 else list[#list + 1] = fullName(name) end
      end
    end
  end
  local raids = raidList(e)
  for i = #raids, 1, -1 do
    local names = {}
    for name in pairs(raids[i].people) do names[#names + 1] = name end
    take(names)
  end
  local rest = {}
  for name in pairs(e.people) do rest[#rest + 1] = name end
  take(rest)
  return list, offline
end

-- Sends the next invite. From a click (byClick) it's one per click; from the timer it waits as the group needs.
local function inviteNext(fromClick)
  local run = invites.run
  if not run then return end
  if not canInvite() then stopInvites(ORANGE .. "Only the raid leader or an assistant can invite.|r") return end
  if IsInGroup() and not IsInRaid() then
    if UnitIsGroupLeader("player") then convertToRaid() end
    run.wait = GetTime() + 1             -- the raid takes a moment to exist
    if not fromClick then return end
  end
  if not IsInGroup() and run.outstanding >= 4 then         -- a party holds five: wait for someone to accept
    if GetTime() - run.lastSent > 60 then stopInvites(ORANGE .. "Nobody has accepted yet.|r") end
    return
  end
  if IsInRaid() and GetNumGroupMembers() >= RAID_MAX then
    local back = 0
    for i = #run.names, 1, -1 do           -- those who asked go back on the waiting list, at the front
      local n = run.names[i]
      if run.fromAsk[n] then addWaiting(run.e, n, "waited", true, true); back = back + 1 end
    end
    if back > 0 then ns.say(back .. " who asked for " .. keyword() .. " didn't fit: they're back on the waiting list.") end
    stopInvites(ORANGE .. "The raid is full (" .. RAID_MAX .. ")" .. (#run.names > 0 and (": " .. #run.names .. " not invited, " .. table.concat(run.names, ", ", 1, math.min(#run.names, 6)) .. (#run.names > 6 and "..." or "")) or "") .. ".|r")
    return
  end
  local name
  repeat
    name = table.remove(run.names, 1)
  until not name or not (function() for n in pairs(groupNow()) do if nameKey(n) == nameKey(name) then return true end end end)()      -- joined meanwhile
  if not name then stopInvites(GREEN .. "Invites sent.|r") return end
  run.current, run.lastSent = name, GetTime()
  local ok = inviteCall(inviteName(name))
  if ok then
    run.counts.sent = (run.counts.sent or 0) + 1
    run.outstanding = run.outstanding + 1
  end
  ns.status:SetText("Inviting " .. name .. " (" .. #run.names .. " left)")
  if draw then draw() end
end

local function startInvites(e, r, names, offline)
  if invites.run then stopInvites() end
  if ns.raidInvites == false then ns.status:SetText("Raid invites are off in HAMR's options.") return end
  if not rfdOn(e) then ns.status:SetText("Tick " .. keyword() .. " on the event to invite for it.") return end
  if not canInvite() then ns.status:SetText(ORANGE .. "Only the leader or an assistant can invite.|r") return end
  store().tied[me()], store().raid[me()] = e.id, r.key       -- whoever joins counts in this raid
  invites.run = { e = e, raid = r, names = names, offline = offline, counts = {}, busy = {}, outstanding = 0,
                  lastSent = GetTime(), wait = 0, gap = INVITE_GAP, fromAsk = {} }
  scan(true)
  if invites.byClick then
    ns.status:SetText("The game wants a click for each invite: press Invite next.")
    if draw then draw() end
    return
  end
  inviteFrame:Show()
end

inviteFrame:SetScript("OnUpdate", function(self)
  local run = invites.run
  if not run or invites.byClick then self:Hide() return end
  local t = GetTime()
  if t < run.wait or t - run.lastSent < run.gap then return end
  inviteNext(false)
end)

local listen = CreateFrame("Frame")
listen:RegisterEvent("CHAT_MSG_SYSTEM")
listen:RegisterEvent("UI_ERROR_MESSAGE")
listen:RegisterEvent("ADDON_ACTION_BLOCKED")
listen:RegisterEvent("ADDON_ACTION_FORBIDDEN")
listen:SetScript("OnEvent", function(_, event, a, b)
  local run = invites.run
  if event == "CHAT_MSG_SYSTEM" then
    local text = tostring(a or "")
    for _, ans in ipairs(ANSWERS) do
      local who = text:match(ans[1])
      if who then
        local said = { joined = "joined", busy = "already in a group", declined = "declined", missing = "not found" }
        answerAsk(who, said[ans[2]])
        break
      end
    end
  end
  if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    if a == "HAMR" and tostring(b):lower():find("promote") and not promoteBlocked then
      promoteBlocked = true
      ns.say("The game doesn't let addons give raid assist here: HAMR stops trying until you /reload.")
    end
    if run and a == "HAMR" and tostring(b):lower():find("invite") then
      invites.byClick = true            -- from now on, one invite per click
      table.insert(run.names, 1, run.current)
      inviteFrame:Hide()
      ns.status:SetText(ORANGE .. "The game only lets addons invite on a click: press Invite next for each.|r")
      if draw then draw() end
    end
    return
  end
  if not run then return end
  if event == "UI_ERROR_MESSAGE" then
    -- Something the game refused while we invite (too fast, most likely): slow down, and try that name again once.
    if GetTime() - run.lastSent < 1.5 and run.current and not run.retried then
      run.retried = true
      table.insert(run.names, 1, run.current)
      run.counts.sent = math.max(0, (run.counts.sent or 1) - 1)
      run.gap = math.min(3, run.gap * 2)
      run.wait = GetTime() + 2
    end
    return
  end
  local text = tostring(a or "")
  for _, ans in ipairs(ANSWERS) do
    local who = text:match(ans[1])
    if who then
      if ans[2] == "busy" then run.busy[#run.busy + 1] = who else run.counts[ans[2]] = (run.counts[ans[2]] or 0) + 1 end
      run.outstanding = math.max(0, run.outstanding - 1)        -- answered, one way or another
      run.retried = nil
      return
    end
  end
end)

-- Gone for everyone: the others' copies get the deletion and drop the names. Kept as a short record for a while, so
-- an addon that had it doesn't share it again.
function deleteEvent(e)
  local wasTied = tiedId() == e.id
  if invites.run and invites.run.e == e then stopInvites() end
  e.status, e.changed, e.changedBy = "deleted", math.max(ns.now(), (e.changed or 0) + 1), me()
  e.people, e.raids = {}, {}
  store().rfd[e.id] = nil
  send(eventLine(e), "GUILD")
  if wasTied then closeRaid() end
  ns.status:SetText(e.title .. " is deleted, for everyone in the guild who has HAMR.")
  if draw then draw() end
end

-- Asking for an invite with the keyword: while you track an event that has it ticked, someone who whispers you just
-- the keyword, or says it in guild chat, is invited through the same paced queue. Case, spaces and punctuation don't
-- matter ("Rfd!"). Guild members only, unless the options allow whispers from outside (for testing). When the word is
-- heard but nobody is invited, the chat frame says why (whispers each time, guild chat at most once a minute).
-- Nothing is ever sent back: HAMR never messages anyone for you.
-- Filling raids one at a time. Every officer tracking an event with the keyword ticked tells the others how big their
-- group is, and the marker on its leader (F id officer count marker; -1 when they stop), every 30 s and on each change. An ask in guild chat goes to one
-- of them: the fullest raid that still has room (ties: the name first in the alphabet), so raids fill one after
-- another and the next officer takes over when one is full. A whisper is for the officer whispered.
local FILL_FRESH = 75
local fillers = {}                -- event id -> name key -> { name, count, icon, at }
local function setFiller(id, name, n, icon)
  if not (id and name) then return end
  fillers[id] = fillers[id] or {}
  icon = tonumber(icon)
  if (tonumber(n) or -1) < 0 then fillers[id][nameKey(name)] = nil
  else fillers[id][nameKey(name)] = { name = name, count = tonumber(n), icon = (icon and icon >= 1 and icon <= 8) and icon or nil, at = GetTime() } end
end
-- The marker (star, skull...) on your raid's leader: officers mark themselves so people can tell the raids apart.
local function leaderIcon()
  if not GetRaidTargetIndex then return 0 end
  local unit = "player"
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local _, rank = GetRaidRosterInfo(i)
      if rank == 2 then unit = "raid" .. i break end
    end
  end
  return GetRaidTargetIndex(unit) or 0
end
local function iconText(i) return i and ("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_" .. i .. ":14|t ") or "" end
local function fillersOf(e)
  local list, t = {}, GetTime()
  for k, f in pairs(fillers[e.id] or {}) do
    if t - f.at <= FILL_FRESH then list[#list + 1] = f else fillers[e.id][k] = nil end
  end
  table.sort(list, function(a, b) if a.count ~= b.count then return a.count > b.count end return ns.lower(a.name) < ns.lower(b.name) end)
  return list
end
local function onDuty(e)
  for _, f in ipairs(fillersOf(e)) do if f.count < RAID_MAX then return f end end
end
local function amFilling()
  local e = tiedId() and events()[tiedId()]
  if e and e.status == "open" and belongs(e) and rfdOn(e) then return e end
end
-- Invites someone who asked: into the invites already going out, or a new run into your raid.
local function inviteAsker(e, name)
  local run = invites.run
  if run and run.e == e then
    for _, n in ipairs(run.names) do if n == name then return end end
    table.insert(run.names, name)
    run.fromAsk[name] = true
    if not invites.byClick then inviteFrame:Show() end
    if draw then draw() end
    return
  end
  local key = store().raid[me()]
  local r = (key and e.raids[key]) or raidOf(e, newRaid(e))
  startInvites(e, r, { name }, 0)
  if invites.run then invites.run.fromAsk[name] = true end
end

-- Takes people off the waiting list while your raid has room: guild chat's when it's your turn, whispers to you always.
local lastDrain = -100
local function drainWaiting(e)
  if not (e and waiting[1]) or GetTime() - lastDrain < 1 or not canInvite() then return end
  local list = waitingFor(e)
  if #list == 0 then return end
  lastDrain = GetTime()
  local run = invites.run
  if run and run.e ~= e then return end
  local duty = onDuty(e)
  local myTurn = duty and isMe(duty.name)
  local room = RAID_MAX - math.max(1, IsInGroup() and GetNumGroupMembers() or 1) - (run and (#run.names + run.outstanding) or 0)
  local here, taken = {}, {}
  for n in pairs(groupNow()) do here[nameKey(n)] = true end
  for _, w in ipairs(list) do
    if here[nameKey(w.name)] then
      unwait(w.name)
    elseif room > 0 and (w.mine or myTurn) then
      unwait(w.name)
      room = room - 1
      taken[#taken + 1] = w.name
      noteAsk(w.name, w.where, "invited by you, after waiting " .. math.max(1, math.floor((GetTime() - w.at) / 60 + 0.5)) .. " min")
      inviteAsker(e, w.name)
    end
  end
  if #taken > 0 then
    for _, m in ipairs(chunked("W\t" .. e.id .. "\t", taken)) do send(m, "GUILD") end
    ns.say("Inviting " .. #taken .. " from the waiting list for " .. e.title .. ": " .. table.concat(taken, ", ", 1, math.min(#taken, 6)) .. (#taken > 6 and "..." or "") .. ".")
    if draw then draw() end
  end
end

local sentFill = { id = nil, n = -2, icon = 0, at = -100 }
local function announceFill(force)
  local e = amFilling()
  if sentFill.id and (not e or e.id ~= sentFill.id) then          -- stopped, or now filling another event
    send(table.concat({ "F", sentFill.id, me(), -1 }, "\t"), "GUILD")
    setFiller(sentFill.id, me(), -1)
    sentFill = { id = nil, n = -2, icon = 0, at = -100 }
  end
  if not e then return end
  local n = IsInGroup() and GetNumGroupMembers() or 0
  local icon = leaderIcon()
  setFiller(e.id, me(), n, icon)
  local t = GetTime()
  if force or t - sentFill.at >= 30 or ((n ~= sentFill.n or icon ~= sentFill.icon) and t - sentFill.at >= 3) then
    send(table.concat({ "F", e.id, me(), n, icon }, "\t"), "GUILD")
    sentFill = { id = e.id, n = n, icon = icon, at = t }
  end
  drainWaiting(e)
end
ns.announceFill = announceFill

local asked, lastWhy = {}, -100
local function heard(text, sender, where)
  if ns.whisperInvites == false or not sender or sender == "" then return end
  local said = ns.lower((tostring(text or ""):gsub("[^%w]", "")))
  if said ~= ns.lower(keyword()) then return end
  local inGuild = rankOf(sender) ~= nil
  local name = inGuild and fullName(ns.shortName(sender)) or sender
  local function why(reason)
    if where == "guild chat" then
      if GetTime() - lastWhy < 60 then return end
      lastWhy = GetTime()
    end
    ns.say(name .. " asked for an invite (" .. where .. "), but " .. reason .. ".")
  end
  local function skip(reason, outcome)     -- outcome: for the keyword's tab, when it isn't the reason itself
    noteAsk(name, where, outcome or reason)
    why(reason)
  end
  if isMe(ns.shortName(name)) then why("that's you") return end
  local e = tiedId() and events()[tiedId()]
  local tracking = e and e.status == "open" and belongs(e)
  if where == "guild chat" and not (tracking and rfdOn(e)) then
    -- Not filling: guild chat is none of our business. But an officer tracking the event keeps a quiet note of who
    -- asked while no raid had room, in case they start filling.
    if tracking and inGuild and ns.raidInvites ~= false and not isMe(ns.shortName(name)) and not onDuty(e) then addWaiting(e, name, where) end
    return
  end
  if not (e and e.status == "open" and belongs(e)) then why("you aren't tracking an event: Track my raid on one first") return end
  if not rfdOn(e) then why(keyword() .. " isn't ticked on " .. e.title) return end
  if not inGuild and not (where == "whisper" and ns.outsiders) then
    skip("they aren't in the guild" .. (where == "whisper" and " (the options can allow whispers from outside, for testing)" or ""), "not in the guild")
    return
  end
  for n in pairs(groupNow()) do if nameKey(n) == nameKey(name) then noteAsk(name, where, "already in your raid") return end end
  announceFill()
  if where == "guild chat" then              -- one officer takes it: the fullest raid with room
    local duty = onDuty(e)
    if duty and nameKey(duty.name) ~= nameKey(me()) then noteAsk(name, where, duty.name .. "'s turn") return end
  end
  if IsInRaid() and GetNumGroupMembers() >= RAID_MAX then          -- guild chat gets here only when every raid is full
    local duty = onDuty(e)
    addWaiting(e, name, where, where == "whisper")
    local n = #waitingFor(e)
    if where == "whisper" then
      skip("your raid is full: they wait for room in it (" .. n .. " waiting)" .. (duty and ("; " .. duty.name .. " has room") or ""), "waiting for room in your raid")
    else
      skip("every raid is full: they're on the waiting list (" .. n .. " waiting)", "waiting: every raid is full")
    end
    return
  end
  if asked[name] and GetTime() - asked[name] < 10 then return end      -- asking twice is one invite
  asked[name] = GetTime()
  unwait(name)
  noteAsk(name, where, "invited by you")
  local fresh = not (invites.run and invites.run.e == e)
  inviteAsker(e, name)
  if fresh then ns.say(name .. " asked for " .. keyword() .. " (" .. where .. "): inviting them for " .. e.title .. ".") end
end
local listenAsk = CreateFrame("Frame")
listenAsk:RegisterEvent("CHAT_MSG_WHISPER")
listenAsk:RegisterEvent("CHAT_MSG_GUILD")
listenAsk:SetScript("OnEvent", function(_, event, text, sender)
  if event == "CHAT_MSG_GUILD" then
    if ns.guildChatInvites ~= false then heard(text, sender, "guild chat") end
  else
    heard(text, sender, "whisper")
  end
end)

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
    local old = events()[p[2] or ""]
    if p[7] == "deleted" and old and ns.shortName(clean(p[9], 40)) ~= ns.shortName(old.by) then return end     -- only its creator deletes it
    local e, new = upsert(p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9])
    if e and new and tiedId() == e.id and e.status ~= "open" then scan() end
    changed = new
  elseif kind == "P" then
    local e = events()[p[2] or ""]
    if e and e.status ~= "deleted" then
      local items = {}
      for item in (p[3] or ""):gmatch("[^,]+") do items[#items + 1] = item end
      changed = #addPeople(e, items, ns.now()) > 0
    end
  elseif kind == "R" then
    local e = events()[p[2] or ""]
    local r = e and e.status ~= "deleted" and raidOf(e, p[3] or "")
    if r then
      local names = {}
      for item in (p[4] or ""):gmatch("[^,]+") do names[#names + 1] = item end
      local fresh = addToRaid(r, names)
      for _, n in ipairs(fresh) do unwait(n) end           -- in a raid now: nobody needs to invite them
      changed = #fresh > 0
    end
  elseif kind == "W" then                    -- another officer invited these from the waiting list
    for item in (p[3] or ""):gmatch("[^,]+") do unwait(ns.trim(item)) end
    changed = true
  elseif kind == "F" then
    if events()[p[2] or ""] and (p[3] or "") ~= "" then
      setFiller(p[2], clean(p[3], 40), tonumber(p[4]) or -1, p[5])
      changed = true
      local mine = amFilling()
      if mine and mine.id == p[2] then drainWaiting(mine) end        -- their raid filled up: our turn, maybe
    end
  elseif kind == "L" then
    if events()[p[2] or ""] and p[3] and p[3] ~= "" then
      setLive(p[2], clean(p[3], 40), tonumber(p[4]) or 0, (p[5] or "") ~= "" and clean(p[5], 60) or nil)
      changed = true
    end
  end
  if changed and draw then draw() end
end

function ns.onQuery(sender)        -- someone just logged in: tell them what's open, or changed in the last few days
  local list = {}
  for _, e in pairs(events()) do
    if belongs(e) and (e.status == "open" or ns.now() - (e.changed or 0) < SHARE_DAYS * 86400) then list[#list + 1] = e end
  end
  if #list == 0 then return end
  C_Timer.After(1 + math.random() * 5, function()        -- so the officers online don't all answer in the same instant
    for _, e in ipairs(list) do
      send(eventLine(e), "WHISPER", sender)
      local names = {}
      for name in pairs(e.people) do names[#names + 1] = name end
      table.sort(names)
      for _, m in ipairs(peopleLines(e, names)) do send(m, "WHISPER", sender) end
      for _, r in ipairs(raidList(e)) do
        local rn = {}
        for name in pairs(r.people) do rn[#rn + 1] = name end
        table.sort(rn)
        for _, m in ipairs(raidLines(e, r.key, rn)) do send(m, "WHISPER", sender) end
      end
    end
    if tiedId() and sentLeader and sentCount > 0 then
      send(table.concat({ "L", tiedId(), sentLeader, sentCount, store().raid[me()] or "" }, "\t"), "WHISPER", sender)
    end
  end)
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("GROUP_ROSTER_UPDATE")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("RAID_TARGET_UPDATE")          -- the raid leader's marker, for the keyword's tab
watcher:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_ENTERING_WORLD" then prune() end
  scan()
  if event ~= "RAID_TARGET_UPDATE" then promoteAssists() end
  announceFill()
end)
C_Timer.NewTicker(SCAN, function()
  scan()
  promoteAssists()
  announceFill()
  if draw then draw() end           -- counts from raids that went quiet fade away
end)

---------------------------------------------------------------------------------------------------------------------
-- The tab: start an event, pick one, and its raids underneath. Built from plain frames like the rest of the window.

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
namePrompt:SetText("New event's name, e.g. CTA Nov 22")
nameBox:SetScript("OnEditFocusGained", function() namePrompt:Hide() end)
nameBox:SetScript("OnEditFocusLost", function(self) if self:GetText() == "" then namePrompt:Show() end end)
nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local startButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
startButton:SetSize(80, 22)
startButton:SetPoint("LEFT", nameBox, "RIGHT", 6, 0)
startButton:SetText("Create")

local past = CreateFrame("CheckButton", nil, panel)
past:SetSize(22, 22)
past:SetPoint("LEFT", startButton, "RIGHT", 10, 0)
past:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
past:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
past:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
past:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
local pastLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
pastLabel:SetPoint("LEFT", past, "RIGHT", 2, 0)
pastLabel:SetText("Ended events")
local pager = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
pager:SetPoint("TOPRIGHT", 0, -5)

local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("TOPLEFT", 4, -40)
empty:SetPoint("RIGHT", -4, 0)
empty:SetJustifyH("LEFT")

local function lineButton(parent, y, height)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(552, height)
  b:SetPoint("TOPLEFT", 0, y)
  b.back = b:CreateTexture(nil, "BACKGROUND")
  b.back:SetAllPoints()
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 8, 0)
  b.text:SetPoint("RIGHT", -128, 0)
  b.text:SetJustifyH("LEFT")
  b.go = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
  b.go:SetSize(120, 22)
  b.go:SetPoint("RIGHT", -4, 0)
  return b
end

local picks = {}
for i = 1, SHOWN do
  local b = lineButton(panel, -30 - (i - 1) * 38, 36)
  local glow = b:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetColorTexture(1, 0.82, 0, 0.08)
  b.text:SetPoint("RIGHT", -184, 0)
  b.rfd = CreateFrame("CheckButton", nil, b)
  b.rfd:SetSize(20, 20)
  b.rfd:SetPoint("RIGHT", b.go, "LEFT", -34, 0)
  b.rfd:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
  b.rfd:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
  b.rfd:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
  b.rfd:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
  b.rfdLabel = b.rfd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.rfdLabel:SetPoint("LEFT", b.rfd, "RIGHT", 1, 0)
  b.rfd:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(keyword() .. ": build raids for this event")
    GameTooltip:AddLine("Rebuild and Invite missing under it" .. (ns.whisperInvites ~= false and (", and guildies who whisper you \"" .. keyword() .. "\" are invited while you track it") or "")
                        .. ". Just for you: each officer ticks it for themselves.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  b.rfd:SetScript("OnLeave", function() GameTooltip:Hide() end)
  picks[i] = b
end

local raidHead = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
raidHead:SetPoint("TOPLEFT", 4, -150)
raidHead:SetPoint("RIGHT", -326, 0)
raidHead:SetWordWrap(false)
local whoButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
whoButton:SetSize(100, 20)
whoButton:SetPoint("TOPRIGHT", -4, -146)
whoButton:SetText("Who's on it")
local allButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
allButton:SetSize(130, 20)
allButton:SetPoint("RIGHT", whoButton, "LEFT", -6, 0)
allButton:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Invite all")
  GameTooltip:AddLine("Invites everyone on the event who isn't in your group, the latest raid's people first, "
                      .. "until the raid is full. Offline guildies are skipped; whoever is in another raid says so.", 1, 1, 1, true)
  GameTooltip:Show()
end)
allButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
local deleteButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
deleteButton:SetSize(80, 20)
deleteButton:SetPoint("RIGHT", allButton, "LEFT", -6, 0)
deleteButton:SetText("Delete")
raidHead:SetJustifyH("LEFT")
local raidRows = {}
for i = 1, RAIDS_SHOWN do raidRows[i] = lineButton(panel, -166 - (i - 1) * 26, 24) end

local selected, offset = nil, 0

local function shownList()
  local list, wantPast = {}, past:GetChecked() and true or false
  for _, e in pairs(events()) do
    if e.status ~= "deleted" and belongs(e) and (e.status == "archived") == wantPast then list[#list + 1] = e end
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
  local seen, helpers = #everyone(e), #assists(e)
  local total, raids = liveOf(e)
  local line1 = GOLD .. e.title .. "|r"
  if total > 0 then line1 = line1 .. GREEN .. "   " .. total .. " in " .. (#raids == 1 and "1 raid" or (#raids .. " raids")) .. " now|r" end
  if tiedId() == e.id then line1 = line1 .. GREEN .. "   · yours|r" end
  if e.status == "archived" then line1 = line1 .. GREY .. "   ended by " .. (e.changedBy or "?") .. "|r" end
  return line1 .. "\n" .. GREY .. "by " .. e.by .. ((rank or "") ~= "" and (", " .. rank) or "") .. " · " .. when(e.created) .. " · "
         .. seen .. (seen == 1 and " person" or " people") .. (helpers > 0 and (", " .. helpers .. " with assist") or "") .. "|r"
end

local showEvents

-- Everyone on an event, raid by raid (* had assist; green: in your group now), for anyone in the guild to look at.
local function whoText(e)
  local here, lines, placed = {}, {}, {}
  for n in pairs(groupNow()) do here[nameKey(n)] = true end
  local assist = {}
  for name, p in pairs(e.people) do if p.assist then assist[nameKey(name)] = true end end
  local function show(name) return assist[nameKey(name)] and (name .. "*") or name end
  for i, r in ipairs(raidList(e)) do
    local names, inRaid = {}, {}
    for name in pairs(r.people) do
      local k = nameKey(name)
      if not inRaid[k] then inRaid[k] = true; names[#names + 1] = fullName(name); placed[k] = true end
    end
    table.sort(names)
    local now = 0
    for k, name in ipairs(names) do if here[nameKey(name)] then now = now + 1 end; names[k] = show(name) end
    lines[#lines + 1] = "Raid " .. i .. ", started by " .. r.by .. " (" .. #names .. " were in it" .. (now > 0 and (", " .. now .. " in your group now") or "") .. "):"
    lines[#lines + 1] = table.concat(names, ", ")
    lines[#lines + 1] = ""
  end
  local rest = {}
  for name in pairs(e.people) do if not placed[nameKey(name)] then placed[nameKey(name)] = true; rest[#rest + 1] = show(fullName(name)) end end
  table.sort(rest)
  if #rest > 0 then
    lines[#lines + 1] = (#lines > 0 and "Not in a raid HAMR saw" or "Everyone") .. " (" .. #rest .. "):"
    lines[#lines + 1] = table.concat(rest, ", ")
  end
  return table.concat(lines, "\n")
end

local deleteFor, deleteUntil = nil, 0
local function drawRaids(e)
  for _, b in ipairs(raidRows) do b:Hide() end
  if not e then raidHead:SetText(""); whoButton:Hide(); deleteButton:Hide(); allButton:Hide() return end
  -- Delete: the creator's own events only, and a second click within 5 seconds to be sure.
  if ns.shortName(e.by) == me() then
    local armed = deleteFor == e.id and GetTime() < deleteUntil
    deleteButton:SetText(armed and "Sure? Delete" or "Delete")
    deleteButton:SetScript("OnClick", function()
      if deleteFor == e.id and GetTime() < deleteUntil then
        deleteFor = nil
        deleteEvent(e)
      else
        deleteFor, deleteUntil = e.id, GetTime() + 5
        ns.status:SetText(ORANGE .. "Click again within 5 seconds to delete " .. e.title .. " for everyone in the guild who has HAMR.|r")
        draw()
      end
    end)
    deleteButton:Show()
  else
    deleteButton:Hide()
  end
  whoButton:SetScript("OnClick", function()
    local n = #everyone(e)
    ns.showText("events", GOLD .. e.title .. "|r: " .. n .. (n == 1 and " person" or " people") .. ", raid by raid. * had raid assist.",
                whoText(e), "Back", function() showEvents() end)
  end)
  if #everyone(e) > 0 then whoButton:Show() else whoButton:Hide() end
  -- Invite all: into your raid (or a new one when you're not in a group), for reforming on another layer.
  local run = invites.run
  allButton:Enable()
  if e.status ~= "open" or not rfdOn(e) or #everyone(e) == 0 then
    allButton:Hide()
  elseif run and run.all and run.e == e then
    allButton:SetText((invites.byClick and run.names[1]) and "Invite next" or "Stop")
    allButton:SetScript("OnClick", function()
      if invites.byClick and run.names[1] then inviteNext(true) else stopInvites("Stopped.") end
    end)
    allButton:Show()
  else
    local names = missingFromAll(e)
    allButton:SetText("Invite all (" .. #names .. ")")
    allButton:SetScript("OnClick", function()
      local fresh, off = missingFromAll(e)
      local key = IsInGroup() and tiedId() == e.id and store().raid[me()]
      local r = (key and e.raids[key]) or raidOf(e, newRaid(e))
      startInvites(e, r, fresh, off)
      if invites.run then invites.run.all = true end
      draw()
    end)
    if #names == 0 then allButton:Disable() end
    allButton:Show()
  end
  local list = raidList(e)
  if #list == 0 then
    raidHead:SetText(e.status == "open" and (GREY .. "No raids yet: Track my raid.|r") or "")
    return
  end
  local _, liveRaids = liveOf(e)
  local nowIn = {}
  for _, l in ipairs(liveRaids) do if l.raid then nowIn[l.raid] = (nowIn[l.raid] or 0) + l.count end end
  local mine = tiedId() == e.id and store().raid[me()] or nil
  local inGroup = IsInGroup()
  local first = math.max(1, #list - RAIDS_SHOWN + 1)          -- the latest raids, if there are more than fit
  raidHead:SetText("Raids" .. GREY .. (first > 1 and ("  (last " .. RAIDS_SHOWN .. " of " .. #list .. ")") or "")
                   .. ((e.status == "open" and ns.raidInvites ~= false and not rfdOn(e)) and ("  Tick " .. keyword() .. " to invite") or "") .. "|r")
  for i = first, #list do
    local r, b = list[i], raidRows[i - first + 1]
    local here = mine == r.key
    b.text:SetText((here and GREEN or GOLD) .. "Raid " .. i .. "|r" .. GREY .. "  started by " .. r.by .. " · " .. raidSize(r) .. " were in it"
                   .. (nowIn[r.key] and (" · " .. nowIn[r.key] .. " now") or "") .. (here and " · you're in it" or "") .. "|r")
    b.back:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0.06)
    b.go:Enable()
    if e.status ~= "open" or not rfdOn(e) then
      b.go:Hide()
    elseif run and run.raid == r then
      if invites.byClick and run.names[1] then
        b.go:SetText("Invite next")
        b.go:SetScript("OnClick", function() inviteNext(true) end)
      else
        b.go:SetText("Stop")
        b.go:SetScript("OnClick", function() stopInvites("Stopped.") end)
      end
      b.go:Show()
    elseif (here and inGroup) or not inGroup then
      local names, offline = missingFrom(r)
      b.go:SetText(inGroup and ("Invite " .. #names .. " missing") or ("Rebuild (" .. #names .. ")"))
      b.go:SetScript("OnClick", function()
        local fresh, off = missingFrom(r)
        startInvites(e, r, fresh, off)
        draw()
      end)
      if #names == 0 then b.go:Disable() end
      b.go:Show()
    else
      b.go:Hide()          -- you're in another group: leave it first, or have someone in this raid invite
    end
    b:Show()
  end
end

draw = function()
  if not panel:IsVisible() then return end         -- not while the window is closed
  local list = shownList()
  offset = math.max(0, math.min(offset, #list - SHOWN))
  if not (selected and events()[selected]) and list[1] then selected = list[1].id end
  for i, b in ipairs(picks) do
    local e = list[i + offset]
    if e then
      b.text:SetText(rowText(e))
      b.back:SetColorTexture(1, 0.82, 0, e.id == selected and 0.16 or (i % 2 == 0 and 0.03 or 0.06))
      b:SetScript("OnClick", function() selected = e.id; draw() end)
      b.rfd:SetChecked(rfdOn(e))
      b.rfdLabel:SetText(keyword())
      b.rfd:SetScript("OnClick", function(self)
        store().rfd[e.id] = self:GetChecked() and true or false
        announceFill(true)
        if not store().rfd[e.id] and invites.run and invites.run.e == e then stopInvites("RFD is off for " .. e.title .. ".") end
        selected = e.id
        draw()
      end)
      if e.status == "open" and ns.raidInvites ~= false then b.rfd:Show() else b.rfd:Hide() end
      if e.status == "open" then
        local mine = tiedId() == e.id
        b.go:SetText(mine and "Stop tracking" or "Track my raid")
        b.go:SetScript("OnClick", function()
          selected = e.id
          if mine then closeRaid(); ns.status:SetText("Your raid isn't tracked for " .. e.title .. " any more. Its list stays.") else openRaid(e) end
          draw()
        end)
        b.go:Show()
      else
        b.go:Hide()
      end
      b:Show()
    else
      b:Hide()
    end
  end
  if #list == 0 then
    empty:SetText(past:GetChecked() and "No ended events yet." or "No events going. Name one above and press Create: it's shared with the guild. Then Track my raid.")
    empty:Show()
  else
    empty:Hide()
  end
  pager:SetText(#list > SHOWN and ((offset + 1) .. "-" .. math.min(offset + SHOWN, #list) .. " of " .. #list .. ", scroll for more") or "")
  local e = selected and events()[selected]
  if e and (e.status == "deleted" or not belongs(e) or (e.status == "archived") ~= (past:GetChecked() and true or false)) then e = nil end
  drawRaids(e)
  if e then
    ns.action:SetText("Copy for the site")
    ns.action:SetScript("OnClick", function()
      local text, n = exportText(e)
      local helpers = #assists(e)
      ns.showText("events", "Press Ctrl+C to copy, then paste it into the event's \"Who was there\" on the site. " .. n .. (n == 1 and " name." or " names.")
                  .. (helpers > 0 and (GREY .. " " .. helpers .. " had raid assist: Who's on it marks them with *.|r") or ""),
                  text, "Back", function() showEvents() end)
    end)
    ns.action:Show()
    ns.second:SetText(e.status == "open" and "End event" or "Reopen")
    ns.second:SetScript("OnClick", function()
      setStatus(e, e.status == "open" and "archived" or "open")
      ns.status:SetText(e.title .. (e.status == "open" and " is going again." or " has ended: tick Ended events to see it."))
      draw()
    end)
    ns.second:Show()
  else
    ns.action:Hide()
    ns.second:Hide()
  end
end

startButton:SetScript("OnClick", function()
  local e = create(nameBox:GetText())
  if not e then return end
  nameBox:SetText("")
  nameBox:ClearFocus()
  namePrompt:Show()
  past:SetChecked(false)
  selected, offset = e.id, 0
  ns.status:SetText(GREEN .. e.title .. " is created and shared with the guild.|r Track my raid puts your group on its list.")
  draw()
end)
nameBox:SetScript("OnEnterPressed", function() startButton:Click() end)
past:SetScript("OnClick", function() offset, selected = 0, nil; draw() end)
panel:EnableMouseWheel(true)
panel:SetScript("OnMouseWheel", function(_, delta) offset = offset - delta; draw() end)

showEvents = function()
  ns.open("events", "Events shared with the guild's HAMR users. Create one, then Track my raid: everyone in your group goes on its "
          .. "list and stays on it. " .. GREY .. keyword() .. " ticked: Rebuild brings a raid back, Invite all reforms from everyone on it.|r")
  panel:Show()
  draw()
end
ns.addTab("events", "Events", function() showEvents() end)

---------------------------------------------------------------------------------------------------------------------
-- The keyword's tab (named after it): the event you fill for, who else fills, how full each raid is, whose turn it
-- is, and what came of everyone who asked.

local fill = CreateFrame("Frame", nil, ns.frame)
fill:SetPoint("TOPLEFT", 24, -146)
fill:SetPoint("BOTTOMRIGHT", -24, 54)
fill:Hide()
table.insert(ns.panels, fill)
local fillHead = fill:CreateFontString(nil, "OVERLAY", "GameFontNormal")
fillHead:SetPoint("TOPLEFT", 0, 0)
fillHead:SetPoint("RIGHT", -150, 0)
fillHead:SetJustifyH("LEFT")
local fillTick = CreateFrame("CheckButton", nil, fill)
fillTick:SetSize(22, 22)
fillTick:SetPoint("TOPRIGHT", -110, 3)
fillTick:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
fillTick:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
fillTick:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
fillTick:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
local fillTickLabel = fill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
fillTickLabel:SetPoint("LEFT", fillTick, "RIGHT", 2, 0)
local fillWho = fill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
fillWho:SetPoint("TOPLEFT", 0, -30)
fillWho:SetWidth(552)
fillWho:SetJustifyH("LEFT")
fillWho:SetJustifyV("TOP")
local askHead = fill:CreateFontString(nil, "OVERLAY", "GameFontNormal")
askHead:SetPoint("TOPLEFT", 0, -122)
askHead:SetText("Who asked")
local askText = fill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
askText:SetPoint("TOPLEFT", 0, -140)
askText:SetWidth(552)
askText:SetJustifyH("LEFT")
askText:SetJustifyV("TOP")

local function drawFill()
  if not fill:IsVisible() then return end
  local e = tiedId() and events()[tiedId()]
  if not (e and e.status == "open" and belongs(e)) then e = nil end
  fillTickLabel:SetText("Fill raids for it")
  if not e then
    fillHead:SetText(GREY .. "You aren't tracking an event. On Events, Track my raid on one, then come back.|r")
    fillTick:Hide(); fillTickLabel:Hide()
  else
    local total, raids = liveOf(e)
    fillHead:SetText(GOLD .. e.title .. "|r" .. (total > 0 and (GREEN .. "   " .. total .. " in " .. #raids .. (#raids == 1 and " raid" or " raids") .. " now|r") or ""))
    fillTick:SetChecked(rfdOn(e))
    fillTick:SetScript("OnClick", function(self)
      store().rfd[e.id] = self:GetChecked() and true or false
      announceFill(true)
      drawFill()
      if draw then draw() end
    end)
    fillTick:Show(); fillTickLabel:Show()
  end
  local lines = {}
  if e then
    local duty = onDuty(e)
    for _, f in ipairs(fillersOf(e)) do
      local turn = duty == f
      lines[#lines + 1] = iconText(f.icon) .. (turn and GREEN or (f.count >= RAID_MAX and GREY or "|cffffffff")) .. f.name .. "|r" .. GREY .. "   " .. f.count .. " / " .. RAID_MAX
                          .. (f.count >= RAID_MAX and "   full" or "") .. "|r" .. (turn and (GREEN .. "   filling now: guild chat asks go here|r") or "")
                          .. (isMe(f.name) and (GREY .. "   (you)|r") or "")
    end
    if #lines == 0 then lines[1] = GREY .. "Nobody is filling for it. Tick \"Fill raids for it\" to start: your raid takes the asks.|r" end
    local wait = waitingFor(e)
    if #wait > 0 then
      local names = {}
      for i, w in ipairs(wait) do if i > 8 then break end names[i] = w.name end
      lines[#lines + 1] = ORANGE .. "Waiting for room: " .. #wait .. "|r" .. GREY .. "   " .. table.concat(names, ", ") .. (#wait > 8 and "..." or "")
                          .. "  (invited in order as a raid has room)|r"
    end
  end
  fillWho:SetText(table.concat(lines, "\n"))
  local out = {}
  for i, a in ipairs(asks) do
    if i > 9 then break end
    local mins = math.floor((GetTime() - a.at) / 60)
    local good = a.outcome == "joined" or a.outcome == "invited by you"
    out[#out + 1] = (good and GREEN or GREY) .. a.name .. "|r" .. GREY .. "  (" .. a.where .. ", " .. (mins < 1 and "just now" or (mins .. " min ago")) .. "): |r" .. a.outcome
  end
  askText:SetText(#out > 0 and table.concat(out, "\n") or (GREY .. "Nobody yet. A guildie whispers you, or says in guild chat, just \"" .. keyword() .. "\".|r"))
end

local function showFill()
  ns.open("rfd", "Officers fill raids one at a time: whoever says \"" .. keyword() .. "\" in guild chat goes to the fullest raid that has room, and the next "
          .. "officer takes over when it's full. A whisper is for the officer whispered.")
  fill:Show()
  drawFill()
end
local fillTab = ns.addTab("rfd", "RFD", function() showFill() end)
local redrawFill = draw
draw = function() redrawFill(); drawFill() end

function ns.onOptions()
  fillTab.label:SetText(keyword())
  ns.hiddenTabs.rfd = ns.raidInvites == false
  if ns.layoutTabs then ns.layoutTabs() end
  if draw then draw() end
end

-- For tests and other files.
ns.events = { create = create, openRaid = openRaid, closeRaid = closeRaid, setStatus = setStatus, scan = scan, liveOf = liveOf,
              exportText = exportText, all = events, upsert = upsert, addPeople = addPeople, send = send, raidList = raidList,
              missingFrom = missingFrom, startInvites = startInvites, inviteNext = inviteNext, invites = invites,
              stopInvites = stopInvites, whoText = whoText, deleteEvent = function(e) deleteEvent(e) end, belongs = belongs,
              shownList = function() return shownList() end }
