# Sledge 2 networking overhaul: handoff notes

As of 2026-10-14. Live version (with diagram): https://claude.ai/code/artifact/a8f3df77-1e06-4f1d-b7da-87ee7ade5f47

## Status at a glance

Phases 1, 2 and 3 are built and pass a headless host + client test. Phases 1 and 3 are pushed to `main`. Phase 2 is still uncommitted on the share. None of it has had a full two-PC playtest with real ping yet.

| Work | State | Where |
| --- | --- | --- |
| Phase 1: security, slimmer syncs, kinematic remote copies, unreliable cosmetics, ENet compression | Pushed | `1a044be` |
| Phase 3: event-based projectiles, shooter prediction, latency fast-forward | Pushed | `1a044be` |
| Fixed bugs that already existed: client fall damage, env time-sync spam | Pushed | `1a044be` |
| `Binaries/` and `binaries/` ignored, `binaries/` removed from git | Pushed | `264b090` |
| Phase 2: shared clock + snapshot interpolation for remote tanks, spawn-spot reservation | **Uncommitted** | `network_manager.gd`, `movement.gd`, `lightning.tscn`, `match.gd` |
| Client projectiles ease toward their direction of travel (not from the original session) | **Uncommitted** | `collision_handler.gd` |

The repo lives on an SMB share (`//Gorack/SSD450`). **The user runs all git commands themselves; don't commit or push.**

## Architecture now

Each tank's owner simulates it and streams its state. The server alone resolves hits, and projectiles are events rather than streams.

| Direction | Message | Channel / mode |
| --- | --- | --- |
| Owner → server → other clients | tank state (`net_state` + `net_time`), 30 Hz | synchronizer, unreliable |
| Owner → server | `request_fire(weapon_index, shot_seq, muzzle)` | 0, reliable |
| Server → all | projectile spawn (shooter adopts its prediction) | 2, reliable |
| Server → all | guided corrections / ricochet corrections | 3 unreliable ordered / 2 reliable |
| Server → all | projectile end / impact effects | 2 reliable / 1 unreliable |
| Server → all | deaths, respawns, HP on change | 0, reliable + on-change sync |
| Server → owner only | power (sync), ammo (`_sync_ammo`) | owner-only |
| Every client ↔ server | clock ping / pong | 4, unreliable |

| Channel | Mode | Carries |
| --- | --- | --- |
| 0 | reliable (default) | team, chat, captures, HP sync, deaths, respawns, fire requests, ammo; synchronizers |
| 1 | unreliable | impact effects, launch and resupply sounds |
| 2 | reliable | projectile spawn, end, ricochet corrections |
| 3 | unreliable ordered | guided-missile corrections, 20 Hz |
| 4 | unreliable | clock ping / pong |

## Changes by phase

**Phase 1: cheap wins**

- Sender checks on `any_peer` RPCs: `request_fire`, `_sync_ammo`, `request_fall_damage`, the launch and resupply sounds (`weapon_node.gd`, `health_node.gd`, `recon_station.gd`).
- Only the server applies damage. `health_node.apply_damage` is a plain server-only function, and deaths go out as the `_broadcast_destroyed` RPC.
- HP sync is on-change with `delta_interval` 0.1. It's visible to all peers, because its RPCs need that. Power sync is owner-only.
- Remote tanks and projectiles are frozen kinematic, so they never simulate or shove anything locally.
- Explosion and bullet hole go out as one unreliable RPC on channel 1: `match.gd::_play_impact_fx`.
- Team juice goes out as one packed RPC, only on change: `NetworkManager._update_all_team_juice`.
- ENet range-coder compression: `NetworkManager._enable_compression`. Host and clients must run the same build.

**Phase 3: projectiles (built before Phase 2)**

- Removed `ProjectileSpawner` and every projectile `MultiplayerSynchronizer`.
- `match.gd`: `spawn_projectile` → `_spawn_projectile_event`, `notify_projectile_ended` → `_end_projectile_event`, `send_projectile_correction` → `_correct_projectile` / `_correct_projectile_reliable`. There's a `net_id` registry `_projectiles`, and volleys are built by `_create_volley`.
- `collision_handler.gd`: the server copy is authoritative. Other copies are cosmetic: `_cosmetic_step`, `fast_forward`, `apply_correction`, `end_cosmetic`.
- `weapon_node.gd`: the shooter predicts the shot (`match.predict_shot`) and applies recoil locally. The server uses the client's muzzle if it's within 4 m of its own. `_fire_rejected` removes a prediction.
- Pre-existing fixes: the server is added to every peer's health-sync visibility (client fall damage was blocked), and `env.gd` only syncs time to peers that have loaded the match.

