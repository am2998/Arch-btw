# AGENTS.md

Shell-script-only repo: an Arch Linux ZFS installer (`src/scripts/archzfs.sh`) plus pacman hooks and zrepl tooling, packaged into a custom ISO. No build system, tests, or package manifests.

## Verification

Only CI checks are `bash -n` and `shellcheck` on every tracked `*.sh`. Run both before a PR (this is exactly what `.github/workflows/lint.yml` runs):

```bash
while IFS= read -r f; do bash -n "$f"; done < <(git ls-files '*.sh')
shellcheck --severity=warning --external-sources $(git ls-files '*.sh')
```

There is no way to test the installer locally in full; real-install testing needs UEFI/OVMF and target hardware. Treat `bash -n`/`shellcheck` as the only executable feedback unless running a VM.

## `src/scripts/archzfs.sh` is a two-layer script

- Lines ~1–493 (outer) run in the live ISO as root: validation, partitioning, `zpool create`, `pacstrap`.
- A quoted heredoc (`<<'EOF'` at ~line 494, ending at ~1141) is a **separate script executed inside the chroot** via `arch-chroot /mnt /usr/bin/env VAR=...`. Because the heredoc is quoted, nothing is interpolated at write time:
  - New variables used inside the chroot must be added to the `/usr/bin/env` list on the `arch-chroot` invocation.
  - Any helper function used inside the chroot must be added to the `declare -f` block that writes helpers to `/mnt/root/.arch-install-helpers.sh`.
- ShellCheck sees it all as one file; inline `# shellcheck disable=` comments map quirks (e.g. `INSTALL_DESKTOP` looks unused in the outer scope but is read by the chroot part).

## ISO packaging is coupled to file paths

`.github/workflows/build-arch-lts-zfs.yml` embeds a fixed file set into the ISO:
- `src/scripts/archzfs.sh` → `/root/archzfs.sh`
- `src/pacman-hooks/zfs-dracut-kernel-refresh.sh` and `src/pacman-hooks/60-zfs-dracut-post.hook` → `/usr/local/share/archzfs/`

If the installer starts needing another repo file in the live environment, it must also be added to that workflow (install step **and** the post-build extraction check). `zfs-pacman-snapshot.sh` / `50-zfs-snapshot-pre.hook` are intentionally not bundled — manual install only.

## Invariants that are easy to break silently

- Never persist or ship the ZFS pool key: no key file on the ESP, no key inside the initramfs/UKI (`keylocation=prompt`; the script actively verifies the UKI contains no key). The UKI lives on the unencrypted ESP.
- Keep the pool compatibility set `openzfs-2.3` (`ZFS_COMPAT`) and keep it an explicit `zpool create -o compatibility=...`: the bundled ZFSBootMenu EFI must always be able to import the pool. `ZBM_KERNEL_VARIANT` is an env override for the ZBM release asset.
- Boot chain must stay self-signed: `systemd-boot-update.service` stays disabled (unsigned update); the pacman hook / refresh helper rebuilds and re-signs the UKI and `bootctl install` result with `sbctl`.

## Conventions and docs

- Scripts are self-contained; do not source files across repo directories (see `.shellcheckrc`).
- `src/scripts/backup/*` is legacy reference only — don't fix or modernize it unless asked.
- The README's "Script Implementation Details" is the documented contract for `archzfs.sh` behavior. Per contribution rules, update it (and the per-directory READMEs in `src/pacman-hooks/`, `src/zrepl/`) whenever flags, paths, or defaults change.
- Workflow quirk: during the ISO build, `[archzfs]` repo uses `SigLevel = TrustAll`; the installed system normalizes it to `Required` after importing the release key (see comment in the workflow).
