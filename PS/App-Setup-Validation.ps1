######################################################################################################################
# App-Setup (SetupFile) Validation Script | Multi-Server EC2 Discovery
# DEVELOPED BY:: Netra Chettri
# Version 1.3 | EC2 Dynamic Discovery & Master Host Fetching Enabled
#======================================================================================================================

Clear-Host
$Module = "App-Setup"
$ServerTypes = 'svc', 'iss', 'aut', 'src', 'snk', 'awf', 'tnp', 'bat'
#$ServerTypes = 'svc','bat'
$ThisServer = (Hostname).ToLower()

# ----------------------------------------------------------------------
# 1. Region Detection
# ----------------------------------------------------------------------
if ($ThisServer -match 'e1') {
    $Region = "us-east-1"
    $ShortRegion = 'e1'
} elseif ($ThisServer -match 'w2') {
    $Region = "us-west-2"
    $ShortRegion = 'w2'
} else {
    Write-Host "Warning: Could not determine region from hostname '$ThisServer', defaulting to us-east-1" -ForegroundColor Yellow
    $Region = "us-east-1"
    $ShortRegion = 'e1'
}

# ----------------------------------------------------------------------
# 2. Existing Logic: Fetch Current Instance Tags & Environment Info
# ----------------------------------------------------------------------
$AWSVarialbesRaw = (aws ec2 describe-instances `
    --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,Environment:Tags[?Key=='environment']|[0].Value,Status:State.environment,Stack:Tags[?Key=='stack']|[0].Value,Status:State.stack,Attribution:Tags[?Key=='attribution']|[0].Value,Status:State.attribution,Pod:Tags[?Key=='pod']|[0].Value,Status:State.pod}" `
    --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='$ThisServer'" "Name=availability-zone,Values='*'" `
    --region $Region | ConvertFrom-Json)

$AWSVarialbes = if ($AWSVarialbesRaw -is [array]) { $AWSVarialbesRaw[0] } else { $AWSVarialbesRaw }

$EnvironmentName = if ($AWSVarialbes.Environment) { $AWSVarialbes.Environment.ToLower() } else { "" }
$Environmentattributon = if ($AWSVarialbes.Attribution) { $AWSVarialbes.Attribution.ToLower() } else { "" }
$EnvironmentStack = if ($AWSVarialbes.Stack) { ($AWSVarialbes.Stack.ToLower())[0] } else { "" }

Write-Host "Environment : $EnvironmentName" -ForegroundColor Cyan
Write-Host "Attribution : $Environmentattributon" -ForegroundColor Cyan
Write-Host "Stack       : $EnvironmentStack" -ForegroundColor Cyan

# Determine Pod (via Tag or S3 Buckets fallback)
if ([string]::IsNullOrEmpty($AWSVarialbes.Pod)) {
    if ($Environmentattributon -eq "jazz") {
        $Environmentpod = $Environmentattributon
    } else {
        try {
            $S3bucketslist = aws s3 ls 2>$null
            if ($S3bucketslist -match "corecard-pod2-$EnvironmentName-$Region-config-files") { $Environmentpod = "pod2" }
            elseif ($S3bucketslist -match "corecard-pod4-$EnvironmentName-$Region-config-files") { $Environmentpod = "pod4" }
            elseif ($S3bucketslist -match "corecard-pod5-$EnvironmentName-$Region-config-files") { $Environmentpod = "pod5" }
            elseif (($S3bucketslist -match "corecard-jazz-$EnvironmentName-$Region-config-files") -and ($Environmentattributon -eq "jazz")) { $Environmentpod = "jazz" }
            else { $Environmentpod = "unknown" }
        } catch {
            $Environmentpod = "unknown"
        }
    }
} else {
    $Environmentpod = $AWSVarialbes.Pod.ToLower()
}
Write-Host "Pod         : $Environmentpod" -ForegroundColor Cyan

# ----------------------------------------------------------------------
# Helper: Safe Serial Number Sorter (prevents cast exception on e.g. "g1")
# ----------------------------------------------------------------------
function Get-ServerSerial {
    param([string]$ServerName, [string]$SplitPrefix)
    if ($ServerName -match '(\d+)$') {
        return [double]$matches[1]
    }
    if ($SplitPrefix -and $ServerName -match [regex]::Escape($SplitPrefix)) {
        $rem = ($ServerName -split [regex]::Escape($SplitPrefix))[1]
        $num = $rem -replace '[^0-9]', ''
        if ($num) { return [double]$num }
    }
    return [double]::MaxValue
}

