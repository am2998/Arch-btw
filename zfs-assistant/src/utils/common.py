#!/usr/bin/env python3
# ZFS Assistant - Common utilities and constants
# Author: GitHub Copilot

import os
import subprocess
import datetime
import re

# Application constants
APP_NAME = "ZFS Snapshot Assistant"
APP_ID = "org.archlinux.zfsassistant"
VERSION = "1.0.0"

# Default window sizes
DEFAULT_WINDOW_WIDTH = 900
DEFAULT_WINDOW_HEIGHT = 600
MIN_WINDOW_WIDTH = 800
MIN_WINDOW_HEIGHT = 500

# Configuration defaults
DEFAULT_CONFIG = {
    "auto_snapshot": True,
    "snapshot_retention": {
        "daily": 7,
        "weekly": 4,
        "monthly": 12
    },    
    "daily_schedule": [0, 1, 2, 3, 4],    # Default to weekdays
    "daily_hour": 0,                      # Default hour for daily snapshots
    "weekly_schedule": True,              # Enable weekly by default
    "monthly_schedule": True,             # Enable monthly by default
    "datasets": [],
    "pacman_integration": True,
    "update_snapshots": "disabled",       # Options: "disabled", "enabled", "pacman_only"
    "clean_cache_after_updates": False,   # Default to not cleaning cache
    "snapshot_name_format": "prefix-type-timestamp", # Default snapshot naming format
    "prefix": "zfs-assistant",
    "external_backup_enabled": False,     # Default to disabled external backup
    "external_pool_name": "",             # No default external pool
    "backup_frequency": "Manual",         # Default backup frequency
    "dark_mode": False,
    "notifications_enabled": True
}

# File paths - System-wide configuration since application runs with elevated privileges
CONFIG_DIR = "/etc/zfs-assistant"
CONFIG_FILE = "/etc/zfs-assistant/config.json"
LOG_FILE = "/var/log/zfs-assistant.log"
PACMAN_HOOK_PATH = "/etc/pacman.d/hooks/00-zfs-snapshot.hook"
SYSTEMD_SCRIPT_PATH = "/usr/local/bin/zfs-assistant-systemd.py"
PACMAN_SCRIPT_PATH = "/usr/local/bin/zfs-assistant-pacman-hook.py"

# Security validation helpers
_DISALLOWED_SHELL_CHARS = set(" \t\r\n'\"`;$|&<>\\")
_SAFE_ZFS_TOKEN_RE = re.compile(r"^[A-Za-z0-9._:/+-]+$")
_SAFE_PREFIX_RE = re.compile(r"^[A-Za-z0-9._-]+$")
_SAFE_ARC_PARAM_RE = re.compile(r"^zfs_[A-Za-z0-9_]+$")
_SAFE_INT_RE = re.compile(r"^-?[0-9]+$")

# Utility functions
def run_command(cmd, capture_output=True, check=True):
    """Run a shell command and return the result"""
    try:
        result = subprocess.run(
            cmd, 
            capture_output=capture_output, 
            text=True, 
            check=check
        )
        return True, result
    except subprocess.CalledProcessError as e:
        return False, e
    except Exception as e:
        return False, e

def get_timestamp():
    """Get current timestamp formatted for filenames"""
    return datetime.datetime.now().strftime("%Y%m%d-%H%M")

def is_safe_zfs_token(value: str) -> bool:
    """Allowlist validator for dataset/pool/snapshot tokens."""
    if not value or not isinstance(value, str):
        return False
    if any(ch in _DISALLOWED_SHELL_CHARS for ch in value):
        return False
    return bool(_SAFE_ZFS_TOKEN_RE.match(value))

def is_safe_snapshot_prefix(value: str) -> bool:
    """Allowlist validator for snapshot prefix from configuration."""
    if not value or not isinstance(value, str):
        return False
    if any(ch in _DISALLOWED_SHELL_CHARS for ch in value):
        return False
    return bool(_SAFE_PREFIX_RE.match(value))

def is_safe_arc_parameter(value: str) -> bool:
    """Allowlist validator for ARC tunable parameter names."""
    return bool(value and isinstance(value, str) and _SAFE_ARC_PARAM_RE.match(value))

def is_safe_integer(value: str) -> bool:
    """Strict integer validator used for sysfs tunables."""
    return bool(value and isinstance(value, str) and _SAFE_INT_RE.match(value.strip()))
