#!/bin/bash
#
# Gentoo Linux LUKS Encrypted Installation Script — KDE Plasma + Flatpak
# (final, July 2026)
# Target: Framework 12 Laptop (Intel iGPU). Change VIDEO_CARDS if yours differs.
#
# Disk layout ("encryption: root only"):
#   p1: EFI System Partition (FAT32), mounted /boot  -- UNENCRYPTED
#       Holds GRUB + kernel + initramfs. GRUB never touches LUKS.
#   p2: LUKS2 (argon2id) -> btrfs (@,@home,@var,@tmp) -- ENCRYPTED root
#       Unlocked at boot by the dracut initramfs via rd.luks.uuid.
#   -> ONE passphrase prompt at boot (from the initramfs), no Argon2-in-GRUB.
#
# Desktop: KDE Plasma 6 + SDDM + Flatpak
#   * Plasma desktop with SDDM on OpenRC (elogind/dbus)
#   * KDE core apps (Dolphin, Konsole, KWrite) + common extras
#     (Ark, Okular, Gwenview, Spectacle, Kate, KCalc, Filelight)
#   * SMB/CIFS network shares in Dolphin (kio-extras[samba])
#   * Flatpak + Flathub for sandboxed app installs (Discover integration)
#   * PipeWire audio, NetworkManager, Intel microcode
#
# Binary-package first:
#   * Uses x86-64-v3 binhost when CPU supports it, baseline as fallback.
#   * FEATURES="getbinpkg"; CPU_FLAGS_X86 deliberately NOT set.
#   * USE deviations kept tiny so more binpkgs match.
#   * ACCEPT_LICENSE="*"; L10N="en-US" (satisfies REQUIRED_USE on myspell-en).
#   * Large merges use --autounmask-continue for leftover USE/license blockers.
#
# Resume: marker files in /tmp/.install_state. If the script dies partway,
# DO NOT re-run the outer script (it re-partitions). Instead:
#     chroot /mnt/gentoo /bin/bash /root/chroot-install.sh
#
# Run from the official Gentoo Live USB, as root.

set -euo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND"; exit 1' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[$(date +%T)]${NC} $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

exec > >(tee -a /root/gentoo-install.log) 2>&1
echo "=== Gentoo LUKS KDE install started at $(date) ==="

# ================================================================ pre-flight
[[ $EUID -eq 0 ]] || error "Run as root."
[[ -d /sys/firmware/efi ]] || error "Not booted in UEFI mode. Reboot the Live USB in UEFI mode."

log "Checking required tools..."
for cmd in sgdisk parted cryptsetup mkfs.vfat mkfs.btrfs wget tar mount umount chroot blkid lsblk partprobe wipefs; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "$cmd missing; attempting to emerge it on the live medium..."
        case "$cmd" in
            sgdisk)           emerge -q sys-apps/gptfdisk ;;
            parted|partprobe) emerge -q sys-block/parted ;;
            cryptsetup)       emerge -q sys-fs/cryptsetup ;;
            mkfs.vfat)        emerge -q sys-fs/dosfstools ;;
            mkfs.btrfs)       emerge -q sys-fs/btrfs-progs ;;
            wipefs)           emerge -q sys-apps/util-linux ;;
            *)                error "Missing critical tool: $cmd" ;;
        esac
    fi
done
success "Tools ready."

# ============================================== gather all user input up front
log "Available disks:"
lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -Ev 'loop|sr0' | cat

warn "!!! ALL DATA ON THE SELECTED DISK WILL BE DESTROYED !!!"
read -rp "Target disk WITHOUT /dev/ (e.g. nvme0n1): " DISK_NAME
DISK="/dev/${DISK_NAME}"
[[ -b "$DISK" ]] || error "Invalid disk: $DISK"

if [[ "$DISK_NAME" =~ (nvme|mmcblk|loop) ]]; then P="p"; else P=""; fi
EFI_PART="${DISK}${P}1"
ROOT_PART="${DISK}${P}2"

read -rp "Hostname [gentoo]: " HOSTNAME_IN;  HOSTNAME_IN="${HOSTNAME_IN:-gentoo}"
read -rp "Timezone  [UTC] (e.g. Europe/Berlin, America/New_York): " TZ_IN; TZ_IN="${TZ_IN:-UTC}"
read -rp "Your username: " USERNAME
[[ -n "$USERNAME" ]] || error "Username cannot be empty."

