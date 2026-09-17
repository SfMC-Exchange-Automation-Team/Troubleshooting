# Get-ExoQueue - how-to video transcript

Runtime 6:55. Generated 2026-09-17. Screenshots are real runs against the CDX lab tenant.

## 1. Get-ExoQueue

*How to use it - for CSAs and customers*

This is a practical walkthrough of Get-ExoQueue. Everything you are about to see is a real run against a real tenant, not a mock-up.
One thing to be clear about before we start. Exchange Online does not expose a transport queue. There is no queue object to read, so this tool approximates one from message trace data. That approximation is genuinely useful, but please repeat that caveat to customers, because a message trace row is not a queue entry.

## 2. Step 1 - load the tool

*It defines a function; running the file does nothing*

```powershell
# Dot-source it. Note the leading dot and the space.
. .\Get-ExoQueue.ps1

# Running it instead does NOT load the function:
.\Get-ExoQueue.ps1          # <- wrong
```

Step one, load the tool. Get-ExoQueue is a function in a script file, so you have to dot-source it. That is a dot, then a space, then the path.
If you run the file normally instead, the function is defined inside a scope that is thrown away the moment the file finishes, so nothing is loaded and nothing appears to happen. The script notices when you have done that and tells you, which saves a confusing few minutes.

## 3. Step 2 - connect to Exchange Online

*Connect first, or let it offer*

```powershell
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

# Get-ExoQueue checks the connection and offers to connect
# if you have not. Under -Quiet or in a scheduled task,
# connect first - it cannot show you a prompt.
```

Step two, connect to Exchange Online. You need the Exchange Online Management module, and a role that can read message trace. View-Only Recipients is enough.
If you are already connected, the tool just uses that session. If you are not, it offers to connect for you. The exception is an unattended run. Under quiet mode the tool cannot show you a prompt, so connect first and pass the force switch, or it will stop waiting for an answer you will never see.

## 4. Step 3 - your first run

*Real output, CDX lab tenant*

Screenshot: `01-first-run.png`

Step three, run it. Here is a real run against a lab tenant, asking for the last seventy two hours.
Notice the status filter. Get me into the habit early, because it is the single most common source of confusion with this tool: the status parameter defaults to Pending on its own. A tenant full of failed or delivered mail will report zero, correctly, and that looks exactly like an empty queue when it is not. Naming the statuses you want removes all of that doubt.

## 5. Step 4 - reading the output

*Four numbers, and what each one means*

Screenshot: `01-first-run.png`

Step four, reading what came back. There are four things on this screen worth knowing.
The first is the count. Fifty two messages, and in brackets, one hundred and fifty four recipient deliveries. Those are different questions. One message to a distribution list is one message but many deliveries, so conflating them makes a queue look far worse than it is. Quote the message count as the queue depth.
The second is queue age. This matters as much as the depth. A hundred thousand messages thirty seconds old is a burst that will clear itself. The same hundred thousand six hours old is an outage. The count on its own cannot tell you which.
The third is the destination breakdown. Exchange Online has no real next hop domain, so the recipient domain stands in for it. When one destination is deferring, its domain climbs to the top of that list. The heading tells you how many domains there are in total, so you know whether you are looking at all of them.
And at the bottom, every file the run wrote, collected in one place.

## 6. Step 5 - the one check that matters

*Never quote a number without it*

Screenshot: `03-truncated.png`

Step five, and if you remember one thing from this video, make it this one.
This is the same tenant and the same time window as before, but with the paging limits turned down. It reports seventeen messages. The true answer is fifty two. The number is not wrong, exactly - it is a floor. The run stopped before it reached the end of the data.
What makes that safe is the warning. The run says, in plain language, that the results are incomplete and that the count above is a floor rather than the queue depth. The older version of this tool did not do that. It stopped after one page, reported whatever it had, and called itself complete, which is how an under-reported number reaches a customer.
So before you quote a queue depth to anybody, look for that warning.

## 7. Step 6 - check it in a script

*Truncated is a property, not just a message*

Screenshot: `04-passthru.png`

Step six. If you are collecting this on a schedule rather than watching it, you do not want to read warnings off a screen. Pass the pass-through switch and you get an object back.
Check the truncated property before you trust the message count. If it is true, truncation reason tells you which limit you hit, so you know whether to widen the page limit or narrow the time range. This is the right way to build a trend: gate on truncated, and only record counts from runs that finished.

## 8. Step 7 - when it reports zero

*A filter result is not an empty tenant*

Screenshot: `02-empty-result.png`

Step seven, the zero case, because it will happen to you.
A bare run here reports zero messages. That is correct, and it is also almost certainly not what the person asking wanted to know. The tool now explains itself: it names the status filter it actually used, and points out that the default is Pending alone.
This is worth knowing for lab work especially. Nothing in a test lab is ever genuinely pending, because Exchange treats an unroutable destination as a permanent failure rather than a temporary one. So synthetic test mail lands as failed, and a bare run will honestly report a queue of zero. Add failed to the status list and it appears.

## 9. Step 8 - export it for a case

*CSV, XML, or straight to a grid*

Screenshot: `05-csv-export.png`

Step eight, getting the data out. Ask for CSV output and you get three files: the full result set, the top senders, and the top recipients. XML works the same way if you would rather reload the objects later.
Every file the run produced is listed together at the end, so you are not hunting through scrollback for a path. Use the output path parameter to put them somewhere sensible, like a case folder.

## 10. Journal mail

*Often the largest single distortion*

```powershell
# Size the journal backlog on its own
Get-ExoQueue -AgeHours 6 -JournalOnly

# Everything except journal mail
Get-ExoQueue -AgeHours 6 -JournalExclude
```

One more thing worth knowing about, particularly in regulated tenants. Journaling copies every message to an archive address, which can roughly double the delivery count and make a queue look far worse than it is.
There are two switches for this. Journal-only sizes the journal backlog on its own. Journal-exclude gives you everything else. The journal address is discovered from the tenant's own journal rules, so you do not need to know it in advance.

## 11. What it cannot do

*Worth saying out loud before a customer asks*

Now the limits, because a confident walkthrough that skipped these would do more harm than good.
On premises you can suspend a queue, resume it, force a retry, remove messages, or export them. None of that exists here. Exchange Online exposes no queue control plane whatsoever, so this tool reads and reports, and that is all it can ever do.
It only sees outbound flow. Message trace is not real time, so very recent mail may not have landed yet. And it remains an approximation built from trace data, which is why every single run prints that disclaimer.

## 12. Recap

*Four habits worth forming*

To recap. Dot-source the file, because running it does nothing. Always pass the status parameter explicitly, so a zero means what you think it means. Check truncated before you quote any number to anybody. And read the queue age alongside the depth, because the two together tell you whether you are looking at a burst or an outage.
The current version lives in the team troubleshooting repository, under Get-ExoQueue. Thanks for watching.

