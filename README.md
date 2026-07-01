# apps_casdoor

Casdoor Kubernetes offline `.run` installer package.

This package builds a Casdoor image from upstream `casdoor/casdoor`, packages the image into a self-extracting offline `.run`, retags and pushes it to an internal registry at install time, renders `app.conf`, and deploys Casdoor on Kubernetes.

## Version

- package version: `2026.07.01`
- default upstream ref: `master`
- default namespace: `casdoor`
- default service type: `ClusterIP`
- default listen address: `0.0.0.0:8000`
- default image: `sealos.hub:5000/kube4/casdoor/casdoor:2026.07.01`

The package self-builds Casdoor instead of simply pulling `casbin/casdoor:latest`.

## What this package creates

- Namespace
- Secret: `casdoor-config`, containing `/conf/app.conf`
- Service: `casdoor`
- Deployment: `casdoor`

Service port:

```text
HTTP: 8000
```

## Upstream references

The upstream default `conf/app.conf` uses `httpport = 8000`, `driverName`, `dataSourceName`, and `dbName` for database configuration. The official docker-compose example starts Casdoor with `./server --createDatabase=true`, sets `RUNNING_IN_DOCKER=true`, and mounts `/conf`. This package follows that model, but renders `app.conf` from installer arguments and stores it in a Kubernetes Secret.

This package additionally renders `httpaddr = 0.0.0.0` by default so the Casdoor process listens on all interfaces inside the Pod. Without this, the process can appear healthy locally but fail through Service/NodePort/Ingress depending on how the runtime binds the listener.

## Build locally

Build host requirements:

- Linux shell
- Docker Buildx
- Python 3
- `tar`
- `sha256sum`

No `jq` is required.

Build one architecture:

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
```

Build both:

```bash
bash build.sh --arch all
```

Build from a specific upstream tag, branch, or commit:

```bash
bash build.sh --arch amd64 --casdoor-ref master
```

Artifacts are written to `dist/`:

```text
dist/casdoor-2026.07.01-amd64.run
dist/casdoor-2026.07.01-amd64.run.sha256
dist/casdoor-2026.07.01-arm64.run
dist/casdoor-2026.07.01-arm64.run.sha256
```

## Target host requirements

Target host requirements:

- `bash`
- common Linux base tools: `awk`, `head`, `wc`, `dd`, `od`, `tail`, `tar`, `sed`, `base64`
- `docker`, unless `--skip-image-prepare` is used
- `kubectl`
- optional `sha256sum`, only for checking the `.sha256` file before running the installer

The target host does **not** need `jq` or Python.

## Prepare database

Casdoor still needs an external database. This package does not deploy MySQL or PostgreSQL.

### MySQL example

Create database user and let Casdoor create the database automatically with `--createDatabase=true`, or create the database yourself first.

Example installer DSN:

```text
root:password@tcp(mysql.default.svc.cluster.local:3306)/
```

### PostgreSQL example

Example installer DSN:

```text
user=postgres password=password host=postgres.default.svc.cluster.local port=5432 sslmode=disable
```

## Install with MySQL

```bash
sha256sum -c casdoor-2026.07.01-amd64.run.sha256
chmod +x casdoor-2026.07.01-amd64.run

./casdoor-2026.07.01-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'passw0rd' \
  -n casdoor \
  --db-driver mysql \
  --data-source-name 'root:password@tcp(mysql.default.svc.cluster.local:3306)/' \
  --db-name casdoor \
  --http-addr 0.0.0.0 \
  --origin 'https://casdoor.example.com' \
  -y
```

## Install with PostgreSQL

```bash
./casdoor-2026.07.01-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'passw0rd' \
  -n casdoor \
  --db-driver postgres \
  --data-source-name 'user=postgres password=password host=postgres.default.svc.cluster.local port=5432 sslmode=disable' \
  --db-name casdoor \
  --http-addr 0.0.0.0 \
  --origin 'https://casdoor.example.com' \
  -y
```

If the target registry already contains the Casdoor image:

```bash
./casdoor-2026.07.01-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -n casdoor \
  --db-driver postgres \
  --data-source-name 'user=postgres password=password host=postgres.default.svc.cluster.local port=5432 sslmode=disable' \
  --db-name casdoor \
  --http-addr 0.0.0.0 \
  --origin 'https://casdoor.example.com' \
  -y
```

## External access

`httpaddr = 0.0.0.0` only controls the listener inside the container. To access Casdoor from outside the cluster, you still need one of these exposure methods:

- `--service-type NodePort --nodeport-http <port>`
- `--service-type LoadBalancer`
- Ingress / Gateway API / reverse proxy pointing to `casdoor.casdoor.svc.cluster.local:8000`

The `--origin` value must match the real browser URL. For example, when using NodePort:

```bash
./casdoor-2026.07.01-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --service-type NodePort \
  --nodeport-http 32080 \
  -n casdoor \
  --db-driver mysql \
  --data-source-name 'root:password@tcp(mysql.default.svc.cluster.local:3306)/' \
  --db-name casdoor \
  --http-addr 0.0.0.0 \
  --origin 'http://NODE_IP:32080' \
  -y
```

## Status

```bash
./casdoor-2026.07.01-amd64.run status -n casdoor
kubectl get pods,svc,deploy,secret -n casdoor -l app.kubernetes.io/name=casdoor
kubectl logs -n casdoor deploy/casdoor
```

Check the rendered `app.conf`:

```bash
kubectl get secret -n casdoor casdoor-config -o jsonpath='{.data.app\.conf}' | base64 -d | grep -E '^(httpaddr|httpport|origin)'
```

Expected:

```text
httpaddr = 0.0.0.0
httpport = 8000
origin = http://NODE_IP:32080
```

## Uninstall

```bash
./casdoor-2026.07.01-amd64.run uninstall -n casdoor -y
```

Delete namespace too:

```bash
./casdoor-2026.07.01-amd64.run uninstall -n casdoor --delete-namespace -y
```

The installer does not delete your external database or Casdoor tables.

## Important notes

- Use `--origin` that matches the real browser access URL, otherwise OAuth redirect URLs and frontend behavior may be wrong.
- `--http-addr 0.0.0.0` is the default and is required for normal Service/NodePort/Ingress access.
- `--create-database true` is the default and matches the upstream docker-compose example.
- For production, use an external MySQL or PostgreSQL service with backup enabled.
- This package renders `app.conf` into a Kubernetes Secret. Treat it as sensitive because it contains the database DSN.
- Casdoor is usually a single Deployment replica unless your DB/session/cache design is ready for multi-replica behavior.

## GitHub Actions

The workflow `.github/workflows/offline-run-packages.yml` builds both `amd64` and `arm64` artifacts on:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are attached to the GitHub Release.
