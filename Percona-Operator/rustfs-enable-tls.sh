#!/usr/bin/env bash
# Enable TLS on the local rustfs pod so pgBackRest can use it as an S3 repo.
#
# pgBackRest ALWAYS speaks TLS to an S3 endpoint -- there is no plaintext-HTTP
# option -- so a stock rustfs listening on http://:9000 can never be a repo.
# This mints a self-signed cert for the in-cluster service name and turns on
# RUSTFS_TLS_PATH. Pair it with these pgBackRest options in the cluster CR:
#
#   backups.pgbackrest.global:
#     repo2-s3-uri-style: path        # rustfs have no bucket.* vhost DNS
#     repo2-storage-verify-tls: "n"   # cert below is self-signed
#
set -euo pipefail

NS=rustfs
SVC=rustfs-svc

case "$(kubectl config current-context)" in
  *kind*) ;;
  *) echo "ABORT: context '$(kubectl config current-context)' is not a kind cluster" >&2; exit 1 ;;
esac

CLUSTER_IP=$(kubectl get svc "$SVC" -n "$NS" -o jsonpath='{.spec.clusterIP}')
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/san.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${SVC}.${NS}.svc.cluster.local
[v3]
subjectAltName = @alt
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
[alt]
DNS.1 = ${SVC}.${NS}.svc.cluster.local
DNS.2 = ${SVC}.${NS}.svc
DNS.3 = ${SVC}.${NS}
DNS.4 = ${SVC}
DNS.5 = localhost
IP.1 = 127.0.0.1
IP.2 = ${CLUSTER_IP}
EOF

# rustfs looks for exactly these filenames in RUSTFS_TLS_PATH.
# Verify with: rustfs tls inspect --path /tls
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/rustfs_key.pem" -out "$WORK/rustfs_cert.pem" \
  -config "$WORK/san.cnf" 2>/dev/null

kubectl create secret generic rustfs-tls -n "$NS" \
  --from-file=rustfs_cert.pem="$WORK/rustfs_cert.pem" \
  --from-file=rustfs_key.pem="$WORK/rustfs_key.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

# The stock chart probes /health over plain HTTP; flip both probes to HTTPS or
# the pod never goes ready once TLS is on.
kubectl patch deploy rustfs -n "$NS" --type=strategic -p '
spec:
  template:
    spec:
      volumes:
      - name: tls
        secret:
          secretName: rustfs-tls
      containers:
      - name: rustfs
        env:
        - name: RUSTFS_TLS_PATH
          value: /tls
        volumeMounts:
        - name: tls
          mountPath: /tls
          readOnly: true
        livenessProbe:
          httpGet: {path: /health, port: 9000, scheme: HTTPS}
        readinessProbe:
          httpGet: {path: /health, port: 9000, scheme: HTTPS}
'

kubectl rollout status deploy/rustfs -n "$NS" --timeout=180s
echo "rustfs now serving HTTPS on ${SVC}.${NS}.svc.cluster.local:9000"
