######################################################################################################################
# User Change for WCF App Pool - Graphical User Interface (GUI)
# DEVELOPED BY:: Netra Chettri
# Version 2.0 | Full WinForms GUI, Zero-Downtime AppPool Update, Multi-Server Selection & HTML Reporting
# Date:: 12-Nov-2026
######################################################################################################################

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================================================================
# AWS & SYSTEM DISCOVERY HELPERS
# =====================================================================================================================
function Get-DetectedRegion {
    $hostName = (hostname).ToLower()
    if ($hostName -match 'e1') { return @{ Region = "us-east-1"; Short = "e1" } }
    if ($hostName -match 'w2') { return @{ Region = "us-west-2"; Short = "w2" } }
    return @{ Region = "us-east-1"; Short = "e1" }
}

function Get-SelfAWSMetadata {
    param([string]$Region)
    $thisServer = ($env:COMPUTERNAME).ToLower()
    $shortServer = ((hostname).ToLower() -split '\.')[0].Trim()

    try {
        # 1. Query instances with tags object to allow case-insensitive tag extraction
        $queryResult = (aws ec2 describe-instances `
            --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,Tags:Tags}" `
            --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='$thisServer','$shortServer'" `
            --region $Region 2>$null | ConvertFrom-Json)
        $flat = @($queryResult | ForEach-Object { $_ } | Where-Object { $_ })

        # 2. Wildcard fallback if exact name tag didn't return
        if (@($flat).Count -eq 0 -and $shortServer) {
            $queryResult = (aws ec2 describe-instances `
                --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name,Tags:Tags}" `
                --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='*$shortServer*'" `
                --region $Region 2>$null | ConvertFrom-Json)
            $flat = @($queryResult | ForEach-Object { $_ } | Where-Object { $_ })
        }

        if (@($flat).Count -gt 0) {
            $inst = $flat[0]
            $allTags = @($inst.Tags)

            $getTagValue = {
                param([string]$keyPattern)
                $found = $allTags | Where-Object { $_.Key -and ($_.Key -match "^$keyPattern$") }
                if ($found) { return [string]$found[0].Value } else { return "" }
            }

            $envVal   = &$getTagValue "(environment|env)"
            $stackVal = &$getTagValue "stack"
            $podVal   = &$getTagValue "pod"
            $attrVal  = &$getTagValue "attribution"

            return [PSCustomObject]@{
                AvailabilityZone = $inst.AvailabilityZone
                IpAddress        = $inst.IpAddress
                Type             = $inst.Type
                Name             = $inst.Name
                Environment      = $envVal
                Stack            = $stackVal
                Pod              = $podVal
                Attribution      = $attrVal
            }
        }
    } catch {}
    return $null
}

function Get-DetectedEnvironment {
    param([string]$Region)

    $detectedEnv = ""
    $detectedPod = ""
    $detectedStack = ""
    $detectedAZ = ""

    # Strategy 1: EC2 Instance Tags from AWS Metadata (Case-insensitive)
    $selfMeta = Get-SelfAWSMetadata -Region $Region
    if ($selfMeta) {
        if ($selfMeta.Environment) { $detectedEnv = $selfMeta.Environment.Trim().ToLower() }
        if ($selfMeta.Pod) { $detectedPod = $selfMeta.Pod.Trim().ToLower() }
        elseif ($selfMeta.Attribution -and $selfMeta.Attribution.ToLower() -eq "jazz") { $detectedPod = "jazz" }
        if ($selfMeta.Stack) { $detectedStack = ($selfMeta.Stack.Trim().ToLower())[0] }
        if ($selfMeta.AvailabilityZone) { $detectedAZ = $selfMeta.AvailabilityZone.Trim() }
    }

    # Strategy 2: If Environment not found from self tags, inspect other running instances in this VPC/Region
    if (-not $detectedEnv) {
        try {
            $queryResult = (aws ec2 describe-instances `
                --query "Reservations[*].Instances[*].{Name:Tags[?Key=='Name']|[0].Value,Tags:Tags}" `
                --filters "Name=instance-state-name,Values=running" `
                --max-items 20 `
                --region $Region 2>$null | ConvertFrom-Json)
            $flat = @($queryResult | ForEach-Object { $_ } | Where-Object { $_ })
            foreach ($item in $flat) {
                $tags = @($item.Tags)
                $envTag = $tags | Where-Object { $_.Key -and ($_.Key -match '^(environment|env)$') }
                if ($envTag -and $envTag[0].Value) {
                    $val = [string]$envTag[0].Value.Trim().ToLower()
                    if ($val -match '^(dev|qa|prod|uat|patqa|patuat|perf)$') {
                        $detectedEnv = $val
                        break
                    }
                }
            }
        } catch {}
    }

    # Strategy 3: Parse Hostname / ComputerName / FQDN / Domain
    $namesToCheck = @(
        $env:COMPUTERNAME,
        (hostname),
        $env:USERDNSDOMAIN,
        $env:LOGONSERVER
    )
    try { $namesToCheck += [System.Net.Dns]::GetHostByName((hostname)).HostName } catch {}

    foreach ($n in $namesToCheck) {
        if (-not $n) { continue }
        $str = $n.ToLower()
        if (-not $detectedEnv) {
            if ($str -match '\b(dev|qa|prod|patqa|patuat|uat|perf)\b') {
                $detectedEnv = $Matches[1]
            } elseif ($str -match '(dev|qa|prod|patqa|patuat|uat|perf)') {
                $detectedEnv = $Matches[1]
            }
        }
        if (-not $detectedPod) {
            if ($str -match '(pod\d+)') {
                $detectedPod = $Matches[1]
            } elseif ($str -match 'jazz') {
                $detectedPod = "jazz"
            }
        }
        if (-not $detectedStack) {
            if ($str -match '(dev|qa|prod|uat|patqa|patuat|perf)([a-d])\d*') {
                $detectedStack = $Matches[2]
            }
        }
    }

    # Strategy 4: S3 Bucket names
    if (-not $detectedPod -or -not $detectedEnv) {
        try {
            $s3List = aws s3 ls 2>$null
            if (-not $detectedEnv) {
                if ($s3List -match 'corecard-[a-z0-9]+-(dev|qa|prod|uat|patqa|patuat|perf)-') {
                    $detectedEnv = $Matches[1]
                }
            }
            if (-not $detectedPod -and $detectedEnv) {
                if ($s3List -match "corecard-pod2-$detectedEnv-") { $detectedPod = "pod2" }
                elseif ($s3List -match "corecard-pod4-$detectedEnv-") { $detectedPod = "pod4" }
                elseif ($s3List -match "corecard-jazz-$detectedEnv-") { $detectedPod = "jazz" }
            }
        } catch {}
    }

    # Strategy 5: Clean defaults
    if (-not $detectedEnv) { $detectedEnv = "dev" }
    if (-not $detectedPod) { $detectedPod = "pod2" }
    if (-not $detectedStack) { $detectedStack = "a" }

    return [PSCustomObject]@{
        Environment      = $detectedEnv
        Pod              = $detectedPod
        Stack            = $detectedStack
        AvailabilityZone = $detectedAZ
    }
}

