# Troubleshooting

## A Script Refuses To Run

Check that:

- PowerShell 7 is being used.
- `-ConfigPath` points to valid JSON.
- `-RootPath` exists.
- `-OutputPath` is writable.
- Output path is not inside the source root unless explicitly allowed.

## A Previous Stage Is Missing

Run the required earlier script. For example, metadata, dedupe, extraction, classification, and knowledge-base scripts require `outputs/inventory/inventory.csv`.

## External Tools Are Missing

Run the matching install helper for the operating system. The helpers check tools first and print install hints.

## OCR Or Transcription Is Skipped

Check `config/pipeline.example.json`. External conversion and transcription are disabled by default to keep first runs predictable.

## Reports Are Empty

Empty reports usually mean the stage found no matching files. For example, `03-Dedupe.ps1` may produce no duplicate groups when all hashes are unique.

## LLM Classification Fails

If stage 06 shows `llm_failed` status in classification.csv:

- Check that Ollama is running: `ollama serve`
- Verify the model name in `classification.model` config matches an installed model: `ollama list`
- Check the endpoint in `classification.ollamaEndpoint` defaults to `http://localhost:11434`
- If Ollama returns unstructured text (not JSON), the stage falls back to heuristic tags

## Python Sidecar Errors

Python sidecars require separate dependency installation:

```bash
pip install -r scripts/python/requirements-entities.txt
pip install -r scripts/python/requirements-search.txt
```

Run with `--help` to verify the script loads without ImportError (lazy imports ensure this works even without ML packages). If the ML model fails to download, check `~/.cache/huggingface/` for disk space.

## Cleanup Stage Does Nothing

Stage 10 requires all three conditions:
1. `cleanup.enabled = true` in config
2. `safety.allowDelete = true` in config
3. `-AllowDelete` flag on the command line

Missing any one causes the stage to skip with an info log message.

## Media Probe Shows Unknown

If `media_subtype` is empty after running stage 02:
- Ensure `metadata.enableMediaProbe = true` in config
- Verify ffprobe is installed: `ffprobe -version`
- The `metadata.ffprobe` command template must be present in config
