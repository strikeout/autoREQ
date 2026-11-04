# AutoREQ roadmap

This plan compares AutoREQ v1.1.0 with the Smaart v9 edition chart from Rational Acoustics. It
also includes the gaps from the Omnissiah manual. Each phase is one minor version. Each phase
ships alone and keeps the tests green.

## What AutoREQ has now

- The app measures a transfer function with magnitude, phase and coherence. It uses pink noise
  from the internal generator as the reference.
- The app calculates a live impulse response, the energy-time curve, the reflections and the room
  modes.
- The app keeps snapshots, combines them, and imports and exports CSV files.
- The app has averaging modes, smoothing, coherence blanking and mic calibration files.
- The guided calibration calculates the crossover, the level, the delay, the polarity and the EQ.
- The loopback engine applies the correction to the system audio.

## Smaart features against AutoREQ

| Smaart feature | AutoREQ now | Plan |
|---|---|---|
| Several inputs from several devices at the same time | One mic channel | Phase 2 |
| A network API for other products | None | Phase 7 |
| Windows, ASIO and WDM drivers | macOS only | Out of scope |
| RTA and spectrograph with fractional-octave bands | None | Phase 1 |
| Many live spectrum measurements with averages | None | Phase 1 |
| Transfer function and live impulse response | Yes | Done |
| Many live transfer functions at the same time | One | Phase 2 |
| Frequency-dependent time windows (FTW) | One FFT size | Phase 2 |
| A plot time reference for the phase (PTR) | None | Phase 2 |
| A transfer function against a generator signal (SyncSource) | Yes, in effect | Done |
| A live IFFT impulse response (L-IFFT) | Yes | Done |
| A timer that captures data automatically | Auto Capture only | Phase 2 |
| A remote client window | None | Phase 7 |
| A high-resolution impulse response mode | 0.7 s live IR | Phase 3 |
| RT60 in octave bands, 1/3-octave bands or a custom band | One T60 for each mode | Phase 3 |
| Clarity, D/R, STI and STIPA | None | Phases 3 and 6 |
| Many impulse responses at the same time | One | Phase 3 |
| An SPL monitor with weightings, Leq, peaks, bands and dose | None | Phase 4 |
| An SPL log of many inputs | None | Phase 4 |
| A grid of SPL meters | None | Phase 4 |
| An SPL web viewer on the LAN | None | Phase 7 |
| Integration with a 10 EaZy box for Class 1 or Class 2 SPL | None | Out of scope |
| A multichannel generator | Pink noise on selected channels | Phase 1 |
| Random and pseudorandom noise, WAV and AIFF playback, sine tones | Pink noise only | Phase 1 |
| Generator presets | None | Phase 1 |
| A pink sweep (swept sine) | None | Phase 3 |

## Phase 1 — v1.2.0: The generator and the spectrum screen

Status: done in v1.2.0.

### The generator

1. Add these signals: pink noise, white noise, periodic pink noise, a sine tone and a dual sine.
2. Add the playback of a WAV or AIFF file. The file is the reference, so music becomes a
   measurement signal.
3. Add a level control and a channel mask for each signal.
4. Add presets. A preset keeps the signal, the level and the channels.

The periodic pink noise has a period of one impulse frame. A rectangular frame of one period has
no window error. The impulse analyzer then needs no `1/(1-|t|/N)` correction.

### The spectrum screen

1. Add an RTA with bands of 1/1, 1/3, 1/6, 1/12, 1/24 and 1/48 octave.
2. Add a peak hold and the averaging modes that the Measure screen already uses.
3. Show more than one input at the same time.
4. Add a spectrograph. It shows the 1/24-octave spectrum of the last 10 s to 5 min as a color
   map, with a dB range control.

### Tests

- On the loopback device, pink noise reads flat within 0.5 dB in each 1/3-octave band.
- A 1 kHz sine at -20 dBFS reads -20 dBFS in the 1 kHz band.
- The periodic pink noise gives the exact impulse response after one frame.

Effort: medium. Risk: low.

## Phase 2 — v1.3.0: Better transfer functions

