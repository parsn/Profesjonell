-- SearchWindow.lua
-- Two-pane recipe search/browse window
Profesjonell = Profesjonell or {}

if Profesjonell.Log then
    Profesjonell.Log("SearchWindow.lua loading")
end

local WINDOW_WIDTH = 600
local WINDOW_HEIGHT = 450
local LEFT_PANE_WIDTH = 160
local ROW_HEIGHT = 28
local VISIBLE_ROWS = 13
local FILTER_DEBOUNCE = 0.2

-- State
local searchFrame = nil
local currentTextFilter = ""
local currentCategoryFilter = nil -- nil = all
local filteredRecipes = {}
local filterDirty = false
local filterDirtyTime = 0
local currentTab = "search"      -- "search" | "favorites" | "crafts"
local currentFavGroup = nil      -- nil = first non-empty group
local currentCraftChar = nil     -- nil = all my characters

local TAB_KEYS = { "search", "favorites", "crafts" }
local TAB_LABELS = { "Search", "Favorites", "My Crafts" }

-- Favorites tab groups (key -> label), in display order
local favGroupOrder = { "enhancement", "items", "consumable" }
local favGroupLabels = {
    enhancement = "Item Enhancement",
    items = "Items",
    consumable = "Consumables",
}

-- Category display names (key -> label)
local categoryLabels = {
    enhancement = "Item Enhancement",
    equipment = "Equipment",
    consumable = "Consumable",
    other = "Other",
    favorites = "Favorites",
}

-- Category display order
local categoryOrder = { "enhancement", "equipment", "consumable", "other" }

----------------------------------------------------------------
-- Favorites (stored per account in ProfesjonellConfig.favorites)
-- Maps recipe key -> true. Favorites are personal and never synced.
----------------------------------------------------------------
local FAVORITES_FILTER = "favorites"

local function GetFavoritesTable()
    if not ProfesjonellConfig then ProfesjonellConfig = {} end
    if not ProfesjonellConfig.favorites then ProfesjonellConfig.favorites = {} end
    return ProfesjonellConfig.favorites
end

function Profesjonell.IsFavorite(key)
    if not key or not ProfesjonellConfig or not ProfesjonellConfig.favorites then return false end
    return ProfesjonellConfig.favorites[key] == true
end

function Profesjonell.SetFavorite(key, isFav)
    if not key then return end
    local favs = GetFavoritesTable()
    if isFav then
        favs[key] = true
    else
        favs[key] = nil
    end
end

function Profesjonell.ToggleFavorite(key)
    local newState = not Profesjonell.IsFavorite(key)
    Profesjonell.SetFavorite(key, newState)
    return newState
end

local RARITY_COLORS = {
    [0] = {r = 0.62, g = 0.62, b = 0.62}, -- Poor (gray)
    [1] = {r = 1.00, g = 1.00, b = 1.00}, -- Common (white)
    [2] = {r = 0.12, g = 1.00, b = 0.00}, -- Uncommon (green)
    [3] = {r = 0.00, g = 0.44, b = 0.87}, -- Rare (blue)
    [4] = {r = 0.64, g = 0.21, b = 0.93}, -- Epic (purple)
    [5] = {r = 1.00, g = 0.50, b = 0.00}, -- Legendary (orange)
}

----------------------------------------------------------------
-- Item Type Name Rules (extensible)
-- Each rule: { pattern = <lua pattern>, category = <string> }
-- Rules are checked in order; first match wins.
----------------------------------------------------------------
Profesjonell.ItemTypeNameRules = {
    -- Item Enhancement: Enchant <Slot> patterns
    { pattern = "^Enchant Boots", category = "enhancement" },
    { pattern = "^Enchant Bracer", category = "enhancement" },
    { pattern = "^Enchant Chest", category = "enhancement" },
    { pattern = "^Enchant Cloak", category = "enhancement" },
    { pattern = "^Enchant Gloves", category = "enhancement" },
    { pattern = "^Enchant Shield", category = "enhancement" },
    { pattern = "^Enchant Weapon", category = "enhancement" },
    { pattern = "^Enchant 2H Weapon", category = "enhancement" },
    -- Belt Buckle, Shield Spike, Sharpening Stone, Weightstone, Grinding Stone, Gemstone, Scope, Accurascope
    { pattern = "Belt Buckle$", category = "enhancement" },
    { pattern = "Shield Spike$", category = "enhancement" },
    { pattern = "Gemstone$", category = "enhancement" },
    { pattern = "Moonstone$", category = "enhancement" },
    { pattern = "Scope$", category = "enhancement" },
    { pattern = "Accurascope$", category = "enhancement" },
    -- Oils
    { pattern = "Wizard Oil$", category = "consumable" },
    { pattern = "Mana Oil$", category = "consumable" },
    { pattern = "^Frost Oil$", category = "consumable" },
    { pattern = "^Shadow Oil$", category = "consumable" },
    -- Consumable: name-based patterns
    { pattern = "Weightstone$", category = "consumable" },
    { pattern = "Grinding Stone$", category = "consumable" },
    { pattern = "Sharpening Stone$", category = "consumable" },
    { pattern = "^Elixir of ", category = "consumable" },
    { pattern = "^Flask of ", category = "consumable" },
    { pattern = "Potion$", category = "consumable" },
    { pattern = "^Major .+ Potion", category = "consumable" },
    { pattern = "^Minor .+ Potion", category = "consumable" },
    { pattern = "^Greater .+ Potion", category = "consumable" },
    { pattern = "^Super .+ Potion", category = "consumable" },
    { pattern = "^Free Action Potion$", category = "consumable" },
    { pattern = "^Living Action Potion$", category = "consumable" },
    { pattern = "^Limited Invulnerability Potion$", category = "consumable" },
    { pattern = "Elixir$", category = "consumable" },
    { pattern = "Flask$", category = "consumable" },
}

-- Infer item type category from recipe name using the rules table
function Profesjonell.InferCategoryFromName(name)
    if not name then return nil end
    for _, rule in ipairs(Profesjonell.ItemTypeNameRules) do
        if string.find(name, rule.pattern) then
            return rule.category
        end
    end
    return nil
end

----------------------------------------------------------------
-- Item Type Cache (name + tooltip scanned)
-- Maps recipe key -> category string
----------------------------------------------------------------
local itemTypeCache = {}  -- key -> category
local itemTypeCacheReady = false
local itemTypeCacheScanning = false
local itemTypeRescanTime = 0  -- next time to re-scan uncategorized items
local RESCAN_INTERVAL = 2     -- seconds between re-scan attempts

-- Equipment slot strings that appear in item tooltips
local equipmentSlots = {
    ["Head"] = true,
    ["Neck"] = true,
    ["Shoulder"] = true,
    ["Back"] = true,
    ["Chest"] = true,
    ["Shirt"] = true,
    ["Tabard"] = true,
    ["Wrist"] = true,
    ["Hands"] = true,
    ["Waist"] = true,
    ["Legs"] = true,
    ["Feet"] = true,
    ["Finger"] = true,
    ["Trinket"] = true,
    ["Main Hand"] = true,
    ["Off Hand"] = true,
    ["One-Hand"] = true,
    ["Two-Hand"] = true,
    ["Ranged"] = true,
    ["Gun"] = true,
    ["Bow"] = true,
    ["Crossbow"] = true,
    ["Wand"] = true,
    ["Thrown"] = true,
    ["Shield"] = true,
    ["Relic"] = true,
    ["Held In Off-hand"] = true,
    ["Held In Off-Hand"] = true,
}

