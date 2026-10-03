#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/bin:/usr/sbin

kit_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/deck-s2h" && pwd)
state_dir=/home/.suspend_then_hibernate
swap_file=$state_dir/swapfile
swap_bytes=21474836480
managed_paths=(
    /etc/deck-s2h/manage.sh
    /etc/systemd/sleep.conf.d/zzzz-deck-s2h.conf
    /etc/systemd/system/deck-s2h-prepare.service
    /etc/systemd/system/systemd-suspend.service.d/zzzz-deck-s2h.conf
    /etc/systemd/system/systemd-suspend-then-hibernate.service.d/zzzz-deck-s2h.conf
    /etc/systemd/system/systemd-hibernate.service.d/zzzz-deck-s2h.conf
    /etc/atomic-update.conf.d/deck-s2h.conf
)

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail '请在本机终端通过 sudo 运行此脚本。'

diagnose() {
    local capability response
    /etc/deck-s2h/manage.sh check
    systemctl is-enabled deck-s2h-prepare.service
    systemctl show systemd-suspend.service -p ExecStart -p DropInPaths
    systemctl show systemd-suspend-then-hibernate.service -p ExecStart -p DropInPaths
    systemd-analyze cat-config systemd/sleep.conf
    for capability in CanHibernate CanSuspendThenHibernate; do
        response=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$capability")
        printf '%s: %s\n' "$capability" "$response"
        [[ $response == 's "yes"' || $response == 's "challenge"' ]] || fail "$capability is unavailable."
    done
    swapon --show
}

install_setup() {
    local program target available_kib
    for program in lsinitcpio mkswap swapon swapoff findmnt systemctl systemd-analyze busctl stat install logger; do
        command -v "$program" >/dev/null || fail "Missing program: $program"
    done
    [[ $(cat /sys/class/dmi/id/product_name) == Galileo || $(cat /sys/class/dmi/id/product_name) == Jupiter ]] || fail '此安装包只针对 Steam Deck。'
    [[ -f /usr/lib/rauc/atomic-update-keep.conf ]] || fail 'SteamOS update preservation mechanism was not found.'
    grep -Fq '/etc/atomic-update.conf.d/*.conf' /usr/lib/rauc/atomic-update-keep.conf || fail 'SteamOS does not support the expected update preservation drop-ins.'
    [[ $(findmnt -n -o FSTYPE -T /home) == ext4 ]] || fail '/home is not ext4.'
    /bin/bash "$kit_dir/manage.sh" platform
    if [[ ! -e $state_dir ]]; then
        install -d -m 700 -o root -g root "$state_dir"
    fi
    [[ -d $state_dir && ! -L $state_dir && $(stat -c '%u:%a' "$state_dir") == 0:700 ]] || fail 'Unexpected state directory ownership or type.'
    if [[ ! -f $state_dir/originals-recorded ]]; then
        install -d -m 700 "$state_dir/originals"
        for target in "${managed_paths[@]}"; do
            if [[ -e $target || -L $target ]]; then
                cp -a --parents -- "$target" "$state_dir/originals/"
            fi
        done
        touch "$state_dir/originals-recorded"
    fi
    if [[ ! -e $swap_file && ! -L $swap_file ]]; then
        available_kib=$(df -Pk /home | awk 'NR == 2 {print $4}')
        (( available_kib >= swap_bytes / 1024 + 2097152 )) || fail '创建 20 GiB 交换文件后需至少保留 2 GiB 空间。'
        printf '创建 20 GiB 休眠交换文件……\n'
        mkswap --file --size "$swap_bytes" --label deck-s2h "$swap_file"
        chmod 600 "$swap_file"
    fi
    [[ -f $swap_file && ! -L $swap_file && $(stat -c '%u:%a' "$swap_file") == 0:600 ]] || fail 'Unexpected swap file ownership or type.'
    [[ $(stat -c %s "$swap_file") == "$swap_bytes" ]] || fail 'An existing swap file has an unexpected size; it was not overwritten.'
    install -d -m 755 /etc/deck-s2h /etc/systemd/sleep.conf.d /etc/atomic-update.conf.d \
        /etc/systemd/system/systemd-suspend.service.d \
        /etc/systemd/system/systemd-suspend-then-hibernate.service.d \
        /etc/systemd/system/systemd-hibernate.service.d
    install -m 755 "$kit_dir/manage.sh" /etc/deck-s2h/manage.sh
    install -m 644 "$kit_dir/zzzz-deck-s2h.conf" /etc/systemd/sleep.conf.d/zzzz-deck-s2h.conf
    install -m 644 "$kit_dir/deck-s2h-prepare.service" /etc/systemd/system/deck-s2h-prepare.service
    install -m 644 "$kit_dir/suspend-override.conf" /etc/systemd/system/systemd-suspend.service.d/zzzz-deck-s2h.conf
    install -m 644 "$kit_dir/suspend-override.conf" /etc/systemd/system/systemd-suspend-then-hibernate.service.d/zzzz-deck-s2h.conf
    install -m 644 "$kit_dir/hibernate-override.conf" /etc/systemd/system/systemd-hibernate.service.d/zzzz-deck-s2h.conf
    install -m 644 "$kit_dir/atomic-update.conf" /etc/atomic-update.conf.d/deck-s2h.conf
    systemd-analyze --man=no verify /etc/systemd/system/deck-s2h-prepare.service \
        /usr/lib/systemd/system/systemd-suspend.service \
        /usr/lib/systemd/system/systemd-suspend-then-hibernate.service \
        /usr/lib/systemd/system/systemd-hibernate.service
    systemctl daemon-reload
    systemctl enable --now deck-s2h-prepare.service
    diagnose
    touch "$state_dir/installed"
    printf '\n安装完成。普通睡眠请求已接入 S3 → 3 小时 → S4 流程。尚未进行实际睡眠/唤醒测试。\n'
}

