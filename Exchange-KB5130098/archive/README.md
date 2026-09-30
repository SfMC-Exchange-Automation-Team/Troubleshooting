# Archive — historical Korean Rules material

**For current usage, return to the [operator guide](../README.md).**
Do not choose an old release merely because it appears here.

The active tool folder now presents only the three current operator scripts.
This archive keeps prior material available without mixing it into the normal
download and documentation folders. No old release ZIP, checksum, recording,
caption, transcript or poster was deleted or changed during this move.

## Current files (outside this archive)

- [Install-KoreanRules.ps1](../Install-KoreanRules.ps1) — prepare verified files.
- [Get-KoreanRulesState.ps1](../Get-KoreanRulesState.ps1) — inspect servers.
- [Set-KoreanRulesState.ps1](../Set-KoreanRulesState.ps1) — change eligible servers.
- [Latest source kit and checksum](../downloads).
- [Most recent walkthrough and supporting documentation](../docs).

## Archived downloads

The [downloads folder](downloads) contains these superseded source kits, each
with its original SHA256 sidecar:

| Versions | Original product naming |
|---|---|
| 1.0.1, 1.0.2 | Exchange-KB5130098 |
| 1.1.0, 1.1.1, 1.1.2 | Exchange-KB5130098 |
| 1.2.0, 1.2.1, 1.2.2, 1.2.3 | Exchange-KB5130098 |
| 2.0.0, 2.0.1 | Exchange-KoreanRules |

Archives are immutable snapshots: their internal layouts and instructions
reflect those versions. They are not instructions for the current release.
The latest 2.1.0 source ZIP is also unchanged and remains in the active
[downloads folder](../downloads); its historical compatibility wrappers still
occupy their original locations inside that already-published ZIP.

## Historical recordings

- [1.0.1 video and companions](media/1.0.1)
- [1.2.1 video, audio and companions](media/1.2.1)

The latest available [2.0.0 walkthrough](../docs/Exchange-KoreanRules-2.0.0-Walkthrough.mp4)
remains in the active docs folder. Use its current-release caveats in the
[written guide](../README.md); archiving does not make old operational advice current.

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
