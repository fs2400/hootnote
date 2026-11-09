---
name: Hootnote
description: A working day of calls set as a railway timetable, where signal red marks only what is live now.
colors:
  ink: "#141518"
  ink-dark: "#F1F2F4"
  signal: "#D91F17"
  signal-dark: "#FF5A50"
  signal-text: "#BF1A12"
  signal-text-dark: "#FF5A50"
  signal-wash: "#D91F1729"
  signal-wash-dark: "#FF5A5029"
  on-signal: "#FFFFFF"
  on-signal-dark: "#141518"
  pill-signal: "#FF5A50"
  line-blue: "#1C66C4"
  line-blue-dark: "#5AA2FF"
  line-green: "#0F8A52"
  line-green-dark: "#3CCB86"
  line-purple: "#7A3FB0"
  line-purple-dark: "#B78BE8"
  line-orange: "#D06A00"
  line-orange-dark: "#F2A040"
  line-teal: "#00828C"
  line-teal-dark: "#3CC4CC"
  line-magenta: "#B8336A"
  line-magenta-dark: "#F07AA8"
  line-brown: "#6D5444"
  line-brown-dark: "#C2A48E"
  line-indigo: "#3B4BB5"
  line-indigo-dark: "#8C98F0"
  app-zoom: "#2D72E8"
  app-zoom-dark: "#5C97FF"
  app-teams: "#5059C9"
  app-teams-dark: "#8C93F0"
  app-browser: "#00897B"
  app-browser-dark: "#3CC4B4"
  app-webex: "#00A0D1"
  app-webex-dark: "#4CC8EE"
  app-slack: "#611F69"
  app-slack-dark: "#C17FCB"
  app-facetime: "#1F9D3F"
  app-facetime-dark: "#4CCB6A"
  ready: "#0B7A48"
  ready-dark: "#3CCB86"
  working: "#1C66C4"
  working-dark: "#5AA2FF"
  caution: "#9A5C00"
  caution-dark: "#F2A93B"
  on-caution: "#FFFFFF"
  on-caution-dark: "#141518"
  search-wash: "#F2A93B52"
  ground: "#FFFFFF"
  ground-dark: "#141518"
  ground-raised: "#F6F7F9"
  ground-raised-dark: "#1C1D21"
  ink-secondary: "#50545C"
  ink-secondary-dark: "#A9ADB5"
  ink-secondary-contrast: "#2E3036"
  ink-secondary-contrast-dark: "#D3D6DC"
  ink-tertiary: "#6B6F76"
  ink-tertiary-dark: "#8A8E97"
  ink-tertiary-contrast: "#45484E"
  ink-tertiary-contrast-dark: "#B8BBC2"
  rule: "#E5E7EB"
  rule-dark: "#2C2E33"
  rule-contrast: "#8A8E96"
  rule-contrast-dark: "#6E727A"
  rule-strong: "#141518"
  rule-strong-dark: "#D9DBDF"
  pill: "#141518"
  on-pill: "#FFFFFF"
typography:
  time-large:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 600
    fontFeature: "'tnum'"
  title:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "22px"
    fontWeight: 700
  section:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 700
  body:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 400
  body-emphasis:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 500
  state:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 600
  time-row:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
    fontFeature: "'tnum'"
  speaker:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  caption:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
  button:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 600
  column-head:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 600
  now-tab:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 700
    fontFeature: "'tnum'"
  time-period:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 600
rounded:
  tab: "3px"
  panel: "12px"
  capsule: "9999px"
spacing:
  head-gap: "6px"
  section-bottom: "10px"
  row: "12px"
  cell: "16px"
  section-top: "34px"
  gutter: "40px"
  column-length: "96px"
  time-column: "104px"
  column-state: "150px"
  column-source: "170px"
  measure: "720px"
  content-max: "1080px"
