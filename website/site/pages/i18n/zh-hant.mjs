// 繁體中文 home page: the translation of EN in _home.mjs.
import { localizedHome } from "./_home.mjs";

export default localizedHome({
  "lang": "zh-Hant",
  "path": "/zh-hant",
  "nativeName": "繁體中文",
  "ogLocale": "zh_TW",
  "title": "Coincide：所有程式碼代理程式，盡在一款原生 Mac App",
  "description": "在一款原生 Mac App 中並排執行 Claude Code、Codex、Cursor、Grok Build、OpenCode 和 Antigravity，還能在對話途中切換代理程式。",
  "ui": {
    "skip": "跳至內容",
    "navLabel": "主選單",
    "nav": [
      "功能",
      "代理程式",
      "文件",
      "下載",
      "常見問題",
      "GitHub"
    ],
    "get": "取得 Coincide",
    "about": "一款原生 Mac App，適用於你已經在用的程式碼代理程式。採用 MIT 授權，免費且開放原始碼。"
  },
  "t": {
    "eyebrow": "免費且開放原始碼 · macOS",
    "h1": "所有程式碼代理程式，盡在一款原生 Mac App。",
    "lede": "Coincide 在同一個視窗中執行 Claude Code、Codex、Cursor、Grok Build、OpenCode 和 Antigravity。每個代理程式都使用自己的命令列工具，搭配你現有的登入或 API 金鑰；你也可以在對話途中切換代理程式。",
    "download": "下載 Mac 版",
    "allOptions": "所有安裝方式",
    "requirements": "需要搭載 Apple 晶片或 Intel 處理器、執行 macOS 26 或以上版本的 Mac。每個版本都以 Developer ID 簽署並經過 Apple 公證，Coincide 也會自動更新。",
    "installTitle": "從命令列安裝",
    "homebrew": "使用 Homebrew：",
    "npm": "使用 npm（Node.js 18 或以上版本），會檢查下載檔案的總和檢查碼、簽章與公證：",
    "agentsTitle": "使用你自己的代理程式",
    "agentsText": "至少安裝並登入一個代理程式。Coincide 會在你的 Mac 上啟動該代理程式本身的工具，因此你現有的訂閱方案照常可用。它絕不轉售、代理或計量你的 token。",
    "featuresTitle": "Coincide 帶來的功能",
    "features": [
      [
        "在對話途中切換代理程式",
        "下一個代理程式會收到它錯過的回合摘要，並在同一個資料夾中繼續工作。切換回來時，原本的代理程式會恢復它自己的工作階段。"
      ],
      [
        "統一的模型選擇器",
        "所有已安裝並登入的代理程式的模型都集中在一個選單中；代理程式支援時，還能選擇推理強度與快速模式。"
      ],
      [
        "專案與對話",
        "具備搜尋、置頂、封存與延後顯示功能的側邊欄，以及 ⌘K 指令面板。"
      ],
      [
        "計畫模式與核准",
        "讓代理程式先擬定計畫、逐一核准每個指令與檔案變更，或授予它完整取用權限。"
      ],
      [
        "內建 Git",
        "差異比對、每個回合的檢查點、工作樹、提交、推送與提取要求。"
      ],
      [
        "每個對話都有瀏覽器",
        "就在每個對話的終端機旁邊。經你允許後，代理程式可以開啟網頁、閱讀內容並點按瀏覽。"
      ],
      [
        "代理程式持續執行",
        "結束或更新 Coincide 時，背景主機程序會讓進行中的回合繼續執行。"
      ],
      [
        "排程任務與機器人",
        "在每個工作日早上九點傳送提示詞，或替機器人設定個性與工作。"
      ],
      [
        "電腦控制",
        "預設為關閉。開啟後，代理程式可以用自己的游標操作其他 Mac App。"
      ],
      [
        "聽寫",
        "使用 Apple 的裝置端語音辨識、本機 Whisper 模型，或你自己的 OpenAI 或 Groq 金鑰。"
      ],
      [
        "用量儀表板",
        "各代理程式方案的用量上限，以及近期回合的本機記錄。"
      ],
      [
        "coincide 指令",
        "代理程式和腳本可以在終端機中建立對話、傳送訊息並等待回覆。"
      ]
    ],
    "languageTitle": "Coincide 繁體中文版",
    "languageText": "Coincide 提供 19 種語言。它會依照你為 Mac 選擇的語言顯示，你也可以在「系統設定」›「一般」›「語言與地區」中為 Coincide 另外選擇語言。譯文由機器翻譯，已標示為待審閱，歡迎指正。",
    "helpTranslate": "如何協助翻譯",
    "remoteTitle": "即將推出：Coincide Remote",
    "remoteText": "適用於 iPhone 和 iPad 的配套 App，透過你自己的網路或 Tailscale 直接連線到 Mac 上的 Coincide。目前尚未推出。",
    "openTitle": "開放原始碼",
    "openText": "Coincide 免費，並以 MIT 授權釋出。原始碼、Issue 與版本發布都在 GitHub 上，社群則在 Discord。Coincide 由 Apoorv Darshan 開發。",
    "github": "在 GitHub 上查看 Coincide",
    "discord": "加入 Discord",
    "englishNote": "本網站的文件與功能頁面為英文。"
  }
});
