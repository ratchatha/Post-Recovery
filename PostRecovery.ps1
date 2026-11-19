param([int[]]$Steps)

$ErrorActionPreference = 'Continue'
$script:Results = New-Object System.Collections.ArrayList
$script:NeedRestart = $false

$cs   = Get-CimInstance Win32_ComputerSystem
$csp  = Get-CimInstance Win32_ComputerSystemProduct
$bios = Get-CimInstance Win32_BIOS

# ---------------------------------------------------------------- helpers
function Add-Result($Step, $Status, $Detail) {
    [void]$script:Results.Add([PSCustomObject]@{ Step = $Step; Status = $Status; Detail = $Detail })
    $color = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ("  [{0}] {1}" -f $Status, $Detail) -ForegroundColor $color
}
function Title($t) { Write-Host ""; Write-Host ("=== " + $t + " ===") -ForegroundColor Cyan }
function Confirm-Yes($msg) { $a = Read-Host ("  " + $msg + " (Y/N)"); return ($a -match '^[Yy]') }
function Test-Winget { return [bool](Get-Command winget -ErrorAction SilentlyContinue) }

function Get-Installed {
    if (-not $script:InstalledCache) {
        $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $script:InstalledCache = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } | Select-Object DisplayName, DisplayVersion
    }
    return $script:InstalledCache
}

# ---------------------------------------------------------------- 1
function Step1 {
    Title "1. Windows Update / Intel Driver Support"
    try {
        Write-Host "  Searching for updates (this can take several minutes)..."
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res = $searcher.Search("IsInstalled=0 and IsHidden=0")
        $n = $res.Updates.Count
        if ($n -eq 0) {
            Add-Result 1 'OK' 'Windows Update: no pending updates'
        } else {
            Add-Result 1 'WARN' "Windows Update: $n pending update(s)"
            foreach ($u in $res.Updates) { Write-Host ("     - " + $u.Title) }
            if (Confirm-Yes "Install all updates now?") {
                $coll = New-Object -ComObject Microsoft.Update.UpdateColl
                foreach ($u in $res.Updates) {
                    if (-not $u.EulaAccepted) { $u.AcceptEula() }
                    [void]$coll.Add($u)
                }
                Write-Host "  Downloading..."
                $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
                Write-Host "  Installing..."
                $in = $session.CreateUpdateInstaller(); $in.Updates = $coll; $r = $in.Install()
                if ($r.RebootRequired) {
                    $script:NeedRestart = $true
                    Add-Result 1 'WARN' 'Installed. Restart required; run step 1 again afterwards to check for more updates'
                } else {
                    Add-Result 1 'OK' 'Updates installed'
                }
            }
        }
    } catch { Add-Result 1 'FAIL' ("Windows Update check failed: " + $_.Exception.Message) }

    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Manufacturer
    if ($cpu -match 'Intel') {
        $dsa = Get-Installed | Where-Object { $_.DisplayName -match 'Intel.*Driver.*Support' }
        if ($dsa) {
            Add-Result 1 'OK' 'Intel Driver & Support Assistant is installed'
        } else {
            Add-Result 1 'WARN' 'Intel Driver & Support Assistant not found'
            if (Confirm-Yes "Install it (winget) or open the download page?") {
                if (Test-Winget) {
                    winget install --id Intel.IntelDriverAndSupportAssistant -e --accept-source-agreements --accept-package-agreements
                } else {
                    Start-Process 'https://www.intel.com/content/www/us/en/support/detect.html'
                }
            }
        }
    } else {
        Add-Result 1 'INFO' 'CPU is not Intel; skipping Intel DSA check'
    }
}