echo
warn "About to ERASE $DISK:"
echo "   ${EFI_PART}  -> EFI System Partition (1 GiB, FAT32, /boot, unencrypted)"
echo "   ${ROOT_PART}  -> LUKS2 encrypted root (btrfs)"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || error "Aborted."

# ================================================== partition + LUKS + btrfs
MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2,discard=async"

log "Wiping and partitioning $DISK..."
wipefs -a "$DISK" || true
sgdisk --zap-all "$DISK" || true
parted -s "$DISK" mklabel gpt
parted -s -a optimal "$DISK" mkpart ESP fat32 1MiB 1GiB
parted -s "$DISK" set 1 esp on
parted -s -a optimal "$DISK" mkpart root 1GiB 100%
partprobe "$DISK" || true; sleep 2

log "Formatting EFI System Partition..."
mkfs.vfat -F32 -n EFI "$EFI_PART"

log "Creating LUKS2 (argon2id) on $ROOT_PART -- set your passphrase now (twice)..."
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id "$ROOT_PART"
log "Unlock it once to continue:"
cryptsetup open "$ROOT_PART" cryptroot

log "Creating btrfs + subvolumes..."
mkfs.btrfs -f -L ROOT /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt/gentoo
for sv in @ @home @var @tmp; do btrfs subvolume create "/mnt/gentoo/$sv"; done
umount /mnt/gentoo

mount -o "subvol=@,$MOUNT_OPTS" /dev/mapper/cryptroot /mnt/gentoo
mkdir -p /mnt/gentoo/{home,var,tmp,boot}
mount -o "subvol=@home,$MOUNT_OPTS" /dev/mapper/cryptroot /mnt/gentoo/home
mount -o "subvol=@var,$MOUNT_OPTS"  /dev/mapper/cryptroot /mnt/gentoo/var
mount -o "subvol=@tmp,$MOUNT_OPTS"  /dev/mapper/cryptroot /mnt/gentoo/tmp
mount "$EFI_PART" /mnt/gentoo/boot
success "Partitions, LUKS, and btrfs ready."

# ========================================================== capture UUIDs
LUKS_UUID=$(cryptsetup luksUUID "$ROOT_PART")
BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
success "LUKS=$LUKS_UUID  btrfs=$BTRFS_UUID  ESP=$EFI_UUID"

mkdir -p /mnt/gentoo/tmp
printf '%s\n' "$LUKS_UUID"   > /mnt/gentoo/tmp/luks_uuid.txt
printf '%s\n' "$BTRFS_UUID"  > /mnt/gentoo/tmp/btrfs_uuid.txt
printf '%s\n' "$EFI_UUID"    > /mnt/gentoo/tmp/efi_uuid.txt
printf '%s\n' "$HOSTNAME_IN" > /mnt/gentoo/tmp/hostname.txt
printf '%s\n' "$TZ_IN"       > /mnt/gentoo/tmp/timezone.txt
printf '%s\n' "$USERNAME"    > /mnt/gentoo/tmp/username.txt
printf '%s\n' "$MOUNT_OPTS"  > /mnt/gentoo/tmp/mount_opts.txt

