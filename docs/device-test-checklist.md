# Device test checklist

Checks that need real ActiveLook glasses or a real outdoor run. None of these
can be done in the simulator, and none is marked as passed. Report each result
by adding a dated line under the item: who ran it, the glasses' firmware
version, the conditions (indoor or daylight, running or still), what was seen,
and pass or fail.

## Chunk 14: segues and heads-ups

The controls for all of these are on the SEGUES sheet (the button next to SCREEN GALLERY,
debug builds): the Segue picker, the Heads-up toggles, a PREVIEW button for
each (loops the mile split until STOP, on the mirror and on the connected
glasses), and the tuning sliders. The settings are saved.

### 1. How many fade steps Bluetooth handles without lag

- **Do:** Connect the glasses. In SEGUES pick FADE, tap PREVIEW and watch the
  split come and go for about 30 s. Then raise FADE IN STEPS and FADE OUT
  STEPS one at a time (4, 5, 6, 8) and keep watching. Repeat with SLIDE and
  GLOW. Try once with REDRAW ONLY WHAT CHANGED off.
- **Expect:** each fade looks like a smooth ramp of brightness, it finishes
  in roughly the FADE IN / FADE OUT time shown, and the split is never seen
  half drawn (every frame is drawn inside hold/flush). It must not lag behind
  the phone's mirror by more than about a quarter of a second.
- **Report:** the largest step count that still keeps up for each segue, and
  any flicker, tearing or lag, with the step count where it began.

### 2. Whether the dimmest brightness levels are visible in daylight

- **Do:** Outdoors in daylight, run the FADE preview at the default 4 steps
  and look at the first fade-in frame (a quarter of full brightness: colour
  levels 2 to 4) and the last fade-out frame. Repeat with GLOW (luma 3).
- **Expect:** the dimmest step is at least faintly visible; if it is not, the
  fade looks like a late snap and the first step count or the minimum level
  needs raising.
- **Report:** which steps were visible, for FADE and for GLOW, and the
  light conditions (sun, overcast, shade).

### 3. Whether the LED is noticeable while running

- **Do:** Turn LED BLINK on (the only heads-up, then together with DOT
  PULSE). During a run (or jogging on the spot), have someone tap the LED
  BLINK PREVIEW, or play a synthetic race (RACE source) so real heads-ups
  happen, 1.5 s before each split, fuel, hill, pace gap and kick clock.
- **Expect:** the green LED's blink is noticed in the corner of the eye
  without looking for it, and it stops when the cue appears.
- **Report:** noticed or not, how many of the heads-ups were seen, and
  whether it was distracting.

### 4. Heads-up timing and partial redraws on the glasses

- **Do:** Play the design walkthrough race at 1x with DOT PULSE on and the
  glasses connected. Watch the kick clock count down in the last 400 m.
- **Expect:** the status dot brightens about 1.5 s before each split, fuel
  reminder, hill notice, pace-gap cue and the kick clock, never before the
  heart-rate warning; the countdown's digits change without leaving ghost
  pixels of the old digits (only the number is redrawn).
- **Report:** any heads-up clearly early or late, any ghosting after a
  partial redraw (if so, retry with REDRAW ONLY WHAT CHANGED off and say
  whether it goes away).
