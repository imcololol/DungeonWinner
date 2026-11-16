-- DungeonWinner: shows everyone's Need/Greed/Pass choices and roll numbers in one list.
-- Data comes from two places:
--   START_LOOT_ROLL  -> a new item is up for rolls (we pre-fill the group as "pending")
--   CHAT_MSG_LOOT    -> "X has selected Need for: [item]", "Need Roll - 87 for [item] by X", "X won: [item]"
-- Chat lines are matched with patterns built from Blizzard's own global strings,
-- so the addon works in any game language.

local ADDON_NAME = ...
local MAX_HISTORY = 50
local playerName = UnitName("player")
local debugMode = false

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

local function ClassOf(name)
    local _, class = UnitClass(name)
    return class
end

local function ColorName(name, class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return name end
    return ("|cff%02x%02x%02x%s|r"):format(math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255), name)
end

local function ForEachGroupMember(fn)
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

---------------------------------------------------------------------------
-- Turning Blizzard's format strings into Lua patterns
-- e.g. "%s has selected Need for: %s"  ->  "^(.-) has selected Need for: (.-)$"
-- Handles positional tokens like "%2$s" used by some languages.
---------------------------------------------------------------------------

local function BuildPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local order, seq = {}, 0
    local tmp = fmt:gsub("%%(%d*)%$?([sd])", function(pos, kind)
        seq = seq + 1
        order[seq] = tonumber(pos) or seq
        return kind == "d" and "\001" or "\002"
    end)
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
    local pattern, order = BuildPattern(fmt)
    if pattern then
        MESSAGES[#MESSAGES + 1] = {
            key = d[1], kind = d[2], choice = d[3], fields = d[4], self = d[5],
            pattern = pattern, order = order,
        }
    end
end

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

local function HandleMessage(def, f)
    local who = def.self and playerName or CleanName(f.player)
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

    elseif def.kind == "won" then
        local item = FindItem(id, f.item, function(it)
            return it.rolls[who] and it.rolls[who].roll
        end)
        item.winner = who
        item.done = true

    elseif def.kind == "allpassed" then
        local item = FindItem(id, f.item)
        item.allPassed = true
        item.done = true
    end
end

local function OnLootMessage(msg)
    if IsSecret(msg) then
        if debugMode then Print("CHAT_MSG_LOOT text is a secret value here; can't read it.") end
        return
    end
    for _, def in ipairs(MESSAGES) do
        local f = MatchMessage(def, msg)
        if f then
            if debugMode then Print("matched", def.key) end
            HandleMessage(def, f)
            Render()
            return
        end
    end
end

local function OnStartRoll(rollID, rollTime)
    local link = GetLootRollItemLink(rollID)
    local icon, name = GetLootRollItemInfo(rollID)
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

local CHOICE_TEXT = {
    Need     = "|cff1eff00Need|r",
    Greed    = "|cffffd100Greed|r",
    Transmog = "|cffb48cffTransmog|r",
    DE       = "|cff69ccf0DE|r",
    Pass     = "|cff9d9d9dPass|r",
}
local CHOICE_RANK = { Need = 1, Greed = 2, Transmog = 3, DE = 4, Pass = 5 }

local frame = CreateFrame("Frame", "DungeonWinnerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetSize(340, 340)
frame:SetPoint("CENTER")
frame:SetFrameStrata("DIALOG")
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
})
frame:Hide()
tinsert(UISpecialFrames, "DungeonWinnerFrame") -- Esc closes it

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -14)
title:SetText("DungeonWinner")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -4, -4)

local scroll = CreateFrame("ScrollFrame", "DungeonWinnerScroll", frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 14, -40)
scroll:SetPoint("BOTTOMRIGHT", -32, 14)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(290, 1)
scroll:SetScrollChild(content)

local headerPool, rowPool = {}, {}

local function GetHeader(i)
    local h = headerPool[i]
    if not h then
        h = CreateFrame("Button", nil, content)
        h:SetSize(290, 20)
        h.icon = h:CreateTexture(nil, "ARTWORK")
        h.icon:SetSize(18, 18)
        h.icon:SetPoint("LEFT")
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h.text:SetPoint("LEFT", h.icon, "RIGHT", 4, 0)
        h.text:SetPoint("RIGHT")
        h.text:SetJustifyH("LEFT")
        h:SetScript("OnEnter", function(self)
            if self.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.link)
                GameTooltip:Show()
            end
        end)
        h:SetScript("OnLeave", GameTooltip_Hide)
        headerPool[i] = h
    end
    return h
end

local function GetRow(i)
    local r = rowPool[i]
    if not r then
        r = CreateFrame("Frame", nil, content)
        r:SetSize(290, 16)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.name:SetPoint("LEFT", 22, 0)
        r.name:SetWidth(120)
        r.name:SetJustifyH("LEFT")
        r.choice = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.choice:SetPoint("LEFT", r.name, "RIGHT", 4, 0)
        r.choice:SetWidth(60)
        r.choice:SetJustifyH("LEFT")
        r.roll = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.roll:SetPoint("LEFT", r.choice, "RIGHT", 4, 0)
        r.roll:SetWidth(30)
        r.roll:SetJustifyH("RIGHT")
        r.won = r:CreateFontString(nil, "OVERLAY", "GameFontGreenSmall")
        r.won:SetPoint("LEFT", r.roll, "RIGHT", 6, 0)
        rowPool[i] = r
    end
    return r
