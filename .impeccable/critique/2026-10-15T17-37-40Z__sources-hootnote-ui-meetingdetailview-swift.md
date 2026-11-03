---
target: Automatic join offer in the meeting header
total_score: 28
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 1
target_identity: "file:/Users/fred/Desktop/Transcription App/Sources/Hootnote/UI/MeetingDetailView.swift"
target_fingerprint: "sha256:86115092911e57f9d7f92a68f88191935529e40cd16b84159806efb4c114e7d1"
target_path: /Users/fred/Desktop/Transcription App/Sources/Hootnote/UI/MeetingDetailView.swift
timestamp: 2026-10-15T17-37-40Z
slug: sources-hootnote-ui-meetingdetailview-swift
---
# Critique: automatic join offer in the meeting header (Sources/Hootnote/UI/MeetingDetailView.swift)

Method: dual-agent (A: design review sub-agent · B: detector sub-agent)

| # | Heuristic | Score | Key issue (before fixes) |
|---|---|---|---|
| 1 | Visibility of status | 3 | Offer appears only after the summary is written |
| 2 | Match real world | 3 | "Not now" means "not for this pair" |
| 3 | User control | 2 | Not now couldn't be undone; a join is reversible only via the Trash |
| 4 | Consistency | 3 | Button casing differs across header lines (existing) |
| 5 | Error prevention | 3 | Strong gating; same-minute default titles could give a false offer (rare) |
| 6 | Recognition | 2 | No offer for drops over 3 min or on the earlier half |
| 7 | Flexibility | 3 | No shortcut for Join; a three-way split needs two joins |
| 8 | Minimalism | 3 | 17 words that truncated at 620 pt; decorative glyph |
| 9 | Error recovery | 3 | Existing Join didn't finish + Try Again |
| 10 | Help | 3 | Tooltips, VoiceOver announcement, full dialog |
| Total | | 28/40 | Good |

Detector: 0 findings (exit 0) on MeetingDetailView.swift and on Sources/Hootnote/UI. It scans web markup, so clean is weak evidence for Swift. Browser overlay n/a (native app).

Design specificity: follows the system (ink, native controls, no card, no red or amber) but uses little of the timetable's own vocabulary. After the fix, the earlier meeting's start time is set in semibold ink with tabular figures, so it reads like a timetable reference.

Priority issues and outcome:
- [P1] The 3-minute rule rarely fires for future splits. During a calendar event the recorder already waits 180 s for a reconnect, so automatic splits there have gaps over 180 s. It still catches a manual stop, another calling app taking the mic, a crash, and splits from older builds. NOT fixed here, because the rule was specified and the fix needs the calendar event id stored on each meeting (AppState.startRecordingAsync, which is being edited elsewhere). Follow-up: store calendarEventID and offer for the same event within maxGap.
- [P2] Truncated at narrow widths: fixed. The text wraps (fixedSize vertical) and the buttons are fixed size. Copy shortened to "Looks like the rest of the 9:03 AM meeting, picked up 1 min 14 s after it stopped."
- [P2] Not now was permanent with no undo: fixed with Edit › Undo Hide Join Suggestion. The label is kept as specified; the tooltip and announcement say the menu still joins them.
- [P2] VoiceOver buttons had no object: fixed. "Join with the 9:03 AM meeting…", "Not now: keep separate from the 9:03 AM meeting", container "Join suggestion".
- [P2] Offer only on the later half: not done (the brief places it there, and the notification opens the later half). Follow-up candidate.
- [P3] Decorative glyph removed; tabular figures added; the collapse after Not now animates with the travel motion and stays in place under Reduce Motion.

Questions to consider:
- If a split is sure enough to say "Looks like the rest of", should a split within one calendar event join automatically, with Undo Join?
- Could the timetable show the two rows as one connection (one train, two legs)?
- Should one dialog join a three-way split?
