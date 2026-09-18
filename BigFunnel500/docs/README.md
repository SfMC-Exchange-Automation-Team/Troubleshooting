# BigFunnel PostingListTable monitor - walkthrough video

A narrated walkthrough on a live Exchange Server SE DAG: verifying the copy, starting it from
an ordinary shell and watching it elevate itself, reading the report, watching it find
something, seeing why it stays quiet on an estate too small to judge, and scheduling it -
including the one mistake that makes a scheduled monitor look healthy while it has never run
at all.

| | |
|---|---|
| **Video** | [`BigFunnel-Monitor-Walkthrough.mp4`](BigFunnel-Monitor-Walkthrough.mp4) - 12:41, 1080p, 8.6 MB |
| **Subtitles** | [`BigFunnel-Monitor-Walkthrough.srt`](BigFunnel-Monitor-Walkthrough.srt) - 201 cues |
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

**All nine chapters are v1.14.0**, the same version this repo carries, captured on
2026-09-17.

Chapter 1 puts a SHA256, a line count and a byte count on screen and tells you to compare them
against the copy you were given, treating a mismatch as tampering or truncation. Those are the
values of the script you will actually download, measured off the file rather than transcribed.

An earlier cut of this video had a **version split**: chapter 1 was v1.14.0 and chapters 2-9
were v1.11.0, because at the time there was no v1.14.0 lab pass to slice from and the builders
do not invent output. That split is gone - the whole recording was re-shot against v1.14.0. If
you have a copy of the video whose chapter 2 banner reads `v1.11.0`, it is the old cut.

### What moved in the estate between the two recordings

The lab is not frozen, so a few figures differ from the older cut. None of it changes the
script's behaviour, but it is worth knowing if you are comparing the two:

- **W25-EX03 is powered off.** It still resolves inside the domain, but answers nothing and
  mounts nothing.
- **`Mailbox Database 1144270448` failed over from W25-EX03 to W25-EX01.** That is why
  W25-EX01 now reports **3 databases and 55 mailboxes** where it reported 2 and 50.
- **Chapter 6 moved to W25-EX02**, which mounts exactly one database (`clab-daga-db01`,
  42 mailboxes). It was W25-EX03 in the older cut.

The three seeded mailboxes did not move, so the Alert and Emerging findings reproduce to the
digit - the same growth rate and the same "critical in 2 day(s)".

### What the recording does not show

Two features are **named on screen but never demonstrated**: `-RegisterScheduledTask`, which
does by itself the registration chapters 7-8 teach by hand, and the `-EmitTo` Event Log and
per-run JSON channels. Chapter 1 lists both in its "if asked to" panel and chapter 5 mentions
the exit code registration can return, but neither is shown running. Both arrived in v1.12.0.
Those are omissions, not errors - see the
[runbook](../BigFunnel-PostingListTable-Runbook.md) for either.

---

## The output is real

Every console frame is an actual run against two lab servers, captured from the script's own
output. Nothing is mocked up, nothing is retyped, and nothing is stitched together from two
runs - if a frame needed content no single run produced, the answer was another capture.

That discipline is why the version split described above existed at all, and why it took a
full lab pass rather than an edit to remove. Retyping four lines to claim the whole thing was
v1.14.0 would have been a five-minute job.

Two chapters show the tool reporting something inconvenient - a run that stays quiet because
the estate is too small to judge, and a scheduled task that reports `Ready` while having never
run - because those are the cases people actually hit.

---

## Contents

| | |
|---|---|
| 0:00 | Introduction |
| 0:42 | 1. Verify the copy |
| 1:50 | 2. Starting it |
| 3:19 | 3. The first run |
| 4:57 | 4. What a run leaves |
| 6:09 | 5. When it finds something |
| 7:52 | 6. On another DAG member |
| 9:12 | 7. Scheduling it |
| 10:26 | 8. The correct registration |
| 11:33 | 9. A first fortnight |
| 12:29 | Close |

---

## Regenerating it

The builders live outside this repo, in the authoring workspace, because they depend on lab
captures and a local toolchain (`edge-tts`, `Pillow`, `ffmpeg`) that this repo does not carry:

- `storyboard.py` - what is said and shown, one entry per screen
- `build.py` - TTS, then durations, then frames, then ffmpeg
- `render.py` - how a frame is drawn
- `make-transcript.py` - `narration.txt` into the transcript published here

Narration is the clock: each beat's frames are held for exactly as long as its audio runs, so
picture and voice cannot drift. TTS is cached on the narration **text**, so editing one beat
re-synthesises only that clip.

Pass `--out=<name>` - it stages into `out/<name>/` so a variant build cannot overwrite a file
already delivered.

The transcript is **generated, not written.** It was hand-assembled once, which is exactly how
it came to still describe the version split after the re-record removed it. `build.py` stamps
its runtime from the finished MP4 rather than from the frame plan - the two differ by about a
second and a half, because `-shortest` trims the mux to the audio track - so the figure in the
transcript is the one a player will show.

### The shipped encode

The published MP4 is re-encoded from the build output before it lands here. The build writes
CRF 20 at 30 fps with 160 kbps audio, which is 21.3 MB; the shipped file is CRF 26 at 15 fps
with 48 kbps mono at 24 kHz, which is 8.6 MB.

```
ffmpeg -i build-output.mp4 -map 0:v -map 0:a -map 0:s \
  -r 15 -c:v libx264 -crf 26 -preset veryslow -pix_fmt yuv420p \
  -c:a aac -b:a 48k -ac 1 -ar 24000 \
  -c:s mov_text -metadata:s:s:0 language=eng \
  -movflags +faststart BigFunnel-Monitor-Walkthrough.mp4
```

Measured against the build output it came from: **SSIM 0.9992**, PSNR **45.4 dB** average with
a per-frame median of **54.6 dB**. The framerate is the large win and it costs nothing, because
the video is still frames held for a narration beat rather than motion. The audio is
band-limited speech whose content above 12 kHz sits 27 dB below the mean, so resampling to
24 kHz discards nothing audible.

The PSNR *minimum* is 20.5 dB, which looks alarming and is not. 0.3% of frames score below
25 dB and every one of them sits on a chapter-card cut - at 15 fps the comparison lands one
frame the far side of a scene change and scores two entirely different screens against each
other. It measures the resample, not the encode.

**Re-measure after every build rather than quoting these figures.** x264 here is not
bit-reproducible: a rebuild from identical inputs produces a different file hash, so a shipped
file measured against a build output it did not come from describes neither.

**If the script's console output changes materially, regenerate the captures first and then the
video, so the two do not drift apart.** There is no automated drift check for this walkthrough
yet.