# ================================================================= stage3
log "Downloading stage3 (desktop, OpenRC)..."
BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-desktop-openrc"
download_stage3() {
    wget -q "${BASE}/latest-stage3-amd64-desktop-openrc.txt" -O /tmp/latest.txt || return 1
    local s3; s3=$(grep -oE 'stage3-amd64-desktop-openrc-[0-9TZ]+\.tar\.xz' /tmp/latest.txt | head -1)
    [[ -n "$s3" ]] || return 1
    wget --show-progress -O /mnt/gentoo/stage3.tar.xz "${BASE}/${s3}" || return 1
    tar -tf /mnt/gentoo/stage3.tar.xz >/dev/null 2>&1
}
if ! download_stage3; then
    warn "Automatic stage3 download failed."
    while true; do
        read -rp "Enter a full stage3 .tar.xz URL (or 'quit'): " u
        [[ "$u" == "quit" ]] && error "Aborted."
        if [[ "$u" =~ ^https://.*\.tar\.xz$ ]] \
           && wget --show-progress -O /mnt/gentoo/stage3.tar.xz "$u" \
           && tar -tf /mnt/gentoo/stage3.tar.xz >/dev/null 2>&1; then break; fi
        warn "Not a valid tarball; try again."
    done
fi
log "Extracting stage3..."
tar xpf /mnt/gentoo/stage3.tar.xz -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner
rm -f /mnt/gentoo/stage3.tar.xz
success "Stage3 extracted."

# ============================================================= chroot prep
log "Preparing chroot mounts..."
cp -L /etc/resolv.conf /mnt/gentoo/etc/resolv.conf
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys  /mnt/gentoo/sys  && mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev  /mnt/gentoo/dev  && mount --make-rslave /mnt/gentoo/dev
mount --bind  /run  /mnt/gentoo/run  && mount --make-slave  /mnt/gentoo/run
if [[ -L /mnt/gentoo/dev/shm ]]; then
    rm -f /mnt/gentoo/dev/shm && mkdir /mnt/gentoo/dev/shm
    mount -t tmpfs -o nosuid,nodev,noexec shm /mnt/gentoo/dev/shm
    chmod 1777 /mnt/gentoo/dev/shm
fi
success "Chroot ready."

# =====================================================================
#  CHROOT SCRIPT
# =====================================================================
log "Writing chroot script..."
cat > /mnt/gentoo/root/chroot-install.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
trap 'echo "CHROOT ERROR at line $LINENO: $BASH_COMMAND"; exit 1' ERR

set +u; source /etc/profile; set -u
export PS1="(chroot) ${PS1:-}"

exec > >(tee -a /root/gentoo-install.log) 2>&1
echo "=== Chroot install started at $(date) ==="

log()    { echo -e "\033[0;34m[CHROOT $(date +%T)]\033[0m $1"; }
success(){ echo -e "\033[0;32m[CHROOT OK]\033[0m $1"; }
warn()   { echo -e "\033[1;33m[CHROOT WARN]\033[0m $1"; }

STATE=/tmp/.install_state; mkdir -p "$STATE"
done_step(){ [[ -f "$STATE/$1" ]]; }
mark(){ touch "$STATE/$1"; }

LUKS_UUID=$(cat /tmp/luks_uuid.txt)
BTRFS_UUID=$(cat /tmp/btrfs_uuid.txt)
EFI_UUID=$(cat /tmp/efi_uuid.txt)
HOSTNAME_IN=$(cat /tmp/hostname.txt)
TZ_IN=$(cat /tmp/timezone.txt)
USERNAME=$(cat /tmp/username.txt)
MOUNT_OPTS=$(cat /tmp/mount_opts.txt)
CORES=$(nproc)

AUTO="--autounmask=y --autounmask-use=y --autounmask-license=y \
--autounmask-keep-keywords=y --autounmask-write=y --autounmask-continue=y"

# ---- 1. ebuild repository ----------------------------------------------
if ! done_step repo; then
    log "Setting up repos.conf and syncing the ebuild tree..."
    mkdir -p /etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf 2>/dev/null || true
    emerge-webrsync
    mark repo
fi

# ---- 2. profile (desktop/plasma, OpenRC) --------------------------------
if ! done_step profile; then
    log "Selecting the Plasma desktop profile..."
    set +e
    PROFILE=$(eselect profile list 2>/dev/null \
        | grep 'desktop/plasma' | grep -v systemd \
        | grep -oE 'default/linux/amd64/[0-9.]+/desktop/plasma\b' | head -1)
    set -e
    if [[ -n "${PROFILE:-}" ]]; then
        eselect profile set "$PROFILE"; success "Profile: $PROFILE"
    else
        warn "No plasma profile found; keeping stage3 default (desktop/openrc)."
    fi
    mark profile
fi

# ---- 3. make.conf -------------------------------------------------------
# QUOTING: heredoc is UNQUOTED (<<EOF) so bash injects real numbers.
# ${COMMON_FLAGS} escaped so Portage expands them, not bash.
# No $(...) command substitution ever lands in the file.
if ! done_step makeconf; then
    log "Writing make.conf..."
    cat > /etc/portage/make.conf <<EOF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
CHOST="x86_64-pc-linux-gnu"

MAKEOPTS="-j${CORES} -l$((CORES + 2))"

FEATURES="getbinpkg parallel-fetch clean-logs"
EMERGE_DEFAULT_OPTS="--jobs=2 --load-average=${CORES} --quiet-build=y --with-bdeps=y"

ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="amd64"

VIDEO_CARDS="intel"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="efi-64"

# Keep USE deviations minimal so more binpkgs match. The desktop/plasma
# profile already provides wayland, X, elogind, dbus, policykit, etc.
USE="pipewire"

# Satisfies REQUIRED_USE on app-dicts/myspell-en (any-of l10n_en-*).
# CPU_FLAGS_X86 deliberately NOT set so SIMD packages use binhost binaries.
L10N="en-US"
EOF
    success "make.conf written (MAKEOPTS=-j${CORES})."
    mark makeconf
fi

# ---- 4. binhost: prefer x86-64-v3, fall back to baseline ----------------
if ! done_step binhost; then
    log "Configuring the binary package host..."
    V3=no
    for ldso in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
        [[ -x "$ldso" ]] || continue
        "$ldso" --help 2>/dev/null | grep -q 'x86-64-v3 (supported' && V3=yes
        break
    done
    if [[ "$V3" == no ]] \
       && grep -qiw avx2 /proc/cpuinfo \
       && grep -qiw bmi2 /proc/cpuinfo \
       && grep -qiw fma  /proc/cpuinfo; then
        V3=yes
    fi

    mkdir -p /etc/portage/binrepos.conf
    rm -f /etc/portage/binrepos.conf/*.conf
    if [[ "$V3" == yes ]]; then
        success "CPU supports x86-64-v3 -> v3 binhost (baseline fallback)."
        cat > /etc/portage/binrepos.conf/gentoo.conf <<'EOF'
[gentoo-x86-64-v3]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64-v3/
verify-signature = true
location = /var/cache/binhost/gentoo-x86-64-v3

[gentoo]
priority = 9959
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
verify-signature = true
location = /var/cache/binhost/gentoo
EOF
    else
        warn "CPU does NOT report x86-64-v3 -> baseline binhost only."
        cat > /etc/portage/binrepos.conf/gentoo.conf <<'EOF'
[gentoo]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
verify-signature = true
location = /var/cache/binhost/gentoo
EOF
    fi
    mark binhost
fi

# ---- 5. binary-package trust anchor -------------------------------------
if ! done_step getuto; then
    log "Setting up the binary-package trust keyring..."
    emerge --quiet --oneshot app-portage/getuto || true
    getuto || true
    mark getuto
fi

# ---- 6. package.use prerequisites (BEFORE @world) -----------------------
if ! done_step pkguse; then
    log "Writing package.use entries..."
    mkdir -p /etc/portage/package.use
    echo 'sys-kernel/installkernel dracut'   > /etc/portage/package.use/installkernel
    echo 'kde-apps/kio-extras samba'         > /etc/portage/package.use/kio-extras
    mark pkguse
fi

# ---- 7. rebuild @world against the new profile --------------------------
if ! done_step world; then
    log "Updating @world (pulls binpkgs where available; the rest compiles)..."
    emerge --update --deep --newuse --with-bdeps=y $AUTO @world
    mark world
fi

# ---- 8. timezone / locale / hostname ------------------------------------
if ! done_step localetime; then
    log "Timezone=$TZ_IN, locale=en_US.UTF-8, hostname=$HOSTNAME_IN..."
    echo "$TZ_IN" > /etc/timezone
    emerge --config sys-libs/timezone-data
    printf 'en_US.UTF-8 UTF-8\nC.UTF-8 UTF-8\n' > /etc/locale.gen
    locale-gen
    eselect locale set en_US.utf8 || true
    echo "hostname=\"$HOSTNAME_IN\"" > /etc/conf.d/hostname
    set +u; env-update && source /etc/profile; set -u
    mark localetime
fi

# ---- 9. fstab (UUIDs only) ----------------------------------------------
if ! done_step fstab; then
    log "Writing /etc/fstab..."
    cat > /etc/fstab <<EOF
UUID=${EFI_UUID}    /boot  vfat   noatime,fmask=0077,dmask=0077        0 2
UUID=${BTRFS_UUID}  /      btrfs  subvol=@,${MOUNT_OPTS}               0 0
UUID=${BTRFS_UUID}  /home  btrfs  subvol=@home,${MOUNT_OPTS}           0 0
UUID=${BTRFS_UUID}  /var   btrfs  subvol=@var,${MOUNT_OPTS}            0 0
UUID=${BTRFS_UUID}  /tmp   btrfs  subvol=@tmp,${MOUNT_OPTS}            0 0
EOF
    mark fstab
fi

# ---- 10. dracut config (force crypt + btrfs into the initramfs) ----------
if ! done_step dracutconf; then
    log "Configuring dracut for LUKS + btrfs..."
    emerge --quiet sys-fs/cryptsetup sys-fs/btrfs-progs
    mkdir -p /etc/dracut.conf.d
    cat > /etc/dracut.conf.d/luks-btrfs.conf <<'EOF'
hostonly="no"
add_dracutmodules+=" crypt dm rootfs-block btrfs "
force_drivers+=" dm_crypt btrfs "
EOF
    mark dracutconf
fi

# ---- 11. binary kernel + firmware + microcode ----------------------------
if ! done_step kernel; then
    log "Installing prebuilt kernel + firmware + microcode..."
    emerge $AUTO \
        sys-kernel/installkernel \
        sys-kernel/gentoo-kernel-bin \
        sys-kernel/linux-firmware \
        sys-firmware/intel-microcode
    success "Kernel + initramfs generated."
    mark kernel
fi

# ---- 12. GRUB (EFI, unencrypted /boot) -----------------------------------
if ! done_step grub; then
    log "Installing GRUB (EFI)..."
    emerge $AUTO sys-boot/grub
    cat > /etc/default/grub <<EOF
GRUB_DISTRIBUTOR="Gentoo"
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX="rd.luks.uuid=${LUKS_UUID} root=UUID=${BTRFS_UUID} rootflags=subvol=@ rd.luks.options=discard"
GRUB_DISABLE_OS_PROBER=true
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
EOF
    grub-install --target=x86_64-efi --efi-directory=/boot \
        --bootloader-id=Gentoo --removable --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
    success "GRUB installed."
    mark grub
fi

# ---- 13. networking ------------------------------------------------------
if ! done_step network; then
    log "Installing NetworkManager..."
    emerge $AUTO net-misc/networkmanager
    mark network
fi

# ---- 14. Plasma desktop + SDDM + OpenRC glue ----------------------------
if ! done_step desktop; then
    log "Installing Plasma 6 + SDDM (binpkgs where available)..."
    emerge $AUTO \
        kde-plasma/plasma-meta \
        x11-misc/sddm \
        x11-base/xorg-server \
        gui-libs/display-manager-init \
        sys-auth/elogind \
        sys-apps/dbus \
        sys-apps/haveged \
        app-admin/sudo

    [[ -s /etc/machine-id ]] || dbus-uuidgen > /etc/machine-id
    usermod -a -G video sddm || true
    printf 'CHECKVT=7\nDISPLAYMANAGER="sddm"\n' > /etc/conf.d/display-manager
    mark desktop
fi

# ---- 15. KDE applications + SMB support ----------------------------------
if ! done_step kdeapps; then
    log "Installing KDE core apps + extras + SMB support..."
    emerge $AUTO \
        kde-apps/kdecore-meta \
        kde-apps/ark \
        kde-apps/okular \
        kde-apps/gwenview \
        kde-plasma/spectacle \
        kde-apps/kate \
        kde-apps/kcalc \
        kde-apps/filelight \
        kde-apps/kio-extras \
        kde-apps/dolphin-plugins-git \
        kde-apps/thumbnailers \
        kde-apps/ffmpegthumbs \
        net-fs/samba
    success "KDE apps + SMB installed."
    mark kdeapps
fi

# ---- 16. Flatpak + Flathub -----------------------------------------------
if ! done_step flatpak; then
    log "Installing Flatpak and adding Flathub..."
    emerge $AUTO sys-apps/flatpak
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    # KDE Discover picks up Flatpak automatically via its flatpak backend.
    success "Flatpak + Flathub configured."
    mark flatpak
fi

# ---- 17. zram swap (compressed swap in RAM) ------------------------------
if ! done_step zram; then
    log "Setting up zram compressed swap..."
    mkdir -p /etc/local.d
    cat > /etc/local.d/zram.start <<'EOF'
#!/bin/bash
modprobe zram
zramctl /dev/zram0 --size 8G --algorithm zstd
mkswap /dev/zram0
swapon /dev/zram0 -p 10
EOF
    cat > /etc/local.d/zram.stop <<'EOF'
#!/bin/bash
swapoff /dev/zram0 2>/dev/null
zramctl --reset /dev/zram0 2>/dev/null
modprobe -r zram 2>/dev/null
EOF
    chmod +x /etc/local.d/zram.start /etc/local.d/zram.stop
    success "zram swap configured (8G zstd)."
    mark zram
fi

# ---- 18. services (elogind MUST be in the boot runlevel) -----------------
if ! done_step services; then
    log "Enabling services..."
    rc-update add elogind boot
    rc-update add dbus default
    rc-update add haveged default
    rc-update add NetworkManager default
    rc-update add display-manager default
    rc-update add local default               # for zram.start/stop
    rc-update add sshd default 2>/dev/null || true
    mark services
fi

# ---- 19. sudo + user + passwords ----------------------------------------
# SUDOERS FIX: /etc/sudoers is mode 0440 (read-only even for root).
# Appending with >> or modifying with sed fails with "Permission denied."
# NEVER modify /etc/sudoers. Gentoo's sudo ships '#includedir /etc/sudoers.d'
# and creates the directory. Just write the drop-in file directly.
if ! done_step user; then
    log "Configuring sudo and creating user '$USERNAME'..."
    command -v sudo >/dev/null || emerge $AUTO app-admin/sudo

    # Safety net only; the directory should already exist from the sudo package.
    mkdir -p /etc/sudoers.d

    if ! id "$USERNAME" &>/dev/null; then
        GROUPS_ADD=""
        for g in wheel audio video input usb portage users plugdev; do
            getent group "$g" >/dev/null 2>&1 && GROUPS_ADD="${GROUPS_ADD:+$GROUPS_ADD,}$g"
        done
        useradd -m -G "$GROUPS_ADD" -s /bin/bash "$USERNAME"
    fi

    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
    chmod 0440 /etc/sudoers.d/wheel
    visudo -c   # validate; exits non-zero on error

    echo; echo ">>> Set password for USER '$USERNAME':"; passwd "$USERNAME"
    echo; echo ">>> Set password for ROOT:";            passwd root
    mark user
fi

# ---- 20. cleanup ---------------------------------------------------------
log "Depclean..."
emerge --depclean --quiet || true

echo "=== Chroot install finished at $(date) ==="
success "Done inside chroot."
CHROOT_EOF

chmod +x /mnt/gentoo/root/chroot-install.sh

# ================================================================ run chroot
# NOTE: the chroot script is resumable via markers in /tmp/.install_state.
# If it stops partway, DO NOT re-run this whole outer script (it re-partitions
# and wipes the disk). Instead re-run only the chroot part:
#     chroot /mnt/gentoo /bin/bash /root/chroot-install.sh
log "Entering chroot..."
chroot /mnt/gentoo /bin/bash /root/chroot-install.sh

success "Installation completed!"
echo
warn "Finish with:"
echo "   umount -R /mnt/gentoo"
echo "   cryptsetup close cryptroot"
echo "   reboot"
echo
echo "On boot: one LUKS passphrase prompt (from the initramfs), then SDDM."
echo "Log in as '$USERNAME'. At the session picker, 'Plasma (X11)' is the most"
echo "reliable first login on OpenRC; Wayland can be tried afterwards."
echo
echo "Post-install tips:"
echo "   * Install apps via Flatpak:  flatpak install flathub org.mozilla.firefox"
echo "   * KDE Discover shows Flatpak apps alongside system packages."
echo "   * SMB shares: type smb://server-ip/sharename in Dolphin's address bar."
echo "     Bookmark via right-click -> 'Add to Places' for quick access."
