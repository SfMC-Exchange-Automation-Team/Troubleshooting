# Get-ExoQueue - how-to video

A narrated walkthrough for CSAs and customers: loading the tool, running it, reading the output,
checking the result is complete, and exporting it for a case.

| | |
|---|---|
| **Video** | [`Get-ExoQueue-HowTo.mp4`](Get-ExoQueue-HowTo.mp4) - 6:55, 1080p |
| **Subtitles** | [`Get-ExoQueue-HowTo.srt`](Get-ExoQueue-HowTo.srt) - 91 cues |
| **Transcript** | [`Get-ExoQueue-HowTo.transcript.md`](Get-ExoQueue-HowTo.transcript.md) |

GitHub will not play the MP4 inline from the file list - click through and use **Download**, or clone
the folder. The transcript is there so you can read the material, present it live, or adapt it for a
customer without watching anything.

## The screenshots are real

Every console image in the video and in [`images/`](images/) is an actual run against a lab tenant,
captured from the tool's own output. Nothing is mocked up or retyped, including the numbers.

That matters more than it sounds. Two of them show the tool reporting something *inconvenient* - a
queue of zero, and an under-reported count of 17 against a true 52 - because those are the cases
people actually hit, and a walkthrough that only ever shows the happy path does not prepare anyone
for them.

| Image | Shows |
|---|---|
| `01-first-run.png` | A normal run: counts, queue age, destination breakdown, files written |
| `02-empty-result.png` | Zero results, and the tool explaining that this is a *filter* result |
| `03-truncated.png` | An incomplete run, with the INCOMPLETE warning that makes it safe |
| `04-passthru.png` | `-PassThru`, for checking `Truncated` in a script |
| `05-csv-export.png` | `-Output CSV` with top senders and recipients |

## Contents

1. Title and the approximation caveat
2. Load the tool - dot-source it
3. Connect to Exchange Online
4. Your first run
5. Reading the output - the four numbers
6. **The one check that matters** - `Truncated`
7. Checking it in a script
8. When it reports zero
9. Exporting for a case
10. Journal mail
11. What it cannot do
12. Recap

## Regenerating it

The builders live outside this repo, in the authoring workspace, because they depend on a lab tenant
and a local toolchain (`edge-tts`, `ffmpeg`) that this repo does not carry:

- `New-ExoQueueLabScreenshot.ps1` - runs the tool against a lab tenant and renders each run's console
  to a PNG
- `New-ExoQueueHowToVideo.ps1` - builds the slides, narration, video, subtitles and transcript

If the tool's console output changes materially, regenerate the screenshots first and then the
video, so the two do not drift apart.
