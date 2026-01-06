!> @file durable_streams.f90
!> @brief Main Durable Streams client module
!>
!> This is the primary public API for the Fortran Durable Streams client.
!> It provides high-level operations for interacting with Durable Streams
!> servers, including stream creation, data appending, reading, and deletion.
!>
!> Example usage:
!> @code
!>   use durable_streams
!>   type(ds_client_t) :: client
!>   type(ds_create_result_t) :: create_res
!>   type(ds_append_result_t) :: append_res
!>   type(ds_read_result_t) :: read_res
!>   integer :: ierr
!>
!>   call ds_initialize("http://localhost:4437", ierr)
!>   create_res = ds_create("/my-stream", "text/plain")
!>   append_res = ds_append("/my-stream", "Hello, World!")
!>   read_res = ds_read("/my-stream")
!>   call ds_finalize()
!> @endcode
!>
!> @author Fortran Durable Streams Team
!> @date 2026

module durable_streams
    use ds_types
    use ds_constants
    use ds_error
    use ds_http
    use ds_sse
    use ds_base64
    use ds_json_utils
    use, intrinsic :: iso_fortran_env, only: int64
    implicit none
    private

    ! Public types
    public :: ds_client_t
    public :: ds_capabilities_t
    public :: ds_headers_t
    public :: ds_create_config_t
    public :: ds_append_config_t
    public :: ds_read_config_t
    public :: ds_create_result_t
    public :: ds_append_result_t
    public :: ds_read_result_t
    public :: ds_head_result_t
    public :: ds_delete_result_t
    public :: ds_chunk_t

    ! Public procedures
    public :: ds_initialize
    public :: ds_finalize
    public :: ds_create
    public :: ds_append
    public :: ds_read
    public :: ds_head
    public :: ds_delete
    public :: ds_get_capabilities

    ! Public constants
    public :: OFFSET_BEGINNING
    public :: LIVE_NONE, LIVE_LONG_POLL, LIVE_SSE
    public :: CT_JSON, CT_TEXT, CT_BINARY

    ! Module-level client state
    type(ds_client_t), save :: global_client

