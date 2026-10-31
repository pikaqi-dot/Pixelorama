# Makes the LAN sync reachable from the phone.
#
# Two things have to be true for the app to connect: the sync ports must be
# allowed in, and no block rule for the editor executable may sit in front of
# them. A block rule wins over an allow rule, so adding the allow rule alone
# changes nothing — that is why this script deletes first and allows second.
#
# Run it from the .bat next to it (it asks for elevation) or with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File fix-lan-sync-firewall.ps1

$ErrorActionPreference = 'Continue'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'This needs administrator rights. Start it through fix-lan-sync-firewall.bat.'
    exit 1
}

Write-Host '--- firewall profile ---'
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction | Format-Table -AutoSize

Write-Host '--- block rules for the editor / app ---'
$blocks = Get-NetFirewallRule -Direction Inbound -Action Block -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'godot|pixelorama' }
if ($blocks) {
    $names = ($blocks | ForEach-Object { $_.DisplayName }) -join ', '
    Write-Host "deleting: $names"
    $blocks | Remove-NetFirewallRule
} else {
    Write-Host 'none found'
}

Write-Host '--- allow rules for the sync ports ---'
$rules = @(
    @{ Name = 'Pixelorama LAN Sync TCP'; Protocol = 'TCP'; Port = '45990-45997' },
    @{ Name = 'Pixelorama LAN Sync UDP'; Protocol = 'UDP'; Port = '45999' }
)
foreach ($rule in $rules) {
    Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow `
        -Protocol $rule.Protocol -LocalPort $rule.Port -Profile Any | Out-Null
    Write-Host ("allowed inbound {0} {1}" -f $rule.Protocol, $rule.Port)
}

Write-Host '--- result ---'
Get-NetFirewallPortFilter |
    Where-Object { $_.LocalPort -eq '45999' -or $_.LocalPort -eq '45990-45997' } |
    ForEach-Object {
        $rule = $_ | Get-NetFirewallRule
        Write-Host ("{0} {1} {2} -> {3}" -f $rule.DisplayName, $rule.Direction, $rule.Action, $_.LocalPort)
    }
Write-Host 'Done. Restart the editor sync (stop, then start) and scan again.'
