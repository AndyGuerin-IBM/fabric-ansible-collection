#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#
# Reachability assertions of the unexposed scenarios B and C (MIGRATION-STEP-1
# sub-task 1.10), for a network that is still alive. They run from the CI runner
# or a laptop: assertion 1 from there, the others from ephemeral pods. The first
# failing assertion stops the script.
#
# Input, from the environment or _cfg/console-env.sh:
#   API_KEY, API_SECRET           console credentials
#   CONSOLE_URL or API_ENDPOINT   exposed URL of the console
#   CONSOLE_NAME                  default hlf-console
#   NAMESPACE or K8S_NAMESPACE    default default
#   HLF_NETWORK_DOMAIN, CLUSTER_DOMAIN, EXPOSED_DOMAIN
#   NEUTRALIZE_NODE_INGRESSES     true: the node Ingresses must not be served
#   UNEXPOSED_INGRESS_CLASS       default none
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scenario-vars.sh
source "${SCRIPT_DIR}/scenario-vars.sh"
if [[ -f "${REPO_ROOT}/_cfg/console-env.sh" ]]; then
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/_cfg/console-env.sh"
fi

NS="${NAMESPACE:-${K8S_NAMESPACE:-default}}"
CONSOLE_NAME="${CONSOLE_NAME:-hlf-console}"
CONSOLE_URL="${CONSOLE_URL:-${API_ENDPOINT:-}}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
UNSERVED="${UNEXPOSED_INGRESS_CLASS:-none}"
NEUTRALIZED="$(scenario_bool NEUTRALIZE_NODE_INGRESSES "${NEUTRALIZE_NODE_INGRESSES:-false}")"
SEL=app.kubernetes.io/managed-by=fabric-ansible-collection
CURL_IMAGE=curlimages/curl:8.10.1
DNS_IMAGE=busybox:1.36.1

# hlf_node_domain: <ns>.svc.<cluster_domain> in scenario B, the HLF network domain otherwise
if [[ "${HLF_NETWORK_DOMAIN:-}" == "${CLUSTER_DOMAIN}" ]]; then
    DOMAIN="${NS}.svc.${CLUSTER_DOMAIN}"
else
    DOMAIN="${HLF_NETWORK_DOMAIN:-${EXPOSED_DOMAIN:-}}"
fi

# Endpoint of a component and the native port its Service must target (sub-task 1.6).
ENDPOINT_PORTS="ca/ca=7054 ca/operations=9443
peer/peer=7051 peer/operations=9443 peer/grpcweb=7443
orderer/orderer=7050 orderer/admin=9443 orderer/operations=8443 orderer/grpcweb=7443"

fail() {
    echo "FAILED: $*"
    exit 1
}

for required in API_KEY API_SECRET CONSOLE_URL DOMAIN; do
    [[ -n "${!required:-}" ]] || fail "${required} is not set"
done

assertion() {  # assertion <name> <function>
    printf '%s: ' "$1"
    "$2"
    echo OK
}

