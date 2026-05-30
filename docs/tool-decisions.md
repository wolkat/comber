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
