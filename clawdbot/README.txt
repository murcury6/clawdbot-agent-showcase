Portable Clawd USB layout

Root items:
- clawdbot
- 1 - Start Bot.bat
- 2 - Chat With Bot.bat
- 3 - Check Bot.bat
- 4 - Stop Bot.bat
- 5 - Settings.bat
- 6 - Fresh Start Bot.bat

Everything needed to run lives inside the clawdbot folder.

Notes:
- On first start, the portable bot imports the bundled GGUF model into its own Ollama store on the USB drive.
- The Start window now shows startup status and can be closed after it says the bot is running.
- The portable launchers read Telegram and GPT API values from `clawdkeys`, import them into a local protected store, and clear the plain input file back to a blank template after sync.
- Edit the assistant personality and rules in `EDIT_AI_HERE`; the launcher syncs that folder into the real workspace prompt files before each run.
- Manual local use is protected by a one-time unlock code sent to your Telegram chat on your phone before start, chat, settings, status, or direct portable startup will run.
- Use `telegram phone:` in `clawdkeys\ENTER_KEYS_HERE.txt` if you want the unlock prompt to show which phone the Telegram startup code is meant for.
- Settings includes a model selector with `auto`, `smart-cost`, `online-first`, and `offline-first`.
- `smart-cost` keeps routine work on the best safe local model it can find, and reserves stronger cloud reasoning for harder spawned work.
- In `smart-cost`, Telegram direct chats prefer `openai/gpt-5-nano` when the API-key probe passes, while harder spawned work can still escalate to the strongest healthy cloud route.
- Telegram is now treated as an ordered job queue: text jobs to add them, ask for the list, and tell the bot what order to do them in.
- While unfinished jobs exist, the bot sends milestone updates plus a 10-minute Telegram status list with current work, completed chunks, and queue order.
- The manual Start launcher now re-arms the watchdog and clears any stop pause marker before startup.
- The Stop launcher now writes a local pause marker so the watchdog does not immediately start the stack again.
- The Fresh Start launcher clears sessions, queue state, memory notes, unlock state, and logs while keeping Telegram keys, model settings, and the rest of the bot setup intact.
- A Windows watchdog is installed as a 5-minute scheduled task plus a Startup entry for the logged-in user, so the bot can resume after login and restart the stack if the local services crash.
- That watchdog uses an internal trusted launch path so unattended recovery can work; the manual launchers still require the Telegram unlock code.
- In `auto`, the portable controller probes ChatGPT OAuth, the API key, and each bundled local tier. It prefers the healthiest cloud route first, then the API key route, then the best healthy offline tier for the current PC.
- The offline ladder on the USB includes `1b`, `3b`, `7b`, and a top large-model tier. The selector chooses the biggest safe tier for the current Windows machine.
- If no online model is reachable, the selector will still fall back to the best bundled offline tier it can find.
- Tool policy is configured for the full OpenClaw surface, including on Ollama fallback runs. Some tools are still gated by model/provider/runtime capability, so local models may expose fewer usable tools in practice.
- Windows mouse and keyboard control is available through `scripts\desktop-input.bat` when the PC is unlocked and the desktop is visible.
- The unlock-code delivery uses Telegram, not plain SMS. Internet access is required when a fresh code needs to be sent.
- The unlock is now per launch: each new launcher run asks for a fresh Telegram code, and the bot does not start until that code is typed in.
- `openclaw.json` no longer needs to keep the common Telegram/OpenAI/Google keys inline; the launcher injects those at runtime from the protected store instead.
