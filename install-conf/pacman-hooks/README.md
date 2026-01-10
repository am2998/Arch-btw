# Pacman hook: ZFS snapshots

Questi file creano uno snapshot ZFS *prima* di ogni transazione `pacman` che installa o aggiorna pacchetti.

## Cosa fa

- Hook pacman (PreTransaction) su `Install` e `Upgrade`
- Script che crea snapshot best-effort (non blocca `pacman` se lo snapshot fallisce)
- Snapshot su:
  - dataset montato su `/`
  - dataset montato su `/home` (se ZFS)
  - dataset montato su `/var` (se ZFS)

## Installazione (manuale)

- Copia il file hook in `/etc/pacman.d/hooks/`
- Copia lo script in `/usr/local/sbin/zfs-pacman-snapshot` e rendilo eseguibile

## Disabilitazione temporanea

- Se esiste il file `/etc/zfs-pacman-snapshot.disable`, lo script non fa nulla.

## Nome snapshot

Formato (UTC): `pacman-<pre|post>-uYYYYmmddTHHMMSSZ-<hash>`

L'hash deriva dalla lista target che pacman passa al hook (quando disponibile).
