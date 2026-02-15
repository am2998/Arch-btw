#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Bootstrap zrepl local backup to an external disk.

Usage:
  bootstrap-zrepl-local-backup.sh --source-pool <pool> [options]

Required:
  --source-pool <pool>       Source pool to snapshot/replicate (e.g. zroot)

Options:
  --backup-disk <path>       Backup disk block device (default: /dev/sdc)
  --backup-pool <name>       Backup pool name to create/use (default: backup)
  --create-backup-pool       Allow creating backup pool if missing (disabled by default)
  --source-dataset <name>    Exact source dataset to back up (default: auto-detect mounted / dataset)
  --client-identity <name>   zrepl client identity (default: short hostname)
  --config <path>            Output zrepl config path (default: ./zrepl.yml)
  --apply                    Execute zpool/zfs commands (default: dry-run)
  -h, --help                 Show this help
USAGE
}

SOURCE_POOL=""
BACKUP_DISK="/dev/sdc"
BACKUP_POOL="backup"
BACKUP_POOL_USER_SET=0
DEFAULT_NODE="$(uname -n 2>/dev/null || echo localhost)"
CLIENT_IDENTITY="${DEFAULT_NODE%%.*}"
CONFIG_PATH="./zrepl.yml"
SOURCE_DATASET=""
APPLY=0
CREATE_BACKUP_POOL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-pool)
      SOURCE_POOL="${2:-}"
      shift 2
      ;;
    --backup-disk)
      BACKUP_DISK="${2:-}"
      shift 2
      ;;
    --backup-pool)
      BACKUP_POOL="${2:-}"
      BACKUP_POOL_USER_SET=1
      shift 2
      ;;
    --client-identity)
      CLIENT_IDENTITY="${2:-}"
      shift 2
      ;;
    --source-dataset)
      SOURCE_DATASET="${2:-}"
      shift 2
      ;;
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --create-backup-pool)
      CREATE_BACKUP_POOL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE_POOL" ]]; then
  echo "Error: --source-pool is required." >&2
  usage
  exit 1
fi

HAVE_ZFS_TOOLS=1
for cmd in zpool zfs; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    HAVE_ZFS_TOOLS=0
  fi
done

if [[ "$APPLY" -eq 1 && "$HAVE_ZFS_TOOLS" -eq 0 ]]; then
  echo "Error: --apply requires both zpool and zfs commands installed." >&2
  exit 1
fi

if [[ "$HAVE_ZFS_TOOLS" -eq 1 && "$BACKUP_POOL_USER_SET" -eq 0 ]]; then
  BACKUP_POOL="backup"
fi

if [[ -z "$SOURCE_DATASET" ]]; then
  if [[ "$HAVE_ZFS_TOOLS" -eq 1 ]]; then
    if ROOT_DATASETS="$(zfs list -H -o name,mounted,mountpoint -r "$SOURCE_POOL" 2>/dev/null | awk '$2=="yes" && $3=="/"{print $1}')"; then
      ROOT_DATASET_COUNT="$(printf '%s\n' "$ROOT_DATASETS" | sed '/^$/d' | wc -l | tr -d ' ')"

      if [[ "$ROOT_DATASET_COUNT" -eq 1 ]]; then
        SOURCE_DATASET="$ROOT_DATASETS"
      elif [[ "$ROOT_DATASET_COUNT" -gt 1 ]]; then
        echo "Error: multiple mounted '/' datasets found under pool '$SOURCE_POOL':" >&2
        printf '%s\n' "$ROOT_DATASETS" >&2
        echo "Set one explicitly with --source-dataset <dataset>." >&2
        exit 1
      elif [[ "$APPLY" -eq 1 ]]; then
        echo "Error: no mounted '/' dataset found under pool '$SOURCE_POOL'." >&2
        echo "Set one explicitly with --source-dataset <dataset>." >&2
        exit 1
      else
        SOURCE_DATASET="$SOURCE_POOL"
        echo "Dry-run note: could not detect mounted '/' dataset under '$SOURCE_POOL'; using '$SOURCE_DATASET' for preview." >&2
      fi
    elif [[ "$APPLY" -eq 1 ]]; then
      echo "Error: cannot inspect ZFS datasets (permission denied or unavailable)." >&2
      echo "Use --source-dataset <dataset> or run with sufficient privileges." >&2
      exit 1
    else
      SOURCE_DATASET="$SOURCE_POOL"
      echo "Dry-run note: cannot inspect ZFS datasets; using '$SOURCE_DATASET' for preview. Use --source-dataset to force exact dataset." >&2
    fi
  elif [[ "$APPLY" -eq 1 ]]; then
    echo "Error: --apply requires zfs to auto-detect the mounted '/' dataset. Use --source-dataset to set it explicitly." >&2
    exit 1
  else
    SOURCE_DATASET="$SOURCE_POOL"
    echo "Dry-run note: zfs not available; using '$SOURCE_DATASET' for preview. Use --source-dataset to force exact dataset." >&2
  fi
