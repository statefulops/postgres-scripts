# Local testing on kind

Notes for bringing up a Postgresql cluster on a local [kind](https://kind.sigs.k8s.io/)
cluster with a Rustfs S3 bucket, then exercising backups.

## 1. Create the kind cluster

Creates the kind cluster plus a local RustFS S3 endpoint on `localhost:9000`.

```bash
curl -fsSL https://raw.githubusercontent.com/statefulops/kind-scripts/main/s3/create-cluster.sh | bash
```

## 2. Install the operator

Add the Percona Helm repo:

```bash
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo update
```

Safety check — only ever run this against a local kind cluster:

```bash
CURRENT_CONTEXT=$(kubectl config current-context)
case "$CURRENT_CONTEXT" in
  *kind*) echo "OK: using kind context '$CURRENT_CONTEXT'" ;;
  *) echo "ABORT: context '$CURRENT_CONTEXT' is not a kind cluster"; exit 1 ;;
esac
```


Install the operator and switch to its namespace:

```bash
kubectl create namespace pg-operator
helm install ps-operator percona/pg-operator --namespace pg-operator

kubectl config set-context --current --namespace=pg-operator
```

kubectl apply -f cr.yaml

## Connect to cluster

 PGBOUNCER_URI=$(kubectl get secret cluster1-pguser-cluster1  -o jsonpath='{.data.pgbouncer-uri}' | base64 --decode) 

 kubectl run -i --rm --tty pg-client --image=percona/percona-distribution-postgresql:18.6.1-1 --restart=Never -- psql $PGBOUNCER_URI

## Run a Backup

kubectl get secret rustfs-admin-credentials -n rustfs -o jsonpath='{.data.secret-key}' | base64 -d

cat <<EOF | base64
[global]
repo2-s3-key=myadminuser
repo2-s3-key-secret=UEtOuRuzQn6vTOcYwnZ28Cb9vjdVDISg
EOF

k apply -f backup_secret.yaml

or a one-liner

printf '[global]\nrepo2-s3-key=%s\nrepo2-s3-key-secret=%s\n' \
  "$(kubectl get secret rustfs-admin-credentials -n rustfs -o jsonpath='{.data.access-key}' | base64 -d)" \
  "$(kubectl get secret rustfs-admin-credentials -n rustfs -o jsonpath='{.data.secret-key}' | base64 -d)" \
| kubectl create secret generic cluster1-pgbackrest-secrets -n pg-operator \
    --from-file=s3.conf=/dev/stdin --dry-run=client -o yaml \
| kubectl apply -f -


## 4. Make rustfs usable as a pgBackRest S3 repo

Two things have to be true before `repo2` works, and neither is obvious from
the operator error message:

1. **pgBackRest always speaks TLS to an S3 endpoint.** There is no plaintext
   option — `repo-storage-verify-tls` only turns off *verification*, not TLS
   itself. A stock rustfs on `http://:9000` produces
   `TLS error [1:167772358] packet length too long`. The `http://` in a
   `repos[].s3.endpoint` is silently ignored; only the host and port are read.
2. **rustfs needs path-style addressing.** pgBackRest defaults to
   `uri-style=host`, i.e. `bucket.endpoint`, so it tries to resolve
   `my-kind-bucket.rustfs-svc.rustfs.svc.cluster.local` — which is NXDOMAIN,
   giving `unable to get address for ...: [-2] Name or service not known`.

Turn on TLS (mints a self-signed cert, mounts it, flips the probes to HTTPS):

```bash
./rustfs-enable-tls.sh
```

Then `cr-backup.yaml` carries the matching pgBackRest options:

```yaml
  backups:
    pgbackrest:
      global:
        repo2-s3-uri-style: path
        repo2-storage-verify-tls: "n"
      repos:
      - name: repo2
        s3:
          bucket: "my-kind-bucket"
          endpoint: "https://rustfs-svc.rustfs.svc.cluster.local:9000"
          region: "us-east-1"
```

Apply, then wait for the config hash to reach every pod — until it does the
operator logs `unable to create stanza: pgBackRest config hash mismatch`,
which is transient and clears itself:

```bash
kubectl apply -f cr-backup.yaml
kubectl exec cluster1-repo-host-0 -c pgbackrest -- pgbackrest --stanza=db --repo=2 info
```

Then run the backup:

```bash
kubectl apply -f backup.yaml
kubectl get perconapgbackup -w
```

To check a candidate option set without a reconcile cycle, override on the
command line inside the repo host:

```bash
kubectl exec cluster1-repo-host-0 -c pgbackrest -- pgbackrest --stanza=db --repo=2 \
  --repo2-s3-uri-style=path \
  --repo2-s3-endpoint=rustfs-svc.rustfs.svc.cluster.local:9000 \
  --no-repo2-storage-verify-tls info
```

## 5. Verify the backup in rustfs

```bash
export AWS_ACCESS_KEY_ID=myadminuser
export AWS_SECRET_ACCESS_KEY=$(kubectl get secret rustfs-admin-credentials -n rustfs -o jsonpath='{.data.secret-key}' | base64 -d)
export AWS_DEFAULT_REGION=us-east-1

aws --no-verify-ssl --endpoint-url https://localhost:9000 \
  s3 ls --recursive s3://my-kind-bucket/pgbackrest/repo2/backup/
```
