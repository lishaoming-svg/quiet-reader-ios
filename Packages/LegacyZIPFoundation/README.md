# ZIPFoundation 0.9.20（同步兼容组件）

原始源码：https://github.com/weichsel/ZIPFoundation/tree/22787ffb59de99e5dc1fbfe80b19c97a904ad48d

Sources 保持上游原样，MIT 许可随包保留。仅将 Swift Package 名称改为 LegacyZIPFoundation、移除未随包复制的测试 target。原有 Word、伴读包和 EPUB 索引使用同步 ZIPFoundation API；Readium SDK 使用它自己的异步 ReadiumZIPFoundation。使用不同本地 package identity 避免 SwiftPM 将两个不同 API 的仓库合并，保留已有导入行为。
