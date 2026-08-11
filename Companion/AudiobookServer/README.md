# 墨阅听书生成器

该程序在 Windows 本地把墨阅发送的章节正文转换为 M4A 音频。音频下载到 iPhone 后可以离线播放。

## 立即启动

CosyVoice 已安装后，双击 `启动墨阅听书.cmd` 即可。脚本会自动加载现有参考音频并打开配对网页；服务运行期间请保留启动窗口。

也可以通过 PowerShell 手动选择引擎：

```powershell
cd Companion\AudiobookServer
python -m pip install -r requirements.txt
.\start.ps1 -Engine sapi
```

浏览器打开终端显示的配对页面，随后在 iPhone 墨阅听书面板中扫码。Windows 第一次询问网络权限时允许专用网络访问。

## CosyVoice 3

首次安装需要下载模型和 Python 依赖：

```powershell
.\install-cosyvoice.ps1
```

当前模型和运行环境合计约 15 GB，安装时还会使用下载缓存，建议预留至少 25 GB 空间。首次安装时间取决于网络速度，完成后可以全程离线合成。

准备一段具有使用权的清晰单人参考音频，以及与音频逐字一致的文字：

```powershell
.\start.ps1 -Engine cosyvoice `
  -PromptAudio 'D:\voices\reader.wav' `
  -PromptText '这里填写参考音频中准确说出的文字。'
```

参考音频建议为 5 至 15 秒、无背景音乐、无混响的 WAV 文件。生成器只监听本机局域网并使用随机配对令牌，切勿把端口直接暴露到公网。

启动后让电脑与 iPhone 连接同一局域网，在墨阅的阅读页点击耳机按钮，再扫描电脑页面上的配对二维码。墨阅会自动生成当前章并持续提前准备后续 3 章；章节下载完成后，关闭电脑或离开局域网也能继续听。

CosyVoice 启动后提供三种朗读模式：自然女声、沉稳旁白和多角色对话。多角色模式会识别引号内台词及附近的说话人线索，为旁白、主角、男性和女性角色分别生成，并把逐段时间轴一同传给 iPhone，使阅读正文随播放位置自动移动。

## 测试

```powershell
python -m unittest discover -s tests -v
```
