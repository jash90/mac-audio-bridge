# Internet mode over Tailscale (M7i)

Streaming keeps working when the iPhone leaves the Mac's Wi-Fi (5G, another Wi-Fi), as long as
both devices are on the same tailnet. Nothing is configured in the app: Tailscale provides the
addresses and the encryption (WireGuard); the apps never log in to or change Tailscale.

## What the user does

1. Install Tailscale on the Mac and the iPhone, sign in with the same account, keep the VPN on.
2. Pair once on the same Wi-Fi: open both apps; the phone's hello tells the Mac the phone's
   tailnet addresses, the Mac's status tells the phone the Mac's — both are stored.
3. From then on, leaving the Wi-Fi fails over by itself. Without a first pairing: Mac menu →
   Receiver → the iPhone listed "via Tailscale" (from `tailscale status --json`), or Manual
   address → `iphone171` / `100.x.y.z` → Use; on the phone: Sources → Add Mac by address.

## Address exchange and failover

- `PhoneHello.tailnetAddresses` / `SourceStatus.tailnetAddresses` (control protocol v2) carry
  the interface addresses in the Tailscale ranges (`InterfaceAddresses.tailnet()`).
- `PathFailover` (BridgeCore, pure, tested) picks the concrete path per peer: the Bonjour
  endpoint while it works, else the stored tailnet addresses (and typed hosts). A keepalive
  timeout (3 s on the LAN, 5 s on WAN) or a failed control connection moves to the next path;
  the LAN is retried only on evidence (Bonjour announces the peer again, or the phone's control
  connection arrives from a LAN address), with backoff, so a phone on 5G is not probed on the
  LAN every few seconds.
- Mac: the logical target stays the receiver service; `SenderController+Internet.swift` maps it
  to `.host(tailnet IP)` while the failover says remote. Receiver services with stored tailnet
  addresses stay valid targets while Bonjour cannot see them (`ReceiverSelection.remoteReachable`).
- Phone: `SourcesModel` reconnects control to the Mac's tailnet IP on port 49001 when the Mac is
  no longer browsed, and moves back to the LAN when it is.

## WAN profile

Chosen automatically (`StreamProfile.decide`): the remote address is a tailnet/public one, the
target is a host name, or the phone reports an expensive path (cellular, hotspot) in its
hello and in the keepalive flags byte.

| | LAN | WAN |
|---|---|---|
| codec | as picked | Opus 128 kbit/s (PCM / Opus 192 capped, the reason is shown) |
| frames per datagram | 1 (5 ms) | 4 (20 ms) |
| redundancy | Opus: previous 4 frames; PCM: frame −3 | previous two datagrams' 8 frames |
| largest datagram | 987 B (PCM) | 1020 B (≤ 1200 B budget under the 1280 B tailnet MTU) |
| datagrams/s | 200 (400 PCM) | 50 |
| jitter target (balanced) | 30–300 ms | 140–600 ms, adaptive up, 20 s window |
| receiver keepalive | every 20 ms | every 200 ms, sender timeout 5 s |

The datagram header (v4) marks the profile (bit 7 of byte 6) and the number of primaries; the
phone follows the mark of the newest datagram only (`ProfileFollower`) and retunes its jitter
buffer in place (`JitterBuffer.retune`, no reset), so LAN ↔ WAN switches are glitch-free and
need no restart.

Data on the wire, Opus 128 WAN over Tailscale direct: 24 B header + 12 × (3 + 80) B = 1020 B
payload + 88 B overhead (IP/UDP 28 + WireGuard 32 + outer IP/UDP 28) per datagram, 50/s =
443 kbit/s ≈ 199 MB/h (relayed through DERP ≈ 207 MB/h). For comparison on the LAN: Opus 192
≈ 480 MB/h, PCM ≈ 1462 MB/h.

## Data usage and path

Both apps show the session's bytes and a rolling "≈ MB/h", plus the path: "Wi-Fi",
"Tailscale direct" or "Tailscale relay" (the Mac reads `CurAddr` from `tailscale status --json`:
empty = relayed through DERP). `stats.jsonl` lines on both sides carry `path`, `profile`,
`bytesTotal` and `mbPerHour`.