-- Read item type from a tooltip by scanning its lines
-- Returns "equipment" if an equip slot is found, "consumable" if "Use:" is found, nil otherwise
function Profesjonell.ReadItemTypeFromTooltip(tooltipFrame)
    if not tooltipFrame or not tooltipFrame.NumLines then return nil end
    local numLines = tooltipFrame:NumLines() or 0
    local tooltipName = tooltipFrame:GetName()
    if not tooltipName then return nil end

    local hasUse = false
    for i = 1, numLines do
        local textObj = _G[tooltipName .. "TextLeft" .. i]
        if textObj then
            local text = textObj:GetText()
            if text then
                -- Check for equipment slot (usually line 2-3 of tooltip)
                if equipmentSlots[text] then
                    return "equipment"
                end
                -- Check for "Use:" line (consumable indicator)
                if string.find(text, "^Use:") then
                    hasUse = true
                end
            end
        end
    end

    if hasUse then
        return "consumable"
    end

    return nil
end

-- Scan all recipe keys and build the item type cache
-- Uses name rules first, then tooltip scanning for remaining items
-- Calls onProgress(current, total) and onComplete() callbacks
function Profesjonell.BuildItemTypeCache(onProgress, onComplete)
    if itemTypeCacheScanning then return end
    itemTypeCacheScanning = true
    itemTypeCache = {}
    itemTypeCacheReady = false

    -- Collect all keys to scan
    local keys = {}
    if ProfesjonellDB then
        for rKey in pairs(ProfesjonellDB) do
            table.insert(keys, rKey)
        end
    end

    local total = table.getn(keys)
    if total == 0 then
        itemTypeCacheReady = true
        itemTypeCacheScanning = false
        if onComplete then onComplete() end
        return
    end

    -- First apply name-based rules
    local needsTooltip = {}
    for _, rKey in ipairs(keys) do
        local recipeName = Profesjonell.GetNameFromKey(rKey)
        if recipeName then
            local cleanName = Profesjonell.StripPrefix(recipeName)
            local inferred = Profesjonell.InferCategoryFromName(cleanName)
            if inferred then
                itemTypeCache[rKey] = inferred
            end
        end
        -- If still unknown, queue for tooltip scan (skip enchant keys)
        if not itemTypeCache[rKey] then
            local _, _, linkType = string.find(rKey, "([^:]+):")
            if linkType ~= "e" then
                table.insert(needsTooltip, rKey)
            end
        end
    end

    local tooltipTotal = table.getn(needsTooltip)
    if tooltipTotal == 0 then
        itemTypeCacheReady = true
        itemTypeCacheScanning = false
        if onProgress then onProgress(total, total) end
        if onComplete then onComplete() end
        return
    end

    -- Create hidden tooltip for scanning
    local scanTooltip = Profesjonell.GetScanTooltip and Profesjonell.GetScanTooltip()
    if not scanTooltip then
        scanTooltip = CreateFrame("GameTooltip", "ProfesjonellTypeScanTooltip", nil, "GameTooltipTemplate")
        scanTooltip:SetOwner(UIParent or CreateFrame("Frame"), "ANCHOR_NONE")
    end

    -- Process in batches
    local scanIndex = 0
    local batchSize = 10
    local alreadyDone = total - tooltipTotal

    local function ProcessBatch()
        local batchEnd = math.min(scanIndex + batchSize, tooltipTotal)
        for idx = scanIndex + 1, batchEnd do
            local rKey = needsTooltip[idx]
            local _, _, linkType, linkId = string.find(rKey, "([^:]+):(%d+)")
            if linkType and linkId then
                local hyperlink
                if linkType == "i" then
                    hyperlink = "item:" .. linkId .. ":0:0:0"
                elseif linkType == "s" then
                    hyperlink = "spell:" .. linkId
                else
                    hyperlink = linkType .. ":" .. linkId
                end
                scanTooltip:ClearLines()
                scanTooltip:SetOwner(UIParent or CreateFrame("Frame"), "ANCHOR_NONE")
                local ok = pcall(function()
                    scanTooltip:SetHyperlink(hyperlink)
                end)
                if ok then
                    local itemType = Profesjonell.ReadItemTypeFromTooltip(scanTooltip)
                    if itemType then
                        itemTypeCache[rKey] = itemType
                    end
                end
            end
        end
        scanIndex = batchEnd
        if onProgress then onProgress(alreadyDone + scanIndex, total) end

        if scanIndex >= tooltipTotal then
            itemTypeCacheReady = true
            itemTypeCacheScanning = false
            if onComplete then onComplete() end
            return true -- done
        end
        return false -- more to do
    end

    while not ProcessBatch() do end
end

-- Get item type category for a recipe key from the cache
function Profesjonell.GetRecipeCategory(key)
    return itemTypeCache[key] or nil
end

-- Re-scan uncategorized items whose tooltips may now be available
-- Returns true if any new categories were resolved
function Profesjonell.RescanUncategorizedItems()
    if not ProfesjonellDB or not itemTypeCacheReady then return false end

    local scanTooltip = Profesjonell.GetScanTooltip and Profesjonell.GetScanTooltip()
    if not scanTooltip then
        scanTooltip = CreateFrame("GameTooltip", "ProfesjonellTypeScanTooltip", nil, "GameTooltipTemplate")
        scanTooltip:SetOwner(UIParent or CreateFrame("Frame"), "ANCHOR_NONE")
    end

    local changed = false
    for rKey in pairs(ProfesjonellDB) do
        if not itemTypeCache[rKey] then
            -- Try name rules first
            local recipeName = Profesjonell.GetNameFromKey(rKey)
            if recipeName then
                local cleanName = Profesjonell.StripPrefix(recipeName)
                local inferred = Profesjonell.InferCategoryFromName(cleanName)
                if inferred then
                    itemTypeCache[rKey] = inferred
                    changed = true
                end
            end
            -- Try tooltip scan for non-enchant keys
            if not itemTypeCache[rKey] then
                local _, _, linkType, linkId = string.find(rKey, "([^:]+):(%d+)")
                if linkType and linkId and linkType ~= "e" then
                    local hyperlink
                    if linkType == "i" then
                        hyperlink = "item:" .. linkId .. ":0:0:0"
                    elseif linkType == "s" then
                        hyperlink = "spell:" .. linkId
                    else
                        hyperlink = linkType .. ":" .. linkId
                    end
                    scanTooltip:ClearLines()
                    scanTooltip:SetOwner(UIParent or CreateFrame("Frame"), "ANCHOR_NONE")
                    local ok = pcall(function()
                        scanTooltip:SetHyperlink(hyperlink)
                    end)
                    if ok then
                        local itemType = Profesjonell.ReadItemTypeFromTooltip(scanTooltip)
                        if itemType then
                            itemTypeCache[rKey] = itemType
                            changed = true
                        end
                    end
                end
            end
        end
    end
    return changed
end

-- Invalidate the item type cache (e.g. when DB changes)
function Profesjonell.InvalidateItemTypeCache()
    itemTypeCache = {}
    itemTypeCacheReady = false
    itemTypeCacheScanning = false
end

-- Wrap the existing InvalidateProfessionCache (from Professions.lua) so that
-- Database.lua's call also clears the item-type cache used by the search window.
do
    local origInvalidate = Profesjonell.InvalidateProfessionCache
    Profesjonell.InvalidateProfessionCache = function()
        if origInvalidate then origInvalidate() end
        Profesjonell.InvalidateItemTypeCache()
    end
end

-- Check if item type cache is ready
function Profesjonell.IsItemTypeCacheReady()
    return itemTypeCacheReady
end

-- Get rarity color from a link's embedded color code
local function GetRarityFromLink(link)
    if not link then return 1 end
    local _, _, hex = string.find(link, "|c(%x%x%x%x%x%x%x%x)")
    if not hex then return 1 end
    if hex == "ff9d9d9d" then return 0 end
    if hex == "ffffffff" then return 1 end
    if hex == "ff1eff00" then return 2 end
    if hex == "ff0070dd" then return 3 end
    if hex == "ffa335ee" then return 4 end
    if hex == "ffff8000" then return 5 end
    return 1
end

