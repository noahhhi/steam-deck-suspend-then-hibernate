# Steam Deck Suspend-then-Hibernate

为 Steam Deck 配置三小时延时休眠：先进入 S3 深度睡眠，超时后自动唤醒、将会话写入 SSD，再进入 S4 休眠。按电源键可恢复原会话。

本项目使用 systemd 的 `suspend-then-hibernate`、EFI 恢复支持，以及 SteamOS 官方原子更新保留名单。已在 Steam Deck OLED 上完成一次真实的 S3 → S4 → 唤醒测试。

## 行为

- 普通系统睡眠请求，包括电源键发起的正常睡眠，接入三小时延时休眠。
- 电池供电和接电都计时；提前手动唤醒取消当前计时，下一次睡眠重新计时。
- 保留 systemd 电量低于约 5% 时提前休眠的保护行为。
- 新增 20 GiB 持久交换文件，保留原有 zram 和系统交换文件。
- 每次开机及每次睡眠前检查恢复条件；检查失败时，普通睡眠退回 S3 并记录原因。

计时从实际系统睡眠流程开始。Steam 的低功耗下载可能推迟真正进入睡眠；到达三小时后，写盘和关机也需要额外时间。

## 兼容性与前提

已实测环境：Steam Deck OLED / Galileo、BIOS F7G0114、SteamOS 3.8.28、systemd 257。详细证据见 [验证记录](docs/validation.md)。

安装器允许 OLED / Galileo 和 LCD / Jupiter，但 **LCD 尚未实测**。需要满足以下条件：

- 内核提供 `deep`、`mem`、`disk`，以及 ACPI `platform` 休眠模式。
- 通过 EFI 启动，EFI 变量可写，内核没有启用阻止休眠的 lockdown。
- 当前内核的 initramfs 包含 `systemd-hibernate-resume` 及可执行的恢复入口。
- `/home` 为 ext4，并至少有 22 GiB 可用空间。
- 系统具备 `lsinitcpio`、支持 `--file --size` 的 `mkswap`、systemd 等命令。
- SteamOS 支持 `/etc/atomic-update.conf.d/*.conf` 更新保留名单。

SteamOS 3.8.28 的厂商配置默认禁用休眠；本项目会通过独立配置覆盖它。安装器不修改 GRUB、不重建 initramfs，也不解除根文件系统的只读保护。不满足恢复条件时会拒绝安装，而不是自动改造启动环境。

## 安装

建议在桌面模式中打开 Konsole。先阅读脚本，再在本机完成管理员认证：

```bash
git clone https://github.com/noahhhi/steam-deck-suspend-then-hibernate.git
cd steam-deck-suspend-then-hibernate
sudo bash ./install-deck-s2h.sh install
```

安装不会自动睡眠、断电或重启。现有同名配置会备份到 `/home/.suspend_then_hibernate/originals/`。新增的交换文件为 `/home/.suspend_then_hibernate/swapfile`，优先级为 10，低于已实测系统的 zram 优先级 100。

验证配置，不触发睡眠：

```bash
sudo bash ./install-deck-s2h.sh check
```

`CanHibernate` 和 `CanSuspendThenHibernate` 应返回 `yes`，准备服务应已启用，交换文件应已激活。配置检查通过不等于已验证该设备的真实 S4 恢复。

## 一分钟实测

先保存游戏和文件。测试会中断当前会话，约一分钟后进入休眠；请等待约 90 秒或写盘结束，再按电源键恢复。

```bash
sudo bash ./install-deck-s2h.sh test-60s
```

按提示输入 `TEST` 开始。测试使用 `/run` 下的临时配置；退出时删除，重启也会清除，不改变持久的三小时设置。测试检查原 boot ID 是否保持不变、服务是否执行过 `hibernate`，以及是否报告休眠失败。提前手动唤醒只测试了 S3，不能算 S4 验证成功。

恢复后，请另外确认游戏、网络、控制器、音频及所使用的蓝牙外设正常。

## 系统更新

`deck-s2h/atomic-update.conf` 安装到 `/etc/atomic-update.conf.d/deck-s2h.conf`，明确列出需要迁移到新系统槽位的脚本、配置和开机服务链接。持久交换文件位于共享的 `/home` 分区。

本项目使用 systemd 的 `HibernateLocation` EFI 变量传递恢复位置，不写死 GRUB 中的交换文件偏移。开机和睡眠前会重新检查当前内核的正常及 fallback initramfs。

已根据实测机器上的 SteamOS 更新脚本验证保留机制，并模拟了相同 rsync 规则的文件迁移；**尚未执行实际系统升级或 A/B 槽位切换测试**。如果未来更新移除恢复支持，普通睡眠会退回 S3。未知未来内核、固件或更新机制变化不能作绝对兼容保证。

## 日志与排查

```bash
journalctl -b -u deck-s2h-prepare.service \
  -u systemd-suspend.service \
  -u systemd-suspend-then-hibernate.service
```

`deck-s2h-prepare.service` 是不保持 active 状态的 oneshot 服务；成功执行后显示 `inactive` 是正常现象。可用以下命令检查结果和开机启用状态：

```bash
systemctl show deck-s2h-prepare.service -p Result -p ExecMainStatus
systemctl is-enabled deck-s2h-prepare.service
```

如果更新后准备检查失败，先查看日志和当前启动环境，不要绕过检查强行休眠。

## 卸载

```bash
sudo bash ./install-deck-s2h.sh uninstall
```

卸载停用本项目的开机服务，撤销专用配置，恢复安装前备份，并在成功停用交换文件后释放其 20 GiB 空间。原配置备份仍保留。请在机器正常运行时执行，不要在系统睡眠或休眠过程中卸载。

## 文件

- `install-deck-s2h.sh`：安装、检查、一分钟测试和卸载。
- `deck-s2h/manage.sh`：恢复条件检查、交换文件准备及睡眠入口。
- `deck-s2h/*.conf`：睡眠参数、服务覆盖配置、更新保留规则及测试参数。
- `deck-s2h/deck-s2h-prepare.service`：开机和睡眠前的准备服务。

## 参考

- [systemd 257 睡眠配置说明](https://github.com/systemd/systemd/blob/v257/man/systemd-sleep.conf.xml)
- [systemd 257 睡眠实现](https://github.com/systemd/systemd/blob/v257/src/sleep/sleep.c)
- 本机 SteamOS 的 `/usr/lib/rauc/atomic-update-keep.conf` 和 `/usr/lib/rauc/post-install.sh`。
