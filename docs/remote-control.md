# Control from the iPhone and several Macs (M5c)

The iPhone lists every Mac running Mac Audio Bridge, shows its state, and picks the one it
plays. Several Macs can run the sender at once; the phone plays exactly one of them.

## Discovery

- Each Mac advertises `_macaudiosrc._tcp` (`Apps/Sender-macOS/Network/ControlServer.swift`):
  instance name = computer name, TXT `v=2`, `id=<UUID>` (generated once, UserDefaults
  `sourceID`). A TCP `NWListener` on port 49001 (any port if taken) serves the phones.
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

Now Playing / lock screen shows the active Mac's name; play/pause there unmute/mute that Mac.
Media keys sent to the Mac (play/pause/next) are not implemented: posting system media-key
events needs the Accessibility permission on the Mac.

## Trust assumption

Personal MVP: no authentication. Control connections are accepted only from the local network
and from the tailnet (`NetworkAddress.isTrustedForControl`): loopback, RFC 1918, link-local,
IPv6 ULA, and the Tailscale ranges `100.64.0.0/10` and `fd7a:115c:a1e0::/48`. Everything else
is refused — the Mac closes the connection, the phone refuses a peer outside these ranges.
Anyone on the same LAN or the same tailnet who runs the app can control a Mac's stream; the
tailnet is the user's own (Tailscale ACLs decide who is on it). See `docs/internet-mode.md`.

## Second Mac

`scripts/package-sender.sh` builds `build/MacAudioBridge-Sender.zip` (Release app + driver +
`install-driver.sh` + `INSTALL.txt`). On the other Mac: unzip, follow `INSTALL.txt` (quarantine
removal, driver install with sudo, copy the app, allow Local Network and System Audio Recording).