-- Build the filtered recipe list
function Profesjonell.GetFilteredRecipes(textFilter, categoryFilter)
    if not ProfesjonellDB then return {} end

    local rosterReady = false
    if Profesjonell.UpdateGuildRosterCache then
        rosterReady = Profesjonell.UpdateGuildRosterCache()
    end

    local textLower = textFilter and string.lower(textFilter) or ""
    local words = {}
    if textLower ~= "" then
        local gfindFunc = string.gfind or string.gmatch
        for word in gfindFunc(textLower, "%S+") do
            table.insert(words, word)
        end
    end

    local results = {}
    for rKey, holders in pairs(ProfesjonellDB) do
        local name = Profesjonell.GetNameFromKey(rKey)
        if not name or string.find(name, "^Unknown") then
            -- skip unresolved
        else
            local cleanName = Profesjonell.StripPrefix(name)
            local lowerName = string.lower(cleanName)
            local link = Profesjonell.GetLinkFromKey(rKey)
            local category = Profesjonell.GetRecipeCategory(rKey)

            -- Category filter
            local catMatch = true
            if categoryFilter == FAVORITES_FILTER then
                catMatch = Profesjonell.IsFavorite(rKey)
            elseif categoryFilter == "other" then
                catMatch = (category == nil)
            elseif categoryFilter then
                catMatch = (category == categoryFilter)
            end

            if catMatch then
                -- Collect holders
                local holderList = {}
                for charName in pairs(holders) do
                    if not rosterReady or (Profesjonell.GuildRosterCache and Profesjonell.GuildRosterCache[charName]) then
                        table.insert(holderList, charName)
                    end
                end
                table.sort(holderList)

                -- Text filter: match against recipe name and holder names
                local textMatch = true
                if table.getn(words) > 0 then
                    local searchStr = lowerName
                    for _, h in ipairs(holderList) do
                        searchStr = searchStr .. " " .. string.lower(h)
                    end
                    for _, word in ipairs(words) do
                        if not string.find(searchStr, word, 1, true) then
                            textMatch = false
                            break
                        end
                    end
                end

                if textMatch and table.getn(holderList) > 0 then
                    table.insert(results, {
                        key = rKey,
                        name = cleanName,
                        link = link,
                        holders = holderList,
                        category = category,
                        favorite = Profesjonell.IsFavorite(rKey),
                        rarity = link and GetRarityFromLink(link) or 1,
                    })
                end
            end
        end
    end

    -- Sort alphabetically by name
    table.sort(results, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    return results
end

----------------------------------------------------------------
-- Favorites tab helpers
----------------------------------------------------------------

-- Map a recipe category to a Favorites-tab group
function Profesjonell.GetFavoriteGroup(category)
    if category == "enhancement" then return "enhancement" end
    if category == "consumable" then return "consumable" end
    return "items"
end

function Profesjonell.CountFavorites()
    local n = 0
    if ProfesjonellConfig and ProfesjonellConfig.favorites then
        for _ in pairs(ProfesjonellConfig.favorites) do n = n + 1 end
    end
    return n
end

----------------------------------------------------------------
-- My Crafts: user-managed list of characters (may be on other accounts)
-- Stored in ProfesjonellConfig.myCharacters (ordered list of names)
----------------------------------------------------------------
local function NormalizeCharName(name)
    if not name then return nil end
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    if name == "" then return nil end
    return string.upper(string.sub(name, 1, 1)) .. string.lower(string.sub(name, 2))
end

function Profesjonell.GetMyCharacters()
    if not ProfesjonellConfig then ProfesjonellConfig = {} end
    if not ProfesjonellConfig.myCharacters then
        ProfesjonellConfig.myCharacters = {}
        -- Seed with the current character the first time
        local me = UnitName and UnitName("player")
        if me and me ~= "" then
            table.insert(ProfesjonellConfig.myCharacters, me)
        end
    end
    return ProfesjonellConfig.myCharacters
end

-- Returns ok, name. ok=false with a name means it already existed.
function Profesjonell.AddMyCharacter(name)
    local norm = NormalizeCharName(name)
    if not norm then return false, nil end
    local list = Profesjonell.GetMyCharacters()
    for _, existing in ipairs(list) do
        if string.lower(existing) == string.lower(norm) then
            return false, existing
        end
    end
    table.insert(list, norm)
    return true, norm
end

function Profesjonell.RemoveMyCharacter(name)
    if not name then return false end
    local list = Profesjonell.GetMyCharacters()
    for i, existing in ipairs(list) do
        if string.lower(existing) == string.lower(name) then
            table.remove(list, i)
            return true
        end
    end
    return false
end

-- Recipes known by "my" characters.
-- Returns results (same shape as GetFilteredRecipes, holders = my characters
-- that know it, detailHolders = all guild holders) and counts[charName].
-- charFilter (optional): only include recipes known by that character.
function Profesjonell.GetCharacterRecipes(textFilter, charFilter)
    local results, counts = {}, {}
    if not ProfesjonellDB then return results, counts end
    local chars = Profesjonell.GetMyCharacters()
    if table.getn(chars) == 0 then return results, counts end

    local mine = {}
    for _, c in ipairs(chars) do mine[string.lower(c)] = c end
    local filterLower = charFilter and string.lower(charFilter) or nil

    local rosterReady = false
    if Profesjonell.UpdateGuildRosterCache then
        rosterReady = Profesjonell.UpdateGuildRosterCache()
    end

    local words = {}
    local textLower = textFilter and string.lower(textFilter) or ""
    if textLower ~= "" then
        local gfindFunc = string.gfind or string.gmatch
        for word in gfindFunc(textLower, "%S+") do
            table.insert(words, word)
        end
    end

    for rKey, holders in pairs(ProfesjonellDB) do
        local name = Profesjonell.GetNameFromKey(rKey)
        if name and not string.find(name, "^Unknown") then
            local myHolders = {}
            for charName in pairs(holders) do
                local canonical = mine[string.lower(charName)]
                if canonical then table.insert(myHolders, canonical) end
            end
            if table.getn(myHolders) > 0 then
                table.sort(myHolders)
                local cleanName = Profesjonell.StripPrefix(name)
                local searchStr = string.lower(cleanName)
                for _, h in ipairs(myHolders) do
                    searchStr = searchStr .. " " .. string.lower(h)
                end
                local textMatch = true
                for _, word in ipairs(words) do
                    if not string.find(searchStr, word, 1, true) then
                        textMatch = false
                        break
                    end
                end
                if textMatch then
                    local hasFiltered = false
                    for _, h in ipairs(myHolders) do
                        counts[h] = (counts[h] or 0) + 1
                        if filterLower and string.lower(h) == filterLower then
                            hasFiltered = true
                        end
                    end
                    if not filterLower or hasFiltered then
                        local detail = {}
                        for charName in pairs(holders) do
                            if not rosterReady or (Profesjonell.GuildRosterCache and Profesjonell.GuildRosterCache[charName]) then
                                table.insert(detail, charName)
                            end
                        end
                        if table.getn(detail) == 0 then detail = myHolders end
                        table.sort(detail)
                        local link = Profesjonell.GetLinkFromKey(rKey)
                        table.insert(results, {
                            key = rKey,
                            name = cleanName,
                            link = link,
                            holders = myHolders,
                            detailHolders = detail,
                            category = Profesjonell.GetRecipeCategory(rKey),
                            favorite = Profesjonell.IsFavorite(rKey),
                            rarity = link and GetRarityFromLink(link) or 1,
                        })
                    end
                end
            end
        end
    end

    table.sort(results, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)
    return results, counts
end

-- Count recipes per category from a recipe list
local function CountByCategory(recipes)
    local counts = {}
    for _, r in ipairs(recipes) do
        local cat = r.category or "other"
        counts[cat] = (counts[cat] or 0) + 1
        if r.favorite then
            counts[FAVORITES_FILTER] = (counts[FAVORITES_FILTER] or 0) + 1
        end
    end
    return counts
end

-- Get ordered list of categories present in the data
local function GetCategoryList(counts)
    local list = {}
    for _, cat in ipairs(categoryOrder) do
        if counts[cat] and counts[cat] > 0 then
            table.insert(list, cat)
        end
    end
    return list
end

-- Build "Known by" text for a recipe entry (for the row subtitle)
local function BuildHolderText(holders)
    if not holders or table.getn(holders) == 0 then return "" end
    local count = table.getn(holders)
    if count > 5 then
        local shown = {}
        for i = 1, 5 do
            table.insert(shown, holders[i])
        end
        return table.concat(Profesjonell.ColorizeList(shown), ", ") .. " (+" .. (count - 5) .. " more)"
    end
    return table.concat(Profesjonell.ColorizeList(holders), ", ")
end

-- Get icon texture for a recipe key
local function GetRecipeIcon(key, category)
    if not key then return nil end
    local _, _, keyType, id = string.find(key, "([^:]+):(%d+)")
    if not keyType or not id then return nil end
    -- Spell keys (s:) have no item icon, use enchanting icon
    if keyType == "s" then
        return "Interface\\Icons\\Trade_Engraving"
    end
    if keyType == "i" then
        local _, _, _, _, _, _, _, _, texture = GetItemInfo(id)
        return texture
    end
    return nil
end

----------------------------------------------------------------
-- UI Creation
----------------------------------------------------------------

local function CreateSearchWindow()
    if searchFrame then return searchFrame end

    -- Main frame
    local f = CreateFrame("Frame", "ProfesjonellSearchFrame", UIParent)
    f:SetWidth(WINDOW_WIDTH)
    f:SetHeight(WINDOW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetBackdropColor(0, 0, 0, 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetFrameStrata("HIGH")
    f:Hide()

    -- Register for Escape to close
    tinsert(UISpecialFrames, "ProfesjonellSearchFrame")

    -- Title icon
    local titleIcon = f:CreateTexture(nil, "ARTWORK")
    titleIcon:SetWidth(16)
    titleIcon:SetHeight(16)
    titleIcon:SetTexture("Interface\\Icons\\ability_hunter_aspectofthemonkey")
    titleIcon:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -14)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titleIcon, "RIGHT", 5, 0)
    title:SetText("Profesjonell - Guild Recipes")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)

    -- Filter edit box
    local editBox = CreateFrame("EditBox", "ProfesjonellSearchEditBox", f, "InputBoxTemplate")
    editBox:SetWidth(WINDOW_WIDTH - LEFT_PANE_WIDTH - 80)
    editBox:SetHeight(20)
    editBox:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT_PANE_WIDTH + 24, -36)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnTextChanged", function()
        local text = editBox:GetText() or ""
        if text ~= currentTextFilter then
            currentTextFilter = text
            filterDirty = true
            filterDirtyTime = GetTime() + FILTER_DEBOUNCE
        end
    end)
    editBox:SetScript("OnEscapePressed", function()
        editBox:ClearFocus()
    end)
    editBox:SetScript("OnEnterPressed", function()
        editBox:ClearFocus()
    end)
    f.editBox = editBox

    -- Clear filter button
    local clearBtn = CreateFrame("Button", nil, f)
    clearBtn:SetWidth(18)
    clearBtn:SetHeight(18)
    clearBtn:SetPoint("LEFT", editBox, "RIGHT", 2, 0)
    clearBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    clearBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    clearBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    clearBtn:SetScript("OnClick", function()
        editBox:SetText("")
        editBox:ClearFocus()
        currentTextFilter = ""
        Profesjonell.RefreshSearchWindow()
    end)
    clearBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(clearBtn, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clear filter")
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    f.clearBtn = clearBtn

    -- Filter label
    local filterLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("RIGHT", editBox, "LEFT", -4, 0)
    filterLabel:SetText("Filter:")

    -- Left pane (category list)
    local leftPane = CreateFrame("Frame", nil, f)
    leftPane:SetWidth(LEFT_PANE_WIDTH)
    leftPane:SetHeight(WINDOW_HEIGHT - 60)
    leftPane:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -56)
    f.leftPane = leftPane

    -- Separator line
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetWidth(1)
    sep:SetHeight(WINDOW_HEIGHT - 70)
    sep:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 4, 0)
    sep:SetTexture(0.4, 0.4, 0.4, 0.8)

    -- Left-pane buttons (created dynamically)
    f.catButtons = {}

    -- "Add character" controls (My Crafts tab only)
    local function AddCharacterFromBox()
        local box = f.addBox
        local ok, result = Profesjonell.AddMyCharacter(box:GetText())
        if result then
            currentCraftChar = result
            box:SetText("")
        end
        box:ClearFocus()
        Profesjonell.RefreshSearchWindow()
    end

    local addBox = CreateFrame("EditBox", "ProfesjonellAddCharEditBox", f, "InputBoxTemplate")
    addBox:SetWidth(94)
    addBox:SetHeight(20)
    addBox:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 8, -2)
    addBox:SetAutoFocus(false)
    addBox:SetMaxLetters(12)
    addBox:SetScript("OnEnterPressed", AddCharacterFromBox)
    addBox:SetScript("OnEscapePressed", function() addBox:ClearFocus() end)
    addBox:Hide()
    f.addBox = addBox

    local addBtn = CreateFrame("Button", "ProfesjonellAddCharButton", f, "UIPanelButtonTemplate")
    addBtn:SetWidth(46)
    addBtn:SetHeight(22)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 4, 0)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", AddCharacterFromBox)
    addBtn:Hide()
    f.addBtn = addBtn

    -- Tabs along the bottom edge
    f.tabs = {}
    for i = 1, 3 do
        local idx = i
        local tab = CreateFrame("Button", "ProfesjonellSearchFrameTab" .. idx, f, "CharacterFrameTabButtonTemplate")
        tab:SetID(idx)
        tab:SetText(TAB_LABELS[idx])
        if idx == 1 then
            tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 15, 7)
        else
            tab:SetPoint("LEFT", f.tabs[idx - 1], "RIGHT", -14, 0)
        end
        tab:SetScript("OnClick", function()
            Profesjonell.SetSearchTab(TAB_KEYS[idx])
        end)
        if PanelTemplates_TabResize then
            pcall(PanelTemplates_TabResize, 0, tab)
        end
        f.tabs[idx] = tab
    end
    if PanelTemplates_SetNumTabs then
        pcall(PanelTemplates_SetNumTabs, f, 3)
    end

    -- Message shown when the list is empty
    local emptyText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("TOP", f, "TOPLEFT", LEFT_PANE_WIDTH + 20 + (WINDOW_WIDTH - LEFT_PANE_WIDTH - 50) / 2, -140)
    emptyText:SetWidth(WINDOW_WIDTH - LEFT_PANE_WIDTH - 90)
    emptyText:SetJustifyH("CENTER")
    emptyText:SetTextColor(0.6, 0.6, 0.6)
    emptyText:Hide()
    f.emptyText = emptyText

    -- Right pane with FauxScrollFrame
    local scrollFrame = CreateFrame("ScrollFrame", "ProfesjonellSearchScrollFrame", f, "FauxScrollFrameTemplate")
    scrollFrame:SetWidth(WINDOW_WIDTH - LEFT_PANE_WIDTH - 50)
    scrollFrame:SetHeight(ROW_HEIGHT * VISIBLE_ROWS)
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT_PANE_WIDTH + 20, -60)
    f.scrollFrame = scrollFrame

    -- Create row buttons
    f.rows = {}
    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Button", "ProfesjonellSearchRow" .. i, f)
        row:SetWidth(WINDOW_WIDTH - LEFT_PANE_WIDTH - 55)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))

        -- Highlight texture
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints(row)
        highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        highlight:SetBlendMode("ADD")
        highlight:SetAlpha(0.3)

        -- Icon
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(18)
        icon:SetHeight(18)
        icon:SetPoint("LEFT", row, "LEFT", 2, 0)
        row.icon = icon

        -- Recipe name
        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 4, 0)
        nameText:SetPoint("RIGHT", row, "RIGHT", -24, 0)
        nameText:SetJustifyH("LEFT")
        row.nameText = nameText

        -- Known by line
        local holderText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        holderText:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 4, -4)
        holderText:SetPoint("RIGHT", row, "RIGHT", -24, 0)
        holderText:SetJustifyH("LEFT")
        holderText:SetTextColor(0.7, 0.7, 0.7)
        row.holderText = holderText

        row.recipeData = nil

        -- Favorite star button (right side of the row)
        local starBtn = CreateFrame("Button", nil, row)
        starBtn:SetWidth(16)
        starBtn:SetHeight(16)
        starBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        local starTex = starBtn:CreateTexture(nil, "ARTWORK")
        starTex:SetAllPoints(starBtn)
        starTex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
        starBtn.tex = starTex
        local starHl = starBtn:CreateTexture(nil, "HIGHLIGHT")
        starHl:SetAllPoints(starBtn)
        starHl:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
        starHl:SetBlendMode("ADD")
        starHl:SetAlpha(0.4)
        starBtn:SetScript("OnClick", function()
            local data = row.recipeData
            if not data then return end
            Profesjonell.ToggleFavorite(data.key)
            Profesjonell.RefreshSearchWindow()
        end)
        starBtn:SetScript("OnEnter", function()
            local data = row.recipeData
            GameTooltip:SetOwner(starBtn, "ANCHOR_RIGHT")
            if data and data.favorite then
                GameTooltip:SetText("Remove from favorites (Alt-click)")
            else
                GameTooltip:SetText("Add to favorites (Alt-click)")
            end
            GameTooltip:Show()
        end)
        starBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        row.starBtn = starBtn

        -- Tooltip on hover (use enchant: for spell keys to show crafting tooltip)
        row:SetScript("OnEnter", function()
            local data = row.recipeData
            if data and data.key then
                local _, _, linkType, linkId = string.find(data.key, "([^:]+):(%d+)")
                if linkType and linkId then
                    local hyperlink
                    if linkType == "s" then
                        hyperlink = "enchant:" .. linkId
                    elseif linkType == "i" then
                        hyperlink = "item:" .. linkId .. ":0:0:0"
                    else
                        hyperlink = linkType .. ":" .. linkId
                    end
                    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                    local ok = pcall(function()
                        GameTooltip:SetHyperlink(hyperlink)
                    end)
                    if ok then
                        GameTooltip:Show()
                    end
                end
            end
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        -- Click to show detail, Shift-click to link in chat
        row:SetScript("OnClick", function()
            local data = row.recipeData
            if not data then return end
            if IsAltKeyDown() then
                -- Alt-click toggles favorite
                Profesjonell.ToggleFavorite(data.key)
                Profesjonell.RefreshSearchWindow()
                return
            end
            if data.link and IsShiftKeyDown() then
                if ChatFrameEditBox and ChatFrameEditBox:IsVisible() then
                    ChatFrameEditBox:Insert(data.link)
                elseif ChatEdit_InsertLink then
                    ChatEdit_InsertLink(data.link)
                end
            else
                Profesjonell.ShowRecipeDetail(data)
            end
        end)

        f.rows[i] = row
    end

    scrollFrame:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(ROW_HEIGHT, function()
            Profesjonell.UpdateSearchWindowScroll()
        end)
    end)

    -- OnUpdate for filter debounce and periodic re-scan of uncategorized items
    f:SetScript("OnUpdate", function()
        if filterDirty and GetTime() >= filterDirtyTime then
            filterDirty = false
            Profesjonell.RefreshSearchWindow()
        end
        -- Periodically re-scan uncategorized items (tooltips may have loaded)
        local now = GetTime()
        if itemTypeCacheReady and now >= itemTypeRescanTime then
            itemTypeRescanTime = now + RESCAN_INTERVAL
            if Profesjonell.RescanUncategorizedItems() then
                Profesjonell.RefreshSearchWindow()
            end
        end
    end)

    searchFrame = f
    return f