# ----------------------------------------------------------------------
# 3. Fetch Master Host Server from EC2
# ----------------------------------------------------------------------
$MasterServerType = $ServerTypes[0]
$MasterFilterPattern = "*$MasterServerType$ShortRegion$EnvironmentName$EnvironmentStack*"

Write-Host "`nFetching Master Host servers ($MasterServerType) from EC2..." -ForegroundColor Yellow

$MasterRawInstances = (aws ec2 describe-instances `
    --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name}" `
    --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='$MasterFilterPattern'" "Name=availability-zone,Values='*'" `
    --region $Region | ConvertFrom-Json)

$MasterHostObjects = @(
    $MasterRawInstances |
    Select-Object *, @{n = "serial"; e = { Get-ServerSerial -ServerName $_.Name -SplitPrefix "$EnvironmentName$EnvironmentStack" } } |
    Sort-Object -Property serial
)

$MasterHostList = @($MasterHostObjects.Name)
$MasterHostCandidate = $MasterHostObjects | Select-Object -First 1

# Check Master Host connectivity (Ping with WinRM port 5985 TCP fallback)
$isMasterAlive = $false
if ($MasterHostCandidate) {
    if (Test-Connection $MasterHostCandidate.Name -Quiet -Count 1 -ErrorAction SilentlyContinue) {
        $isMasterAlive = $true
    } else {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($MasterHostCandidate.IpAddress, 5985, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(2000, $false)) {
                $tcp.EndConnect($iar); $tcp.Close(); $isMasterAlive = $true
            } else { $tcp.Close() }
        } catch {}
    }
}

if ($isMasterAlive) {
    $MasterHost = $MasterHostCandidate.Name
    $MasterHostIP = $MasterHostCandidate.IpAddress
    Write-Host "Master Host (Primary)  - $MasterHost (IP: $MasterHostIP)" -ForegroundColor Green
} else {
    $MasterFallback = $MasterHostObjects | Select-Object -Last 1
    $MasterHost = if ($MasterFallback) { $MasterFallback.Name } else { $MasterHostCandidate.Name }
    $MasterHostIP = if ($MasterFallback) { $MasterFallback.IpAddress } else { $MasterHostCandidate.IpAddress }
    Write-Host "Master Host (Selected) - $MasterHost (IP: $MasterHostIP)" -ForegroundColor Yellow
}

# ----------------------------------------------------------------------
# 4. Fetch All Servers from EC2 for each ServerType in $ServerTypes
# ----------------------------------------------------------------------
Write-Host "`nFetching all servers across ServerTypes from EC2..." -ForegroundColor Yellow

$ServerListByType = @{}
$AllDiscoveredServers = @()

foreach ($sType in $ServerTypes) {
    $srvPattern = "*$sType$ShortRegion$EnvironmentName$EnvironmentStack*"
    
    $rawSrvList = (aws ec2 describe-instances `
        --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name}" `
        --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='$srvPattern'" "Name=availability-zone,Values='*'" `
        --region $Region | ConvertFrom-Json)

    # Fallback without stack letter if 0 instances matched
    if (-not $rawSrvList -or $rawSrvList.Count -eq 0) {
        $fallbackPattern = "*$sType$ShortRegion$EnvironmentName*"
        $rawSrvList = (aws ec2 describe-instances `
            --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name}" `
            --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='$fallbackPattern'" "Name=availability-zone,Values='*'" `
            --region $Region | ConvertFrom-Json)
    }

    $sortedServers = @(
        $rawSrvList |
        Select-Object *, @{n = "ServerType"; e = { $sType } }, @{n = "serial"; e = { Get-ServerSerial -ServerName $_.Name -SplitPrefix "$EnvironmentName$EnvironmentStack" } } |
        Sort-Object -Property serial
    )

    $ServerListByType[$sType] = $sortedServers
    $AllDiscoveredServers += $sortedServers

    Write-Host "  [$sType] Discovered ($($sortedServers.Count) servers):" -ForegroundColor Cyan
    foreach ($s in $sortedServers) {
        Write-Host "    -> $($s.Name) (IP: $($s.IpAddress))" -ForegroundColor DarkGray
    }
}

# ----------------------------------------------------------------------
# 5. Output Report Initialization
# ----------------------------------------------------------------------
$Outputreport = "<HTML><TITLE> $Module Validation Report </TITLE>
                 <BODY background-color:peachpuff>
                 <font color =""#4682B4"" face=""Microsoft Tai le"">
                 <H2>$($EnvironmentName.ToUpper()) - $($Environmentpod.ToUpper()) - $Module Validation Report</H2>
                 <H3>PLEASE VERIFY BELOW TABLE VALUES AND COMPARE WITH EXPECTED VALUES / VALIDATION SHEET</H3></font>
                 <Table border=1 cellpadding=0 cellspacing=0>"

