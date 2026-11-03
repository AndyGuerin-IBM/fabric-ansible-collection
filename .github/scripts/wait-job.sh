#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#
# Waits until a Job ends, and fails as soon as it fails. A plain
# `kubectl wait --for=jsonpath=...=Complete` returns only when the Job
# completes: on a failed Job it waits for the whole timeout.
#
#   wait-job.sh <job> [timeout in seconds, default 3600]
#
set -euo pipefail

JOB="$1"
TIMEOUT="${2:-3600}"
NAMESPACE="${K8S_NAMESPACE:-default}"

end=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "${end}" ]; do
    conditions=$(kubectl -n "${NAMESPACE}" get job "${JOB}" \
        -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}')
    case " ${conditions} " in
        *" Complete "*)
            echo "job/${JOB}: Complete"
            exit 0 ;;
        *" Failed "*)
            echo "job/${JOB}: Failed"
            kubectl -n "${NAMESPACE}" get job "${JOB}" -o jsonpath='{.status.conditions}{"\n"}'
            exit 1 ;;
    esac
    sleep 10
done
echo "job/${JOB}: still running after ${TIMEOUT}s" >&2
exit 1
