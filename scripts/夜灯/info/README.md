# 夜灯

滑块调屏幕色温，并同步写入 Windows 夜间模式设置。能力移植自作者自有项目 KissLight。

## 功能

- 滑块 0–100% 对应色温 6500K–1200K，实时走 `gdi32\SetDeviceGammaRamp`；停止拖动 400 ms 后
  把色温写进 Windows 夜间模式的 CloudStore 二进制值（只改温度字段与时间戳，保留其余字节）。
- 启动时读取系统当前夜间模式色温作为初值；首次运行自动弹面板（不需要可删脚本末尾的 `SetTimer` 一行）。
- 纯 AHK v2：GammaRamp 走 gdi32，注册表走 advapi32，不依赖外部 exe。

## 入口

- 托盘菜单「夜灯调整」／「还原冷色」／「退出」（宿主内由宿主镜像；独立运行显示自己的托盘图标）。
- 全局热键由 AHKDeck 统一指派，脚本不自设。

## 写入位置

- `HKCU\...\CloudStore\...\bluelightreduction.settings` 的 `Data`（REG_BINARY）。
- `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM\GdiICMGammaRange`（解锁 gamma 范围，需管理员）。

## 退出行为

- **不还原屏幕**——屏幕当前的样子就是用户最后选的样子；只把未落盘的参数写进注册表。

## 风险

- 改 gamma 影响整屏显示；解锁 gamma 范围需管理员权限。
- 直接写 CloudStore 二进制值，只改温度字段与时间戳，保留其余字节；Windows 大版本更新可能改该值结构。

## 不做

- 不做定时切换/日出日落自动调温；不做多显示器独立色温。