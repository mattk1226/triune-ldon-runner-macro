# ldon.mac

A MacroQuest macro that runs Lost Dungeons of Norrath adventures in a loop on the Triune emu server. It requests an adventure (high difficulty), travels to the dungeon entrance, runs the TAC as puller until the adventure completes, leaves through the Bazaar, and returns to the camp for the next one.

It was built and tested on MacroQuest emu-rof2 v3.1.4.13. Use it at your own risk, stay at the keyboard for your first loops, and check the server rules on unattended play before leaving it running.

## Requirements

- MacroQuest with the **MQ2Nav** and **MQ2MoveUtils** plugins loaded
- A navmesh for every zone the camp passes through (see "Meshes" below)
- The **Bazaar and Back** AA (alt activate 331)
- The destination waypoints unlocked on the Bazaar map
- The Triune auto combat commands (`/ac puller`, `/ac run`, `/ac manual`, `/ac stop`)

MQ2EasyFind's `/travelto` is not used. It can't route between these zones on this server.

## Install

Copy `ldon.mac` into your MacroQuest `Macros` folder.

## Usage

```
/mac ldon <camp> [skip] [loop] [bail]
```

| Camp | Theme | Camp zone | Recruiter |
|---|---|---|---|
| `sro` | Deepest Guk | South Ro | Kallei Ribblok |
| `ep` | Miragul's Menagerie | Everfrost | Mannis McGuyett |
| `bm` | Mistmoore's Catacombs | Butcherblock | Xyzelauna Tu`Valzir |
| `ec` | The Rujarkian Hills | East Commonlands | Periac Windfell |
| `nro` | Takish-Hiz | North Ro | Escon Quickbow |

With no camp given, it uses `sro`.

`skip` is for when you already hold an adventure and are standing at the recruiter. It skips the request on the first loop only.

`loop` runs one adventure at each camp in turn (sro, ep, bm, ec, nro, then round again), starting at the camp you give. For example, `/mac ldon ec loop` goes ec, nro, sro, ep, bm, ec and so on. After each run, the trip back goes to the next camp. If a recruiter refuses, it moves straight on to the next camp, and it stops only if every camp refuses in a row. The Lua version takes `loop` the same way, or you can tick "Loop through every camp" in its window.

