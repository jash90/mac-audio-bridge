# Stronger compression for the audio stream: lossless and lossy options

Research, 2026-11-01. Nothing in the app was changed; all probes ran in a scratch directory outside the repo.

## TL;DR

- **Lossless does not pay off.** At our 5 ms frames FLAC brings real music to **63–66 % of PCM** (about 1.0 Mbit/s of payload). With 10 ms frames it is 60–64 %, and even 4096-sample blocks only reach 56–62 %. With the PCM-style copy datagram, the wire rate is still about **2.2 Mbit/s and ≈ 1 GB/h**.
  - The iPhone sends AirPods **AAC over Bluetooth (≈ 256 kbit/s)**, so nothing lossless reaches the ear.
  - Our current Opus 192 already scores the same as the original on the objective metric (ViSQOL 4.72 vs 4.73).
  - Lossless is only worth it for a wired DAC or AirPods Max on the USB‑C cable.
- **On the Internet profile, redundancy costs more than the codec.** Today every frame is sent three times (N = 2 copies), so 71 % of the 199 MB/h is copies and headers. Three changes help, from cheapest up:
  1. **Lower Opus bitrates** with the same layout: 96 → 156 MB/h, 64 → 113 MB/h.
  2. **20 ms Opus frames on WAN.** The WAN datagram already waits 20 ms, so this adds no latency. Opus 64 @ 20 ms scores like today's Opus 128 @ 5 ms (ViSQOL 4.61 vs 4.62), at **108 MB/h**.
  3. **Low-bitrate redundant copies** (copies at 24 kbit/s instead of full rate): Opus 96 at **87 MB/h**, Opus 64 at **72 MB/h**. Under 5 % loss these copies recover almost as well as full copies (ViSQOL 4.56–4.57 vs 4.58; plain PLC gives 4.50).
- **No new codec beats Opus here.**
  - AAC-ELD from Apple is band-limited below 128 kbit/s: 5.5 kHz at 64 kbit/s.
  - HE-AAC and AAC-LC add 65–130 ms of delay.
  - LC3 needs about 30 kbit/s more than Opus for the same score.
  - In-band FEC and DRED do not work for music in our mode.
- **Recommended ladder for cellular** (all over Tailscale, including the 88 B per datagram):

  | Step | Setting | MB/h |
  |---|---|---|
  | High | Opus 128 | 101 |
  | Standard | Opus 96 | 87 |
  | Saver | Opus 64 | 72 |
  | Floor ("still pleasant") | Opus 48 | 65 |

  Every step uses 20 ms frames plus 2 copies at 24 kbit/s. The floor is the lowest setting I'd still call pleasant.

## 1. Method

**Material.** Five 60 s excerpts (from 0:45), decoded to 48 kHz / 16‑bit stereo with ffmpeg. The 44.1 kHz sources were resampled. Audio was only read locally into the scratch directory and deleted after the run; none is in the repo or in this report.

| id | genre | source |
|---|---|---|
| t1 | electronic / hip-hop remix, loud master | CD FLAC 44.1 kHz |
| t2 | pop-rock | 48 kHz WAV |
| t3 | folk / epic, orchestral | 48 kHz WAV |
| t4 | unknown genre, quiet passages | AAC 256 kbit/s m4a (lossy source) |
| t5 | speech podcast | MP3 |

t4 and t5 come from lossy, low-passed or quiet sources, which inflates lossless ratios. For lossless, t1–t3 are the honest numbers.

**Tools.**
- libFLAC 1.5.0 CLI.
- ffmpeg 8 for its WavPack encoder.
- Apple's open-source ALAC (macosforge/alac, Apache‑2.0) and the AudioToolbox ALAC/AAC converters.
- **libopus 1.5.2** built from the same tarball as `ThirdParty/opus` (sha256 `65c1d2f7…`), through a C harness using our settings: CBR, complexity 10, `SIGNAL_MUSIC`.
- liblc3 (google/liblc3 main).

CPU was timed single-threaded per frame on this Mac (Apple Silicon); the iPhone 16‑class cores are comparable.

**Quality metric.** `visqol-python` 3.8.0, a pure-Python port of ViSQOL v3.3.3 in audio mode. The C++ original needs Bazel.
- It ran on 20 s of each track (0:20–0:40), on L and R separately, after aligning the decoded signal by cross-correlation. The score is the mean of L and R.
- The scale tops out at **4.73** (reference against itself).
- Sanity anchors on t2: a 15 kHz low-pass scores 4.24, a 7 kHz low-pass 2.59.
- SNR and a bandwidth check (highest 500 Hz band within 10 dB of the reference) are reported next to it.

