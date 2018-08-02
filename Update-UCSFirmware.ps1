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
 
	[Parameter(Mandatory=$True, HelpMessage="UCS Host Firmware Package Name")]
	[string]$DestFirmwarePackage
)
 
Write-Host "Starting process at $(date)"
Write-Host "Working on ESXi Cluster: $ESXiCluster"
Write-Host "Using Host Firmware Package: $DestFirmwarePackage"
 
try {
	Foreach ($VMHost in (Get-Cluster $ESXiCluster | Get-VMHost | Where { $_.Name -like "$ESXiHost" } )) {
		
        Write-Host "UCS: Correlating ESXi Host: $($VMHost.Name) to running UCS Service Profile (SP)"
 	    $MacAddr = Get-VMHostNetworkAdapter -vmhost $vmhost -Physical | where {$_.BitRatePerSec -gt 0} | select -first 1 #Select first connected physical NIC
        $ServiceProfileToUpdate =  Get-UcsServiceProfile | Get-UcsVnic |  where { $_.addr -ieq  $MacAddr.Mac } | Get-UcsParent
	    # Find the physical hardware the service profile is running on:
	    $UCSHardware = $ServiceProfile.PnDn
        
        #Validating environment
        if ($ServiceProfileToUpdate -eq $null) {
            write-host $VMhost "was not found in UCS.  Skipping host"
            Continue
        }
        if ((Get-UcsFirmwareComputeHostPack | where {$_.ucs -eq $ServiceProfileToUpdate.Ucs -and $_.name -eq $DestFirmwarePackage }).count -ne 1) {
            write-host "Firmware Package" $DestFirmwarePackage "not found on" $ServiceProfileToUpdate.Ucs "for server" $vmhost.name
            Continue
        }
        if ($ServiceProfileToUpdate.HostFwPolicyName -eq $DestFirmwarePackage) {
            Write-Host $ServiceProfileToUpdate.name "is already running firmware" $DestFirmwarePackage
            Continue
        }

		Write-Host "vC: Placing ESXi Host: $($VMHost.Name) into maintenance mode"
		#$Maint = $VMHost | Set-VMHost -State Maintenance -Evacuate
 
		Write-Host "vC: Waiting for ESXi Host: $($VMHost.Name) to enter Maintenance Mode"
		do {
			Sleep 10
		} until ((Get-VMHost $VMHost).State -eq "Maintenance")
 
#Will add ability to install a VIB or Update Manager baseline here to install new drivers prior to shutdown

		Write-Host "vC: ESXi Host: $($VMHost.Name) now in Maintenance Mode, shutting down Host"
		#$Shutdown = $VMHost.ExtensionData.ShutdownHost($true)
 


 
		Write-Host "UCS: ESXi Host: $($VMhost.Name) is running on UCS SP: $($ServiceProfileToUpdate.name)"
		Write-Host "UCS: Waiting for UCS SP: $($ServiceProfileToUpdate.name) to gracefully power down"
	 	do {
			if ( (get-ucsmanagedobject -dn $ServiceProfileToUpdate.PnDn -ucs $ServiceProfile.Ucs).OperPower -eq "off")
			{
				break
			}
			Sleep 60
		} until ((get-ucsmanagedobject -dn $ServiceProfileToUpdate.PnDn -ucs $ServiceProfile.Ucs).OperPower -eq "off" )
		Write-Host "UCS: UCS SP: $($ServiceProfileToUpdate.name) powered down"
 
		Write-Host "UCS: Setting desired power state for UCS SP: $($ServiceProfileToUpdate.name) to down"
		#$poweron = $ServiceProfileToUpdate | Set-UcsServerPower -State "down" -Force | Out-Null
 
		# Unbind / Bind to SP template, as this will force FW update action:
		#$ServiceProfileToUpdate | Set-UcsServiceProfile -srctemplname '' -force
		#$ServiceProfileToUpdate | Set-UcsServiceProfile -srctemplname "$DestFirmwarePackage" -force
 
		Write-Host "UCS: Acknowledging any User Maintenance Actions for UCS SP: $($ServiceProfileToUpdate.name)"
		if (($ServiceProfileToUpdate | Get-UcsLsmaintAck| measure).Count -ge 1)
			{
				#$ackuserack = $ServiceProfileToUpdate | get-ucslsmaintack | Set-UcsLsmaintAck -AdminState "trigger-immediate" -Force
			}
 
		Write-Host "UCS: Waiting for UCS SP: $($ServiceProfileToUpdate.name) to complete firmware update process..."
		do {
			Sleep 40
		} until ((Get-UcsManagedObject -Dn $ServiceProfileToUpdate.Dn -ucs $ServiceProfile.Ucs).AssocState -ieq "associated")
 
		Write-Host "UCS: Host Firmware Pack update process complete.  Setting desired power state for UCS SP: $($ServiceProfileToUpdate.name) to 'up'"
		#$poweron = $ServiceProfileToUpdate | Set-UcsServerPower -State "up" -Force | Out-Null
 
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