function Get-DiscoveredAZs {
    param([string]$Region, [string]$ShortRegion, [string]$EnvName, [string]$EnvStack)
    $azList = @()
    # 1. Query running WCF servers to find their actual Availability Zones
    try {
        $queryResult = (aws ec2 describe-instances `
            --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone}" `
            --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='*wcf$ShortRegion$EnvName$EnvStack*'" "Name=availability-zone,Values='*'" `
            --region $Region 2>$null | ConvertFrom-Json)
        $flat = @($queryResult | ForEach-Object { $_ } | Where-Object { $_ })
        if ($flat.Count -gt 0) {
            $azList = @($flat | ForEach-Object { $_.AvailabilityZone } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
        }
    } catch {}

    # 2. Fallback to TNP servers if no WCF servers are currently running
    if (-not $azList -or $azList.Count -eq 0) {
        try {
            $queryResult = (aws ec2 describe-instances `
                --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone}" `
                --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='*tnp$ShortRegion$EnvName$EnvStack*'" "Name=availability-zone,Values='*'" `
                --region $Region 2>$null | ConvertFrom-Json)
            $flat = @($queryResult | ForEach-Object { $_ } | Where-Object { $_ })
            if ($flat.Count -gt 0) {
                $azList = @($flat | ForEach-Object { $_.AvailabilityZone } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
            }
        } catch {}
    }
    return $azList
}

$script:AllDiscoveredServers = @()

function Get-DiscoveredServers {
    param(
        [string]$Region,
        [string]$ShortRegion,
        [string]$EnvName,
        [string]$EnvStack,
        [string]$ServerType,
        [string]$SelectedAZ,
        [bool]$ForceRefresh = $false
    )

    if ($ForceRefresh -or (-not $script:AllDiscoveredServers) -or $script:AllDiscoveredServers.Count -eq 0) {
        try {
            $pattern = "*$ServerType$ShortRegion$EnvName$EnvStack*"
            $queryResult = (aws ec2 describe-instances `
                --query "Reservations[*].Instances[*].{AvailabilityZone:Placement.AvailabilityZone,IpAddress:PrivateIpAddress,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value,Status:State.Name}" `
                --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values='$pattern'" "Name=availability-zone,Values=*" `
                --region $Region 2>$null | ConvertFrom-Json)

            $flat = @($queryResult | ForEach-Object { $_ } | Where-Object { $_ })
            if ($flat.Count -gt 0) {
                $script:AllDiscoveredServers = @($flat | Where-Object { $_.Name } | Select-Object `
                    @{n = "Name"; e = { $_.Name } }, `
                    @{n = "AvailabilityZone"; e = { $_.AvailabilityZone } }, `
                    @{n = "serial"; e = {
                        try {
                            $parts = $_.Name -split "$EnvName$EnvStack"
                            if ($parts.Count -gt 1) { [double]$parts[1] } else { 0 }
                        } catch { 0 }
                    } } `
                    | Sort-Object -Property serial)
            } else {
                $script:AllDiscoveredServers = @()
            }
        } catch {
            $script:AllDiscoveredServers = @()
        }
    }

    if ($SelectedAZ -and $SelectedAZ -ne "*" -and $SelectedAZ -notmatch "All") {
        $cleanAZ = [string]$SelectedAZ.Trim()
        $matched = @($script:AllDiscoveredServers | Where-Object { 
            $serverAz = [string]$_.AvailabilityZone
            ($serverAz.Trim() -eq $cleanAZ) -or ($serverAz -like "*$cleanAZ*")
        })
        return $matched
    } else {
        return $script:AllDiscoveredServers
    }
}

# =====================================================================================================================
# BUILD GUI INTERFACE
# =====================================================================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "WCF AppPool Identity Manager & Zero-Downtime User Change - GUI"
$form.Size = New-Object System.Drawing.Size(1120, 840)
$form.MinimumSize = New-Object System.Drawing.Size(1020, 720)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Global script-scope variable for HTML report path
$script:LastReportFile = ""

# ---------------------------------------------------------------------------------------------------------------------
# HEADER BANNER
# ---------------------------------------------------------------------------------------------------------------------
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlHeader.Height = 70
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(43, 87, 154) # Steel Navy / Blue
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "WCF AppPool Identity Manager"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(18, 12)
$pnlHeader.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = "Developed by Netra Chettri"
$lblSubtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(220, 235, 255)
$lblSubtitle.AutoSize = $true
$lblSubtitle.Location = New-Object System.Drawing.Point(20, 42)
$pnlHeader.Controls.Add($lblSubtitle)

# ---------------------------------------------------------------------------------------------------------------------
# MAIN LAYOUT CONTAINER
# ---------------------------------------------------------------------------------------------------------------------
$pnlMain = New-Object System.Windows.Forms.Panel
$pnlMain.Dock = [System.Windows.Forms.DockStyle]::Fill
$pnlMain.Padding = New-Object System.Windows.Forms.Padding(12)
$form.Controls.Add($pnlMain)
$pnlHeader.SendToBack()

# Left Column (Discovery & Server Selection)
$grpDiscovery = New-Object System.Windows.Forms.GroupBox
$grpDiscovery.Text = " 1. AWS Discovery & Target Servers "
$grpDiscovery.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$grpDiscovery.ForeColor = [System.Drawing.Color]::FromArgb(35, 60, 95)
$grpDiscovery.Location = New-Object System.Drawing.Point(12, 10)
$grpDiscovery.Size = New-Object System.Drawing.Size(510, 715)
$grpDiscovery.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$pnlMain.Controls.Add($grpDiscovery)

# Controls inside grpDiscovery
$lblRegion = New-Object System.Windows.Forms.Label
$lblRegion.Text = "Region:"
$lblRegion.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblRegion.ForeColor = [System.Drawing.Color]::Black
$lblRegion.Location = New-Object System.Drawing.Point(15, 28)
$lblRegion.Size = New-Object System.Drawing.Size(65, 20)
$grpDiscovery.Controls.Add($lblRegion)

$cmbRegion = New-Object System.Windows.Forms.ComboBox
$cmbRegion.Items.AddRange(@("us-east-1", "us-west-2"))
$cmbRegion.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cmbRegion.Location = New-Object System.Drawing.Point(85, 25)
$cmbRegion.Size = New-Object System.Drawing.Size(140, 24)
$cmbRegion.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$grpDiscovery.Controls.Add($cmbRegion)

$lblEnv = New-Object System.Windows.Forms.Label
$lblEnv.Text = "Env:"
$lblEnv.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblEnv.ForeColor = [System.Drawing.Color]::Black
$lblEnv.Location = New-Object System.Drawing.Point(245, 28)
$lblEnv.Size = New-Object System.Drawing.Size(40, 20)
$grpDiscovery.Controls.Add($lblEnv)

$cmbEnv = New-Object System.Windows.Forms.ComboBox
$cmbEnv.Items.AddRange(@("prod", "qa", "dev", "patqa", "patuat", "uat", "perf"))
$cmbEnv.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cmbEnv.Location = New-Object System.Drawing.Point(290, 25)
$cmbEnv.Size = New-Object System.Drawing.Size(100, 24)
$grpDiscovery.Controls.Add($cmbEnv)

$lblStack = New-Object System.Windows.Forms.Label
$lblStack.Text = "Stack:"
$lblStack.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblStack.ForeColor = [System.Drawing.Color]::Black
$lblStack.Location = New-Object System.Drawing.Point(405, 28)
$lblStack.Size = New-Object System.Drawing.Size(40, 20)
$grpDiscovery.Controls.Add($lblStack)

$txtStack = New-Object System.Windows.Forms.TextBox
$txtStack.Text = "a"
$txtStack.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$txtStack.Location = New-Object System.Drawing.Point(450, 25)
$txtStack.Size = New-Object System.Drawing.Size(45, 24)
$grpDiscovery.Controls.Add($txtStack)

# Row 2: POD Selection & Availability Zone
$lblPod = New-Object System.Windows.Forms.Label
$lblPod.Text = "POD Name:"
$lblPod.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblPod.ForeColor = [System.Drawing.Color]::Black
$lblPod.Location = New-Object System.Drawing.Point(15, 62)
$lblPod.Size = New-Object System.Drawing.Size(70, 20)
$grpDiscovery.Controls.Add($lblPod)

$cmbPod = New-Object System.Windows.Forms.ComboBox
$cmbPod.Items.AddRange(@("pod2", "pod4", "jazz", "pod5"))
$cmbPod.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cmbPod.Location = New-Object System.Drawing.Point(85, 59)
$cmbPod.Size = New-Object System.Drawing.Size(140, 24)
$grpDiscovery.Controls.Add($cmbPod)

$lblAZ = New-Object System.Windows.Forms.Label
$lblAZ.Text = "Availability Zone:"
$lblAZ.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblAZ.ForeColor = [System.Drawing.Color]::Black
$lblAZ.Location = New-Object System.Drawing.Point(235, 62)
$lblAZ.Size = New-Object System.Drawing.Size(110, 20)
$grpDiscovery.Controls.Add($lblAZ)

$cmbAZ = New-Object System.Windows.Forms.ComboBox
$cmbAZ.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cmbAZ.Location = New-Object System.Drawing.Point(345, 59)
$cmbAZ.Size = New-Object System.Drawing.Size(150, 24)
$cmbAZ.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$grpDiscovery.Controls.Add($cmbAZ)

# Discovery Action Button
$btnDiscover = New-Object System.Windows.Forms.Button
$btnDiscover.Text = "Discover / Refresh Servers"
$btnDiscover.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnDiscover.BackColor = [System.Drawing.Color]::FromArgb(43, 87, 154)
$btnDiscover.ForeColor = [System.Drawing.Color]::White
$btnDiscover.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDiscover.Location = New-Object System.Drawing.Point(15, 95)
$btnDiscover.Size = New-Object System.Drawing.Size(480, 32)
$btnDiscover.Cursor = [System.Windows.Forms.Cursors]::Hand
$grpDiscovery.Controls.Add($btnDiscover)

# Server Selection Header and ListBox (no checkboxes)
$lblServerListHeader = New-Object System.Windows.Forms.Label
$lblServerListHeader.Text = "Target WCF Servers:"
$lblServerListHeader.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblServerListHeader.ForeColor = [System.Drawing.Color]::Black
$lblServerListHeader.Location = New-Object System.Drawing.Point(15, 137)
$lblServerListHeader.Size = New-Object System.Drawing.Size(220, 20)
$grpDiscovery.Controls.Add($lblServerListHeader)

$lblSelectionCount = New-Object System.Windows.Forms.Label
$lblSelectionCount.Text = "Servers Found: 0"
$lblSelectionCount.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblSelectionCount.ForeColor = [System.Drawing.Color]::FromArgb(43, 87, 154)
$lblSelectionCount.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblSelectionCount.Location = New-Object System.Drawing.Point(320, 137)
$lblSelectionCount.Size = New-Object System.Drawing.Size(175, 20)
$grpDiscovery.Controls.Add($lblSelectionCount)

$lstServerList = New-Object System.Windows.Forms.ListBox
$lstServerList.Location = New-Object System.Drawing.Point(15, 165)
$lstServerList.Size = New-Object System.Drawing.Size(480, 485)
$lstServerList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$lstServerList.Font = New-Object System.Drawing.Font("Consolas", 10)
$lstServerList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$grpDiscovery.Controls.Add($lstServerList)

$lblAZHint = New-Object System.Windows.Forms.Label
$lblAZHint.Text = "* Servers above are automatically filtered based on selected Availability Zone"
$lblAZHint.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Italic)
$lblAZHint.ForeColor = [System.Drawing.Color]::Gray
$lblAZHint.Location = New-Object System.Drawing.Point(15, 660)
$lblAZHint.Size = New-Object System.Drawing.Size(360, 20)
$lblAZHint.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$grpDiscovery.Controls.Add($lblAZHint)

$btnAddManual = New-Object System.Windows.Forms.Button
$btnAddManual.Text = "+ Add Server"
$btnAddManual.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnAddManual.Location = New-Object System.Drawing.Point(385, 656)
$btnAddManual.Size = New-Object System.Drawing.Size(110, 26)
$btnAddManual.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$btnAddManual.Cursor = [System.Windows.Forms.Cursors]::Hand
$grpDiscovery.Controls.Add($btnAddManual)


# ---------------------------------------------------------------------------------------------------------------------
# RIGHT COLUMN (AppPool Configuration & Action)
# ---------------------------------------------------------------------------------------------------------------------
$grpConfig = New-Object System.Windows.Forms.GroupBox
$grpConfig.Text = " 2. AppPool Identity & Update Settings "
$grpConfig.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$grpConfig.ForeColor = [System.Drawing.Color]::FromArgb(35, 60, 95)
$grpConfig.Location = New-Object System.Drawing.Point(535, 10)
$grpConfig.Size = New-Object System.Drawing.Size(555, 235)
$grpConfig.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$pnlMain.Controls.Add($grpConfig)

# AppPool Name
$lblAppPoolName = New-Object System.Windows.Forms.Label
$lblAppPoolName.Text = "AppPool Name:"
$lblAppPoolName.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblAppPoolName.ForeColor = [System.Drawing.Color]::Black
$lblAppPoolName.Location = New-Object System.Drawing.Point(20, 28)
$lblAppPoolName.Size = New-Object System.Drawing.Size(110, 20)
$grpConfig.Controls.Add($lblAppPoolName)

$txtAppPoolName = New-Object System.Windows.Forms.TextBox
$txtAppPoolName.Text = "WCF"
$txtAppPoolName.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$txtAppPoolName.Location = New-Object System.Drawing.Point(140, 25)
$txtAppPoolName.Size = New-Object System.Drawing.Size(395, 24)
$grpConfig.Controls.Add($txtAppPoolName)

# Target User Selection
$lblTargetUser = New-Object System.Windows.Forms.Label
$lblTargetUser.Text = "Target User:"
$lblTargetUser.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblTargetUser.ForeColor = [System.Drawing.Color]::Black
$lblTargetUser.Location = New-Object System.Drawing.Point(20, 62)
$lblTargetUser.Size = New-Object System.Drawing.Size(110, 20)
$grpConfig.Controls.Add($lblTargetUser)

$cmbTargetUser = New-Object System.Windows.Forms.ComboBox
$cmbTargetUser.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cmbTargetUser.Location = New-Object System.Drawing.Point(140, 59)
$cmbTargetUser.Size = New-Object System.Drawing.Size(395, 24)
$cmbTargetUser.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$grpConfig.Controls.Add($cmbTargetUser)

# Target Password (optional)
$lblPassword = New-Object System.Windows.Forms.Label
$lblPassword.Text = "Password:"
$lblPassword.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblPassword.ForeColor = [System.Drawing.Color]::Black
$lblPassword.Location = New-Object System.Drawing.Point(20, 96)
$lblPassword.Size = New-Object System.Drawing.Size(110, 20)
$grpConfig.Controls.Add($lblPassword)

$txtPassword = New-Object System.Windows.Forms.TextBox
$txtPassword.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$txtPassword.Location = New-Object System.Drawing.Point(140, 93)
$txtPassword.Size = New-Object System.Drawing.Size(220, 24)
$txtPassword.UseSystemPasswordChar = $true
$grpConfig.Controls.Add($txtPassword)

$lblPwdNote = New-Object System.Windows.Forms.Label
$lblPwdNote.Text = "(Leave empty for GMSA accounts)"
$lblPwdNote.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Italic)
$lblPwdNote.ForeColor = [System.Drawing.Color]::Gray
$lblPwdNote.Location = New-Object System.Drawing.Point(365, 96)
$lblPwdNote.Size = New-Object System.Drawing.Size(175, 20)
$grpConfig.Controls.Add($lblPwdNote)

