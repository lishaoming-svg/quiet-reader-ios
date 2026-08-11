# 第三方依赖

## SwiftSoup

- 项目：https://github.com/scinfu/SwiftSoup
- 版本要求：2.13.5 及以上、3.0.0 以下
- 许可证：MIT License
- 用途：HTML 解析、CSS Selector 查询和正文清理。

墨阅没有复制 Legado 源码；书源数据结构仅实现公开可观察的常用字段兼容。

## ZIPFoundation

- 项目：https://github.com/weichsel/ZIPFoundation
- 版本：0.9.20
- 许可证：MIT License
- 用途：在 iOS 本地校验和解包 `.qraudio` 逐句伴读包。

## 可选听书组件

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
