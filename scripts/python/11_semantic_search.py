#!/usr/bin/env python3
"""
11_semantic_search.py - Semantic search over archive vault using vector embeddings

Builds a ChromaDB index from vault notes, extracted text, and transcripts, then
enables natural-language queries via sentence-transformers embeddings.

Usage:
    # Index mode: build or update the ChromaDB collection
    python 11_semantic_search.py --mode index --vault-dir outputs/vault/archive-vault
                                   [--classification-csv outputs/classification/classification.csv]
                                   [--output-dir outputs]
                                   [--model all-MiniLM-L6-v2]
                                   [--persist-dir outputs/chroma_db]
                                   [--max-chars 5000]

    # Query mode: search an existing index
    python 11_semantic_search.py --mode query --query "what documents mention OCR"
                                   [--top-k 10]
                                   [--model all-MiniLM-L6-v2]
                                   [--persist-dir outputs/chroma_db]

    # Help
    python 11_semantic_search.py --help

Examples:
    python 11_semantic_search.py --mode index --vault-dir outputs/vault/archive-vault
    python 11_semantic_search.py --mode query --query "extracted text from screenshots" --top-k 5
    python 11_semantic_search.py --mode query --query "duplicate files" --persist-dir ./chroma_db
"""

import argparse
import csv
import logging
import os
import re
import sys

# yaml is imported lazily in functions that need it


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("semantic_search")


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_MODEL = "all-MiniLM-L6-v2"
DEFAULT_PERSIST_DIR = os.path.join("outputs", "chroma_db")
DEFAULT_MAX_CHARS = 5000
DEFAULT_TOP_K = 10
SEARCH_OUTPUT_FILE = "search-results.csv"


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args(argv=None):
    """Parse and validate command-line arguments."""
    parser = argparse.ArgumentParser(
        description=(
            "Semantic search over archive vault using vector embeddings. "
            "Index mode reads vault notes and builds a ChromaDB collection. "
            "Query mode searches the collection with a natural-language query."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python 11_semantic_search.py --mode index --vault-dir outputs/vault/archive-vault\n"
            "  python 11_semantic_search.py --mode query --query \"what documents mention OCR\" --top-k 5\n"
            "  python 11_semantic_search.py --mode query --query \"duplicate files\" --persist-dir ./chroma_db\n"
        ),
    )
    parser.add_argument(
        "--mode",
        required=True,
        choices=["index", "query"],
        help="Operation mode: 'index' to build/update the collection, 'query' to search it.",
    )
    parser.add_argument(
        "--vault-dir",
        default=None,
        help="Path to vault directory containing markdown notes (required for index mode).",
    )
    parser.add_argument(
        "--classification-csv",
        default=None,
        help="Path to classification.csv for enriching metadata with confidence and theme data.",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help=(
            "Root output directory (e.g., outputs/). Used to discover extracted/ "
            "and transcripts/ directories for additional index sources."
        ),
    )
    parser.add_argument(
        "--query",
        default=None,
        type=str,
        help="Natural-language search query (required for query mode).",
    )
    parser.add_argument(
        "--top-k",
        default=DEFAULT_TOP_K,
        type=int,
        help="Number of top results to return in query mode (default: %d)." % DEFAULT_TOP_K,
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help="Sentence-transformers model name for embeddings (default: %s)." % DEFAULT_MODEL,
    )
    parser.add_argument(
        "--persist-dir",
        default=DEFAULT_PERSIST_DIR,
        help="Directory for ChromaDB persistence (default: %s)." % DEFAULT_PERSIST_DIR,
    )
    parser.add_argument(
        "--max-chars",
        default=DEFAULT_MAX_CHARS,
        type=int,
        help="Maximum characters of body text to embed per file (default: %d)." % DEFAULT_MAX_CHARS,
    )
    return parser.parse_args(argv)


def _validate_args(args):
    """Validate mode-specific required arguments; exit with error if missing."""
    if args.mode == "index" and not args.vault_dir:
        log.error("--vault-dir is required in index mode")
        sys.exit(1)
    if args.mode == "query" and not args.query:
        log.error("--query is required in query mode")
        sys.exit(1)


# ---------------------------------------------------------------------------
# YAML frontmatter I/O
# ---------------------------------------------------------------------------

