# gentoo-install-script
Gentoo with OpenRC and luks encryption on Plasma

Target: Intel based Laptop (Intel iGPU). Change VIDEO_CARDS if yours differs.

Disk layout (matches "encryption: root only"):
 p1: EFI System Partition (FAT32), mounted /boot  -- UNENCRYPTED
      holds GRUB + kernel + initramfs. GRUB never touches LUKS.
 p2: LUKS2 (argon2id) -> btrfs (@,@home,@var,@tmp) -- ENCRYPTED root
      unlocked at boot by the dracut initramfs via rd.luks.uuid.
 -> ONE passphrase prompt at boot (from the initramfs), no Argon2-in-GRUB.

Binary-package first:
  * FEATURES="getbinpkg" pulls prebuilt packages from the official binhost.
  * Uses the x86-64-v3 binhost (more optimized) when the CPU supports it,
    with the baseline x86-64 binhost as automatic fallback.
  * We do NOT set CPU_FLAGS_X86 and we keep USE deviations tiny, because any
    USE / USE_EXPAND deviation from the binhost forces a source rebuild.
    (-march=native is fine: CFLAGS do NOT affect binpkg selection, only the
    few packages that still compile from source.)
  * ACCEPT_LICENSE="*" so no license ever blocks a merge.
  * L10N="en-US" so English-dictionary REQUIRED_USE is satisfied.
  * The two large merges run with --autounmask-continue so leftover USE/
    license blockers are resolved and applied automatically.

Run from the official Gentoo Live USB, as root.
