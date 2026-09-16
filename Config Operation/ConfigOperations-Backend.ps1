######################################################################################################################
# Config Operations - BACKEND
# Original PowerShell logic (Process / Task / IIS / File management) preserved.
# GUI removed - all selections are now passed in as parameters from the Python front end.
######################################################################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $true)]
    [string]$Operation,

    [Parameter(Mandatory = $true)]
    [string]$Job,

    [Parameter(Mandatory = $false)]
    [string[]]$ProcessTasks = @(),

    [Parameter(Mandatory = $true)]
    [string[]]$ServerList,

    [Parameter(Mandatory = $false)]
    [string]$CopyPathS3 = "",

    [Parameter(Mandatory = $false)]
    [string]$RestartReportFolder = ""
)

$ErrorActionPreference = "Continue"

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " CONFIG OPERATIONS - BACKEND" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "Environment : $EnvironmentName"
Write-Host "Operation   : $Operation"
Write-Host "Job         : $Job"
Write-Host "Targets     : $($ProcessTasks -join ', ')"
Write-Host "Servers     : $($ServerList -join ', ')"
Write-Host ""

$option = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 20000

# Capture results so Old PID / New PID verification can be written to HTML.
$InvokeResult = @(Invoke-Command -ComputerName $ServerList -SessionOption $option -ErrorAction Continue -ScriptBlock {

param ($EnvironmentName, $OperationsParam, $JobsParam, $ProcessTasksParam, $CopyPathS3Param)

$computername = hostname

if($OperationsParam -eq "Process Management"){

If ($JobsParam  -eq "Stop Processes") {
$ProcessTasksListNames = $NULL
$ProcessTasksListNames = (Get-Process -Name $ProcessTasksParam).Name
If ($ProcessTasksListNames -ne $NULL){Write-Host "Process stopping on "  $computername :  $ProcessTasksListNames
Get-Process -Name $ProcessTasksListNames | Stop-Process -Force}
else{Write-Host "Process Stopping on "  $computername ": " "No Process to Stop"}
}

If ($JobsParam  -eq "Start Processes") {
$ProcessTasksListNames = $NULL
$ProcessTasksListNames = (Get-ScheduledTask  -TaskName $ProcessTasksParam -ErrorAction SilentlyContinue | Start-ScheduledTask -ErrorAction SilentlyContinue).TaskName
If((Get-ScheduledTask  -TaskName $ProcessTasksParam -ErrorAction SilentlyContinue) -ne $NULL){
Write-Host "Process starting on "  $computername ": " (((Get-ScheduledTask  -TaskName $ProcessTasksParam -ErrorAction SilentlyContinue).TaskName).replace("Task_","  Task_"))
}
}

If ($JobsParam -eq "Restart Processes") {

    foreach ($ProcessPattern in $ProcessTasksParam) {

        $RestartTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        try {

            # 1. Check process BEFORE restart.
            $RunningProcesses = @(Get-Process -Name $ProcessPattern -ErrorAction SilentlyContinue)

            # IMPORTANT:
            # If the process is not running, DO NOT start it.
            if ($RunningProcesses.Count -eq 0) {

                Write-Host "SKIPPED on $computername : $ProcessPattern - Process was not running" -ForegroundColor Yellow

                [PSCustomObject]@{
                    Server         = $computername
                    ProcessName    = $ProcessPattern
                    OldPID         = "-"
                    NewPID         = "-"
                    RestartTime    = $RestartTime
                    RestartStatus  = "Skipped - Process Not Running"
                    TaskName       = "-"
                }

                continue
            }

            # 2. Capture ALL old PIDs.
            $OldPIDs = @($RunningProcesses | Select-Object -ExpandProperty Id)

            Write-Host "Process restarting on $computername : $ProcessPattern"
            Write-Host "Old PID(s): $($OldPIDs -join ', ')"

            # 3. Stop ONLY the process instances that were running.
            foreach ($Process in $RunningProcesses) {
                Stop-Process -Id $Process.Id -Force -ErrorAction Stop
            }

            # 4. Wait for process termination.
            Start-Sleep -Seconds 10

            # 5. Convert process name to scheduled task name.
            if ($ProcessPattern -like "Rundbb_*") {
                $TaskPattern = "Task_" + ($ProcessPattern -replace '^Rundbb_', '')
            }
            else {
                $TaskPattern = "Task_$ProcessPattern"
            }

            Write-Host "Process-to-task mapping on $computername : $ProcessPattern -> $TaskPattern"

            # 6. Find and start matching scheduled tasks.
            $ScheduledTasks = @(Get-ScheduledTask -TaskName $TaskPattern -ErrorAction SilentlyContinue)

            if ($ScheduledTasks.Count -eq 0) {

                Write-Host "FAILED on $computername : No matching scheduled task found - $TaskPattern" -ForegroundColor Red

                [PSCustomObject]@{
                    Server         = $computername
                    ProcessName    = $ProcessPattern
                    OldPID         = ($OldPIDs -join ", ")
                    NewPID         = "-"
                    RestartTime    = $RestartTime
                    RestartStatus  = "Failed - Scheduled Task Not Found"
                    TaskName       = $TaskPattern
                }

                continue
            }

            $StartedTaskNames = @()

            foreach ($ScheduledTask in $ScheduledTasks) {

                try {
                    Start-ScheduledTask -TaskName $ScheduledTask.TaskName -ErrorAction Stop
                    $StartedTaskNames += $ScheduledTask.TaskName

                    Write-Host "Scheduled task started on $computername : $($ScheduledTask.TaskName)"
                }
                catch {
                    Write-Host "ERROR starting task on $computername : $($ScheduledTask.TaskName) - $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            # 7. Wait up to 30 seconds for the NEW process PID.
            $NewPIDs = @()
            $Deadline = (Get-Date).AddSeconds(30)

            do {

                Start-Sleep -Seconds 2

                $NewProcesses = @(Get-Process -Name $ProcessPattern -ErrorAction SilentlyContinue)

                $NewPIDs = @($NewProcesses | Select-Object -ExpandProperty Id)

                if ($NewPIDs.Count -gt 0) {
                    break
                }

            } while ((Get-Date) -lt $Deadline)

            # 8. Verify that at least one NEW PID is different from the old PID.
            $DifferentPIDFound = $false

            foreach ($NewPID in $NewPIDs) {

                if ($OldPIDs -notcontains $NewPID) {
                    $DifferentPIDFound = $true
                    break
                }
            }

            if ($DifferentPIDFound) {

                $RestartStatus = "Restart Successful"

                Write-Host "RESTART SUCCESSFUL on $computername : $ProcessPattern" -ForegroundColor Green
                Write-Host "Old PID(s): $($OldPIDs -join ', ')"
                Write-Host "New PID(s): $($NewPIDs -join ', ')"

            }
            elseif ($NewPIDs.Count -eq 0) {

                $RestartStatus = "Failed - Process Did Not Start"

                Write-Host "RESTART FAILED on $computername : $ProcessPattern - Process did not start" -ForegroundColor Red

            }
            else {

                $RestartStatus = "Failed - PID Did Not Change"

                Write-Host "RESTART FAILED on $computername : $ProcessPattern - PID did not change" -ForegroundColor Red
            }

            # 9. Return one HTML-report-ready result for this server/process.
            [PSCustomObject]@{
                Server         = $computername
                ProcessName    = $ProcessPattern
                OldPID         = ($OldPIDs -join ", ")
                NewPID         = if ($NewPIDs.Count -gt 0) { $NewPIDs -join ", " } else { "-" }
                RestartTime    = $RestartTime
                RestartStatus  = $RestartStatus
                TaskName       = if ($StartedTaskNames.Count -gt 0) { $StartedTaskNames -join ", " } else { $TaskPattern }
            }
        }
        catch {

            Write-Host "ERROR restarting on $computername : $ProcessPattern - $($_.Exception.Message)" -ForegroundColor Red

            [PSCustomObject]@{
                Server         = $computername
                ProcessName    = $ProcessPattern
                OldPID         = if ($OldPIDs) { $OldPIDs -join ", " } else { "-" }
                NewPID         = "-"
                RestartTime    = $RestartTime
                RestartStatus  = "Failed - $($_.Exception.Message)"
                TaskName       = if ($TaskPattern) { $TaskPattern } else { "-" }
            }
        }
    }
}

}

elseif($OperationsParam -eq "Task Management"){

If ($JobsParam -eq "Disable Tasks") {
$ProcessTasksListNames = $NULL
foreach ($Task in $ProcessTasksParam){
$ProcessTasksListNames += (Get-ScheduledTask  -TaskName "*$Task*" -ErrorAction SilentlyContinue | Disable-ScheduledTask).TaskName}
if ($ProcessTasksListNames -ne $NULL){Write-Host "Disabled Jobs on "  $computername ":"  $ProcessTasksListNames.replace("Task_","  Task_")}
}

If ($JobsParam  -eq "Enable Tasks") {
$ProcessTasksListNames = $NULL
foreach ($Task in $ProcessTasksParam){
$ProcessTasksListNames += (Get-ScheduledTask  -TaskName "*$Task*" -ErrorAction SilentlyContinue | Enable-ScheduledTask).TaskName}
if ($ProcessTasksListNames -ne $NULL){Write-Host "Enabled Jobs on "  $computername ":"  $ProcessTasksListNames.replace("Task_","  Task_")}
}
}

elseif($OperationsParam -eq "IIS Management"){

If ($JobsParam -eq "Stop IIS"){
$IISResetResult = IISRESET /stop
Write-Host $computername  $IISResetResult}

If ($JobsParam -eq "Start IIS"){
$IISResetResult = IISRESET /start
Write-Host $computername  $IISResetResult}

If ($JobsParam -eq "Reset IIS"){
$IISResetResult = IISRESET
Write-Host $computername  $IISResetResult}

If ($JobsParam -eq "Stop and Disable W3SVC"){
$W3SVCService = Get-WmiObject Win32_Service  -filter "Name = 'W3SVC'"
$W3SVCService.stopservice()
$W3SVCService.ChangeStartMode("Disabled")
Write-Host $computername  " - Stop and Disable W3SVC"}

If ($JobsParam -eq "Enable and Start W3SVC"){
$W3SVCService = Get-WmiObject Win32_Service  -filter "Name = 'W3SVC'"
$W3SVCService.ChangeStartMode("Automatic")
$W3SVCService.startservice()
Write-Host $computername  " - Enable and Start W3SVC"}

If ($JobsParam -eq "Stop ScaleService"){
Get-Process -Name dbbScaleService | Stop-Process -Force
Write-Host $computername  " - Stop ScaleService"}

If ($JobsParam -eq "Start ScaleService"){
$ScaleService = Get-WmiObject Win32_Service  -filter "Name = 'DbbScaleService'"
$ScaleService.startservice()
Write-Host $computername  " - Start ScaleService"}

If ($JobsParam -eq "Recycle AppPool"){
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Restart-WebAppPool $WebAppPool
$WebAppPool
Write-Host "$computername; WebSite - $Site Web; WebAppPool- $WebAppPool Recyled..."
}
}

If ($JobsParam -eq "Set Connect As - ccgs-app-svc"){
$EnvironmentName = $EnvironmentName.ToUpper()
$SecretObj = (Get-SECSecretValue -Secretid "$EnvironmentName/app-service-secret")
$Secret = $SecretObj.SecretString | ConvertFrom-Json
$DomainName = ($Secret.domainNetBIOSName).ToUpper()
$Username = $Secret.username
$DomainUsername = "$DomainName\$Username"
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
Set-WebConfiguration "/system.applicationHost/sites/site[@name='Webserver']/application[@path='/$Site']/VirtualDirectory[@path='/']" -Value @{userName = $DomainUsername; password = $Secret.password}
}else{
Set-WebConfiguration "/system.applicationHost/sites/site[@name='$Site']/application[@path='/']/VirtualDirectory[@path='/']" -Value @{userName = $DomainUsername; password = $Secret.password}
}
Write-Host "$computername; Website - $Site; ConnectAs - $Username"
}
}

If ($JobsParam -eq "Set Connect As - ccgs-app-upg"){
$EnvironmentName = $EnvironmentName.ToUpper()
$SecretObj = (Get-SECSecretValue -Secretid "$EnvironmentName/app-upgrade-secret")
$Secret = $SecretObj.SecretString | ConvertFrom-Json
$DomainName = ($Secret.domainNetBIOSName).ToUpper()
$Username = $Secret.username
$DomainUsername = "$DomainName\$Username"
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
Set-WebConfiguration "/system.applicationHost/sites/site[@name='Webserver']/application[@path='/$Site']/VirtualDirectory[@path='/']" -Value @{userName = $DomainUsername; password = $Secret.password}
}else{
Set-WebConfiguration "/system.applicationHost/sites/site[@name='$Site']/application[@path='/']/VirtualDirectory[@path='/']" -Value @{userName = $DomainUsername; password = $Secret.password}
}
Write-Host "$computername; Website - $Site; ConnectAs - $Username"
}
}