**How far to trust it.**
- ViSQOL ranks settings *within one codec* sensibly: bitrate and frame size move it monotonically, within about ±0.05 noise per track. t3 shows a couple of non-monotonic 0.05 steps.
- It **saturates above about 4.6**: it cannot separate 128 from 192 kbit/s, or "very good" from "transparent".
- It is lenient on low-rate Opus. Opus 32 kbit/s still scores 4.36, while listening tests rate it clearly degraded.
- It rewards SBR-generated highs more than a listener might.
- Across codec families (Opus vs SBR codecs) the numbers are indicative only.

I therefore set the "still pleasant" floor from the measured curve *and* from published listening tests: in the 2014 Hydrogenaudio 96 kbit/s multiformat test Opus came first, but no codec was reliably transparent at 96. A short blind listening pass on the user's own music is the missing step before the ladder is final.

## 2. Lossless at low delay

### Measured size per frame

The tables give the share of PCM16 size, with mean / p99 / max frame bytes. The datagram budget is 1176 B (1200 B minus the 24 B header).

| codec, block | t1 electronic | t2 pop-rock | t3 folk | t4 (AAC src) | t5 speech | frames > 1176 B (music) |
|---|---|---|---|---|---|---|
| FLAC ‑8, 5 ms (240) | 65.8 % · 632/794/852 | 66.2 % · 635/731/758 | 63.3 % · 608/712/748 | 29.7 % | 27.3 % | 0 % |
| FLAC ‑8, 10 ms (480) | 64.0 % · 1228/1551/1658 | 63.9 % | 59.6 % | 27.9 % | 25.6 % | 43–65 % |
| FLAC ‑8, 20 ms (960) | 62.8 % | 62.6 % | 57.3 % | 27.0 % | 24.7 % | 100 % |
| FLAC ‑8, 4096 (reference) | 62.2 % | 61.6 % | 56.1 % | 27.0 % | 24.6 % | — |
| ALAC (Apple OSS), 5 ms | 67.1 % · 644/814/964 | 68.1 % | 67.4 % | 34.0 % | 29.9 % | 0 % |
| ALAC (Apple OSS), 10 ms | 65.2 % | 66.0 % | 65.3 % | 31.8 % | 28.2 % | > 50 % |
| WavPack (ffmpeg, ‑l3), 5 ms | 76.2 % | 75.8 % | 75.7 % | 44.7 % | 42.4 % | 0 % |
| WavPack, 10 ms | 67.8 % | 67.7 % | 66.4 % | 35.3 % | 35.3 % | 80–85 % |

**Ratios.**
- Real, mastered music at our 5 ms frames is **~65 % of PCM**, about **1.0 Mbit/s** instead of 1.536.
- Small blocks cost only 2–7 points against big blocks. Mastered pop is simply hard to compress losslessly.
- Ratios like the 25–30 % on t4/t5 only appear with quiet, low-passed or already-lossy material.

**Worst case.**
- A 5 ms FLAC frame always fits one datagram. FLAC falls back to verbatim, so the bound is about 960 B + 15 B header; the largest seen was 852 B.
- A 5 ms ALAC frame has the same bound, through its escape frame (964 B max).
- No second frame or redundant copy fits next to it, so the redundancy copy needs its own datagram, as PCM16 does today.
- 10 ms lossless frames exceed 1176 B in roughly half the frames, which would mean fragmentation.

**CPU** (per 5 ms frame, single core):

| codec | encode | decode |
|---|---|---|
| FLAC ‑8 | 37 µs | ~6 µs |
| FLAC ‑5 | 12 µs | ~6 µs |
| ALAC | 29 µs | — |
| ALAC on AudioToolbox, 480-frame packets | — | 16 µs |

CPU is a non-issue (for comparison, Opus 192 @ 5 ms takes 57 µs to encode and 13–23 µs to decode).

