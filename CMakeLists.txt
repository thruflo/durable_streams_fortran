cmake_minimum_required(VERSION 3.14)
project(fortran_durable_streams
    VERSION 1.0.0
    DESCRIPTION "Durable Streams Client for Modern Fortran"
    LANGUAGES Fortran C)

# Set Fortran standard
set(CMAKE_Fortran_MODULE_DIRECTORY ${CMAKE_BINARY_DIR}/modules)
set(CMAKE_Fortran_FLAGS "${CMAKE_Fortran_FLAGS} -std=f2018 -Wall -Wextra")
set(CMAKE_Fortran_FLAGS_DEBUG "${CMAKE_Fortran_FLAGS_DEBUG} -g -fcheck=all")
set(CMAKE_Fortran_FLAGS_RELEASE "${CMAKE_Fortran_FLAGS_RELEASE} -O3")

# Find required packages
find_package(CURL REQUIRED)

# Include FetchContent for dependencies
include(FetchContent)

# Option to use system json-fortran if available
option(USE_SYSTEM_JSON_FORTRAN "Use system-installed json-fortran" OFF)

if(NOT USE_SYSTEM_JSON_FORTRAN)
    FetchContent_Declare(
        json_fortran
        GIT_REPOSITORY https://github.com/jacobwilliams/json-fortran
        GIT_TAG 8.5.2
    )
    FetchContent_MakeAvailable(json_fortran)
endif()

# Main library
add_library(durable_streams
    src/ds_constants.f90
    src/ds_types.f90
    src/ds_error.f90
    src/ds_base64.f90
    src/ds_json_utils.f90
    src/ds_http.f90
    src/ds_sse.f90
    src/durable_streams.f90
)

target_include_directories(durable_streams
    PUBLIC
        ${CMAKE_BINARY_DIR}/modules
        ${CURL_INCLUDE_DIRS}
)

target_link_libraries(durable_streams
    PUBLIC
        ${CURL_LIBRARIES}
        jsonfortran::jsonfortran
)

# Conformance test adapter executable
add_executable(ds_adapter
    src/adapter/ds_conformance_adapter.f90
)
target_link_libraries(ds_adapter PRIVATE durable_streams)

# Example programs
add_executable(example_basic examples/basic_usage.f90)
target_link_libraries(example_basic PRIVATE durable_streams)

add_executable(example_streaming examples/streaming_read.f90)
target_link_libraries(example_streaming PRIVATE durable_streams)

# Install targets
install(TARGETS durable_streams ds_adapter
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)

install(DIRECTORY ${CMAKE_BINARY_DIR}/modules/
    DESTINATION include/fortran_durable_streams
    FILES_MATCHING PATTERN "*.mod"
)

# Testing
enable_testing()

# Add simple unit test
add_executable(test_base64 tests/test_base64.f90)
target_link_libraries(test_base64 PRIVATE durable_streams)
add_test(NAME base64_test COMMAND test_base64)

add_executable(test_json tests/test_json.f90)
target_link_libraries(test_json PRIVATE durable_streams)
add_test(NAME json_test COMMAND test_json)

# CPack for packaging
set(CPACK_PACKAGE_NAME "fortran-durable-streams")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Durable Streams Client for Modern Fortran")
include(CPack)