$SetupFileList = @(
    "D:\DBBSetup\BatchScripts\CoreIssue\SetupCI.bat",
    "D:\DBBSetup\BatchScripts\CoreIssue\SetUp.py",
    "D:\DBBSetup\BatchScripts\CoreIssue\SetupCIPy.ini",
    "D:\DBBSetup\BatchScripts\CoreAuth\CoreAuthSetup.bat",
    "D:\DBBSetup\DSLs\CI\About.DSL",
    "D:\DBBSetup\DSLs\CoreAuth\About.DSL",
    "D:\CC_Runtime\appsys30.DSL",
    "D:\DBBSetup\BatchScripts\CoreIssue\RTM.config",
    "D:\DBBSetup\BatchScripts\CoreAuth\RTM.config"
)

$SetupCIEnvVarialbeList = 'SET DB_Server_NAME=', 'SET ReportsCoreAuthDBName=', 'SET EXECUTABLEPATH=', 'SET StatementDataQueueName=', 'SET emKMSdefaultMachines=', 'SET emThalesConnectionAddrBase=', 'SET SCALE_SERVER_HOST=', 'SET Enviroment=', 'SET ExperianSetup=', 'SET PlatPIIHubEnv=', 'SET PlatPIIHubTokenEnv=', 'SET PlatAutoRewardRedeem=', 'SET RelaxIssueStatusCheckForActivation=', 'SET DummyMmsApiResult=', 'SET UsePIIFromBearerForEmbossing=', 'SET InterestAlertByTNP=', 'SET PodActiveTQR4=', 'SET PlatModelScore=', 'SET DummyModelScore=', 'SET MultiPODEnabled_IPM=', 'SET TokenRefreshCall=', 'SET UseBhubFromBearerForEmbossing=', 'SET RptSrvrName_StlRcn=', 'SET MailSender_StlRcn=', 'SET MessageQueueService=', 'SET SQSRole=', 'SET SQSURL=', 'SET SQSS3Bucket=', 'SET SQSRegion=', 'SET SQSSTSlink=', 'SET SQSSTSRegion=', 'SET SQSS3Url=', 'SET SQSS3Region=', 'SET APIStore=', 'SET S3URL=', 'SET S3Role=' , 'SET S3BucketName=', 'SET S3Region=', 'SET S3STSUrl=', 'SET S3STSRegion=', 'SET S3URLAlert=', 'SET S3RegionAlert=', 'SET AWSRoleAlert=', 'SET SQSURLAlert=', 'SET SQSRegionAlert=', 'SET SQSCustomURL='
$SetUppyEnvVarialbeList = 'MailFrom =', 'MailTo =', 'RetailEnvironment =', 'RetailFileProcessingPOD =', 'RetailAWS_secret_name =', 'RetailAWS_region_name =', 'RetailSES_smtp_url', 'RetailAWSPort', 'POTBEnvironment =', 'EnvironmentName ='
$SetupCIPyEnvVarialbeList = 'POD =', 'EXECUTABLEPATH =', 'emKMSdefaultMachines =', 'emKMSdefaultMachinesDR =', 'DB_Server_NAME =', 'DB_DSN_NAME =', 'DB_Server_NAME_RPT', 'DB_DSN_NAME_RPT', 'ODBC_Driver =', 'Cnst_API_url =', 'ses_smtp_secret_name =', 'ses_smtp_url =', 'ses_region_name =', 'alert_email_sender =', 'BatchScripts =', 'CheckPIIData =', 'PIIHubEnv =', 'CBREmailFrom =', 'CBRNotifyEmail =', 'SqlOdbcDriver =', 'EnvironmentName =', 'RetailEnvironment =', 'POTBEnvironment ='
$CoreAuthSetupEnvVarialbeList = 'SET PrimaryDBServerODBCName=', 'SET EXECUTABLEPATH=', 'SET emKMSdefaultMachines=', 'SET emThalesConnectionAddrBase=', 'SET SCALE_SERVER_HOST=', 'SET Enviroment=', 'SET TLS12Required=', 'SET Environment=', 'SET ICANumber=', 'SET GSINumber=', 'SET NetworkManagementInformationcode=', 'SET CACertificate=', 'SET emThalesMonitorInterval=', 'SET emThalesCBTestInterval=', 'SET SendActivateSessionOnReconnect='
$CoreAuthRTM = 'RunTimeMode='
$CoreIssueRTM = 'RunTimeMode='
$AboutDSLVarialbeList = 'CreditProcessing '
$PlatformVersionVarialbeList = 'Application Release '

