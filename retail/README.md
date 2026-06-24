# retail

This template should help get you started developing with Vue 3 in Vite.

## Recommended IDE Setup

[VS Code](https://code.visualstudio.com/) + [Vue (Official)](https://marketplace.visualstudio.com/items?itemName=Vue.volar) (and disable Vetur).

## Recommended Browser Setup

- Chromium-based browsers (Chrome, Edge, Brave, etc.):
  - [Vue.js devtools](https://chromewebstore.google.com/detail/vuejs-devtools/nhdogjmejiglipccpnnnanhbledajbpd)
  - [Turn on Custom Object Formatter in Chrome DevTools](http://bit.ly/object-formatters)
- Firefox:
  - [Vue.js devtools](https://addons.mozilla.org/en-US/firefox/addon/vue-js-devtools/)
  - [Turn on Custom Object Formatter in Firefox DevTools](https://fxdx.dev/firefox-devtools-custom-object-formatters/)

## Type Support for `.vue` Imports in TS

TypeScript cannot handle type information for `.vue` imports by default, so we replace the `tsc` CLI with `vue-tsc` for type checking. In editors, we need [Volar](https://marketplace.visualstudio.com/items?itemName=Vue.volar) to make the TypeScript language service aware of `.vue` types.

## Customize configuration

See [Vite Configuration Reference](https://vite.dev/config/).

## Project Setup

```sh
bun install
```

### Compile and Hot-Reload for Development

```sh
bun dev
```

### Type-Check, Compile and Minify for Production

```sh
bun run build
```

### Lint with [ESLint](https://eslint.org/)

```sh
bun lint
```

---

## retaillm — Dashboard + consulta en vivo (Fase 7)

Interfaz del proyecto: visualiza los resultados (6.3 rendimiento, 6.2 agéntico, 6.4
comparación) y permite **consultar al agente en lenguaje natural** desde el navegador.

### Datos del dashboard

El front consume `public/data/dashboard.json`, generado desde `../results/` por un
agregador en Python (solo stdlib):

```sh
python3 build_data.py     # ../results/ -> public/data/dashboard.json
```

Re-córrelo cada vez que regeneres resultados (corrida EMR, agente o comparación).

### Backend (consulta en vivo)

`server.py` reúsa el pipeline del agente y expone `POST /api/ask`. Se lanza con
`run_ui.sh` (entorno `uv` con pyspark + jdk4py), que además sirve `dist/`:

```sh
bun run build            # compila la app a dist/
bash run_ui.sh           # backend + app en http://localhost:8000
# desarrollo con hot-reload: 'bun dev' en otra terminal (proxa /api -> :8000)
```

### Backend LLM: Gemini u opencode

El agente soporta dos backends vía `LLM_BACKEND`:

| `LLM_BACKEND` | Cliente | Requiere |
|---------------|---------|----------|
| `opencode` (**default**) | `../agentic/opencode_client.py` (CLI `opencode run`, modelos gratis) | `opencode` instalado |
| `gemini` | `../agentic/gemini_client.py` (SDK google-genai) | `GEMINI_API_KEY` en `../.env` |

```sh
# Default: opencode (no necesita GEMINI_API_KEY; no depende de la cuota de Gemini):
bash run_ui.sh
# modelo opcional (default opencode/deepseek-v4-flash-free):
OPENCODE_MODEL=opencode/mimo-v2.5-free bash run_ui.sh
# Para volver a Gemini (necesita GEMINI_API_KEY en ../.env):
LLM_BACKEND=gemini bash run_ui.sh
```

Lo mismo aplica a `../agentic/run_agent.sh`. Tiempos: opencode ~10–20 s/consulta; Gemini
free tier ~30–60 s (espaciado de cuota) y se agota (429) tras varias corridas.
