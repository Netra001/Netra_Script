######################################################################################################################
# Report Delivery Validation  | DEVELOPED BY:: Netra Chettri
# Version 2.7 | Multi-Server EC2 Discovery & Report Layout & HTML Output Change  :: Netra Chettri | Date:: 13-Oct-2026
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

$AWSVarialbes = (aws ec2 describe-instances --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,Environment:Tags[?Key=='environment']|[0].Value,Status:State.environment,Stack:Tags[?Key=='stack']|[0].Value,Status:State.stack,Attribution:Tags[?Key=='attribution']|[0].Value,Status:State.attribution}" --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='$ThisServer'" "Name=availability-zone,Values='*'" --region $Region | ConvertFrom-Json)

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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ======================================================================
# AWS SECRET RETRIEVAL FOR REPORT URL CHECKS
# ======================================================================
$cred = $null
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
} catch {
    Write-Host "Warning: Could not retrieve secret from AWS Secrets Manager: $($_.Exception.Message)" -ForegroundColor Yellow
}

function Test-ReportEndpoints {
    param(
        [string]$UrlString,
        [PSCredential]$Credential
    )
    if (-not $UrlString) { return "No URLs configured" }
    $urls = $UrlString -split ';' | Where-Object { $_ }
    $expectedEndpoints = @("reportingservice.asmx", "ReportExecution2005.asmx")
    $urlErrors = @()
    foreach ($u in $urls) {
        $uLower = $u.ToLower()
        $validEp = $false
        foreach ($ep in $expectedEndpoints) {
            if ($uLower -like "*$ep") { $validEp = $true; break }
        }
        if (-not $validEp) {
            $urlErrors += "$u (Misspelled/Invalid Endpoint)"
            continue
        }
        if ($Credential) {
            try {
                $resp = Invoke-WebRequest -Uri $u -Credential $Credential -UseBasicParsing -TimeoutSec 10
                if ($resp.StatusCode -ne 200) { $urlErrors += "$u ($($resp.StatusCode))" }
            } catch {
                $urlErrors += "$u (Error: $($_.Exception.Message))"
            }
        }
    }
    if ($urlErrors.Count -gt 0) {
        return "Failed: " + ($urlErrors -join "; ")
    } else {
        return "Working (HTTP 200)"
    }
}

# ======================================================================
# FETCH MASTER HOST BASELINE
# ======================================================================
$option = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 20000

