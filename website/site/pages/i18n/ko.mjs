// 한국어 home page: the translation of EN in _home.mjs.
import { localizedHome } from "./_home.mjs";

export default localizedHome({
  "lang": "ko",
  "path": "/ko",
  "nativeName": "한국어",
  "ogLocale": "ko_KR",
  "title": "Coincide: 모든 코딩 에이전트를 하나의 네이티브 Mac 앱에서",
  "description": "Claude Code, Codex, Cursor, Grok Build, OpenCode, Antigravity를 하나의 네이티브 Mac 앱에서 나란히 실행하고, 스레드 도중에 에이전트를 바꿔 보세요.",
  "ui": {
    "skip": "본문으로 건너뛰기",
    "navLabel": "주 메뉴",
    "nav": [
      "기능",
      "에이전트",
      "문서",
      "다운로드",
      "FAQ",
      "GitHub"
    ],
    "get": "Coincide 받기",
    "about": "이미 사용 중인 코딩 에이전트를 위한 네이티브 Mac 앱입니다. MIT 라이선스로 제공되는 무료 오픈 소스입니다."
  },
  "t": {
    "eyebrow": "무료 오픈 소스 · macOS",
    "h1": "모든 코딩 에이전트를, 하나의 네이티브 Mac 앱에서.",
    "lede": "Coincide는 Claude Code, Codex, Cursor, Grok Build, OpenCode, Antigravity를 하나의 윈도우에서 실행합니다. 각 에이전트는 이미 가지고 있는 로그인이나 API 키로 자체 명령줄 도구를 사용하며, 스레드 도중에 에이전트를 바꿀 수 있습니다.",
    "download": "Mac용 다운로드",
    "allOptions": "모든 설치 방법",
    "requirements": "Apple 실리콘 또는 Intel 기반 Mac에서 macOS 26 이상이 필요합니다. 모든 릴리스는 Developer ID로 서명되고 Apple의 공증을 받으며, Coincide는 스스로 업데이트됩니다.",
    "installTitle": "명령줄로 설치하기",
    "homebrew": "Homebrew 사용:",
    "npm": "npm 사용(Node.js 18 이상). 다운로드한 파일의 체크섬, 서명, 공증을 확인합니다:",
    "agentsTitle": "사용 중인 에이전트를 그대로",
    "agentsText": "에이전트를 하나 이상 설치하고 로그인하세요. Coincide는 Mac에서 해당 에이전트의 자체 도구를 실행하므로, 기존 구독을 그대로 쓸 수 있습니다. 토큰을 재판매하거나, 프록시로 중계하거나, 계량하는 일은 절대 없습니다.",
    "featuresTitle": "Coincide가 더하는 기능",
    "features": [
      [
        "스레드 도중에 에이전트 전환",
        "다음 에이전트는 놓친 턴의 요약을 받아 같은 폴더에서 이어서 작업합니다. 다시 전환하면 처음 에이전트가 자신의 세션을 재개합니다."
      ],
      [
        "하나의 모델 선택기",
        "설치되고 로그인된 모든 에이전트의 모델을 하나의 메뉴에서. 에이전트가 지원하면 추론 수준과 빠른 모드도 선택할 수 있습니다."
      ],
      [
        "프로젝트와 스레드",
        "검색, 고정, 보관, 나중에 보기 기능이 있는 사이드바와 ⌘K 명령 팔레트."
      ],
      [
        "계획 모드와 승인",
        "에이전트가 먼저 계획을 세우게 하거나, 모든 명령과 파일 변경을 하나씩 승인하거나, 전체 접근 권한을 줄 수 있습니다."
      ],
      [
        "Git 내장",
        "diff, 턴마다 만드는 체크포인트, 워크트리, 커밋, 푸시, 풀 리퀘스트."
      ],
      [
        "스레드마다 브라우저",
        "각 스레드의 터미널 옆에 있습니다. 허용하면 에이전트가 페이지를 열고, 읽고, 클릭하며 탐색할 수 있습니다."
      ],
      [
        "에이전트는 계속 실행됩니다",
        "Coincide를 종료하거나 업데이트해도 백그라운드 호스트가 턴을 계속 진행합니다."
      ],
      [
        "예약 작업과 봇",
        "평일 아침 9시마다 프롬프트를 보내거나, 봇에게 성격과 역할을 부여하세요."
      ],
      [
        "컴퓨터 사용",
        "기본적으로 꺼져 있습니다. 켜면 에이전트가 자체 커서로 다른 Mac 앱을 조작할 수 있습니다."
      ],
      [
        "받아쓰기",
        "Apple의 온디바이스 음성 인식, 로컬 Whisper 모델, 또는 직접 보유한 OpenAI나 Groq 키를 사용합니다."
      ],
      [
        "사용량 대시보드",
        "에이전트별 요금제 사용량 한도와 최근 턴의 로컬 기록."
      ],
      [
        "coincide 명령어",
        "에이전트와 스크립트가 터미널에서 스레드를 만들고, 메시지를 보내고, 답장을 기다릴 수 있습니다."
      ]
    ],
    "languageTitle": "한국어로 만나는 Coincide",
    "languageText": "Coincide는 19개 언어로 제공됩니다. Mac에서 선택한 언어를 따르며, 시스템 설정 › 일반 › 언어 및 지역에서 Coincide용 언어를 따로 고를 수도 있습니다. 번역은 기계 번역이며 검토 대상으로 표시되어 있으니, 수정 제안을 환영합니다.",
    "helpTranslate": "번역을 돕는 방법",
    "remoteTitle": "출시 예정: Coincide Remote",
    "remoteText": "iPhone과 iPad용 동반 앱으로, 사용자의 네트워크나 Tailscale을 통해 Mac의 Coincide에 직접 연결됩니다. 아직 출시되지 않았습니다.",
    "openTitle": "오픈 소스",
    "openText": "Coincide는 무료이며 MIT 라이선스로 공개되어 있습니다. 소스 코드, 이슈, 릴리스는 GitHub에 있고, 커뮤니티는 Discord에 있습니다. Apoorv Darshan이 만들었습니다.",
    "github": "GitHub에서 Coincide 보기",
    "discord": "Discord 참여하기",
    "englishNote": "이 사이트의 문서와 기능 소개 페이지는 영어로 되어 있습니다."
  }
});
