# Field recordings

Real runs recorded by the app (Phone sensors). Each run is two files with
the same base name, shared from the run's review screen (AirDrop, Mail,
Save to Files):

- SHARE RECORDING: `<run>.json`, the RunRecording (every input the engine took)
- SHARE LOG: `<run>.jsonl`, the cue log saved at END

Drop both here and run `swift test --filter FieldRecordingTests`: each
recording is replayed through RunEngine and must give the same cues as its
cue log. See docs/device-test-checklist.md (11.3).
