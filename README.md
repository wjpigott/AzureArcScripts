# Azure Arc Scripts

Small Azure Arc administration scripts and examples.

## Scripts

### Remove expired Azure Arc machines

[`scripts/Remove-ExpiredArcMachines.ps1`](scripts/Remove-ExpiredArcMachines.ps1) finds Azure Arc-enabled server resources where the Arc agent status is `Expired` and previews the Azure resources that would be removed.

By default, the script does not delete anything.

```powershell
.\scripts\Remove-ExpiredArcMachines.ps1
```

Test the delete path safely with PowerShell WhatIf:

```powershell
.\scripts\Remove-ExpiredArcMachines.ps1 -Force -WhatIf
```

Actual deletion requires `-Force` and an explicit `YES` confirmation prompt:

```powershell
.\scripts\Remove-ExpiredArcMachines.ps1 -Force
```

Use the optional `-SubscriptionId` and `-ResourceGroup` parameters when you want to scope the query at runtime. Do not commit environment-specific values into scripts or docs.

## Requirements

- PowerShell 7 or Windows PowerShell
- Azure CLI
- An active Azure CLI login from `az login`
- Permissions to read Azure Resource Graph and delete `Microsoft.HybridCompute/machines` resources when using `-Force`

## Notes

Deleting the Azure Arc resource object does not uninstall the Azure Connected Machine agent from the server.
