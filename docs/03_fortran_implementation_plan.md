# Fortran Durable Streams Client - Implementation Plan

## Executive Summary

This document outlines the plan for implementing a Durable Streams client in Modern Fortran (2018 standard), proving Fortran's relevance for modern AI infrastructure development.

## Technical Stack

### Fortran Standard
- **Target**: Fortran 2018 (ISO/IEC 1539-1:2018)
- **Compiler**: gfortran 10+ or ifort 2021+
- **Build System**: CMake 3.14+ with FetchContent

### Dependencies

#### 1. HTTP Client: libcurl via fortran-curl
- **Library**: fortran-curl (https://github.com/interkosmos/fortran-curl)
- **Provides**: ISO C binding interface to libcurl
- **Features**: GET, POST, PUT, DELETE, HEAD, custom headers, streaming

#### 2. JSON Parsing: json-fortran
- **Library**: json-fortran (https://github.com/jacobwilliams/json-fortran)
- **Provides**: Full JSON parsing and generation
- **Features**: Type-safe access, error handling, streaming support

#### 3. String Utilities: stdlib (fortran-lang)
- **Library**: fortran-stdlib
- **Provides**: String manipulation, base64 encoding

### Alternative Approach: iso_c_binding Direct
For maximum control, we could use direct C bindings:
- `curl_easy_*` for HTTP
- `jansson` or custom JSON parser

**Decision**: Use fortran-curl + json-fortran for faster development, proven reliability.

## Module Architecture

```
src/
├── durable_streams.f90           # Main public API module
├── ds_types.f90                  # Type definitions
├── ds_http.f90                   # HTTP client wrapper
├── ds_json.f90                   # JSON utilities
├── ds_sse.f90                    # Server-Sent Events parser
├── ds_error.f90                  # Error handling
├── ds_config.f90                 # Configuration and constants
└── adapter/
    └── ds_conformance_adapter.f90  # Conformance test adapter
```

## Type Definitions (ds_types.f90)

```fortran
module ds_types
    use, intrinsic :: iso_fortran_env, only: int32, int64, real64
    implicit none
    private

    ! Stream configuration
    type, public :: ds_config_t
        character(len=:), allocatable :: server_url
        character(len=:), allocatable :: content_type
        integer(int64) :: ttl_seconds = -1
        character(len=:), allocatable :: expires_at
    end type

    ! Stream metadata from HEAD
    type, public :: ds_metadata_t
        character(len=:), allocatable :: offset
        character(len=:), allocatable :: cursor
        character(len=:), allocatable :: content_type
        logical :: up_to_date = .false.
        integer :: status = 0
    end type

    ! Read chunk
    type, public :: ds_chunk_t
        character(len=:), allocatable :: offset
        character(len=:), allocatable :: data
    end type

    ! Read result
    type, public :: ds_read_result_t
        integer :: status = 0
        type(ds_chunk_t), allocatable :: chunks(:)
        logical :: up_to_date = .false.
        character(len=:), allocatable :: error_code
        character(len=:), allocatable :: message
    end type

    ! Append result
    type, public :: ds_append_result_t
        integer :: status = 0
        character(len=:), allocatable :: offset
        character(len=:), allocatable :: error_code
        character(len=:), allocatable :: message
    end type

    ! Create result
    type, public :: ds_create_result_t
        integer :: status = 0
        character(len=:), allocatable :: offset
        character(len=:), allocatable :: error_code
        character(len=:), allocatable :: message
    end type

    ! Error codes enumeration
    integer, parameter, public :: DS_ERR_NONE = 0
    integer, parameter, public :: DS_ERR_NETWORK = 1
    integer, parameter, public :: DS_ERR_TIMEOUT = 2
    integer, parameter, public :: DS_ERR_NOT_FOUND = 3
    integer, parameter, public :: DS_ERR_CONFLICT = 4
    integer, parameter, public :: DS_ERR_SEQUENCE = 5
    integer, parameter, public :: DS_ERR_INVALID_OFFSET = 6
    integer, parameter, public :: DS_ERR_PARSE = 7
    integer, parameter, public :: DS_ERR_INTERNAL = 8
    integer, parameter, public :: DS_ERR_NOT_SUPPORTED = 9

end module ds_types
```

## Main API (durable_streams.f90)

```fortran
module durable_streams
    use ds_types
    use ds_http
    use ds_json
    use ds_error
    implicit none
    private

    ! Public types
    public :: ds_config_t, ds_metadata_t, ds_chunk_t
    public :: ds_read_result_t, ds_append_result_t, ds_create_result_t

    ! Public procedures
    public :: ds_init, ds_shutdown
    public :: ds_create, ds_append, ds_read, ds_head, ds_delete

    ! Stream handle type
    type, public :: durable_stream_t
        private
        character(len=:), allocatable :: base_url
        character(len=:), allocatable :: path
        character(len=:), allocatable :: content_type
        type(ds_http_client_t) :: http
    contains
        procedure :: create => stream_create
        procedure :: append => stream_append
        procedure :: read => stream_read
        procedure :: head => stream_head
        procedure :: delete => stream_delete
    end type

contains

    ! Initialize the library
    subroutine ds_init(server_url, ierr)
        character(len=*), intent(in) :: server_url
        integer, intent(out) :: ierr
        ! Initialize libcurl, set up connection
    end subroutine

    ! Cleanup
    subroutine ds_shutdown()
        ! Cleanup libcurl handles
    end subroutine

    ! Create a new stream
    function ds_create(path, content_type, ttl_seconds, initial_data, headers) result(res)
        character(len=*), intent(in) :: path
        character(len=*), intent(in), optional :: content_type
        integer(int64), intent(in), optional :: ttl_seconds
        character(len=*), intent(in), optional :: initial_data
        type(ds_headers_t), intent(in), optional :: headers
        type(ds_create_result_t) :: res
    end function

    ! Append data to stream
    function ds_append(path, data, seq, headers) result(res)
        character(len=*), intent(in) :: path
        character(len=*), intent(in) :: data
        integer(int64), intent(in), optional :: seq
        type(ds_headers_t), intent(in), optional :: headers
        type(ds_append_result_t) :: res
    end function

    ! Read from stream
    function ds_read(path, offset, live, timeout_ms, headers) result(res)
        character(len=*), intent(in) :: path
        character(len=*), intent(in), optional :: offset
        character(len=*), intent(in), optional :: live  ! 'none', 'long-poll', 'sse'
        integer, intent(in), optional :: timeout_ms
        type(ds_headers_t), intent(in), optional :: headers
        type(ds_read_result_t) :: res
    end function

    ! Get stream metadata
    function ds_head(path, headers) result(res)
        character(len=*), intent(in) :: path
        type(ds_headers_t), intent(in), optional :: headers
        type(ds_metadata_t) :: res
    end function

    ! Delete stream
    function ds_delete(path, headers) result(status)
        character(len=*), intent(in) :: path
        type(ds_headers_t), intent(in), optional :: headers
        integer :: status
    end function

end module durable_streams
```

## HTTP Client Wrapper (ds_http.f90)

```fortran
module ds_http
    use curl
    use ds_types
    implicit none
    private

    type, public :: ds_http_client_t
        private
        type(c_ptr) :: curl_handle = c_null_ptr
        character(len=:), allocatable :: base_url
    contains
        procedure :: init => http_init
        procedure :: cleanup => http_cleanup
        procedure :: get => http_get
        procedure :: post => http_post
        procedure :: put => http_put
        procedure :: head => http_head
        procedure :: delete => http_delete
    end type

    type, public :: ds_http_response_t
        integer :: status = 0
        character(len=:), allocatable :: body
        type(ds_headers_t) :: headers
    end type

    type, public :: ds_headers_t
        character(len=256), allocatable :: keys(:)
        character(len=1024), allocatable :: values(:)
        integer :: count = 0
    contains
        procedure :: add => headers_add
        procedure :: get => headers_get
        procedure :: has => headers_has
    end type

contains
    ! Implementation using libcurl
end module ds_http
```

## Conformance Test Adapter

The adapter is a standalone executable that:
1. Reads JSON commands from stdin
2. Executes corresponding library functions
3. Writes JSON results to stdout

```fortran
program ds_conformance_adapter
    use durable_streams
    use ds_json
    use, intrinsic :: iso_fortran_env
    implicit none

    character(len=65536) :: line
    integer :: iostat

    ! Main loop: read commands from stdin
    do
        read(input_unit, '(A)', iostat=iostat) line
        if (iostat /= 0) exit

        call process_command(trim(line))
    end do

contains

    subroutine process_command(json_line)
        character(len=*), intent(in) :: json_line
        ! Parse JSON, dispatch to appropriate handler
    end subroutine

    subroutine handle_init(json)
        ! Initialize client, report capabilities
    end subroutine

    subroutine handle_create(json)
        ! Create stream, return result
    end subroutine

    subroutine handle_append(json)
        ! Append data, return result
    end subroutine

    subroutine handle_read(json)
        ! Read from stream, return chunks
    end subroutine

    subroutine handle_head(json)
        ! Get metadata, return result
    end subroutine

    subroutine handle_delete(json)
        ! Delete stream, return status
    end subroutine

    subroutine handle_shutdown()
        ! Clean shutdown
    end subroutine

end program
```

## Implementation Phases

### Phase 1: Foundation (Core Infrastructure)
1. Set up CMake build system with FetchContent
2. Integrate fortran-curl and json-fortran
3. Implement ds_http module (basic GET, POST, PUT, DELETE, HEAD)
4. Implement ds_json module (parse/generate)
5. Implement ds_types module
6. Write unit tests for HTTP and JSON modules

### Phase 2: Core Operations
1. Implement ds_create (PUT with headers)
2. Implement ds_append (POST with body)
3. Implement ds_head (HEAD, parse response headers)
4. Implement ds_delete (DELETE)
5. Implement ds_read (GET with offset)
6. Implement error handling and mapping

### Phase 3: Conformance Adapter
1. Create adapter executable structure
2. Implement JSON command parsing
3. Implement all command handlers
4. Implement JSON response generation
5. Test with manual commands

### Phase 4: Long-Polling Support
1. Implement timeout handling in HTTP client
2. Add live=long-poll query parameter
3. Handle 204 No Content responses
4. Parse Stream-Up-To-Date header
5. Test with conformance suite

### Phase 5: SSE Support (Optional but valuable)
1. Implement SSE line parser
2. Handle text/event-stream content type
3. Parse control and data events
4. Implement streaming read with callbacks
5. Test with conformance suite

### Phase 6: Advanced Features
1. Sequence number support
2. Custom headers pass-through
3. TTL and expiration handling
4. Binary data (base64) support
5. Unicode handling

### Phase 7: Polish and Documentation
1. Comprehensive error messages
2. API documentation
3. Usage examples
4. Performance optimization
5. README with Fortran advocacy

## Build System (CMakeLists.txt)

```cmake
cmake_minimum_required(VERSION 3.14)
project(fortran_durable_streams
    VERSION 1.0.0
    LANGUAGES Fortran C)

# Fortran settings
set(CMAKE_Fortran_MODULE_DIRECTORY ${CMAKE_BINARY_DIR}/modules)

# FetchContent for dependencies
include(FetchContent)

# fortran-curl
FetchContent_Declare(
    fortran_curl
    GIT_REPOSITORY https://github.com/interkosmos/fortran-curl
    GIT_TAG master
)

# json-fortran
FetchContent_Declare(
    json_fortran
    GIT_REPOSITORY https://github.com/jacobwilliams/json-fortran
    GIT_TAG master
)

FetchContent_MakeAvailable(fortran_curl json_fortran)

# Find system libcurl
find_package(CURL REQUIRED)

# Library
add_library(durable_streams
    src/ds_types.f90
    src/ds_config.f90
    src/ds_error.f90
    src/ds_json.f90
    src/ds_http.f90
    src/ds_sse.f90
    src/durable_streams.f90
)
target_link_libraries(durable_streams
    PRIVATE fortran_curl json_fortran CURL::libcurl)
target_include_directories(durable_streams
    PUBLIC ${CMAKE_BINARY_DIR}/modules)

# Conformance adapter
add_executable(ds_adapter
    src/adapter/ds_conformance_adapter.f90)
target_link_libraries(ds_adapter PRIVATE durable_streams)

# Tests
enable_testing()
add_subdirectory(tests)
```

## Risk Analysis

### Technical Risks

| Risk | Mitigation |
|------|------------|
| libcurl integration complexity | Use fortran-curl wrapper, proven stable |
| JSON parsing performance | json-fortran is well-optimized |
| Unicode handling | Fortran 2018 has good Unicode support |
| SSE streaming | Can implement as optional feature |
| Memory management | Use allocatable types, RAII patterns |

### Timeline Risks

| Risk | Mitigation |
|------|------------|
| Dependency build issues | Use FetchContent, fallback to vendoring |
| Conformance test failures | Implement core tests first, iterate |
| Platform compatibility | Target Linux first, add others later |

## Success Criteria

1. **All core conformance tests pass** (~45 tests)
2. **Long-poll tests pass** (5 tests)
3. **SSE tests pass** (10 tests) - stretch goal
4. **Clean, idiomatic Fortran code**
5. **Comprehensive documentation**
6. **Working examples**

## Fortran Advantages for This Project

1. **Performance**: Native compilation, no GC pauses
2. **Type Safety**: Strong static typing catches errors at compile time
3. **Array Operations**: Built-in array semantics for batch operations
4. **Interoperability**: ISO C binding for seamless library integration
5. **Stability**: Language standard ensures long-term maintainability
6. **Scientific Heritage**: Trusted for mission-critical applications

## Conclusion

This implementation plan demonstrates that Modern Fortran is fully capable of implementing modern web protocols and AI infrastructure primitives. By leveraging Fortran's strengths in performance, type safety, and interoperability, we will create a production-quality Durable Streams client that stands alongside implementations in TypeScript, Rust, Go, and other modern languages.

**Fortran is not just alive - it's evolving and ready for the AI age!**
