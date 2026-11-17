-- DungeonWinner: shows everyone's Need/Greed/Pass choices and roll numbers in one list.
-- Data comes from two places:
--   START_LOOT_ROLL  -> a new item is up for rolls (we pre-fill the group as "pending")
--   CHAT_MSG_LOOT    -> "X has selected Need for: [item]", "Need Roll - 87 for [item] by X", "X won: [item]"
-- Chat lines are matched with patterns built from Blizzard's own global strings,
-- so the addon works in any game language.

local ADDON_NAME = ...
local MAX_HISTORY = 300
local playerName = UnitName("player")
local debugMode = false

-- Developer options (/dw debug) only unlock for this BattleTag.
-- Note: this hides the tools from normal players; it isn't real security,
-- since anyone can edit an addon's Lua on their own computer.
local DEVELOPER_BTAG = "Cololol#1243"

local function IsDeveloper()
    if not BNGetInfo then return false end
    local _, battleTag = BNGetInfo()
    if battleTag == nil or (issecretvalue and issecretvalue(battleTag)) then return false end
    return battleTag == DEVELOPER_BTAG
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Print(...)
    print("|cff33ff99DungeonWinner:|r", ...)
end

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

local GetIconByID = (C_Item and C_Item.GetItemIconByID) or GetItemIcon

local function ItemID(link)
    return link and tonumber(link:match("item:(%d+)"))
end

-- Strip player hyperlinks / color codes and drop the realm from a name
local function CleanName(name)
    if not name then return nil end
    name = name:gsub("|H.-|h(.-)|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if YOU and name == YOU then return playerName end
    if Ambiguate then name = Ambiguate(name, "short") end
    return name
end

local ForEachGroupMember -- defined just below

-- Find a player's class: yourself, then by name, then by scanning the group
-- (the scan catches players from other realms, whose names don't look up directly)
local function ClassOf(name)
    if not name then return nil end
    if name == playerName then return select(2, UnitClass("player")) end
    local _, class = UnitClass(name)
    if class then return class end
    if IsInGroup() then
        ForEachGroupMember(function(unit)
            if not class and UnitName(unit) == name then
                class = select(2, UnitClass(unit))
            end
        end)
    end
    return class
end

local function Setting(key)
    return DungeonWinnerDB and DungeonWinnerDB.settings and DungeonWinnerDB.settings[key]
end

local function ColorName(name, class)
    if Setting("firstNameOnly") then name = name:match("^(%S+)") or name end
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return name end
    return ("|cff%02x%02x%02x%s|r"):format(math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255), name)
end

function ForEachGroupMember(fn)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) then fn(unit) end
        end
    else
        fn("player")
        for i = 1, GetNumSubgroupMembers() do fn("party" .. i) end
    end
end

-- Forever names are "First Last", and players can hide their last name in the
-- world (but not in chat). So the group list might say "Smelly" while chat says
-- "Smelly Man". This maps a chat name onto the group member's name so both
-- count as the same person.
local function FirstWord(s)
    return s and s:match("^(%S+)")
end

local function SameName(a, b)
    if not a or not b then return false end
    if a == b then return true end
    -- one is just the first name of the other
    return (a == FirstWord(b) and b:find(" ", 1, true) ~= nil)
        or (b == FirstWord(a) and a:find(" ", 1, true) ~= nil)
end

local function GroupKey(name)
    if not name then return nil end
    if SameName(name, playerName) then return playerName end
    local key = name
    if IsInGroup() then
        local found = false
        ForEachGroupMember(function(unit)
            local n = UnitName(unit)
            if not found and SameName(name, n) then
                key, found = n, true
            end
        end)
    end
    return key
end

---------------------------------------------------------------------------
-- Turning Blizzard's format strings into Lua patterns
-- e.g. "%s has selected Need for: %s"  ->  "^(.-) has selected Need for: (.-)$"
-- Handles positional tokens like "%2$s" used by some languages.
---------------------------------------------------------------------------

-- The modern client prefixes loot-roll lines with a clickable
-- "|HlootHistory:123|h[Loot]|h: " link. Remove it from both the format
-- strings and incoming messages so the rest lines up with the fields below.
local function StripFormatPrefix(fmt)
    return (fmt:gsub("|HlootHistory:%%%d*%$?d|h.-|h:?%s*", ""))
end

local function StripMessagePrefix(msg)
    return (msg:gsub("|HlootHistory:%d+|h.-|h:?%s*", ""))
end

local function BuildPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local positions, seq = {}, 0
    local tmp = fmt:gsub("%%(%d*)%$?([sd])", function(pos, kind)
        seq = seq + 1
        positions[seq] = tonumber(pos) or seq
        return kind == "d" and "\001" or "\002"
    end)
    -- Renumber positions to 1..n (stripping the prefix can leave gaps like 2,3)
    local sorted = {}
    for i, p in ipairs(positions) do sorted[i] = p end
    table.sort(sorted)
    local rank = {}
    for i, p in ipairs(sorted) do rank[p] = i end
    local order = {}
    for i, p in ipairs(positions) do order[i] = rank[p] end

    tmp = tmp:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
    tmp = tmp:gsub("\001", "(%%d+)")
    tmp = tmp:gsub("\002", "(.-)")
    return "^" .. tmp .. "$", order
end

-- ORDER MATTERS: more specific messages must come before general ones
-- (e.g. "X automatically passed on" before "X passed on", "You won" before "X won").
-- fields = what each %s/%d means in the English string, in order.
local MESSAGE_DEFS = {
    { "LOOT_ROLL_ALL_PASSED",        "allpassed", nil,        { "item" } },
    { "LOOT_ROLL_YOU_WON",           "won",       nil,        { "item" },                   true },
    { "LOOT_ROLL_WON",               "won",       nil,        { "player", "item" } },
    { "LOOT_ROLL_PASSED_SELF_AUTO",  "choice",    "Pass",     { "item" },                   true },
    { "LOOT_ROLL_PASSED_SELF",       "choice",    "Pass",     { "item" },                   true },
    { "LOOT_ROLL_NEED_SELF",         "choice",    "Need",     { "item" },                   true },
    { "LOOT_ROLL_GREED_SELF",        "choice",    "Greed",    { "item" },                   true },
    { "LOOT_ROLL_TRANSMOG_SELF",     "choice",    "Transmog", { "item" },                   true },
    { "LOOT_ROLL_DISENCHANT_SELF",   "choice",    "DE",       { "item" },                   true },
    { "LOOT_ROLL_PASSED_AUTO",       "choice",    "Pass",     { "player", "item" } },
    { "LOOT_ROLL_PASSED_AUTO_FEMALE","choice",    "Pass",     { "player", "item" } },
    { "LOOT_ROLL_PASSED",            "choice",    "Pass",     { "player", "item" } },
    { "LOOT_ROLL_NEED",              "choice",    "Need",     { "player", "item" } },
    { "LOOT_ROLL_GREED",             "choice",    "Greed",    { "player", "item" } },
    { "LOOT_ROLL_TRANSMOG",          "choice",    "Transmog", { "player", "item" } },
    { "LOOT_ROLL_DISENCHANT",        "choice",    "DE",       { "player", "item" } },
    { "LOOT_ROLL_ROLLED_NEED_ROLE_BONUS", "roll", "Need",     { "roll", "item", "player" } },
    { "LOOT_ROLL_ROLLED_NEED",       "roll",      "Need",     { "roll", "item", "player" } },
    { "LOOT_ROLL_ROLLED_GREED",      "roll",      "Greed",    { "roll", "item", "player" } },
    { "LOOT_ROLL_ROLLED_TRANSMOG",   "roll",      "Transmog", { "roll", "item", "player" } },
    { "LOOT_ROLL_ROLLED_DE",         "roll",      "DE",       { "roll", "item", "player" } },
}

local MESSAGES = {}
for _, d in ipairs(MESSAGE_DEFS) do
    local fmt = _G[d[1]]
    if type(fmt) == "string" then
        fmt = StripFormatPrefix(fmt)
        local pattern, order = BuildPattern(fmt)
        MESSAGES[#MESSAGES + 1] = {
            key = d[1], kind = d[2], choice = d[3], fields = d[4], self = d[5],
            pattern = pattern, order = order, fmt = fmt,
        }
    end
end

local MESSAGES_BY_KEY = {}
for _, def in ipairs(MESSAGES) do MESSAGES_BY_KEY[def.key] = def end

local function MatchMessage(def, msg)
    local caps = { msg:match(def.pattern) }
    if #caps == 0 then return nil end
    local byPos = {}
    for i, pos in ipairs(def.order) do byPos[pos] = caps[i] end
    local out = {}
    for i, field in ipairs(def.fields) do out[field] = byPos[i] end
    return out
end

---------------------------------------------------------------------------
-- Data
-- DungeonWinnerDB.history = { newest item first
--   { link, name, icon, itemID, time, done, winner, allPassed,
--     rolls = { [playerName] = { class, choice, roll } } }
-- }
---------------------------------------------------------------------------

local Render -- defined in the UI section

---------------------------------------------------------------------------
-- Dungeon runs: the leaderboard only counts loot won during the current
-- dungeon run. Entering a different dungeon (or coming back to the same one
-- after more than 15 minutes away) starts a new run.
---------------------------------------------------------------------------