**ALAC via AudioToolbox — a trap.**
- The macOS AudioToolbox ALAC **encoder accepts only 4096 frames per packet**: 240–2048 all fail with `fmt?`.
- The AudioToolbox **decoder rejects ALAC frames shorter than 352 samples**: 240/256/288/320 fail with `!dat`. It decodes 352, 384 and 480 **bit-exactly**; 352 is the AirPlay/RAOP frame size.
- So "native ALAC on both ends" is impossible at 5 ms. At 10 ms it would need a vendored encoder on the Mac (Apple OSS, Apache‑2.0) plus fragmentation, because frames average 1250 B.
- FLAC is 1–4 points smaller than ALAC anyway.

**Data use with the current layout** (frame plus one copy datagram, 400 datagrams/s):

| | LAN | Tailscale |
|---|---|---|
| FLAC 5 ms | 2.2 Mbit/s, ≈ 994 MB/h | ≈ 1.08 GB/h |
| PCM16 today | 3.25 Mbit/s, 1.46 GB/h | — |
| FLAC 5 ms, no copy | 1.1 Mbit/s, 497 MB/h | — |

On cellular, lossless is pointless: it is 5–15× the data of the lossy ladder below.

### Does lossless help with AirPods?

No, not on the phone-to-AirPods path. Sources are listed in the table at the end.

- **AirPods get AAC over Bluetooth.** Apple: "Bluetooth connections aren't lossless". The bitrate is about 256 kbit/s; Apple states it only second-hand.
- **The iPhone always re-encodes.** It mixes system sounds and applies EQ/Spatial Audio, so audio is decoded, mixed and re-encoded to AAC. Apple has no public passthrough statement, but our app plays decoded PCM through AVAudioEngine anyway, so re-encoding is certain for us.
- **Lossless on AirPods exists only in two cases:**
  - AirPods Max (USB‑C) on a **USB‑C cable** (iOS/macOS 18.4 / 15.4, 24‑bit/48 kHz).
  - AirPods Pro 3, AirPods Pro 2 (USB‑C), AirPods 4 and Powerbeats Pro 2 **with Apple Vision Pro only**, over a proprietary low-latency protocol.
- I found nothing in iOS 26 that adds lossless Bluetooth from iPhone; its AirPods changes were recording and call quality.
- **Our current Opus 192 already measures as the source:** ViSQOL 4.72 against the reference's 4.73. Opus 128 @ 20 ms also scores 4.71. A second lossy stage (AAC 256 in the phone) after a near-transparent first stage is inaudible in practice.

**When lossless would matter:**
- a wired USB‑C / Lightning DAC or headphone adapter on the iPhone,
- AirPods Max on the USB‑C cable,
- possibly an AirPlay receiver, if the receiver app ever forwarded audio there (it does not).

The iPhone speaker gains nothing.

**Verdict:** do not add lossless now. If the user later uses a wired DAC, add "Lossless (FLAC, LAN only)" as a separate codec. See §4 for the cost.

## 3. Lossy: stronger than today and still pleasant

### Opus: bitrate × frame size

All settings: RESTRICTED_LOWDELAY, CBR, complexity 10. Scores are ViSQOL means over the music tracks t1–t4; speech is t5. "Lat." is the algorithmic delay: frame plus 2.5 ms lookahead.

| kbit/s | 5 ms (lat. 7.5 ms) | 10 ms (12.5 ms) | 20 ms (22.5 ms) | speech @ 20 ms |
|---|---|---|---|---|
| 192 | **4.72** | 4.72 | 4.72 | 4.73 |
| 128 | **4.62** | 4.65 | 4.71 | 4.73 |
| 96 | 4.61 | 4.62 | 4.62 | 4.61 |
| 80 | 4.58 | 4.62 | 4.63 | 4.60 |
| 64 | 4.45 | 4.59 | **4.61** | 4.59 |
| 48 | 4.33 | 4.44 | **4.53** | 4.46 |
| 32 | 4.33 | 4.26 | 4.36 | 4.28 |

Bold marks today's settings (192 and 128 at 5 ms) and the key new points (64 and 48 at 20 ms).

