# Speech models and downloads

Parakeet through mlx-audio (`Transcriber.swift`), Apple's `SpeechAnalyzer` (`AppleEngine.swift`), and the download and cache handling in `Config.swift` (`ModelChoice`, `ModelStatus`) and `Onboarding.swift`.

## mlx-audio's `language` parameter does nothing

It is copied into `STTOutput` and never reaches the decoder. A language picker for Parakeet would be a control that silently does nothing, which is why the Language setting only appears for Apple Intelligence. This is also why the default model is v2 (English-only) rather than the multilingual v3, which otherwise decodes short English clips as Cyrillic.

## Download progress cannot be a percentage

`URLSession.download` streams to a system temp path and only moves the finished file into the cache, so nothing observable grows during the transfer. A directory-derived percentage sits at 0% then jumps to 100%, reading as hung. `ModelStatus.downloading` therefore carries elapsed time.

Two cache locations matter: `~/.cache/huggingface/hub/models--…` (real download) and `~/.cache/huggingface/hub/mlx-audio/…` (mlx-audio's copy). Clearing only the second gives a fake fast "download" that is really a local copy. A real fresh-install test needs both gone.

## The cache root is not always `~/.cache/huggingface`

swift-huggingface resolves it as `HF_HUB_CACHE`, then `HF_HOME` + `/hub`, then the standard path. `ModelChoice.hubRoot` repeats those rules, including the sandbox branch Speak does not currently take, because the two disagreeing is a silent 2.4 GB re-download: Speak measured the standard path, said "already downloaded", and then sat on "loading model…" for four minutes with no progress bar while the library fetched the weights into the other cache. The disk-space figures in Settings were counting the wrong directory for the same reason.

This bites when running Speak **from a shell**, since anyone with local ML tooling tends to have `HF_HOME` set. A Finder launch inherits no shell environment, so it will not reproduce there. `env -u HF_HOME` when testing from a terminal, or expect a surprise download.

## Setup downloads nothing on its own

Leaving the welcome step used to start the default engine's download so it overlapped the permission steps. That is a good trade only for someone who wanted the default: everyone else spent a few hundred megabytes on a model they were about to replace, and on a slow or metered connection the choice was moot by the time they reached it.

So: the model step selects nothing until the user does (`Settings.modelChosen`, which is the presence of the `modelID` key, not a `choice` that always has a value), and the primary button *is* the consent, reading "Download Parakeet v3 (2,51 GB)". `Onboarding.pickModel` loads an engine only when `isDownloaded`, and calls `App.idleModel()` otherwise, which also cancels any fetch already running. Anything that starts a download without a press reintroduces the complaint.

`structuralKey()` must keep `.idle` distinct from `.downloading`. Folded together, the step that starts a download keeps the body it was built with, so the progress bar is never created and the download runs invisibly. (Why `structuralKey()` exists: `docs/ui.md`.)
