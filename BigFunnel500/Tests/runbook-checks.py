"""The mechanical runbook checks. Every defect the 2026-09-16 audit found read
perfectly well as prose; all six came out of diffing rather than reading. Checks
5 and 6 were added later for the same reason, 6 after a sentence that named the
excluded parameters counted -TaskCredential twice and still scanned fine.
Re-run this before calling the runbook done.

Two things about how this file navigates, both of them measured failures of the
version before it:

  * It reads headings and links from DOC_PROSE, never DOC. The runbook is mostly
    worked examples, and a PowerShell comment inside a fenced block opens with
    the same character a heading does. 41 of the 129 "headings" the first version
    of check 4 counted were lines like `# -Scope Local and no -Databases`.
  * It navigates with anchor()/upto(), never str.index(). Twenty unguarded
    .index() calls meant that renaming one table header ended the run with a
    ValueError traceback - no PASS lines, no FAIL lines, and nothing naming the
    anchor that had moved. The five checks that would have passed went with it.
  * Its patterns match what the script is ALLOWED to contain, not what it happens
    to contain today. An untyped parameter and an `exit 7  # why` both existed
    nowhere when this was written, and both would have been read as absent rather
    than reported. A check that quietly stops seeing things is worse than one that
    was never written, because its PASS line still appears.
"""
import re, sys, pathlib

BASE = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = (BASE / 'Monitor-BigFunnelPostingList.ps1').read_text(encoding='utf-8-sig')
DOC = (BASE / 'BigFunnel PostingListTable Runbook.md').read_text(encoding='utf-8-sig')

FENCED = re.compile(r'^```.*?^```', re.MULTILINE | re.DOTALL)
DOC_PROSE = FENCED.sub('', DOC)

NUMBER_WORDS = {'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6,
                'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11,
                'twelve': 12}

fails = 0


class AnchorMissing(Exception):
    """A literal this file navigates by is no longer in the document."""


def anchor(text, needle, what):
    """Everything from `needle` onward, or a named failure for one check only."""
    i = text.find(needle)
    if i < 0:
        raise AnchorMissing('anchor moved in %s\n  looked for: %r\n'
                            '  the text it names has been renamed, reworded or '
                            'removed. Fix the anchor or the document.'
                            % (what, needle))
    return text[i:]


def upto(text, needle, what):
    """Everything before `needle`, or a named failure for one check only."""
    i = text.find(needle)
    if i < 0:
        raise AnchorMissing('end marker moved in %s\n  looked for: %r'
                            % (what, needle))
    return text[:i]


def report(name, ok, detail=''):
    global fails
    print(('PASS  ' if ok else 'FAIL  ') + name)
    if not ok:
        fails += 1
        for line in detail.splitlines():
            print('        ' + line)


def run(label, fn):
    """One check, its anchors contained. A check that cannot find its way around
    the document fails as itself; it does not take the other five with it."""
    try:
        results = fn()
    except AnchorMissing as e:
        report(label + '  [could not run]', False, str(e))
        return
    for name, ok, detail in results:
        report(name, ok, detail)


def param_triples(text):
    """(name, type, default) in declaration order, comments and attributes stripped.

    The type is OPTIONAL in the pattern and CAPTURED in the result, and those two
    changes only make sense together. Requiring it meant an untyped `$Foo` matched
    nothing at all, so a parameter declared without a type was invisible on both
    sides and the check passed by seeing neither of them. Making it optional
    without capturing it would trade that for a worse blind spot: a script's
    `[int]$Foo = 4` and a runbook that had dropped the `[int]` would both reduce
    to ('Foo', '4') and match. All 28 parameters are typed today and the types
    agree, so capturing it changes no verdict - it only removes somewhere to hide.
    """
    out = []
    for m in re.finditer(r'^\s*(\[[\w\.\[\]]+\])?\$(\w+)(\s*=\s*(.+?))?\s*,?\s*$',
                         text, re.MULTILINE):
        default = (m.group(4) or '').strip().rstrip(',').strip()
        out.append((m.group(2), (m.group(1) or '').strip(), default))
    return out


