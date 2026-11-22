-- WandBar: on enemy nameplate health bars, the damage that is still coming, as bands that eat
-- back from the end of the health fill; what stays uncovered is the health the mob will have
-- left. From the health edge back:
--   yellow band: the direct hit of the spell you are casting / just cast
--   channel band: what is left of the drain / Mind Flay you are channelling
--   DoT bands: one per DoT you applied, in its colour (Spells.lua), shrinking tick by
--     tick; grey for a DoT DoesItDie tracks that Spells.lua doesn't know
--   pale band: one average wand shot after all that, with a white line at its end
--   text: "kill" when the DoTs finish the mob, else "xN" wand shots still needed
--
-- WoW Forever closes the combat log to addons, so DoTs are estimated from your casts (target,
-- time, the rank's tooltip damage + spell power x coefficient) and counted down tick by tick.
-- With DoesItDie loaded, its numbers (learned from real ticks) replace the estimates.
--
-- Enemy health can be a secret value on this client. The bands never do maths on it: each is
-- a StatusBar whose range is the (maybe secret) max health and whose value is our own number,
-- so the client places it. The text needs real numbers and stays hidden while health is
-- secret.

local ADDON, ns = ...
local canaccess = canaccessvalue or function() return true end

local function Say(msg) print("|cffb090ff" .. ADDON .. "|r: " .. msg) end

local WAND_COLOR = { 1, 1, 1, 0.45 }
local EDGE_COLOR = { 1, 1, 1, 0.95 }
local TEXT_COLOR = { 0.85, 0.75, 1 }
local KILL_COLOR = { 0.4, 1, 0.4 }
local CAST_COLOR = { 1.00, 0.90, 0.15, 0.95 }
local OTHER_COLOR = { 0.75, 0.75, 0.75, 0.95 }
local CAST_FLIGHT = 1.0 -- seconds a cast's band stays after it leaves your hands
-- a projectile DoT's first tick came 3.6 to 3.9 s after the cast instead of 3 s
local DOT_TRAVEL = 0.75
local SCHOOLS = { holy = 2, fire = 3, nature = 4, frost = 5, shadow = 6, arcane = 7 }

local DEFAULTS = { enabled = true, wand = true, dots = true, cast = true, text = true }
local db

local DOTS = {} -- spell name or alias -> DoT definition
local CONSUMES = {} -- spell name -> name of the DoT it ends
local ORDER = {} -- DoT definitions in band order: yours first, channels before the rest
local classDots = {} -- the player's class's DoTs

local overlays = {} -- healthbar -> overlay
local byUnit = {} -- nameplate unit -> overlay
local dots = {} -- mob GUID -> { [dot name] = { start, interval, ticks, perTick, ... } }
local sentTarget = {} -- castGUID -> target GUID when the cast was sent
local pending = {} -- mob GUID -> { amount, castGUID, expires } for a direct hit on its way
local wandDamage -- average per shot, nil without a wand

local function BuildSpellTables()
    local _, class = UnitClass("player")
    local function add(def, mine)
        if mine then classDots[#classDots + 1] = def end
        DOTS[def.name] = def
        for _, alias in ipairs(def.aliases or {}) do DOTS[alias] = def end
        if def.consumedBy then CONSUMES[def.consumedBy] = def.name end
    end
    for _, def in ipairs(ns.DOTS[class] or {}) do add(def, true) end
    for other, list in pairs(ns.DOTS) do
        if other ~= class then for _, def in ipairs(list) do add(def, false) end end
    end
    for _, channel in ipairs({ true, false }) do
        for _, def in ipairs(classDots) do
            if (def.channel or false) == channel then ORDER[#ORDER + 1] = def end
        end
    end
    for other, list in pairs(ns.DOTS) do
        if other ~= class then for _, def in ipairs(list) do ORDER[#ORDER + 1] = def end end
    end
end

local function Number(v)
    if v ~= nil and canaccess(v) and type(v) == "number" then return v end
end

---------------------------------------------------------------------------
-- Wand damage
---------------------------------------------------------------------------
local function HasWand()
    if HasWandEquipped then return HasWandEquipped() end
    local id = GetInventoryItemID("player", INVSLOT_RANGED or 18)
    if not id then return false end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
    return classID == 2 and subClassID == 19
end

-- UnitRangedDamage includes buffs and percent modifiers (it is what the character sheet shows)
local function ReadWandDamage()
    if not HasWand() then return nil end
    local _, minD, maxD = UnitRangedDamage("player")
    minD, maxD = Number(minD), Number(maxD)
    if not minD or not maxD or maxD <= 0 then return nil end
    return (minD + maxD) / 2
end

---------------------------------------------------------------------------
-- Damage from tooltips
---------------------------------------------------------------------------
local function ReadableGUID(unit)
    local guid = UnitGUID(unit)
    if guid and canaccess(guid) then return guid end
end

local function Description(spellID)
    local text = C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(spellID)
    if not text or not canaccess(text) or text == "" then return nil end
    return (text:lower():gsub("(%d),(%d)", "%1%2"))
end

local function BonusPower(def)
    if def.power == "ranged" then
        if not UnitRangedAttackPower then return 0 end
        local base, pos, neg = UnitRangedAttackPower("player")
        base, pos, neg = Number(base), Number(pos) or 0, Number(neg) or 0
        return base and math.max(0, base + pos + neg) or 0
    end
    return GetSpellBonusDamage and Number(GetSpellBonusDamage(def.school)) or 0
end

-- The rank's periodic total and duration from its tooltip
local periodicCache = {}
local function PeriodicDamage(spellID)
    local cached = periodicCache[spellID]
    if cached then return cached[1], cached[2] end
    local text = Description(spellID)
    if not text then return nil end
    -- "causing 40 shadow damage over 12 sec", "bleed for 15 damage over 9 sec"
    local total, duration = text:match("(%d+) %a* ?damage over (%d+) sec")
    total, duration = tonumber(total), tonumber(duration)
    if not total then
        -- Bane of Doom: "causing 3200 shadow damage after 1 min" / "after 60 sec"
        local t, n, unit = text:match("(%d+) %a+ damage after (%d+) (%a+)")
        t, n = tonumber(t), tonumber(n)
        if t and n then total, duration = t, (unit:sub(1, 3) == "min") and n * 60 or n end
    end
    if not total then
        -- "transfers 10 health every 1 second ... lasts 5 sec",
        -- "transfers 11 health from the target to the caster every 3 sec. lasts 30 sec"
        local per, every = text:match("(%d+) health .-every (%d+) sec")
        if not per then
            per = text:match("(%d+) health .-every sec")
            every = per and 1
        end
        local lasts = text:match("lasts (%d+) sec") or text:match("for (%d+) sec")
        per, every, lasts = tonumber(per), tonumber(every), tonumber(lasts)
        if per and every and lasts and every > 0 then
            total, duration = per * lasts / every, lasts
        end
    end
    if not (total and duration and duration > 0) then return nil end
    periodicCache[spellID] = { total, duration }
    return total, duration
end

-- The rank's direct (non-periodic) damage from its tooltip, plus spell power, or nil
local directCache = {}
local function DirectDamage(spellID, name)
    if ns.NOT_DIRECT[name] then return nil end
    local cached = directCache[spellID]
    if cached == nil then
        local text = Description(spellID)
        if not text then return nil end
        cached = false
        -- "causing 13 to 18 shadow damage"
        local lo, hi, school = text:match("(%d+) to (%d+) (%a+) damage")
        local base = lo and (tonumber(lo) + tonumber(hi)) / 2
        if not base then
            -- "burns the enemy for 11 fire damage and then ... over 15 sec": the first
            -- "N school damage" that is not periodic
            for n, s, rest in text:gmatch("(%d+) (%a+) damage ?(%a*)") do
                if SCHOOLS[s] and rest ~= "over" and rest ~= "after" and rest ~= "every" then
                    base, school = tonumber(n), s
                    break
                end
            end
        end
        if base and SCHOOLS[school] then cached = { base, SCHOOLS[school] } end
        directCache[spellID] = cached
    end
    if not cached then return nil end
    local def = DOTS[name]
    local coef = def and def.direct or ns.DIRECT_COEF[name]
    if not coef then
        local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
        local cast = info and Number(info.castTime) or 0
        coef = math.min(math.max(cast / 1000, 1.5), 3.5) / 3.5
    end
    local sp = GetSpellBonusDamage and Number(GetSpellBonusDamage(cached[2])) or 0
    return cached[1] + coef * sp
end

---------------------------------------------------------------------------
-- DoT tracking
---------------------------------------------------------------------------
-- tick k's share of the total: equal, or for a ramp half / normal / 1.5x by thirds
local function RampWeights(ticks)
    local w, third = {}, ticks / 3
    for k = 1, ticks do
        w[k] = (k <= third + 0.001) and 0.5 or (k <= 2 * third + 0.001) and 1 or 1.5
    end
    return w
end

local function AddDot(guid, spellID, def, castName)
    local total, duration = PeriodicDamage(spellID)
    if not total then return end
    local ticks = math.max(1, math.floor(duration / def.interval + 0.5))
    local weights = def.ramp and ticks >= 3 and RampWeights(ticks) or nil
    local weightSum = ticks
    if weights then
        weightSum = 0
        for _, w in ipairs(weights) do weightSum = weightSum + w end
    end
    -- base tooltip damage shared by the ticks' weights, plus the power bonus on each tick
    local perTick = (total + (def.coef or 0) * BonusPower(def) * ticks) / weightSum
    dots[guid] = dots[guid] or {}
    dots[guid][def.name] = {
        start = GetTime() + (def.travel and DOT_TRAVEL or 0), interval = def.interval,
        ticks = ticks, perTick = perTick, weights = weights, aura = castName or def.name,
    }
end

local function DotRemaining(d, now)
    local done = math.max(0, math.floor((now - d.start) / d.interval + 0.001))
    if done >= d.ticks then return 0 end
    if not d.weights then return (d.ticks - done) * d.perTick end
    local sum = 0
    for k = done + 1, d.ticks do sum = sum + d.weights[k] end
    return sum * d.perTick
end

-- Your debuffs on the unit by name, or nil when the client does not let us read them
local scratch = {}
local function PlayerDebuffs(unit)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
    wipe(scratch)
    local any = false
    for i = 1, 40 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL|PLAYER")
        if not ok then return nil end
        if not aura then break end
        local name = aura.name
        if not canaccess(name) then return nil end
        scratch[name] = true
        any = true
    end
    -- an empty list proves nothing (it also comes back empty when hidden)
    return any and scratch or nil
end

-- Remaining damage per DoT on this mob, dropping finished ones and, when `verify`, ones whose
-- debuff is gone (dispelled, replaced, resisted)
local function MobDots(unit, guid, now, verify)
    local list = dots[guid]
    if not list then return nil end
    local seen = verify and next(list) and PlayerDebuffs(unit)
    for name, d in pairs(list) do
        local left = DotRemaining(d, now)
        -- give a fresh cast a moment to show up as a debuff
        if left <= 0 or (seen and not seen[d.aura] and now - d.start > 0.5) then
            list[name] = nil
        else
            d.left = left
        end
    end
    if not next(list) then dots[guid] = nil; return nil end
    return list
end

-- DoesItDie's per-DoT numbers on this unit by DoT name, plus the total of the DoTs WandBar
-- has no entry for; nil when DoesItDie isn't loaded
local function DIDAmounts(unit)
    local api = DoesItDie
    if type(api) ~= "table" or not api.GetDoTs then return nil end
    local ok, entries = pcall(api.GetDoTs, unit)
    if not ok or type(entries) ~= "table" then return nil end
    local amounts, other = {}, 0
    for _, e in ipairs(entries) do
        local def = DOTS[e.name]
        if type(e.damage) == "number" then
            if def then
                amounts[def.name] = (amounts[def.name] or 0) + e.damage
            else
                other = other + e.damage
            end
        end
    end
    return amounts, other
end

-- What comes off the mob, nearest the health edge first: the cast, the channel, each DoT.
-- DoesItDie lists a DoT from its first tick on; until then (one tick + a moment) ours stands
-- in for it.
local function Segments(unit, guid, now, verify)
    local segs = {}
    local hit = guid and db.cast and pending[guid]
    if hit and hit.expires > now then segs[#segs + 1] = { "cast", hit.amount } end
    if not db.dots then return segs end
    local list = guid and MobDots(unit, guid, now, verify)
    local fromDID, otherDID = DIDAmounts(unit)
    for _, def in ipairs(ORDER) do
        local d = list and list[def.name]
        local amount
        if fromDID and not def.channel and def.did ~= false then
            amount = fromDID[def.name]
            if not amount and d and now - d.start < def.interval + 1.5 then amount = d.left end
        else
            amount = d and d.left
        end
        if amount and amount > 0 then segs[#segs + 1] = { def.name, amount } end
    end
    if otherDID and otherDID > 0 then segs[#segs + 1] = { "other", otherDID } end
    return segs
end

---------------------------------------------------------------------------
-- Overlay on one health bar
---------------------------------------------------------------------------
local function HealthBarFor(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return nil end
    local tp = plate.TPFrame
    local bar = tp and tp.visual and tp.visual.Healthbar
    if bar then return bar end
    local uf = plate.UnitFrame
    bar = uf and (uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar or uf.healthBar)
    if bar and not bar:IsForbidden() then return bar end
end

-- Threat Plates' text layer on this unit's plate (health text, name), or nil on other plates
local function TextFrameFor(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    local tp = plate and plate.TPFrame
    return tp and tp.visual and tp.visual.textframe
end

local function SafeLevel(frame)
    local ok, level = pcall(frame.GetFrameLevel, frame)
    return ok and Number(level) or 10
end

-- every band starts at the health fill's edge and runs back over it by its (cumulative)
-- value, so what stays uncovered is the health the mob will have left
local function AnchorBand(o, band)
    local fill = o.fill
    band:ClearAllPoints()
    band:SetWidth(o.width)
    if o.reverse then
        band:SetPoint("TOPLEFT", fill, "TOPLEFT")
        band:SetPoint("BOTTOMLEFT", fill, "BOTTOMLEFT")
        band:SetReverseFill(false)
    else
        band:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
        band:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
        band:SetReverseFill(true)
    end
end

local function LayoutOverlay(o)
    local hb = o.healthbar
    o.fill = hb:GetStatusBarTexture()
    if not o.fill then return end
    local ok, rev = pcall(function() return hb.GetReverseFill and hb:GetReverseFill() end)
    o.reverse = ok and canaccess(rev) and rev == true
    local okW, w = pcall(hb.GetWidth, hb)
    w = okW and Number(w)
    o.width = (w and w > 1) and w or 100
    AnchorBand(o, o.wand)
    for _, band in pairs(o.bands) do AnchorBand(o, band) end
    -- the white line marks where one wand shot after everything else would leave the mob
    local tex = o.wand:GetStatusBarTexture()
    local side = o.reverse and "RIGHT" or "LEFT"
    o.edge:ClearAllPoints()
    o.edge:SetPoint("TOP" .. side, tex, "TOP" .. side)
    o.edge:SetPoint("BOTTOM" .. side, tex, "BOTTOM" .. side)
end

local function NewBand(parent, color)
    local band = CreateFrame("StatusBar", nil, parent)
    band:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    band:SetStatusBarColor(unpack(color))
    band:SetMinMaxValues(0, 1)
    band:SetValue(0)
    return band
end

local function Band(o, key)
    local band = o.bands[key]
    if band then return band end
    local def = DOTS[key]
    local color = key == "cast" and CAST_COLOR or def and def.color or OTHER_COLOR
    band = NewBand(o.clip, color)
    o.bands[key] = band
    if o.fill then AnchorBand(o, band) end
    return band
end

local function GetOverlay(hb)
    local o = overlays[hb]
    if o then return o end
    o = { healthbar = hb, bands = {} }

    -- holds the bands and clips them to the bar, so damage beyond the health left stops at
    -- the bar's edge; their levels are set per update
    local clip = CreateFrame("Frame", nil, hb)
    clip:SetAllPoints(hb)
    clip:SetClipsChildren(true)
    clip:SetFrameLevel(SafeLevel(hb) + 1)
    o.clip = clip

    o.wand = NewBand(clip, WAND_COLOR)
    local edge = o.wand:CreateTexture(nil, "OVERLAY")
    edge:SetColorTexture(unpack(EDGE_COLOR))
    edge:SetWidth(1)
    o.edge = edge

    local text = hb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", hb, "RIGHT", 3, 0)
    text:Hide()
    o.text = text

    hb:HookScript("OnSizeChanged", function() if o.unit then LayoutOverlay(o) end end)
    overlays[hb] = o
    return o
end

local function HideOverlay(o)
    o.clip:Hide()
    o.text:Hide()
    if o.unit and byUnit[o.unit] == o then byUnit[o.unit] = nil end
    o.unit = nil
end

local function IsEnemy(unit)
    local attackable = UnitCanAttack("player", unit)
    if not canaccess(attackable) then return true end
    if not attackable then return false end
    local dead = UnitIsDead(unit)
    return not (canaccess(dead) and dead)
end

local function UpdateText(o)
    if not (db.text and o.unit) then o.text:Hide(); return end
    local hp = Number(UnitHealth(o.unit))
    if not hp or hp <= 0 then o.text:Hide(); return end
    local wand = db.wand and wandDamage
    local left = hp - o.dotTotal
    if o.dotTotal > 0 and left <= 0 then
        o.text:SetText("kill")
        o.text:SetTextColor(unpack(KILL_COLOR))
    elseif wand then
        o.text:SetFormattedText("x%d", math.ceil(left / wand))
        o.text:SetTextColor(unpack(TEXT_COLOR))
    else
        o.text:Hide()
        return
    end
    o.text:Show()
end

local function UpdateUnit(unit, verify)
    local o = byUnit[unit]
    local now = GetTime()
    local segs = Segments(unit, ReadableGUID(unit), now, verify)
    local dotTotal = 0
    for _, s in ipairs(segs) do dotTotal = dotTotal + s[2] end
    local wand = db.wand and wandDamage
    local hb = db.enabled and (wand or dotTotal > 0) and IsEnemy(unit) and HealthBarFor(unit)
    if not hb then
        if o then HideOverlay(o) end
        return
    end
    if o and o.healthbar ~= hb then HideOverlay(o) end
    o = GetOverlay(hb)
    if o.unit and o.unit ~= unit and byUnit[o.unit] == o then byUnit[o.unit] = nil end
    if o.unit ~= unit then o.unit = unit; LayoutOverlay(o) end
    byUnit[unit] = o
    o.guid = ReadableGUID(unit)
    o.dotTotal = dotTotal

    -- max health may be secret: it only ever goes into the StatusBars.
    -- Each band runs back from the health edge by its cumulative value, so the shorter
    -- (nearer) ones must lie on top of the longer ones.
    local maxHealth = UnitHealthMax(unit)
    local base = SafeLevel(o.healthbar) + 1
    local top = base + #segs + (wand and 1 or 0)
    for _, band in pairs(o.bands) do band.used = false end
    local cum = 0
    for i, s in ipairs(segs) do
        local band = Band(o, s[1])
        cum = cum + s[2]
        band:SetFrameLevel(math.max(top - i + 1, base + 1))
        band:SetMinMaxValues(0, maxHealth)
        band:SetValue(cum)
        band:Show()
        band.used = true
    end
    for _, band in pairs(o.bands) do if not band.used then band:Hide() end end
    if wand then
        o.wand:SetFrameLevel(math.max(top - #segs, base + 1))
        o.wand:SetMinMaxValues(0, maxHealth)
        o.wand:SetValue(cum + wand)
        o.wand:Show()
    else
        o.wand:Hide()
    end
    o.clip:Show()
    -- Threat Plates draws its health text (and name, raid marker) on a text layer level with
    -- the health bar: lift it over the bands so they never cover it. Threat Plates resets it
    -- when it restyles the plate; the next update (every 0.25 s while DoTs run) lifts it
    -- again.
    local tf = TextFrameFor(unit)
    if tf and SafeLevel(tf) <= top then tf:SetFrameLevel(top + 1) end
    UpdateText(o)
end

local function ForEachPlateUnit(fn)
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if unit then fn(unit) end
    end
end

local function UpdateAll()
    wandDamage = ReadWandDamage()
    for unit, o in pairs(byUnit) do
        if not UnitExists(unit) then HideOverlay(o) end
    end
    ForEachPlateUnit(UpdateUnit)
end

local function UpdateGUID(guid)
    ForEachPlateUnit(function(unit)
        if ReadableGUID(unit) == guid then UpdateUnit(unit) end
    end)
end

-- DoT bands shrink tick by tick; finished DoTs are dropped; a plate's debuffs are re-checked
local function Tick()
    local now = GetTime()
    local redraw
    for guid, hit in pairs(pending) do
        if hit.expires <= now then
            pending[guid] = nil
            redraw = redraw or {}
            redraw[guid] = true
        end
    end
    if not next(dots) and not redraw then return end
    local shown = {}
    for unit, o in pairs(byUnit) do
        local guid = o.guid
        if guid and (dots[guid] or (redraw and redraw[guid])) then
            shown[guid] = true
            UpdateUnit(unit, true)
        end
    end
    -- mobs without a plate: just let their timers run out
    for guid, list in pairs(dots) do
        if not shown[guid] then
            for name, d in pairs(list) do
                if DotRemaining(d, now) <= 0 then list[name] = nil end
            end
            if not next(list) then dots[guid] = nil end
        end
    end
end

---------------------------------------------------------------------------
-- Casts
---------------------------------------------------------------------------
local activeChannel -- { guid, name, spellID, time } of the DoT you are channelling

-- The mob a cast is aimed at (read when it was sent) and the spell's name, or nil
local function CastTarget(castGUID, spellID, consume)
    if not (spellID and canaccess(spellID)) then return end
    local okGUID = castGUID and canaccess(castGUID)
    local guid = okGUID and sentTarget[castGUID]
    if consume and okGUID then sentTarget[castGUID] = nil end
    local name = C_Spell.GetSpellName(spellID)
    if not (name and canaccess(name)) then return end
    if not guid then
        local attackable = UnitCanAttack("player", "target")
        if canaccess(attackable) and attackable then guid = ReadableGUID("target") end
    end
    if guid then return guid, name end
end

-- casting starts: show the hit it will do for as long as the cast bar runs
local function OnCastStart(castGUID, spellID)
    local guid, name = CastTarget(castGUID, spellID, false)
    if not guid then return end
    local amount = DirectDamage(spellID, name)
    if not amount then return end
    local _, _, _, _, endMs = UnitCastingInfo("player")
    endMs = Number(endMs)
    local ends = endMs and endMs / 1000 or GetTime() + 5
    pending[guid] = { amount = amount, castGUID = castGUID, expires = ends + CAST_FLIGHT + 1 }
    UpdateGUID(guid)
end

-- the cast was cancelled: its hit is not coming
local function OnCastFailed(castGUID)
    if not (castGUID and canaccess(castGUID)) then return end
    sentTarget[castGUID] = nil
    for guid, hit in pairs(pending) do
        if hit.castGUID == castGUID then
            pending[guid] = nil
            UpdateGUID(guid)
        end
    end
end

local function OnSpellSucceeded(castGUID, spellID)
    if not (spellID and canaccess(spellID)) then return end
    -- a channel can report both SUCCEEDED and CHANNEL_START: count it once
    local c = activeChannel
    if c and c.spellID == spellID and GetTime() - c.time < 0.5 then return end
    local guid, name = CastTarget(castGUID, spellID, true)
    if not guid then return end
    local changed = false
    -- the spell left your hands: its hit lands about a second from now
    local amount = db.cast and DirectDamage(spellID, name)
    if amount then
        local expires = GetTime() + CAST_FLIGHT
        pending[guid] = { amount = amount, castGUID = castGUID, expires = expires }
        changed = true
    end
    local def = DOTS[name]
    if def then
        AddDot(guid, spellID, def, name)
        if def.channel then
            local time = GetTime()
            activeChannel = { guid = guid, name = def.name, spellID = spellID, time = time }
        end
        changed = true
    elseif CONSUMES[name] and dots[guid] then
        dots[guid][CONSUMES[name]] = nil
        changed = true
    end
    if changed then UpdateGUID(guid) end
end

-- a channel stops doing damage the moment you stop channelling (moved, interrupted, recast)
local function OnChannelStop()
    local c = activeChannel
    activeChannel = nil
    if not c then return end
    local list = dots[c.guid]
    if list then
        list[c.name] = nil
        if not next(list) then dots[c.guid] = nil end
    end
    UpdateGUID(c.guid)
end

---------------------------------------------------------------------------
-- DoesItDie
---------------------------------------------------------------------------
-- Once: make DoesItDie's nameplate marker invisible (its kill skull stays), since WandBar
-- draws the same DoTs there per spell. Plate settings only; its target frame marker is
-- untouched. /did can turn it back on, and WandBar won't redo it.
local function SetUpDoesItDie()
    if type(DoesItDieDB) == "table" and not db.didPlateStyled then
        DoesItDieDB.plateFillOpacity = 0
        DoesItDieDB.plateOutlineStyle = "none"
        db.didPlateStyled = true
        Say("hid DoesItDie's nameplate marker, since " .. ADDON .. " draws each DoT there. "
            .. "/did (Nameplates) brings it back.")
    end
    local api = DoesItDie
    if type(api) == "table" and api.RegisterCallback then
        api.RegisterCallback(ADDON, function(_, unit)
            if type(unit) == "string" and unit:find("^nameplate") and UnitExists(unit) then
                UpdateUnit(unit)
            end
        end)
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        f:UnregisterEvent("ADDON_LOADED")
        WandBarDB = WandBarDB or {}
        db = WandBarDB
        for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
        db.timers = nil -- setting of an older version
        BuildSpellTables()
        for _, e in ipairs({
            "PLAYER_ENTERING_WORLD", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
            "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_FACTION", "PLAYER_EQUIPMENT_CHANGED",
        }) do
            f:RegisterEvent(e)
        end
        for _, e in ipairs({
            "UNIT_RANGEDDAMAGE", "UNIT_INVENTORY_CHANGED", "UNIT_SPELLCAST_SENT",
            "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
            "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_START",
            "UNIT_SPELLCAST_CHANNEL_STOP",
        }) do
            f:RegisterUnitEvent(e, "player")
        end
        C_Timer.NewTicker(0.25, Tick)
        SetUpDoesItDie()
    elseif event == "UNIT_SPELLCAST_SENT" then
        -- arg3 = castGUID; the target is read now, before a cast time lets it change
        local attackable = UnitCanAttack("player", "target")
        if arg3 and canaccess(arg3) and canaccess(attackable) and attackable then
            sentTarget[arg3] = ReadableGUID("target")
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        OnSpellSucceeded(arg2, arg3)
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        OnChannelStop()
    elseif event == "UNIT_SPELLCAST_START" then
        if db.cast then OnCastStart(arg2, arg3) end
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        OnCastFailed(arg2)
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- let the nameplate addon finish setting up its plate first
        C_Timer.After(0, function() if UnitExists(arg1) then UpdateUnit(arg1) end end)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local o = byUnit[arg1]
        if o then HideOverlay(o) end
    elseif event == "UNIT_HEALTH" then
        local o = byUnit[arg1]
        if o then
            local dead = UnitIsDead(arg1)
            if canaccess(dead) and dead then
                if o.guid then dots[o.guid] = nil end
                HideOverlay(o)
            else
                UpdateText(o)
            end
        end
    elseif event == "UNIT_MAXHEALTH" or event == "UNIT_FACTION" then
        if byUnit[arg1] or (arg1 and arg1:find("^nameplate")) then UpdateUnit(arg1) end
    else
        UpdateAll()
    end
end)

---------------------------------------------------------------------------
-- /wandbar
---------------------------------------------------------------------------
local TOGGLES = {
    wand = "one wand shot (pale band)",
    dots = "DoT and channel bands",
    cast = "the hit of the spell you are casting (yellow band)",
    text = "\"kill\" / \"xN\" wand shots beside the plate",
}

local function OnOff(v) return v and "|cff80ff80on|r" or "|cffff8080off|r" end

local function PrintHelp()
    Say("damage still coming, on enemy nameplates")
    print("  /wandbar - status")
    print("  /wandbar on | off - everything")
    for _, k in ipairs({ "wand", "dots", "cast", "text" }) do
        print(("  /wandbar %s - toggle %s"):format(k, TOGGLES[k]))
    end
    print("  /wandbar clear - forget the DoTs tracked so far")
    print("  /wandbar reset - all settings back to defaults")
end

local function PrintStatus()
    Say(("%s | wand %s, dots %s, cast %s, text %s"):format(OnOff(db.enabled), OnOff(db.wand),
        OnOff(db.dots), OnOff(db.cast), OnOff(db.text)))
    print("  Wand shot: " .. (wandDamage and ("%.1f average"):format(wandDamage)
        or "no wand equipped"))
    local names = {}
    for _, def in ipairs(classDots) do names[#names + 1] = def.name end
    print("  DoTs: " .. (#names > 0 and table.concat(names, ", ")
        or "none known for your class (casts and wand only)"))
    if DoesItDie and DoesItDie.GetDoTs then
        print("  DoT sizes: DoesItDie's, learned from real ticks")
    end
    print("  /wandbar help for commands")
end

SLASH_WANDBAR1 = "/wandbar"
SlashCmdList.WANDBAR = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "help" or msg == "?" then
        PrintHelp()
        return
    elseif msg == "on" or msg == "off" then
        db.enabled = (msg == "on")
    elseif TOGGLES[msg] then
        db[msg] = not db[msg]
    elseif msg == "clear" then
        wipe(dots)
        wipe(pending)
    elseif msg == "reset" then
        for k, v in pairs(DEFAULTS) do db[k] = v end
    elseif msg ~= "" then
        Say("unknown command '" .. msg .. "'")
        PrintHelp()
        return
    end
    UpdateAll()
    PrintStatus()
end
