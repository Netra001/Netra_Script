######################################################################################################################
# FileSplitter Validation | DEVELOPED BY:: Mahendra Dwivedi
# Version 3.6 | FileSplitter Validation | Multi-Server Remoting Enabled
# Version3.7 :: AWS-based server discovery added | Netra Chettri | Date :: 07-Oct-2026
#======================================================================================================================

Clear-Host

# Clear all user-defined variables (excluding PowerShell internal ones)
Get-Variable | Where-Object {
    ($_.Options -band [System.Management.Automation.ScopedItemOptions]::Constant) -eq 0 -and
    $_.Name -notmatch '^PS(|Item|Cmd|Script|Version|Home|ISE|Console|Prompt)'
} | ForEach-Object {
    Remove-Variable -Name $_.Name -Force -ErrorAction SilentlyContinue
}

$Module = "File-Splitter"

# ======================================================================
# AWS SERVER DISCOVERY HELPER
# ======================================================================

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
    "us-east-1" { "e1" }
    "us-west-2" { "w2" }
    "eu-west-1" { "w1" }
    default     { $Region }
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

$AWSVariables = Get-AwsInstanceData `
    -Query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,Environment:Tags[?Key=='environment']|[0].Value,Stack:Tags[?Key=='stack']|[0].Value,Attribution:Tags[?Key=='attribution']|[0].Value,TypeTag:Tags[?Key=='Type']|[0].Value,Tags:Tags}" `
    -Filters $LocalServerFilters `
    -Region $Region `
    -Operation "fetching local instance '$InstanceId'"

if (-not $AWSVariables -or (-not $AWSVariables.Environment -and -not ($AWSVariables.Tags | Where-Object { $_.Key -ieq 'environment' }))) {
    Write-Host "ERROR: Could not resolve environment tags for local instance '$InstanceId' in region '$Region'." -ForegroundColor Red
    exit 1
}

$EnvironmentNameRaw = if ($AWSVariables.Environment) {
    $AWSVariables.Environment
} else {
    ($AWSVariables.Tags | Where-Object { $_.Key -ieq 'environment' } | Select-Object -First 1).Value
}
$EnvironmentName = $EnvironmentNameRaw.ToLower()

$Environmentattributon = if ($AWSVariables.Attribution) {
    $AWSVariables.Attribution.ToLower()
} else {
    $rawAttr = ($AWSVariables.Tags | Where-Object { $_.Key -ieq 'attribution' } | Select-Object -First 1).Value
    if ($rawAttr) { $rawAttr.ToLower() } else { "" }
}

$rawStack = if ($AWSVariables.Stack) {
    $AWSVariables.Stack
} else {
    ($AWSVariables.Tags | Where-Object { $_.Key -ieq 'stack' } | Select-Object -First 1).Value
}
$EnvironmentStack = if ($rawStack) { ($rawStack.ToLower())[0] } else { "" }
$StackFull = if ($rawStack) { $rawStack } else { $null }

# ======================================================================
# POD DETECTION
# ======================================================================

$Environmentpod = $null
$ResolvedPodTag = ($AWSVariables.Tags | Where-Object { $_.Key -ieq 'pod' } | Select-Object -First 1).Value

if (-not $ResolvedPodTag) {
    if ($Environmentattributon -eq "jazz") {
        $Environmentpod = $Environmentattributon
    }
    else {
        try {
            $S3bucketslist = aws s3 ls 2>&1
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
            elseif (($S3bucketslist -match "corecard-jazz-$EnvironmentName-$Region-config-files") -and ($Environmentattributon -eq "jazz")) {
                $Environmentpod = "jazz"
            }
        }
        catch {}
    }
}
else {
    $Environmentpod = $ResolvedPodTag.ToLower()
}

if (-not $Environmentpod) {
    $Environmentpod = "unknown"
}

# ======================================================================
# DISCOVER FILESPLITTER SERVERS
# ======================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Discovering FileSplitter Servers" -ForegroundColor Cyan
Write-Host "Environment : $EnvironmentNameRaw" -ForegroundColor Cyan
Write-Host "Stack       : $StackFull" -ForegroundColor Cyan
Write-Host "Pod         : $Environmentpod" -ForegroundColor Cyan
Write-Host "Region      : $Region" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Detect Type tag value from local instance
$localTypeTagVal = if ($AWSVariables.TypeTag) { $AWSVariables.TypeTag } else {
    ($AWSVariables.Tags | Where-Object { $_.Key -ieq 'Type' -or $_.Key -ieq 'role' -or $_.Key -ieq 'module' } | Select-Object -First 1).Value
}

$typeCandList = @("filesplitter", "File-Splitter", "FileSplitter", "fs")
if ($localTypeTagVal) {
    $typeCandList = @($localTypeTagVal) + $typeCandList
}
$typeCandList = @($typeCandList | Select-Object -Unique)

