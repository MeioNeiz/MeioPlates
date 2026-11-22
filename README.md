# Meio Plates

Enemy nameplates show the damage still coming from you and how many hits the mob still takes.

![Two enemy nameplates: before, plain health bars; with Meio Plates, the Shadow Bolt being cast
in yellow, a band per DoT, "x11" wand shots left on one mob and "kill" on the one the DoTs
will finish](docs/before-after.png)

## What it does

From the end of each enemy's health bar, bands eat back the damage already on its way, so the
red that stays is what the mob will have left. Beside it, `xN` more attacks to kill, or `kill`
when your DoTs finish it.

- Yellow is the spell you are casting; each DoT gets its own colour and shrinks tick by tick
- Pale is one of your main attacks: a wand shot, Auto Shot, melee swing or your main spell,
  plus your pet's damage on the mob it attacks
- Hover a mob: its tooltip counts each of your attacks; Shift adds each DoT and hit sizes
- Warlock and Mage: crowd control timers. Warlock: a soul shard icon when Drain Soul would
  finish the mob
- Works on Blizzard's and Threat Plates' nameplates, and uses DoesItDie (hiding its own plate
  marker once; `/did` brings it back) and Meio DPS when installed

WoW Forever hides the combat log from addons, so DoTs are estimated from your casts and
spell tooltips.

Settings: Esc > Options > AddOns > MeioPlates, or `/meioplates`.

## Commands

- `/meioplates help`: the commands; `/meioplates status`: your attacks and DoT colours
- `/meioplates on|off`: everything
- `/meioplates attack|pet|dots|cast|text|tooltip|cc|drainsoul on|off`: one part
- `/meioplates count auto|wand|shot|melee|spell`: what `xN` counts in
- `/meioplates shards N`: Drain Soul cue only below N shards
- `/meioplates clear`: forget the DoTs and timers; `/meioplates reset`: default settings

## Install

Use your addon manager (CurseForge, Wago), or unzip a GitHub release into
`World of Warcraft\_forever_\Interface\AddOns` and restart WoW fully.

## Feedback

Bugs and ideas: [GitHub issues](https://github.com/MeioNeiz/MeioPlates/issues)

## More Meio addons

[Meio Next Stop](https://www.curseforge.com/wow/addons/leavebutton) | [Meio TrainerCompare](https://www.curseforge.com/wow/addons/trainercompare) | [Meio MeterHover](https://www.curseforge.com/wow/addons/meterhover) | [Meio AutoRank](https://www.curseforge.com/wow/addons/meio-autorank)

## Licence

[MIT](LICENSE)
