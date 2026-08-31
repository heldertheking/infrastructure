# Stack: backup

Automated offsite backups for homelab configuration data using Restic.

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| `restic` | `mazzolino/restic:1.7.2` | Runs scheduled nightly backups of `/opt/appdata` to S3-compatible offsite storage |

## What gets backed up

- `/opt/appdata` (mounted read-only as `${PATH_APPDATA_SOURCE}`)  
  Includes service configs, persistent app state, and embedded databases.

## Media strategy evaluation (`/mnt/storage-hdd`)

`/mnt/storage-hdd` is usually large media content and is expensive to snapshot nightly with Restic.

Recommended approach:
- Keep **Restic** focused on `/opt/appdata`.
- Use a separate **cold-storage sync** (for example `rclone sync`) for selected media folders on a slower cadence (weekly/monthly), ideally to a lower-cost storage class.

This keeps recovery for critical configs fast and affordable while still giving optional long-term protection for media.

## Setup

```bash
cp stacks/backup/.env.backup.example stacks/backup/.env
# Fill in repository and credentials
docker compose -f stacks/backup/compose.yaml --env-file stacks/backup/.env up -d
```

Or with the root Makefile:

```bash
make up STACK=backup
```

## Configuration Variables

See [`.env.backup.example`](.env.backup.example) for a ready-to-copy template.

| Variable | Description | Example |
|----------|-------------|---------|
| `STACK_NAME` | Compose project name | `backup` |
| `PATH_APPDATA` | Backup stack state/cache path | `/opt/appdata/backup` |
| `PATH_APPDATA_SOURCE` | Source data path to back up nightly | `/opt/appdata` |
| `PATH_MEDIA_SOURCE` | Media root (for optional cold-sync workflows) | `/mnt/storage-hdd` |
| `PATH_LOGS` | Log directory | `/var/log/backup` |
| `TZ` | Timezone | `Europe/Zurich` |
| `BACKUP_CRON` | Backup schedule (cron with seconds) | `0 30 2 * * *` |
| `RESTIC_REPOSITORY` | Offsite repository URL (S3-compatible) | `s3:https://s3.example.com/my-bucket/homelab` |
| `RESTIC_PASSWORD` | Repository password | *(secret — never commit)* |
| `AWS_ACCESS_KEY_ID` | S3/B2 access key | *(secret — never commit)* |
| `AWS_SECRET_ACCESS_KEY` | S3/B2 secret key | *(secret — never commit)* |
| `AWS_DEFAULT_REGION` | S3 region | `us-east-1` |

## Restore procedure (tested commands)

1. Stop the affected stack(s) to avoid writes during restore.
2. List snapshots:

   ```bash
   docker compose -f stacks/backup/compose.yaml --env-file stacks/backup/.env run --rm restic snapshots
   ```

3. Inspect a snapshot before restoring:

   ```bash
   docker compose -f stacks/backup/compose.yaml --env-file stacks/backup/.env run --rm restic ls latest
   ```

4. Restore to a temporary directory for validation:

   ```bash
   mkdir -p /tmp/restic-restore
   docker compose -f stacks/backup/compose.yaml --env-file stacks/backup/.env run --rm restic restore latest --target /tmp/restic-restore
   ```

5. Copy validated data back to `/opt/appdata` and start services again.

## Optional media cold-sync example

For selected media folders, run manually (or via external scheduler):

```bash
rclone sync /mnt/storage-hdd/media remote:homelab-media --fast-list --transfers 4 --checkers 8
```
