# Hootnote

A personal, fully local meeting transcriber for macOS. It notices when you join a call, asks to
record, stops when the call ends, and produces a speaker-labeled transcript, summary and action items.
Nothing joins the meeting and nothing leaves the Mac.

Installed at `/Applications/Hootnote.app` (formerly MeetingScribe; data and settings migrate
automatically). Recordings and transcripts live in `~/Library/Application Support/Hootnote/Meetings/`;
dictation history (text only) in `~/Library/Application Support/Hootnote/dictations.json`; a Markdown copy
of each transcript goes to `~/Documents/Meeting Transcripts/` (configurable).

## Using it

1. Open Hootnote and work through the welcome screen: your name, Microphone and System Audio
   permissions, open at login, and the one-time model download (~2.2 GB).
2. Join a call in Zoom, Teams, Webex, Slack, FaceTime, or a browser (Meet/Teams/Zoom web). A prompt
   appears top-right: **Record** / **Not now** / "Always record this app".
3. A small indicator shows the timer and levels for you and the call. When the call app releases the
   microphone, recording stops after a grace period (15 s by default; **Keep** overrides it).
4. Transcription runs in the background, one meeting at a time. You can join and record the next
   call immediately, and it queues behind the first.
5. Name a speaker once ("Speaker 2" → "Dana") and their voice is remembered for future meetings.

In-person meetings: **Record in person** on Home, the toolbar, the menu bar, or ⇧⌘R. Everyone on
your mic is separated by voice.

Uploads: **Upload audio** on Home or the toolbar, or drop files onto Home. Any audio or video file;
everyone in it is separated by voice.

Dictation: hold **fn** in any app and speak; let go and the text is pasted where your cursor was.
Tap fn once for hands-free, tap again to finish. A pill above the Dock shows your live audio. The text
is kept under **Dictations**; the audio is never saved. Needs Accessibility permission, and in System
Settings › Keyboard set "Press 🌐 key to" to Do Nothing. Right Option can be used instead (Settings ›
Dictation).

In a meeting: click any word to play from it (↑ and ↓ jump a paragraph); click any speaker's name to
retype it. ⌘Z undoes renames, text edits, speaker changes and deleted paragraphs (⇧⌘Z redoes).
⌘← and ⌘→ skip 15 seconds, except while you're typing in a text box, where they move the cursor. During playback
a red now-line follows the audio and the word being spoken lights up. Export as Word, PDF, Markdown,
text or subtitles. Right-click a meeting (sidebar, Home, Meetings) to delete it after a confirmation;
it goes to the Trash.

Transcripts are cleaned up before you see them (echo fragments under your name, Whisper's repetition
loops, dialogue dashes). Meeting › Clean Up Transcript does the same for meetings transcribed before
this existed, and Meeting › Restore Original Transcript undoes it.

## How it works

```
 Call app (Zoom/Teams/…)                         Hootnote     
 ─────────────────────                           ─────────────
 plays the others ──► Core Audio process tap ──► system.caf  (call track, 16 kHz)
 your mic ──────────► AVAudioEngine input ─────► mic.caf     (your track, 16 kHz)
                      both stamped with host time and kept within 40 ms of each other

 After the call (background queue):
   mic + system ─► echo canceller (SpeexDSP MDF, call track as reference) ─► clean mic
   each track  ─► Silero VAD ─► OpenAI Whisper Large-v3 Turbo (WhisperKit, Neural Engine) ─► words
               ─► Parakeet TDT v2 on the same speech ─► every word moved onto its exact time
   call track  ─► pyannote Community-1 (FluidAudio Core ML) ─► who spoke when + voice embeddings
   clean mic   ─► pyannote again, when there was echo ─► which voices on your mic are the call's
   merge ─► "You" + Speaker 1…n ─► clean-up ─► voiceprint / calendar naming ─► transcript.json
   playback.m4a (both tracks levelled and mixed) + recording.m4a (stereo: ch 1 = you, ch 2 = call)
     + mic.m4a and system.m4a as recorded
   Ollama (local LLM) ─► summary, action items; "Ask about this meeting"
```