# Checkboxes
$chkKeepRunning = New-Object System.Windows.Forms.CheckBox
$chkKeepRunning.Text = "Zero-Downtime Update: Keep AppPool running (Do NOT stop AppPool)"
$chkKeepRunning.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$chkKeepRunning.ForeColor = [System.Drawing.Color]::Black
$chkKeepRunning.Checked = $true
$chkKeepRunning.Location = New-Object System.Drawing.Point(23, 126)
$chkKeepRunning.Size = New-Object System.Drawing.Size(510, 22)
$grpConfig.Controls.Add($chkKeepRunning)

$chkAutoStart = New-Object System.Windows.Forms.CheckBox
$chkAutoStart.Text = "Ensure AppPool is Started if found in Stopped state"
$chkAutoStart.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$chkAutoStart.ForeColor = [System.Drawing.Color]::Black
$chkAutoStart.Checked = $true
$chkAutoStart.Location = New-Object System.Drawing.Point(23, 150)
$chkAutoStart.Size = New-Object System.Drawing.Size(510, 22)
$grpConfig.Controls.Add($chkAutoStart)

# Action Buttons
$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = "Apply AppPool User Change"
$btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(40, 167, 69) # Green
$btnApply.ForeColor = [System.Drawing.Color]::White
$btnApply.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnApply.Location = New-Object System.Drawing.Point(20, 182)
$btnApply.Size = New-Object System.Drawing.Size(280, 40)
$btnApply.Cursor = [System.Windows.Forms.Cursors]::Hand
$grpConfig.Controls.Add($btnApply)

