# AutoREQ

AutoREQ is a room-correction app for macOS. It measures your speakers in your room. It then
calculates a correction and applies the correction live to the audio of your Mac.

AutoREQ rebuilds the software features of the Omnissiah app by Tantrum Audio in Swift. AutoREQ is
an independent project. Tantrum Audio does not make, support or endorse it. AutoREQ does not control
the Tantrum Really Mean Sub, because the USB protocol of that device is not public.

## Screenshots

The screenshots show a simulated room with a stereo pair and a subwoofer.

The Measure screen compares the snapshots of the three speakers. It shows the magnitude, the coherence and the phase.

![The Measure screen with three speaker snapshots](docs/screenshots/measure.png)

The results page shows each channel after the correction, with the target curve as a dashed line.

![The calibration results with the corrected response of each channel](docs/screenshots/calibration-results.png)

The Loopback screen sets the devices, the volume and the trim of each speaker.

![The Loopback screen with the volume controls](docs/screenshots/loopback.png)

The Target Curve screen shows the selected preset or your custom curve.

![The Target Curve screen with the House Flat preset](docs/screenshots/target-curve.png)

## Features

- **Measure:** The app plays pink noise and shows the transfer function of the speaker. The chart
  shows the magnitude, the phase and the coherence. You can keep snapshots and compare them. You
  can also export a snapshot to CSV and import a CSV again.
- **Calibrate:** A guided procedure measures each speaker at one or more mic positions. The app
  then calculates the crossover, the level, the delay, the polarity and up to 48 EQ filters for
  each speaker.
- **Target curves:** Five preset curves are available. You can also make a custom curve from
  points.
- **Loopback:** The app captures the system audio from a virtual audio device. It applies the
  correction and sends the result to your speakers. A master volume, a correction strength and a
  trim for each speaker are available.
- **Mic calibration:** The app reads REW and miniDSP calibration files. The app also includes
  approximate curves for the bottom mic of the iPhone 17 Pro and the iPhone 18 Pro.
- **Export:** The app writes REW filter files, corrected-response CSV files and a results file.

## Requirements

- The app needs macOS 15 or later.
- You need a measurement microphone. A USB mic such as the miniDSP UMIK-1 is the easiest choice.
- For the loopback correction, you need a virtual audio device such as BlackHole 2ch or VB-Cable.

## Install

1. Download `AutoREQ.zip` from the latest release on GitHub.
2. Unzip the file, and move `AutoREQ.app` to the Applications folder.
3. Control-click `AutoREQ.app`, and select **Open**.

> **Caution:** The app has an ad-hoc signature only. Apple has not notarized it. macOS blocks
> the first start until you open the app with Control-click → **Open**.

When the app measures for the first time, macOS asks for access to the microphone. Click
**Allow**.

## Build from source

You need Xcode 16 or later.

```bash
git clone https://github.com/strikeout/autoREQ.git
cd autoREQ
swift test
./scripts/bundle.sh
open build/AutoREQ.app
```

The script `scripts/bundle.sh` writes the app to `build/AutoREQ.app`. Use the bundle, not
`swift run`. macOS gives microphone access only to an app bundle.

### Make the screenshots again

The app can draw its main screens with the simulated room and write PNG files. This mode
uses no audio device, and it does not change your saved settings.

```bash
./scripts/bundle.sh
open -W build/AutoREQ.app --args --screenshots "$PWD/docs/screenshots"
```

## Use the app

### Set the devices

1. Open **Settings → Audio**.
2. Select the measurement mic and its input channel.
3. If you have a calibration file for your mic, click **Import calibration file…**.
4. Select the speaker output device.
5. Select the sample rate. The app sets the mic and the output device to this rate.

### Measure a speaker

> **Warning:** The test signal is pink noise at −12 dBFS. Set your amplifier to a low volume before
> you start the noise.

1. Open **Measure**.
2. Select the output channel of the speaker.
3. Click **Start Noise**.
4. Wait until the status shows "OK — Measuring".
5. Click **Take Snapshot**, or use **Auto Capture**. Auto Capture stops when the reading is stable.

### Calibrate the room

1. Open **Calibrate**.
2. Select **Quick Measurement** or **Complete Measurement**.
3. Select a system template, and set the output channel of each speaker.
4. Click **Start Measurement**, and follow the steps on the screen.
5. On the results page, click **Apply to loopback**.

### Use the loopback correction

1. Install a virtual audio device, for example BlackHole 2ch.
2. In **System Settings → Sound → Output**, select the virtual device.
3. In AutoREQ, open **Loopback**.
4. Select the virtual device as the loopback input, and select your speakers as the output.
5. Click **Start**.

The loopback correction runs only while AutoREQ runs. If you close the window, the app continues
to run. Use **Bypass** to compare the sound with and without the EQ. The bypass keeps the
crossover and the levels, so the comparison stays level-matched.

## Mic calibration

Most measurement mics come with a calibration file for each serial number. Download the file for
your mic from the maker, and import it. Examples are miniDSP for the UMIK-1 and UMIK-2, and Dayton
Audio for the EMM-6 and UMM-6. No maker publishes a generic file for these mics, so AutoREQ does not
include one.

The built-in iPhone curves come from graphs that Faber Acoustical published. The values are
approximate and cover 30 Hz to 5 kHz only. If you use an iPhone as the mic over Continuity, set
**Mic Mode → Standard** in the menu bar. Voice Isolation removes steady noise and makes the
measurement wrong.

## Check the measurement chain

A loop-through device sends its output back to its input. Examples are VB-Cable and BlackHole.
The self-test measures such a device against itself.

```bash
open -W --stdout /tmp/selftest.txt build/AutoREQ.app --args --selftest "VB-Cable"
cat /tmp/selftest.txt
```

A correct chain shows a flat response near 0 dB and a coherence near 1. The last line is `PASS`
or `FAIL`.

## Known limits

- The input device and the output device must run at the same sample rate.
- The loopback path does not correct clock drift between two devices. The app resets the read
  position when the drift becomes too large, and this can make a click.
- The calibration does not include a phase correction pass or extra listening areas.
- The crossover is always a 4th-order Linkwitz-Riley filter.

## License

AutoREQ is free software under the GNU General Public License v3.0. See `LICENSE`.
