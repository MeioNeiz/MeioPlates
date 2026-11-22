-- MeioPlates: on enemy nameplate health bars, the damage that is still coming, as bands that
-- eat back from the end of the health fill; what stays uncovered is the health the mob will
-- have left. From the health edge back:
--   yellow band: the direct hit of the spell you are casting / just cast
--   channel band: what is left of the drain / Mind Flay you are channelling
--   DoT bands: one per DoT you applied, in its colour (Spells.lua), shrinking tick by
--     tick; grey for a DoT DoesItDie tracks that Spells.lua doesn't know
--   pale band: one of your main attacks after all that (wand shot, Auto Shot, melee swing
--     or main spell, plus your pet's damage meanwhile), with a white line at its end
--   text: "kill" when the DoTs finish the mob, else "xN" main attacks still needed
--   soul shard icon (warlocks): what the DoTs leave is within one Drain Soul channel
--   crowd control icon left of the bar with the seconds left of your Fear, Banish etc.
-- The mob's tooltip lists every attack's count; Shift adds each DoT.
--
-- WoW Forever closes the combat log to addons, so DoTs are estimated from your casts (target,
-- time, the rank's tooltip damage) and counted down tick by tick. Forever's tooltip numbers
-- already include spell power, so it is not added again.
-- With DoesItDie loaded, its numbers (learned from real ticks) replace the estimates; with
-- MeioDPS loaded, its per-hit damage (learned from the damage meter) replaces ours.
--
-- Enemy health can be a secret value on this client. The bands never do maths on it: each is
-- a StatusBar whose range is the (maybe secret) max health and whose value is our own number,
-- so the client places it. The text needs real numbers and stays hidden while health is
-- secret.

local ADDON, ns = ...
local canaccess = canaccessvalue or function() return true end

local function Say(msg) print("|cffb090ff" .. ADDON .. ":|r " .. msg) end

local ATTACK_COLOR = { 1, 1, 1, 0.45 }
local EDGE_COLOR = { 1, 1, 1, 0.95 }
local TEXT_COLOR = { 1, 1, 1 }
local KILL_COLOR = { 0.4, 1, 0.4 }
local CAST_COLOR = { 1.00, 0.90, 0.15, 0.95 }
local OTHER_COLOR = { 0.75, 0.75, 0.75, 0.95 }
local CAST_FLIGHT = 1.0 -- seconds a cast's band stays after it leaves your hands
-- a projectile DoT's first tick came 3.6 to 3.9 s after the cast instead of 3 s
local DOT_TRAVEL = 0.75
local SCHOOLS = {
    holy = 2, fire = 3, nature = 4, frost = 5, shadow = 6, arcane = 7, frostfire = 8,
}
local SHARD_ICON = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02"

local DEFAULTS = {
    enabled = true, attack = true, count = "auto", pet = true, dots = true, cast = true,
    text = true, tooltip = true, drainSoul = true, shardCap = 20, cc = true,
}
local db, charDB

local DOTS = {} -- spell name or alias -> DoT definition
local CONSUMES = {} -- spell name -> name of the DoT it ends
local ORDER = {} -- DoT definitions in band order: yours first, channels before the rest
local classDots = {} -- the player's class's DoTs

local overlays = {} -- healthbar -> overlay
local byUnit = {} -- nameplate unit -> overlay
local dots = {} -- mob GUID -> { [dot name] = { start, interval, ticks, perTick, ... } }
local sentTarget = {} -- castGUID -> target GUID when the cast was sent
local pending = {} -- mob GUID -> { amount, castGUID, expires } for a direct hit on its way
local attacks = {} -- kind -> attack (see ReadAttacks), what you have now
local mainAttack -- the attack the pale band and "xN" count in, or nil
local petDPS -- your pet's damage per second, nil without a pet that melees
local activeChannel -- { guid, name, time, speeds, rate } of the DoT you are channelling
local lastCast -- { spellID, guid, time, def }: one cast reports SUCCEEDED and CHANNEL_START
local cc = {} -- mob GUID -> { [cc name] = { expires, icon, start, pet } }, kept off-plate
local CCS = {} -- spell name -> crowd control definition (Spells.lua)
local subjugate -- { expires, start, oldPet, petGUID, warned } while a demon is enslaved
local shardCount, bagRoom = 0, false -- soul shards in bags, any free bag slot
local isWarlock, playerClass

local function BuildSpellTables()
    local _, class = UnitClass("player")
    playerClass = class
    isWarlock = class == "WARLOCK"
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
    if ns.CC_CLASSES[class] then
        for _, def in ipairs(ns.CC) do CCS[def.name] = def end
    end
end

local function Number(v)
    if v ~= nil and canaccess(v) and type(v) == "number" then return v end
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
    -- "1,250", "128.1 to 139.9  frost damage": whole numbers, single spaces
    text = text:lower():gsub("(%d),(%d)", "%1%2"):gsub("  +", " ")
    return (text:gsub("%d+%.%d+", function(n) return tostring(math.floor(n + 0.5)) end))
end

local function RangedAttackPower()
    if not UnitRangedAttackPower then return 0 end
    local base, pos, neg = UnitRangedAttackPower("player")
    base, pos, neg = Number(base), Number(pos) or 0, Number(neg) or 0
    return base and math.max(0, base + pos + neg) or 0
end

-- tooltips include spell power, which gear and buffs change: re-read them now and then
local CACHE_SECONDS = 10

-- The rank's periodic total and duration from its tooltip
local periodicCache = {}
local function PeriodicDamage(spellID)
    local cached = periodicCache[spellID]
    if cached and GetTime() - cached[3] < CACHE_SECONDS then return cached[1], cached[2] end
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
        -- Black Arrow: "causing 150 shadow damage and draining 150 mana over 30 sec"
        total, duration = text:match("(%d+) %a+ damage and [^%.]- over (%d+) sec")
        total, duration = tonumber(total), tonumber(duration)
    end
    if not total then
        -- "transfers 10 health every 1 second ... lasts 5 sec",
        -- "transfers 11 health from the target to the caster every 3 sec. lasts 30 sec",
        -- Wrack: "for 6 sec, inflicting 25 shadow damage every 1 sec"
        local per, every = text:match("(%d+) health .-every (%d+) sec")
        if not per then per, every = text:match("(%d+) %a+ damage every (%d+) sec") end
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
    periodicCache[spellID] = { total, duration, GetTime() }
    return total, duration
end

-- The rank's direct (non-periodic) damage from its tooltip, or nil
local directCache = {}
local function DirectDamage(spellID, name)
    if ns.NOT_DIRECT[name] then return nil end
    local entry = directCache[spellID]
    local cached
    if entry and GetTime() - entry[2] < CACHE_SECONDS then cached = entry[1] end
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
            for n, s, rest in text:gmatch("(%d+) (%a+) damage([^%.]*)") do
                local periodic = rest:find("^ over") or rest:find("^ after")
                    or rest:find("^ every") or rest:find("^ and [^,]- over %d")
                if SCHOOLS[s] and not periodic then
                    base, school = tonumber(n), s
                    break
                end
            end
        end
        if base and SCHOOLS[school] then cached = base end
        directCache[spellID] = { cached, GetTime() }
    end
    return cached or nil
end

---------------------------------------------------------------------------
-- Attacks: what the pale band and "xN" count in
---------------------------------------------------------------------------
local ATTACK_NAMES = { wand = "Wand", shot = "Auto Shot", melee = "Melee" }
-- per class, the attacks worth counting in, best first; "auto" takes the first you have
local CLASS_ATTACKS = {
    WARLOCK = { "wand", "spell" }, MAGE = { "wand", "spell" }, PRIEST = { "wand", "spell" },
    HUNTER = { "shot", "melee" }, WARRIOR = { "melee" }, ROGUE = { "melee" },
    PALADIN = { "melee", "spell" }, SHAMAN = { "melee", "spell" },
    DRUID = { "spell", "melee" },
}
local MELEE_FORMS = { [1] = true, [5] = true, [8] = true } -- cat, bear, dire bear
local GCD = 1.5

local function ClassAttacks()
    local form = playerClass == "DRUID" and GetShapeshiftFormID and GetShapeshiftFormID()
    if form and MELEE_FORMS[form] then return { "melee" } end
    return CLASS_ATTACKS[playerClass] or { "melee" }
end

-- "wand" or "shot" for the ranged weapon you hold, nil for none
local function RangedKind()
    if HasWandEquipped and HasWandEquipped() then return "wand" end
    local id = GetInventoryItemID("player", INVSLOT_RANGED or 18)
    if not id then return nil end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
    if classID ~= 2 then return nil end
    return subClassID == 19 and "wand" or "shot"
end

-- UnitDamage / UnitRangedDamage include buffs and percent modifiers (the character sheet's
-- numbers). The off hand swings on its own timer: its share of one main-hand swing.
local function MeleeHit(unit)
    local lo, hi, offLo, offHi = UnitDamage(unit)
    local speed, offSpeed = UnitAttackSpeed(unit)
    lo, hi, speed = Number(lo), Number(hi), Number(speed)
    if not (lo and hi and speed and hi > 0 and speed > 0) then return nil end
    local hit = (lo + hi) / 2
    offLo, offHi, offSpeed = Number(offLo), Number(offHi), Number(offSpeed)
    if offLo and offHi and offSpeed and offHi > 0 and offSpeed > 0 then
        hit = hit + (offLo + offHi) / 2 * speed / offSpeed
    end
    return hit, speed
end

-- Your main spell: the direct damage spell you cast most on this character, else your
-- class's usual one (Spells.lua) once you know it
local function MainSpell()
    local best
    for _, c in pairs(charDB.casts) do
        if not best or c.n > best.n then best = c end
    end
    if best then return best.id end
    local name = ns.MAIN_SPELL[playerClass]
    local info = name and C_Spell.GetSpellInfo(name)
    local id = info and info.spellID
    if id and canaccess(id) and C_SpellBook.IsSpellKnown(id) then return id end
end

local function CountSpellCast(spellID, name)
    local c = charDB.casts[name] or { n = 0 }
    c.n, c.id = c.n + 1, spellID
    charDB.casts[name] = c
end

-- MeioDPS's numbers when it is loaded: per cast as the damage meter measured it, else its
-- own reading of the spell or weapon; nil when it has none, so ours stand
local function DPSApi()
    local api = type(MeioDPS) == "table" and MeioDPS.API
    return type(api) == "table" and api or nil
end

local function Positive(v)
    v = Number(v)
    return v and v > 0 and v or nil
end

local function MeioDPSSpell(spellID)
    local api = DPSApi()
    if not api then return nil end
    local measured = type(api.Measured) == "function" and Positive(api.Measured(spellID))
    if measured then return measured end
    local d = type(api.SpellDamage) == "function" and api.SpellDamage(spellID)
    return type(d) == "table" and Positive(d.direct) or nil
end

-- average per hit and seconds per hit; melee folds the off hand into one main-hand swing
local function MeioDPSAuto(kind)
    local api = DPSApi()
    local auto = api and type(api.AutoAttack) == "function" and api.AutoAttack
    if not auto then return nil end
    if kind ~= "melee" then
        local hit, speed = auto(kind == "shot" and "ranged" or "wand")
        hit, speed = Positive(hit), Positive(speed)
        if hit and speed then return hit, speed end
        return nil
    end
    local hit, speed = auto("main")
    hit, speed = Positive(hit), Positive(speed)
    if not (hit and speed) then return nil end
    local off, offSpeed = auto("off")
    off, offSpeed = Positive(off), Positive(offSpeed)
    if off and offSpeed then hit = hit + off * speed / offSpeed end
    return hit, speed
end

-- the Imp casts Firebolt rather than meleeing, so its damage isn't in UnitDamage
local function ReadPetDPS()
    if not UnitExists("pet") then return nil end
    local family = UnitCreatureFamily and UnitCreatureFamily("pet")
    if family and canaccess(family) and family == "Imp" then return nil end
    local hit, speed = MeleeHit("pet")
    return hit and hit / speed
end

local function ReadAttacks()
    wipe(attacks)
    local ranged = RangedKind()
    if ranged then
        local speed, lo, hi = UnitRangedDamage("player")
        speed, lo, hi = Number(speed), Number(lo), Number(hi)
        if speed and lo and hi and hi > 0 and speed > 0 then
            attacks[ranged] = { hit = (lo + hi) / 2, seconds = speed }
        end
    end
    local hit, speed = MeleeHit("player")
    if hit then attacks.melee = { hit = hit, seconds = speed } end
    local id = MainSpell()
    local name = id and C_Spell.GetSpellName(id)
    hit = name and DirectDamage(id, name)
    if hit then
        local info = C_Spell.GetSpellInfo(id)
        local cast = info and Number(info.castTime) or 0
        attacks.spell = { hit = hit, seconds = math.max(cast / 1000, GCD), spellID = id,
            name = name }
    end
    for kind, a in pairs(attacks) do
        a.kind, a.name = kind, a.name or ATTACK_NAMES[kind]
        if kind == "spell" then
            a.hit = MeioDPSSpell(a.spellID) or a.hit
        else
            local hit, speed = MeioDPSAuto(kind)
            if hit then a.hit, a.seconds = hit, speed end
        end
    end
    petDPS = db.pet and ReadPetDPS() or nil
    mainAttack = attacks[db.count]
    if not mainAttack then
        for _, kind in ipairs(ClassAttacks()) do
            mainAttack = mainAttack or attacks[kind]
        end
    end
end

-- whether your pet is attacking this mob
local function PetOn(guid)
    return petDPS ~= nil and guid ~= nil and ReadableGUID("pettarget") == guid
end

-- one attack, plus what your pet does to the mob in the time it takes
local function PerAttack(a, guid)
    if PetOn(guid) then return a.hit + petDPS * a.seconds end
    return a.hit
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
    -- tooltip damage shared by the ticks' weights, plus the ranged attack power bonus on each
    -- tick (Serpent Sting's tooltip leaves it out)
    local perTick = (total + (def.rapCoef or 0) * RangedAttackPower() * ticks) / weightSum
    dots[guid] = dots[guid] or {}
    dots[guid][def.name] = {
        start = GetTime() + (def.travel and DOT_TRAVEL or 0), interval = def.interval,
        ticks = ticks, perTick = perTick, weights = weights, aura = castName or def.name,
        guid = guid, name = def.name, boost = 0,
    }
end

-- Seconds the channel has sped this DoT up by (Wrack), up to now
local function LiveBoost(d, now)
    local c = activeChannel
    if not (c and c.rate and c.guid == d.guid and c.speeds[d.name]) then return 0 end
    return math.max(0, now - math.max(c.time, d.start)) * c.rate
end

-- The DoT's own clock: time since its start, plus what a channel has sped it up by
local function Elapsed(d, now)
    return now - d.start + d.boost + LiveBoost(d, now)
end

local function DotRemaining(d, now)
    local done = math.max(0, math.floor(Elapsed(d, now) / d.interval + 0.001))
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

-- DoesItDie's per-DoT numbers on this unit by DoT name, plus the total of the DoTs MeioPlates
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
-- in for it. all: ignore the cast / dots display settings (for the public API).
local function Segments(unit, guid, now, verify, all)
    local segs = {}
    local hit = guid and (all or db.cast) and pending[guid]
    if hit and hit.expires > now then segs[#segs + 1] = { "cast", hit.amount } end
    if not (all or db.dots) then return segs end
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
    local tp = rawget(plate, "TPFrame")
    local bar = tp and tp.visual and tp.visual.Healthbar
    if bar then return bar end
    local uf = plate.UnitFrame
    bar = uf and (uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar or uf.healthBar)
    if bar and not bar:IsForbidden() then return bar end
end

-- Threat Plates' text layer on this unit's plate (health text, name), or nil on other plates
local function TextFrameFor(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    local tp = plate and rawget(plate, "TPFrame")
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
    AnchorBand(o, o.attack)
    for _, band in pairs(o.bands) do AnchorBand(o, band) end
    -- the white line marks where one main attack after everything else would leave the mob
    local tex = o.attack:GetStatusBarTexture()
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

    o.attack = NewBand(clip, ATTACK_COLOR)
    local edge = o.attack:CreateTexture(nil, "OVERLAY")
    edge:SetColorTexture(unpack(EDGE_COLOR))
    edge:SetWidth(1)
    o.edge = edge

    local text = hb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", hb, "RIGHT", 3, 0)
    text:Hide()
    o.text = text

    local shard = hb:CreateTexture(nil, "OVERLAY")
    shard:SetSize(14, 14)
    shard:SetTexture(C_Item.GetItemIconByID and C_Item.GetItemIconByID(ns.SOUL_SHARD)
        or SHARD_ICON)
    shard:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    shard:Hide()
    o.shard = shard

    local ccIcon = hb:CreateTexture(nil, "OVERLAY")
    ccIcon:SetSize(16, 16)
    ccIcon:SetPoint("RIGHT", hb, "LEFT", -3, 0)
    ccIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ccIcon:Hide()
    o.ccIcon = ccIcon
    -- a frame above the icon, so the seconds draw over it
    local ccTextFrame = CreateFrame("Frame", nil, hb)
    ccTextFrame:SetAllPoints(ccIcon)
    ccTextFrame:SetFrameLevel(SafeLevel(hb) + 20)
    local ccText = ccTextFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local font, size = ccText:GetFont()
    if font then ccText:SetFont(font, size or 10, "OUTLINE") end
    ccText:SetPoint("CENTER", ccIcon, "CENTER", 0, 0)
    o.ccText = ccText
    o.ccTextFrame = ccTextFrame
    ccTextFrame:Hide()

    hb:HookScript("OnSizeChanged", function() if o.unit then LayoutOverlay(o) end end)
    overlays[hb] = o
    return o
end

local function HideOverlay(o)
    o.clip:Hide()
    o.text:Hide()
    o.shard:Hide()
    o.ccIcon:Hide()
    o.ccTextFrame:Hide()
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

---------------------------------------------------------------------------
-- Drain Soul cue
---------------------------------------------------------------------------
-- ShardKeeper, when loaded, owns the shard cap (nil from its Cap(): no cap)
function ns.UsesShardKeeper()
    return type(ShardKeeper) == "table" and type(ShardKeeper.Cap) == "function"
end

-- ShardKeeper's own count can lag the bag event we count on, so only its cap is borrowed;
-- the cap is read live because changing it fires no event here
local function CountShards()
    if not isWarlock then return end
    local count = C_Item.GetItemCount(ns.SOUL_SHARD)
    local free = 0
    if C_Container and C_Container.GetContainerNumFreeSlots then
        for bag = 0, NUM_BAG_SLOTS or 4 do
            free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
        end
    end
    shardCount, bagRoom = Number(count) or 0, (Number(free) or 0) > 0
end

-- A shard only comes when there is room for it, and only when you want more
local function ShardRoom()
    local cap = db.shardCap or DEFAULTS.shardCap
    if ns.UsesShardKeeper() then cap = ShardKeeper.Cap() end
    return bagRoom and (not cap or shardCount < cap)
end

-- Your best Drain Soul's damage over one full channel, or nil before you learn it
local function DrainSoulDamage()
    for _, id in ipairs(ns.DRAIN_SOUL) do
        if C_SpellBook.IsSpellKnown(id) then return (PeriodicDamage(id)) end
    end
end

local function CueWanted()
    return isWarlock and db.drainSoul and ShardRoom()
end

-- hp is a readable number: what the DoTs (coming) leave of it dies inside one Drain Soul
-- channel, on a mob that gives shards, and you aren't draining it already
local function DrainSoulCue(unit, guid, hp, coming)
    if not CueWanted() then return false end
    if guid and dots[guid] and dots[guid]["Drain Soul"] then return false end
    local trivial = UnitIsTrivial and UnitIsTrivial(unit)
    if trivial ~= nil and (not canaccess(trivial) or trivial) then return false end
    local ds = DrainSoulDamage()
    return ds ~= nil and hp - coming <= ds
end

local function UpdateText(o)
    o.text:Hide()
    o.shard:Hide()
    if not o.unit then return end
    local hp = Number(UnitHealth(o.unit))
    if not hp or hp <= 0 then return end
    local left = hp - o.dotTotal
    if not db.text then
        -- no text
    elseif o.dotTotal > 0 and left <= 0 then
        o.text:SetText("kill")
        o.text:SetTextColor(unpack(KILL_COLOR))
        o.text:Show()
    elseif o.per then
        o.text:SetFormattedText("x%d", math.ceil(left / o.per))
        o.text:SetTextColor(unpack(TEXT_COLOR))
        o.text:Show()
    end
    if DrainSoulCue(o.unit, o.guid, hp, o.dotTotal) then
        o.shard:ClearAllPoints()
        if o.text:IsShown() then
            o.shard:SetPoint("LEFT", o.text, "RIGHT", 2, 0)
        else
            o.shard:SetPoint("LEFT", o.healthbar, "RIGHT", 3, 0)
        end
        o.shard:Show()
    end
end

---------------------------------------------------------------------------
-- Crowd control timers
---------------------------------------------------------------------------
local CC_SOON = 3 -- seconds left when the count turns red

-- The CC on this mob that holds it longest, dropping finished ones and, when `verify`,
-- ones whose debuff is gone (resisted, broken by damage) while debuffs can be read
local function MobCC(unit, guid, now, verify)
    local list = guid and cc[guid]
    if not list then return nil end
    local seen = verify and PlayerDebuffs(unit)
    local best
    for name, c in pairs(list) do
        -- a pet's debuff is not yours, so the PLAYER filter never lists it
        local gone = seen and not c.pet and not seen[name] and now - c.start > 0.5
        if c.expires <= now or gone then
            list[name] = nil
        elseif not best or c.expires > best.expires then
            best = c
        end
    end
    if not next(list) then cc[guid] = nil end
    return best
end

local function UpdateCC(o, verify)
    local c = db.cc and o.unit and MobCC(o.unit, o.guid, GetTime(), verify)
    if not c then
        o.ccIcon:Hide()
        o.ccTextFrame:Hide()
        return
    end
    local left = c.expires - GetTime()
    o.ccIcon:SetTexture(c.icon)
    o.ccIcon:Show()
    o.ccText:SetFormattedText("%d", math.ceil(left))
    if left <= CC_SOON then
        o.ccText:SetTextColor(1, 0.5, 0.5)
    else
        o.ccText:SetTextColor(1, 1, 1)
    end
    o.ccTextFrame:Show()
end

local function UpdateUnit(unit, verify)
    local o = byUnit[unit]
    local now = GetTime()
    local guid = ReadableGUID(unit)
    local segs = Segments(unit, guid, now, verify)
    local dotTotal = 0
    for _, s in ipairs(segs) do dotTotal = dotTotal + s[2] end
    local per = db.attack and mainAttack and PerAttack(mainAttack, guid)
    local wanted = per or dotTotal > 0 or CueWanted() or (db.cc and guid and cc[guid])
    local hb = db.enabled and wanted and IsEnemy(unit) and HealthBarFor(unit)
    if not hb then
        if o then HideOverlay(o) end
        return
    end
    if o and o.healthbar ~= hb then HideOverlay(o) end
    o = GetOverlay(hb)
    if o.unit and o.unit ~= unit and byUnit[o.unit] == o then byUnit[o.unit] = nil end
    if o.unit ~= unit then o.unit = unit; LayoutOverlay(o) end
    byUnit[unit] = o
    o.guid = guid
    o.dotTotal = dotTotal
    o.per = per or nil

    -- max health may be secret: it only ever goes into the StatusBars.
    -- Each band runs back from the health edge by its cumulative value, so the shorter
    -- (nearer) ones must lie on top of the longer ones.
    local maxHealth = UnitHealthMax(unit)
    local base = SafeLevel(o.healthbar) + 1
    local top = base + #segs + (per and 1 or 0)
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
    if per then
        o.attack:SetFrameLevel(math.max(top - #segs, base + 1))
        o.attack:SetMinMaxValues(0, maxHealth)
        o.attack:SetValue(cum + per)
        o.attack:Show()
    else
        o.attack:Hide()
    end
    o.clip:Show()
    -- Threat Plates draws its health text (and name, raid marker) on a text layer level with
    -- the health bar: lift it over the bands so they never cover it. Threat Plates resets it
    -- when it restyles the plate; the next update (every 0.25 s while DoTs run) lifts it
    -- again.
    local tf = TextFrameFor(unit)
    if tf and SafeLevel(tf) <= top then tf:SetFrameLevel(top + 1) end
    UpdateText(o)
    UpdateCC(o, verify)
end

local function ForEachPlateUnit(fn)
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if unit then fn(unit) end
    end
end

local function UpdateAll()
    ReadAttacks()
    CountShards()
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

-- The enslaved demon turns on you when Subjugate Demon ends: warn shortly before
local function CheckSubjugate(now)
    local sub = subjugate
    if not sub then return end
    -- no new pet after the cast (resisted): nothing to time
    if now >= sub.expires or (not sub.petGUID and now - sub.start > 10) then
        subjugate = nil
    elseif not sub.warned and sub.petGUID and sub.expires - now <= ns.SUBJUGATE.warnAt then
        sub.warned = true
        if db.enabled and db.cc then
            if UIErrorsFrame then
                UIErrorsFrame:AddMessage(("%s: %d sec left"):format(ns.SUBJUGATE.name,
                    ns.SUBJUGATE.warnAt), 1, 0.5, 0.5)
            end
            if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.RAID_WARNING) end
        end
    end
end

-- UNIT_PET: the demon you enslaved became your pet, or a different pet (or none) replaced
-- it, so the enslavement is over
local function OnPetChanged()
    local sub = subjugate
    if not sub then return end
    local pet = ReadableGUID("pet")
    if not sub.petGUID then
        if pet and pet ~= sub.oldPet then sub.petGUID = pet end
    elseif pet ~= sub.petGUID then
        subjugate = nil
    end
end

local function CCDuration(def, spellID)
    local seconds = def.ranks[spellID]
    if seconds then return seconds end
    local text = Description(spellID)
    return text and tonumber(text:match("(%d+) sec"))
end

-- a crowd control spell landed on the mob (guid); true when a plate needs redrawing
local function OnCCCast(guid, spellID, name, now, fromPet)
    if name == ns.SUBJUGATE.name and isWarlock and not fromPet then
        local pet = ReadableGUID("pet")
        subjugate = { start = now, expires = now + ns.SUBJUGATE.duration, oldPet = pet,
            petGUID = pet == guid and pet or nil }
        return false
    end
    local def = CCS[name]
    if not def or (def.pet or false) ~= (fromPet or false) then return false end
    local seconds = CCDuration(def, spellID)
    if not seconds then return false end
    if def.single then
        for other, list in pairs(cc) do
            if other ~= guid and list[name] then
                list[name] = nil
                if not next(list) then cc[other] = nil end
                UpdateGUID(other)
            end
        end
    end
    cc[guid] = cc[guid] or {}
    cc[guid][name] = { start = now, expires = now + seconds, pet = def.pet,
        icon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID) }
    return true
end

-- your pet finished a cast (Seduction), aimed at its target
local function OnPetSpellSucceeded(spellID)
    if not (spellID and canaccess(spellID)) then return end
    local guid = ReadableGUID("pettarget")
    local name = C_Spell.GetSpellName(spellID)
    if not (guid and name and canaccess(name)) then return end
    if OnCCCast(guid, spellID, name, GetTime(), true) then UpdateGUID(guid) end
end

-- DoT bands shrink tick by tick; finished DoTs are dropped; a plate's debuffs are re-checked
-- spell power and buffs change hit sizes without an event: re-read them now and then
local ATTACK_REFRESH = 5
local attacksRead = 0

local function Tick()
    local now = GetTime()
    local redraw
    if now - attacksRead >= ATTACK_REFRESH and next(byUnit) then
        attacksRead = now
        UpdateAll()
    end
    for guid, hit in pairs(pending) do
        if hit.expires <= now then
            pending[guid] = nil
            redraw = redraw or {}
            redraw[guid] = true
        end
    end
    CheckSubjugate(now)
    if not next(dots) and not redraw and not next(cc) then return end
    local shown = {}
    for unit, o in pairs(byUnit) do
        local guid = o.guid
        if guid and (dots[guid] or cc[guid] or (redraw and redraw[guid])) then
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
    for guid, list in pairs(cc) do
        if not shown[guid] then
            for name, c in pairs(list) do
                if c.expires <= now then list[name] = nil end
            end
            if not next(list) then cc[guid] = nil end
        end
    end
end

---------------------------------------------------------------------------
-- Casts
---------------------------------------------------------------------------

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

-- whether you are channelling spellID right now
local function Channelling(spellID)
    if not UnitChannelInfo then return false end
    local id = select(8, UnitChannelInfo("player"))
    return id ~= nil and canaccess(id) and id == spellID
end

-- Wrack's "deal their periodic damage 100% faster" as 1.0
local function SpeedUp(def, spellID)
    if not def.speedsUp then return nil end
    local text = Description(spellID)
    local pct = text and tonumber(text:match("(%d+)%% faster"))
    return (pct or 100) / 100
end

-- the channel ends: bank the time it gained the DoTs it sped up, and drop its own DoT
local function EndChannel(now)
    local c = activeChannel
    activeChannel = nil
    if not c then return end
    local list = dots[c.guid]
    if not list then return c end
    if c.rate then
        for _, d in pairs(list) do
            if c.speeds[d.name] then
                d.boost = d.boost + math.max(0, now - math.max(c.time, d.start)) * c.rate
            end
        end
    end
    list[c.name] = nil
    if not next(list) then dots[c.guid] = nil end
    return c
end

local function StartChannel(guid, def, spellID, now)
    local old = EndChannel(now)
    if old and old.guid ~= guid then UpdateGUID(old.guid) end
    local speeds = {}
    for _, n in ipairs(def.speedsUp or {}) do speeds[n] = true end
    activeChannel = { guid = guid, name = def.name, time = now, speeds = speeds,
        rate = SpeedUp(def, spellID) }
end

-- isChannel: the event was CHANNEL_START. Spells that are channelled on some ranks only
-- (Drain Life) are channels only when the client says so.
local function OnSpellSucceeded(castGUID, spellID, isChannel)
    if not (spellID and canaccess(spellID)) then return end
    local now = GetTime()
    local last = lastCast
    if last and last.spellID == spellID and now - last.time < 0.5 then
        -- the same cast's second event: only learn that it is a channel
        if last.def and last.def.channel and isChannel and not activeChannel then
            StartChannel(last.guid, last.def, spellID, last.time)
        end
        return
    end
    local guid, name = CastTarget(castGUID, spellID, true)
    if not guid then return end
    local changed = OnCCCast(guid, spellID, name, now)
    -- the spell left your hands: its hit lands about a second from now
    local direct = DirectDamage(spellID, name)
    -- a nuke, not a DoT with a small opening hit (Moonfire, Immolate)
    if direct and direct > (PeriodicDamage(spellID) or 0) then
        CountSpellCast(spellID, name)
        if MainSpell() ~= (attacks.spell and attacks.spell.spellID) then ReadAttacks() end
    end
    local amount = db.cast and direct
    if amount then
        local expires = now + CAST_FLIGHT
        pending[guid] = { amount = amount, castGUID = castGUID, expires = expires }
        changed = true
    end
    local def = DOTS[name]
    lastCast = { spellID = spellID, guid = guid, time = now, def = def }
    if def then
        AddDot(guid, spellID, def, name)
        if def.channel and (isChannel or Channelling(spellID)) then
            StartChannel(guid, def, spellID, now)
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
    local c = EndChannel(GetTime())
    if c then UpdateGUID(c.guid) end
end

---------------------------------------------------------------------------
-- Mob tooltip: each attack's count to kill; Shift adds each DoT, hit sizes and your pet
---------------------------------------------------------------------------
local LABEL = { 1, 0.82, 0 }
local VALUE = { 1, 1, 1 }

local function Round(v) return math.floor(v + 0.5) end

local function Line(tt, label, value, color, labelColor)
    color, labelColor = color or VALUE, labelColor or LABEL
    tt:AddDoubleLine(label, value, labelColor[1], labelColor[2], labelColor[3], color[1],
        color[2], color[3])
end

-- one "Shift: more" per tooltip across the Meio addons; cleared with the tooltip
local function AddShiftHint(tt)
    if tt.meioShiftHint then return end
    tt.meioShiftHint = true
    tt:AddLine("|cff999999Shift: more|r")
end

-- your class's attacks you have, the one the plate counts in first
local function ListedAttacks()
    local list = { mainAttack }
    for _, kind in ipairs(ClassAttacks()) do
        local a = attacks[kind]
        if a and a ~= mainAttack then list[#list + 1] = a end
    end
    return list
end

local function AddTooltipLines(tt, unit)
    if not (db.enabled and db.tooltip and IsEnemy(unit)) then return end
    local hp = Number(UnitHealth(unit))
    local guid = ReadableGUID(unit)
    if not (hp and hp > 0 and guid) then return end
    local segs = Segments(unit, guid, GetTime(), false, true)
    local coming = 0
    for _, s in ipairs(segs) do coming = coming + s[2] end
    local list = db.attack and ListedAttacks() or {}
    if coming <= 0 and #list == 0 then return end
    tt.meioPlatesUnit = true
    local left = hp - coming
    if coming > 0 then
        Line(tt, "Damage coming", left <= 0 and Round(coming) .. ", kills it" or Round(coming),
            left <= 0 and KILL_COLOR or nil)
    end
    local pet = PetOn(guid) and " + pet" or ""
    if left > 0 then
        for _, a in ipairs(list) do
            Line(tt, a.name .. pet .. " to kill", ("x%d"):format(math.ceil(left / PerAttack(a,
                guid))))
        end
    end
    if not IsShiftKeyDown() then
        AddShiftHint(tt)
        return
    end
    for _, s in ipairs(segs) do
        local def = DOTS[s[1]]
        local name = s[1] == "cast" and "Your cast" or s[1] == "other" and "Other DoTs" or s[1]
        local color = s[1] == "cast" and CAST_COLOR or def and def.color or OTHER_COLOR
        Line(tt, "  " .. name, Round(s[2]), nil, color)
    end
    for _, a in ipairs(list) do
        Line(tt, "  " .. a.name, ("%d every %.1f sec"):format(Round(a.hit), a.seconds))
    end
    if petDPS then
        Line(tt, "  Pet" .. (pet == "" and " (not on this mob)" or ""),
            ("%d a second"):format(Round(petDPS)))
    end
end

function ns.RefreshTooltip()
    local tt = GameTooltip
    if not (tt and tt:IsShown() and tt.meioPlatesUnit) then return end
    local _, unit = tt:GetUnit()
    if unit and canaccess(unit) and UnitExists(unit) then tt:SetUnit(unit) end
end

local function SetUpTooltip()
    if not (TooltipDataProcessor and Enum.TooltipDataType) then return end
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt)
        if tt ~= GameTooltip then return end
        local _, unit = tt:GetUnit()
        if unit and canaccess(unit) then AddTooltipLines(tt, unit) end
    end)
    GameTooltip:HookScript("OnTooltipCleared", function(tt)
        tt.meioPlatesUnit, tt.meioShiftHint = nil, nil
    end)
end

---------------------------------------------------------------------------
-- DoesItDie
---------------------------------------------------------------------------
-- Once: make DoesItDie's nameplate marker invisible (its kill skull stays), since MeioPlates
-- draws the same DoTs there per spell. Plate settings only; its target frame marker is
-- untouched. /did can turn it back on, and MeioPlates won't redo it. Silent at login;
-- /meioplates status says so.
local function SetUpDoesItDie()
    if type(DoesItDieDB) == "table" and not db.didPlateStyled then
        DoesItDieDB.plateFillOpacity = 0
        DoesItDieDB.plateOutlineStyle = "none"
        db.didPlateStyled = true
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
        MeioPlatesDB = MeioPlatesDB or {}
        db = MeioPlatesDB
        for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
        ns.db = db
        MeioPlatesCharDB = MeioPlatesCharDB or {}
        charDB = MeioPlatesCharDB
        charDB.casts = charDB.casts or {}
        BuildSpellTables()
        ns.isWarlock = isWarlock
        ns.SetCCTip()
        for _, e in ipairs({
            "PLAYER_ENTERING_WORLD", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
            "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_FACTION", "PLAYER_EQUIPMENT_CHANGED",
            "BAG_UPDATE_DELAYED", "UPDATE_SHAPESHIFT_FORM", "MODIFIER_STATE_CHANGED",
        }) do
            f:RegisterEvent(e)
        end
        for _, e in ipairs({
            "UNIT_RANGEDDAMAGE", "UNIT_INVENTORY_CHANGED", "UNIT_SPELLCAST_SENT",
            "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_FAILED",
            "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_START",
            "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_PET",
        }) do
            f:RegisterUnitEvent(e, "player")
        end
        for _, e in ipairs({ "UNIT_DAMAGE", "UNIT_ATTACK_SPEED", "UNIT_TARGET" }) do
            f:RegisterUnitEvent(e, "player", "pet")
        end
        f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
        C_Timer.NewTicker(0.25, Tick)
        SetUpDoesItDie()
        SetUpTooltip()
    elseif event == "UNIT_SPELLCAST_SENT" then
        -- arg3 = castGUID; the target is read now, before a cast time lets it change
        local attackable = UnitCanAttack("player", "target")
        if arg3 and canaccess(arg3) and canaccess(attackable) and attackable then
            sentTarget[arg3] = ReadableGUID("target")
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and arg1 == "pet" then
        OnPetSpellSucceeded(arg3)
    elseif event == "UNIT_PET" then
        OnPetChanged()
        UpdateAll()
    elseif event == "MODIFIER_STATE_CHANGED" then
        if arg1 == "LSHIFT" or arg1 == "RSHIFT" then ns.RefreshTooltip() end
    elseif event == "UNIT_TARGET" then
        if arg1 == "pet" then UpdateAll() end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        OnSpellSucceeded(arg2, arg3, event == "UNIT_SPELLCAST_CHANNEL_START")
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
                if o.guid then dots[o.guid], cc[o.guid] = nil, nil end
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
-- Public API, for other addons (ShardKeeper). Health is never read while it is secret.
--   MeioPlates.DamageComing(unit) -> number: damage still coming to the mob from you (hit in
--     flight, channel, DoTs; DoesItDie's sizes when it is loaded), 0 when nothing; nil when
--     the unit's GUID can't be read
--   MeioPlates.HealthLeft(unit) -> number: health the mob keeps after that (<= 0: it dies);
--     nil when its health is secret
--   MeioPlates.TimeToDie(unit) -> seconds until your hit in flight and DoT ticks kill it, from
--     MeioPlates' own tick schedule; nil when they won't, health is secret or nothing is
--     tracked
--   MeioPlates.DrainSoulCue(unit) -> true when MeioPlates shows its soul shard cue for the mob
---------------------------------------------------------------------------
local function Coming(unit)
    local guid = ReadableGUID(unit)
    if not guid then return nil end
    local total = 0
    for _, seg in ipairs(Segments(unit, guid, GetTime(), false, true)) do
        total = total + seg[2]
    end
    return total, guid
end

local function HealthLeft(unit)
    local coming, guid = Coming(unit)
    local hp = Number(UnitHealth(unit))
    if not (coming and hp) then return nil end
    return hp - coming, hp, coming, guid
end

MeioPlates = {
    DamageComing = function(unit) return (Coming(unit)) end,
    HealthLeft = function(unit) return (HealthLeft(unit)) end,
    DrainSoulCue = function(unit)
        local _, hp, coming, guid = HealthLeft(unit)
        return hp ~= nil and hp > 0 and DrainSoulCue(unit, guid, hp, coming)
    end,
    TimeToDie = function(unit)
        local guid = ReadableGUID(unit)
        local hp = Number(UnitHealth(unit))
        if not (guid and hp and hp > 0) then return nil end
        local now, hits = GetTime(), {}
        local hit = pending[guid]
        if hit and hit.expires > now then
            hits[#hits + 1] = { math.max(now, hit.expires - CAST_FLIGHT), hit.amount }
        end
        for _, d in pairs(dots[guid] or {}) do
            local e = Elapsed(d, now)
            for k = math.max(0, math.floor(e / d.interval + 0.001)) + 1, d.ticks do
                local w = d.weights and d.weights[k] or 1
                hits[#hits + 1] = { now + math.max(0, k * d.interval - e), d.perTick * w }
            end
        end
        table.sort(hits, function(x, y) return x[1] < y[1] end)
        for _, h in ipairs(hits) do
            hp = hp - h[2]
            if hp <= 0 then return h[1] - now end
        end
        return nil
    end,
}

---------------------------------------------------------------------------
-- /meioplates
---------------------------------------------------------------------------
local function OnOff(v) return v and "|cff80ff80on|r" or "|cffff8080off|r" end
local function Cmd(text) return "|cffffd100" .. text .. "|r" end

-- chat words, Settings labels and tooltips; Settings.lua builds its checkboxes from these
ns.TOGGLES = {
    { key = "attack", label = "Attack band", say = "pale attack band",
      tip = "Pale band with a white line: one of your main attacks after everything else "
          .. "(wand shot, Auto Shot, melee swing or main spell), plus what your pet does "
          .. "meanwhile when it attacks the same mob." },
    { key = "pet", label = "Count your pet", say = "your pet's damage in the counts",
      tip = "Your pet's damage, while it attacks the same mob, goes into the attack band "
          .. "and the counts. Not the Imp, which casts rather than melees." },
    { key = "dots", label = "DoT bands", say = "DoT and channel bands",
      tip = "A band per DoT and channel you put on the mob, in its colour, shrinking "
          .. "tick by tick." },
    { key = "cast", label = "Cast band", say = "yellow cast band",
      tip = "Yellow band: the hit of the spell you are casting, until it lands." },
    { key = "text", label = "Kill / xN text", say = "\"kill\" / \"xN\" text",
      tip = "Beside the plate: \"kill\" when your DoTs finish the mob, else \"xN\" main "
          .. "attacks still needed." },
    { key = "tooltip", label = "Tooltip lines", say = "lines on the mob's tooltip",
      tip = "On an enemy's tooltip: the damage coming and how many of each of your attacks "
          .. "it still takes. Shift: each DoT, hit sizes and your pet." },
    { key = "drainSoul", cmd = "drainsoul", label = "Drain Soul cue",
      classes = { WARLOCK = true },
      say = "Drain Soul shard icon",
      tip = "Soul shard icon beside the plate when what your DoTs leave of the mob dies "
          .. "inside one Drain Soul channel: channel it then for a shard. Only while you "
          .. "carry fewer shards than the cap and have a free bag slot." },
    -- tip: set for the player's class by ns.SetCCTip
    { key = "cc", label = "CC timers", classes = ns.CC_CLASSES,
      say = "crowd control timers" },
}

-- after BuildSpellTables, which knows the class
function ns.SetCCTip()
    local t
    for _, toggle in ipairs(ns.TOGGLES) do if toggle.key == "cc" then t = toggle end end
    local names = {}
    for _, def in ipairs(ns.CC) do
        if CCS[def.name] and def.name ~= "Seduction" then names[#names + 1] = def.name end
    end
    local tip = "Left of the plate: the icon and seconds left of your "
        .. table.concat(names, ", ")
    if isWarlock then
        tip = tip .. " (Howl: your target only) and your Succubus's Seduction. Subjugate "
            .. "Demon: a warning and a sound 5 sec before the demon breaks free"
    end
    t.tip = tip .. ". Timed from your casts, so one broken early in combat still counts down."
end

-- whether the toggle applies to the player's class
function ns.ToggleShown(t)
    return not t.classes or t.classes[select(2, UnitClass("player"))] == true
end

local function ColouredDots()
    local names = {}
    for _, def in ipairs(classDots) do
        local c = def.color
        names[#names + 1] = ("|cff%02x%02x%02x%s|r"):format(c[1] * 255, c[2] * 255,
            c[3] * 255, def.name)
    end
    return names
end
ns.ColouredDots = ColouredDots

-- what /meioplates count and the Settings dropdown offer
ns.COUNTS = {
    { "auto", "Auto: your class's usual" }, { "wand", "Wand shots" },
    { "shot", "Auto Shots" }, { "melee", "Melee swings" }, { "spell", "Main spell" },
}
local function CountLabel(kind)
    for _, c in ipairs(ns.COUNTS) do if c[1] == kind then return c[2] end end
end

local function AttackText(a)
    return ("%s %d every %.1f sec"):format(a.name, Round(a.hit), a.seconds)
end

local function PrintHelp()
    Say("damage still coming, on enemy nameplates")
    print("  " .. Cmd("/meioplates") .. " - open Settings")
    print("  " .. Cmd("/meioplates status") .. " - what is on, your attacks and DoT colours")
    print(("  %s - everything (now %s)"):format(Cmd("/meioplates on||off"), OnOff(db.enabled)))
    for _, t in ipairs(ns.TOGGLES) do
        if ns.ToggleShown(t) then
            print(("  %s - %s (now %s)"):format(Cmd("/meioplates " .. (t.cmd or t.key)
                .. " on||off"), t.say, OnOff(db[t.key])))
        end
    end
    print(("  %s - what the attack band and xN count in (now %s)"):format(
        Cmd("/meioplates count auto||wand||shot||melee||spell"), db.count))
    if isWarlock and ns.UsesShardKeeper() then
        print(("  %s - unused: ShardKeeper's cap applies (%s)"):format(
            Cmd("/meioplates shards N"), Cmd("/shards cap")))
    elseif isWarlock then
        print(("  %s - Drain Soul cue only below N shards (now %d)"):format(
            Cmd("/meioplates shards N"), db.shardCap))
    end
    print("  " .. Cmd("/meioplates clear")
        .. " - forget the DoTs and crowd control timers tracked so far")
    print("  " .. Cmd("/meioplates reset") .. " - all settings back to defaults")
    if attacks.wand then
        -- a plain /cast Shoot toggles: pressed while the wand fires, it stops shooting
        print("  |cff999999Tip: in wand macros write /cast !Shoot (also in castsequence), so "
            .. "a press never turns the wand off|r")
    end
    print("  Settings: Esc > Options > AddOns > MeioPlates ("
        .. Cmd("/meioplates settings") .. ")")
end

local function PrintStatus()
    local parts = {}
    for _, t in ipairs(ns.TOGGLES) do
        if ns.ToggleShown(t) then
            parts[#parts + 1] = (t.cmd or t.key) .. " " .. OnOff(db[t.key])
        end
    end
    Say(OnOff(db.enabled) .. " - " .. table.concat(parts, ", "))
    local picked = ""
    if db.count ~= "auto" then
        picked = attacks[db.count] and " (picked)"
            or (" (%s picked, but you have none)"):format(CountLabel(db.count))
    end
    print("  Counting in: " .. (mainAttack and AttackText(mainAttack) or "nothing yet")
        .. picked)
    for _, a in ipairs(ListedAttacks()) do
        if a ~= mainAttack then print("  Also: " .. AttackText(a)) end
    end
    if petDPS then
        print(("  Pet: %d a second, counted where it attacks"):format(Round(petDPS)))
    end
    local names = ColouredDots()
    print("  DoTs: " .. (#names > 0 and table.concat(names, ", ")
        or "none known for your class"))
    if DoesItDie and DoesItDie.GetDoTs then
        print("  DoT sizes: DoesItDie's, learned from real ticks. Its nameplate marker was "
            .. "hidden once, since the bands show the same (/did brings it back)")
    end
    if type(MeioDPS) == "table" and type(MeioDPS.API) == "table" then
        print("  Hit sizes: from MeioDPS (spells: what the damage meter measured)")
    end
    print("  " .. Cmd("/meioplates help") .. " for commands")
end

local function Refresh() UpdateAll() end
ns.Refresh = Refresh

SLASH_MEIOPLATES1 = "/meioplates"
SLASH_MEIOPLATES2 = "/wandbar"
SlashCmdList.MEIOPLATES = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    local word, arg = msg:match("^(%S+)%s*(.-)$")
    if msg == "" or msg == "settings" or msg == "options" then
        if not (ns.OpenSettings and ns.OpenSettings()) then PrintHelp() end
        return
    elseif msg == "help" or msg == "?" then
        PrintHelp()
        return
    elseif msg == "status" then
        UpdateAll()
        PrintStatus()
        return
    elseif msg == "on" or msg == "off" then
        db.enabled = (msg == "on")
        Say("bands " .. OnOff(db.enabled))
    elseif word == "shards" and tonumber(arg) then
        db.shardCap = math.max(1, math.floor(tonumber(arg)))
        if ns.UsesShardKeeper() then
            Say("ShardKeeper's cap applies to the Drain Soul cue: " .. Cmd("/shards cap N"))
        else
            Say(("Drain Soul cue below %d shards"):format(db.shardCap))
        end
    elseif word == "count" and CountLabel(arg) then
        db.count = arg
        Say("counting in " .. CountLabel(arg):lower())
    elseif msg == "clear" then
        wipe(dots)
        wipe(pending)
        wipe(cc)
        subjugate = nil
        Say("forgot the DoTs and crowd control timers tracked so far")
    elseif msg == "reset" then
        for k, v in pairs(DEFAULTS) do db[k] = v end
        Say("settings back to defaults")
    else
        local toggle
        for _, t in ipairs(ns.TOGGLES) do
            if word == (t.cmd or t.key):lower() then toggle = t end
        end
        if not (toggle and (arg == "" or arg == "on" or arg == "off")) then
            Say(("unknown command \"%s\""):format(msg))
            PrintHelp()
            return
        end
        if arg == "" then
            db[toggle.key] = not db[toggle.key]
        else
            db[toggle.key] = arg == "on"
        end
        Say(toggle.say .. " " .. OnOff(db[toggle.key]))
    end
    UpdateAll()
end