$MasterData = Invoke-Command -ComputerName $MasterHost -SessionOption $option -ErrorAction inquire -ScriptBlock {
    $comp = hostname
    $pythonPath = "D:\CC_Python\python.exe"
    $pyVer = if (Test-Path $pythonPath) { try { (& $pythonPath --version 2>&1).ToString().Trim() } catch { "Error" } } else { "Not found" }

    $bcpVer = "Not installed"
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
        } catch {
            try {
                $fv = (Get-Item $bcpExe).VersionInfo.ProductVersion
                if (-not $fv) { $fv = (Get-Item $bcpExe).VersionInfo.FileVersion }
                $bcpVer = if ($fv) { "BCP - Version: $fv" } else { "Installed" }
            } catch { $bcpVer = "Error" }
        }
    }

    $rdwfPath = "D:\ReportDelivery\ReportDelivery\WFRunReports.exe"
    $rdwfVer = if (Test-Path $rdwfPath) { (Get-Item $rdwfPath).VersionInfo.ProductVersion } else { "Not found" }

    $platPath = "D:\PlatformCode\appsys30.dsl"
    $platVer = if (Test-Path $platPath) {
        (Select-String -Path $platPath -Pattern 'Application Release\s+([\d\.]+)' | ForEach-Object { if ($_ -match 'Application Release\s+([\d\.]+)') { $matches[1] } })
    } else { "Not found" }

    $transPath = "D:\PlatformCode\translate.exe"
    $transStatus = if (Test-Path $transPath) { "Found" } else { "Not found" }

    $ExpectedServers = @("CCAPPLIST1","CCAPPSQLAG1","CCRPTLIST1","CCRPTSQLAG1")
    $dsnErrors = @()
    try {
        $dsns = Get-OdbcDsn -ErrorAction SilentlyContinue
        foreach ($dsn in $dsns) {
            $err = @()
            if ($dsn.DriverName -ne "ODBC Driver 17 for SQL Server") { $err += "Driver: $($dsn.DriverName)" }
            if ($dsn.Attribute.MultiSubnetFailover -ne "Yes") { $err += "MultiSubnetFailover: $($dsn.Attribute.MultiSubnetFailover)" }
            if (-not ($ExpectedServers -contains $dsn.Attribute.Server)) { $err += "Server: $($dsn.Attribute.Server)" }
            if ($err) { $dsnErrors += "$($dsn.Name): $($err -join ';')" }
        }
        $dsnStatus = if ($dsnErrors.Count -gt 0) { "Issues: " + ($dsnErrors -join "; ") } else { "Passed" }
    } catch { $dsnStatus = "Error: $($_.Exception.Message)" }

    $missingDrivers = @()
    @("C:\Windows\System32\msodbcsql17.dll", "C:\Windows\System32\msodbcsql13.dll", "C:\Windows\System32\sqlncli11.dll") | ForEach-Object {
        if (-not (Test-Path $_)) { $missingDrivers += (Split-Path $_ -Leaf) }
    }
    $driversStatus = if ($missingDrivers.Count -gt 0) { "Missing: " + ($missingDrivers -join ", ") } else { "All installed" }

    $osqlPaths = @(
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\osql.exe",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\osql.rll",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\osql.exe",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\osql.rll"
    )
    $missingOsql = @()
    foreach ($p in $osqlPaths) { if (-not (Test-Path $p)) { $missingOsql += (Split-Path $p -Leaf) } }
    $osqlStatus = if ($missingOsql.Count -gt 0) { "Missing: " + ($missingOsql -join ", ") } else { "All installed" }

    $taskStatus = "Not found"
    $taskUser = "Not found"
    try {
        $t = Get-ScheduledTask -TaskName "Task_RDWF" -ErrorAction SilentlyContinue
        if ($t) {
            $taskStatus = "$($t.State)"
            $taskUser = if ($t.Principal.UserId) { "$($t.Principal.UserId)" } else { "N/A" }
        }
    } catch {
        $taskStatus = "Error"
        $taskUser = "Error"
    }

    $cfg = "D:\ReportDelivery\ReportDelivery\WFRunReports.exe.config"
    $kmsMachines = ""
    if (Test-Path $cfg) {
        try {
            [xml]$x = Get-Content $cfg
            $kmsMachines = ($x.configuration.appSettings.add | Where-Object { $_.key -eq "DFENV_emKMSdefaultMachines" }).value
        } catch { $kmsMachines = "Error" }
    } else { $kmsMachines = "Not found" }

    $connStatus = "Passed"
    if (Test-Path $cfg) {
        try {
            [xml]$x = Get-Content $cfg
            $expectedConns = @{
                CoreIssue      = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreIssue","CCJAZZ_RPT_CoreIssue")}
                CoreIssue_Main = @{Server="CCAPPLIST1";Databases=@("CCGS_CoreIssue","CCJAZZ_CoreIssue")}
                CoreLibrary    = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreLibrary")}
                CoreSales      = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreIssue","CCJAZZ_RPT_CoreIssue")}
                CoreApp        = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreApp","CCJAZZ_RPT_CoreApp")}
                CoreAuth       = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreAuth","CCJAZZ_RPT_CoreAuth")}
                CoreCollect    = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreCollect")}
            }
            $cFail = 0
            foreach ($cn in $expectedConns.Keys) {
                $item = $x.configuration.connectionStrings.add | Where-Object { $_.name -eq $cn }
                if ($item) {
                    $cs = $item.connectionString
                    $srv = ($cs -split ';' | Where-Object {$_ -like 'server=*'}) -replace 'server=',''
                    $db = ($cs -split ';' | Where-Object {$_ -like 'database=*'}) -replace 'database=',''
                    if ($srv -ne $expectedConns[$cn].Server -or -not ($expectedConns[$cn].Databases -contains $db)) { $cFail++ }
                } else { $cFail++ }
            }
            if ($cFail -gt 0) { $connStatus = "Failed ($cFail errors)" }
        } catch { $connStatus = "Error: $($_.Exception.Message)" }
    } else { $connStatus = "Not found" }

    $urls = @()
    if (Test-Path $cfg) {
        try {
            [xml]$x = Get-Content $cfg
            foreach ($sec in $x.configuration.applicationSettings.ChildNodes) {
                foreach ($s in $sec.setting) {
                    $v = $s.SelectSingleNode("value").InnerText
                    if ($v -match '^https?://') { $urls += $v }
                }
            }
        } catch {}
    }

    [PSCustomObject]@{
        ServerName     = $comp
        PythonVer      = $pyVer
        BCPVer         = $bcpVer
        RDWFVer        = $rdwfVer
        PlatVer        = $platVer
        Translate      = $transStatus
        ODBCDSN        = $dsnStatus
        ODBCDrivers    = $driversStatus
        OSQLFiles      = $osqlStatus
        TaskRDWF       = $taskStatus
        TaskRDWFUser   = $taskUser
        KMSMachines    = $kmsMachines
        ConnStrings    = $connStatus
        ReportURLsList = ($urls -join ";")
    }
}

