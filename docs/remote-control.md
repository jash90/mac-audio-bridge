# Control from the iPhone and several Macs (M5c)

The iPhone lists every Mac running Mac Audio Bridge, shows its state, and picks the one it
plays. Several Macs can run the sender at once; the phone plays exactly one of them.

## Discovery

- Each Mac advertises `_macaudiosrc._tcp` (`Apps/Sender-macOS/Network/ControlServer.swift`):
  instance name = computer name, TXT `v=1`, `id=<UUID>` (generated once, UserDefaults
  `sourceID`). A TCP `NWListener` (any port) serves the phones.
- The phone browses it (`Apps/Receiver-iOS/Sources/SourceBrowser.swift`) and keeps one TCP
  connection per Mac (`ControlClient`), reconnecting every 2 s while the Mac is browsed; a
  connection silent for 6 s (statuses come every 2 s at least) is recycled.

## Control protocol (`Packages/BridgeCore/Sources/BridgeCore/ControlProtocol.swift`)

Frames: 4-byte big-endian length (1…64 KiB) + UTF-8 JSON envelope `{"v":1,"type":…}`.
Another `v` → `versionMismatch` (the connection is closed, the phone shows "update"); a
malformed frame is skipped; a zero or oversized length closes the connection.

| Direction | Message | Meaning |
|---|---|---|
| phone → Mac | `hello{phoneID, phoneName, receiverService}` | who the phone is, where to stream |
| phone → Mac | `connect` | remember the output, switch to ours, stream to this phone |
| phone → Mac | `disconnect` / `release{byName}` | stop, restore the remembered output (release: "iPhone used by …") |
| phone → Mac | `setVolume` / `setMuted` / `setQuality` | virtual-device volume/mute, codec (synced with the menu) |
| Mac → phone | `status{…}` | on change + every 2 s: streaming to you, playing, output name, volume, mute, quality, problem |
| Mac → phone | `claim` | the Mac's user selected our output: the phone switches to this Mac |
| phone → Mac | `media{media}` (v2) | `play` / `pause` / `togglePlayPause` / `nextTrack` / `previousTrack` for the Mac's Now Playing app |
| Mac → phone | `nowPlaying{nowPlaying?}` (v2) | on change (throttled, max 2/s; position advancing is not a change, a seek is) and after hello: title, artist, album, app, isPlaying, duration, elapsed, artwork (≤ 24 KB JPEG), canControl; absent = nothing plays |

Version 2 (M9): `v` is the version that introduced each message, so version 1 messages still
go out as `v:1` and a v1 Mac (Sender 0.5.0) keeps working with a v2 phone. `status` carries
`protocolVersion` (absent = 1); the phone sends `media` only to a Mac that reported 2 or later.

## Arbitration (`SourceArbiter`, phone side, pure and tested)

The newest explicit action wins, in the order the events reach the phone:
tap = `connect` to the Mac + `release(byName:)` to the previous / any other streaming Mac;
a `claim` does the same without `connect`; a Mac streaming to us unasked while another is
active (or after we released it) is released once per run; with nothing active, a Mac that
already streams is adopted. The active Mac stopping on its own or going offline leaves nothing
active; the last used Mac is persisted and offered as "Reconnect to …".

Mac side: `OutputRestoreModel` remembers the last non-bridge output by UID and restores it on
disconnect/release (fallback: built-in output, then any other output; none → the stream pauses
with the output kept, menu "Resume streaming"). A change of the default output to ours that the
app did not make itself is a takeover and is sent to the phone as `claim`.

## Audio path: one source

`AudioDatagram` v3 (Bonjour TXT `v=3` on `_macaudiobridge._udp`) adds a 4-byte source tag
(FNV-1a of the Mac's UUID) to the header (24 bytes; Opus 192 datagram 639 B). The receiver's
`SourceGate` drops datagrams of any other tag (counted as "Other Macs (dropped)") — independent
of addresses and robust to two Macs streaming at once. The first datagram of a newly admitted
source must carry a primary; it is marked `.discontinuity`, so the jitter buffer resets and the
reader crossfades (the M2.8 fade, no click). Non-active Macs get no keepalives.

## Phone extras

Now Playing / lock screen shows the active Mac's name. With a v2 Mac that reports what plays it
shows the Mac's track (title, "artist · Mac name", app as album, artwork, position) and
`playbackRate` follows the Mac's play state; play / pause / toggle / next / previous from the
lock screen, Control Center, AirPods and the active row's buttons go to the Mac
(`MediaControlRouter`). Otherwise (nothing known, v1 Mac) play / pause unmute / mute that Mac
and next / previous are disabled.

## Playback control on the Mac (M9)

- **Commands**: `MRMediaRemoteSendCommand` from the private MediaRemote.framework (dlopen).
  Probed on macOS 27.0.1: sending still works for an unentitled, non-sandboxed app (pause/play
  of a browser video round-tripped) and needs no permission; only *reading* Now Playing is
  blocked since 15.4. Fallback if sending ever fails: system media-key events posted with
  `CGEvent.post` — needs Accessibility; the menu then shows "Playback control: needs
  Accessibility — Open Settings" and the phone falls back to mute.
- **Now Playing info**: the vendored [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
  v0.7.7 (BSD-3-Clause, `ThirdParty/mediaremote-adapter`, `vendor.sh` pins the commit). The
  entitled `/usr/bin/perl` runs `mediaremote-adapter.pl` from the app's Resources and loads
  `MediaRemoteAdapter.framework` (built by the `MediaRemoteAdapter` target, embedded, not
  linked) — `stream` prints JSON lines that `MediaRemoteAdapterStream` (BridgeCore) merges.
  No permission needed. `NowPlayingMonitor` restarts the child with a backoff.
- Pausing leaves the stream running: the virtual device keeps the stream alive and sends
  silence, no reconnect, the M2.8 fades are unchanged.

## Trust assumption

Personal MVP: local network only, no authentication. The Mac closes control connections from
non-local addresses (RFC 1918, link-local, loopback, IPv6 ULA/link-local), the phone refuses a
resolved non-local peer. Anyone on the same LAN who runs the app can control a Mac's stream.

## Second Mac

`scripts/package-sender.sh` builds `build/MacAudioBridge-Sender.zip` (Release app + driver +
`install-driver.sh` + `INSTALL.txt`). On the other Mac: unzip, follow `INSTALL.txt` (quarantine
removal, driver install with sudo, copy the app, allow Local Network and System Audio Recording).
