#!/usr/bin/env python3
"""
10_extract_entities.py - Extract named entities from processed files using GLiNER2

Extends Comber's pipeline with CPU-efficient NER. Reads classification results
from stage 06, finds corresponding extracted text or transcript markdown, runs
GLiNER2 NER with configurable entity labels, and writes deduplicated results
to entities.csv.

Usage:
    python 10_extract_entities.py --classification-csv <path> --output-dir <path>
                                   [--model <name>] [--labels <list>]
                                   [--threshold <float>] [--max-chars <int>]
                                   [--verbose]
    python 10_extract_entities.py --help

Examples:
    # Extract entities using defaults
    python 10_extract_entities.py \\
        --classification-csv outputs/classification/classification.csv \\
        --output-dir outputs

    # Custom labels and higher threshold
    python 10_extract_entities.py \\
        --classification-csv outputs/classification/classification.csv \\
        --output-dir outputs \\
        --labels person organization location \\
        --threshold 0.7

    # Debug-level logging
    python 10_extract_entities.py \\
        --classification-csv outputs/classification/classification.csv \\
        --output-dir outputs --verbose
"""

import argparse
import csv
import logging
import os
import sys
from collections import OrderedDict

# NOTE: yaml (pyyaml) is imported lazily inside _read_frontmatter_source_path
#       to ensure --help works without runtime dependencies.


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("extract_entities")


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args(argv=None):
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description=(
            "Extract named entities from processed files using GLiNER2. "
            "Reads classification.csv, finds corresponding extracted/transcript "
            "markdown, runs NER, and writes deduplicated entities."
        ),
    )
    parser.add_argument(
        "--classification-csv",
        required=True,
        help="Path to classification.csv (output from stage 06-ClassifyThemes)",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help=(
            "Output directory root (e.g., outputs/). Entities CSV is written to "
            "<output-dir>/entities/entities.csv."
        ),
    )
    parser.add_argument(
        "--model",
        default="fastino/gliner2-base-v1",
        help="GLiNER2 HuggingFace model name (default: fastino/gliner2-base-v1)",
    )
    parser.add_argument(
        "--labels",
        nargs="+",
        default=[
            "person", "brand", "organization", "location",
            "topic", "concept", "product", "event",
        ],
        help=(
            "Entity labels to extract (default: person brand organization "
            "location topic concept product event)"
        ),
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.5,
        help="Confidence threshold for entity detection, 0.0-1.0 (default: 0.5)",
    )
    parser.add_argument(
        "--max-chars",
        type=int,
        default=10000,
        help="Maximum text characters to process per file (default: 10000)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable debug-level logging",
    )
    return parser.parse_args(argv)


# ---------------------------------------------------------------------------
# CSV I/O
# ---------------------------------------------------------------------------