$MasterReportURLs = Test-ReportEndpoints -UrlString $MasterData.ReportURLsList -Credential $cred

# ======================================================================
# EXPECTED VALUES
# ======================================================================
$ExpectedServerCount = $ServerList.Count
$ExpectedPython = $MasterData.PythonVer
$ExpectedBCP = $MasterData.BCPVer
$ExpectedRDWF = $MasterData.RDWFVer
$ExpectedPlatform = $MasterData.PlatVer
$ExpectedTranslate = "Found"
$ExpectedODBCDSN = "Passed"
$ExpectedODBCDrivers = "All installed"
$ExpectedOSQLFiles = "All installed"
$ExpectedTaskRDWF = "Ready"
$ExpectedTaskRDWFUser = if ($MasterData.TaskRDWFUser -and $MasterData.TaskRDWFUser -ne "Not found" -and $MasterData.TaskRDWFUser -ne "Error") { $MasterData.TaskRDWFUser } else { "gmsa-app-svc$" }
$ExpectedConnStrings = "Passed"
$ExpectedReportURLs = "Working (HTTP 200)"

# ======================================================================
# INITIALIZE HTML OUTPUT (Services-WebSite Format)
# ======================================================================
$Outputreport = "<HTML><TITLE> $Module Validation Report </TITLE>
                 <BODY background-color:peachpuff>
                 <font color =""#4682B4"" face=""Microsoft Tai le"">
                 <H2>$($EnvironmentName.ToUpper()) - $($Environmentpod.ToUpper()) - $Module Validation Report</H2>
                 <H3>PLEASE VERIFY BELOW TABLE VALUES AND COMPARE WITH EXPECTED VALUES</H3></font>
                 <Table border=1 cellpadding=0 cellspacing=0>
                 <TR bgcolor=gray align=center>
                   <TD><B>Master Host</B></TD>
                   <TD><B>Python Version</B></TD>
                   <TD><B>BCP Version</B></TD>
                   <TD><B>RDWF Version</B></TD>
                   <TD><B>Platform Version</B></TD>
                   <TD><B>Translate.exe</B></TD>
                   <TD><B>ODBC DSN</B></TD>
                   <TD><B>ODBC Drivers</B></TD>
                   <TD><B>OSQL Files</B></TD>
                   <TD><B>Task_RDWF</B></TD>
                   <TD><B>Scheduled Task User</B></TD>
                   <TD><B>KMS Machines</B></TD>
                   <TD><B>Connection Strings</B></TD>
                   <TD><B>Report URLs Status</B></TD>
                 </TR>"

