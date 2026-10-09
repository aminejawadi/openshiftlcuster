<#
  Host-side wrapper used by the Vagrantfile triggers (you can also run it by hand).
  Finds the helper, downloads the create-okd-vm.ps1 that Ansible generated there
  (for VirtualBox or VMware, whichever the helper runs on), and runs it.
  A copy is kept in .okd\ so -Destroy still works after the helper is gone.

  It needs administrator rights (to edit the Windows hosts file). Started from a
  normal terminal (e.g. Git Bash), it asks for them with a Windows prompt and
  shows the elevated run's output afterwards.

    .\scripts\okd-vm.ps1                          # create (or start) the OKD VM
    .\scripts\okd-vm.ps1 -Destroy                 # delete the OKD VM and its hosts entries
    .\scripts\okd-vm.ps1 -HelperIp 192.168.56.10  # skip auto-detection
#>
[CmdletBinding()]
param(
    [switch]$Destroy,
    [string]$HelperIp,
    [int]$HelperOctet = 10,   # must match helper_ip in inventory/group_vars/all.yml
    [int]$Port = 8080,        # must match http_port
    [string]$LogFile          # internal: set when this script re-launches itself elevated
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$CacheDir = Join-Path (Split-Path $PSScriptRoot -Parent) '.okd'
$Script   = Join-Path $CacheDir 'create-okd-vm.ps1'
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

function Test-Admin {
    # PowerShell 7 on Linux/macOS: nothing to elevate.
    if ($null -ne $IsWindows -and -not $IsWindows) { return $true }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
    $log = Join-Path $CacheDir 'okd-vm.log'
    Remove-Item -Path $log -Force -ErrorAction SilentlyContinue
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                 '-File', "`"$PSCommandPath`"", '-LogFile', "`"$log`"",
                 '-HelperOctet', $HelperOctet, '-Port', $Port)
    if ($Destroy)  { $argList += '-Destroy' }
    if ($HelperIp) { $argList += @('-HelperIp', $HelperIp) }

    Write-Host 'Administrator rights are needed to edit the Windows hosts file.'
    Write-Host 'Approve the Windows prompt; the work runs in a separate window.'
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait -PassThru
    } catch {
        throw ("Administrator rights were refused. Approve the prompt, or run this from " +
               "PowerShell opened with 'Run as administrator'.")
    }
    if (Test-Path $log) { Get-Content -Path $log | ForEach-Object { Write-Host $_ } }
    exit $proc.ExitCode
}

function Invoke-Main {
    if ($Destroy) {
        if (Test-Path $Script) {
            & $Script -Destroy
        } else {
            Write-Host 'No saved create-okd-vm.ps1 found, so there is no OKD VM to remove.'
        }
        return
    }

    # Candidate helper addresses: <subnet>.10 on every VirtualBox host-only and
    # VMware VMnet adapter on this PC, then the VirtualBox default. The first one
    # that serves the script wins. Match on the adapter *description* as well as
    # the name: Windows often names a VirtualBox adapter just "Ethernet 3".
    if ($HelperIp) {
        $candidates = @($HelperIp)
    } else {
        $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object {
                $_.InterfaceDescription -like '*VirtualBox*' -or $_.Name -like '*VirtualBox*' -or
                $_.InterfaceDescription -like '*VMware*'     -or $_.Name -like '*VMnet*'
            })
        $fromAdapters = @($adapters | ForEach-Object {
                Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            } | ForEach-Object { (($_.IPAddress -split '\.')[0..2] -join '.') + ".$HelperOctet" })
        $candidates = @($fromAdapters + "192.168.56.$HelperOctet" | Select-Object -Unique)
    }

    $found = $null
    foreach ($ip in $candidates) {
        $url = "http://${ip}:${Port}/okd/create-okd-vm.ps1"
        try {
            Invoke-WebRequest -Uri $url -OutFile $Script -UseBasicParsing -TimeoutSec 5
            $found = $url
            break
        } catch {
            Write-Verbose "No helper at $url"
        }
    }
    if (-not $found) {
        throw ("The helper did not answer on any of: $($candidates -join ', ') (port $Port). " +
               "Is it running, and did 'vagrant provision' finish without errors?")
    }

    Write-Host "Using $found"
    & $Script
}

# Nothing to delete: don't ask for administrator rights just to say so.
if ($Destroy -and -not (Test-Path $Script)) {
    Write-Host 'No saved create-okd-vm.ps1 found, so there is no OKD VM to remove.'
    exit 0
}

if (-not (Test-Admin)) { Invoke-Elevated }

if ($LogFile) { Start-Transcript -Path $LogFile -Force | Out-Null }
$exitCode = 0
try {
    Invoke-Main
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    $exitCode = 1
} finally {
    if ($LogFile) { Stop-Transcript | Out-Null }
}
exit $exitCode
