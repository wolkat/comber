# Performance Benchmarks and Scaling Guidance

This document provides performance benchmarks, scaling recommendations, and optimization strategies for Comber.

## Performance Overview

Comber is designed for local archives ranging from thousands to millions of files. Performance depends on:

- **Storage type:** SSD vs HDD vs network storage
- **File count:** Number of files to process
- **File size:** Average and maximum file sizes
- **External tools:** Availability and performance of optional tools
- **Hardware:** CPU, memory, and I/O capabilities

## Benchmarks

### Baseline Performance

Tested on: macOS 15.7.5, Apple M1, 16GB RAM, SSD storage

| Stage | 1,000 Files | 10,000 Files | 100,000 Files |
|-------|-------------|--------------|---------------|
| 01-Inventory | 2s | 15s | 2.5min |
| 02-Metadata | 5s | 45s | 7min |
| 03-Dedupe | 1s | 8s | 1.5min |
| 04-ExtractText | 10s | 1.5min | 15min |
| 05-TranscribeMedia | 0s (disabled) | 0s (disabled) | 0s (disabled) |
| 06-ClassifyThemes | 0s (disabled) | 0s (disabled) | 0s (disabled) |
| 07-BuildKnowledgeBase | 3s | 25s | 4min |
| 08-ReviewReports | 1s | 5s | 45s |
| **Total (basic)** | **~22s** | **~3min** | **~30min** |

### Stage-Specific Performance

#### Stage 01: Inventory

**Bottleneck:** File hashing (SHA256)

| Operation | Time per File | Notes |
|-----------|---------------|-------|
| File enumeration | 0.01ms | Directory traversal |
| Hash calculation (small < 1MB) | 0.5ms | Fast |
| Hash calculation (medium 1-100MB) | 5ms | I/O bound |
| Hash calculation (large > 100MB) | 50ms+ | Consider skipping |
| CSV writing | 0.1ms | Batched |

**Optimization:**
- Use `hashMaxBytes` to skip large files
- Increase `progressEvery` to reduce console output
- Use SSD storage for faster I/O

#### Stage 02: Metadata

**Bottleneck:** ExifTool execution

| Operation | Time per File | Notes |
|-----------|---------------|-------|
| ExifTool call | 10-50ms | Process overhead |
| FFprobe call | 20-100ms | For video/audio |
| CSV writing | 0.1ms | Batched |

**Optimization:**
- Disable ExifTool for large archives: `metadata.enableExifTool: false`
- Process only specific file types
- Use parallel processing (future enhancement)

#### Stage 03: Dedupe

**Bottleneck:** Hash comparison

| Operation | Time per File | Notes |
|-----------|---------------|-------|
| Hash lookup | 0.01ms | In-memory |
| Group formation | 0.1ms | Per duplicate group |
| Czkawka fuzzy | 1-10ms | If enabled |

**Optimization:**
- Stage 03 reuses hashes from Stage 01
- Czkawka is optional for fuzzy matching

#### Stage 04: Text Extraction

**Bottleneck:** External tool execution

| Operation | Time per File | Notes |
|-----------|---------------|-------|
| Plain text (.txt, .md) | 0.1ms | Direct read |
| PDF extraction | 10-100ms | Depends on size |
| OCR (Tesseract) | 100ms-10s | Depends on image |
| Document conversion | 50-500ms | MarkItDown/Docling |

**Optimization:**
- Disable external converters for large archives
- Process only text-based files
- Use `-DryRun` to estimate time

## Scaling Recommendations

### Small Archives (< 10,000 files)

**Configuration:**
```json
{
  "inventory": {
    "hashAlgorithm": "SHA256",
    "hashMaxBytes": 0,
    "progressEvery": 100
  },
  "metadata": {
    "enableExifTool": true
  },
  "extraction": {
    "enableExternalConverters": true
  }
}
```

**Expected time:** 1-5 minutes

### Medium Archives (10,000 - 100,000 files)

**Configuration:**
```json
{
  "inventory": {
    "hashAlgorithm": "SHA256",
    "hashMaxBytes": 104857600,
    "progressEvery": 500
  },
  "metadata": {
    "enableExifTool": true
  },
  "extraction": {
    "enableExternalConverters": false
  }
}
```

**Expected time:** 10-30 minutes

**Recommendations:**
- Skip files > 100MB for hashing
- Disable external converters
- Run during off-hours

### Large Archives (> 100,000 files)

**Configuration:**
```json
{
  "inventory": {
    "hashAlgorithm": "SHA256",
    "hashMaxBytes": 52428800,
    "progressEvery": 1000
  },
  "metadata": {
    "enableExifTool": false
  },
  "extraction": {
    "enableExternalConverters": false
  }
}
```

**Expected time:** 1-3 hours

**Recommendations:**
- Skip files > 50MB for hashing
- Disable ExifTool
- Run overnight
- Consider splitting by directory

## Optimization Strategies

### 1. Skip Large Files