# ----------------------------------------------------------------------
# 6. Collect Baseline Hashes from Master Host
# ----------------------------------------------------------------------
$option = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 20000

Write-Host "`nCollecting baseline hashes from Master Host ($MasterHost)..." -ForegroundColor Cyan

$MasterResult = @()
$MasterResult += Invoke-Command -ComputerName $MasterHost -SessionOption $option -ErrorAction Continue -HideComputerName -ScriptBlock {

    $MasterHashSetupCI = (Get-FileHash D:\DBBSetup\BatchScripts\CoreIssue\SetupCI.bat -ErrorAction SilentlyContinue).Hash
    $MasterHashRunccCI = (Get-FileHash D:\DBBSetup\BatchScripts\CoreIssue\RunccCI.bat -ErrorAction SilentlyContinue).Hash
    $MasterHashSetupCIPy = (Get-FileHash D:\DBBSetup\BatchScripts\CoreIssue\SetupCIPy.ini -ErrorAction SilentlyContinue).Hash
    $MasterHashSetUp = (Get-FileHash D:\DBBSetup\BatchScripts\CoreIssue\SetUp.py -ErrorAction SilentlyContinue).Hash
    $MasterHashCoreAuthSetup = (Get-FileHash D:\DBBSetup\BatchScripts\CoreAuth\CoreAuthSetup.bat -ErrorAction SilentlyContinue).Hash
    $MasterHashRunccCoreAuth = (Get-FileHash D:\DBBSetup\BatchScripts\CoreAuth\RunccCoreAuth.bat -ErrorAction SilentlyContinue).Hash
    $MasterHashCoreIssueAboutDSL = (Get-FileHash D:\DBBSetup\DSLs\CI\About.DSL -ErrorAction SilentlyContinue).Hash
    $MasterHashCoreAuthAboutDSL = (Get-FileHash D:\DBBSetup\DSLs\CoreAuth\About.DSL -ErrorAction SilentlyContinue).Hash

    $MasterDSLsHash = $null
    (Get-ChildItem -Path D:\DBBSetup\DSLs\ -Recurse -Filter *.DSL -ErrorAction SilentlyContinue | Get-FileHash).Hash | ForEach-Object { $MasterDSLsHash += "$_" }
    $MasterDSLs_stream = [IO.MemoryStream]::new([byte[]][char[]]$MasterDSLsHash)
    $MasterDSLsHash = (Get-FileHash -InputStream $MasterDSLs_stream).Hash

    $MasterBatchScriptsHash = $null
    (Get-ChildItem -Path D:\DBBSetup\BatchScripts\ -Recurse -Filter *.bat -ErrorAction SilentlyContinue | Get-FileHash).Hash | ForEach-Object { $MasterBatchScriptsHash += "$_" }
    $MasterBatchScripts_stream = [IO.MemoryStream]::new([byte[]][char[]]$MasterBatchScriptsHash)
    $MasterBatchScriptsHash = (Get-FileHash -InputStream $MasterBatchScripts_stream).Hash

    $MasterPlatformVersionHash = (Get-FileHash D:\CC_runtime\appsys30.DSL -ErrorAction SilentlyContinue).Hash

    [PSCustomObject]@{
        MasterHashSetupCI           = "$($MasterHashSetupCI)"
        MasterHashRunccCI           = "$($MasterHashRunccCI)"
        MasterHashSetupCIPy         = "$($MasterHashSetupCIPy)"
        MasterHashSetUp             = "$($MasterHashSetUp)"
        MasterHashCoreAuthSetup     = "$($MasterHashCoreAuthSetup)"
        MasterHashRunccCoreAuth     = "$($MasterHashRunccCoreAuth)"
        MasterHashCoreIssueAboutDSL = "$($MasterHashCoreIssueAboutDSL)"
        MasterHashCoreAuthAboutDSL  = "$($MasterHashCoreAuthAboutDSL)"
        MasterDSLsHash              = "$($MasterDSLsHash)"
        MasterBatchScriptsHash      = "$($MasterBatchScriptsHash)"
        MasterPlatformVersionHash   = "$($MasterPlatformVersionHash)"
    }
}

