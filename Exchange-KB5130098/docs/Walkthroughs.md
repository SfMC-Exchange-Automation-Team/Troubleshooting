# Korean Rules 2.1.0 — English and Hindi walkthroughs

Return to the [operator guide](../README.md) for complete commands and prerequisites.
Both editions cover the same retained 2.1.0 workflow, with independently generated
narration, captions, transcripts and chapter timing.

> **2.2.0 correction — manual payload handoff superseded:** these English/Hindi
> recordings and companions were **not regenerated**. After a successful portable
> build, Install prepares/verifies `payload` beside `Install-KoreanRules.ps1`.
> From that same complete writable kit and computer, run
> `.\Install-KoreanRules.ps1 -Download` (or existing media/rules), then
> `.\Get-KoreanRulesState.ps1`, then `.\Set-KoreanRulesState.ps1 -WhatIf`.
> Capturing `$build` or passing `-PayloadDirectory` is no longer required.
> An explicit alternate path still takes precedence; downloads, Apply and
> restarts are not implicit. Follow the written 2.2.0 guide over the recordings.

## Choose a language

| Edition | Video | Audio-only | Text and captions |
|---|---|---|---|
| English | [MP4](en/Exchange-KoreanRules-2.1.0-English-Walkthrough.mp4) | [M4A](en/Exchange-KoreanRules-2.1.0-English-Narration.m4a) | [Transcript](en/Exchange-KoreanRules-2.1.0-English-Transcript.txt) · [SRT](en/Exchange-KoreanRules-2.1.0-English-Captions.srt) · [WebVTT](en/Exchange-KoreanRules-2.1.0-English-Captions.vtt) |
| Hindi / हिंदी | [MP4](hi/Exchange-KoreanRules-2.1.0-Hindi-Walkthrough.mp4) | [M4A](hi/Exchange-KoreanRules-2.1.0-Hindi-Narration.m4a) | [हिंदी पाठ](hi/Exchange-KoreanRules-2.1.0-Hindi-Transcript.txt) · [SRT](hi/Exchange-KoreanRules-2.1.0-Hindi-Captions.srt) · [WebVTT](hi/Exchange-KoreanRules-2.1.0-Hindi-Captions.vtt) |

**Hindi edition:** हिंदी में नैरेशन और देवनागरी कैप्शन दिए गए हैं। स्क्रीन पर
PowerShell कमांड, पैरामीटर और उदाहरण अंग्रेज़ी में ही रखे गए हैं, ताकि वे
स्क्रिप्ट से मेल खाएँ। स्क्रिप्ट के अपने संदेशों का अनुवाद नहीं किया गया है।

Both videos are **1920 × 1080**, with visible captions and **18 embedded chapters**.
English runs **11 minutes 6 seconds**; Hindi runs **13 minutes 38 seconds**.
They use generic natural-sounding neural voices synthesized locally, not voice
cloning. Narration and local speech checks do not send text or audio to an online
speech service. Model downloads are separate from local synthesis.

[![English preview](en/Exchange-KoreanRules-2.1.0-English-Poster.png)](en/Exchange-KoreanRules-2.1.0-English-Walkthrough.mp4)

[![Hindi preview](hi/Exchange-KoreanRules-2.1.0-Hindi-Poster.png)](hi/Exchange-KoreanRules-2.1.0-Hindi-Walkthrough.mp4)

## Chapter index

The same chapters have different start times because each narration was
generated and timed in its own language. Times below are elapsed minutes:seconds.

| English | Hindi | Chapter |
|---|---|---|
| 00:00 | 00:00 | Three commands and their responsibilities |
| 00:32 | 00:39 | Browse, download, extract and keep a stable folder |
| 01:06 | 01:20 | Install choices and explicit downloads |
| 01:48 | 02:13 | Positional source and output paths |
| 02:29 | 03:06 | Incomplete media and strict verification |
| 03:07 | 03:50 | Use the returned payload directory — manual handoff superseded in 2.2.0 (see above) |
| 03:40 | 04:31 | Get is inspection only |
| 04:13 | 05:13 | Yellow skips, reasons and continued inspection |
| 04:55 | 06:05 | Positional computers and native Exchange CSV columns |
| 05:36 | 06:54 | Compact output at four or more targets |
| 06:07 | 07:35 | Inspect every result in `$report` |
| 06:41 | 08:19 | CSV, JSON, JSONL and Splunk guidance |
| 07:17 | 09:04 | Set, WhatIf and optional confirmation |
| 07:52 | 09:50 | One approved pilot and explicit restart |
| 08:26 | 10:32 | Workload recovery evidence |
| 09:00 | 11:13 | Serial rollout and required recovery attestation |
| 09:34 | 11:57 | Exit codes, receipts and appropriate escalation |
| 10:23 | 12:49 | Validation boundaries and handoff |

## What changed from the older video

- Install with no arguments now shows choices, not a mandatory file-path prompt.
- Source EXE/folder and optional new output folder can be positional arguments;
  Get and Set accept positional computer names. CSV still needs `-CsvPath`.
- Pasted paired quotes, folder ambiguity and missing input are explained.
- Size/hash/version failures show observed and required identities; downloads
  remain visibly partial until identity and signature checks pass.
- Expected existing-rule and incompatible-identity targets are yellow skips.
  Set records why and continues inspection; skipped targets are not modified.
- Routine skipped/input states do not automatically require a Support case.
  Partial operations, unstable processes and exceptional rollback retain their
  separate investigation and approval requirements.
- Four or more targets use Status + Count totals without losing report rows.
- Older releases and recordings are in the [archive](../archive/README.md).

## Important boundaries

These are **illustrative examples**, not recordings of a fresh deployment.
Install prepares files; it does not install SQL or apply the workaround.
Set modifies eligible servers unless `-WhatIf` is supplied. A matching filename,
green state, exit zero or a running service is not a recovery sign-off.

The Hindi edition explains the same controls and limits; it does not grant
different permissions or bypass input, identity, maintenance or recovery checks.
No new workload pilot or customer Splunk validation is claimed by translating or
rebuilding the video. See [validation and limitations](Lab-Validation.md).

## Download and playback

The links open browsable GitHub file pages. Select **Download raw file** if no
player appears, or download the MP4 and play it locally. The audio-only M4A
contains the same narration and chapters. Captions are burned into each video;
SRT/WebVTT files are supplied for reuse.

Media is kept separate from the source ZIP. The 2.1.0 code archive and checksum
are preserved unchanged in [archived downloads](../archive/downloads).
The latest source kit is 2.2.1; this documentation correction does not regenerate
media or move/remove files in existing operator working folders.