components:
  timetable-head:
    textColor: "{colors.ink-secondary}"
    typography: "{typography.column-head}"
    padding: "0 0 6px"
  timetable-rule:
    backgroundColor: "{colors.rule-strong}"
    height: "2px"
  hairline-rule:
    backgroundColor: "{colors.rule}"
    height: "1px"
  timetable-row:
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    padding: "12px 0"
  timetable-row-hover:
    backgroundColor: "{colors.ground-raised}"
  timetable-time:
    textColor: "{colors.ink}"
    typography: "{typography.time-large}"
    width: "{spacing.time-column}"
  timetable-time-live:
    textColor: "{colors.signal}"
    typography: "{typography.time-large}"
  section-heading:
    textColor: "{colors.ink}"
    typography: "{typography.title}"
    padding: "34px 0 10px"
  now-line-tab:
    backgroundColor: "{colors.signal}"
    textColor: "{colors.on-signal}"
    typography: "{typography.now-tab}"
    rounded: "{rounded.tab}"
    padding: "1px 6px"
  now-line-rule:
    backgroundColor: "{colors.signal}"
    height: "2px"
  line-dot:
    rounded: "{rounded.capsule}"
    size: "9px"
  state-recording:
    textColor: "{colors.signal}"
    typography: "{typography.state}"
  state-waiting:
    textColor: "{colors.ink-tertiary}"
    typography: "{typography.state}"
  state-transcribing:
    textColor: "{colors.working}"
    typography: "{typography.state}"
  state-failed:
    textColor: "{colors.caution}"
    typography: "{typography.state}"
  state-ready:
    textColor: "{colors.ready}"
    typography: "{typography.state}"
  state-progress:
    backgroundColor: "{colors.working}"
    rounded: "{rounded.capsule}"
    height: "3px"
    width: "120px"
  action-cell:
    textColor: "{colors.ink}"
    typography: "{typography.body-emphasis}"
    padding: "16px"
  action-cell-hover:
    backgroundColor: "{colors.ground-raised}"
  transcript-time:
    textColor: "{colors.ink-secondary}"
    typography: "{typography.time-row}"
    width: "{spacing.time-column}"
  transcript-speaker:
    textColor: "{colors.ink}"
    typography: "{typography.speaker}"
    width: "{spacing.column-source}"
  transcript-word-lit:
    backgroundColor: "{colors.signal-wash}"
    textColor: "{colors.signal-text}"
    textDecoration: "underline thick {colors.signal}"
  search-match:
    backgroundColor: "{colors.search-wash}"
  button-record:
    backgroundColor: "{colors.signal}"
    textColor: "{colors.on-signal}"
    typography: "{typography.button}"
    rounded: "{rounded.capsule}"
    padding: "5px 12px"
  button-quiet:
    backgroundColor: "{colors.rule}"
    textColor: "{colors.ink}"
    typography: "{typography.button}"
    rounded: "{rounded.capsule}"
    padding: "5px 12px"
  button-keep:
    backgroundColor: "{colors.caution}"
    textColor: "{colors.on-caution}"
    typography: "{typography.button}"
    rounded: "{rounded.capsule}"
    padding: "5px 12px"
  call-prompt:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    rounded: "{rounded.panel}"
    padding: "14px"
    width: "350px"
  recording-hud:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.signal}"
    rounded: "{rounded.capsule}"
    padding: "9px 14px"
  dictation-pill:
    backgroundColor: "{colors.pill}"
    textColor: "{colors.on-pill}"
    rounded: "{rounded.capsule}"
    height: "38px"
    padding: "0 16px"
  export-notice:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    typography: "{typography.body-emphasis}"
    rounded: "{rounded.capsule}"
    padding: "10px 16px"
---

# Design System: Hootnote

## Overview

**Creative North Star: "The Railway Timetable"**

Hootnote sets a working day of calls the way a railway sets its timetable. Every meeting, dictation and transcript paragraph keeps its time in one aligned column at the left edge, and the rest of the row reads across from it. Hierarchy comes from scale and weight alone: large tabular times, condensed column heads, a 2 pt ink rule over each table and 1 pt hairlines between rows. The main window has no cards, no tinted panels and no status pills.