**Findings:**
- **Frame size matters more than bitrate below 96 kbit/s.** 5 ms frames cost about one bitrate step: 64 @ 20 ms ≈ 96 @ 5 ms ≈ 128 @ 5 ms. This matches the Opus paper (5 ms frames are lower quality but "still acceptable"). At 96 kbit/s and above, frame size makes no measurable difference, so LAN can stay at 5 ms.
- **Every Opus setting keeps full bandwidth** (to 20.5 kHz, the sources' limit). CELT degrades by coarser quantisation and band folding, not by low-passing. That is why it stays "pleasant" down to about 48 kbit/s. SNR, for reference: 25 dB at 192 @ 5 ms, 13.5 dB at 64 @ 5 ms, 14.4 dB at 48 @ 20 ms. SNR is meaningless for perceptual codecs and is shown only as asked.
- **Constrained VBR vs CBR: no gain** (+0.00–0.02 at 48/64/96, 5 and 20 ms). Keep CBR, because sizes stay fixed and the datagram budget stays trivially safe.
- **AUDIO vs RESTRICTED_LOWDELAY: identical quality** (64 @ 20 ms: 4.611 vs 4.610; 96 @ 10 ms: 4.62 vs 4.62). For stereo music at these rates the encoder chooses CELT-only anyway. AUDIO only adds lookahead: 312 instead of 120 samples, **+4 ms**. Keep RESTRICTED_LOWDELAY.
- **In-band FEC: harmful for music.** FEC (LBRR) exists only in SILK/hybrid frames; the source code returns no FEC for CELT-only. With AUDIO + FEC + 10 % expected loss, the encoder switched 97 % of frames to hybrid, and quality dropped: 64 kbit/s scored 4.45 against 4.61 without FEC (48 kbit/s: 4.43 vs 4.53). LBRR also covers only one frame, at SILK quality.
- **DRED / Deep PLC / OSCE (1.5) and the 1.6 updates** (released 2025‑12‑15: smaller DRED that does not interoperate with 1.5, speech bandwidth extension, a 96 kHz "HD" layer, 24‑bit API) are trained on speech and need the dnn models. The 1.6 notes list no CELT or music change. **Stay on 1.5.2**; upgrading gains nothing for this stream.
- **Complexity 5 = complexity 10** in quality (64 @ 5 ms: 4.457 vs 4.452) at about 25–40 % less encoder CPU. That is optional, since CPU is tiny either way: Opus 20 ms encode is 100–170 µs per 20 ms (< 1 % of a core), decode about 30 µs.

### AAC via AudioToolbox

Measured on macOS. Bitrate control mode is "constant", but sizes still vary through the bit reservoir.

| variant | frame | measured delay | kbit/s accepted (stereo 48 k) | ViSQOL | notes |
|---|---|---|---|---|---|
| AAC‑LC | 1024 | 2112 priming → **≈ 65 ms** | — | 128: 4.53 · 96: 4.30 · 64: 3.64 | low-passed at 17.5 / 16 / 12 kHz |
| HE‑AAC v1 | 2048 | 4224 → **≈ 130 ms** | 32–64 | 64: 4.58 · 48: 4.51 | delay disqualifies it |
| HE‑AAC v2 | 2048 | 4224 → ≈ 130 ms | 24–48 | 48: 4.52 · 32: 4.44 | delay disqualifies it |
| AAC‑ELD | 480 / 512 | 240–312 → **≈ 15–16 ms** | **≥ 64 only** | 128: 3.99 · 96: 3.14 · 64: 2.05 | **band-limited: 5.5 kHz @ 64, 10 kHz @ 96, 13.5 kHz @ 128** (FaceTime tuning); codec quality setting has no effect |
| AAC‑ELD + SBR | 480 | 240 → ≈ 15 ms | ≥ 56 | 64: 4.30 · 56: 4.26 | full band via SBR, but below Opus 64 @ 5 ms (4.45) at twice Opus's delay; ViSQOL is generous to SBR |
| AAC‑LD | 480 | 511–536 → ≈ 21 ms | — | 64: 2.05 · 96: 3.13 | same band limit as ELD |
| AAC‑ELD v2 | — | — | — | — | not available (`fmt?`) |

**Verdict:** nothing in AudioToolbox beats Opus at low delay. AAC-ELD would also need a new codec path on both ends. On iOS it is decoded by the system, but that saves nothing, since the iPhone already runs libopus.

### LC3 (liblc3, Apache‑2.0)

| | 5 ms | 10 ms |
|---|---|---|
| 96 kbit/s | 4.43 | 4.55 |
| 128 kbit/s | 4.59 | 4.63 |
| 160 kbit/s | 4.66 | 4.66 |
| 192 kbit/s | 4.69 | — |

- Delay is 2.5 ms plus the frame, and CPU is about 13 µs per 5 ms frame.
- At 5 ms, LC3 needs **~128 kbit/s to match Opus 96** and ~160 to match Opus 128. It brings no feature we lack, because our own redundancy already exceeds its packet-loss tooling.
- LC3plus (ETSI TS 103 634; liblc3 implements its 2.5/5 ms frames and HR mode) has Fraunhofer/Ericsson patents. Fraunhofer's 2021 terms make the HR mode royalty-free, but the rest needs a licence. Not worth the legal uncertainty.
- **Do not add LC3.**

### Loss resilience: our redundancy vs alternatives

In-band FEC and DRED are ruled out above. The real lever is **what the redundant copies cost**.

Experiment: Opus 96 @ 20 ms, i.i.d. 5 % datagram loss, each datagram carrying one copy of the previous frame. 164 of 170 lost frames were recovered and 6 double losses were concealed. Scores are on t1–t3; the same setting without loss scores 4.617.

| copy of the lost frame | ViSQOL |
|---|---|
| none (Opus PLC only) | 4.50 |
| full-rate copy (what we do today) | 4.58 |
| copy from a second encoder at 48 kbit/s | 4.58 |
| at 32 kbit/s | 4.57 |
| at 24 kbit/s | 4.56 |
| at 16 kbit/s | 4.56 |

- Copies at 24–32 kbit/s recover almost everything a full copy does, at a quarter to a third of the bytes.
- The receiver feeds the copy to the *same* decoder. Opus tolerates packets from a different encoder instance (bitrate switches are normal in Opus); no errors or bursts appeared.
- This is the RFC 2198 "RED with a lower-rate secondary" idea.
- Caveat: ViSQOL averages over 20 s. The *audibility* of the short low-rate patches during a loss burst still needs a listening check.

## 4. Packetisation and data use

The model follows `DatagramLayout` / `RedundancyPacker`: 24 B header, 3 B per entry. Per datagram, LAN adds 28 B of IPv4+UDP and Tailscale direct adds 88 B (IPv4 + UDP + WireGuard 32 + inner IPv4 + UDP). With IPv6 inside the tunnel it is 20 B more; on a DERP relay, about 41 B more. "Burst" is the longest run of lost datagrams that is fully recovered.

### Today (for reference)

| setting | datagram | pkt/s | LAN | Tailscale | latency added by framing | burst |
|---|---|---|---|---|---|---|
| PCM16 5 ms + copy datagram (+15 ms) | 987 B ×2 | 400 | 3.25 Mbit/s · 1462 MB/h | 1548 MB/h | 5 ms | 3 datagrams |
| Opus 192, 5 ms, N = 4 (LAN) | 639 B | 200 | 1.07 Mbit/s · 480 MB/h | 523 MB/h | 7.5 ms | 20 ms |
| Opus 128, 5 ms, N = 4 (LAN) | 439 B | 200 | 747 kbit/s · 336 MB/h | 379 MB/h | 7.5 ms | 20 ms |
| **Opus 128, WAN 4×5 ms + 8 copies** | 1020 B | 50 | 189 MB/h | **199 MB/h** (443 kbit/s) | 22.5 ms | 40 ms |

On WAN, copies and headers are 71 % of the bytes; the audio itself is only 128 kbit/s of 443.

### Recommended settings

All WAN rows keep 50 datagrams/s and the same 20 ms packetisation as today, so they add **no latency**. The jitter buffer floor (120–200 ms) dominates anyway.

| step | setting | datagram | pkt/s | LAN | Tailscale | ViSQOL (no loss) | burst |
|---|---|---|---|---|---|---|---|
| LAN default | Opus 192, 5 ms, N = 4 (unchanged) | 639 B | 200 | 480 MB/h | 523 MB/h | 4.72 | 20 ms |
| LAN option | **Opus 96, 5 ms, N = 4** | 339 B | 200 | 264 MB/h | 307 MB/h | 4.61 | 20 ms |
| A — bitrate only | Opus 96, WAN 4×5 ms, N = 2 | 780 B | 50 | 145 MB/h | **156 MB/h** | 4.61 | 40 ms |
| A — bitrate only | Opus 64, WAN 4×5 ms, N = 2 | 540 B | 50 | 102 MB/h | **113 MB/h** | 4.45 | 40 ms |
| B — 20 ms frames | Opus 128, 20 ms, N = 2 | 993 B | 50 | 184 MB/h | 195 MB/h | 4.71 | 40 ms |
| B — 20 ms frames | Opus 96, 20 ms, N = 2 | 753 B | 50 | 141 MB/h | **151 MB/h** | 4.62 | 40 ms |
| B — 20 ms frames | Opus 64, 20 ms, N = 2 | 513 B | 50 | 97 MB/h | **108 MB/h** | 4.61 | 40 ms |
| B — 20 ms frames | Opus 48, 20 ms, N = 2 | 393 B | 50 | 76 MB/h | **87 MB/h** | 4.53 | 40 ms |
| C — + 24 k copies | Opus 128 + 2×24 k | 473 B | 50 | 90 MB/h | **101 MB/h** | 4.71 | 40 ms (copies at 24 k) |
| C — + 24 k copies | Opus 96 + 2×24 k | 393 B | 50 | 76 MB/h | **87 MB/h** | 4.62 | 40 ms |
| C — + 24 k copies | Opus 64 + 2×24 k | 313 B | 50 | 61 MB/h | **72 MB/h** | 4.61 | 40 ms |
| C — + 24 k copies | Opus 48 + 2×24 k | 273 B | 50 | 54 MB/h | **65 MB/h** | 4.53 | 40 ms |
| C — + 3 copies | Opus 96 + 3×24 k | 456 B | 50 | 87 MB/h | 98 MB/h | 4.62 | 60 ms |

Rows considered and rejected:
- **40 ms per datagram** (25 pkt/s): saves only about 8 MB/h of headers (Opus 64: 69 instead of 79 MB/h with one copy) and adds 20 ms of latency.
- **N = 1 copy at full rate**: Opus 64 @ 20 ms is 79 MB/h, but it covers only 20 ms bursts. Low-rate copies give N = 2 coverage for less.
- **10 ms frames on WAN** (2×10 ms per datagram): quality is between 5 and 20 ms at the same bytes, so there is no reason to prefer it.

### The cellular floor

Opus **48 kbit/s @ 20 ms** stays full-band, scores 4.53 (close to Opus 128 @ 5 ms, 4.62), and holds up on speech (4.46). Below that, 32 kbit/s drops on all three music tracks t1–t3 (4.22–4.37) and is known from listening tests to sound narrow and smeared on stereo music. The floor is **48 kbit/s at 20 ms frames, never at 5 ms frames** (48 @ 5 ms scores 4.33, below 64 @ 5 ms).

## 5. Recommendation for the Quality picker

**LAN (Wi‑Fi):** keep Opus 192 (default), Opus 128 and PCM. Optionally add **Opus 96** (5 ms, N = 4). Data hardly matters on Wi‑Fi, and today's choices are already at or near the metric's ceiling.

**Internet / cellular:** replace the fixed "Opus 128" with a small ladder, default **Standard**. The table shows target MB/h over Tailscale.

| step | today's layout (A) | 20 ms frames (B) | + low-rate copies (C) |
|---|---|---|---|
| High — Opus 128 | 199 | 195 | **101** |
| Standard — Opus 96 | 156 | 151 | **87** |
| Saver — Opus 64 | 113 | 108 | **72** |
| Floor — Opus 48 | 91 (sounds worse at 5 ms) | 87 | **65** |

### Implementation options and cost

1. **Minimal (A), about ½ day, Opus-only.**
   - Add `StreamQuality` cases `opus96` / `opus64` (optionally `opus48`) with their bitrates. `setBitrate` already exists.
   - Let `StreamProfile.effectiveQuality` keep a lower user pick on WAN instead of forcing 128, and show the choice in the menu.
   - No wire, decoder or layout change. The WAN layout stays 4×5 ms + 8 copies, and `receiverDescription` already derives kbit/s from the payload size.
   - Result: 156 / 113 MB/h. Note that 64 kbit/s at 5 ms frames is audibly the weakest step.
2. **Best (B + C), about 3–4 days in total.**
   - **B: 20 ms Opus frames on WAN, about 1.5–2 days.**
     - The wire assumes `samplesPerFrame` = 240 per sequence slot, so it needs a frame-duration field (or a codec value `opus20`) and a version bump. Both apps are always updated together.
     - Let one 20 ms frame occupy 4 sequence slots, or carry its own count.
     - The receiver decodes 960 samples on arrival and pushes four 5 ms PCM frames into the jitter buffer.
     - Opus PLC runs at 20 ms granularity.
     - Plus tests: datagram ≤ 1200 B, the LAN↔WAN switch crossfade, and loss runs.
   - **C: low-rate copies, about 1.5–2 days on top.**
     - A second `OpusEncoderBox` on the Mac runs at 24 kbit/s with the same frame size, fed the same PCM.
     - The packer puts the low-rate packet into copy entries; a flag bit on the entry is for stats.
     - The receiver already takes "first arrival per slot". It must prefer a late primary over an earlier copy (rare reordering) and count `copyFramesUsed`.
     - CPU doubles, from < 1 % to < 2 % of a core.
     - Data roughly halves at every step.
3. **Not recommended now:**
   - **FLAC lossless**, about 3–4 days. It means vendoring libFLAC (BSD‑3, ~40 C files, no SIMD needed at this size), a new codec value, the PCM-style separate copy datagram, LAN only, and a picker entry "Lossless (wired headphones)". The only benefit is for wired DAC or AirPods Max cable users.
   - **AAC-ELD, HE-AAC, LC3 or LC3plus**, any of them: a new codec path with no gain over Opus.

### Risks

- **The metric is a proxy.** ViSQOL (a Python port) saturates near 4.7 and is lenient at low bitrates. Run a short blind A/B on the phone before fixing the ladder, for example Opus 64 @ 20 ms against today's 128 @ 5 ms, and a 5 % / 10 % loss run with 24 k copies.
- **20 ms frames are in the WAN path only.** They lengthen PLC gaps per lost unconcealed frame (20 ms instead of 5 ms), which the copies cover. Keep 5 ms on LAN for lowest latency.
- **Low-rate copies are unusual.** WebRTC RED repeats identical packets. Decoder-state mismatch after a substituted frame was harmless in the probe but deserves a crackle-metric test (the M2.8 suite).
- **Licences.**
  - libopus: BSD‑3, already vendored. Keep 1.5.2; 1.6.x brings nothing for CELT music.
  - libFLAC: BSD‑3.
  - Apple ALAC: Apache‑2.0.
  - liblc3: Apache‑2.0, but LC3 and LC3plus patents are held by Fraunhofer/Ericsson.
  - AAC via AudioToolbox is covered by Apple's licence on its platforms.

## Sources (web facts, checked 2026‑11‑01)

- Apple: AirPods codecs and "Bluetooth connections aren't lossless"; lossless with Vision Pro for AirPods Pro 3, Pro 2 (USB‑C), AirPods 4 and Powerbeats Pro 2 — https://support.apple.com/en-us/118295
- AirPods Max USB‑C lossless with iOS 18.4 — https://www.macrumors.com/2025/03/24/airpods-max-lossless-audio-coming-april/ , https://www.engadget.com/audio/headphones/how-to-use-lossless-audio-on-the-airpods-max-180026218.html
- iOS 26 AirPods features (no lossless) — https://www.macrumors.com/2025/08/08/ios-26-7-new-airpods-features/
- Opus 1.6 release notes (2025‑12‑15) — https://opus-codec.org/demo/opus-1.6/ ; Opus 1.5 — https://opus-codec.org/demo/opus-1.5/
- FEC only in the LPC (SILK) layer — https://opus-codec.org/docs/opus_api-1.3.1/group__opus__encoderctls.html ; `decide_fec()` in https://github.com/xiph/opus/blob/main/src/opus_encoder.c
- Opus paper (frame size vs quality, delays, AAC‑ELD ≈ 15 ms) — https://arxiv.org/abs/1602.04845
- Hydrogenaudio 96 kbit/s multiformat test 2014 — https://hydrogenaud.io/index.php/topic,106911.msg875036.html
- liblc3 — https://github.com/google/liblc3 ; LC3plus licensing — https://www.iis.fraunhofer.de/content/dam/iis/en/img/ff/Audio/patent-lizenz/Fraunhofer-LC3plus-Licensing.pdf
- visqol-python — https://pypi.org/project/visqol-python/ ; ViSQOL — https://github.com/google/visqol
- Earlier project research: `.agent-logs/research-opus.md` (vendoring, FEC gotcha), `.claude/tasks/07-internet-mode.md` (WAN profile).

The probe harnesses (`opusprobe.c`, `atprobe.swift`, `alacprobe.cpp`, `atdec.swift`, `lc3probe.c`, `lbrprobe.c`, `metric.py`) were built in a session scratch directory and are not part of the repo.
