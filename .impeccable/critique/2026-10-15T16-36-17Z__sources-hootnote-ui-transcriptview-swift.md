---
target: the transcript screen
total_score: 26
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:/Users/fred/Desktop/Transcription App/Sources/Hootnote/UI/TranscriptView.swift"
target_fingerprint: "sha256:54eddbed2bd59117c983589ff5170b033d35365dc2c1974a198977f3070f27cb"
target_path: /Users/fred/Desktop/Transcription App/Sources/Hootnote/UI/TranscriptView.swift
timestamp: 2026-10-15T16-36-17Z
slug: sources-hootnote-ui-transcriptview-swift
---
# Critique: transcript screen (Sources/Hootnote/UI/TranscriptView.swift)

Run: two isolated sub-agents (A design review, B detector). Detector v0.1.14 has no SwiftUI rules: exit 0, 0 findings, no Swift files scanned in folder mode, so deterministic scan unavailable for SwiftUI; browser overlay skipped (native app, no URL). Fallback grep found minor token drift only.

## Design specificity
Grounded in this product: the now-line rides the 104 pt time column and the row's own time hides under it; route-line speaker dots; signal red only for now. The speaker strip is the most generic part.

## Heuristics (assessed before this run's fixes)
| # | Heuristic | Score |
|---|---|---|
| 1 | Visibility of system status | 3 |
| 2 | Match with the real world | 3 |
| 3 | User control and freedom | 2 |
| 4 | Consistency and standards | 3 |
| 5 | Error prevention | 2 |
| 6 | Recognition rather than recall | 2 |
| 7 | Flexibility and efficiency | 3 |
| 8 | Aesthetic and minimalist design | 3 |
| 9 | Error recognition and recovery | 2 |
| 10 | Help and documentation | 3 |
| | Total | 26/40 |

## Priority issues and status
1. [P1] Clean Up ran invisibly and could overwrite edits made meanwhile. FIXED: progress line in the meeting header, failure line with Try again, clean-up re-reads the transcript before saving.
2. [P1] Re-transcribe and Restore Original replaced edits without asking. FIXED: confirmation dialogs explaining what is replaced. OPEN: no undo for rename, edit, move, delete.
3. [P1] All-words-as-links risked hootnote:// links in copied quotes and a selection cleared by playback. FIXED: paragraphs are native NSTextView text; copy, drag and Services write plain text (verified); only the lit word's attributes change.
4. [P2] Clicking a word scrolled the paragraph away. FIXED: the follow scroll skips the change caused by a click.
5. [P2] Any click starts audio. PARTLY: a drag or a click that clears a selection no longer plays; a plain click still plays, as the user asked for.
6. [P2] Lit word contrast 4.3:1 on its wash, hue-only in dark. FIXED: Signal Text #BF1A12 (5.3:1), wash 16%, thick Signal underline, Increase Contrast values.
7. [P2] No keyboard seeking. FIXED: up/down in a focused transcript, Playback > Previous/Next Paragraph (opt-cmd-up/down). OPEN: focus cue hidden by focusEffectDisabled.
8. [P2] Static strip fade covered the last chevron. FIXED: 28 pt trailing content margin. OPEN: no leading fade once scrolled.
9. [P3] Clean Up hard to find; tooltip on every paragraph. FIXED: Clean Up and Restore in the More menu; tooltip only until the first word click.

## Persona red flags
- Power user: cmd-left/right are menu shortcuts and probably steal caret moves in the title and Ask fields (verify).
- Keyboard/VoiceOver user: time buttons need Keyboard Navigation; "Speaker Speaker 1" label for unnamed speakers.
- Consultant pulling a quote: addressed (plain-text copy, selection survives, no jump on click).

## Minor
- Speaker name font is a one-off .system(size: 13, weight: .semibold) rather than a token.
- The 1080 max width is repeated in two places; now-line math depends on minHeight 22.
- A sentence split across two speakers has no "merge with previous" fix.
