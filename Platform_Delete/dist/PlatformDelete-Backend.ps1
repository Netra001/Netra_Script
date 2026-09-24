######################################################################################################################
# PlatFormCode Delete - BACKEND
# All server discovery, POD/AZ selection and environment validation now
# happen in the Python GUI. This script only performs the remote
# deletion work and builds the HTML report, given already-resolved
# parameters.
#=====================================================================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentCategory,   # "PROD" or "NON-PROD" - display only

    [Parameter(Mandatory = $true)]
    [string]$PODName,

    [Parameter(Mandatory = $true)]
    [string]$AvailabilityZoneLabel, # display string, e.g. "us-east-1a" or "us-east-1a, us-east-1b (2 zones)"

    [Parameter(Mandatory = $true)]
    [ValidateSet("1", "2")]
    [string]$ConditionSelected,

    [Parameter(Mandatory = $true)]
    [string[]]$ServerList,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath = "C:\temp\FileDeletionReport.html"
)

$ErrorActionPreference = "Continue"

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " PLATFORMCODE DELETE - BACKEND" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "Environment : $($EnvironmentName.ToUpper()) ($EnvironmentCategory)"
Write-Host "POD         : $PODName"
Write-Host "AZ(s)       : $AvailabilityZoneLabel"
Write-Host "Condition   : $ConditionSelected"
Write-Host "Servers     : $($ServerList -join ', ')"
Write-Host ""

$option = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 20000
$ResultList = @()

foreach ($server in $ServerList) {
    try {
        $DeletionResult = Invoke-Command -ComputerName $server -SessionOption $option -ScriptBlock {
            param($Condition, $FolderPath, $SpecificFilePath, $FolderToDelete)

            switch ($Condition) {
                "1" {
                    # ------------------------------------------------------
                    # Combined: delete CC-Runtime contents AND the shmem
                    # memory file together, in the same remote call.
                    # ------------------------------------------------------
                    $CCRuntimeStatus = "Not Deleted"
                    $ShmemStatus = "Not Deleted"

                    try {
                        Get-ChildItem -Path $FolderPath -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction Stop
                        $Remaining = Get-ChildItem -Path $FolderPath -ErrorAction SilentlyContinue
                        $CCRuntimeStatus = if (-not $Remaining) { "Deleted" } else { "Not Deleted" }
                    }
                    catch {
                        $CCRuntimeStatus = "Error: $($_.Exception.Message)"
                    }

                    try {
                        Remove-Item -Path $SpecificFilePath -Force -ErrorAction Stop
                        $ShmemStatus = if (Test-Path $SpecificFilePath) { "Not Deleted" } else { "Deleted" }
                    }
                    catch {
                        $ShmemStatus = "Error: $($_.Exception.Message)"
                    }

                    return [PSCustomObject]@{
                        CCRuntimeStatus = $CCRuntimeStatus
                        ShmemStatus     = $ShmemStatus
                    }
                }
                "2" {
                    # Condition 2: Delete a folder
                    $SpecificFileStatus = "Not Deleted"
                    try {
                        Remove-Item -Path $FolderToDelete -Recurse -Force -ErrorAction Stop
                        $SpecificFileStatus = if (Test-Path $FolderToDelete) { "Not Deleted" } else { "Deleted" }
                    }
                    catch {
                        $SpecificFileStatus = "Error: $($_.Exception.Message)"
                    }

                    return [PSCustomObject]@{
                        SpecificFileStatus = $SpecificFileStatus
                    }
                }
                default {
                    return [PSCustomObject]@{ Status = "Invalid Condition" }
                }
            }
        } -ArgumentList $ConditionSelected, "D:\CC_runtime\*", "C:\corecard_services\shmem.bin", "D:\BKP\1" -ErrorAction Stop

        if ($ConditionSelected -eq "1") {
            Write-Host "$server -> CC-Runtime: $($DeletionResult.CCRuntimeStatus) | Shmem: $($DeletionResult.ShmemStatus)"
            $ResultList += [PSCustomObject]@{
                ServerName      = $server
                CCRuntimeStatus = $DeletionResult.CCRuntimeStatus
                ShmemStatus     = $DeletionResult.ShmemStatus
            }
        }
        else {
            Write-Host "$server -> SpecificFile: $($DeletionResult.SpecificFileStatus)"
            $ResultList += [PSCustomObject]@{
                ServerName          = $server
                SpecificFileStatus  = $DeletionResult.SpecificFileStatus
            }
        }
    }
    catch {
        Write-Host "$server -> ERROR: $($_.Exception.Message)" -ForegroundColor Red

        if ($ConditionSelected -eq "1") {
            $ResultList += [PSCustomObject]@{
                ServerName      = $server
                CCRuntimeStatus = "Error: $($_.Exception.Message)"
                ShmemStatus     = "Error: $($_.Exception.Message)"
            }
        }
        else {
            $ResultList += [PSCustomObject]@{
                ServerName          = $server
                SpecificFileStatus  = "Error: $($_.Exception.Message)"
            }
        }
    }
}

# ======================================================================
# HTML generation - columns depend on which condition was run.
# ======================================================================
if ($ConditionSelected -eq "1") {
    $TableHeaderHtml = @"
        <tr>
            <th>Server Name</th>
            <th>CC-Runtime Status</th>
            <th>Shmem Status</th>
        </tr>
"@
}
else {
    $TableHeaderHtml = @"
        <tr>
            <th>Server Name</th>
            <th>SpecificFile Status</th>
        </tr>
"@
}

$HtmlReport = @"
<html>
<head>
    <style>
        body { font-family: Arial; }
        table { border-collapse: collapse; width: 80%; margin: 20px; }
        th, td { border: 1px solid #ddd; padding: 10px; text-align: left; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        .Deleted { color: green; font-weight: bold; }
        .Error, .NotDeleted, .FolderNotFound { color: red; font-weight: bold; }
    </style>
</head>
<body>
    <h2>File Deletion Report</h2>
    <p><b>Environment:</b> $($EnvironmentName.ToUpper()) ($EnvironmentCategory) &nbsp;|&nbsp; <b>POD:</b> $PODName &nbsp;|&nbsp; <b>Availability Zone(s):</b> $AvailabilityZoneLabel</p>
    <table>
$TableHeaderHtml
"@

foreach ($entry in $ResultList) {

    if ($ConditionSelected -eq "1") {
        $CCClass = ($entry.CCRuntimeStatus -replace '\s+', '' -replace ':.*', '')
        $ShmemClass = ($entry.ShmemStatus -replace '\s+', '' -replace ':.*', '')
        $HtmlReport += "<tr><td>$($entry.ServerName)</td><td class='$CCClass'>$($entry.CCRuntimeStatus)</td><td class='$ShmemClass'>$($entry.ShmemStatus)</td></tr>`n"
    }
    else {
        $StatusClass = ($entry.SpecificFileStatus -replace '\s+', '' -replace ':.*', '')
        $HtmlReport += "<tr><td>$($entry.ServerName)</td><td class='$StatusClass'>$($entry.SpecificFileStatus)</td></tr>`n"
    }
}

$HtmlReport += @"
    </table>
</body>
</html>
"@

$HtmlReport | Out-File -FilePath $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "HTML Report generated at:" -ForegroundColor Green
Write-Host "REPORT_FILE::$ReportPath"

Write-Host ""
Write-Host "Operation completed." -ForegroundColor Green
