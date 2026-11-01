// Español home page: the translation of EN in _home.mjs.
import { localizedHome } from "./_home.mjs";

export default localizedHome({
  "lang": "es",
  "path": "/es",
  "nativeName": "Español",
  "ogLocale": "es_ES",
  "title": "Coincide: agentes de programación en una app nativa de Mac",
  "description": "Usa Claude Code, Codex, Cursor, Grok Build, OpenCode y Antigravity lado a lado en una app nativa para Mac y cambia de agente a mitad de una conversación.",
  "ui": {
    "skip": "Saltar al contenido",
    "navLabel": "Principal",
    "nav": [
      "Funciones",
      "Agentes",
      "Documentación",
      "Descargar",
      "FAQ",
      "GitHub"
    ],
    "get": "Obtener Coincide",
    "about": "Una app nativa para Mac para los agentes de programación que ya usas. Gratuita y de código abierto con licencia MIT."
  },
  "t": {
    "eyebrow": "Gratis y de código abierto · macOS",
    "h1": "Todos tus agentes de programación. Una sola app nativa para Mac.",
    "lede": "Coincide reúne Claude Code, Codex, Cursor, Grok Build, OpenCode y Antigravity en una sola ventana. Cada agente usa su propia herramienta de línea de comandos con el inicio de sesión o la clave de API que ya tienes, y puedes cambiar de agente en medio de una conversación.",
    "download": "Descargar para Mac",
    "allOptions": "Todas las formas de instalarlo",
    "requirements": "Requiere macOS 26 o posterior en un Mac con chip de Apple o procesador Intel. Cada versión está firmada con Developer ID y notarizada por Apple, y Coincide se actualiza solo.",
    "installTitle": "Instalar desde la línea de comandos",
    "homebrew": "Con Homebrew:",
    "npm": "Con npm (Node.js 18 o posterior), que comprueba la suma de verificación, la firma y la notarización de la descarga:",
    "agentsTitle": "Usa tus propios agentes",
    "agentsText": "Instala al menos un agente e inicia sesión en él. Coincide ejecuta la herramienta propia de ese agente en tu Mac, así que tus suscripciones actuales siguen funcionando. Nunca revende tus tokens, no los pasa por un proxy ni los mide.",
    "featuresTitle": "Lo que aporta Coincide",
    "features": [
      [
        "Cambia de agente a mitad de una conversación",
        "El siguiente agente recibe un resumen de los turnos que se perdió y continúa en la misma carpeta. Si vuelves al anterior, este retoma su propia sesión."
      ],
      [
        "Un solo selector de modelos",
        "Los modelos de todos los agentes instalados y con sesión iniciada en un único menú, con esfuerzo de razonamiento y modo rápido cuando el agente los admite."
      ],
      [
        "Proyectos y conversaciones",
        "Una barra lateral con búsqueda, fijar, archivar y posponer, y una paleta de comandos con ⌘K."
      ],
      [
        "Modo de planificación y aprobaciones",
        "Deja que un agente planifique primero, aprueba cada comando y cada cambio de archivo, o dale acceso total."
      ],
      [
        "Git integrado",
        "Diffs, puntos de control en cada turno, worktrees, commits, pushes y pull requests."
      ],
      [
        "Un navegador en cada conversación",
        "Junto a la terminal de cada conversación. Los agentes pueden abrir páginas, leerlas y navegar por ellas cuando lo permites."
      ],
      [
        "Los agentes siguen trabajando",
        "Un proceso en segundo plano mantiene los turnos en marcha cuando cierras o actualizas Coincide."
      ],
      [
        "Tareas programadas y bots",
        "Envía un prompt cada día laborable a las nueve, o dale a un bot una personalidad y una tarea."
      ],
      [
        "Computer Use",
        "Desactivado de forma predeterminada. Si lo activas, los agentes pueden manejar otras apps del Mac con su propio cursor."
      ],
      [
        "Dictado",
        "El reconocimiento de voz de Apple en el propio dispositivo, un modelo local de Whisper o tu propia clave de OpenAI o Groq."
      ],
      [
        "Panel de uso",
        "Los límites de uso de tus planes para cada agente, con un historial local de los turnos recientes."
      ],
      [
        "El comando coincide",
        "Agentes y scripts pueden crear conversaciones, enviar mensajes y esperar respuestas desde la Terminal."
      ]
    ],
    "languageTitle": "Coincide en español",
    "languageText": "Coincide está disponible en 19 idiomas. Usa el idioma que elegiste para tu Mac o el que configures para Coincide en Ajustes del Sistema (Configuración del Sistema en Latinoamérica) › General › Idioma y región. Las traducciones se hicieron de forma automática y están marcadas para revisión, así que las correcciones son bienvenidas.",
    "helpTranslate": "Cómo ayudar con las traducciones",
    "remoteTitle": "Próximamente: Coincide Remote",
    "remoteText": "Una app complementaria para iPhone y iPad que se conecta directamente a Coincide en tu Mac a través de tu propia red o de Tailscale. Todavía no se ha lanzado.",
    "openTitle": "Código abierto",
    "openText": "Coincide es gratuito y se publica con la licencia MIT. Su código fuente, sus issues y sus versiones están en GitHub, y la comunidad está en Discord. Lo desarrolla Apoorv Darshan.",
    "github": "Coincide en GitHub",
    "discord": "Únete al Discord",
    "englishNote": "La documentación y las páginas de funciones de este sitio están en inglés."
  }
});