$btnViewReport = New-Object System.Windows.Forms.Button
$btnViewReport.Text = "View HTML Report"
$btnViewReport.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnViewReport.BackColor = [System.Drawing.Color]::FromArgb(23, 162, 184) # Teal / Info
$btnViewReport.ForeColor = [System.Drawing.Color]::White
$btnViewReport.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnViewReport.Location = New-Object System.Drawing.Point(310, 182)
$btnViewReport.Size = New-Object System.Drawing.Size(225, 40)
$btnViewReport.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnViewReport.Enabled = $false
$grpConfig.Controls.Add($btnViewReport)


# ---------------------------------------------------------------------------------------------------------------------
# BOTTOM RIGHT: RESULTS & LOG TABS
# ---------------------------------------------------------------------------------------------------------------------
$tabOutput = New-Object System.Windows.Forms.TabControl
$tabOutput.Location = New-Object System.Drawing.Point(535, 255)
$tabOutput.Size = New-Object System.Drawing.Size(555, 470)
$tabOutput.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tabOutput.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$pnlMain.Controls.Add($tabOutput)

# Tab 1: Results Table
$tabResults = New-Object System.Windows.Forms.TabPage
$tabResults.Text = "Execution Results"
$tabResults.BackColor = [System.Drawing.Color]::White
$tabOutput.TabPages.Add($tabResults)