$MasterHashSetupCI           = $MasterResult.MasterHashSetupCI
$MasterHashRunccCI           = $MasterResult.MasterHashRunccCI
$MasterHashSetupCIPy         = $MasterResult.MasterHashSetupCIPy
$MasterHashSetUp             = $MasterResult.MasterHashSetUp
$MasterHashCoreAuthSetup     = $MasterResult.MasterHashCoreAuthSetup
$MasterHashRunccCoreAuth     = $MasterResult.MasterHashRunccCoreAuth
$MasterHashCoreIssueAboutDSL = $MasterResult.MasterHashCoreIssueAboutDSL
$MasterHashCoreAuthAboutDSL  = $MasterResult.MasterHashCoreAuthAboutDSL
$MasterDSLsHash              = $MasterResult.MasterDSLsHash
$MasterBatchScriptsHash      = $MasterResult.MasterBatchScriptsHash
$MasterPlatformVersionHash   = $MasterResult.MasterPlatformVersionHash

# Extract Master Host Variable Table
$Outputreport += Invoke-Command -ComputerName $MasterHost -SessionOption $option -ErrorAction Continue -HideComputerName -ScriptBlock {
    param ($SetupFileList, $SetupCIEnvVarialbeList, $SetUppyEnvVarialbeList, $SetupCIPyEnvVarialbeList, $CoreAuthSetupEnvVarialbeList, $AboutDSLVarialbeList, $PlatformVersionVarialbeList, $CoreAuthRTM, $CoreIssueRTM)
    $MasterHostName = hostname

    function Get-LatestActiveMatch {
        param($Path, $Pattern)
        $allMatches = Select-String -Path $Path -Pattern $Pattern -ErrorAction SilentlyContinue
        if (-not $allMatches) { return $null }
        $activeMatches = $allMatches | Where-Object {
            $_.Line.TrimStart() -notmatch '^(REM\s|::|#|;|//)'
        }
        if ($activeMatches) { return ($activeMatches | Select-Object -Last 1) }
        else { return $null }
    }

    $OutputreportVarVal = $null
    foreach ($SetupFile in $SetupFileList) {
        $OutputreportVarVal += "<TR bgcolor=gray align=center><TD colspan=2><B>$MasterHostName - $SetupFile</B></TD></TR>
                                <TR bgcolor=silver align=center>
                                <TD><B>Variable Name</B></TD>
                                <TD><B>Value</B></TD>
                                </TR>"

        if ($SetupFile.ToString() -match "SetupCI.bat") { $EnvVarialbeList = $SetupCIEnvVarialbeList }
        elseif ($SetupFile.ToString() -match "SetUp.py") { $EnvVarialbeList = $SetUppyEnvVarialbeList }
        elseif ($SetupFile.ToString() -match "SetupCIPy.ini") { $EnvVarialbeList = $SetupCIPyEnvVarialbeList }
        elseif ($SetupFile.ToString() -match "CoreAuthSetup.bat") { $EnvVarialbeList = $CoreAuthSetupEnvVarialbeList }
        elseif ($SetupFile.ToString() -match "About.DSL") { $EnvVarialbeList = $AboutDSLVarialbeList }
        elseif ($SetupFile.ToString() -match "appsys30.DSL") { $EnvVarialbeList = $PlatformVersionVarialbeList }
        elseif ($SetupFile.ToString() -match "CoreAuth\\RTM.config") { $EnvVarialbeList = $CoreAuthRTM }
        elseif ($SetupFile.ToString() -match "CoreIssue\\RTM.config") { $EnvVarialbeList = $CoreIssueRTM }

        foreach ($EnvVarialbe in $EnvVarialbeList) {
            if ($EnvVarialbeList -eq $AboutDSLVarialbeList) {
                $Match = Get-LatestActiveMatch -Path $SetupFile -Pattern "$EnvVarialbe"
                if ($Match) { $EnvVarialbeValue = $Match.ToString().Split('"')[1] } else { $EnvVarialbeValue = "NOT FOUND" }
                $EnvVarialbe = "DSL Version"
            }
            elseif ($EnvVarialbeList -eq $PlatformVersionVarialbeList) {
                $Match = Get-LatestActiveMatch -Path $SetupFile -Pattern "$EnvVarialbe"
                if ($Match) { $EnvVarialbeValue = $Match.ToString().Split('"')[1] } else { $EnvVarialbeValue = "NOT FOUND" }
                $EnvVarialbe = "Platform Version"
            }
            else {
                $Match = Get-LatestActiveMatch -Path $SetupFile -Pattern "$EnvVarialbe"
                if ($Match) { $EnvVarialbeValue = $Match.ToString().Split('=')[1].Trim() } else { $EnvVarialbeValue = "NOT FOUND" }
            }

            $OutputreportVarVal += "<TR><TD>$($EnvVarialbe)</TD><TD align=center>$($EnvVarialbeValue)</TD></TR>"
        }
    }
    $OutputreportVarVal
} -ArgumentList $SetupFileList, $SetupCIEnvVarialbeList, $SetUppyEnvVarialbeList, $SetupCIPyEnvVarialbeList, $CoreAuthSetupEnvVarialbeList, $AboutDSLVarialbeList, $PlatformVersionVarialbeList, $CoreAuthRTM, $CoreIssueRTM

