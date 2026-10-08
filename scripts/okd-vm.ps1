<#
  Host-side wrapper used by the Vagrantfile triggers (you can also run it by hand).
  Finds the helper on the VMnet8 network, downloads the create-okd-vm.ps1 that
  Ansible generated there, and runs it. A copy is kept in .okd\ so -Destroy
  still works after the helper is gone.

    .\scripts\okd-vm.ps1            # create (or start) the OKD VM
    .\scripts\okd-vm.ps1 -Destroy   # delete the OKD VM and its hosts entries
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$Destroy,
    [int]$HelperOctet = 10,   # must match helper_ip in inventory/group_vars/all.yml
    [int]$Port = 8080         # must match http_port
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$CacheDir = Join-Path (Split-Path $PSScriptRoot -Parent) '.okd'
$Script   = Join-Path $CacheDir 'create-okd-vm.ps1'
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

if ($Destroy) {
    if (Test-Path $Script) {
        & $Script -Destroy
    } else {
        Write-Host 'No saved create-okd-vm.ps1 found, so there is no OKD VM to remove.'
    }
    return
}

$vmnet8 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.InterfaceAlias -like '*VMnet8*' } |
          Select-Object -First 1
if (-not $vmnet8) {
    throw 'No "VMware Network Adapter VMnet8" found. Enable NAT (VMnet8) in the Virtual Network Editor.'
}

$Subnet = ($vmnet8.IPAddress -split '\.')[0..2] -join '.'
$Url    = "http://$Subnet.${HelperOctet}:${Port}/okd/create-okd-vm.ps1"

Write-Host "Fetching $Url"
Invoke-WebRequest -Uri $Url -OutFile $Script -UseBasicParsing
& $Script
