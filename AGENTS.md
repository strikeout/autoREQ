# autoREQ — Agent Reference

AutoREQ is a native macOS app (SwiftUI) for room correction. It rebuilds the software half of
Tantrum Audio's Omnissiah (manual: https://tantrumaudio.co.uk/usermanuals/omnissiah): a pink-noise
transfer-function measurement tool with coherence and snapshots, a guided calibration that fits
peaking EQ, crossover, level, delay and polarity, target curves, and a loopback engine that applies
the correction live to system audio. It does NOT control the Tantrum Really Mean Sub hardware. The
USB protocol of that device is not public.

- **Stack:** Swift 6.4 (language mode 5), SwiftPM, SwiftUI, Swift Charts, AVAudioEngine, CoreAudio, Accelerate. macOS 15+.
- **Runs with:** `./scripts/bundle.sh && open build/AutoREQ.app`
- **Tests with:** `swift test` (DSP core). End-to-end audio check: `open -W --stdout out.txt build/AutoREQ.app --args --selftest "VB-Cable"`
- **Deploys to:** GitHub releases at https://github.com/strikeout/autoREQ. Push a tag that equals `version.txt` (for example `v1.0.0`); `.github/workflows/release.yml` builds and attaches `AutoREQ.zip`. The release notes come from the matching `## vX.Y.Z` section of `CHANGELOG.md`.

This file is the project's durable memory. It is read before every task and it is expected to
grow. Keep it factual, keep it current, delete what stopped being true.

---

## Constraints

Standing instructions for working in this repo. **Every rule carries an expiry date, and an
expired rule is not in force.** On the first session after a rule's date, either renew it — push
the date out and append the reason it still holds — or delete it. Never silently keep it, and
never renew a rule you cannot justify in one line: not being able to say why it still applies
*is* the answer. This is the only thing that stops a constraint list growing into hundreds of
lines of dead instruction that an agent quietly ignores.

The line format is fixed so the list stays greppable — `- **until YYYY-MM-DD** — <rule>`. A new
rule gets **90 days** unless there is a reason for a shorter or longer life; a rule tied to a
known event (a migration, a launch, a vendor deadline) expires on that date instead.

```bash
sh ~/.claude/templates/check-constraints.sh
```

- **until 2027-01-31** — No repo-specific constraints have been written yet. Delete this line
  when the first one is added.

Only *instructions* belong here — "always X", "never Y", "ask before Z". Durable **facts** about
how this code works do not expire and live in the other sections, not in this list.

---

## Versioning — `version.txt`

The repo root holds **`version.txt`**: one line, `vmajor.minor.hotfix`, `v` prefix included,
trailing newline. It starts at `v0.0.0`.

```
v0.0.0
```

**`version.txt` is the single source of truth.** If the project also carries a version in a
native manifest (`package.json`, `Cargo.toml`, `pyproject.toml`, `manifest.json`), that field
mirrors `version.txt` — **without** the `v`, since those formats forbid it — and both move in
the **same commit**, never one without the other.

**Bump on every commit that changes code**, in the same commit as the change:

| Segment | Bump when | Examples |
|---|---|---|
| **hotfix** (`v0.1.0` → `v0.1.1`) | Behaviour was wrong and now is right. Nothing new. | Bug fix, typo in user-facing copy, dependency patch, revert |
| **minor** (`v0.1.4` → `v0.2.0`) | Behaviour was added or visibly changed. | New feature, new endpoint, new flag, refactor a user could notice, schema addition |
| **major** (`v0.9.2` → `v1.0.0`) | Incompatible break, or a deliberate release milestone. | Removed/renamed public API, data migration that cannot roll back, rewrite |

Rules that keep it honest:

- **Never bump `major` on your own.** It is the human's call — propose it, don't take it.
- **Docs-only, comment-only, or config-only commits do not bump.** Neither do `AGENTS.md`
  edits. The version tracks *code*, not the repo.
- **One commit, one bump.** Don't stack two bumps into one commit, and don't leave a code
  commit unbumped intending to "catch up later" — the number stops meaning anything.
- **Read it, don't assume it.** `cat version.txt` before bumping; the branch may be behind.
- Once the project has users, add a `CHANGELOG.md` entry for every **minor** and **major** —
  one plain-language line per change, written for the user, not the git log.

```bash
cat version.txt
```

---

## Working rules

- **Read before writing.** This file, then the code the task touches. Don't infer an API from
  its name.
- **Match the surrounding code.** Its naming, its comment density, its idioms — not yours.
- **Run the test command before saying something works.** If there are no tests, say that
  plainly instead of implying verification.
