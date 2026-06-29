<#
.SYNOPSIS
    Finds and optionally deletes Azure Arc machine resources where Arc agent status is Expired.

.DESCRIPTION
    Uses Azure CLI authentication and the Azure Resource Graph REST API to find Azure
    Arc-enabled servers with properties.status == "Expired". By default, the script
    runs in WhatIf/preview mode and only shows the machines it would delete. Pass
    -Force to delete them after an explicit YES confirmation. Pass -Force -WhatIf
    to exercise the delete path without deleting.

.EXAMPLES
    Preview expired Arc machines in the current Azure CLI subscription:
        .\Remove-ExpiredArcMachines.ps1

    Preview using PowerShell WhatIf output for the delete path:
        .\Remove-ExpiredArcMachines.ps1 -Force -WhatIf

    Delete expired Arc machines after confirmation:
        .\Remove-ExpiredArcMachines.ps1 -Force

.NOTES
    This deletes the Azure Arc resource object in Azure. It does not uninstall the Azure
    Connected Machine agent from the actual server.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string] $SubscriptionId,

    [string] $ResourceGroup,

    [string] $ExportCsv = ".\expired-arc-machines.csv",

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Test-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI was not found. Install it from https://aka.ms/installazurecliwindows, then run: az login"
    }
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & az @Arguments --only-show-errors -o json

    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }

    if ([string]::IsNullOrWhiteSpace($output)) {
        return $null
    }

    return $output | ConvertFrom-Json
}

function Escape-KqlString {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    return $Value.Replace("'", "''")
}

Test-AzCli

try {
    $account = Invoke-AzCliJson -Arguments @('account', 'show')
}
catch {
    Write-Host "No Azure CLI login found. Starting az login..." -ForegroundColor Yellow
    & az login --only-show-errors | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "az login failed."
    }

    $account = Invoke-AzCliJson -Arguments @('account', 'show')
}

if ($SubscriptionId) {
    & az account set --subscription $SubscriptionId --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set Azure CLI subscription to '$SubscriptionId'."
    }

    $account = Invoke-AzCliJson -Arguments @('account', 'show')
}

Write-Host "Azure CLI account: $($account.user.name)" -ForegroundColor Green
Write-Host "Subscription: $($account.name) [$($account.id)]" -ForegroundColor Green

$resourceGroupWhere = ""
if (-not [string]::IsNullOrWhiteSpace($ResourceGroup)) {
    $escapedResourceGroup = Escape-KqlString -Value $ResourceGroup
    $resourceGroupWhere = "| where resourceGroup =~ '$escapedResourceGroup'"
}

$query = @"
Resources
| where type =~ 'microsoft.hybridcompute/machines'
$resourceGroupWhere
| extend arcAgentStatus = tostring(properties.status)
| extend connectionStatus = tostring(properties.connectionStatus)
| extend lastStatusChange = todatetime(properties.lastStatusChange)
| extend agentVersion = tostring(properties.agentVersion)
| extend osName = tostring(properties.osName)
| extend osSku = tostring(properties.osSku)
| where arcAgentStatus =~ 'Expired'
| project name, resourceGroup, subscriptionId, location, arcAgentStatus, connectionStatus, lastStatusChange, agentVersion, osName, osSku, id
| order by resourceGroup asc, name asc
"@

Write-Host ""
Write-Host "Searching for Azure Arc machines where Arc agent status = Expired..." -ForegroundColor Cyan

$token = Invoke-AzCliJson -Arguments @('account', 'get-access-token', '--resource', 'https://management.azure.com/')
$requestBody = [pscustomobject]@{
    subscriptions = @([string]$account.id)
    query = $query
    options = [pscustomobject]@{
        '$top' = 1000
        resultFormat = 'objectArray'
    }
} | ConvertTo-Json -Depth 5

$graphResult = Invoke-RestMethod `
    -Method Post `
    -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' `
    -Headers @{ Authorization = "Bearer $($token.accessToken)" } `
    -ContentType 'application/json' `
    -Body $requestBody
$machines = @($graphResult.data)

if ($machines.Count -eq 0) {
    Write-Host "No expired Azure Arc machine resources found." -ForegroundColor Green
    return
}

Write-Host ""
Write-Host "Expired Azure Arc machine resources:" -ForegroundColor Yellow
$machines |
    Select-Object name, resourceGroup, arcAgentStatus, connectionStatus, lastStatusChange, agentVersion, osName, location |
    Format-Table -AutoSize

Write-Host "Count: $($machines.Count)" -ForegroundColor Yellow

$machines |
    Select-Object name, resourceGroup, subscriptionId, location, arcAgentStatus, connectionStatus, lastStatusChange, agentVersion, osName, osSku, id |
    Export-Csv -Path $ExportCsv -NoTypeInformation -WhatIf:$false

Write-Host "Exported results to: $ExportCsv" -ForegroundColor Cyan

if (-not $Force) {
    Write-Host ""
    Write-Host "WHATIF MODE: No resources deleted." -ForegroundColor Magenta
    Write-Host "Run with -Force to remove these Arc machine resource objects after confirmation." -ForegroundColor Magenta

    foreach ($machine in $machines) {
        $resourceId = [string]$machine.id
        Write-Host "Would delete: $($machine.name) [$resourceId]" -ForegroundColor DarkYellow
    }

    return
}

if (-not $WhatIfPreference) {
    Write-Host ""
    Write-Host "WARNING: This will delete Azure Arc machine resource objects from Azure." -ForegroundColor Red
    Write-Host "It will not uninstall the Azure Connected Machine agent from the actual server." -ForegroundColor Yellow
    Write-Host "CSV backup of targeted resources saved to: $ExportCsv" -ForegroundColor Yellow

    $confirm = Read-Host "Type YES to delete these Azure Arc machine resources"
    if ($confirm -ne 'YES') {
        Write-Host "Aborted. No resources deleted." -ForegroundColor Cyan
        return
    }
}

foreach ($machine in $machines) {
    $resourceId = [string]$machine.id

    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        Write-Warning "Skipping '$($machine.name)' because Resource ID is empty."
        continue
    }

    if ($PSCmdlet.ShouldProcess($resourceId, 'Delete Azure Arc machine resource')) {
        Write-Host "Deleting: $($machine.name) in RG: $($machine.resourceGroup)" -ForegroundColor Red
        & az resource delete --ids $resourceId --only-show-errors

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Deleted: $($machine.name)" -ForegroundColor Green
        }
        else {
            Write-Warning "Failed to delete $($machine.name)."
        }
    }
}

Write-Host ""
if ($WhatIfPreference) {
    Write-Host "WhatIf complete. No resources deleted." -ForegroundColor Green
}
else {
    Write-Host "Cleanup complete." -ForegroundColor Green
}