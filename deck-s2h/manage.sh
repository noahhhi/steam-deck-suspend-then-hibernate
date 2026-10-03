#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/bin:/usr/sbin

state_dir=/home/.suspend_then_hibernate
swap_file=$state_dir/swapfile
ready_file=/run/deck-s2h/ready

fail() {
    printf 'deck-s2h: %s\n' "$*" >&2
    return 1
}

validate_platform() {
    [[ $EUID == 0 ]] || { fail 'Administrator privileges are required.'; return 1; }
    grep -qw deep /sys/power/mem_sleep || { fail 'S3 deep sleep is unavailable.'; return 1; }
    grep -qw disk /sys/power/state || { fail 'Hibernation is unavailable.'; return 1; }
    grep -qw platform /sys/power/disk || { fail 'ACPI S4 platform mode is unavailable.'; return 1; }
    [[ -d /sys/firmware/efi/efivars ]] || { fail 'EFI resume support is unavailable.'; return 1; }
    findmnt -n -o OPTIONS /sys/firmware/efi/efivars | grep -qw rw || {
        fail 'EFI variables are not writable.'; return 1;
    }
    if [[ -r /sys/kernel/security/lockdown ]]; then
        grep -Fq '[none]' /sys/kernel/security/lockdown || {
            fail 'Kernel lockdown prevents hibernation.'; return 1;
        }
    fi
    local boot_arguments argument boot_kernel='' initramfs image contents
    read -ra boot_arguments < /proc/cmdline
    for argument in "${boot_arguments[@]}"; do
        case "$argument" in
            noresume|noresume=*) fail 'The kernel command line disables resume.'; return 1 ;;
            BOOT_IMAGE=*) boot_kernel=${argument##*/} ;;
        esac
    done
    [[ $boot_kernel == vmlinuz-* ]] || {
        fail 'Cannot identify the booted kernel; resume verification is required.'; return 1;
    }
    initramfs=/boot/initramfs-${boot_kernel#vmlinuz-}
    [[ -f $initramfs.img ]] || { fail "Missing initramfs: $initramfs.img"; return 1; }
    for image in "$initramfs.img" "$initramfs-fallback.img"; do
        [[ -f $image ]] || continue
        contents=$(lsinitcpio -l "$image") || { fail "Cannot inspect $image"; return 1; }
        grep -Eq '^([.]/)?usr/lib/systemd/systemd-hibernate-resume$' <<< "$contents" || {
            fail "EFI resume executable is missing from $image"; return 1;
        }
        grep -Eq '^([.]/)?(hooks/resume|usr/lib/systemd/system/systemd-hibernate-resume.service)$' <<< "$contents" || {
            fail "Resume hook/service is missing from $image"; return 1;
        }
    done
    printf 'S3/S4 and EFI initramfs resume support verified.\n'
}

validate_swap() {
    [[ -d $state_dir && ! -L $state_dir ]] || { fail 'Swap directory is missing or is a symlink.'; return 1; }
    [[ $(stat -c '%u:%a' "$state_dir") == 0:700 ]] || { fail 'Swap directory must be root-owned with mode 700.'; return 1; }
    [[ -f $swap_file && ! -L $swap_file ]] || { fail 'Swap file is missing or is a symlink.'; return 1; }
    [[ $(stat -c '%u:%a' "$swap_file") == 0:600 ]] || { fail 'Swap file must be root-owned with mode 600.'; return 1; }
    [[ $(findmnt -n -o FSTYPE -T "$swap_file") == ext4 ]] || { fail 'This swap setup requires ext4.'; return 1; }
    local memory_kib vram_bytes=0 vram_file required_bytes
    memory_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    for vram_file in /sys/class/drm/card*/device/mem_info_vram_total; do
        [[ -r $vram_file ]] || continue
        vram_bytes=$((vram_bytes + $(< "$vram_file")))
    done
    required_bytes=$((memory_kib * 1024 + vram_bytes + 1073741824))
    (( $(stat -c %s "$swap_file") >= required_bytes )) || {
        fail 'Swap file is too small for RAM, VRAM, and the reserve.'; return 1;
    }
}

swap_active() {
    awk -v target="$swap_file" 'NR > 1 && $1 == target {found=1} END {exit !found}' /proc/swaps
}

prepare() {
    install -d -m 700 /run/deck-s2h
    rm -f -- "$ready_file"
    if ! validate_platform || ! validate_swap; then
        fail 'Readiness check failed. Ordinary suspend will use S3 only.'
        return 1
    fi
    if ! swap_active; then
        swapon --priority 10 "$swap_file" || { fail 'Cannot activate hibernation swap.'; return 1; }
    fi
    printf '%s\n' "$(cat /proc/sys/kernel/random/boot_id)" > "$ready_file"
    printf 'Ready: S3 deep sleep, hibernate after 3h, including AC power.\n'
}

check() {
    validate_platform
    validate_swap
    swap_active || { fail 'Hibernation swap is not active.'; return 1; }
    [[ -f $ready_file ]] || { fail 'Preparation has not succeeded this boot.'; return 1; }
    printf 'Hibernation swap is active; preparation succeeded.\n'
}

case ${1:-} in
    platform) validate_platform ;;
    prepare) prepare ;;
    check) check ;;
    sleep)
        if [[ -f $ready_file ]] && swap_active; then
            exec /usr/lib/systemd/systemd-sleep suspend-then-hibernate
        fi
        logger -t deck-s2h 'Resume readiness failed; falling back to S3 suspend. See deck-s2h-prepare.service.'
        exec /usr/lib/systemd/systemd-sleep suspend
        ;;
    *) printf 'Usage: %s {platform|prepare|check|sleep}\n' "$0" >&2; exit 2 ;;
esac
