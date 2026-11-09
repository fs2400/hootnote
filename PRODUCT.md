# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app (SwiftUI + AppKit, macOS 14.4+, Apple silicon). Impeccable ships no macOS reference, so its Apple-native rules from the iOS reference apply as adapted to the macOS Human Interface Guidelines: sidebar + toolbar + menu-bar navigation, pointer and keyboard first, system controls, SF Symbols, semantic colors, Dark Mode as a first-class appearance, Reduce Motion honored.

## Users

One person: a consultant at a New York transformation consultancy who spends much of the day on back-to-back client and internal calls (Zoom, Microsoft Teams, Google Meet in the browser, Slack) and some in-person meetings. Personal use only; not sold or shared. The job: capture every call without thinking about it, then quickly find what was said, who said it, and what they committed to.

## Product Purpose

Hootnote is a private, on-device meeting transcriber for macOS. It notices when a call starts, asks to record, stops when the call ends, and produces a speaker-labeled transcript, summary and action items. It also records in-person meetings, transcribes uploaded audio, and offers push-to-talk dictation (hold fn, speak, text is pasted where the cursor was). Success: the user never misses a call, trusts who-said-what, and gets from "what did we agree?" to the answer in seconds.

## Positioning

Nothing joins the meeting. Call audio comes from a passive Core Audio tap and the user's mic is a separate track, so the user is always known and never confused with other speakers. Recording, transcription (OpenAI Whisper Large-v3 Turbo) and speaker separation (pyannote Community-1) run on the Mac. Summaries and Q&A come from ChatGPT (the user's own account, through Sign in with ChatGPT) or Claude (a Claude API key, covered by Max, Ultra, and Team plans' monthly API credits), so no language model runs locally and the laptop stays fast.

## Operating Context

- Runs all day from the menu bar; the main window is opened between calls to review, search, rename speakers, and export.
- A floating prompt appears when a call app takes the microphone; a small recording indicator floats top-right during calls. Both are excluded from screen sharing.
- Back-to-back calls: a new call can be recorded while the previous one is still being processed.
- Dictation: a pill above the Dock shows live audio while the fn key is held; the text is pasted into the app the user was in.
- Exports go to clients and colleagues as Markdown, plain text, SRT, Word (.docx) and PDF, with speaker names and timestamps.
- Client material is confidential: audio stays on the Mac; only transcript text goes to ChatGPT or Claude, for summaries and Ask.

## Capabilities and Constraints

- Meetings: auto-detect calls, record (mic + call audio, echo-cancelled), auto-stop, background transcription queue, speaker naming that learns voices, summaries, "Ask about this meeting", search, playback with word-level follow-along, edit text, change speaker per paragraph, delete with confirmation.
- In-person recording and audio/video file upload (single mixed track, all speakers separated by voice).
- Dictation history kept as text only; dictation audio is discarded.
- Hardware: 18 GB unified memory. No local language model: summaries and Ask use ChatGPT (Plus or Pro, through Sign in with ChatGPT) or Claude (API key).
- Requires Microphone, System Audio Recording, Accessibility (dictation hotkey and paste) and optionally Calendar and Notifications permissions.

## Brand Commitments

- Name: Hootnote.
- App icon: a cartoonish, playful, fun owl.
- The owl's playfulness lives in the icon only. The interface itself is strictly professional: modern, sleek, and at the level of leading software products. (Confirmed by the user, 2026-10-15.)

## Evidence on Hand

- One clearly labeled synthetic sample meeting ("Sample call: Q3 roadmap (synthetic test audio)") built from macOS text-to-speech voices. No real customer data, testimonials or benchmarks exist; none should be invented.
- Pipeline test results in README.md (synthetic calls only).

## Product Principles

1. Zero-effort capture: the right recording starts and stops without the user managing it.
2. Trust who said what: speaker attribution is visible, correctable in place, and learns.
3. Private by construction: no feature may require sending audio or transcripts off the Mac.
4. Answer in seconds: search, summaries and Q&A beat scrubbing through audio.
5. Never block the next call: processing and AI work happen in the background.

## Accessibility & Inclusion

No product-specific needs beyond macOS defaults: semantic colors with sufficient contrast in light and dark, full keyboard access, VoiceOver labels on controls, system text styles, Reduce Motion honored. (Confirmed by the user, 2026-10-15.)
