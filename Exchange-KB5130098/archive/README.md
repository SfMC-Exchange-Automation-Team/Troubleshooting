# Archive — historical Korean Rules material

**For current usage, return to the [operator guide](../README.md).**
Do not choose an old release merely because it appears here.

The active tool folder now presents only the three current operator scripts.
This archive keeps prior material available without mixing it into the normal
download and documentation folders. No old release ZIP, checksum, recording,
caption, transcript or poster was deleted or changed during this move.

## Current files (outside this archive)

- [Install-KoreanRules.ps1](../Install-KoreanRules.ps1) — build a portable runtime and prepare/verify adjacent payload.
- [Get-KoreanRulesState.ps1](../Get-KoreanRulesState.ps1) — inspect servers.
- [Set-KoreanRulesState.ps1](../Set-KoreanRulesState.ps1) — change eligible servers.
- [Latest source kit and checksum](../downloads).
- [Retained 2.1.0 walkthroughs and the 2.2.0 correction](../docs/Walkthroughs.md).

The current release is **2.2.0**. After Install succeeds, Set in the same complete
writable kit/computer uses its adjacent payload without a manual handoff.
Microsoft binaries generated there remain local-only, not source-download
contents. The release root retains exactly three operator scripts.

## Archived downloads

The [downloads folder](downloads) contains these superseded source kits, each
with its original SHA256 sidecar:

| Versions | Original product naming |
|---|---|
| 1.0.1, 1.0.2 | Exchange-KB5130098 |
| 1.1.0, 1.1.1, 1.1.2 | Exchange-KB5130098 |
| 1.2.0, 1.2.1, 1.2.2, 1.2.3 | Exchange-KB5130098 |
| 2.0.0, 2.0.1, 2.1.0 | Exchange-KoreanRules |

Archives are immutable snapshots: their internal layouts and instructions
reflect those versions. They are not instructions for the current release.
The 2.1.0 source ZIP and sidecar are also preserved unchanged here; its historical
compatibility wrappers still occupy their original locations inside that ZIP.
The latest 2.2.0 source kit and checksum belong in the active
[downloads folder](../downloads).

## Historical recordings

- [1.0.1 video and companions](media/1.0.1)
- [1.2.1 video, audio and companions](media/1.2.1)
- [2.0.0 video, audio and companions](media/2.0.0)

The retained [2.1.0 English and Hindi walkthroughs](../docs/Walkthroughs.md)
remain in the active language folders and were not regenerated for 2.2.0.
Their manual payload-handoff section is superseded by the adjacent default.
Use the [written guide](../README.md)
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
it retains the maintenance and recovery gates. Prefer updating automation to
the new names rather than copying old files back into the active view.

This repository cleanup intentionally changes old file URLs. Updated guide links
point here; Git history retains the original locations. Existing downloaded
packages and files staged in operator/lab folders were not moved or removed.