local RUN_RESUME_SECONDS = 15 * 60
local inDungeon = false
local showingTest = false -- leaderboard shows /dw test data until real loot arrives

local function InDungeon()
    local inInstance, instanceType = IsInInstance()
    return inInstance and instanceType == "party"
end

local function StartRun(name, instanceID, isTest, manual)
    local now = time()
    local run = {
        id = tostring(now) .. "-" .. tostring(instanceID or 0) .. (isTest and "-test" or "") .. (manual and "-manual" or ""),
        name = name, instanceID = instanceID, started = now, test = isTest, manual = manual,
    }
    if isTest then
        DungeonWinnerDB.testRun = run
        showingTest = true
    else
        DungeonWinnerDB.run = run
        showingTest = false
    end
    return run
end

-- A run you started yourself (/dw start or the Start run button). It tracks
-- Greed wins anywhere until you end it, and dungeons don't replace it.
local function ManualActive()
    local run = DungeonWinnerDB.run
    return run ~= nil and run.manual and not run.ended
end

local function StartManualRun(name)
    StartRun(name or ("Run " .. date("%b %d, %H:%M")), nil, false, true)
    Print("Started tracking Greed wins: " .. DungeonWinnerDB.run.name .. ". End it with /dw stop.")
    if Render then Render() end
end

local function EndManualRun()
    if not ManualActive() then
        Print("No manual run to end.")
        return
    end
    DungeonWinnerDB.run.ended = time()
    Print("Ended run: " .. DungeonWinnerDB.run.name .. ".")
    -- If you're standing in a dungeon, carry on tracking it as a normal dungeon run
    if InDungeon() then
        local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
        StartRun(name, instanceID)
        Print("Tracking Greed wins for " .. (name or "this dungeon") .. ".")
    end
    if Render then Render() end
end

local function CheckInstance()
    local run = DungeonWinnerDB.run
    if ManualActive() then
        inDungeon = InDungeon() -- manual runs aren't replaced by dungeons
        if Render then Render() end
        return
    end
    if InDungeon() then
        local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
        local now = time()
        local stale = run and run.leftAt and (now - run.leftAt > RUN_RESUME_SECONDS)
        if not run or run.instanceID ~= instanceID or stale then
            StartRun(name, instanceID)
            Print("Tracking Greed wins for " .. (name or "this dungeon") .. ".")
        else
            run.leftAt = nil
            showingTest = false
        end
        inDungeon = true
    else
        if inDungeon and run then run.leftAt = time() end
        inDungeon = false
    end
    if Render then Render() end
end

local function NewItem(link, name, icon)
    local id = ItemID(link)
    local item = {
        link = link, name = name, itemID = id, time = time(), rolls = {},
        icon = icon or (id and GetIconByID and GetIconByID(id)),
    }
    if IsInGroup() then
        ForEachGroupMember(function(unit)
            local n = UnitName(unit)
            if n then item.rolls[n] = { class = select(2, UnitClass(unit)) } end
        end)
    end
    local run = DungeonWinnerDB.run
    if run and not run.ended and (ManualActive() or (inDungeon and not run.manual)) then
        item.runId = DungeonWinnerDB.run.id
        showingTest = false
    end
    local hist = DungeonWinnerDB.history
    table.insert(hist, 1, item)
    while #hist > MAX_HISTORY do table.remove(hist) end
    return item
end

-- Find the oldest still-open item with this itemID that passes `pred`.
-- Oldest-first handles two copies of the same item dropping at once.
local function FindItem(id, link, pred)
    local hist = DungeonWinnerDB.history
    local fallback
    for i = #hist, 1, -1 do
        local it = hist[i]
        if not it.done and it.itemID == id then
            if not pred or pred(it) then return it end
            fallback = fallback or it
        end
    end
    return fallback or NewItem(link)
end

local function GetEntry(item, who)
    local r = item.rolls[who]
    if not r then
        r = { class = ClassOf(who) }
        item.rolls[who] = r
    end
    return r
end

-- Item value for the leaderboard: vendor price by default, or the
-- Auctionator price when that setting is on (falls back to vendor when
-- Auctionator has no price, e.g. bind-on-pickup items).
local GetItemInfoCompat = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function VendorPrice(item)
    if item.vendorPrice == nil and (item.link or item.itemID) then
        local sell = select(11, GetItemInfoCompat(item.itemID or item.link))
        if sell then
            item.vendorPrice = sell
        elseif item.itemID and C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(item.itemID) -- GET_ITEM_INFO_RECEIVED re-renders
        end
    end
    return item.vendorPrice
end

local function AuctionatorReady()
    return Auctionator ~= nil and Auctionator.API ~= nil and Auctionator.API.v1 ~= nil
        and Auctionator.API.v1.GetAuctionPriceByItemID ~= nil
end

local function AuctionPrice(item)
    if not AuctionatorReady() then return nil end
    local api = Auctionator.API.v1
    local ok, price
    if item.link and api.GetAuctionPriceByItemLink then
        ok, price = pcall(api.GetAuctionPriceByItemLink, "DungeonWinner", item.link)
    end
    if (not ok or not price) and item.itemID then
        ok, price = pcall(api.GetAuctionPriceByItemID, "DungeonWinner", item.itemID)
    end
    return ok and price or nil
end

local function ItemValue(item)
    if Setting("useAH") then
        local p = AuctionPrice(item)
        if p then return p, "Auctionator" end
    end
    local v = VendorPrice(item)
    if v then return v, "vendor" end
    return nil
end

local function MoneyText(copper)
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        return C_CurrencyInfo.GetCoinTextureString(copper)
    elseif GetCoinTextureString then
        return GetCoinTextureString(copper)
    end
    return ("%dg %ds %dc"):format(math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

-- Anyone rolls a 67 and the addon tells your group about it
local ANNOUNCE_67 = "~~~ 6 7 ~~~ ┐(°o°)┌ ~~~ 6 7 ~~~"

local function GroupChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function Announce67()
    local channel = GroupChannel()
    if not channel then
        Print(ANNOUNCE_67) -- not in a group: just show it to you
        return
    end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    local ok, err = pcall(send, ANNOUNCE_67, channel)
    if not ok then
        Print(ANNOUNCE_67)
        if debugMode then Print("Couldn't send to " .. channel .. ":", tostring(err)) end
    end
end

local function HandleMessage(def, f, isTest)
    local who = def.self and playerName or GroupKey(CleanName(f.player))
    local id = ItemID(f.item)
    if not id then return end

    if def.kind == "choice" then
        local item = FindItem(id, f.item, function(it)
            local r = it.rolls[who]
            return not r or not r.choice
        end)
        GetEntry(item, who).choice = def.choice

    elseif def.kind == "roll" then
        local item = FindItem(id, f.item, function(it)
            local r = it.rolls[who]
            return r and r.choice == def.choice and not r.roll
        end)
        local r = GetEntry(item, who)
        r.choice = r.choice or def.choice
        r.roll = tonumber(f.roll)
        -- Anyone in the group rolls a 67 -> every DungeonWinner user in the group says it
        if r.roll == 67 and not isTest and Setting("announce67") then
            Announce67()
        end

    elseif def.kind == "won" then
        local item = FindItem(id, f.item, function(it)
            return it.rolls[who] and it.rolls[who].roll
        end)
        item.winner = who
        item.done = true
        VendorPrice(item)

    elseif def.kind == "allpassed" then
        local item = FindItem(id, f.item)
        item.allPassed = true
        item.done = true
    end
end

-- "Active everywhere" off (default): only record rolls inside dungeons and raids
local function IsActive()
    if Setting("activeEverywhere") or ManualActive() then return true end
    local inInstance, instanceType = IsInInstance()
    return inInstance and (instanceType == "party" or instanceType == "raid")
end

local function OnLootMessage(msg, force)
    if IsSecret(msg) then
        if debugMode then Print("CHAT_MSG_LOOT text is a secret value here; can't read it.") end
        return
    end
    if not force and not IsActive() then return end
    msg = StripMessagePrefix(msg)
    for _, def in ipairs(MESSAGES) do
        local f = MatchMessage(def, msg)
        if f then
            if debugMode then Print("matched", def.key) end
            HandleMessage(def, f, force) -- force = test roll, never announced
            Render()
            return
        end
    end
end

local function OnStartRoll(rollID, rollTime)
    if not IsActive() then return end
    local link = GetLootRollItemLink(rollID)
    local icon, name = GetLootRollItemInfo(rollID)
    -- Fold away finished items so the new roll(s) are easy to see
    for _, old in ipairs(DungeonWinnerDB.history) do
        if old.done then old.collapsed = true end
    end
    local item = NewItem(link, name, icon)
    -- Safety net: close the entry if we never see a "won"/"everyone passed" line
    local seconds = (rollTime or 60000) / 1000 + 30
    C_Timer.After(seconds, function()
        if not item.done then item.done = true; Render() end
    end)
    if DungeonWinnerDB.autoShow then DungeonWinnerFrame:Show() end
    Render()
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local CHOICE_RANK = { Need = 1, Greed = 2, Transmog = 3, DE = 4, Pass = 5 }

-- Same icons as the default loot roll popup. The modern client uses atlases;
-- the old texture files are the fallback if an atlas isn't found.
local CHOICE_ICON = {
    Need     = { atlas = "lootroll-toast-icon-need-up",     file = "Interface\\Buttons\\UI-GroupLoot-Dice-Up" },
    Greed    = { atlas = "lootroll-toast-icon-greed-up",    file = "Interface\\Buttons\\UI-GroupLoot-Coin-Up" },
    Transmog = { atlas = "lootroll-toast-icon-transmog-up", file = "Interface\\Buttons\\UI-GroupLoot-Coin-Up" },
    DE       = { atlas = "lootroll-toast-icon-disenchant-up", file = "Interface\\Buttons\\UI-GroupLoot-DE-Up" },
    Pass     = { atlas = "lootroll-toast-icon-pass-up",     file = "Interface\\Buttons\\UI-GroupLoot-Pass-Up" },
}

local function SetChoiceIcon(tex, choice)
    local info = CHOICE_ICON[choice]
    if not info then tex:Hide() return end
    if info.atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(info.atlas) then
        tex:SetAtlas(info.atlas)
    else
        tex:SetTexture(info.file)
        tex:SetTexCoord(0, 1, 0, 1)
    end
    tex:Show()
end

---------------------------------------------------------------------------
-- Window: dark compact panel, one card per item, rolls listed under it
---------------------------------------------------------------------------

local CARD_H, ROW_H, GAP = 44, 18, 6
local NUMBER_COLOR = { 1, 0.82, 0 }

local frame = CreateFrame("Frame", "DungeonWinnerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetSize(280, 420)
frame:SetPoint("CENTER")
frame:SetFrameStrata("MEDIUM")
frame:SetMovable(true)
frame:SetResizable(true)
if frame.SetResizeBounds then frame:SetResizeBounds(240, 160, 520, 900) end
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
frame:SetBackdropColor(0.04, 0.04, 0.06, 0.92)
frame:SetBackdropBorderColor(0.22, 0.22, 0.26, 1)
frame:Hide()

local function SaveLayout()
    local point, _, relPoint, x, y = frame:GetPoint()
    DungeonWinnerDB.layout = { point, relPoint, x, y, frame:GetWidth(), frame:GetHeight() }
end

local function RestoreLayout()
    local l = DungeonWinnerDB.layout
    if not l then return end
    frame:ClearAllPoints()
    frame:SetPoint(l[1], UIParent, l[2], l[3], l[4])
    frame:SetSize(l[5], l[6])
end

frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveLayout()
end)

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 10, -8)
title:SetText("DungeonWinner")

