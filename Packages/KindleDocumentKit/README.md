# KindleDocumentKit

墨阅的本地 Kindle 解析模块，支持未加密的 MOBI/KF7、PalmDOC、HUFF/CDIC 和 KF8/AZW3，包括 KF7+KF8 混合容器。加密标记会在正文解析前被拒绝；模块不提供密钥导入或解密接口。

该模块作为 **动态库** 构建，应用只依赖它的 Swift 接口；底层 libmobi 静态对象位于动态模块内。`project.yml` 通过本地 Swift Package 引用它。LibmobiSPM 固定提交为 `9f50f89509a2edc229b08ae4e128caa7bc983f3a`，其封装使用 MIT 许可，libmobi 使用 LGPL-3.0-or-later；许可全文在 `Licenses/`，也随 App 分发。

## 构建与替换

1. 克隆本仓库，保留 `project.yml` 和 `Packages/KindleDocumentKit`。底层固定版本源代码：https://github.com/mlilback/LibmobiSPM/tree/9f50f89509a2edc229b08ae4e128caa7bc983f3a 。
2. 如需修改 libmobi，可下载其源码，在本包 `Package.swift` 中把远程依赖改为对应本地包路径，保留 `CLibmobi` 产品名。该接口不限制用户修改或调试库。
3. 执行 XcodeGen，并通过 GitHub Actions 的 Build & Test 构建。设备 IPA 内嵌 `KindleDocumentKit.framework`。替换库后，按 iOS 平台要求重新签名整个应用再安装；也可直接从上述源码构建和签名完整应用。

本模块的 Swift 封装源码与此说明以 MIT 许可提供；原作者及许可见 `Licenses/LibmobiSPM-MIT.txt`，libmobi 原作者为 Bartek Fabiszewski 及贡献者。未修改上游 C 源码。