$Outputreport += "<TR align=center>
                   <TD>$("$MasterHost".ToUpper())</TD>
                   <TD align=center>$($MasterData.PythonVer)</TD>
                   <TD align=center>$($MasterData.BCPVer)</TD>
                   <TD align=center>$($MasterData.RDWFVer)</TD>
                   <TD align=center>$($MasterData.PlatVer)</TD>
                   <TD align=center>$($MasterData.Translate)</TD>
                   <TD align=center>$($MasterData.ODBCDSN)</TD>
                   <TD align=center>$($MasterData.ODBCDrivers)</TD>
                   <TD align=center>$($MasterData.OSQLFiles)</TD>
                   <TD align=center>$($MasterData.TaskRDWF)</TD>
                   <TD align=center>$($MasterData.TaskRDWFUser)</TD>
                   <TD align=center>$($MasterData.KMSMachines)</TD>
                   <TD align=center>$($MasterData.ConnStrings)</TD>
                   <TD align=center>$MasterReportURLs</TD>
                  </TR>"

# ======================================================================
# EXECUTE VALIDATION ACROSS ALL REPORT DELIVERY SERVERS
# ======================================================================
$Result = @()
$option = New-PSSessionOption -ProxyAccessType NoProxyServer
$Result += Invoke-Command -ComputerName $ServerList -SessionOption $option -ErrorAction inquire -ScriptBlock {
    $comp = hostname
    $pythonPath = "D:\CC_Python\python.exe"
    $pyVer = if (Test-Path $pythonPath) { try { (& $pythonPath --version 2>&1).ToString().Trim() } catch { "Error" } } else { "Not found" }

    $bcpVer = "Not installed"
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
        } catch {
            try {
                $fv = (Get-Item $bcpExe).VersionInfo.ProductVersion
                if (-not $fv) { $fv = (Get-Item $bcpExe).VersionInfo.FileVersion }
                $bcpVer = if ($fv) { "BCP - Version: $fv" } else { "Installed" }
            } catch { $bcpVer = "Error" }
        }
    }

    $rdwfPath = "D:\ReportDelivery\ReportDelivery\WFRunReports.exe"
    $rdwfVer = if (Test-Path $rdwfPath) { (Get-Item $rdwfPath).VersionInfo.ProductVersion } else { "Not found" }

    $platPath = "D:\PlatformCode\appsys30.dsl"
    $platVer = if (Test-Path $platPath) {
        (Select-String -Path $platPath -Pattern 'Application Release\s+([\d\.]+)' | ForEach-Object { if ($_ -match 'Application Release\s+([\d\.]+)') { $matches[1] } })
    } else { "Not found" }

    $transPath = "D:\PlatformCode\translate.exe"
    $transStatus = if (Test-Path $transPath) { "Found" } else { "Not found" }

    $ExpectedServers = @("CCAPPLIST1","CCAPPSQLAG1","CCRPTLIST1","CCRPTSQLAG1")
    $dsnErrors = @()
    try {
        $dsns = Get-OdbcDsn -ErrorAction SilentlyContinue
        foreach ($dsn in $dsns) {
            $err = @()
            if ($dsn.DriverName -ne "ODBC Driver 17 for SQL Server") { $err += "Driver: $($dsn.DriverName)" }
            if ($dsn.Attribute.MultiSubnetFailover -ne "Yes") { $err += "MultiSubnetFailover: $($dsn.Attribute.MultiSubnetFailover)" }
            if (-not ($ExpectedServers -contains $dsn.Attribute.Server)) { $err += "Server: $($dsn.Attribute.Server)" }
            if ($err) { $dsnErrors += "$($dsn.Name): $($err -join ';')" }
        }
        $dsnStatus = if ($dsnErrors.Count -gt 0) { "Issues: " + ($dsnErrors -join "; ") } else { "Passed" }
    } catch { $dsnStatus = "Error: $($_.Exception.Message)" }

    $missingDrivers = @()
    @("C:\Windows\System32\msodbcsql17.dll", "C:\Windows\System32\msodbcsql13.dll", "C:\Windows\System32\sqlncli11.dll") | ForEach-Object {
        if (-not (Test-Path $_)) { $missingDrivers += (Split-Path $_ -Leaf) }
    }
    $driversStatus = if ($missingDrivers.Count -gt 0) { "Missing: " + ($missingDrivers -join ", ") } else { "All installed" }

    $osqlPaths = @(
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\osql.exe",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\osql.rll",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\osql.exe",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\osql.rll"
    )
    $missingOsql = @()
    foreach ($p in $osqlPaths) { if (-not (Test-Path $p)) { $missingOsql += (Split-Path $p -Leaf) } }
    $osqlStatus = if ($missingOsql.Count -gt 0) { "Missing: " + ($missingOsql -join ", ") } else { "All installed" }

    $taskStatus = "Not found"
    $taskUser = "Not found"
    try {
        $t = Get-ScheduledTask -TaskName "Task_RDWF" -ErrorAction SilentlyContinue
        if ($t) {
            $taskStatus = "$($t.State)"
            $taskUser = if ($t.Principal.UserId) { "$($t.Principal.UserId)" } else { "N/A" }
        }
    } catch {
        $taskStatus = "Error"
        $taskUser = "Error"
    }

    $cfg = "D:\ReportDelivery\ReportDelivery\WFRunReports.exe.config"
    $kmsMachines = ""
    if (Test-Path $cfg) {
        try {
            [xml]$x = Get-Content $cfg
            $kmsMachines = ($x.configuration.appSettings.add | Where-Object { $_.key -eq "DFENV_emKMSdefaultMachines" }).value
        } catch { $kmsMachines = "Error" }
    } else { $kmsMachines = "Not found" }

    $connStatus = "Passed"
    if (Test-Path $cfg) {
        try {
            [xml]$x = Get-Content $cfg
            $expectedConns = @{
                CoreIssue      = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreIssue","CCJAZZ_RPT_CoreIssue")}
                CoreIssue_Main = @{Server="CCAPPLIST1";Databases=@("CCGS_CoreIssue","CCJAZZ_CoreIssue")}
                CoreLibrary    = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreLibrary")}
                CoreSales      = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreIssue","CCJAZZ_RPT_CoreIssue")}
                CoreApp        = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreApp","CCJAZZ_RPT_CoreApp")}
                CoreAuth       = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreAuth","CCJAZZ_RPT_CoreAuth")}
                CoreCollect    = @{Server="CCrptLIST1";Databases=@("CCGS_RPT_CoreCollect")}
            }
            $cFail = 0
            foreach ($cn in $expectedConns.Keys) {
                $item = $x.configuration.connectionStrings.add | Where-Object { $_.name -eq $cn }
                if ($item) {
                    $cs = $item.connectionString
                    $srv = ($cs -split ';' | Where-Object {$_ -like 'server=*'}) -replace 'server=',''
                    $db = ($cs -split ';' | Where-Object {$_ -like 'database=*'}) -replace 'database=',''
                    if ($srv -ne $expectedConns[$cn].Server -or -not ($expectedConns[$cn].Databases -contains $db)) { $cFail++ }
                } else { $cFail++ }
            }
            if ($cFail -gt 0) { $connStatus = "Failed ($cFail errors)" }
        } catch { $connStatus = "Error: $($_.Exception.Message)" }
    } else { $connStatus = "Not found" }

    $urls = @()
    if (Test-Path $cfg) {
        try {
            [xml]$x = Get-Content $cfg
            foreach ($sec in $x.configuration.applicationSettings.ChildNodes) {
                foreach ($s in $sec.setting) {
                    $v = $s.SelectSingleNode("value").InnerText
                    if ($v -match '^https?://') { $urls += $v }
                }
            }
        } catch {}
    }

    [PSCustomObject]@{
        ServerName     = $comp
        PythonVer      = $pyVer
        BCPVer         = $bcpVer
        RDWFVer        = $rdwfVer
        PlatVer        = $platVer
        Translate      = $transStatus
        ODBCDSN        = $dsnStatus
        ODBCDrivers    = $driversStatus
        OSQLFiles      = $osqlStatus
        TaskRDWF       = $taskStatus
        TaskRDWFUser   = $taskUser
        KMSMachines    = $kmsMachines
        ConnStrings    = $connStatus
        ReportURLsList = ($urls -join ";")
    }
}

