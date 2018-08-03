#requires -version 2
<#
.SYNOPSIS
  Script to update Cisco UCS Firmware on VMware based blades in a rolling update manner, by VMware cluster
.DESCRIPTION
  User provides vSphere cluster, hostname pattern, and UCS Host Firmware Policy name.
  The script will sequentially check if each host is running the requested firmware.
  If not running the desired firmware, the host will be put into maintenance, shut down,
  UCS firmware update applied, and then powered on and taken out of maintenance mode
  This repeats until all hosts in the cluster have been updated.
.PARAMETER <Parameter_Name>
    <Brief description of parameter input required. Repeat this attribute if required>
.INPUTS
  Script assumes the user has previously installed the VMware PowerCLI and Cisco PowerTool modules into Powershell
    # VMware PowerCLI install
    # Install-Module VMware.PowerCLI

    # UCS PowerTool install
    # Install-Module Cisco.UCSManager
  Also assumes a connection to vSphere and UCS has already been created using the modules
    $vcenters = @("vcenter.domain.local","vcenter2.domain.local)
    Connect-VIServer $vcenters -AllLinked
    
    $UCSManagers= @("192.168.0.1","UCS1.domain.local")
    Import-Module Cisco.UCSManager
    Set-UcsPowerToolConfiguration -supportmultipledefaultucs $true 
    connect-ucs $UCSManagers -Credential $UCSAccount
.OUTPUTS
  None
.NOTES
  Version:        1.2
  Author:         Joshua Post
  Creation Date:  8/2/2018
  Purpose/Change: Modification of other base scripts to support multiple UCS connections and Update Manager to install drivers associated with firmware update
  Based on http://timsvirtualworld.com/2014/02/automate-ucs-esxi-host-firmware-updates-with-powerclipowertool/
  Adapted from Cisco example found here: https://communities.cisco.com/docs/DOC-36050
.EXAMPLE
  Run script, being prompted for all input, but no updates installed
  .\Update-UCSFirmware.ps1
  Run script, providing all needed input including baseline to install updates
  .\Update-UCSFirmware.ps1 -ESXiCluster "Cluster1" -ESXiHost "*" -FirmwarePackage "3.2(3d)" -baseline "3.2(3d) Drivers"
  Run script, being prompted for baselines to install updates
  .\Update-UCSFirmware.ps1 -PromptBaseline
#>


[CmdletBinding()]
Param(
	[Parameter(Mandatory=$False, HelpMessage="ESXi Cluster to Update")]
	[string]$ESXiCluster,
 
	[Parameter(Mandatory=$False, HelpMessage="ESXi Host(s) in cluster to update. Specify * for all hosts or as a wildcard")]
	[string]$ESXiHost,
    
    [Parameter(Mandatory=$False, HelpMessage="Switch to enable prompting of available Update Manager baselines. Do not use with -baseline")]
    [switch]$PromptBaseline,

    [Parameter(Mandatory=$False, HelpMessage="Name of Update Manager baseline to apply")]
    [string]$Baseline,

	[Parameter(Mandatory=$False, HelpMessage="UCS Host Firmware Package Name")]
	[string]$FirmwarePackage
)


########################################
# Listing Available options if not supplied
########################################
if ($ESXiCluster -eq "") {
    $x=1
    $ClusterList = Get-Cluster | sort name
    Write-Host "`nAvailable Clusters to update"
    $ClusterList | %{Write-Host $x":" $_.name ; $x++}
    $x = Read-Host "Enter the number of the package for the update"
    $ESXiClusterObject = Get-Cluster $ClusterList[$x-1]
}Else {
    $ESXiClusterObject = Get-Cluster $ESXiCluster
}

if ($ESXiHost -eq "") {
    Write-Host "`nEnter name of ESXi Host to update. `nSpecify a FQDN, * for all hosts in cluster, or a wildcard such as Server1*"
    $ESXiHost = Read-Host "ESXi Host"
}

if ($PromptBaseline) {
    $x=1
    $BaselineList = $ESXiClusterObject | get-vmhost | Get-Baseline -Inherit | sort LastUpdateTime -descending
    Write-Host "`nAvailable Update Manager Baselines"
    $BaselineList | %{Write-Host $x":" $_.name ; $x++}
    $x = Read-Host "Enter the number of the Baseline"
    $Baseline = $BaselineList[$x-1]
} 
if ($PromptBaseline-eq $False -and $Baseline -ne "") {
    $Baseline = Get-Baseline $Baseline
}#>


If ($FirmwarePackage -eq "") {
    $x=1
    $FirmwarePackageList = Get-UcsFirmwareComputeHostPack | select name -unique | sort name
    Write-Host "`nHost Firmware Packages available on connected UCS systems"
    $FirmwarePackageList | %{Write-Host $x":" $_.name ; $x++}
    $x = Read-Host "Enter the number of the package for the update"
    $FirmwarePackage = $FirmwarePackageList[$x-1].name
} 

 
Write-Host "`nStarting process at $(date)"
Write-Host "Working on ESXi Cluster: $($ESXiClusterObject.name)"
Write-Host "Using Host Firmware Package: $FirmwarePackage"
 

try {
	Foreach ($VMHost in ($ESXiClusterObject | Get-VMHost | Where { $_.Name -like "$ESXiHost" } | sort name )) {
		# Clearing Variables to be safe
        $MacAddr=$ServiceProfiletoUpdate=$UCShardware=$Maint=$Shutdown=$poweron=$ackuserack=$null
        
        Write-Host "Processing $($VMHost.name)"
        Write-Host "UCS: Correlating ESXi Host: $($VMHost.Name) to running UCS Service Profile (SP)"
 	    $MacAddr = Get-VMHostNetworkAdapter -vmhost $vmhost -Physical | where {$_.BitRatePerSec -gt 0} | select -first 1 #Select first connected physical NIC
        $ServiceProfileToUpdate =  Get-UcsServiceProfile | Get-UcsVnic |  where { $_.addr -ieq  $MacAddr.Mac } | Get-UcsParent
	    # Find the physical hardware the service profile is running on:
	    $UCSHardware = $ServiceProfileToUpdate.PnDn
        
        #Validating environment
        if ($ServiceProfileToUpdate -eq $null) {
            write-host $VMhost "was not found in UCS.  Skipping host"
            Continue
        }
        if ((Get-UcsFirmwareComputeHostPack | where {$_.ucs -eq $ServiceProfileToUpdate.Ucs -and $_.name -eq $FirmwarePackage }).count -ne 1) {
            write-host "Firmware Package" $FirmwarePackage "not found on" $ServiceProfileToUpdate.Ucs "for server" $vmhost.name
            Continue
        }
        if ($ServiceProfileToUpdate.HostFwPolicyName -eq $FirmwarePackage) {
            Write-Host $ServiceProfileToUpdate.name "is already running firmware" $FirmwarePackage
            Continue
        }

		Write-Host "vC: Placing ESXi Host: $($VMHost.Name) into maintenance mode"
		#$Maint = $VMHost | Set-VMHost -State Maintenance -Evacuate
 
 <#
		Write-Host "vC: Waiting for ESXi Host: $($VMHost.Name) to enter Maintenance Mode"
		do {
			Sleep 10
		} until ((Get-VMHost $VMHost).ConnectionState -eq "Maintenance")
#>
        Write-Host "vC: ESXi Host: $($VMHost.Name) now in Maintenance Mode"


        if ($Baseline -ne "") {
            Write-Host "VC: Installing Updates on host $($VMhost.name)"
            Test-compliance -entity $vmhost -whatif
            #Remediate-Inventory -baseline $Baseline -entity $vmhost -whatif
        }

		Write-Host "vC: ESXi Host: $($VMHost.Name) is now being shut down"
		#$Shutdown = $VMHost.ExtensionData.ShutdownHost($true)
 


 
		Write-Host "UCS: ESXi Host: $($VMhost.Name) is running on UCS SP: $($ServiceProfileToUpdate.name)"
		Write-Host "UCS: Waiting for UCS SP: $($ServiceProfileToUpdate.name) to gracefully power down"
<#	 	do {
			if ( (get-ucsmanagedobject -dn $ServiceProfileToUpdate.PnDn -ucs $ServiceProfileToUpdate.Ucs).OperPower -eq "off")
			{
				break
			}
			Sleep 60
		} until ((get-ucsmanagedobject -dn $ServiceProfileToUpdate.PnDn -ucs $ServiceProfileToUpdate.Ucs).OperPower -eq "off" )
#>		Write-Host "UCS: UCS SP: $($ServiceProfileToUpdate.name) powered down"
 
		Write-Host "UCS: Setting desired power state for UCS SP: $($ServiceProfileToUpdate.name) to down"
		#$poweron = $ServiceProfileToUpdate | Set-UcsServerPower -State "down" -Force | Out-Null
 

		Write-Host "UCS: Changing Host Firmware pack policy for UCS SP: $($ServiceProfileToUpdate.name) to '$($FirmwarePackage)'"
		#$updatehfp = $ServiceProfileToUpdate | Set-UcsServiceProfile -HostFwPolicyName (Get-UcsFirmwareComputeHostPack -Name $ServiceProfileToUpdate. -Ucs $ServiceProfileToUpdate.Ucs).Name -Force
 
		Write-Host "UCS: Acknowledging any User Maintenance Actions for UCS SP: $($ServiceProfileToUpdate.name)"
		if (($ServiceProfileToUpdate | Get-UcsLsmaintAck| measure).Count -ge 1)
			{
				#$ackuserack = $ServiceProfileToUpdate | get-ucslsmaintack | Set-UcsLsmaintAck -AdminState "trigger-immediate" -Force
			}
 
		Write-Host "UCS: Waiting for UCS SP: $($ServiceProfileToUpdate.name) to complete firmware update process..."
<#		do {
			Sleep 40
		} until ((Get-UcsManagedObject -Dn $ServiceProfileToUpdate.Dn -ucs $ServiceProfileToUpdate.Ucs).AssocState -ieq "associated")
 #>
		Write-Host "UCS: Host Firmware Pack update process complete.  Setting desired power state for UCS SP: $($ServiceProfileToUpdate.name) to 'up'"
		#$poweron = $ServiceProfileToUpdate | Set-UcsServerPower -State "up" -Force | Out-Null
 
		Write "vC: Waiting for ESXi: $($VMHost.Name) to connect to vCenter"
<#		do {
			Sleep 40
		} until (($VMHost = Get-VMHost $VMHost).ConnectionState -ne "NotResponding" ) 
#>        Write-host "VC: Exiting maintenance mode"
        #$VMHost | Set-VMHost -State Connected 
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