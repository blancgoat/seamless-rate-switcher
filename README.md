<img width="297" height="261" alt="image" src="https://github.com/user-attachments/assets/1717475b-3746-4c6e-ac48-5dfc36da735e" />



https://github.com/user-attachments/assets/e8b8c2ee-830b-4a9f-a59f-6587e2972266




# Seamless Rate Switcher

**English** | [한국어](README.ko.md)

<img width="97" height="110" alt="image" src="https://github.com/user-attachments/assets/70488b9b-4ba1-4839-a428-5697e95d04bb" />

**Bit-perfect sample rate switching for Apple Music on Mac.**

A menu bar app for the Music app on Mac.

1. **Automatic sample rate switching**: Every time the track changes, the output device's sample rate is set to match the track.
2. **Silence while switching**: When the sample rate changes, playback is paused until the DAC finishes switching to the new rate, then the track plays from the beginning.

## Getting Started

Works with both Apple Music streaming and local files in your library.
**Apple Silicon Macs only. Tested only on macOS 27.0.1.**

1. Download `Seamless-Rate-Switcher-<version>.zip` from [Releases](https://github.com/blancgoat/seamless-rate-switcher/releases/latest), unzip it, put `Seamless Rate Switcher.app` in `/Applications`, and launch it.
   - The app is not signed, so the first launch shows a warning that Apple cannot check it for malicious software. Go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run the command below in Terminal and open the app again.

     ```bash
     xattr -dr com.apple.quarantine "/Applications/Seamless Rate Switcher.app"
     ```

2. The menu bar shows a note and the output device's current sample rate, like **♫ 44.1k**.
3. Play music in the Music app, and the sample rate follows each track automatically.
4. The first time, macOS asks whether the app may control Music. Click **Allow**. This is needed to pause/resume while switching and to read the sample rate of local files.

## Setting the Wait Time

How long a DAC needs after a sample rate change before it can actually play sound depends on the device. Choose one of two ways.

### Fixed Time

Set it with the slider under **Pause While Switching** in the menu bar icon, anywhere from 0 to 20 seconds (default 5 seconds). You can also type a number in the box next to it and press Enter to set it in 10 ms steps.

- If **the beginning of the track gets cut off**, increase it.
- If **the pause feels too long**, decrease it.

### Ready Script

Instead of a fixed time, playback can resume the moment the playback device (DAC) is actually ready.

1. Prepare a script that **exits with 0** once the playback device (DAC) is ready at the new sample rate.
   - The app resumes playback as soon as the script exits. A non-zero exit is recorded as a failure, but playback still resumes right away.
   - If the script doesn't finish within 20 seconds, it is stopped and playback resumes.
2. Register the script with **Choose Ready Script…** under **Pause While Switching** in the menu bar icon.

An example script for the MOTU UltraLite mk5 is included (based on firmware 2.1.2). If you have the same model, build it and register it.

```bash
example_ready_scripts/motu-ultralite-mk5/build.sh
```

## Good to Know

- **This app controls Music directly.** On tracks where the sample rate changes, Music pauses for a few seconds. This is expected: it is waiting for the DAC to finish switching to the new rate. **Please don't press play — just wait.** While waiting, the menu bar icon changes from a note (♫) to a rest (<img width="50" height="25" alt="image" src="https://github.com/user-attachments/assets/8fbe970e-9dab-426c-a7a4-7971d1e1f7e6" />), and changes back to a note when playback resumes.
- For an Apple Music track that was already playing before the app launched, the sample rate is matched starting from the next track. Local files are matched right away.
- Sample rates the output device doesn't support are skipped.
- The app works by reading the Music app's internal logs, so it may stop working after a macOS or Music update.

## License

[GNU General Public License v3.0](LICENSE). You may use, modify, and even sell this software, but any version you distribute must also be released as open source under the same license.

## Building

You can build with just the Command Line Tools, no Xcode needed.

```bash
scripts/bundle.sh            # creates build/Seamless Rate Switcher.app
scripts/bundle.sh --install  # installs to /Applications and launches it
```

With only the Command Line Tools installed, SwiftPM's default build system can fail, so the script builds with `--build-system native`.
