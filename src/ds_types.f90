!> @file ds_types.f90
!> @brief Type definitions for Durable Streams client
!>
!> This module defines all the derived types used throughout the Fortran
!> Durable Streams client. Types are designed with Fortran 2018 features
!> including allocatable components and type-bound procedures.
!>
!> @author Fortran Durable Streams Team
!> @date 2026

module ds_types
    use, intrinsic :: iso_fortran_env, only: int32, int64, real64
    use ds_constants
    implicit none
    private

    !---------------------------------------------------------------------------
    ! HTTP Header Storage
    !---------------------------------------------------------------------------

    !> @brief Single HTTP header key-value pair
    type, public :: ds_header_t
        character(len=:), allocatable :: key
        character(len=:), allocatable :: value
    end type ds_header_t

    !> @brief Collection of HTTP headers
    type, public :: ds_headers_t
        type(ds_header_t), allocatable :: items(:)
        integer :: count = 0
    contains
        procedure :: add => headers_add
        procedure :: get => headers_get
        procedure :: has => headers_has
        procedure :: clear => headers_clear
        procedure :: to_curl_list => headers_to_curl_list
    end type ds_headers_t

    !---------------------------------------------------------------------------
    ! Stream Configuration
    !---------------------------------------------------------------------------

    !> @brief Configuration for creating a new stream
    type, public :: ds_create_config_t
        character(len=:), allocatable :: content_type   !< MIME type (default: application/json)
        integer(int64) :: ttl_seconds = -1              !< TTL in seconds (-1 = no expiry)
        character(len=:), allocatable :: expires_at     !< RFC 3339 expiration timestamp
        character(len=:), allocatable :: initial_data   !< Optional initial data
        type(ds_headers_t) :: headers                   !< Custom headers
    end type ds_create_config_t

    !> @brief Configuration for append operation
    type, public :: ds_append_config_t
        integer(int64) :: seq = -1                      !< Sequence number (-1 = not set)
        type(ds_headers_t) :: headers                   !< Custom headers
    end type ds_append_config_t

    !> @brief Configuration for read operation
    type, public :: ds_read_config_t
        character(len=:), allocatable :: offset         !< Starting offset ("-1" = beginning)
        character(len=:), allocatable :: live           !< Live mode: "none", "long-poll", "sse"
        integer :: timeout_ms = DEFAULT_LONGPOLL_TIMEOUT_MS  !< Timeout for long-poll
        character(len=:), allocatable :: cursor         !< Optional cursor for CDN
        type(ds_headers_t) :: headers                   !< Custom headers
    end type ds_read_config_t

    !---------------------------------------------------------------------------
    ! Result Types
    !---------------------------------------------------------------------------

    !> @brief Single data chunk from a read operation
    type, public :: ds_chunk_t
        character(len=:), allocatable :: offset         !< Offset of this chunk
        character(len=:), allocatable :: data           !< The data content
    contains
        procedure :: is_valid => chunk_is_valid
    end type ds_chunk_t

    !> @brief Result from stream creation
    type, public :: ds_create_result_t
        logical :: success = .false.
        integer :: status = 0                           !< HTTP status code
        character(len=:), allocatable :: offset         !< Initial offset
        character(len=:), allocatable :: error_code     !< Error code if failed
        character(len=:), allocatable :: message        !< Error message if failed
    end type ds_create_result_t

    !> @brief Result from append operation
    type, public :: ds_append_result_t
        logical :: success = .false.
        integer :: status = 0                           !< HTTP status code
        character(len=:), allocatable :: offset         !< New offset after append
        character(len=:), allocatable :: error_code     !< Error code if failed
        character(len=:), allocatable :: message        !< Error message if failed
    end type ds_append_result_t

    !> @brief Result from read operation
    type, public :: ds_read_result_t
        logical :: success = .false.
        integer :: status = 0                           !< HTTP status code
        type(ds_chunk_t), allocatable :: chunks(:)      !< Data chunks
        integer :: chunk_count = 0                      !< Number of chunks
        character(len=:), allocatable :: next_offset    !< Next offset to read from
        logical :: up_to_date = .false.                 !< True if caught up
        character(len=:), allocatable :: cursor         !< Cursor for next request
        character(len=:), allocatable :: error_code     !< Error code if failed
        character(len=:), allocatable :: message        !< Error message if failed
    contains
        procedure :: add_chunk => read_result_add_chunk
    end type ds_read_result_t

    !> @brief Result from HEAD operation (stream metadata)
    type, public :: ds_head_result_t
        logical :: success = .false.
        integer :: status = 0                           !< HTTP status code
        character(len=:), allocatable :: offset         !< Current stream offset
        character(len=:), allocatable :: content_type   !< Stream content type
        character(len=:), allocatable :: cursor         !< Current cursor
        logical :: up_to_date = .false.                 !< Always true for HEAD
        character(len=:), allocatable :: error_code     !< Error code if failed
        character(len=:), allocatable :: message        !< Error message if failed
    end type ds_head_result_t

    !> @brief Result from DELETE operation
    type, public :: ds_delete_result_t
        logical :: success = .false.
        integer :: status = 0                           !< HTTP status code
        character(len=:), allocatable :: error_code     !< Error code if failed
        character(len=:), allocatable :: message        !< Error message if failed
    end type ds_delete_result_t

    !---------------------------------------------------------------------------
    ! Client State
    !---------------------------------------------------------------------------

    !> @brief Client capabilities reported to conformance tests
    type, public :: ds_capabilities_t
        logical :: sse = .true.                         !< SSE support
        logical :: longpoll = .true.                    !< Long-poll support
        logical :: batching = .false.                   !< Write batching
        logical :: retry = .true.                       !< Automatic retry
        logical :: dynamic_headers = .false.            !< Dynamic header support
    end type ds_capabilities_t

    !> @brief Main client state
    type, public :: ds_client_t
        character(len=:), allocatable :: server_url     !< Base server URL
        logical :: initialized = .false.                !< Initialization state
        type(ds_capabilities_t) :: capabilities         !< Client capabilities
        type(ds_headers_t) :: default_headers           !< Default headers for all requests
    contains
        procedure :: init => client_init
        procedure :: shutdown => client_shutdown
        procedure :: is_ready => client_is_ready
    end type ds_client_t

    ! Public interface
    public :: headers_add, headers_get, headers_has, headers_clear
    public :: client_init, client_shutdown, client_is_ready

