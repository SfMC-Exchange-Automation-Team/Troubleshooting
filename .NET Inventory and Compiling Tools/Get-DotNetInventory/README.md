# Get-DotNetInventory PowerShell Function

## Summary
`Get-DotNetInventory` is a **PowerShell 5.1-compatible** function that dynamically enumerates all installed .NET components on Windows systems, including:

- **.NET Framework** (1.x–4.x)
- **.NET / .NET Core runtimes**
- **.NET SDKs**
- Optional sources:
  - `InstalledVersions` registry data
  - Add/Remove Program (ARP) entries (Programs & Features)

This script is designed for **administrators and support engineers** who need accurate inventory without relying on hardcoded version tables.

---

## Features
- Recursively scans registry keys for .NET Framework versions.
- Uses `dotnet CLI` for runtime and SDK detection; falls back to filesystem if CLI is missing or returns no data.
- Supports **32-bit and 64-bit dotnet CLI** detection on mixed environments.
- Provides **best-effort InstallDate** using:
  - Registry `InstallDate`
  - Registry `LastWriteTime`
  - Latest file timestamp in install folder
- Output is **refined for readability**:
  - `Type`, `Product`, `Version`, `Architecture`, `Source`, `InstallDate`

---

## Parameters
| Parameter                | Type    | Description                                                                 |
|--------------------------|---------|-----------------------------------------------------------------------------|
| `-LatestPerProduct`      | Switch  | Returns only the highest version per (Type, Product, Architecture).        |
| `-IncludeLanguagePacks`  | Switch  | Includes .NET Framework language packs (LCID subkeys). Default: Off.       |
| `-IncludeInstalledVersions` | Bool | Includes `HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions`. Default: True.   |
| `-IncludeARP`            | Bool    | Includes ARP entries for Microsoft .NET. Default: True.                    |

---

## Requirements
- **Windows PowerShell 5.1**
- Read access to:
  - `HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP`
  - `HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions`
  - ARP uninstall keys
- Optional: `dotnet CLI` in PATH or installed under `Program Files` / `Program Files (x86)`.

---

## Usage Examples

### Basic Inventory
```powershell
Get-DotNetInventory
````

### Latest Version Per Product

```powershell
Get-DotNetInventory -LatestPerProduct
```

### Include Language Packs

```powershell
Get-DotNetInventory -IncludeLanguagePacks
```

### Verbose Output

```powershell
Get-DotNetInventory -Verbose | Format-Table -AutoSize
```

***

## Output

Default output columns:

*   `Type` (Framework, Runtime, SDK, Installed, ARP)
*   `Product`
*   `Version`
*   `Architecture` (x64 / x86)
*   `Source` (Registry, DotNetCLI, FileSystem, InstalledVersions, ARP)
*   `InstallDate` (best-effort)

***

## Notes

*   No elevation required for read-only registry and filesystem queries.
*   Handles mixed 32-bit/64-bit environments gracefully.
*   If `dotnet CLI` returns no data, filesystem fallback ensures coverage.

***

## Change Log

### v1.1 - 10/27/2025

*   Added refined default output.
*   Added verbose messaging for CLI fallback.
*   Added support for 32-bit dotnet CLI detection.
*   Fixed PS 5.1 parsing issues with `ProgramFiles(x86)`.

***

## Author

Cullen Haafke  
**Role:** Sr Cloud Solution Architect  
**Division:** Support for Mission Critical (SfMC)  
Microsoft
