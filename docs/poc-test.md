# PoC manual test checklist

1. On the Mac: `xcodegen generate`, open `MacAudioBridge.xcodeproj`, run the **Sender** scheme — a hi-fi speaker icon appears in the menu bar.
2. On the iPhone: connect to the same Wi-Fi as the Mac and pair the Bluetooth headphones to the iPhone.
3. Build & run the **Receiver** scheme on the iPhone from Xcode (install needs your development team in Signing & Capabilities).
4. Approve the first-launch prompts: "Local Network" (iPhone) and audio capture / microphone (Mac, shown when you press Start).
5. Read the iPhone's Wi-Fi IPv4 address shown in big type on the Receiver screen.
6. On the Mac: open the menu bar item, type that IP address, press **Start**.
7. Play any audio on the Mac (e.g. Music or a YouTube video).
8. Expected: the audio is audible in the iPhone's headphones within ~1–2 s, and the Mac keeps playing it locally.
9. Receiver screen shows packets/s ≈ 100, buffered ms roughly steady, underruns near 0 (a few right after Start are normal).
10. Press **Stop** on the Mac — audio stops on the headphones; press **Start** again to confirm streaming resumes. If silent: re-check the IP, the Local Network permission (Settings → Privacy → Local Network) and the Mac's firewall.
