---
version: 1
slug: "sources-hootnote-ui"
primary_target: "Sources/Hootnote/UI"
related_targets: ["Sources/Hootnote/App"]
---

# Hootnote app shell (Operate)

Scope: the whole native macOS app: main window (Home, Meetings, Dictations, meeting detail with transcript, summary and player), menu-bar panel, call prompt, recording indicator, dictation pill, settings, onboarding. Visitor mode: Operate. Audience and constraints live in PRODUCT.md; the brand commitment that matters most here: the owl's playfulness stays in the icon, the interface is strictly professional.

## Direction contract

THESIS: Hootnote sets a working day of calls like a railway timetable: every meeting and every sentence keeps its time in one aligned column, and signal red marks only what is live now. It refuses the category default of gray cards, a blue accent and pill status tags.

OWN-WORLD: White timetable stock (graphite in Dark Mode); ink-black SF Pro with tabular figures; hairline rules, with a 2 pt ink rule heading every table; signal red reserved for recording, live and now; route-line colours (blue, green, purple, orange, teal) as dots for apps and speakers; ink as the interactive tint. Native sidebar, toolbar and controls.

STORY: Between calls the user opens Hootnote, reads today's timetable (recording, transcribing, ready), opens a meeting, reads who said what by time, fixes a name in place, asks a question, exports to Word or PDF.

FIRST VIEWPORT: Native sidebar (Home, Meetings, Dictations, then day-grouped meetings as time and title). Home: three actions on a 2 pt ink rule (Record in person, Upload audio, Dictation), then Today as a timetable (Time in a fixed 104 pt column of large tabular figures, Line, Meeting, Length, State) cut by a red now-line at the current time, its caption naming the next call; Recent dictations below. (104 pt, amended from 84 after review: 20 pt figures plus an AM/PM period crowded the next column at 84.)

FORM: Railway Timetable, candidate 5 of 7 on the ordered list. seed: none (unavailable). Signature move: the red now-line. On Home it marks the present between past and upcoming meetings; in a transcript it travels down within the time column through the paragraph being played, proportional to playback, never crossing a speaker name or text, while the word being spoken lights in signal red. Rows never move. Motion 180 ms ease-out; under Reduce Motion movement updates in place and only appearances fade.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Raises carried from the hand

- Hierarchy by scale contrast alone (variable font specimen): large tabular times, no cards.
- One armature (Crouwel grid): the time column is the same width on Home, Meetings and every transcript.
- Fixed state sequence (botanical folio): Recording, Transcribing, Ready always in the same place with the same words.
- States change in place (ticket wallet): rows never reorder while being read.
- Next item one step away (vertical feed): arrow keys move through meetings.

## Unresolved

- None.
