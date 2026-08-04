# 墨阅 QuietReader

墨阅是一款面向个人使用的原生 iOS 无广告阅读器。第一阶段支持导入声明式 JSON 书源、跨书源搜索、书籍详情、章节正文、离线缓存和阅读进度。

## 当前能力

- iOS 17+，SwiftUI + SwiftData。
- 从 JSON 文本、文件或远程 URL 导入书源。
- 导入前预览新增、更新和已有状态。
- 常用 Legado CSS 链式规则、CSS Selector、基础 JSONPath 与正则替换。
- 相对书源地址、当前节点属性和多页目录读取。
- 搜索、详情、目录、正文和单章缓存。
- 中文阅读界面、字号、行距和纸张主题设置。
- 无广告、无分析 SDK、无账号。

## 生成 Xcode 工程

项目使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 描述工程：

```bash
brew install xcodegen
xcodegen generate
open QuietReader.xcodeproj
```

Windows 环境不能运行 Xcode。推送到 GitHub 后，可在 Actions 中运行 `构建 iOS 测试包`，下载 `QuietReader-unsigned-ipa` 构建产物，再使用 AltStore 或 Sideloadly 以自己的 Apple ID 签名安装。

## 书源边界

当前书源格式兼容 Legado 的常用顶层字段和四段规则结构，但不是完整 Legado 引擎。暂不支持任意 JavaScript、登录、验证码、复杂 POST、XPath 和付费操作。

导入页的“载入精选源”包含 5 条已实测规则：古登堡公版书、轻小说百科、红袖读书公开章节、Light Novel World 和 Royal Road。站点结构或访问策略变化后，书源仍可能失效。

仅应连接用户有权访问的内容服务。
