# 书源结构说明

第一阶段使用以下核心字段：

- `bookSourceUrl`：书源基础地址，同时作为兼容标识。
- `sourceId`：可选的稳定标识；缺省时由 `bookSourceUrl` 生成。
- `bookSourceName`、`bookSourceGroup`、`enabled`、`lastUpdateTime`。
- `header`：JSON 字符串形式的请求头。
- `searchUrl`：支持 `{{key}}`、`{{page}}` 模板变量。
- `ruleSearch`：搜索结果列表与字段规则。
- `ruleBookInfo`：详情字段规则。
- `ruleToc`：目录字段规则。
- `ruleContent`：正文与下一页规则。

规则示例：

- `.book-item`：CSS 元素列表。
- `h3@text`：提取元素文本。
- `a@href`：提取链接属性。
- `$.results[*]`：基础 JSONPath 列表。
- `$["formats"]["text/plain; charset=utf-8"]`：包含特殊字符的 JSON 键。
- `.intro@text##^简介：##`：提取后执行正则替换。