# ======================================================================
# SERVER COUNT VERIFICATION HEADING
# ======================================================================
if($ServerList.Count -eq $ExpectedServerCount)
{
$Outputreport += "</Table>
                 <font color =""#4682B4"" face=""Microsoft Tai le"">
                   <H4>  Report Delivery Validation Report - Server Count $($Result.count) </H4></font>"
}else{
$Outputreport += "</Table>
                 <font color =""#CD5C5C"" face=""Microsoft Tai le"">
                   <H4>Report Delivery Validation Report - Server Count $($Result.count) is not matching with expected count $ExpectedServerCount </H4></font>"
}

# ======================================================================
# DETAIL TABLE FOR ALL SERVERS
# ======================================================================
$Outputreport += "<Table border=1 cellpadding=0 cellspacing=0>
                 <TR bgcolor=gray align=center>
                    <TD><B>Report Delivery Server</B></TD>
                    <TD><B>Python Version</B></TD>
                    <TD><B>BCP Version</B></TD>
                    <TD><B>RDWF Version</B></TD>
                    <TD><B>Platform Version</B></TD>
                    <TD><B>Translate.exe</B></TD>
                    <TD><B>ODBC DSN</B></TD>
                    <TD><B>ODBC Drivers</B></TD>
                    <TD><B>OSQL Files</B></TD>
                    <TD><B>Task_RDWF</B></TD>
                    <TD><B>Scheduled Task User</B></TD>
                    <TD><B>KMS Machines</B></TD>
                    <TD><B>Connection Strings</B></TD>
                    <TD><B>Report URLs Status</B></TD>
                 </TR>"

