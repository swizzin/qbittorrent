# libtorrent 1.2.20 compiled defaults (10g profile)

`1.2.20/patch` rewrites six `SET(...)` defaults in `src/settings_pack.cpp` of libtorrent
`v1.2.20`. The directory name matches what `qbittorrent-nox-static.sh -lt v1.2.20` expects
(`qbt-build/patches/libtorrent/1.2.20/patch`). Upstream ships no libtorrent 1.2.20 patch of
its own, so nothing is layered on the same file.

Generated from the tagged source, not by hand; both `git apply --check -p1` and
`patch -p1 --dry-run` pass against a pristine `v1.2.20` tree, and exactly six lines change.

None of these six has a qBittorrent preference: they are absent from
`src/base/bittorrent/sessionimpl.cpp` and `src/webui/api/appcontroller.cpp` at
`release-5.3.0`. qBittorrent never sets them, so compiling them in is the only way to change
them.

| setting | stock | here | mechanism |
|---|---|---|---|
| `send_not_sent_low_watermark` | 16384 | 1048576 | Linux `TCP_NOTSENT_LOWAT`; more data per wakeup, fewer syscalls |
| `max_peer_recv_buffer_size` | 2 MiB | 4 MiB | per-peer receive ceiling for high-latency peers |
| `whole_pieces_threshold` | 20 | 10 | seconds; below it, whole pieces are requested so disk access stays local |
| `request_timeout` | 60 | 20 | seconds a 16 KiB block may take before it is re-requested elsewhere |
| `torrent_connect_boost` | 30 | 50 | peers dialled at once on the first tracker response |
| `predictive_piece_announce` | 0 | 10 | ms of lead when announcing pieces while seeding |

`send_not_sent_low_watermark` is sized for the 10g runtime profile, where
`Session\SendBufferLowWatermark` is 1024 KiB and `Session\SendBufferWatermark` is 10240 KiB.
At or above the high watermark it would never trip. `max_peer_recv_buffer_size` is a
per-peer ceiling, so worst-case memory is peers × 4 MiB: right for a big box, wrong as a
small-VPS default.

## Deliberately excluded

- Everything qBittorrent sets itself at each session start (connection and unchoke limits,
  `active_*`, send-buffer watermarks, `aio_threads`, `suggest_mode`, and on 1.2 the cache
  and coalesce settings). A compiled default there is overwritten; set it in
  `qBittorrent.conf`.
- `min_announce_interval` below 300: announce spam, private-tracker bans.
- `max_failcount 1`, `min_reconnect_time 0`, `inactivity_timeout 20`, `peer_timeout 20`:
  peer churn for no gain.
- `allowed_fast_set_size 0`, `use_parole_mode false`, `max_rejects 10`: each removes a
  protection or an optimisation.
- `share_ratio_limit` / `seed_time_ratio_limit`: seeding policy, owned by qBittorrent's own
  limits.

## Runtime settings that go with this build

Recommended `qBittorrent.conf` values for the 10g profile. They are a starting point
written once, never re-applied: a user changing them is not drift.

| key | value |
|---|---|
| `Session\DiskCacheSize` | `0` (ZFS: the ARC is the cache) |
| `Session\SendBufferWatermark` | `10240` |
| `Session\SendBufferLowWatermark` | `1024` |
| `Session\SendBufferWatermarkFactor` | `250` |
| `Session\AsyncIOThreadsCount` | `8` on 12 threads |
| `Session\DiskQueueSize` | `134217728` |
| `Session\SuggestMode` | `false` |
| `Session\BTProtocol` | `TCP` |
| `Session\Preallocation` | `true` |