# 1. param (name, type, default) triples, both sides, in order.
def check_1():
    what = 'check 1, the parameter blocks'
    s_block = upto(anchor(SCRIPT, '\nparam(', what), '\n)\n', what)
    d_block = upto(anchor(DOC, '[CmdletBinding()]\nparam(', what), '\n)\n```', what)

    sp, dp = param_triples(s_block), param_triples(d_block)
    diff = []
    for i in range(max(len(sp), len(dp))):
        a = sp[i] if i < len(sp) else ('-', '-', '-')
        b = dp[i] if i < len(dp) else ('-', '-', '-')
        if a != b:
            diff.append('  %-2d script %-16s %-24s = %s' % (i, a[1], a[0], a[2]))
            diff.append('     doc    %-16s %-24s = %s' % (b[1], b[0], b[2]))
    return [('1. param (name, type, default) triples match, and in order  '
             '[script %d, doc %d]' % (len(sp), len(dp)), not diff, '\n'.join(diff))]


# 2. the $runStatus precedence chain vs the Status table and the worst-first sentence.
def check_2():
    what = 'check 2, the status precedence chain'
    chain_src = upto(anchor(SCRIPT, '$runStatus = $(', what), '\n\n', what)
    chain = re.findall(r"'(OK|PublishFailed|Partial|Alert|MetricUnavailable|"
                       r"Emerging|MetricInconclusive)'", chain_src)
    seen = set()
    chain = [c for c in chain if not (c in seen or seen.add(c))]

    tbl = upto(anchor(DOC, '| `Status` | Meaning |', what), '\n\n', what)
    doc_status = re.findall(r'^\| `(\w+)`', tbl, re.MULTILINE)
    doc_status = [s for s in doc_status if s != 'Status']   # the header row
    out = [('2a. every status in the chain is in the Status table, and vice versa',
            sorted(chain) == sorted(doc_status),
            'chain: %s\ndoc:   %s' % (sorted(chain), sorted(doc_status)))]

    sent = upto(anchor(DOC, 'Reported worst-first where more than one applies:', what),
                '.', what)          # the list ends at the first full stop
    out.append(('2b. the worst-first sentence lists them in the chain\'s own order',
                re.findall(r'`(\w+)`', sent) == chain,
                'sentence: %s\nchain:    %s' % (re.findall(r'`(\w+)`', sent), chain)))
    return out


# 3. every exit code the script can return vs the Code table. NOT anchored to
# the line start: $exitCode = 1 lives inside a one-line if, and an anchored
# pattern silently reports code 1 as unreachable.
def check_3():
    what = 'check 3, the exit-code table'
    codes = set(re.findall(r'\$exitCode\s*=\s*(\d+)', SCRIPT))
    # The trailing (?:#.*)? is what lets `exit 7  # policy refused the
    # registration` be seen at all. Anchored hard to end-of-line, a code whose
    # only unconditional site carried a trailing comment vanished from the
    # script side and the check failed the RUNBOOK for documenting it - a FAIL
    # pointing at the wrong file, over a comment. No such line exists today.
    codes |= set(re.findall(r'(?m)^\s*exit\s+(\d+)\s*(?:#.*)?$', SCRIPT))
    codes |= set(re.findall(r'(?m)^\s*return\s+(\d+)\s*(?:#.*)?$', SCRIPT))
    ctbl = upto(anchor(DOC, '| Code | Meaning | Alert |', what), '\n\n', what)
    doc_codes = set(re.findall(r'^\| `(\d+)`', ctbl, re.MULTILINE))
    return [('3. every exit code in the script is in the Code table, and vice versa',
             codes == doc_codes,
             'script: %s\ndoc:    %s' % (sorted(codes), sorted(doc_codes)))]


# 4. every in-page link resolves to a heading slug.
def check_4():
    # Slugs are built the way GitHub builds them, including the -1, -2 suffix it
    # appends to a heading whose text repeats. No heading repeats today; the day
    # one does, a checker without this rejects #step-2-1 as unresolvable, and a
    # false FAIL is the expensive direction for a check nobody expects to fire.
    slugs, seen = set(), {}
    for h in re.findall(r'^#{1,6} (.+)$', DOC_PROSE, re.MULTILINE):
        s = re.sub(r'[^\w\s-]', '', h.lower())
        s = re.sub(r'\s+', '-', s.strip())
        n = seen.get(s, 0)
        seen[s] = n + 1
        slugs.add(s if n == 0 else '%s-%d' % (s, n))
    links = re.findall(r'\]\(#([\w-]+)\)', DOC_PROSE)
    bad = sorted(set(l for l in links if l not in slugs))
    return [('4. every in-page link resolves  [%d links, %d headings]'
             % (len(links), len(slugs)), not bad, '\n'.join('  #' + b for b in bad))]


