Clear-Host
Get-ChildItem D:\ -Recurse | Unblock-File
$Module = "Web-Services"
$ServerType = 'web'
$AppServerType = 'svc'
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

$CoreAppServicesServerList = (aws ec2 describe-instances --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,Environment:Tags[?Key=='environment']|[0].Value,Status:State.environment,Stack:Tags[?Key=='stack']|[0].Value,Status:State.stack,Attribution:Tags[?Key=='attribution']|[0].Value,Status:State.attribution}" --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='*$AppServerType$ShortRegion$EnvironmentName$EnvironmentStack*'" "Name=availability-zone,Values='*'" --region $Region | ConvertFrom-Json)
$CoreAppServicesServerList.Name

$MasterHost = $ServerList | Select-Object -First 1

If (Test-Connection $MasterHost -Quiet){
Write-Host "Master Host - " $MasterHost
}
else{
$MasterHost = $ServerList | Select-Object -Last 1
Write-Host "Master Host - " $MasterHost
}

$option = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 20000
$MasterSVCHandlerVersion = Invoke-Command -ComputerName $MasterHost -SessionOption $option -ErrorAction inquire -ScriptBlock {
$MasterSVCHandlerVersion = (Get-Command D:\WebServer\Services\bin\dbbHandler2005.dll).FileVersionInfo.FileVersion
$MasterSVCHandlerVersion}

$MasterCoreCardServicesGatewayVersion = Invoke-Command -ComputerName $MasterHost -SessionOption $option -ErrorAction inquire -ScriptBlock {
$MasterCoreCardServicesGatewayVersion = (Get-Command D:\WebServer\Services\CoreCardServicesGateway\bin\AccountSummaryGateway.dll).FileVersionInfo.FileVersion
$MasterCoreCardServicesGatewayVersion}

$MasterScaleServiceVersion = Invoke-Command -ComputerName $MasterHost -SessionOption $option -ErrorAction inquire -ScriptBlock {
$file = "D:\WebServer\ScaleService\dbbScaleService.exe"
If (Test-Path $file){
$MasterScaleServiceVersion = (Get-Command $file).FileVersionInfo.FileVersion} 
else{
$MasterScaleServiceVersion = "ScaleService does not exist"}
$MasterScaleServiceVersion}

$MasterSVCWebsiteHash = Invoke-Command -ComputerName $MasterHost -SessionOption $option -ErrorAction inquire -ScriptBlock {
(Get-ChildItem -Path D:\WebServer\Services\ -Recurse -Filter *.* | Get-FileHash).Hash | %{ $MasterSVCWebsiteHash += "$_"}
$MasterSVCWebsite_stream = [IO.MemoryStream]::new([byte[]][char[]]$MasterSVCWebsiteHash)
$MasterSVCWebsiteHash = (Get-FileHash -InputStream $MasterSVCWebsite_stream).Hash
$MasterSVCWebsiteHash}


$ExpectedWEBServerCount = 2
$Expectedenable32BitAppOnWin64 = "False"
$ExpectedidleTimeoutAction = "Suspend"
$ExpectedLoadUserProfile = "True"
$ExpectedmaxProcesses = "4"
$ExpectedPrivateMemoryLimit = "0"
$ExpectedRecyclingPeriodicRestartTime = "1740"
$ExpectedAnonymousAuthentication = "Application Pool Identity"
$ExpectedAppPooluserName = ((whoami).TOLOWER()).Split('\')[0] + '\gMSA-web-svc$'
$ExpectedConnectAs = "Pass-through Authentication"
$ExpectedSiteBindingprotocol = "https"
$ExpectedXRequestID = "X-Request-ID"
$ExpectedASStatus = "Method not allowed"
$ExpectedPASRequest = "Method not allowed"
$ExpectedLAStatus = "Method not allowed"
$ExpectedHandlerHealth = "Healthy"
$ExpectedCoreCardServicesGatewayWorking = "Working"
$ExpectedServerIPHealth = "True"

if (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "perf") -and ($Environmentattributon -eq "cookie")){
$ExpectedWEBServerCount = "45" 
$ExpectedmaxProcesses = "16"
$ExpectedPrivateMemoryLimit = "819200"
$ExpectedRecyclingPeriodicRestartTime = "1740"}
elseif (($EnvironmentName -eq "prod" -or $EnvironmentName -eq "uat2" -or $EnvironmentName -eq "mock") -and ($Environmentattributon -eq "jazz")){
$ExpectedWEBServerCount = "30"
$ExpectedmaxProcesses = "16"
$ExpectedPrivateMemoryLimit = "819200"
$ExpectedRecyclingPeriodicRestartTime = "1740"}
$ExpectedServicesHandlerLogs = "D:\LOGs\ServicesHandlerLogs"
$ExpectedCoreCardServicesLogs = "D:\LOGs\CoreCardServicesGateway"


