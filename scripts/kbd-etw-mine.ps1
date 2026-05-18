$out = "C:\mm-dev-queue\kbd-etw-mine.txt"
"=== ETW + EVENT LOG MINE for MagicKbDesc / Apple kb $(Get-Date) ===" | Set-Content $out -Encoding UTF8
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
"Boot: $boot" | Add-Content $out
$kbId = 'BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205ac_PID&0239\9&73b8b28&0&E806884B0741_C00000000'

"" | Add-Content $out
"=== 1. Kernel-PnP/Configuration since boot (filter chain build) ===" | Add-Content $out
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Kernel-PnP/Configuration'; StartTime=$boot} -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'MagicKbDesc|BTHENUM.*0239|HidBth|magickbdesc|0X0000003D|filter' } |
    Select-Object -First 60 TimeCreated, Id, LevelDisplayName, @{n='Msg';e={$_.Message.Substring(0,[Math]::Min(400,$_.Message.Length))}} |
    Format-List | Out-String | Add-Content $out

"" | Add-Content $out
"=== 2. Kernel-PnP/Device Configuration since boot ===" | Add-Content $out
Get-WinEvent -LogName 'Microsoft-Windows-Kernel-PnP/Device Configuration' -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -gt $boot -and $_.Message -match 'MagicKbDesc|BTHENUM.*0239|HidBth|magickbdesc|filter' } |
    Select-Object -First 60 TimeCreated, Id, LevelDisplayName, @{n='Msg';e={$_.Message.Substring(0,[Math]::Min(400,$_.Message.Length))}} |
    Format-List | Out-String | Add-Content $out

"" | Add-Content $out
"=== 3. KMDF DriverFrameworks-UserMode/Operational ===" | Add-Content $out
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -gt $boot -and $_.Message -match 'MagicKbDesc' } |
    Select-Object -First 30 TimeCreated, Id, LevelDisplayName, @{n='Msg';e={$_.Message.Substring(0,[Math]::Min(400,$_.Message.Length))}} |
    Format-List | Out-String | Add-Content $out

"" | Add-Content $out
"=== 4. System Service Control Manager events for MagicKbDesc since boot ===" | Add-Content $out
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$boot; ProviderName='Service Control Manager'} -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'MagicKbDesc|HidBth' } |
    Select-Object -First 30 TimeCreated, Id, LevelDisplayName, @{n='Msg';e={$_.Message.Substring(0,[Math]::Min(400,$_.Message.Length))}} |
    Format-List | Out-String | Add-Content $out

"" | Add-Content $out
"=== 5. setupapi.dev.log entries since boot mentioning kbd/MagicKbDesc ===" | Add-Content $out
$bootDate = $boot.ToString('yyyy/MM/dd')
Get-Content 'C:\Windows\inf\setupapi.dev.log' -ErrorAction SilentlyContinue |
    Select-String -Pattern "$bootDate|MagicKbDesc|magickbdesc|BTHENUM.*0239|VID&000205ac" |
    Select-Object -Last 100 | ForEach-Object { $_.Line } |
    Add-Content $out

"" | Add-Content $out
"=== 6. Listed providers known to track HID/BT (presence check, not query) ===" | Add-Content $out
foreach ($p in 'Microsoft-Windows-HID-Class','Microsoft-Windows-Kernel-Debug-Print','Microsoft-Windows-Kernel-PnP','Microsoft-Windows-DriverFrameworks-KernelMode/Operational','Microsoft-Windows-DriverFrameworks-UserMode/Operational') {
    $exists = Get-WinEvent -ListLog $p -ErrorAction SilentlyContinue
    if ($exists) {
        "  PRESENT: $p (records=$($exists.RecordCount), enabled=$($exists.IsEnabled))" | Add-Content $out
    } else {
        "  ABSENT/NOT-LOGGED: $p" | Add-Content $out
    }
}

"" | Add-Content $out
"=== DONE - file: $out ===" | Add-Content $out
