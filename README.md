# Enhanced Package Management System

Complete package management system for Arch Linux combining custom multi-source feeds with aurutils dependency resolution and paru convenience.

## Quick Start

```bash
# 1. Install dependencies
paru -S aurutils devtools

# 2. Initialize system
./scripts/repo-mgmt.sh init
# Follow instructions to add repo to /etc/pacman.conf

# 3. Run first sync
./scripts/sync-all.sh --review

# 4. Daily updates
./scripts/sync-all.sh
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  feeds.json - Multi-source package definitions             │
│  - Chrome/Edge update channels                              │
│  - GitHub releases with regex patterns                      │
│  - VCS packages (-git, -hg, -svn)                          │
│  - Manual AUR packages                                      │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│  sync-all.sh - Master orchestration                         │
│  1. Check Arch news                                         │
│  2. Detect updates                                          │
│  3. Review PKGBUILDs (optional)                            │
│  4. Resolve AUR dependencies (aurutils)                     │
│  5. Build packages                                          │
│  6. Update local repository                                 │
│  7. Install via pacman                                      │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│  Local Repository (/var/cache/pacman/custom)               │
│  - All packages managed by pacman                           │
│  - Standard pacman -Syu workflow                            │
│  - Version tracking and rollback                            │
└─────────────────────────────────────────────────────────────┘
```

## What This System Does

### Core Capabilities

**Multi-Source Package Management** (Unique to this system)
- Chrome/Edge from RPM repos
- VS Code, 1Password CLI, LM Studio
- GitHub releases with custom version patterns
- All AUR packages

**Automatic Dependency Resolution** (via aurutils)
- Complete AUR dependency graphs
- Topologically sorted build order
- Automatic import of missing dependencies

**PKGBUILD Review Workflow**
- Diff tracking since last review
- Commit-based review state
- AUR comments integration
- Syntax highlighted viewing (via bat)

**Reproducible Builds** (via devtools)
- Clean chroot builds
- Isolated build environment
- Verified dependency closure

**Local Repository Integration**
- First-class pacman integration
- Standard -Syu upgrades
- Version history
- Rollback capability

## File Structure

```
~/Projects/Packages/
├── config.sh                      # Central configuration
├── feeds.json                     # Package definitions
│
├── scripts/
│   ├── Core Workflow
│   ├── sync-all.sh               # Master orchestration (daily driver)
│   ├── update-pkg.sh             # Package update logic (enhanced)
│   ├── install-updates.sh        # Installation logic (enhanced)
│   │
│   ├── Dependency Management
│   ├── resolve-deps.sh           # Dependency resolution wrapper
│   ├── aur-imports.sh            # AUR package import (enhanced)
│   │
│   ├── Repository Operations
│   ├── repo-mgmt.sh              # Repository management
│   ├── cleanup-repo.sh           # Cleanup and maintenance
│   │
│   ├── Quality Assurance
│   ├── review-pkgbuild.sh        # PKGBUILD review workflow
│   ├── build-chroot.sh           # Clean chroot builds
│   ├── check-news.sh             # Arch Linux news
│   └── compare-versions.sh       # Version detection audit
│
├── Package Directories
├── google-chrome-canary-bin/
├── ktailctl/
├── ollama/
└── ...
```

```
~/.cache/pkg-mgmt/
├── staging/                          # Built packages ready to install
│   ├── ktailctl-0.21.5-1.pkg.tar.zst
│   ├── ollama-0.14.3-1.pkg.tar.zst
│   └── chrome-146.0.7650.0-1.pkg.tar.zst
├── logs/
│   └── builds/                       # Per-package build logs
│       ├── ktailctl-20250123-143022.log
│       ├── ollama-20250123-143156.log
│       └── chrome-20250123-143245.log
├── chroot/                           # Clean build environment (optional)
└── failed-builds.txt                 # Track failures for retry

~/.local/share/pkg-mgmt/
└── reviewed/                         # PKGBUILD review state
    ├── ktailctl
    └── ollama

/var/cache/pacman/custom/             # Local repository (optional)
├── custom.db.tar.gz
├── ktailctl-0.21.5-1.pkg.tar.zst
└── ollama-0.14.3-1.pkg.tar.zst
```

## Scripts Overview

### Daily Workflow

**sync-all.sh** - Your daily driver
```bash
./sync-all.sh                 # Full auto update
./sync-all.sh --review        # With PKGBUILD review
./sync-all.sh --chroot        # Reproducible builds
./sync-all.sh ktailctl        # Update specific package
```

### Package Operations

**update-pkg.sh** - Update individual packages
```bash
# Enhanced with new features:
./update-pkg.sh --dry-run                    # Check for updates
./update-pkg.sh --resolve-deps ktailctl      # Auto-import deps
./update-pkg.sh --review google-chrome       # Review before build
./update-pkg.sh --chroot --repo /path ollama # Clean build to repo
```

