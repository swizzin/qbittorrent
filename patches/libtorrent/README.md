# libtorrent 1.2.20 compiled defaults

Two patch files in `1.2.20/`, both generated from the tagged `v1.2.20`
`src/settings_pack.cpp` and applied by the build script as
`qbt-build/patches/libtorrent/1.2.20/patch`:

| file | profile | what it changes |
|---|---|---|
| `1.2.20/patch` | `10g` | six `SET(...)` defaults (the 10g build) |
| `1.2.20/base.patch` | `base` | the same six except the two that scale with the box |

The directory name matches what `qbittorrent-nox-static.sh -lt v1.2.20` expects
(`qbt-build/patches/libtorrent/1.2.20/patch`). The Dockerfile stages exactly one
of the two files into that path, chosen by the `PROFILE` build arg — the script
would otherwise merge every `*.patch` file it finds in the directory, so the two
files must not both land there. Upstream ships no libtorrent 1.2.20 patch of its
own, so nothing is layered on the same file.

Generated from the tagged source, not by hand; both `git apply --check -p1` and
`patch -p1 --dry-run` pass against a pristine `v1.2.20` tree.

None of the six has a qBittorrent preference: they are absent from
`src/base/bittorrent/sessionimpl.cpp` and `src/webui/api/appcontroller.cpp` at
`release-5.3.0`. qBittorrent never sets them, so compiling them in is the only
way to change them.

## base vs 10g

Four tunings are shared by both profiles; two scale with the box and are the
only thing that differs between them:

| setting | base | 10g | mechanism |
|---|---|---|---|
| `request_timeout` | 20 | 20 | seconds a 16 KiB block may take before it is re-requested elsewhere |
| `whole_pieces_threshold` | 10 | 10 | seconds; below it, whole pieces are requested so disk access stays local |
| `torrent_connect_boost` | 50 | 50 | peers dialled at once on the first tracker response (max 255) |
| `predictive_piece_announce` | 10 | 10 | ms of lead when announcing pieces while seeding |
| `send_not_sent_low_watermark` | 524288 | 1048576 | Linux `TCP_NOTSENT_LOWAT`; sized to the runtime send-buffer low watermark |
| `max_peer_recv_buffer_size` | 2 MiB (stock) | 4 MiB | per-peer receive ceiling; worst case is peers × ceiling |

`send_not_sent_low_watermark` is a wakeup threshold, so it only means something
against the send-buffer low watermark the runtime profile sets:

- base (`Session\SendBufferLowWatermark` 10 KiB): 512 KiB (`524288`) is right.
- 10g (`Session\SendBufferLowWatermark` 1024 KiB): 1 MiB (`1048576`) matches the
  low watermark; at or above the high watermark it stops doing anything, because
  unsent bytes never get that deep.

`max_peer_recv_buffer_size` is a per-peer ceiling: worst case is peers × 4 MiB,
right for a big box but wrong as a small-VPS default, so base keeps the stock
2 MiB.

The socket buffers themselves (`send_socket_buffer_size`,
`recv_socket_buffer_size`, i.e. SO_SNDBUF/SO_RCVBUF) and the send-buffer
watermarks are qBittorrent preferences, so they stay runtime (`qBittorrent.conf`),
not compiled.

## Deliberately excluded

- Everything qBittorrent sets itself at each session start. A compiled default
  there is overwritten; set it in `qBittorrent.conf`. In `sessionimpl.cpp` these
  are re-applied at every start: `connections_limit`, `unchoke_slots_limit`,
  `active_downloads`, `active_seeds`, `active_limit`, `alert_queue_size` (set to
  `INT_MAX/2`), `max_out_request_queue`, `max_allowed_in_request_queue`,
  `max_queued_disk_bytes`, `connection_speed`, `aio_threads`, `file_pool_size`,
  `checking_mem_usage`, `peer_turnover_interval`, `send_buffer_low_watermark`,
  `send_buffer_watermark`, `send_buffer_watermark_factor`, `suggest_mode`,
  `piece_extent_affinity`, `listen_queue_size`, `mixed_mode_algorithm`,
  `seeding_outgoing_connections`, `allow_multiple_connections_per_ip`,
  `enable_outgoing_utp`, `enable_incoming_utp`, and — on 1.2 builds —
  `cache_size`, `cache_expiry`, `coalesce_reads`, `coalesce_writes`.
- `min_announce_interval` below 300: announce spam; this is how people get
  banned from private trackers. Stays at 300.
- `max_failcount 1`, `min_reconnect_time 0`, `inactivity_timeout 20`,
  `peer_timeout 20`: churn good peers and burn CPU on a small box.
- `allowed_fast_set_size 0`: disables BEP 6's allowed-fast set, which is a
  startup optimisation being removed, not a gain.
- `use_parole_mode false`: returns to streaming blocks from peers that just
  failed a hash check. Kept at `true`.
- `max_rejects 10`: disconnects peers that keep requesting while choked; 50 is
  fine.
- `peer_tos`: renamed `peer_dscp`; only does anything with QoS configured.
- `share_ratio_limit` / `seed_time_ratio_limit` to `-1`: seeding policy, not
  performance, and qBittorrent's own ratio and seed-time limits are where the
  seeding invariant lives.
- `connections_limit 8000`, `active_seeds 2000`, `active_limit -1`: a large-box
  profile compiled into everyone's install, and qBittorrent owns those values
  anyway.

## Lessons from the previous custom build

- **Assert the allocator is actually linked.** A build that installed gperftools
  and meant to link tcmalloc shipped without it: the linker flags lived in a
  patch against an older copy of the build script, and the newer script it
  really ran never carried them. Nothing failed. CI must check the binary
  rather than trusting the Dockerfile — `hack/verify-binary.sh` makes mimalloc
  prove it is the live allocator at runtime, not merely present in the binary.
- **Pin a tag, not a branch.** `-lt RC_1_2` builds whatever the branch tip is
  that day. Use `-lt v1.2.20`, so the patch directory and the version string
  match a real release.
- **Only documented variables do anything.** `qbt_optimize` is not read by the
  script; `-march=native` comes from the `-o` flag, and a published image must
  not use it anyway.
- **Never ship `-fprofile-generate`.** It produces an instrumented, slower
  binary that writes profile data at runtime. PGO is generate, run a workload,
  then rebuild with `-fprofile-use`, and that needs a reproducible workload
  first.

## Before adding these to a build

Check whether userdocs' own patch set for that libtorrent version touches
`src/settings_pack.cpp`; if it does, fold the two together rather than layering
a second patch on the same file. (Upstream ships no 1.2.20 patch, so this does
not apply today.)

## Runtime settings that go with the 10g build

Recommended `qBittorrent.conf` values for the 10g profile. They are a starting
point written once, never re-applied: a user changing them is not drift. The
base profile's runtime presets are the stock qBittorrent defaults with a lower
send-buffer watermark (see above); only these compiled values are fixed at build
time, nothing here is.

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
