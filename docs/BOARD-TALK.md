# Board Talk

Beat Key's UI voice (J, 2026-11-18). Named for the scribble strip on a console: a few
words, in the engineer's own language, readable at a glance mid-session. Artemis can use
the same guide.

J's complaint that started it: the old tips read "psychotic, very verbose"; "it shouldn't
be a pop-up that's ten words where it could be three."

Model: Pro Tools hover tooltips. A short title, at most one short line under it.
(Length rule below is Beat Key's own. Still open 2026-11-18: not yet checked against real
Pro Tools tooltips; the Studio D capture, TOOLTIPS.md, never landed.)

## The rules

1. **Title + one short line.** The title is the control's legend (what is printed on it).
   The body is a phrase, not a sentence. No second sentence unless it is two words
   ("Click to unpin.").
2. **Length.** Body target 3-8 words, **60 characters max** (the cap `HelpTip.maxBody`,
   held by `HelpTests` and by the launch self-check `HelpText.problems`, which logs any
   tip over the cap to beatkey.log). Current table: median 38 characters, 7 words;
   longest 51.
3. **J's words for things.** receive key, get BPM, auto get key, pin / unpin, listen,
   send to Auto-Tune, new song, hold. Not "manual selection", "detect", "analyze" when
   J says "get" or "read".
4. **Concrete verbs, first.** Get, send, pin, click, drag, pick, open, reveal, set.
   Say what the click does ("Click to pin"), not what the control "allows".
5. **Never:** please, you can, allows you to, lets you, simply, easily, in order to,
   "this will". No explaining why. No marketing.
6. **Facts only the control can tell.** What it does, what a click does, the unit
   ("Semitones", "Cents"). Drop anything the screen already shows.
7. **Shortcut last, in parentheses**, taken from the constant that owns it
   (`AutoTuneSend.shortcutDisplay`), never typed twice: `Send key to Auto-Tune (⌃⌥⌘A)`.
8. **Symbols over words** where the screen uses them: `=`, `·`, `›`, `←`, `→`, `%`.
9. **Pinned key is "pin".** A click pins; a click on the pinned key unpins. Never "manual",
   "locked to", "reset manual selection".
10. **Titles stay as the control's legend**, uppercase as printed, and stay unique.

## Before / after (from the old HelpText)

| Tip | Before | After |
|---|---|---|
| BPM | The tempo in beats per minute: the whole number to type into your DAW, decimals smaller. Click to switch normal, double and half time. | Click: normal, double or half time. |
| KEY | The key Beat Key hears; the ring and the % under it show how sure it is. | Key heard. Ring and % show how sure. |
| TOP KEYS | The three likeliest keys and how sure Beat Key is of each. Click 2 or 3 to use that key: it turns white, marked MANUAL. | Three likeliest keys. Click to pin, again to unpin. |
| MANUAL KEY (dial) | Click to reset manual selection. | Click to unpin. |
| LISTEN | Reads BPM and key live from whatever is playing. Nothing is recorded or saved. | Live BPM and key. Nothing recorded or saved. |
| SEND TO AUTO-TUNE | Sets the key and reference pitch in Auto-Tune (and Waves Tune Real-Time). Shortcut ⌃⌥⌘A (Reading menu). | Set key in Auto-Tune, Tune Real-Time (⌃⌥⌘A) |
| OPEN AUDIO | Choose audio files on your Mac, then press FIND KEY/BPM. You can also drop files on the window. | Choose or drop audio files, any number. |
| CHORDS | The key's chords. Click one to hear it; drag it into your DAW or Finder for a MIDI clip. | Click to hear. Drag to a DAW as MIDI. |
| HOLD | Freezes the reading on screen while listening carries on. Press again to follow the music. | Freeze the reading. Click again to follow. |
| ADVANCED | Adds the key wheel, chords to hear and drag, and MATCH TO. First switch each launch sets the window and menu bar; then each on its own. | Add key wheel, chords, MATCH TO. |
| FILE NAMES | Add the key and BPM to a file's name after it is read. Ask each time, always, or never. Pro Tools session files always ask. | Add key + BPM to names. Pro Tools files always ask. |

## Checking a new tip

- Over 60 characters? Cut. The test fails and the launch check logs it.
- Could a word go without changing what the click does? Cut it.
- Would J say it out loud that way? If not, use his word.
- Does it match what the code does today (read the code, not the old tip)?
