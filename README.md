# Hootnote

Hootnote is a macOS menu bar app that records your calls, transcribes them on your Mac, and writes a
summary of each meeting with ChatGPT or Claude. No bot joins the meeting.

## Features

- **Call detection** for Zoom, Microsoft Teams, Webex, Slack, FaceTime, and calls in a browser.
- **Speaker labels.** Name a speaker once, and Hootnote recognizes their voice in later meetings.
- **In-person meetings and uploads.** Record a room, or transcribe any audio or video file.
- **Summaries and questions.** Get notes and action items for each meeting, and ask questions about it.
- **Dictation.** Hold **fn** in any app, speak, and the text is pasted at your cursor.
- **Export** to Word, PDF, Markdown, plain text, or subtitles.

## Before you begin

You need:

- macOS 14.4 or later.
- Xcode Command Line Tools with Swift 6.1 or later.
- About 2.2 GB of free disk space for the speech models.
- For summaries and questions, a ChatGPT Plus or Pro account, or a Claude API key.

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

   To build without installing, add `--no-install`. The app is saved to `build/Hootnote.app`.

**Note:** To keep macOS permissions after you rebuild, set `SIGN_IDENTITY` to the name of a
code-signing certificate in your keychain.

## Get started

1. Open Hootnote and follow the welcome screen.
2. In the **Connect ChatGPT or Claude** window, click **Continue with ChatGPT**, or paste a Claude API
   key and click **Connect**.
3. Join a call. When Hootnote asks, click **Record**.
4. When the call ends, click **Summarize** if you want a summary. Hootnote transcribes the call either way.
5. Open the meeting to see the **Transcript**, **Summary**, and **Ask** tabs.

## Common tasks

| Task | Steps |
|---|---|
| Record an in-person meeting | Click **Record in person** on Home or in the menu bar. |
| Transcribe a file | Click **Upload audio** on Home, or drop the file on Home. |
| Rename a speaker | Click the speaker's name in the transcript. |
| Ask about a meeting | Open the meeting and click the **Ask** tab. |
| Summarize a meeting later | On the **Summary** tab, click **Write summary**. |
| Rewrite a summary | On the **Summary** tab, click **Rewrite**. |
| Choose when summaries are written | Open **Settings** > **AI** and set **After each meeting**. |
| Include or leave out the summary in exports | Open **Settings** > **General** and set **Include the summary**. |
| Check your ChatGPT or Claude usage | On the **Summary** tab or in **Settings** > **AI**, click **Check usage**. |
| Dictate into another app | Hold **fn**, speak, and release. |
| Delete a meeting | Right-click the meeting and click **Delete Meeting**. |

**Note:** Dictation needs Accessibility permission. In **System Settings** > **Keyboard**, set **Press
🌐 key to** to **Do Nothing**.

## Use Claude

1. On claude.ai, open **Settings** > **Billing**. On a Team plan, open **Organization settings** >
   **Billing**.
2. Under **API credits**, click **Link organization** and follow the steps.
3. In the [Claude Console](https://platform.claude.com/settings/keys), create an API key.
4. In Hootnote, open **Settings** > **AI**, paste the key under **Claude**, and click **Connect**.

**Note:** Claude Max, Ultra, and Team plans include monthly API credits that cover Hootnote. Hootnote
uses Claude Opus 5.5 unless you choose another model.

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
| Dictation history | `~/Library/Application Support/Hootnote/dictations.json` |
| Markdown copies of transcripts | `~/Documents/Meeting Transcripts/` |

Recording and transcription happen on your Mac. To write summaries and answer questions, Hootnote sends
the meeting's transcript to ChatGPT or Claude.

## How it works

1. Hootnote records your microphone and the call audio as separate tracks.
2. It removes speaker echo from your microphone track.
3. It transcribes both tracks with OpenAI Whisper, and labels speakers with pyannote.
4. It sends the transcript to ChatGPT or Claude for a summary.

For details, see [How Hootnote works](docs/how-it-works.md).

## Troubleshooting

**ChatGPT says "This app needs your organization's permission."**

Your ChatGPT account belongs to a work workspace that hasn't allowed Hootnote. Do one of the following:

- Ask your ChatGPT workspace admin to open **External access** in the Global Admin Console, allow
  Hootnote, and set **Use ChatGPT plan** to **Allowed**.
- Sign in with a personal ChatGPT Plus or Pro account instead.

Then, in Hootnote, click **Cancel** and **Continue with ChatGPT** again.

## Known limitations

- Overlapping speech or similar voices can get the wrong speaker label. To fix one, right-click the
  paragraph and click **Change Speaker for This Paragraph**.
- If your call app releases the microphone when you mute, recording stops after 15 seconds. To wait
  longer, open **Settings** > **Recording**.
- Recording laws vary. In some places, everyone on a call must agree to be recorded.

## Third-party components

| Purpose | Project | License |
|---|---|---|
| Speech recognition | [WhisperKit](https://github.com/argmaxinc/WhisperKit) 1.1.1 (OpenAI Whisper Large-v3 Turbo) | MIT |
| Speaker labels, voice detection, word timing | [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.7 (pyannote Community-1, Silero VAD, NVIDIA Parakeet TDT 0.6B v2) | Apache 2.0; Parakeet weights CC-BY-4.0 |
| Echo cancellation | [SpeexDSP](https://github.com/xiph/speexdsp) 1.2.1, in `Sources/CSpeexDSP` | BSD-3 |

## License

Hootnote is released under the [MIT License](LICENSE). The SpeexDSP code in `Sources/CSpeexDSP` keeps its
own [BSD-3 license](Sources/CSpeexDSP/COPYING).
