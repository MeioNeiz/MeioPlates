-- MeioPlates' spell data. Add a DoT here and MeioPlates tracks it; nothing else needs
-- changing.
--
-- Tick intervals are this client's spell data (SpellEffect: EffectAuraPeriod). The damage and
-- duration of each rank are read from the spell's tooltip when you cast it, so new ranks need
-- no entry. Forever's tooltips already include spell power, so there are no spell power
-- coefficients here.
--
-- DoT fields:
--   name: spell name, which is also the debuff's name
--   aliases: other names the same DoT goes by
--   interval: seconds between ticks
--   rapCoef: damage added per tick per point of ranged attack power, which the tooltip
--     leaves out
--   channel: a channelled spell: its band sits nearest the health edge, and it ends when the
--     channel does (MeioPlates sees from each cast whether it was channelled)
--   speedsUp: while you channel it, these DoTs on the same mob tick faster by the tooltip's
--     "N% faster"
--   ramp: ticks grow, first third at half, middle third normal, last third at 1.5x
--   travel: a projectile, so the ticks start when it lands
--   consumedBy: a spell that ends the DoT
--   did: false when DoesItDie doesn't track it, so MeioPlates' estimate is always used
--   color: r, g, b, a of its band; only needs to differ within a class

local _, ns = ...

ns.DOTS = {
    WARLOCK = {
        -- the 15 s ranks (403677 to 403689) are not channelled
        { name = "Drain Life", interval = 1, channel = true,
          color = { 0.90, 0.15, 0.30, 0.95 } },
        { name = "Drain Soul", interval = 3, channel = true,
          color = { 0.30, 0.55, 1.00, 0.95 } },
        { name = "Wrack", interval = 1, channel = true,
          speedsUp = { "Siphon Life", "Corruption", "Bane of Agony" },
          color = { 1.00, 0.40, 0.80, 0.95 } },
        { name = "Immolate", interval = 3,
          consumedBy = "Conflagrate", color = { 1.00, 0.45, 0.10, 0.95 } },
        { name = "Corruption", interval = 3, color = { 0.62, 0.25, 0.95, 0.95 } },
        -- seen in game: 72 over 24 s ticked 3,3,3,3, 6,6,6,6, 9,9,9,9
        { name = "Bane of Agony", interval = 2,
          ramp = true, color = { 0.35, 0.80, 0.20, 0.95 } },
        { name = "Siphon Life", interval = 3, color = { 0.10, 0.60, 0.50, 0.95 } },
        -- one hit after a minute; DoesItDie can't read its "after 1 min" tooltip
        { name = "Bane of Doom", interval = 60,
          did = false, color = { 0.75, 0.25, 0.65, 0.95 } },
    },
    PRIEST = {
        { name = "Mind Flay", interval = 1, channel = true,
          color = { 0.55, 0.45, 1.00, 0.95 } },
        { name = "Starshards", interval = 1, channel = true,
          color = { 0.40, 0.80, 1.00, 0.95 } },
        { name = "Shadow Word: Pain", interval = 3, color = { 0.62, 0.25, 0.95, 0.95 } },
        { name = "Devouring Plague", interval = 3, color = { 0.45, 0.75, 0.25, 0.95 } },
        { name = "Holy Fire", interval = 2, color = { 1.00, 0.60, 0.20, 0.95 } },
    },
    DRUID = {
        { name = "Moonfire", interval = 3, color = { 0.45, 0.70, 1.00, 0.95 } },
        { name = "Insect Swarm", interval = 2, color = { 0.55, 0.80, 0.15, 0.95 } },
        { name = "Entangling Roots", interval = 3, color = { 0.60, 0.45, 0.20, 0.95 } },
        { name = "Rake", interval = 3, color = { 1.00, 0.55, 0.15, 0.95 } },
    },
    HUNTER = {
        -- 0.05 of ranged attack power per tick: Blizzard's Forever beta development notes
        -- (the client data has 0)
        { name = "Serpent Sting", interval = 3, rapCoef = 0.05, travel = true,
          color = { 0.30, 0.85, 0.30, 0.95 } },
        { name = "Black Arrow", interval = 2, travel = true,
          color = { 0.55, 0.30, 0.80, 0.95 } },
    },
    MAGE = {
        { name = "Fireball", interval = 2, travel = true,
          color = { 1.00, 0.45, 0.10, 0.95 } },
        { name = "Pyroblast", interval = 3,
          travel = true, color = { 0.95, 0.20, 0.10, 0.95 } },
        { name = "Frostfire Bolt", interval = 3, travel = true,
          color = { 0.60, 0.50, 1.00, 0.95 } },
    },
    SHAMAN = {
        { name = "Flame Shock", interval = 3, color = { 1.00, 0.40, 0.10, 0.95 } },
    },
    WARRIOR = {
        { name = "Rend", interval = 3, color = { 1.00, 0.55, 0.15, 0.95 } },
    },
}

-- Spells whose damage can't be pinned on your target: ground effects, area around you,
-- auto-attacks. They never get a cast band.
ns.NOT_DIRECT = {
    ["Shoot"] = true, ["Auto Shot"] = true, ["Hellfire"] = true, ["Rain of Fire"] = true,
    ["Flamestrike"] = true, ["Blizzard"] = true, ["Arcane Explosion"] = true,
    ["Blast Wave"] = true, ["Cone of Cold"] = true, ["Frost Nova"] = true,
    ["Holy Nova"] = true, ["Consecration"] = true, ["Holy Wrath"] = true,
    ["Hurricane"] = true, ["Volley"] = true, ["Arcane Missiles"] = true,
    ["Explosive Trap"] = true, ["Immolation Trap"] = true,
}

-- Each class's usual direct damage spell, counted in until you have cast another one more
ns.MAIN_SPELL = {
    WARLOCK = "Shadow Bolt", MAGE = "Frostbolt", PRIEST = "Smite", DRUID = "Wrath",
    SHAMAN = "Lightning Bolt",
}

-- Drain Soul ranks, highest first, for the soul shard cue
ns.DRAIN_SOUL = { 11675, 8289, 8288, 1120 }
ns.SOUL_SHARD = 6265

-- Crowd control timed from your own casts (enemy auras are hidden in combat on Forever).
-- ranks: seconds per rank from this client's spell data (SpellMisc -> SpellDuration); a rank
-- missing here takes the first "N sec" of its tooltip.
--   single: only one target at a time, so casting it on another mob ends the old one
--   pet: your pet casts it (UNIT_SPELLCAST_SUCCEEDED on "pet", aimed at its target)
ns.CC = {
    { name = "Fear", single = true, ranks = { [5782] = 10, [6213] = 15, [6215] = 20 } },
    { name = "Banish", single = true, ranks = { [710] = 20, [18647] = 30 } },
    { name = "Death Coil", ranks = { [6789] = 3, [17925] = 3, [17926] = 3 } },
    -- hits everything near you; only your target is timed
    { name = "Howl of Terror", ranks = { [5484] = 10, [17928] = 15 } },
    { name = "Seduction", pet = true, single = true, ranks = { [6358] = 15 } },
    { name = "Polymorph", single = true,
      ranks = { [118] = 20, [12824] = 30, [12825] = 40, [12826] = 50 } },
}
ns.CC_CLASSES = { WARLOCK = true, MAGE = true }

-- Forever's Enslave Demon: the demon becomes your pet for up to 5 min and may break early
ns.SUBJUGATE = { name = "Subjugate Demon", duration = 300, warnAt = 5 }