If ($JobsParam -eq "Set Connect As - ccgs-web-svc"){
$EnvironmentName = $EnvironmentName.ToUpper()
$SecretObj = (Get-SECSecretValue -Secretid "$EnvironmentName/web-service-secret")
$Secret = $SecretObj.SecretString | ConvertFrom-Json
$DomainName = ($Secret.domainNetBIOSName).ToUpper()
$Username = $Secret.username
$DomainUsername = "$DomainName\$Username"
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
Set-WebConfiguration "/system.applicationHost/sites/site[@name='Webserver']/application[@path='/$Site']/VirtualDirectory[@path='/']" -Value @{userName = $DomainUsername; password = $Secret.password}
}else{
Set-WebConfiguration "/system.applicationHost/sites/site[@name='$Site']/application[@path='/']/VirtualDirectory[@path='/']" -Value @{userName = $DomainUsername; password = $Secret.password}
}
Write-Host "$computername; Website - $Site; ConnectAs - $DomainUsername"
}
}

If ($JobsParam -eq "Set AppPool User - ccgs-app-svc"){
$EnvironmentName = $EnvironmentName.ToUpper()
$SecretObj = (Get-SECSecretValue -Secretid "$EnvironmentName/app-service-secret")
$Secret = $SecretObj.SecretString | ConvertFrom-Json
$DomainName = ($Secret.domainNetBIOSName).ToUpper()
$Username = $Secret.username
$DomainUsername = "$DomainName\$Username"
Import-Module WebAdministration
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Restart-WebAppPool $WebAppPool
$WebAppPool
Set-ItemProperty "IIS:\AppPools\$WebAppPool" -name processModel -value @{userName = $DomainUsername; password = $Secret.password; identitytype = 3 }
Write-Host "$computername; Website - $Site; ; AppPool - $WebAppPool; User - $DomainUsername"
}
}

