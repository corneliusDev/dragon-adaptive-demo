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

## Chunk 12: Apple Watch and heart rate

Set up for all of these: an iPhone with this build and a paired Apple Watch
(watchOS 10+) with Dragon installed on it (it installs with the iPhone app;
check the Watch app on the iPhone › Available Apps if not). Signing needs a
team with the HealthKit capability for both targets (the simulator builds
don't). Allow Health access when asked (the first START with the Watch, or
FILL FROM HEALTH). Before START on the live run screen, pick **Phone
sensors** and under "Heart rate from" pick **Watch**. The live screen's
Sensors line shows "Watch HR 152 · 1.2 s behind" while it flows; the
Developer menu (gear) › WATCH LINK lists each message as it arrives, with
its route (mirroring or connectivity). In the simulator only the
WatchConnectivity fallback was exercised (synthetic heart rate:
docs/screenshots/chunk12-*); workout mirroring and HealthKit's real heart
rate need these device checks.

### 12.1 Heart rate reaches the phone in under 5 s, over 10 minutes
- Do: START a Phone sensors run with the Watch. Check the Watch opens
  Dragon by itself and starts a workout (heart rate and elapsed time on the
  Watch). Walk or jog for 10 minutes with both screens on, glancing at the
  phone's Sensors line now and then. END on the phone.
- Expect: the Watch workout starts within a few seconds of START, without
  touching the Watch; the WATCH LINK route says "mirroring" (the
  "connectivity" route only before mirroring is up); the Sensors line's
  delay stays under 5 s and heart rate never shows "missing"; END on the
  phone ends the workout on the Watch (and it appears in Health › Workouts).
- Report: the largest delay you saw, the routes listed, and the run's
  recording (Review › SHARE RECORDING: its vitals with source "watch").

### 12.2 60 minutes with the Watch screen off
- Do: START as in 12.1, lower the wrist (screen off) and lock the phone in
  a pocket; run or walk 60 minutes without looking. END on the Watch this
  time (STOP).
- Expect: the phone's run ends by itself when the Watch workout is stopped
  (it goes to the review). The recording has a Watch heart rate every few
  seconds for the whole hour (no gap longer than 5 s apart from 12.3-style
  range loss) and wrist effort once a second; the review's heart-rate cues
  (if any) fire as for a synthetic run.
- Report: PASS/FAIL, the longest gap in the recording's Watch vitals, the
  Watch battery used, and the recording.
- Note: the iPhone app has the location background mode (it keeps running
  for the run) but not "workout-processing" (chunk 11's test pins the
  background modes to location only). If mirroring fails to reach a locked
  phone, report it: adding workout-processing needs that test changed.

### 12.3 Out of Bluetooth range and back
- Do: during a run as in 12.1, leave the phone somewhere and walk away with
  the Watch until the phone's Sensors line says "Watch HR missing" (or
  60 s), then walk back.
- Expect: within 5 s of losing the Watch the live screen's Heart shows "—"
  and the Sensors line says "Watch HR missing (N s)"; heart-rate cues stop
  (missing data, not the last value). Back in range, heart rate resumes by
  itself within a few seconds without touching either device; readings
  queued during the gap are not back-filled (WATCH LINK counts them as
  dropped; the recording has no Watch vitals inside the gap).
- Report: how long the gap was, how long until HR resumed, and the
  recording.

### 12.4 Fill from Health
- Do: on a phone whose Health has resting heart rate (from the Watch) and
  a date of birth, open a plan, tap FILL FROM HEALTH, allow access.
- Expect: Rest, Threshold and Max fill in (threshold 88% of the way from
  rest to max); the label reads "Heart rate zones · from Health" and the
  note says where max came from. With access denied, the note says Health
  had nothing and how to fix it; the fields are left as they were.
- Report: the numbers filled, compared with Health's own resting HR.