uninstall_setup() {
    [[ -f $state_dir/originals-recorded ]] || fail 'No installation backup was found.'
    [[ -d $state_dir && ! -L $state_dir && $(stat -c '%u:%a' "$state_dir") == 0:700 ]] || fail 'Unexpected state directory.'
    local target
    systemctl disable --now deck-s2h-prepare.service
    if awk -v target="$swap_file" 'NR > 1 && $1 == target {found=1} END {exit !found}' /proc/swaps; then
        swapoff "$swap_file" || fail 'Swap could not be deactivated; no files were removed.'
    fi
    for target in "${managed_paths[@]}"; do
        [[ ! -d $target || -L $target ]] || fail "Unexpected directory at $target"
        rm -f -- "$target"
        if [[ -e $state_dir/originals$target || -L $state_dir/originals$target ]]; then
            cp -a -- "$state_dir/originals$target" "$target"
        fi
    done
    systemctl daemon-reload
    rm -f -- "$swap_file" "$state_dir/installed" /run/deck-s2h/ready
    printf '已撤销本次配置并释放 20 GiB 交换文件；原配置备份仍保留。\n'
}

test_resume() {
    /etc/deck-s2h/manage.sh check
    printf '测试会立即睡眠，约 60 秒后转入 S4；随后请按电源键唤醒。\n请先保存游戏和文件。输入 TEST 开始：'
    local confirmation initial_boot_id test_timestamp test_logs
    read -r confirmation
    [[ $confirmation == TEST ]] || fail 'Test cancelled.'
    initial_boot_id=$(cat /proc/sys/kernel/random/boot_id)
    test_timestamp=$(date +%s)
    [[ ! -e /run/systemd/sleep.conf.d/zzzzz-deck-s2h-test.conf ]] || fail 'A test override already exists.'
    install -d -m 755 /run/systemd/sleep.conf.d
    install -m 644 "$kit_dir/test-60s.conf" /run/systemd/sleep.conf.d/zzzzz-deck-s2h-test.conf
    trap 'rm -f -- /run/systemd/sleep.conf.d/zzzzz-deck-s2h-test.conf' EXIT
    printf '测试前 boot_id=%s\n' "$initial_boot_id"
    systemctl suspend-then-hibernate
    while [[ $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager PreparingForSleep) == 'b true' ]] || \
        systemctl is-active --quiet systemd-suspend-then-hibernate.service; do
        sleep 1
    done
    [[ $(cat /proc/sys/kernel/random/boot_id) == "$initial_boot_id" ]] || fail 'The session did not resume from the original boot.'
    journalctl -b -u systemd-suspend-then-hibernate.service -u deck-s2h-prepare.service --no-pager -n 70
    test_logs=$(journalctl -b -u systemd-suspend-then-hibernate.service --since "@$test_timestamp" --no-pager -o cat)
    grep -Fq "Performing sleep operation 'hibernate'" <<< "$test_logs" || fail 'No S4 operation was recorded; an early manual wake only tests S3.'
    if grep -Eq "Couldn't hibernate|Failed to put system to sleep|Failed to find location to hibernate" <<< "$test_logs"; then
        fail 'The S4 operation failed; inspect the service log.'
    fi
    printf '\n已回到原会话，三小时配置已恢复。请确认日志出现 hibernate 操作，且游戏和网络正常。\n'
}

case ${1:-install} in
    install) install_setup ;;
    check) diagnose ;;
    uninstall) uninstall_setup ;;
    test-60s) test_resume ;;
    *) fail 'Usage: install-deck-s2h.sh {install|check|uninstall|test-60s}' ;;
esac
