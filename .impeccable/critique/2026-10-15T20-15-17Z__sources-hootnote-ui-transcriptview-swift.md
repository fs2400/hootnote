---
target: "the transcript screen: editing and keyboard"
total_score: 29
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/fred/Desktop/Transcription App/Sources/Hootnote/UI/TranscriptView.swift"
target_fingerprint: "sha256:a9d1a1a8f9061c8d99215657b930d5dfdecf3a8f9424ca2f3e459602ca2f6967"
target_path: /Users/fred/Desktop/Transcription App/Sources/Hootnote/UI/TranscriptView.swift
timestamp: 2026-10-15T20-15-17Z
slug: sources-hootnote-ui-transcriptview-swift
---
# Critique: transcript screen, editing and keyboard (Sources/Hootnote/UI/TranscriptView.swift)

Run: two isolated sub-agents (A design review, B detector). Detector: exit 0 and 0 findings on all four files; it has no SwiftUI rules, so deterministic scan unavailable. Browser overlay skipped (native app).

## Heuristics (assessed before this run's fixes)
| # | Heuristic | Score |
|---|---|---|
| 1 | Visibility of system status | 3 |
| 2 | Match with the real world | 3 |
| 3 | User control and freedom | 3 |
| 4 | Consistency and standards | 3 |
| 5 | Error prevention | 3 |
| 6 | Recognition rather than recall | 2 |
| 7 | Flexibility and efficiency | 3 |
| 8 | Aesthetic and minimalist design | 3 |
| 9 | Error recognition and recovery | 3 |
| 10 | Help and documentation | 3 |
| | Total | 29/40 |

## Priority issues and status
1. [P1] Undo changed a meeting you couldn't see. FIXED: undo/redo opens that meeting first and announces what it did.
2. [P2] Beep-and-clear unexplained; Edit menu offered dead steps. FIXED: Clean Up, Re-transcribe, Restore and joins clear that meeting's steps when they save; deleting a meeting clears all its steps; the backstop beep now announces why; Re-transcribe and Restore dialogs say earlier edits can't be undone.
3. [P1] Space and up/down stopped working after clicking a word. FIXED: the paragraph forwards them to the player (tested).
4. [P2] Cmd-Delete (Delete Meeting) took over delete-to-line-start in text boxes. FIXED: handed back while typing (tested).
5. [P2] Up/down while paused moved the playhead out of view. FIXED: keyboard jumps scroll the transcript even when paused.
6. [P2] Hidden focus. FIXED: the speaker strip shows "Space plays or pauses · up down paragraphs" while the transcript or a paragraph has the keyboard.
7. [P3] Wording. FIXED: "Mark as Me" matches its undo; context menus in Title Case; delete-paragraph dialog says it can be undone; Save disabled for empty text; VoiceOver no longer says "Speaker Speaker 1".

## Still open
- Clean Up, Re-transcribe and Join are not undoable themselves (Restore Original covers Clean Up).
- Cmd-E (Export as Word) shadows Use Selection for Find (P3).
- One-off fonts (speaker name 13 pt semibold, recording clock 48 pt) and a repeated hard-coded shadow.