$ServerFilters = @(
    @{
        Name   = "instance-state-name"
        Values = @("running")
    }
    @{
        Name   = "tag:Type"
        Values = $typeCandList
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

$DiscoveredInstances = Get-AwsInstanceData `
    -Query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,PrivateDnsName:PrivateDnsName,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,InstanceId:InstanceId,SecurityGroups:SecurityGroups[*].GroupId}" `
    -Filters $ServerFilters `
    -Region $Region `
    -Operation "fetching FileSplitter servers"

# Fallback: if no instances found with tag:Type, try Name wildcard matching
if (-not $DiscoveredInstances -or $DiscoveredInstances.Count -eq 0) {
    Write-Host "Notice: No instances found with tag:Type ($($typeCandList -join ', ')). Trying Name tag fallback..." -ForegroundColor Yellow
    $FallbackFilters = @(
        @{
            Name   = "instance-state-name"
            Values = @("running")
        }
        @{
            Name   = "tag:environment"
            Values = @($EnvironmentNameRaw)
        }
        @{
            Name   = "availability-zone"
            Values = @("*")
        }
        @{
            Name   = "tag:Name"
            Values = @("*fs*", "*filesplitter*", "*FileSplitter*")
        }
    )
    if ($StackFull) {
        $FallbackFilters += @{
            Name   = "tag:stack"
            Values = @($StackFull)
        }
    }

    $DiscoveredInstances = Get-AwsInstanceData `
        -Query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,PrivateDnsName:PrivateDnsName,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,InstanceId:InstanceId,SecurityGroups:SecurityGroups[*].GroupId}" `
        -Filters $FallbackFilters `
        -Region $Region `
        -Operation "fetching FileSplitter servers via Name fallback"
}

# Guarantee local instance is in the list
if (-not $DiscoveredInstances -or $DiscoveredInstances.Count -eq 0) {
    Write-Host "Notice: Auto-discovery returned 0 instances; adding local instance '$ThisServer'." -ForegroundColor Yellow
    $DiscoveredInstances = @([PSCustomObject]@{
        Name           = if ($AWSVariables.Name) { $AWSVariables.Name } else { $ThisServer }
        IpAddress      = $AWSVariables.IpAddress
        PrivateDnsName = $null
        InstanceId     = $InstanceId
        SecurityGroups = $null
    })
}

$ServerObjects = @(
    $DiscoveredInstances |
    Select-Object `
        @{n = "Name"; e = { $_.Name } },
        @{n = "IpAddress"; e = { $_.IpAddress } },
        @{n = "PrivateDnsName"; e = { $_.PrivateDnsName } },
        @{n = "InstanceId"; e = { $_.InstanceId } },
        @{n = "SecurityGroups"; e = { $_.SecurityGroups } },
        @{n = "serial"; e = {
            $Name = $_.Name
            if ($Name -match '(\d+)$') {
                [double]$matches[1]
            }
            elseif ($Name -match [regex]::Escape("$EnvironmentName$EnvironmentStack")) {
                $Remaining = ($Name -split [regex]::Escape("$EnvironmentName$EnvironmentStack"))[1]
                $Number = $Remaining -replace "[^0-9]", ""
                if ($Number) { [double]$Number } else { [double]::MaxValue }
            }
            else {
                [double]::MaxValue
            }
        } } |
    Sort-Object -Property serial
)

$ServerList = @($ServerObjects.Name)

Write-Host ""
Write-Host "Discovered FileSplitter Servers:" -ForegroundColor Green
$ServerObjects | ForEach-Object {
    Write-Host "  $($_.Name) (IP: $($_.IpAddress))" -ForegroundColor Green
}

if (-not $ServerObjects) {
    Write-Host ""
    Write-Host "No FileSplitter servers found for the given criteria. Exiting..." -ForegroundColor Red
    exit 1
}

# ======================================================================
# WINRM & HOST RESOLUTION HELPERS
# ======================================================================

function Test-PortFast {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,

        [int]$Port = 5985,

        [int]$TimeoutMs = 2500
    )

    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($Address, $Port, $null, $null)
        $wh = $iar.AsyncWaitHandle
        if (-not $wh.WaitOne($TimeoutMs, $false)) {
            $tcp.Close()
            return $false
        }
        $tcp.EndConnect($iar)
        $tcp.Close()
        return $true
    }
    catch {
        if ($tcp) { try { $tcp.Close() } catch {} }
        return $false
    }
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
    $TargetInstanceId = if ($ServerTarget.InstanceId) { $ServerTarget.InstanceId } else { $null }

    if ((-not $ServerIP -or -not $TargetInstanceId) -and $DiscoveredInstances) {
        $matchingInst = $DiscoveredInstances | Where-Object { $_.Name -ieq $ServerName } | Select-Object -First 1
        if ($matchingInst) {
            if (-not $ServerIP) { $ServerIP = $matchingInst.IpAddress }
            if (-not $ServerPrivateDns) { $ServerPrivateDns = $matchingInst.PrivateDnsName }
            if (-not $TargetInstanceId) { $TargetInstanceId = $matchingInst.InstanceId }
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

    try {
        & winrm set winrm/config/client '@{TrustedHosts="*"}' 2>$null
    }
    catch {}

    # ---------------------------------------------------------------
    # Build candidate endpoints to connect to
    # ---------------------------------------------------------------
    $Candidates = @()

    # 1. AWS Private IP Address (Direct connection fetched from EC2 - no DNS or hosts file needed)
    if ($ServerIP) {
        $Candidates += [PSCustomObject]@{ Address = $ServerIP; Type = "AWS Private IP" }
    }

    # 2. Short Hostname
    if ($ServerName -and ($Candidates.Address -notcontains $ServerName)) {
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

    # 4. Connection-specific DNS suffix FQDNs
    try {
        $suffixes = @()
        $suffixes += (Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue).SuffixSearchList
        $suffixes += (Get-DnsClient -ErrorAction SilentlyContinue | Where-Object ConnectionSpecificSuffix | Select-Object -ExpandProperty ConnectionSpecificSuffix)
        foreach ($suf in ($suffixes | Where-Object { $_ } | Select-Object -Unique)) {
            $fqdnCand = "$ServerName.$suf"
            if ($Candidates.Address -notcontains $fqdnCand) {
                $Candidates += [PSCustomObject]@{ Address = $fqdnCand; Type = "DNS Suffix FQDN" }
            }
        }
    }
    catch {}

    # 5. DNS-resolved name (via Resolve-DnsName)
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

    # 6. AWS Private DNS Name (e.g. ip-10-x-x-x.ec2.internal)
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

        # Fast TCP pre-check: ensure port 5985 is open before calling Invoke-Command
        $port5985Open = Test-PortFast -Address $addr -Port 5985 -TimeoutMs 2500
        $port5986Open = $false

        if (-not $port5985Open) {
            # Test if HTTPS port 5986 is available
            $port5986Open = Test-PortFast -Address $addr -Port 5986 -TimeoutMs 1500
            if (-not $port5986Open) {
                $skipMsg = "Port 5985/5986 unreachable or hostname unresolvable (timed out after 2.5s)"
                Write-Host "WinRM skipped via $type ($addr): $skipMsg" -ForegroundColor Yellow
                $attemptErrors += "[$type - $addr]: $skipMsg"
                continue
            }
        }

        $useSsl = $port5986Open -and (-not $port5985Open)
        $authList = if ($type -eq "AWS Private IP" -or ($addr -match '^\d{1,3}(\.\d{1,3}){3}$')) {
            @("Negotiate", "Default")
        } else {
            @("Default", "Negotiate")
        }

        $connSuccess = $false
        $lastError = ""

        foreach ($authMode in $authList) {
            try {
                $icParams = @{
                    ComputerName  = $addr
                    SessionOption = $SessionOption
                    ErrorAction   = "Stop"
                    ScriptBlock   = $ScriptBlock
                }
                if ($authMode -ne "Default") {
                    $icParams["Authentication"] = $authMode
                }
                if ($useSsl) {
                    $icParams["UseSSL"] = $true
                }

                $remoteResults = Invoke-Command @icParams

                Write-Host "WinRM connection successful to '$ServerName' via $type ($addr) [Auth: $authMode]!" -ForegroundColor Green

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
                $lastError = $_.Exception.Message
                Write-Host "  -> Attempt with Auth '$authMode' failed: $lastError" -ForegroundColor Yellow
                if ($lastError -notmatch "authentication|credentials|TrustedHosts|Kerberos|NTLM|access is denied|logon|security") {
                    break
                }
            }
        }

        $attemptErrors += "[$type - $addr]: $lastError"
    }

    # ---------------------------------------------------------------
    # Diagnostics if all candidates failed
    # ---------------------------------------------------------------
    $diagTarget = if ($ServerIP) { $ServerIP } else { $ServerName }
    $port5985Open = Test-PortFast -Address $diagTarget -Port 5985 -TimeoutMs 2000
    $port5985Status = if ($port5985Open) {
        "Port 5985 is OPEN (network path reachable; issue is WinRM authentication, credentials, or LocalAccountTokenFilterPolicy)"
    } else {
        "Port 5985 is BLOCKED / UNREACHABLE (check AWS Security Group inbound 5985 and remote Windows Firewall)"
    }

    $awsSgDiag = ""
    if ($TargetInstanceId -and $Region) {
        try {
            $instDesc = aws ec2 describe-instances `
                --instance-ids $TargetInstanceId `
                --region $Region `
                --query "Reservations[0].Instances[0].{SecurityGroups:SecurityGroups[*].GroupId,SubnetId:SubnetId}" 2>$null |
                ConvertFrom-Json
            if ($instDesc -and $instDesc.SecurityGroups) {
                $sgList = @($instDesc.SecurityGroups) -join ", "
                $awsSgDiag = "Target Instance: $TargetInstanceId | Security Groups: $sgList"

                $sgRules = aws ec2 describe-security-groups `
                    --group-ids @($instDesc.SecurityGroups) `
                    --region $Region `
                    --query "SecurityGroups[*].IpPermissions[?FromPort<=``5985`` && ToPort>=``5985`` || IpProtocol==``-1``]" 2>$null |
                    ConvertFrom-Json
                if (-not $sgRules -or $sgRules.Count -eq 0) {
                    $awsSgDiag += " [ALERT: Inbound rule for Port 5985 is MISSING in target Security Group!]"
                }
            }
        }
        catch {}
    }

    $allErrorsStr = $attemptErrors -join " | "
    $fullDiag = "$port5985Status"
    if ($awsSgDiag) {
        $fullDiag += " | $awsSgDiag"
    }

    Write-Host ""
    Write-Host "Diagnostic Summary for $ServerName :" -ForegroundColor Red
    Write-Host "  $fullDiag" -ForegroundColor Red
    Write-Host ""
    Write-Host "Remediation Steps:" -ForegroundColor Yellow
    Write-Host "  1. If Port 5985 is BLOCKED: In AWS Console -> EC2 -> Security Groups, add Inbound Rule -> Type: Custom TCP, Port: 5985, Source: $($LocalIPs -join ', ')/32 (or VPC CIDR)." -ForegroundColor Yellow
    Write-Host "  2. If running non-elevated: Open PowerShell using 'Run as Administrator'." -ForegroundColor Yellow
    Write-Host "  3. On remote server '$ServerName': Ensure WinRM service is running and execute: winrm quickconfig -q" -ForegroundColor Yellow

    throw "WinRM connection failed for '$ServerName'. Attempts: $allErrorsStr. Diagnostics: $fullDiag"
}

# ======================================================================
# WINRM SESSION OPTIONS & OUTPUT PATH
# ======================================================================

$option = New-PSSessionOption `
    -ProxyAccessType NoProxyServer `
    -OpenTimeout 20000 `
    -OperationTimeout 120000

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$htmlPath = "C:\Temp\FileSplitterValidation_$timestamp.html"

if (-not (Test-Path "C:\Temp")) {
    New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
}


# ======================================================================
# MULTI-SERVER VALIDATION EXECUTION
# ======================================================================

$AllResults = @()
$AllScheduledTasks = @()
$AllServices = @()

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

            # Remote unblock & preparation
            Get-ChildItem D:\ -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

            Clear-Host

            # ----------------- Scheduled Tasks -----------------
            $TaskMappings = @(
                @{ Name = "ACHDownloaderSplitter";            Dir = "D:\DBBSetup\MonitoringScript\FileSplitter\ACHDownloaderSplitter\" },
                @{ Name = "BillPayPaymentDownloaderSplitter"; Dir = "D:\DBBSetup\MonitoringScript\FileSplitter\BillPayDownloaderSplitter\" },
                @{ Name = "EmbossingDownloaderSplitter";      Dir = "D:\DBBSetup\MonitoringScript\FileSplitter\EmbossingDownloaderSplitter\" },
                @{ Name = "LockBoxDownloaderSplitter";        Dir = "D:\DBBSetup\MonitoringScript\FileSplitter\LockBoxDownloaderSplitter\" },
                @{ Name = "MCCustomFeedDownloaderSplitter";   Dir = "D:\DBBSetup\MonitoringScript\FileSplitter\MCCustomFeedDownloaderSplitter\" },
                @{ Name = "NACKFileDownloaderSplitter";       Dir = "D:\DBBSetup\MonitoringScript\FileSplitter\NACKFileDownloaderSplitter\" },
                @{ Name = "T284DownloaderSplitter";           Dir = "D:\DBBSetup\MonitoringScript\FileSplitter\T284DownloaderSplitter\" }
            )

            $localTaskResults = @()

            foreach ($taskInfo in $TaskMappings) {
                $taskName = $taskInfo.Name
                $expectedDir = $taskInfo.Dir

                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

                if ($task) {
                    $taskEnabled = if ($task.Settings.Enabled -eq $true) { "Enabled" } else { "Disabled" }
                    $triggerTime = "N/A"

                    if ($task.Triggers) {
                        $triggerTime = ($task.Triggers |
                            Sort-Object { [datetime]$_.StartBoundary } |
                            ForEach-Object {
                                $start = Get-Date $_.StartBoundary -Format "h:mm tt"
                                $schedule = "At $start every day"
                                $repeatText = ""

                                if ($_.Repetition.Interval) {
                                    $interval = [System.Xml.XmlConvert]::ToTimeSpan($_.Repetition.Interval)
                                    $duration = [System.Xml.XmlConvert]::ToTimeSpan($_.Repetition.Duration)
                                    $intervalMinutes = [int]$interval.TotalMinutes
                                    $durationMinutes = [int]$duration.TotalMinutes
                                    $repeatText = " - After triggered, repeat every $intervalMinutes minutes for a duration of $durationMinutes minutes."
                                }

                                "$schedule$repeatText"
                            }) -join "<br>"
                    }

                    $action = ($task.Actions | Where-Object { $_.Execute }) | Select-Object -First 1
                    $program = if ($action) { $action.Execute } else { "N/A" }
                    $arguments = if ($action) { $action.Arguments } else { "N/A" }
                    $workingDirectory = if ($action) { $action.WorkingDirectory } else { "N/A" }
                    $actualUser = $task.Principal.UserId

                    $fileVersion = "N/A"
                    try {
                        if ($program -and (Test-Path $program)) {
                            $fileVersion = (Get-Item $program).VersionInfo.FileVersion
                        }
                    } catch {
                        $fileVersion = "Error"
                    }

                    $localTaskResults += [PSCustomObject]@{
                        Category          = "ScheduledTask"
                        CheckName         = "Task - $taskName"
                        TaskName          = $taskName
                        Status            = $taskEnabled
                        User              = $actualUser
                        TriggerTime       = $triggerTime
                        Program           = $program
                        WorkingDirectory  = $workingDirectory
                        ExpectedDirectory = $expectedDir
                        FileVersion       = $fileVersion
                    }
                }
                else {
                    $localTaskResults += [PSCustomObject]@{
                        Category          = "ScheduledTask"
                        CheckName         = "Task - $taskName"
                        TaskName          = $taskName
                        Status            = "Missing"
                        User              = "N/A"
                        TriggerTime       = "N/A"
                        Program           = "N/A"
                        WorkingDirectory  = "N/A"
                        ExpectedDirectory = $expectedDir
                        FileVersion       = "N/A"
                    }
                }
            }

            # ----------------- FileSplitter Services -----------------
            $ServiceMappings = @(
                @{ Name = "PlatAmortizationFileSplitterService"; Path = "D:\DBBSetup\MonitoringScript\FileSplitter\AmortizationFileSplitter" },
                @{ Name = "PlatChargebackFileSplitterService";   Path = "D:\DBBSetup\MonitoringScript\FileSplitter\TQRFileSplitter" },
                @{ Name = "PlatEnrollmentFileSplitterService";   Path = "D:\DBBSetup\MonitoringScript\FileSplitter\EnrollmentFileSplitter" },
                @{ Name = "PlatIPMFileSplitterService";          Path = "D:\DBBSetup\MonitoringScript\FileSplitter\IPMFileSplitter" },
                @{ Name = "PlatT140FileSplitterService";         Path = "D:\DBBSetup\MonitoringScript\FileSplitter\T140FileSplitter" }
            )

            $localServiceResults = @()

            foreach ($svc in $ServiceMappings) {
                $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue

                if ($service) {
                    $actualUser = $service.StartName
                    $actualPath = $service.PathName.Trim('"')

                    $fileVersion = "N/A"
                    try {
                        $exePath = ($actualPath -split '\.exe')[0] + '.exe'
                        if (Test-Path $exePath) {
                            $fileVersion = (Get-Item $exePath).VersionInfo.FileVersion
                        }
                    } catch {
                        $fileVersion = "Error"
                    }

                    $localServiceResults += [PSCustomObject]@{
                        Category       = "Service"
                        CheckName      = "Service - $($svc.Name)"
                        ServiceName    = $service.Name
                        DisplayName    = $service.DisplayName
                        Status         = $service.State
                        LogOnAs        = $actualUser
                        ExecutablePath = $actualPath
                        ExpectedPath   = $svc.Path
                        FileVersion    = $fileVersion
                    }
                }
                else {
                    $localServiceResults += [PSCustomObject]@{
                        Category       = "Service"
                        CheckName      = "Service - $($svc.Name)"
                        ServiceName    = $svc.Name
                        DisplayName    = "Service Not Found"
                        Status         = "Not Found"
                        LogOnAs        = "N/A"
                        ExecutablePath = "N/A"
                        ExpectedPath   = $svc.Path
                        FileVersion    = "N/A"
                    }
                }
            }

            return @($localTaskResults + $localServiceResults)
        }

        # Segregate and store
        foreach ($res in $ServerResults) {
            $AllResults += [PSCustomObject]@{
                PSComputerName = $Server
                Check          = $res.CheckName
                Value          = $res.Status
                Status         = $res.Status
            }

            if ($res.Category -eq "ScheduledTask") {
                $AllScheduledTasks += $res
            }
            elseif ($res.Category -eq "Service") {
                $AllServices += $res
            }
        }

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
# AWS SECRETS VALIDATION (ENVIRONMENT-LEVEL)
# ======================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Validating AWS Secrets for Environment: $EnvironmentNameRaw" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$resultsSecretValidation = @()

$SecretsMap = @{
    "PATUAT" = @(
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "chargeback-patuat-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "chargeback-patuat-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "chargeback-patuat-corecardpassphrase" },
        @{ VariableName = "AuthorizationUserIdAWSKey"; KeyName = "patuat-AuthorizationUserId" },
        @{ VariableName = "AuthorizationPwdAWSKey"; KeyName = "patuat-AuthorizationPwd" },
        @{ VariableName = "SMTPConfigurationAWSKey"; KeyName = "ses-smtp-patuat-secret" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "ach-patuat-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "ach-patuat-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "ach-patuat-corecardpassphrase" },
        @{ VariableName = "SFTPPrivateKeyAWSKey"; KeyName = "ach-patuat-incoming-sshprivatekey" },
        @{ VariableName = "ClientFilePublicAWSKey"; KeyName = "ach-patuat-corecardpublickey" },
        @{ VariableName = "SFTPPrivateKeyAWSKey1"; KeyName = "PATUAT/mastercard-corecard-incoming-ssh-privatekey" },
        @{ VariableName = "BinRangeSecretsKey"; KeyName = "mastercard-patuat-bin-range" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "amortization-patuat-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "amortization-patuat-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "amortization-patuat-corecardpassphrase" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "ipm-patuat-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "ipm-patuat-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "ipm-patuat-corecardpassphrase" },
        @{ VariableName = "ClientFilePassPharseAWSKey"; KeyName = "ipm-patuat-corecardpassphrase" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "PATUAT/enrollment-corecard-publickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "PATUAT/enrollment-corecard-privatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "PATUAT/enrollment-corecard-passphrase" },
        @{ VariableName = "ClientFilePassPharseAWSKey"; KeyName = "PATUAT/enrollment-corecard-passphrase" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "billpay-patuat-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "billpay-patuat-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "billpay-patuat-corecardpassphrase" },
        @{ VariableName = "SFTPPrivateKeyAWSKey"; KeyName = "billpay-patuat-incoming-sshprivatekey" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "embossing-patuat-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "embossing-patuat-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "embossing-patuat-corecardpassphrase" },
        @{ VariableName = "SFTPPrivateKeyAWSKey"; KeyName = "embossing-patuat-incoming-sshprivatekey" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "lockbox-patuat-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "lockbox-patuat-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "lockbox-patuat-corecardpassphrase" },
        @{ VariableName = "SFTPPrivateKeyAWSKey"; KeyName = "lockbox-patuat-incoming-sshprivatekey" },
        @{ VariableName = "ClientFilePublicAWSKey"; KeyName = "mastercard-patuat-corecardpublickey" }
    )
    "PROD" = @(
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "chargeback-prod-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "chargeback-prod-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "chargeback-prod-corecardpassphrase" },
        @{ VariableName = "AuthorizationUserIdAWSKey"; KeyName = "prod-AuthorizationUserId" },
        @{ VariableName = "AuthorizationPwdAWSKey"; KeyName = "prod-AuthorizationPwd" },
        @{ VariableName = "SMTPConfigurationAWSKey"; KeyName = "ses-smtp-prod-secret" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "ach-prod-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "ach-prod-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "ach-prod-corecardpassphrase" },
        @{ VariableName = "SFTPPrivateKeyAWSKey"; KeyName = "ach-prod-incoming-sshprivatekey" },
        @{ VariableName = "ClientFilePublicAWSKey"; KeyName = "ach-prod-corecardpublickey" },
        @{ VariableName = "SFTPPrivateKeyAWSKey1"; KeyName = "PROD/mastercard-corecard-incoming-ssh-privatekey" },
        @{ VariableName = "BinRangeSecretsKey"; KeyName = "mastercard-prod-bin-range" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "amortization-prod-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "amortization-prod-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "amortization-prod-corecardpassphrase" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "ipm-prod-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "ipm-prod-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "ipm-prod-corecardpassphrase" },
        @{ VariableName = "ClientFilePassPharseAWSKey"; KeyName = "ipm-prod-corecardpassphrase" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "PROD/enrollment-corecard-publickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "PROD/enrollment-corecard-privatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "PROD/enrollment-corecard-passphrase" },
        @{ VariableName = "ClientFilePassPharseAWSKey"; KeyName = "PROD/enrollment-corecard-passphrase" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "billpay-prod-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "billpay-prod-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "billpay-prod-corecardpassphrase" },
        @{ VariableName = "SFTPPrivateKeyAWSKey"; KeyName = "billpay-prod-incoming-sshprivatekey" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "embossing-prod-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "embossing-prod-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "embossing-prod-corecardpassphrase" },
        @{ VariableName = "SFTPPrivateKeyAWSKey"; KeyName = "embossing-prod-incoming-sshprivatekey" },
        @{ VariableName = "OrignalFileEncryptionAWSKey"; KeyName = "lockbox-prod-corecardpublickey" },
        @{ VariableName = "OrignalFileDecryptionAWSKey"; KeyName = "lockbox-prod-corecardprivatekey" },
        @{ VariableName = "OrignalFilePassPharseAWSKey"; KeyName = "lockbox-prod-corecardpassphrase" },
        @{ VariableName = "SFTPPrivateKeyAWSKey"; KeyName = "lockbox-prod-incoming-sshprivatekey" },
        @{ VariableName = "ClientFilePublicAWSKey"; KeyName = "mastercard-prod-corecardpublickey" }
    )
}

$envUpper = $EnvironmentName.ToUpper()
$DeduplicatedSecrets = @{}
if ($SecretsMap.ContainsKey($envUpper)) {
    foreach ($secret in $SecretsMap[$envUpper]) {
        $compositeKey = "$($secret.VariableName.ToLower())|$($secret.KeyName.ToLower())"
        if (-not $DeduplicatedSecrets.ContainsKey($compositeKey)) {
            $DeduplicatedSecrets[$compositeKey] = $secret
        }
    }
}
elseif ($SecretsMap.ContainsKey("PATUAT")) {
    # Fallback to PATUAT list if exact env key is not defined
    foreach ($secret in $SecretsMap["PATUAT"]) {
        $compositeKey = "$($secret.VariableName.ToLower())|$($secret.KeyName.ToLower())"
        if (-not $DeduplicatedSecrets.ContainsKey($compositeKey)) {
            $DeduplicatedSecrets[$compositeKey] = $secret
        }
    }
}

foreach ($secret in $DeduplicatedSecrets.Values) {
    $isValid = $false
    try {
        if (Get-Command Get-SECSecretValue -ErrorAction SilentlyContinue) {
            $valueObj = Get-SECSecretValue -SecretId $secret.KeyName -Region $Region -ErrorAction Stop
            $isValid = ($valueObj.SecretString -or $valueObj.SecretBinary) -ne $null
        }
        else {
            $secOut = aws secretsmanager describe-secret --secret-id $secret.KeyName --region $Region 2>&1
            $isValid = ($LASTEXITCODE -eq 0)
        }
    }
    catch {
        Write-Warning "Secret $($secret.KeyName) could not be fetched: $_"
        $isValid = $false
    }

    $resultsSecretValidation += [PSCustomObject]@{
        Environment  = $envUpper
        VariableName = $secret.VariableName
        KeyName      = $secret.KeyName
        Status       = if ($isValid) { "Pass" } else { "Failed" }
    }
}

# ======================================================================
# GENERATE HTML REPORT
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

# Distinct check names for summary matrix
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

# Summary Table 1: Master Host Header & Expected Row
$t1HeaderCells = foreach ($chk in $DistinctChecks) {
    $chkEsc = [System.Net.WebUtility]::HtmlEncode($chk)
    "<TD><B>$chkEsc</B></TD>"
}
$t1Header = "<TR bgcolor=gray align=center><TD><B>Master Host</B></TD>$($t1HeaderCells -join '')</TR>"

$t1MasterCells = foreach ($chk in $DistinctChecks) {
    # Expected: "Enabled" for Tasks, "Running" for Services
    $expVal = if ($chk -like "Task*") { "Enabled" } else { "Running" }
    $dispVal = [System.Net.WebUtility]::HtmlEncode($expVal)
    "<TD align=center bgcolor=white title='$dispVal'>$dispVal</TD>"
}
$t1MasterRow = "<TR align=center><TD><B>$($MasterHost.ToUpper())</B></TD>$($t1MasterCells -join '')</TR>"

# Summary Table 2: FileSplitter Servers Header & Actual Rows
$t2HeaderCells = foreach ($chk in $DistinctChecks) {
    $chkEsc = [System.Net.WebUtility]::HtmlEncode($chk)
    "<TD><B>$chkEsc</B></TD>"
}
$t2Header = "<TR bgcolor=gray align=center><TD><B>FileSplitter Server</B></TD>$($t2HeaderCells -join '')</TR>"

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
                $isMatch = ($statusNorm -in @("ENABLED", "RUNNING", "PASSED", "OK", "TRUE"))
                $cellBg = if ($isMatch) { "white" } else { "LightSalmon" }
                $rawVal = "$($match.Value)".Trim()
                $dispVal = [System.Net.WebUtility]::HtmlEncode($rawVal)
                "<TD align=center bgcolor='$cellBg' title='$dispVal'>$dispVal</TD>"
            }
            else {
                "<TD align=center bgcolor='LightSalmon' title='Not Reported'>-</TD>"
            }
        }
        "<TR align=center><TD><B>$($srv.ToUpper())</B></TD>$($rowCells -join '')</TR>"
    }
}

# Detailed Section 1: Scheduled Tasks Rows
$taskRowsHtml = foreach ($r in $AllScheduledTasks) {
    $css = switch ($r.Status) {
        "Enabled"  { "PASSED" }
        "Disabled" { "WARNING" }
        "Missing"  { "FAILED" }
        default    { "FAILED" }
    }

    # User check formatting
    $userDisplay = if ($r.User -eq "ccgs-app-service") {
        "<span style='color:green;'>$($r.User)</span>"
    } else {
        "<span style='color:red;'>$($r.User)</span>"
    }

    # Working Directory formatting
    $workDirDisplay = if ($r.WorkingDirectory -eq $r.ExpectedDirectory) {
        "<span style='color:green;'>$($r.WorkingDirectory)</span>"
    } else {
        "<span style='color:red;'>$($r.WorkingDirectory)</span>"
    }

    "<tr>
        <td><b>$($r.PSComputerName.ToUpper())</b></td>
        <td>$($r.TaskName)</td>
        <td class='$css'>$($r.Status)</td>
        <td>$userDisplay</td>
        <td>$($r.TriggerTime)</td>
        <td>$($r.Program)</td>
        <td>$workDirDisplay</td>
        <td>$($r.FileVersion)</td>
    </tr>`n"
}

# Detailed Section 2: Services Rows
$serviceRowsHtml = foreach ($svc in $AllServices) {
    $css = if ($svc.Status -eq "Running") { "PASSED" } else { "FAILED" }

    # User check
    $userDisplay = if ($svc.LogOnAs -eq ".\ccgs-app-service") {
        "<span style='color:green;'>$($svc.LogOnAs)</span>"
    } else {
        "<span style='color:red;'>$($svc.LogOnAs)</span>"
    }

    # Path check
    $pathDisplay = if ($svc.ExecutablePath -like "$($svc.ExpectedPath)*") {
        "<span style='color:green;'>$($svc.ExecutablePath)</span>"
    } else {
        "<span style='color:red;'>$($svc.ExecutablePath)</span>"
    }

    "<tr>
        <td><b>$($svc.PSComputerName.ToUpper())</b></td>
        <td>$($svc.ServiceName)</td>
        <td>$($svc.DisplayName)</td>
        <td class='$css'>$($svc.Status)</td>
        <td>$userDisplay</td>
        <td>$pathDisplay</td>
        <td>$($svc.FileVersion)</td>
    </tr>`n"
}

# Detailed Section 3: AWS Secrets Rows
$secretRowsHtml = foreach ($secret in $resultsSecretValidation) {
    $css = if ($secret.Status -eq "Pass") { "PASSED" } else { "FAILED" }
    "<tr>
        <td>$($secret.Environment)</td>
        <td>$($secret.VariableName)</td>
        <td>$($secret.KeyName)</td>
        <td class='$css'>$($secret.Status)</td>
    </tr>`n"
}

$html = @"
<!DOCTYPE html>
<HTML>
<HEAD>
<meta charset='UTF-8'>
<TITLE>FileSplitter Validation Report - $timestamp</TITLE>
<style>
body {
    font-family: 'Microsoft Tai Le', 'Segoe UI', Arial, sans-serif;
    font-size: 13px;
    background-color: #ffffff;
    margin: 20px;
}
h2, h3, h4 {
    margin-top: 15px;
    margin-bottom: 8px;
}
table {
    border-collapse: collapse;
    font-family: 'Microsoft Tai Le', 'Segoe UI', Arial, sans-serif;
    font-size: 12px;
    margin-bottom: 25px;
    width: 100%;
}
th, td {
    border: 1px solid #999;
    padding: 6px 10px;
    text-align: left;
    vertical-align: middle;
}
th {
    background-color: #007ACC;
    color: white;
    font-weight: bold;
    text-align: center;
}
.matrix-table th, .matrix-table td {
    text-align: center;
    white-space: nowrap;
}
.PASSED {
    background-color: #d4edda;
    color: #155724;
    font-weight: bold;
    text-align: center;
}
.FAILED {
    background-color: #f8d7da;
    color: #721c24;
    font-weight: bold;
    text-align: center;
}
.WARNING {
    background-color: #fff3cd;
    color: #856404;
    font-weight: bold;
    text-align: center;
}
</style>
</HEAD>
<BODY>
<font color="#4682B4" face="Microsoft Tai le">
<H2>$($EnvironmentName.ToUpper()) - $($Environmentpod.ToUpper()) - FileSplitter Validation Report</H2>
<H3>PLEASE VERIFY BELOW TABLE VALUES AND COMPARE WITH EXPECTED VALUES</H3>
</font>

<!-- SUMMARY MATRIX: MASTER HOST EXPECTED -->
<div style="overflow-x: auto; margin-bottom: 25px;">
<Table class="matrix-table" border=1 cellpadding=0 cellspacing=0>
$t1Header
$t1MasterRow
</Table>
</div>

<!-- SUMMARY MATRIX: SERVERS ACTUAL -->
<font color="#4682B4" face="Microsoft Tai le">
<H4>FileSplitter Servers Status Summary - Server Count $($DistinctServers.Count)</H4>
</font>
<div style="overflow-x: auto; margin-bottom: 25px;">
<Table class="matrix-table" border=1 cellpadding=0 cellspacing=0>
$t2Header
$($t2Rows -join "`n")
</Table>
</div>

<!-- DETAILED SECTION 1: SCHEDULED TASKS -->
<font color="#4682B4" face="Microsoft Tai le">
<H3>1. Scheduled Task Validation (Detailed)</H3>
</font>
<div style="overflow-x: auto; margin-bottom: 25px;">
<Table border=1 cellpadding=0 cellspacing=0>
    <TR>
        <th>Server Name</th>
        <th>Task Name</th>
        <th>Status</th>
        <th>User</th>
        <th>Trigger Time</th>
        <th>Program/Script</th>
        <th>Working Directory</th>
        <th>File Version</th>
    </TR>
    $($taskRowsHtml -join "")
</Table>
</div>

<!-- DETAILED SECTION 2: SERVICES -->
<font color="#4682B4" face="Microsoft Tai le">
<H3>2. FileSplitter Services Validation (Detailed)</H3>
</font>
<div style="overflow-x: auto; margin-bottom: 25px;">
<Table border=1 cellpadding=0 cellspacing=0>
    <TR>
        <th>Server Name</th>
        <th>Service Name</th>
        <th>Display Name</th>
        <th>Status</th>
        <th>Log On As</th>
        <th>Executable Path</th>
        <th>File Version</th>
    </TR>
    $($serviceRowsHtml -join "")
</Table>
</div>

<!-- DETAILED SECTION 3: AWS SECRETS -->
<font color="#4682B4" face="Microsoft Tai le">
<H3>3. AWS Secrets Validation</H3>
</font>
<div style="overflow-x: auto; margin-bottom: 25px;">
<Table border=1 cellpadding=0 cellspacing=0>
    <TR>
        <th>Environment</th>
        <th>Variable Name</th>
        <th>Secret Key Name</th>
        <th>Status</th>
    </TR>
    $($secretRowsHtml -join "")
</Table>
</div>

</BODY>
</HTML>
"@

# Save and Open Report
$html | Out-File -FilePath $htmlPath -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "FileSplitter validation completed." -ForegroundColor Green
Write-Host "HTML Report:" -ForegroundColor Green
Write-Host "$htmlPath" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Green

Invoke-Item $htmlPath