If ($JobsParam -eq "Set AppPool User - ccgs-app-upg"){
$EnvironmentName = $EnvironmentName.ToUpper()
$SecretObj = (Get-SECSecretValue -Secretid "$EnvironmentName/app-upgrade-secret")
$Secret = $SecretObj.SecretString | ConvertFrom-Json
$DomainName = ($Secret.domainNetBIOSName).ToUpper()
$Username = $Secret.username
$DomainUsername = "$DomainName\$Username"
Import-Module WebAdministration
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Restart-WebAppPool $WebAppPool
$WebAppPool
Set-ItemProperty "IIS:\AppPools\$WebAppPool" -name processModel -value @{userName = $DomainUsername; password = $Secret.password; identitytype = 3 }
Write-Host "$computername; Website - $Site; ; AppPool - $WebAppPool; User - $DomainUsername"
}
}

If ($JobsParam -eq "Set AppPool User - ccgs-web-svc"){
$EnvironmentName = $EnvironmentName.ToUpper()
$SecretObj = (Get-SECSecretValue -Secretid "$EnvironmentName/web-service-secret")
$Secret = $SecretObj.SecretString | ConvertFrom-Json
$DomainName = ($Secret.domainNetBIOSName).ToUpper()
$Username = $Secret.username
$DomainUsername = "$DomainName\$Username"
Import-Module WebAdministration
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Restart-WebAppPool $WebAppPool
$WebAppPool
Set-ItemProperty "IIS:\AppPools\$WebAppPool" -name processModel -value @{userName = $DomainUsername; password = $Secret.password; identitytype = 3 }
Write-Host "$computername; Website - $Site; ; AppPool - $WebAppPool; User - $DomainUsername"
}
}

