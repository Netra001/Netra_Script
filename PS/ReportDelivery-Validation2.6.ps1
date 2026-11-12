######################################################################################################################
# Report Delivery Validation  | DEVELOPED BY:: Mahendra Dwivedi
# Version 2.3 | Enhanced with separated steps | Date:: 30-Dec-2025
# Version 2.4 | Updated the RDWF Version step:: Netra Chettri | Date:: 12-Feb-2026
# Version 2.5 | Updated the logic if miss-spelled in reportingservice.asmx and ReportExecution2005.asmx :: Netra Chettri | Date:: 1-April-2026
# Version 2.6 | Updated KMS Name Logic for east west  :: Mahendra | Date:: 14-April-2026
# Version 2.7 | Multi-Server EC2 Discovery & Value/Status Report Output :: Netra Chettri | Date:: 13-Oct-2026
#=============================================================================================================================================

Clear-Host
Get-ChildItem D:\ -Recurse -ErrorAction SilentlyContinue | Unblock-File
$Module = "Report-Delivery"
$ServerType = 'rpd'
$ThisServer = (Hostname).ToLower()
if($ThisServer -match 'e1')
{$Region = "us-east-1"
$ShortRegion = 'e1'
} elseif($ThisServer -match 'w2')
{$Region = "us-west-2"
$ShortRegion = 'w2'
}

$AWSVarialbes = (aws ec2 describe-instances --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,Environment:Tags[?Key=='environment']|[0].Value,Status:State.environment,Stack:Tags[?Key=='stack']|[0].Value,Status:State.stack,Attribution:Tags[?Key=='attribution']|[0].Value,Status:State.attribution,Pod:Tags[?Key=='pod']|[0].Value,Status:State.pod}" --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='$ThisServer'" "Name=availability-zone,Values='*'" --region $Region | ConvertFrom-Json)

$EnvironmentName = $AWSVarialbes.Environment.ToLower()
$EnvironmentName
$Environmentattributon = $AWSVarialbes.Attribution.ToLower()
$Environmentattributon
$EnvironmentStack = ($AWSVarialbes.Stack.ToLower())[0]
$EnvironmentStack

if(($AWSVarialbes.Pod) -eq $NULL){
if($Environmentattributon -eq "jazz"){
$Environmentpod = $Environmentattributon
}else{
$S3bucketslist = $NULL
$S3bucketslist = aws s3 ls
if($S3bucketslist -match "corecard-pod2-$EnvironmentName-$Region-config-files") {$Environmentpod = "pod2"}
elseif($S3bucketslist -match "corecard-pod4-$EnvironmentName-$Region-config-files") {$Environmentpod = "pod4"}
elseif($S3bucketslist -match "corecard-pod5-$EnvironmentName-$Region-config-files") {$Environmentpod = "pod5"}
elseif(($S3bucketslist -match "corecard-jazz-$EnvironmentName-$Region-config-files") -and ($Environmentattributon -eq "jazz")) {$Environmentpod = "jazz"}
}

}
else{
$Environmentpod = $AWSVarialbes.Pod.ToLower()}
$Environmentpod

$ServerList = ((aws ec2 describe-instances --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name}" --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='*$ServerType$ShortRegion$EnvironmentName$EnvironmentStack*'" "Name=availability-zone,Values='*'" --region $Region | ConvertFrom-Json) | Select-Object @{n = "Name"; e = { $_.Name } }, @{n = "serial"; e = { [double]($_.Name -split "$EnvironmentName$EnvironmentStack")[1] } } | Sort-Object -Property serial).Name
$ServerList

$MasterHost = $ServerList | Select-Object -First 1

If (Test-Connection $MasterHost -Quiet){
Write-Host "Master Host - " $MasterHost
}
else{
$MasterHost = $ServerList | Select-Object -Last 1
Write-Host "Master Host - " $MasterHost
}