**Phase 2: remote tank smoothness (uncommitted)**

- `NetworkManager`: `server_time()`, `is_clock_synced()`, `round_trip_time`. Unreliable ping/pong on channel 4, min-RTT filter. The offset snaps on a clearly better sample or more than 50 ms of error, and slews 2 ms per sample otherwise.
- `movement.gd`: the owner writes `net_state` (a 12-float pack: pos, quat, velocity, yaw, pitch) and `net_time` every physics tick. Remote copies buffer snapshots on the root synchronizer's `synchronized` signal and render `INTERP_DELAY` = 0.1 s behind, with Hermite blending, up to 0.25 s of extrapolation, and a snap past 8 m. `snap_net_target` resets the buffer on spawn and respawn.
- `lightning.tscn`: the root synchronizer syncs `movement_node:net_state` and `movement_node:net_time` with `replication_interval` 0.0333.
- `match.gd`: spawn spots handed out in the last 3 s count as occupied (`_recent_spawns`).

## Measured results

Measured headless on localhost: 2 players, 144 FPS cap, about 7 ms round trip, client firing the cannon nonstop.

| Measure | Before (`d929185`) | Now |
| --- | --- | --- |
| Host upload | 27.7 KB/s, 159 packets/s | 2.6 KB/s, 39 packets/s |
| Client upload | 12.1 KB/s | 2.4 KB/s |
| Remote tank error vs. true position 100 ms earlier, median | n/a | 0.5 cm |
| Remote tank error, max | n/a | 4.4 cm |
| Snapshot buffer depth | n/a | 3–4 snapshots, never empty |

Real-ping behaviour is unmeasured.

## Gotchas

- **RPC visibility.** Godot drops RPCs on any node whose `MultiplayerSynchronizer` isn't visible to the target peer, and checks this on the sender's local copy. Making `health_node`'s sync owner-only silently swallowed other tanks' explosions and respawns. Keep any node that carries RPCs visible to every peer that must receive them, including the server on clients for client-to-server calls.
- **Authority is recursive.** `set_multiplayer_authority(peer)` on a craft also reassigns its children. `health_node` and `power_node` are re-pinned to the server in `match.gd::_spawn_craft`.
- **Remote tanks are kinematic.** Overlapping spawns eject the local, simulated tank hard; hence `_recent_spawns`. Maps with a single `PlayerSpawn` point still stack tanks that respawn together.
- **Clock during load.** Pings sent while a peer loads the map come back looking seconds late. The offset logic has to snap on better samples; slewing alone left it about 1 s off.
- **Duplicated `WeaponSettings` lose their `resource_path`.** That's why projectiles carry `weapon_settings_path` separately.
- **`get_remote_sender_id()`** returns the local peer id for `call_local` executions, so the host's own requests pass the sender checks.
- **Alt+Q (exit)** works in-engine. On the user's desktop the desktop environment intercepts it; the user will rebind it.
- **Git on the SMB share** fails intermittently with "Remote I/O error". Retrying works.

## How to test

Verify every networking change with a headless host + client on localhost before handing back. The user tests with exported builds on two PCs, so each round trip costs them a build.

The harness was a throwaway: two temp files in the project root, deleted after each run. To rebuild it:

1. `_net_test.tscn` + `_net_test.gd`: in `_ready`, add a runner node to `get_tree().root` (deferred), so it survives the scene change.
2. Runner, host role: `NetworkManager.host_game("test", -1, [], true, "127.0.0.1", "team_red", 7799, 8, false)`, then `change_scene_to_file("res://Networking/match.tscn")`. Map id -1 loads `res://map.pck`.
3. Runner, client role: `join_game("127.0.0.1", 7799, -1)`, `request_team("team_blue")` on connect, change scene when `player_registered` fires for its own id.
4. Drive it from `_process`, starting the timers when both tanks exist and the host's `_ready_peers` has 2 entries: `Input.action_press("fire_weapon")`, `ui_up`/`ui_left` to drive, `health_node.apply_damage(99999)` on the server to kill, and `Input.parse_input_event` with an Alt+Q `InputEventKey`.
5. Log state changes (tank visibility and destroyed state, projectile counts, match child count for effects), ENet `HOST_TOTAL_SENT_DATA` for bandwidth, and the host tank's position against `NetworkManager.server_time()` on both sides, to measure interpolation error.
6. Run `godot --headless --path . res://_net_test.tscn -- host &`, wait 3 s, then the same with `-- client`. Grep both logs for `ERROR` / `SCRIPT ERROR`. A lobby-API TLS error and "resources still in use at exit" are expected noise.

`--check-only` can't compile these scripts, because it skips autoloads; load them from a temp scene instead. Set `Engine.max_fps = 144` in the harness, or headless runs uncapped and bandwidth numbers inflate.

