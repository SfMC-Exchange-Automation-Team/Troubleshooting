"""Proof that runbook-checks.py fails the way it claims to.

A check that has never been watched catch anything is not a safety net, it is a
line in a PR body. This builds a throwaway copy of the three files per case,
breaks exactly one thing, and asserts on what the checker prints.

The cases are the failure modes the hardening pass was for. Three of them were
real weaknesses in the version before it:

  * A moved anchor used to end the run with a ValueError traceback, taking the
    five checks that would have passed with it. Now it fails as itself, by name.
  * Headings were harvested from the whole document, so a PowerShell comment
    inside a fenced block became a heading slug - 41 of the 129 it counted. A
    link to one of those resolved happily. Now it does not.
  * The spelled-out count in the exclusion sentence was an anchor rather than a
    fact under test, so it could only ever be wrong silently.

Read-only against the repo, writes only to a temp directory, needs no Exchange,
no elevation and no network.

    python Tests\\runbook-checks-selftest.py
"""
import shutil, subprocess, sys, tempfile, pathlib

BASE = pathlib.Path(__file__).resolve().parent.parent
MON = 'Monitor-BigFunnelPostingList.ps1'
RB = 'BigFunnel PostingListTable Runbook.md'
CHK = 'runbook-checks.py'

results = []


def run_case(name, mutate_doc=None, mutate_script=None,
             want_exit=1, want_in='', want_not_in='', want_pass_count=None):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix='rbcheck-'))
    try:
        (tmp / 'Tests').mkdir()
        doc = (BASE / RB).read_text(encoding='utf-8-sig')
        scr = (BASE / MON).read_text(encoding='utf-8-sig')
        if mutate_doc:
            doc = mutate_doc(doc)
        if mutate_script:
            scr = mutate_script(scr)
        (tmp / RB).write_text(doc, encoding='utf-8')
        (tmp / MON).write_text(scr, encoding='utf-8')
        shutil.copy2(BASE / 'Tests' / CHK, tmp / 'Tests' / CHK)

        p = subprocess.run([sys.executable, str(tmp / 'Tests' / CHK)],
                           capture_output=True, text=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    out = p.stdout + p.stderr
    ok, why = True, []
    if p.returncode != want_exit:
        ok = False
        why.append('exit %d, wanted %d' % (p.returncode, want_exit))
    if want_in and want_in not in out:
        ok = False
        why.append('missing from output: %r' % want_in)
    if want_not_in and want_not_in in out:
        ok = False
        why.append('should NOT be in output: %r' % want_not_in)
    if want_pass_count is not None and out.count('PASS  ') != want_pass_count:
        ok = False
        why.append('%d PASS lines, wanted %d' % (out.count('PASS  '), want_pass_count))
    if 'Traceback' in out:
        ok = False
        why.append('the checker CRASHED instead of reporting')

    results.append((name, ok, '; '.join(why), out))


# The baseline. If this one fails, nothing below it means anything.
run_case('unmutated tree still passes all 8', want_exit=0, want_pass_count=8,
         want_in='CHECKS: 0 failed')

# A moved anchor fails as itself and leaves the other checks running. Three
# cases: two anchors in the document, one in the script.
run_case('renamed Code table header: check 3 fails BY NAME, the other 7 still run',
         mutate_doc=lambda d: d.replace('| Code | Meaning | Alert |',
                                        '| Code | What it means | Alert |', 1),
         want_in='FAIL  3. the exit-code table  [could not run]',
         want_pass_count=7)

run_case('renamed Status table header: check 2 fails, check 3 still PASSES',
         mutate_doc=lambda d: d.replace('| `Status` | Meaning |',
                                        '| `Status` | What it means |', 1),
         want_in='FAIL  2. the status precedence chain  [could not run]',
         want_pass_count=6)          # 2a and 2b both lost, the other six survive

run_case('renamed a map in the SCRIPT: check 5 fails, the doc checks survive',
         mutate_script=lambda s: s.replace('$script:RunEventMap = @{',
                                           '$script:RunEventMapping = @{', 1),
         want_in='FAIL  5. the event-ID table  [could not run]',
         want_pass_count=7)

# The spelled-out count is under test rather than trusted. It must FAIL, not
# crash - crashing was the old behaviour and it loses the other checks.
run_case('count drifts to "nine" while the list stays at 8: 6b catches it',
         mutate_doc=lambda d: d.replace('minus the eight parameters',
                                        'minus the nine parameters', 1),
         want_in='FAIL  6b.', want_not_in='could not run', want_pass_count=7)

# #control-nor-shell-history was a genuine slug before the fix, harvested from a
# PowerShell comment inside a fenced block. A link to it passed.
run_case('link to a slug that exists only inside a code fence now FAILS',
         mutate_doc=lambda d: d.replace(
             '## Related articles',
             'See [this](#control-nor-shell-history).\n\n## Related articles', 1),
         want_in='#control-nor-shell-history', want_pass_count=7)

# GitHub appends -1 to a repeated heading. Rejecting that link would be a false
# FAIL, which is the expensive direction for a check nobody expects to fire.
run_case('duplicate heading: a link to the -1 slug resolves',
         mutate_doc=lambda d: d.replace(
             '## Related articles',
             '### Symptoms\n\nA second one.\n\nSee [it](#symptoms-1).\n\n'
             '## Related articles', 1),
         want_exit=0, want_pass_count=8)

# And the inverse, so the two cases above cannot have been bought with blanket
# permissiveness: a link to nothing must still fail.
run_case('a link to nothing at all still FAILS',
         mutate_doc=lambda d: d.replace(
             '## Related articles',
             'See [that](#no-such-heading-anywhere).\n\n## Related articles', 1),
         want_in='#no-such-heading-anywhere', want_pass_count=7)

print()
bad = 0
for name, ok, why, out in results:
    print(('PASS  ' if ok else 'FAIL  ') + name)
    if not ok:
        bad += 1
        print('        ' + why)
        for line in out.splitlines():
            print('        | ' + line)
print()
print('PROOFS: %d failed' % bad)
sys.exit(1 if bad else 0)