$Outputreport = "<HTML><TITLE> $Module Validation Report </TITLE>
                 <BODY background-color:peachpuff>
                 <font color =""#4682B4"" face=""Microsoft Tai le"">
                 <H2>$($EnvironmentName.ToUpper()) - $($Environmentpod.ToUpper()) - $Module Validation Report</H2>
                 <H3>PLEASE VERIFY BELOW TABLE VALUES AND COMPARE WITH EXPECTED VALUES</H3></font>
                 <Table border=1 cellpadding=0 cellspacing=0>
                 <TR bgcolor=gray align=center>
                   <TD><B>Master Host</B></TD>
                   <TD><B>SVC Handler Version</B></TD>
                   <TD><B>CoreCardServicesGateway Version</B></TD>
                   <TD><B>Scale Service Version</B></TD>
                   <TD><B>Services Website Hash</B></TD>
                   <TD><B>32Bit Enable</B></TD>
                   <TD><B>Idle Timeout Action</B></TD>
                   <TD><B>Load User Profile</B></TD>
                   <TD><B>Max Worker Processes</B></TD>
                   <TD><B>Private Memory Limit</B></TD>
                   <TD><B>Recycling Periodic Restart Time (in min)</B></TD>
                   <TD><B>Anonymous Authentication</B></TD>
                   <TD><B>AppPool userName</B></TD>
                   <TD><B>ConnectAs</B></TD>
                   <TD><B>Site Protocols</B></TD>
                   <TD><B>XRequestID</B></TD>
                   <TD><B>Account Summary URL Status</B></TD>
                   <TD><B>Person Account Summary URL Status</B></TD>
                   <TD><B>List Accounts URL Status</B></TD>
                   <TD><B>CoreCardServicesGateway URL Status</B></TD>
                   <TD><B>Handler URL Status</B></TD>
                   <TD><B>NLB URL & Status</B></TD>
                   <TD><B>ServicesHandler Logs</B></TD>
                   <TD><B>CoreCardServices Logs</B></TD>
                   </TR>"
                   

$Outputreport += "<TR align=center>"
$Outputreport += "<TD>$("$MasterHost".ToUpper())</TD>
                   <TD>$("$MasterSVCHandlerVersion")</TD>
                   <TD>$("$MasterCoreCardServicesGatewayVersion")</TD>
                   <TD>$("$MasterScaleServiceVersion")</TD>
                   <TD>$("True")</TD>
                   <TD>$("$Expectedenable32BitAppOnWin64")</TD>
                   <TD>$("$ExpectedidleTimeoutAction")</TD>
                   <TD>$("$ExpectedLoadUserProfile")</TD>
                   <TD>$("$ExpectedmaxProcesses")</TD>
                   <TD>$("$ExpectedPrivateMemoryLimit")</TD>
                   <TD>$("$ExpectedRecyclingPeriodicRestartTime")</TD>
                   <TD>$("$ExpectedAnonymousAuthentication")</TD>
                   <TD>$("$ExpectedAppPooluserName")</TD>
                   <TD>$("$ExpectedConnectAs")</TD>
                   <TD>$("$ExpectedSiteBindingprotocol")</TD>
                   <TD>$("$ExpectedXRequestID")</TD>
                   <TD>$("$ExpectedASStatus")</TD>
                   <TD>$("$ExpectedPASRequest")</TD>
                   <TD>$("$ExpectedLAStatus")</TD>
                   <TD>$("$ExpectedCoreCardServicesGatewayWorking")</TD>                   
                   <TD>$("$ExpectedHandlerHealth")</TD>
                   <TD>$("$ExpectedServerIPHealth")</TD>
                   <TD>$("$ExpectedServicesHandlerLogs")</TD>
                   <TD>$("$ExpectedCoreCardServicesLogs")</TD>
                  </TR>"




