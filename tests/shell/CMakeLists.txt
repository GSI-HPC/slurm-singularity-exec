# Shell script tests using BATS (Bash Automated Testing System)

# Find bats-core test framework
find_program(BATS_EXECUTABLE
    NAMES bats
    DOC "BATS (Bash Automated Testing System) executable"
)

if(BATS_EXECUTABLE)
    message(STATUS "Found BATS: ${BATS_EXECUTABLE}")

    # Configure test file to reference the source wrapper script
    configure_file(
        test_wrapper.bats
        ${CMAKE_CURRENT_BINARY_DIR}/test_wrapper.bats
        COPYONLY
    )

    # Add shell tests to CTest
    add_test(
        NAME shell_wrapper_tests
        COMMAND ${BATS_EXECUTABLE} --formatter tap test_wrapper.bats
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    )

    # Set environment variables for the test
    set_tests_properties(shell_wrapper_tests PROPERTIES
        ENVIRONMENT "WRAPPER_SCRIPT=${CMAKE_SOURCE_DIR}/slurm-singularity-wrapper.sh"
        TIMEOUT 60
    )

    # Create a custom target to run only shell tests
    add_custom_target(test_shell
        COMMAND ${CMAKE_CTEST_COMMAND} -R shell_wrapper_tests --output-on-failure
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        COMMENT "Running shell script tests"
        USES_TERMINAL
    )

else()
    message(WARNING "BATS not found. Shell tests will be skipped.")
    message(WARNING "Install BATS from: https://github.com/bats-core/bats-core")
    message(WARNING "  Ubuntu/Debian: sudo apt-get install bats")
    message(WARNING "  Fedora/RHEL: sudo dnf install bats")
endif()