Status: done in v1.3.0. The app shows a warning for an aggregate device. It does not make an
aggregate device itself.

1. **Several mics at the same time.** Change `MeasurementEngine` from one mic channel to a list of
   channels. Each channel gets its own transfer function. The Complete Measurement mode can then
   measure several positions at the same time.
2. **Frequency-dependent time windows.** Calculate the transfer function with several FFT sizes,
   for example 64k below 150 Hz and 1k above 5 kHz. Join the parts on the 1/48-octave grid. The
   result has a high resolution in the bass and a stable treble.
3. **Delay tracking.** Read the peak of the live impulse response. Move the delay of the
   reference when the peak moves. This also removes clock drift from a measurement.
4. **Plot time reference.** Let the user set a time reference for the phase, or take it from the
   impulse peak.
5. **Reference snapshot.** Let the user divide the live trace or a snapshot by a reference
   snapshot.
6. **Capture timer.** Take a snapshot at a set interval or a set number of times. Average the
   captures if the user selects it.

A mic on a second audio device has its own clock. The app must show a warning for this case. The
app can also make an aggregate device, but one interface is the better setup.

### Tests

- Two loopback channels give two flat transfer functions at the same time.
- The joined transfer function of a synthetic 40 Hz resonance shows the correct Q.
- When the delay of a synthetic signal changes by 1 ms, the delay tracker follows it in 2 s.

Effort: large. Risk: medium. Phase 2 also makes the calibration better.

## Phase 3 — v1.4.0: The impulse response mode

Status: done in v1.4.0. The sweep impulse response stays in the state file. It is 2 s long, so it
is about 0.5 MB in each snapshot.

1. **Log sweep.** Add a logarithmic sine sweep from 20 Hz to 20 kHz with a length of 1 s to 10 s.
   Calculate the impulse response with the inverse filter of the sweep. The impulse response then
   has the length of the sweep.
2. **Distortion.** Use the harmonic impulse responses of the sweep to show THD, H2 and H3 against
   the frequency.
3. **Decay in bands.** Calculate T20, T30 and EDT in octave bands, 1/3-octave bands and a custom
   band from 63 Hz to 8 kHz. Use the Lundeby method to find the end of the decay in the noise.
4. **Energy ratios.** Calculate C50, C80, D50, the centre time Ts and the direct-to-reverberant
   ratio.
5. **Overlays.** Show more than one impulse response in the Room Analysis screen.
6. **WAV files.** Export and import an impulse response as a 32-bit float WAV file. REW can then
   read the impulse responses from AutoREQ.

A 10 s impulse response is about 2.6 MB in the JSON state file. Store a long impulse response as a
separate file next to the state file.

Phase 3 removes the limit of the live impulse response. The decay of a long mode becomes
measurable.

### Tests

- On the loopback device, the sweep gives one peak at lag 0 and a THD below -90 dB.
- A synthetic exponential decay with T60 = 1.2 s gives T20 and T30 within 5 % in each band.
- A synthetic impulse response with a known energy split gives the correct C50, C80 and D50.
- A clipped synthetic sweep gives the correct H3 level.

Effort: large. Risk: medium.

## Phase 4 — v1.5.0: SPL meter and SPL log

Status: done in v1.5.0. The band levels come from the RTA with slow averaging. The impulse detector
is simpler than the detector of IEC 60651.

1. **Level calibration.** Read a 94 dB or 114 dB calibrator at 1 kHz. Keep the dBFS offset for
   each mic and input. The mic calibration file keeps the frequency correction.
2. **Weightings.** Add the A, C and Z frequency weightings from IEC 61672-1 as biquad filters.
3. **Time weightings.** Add Fast (125 ms), Slow (1 s) and Impulse.
4. **Metrics.** Add LAeq and LCeq for windows that the user sets. Add LCpeak, LZpeak and the SPL
   in octave and 1/3-octave bands.
5. **Dose.** Add the OSHA dose with 90 dBA and a 5 dB exchange rate. Add the NIOSH dose with
   85 dBA and a 3 dB exchange rate. Show a projected 8-hour value for each dose.
