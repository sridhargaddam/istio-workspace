#!/bin/bash

# Copyright 2019 Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script is used to run the integration tests on OpenShift.
# Usage: ./integ-suite-ocp.sh TEST_SUITE SKIP_TESTS, example: /prow/integ-suite-ocp.sh telemetry "TestClientTracing|TestServerTracing"
# TEST_SUITE: The test suite to run. Default is "pilot". Available options are "pilot", "security", "telemetry", "helm".
# TODO: Use the same arguments as integ-suite.kind.sh uses

#--------------------------------------------------------------------------------------------------------------------
# Source code of Original file: https://github.com/openshift-service-mesh/istio/blob/master/prow/integ-suite-ocp.sh
#--------------------------------------------------------------------------------------------------------------------

# Print commands
set -x

WD=$(dirname "$0")
ROOT=$(dirname "$WD")
WD=$(cd "$WD"; pwd)
TIMEOUT=300
export NAMESPACE="${NAMESPACE:-"istio-system"}"
export TAG="${TAG:-"istio-testing"}"
SKIP_TESTS="${2:-""}"
TEST_SUITE="${1:-"pilot"}"
# TEST_OUTPUT_FORMAT set the output format for the test result. Currently only supports: not set and junit
# If you are executing locally you will need to install before the go-junit-report package
TEST_OUTPUT_FORMAT="${TEST_OUTPUT_FORMAT:-"junit"}"

export OUTPUT_DIR="$PWD/integ-test-output_$(date +%Y%m%d_%H%M%S)"

# Check if artifact dir exist and if not create it in the current directory
ARTIFACTS_DIR="${ARTIFACT_DIR:-"${OUTPUT_DIR}"}"
mkdir -p "${ARTIFACTS_DIR}/junit"
JUNIT_REPORT_DIR="${ARTIFACTS_DIR}/junit"

# Exit immediately for non zero status
set -e
# Check unset variables
set -u
# Print commands
set -x

# Run the integration tests
echo "Running integration tests"

# Set up test command and parameters
setup_junit_report() {
    export ISTIO_BIN="${GOPATH}/bin"
    echo "ISTIO_BIN: ${ISTIO_BIN}"

    JUNIT_REPORT=$(which go-junit-report 2>/dev/null)
    if [ -z "$JUNIT_REPORT" ]; then
        JUNIT_REPORT="${ISTIO_BIN}/go-junit-report"
    fi
    echo "JUNIT_REPORT: ${JUNIT_REPORT}"
}

# Build the base command and store it in an array
base_cmd=("go" "test" "-p" "1" "-v" "-count=1" "-tags=integ" "-vet=off" "-timeout=60m" "./tests/integration/${TEST_SUITE}/..."
          "--istio.test.ci"
          "--istio.test.pullpolicy=IfNotPresent"
          "--istio.test.work_dir=${ARTIFACTS_DIR}"
          "--istio.test.skipTProxy=true"
          "--istio.test.skipVM=true"
          "--istio.test.enableDualStack=true"
          "--istio.test.kube.helm.values=profile=openshift,global.platform=openshift"
          "--istio.test.istio.enableCNI=true"
          "--istio.test.hub=${HUB}"
          "--istio.test.tag=${TAG}"
          "--istio.test.openshift")

# Append skip tests flag if SKIP_TESTS is set
if [ -n "${SKIP_TESTS}" ]; then
    base_cmd+=("-skip" "${SKIP_TESTS}")
fi

if [ "${TEST_OUTPUT_FORMAT}" == "junit" ]; then
    echo "Using junit"
else
    echo "Not using junit"
fi

# Execute the command and handle junit output
if [ "${TEST_OUTPUT_FORMAT}" == "junit" ]; then
    echo "A junit report file will be generated"
    setup_junit_report
    "${base_cmd[@]}" 2>&1 | tee >( "${JUNIT_REPORT}" > "${ARTIFACTS_DIR}/junit/junit.xml" )
    test_status=${PIPESTATUS[0]}
else
    "${base_cmd[@]}"
    test_status=$?
fi

# Exit with the status of the test command
exit $test_status
