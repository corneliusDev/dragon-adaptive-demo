# Device test checklist

Checks that need real hardware or a real outdoor run and cannot be done in the
simulator. None of these has been marked as passed. When you run one, add
the date, device(s), build (git commit) and result under it, and attach
anything useful (screenshots, the cue log from Documents/CueLogs, a screen
recording).

How to report: copy the item's heading into an issue or the PR thread,
write PASS or FAIL, what you saw if it differs from "Expect", and attach the
run's cue log (Review → SHARE LOG).

## Chunk 10: phone screens

### 10.1 Live run drives real glasses
- Do: on an iPhone with the ActiveLook glasses, tap CONNECT on the home
  screen, create a plan (any distance), START RUN, set 10x.
- Expect: the glasses show the same frames as the phone mirror (target at the
  start, splits at each marker, the result at the finish, then dark). After
  END, the glasses go back to the developer HUD's own display.

### 10.2 Glasses gestures reach the live run
- Do: during a live run (10.1), wave at the glasses' gesture sensor once, and
  hold for a long look once.
- Expect: a wave shows the status answer (projected finish), a held look the
  split table, within about a second. The review lists them as Status / Split
  table with "seen" or "looked closer".

### 10.3 GPX import from Files / iCloud Drive
- Do: put a race GPX with elevation and one without in iCloud Drive or Files;
  in the plan editor tap IMPORT GPX and pick each in turn.
- Expect: the file name and a summary (distance, hills, aid stations) appear.
  For the file without elevation, the notice "No elevation in this course:
  hill warnings are off." shows in amber. A file shorter than the race
  distance blocks saving with a message.

### 10.4 Screens on a small and a large iPhone
- Do: open Home, the plan editor, a live run and a review on an iPhone SE /
  mini-size device and a Pro Max-size device.
- Expect: nothing is cut off or overlaps; the bottom buttons stay reachable
  with the keyboard up (use Done on the keyboard bar to dismiss it).
