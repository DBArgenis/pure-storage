#
#   Pure Storage FlashArray Snap Torture
#   Last updated by Argenis Fernandez <argenis@purestorage.com> 20200604
#

$ArrayName = '10.21.230.28'
$TargetVM = 'sql-s01'
$ArrayUsername = 'pureuser'
$ArrayPassword = 'pureuser'

# Create a Powershell session against the target VM
$TargetVMSession = New-PSSession -ComputerName $TargetVM

$FlashArray = New-PfaArray -EndPoint $ArrayName -UserName $ArrayUsername -Password (ConvertTo-SecureString -AsPlainText $ArrayPassword -Force) -IgnoreCertificateError

$ScriptBlock = [ScriptBlock]::Create('Get-Disk | ? { $_.Number -gt 2 -and $_.Number -lt 103 }')

# Get the list of disks in Windows that are going to be refreshed
$TargetDisks =  Invoke-Command -Session $TargetVMSession -ScriptBlock $ScriptBlock 
$TargetVolumes = Get-PfaVolumes -Array $FlashArray | ? { $_.Created -gt '5/27/2020' -and $_.name -match 'vvol-sql-s01-f41c562d-vg' -and $_.size -eq 20TB }

0..1 | ForEach-Object {
    
    # Overwrite the volume with a fresh copy from the source volume 
    New-PfaVolume -Array $FlashArray -VolumeName $TargetVolumes[$_].name -Source vvol-sql-s01-f41c562d-vg/Data-41411ed5 -Overwrite
}

0..1 | ForEach-Object { 
        # Create ScriptBlock to Online the volume and make it writeable
        $ScriptBlock = [ScriptBlock]::Create('Set-Disk -Number ' + $TargetDisks[$_].Number + ' -IsOffline $False; Set-Disk -Number ' + $TargetDisks[$_].Number + ' -IsReadOnly $False')
    
        # Bring the volume online in Windows and make it writeable
        Invoke-Command -Session $TargetVMSession -ScriptBlock $ScriptBlock
}

$MountScriptBlock = [ScriptBlock]::Create('1..100 | % { $DiskNumber = $_ + 2; Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber 2 -AccessPath "X:\SqlData-$_"}')
Invoke-Command -Session $TargetVMSession -ScriptBlock $MountScriptBlock

0..1 | ForEach-Object { 
    $CopyNumber = $_ + 1;
    $SqlQuery = @"
    CREATE DATABASE [FT_Demo-Copy-$CopyNumber] ON 
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo.mdf' ),
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo_log.LDF' ),
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo_Base_1.ndf' ),
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo_part_ci1_01.ndf' ),
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo_part_ci2_01.ndf' ),
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo_part_ci3_01.ndf' ),
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo_part_ci4_01.ndf' ),
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo_part_ci5_01.ndf' ),
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo_part_ci6_01.ndf' ),
( FILENAME = N'X:\SqlData-$CopyNumber\FT_Demo_part_ci7_01.ndf' )
 FOR ATTACH
"@
    Invoke-SqlCmd -ServerInstance 'SQL-S01' -Database 'master' -Query $SqlQuery
}