# ---------------------------------------------------------------- 2
function Step2 {
    Title "2. Basic software"
    $apps = Get-Installed
    $chrome = $apps | Where-Object { $_.DisplayName -match 'Google Chrome' } | Select-Object -First 1
    $m365   = $apps | Where-Object { $_.DisplayName -match 'Microsoft 365|Microsoft Office|Office 16' } | Select-Object -First 1
    $adobe  = $apps | Where-Object { $_.DisplayName -match 'Adobe Acrobat|Adobe Reader' } | Select-Object -First 1

    $targets = @(
        @{ Name = 'Google Chrome'; Found = $chrome; Winget = 'Google.Chrome' },
        @{ Name = 'Microsoft 365'; Found = $m365;   Winget = $null },
        @{ Name = 'Adobe Acrobat/Reader'; Found = $adobe; Winget = 'Adobe.Acrobat.Reader.64-bit' }
    )
    foreach ($t in $targets) {
        if ($t.Found) {
            Add-Result 2 'OK' ("{0}: {1} {2}" -f $t.Name, $t.Found.DisplayName, $t.Found.DisplayVersion)
        } else {
            Add-Result 2 'FAIL' ("{0}: not found" -f $t.Name)
            if ($t.Winget -and (Test-Winget)) {
                if (Confirm-Yes ("Install {0} with winget?" -f $t.Name)) {
                    winget install --id $t.Winget -e --accept-source-agreements --accept-package-agreements
                    $script:InstalledCache = $null
                }
            } elseif (-not $t.Winget) {
                Write-Host "     (Microsoft 365 must be installed and signed in manually)" -ForegroundColor Gray
            }
        }
    }
}