def _read_yaml_frontmatter(text):
    """Extract and parse the first YAML frontmatter block from *text*.

    Looks for a ``---``-delimited block at the start of the content (after
    stripping leading whitespace).  Returns ``(frontmatter_dict, body_text)``.

    If no frontmatter is found, returns ``({}, text)``.
    """
    stripped = text.lstrip("\ufeff")
    if not stripped.startswith("---"):
        return {}, stripped

    end_idx = stripped.find("---", 3)
    if end_idx == -1:
        return {}, stripped

    yaml_block = stripped[3:end_idx]
    body = stripped[end_idx + 3:].lstrip()

    try:
        import yaml as _yaml
        meta = _yaml.safe_load(yaml_block) or {}
    except ImportError:
        log.warning("pyyaml is not installed; cannot parse frontmatter")
        meta = {}
    except Exception as exc:
        log.debug("Cannot parse YAML frontmatter: %s", exc)
        meta = {}

    if not isinstance(meta, dict):
        meta = {}

    return meta, body


def _read_all_frontmatter_blocks(text):
    """Extract ALL consecutive YAML frontmatter blocks from *text*.

    Returns ``(list_of_dicts, final_body)`` where *final_body* is everything
    after the last closing ``---``.
    """
    blocks = []
    remaining = text.lstrip("\ufeff")

    while remaining.startswith("---"):
        end_idx = remaining.find("---", 3)
        if end_idx == -1:
            break

        yaml_block = remaining[3:end_idx]
        body_after = remaining[end_idx + 3:].lstrip()

        try:
            import yaml as _yaml
            meta = _yaml.safe_load(yaml_block) or {}
        except ImportError:
            log.warning("pyyaml is not installed; cannot parse frontmatter")
            meta = {}
        except Exception:
            meta = {}

        if isinstance(meta, dict):
            blocks.append(meta)
        else:
            blocks.append({})

        remaining = body_after

    return blocks, remaining


# ---------------------------------------------------------------------------
# Vault reading
# ---------------------------------------------------------------------------

def read_vault_notes(vault_dir):
    """Walk *vault_dir* and return a list of note dicts.

    Each dict has keys:
        ``file``        -- basename
        ``filepath``    -- full path
        ``frontmatter`` -- first (knowledge-base) frontmatter block
        ``extractions`` -- subsequent (extraction-metadata) blocks
        ``body``        -- everything after the first frontmatter block
        ``raw_text``    -- complete file content
    """
    notes = []

    if not os.path.isdir(vault_dir):
        log.warning("Vault directory not found: %s", vault_dir)
        return notes

    for filename in sorted(os.listdir(vault_dir)):
        if not filename.endswith(".md"):
            continue
        filepath = os.path.join(vault_dir, filename)
        if not os.path.isfile(filepath):
            continue

        try:
            with open(filepath, "r", encoding="utf-8") as fh:
                raw_text = fh.read()
        except (OSError, UnicodeDecodeError) as exc:
            log.warning("Cannot read %s: %s", filepath, exc)
            continue

        blocks, final_body = _read_all_frontmatter_blocks(raw_text)
        first_fm = blocks[0] if blocks else {}
        extractions = blocks[1:] if len(blocks) > 1 else []

        notes.append({
            "file": filename,
            "filepath": filepath,
            "frontmatter": first_fm,
            "extractions": extractions,
            "body": final_body,
            "raw_text": raw_text,
        })

    return notes


# ---------------------------------------------------------------------------
# Content file discovery (for extracted/ and transcripts/ directories)
# ---------------------------------------------------------------------------

def _read_source_path_from_file(md_path):
    """Read the ``source_path`` from the first YAML frontmatter block."""
    try:
        with open(md_path, "r", encoding="utf-8") as fh:
            content = fh.read()
    except Exception:
        return None

    meta, _body = _read_yaml_frontmatter(content)
    sp = meta.get("source_path")
    return os.path.normpath(str(sp)) if sp else None


def build_content_map(output_dir):
    """Scan ``<output_dir>/extracted/`` and ``<output_dir>/transcripts/`` and
    return ``{normalized_source_path: absolute_md_path}``.

    Mirrors the pattern used in ``10_extract_entities.py``.
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
            source_path = _read_source_path_from_file(md_path)
            if source_path:
                content_map[source_path] = md_path

    log.info("Found %d content files (extracted + transcripts)", len(content_map))
    return content_map


# ---------------------------------------------------------------------------
# Text extraction helpers
# ---------------------------------------------------------------------------

def strip_frontmatter(markdown_text):
    """Remove the first YAML frontmatter block and return body text.

    Only strips the opening ``---`` ... ``---`` block at the start of file.
    """
    _meta, body = _read_yaml_frontmatter(markdown_text)
    return body


def read_body_text(md_path, max_chars):
    """Read *md_path*, strip frontmatter, and return up to *max_chars* chars.

    Mirrors the pattern in ``10_extract_entities.py``.
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
# Document building
# ---------------------------------------------------------------------------

