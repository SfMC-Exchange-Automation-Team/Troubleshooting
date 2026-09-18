# BigFunnel PostingListTable monitor - walkthrough transcript

Runtime 12:33. Generated 2026-09-17 from the v1.14.0 build of the storyboard.
Voice: `en-GB-RyanNeural` at -4%.

This is the narration, word for word, with the timestamp each line is spoken at.
It is generated from the same source the audio is synthesised from, so it cannot
drift from the video.

> **On versions.** Chapter 1 was re-cut against **v1.14.0** and every value it puts
> on screen - the SHA256, the line and byte counts - is measured against that
> script. Chapters 2-9 are **v1.11.0** captures and their banners say so. Nothing
> in them is false; the only visible difference on v1.14.0 is the completion line,
> which gained a per-phase breakdown. The narration names that split in the first
> minute rather than leaving you to find it. See
> [`../README.md`](../README.md) for what has landed since.

## Introduction

**[0:00]**  This is a walkthrough of the BigFunnel posting list table monitor, version one point fourteen point zero, on a live Exchange Server Subscription Edition database availability group. Subscription Edition and Exchange 2019 are code equivalent here, so everything in this walkthrough applies to both. What you are about to see is real output from two lab servers. The screens were captured on version one point eleven point zero, so that is the version their banners show; the only thing that looks different on fourteen is the completion line, which now also breaks the time down by phase. We will start it from an ordinary shell and watch it elevate itself, read the report it prints, watch it find something, see why it stays quiet on an estate too small to judge, and then schedule it - including the one mistake that makes a scheduled monitor look healthy while it has never run at all.

## 1. Verify the copy

**[0:54]**  This is the BigFunnel posting list table monitor, version one point fourteen point zero. It is a single read-only PowerShell script. Before you run it anywhere, verify the copy you were given.

**[1:08]**  Hash it. The script is not code-signed, so the hash is the only thing that tells you the file you have is the file that was tested. Check the line and byte counts too - they catch a copy that was truncated in transit, which a hash tells you about only after you already have the right one to compare against.

**[1:27]**  It calls three Exchange cmdlets, all of them read-only: Get-Exchange-Server, Get-Mailbox-Database, and Get-Mailbox-Statistics. It does not move a mailbox, fail over a database, or change a single Exchange setting. By default the only thing it writes is files under the output path you give it. Two switches add a destination outside that path - dash Emit To writes to the Application event log, and dash Register Scheduled Task creates a task - and neither happens unless you ask for it.

## 2. Starting it

**[2:02]**  Start it from an ordinary shell - not an elevated one - and it deals with that itself. It rebuilds its own command line from the parameters you passed, relaunches under Run As, and asks you to approve the prompt.

**[2:16]**  Here is the detail that matters. An elevated process cannot attach to the console of the one that launched it, so the relaunch gets a window of its own and Windows closes it the instant the run ends. Without help you would approve a prompt, watch a console flash past, and be left with a pointer to a log file. Instead the child writes each line to a relay file as it prints it, and the parent replays it here.

**[2:42]**  The whole report arrives, colours and all, in the window you were already looking at. One critical and one warning, each named, on its database, with its size. It is written line by line rather than buffered, so a child that dies halfway still relays what it managed to say.

**[3:01]**  And then it exits with the child's code, not its own. Note what that code is. Zero - on a run that just found a critical mailbox. Codes one, five and six are gated behind dash Exit Non Zero On Alert, so that adding this monitor to an existing scheduler cannot start failing tasks on day one. Rather than leave that contradiction on screen, the report says so on the line underneath.

## 3. The first run

**[3:31]**  Now a first run on a DAG member, from a shell that is already elevated, so there is no prompt. Scope Local discovers the databases whose active copy is mounted on this node. You do not need dash Verbose: since version one point eight the report is printed every run, and Verbose only adds the individual rows the terse report leaves out.

**[3:53]**  It opens its own Exchange runspace. That is what makes it schedulable - it does not need to be launched from the Exchange Management Shell. Two databases here, fifty mailboxes between them, and it names each one with its count rather than making you read that back out of a log.

**[4:11]**  Result OK, in four point eight seconds. Nothing critical, nothing warning, nothing emerging, no database failed. And the line under the counts is the one to read first: Counter, Confirmed. That says the script proved to itself that the metric it depends on is actually being populated on this estate.

**[4:33]**  Then the honest first-run message. There is no previous run to compare against, so there are no rates and no projected dates. That is not an error. And notice the last line: two counters are in use. Three mailboxes are dated on the posting list table itself; the other twenty are ranked only, on index payload bytes, because the thresholds do not apply to that counter.

## 4. What a run leaves

**[5:01]**  A run leaves four files. A timestamped C S V and log for history, latest dot C S V for whatever you point a report at, and latest dash summary dot JSON, which is the one you wire into monitoring.

**[5:16]**  The C S V is where the per-mailbox detail lives. Filter it to the rows that carry a projected date, sort by that date, and you have your work queue in the order it needs doing. Note the trend metric column - it tells you which counter each row was ranked on.

