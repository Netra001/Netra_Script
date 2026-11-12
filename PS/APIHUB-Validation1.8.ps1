######################################################################################################################
# APIHUB Servers Validation
# DEVELOPED BY:: Netra Chettri
# Version 1.8 | Date:: 29-Sep-2026
######################################################################################################################

Clear-Host

# ======================================================================
# AWS SERVER DISCOVERY
# ======================================================================

$Module = "APIHUB"

function Get-AwsInstanceData {
    param (
        [string]$Query,
        [object[]]$Filters,
        [string]$Region,
        [string]$Operation
    )

    $FilterArguments = @(
        foreach ($Filter in $Filters) {
            $Values = @($Filter.Values) -join ","
            "Name=$($Filter.Name),Values=$Values"
        }
    )

    $AwsArguments = @(
        "ec2"
        "describe-instances"
        "--query"
        $Query
        "--filters"
    ) + $FilterArguments + @(
        "--region"
        $Region
    )

    $AwsOutput = & aws @AwsArguments 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: AWS server error while $Operation (exit code $LASTEXITCODE)." -ForegroundColor Red

        $AwsOutput | ForEach-Object {
            Write-Host "$_" -ForegroundColor Red
        }

        exit 1
    }

    try {
        $JsonOutput = $AwsOutput -join [Environment]::NewLine

        return $JsonOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Could not parse AWS response while $Operation`: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# ======================================================================
# IDENTIFY CURRENT EC2 INSTANCE
# ======================================================================

$ThisServer = (Hostname).ToLower()

try {

    $MetadataToken = Invoke-RestMethod `
        -Method Put `
        -Uri "http://169.254.169.254/latest/api/token" `
        -Headers @{
            "X-aws-ec2-metadata-token-ttl-seconds" = "21600"
        } `
        -TimeoutSec 5 `
        -ErrorAction Stop

    $MetadataHeaders = @{
        "X-aws-ec2-metadata-token" = $MetadataToken
    }

    $InstanceId = (
        Invoke-RestMethod `
            -Uri "http://169.254.169.254/latest/meta-data/instance-id" `
            -Headers $MetadataHeaders `
            -TimeoutSec 5 `
            -ErrorAction Stop
    ).Trim()

    $Region = (
        Invoke-RestMethod `
            -Uri "http://169.254.169.254/latest/meta-data/placement/region" `
            -Headers $MetadataHeaders `
            -TimeoutSec 5 `
            -ErrorAction Stop
    ).Trim()

}
catch {

    Write-Host "ERROR: Could not identify this EC2 instance from instance metadata: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ======================================================================
# REGION MAPPING
# ======================================================================

$ShortRegion = switch ($Region) {

    "us-east-1" {
        "e1"
    }

    "us-west-2" {
        "w2"
    }

    default {
        $null
    }
}

if (-not $ShortRegion) {

    Write-Host "ERROR: Unsupported AWS region '$Region' for local instance '$InstanceId'." -ForegroundColor Red

    exit 1
}

# ======================================================================
# GET CURRENT INSTANCE DETAILS
# ======================================================================

$LocalServerFilters = @(
    @{
        Name   = "instance-state-name"
        Values = @("running")
    }

    @{
        Name   = "instance-id"
        Values = @($InstanceId)
    }

    @{
        Name   = "availability-zone"
        Values = @("*")
    }
)

$AWSVarialbes = Get-AwsInstanceData `
    -Query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,Environment:Tags[?Key=='environment']|[0].Value,Stack:Tags[?Key=='stack']|[0].Value,Attribution:Tags[?Key=='attribution']|[0].Value,Tags:Tags}" `
    -Filters $LocalServerFilters `
    -Region $Region `
    -Operation "fetching local instance '$InstanceId'"

if (-not $AWSVarialbes -or (-not $AWSVarialbes.Environment -and -not ($AWSVarialbes.Tags | Where-Object { $_.Key -ieq 'environment' }))) {

    Write-Host "ERROR: Could not resolve environment tags for local instance '$InstanceId' in region '$Region'." -ForegroundColor Red

    Write-Host "Check that the instance has an environment tag and that the AWS CLI credentials have permission to describe this instance in the current account and region." -ForegroundColor Red

    Write-Host ""
    Write-Host "Try running this directly to see what AWS actually returns:" -ForegroundColor Yellow

    Write-Host "aws ec2 describe-instances --instance-ids $InstanceId --region $Region" -ForegroundColor Yellow

    exit 1
}

$EnvironmentNameRaw = if ($AWSVarialbes.Environment) {
    $AWSVarialbes.Environment
}
else {
    ($AWSVarialbes.Tags | Where-Object { $_.Key -ieq 'environment' } | Select-Object -First 1).Value
}

$EnvironmentName = $EnvironmentNameRaw.ToLower()
$EnvironmentName

$Environmentattributon = if ($AWSVarialbes.Attribution) {
    $AWSVarialbes.Attribution.ToLower()
}
else {
    $rawAttr = ($AWSVarialbes.Tags | Where-Object { $_.Key -ieq 'attribution' } | Select-Object -First 1).Value
    if ($rawAttr) { $rawAttr.ToLower() } else { "" }
}
$Environmentattributon

$rawStack = if ($AWSVarialbes.Stack) {
    $AWSVarialbes.Stack
}
else {
    ($AWSVarialbes.Tags | Where-Object { $_.Key -ieq 'stack' } | Select-Object -First 1).Value
}

if ($rawStack) {
    $EnvironmentStack = ($rawStack.ToLower())[0]
}
else {
    $EnvironmentStack = ""
}

$EnvironmentStack

# ======================================================================
# POD DETECTION
# ======================================================================

$Environmentpod = $null

$ResolvedPodTag = ($AWSVarialbes.Tags | Where-Object { $_.Key -ieq 'pod' } | Select-Object -First 1).Value

if (-not $ResolvedPodTag) {

    if ($Environmentattributon -eq "jazz") {

        $Environmentpod = $Environmentattributon

    }
    else {

        $S3bucketslist = aws s3 ls

        if ($S3bucketslist -match "corecard-(pod\d+|jazz)-$EnvironmentName-$Region-config-files") {

            $Environmentpod = $matches[1]
        }
        elseif ($S3bucketslist -match "corecard-pod1-$EnvironmentName-$Region-config-files") {

            $Environmentpod = "pod1"
        }
        elseif ($S3bucketslist -match "corecard-pod2-$EnvironmentName-$Region-config-files") {

            $Environmentpod = "pod2"
        }
        elseif ($S3bucketslist -match "corecard-pod3-$EnvironmentName-$Region-config-files") {

            $Environmentpod = "pod3"
        }
        elseif ($S3bucketslist -match "corecard-pod4-$EnvironmentName-$Region-config-files") {

            $Environmentpod = "pod4"
        }
        elseif ($S3bucketslist -match "corecard-pod5-$EnvironmentName-$Region-config-files") {

            $Environmentpod = "pod5"
        }
        elseif (
            ($S3bucketslist -match "corecard-jazz-$EnvironmentName-$Region-config-files") -and
            ($Environmentattributon -eq "jazz")
        ) {

            $Environmentpod = "jazz"
        }
    }
}
else {

    $Environmentpod = $ResolvedPodTag.ToLower()
}

if (-not $Environmentpod) {

    $Environmentpod = "unknown"
}

$Environmentpod

# ======================================================================
# DISCOVER APIHUB SERVERS
# ======================================================================

$EnvironmentNameRaw = $AWSVarialbes.Environment

$StackFull = if ($AWSVarialbes.Stack) {
    $AWSVarialbes.Stack
}
else {
    $null
}

$ServerFilters = @(
    @{
        Name   = "instance-state-name"
        Values = @("running")
    }

    @{
        Name   = "tag:Type"
        Values = @("apihub")
    }

    @{
        Name   = "tag:environment"
        Values = @($EnvironmentNameRaw)
    }

    @{
        Name   = "availability-zone"
        Values = @("*")
    }
)

if ($StackFull) {

    $ServerFilters += @{
        Name   = "tag:stack"
        Values = @($StackFull)
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Discovering APIHUB Servers" -ForegroundColor Cyan
Write-Host "Environment : $EnvironmentNameRaw" -ForegroundColor Cyan
Write-Host "Stack       : $StackFull" -ForegroundColor Cyan
Write-Host "Region      : $Region" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$DiscoveredInstances = Get-AwsInstanceData `
    -Query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,PrivateDnsName:PrivateDnsName,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name}" `
    -Filters $ServerFilters `
    -Region $Region `
    -Operation "fetching APIHUB servers"

# ======================================================================
# SERVER LIST
# ======================================================================

$ServerObjects = @(
    $DiscoveredInstances |
    Select-Object `
        @{n = "Name"; e = { $_.Name } },
        @{n = "IpAddress"; e = { $_.IpAddress } },
        @{n = "PrivateDnsName"; e = { $_.PrivateDnsName } },
        @{n = "serial"; e = {

            $Name = $_.Name

            if ($Name -match [regex]::Escape("$EnvironmentName$EnvironmentStack")) {

                $Remaining = ($Name -split [regex]::Escape("$EnvironmentName$EnvironmentStack"))[1]

                $Number = $Remaining -replace "[^0-9]", ""

                if ($Number) {
                    [double]$Number
                }
                else {
                    [double]::MaxValue
                }
            }
            else {
                [double]::MaxValue
            }
        } } |
    Sort-Object -Property serial
)

$ServerList = @($ServerObjects.Name)

Write-Host ""
Write-Host "Discovered APIHUB Servers:" -ForegroundColor Green

$ServerObjects | ForEach-Object {
    Write-Host "  $($_.Name) (IP: $($_.IpAddress))" -ForegroundColor Green
}

if (-not $ServerObjects) {

    Write-Host ""
    Write-Host "No APIHUB servers found for the given criteria. Exiting..." -ForegroundColor Red

    exit 1
}

# ======================================================================
# WINRM SESSION OPTIONS
# ======================================================================

$option = New-PSSessionOption `
    -ProxyAccessType NoProxyServer `
    -OpenTimeout 20000 `
    -OperationTimeout 120000

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

$htmlFile = "C:\Temp\APIHUBServersValidation$timestamp.html"

# Create C:\Temp if it does not exist

if (-not (Test-Path "C:\Temp")) {

    New-Item `
        -Path "C:\Temp" `
        -ItemType Directory `
        -Force | Out-Null
}

# ======================================================================
# WINRM CONNECTIVITY / REMOTE EXECUTION FUNCTION
# ======================================================================

function Invoke-RemoteValidation {

    param (
        [Parameter(Mandatory = $true)]
        $ServerTarget,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        $SessionOption
    )

    $ServerName = if ($ServerTarget -is [string]) { $ServerTarget } else { $ServerTarget.Name }
    $ServerIP   = if ($ServerTarget.IpAddress) { $ServerTarget.IpAddress } else { $null }
    $ServerPrivateDns = if ($ServerTarget.PrivateDnsName) { $ServerTarget.PrivateDnsName } else { $null }

    if (-not $ServerIP -and $DiscoveredInstances) {
        $matchingInst = $DiscoveredInstances | Where-Object { $_.Name -ieq $ServerName } | Select-Object -First 1
        if ($matchingInst) {
            $ServerIP = $matchingInst.IpAddress
            if (-not $ServerPrivateDns) { $ServerPrivateDns = $matchingInst.PrivateDnsName }
        }
    }

    # ---------------------------------------------------------------
    # 0. Check if target is the local machine running this script
    # ---------------------------------------------------------------
    $LocalHostName = (Hostname).ToLower()
    $LocalEnvComp  = ($env:COMPUTERNAME).ToLower()
    $LocalIPs = @(
        try {
            [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                ForEach-Object { $_.IPAddressToString }
        }
        catch { @() }
    )

    $isLocal = ($ServerName.ToLower() -eq $LocalHostName) -or
               ($ServerName.ToLower() -eq $LocalEnvComp) -or
               ($ServerName -ieq "localhost") -or
               ($ServerName -eq "127.0.0.1") -or
               ($ServerIP -and ($LocalIPs -contains $ServerIP))

    if ($isLocal) {
        Write-Host ""
        Write-Host "Target '$ServerName' is the local server ($LocalHostName). Executing validation directly in-process..." -ForegroundColor Green
        try {
            $localRawResults = & $ScriptBlock
            $stampedResults = @(
                foreach ($item in $localRawResults) {
                    if ($item -and -not $item.PSComputerName) {
                        Add-Member -InputObject $item -NotePropertyName "PSComputerName" -NotePropertyValue $ServerName -Force
                    }
                    $item
                }
            )
            return $stampedResults
        }
        catch {
            Write-Host "Direct local validation failed on '$ServerName': $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
    }

    # ---------------------------------------------------------------
    # Ensure WinRM service and TrustedHosts are configured locally
    # ---------------------------------------------------------------
    try {
        $winrmService = Get-Service -Name WinRM -ErrorAction SilentlyContinue
        if ($winrmService -and $winrmService.Status -ne 'Running') {
            Start-Service -Name WinRM -ErrorAction SilentlyContinue
        }
    }
    catch {}

    try {
        $curTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
        if ($curTrusted -ne "*") {
            Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value "*" -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}

    # ---------------------------------------------------------------
    # Build candidate endpoints to connect to
    # ---------------------------------------------------------------
    $Candidates = @()

    # 1. AWS Private IP Address (Direct connection - no DNS or hosts file needed)
    if ($ServerIP) {
        $Candidates += [PSCustomObject]@{ Address = $ServerIP; Type = "AWS Private IP" }
    }

    # 2. Short Hostname
    if ($ServerName) {
        $Candidates += [PSCustomObject]@{ Address = $ServerName; Type = "Hostname" }
    }

    # 3. Domain FQDN (if domain is known and not workgroup)
    try {
        $domain = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Domain
        if ($domain -and $domain -ne "WORKGROUP" -and ($ServerName -notmatch [regex]::Escape($domain))) {
            $Candidates += [PSCustomObject]@{ Address = "$ServerName.$domain"; Type = "Domain FQDN" }
        }
    }
    catch {}

    # 4. DNS-resolved name (via Resolve-DnsName)
    try {
        $dnsRec = Resolve-DnsName -Name $ServerName -Type A -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress } | Select-Object -First 1
        if ($dnsRec -and $dnsRec.Name -and ($Candidates.Address -notcontains $dnsRec.Name)) {
            $Candidates += [PSCustomObject]@{ Address = $dnsRec.Name; Type = "DNS A-Record" }
        }
        if ($dnsRec -and $dnsRec.IPAddress -and -not $ServerIP) {
            $ServerIP = $dnsRec.IPAddress
        }
    }
    catch {}

    # 5. AWS Private DNS Name (e.g. ip-10-x-x-x.ec2.internal)
    if ($ServerPrivateDns -and ($Candidates.Address -notcontains $ServerPrivateDns)) {
        $Candidates += [PSCustomObject]@{ Address = $ServerPrivateDns; Type = "AWS Private DNS" }
    }

    # ---------------------------------------------------------------
    # Try connecting using each candidate
    # ---------------------------------------------------------------
    $attemptErrors = @()

    foreach ($cand in $Candidates) {
        $addr = $cand.Address
        $type = $cand.Type

        Write-Host ""
        Write-Host "Attempting WinRM connection to '$ServerName' via $type ($addr)..." -ForegroundColor Cyan

        try {
            $remoteResults = Invoke-Command `
                -ComputerName $addr `
                -SessionOption $SessionOption `
                -ErrorAction Stop `
                -ScriptBlock $ScriptBlock

            Write-Host "WinRM connection successful to '$ServerName' via $type ($addr)!" -ForegroundColor Green

            # Stamp PSComputerName with friendly name so report displays $ServerName
            $stampedResults = @(
                foreach ($item in $remoteResults) {
                    if ($item -and ($item.PSComputerName -ne $ServerName)) {
                        Add-Member -InputObject $item -NotePropertyName "PSComputerName" -NotePropertyValue $ServerName -Force
                    }
                    $item
                }
            )

            return $stampedResults
        }
        catch {
            $err = $_.Exception.Message
            Write-Host "WinRM connection failed via $type ($addr): $err" -ForegroundColor Yellow
            $attemptErrors += "[$type - $addr]: $err"
        }
    }

    # ---------------------------------------------------------------
    # Diagnostics if all candidates failed
    # ---------------------------------------------------------------
    $port5985Status = "Unknown"
    $diagTarget = if ($ServerIP) { $ServerIP } else { $ServerName }
    try {
        $tnc = Test-NetConnection -ComputerName $diagTarget -Port 5985 -WarningAction SilentlyContinue
        if ($tnc.TcpTestSucceeded) {
            $port5985Status = "Port 5985 is OPEN (network path reachable; issue is WinRM authentication or target service config)"
        }
        else {
            $port5985Status = "Port 5985 is BLOCKED / UNREACHABLE (check AWS Security Group inbound 5985 and target Windows Firewall)"
        }
    }
    catch {
        $port5985Status = "Could not test port 5985 ($($_.Exception.Message))"
    }

    $allErrorsStr = $attemptErrors -join " | "
    throw "WinRM connection failed for '$ServerName'. Attempts: $allErrorsStr. Diagnostics: $port5985Status"
}

# ======================================================================
# VALIDATION SCRIPT
# ======================================================================

$AllResults = @()

foreach ($ServerObj in $ServerObjects) {

    $Server = $ServerObj.Name

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "Starting validation for: $Server" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray

    try {

        $ServerResults = Invoke-RemoteValidation `
            -ServerTarget $ServerObj `
            -SessionOption $option `
            -ScriptBlock {

            # ==========================================================
            # REMOTE SERVER VALIDATION START
            # ==========================================================

            Get-ChildItem D:\ -Recurse | Unblock-File

            Clear-Host

            Get-Variable |
            Where-Object {

                ($_.Options -band [System.Management.Automation.ScopedItemOptions]::Constant) -eq 0 -and
                $_.Name -notmatch '^PS(|Item|Cmd|Script|Version|Home|ISE|Console|Prompt)'

            } |
            ForEach-Object {

                Remove-Variable `
                    -Name $_.Name `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            # ==========================================================
            # RESULTS ARRAY
            # ==========================================================

            $results = @()

            # ==========================================================
            # LOG FOLDER CHECK
            # ==========================================================

            $logJsonFile = 'D:\ApiHub\PODRedirectService\appsettings.json'

            $expectedJsonLine = '"path": "D:/Logs/APIHUB/MergeAcrossAPI.log"'

            $expectedResolvedPath = "D:\Logs\APIHUB"

            $logResult = 'FAILED'

            if (Test-Path $logJsonFile) {

                $escapedPattern = [regex]::Escape($expectedJsonLine)

                $matchFound = Select-String `
                    -Path $logJsonFile `
                    -Pattern $escapedPattern `
                    -Quiet

                $folderExists = Test-Path $expectedResolvedPath

                if ($matchFound -and $folderExists) {

                    $logResult = 'PASSED'
                }
                elseif ($matchFound -and -not $folderExists) {

                    $logResult = 'Folder Missing'
                }
                elseif (-not $matchFound -and $folderExists) {

                    $logResult = 'Path Mismatch in JSON'
                }
                else {

                    $logResult = 'JSON Path & Folder Missing'
                }
            }
            else {

                $logResult = 'JSON File Not Found'
            }

            $results += [PSCustomObject]@{
                Check  = 'Log Folder'
                Value  = $expectedResolvedPath
                Status = $logResult
            }

            # ==========================================================
            # CERT FOLDER CHECK
            # ==========================================================

            $certJsonFile = 'D:\ApiHub\PODRedirectService\appsettings.json'

            $expectedJsonLine = '"CertFolder": "D:/CertFolder"'

            $resolvedPath = 'D:\CertFolder'

            $certResult = 'FAILED'

            if (Test-Path $certJsonFile) {

                $escapedPattern = [regex]::Escape($expectedJsonLine)

                $matchFound = Select-String `
                    -Path $certJsonFile `
                    -Pattern $escapedPattern `
                    -Quiet

                $folderExists = Test-Path $resolvedPath

                if ($matchFound -and $folderExists) {

                    $certResult = 'PASSED'
                }
                elseif ($matchFound -and -not $folderExists) {

                    $certResult = 'Folder Missing'
                }
                elseif (-not $matchFound -and $folderExists) {

                    $certResult = 'Path Mismatch in JSON'
                }
                else {

                    $certResult = 'JSON Path & Folder Missing'
                }
            }
            else {

                $certResult = 'JSON File Not Found'
            }

            $results += [PSCustomObject]@{
                Check  = 'Cert Folder'
                Value  = $resolvedPath
                Status = $certResult
            }

            # ==========================================================
            # API URL VALIDATION
            # ==========================================================

            if (-not ("TrustAllCertsPolicy" -as [type])) {

                Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;

public class TrustAllCertsPolicy : ICertificatePolicy
{
    public bool CheckValidationResult(
        ServicePoint srvPoint,
        X509Certificate certificate,
        WebRequest request,
        int certificateProblem
    )
    {
        return true;
    }
}
"@

                [System.Net.ServicePointManager]::CertificatePolicy =
                    New-Object TrustAllCertsPolicy
            }

            [Net.ServicePointManager]::SecurityProtocol =
                [Net.SecurityProtocolType]::Tls12

            $jsonFile = 'D:\ApiHub\PODRedirectService\appsettings.json'

            $apiUrl = $null

            $apiResult = 'FAILED'

            if (Test-Path $jsonFile) {

                $fileContent = Get-Content `
                    -Path $jsonFile `
                    -Raw `
                    -Encoding UTF8

                try {

                    $jsonContent = $fileContent |
                        ConvertFrom-Json `
                            -ErrorAction Stop

                    $apiUrl = $jsonContent.APIURL
                }
                catch {

                    if ($fileContent -match '"APIURL"\s*:\s*"([^"]+)"') {

                        $apiUrl = $matches[1]
                    }
                }

                if ($apiUrl) {

                    $baseUrl = $apiUrl -replace '/\{0\}.*$', ''

                    $requiredPath = 'accounts/issuerAccountIds'

                    if ($baseUrl -notmatch [regex]::Escape($requiredPath)) {

                        $apiResult = 'FAILED - API URL is Not Expected'
                    }
                    else {

                        try {

                            $response = Invoke-WebRequest `
                                -Uri $baseUrl `
                                -Method GET `
                                -UseBasicParsing `
                                -ErrorAction Stop

                            if ($response.StatusCode -eq 200) {

                                $apiResult = 'Live (Unexpected 200)'
                            }
                            else {

                                $apiResult = "Unexpected ($($response.StatusCode))"
                            }
                        }
                        catch {

                            if ($_.Exception.Response) {

                                $statusCode =
                                    [int]$_.Exception.Response.StatusCode

                                if ($statusCode -eq 401) {

                                    $apiResult = 'PASSED'
                                }
                                else {

                                    $apiResult = "Unexpected ($statusCode)"
                                }
                            }
                            else {

                                $apiResult =
                                    "Error: $($_.Exception.Message)"
                            }
                        }
                    }
                }
                else {

                    $apiResult = 'APIURL Missing'
                }
            }
            else {

                $apiResult = 'JSON File Not Found'
            }

            $results += [PSCustomObject]@{
                Check  = 'API URL'
                Value  = $apiUrl
                Status = $apiResult
            }

            # ==========================================================
            # POD URL VALIDATION
            # ==========================================================

            if (Test-Path $jsonFile) {

                $fileContent = Get-Content `
                    -Path $jsonFile `
                    -Raw `
                    -Encoding UTF8

                $podMatches = [regex]::Matches(
                    $fileContent,
                    '"(POD\d+)"\s*:\s*"([^"]+)"'
                )

                foreach ($match in $podMatches) {

                    $keyName = $match.Groups[1].Value

                    $url = $match.Groups[2].Value

                    if ($keyName -match '^POD[124]$') {

                        $status = 'FAILED'

                        try {

                            $uri = [uri]$url

                            $baseUrl =
                                $uri.GetLeftPart(
                                    [System.UriPartial]::Authority
                                )

                            $response = Invoke-WebRequest `
                                -Uri $baseUrl `
                                -UseBasicParsing `
                                -TimeoutSec 120 `
                                -ErrorAction Stop

                            if ($response.StatusCode -eq 200) {

                                $status = 'PASSED'
                            }
                            else {

                                $status =
                                    "UnPASSED ($($response.StatusCode))"
                            }
                        }
                        catch {

                            if (
                                $_.Exception.InnerException -and
                                $_.Exception.InnerException.GetType().Name -eq 'TimeoutException'
                            ) {

                                $status =
                                    'Error: Request Timed Out'
                            }
                            else {

                                $status =
                                    "Error: $($_.Exception.Message)"
                            }
                        }

                        $results += [PSCustomObject]@{
                            Check  = $keyName
                            Value  = $url
                            Status = $status
                        }
                    }
                }
            }
            else {

                $results += [PSCustomObject]@{
                    Check  = 'POD URLs'
                    Value  = ''
                    Status = 'JSON File Not Found'
                }
            }

            # ==========================================================
            # AWS SECRET KEY VALIDATION
            # ==========================================================

            $jsonFile =
                'D:\ApiHub\PODRedirectService\appsettings.json'

            if (Test-Path $jsonFile) {

                try {

                    $rawJson = Get-Content `
                        -Path $jsonFile `
                        -Raw `
                        -Encoding UTF8

                    $cleanJson =
                        $rawJson -replace '(?s)/\*.*?\*/', ''

                    $jsonContent =
                        $cleanJson |
                        ConvertFrom-Json `
                            -ErrorAction Stop
                }
                catch {

                    $results += [PSCustomObject]@{
                        Check  = 'Secret Keys'
                        Value  = ''
                        Status =
                            "Failed to read JSON: $($_.Exception.Message)"
                    }

                    $jsonContent = $null
                }
            }
            else {

                $results += [PSCustomObject]@{
                    Check  = 'Secret Keys'
                    Value  = ''
                    Status = 'JSON File Not Found'
                }

                $jsonContent = $null
            }

            if ($jsonContent) {

                $region =
                    $jsonContent.AWSConfiguration.SecretManagerRegionEndpointName

                $secretKeys = @(
                    "APIUserId",
                    "APIPassword",
                    "AuthorizationUserIdAWSKey",
                    "AuthorizationPwdAWSKey"
                )

                foreach ($key in $secretKeys) {

                    $secretId =
                        $jsonContent.AWSConfiguration.$key

                    if (-not $secretId) {

                        $status = "Missing in JSON"

                        $secretId = ''
                    }
                    else {

                        try {

                            $secretValue =
                                Get-SECSecretValue `
                                    -Region $region `
                                    -SecretId $secretId `
                                    -ErrorAction Stop

                            if ($secretValue.SecretString) {

                                $status = "PASSED"
                            }
                            else {

                                $status =
                                    "UnPASSED (no value returned)"
                            }
                        }
                        catch {

                            $status =
                                "UnPASSED ($($_.Exception.Message))"
                        }
                    }

                    $results += [PSCustomObject]@{
                        Check  = "Secret Key - $key"
                        Value  = $secretId
                        Status = $status
                    }
                }
            }

            # ==========================================================
            # SECRET MANAGER REGION VALIDATION
            # ==========================================================

            $ThisServer = (hostname).ToLower()

            $ShortRegion = "UNKNOWN"

            $hostnameRegionMap = @{
                'e1' = 'us-east-1'
                'w2' = 'us-west-2'
            }

            foreach ($key in $hostnameRegionMap.Keys) {

                if ($ThisServer -match $key) {

                    $ShortRegion = $key

                    break
                }
            }

            $expectedRegion = if ($ShortRegion -ne "UNKNOWN") {

                $hostnameRegionMap[$ShortRegion]
            }
            else {

                "UNKNOWN"
            }

            $jsonFile =
                'D:\ApiHub\PODRedirectService\appsettings.json'

            if (Test-Path $jsonFile) {

                try {

                    $rawJson = Get-Content `
                        -Path $jsonFile `
                        -Raw `
                        -Encoding UTF8

                    $cleanJson =
                        $rawJson -replace '(?s)/\*.*?\*/', ''

                    $jsonData =
                        $cleanJson |
                        ConvertFrom-Json `
                            -ErrorAction Stop

                    $regionValue =
                        $jsonData.AWSConfiguration.SecretManagerRegionEndpointName

                    if (-not $regionValue) {

                        $status = "FAILED"

                        $value = "Missing in JSON"
                    }
                    elseif ($expectedRegion -eq "UNKNOWN") {

                        if (
                            $regionValue -in
                            $hostnameRegionMap.Values
                        ) {

                            $status = "PASSED"

                            $value = $regionValue
                        }
                        else {

                            $status = "FAILED"

                            $value =
                                "Unknown server region & invalid JSON value: $regionValue"
                        }
                    }
                    elseif ($regionValue -eq $expectedRegion) {

                        $status = "PASSED"

                        $value = $regionValue
                    }
                    else {

                        $status = "FAILED"

                        $value =
                            "Found: $regionValue | Expected: $expectedRegion"
                    }
                }
                catch {

                    $status = "FAILED"

                    $value =
                        "Error parsing JSON: $($_.Exception.Message)"
                }
            }
            else {

                $status = "FAILED"

                $value = "JSON File Not Found"
            }

            $results += [PSCustomObject]@{
                Check  = "SecretManagerRegionEndpointName"
                Value  = $value
                Status = $status
            }

            # ==========================================================
            # APPPOOL VALIDATION
            # ==========================================================

            Import-Module WebAdministration -ErrorAction Stop

            $Computername = $env:COMPUTERNAME

            $Locations = @(
                "PODRedirectService"
            )

            $ExpectedAppPools = @{
                "PODRedirectService" = "APIHUB"
            }

            if ($Locations.Count -eq 0) {

                $results += [PSCustomObject]@{
                    Check  = "AppPool"
                    Value  = ""
                    Status =
                        "No relevant IIS sites for this server ($Computername)"
                }
            }
            else {

                foreach ($Location in $Locations) {

                    try {

                        if (Test-Path "IIS:\Sites\$Location") {

                            $site =
                                Get-Item "IIS:\Sites\$Location"

                            $appPoolName =
                                $site.ApplicationPool

                            $expectedAppPool =
                                $ExpectedAppPools[$Location]

                            if ($appPoolName -eq $expectedAppPool) {

                                $status = "PASSED"
                            }
                            else {

                                $status =
                                    "FAILED (Expected: $expectedAppPool)"
                            }
                        }
                        else {

                            $status =
                                "WARNING (Site Not Found)"

                            $appPoolName = ""
                        }
                    }
                    catch {

                        $status =
                            "ERROR: $($_.Exception.Message)"

                        $appPoolName = ""
                    }

                    $results += [PSCustomObject]@{
                        Check  = "AppPool Validate"
                        Value  = $appPoolName
                        Status = $status
                    }
                }
            }

            # ==========================================================
            # SITE PROTOCOL VALIDATION
            # ==========================================================

            $ConfirmPreference = 'High'

            $Locations = @(
                "PODRedirectService"
            )

            foreach ($Location in $Locations) {

                $status = ""

                $protocols = ""

                try {

                    if (-not (Test-Path "IIS:\Sites\$Location")) {

                        $status =
                            "WARNING: Site Not Found"

                        $protocols = "N/A"
                    }
                    else {

                        $Bindings =
                            Get-WebBinding `
                                -Name $Location `
                                -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty protocol

                        if (-not $Bindings) {

                            $protocols = "None"

                            $status =
                                "FAILED: No bindings found"
                        }
                        else {

                            $protocols =
                                (
                                    $Bindings |
                                    Sort-Object -Unique |
                                    ForEach-Object {
                                        $_.ToUpper()
                                    }
                                ) -join "/"

                            $hasHttp =
                                $Bindings |
                                Where-Object {
                                    $_ -ieq "http"
                                }

                            $hasHttps =
                                $Bindings |
                                Where-Object {
                                    $_ -ieq "https"
                                }

                            if ($hasHttp -and $hasHttps) {

                                $status = "PASSED"
                            }
                            elseif ($hasHttp) {

                                $status = "WARNING: Only HTTP"
                            }
                            elseif ($hasHttps) {

                                $status = "WARNING: Only HTTPS"
                            }
                            else {

                                $status =
                                    "FAILED: Unknown protocols"
                            }
                        }
                    }
                }
                catch {

                    $status =
                        "ERROR: $($_.Exception.Message)"

                    $protocols = "N/A"
                }

                $results += [PSCustomObject]@{
                    Check  = "Site Protocols"
                    Value  = $protocols
                    Status = $status
                }
            }

            # ==========================================================
            # APIHUB URL VALIDATION
            # ==========================================================

            try {

                $token =
                    Invoke-RestMethod `
                        -Method PUT `
                        -Uri "http://169.254.169.254/latest/api/token" `
                        -Headers @{
                            "X-aws-ec2-metadata-token-ttl-seconds" = "21600"
                        }

                $identity =
                    Invoke-RestMethod `
                        -Uri "http://169.254.169.254/latest/dynamic/instance-identity/document" `
                        -Headers @{
                            "X-aws-ec2-metadata-token" = $token
                        }

                $Region = $identity.region

                $InstanceId = $identity.instanceId
            }
            catch {

                $results += [PSCustomObject]@{
                    Check  = "APIHUB URL Check"
                    Value  = "Error fetching EC2 metadata"
                    Status = "FAILED"
                }

                return
            }

            # ==========================================================
            # GET INSTANCE TAGS
            # ==========================================================

            try {

                $AWSVariables =
                    aws ec2 describe-instances `
                        --instance-ids $InstanceId `
                        --region $Region |
                    ConvertFrom-Json
            }
            catch {

                $results += [PSCustomObject]@{
                    Check  = "APIHUB URL Check"
                    Value =
                        "Error describing instance: $($_.Exception.Message)"
                    Status = "FAILED"
                }

                return
            }

            $Tags =
                $AWSVariables.Reservations[0].Instances[0].Tags

            $EnvironmentName =
                (
                    $Tags |
                    Where-Object {
                        $_.Key -ieq 'Environment'
                    } |
                    Select-Object -First 1
                ).Value

            $Stack =
                (
                    $Tags |
                    Where-Object {
                        $_.Key -ieq 'Stack'
                    } |
                    Select-Object -First 1
                ).Value

            $EnvironmentName = if ($EnvironmentName) {

                $EnvironmentName.ToUpper().Trim()
            }
            else {

                "QA"
            }

            $Stack = if ($Stack) {

                $Stack.ToLower().Trim()
            }
            else {

                ""
            }

            Write-Host "EnvironmentName = [$EnvironmentName]"

            Write-Host "Stack = [$Stack]"

            # ==========================================================
            # APIHUB URL BASED ON STACK
            # ==========================================================

            if ($Stack -eq "blue") {

                $APIHUBURL = switch ($EnvironmentName) {

                    "PATUAT" {
                        "https://apihub.patuat-blue-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "PATQA" {
                        "https://apihub.patqa-blue-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "PERF" {
                        "https://apihub.perf-blue-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "QA" {
                        "https://apihub.qa-blue-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "DEV" {
                        "https://apihub.dev-blue-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "UAT" {
                        "https://apihub.uat-blue-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "PROD" {
                        "https://apihub.cc-ss.infra.marcus.com/index.html"
                    }

                    default {
                        $null
                    }
                }
            }
            elseif ($Stack -eq "green") {

                $APIHUBURL = switch ($EnvironmentName) {

                    "PATUAT" {
                        "https://apihub.patuat-green-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "PATQA" {
                        "https://apihub.patqa-green-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "PERF" {
                        "https://apihub.perf-green-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "QA" {
                        "https://apihub.qa-green-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "DEV" {
                        "https://apihub.dev-green-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "UAT" {
                        "https://apihub.uat-green-us-east-1.cc-ss.infra.marcus.com/index.html"
                    }

                    "PROD" {
                        "https://apihub.cc-ss.infra.marcus.com/index.html"
                    }

                    default {
                        $null
                    }
                }
            }
            else {

                $APIHUBURL = switch ($EnvironmentName) {

                    "PATUAT" {
                        "https://apihub.patuat.cc-ss.infra.marcus.com/index.html"
                    }

                    "PATQA" {
                        "https://apihub.patqa.cc-ss.infra.marcus.com/index.html"
                    }

                    "PERF" {
                        "https://apihub.perf.cc-ss.infra.marcus.com/index.html"
                    }

                    "QA" {
                        "https://apihub.qa.cc-ss.infra.marcus.com/index.html"
                    }

                    "DEV" {
                        "https://apihub.dev.cc-ss.infra.marcus.com/index.html"
                    }

                    "UAT" {
                        "https://apihub.uat.cc-ss.infra.marcus.com/index.html"
                    }

                    "PROD" {
                        "https://apihub.cc-ss.infra.marcus.com/index.html"
                    }

                    default {
                        $null
                    }
                }
            }

            if (-not $APIHUBURL) {

                $results += [PSCustomObject]@{
                    Check  = "APIHUB URL Check"
                    Value  = "Unknown environment: $EnvironmentName"
                    Status = "FAILED"
                }

                return
            }

            # ==========================================================
            # CHECK APIHUB URL
            # ==========================================================

            try {

                $response =
                    Invoke-WebRequest `
                        -Uri $APIHUBURL `
                        -UseBasicParsing `
                        -TimeoutSec 120 `
                        -ErrorAction Stop

                if ($response.StatusCode -eq 200) {

                    $urlStatus = "PASSED"

                    $urlValue = "HTTP 200 OK"
                }
                else {

                    $urlStatus = "FAILED"

                    $urlValue =
                        "HTTP Status Code: $($response.StatusCode)"
                }
            }
            catch {

                $urlStatus = "FAILED"

                $urlValue =
                    "Error: $($_.Exception.Message)"
            }

            $results += [PSCustomObject]@{
                Check  = "APIHUB URL Check"
                Value  = $urlValue
                Status = $urlStatus
            }

            # ==========================================================
            # IIS CERT EXPIRATION CHECK
            # ==========================================================

            Import-Module WebAdministration

            $now = Get-Date

            $warningDays = 30

            $sites = Get-ChildItem IIS:\Sites

            foreach ($site in $sites) {

                $siteName = $site.Name

                $bindings = $site.Bindings.Collection

                foreach ($binding in $bindings) {

                    if ($binding.Protocol -eq 'https') {

                        if (-not $binding.CertificateHash) {

                            $results += [PSCustomObject]@{
                                Check =
                                    "Cert Expiry - $siteName ($($binding.BindingInformation))"

                                Value =
                                    "No certificate assigned"

                                Status = "FAILED"
                            }

                            continue
                        }

                        $bindingThumb =
                            ($binding.CertificateHash).Replace(" ", "")

                        $cert =
                            Get-ChildItem Cert:\LocalMachine\My |
                            Where-Object {
                                $_.Thumbprint -eq $bindingThumb
                            }

                        if ($cert) {

                            $expirationDate =
                                $cert.NotAfter

                            $expDateStr =
                                $expirationDate.ToString(
                                    'yyyy-MM-dd HH\:mm\:ss'
                                )

                            if ($expirationDate -le $now) {

                                $status = "FAILED"

                                $value =
                                    "Expired on: $expDateStr"
                            }
                            elseif (
                                $expirationDate -le
                                $now.AddDays($warningDays)
                            ) {

                                $status = "WARNING"

                                $value =
                                    "Expires soon: $expDateStr"
                            }
                            else {

                                $status = "PASSED"

                                $value =
                                    "Expires: $expDateStr"
                            }
                        }
                        else {

                            $status = "FAILED"

                            $value =
                                "Certificate not found"
                        }

                        $results += [PSCustomObject]@{
                            Check =
                                "Cert Expiry - $siteName ($($binding.BindingInformation))"

                            Value  = $value
                            Status = $status
                        }
                    }
                }
            }

            # ==========================================================
            # FOLDER CERTIFICATE EXPIRATION
            # ==========================================================

            $certFolder = 'D:\CertFolder'

            $currentDate = Get-Date

            $warningDays = 30

            if (Test-Path $certFolder) {

                Get-ChildItem `
                    -Path $certFolder `
                    -Filter *.cer |
                ForEach-Object {

                    try {

                        $cert =
                            New-Object System.Security.Cryptography.X509Certificates.X509Certificate2

                        $cert.Import($_.FullName)

                        $expiryDate =
                            $cert.NotAfter

                        $expDateStr =
                            $expiryDate.ToString(
                                'yyyy-MM-dd HH\:mm\:ss'
                            )

                        if ($expiryDate -le $currentDate) {

                            $status = "FAILED"

                            $value =
                                "Expired on: $expDateStr"
                        }
                        elseif (
                            $expiryDate -le
                            $currentDate.AddDays($warningDays)
                        ) {

                            $status = "WARNING"

                            $value =
                                "Expires soon: $expDateStr"
                        }
                        else {

                            $status = "PASSED"

                            $value =
                                "Expires: $expDateStr"
                        }

                        $results += [PSCustomObject]@{
                            Check =
                                "Folder Cert Expiry - $($_.Name)"

                            Value  = $value
                            Status = $status
                        }
                    }
                    catch {

                        $results += [PSCustomObject]@{
                            Check =
                                "Folder Cert Expiry - $($_.Name)"

                            Value =
                                "Error: $($_.Exception.Message)"

                            Status = "FAILED"
                        }
                    }
                }
            }
            else {

                $results += [PSCustomObject]@{
                    Check  = "Folder Cert Expiry"
                    Value  = "Folder not found: $certFolder"
                    Status = "FAILED"
                }
            }

            # ==========================================================
            # APIHUB DLL VERSION
            # ==========================================================

            $DllPath =
                "D:\ApiHub\PODRedirectService\clrjit.dll"

            if (Test-Path $DllPath) {

                try {

                    $versionInfo =
                        (Get-Item $DllPath).VersionInfo

                    $fileVersion =
                        $versionInfo.FileVersion.Split(" ")[0]

                    $results += [PSCustomObject]@{
                        Check  = "APIHUB DLL Version"
                        Value  = $fileVersion
                        Status = "PASSED"
                    }
                }
                catch {

                    $results += [PSCustomObject]@{
                        Check  = "APIHUB DLL Version"
                        Value =
                            "Error: $($_.Exception.Message)"
                        Status = "FAILED"
                    }
                }
            }
            else {

                $results += [PSCustomObject]@{
                    Check  = "APIHUB DLL Version"
                    Value =
                        "File not found: $DllPath"
                    Status = "FAILED"
                }
            }

            # ==========================================================
            # AUTH URL VALIDATION
            # ==========================================================

            $jsonFile =
                'D:\ApiHub\PODRedirectService\appsettings.json'

            $checkName = "AuthURL"

            $value = "Not Found"

            $status = "Error"

            if (Test-Path $jsonFile) {

                try {

                    $jsonContent =
                        Get-Content `
                            -Path $jsonFile `
                            -Raw `
                            -Encoding UTF8

                    if (
                        $jsonContent -match
                        '"AuthUrl"\s*:\s*"([^"]+)"'
                    ) {

                        $authUrl = $Matches[1]

                        $value = $authUrl

                        if (
                            $authUrl -match
                            '^(https?:\/\/[^\/]+)'
                        ) {

                            $baseUrl = $Matches[1]

                            try {

                                Invoke-WebRequest `
                                    -Uri $baseUrl `
                                    -Method GET `
                                    -UseBasicParsing `
                                    -TimeoutSec 120 `
                                    -ErrorAction Stop |
                                Out-Null

                                $status = "PASSED"
                            }
                            catch {

                                if ($_.Exception.Response) {

                                    $status =
                                        [int]$_.Exception.Response.StatusCode
                                }
                                else {

                                    $status = "Unreachable"
                                }
                            }
                        }
                        else {

                            $status = "Invalid URL"
                        }
                    }
                    else {

                        $value = "AuthUrl Missing"

                        $status = "FAILED"
                    }
                }
                catch {

                    $value = "Error reading file"

                    $status = "FAILED"
                }
            }
            else {

                $value = "JSON File Missing"

                $status = "FAILED"
            }

            $results =
                $results |
                Where-Object {
                    $_.Check -ne $checkName
                }

            $results += [PSCustomObject]@{
                Check  = $checkName
                Value  = $value
                Status = $status
            }

            # ==========================================================
            # PODREDIRECTSERVICE SITE ACCESS
            # ==========================================================

            Import-Module WebAdministration -ErrorAction Stop

            $checkName =
                "PODRedirectService Site Access"

            $value = "Not Checked"

            $status = "FAILED"

            $location =
                "PODRedirectService"

            try {

                if (-not (Test-Path "IIS:\Sites\$location")) {

                    $value = "Site Not Found"

                    $status = "FAILED"
                }
                else {

                    $bindings =
                        (Get-IISSite $location).Bindings

                    $httpsBinding =
                        $bindings |
                        Where-Object {
                            $_.protocol -eq "https"
                        }

                    if (-not $httpsBinding) {

                        $value =
                            "No HTTPS Binding"

                        $status = "FAILED"
                    }
                    else {

                        $ipAddress =
                            $httpsBinding.bindingInformation.Split(':')[0]

                        if (
                            $ipAddress -eq "*" -or
                            [string]::IsNullOrWhiteSpace($ipAddress)
                        ) {

                            $ipAddress = "localhost"
                        }

                        $siteUrl =
                            "https://$ipAddress/Index.html"

                        $value = $siteUrl

                        try {

                            $response =
                                Invoke-WebRequest `
                                    -Uri $siteUrl `
                                    -TimeoutSec 120 `
                                    -UseBasicParsing `
                                    -ErrorAction Stop

                            if ($response.StatusCode -eq 200) {

                                $status = "PASSED"
                            }
                            else {

                                $status =
                                    "HTTP $($response.StatusCode)"
                            }
                        }
                        catch {

                            if ($_.Exception.Response) {

                                $status =
                                    "HTTP $([int]$_.Exception.Response.StatusCode)"
                            }
                            else {

                                $status = "Unreachable"
                            }
                        }
                    }
                }
            }
            catch {

                $value =
                    $_.Exception.Message

                $status = "FAILED"
            }

            $results =
                $results |
                Where-Object {
                    $_.Check -ne $checkName
                }

            $results += [PSCustomObject]@{
                Check  = $checkName
                Value  = $value
                Status = $status
            }

            # ==========================================================
            # DNS RESOLVER / SERVICE IP VALIDATION
            # ==========================================================

            $dnsHostName =
                "ccservices.corecard.com"

            $dnsResolverValue = ""

            $serviceIPValue = ""

            $dnsStatus = "FAILED"

            try {

                $dnsResolver = @(
                    Get-DnsClientServerAddress `
                        -AddressFamily IPv4 |
                    ForEach-Object {
                        $_.ServerAddresses
                    }
                ) |
                Where-Object {
                    $_
                }

                if ($dnsResolver) {

                    $dnsResolverValue =
                        $dnsResolver -join ", "
                }
                else {

                    $dnsResolverValue =
                        "DNS Resolver IP Not Found"
                }

                $serviceIPs = @(
                    Resolve-DnsName `
                        -Name $dnsHostName `
                        -Type A `
                        -ErrorAction Stop |
                    Where-Object {
                        $_.IPAddress
                    } |
                    Select-Object -ExpandProperty IPAddress
                )

                if ($serviceIPs) {

                    $serviceIPValue =
                        $serviceIPs -join ", "

                    $dnsStatus = "PASSED"
                }
                else {

                    $serviceIPValue =
                        "Service IP Not Found"

                    $dnsStatus = "FAILED"
                }
            }
            catch {

                $dnsStatus = "FAILED"

                $serviceIPValue =
                    "Error: $($_.Exception.Message)"
            }

            $results += [PSCustomObject]@{
                Check  = "DNS Resolver IP"
                Value  = $dnsResolverValue
                Status = $dnsStatus
            }

            $results += [PSCustomObject]@{
                Check  = "Service IP - $dnsHostName"
                Value  = $serviceIPValue
                Status = $dnsStatus
            }

            # ==========================================================
            # RETURN RESULTS
            # ==========================================================

            $results

            # ==========================================================
            # REMOTE SERVER VALIDATION END
            # ==========================================================
        }

        if ($ServerResults) {
            foreach ($item in $ServerResults) {
                if ($item) {
                    $item | Add-Member -MemberType NoteProperty -Name "PSComputerName" -Value $Server -Force
                }
            }
        }
        $AllResults += $ServerResults

        Write-Host ""
        Write-Host "Validation completed successfully for $Server" -ForegroundColor Green
    }
    catch {

        Write-Host ""
        Write-Host "Validation failed for $Server" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red

        $AllResults += [PSCustomObject]@{
            PSComputerName = $Server
            Check          = "WinRM Connection"
            Value          = $_.Exception.Message
            Status         = "FAILED"
        }
    }
}

# ======================================================================
# HTML REPORT
# ======================================================================

# Collect distinct servers maintaining input order
$DistinctServers = @()
if ($ServerObjects) {
    $DistinctServers = @($ServerObjects | Select-Object -ExpandProperty Name -Unique)
}
elseif ($ServerList) {
    $DistinctServers = @($ServerList | Select-Object -Unique)
}
else {
    $DistinctServers = @($AllResults | Where-Object { $_.PSComputerName } | Select-Object -ExpandProperty PSComputerName -Unique)
}
foreach ($srv in ($AllResults | Where-Object { $_.PSComputerName } | Select-Object -ExpandProperty PSComputerName -Unique)) {
    if ($srv -and ($DistinctServers -notcontains $srv)) {
        $DistinctServers += $srv
    }
}

# Normalize any host-specific IP bindings in check names like "Cert Expiry - Site (IP:Port:)" -> "Cert Expiry - Site"
foreach ($r in $AllResults) {
    if ($r.Check -match '^(Cert Expiry\s*-\s*[^(\r\n]+)\s*\(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:.*?\)$') {
        $r.Check = $Matches[1].Trim()
    }
}

# Collect all distinct validation checks in appearance order (excluding WinRM Connection unless it is the only check)
$DistinctChecks = [System.Collections.Generic.List[string]]::new()
foreach ($r in $AllResults) {
    if ($r.Check -and ($r.Check -ne "WinRM Connection") -and (-not $DistinctChecks.Contains($r.Check))) {
        $DistinctChecks.Add($r.Check)
    }
}
if ($DistinctChecks.Count -eq 0) {
    $DistinctChecks.Add("WinRM Connection")
}

$MasterHost = if ($DistinctServers) { $DistinctServers | Select-Object -First 1 } else { "MASTER" }

# Table 1: Master Host Header & Row (Expected Values)
$t1HeaderCells = foreach ($chk in $DistinctChecks) {
    $chkEsc = [System.Net.WebUtility]::HtmlEncode($chk)
    "<TD><B>$chkEsc</B></TD>"
}
$t1Header = "<TR bgcolor=gray align=center><TD><B>Master Host</B></TD>$($t1HeaderCells -join '')</TR>"

$t1MasterCells = foreach ($chk in $DistinctChecks) {
    $m = $AllResults | Where-Object { $_.PSComputerName -eq $MasterHost -and $_.Check -eq $chk } | Select-Object -First 1
    $rawVal = if ($m -and $m.Value) { "$($m.Value)".Trim() } else { "PASSED" }
    $dispVal = if ($rawVal.Length -gt 60) { [System.Net.WebUtility]::HtmlEncode($rawVal.Substring(0, 57) + "...") } else { [System.Net.WebUtility]::HtmlEncode($rawVal) }
    $titleEsc = [System.Net.WebUtility]::HtmlEncode($rawVal)
    "<TD align=center bgcolor=white title='$titleEsc'>$dispVal</TD>"
}
$t1MasterRow = "<TR align=center><TD><B>$($MasterHost.ToUpper())</B></TD>$($t1MasterCells -join '')</TR>"

# Table 2: WEB Server Header & Server Rows (Actual Values)
$t2HeaderCells = foreach ($chk in $DistinctChecks) {
    $chkEsc = [System.Net.WebUtility]::HtmlEncode($chk)
    "<TD><B>$chkEsc</B></TD>"
}
$t2Header = "<TR bgcolor=gray align=center><TD><B>WEB Server</B></TD>$($t2HeaderCells -join '')</TR>"

$t2Rows = foreach ($srv in $DistinctServers) {
    $winrmFail = $AllResults | Where-Object { $_.PSComputerName -eq $srv -and $_.Check -eq "WinRM Connection" -and "$($_.Status)".ToUpper() -eq "FAILED" } | Select-Object -First 1

    if ($winrmFail -and ($DistinctChecks[0] -ne "WinRM Connection")) {
        $errEsc = [System.Net.WebUtility]::HtmlEncode($winrmFail.Value)
        "<TR align=center>
            <TD><B>$($srv.ToUpper())</B></TD>
            <TD colspan='$($DistinctChecks.Count)' align=center bgcolor='LightSalmon' title='$errEsc'><strong>WinRM Connection Failed:</strong> $errEsc</TD>
        </TR>"
    }
    else {
        $rowCells = foreach ($chk in $DistinctChecks) {
            $match = $AllResults | Where-Object { $_.PSComputerName -eq $srv -and $_.Check -eq $chk } | Select-Object -Last 1
            if ($match) {
                $statusNorm = "$($match.Status)".Trim().ToUpper()
                $isMatch = ($statusNorm -in @("PASSED", "200", "WORKING", "TRUE", "OK", "MATCHED") -or $statusNorm -like "*PASSED*")
                $cellBg = if ($isMatch) { "white" } else { "LightSalmon" }
                
                $rawVal = if ($match.Value) { "$($match.Value)".Trim() } else { "$($match.Status)" }
                $dispVal = if ($rawVal.Length -gt 60) { [System.Net.WebUtility]::HtmlEncode($rawVal.Substring(0, 57) + "...") } else { [System.Net.WebUtility]::HtmlEncode($rawVal) }
                $titleEsc = [System.Net.WebUtility]::HtmlEncode($rawVal)

                "<TD align=center bgcolor='$cellBg' title='$titleEsc'>$dispVal</TD>"
            }
            else {
                "<TD align=center bgcolor='LightSalmon' title='Not Applicable / Not Reported'>-</TD>"
            }
        }
        "<TR align=center><TD><B>$($srv.ToUpper())</B></TD>$($rowCells -join '')</TR>"
    }
}

$html = @"
<HTML>
<HEAD>
<TITLE>APIHUB Validation Report - $timestamp</TITLE>
<style>
body {
    font-family: 'Microsoft Tai Le', 'Segoe UI', Arial, sans-serif;
    background-color: #ffffff;
    margin: 20px;
}
table {
    border-collapse: collapse;
    font-family: 'Microsoft Tai Le', 'Segoe UI', Arial, sans-serif;
    font-size: 12px;
    margin-bottom: 25px;
}
th, td {
    border: 1px solid #999;
    padding: 6px 10px;
    text-align: center;
    vertical-align: middle;
    white-space: nowrap;
}
</style>
</HEAD>
<BODY>
<font color="#4682B4" face="Microsoft Tai le">
<H2>$($EnvironmentName.ToUpper()) - $($Environmentpod.ToUpper()) - APIHUB Validation Report</H2>
<H3>PLEASE VERIFY BELOW TABLE VALUES AND COMPARE WITH EXPECTED VALUES</H3>
</font>
<div style="overflow-x: auto; margin-bottom: 25px;">
<Table border=1 cellpadding=0 cellspacing=0>
$t1Header
$t1MasterRow
</Table>
</div>

<font color="#4682B4" face="Microsoft Tai le">
<H4>APIHUB Website Validation Report - Server Count $($DistinctServers.Count)</H4>
</font>
<div style="overflow-x: auto; margin-bottom: 25px;">
<Table border=1 cellpadding=0 cellspacing=0>
$t2Header
$($t2Rows -join "`n")
</Table>
</div>
</BODY>
</HTML>
"@

# ======================================================================
# SAVE REPORT
# ======================================================================

$html |
    Out-File `
        -FilePath $htmlFile `
        -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "APIHUB validation completed." -ForegroundColor Green
Write-Host "HTML Report:" -ForegroundColor Green
Write-Host "$htmlFile" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Green

Invoke-Item $htmlFile