`bail` gives up on an adventure that is stuck. If nothing has been hit either way for 5 minutes inside the dungeon (for example a mob it can't reach, or a mesh trap), it leaves through Bazaar and Back as usual. At the next recruiter it clicks Leave on the old adventure, then requests a new one. The time is `BailMinutes` in the mac and `BAIL_AFTER_MIN` in the Lua version, and the Lua window has a checkbox for it.

You can start the macro in the camp's zone, in the Bazaar, or anywhere else. Outside the camp zone it uses Bazaar and Back and the Bazaar map to get to the camp first. Don't start it mid-fight or inside a dungeon you want to finish.

Bazaar and Back can be set to the Bazaar or to East Commonlands. If it lands in East Commonlands, the landing zone for every camp, the walk to the Bazaar map is skipped.

Type `/endmacro` to stop it.

## Lua version (Triune plugin)

`triune_ldon.lua` is a port of `ldon.mac` that runs as a standalone Triune tool, like `triune_track` or `triune_dps`. It does the same loop with the same camps, routes and settings, and adds a window with camp selection, Start/Stop, a requirements check (MQ2Nav, mesh, MoveUtils, TAC) and a log.

Install: copy `triune_ldon.lua` into your MacroQuest `lua` folder.

```
/lua run triune_ldon            opens the window idle
/lua run triune_ldon sro skip   starts right away, like /mac ldon sro skip
/ldon start [camp] [skip] [loop] [bail]  start the loop
/ldon stop                      stop after the current step (the window stays open)
/ldon camp <sro|ep|bm|ec|nro>   pick a camp
/ldon status | show | hide | toggle | quit
```

Camp, Risk row, Type row and max clear time are saved per character in `config/triune_ldon_<Name>.lua`. Per-camp data is in the `CAMPS` table and the zone crossings are in `ROUTES` at the top of the file. Stopping it, or a failure, leaves the TAC as it was, the same as `/endmacro`. The `ldon_paths.ini` fallback for extra routes is not ported.

## Skipping one unattackable mob (TAC plugin)

Some dungeons have one copy of a mob that can't be attacked, mixed in with normal copies of the same name. For example, one "a feral snow cougar" in Maw of the Menagerie is unattackable. Triune's ignore list works by name, so it would skip all of them.

`tac/ldon_skip.lua` is a Triune plugin that skips just the stuck copy. A watched mob can have a spot: the cougar's is 616, 736, and a cougar standing within 30 of it is skipped right away. Otherwise, when Triune has a watched mob targeted, within 40 units, and its HP stays at 100% for 20 seconds, that one spawn goes on Triune's per-spawn ignore, the same as the ignore toggle in the Extended Target window. A mob that has taken any damage is never skipped.

Install: copy `tac/ldon_skip.lua` into your MacroQuest `lua	ac` folder, then restart Triune or press Rescan on its plugin page. The watch list, timing and range are on the plugin's settings page. `/ac ldonskip` skips the current target by hand, and `/ac ldonskip list` shows the watch list. It works with both `ldon.mac` and `triune_ldon.lua`.

## What one loop does

1. Walks to the recruiter, sets Risk and Type in the adventure window, requests and accepts.
2. Travels to the entrance zone. The `ec` camp uses the Magus port to South Ro.
3. Navs to the portal and clicks it.
4. Runs `/ac puller` and `/ac run`, then waits for "You have successfully completed your adventure".
5. Runs `/ac manual`, waits until combat has been over for five seconds, then `/ac stop`.
6. Uses Bazaar and Back, walks to the map, and ports to the camp's waypoint.
7. Returns to the camp. The `sro`, `ep`, `bm` and `nro` camps port to East Commonlands and use Magus Zeir.

## Settings

General settings are at the top of `Sub Main` in `ldon.mac`:

- `CharName`: optional. Set it to restrict the macro to one character.
- `RiskIndex` and `TypeIndex`: positions in the adventure window dropdowns. The defaults are 2 (High) and 3 (Mob Count).
- `MaxClearTime`: how long to wait for the adventure to complete before leaving anyway.
- `AggroDropAfter` and `AggroDropList`: after the adventure is won, if you are still in combat with no hits either way for 30 seconds, something is stuck on the hate list and would block Bazaar and Back. It uses the first ability on the list that you have and is ready (Fading Memories, Imitate Death, Death Peace, Escape, Feign Death), then stands up if it feigned. In the Lua version they are `AGGRO_DROP_AFTER_SEC` and `AGGRO_DROP_LIST` at the top of the file.
- `AvoidDungeons`: adventures to turn down, default Maw of the Menagerie and Spider Den (Everfrost) and Root Garden and The Drowning Crypt (Guk), which the meshes can't handle. If the offer names one, it declines, reopens the window and requests again, as many times as it takes. Only a real request error moves on to the fallback camp (or the next camp with `loop`). In the Lua version it's `AVOID_DUNGEONS`.
- `FallbackCamp`: if the recruiter refuses an adventure three times, take the Magus at the camp to another camp, run one loop there, and then go back to the original camp. Empty means a random other camp. Set it to `none` to just stop. In the Lua version it's the "If refused, run" dropdown or `/ldon fallback <camp|random|none>`.

Per-camp settings (recruiter, portal location and switch ID, waypoint, Magus phrases) are in `Sub SetCamp`.

## Meshes

The stock mesh pack is built for live-server zones and does not match several classic zones on this server. If nav refuses to path or runs into walls, build a mesh from your own game files:

1. Download `MQ2Nav-1.3.3.157-Live.zip` from the MQ2Nav releases page: <https://github.com/brainiac/MQ2Nav/releases/tag/1.3.3.157>
2. Unzip it to its own folder. Do not copy its `MQ2Nav.dll` into MacroQuest.
3. Run `MeshGenerator.exe`, point it at your EverQuest folder, open the zone, Build, Save.
4. Copy the `.navmesh` file into `resources\MQ2Nav` in your MacroQuest folder and type `/nav reload` in game.

Zones used:

| Camp | Zones |
|---|---|
| All | `bazaar` |
| `sro` | `sro`, `innothule`, `guktop`, `grobb` |
| `ep` | `ecommons`, `everfrost` |
| `bm` | `ecommons`, `butcher`, `gfaydark`, `lfaydark` |
| `ec` | `ecommons`, `sro` (plus `nro`, `oasis` if the Magus port fails) |
| `nro` | `ecommons`, `nro` |

## Zone crossings

The zone lines the macro crosses are built into `ldon.mac` (see `Sub BuiltInRoute`), so there is nothing to record or set up. Each one needs a navmesh for its zone, since nav does the pathing up to the zone line.

## Status and known gaps

- `sro` and `ec` have been run in game.
- `nro` is fully configured, but a complete loop hasn't been confirmed yet.
- `bm`: the two zone crossings (Butcherblock to Greater Faydark to Lesser Faydark) and the portal selection are untested.
- `ep`: portal locations are approximate (no height or switch ID), and it is untested.
- Camps with two portals (`sro`, `ep`, `bm`) choose the portal by reading the adventure text. That check is unconfirmed, so for now the macro may always go to the first portal. On an adventure that uses the second one, it will stop at the entrance.
- Some South Ro tents are missing from the navmesh, so the macro walks through fixed clear spots near the camp. If your character snags there, rebuild the South Ro mesh or adjust the `Camp` and `MagusExit` locations in `Sub SetCamp`.

## Troubleshooting

When the macro stops, it prints the reason. Common ones:

- **"Route [...] needs a navmesh"**: build or install the mesh for that zone.
- **"Nav can't path to the end of route"**: the mesh doesn't match the zone. Rebuild it.
- **"Couldn't enter the dungeon"**: no active adventure for that portal, or the adventure uses the camp's other portal.
- **"Couldn't find ... in the waypoint list"**: that waypoint isn't unlocked on your Bazaar map.
