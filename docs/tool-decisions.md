# Tool Decisions

## PowerShell 7

PowerShell 7 is used because it runs on Windows, macOS, and Linux and gives enough filesystem and process control without adding a heavy framework.

## CSV and Markdown

CSV is used for reports that humans can inspect in spreadsheet tools. Markdown is used for the knowledge base so the output stays portable and durable.

## SQLite/DuckDB

The first implementation uses CSV to keep the toolkit simple. A later version can add SQLite or DuckDB if the archive is too large for comfortable CSV workflows.

## External Tools

External tools are optional unless a stage explicitly needs them. Their command templates live in config so users can adjust flags without editing scripts.

## LLMs

LLMs are useful for tags, themes, summaries, and captions. They are not used for deletion decisions.

LLM responses are parsed for structured JSON using `ConvertFrom-ArchiveLlmJson`, which extracts the first complete JSON object from response text using brace matching. This handles markdown-wrapped JSON, trailing text, and malformed responses gracefully.

When `classification.enabled` is true, stage 06 calls Ollama's `/api/chat` endpoint with a system prompt and file content. The endpoint, model, and system prompt are configurable in the `classification` config section.

## Czkawka

Czkawka CLI is used for near-duplicate image and video detection when enabled via `dedupe.enableNearDuplicate`. It performs content-based similarity comparison beyond what SHA256 exact matching can catch. The command template lives in the config so flags can be adjusted per installed version.

## Perceptual Hashing (ImageMagick)

ImageMagick `identify` is used as a pre-filter for near-duplicate image detection. It produces a signature hash that can be compared with a configurable distance threshold. This runs before Czkawka when both are available, providing fast pairwise comparison for image files. The dHash implementation converts the signature into a 64-bit fingerprint and compares bit-distance as a similarity ratio.

## Python Sidecars

Features requiring ML/NLP libraries that lack PowerShell equivalents are implemented as Python scripts in `scripts/python/`. Each script supports `--help` with full argument documentation and examples.

The two Python sidecars are:
- `10_extract_entities.py` — NER using GLiNER2 (CPU-efficient, 205M params). Reads classification.csv and extracted/transcript markdown, writes entities.csv.
- `11_semantic_search.py` — Vector search using sentence-transformers + ChromaDB. Index mode builds embeddings from vault notes; query mode searches with natural language.

All Python dependencies are documented in requirements files: `requirements-entities.txt` and `requirements-search.txt`. Heavy imports (gliner2, chromadb, sentence_transformers) are lazy-loaded inside functions so `--help` works without installing anything.

## FFprobe Media Probe

ffprobe is used for media type auto-detection when `metadata.enableMediaProbe` is enabled. It probes audio/video files for codec, dimensions, and duration, distinguishing video, slideshow (vcodec=none), and audio-only content. This is more reliable than extension-based categorization alone.

## Cleanup Stage

Stage 10 (Cleanup) deletes intermediate artifacts (extracted text, transcripts, sidecar JSONs) after they've been consumed by the knowledge base. It follows the same safety model as stage 09: requires both `config.safety.allowDelete=true` and the `-AllowDelete` CLI flag. Targets are configurable via the `cleanup.targets` array.
