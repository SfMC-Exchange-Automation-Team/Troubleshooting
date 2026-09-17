# Archive

The previously published version of `Get-ExoQueue`, kept for reference.

**Do not run it against a customer tenant.** It under-reports, and it does not say so while it
happens — which is the reason it is in here rather than one folder up.

| File | |
|---|---|
| `Get-ExoQueue_v1.4.2.ps1 - ISSUE WITH GET-MESSAGETRACEV2 - RESULTS ARE CAPPED` | The version this folder shipped until Sept 2026. |

The filename is the team's own warning label and has been left exactly as it was. It also has no
`.ps1` extension, so PowerShell will not dot-source or execute it by accident — worth preserving,
and a good reason not to "tidy" the name.

## What it got wrong

**The paging loop stops after one page.** A queue deeper than `-ResultSize` is reported at whatever
the first page happened to return, and the run then reports itself as complete. There is no warning,
no `Truncated` flag, nothing on screen to suggest the number is a floor rather than the depth.

This is why it survived into production: on any tenant whose queue fits inside one page — every test
tenant — the output is correct. The failure only appears at the moment the tool matters most, during
a real backlog, and it fails by quietly understating it.

Three further defects rode along with it:

- **Journal filtering was inverted.** `-JournalOnly` and `-JournalExclude` filtered on the *sender*,
  so `-JournalOnly` matched only mail the journal mailbox had itself sent — in practice, almost
  nothing.
- **Multi-recipient messages lost every recipient but one** on export.
- **The time basis differed between page 1 and later pages**, so west of UTC the window moved the
  wrong way.

A related defect was found later, against a live tenant, and is worth knowing about because it
affects any tool built on `Get-MessageTraceV2`: **the service floors `EndDate` to whole seconds**, so
a paging cursor seeded with a row's own sub-second `Received` silently skips every row inside that
second. Fixed in 1.6.4.

## Use this instead

[`../Get-ExoQueue.ps1`](../Get-ExoQueue.ps1) — currently 1.6.6, with 158 offline tests.

Every defect listed above has a regression test in `Get-ExoQueue.Tests.ps1`, and the full history
is in the comment block at the end of the script.