contains

    !---------------------------------------------------------------------------
    ! Header Methods
    !---------------------------------------------------------------------------

    !> @brief Add a header to the collection
    subroutine headers_add(this, key, value)
        class(ds_headers_t), intent(inout) :: this
        character(len=*), intent(in) :: key, value
        type(ds_header_t), allocatable :: temp(:)
        integer :: n

        if (.not. allocated(this%items)) then
            allocate(this%items(10))
            this%count = 0
        end if

        ! Expand array if needed
        if (this%count >= size(this%items)) then
            n = size(this%items)
            allocate(temp(n * 2))
            temp(1:n) = this%items
            call move_alloc(temp, this%items)
        end if

        this%count = this%count + 1
        this%items(this%count)%key = key
        this%items(this%count)%value = value
    end subroutine headers_add

    !> @brief Get header value by key
    function headers_get(this, key) result(value)
        class(ds_headers_t), intent(in) :: this
        character(len=*), intent(in) :: key
        character(len=:), allocatable :: value
        integer :: i

        value = ""
        if (.not. allocated(this%items)) return

        do i = 1, this%count
            if (this%items(i)%key == key) then
                value = this%items(i)%value
                return
            end if
        end do
    end function headers_get

    !> @brief Check if header exists
    function headers_has(this, key) result(found)
        class(ds_headers_t), intent(in) :: this
        character(len=*), intent(in) :: key
        logical :: found
        integer :: i

        found = .false.
        if (.not. allocated(this%items)) return

        do i = 1, this%count
            if (this%items(i)%key == key) then
                found = .true.
                return
            end if
        end do
    end function headers_has

    !> @brief Clear all headers
    subroutine headers_clear(this)
        class(ds_headers_t), intent(inout) :: this
        if (allocated(this%items)) deallocate(this%items)
        this%count = 0
    end subroutine headers_clear

    !> @brief Convert headers to curl-compatible format (key: value strings)
    function headers_to_curl_list(this) result(list)
        class(ds_headers_t), intent(in) :: this
        character(len=:), allocatable :: list(:)
        integer :: i

        if (this%count == 0 .or. .not. allocated(this%items)) then
            allocate(character(len=1) :: list(0))
            return
        end if

        allocate(character(len=MAX_HEADER_SIZE) :: list(this%count))
        do i = 1, this%count
            list(i) = trim(this%items(i)%key) // ": " // trim(this%items(i)%value)
        end do
    end function headers_to_curl_list

    !---------------------------------------------------------------------------
    ! Chunk Methods
    !---------------------------------------------------------------------------

    !> @brief Check if chunk has valid data
    function chunk_is_valid(this) result(valid)
        class(ds_chunk_t), intent(in) :: this
        logical :: valid
        valid = allocated(this%offset) .and. allocated(this%data)
    end function chunk_is_valid

    !---------------------------------------------------------------------------
    ! Read Result Methods
    !---------------------------------------------------------------------------

    !> @brief Add a chunk to read result
    subroutine read_result_add_chunk(this, offset, data)
        class(ds_read_result_t), intent(inout) :: this
        character(len=*), intent(in) :: offset, data
        type(ds_chunk_t), allocatable :: temp(:)
        integer :: n

        if (.not. allocated(this%chunks)) then
            allocate(this%chunks(10))
            this%chunk_count = 0
        end if

        ! Expand array if needed
        if (this%chunk_count >= size(this%chunks)) then
            n = size(this%chunks)
            allocate(temp(n * 2))
            temp(1:n) = this%chunks
            call move_alloc(temp, this%chunks)
        end if

        this%chunk_count = this%chunk_count + 1
        this%chunks(this%chunk_count)%offset = offset
        this%chunks(this%chunk_count)%data = data
    end subroutine read_result_add_chunk

    !---------------------------------------------------------------------------
    ! Client Methods
    !---------------------------------------------------------------------------

    !> @brief Initialize the client
    subroutine client_init(this, server_url, ierr)
        class(ds_client_t), intent(inout) :: this
        character(len=*), intent(in) :: server_url
        integer, intent(out) :: ierr

        ierr = 0

        if (len_trim(server_url) == 0) then
            ierr = 1
            return
        end if

        this%server_url = trim(server_url)
        this%initialized = .true.

        ! Set default capabilities
        this%capabilities%sse = .true.
        this%capabilities%longpoll = .true.
        this%capabilities%batching = .false.
        this%capabilities%retry = .true.
        this%capabilities%dynamic_headers = .false.
    end subroutine client_init

    !> @brief Shutdown the client
    subroutine client_shutdown(this)
        class(ds_client_t), intent(inout) :: this
        if (allocated(this%server_url)) deallocate(this%server_url)
        call this%default_headers%clear()
        this%initialized = .false.
    end subroutine client_shutdown

    !> @brief Check if client is ready
    function client_is_ready(this) result(ready)
        class(ds_client_t), intent(in) :: this
        logical :: ready
        ready = this%initialized
    end function client_is_ready

end module ds_types
