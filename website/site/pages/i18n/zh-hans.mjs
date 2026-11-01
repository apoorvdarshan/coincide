// 简体中文 home page: the translation of EN in _home.mjs.
import { localizedHome } from "./_home.mjs";

export default localizedHome({
  "lang": "zh-Hans",
  "path": "/zh-hans",
  "nativeName": "简体中文",
  "ogLocale": "zh_CN",
  "title": "Coincide：在一款原生 Mac 应用中使用所有编程智能体",
  "description": "在一款原生 Mac 应用中并排运行 Claude Code、Codex、Cursor、Grok Build、OpenCode 和 Antigravity，还能在对话中途切换智能体。",
  "ui": {
    "skip": "跳到正文",
    "navLabel": "主导航",
    "nav": [
      "功能",
      "智能体",
      "文档",
      "下载",
      "常见问题",
      "GitHub"
    ],
    "get": "获取 Coincide",
    "about": "一款原生 Mac 应用，适用于你已经在用的编程智能体。基于 MIT 许可证，免费且开源。"
  },
  "t": {
    "eyebrow": "免费开源 · macOS",
    "h1": "所有编程智能体，尽在一款原生 Mac 应用。",
    "lede": "Coincide 在同一个窗口中运行 Claude Code、Codex、Cursor、Grok Build、OpenCode 和 Antigravity。每个智能体都使用自己的命令行工具，以及你现有的登录或 API 密钥；你还可以在对话中途切换智能体。",
    "download": "下载 Mac 版",
    "allOptions": "所有安装方式",
    "requirements": "需要搭载 Apple 芯片或 Intel 处理器、运行 macOS 26 或更高版本的 Mac。每个版本都使用 Developer ID 签名并经过 Apple 公证，Coincide 会自动更新。",
    "installTitle": "通过命令行安装",
    "homebrew": "使用 Homebrew：",
    "npm": "使用 npm（Node.js 18 或更高版本），它会校验下载文件的校验和、签名和公证：",
    "agentsTitle": "使用你自己的智能体",
    "agentsText": "至少安装并登录一个智能体。Coincide 会在你的 Mac 上启动该智能体自己的工具，因此你现有的订阅照常可用。它绝不会转售、代理或计量你的 token。",
    "featuresTitle": "Coincide 带来的功能",
    "features": [
      [
        "在对话中途切换智能体",
        "下一个智能体会收到它错过的轮次摘要，并在同一文件夹中继续工作。切换回来时，原来的智能体会恢复它自己的会话。"
      ],
      [
        "统一的模型选择器",
        "所有已安装并登录的智能体的模型都集中在一个菜单中；智能体支持时，还可选择推理强度和快速模式。"
      ],
      [
        "项目和对话",
        "带有搜索、置顶、归档和延后显示功能的边栏，以及 ⌘K 命令面板。"
      ],
      [
        "计划模式和审批",
        "让智能体先制定计划，逐一批准每条命令和每次文件改动，或授予它完全访问权限。"
      ],
      [
        "内置 Git",
        "差异对比、每轮的检查点、工作树、提交、推送和拉取请求。"
      ],
      [
        "每个对话都有浏览器",
        "位于每个对话的终端旁边。在你允许时，智能体可以打开网页、阅读内容并点击浏览。"
      ],
      [
        "智能体持续运行",
        "退出或更新 Coincide 时，后台宿主进程会让进行中的轮次继续运行。"
      ],
      [
        "计划任务和机器人",
        "在每个工作日早上九点发送提示词，或者为机器人设定性格和职责。"
      ],
      [
        "电脑控制",
        "默认关闭。开启后，智能体可以用自己的光标操作其他 Mac 应用。"
      ],
      [
        "听写",
        "使用 Apple 的设备端语音识别、本地 Whisper 模型，或你自己的 OpenAI 或 Groq 密钥。"
      ],
      [
        "用量面板",
        "各智能体套餐的用量上限，以及近期轮次的本地历史记录。"
      ],
      [
        "coincide 命令",
        "智能体和脚本可以在终端中创建对话、发送消息并等待回复。"
      ]
    ],
    "languageTitle": "Coincide 简体中文版",
    "languageText": "Coincide 提供 19 种语言。它会跟随你为 Mac 选择的语言，你也可以在“系统设置”›“通用”›“语言与地区”中为 Coincide 单独选择语言。译文由机器翻译，已标记为待审核，欢迎指正。",
    "helpTranslate": "如何帮助翻译",
    "remoteTitle": "即将推出：Coincide Remote",
    "remoteText": "适用于 iPhone 和 iPad 的配套应用，通过你自己的网络或 Tailscale 直接连接到 Mac 上的 Coincide。目前尚未发布。",
    "openTitle": "开源",
    "openText": "Coincide 免费，并以 MIT 许可证发布。源代码、Issue 和版本发布都在 GitHub 上，社区则在 Discord。Coincide 由 Apoorv Darshan 开发。",
    "github": "在 GitHub 上查看 Coincide",
    "discord": "加入 Discord",
    "englishNote": "本网站的文档和功能页面为英文。"
  }
});
