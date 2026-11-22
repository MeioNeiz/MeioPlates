-- WandBar's spell data. Add a DoT here and WandBar tracks it; nothing else needs changing.
--
-- Tick intervals and coefficients are this client's spell data (SpellEffect:
-- EffectAuraPeriod, EffectBonusCoefficient), except where noted. The damage and duration of
-- each rank are read from the spell's tooltip when you cast it, so new ranks need no entry.
--
-- DoT fields:
--   name: spell name, which is also the debuff's name
--   aliases: other names the same DoT goes by
--   interval: seconds between ticks
--   coef: damage added per tick per point of spell power of `school`
--   school: GetSpellBonusDamage school (2 holy, 3 fire, 4 nature, 5 frost, 6 shadow,
--     7 arcane)
--   power: "ranged" when coef is of ranged attack power instead of spell power
--   direct: spell power coefficient of the spell's direct hit, if it has one
--   channel: lasts only while you keep channelling
--   ramp: ticks grow, first third at half, middle third normal, last third at 1.5x
--   travel: a projectile, so the ticks start when it lands
--   consumedBy: a spell that ends the DoT
--   did: false when DoesItDie doesn't track it, so WandBar's estimate is always used
--   color: r, g, b, a of its band; only needs to differ within a class

local _, ns = ...

ns.DOTS = {
    WARLOCK = {
        { name = "Drain Life", interval = 1, coef = 0.10, school = 6, channel = true,
          color = { 0.90, 0.15, 0.30, 0.95 } },
        { name = "Drain Soul", interval = 3, coef = 0.10, school = 6, channel = true,
          color = { 0.30, 0.55, 1.00, 0.95 } },
        { name = "Immolate", interval = 3, coef = 0.13, school = 3, direct = 0.20,
          consumedBy = "Conflagrate", color = { 1.00, 0.45, 0.10, 0.95 } },
        { name = "Corruption", interval = 3, coef = 0.20, school = 6,
          color = { 0.62, 0.25, 0.95, 0.95 } },
        -- seen in game: 72 over 24 s ticked 3,3,3,3, 6,6,6,6, 9,9,9,9
        { name = "Bane of Agony", aliases = { "Curse of Agony" }, interval = 2, coef = 0.133,
          school = 6, ramp = true, color = { 0.35, 0.80, 0.20, 0.95 } },
        { name = "Siphon Life", interval = 3, coef = 0.05, school = 6,
          color = { 0.10, 0.60, 0.50, 0.95 } },
        -- one hit after a minute; DoesItDie can't read its "after 1 min" tooltip
        { name = "Bane of Doom", aliases = { "Curse of Doom" }, interval = 60, coef = 4.0,
          school = 6, did = false, color = { 0.50, 0.05, 0.40, 0.95 } },
    },
    PRIEST = {
        { name = "Mind Flay", interval = 1, coef = 0.167, school = 6, channel = true,
          color = { 0.55, 0.45, 1.00, 0.95 } },
        { name = "Shadow Word: Pain", interval = 3, coef = 0.20, school = 6,
          color = { 0.62, 0.25, 0.95, 0.95 } },
        { name = "Devouring Plague", interval = 3, coef = 0.10, school = 6,
          color = { 0.45, 0.75, 0.25, 0.95 } },
        { name = "Holy Fire", interval = 2, coef = 0.05, school = 2, direct = 0.75,
          color = { 1.00, 0.60, 0.20, 0.95 } },
    },
    DRUID = {
        { name = "Moonfire", interval = 3, coef = 0.13, school = 7, direct = 0.15,
          color = { 0.45, 0.70, 1.00, 0.95 } },
        { name = "Insect Swarm", interval = 2, coef = 0.158, school = 4,
          color = { 0.55, 0.80, 0.15, 0.95 } },
        { name = "Rake", interval = 3, coef = 0, school = 1,
          color = { 0.85, 0.20, 0.20, 0.95 } },
    },
    HUNTER = {
        -- 0.05 of ranged attack power per tick: Blizzard's Forever beta development notes
        -- (the client data has 0)
        { name = "Serpent Sting", interval = 3, coef = 0.05, power = "ranged", travel = true,
          color = { 0.30, 0.85, 0.30, 0.95 } },
    },
    MAGE = {
        { name = "Fireball", interval = 2, coef = 0, school = 3, travel = true,
          color = { 1.00, 0.45, 0.10, 0.95 } },
        { name = "Pyroblast", interval = 3, coef = 0.15, school = 3, direct = 1.0,
          travel = true, color = { 0.95, 0.20, 0.10, 0.95 } },
    },
    SHAMAN = {
        { name = "Flame Shock", interval = 3, coef = 0.10, school = 3, direct = 0.214,
          color = { 1.00, 0.40, 0.10, 0.95 } },
    },
    WARRIOR = {
        { name = "Rend", interval = 3, coef = 0, school = 1,
          color = { 0.80, 0.10, 0.10, 0.95 } },
    },
}

-- Direct hits whose spell power coefficient isn't the usual cast time / 3.5 (1.5 to 3.5 s).
-- From the client's spell data.
ns.DIRECT_COEF = {
    ["Death Coil"] = 0.214, ["Chain Lightning"] = 0.357, ["Chastise"] = 0.143,
    ["Penance"] = 0.19,
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
