# Hootnote

Hootnote is a macOS menu bar app that records your calls and transcribes them on your Mac. It detects
when a call starts, asks whether to record, stops when the call ends, and produces a transcript with
speaker labels, a summary, and action items. No bot joins the meeting, and no audio or text leaves your
Mac.

## Features

- **Call detection** for Zoom, Microsoft Teams, Webex, Slack, FaceTime, and calls in a browser.
- **Speaker labels.** Name a speaker once, and Hootnote recognizes their voice in later meetings.
- **In-person meetings and uploads.** Record a room, or transcribe any audio or video file.
- **Summaries and questions** answered by a local model through Ollama.
- **Dictation.** Hold **fn** in any app, speak, and the text is pasted at your cursor.
- **Export** to Word, PDF, Markdown, plain text, or subtitles.

## Prerequisites

- macOS 14.4 or later.
- Xcode Command Line Tools with Swift 6.1 or later. Full Xcode isn't required.
- About 2.2 GB of free disk space for the speech models, which download the first time you open the app.
- Optional: [Ollama](https://ollama.com), for summaries and questions.

## Build and install

1. Clone the repository:

   ```bash
   git clone https://github.com/fs2400/hootnote.git
   cd hootnote
   ```

2. Build the app and install it in `/Applications`:

   ```bash
   scripts/build_app.sh
   ```

   To build without installing, add `--no-install`. The app is written to `build/Hootnote.app`.

3. Optional: download the model for summaries and questions:

   ```bash
   ollama pull qwen3.5:9b
   ```

> [!NOTE]
> macOS ties Microphone and System Audio Recording permissions to the app's code signature. Set
> `SIGN_IDENTITY` to the name of a code-signing certificate in your keychain to keep permissions across
> rebuilds. Without one, the script signs the app ad hoc and macOS asks for permissions again after each
> rebuild.

## Get started

1. Open Hootnote. The welcome screen asks for your name and for Microphone and System Audio Recording
   permissions, then downloads the speech models.
2. Join a call. When Hootnote detects it, a prompt appears in the upper-right corner. Select **Record**
   or **Not now**. To record every call from that app without asking, select **Always record *app*
   calls**.
3. While Hootnote records, an indicator shows the elapsed time and audio levels. Recording stops 15
   seconds after the call app releases the microphone. To continue recording, select **Keep**.
4. After the call, Hootnote transcribes in the background. You can record your next call while it works.
5. Open the meeting and select a speaker's name to rename them. Hootnote remembers their voice for later
   meetings.

## Common tasks

| Task | Steps |
|---|---|
| Record an in-person meeting | Select **Record in person** on Home, in the toolbar, or in the menu bar. |
| Transcribe a file | Select **Upload audio** on Home, or drop the file on Home. |
| Dictate into another app | Hold **fn**, speak, and release. For hands-free dictation, tap **fn** once to start and again to finish. |
| Play from a word | Select the word in the transcript. |
| Fix one paragraph's speaker | Right-click the paragraph and select **Change Speaker for This Paragraph**. |
| Rejoin a call that was split in two | Open the second meeting and select **Meeting** > **Join with Previous Meeting**. |
| Delete a meeting | Right-click the meeting and select **Delete Meeting**. It moves to the Trash. |

> [!IMPORTANT]
> Dictation needs Accessibility permission. In **System Settings** > **Keyboard**, set **Press 🌐 key
> to** to **Do Nothing**. To use Right Option instead of fn, go to **Settings** > **Dictation** in
> Hootnote.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⇧⌘R | Record in person |
| ⌥⌘P | Play or pause |
| ⌘← / ⌘→ | Skip back or forward 15 seconds |
| ↑ / ↓ | Go to the previous or next paragraph |
| ⌘Z / ⇧⌘Z | Undo or redo a transcript edit |

## Where your data is stored

| Data | Location |
|---|---|
| Recordings and transcripts | `~/Library/Application Support/Hootnote/Meetings/` |
| Dictation history (text only) | `~/Library/Application Support/Hootnote/dictations.json` |
| A Markdown copy of each transcript | `~/Documents/Meeting Transcripts/`, which you can change in **Settings** |

## How it works

Hootnote records your microphone and the call audio as two separate tracks. It captures call audio
through a Core Audio process tap, so it needs no audio driver and doesn't change your sound settings.
After the call, Hootnote:

1. Removes speaker echo from your microphone track.
2. Transcribes both tracks with OpenAI Whisper Large-v3 Turbo, then times each word with NVIDIA Parakeet.
3. Separates the call participants by voice with pyannote Community-1.
4. Writes a summary and action items with the Ollama model.

For call detection, echo handling, and test results, see [How Hootnote works](docs/how-it-works.md).

## Known limitations

- The meeting service mixes remote participants into one stream, so Hootnote has to tell them apart by
  voice. Overlapping speech or similar voices can be mislabeled.
- Hootnote detects a call by checking which app is using the microphone. If your call app releases the
  microphone when you mute, recording stops after 15 seconds. To wait longer, go to **Settings** >
  **Recording**.
- Hootnote doesn't load a summary model larger than about 45% of your Mac's memory, and it loads only one
  model at a time.
- Recording laws vary. In some places, everyone on a call must consent to being recorded.

## Third-party components

| Purpose | Project | License |
|---|---|---|
| Speech recognition | [WhisperKit](https://github.com/argmaxinc/WhisperKit) 1.1.1 (OpenAI Whisper Large-v3 and Large-v3 Turbo) | MIT |
| Speaker separation, voice detection, word timing | [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.7 (pyannote Community-1, Silero VAD, NVIDIA Parakeet TDT 0.6B v2) | Apache 2.0; Parakeet weights CC-BY-4.0 |
| Echo cancellation | [SpeexDSP](https://github.com/xiph/speexdsp) 1.2.1, included in `Sources/CSpeexDSP` | BSD-3 |
| Summaries and questions | [Ollama](https://ollama.com) with qwen3.5:9b | MIT; Apache 2.0 |

## License

Hootnote is released under the [MIT License](LICENSE). The SpeexDSP code in `Sources/CSpeexDSP` keeps its
own [BSD-3 license](Sources/CSpeexDSP/COPYING).
