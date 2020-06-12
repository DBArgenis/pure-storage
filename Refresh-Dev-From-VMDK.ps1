# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your passwords in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!

# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your passwords in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!

$StartTime = Get-Date

Import-Module VMware.VimAutomation.Core 3>$null
Import-Module PureStoragePowerShellSDK 3>$null

$TargetVM = 'VM02'
$DatabaseName = 'FT_Demo'
$VIServerName = '192.168.0.2'
$VMHostname = '192.168.0.1'
$Username = 'administrator@test.lab'
$Password = 'P@ssword99!'
$TargetVMDiskNumber = 1
$SourceDatastoreName = 'vmfs01'
$VMDKPath = 'vm01/vm01_1.vmdk'
$ArrayName = '10.21.58.23'
$ArrayUsername = 'pureuser'
$ArrayPassword = 'pureuser'
$SourceVolumeName = 'esx-vmfs01'
$TargetVolumeName = 'esx-vmfs01-clone-vm03-FT_Demo'

# Create a Powershell session against the target VM
$TargetVMSession = New-PSSession -ComputerName $TargetVM

Write-Host -ForegroundColor Green "Importing SQLPS module on target VM..." 

Import-Module SQLPS -PSSession $TargetVMSession -DisableNameChecking

# Connect to vSphere vCenter server
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false  # I'm ignoring certificate errors - this you probably won't want to ignore.

Write-Host -ForegroundColor Green "Connecting to vCenter..." 

$VIServer = Connect-VIServer -Server $VIServerName -Protocol https -User $Username -Password $Password 

# Offline the target database
$ScriptBlock = [ScriptBlock]::Create("Invoke-Sqlcmd -ServerInstance . -Database master -Query `"ALTER DATABASE $DatabaseName SET OFFLINE WITH ROLLBACK IMMEDIATE`"")

Write-Host -ForegroundColor Green "Offlining target database..." 

Invoke-Command -Session $TargetVMSession -ScriptBlock $ScriptBlock

# Offline the guest target volume
Write-Host -ForegroundColor Green "Offlining target VM volume..." 

$ScriptBlock = [ScriptBlock]::Create('Get-Disk | ? { $_.Number -eq ' +  $TargetVMDiskNumber + ' } | Set-Disk -IsOffline $True')

Invoke-Command -Session $TargetVMSession -ScriptBlock $ScriptBlock

# Remove the VMDK from the VM
$VM = Get-VM -Server $VIServer -Name $TargetVM

$harddisk = Get-HardDisk -VM $VM | ? { $_.FileName -match $VMDKPath } 

Write-Host -ForegroundColor Green "Removing hard disk from target VM..." 

Remove-HardDisk -HardDisk $harddisk -Confirm:$false

# Guest hard disk removed, now remove the stale datastore
$datastore = $harddisk.filename.Substring(1, ($harddisk.filename.LastIndexOf(']') - 1))

Write-Host -ForegroundColor Green "Detaching datastore..." 

Get-Datastore $datastore | Remove-Datastore -VMHost $VMhostname -Confirm:$false

# Connect to the array, authenticate. Remember disclaimer at the top!
Write-Host -ForegroundColor Green "Connecting to Pure FlashArray..." 

$FlashArray = New-PfaArray -EndPoint $ArrayName -UserName $ArrayUsername -Password (ConvertTo-SecureString -AsPlainText $ArrayPassword -Force) -IgnoreCertificateError

# Perform the volume overwrite (no intermediate snapshot needed!)
Write-Host -ForegroundColor Green "Performing datastore array volume clone..." 

New-PfaVolume -Array $FlashArray -VolumeName $TargetVolumeName -Source $SourceVolumeName -Overwrite

# Now let's tell the ESX host to rescan storage

$VMHost = Get-VMHost $VMHostname 

Write-Host -ForegroundColor Green "Rescanning storage on VM host..." 

Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VMHost

$esxcli = Get-EsxCli -VMHost $VMHost

# If debug needed, use: $snapInfo = $esxcli.storage.vmfs.snapshot.list()

# Do a resignature of the datastore
Write-Host -ForegroundColor Green "Performing resignature of the new datastore..." 

$esxcli.storage.vmfs.snapshot.resignature($SourceDatastoreName)

# Find the assigned datastore name
Write-Host -ForegroundColor Green "Waiting for new datastore to come online..." 

$datastore = (Get-Datastore | ? { $_.name -match 'snap' -and $_.name -match $SourceDatastoreName })

while ($null -eq $datastore) { # We may have to wait a little bit before the datastore is fully operational
    $datastore = (Get-Datastore | ? { $_.name -match 'snap' -and $_.name -match $SourceDatastoreName })
    Start-Sleep -Seconds 1
}

$datastore = $datastore[0].Name

# Attach the VMDK to the target VM
Write-Host -ForegroundColor Green "Attaching VMDK to target VM..." 

$DiskPath = "[" + $datastore + "] " + $VMDKPath

Write-Host -ForegroundColor Green "DiskPath: $DiskPath"

New-HardDisk -VM $VM -DiskPath $DiskPath

# Online the guest target volume
Write-Host -ForegroundColor Green "Onlining guest volume on target VM..." 

# Also, the volume might be read-only, so let's force read/write. These things happen sometimes...
$ScriptBlock = [ScriptBlock]::Create('$disk = Get-Disk | ? { $_.Number -eq ' + $TargetVMDiskNumber + ' }; $disk | Set-Disk -IsOffline $False; $disk | Set-Disk -IsReadOnly $False')

Invoke-Command -Session $TargetVMSession -ScriptBlock $ScriptBlock

# Online the database
$ScriptBlock = [ScriptBlock]::Create("Invoke-Sqlcmd -ServerInstance . -Database master -Query `"ALTER DATABASE $DatabaseName SET ONLINE WITH ROLLBACK IMMEDIATE`"")

Write-Host -ForegroundColor Green "Onlining target database..." 

Invoke-Command -Session $TargetVMSession -ScriptBlock $ScriptBlock

$TotalTimeSeconds = ((Get-Date) - $StartTime).TotalSeconds

Write-Host -ForegroundColor Green "Total Time Elapsed: $TotalTimeSeconds seconds"