# ZFS Assistant

A GTK4/libadwaita desktop application for managing ZFS snapshots on Linux.

## Current Repository State

This repository currently provides a **source workflow** (Python package + direct module run).
AppImage build scripts referenced in older revisions are not part of this tree.

## Features

- Snapshot listing/creation/deletion
- Rollback and clone operations
- Scheduled snapshots with systemd timer integration
- Optional pacman pre-transaction snapshot hook
- ARC property monitoring and tuning UI
- Config import/export

## Project Structure

```text
zfs-assistant/
├── Makefile
├── setup.py
└── src/
    ├── __main__.py
    ├── application.py
    ├── zfs_assistant.py
    ├── core/
    ├── backup/
    ├── system/
    ├── ui/
    └── utils/
```

## Prerequisites

- Linux
- Python 3.8+
- ZFS userspace tools (`zfs`, `zpool`)
- GTK4 + libadwaita + Python GI bindings

Example packages:

```bash
# Arch Linux
sudo pacman -S gtk4 libadwaita python-gobject python-cairo zfs-utils

# Debian/Ubuntu (package names may vary by release)
sudo apt install libgtk-4-dev libadwaita-1-dev python3-gi python3-gi-cairo
```

## Installation (Source)

```bash
git clone https://github.com/am2998/Arch-Lab.git
cd Arch-Lab/zfs-assistant
python3 -m pip install -r src/requirements.txt
python3 -m pip install -e .
```

Or via Makefile:

```bash
make install
```

## Running

From installed console script:

```bash
zfs-assistant
```

From source module:

```bash
python3 -m src
```

The app may request elevation (`pkexec`) for ZFS/system integration operations.

## Build / Test Helpers

```bash
make release   # build wheel/sdist via python -m build
make test      # syntax smoke test (py_compile)
make clean
```

## Troubleshooting

1. If ZFS commands fail, verify ZFS is installed and module loaded:

```bash
sudo modprobe zfs
zfs version
```

2. If elevation fails, ensure `pkexec`/polkit is installed and configured.

3. If GTK fails to initialize, verify GTK4/libadwaita GI packages are available.

## License

MIT (see `LICENSE`).
