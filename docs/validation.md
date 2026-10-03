# 验证记录

验证日期：2026-10-03，时区 Asia/Shanghai。

## 环境

| 项目 | 实测值 |
| --- | --- |
| 设备 | Steam Deck OLED / Galileo |
| BIOS | F7G0114 |
| SteamOS | 3.8.28，build 20260922.1 |
| 内核 | 6.18.50-valve2-1-neptune-618-gc7289a96b14d |
| systemd | 257 |
| `/home` | ext4 |
| 新增交换文件 | 20 GiB，优先级 10 |

## 配置验证

安装后 `CanHibernate` 和 `CanSuspendThenHibernate` 均返回 `yes`，准备服务已启用且执行成功。

普通 `systemd-suspend.service` 和 `systemd-suspend-then-hibernate.service` 均加载了本项目的覆盖配置。直接休眠服务也会在执行前检查恢复条件。

有效设置为 `SuspendState=mem`、`MemorySleepMode=deep`、`HibernateMode=platform`、`HibernateDelaySec=3h`、`HibernateOnACPower=yes`。原有 zram 和系统交换文件均保留。

## 真实睡眠与恢复

在确认游戏和文件已保存后，使用 60 秒临时延时验证完整链路：

| 时间 | 服务事件 |
| --- | --- |
| 16:58:24 | `Performing sleep operation 'suspend'` |
| 16:59:25 | `Performing sleep operation 'hibernate'` |
| 17:01:06 | `System returned from sleep operation 'suspend-then-hibernate'` |
| 17:01:07 | 服务完成，`Result=success`，`ExecMainStatus=0` |

内核记录 `suspend entry (deep)`、S3 唤醒、`hibernation entry`、进入 S4、从 S4 唤醒及 `hibernation exit`。恢复后清除了 `HibernateLocation` EFI 变量。

恢复前后 boot ID 相同，原游戏进程仍存活。Steam 商店 HTTPS 请求返回 HTTP 200，内置控制器输入设备存在，`systemctl --failed` 无失败单元。

临时测试配置已删除，有效延时恢复为三小时。

## 更新保留机制

检查了实测机器的 SteamOS 原子更新实现：`post-install.sh` 会读取 `/etc/atomic-update.conf.d/*.conf`，并按保留规则将修改迁移到另一系统槽位。

使用相同 rsync 包含规则进行了文件迁移模拟；新增脚本、睡眠配置、服务覆盖文件和开机启用链接均被包含，无关文件未被包含。

整个安装未解除根文件系统只读保护，未修改 GRUB，也未重建 initramfs。

## 边界

- 实测了 60 秒延时的完整 S3 → S4 → 恢复链路，没有实际等待三小时。
- 没有执行实际 SteamOS 更新或 A/B 槽位切换。
- LCD / Jupiter 没有实测。
- 蓝牙服务正常运行，但测试时蓝牙开关关闭，因此没有验证蓝牙外设恢复。
- NetworkManager 显示 `connected (site only)` / `limited`，但实际 Steam 商店 HTTPS 访问成功。
- 输入设备存在不代表已经人工验证所有控制器、音频及外设功能。
- 未验证其他内核、固件及未来更新版本的兼容性。

此记录描述一次具体设备上的实测结果，不应当解读为所有 Steam Deck 或未来系统版本都已通过验证。
