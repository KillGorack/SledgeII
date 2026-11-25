# match.gd outline (Networking/match.gd, ~2057 lines)

Big strokes only. Line numbers are approximate (as of 2026-11-24).
It is the root script of match.tscn: one node per running match, on every peer
(server and clients). The server is authoritative; clients mirror via events.

| Lines | Area | What it does |
|---|---|---|
| 1-212 | Constants and state | Scene preloads, kill-feed phrases, bounty/score tuning, spawn-pad and base-gun layout, team materials, per-peer dictionaries (names, scores, bounty, ready peers). |
| 213-283 | Lifecycle | `_ready` wires the match up, `_process` ticks bounty and the leave countdown. |
| 284-328 | Team juice | Team currency: add, generate over time, broadcast. |
| 329-427 | Chat and roster | Chat send/broadcast with BBCode escaping, name cleanup, roster sync, announcements. |
| 428-517 | Leaving | Leave-to-menu countdown, exit, server-disconnect handling. |
| 518-787 | Map and world | Load the map (local or downloaded .pck), environment/light, base ambience, shader prewarm, spawn recon stations. |
| 788-966 | Player join | Register/unregister players, "I'm ready" handshake, visibility grants (so nothing replicates to a peer before it can receive it). |
| 967-1065 | Spawn points | Pick a base-pad slot, lift per craft, keep clear of other crafts. |
| 1066-1211 | Base guns and recon capture | Spawn the hovering base guns, capture request/run/sync. |
| 1227-1437 | Loot | Weighted roll, drop count by "Drops" level, spawn/collect/remove events, structure drops. |
| 1212-1727 | Projectiles, stats, latency | Spawn events, client prediction/rejection, corrections, end events, volleys (boost ops applied), impact FX, weapon-hit stats, one-way latency. |
| 1728-1882 | Bots and craft spawn | Add bots, bot teams, build and spawn a craft with team materials, attach the one local camera. |
| 1883-2057 | Scoring and defeat | Score and bounty, record defeats, kill-feed lines, respawn on craft defeat, recon/gun-destroyed payouts. |

## Responsibilities in one line each
1. Match lifecycle: load, join, ready, leave.
2. World setup: map, environment, recon stations, base guns.
3. Spawning: crafts, bots, spawn pads, camera.
4. Network event hub for projectiles (the biggest block, ~280 lines).
5. Loot drops.
6. Economy and scoring: juice, bounty, score, kill payouts.
7. Social: chat, roster, kill feed.