## Open items and next steps

Next is a two-PC playtest of Phase 2 with real ping. Nothing else should be built on top until it passes.

**Playtest checklist (user)**

- [ ] Remote tanks move smoothly and trail about 100 ms behind; bumping them doesn't launch you
- [ ] Hits on moving tanks feel fair
- [ ] Shots look right: cannon arc, Detno tracking, Repulsor ricochets, plasma
- [ ] Explosions and respawns show on every screen
- [ ] Recon pads capture and heal for client tanks (remote tanks are now kinematic in Jolt)
- [ ] Client fall damage works and the amount feels right

**Chat join/leave (2026-10-15, uncommitted):** `_notify_ready(username)` → `_peer_names` → `_announce` → `_broadcast_chat_message` ("X: has entered the arena." / "X: has left the arena.").

**F4 player list (2026-10-15, uncommitted):** `Crafts/_scripts/player_list.gd`, added to the owner's HUD by `hud_controller.gd`. The server pushes `_peer_names` to loaded peers via `match.gd::_sync_roster` on every join/leave → `NetworkManager.peer_names` + `roster_changed`. The `player_list` action (F4) is registered in code if the Input Map doesn't have it.

**Takedowns / wrecks (2026-10-15, uncommitted):** projectiles carry `shooter_peer`. `health_node.note_attacker` records the last attacker on damage (`apply_damage(damage, attacker)`) and on knockback (`apply_hit_force`, so the Repulsor counts). A death within `TAKEDOWN_CREDIT_MSEC` (5 s) credits them. `match._record_defeat` keeps `_peer_scores` (`[takedowns, wrecks]`, no credit for teammates) and ships them with `_sync_roster`; the F4 list shows them. Seen in a test: teleporting a client tank 80 m straight down dragged the host's parked tank through the floor on the host. Remote copies are kinematic and swept through it. Real falls are gradual, so this is probably harmless, but it's the same family as "bumping remote tanks" on the playtest checklist.

**Recon capture host rule (2026-10-18, uncommitted):** "Recon capture" checkbox (`%ReconCaptureCheck`, index.tscn) → `host_game(..., recon_capture)` → `NetworkManager.recon_capture_enabled`, sent to joiners in `_assign_ruleset`. `match._start_capture_request` (server) and `_try_start_capture` (client) refuse when it's off. Healing and resupply are unaffected.

**Known gaps, in suggested order**

1. Rewind lag compensation: the server checks hits against remote tanks drawn 100 ms in the past. **On hold (user, 2026-10-15)**; revisit only if hits on moving tanks feel late.
2. ~~Freeze only affected the host's tank.~~ Fixed 2026-10-15: `collision_handler._send_freeze` → `health_node.apply_weapon_freeze` RPC; the owner runs the timer, overlapping freezes extend and never shorten, duration 0 unfreezes. No weapon sets `freeze_timer`/`unfreeze` yet. Uncommitted.
3. ~~Crit and ricochet sounds only played on the host.~~ Fixed 2026-10-15: crits set `_crit_pending`, which rides `_play_impact_fx` as `show_crit`. Ricochet already reached clients through the impact fx `hit_sound`; the extra `play_hit_sound()` only doubled it on the host and is gone. No weapon sets `crit_sound` yet. Uncommitted.
4. Server-side movement sanity check: reject tank movement faster than `max_speed` plus a margin, allowing for knockback and respawns.
5. ~~Tank spawns reached peers before their match loaded.~~ Fixed 2026-10-15, uncommitted. Two bugs, both reproduced with host + 4 clients joining 1 s apart:
   - **Spawns:** Godot skips synchronizers the server isn't authority of when deciding spawn visibility, so client-owned crafts spawned on every connected peer at once. If one landed before `Match/CraftSpawner` existed, that peer's path cache broke and it never saw a tank (before: 4 of 4 clients saw 0 tanks). Fix: `_spawn_craft` adds a server-owned, property-less `SpawnGate` synchronizer, granted in `_grant_visibility`.
   - **Movement:** `_grant_own_craft_visibility` was sent to an owner still loading and was dropped, so nobody saw that tank move (before: the host saw 0 of 4 client tanks move). Fix: only sent to ready owners; `_notify_ready` grants the newcomer's craft to everyone already there.
   - After: every peer sees every tank, all moving; no spawner or "Match not found" errors.
   - Join/leave chat lines go only to `_ready_peers` (`_announce`).
6. Maps with a single `PlayerSpawn` point stack tanks that respawn together. Could offset when the spot is occupied.
7. Optional: put the headless harness in the repo (for example `tests/net_test`), if the user wants it there.
