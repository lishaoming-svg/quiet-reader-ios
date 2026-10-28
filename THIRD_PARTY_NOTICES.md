# 第三方依赖

## SwiftSoup

- 项目：https://github.com/scinfu/SwiftSoup
- 版本：2.13.5（固定）
- 许可证：MIT License
- 用途：HTML 解析、CSS Selector 查询和正文清理。

墨阅没有复制 Legado 源码；书源数据结构仅实现公开可观察的常用字段兼容。

## ZIPFoundation

- 项目：https://github.com/weichsel/ZIPFoundation
- 版本：0.9.20，原始提交 `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`；同步兼容源码位于 `Packages/LegacyZIPFoundation`
- 许可证：MIT License
- 用途：本地 Word、EPUB 索引和 `.qraudio` 包解析。MIT 许可随源码和 App 分发。

## 可选听书组件

- GPT-SoVITS：https://github.com/RVC-Boss/GPT-SoVITS
- 许可证：MIT License
- 用途：Windows 本地 11 音色多角色语音合成。源码、依赖和模型由用户单独下载，不随 iOS App 分发。
- AISHELL-3：https://www.aishelltech.com/aishell_3
- 许可证：Apache License 2.0
- 用途：已确认自然青年男声的本地参考声纹。
- Qwen3-TTS：https://github.com/QwenLM/Qwen3-TTS
- 许可证：Apache License 2.0
- 用途：已确认设计声线和官方预设声线的本地参考声纹。
- CosyVoice：https://github.com/QwenAudio/CosyVoice
- 许可证：Apache License 2.0
- 用途：Windows 本地自然语音合成。源码、依赖和模型由用户单独下载，不随 iOS App 分发。
- Python qrcode：https://github.com/lincolnloop/python-qrcode
- 许可证：BSD License
- 用途：在 Windows 配对页面生成二维码，由用户单独安装。

## 社区书源参考

精选声明式规则参考以下社区 Legado 合集，并针对墨阅支持的规则子集重新适配和验证：

- ZWolken/Light-Novel-Yuedu-Source（MIT）
- e101406/booksources
- rektpartyaftermath/Legado-booksource-collection

应用不内置书籍内容。书源只在用户主动操作时访问对应站点，能否使用取决于站点状态和使用条款。

## libmobi / KindleDocumentKit

- libmobi：https://github.com/bfabiszewski/libmobi
- Swift Package 封装：https://github.com/mlilback/LibmobiSPM ，固定提交 `9f50f89509a2edc229b08ae4e128caa7bc983f3a`
- libmobi 许可证：LGPL-3.0-or-later；上游 Swift Package 封装：MIT。
- 用途：在本机解析未加密的 MOBI / AZW / AZW3 正文和元数据。
- 集成方式：`Packages/KindleDocumentKit` 动态库；上游 C 源码未修改。源码获取、重新构建与替换说明见该目录的 README，许可证全文在 `Licenses/` 并随 App 分发。
- Kindle 回归样本的来源、固定版本与文件哈希见 `Tests/Fixtures/README.md`。

新增界面由 SwiftUI、系统字体和 SF Symbols 构建，不包含苹果图书的品牌图片或其书籍内容。

## Readium Swift Toolkit

- 项目：https://github.com/readium/swift-toolkit
- 版本：3.11.1，固定提交 `9a8c094b72245fd27043c9d298005e5c78b32a01`。
- 许可证：BSD-3-Clause，全文随 App 分发。
- 用途：EPUB 2/3 原书 CSS、图片、字体、注音与固定版式阅读；保留 Readium Locator 续读。
- 使用 ReadiumShared、ReadiumStreamer、ReadiumNavigator，不接入 LCP 付费服务。
- Readium 的直接依赖许可：SwiftSoup（MIT）、Zip（MIT）、DifferenceKit（Apache-2.0）、Readium/Fuzi（MIT）、Readium/ZIPFoundation（MIT）；这些模块保留上游许可。SDK 所带 Readium CSS 与字体资源的原始许可随其资源包分发。
- 原创 EPUB 示例仅用于排版和导入验证，文字和 SVG 均为本项目生成。