If ($JobsParam -eq "Set X-Request-ID"){
Import-Module WebAdministration
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
New-ItemProperty 'IIS:\Sites\Webserver' -Name logfile.customFields.collection -Value @{logFieldName='X-Request-ID';sourceType='RequestHeader';sourceName='X-Request-ID'}
New-ItemProperty 'IIS:\Sites\Webserver' -Name logfile.customFields.collection -Value @{logFieldName='X-Request-ID';sourceType='RequestHeader';sourceName='X-Request-ID'}
}else{
New-ItemProperty 'IIS:\Sites\$Site' -Name logfile.customFields.collection -Value @{logFieldName='X-Request-ID';sourceType='RequestHeader';sourceName='X-Request-ID'}
New-ItemProperty 'IIS:\Sites\$Site' -Name logfile.customFields.collection -Value @{logFieldName='X-Request-ID';sourceType='RequestHeader';sourceName='X-Request-ID'}
}
Write-Host "$computername; Website - $Site; X-Request-ID - Enabled"
}
}

If ($JobsParam -eq "Disable IIS Logging"){
Import-Module WebAdministration
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
Set-ItemProperty -Path 'IIS:\Sites\Webserver' -Name Logfile.enabled -Value $false
}else{
Set-ItemProperty -Path 'IIS:\Sites\$Site' -Name Logfile.enabled -Value $false
}
Write-Host "$computername; Website - $Site; IIS Logging - Disabled"
}
}