**aur-imports.sh** - Import packages from AUR
```bash
# Enhanced with dependency support:
./aur-imports.sh ktailctl --infer           # Import with inference
./aur-imports.sh --with-deps ollama         # Import + dependencies
./aur-imports.sh --from-file packages.txt   # Batch import
```

### Dependency Management

**resolve-deps.sh** - Resolve AUR dependencies
```bash
./resolve-deps.sh ktailctl                  # Show dependencies
./resolve-deps.sh --import ktailctl         # Import dependencies
./resolve-deps.sh --build-order --json      # JSON output
```

### Repository Management

**repo-mgmt.sh** - Manage local repository
```bash
./repo-mgmt.sh init                         # Initialize repo
./repo-mgmt.sh add *.pkg.tar.zst           # Add packages
./repo-mgmt.sh list --upgrades             # Show updates
./repo-mgmt.sh status                      # Repository stats
```

**cleanup-repo.sh** - Repository maintenance
```bash
./cleanup-repo.sh --auto --keep-n 2        # Keep 2 versions
./cleanup-repo.sh --orphans-only           # Remove orphans
```

### Quality Assurance

**review-pkgbuild.sh** - Review workflow
```bash
./review-pkgbuild.sh ktailctl              # Review package
./review-pkgbuild.sh --comments ollama     # Include AUR comments
./review-pkgbuild.sh --force               # Force re-review
```

**build-chroot.sh** - Clean builds
```bash
./build-chroot.sh ktailctl                 # Build in chroot
./build-chroot.sh --update --clean         # Fresh chroot
```

**check-news.sh** - Arch news
```bash
./check-news.sh                            # Unread news
./check-news.sh --all                      # All recent news
./check-news.sh --since 2025-01-01         # Since date
```

**compare-versions.sh** - Version audit
```bash
./compare-versions.sh                      # Compare all sources
./compare-versions.sh --package ktailctl   # Specific package
```

## Configuration

Edit `config.sh` to customize:

```bash
# Repository
REPO_NAME="custom"
REPO_DIR="/var/cache/pacman/custom"

# Build behavior
ENABLE_CHROOT=false              # Clean builds by default?
ENABLE_REVIEW=true               # Review by default?
AUTO_RESOLVE_DEPS=true           # Auto-import AUR deps?

# Review settings
REVIEW_EDITOR="${EDITOR:-vim}"
USE_BAT="auto"                   # Syntax highlighting

# Paths
CHROOT_DIR="$HOME/.cache/pkg-mgmt/chroot"
LOG_DIR="$HOME/.cache/pkg-mgmt/logs"
```

## Common Workflows

### First-Time Setup

```bash
# 1. Install system
paru -S aurutils devtools

# 2. Initialize repository
./scripts/repo-mgmt.sh init

# 3. Add to /etc/pacman.conf
sudo tee -a /etc/pacman.conf << 'EOF'
[custom]
SigLevel = Optional TrustAll
Server = file:///var/cache/pacman/custom
EOF

# 4. Sync pacman
sudo pacman -Sy

# 5. Build existing packages to repo
./scripts/sync-all.sh
```

### Daily Updates

```bash
# Simple: auto-update everything
./scripts/sync-all.sh

# Safe: review before updating
./scripts/sync-all.sh --review

# Paranoid: clean builds with review
./scripts/sync-all.sh --review --chroot
```

### Add New Package

```bash
# From AUR with auto-detection
./scripts/aur-imports.sh ktailctl --infer

# With dependencies
./scripts/aur-imports.sh --with-deps ollama

# Then update to trigger build
./scripts/update-pkg.sh ktailctl
```

### Update Specific Packages

```bash
# Check for updates
./scripts/update-pkg.sh --dry-run

# Update specific packages
./scripts/update-pkg.sh ktailctl ollama

# With review
./scripts/update-pkg.sh --review google-chrome-canary-bin
```

### Repository Maintenance

```bash
# Check repository status
./scripts/repo-mgmt.sh status

# Clean old versions
./scripts/cleanup-repo.sh --auto --keep-n 2

# Remove packages not in feeds.json
./scripts/cleanup-repo.sh --orphans-only

# Verify integrity
./scripts/repo-mgmt.sh verify
```

### Troubleshooting

```bash
# Check what would update
./scripts/update-pkg.sh --dry-run

# Compare version detection
./scripts/compare-versions.sh

# Check Arch news
./scripts/check-news.sh

# View session logs
ls -la ~/.cache/pkg-mgmt/logs/
```

## Integration with aurutils/paru

### What We Use from aurutils

**Dependency Resolution** (aur-depends)
- Complete AUR dependency graphs
- Topologically sorted build order
- Handles provides/conflicts

**Version Comparison** (aur-vercmp)
- Accurate version comparisons
- Epoch handling
- Proper pacman semantics