local close = CreateFrame("Button", nil, frame)
close:SetSize(18, 18)
close:SetPoint("TOPRIGHT", -5, -4)
close.text = close:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
close.text:SetPoint("CENTER")
close.text:SetText("x")
close:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 0.3, 0.3) end)
close:SetScript("OnLeave", function(self) self.text:SetTextColor(1, 1, 1) end)
close:SetScript("OnClick", function() frame:Hide() end)

local divider = frame:CreateTexture(nil, "ARTWORK")
divider:SetColorTexture(1, 1, 1, 0.08)
divider:SetHeight(1)
divider:SetPoint("TOPLEFT", 1, -26)
divider:SetPoint("TOPRIGHT", -1, -26)

-- Tabs: Rolls | Leaderboard
local view = "rolls"
local tabs = {}
local function MakeTab(key, label, x, width)
    local t = CreateFrame("Button", nil, frame)
    t:SetSize(width, 20)
    t:SetPoint("TOPLEFT", x, -28)
    t.text = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t.text:SetPoint("CENTER")
    t.text:SetText(label)
    t.line = t:CreateTexture(nil, "ARTWORK")
    t.line:SetHeight(2)
    t.line:SetPoint("BOTTOMLEFT")
    t.line:SetPoint("BOTTOMRIGHT")
    t.line:SetColorTexture(0.25, 0.5, 0.8, 1)
    t:SetScript("OnClick", function() view = key; Render() end)
    tabs[key] = t
end
MakeTab("rolls", "Rolls", 8, 60)
MakeTab("board", "Leaderboard", 72, 90)

local function UpdateTabs()
    for key, t in pairs(tabs) do
        local on = (key == view)
        t.line:SetShown(on)
        if on then t.text:SetTextColor(1, 0.82, 0) else t.text:SetTextColor(0.6, 0.6, 0.6) end
    end
end

local divider2 = frame:CreateTexture(nil, "ARTWORK")
divider2:SetColorTexture(1, 1, 1, 0.08)
divider2:SetHeight(1)
divider2:SetPoint("TOPLEFT", 1, -49)
divider2:SetPoint("TOPRIGHT", -1, -49)

-- Scroll area with a thin custom scrollbar
local scroll = CreateFrame("ScrollFrame", nil, frame)
scroll:SetPoint("TOPLEFT", 6, -53)
scroll:SetPoint("BOTTOMRIGHT", -16, 16)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(250, 1)
scroll:SetScrollChild(content)
scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)

local bar = CreateFrame("Slider", nil, frame)
bar:SetOrientation("VERTICAL")
bar:SetWidth(5)
bar:SetPoint("TOPRIGHT", -6, -55)
bar:SetPoint("BOTTOMRIGHT", -6, 18)
bar.bg = bar:CreateTexture(nil, "BACKGROUND")
bar.bg:SetAllPoints()
bar.bg:SetColorTexture(1, 1, 1, 0.06)
bar:SetThumbTexture("Interface\\Buttons\\WHITE8x8")
bar:GetThumbTexture():SetSize(5, 40)
bar:GetThumbTexture():SetVertexColor(0.25, 0.5, 0.8, 1)
bar:SetMinMaxValues(0, 0)
bar:SetValue(0)
bar:SetScript("OnValueChanged", function(_, v) scroll:SetVerticalScroll(v) end)

scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(_, delta)
    local _, max = bar:GetMinMaxValues()
    bar:SetValue(math.max(0, math.min(max, bar:GetValue() - delta * 40)))
end)

local function UpdateScrollRange()
    local max = math.max(0, content:GetHeight() - scroll:GetHeight())
    bar:SetMinMaxValues(0, max)
    if bar:GetValue() > max then bar:SetValue(max) end
    bar:SetShown(max > 0)
end

-- Resize grip in the bottom-right corner
local grip = CreateFrame("Button", nil, frame)
grip:SetSize(14, 14)
grip:SetPoint("BOTTOMRIGHT", -2, 2)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
local MIN_W, MAX_W, MIN_H, MAX_H = 240, 520, 160, 900

grip:SetScript("OnMouseDown", function(self)
    -- Pin the top-left corner, then size the window to follow the cursor.
    -- Done by hand (instead of StartSizing) so it can't jump, and nothing
    -- heavy runs while dragging.
    local left, top = frame:GetLeft(), frame:GetTop()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    local scale = frame:GetEffectiveScale()
    self:SetScript("OnUpdate", function()
        local cx, cy = GetCursorPosition()
        cx, cy = cx / scale, cy / scale
        local w = math.max(MIN_W, math.min(MAX_W, cx - left + 6))
        local h = math.max(MIN_H, math.min(MAX_H, top - cy + 6))
        frame:SetSize(w, h)
    end)
end)
grip:SetScript("OnMouseUp", function(self)
    self:SetScript("OnUpdate", nil)
    SaveLayout()
    Render()
end)

local emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
emptyText:SetPoint("TOP", 0, -20)
emptyText:SetText("No rolls yet. Try /dw test")

---------------------------------------------------------------------------
-- Item quality color (works with both old "|cffRRGGBB" and new "|cnIQ4:" links)
---------------------------------------------------------------------------

local function QualityColor(item)
    local q = item.itemID and C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(item.itemID)
    local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
    local r, g, b = (item.link or ""):match("|c%x%x(%x%x)(%x%x)(%x%x)")
    if r then return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255 end
    return 0.6, 0.6, 0.6
end

---------------------------------------------------------------------------
-- Pools: one "card" per item, one "row" per player
---------------------------------------------------------------------------

local cardPool, rowPool = {}, {}

