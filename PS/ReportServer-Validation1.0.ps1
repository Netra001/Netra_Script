######################################################################################################################
# Report Server (SSRS) Validation Script  | DEVELOPED BY:: Mahendra Dwivedi
# Intial Version| Report Server (SSRS) Validation Script | Date:: 02-July-2025
# Report Server (SSRS) Validation Script  | DEVELOPED BY:: Netra Chettri
# Version 1.0 | Multi-Server EC2 Discovery & Merged Service Details & HTML Output | Date:: 03-Nov-2026
#======================================================================================================================

Clear-Host
Get-ChildItem D:\ -Recurse -ErrorAction SilentlyContinue | Unblock-File
$Module = "Report-Server"
$ServerType = 'rps'
$Domain = $env:USERDOMAIN
$ThisServer = (Hostname).ToLower()
if($ThisServer -match 'e1')
{$Region = "us-east-1"
$ShortRegion = 'e1'
} elseif($ThisServer -match 'w2')
{$Region = "us-west-2"
$ShortRegion = 'w2'
} else {
$Region = "us-east-1"
$ShortRegion = 'e1'
}

$AWSVarialbes = (aws ec2 describe-instances --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,Environment:Tags[?Key=='environment']|[0].Value,Status:State.environment,Stack:Tags[?Key=='stack']|[0].Value,Status:State.stack,Attribution:Tags[?Key=='attribution']|[0].Value,Status:State.attribution,Pod:Tags[?Key=='pod']|[0].Value}" --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='$ThisServer'" "Name=availability-zone,Values='*'" --region $Region | ConvertFrom-Json)

$EnvironmentName = if ($AWSVarialbes.Environment) { $AWSVarialbes.Environment.ToLower() } else { "qa" }
$EnvironmentName
$Environmentattributon = if ($AWSVarialbes.Attribution) { $AWSVarialbes.Attribution.ToLower() } else { "corecard" }
$Environmentattributon
$EnvironmentStack = if ($AWSVarialbes.Stack) { ($AWSVarialbes.Stack.ToLower())[0] } else { "a" }
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
        else {$Environmentpod = "pod2"}
    }
} else {
    $Environmentpod = $AWSVarialbes.Pod.ToLower()
}
$Environmentpod

$ServerList = @(((aws ec2 describe-instances --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name}" --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='*$ServerType$ShortRegion$EnvironmentName$EnvironmentStack*'" "Name=availability-zone,Values='*'" --region $Region | ConvertFrom-Json) | Select-Object @{n = "Name"; e = { $_.Name } }, @{n = "serial"; e = { [double]($_.Name -split "$EnvironmentName$EnvironmentStack")[1] } } | Sort-Object -Property serial).Name)

if (-not $ServerList -or $ServerList.Count -eq 0) {
    # Fallback to 'rps' prefix if 'rpt' returned nothing
    $ServerType = 'rps'
    $ServerList = @(((aws ec2 describe-instances --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name}" --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='*$ServerType$ShortRegion$EnvironmentName$EnvironmentStack*'" "Name=availability-zone,Values='*'" --region $Region | ConvertFrom-Json) | Select-Object @{n = "Name"; e = { $_.Name } }, @{n = "serial"; e = { [double]($_.Name -split "$EnvironmentName$EnvironmentStack")[1] } } | Sort-Object -Property serial).Name)
    if (-not $ServerList -or $ServerList.Count -eq 0) {
        $ServerType = 'rpt'
        $ServerList = @($env:COMPUTERNAME)
    }
}
$ServerList

$MasterHost = $ServerList | Select-Object -First 1