**Call detection.** macOS 14+ reports, per process, whether it is using the microphone
(`kAudioProcessPropertyIsRunningInput`). No permission is needed. A known calling app holding the mic
for 2 s means a call. The call has ended when the app releases the mic for the grace period, unless the
app is still playing call audio (you're muted). A release of 6 s or more in silence, followed by the
mic coming back, is treated as a new back-to-back call.

Calls also drop and reconnect. On one Teams call the recording stopped as the call dropped, and the call
came back a minute later as a second meeting. So while the calendar event a recording was named from is
still on (and is still the event you're in), Hootnote waits up to 3 minutes for the mic to come back, and
the mic returning continues the same recording. Past the usual grace period the wait records nothing, and
a call that comes back keeps the wait as silence, so times stay true. A call that really ended stops as
before, with nothing extra recorded. A dedicated calling app taking the mic still ends the call at once;
a browser doing so during the event doesn't.

**Joining a split call.** If a call was still saved as two meetings, Hootnote usually notices. When the
second one has the same app and title as the meeting before it (the title comes from the calendar event)
and started within 3 minutes of that one's end, its header says "Looks like the rest of the 9:03 AM
meeting…" with **Join…** and **Not now**, and the "Transcript ready" notification says so too. Join opens
the same confirmation as the menu command, and nothing is joined until you confirm. Not now is remembered
for that pair. For any other pair, open the second meeting and choose Meeting › Join with Previous
Meeting…. The audio is joined end to end with the real gap between the
recordings as silence, the second transcript moves to its place in time, and speakers heard in both parts
are matched by voice (the same threshold as voiceprints) or by a name you gave in both. The second meeting
moves to the Trash with its auto-exported file, and the summary is written again. When one part's mic track
predates raw storage (older versions stored it echo-cancelled), the other part is echo-cancelled at the join
so the track has one format. A joined meeting records where each part starts, and the echo canceller
treats each part on its own, since the speaker-to-mic delay can differ (24 ms and 36 ms on that call).

**Capture without drivers or feedback.** The call audio comes from a Core Audio process tap
(macOS 14.4+): a passive, read-only copy of what apps play. It excludes Hootnote itself, uses a
private aggregate device that doesn't appear in your sound settings, and never changes your output
device. It needs only the "System Audio Recording" permission, not full Screen Recording. Both tracks
are stamped with the host clock; real gaps are padded with silence, and the slow drift between the
audio devices' clocks is absorbed a sample at a time (earlier builds corrected it in 40 ms jumps, which
you could hear as a skip).

**No echo in your track.** Your mic and the call are recorded separately, so the diarizer only ever
sees the other participants, and your voice can't be confused with theirs, even when you talk over
someone. On laptop speakers the mic also hears the call. The echo canceller finds the speaker-to-mic
delay (up to 500 ms, which covers Bluetooth speakers) and removes the echo using the call track as the
reference. With headphones it detects no echo and leaves the mic untouched.

Loud laptop speakers can leave the mic hearing the call louder than your own voice, and the canceller
can't remove all of it. Whisper turns what's left into short lines of nonsense under your name. The
clean-up removes them by voice: pyannote separates the voices on your mic, and the ones that match a
participant on the call (and only turn up while the call is playing) are echo. On the first Teams call
tested, your own voice formed two clusters that matched nobody on the call (similarity under 0.3),
while every echo cluster matched a participant at 0.64 to 0.86. Your interjections stay, even when you
talk over someone.

**Playback.** The player plays one levelled mix. Each track's gain follows its speech level toward
the same target, so a laptop mic recorded 13 dB below the call (as on that Teams call) plays at the
same volume. Your track is the echo canceller's linear output, which never gates your voice, and it
is turned down while only the call is talking, so leftover echo can't double the call.

**Word timing.** Whisper's word times come from attention weights. Measured against Parakeet on a real
call they were off by a median of 90 ms, and by more than 440 ms for one word in ten. Parakeet TDT
predicts a duration for every token, so after Whisper transcribes, Parakeet transcribes the same
speech and each Whisper word takes its Parakeet twin's time (93% matched; the rest are placed between
matched neighbours). The highlighted word follows the voice, and clicking a word starts there.

