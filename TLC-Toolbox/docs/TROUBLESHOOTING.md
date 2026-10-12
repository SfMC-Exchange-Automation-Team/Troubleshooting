# Reading a TLC Toolbox Teams evidence bundle

[Toolbox installation and collection instructions](../README.md)

The useful starting point is **what happened, when, to whom, on which client/session, and
whether the evidence covers that moment**. Do not start by searching every file for `error`.
Teams can log harmless retries and launch-time policy checks; an error must match the
symptom, timestamp, session and surrounding state before it becomes a plausible cause.

## First ten minutes

| Order | Inspect | Key questions |
|---|---|---|
| 1 | `Scope.json`, `Run.json` | Correct affected user, scenario, device, time zone and incident? Did the run finish or fail? |
| 2 | `Blockers.csv`, `ManualChecklist.md` | What was skipped, unreadable, incomplete or owed from a portal? Is log coverage missing? |
| 3 | `Endpoints\<device>\Capture.json` and `Samples.jsonl` for live traces | Actual session start/end, count/cadence, probe errors, freeze/exit/restart times? |
| 4 | `ClientLogs\ClientLogs.manifest.json`, `Window-Timeline.log`, `Window-Excerpt.log` | Which log families were copied, where are gaps, and what happens around the symptom? |
| 5 | `Inventory.json`, `ClientState\`, `EventLogs.json` | Client/OS/WebView2 build, selected devices, prior exit state, crash/hang events or identity failures? |
| 6 | `Network.json`, `SupportFiles\`, browser exports, service telemetry | Does client state corroborate network findings? Do actual call/media/identity records support the hypothesis? |

Not every scenario creates every file. The plan/checklist and collection warnings explain
expected evidence and missing inputs; absence is not automatically a healthy result.

For a sealed archive, first run `Test-TlcBundleIntegrity` as shown in the README.
`Manifest.json` verifies included files; `.bundle.json` beside the ZIP records the whole-archive
hash. Verify **inside the archive**, not by comparing a run folder whose status files may
have changed after packaging. Integrity establishes unchanged bytes, not diagnostic truth.

## Time and correlation are the foundation

- Write down the **local symptom time, UTC equivalent and time zone/offset**. Include seconds
  when possible, meeting/call/session ID, client/device, and the specific symptom.
- A retrospective collection's `Scope.json` window chooses already-written logs; it does not
  enable logging. Old logs may have rotated away.
- A live trace uses `Capture.json -> Session.StartedUtc/EndedUtc`. Retrospective impact-window
  fields are not its sampling window.
- The toolbox treats rolling Teams log timestamp values as UTC. In the Windows new-Teams
  log format it supports, a numeric UTC timestamp can be followed by a local offset suffix;
  its parser intentionally ignores that suffix. Do not apply the offset twice. This is a
  collector-format rule, not a universal instruction for every service/browser log.
- Start with `Window-Timeline.log` for cross-family ordering, then go back to the original
  copied file for full context. Excerpts are filtered/capped and may suppress repeated lines;
  they are not the whole source file.
- Match **the same call/session/correlation identifiers**, not just a timestamp or user.
  A toolbox `CorrelationId` identifies the collection run; it is not automatically a Teams
  service call ID.

## Three practical scenario investigations

### Poor meeting or call quality

1. Determine **audio, video or screen sharing**, the affected direction (send/receive), the
   user/session/device, and whether one participant or several were affected.
2. Check real **participant media telemetry** in Teams admin-center meeting/call
   troubleshooting; use CQD for wider patterns. Compare stream loss, jitter/latency, bandwidth,
   device or compute symptoms and relevant timing instead of averaging everything together.
3. Inspect `Network.json`: proxy stacks, VPN/tunnel/adapters, DNS/TLS chain, relay connectivity
   and permissions/unmeasured outcomes. A successful probe does not prove Teams used that path.
4. Compare `SupportFiles.TeamsOffline` in `Blockers.csv` and the harvested application's network
   state with the synthetic probes. Teams may be offline while a separate probe still replies.
5. Check the configured microphone/speaker/camera in `ClientState\cmd_settings.json` and
   device inventory. A device can be detected but unused; HDMI/display audio is not a
   microphone, and an unknown device status alone does not prove the fault.
6. Preserve the complete Teams support folder and weblog ZIP. **Media and signaling logs
   are encrypted and require Microsoft Support to decrypt**; do not claim to decode them
   with this toolbox.

**Reading the live graph**

| Metric | What it means | What it does not prove |
|---|---|---|
| STUN RTT/jitter/loss | Synthetic UDP relay-probe behavior at saved sample times | Actual call packet loss, codec quality, MOS, or the call's exact network route |
| Teams/WebView2 MB | Sum of process working sets; trends can suggest resource pressure | A fixed Teams memory limit, a leak, or attribution of system RAM use to Teams alone |
| Total/available RAM | Usable system physical capacity and available memory | Commit/page-file capacity; the initial preview is not saved evidence |
| Green/amber/red | Documented thresholds applied as indicative display bands | A root-cause diagnosis or actual CQD stream classification |

RTT bands are below 200 ms, 200-500 ms, and above 500 ms. Available-RAM critical red takes
precedence below 1% **or** 500 MB; otherwise amber below 10% **and** 4 GB, otherwise green.
Missing readings remain unknown/gaps. Purple memory means system-RAM context was not
measured. These bands and the tooltips cite source guidance, not app-specific causal limits.

### Desktop launch, crash or performance

1. Check client version, install/update history and platform in `Inventory.json`. Correlate
   with `Launcher_*`, update/autostart logs, and the affected process/session.
2. Look for **Windows Application Error 1000, Windows Error Reporting 1001 and Application
   Hang 1002** at the symptom time. Inspect exception/faulting module and surrounding records;
   a named module alone is not proof that it caused the issue.
3. Review `ClientState\uae.json` and `previous_session_data.json` for the client's account of
   the previous exit; do not treat the current client's state as proof of the earlier session.
4. In a live trace, match `Capture:TeamsNotResponding` / `Capture:TeamsExited` warnings and
   sample responsiveness/process-start changes against event and client logs.
5. Inspect **growth over time**, a freeze's first/last observed sample, or a restart. A large
   working set by itself is not a leak; shared process memory may be counted more than once.
6. Record changes, rather than clearing cache/reinstalling first and destroying evidence.
   The toolbox collects facts; it does not prescribe an automatic reset.

### Sign-in or authentication failure

1. Capture the **exact error code/message**, UTC time, signed-in identity/tenant context and
   correlation/request ID if shown. Do not paste tokens into notes or public issues.
2. Correlate with **Microsoft Entra sign-in logs**: failure reason, application/resource,
   Conditional Access result, authentication steps and device context. Portal permissions
   and access are separate; a local capture does not collect Entra sign-in history for you.
3. Check local client/WebView2 state, clock accuracy, Windows identity/event records and
   relevant DNS/proxy/TLS symptoms. A launch failure and a service identity rejection are
   different paths.
4. Distinguish user credentials, policy/device compliance, token-broker state and network
   access using corroboration. A local generic `401`/`403` is not a diagnosis by itself.
5. Preserve the original failure before signing out/resetting; those actions can change the
   very session and broker evidence you need.

## Other scenarios need other evidence

- **Web / Files:** HAR plus console output, and WebRTC internals for relevant browser media.
  Capture after sign-in using the sanitized HAR export; the toolbox still redacts credentials
  left in response bodies before packaging. Match request URL/resource, status, timing,
  server correlation ID and the actual failed operation. Desktop probes are not a substitute
  for a missing browser export. A `403` may be a permission/policy issue, not a transport issue.
- **VDI:** verify the affected session is actually virtual and whether media is SlimCore-based,
  legacy optimized, or fallback. Vendor/session-host/endpoint evidence may be required.
- **Rooms, Android Rooms, Mobile, CVI, tenant/service:** use the actual device and approved
  portal/service evidence. Local live trace is disabled for these targets deliberately.
- Follow `ManualChecklist.md` for the sources still owed; the tool does not invent those exports.

## Prove the collection worked before interpreting it

For live captures:

- Count readable saved records and compare with `Session.SampleCount`; inspect `Errors` per probe.
- Look at **actual timestamp gaps**, not just the requested five-second cadence or its average.
  A brief issue can occur between samples. Warm-up is outside the recording window.
- Compare closing `Collect.json` times with the capture session; confirm copied logs cover
  the symptom and inspect `MainLogGaps` / failed-copy lists.
- Check support-file status separately. `Run.json = Complete` and `ShortcutSent` do not prove
  support files arrived or finished writing.
- During stopping, quiet-period progress can restart when Teams writes again. Closing settings
  files and the required unchanged interval are readiness checks, not a fabricated completion
  percentage. Review any skipped, partial or failed support artifacts.

Do not infer that a call happened by counting `RegisterCall`, `MeetingJoin` or similar strings:
they can be launch, policy or graphics events. Call existence and media quality need supported
call/session evidence, not a keyword-frequency heuristic.

## Record a hypothesis, not just a pile of errors

Use a short case note:

```text
Symptom / affected user and device:
Local time, UTC time, time zone:
Meeting/call/session/correlation identifiers:
Collection run ID, scenario and actual covered window:
Missing/skipped evidence and timing gaps:
Observed client events around the symptom:
Corroborating service/media/device/network evidence:
Current hypothesis and contradictory observations:
Next discriminating test / required portal export:
Bundle integrity result and approved handover location:
```

Keep this note in the case's approved private system, not this public repository.

## Authoritative guidance

- [Microsoft: collect Teams log files](https://learn.microsoft.com/en-us/microsoftteams/log-files)
  - UTC timestamps, collection procedure, multi-account scope and encrypted media/signaling logs.
- [Microsoft: monitor and troubleshoot meetings/calls](https://learn.microsoft.com/en-us/microsoftteams/monitor-troubleshoot-teams-meetings-calls)
  - current admin-center participant/session telemetry and required permissions.
- [Microsoft: Call Quality Dashboard](https://learn.microsoft.com/en-us/microsoftteams/turning-on-and-using-call-quality-dashboard)
  - broader quality trends, not a local capture replacement.
- [Microsoft: browser logs and tracing](https://learn.microsoft.com/en-us/microsoftteams/browser-logs-and-tracing-for-teams).
- [Microsoft: resolve Teams sign-in errors](https://learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-sign-in/resolve-sign-in-errors).
- [Microsoft: Entra sign-in logs](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-ins).
- [Microsoft: call-health typical metrics](https://support.microsoft.com/en-us/teams/meetings/monitor-call-and-meeting-quality-in-microsoft-teams)
  and [CQD classification criteria](https://learn.microsoft.com/en-us/microsoftteams/stream-classification-in-call-quality-dashboard).
- [Microsoft: Windows performance counter guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-performance-problems-in-windows#memory).

Portal layout, permissions and telemetry availability can change; use the current service
guidance when investigating a particular tenant.