If (Test-Connection $MasterHost -Quiet -Count 1 -ErrorAction SilentlyContinue){
    Write-Host "Master Host - " $MasterHost
}
else{
    $lastHost = $ServerList | Select-Object -Last 1
    if (Test-Connection $lastHost -Quiet -Count 1 -ErrorAction SilentlyContinue) {
        $MasterHost = $lastHost
    }
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
# AWS SECRET RETRIEVAL FOR REPORT SERVER VALIDATION
# ======================================================================
$cred = $null
try {
    $domainEnv = $Domain.ToUpper().Split('-')[-1]
    $envCandidate = if ($EnvironmentName) { $EnvironmentName.ToUpper() } else { $domainEnv }
    $secretId = "$envCandidate/app-rw-secret"
    $secretString = $null

    try {
        if (Get-Command Get-SECSecretValue -ErrorAction SilentlyContinue) {
            $secretRaw = Get-SECSecretValue -SecretId $secretId -ErrorAction Stop
            $secretString = $secretRaw.SecretString
        }
    } catch {
        try {
            $secretId = "$domainEnv/app-rw-secret"
            $secretRaw = Get-SECSecretValue -SecretId $secretId -ErrorAction Stop
            $secretString = $secretRaw.SecretString
        } catch {}
    }

    if (-not $secretString) {
        try {
            $secretId = "$envCandidate/app-rw-secret"
            $cliOut = (aws secretsmanager get-secret-value --secret-id $secretId --region $Region 2>$null | ConvertFrom-Json)
            if (-not $cliOut) {
                $secretId = "$domainEnv/app-rw-secret"
                $cliOut = (aws secretsmanager get-secret-value --secret-id $secretId --region $Region 2>$null | ConvertFrom-Json)
            }
            if ($cliOut.SecretString) {
                $secretString = $cliOut.SecretString
            }
        } catch {}
    }

    if ($secretString) {
        $secretJson = $secretString | ConvertFrom-Json
        $cred = New-Object PSCredential ($secretJson.username, (ConvertTo-SecureString $secretJson.password -AsPlainText -Force))
    }
} catch {
    Write-Host "Warning: Could not retrieve secret from AWS Secrets Manager: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ======================================================================
# REPORT SERVER VALIDATION SCRIPTBLOCK (Executed on Target Nodes)
# ======================================================================
$ValidationScriptBlock = {
    param($RemoteCred)

    $comp = hostname
    $domain = $env:USERDOMAIN

    # Resolve local IPv4
    $ip = $null
    try {
        $dns = Resolve-DnsName -Name $comp -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq "A" } | Select-Object -First 1
        if ($dns) { $ip = $dns.IPAddress }
    } catch {}
    if (-not $ip) {
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($comp) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString
        } catch {}
    }
    if (-not $ip) { $ip = "127.0.0.1" }

    $reportUrl = "http://$ip/ReportServer"
    $wsdlUrl = "$reportUrl/ReportService2010.asmx?wsdl"

    # Use passed credential or attempt local retrieval
    $localCred = $RemoteCred
    if (-not $localCred) {
        try {
            $domainEnv = $domain.ToUpper().Split('-')[-1]
            $secId = "$domainEnv/app-rw-secret"
            if (Get-Command Get-SECSecretValue -ErrorAction SilentlyContinue) {
                $raw = Get-SECSecretValue -SecretId $secId -ErrorAction SilentlyContinue
                if ($raw.SecretString) {
                    $json = $raw.SecretString | ConvertFrom-Json
                    $localCred = New-Object PSCredential ($json.username, (ConvertTo-SecureString $json.password -AsPlainText -Force))
                }
            }
        } catch {}
    }

    # ------------------------------------------------------------------
    # 1. Report Server URL Accessibility & Content Check
    # ------------------------------------------------------------------
    $urlStatus = "Unknown"
    $urlDetailedError = ""
    try {
        $webParams = @{
            Uri             = $reportUrl
            UseBasicParsing = $true
            TimeoutSec      = 10
        }
        if ($localCred) {
            $webParams["Credential"] = $localCred
        } else {
            $webParams["UseDefaultCredentials"] = $true
        }
        $resp = Invoke-WebRequest @webParams -ErrorAction Stop
        $content = if ($resp.RawContent) { $resp.RawContent } else { $resp.Content }

        if ($resp.StatusCode -eq 200 -and
            $content -match "/ReportServer\s+-" -and
            $content -match "CoreCreditReports" -and
            $content -match "CoreIssueReports" -and
            $content -match "Microsoft SQL Server Reporting Services Version") {
            $urlStatus = "Accessible"
        } elseif ($resp.StatusCode -eq 200) {
            $urlStatus = "Content Mismatch"
        } else {
            $urlStatus = "HTTP $($resp.StatusCode)"
        }
    } catch {
        $urlStatus = "URL Not Accessible"
        $urlDetailedError = $_.Exception.Message
    }

    # ------------------------------------------------------------------
    # 2 & 3. Folder & Security Site Setting Permissions Validation
    # ------------------------------------------------------------------
    $folderOverall = "Unknown"
    $siteOverall = "Unknown"
    $proxy = $null

    try {
        $dynNamespace = "SSRS_" + [System.Guid]::NewGuid().ToString("N")
        if ($localCred) {
            $proxy = New-WebServiceProxy -Uri $wsdlUrl -Namespace $dynNamespace -Credential $localCred -ErrorAction Stop
        } else {
            $proxy = New-WebServiceProxy -Uri $wsdlUrl -Namespace $dynNamespace -UseDefaultCredential -ErrorAction Stop
        }
    } catch {
        $folderOverall = "Failed - Proxy Error: $($_.Exception.Message)"
        $siteOverall   = "Failed - Proxy Error: $($_.Exception.Message)"
    }

    $ExpectedFolderPermissions = @(
        @{ ShortUser = "Administrators"; Roles = @("Content Manager") },
        @{ ShortUser = "gmsa-web-svc$"; Roles = @("Browser", "Content Manager", "My Reports", "Publisher", "Report Builder") },
        @{ ShortUser = "gmsa-app-svc$"; Roles = @("Browser", "Content Manager", "My Reports", "Publisher", "Report Builder") },
        @{ ShortUser = "ccgs-app-rw";   Roles = @("Browser", "Content Manager", "My Reports", "Publisher", "Report Builder") },
        @{ ShortUser = "ccgs-sql-rw";   Roles = @("Browser", "Content Manager", "My Reports", "Publisher", "Report Builder") },
        @{ ShortUser = "ccgs-web-rw";   Roles = @("Browser", "Content Manager", "My Reports", "Publisher", "Report Builder") },
        @{ ShortUser = "ccgs-rpts-svc"; Roles = @("Browser", "Content Manager", "My Reports", "Publisher", "Report Builder") }
    )

    if ($proxy) {
        # Check 2: Folder Policies ("/")
        try {
            $policies, [ref]$inherited = $null, $false
            $policies = $proxy.GetPolicies("/", [ref]$inherited)

            $missingFolderUsers = @()
            foreach ($expected in $ExpectedFolderPermissions) {
                $shortUser = $expected.ShortUser
                $expectedRoles = $expected.Roles
                $matchedPolicy = $policies | Where-Object { $_.GroupUserName -like "*$shortUser" }

                if (-not $matchedPolicy) {
                    $missingFolderUsers += "$shortUser (User not found)"
                    continue
                }

                $actualRoles = $matchedPolicy.Roles | ForEach-Object { $_.Name }
                $missingRoles = $expectedRoles | Where-Object { $_ -notin $actualRoles }
                if ($missingRoles.Count -gt 0) {
                    $missingFolderUsers += "$shortUser (Missing: $($missingRoles -join ', '))"
                }
            }

            if ($missingFolderUsers.Count -gt 0) {
                $folderOverall = "Failed - " + ($missingFolderUsers -join "; ")
            } else {
                $folderOverall = "Passed"
            }
        } catch {
            $folderOverall = "Failed - $($_.Exception.Message)"
        }

        # Check 3: Security Site Setting Permissions
        $ExpectedSitePermissions = @(
            @{ ShortUser = "Administrators"; Roles = @("System Administrator") },
            @{ ShortUser = "gmsa-web-svc$"; Roles = @("System Administrator", "System User") },
            @{ ShortUser = "gmsa-app-svc$"; Roles = @("System Administrator", "System User") },
            @{ ShortUser = "ccgs-web-rw";   Roles = @("System Administrator", "System User") },
            @{ ShortUser = "ccgs-sql-rw";   Roles = @("System Administrator", "System User") },
            @{ ShortUser = "ccgs-rpts-svc"; Roles = @("System Administrator", "System User") },
            @{ ShortUser = "ccgs-app-rw";   Roles = @("System Administrator", "System User") }
        )

        try {
            $systemPolicies = $proxy.GetSystemPolicies()
            $missingSiteUsers = @()
            foreach ($expected in $ExpectedSitePermissions) {
                $shortUser = $expected.ShortUser
                $expectedRoles = $expected.Roles
                $matched = $systemPolicies | Where-Object { $_.GroupUserName -like "*$shortUser" }

                if (-not $matched) {
                    $missingSiteUsers += "$shortUser (User not found)"
                    continue
                }

                $actualRoles = $matched.Roles | ForEach-Object { $_.Name }
                $missingRoles = $expectedRoles | Where-Object { $_ -notin $actualRoles }
                if ($missingRoles.Count -gt 0) {
                    $missingSiteUsers += "$shortUser (Missing: $($missingRoles -join ', '))"
                }
            }

            if ($missingSiteUsers.Count -gt 0) {
                $siteOverall = "Failed - " + ($missingSiteUsers -join "; ")
            } else {
                $siteOverall = "Passed"
            }
        } catch {
            $siteOverall = "Failed - $($_.Exception.Message)"
        }
    }

    # ------------------------------------------------------------------
    # 4. ReportServer Windows Service Validation
    # ------------------------------------------------------------------
    $serviceName = "SQL Server Reporting Services (REPORTSERVER)"
    $expectedAccountName = "$domain\ccgs-rpts-svc"
    $serviceState = "Unknown"
    $serviceAccount = "Unknown"
    $serviceOverall = "Unknown"

    try {
        $svc = Get-Service -Name $serviceName -ErrorAction Stop
        $serviceState = $svc.Status.ToString()
        $wmi = Get-WmiObject -Class Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction Stop
        $serviceAccount = $wmi.StartName

        $accountOk = ($serviceAccount -like "*ccgs-rpts-svc*")
        if ($serviceState -eq "Running" -and $accountOk) {
            $serviceOverall = "Passed"
        } elseif ($serviceState -eq "Running") {
            $serviceOverall = "Failed - Wrong account ($serviceAccount)"
        } else {
            $serviceOverall = "Failed - State: $serviceState"
        }
    } catch {
        $serviceOverall = "Failed - $($_.Exception.Message)"
    }

    [PSCustomObject]@{
        ServerName       = $comp
        IPAddress        = $ip
        ReportURL        = $reportUrl
        URLStatus        = $urlStatus
        URLDetailedError = $urlDetailedError
        FolderOverall    = $folderOverall
        SiteOverall      = $siteOverall
        ServiceName      = $serviceName
        ServiceState     = $serviceState
        ServiceAccount   = $serviceAccount
        ServiceOverall   = $serviceOverall
    }
}

