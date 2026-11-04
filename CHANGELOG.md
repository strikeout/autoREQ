# Changelog

## v1.8.3

- The Room Analysis screen no longer stops the app after a sweep. Before, it drew the new impulse response with the old analysis for a moment.

## v1.8.2

- The app no longer stops when you remove a speaker or a listening area on the Calibrate screen.
- Extra mics, long sweeps and the SPL calibration now work at all sample rates. Before, the sample rings were too short.
- Find in the phase delay control now flattens the phase. Before, it doubled the phase slope.
- A delay tracker shift no longer makes the guided calibration skip a speaker.
- The app removes extra mics, spectrum channels and SPL channels that the current mic device does not have.
- The SPL log keeps its meters when you turn off a channel on the SPL screen.
- A short tap on Test Speakers no longer leaves the noise on.
- Stop Timer keeps the captures and adds no average. The averages now group by mic channel.
- The clip warning uses the measured crest of an audio file and the real crest of a sweep. The output clips at full scale, so the reference stays equal to the output.
- A new signal choice wins over an audio file that still loads. Auto Capture stops when the signal cannot start.
- A WAV import keeps 10 ms before the peak and 10 s after it.
- T20 and T30 need 35 dB and 45 dB of range, so each fit ends 10 dB above the noise (ISO 3382-1).
- The delay tracker ignores a shift of one sample, so it no longer moves back and forth.
- The impulse analyser uses only frames after a signal change. Before, a frame with the old signal could move the delay.
- A reference snapshot no longer adds a phase slope from the latency of another engine run.
- The remote server waits for the old port when it restarts. It closes a connection after 10 s and accepts 32 connections at most.
- A request with ms=nan no longer stops the app. A value that is not valid JSON gives an error reply.
- The Remote tab shows the correct network setting after you open it again. The token stays the same until the app quits.
- On the Target Curve screen, a drag moves only the point under the pointer at the start. The frequency field stays in 20 Hz to 20 kHz. The custom points stay when you select a preset.

## v1.8.1

- The Target Curve screen shows the presets as cards with a small preview of each curve.
- The chart fills the area under the curve and marks the bass, the midrange and the treble.
- The chart can show the measured room of the last calibration and the other presets.
- You can drag the points of the custom curve. The custom points stay when you select a preset.

## v1.8.0

- The new Remote tab in Settings starts a local web viewer and a JSON API. The server is off by default.
- The web viewer shows the live transfer function, the RTA and the SPL meters, and polls twice each second.
- The API reads the status, the responses, the impulse response, the spectrum and the SPL values.
- The API also starts and stops the generator and takes snapshots.
- Each request needs a random token. The server listens on 127.0.0.1 unless you allow the local network.

## v1.7.0

- The Room Analysis screen shows the STI, the STIPA and the class of a measurement.
- The screen also shows the transmission index of each octave band.
- You can set the speech level and turn the auditory masking and threshold on or off.
- The app can read the background noise in octave bands from a calibrated mic and include it in the STI.
- The self-test also checks that the loopback has an STI near 1.

## v1.6.0

- The optional phase correction adds all-pass filters, so the subs and the tops stay in phase at the crossover.
- The Complete Measurement mode has a space plan. Extra listening areas have a name, a size, positions and a weight.
- Diagnostic cards explain boundary nulls, room modes, reflections, weak measurements and uncorrected peaks.
- The cards show live on the Measure screen and on the results page.
- The latency drift check measures the latency 3 to 20 times and writes a CSV file.
- Settings has a buffer size and a Test Speakers button.

## v1.5.0

- The new SPL screen calibrates each input with a 94 dB or 114 dB calibrator.
- The meters show A, C and Z levels with Fast, Slow and Impulse time weighting, Leq, Lmax and peaks.
- The meters also show rolling Leq values for 1, 10 and 15 min, and the OSHA and NIOSH noise dose.
- You can add, remove and arrange the meters in a grid.
- The screen shows the band levels in octaves or 1/3 octaves.
- The SPL log writes one CSV line each second. It continues when the window closes.

## v1.4.0

- The Room Analysis screen measures with a log sweep. A sweep gives a 2 s impulse response and the harmonic distortion.
- The generator has a Log Sweep signal for the Measure screen.
- The screen shows EDT, T20 and T30 in octave bands or 1/3-octave bands, with the Lundeby noise correction.
- The screen shows C50, C80, D50, Ts and the direct-to-reverberant ratio.
- The screen shows the THD, H2 and H3 of a sweep.
- The energy-time curves of other snapshots can show in the same chart.
- Impulse responses export to and import from WAV files.

## v1.3.0

- The transfer function uses frequency-dependent windows (FTW). A narrow bass resonance now reads within 1 dB of its true level.
- Up to 8 mics of one interface measure at the same time. Each mic has its own delay and calibration file.
- In the guided calibration, each extra mic counts as one position.
- Track Delay follows the delay of each mic from its impulse response. It replaces the old delay search every 3 s.
- A snapshot can be the reference. The chart then shows the other traces relative to it.
- The phase delay moves the time reference of the live phase. Find sets it to the impulse peak.
- The capture timer takes snapshots at a set interval and can add their average.

## v1.2.0

- The generator plays pink noise, white noise, periodic pink noise, a sine tone, a dual sine or an audio file.
- The generator level is now an RMS level in dBFS. The old pink noise was 7.5 dB below its nominal level. The new default of −20 dBFS RMS gives the same loudness as the old default.
- Generator presets keep the signal, the level and the output channel.
- The new Spectrum screen shows an RTA of up to 8 inputs with a peak hold. The bands are 1/1 octave to 1/48 octave wide.
- The Spectrum screen also shows a spectrograph of the last 10 s to 5 min.
- With periodic pink noise, the impulse response is exact after one frame.
- The self-test also checks the RTA, a sine level and the periodic pink noise.

## v1.1.0

- The new Room Analysis screen shows the impulse response and the energy-time curve of a measurement.
- The screen lists the reflections in the first 100 ms with the delay, the level and the extra path length.
- The screen lists the room modes from 15 Hz to 300 Hz with the frequency, the level, the Q and the T60.
- Each live measurement and snapshot now keeps its impulse response.

## v1.0.1

- The auto scale of the response chart now shows a 60 dB window below the loudest point. Before, a subwoofer roll-off compressed all the curves into a thin strip.
- The charts no longer draw curves outside the plot area.
- The volume sliders no longer show dense tick marks.
- The target curve chart uses the same frequency labels as the other charts.
- The README shows screenshots of the main screens.

## v1.0.0

This is the first public release of AutoREQ.

- The Measure screen shows the transfer function, the phase and the coherence of a speaker with pink noise.
- You can keep snapshots, combine them, and export or import them as CSV files.
- The guided calibration measures each speaker at one or more mic positions.
- The calibration calculates the crossover, the level, the delay, the polarity and the EQ of each speaker.
- Five preset target curves and a custom curve are available.
- The loopback engine applies the correction live to the system audio.
- The Loopback screen has a master volume, a correction strength and a trim for each speaker.
- The app reads REW and miniDSP mic calibration files.
- The app includes approximate curves for the iPhone 17 Pro and iPhone 18 Pro mics.
- The app exports REW filter files, corrected-response CSV files and a results file.