Foreach($Entry in $Result){
    $serverReportURLs = Test-ReportEndpoints -UrlString $Entry.ReportURLsList -Credential $cred

    # Cell-level highlighting (white if matching expected, LightSalmon/orange if mismatched)
    $pyCellColor = if ($Entry.PythonVer -eq $ExpectedPython) { "" } else { "bgcolor=LightSalmon" }
    $bcpCellColor = if ($Entry.BCPVer -eq $ExpectedBCP) { "" } else { "bgcolor=LightSalmon" }
    $rdwfCellColor = if ($Entry.RDWFVer -eq $ExpectedRDWF) { "" } else { "bgcolor=LightSalmon" }
    $platCellColor = if ($Entry.PlatVer -eq $ExpectedPlatform) { "" } else { "bgcolor=LightSalmon" }
    $transCellColor = if ($Entry.Translate -eq $ExpectedTranslate) { "" } else { "bgcolor=LightSalmon" }
    $dsnCellColor = if ($Entry.ODBCDSN -eq $ExpectedODBCDSN) { "" } else { "bgcolor=LightSalmon" }
    $driversCellColor = if ($Entry.ODBCDrivers -eq $ExpectedODBCDrivers) { "" } else { "bgcolor=LightSalmon" }
    $osqlCellColor = if ($Entry.OSQLFiles -eq $ExpectedOSQLFiles) { "" } else { "bgcolor=LightSalmon" }
    $taskCellColor = if ($Entry.TaskRDWF -eq $ExpectedTaskRDWF -or $Entry.TaskRDWF -eq "Running") { "" } else { "bgcolor=LightSalmon" }
    $taskUserCellColor = if (($Entry.TaskRDWFUser -eq $ExpectedTaskRDWFUser) -or ($Entry.TaskRDWFUser -like "*gmsa-app-svc*")) { "" } else { "bgcolor=LightSalmon" }
    $kmsCellColor = if ($Entry.KMSMachines -eq $MasterData.KMSMachines) { "" } else { "bgcolor=LightSalmon" }
    $connCellColor = if ($Entry.ConnStrings -eq $ExpectedConnStrings) { "" } else { "bgcolor=LightSalmon" }
    $urlsCellColor = if ($serverReportURLs -like "*Working*") { "" } else { "bgcolor=LightSalmon" }

    $rowColor = if ($pyCellColor -or $bcpCellColor -or $rdwfCellColor -or $platCellColor -or $transCellColor -or $dsnCellColor -or $driversCellColor -or $osqlCellColor -or $taskCellColor -or $taskUserCellColor -or $kmsCellColor -or $connCellColor -or $urlsCellColor) {
        "bgcolor=LightSalmon"
    } else {
        ""
    }

    $Outputreport += "<TR $rowColor align=center>
                        <TD>$($Entry.ServerName)</TD>
                        <TD $pyCellColor align=center>$($Entry.PythonVer)</TD>
                        <TD $bcpCellColor align=center>$($Entry.BCPVer)</TD>
                        <TD $rdwfCellColor align=center>$($Entry.RDWFVer)</TD>
                        <TD $platCellColor align=center>$($Entry.PlatVer)</TD>
                        <TD $transCellColor align=center>$($Entry.Translate)</TD>
                        <TD $dsnCellColor align=center>$($Entry.ODBCDSN)</TD>
                        <TD $driversCellColor align=center>$($Entry.ODBCDrivers)</TD>
                        <TD $osqlCellColor align=center>$($Entry.OSQLFiles)</TD>
                        <TD $taskCellColor align=center>$($Entry.TaskRDWF)</TD>
                        <TD $taskUserCellColor align=center>$($Entry.TaskRDWFUser)</TD>
                        <TD $kmsCellColor align=center>$($Entry.KMSMachines)</TD>
                        <TD $connCellColor align=center>$($Entry.ConnStrings)</TD>
                        <TD $urlsCellColor align=center>$serverReportURLs</TD>
                      </TR>"
}