# ======================================================================
# FETCH MASTER HOST BASELINE
# ======================================================================
$option = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 20000

if ($MasterHost -eq $env:COMPUTERNAME) {
    $MasterData = & $ValidationScriptBlock $cred
} else {
    $MasterData = Invoke-Command -ComputerName $MasterHost -SessionOption $option -ArgumentList $cred -ErrorAction inquire -ScriptBlock $ValidationScriptBlock
}

# ======================================================================
# EXPECTED VALUES
# ======================================================================
$ExpectedServerCount = $ServerList.Count
$ExpectedURLStatus = "Accessible"
$ExpectedFolderPerm = "Passed"
$ExpectedSitePerm = "Passed"
$ExpectedServiceName = "SQL Server Reporting Services (REPORTSERVER)"
$ExpectedServiceState = "Running"
$ExpectedServiceAccount = "$Domain\ccgs-rpts-svc"

# ======================================================================
# INITIALIZE HTML OUTPUT (Matching ReportDelivery-Validation Format)
# ======================================================================
$Outputreport = "<HTML><TITLE> $Module Validation Report </TITLE>
                 <BODY background-color:peachpuff>
                 <font color =""#4682B4"" face=""Microsoft Tai le"">
                 <H2>$($EnvironmentName.ToUpper()) - $($Environmentpod.ToUpper()) - Report Server Validation Report</H2>
                 <H3>PLEASE VERIFY BELOW TABLE VALUES AND COMPARE WITH EXPECTED VALUES</H3></font>
                 <Table border=1 cellpadding=0 cellspacing=0>
                 <TR bgcolor=gray align=center>
                   <TD><B>Master Host</B></TD>
                   <TD><B>IP Address</B></TD>
                   <TD><B>Report Server URL</B></TD>
                   <TD><B>URL Status</B></TD>
                   <TD><B>Folder Permissions</B></TD>
                   <TD><B>Site Permissions</B></TD>
                   <TD><B>Service Name</B></TD>
                   <TD><B>Service State</B></TD>
                   <TD><B>Service Account</B></TD>
                 </TR>"

