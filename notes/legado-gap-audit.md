# Legado 源码与墨阅差距审计

## 审计基线

- 审计时间：2026-08-06。
- 官方仓库 `gedoor/legado` 当前主分支只保留下架公告，无法用来进行完整源码审计。
- 本地参考副本来自保留完整历史的 `huajideshutiao/legado`，提交为 `9b1a5b68618b883ba4f5bdb8616599594bef85cd`，提交时间为 2026-06-26。
- 参考副本含 354 个 UI Kotlin 文件和 182 个布局 XML。它是多年迭代后的 Android 工程，不应按一个版本直接逐项照搬到 iOS；本项目采用原生 SwiftUI 重建相同的核心信息架构。

## Legado 的实际结构

### 主界面

`activity_main.xml` 和 `MainActivity.kt` 使用页面容器加底部导航，书架、发现等主模块保持独立状态。书架有两套实现，支持分组页签、列表/网格布局、排序、刷新、未读和最近更新信息，而不是只有一列静态卡片。

关键参考：

- `app/src/main/res/layout/activity_main.xml`
- `app/src/main/java/io/legado/app/ui/main/MainActivity.kt`
- `app/src/main/java/io/legado/app/ui/main/bookshelf/style1/BookshelfFragment1.kt`
- `app/src/main/java/io/legado/app/ui/main/bookshelf/style2/BookshelfFragment2.kt`

### 搜索、作品与换源

搜索不是把所有结果永久视为不同书籍。作品名称和作者用于聚合候选来源，用户可以在作品级换书源，也可以在阅读过程中按章节换源。换源界面显示来源、最新章节、响应状态，并保留当前阅读位置。

关键参考：

- `app/src/main/java/io/legado/app/ui/book/search/SearchActivity.kt`
- `app/src/main/java/io/legado/app/ui/book/changesource/ChangeBookSourceDialog.kt`
- `app/src/main/java/io/legado/app/ui/book/changesource/ChangeChapterSourceDialog.kt`
- `app/src/main/res/layout/dialog_book_change_source.xml`
- `app/src/main/res/layout/dialog_chapter_change_source.xml`

### 阅读器

`activity_book_read.xml` 的正文层是全屏主体，`view_read_menu.xml` 是按需覆盖显示的菜单层。顶层显示书名、章节和来源操作；底部包含上一章/下一章、全书进度、目录、朗读和设置；浮动操作包含书内搜索、自动翻页、替换规则和日夜主题。正文翻页规则会持续跟随 `nextContentUrl`，直到链接为空、重复或进入下一章，不会固定只读取前三页。

关键参考：

- `app/src/main/res/layout/activity_book_read.xml`
- `app/src/main/res/layout/view_read_menu.xml`
- `app/src/main/java/io/legado/app/ui/book/read/ReadBookActivity.kt`
- `app/src/main/java/io/legado/app/ui/book/read/ReadMenu.kt`
- `app/src/main/java/io/legado/app/model/webBook/BookContent.kt`

### 书源系统

书源是“请求定义 + 搜索规则 + 详情规则 + 目录规则 + 正文规则”的数据对象。管理界面提供搜索、分组、排序、批量启停、发现开关、置顶/置底、导入/导出、编辑、登录、单源搜索、调试和有效性检查。规则执行器支持的表达能力远高于墨阅当前声明式子集。

关键参考：

- `app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceActivity.kt`
- `app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceViewModel.kt`
- `app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceAdapter.kt`
- `app/src/main/java/io/legado/app/ui/book/source/manage/GroupManageDialog.kt`
- `app/src/main/java/io/legado/app/ui/book/source/edit/BookSourceEditActivity.kt`
- `app/src/main/java/io/legado/app/ui/book/source/debug/BookSourceDebugActivity.kt`

## 当前差距

| 领域 | Legado | 墨阅 0.5.1 当前状态 | 优先级 |
| --- | --- | --- | --- |
| 正文完整性 | 连续解析正文下一页并避开下一章 | 已从 3 页上限改为连续 20 页安全上限，超限明确报错 | P0 已处理 |
| 目录完整性 | 支持目录分页和去重 | 已支持连续 100 页、去重和超限报错 | P0 已处理 |
| 搜索聚合 | 同书多来源聚合 | 本版新增书名+作者聚合及来源数量 | P0 已处理 |
| 作品换源 | 作品级来源切换 | 本版新增详情页换源，章节级无缝换源尚缺 | P0 部分完成 |
| 阅读布局 | 全屏正文+覆盖菜单 | 已有三种翻页和位置保持；本版隐藏主标签栏，菜单层仍需继续重构 | P0 部分完成 |
| 书架 | 分组、网格/列表、排序、更新状态 | 本版新增网格/列表切换；仍缺分组、排序与更新状态 | P1 部分完成 |
| 书源管理 | 分组筛选、批量操作、编辑、调试、校验 | 本版新增名称/分组/域名筛选和结果批量启停；已有导入、清理、榜单、置顶/置底，仍缺编辑调试 | P1 部分完成 |
| 阅读工具 | 朗读、书内搜索、替换、自动翻页、亮度 | 已有书签、字体、行距、主题、三种翻页 | P1 |
| 本地书籍 | TXT/EPUB、文件管理 | 未实现 | P1 |
| 数据安全 | 备份恢复、WebDAV、导入导出 | 未实现 | P2 |
| 高级规则 | XPath、JSONPath、JavaScript、POST、Cookie 等 | 仅安全声明式 CSS/基础 JSONPath/GET/Cookie 登录 | P2，分安全等级实现 |
| 其他内容 | RSS、音频、漫画等 | 未实现 | P3 |

## 实施顺序

1. P0：正文与目录完整性、同书聚合、作品换源、沉浸阅读布局、错误源自动停用。
2. P1：书架分组和网格/列表、书内搜索、系统朗读、自动翻页、源编辑与调试、本地 TXT/EPUB。
3. P2：备份恢复、WebDAV、安全规则能力扩展、章节级自动换源与来源质量评分。
4. P3：RSS、音频、漫画和高级自动化。

## 验收原则

- “能打开”不能作为正文测试标准。测试必须指定作品、作者、章节、最小目录数、最小正文长度和章节结尾标记。
- 书源分页达到安全上限时必须报错，不能把已抓到的前半段当成完整正文显示。
- 换源应以作品身份而不是 URL 为核心，后续需要把书架、进度、书签从来源 URL 身份中解耦。
- 未经真机查看，不声称视觉和手势已达到最终效果。
