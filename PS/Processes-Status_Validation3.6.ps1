######################################################################################################################
# Process Status Validation  | DEVELOPED BY::Aaksh Sharma
# Version 2.0 | Date:: 12-Aug-2025 | Update By Netra
# Version 3.5 | Date:: 07-April-2026 | Updated By Mahendrta Dwivedi
# Version 3.6 | Date:: 20-August-2026 | Added Output Filtering By Gowtham Javvadi
# Version 3.7 | Date:: 30-Oct-2026 | Added Process Threads (CoreIssue & CoreAuth) By Netra Chettri
#======================================================================================================================

Clear-Host

$Module = "Processes-Status"
$ServerTypes = 'SVC', 'ISS', 'AUT', 'SRC', 'SNK', 'TNP', 'AWF', 'BAT'
$ThisServer = (hostname).ToLower()

# Region detection
if ($ThisServer -match 'e1') { $Region = "us-east-1" }
elseif ($ThisServer -match 'w2') { $Region = "us-west-2" }

Write-Host "Running on Server: $ThisServer | Region: $Region" -ForegroundColor Cyan

# Get AWS metadata for current server
$AWSVarialbes = (aws ec2 describe-instances `
--query "Reservations[*].Instances[*].{
    AvailabilityZone:Placement.AvailabilityZone,
    Name:Tags[?Key=='Name']|[0].Value,
    Environment:Tags[?Key=='environment']|[0].Value,
    Stack:Tags[?Key=='stack']|[0].Value,
    Attribution:Tags[?Key=='attribution']|[0].Value,
    Pod:Tags[?Key=='pod']|[0].Value
}" `
--filters "Name=instance-state-name,Values=running" `
"Name=tag:Name,Values=$ThisServer" `
--region $Region | ConvertFrom-Json)

$EnvironmentName = $AWSVarialbes.Environment.ToLower()
$Environmentattributon = $AWSVarialbes.Attribution.ToLower()

# POD detection
if ($null -eq $AWSVarialbes.Pod) {
    if ($Environmentattributon -eq "jazz") {
        $Environmentpod = "jazz"
    } else {
        $S3bucketslist = aws s3 ls
        if ($S3bucketslist -match "corecard-pod2-$EnvironmentName-$Region-config-files") { $Environmentpod = "pod2" }
        elseif ($S3bucketslist -match "corecard-pod4-$EnvironmentName-$Region-config-files") { $Environmentpod = "pod4" }
        elseif ($S3bucketslist -match "corecard-pod5-$EnvironmentName-$Region-config-files") { $Environmentpod = "pod5" }
    }
} else {
    $Environmentpod = $AWSVarialbes.Pod.ToLower()
}