Large files slow down hashing significantly:

```json
{
  "inventory": {
    "hashMaxBytes": 104857600
  }
}
```

Files larger than `hashMaxBytes` will have `hash_status: skipped_size_limit`.

### 2. Disable External Tools

External tools add overhead:

```json
{
  "metadata": {
    "enableExifTool": false
  },
  "extraction": {
    "enableExternalConverters": false
  },
  "transcription": {
    "enabled": false
  },
  "classification": {
    "enabled": false
  }
}
```

### 3. Use Dry Run

Estimate time without processing:

```powershell
pwsh ./scripts/01-Inventory.ps1 -ConfigPath ./config/pipeline.json -DryRun
```

### 4. Split by Directory

For very large archives, process subdirectories separately:

```powershell
# Process photos
pwsh ./scripts/01-Inventory.ps1 -RootPath /archive/photos -OutputPath ./outputs-photos

# Process documents
pwsh ./scripts/01-Inventory.ps1 -RootPath /archive/documents -OutputPath ./outputs-docs
```

### 5. Resume Failed Runs

Use `-Resume` to continue from last successful point:

```powershell
pwsh ./scripts/01-Inventory.ps1 -ConfigPath ./config/pipeline.json -Resume
```

## Resource Usage

### Memory

| Stage | Memory Usage | Notes |
|-------|--------------|-------|
| 01-Inventory | Low | Streams file list |
| 02-Metadata | Low | Processes one file at a time |
| 03-Dedupe | Medium | Stores all hashes in memory |
| 04-ExtractText | Low-Medium | Depends on file size |
| 07-BuildKnowledgeBase | Medium | Loads all CSVs |

**Recommendation:** 4GB RAM minimum for large archives.

### Disk I/O

| Operation | I/O Pattern | Notes |
|-----------|-------------|-------|
| File enumeration | Sequential | Fast on SSD |
| Hash calculation | Sequential read | I/O bound |
| CSV writing | Sequential write | Batched |
| Log writing | Sequential append | Minimal |

**Recommendation:** SSD storage for best performance.

### CPU

| Operation | CPU Usage | Notes |
|-----------|-----------|-------|
| Hash calculation | Single core | CPU bound |
| ExifTool | Single core | Process overhead |
| OCR | Multi-core | Tesseract uses multiple cores |
| Classification | Single core | LLM inference |

**Recommendation:** Multi-core CPU for OCR and classification.

## Monitoring Performance

### Enable Verbose Logging

```powershell
pwsh ./scripts/01-Inventory.ps1 -ConfigPath ./config/pipeline.json -VerboseLog
```

Output includes:
- File count progress
- Processing time per file
- Error details

### Check Log Files

Logs are in `outputs/logs/`:

```powershell
Get-Content ./outputs/logs/01-Inventory-*.log -Tail 50
```

### Measure Stage Time

```powershell
$start = Get-Date
pwsh ./scripts/01-Inventory.ps1 -ConfigPath ./config/pipeline.json
$end = Get-Date
$duration = $end - $start
Write-Host "Duration: $($duration.TotalSeconds) seconds"
```

## Troubleshooting Performance

### Slow Inventory Stage

**Symptoms:** Stage 01 takes > 10 minutes

**Causes:**
- Large files being hashed
- Network storage
- Slow disk

**Solutions:**
- Increase `hashMaxBytes`
- Use local storage
- Use SSD

### Slow Metadata Stage

**Symptoms:** Stage 02 takes > 30 minutes

**Causes:**
- ExifTool overhead
- Many files

**Solutions:**
- Disable ExifTool: `metadata.enableExifTool: false`
- Process specific file types only

### Slow Text Extraction

**Symptoms:** Stage 04 takes > 1 hour

**Causes:**
- OCR processing
- Document conversion

**Solutions:**
- Disable external converters
- Process only text files
- Use faster hardware

### Memory Issues

**Symptoms:** Out of memory errors

**Causes:**
- Too many files in memory
- Large CSV files

**Solutions:**
- Split by directory
- Increase system memory
- Process in batches

## Future Optimizations

### Planned Improvements

1. **Parallel processing:** Process multiple files concurrently
2. **Streaming CSV:** Reduce memory usage for large archives
3. **Incremental hashing:** Only hash changed files
4. **Database backend:** SQLite for large archives
5. **Cloud storage:** Support for S3, Azure Blob, etc.

### Contributing Performance Improvements

If you identify performance bottlenecks:

1. **Profile the code** using PowerShell profiling tools
2. **Document the bottleneck** with measurements
3. **Propose a solution** in a GitHub issue
4. **Submit a PR** with benchmarks

## References

- [PowerShell Performance](https://docs.microsoft.com/en-us/powershell/scripting/dev-cross-plat/performance/script-authoring-considerations)
- [ExifTool Performance](https://exiftool.org/forum/index.php?topic=3652.0)
- [Tesseract Performance](https://github.com/tesseract-ocr/tesseract/wiki/FAQ)