$gridResults = New-Object System.Windows.Forms.DataGridView
$gridResults.Dock = [System.Windows.Forms.DockStyle]::Fill
$gridResults.BackgroundColor = [System.Drawing.Color]::White
$gridResults.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$gridResults.AllowUserToAddRows = $false
$gridResults.AllowUserToDeleteRows = $false
$gridResults.ReadOnly = $true
$gridResults.RowHeadersVisible = $false
$gridResults.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$gridResults.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$gridResults.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Grid Columns
$colServer = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colServer.HeaderText = "Server Name"
$colServer.FillWeight = 85
$gridResults.Columns.Add($colServer) | Out-Null

$colAppPool = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colAppPool.HeaderText = "AppPool"
$colAppPool.FillWeight = 50
$gridResults.Columns.Add($colAppPool) | Out-Null

$colTarget = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTarget.HeaderText = "Target User"
$colTarget.FillWeight = 110
$gridResults.Columns.Add($colTarget) | Out-Null

$colConfigured = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colConfigured.HeaderText = "Configured User"
$colConfigured.FillWeight = 110
$gridResults.Columns.Add($colConfigured) | Out-Null

$colState = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colState.HeaderText = "State"
$colState.FillWeight = 50
$gridResults.Columns.Add($colState) | Out-Null

$colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colStatus.HeaderText = "Status"
$colStatus.FillWeight = 60
$gridResults.Columns.Add($colStatus) | Out-Null

$colMsg = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colMsg.HeaderText = "Remarks / Message"
$colMsg.FillWeight = 140
$gridResults.Columns.Add($colMsg) | Out-Null

$tabResults.Controls.Add($gridResults)

# Tab 2: Live Console Log
$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = "Live Console Log"
$tabLog.BackColor = [System.Drawing.Color]::White
$tabOutput.TabPages.Add($tabLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtLog.Multiline = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$tabLog.Controls.Add($txtLog)

# ---------------------------------------------------------------------------------------------------------------------
# STATUS BAR
# ---------------------------------------------------------------------------------------------------------------------
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor = [System.Drawing.Color]::FromArgb(235, 238, 242)
$form.Controls.Add($statusStrip)

$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Ready"
$statusLabel.Spring = $true
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusStrip.Items.Add($statusLabel) | Out-Null

$statusProgress = New-Object System.Windows.Forms.ToolStripProgressBar
$statusProgress.Size = New-Object System.Drawing.Size(180, 16)
$statusProgress.Visible = $false
$statusStrip.Items.Add($statusProgress) | Out-Null

$statusAuthor = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusAuthor.Text = "Developed by Netra Chettri"
$statusAuthor.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$statusAuthor.ForeColor = [System.Drawing.Color]::FromArgb(43, 87, 154)
$statusStrip.Items.Add($statusAuthor) | Out-Null


# =====================================================================================================================
# LOGGING HELPER
# =====================================================================================================================
function Write-GuiLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp] [$Level] $Message`r`n"
    $txtLog.AppendText($line)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    $statusLabel.Text = $Message
    [System.Windows.Forms.Application]::DoEvents()
}

# =====================================================================================================================
# EVENT HANDLERS & LOGIC
# =====================================================================================================================

function Update-UserPresets {
    $envName = if ($cmbEnv.Text) { $cmbEnv.Text.Trim().ToLower() } else { "dev" }
    $podName = if ($cmbPod.Text) { $cmbPod.Text.Trim().ToLower() } else { "pod2" }

    $currentVal = $cmbTargetUser.Text
    $cmbTargetUser.Items.Clear()

    # Dynamic presets strictly based on EC2 fetched / selected Environment and POD (No hardcoded environments)
    $primarySvc = "cc-$podName-$envName\gmsa-app-svc$"
    $primaryUpg = "cc-$podName-$envName\gmsa-app-upg$"

    $cmbTargetUser.Items.Add($primarySvc) | Out-Null
    $cmbTargetUser.Items.Add($primaryUpg) | Out-Null

    # Include peer pod options for the same detected environment only
    if ($podName -eq "pod2") {
        $cmbTargetUser.Items.Add("cc-pod4-$envName\gmsa-app-svc$") | Out-Null
        $cmbTargetUser.Items.Add("cc-pod4-$envName\gmsa-app-upg$") | Out-Null
    } elseif ($podName -eq "pod4") {
        $cmbTargetUser.Items.Add("cc-pod2-$envName\gmsa-app-svc$") | Out-Null
        $cmbTargetUser.Items.Add("cc-pod2-$envName\gmsa-app-upg$") | Out-Null
    }

    # Automatically select primary svc user for the detected environment
    if ($currentVal -and ($cmbTargetUser.Items.Contains($currentVal))) {
        $cmbTargetUser.SelectedItem = $currentVal
    } elseif ($cmbTargetUser.Items.Count -gt 0) {
        $cmbTargetUser.SelectedIndex = 0
    }
}

function Update-ServerListByAZ {
    if (-not $cmbAZ.SelectedItem) { return }
    $selectedAZ = $cmbAZ.SelectedItem.ToString().Trim()
    $region = $cmbRegion.Text
    $shortRegion = if ($region -match 'w2') { 'w2' } else { 'e1' }
    $envName = $cmbEnv.Text.Trim().ToLower()
    $envStack = $txtStack.Text.Trim().ToLower()
    if (-not $envStack) { $envStack = 'a' }

    $azFilter = if ($selectedAZ -match 'All' -or $selectedAZ -eq '*') { "*" } else { $selectedAZ }
    $servers = @(Get-DiscoveredServers -Region $region -ShortRegion $shortRegion -EnvName $envName -EnvStack $envStack -ServerType "wcf" -SelectedAZ $azFilter -ForceRefresh $false)

    $lstServerList.Items.Clear()
    if ($servers.Count -gt 0) {
        foreach ($srv in $servers) {
            $displayItem = "$($srv.Name)  [$($srv.AvailabilityZone)]"
            $lstServerList.Items.Add($displayItem) | Out-Null
        }
        Write-GuiLog "Loaded $($servers.Count) server(s) for Availability Zone '$selectedAZ'."
    } else {
        Write-GuiLog "No running WCF servers found for Availability Zone '$selectedAZ'." "WARNING"
    }

    $lblSelectionCount.Text = "Servers Found: $($lstServerList.Items.Count)"
}