local function GetCard(i)
    local c = cardPool[i]
    if c then return c end

    c = CreateFrame("Button", nil, content)
    c:SetHeight(CARD_H)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    c.bg:SetColorTexture(1, 1, 1, 0.045)
    c:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
    c:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.05)

    c.toggle = c:CreateTexture(nil, "ARTWORK")
    c.toggle:SetSize(14, 14)
    c.toggle:SetPoint("LEFT", 4, 0)

    c.iconBorder = c:CreateTexture(nil, "BORDER")
    c.iconBorder:SetSize(38, 38)
    c.iconBorder:SetPoint("LEFT", 22, 0)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(36, 36)
    c.icon:SetPoint("CENTER", c.iconBorder)
    c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.name:SetPoint("TOPLEFT", c.iconBorder, "TOPRIGHT", 6, -3)
    c.name:SetPoint("RIGHT", -6, 0)
    c.name:SetJustifyH("LEFT")
    c.name:SetWordWrap(false)

    c.num = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.num:SetPoint("BOTTOMRIGHT", -6, 6)
    c.num:SetWidth(28)
    c.num:SetJustifyH("RIGHT")
    c.num:SetTextColor(unpack(NUMBER_COLOR))
    c.choice = c:CreateTexture(nil, "ARTWORK")
    c.choice:SetSize(16, 16)
    c.choice:SetPoint("RIGHT", c.num, "LEFT", -2, 0)

    c.sub = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.sub:SetPoint("BOTTOMLEFT", c.iconBorder, "BOTTOMRIGHT", 6, 4)
    c.sub:SetPoint("RIGHT", c.choice, "LEFT", -4, 0)
    c.sub:SetJustifyH("LEFT")
    c.sub:SetWordWrap(false)

    c:SetScript("OnClick", function(self)
        if self.item then
            self.item.collapsed = not self.item.collapsed
            Render()
        end
    end)
    c:SetScript("OnEnter", function(self)
        if self.item and self.item.link then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.item.link)
            GameTooltip:Show()
        end
    end)
    c:SetScript("OnLeave", GameTooltip_Hide)

    cardPool[i] = c
    return c
end

local function GetRow(i)
    local r = rowPool[i]
    if r then return r end

    r = CreateFrame("Frame", nil, content)
    r:SetHeight(ROW_H)
    r.winBg = r:CreateTexture(nil, "BACKGROUND")
    r.winBg:SetAllPoints()
    r.winBg:SetColorTexture(0.1, 1, 0.1, 0.12)

    r.num = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.num:SetPoint("RIGHT", -6, 0)
    r.num:SetWidth(28)
    r.num:SetJustifyH("RIGHT")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(15, 15)
    r.icon:SetPoint("RIGHT", r.num, "LEFT", -2, 0)

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", 66, 0)
    r.name:SetPoint("RIGHT", r.icon, "LEFT", -4, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)

    rowPool[i] = r
    return r
end

