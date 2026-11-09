# How Hootnote works

This article describes how Hootnote captures, transcribes, and labels a call. For setup and everyday use,
see the [README](../README.md).

## Pipeline

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
   ChatGPT or Claude ─► summary, action items; "Ask about this meeting"
```

## Call detection

macOS 14 and later reports, per process, whether it's using the microphone
(`kAudioProcessPropertyIsRunningInput`). No permission is needed. A known calling app holding the
microphone for 2 seconds means a call. The call has ended when the app releases the microphone for the
grace period, unless the app is still playing call audio (you're muted). A release of 6 seconds or more in
silence, followed by the microphone coming back, is treated as a new back-to-back call.

Calls also drop and reconnect. On one Teams call, the recording stopped as the call dropped, and the call
came back a minute later as a second meeting. So while the calendar event a recording was named from is
still on (and is still the event you're in), Hootnote waits up to 3 minutes for the microphone to come
back, and the microphone returning continues the same recording. Past the usual grace period the wait
records nothing, and a call that comes back keeps the wait as silence, so times stay true. A call that
really ended stops as before, with nothing extra recorded. A dedicated calling app taking the microphone
still ends the call at once; a browser doing so during the event doesn't.

## Rejoining a split call

If a call was still saved as two meetings, Hootnote usually notices. When the second one has the same app
and title as the meeting before it (the title comes from the calendar event) and started within 3 minutes
of that one's end, its header says "Looks like the rest of the 9:03 AM meeting…" with **Join…** and
**Not now**, and the "Transcript ready" notification says so too. **Join** opens the same confirmation as
the menu command, and nothing is joined until you confirm. **Not now** is remembered for that pair. For any
other pair, open the second meeting and select **Meeting** > **Join with Previous Meeting**.

The audio is joined end to end with the real gap between the recordings as silence, the second transcript
moves to its place in time, and speakers heard in both parts are matched by voice (the same threshold as
voiceprints) or by a name you gave in both. The second meeting moves to the Trash with its auto-exported
file, and the summary is written again. When one part's microphone track predates raw storage (older
versions stored it echo-cancelled), the other part is echo-cancelled at the join so the track has one
format. A joined meeting records where each part starts, and the echo canceller treats each part on its
own, since the speaker-to-microphone delay can differ (24 ms and 36 ms on that call).

## Capture without drivers or feedback

The call audio comes from a Core Audio process tap (macOS 14.4 and later): a passive, read-only copy of
what apps play. It excludes Hootnote itself, uses a private aggregate device that doesn't appear in your
sound settings, and never changes your output device. It needs only the System Audio Recording
permission, not full Screen Recording. Both tracks are stamped with the host clock; real gaps are padded
with silence, and the slow drift between the audio devices' clocks is absorbed a sample at a time
(earlier builds corrected it in 40 ms jumps, which you could hear as a skip).

## Echo removal

Your microphone and the call are recorded separately, so the diarizer only ever sees the other
participants, and your voice can't be confused with theirs, even when you talk over someone. On laptop
speakers the microphone also hears the call. The echo canceller finds the speaker-to-microphone delay (up
to 500 ms, which covers Bluetooth speakers) and removes the echo using the call track as the reference.
With headphones it detects no echo and leaves the microphone untouched.

Loud laptop speakers can leave the microphone hearing the call louder than your own voice, and the
canceller can't remove all of it. Whisper turns what's left into short lines of nonsense under your name.
The clean-up removes them by voice: pyannote separates the voices on your microphone, and the ones that
match a participant on the call (and only turn up while the call is playing) are echo. On the first Teams
call tested, your own voice formed two clusters that matched nobody on the call (similarity under 0.3),
while every echo cluster matched a participant at 0.64 to 0.86. Your interjections stay, even when you
talk over someone.

The clean-up also removes Whisper's repetition loops and dialogue dashes. **Meeting** > **Clean Up
Transcript** applies it to meetings transcribed before it existed, and **Meeting** > **Restore Original
Transcript** undoes it.

## Playback

The player plays one levelled mix. Each track's gain follows its speech level toward the same target, so
a laptop microphone recorded 13 dB below the call (as on that Teams call) plays at the same volume. Your
track is the echo canceller's linear output, which never gates your voice, and it's turned down while only
the call is talking, so leftover echo can't double the call.

## Word timing

Whisper's word times come from attention weights. Measured against Parakeet on a real call, they were off
by a median of 90 ms, and by more than 440 ms for one word in ten. Parakeet TDT predicts a duration for
every token, so after Whisper transcribes, Parakeet transcribes the same speech and each Whisper word
takes its Parakeet twin's time (93% matched; the rest are placed between matched neighbours). The
highlighted word follows the voice, and selecting a word starts playback there.

## Accuracy choices

- Whisper: Large-v3 Turbo by default. **Settings** > **Transcription** offers full Large-v3, or Parakeet
  v2 for speed. Only speech regions go to Whisper; silence is where Whisper tends to invent text.
- Custom vocabulary (**Settings** > **Transcription**) is passed to Whisper as a prompt. WhisperKit 1.1.1
  misplaces word timestamps when a prompt is used; `PromptAlignedSegmentSeeker` corrects this (verified
  against ground-truth timings).
- pyannote runs with its reference Community-1 settings (step 0.1, no minimum segment length) rather than
  FluidAudio's faster default.

## Summaries and Ask

Summaries and Ask use ChatGPT or Claude. No language model runs on the Mac. **Default model** in
**Settings** > **AI** sets the service and model. The model menu beside **Ask**, **Write summary**, and
**Rewrite** picks another model for one conversation or summary. The menus list what each connected
service offers right now (`GET /v1/models`), fetched again when a menu appears and the list is more than
five minutes old. Claude's newest model in each family is at the top; older ones are under **More
Models**. If the chosen model is no longer offered, Hootnote uses the service's default.
`Hootnote --models` prints the lists. By default Hootnote asks "Summarize this meeting?" when a recording ends or an upload is read, and
writes a summary only if you say yes (`Meeting.wantsSummary`), so meetings that don't need one cost
nothing. **After each meeting** can also be set to always or never. Transcripts up to 400,000 characters are summarized in one request; longer ones are summarized in
parts and then combined. `Hootnote --summary-test <part of a meeting title>` summarizes a meeting with the
chosen service.

### ChatGPT

ChatGPT uses the person's own Plus or Pro plan through OpenAI's
[Sign in with ChatGPT](https://developers.openai.com/siwc) flow for open-source apps that run locally.

- **Sign-in:** OAuth with PKCE, opened in the default browser. The callback returns to
  `http://127.0.0.1:1455/auth/callback`, or another free port if 1455 is taken. The first sign-in
  registers this copy of Hootnote and returns its client ID with the code.
