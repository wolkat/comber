# Architecture

Comber is a staged pipeline. Each stage reads source files or previous-stage outputs, validates inputs, writes its own outputs, and exits with a clear code.

```mermaid
flowchart LR
  A["Source archive"] --> B["01 Inventory"]
  B --> C["02 Metadata"]
  B --> D["03 Dedupe"]
  B --> E["04 Extract text"]
  B --> F["05 Transcribe media"]
  C --> G["06 Classify themes"]
  E --> G
  F --> G
  B --> H["07 Build knowledge base"]
  C --> H
  D --> H
  E --> H
  F --> H
  G --> H
  B --> I["08 Review reports"]
  C --> I
  D --> I
  E --> I
  F --> I
  G --> I
  I --> J["09 Apply reviewed actions"]
```

## State

The toolkit does not require a service or database server.

- CSV is used for reviewable tables.
- JSON sidecars are used where nested metadata is useful.
- Markdown is used for the final knowledge base.
- Logs capture operational details.

## Trust Boundaries

- File inventory and hashes are deterministic.
- Duplicate candidates are recommendations until a human approves a manifest.
- Near-duplicate detection uses perceptual hashing (ImageMagick `identify`) or Czkawka CLI, both opt-in via `dedupe` config section.
- LLM outputs are treated as untrusted annotations.
- The reviewed-action script is the only script that may move or delete files.
