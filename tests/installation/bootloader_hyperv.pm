# SUSE's openQA tests
#
# Copyright © 2016-2017 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: Hyper-V bootloader with asset downloading
# Maintainer: Michal Nowak <mnowak@suse.com>

use base 'installbasetest';
use testapi;
use utils;
use strict;
use warnings;
use File::Basename;

sub hyperv_cmd {
    my ($cmd, $args) = @_;
    $args->{ignore_return_code} ||= 0;
    my $ret = console('svirt')->run_cmd($cmd);
    die 'Command on Hyper-V failed' unless ($args->{ignore_return_code} || !$ret);
}

sub run {
    my $svirt               = select_console('svirt');
    my $hyperv_intermediary = select_console('hyperv-intermediary');
    my $name                = $svirt->name;

    # Gather paths of assets on NFS to be downloaded to Hyper-V
    my @filepaths;
    @filepaths = get_var('ISO') if get_var('ISO');
    for my $n (1 .. 9) {
        push @filepaths, "hdd\\" . basename get_var("HDD_$n") if get_var("HDD_$n");
        push @filepaths, "iso\\" . basename get_var("ISO_$n") if get_var("ISO_$n");
    }

    # Mount openQA NFS share to drive N:
    hyperv_cmd("if not exist N: ( mount \\\\openqa.suse.de\\var\\lib\\openqa\\share\\factory N: )");

    # Copy assets from NFS share to local cache on Hyper-V
    my $type = fileparse_set_fstype('MSWin32');
    for my $filepath (@filepaths) {
        my $filename = basename $filepath;
        hyperv_cmd("if not exist D:\\cache\\$filename ( copy N:\\$filepath D:\\cache\\ )");
        # Decompress the XZ compressed image & rename it to .vhd
        if ($filename =~ m/vhdfixed\.xz/) {
            # Becaus we wrote 30-40 GB of zeros to disk, we have to wait some time for the disk
            # to write all the data, otherwise the test would be error-prone due to the load.
            # Wrt `ping 127.0.0.1 ...`: this is actually the 'standard' way to sleep $nap seconds
            # in scripted Windows environments...
            hyperv_cmd("if not exist D:\\cache\\" . $filename =~ s/vhdfixed\.xz/vhd/r . " ( xz --decompress --keep --verbose D:\\cache\\$filename )");
            # Check average disk load for $nap seconds to make sure all the data are in cold on disk.
            my $nap = 600;
            select_console('svirt');
            type_string("typeperf \"\\PhysicalDisk(1 D:)\\Avg\. Disk Bytes/Write\"\n");
            assert_screen('no-hyperv-disk-load', $nap);
            send_key 'ctrl-c';
            assert_screen 'hyperv-typeperf-command-finished';
            select_console('hyperv-intermediary');
            # Rename .vhdfixed to .vhd
            $filename = $filename =~ s/\.xz//r;
            hyperv_cmd("if not exist D:\\cache\\" . $filename =~ s/vhdfixed/vhd/r . " ( move /Y D:\\cache\\$filename D:\\cache\\" . $filename
                  =~ s/vhdfixed/vhd/r . " )");
        }
    }
    fileparse_set_fstype($type);

    my $xvncport = get_required_var('VIRSH_INSTANCE');

    my $hdd1 = get_var('HDD_1') ? 'd:\\cache\\' . basename(get_var('HDD_1')) =~ s/vhdfixed\.xz/vhd/r : undef;
    my $hdd2 = get_var('HDD_2') ? 'd:\\cache\\' . basename(get_var('HDD_2')) =~ s/vhdfixed\.xz/vhd/r : undef;
    my $hdd1size = get_var('HDDSIZEGB');
    my $iso      = get_var('ISO') ? 'd:\\cache\\' . basename(get_var('ISO')) : undef;
    my $ramsize  = get_var('QEMURAM');
    my $cpucount = get_var('QEMUCPUS');

    type_string "mkdir -p ~/.vnc/\n";
    type_string "vncpasswd -f <<<$testapi::password > ~/.vnc/passwd\n";
    type_string "chmod 0600 ~/.vnc/passwd\n";
    type_string "pkill -f \"Xvnc :$xvncport\"; pkill -9 -f \"Xvnc :$xvncport\"\n";
    type_string "Xvnc :$xvncport -geometry 1024x768 -pn -rfbauth ~/.vnc/passwd &\n";

    my $ps = 'powershell -Command';

    my ($winserver, $winver, $vmguid);

    $winver = $svirt->get_cmd_output("cmd /C ver");
    if (grep { /Microsoft Windows \[Version 6.3.*\]/ } $winver) {
        $winserver = 2012;
    }
    else {
        die "Unsupported version: $winver";
    }

    hyperv_cmd("$ps Get-VM");
    hyperv_cmd("$ps Stop-VM -Force $name -TurnOff", {ignore_return_code => 1});
    hyperv_cmd("$ps Remove-VM -Force $name",        {ignore_return_code => 1});
    hyperv_cmd("del d:\\cache\\${name}a.vhd d:\\cache\\${name}a.vhdx");

    if ($winserver eq "2012") {
        my $vm_generation = get_var('UEFI') ? 2 : 1;
        my $hyperv_switch_name = get_var('HYPERV_VIRTUAL_SWITCH', 'ExternalVirtualSwitch');
        if ($hdd1) {
            hyperv_cmd("$ps New-VHD -ParentPath $hdd1 -Path d:\\cache\\${name}a.vhd -Differencing");
            hyperv_cmd("$ps New-VM -Name $name -Generation $vm_generation -VHDPath d:\\cache\\${name}a.vhd "
                  . "-SwitchName $hyperv_switch_name -MemoryStartupBytes ${ramsize}MB");
            if (get_var('HDD_2')) {
                hyperv_cmd("$ps Set-VMDvdDrive -VMName $name -Path $hdd2 -ControllerNumber 1");
            }
        }
        else {
            hyperv_cmd("$ps New-VM -Name $name -Generation $vm_generation -NewVHDPath d:\\cache\\${name}a.vhdx "
                  . "-NewVHDSizeBytes ${hdd1size}GB -SwitchName $hyperv_switch_name -MemoryStartupBytes ${ramsize}MB");
            if (get_var('UEFI')) {
                hyperv_cmd("$ps Add-VMDvdDrive -VMName $name -Path $iso");
            }
            else {
                hyperv_cmd("$ps Remove-VMDvdDrive -VMName $name -ControllerNumber 1 -ControllerLocation 0");    # Removes DvdDrive on 1:0
                hyperv_cmd("$ps Add-VMDvdDrive -VMName $name -Path $iso -ControllerNumber 0 -ControllerLocation 1");
            }
        }
        hyperv_cmd("$ps Set-VMComPort -VMName $name -Number 1 -Path '\\\\.\\pipe\\$name'");
        $vmguid = $svirt->get_cmd_output("$ps (Get-VM -VMName $name).id.guid");
    }
    else {
        die "Hyper-V $winserver is not supported version";
    }

    # For Gen1 type machine: As we boot from IDE (then CD), HDD has to be connected to IDE
    # controller. However that leaves us with just three spare IDE channels for CDs, and one
    # of them has to be install CD, so: only three CDs can be attached to machine at once
    # (CDROM device can't be connected to SCSI, HDD can but we won't be able to bott from it).
    for my $n (1 .. 3) {
        if (my $addoniso = get_var("ISO_$n")) {
            hyperv_cmd("$ps Add-VMDvdDrive -VMName $name -Path d:\\cache\\" . basename($addoniso));
        }
    }

    hyperv_cmd("$ps Set-VMProcessor $name -Count $cpucount");
    # All booteble devices has to be enumerated all the time...
    my $startup_order = (check_var('BOOTFROM', 'd') ? "'CD', 'VHD'" : "'VHD', 'CD'") . ", 'Floppy', 'NetworkAdapter'";
    if (get_var('UEFI')) {
        hyperv_cmd("$ps Set-VMFirmware $name -EnableSecureBoot off ");
    }
    else {
        hyperv_cmd($ps . ' "' . "Set-VMBios $name -StartupOrder @($startup_order)" . '"');
    }

    # remove stray whitespace characters
    $vmguid =~ s/[^[:print:]]+//;

    # xfreerdp should be run with fullscreen option (/f) so the needle match.
    # Typing this string takes so long that we would miss grub menu, so...
    type_string "rm -fv xfreerdp_${name}_stop* xfreerdp_${name}.log; while true; do inotifywait xfreerdp_${name}_stop; DISPLAY=:$xvncport xfreerdp /u:"
      . get_var('HYPERV_USERNAME') . " /p:'"
      . get_var('HYPERV_PASSWORD') . "' /v:"
      . get_var('HYPERV_SERVER')
      . " /cert-ignore /vmconnect:$vmguid /f 2>&1 >> xfreerdp_${name}.log; echo $vmguid > xfreerdp_${name}_stop; done";
    #      . " /cert-ignore /jpeg /jpeg-quality:100 /fast-path:1 /bpp:32 /vmconnect:$vmguid /f";

    hyperv_cmd("$ps Start-VM $name");

    # ...we execute the command right after VMs starts.
    send_key 'ret';

    # Attach to serial console (a TCP port on HYPERV_SERVER).
    $svirt->attach_to_running({stop_vm => 1});
    # Get the VM's display.
    select_console('sut', await_console => 0);
}

1;