def _extract_body_metadata(body):
    """Extract ``category``, ``theme``, ``summary`` from vault note body bullets.

    Lines like ``- Category: text``  are parsed.  Missing keys default to "".
    """
    result = {"category": "", "theme": "", "summary": ""}
    for line in body.splitlines():
        match = re.match(r'^\s*-\s+(Category|Theme|Summary):\s*(.+)', line)
        if match:
            key = match.group(1).lower()
            result[key] = match.group(2).strip()
    return result


def _extract_extracted_text(body):
    """Return the actual extracted/transcribed text from a vault note body.

    The vault body often contains:
      1. A heading and summary table
      2. An embedded frontmatter block (extraction metadata)
      3. The extracted content

    We return everything after the last frontmatter block, falling back to the
    body with summary lines stripped.
    """
    blocks, final_text = _read_all_frontmatter_blocks(body)
    if blocks:
        return final_text.strip()

    # No embedded frontmatter: skip the heading and summary section
    lines = body.splitlines()
    content_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("# "):
            continue
        if stripped.startswith("- Source:") or stripped.startswith("- Category:"):
            continue
        if stripped.startswith("- Theme:") or stripped.startswith("- Summary:"):
            continue
        if not stripped and not content_lines:
            continue
        content_lines.append(line)
    return "\n".join(content_lines).strip()


def build_document(note, max_chars):
    """Build a combined document string from a vault note for embedding.

    Combines ``summary``, ``tags``, ``category``, ``theme``, and body text.
    """
    fm = note["frontmatter"]
    body_meta = _extract_body_metadata(note["body"])
    extracted_text = _extract_extracted_text(note["body"])

    summary = body_meta["summary"] or fm.get("summary", "")
    tags = fm.get("tags", "")
    category = body_meta["category"] or fm.get("category", "")
    theme = body_meta["theme"]
    truncated_body = extracted_text[:max_chars]

    parts = []
    if summary:
        parts.append("summary: %s" % summary)
    if tags:
        parts.append("tags: %s" % tags)
    if category:
        parts.append("category: %s" % category)
    if theme:
        parts.append("theme: %s" % theme)
    if truncated_body:
        parts.append("body: %s" % truncated_body)
    return "\n\n".join(parts)


def build_document_from_content(source_path, body_text, classification, max_chars):
    """Build a combined document from a content file (extracted or transcript).

    *classification* is a dict from ``load_classification_data``, possibly empty.
    """
    summary = classification.get("summary", "")
    tags = classification.get("tags", "")
    category = classification.get("category", "")
    truncated_body = body_text[:max_chars]

    parts = []
    if summary:
        parts.append("summary: %s" % summary)
    if tags:
        parts.append("tags: %s" % tags)
    if category:
        parts.append("category: %s" % category)
    if truncated_body:
        parts.append("body: %s" % truncated_body)
    return "\n\n".join(parts)


# ---------------------------------------------------------------------------
# Classification CSV
# ---------------------------------------------------------------------------

def load_classification_data(csv_path):
    """Load *classification.csv* and return ``{source_path: row_dict}``.

    Returns an empty dict if the file is missing or unreadable.
    """
    data = {}
    if not csv_path or not os.path.isfile(csv_path):
        return data

    try:
        with open(csv_path, "r", encoding="utf-8-sig") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                path = row.get("path", "")
                if path:
                    data[path] = {
                        "category": row.get("category", ""),
                        "tags": row.get("tags", ""),
                        "theme": row.get("theme", ""),
                        "summary": row.get("summary", ""),
                        "confidence": row.get("confidence", ""),
                    }
    except (OSError, csv.Error) as exc:
        log.warning("Cannot read classification CSV %s: %s", csv_path, exc)

    log.info("Loaded %d classification records from %s", len(data), csv_path)
    return data


# ---------------------------------------------------------------------------
# ChromaDB helpers
# ---------------------------------------------------------------------------

