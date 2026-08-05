# 大灰狼书源适配记录

- 发布页：https://www.yckceo.com/yuedu/shuyuans/content/id/1036.html
- 原始合集：https://www.yckceo.com/yuedu/shuyuans/json/id/1036.json
- 适配对象：`🍅大灰狼小说5.0(独立版)`
- 服务地址：`https://api.langge.cf`
- 核验日期：2026-08-05

原始合集还包含聚合、漫画、听书和短剧源。其中聚合源依赖 Legado JavaScript、动态变量、Cookie 和登录流程，不能在墨阅的声明式规则引擎中直接执行。

内置兼容版仅保留小说源的搜索、详情、目录和正文 JSON API。搜索、详情和目录已实时核验；正文未登录访问受服务端每日额度限制。