Colour is scarce and every colour has one job. Ink is the text and the interactive tint. Signal red means live: a recording, its running clock, the now-line, the word being spoken. Route-line colours appear only as small dots that tell you which app a call came from or which speaker a paragraph belongs to. Green, blue and amber belong to the state words Ready, Transcribing and Failed. White timetable stock turns graphite in Dark Mode, and every colour carries a dark value; secondary ink, tertiary ink and hairlines also carry Increase Contrast values.

The frame is native macOS: sidebar, toolbar search, segmented control, Form settings, menu-bar extra, confirmation dialogs, SF Symbols and SF Pro. The world lives in the detail pane and the floating panels. Motion is short and functional. The now-line travels and the transcript follows playback at 180 ms ease-out, and under Reduce Motion both update in place. The owl's playfulness stays in the app icon and the menu-bar glyph; the interface itself is strictly professional. The direction refused the category default of gray cards, a blue accent and pill status tags, and the build carries none of them.

**Key Characteristics:**
- One 104 pt time column, identical on Home, Meetings, Dictations, search results and every transcript.
- Tabular figures for every time and duration.
- Two rules only: 2 pt ink over each table, 1 pt hairline under each row.
- Signal red reserved for what is live now; the red now-line is the signature.
- Route dots (9 pt) for apps and speakers; names stay ink.
- Five fixed state words in a fixed State column.
- Native chrome tinted ink, with Dark Mode and Increase Contrast values throughout.

## Colors

Ink on white stock (graphite in Dark Mode), one red that means now, a set of route-line dots, and three state colours. Light / dark values below; contrast ratios are WCAG ratios against the stock.

