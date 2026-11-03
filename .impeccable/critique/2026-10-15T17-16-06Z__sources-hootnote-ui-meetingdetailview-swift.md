---
target: Join with Previous Meeting and reconnect pause
total_score: 27
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:/Users/fred/Desktop/Transcription App/Sources/Hootnote/UI/MeetingDetailView.swift"
target_fingerprint: "sha256:776bde479e02bb08b66ee0532cd5d73ec718da2738aeacb03173fad29bb80718"
target_path: /Users/fred/Desktop/Transcription App/Sources/Hootnote/UI/MeetingDetailView.swift
timestamp: 2026-10-15T17-16-06Z
slug: sources-hootnote-ui-meetingdetailview-swift
---
# Critique: Join with Previous Meeting + reconnect pause (Sources/Hootnote/UI/MeetingDetailView.swift)

Method: dual-agent (A: design review sub-agent · B: detector sub-agent)

| # | Heuristic | Score | Key issue (before fixes) |
|---|---|---|---|
| 1 | Visibility of status | 3 | Success ended silently; paused looked live |
| 2 | Match real world | 3 | "let go of the microphone" is the system's view |
| 3 | User control | 2 | Join irreversible; failed join had no Try Again |
| 4 | Consistency | 3 | Clean Up failure has Try again, Join didn't |
| 5 | Error prevention | 2 | Pair chosen by order alone; no warning on different calls |
| 6 | Recognition | 3 | Retry needed recalling the later meeting |
| 7 | Flexibility | 3 | Not in row context menu |
| 8 | Minimalism | 3 | Paused view kept a stale subtitle |
| 9 | Error recovery | 2 | Ambiguous reasons ("that meeting") |
| 10 | Help | 3 | Tooltip only in the toolbar menu |
| Total | | 27/40 | Acceptable |

Detector: 0 findings (exit 0) on the three files and on Sources/Hootnote/UI. It only regex-scans web syntax in Swift, so clean is weak evidence. Browser overlay n/a (native app).

Priority issues and outcome:
- [P1] Join irreversible: fixed partly. The earlier meeting's replaced files now go to the Trash as well, and the dialog says it can't be split again. There's still no Split/Undo (follow-up).
- [P1] Pairing by order alone: dialog now warns when titles or apps differ and says which title is kept. A proactive offer is a follow-up.
- [P1] Failure recovery: Try Again re-queues the same pair; message adds "Both meetings are unchanged."; reasons now name which meeting.
- [P2] Paused wore live red: amber pause glyph/dot, ink clock, meters at zero, subtitle "Nothing is recorded until the call comes back."
- [P2] Silent success: transient capsule "Joined into one … meeting. The later part is in the Trash." plus VoiceOver announcement.
