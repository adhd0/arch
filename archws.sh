#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2026.11.23-6"
T=/mnt
DRY=0
RESUME=0
CONFIG_IN=""
LOG=""
MAPPER=cryptroot
STATE_DIR="$T/var/lib/archws"
STATE_FILE="$STATE_DIR/install.state"
ANSWERS_FILE="$STATE_DIR/answers.conf"
LIVE_ANSWERS=/run/archws-answers.conf
MIN_DISK_GIB=40
MULLVAD_DEFAULT_VERSION=2026.5
MULLVAD_FPR=A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF
MULLVAD_DIR=/tmp/archws-mullvad
MULLVAD_DEB=""
ANSWER_KEYS=(USE_MULLVAD MULLVAD_MODE MULLVAD_LOCATION MULLVAD_ON_TARGET MULLVAD_VERSION
  DISK HOST_NAME USER_NAME TIMEZONE KEYMAP XKB_LAYOUTS MIRRORS
  WANT_NVIDIA WANT_DEV WANT_CONTAINERS WANT_BT WANT_PRINT WANT_OOMD WANT_MEDIA WANT_PRISM EXTRA_PKGS)

if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
else
  B=""; DIM=""; RED=""; GRN=""; YLW=""; CYN=""; RST=""
fi
step() { printf '\n%s==> %s%s\n' "$B$CYN" "$*" "$RST"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s!!  %s%s\n' "$YLW" "$*" "$RST" >&2; }
die()  { printf '%sERROR: %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

on_err() {
  local rc=$? line=$1
  printf '\n%sFailed (exit %s) near line %s.%s\n' "$RED" "$rc" "$line" "$RST" >&2
  [[ -n $LOG ]] && printf 'Log: %s\n' "$LOG" >&2
  if [[ ${MODE:-} == install ]]; then
    if [[ -f $STATE_FILE ]]; then
      printf 'Finished stages are recorded. Fix the cause, then continue with:\n  bash %s install --resume\n' "${BASH_SOURCE[0]}" >&2
    elif [[ -f $LIVE_ANSWERS ]]; then
      printf 'Nothing resumable yet. Start again without retyping the answers:\n  bash %s install --config %s\n' "${BASH_SOURCE[0]}" "$LIVE_ANSWERS" >&2
    fi
    if ((${USE_MULLVAD:-0})); then
      printf 'This live session is still registered as a device on your Mullvad account.\nIt is removed when the install completes, or now with: mullvad account logout\n' >&2
    fi
  fi
  exit "$rc"
}
trap 'on_err $LINENO' ERR

run() {
  printf '%s+ %s%s\n' "$DIM" "$*" "$RST"
  ((DRY)) && return 0
  if [[ -n $LOG ]]; then
    printf '+ %s\n' "$*" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG"
  else
    "$@"
  fi
}
run_tty() {
  printf '%s+ %s%s\n' "$DIM" "$*" "$RST"
  ((DRY)) && return 0
  "$@"
}
retry() {
  local n
  for n in 1 2 3; do
    if "$@"; then return 0; fi
    if ((n < 3)); then warn "That failed (attempt $n of 3). Retrying in 10 seconds."; sleep 10; fi
  done
  return 1
}
in_chroot() { run arch-chroot "$T" "$@"; }
put() {
  printf '%s+ write %s%s\n' "$DIM" "$1" "$RST"
  if ((DRY)); then cat >/dev/null; return 0; fi
  install -D -m "$2" /dev/stdin "$T$1"
}
sput() {
  printf '%s+ write %s%s\n' "$DIM" "$1" "$RST"
  if ((DRY)); then cat >/dev/null; return 0; fi
  sudo install -D -m "$2" /dev/stdin "$1"
}
have() { command -v "$1" >/dev/null 2>&1; }
start_log() { LOG="$T/var/log/archws-install.log"; mkdir -p "${LOG%/*}"; }
sim() { ((DRY)) || [[ -n ${ARCHWS_TEST-} ]]; }

ask() {
  local __var=$1 __prompt=$2 __def=${3-} __ans=""
  if [[ -n $__def ]]; then
    read -r -p "$__prompt [$__def]: " __ans || true
    __ans=${__ans:-$__def}
  else
    read -r -p "$__prompt: " __ans || true
  fi
  printf -v "$__var" '%s' "$__ans"
}
ask_yn() {
  local __ans="" __def=$2 __hint="[y/N]"
  [[ $__def == Y ]] && __hint="[Y/n]"
  while true; do
    read -r -p "$1 $__hint: " __ans || true
    __ans=${__ans:-$__def}
    case ${__ans,,} in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "    Please answer y or n." ;;
    esac
  done
}
ask_secret() {
  local __var=$1 __a="" __b=""
  while true; do
    read -r -s -p "$2: " __a || true; echo
    read -r -s -p "$2 (again): " __b || true; echo
    if [[ -z $__a ]]; then echo "    Must not be empty."; continue; fi
    if [[ $__a != "$__b" ]]; then echo "    The two entries differ. Try again."; continue; fi
    printf -v "$__var" '%s' "$__a"
    return 0
  done
}
ask_valid() {
  local __v=$1 __re=$4
  if [[ -n ${!__v+x} ]]; then
    if [[ ${!__v} =~ $__re ]]; then info "$2: ${!__v:-(empty)}  (from config)"; return 0; fi
    warn "Ignoring invalid $__v from the config: '${!__v}'"
  fi
  while true; do
    ask "$__v" "$2" "$3"
    [[ ${!__v} =~ $__re ]] && break
    echo "    $5"
  done
}
flag() {
  local __v=$1
  if [[ ${!__v-} == [01] ]]; then
    info "$2 $( ((${!__v})) && echo yes || echo no )  (from config)"
    return 0
  fi
  if ask_yn "$2" "$3"; then printf -v "$__v" 1; else printf -v "$__v" 0; fi
}

load_answers() {
  local file=$1 line="" key val
  [[ -f $file && -r $file ]] || die "Cannot read answers file: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line =~ ^([A-Z_]+)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
      val=${val%\"}; val=${val#\"}
      case " ${ANSWER_KEYS[*]} " in
        *" $key "*) printf -v "$key" '%s' "$val" ;;
        *) warn "Ignoring unknown key in $file: $key" ;;
      esac
    else
      warn "Ignoring malformed line in $file: $line"
    fi
  done < "$file"
}
write_answers() {
  local k
  {
    echo "# archws answers. No passwords are stored here."
    echo "# Reuse with: bash archws.sh install --config <this file>"
    for k in "${ANSWER_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k-}"; done
  } > "$1"
}
stage_done() { [[ -f $STATE_FILE ]] && grep -qx "$1" "$STATE_FILE"; }
stage() {
  if stage_done "$1"; then info "Stage '$1' is already done; skipping."; return 0; fi
  "$2"
  ((DRY)) && return 0
  install -d -m 700 "$STATE_DIR"
  echo "$1" >> "$STATE_FILE"
  [[ -f $ANSWERS_FILE ]] || write_answers "$ANSWERS_FILE"
}

PK_BASE=(base base-devel linux-zen linux-zen-headers linux-lts linux-lts-headers linux-firmware
  btrfs-progs cryptsetup dosfstools grub efibootmgr grub-btrfs inotify-tools rsync
  networkmanager wireless-regdb sudo zsh git vim nano less man-db man-pages
  zram-generator reflector terminus-font)
PK_NVIDIA=(nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver)
PK_DESKTOP=(plasma-meta konsole dolphin dolphin-plugins kate ark gwenview okular kcalc
  partitionmanager filelight kwalletmanager ffmpegthumbs kdegraphics-thumbnailers kio-admin
  xdg-desktop-portal-gtk xdg-user-dirs xsettingsd xorg-xwayland xorg-xlsclients xorg-xrdb firefox
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber lib32-pipewire)
PK_SYSTEM=(firewalld power-profiles-daemon fwupd smartmontools nvme-cli lm_sensors usbutils pciutils
  flatpak pacman-contrib pkgfile openssh jq 7zip unzip zip unrar exfatprogs ntfs-3g libva-utils vulkan-tools
  wireguard-tools networkmanager-openvpn hunspell-en_us hunspell-ru
  wl-clipboard bash-completion zsh-completions zsh-autosuggestions zsh-syntax-highlighting
  htop btop fastfetch ripgrep fd fzf bat eza zoxide tree wget)
PK_FONTS=(noto-fonts noto-fonts-cjk noto-fonts-emoji inter-font ttf-jetbrains-mono
  ttf-jetbrains-mono-nerd ttf-fira-code ttf-cascadia-code ttf-dejavu ttf-liberation
  ttf-carlito ttf-caladea)
PK_REMOTE=(krdc freerdp)
PK_MEDIA=(mpv yt-dlp ffmpeg gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav
  gst-plugin-pipewire libdvdcss libheif libavif libjxl)
PK_PRISM=(prismlauncher)
PK_BLUETOOTH=(bluez bluez-utils)
PK_PRINT=(cups cups-pdf system-config-printer avahi nss-mdns)
PK_VM_GUEST=(qemu-guest-agent spice-vdagent)
PK_DEV=(gcc clang llvm lld lldb gdb cmake ninja meson ccache mold bear valgrind strace perf
  git-lfs github-cli git-delta go gopls delve rustup python python-pipx uv ruff pyright
  nodejs-lts-krypton npm pnpm jdk21-openjdk maven gradle go-yq tmux httpie direnv
  shellcheck shfmt hyperfine tealdeer bind mtr tcpdump iperf3 socat lsof openbsd-netcat nmap code)
PK_CONTAINERS=(docker docker-compose docker-buildx podman podman-compose kubectl helm k9s kubectx)
PK_SNAPSHOTS=(snapper snap-pac btrfs-assistant)
FLATPAK_APPS=(
  "org.telegram.desktop|Telegram|Y|verified publisher"
  "com.discordapp.Discord|Discord|Y|verified publisher"
  "org.keepassxc.KeePassXC|KeePassXC (password manager)|Y|verified publisher"
  "app.zen_browser.zen|Zen Browser (second browser)|Y|verified publisher"
  "com.termius.Termius|Termius (SSH client)|Y|community build, not vendor-verified"
  "com.visualstudio.code|Microsoft build of VS Code (only for Marketplace-only extensions)|N|community build, not vendor-verified"
  "it.mijorus.gearlever|Gear Lever (adds AppImages such as Cursor to the app menu)|N|verified publisher"
)

SUBVOLS=(@ @home @snapshots @log @pkg @docker @containers @rancher)

pac() { retry in_chroot pacman -S --noconfirm --needed "$@"; }

detect_ucode() {
  if grep -q AuthenticAMD /proc/cpuinfo 2>/dev/null; then echo amd-ucode
  elif grep -q GenuineIntel /proc/cpuinfo 2>/dev/null; then echo intel-ucode
  fi
}
has_gpu() {
  local d
  for d in /sys/bus/pci/devices/*; do
    [[ -r $d/vendor && -r $d/class ]] || continue
    if [[ $(<"$d/vendor") == "$1" && $(<"$d/class") == 0x03* ]]; then return 0; fi
  done
  return 1
}
detect_virt() {
  local v=""
  have systemd-detect-virt && v=$(systemd-detect-virt 2>/dev/null || true)
  echo "${v:-none}"
}
secure_boot_on() {
  local -a f=(/sys/firmware/efi/efivars/SecureBoot-*)
  [[ -r ${f[0]} ]] || return 1
  [[ $(od -An -t u1 -j4 -N1 "${f[0]}" 2>/dev/null | tr -d ' ') == 1 ]]
}

preflight_local() {
  step "Checking the live environment"
  if ((DRY)); then info "dry run: no changes will be made"; return 0; fi
  if sim; then info "test mode: hardware checks skipped"; return 0; fi
  [[ $EUID -eq 0 ]] || die "Run the installer as root from the Arch ISO."
  case $(readlink -f "${BASH_SOURCE[0]}") in
    "$T"/*) die "Copy this script off $T first (for example to /root) and run it from there." ;;
  esac
  [[ -r /sys/firmware/efi/fw_platform_size && $(</sys/firmware/efi/fw_platform_size) == 64 ]] \
    || die "Not booted in 64-bit UEFI mode. Reboot the ISO from its UEFI entry."
  if secure_boot_on; then
    die "Secure Boot is enabled. This setup boots an unsigned GRUB and unsigned DKMS modules; disable Secure Boot in the firmware and start again."
  fi
  local c
  for c in sgdisk wipefs partprobe cryptsetup mkfs.btrfs mkfs.fat pacstrap genfstab arch-chroot lsblk blkid; do
    have "$c" || die "Missing tool on this system: $c (use the official Arch ISO)."
  done
  [[ -d /run/archiso ]] || warn "This does not look like the Arch ISO. Continuing anyway."
  if [[ $1 == fresh ]] && { mountpoint -q "$T" || [[ -e /dev/mapper/$MAPPER ]]; }; then
    warn "A previous attempt left $T mounted or /dev/mapper/$MAPPER open."
    info "To continue that attempt instead, answer n and run: install --resume"
    ask_yn "Unmount and close it now (the disk will be wiped again)?" N || die "Left as it is."
    umount -R "$T" 2>/dev/null || true
    cryptsetup close "$MAPPER" 2>/dev/null || true
  fi
  info "UEFI 64-bit, Secure Boot off, tools present."
}
preflight_net() {
  if sim; then return 0; fi
  ping -c1 -W5 archlinux.org >/dev/null 2>&1 || die "No network. Connect first (Wi-Fi: iwctl station wlan0 connect <ssid>)."
  local i
  for i in $(seq 1 15); do
    [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && break
    sleep 2
  done
  [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] \
    || warn "Clock is not NTP-synchronised yet; package signature checks may fail."
  info "Network is reachable."
}

set_partitions() {
  local p=""
  [[ $DISK == *[0-9] ]] && p=p
  ESP="${DISK}${p}1"; LUKS="${DISK}${p}2"
}
pick_disk() {
  local -a disks=() ; local d iso_src="" iso_disk="" i pick=""
  if [[ -n ${DISK-} ]]; then
    if sim || [[ -b $DISK ]]; then info "Disk: $DISK  (from config)"; return 0; fi
    warn "Disk from config does not exist: $DISK"
  fi
  if have lsblk; then
    iso_src=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
    [[ -n $iso_src ]] && iso_disk="/dev/$(lsblk -no PKNAME "$iso_src" 2>/dev/null | head -n1)"
    while read -r d; do
      [[ $d == /dev/zram* || $d == "$iso_disk" ]] && continue
      disks+=("$d")
    done < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')
  fi
  if ((${#disks[@]} == 0)); then
    ((DRY)) || die "No installable disk found."
    disks=(/dev/nvme0n1); info "dry run: pretending /dev/nvme0n1 exists"
  fi
  for i in "${!disks[@]}"; do
    printf '  %s) %s\n' "$((i + 1))" "$(lsblk -dpno NAME,SIZE,MODEL "${disks[$i]}" 2>/dev/null || echo "${disks[$i]}")"
  done
  while true; do
    ask pick "Which disk (number)" 1
    [[ $pick =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#disks[@]})) && break
    echo "    Enter a number from the list."
  done
  DISK=${disks[$((pick - 1))]}
}
choose_disk() {
  step "Target disk"
  pick_disk
  set_partitions
  if ! sim; then
    local bytes
    bytes=$(lsblk -bdno SIZE "$DISK")
    ((bytes >= MIN_DISK_GIB * 1024 * 1024 * 1024)) \
      || die "$DISK is smaller than ${MIN_DISK_GIB} GiB; too small for this setup."
  fi
  echo
  lsblk -po NAME,SIZE,FSTYPE,LABEL "$DISK" 2>/dev/null || true
  printf '\n%s%sEVERYTHING ON %s WILL BE DESTROYED.%s\n' "$B" "$RED" "$DISK" "$RST"
  local confirm=""
  ask confirm "Type the device name (${DISK##*/}) to confirm"
  [[ $confirm == "${DISK##*/}" ]] || die "Confirmation did not match. Nothing was changed."
}
mount_target() {
  local dev=/dev/mapper/$MAPPER o=noatime,compress=zstd:1
  run mount -o "$o,subvol=@" "$dev" "$T"
  run mount --mkdir -o "$o,subvol=@home"       "$dev" "$T/home"
  run mount --mkdir -o "$o,subvol=@snapshots"  "$dev" "$T/.snapshots"
  run mount --mkdir -o "$o,subvol=@log"        "$dev" "$T/var/log"
  run mount --mkdir -o "$o,subvol=@pkg"        "$dev" "$T/var/cache/pacman/pkg"
  run mount --mkdir -o "$o,subvol=@docker"     "$dev" "$T/var/lib/docker"
  run mount --mkdir -o "$o,subvol=@containers" "$dev" "$T/var/lib/containers"
  run mount --mkdir -o "$o,subvol=@rancher"    "$dev" "$T/var/lib/rancher"
  run mount --mkdir -o umask=0077 "$ESP" "$T/boot"
}

