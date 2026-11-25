# Meio Plates

Enemy nameplates show the damage still coming from you and how many hits the mob still takes.

For WoW Forever.

![Two enemy nameplates, the mouse on one with Shift held: before, plain health bars and
tooltip; with Meio Plates, a band per DoT and the Shadow Bolt being cast, "x11" wand shots
left, "kill" on the mob the DoTs will finish, and the tooltip naming each band in its
colour](docs/before-after.png)

## What it does

From the end of each enemy's health bar, bands eat back the damage already on its way, so the
red that stays is what the mob will have left. Beside it, `xN` more attacks to kill, or `kill`
when your DoTs finish it.

- Yellow is the spell you are casting; each DoT gets its own colour and shrinks tick by tick
- Pale is one of your main attacks: a wand shot, Auto Shot, melee swing or your main spell,
  plus your pet's damage on the mob it attacks

![A hunter's nameplates: one Auto Shot plus the wolf's damage per band, "x8" to kill, and the
mob's tooltip with Shift held](docs/hunter.png)

- Hover a mob: its tooltip counts each of your attacks; Shift adds each DoT and hit sizes
- Warlock and Mage: crowd control timers. Warlock: a soul shard icon when Drain Soul would
  finish the mob
- Works on Blizzard's and Threat Plates' nameplates, and uses DoesItDie (hiding its own plate
  marker once; `/did` brings it back) and Meio DPS when installed

WoW Forever hides the combat log from addons, so DoTs are estimated from your casts and
spell tooltips.

Settings: Esc > Options > AddOns > MeioPlates, or `/meioplates`.

## Coming soon

- Works on Plater and Platynator nameplates
- A skull on the plate when one more hit kills

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

[Meio Trainer Compare](https://www.curseforge.com/wow/addons/trainercompare) | [Meio Next Stop](https://www.curseforge.com/wow/addons/leavebutton) | [Meio Auto Rank](https://www.curseforge.com/wow/addons/meio-autorank) | [Meio Meter Hover](https://www.curseforge.com/wow/addons/meterhover) | [Meio Map](https://addons.wago.io/addons/meiomap) | [Meio Alts](https://addons.wago.io/addons/meioalts) | [Meio DPS](https://addons.wago.io/addons/meiodps) | [Meio Hub](https://addons.wago.io/addons/meiohub) | [Meio Pets](https://addons.wago.io/addons/meiopets) | [Meio Stats](https://addons.wago.io/addons/meiostats) | [Meio Bags](https://addons.wago.io/addons/meiobags) | [Meio Fixes](https://addons.wago.io/addons/meiofixes) | [Meio Flight Times](https://addons.wago.io/addons/meioflighttimes) | [Meio Tooltip Fold](https://addons.wago.io/addons/meiotooltipfold) | [Meio Auto Run Turn](https://addons.wago.io/addons/meioautorunturn) | [Meio Mail](https://addons.wago.io/addons/meiomail) | [Meio QoL](https://addons.wago.io/addons/meioqol) | [Meio TSM Browse](https://addons.wago.io/addons/tsmbrowse) | [Meio Shards](https://addons.wago.io/addons/meioshards) | [Meionomics](https://www.curseforge.com/wow/addons/meionomics) | [Meio Spike Check](https://addons.wago.io/addons/meiospikecheck) | [Meio BiS Extras](https://addons.wago.io/addons/meiobisextras) | [Meio Buff Thanks](https://addons.wago.io/addons/meiobuffthanks) | [Meio Flare Fixes](https://addons.wago.io/addons/meioflarefixes) | [Meio Flare Questie](https://addons.wago.io/addons/meioflarequestie)

## Licence

[MIT](LICENSE)
