# greenshift-jupyter

A Helm chart that deploys a read-only Jupyter notebook for [Greenshift](https://greenshift.app) clusters. The notebook connects to MariaDB, MongoDB, and ClickHouse using a dedicated read-only user. A Kubernetes `NetworkPolicy` enforces that the pod cannot reach anything other than those three databases and the cluster DNS server.

---

## Requirements

- Kubernetes 1.25+
- Helm 3.10+
- The Greenshift platform chart already deployed in the same namespace
- **For Azure environments:** [External Secrets Operator](https://external-secrets.io) installed and a `ClusterSecretStore` named `azure-kv` configured

---

## Required Secrets

### Local / dev (`externalSecret.enabled=false`)

Passwords are passed directly via `--set` at install time (see Install section below). No pre-created secrets are needed.

### Azure (`externalSecret.enabled=true`)

The following Key Vault secrets must exist before running `helm install`. Use `<release-name>` as the prefix — it must match the `externalSecret.remoteKeyPrefix` value you pass to Helm.

| Key Vault secret name | Description | Created by |
|-----------------------|-------------|------------|
| `<release-name>--jupyter-secret--token` | Notebook login token. Generate with `python3 -c 'import secrets; print(secrets.token_hex(32))'` | **You, before install** |
| `<release-name>--readonly-db-secret--mariadb-password` | `ro_user` password for MariaDB | Main Greenshift chart |
| `<release-name>--readonly-db-secret--mongo-password` | `ro_user` password for MongoDB | Main Greenshift chart |
| `<release-name>--readonly-db-secret--clickhouse-password` | `ro_user` password for ClickHouse | Main Greenshift chart |

The three `readonly-db-secret` entries are created automatically when the main Greenshift chart is deployed. The only secret you need to create manually is the Jupyter token.

To create it, contact the IT team and provide the Key Vault name, release name prefix, and the token value you want to set — or if you have direct Key Vault access:
```bash
az keyvault secret set \
  --vault-name <keyvault-name> \
  --name "<release-name>--jupyter-secret--token" \
  --value "$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
```

---

## Install

```bash
helm repo add greenshift https://greenshift-public-repos.github.io/greenshift-jupyter
helm repo update
```

**Local / dev (plain K8s Secret):**
```bash
helm install jupyter greenshift/jupyter \
  --namespace <namespace> \
  --set ingress.host="dev-greenshift.app" \
  --set ingress.className="nginx" \
  --set ingress.tls.enabled=false \
  --set db.mariadb.password="<password>" \
  --set db.mongo.password="<password>" \
  --set db.clickhouse.password="<password>"
```
Access the notebook at `https://<host>/jupyter`. Log in with token `local-jupyter-token` (default; override with `--set token=<value>`).

**Azure (External Secrets — Key Vault provides all sensitive values):**
```bash
helm install jupyter greenshift/jupyter \
  --namespace <namespace> \
  --set ingress.host="<cluster-domain>" \
  --set ingress.tls.existingSecret="defaultcert" \
  --set externalSecret.enabled=true \
  --set externalSecret.remoteKeyPrefix="<release-name>"
```

---

## How Deployment-Specific Values Are Set

Several fields must be set per deployment. None of them have a universal default.

### `ingress.host`

The domain the notebook is served on. Must exactly match the main Greenshift chart's `ingress.domainName`. Jupyter is served at `<host>/jupyter`.

```bash
--set ingress.host="application.test.greenshift.app"
```

### `token`

The password used to log in to the notebook. When `externalSecret.enabled=false`, this value is taken directly from `values.yaml` (defaults to `local-jupyter-token`). Set it explicitly for any non-local deployment that is not using External Secrets:

```bash
--set token="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
```

When `externalSecret.enabled=true`, the token is pulled from Key Vault and this field is ignored.

### `db.*.password`

The password for `ro_user` in each database. Must match whatever the Greenshift platform chart provisioned when it created the read-only user.

When `externalSecret.enabled=false`, pass each password explicitly:
```bash
--set db.mariadb.password="<password>" \
--set db.mongo.password="<password>" \
--set db.clickhouse.password="<password>"
```

When `externalSecret.enabled=true`, passwords are pulled from Key Vault and these fields are ignored.

### `externalSecret.remoteKeyPrefix`

The Key Vault key name prefix. Must match the Helm release name of the main Greenshift chart so that the correct secrets are fetched. Key Vault keys resolved:

```
<remoteKeyPrefix>--jupyter-secret--token
<remoteKeyPrefix>--readonly-db-secret--mariadb-password
<remoteKeyPrefix>--readonly-db-secret--mongo-password
<remoteKeyPrefix>--readonly-db-secret--clickhouse-password
```

The `readonly-db-secret` keys are created by the main Greenshift chart when it provisions the read-only database users. Only `jupyter-secret--token` is Jupyter-specific and must be created separately before installing this chart.

---

## TLS and Certificates

TLS is controlled by `ingress.tls.enabled` (default: `true`).

### Option A — Reuse an existing certificate (recommended for Greenshift)

The Greenshift platform chart provisions a TLS certificate for the cluster domain. Jupyter shares that certificate by referencing its K8s Secret name:

```yaml
ingress:
  tls:
    enabled: true
    existingSecret: "defaultcert"   # name of the TLS Secret in the namespace
```

Find the secret name with:
```bash
kubectl get secret -n <namespace> | grep tls
```

### Option B — Let cert-manager create a new certificate

Leave `existingSecret` empty and add the cert-manager cluster-issuer annotation:

```yaml
ingress:
  host: "application.test.greenshift.app"
  tls:
    enabled: true
    existingSecret: ""
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
```

cert-manager will issue a certificate for `ingress.host` and store it in a Secret named `<host-with-dashes>-tls` (e.g., `application-test-greenshift-app-tls`). cert-manager must be installed in the cluster.

### Option C — No TLS (local only)

```yaml
ingress:
  tls:
    enabled: false
```

---

## Security

### Read-Only Database Users

The notebook connects as `ro_user`, which is provisioned by the Greenshift platform chart on every deploy with the minimum privileges required to read data:

| Database   | Grants |
|------------|--------|
| MariaDB    | `SELECT` on all databases |
| MongoDB    | `readAnyDatabase` on `admin` |
| ClickHouse | `readonly` profile |

### NetworkPolicy

The pod has a `NetworkPolicy` with strict ingress and egress rules.

**Ingress** — only the ingress controller pods can reach port 8888. No other pod in the cluster can connect to the notebook directly, even within the same namespace.

**Egress** — each allowed port is locked to a specific pod, not open to all destinations:

| Port | Protocol | Destination | Purpose |
|------|----------|-------------|---------|
| 53 | UDP + TCP | `kube-system` namespace only | DNS via CoreDNS |
| 3306 | TCP | `app: mariadb` pod only | MariaDB |
| 80 | TCP | `app: mongo` pod only | MongoDB service |
| 8123 | TCP | `app: clickhouse` pod only | ClickHouse HTTP |

Without the `to:` destination restriction, allowed ports would be open to the public internet. Port 80 in particular would be a full HTTP egress channel. Restricting DNS to `kube-system` prevents DNS tunneling exfiltration.

Database drivers (`pymysql`, `pymongo`, `clickhouse-connect`) are pre-baked into the Docker image — no internet access is needed after the pod starts.

---

## Values Reference

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `""` | ACR image URL. Set to `<ACR_NAME>.azurecr.io/greenshift-jupyter`. |
| `image.tag` | `"v0.1.0"` | Image tag. Must match `appVersion` in `Chart.yaml`. Only updated when a new Docker image is built. |
| `token` | `"local-jupyter-token"` | Notebook access token. Used when `externalSecret.enabled=false`. |
| `ingress.host` | `""` | **Required.** Cluster domain, e.g. `application.test.greenshift.app`. |
| `ingress.className` | `"webapprouting.kubernetes.azure.com"` | Ingress class. Use `"nginx"` for local/OSS. |
| `ingress.path` | `"/jupyter"` | URL path prefix. Must not be changed (matches `ServerApp.base_url`). |
| `ingress.tls.enabled` | `true` | Enable HTTPS. Set `false` for local dev. |
| `ingress.tls.existingSecret` | `""` | Reuse an existing TLS Secret. Leave empty to let cert-manager create one. |
| `ingress.annotations` | `{}` | Add `cert-manager.io/cluster-issuer` here if creating a new cert. |
| `db.mariadb.host` | `"mariadb"` | MariaDB K8s service name. |
| `db.mariadb.port` | `3306` | MariaDB port. |
| `db.mariadb.user` | `"ro_user"` | Read-only user provisioned by the platform chart. |
| `db.mariadb.password` | `""` | Required when `externalSecret.enabled=false`. |
| `db.mongo.host` | `"mongo"` | MongoDB K8s service name. |
| `db.mongo.port` | `80` | MongoDB K8s service port (routes to 27017 internally). |
| `db.mongo.user` | `"ro_user"` | Read-only user. |
| `db.mongo.password` | `""` | Required when `externalSecret.enabled=false`. |
| `db.clickhouse.host` | `"clickhouse"` | ClickHouse K8s service name. |
| `db.clickhouse.port` | `8123` | ClickHouse HTTP interface port. Required by `clickhouse-connect`. |
| `db.clickhouse.user` | `"ro_user"` | Read-only user. |
| `db.clickhouse.password` | `""` | Required when `externalSecret.enabled=false`. |
| `externalSecret.enabled` | `false` | Pull token + passwords from Azure Key Vault instead of values. |
| `externalSecret.remoteKeyPrefix` | `""` | Key Vault key prefix. Must match the main chart's release name. |
| `persistence.enabled` | `true` | Mount a PVC at `/home/jovyan/work` so notebooks survive pod restarts. |
| `persistence.size` | `"5Gi"` | PVC size. |
| `networkPolicy.ingressController.enabled` | `true` | Restrict notebook access to ingress controller only. |

---

## Releases

`Chart.yaml` has two independent version fields:

- **`version`** — the Helm chart version. Bump this whenever any chart file changes (templates, values, helpers), even if the Docker image did not change.
- **`appVersion`** — the Docker image version. Only bump this when a new image is built and pushed to ACR. `values.yaml` `image.tag` must always match this.

| Artefact | Where | Tag format |
|----------|-------|------------|
| Helm chart | GitHub Releases + `gh-pages` `index.yaml` | `jupyter-<semver>` (e.g. `jupyter-0.2.0`) |
| Docker image | ACR | `v<semver>` (e.g. `v0.2.0`) + `sha-<git-sha>` |

**Releasing a chart-only change** (no Dockerfile changes):
1. Bump `version` in `Chart.yaml` (e.g. `0.1.5` → `0.1.6`)
2. Leave `appVersion` and `image.tag` unchanged
3. Push to `main` — `release.yml` packages the chart and publishes the GitHub Release

**Releasing a new Docker image** (Dockerfile or pip dependencies changed):
1. Bump `appVersion` in `Chart.yaml` (e.g. `v0.1.2` → `v0.1.3`)
2. Update `image.tag` in `values.yaml` to match (e.g. `v0.1.3`)
3. Bump `version` in `Chart.yaml` as well (the values file changed)
4. Push to `main` — `release.yml` packages the chart and publishes the GitHub Release
5. Create and push a git tag: `git tag v0.1.3 && git push origin v0.1.3`
6. `docker-publish.yml` triggers on the tag, builds the image, and pushes `v0.1.3` + `sha-<sha>` to ACR

The `sha-<sha>` tag is also produced on every push to `main` when `Dockerfile` changes, useful for pinning during development without waiting for a formal release.
