[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/gitbucket-1?utm_medium=integration&utm_source=button&utm_campaign=gitbucket)

# GitBucket on Railway

One-click [Railway](https://railway.com) template for [GitBucket](https://github.com/gitbucket/gitbucket) **4.48.0**, the open-source Git platform with issues, pull requests, wikis and a GitHub-compatible API (Apache-2.0). The app service builds from this repository, so when we bump the version here, Railway offers deployers an update.

## What the template deploys

| Service | Built from | What it does |
|---|---|---|
| `gitbucket` (public) | this repo's [`Dockerfile`](Dockerfile) | The official image `ghcr.io/gitbucket/gitbucket:4.48.0`, pinned by digest, plus [`start.sh`](start.sh). Web UI, REST API (`/api/v3`) and Git over HTTPS on the public domain; Git over SSH through a Railway TCP proxy. Repositories, wikis, attachments, plugins and the SSH host key live on a volume at `/gitbucket`. Health check `/signin`. |
| `Postgres` | Railway's PostgreSQL | Accounts, issues, pull requests, settings. |

## What the start script does

1. Waits for PostgreSQL and points GitBucket at it (`GITBUCKET_DB_URL`, built from the `PG*` references).
2. On a new database, builds GitBucket's schema on `127.0.0.1` only, then replaces the built-in `root`/`root` account password with the generated `ADMIN_PASSWORD`, before the public port opens. A PostgreSQL advisory lock keeps two overlapping deploys from doing this twice.
3. Sets the base URL from the Railway public domain, and enables SSH when the service has a TCP proxy.
4. Sizes the JVM for small plans (Serial GC, heap 45% of the memory limit, exit on `OutOfMemoryError`), and exits non-zero if GitBucket stops or stops answering for 5 minutes, so Railway's `ON_FAILURE` restart policy brings it back.

## After deploy

1. Open the public URL and sign in as **`root`** with the `ADMIN_PASSWORD` value from the `gitbucket` service's **Variables** tab. Change it under **Account settings** if you like.
2. Create users under **Administration → User management**. Self-registration is off by default (**System settings** turns it on).
3. **System settings → Anonymous access** is on by default, as upstream ships it: public repositories are readable without an account. Turn it off for a fully private instance.
4. Git over SSH: add your public key under **Account settings → SSH keys** and use the `ssh://git@…` clone URL GitBucket shows (it points at the Railway TCP proxy).
5. Optional: email notifications need SMTP settings in **System settings**.

## Variables

| Service | Variable | Value |
|---|---|---|
| `gitbucket` | `ADMIN_PASSWORD` | Generated 24-character password for `root`, applied on the first deploy only |
| `gitbucket` | `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` | References to the `Postgres` service |
| `gitbucket` | `PORT` | `8080` |

Nothing has to be typed in. Other GitBucket settings can be set as `GITBUCKET_*` variables ([upstream docs](https://github.com/gitbucket/gitbucket/wiki/Basic-configurations)), for example `GITBUCKET_BASE_URL` for a custom domain. `GITBUCKET_HEAP_PERCENT` (default 45) changes the JVM heap share.

## Resources

Runs in 0.5 GB RAM / 1 vCPU (Railway's Free plan): about 170 MB in use after first setup and a push. Large repositories or many users need more; raise the service's memory and the heap follows.

## Updates

We bump the pinned image in this repository and note each version in [CHANGELOG.md](CHANGELOG.md), breaking changes first. Railway then shows an update notice on your project; apply it when you're ready. GitBucket migrates its database on start, so back up the `Postgres` service and the `/gitbucket` volume first.

## Licence

The wrapper files in this repository are MIT. GitBucket is Apache-2.0.