fi

run() {
  if [[ "$APPLY" -eq 1 ]]; then
    "$@"
  else
    echo "[dry-run] $*"
  fi
}

echo "Writing zrepl config to: $CONFIG_PATH"
echo "Using source dataset: $SOURCE_DATASET"
cat > "$CONFIG_PATH" <<EOF_CONFIG
jobs:
- type: push
  name: backup_hourly
  connect:
    type: local
    listener_name: backup_sink
    client_identity: ${CLIENT_IDENTITY}
  filesystems: {
      "${SOURCE_DATASET}": true
  }
  send:
    encrypted: true
  replication:
    protection:
      initial: guarantee_resumability
      incremental: guarantee_incremental
  snapshotting:
    type: periodic
    prefix: zrepl_
    interval: 1h
  pruning:
    keep_sender:
    - type: grid
      grid: 24 x1h | 30 x1d | 8 x30d
      regex: "^zrepl_.*"
    - type: regex
      regex: "^(base|pacman-.*)$"
    keep_receiver:
    - type: grid
      grid: 24 x1h | 30 x1d | 12 x30d
      regex: "^zrepl_.*"
    - type: regex
      regex: "^base$"

- type: sink
  name: backup_sink
  root_fs: "${BACKUP_POOL}/zrepl/sink"
  serve:
    type: local
    listener_name: backup_sink
EOF_CONFIG

if [[ "$HAVE_ZFS_TOOLS" -eq 0 ]]; then
  echo "Skipping pool/dataset checks because zpool/zfs are not available in this environment."
else
  if zpool list -H -o name "$BACKUP_POOL" >/dev/null 2>&1; then
    echo "Backup pool already exists: $BACKUP_POOL"
  else
    IMPORTABLE=0
    if zpool import 2>/dev/null | awk '/^[[:space:]]*pool: /{print $2}' | grep -Fxq "$BACKUP_POOL"; then
      IMPORTABLE=1
    fi

    if [[ "$IMPORTABLE" -eq 1 ]]; then
      echo "Backup pool exists but is not imported: $BACKUP_POOL"
      run sudo zpool import "$BACKUP_POOL"
    elif [[ "$CREATE_BACKUP_POOL" -eq 1 ]]; then
      echo "Backup pool does not exist and will be created on $BACKUP_DISK"
      echo "WARNING: zpool create will overwrite existing data on $BACKUP_DISK"
      run sudo zpool create -f "$BACKUP_POOL" "$BACKUP_DISK"
    else
      if [[ "$APPLY" -eq 1 ]]; then
        echo "Error: backup pool '$BACKUP_POOL' is not imported and not importable." >&2
        echo "Refusing to create automatically. Re-run with --create-backup-pool if you intend to create it on $BACKUP_DISK." >&2
        exit 1
      fi
      echo "Dry-run note: backup pool '$BACKUP_POOL' is not imported/importable in this environment." >&2
      echo "Dry-run note: add --create-backup-pool to preview/create a new pool on $BACKUP_DISK." >&2
    fi
  fi

  if zfs list -H -o name "$BACKUP_POOL/zrepl/sink" >/dev/null 2>&1; then
    echo "Dataset already exists: $BACKUP_POOL/zrepl/sink"
  else
    run sudo zfs create -p "$BACKUP_POOL/zrepl/sink"
  fi
fi

cat <<EOF_DONE

Next steps:
1) Validate config:
   sudo zrepl configcheck --config "$CONFIG_PATH"
2) Install config:
   sudo install -m 0644 "$CONFIG_PATH" /etc/zrepl/zrepl.yml
3) Start service:
   sudo systemctl enable --now zrepl
4) Trigger an immediate run now (optional):
   sudo zrepl signal wakeup backup_hourly
5) Check status:
   sudo zrepl status
EOF_DONE