function Refresh-Discovery {
    $region = $cmbRegion.Text
    $shortRegion = if ($region -match 'w2') { 'w2' } else { 'e1' }
    $envName = $cmbEnv.Text.Trim().ToLower()
    $envStack = $txtStack.Text.Trim().ToLower()
    if (-not $envStack) { $envStack = 'a'; $txtStack.Text = 'a' }

    Write-GuiLog "Starting discovery for Region: $region | Env: $envName | Stack: $envStack..."

    # 1. Fetch all running WCF servers from AWS
    $allWcfServers = @(Get-DiscoveredServers -Region $region -ShortRegion $shortRegion -EnvName $envName -EnvStack $envStack -ServerType "wcf" -SelectedAZ "*" -ForceRefresh $true)

    # 2. Extract distinct Availability Zones from discovered servers
    $azs = @()
    if ($allWcfServers.Count -gt 0) {
        $azs = @($allWcfServers | ForEach-Object { [string]$_.AvailabilityZone.Trim() } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
    }

    # Fallback to TNP query if no WCF servers found
    if ($azs.Count -eq 0) {
        $azs = @(Get-DiscoveredAZs -Region $region -ShortRegion $shortRegion -EnvName $envName -EnvStack $envStack)
    }

    $currentSelectedAZ = if ($cmbAZ.SelectedItem) { $cmbAZ.SelectedItem.ToString().Trim() } else { "" }

    $cmbAZ.Items.Clear()
    foreach ($az in $azs) {
        $cmbAZ.Items.Add($az) | Out-Null
    }

    if ($currentSelectedAZ -and ($cmbAZ.Items.Contains($currentSelectedAZ))) {
        $cmbAZ.SelectedItem = $currentSelectedAZ
    } elseif ($cmbAZ.Items.Count -gt 0) {
        $cmbAZ.SelectedIndex = 0
    }

    # 3. Update server list based on selected AZ
    Update-ServerListByAZ
    Update-UserPresets
}

# ComboBox Changes
$cmbEnv.Add_SelectedIndexChanged({ Update-UserPresets; Refresh-Discovery })
$cmbPod.Add_SelectedIndexChanged({ Update-UserPresets })
$cmbAZ.Add_SelectedIndexChanged({ Update-ServerListByAZ })

$btnDiscover.Add_Click({ Refresh-Discovery })

$btnAddManual.Add_Click({
    $manualForm = New-Object System.Windows.Forms.Form
    $manualForm.Text = "Add Server Manually"
    $manualForm.Size = New-Object System.Drawing.Size(380, 160)
    $manualForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $manualForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $manualForm.MaximizeBox = $false
    $manualForm.MinimizeBox = $false

    $lblM = New-Object System.Windows.Forms.Label
    $lblM.Text = "Enter Server Hostname / IP Address:"
    $lblM.Location = New-Object System.Drawing.Point(15, 15)
    $lblM.Size = New-Object System.Drawing.Size(330, 20)
    $manualForm.Controls.Add($lblM)

    $txtM = New-Object System.Windows.Forms.TextBox
    $txtM.Location = New-Object System.Drawing.Point(18, 40)
    $txtM.Size = New-Object System.Drawing.Size(325, 24)
    $manualForm.Controls.Add($txtM)

    $btnMOk = New-Object System.Windows.Forms.Button
    $btnMOk.Text = "Add"
    $btnMOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnMOk.Location = New-Object System.Drawing.Point(170, 80)
    $btnMOk.Size = New-Object System.Drawing.Size(80, 28)
    $manualForm.Controls.Add($btnMOk)

    $btnMCancel = New-Object System.Windows.Forms.Button
    $btnMCancel.Text = "Cancel"
    $btnMCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnMCancel.Location = New-Object System.Drawing.Point(260, 80)
    $btnMCancel.Size = New-Object System.Drawing.Size(80, 28)
    $manualForm.Controls.Add($btnMCancel)
    $manualForm.AcceptButton = $btnMOk

    if ($manualForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $txtM.Text.Trim()) {
        $srvName = $txtM.Text.Trim().ToLower()
        $lstServerList.Items.Add("$srvName  [Manual]") | Out-Null
        $lblSelectionCount.Text = "Servers Found: $($lstServerList.Items.Count)"
    }
})

$btnViewReport.Add_Click({
    if ($script:LastReportFile -and (Test-Path $script:LastReportFile)) {
        try { Start-Process $script:LastReportFile } catch { Invoke-Item $script:LastReportFile }
    } else {
        [System.Windows.Forms.MessageBox]::Show("No HTML report file found yet.", "Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
})


# ---------------------------------------------------------------------------------------------------------------------
# EXECUTION ENGINE: APPLY APP POOL CHANGE
# ---------------------------------------------------------------------------------------------------------------------
$btnApply.Add_Click({
    $targetAppPool = $txtAppPoolName.Text.Trim()
    $targetUser = $cmbTargetUser.Text.Trim()
    $targetPassword = $txtPassword.Text
    $keepRunning = $chkKeepRunning.Checked
    $autoStart = $chkAutoStart.Checked

    if (-not $targetAppPool) {
        [System.Windows.Forms.MessageBox]::Show("Please enter an AppPool name.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    if (-not $targetUser) {
        [System.Windows.Forms.MessageBox]::Show("Please specify a target user account.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $serverItems = @($lstServerList.Items)
    if ($serverItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No target servers available for the selected Availability Zone ($($cmbAZ.Text)).", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    # Extract clean hostnames from the displayed strings ("ccwcfe1devb2  [us-east-1b]" -> "ccwcfe1devb2")
    $targetServers = @()
    foreach ($item in $serverItems) {
        $serverName = ($item -split "\s+\[")[0].Trim()
        if ($serverName) { $targetServers += $serverName }
    }

    $selectedAZName = $cmbAZ.Text
    $confirmMsg = "You are about to update the WCF AppPool identity on $($targetServers.Count) server(s):`n`n" +
                  "Availability Zone : $selectedAZName`n" +
                  "Target AppPool    : $targetAppPool`n" +
                  "Target User       : $targetUser`n" +
                  "Zero-Downtime     : $(if ($keepRunning) { 'Yes (Do not stop AppPool)' } else { 'No' })`n`n" +
                  "Proceed with execution?"

    $confirm = [System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm AppPool User Change", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # UI State: Busy
    $btnApply.Enabled = $false
    $btnDiscover.Enabled = $false
    $statusProgress.Visible = $true
    $statusProgress.Minimum = 0
    $statusProgress.Maximum = $targetServers.Count
    $statusProgress.Value = 0

    $gridResults.Rows.Clear()
    $tabOutput.SelectedTab = $tabResults

    Write-GuiLog "====================================================================="
    Write-GuiLog "Starting AppPool User Change: AppPool='$targetAppPool', User='$targetUser'"
    Write-GuiLog "Target Server Count: $($targetServers.Count)"

    $option = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 20000
    $Results = @()
    $currentIndex = 0

    # Remote Execution ScriptBlock
    $ExecutionScriptBlock = {
        param(
            [string]$targetAppPool,
            [string]$targetUser,
            [string]$targetPassword,
            [bool]$keepRunning,
            [bool]$ensureStarted
        )
        Import-Module WebAdministration -ErrorAction SilentlyContinue

        if (-not (Test-Path "IIS:\AppPools\$targetAppPool")) {
            return [PSCustomObject]@{
                ServerName     = $env:COMPUTERNAME
                AppPoolName    = $targetAppPool
                UserName       = $targetUser
                ConfiguredUser = "Not Found"
                AppPoolState   = "N/A"
                Status         = "FAILED"
                Message        = "AppPool '$targetAppPool' does not exist on this server"
            }
        }

        # 1. Update AppPool identity without stopping the app pool
        try {
            Set-ItemProperty "IIS:\AppPools\$targetAppPool" -name processModel -value @{
                userName     = $targetUser
                password     = $targetPassword
                identitytype = 3
            } -ErrorAction Stop
        } catch {
            return [PSCustomObject]@{
                ServerName     = $env:COMPUTERNAME
                AppPoolName    = $targetAppPool
                UserName       = $targetUser
                ConfiguredUser = "Error"
                AppPoolState   = "Unknown"
                Status         = "FAILED"
                Message        = "Failed to set processModel: $($_.Exception.Message)"
            }
        }

        # 2. Check current AppPool state
        $appPoolState = try { (Get-WebAppPoolState -Name $targetAppPool).Value } catch { "Unknown" }

        # 3. If AppPool was stopped and ensureStarted is true, start it (never stop it)
        if ($ensureStarted -and ($appPoolState -eq "Stopped")) {
            try {
                Start-WebAppPool -Name $targetAppPool -ErrorAction SilentlyContinue
            } catch {
                try {
                    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start apppool /apppool.name:"$targetAppPool" 2>&1 | Out-Null
                } catch {}
            }
            Start-Sleep -Seconds 1
            $appPoolState = try { (Get-WebAppPoolState -Name $targetAppPool).Value } catch { "Unknown" }
        }

        # 4. Verify configured identity from IIS
        $configuredUser = try { (Get-ItemProperty "IIS:\AppPools\$targetAppPool" -Name processModel).userName } catch { "Error" }
        $status = if (($configuredUser -eq $targetUser) -and ($appPoolState -eq "Started")) { "SUCCESS" } else { "FAILED" }

        $msg = if ($status -eq "SUCCESS") {
            "AppPool user updated successfully without stopping AppPool (State: $appPoolState)"
        } elseif ($configuredUser -ne $targetUser) {
            "Configured user ($configuredUser) does not match target ($targetUser)"
        } else {
            "AppPool user updated, but AppPool state is $appPoolState"
        }

        return [PSCustomObject]@{
            ServerName     = $env:COMPUTERNAME
            AppPoolName    = $targetAppPool
            UserName       = $targetUser
            ConfiguredUser = $configuredUser
            AppPoolState   = $appPoolState
            Status         = $status
            Message        = $msg
        }
    }

    # Execute per server with live UI updates
    foreach ($comp in $targetServers) {
        $currentIndex++
        $statusProgress.Value = $currentIndex
        Write-GuiLog "[$currentIndex/$($targetServers.Count)] Connecting to $comp..."

        $serverResult = $null
        try {
            if ($comp -eq $env:COMPUTERNAME -or $comp -eq "localhost") {
                $serverResult = & $ExecutionScriptBlock $targetAppPool $targetUser $targetPassword $keepRunning $autoStart
            } else {
                $serverResult = Invoke-Command -ComputerName $comp -SessionOption $option -ErrorAction Stop `
                    -ScriptBlock $ExecutionScriptBlock `
                    -ArgumentList $targetAppPool, $targetUser, $targetPassword, $keepRunning, $autoStart
            }
        } catch {
            $serverResult = [PSCustomObject]@{
                ServerName     = $comp
                AppPoolName    = $targetAppPool
                UserName       = $targetUser
                ConfiguredUser = "Error"
                AppPoolState   = "N/A"
                Status         = "FAILED"
                Message        = "$($_.Exception.Message)"
            }
        }

        $Results += $serverResult

        # Add row to DataGridView
        $rowIndex = $gridResults.Rows.Add($serverResult.ServerName, $serverResult.AppPoolName, $serverResult.UserName, $serverResult.ConfiguredUser, $serverResult.AppPoolState, $serverResult.Status, $serverResult.Message)
        $row = $gridResults.Rows[$rowIndex]

        if ($serverResult.Status -eq "SUCCESS") {
            $row.Cells[5].Style.BackColor = [System.Drawing.Color]::FromArgb(212, 237, 218) # Light green
            $row.Cells[5].Style.ForeColor = [System.Drawing.Color]::FromArgb(21, 87, 36)
            $row.Cells[5].Style.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
            Write-GuiLog "[$currentIndex/$($targetServers.Count)] $comp`: SUCCESS - $($serverResult.Message)" "SUCCESS"
        } else {
            $row.Cells[5].Style.BackColor = [System.Drawing.Color]::FromArgb(248, 215, 218) # Light red/salmon
            $row.Cells[5].Style.ForeColor = [System.Drawing.Color]::FromArgb(114, 28, 36)
            $row.Cells[5].Style.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
            Write-GuiLog "[$currentIndex/$($targetServers.Count)] $comp`: FAILED - $($serverResult.Message)" "ERROR"
        }

        # Auto-scroll grid to latest row
        $gridResults.FirstDisplayedScrollingRowIndex = $rowIndex
        [System.Windows.Forms.Application]::DoEvents()
    }

    # Summary Counts
    $successCount = @($Results | Where-Object { $_.Status -eq "SUCCESS" }).Count
    $failedCount = @($Results | Where-Object { $_.Status -ne "SUCCESS" }).Count
    $totalCount = @($Results).Count

    Write-GuiLog "Execution Complete. Total: $totalCount | Success: $successCount | Failed: $failedCount"

    # =================================================================================================================
    # HTML REPORT GENERATION & S3 UPLOAD
    # =================================================================================================================
    $envName = $cmbEnv.Text.Trim().ToUpper()
    $podName = $cmbPod.Text.Trim().ToUpper()
    $region = $cmbRegion.Text.Trim()
    $azText = $cmbAZ.Text

    $Outputreport = "<HTML><TITLE> WCF-AppPool-UserChange Report </TITLE>
<BODY bgcolor=""white"" style=""background-color:white; font-family:'Segoe UI', Tahoma, Arial, sans-serif; margin:20px;"">
<font color=""#4682B4"" face=""Segoe UI"">
<H2 style=""color:#4682B4;"">$envName - $podName - WCF App Pool User Change Report</H2>
<H3 style=""color:#4682B4;"">PLEASE VERIFY BELOW TABLE VALUES FOR WCF APP POOL USER CHANGE</H3>
<H4 style=""color:#555555; margin-top:2px;"">Developed by Netra Chettri</H4>
<H4 style=""color:#333333;"">Target User: $targetUser | AppPool: $targetAppPool | Total: $totalCount | Success: $successCount | Failed: $failedCount</H4></font>
<Table border=1 cellpadding=6 cellspacing=0 style=""border-collapse:collapse; background-color:white; border:1px solid #cccccc; width:100%;"">
<TR bgcolor=""#4682B4"" align=center style=""background-color:#4682B4; color:white;"">
    <TH style=""padding:8px;""><B>Server Name</B></TH>
    <TH style=""padding:8px;""><B>App Pool</B></TH>
    <TH style=""padding:8px;""><B>Target User</B></TH>
    <TH style=""padding:8px;""><B>Configured User</B></TH>
    <TH style=""padding:8px;""><B>App Pool State</B></TH>
    <TH style=""padding:8px;""><B>Status</B></TH>
    <TH style=""padding:8px;""><B>Message / Remarks</B></TH>
</TR>"

    foreach ($res in $Results) {
        if ($res.Status -eq "SUCCESS") {
            $rowBg = "style=""background-color:#ffffff;"""
            $statusCell = "<TD bgcolor=LightGreen align=center style=""background-color:#d4edda; color:#155724; font-weight:bold;""><B>SUCCESS</B></TD>"
        } else {
            $rowBg = "bgcolor=LightSalmon style=""background-color:#fff3cd;"""
            $statusCell = "<TD bgcolor=LightSalmon align=center style=""background-color:#f8d7da; color:#721c24; font-weight:bold;""><B>FAILED</B></TD>"
        }

        $Outputreport += "<TR $rowBg align=center>
            <TD align=center style=""padding:6px;"">$($res.ServerName)</TD>
            <TD align=center style=""padding:6px;"">$($res.AppPoolName)</TD>
            <TD align=center style=""padding:6px;"">$($res.UserName)</TD>
            <TD align=center style=""padding:6px;"">$($res.ConfiguredUser)</TD>
            <TD align=center style=""padding:6px;"">$($res.AppPoolState)</TD>
            $statusCell
            <TD align=left style=""padding:6px;"">$($res.Message)</TD>
        </TR>"
    }

    $Outputreport += "</Table></BODY></HTML>"

    if (-not (Test-Path "C:\Temp")) { New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null }
    $ReportFileNamePrefix = "WCF_AppPool_UserChange_"
    $ReportFile = "C:\Temp\$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd-hhmm).html"
    $Outputreport | Out-File "$ReportFile" -Encoding UTF8
    $script:LastReportFile = $ReportFile
    $btnViewReport.Enabled = $true

    Write-GuiLog "HTML Report generated: $ReportFile" "SUCCESS"

    # S3 Upload
    if ($podName -and $envName -and $region) {
        $s3Target = "s3://corecard-$($podName.ToLower())-$($envName.ToLower())-$region-config-files/EnvironmentValidationReports/$ReportFileNamePrefix$(Get-Date -Format yyyy-MM-dd).html"
        try {
            aws s3 cp $ReportFile $s3Target
            Write-GuiLog "Uploaded report to S3: $s3Target" "SUCCESS"
        } catch {
            Write-GuiLog "S3 upload skipped/failed: $($_.Exception.Message)" "WARNING"
        }
    }

    # Re-enable UI
    $btnApply.Enabled = $true
    $btnDiscover.Enabled = $true
    $statusProgress.Visible = $false
    $statusLabel.Text = "Finished! Success: $successCount | Failed: $failedCount"

    # Automatically open HTML report
    try { Start-Process $ReportFile } catch { Invoke-Item $ReportFile }

    [System.Windows.Forms.MessageBox]::Show("AppPool user change completed!`n`nTotal Servers: $totalCount`nSuccess: $successCount`nFailed: $failedCount`n`nHTML Report: $ReportFile", "Execution Finished", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})


# ---------------------------------------------------------------------------------------------------------------------
# FORM INITIALIZATION ON LOAD
# ---------------------------------------------------------------------------------------------------------------------
$form.Add_Shown({
    Write-GuiLog "Initializing WCF AppPool GUI..."

    # 1. Detect Region
    $regInfo = Get-DetectedRegion
    $cmbRegion.SelectedItem = $regInfo.Region
    if (-not $cmbRegion.SelectedItem) { $cmbRegion.SelectedIndex = 0 }

    # 2. Query Self Metadata & Environment automatically from EC2
    $autoInfo = Get-DetectedEnvironment -Region $cmbRegion.SelectedItem
    Write-GuiLog "EC2 Auto-Discovery -> Environment: '$($autoInfo.Environment)' | POD: '$($autoInfo.Pod)' | Stack: '$($autoInfo.Stack)'"

    # Automatically set Environment from EC2
    if ($autoInfo.Environment) {
        if (-not $cmbEnv.Items.Contains($autoInfo.Environment)) {
            $cmbEnv.Items.Insert(0, $autoInfo.Environment) | Out-Null
        }
        $cmbEnv.SelectedItem = $autoInfo.Environment
    } else {
        $cmbEnv.SelectedIndex = 0
    }

    # Automatically set POD from EC2
    if ($autoInfo.Pod) {
        if (-not $cmbPod.Items.Contains($autoInfo.Pod)) {
            $cmbPod.Items.Insert(0, $autoInfo.Pod) | Out-Null
        }
        $cmbPod.SelectedItem = $autoInfo.Pod
    } else {
        $cmbPod.SelectedIndex = 0
    }

    # Automatically set Stack from EC2
    if ($autoInfo.Stack) {
        $txtStack.Text = $autoInfo.Stack
    }

    # 3. Populate Target Users for detected EC2 Environment (No hardcoded users)
    Update-UserPresets

    # 4. Discover AZs and Servers
    Refresh-Discovery
})

# Show the GUI
[void]$form.ShowDialog()
