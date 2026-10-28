# QuietReader 稳定规则

- 所有用户可见文本、界面介绍和交付说明以中文为主。
- 应用不接入广告、分析、跟踪或第三方账号系统。
- `inputs/` 中的原始材料只读，生成内容写入 `outputs/` 或源码目录。
- 第一阶段书源引擎只执行声明式规则，不执行导入书源中的任意 JavaScript。
- 网络书源必须经过格式校验；请求只允许 `http` 和 `https`。
- 每项功能都应覆盖空状态、加载状态和可操作的错误状态。
- 本地无法运行 Xcode 时，不得宣称已完成真机或最终界面验证。

## iOS CI 协作规则

- 本项目用 [ios-ci-workflows](https://github.com/wenjinliuu/ios-ci-workflows) 编译和测试；CI 是唯一测试入口，本地不跑 Xcode。改完代码 push，读 Build & Test 的测试报告再修。
- 新功能必须带测试；能用逻辑测试验证的不写成 UI 测试；UI 测试按条件等待，不用 sleep 固定等。
- 删测试只有三种理由：功能已删除、和另一个测试完全重复、已被更便宜的测试覆盖；删测试、改断言的预期值都要在提交里写明理由。
- 有意改了界面：有快照测试时手动运行 Build & Test 并勾选 record_snapshots，再跑一次确认变绿，并说明改了哪些页面。
- 当前每次运行 QuietReader scheme 的全部测试。以后拆分测试计划时，PR 跑快线（逻辑、迁移、快照）；改了界面交互、关键流程或 UI 测试时，合并前手动跑一次 ui（或 full）。
- 在线书源测试保持手动运行，不把第三方站点的可用性纳入固定回归门槛。
- 涉及 CloudBase 时，先执行 `npx skills add tencentcloudbase/cloudbase-skills` 并读取 cloudbase-guidelines。
- 部署只走 git → CI；MCP 只用来查数据、看日志、排查问题；AI 默认只连测试环境。
- 更多细节见上游 [ios-ci-workflows Skill](https://github.com/wenjinliuu/ios-ci-workflows/blob/df71d6096d6d39ea799179cb2635703548b07ae0/skills/ios-ci-workflows/SKILL.md)。
