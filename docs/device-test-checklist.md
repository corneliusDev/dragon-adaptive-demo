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

## Chunk 11: real iPhone sensors

Set up for all three: an iPhone with this build, Location allowed "While
Using the App" and Motion & Fitness allowed (the live run screen explains
each before iOS asks). On the live run screen pick **Phone sensors**. At the
end, tap END; the review then has SHARE LOG and SHARE RECORDING.

### 11.1 Known 1-mile route: distance accuracy
- Do: pick a route whose length you know to be 1 mile (a measured track:
  4 laps of lane 1 is 1600 m, so use 1609 m as 4 laps + 9 m; or a certified
  course segment). Record its GPX (e.g. draw it in a route planner) and run
  it twice with the phone in a pocket: once with a plan that has the GPX
  imported (Custom distance 1.00 mi), once with a plan without a course.
  Stop at the end of the mile and tap END.
- Expect: the review's distance ("Ended at …" or the finish) is within 2% of
  the true mile with the course (1577–1641 m) and within 4% without
  (1545–1673 m).
- Note: with no course the engine integrates GPS fixes. In synthetic testing
  (synthetic GPS noise) that reads about 6.5% long over a mile, so the 4%
  item may fail; report the measured figure either way.
- Report: both distances, the phone model, weather/sky view, and both
  recordings and cue logs.

### 11.2 Screen locked for the whole run
- Do: start a Phone sensors run, lock the phone and put it in a pocket; run
  at least 10 minutes without unlocking; unlock and tap END.
- Expect: the blue location indicator shows while locked; the elapsed time
  and distance kept growing the whole time (no flat stretch in the splits);
  the recording has GPS fixes about once a second throughout (no gap longer
  than ~5 s apart from real GPS loss) and motion/cadence samples throughout.
  If glasses were connected, cues kept arriving on them while locked.
- Report: PASS/FAIL, the run's length, any gap you saw, the recording.

### 11.3 A field recording replays with the same cues
- Do: after 11.1 or 11.2, on the review tap SHARE RECORDING and SHARE LOG
  and get both files (`<run>.json` and `<run>.jsonl`, same base name) onto
  the Mac. Copy them into
  `Packages/DragonEngine/Tests/DragonEngineTests/Fixtures/field/` and run
  `swift test --package-path Packages/DragonEngine --filter FieldRecordingTests`.
- Expect: the test passes: replaying the recording through RunEngine gives
  exactly the cues (and finish time) in the run's cue log. The Developer menu
  (gear on the home screen) also lists the run under RECORDINGS; REPLAY plays
  it through the live screen at 1x/10x.
- Report: PASS/FAIL and the test output; keep the pair as a fixture if it's
  useful for later chunks (check that it holds nothing private, it's a GPS
  trace).

### 11.4 Motion effort score on a real body
- Do: on any Phone sensors run, jog easy for 3 minutes, run at race pace for
  3 minutes, then sprint for 30 s, with the phone in a shorts or jacket pocket.
- Expect: on the live screen the Engine line reads "Effort light" when easy,
  "moderate" at race pace and "hard" in the sprint (PhoneMotionSource maps
  RMS user acceleration linearly from 0.03 g = 0 to 1.2 g = 100; these two
  numbers are in its Config to tune). Cadence (in the recording) is close to
  your real steps a minute.
- Report: the effort label seen at each pace, where the phone was carried,
  and the recording.