end

-- Update the scroll display
function Profesjonell.UpdateSearchWindowScroll()
    if not searchFrame then return end

    local totalRecipes = table.getn(filteredRecipes)
    FauxScrollFrame_Update(searchFrame.scrollFrame, totalRecipes, VISIBLE_ROWS, ROW_HEIGHT)

    local offset = FauxScrollFrame_GetOffset(searchFrame.scrollFrame)

    for i = 1, VISIBLE_ROWS do
        local row = searchFrame.rows[i]
        local index = offset + i
        if index <= totalRecipes then
            local data = filteredRecipes[index]
            row.recipeData = data

            -- Set name with rarity color
            local color = RARITY_COLORS[data.rarity] or RARITY_COLORS[1]
            row.nameText:SetTextColor(color.r, color.g, color.b)
            row.nameText:SetText(data.name)

            -- Set holder text
            row.holderText:SetText(BuildHolderText(data.holders))

            -- Set favorite star (bright = favorite, dim gray = not)
            if data.favorite then
                row.starBtn.tex:SetVertexColor(1, 1, 1)
                row.starBtn.tex:SetAlpha(1)
            else
                row.starBtn.tex:SetVertexColor(0.5, 0.5, 0.5)
                row.starBtn.tex:SetAlpha(0.35)
            end

            -- Set icon
            local iconTexture = GetRecipeIcon(data.key, data.category)
            if iconTexture then
                row.icon:SetTexture(iconTexture)
                row.icon:Show()
            else
                row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                row.icon:Show()
            end

            row:Show()
        else
            row.recipeData = nil
            row:Hide()
        end
    end
