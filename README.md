# ahk-v2 脚本仓库

AHKDeck 的**官方脚本**仓库：每个脚本一份纯 AHK v2 源码，可搭配 AHKDeck 使用，也可用原版
AutoHotkey v2 独立运行。脚本与宿主**分离**——本仓库是脚本的唯一真源，宿主只负责运行。

- AHKDeck：面向 Windows x64 的 AutoHotkey v2 脚本工作台，集成脚本管理、编辑运行、日志查看与 MCP AI 接入。

> 脚本仓库：[Gitee](https://gitee.com/qiuzongman/ahk-v2-scripts) ｜ [GitHub](https://github.com/zongmanqiu/ahk-v2-scripts)
>
> AHKDeck 仓库：[Gitee](https://gitee.com/qiuzongman/AHKDeck) ｜ [GitHub](https://github.com/zongmanqiu/AHKDeck)

## 脚本列表

| 名称 | 版本 | 时间 | 简介 |
|---|---:|---|---|
| [打开方式清理](scripts/打开方式清理/打开方式清理.ahk) | 1.2.0 | 2026-11-11 | 扫描「打开方式」相关 13 处注册表位置，列出并清理失效残留 |
| [夜灯](scripts/夜灯/夜灯.ahk) | 1.0.1 | 2026-11-11 | 滑块调屏幕色温，并同步 Windows 夜间模式设置 |
| [双击防抖](scripts/双击防抖/双击防抖.ahk) | 1.0.0 | 2026-11-11 | 拦截间隔过短的左键双击，抑制误触连点，间隔可配置 |

每个脚本的详细说明与版本历史在它自己的 `info/` 里：点名称进脚本文件夹，再看 `info/README.md` 与 `info/HISTORY.md`。

## 怎么用

- **AHKDeck 内**：把 `.ahk` 放进宿主的 `Scripts` 目录（或在宿主里添加脚本），运行后脚本的托盘菜单
  会被宿主镜像成右键子菜单，点菜单项即入口。宿主关闭时脚本一并结束。
- **独立运行**：安装 [AutoHotkey v2](https://www.autohotkey.com/)（x64）后双击脚本，或
  `AutoHotkey64.exe 脚本.ahk`。所有脚本不依赖宿主私有 API，独立运行功能完整。
- **命令行分支**（仅打开方式清理，无 GUI）：
  - `AutoHotkey64.exe 打开方式清理.ahk --report [输出路径]`：只读扫描，输出逐来源行数/耗时等读数。
  - `AutoHotkey64.exe 打开方式清理.ahk --selftest [输出路径]`：合成注册表键自测，只动自建键、
    结束即清理；`rc=0` 全绿。

## 想知道｜去哪

| 想知道 | 去哪 |
|---|---|
| 某个脚本的功能/入口/写入位置/风险 | 该脚本文件夹下的 `info/README.md` |
| 某个脚本各版本改了什么 | 该脚本文件夹下的 `info/HISTORY.md`（只增不改） |
| 目录怎么组织、头部块怎么写、注释/版本/测试/出货规矩 | [`开发指南.md`](开发指南.md) |
| 脚本机器清单（版本/作者/raw 下载地址，供宿主以后下载用） | [`scripts.json`](scripts.json)（由 `tools/make_index.py` 生成） |
| 复刻/移植了哪些项目、来源与许可 | [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) |
| 本仓库许可（AGPL-3.0 全文） | [`LICENSE`](LICENSE) |

## 许可证

本仓库 **AGPL-3.0**，全文见 [`LICENSE`](LICENSE)。每个脚本头部 `@license` 只写 SPDX 名。