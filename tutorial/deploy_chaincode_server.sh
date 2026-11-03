#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#
# Runs the smart contract as a service (CCaaS), for peers that cannot build a
# chaincode themselves ("docker build is disabled"), and writes the CCaaS
# package (smart_contract_package) that the install playbooks use.
#
#   deploy_chaincode_server.sh deploy | destroy
#
# Needs docker, kubectl and yq. CCAAS_IMAGE sets the image (default: the local
# registry of the KIND cluster, localhost:5000).
#
# CCAAS_PACKAGE_ONLY=true: only write (deploy) or remove (destroy) the package.
# The server is deployed and destroyed by the caller, which has docker and the
# rights to create a Deployment: the CI runner, for the tests that run in an
# in-cluster Job without either (MIGRATION-STEP-1 sub-task 1.9).
#
set -e
cd "$(dirname "$0")"

function usage {
    echo "Usage: deploy_chaincode_server.sh [deploy|destroy]" 1>&2
    exit 1
}

NAMESPACE="${K8S_NAMESPACE:-$(yq -r '.k8s_namespace // "default"' org1-vars.yml)}"
NAME="$(yq -r .smart_contract_name common-vars.yml)"
VERSION="$(yq -r .smart_contract_version common-vars.yml)"
PACKAGE="$(yq -r .smart_contract_package common-vars.yml)"
SOURCE_PACKAGE="${SOURCE_PACKAGE:-${NAME}@${VERSION}.tgz}"
SERVER="$(echo "${NAME}-ccaas" | tr '[:upper:]_' '[:lower:]-')"
IMAGE="${CCAAS_IMAGE:-localhost:5000/${SERVER}:${VERSION}}"
PORT=9999
PACKAGE_ONLY="${CCAAS_PACKAGE_ONLY:-false}"

if [ "$1" = "deploy" ]; then
    set -x
    if [ "${PACKAGE_ONLY}" != "true" ]; then
        docker build -t "${IMAGE}" -f ccaas/Dockerfile --build-arg SOURCE_PACKAGE="${SOURCE_PACKAGE}" .
        docker push "${IMAGE}"
    fi

    # The package only holds the address of the server. Same label and address
    # give the same package, so the same package ID.
    PACKAGE_ID=$(python3 - "${NAME}_${VERSION}" "${SERVER}.${NAMESPACE}:${PORT}" "${PACKAGE}" <<'PY'
import gzip, hashlib, io, json, sys, tarfile
label, address, out = sys.argv[1:]
def targz(files):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in files:
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(data), 0o644, 0
            tar.addfile(info, io.BytesIO(data))
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as f:
        f.write(raw.getvalue())
    return gz.getvalue()
connection = json.dumps({"address": address, "dial_timeout": "10s", "tls_required": False}).encode()
metadata = json.dumps({"type": "ccaas", "label": label}).encode()
package = targz([("metadata.json", metadata), ("code.tar.gz", targz([("connection.json", connection)]))])
with open(out, "wb") as f:
    f.write(package)
print(f"{label}:{hashlib.sha256(package).hexdigest()}")
PY
)
    if [ "${PACKAGE_ONLY}" = "true" ]; then
        set +x
        exit 0
    fi

    kubectl -n "${NAMESPACE}" apply -f - <<MANIFEST
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVER}
  labels: {app: ${SERVER}}
spec:
  replicas: 1
  selector:
    matchLabels: {app: ${SERVER}}
  template:
    metadata:
      labels: {app: ${SERVER}}
    spec:
      containers:
        - name: chaincode
          image: ${IMAGE}
          imagePullPolicy: Always
          env:
            - {name: CHAINCODE_ID, value: "${PACKAGE_ID}"}
            - {name: CHAINCODE_SERVER_ADDRESS, value: "0.0.0.0:${PORT}"}
          ports:
            - containerPort: ${PORT}
---
apiVersion: v1
kind: Service
metadata:
  name: ${SERVER}
  labels: {app: ${SERVER}}
spec:
  selector: {app: ${SERVER}}
  ports:
    - port: ${PORT}
      targetPort: ${PORT}
MANIFEST
    kubectl -n "${NAMESPACE}" rollout status "deployment/${SERVER}" --timeout=300s
    set +x
elif [ "$1" = "destroy" ]; then
    set -x
    if [ "${PACKAGE_ONLY}" != "true" ]; then
        kubectl -n "${NAMESPACE}" delete deployment,service "${SERVER}" --ignore-not-found
    fi
    rm -f "${PACKAGE}"
    set +x
else
    usage
fi
