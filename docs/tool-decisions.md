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

## Czkawka

Czkawka CLI is used for near-duplicate image and video detection when enabled via `dedupe.enableNearDuplicate`. It performs content-based similarity comparison beyond what SHA256 exact matching can catch. The command template lives in the config so flags can be adjusted per installed version.

## Perceptual Hashing (ImageMagick)

ImageMagick `identify` is used as a pre-filter for near-duplicate image detection. It produces a signature hash that can be compared with a configurable distance threshold. This runs before Czkawka when both are available, providing fast pairwise comparison for image files. The dHash implementation converts the signature into a 64-bit fingerprint and compares bit-distance as a similarity ratio.
