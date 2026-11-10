# How Was Your Day

[Website](https://alepee.github.io/how-was-your-day/) · [Download](https://github.com/alepee/how-was-your-day/releases/latest)

A native macOS app for recording, transcribing and reviewing conversations locally. Built with SwiftUI and Swift Package Manager.

**Experimental, Apple Silicon, macOS 26 or later.** The interface is currently in French.

## Install

```sh
brew install --cask alepee/tap/how-was-your-day
```

Or download the DMG from [GitHub Releases](https://github.com/alepee/how-was-your-day/releases).

The app uses a persistent local signing certificate, but is **not notarized by Apple**. On first launch, macOS may require **System Settings > Privacy & Security > Open Anyway**. Allow microphone and system audio access when you start recording. Calendar access is optional.

```sh
brew upgrade --cask how-was-your-day
```

## Features

- Record microphone and system audio as synchronized, separate tracks.
- Pause and resume a recording without ending the session (button or ⌘⇧P). During a pause the audio device is stopped, so neither the microphone nor system audio is captured; the paused time is left out of the recording timeline, so notes stay aligned with the audio.
- Local French transcription with Apple SpeechAnalyzer; optional offline speaker diarization with FluidAudio.
- Review waveforms, play both tracks, solo or mute each track, and correct speaker assignments.
- Keep editable notes alongside the transcript and audio.
- Optional summaries: local through an OpenAI-compatible server such as LM Studio, hosted through the Mistral, OpenAI, Anthropic or Google Gemini APIs with your own API key, or written by your own coding agent over the Agent Client Protocol (Claude Code, Codex, Mistral Vibe, Grok, Gemini CLI), which can use what it knows about you in a separate context section. Reports include an overview, decisions, next steps and topic details with source references.
- Calendar context and explicit meeting reminders through macOS accounts, including Google and Microsoft accounts configured in Calendar.
- Light, dark and system appearance, menu bar access and a floating notepad.
- Versioned Markdown/JSON exports and a standalone stdio MCP server with segment-aware pagination, structured transcripts and time/speaker/track filters.
- Voice tiles in the session view: one per detected voice with its state (unidentified, proposed, confirmed). A click plays only that voice's passages back to back. Naming, confirming, linking to a known person or regrouping duplicates (menu or drag and drop) applies to the whole session and never creates a voice fingerprint. Two unnamed voices on different tracks must be named before they can be regrouped. A voice can also be ignored (speaker echo, noise): its passages are hidden from the transcript, the Markdown export, search, MCP and summaries, and can be restored from the tile.
- The transcript follows playback and highlights the passages being heard. Scrolling pauses the follow; « Suivre la lecture » resumes it.
- Explicit local voice enrollment from the speaker editor, with automatic name suggestions after diarization. Voice vectors stay in the macOS keychain, never in exports.

## Current limitations

Capture and speaker identity are experimental. HWYD applies experimental offline acoustic echo cancellation to a temporary microphone copy for dual-track transcriptions before speech recognition and diarization. Original playback audio is unchanged. Residual echo and simultaneous speech still require review. Existing transcripts need reprocessing. Changing audio devices stops the recording. Transcription runs after capture, with a fixed French locale; code-switching quality is not established.

Summaries require a separately running local server, a hosted provider API key, or an installed and signed-in ACP agent. An agent receives the session title, transcript and voice names, reads its own context, and returns the summary through the `submit_summary` tool of a restricted `hwyd-mcp`; HWYD refuses its requests to edit, delete or run commands, but permissions already granted in the agent's own configuration are its own. Embedded MLX inference is not implemented. With a hosted provider, the session title, transcript and voice names are sent to that provider on each summary, under its own data terms. Selecting a hosted provider and saving its key is the opt-in: the key is checked by listing the provider's models, which the settings then offer as a list and as completions. Notes, audio and voice fingerprints are never sent. API keys are stored in the macOS keychain. Hosted models read much larger portions per request, so a typical session needs only a few requests; costs are billed to your provider account. Hosted structured-output support varies by model: a model that rejects the schema reports the provider's error. The workflow extracts evidence from bounded portions, writes from the original words and checks proposed commitments. Short sessions avoid unnecessary topic routing. Requests run sequentially, with local checkpoints and stage progress. Audio model jobs and summary generation do not run concurrently inside HWYD.

Structured output and source references do not guarantee accuracy. Models can omit decisions or distort details, and summaries still need review. French, English and mixed transcripts have a synthetic [benchmark suite](docs/summary-benchmark.md); summaries are currently written in French. Input budgets limit each request, not the external server's memory allocation or model cache. With a local server, verify the context it actually reports. The optional reasoning toggle helps models that otherwise return no final JSON. See [summary workflow](docs/summary-workflow.md).

There is no automatic audio purge, app-level encryption, Sparkle updater or login item yet. Retention settings are not enforced. Uninstalling does not delete recordings or keychain entries. Voice matching thresholds are not calibrated on a representative corpus.

## Data and consent

Data lives in `~/Library/Application Support/HWYD`. Recording starts only on an explicit action. Inform participants and obtain the consent required for your use case. “Name only” changes the transcript; “Name and remember” also creates a local voice fingerprint. Suggested names require confirmation. Agents consuming your exports or MCP data may send that data elsewhere according to their own configuration. A hosted summary provider receives the transcript only after you enable it.

First-run model downloads are explicit. Audio is processed locally. No real recordings or transcripts are included in this repository.

## Build

Install Xcode 27 with Swift 6.4 or later. The pinned Swift Collections dependency requires Swift 6.4; the app deployment target remains macOS 26. No `.xcodeproj` is needed.

```sh
SIGN_IDENTITY='Your persistent code signing identity' scripts/build-app.sh debug
open 'build/How Was Your Day.app'
```

The local default is an `Apple Development` identity (a free Apple ID added in Xcode is enough). Its team ID keeps keychain and privacy permissions valid across rebuilds. The build fails if no matching certificate is available. For isolated development or CI only:

```sh
SIGN_IDENTITY=- HWYD_ALLOW_ADHOC=1 scripts/build-app.sh debug
```

Ad hoc signatures can cause repeated macOS permission prompts. Public release packaging refuses them. Never rebuild over an app that is recording. Use a separate output directory:

```sh
HWYD_APP_OUTPUT='build/validation/How Was Your Day.app' scripts/build-app.sh debug
```

## Test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HWYDCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
scripts/test-realtime.sh
python3 scripts/test-summary.py
'build/How Was Your Day.app/Contents/MacOS/HWYD' --self-test build/audio-test
'build/How Was Your Day.app/Contents/MacOS/HWYD' --ui-test build/ui-test
python3 scripts/test-mcp.py 'build/How Was Your Day.app/Contents/Helpers/hwyd-mcp' build/ui-test
'build/How Was Your Day.app/Contents/MacOS/HWYD' --snapshot build/screenshots
```

Use fresh test directories. Demo, snapshot, self-test and UI-test modes never capture the microphone. Tests using installed speech or diarization models are separate, opt-in checks.

## MCP

Configure your MCP client with this executable, using an absolute path:

```json
{
  "mcpServers": {
    "hwyd": {
      "command": "/Applications/How Was Your Day.app/Contents/Helpers/hwyd-mcp"
    }
  }
}
```

The app does not need to be running. Reads are enabled by default. Writing notes or renaming speakers requires both the app preference and the `--allow-write` argument.

## Project

| Path | Purpose |
| --- | --- |
| `Sources/HWYDApp` | SwiftUI app, capture and playback |
| `Sources/HWYDRealtime` | Allocation-free C audio callback and SPSC buffer |
| `Sources/HWYDPipeline` | Isolated speech, diarization and identity helper |
| `Sources/HWYDMCP` | Standalone MCP server |
| `Packages/HWYDCore` | Models, store, summaries, exports and tests |
| `docs` | Original French design documents, including planned features |

The [architecture draft](docs/architecture.md) describes the target, not a list of delivered features. See [release instructions](docs/distribution.md) for signing, packaging and Homebrew updates.
