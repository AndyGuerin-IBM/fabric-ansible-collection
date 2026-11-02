#
# SPDX-License-Identifier: Apache-2.0
#
# Runner of the tutorial tests inside the KIND cluster (MIGRATION-STEP-1
# sub-task 1.9): the collection image plus the test-only tools and files.
# Built in CI from the repository root:
#   docker build -t fabric-ansible-collection:ci .
#   docker build -t ansible-runner:ci -f .github/docker/ansible-runner/Dockerfile .
ARG BASE_IMAGE=fabric-ansible-collection:ci
FROM ${BASE_IMAGE}
# Test-only tools: jq, shasum (TEST_RUN_ID stamping), pip for yq.
USER root
RUN microdnf install -y jq perl-Digest-SHA python3-pip && microdnf clean -y all
USER 7051
# Python yq (run-tests.sh uses `yq -yi`, which mikefarah's yq does not support).
# cryptography as in requirements.txt: the base image installs the latest one,
# and fabric-sdk-py then fails to enroll ("curve must be an EllipticCurve
# instance").
RUN python3.9 -m pip install --user yq 'cryptography==42.0.8'
# Writable copy of the tests: run-tests.sh does `cd tutorial` relative to the repo root.
COPY --chown=7051:0 .github/scripts /workspace/.github/scripts
COPY --chown=7051:0 tutorial /workspace/tutorial
USER root
RUN chmod -R g=u /workspace
USER 7051
WORKDIR /workspace
ENTRYPOINT [ "/docker-entrypoint.sh" ]
CMD [ ".github/scripts/run-tests.sh" ]