# Get all servers
$ServerList = (aws ec2 describe-instances `
--query "Reservations[*].Instances[*].{
    AvailabilityZone:Placement.AvailabilityZone,
    Name:Tags[?Key=='Name']|[0].Value,
    Stack:Tags[?Key=='stack']|[0].Value
}" `
--filters "Name=instance-state-name,Values=running" `
--region $Region | ConvertFrom-Json)

# Filter stack
$ServerList = $ServerList | Where-Object {
    $_.Stack -like "*$($AWSVarialbes.Stack)*"
}

# ? Build AZ Mapping
$ServerMap = @{}
foreach ($srv in $ServerList) {
    if ($srv.Name) {
        $ServerMap[$srv.Name.ToLower()] = $srv.AvailabilityZone
    }
}

Write-Host "Total Servers Mapped: $($ServerMap.Count)" -ForegroundColor Yellow

$Result = @()

foreach ($ServerType in $ServerTypes) {

    Write-Host "`nProcessing ServerType: $ServerType" -ForegroundColor Cyan

    $FilteredServers = $ServerList | Where-Object {
        $_.Name -like "*$ServerType*"
    }

    $ComputerList = $FilteredServers.Name | Where-Object { $_ }

    if (-not $ComputerList) {
        Write-Host "No servers found for $ServerType" -ForegroundColor Red
        continue
    }

    $option = New-PSSessionOption -ProxyAccessType NoProxyServer

    $Result += Invoke-Command -ComputerName $ComputerList `
    -SessionOption $option `
    -ErrorAction SilentlyContinue `
    -ArgumentList ($ServerMap) `
    -ScriptBlock {

        param ($ServerMap)

        $hostname = $env:COMPUTERNAME.ToLower()
        $ServerAZ = $ServerMap[$hostname]

        # ?? Fallback using LIKE
        if (-not $ServerAZ) {
            foreach ($key in $ServerMap.Keys) {
                if ($key -like "*$hostname*") {
                    $ServerAZ = $ServerMap[$key]
                    break
                }
            }
        }

        # ?? Debug if still not found
        if (-not $ServerAZ) {
            Write-Output "DEBUG: AZ NOT FOUND for $hostname"
            $ServerAZ = "UNKNOWN"
        }

        $resultvalue = @()

        $ciBatPath = "D:\DBBSetup\BatchScripts\CoreIssue\RunccCI.bat"
        $authBatPath = "D:\DBBSetup\BatchScripts\CoreAuth\RunccCoreAuth.bat"

        $ciBatLines = if (Test-Path $ciBatPath) { Get-Content $ciBatPath -ErrorAction SilentlyContinue } else { @() }
        $authBatLines = if (Test-Path $authBatPath) { Get-Content $authBatPath -ErrorAction SilentlyContinue } else { @() }

        $scheduledtasknames = (Get-Scheduledtask -TaskName Task_* -ErrorAction SilentlyContinue).TaskName
        $ProcessesNames = (Get-Process -Name 'DbbAppServer*', 'Rundbb*' -ErrorAction SilentlyContinue).ProcessName

        $ServerTasksVsProcessesCount = if ($scheduledtasknames.count -eq $ProcessesNames.count) { "Matching" } else { "Mismatch" }

        if ($null -eq $scheduledtasknames) {
            $resultvalue += [PSCustomObject]@{
            ServerType = $using:ServerType   # ? ADD THIS
            ServerName = $hostname
            ProcessName = "No Tasks"
            ProcessId = "NA"
            Threads = "NA"
            TaskUser = "No Tasks"
            ProcessStatus = "No Tasks"
            ProcessCount = "Mismatch"
            ProcessUser = "Mismatch"
            ServerTasksVsProcessesCount = $ServerTasksVsProcessesCount
            AvailabilityZone = $ServerAZ
            IntentMode = ""
            }
        }

        foreach ($scheduledtaskname in $scheduledtasknames) {

            $TaskDetails = Get-Scheduledtask -TaskName $scheduledtaskname
            $TaskUser = $TaskDetails.Principal.UserID

            if ($scheduledtaskname -match "Task_DbbAppServer") {
                $FindProcessName = $scheduledtaskname.Replace("Task_", "")
            } else {
                $FindProcessName = $scheduledtaskname.Replace("Task_", "Rundbb_")
            }

            $ProcessDetails = Get-Process -Name $FindProcessName -IncludeUserName -ErrorAction SilentlyContinue

            $ProcessId = if ($ProcessDetails) { ($ProcessDetails | Select-Object -First 1 -ExpandProperty Id) } else { "N/A" }

            $ProcessCount = if ($ProcessDetails.Name.Count -eq 1) { "Matching" } else { "Mismatch" }

            $procUser = ($ProcessDetails.UserName -split '\\')[-1]
            $taskUser = ($TaskUser -split '\\')[-1]

            $ProcessUser = if ($procUser -and $taskUser -and ($procUser.ToLower() -eq $taskUser.ToLower())) {
                "Matching"
            } else {
                "Mismatch"
            }

            $IntentRaw = Select-String -Path "D:\DBBSetup\BatchScripts\CoreIssue\RTM.config" -Pattern "RunTimeMode=" -ErrorAction SilentlyContinue

if ($IntentRaw) {
    $IntentMode = $IntentRaw.ToString().Split('=')[1].Trim()
} else {
    $IntentMode = ""
}
# Extract Port from Arguments (FIX)
$HealthPort = $null
$taskArgs = $TaskDetails.Actions.Arguments

# Debug (optional - remove later)
# Write-Output "DEBUG: Args=$taskArgs"

if ($taskArgs) {
    # Case 1: --server.port=8080 OR port=8080
    if ($taskArgs -match 'port[=\s](\d{3,5})') {
        $HealthPort = $matches[1]
    }
    # Case 2: standalone port like 8080
    elseif ($taskArgs -match '\b(\d{3,5})\b') {
        $HealthPort = $matches[1]
    }
}


if (-not $HealthPort) {
    $ProcessStatus = "Health Port Not Found"
}
else {
    $url = "http://localhost:$HealthPort/healthy"

    try {
        $resp = Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing

        if ($resp.StatusCode -eq 200) {

            # Flexible check (important fix)
            if ($resp.Content -match "Healthy|UP|OK") {
                $ProcessStatus = "Process Healthy"
            }
            else {
                $ProcessStatus = "Process Healthy"
            }

        } else {
            $ProcessStatus = "Process Unhealthy"
        }

    } catch {
        $ProcessStatus = "Process Down"
    }
}

            # Extract configured thread count from RunccCI.bat or RunccCoreAuth.bat
            $Threads = "NA"
            $procKey = $scheduledtaskname -replace '^Task_', ''
            $stripProcKey = $procKey -replace '^(ci|auth)', ''

            $batSources = if ($using:ServerType -eq "AUT" -or $scheduledtaskname -like "*Auth*") {
                @($authBatLines, $ciBatLines)
            } else {
                @($ciBatLines, $authBatLines)
            }

            foreach ($lines in $batSources) {
                if (-not $lines -or $lines.Count -eq 0) { continue }

                # 1. Search lines matching process identifier and containing -threads
                foreach ($line in $lines) {
                    if ($line -match '-threads\s+(\d+)') {
                        $candThreads = $matches[1]
                        if ($line -match "\b$FindProcessName\b" -or
                            $line -match "start\s+[`"']?$procKey[`"']?" -or
                            $line -match "start\s+[`"']?$stripProcKey[`"']?" -or
                            $line -match "[\/]$stripProcKey\.exe\b" -or
                            $line -match "Rundbb_$stripProcKey\b") {
                            $Threads = $candThreads
                            break
                        }
                    }
                }
                if ($Threads -ne "NA") { break }

                # 2. Section label search (:citnp, :cidbpd, :AuthMSMQ, etc.)
                for ($idx = 0; $idx -lt $lines.Count; $idx++) {
                    if ($lines[$idx] -match "^\s*:(ci|auth)?($procKey|$stripProcKey)\b") {
                        $maxLook = [Math]::Min($lines.Count, $idx + 6)
                        for ($j = $idx; $j -lt $maxLook; $j++) {
                            if ($lines[$j] -match '-threads\s+(\d+)') {
                                $Threads = $matches[1]
                                break
                            }
                        }
                        if ($Threads -ne "NA") { break }
                    }
                }
                if ($Threads -ne "NA") { break }
            }

            # 3. Fallback: check Scheduled Task arguments
            if ($Threads -eq "NA" -and $taskArgs -and ($taskArgs -match '-threads\s+(\d+)')) {
                $Threads = $matches[1]
            }

            # 4. Fallback: check running process command line via WMI if available
            if ($Threads -eq "NA" -and $ProcessId -and ($ProcessId -ne "NA") -and ($ProcessId -ne "N/A")) {
                try {
                    $wmiProc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
                    if ($wmiProc.CommandLine -match '-threads\s+(\d+)') {
                        $Threads = $matches[1]
                    }
                } catch {}
            }

            $resultvalue += [PSCustomObject]@{
                ServerType = $using:ServerType   # ? ADD THIS
                ServerName = $hostname
                ProcessName = $scheduledtaskname
                ProcessId = $ProcessId
                Threads = $Threads
                TaskUser = $TaskUser
                ProcessStatus = $ProcessStatus
                ProcessCount = $ProcessCount
                ProcessUser = $ProcessUser
                ServerTasksVsProcessesCount = $ServerTasksVsProcessesCount
                AvailabilityZone = $ServerAZ
                IntentMode = $IntentMode
            }
        }

        return $resultvalue
    }
}

