# Tests

**Nothing in here is for troubleshooting a customer tenant.** These verify the tool itself. If you
came here to look at a queue, the script you want is [`../Get-ExoQueue.ps1`](../Get-ExoQueue.ps1).

They live in a subfolder so the tool folder shows what an operator actually runs. They are kept in
the repo, rather than left in a private workspace, because the tool makes specific claims about its
own correctness and these are what back them up.

| File | What it does |
|---|---|
| `Get-ExoQueue.Tests.ps1` | 160 Pester tests. Stubs `Get-MessageTraceV2`; connects to nothing. |
| `Test-ExoQueuePagingFidelity.ps1` | Drives the paging loop against a simulated service whose contents are known, and checks the retrieved set against them. |

## Running them

```powershell
# Needs Pester 6. Windows PowerShell 5.1 ships Pester 3.4.0, which will NOT work -
# -MinimumVersion silently matches nothing and you get a cascade of unrelated errors.
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force

Invoke-Pester -Path .\Get-ExoQueue.Tests.ps1 -Output Detailed
```

```powershell
.\Test-ExoQueuePagingFidelity.ps1
```

## Reading the paging probe's output

It prints `MISSING n message(s)` in several scenarios, **and that is usually the point.** Most of
those scenarios deliberately simulate a service that misbehaves — one that caps `ResultSize` below
what was asked, or a burst of messages sharing a single timestamp that cannot be paged through at
all. What is being checked is not that nothing is ever missed; it is that when something *is* missed,
the tool says so, by setting `Truncated` rather than reporting a short count as complete.

So read the `trunc` column, not the `MISSING` lines. `trunc True` against a missing set is the
correct result. A missing set with `trunc False` would be the defect — that is precisely the 1.4.2
behaviour this tool was rebuilt to eliminate.

There is no single pass/fail line and the script exits 0 regardless, which is why it sits in here
rather than somewhere an operator might run it by accident and conclude the tool is broken.

## Why the old versions are still around

[`../archive/`](../archive/) holds 1.4.2 along with tests that assert its *buggy* behaviour. That is
deliberate: "1.4.2 under-reports on a queue deeper than one page" is a claim, whereas a test that
fails against 1.4.2 and passes against the current version is a measurement.