$Result = @() 


$option = New-PSSessionOption -ProxyAccessType NoProxyServer 
$result += Invoke-Command -ComputerName $ServerList -SessionOption $option -ErrorAction inquire -ScriptBlock {
$computername = hostname
Import-Module WebAdministration
$SVCHandlerVersion = (Get-Command D:\WebServer\Services\bin\dbbHandler2005.dll).FileVersionInfo.FileVersion
$CoreCardServicesGatewayVersion = (Get-Command D:\WebServer\Services\CoreCardServicesGateway\bin\AccountSummaryGateway.dll).FileVersionInfo.FileVersion
$ServerSVCWebsiteHash = $NULL
(Get-ChildItem -Path D:\WebServer\Services\ -Recurse -Filter *.* | Get-FileHash).Hash | %{ $ServerSVCWebsiteHash += "$_"}
$ServerSVCWebsite_stream = [IO.MemoryStream]::new([byte[]][char[]]$ServerSVCWebsiteHash)
$ServerSVCWebsiteHash = (Get-FileHash -InputStream $ServerSVCWebsite_stream).Hash
#$ScaleServiceVersion = (Get-Command D:\WebServer\ScaleService\dbbScaleService.exe).FileVersionInfo.FileVersion
$file = "D:\WebServer\ScaleService\dbbScaleService.exe"
If (Test-Path $file){
$ScaleServiceVersion = (Get-Command $file).FileVersionInfo.FileVersion} 
else{
$ScaleServiceVersion = "ScaleService does not exist"}
$enable32BitAppOnWin64 = (Get-ItemProperty IIS:\AppPools\Services).enable32BitAppOnWin64
$managedPipelineMode = (Get-ItemProperty IIS:\AppPools\Services).managedPipelineMode
$state = (Get-ItemProperty IIS:\AppPools\Services).state
$idleTimeoutAction = Get-ItemProperty "IIS:\AppPools\Services" -Name processModel.idleTimeoutAction
$LoadUserProfile = Get-ItemProperty "IIS:\AppPools\Services" -Name processModel.LoadUserProfile.Value
$maxProcesses = Get-ItemProperty "IIS:\AppPools\Services" -Name processModel.maxProcesses.Value
$PrivateMemoryLimit = (Get-ItemProperty IIS:\apppools\Services -Name recycling.periodicrestart.privateMemory).value
$RecyclingPeriodicRestartTime = ((Get-ItemProperty -Path "IIS:\AppPools\Services" -Name Recycling.PeriodicRestart.Time).value.TotalMinutes)
$AnonymousAuthentication = (Get-WebConfigurationProperty -Filter '/system.webServer/security/authentication/anonymousAuthentication'  -PSPath 'IIS:\' -Location "Services" -Name userName).Value
if($AnonymousAuthentication -eq ""){$AnonymousAuthentication = "Application Pool Identity"}
#else{$AnonymousAuthentication = "Application Pool Identity"}
$AppPooluserName = Get-ItemProperty "IIS:\AppPools\Services" -Name processModel.userName.Value
$ConnectAs = (Get-WebConfiguration "/system.applicationHost/sites/site[@name='Services']/application[@path='/']/VirtualDirectory[@path='/']").UserName
if($ConnectAs -eq ""){$ConnectAs = "Pass-through Authentication"}
#else{Write-Host "Connect AS- User Set:$ConnectAs"}
$SiteBindingprotocol = (Get-IISSite "Services").bindings.protocol #| select-object protocol, bindingInformation
$SiteBindingInfo = (Get-IISSite "Services").bindings.bindingInformation
$XRequestID = (Get-ItemProperty 'IIS:\Sites\Services' -Name logfile.customFields.collection).logFieldName

$ServerIPHealth =$NULL
$CoreCardServicesGatewayURL = (Select-String -Path D:\WebServer\Services\CoreCardServicesGateway\Web.config -Pattern "WCFEndPointWithoutSharding").ToString().Split('=')[2].Split('"')[1]
$ServerIPHealth = (Select-String -Path D:\WebServer\Services\Web.config -Pattern "ServerIP").ToString().Split('=')[2].Split('"')[1]

$CoreCardServicesLogsTemp = (Select-String -Path "D:\WebServer\Services\CoreCardServicesGateway\log4net.config" -Pattern "file type").ToString().Split('=')[2].Split('"')[1]
$CoreCardServicesLogs = $CoreCardServicesLogsTemp -replace '\\%.*$',''
#$ServicesHandlerLogs = (Select-String -Path D:\WebServer\Services\Web.config -Pattern "ServicesHandlerLogs").ToString().Split('=')[2].Split('"')[1]

$ServicesHandlerLogsTemp = (Select-String -Path "D:\WebServer\Services\Web.config" -Pattern "internalLogFile=").ToString().Split('=')[2].Split('"')[1]
$ServicesHandlerLogs = $ServicesHandlerLogsTemp -replace '\\nlog.txt$',''

# Ensure that $CoreCardServicesGatewayLog has a valid value
If((Test-Path $ServicesHandlerLogs) -and (Test-Path $CoreCardServicesLogs)){
    $HandlerLogs = "Passed"
} Else {
    $HandlerLogs = "Failed"
}
  
  
$resultvalue = @() 
$resultvalue = [PSCustomObject] @{ 
    ServerName = "$($computername)"
    SVCHandlerVersion = "$($SVCHandlerVersion)"
    CoreCardServicesGatewayVersion = "$($CoreCardServicesGatewayVersion)"
    ScaleServiceVersion = "$($ScaleServiceVersion)"
    ServerSVCWebsiteHash = "$($ServerSVCWebsiteHash)"
    enable32BitAppOnWin64 = "$($enable32BitAppOnWin64)"
    managedPipelineMode = "$($managedPipelineMode)"
    state = "$($state)"
    idleTimeoutAction = "$($idleTimeoutAction)"
    LoadUserProfile = "$($LoadUserProfile)"
    maxProcesses = "$($maxProcesses)"
    PrivateMemoryLimit = "$($PrivateMemoryLimit)"
    RecyclingPeriodicRestartTime = "$($RecyclingPeriodicRestartTime)"
    AnonymousAuthentication = "$($AnonymousAuthentication)"
    AppPooluserName = "$($AppPooluserName)"
    ConnectAs = "$($ConnectAs)"
    SiteBindingprotocol = "$($SiteBindingprotocol)"
    SiteBindingInfo = "$($SiteBindingInfo)"
    XRequestID = "$($XRequestID)"
    CoreCardServicesGatewayURL = "$($CoreCardServicesGatewayURL)"
    ServerIPHealth = "$($ServerIPHealth)"
    ServicesHandlerLogs = "$($ServicesHandlerLogs)"
    CoreCardServicesLogs = "$($CoreCardServicesLogs)"
	}
$resultvalue
}

if($Serverlist.Count -eq $ExpectedWEBServerCount)
{
$Outputreport += "</Table>
                 <font color =""#4682B4"" face=""Microsoft Tai le"">
                   <H4>  Services Website Validation Report - Server Count $($result.count) </H4></font>"


}else{
$Outputreport += "</Table>
                 <font color =""#CD5C5C"" face=""Microsoft Tai le"">
                   <H4>Services Website Validation Report - Server Count $($result.count) is not matching with expected count $ExpectedWEBServerCount </H4></font>"
}


$Outputreport += "<Table border=1 cellpadding=0 cellspacing=0>
                 <TR bgcolor=gray align=center>
                    <TD><B>WEB Server</B></TD>
                   <TD><B>Services Handler Version</B></TD>
                   <TD><B>CoreCardServicesGateway Version</B></TD>
                   <TD><B>Services Service Version</B></TD>
                   <TD><B>Services website Hash</B></TD>
                   <TD><B>32Bit Enable</B></TD>
                   <TD><B>Idle Timeout Action</B></TD>
                   <TD><B>Load user Profile</B></TD>
                   <TD><B>Max Worker Processes</B></TD>
                   <TD><B>Private Memory Limit</B></TD>
                   <TD><B>Recycling Periodic Restart Time(in min)</B></TD>
                   <TD><B>Anonymous Authentication</B></TD>
                   <TD><B>AppPool userName</B></TD>
                   <TD><B>ConnectAs</B></TD>
                   <TD><B>Site Protocols</B></TD>
                   <TD><B>Site Bindings</B></TD>
                   <TD><B>XRequestID</B></TD>
                   <TD><B>Account Summary URL</B></TD>
                   <TD><B>Person Account Sumary URL</B></TD>
                   <TD><B>List Accounts URL</B></TD>
                   <TD><B>CoreCardServicesGateway URL</B></TD>
                   <TD><B>Handler URL</B></TD>
                   <TD><B>NLB URL & Status</B></TD>
                   <TD><B>ServicesHandler Logs</B></TD>
                   <TD><B>CoreCardServices Logs</B></TD>
                   </TR>"

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

$Entry = $NULL
Foreach($Entry in $Result){ 
$ASRequest = $NULL
$PASRequest = $NULL
$LARequest = $NULL
$HandlerHealthRequest = $NULL




 
$IPAddress = (Resolve-DnsName $Entry.ServerName | Where-Object Type -eq "A").IpAddress
try {
$ASURL = "https://$IPAddress/CoreCardServices/CoreCardServices.svc/AccountSummary"
$ASRequest = Invoke-WebRequest $ASURL -UseBasicParsing
} catch {

    $ASstring_err = $_ | Out-String

}

$ASStatus = $ASstring_err | Select-String "Method not allowed" |ForEach-Object { $_.Matches.Value }
if ($ASStatus -eq $NULL) {$ASStatus = "Not Working"}
$ASURL
$ASStatus

try {
$PASURL = "https://$IPAddress/CoreCardServices/CoreCardServices.svc/PersonAccountSummary"
$PASRequest = Invoke-WebRequest $PASURL -UseBasicParsing
} catch {

    $PASstring_err = $_ | Out-String

}

$PASStatus = $PASstring_err | Select-String "Method not allowed" |ForEach-Object { $_.Matches.Value }
if ($PASStatus -eq $NULL) {$PASStatus = "Not Working"}
$PASURL
$PASStatus


try {
$LAURL = "https://$IPAddress/CoreCardServices/CoreCardServices.svc/ListAccounts"
$LARequest = Invoke-WebRequest $LAURL -UseBasicParsing
} catch {

    $LAstring_err = $_ | Out-String

}

$LAStatus = $LAstring_err | Select-String "Method not allowed" |ForEach-Object { $_.Matches.Value }
if ($LAStatus -eq $NULL) {$LAStatus = "Not Working"}
$LAURL
$LAStatus



try {
$HandlerHealthURL = "https://$IPAddress/CoreCardServices/CoreCardServices.svc/appServices.aspx?geTservletversion=1"
$HandlerHealthRequest = Invoke-WebRequest $HandlerHealthURL -UseBasicParsing
} catch {

    $HandlerHealthstring_err = $_ | Out-String

}

$HandlerHealthStatus = $HandlerHealthRequest.StatusCode
$HandlerHealthContent = $HandlerHealthRequest.Content | Select-String "serverPort=0" |ForEach-Object { $_.Matches.Value }
if (($HandlerHealthContent -eq "serverPort=0") -and ($HandlerHealthStatus	-eq 200))
{
$HandlerHealthWorking="Healthy"
}
else
{
$HandlerHealthWorking="Not Healthy"
$HandlerHealthContent = $NULL
}
$HandlerHealthURL
$HandlerHealthStatus
$HandlerHealthContent

$CoreCardServicesGatewayRequest = $NULL
$CoreCardServicesGatewayRequest = Invoke-WebRequest $Entry.CoreCardServicesGatewayURL
$CoreCardServicesGatewayURL = $Entry.CoreCardServicesGatewayURL
$CoreCardServicesGatewayStatus = $NULL
$CoreCardServicesGatewayStatus = $CoreCardServicesGatewayRequest.StatusCode


if($CoreCardServicesGatewayStatus -eq 200)
{

$CoreCardServicesGatewayWorking="Working"
}
else
{

$CoreCardServicesGatewayWorking="Not Working"
}


$ServerIPHealthRequest = Test-NetConnection $Entry.ServerIPHealth -port 4422


$ServerIPHealthRequestStatus = $ServerIPHealthRequest.TcpTestSucceeded
$ServerIPHealthRequestStatusWorking = $null

if ($ServerIPHealthRequestStatus -eq "True")
{
$ServerIPHealthRequestStatusWorking="True"
}
else
{
$ServerIPHealthRequestStatusWorking="False"
}

$ServerIPHealthRequestStatusWorking


if(($Entry.ScaleServiceVersion -eq $MasterScaleServiceVersion) `
-and ($Entry.CoreCardServicesGatewayVersion -eq $MasterCoreCardServicesGatewayVersion) `
-and ($Entry.ScaleServiceVersion -eq $MasterScaleServiceVersion) `
-and ($Entry.ServerSVCWebsiteHash -eq $MasterSVCWebsiteHash) `
-and ($Entry.enable32BitAppOnWin64 -eq $Expectedenable32BitAppOnWin64) `
-and ($Entry.idleTimeoutAction -eq $ExpectedidleTimeoutAction) `
-and ($Entry.LoadUserProfile -eq $ExpectedLoadUserProfile) `
-and ($Entry.maxProcesses -eq $ExpectedmaxProcesses) `
-and ($Entry.PrivateMemoryLimit -eq $ExpectedPrivateMemoryLimit) `
-and ($Entry.RecyclingPeriodicRestartTime -eq $ExpectedRecyclingPeriodicRestartTime) `
-and ($Entry.AnonymousAuthentication -eq $ExpectedAnonymousAuthentication) `
-and ($Entry.AppPooluserName -eq $ExpectedAppPooluserName) `
-and ($Entry.ConnectAs -eq  $ExpectedConnectAs ) `
-and ($Entry.SiteBindingprotocol -eq $ExpectedSiteBindingprotocol) `
-and ($Entry.XRequestID -eq $ExpectedXRequestID) `
-and ($ASStatus -eq $ExpectedASStatus) `
-and ($PASStatus -eq $ExpectedPASRequest) `
-and ($LAStatus -eq $ExpectedLAStatus) `
-and ($CoreCardServicesGatewayWorking -eq $ExpectedCoreCardServicesGatewayWorking) `
-and ($HandlerHealthWorking -eq $ExpectedHandlerHealth) `
-and ($ServerIPHealthRequestStatusWorking -eq $ExpectedServerIPHealth)`
-and ($Entry.ServicesHandlerLogs -eq $ExpectedServicesHandlerLogs)`
-and ($Entry.CoreCardServicesLogs -eq $ExpectedCoreCardServicesLogs))
{
$Outputreport += "<TR align=center>" 
}else{
$Outputreport += "<TR bgcolor=LightSalmon align=center>"
}

$Outputreport += "<TD>$($Entry.ServerName)</TD>
                  <TD align=center>$($Entry.SVCHandlerVersion)</TD>
                  <TD align=center>$($Entry.CoreCardServicesGatewayVersion)</TD>
                  <TD align=center>$($Entry.ScaleServiceVersion)</TD>
                  <TD align=center>$($Entry.ServerSVCWebsiteHash -eq $MasterSVCWebsiteHash)</TD>
                  <TD align=center>$($Entry.enable32BitAppOnWin64)</TD>
                  <TD align=center>$($Entry.idleTimeoutAction)</TD>
                  <TD align=center>$($Entry.LoadUserProfile)</TD>
                  <TD align=center>$($Entry.maxProcesses)</TD>
                  <TD align=center>$($Entry.PrivateMemoryLimit)</TD>
                  <TD align=center>$($Entry.RecyclingPeriodicRestartTime)</TD>
                  <TD align=center>$($Entry.AnonymousAuthentication)</TD>
                  <TD align=center>$($Entry.AppPooluserName)</TD>
                  <TD align=center>$($Entry.ConnectAs)</TD>
                  <TD align=center>$($Entry.SiteBindingprotocol)</TD>
                  <TD align=center>$($Entry.SiteBindingInfo)</TD>
                  <TD align=center>$($Entry.XRequestID)</TD>
                  <TD align=center><p>$ASURL </br> $ASStatus</p></TD>
                  <TD align=center><p>$PASURL </br> $PASStatus</p></TD>
                  <TD align=center><p>$LAURL $LAStatus</p></TD>
                  <TD align=center><p>$CoreCardServicesGatewayURL $CoreCardServicesGatewayWorking</p></TD>
                  <TD align=center><p>$HandlerHealthURL </br> $HandlerHealthStatus </br> $HandlerHealthWorking</p></TD>
                  <TD align=center><p>$($Entry.ServerIPHealth) </br> $ServerIPHealthRequestStatusWorking
                  <TD align=center>$($Entry.ServicesHandlerLogs)</TD>
                  <TD align=center>$($Entry.CoreCardServicesLogs)</p></TD></TR>"
Clear-Variable ASstring_err
Clear-Variable ASURL
Clear-Variable ASSTATUS
Clear-Variable IPAddress

Clear-Variable PASstring_err
Clear-Variable PASURL
Clear-Variable PASSTATUS

Clear-Variable LAstring_err
Clear-Variable LAURL
Clear-Variable LASTATUS

Clear-Variable HandlerHealthURL
Clear-Variable HandlerHealthStatus
Clear-Variable HandlerHealthWorking

Clear-Variable ASRequest
Clear-Variable PASRequest
Clear-Variable LARequest
Clear-Variable HandlerHealthRequest

Clear-Variable CoreCardServicesGatewayRequest
Clear-Variable CoreCardServicesGatewayURL
Clear-Variable CoreCardServicesGatewayWorking

#Clear-Variable ServerIPHealth
Clear-Variable ServerIPHealthRequestStatus
Clear-Variable ServerIPHealthRequestStatusWorking
Clear-Variable ServerIPHealthRequest

}

$Outputreport += "</Table></BODY>
                  </HTML>" 

$Outputreport += "</Table></BODY>
                  </HTML>" 


$Results = $NULL
$Results = @()


foreach ($Server in $CoreAppServicesServerList) {

$HealthWebcallURL = $NULL
$HealthWebcallStatus = $NULL
$HealthWebcall = $NULL

try{

$HealthWebcallURL = "http://$($Server.Name)" + ":7011/healthy"

$HealthWebcall = Invoke-WebRequest -Uri  "$HealthWebcallURL" -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue 
}
catch{Write-Host -ForegroundColor Red "$($Server.Name)- Unable to verify health port or there is some issue in HealthWebcallURL"}

  $HealthWebcallStatus = if($HealthWebcall.StatusCode -eq "200"){"HEALTHY"}
    Else{"NOT HEALTHY"}

    
    $Results += [PSCustomObject]@{
        Server = $Server.Name
        HealthWebcallStatus = $HealthWebcallStatus
        AvailabilityZone    = $Server.AvailabilityZone
    }

}
    
      
$Outputreport += @"
<html>
<head>   
    <style>
        h2 {
            color: #4682B4;
        }       
        .unhealthy {
            background-color: #FFA07A;
        }
    </style>
</head>
<BODY background-color:peachpuff>
    <h2>$AppServerType -Server Health Check Results</h2>
    <Table border=1 cellpadding=0 cellspacing=0>
    <TR bgcolor=gray align=center>        
            <th>Server</th>
            <th>AvailabilityZone</th>
            <th>HealthWebcall</th>
        </TR>
"@

foreach ($Results1 in $Results) {
    $statusClass = if ($Results1.HealthWebcallStatus -eq "NOT HEALTHY") { 'unhealthy' } else { '' }

    $Outputreport += @"
        <tr class='$statusClass'>
            <td>$($Results1.Server)</td>
            <td>$($Results1.AvailabilityZone)</td>
            <td>$($Results1.HealthWebcallStatus)</td>
        </tr>
"@
}

$Outputreport += @"
    </table>
</body>
</html>
"@

$ReportFileNamePrefix = $Module +"_Validation_"
$ReportFile = "C:\Temp\$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd-hhmm).html"
$Outputreport | out-file "$ReportFile"
aws s3 cp $ReportFile "s3://corecard-$Environmentpod-$EnvironmentName-$Region-config-files/EnvironmentValidationReports/$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd).html"

if($host.Name -eq "Windows PowerShell ISE Host"){Invoke-Item $ReportFile}

Clear-Variable Module
Clear-Variable ServerType
Clear-Variable ThisServer
Clear-Variable Region
Clear-Variable ShortRegion
Clear-Variable AWSVarialbes
Clear-Variable Environmentattributon
Clear-Variable EnvironmentStack
Clear-Variable Environmentpod
Clear-Variable result
Clear-Variable Outputreport
Clear-Variable Environmentpod
Clear-Variable MasterHost
Clear-Variable ExpectedWEBServerCount
Clear-Variable MasterSVCHandlerVersion
Clear-Variable MasterScaleServiceVersion
Clear-Variable Expectedenable32BitAppOnWin64
Clear-Variable ExpectedidleTimeoutAction
Clear-Variable ExpectedLoadUserProfile
Clear-Variable ExpectedmaxProcesses
Clear-Variable ExpectedPrivateMemoryLimit
Clear-Variable ExpectedAnonymousAuthentication
Clear-Variable ExpectedAppPooluserName
Clear-Variable ExpectedConnectAs
Clear-Variable ExpectedSiteBindingprotocol
Clear-Variable ExpectedXRequestID
Clear-Variable ExpectedASStatus
Clear-Variable ExpectedPASRequest
Clear-Variable ExpectedLAStatus
Clear-Variable ExpectedHandlerHealth
Clear-Variable MasterSVCWebsiteHash
Clear-Variable ExpectedRecyclingPeriodicRestartTime
Clear-Variable ReportFileNamePrefix
Clear-Variable ReportFile
Clear-Variable ExpectedCoreCardServicesGatewayWorking
Clear-Variable Result
Clear-Variable Server
Clear-Variable Results
Clear-Variable HealthWebcallURL
Clear-Variable HealthWebcall
Clear-Variable HealthWebcallStatus
Clear-Variable ExpectedServicesHandlerLogs
Clear-Variable ExpectedCoreCardServicesLogs