# =========================
# AFTER RESULT COLLECTION
# =========================

# HTML Report Formatting
$upgUsername = "<td>$($env:USERDOMAIN)\gmsa-app-upg`$</td>"
$upgUsernameColor = "<td bgcolor='lightsalmon'>$($env:USERDOMAIN)\gmsa-app-upg`$</td>"
$IntentMode = "<td>ZDT</td>"

#$ProcessesReport = $Result | Select-Object ServerName, ProcessName, ProcessId, TaskUser, ProcessStatus, ProcessCount, ProcessUser, ServerTasksVsProcessesCount, AvailabilityZone, IntentMode | ConvertTo-Html -Title "Processes Status Validation Report"
# Build ServerType Order
$ServerTypeOrder = @{}
for ($i = 0; $i -lt $ServerTypes.Count; $i++) {
    $ServerTypeOrder[$ServerTypes[$i]] = $i
}

# Sort properly
$SortedResult = $Result | Sort-Object `
    @{Expression = { $ServerTypeOrder[$_.ServerType] }}, `
    @{Expression = { $_.ServerName -replace '\d','' }}, `
    @{Expression = { [int]($_.ServerName -replace '\D','') }}

#$ProcessesReport = $SortedResult | Select-Object ServerName, ProcessName, ProcessId, TaskUser, ProcessStatus, ProcessCount, ProcessUser, ServerTasksVsProcessesCount, AvailabilityZone, IntentMode | ConvertTo-Html -Title "Processes Status Validation Report"
$ProcessesReport = $SortedResult | Select-Object `
ServerType, ServerName, ProcessName, ProcessId, Threads, TaskUser, ProcessStatus, `
ProcessCount, ProcessUser, ServerTasksVsProcessesCount, AvailabilityZone, IntentMode `
| ConvertTo-Html -Title "Processes Status Validation Report"

