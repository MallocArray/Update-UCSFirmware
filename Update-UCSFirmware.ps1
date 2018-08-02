# Script to update ESXi host UCS firmware in a rolling fashion inside of a vSphere cluster.
#
# Assumptions:
#    1. You have assigned the new firmware package to the service profile template defined in the variable below. 
#    2. The service profile template is an "initial" template, and not an "updating" template.
#    3. You have already connected to the appropriate vSphere server and UCS environment in PowerShell/PowerCLI.
#
# Author: Tim Patterson <tim@pc-professionals.net>
# Last Updated: 2014-02-03
# 
# Adapted from Cisco example found here: https://communities.cisco.com/docs/DOC-36050
 
[CmdletBinding()]
Param(
	[Parameter(Mandatory=$True, HelpMessage="ESXi Cluster to Update")]
	[string]$ESXiCluster,
 
	[Parameter(Mandatory=$True, HelpMessage="ESXi Host(s) in cluster to update. Specify * for all hosts.")]
	[string]$ESXiHost,
 
	[Parameter(Mandatory=$True, HelpMessage="UCS Service Profile Template Name")]
	[string]$SPTemplate
)
 
Write-Host "Starting process at $(date)"
Write-Host "Working on ESXi Cluster: $ESXiCluster"
Write-Host "Using service profile template: $SPTemplate"
 
try {
	Foreach ($VMHost in (Get-Cluster $ESXiCluster | Get-VMHost | Where { $_.Name -like "$ESXiHost" } )) {
		Write-Host "vC: Placing ESXi Host: $($VMHost.Name) into maintenance mode"
		$Maint = $VMHost | Set-VMHost -State Maintenance -Evacuate
 
		Write-Host "vC: Waiting for ESXi Host: $($VMHost.Name) to enter Maintenance Mode"
		do {
			Sleep 10
		} until ((Get-VMHost $VMHost).State -eq "Maintenance")
 
		Write-Host "vC: ESXi Host: $($VMHost.Name) now in Maintenance Mode, shutting down Host"
		$Shutdown = $VMHost.ExtensionData.ShutdownHost($true)
 
		Write-Host "UCS: Correlating ESXi Host: $($VMHost.Name) to running UCS Service Profile (SP)"
 
		$vmMacAddr = $VMhost.NetworkInfo.PhysicalNic | where { $_.name -ieq "vmnic0" }
 
		$sp2upgrade =  Get-UcsServiceProfile | Get-UcsVnic -Name eth0 |  where { $_.addr -ieq  $vmMacAddr.Mac } | Get-UcsParent 
 
		Write-Host "UCS: ESXi Host: $($VMhost.Name) is running on UCS SP: $($sp2upgrade.name)"
		Write-Host "UCS: Waiting for UCS SP: $($sp2upgrade.name) to gracefully power down"
	 	do {
			if ( (get-ucsmanagedobject -dn $sp2upgrade.PnDn).OperPower -eq "off")
			{
				break
			}
			Sleep 60
		} until ((get-ucsmanagedobject -dn $sp2upgrade.PnDn).OperPower -eq "off" )
		Write-Host "UCS: UCS SP: $($sp2upgrade.name) powered down"
 
		Write-Host "UCS: Setting desired power state for UCS SP: $($sp2upgrade.name) to down"
		$poweron = $sp2upgrade | Set-UcsServerPower -State "down" -Force | Out-Null
 
		# Unbind / Bind to SP template, as this will force FW update action:
		$sp2upgrade | Set-UcsServiceProfile -srctemplname '' -force
		$sp2upgrade | Set-UcsServiceProfile -srctemplname "$SPTemplate" -force
 
		Write-Host "UCS: Acknowledging any User Maintenance Actions for UCS SP: $($sp2upgrade.name)"
		if (($sp2upgrade | Get-UcsLsmaintAck| measure).Count -ge 1)
			{
				$ackuserack = $sp2upgrade | get-ucslsmaintack | Set-UcsLsmaintAck -AdminState "trigger-immediate" -Force
			}
 
		Write-Host "UCS: Waiting for UCS SP: $($sp2upgrade.name) to complete firmware update process..."
		do {
			Sleep 40
		} until ((Get-UcsManagedObject -Dn $sp2upgrade.Dn).AssocState -ieq "associated")
 
		Write-Host "UCS: Host Firmware Pack update process complete.  Setting desired power state for UCS SP: $($sp2upgrade.name) to 'up'"
		$poweron = $sp2upgrade | Set-UcsServerPower -State "up" -Force | Out-Null
 
		Write "vC: Waiting for ESXi: $($VMHost.Name) to connect to vCenter"
		do {
			Sleep 40
		} until (($VMHost = Get-VMHost $VMHost).ConnectionState -eq "Connected" )
	}
}
Catch 
{
	 Write-Host "Error occurred in script:"
	 Write-Host ${Error}
	 Write-Host "Finished process at $(date)"
         exit
}
Write-Host "Finished process at $(date)"