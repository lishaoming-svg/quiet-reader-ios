# 墨阅 QuietReader

墨阅是一款面向个人使用的原生 iOS 无广告阅读器。当前版本支持导入声明式 JSON 书源、跨书源搜索、精确阅读进度、多种翻页方式、阅读记录、书签和批量离线缓存。

## 当前能力

- iOS 17+，SwiftUI + SwiftData。
- 从 JSON 文本、文件或远程 URL 导入书源。
- 随 App 内置 25,968 条去重书源，支持按名称、分组、域名和兼容性筛选后导入。
- 导入前预览新增、更新和已有状态。
- 常用 Legado CSS 链式规则、CSS Selector、基础 JSONPath 与正则替换。
- 相对书源地址、当前节点属性和多页目录读取。
- 搜索历史、详情、目录、正文、单章自动缓存和批量章节缓存。
- 搜索结果按书名或作者相关性排序，并过滤书源返回的推广伪结果。
- 章节内字符锚点、章节进度、全书进度和精确续读。
- 垂直滚动、水平滑动分页和无动画分页。
- 左右点击翻页、中央菜单、章节跳转和进度拖动。
- 最近阅读、今日/本周/本月/累计时长和阅读明细。
- 位置书签、书签摘要、书签列表和精确跳转。
- 中文阅读界面、字号、行距、衬线字体和四种纸张主题。
- 无广告、无分析 SDK、无强制账号；需要认证的第三方书源可使用独立网页登录。

## 生成 Xcode 工程

项目使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 描述工程：

```bash
brew install xcodegen
xcodegen generate
open QuietReader.xcodeproj
```

Windows 环境不能运行 Xcode。推送到 GitHub 后，可在 Actions 中运行 `构建 iOS 测试包`，下载 `QuietReader-unsigned-ipa` 构建产物，再使用 AltStore 或 Sideloadly 以自己的 Apple ID 签名安装。

第三方书源的实时链路可在 Actions 中手动运行 `在线书源冒烟测试`。该测试会在 iPhone 模拟器中使用 App 自身的书源引擎，让 5 条精选源分别搜索“异悚”，再执行详情、目录和第一章正文读取；不纳入每次提交的固定测试，以免第三方服务临时故障阻断正常构建。

## 书源边界

当前书源格式兼容 Legado 的常用顶层字段和四段规则结构，但不是完整 Legado 引擎。支持普通网页登录 Cookie 同步；暂不支持 Legado JavaScript 桥接、脚本登录界面、验证码自动处理、复杂 POST、XPath 和付费操作。

“书源”页的“内置源库”来自用户提供的全网合集：102,300 条原始记录经格式修复和“地址 + 名称”去重后形成 25,968 条目录，其中 6,223 条标记为当前兼容、15,066 条部分兼容、4,679 条暂不支持。完整规则按 64 个压缩分片随 App 分发，默认不批量启用，避免一次搜索向数千站点同时发起请求。

当前阅读器暂未实现文本高亮与笔记、TTS、跨设备同步、本地 EPUB/TXT 和仿真卷页。

导入页的“载入精选源”包含从用户合集筛选并转换的 5 条无需登录规则：饿狼小说、森林文学、B5200、五二书库和快眼看书。精选标准包括无需登录、普通 GET 搜索、不同站点、当前规则引擎可解析，并以“异悚”执行搜索、详情、目录和正文实时检查。

重新编译用户提供的源库：

```powershell
$env:PYTHONIOENCODING='utf-8'
python scripts\compile-source-catalog.py 'D:\开源阅读书源全网合集(2)' 'App\Resources\SourceCatalog'
python scripts\verify-source-catalog.py 'App\Resources\SourceCatalog'
```

仅应连接用户有权访问的内容服务。