def _load_chromadb():
    """Lazy import of chromadb with a helpful error message."""
    try:
        import chromadb as _cdb
        return _cdb
    except ImportError:
        log.error(
            "chromadb is not installed. "
            "Install it with: pip install -r scripts/python/requirements-search.txt"
        )
        sys.exit(1)


def _load_sentence_transformer():
    """Lazy import of sentence_transformers with a helpful error message."""
    try:
        from sentence_transformers import SentenceTransformer as _ST
        return _ST
    except ImportError:
        log.error(
            "sentence-transformers is not installed. "
            "Install it with: pip install -r scripts/python/requirements-search.txt"
        )
        sys.exit(1)


def _collection_name(model_name):
    """Normalize an arbitrary model name into a valid ChromaDB collection name."""
    return re.sub(r"[^a-zA-Z0-9_]", "_", model_name)


def get_chroma_collection(persist_dir, model_name):
    """Create a fresh ChromaDB collection for indexing.  Drops any existing
    collection with the same name.

    Returns ``(collection, client)``.
    """
    chromadb = _load_chromadb()
    name = _collection_name(model_name)
    client = chromadb.PersistentClient(path=persist_dir)

    try:
        client.delete_collection(name)
    except ValueError:
        pass

    collection = client.create_collection(
        name=name,
        metadata={"hnsw:space": "cosine"},
    )
    return collection, client


def get_existing_collection(persist_dir, model_name):
    """Retrieve an existing ChromaDB collection for querying.

    Returns ``(collection, client)`` or exits with an error message.
    """
    chromadb = _load_chromadb()
    name = _collection_name(model_name)
    client = chromadb.PersistentClient(path=persist_dir)

    try:
        collection = client.get_collection(name=name)
    except ValueError:
        log.error(
            "Collection '%s' not found in %s. Run index mode first.",
            name,
            persist_dir,
        )
        sys.exit(1)

    return collection, client


# ---------------------------------------------------------------------------
# Index mode
# ---------------------------------------------------------------------------

def index_mode(args):
    """Build ChromaDB index from vault notes, extracted files, and transcripts."""
    SentenceTransformer = _load_sentence_transformer()

    # 1. Load embedding model
    log.info("Loading embedding model: %s", args.model)
    model = SentenceTransformer(args.model)
    log.info("Model dimension: %d", model.get_sentence_embedding_dimension())

    # 2. Load classification data for enrichment
    classification_data = load_classification_data(args.classification_csv)

    # 3. Read vault notes
    log.info("Reading vault notes from: %s", args.vault_dir)
    notes = read_vault_notes(args.vault_dir)
    log.info("Found %d vault note(s)", len(notes))

    if not notes:
        log.error("No vault notes found; nothing to index.")
        sys.exit(1)

    # 4. Build documents, metadata, IDs from vault notes
    documents = []
    metadatas = []
    ids = []

    for idx, note in enumerate(notes):
        doc = build_document(note, args.max_chars)
        fm = note["frontmatter"]
        body_meta = _extract_body_metadata(note["body"])

        source_path = fm.get("source_path", "")
        cls = classification_data.get(source_path, {})

        summary = body_meta["summary"] or fm.get("summary", "") or cls.get("summary", "")
        tags = fm.get("tags", "") or cls.get("tags", "")
        category = body_meta["category"] or fm.get("category", "") or cls.get("category", "")
        theme = body_meta["theme"] or cls.get("theme", "")

        metadata = {
            "source_path": source_path,
            "category": category,
            "tags": tags,
            "summary": summary,
            "theme": theme,
        }

        vibe = fm.get("vibe", "")
        if vibe:
            metadata["vibe"] = vibe
        if cls.get("confidence"):
            metadata["confidence"] = cls["confidence"]

        documents.append(doc)
        metadatas.append(metadata)
        ids.append("note_%05d" % idx)

    # 5. Supplement with extracted/ and transcripts/ files if --output-dir given
    indexed_sources = {m.get("source_path") for m in metadatas}

    if args.output_dir and os.path.isdir(args.output_dir):
        content_map = build_content_map(args.output_dir)
        for source_path, md_path in sorted(content_map.items()):
            if source_path in indexed_sources:
                continue  # already indexed via vault note

            body = read_body_text(md_path, args.max_chars)
            if not body.strip():
                continue

            cls = classification_data.get(source_path, {})
            doc = build_document_from_content(source_path, body, cls, args.max_chars)

            metadata = {
                "source_path": source_path,
                "category": cls.get("category", ""),
                "tags": cls.get("tags", ""),
                "summary": cls.get("summary", ""),
                "theme": cls.get("theme", ""),
            }
            if cls.get("confidence"):
                metadata["confidence"] = cls["confidence"]

            documents.append(doc)
            metadatas.append(metadata)
            ids.append("content_%05d" % (len(documents) - 1))

    if not documents:
        log.error("No documents to index.")
        sys.exit(1)

    log.info("Generating embeddings for %d document(s)...", len(documents))
    embeddings = model.encode(documents, show_progress_bar=True)

    # 6. Store in ChromaDB
    log.info("Storing in ChromaDB: %s", args.persist_dir)
    collection, _client = get_chroma_collection(args.persist_dir, args.model)

    # Batch upsert to keep memory reasonable
    batch_size = 32
    for i in range(0, len(documents), batch_size):
        end = min(i + batch_size, len(documents))
        collection.add(
            ids=ids[i:end],
            documents=documents[i:end],
            embeddings=embeddings[i:end].tolist(),
            metadatas=metadatas[i:end],
        )

    log.info(
        "Indexing complete. Collection '%s' contains %d document(s).",
        collection.name,
        collection.count(),
    )