If ($JobsParam -eq "Enable IIS Logging"){
Import-Module WebAdministration
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
Set-ItemProperty -Path 'IIS:\Sites\Webserver' -Name Logfile.enabled -Value $true
}else{
Set-ItemProperty -Path 'IIS:\Sites\$Site' -Name Logfile.enabled -Value $true
}
Write-Host "$computername; Website - $Site; IIS Logging - Enabled"
}
}

If ($JobsParam -eq "Set Worker Process 1"){
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Set-ItemProperty "IIS:\AppPools\$WebAppPool" -name processModel -value @{maxProcesses = 1}
Write-Host "$computername; WebSite - $Site Web; WebAppPool- $WebAppPool; MaxProcesses = (Get-ItemProperty "IIS:\AppPools\$WebAppPool" -name processModel).maxProcesses"
}
}

If ($JobsParam -eq "Set Worker Process 4"){
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Set-ItemProperty "IIS:\AppPools\$WebAppPool" -name processModel -value @{maxProcesses = 4}
Write-Host "$computername; WebSite - $Site Web; WebAppPool- $WebAppPool; MaxProcesses = (Get-ItemProperty "IIS:\AppPools\$WebAppPool" -name processModel).maxProcesses"
}
}

If ($JobsParam -eq "Set Worker Process 64"){
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Set-ItemProperty "IIS:\AppPools\$WebAppPool" -name processModel -value @{maxProcesses = 64}
Write-Host "$computername; WebSite - $Site Web; WebAppPool- $WebAppPool; MaxProcesses = (Get-ItemProperty "IIS:\AppPools\$WebAppPool" -name processModel).maxProcesses"
}
}

If ($JobsParam -eq "Enable32bitApplication True"){
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Set-ItemProperty IIS:\AppPools\$WebAppPool -Name enable32BitAppOnWin64 -Value 'true'
Write-Host "$computername; WebSite - $Site Web; WebAppPool- $WebAppPool; MaxProcesses = (Get-ItemProperty IIS:\AppPools\$WebAppPool -Name enable32BitAppOnWin64).Value"
}
}

If ($JobsParam -eq "Enable32bitApplication False"){
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Set-ItemProperty IIS:\AppPools\$WebAppPool -Name enable32BitAppOnWin64 -Value 'false'
Write-Host "$computername; WebSite - $Site Web; WebAppPool- $WebAppPool; MaxProcesses = (Get-ItemProperty IIS:\AppPools\$WebAppPool -Name enable32BitAppOnWin64).Value"
}
}