# ----------------------------------------------------------------------
# 7. Multi-Server Validation Against Master Baseline
# ----------------------------------------------------------------------
ForEach ($ServerType in $ServerTypes) {
    Write-Host "`nValidating $ServerType servers against Master Host baseline..." -ForegroundColor Cyan

    $CurrentServerObjs = $ServerListByType[$ServerType]
    $ServerList = @($CurrentServerObjs.Name)

    # Expected count logic
    $ExpectedServerCount = 0
    if ($ServerType -eq "svc") {
        $ExpectedServerCount = 4
        if (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "perf") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 45 }
        elseif (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "uat2" -or $EnvironmentName -eq "mock") -and ($Environmentattributon -eq "jazz")) { $ExpectedServerCount = 45 }
    }
    elseif ($ServerType -eq "iss") {
        $ExpectedServerCount = 2
        if (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "perf") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 3 }
        elseif (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "uat2" -or $EnvironmentName -eq "mock") -and ($Environmentattributon -eq "jazz")) { $ExpectedServerCount = 6 }
    }
    elseif ($ServerType -eq "aut") {
        $ExpectedServerCount = 4
        if (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "perf") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 30 }
        elseif (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "uat2" -or $EnvironmentName -eq "mock") -and ($Environmentattributon -eq "jazz")) { $ExpectedServerCount = 4 }
    }
    elseif ($ServerType -eq "tnp") {
        $ExpectedServerCount = 15
        if (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "perf") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 60 }
        elseif (($EnvironmentName -eq "patuat") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 9 }
        elseif (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "uat2" -or $EnvironmentName -eq "mock") -and ($Environmentattributon -eq "jazz")) { $ExpectedServerCount = 60 }
    }
    elseif ($ServerType -eq "awf") {
        $ExpectedServerCount = 10
        if (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "perf") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 80 }
        elseif (($EnvironmentName -eq "patuat") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 9 }
        elseif (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "uat2" -or $EnvironmentName -eq "mock") -and ($Environmentattributon -eq "jazz")) { $ExpectedServerCount = 80 }
    }
    elseif ($ServerType -eq "src") {
        $ExpectedServerCount = 2
        if (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "perf") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 12 }
        elseif (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "uat2" -or $EnvironmentName -eq "mock") -and ($Environmentattributon -eq "jazz")) { $ExpectedServerCount = 12 }
    }
    elseif ($ServerType -eq "snk") {
        $ExpectedServerCount = 2
        if (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "perf") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 36 }
        elseif (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "uat2" -or $EnvironmentName -eq "mock") -and ($Environmentattributon -eq "jazz")) { $ExpectedServerCount = 36 }
    }
    elseif ($ServerType -eq "bat") {
        $ExpectedServerCount = 4
        if (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "perf") -and ($Environmentattributon -eq "cookie")) { $ExpectedServerCount = 4 }
        elseif (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "uat2" -or $EnvironmentName -eq "mock") -and ($Environmentattributon -eq "jazz")) { $ExpectedServerCount = 4 }
    }

    $Result = @()
    if ($ServerList.Count -gt 0) {
        try {
            $Result += Invoke-Command -ComputerName $ServerList -SessionOption $option -ErrorAction Continue -HideComputerName -ScriptBlock {
                param ($MasterHashSetupCI, $MasterHashRunccCI, $MasterHashSetupCIPy, $MasterHashSetUp, $MasterHashCoreAuthSetup, $MasterHashRunccCoreAuth, $MasterHashCoreIssueAboutDSL, $MasterHashCoreAuthAboutDSL, $MasterDSLsHash, $MasterBatchScriptsHash, $MasterPlatformVersionHash)
                $computername = hostname

                $ServerHashSetupCI = $MasterHashSetupCI -eq (Get-FileHash D:\DBBSetup\BatchScripts\CoreIssue\SetupCI.bat -ErrorAction SilentlyContinue).Hash
                $ServerHashRunccCI = $MasterHashRunccCI -eq (Get-FileHash D:\DBBSetup\BatchScripts\CoreIssue\RunccCI.bat -ErrorAction SilentlyContinue).Hash
                $ServerHashSetupCIPy = $MasterHashSetupCIPy -eq (Get-FileHash D:\DBBSetup\BatchScripts\CoreIssue\SetupCIPy.ini -ErrorAction SilentlyContinue).Hash
                $ServerHashSetUp = $MasterHashSetUp -eq (Get-FileHash D:\DBBSetup\BatchScripts\CoreIssue\SetUp.py -ErrorAction SilentlyContinue).Hash
                $ServerHashCoreAuth = $MasterHashCoreAuthSetup -eq (Get-FileHash D:\DBBSetup\BatchScripts\CoreAuth\CoreAuthSetup.bat -ErrorAction SilentlyContinue).Hash
                $ServerHashRunccCoreAuth = $MasterHashRunccCoreAuth -eq (Get-FileHash D:\DBBSetup\BatchScripts\CoreAuth\RunccCoreAuth.bat -ErrorAction SilentlyContinue).Hash
                $ServerHashCoreIssueAboutDSL = $MasterHashCoreIssueAboutDSL -eq (Get-FileHash D:\DBBSetup\DSLs\CI\About.DSL -ErrorAction SilentlyContinue).Hash
                $ServerHashCoreAuthAboutDSL = $MasterHashCoreAuthAboutDSL -eq (Get-FileHash D:\DBBSetup\DSLs\CoreAuth\About.DSL -ErrorAction SilentlyContinue).Hash

                $ServerDSLsHash = $null
                (Get-ChildItem -Path D:\DBBSetup\DSLs\ -Recurse -Filter *.DSL -ErrorAction SilentlyContinue | Get-FileHash).Hash | ForEach-Object { $ServerDSLsHash += "$_" }
                $DSLs_stream = [IO.MemoryStream]::new([byte[]][char[]]$ServerDSLsHash)
                $ServerDSLsHash = $MasterDSLsHash -eq (Get-FileHash -InputStream $DSLs_stream).Hash

                $ServerBatchScriptsHash = $null
                (Get-ChildItem -Path D:\DBBSetup\BatchScripts\ -Recurse -Filter *.bat -ErrorAction SilentlyContinue | Get-FileHash).Hash | ForEach-Object { $ServerBatchScriptsHash += "$_" }
                $BatchScripts_stream = [IO.MemoryStream]::new([byte[]][char[]]$ServerBatchScriptsHash)
                $ServerBatchScriptsHash = $MasterBatchScriptsHash -eq (Get-FileHash -InputStream $BatchScripts_stream).Hash

                $ServerHashPlatformVersion = $MasterPlatformVersionHash -eq (Get-FileHash D:\CC_runtime\appsys30.DSL -ErrorAction SilentlyContinue).Hash

                [PSCustomObject]@{
                    ServerName                 = "$($computername)"
                    ServerHashSetupCI          = "$($ServerHashSetupCI)"
                    ServerHashRunccCI          = "$($ServerHashRunccCI)"
                    ServerHashSetupCIPy        = "$($ServerHashSetupCIPy)"
                    ServerHashSetUp            = "$($ServerHashSetUp)"
                    ServerHashCoreAuth         = "$($ServerHashCoreAuth)"
                    ServerHashRunccCoreAuth    = "$($ServerHashRunccCoreAuth)"
                    ServerHashCoreIssueAboutDSL = "$($ServerHashCoreIssueAboutDSL)"
                    ServerHashCoreAuthAboutDSL = "$($ServerHashCoreAuthAboutDSL)"
                    ServerDSLsHash             = "$($ServerDSLsHash)"
                    ServerBatchScriptsHash     = "$($ServerBatchScriptsHash)"
                    ServerHashPlatformVersion  = "$($ServerHashPlatformVersion)"
                }
            } -ArgumentList $MasterHashSetupCI, $MasterHashRunccCI, $MasterHashSetupCIPy, $MasterHashSetUp, $MasterHashCoreAuthSetup, $MasterHashRunccCoreAuth, $MasterHashCoreIssueAboutDSL, $MasterHashCoreAuthAboutDSL, $MasterDSLsHash, $MasterBatchScriptsHash, $MasterPlatformVersionHash
        }
        catch {
            Write-Host "Remote execution encountered an error on one or more $ServerType servers: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($ServerList.Count -eq $ExpectedServerCount) {
        $Outputreport += "</Table>
                          <font color=""#4682B4"" face=""Microsoft Tai le"">
                          <H4>File Comparison - $($ServerType.ToUpper()) - Server Count $($ServerList.Count)</H4></font>"
    } else {
        $Outputreport += "</Table>
                          <font color=""#CD5C5C"" face=""Microsoft Tai le"">
                          <H4>File Comparison - $($ServerType.ToUpper()) - Server Count $($ServerList.Count) is not matching with expected count $ExpectedServerCount</H4></font>"
    }

    $Outputreport += "<Table border=1 cellpadding=0 cellspacing=0>
                      <TR bgcolor=gray align=center>
                      <TD><B>Server Name</B></TD>
                      <TD><B>SetupCI.bat</B></TD>
                      <TD><B>RunccCI.bat</B></TD>
                      <TD><B>SetupCIPy.ini</B></TD>
                      <TD><B>SetUp.py</B></TD>
                      <TD><B>CoreAuthSetup.bat</B></TD>
                      <TD><B>RunccCoreAuth.bat</B></TD>
                      <TD><B>CoreIssue About.DSL</B></TD>
                      <TD><B>CoreAuth About.DSL</B></TD>
                      <TD><B>*.DSLs</B></TD>
                      <TD><B>*.BAT</B></TD>
                      <TD><B>Platform Version</B></TD>
                      </TR>"

    foreach ($ServerEntry in $ServerList) {
        try {
            $Entry = $Result | Where-Object { $_.ServerName -ieq $ServerEntry }

            if ($Entry -and
                [Boolean]::Parse($Entry.ServerHashSetupCI) -and
                [Boolean]::Parse($Entry.ServerHashRunccCI) -and
                [Boolean]::Parse($Entry.ServerHashSetupCIPy) -and
                [Boolean]::Parse($Entry.ServerHashSetUp) -and
                [Boolean]::Parse($Entry.ServerHashCoreAuth) -and
                [Boolean]::Parse($Entry.ServerHashRunccCoreAuth) -and
                [Boolean]::Parse($Entry.ServerHashCoreIssueAboutDSL) -and
                [Boolean]::Parse($Entry.ServerHashCoreAuthAboutDSL) -and
                [Boolean]::Parse($Entry.ServerDSLsHash) -and
                [Boolean]::Parse($Entry.ServerBatchScriptsHash) -and
                [Boolean]::Parse($Entry.ServerHashPlatformVersion)) {
                $Outputreport += "<TR align=center>"
            } else {
                $Outputreport += "<TR bgcolor=LightSalmon align=center>"
            }

            $Outputreport += "<TD>$ServerEntry</TD>
                              <TD>$($Entry.ServerHashSetupCI)</TD>
                              <TD>$($Entry.ServerHashRunccCI)</TD>
                              <TD>$($Entry.ServerHashSetupCIPy)</TD>
                              <TD>$($Entry.ServerHashSetUp)</TD>
                              <TD>$($Entry.ServerHashCoreAuth)</TD>
                              <TD>$($Entry.ServerHashRunccCoreAuth)</TD>
                              <TD>$($Entry.ServerHashCoreIssueAboutDSL)</TD>
                              <TD>$($Entry.ServerHashCoreAuthAboutDSL)</TD>
                              <TD>$($Entry.ServerDSLsHash)</TD>
                              <TD>$($Entry.ServerBatchScriptsHash)</TD>
                              <TD>$($Entry.ServerHashPlatformVersion)</TD></TR>"
        }
        catch {
            $Outputreport += "<TR bgcolor=LightSalmon align=center>
                              <TD>$ServerEntry</TD>
                              <TD>Problem</TD><TD>Problem</TD><TD>Problem</TD><TD>Problem</TD>
                              <TD>Problem</TD><TD>Problem</TD><TD>Problem</TD><TD>Problem</TD>
                              <TD>Problem</TD><TD>Problem</TD><TD>Problem</TD></TR>"
        }
    }
}

# ----------------------------------------------------------------------
# 8. Report Finalization & S3 Upload
# ----------------------------------------------------------------------
$Outputreport += "</Table></BODY></HTML>"

if (-not (Test-Path "C:\Temp")) { New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null }
$ReportFileNamePrefix = $Module + "_Validation_"
$ReportFile = "C:\Temp\$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd-hhmm).html"
$Outputreport | Out-File "$ReportFile" -Encoding UTF8

Write-Host "`nReport saved locally: $ReportFile" -ForegroundColor Green

# Upload to S3 if bucket is known
if ($Environmentpod -and $Environmentpod -ne "unknown") {
    $s3Target = "s3://corecard-$Environmentpod-$EnvironmentName-$Region-config-files/EnvironmentValidationReports/$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd).html"
    try {
        aws s3 cp $ReportFile $s3Target
        Write-Host "Uploaded to S3: $s3Target" -ForegroundColor Green
    }
    catch {
        Write-Host "Notice: S3 upload skipped or failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($host.Name -eq "Windows PowerShell ISE Host") { Invoke-Item $ReportFile }

