# 导入测试材料

`sample.docx`、`sample.doc` 和 `多编码文本.txt` 是为墨阅编写的原创短文本测试材料，覆盖 OOXML 标题、文本段、表格、修订删除文本、MS-CFB/FIB/CLX 以及 GB18030 中文编码。

Kindle 材料来自 libmobi 的公开测试集，按其 LGPL-3.0-or-later 许可保留：

- 固定提交：`906274205c11944b628da1c553b255acb1af7c55`
- `sample-ncx.mobi`：Git blob `7a0d92ea535a04cb72079c47a11559fb4f999ad1`，PalmDOC 压缩、KF7 + KF8 混合容器。
- `sample-unicode-huffdic.mobi`：Git blob `8d71a648ece3d1f558ef8d9a0fccdcb80a0eb3ce`，Unicode、HUFF/CDIC、KF7 + KF8 混合容器。
- 来源：https://github.com/bfabiszewski/libmobi/tree/906274205c11944b628da1c553b255acb1af7c55/tests/samples
- 许可文本：`Packages/KindleDocumentKit/Licenses/`。

测试会以 MOBI、AZW 和 AZW3 扩展名分别导入相同的有效容器，检查实际正文解析；文件不是仅更改扩展名的文本。
