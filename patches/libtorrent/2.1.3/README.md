# libtorrent 2.1.3 compiled defaults

Two patch files in this directory, both generated from the tagged `v2.1.3`
`src/settings_pack.cpp` and applied by the build script as
`qbt-build/patches/libtorrent/2.1.3/patch`:

| file | profile | what it changes |
|---|---|---|
| `patch` | `10g` | six `SET(...)` defaults (the 10g build) |
| `base.patch` | `base` | the same six except the two that scale with the box |

They target **libtorrent v2.1.3** and **qBittorrent 5.3.1**
(`release-5.3.1`). The directory name is what
`qbittorrent-nox-static.sh -lt v2.1.3` creates and reads
(`qbt-build/patches/libtorrent/2.1.3/`); verified by bootstrapping the pinned
script in a throwaway Alpine container with `-lt v2.1.3 -qt release-5.3.1
-bs-a` and listing `qbt-build/patches`, which came back with `2.1.3/` and
`5.3.1/`. The Dockerfile stages exactly one of the two files into that path,
chosen by the `PROFILE` build arg — the script merges every `*.patch`/`*.diff`
file it finds in the directory, so the two must not both land there. Upstream
ships no libtorrent 2.1.3 patch: the pinned script at
`66a0aa3fd2044dcd2a327670aba35779b0957e34` creates that directory with an empty
`source/` inside and fetches nothing for it. The only libtorrent patch userdocs
publishes is a 1.2.20 one (Boost 1.87–1.92 and OpenSSL 4 support), added after
that commit and irrelevant here.

Generated from the tagged source, not by hand: `hack/lt-patches.sh 2.1.3`
writes both files, then checks them with `git apply --check -p1` and
`patch -p1 --dry-run` against a pristine tree of the tag, applies them for
real, and reads back six (10g) and five (base) rewritten lines.

## Same intent as 1.2.20, re-derived for this branch

The pair is not copied from `../1.2.20/`: a 1.2 patch does not apply to 2.x
(the hunks and some settings differ), so each file is regenerated against this
tag's own `settings_pack.cpp`. The intent is the same: four tunings that help
any box, plus two that scale with it.

## base vs 10g

Four tunings are shared by both profiles; two scale with the box and are the
only thing that differs between them:

| setting | base | 10g | mechanism |
|---|---|---|---|
| `request_timeout` | 20 | 20 | seconds a 16 KiB block may be outstanding before it is re-requested elsewhere |
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
`recv_socket_buffer_size`) and the send-buffer watermarks are qBittorrent
preferences, so they stay runtime (`qBittorrent.conf`), not compiled.

## What 2.1.3 changed in this file

`src/settings_pack.cpp` between `v2.1.2` and `v2.1.3` changes three things,
none of them one of the six:

- `peer_fingerprint`, `-LT2120-` to `-LT2130-` (`settings_pack.cpp:127`), which
  is what makes a 2.1.3 client identifiable in a peer list. qBittorrent
  overwrites it with its own fingerprint at session start
  (`sessionimpl.cpp:1812`), so an image built from this line does not report
  it anyway.
- `announce_to_all_tiers` and `announce_to_all_trackers` swap places
  (`settings_pack.cpp:153-154`); both stay `false` and qBittorrent sets both
  (`sessionimpl.cpp:2091-2092`).
- `max_out_request_queue`'s stock value, 500 to 1500
  (`settings_pack.cpp:237`). It only moves the context line of our second hunk,
  and it is inert either way: qBittorrent sets it from its own
  `Session\RequestQueueSize` at every start (`sessionimpl.cpp:2098`).

## What 2.1 adds, and why none of it is in the patch

The 2.x disk layer is where a community profile usually starts adding lines. On
a libtorrent-2 build, qBittorrent 5.3.1 sets all of them from its own
preferences at every session start (`loadLTSettings()`,
`src/base/bittorrent/sessionimpl.cpp:1973`), so a compiled default is
overwritten before the session exists and changes nothing:

| setting | who sets it |
|---|---|
| `aio_threads` | qBittorrent, every build (`Session\AsyncIOThreadsCount`, `sessionimpl.cpp:2105`) |
| `hashing_threads` | qBittorrent, libtorrent-2 builds only (`Session\HashingThreadsCount`, `sessionimpl.cpp:2107`, under `#ifdef QBT_USES_LIBTORRENT2`) |
| `max_queued_disk_bytes` | qBittorrent (`Session\DiskQueueSize`, `sessionimpl.cpp:2120`) |
| `disk_io_read_mode`, `disk_io_write_mode` | qBittorrent (`Session\DiskIOReadMode`/`DiskIOWriteMode`, `sessionimpl.cpp:2125-2144`, including 2.x's `write_through`) |
| `mmap_file_size_cutoff`, `disk_write_mode` | qBittorrent in its `SimplePreadPwrite` case (`sessionimpl.cpp:1830-1833`) |
| posix vs mmap disk I/O | not a setting at all: qBittorrent chooses the disk I/O constructor (`DiskIOType`: `Posix`, `MMap`, `SimplePreadPwrite`, `PreadPwrite`, `sessionimpl.cpp:1839-1854`) |
| `checking_mem_usage`, `file_pool_size`, `piece_extent_affinity`, `suggest_mode`, `send_buffer_*` | qBittorrent (`sessionimpl.cpp:2109-2161`) |

`cache_size`, `cache_expiry`, `coalesce_reads` and `coalesce_writes` still exist
on 2.1.3 but are `DEPRECATED_SET` (`settings_pack.cpp:146-147`, `262-264`), and
qBittorrent only assigns them under `#ifndef QBT_USES_LIBTORRENT2`
(`sessionimpl.cpp:2116-2117`, `2150-2151`), so on this line they are inert
twice over: the 2.x disk cache is caches and the app builds its own disk I/O.
They are dropped here and are not in the 1.2-style exclusion list as anything
but deprecated.

None of the six settings in this patch is set by qBittorrent 5.3.1 in either
build mode, and none has a WebUI preference key in
`src/webui/api/appcontroller.cpp`: `request_timeout`,
`whole_pieces_threshold`, `max_peer_recv_buffer_size`,
`torrent_connect_boost`, `predictive_piece_announce` and
`send_not_sent_low_watermark` appear nowhere in qBittorrent's `src/` at
`release-5.3.1`, so compiling them in is the only way to change them.

## Deliberately excluded

- Everything qBittorrent sets itself at each session start. A compiled default
  there is overwritten; set it in `qBittorrent.conf`. On this branch that is
  the table above plus `connections_limit`, `unchoke_slots_limit`,
  `active_downloads`, `active_seeds`, `active_limit`, `alert_queue_size`,
  `max_out_request_queue`, `max_allowed_in_request_queue`,
  `connection_speed`, `peer_turnover*`, `listen_queue_size`,
  `mixed_mode_algorithm`, `seeding_outgoing_connections`,
  `allow_multiple_connections_per_ip`, `enable_outgoing_utp`,
  `enable_incoming_utp`, and `active_dht_limit`/`active_tracker_limit`/
  `active_lsd_limit`.
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
- `peer_tos`: renamed `peer_dscp` on 2.x; only does anything with QoS
  configured.
- `share_ratio_limit` / `seed_time_ratio_limit`: seeding policy, not
  performance; qBittorrent's own ratio and seed-time limits are where the
  seeding invariant lives.
- `connections_limit 8000`, `active_seeds 2000`, `active_limit -1`: a large-box
  profile compiled into everyone's install, and qBittorrent owns those values
  anyway.

## Runtime settings that go with this build

Recommended `qBittorrent.conf` values for the 10g profile on 2.1.3. They are a
starting point written once, never re-applied: a user changing them is not
drift. The base profile's runtime presets are the stock qBittorrent defaults
with a lower send-buffer watermark; only the compiled values are fixed at build
time, nothing here is.

| key | value |
|---|---|
| `Session\DiskCacheSize` | `0` (ZFS: the ARC is the cache; ignored on 2.x) |
| `Session\SendBufferWatermark` | `10240` |
| `Session\SendBufferLowWatermark` | `1024` |
| `Session\SendBufferWatermarkFactor` | `250` |
| `Session\AsyncIOThreadsCount` | `8` on 12 threads |
| `Session\HashingThreadsCount` | `1` unless the box has cache pressure |
| `Session\DiskQueueSize` | `134217728` |
| `Session\SuggestMode` | `false` |
| `Session\BTProtocol` | `TCP` |
| `Session\Preallocation` | `true` |

## Before changing this patch

Check whether userdocs' own patch set for that libtorrent version touches
`src/settings_pack.cpp`; if it does, fold the two together rather than layering
a second patch on the same file. Upstream ships no 2.1.3 patch, and the
Dockerfile takes the local-patch path (no remote fetch) for both libtorrent and
qBittorrent.

Regenerate with `hack/lt-patches.sh <version>`, never by hand: it fails by name
when a stock line has moved, which is the failure mode that otherwise ships
stock values in a build that looks fine.