end

-- Create a left-pane entry button (with an optional remove "x")
local function CreateLeftButton()
    local btn = CreateFrame("Button", nil, searchFrame.leftPane)
    btn:SetWidth(LEFT_PANE_WIDTH - 4)
    btn:SetHeight(18)
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", btn, "LEFT", 4, 0)
    text:SetJustifyH("LEFT")
    btn.text = text
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(btn)
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.3)

    local rb = CreateFrame("Button", nil, btn)
    rb:SetWidth(14)
    rb:SetHeight(14)
    rb:SetPoint("RIGHT", btn, "RIGHT", -1, 0)
    local rt = rb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rt:SetPoint("CENTER", rb, "CENTER", 0, 0)
    rt:SetText("x")
    rt:SetTextColor(0.9, 0.2, 0.2)
    rb:SetScript("OnEnter", function()
        rt:SetTextColor(1, 0.6, 0.6)
        GameTooltip:SetOwner(rb, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove character")
        GameTooltip:Show()
    end)
    rb:SetScript("OnLeave", function()
        rt:SetTextColor(0.9, 0.2, 0.2)
        GameTooltip:Hide()
    end)
    rb:Hide()
    btn.removeBtn = rb
    return btn
end

-- Fill the left pane with entries: { label, selected, onClick, onRemove }
local function RefreshLeftPane(entries, startY)
    if not searchFrame then return end
    local btns = searchFrame.catButtons
    for _, b in ipairs(btns) do b:Hide() end

    local y = startY or 0
    for i, e in ipairs(entries) do
        local btn = btns[i]
        if not btn then
            btn = CreateLeftButton()
            btns[i] = btn
        end
        btn:SetPoint("TOPLEFT", searchFrame.leftPane, "TOPLEFT", 0, -y)
        local label = e.label
        if e.selected then
            btn.text:SetTextColor(1, 0.82, 0)
            label = "> " .. label
        else
            btn.text:SetTextColor(1, 1, 1)
        end
        btn.text:SetText(label)
        btn.text:SetPoint("RIGHT", btn, "RIGHT", e.onRemove and -16 or -2, 0)
        btn:SetScript("OnClick", e.onClick)
        if e.onRemove then
            btn.removeBtn:SetScript("OnClick", e.onRemove)
            btn.removeBtn:Show()
        else
            btn.removeBtn:Hide()
        end
        btn:Show()
        y = y + 18
    end
end

local function SetEmptyText(text)
    if not searchFrame or not searchFrame.emptyText then return end
    if text then
        searchFrame.emptyText:SetText(text)
        searchFrame.emptyText:Show()
    else
        searchFrame.emptyText:Hide()
    end
end

local function RefreshSearchTab()
    -- Counts use the text-filtered (but not category-filtered) list
    local allTextFiltered = Profesjonell.GetFilteredRecipes(currentTextFilter, nil)
    filteredRecipes = Profesjonell.GetFilteredRecipes(currentTextFilter, currentCategoryFilter)

    local counts = CountByCategory(allTextFiltered)
    local entries = {}
    table.insert(entries, {
        label = "All (" .. table.getn(allTextFiltered) .. ")",
        selected = (currentCategoryFilter == nil),
        onClick = function()
            currentCategoryFilter = nil
            Profesjonell.RefreshSearchWindow()
        end,
    })
    for _, cat in ipairs(GetCategoryList(counts)) do
        local capturedCat = cat
        table.insert(entries, {
            label = (categoryLabels[cat] or cat) .. " (" .. (counts[cat] or 0) .. ")",
            selected = (currentCategoryFilter == cat),
            onClick = function()
                currentCategoryFilter = capturedCat
                Profesjonell.RefreshSearchWindow()
            end,
        })
    end
    RefreshLeftPane(entries, 0)
    SetEmptyText(table.getn(filteredRecipes) == 0 and "No matching recipes." or nil)
end

local function RefreshFavoritesTab()
    local base = Profesjonell.GetFilteredRecipes(currentTextFilter, nil)
    local groups = { enhancement = {}, items = {}, consumable = {} }
    for _, r in ipairs(base) do
        if r.favorite then
            table.insert(groups[Profesjonell.GetFavoriteGroup(r.category)], r)
        end
    end

    local selected = currentFavGroup
    if not selected then
        for _, g in ipairs(favGroupOrder) do
            if table.getn(groups[g]) > 0 then
                selected = g
                break
            end
        end
        selected = selected or favGroupOrder[1]
    end

    local entries = {}
    for _, g in ipairs(favGroupOrder) do
        local capturedGroup = g
        table.insert(entries, {
            label = favGroupLabels[g] .. " (" .. table.getn(groups[g]) .. ")",
            selected = (selected == g),
            onClick = function()
                currentFavGroup = capturedGroup
                Profesjonell.RefreshSearchWindow()
            end,
        })
    end
    RefreshLeftPane(entries, 0)

    filteredRecipes = groups[selected]
    if table.getn(filteredRecipes) == 0 then
        if currentTextFilter ~= "" then
            SetEmptyText("No matching favorites.")
        elseif Profesjonell.CountFavorites() == 0 then
            SetEmptyText("No favorites yet.\nAlt-click a recipe in the Search tab to add it.")
        else
            SetEmptyText("No favorites in this category.")
        end
    else
        SetEmptyText(nil)
    end
end

local function RefreshCraftsTab()
    local chars = Profesjonell.GetMyCharacters()

    -- Drop a selection that no longer exists
    if currentCraftChar then
        local found = false
        for _, c in ipairs(chars) do
            if string.lower(c) == string.lower(currentCraftChar) then found = true end
        end
        if not found then currentCraftChar = nil end
    end

    local all, counts = Profesjonell.GetCharacterRecipes(currentTextFilter, nil)
    if currentCraftChar then
        filteredRecipes = Profesjonell.GetCharacterRecipes(currentTextFilter, currentCraftChar)
    else
        filteredRecipes = all
    end

    local entries = {}
    table.insert(entries, {
        label = "All characters (" .. table.getn(all) .. ")",
        selected = (currentCraftChar == nil),
        onClick = function()
            currentCraftChar = nil
            Profesjonell.RefreshSearchWindow()
        end,
    })
    for _, c in ipairs(chars) do
        local capturedChar = c
        table.insert(entries, {
            label = c .. " (" .. (counts[c] or 0) .. ")",
            selected = (currentCraftChar ~= nil and string.lower(currentCraftChar) == string.lower(c)),
            onClick = function()
                currentCraftChar = capturedChar
                Profesjonell.RefreshSearchWindow()
            end,
            onRemove = function()
                Profesjonell.RemoveMyCharacter(capturedChar)
                if currentCraftChar and string.lower(currentCraftChar) == string.lower(capturedChar) then
                    currentCraftChar = nil
                end
                Profesjonell.RefreshSearchWindow()
            end,
        })
    end
    RefreshLeftPane(entries, 28)

    if table.getn(chars) == 0 then
        SetEmptyText("Add one of your characters on the left\nto see what it can craft.")
    elseif table.getn(filteredRecipes) == 0 then
        if currentTextFilter ~= "" then
            SetEmptyText("No matching recipes.")
        else
            SetEmptyText("No known recipes for this selection.\nOpen the character's professions to scan them.")
        end
    else
        SetEmptyText(nil)
    end
end

-- Full refresh of the search window
function Profesjonell.RefreshSearchWindow()
    if not searchFrame or not searchFrame:IsShown() then return end

    -- "Add character" controls only belong to the My Crafts tab
    if currentTab == "crafts" then
        searchFrame.addBox:Show()
        searchFrame.addBtn:Show()
    else
        searchFrame.addBox:Hide()
        searchFrame.addBtn:Hide()
    end

    if currentTab == "favorites" then
        RefreshFavoritesTab()
    elseif currentTab == "crafts" then
        RefreshCraftsTab()
    else
        RefreshSearchTab()
    end

    Profesjonell.UpdateSearchWindowScroll()
end

-- Highlight the active tab
local function UpdateTabVisual()
    if not searchFrame or not searchFrame.tabs then return end
    local idx = 1
    for i, key in ipairs(TAB_KEYS) do
        if key == currentTab then idx = i end
    end
    searchFrame.selectedTab = idx
    if PanelTemplates_SetTab then
        pcall(PanelTemplates_SetTab, searchFrame, idx)
    end
end

-- Switch tab: "search", "favorites" or "crafts"
function Profesjonell.SetSearchTab(tab)
    if not searchFrame then return end
    currentTab = tab
    Profesjonell.HideRecipeDetail()
    UpdateTabVisual()
    local sb = getglobal and getglobal("ProfesjonellSearchScrollFrameScrollBar")
    if sb and sb.SetValue then sb:SetValue(0) end
    Profesjonell.RefreshSearchWindow()
end

----------------------------------------------------------------
-- Recipe Detail Frame
----------------------------------------------------------------
local detailFrame = nil
local DETAIL_WIDTH = 260
local DETAIL_MEMBER_ROW_HEIGHT = 16
local DETAIL_MAX_VISIBLE_MEMBERS = 12

local function CreateDetailFrame()
    if detailFrame then return detailFrame end

    local df = CreateFrame("Frame", "ProfesjonellDetailFrame", searchFrame)
    df:SetWidth(DETAIL_WIDTH)
    df:SetHeight(WINDOW_HEIGHT)
    df:SetPoint("TOPLEFT", searchFrame, "TOPRIGHT", -2, 0)
    df:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    df:SetBackdropColor(0, 0, 0, 1)
    df:SetFrameStrata("HIGH")
    df:Hide()

    -- Close button
    local closeBtn = CreateFrame("Button", nil, df, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", df, "TOPRIGHT", -5, -5)
    closeBtn:SetScript("OnClick", function()
        df:Hide()
    end)

    -- Tooltip area (top half) - use a child frame to anchor the GameTooltip-style display
    local tooltipArea = CreateFrame("Frame", nil, df)
    tooltipArea:SetWidth(DETAIL_WIDTH - 24)
    tooltipArea:SetPoint("TOPLEFT", df, "TOPLEFT", 12, -12)
    tooltipArea:SetHeight(1) -- will be resized dynamically
    df.tooltipArea = tooltipArea

    -- Tooltip display frame (hidden GameTooltip clone for reading)
    local detailTooltip = CreateFrame("GameTooltip", "ProfesjonellDetailTooltip", df, "GameTooltipTemplate")
    detailTooltip:SetOwner(df, "ANCHOR_NONE")
    detailTooltip:SetPoint("TOPLEFT", tooltipArea, "TOPLEFT", 0, 0)
    df.detailTooltip = detailTooltip

    -- Separator between tooltip and member lists
    local sep = df:CreateTexture(nil, "ARTWORK")
    sep:SetWidth(DETAIL_WIDTH - 30)
    sep:SetHeight(1)
    sep:SetTexture(0.4, 0.4, 0.4, 0.8)
    df.separator = sep

    -- "Known by" header
    local knownByHeader = df:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    knownByHeader:SetJustifyH("LEFT")
    knownByHeader:SetText("Known by:")
    df.knownByHeader = knownByHeader

    -- Scrollable member list area
    local memberScroll = CreateFrame("ScrollFrame", "ProfesjonellDetailMemberScroll", df)
    memberScroll:SetWidth(DETAIL_WIDTH - 24)
    memberScroll:SetHeight(DETAIL_MAX_VISIBLE_MEMBERS * DETAIL_MEMBER_ROW_HEIGHT)
    df.memberScroll = memberScroll

    -- Scroll child (actual content)
    local memberArea = CreateFrame("Frame", nil, memberScroll)
    memberArea:SetWidth(DETAIL_WIDTH - 40)
    memberArea:SetHeight(1) -- resized dynamically
    memberScroll:SetScrollChild(memberArea)
    df.memberArea = memberArea

    -- Scrollbar (slider)
    local scrollBar = CreateFrame("Slider", "ProfesjonellDetailMemberScrollBar", memberScroll)
    scrollBar:SetWidth(16)
    scrollBar:SetPoint("TOPRIGHT", memberScroll, "TOPRIGHT", 0, 0)
    scrollBar:SetPoint("BOTTOMRIGHT", memberScroll, "BOTTOMRIGHT", 0, 0)
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValueStep(DETAIL_MEMBER_ROW_HEIGHT)
    scrollBar:SetValue(0)
    scrollBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    local thumbTex = scrollBar:CreateTexture(nil, "OVERLAY")
    thumbTex:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    thumbTex:SetWidth(18)
    thumbTex:SetHeight(24)
    scrollBar:SetThumbTexture(thumbTex)
    scrollBar:SetScript("OnValueChanged", function()
        memberScroll:SetVerticalScroll(scrollBar:GetValue())
    end)
    scrollBar:Hide()
    df.memberScrollBar = scrollBar

    -- Mouse wheel scrolling
    memberScroll:EnableMouseWheel(true)
    memberScroll:SetScript("OnMouseWheel", function()
        local cur = scrollBar:GetValue()
        local step = DETAIL_MEMBER_ROW_HEIGHT * 3
        if arg1 > 0 then
            scrollBar:SetValue(math.max(0, cur - step))
        else
            local _, maxVal = scrollBar:GetMinMaxValues()
            scrollBar:SetValue(math.min(maxVal, cur + step))
        end
    end)

    -- Member rows (created on demand)
    df.memberRows = {}

    detailFrame = df
    return df
end

local function GetOrCreateMemberRow(index)
    if detailFrame.memberRows[index] then
        return detailFrame.memberRows[index]
    end

    local row = CreateFrame("Frame", nil, detailFrame.memberArea)
    row:SetWidth(DETAIL_WIDTH - 28)
    row:SetHeight(DETAIL_MEMBER_ROW_HEIGHT)

    -- Online status indicator
    local statusIcon = row:CreateTexture(nil, "ARTWORK")
    statusIcon:SetWidth(8)
    statusIcon:SetHeight(8)
    statusIcon:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.statusIcon = statusIcon

    -- Member name
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", statusIcon, "RIGHT", 4, 0)
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    -- Whisper button (only for online members)
    local whisperBtn = CreateFrame("Button", nil, row)
    whisperBtn:SetWidth(14)
    whisperBtn:SetHeight(14)
    whisperBtn:SetPoint("RIGHT", row, "RIGHT", -18, 0)
    whisperBtn:SetNormalTexture("Interface\\GossipFrame\\GossipGossipIcon")
    whisperBtn:SetHighlightTexture("Interface\\GossipFrame\\GossipGossipIcon")
    row.whisperBtn = whisperBtn

    detailFrame.memberRows[index] = row
    return row
end

-- Show the detail frame for a given recipe
function Profesjonell.ShowRecipeDetail(recipeData)
    if not searchFrame or not recipeData then return end

    local df = CreateDetailFrame()

    -- Set tooltip (top half) - only for item keys, not spell/enchant
    local tooltip = df.detailTooltip
    tooltip:ClearLines()
    tooltip:SetOwner(df, "ANCHOR_NONE")
    tooltip:SetPoint("TOPLEFT", df.tooltipArea, "TOPLEFT", 0, 0)

    local hasTooltip = false
    if string.find(recipeData.key, "^s:") then
        -- Use enchant: hyperlink for spell keys (shows full crafting tooltip with reagents)
        local _, _, linkId = string.find(recipeData.key, "^s:(%d+)")
        if linkId then
            local ok = pcall(function()
                tooltip:SetHyperlink("enchant:" .. linkId)
            end)
            if ok and tooltip:NumLines() and tooltip:NumLines() > 0 then
                hasTooltip = true
                tooltip:Show()
            end
        end
    else
        local _, _, linkType, linkId = string.find(recipeData.link or "", "|H(%a+):(%d+)")
        if linkType and linkId then
            local ok = pcall(function()
                tooltip:SetHyperlink(linkType .. ":" .. linkId)
            end)
            if ok and tooltip:NumLines() and tooltip:NumLines() > 0 then
                hasTooltip = true
                tooltip:Show()
            end
        end
    end

    if not hasTooltip then
        tooltip:Hide()
        -- For enchants/spells with no tooltip, show recipe name as a label
        if recipeData.name and recipeData.name ~= "" then
            if not df.enchantLabel then
                df.enchantLabel = df.tooltipArea:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                df.enchantLabel:SetPoint("TOPLEFT", df.tooltipArea, "TOPLEFT", 4, -4)
            end
            df.enchantLabel:SetText(recipeData.name)
            df.enchantLabel:Show()
        else
            if df.enchantLabel then
                df.enchantLabel:Hide()
            end
        end
    else
        if df.enchantLabel then
            df.enchantLabel:Hide()
        end
    end

    -- Calculate where the member list starts using actual tooltip dimensions
    local tooltipHeight = 0
    local tooltipWidth = 0
    if hasTooltip then
        tooltipHeight = tooltip:GetHeight() or 0
        tooltipWidth = tooltip:GetWidth() or 0
        if tooltipHeight < 1 then
            -- Fallback: estimate from line count
            local numLines = tooltip:NumLines() or 0
            tooltipHeight = math.max(numLines * 14 + 16, 30)
        end
    end
    -- For enchants with no tooltip, use the label height
    if not hasTooltip and df.enchantLabel and df.enchantLabel:IsShown() then
        tooltipHeight = (df.enchantLabel:GetHeight() or 14) + 12
    end
    df.tooltipArea:SetHeight(math.max(tooltipHeight, 1))

    -- Resize detail frame width to fit tooltip if needed
    local minWidth = DETAIL_WIDTH
    local neededWidth = tooltipWidth + 24 -- 12px padding each side
    local frameWidth = math.max(minWidth, neededWidth)
    df:SetWidth(frameWidth)

    -- Position separator
    local sepY = -12 - tooltipHeight - 8
    df.separator:SetPoint("TOPLEFT", df, "TOPLEFT", 15, sepY)

    -- Position "Known by" header
    df.knownByHeader:SetPoint("TOPLEFT", df, "TOPLEFT", 14, sepY - 8)

    -- Position member scroll area
    df.memberScroll:SetPoint("TOPLEFT", df, "TOPLEFT", 14, sepY - 24)

    -- Build online/offline member lists
    local onlineMembers = {}
    local offlineMembers = {}
    local holders = recipeData.detailHolders or recipeData.holders or {}
    for _, name in ipairs(holders) do
        if Profesjonell.GuildRosterOnlineCache and Profesjonell.GuildRosterOnlineCache[name] then
            table.insert(onlineMembers, name)
        else
            table.insert(offlineMembers, name)
        end
    end
    table.sort(onlineMembers, function(a, b) return string.lower(a) < string.lower(b) end)
    table.sort(offlineMembers, function(a, b) return string.lower(a) < string.lower(b) end)

    -- Hide all existing member rows
    for _, row in ipairs(df.memberRows) do
        row:Hide()
    end

    local rowIndex = 0

    -- Online members
    for _, name in ipairs(onlineMembers) do
        rowIndex = rowIndex + 1
        local row = GetOrCreateMemberRow(rowIndex)
        row:SetPoint("TOPLEFT", df.memberArea, "TOPLEFT", 0, -((rowIndex - 1) * DETAIL_MEMBER_ROW_HEIGHT))
        row.statusIcon:SetTexture(0, 1, 0, 1) -- green dot
        row.nameText:SetText(name)
        local classColor = Profesjonell.GetClassColor(Profesjonell.GuildRosterCache and Profesjonell.GuildRosterCache[name])
        if classColor then
            local cr = tonumber(string.sub(classColor, 1, 2), 16) / 255
            local cg = tonumber(string.sub(classColor, 3, 4), 16) / 255
            local cb = tonumber(string.sub(classColor, 5, 6), 16) / 255
            row.nameText:SetTextColor(cr, cg, cb)
        else
            row.nameText:SetTextColor(1, 1, 1)
        end
        row.whisperBtn:Show()
        local capturedName = name
        row.whisperBtn:SetScript("OnClick", function()
            if ChatFrameEditBox then
                ChatFrameEditBox:Show()
                ChatFrameEditBox:SetText("/w " .. capturedName .. " ")
                ChatFrameEditBox:SetFocus()
            end
        end)
        row.whisperBtn:SetScript("OnEnter", function()
            GameTooltip:SetOwner(row.whisperBtn, "ANCHOR_RIGHT")
            GameTooltip:SetText("Whisper " .. capturedName)
            GameTooltip:Show()
        end)
        row.whisperBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        row:Show()
    end

    -- Offline members
    for _, name in ipairs(offlineMembers) do
        rowIndex = rowIndex + 1
        local row = GetOrCreateMemberRow(rowIndex)
        row:SetPoint("TOPLEFT", df.memberArea, "TOPLEFT", 0, -((rowIndex - 1) * DETAIL_MEMBER_ROW_HEIGHT))
        row.statusIcon:SetTexture(0.5, 0.5, 0.5, 1) -- gray dot
        row.nameText:SetText(name)
        local classColor = Profesjonell.GetClassColor(Profesjonell.GuildRosterCache and Profesjonell.GuildRosterCache[name])
        if classColor then
            local cr = tonumber(string.sub(classColor, 1, 2), 16) / 255
            local cg = tonumber(string.sub(classColor, 3, 4), 16) / 255
            local cb = tonumber(string.sub(classColor, 5, 6), 16) / 255
            row.nameText:SetTextColor(cr, cg, cb)
        else
            row.nameText:SetTextColor(0.6, 0.6, 0.6)
        end
        row.whisperBtn:Hide()
        row:Show()
    end

    -- Set up scrolling if needed
    local totalMemberHeight = rowIndex * DETAIL_MEMBER_ROW_HEIGHT
    df.memberArea:SetHeight(totalMemberHeight)
    local visibleMemberHeight
    if rowIndex > DETAIL_MAX_VISIBLE_MEMBERS then
        visibleMemberHeight = DETAIL_MAX_VISIBLE_MEMBERS * DETAIL_MEMBER_ROW_HEIGHT
        local maxScroll = totalMemberHeight - visibleMemberHeight
        df.memberScrollBar:SetMinMaxValues(0, maxScroll)
        df.memberScrollBar:SetValue(0)
        df.memberScrollBar:Show()
        df.memberScroll:SetVerticalScroll(0)
    else
        visibleMemberHeight = totalMemberHeight
        df.memberScrollBar:SetMinMaxValues(0, 0)
        df.memberScrollBar:SetValue(0)
        df.memberScrollBar:Hide()
        df.memberScroll:SetVerticalScroll(0)
    end
    df.memberScroll:SetHeight(visibleMemberHeight)

    -- Resize the detail frame to fit content
    local totalHeight = 12 + tooltipHeight + 8 + 1 + 8 + 16 + visibleMemberHeight + 16
    df:SetHeight(math.max(totalHeight, 100))

    df:Show()
end

-- Hide the detail frame
function Profesjonell.HideRecipeDetail()
    if detailFrame then
        detailFrame:Hide()
    end
end

-- Show/hide the progress bar overlay
local function ShowProgressBar(show)
    if not searchFrame then return end
    if not searchFrame.progressOverlay then
        local overlay = CreateFrame("Frame", nil, searchFrame)
        overlay:SetAllPoints(searchFrame)
        overlay:SetFrameLevel(searchFrame:GetFrameLevel() + 10)
        local bg = overlay:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(overlay)
        bg:SetTexture(0, 0, 0, 0.7)

        local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        label:SetPoint("CENTER", overlay, "CENTER", 0, 20)
        label:SetText("Scanning recipes...")
        overlay.label = label

        -- Progress bar background
        local barBg = CreateFrame("Frame", nil, overlay)
        barBg:SetWidth(300)
        barBg:SetHeight(20)
        barBg:SetPoint("CENTER", overlay, "CENTER", 0, -10)
        barBg:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        overlay.barBg = barBg

        -- Progress bar fill
        local barFill = barBg:CreateTexture(nil, "ARTWORK")
        barFill:SetPoint("TOPLEFT", barBg, "TOPLEFT", 3, -3)
        barFill:SetHeight(14)
        barFill:SetWidth(1)
        barFill:SetTexture(0.26, 0.68, 0.26, 1)
        overlay.barFill = barFill

        -- Progress text
        local pctText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pctText:SetPoint("TOP", barBg, "BOTTOM", 0, -4)
        pctText:SetText("0%")
        overlay.pctText = pctText

        searchFrame.progressOverlay = overlay
    end

    if show then
        searchFrame.progressOverlay:Show()
    else
        searchFrame.progressOverlay:Hide()
    end
end

local function UpdateProgressBar(current, total)
    if not searchFrame or not searchFrame.progressOverlay then return end
    local pct = total > 0 and (current / total) or 1
    local maxWidth = 294
    searchFrame.progressOverlay.barFill:SetWidth(math.max(1, maxWidth * pct))
    searchFrame.progressOverlay.pctText:SetText(math.floor(pct * 100) .. "%")
end

-- Toggle the search window
function Profesjonell.ToggleSearchWindow()
    if not searchFrame then
        CreateSearchWindow()
    end

    if searchFrame:IsShown() then
        Profesjonell.HideRecipeDetail()
        searchFrame:Hide()
    else
        Profesjonell.HideRecipeDetail()
        currentTextFilter = ""
        currentCategoryFilter = nil
        if searchFrame.editBox then
            searchFrame.editBox:SetText("")
        end
        searchFrame:Show()
        UpdateTabVisual()

        if not Profesjonell.IsItemTypeCacheReady() then
            ShowProgressBar(true)
            Profesjonell.BuildItemTypeCache(
                function(current, total)
                    UpdateProgressBar(current, total)
                end,
                function()
                    ShowProgressBar(false)
                    Profesjonell.RefreshSearchWindow()
                end
            )
        else
            Profesjonell.RefreshSearchWindow()
        end
    end
end

Profesjonell.Log("SearchWindow.lua loaded")
