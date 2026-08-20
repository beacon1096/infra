# hpe-microserver — disk layout
#
# HPE ProLiant MicroServer Gen10 Plus
# 3× KIOXIA EXCERIA SATA SSD (894.3G each)
# (sdd MX500 excluded — unreliable, dropped from SATA bus)
#
# All three disks in mdadm RAID5 (usable ~1.79TB).
# All three disks carry an ESP partition for boot redundancy.
# RAID5 array formatted as btrfs with subvolumes.
#
# No swap — 64GB RAM is sufficient.
let
  mkDisk = device: espMountpoint: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          name = "ESP";
          start = "1M";
          end = "4G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = espMountpoint;
            mountOptions = [ "fmask=0077" "dmask=0077" ];
          };
        };
        raid = {
          size = "100%";
          content = {
            type = "mdraid";
            name = "data";
          };
        };
      };
    };
  };
in
{
  disko.devices = {
    disk = {
      sda = mkDisk "/dev/sda" "/boot";
      sdb = mkDisk "/dev/sdb" "/boot/esp-sdb";
      sdc = mkDisk "/dev/sdc" "/boot/esp-sdc";
    };

    mdadm.data = {
      type = "mdadm";
      level = 5;
      # The previous array was created with an internal bitmap and produced
      # metadata that the kernel later refused to import. Keep the layout
      # simple and let the kernel resync normally.
      extraArgs = [ "--bitmap=none" ];
      content = {
        type = "btrfs";
        extraArgs = [ "-f" ];
        subvolumes = {
          "@" = {
            mountpoint = "/";
            mountOptions = [ "compress=zstd" ];
          };
          "@home" = {
            mountpoint = "/home";
            mountOptions = [ "compress=zstd" ];
          };
          "@nix" = {
            mountpoint = "/nix";
            mountOptions = [ "compress=zstd" "noatime" ];
          };
        };
      };
    };
  };
}