# ---------------------------------------------------------------- 3
function Step3 {
    Title "3. Camera / Speaker / Time / Keyboard language"

    # camera
    $cams = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { ($_.Class -in 'Camera', 'Image') -and ($_.FriendlyName -notmatch 'Scanner') }
    if ($cams) {
        foreach ($c in $cams) {
            $st = if ($c.Status -eq 'OK') { 'OK' } else { 'FAIL' }
            Add-Result 3 $st ("Camera: {0} (status {1})" -f $c.FriendlyName, $c.Status)
        }
        if (Confirm-Yes "Open the Camera app to test the picture?") {
            Start-Process 'microsoft.windows.camera:'
            if (Confirm-Yes "Does the camera picture look normal?") { Add-Result 3 'OK' 'Camera picture test passed' }
            else { Add-Result 3 'FAIL' 'Camera picture is abnormal' }
        }
    } else {
        Add-Result 3 'WARN' 'No camera device found (ignore if this model has no camera)'
    }

    # sound
    $snd = Get-CimInstance Win32_SoundDevice
    if ($snd) {
        foreach ($s in $snd) { Write-Host ("     Audio: {0} ({1})" -f $s.Name, $s.Status) }
        [System.Media.SystemSounds]::Exclamation.Play(); Start-Sleep -Seconds 1
        if (Confirm-Yes "Did you hear the test sound from the speakers?") { Add-Result 3 'OK' 'Speakers working' }
        else { Add-Result 3 'FAIL' 'No sound from speakers (check volume / mute / driver)' }
    } else {
        Add-Result 3 'FAIL' 'No audio device found'
    }

    # time
    $tz = Get-TimeZone
    Write-Host ("     Current time: {0}  Time zone: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $tz.DisplayName)
    try {
        Set-Service w32time -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service w32time -ErrorAction SilentlyContinue
        w32tm /resync /force | Out-Null
        if ($LASTEXITCODE -eq 0) { Add-Result 3 'OK' 'Time synchronized with time server' }
        else { Add-Result 3 'WARN' 'Time sync failed (check internet connection)' }
    } catch { Add-Result 3 'WARN' 'Time sync failed' }
    if ($tz.Id -ne 'SE Asia Standard Time') {
        Add-Result 3 'WARN' ("Time zone is {0}, not Thailand" -f $tz.Id)
        if (Confirm-Yes "Set time zone to (UTC+07:00) Bangkok?") { Set-TimeZone -Id 'SE Asia Standard Time'; Add-Result 3 'OK' 'Time zone set to Thailand' }
    } else {
        Add-Result 3 'OK' 'Time zone: Thailand'
    }

    # languages
    $langs = Get-WinUserLanguageList
    $tags = $langs | ForEach-Object { $_.LanguageTag }
    Write-Host ("     Keyboard languages: " + ($tags -join ', '))
    if ($tags -contains 'th-TH' -and ($tags | Where-Object { $_ -like 'en-*' })) {
        Add-Result 3 'OK' 'Thai and English present (test the switch key: ~ or Alt+Shift)'
    } else {
        Add-Result 3 'WARN' 'Thai or English is missing from the language list'
        if (-not ($tags -contains 'th-TH') -and (Confirm-Yes "Add Thai (th-TH)?")) {
            $l = Get-WinUserLanguageList; $l.Add('th-TH'); Set-WinUserLanguageList $l -Force
            Add-Result 3 'OK' 'Thai language added'
        }
    }
}

# ---------------------------------------------------------------- 4
function Step4 {
    Title "4. Device name (Settings > About > Device name) = Barcode"
    $cur = $env:COMPUTERNAME
    Write-Host "     Current device name : $cur"
    Write-Host "     Serial number       : $($bios.SerialNumber)"
    $bc = (Read-Host "  Scan/type the barcode to use as device name (Enter = skip)").Trim()
    if (-not $bc) { Add-Result 4 'INFO' 'Rename skipped'; return }
    if ($bc -ieq $cur) { Add-Result 4 'OK' "Device name already matches barcode ($cur)"; return }
    if (($bc -notmatch '^[A-Za-z0-9-]{1,15}$') -or ($bc -match '^\d+$')) {
        Add-Result 4 'FAIL' 'Device name must be 1-15 chars, only A-Z, 0-9, hyphen, and not all digits (Windows limit)'
        return
    }
    try {
        Rename-Computer -NewName $bc -Force -ErrorAction Stop
        $script:NeedRestart = $true
        Add-Result 4 'WARN' "Renamed to $bc (restart required to take effect)"
    } catch { Add-Result 4 'FAIL' ("Rename failed: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------- 5
function Step5 {
    Title "5. Drive partitions"
    Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
        Write-Host ("     {0}: {1,-14} total {2,8:N1} GB / free {3,8:N1} GB ({4})" -f $_.DriveLetter, $_.FileSystemLabel, ($_.Size / 1GB), ($_.SizeRemaining / 1GB), $_.FileSystem)
    }
    $others = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.DriveLetter -ne 'C' }
    if ($others) { Add-Result 5 'OK' ("Separate data drive already exists: " + (($others | ForEach-Object { $_.DriveLetter }) -join ', ')); return }

    Add-Result 5 'WARN' 'Only drive C: exists; disk not partitioned yet'
    if (-not (Confirm-Yes "Create a separate data drive from C: now?")) { return }

    $sup = Get-PartitionSupportedSize -DriveLetter C
    $curGB = [math]::Floor($sup.SizeMax / 1GB)
    $minGB = [math]::Ceiling($sup.SizeMin / 1GB)
    Write-Host "     C: is currently $curGB GB, can shrink to about $minGB GB"
    $in = Read-Host "  How many GB should C: keep (e.g. 200)"
    [int]$cGB = 0
    if (-not [int]::TryParse($in, [ref]$cGB) -or $cGB -lt $minGB -or $cGB -ge $curGB) {
        Add-Result 5 'FAIL' "Invalid size (must be between $minGB and $curGB GB)"; return
    }
    $label = Read-Host "  New drive label (Enter = Data)"
    if (-not $label) { $label = 'Data' }
    if (-not (Confirm-Yes "Confirm: shrink C: to $cGB GB and create drive '$label' from the remaining space?")) { return }
    try {
        Resize-Partition -DriveLetter C -Size ([int64]$cGB * 1GB) -ErrorAction Stop
        $diskNum = (Get-Partition -DriveLetter C).DiskNumber
        $np = New-Partition -DiskNumber $diskNum -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        Format-Volume -Partition $np -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false | Out-Null
        Add-Result 5 'OK' ("Created drive {0}: ({1})" -f $np.DriveLetter, $label)
    } catch { Add-Result 5 'FAIL' ("Partitioning failed: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------- 6
function Step6 {
    Title "6. Access work or school"
    $ds = (dsregcmd /status) -join "`n"
    function Flag($name) { if ($ds -match "(?m)^\s*$name\s*:\s*(\w+)") { return $Matches[1] } else { return '?' } }
    $aad = Flag 'AzureAdJoined'; $dom = Flag 'DomainJoined'; $wp = Flag 'WorkplaceJoined'
    Write-Host "     AzureAdJoined=$aad  DomainJoined=$dom  WorkplaceJoined=$wp"

    $mdm = @()
    $enr = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path $enr) {
        $mdm = Get-ChildItem $enr -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.UPN -or $_.ProviderID -match 'MS DM Server|Intune' }
    }
    if ($mdm) { Write-Host ("     Device management (MDM) enrollment found: " + (($mdm | ForEach-Object { $_.UPN }) -join ', ')) }

    if ($aad -ne 'YES' -and $dom -ne 'YES' -and $wp -ne 'YES' -and -not $mdm) {
        Add-Result 6 'OK' 'No work or school connection'
        return
    }
    Add-Result 6 'WARN' 'Work or school connection found'
    if ($aad -eq 'YES') {
        Write-Host "  WARNING: This PC is joined to Azure AD. If you are signed in with a work account, leaving may lock you out." -ForegroundColor Yellow
        if (Confirm-Yes "Remove this PC from Azure AD (dsregcmd /leave)?") {
            dsregcmd /leave
            $script:NeedRestart = $true
            Add-Result 6 'WARN' 'Leave command sent; verify after restart'
        }
    }
    if (Confirm-Yes "Open Settings > Access work or school to click Disconnect manually?") { Start-Process 'ms-settings:workplace' }
}

# ---------------------------------------------------------------- 7
function Step7 {
    Title "7. BitLocker (DELL / ThinkPad only)"
    $isDell = $cs.Manufacturer -match 'Dell'
    $isThinkPad = ($cs.Manufacturer -match 'LENOVO') -and ($csp.Version -match 'ThinkPad')
    if (-not ($isDell -or $isThinkPad)) {
        Add-Result 7 'INFO' ("This is {0} {1}, not DELL/ThinkPad; skipped" -f $cs.Manufacturer, $cs.Model)
        return
    }
    try {
        $vols = Get-BitLockerVolume -ErrorAction Stop
        foreach ($v in $vols) {
            $line = "{0} Protection={1} Status={2} Encrypted={3}%" -f $v.MountPoint, $v.ProtectionStatus, $v.VolumeStatus, $v.EncryptionPercentage
            if ($v.ProtectionStatus -eq 'On' -or $v.VolumeStatus -ne 'FullyDecrypted') { Add-Result 7 'FAIL' ("BitLocker is ON / encrypting: " + $line) }
            else { Add-Result 7 'OK' ("BitLocker is OFF: " + $line) }
        }
    } catch {
        Write-Host "  Using manage-bde instead (Get-BitLockerVolume unavailable on this PC)" -ForegroundColor Gray
        manage-bde -status
        Add-Result 7 'INFO' 'See manage-bde output above'
    }
    if (Confirm-Yes "Open BitLocker Drive Encryption (Control Panel) to check visually?") {
        Start-Process control.exe -ArgumentList '/name Microsoft.BitLockerDriveEncryption'
    }
}

# ---------------------------------------------------------------- 8
function Step8 {
    Title "8. Battery health"
    $tmp = Join-Path $env:TEMP ("bat_" + [guid]::NewGuid().ToString("N") + ".xml")
    powercfg /batteryreport /xml /output $tmp *> $null
    if (-not (Test-Path $tmp)) { Add-Result 8 'FAIL' 'Could not create battery report'; return }
    [xml]$xml = Get-Content $tmp
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $b = $xml.BatteryReport.Batteries.Battery
    if ($b -is [array]) { $b = $b[0] }
    if (-not $b) { Add-Result 8 'INFO' 'No battery found (desktop PC?)'; return }

    $design = [int]$b.DesignCapacity
    $full   = [int]$b.FullChargeCapacity
    Write-Host ("     Battery: {0} / Chemistry {1}" -f $b.Id, $b.Chemistry)
    Write-Host ("     Design capacity {0} mWh / Full charge capacity {1} mWh" -f $design, $full)
    if ($design -le 0) { Add-Result 8 'WARN' 'Could not read design capacity'; return }
    $pct = [math]::Round(($full / $design) * 100, 1)

    if ($pct -lt 60) {
        Add-Result 8 'FAIL' "Battery health $pct% (below 60%) - replacement recommended"
        $model = if ($cs.Manufacturer -match 'LENOVO') { $csp.Version } else { $cs.Model }
        $q = [uri]::EscapeDataString("battery $($cs.Manufacturer) $model")
        Write-Host "     Prices and shops vary by model; this tool does not fetch prices but can open search pages." -ForegroundColor Gray
        if (Confirm-Yes "Open searches for '$($cs.Manufacturer) $model' battery (Google / Lazada / Shopee)?") {
            Start-Process "https://www.google.com/search?q=$q"
            Start-Process "https://www.lazada.co.th/catalog/?q=$q"
            Start-Process "https://shopee.co.th/search?keyword=$q"
        }
    } else {
        Add-Result 8 'OK' "Battery health $pct% (normal)"
    }
}

# ---------------------------------------------------------------- 9
function Step9 {
    Title "9. Clear usage history"
    Write-Host "  Will clear: Chrome/Edge browsing + download history, Explorer search/Run history, recent files, Recycle Bin."
    Write-Host "  Bookmarks/passwords and downloaded files are kept (unless you choose otherwise below). Cannot be undone." -ForegroundColor Yellow
    if (-not (Confirm-Yes "Clear now?")) { Add-Result 9 'INFO' 'History clearing skipped'; return }

    $procs = Get-Process chrome, msedge -ErrorAction SilentlyContinue
    if ($procs) {
        if (Confirm-Yes "Chrome/Edge must be closed first. Close them now?") { $procs | Stop-Process -Force; Start-Sleep -Seconds 2 }
        else { Write-Host "     (Files of running browsers may fail to delete)" -ForegroundColor Gray }
    }

    $roots = @("$env:LOCALAPPDATA\Google\Chrome\User Data", "$env:LOCALAPPDATA\Microsoft\Edge\User Data")
    $names = 'History', 'History-journal', 'Visited Links', 'Top Sites', 'Top Sites-journal',
             'Shortcuts', 'Shortcuts-journal', 'Network Action Predictor', 'Network Action Predictor-journal'
    $ok = 0; $fail = 0
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        Get-ChildItem $r -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
            foreach ($n in $names) {
                $f = Join-Path $_.FullName $n
                if (Test-Path $f) {
                    try { Remove-Item $f -Force -ErrorAction Stop; $ok++ } catch { $fail++ }
                }
            }
        }
    }
    if ($fail -eq 0) { Add-Result 9 'OK' "Chrome/Edge history cleared ($ok files)" }
    else { Add-Result 9 'WARN' "Cleared $ok files, $fail failed (browser may still be running)" }

    foreach ($k in 'Explorer\WordWheelQuery', 'Explorer\RunMRU', 'Explorer\TypedPaths') {
        Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\$k" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Recurse -Force -ErrorAction SilentlyContinue
    Add-Result 9 'OK' 'Explorer search / Run history and recent files cleared'

    try { Clear-RecycleBin -Force -ErrorAction Stop; Add-Result 9 'OK' 'Recycle Bin emptied' }
    catch { Add-Result 9 'INFO' 'Recycle Bin already empty or could not be emptied' }

    $dlDir = Join-Path $env:USERPROFILE 'Downloads'
    $cnt = (Get-ChildItem $dlDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($cnt -gt 0 -and (Confirm-Yes "Also DELETE all files in the Downloads folder ($cnt items)? (default is N)")) {
        Get-ChildItem $dlDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Add-Result 9 'OK' 'Downloads folder emptied'
    }

    Write-Host "  Windows taskbar search history must be cleared in Settings (Search permissions > Clear device search history)." -ForegroundColor Gray
    if (Confirm-Yes "Open that Settings page?") { try { Start-Process 'ms-settings:search-permissions' } catch { } }
    Write-Host "  Note: Firefox is not cleared (bookmarks share the same file as history)." -ForegroundColor Gray
}

# ---------------------------------------------------------------- main
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Clear-Host
Write-Host "Post-Recovery Checklist" -ForegroundColor Cyan
Write-Host ("PC: {0} / {1} {2} / S/N {3}" -f $env:COMPUTERNAME, $cs.Manufacturer, $cs.Model, $bios.SerialNumber)
if (-not $isAdmin) { Write-Host "WARNING: Not running as Administrator. Some steps will not work." -ForegroundColor Yellow }
Write-Host @"

  1  Windows Update / Intel Driver Support
  2  Basic software (Chrome, Microsoft 365, Adobe PDF)
  3  Camera / Speaker / Time / Keyboard language
  4  Set device name to barcode
  5  Partition the drive
  6  Remove Access work or school
  7  Check BitLocker (DELL / ThinkPad)
  8  Check battery health
  9  Clear history
"@
if (-not $Steps) {
    $in = Read-Host "Select steps (Enter = run all, or type e.g. 1,3,8)"
    if ($in) { $Steps = $in -split '[,\s]+' | Where-Object { $_ -match '^[1-9]$' } | ForEach-Object { [int]$_ } }
    else { $Steps = 1..9 }
}
foreach ($s in $Steps) {
    try { & "Step$s" } catch { Add-Result $s 'FAIL' $_.Exception.Message }
}

# ---------------------------------------------------------------- summary
Title "Summary"
$script:Results | ForEach-Object {
    $color = switch ($_.Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ("  Step {0} [{1}] {2}" -f $_.Step, $_.Status, $_.Detail) -ForegroundColor $color
}
try {
    $inv  = [Globalization.CultureInfo]::InvariantCulture
    $now  = Get-Date
    $dir  = if ($PSScriptRoot) { $PSScriptRoot } else { $env:TEMP }
    $file = Join-Path $dir ("PostRecovery_Report_{0}_{1}.txt" -f $env:COMPUTERNAME, $now.ToString('yyyy-MM-dd_HH-mm', $inv))

    $lines = @()
    $lines += "Post-Recovery Report"
    $lines += ("Date/Time : " + $now.ToString('dd MMM yyyy, HH:mm:ss', $inv))
    $lines += ("PC        : {0} ({1} {2}, S/N {3})" -f $env:COMPUTERNAME, $cs.Manufacturer, $cs.Model, $bios.SerialNumber)
    $lines += "----------------------------------------"
    $lines += ($script:Results | ForEach-Object { "Step {0} [{1}] {2}" -f $_.Step, $_.Status, $_.Detail })

    $lines | Out-File -FilePath $file -Encoding UTF8
    Write-Host ""; Write-Host "Report saved to: $file" -ForegroundColor Gray
} catch { }

if ($script:NeedRestart -and (Confirm-Yes "Changes require a restart. Restart now?")) { Restart-Computer -Force }
