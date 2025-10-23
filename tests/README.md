# Testing Guide

## Quick Start

```bash
cd tests
docker compose up
```

## Running Tests

### Docker (Recommended)

```bash
cd tests

# Test all versions in parallel
docker compose up

# Test specific Slurm version
docker compose up slurm-23.11
docker compose up slurm-24.11
```

### Native BATS

```bash
cmake -B build
ctest --test-dir build --output-on-failure
```

### Manual BATS

```bash
cd tests/shell
bats test_wrapper.bats
```

## Test Coverage

21 BATS test cases in `tests/shell/test_wrapper.bats` covering:

- Container existence validation
- Command execution and argument passing
- Environment variables: `SLURM_SINGULARITY_BIND`, `SLURM_SINGULARITY_ARGS`, `SLURM_SINGULARITY_GLOBAL`, `SLURM_SINGULARITY_DEBUG`
- Error handling (missing files, invalid paths, special characters)
- Command construction (argument ordering, bind mount syntax, environment propagation)

## Continuous Integration

GitHub Actions tests on every push/PR with:
- Slurm 23.11 (Ubuntu 24.04 Noble)
- Slurm 24.11 (Ubuntu 25.04 Plucky)

## Writing Tests

Example test in `tests/shell/test_wrapper.bats`:

```bash
@test "description of test" {
    run env PATH="${TEST_TMP_DIR}:${PATH}" \
        SLURM_SINGULARITY_BIND="/custom:/mount" \
        "${WRAPPER_SCRIPT}" "${TEST_CONTAINER}" echo "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--bind=/custom:/mount"* ]]
}
```

Key patterns:
- Use `PATH="${TEST_TMP_DIR}:${PATH}"` for mock singularity
- Environment variables via `env`
- Test both success and failure cases
