# Import-DiscoveryScriptResults

## Summary

This script provides a framework for working with XML and CliXML outputs from Exchange discovery cmdlets (such as `Get-ExchangeServer`, `Get-SendConnector`, and others). It enables you to register discovery datasets, load them into PowerShell as dynamic `Get-*` functions ("shims"), filter results through Exchange-like parameters, and unload or inspect those temporary functions.

## Applies to

*   PowerShell 5.1+ (explicitly stated in script comments)
*   Exchange discovery dataset outputs (XML or CliXML)
*   Local file system datasets (no remote execution logic included)

## What this script does

This script:

*   Registers discovery datasets in an internal `CustomerRegistry`.
*   Creates and manages synthetic `Get-*` functions that read from XML/CliXML outputs.
*   Normalizes organization prefixes using auto-detected tokens from `OrganizationConfig` XML files.
*   Supports filtering on many Exchange/AD-style parameters (e.g., `Identity`, `UserPrincipalName`, `Guid`, `RecipientTypeDetails`, and more).
*   Supports pagination features (`-First`, `-Skip`, `-SortBy`) when the underlying file is CliXML.
*   Tracks shim functions in a `FunctionRegistry`.
*   Removes shims on demand without deleting customer registration entries.

Data sources used:

*   Local file system XML/CliXML files (via `Import-Clixml`, `Get-Content`, `Get-ChildItem`).
*   No network, registry, WMI, or external services.

## Prerequisites

Based on script requirements:

*   **PowerShell 5.1 or later** (explicitly documented).
*   Read access to file system locations containing discovery XML/CliXML files.
*   XML files representing discovery results exported from Exchange cmdlets.
*   The script must be run in a context where global functions may be created.

No other dependencies, modules, or permissions are specified.

## Parameters

### Import-DiscoveryScriptResults

| Parameter    | Type            | Required | Description                                   |
| ------------ | --------------- | -------- | --------------------------------------------- |
| CustomerName | string          | Yes      | Logical name for the dataset.                 |
| Path         | string (folder) | Yes      | Folder containing discovery XML/CliXML files. |
| Year         | string          | No       | Stores Year metadata in registry entry.       |
| EXO          | switch          | No       | Tags dataset as Exchange Online.              |
| OnPrem       | switch          | No       | Tags dataset as Exchange On-Prem.             |
| NoLoad       | switch          | No       | Prevents auto‑load of shims after import.     |

### Load-Customer

| Parameter    | Type   | Required | Description                              |
| ------------ | ------ | -------- | ---------------------------------------- |
| CustomerName | string | Yes      | Name of registered dataset.              |
| EXO          | switch | No       | Overrides tag during load if applicable. |
| OnPrem       | switch | No       | Overrides tag during load if applicable. |

### Remove-DiscoveryFunctions

| Parameter    | Type   | Required | Description                               |
| ------------ | ------ | -------- | ----------------------------------------- |
| CustomerName | string | Yes      | Removes shim functions for this customer. |

### Get-DiscoveryIndex

| Parameter    | Type   | Required | Description                       |
| ------------ | ------ | -------- | --------------------------------- |
| CustomerName | string | No       | Filters index output by customer. |

### Unload-Customer

| Parameter    | Type   | Required | Description                               |
| ------------ | ------ | -------- | ----------------------------------------- |
| CustomerName | string | Yes      | Removes all shim functions for a dataset. |

### Get-Customer

| Parameter    | Type   | Required | Description                            |
| ------------ | ------ | -------- | -------------------------------------- |
| CustomerName | string | No       | Filters output to a specific customer. |

The dynamically created `Get-*` functions contain a very large parameter set (Exchange-like filtering). These are added programmatically in the script and match the parameter block inside the function wrapper.

## Output

### Get-DiscoveryIndex

Produces a `[pscustomobject]` with:

| Field    | Description                                                |
| -------- | ---------------------------------------------------------- |
| Function | Name of the generated `Get-*` shim.                        |
| Path     | Absolute path to the XML/CliXML file backing the function. |
| Customer | Customer associated with the shim.                         |
| Tag      | EXO / OnPrem / Unspecified.                                |
| Year     | Year metadata from registry.                               |

### Get-Customer

Produces a `[pscustomobject]` with:

| Field        | Description                    |
| ------------ | ------------------------------ |
| CustomerName | Registered dataset identifier. |
| Path         | Folder path for dataset.       |
| Tag          | Dataset tag.                   |
| Year         | Year metadata.                 |

### Loaded Get-\* functions

When called, they return either:

*   **Imported CliXML objects** (fully filterable), or
*   **Raw XML document** (`[xml]`) when CliXML import fails.

If raw XML is returned, filtering and pagination parameters are explicitly blocked.

## Examples

### From script help

```powershell
# Import and auto-load an OnPrem dataset for Contoso
Import-DiscoveryScriptResults -CustomerName Contoso -Path 'C:\Discovery\Contoso\OrgSettings' -OnPrem
```

```powershell
# Import a dataset but defer loading of shims
Import-DiscoveryScriptResults -CustomerName Fabrikam -Path 'C:\Discovery\Fabrikam\OrgSettings' -EXO -NoLoad
```

```powershell
# Load an existing customer dataset
Load-Customer -CustomerName Contoso -OnPrem
```

```powershell
# List all registered customers
Get-Customer
```

```powershell
# List all active discovery shims for a customer
Get-DiscoveryIndex -CustomerName Contoso
```

```powershell
# Remove all shims for a customer
Remove-DiscoveryFunctions -CustomerName Contoso
```

```powershell
# Fully unload a customer
Unload-Customer -CustomerName Contoso
```

## Error handling and troubleshooting

The script includes multiple error-handling mechanisms:

*   **Try/catch blocks**
    *   Used when loading CliXML files.
    *   If `Import-Clixml` fails, the script falls back to `Get-Content` and returns raw XML.
    *   Auto-load failures during import yield warnings without stopping registration.

*   **Parameter validation errors**
    *   Filtering parameters that do not exist on objects produce a descriptive error listing available properties.

*   **Warning messages**
    *   When no XML files are found in a dataset directory.
    *   When attempting to unload non-existent shims.

*   **Verbose output**
    *   For organization token detection from XML and filenames.

## Limitations

Derived strictly from script behavior:

*   Filtering and pagination (`-First`, `-Skip`, `-SortBy`) do **not** work for raw XML imports.
*   Shim function names are inferred from file names; malformed names may produce unexpected function names.
*   Only **local** file system XML/CliXML datasets are supported. No remote or live Exchange data queries.
*   No de-registration function exists to remove a customer from the `CustomerRegistry` itself.
*   Global function creation requires a PowerShell session that allows modifying global scope.

## Security and permissions considerations

*   Script modifies **global function scope**, which may require elevated permissions depending on session policy.
*   Dataset reading requires file system read permissions for XML/CliXML files.
*   The script does **not** modify system state outside PowerShell scope and does not connect to remote services.

## FAQ

### How do I run this script against multiple customers?

You may register multiple datasets using `Import-DiscoveryScriptResults`. Each customer maintains its own set of shims.

### What does it mean when a result is empty or `$null`?

If `Import-Clixml` fails, the script returns raw `[xml]`. Filtering is disabled in this case, producing unexpected empty results unless filtering is removed.

### Does this script require special permissions?

Only read access to the dataset folder and permission to define global PowerShell functions.

### Does this script modify Exchange or Active Directory?

No. It is entirely read-only and operates only on exported XML/CliXML files.

### Where are logs stored?

The script does not implement logging. Any observable messaging is output directly to the console via `Write-Host`, `Write-Warning`, or `Write-Verbose`.

***

If you'd like, I can also generate:

*   A README.md formatted for GitHub
*   Inline script documentation updates
*   A shorter executive summary for leadership

Just let me know!