# ---------------------------------------------------------------------------
# Query mode
# ---------------------------------------------------------------------------

def query_mode(args):
    """Search the ChromaDB index with a natural-language query."""
    SentenceTransformer = _load_sentence_transformer()

    log.info("Loading embedding model: %s", args.model)
    model = SentenceTransformer(args.model)

    collection, _client = get_existing_collection(args.persist_dir, args.model)
    log.info(
        "Collection '%s' contains %d document(s)",
        collection.name,
        collection.count(),
    )

    log.info("Query: %s", args.query)
    query_embedding = model.encode(args.query).tolist()

    n_results = min(args.top_k, collection.count()) or 1
    results = collection.query(
        query_embeddings=[query_embedding],
        n_results=n_results,
        include=["documents", "metadatas", "distances"],
    )

    if not results["ids"] or not results["ids"][0]:
        log.info("No results found.")
        _write_search_results_csv([], args.persist_dir)
        return

    print()  # blank line before results
    output_rows = []

    for rank, (doc_id, metadata, distance, doc_text) in enumerate(
        zip(
            results["ids"][0],
            results["metadatas"][0],
            results["distances"][0],
            results["documents"][0],
        ),
        start=1,
    ):
        similarity = 1.0 - distance
        source_path = metadata.get("source_path", "")
        category = metadata.get("category", "")
        tags = metadata.get("tags", "")
        vibe = metadata.get("vibe", "")
        summary = metadata.get("summary", "")

        print("  [%d] Similarity: %.4f" % (rank, similarity))
        print("       Source:   %s" % (source_path or doc_id))
        print("       Category: %s" % category)
        print("       Tags:     %s" % tags)
        if vibe:
            print("       Vibe:     %s" % vibe)
        print("       Summary:  %s" % (summary[:120] if summary else "(none)"))
        print()

        body_preview = doc_text[:200].replace("\n", " ") if doc_text else ""
        output_rows.append({
            "rank": str(rank),
            "source_path": source_path,
            "category": category,
            "tags": tags,
            "vibe": vibe,
            "summary": summary,
            "similarity": "%.4f" % similarity,
            "body_preview": body_preview,
        })

    _write_search_results_csv(output_rows, args.persist_dir)


def _write_search_results_csv(rows, persist_dir):
    """Write search results to ``outputs/search/search-results.csv``.

    Creates the output directory if needed.
    """
    search_dir = os.path.join(os.path.dirname(persist_dir), "search")
    os.makedirs(search_dir, exist_ok=True)
    output_path = os.path.join(search_dir, SEARCH_OUTPUT_FILE)

    fieldnames = [
        "rank",
        "source_path",
        "category",
        "tags",
        "vibe",
        "summary",
        "similarity",
        "body_preview",
    ]

    try:
        with open(output_path, "w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
        log.info("Wrote %d result(s) to %s", len(rows), output_path)
    except OSError as exc:
        log.warning("Cannot write search results CSV: %s", exc)


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def main():
    """Dispatch to index_mode or query_mode based on ``--mode``."""
    args = parse_args()
    _validate_args(args)

    if args.mode == "index":
        index_mode(args)
    else:
        query_mode(args)


if __name__ == "__main__":
    main()
