# 兼容压缩 · Compatible Zip

一个轻量的 macOS 小工具，用来把中文文件、文件夹打包成适合发给 Windows 用户的 ZIP。支持拖放、文件选择和 Finder 服务，无需账号，处理过程在本机完成。

起因很简单：在 Mac 上压缩中文文件夹，经微信发送后，对方在 Windows 上看到乱码文件名，或者解压窗口看起来是空的。这个工具针对 ZIP 文件名的 UTF-8 标志和开头的 `./` 路径做处理。

## 下载和安装

在 [Releases](https://github.com/ForCattttt/compatible-zip/releases/latest) 下载 `CompatibleZip-1.1.1-macOS-universal.zip`，解压后：

1. 把 `兼容压缩.app` 放入个人目录的 `Applications` 文件夹（`~/Applications`，没有则新建）。
2. 双击应用选择文件，或把文件、文件夹拖到应用图标上。
3. 生成的 `原名称_兼容版.zip` 保存在原文件旁边，把这个新包发送给接收方。

可选：将 `兼容压缩（发微信）.workflow` 放入 `~/Library/Services`，即可从 Finder 右键的“服务”或“快速操作”调用。服务按上述个人 Applications 路径查找应用。

支持 macOS 13 或更高版本；下载包包含 Apple Silicon 和 Intel 两种架构。发布包使用本地临时签名，**未经过 Apple 开发者签名和公证**，下载后可能被系统拦截。请核对来源和校验值；也可以从源码构建。

## 功能

- 明确写入中文文件名的 UTF-8 编码标志，去掉 ZIP 条目开头的 `./`。
- 从文件夹新打包时，排除 `.DS_Store`、`._*` 和 `__MACOSX` 等 Mac 附加文件。已有 ZIP 修复会保留其中的条目。
- 对所选文件夹内的 ZIP 检查文件名元数据，按需生成修复副本；也能直接选择一个旧 ZIP 修复。
- 检查 Windows 保留名称、非法字符、名称冲突和危险路径。
- 在临时目录生成并校验结果，成功后才保存；保留源文件，重名自动增加序号。
- 显示打包文件数量，拒绝没有可打包文件的空包。

## 适用范围

本工具修复的是文件名元数据，无法自动恢复已经被改成乱码的名称，也不处理 Word、Excel 等文档正文乱码。

旧 ZIP 的文件名与逐条注释均须为有效 UTF-8；加密包、分卷包、结构损坏或名称不明确的包会被拒绝。文件夹来源中的符号链接会被拒绝。已有 ZIP 内的链接及普通隐藏文件会保留，因此请只处理可信来源的文件，并在发送前检查内容。

不会递归处理 ZIP 内部再嵌套的 ZIP。生成的外层 ZIP 会做 CRC 检查；文件夹内无需修复的 ZIP 不会另行解压校验其内部内容。长路径、接收方解压软件或网络传输引起的问题仍可能存在。

## 从源码构建

需要 macOS、Apple Command Line Tools（`xcode-select --install`）和 Python 3。应用运行时不依赖 Python 或第三方库。

```bash
git clone https://github.com/ForCattttt/compatible-zip.git
cd compatible-zip
bash scripts/build.sh
python3 tests/smoke.py "build/兼容压缩.app/Contents/MacOS/CompatZip"
python3 scripts/package.py
```

应用与 Finder 服务生成到 `build/`，下载包及 SHA-256 校验值生成到 `dist/`。构建脚本只写入项目内的这两个目录，不会替换已安装应用。

命令行使用：

```bash
"build/兼容压缩.app/Contents/MacOS/CompatZip" --cli "/path/to/文件夹"
"build/兼容压缩.app/Contents/MacOS/CompatZip" --cli "/path/to/旧包.zip" --output "/path/to/修复版.zip"
```

源代码：`src/CompatZip.swift` 是打包与应用入口，`src/ZipMetadata.swift` 是 ZIP 元数据检查和修补逻辑，`tools/MakeIcon.swift` 生成应用图标。运行时调用 macOS 自带的 `tar` 和 `unzip`。

当前发布在 Apple Silicon Mac 上完成构建与回归验证；Intel 架构已交叉编译，最低 macOS 版本和 Windows 实机解压仍需要更多环境反馈。遇到问题可提交 Issue，尽量提供不含个人或业务内容的最小示例。

## 许可

[MIT License](LICENSE)。