end

local function SortedNames(item)
    local names = {}
    for n in pairs(item.rolls) do names[#names + 1] = n end
    table.sort(names, function(a, b)
        local ra, rb = item.rolls[a], item.rolls[b]
        local ca, cb = CHOICE_RANK[ra.choice] or 9, CHOICE_RANK[rb.choice] or 9
        if ca ~= cb then return ca < cb end
        local na, nb = ra.roll or -1, rb.roll or -1
        if na ~= nb then return na > nb end
        return a < b
    end)
    return names
end

function Render()
    if not frame:IsShown() then return end
    for _, h in ipairs(headerPool) do h:Hide() end
    for _, r in ipairs(rowPool) do r:Hide() end

    local y, hi, ri = 0, 0, 0
    for _, item in ipairs(DungeonWinnerDB.history) do
        hi = hi + 1
        local h = GetHeader(hi)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        h.icon:SetTexture(item.icon or 134400)
        local status = ""
        if item.allPassed then status = " |cff9d9d9d(all passed)|r"
        elseif not item.done then status = " |cffaaaaaa(rolling...)|r" end
        h.text:SetText((item.link or item.name or "?") .. status)
        h.link = item.link
        h:Show()
        y = y + 22

        for _, name in ipairs(SortedNames(item)) do
            local e = item.rolls[name]
            ri = ri + 1
            local r = GetRow(ri)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            r.name:SetText(ColorName(name, e.class))
            r.choice:SetText(CHOICE_TEXT[e.choice] or "|cff666666...|r")
            r.roll:SetText(e.roll and tostring(e.roll) or "")
            r.won:SetText(item.winner == name and "WON" or "")
            r:Show()
            y = y + 16
        end
        y = y + 8
    end

    if hi == 0 then
        local h = GetHeader(1)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        h.icon:SetTexture(nil)
        h.text:SetText("|cffaaaaaaNo rolls yet. Try /dungeonwinner test|r")
        h.link = nil
        h:Show()
        y = 22
    end
    content:SetHeight(math.max(y, 1))
end

frame:SetScript("OnShow", Render)

---------------------------------------------------------------------------
-- Test data: feeds fake chat lines through the real parser
---------------------------------------------------------------------------

local function RunTest()
    local link = "|cffa335ee|Hitem:19019::::::::60:::::::|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"
    NewItem(link, "Thunderfury", nil)
    frame:Show()
    local lines = {
        LOOT_ROLL_NEED and LOOT_ROLL_NEED:format("Thrall", link),
        LOOT_ROLL_GREED and LOOT_ROLL_GREED:format("Jaina", link),
        LOOT_ROLL_NEED_SELF and LOOT_ROLL_NEED_SELF:format(link),
        LOOT_ROLL_PASSED and LOOT_ROLL_PASSED:format("Sylvanas", link),
        LOOT_ROLL_ROLLED_NEED and LOOT_ROLL_ROLLED_NEED:format(87, link, "Thrall"),
        LOOT_ROLL_ROLLED_NEED and LOOT_ROLL_ROLLED_NEED:format(42, link, playerName),
        LOOT_ROLL_ROLLED_GREED and LOOT_ROLL_ROLLED_GREED:format(99, link, "Jaina"),
        LOOT_ROLL_WON and LOOT_ROLL_WON:format("Thrall", link),
    }
    for _, line in ipairs(lines) do
        if line then OnLootMessage(line) end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("START_LOOT_ROLL")
events:RegisterEvent("CHAT_MSG_LOOT")

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
            playerName = UnitName("player")
        end
    elseif event == "START_LOOT_ROLL" then
        if debugMode then Print("START_LOOT_ROLL", ...) end
        OnStartRoll(...)
    elseif event == "CHAT_MSG_LOOT" then
        local msg = ...
        if debugMode and not IsSecret(msg) then Print("CHAT_MSG_LOOT:", msg) end
        OnLootMessage(msg)
    elseif debugMode then
        Print(event, ...)
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_DUNGEONWINNER1 = "/dungeonwinner"
SLASH_DUNGEONWINNER2 = "/dwin"
SlashCmdList.DUNGEONWINNER = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "clear" then
        wipe(DungeonWinnerDB.history)
        Render()
        Print("History cleared.")
    elseif msg == "auto" then
        DungeonWinnerDB.autoShow = not DungeonWinnerDB.autoShow
        Print("Auto-open on new rolls:", DungeonWinnerDB.autoShow and "ON" or "OFF")
    elseif msg == "test" then
        RunTest()
    elseif msg == "debug" then
        debugMode = not debugMode
        Print("Debug:", debugMode and "ON" or "OFF")
    elseif msg == "help" then
        Print("/dungeonwinner - toggle window | test | clear | auto | debug")
    else
        frame:SetShown(not frame:IsShown())
    end
end
