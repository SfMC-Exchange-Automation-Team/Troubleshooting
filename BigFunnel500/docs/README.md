# BigFunnel PostingListTable monitor - walkthrough video

A narrated walkthrough on a live Exchange Server SE DAG: verifying the copy, starting it from
an ordinary shell and watching it elevate itself, reading the report, watching it find
something, seeing why it stays quiet on an estate too small to judge, and scheduling it -
including the one mistake that makes a scheduled monitor look healthy while it has never run
at all.

| | |
|---|---|
| **Video** | [`BigFunnel-Monitor-Walkthrough.mp4`](BigFunnel-Monitor-Walkthrough.mp4) - 12:33, 1080p, 8.4 MB |
| **Subtitles** | [`BigFunnel-Monitor-Walkthrough.srt`](BigFunnel-Monitor-Walkthrough.srt) - 198 cues |
| **Transcript** | [`BigFunnel-Monitor-Walkthrough.transcript.md`](BigFunnel-Monitor-Walkthrough.transcript.md) |
| **Chapters** | [`BigFunnel-Monitor-Walkthrough.chapters.txt`](BigFunnel-Monitor-Walkthrough.chapters.txt) - for Stream or YouTube |

The subtitles are also embedded in the MP4 as a soft track, off by default and switchable in
any player - Teams and Stream both honour it. The `.srt` is there for players that want it
alongside, and for anything that indexes text.

GitHub will not play the MP4 inline from the file list - click through and use **Download**, or
clone the folder. The transcript is there so you can read the material, present it live, or
adapt it for a customer without watching anything.

---

## Which version it shows

**Chapter 1 is v1.14.0. Chapters 2-9 are v1.11.0, and their banners say so.**

That split is deliberate and the narration names it in the first minute rather than leaving
you to find it at 1:48.

Chapter 1 puts a SHA256, a line count and a byte count on screen and tells you to compare them
against the copy you were given, treating a mismatch as tampering or truncation. So those have
to be the values of the script you will actually download, and they are - re-measured against
v1.14.0 on 2026-09-17. Chapter 1 could be corrected honestly because it contains no captured
run output: every value in it is measured directly off the file.

Chapters 2-9 could not, so they were left alone. **Nothing in them is false.** The only visible
difference on v1.14.0 is the completion line, which gained a per-phase breakdown:

```
v1.11.0    50 mailbox(es) evaluated in 4.8s
v1.14.0    50 mailbox(es) evaluated in 4.8s  (bind 2.2s, discover 1.5s, collect 1.9s)
```

Four screens show the old form. Typing the new one in would be inventing output, which is the
one thing the builders promise does not happen, so they stay as captured until there is a
v1.14.0 lab pass to slice from.

Two features postdate the recording entirely and are **not covered anywhere**: `-RegisterScheduledTask`,
which does by itself the registration chapters 7-8 teach by hand, and the `-EmitTo` Event Log
and per-run JSON channels. Both arrived in v1.12.0. Those are omissions, not errors - see the
[runbook](../BigFunnel-PostingListTable-Runbook.md) for either.

---

## The output is real

Every console frame is an actual run against two lab servers, captured from the script's own
output. Nothing is mocked up, nothing is retyped, and nothing is stitched together from two
runs - if a frame needed content no single run produced, the answer was another capture.

That is why the version split above exists at all. It would have been a five-minute edit to
retype four lines and claim the whole thing was v1.14.0. The screens are of an older run
instead, and this file says which.

Two chapters show the tool reporting something inconvenient - a run that stays quiet because
the estate is too small to judge, and a scheduled task that reports `Ready` while having never
run - because those are the cases people actually hit.

---

## Contents

| | |
|---|---|
| 0:00 | Introduction |
| 0:52 | 1. Verify the copy |
| 2:00 | 2. Starting it |
| 3:29 | 3. The first run |
| 4:59 | 4. What a run leaves |
| 6:11 | 5. When it finds something |
| 7:46 | 6. On another DAG member |
| 9:05 | 7. Scheduling it |
| 10:19 | 8. The correct registration |
| 11:26 | 9. A first fortnight |
| 12:22 | Close |

---

## Regenerating it

The builders live outside this repo, in the authoring workspace, because they depend on lab
captures and a local toolchain (`edge-tts`, `Pillow`, `ffmpeg`) that this repo does not carry:

- `storyboard.py` - what is said and shown, one entry per screen
- `build.py` - TTS, then durations, then frames, then ffmpeg
- `render.py` - how a frame is drawn

Narration is the clock: each beat's frames are held for exactly as long as its audio runs, so
picture and voice cannot drift. TTS is cached on the narration **text**, so editing one beat
re-synthesises only that clip.

Pass `--out=<name>` - it stages into `out/<name>/` so a variant build cannot overwrite a file
already delivered.

The published MP4 is re-encoded from the build output before it lands here. The build writes
CRF 20 at 30 fps with 160 kbps audio, which is 21 MB; the shipped file is CRF 26 at 15 fps with
48 kbps mono at 24 kHz, which is 8.4 MB. Measured against the build output: **SSIM 0.9998,
PSNR 50.8 dB** - visually lossless on text. The framerate is the large win and it costs nothing,
because the video is still frames held for a narration beat rather than motion. The audio is
band-limited speech whose content above 12 kHz sits 27 dB below the mean, so resampling to
24 kHz discards nothing audible.

```
ffmpeg -i build-output.mp4 -map 0:v -map 0:a -map 0:s \
  -r 15 -c:v libx264 -crf 26 -preset veryslow -pix_fmt yuv420p \
  -c:a aac -b:a 48k -ac 1 -ar 24000 \
  -c:s mov_text -metadata:s:s:0 language=eng \
  -movflags +faststart BigFunnel-Monitor-Walkthrough.mp4
```

**If the script's console output changes materially, regenerate the captures first and then the
video, so the two do not drift apart.** There is no automated drift check for this walkthrough
yet.