# Apply formatting
$Outputreport = $ProcessesReport

# Highlight gmsa user
$Outputreport = $Outputreport -replace '<td>([^<]*gmsa-app-upg\$[^<]*)</td>', '<td bgcolor="LightSalmon">$1</td>'

# Highlight ZDT
$Outputreport = $Outputreport -replace '<td>(\s*ZDT\s*)</td>', '<td bgcolor="LightSalmon">$1</td>'

# Header
$BodyHeader = "<h2 style='color: steelblue;'>$($EnvironmentName.ToUpper()) - $($Environmentpod.ToUpper()) - $($Module) Validation Report</h2>"
$Outputreport = $Outputreport.Replace("<body>", "<body>$BodyHeader")

# Table styling
$Outputreport = $Outputreport.Replace("<table>", "<Table border=1 cellpadding=0 cellspacing=0>")
$Outputreport = $Outputreport.Replace("<th>", '<th bgcolor=gray>')

# Conditional colors
$Outputreport = $Outputreport.Replace("<td>Process Down</td>", "<td bgcolor=LightSalmon>Process Down</td>")
$Outputreport = $Outputreport.Replace("<td>Health Port Not Found</td>", "<td bgcolor=LightSalmon>Health Port Not Found</td>")
$Outputreport = $Outputreport.Replace("<td>No Tasks</td>", "<td bgcolor=LightSalmon>No Tasks</td>")
$Outputreport = $Outputreport.Replace("<td>Mismatch</td>", "<td bgcolor=LightSalmon>Mismatch</td>")
$Outputreport = $Outputreport.Replace("<td>Process Unhealthy</td>", "<td bgcolor=LightSalmon>Process Unhealthy</td>")

# Specific user highlight
$Outputreport = $Outputreport.Replace($upgUsername, $upgUsernameColor)


# =========================
# HTML DROPDOWN FILTERS
# =========================
$DropdownFilterScript = @"
<style>
.filter-row th {
    background-color: #d9e2f3 !important;
    padding: 4px !important;
}
.filter-row select {
    width: 100%;
    min-width: 120px;
    padding: 2px;
    font-size: 12px;
}
.filter-actions {
    margin: 8px 0;
    padding: 6px;
}
.filter-actions button {
    padding: 5px 14px;
    font-weight: bold;
    cursor: pointer;
}
.result-count {
    margin-left: 15px;
    font-weight: bold;
}
#processStatusTable {
    border-collapse: collapse;
}
#processStatusTable th,
#processStatusTable td {
    white-space: nowrap;
}
</style>