contains

    !---------------------------------------------------------------------------
    ! Initialization
    !---------------------------------------------------------------------------

    !> @brief Initialize the Durable Streams client
    !>
    !> Must be called before any other operations. Initializes the HTTP
    !> client and sets up the server URL.
    !>
    !> @param server_url Base URL of the Durable Streams server
    !> @param ierr Error code (0 = success)
    subroutine ds_initialize(server_url, ierr)
        character(len=*), intent(in) :: server_url
        integer, intent(out) :: ierr

        ! Initialize HTTP client
        call http_init(ierr)
        if (ierr /= 0) return

        ! Initialize client state
        call global_client%init(server_url, ierr)
    end subroutine ds_initialize

    !> @brief Finalize and cleanup the client
    !>
    !> Should be called when done using the client to release resources.
    subroutine ds_finalize()
        call global_client%shutdown()
        call http_cleanup()
    end subroutine ds_finalize

    !> @brief Get client capabilities
    !>
    !> Returns the feature flags that this client supports.
    !>
    !> @return Capabilities structure
    function ds_get_capabilities() result(caps)
        type(ds_capabilities_t) :: caps
        caps = global_client%capabilities
    end function ds_get_capabilities

    !---------------------------------------------------------------------------
    ! Stream Operations
    !---------------------------------------------------------------------------

    !> @brief Create a new stream
    !>
    !> Creates a new stream at the specified path. The operation is idempotent -
    !> creating an existing stream with matching configuration returns success.
    !>
    !> @param path Stream path (e.g., "/my-stream")
    !> @param content_type Optional MIME type (default: application/json)
    !> @param ttl_seconds Optional time-to-live in seconds
    !> @param initial_data Optional initial data to write
    !> @param headers Optional custom headers
    !> @return Result containing status and offset
    function ds_create(path, content_type, ttl_seconds, initial_data, headers) result(res)
        character(len=*), intent(in) :: path
        character(len=*), intent(in), optional :: content_type
        integer(int64), intent(in), optional :: ttl_seconds
        character(len=*), intent(in), optional :: initial_data
        type(ds_headers_t), intent(in), optional :: headers
        type(ds_create_result_t) :: res

        character(len=:), allocatable :: url, ct, body
        type(ds_headers_t) :: req_headers
        type(http_response_t) :: http_res
        character(len=20) :: ttl_str

        ! Build URL
        url = trim(global_client%server_url) // trim(path)

        ! Set content type
        if (present(content_type)) then
            ct = content_type
        else
            ct = CT_JSON
        end if
        call req_headers%add(HDR_CONTENT_TYPE, ct)

        ! Set TTL if provided
        if (present(ttl_seconds)) then
            if (ttl_seconds > 0) then
                write(ttl_str, '(I0)') ttl_seconds
                call req_headers%add(HDR_STREAM_TTL, trim(ttl_str))
            end if
        end if

        ! Add custom headers
        if (present(headers)) then
            call merge_headers(req_headers, headers)
        end if

        ! Set body
        if (present(initial_data)) then
            body = initial_data
        else
            body = ""
        end if

        ! Make PUT request
        http_res = http_put(url, body, req_headers)

        ! Process response
        res%status = http_res%status
        if (is_success_status(http_res%status)) then
            res%success = .true.
            res%offset = http_res%headers%get(HDR_STREAM_NEXT_OFFSET)
            if (.not. allocated(res%offset) .or. len_trim(res%offset) == 0) then
                res%offset = OFFSET_BEGINNING
            end if
        else
            res%success = .false.
            res%error_code = http_status_to_error_code(http_res%status)
            res%message = format_error_message(http_res%status, res%error_code)
        end if
    end function ds_create

    !> @brief Append data to a stream
    !>
    !> Appends data to an existing stream. The data is added to the end
    !> of the stream and assigned a new offset.
    !>
    !> @param path Stream path
    !> @param data Data to append
    !> @param seq Optional sequence number for ordering
    !> @param headers Optional custom headers
    !> @return Result containing status and new offset
    function ds_append(path, data, seq, headers) result(res)
        character(len=*), intent(in) :: path
        character(len=*), intent(in) :: data
        integer(int64), intent(in), optional :: seq
        type(ds_headers_t), intent(in), optional :: headers
        type(ds_append_result_t) :: res

        character(len=:), allocatable :: url
        type(ds_headers_t) :: req_headers
        type(http_response_t) :: http_res
        character(len=20) :: seq_str

        ! Check for empty data
        if (len(data) == 0) then
            res%success = .false.
            res%status = HTTP_BAD_REQUEST
            res%error_code = ERR_CODE_BAD_REQUEST
            res%message = "Cannot append empty data"
            return
        end if

        ! Build URL
        url = trim(global_client%server_url) // trim(path)

        ! Set content type (match stream's type - assume JSON for now)
        call req_headers%add(HDR_CONTENT_TYPE, CT_JSON)

        ! Set sequence number if provided
        if (present(seq)) then
            if (seq >= 0) then
                write(seq_str, '(I0)') seq
                call req_headers%add(HDR_STREAM_SEQ, trim(seq_str))
            end if
        end if

        ! Add custom headers
        if (present(headers)) then
            call merge_headers(req_headers, headers)
        end if

        ! Make POST request
        http_res = http_post(url, data, req_headers)

        ! Process response
        res%status = http_res%status
        if (is_success_status(http_res%status)) then
            res%success = .true.
            res%offset = http_res%headers%get(HDR_STREAM_NEXT_OFFSET)
            if (.not. allocated(res%offset)) res%offset = ""
        else
            res%success = .false.
            res%error_code = http_status_to_error_code(http_res%status)
            ! Check for sequence conflict
            if (http_res%status == HTTP_CONFLICT) then
                res%error_code = ERR_CODE_SEQUENCE
            end if
            res%message = format_error_message(http_res%status, res%error_code)
        end if
    end function ds_append

    !> @brief Read from a stream
    !>
    !> Reads data from a stream starting at the specified offset. Supports
    !> various live modes for real-time streaming.
    !>
    !> @param path Stream path
    !> @param offset Starting offset ("-1" for beginning)
    !> @param live Live mode: "none", "long-poll", or "sse"
    !> @param timeout_ms Timeout for long-poll in milliseconds
    !> @param headers Optional custom headers
    !> @return Result containing chunks and metadata
    function ds_read(path, offset, live, timeout_ms, headers) result(res)
        character(len=*), intent(in) :: path
        character(len=*), intent(in), optional :: offset
        character(len=*), intent(in), optional :: live
        integer, intent(in), optional :: timeout_ms
        type(ds_headers_t), intent(in), optional :: headers
        type(ds_read_result_t) :: res

        character(len=:), allocatable :: url, live_mode, start_offset
        type(ds_headers_t) :: req_headers
        type(http_response_t) :: http_res
        integer :: actual_timeout
        character(len=:), allocatable :: content_type

        ! Set defaults
        if (present(offset)) then
            start_offset = offset
        else
            start_offset = OFFSET_BEGINNING
        end if

        if (present(live)) then
            live_mode = live
        else
            live_mode = LIVE_NONE
        end if

        if (present(timeout_ms)) then
            actual_timeout = timeout_ms
        else
            actual_timeout = DEFAULT_LONGPOLL_TIMEOUT_MS
        end if

        ! Build URL with query parameters
        url = trim(global_client%server_url) // trim(path) // &
            "?" // PARAM_OFFSET // "=" // trim(start_offset)

        if (live_mode /= LIVE_NONE) then
            url = url // "&" // PARAM_LIVE // "=" // trim(live_mode)
        end if

        ! Add custom headers
        if (present(headers)) then
            call merge_headers(req_headers, headers)
        end if

        ! Make GET request
        http_res = http_get(url, req_headers, actual_timeout)

        ! Process response
        res%status = http_res%status

        if (is_success_status(http_res%status)) then
            res%success = .true.

            ! Get metadata from headers
            res%next_offset = http_res%headers%get(HDR_STREAM_NEXT_OFFSET)
            res%cursor = http_res%headers%get(HDR_STREAM_CURSOR)

            ! Check up-to-date header
            if (http_res%headers%get(HDR_STREAM_UP_TO_DATE) == "true") then
                res%up_to_date = .true.
            else
                res%up_to_date = .false.
            end if

            ! Parse response based on content type
            content_type = http_res%headers%get(HDR_CONTENT_TYPE)

            if (index(content_type, CT_EVENT_STREAM) > 0) then
                ! SSE response - parse events
                call parse_sse_response(http_res%body, res)
            else if (index(content_type, CT_JSON) > 0) then
                ! JSON response - parse array
                call parse_json_response(http_res%body, res)
            else
                ! Plain text or binary - single chunk
                if (len(http_res%body) > 0) then
                    call res%add_chunk(start_offset, http_res%body)
                end if
            end if

        else if (http_res%status == HTTP_NO_CONTENT) then
            ! Long-poll timeout - no new data
            res%success = .true.
            res%up_to_date = .true.
            res%next_offset = http_res%headers%get(HDR_STREAM_NEXT_OFFSET)
            res%cursor = http_res%headers%get(HDR_STREAM_CURSOR)
            allocate(res%chunks(0))
            res%chunk_count = 0

        else
            res%success = .false.
            res%error_code = http_status_to_error_code(http_res%status)
            res%message = format_error_message(http_res%status, res%error_code)
        end if
    end function ds_read

    !> @brief Get stream metadata
    !>
    !> Retrieves metadata about a stream without reading any data.
    !>
    !> @param path Stream path
    !> @param headers Optional custom headers
    !> @return Result containing offset and content type
    function ds_head(path, headers) result(res)
        character(len=*), intent(in) :: path
        type(ds_headers_t), intent(in), optional :: headers
        type(ds_head_result_t) :: res

        character(len=:), allocatable :: url
        type(ds_headers_t) :: req_headers
        type(http_response_t) :: http_res

        ! Build URL
        url = trim(global_client%server_url) // trim(path)

        ! Add custom headers
        if (present(headers)) then
            call merge_headers(req_headers, headers)
        end if

        ! Make HEAD request
        http_res = http_head(url, req_headers)

        ! Process response
        res%status = http_res%status

        if (is_success_status(http_res%status)) then
            res%success = .true.
            res%offset = http_res%headers%get(HDR_STREAM_NEXT_OFFSET)
            res%content_type = http_res%headers%get(HDR_CONTENT_TYPE)
            res%cursor = http_res%headers%get(HDR_STREAM_CURSOR)
            res%up_to_date = .true.

            if (.not. allocated(res%offset) .or. len_trim(res%offset) == 0) then
                res%offset = OFFSET_BEGINNING
            end if
        else
            res%success = .false.
            res%error_code = http_status_to_error_code(http_res%status)
            res%message = format_error_message(http_res%status, res%error_code)
        end if
    end function ds_head

    !> @brief Delete a stream
    !>
    !> Permanently deletes a stream and all its data.
    !>
    !> @param path Stream path
    !> @param headers Optional custom headers
    !> @return Result containing status
    function ds_delete(path, headers) result(res)
        character(len=*), intent(in) :: path
        type(ds_headers_t), intent(in), optional :: headers
        type(ds_delete_result_t) :: res

        character(len=:), allocatable :: url
        type(ds_headers_t) :: req_headers
        type(http_response_t) :: http_res

        ! Build URL
        url = trim(global_client%server_url) // trim(path)

        ! Add custom headers
        if (present(headers)) then
            call merge_headers(req_headers, headers)
        end if

        ! Make DELETE request
        http_res = http_delete(url, req_headers)

        ! Process response
        res%status = http_res%status

        if (is_success_status(http_res%status)) then
            res%success = .true.
        else
            res%success = .false.
            res%error_code = http_status_to_error_code(http_res%status)
            res%message = format_error_message(http_res%status, res%error_code)
        end if
    end function ds_delete

    !---------------------------------------------------------------------------
    ! Helper Procedures
    !---------------------------------------------------------------------------

    !> @brief Merge custom headers into request headers
    subroutine merge_headers(dest, src)
        type(ds_headers_t), intent(inout) :: dest
        type(ds_headers_t), intent(in) :: src
        integer :: i

        if (.not. allocated(src%items)) return

        do i = 1, src%count
            call dest%add(src%items(i)%key, src%items(i)%value)
        end do
    end subroutine merge_headers

    !> @brief Parse SSE response into chunks
    subroutine parse_sse_response(body, res)
        character(len=*), intent(in) :: body
        type(ds_read_result_t), intent(inout) :: res

        type(sse_event_t), allocatable :: events(:)
        integer :: event_count, i

        call sse_parse_events(body, events, event_count)

        do i = 1, event_count
            select case (events(i)%event_type)
                case (SSE_EVENT_DATA)
                    ! Add data chunk
                    if (allocated(events(i)%data)) then
                        call res%add_chunk(res%next_offset, events(i)%data)
                    end if

                case (SSE_EVENT_CONTROL)
                    ! Update metadata
                    if (allocated(events(i)%offset)) then
                        res%next_offset = events(i)%offset
                    end if
                    if (allocated(events(i)%cursor)) then
                        res%cursor = events(i)%cursor
                    end if
                    res%up_to_date = events(i)%up_to_date
            end select
        end do
    end subroutine parse_sse_response

    !> @brief Parse JSON array response into chunks
    subroutine parse_json_response(body, res)
        use json_module
        character(len=*), intent(in) :: body
        type(ds_read_result_t), intent(inout) :: res

        type(json_file) :: json
        type(json_core) :: jc
        type(json_value), pointer :: p, array, elem
        integer :: i, n
        character(len=:), allocatable :: item_str
        logical :: found

        if (len_trim(body) == 0) return

        call json%initialize()
        call json%deserialize(body)

        if (json%failed()) then
            ! Not JSON array, treat as single chunk
            call res%add_chunk(res%next_offset, body)
            call json%destroy()
            return
        end if

        ! Check if it's an array
        call json%get(p)
        call jc%initialize()
        call jc%info(p, n_children=n)

        if (n > 0) then
            ! Parse array elements
            do i = 1, n
                call jc%get_child(p, i, elem, found)
                if (found) then
                    call jc%serialize(elem, item_str)
                    call res%add_chunk(res%next_offset, item_str)
                end if
            end do
        else if (len_trim(body) > 2) then
            ! Single item, not an array
            call res%add_chunk(res%next_offset, body)
        end if

        call json%destroy()
    end subroutine parse_json_response

end module durable_streams