$Outputreport += "</Table></BODY></HTML>"

# ======================================================================
# SAVE & UPLOAD REPORT TO S3
# ======================================================================
$ReportFileNamePrefix = $Module +"_Validation_"
$ReportFile = "C:\Temp\$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd-hhmm).html"
$Outputreport | Out-File "$ReportFile" -Encoding UTF8
aws s3 cp $ReportFile "s3://corecard-$Environmentpod-$EnvironmentName-$Region-config-files/EnvironmentValidationReports/$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd).html"

if($host.Name -eq "Windows PowerShell ISE Host"){Invoke-Item $ReportFile}

# ======================================================================
# CLEANUP VARIABLES
# ======================================================================
Clear-Variable Module -ErrorAction SilentlyContinue
Clear-Variable ServerType -ErrorAction SilentlyContinue
Clear-Variable ThisServer -ErrorAction SilentlyContinue
Clear-Variable Region -ErrorAction SilentlyContinue
Clear-Variable ShortRegion -ErrorAction SilentlyContinue
Clear-Variable AWSVarialbes -ErrorAction SilentlyContinue
Clear-Variable Environmentattributon -ErrorAction SilentlyContinue
Clear-Variable EnvironmentStack -ErrorAction SilentlyContinue
Clear-Variable Environmentpod -ErrorAction SilentlyContinue
Clear-Variable ServerList -ErrorAction SilentlyContinue
Clear-Variable MasterHost -ErrorAction SilentlyContinue
Clear-Variable MasterData -ErrorAction SilentlyContinue
Clear-Variable Result -ErrorAction SilentlyContinue
Clear-Variable Outputreport -ErrorAction SilentlyContinue
Clear-Variable ReportFileNamePrefix -ErrorAction SilentlyContinue
Clear-Variable ReportFile -ErrorAction SilentlyContinue