local function SortedNames(item)
    local names = {}
    for n in pairs(item.rolls) do names[#names + 1] = n end
    table.sort(names, function(a, b)
        local ra, rb = item.rolls[a], item.rolls[b]
        if (item.winner == a) ~= (item.winner == b) then return item.winner == a end
        local ca, cb = CHOICE_RANK[ra.choice] or 9, CHOICE_RANK[rb.choice] or 9
        if ca ~= cb then return ca < cb end
        local na, nb = ra.roll or -1, rb.roll or -1
        if na ~= nb then return na > nb end
        return a < b
    end)
    return names
end

local function Place(f, y)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    f:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
    f:Show()
end

local function FillCard(c, item)
    c.item = item
    c.toggle:SetTexture(item.collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    c.iconBorder:SetColorTexture(QualityColor(item))
    c.icon:SetTexture(item.icon or 134400)
    c.name:SetText(item.link or item.name or "?")

    local total, chosen = 0, 0
    for _, e in pairs(item.rolls) do
        total = total + 1
        if e.choice then chosen = chosen + 1 end
    end

    c.choice:Hide()
    c.num:SetText("")
    if item.allPassed then
        c.sub:SetText("|cff9d9d9dEveryone passed|r")
    elseif item.winner then
        local w = item.rolls[item.winner] or {}
        w.class = w.class or ClassOf(item.winner)
        c.sub:SetText(ColorName(item.winner, w.class))
        SetChoiceIcon(c.choice, w.choice)
        c.num:SetText(w.roll and tostring(w.roll) or "")
    elseif not item.done then
        c.sub:SetText(("|cffaaaaaaRolling...  %d/%d|r"):format(chosen, total))
    else
        c.sub:SetText("|cff9d9d9dFinished|r")
    end
end

local function FillRow(r, item, name)
    local e = item.rolls[name]
    e.class = e.class or ClassOf(name) -- fill in late if we missed it earlier
    r.name:SetText(ColorName(name, e.class))
    r.winBg:SetShown(item.winner == name)
    if e.choice then
        SetChoiceIcon(r.icon, e.choice)
        if e.roll then
            r.num:SetTextColor(unpack(NUMBER_COLOR))
            r.num:SetText(tostring(e.roll))
        elseif e.choice ~= "Pass" and not item.done then
            r.num:SetTextColor(0.5, 0.5, 0.5)
            r.num:SetText("-") -- chose, waiting for everyone else before numbers roll
        else
            r.num:SetText("")
        end
    else
        r.icon:Hide()
        r.num:SetTextColor(0.5, 0.5, 0.5)
        r.num:SetText("...")
    end
end

---------------------------------------------------------------------------
-- Leaderboard: Greed wins only, current dungeon run only
---------------------------------------------------------------------------

local function ComputeLeaderboard(run)
    local scores, list = {}, {}
    if not run then return list end

    local function Entry(name, class)
        local s = scores[name]
        if not s then
            s = { name = name, total = 0, count = 0, class = class, items = {}, unpriced = 0 }
            scores[name] = s
            list[#list + 1] = s
        end
        s.class = s.class or class
        return s
    end

    for _, item in ipairs(DungeonWinnerDB.history) do
        if item.runId == run.id then
            -- everyone who took part in this run's rolls gets a spot
            for name, e in pairs(item.rolls) do Entry(name, e.class) end
            local w = item.winner and item.rolls[item.winner]
            if w and w.choice == "Greed" then -- Need wins don't count
                local s = Entry(item.winner, w.class)
                local v = ItemValue(item)
                s.total = s.total + (v or 0)
                s.count = s.count + 1
                if not v or v == 0 then s.unpriced = s.unpriced + 1 end
                s.items[#s.items + 1] = item
            end
        end
    end
    -- Put everyone in the current group on the board, even with nothing yet
    local live = not run.test and (ManualActive() and run == DungeonWinnerDB.run or (inDungeon and not run.manual))
    if live and IsInGroup() then
        ForEachGroupMember(function(unit)
            local n = UnitName(unit)
            if n and not scores[n] then
                scores[n] = { name = n, total = 0, count = 0, class = select(2, UnitClass(unit)) }
                list[#list + 1] = scores[n]
            end
        end)
    end
    table.sort(list, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return list
end

local board = CreateFrame("Frame", nil, frame)
board:SetPoint("TOPLEFT", 6, -53)
board:SetPoint("BOTTOMRIGHT", -6, 18)
board:Hide()

board.title = board:CreateFontString(nil, "OVERLAY", "GameFontNormal")
board.title:SetPoint("TOPLEFT", 4, -4)
board.title:SetJustifyH("LEFT")
board.title:SetWordWrap(false)

board.sub = board:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
board.sub:SetPoint("TOPLEFT", board.title, "BOTTOMLEFT", 0, -3)
board.sub:SetPoint("RIGHT", -4, 0)
board.sub:SetJustifyH("LEFT")
board.sub:SetWordWrap(false)

board.empty = board:CreateFontString(nil, "OVERLAY", "GameFontDisable")
board.empty:SetPoint("TOP", 0, -60)

-- Buttons at the top-right of the leaderboard: [Start run / End run] [Reset]
local function BoardButton(width, parent)
    local b = CreateFrame("Button", nil, parent or board, BackdropTemplateMixin and "BackdropTemplate" or nil)
    b:SetSize(width, 18)
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    b:SetBackdropColor(1, 1, 1, 0.06)
    b:SetBackdropBorderColor(1, 1, 1, 0.18)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER")
    b:SetScript("OnEnter", function(self) self:SetBackdropColor(1, 1, 1, 0.14) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropColor(1, 1, 1, 0.06) end)
    return b
end

board.reset = BoardButton(46)
board.reset:SetPoint("TOPRIGHT", board, "TOPRIGHT", -2, -2)
board.reset.text:SetText("Reset")
board.reset:SetScript("OnClick", function(self)
    -- First click asks, second click (within 3 seconds) resets
    if not self.confirming then
        self.confirming = true
        self.text:SetText("|cffff5555Sure?|r")
        C_Timer.After(3, function()
            self.confirming = false
            self.text:SetText("Reset")
        end)
        return
    end
    self.confirming = false
    self.text:SetText("Reset")
    if showingTest then
        DungeonWinnerDB.testRun = nil
        showingTest = false
    elseif ManualActive() then
        StartRun(DungeonWinnerDB.run.name, nil, false, true) -- fresh start, same name
    elseif InDungeon() then
        local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
        StartRun(name, instanceID)
    else
        DungeonWinnerDB.run = nil
    end
    Render()
end)

board.toggle = BoardButton(66)
board.toggle:SetPoint("RIGHT", board.reset, "LEFT", -4, 0)
board.toggle:SetScript("OnClick", function()
    if ManualActive() then EndManualRun() else StartManualRun() end
end)

-- keep the run name clear of the buttons
board.title:SetPoint("RIGHT", board.toggle, "LEFT", -6, 0)

-- Clear button on the Rolls tab. It hides rolls from the list but keeps them
-- for the leaderboard, so clearing never changes anyone's score.
local function ClearRolls()
    local hist = DungeonWinnerDB.history
    for i = #hist, 1, -1 do
        local item = hist[i]
        if not item.done then
            -- still rolling: leave it so you can watch it finish
        elseif item.runId then
            item.hidden = true       -- still counted on its leaderboard
        else
            table.remove(hist, i)    -- not part of any leaderboard, safe to delete
        end
    end
    Render()
end

local clearBtn = BoardButton(46, frame)
clearBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -29)
clearBtn.text:SetText("Clear")
clearBtn:SetScript("OnClick", function(self)
    if not self.confirming then
        self.confirming = true
        self.text:SetText("|cffff5555Sure?|r")
        C_Timer.After(3, function()
            self.confirming = false
            self.text:SetText("Clear")
        end)
        return
    end
    self.confirming = false
    self.text:SetText("Clear")
    ClearRolls()
end)

local RANK_COLORS = { { 1, 0.82, 0 }, { 0.8, 0.8, 0.85 }, { 0.8, 0.5, 0.25 } }
local boardRows = {}

local function GetBoardRow(i)
    local r = boardRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, board)
    r:SetHeight(22)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(1, 1, 1, i % 2 == 1 and 0.045 or 0.02)
    r.rank = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.rank:SetPoint("LEFT", 4, 0)
    r.rank:SetWidth(22)
    r.rank:SetJustifyH("RIGHT")
    r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.value:SetPoint("RIGHT", -6, 0)
    r.value:SetJustifyH("RIGHT")
    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.count:SetPoint("RIGHT", r.value, "LEFT", -8, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.name:SetPoint("LEFT", r.rank, "RIGHT", 8, 0)
    r.name:SetPoint("RIGHT", r.count, "LEFT", -6, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        local s = self.score
        if not s then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ColorName(s.name, s.class))
        if #s.items == 0 then
            GameTooltip:AddLine("No Greed wins yet", 0.6, 0.6, 0.6)
        end
        for _, item in ipairs(s.items) do
            local v = ItemValue(item)
            GameTooltip:AddDoubleLine(item.link or item.name or "?",
                (v and v > 0) and MoneyText(v) or "|cff888888no price|r", 1, 1, 1, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    boardRows[i] = r
    return r
end

local function RenderBoard()
    for _, r in ipairs(boardRows) do r:Hide() end
    local run = showingTest and DungeonWinnerDB.testRun or DungeonWinnerDB.run

    board.toggle.text:SetText(ManualActive() and "End run" or "Start run")

    if not run then
        board.title:SetText("No run yet")
        board.sub:SetText("Enter a dungeon, or click Start run below.")
        board.empty:Hide()
        board.reset:Hide()
        return
    end

    local live = not run.test and (ManualActive() or (inDungeon and not run.manual))
    local minutes = math.floor(((run.ended or run.leftAt or time()) - run.started) / 60)
    local prices = (Setting("useAH") and AuctionatorReady()) and "Auctionator prices" or "vendor prices"
    local kind = run.manual and "manual, " or ""
    local status = run.test and "test data" or (kind .. minutes .. "m, " .. (live and "in progress" or "finished"))
    board.title:SetText(run.name or "Dungeon")
    board.sub:SetText("Greed wins only - " .. prices .. " - " .. status)

    local list = ComputeLeaderboard(run)
    board.empty:SetShown(#list == 0)
    board.empty:SetText("No Greed wins yet.")

    local y = 38
    for i, s in ipairs(list) do
        local r = GetBoardRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", board, "TOPLEFT", 0, -y)
        r:SetPoint("TOPRIGHT", board, "TOPRIGHT", 0, -y)
        local rc = RANK_COLORS[i]
        r.rank:SetText(i .. ".")
        if rc then r.rank:SetTextColor(rc[1], rc[2], rc[3]) else r.rank:SetTextColor(0.6, 0.6, 0.6) end
        r.name:SetText(ColorName(s.name, s.class))
        if s.count == 0 then r.count:SetText("")
        else r.count:SetText(s.count == 1 and "1 item" or (s.count .. " items")) end
        r.score = s
        if s.total > 0 then
            r.value:SetText(MoneyText(s.total))
        elseif s.count > 0 then
            r.value:SetText("|cff888888no price|r")
        else
            r.value:SetText("|cff666666-|r")
        end
        r:Show()
        y = y + 22
    end
    board.reset:Show()
end

function Render()
    if not frame:IsShown() then return end
    UpdateTabs()
    clearBtn:SetShown(view == "rolls")
    if view == "board" then
        scroll:Hide()
        bar:Hide()
        board:Show()
        RenderBoard()
        return
    end
    board:Hide() -- its buttons hide with it
    scroll:Show()
    for _, c in ipairs(cardPool) do c:Hide() end
    for _, r in ipairs(rowPool) do r:Hide() end

    local y, ci, ri = 0, 0, 0
    for _, item in ipairs(DungeonWinnerDB.history) do
        if not item.hidden then
            ci = ci + 1
            local c = GetCard(ci)
            FillCard(c, item)
            Place(c, y)
            y = y + CARD_H

            if not item.collapsed then
                for _, name in ipairs(SortedNames(item)) do
                    ri = ri + 1
                    local r = GetRow(ri)
                    FillRow(r, item, name)
                    Place(r, y)
                    y = y + ROW_H
                end
            end
            y = y + GAP
        end
    end

    emptyText:SetShown(ci == 0)
    content:SetHeight(math.max(y, 1))
    UpdateScrollRange()
end

frame:SetScript("OnShow", Render)
frame:SetScript("OnSizeChanged", function() if frame:IsShown() and view == "rolls" then UpdateScrollRange() end end)

---------------------------------------------------------------------------
-- Settings window (right-click the minimap button, or /dw settings)
---------------------------------------------------------------------------

local UpdateMinimapButton -- defined in the minimap section below
local RunTest             -- defined in the test section below

local settings = CreateFrame("Frame", "DungeonWinnerSettings", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
local SETTINGS_BASE_H = 344
settings:SetSize(300, SETTINGS_BASE_H)
settings:SetPoint("CENTER", 0, 80)
settings:SetFrameStrata("DIALOG")
settings:SetMovable(true)
settings:SetClampedToScreen(true)
settings:EnableMouse(true)
settings:RegisterForDrag("LeftButton")
settings:SetScript("OnDragStart", settings.StartMoving)
settings:SetScript("OnDragStop", settings.StopMovingOrSizing)
settings:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
settings:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
settings:SetBackdropBorderColor(0.22, 0.22, 0.26, 1)
settings:Hide()

local sTitle = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sTitle:SetPoint("TOPLEFT", 10, -8)
sTitle:SetText("DungeonWinner Settings")

local sClose = CreateFrame("Button", nil, settings)
sClose:SetSize(18, 18)
sClose:SetPoint("TOPRIGHT", -5, -4)
sClose.text = sClose:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
sClose.text:SetPoint("CENTER")
sClose.text:SetText("x")
sClose:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 0.3, 0.3) end)
sClose:SetScript("OnLeave", function(self) self.text:SetTextColor(1, 1, 1) end)
sClose:SetScript("OnClick", function() settings:Hide() end)

local sDivider = settings:CreateTexture(nil, "ARTWORK")
sDivider:SetColorTexture(1, 1, 1, 0.08)
sDivider:SetHeight(1)
sDivider:SetPoint("TOPLEFT", 1, -26)
sDivider:SetPoint("TOPRIGHT", -1, -26)

local checks = {}

local function AddCheck(y, label, get, set, note)
    local cb = CreateFrame("CheckButton", nil, settings, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", 10, y)
    cb.y = y
    cb.label = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    cb.label:SetText(label)
    cb.note = settings:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    cb.note:SetPoint("TOPLEFT", cb.label, "BOTTOMLEFT", 0, -2)
    cb.note:SetPoint("RIGHT", settings, "RIGHT", -10, 0)
    cb.note:SetJustifyH("LEFT")
    cb.note:SetText(note or "")
    cb.get = get
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    checks[#checks + 1] = cb
    return cb
end

AddCheck(-34, "Active everywhere",
    function() return Setting("activeEverywhere") end,
    function(v) DungeonWinnerDB.settings.activeEverywhere = v end,
    "Off: only tracks rolls in dungeons and raids")

AddCheck(-78, "Only show first names",
    function() return Setting("firstNameOnly") end,
    function(v) DungeonWinnerDB.settings.firstNameOnly = v; Render() end,
    "Hides last names in the roll list")

local ahCheck = AddCheck(-122, "Use auction house prices",
    function() return Setting("useAH") end,
    function(v) DungeonWinnerDB.settings.useAH = v; Render() end)

AddCheck(-166, "Open when a roll starts",
    function() return DungeonWinnerDB.autoShow end,
    function(v) DungeonWinnerDB.autoShow = v end,
    "Pops the roll window up automatically")

AddCheck(-210, "Show minimap button",
    function() return DungeonWinnerDB.settings.showMinimap end,
    function(v) DungeonWinnerDB.settings.showMinimap = v; UpdateMinimapButton() end,
    "If hidden, bring it back with /dw minimap")

AddCheck(-254, "Announce 67s",
    function() return Setting("announce67") end,
    function(v) DungeonWinnerDB.settings.announce67 = v end,
    "Tells your group when anyone rolls a 67")

settings:SetScript("OnShow", function()
    for _, cb in ipairs(checks) do cb:SetChecked(cb.get() and true or false) end
    if AuctionatorReady() then
        ahCheck:Enable()
        ahCheck.label:SetTextColor(1, 1, 1)
        ahCheck.note:SetText("Leaderboard uses Auctionator prices (vendor price if none)")
    else
        ahCheck:Disable()
        ahCheck.label:SetTextColor(0.5, 0.5, 0.5)
        ahCheck.note:SetText("Needs the Auctionator addon. Using vendor prices.")
    end
end)

---------------------------------------------------------------------------
-- Themes (Settings > Theme). Each theme sets the window background, border,
-- title color, accent color (tabs + scrollbar) and how thick the border is.
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8x8"
local PositionThemePicker -- defined below
local THEME_ORDER = { "tooltip", "dialog", "minimal", "class", "parchment" }
local THEMES = {
    tooltip = {
        name = "Classic Tooltip", pad = 3,
        backdrop = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                     tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } },
        bg = { 0.06, 0.06, 0.14, 0.92 }, border = { 0.7, 0.7, 0.7, 1 },
        title = { 1, 0.82, 0 }, accent = { 0.4, 0.6, 1 },
    },
    dialog = {
        name = "Blizzard Dialog", pad = 8,
        backdrop = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                     tile = true, tileSize = 32, edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } },
        bg = { 1, 1, 1, 1 }, border = { 1, 1, 1, 1 },
        title = { 1, 0.82, 0 }, accent = { 1, 0.82, 0 },
    },
    minimal = {
        name = "Dark Minimal", pad = 0,
        backdrop = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 },
        bg = { 0.04, 0.04, 0.06, 0.92 }, border = { 0.22, 0.22, 0.26, 1 },
        title = { 1, 0.82, 0 }, accent = { 0.25, 0.5, 0.8 },
    },
    class = {
        name = "Class Color", pad = 1,
        backdrop = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 2 },
        bg = { 0.04, 0.04, 0.06, 0.92 }, border = "class",
        title = "class", accent = "class",
    },
    parchment = {
        name = "Parchment", pad = 3,
        backdrop = { bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                     edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } },
        bg = { 0.24, 0.18, 0.11, 0.95 }, border = { 0.65, 0.5, 0.3, 1 },
        title = { 1, 0.86, 0.55 }, accent = { 0.85, 0.65, 0.35 },
    },
}

local function ThemeColor(c)
    if c == "class" then
        local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[select(2, UnitClass("player"))]
        if cc then return cc.r, cc.g, cc.b, 1 end
        return 1, 0.82, 0, 1
    end
    return c[1], c[2], c[3], c[4] or 1
end

local function CurrentTheme()
    return THEMES[Setting("theme") or "minimal"] or THEMES.minimal
end

local function StyleWindow(f, t)
    f:SetBackdrop(t.backdrop)
    f:SetBackdropColor(ThemeColor(t.bg))
    f:SetBackdropBorderColor(ThemeColor(t.border))
end

local function Anchor(region, point, x, y, point2, x2, y2)
    region:ClearAllPoints()
    region:SetPoint(point, x, y)
    if point2 then region:SetPoint(point2, x2, y2) end
end

local function ApplyTheme()
    local t = CurrentTheme()
    local p = t.pad
    local ar, ag, ab = ThemeColor(t.accent)

    -- Main window
    StyleWindow(frame, t)
    title:SetTextColor(ThemeColor(t.title))
    Anchor(title, "TOPLEFT", 10 + p, -8 - p)
    Anchor(close, "TOPRIGHT", -5 - p, -4 - p)
    Anchor(divider, "TOPLEFT", 1 + p, -26 - p, "TOPRIGHT", -1 - p, -26 - p)
    Anchor(tabs.rolls, "TOPLEFT", 8 + p, -28 - p)
    Anchor(tabs.board, "TOPLEFT", 72 + p, -28 - p)
    Anchor(clearBtn, "TOPRIGHT", -8 - p, -29 - p)
    for _, tab in pairs(tabs) do tab.line:SetColorTexture(ar, ag, ab, 1) end
    Anchor(divider2, "TOPLEFT", 1 + p, -49 - p, "TOPRIGHT", -1 - p, -49 - p)
    Anchor(scroll, "TOPLEFT", 6 + p, -53 - p, "BOTTOMRIGHT", -16 - p, 16 + p)
    Anchor(bar, "TOPRIGHT", -6 - p, -55 - p, "BOTTOMRIGHT", -6 - p, 18 + p)
    bar:GetThumbTexture():SetVertexColor(ar, ag, ab, 1)
    Anchor(board, "TOPLEFT", 6 + p, -53 - p, "BOTTOMRIGHT", -6 - p, 18 + p)
    Anchor(grip, "BOTTOMRIGHT", -2 - p, 2 + p)

    -- Settings window
    StyleWindow(settings, t)
    sTitle:SetTextColor(ThemeColor(t.title))
    Anchor(sTitle, "TOPLEFT", 10 + p, -8 - p)
    Anchor(sClose, "TOPRIGHT", -5 - p, -4 - p)
    Anchor(sDivider, "TOPLEFT", 1 + p, -26 - p, "TOPRIGHT", -1 - p, -26 - p)
    for _, cb in ipairs(checks) do Anchor(cb, "TOPLEFT", 10 + p, cb.y - p) end
    settings:SetHeight(SETTINGS_BASE_H + p * 2)

    if UpdateTabs and frame:IsShown() then UpdateTabs() end
end

-- Theme picker in the settings window: < [ Theme name ] >  with a drop-down list
local themeLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
themeLabel:SetText("Theme")

local themeBox = CreateFrame("Button", nil, settings, BackdropTemplateMixin and "BackdropTemplate" or nil)
themeBox:SetSize(140, 22)
themeBox:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
themeBox:SetBackdropColor(0.1, 0.1, 0.12, 1)
themeBox:SetBackdropBorderColor(0.35, 0.35, 0.4, 1)
themeBox.text = themeBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
themeBox.text:SetPoint("CENTER")

local function ArrowButton(label)
    local b = CreateFrame("Button", nil, settings)
    b:SetSize(18, 22)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    b:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
    b:SetScript("OnLeave", function(self) self.text:SetTextColor(1, 0.82, 0) end)
    return b
end
local themePrev, themeNext = ArrowButton("<"), ArrowButton(">")

local themeMenu = CreateFrame("Frame", nil, settings, BackdropTemplateMixin and "BackdropTemplate" or nil)
themeMenu:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
themeMenu:SetBackdropColor(0.06, 0.06, 0.08, 0.98)
themeMenu:SetBackdropBorderColor(0.35, 0.35, 0.4, 1)
themeMenu:SetFrameLevel(settings:GetFrameLevel() + 20)
themeMenu:SetSize(140, #THEME_ORDER * 20 + 8)
themeMenu:Hide()

local function SetTheme(key)
    DungeonWinnerDB.settings.theme = key
    themeBox.text:SetText(THEMES[key].name)
    themeMenu:Hide()
    ApplyTheme()
    PositionThemePicker()
end

local menuButtons = {}
for i, key in ipairs(THEME_ORDER) do
    local b = CreateFrame("Button", nil, themeMenu)
    b:SetSize(132, 20)
    b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 20)
    b:SetHighlightTexture(WHITE)
    b:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 6, 0)
    b.text:SetText(THEMES[key].name)
    b.key = key
    b:SetScript("OnClick", function(self) SetTheme(self.key) end)
    menuButtons[#menuButtons + 1] = b
end

local function StepTheme(dir)
    local current = Setting("theme") or "minimal"
    local idx = 1
    for i, key in ipairs(THEME_ORDER) do if key == current then idx = i end end
    idx = ((idx - 1 + dir) % #THEME_ORDER) + 1
    SetTheme(THEME_ORDER[idx])
end

themeBox:SetScript("OnClick", function()
    local current = Setting("theme") or "minimal"
    for _, b in ipairs(menuButtons) do
        if b.key == current then b.text:SetTextColor(1, 0.82, 0) else b.text:SetTextColor(1, 1, 1) end
    end
    themeMenu:SetShown(not themeMenu:IsShown())
end)
themePrev:SetScript("OnClick", function() StepTheme(-1) end)
themeNext:SetScript("OnClick", function() StepTheme(1) end)

function PositionThemePicker()
    local p = CurrentTheme().pad
    Anchor(themeLabel, "TOPLEFT", 16 + p, -307 - p)
    Anchor(themeNext, "TOPRIGHT", -12 - p, -302 - p)
    themeBox:ClearAllPoints()
    themeBox:SetPoint("RIGHT", themeNext, "LEFT", -2, 0)
    themePrev:ClearAllPoints()
    themePrev:SetPoint("RIGHT", themeBox, "LEFT", -2, 0)
    themeMenu:ClearAllPoints()
    themeMenu:SetPoint("TOP", themeBox, "BOTTOM", 0, -2)
end

settings:HookScript("OnShow", function()
    themeBox.text:SetText(CurrentTheme().name)
    PositionThemePicker()
end)
settings:HookScript("OnHide", function() themeMenu:Hide() end)

---------------------------------------------------------------------------
-- Blizzard Settings panel (Esc > Options > AddOns > DungeonWinner).
-- If this client's Settings API doesn't match, we fall back to our own window.
---------------------------------------------------------------------------

local blizzCategory
local blizzSettings = {} -- key -> Blizzard setting object, to sync from slash commands

local function RegisterBlizzardSettings()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting
            and Settings.CreateCheckbox and Settings.RegisterAddOnCategory) then
        return false
    end
    local ok, err = pcall(function()
        local category, layout = Settings.RegisterVerticalLayoutCategory("DungeonWinner")
        local st = DungeonWinnerDB.settings

        local function Header(text)
            if layout and CreateSettingsListSectionHeaderInitializer then
                layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
            end
        end

        local function Check(tbl, key, name, default, tooltip, onChange)
            local setting = Settings.RegisterAddOnSetting(category, "DungeonWinner_" .. key, key, tbl, type(default), name, default)
            if onChange then setting:SetValueChangedCallback(function(_, value) onChange(value) end) end
            Settings.CreateCheckbox(category, setting, tooltip)
            blizzSettings[key] = setting
            return setting
        end

        Header("General")
        Check(st, "activeEverywhere", "Active everywhere", false,
            "Off: only tracks rolls inside dungeons and raids.\nOn: tracks group loot rolls anywhere.")
        Check(DungeonWinnerDB, "autoShow", "Open when a roll starts", true,
            "Pops the roll window up automatically when a Need/Greed/Pass roll starts.")
        Check(st, "showMinimap", "Show minimap button", true,
            "If hidden, bring it back with /dw minimap.",
            function() UpdateMinimapButton() end)
        Check(st, "announce67", "Announce 67s", true,
            "When anyone in your group rolls a 67, tells your group:\n" .. ANNOUNCE_67)

        Header("Leaderboard")
        Check(st, "useAH", "Use auction house prices", false,
            "Values items with Auctionator prices instead of vendor prices.\nNeeds the Auctionator addon; items with no AH price use their vendor price.",
            function() Render() end)

        Header("Appearance")
        Check(st, "firstNameOnly", "Only show first names", false,
            "Hides last names in the roll list and leaderboard.",
            function() Render() end)

        if Settings.CreateDropdown and Settings.CreateControlTextContainer then
            local themeSetting = Settings.RegisterAddOnSetting(category, "DungeonWinner_theme", "theme", st, "string", "Theme", "minimal")
            themeSetting:SetValueChangedCallback(function() ApplyTheme(); Render() end)
            local function ThemeOptions()
                local container = Settings.CreateControlTextContainer()
                for _, key in ipairs(THEME_ORDER) do container:Add(key, THEMES[key].name) end
                return container:GetData()
            end
            Settings.CreateDropdown(category, themeSetting, ThemeOptions, "Changes the look of the DungeonWinner window.")
            blizzSettings.theme = themeSetting
        end

        Settings.RegisterAddOnCategory(category)
        blizzCategory = category
    end)
    if not ok then
        if debugMode then Print("Blizzard settings panel unavailable:", tostring(err)) end
        blizzCategory = nil
    end
    return ok
end

-- Open our settings: the Blizzard AddOns page if it registered, otherwise our own window
local function OpenSettings()
    local panel = SettingsPanel
    -- Clicking again closes it
    if panel and panel:IsShown() then
        HideUIPanel(panel)
        return
    end
    if settings:IsShown() then
        settings:Hide()
        return
    end

    if blizzCategory then
        local id = (blizzCategory.GetID and blizzCategory:GetID()) or blizzCategory.ID
        -- Try the different ways this has worked across game versions, and
        -- check the panel actually appeared after each one.
        if Settings and Settings.OpenToCategory then pcall(Settings.OpenToCategory, id) end
        if panel and not panel:IsShown() and panel.OpenToCategory then
            pcall(panel.OpenToCategory, panel, id)
        end
        if panel and not panel:IsShown() then
            pcall(ShowUIPanel, panel)
            if panel:IsShown() and panel.SelectCategory then pcall(panel.SelectCategory, panel, blizzCategory) end
        end
        if panel and panel:IsShown() then return end
        if debugMode then Print("Couldn't open the Blizzard settings page; using DungeonWinner's own window.") end
    end
    settings:Show()
end

---------------------------------------------------------------------------
-- Minimap button: left-click = leaderboard, right-click = settings,
-- shift-left-click = test rolls, drag = move
---------------------------------------------------------------------------

local mm = CreateFrame("Button", "DungeonWinnerMinimapButton", Minimap)
mm:SetSize(31, 31)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mm:RegisterForDrag("LeftButton")
mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local mmBg = mm:CreateTexture(nil, "BACKGROUND")
mmBg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
mmBg:SetSize(20, 20)
mmBg:SetPoint("TOPLEFT", 7, -5)

local mmIcon = mm:CreateTexture(nil, "ARTWORK")
mmIcon:SetSize(18, 18)
mmIcon:SetPoint("TOPLEFT", 7, -6)
SetChoiceIcon(mmIcon, "Need") -- the dice

local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmBorder:SetSize(53, 53)
mmBorder:SetPoint("TOPLEFT")

local function UpdateMinimapPosition()
    local angle = math.rad(DungeonWinnerDB.settings.minimap.angle or 225)
    local radius = (Minimap:GetWidth() / 2) + 5
    mm:ClearAllPoints()
    mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function UpdateMinimapButton()
    mm:SetShown(DungeonWinnerDB.settings.showMinimap)
    UpdateMinimapPosition()
end

mm:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        DungeonWinnerDB.settings.minimap.angle = math.deg(math.atan2(py / scale - my, px / scale - mx))
        UpdateMinimapPosition()
    end)