If ($JobsParam -eq "IdleTimeoutAction Terminate"){
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Set-ItemProperty "IIS:\AppPools\$WebAppPool" -Name processModel.idleTimeoutAction -Value Terminate
Write-Host "$computername; WebSite - $Site Web; WebAppPool- $WebAppPool; IdleTimeoutAction = Get-ItemProperty IIS:\AppPools\$WebAppPool -Name processModel.idleTimeoutAction"
}
}

If ($JobsParam -eq "IdleTimeoutAction Suspend"){
foreach($Site in $ProcessTasksParam){
If(($Site -eq "WCF") -or ($Site -eq "CoreCardServices")){
$WebAppPool = (Get-WebApplication -name $Site | Where ItemXPath -Match "Webserver").applicationPool
}else{
$WebAppPool = (Get-Website -Name $Site).applicationPool}
Set-ItemProperty "IIS:\AppPools\$WebAppPool" -Name processModel.idleTimeoutAction -Value Suspend
Write-Host "$computername; WebSite - $Site Web; WebAppPool- $WebAppPool; IdleTimeoutAction = Get-ItemProperty IIS:\AppPools\$WebAppPool -Name processModel.idleTimeoutAction"
}
}

}

elseif($OperationsParam -eq "File Management"){

write-host  $computername

If ($JobsParam -match "Copy"){
$CompressedFileNameonDestServer = $JobsParam.Split(" ")[1] + ".zip"

if(Test-Path -Path C:\TEMP\$CompressedFileNameonDestServer) {Remove-Item -Force -Path "C:\TEMP\$CompressedFileNameonDestServer"}
aws s3 cp $CopyPathS3Param "C:\TEMP\$CompressedFileNameonDestServer"
Expand-Archive -Path "C:\TEMP\$CompressedFileNameonDestServer" -DestinationPath D:\ -Force
}

}

else{
Write-Host "Invalid Option"
}

} -ArgumentList $EnvironmentName, $Operation, $Job, $ProcessTasks, $CopyPathS3

)

# ==============================================================
# Restart PID verification HTML report
# ==============================================================

if ($Job -eq "Restart Processes") {

    if ([string]::IsNullOrWhiteSpace($RestartReportFolder)) {
        $RestartReportFolder = Join-Path $env:TEMP "ProcessRestartReports"
    }

    if (-not (Test-Path $RestartReportFolder)) {
        New-Item -ItemType Directory -Path $RestartReportFolder -Force | Out-Null
    }

    $RestartReportFile = Join-Path $RestartReportFolder (
        "ProcessRestart_{0}.html" -f (Get-Date -Format "yyyyMMdd_HHmmss")
    )

    $RestartResults = @(
        $InvokeResult |
            Where-Object {
                $_.PSObject.Properties.Name -contains "RestartStatus"
            } |
            Select-Object Server, ProcessName, OldPID, NewPID, RestartTime, RestartStatus, TaskName
    )

    if ($RestartResults.Count -gt 0) {

        $PreContent = @"
<h2>Process Restart PID Verification Report</h2>
<p>
<b>Restart Rule:</b> Only processes that were running before the restart are restarted.
If a process was not running, the server is skipped and the process is not started.
</p>
<p>
<b>Old PID:</b> PID captured before stopping the process.
&nbsp;&nbsp;
<b>New PID:</b> PID captured after starting the scheduled task.
</p>
"@

        $Head = @"
<style>
body { font-family: Arial; font-size: 12px; }
h2 { color: #1f4e78; }
table { border-collapse: collapse; width: 100%; }
th { background-color: #d9e2f3; }
th, td { border: 1px solid #999; padding: 6px; }
</style>
"@

        $RestartResults |
            ConvertTo-Html `
                -Title "Process Restart PID Verification Report" `
                -PreContent $PreContent `
                -Head $Head |
            Out-File -FilePath $RestartReportFile -Encoding UTF8

        Write-Host ""
        Write-Host "Restart PID verification report:" -ForegroundColor Cyan
        Write-Host "REPORT_FILE::$RestartReportFile"
    }
}

Write-Host ""
Write-Host "Operation completed." -ForegroundColor Green