svcs_of() {  # svcs_of <endpoint type>: Service names, one per line
    kubectl get svc -n "${NS}" -l "${SEL},fabric-ansible-collection/endpoint=$1" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

incluster() {  # incluster <pod name> <image> <command...>: runs in an ephemeral pod
    local name="$1" image="$2"
    shift 2
    kubectl delete pod "${name}" -n "${NS}" --ignore-not-found --wait=true >/dev/null
    kubectl run "${name}" --image="${image}" --restart=Never --rm -i --quiet \
        --pod-running-timeout=3m --namespace "${NS}" --command -- "$@"
}

assert_ingresses_not_served() {
    local class code name host
    class=$(kubectl get ingress -n "${NS}" "${CONSOLE_NAME}" -o jsonpath='{.spec.ingressClassName}')
    [[ "${class}" == "${UNSERVED}" ]] \
        || fail "console Ingress class '${class}', expected '${UNSERVED}'"
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${CONSOLE_URL}/ak/api/v3/health") \
        || code="curl exit $?"
    [[ "${code}" == 404 ]] || fail "console still served by nginx (HTTP ${code})"

    for name in $(kubectl get ingress -n "${NS}" -o jsonpath='{.items[*].metadata.name}'); do
        [[ "${name}" != "${CONSOLE_NAME}" ]] || continue
        for host in $(kubectl get ingress -n "${NS}" "${name}" -o jsonpath='{.spec.rules[*].host}'); do
            [[ "${host}" == *".${DOMAIN}" ]] \
                || fail "Ingress ${name}: host ${host} is not under ${DOMAIN}"
        done
        if [[ "${NEUTRALIZED}" == true ]]; then
            class=$(kubectl get ingress -n "${NS}" "${name}" -o jsonpath='{.spec.ingressClassName}')
            [[ "${class}" == "${UNSERVED}" ]] \
                || fail "Ingress ${name}: class '${class}', expected '${UNSERVED}'"
        fi
    done
}

assert_console_service() {
    # The password goes through stdin (curl -K -), not in the spec of the pod.
    # Backslashes and quotes are escaped for the curl config syntax.
    local escaped
    escaped=$(printf '%s:%s' "${API_KEY}" "${API_SECRET}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf 'user = "%s"\n' "${escaped}" \
        | incluster curl-console "${CURL_IMAGE}" curl -sfk -o /dev/null --max-time 15 -K - \
            "https://${CONSOLE_NAME}.${NS}.svc.${CLUSTER_DOMAIN}:3000/ak/api/v3/health" \
        || fail "no answer from https://${CONSOLE_NAME}.${NS}.svc.${CLUSTER_DOMAIN}:3000: console pod, Service selector or credentials (401)"
}

assert_services() {
    local entry key component endpoint want names svc port addresses
    for entry in ${ENDPOINT_PORTS}; do
        key="${entry%=*}"
        want="${entry#*=}"
        component="${key%/*}"
        endpoint="${key#*/}"
        names=$(kubectl get svc -n "${NS}" \
            -l "${SEL},fabric-ansible-collection/component=${component},fabric-ansible-collection/endpoint=${endpoint}" \
            -o jsonpath='{.items[*].metadata.name}')
        [[ -n "${names}" ]] || fail "no ${component} '${endpoint}' Service found"
        for svc in ${names}; do
            port=$(kubectl get svc -n "${NS}" "${svc}" -o jsonpath='{.spec.ports[?(@.port==443)].targetPort}')
            [[ "${port}" == "${want}" ]] || fail "${svc}: 443 -> ${port}, expected ${want}"
            addresses=$(kubectl get endpoints -n "${NS}" "${svc}" -o jsonpath='{.subsets[*].addresses[*].ip}')
            [[ -n "${addresses}" ]] || fail "${svc} has no ready backend (selector assumption S3?)"
        done
    done
}

assert_healthz() {
    local urls
    urls=$(svcs_of operations | sed "s|.*|https://&.${DOMAIN}/healthz|")
    [[ -n "${urls}" ]] || fail "no operations Service found"
    # shellcheck disable=SC2086,SC2016
    incluster healthz "${CURL_IMAGE}" sh -c '
        for u in "$@"; do
            curl -sk --connect-timeout 5 --max-time 15 "$u" | grep -q "\"status\":\"OK\"" \
                || { echo "FAILED: $u"; exit 1; }
        done' sh ${urls} \
        || fail "an operations endpoint does not answer /healthz (rewrite, target port or node health)"
}

assert_tls() {
    local ca_urls tls_urls endpoint
    ca_urls=$(svcs_of ca | sed "s|.*|https://&.${DOMAIN}/cainfo|")
    tls_urls=$(for endpoint in peer orderer grpcweb admin; do svcs_of "${endpoint}"; done \
        | sed "s|.*|https://&.${DOMAIN}/|")
    [[ -n "${ca_urls}" && -n "${tls_urls}" ]] || fail "no CA, peer, orderer, grpcweb or admin Service found"
    # Exit 0, 35 (handshake alert: a client certificate is required) and 56 mean
    # TLS answered. 6, 7 and 28 (DNS, connection refused, timeout) fail.
    # shellcheck disable=SC2086,SC2016
    incluster tls-check "${CURL_IMAGE}" sh -c '
        ca_count="$1"; shift
        i=0
        for u in "$@"; do
            i=$((i + 1))
            if [ "$i" -le "$ca_count" ]; then
                curl -sk --connect-timeout 5 --max-time 15 "$u" | grep -q "\"CAName\"" \
                    || { echo "FAILED: $u"; exit 1; }
            else
                rc=0; curl -sk -o /dev/null --connect-timeout 5 --max-time 15 "$u" || rc=$?
                case "$rc" in 0|35|56) ;; *) echo "FAILED: $u (curl exit $rc)"; exit 1 ;; esac
            fi
        done' sh "$(echo "${ca_urls}" | wc -l | tr -d ' ')" ${ca_urls} ${tls_urls} \
        || fail "a CA, peer, orderer, grpcweb or admin endpoint does not answer TLS on 443"
}

assert_dns() {
    local pairs
    pairs=$(kubectl get svc -n "${NS}" -l "${SEL}" \
        -o jsonpath='{range .items[*]}{.metadata.name}={.spec.clusterIP}{" "}{end}')
    [[ -n "${pairs}" ]] || fail "no Service found with label ${SEL}"
    # shellcheck disable=SC2086,SC2016
    incluster dns-check "${DNS_IMAGE}" sh -c '
        domain="$1"; shift
        for p in "$@"; do
            fqdn="${p%%=*}.${domain}"; want="${p#*=}"
            got=$(nslookup "$fqdn" | awk "/^Address/ {a=\$2} END {print a}")
            [ "$got" = "$want" ] || { echo "FAILED: $fqdn -> $got, expected $want"; exit 1; }
        done' sh "${DOMAIN}" ${pairs} \
        || fail "an endpoint FQDN does not resolve to its own Service (CoreDNS rewrites in C, spec.deployer.domain in B)"
}

assertion "1. Unexposed Ingresses are not served by nginx" assert_ingresses_not_served
assertion "2. The console Service answers in the cluster" assert_console_service
assertion "3. One Service per endpoint, right port, ready backends" assert_services
assertion "4. Every operations endpoint answers /healthz on 443" assert_healthz
assertion "5. API, CA, grpcweb and admin endpoints answer TLS on 443" assert_tls
assertion "6. Every endpoint FQDN resolves to its own Service" assert_dns
