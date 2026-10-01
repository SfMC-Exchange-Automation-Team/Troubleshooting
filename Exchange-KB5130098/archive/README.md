# Archive — historical Korean Rules material

**For current usage, return to the [operator guide](../README.md).**
Do not choose an old release merely because it appears here.

The active tool folder now presents only the three current operator scripts.
This archive keeps prior material available without mixing it into the normal
download and documentation folders. No old release ZIP, checksum, recording,
caption, transcript or poster was deleted or changed during this move.

## Current files (outside this archive)

- [Install-KoreanRules.ps1](../Install-KoreanRules.ps1) — verify/prepare adjacent payload; portable runtime/ZIP only with explicit output.
- [Get-KoreanRulesState.ps1](../Get-KoreanRulesState.ps1) — inspect servers.
- [Set-KoreanRulesState.ps1](../Set-KoreanRulesState.ps1) — change eligible servers.
- [Latest 2.3.1 complete public kit](../downloads/Exchange-KoreanRules-2.3.1.zip)
  and [checksum](../downloads/Exchange-KoreanRules-2.3.1.zip.sha256).
- [Current 2.3.1 English, Hindi and Tamil walkthroughs](../docs/Walkthroughs.md).

The current release is **2.3.1**. Public inclusion of both exact, pinned Microsoft
BINs was explicitly approved. The public ZIP contains the complete runtime, docs,
tests, archived compatibility wrappers and payload: token **56,132 bytes** and
complex **717,792 bytes**. No SQL EXE, MSI or DLL is included.
The repository payload allowlist tracks only `payload\ko.token.rule.bin` and
`payload\ko.complex.rule.bin`; unrelated payload files remain ignored.
The release root retains exactly three operator scripts.

No SQL media preparation or Install run is needed. Get needs no payload; Set
automatically uses adjacent `payload` and keeps its own checks.
Optional bare Install verifies adjacent payload read-only, with no download,
admin requirement, writes, directories or prompts. Only a historical/custom
source-only kit with no payload shows help instead. Invalid or partial adjacent
payload fails verification with no fallback. Default preparation writes only
adjacent `payload`: no second kit/ZIP/default `KoreanRules-Ready` directory or
empty work directory for BIN input. `Package`/`SHA256` are null,
`ExpandedPackage` is the current invoked kit, and `PayloadDirectory` equals the
adjacent `DefaultPayloadDirectory`.

Explicit `-OutputDirectory` (second positional argument) requests a portable
expanded kit plus ZIP and refuses existing folders. With no source/download
arguments it uses bundled payload. Portable return values are preserved;
`DefaultPayloadDirectory` still names the original adjacent payload.
If bundled payload is absent, explicit output fails with an error, not silent
help or an automatic download; supply a verified source or explicitly choose
`-Download`.
Explicit `-Download` is a fallback for fresh media extraction or missing payload,
not a public-kit prerequisite. It downloads/extracts once locally, never installs SQL;
existing EXE extraction is supported. Only media uses unique `WorkRoot`
directories for collision-safe extraction/logs. They are retained intentionally;
old user directories are never automatically deleted.

Follow the [trust/MOTW procedure](../README.md#trust-mark-of-the-web-and-extraction)
before running a downloaded kit: verify the approved source/checksum, unblock
the exact ZIP before fresh unique extraction, or review then manually unblock
only the dedicated extracted kit's scripts/modules/manifests including `private`.
Unblocking a ZIP afterward does not clear existing extracted ADS. There is no
self-unblock or policy bypass; UAC, publisher trust, AllSigned, GPO and WDAC
remain distinct. `Get-ExecutionPolicy -List` is read-only, and unblocking does
not guarantee that all prompts disappear.

## Archived downloads

The [downloads folder](downloads) contains these superseded source kits, each
with its original SHA256 sidecar:

| Versions | Original product naming |
|---|---|
| 1.0.1, 1.0.2 | Exchange-KB5130098 |
| 1.1.0, 1.1.1, 1.1.2 | Exchange-KB5130098 |
| 1.2.0, 1.2.1, 1.2.2, 1.2.3 | Exchange-KB5130098 |
| 2.0.0, 2.0.1, 2.1.0 | Exchange-KoreanRules |
| 2.2.0, 2.2.1, 2.3.0 | Exchange-KoreanRules |

Archives are immutable snapshots: their internal layouts and instructions
reflect those versions. They are not instructions for the current release.
The 2.1.0 source ZIP and sidecar are also preserved unchanged here; its historical
compatibility wrappers still occupy their original locations inside that ZIP.
The superseded [2.2.1 source kit](downloads/Exchange-KoreanRules-2.2.1-source.zip)
and its checksum are archived here. The superseded
[2.3.0 source kit](downloads/Exchange-KoreanRules-2.3.0-source.zip) and
[checksum](downloads/Exchange-KoreanRules-2.3.0-source.zip.sha256) are also
preserved unchanged. Its source-only contents reflect the distribution before
explicit public approval for the two BINs, not a restriction on the current
2.3.1 bundle. The latest complete public kit and checksum belong in the active
[downloads folder](../downloads).

## Historical recordings

- [1.0.1 video and companions](media/1.0.1)
- [1.2.1 video, audio and companions](media/1.2.1)
- [2.0.0 video, audio and companions](media/2.0.0)
- [2.1.0 English and Hindi video, audio and companions](media/2.1.0)

The 2.1.0 English and Hindi walkthroughs have been archived unchanged.
Their mandatory maintenance flag, default portable output and manual payload
handoff are superseded by the current written contract.
The [2.3.1 recordings](../docs/Walkthroughs.md) cover the bundled-file workflow
in English, Hindi and Tamil. Use them and the [written guide](../README.md)
for current operating instructions; archiving does not make old advice current.

## Compatibility entry points

The [compatibility folder](compatibility) holds maintained forwarding wrappers,
not standalone installers:

| Old entry point | Prefer now |
|---|---|
| `Build-KB5130098Package.ps1` | `Install-KoreanRules.ps1` |
| `Invoke-KB5130098.ps1` | `Get-KoreanRulesState.ps1` / `Set-KoreanRulesState.ps1` |
| `Invoke-KB5130098Fleet.ps1` | Current Get/Set with names or CSV |
| `KB5130098.psm1` | `KoreanRules.psm1` |

These wrappers resolve the current tool root when run from this archive. They
also work if deliberately copied beside a complete current runtime for an
existing automation dependency. **The old Fleet Apply still implies a restart**;
it retains recovery gates. `-MaintenanceWindowApproved` is not required anywhere;
it remains an optional compatibility no-op for old commands. Current Set requires
explicit `-RestartSearch`. Plan an operational window; rollback stays
Support-approved/receipt-bound and restarted remote rollout stays serial with
required per-server recovery attestation. State-command UAC is unchanged.
Prefer updating automation to
the new names rather than copying old files back into the active view.

This repository cleanup intentionally changes old file URLs. Updated guide links
point here; Git history retains the original locations. Existing downloaded
packages and files staged in operator/lab folders were not moved or removed.
