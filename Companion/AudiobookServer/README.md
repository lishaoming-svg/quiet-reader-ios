# 墨阅听书生成器

该程序在 Windows 本地把墨阅发送的章节正文转换为 M4A 音频。音频下载到 iPhone 后可以离线播放。

## 立即启动

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

准备一段具有使用权的清晰单人参考音频，以及与音频逐字一致的文字：

```powershell
.\start.ps1 -Engine cosyvoice `
  -PromptAudio 'D:\voices\reader.wav' `
  -PromptText '这里填写参考音频中准确说出的文字。'
```

参考音频建议为 5 至 15 秒、无背景音乐、无混响的 WAV 文件。生成器只监听本机局域网并使用随机配对令牌，切勿把端口直接暴露到公网。

## 测试

```powershell
python -m unittest discover -s tests -v
```