$masterIP = if ($MasterData.IPAddress) { $MasterData.IPAddress } else { "-" }
$masterURL = if ($MasterData.ReportURL) { $MasterData.ReportURL } else { "-" }

# In Expected Table (Table 1), Expected status is always "Passed" and expected configuration
$Outputreport += "<TR align=center>
                   <TD>$("$MasterHost".ToUpper())</TD>
                   <TD align=center>$masterIP</TD>
                   <TD align=center>$masterURL</TD>
                   <TD align=center>$ExpectedURLStatus</TD>
                   <TD align=center>$ExpectedFolderPerm</TD>
                   <TD align=center>$ExpectedSitePerm</TD>
                   <TD align=center>$ExpectedServiceName</TD>
                   <TD align=center>$ExpectedServiceState</TD>
                   <TD align=center>$ExpectedServiceAccount</TD>
                  </TR>"

# ======================================================================
# EXECUTE VALIDATION ACROSS ALL REPORT SERVERS
# ======================================================================
$Result = @()
$option = New-PSSessionOption -ProxyAccessType NoProxyServer

if ($ServerList.Count -eq 1 -and $ServerList[0] -eq $env:COMPUTERNAME) {
    $Result = @(& $ValidationScriptBlock $cred)
} else {
    $Result = @(Invoke-Command -ComputerName $ServerList -SessionOption $option -ArgumentList $cred -ErrorAction inquire -ScriptBlock $ValidationScriptBlock)
}

