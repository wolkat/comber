# Release Strategy

This document outlines Comber's versioning, release process, and backward compatibility policies.

## Versioning Scheme

Comber follows [Semantic Versioning](https://semver.org/) (SemVer):

```
MAJOR.MINOR.PATCH
```

### Version Increments

| Type | When to Increment | Examples |
|------|-------------------|----------|
| **MAJOR** | Breaking changes to config format, CSV schema, or CLI interface | Changing inventory CSV columns, removing config options, changing exit codes |
| **MINOR** | New features, new pipeline stages, non-breaking enhancements | Adding stage 10, new config options, new output formats |
| **PATCH** | Bug fixes, documentation updates, performance improvements | Fixing hash calculation, updating README, optimizing file scanning |

### Pre-release Versions

For pre-release testing:

```
1.0.0-alpha.1    # Alpha release
1.0.0-beta.1     # Beta release
1.0.0-rc.1       # Release candidate
```

## Release Process

### 1. Prepare the Release

1. **Update version references** in:
   - `CHANGELOG.md`
   - `README.md` (if version is mentioned)
   - Any documentation referencing specific versions

2. **Update CHANGELOG.md:**
   ```markdown
   ## [1.2.0] - 2026-06-01

   ### Added
   - New fuzzy deduplication stage
   - Support for WebP images

   ### Changed
   - Improved inventory scanning performance

   ### Fixed
   - Handle paths with special characters
   ```

3. **Run full test suite:**
   ```powershell
   make lint
   make test
   ```

### 2. Create the Release

1. **Create a git tag:**
   ```powershell
   git tag -a v1.2.0 -m "Release v1.2.0"
   ```

2. **Push the tag:**
   ```powershell
   git push origin v1.2.0
   ```

3. **Create GitHub release:**
   - Go to GitHub Releases
   - Create new release from tag
   - Copy release notes from CHANGELOG.md
   - Attach any release artifacts (if applicable)

### 3. Post-release

1. **Update CHANGELOG.md** with `[Unreleased]` section
2. **Announce release** in relevant channels
3. **Update documentation** if needed

## Backward Compatibility

### Config Format

- **Additive changes** (new optional fields) are backward compatible
- **Removal or renaming** of fields requires major version bump
- **Default values** must be provided for new fields

Example of backward compatible change:
```json
{
  "inventory": {
    "hashAlgorithm": "SHA256",
    "hashMaxBytes": 0,
    "progressEvery": 250,
    "newOption": "default_value"  // New field with default
  }
}
```

### CSV Schema

- **Adding columns** is backward compatible (consumers should ignore unknown columns)
- **Removing or renaming columns** requires major version bump
- **Changing column semantics** requires major version bump

### Exit Codes

Exit codes are part of the public API:

| Code | Meaning | Stability |
|------|---------|-----------|
| `0` | Success | Stable |
| `1` | Fatal error | Stable |
| `3` | Partial success | Stable |

- **Adding new exit codes** is backward compatible
- **Changing existing exit codes** requires major version bump

### CLI Interface

- **Adding new parameters** is backward compatible
- **Removing parameters** requires major version bump
- **Changing parameter behavior** requires major version bump

## Migration Guides

### Major Version Upgrades

When upgrading between major versions:

1. **Read the CHANGELOG** for breaking changes
2. **Update config files** to match new format
3. **Update scripts** that depend on CSV schema
4. **Test thoroughly** before production use

### Config Migration

Example migration from v1.x to v2.x:

```powershell
# Old config (v1.x)
{
  "hashAlgorithm": "SHA256"
}

# New config (v2.x)
{
  "inventory": {
    "hashAlgorithm": "SHA256",
    "hashMaxBytes": 0
  }
}
```

## Long-term Support (LTS)

### Current Policy

- **Latest major version** receives all updates
- **Previous major version** receives critical bug fixes for 6 months
- **Older versions** are unsupported

### LTS Releases

When a new major version is released:

1. **Previous version** enters LTS for 6 months
2. **Critical bugs** are backported to LTS
3. **Security fixes** are backported to LTS
4. **New features** are only in latest version

## Release Checklist

### Pre-release

- [ ] All tests pass (`make test`)
- [ ] Static checks pass (`make lint`)
- [ ] CHANGELOG.md updated
- [ ] Version references updated
- [ ] Documentation reviewed

### Release

- [ ] Git tag created
- [ ] GitHub release created
- [ ] Release notes written

### Post-release

- [ ] CHANGELOG.md updated with `[Unreleased]` section
- [ ] Documentation updated (if needed)
- [ ] Release announced

## Hotfix Process

For critical bugs in production:

1. **Create hotfix branch** from release tag:
   ```powershell
   git checkout -b hotfix/critical-fix v1.2.0
   ```

2. **Fix the bug** with minimal changes

3. **Test thoroughly:**
   ```powershell
   make lint
   make test
   ```

4. **Create patch release:**
   ```powershell
   git tag -a v1.2.1 -m "Hotfix: critical bug fix"
   git push origin v1.2.1
   ```

5. **Merge back** to main branch

## Deprecation Policy

### Deprecation Process

1. **Announce deprecation** in release notes
2. **Add warning** in current version
3. **Remove** in next major version

### Deprecation Timeline

- **v1.0:** Feature announced as deprecated
- **v1.1:** Deprecation warning added
- **v2.0:** Feature removed

Example:
```powershell
# v1.0 - Deprecated
Write-Warning "Function Get-OldData is deprecated. Use Get-NewData instead."

# v2.0 - Removed
# Function no longer exists
```

## Version History

| Version | Release Date | Key Changes |
|---------|--------------|-------------|
| 0.1.0 | 2026-05-31 | Initial release |
| 1.0.0 | TBD | First stable release |

## References

- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
