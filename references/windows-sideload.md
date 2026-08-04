# Windows 真机测试流程

## 生成 IPA

1. 将项目推送到 GitHub 仓库的 `main` 分支。
2. 打开仓库的 `Actions` 页面。
3. 运行“构建 iOS 测试包”。
4. 构建成功后下载 `QuietReader-unsigned-ipa`。
5. 解压构建产物，得到 `QuietReader-unsigned.ipa`。

## 安装到 iPhone

1. 在 Windows 安装 iTunes、iCloud 和 AltStore 或 Sideloadly。
2. 用数据线连接 iPhone并信任这台电脑。
3. 使用自己的 Apple ID 对 IPA 签名并安装。
4. iOS 16 及以上需要在“设置 -> 隐私与安全性 -> 开发者模式”中启用开发者模式。
5. 免费 Apple ID 的签名约 7 天到期；保持相同 Apple ID 和 Bundle ID 覆盖安装，可以降低本地数据丢失风险。

首次测试建议依次检查：启动、载入测试源、搜索 `Pride`、打开详情、阅读全文、返回书架、断网后重开已缓存章节。