def read_classification_csv(path):
    """Read classification.csv and return list of dicts.

    Args:
        path: Absolute or relative path to classification.csv.

    Returns:
        list[dict]: Rows keyed by column name.

    Raises:
        SystemExit: If the file does not exist or is unreadable.
    """
    if not os.path.isfile(path):
        log.error("Classification CSV not found: %s", path)
        sys.exit(1)

    rows = []
    with open(path, "r", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        if not reader.fieldnames:
            log.error("Empty or unreadable classification CSV: %s", path)
            sys.exit(1)
        for row in reader:
            rows.append(row)

    if not rows:
        log.warning("Classification CSV contains no data rows: %s", path)

    log.info("Read %d rows from %s", len(rows), path)
    return rows


def write_entities_csv(entities, output_path):
    """Write entities list-of-dicts to CSV.

    Columns: source_path, entity_text, entity_label, confidence, mention_count

    Args:
        entities: list[dict] with keys matching fieldnames.
        output_path: Destination CSV path.
    """
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    fieldnames = [
        "source_path",
        "entity_text",
        "entity_label",
        "confidence",
        "mention_count",
    ]
    with open(output_path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(entities)

    log.info("Wrote %d entity rows to %s", len(entities), output_path)


# ---------------------------------------------------------------------------
# Content file discovery via YAML frontmatter
# ---------------------------------------------------------------------------

def _read_frontmatter_source_path(md_path):
    """Extract ``source_path`` from YAML frontmatter of a markdown file.

    Searches for the first YAML block delimited by ``---`` lines at the
    start of the file. Returns the value of ``source_path`` if found,
    otherwise ``None``.

    Args:
        md_path: Path to a markdown file.

    Returns:
        str or None: Normalized source_path value.
    """
    # Lazily import yaml so --help works without pyyaml installed
    try:
        import yaml as _yaml
    except ImportError:
        log.warning("pyyaml is not installed; cannot parse frontmatter in %s", md_path)
        return None

    try:
        with open(md_path, "r", encoding="utf-8") as fh:
            content = fh.read()
    except Exception as exc:
        log.debug("Cannot read %s: %s", md_path, exc)
        return None

    # YAML frontmatter is delimited by --- on its own line at file start
    stripped = content.lstrip()
    if not stripped.startswith("---"):
        log.debug("No YAML frontmatter delimiter in %s", md_path)
        return None

    end_idx = stripped.find("---", 3)
    if end_idx == -1:
        log.debug("Unclosed YAML frontmatter in %s", md_path)
        return None

    yaml_block = stripped[3:end_idx]
    try:
        meta = _yaml.safe_load(yaml_block) or {}
    except Exception as exc:
        log.debug("Cannot parse YAML frontmatter in %s: %s", md_path, exc)
        return None

    source_path = meta.get("source_path")
    if source_path:
        return os.path.normpath(str(source_path))
    return None


def build_content_map(output_dir):
    """Scan extracted/ and transcripts/ directories and build a
    ``source_path -> markdown_file_path`` mapping.

    Each markdown file's YAML frontmatter is read to obtain the original
    source path. This handles hash-based filenames that cannot be
    reverse-mapped from the classification CSV path alone.

    Args:
        output_dir: Root output directory (e.g., ``outputs/``).

    Returns:
        dict: ``{normalized_source_path: absolute_md_path}``
    """
    content_map = {}

    for subdir in ("extracted", "transcripts"):
        dir_path = os.path.join(output_dir, subdir)
        if not os.path.isdir(dir_path):
            log.debug("Skipping missing content directory: %s", dir_path)
            continue

        for entry in sorted(os.listdir(dir_path)):
            if not entry.endswith(".md"):
                continue
            md_path = os.path.join(dir_path, entry)
            source_path = _read_frontmatter_source_path(md_path)
            if source_path:
                content_map[source_path] = md_path

    log.info("Found %d content files (extracted + transcripts)", len(content_map))
    return content_map


# ---------------------------------------------------------------------------
# Text extraction helpers
# ---------------------------------------------------------------------------

def strip_frontmatter(markdown_text):
    """Remove YAML frontmatter delimited by ``---`` from markdown text.

    Only strips frontmatter at the very start of the text (after leading
    whitespace). Everything after the closing ``---`` is returned as body.

    Args:
        markdown_text: Raw markdown content.

    Returns:
        str: Body text after the frontmatter block.
    """
    stripped = markdown_text.lstrip()
    if not stripped.startswith("---"):
        return markdown_text

    end_idx = stripped.find("---", 3)
    if end_idx == -1:
        return markdown_text

    return stripped[end_idx + 3:].lstrip()


def read_body_text(md_path, max_chars):
    """Read a markdown file and return the body text.

    Strips YAML frontmatter and truncates to *max_chars*.

    Args:
        md_path: Path to markdown file.
        max_chars: Maximum characters to return.

    Returns:
        str: Body text, possibly truncated.
    """
    try:
        with open(md_path, "r", encoding="utf-8") as fh:
            content = fh.read()
    except Exception as exc:
        log.warning("Cannot read %s: %s", md_path, exc)
        return ""

    body = strip_frontmatter(content)
    if len(body) > max_chars:
        body = body[:max_chars]
    return body


# ---------------------------------------------------------------------------
# NER extraction with GLiNER2
# ---------------------------------------------------------------------------

def extract_entities(ner_model, text, labels, threshold):
    """Run GLiNER2 NER on *text* and deduplicate results.

    Entities with the same normalized text (case-insensitive) and label
    are merged: ``mention_count`` is incremented and ``confidence`` holds
    the highest score across mentions.

    Args:
        ner_model: Loaded GLiNER2 model instance.
        text: Input text to analyze.
        labels: List of entity labels to search for.
        threshold: Confidence threshold (0.0-1.0).

    Returns:
        list[dict]: Each entry has keys ``entity_text``, ``entity_label``,
        ``confidence``, ``mention_count``.
    """
    if not text.strip():
        return []

    results = ner_model.predict_entities(text, labels, threshold=threshold)

    # Deduplicate by (text.lower().strip(), label), keeping highest confidence
    seen = OrderedDict()
    for entity in results:
        raw_text = entity.get("text", "").strip()
        if not raw_text:
            continue

        key = (raw_text.lower(), entity.get("label", ""))
        score = entity.get("score", threshold)

        if key not in seen:
            seen[key] = {
                "entity_text": raw_text,
                "entity_label": entity.get("label", ""),
                "confidence": score,
                "mention_count": 1,
            }
        else:
            seen[key]["mention_count"] += 1
            if score > seen[key]["confidence"]:
                seen[key]["confidence"] = score

    return list(seen.values())


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def main():
    """Orchestrate entity extraction pipeline."""
    args = parse_args()

    if args.verbose:
        logging.getLogger("extract_entities").setLevel(logging.DEBUG)

    # ------------------------------------------------------------------
    # 1. Load GLiNER2 model
    # ------------------------------------------------------------------
    log.info("Loading GLiNER2 model: %s", args.model)
    try:
        from gliner import GLiNER as _GLiNER
    except ImportError:
        log.error(
            "GLiNER2 is not installed. Install it with: "
            "pip install gliner2"
        )
        sys.exit(1)

    try:
        ner_model = _GLiNER.from_pretrained(args.model)
    except Exception as exc:
        log.error(
            "Failed to load model '%s': %s", args.model, exc
        )
        sys.exit(1)

    log.info("Model loaded successfully")

    # ------------------------------------------------------------------
    # 2. Read classification CSV
    # ------------------------------------------------------------------
    classification_rows = read_classification_csv(args.classification_csv)
    if not classification_rows:
        log.warning("No classification rows to process; writing empty entities CSV.")
        entities_dir = os.path.join(args.output_dir, "entities")
        os.makedirs(entities_dir, exist_ok=True)
        entities_path = os.path.join(entities_dir, "entities.csv")
        write_entities_csv([], entities_path)
        return

    # ------------------------------------------------------------------
    # 3. Build content file map (source_path -> markdown file)
    # ------------------------------------------------------------------
    content_map = build_content_map(args.output_dir)

    # ------------------------------------------------------------------
    # 4. Process each classification entry
    # ------------------------------------------------------------------
    all_entities = []
    processed = 0
    skipped_no_content = 0
    skipped_no_text = 0

    for row in classification_rows:
        source_path = row.get("path", "").strip()
        if not source_path:
            log.debug("Skipping classification row with empty path")
            continue

        norm_source = os.path.normpath(source_path)

        # Find the corresponding markdown content file
        md_path = content_map.get(norm_source)
        if not md_path:
            log.debug("No content file found for: %s", source_path)
            skipped_no_content += 1
            continue

        # Read body text (stripped of frontmatter)
        body = read_body_text(md_path, args.max_chars)
        if not body.strip():
            log.debug("Empty body text for: %s", source_path)
            skipped_no_text += 1
            continue

        # Run NER
        file_entities = extract_entities(
            ner_model, body, args.labels, args.threshold,
        )

        # Tag each entity with its source path
        for ent in file_entities:
            ent["source_path"] = source_path

        all_entities.extend(file_entities)
        processed += 1

        log.debug(
            "Processed: %s -> %d entities (%d chars)",
            os.path.basename(source_path),
            len(file_entities),
            len(body),
        )

    # ------------------------------------------------------------------
    # 5. Write entities CSV
    # ------------------------------------------------------------------
    entities_dir = os.path.join(args.output_dir, "entities")
    os.makedirs(entities_dir, exist_ok=True)
    entities_path = os.path.join(entities_dir, "entities.csv")

    write_entities_csv(all_entities, entities_path)

    # ------------------------------------------------------------------
    # 6. Summary
    # ------------------------------------------------------------------
    log.info(
        "Summary: %d files processed, %d entities extracted, "
        "%d skipped (no content), %d skipped (empty text)",
        processed,
        len(all_entities),
        skipped_no_content,
        skipped_no_text,
    )


if __name__ == "__main__":
    main()