# ======================================================================
# SSL & CERTIFICATE POLICY
# ======================================================================
class TrustAllCertsPolicy : System.Net.ICertificatePolicy {
    [bool] CheckValidationResult([System.Net.ServicePoint] $a,
                                 [System.Security.Cryptography.X509Certificates.X509Certificate] $b,
                                 [System.Net.WebRequest] $c,
                                 [int] $d) {
        return $true
    }
}
[System.Net.ServicePointManager]::CertificatePolicy = [TrustAllCertsPolicy]::new()
[Net.SecurityProtocolType]::Tls12 | Out-Null
[System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ======================================================================
# AWS SECRET RETRIEVAL FOR REPORT URL CHECKS
# ======================================================================
$cred = $null
$secretRetrievalResult = @{ Status = "FAILED"; Value = "Not retrieved" }
try {
    $domainEnv = $env:USERDOMAIN.ToUpper().Split('-')[-1]
    $envCandidate = if ($EnvironmentName) { $EnvironmentName.ToUpper() } else { $domainEnv }
    $secretId = "$envCandidate/app-rw-secret"
    $secretRaw = $null
    try {
        $secretRaw = Get-SECSecretValue -SecretId $secretId -ErrorAction Stop
    } catch {
        $secretId = "$domainEnv/app-rw-secret"
        $secretRaw = Get-SECSecretValue -SecretId $secretId
    }
    $secretJson = $secretRaw.SecretString | ConvertFrom-Json
    $cred = New-Object PSCredential ($secretJson.username, (ConvertTo-SecureString $secretJson.password -AsPlainText -Force))
    $secretRetrievalResult.Status = "PASSED"
    $secretRetrievalResult.Value = "Retrieved: $secretId"
} catch {
    $secretRetrievalResult.Status = "FAILED"
    $secretRetrievalResult.Value = "Error: $($_.Exception.Message)"
    Write-Host "Warning: Could not retrieve secret from AWS Secrets Manager: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ======================================================================
# EXECUTE VALIDATION ACROSS ALL REPORT DELIVERY SERVERS VIA REMOTING
# ======================================================================
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$allResults = @()

$option = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 30000

Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host "Running Report Delivery Validation Across Discovered Servers: $($ServerList -join ', ')" -ForegroundColor Cyan
Write-Host "================================================`n" -ForegroundColor Cyan

$remoteRawResults = Invoke-Command -ComputerName $ServerList -SessionOption $option -ErrorAction inquire -ScriptBlock {
    $currentServer = hostname
    $localResults = @()

    # ---------- STEP 1: Python Check ----------
    $pythonPath = "D:\CC_Python\python.exe"
    if (Test-Path $pythonPath) {
        try {
            $pythonVer = (& $pythonPath --version 2>&1).ToString().Trim()
            $localResults += [PSCustomObject]@{Server=$currentServer; Step="1"; Check="Python"; Value="$pythonPath - $pythonVer"; Status="PASSED"}
        } catch {
            $localResults += [PSCustomObject]@{Server=$currentServer; Step="1"; Check="Python"; Value="Found but version check failed"; Status="WARNING"}
        }
    } else {
        $localResults += [PSCustomObject]@{Server=$currentServer; Step="1"; Check="Python"; Value="Not found"; Status="FAILED"}
    }

    # ---------- STEP 2: BCP Check ----------
    $bcpExe = $null
    try {
        $cmd = Get-Command "bcp" -ErrorAction SilentlyContinue
        if ($cmd) { $bcpExe = $cmd.Source }
    } catch {}
    if (-not $bcpExe) {
        $knownBcpPaths = @(
            "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\bcp.exe",
            "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\bcp.exe",
            "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\110\Tools\Binn\bcp.exe",
            "C:\Program Files\Microsoft SQL Server\160\Tools\Binn\bcp.exe",
            "C:\Program Files\Microsoft SQL Server\150\Tools\Binn\bcp.exe",
            "C:\Program Files\Microsoft SQL Server\140\Tools\Binn\bcp.exe",
            "C:\Program Files\Microsoft SQL Server\130\Tools\Binn\bcp.exe",
            "C:\Program Files\Microsoft SQL Server\120\Tools\Binn\bcp.exe",
            "C:\Program Files\Microsoft SQL Server\110\Tools\Binn\bcp.exe",
            "C:\Program Files (x86)\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\bcp.exe",
            "C:\Program Files (x86)\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\bcp.exe"
        )
        foreach ($kp in $knownBcpPaths) {
            if (Test-Path $kp) { $bcpExe = $kp; break }
        }
    }
    if ($bcpExe) {
        try {
            $rawBcp = (& $bcpExe -v 2>&1)
            $bcpBanner = ($rawBcp | Select-String -Pattern 'BCP' | Select-Object -First 1)
            $bcpBannerText = if ($bcpBanner) { $bcpBanner.ToString().Trim() } else { "BCP" }
            $verLine = ($rawBcp | Select-String -Pattern 'Version' | Select-Object -First 1)
            if ($verLine) {
                $bcpVer = "$bcpBannerText - $($verLine.ToString().Trim())"
            } else {
                $rawStr = ($rawBcp -join "`n")
                if ($rawStr -match '(?i)version[:\s]+([0-9\.]+)') {
                    $bcpVer = "$bcpBannerText - Version: $($matches[1])"
                } elseif ($rawStr -match '([0-9]+\.[0-9]+\.[0-9]+[\.[0-9]*)') {
                    $bcpVer = "$bcpBannerText - Version: $($matches[1])"
                } else {
                    $fv = (Get-Item $bcpExe).VersionInfo.ProductVersion
                    if (-not $fv) { $fv = (Get-Item $bcpExe).VersionInfo.FileVersion }
                    $bcpVer = if ($fv) { "$bcpBannerText - Version: $fv" } else { $bcpBannerText }
                }
            }
            $localResults += [PSCustomObject]@{Server=$currentServer; Step="2"; Check="BCP"; Value=$bcpVer; Status="PASSED"}
        } catch {
            $localResults += [PSCustomObject]@{Server=$currentServer; Step="2"; Check="BCP"; Value="Error retrieving version"; Status="FAILED"}
        }
    } else {
        $localResults += [PSCustomObject]@{Server=$currentServer; Step="2"; Check="BCP"; Value="Not installed"; Status="FAILED"}
    }

    # ---------- STEP 3: RDWF Version ----------
    $pathRDWF = "D:\ReportDelivery\ReportDelivery\WFRunReports.exe"
    try {
        if (Test-Path $pathRDWF) {
            $productVersion = (Get-Item $pathRDWF).VersionInfo.ProductVersion
            if ($productVersion) {
                $localResults += [PSCustomObject]@{Server=$currentServer; Step="3"; Check="RDWF Version"; Value=$productVersion; Status="PASSED"}
            } else {
                $localResults += [PSCustomObject]@{Server=$currentServer; Step="3"; Check="RDWF Version"; Value="Product version not found"; Status="FAILED"}
            }
        } else {
            $localResults += [PSCustomObject]@{Server=$currentServer; Step="3"; Check="RDWF Version"; Value="WFRunReports.exe not found"; Status="FAILED"}
        }
    } catch {
        $localResults += [PSCustomObject]@{Server=$currentServer; Step="3"; Check="RDWF Version"; Value="Error: $($_.Exception.Message)"; Status="FAILED"}
    }

    # ---------- STEP 4: Platform Version ----------
    $pathPlatform = "D:\PlatformCode\appsys30.dsl"
    try {
        if (Test-Path $pathPlatform) {
            $platVer = Select-String -Path $pathPlatform -Pattern 'Application Release\s+([\d\.]+)' | 
                       ForEach-Object { if ($_ -match 'Application Release\s+([\d\.]+)') { $matches[1] } }
            if ($platVer) {
                $localResults += [PSCustomObject]@{Server=$currentServer; Step="3"; Check="Platform Version"; Value=$platVer; Status="PASSED"}
            } else {
                $localResults += [PSCustomObject]@{Server=$currentServer; Step="3"; Check="Platform Version"; Value="Not found in file"; Status="FAILED"}
            }
        } else {
            $localResults += [PSCustomObject]@{Server=$currentServer; Step="3"; Check="Platform Version"; Value="File not found"; Status="FAILED"}
        }
    } catch {
        $localResults += [PSCustomObject]@{Server=$currentServer; Step="3"; Check="Platform Version"; Value="Error: $($_.Exception.Message)"; Status="FAILED"}
    }

    # ---------- STEP 5: ODBC DSN Configuration ----------
    $ExpectedServers = @("CCAPPLIST1","CCAPPSQLAG1","CCRPTLIST1","CCRPTSQLAG1")
    $dsnErrors = @()
    try {
        $ODBCDSNList = Get-OdbcDsn -ErrorAction SilentlyContinue
        foreach ($dsn in $ODBCDSNList) {
            $err = @()
            if ($dsn.DriverName -ne "ODBC Driver 17 for SQL Server") { $err += "Driver: $($dsn.DriverName)" }
            if ($dsn.Attribute.MultiSubnetFailover -ne "Yes") { $err += "MultiSubnetFailover: $($dsn.Attribute.MultiSubnetFailover)" }
            if (-not ($ExpectedServers -contains $dsn.Attribute.Server)) { $err += "Server: $($dsn.Attribute.Server)" }
            if ($err) { $dsnErrors += "DSN '$($dsn.Name)': $($err -join '; ')" }
        }
        $localResults += [PSCustomObject]@{
            Server = $currentServer
            Step   = "4"
            Check  = "ODBC DSN"
            Value  = if($dsnErrors){ "Issues: " + ($dsnErrors -join "; ") } else { "OK" }
            Status = if($dsnErrors){ "FAILED" } else { "PASSED" }
        }
    } catch {
        $localResults += [PSCustomObject]@{Server=$currentServer; Step="4"; Check="ODBC DSN"; Value="Error: $($_.Exception.Message)"; Status="FAILED"}
    }

    # ---------- STEP 6: ODBC Drivers ----------
    $odbcDrivers = @(
        @{Name="ODBC Driver 17";Path="C:\Windows\System32\msodbcsql17.dll"},
        @{Name="ODBC Driver 13";Path="C:\Windows\System32\msodbcsql13.dll"},
        @{Name="SQL Native Client 11.0";Path="C:\Windows\System32\sqlncli11.dll"}
    )
    $missing = @()
    foreach ($d in $odbcDrivers) {
        if (-not (Test-Path $d.Path)) { $missing += $d.Name }
    }
    $localResults += [PSCustomObject]@{
        Server = $currentServer
        Step   = "5"
        Check  = "ODBC Drivers"
        Value  = if($missing){ "Missing: " + ($missing -join ', ') } else { "All installed" }
        Status = if($missing){ "FAILED" } else { "PASSED" }
    }

    # ---------- STEP 7: OSQL Files ----------
    $osqlPaths = @(
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\osql.exe",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\osql.rll",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\osql.exe",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\osql.rll"
    )
    foreach ($path in $osqlPaths) {
        $exists = Test-Path $path
        $file = Split-Path $path -Leaf
        $verFolder = if ($path -match '130') { "130" } else { "170" }
        $localResults += [PSCustomObject]@{
            Server = $currentServer
            Step   = "6"
            Check  = "OSQL - $file ($verFolder)"
            Value  = if($exists){ $path } else { "Missing" }
            Status = if($exists){ "PASSED" } else { "FAILED" }
        }
    }

    # ---------- STEP 8: Translate.exe ----------
    $translatePath = "D:\PlatformCode\translate.exe"
    $existsTrans = Test-Path $translatePath
    $localResults += [PSCustomObject]@{
        Server = $currentServer
        Step   = "7"
        Check  = "Translate.exe"
        Value  = if($existsTrans){ $translatePath } else { "Not found" }
        Status = if($existsTrans){ "PASSED" } else { "FAILED" }
    }

    # ---------- STEP 9: Scheduled Task ----------
    $taskName = "Task_RDWF"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $localResults += [PSCustomObject]@{
            Server = $currentServer
            Step   = "8"
            Check  = "Scheduled Task"
            Value  = "User: $($task.Principal.UserId), State: $($task.State)"
            Status = "PASSED"
        }
    } else {
        $localResults += [PSCustomObject]@{Server=$currentServer; Step="8"; Check="Scheduled Task"; Value="Not found"; Status="FAILED"}
    }

    # ---------- STEP 10: AppSettings (DFENV_emKMSdefaultMachines) ----------
    $configPath = "D:\ReportDelivery\ReportDelivery\WFRunReports.exe.config"
    $reportUrlsFound = @()
    if (Test-Path $configPath) {
        try {
            [xml]$config = Get-Content $configPath
            $appSettings = @{}
            $config.configuration.appSettings.add | ForEach-Object {
                $appSettings[$_.key] = $_.value
            }

            $compUpper = $currentServer.ToUpper()
            $envOrder = @("PATUAT","PATQA","PERF","UAT","QA","DEV","PROD")
            $envName = $envOrder | Where-Object { $compUpper -like "*$_*" } | Select-Object -First 1
            if (-not $envName) { $envName = "UNKNOWN" }

            $kmsPrefixMap = @{
                DEV    = @("cckmse1dev")
                QA     = @("cckmse1qa","cckmsw2qa")
                UAT    = @("cckmse1uat","cckmsw2uat")
                PERF   = @("cckmse1perf","cckmsw2perf")
                PATQA  = @("cckmse1patqa","cckmsw2patqa")
                PATUAT = @("cckmse1patuat","cckmsw2patuat")
                PROD   = @("cckmse1prod","cckmsw2prod")
            }
            $expectedPrefixes = $kmsPrefixMap[$envName]

            foreach ($key in $appSettings.Keys) {
                $val = $appSettings[$key]
                $status = "PASSED"

                if ($key -eq "DFENV_emKMSdefaultMachines") {
                    if ($envName -eq "UNKNOWN" -or -not $expectedPrefixes) {
                        $status = "FAILED"
                    } else {
                        $machines = $val -split '\s+' | Where-Object { $_ }
                        foreach ($m in $machines) {
                            $matchFound = $false
                            foreach ($prefix in $expectedPrefixes) {
                                if ($m.ToLower().StartsWith($prefix)) { $matchFound = $true; break }
                            }
                            if (-not $matchFound) { $status = "FAILED"; break }
                        }
                    }
                }

                $localResults += [PSCustomObject]@{
                    Server = $currentServer
                    Step   = "10"
                    Check  = "AppSetting-$key"
                    Value  = if ($val) { $val } else { "(empty)" }
                    Status = $status
                }
            }
        } catch {
            $localResults += [PSCustomObject]@{Server=$currentServer; Step="10"; Check="AppSettings"; Value="Error: $($_.Exception.Message)"; Status="FAILED"}
        }

        # ---------- STEP 11: Connection Strings ----------
        try {
            [xml]$config = Get-Content $configPath
            $connections = $config.configuration.connectionStrings.add
            $expected = @{
                CoreIssue      = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreIssue","CCJAZZ_RPT_CoreIssue")}
                CoreIssue_Main = @{Server="CCAPPLIST1";Databases=@("CCGS_CoreIssue","CCJAZZ_CoreIssue")}
                CoreLibrary    = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreLibrary")}
                CoreSales      = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreIssue","CCJAZZ_RPT_CoreIssue")}
                CoreApp        = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreApp","CCJAZZ_RPT_CoreApp")}
                CoreAuth       = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreAuth","CCJAZZ_RPT_CoreAuth")}
                CoreCollect    = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreCollect")}
            }
            foreach ($name in $expected.Keys) {
                $conn = $connections | Where-Object {$_.name -eq $name}
                if ($conn) {
                    $cs = $conn.connectionString
                    $srv = ($cs -split ';' | Where-Object {$_ -like 'server=*'}) -replace 'server=',''
                    $db = ($cs -split ';' | Where-Object {$_ -like 'database=*'}) -replace 'database=',''
                    $stat = if($srv -eq $expected[$name].Server -and $expected[$name].Databases -contains $db){"PASSED"}else{"FAILED"}
                    $localResults += [PSCustomObject]@{Server=$currentServer; Step="10"; Check="ConnString-$name"; Value="Server=$srv; DB=$db"; Status=$stat}
                } else {
                    $localResults += [PSCustomObject]@{Server=$currentServer; Step="10"; Check="ConnString-$name"; Value="Not found"; Status="FAILED"}
                }
            }
        } catch {
            $localResults += [PSCustomObject]@{Server=$currentServer; Step="10"; Check="ConnectionStrings"; Value="Error: $($_.Exception.Message)"; Status="FAILED"}
        }

        # Extract URLs for Step 12
        try {
            [xml]$config = Get-Content $configPath
            foreach ($sec in $config.configuration.applicationSettings.ChildNodes) {
                foreach ($set in $sec.setting) {
                    $val = $set.SelectSingleNode("value").InnerText
                    if ($val -match '^https?://') {
                        $reportUrlsFound += [PSCustomObject]@{ SettingName = $set.name; Url = $val }
                    }
                }
            }
        } catch {}

    } else {
        $localResults += [PSCustomObject]@{Server=$currentServer; Step="10"; Check="AppSettings"; Value="Config not found"; Status="FAILED"}
        $localResults += [PSCustomObject]@{Server=$currentServer; Step="10"; Check="ConnectionStrings"; Value="Config not found"; Status="FAILED"}
    }

    [PSCustomObject]@{
        ServerResults = $localResults
        ReportUrls    = $reportUrlsFound
    }
}

# Process results and execute Step 12 URL checks per server
foreach ($remoteItem in $remoteRawResults) {
    $serverName = $remoteItem.PSComputerName
    if (-not $serverName) { $serverName = $remoteItem.ServerResults[0].Server }

    # Add Steps 1 to 11
    foreach ($row in $remoteItem.ServerResults) {
        $row.Server = $serverName
        $allResults += $row
    }

    # Add Step 12: AWS Secret
    $allResults += [PSCustomObject]@{
        Server = $serverName
        Step   = "11"
        Check  = "AWS Secret"
        Value  = $secretRetrievalResult.Value
        Status = $secretRetrievalResult.Status
    }

    # Add Step 12: URLs
    $expectedEndpoints = @("reportingservice.asmx", "ReportExecution2005.asmx")
    foreach ($urlEntry in $remoteItem.ReportUrls) {
        $settingName = $urlEntry.SettingName
        $val = $urlEntry.Url
        $urlLower = $val.ToLower()

        $isValidEndpoint = $false
        foreach ($ep in $expectedEndpoints) {
            if ($urlLower -like "*$ep") { $isValidEndpoint = $true; break }
        }

        if (-not $isValidEndpoint) {
            $allResults += [PSCustomObject]@{
                Server = $serverName
                Step   = "11"
                Check  = "URL-$settingName"
                Value  = "$val (SKIPPED) - Invalid or misspelled endpoint"
                Status = "FAILED"
            }
            continue
        }

        if ($cred) {
            try {
                $resp = Invoke-WebRequest -Uri $val -Credential $cred -UseBasicParsing -TimeoutSec 10
                $httpCode = $resp.StatusCode
                $allResults += [PSCustomObject]@{
                    Server = $serverName
                    Step   = "11"
                    Check  = "URL-$settingName"
                    Value  = "$val (HTTP $httpCode)"
                    Status = if ($httpCode -eq 200) { "PASSED" } else { "FAILED" }
                }
            } catch {
                $allResults += [PSCustomObject]@{
                    Server = $serverName
                    Step   = "11"
                    Check  = "URL-$settingName"
                    Value  = "$val (ERROR) - $($_.Exception.Message)"
                    Status = "FAILED"
                }
            }
        } else {
            $allResults += [PSCustomObject]@{
                Server = $serverName
                Step   = "11"
                Check  = "URL-$settingName"
                Value  = "$val (SKIPPED) - AWS credentials not available"
                Status = "FAILED"
            }
        }
    }
}

# Summary counts
$totalChecks = $allResults.Count
$passedChecks = ($allResults | Where-Object { $_.Status -eq "PASSED" }).Count
$failedChecks = ($allResults | Where-Object { $_.Status -eq "FAILED" }).Count
$warningChecks = ($allResults | Where-Object { $_.Status -eq "WARNING" }).Count

# ======================================================================
# BUILD HTML REPORT (Peachpuff background + Table with Step, Check, Value, Status)
# ======================================================================
$ExpectedServerCount = $ServerList.Count
$serverCountMatch = ($ServerList.Count -eq $ExpectedServerCount)

$countColor = if ($serverCountMatch) { "#4682B4" } else { "#CD5C5C" }
$countHeader = if ($serverCountMatch) {
    "Report Delivery Validation Report - Server Count $($ServerList.Count)"
} else {
    "Report Delivery Validation Report - Server Count $($ServerList.Count) is not matching with expected count $ExpectedServerCount"
}

$Outputreport = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>$Module Validation Report</title>
<style>
body {
    background-color: peachpuff;
    font-family: "Microsoft Tai le", "Segoe UI", Tahoma, sans-serif;
    margin: 20px;
}
h2 {
    color: #4682B4;
    margin-bottom: 5px;
}
h3 {
    color: #4682B4;
    margin-top: 0;
    margin-bottom: 12px;
}
h4 {
    margin-top: 15px;
    margin-bottom: 10px;
}
.summary-bar {
    background-color: #ffffff;
    border: 1px solid #ddd;
    padding: 10px 15px;
    margin-bottom: 15px;
    border-radius: 4px;
    font-size: 14px;
}
table {
    border-collapse: collapse;
    width: 100%;
    background-color: #ffffff;
    border: 1px solid #ddd;
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}
th {
    background-color: #333333;
    color: #ffffff;
    padding: 10px 12px;
    text-align: left;
    font-weight: 600;
    border: 1px solid #444444;
}
td {
    padding: 8px 12px;
    border: 1px solid #ddd;
    font-size: 13px;
}
tr:nth-child(even) { background-color: #f9f9f9; }
tr:hover { background-color: #f1f1f1; }

.status-passed {
    color: #155724;
    font-weight: bold;
    text-align: center;
}
.status-failed {
    color: #721c24;
    font-weight: bold;
    text-align: center;
}
.status-warning {
    color: #856404;
    font-weight: bold;
    text-align: center;
}
tr.failed-row td {
    background-color: LightSalmon !important;
    color: #000;
}
tr.failed-row td.status-failed {
    color: #721c24;
    font-weight: bold;
}
tr.warning-row td {
    background-color: #fff3cd !important;
}
</style>
</head>
<body>
<font color="#4682B4" face="Microsoft Tai le">
<h2>$($EnvironmentName.ToUpper()) - $($Environmentpod.ToUpper()) - $Module Validation Report</h2>
<h3>PLEASE VERIFY BELOW TABLE VALUES AND COMPARE WITH EXPECTED VALUES</h3>
</font>

<div class="summary-bar">
    <strong>Master Host:</strong> $($MasterHost.ToUpper()) &nbsp;|&nbsp;
    <strong>Discovered Servers ($($ServerList.Count)):</strong> $($ServerList -join ', ') &nbsp;|&nbsp;
    <strong>Total Checks:</strong> $totalChecks &nbsp;|&nbsp;
    <strong style="color: #155724;">Passed:</strong> $passedChecks &nbsp;|&nbsp;
    <strong style="color: #721c24;">Failed:</strong> $failedChecks &nbsp;|&nbsp;
    <strong>Generated:</strong> $timestamp
</div>

<font color="$countColor" face="Microsoft Tai le">
<h4>$countHeader</h4>
</font>

<table border="1" cellpadding="0" cellspacing="0">
<thead>
<tr align="center" bgcolor="#333333" style="color:white;">
    <th style="width: 140px; text-align: left;">Server</th>
    <th style="width: 50px; text-align: center;">Step</th>
    <th style="width: 220px; text-align: left;">Check</th>
    <th style="text-align: left;">Value</th>
    <th style="width: 90px; text-align: center;">Status</th>
</tr>
</thead>
<tbody>
"@

foreach ($r in $allResults) {
    $rowClass = if ($r.Status -eq "FAILED") { "failed-row" } elseif ($r.Status -eq "WARNING") { "warning-row" } else { "" }
    $statusClass = switch ($r.Status) {
        "PASSED"  { "status-passed" }
        "FAILED"  { "status-failed" }
        "WARNING" { "status-warning" }
        default   { "" }
    }

    $safeVal = [System.Security.SecurityElement]::Escape("$($r.Value)") -replace "`n", "<br/>"

    $Outputreport += @"
<tr class='$rowClass'>
    <td>$($r.Server)</td>
    <td align="center">$($r.Step)</td>
    <td>$($r.Check)</td>
    <td>$safeVal</td>
    <td class='$statusClass'>$($r.Status)</td>
</tr>
"@
}

$Outputreport += @"
</tbody>
</table>
</body>
</html>
"@

# ======================================================================
# SAVE & UPLOAD REPORT TO S3
# ======================================================================
$ReportFileNamePrefix = $Module +"_Validation_"
$ReportFile = "C:\Temp\$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd-hhmm).html"
$Outputreport | Out-File "$ReportFile" -Encoding UTF8
aws s3 cp $ReportFile "s3://corecard-$Environmentpod-$EnvironmentName-$Region-config-files/EnvironmentValidationReports/$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd).html"

if($host.Name -eq "Windows PowerShell ISE Host"){Invoke-Item $ReportFile}

Write-Host "`nReport saved locally: $ReportFile" -ForegroundColor Green
Write-Host "Validation Finished: Passed=$passedChecks, Failed=$failedChecks, Warnings=$warningChecks" -ForegroundColor Cyan