### Primary
- **Timetable Ink** (#141518 light / #F1F2F4 dark): all primary text, start times, meeting titles, speaker names, and the tint for the window, menu-bar panel and Settings (sidebar selection, checkboxes, segmented control, the playback slider while paused). "You" ride the ink line: your speaker dot is ink, and in-person recordings carry an ink dot. 18.3:1 on stock light, 16.3:1 dark.

### Secondary
- **Signal Red** (#D91F17 / #FF5A50): recording, live elapsed time, the now-line and its time tab, the start time of a meeting being recorded, the Record and Stop and transcribe buttons, the playing time and slider tint during playback, and the word being spoken. 5.1:1 light, 5.9:1 dark.
- **Signal Text** (#BF1A12 / #FF5A50; Increase Contrast #9E140E / #FF8078): the word being spoken. A deeper red than Signal so it holds 5.3:1 on its wash in light mode, where Signal managed only 4.3:1. It carries a thick Signal underline, so the word reads as "now" without relying on hue.
- **Signal Wash** (Signal Red at 16%: #D91F1729 / #FF5A5029): the background behind the word being spoken. Nowhere else. Raised from 10% after review, when the wash barely registered as a shape.
- **On Signal** (#FFFFFF / #141518): text on a signal fill. Dark Mode switches to graphite because white on #FF5A50 is only 3.1:1; graphite gives 5.9:1.
- **Pill Signal** (#FF5A50 in both appearances): the listening dot on the always-dark dictation pill.

### Tertiary
Route lines. Each appears only as a dot.
- **Speaker lines**, assigned in order of first appearance to everyone except you: Blue (#1C66C4 / #5AA2FF), Green (#0F8A52 / #3CCB86), Purple (#7A3FB0 / #B78BE8), Orange (#D06A00 / #F2A040), Teal (#00828C / #3CC4CC), Magenta (#B8336A / #F07AA8), Brown (#6D5444 / #C2A48E), Indigo (#3B4BB5 / #8C98F0). The ninth speaker wraps back to Blue.
- **App lines**, close to each app's own identity: Zoom (#2D72E8 / #5C97FF), Microsoft Teams (#5059C9 / #8C93F0), browser calls in Chrome, Edge, Arc, Brave, Firefox or Safari (#00897B / #3CC4B4), Webex (#00A0D1 / #4CC8EE), Slack (#611F69 / #C17FCB), FaceTime and WhatsApp (#1F9D3F / #4CCB6A). In-person recordings use Timetable Ink, uploads use Tertiary Ink, unknown apps use Secondary Ink, and upcoming calendar rows use a Hairline-coloured dot.
- The Blue speaker line shares its values with Working Blue, and Green's dark value matches Ready Green's. They never collide in meaning because a route colour is always a dot and a state colour is always a word.

### State
- **Ready Green** (#0B7A48 / #3CCB86): the Ready state word, the Saved and Copied checkmarks, the "Listening for calls" dot, and level-meter fill. 5.4:1 light.
- **Working Blue** (#1C66C4 / #5AA2FF): the Transcribing state word and its 3 pt progress bar, "Writing summary", the menu-bar processing line, Ask's in-progress line. 5.6:1 light.
- **Caution Amber** (#9A5C00 / #F2A93B): the Failed state word, warnings, the auto-stop countdown, the Keep button fill, and a level meter above 85%. 5.4:1 light.
- **On Caution** (#FFFFFF / #141518): text on the Keep button.
- **Search Amber Wash** (#F2A93B at 32%, both appearances): the background on search matches in transcripts and search results. It is amber so a match never reads as "now".

### Neutral
- **Timetable Stock** (#FFFFFF) / **Graphite Stock** (#141518): the detail pane, floating panels and the player bar.
- **Raised Stock** (#F6F7F9 / #1C1D21): the hover wash on timetable rows and Home action cells. Nothing else.
- **Secondary Ink** (#50545C / #A9ADB5; Increase Contrast #2E3036 / #D3D6DC): column heads, subtitles and speaker lists, durations, section details, the AM/PM period, captions, transcript times. 7.6:1 light, 8.1:1 dark.
- **Tertiary Ink** (#6B6F76 / #8A8E97; Increase Contrast #45484E / #B8BBC2): dates under times, the Waiting state, upcoming calendar rows, talk-share percentages, model credits, the speaker-menu chevron. 5.1:1 light, 5.6:1 dark.
- **Hairline** (#E5E7EB / #2C2E33; Increase Contrast #8A8E96 / #6E727A): 1 pt row rules, the vertical dividers between Home actions, floating-panel borders, the quiet "Not now" button fill, the progress track.
- **Heavy Rule** (#141518 / #D9DBDF): the 2 pt rule heading every table, the call prompt and the menu-bar list.
- **Pill Graphite** (#141518 in both appearances) with **On Pill** (#FFFFFF): the dictation pill, which is always a dark tab over whatever app you are in.

### Named Rules
**The Signal Rule.** Signal red means live now: recording, its clock, the now-line, the word being spoken, and the buttons that start or stop a recording. It is never decoration and never an error colour; failures and warnings are Caution Amber. (Native destructive buttons in system confirmation dialogs keep their system styling.)

**The Ink Tint Rule.** The interactive tint is ink. There is no blue accent; blue appears only as the Transcribing state and as a route dot.

**The Route Dot Rule.** Route colours appear only as 9 pt dots beside an ink name. They never colour text, fills or rules.

## Typography

**Display Font:** SF Pro, the system font (no separate display face)
**Body Font:** SF Pro (`-apple-system` on the web)
**Label/Mono Font:** SF Pro with tabular digits for every time; SF Pro at condensed width for column heads and state words

**Character:** One family, set like a timetable. Semibold tabular figures carry the time, bold sizes carry headings, and condensed semibold carries the column heads and state words, as printed timetables do.

### Hierarchy
- **Time Large** (semibold 600, 20 pt, tabular): start times in the time column on Home, Meetings, Dictations and search results, and the step numbers in onboarding. Followed by the period at 11 pt semibold in Secondary Ink, baseline-aligned, 3 pt apart; 24-hour locales show no period.
- **Title** (bold 700, 22 pt): section headings (Today, Earlier, Recent dictations, each day in Meetings) and the editable meeting title.
- **Section** (bold 700, 17 pt): status headings, empty-state headings, summary section heads, the Ask intro, the drop overlay, sheet titles, onboarding step titles.
- **Body** (regular 400, 14 pt): row text, section details, explanations, transcript paragraphs. Transcript paragraphs add 3 pt line spacing and stop at 720 pt; explanatory prose stops at 560 to 620 pt.
- **Body Emphasis** (medium 500, 14 pt): meeting titles in rows, Home action titles, Ask questions, summary labels, the saved-export notice.
- **State** (semibold 600, 14 pt, condensed width): the five state words in the State column.
- **Time Row** (semibold 600, 13 pt, tabular): transcript times, search-moment times, the player clock, menu-bar times.
- **Speaker** (semibold 600, 13 pt): speaker names in transcript rows and search moments.
- **Caption** (regular 400, 12 pt): subtitles and speaker lists, dates under times, the now-line caption, panel detail text.
- **Button** (semibold 600, 12 pt, the macOS callout size): pill buttons in floating panels.
- **Column Head** (semibold 600, 11 pt, condensed width, never uppercased): Time, Source, Meeting, Length, State.
- **Now Tab** (bold 700, 11 pt, tabular): the time on the now-line's red tab.

### Named Rules
**The Tabular Time Rule.** Every time and duration is set with tabular figures, so a column of times aligns digit for digit and a running clock never jitters.

**The Scale Contrast Rule.** Hierarchy comes from size and weight inside one family: 20 pt semibold times against 14 pt body, 22 pt bold headings against 11 pt condensed heads. No boxes, tints or icons stand in for hierarchy.

## Layout

The main window is a native split view: sidebar (230 pt minimum, 260 pt ideal, 360 pt maximum) and a detail pane on Timetable Stock. Detail content is left-aligned, capped at 1080 pt, with 40 pt gutters, 28 pt above Home, and 40 pt below every scrolling page.

Every table shares one armature: Time (104 pt), Source (170 pt; the speaker column in transcripts and search moments), Meeting (flexible, 12 pt trailing space), Length (96 pt), State (150 pt). Rows align on the first text baseline and take 12 pt above and below. Column heads sit 6 pt above the heavy rule. Section headings take 34 pt above and 10 pt below, with their detail inline after the title, 14 pt apart. The time column was set at 84 pt in the direction and widened to 104 pt after review, because 20 pt figures plus an AM/PM period crowded the next column at 84.

Home opens on three equal action cells (Record in person, Upload audio, Dictation) between a heavy rule and a hairline, divided by 1 pt vertical hairlines, each with 16 pt padding and a 20 pt symbol in a 26 pt slot. Today follows as a timetable sorted morning to evening, cut by the now-line with the next calendar call captioned to its right, then upcoming calendar rows in Tertiary Ink, Earlier, and Recent dictations.

A transcript keeps the same armature: a speaker strip (10 pt vertical padding, 18 pt between speakers; it scrolls sideways when there are more speakers than fit, and its trailing 28 pt fades rather than cutting a name) above a heavy rule, then rows of time, speaker and paragraph. The summary sets its labels across the time and source columns together (274 pt). Dictation rows put the app name in a 110 pt column before a copy button.

The sidebar lists Home, Meetings and Dictations, then day sections of meetings as a 64 pt tabular semibold time and a one-line title.

Floating surfaces sit outside the window: the call prompt (350 pt wide, 14 pt padding) and the recording indicator stack in the top-right corner, 10 pt from the screen edge and 8 pt apart; the dictation pill (38 pt capsule in a 340 by 44 pt panel) centres 12 pt above the Dock on the screen under the pointer; the menu-bar panel is 330 pt wide with 14 pt padding. Settings is a native 640 by 500 pt tabbed Form.

### Named Rules
**The One Armature Rule.** The time column is 104 pt and the source or speaker column is 170 pt on every table in the app. A new table adopts these widths; it does not set its own.

**The Rows Stay Put Rule.** State changes in place. Rows keep their order while being read, and hover adds Raised Stock, never movement.

## Elevation & Depth

The window is flat. Depth comes from rules: the 2 pt heavy rule says "a table starts here", the 1 pt hairline separates rows, and Raised Stock answers hover. Floating surfaces (call prompt, recording indicator, dictation pill) are borderless, non-activating panels with the system window shadow and a hairline border (14% white on the dark pill); they never pull the call app out of the foreground, and they are excluded from screen sharing. One element floats inside the window: the saved-export notice, a capsule over the bottom of the meeting view that dismisses itself after 6 s.

### Shadow Vocabulary
- **Window shadow** (system panel shadow, `hasShadow = true`): call prompt, recording indicator, dictation pill.
- **Transient notice** (SwiftUI `.shadow(color: .black.opacity(0.12), radius: 10, y: 4)`, about `box-shadow: 0 4px 20px rgba(0,0,0,0.12)` on the web): the saved-export notice only.

### Named Rules
**The Flat Stock Rule.** Inside the main window everything sits flat on the stock. The only lift is the transient export notice; rows, cells and headings never carry a shadow.

## Shapes

Square by default. Rules are full-width rectangles, and rows, cells and tables have no corners or outlines. Shapes round only where something is held or floats: capsules for pill buttons, the recording indicator, the dictation pill, the export notice, the 3 pt progress bar, level meters and waveform bars; 12 pt continuous corners on the call prompt; 3 pt corners on the now-line's time tab. Dots are circles at fixed sizes: 9 pt route dots, 7 pt status dots in the toolbar and menu bar, 8 pt listening dot on the pill, 10 pt pulsing recording dot, 12 pt dot beside the live recording clock. Native text fields keep their rounded-border style; the paragraph editor has a 6 pt hairline border. The drop target is a 2 pt dashed ink rectangle (6 on, 4 off) inset 12 pt.

## Components

### Buttons
Native buttons everywhere a window is key; explicit pill buttons where it is not.
- **Shape:** capsule (9999px) for pill buttons; native bezels elsewhere.
- **Record (pill):** Signal Red fill, On Signal text, 12 pt semibold, 5 pt by 12 pt padding, with the `record.circle.fill` symbol. Default action of the call prompt and the menu-bar prompt.
- **Not now (pill):** Hairline fill, ink text, same metrics. Cancel action.
- **Keep (pill):** Caution Amber fill, On Caution text; appears in the recording indicator only during the auto-stop countdown.
- **Summarize (pill):** Timetable Ink fill, Timetable Stock text, same metrics. The default answer in the summary question; ink, not red, because nothing is live.
- **Pressed:** fill drops to 70% opacity. Pill buttons exist because floating panels never become key, and the system prominent style turns gray in non-key windows.
- **Stop and transcribe:** native bordered-prominent, tinted Signal Red, large in the live recording view and regular in the menu bar, beside a native destructive Discard….
- **Toolbar:** native Record in person / Stop recording (Signal Red while recording) and Upload audio.

### Cards / Containers
There are no cards in the main window. Content sits on the stock in rows under rules. The only bounded containers float outside it.
- **Call prompt:** Timetable Stock, 12 pt continuous corners, Hairline border, 14 pt padding, 350 pt wide, opened by a 2 pt heavy rule. A 34 pt app icon, a 14 pt semibold title, a caption, then Record, Not now and a borderless "…" menu (Always record this app).
- **Menu-bar panel:** 330 pt, status line (7 pt status dot plus 13 pt semibold), a 2 pt heavy rule, the five latest meetings as time, title and state word over hairlines, then a checkbox and Open Hootnote.

### Inputs / Fields
- **Search:** the native toolbar search field. Its prompt reads "Search meetings and dictations" or, inside a meeting, "Find in this meeting".
- **Meeting title:** a plain text field set in Title; Return commits and Escape restores.
- **Speaker names:** shown as plain ink text with an I-beam on hover; a click swaps in a 150 pt rounded-border field. Return commits, Escape cancels.
- **Ask:** a rounded-border field and a native Ask button under a hairline at the foot of the Ask tab.

### Navigation
- Native sidebar (`.sidebar` list style) tinted ink: Home, Meetings, Dictations, then meetings by day. A recording meeting's time turns Signal Red.
- Inside a meeting, a native segmented control switches Transcript, Summary and Ask. Arrow keys move through sidebar meetings; Space plays and pauses a transcript; ⌘G and ⇧⌘G step through matches. ⌘← and ⌘→ skip 15 seconds, but while a text box is being typed in they move its cursor, as everywhere on the Mac. Every transcript edit and meeting rename has a named Undo in the Edit menu.

### Timetable
The signature table. A header of condensed 11 pt column heads in Secondary Ink, 6 pt above a 2 pt heavy rule; rows of Time Large (Signal Red while recording; in tables that span days, the date sits below in caption), a route dot and app name, the meeting title in Body Emphasis over a caption of up to three speaker names, the length in tabular body Secondary Ink (a live clock in Signal Red while recording), and the state word. Each row ends in a hairline and takes Raised Stock on hover. The whole row is one button with a single VoiceOver label.

### Now-Line
The signature move: a 2 pt Signal Red rule with the current time on a red tab (bold 11 pt tabular, On Signal, 3 pt corners) at its left end.
- **On Home:** it sits after today's meetings and before upcoming calendar calls, refreshed every 30 s, with a caption naming the next call ("Next: …, in 12 min") or how to connect a calendar.
- **In a transcript:** it rides inside the time column only (104 minus 14 pt wide), travelling down through the paragraph being played in proportion to playback, so it never crosses a speaker name or a word. The row's own time hides while the line carries it, and the word being spoken lights in Signal Red on Signal Wash. Movement uses the travel motion (180 ms ease-out); under Reduce Motion it jumps in place.

### State Words
A fixed vocabulary, always in the State column, always condensed 14 pt semibold: **Recording** (Signal Red, with the `record.circle.fill` symbol), **Waiting** (Tertiary Ink), **Transcribing** (Working Blue), **Failed** (Caution Amber), **Ready** (Ready Green). Under Transcribing, a 120 by 3 pt capsule progress bar on a Hairline track and a caption naming the stage ("Call audio · 62%").

**The Fixed Vocabulary Rule.** A meeting's state is one of these five words, in this colour, in this column. Never a pill, badge or icon alone.

### Meeting Header Line
At most one caption line under a meeting's app, start time and length, saying what is happening to that meeting. It changes in place and never stacks. In order of precedence:
- **Working:** while Clean Up or a join runs, a small spinner and Working Blue text.
- **Didn't finish:** Caution Amber text with native small Try Again and Dismiss buttons.
- **Join offer:** when the meeting looks like the rest of the one before it (same app, same calendar title, started within 3 minutes of that one's end). The text is Secondary Ink, with the earlier meeting's start time in semibold ink so it can be found in the sidebar: "Looks like the rest of the **9:03 AM** meeting, picked up 1 min 14 s after it stopped." It is followed by native small **Join…** and **Not now** buttons, all in tabular figures.
  - It wraps rather than truncating, and it is never amber or red, because nothing has failed.
  - Join… opens the join confirmation.
  - Not now is remembered for that pair and can be undone (Edit › Undo Hide Join Suggestion).

### Transcript Row
Time Row in Secondary Ink inside the 104 pt column (a button that plays from that moment), a route dot plus the speaker name in 13 pt semibold within 170 pt, then the paragraph in Body with 3 pt extra line spacing, selectable, up to 720 pt. Click any word to play from where it was said. The paragraph is native text, so it still reads as plain ink: the pointing hand over the words and a "Click a word to play from there" tooltip (shown until the first click) carry the affordance. A drag selects, a double-click selects a word, and copying gives plain text. VoiceOver reads the paragraph as one label. While a transcript has focus, ↑ and ↓ play from the previous or next paragraph (also Playback › Previous / Next Paragraph, ⌥⌘↑ / ⌥⌘↓). 12 pt above and below, hairline under. Right-click offers Play from here, Copy paragraph, Edit text…, Change speaker and Delete paragraph…. Search matches take the Search Amber Wash.

### Recording Indicator
A capsule on Timetable Stock with a Hairline border, 9 by 14 pt padding: a 10 pt pulsing Signal Red dot (0.8 s fade between 35% and 100%, steady under Reduce Motion), the elapsed clock in 14 pt semibold tabular Signal Red over the app name in caption, two 5 by 22 pt level meters (you and the call), Keep during the countdown, and a borderless stop symbol.

### Summary Question
Shown when a recording ends or an upload is read, while **After each meeting** is set to Ask me and ChatGPT or Claude is connected. The call prompt's panel (350 pt, 14 pt padding, 12 pt continuous corners, Hairline border, 2 pt Heavy Rule on top), stacked under the call prompt and the recording indicator: "Summarize this meeting?" in 14 pt semibold ink, the meeting title in caption Secondary Ink (two lines at most), then Summarize (ink pill) and No thanks (Hairline pill), with "With Claude" or "With ChatGPT" in caption Tertiary Ink at the trailing edge. Unanswered, it leaves after two minutes and no summary is written; the Summary tab still offers one.
### Model Menu
The model the next answer or summary comes from, beside the button it affects: between the Ask field and Ask, and before Write summary or Rewrite. The model name in Caption Secondary Ink (Ink on hover) with a 9 pt semibold `chevron.down` in Tertiary Ink; no bezel. The native menu lists each connected service as a titled section, the chosen model checked; Claude keeps older models under More Models. In Settings › AI the same menu is a native pull-down labelled Default model.
### Connect ChatGPT or Claude
A 640 pt native sheet, offered once after the welcome screen when neither service is connected. Title (22 pt bold), one line of Secondary Ink, then the Heavy Rule and one row per service: the name in Section type inside the 104 pt time column, its explanation and controls beside it, and "Connected" as a Ready Green state word at the trailing edge once it is set up. Claude's row numbers its three steps in Time Row Secondary Ink; the Console link is underlined ink with an `arrow.up.right` symbol. Set Up Later (native) on the left, Done (prominent, ink) on the right, enabled once either service is connected.
### Dictation Pill
A 38 pt Pill Graphite capsule with a 14% white border, centred above the Dock. Listening shows an 8 pt Pill Signal dot and a waveform of 3 pt white bars (3 to 24 pt tall, 2 pt apart, newest on the right); hands-free adds "Tap fn to finish" at 70% white. Transcribing, done and failed show a small symbol and a 12 pt medium message. It never takes clicks or focus.

## Do's and Don'ts

### Do:
- **Do** put every time in the 104 pt time column at the left of its row, in tabular figures: Time Large (20 pt semibold) for start times, Time Row (13 pt semibold) for offsets.
- **Do** head every table with the 2 pt Heavy Rule and close every row with a 1 pt Hairline.
- **Do** keep Signal Red (#D91F17 / #FF5A50) for recording, live clocks, the now-line, the spoken word and the buttons that start or stop recording.
- **Do** mark apps and speakers with a 9 pt route dot beside an ink name; you are always the ink dot.
- **Do** write a meeting's state as one of the five fixed words, condensed 14 pt semibold, in the State column.
- **Do** change state in place and keep row order while the user reads; answer hover with Raised Stock.
- **Do** move things with the travel motion (180 ms ease-out) and let them update in place under Reduce Motion.
- **Do** use native sidebar, toolbar, search, segmented control, Form settings and confirmation dialogs, tinted ink.
- **Do** give every new colour a Dark Mode value, and an Increase Contrast value when it is secondary text or a rule.
- **Do** use explicitly coloured capsule buttons in floating panels, which never become key.

### Don't:
- **Don't** put meetings, dictations or transcript paragraphs in cards, boxes or rounded containers; the timetable is rows and rules.
- **Don't** introduce a blue accent or tint; the interactive tint is ink.
- **Don't** show state as pill tags or badges; state is a word in a column.
- **Don't** use Signal Red for errors, warnings or decoration; failures and warnings are Caution Amber.
- **Don't** colour text, fills or rules with route colours.
- **Don't** let the now-line cross a speaker name or a word; in a transcript it stays inside the time column.
- **Don't** change the time column or source column width for a new screen.
- **Don't** add shadows inside the main window; the transient export notice is the only lift.
- **Don't** bring the owl into the interface; its playfulness lives in the app icon and the menu-bar glyph only.
