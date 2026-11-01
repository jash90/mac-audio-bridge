# Receiver discovery and automatic reconnection (M3)

Why: the iPhone's DHCP address changed (.151 → .171) while the Mac kept streaming
to the typed-in old IP — silence, and the IP field was disabled while streaming.
Now nothing has to be typed and the stream follows the phone.

## How it works

- **Receiver advertises** (`Apps/Receiver-iOS/Network/UDPReceiver.swift`): the UDP
  `NWListener` (port 49000, any free port if taken; `serviceClass = .interactiveVoice`)
  publishes Bonjour `_macaudiobridge._udp` with TXT `v=3` (wire protocol 3: 5 ms frames, redundancy, source tag — see remote-control.md). The name is
  `UIDevice.current.name` (generic "iPhone" on iOS 16+) plus a random 4-character
  suffix persisted on first launch (`ReceiverIdentity`), e.g. `iPhone 7KQ2` — stable
  across launches, unique per phone. A failed listener is recreated with the same
  name. The screen shows "Visible to your Mac as …" and the IP small below; if iOS
  blocks the advertisement (Local Network permission), it explains how to allow it.
- **Sender discovers** (`Apps/Sender-macOS/Network/ReceiverBrowser.swift`): an
  `NWBrowser` runs from launch, owned by `SenderController` (never by a view).
  Selection is the pure `ReceiverSelection` state machine in BridgeCore:
  stored pick (`receiverServiceName`) > the only visible receiver (automatic) >
  manual host. A missing stored pick shows "Looking for <name>…" and resumes when it
  reappears; a vanished target is kept for 2 s so a receiver app restart does not
  stop the stream.
- **Connection** (`Apps/Sender-macOS/Network/UDPSender.swift`):
  `NWConnection(to: .service(name:type:domain:interface:))`, so each new connection
  resolves the service's current address. Packets still go straight from the
  converter queue to `NWConnection.send` — no buffering, no extra hop.
- **Liveness**: the receiver's 20 ms "MABK" keepalives arrive on the same
  connection. A 500 ms timer on the connection queue feeds `ReceiverLiveness`: 3 s of
  unanswered sends (or 3 s without a ready path) → cancel and recreate the
  connection, which re-resolves the service. No audio playing = nothing sent = idle,
  never a timeout.
- **Manual fallback**: "Manual address" disclosure in the menu, always editable.
  The pre-M3 `receiverHost` value is ignored until that section is opened once.

## Stats

`sender-stats.jsonl` gains `receiver`, `keepaliveAgeMs` (-1 = none), `connectionState`
(NWConnection state), `link` (connecting / alive / idle / noResponse) and `reconnects`.

## First launch

- **iPhone**: iOS asks for Local Network access — tap **Allow**. Until then the screen
  says "Local Network access needed" (Settings → Privacy & Security → Local Network).
- **Mac**: macOS 15 may ask "find devices on your local network" — **Allow**
  (System Settings → Privacy & Security → Local Network otherwise). With one iPhone
  running the receiver, the menu picks it automatically; with several, pick one.