# ======================================================================
# SERVER COUNT VERIFICATION HEADING
# ======================================================================
if($ServerList.Count -eq $ExpectedServerCount)
{
$Outputreport += "</Table>
                 <font color =""#4682B4"" face=""Microsoft Tai le"">
                   <H4>  Report Server Validation Report - Server Count $($Result.count) </H4></font>"
}else{
$Outputreport += "</Table>
                 <font color =""#CD5C5C"" face=""Microsoft Tai le"">
                   <H4>Report Server Validation Report - Server Count $($Result.count) is not matching with expected count $ExpectedServerCount </H4></font>"
}

# ======================================================================
# DETAIL TABLE FOR ALL REPORT SERVERS (Actual Output)
# ======================================================================
$Outputreport += "<Table border=1 cellpadding=0 cellspacing=0>
                 <TR bgcolor=gray align=center>
                    <TD><B>Report Server</B></TD>
                    <TD><B>IP Address</B></TD>
                    <TD><B>Report Server URL</B></TD>
                    <TD><B>URL Status</B></TD>
                    <TD><B>Folder Permissions</B></TD>
                    <TD><B>Site Permissions</B></TD>
                    <TD><B>Service Name</B></TD>
                    <TD><B>Service State</B></TD>
                    <TD><B>Service Account</B></TD>
                 </TR>"

Foreach($Entry in $Result){
    # Cell-level highlighting (white if matching expected, LightSalmon if mismatched/failed)
    $urlCellColor = if ($Entry.URLStatus -eq "Accessible") { "" } else { "bgcolor=LightSalmon" }
    $folderCellColor = if ($Entry.FolderOverall -like "Pass*") { "" } else { "bgcolor=LightSalmon" }
    $siteCellColor = if ($Entry.SiteOverall -like "Pass*") { "" } else { "bgcolor=LightSalmon" }
    $svcNameCellColor = if ($Entry.ServiceName -like "*Reporting Services*") { "" } else { "bgcolor=LightSalmon" }
    $svcStateCellColor = if ($Entry.ServiceState -eq "Running") { "" } else { "bgcolor=LightSalmon" }
    $svcAccountCellColor = if ($Entry.ServiceAccount -like "*ccgs-rpts-svc*") { "" } else { "bgcolor=LightSalmon" }

    $serviceNameVal = if ($Entry.ServiceName) { $Entry.ServiceName } else { "SQL Server Reporting Services (REPORTSERVER)" }

    $Outputreport += "<TR align=center>
                        <TD>$($Entry.ServerName)</TD>
                        <TD align=center>$($Entry.IPAddress)</TD>
                        <TD align=center>$($Entry.ReportURL)</TD>
                        <TD $urlCellColor align=center>$($Entry.URLStatus)</TD>
                        <TD $folderCellColor align=center>$($Entry.FolderOverall)</TD>
                        <TD $siteCellColor align=center>$($Entry.SiteOverall)</TD>
                        <TD $svcNameCellColor align=center>$serviceNameVal</TD>
                        <TD $svcStateCellColor align=center>$($Entry.ServiceState)</TD>
                        <TD $svcAccountCellColor align=center>$($Entry.ServiceAccount)</TD>
                      </TR>"
}

$Outputreport += "</Table></BODY></HTML>"

# ======================================================================
# SAVE & UPLOAD REPORT TO S3
# ======================================================================
if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null }
$ReportFileNamePrefix = $Module + "_Validation_"
$ReportFile = "C:\Temp\$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd-hhmm).html"
$Outputreport | Out-File "$ReportFile" -Encoding UTF8
aws s3 cp $ReportFile "s3://corecard-$Environmentpod-$EnvironmentName-$Region-config-files/EnvironmentValidationReports/$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd).html"

if($host.Name -eq "Windows PowerShell ISE Host"){
    Invoke-Item $ReportFile
} else {
    try { Start-Process $ReportFile } catch {}
}

# ======================================================================
# CLEANUP VARIABLES
# ======================================================================
Clear-Variable Module -ErrorAction SilentlyContinue
Clear-Variable ServerType -ErrorAction SilentlyContinue
Clear-Variable Domain -ErrorAction SilentlyContinue
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
