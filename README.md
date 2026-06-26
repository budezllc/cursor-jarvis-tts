# Jarvis TTS by Kei Sakai @keisakaix

Speaks Cursor agent replies in a British Jarvis-style voice (`en-GB-RyanNeural` via [edge-tts](https://github.com/rany2/edge-tts)).

Uses the `afterAgentResponse` hook with debouncing, deduplication, and short summaries (first 3 sentences) so you hear a concise spoken briefing instead of the full markdown essay.

## Prerequisites (Windows)

```powershell
pip install edge-tts
winget install Gyan.FFmpeg
```

- **edge-tts** — generates speech (free Microsoft neural voices)
- **ffmpeg / ffplay** — plays MP3 audio; `auto` mode also uses ffmpeg to convert MP3→WAV for Windows SoundPlayer

## Install in Cursor

1. Open **Cursor → Customize → Plugins**
2. Click **+ Add** → choose **from local folder** or paste the GitHub URL: `https://github.com/budezllc/cursor-jarvis-tts`
3. For local install, select this repo folder (must contain `.cursor-plugin/marketplace.json` and `plugin.json`)
4. **Reload Cursor**
6. Send an agent message — you should hear Jarvis after the reply finishes streaming

## Verify

- **Settings → Hooks** — should show `afterAgentResponse` from the plugin
- **View → Output → Hooks** — shows hook runs and exit codes
- **Log file** — `scripts\tts.log` inside this plugin folder

## Customize voice

Edit the profile at the top of `scripts/speak-response.ps1`:

| Variable | Default | Purpose |
|---|---|---|
| `$Voice` | `en-GB-RyanNeural` | British male Jarvis voice |
| `$Rate` | `-10%` | Slower, deliberate delivery |
| `$MaxChars` | `500` | Max spoken characters |
| `$MaxSentences` | `3` | Sentence cap before "more in the chat, sir" |
| `$DebounceSec` | `2.5` | Wait for streaming to settle |
| `$PlaybackMode` | `auto` | Audio backend: `auto`, `soundplayer`, `ffplay`, `default` |

List voices: `edge-tts --list-voices | findstr GB`

## Structure

```
cursor-jarvis-tts/
├── .cursor-plugin/
│   ├── plugin.json              # Plugin manifest
│   └── marketplace.json         # Required for local / multi-plugin install
├── assets/logo.svg              # Plugin icon
├── hooks/hooks.json             # afterAgentResponse registration
├── scripts/speak-response.ps1   # TTS engine
└── rules/jarvis-tts-setup.mdc   # Setup reminder for the agent
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| No sound | Check `scripts/tts.log` for `ERROR edge-tts not found` |
| Wrong device / silent with ffplay | Set `$PlaybackMode = 'soundplayer'` or keep `auto` (uses Windows default output) |
| Double speech | Remove `~/.cursor/hooks.json` duplicate hook |
| Repeating lines | Fixed via debounce + dedup; reload Cursor after update |
| Long replies fail | Script uses file input to edge-tts (not CLI args) |

## License

MIT
