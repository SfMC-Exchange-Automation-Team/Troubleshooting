"""The mechanical runbook checks. Every defect the 2026-09-16 audit found read
perfectly well as prose; all six came out of diffing rather than reading. Checks
5 and 6 were added later for the same reason, 6 after a sentence that named the
excluded parameters counted -TaskCredential twice and still scanned fine.
Re-run this before calling the runbook done."""
import re, sys, pathlib

BASE = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = (BASE / 'Monitor-BigFunnelPostingList.ps1').read_text(encoding='utf-8-sig')
DOC = (BASE / 'BigFunnel PostingListTable Runbook.md').read_text(encoding='utf-8-sig')

fails = 0


def report(name, ok, detail=''):
    global fails
    print(('PASS  ' if ok else 'FAIL  ') + name)
    if not ok:
        fails += 1
        for line in detail.splitlines():
            print('        ' + line)


def param_pairs(text):
    """(name, default) in declaration order, comments and attributes stripped."""
    out = []
    for m in re.finditer(r'^\s*\[[\w\.\[\]]+\]\$(\w+)(\s*=\s*(.+?))?\s*,?\s*$',
                         text, re.MULTILINE):
        default = (m.group(3) or '').strip().rstrip(',').strip()
        out.append((m.group(1), default))
    return out


# 1. param (name, default) pairs, both sides, in order.
s_block = SCRIPT[SCRIPT.index('\nparam('):]
s_block = s_block[:s_block.index('\n)\n')]
d_block = DOC[DOC.index('[CmdletBinding()]\nparam('):]
d_block = d_block[:d_block.index('\n)\n```')]

sp, dp = param_pairs(s_block), param_pairs(d_block)
diff = []
for i in range(max(len(sp), len(dp))):
    a = sp[i] if i < len(sp) else ('-', '-')
    b = dp[i] if i < len(dp) else ('-', '-')
    if a != b:
        diff.append('  %-2d script %-24s = %-55s' % (i, a[0], a[1]))
        diff.append('     doc    %-24s = %-55s' % (b[0], b[1]))
report('1. param (name, default) pairs match in name, default and order  '
       '[script %d, doc %d]' % (len(sp), len(dp)), not diff, '\n'.join(diff))

# 2. the $runStatus precedence chain vs the Status table and the worst-first sentence.
chain_src = SCRIPT[SCRIPT.index('$runStatus = $('):]
chain_src = chain_src[:chain_src.index('\n\n')]
chain = re.findall(r"'(OK|PublishFailed|Partial|Alert|MetricUnavailable|"
                   r"Emerging|MetricInconclusive)'", chain_src)
seen = set()
chain = [c for c in chain if not (c in seen or seen.add(c))]

tbl = DOC[DOC.index('| `Status` | Meaning |'):]
tbl = tbl[:tbl.index('\n\n')]
doc_status = re.findall(r'^\| `(\w+)`', tbl, re.MULTILINE)
doc_status = [s for s in doc_status if s != 'Status']   # the header row
report('2a. every status in the chain is in the Status table, and vice versa',
       sorted(chain) == sorted(doc_status),
       'chain: %s\ndoc:   %s' % (sorted(chain), sorted(doc_status)))

sent = DOC[DOC.index('Reported worst-first where more than one applies:'):]
sent = sent[:sent.index('.')]            # the list ends at the first full stop
report('2b. the worst-first sentence lists them in the chain\'s own order',
       re.findall(r'`(\w+)`', sent) == chain,
       'sentence: %s\nchain:    %s' % (re.findall(r'`(\w+)`', sent), chain))

# 3. every exit code the script can return vs the Code table. NOT anchored to
# the line start: $exitCode = 1 lives inside a one-line if, and an anchored
# pattern silently reports code 1 as unreachable.
codes = set(re.findall(r'\$exitCode\s*=\s*(\d+)', SCRIPT))
codes |= set(re.findall(r'(?m)^\s*exit\s+(\d+)\s*$', SCRIPT))
codes |= set(re.findall(r'(?m)^\s*return\s+(\d+)\s*$', SCRIPT))
ctbl = DOC[DOC.index('| Code | Meaning | Alert |'):]
ctbl = ctbl[:ctbl.index('\n\n')]
doc_codes = set(re.findall(r'^\| `(\d+)`', ctbl, re.MULTILINE))
report('3. every exit code in the script is in the Code table, and vice versa',
       codes == doc_codes,
       'script: %s\ndoc:    %s' % (sorted(codes), sorted(doc_codes)))

# 4. every in-page link resolves to a heading slug.
slugs = set()
for h in re.findall(r'^#{1,6} (.+)$', DOC, re.MULTILINE):
    s = h.lower()
    s = re.sub(r'[^\w\s-]', '', s)
    slugs.add(re.sub(r'\s+', '-', s.strip()))
links = re.findall(r'\]\(#([\w-]+)\)', DOC)
bad = sorted(set(l for l in links if l not in slugs))
report('4. every in-page link resolves  [%d links, %d headings]'
       % (len(links), len(slugs)), not bad, '\n'.join('  #' + b for b in bad))

# 5. the event-ID table vs the two maps in the script. These IDs are a published
# contract - a Splunk alert is keyed to the number, so a silent renumber breaks a
# consumer that never reads this file. 1007 and 1099 are literals in the emit path
# rather than map entries, so they are added here by hand; this check exists to
# catch a map edit, and the two literals are covered by T56 in the suite.
def event_map(name):
    src = SCRIPT[SCRIPT.index('$script:%s = @{' % name):]
    src = src[:src.index('\n}')]
    return {int(i): t for _, i, t in
            re.findall(r"'(\w+)'\s*=\s*@\{\s*Id\s*=\s*(\d+);\s*EntryType\s*=\s*'(\w+)'",
                       src)}


s_events = event_map('RunEventMap')
s_events.update(event_map('MailboxEventMap'))
s_events[1007] = 'Error'      # aborted run, emitted by literal
s_events[1099] = 'Warning'    # unmapped status on a completed run, ditto

etbl = DOC[DOC.index('| Event ID | Raised when | Entry type |'):]
etbl = etbl[:etbl.index('\n\n')]
d_events = {int(i): t for i, t in
            re.findall(r'^\| `(\d+)` \| .*? \| (\w+) \|$', etbl, re.MULTILINE)}
ediff = ['  %-6s script %-12s doc %s' % (k, s_events.get(k, '-'), d_events.get(k, '-'))
         for k in sorted(set(s_events) | set(d_events))
         if s_events.get(k) != d_events.get(k)]
report('5. every event id and entry type matches the script  [script %d, doc %d]'
       % (len(s_events), len(d_events)), not ediff, '\n'.join(ediff))

# 6. the task-registration exclusion list. Prose got this wrong once already, by
# double-counting -TaskCredential, which reads perfectly well either way.
x_src = SCRIPT[SCRIPT.index('    $exclude = @(\n'):]
x_src = x_src[:x_src.index('\n    )')]
s_excl = re.findall(r"'(\w+)'", x_src)
sent6 = DOC[DOC.index('minus the eight parameters that cannot mean anything inside it:'):]
sent6 = sent6[:sent6.index('The argument string is built')]
d_excl = re.findall(r'`-(\w+)`', sent6)
report('6. the runbook names every excluded parameter, and only those  '
       '[script %d, doc %d]' % (len(s_excl), len(d_excl)),
       sorted(s_excl) == sorted(d_excl),
       'script: %s\ndoc:    %s' % (sorted(s_excl), sorted(d_excl)))

print()
print('CHECKS: %d failed' % fails)
sys.exit(1 if fails else 0)