<script type="text/javascript">
(function () {

    function addLoadEvent(func) {
        if (window.addEventListener) {
            window.addEventListener("load", func, false);
        } else if (window.attachEvent) {
            window.attachEvent("onload", func);
        } else {
            window.onload = func;
        }
    }

    function trimText(value) {
        return String(value).replace(/^\s+|\s+$/g, "");
    }

    function getCellText(cell) {
        if (!cell) return "";
        return trimText(cell.innerText || cell.textContent || "");
    }

    function updateResultCount(table) {

        var rows = table.getElementsByTagName("tr");
        var totalCount = 0;
        var visibleCount = 0;
        var healthyCount = 0;
        var downCount = 0;
        var unhealthyCount = 0;
        var portNotFoundCount = 0;
        var serialNumber = 1;
        var i;

        for (i = 2; i < rows.length; i++) {

            var cells = rows[i].getElementsByTagName("td");

            if (cells.length > 0) {

                totalCount++;

                if (rows[i].style.display !== "none") {

                    visibleCount++;

                    // S.No is always column 0.
                    cells[0].innerHTML = serialNumber;
                    serialNumber++;

                    // After adding S.No:
                    // 0 = S.No
                    // 1 = ServerType
                    // 2 = ServerName
                    // 3 = ProcessName
                    // 4 = ProcessId
                    // 5 = Threads
                    // 6 = TaskUser
                    // 7 = ProcessStatus

                    var statusCol = 7;
                    if (rows[0]) {
                        var thList = rows[0].getElementsByTagName("th");
                        for (var c = 0; c < thList.length; c++) {
                            if (trimText(thList[c].innerText || thList[c].textContent) === "ProcessStatus") {
                                statusCol = c;
                                break;
                            }
                        }
                    }
                    var status = getCellText(cells[statusCol]);

                    if (status === "Process Healthy") {
                        healthyCount++;
                    }
                    else if (status === "Process Down") {
                        downCount++;
                    }
                    else if (status === "Process Unhealthy") {
                        unhealthyCount++;
                    }
                    else if (status === "Health Port Not Found") {
                        portNotFoundCount++;
                    }

                }
                else {
                    cells[0].innerHTML = "";
                }
            }
        }

        var countElement = document.getElementById("processResultCount");

        if (countElement) {

            var summary =
                "Showing: " + visibleCount + " of " + totalCount +
                " | Running/Healthy: " + healthyCount;

            if (downCount > 0) {
                summary += " | Down: " + downCount;
            }

            if (unhealthyCount > 0) {
                summary += " | Unhealthy: " + unhealthyCount;
            }

            if (portNotFoundCount > 0) {
                summary += " | Health Port Not Found: " + portNotFoundCount;
            }

            countElement.innerHTML = summary;
        }
    }

    function applyFilters(table, filterRow) {

        var selects = filterRow.getElementsByTagName("select");
        var rows = table.getElementsByTagName("tr");
        var i, j;

        for (i = 2; i < rows.length; i++) {

            var cells = rows[i].getElementsByTagName("td");
            var showRow = true;

            for (j = 0; j < selects.length; j++) {

                var columnIndex = parseInt(
                    selects[j].getAttribute("data-column"), 10
                );

                var selectedValue = selects[j].value;

                if (selectedValue !== "" &&
                    cells.length > columnIndex) {

                    var cellValue = getCellText(cells[columnIndex]);

                    if (cellValue !== selectedValue) {
                        showRow = false;
                        break;
                    }
                }
            }

            rows[i].style.display = showRow ? "" : "none";
        }

        updateResultCount(table);
    }

    function clearAllFilters(table, filterRow) {

        var selects = filterRow.getElementsByTagName("select");
        var i;

        for (i = 0; i < selects.length; i++) {
            selects[i].selectedIndex = 0;
        }

        applyFilters(table, filterRow);
    }

    function createFilterReport() {

        var tables = document.getElementsByTagName("table");

        if (!tables || tables.length === 0) {
            return;
        }

        var table = tables[0];
        table.id = "processStatusTable";

        var rows = table.getElementsByTagName("tr");

        if (!rows || rows.length === 0) {
            return;
        }

        /*
         * IMPORTANT:
         * Build the column mapping from the ACTUAL HTML headers.
         * Do not assume fixed positions for ServerType, ServerName,
         * ProcessName, etc. This prevents dropdown mismatches.
         */

        var headerRow = rows[0];
        var headers = headerRow.getElementsByTagName("th");

        var headerIndex = {};
        var i, r;

        for (i = 0; i < headers.length; i++) {

            var headerName = trimText(
                headers[i].innerText || headers[i].textContent
            );

            headerIndex[headerName] = i;
        }

        var requiredFilters = [
            "ServerType",
            "ServerName",
            "ProcessName",
            "Threads",
            "TaskUser",
            "ProcessStatus",
            "AvailabilityZone",
            "IntentMode"
        ];

        /*
         * Add Serial Number column FIRST.
         * All original columns then move one position to the right.
         */

        var serialHeader = document.createElement("th");
        serialHeader.innerHTML = "S.No";
        headerRow.insertBefore(
            serialHeader,
            headerRow.firstChild
        );

        for (r = 1; r < rows.length; r++) {

            var existingCells = rows[r].getElementsByTagName("td");

            if (existingCells.length > 0) {

                var serialCell = document.createElement("td");
                serialCell.innerHTML = "";

                rows[r].insertBefore(
                    serialCell,
                    existingCells[0]
                );
            }
        }

        /*
         * Recalculate header indexes after adding S.No.
         */

        headerRow = rows[0];
        headers = headerRow.getElementsByTagName("th");
        headerIndex = {};

        for (i = 0; i < headers.length; i++) {

            headerName = trimText(
                headers[i].innerText || headers[i].textContent
            );

            headerIndex[headerName] = i;
        }

        var filterRow = document.createElement("tr");
        filterRow.className = "filter-row";

        for (i = 0; i < headers.length; i++) {

            var filterCell = document.createElement("th");
            var columnName = trimText(
                headers[i].innerText || headers[i].textContent
            );

            var filterRequired = false;
            var f;

            for (f = 0; f < requiredFilters.length; f++) {

                if (requiredFilters[f] === columnName) {
                    filterRequired = true;
                    break;
                }
            }

            if (filterRequired) {

                var select = document.createElement("select");
                select.setAttribute("data-column", i);

                var allOption = document.createElement("option");
                allOption.value = "";
                allOption.text = "All " + columnName;
                select.appendChild(allOption);

                /*
                 * IMPORTANT:
                 * Read values from THIS SAME column index.
                 * This prevents ServerName values from appearing
                 * in the ProcessName dropdown.
                 */

                var values = [];
                var currentRows = table.getElementsByTagName("tr");

                for (r = 2; r < currentRows.length; r++) {

                    var dataCells =
                        currentRows[r].getElementsByTagName("td");

                    if (dataCells.length > i) {

                        var value = getCellText(dataCells[i]);

                        if (value !== "") {

                            var exists = false;
                            var v;

                            for (v = 0; v < values.length; v++) {

                                if (values[v] === value) {
                                    exists = true;
                                    break;
                                }
                            }

                            if (!exists) {
                                values.push(value);
                            }
                        }
                    }
                }

                values.sort(function (a, b) {

                    var aa = a.toLowerCase();
                    var bb = b.toLowerCase();

                    if (aa < bb) return -1;
                    if (aa > bb) return 1;

                    return 0;
                });

                for (r = 0; r < values.length; r++) {

                    var option =
                        document.createElement("option");

                    option.value = values[r];
                    option.text = values[r];

                    select.appendChild(option);
                }

                select.onchange = function () {

                    applyFilters(
                        table,
                        filterRow
                    );
                };

                filterCell.appendChild(select);
            }

            filterRow.appendChild(filterCell);
        }

        headerRow.parentNode.insertBefore(
            filterRow,
            headerRow.nextSibling
        );

        /*
         * Clear Filters + count.
         */

        var actionRow = document.createElement("div");
        actionRow.className = "filter-actions";

        var clearButton =
            document.createElement("button");

        clearButton.type = "button";
        clearButton.innerHTML = "Clear Filters";

        clearButton.onclick = function () {

            clearAllFilters(
                table,
                filterRow
            );
        };

        var countSpan =
            document.createElement("span");

        countSpan.id = "processResultCount";
        countSpan.className = "result-count";

        actionRow.appendChild(clearButton);
        actionRow.appendChild(countSpan);

        table.parentNode.insertBefore(
            actionRow,
            table
        );

        updateResultCount(table);
    }

    addLoadEvent(createFilterReport);

})();
</script>
"@

$Outputreport = $Outputreport.Replace("</body>", "$DropdownFilterScript</body>")

# File creation
$ReportFileNamePrefix = "${Module}_Validation_"
$ReportFile = "C:\Temp\$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd-hhmm).html"
$Outputreport | Out-File "$ReportFile"

# Upload to S3
aws s3 cp $ReportFile "s3://corecard-$Environmentpod-$EnvironmentName-$Region-config-files/EnvironmentValidationReports/$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd).html"

# Open in ISE
if ($host.Name -eq "Windows PowerShell ISE Host") {
    Invoke-Item $ReportFile
}

# Cleanup
Clear-Variable Module
Clear-Variable ServerType
Clear-Variable ThisServer
Clear-Variable Region
Clear-Variable AWSVarialbes
Clear-Variable Environmentattributon
Clear-Variable Environmentpod
Clear-Variable result
Clear-Variable ReportFileNamePrefix
Clear-Variable ReportFile
Clear-Variable ReportFileNamePrefix
Clear-Variable ReportFile