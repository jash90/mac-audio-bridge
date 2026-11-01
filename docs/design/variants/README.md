# iPhone redesign — three directions

The user said the Sources list is fine, but latency and details look mediocre. These are three different redesigns of everything else.
All three are mockups built with mock data (`Apps/Receiver-iOS/DesignLab/`). None of them is connected to the engine.
Sources is the same polished list in all three (status dot on a Mac icon, plays-here waveform, one "Output" section for the active Mac with volume, quality and Disconnect, plus "Add a Mac by address"). Only where it opens changes.

Contact sheets: [A](A-sheet.png) · [B](B-sheet.png) · [C](C-sheet.png). Single screens are named `<variant>-<screen>-<state>-<light|dark>.png`.

## A — Now Playing first
A big player card is the screen: artwork, title, artist and "Spotify on MacBook Pro", transport, volume and a quality chip. Under it, one card says how the link is in plain words, with three numbers (path, total delay, MB/h). Below that come the Delay control (Low / Balanced / Safe with one sentence on what it means) and the "Talk through iPhone" card.
The Mac picker sits in the title as "MacBook Pro ⌄" and opens Sources as a sheet. Details is a calm grouped list: a verdict, then where the delay comes from (stacked bar), then network, packets, audio, data and advanced.

- **Pros:** the most familiar layout (it looks like Music or Spotify), calm, and the "what is playing" question comes first. Details reads like iOS Settings.
- **Cons:** you scroll to reach the mic and the delay control. Link quality is a sentence, not something you can read at a glance.

## B — Control panel
Three tabs: **Now · Sources · Details**. Now is a dense dashboard:
- a compact now-playing strip;
- a link score ring with the verdict, the path and the jitter;
- four live tiles: delay with a sparkline, loss with a sparkline, quality, and data in MB/h;
- three big delay-mode buttons, each with its ms value;
- a volume row and a mic tile with a LIVE badge, a meter and mute.

Details is an instrument panel: a packet-delay chart against the buffer line, loss per second, the delay budget, and a spec-sheet grid of every counter.

- **Pros:** you see everything at a glance, and every number is one tap away. The Details charts best explain *why* the sound crackles. Sources gets its own tab.
- **Cons:** busy for someone who only wants to listen. The idle state is mostly empty tiles. It looks more like a tool than a product.

## C — Glance
One screen with no scrolling. A big glass orb shows **one number** (the total delay in ms) and **one word** (Excellent / Okay). Below it are the track and the transport, a three-stop delay slider with a plain sentence, and a glass dock with volume, quality, mic and Details. The background tint follows the link: cyan when the link is good, amber when it is worse, grey when no Mac is connected.
Details reads like a short report that answers three questions: "Where do the 210 ms go?", "How is the connection?" and "How much data?". The raw counters come last, in a tidy table.

- **Pros:** the most distinctive look, and it uses Liquid Glass best. You understand it in one second. Details explains things in human terms, which is the part the user called mediocre.
- **Cons:** it hides the most. The path and the loss are only in Details. The large orb leaves little room for longer titles or large Dynamic Type sizes.

## How to run
Launch the Receiver with `-DesignLab A|B|C` and, optionally:
- `-DesignState wifi|cellular|idle`
- `-DesignScreen home|details|sources`
- `-DesignAppearance light|dark`
- `-DesignScroll end` (opens the screen scrolled to the bottom)

To regenerate the sheets, run `swift scripts/design-contact-sheet.swift docs/design/variants`.