6. **Meter grid.** Let the user put many meters in a grid. Each meter shows one input and one
   metric.
7. **SPL log.** Write the metrics of each input to a CSV file each second. Keep the log open when
   the window closes, and stop App Nap during the log.

The SPL meter is not a certified sound level meter. The README and the screen must say this. An
iPhone mic gives no correct absolute level.

### Tests

- The A and C filters match the IEC 61672-1 table within the Class 1 limits up to 10 kHz at
  48 kHz.
- A 1 kHz sine at the calibration level reads 94.0 dB with each weighting.
- A tone burst gives the correct Fast, Slow and Leq values.
- The dose of a constant 90 dBA for 8 h reads 100 % OSHA.

Effort: medium. Risk: low.

## Phase 5 — v1.6.0: Calibration items from the Omnissiah manual

Status: done in v1.6.0. The thresholds of the diagnostic cards come from synthetic data only.

1. Add the phase correction pass to the optimizer.
2. Add the space plan of the Complete Measurement mode. It has an area size and extra listening
   areas with a weight from 0.25 to 1.0.
3. Add the diagnostic cards. The boundary null card shows the wall distance. Other cards show a
   room mode peak or null, a reflection, an uncorrected peak and the high-frequency limit. The
   weak measurement card shows the SNR.
4. Use `RoomAnalysis` for the mode cards and the reflection cards. Show the cards live and in the
   results.
5. Add the latency drift check, a buffer size setting and a Test Speakers button.

Phase 5 comes after Phase 2. The frequency-dependent windows and the extra mics make the
calibration better first.

Effort: large. Risk: medium.

## Phase 6 — v1.7.0: STI and STIPA

Status: done in v1.7.0. The analytic tests pass. The check against the IEC test signals is not
done, because the app has no copy of them.

1. Calculate the modulation transfer function from the impulse response. Use the indirect method
   of IEC 60268-16 for 7 octave bands and 14 modulation frequencies.
2. Add the background noise from the SPL meter, the level-dependent masking and the auditory
   threshold.
3. Show the STI, the STIPA value, the rating class and the transmission index of each band.

This phase needs Phase 3 for the impulse response and Phase 4 for the absolute levels.

### Tests

- A synthetic exponential decay gives the analytic MTF `m(F) = 1/sqrt(1 + (2πF·T/13.8)²)`.
- An ideal impulse with no noise gives an STI of 1.00.
- The results match the check values of IEC 60268-16 within 0.01.

Effort: large. Risk: high. The standard has many details, and each detail changes the result.

## Phase 7 — v1.8.0: Remote access and API

Status: done in v1.8.0. The web viewer polls the JSON API, so the server needs no WebSocket.

1. Add a local HTTP and WebSocket server with `NWListener`. The server is off by default.
2. Add a read-only web viewer for the live traces and the SPL meters.
3. Add a JSON API. It starts and stops the generator, takes a snapshot, and reads a response, an
   impulse response or the SPL values.
4. Protect each request with a random token. Show the URL and the token in the app.

**Warning:** The server exposes measurement data and generator control to the LAN. Keep it off by
default, and bind it to the local machine until the user selects the LAN.

Effort: medium. Risk: medium.

## Out of scope

- Windows, ASIO and WDM drivers. AutoREQ is a macOS app.
- The 10 EaZy hardware and a Class 1 or Class 2 compliance claim. AutoREQ cannot certify a
  measurement chain.
- Licenses and editions. AutoREQ is GPL-3.0 and has one edition.
- AutoREQ does not include the Smaart Data Modeler.
- The hardware features of the Really Mean Sub.

## Order and dependencies

1. Phase 1 has no dependency. It adds the generator that Phase 3 needs.
2. Phase 2 has no dependency. Phase 5 needs it.
3. Phase 3 needs the generator from Phase 1.
4. Phase 4 has no dependency. Phase 6 needs it.
5. Phase 6 needs Phases 3 and 4.
6. Phase 7 is best after Phase 4, because the web viewer shows the SPL meters.

Phases 1, 2 and 4 can run at the same time in separate branches. They change different files,
except `MeasurementEngine.swift`.
