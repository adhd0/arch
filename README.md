# arch

my archlinux template, perform `curl -fLO https://raw.githubusercontent.com/adhd0/arch/main/archws.sh` and run `bash archws.sh install`

install script for my desktop (ryzen cpu, rtx 50xx, qhd display).

this is my personal setup, made for this one machine

## stack

- grub, luks2, btrfs, zram, linux-zen, linux-lts, nvidia-open-dkms
- plasma (wayland), pipewire, firewalld
- snapper, snap-pac, grub-btrfs

## install

from the arch iso, uefi:

```
bash archws.sh install --dry-run
bash archws.sh install
```

the script must not be under `/mnt`.

resume after a failure:

```
bash archws.sh install --resume
```

reuse saved answers (`/var/lib/archws/answers.conf`):

```
bash archws.sh install --config answers.conf
```

after the first boot:

```
archws post
archws verify
```

## mullvad

asked first. the script downloads the 2026.5 `.deb` from github, checks the signature, starts
the daemon with lockdown mode on and connects before installing anything.

to skip the github download, put `MullvadVPN-2026.5_amd64.deb` and `.asc` next to the script.

on the installed system there is no network until `archws post` logs in.

## rollback

```
sudo archws rollback --list
sudo archws rollback
reboot
sudo archws rollback --finish
sudo archws rollback --cleanup
```

without the script:

```
mount -o subvolid=5 /dev/mapper/cryptroot /mnt
mv /mnt/@ /mnt/@.broken
btrfs subvolume snapshot /mnt/@snapshots/<N>/snapshot /mnt/@
rsync -a -c --delete /mnt/@/.bootbackup/ /boot/
rm -f /mnt/@/var/lib/pacman/db.lck
umount /mnt && reboot
```

## disk

```
p1  2g    esp, /boot
p2  rest  luks2, btrfs

@            /
@home        /home
@snapshots   /.snapshots
@log         /var/log
@pkg         /var/cache/pacman/pkg
@docker      /var/lib/docker
@containers  /var/lib/containers
@rancher     /var/lib/rancher
```

`/boot` is not encrypted. snapshots do not include `/home`.