**Accuracy choices.**
- Whisper: Large-v3 Turbo by default (Settings → Transcription offers full Large-v3, or Parakeet v2
  for speed). Only speech regions go to Whisper; silence is where Whisper tends to invent text.
- Custom vocabulary (Settings → Transcription) is passed to Whisper as a prompt. WhisperKit 1.1.1
  misplaces word timestamps when a prompt is used; `PromptAlignedSegmentSeeker` corrects this
  (verified against ground-truth timings).
- pyannote runs with its reference Community-1 settings (step 0.1, no minimum segment length) rather
  than FluidAudio's faster default.

## Verified with synthetic calls

`Hootnote --selftest <folder with mic.caf and system.caf>` runs the pipeline and prints the
transcript. The test calls used three TTS voices, with call audio bleeding into the mic at −15 dB with
60 ms latency and room reflections:

| Case | Result |
|---|---|
| Speakers, no crosstalk | Delay found exactly (60 ms); 45 dB of echo removed; mic transcript has only your lines |
| You talk over a remote speaker | Your interjection kept word for word; their sentence intact; still 2 remote speakers |
| Headphones (no bleed) | "No echo detected"; mic left as recorded |
| Diarization | 2 of 2 remote speakers separated, every sentence attributed correctly |

Synthetic voices are cleaner than real calls, so expect somewhat lower accuracy on real meetings
(crosstalk between remote people, poor connections, similar-sounding voices).

## Rebuilding

```bash
scripts/build_app.sh
```

This builds a release, signs with the "Whisper Transcription Local Signing" certificate (so macOS keeps
the permissions across rebuilds), and installs to /Applications. Requires the Xcode Command Line Tools
(Swift 6.1+); full Xcode is not needed.

## Limits

- Remote participants arrive already mixed by the meeting service, so pyannote has to separate them
  by voice. Overlapping remote speakers or similar voices can be mislabeled; fix a paragraph with
  right-click → Change speaker.
- Detection relies on the call app holding the microphone. An app that releases the mic when you mute
  would end the recording after the grace period; raise it in Settings → Recording if that happens.
- Summaries and Ask use `qwen3.5:9b` (reasoning mode) through Ollama. This Mac has 18 GB of memory:
  the strongest open reasoning models need far more, and `gpt-oss:20b` (14 GB) froze the Mac in testing.
  Hootnote refuses any model larger than ~45% of memory and never keeps two loaded at once.
- Recording laws vary. In some places everyone on a call must consent to being recorded.

## Components

| Part | Project | License |
|---|---|---|
| Speech recognition | [WhisperKit](https://github.com/argmaxinc/WhisperKit) 1.1.1, OpenAI Whisper Large-v3 / Turbo | MIT |
| Diarization, VAD, word timing | [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.7 (pyannote Community-1, Silero, NVIDIA Parakeet TDT 0.6B v2) | Apache 2.0 (Parakeet weights: CC-BY-4.0) |
| Echo cancellation | [SpeexDSP](https://github.com/xiph/speexdsp) 1.2.1, vendored in `Sources/CSpeexDSP` | BSD-3 |
| Summaries and Ask | [Ollama](https://ollama.com) with qwen3.5:9b | MIT / Apache 2.0 |

## Design

The interface follows the "Railway Timetable" direction chosen with the Impeccable design skill
(`.claude/skills/impeccable`, not in this repo; `skills-lock.json` records the version): white timetable
stock and ink tabular figures, signal red only for what is live (recording, the now-line, the word being
spoken), route-line colours for apps and speakers. Product record: `PRODUCT.md`. Direction contract:
`.impeccable/surfaces/sources-hootnote-ui.md`. Tokens: `Sources/Hootnote/UI/Theme.swift`.

## License

MIT, see `LICENSE`. The vendored SpeexDSP code in `Sources/CSpeexDSP` keeps its own BSD-3 license
(`Sources/CSpeexDSP/COPYING`).