end)
mm:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

mm:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
        OpenSettings()
    elseif IsShiftKeyDown() then
        view = "rolls"
        RunTest()
    elseif frame:IsShown() and view == "board" then
        frame:Hide()
    else
        view = "board"
        frame:Show()
        Render()
    end
end)

mm:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("DungeonWinner")
    GameTooltip:AddLine("Left-click: leaderboard", 1, 1, 1)
    GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
    GameTooltip:AddLine("Shift-left-click: test rolls", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
mm:SetScript("OnLeave", GameTooltip_Hide)

---------------------------------------------------------------------------
-- Test data: feeds fake chat lines through the real parser
---------------------------------------------------------------------------

function RunTest()
    -- Use real items from your bags so they exist in Forever, are already
    -- loaded, and have real prices. Fill up with a few known items if needed.
    local testItems, seen = {}, {}
    if C_Container and C_Container.GetContainerNumSlots then
        for bag = 0, (NUM_BAG_SLOTS or 4) do
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.hyperlink and info.itemID and not seen[info.itemID] then
                    seen[info.itemID] = true
                    testItems[#testItems + 1] = { info.hyperlink, info.itemName or "" }
                end
            end
        end
    end
    for i = #testItems, 2, -1 do -- shuffle so each test picks different items
        local j = math.random(i)
        testItems[i], testItems[j] = testItems[j], testItems[i]
    end
    while #testItems > 6 do table.remove(testItems) end
    local fallback = {
        { "|cffffffff|Hitem:14047::::::::60:::::::|h[Runecloth]|h|r", "Runecloth" },
        { "|cff1eff00|Hitem:13468::::::::60:::::::|h[Black Lotus]|h|r", "Black Lotus" },
        { "|cff0070dd|Hitem:14344::::::::60:::::::|h[Large Brilliant Shard]|h|r", "Large Brilliant Shard" },
        { "|cffa335ee|Hitem:12640::::::::60:::::::|h[Lionheart Helm]|h|r", "Lionheart Helm" },
        { "|cffa335ee|Hitem:19137::::::::60:::::::|h[Onslaught Girdle]|h|r", "Onslaught Girdle" },
        { "|cffa335ee|Hitem:19019::::::::60:::::::|h[Thunderfury, Blessed Blade of the Windseeker]|h|r", "Thunderfury" },
    }
    for _, f in ipairs(fallback) do
        if #testItems >= 6 then break end
        local id = ItemID(f[1])
        if not seen[id] then
            seen[id] = true
            testItems[#testItems + 1] = f
        end
    end
    local testRun = StartRun("Test Dungeon", 0, true)

    -- Remove earlier test entries so repeated tests don't pile up
    local hist = DungeonWinnerDB.history
    for i = #hist, 1, -1 do
        if hist[i].test then table.remove(hist, i) end
    end

    -- Each line is formatted with the same (prefix-stripped) string the parser uses,
    -- and prefixed like the real client does, so this exercises the full path.
    local failed = 0
    local function Feed(lines)
        for _, l in ipairs(lines) do
            local def = MESSAGES_BY_KEY[l[1]]
            local ok, text = false, nil
            if def then ok, text = pcall(string.format, def.fmt, unpack(l, 2)) end
            if ok then
                OnLootMessage("|HlootHistory:1|h[Loot]|h: " .. text, true) -- test works anywhere
            else
                failed = failed + 1
                Print("Test line failed:", l[1], def and def.fmt or "(string missing)")
            end
        end
    end

    local items = {}
    local mismatches = 0
    local fakeClasses = {
        ["Smelly Man"] = "PALADIN",
        ["Skinny Beans"] = "ROGUE",
        ["Meddle Floyd"] = "PRIEST",
        ["Mr Peka"] = "SHAMAN",
    }
    local players = { playerName, "Smelly Man", "Skinny Beans", "Meddle Floyd", "Mr Peka" }

    -- Simulates one full roll with random choices and random numbers,
    -- sending the same chat lines the game would, in a shuffled order.
    local function SimulateRoll(link, name)
        local it = NewItem(link, name, nil)
        it.test = true
        it.runId = testRun.id
        items[#items + 1] = it

        -- Like real dungeons: on some items nobody can use it, so it's Greed or Pass only
        local needable = math.random() < 0.4
        local choices = needable and { "Need", "Greed", "Pass" } or { "Greed", "Greed", "Pass" }
        local lines, rolls, expected = {}, {}, {}
        for _, p in ipairs(players) do
            local choice = choices[math.random(#choices)]
            expected[p] = { choice = choice }
            local isMe = (p == playerName)
            if choice == "Need" then
                lines[#lines + 1] = isMe and { "LOOT_ROLL_NEED_SELF", link } or { "LOOT_ROLL_NEED", p, link }
            elseif choice == "Greed" then
                lines[#lines + 1] = isMe and { "LOOT_ROLL_GREED_SELF", link } or { "LOOT_ROLL_GREED", p, link }
            else
                lines[#lines + 1] = isMe and { "LOOT_ROLL_PASSED_SELF", link } or { "LOOT_ROLL_PASSED", p, link }
            end
            if choice ~= "Pass" then
                local n = math.random(1, 100)
                expected[p].roll = n
                rolls[#rolls + 1] = { player = p, choice = choice, roll = n }
            end
        end

        -- Shuffle the choice lines so the parser can't rely on order
        for i = #lines, 2, -1 do
            local j = math.random(i)
            lines[i], lines[j] = lines[j], lines[i]
        end

        -- Winner: highest Need, otherwise highest Greed
        local winner
        for _, r in ipairs(rolls) do
            if not winner
                or (r.choice == "Need" and winner.choice ~= "Need")
                or (r.choice == winner.choice and r.roll > winner.roll) then
                winner = r
            end
        end

        for _, r in ipairs(rolls) do
            local key = r.choice == "Need" and "LOOT_ROLL_ROLLED_NEED" or "LOOT_ROLL_ROLLED_GREED"
            lines[#lines + 1] = { key, r.roll, link, r.player }
        end
        if winner then
            lines[#lines + 1] = winner.player == playerName and { "LOOT_ROLL_YOU_WON", link }
                or { "LOOT_ROLL_WON", winner.player, link }
        else
            lines[#lines + 1] = { "LOOT_ROLL_ALL_PASSED", link }
        end
        Feed(lines)

        -- Check the addon recorded exactly what was rolled
        for p, want in pairs(expected) do
            local got = it.rolls[p]
            if not got or got.choice ~= want.choice or got.roll ~= want.roll then
                mismatches = mismatches + 1
                Print(("Mismatch on %s for %s: expected %s %s, got %s %s"):format(
                    name, p, want.choice, tostring(want.roll or "-"),
                    tostring(got and got.choice), tostring(got and got.roll or "-")))
            end
        end
        local wantWinner = winner and winner.player or nil
        if it.winner ~= wantWinner or (not wantWinner and not it.allPassed) then
            mismatches = mismatches + 1
            Print(("Mismatch on %s: expected winner %s, got %s"):format(
                name, tostring(wantWinner or "everyone passed"), tostring(it.winner)))
        end
    end

    for _, t in ipairs(testItems) do SimulateRoll(t[1], t[2]) end

    -- Fake players aren't in your group, so give them classes to show the colors
    for i, it in ipairs(items) do
        it.collapsed = i <= #items - 3 -- keep the 3 newest open
        for name, class in pairs(fakeClasses) do
            if it.rolls[name] then it.rolls[name].class = class end
        end
    end

    showingTest = true -- (creating items inside a dungeon would otherwise switch this off)
    frame:Show()
    Render()
    if failed == 0 and mismatches == 0 then
        Print("Test passed: " .. #items .. " random rolls, everything read correctly. Check the Leaderboard tab.")
    else
        Print(("Test found problems: %d unreadable line(s), %d mismatch(es)."):format(failed, mismatches))
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("START_LOOT_ROLL")
events:RegisterEvent("CHAT_MSG_LOOT")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")

local refreshQueued = false

-- Modern loot-history events. Only used for debug output for now, so we
-- can see in-game whether Forever fires them. pcall: unknown events error.
for _, ev in ipairs({ "LOOT_HISTORY_UPDATE_DROP", "LOOT_HISTORY_UPDATE_ENCOUNTER", "LOOT_ROLLS_COMPLETE" }) do
    pcall(events.RegisterEvent, events, ev)
end

events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then
            DungeonWinnerDB = DungeonWinnerDB or {}
            DungeonWinnerDB.history = DungeonWinnerDB.history or {}
            if DungeonWinnerDB.autoShow == nil then DungeonWinnerDB.autoShow = true end
            DungeonWinnerDB.settings = DungeonWinnerDB.settings or {}
            local st = DungeonWinnerDB.settings
            if st.firstNameOnly == nil then st.firstNameOnly = false end
            if st.useAH == nil then st.useAH = false end
            if st.activeEverywhere == nil then st.activeEverywhere = false end
            if st.theme == nil or not THEMES[st.theme] then st.theme = "minimal" end
            if st.announce67 == nil then st.announce67 = true end
            st.minimap = st.minimap or { angle = 225 }
            if st.showMinimap == nil then st.showMinimap = not st.minimap.hide end
            st.minimap.hide = nil
            playerName = UnitName("player")
            -- Anything left open from last session is finished; fold it away
            for _, item in ipairs(DungeonWinnerDB.history) do
                item.done = true
                item.collapsed = true
            end
            RestoreLayout()
            UpdateMinimapButton()
            ApplyTheme()
            RegisterBlizzardSettings()
        end
    elseif event == "START_LOOT_ROLL" then
        if debugMode then
            Print("START_LOOT_ROLL", ...)
            -- Show how the game names group members, to compare with chat names
            ForEachGroupMember(function(unit)
                Print("  group:", unit, "=", "[" .. tostring(UnitName(unit)) .. "]")
            end)
        end
        OnStartRoll(...)
    elseif event == "CHAT_MSG_LOOT" then
        local msg = ...
        if debugMode and not IsSecret(msg) then Print("CHAT_MSG_LOOT:", msg) end
        OnLootMessage(msg)
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        CheckInstance()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- item prices arrived; refresh once shortly after (this event fires a lot)
        if frame:IsShown() and not refreshQueued then
            refreshQueued = true
            C_Timer.After(0.3, function() refreshQueued = false; Render() end)
        end
    elseif debugMode then
        Print(event, ...)
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_DUNGEONWINNER1 = "/dungeonwinner"
SLASH_DUNGEONWINNER2 = "/dw"
SlashCmdList.DUNGEONWINNER = function(msg)
    local raw = strtrim(msg or "")
    msg = raw:lower()
    local cmd = msg:match("^(%S*)")
    if cmd == "start" then
        local name = raw:match("^%S+%s+(.+)$")
        StartManualRun(name)
        view = "board"
        frame:Show()
        Render()
        return
    elseif cmd == "stop" or cmd == "end" then
        EndManualRun()
        return
    end
    if msg == "clear" then
        ClearRolls()
        Print("Rolls cleared (leaderboards keep their scores).")
    elseif msg == "auto" then
        if blizzSettings.autoShow then
            blizzSettings.autoShow:SetValue(not DungeonWinnerDB.autoShow)
        else
            DungeonWinnerDB.autoShow = not DungeonWinnerDB.autoShow
        end
        Print("Auto-open on new rolls:", DungeonWinnerDB.autoShow and "ON" or "OFF")
    elseif msg == "board" or msg == "leaderboard" then
        view = "board"
        frame:Show()
        Render()
    elseif msg == "settings" or msg == "config" then
        OpenSettings()
    elseif msg == "minimap" then
        local show = not DungeonWinnerDB.settings.showMinimap
        if blizzSettings.showMinimap then
            blizzSettings.showMinimap:SetValue(show) -- keeps the Blizzard panel in sync
        else
            DungeonWinnerDB.settings.showMinimap = show
        end
        UpdateMinimapButton()
        Print("Minimap button:", show and "shown" or "hidden")
    elseif msg == "test" then
        RunTest()
    elseif msg == "67" then
        if not IsDeveloper() then
            Print("That command is for the addon developer only.")
        else
            Announce67()
        end
    elseif msg == "debug" then
        if not IsDeveloper() then
            Print("That command is for the addon developer only.")
        else
            debugMode = not debugMode
            Print("Debug:", debugMode and "ON" or "OFF")
        end
    elseif msg == "help" then
        if IsDeveloper() then
            Print("/dw - toggle window | board | start [name] | stop | settings | test | clear | auto | minimap | dev: debug, 67")
        else
            Print("/dw - toggle window | board | settings | test | clear | auto | minimap")
        end
    else
        frame:SetShown(not frame:IsShown())
    end
end
