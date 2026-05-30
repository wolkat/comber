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