mullvad_key() {
  cat <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v2

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
=kwTD
-----END PGP PUBLIC KEY BLOCK-----
EOF
}

mullvad_ask() {
  step "Network"
  local re_mode='^(auto|off|lwo|quic|shadowsocks|udp2tcp|wireguard-port)$'
  flag USE_MULLVAD "Use Mullvad? (everything below is then downloaded through its WireGuard tunnel)" N
  if ! ((USE_MULLVAD)); then MULLVAD_MODE=off; MULLVAD_LOCATION=""; MULLVAD_ON_TARGET=0; return 0; fi
  if [[ -z ${MULLVAD_MODE+x} ]] && ! ask_yn "Use anti-censorship (for networks that block WireGuard)?" Y; then
    MULLVAD_MODE=off
  fi
  ask_valid MULLVAD_MODE "Anti-censorship method: lwo, quic, shadowsocks, udp2tcp, wireguard-port, auto" lwo \
    "$re_mode" "One of: lwo quic shadowsocks udp2tcp wireguard-port auto off"
  ask_valid MULLVAD_LOCATION "Server: hostname (se-got-wg-001), country (se) or 'country city' (se got); empty = any" "" \
    '^([a-z]{2}( [a-z]{3})?|[a-z]{2}-[a-z]{3}-[a-z0-9-]+)?$' "Examples: se-got-wg-001   se   se got"
  flag MULLVAD_ON_TARGET "Install Mullvad on the new system too (lockdown on; you log in once after first boot)?" Y
}
mullvad_ask_account() {
  local a=""
  while true; do
    read -r -s -p "Mullvad account number (16 digits, not shown): " a || true; echo
    a=${a//[[:space:]]/}
    [[ $a =~ ^[0-9]{16}$ ]] && break
    echo "    An account number is 16 digits."
  done
  MULLVAD_ACCOUNT=$a
}
mullvad_verify() {
  local home status
  home=$(mktemp -d)
  mullvad_key | gpg --homedir "$home" --batch --quiet --import
  status=$(gpg --homedir "$home" --batch --status-fd 1 --verify "$1.asc" "$1" 2>/dev/null || true)
  rm -rf "$home"
  grep -q "^\[GNUPG:\] VALIDSIG .* ${MULLVAD_FPR}\$" <<< "$status" \
    || die "Signature check failed for $1. Refusing to use it."
  info "Signature is valid (Mullvad code signing key)."
}
mullvad_fetch() {
  local ver=${MULLVAD_VERSION:-$MULLVAD_DEFAULT_VERSION} name beside url
  name="MullvadVPN-${ver}_amd64.deb"
  beside="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/$name"
  url="https://github.com/mullvad/mullvadvpn-app/releases/download/$ver/$name"
  MULLVAD_DEB="$MULLVAD_DIR/$name"
  if ((DRY)); then info "dry run: would fetch and verify $name"; return 0; fi
  mkdir -p "$MULLVAD_DIR"
  if [[ -f $MULLVAD_DEB && -f $MULLVAD_DEB.asc ]]; then
    info "Using the copy already in $MULLVAD_DIR."
  elif [[ -f $beside && -f $beside.asc ]]; then
    info "Using $beside (no download)."
    cp "$beside" "$beside.asc" "$MULLVAD_DIR/"
  else
    info "Downloading $name from GitHub (outside the tunnel; it does not exist yet)."
    retry run curl -fL --proto '=https' -o "$MULLVAD_DEB" "$url"
    retry run curl -fL --proto '=https' -o "$MULLVAD_DEB.asc" "$url.asc"
  fi
  mullvad_verify "$MULLVAD_DEB"
}
mullvad_live_up() {
  step "Mullvad VPN"
  local c member i
  local -a loc=(any)
  if ! sim; then
    for c in curl gpg bsdtar timeout systemctl; do have "$c" || die "Missing tool for Mullvad: $c"; done
  fi
  mullvad_fetch
  if ! ((DRY)); then
    member=$(bsdtar -tf "$MULLVAD_DEB" | grep -m1 '^data\.tar')
    bsdtar -xOf "$MULLVAD_DEB" "$member" | bsdtar -xf - -C / \
      ./usr/bin/mullvad ./usr/bin/mullvad-daemon \
      "./opt/Mullvad VPN/resources/relays.json" "./opt/Mullvad VPN/resources/ca.crt" \
      ./usr/lib/systemd/system/mullvad-daemon.service
  fi
  run systemctl daemon-reload
  run systemctl start mullvad-daemon.service
  if ! ((DRY)); then
    for i in $(seq 1 30); do mullvad status >/dev/null 2>&1 && break; sleep 1; done
    mullvad status >/dev/null 2>&1 || die "The Mullvad daemon did not start. See: journalctl -u mullvad-daemon"
  fi
  run mullvad lockdown-mode set on
  run mullvad auto-connect set on
  run mullvad anti-censorship set mode "$MULLVAD_MODE"
  [[ -n $MULLVAD_LOCATION ]] && read -r -a loc <<< "$MULLVAD_LOCATION"
  run mullvad relay set location "${loc[@]}"
  printf '%s+ mullvad account login%s\n' "$DIM" "$RST"
  if ! ((DRY)) && mullvad account get 2>&1 | grep -q "Not logged in"; then
    printf '%s\n' "$MULLVAD_ACCOUNT" | mullvad account login >/dev/null \
      || die "Mullvad login failed: wrong number, no time left, or five devices already registered."
  fi
  unset MULLVAD_ACCOUNT
  run timeout 120 mullvad connect --wait
  if ! ((DRY)); then
    if ! mullvad status | grep -q '^Connected'; then
      mullvad status >&2 || true
      die "The tunnel did not come up. Lockdown mode stays on. Try another server or method."
    fi
    info "$(mullvad status | head -n 2 | tr -s ' \n' ' ')"
  fi
}
network_up() {
  if ((${USE_MULLVAD:-0})); then
    if ! ((DRY)) && have mullvad && mullvad status 2>/dev/null | grep -q '^Connected'; then
      info "The Mullvad tunnel is already up."
    else
      mullvad_ask_account
      mullvad_live_up
    fi
  fi
  preflight_net
}
do_mullvad_target() {
  if ! ((USE_MULLVAD && MULLVAD_ON_TARGET)); then return 0; fi
  step "Mullvad on the new system"
  local ver=${MULLVAD_VERSION:-$MULLVAD_DEFAULT_VERSION} name sum=SKIP build=/var/cache/archws/mullvad
  name="MullvadVPN-${ver}_amd64.deb"
  [[ -n $MULLVAD_DEB && ( -f $MULLVAD_DEB || $DRY == 1 ) ]] || mullvad_fetch
  pac alsa-lib at-spi2-core gtk3 libnotify libsecret libxss libxtst nss xdg-utils
  run install -D -m 644 "$MULLVAD_DEB" "$T$build/$name"
  ((DRY)) || sum=$(sha256sum "$MULLVAD_DEB" | cut -d' ' -f1)
  put "$build/PKGBUILD" 644 <<EOF
pkgname=mullvad-vpn-vendor
pkgver=$ver
pkgrel=1
pkgdesc="Mullvad VPN client (vendor build, repackaged)"
arch=(x86_64)
url="https://mullvad.net"
license=(GPL-3.0-or-later)
depends=(alsa-lib at-spi2-core dbus gtk3 iputils libnotify libsecret libxss libxtst nss xdg-utils)
options=(!strip !debug)
source=("$name")
noextract=("$name")
sha256sums=($sum)

package() {
  local member
  member=\$(bsdtar -tf "\$srcdir/$name" | grep -m1 '^data\\.tar')
  bsdtar -xOf "\$srcdir/$name" "\$member" | bsdtar -xf - -C "\$pkgdir"
  install -Dm644 "\$pkgdir/usr/local/share/zsh/site-functions/_mullvad" "\$pkgdir/usr/share/zsh/site-functions/_mullvad"
  rm -r "\$pkgdir/usr/local"
  chmod u+s "\$pkgdir/usr/bin/mullvad-exclude"
}
EOF
  in_chroot chown -R "$USER_NAME:$USER_NAME" "$build"
  in_chroot runuser -u "$USER_NAME" -- env HOME="/home/$USER_NAME" bash -c "cd '$build' && makepkg -f --nodeps"
  in_chroot bash -c "pacman -U --noconfirm '$build'/mullvad-vpn-vendor-*.pkg.tar.zst"
  in_chroot systemctl enable mullvad-daemon.service mullvad-early-boot-blocking.service
  if ! ((DRY)) && [[ -f /etc/mullvad-vpn/settings.json ]]; then
    install -D -m 600 /etc/mullvad-vpn/settings.json "$T/etc/mullvad-vpn/settings.json"
  fi
}
post_mullvad() {
  have mullvad || return 0
  step "Mullvad VPN"
  if ((DRY)); then info "dry run: would log in if needed and connect"; return 0; fi
  local i
  for i in $(seq 1 30); do mullvad status >/dev/null 2>&1 && break; sleep 1; done
  mullvad status >/dev/null 2>&1 || die "The Mullvad daemon is not running: sudo systemctl start mullvad-daemon"
  run mullvad lockdown-mode set on
  if mullvad account get 2>&1 | grep -q "Not logged in"; then
    info "Lockdown mode is on: nothing leaves this machine until you are logged in and connected."
    mullvad_ask_account
    printf '%s\n' "$MULLVAD_ACCOUNT" | mullvad account login >/dev/null \
      || die "Mullvad login failed: wrong number, no time left, or five devices already registered."
    unset MULLVAD_ACCOUNT
  fi
  mullvad status | grep -q '^Connected' || run timeout 120 mullvad connect --wait
  mullvad status | grep -q '^Connected' || die "The tunnel did not come up. Check: mullvad status"
  info "$(mullvad status | head -n 2 | tr -s ' \n' ' ')"
}

choose_timezone() {
  local tz="" matches
  if [[ -n ${TIMEZONE-} ]]; then
    if [[ -f /usr/share/zoneinfo/$TIMEZONE ]] || ((DRY)); then info "Time zone: $TIMEZONE  (from config)"; return 0; fi
    warn "Ignoring unknown time zone from the config: $TIMEZONE"
  fi
  while true; do
    ask tz "Time zone (e.g. Europe/Berlin; type part of a name to search)"
    if [[ -n $tz && -f /usr/share/zoneinfo/$tz ]]; then TIMEZONE=$tz; return 0; fi
    if ((DRY)) && [[ ! -d /usr/share/zoneinfo ]]; then TIMEZONE=${tz:-UTC}; return 0; fi
    matches=$(cd /usr/share/zoneinfo && find . -type f -ipath "*${tz}*" 2>/dev/null \
      | sed 's|^\./||' | grep -vE '^(posix|right)/|\.(tab|zi|list)$' | sort | head -n 20 || true)
    # shellcheck disable=SC2086
    if [[ -n $matches ]]; then echo "    Matches:"; printf '      %s\n' $matches
    else echo "    No time zone matches '$tz'."; fi
  done
}
ask_account_passwords() {
  ask_secret USER_PW "Password for $USER_NAME"
  if ask_yn "Use the same password for root (needed for the emergency shell)?" Y; then
    ROOT_PW=$USER_PW
  else
    ask_secret ROOT_PW "Root password"
  fi
}
derive_settings() {
  LOCALE=en_US.UTF-8
  UCODE=$(detect_ucode)
  VIRT=$(detect_virt)
}

gather() {
  step "Questions (nothing is written to disk until you confirm the summary)"
  derive_settings
  [[ $VIRT == none ]] || info "Virtual machine detected ($VIRT): guest tools will be installed."
  choose_disk

  ask_valid HOST_NAME "Hostname" arch '^[a-z0-9][a-z0-9-]{0,62}$' "Lowercase letters, digits and hyphens only."
  while true; do
    ask_valid USER_NAME "User name" "" '^[a-z_][a-z0-9_-]{0,31}$' "Lowercase letters, digits, '_' and '-'."
    [[ $USER_NAME != root ]] && break
    echo "    The user must not be root."; unset USER_NAME
  done
  ask_account_passwords
  echo "    Disk passphrase: use ASCII characters only; it is typed before your keyboard layout loads."
  while true; do
    ask_secret LUKS_PW "Disk encryption passphrase"
    if [[ $LUKS_PW == *[!\ -~]* ]]; then
      ask_yn "It contains non-ASCII characters. Use it anyway?" N && break
    else
      break
    fi
  done

  choose_timezone
  ask_valid KEYMAP "Console keymap (text console and disk passphrase prompt)" us '^[A-Za-z0-9_-]+$' "A console keymap name, e.g. us"
  ask_valid XKB_LAYOUTS "Desktop keyboard layouts, first is the default (Ctrl+Shift switches)" us,ru \
    '^[a-z]{2,3}(,[a-z]{2,3})*$' "Comma-separated XKB layout codes without spaces, e.g. us,ru"
  ask_valid MIRRORS "Mirror countries as ISO codes, e.g. DE,PL,NL (empty keeps the ISO's mirror list)" "" \
    '^([A-Za-z]{2}(,[A-Za-z]{2})*)?$' "Two-letter country codes separated by commas, no spaces."

  if has_gpu 0x10de; then
    flag WANT_NVIDIA "NVIDIA GPU found. Install the open kernel modules + NVIDIA user space?" Y
  else
    flag WANT_NVIDIA "No NVIDIA GPU detected. Install the NVIDIA driver anyway?" N
  fi
  flag WANT_DEV        "Developer toolchains (C/C++, Go, Rust, Python, Node LTS, Java) and VS Code?" Y
  flag WANT_CONTAINERS "Docker, Podman and Kubernetes CLI tools?" Y
  flag WANT_BT         "Bluetooth?" Y
  flag WANT_PRINT      "Printing (CUPS, network printer discovery)?" N
  flag WANT_OOMD       "systemd-oomd (kills a runaway app before the desktop freezes)?" Y
  flag WANT_MEDIA      "mpv with codecs and hardware video decoding?" Y
  flag WANT_PRISM      "Prism Launcher (Minecraft)?" Y
  ask_valid EXTRA_PKGS "Extra packages to install as well, separated by spaces (empty = none)" "" \
    '^([a-z0-9@._+-]+( +[a-z0-9@._+-]+)*)?$' "Package names from core/extra/multilib, separated by spaces."

  step "Summary"
  cat <<EOF
    Disk ............ $DISK  (ESP $ESP 2G, LUKS2 $LUKS rest)  ** will be wiped **
    Filesystem ...... Btrfs: ${SUBVOLS[*]}
    Kernels ......... linux-zen (default), linux-lts (fallback)   microcode: ${UCODE:-none}
    Host / user ..... $HOST_NAME / $USER_NAME
    Time zone ....... $TIMEZONE      interface language: $LOCALE (English only)
    Keyboard ........ desktop layouts: $XKB_LAYOUTS, switch with Ctrl+Shift      console keymap: $KEYMAP
    Mirrors ......... ${MIRRORS:-keep ISO list}
    Desktop ......... KDE Plasma (Wayland), PipeWire, firewalld, Flatpak
    NVIDIA .......... $( ((WANT_NVIDIA)) && echo yes || echo no )      virtual machine: $VIRT
    Dev tools ....... $( ((WANT_DEV)) && echo yes || echo no )      containers: $( ((WANT_CONTAINERS)) && echo yes || echo no )
    Bluetooth ....... $( ((WANT_BT)) && echo yes || echo no )      printing: $( ((WANT_PRINT)) && echo yes || echo no )      oomd: $( ((WANT_OOMD)) && echo yes || echo no )
    Media (mpv) ..... $( ((WANT_MEDIA)) && echo yes || echo no )      Prism Launcher: $( ((WANT_PRISM)) && echo yes || echo no )
    Extra packages .. ${EXTRA_PKGS:-none}
    Network ......... $( ((USE_MULLVAD)) && echo "Mullvad VPN, method $MULLVAD_MODE, server ${MULLVAD_LOCATION:-any}, on the new system: $( ((MULLVAD_ON_TARGET)) && echo yes || echo no )" || echo "direct" )
EOF
  ask_yn "Start the installation?" N || die "Aborted. Nothing was changed."
  ((DRY)) || write_answers "$LIVE_ANSWERS"
}

resume_prepare() {
  step "Resuming an interrupted installation"
  if ! mountpoint -q "$T"; then
    info "The target is not mounted (the ISO was probably rebooted). Unlocking it again."
    pick_disk
    set_partitions
    [[ -e /dev/mapper/$MAPPER ]] || run_tty cryptsetup open "$LUKS" "$MAPPER"
    mount_target
  fi
  [[ -f $STATE_FILE && -f $ANSWERS_FILE ]] \
    || die "No resumable installation found under $T. Run a normal install (add --config $LIVE_ANSWERS if that file exists)."
  load_answers "$ANSWERS_FILE"
  : "${USE_MULLVAD:=0}" "${MULLVAD_MODE:=off}" "${MULLVAD_LOCATION:=}" "${MULLVAD_ON_TARGET:=0}" "${EXTRA_PKGS:=}"
  set_partitions
  derive_settings
  info "Finished stages: $(tr '\n' ' ' < "$STATE_FILE")"
  if ! stage_done config; then
    info "Accounts were not created yet, so the passwords are needed again."
    ask_account_passwords
  fi
  start_log
}

do_disk() {
  step "Partitioning $DISK"
  run sgdisk --zap-all "$DISK"
  run sgdisk -n1:0:+2G -t1:ef00 -c1:EFI "$DISK"
  run sgdisk -n2:0:0 -t2:8309 -c2:cryptroot "$DISK"
  run partprobe "$DISK"
  run udevadm settle
  if ! sim; then
    local i
    for i in $(seq 1 20); do [[ -b $ESP && -b $LUKS ]] && break; sleep 0.5; done
    [[ -b $ESP && -b $LUKS ]] || die "Partitions $ESP / $LUKS did not appear."
  fi
  run wipefs -af "$ESP" "$LUKS"
  run mkfs.fat -F32 -n EFI "$ESP"

  step "Encrypting $LUKS (LUKS2)"
  printf '%s+ cryptsetup luksFormat --type luks2 %s%s\n' "$DIM" "$LUKS" "$RST"
  printf '%s+ cryptsetup open --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent %s %s%s\n' "$DIM" "$LUKS" "$MAPPER" "$RST"
  if ! ((DRY)); then
    printf '%s' "$LUKS_PW" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$LUKS"
    printf '%s' "$LUKS_PW" | cryptsetup open --key-file - --allow-discards \
      --perf-no_read_workqueue --perf-no_write_workqueue --persistent "$LUKS" "$MAPPER"
  fi
  unset LUKS_PW

  step "Creating Btrfs and subvolumes"
  local dev=/dev/mapper/$MAPPER sv
  run mkfs.btrfs -f -L arch "$dev"
  run mount "$dev" "$T"
  for sv in "${SUBVOLS[@]}"; do run btrfs subvolume create "$T/$sv"; done
  run umount "$T"
  mount_target
}

do_base() {
  step "Installing the base system"
  run sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
  retry run pacman -Sy --noconfirm --needed archlinux-keyring
  if [[ -n $MIRRORS ]]; then
    if ! run reflector --country "$MIRRORS" --protocol https --latest 15 --sort rate --save /etc/pacman.d/mirrorlist; then
      warn "reflector failed; keeping the current mirror list."
    fi
  fi
  local -a pk=("${PK_BASE[@]}")
  [[ -n $UCODE ]] && pk+=("$UCODE")
  retry run pacstrap -K "$T" "${pk[@]}"

  step "Writing fstab (by subvolume name, not ID)"
  if ((DRY)); then
    printf '%s+ genfstab -U %s > %s/etc/fstab%s\n' "$DIM" "$T" "$T" "$RST"
  else
    genfstab -U "$T" > "$T/etc/fstab"
  fi
  run sed -i 's/subvolid=[0-9]*,//' "$T/etc/fstab"
}

do_config() {
  step "Time, locale, console, host name"
  in_chroot ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  in_chroot hwclock --systohc
  run sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$T/etc/locale.gen"
  in_chroot locale-gen
  put /etc/locale.conf 644 <<EOF
LANG=$LOCALE
EOF
  put /etc/vconsole.conf 644 <<EOF
KEYMAP=$KEYMAP
FONT=ter-v22b
EOF
  put /etc/hostname 644 <<EOF
$HOST_NAME
EOF

  step "Keyboard layouts: $XKB_LAYOUTS, Ctrl+Shift switches"
  put /etc/xdg/kxkbrc 644 <<EOF
[Layout]
Use=true
LayoutList=$XKB_LAYOUTS
Options=grp:ctrl_shift_toggle
ResetOldOptions=true
EOF
  put /etc/X11/xorg.conf.d/00-keyboard.conf 644 <<EOF
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "$XKB_LAYOUTS"
        Option "XkbOptions" "grp:ctrl_shift_toggle"
EndSection
EOF

  step "Shell defaults for new users"
  put /etc/skel/.zshrc 644 <<'EOF'
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt hist_ignore_all_dups share_history auto_cd interactive_comments
bindkey -e
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

export EDITOR=nano
export PATH="$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:$PATH"
PROMPT='%F{cyan}%n@%m%f %F{blue}%~%f %# '

alias ls='ls --color=auto' ll='ls -lah' grep='grep --color=auto'

for f in \
  /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh \
  /usr/share/fzf/key-bindings.zsh \
  /usr/share/fzf/completion.zsh \
  /usr/share/doc/pkgfile/command-not-found.zsh \
  /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
do
  [[ -r $f ]] && source "$f"
done
unset f
(( $+commands[zoxide] )) && eval "$(zoxide init zsh)"
(( $+commands[direnv] )) && eval "$(direnv hook zsh)"
EOF

  step "Accounts"
  if ((DRY)) || ! arch-chroot "$T" id "$USER_NAME" >/dev/null 2>&1; then
    in_chroot useradd -m -G wheel -s /usr/bin/zsh "$USER_NAME"
  fi
  printf '%s+ chpasswd (root, %s)%s\n' "$DIM" "$USER_NAME" "$RST"
  if ! ((DRY)); then
    printf '%s:%s\n%s:%s\n' root "$ROOT_PW" "$USER_NAME" "$USER_PW" | arch-chroot "$T" chpasswd
  fi
  unset USER_PW ROOT_PW
  put /etc/sudoers.d/10-wheel 440 <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
  in_chroot visudo -c

  step "pacman: colour, parallel downloads, multilib"
  run sed -i 's/^#Color/Color/; s/^#\?ParallelDownloads.*/ParallelDownloads = 10/' "$T/etc/pacman.conf"
  run sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$T/etc/pacman.conf"
  if [[ -n $MIRRORS ]]; then
    put /etc/xdg/reflector/reflector.conf 644 <<EOF
--save /etc/pacman.d/mirrorlist
--protocol https
--country $MIRRORS
--latest 15
--sort rate
EOF
  fi
  retry in_chroot pacman -Syu --noconfirm
}

do_tuning() {
  step "zram, VM and build tuning"
  put /etc/systemd/zram-generator.conf 644 <<'EOF'
[zram0]
zram-size = min(ram / 2, 16384)
compression-algorithm = zstd
EOF
  put /etc/sysctl.d/99-vm-zram-parameters.conf 644 <<'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
  put /etc/sysctl.d/90-dev-limits.conf 644 <<'EOF'
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
EOF
  put /etc/makepkg.conf.d/10-jobs.conf 644 <<'EOF'
MAKEFLAGS="--jobs=$(nproc)"
EOF
  if ((WANT_OOMD)); then
    put /etc/systemd/system/user@.service.d/10-oomd.conf 644 <<'EOF'
[Service]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
EOF
    put /etc/systemd/system/-.slice.d/10-oomd.conf 644 <<'EOF'
[Slice]
ManagedOOMSwap=kill
EOF
  fi
}

do_gpu_initramfs() {
  local modules="vfat" hooks
  if ((WANT_NVIDIA)); then
    step "NVIDIA driver (open kernel modules via DKMS, both kernels)"
    pac "${PK_NVIDIA[@]}"
    modules="nvidia nvidia_modeset nvidia_uvm nvidia_drm vfat"
    hooks="base udev keyboard autodetect microcode modconf keymap consolefont block encrypt filesystems fsck grub-btrfs-overlayfs"
  else
    hooks="base udev keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck grub-btrfs-overlayfs"
    if has_gpu 0x1002; then step "AMD GPU: Vulkan driver"; pac vulkan-radeon; fi
    if has_gpu 0x8086; then step "Intel GPU: Vulkan driver"; pac vulkan-intel; fi
  fi
  if [[ $VIRT == kvm || $VIRT == qemu ]]; then
    step "Virtual machine guest tools"
    pac "${PK_VM_GUEST[@]}"
  fi
  step "Initramfs"
  put /etc/mkinitcpio.conf.d/10-workstation.conf 644 <<EOF
MODULES=($modules)
HOOKS=($hooks)
EOF
  in_chroot mkinitcpio -P
}

do_software() {
  step "KDE Plasma, PipeWire and system tools"
  pac "${PK_DESKTOP[@]}"
  pac "${PK_SYSTEM[@]}" "${PK_REMOTE[@]}"
  if ((WANT_BT)); then pac "${PK_BLUETOOTH[@]}"; fi
  if ((WANT_PRINT)); then
    step "Printing"
    pac "${PK_PRINT[@]}"
    if ((DRY)) || ! grep -q mdns_minimal "$T/etc/nsswitch.conf"; then
      run sed -i 's/^hosts: mymachines /hosts: mymachines mdns_minimal [NOTFOUND=return] /' "$T/etc/nsswitch.conf"
    fi
    in_chroot firewall-offline-cmd --zone=public --add-service=mdns
  fi

  step "Fonts and font rendering"
  pac "${PK_FONTS[@]}"
  in_chroot ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d/
  put /etc/fonts/local.conf 644 <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias><family>sans-serif</family><prefer><family>Noto Sans</family></prefer></alias>
  <alias><family>serif</family><prefer><family>Noto Serif</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>JetBrains Mono</family></prefer></alias>
</fontconfig>
EOF

  if ((WANT_MEDIA)); then
    step "mpv and codecs"
    pac "${PK_MEDIA[@]}"
    put /etc/mpv/mpv.conf 644 <<'EOF'
hwdec=auto-safe
EOF
  fi
  if ((WANT_PRISM)); then
    step "Prism Launcher"
    pac "${PK_PRISM[@]}"
  fi
  if ((WANT_DEV)); then
    step "Developer toolchains"
    pac "${PK_DEV[@]}"
  fi
  if ((WANT_CONTAINERS)); then
    step "Docker, Podman, Kubernetes CLI"
    pac "${PK_CONTAINERS[@]}"
  fi
  if [[ -n $EXTRA_PKGS ]]; then
    step "Extra packages"
    local p
    local -a found=() missing=()
    for p in $EXTRA_PKGS; do
      if ((DRY)) || arch-chroot "$T" pacman -Si "$p" >/dev/null 2>&1; then found+=("$p"); else missing+=("$p"); fi
    done
    if ((${#found[@]})); then pac "${found[@]}"; fi
    if ((${#missing[@]})); then
      warn "Not in the repositories, skipped: ${missing[*]}"
      printf '%s\n' "${missing[@]}" > "$STATE_DIR/skipped-packages"
    fi
  fi
}

do_services() {
  step "Enabling services"
  local -a units=(NetworkManager.service systemd-timesyncd.service fstrim.timer plasmalogin.service
    firewalld.service power-profiles-daemon.service paccache.timer pkgfile-update.timer
    "btrfs-scrub@-.timer")
  [[ -n $MIRRORS ]] && units+=(reflector.timer)
  ((WANT_BT)) && units+=(bluetooth.service)
  ((WANT_PRINT)) && units+=(cups.socket avahi-daemon.service)
  ((WANT_OOMD)) && units+=(systemd-oomd.service)
  ((WANT_CONTAINERS)) && units+=(docker.socket)
  in_chroot systemctl enable "${units[@]}"
}

do_bootloader() {
  step "GRUB"
  local uuid=DRY-RUN-UUID
  ((DRY)) || uuid=$(blkid -s UUID -o value "$LUKS")
  [[ -n $uuid ]] || die "Could not read the LUKS UUID of $LUKS."
  run sed -i \
    -e 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet zswap.enabled=0"|' \
    -e "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${uuid}:${MAPPER}\"|" \
    "$T/etc/default/grub"
  if ((DRY)); then
    printf '%s+ append GRUB_TOP_LEVEL to /etc/default/grub%s\n' "$DIM" "$RST"
  else
    grep -q '^GRUB_TOP_LEVEL=' "$T/etc/default/grub" \
      || echo 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux-zen"' >> "$T/etc/default/grub"
  fi
  in_chroot grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  in_chroot grub-install --target=x86_64-efi --efi-directory=/boot --removable
}

do_snapshots() {
  step "Snapshots: snapper, snap-pac, grub-btrfs, /boot mirror"
  pac "${PK_SNAPSHOTS[@]}"
  in_chroot install -D -m 640 /usr/share/snapper/config-templates/default /etc/snapper/configs/root
  run sed -i \
    -e 's|^SUBVOLUME=.*|SUBVOLUME="/"|' -e 's|^FSTYPE=.*|FSTYPE="btrfs"|' \
    -e 's|^TIMELINE_LIMIT_HOURLY=.*|TIMELINE_LIMIT_HOURLY="5"|' \
    -e 's|^TIMELINE_LIMIT_DAILY=.*|TIMELINE_LIMIT_DAILY="7"|' \
    -e 's|^TIMELINE_LIMIT_WEEKLY=.*|TIMELINE_LIMIT_WEEKLY="0"|' \
    -e 's|^TIMELINE_LIMIT_MONTHLY=.*|TIMELINE_LIMIT_MONTHLY="0"|' \
    -e 's|^TIMELINE_LIMIT_YEARLY=.*|TIMELINE_LIMIT_YEARLY="0"|' \
    -e 's|^NUMBER_LIMIT=.*|NUMBER_LIMIT="20"|' \
    "$T/etc/snapper/configs/root"
  run sed -i 's|^SNAPPER_CONFIGS=.*|SNAPPER_CONFIGS="root"|' "$T/etc/conf.d/snapper"
  run chmod 750 "$T/.snapshots"

  local when name
  for when in Pre Post; do
    name=04-bootbackup-pre.hook
    [[ $when == Post ]] && name=95-bootbackup-post.hook
    put "/etc/pacman.d/hooks/$name" 644 <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Mirroring /boot to /.bootbackup (${when,,})...
When = ${when}Transaction
Depends = rsync
Exec = /usr/bin/sh -c 'mountpoint -q /boot && exec rsync -a --delete /boot/ /.bootbackup/'
EOF
  done

  in_chroot systemctl enable snapper-timeline.timer snapper-cleanup.timer grub-btrfsd.service
  in_chroot grub-mkconfig -o /boot/grub/grub.cfg
  in_chroot rsync -a --delete /boot/ /.bootbackup/
  if ((DRY)) || ! arch-chroot "$T" snapper --no-dbus -c root list 2>/dev/null | grep -q "Fresh install"; then
    in_chroot snapper --no-dbus -c root create --description "Fresh install (archws)"
  fi
  in_chroot grub-mkconfig -o /boot/grub/grub.cfg
  in_chroot rsync -a --delete /boot/ /.bootbackup/
}

do_finish() {
  step "Finishing"
  local self
  self=$(readlink -f "${BASH_SOURCE[0]}")
  run install -D -m 755 "$self" "$T/usr/local/bin/archws"
  put "/home/$USER_NAME/.config/autostart/archws-post.desktop" 644 <<'EOF'
[Desktop Entry]
Type=Application
Name=archws post-install
Exec=konsole --hold -e archws post
X-KDE-autostart-after=panel
EOF
  in_chroot chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config"
}

cmd_install() {
  MODE=install
  if ! sim && [[ ! -t 0 ]]; then die "Run this from a file in a terminal, not through a pipe."; fi
  printf '%sarchws %s%s - Arch Linux workstation installer\n' "$B" "$VERSION" "$RST"
  unset "${ANSWER_KEYS[@]}"
  if [[ -n $CONFIG_IN ]]; then load_answers "$CONFIG_IN"; fi
  if ((RESUME)); then
    preflight_local resume
    resume_prepare
    network_up
  else
    preflight_local fresh
    mullvad_ask
    network_up
    gather
  fi
  stage disk       do_disk
  stage base       do_base
  ((DRY)) || start_log
  stage config     do_config
  stage tuning     do_tuning
  stage gpu        do_gpu_initramfs
  stage software   do_software
  stage mullvad    do_mullvad_target
  stage services   do_services
  stage bootloader do_bootloader
  stage snapshots  do_snapshots
  stage finish     do_finish

  local skipped=""
  if [[ -f $STATE_DIR/skipped-packages ]]; then skipped=$(tr '\n' ' ' < "$STATE_DIR/skipped-packages"); fi
  step "Unmounting"
  LOG=""
  run umount -R "$T"
  run cryptsetup close "$MAPPER"
  if ((USE_MULLVAD)); then
    run mullvad account logout || warn "Could not log out; remove this device on your Mullvad account page."
  fi
  cat <<EOF

${B}${GRN}Installation finished.${RST}

  1. Remove the USB stick and reboot:   reboot
  2. GRUB's first entry boots linux-zen. Enter the disk passphrase.
  3. Log in to Plasma. A terminal opens with the post-install assistant
     (Flatpak apps, Cursor, k3s). You can also start it later:  archws post
  4. Health check at any time:  archws verify
  5. If an update ever breaks the system:  sudo archws rollback

  On the new system: install log /var/log/archws-install.log,
  your answers (for a reinstall with --config) /var/lib/archws/answers.conf
EOF
  if ((USE_MULLVAD && MULLVAD_ON_TARGET)); then
    echo "  Mullvad is installed with lockdown mode on: the new system has no network until"
    echo "  'archws post' has asked for your account number and connected."
  fi
  if [[ -n $skipped ]]; then warn "Extra packages that were not found and were skipped: $skipped"; fi
}

cmd_post() {
  MODE=post
  [[ $EUID -ne 0 ]] || die "Run 'archws post' as your normal user, not as root."
  printf '%sarchws post%s - apps and services that are set up after first boot\n' "$B" "$RST"
  ((DRY)) || sudo -v || die "sudo is required."
  post_mullvad
  ((DRY)) || ping -c1 -W5 archlinux.org >/dev/null 2>&1 || die "No network. Connect with the network applet first."

  step "Desktop settings"
  if have gsettings; then
    run gsettings set org.gnome.desktop.interface font-antialiasing rgba
    run gsettings set org.gnome.desktop.interface font-hinting slight
  fi
  have xdg-user-dirs-update && run xdg-user-dirs-update
  if have npm; then run npm config set prefix "$HOME/.local"; fi
  if have rustup && ! rustup toolchain list 2>/dev/null | grep -q stable; then
    if ask_yn "Install the stable Rust toolchain with rustup?" Y; then run rustup default stable; fi
  fi

  if have flatpak; then
    step "Flatpak apps (Flathub)"
    local entry id label def status rest
    for entry in "${FLATPAK_APPS[@]}"; do
      id=${entry%%|*}; rest=${entry#*|}
      label=${rest%%|*}; rest=${rest#*|}
      def=${rest%%|*}; status=${rest#*|}
      if ask_yn "$label [$status]?" "$def"; then
        retry run sudo flatpak install -y --noninteractive flathub "$id"
      fi
    done
  fi

  step "Cursor (vendor AppImage; not in Arch repos, not on Flathub)"
  if ask_yn "Download Cursor to ~/Applications?" Y; then
    local url=""
    if ((DRY)); then
      url="https://downloads.cursor.com/dry-run/Cursor-x86_64.AppImage"
    else
      url=$(curl -fsS 'https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable' | jq -r .downloadUrl)
    fi
    info "Download URL: $url"
    case $url in
      https://downloads.cursor.com/*-x86_64.AppImage)
        run mkdir -p "$HOME/Applications"
        run curl -fL --output-dir "$HOME/Applications" -O "$url"
        run chmod +x "$HOME/Applications/${url##*/}"
        info "Start it with: ~/Applications/${url##*/}"
        info "If it complains about libfuse.so.2: sudo pacman -S --needed fuse2"
        ;;
      *) warn "Unexpected download host; not fetching. Get it from cursor.com manually." ;;
    esac
  fi

  if have docker; then
    step "Docker"
    info "Members of the docker group can become root without a password."
    info "Published ports bypass firewalld: bind to loopback, e.g. -p 127.0.0.1:8080:80."
    if ask_yn "Add $USER to the docker group anyway?" N; then
      run sudo usermod -aG docker "$USER"
      info "Log out and back in for the group to apply."
    fi
  fi

  if have kubectl; then
    step "k3s (vendor install script; not in Arch repos)"
    if ask_yn "Install k3s?" Y; then post_k3s; fi
  fi

  step "Baseline snapshot"
  run sudo snapper -c root create --description "After archws post"
  run rm -f "$HOME/.config/autostart/archws-post.desktop"

  echo
  cmd_verify || true
  cat <<EOF

Next, in System Settings:
  Display & Monitor  -> resolution, refresh rate and scale per monitor (100% for 27" 1440p)
  Text & Fonts       -> Noto Sans 10 / JetBrains Mono 10, sub-pixel RGB, slight hinting
EOF
}

post_k3s() {
  local disable_ingress=1 script="$HOME/k3s-install.sh"
  if ask_yn "Keep the bundled Traefik ingress and ServiceLB disabled (they publish ports 80/443 on all addresses)?" Y; then
    disable_ingress=1
  else
    disable_ingress=0
  fi
  run sudo install -d -m 0755 /etc/rancher/k3s
  if ((disable_ingress)); then
    sput /etc/rancher/k3s/config.yaml 644 <<'EOF'
write-kubeconfig-mode: "0600"
disable:
  - servicelb
  - traefik
EOF
  else
    sput /etc/rancher/k3s/config.yaml 644 <<'EOF'
write-kubeconfig-mode: "0600"
EOF
  fi
  retry run curl -fsSLo "$script" https://get.k3s.io
  info "Saved the vendor script to $script. It verifies the k3s binary's SHA-256 itself."
  if ask_yn "Read it in a pager before it runs?" Y; then run_tty less "$script"; fi
  if ! ask_yn "Run it now (installs /usr/local/bin/k3s, not enabled at boot)?" Y; then
    info "Skipped. Run later: sudo env INSTALL_K3S_CHANNEL=stable INSTALL_K3S_SKIP_ENABLE=true sh $script"
    return 0
  fi
  run sudo env INSTALL_K3S_CHANNEL=stable INSTALL_K3S_SKIP_ENABLE=true sh "$script"
  run sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
  run sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
  run sudo firewall-cmd --reload
  if ask_yn "Start k3s at every boot? (No = start it by hand with: sudo systemctl start k3s)" N; then
    run sudo systemctl enable k3s
  fi
  if ask_yn "Start it now and write ~/.kube/config?" Y; then
    run sudo systemctl start k3s
    if ! ((DRY)); then
      local i
      for i in $(seq 1 60); do sudo test -s /etc/rancher/k3s/k3s.yaml && break; sleep 2; done
      mkdir -p "$HOME/.kube"
      # shellcheck disable=SC2024
      if [[ -e $HOME/.kube/config ]]; then
        warn "$HOME/.kube/config exists; writing $HOME/.kube/k3s.yaml instead."
        (umask 077; sudo k3s kubectl config view --raw > "$HOME/.kube/k3s.yaml")
      else
        (umask 077; sudo k3s kubectl config view --raw > "$HOME/.kube/config")
      fi
    fi
    info "Stop the cluster completely with: sudo systemctl stop k3s && sudo /usr/local/bin/k3s-killall.sh"
  fi
}

RB_TOP=""; RB_ESP_TMP=""
rb_close() {
  if [[ -n $RB_TOP ]] && mountpoint -q "$RB_TOP"; then umount "$RB_TOP" || true; fi
  if [[ -n $RB_TOP && -d $RB_TOP ]]; then rmdir "$RB_TOP" 2>/dev/null || true; fi
  if [[ -n $RB_ESP_TMP ]] && mountpoint -q "$RB_ESP_TMP"; then umount "$RB_ESP_TMP" || true; fi
  if [[ -n $RB_ESP_TMP && -d $RB_ESP_TMP ]]; then rmdir "$RB_ESP_TMP" 2>/dev/null || true; fi
  RB_TOP=""; RB_ESP_TMP=""
  return 0
}
rb_open() {
  local dev=${ARCHWS_ROOTDEV:-/dev/mapper/$MAPPER} opts=subvolid=5
  RB_BOOT=${ARCHWS_BOOT:-/boot}
  if [[ ! -e $dev ]]; then
    [[ -d /run/archiso ]] || die "$dev does not exist. Is the encrypted disk unlocked?"
    info "Arch ISO: unlocking the disk and mounting its ESP."
    pick_disk
    set_partitions
    run_tty cryptsetup open "$LUKS" "$MAPPER"
    RB_ESP_TMP=$(mktemp -d /run/archws-esp.XXXXXX)
    mount "$ESP" "$RB_ESP_TMP"
    RB_BOOT=$RB_ESP_TMP
  fi
  ((DRY)) && opts=subvolid=5,ro
  RB_TOP=$(mktemp -d /run/archws-top.XXXXXX)
  mount -o "$opts" "$dev" "$RB_TOP"
  [[ -d $RB_TOP/@ && -d $RB_TOP/@snapshots ]] \
    || die "This filesystem has no @ and @snapshots subvolumes; not an archws layout."
}
rb_field() { sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" "$2" | head -n1; }
rb_list() {
  local n x bb
  local -a nums=()
  mapfile -t nums < <(find "$RB_TOP/@snapshots" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -printf '%f\n' | sort -n)
  printf '  %-5s %-7s %-20s %-6s %s\n' "No." "Type" "Date (UTC)" "/boot" "Description"
  for n in "${nums[@]}"; do
    x="$RB_TOP/@snapshots/$n/info.xml"
    [[ -f $x && -d $RB_TOP/@snapshots/$n/snapshot ]] || continue
    bb=no; [[ -f $RB_TOP/@snapshots/$n/snapshot/.bootbackup/vmlinuz-linux-zen ]] && bb=yes
    printf '  %-5s %-7s %-20s %-6s %s\n' "$n" "$(rb_field type "$x")" "$(rb_field date "$x")" "$bb" "$(rb_field description "$x")"
  done
  local -a old=()
  mapfile -t old < <(find "$RB_TOP" -mindepth 1 -maxdepth 1 -type d -name '@.broken-*' -printf '%f\n' | sort)
  if ((${#old[@]})); then
    echo "  Old roots kept by earlier rollbacks (delete with: archws rollback --cleanup):"
    printf '    %s\n' "${old[@]}"
  fi
}

rb_do() {
  local want=${1-} snap stamp broken has_boot=0 confirm=""
  rb_list
  [[ -n $want ]] || ask want "Roll back to snapshot number"
  [[ $want =~ ^[0-9]+$ && -d $RB_TOP/@snapshots/$want/snapshot ]] || die "Snapshot '$want' does not exist."
  snap="$RB_TOP/@snapshots/$want/snapshot"
  [[ -f $snap/.bootbackup/vmlinuz-linux-zen ]] && has_boot=1
  if ((has_boot)); then
    if [[ -z ${ARCHWS_BOOT-} ]] && ! mountpoint -q "$RB_BOOT"; then
      die "$RB_BOOT is not a mounted ESP; refusing to restore kernels into it."
    fi
  else
    warn "Snapshot $want has no /.bootbackup, so the kernels on the ESP stay as they are."
    warn "If the snapshot expects other kernel versions, boot linux-lts afterwards or reinstall the kernels."
  fi
  cat <<EOF

  Snapshot $want replaces the root subvolume @: installed packages and all of /etc go back to
  that point. /home, logs, the package cache and container data are separate subvolumes and
  are not touched. The current root is kept as @.broken-<timestamp> until you delete it.
  /boot: $( ((has_boot)) && echo "kernels and initramfs images are restored from the snapshot" || echo "left unchanged" )
EOF
  ask confirm "Type 'rollback' to continue"
  [[ $confirm == rollback ]] || die "Not confirmed. Nothing was changed."

  stamp=$(date +%Y%m%d-%H%M%S); broken="@.broken-$stamp"
  run mv "$RB_TOP/@" "$RB_TOP/$broken"
  if ! run btrfs subvolume snapshot "$snap" "$RB_TOP/@"; then
    warn "Creating the new root failed; putting the previous one back."
    mv "$RB_TOP/$broken" "$RB_TOP/@"
    die "Rollback aborted. Nothing was changed."
  fi
  if ((has_boot)); then run rsync -a -c --delete "$snap/.bootbackup/" "$RB_BOOT/"; fi
  run rm -f "$RB_TOP/@/var/lib/pacman/db.lck"
  rb_close
  if ((DRY)); then info "dry run: nothing was changed."; return 0; fi
  cat <<EOF

${B}${GRN}Rollback prepared.${RST} The previous root is kept as $broken.

  1. Reboot now:                         reboot
  2. After the reboot, bring the boot files in line:   sudo archws rollback --finish
  3. Once you are sure everything works:               sudo archws rollback --cleanup
EOF
}

rb_cleanup() {
  local name current
  local -a old=()
  mapfile -t old < <(find "$RB_TOP" -mindepth 1 -maxdepth 1 -type d -name '@.broken-*' -printf '%f\n' | sort)
  if ((${#old[@]} == 0)); then info "No old roots to delete."; return 0; fi
  current=$(findmnt -no OPTIONS / 2>/dev/null | tr ',' '\n' | sed -n 's|^subvol=/||p' | head -n1)
  for name in "${old[@]}"; do
    if [[ $name == "$current" ]]; then
      warn "$name is the root you are running from (reboot first); skipping."
      continue
    fi
    if ask_yn "Permanently delete $name?" N; then
      run btrfs subvolume delete -R "$RB_TOP/$name"
    fi
  done
}

cmd_rollback() {
  MODE=rollback
  local action=apply want="" a
  for a in "$@"; do
    case $a in
      --list)    action=list ;;
      --finish)  action=finish ;;
      --cleanup) action=cleanup ;;
      *) if [[ $a =~ ^[0-9]+$ ]]; then want=$a; else die "Unknown rollback option: $a"; fi ;;
    esac
  done
  [[ $EUID -eq 0 ]] || die "Run it as root: sudo archws rollback"
  printf '%sarchws rollback%s\n' "$B" "$RST"
  if [[ $action == finish ]]; then
    step "Rebuilding initramfs images and the GRUB menu for the restored system"
    run mkinitcpio -P
    run grub-mkconfig -o /boot/grub/grub.cfg
    info "Done. Check the result with: archws verify"
    return 0
  fi
  trap rb_close EXIT
  rb_open
  case $action in
    list)    rb_list ;;
    cleanup) rb_cleanup ;;
    apply)   rb_do "$want" ;;
  esac
  rb_close
}

PASS=0; FAIL=0; WARNED=0
ok()   { printf '  %s[ ok ]%s %s\n' "$GRN" "$RST" "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$1"; FAIL=$((FAIL + 1)); }
note() { printf '  %s[warn]%s %s\n' "$YLW" "$RST" "$1"; WARNED=$((WARNED + 1)); }
t()    { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
w()    { if eval "$2" >/dev/null 2>&1; then ok "$1"; else note "$1"; fi; }

all_enabled() { local u; for u in "$@"; do systemctl is-enabled -q "$u" || return 1; done; }

cmd_verify() {
  MODE=verify
  printf '%sarchws verify%s\n' "$B" "$RST"
  if ((DRY)); then info "dry run: checks skipped"; return 0; fi
  sudo -v 2>/dev/null || warn "No sudo: some checks will fail."

  echo "Boot, kernel, storage"
  t "running linux-zen or linux-lts"            '[[ $(uname -r) == *-zen || $(uname -r) == *-lts ]]'
  t "kernel command line unlocks by LUKS UUID"  '[[ $(sudo blkid -t TYPE=crypto_LUKS -s UUID -o value | head -n1) == "$(grep -o "cryptdevice=UUID=[^: ]*" /proc/cmdline | cut -d= -f3)" ]]'
  t "root is Btrfs subvolume @"                 'findmnt -no OPTIONS / | grep -q "subvol=/@\(,\|$\)"'
  t "noatime + zstd compression on /"           'findmnt -no OPTIONS / | grep -q noatime && findmnt -no OPTIONS / | grep -q compress=zstd'
  t "fstab mounts by subvolume name, not ID"    '! grep -q subvolid /etc/fstab'
  t "LUKS: discards + workqueue bypass"         'sudo cryptsetup status cryptroot | grep flags | grep -q discards && sudo cryptsetup status cryptroot | grep flags | grep -q no_read_workqueue'
  t "/boot is the ESP (vfat) and mounted"       '[[ $(findmnt -no FSTYPE /boot) == vfat ]]'
  t "initramfs carries vfat + overlay hook"     'lsinitcpio /boot/initramfs-linux-zen.img 2>/dev/null | grep -q "/vfat\.ko" || sudo lsinitcpio /boot/initramfs-linux-zen.img | grep -q "/vfat\.ko"'
  t "linux-zen is GRUB top-level entry"         '[[ $(sudo grep -m1 -o "vmlinuz-linux[a-z-]*" /boot/grub/grub.cfg) == vmlinuz-linux-zen ]]'
  w "no old root left from a rollback"          '[[ -z $(sudo btrfs subvolume list / | grep -o "@\.broken-[0-9-]*$" | head -n1) ]]'

  echo "Memory"
  t "zram is the swap device"                   'swapon --show=NAME --noheadings | grep -q zram'
  t "zswap is disabled"                         '[[ $(cat /sys/module/zswap/parameters/enabled) == N ]]'
  t "vm.swappiness = 180"                       '[[ $(sysctl -n vm.swappiness) == 180 ]]'
  w "systemd-oomd active (optional)"            'systemctl is-active -q systemd-oomd'

  echo "Graphics and desktop"
  if pacman -Qq nvidia-utils >/dev/null 2>&1; then
    t "NVIDIA driver answers (nvidia-smi)"      'nvidia-smi -L | grep -q GPU'
    t "nvidia_drm modeset enabled"              '[[ $(cat /sys/module/nvidia_drm/parameters/modeset) == Y ]]'
    t "DKMS module built for both kernels"      '[[ $(dkms status | grep -c "nvidia.*installed") -ge 2 ]]'
    t "nvidia-suspend service stays disabled"   '! systemctl is-enabled -q nvidia-suspend.service'
  fi
  t "interface language is English only"        'grep -qx "LANG=en_US.UTF-8" /etc/locale.conf && [[ $(locale -a | grep -c "_.*utf8") -eq 1 ]]'
  w "layouts + Ctrl+Shift switch (system default)" 'grep -q "^LayoutList=.*,." /etc/xdg/kxkbrc && grep -q "grp:ctrl_shift_toggle" /etc/xdg/kxkbrc'
  w "Wayland session (run inside Plasma)"       '[[ ${XDG_SESSION_TYPE:-} == wayland ]]'
  t "login manager enabled (plasmalogin)"       'systemctl is-enabled -q plasmalogin.service'
  w "PipeWire serves PulseAudio clients"        'pactl info | grep -q "on PipeWire"'
  t "firewalld running, default zone public"    '[[ $(sudo firewall-cmd --get-default-zone) == public ]]'
  t "fontconfig: RGB sub-pixel, slight hinting" 'fc-match -v sans-serif | grep -q "rgba: 1" && fc-match -v sans-serif | grep -q "hintstyle: 1"'
  t "monospace resolves to JetBrains Mono"      'fc-match monospace | grep -qi jetbrains'
  t "Cyrillic resolves to Noto Sans"            'fc-match "sans-serif:lang=ru" | grep -qi noto'

  echo "Snapshots"
  t "/.snapshots is @snapshots, mode 750"       'findmnt -no SOURCE /.snapshots | grep -q "\[/@snapshots\]" && [[ $(stat -c %a /.snapshots) == 750 ]]'
  t "snapper config 'root' exists"              'sudo snapper list-configs | grep -q "^root"'
  t "at least one snapshot"                     '[[ $(sudo snapper -c root list | grep -c "^ *[0-9]") -ge 2 ]]'
  t "timeline, cleanup, grub-btrfsd enabled"    'all_enabled snapper-timeline.timer snapper-cleanup.timer grub-btrfsd.service'
  t "/boot mirror hooks installed"              '[[ -f /etc/pacman.d/hooks/04-bootbackup-pre.hook && -f /etc/pacman.d/hooks/95-bootbackup-post.hook ]]'
  t "/.bootbackup holds both kernels"           'sudo test -f /.bootbackup/vmlinuz-linux-zen && sudo test -f /.bootbackup/vmlinuz-linux-lts'
  w "GRUB menu has the snapshots submenu"       'sudo grep -q grub-btrfs.cfg /boot/grub/grub.cfg'

  echo "Services and packages"
  t "NetworkManager, timesyncd, fstrim enabled" 'all_enabled NetworkManager.service systemd-timesyncd.service fstrim.timer'
  t "monthly Btrfs scrub enabled"               'systemctl is-enabled -q "btrfs-scrub@-.timer"'
  t "sshd is not enabled"                       '! systemctl is-enabled -q sshd.service'
  if pacman -Qq docker >/dev/null 2>&1; then
    t "Docker: socket enabled, service not"     'systemctl is-enabled -q docker.socket && ! systemctl is-enabled -q docker.service'
    w "user is not in the docker group"         '! id -nG | grep -qw docker'
  fi
  if [[ -x /usr/local/bin/k3s ]]; then
    w "k3s not enabled at boot"                 '! systemctl is-enabled -q k3s.service'
    t "k3s kubeconfig is root-only (600)"       '[[ ! -e /etc/rancher/k3s/k3s.yaml || $(stat -c %a /etc/rancher/k3s/k3s.yaml) == 600 ]]'
  fi
  t "no AUR packages (pacman -Qm)"              '[[ -z $(pacman -Qmq | grep -vx mullvad-vpn-vendor) ]]'
  if have mullvad; then
    w "Mullvad tunnel is connected"             'mullvad status | grep -q "^Connected"'
  fi
  t "no failed systemd units"                   '[[ -z $(systemctl --failed --no-legend) ]]'

  printf '\n%s%d passed%s, %s%d warnings%s, %s%d failed%s\n' "$GRN" "$PASS" "$RST" "$YLW" "$WARNED" "$RST" "$RED" "$FAIL" "$RST"
  ((FAIL == 0))
}

usage() {
  cat <<'EOF'
archws - interactive Arch Linux workstation installer

  archws.sh install [--dry-run] [--config FILE]   from the Arch ISO, as root
  archws.sh install --resume                      continue an install that stopped half way
  archws post       [--dry-run]                   after first boot, as your user
  archws verify                                   read-only health check
  sudo archws rollback [N] [--dry-run]            replace the root subvolume with snapshot N
  sudo archws rollback --list                     show snapshots and old roots
  sudo archws rollback --finish                   after the reboot: rebuild initramfs and GRUB menu
  sudo archws rollback --cleanup                  delete old roots kept by earlier rollbacks
EOF
}

main() {
  local cmd=${1:-help}
  shift || true
  local -a rest=()
  while (($#)); do
    case $1 in
      --dry-run)  DRY=1 ;;
      --resume)   RESUME=1 ;;
      --config)   shift; CONFIG_IN=${1-}; [[ -n $CONFIG_IN ]] || die "--config needs a file name." ;;
      --config=*) CONFIG_IN=${1#*=} ;;
      *)          rest+=("$1") ;;
    esac
    shift
  done
  case $cmd in
    install)  ((${#rest[@]} == 0)) || die "Unknown option: ${rest[0]}"; cmd_install ;;
    post)     ((${#rest[@]} == 0)) || die "Unknown option: ${rest[0]}"; cmd_post ;;
    verify)   trap - ERR; cmd_verify ;;
    rollback) cmd_rollback "${rest[@]}" ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