- **Storage:** Tokens are kept in the Keychain (service `com.local.Hootnote.chatgpt`). Each refresh
  replaces the refresh token, so refreshes run one at a time and are saved immediately.
- **Requests:** `POST https://api.openai.com/v1/responses` with `store: false` and `stream: true`. The
  model comes from `GET /v1/models` (entries with `visibility: "list"`).
- **Work workspaces:** A ChatGPT Business or Enterprise workspace must allow the app first. A global admin
  sets **Use ChatGPT plan** to **Allowed** for it under **External access** in the OpenAI Admin Console.

### Claude

Claude uses an API key from the Claude Console. Claude Max, Ultra, and Team plans include monthly API
credits for a linked Console organization, which cover these requests.

- **Storage:** The key is kept in the Keychain (service `com.local.Hootnote.claude`). Hootnote checks it
  with `GET /v1/models` before saving it.
- **Requests:** `POST https://api.anthropic.com/v1/messages`, streamed, with `anthropic-version:
  2026-10-21`. The default model is `claude-opus-5-5`. `max_tokens` is 64,000, or the model's own
  limit if that is lower.
- **Declines:** Requests to models with safety classifiers send `fallbacks: "default"` (beta
  `server-side-fallback-2026-07-01`), so a declined request is retried on the model Anthropic
  recommends.
- **Ask:** Requests use prompt caching, so follow-up questions reuse the cached transcript.

## Testing with synthetic calls

`Hootnote --selftest <folder with mic.caf and system.caf>` runs the pipeline and prints the transcript.
The test calls used three text-to-speech voices, with call audio bleeding into the microphone at −15 dB
with 60 ms latency and room reflections:

| Case | Result |
|---|---|
| Speakers, no crosstalk | Delay found exactly (60 ms); 45 dB of echo removed; microphone transcript has only your lines |
| You talk over a remote speaker | Your interjection kept word for word; their sentence intact; still 2 remote speakers |
| Headphones (no bleed) | "No echo detected"; microphone left as recorded |
| Diarization | 2 of 2 remote speakers separated, every sentence attributed correctly |

Synthetic voices are cleaner than real calls, so expect somewhat lower accuracy on real meetings
(crosstalk between remote people, poor connections, similar-sounding voices).

## Interface design

The interface follows the "Railway Timetable" direction chosen with the Impeccable design skill
(`.claude/skills/impeccable`, not in this repository; `skills-lock.json` records the version): white
timetable stock and ink tabular figures, signal red only for what is live (recording, the now-line, the
word being spoken), and route-line colours for apps and speakers. Product record: `PRODUCT.md`. Direction
contract: `.impeccable/surfaces/sources-hootnote-ui.md`. Tokens: `Sources/Hootnote/UI/Theme.swift`.