# 5. the event-ID table vs the two maps in the script. These IDs are a published
# contract - a Splunk alert is keyed to the number, so a silent renumber breaks a
# consumer that never reads this file. 1007 and 1099 are literals in the emit path
# rather than map entries, so they are added here by hand; this check exists to
# catch a map edit, and the two literals are covered by T56 in the suite.
def check_5():
    what = 'check 5, the event-ID table'

    def event_map(name):
        src = upto(anchor(SCRIPT, '$script:%s = @{' % name, what), '\n}', what)
        return {int(i): t for _, i, t in
                re.findall(r"'(\w+)'\s*=\s*@\{\s*Id\s*=\s*(\d+);\s*EntryType\s*=\s*'(\w+)'",
                           src)}

    s_events = event_map('RunEventMap')
    s_events.update(event_map('MailboxEventMap'))
    s_events[1007] = 'Error'      # aborted run, emitted by literal
    s_events[1099] = 'Warning'    # unmapped status on a completed run, ditto

    etbl = upto(anchor(DOC, '| Event ID | Raised when | Entry type |', what), '\n\n', what)
    d_events = {int(i): t for i, t in
                re.findall(r'^\| `(\d+)` \| .*? \| (\w+) \|$', etbl, re.MULTILINE)}
    ediff = ['  %-6s script %-12s doc %s' % (k, s_events.get(k, '-'), d_events.get(k, '-'))
             for k in sorted(set(s_events) | set(d_events))
             if s_events.get(k) != d_events.get(k)]
    return [('5. every event id and entry type matches the script  [script %d, doc %d]'
             % (len(s_events), len(d_events)), not ediff, '\n'.join(ediff))]


# 6. the task-registration exclusion list. Prose got this wrong once already, by
# double-counting -TaskCredential, which reads perfectly well either way.
def check_6():
    what = 'check 6, the task-argument exclusions'
    x_src = upto(anchor(SCRIPT, '    $exclude = @(\n', what), '\n    )', what)
    s_excl = re.findall(r"'(\w+)'", x_src)

    # Anchored on the part of the sentence WITHOUT the count in it. Anchoring on
    # "minus the eight parameters that..." meant the check could not survive a
    # ninth exclusion: the anchor would vanish and it would fail for the wrong
    # reason. The count is now checked rather than depended on - see 6b.
    sent6 = upto(anchor(DOC, 'parameters that cannot mean anything inside it:', what),
                 'The argument string is built', what)
    d_excl = re.findall(r'`-(\w+)`', sent6)
    out = [('6. the runbook names every excluded parameter, and only those  '
            '[script %d, doc %d]' % (len(s_excl), len(d_excl)),
            sorted(s_excl) == sorted(d_excl),
            'script: %s\ndoc:    %s' % (sorted(s_excl), sorted(d_excl)))]

    # 6b. The spelled-out number in that same sentence. A prose count of things is
    # a fact with nothing testing it, and this one has already been wrong once.
    m = re.search(r'minus the (\w+) parameters that cannot mean anything', DOC)
    word = m.group(1) if m else None
    out.append(('6b. the runbook\'s spelled-out count matches the list  '
                '[says %s, list has %d]' % (word or '?', len(s_excl)),
                NUMBER_WORDS.get((word or '').lower()) == len(s_excl),
                'the sentence says %r, which is %s; the script excludes %d'
                % (word, NUMBER_WORDS.get((word or '').lower()), len(s_excl))))
    return out


for label, fn in (('1. param (name, type, default) triples', check_1),
                  ('2. the status precedence chain', check_2),
                  ('3. the exit-code table', check_3),
                  ('4. in-page links', check_4),
                  ('5. the event-ID table', check_5),
                  ('6. the task-argument exclusions', check_6)):
    run(label, fn)

print()
print('CHECKS: %d failed' % fails)
sys.exit(1 if fails else 0)
