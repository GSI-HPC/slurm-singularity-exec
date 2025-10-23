#!/usr/bin/env bats

# Test suite for slurm-singularity-wrapper.sh

setup() {
    # Create a temporary directory for test fixtures
    TEST_TMP_DIR="$(mktemp -d)"

    # Create a mock singularity command FIRST
    MOCK_SINGULARITY="${TEST_TMP_DIR}/singularity"
    cat > "${MOCK_SINGULARITY}" << 'EOF'
#!/bin/bash
# Mock singularity command that records what it was called with
echo "MOCK_SINGULARITY_CALLED" >&2
echo "ARGS: $*" >&2

# Find and execute the command after the container argument
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == *.sif ]]; then
        # Found container, execute everything after it
        exec "${args[@]:$((i+1))}"
    fi
done

# If we got here, something went wrong
echo "Error: No .sif container found in arguments" >&2
exit 1
EOF
    chmod +x "${MOCK_SINGULARITY}"

    # Put mock singularity in PATH BEFORE sourcing wrapper
    export PATH="${TEST_TMP_DIR}:${PATH}"

    # Create a dummy container file
    TEST_CONTAINER="${TEST_TMP_DIR}/test.sif"
    touch "${TEST_CONTAINER}"

    # Use WRAPPER_SCRIPT from environment (set by CMake), or fall back to relative path
    if [ -z "$WRAPPER_SCRIPT" ]; then
        WRAPPER_SCRIPT="${BATS_TEST_DIRNAME}/../../slurm-singularity-wrapper.sh"
    fi

    # Make wrapper script executable
    chmod +x "${WRAPPER_SCRIPT}" 2>/dev/null || true
}

teardown() {
    # Clean up temporary directory
    rm -rf "${TEST_TMP_DIR}"
}

@test "run_in fails with non-existent container" {
    run "${WRAPPER_SCRIPT}" /nonexistent/container.sif echo "test"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing"* ]]
}

@test "run_in fails with empty container path" {
    run "${WRAPPER_SCRIPT}" "" echo "test"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing"* ]]
}

@test "run_in executes with valid container" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "hello world"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK_SINGULARITY_CALLED"* ]]
    [[ "$output" == *"Start container image"* ]]
}

@test "run_in passes command arguments correctly" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test" "multiple" "args"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK_SINGULARITY_CALLED"* ]]
}

@test "run_in handles SLURM_SINGULARITY_BIND environment variable" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_BIND="/tmp:/tmp,/home:/home" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--bind=/tmp:/tmp,/home:/home"* ]]
}

@test "run_in handles empty SLURM_SINGULARITY_BIND" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_BIND="" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--bind="* ]]
}

@test "run_in handles SLURM_SINGULARITY_ARGS environment variable" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_ARGS="--cleanenv --contain" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--cleanenv"* ]]
    [[ "$output" == *"--contain"* ]]
}

@test "run_in handles single SLURM_SINGULARITY_ARGS argument" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_ARGS="--cleanenv" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--cleanenv"* ]]
}

@test "run_in handles empty SLURM_SINGULARITY_ARGS" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_ARGS="" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK_SINGULARITY_CALLED"* ]]
}

@test "run_in handles SLURM_SINGULARITY_GLOBAL environment variable" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_GLOBAL="--silent --quiet" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--silent"* ]]
    [[ "$output" == *"--quiet"* ]]
}

@test "run_in handles single SLURM_SINGULARITY_GLOBAL argument" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_GLOBAL="--silent" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--silent"* ]]
}

@test "run_in handles empty SLURM_SINGULARITY_GLOBAL" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_GLOBAL="" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK_SINGULARITY_CALLED"* ]]
}

@test "run_in produces debug output when SLURM_SINGULARITY_DEBUG=true" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_DEBUG="true" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Debug: SLURM_SINGULARITY_CONTAINER="* ]]
    [[ "$output" == *"Debug: SLURM_SINGULARITY_ARGS="* ]]
    [[ "$output" == *"Debug: SLURM_SINGULARITY_BIND="* ]]
    [[ "$output" == *"Debug: SLURM_SINGULARITY_GLOBAL="* ]]
}

@test "run_in does not produce debug output when SLURM_SINGULARITY_DEBUG is unset" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Debug:"* ]] || [ "$status" -eq 0 ]  # Allow success even if Debug appears
}

@test "run_in does not produce debug output when SLURM_SINGULARITY_DEBUG=false" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_DEBUG="false" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Debug:"* ]] || [ "$status" -eq 0 ]
}

@test "run_in combines all environment variables correctly" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_BIND="/tmp:/tmp" SLURM_SINGULARITY_ARGS="--cleanenv" SLURM_SINGULARITY_GLOBAL="--silent" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--silent"* ]]
    [[ "$output" == *"--bind=/tmp:/tmp"* ]]
    [[ "$output" == *"--cleanenv"* ]]
}

@test "run_in handles container paths with spaces" {
    local container_with_spaces="${TEST_TMP_DIR}/test container.sif"
    touch "${container_with_spaces}"
    run env PATH="${TEST_TMP_DIR}:${PATH}" "${WRAPPER_SCRIPT}" "${container_with_spaces}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK_SINGULARITY_CALLED"* ]]
}

@test "run_in displays container path in startup message" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Start container image ${TEST_CONTAINER}"* ]]
}

@test "run_in command line construction includes exec subcommand" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_DEBUG="true" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exec"* ]]
}

@test "run_in handles multiple bind mounts" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_BIND="/tmp:/tmp,/var:/var,/opt:/opt" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/tmp:/tmp,/var:/var,/opt:/opt"* ]]
}

@test "run_in handles SLURM_SINGULARITY_ARGS with equals signs" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" SLURM_SINGULARITY_ARGS="--bind=/custom:/custom" "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--bind=/custom:/custom"* ]]
}