**VCS Package Handling** (aur-srcver)
- Update pkgver() functions
- Handle -git/-hg/-svn packages

**Repository Management Patterns**
- Lock file handling
- Error diagnostics
- Review tracking

### What We Use from paru

**Ad-hoc Package Installation**
```bash
# Quick installs outside feeds.json
paru some-random-package

# Search AUR
paru -Ss search-term

# AUR comments
paru -Gc package-name
```

**Cross-checking**
```bash
# Compare our detection vs paru
paru -Qua
./scripts/compare-versions.sh
```

### What We DON'T Use

**Not using aurutils for:**
- Custom update sources (Chrome, Edge, VS Code, etc.)
- feeds.json management
- Daily workflow orchestration

**Not using paru for:**
- Automated workflows
- feeds.json packages
- Repository management

## Advanced Features

### Chroot Builds

Reproducible, isolated builds:

```bash
# Enable for all builds
export ENABLE_CHROOT=true
./scripts/sync-all.sh

# Or per-package
./scripts/update-pkg.sh --chroot ktailctl
```

### Review Workflow

Track what you've reviewed:

```bash
# Review during update
./scripts/update-pkg.sh --review google-chrome-canary-bin

# Review shows:
# - Diff since last review
# - Changes to PKGBUILD, .SRCINFO, install scripts
# - AUR comments (if requested)
# - Interactive approval

# State tracked in ~/.local/share/pkg-mgmt/reviewed/
```

### Batch Operations

```bash
# Import multiple packages
echo -e "ktailctl\nollama\nvesktop" > packages.txt
./scripts/aur-imports.sh --from-file packages.txt --with-deps

# Update multiple packages
./scripts/update-pkg.sh ktailctl ollama vesktop

# Install from repo
./scripts/install-updates.sh --from-repo
```

### JSON Output for Scripting

```bash
# Dependency info
./scripts/resolve-deps.sh --json ktailctl

# News
./scripts/check-news.sh --json

# Version comparison
./scripts/compare-versions.sh --json
```

## Troubleshooting

### Dependency Resolution Fails

```bash
# Check aurutils is working
aur depends ktailctl

# Manual resolution
./scripts/resolve-deps.sh --verbose ktailctl

# Import individually
./scripts/aur-imports.sh missing-dep
```

### Repository Issues

```bash
# Verify repo exists
./scripts/repo-mgmt.sh status

# Check pacman config
grep -A3 '\[custom\]' /etc/pacman.conf

# Rebuild database
cd /var/cache/pacman/custom
repo-add custom.db.tar.gz *.pkg.tar.zst

# Sync pacman
sudo pacman -Sy
```

### Build Failures

```bash
# Check logs
ls -la ~/.cache/pkg-mgmt/logs/

# Preserved artifacts
ls -la ~/.cache/pkg-mgmt/logs/failed-builds/

# Try chroot build
./scripts/build-chroot.sh --clean package-name
```

### Lock File Issues

```bash
# Check for stale locks
ls -la /tmp/pkg-mgmt-locks/

# Remove (if no update-pkg.sh running)
rm /tmp/pkg-mgmt-locks/*.lock
```

## Migration from Old System

See `ENHANCEMENTS.md` for detailed migration guide.

Quick migration:

```bash
# 1. Copy new scripts
cp /path/to/new/scripts/* ./scripts/

# 2. Update config.sh
vim ./scripts/config.sh

# 3. Initialize repo
./scripts/repo-mgmt.sh init

# 4. Build everything to repo
./scripts/sync-all.sh

# 5. Verify
./scripts/repo-mgmt.sh list
./scripts/compare-versions.sh
```

## Performance Tips

**Speed up updates:**
```bash
# Skip news check
./scripts/sync-all.sh --skip-news

# Update specific packages only
./scripts/sync-all.sh ktailctl ollama

# Use parallel builds (not implemented yet)
```

**Reduce storage:**
```bash
# Clean old versions aggressively
./scripts/cleanup-repo.sh --auto --keep-n 1

# Remove source directories after build
# (edit PKGBUILD to add: rm -rf src/)
```

## Security Considerations

**PKGBUILD Review**
- Always review before first build
- Check for suspicious commands
- Verify source URLs

**Repository Trust**
- SigLevel set to "Optional TrustAll"
- Packages are self-built
- No signature verification on repo

**Chroot Isolation**
- Builds in clean environment
- Prevents host contamination
- Verifies dependency completeness

## Contributing

This is a personal package management system, but improvements welcome:

1. Test thoroughly before committing
2. Update ENHANCEMENTS.md for script changes
3. Add examples to README
4. Update config.sh for new options

## License

Scripts are provided as-is. Use at your own risk.

## Credits

- **aurutils**: Dependency resolution, version comparison
- **paru**: Inspiration for review workflow, news checking
- **Arch Linux**: Best distro for this kind of tinkering