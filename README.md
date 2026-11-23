# arch

my archlinux template, perform `curl -fLO https://raw.githubusercontent.com/adhd0/arch/main/archws.sh` and run `bash archws.sh install` if u want it

install script for my desktop (ryzen cpu, rtx 50xx, qhd display).

it installs an encrypted (luks2) btrfs system with grub, linux-zen + linux-lts, nvidia-open drivers,
plasma on wayland with pipewire and firewalld, zram, automatic snapshots (snapper, snap-pac, grub-btrfs),
docker/podman/k3s, dev toolchains, mpv, prism launcher for minecraft and a few flatpak apps.

tuned for responsiveness: zram with matching vm sysctls (zswap off), systemd-oomd, trim and dm-crypt
workqueue bypass on nvme, btrfs with noatime and zstd.

## tl;dr

```
bash archws.sh install             # from the arch iso; asks questions, then installs
bash archws.sh install --resume    # continue after a failure
archws post                        # after the first boot: flatpak apps, devtools, etc
archws verify                      # check the installed system
sudo archws rollback               # go back to a snapshot
```

the first question is whether to route everything through mullvad.
`/boot` is not encrypted. snapshots do not include `/home`.