- **Never commit secrets.** Keys, tokens and `.env` files stay out of the repo; document the
  *names* of the required env vars here, never their values.
- **Commit and push only when asked.** If on the default branch, branch first.
- **Commits are written normally** — imperative subject, no caveman, no emoji unless the repo
  already uses them.

## Architecture facts

- `Sources/AutoREQCore` holds all DSP and has no UI or device code. Keep it testable with `swift test`.
- `Sources/AutoREQ/Audio` runs two `AVAudioEngine` instances, one for the output device and one for
  the input device. One engine with two different devices is not reliable on macOS. Each engine
  writes to a `SampleRing` with an absolute sample counter; GCC-PHAT finds the counter offset.
- The measurement engines stay running for a whole calibration. Arrival times of different speakers
  are only comparable while the counter offset stays the same.
- The app must run as a bundle (`scripts/bundle.sh`). macOS grants microphone access only to a
  bundle that has `NSMicrophoneUsageDescription`.
- `Atomic` from `Synchronization` is noncopyable. A render closure cannot capture it directly, so
  the engines keep atomics in a small final class.
- Mic calibration: no maker publishes a generic file for UMIK-1/2, EMM-6, UMM-6, ECM8000 or XREF 20.
  Their files are per serial number, so the user imports them. The only built-in curves are the
  iPhone 17 Pro and 18 Pro, read by eye from Faber Acoustical's published graphs (30 Hz–5 kHz).
  Do not add a built-in curve without a named published source.
- `scripts/notarize.sh` signs with the Developer ID identity in the keychain, notarizes with the
  keychain profile `autoreq-notary` (override with `NOTARY_PROFILE`), staples, and writes
  `build/AutoREQ.zip`. The CI release builds an ad-hoc signed zip only. After the release
  workflow finishes, replace its asset: `gh release upload vX.Y.Z build/AutoREQ.zip --clobber`.
- The bundle ID is `com.thomassteinhauer.autoreq`. A change of the ID makes macOS ask for
  microphone access again.
- The hardened runtime needs `Resources/AutoREQ.entitlements` (`device.audio-input`), or the
  microphone stays silent without an error.
- `scripts/make-icon.swift` draws the app icon in code and writes `Resources/AppIcon.icns`.
  Edit the script and run `swift scripts/make-icon.swift` to change the icon.
- `ImpulseAnalyzer` (in `RoomAnalysis.swift`) is separate from `TransferAnalyzer`. It uses a
  rectangular frame of at least 1.2 s. It divides each lag t by (1 - |t| / N) to remove the
  window error. The Hann window of `TransferAnalyzer` attenuates late lags too much for a decay
  measurement. The engine adds an impulse frame every 5th tick (0.5 s).
- The JSON state keeps `Response.impulse` as raw Float32 data in base64. `applying`, `sum` and
  `powerAverage` set it to nil, because their output is no longer a measurement.
- Generator levels are RMS levels relative to a digital value of 1.0. Each `SignalGenerator`
  signal has an RMS of 1.0 before the gain. Before v1.2.0, the pink noise was 7.5 dB below its
  nominal level, so the old calibration default of −12 dB equals −20 dBFS RMS now.
- The render thread reads the generator through `Mutex.withLockIfAvailable`. It plays silence for
  one buffer if the main thread holds the lock to swap the signal. Build a new `SignalGenerator`
  on the main thread, because periodic noise and file playback allocate a table.
- Periodic pink noise has a period of `ImpulseAnalyzer.fftSize`. The engine sets
  `ImpulseAnalyzer.periodic`, which turns off the (1 - |t| / N) correction. The delay search then
  uses a range shorter than one period, because the noise matches at every period.
- A tone (sine or dual sine) gives no transfer function. The engine skips the transfer function
  and reports the status `.tone`.
- The engine writes the first 8 input channels to `inputRings` for the RTA. `SpectrumAnalyzer`
  uses the IEC 61260-1 base-ten bands and weights each FFT bin by its overlap with the band.
- `WindowedTransferAnalyzer` (FTW) runs one `TransferAnalyzer` for each window. At 48 kHz, the
  windows are 64k below 160 Hz, 16k to 1.25 kHz, 4k to 5 kHz and 1k above. A 1/3-octave crossfade
  joins the parts. A
  short window adds up to 4 frames for each tick, so its average covers the same time.
- The engine keeps one `Mic` for each mic channel, with its own delay offset, analysers and
  `DelayTracker`. The first mic is the main mic. Extra mics read `inputRings`, so they must be
  among the first 8 input channels.
- Delay tracking (the setting `clockDrift`) replaces the old search every 3 s. It reads the
  GCC-PHAT peak of the newest impulse frame. A shift must show in two frames in a row.