**[5:33]**  Here is the summary file, trimmed to the fields a consumer branches on. Status, the counter validation, the counts, whether the run was elevated, and the exit code. Alert on Status not in OK or Metric Inconclusive, and read the counts beside it for what was found.

**[5:52]**  And when the monitor names a mailbox, this is where you end up: the mailbox itself. Two point seven gigabytes of content, and a posting list table of seven hundred and twenty-one megabytes. That is the figure the whole script is built around, read straight from Get-Mailbox-Statistics.

## 5. When it finds something

**[6:13]**  The defaults of one point seven and two gigabytes are a recommended starting point, not a law. After a fortnight you tune them to what your estate actually looks like. On this lab the largest mailboxes sit around seven hundred megabytes, so here the thresholds are set to match - and this time with dash Exit Non Zero On Alert.

**[6:34]**  Result Alert. One critical, one warning, ranked worst first, and each one carrying its own growth rate on the same line as the finding. Bfseed03 is over the line and gaining a sixth of a gigabyte a day. Bfseed01 is over the warning line and not growing at all. Those are two different pieces of work, and you can tell them apart without opening anything.

**[7:00]**  Now raise the thresholds slightly, so nothing is over the line today. The same mailbox comes back as Emerging: still normal, still under warning, but projected to cross critical in two days. The exit code is six. One means work today; six means work before the weekend, and a run cannot return both.

**[7:22]**  Route the codes by meaning. One and six are findings about mailboxes - send those to whoever owns the estate. Two, three, four and five are operational: the monitor itself had a problem, and that is a different queue. Status is ordered the same way as the exit codes, so the two never disagree about which condition a run is reporting.

## 6. On another DAG member

**[7:48]**  The same command, unchanged, on a different DAG member. This one has a single mounted database and five mailboxes, and none of them is large.

**[7:59]**  Nothing in scope has ever allocated a posting list table, so there is no posting list data to rank on at all. It falls back to index payload bytes and says exactly what that costs you: the ranking is real, but no projected dates are given, because the thresholds do not apply to that counter.

**[8:18]**  And here is the reasoning in full, printed rather than buried in a log. Two mailboxes read zero bytes, and both are below the bar at which this build would allocate a table at all - so zero is the correct reading, not a fault. But read the second half. No threshold in this run was tested, because nothing in scope is large enough to show whether the counter works.

**[8:42]**  So it reports Metric Inconclusive, the counter reads Inconclusive, and it exits zero. A small estate does not get a false alarm. Inconclusive means it could not prove the counter works either way - which is a different thing from proving it is broken. That second case is Metric Unavailable, exit five, and that one you do alert on.

## 7. Scheduling it

**[9:07]**  Now the part that catches people out. Scheduling it. Here is the registration, and it looks completely ordinary.

**[9:17]**  It registers. No error. No warning. Nothing at all tells you anything is wrong.

**[9:26]**  Start it, wait, and look at what the scheduler reports. Logon type Interactive. A last run time of November the thirtieth, nineteen ninety-nine - which is the never-ran sentinel. And task result two six seven zero one one, which is scheduler-speak for has not run.

**[9:45]**  It never ran. And the output directory proves it - no log, no C S V, no summary file. Every single place you would normally look for a fault is simply empty. This is the worst kind of failure: a monitor you believe is running, that has never run once. The cause is one missing parameter. With dash User and no dash Password, the task gets logon type Interactive, which means run only when this user is logged on. A service account never is.

## 8. The correct registration

**[10:21]**  The fix is to supply the password. Prompt for it rather than writing it into the script, so it reaches neither source control nor your shell history. A group managed service account will not work here either - it has no outbound network credential to give the task.

**[10:38]**  Never trust the registration. Verify it. Logon type now reads Password, there is a real last run time, and the task result is zero.

**[10:50]**  And this time the output directory has something in it. Four files, the same four a run by hand produces, with a real timestamp on them.

**[10:59]**  Three commands prove it took, and they are worth keeping as a checklist. Logon type reads Password. The scheduler's last result is zero. And the summary file agrees with the scheduler - same version, completed true, status OK, exit code zero. If the file says one thing and the scheduler says another, something in your chain is using dash Command instead of dash File.

## 9. A first fortnight

**[11:28]**  To put this into production. Day zero: verify the hash, copy it to one DAG member, run it by hand. Day one: run it again twenty-four hours later, and you have your first rates. Day two: register the task on every member, with dash File, dash Password, and dash Exit Non Zero On Alert.

**[11:51]**  Day three: wire latest dash summary dot JSON into your monitoring. Alert on Status, and route one and six apart from two, three, four and five. And at week two, review the rates and tune the warning and critical thresholds to your own data.

**[12:09]**  And the one thing to take away from all of this: dash Password is not optional, and a task that says Ready is not a task that runs. Verify the logon type on every member you register.

## Close

**[12:22]**  That is the walkthrough. Verify the hash, run it by hand twice, schedule it with a password on every member, and alert on Status and the exit code together.
