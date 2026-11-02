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
- `scripts/make-icon.swift` draws the app icon in code and writes `Resources/AppIcon.icns`.
  Edit the script and run `swift scripts/make-icon.swift` to change the icon.
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