- The mic calibration of the main mic has the device UID as its key. An extra mic uses `uid#channel`.
- The sweep measurement plays `SignalKind.logSweep`: one sweep and 2 s of silence, looped. The
  render thread stores the reference index of each table start in `periodStart`.
  `MeasurementEngine.lastPeriod` reads one aligned period for each mic.
- `LogSweep.impulse` deconvolves with a regularised division, so a wire gives a peak of about 0.81
  at 48 kHz. That is the peak of a 20 Hz–20 kHz band-limited impulse, and the in-band gain is 1.
- `SoundLevelMeter` gets the raw samples of `inputRings` on each tick. The SPL calibration offset
  has the key `uid#channel` in `SPLSettings.calibrations`. It is separate from the mic calibration file.
- The Spectrum screen and the SPL screen share the RTA of the engine. `AppModel.engineBanding`
  holds the band width that the engine uses now.
- The phase correction (`CorrectionOptions.phaseCorrection`) runs after the time alignment. It adds
  the all-pass filters of `PhaseAligner.align` to the side whose phase leads. Then the sub fine
  alignment runs again, because an all-pass changes the phase at the crossover.
- `CalibrationSession.measurements` keeps the area index of each position. `ListeningArea.combine`
  gives each area its weight, whatever its number of positions. The main area is first.
- `SpeechTransmission.analyze` filters the impulse response in octaves with a zero-phase FFT filter.
  A simplified Lundeby method truncates the decay. `STIResult.mtf` is the corrected MTF.
- The masking slope, the reception threshold and the male speech spectrum in
  `SpeechTransmission.swift` are from memory of the standard. Check them against IEC 60268-16 ed. 5.
- `RemoteServer` uses `NWListener` with plain HTTP and closes each connection after one reply. It
  binds to 127.0.0.1 unless the user allows the LAN. It does not share a port with another app;
  a bind failure reaches `AppModel.remoteError`. The web viewer polls the API, so there is no WebSocket.
- The preset target-curve shapes are approximations. The Omnissiah manual describes them in words only.

## Keeping this file true

When a fact about *this project* turns durable — a build incantation, a gotcha, a decision and
what it rejected — append it here in the same session it was learned. When a claim here turns
false, delete it; a stale `AGENTS.md` is worse than a short one. Do not paste content that
belongs in the README (what the project is, how a human installs it) or in the wiki (see below).

---

## Wiki Protocol

There is a personal wiki at `~/Sites/AI-projects/Wiki` — an Obsidian vault that an agent
maintains and the human reads. This project is a subject in its **`digital`** domain.

### The trigger — when a learning occurs, file it

Capture when, and only when, one of these is true:

1. A bug's root cause was **non-obvious** and cost real time.
2. An external system behaved **contrary to its documentation** — API quirk, rate limit, silent
   failure, undocumented error.
3. A decision was made **and alternatives were rejected** — record the why and the rejected list.
4. A build/deploy/tooling incantation was found that is **in no README**.
5. Something learned here **applies to another project**. Highest value; nothing else catches it.
6. The human states a **standing rule or preference** that applies to more than one project.

Do **not** capture routine feature work, anything already in this file, restatements of public
docs, or session status updates.

### The recall trigger — before you work, ask what is already known

The capture trigger above fills the wiki. This trigger uses it. Run one search before the work
starts:

```bash
sh ~/.claude/templates/wiki-recall.sh <term> [<term>...]
```

Run it before non-trivial work. A debugging session longer than one line qualifies, and so does
an architecture decision. First contact with an unfamiliar subsystem qualifies, and so does work
against an external API. Skip it for a typo, a one-line edit, or a question about the current
diff.

The procedure is `~/Sites/AI-projects/Wiki/CLAUDE.md`, section "Operations → Recall". Read it
there. It holds the search order, the read cap, and the rule that the code wins over a stale
page. This file deliberately does not restate it.

### The split

Facts durable to *this project only* stay in this file. The **cross-project and
durable-knowledge** slice goes to the wiki. The test: *"would this help me in a different
repo?"* Yes → wiki. No → here.

### The procedure — read it, never remember it

**`~/Sites/AI-projects/Wiki/CLAUDE.md`, section "Capture", is the single source of truth for
where the page goes, what shape it takes and how the log line reads.** Read it before writing
into the wiki, and follow it over anything you remember.

It is deliberately not restated here. This block sat a full schema version behind for months
because eleven repos each carried their own copy of the procedure; the fix was to stop copying
the half that changes. Keep it that way — if you find yourself pasting filing rules into this
file, you are recreating the bug.
