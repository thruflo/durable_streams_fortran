!> @file ds_http.f90
!> @brief HTTP client wrapper using libcurl
!>
!> This module provides HTTP client functionality for the Durable Streams
!> protocol, wrapping libcurl via iso_c_binding. It handles all HTTP methods
!> (GET, POST, PUT, DELETE, HEAD) with support for custom headers and
!> response parsing.
!>
!> @author Fortran Durable Streams Team
!> @date 2026

module ds_http
    use, intrinsic :: iso_c_binding
    use, intrinsic :: iso_fortran_env, only: int64
    use ds_types
    use ds_constants
    use ds_error
    implicit none
    private

    ! CURL constants
    integer(c_long), parameter :: CURLOPT_URL = 10002
    integer(c_long), parameter :: CURLOPT_WRITEFUNCTION = 20011
    integer(c_long), parameter :: CURLOPT_WRITEDATA = 10001
    integer(c_long), parameter :: CURLOPT_HEADERFUNCTION = 20079
    integer(c_long), parameter :: CURLOPT_HEADERDATA = 10029
    integer(c_long), parameter :: CURLOPT_POST = 47
    integer(c_long), parameter :: CURLOPT_POSTFIELDS = 10015
    integer(c_long), parameter :: CURLOPT_POSTFIELDSIZE = 60
    integer(c_long), parameter :: CURLOPT_HTTPHEADER = 10023
    integer(c_long), parameter :: CURLOPT_CUSTOMREQUEST = 10036
    integer(c_long), parameter :: CURLOPT_NOBODY = 44
    integer(c_long), parameter :: CURLOPT_TIMEOUT_MS = 155
    integer(c_long), parameter :: CURLOPT_FOLLOWLOCATION = 52

    integer(c_long), parameter :: CURLINFO_RESPONSE_CODE = 2097154

    integer(c_int), parameter :: CURLE_OK = 0

    ! C interfaces
    interface
        function curl_easy_init() bind(c, name='curl_easy_init')
            import :: c_ptr
            type(c_ptr) :: curl_easy_init
        end function

        subroutine curl_easy_cleanup(handle) bind(c, name='curl_easy_cleanup')
            import :: c_ptr
            type(c_ptr), value :: handle
        end subroutine

        function curl_easy_setopt_long(handle, option, param) bind(c, name='curl_easy_setopt')
            import :: c_ptr, c_long, c_int
            type(c_ptr), value :: handle
            integer(c_long), value :: option
            integer(c_long), value :: param
            integer(c_int) :: curl_easy_setopt_long
        end function

        function curl_easy_setopt_ptr(handle, option, param) bind(c, name='curl_easy_setopt')
            import :: c_ptr, c_long, c_int
            type(c_ptr), value :: handle
            integer(c_long), value :: option
            type(c_ptr), value :: param
            integer(c_int) :: curl_easy_setopt_ptr
        end function

        function curl_easy_setopt_funptr(handle, option, param) bind(c, name='curl_easy_setopt')
            import :: c_ptr, c_long, c_int, c_funptr
            type(c_ptr), value :: handle
            integer(c_long), value :: option
            type(c_funptr), value :: param
            integer(c_int) :: curl_easy_setopt_funptr
        end function

        function curl_easy_perform(handle) bind(c, name='curl_easy_perform')
            import :: c_ptr, c_int
            type(c_ptr), value :: handle
            integer(c_int) :: curl_easy_perform
        end function

        function curl_easy_getinfo_long(handle, info, param) bind(c, name='curl_easy_getinfo')
            import :: c_ptr, c_long, c_int
            type(c_ptr), value :: handle
            integer(c_long), value :: info
            integer(c_long) :: param
            integer(c_int) :: curl_easy_getinfo_long
        end function

        function curl_slist_append(list, string) bind(c, name='curl_slist_append')
            import :: c_ptr, c_char
            type(c_ptr), value :: list
            character(kind=c_char), dimension(*), intent(in) :: string
            type(c_ptr) :: curl_slist_append
        end function

        subroutine curl_slist_free_all(list) bind(c, name='curl_slist_free_all')
            import :: c_ptr
            type(c_ptr), value :: list
        end subroutine

        function curl_global_init(flags) bind(c, name='curl_global_init')
            import :: c_long, c_int
            integer(c_long), value :: flags
            integer(c_int) :: curl_global_init
        end function

        subroutine curl_global_cleanup() bind(c, name='curl_global_cleanup')
        end subroutine
    end interface

    ! Response buffer type for callback
    type :: response_buffer_t
        character(len=:), allocatable :: data
        integer :: length = 0
    end type

    ! Header buffer type for callback
    type :: header_buffer_t
        type(ds_headers_t) :: headers
    end type

    ! Module state
    type(c_ptr), save :: curl_handle = c_null_ptr
    logical, save :: curl_initialized = .false.
    type(response_buffer_t), target, save :: response_buffer
    type(header_buffer_t), target, save :: header_buffer

    public :: http_init
    public :: http_cleanup
    public :: http_get
    public :: http_post
    public :: http_put
    public :: http_delete
    public :: http_head

    !> HTTP response type
    type, public :: http_response_t
        integer :: status = 0
        character(len=:), allocatable :: body
        type(ds_headers_t) :: headers
    end type http_response_t

contains

    !> @brief Initialize HTTP client
    subroutine http_init(ierr)
        integer, intent(out) :: ierr
        integer(c_int) :: rc

        ierr = 0

        if (curl_initialized) return

        rc = curl_global_init(3_c_long)  ! CURL_GLOBAL_ALL
        if (rc /= CURLE_OK) then
            ierr = 1
            return
        end if

        curl_initialized = .true.
    end subroutine http_init

    !> @brief Cleanup HTTP client
    subroutine http_cleanup()
        if (curl_initialized) then
            call curl_global_cleanup()
            curl_initialized = .false.
        end if
    end subroutine http_cleanup

    !> @brief Write callback for response body
    function write_callback(ptr, size, nmemb, userdata) bind(c)
        type(c_ptr), value :: ptr
        integer(c_size_t), value :: size, nmemb
        type(c_ptr), value :: userdata
        integer(c_size_t) :: write_callback

        character(len=:), allocatable :: new_data
        character(len=1), pointer :: c_array(:)
        integer :: total_size, i

        total_size = int(size * nmemb)
        write_callback = int(total_size, c_size_t)

        if (total_size == 0) return

        ! Get pointer to C data
        call c_f_pointer(ptr, c_array, [total_size])

        ! Append to response buffer
        allocate(character(len=total_size) :: new_data)
        do i = 1, total_size
            new_data(i:i) = c_array(i)
        end do

        if (allocated(response_buffer%data)) then
            response_buffer%data = response_buffer%data // new_data
        else
            response_buffer%data = new_data
        end if
        response_buffer%length = response_buffer%length + total_size
    end function write_callback

    !> @brief Header callback for response headers
    function header_callback(ptr, size, nmemb, userdata) bind(c)
        type(c_ptr), value :: ptr
        integer(c_size_t), value :: size, nmemb
        type(c_ptr), value :: userdata
        integer(c_size_t) :: header_callback

        character(len=:), allocatable :: header_line
        character(len=1), pointer :: c_array(:)
        integer :: total_size, i, colon_pos
        character(len=:), allocatable :: key, value

        total_size = int(size * nmemb)
        header_callback = int(total_size, c_size_t)

        if (total_size == 0) return

        ! Get pointer to C data
        call c_f_pointer(ptr, c_array, [total_size])

        ! Build header line
        allocate(character(len=total_size) :: header_line)
        do i = 1, total_size
            header_line(i:i) = c_array(i)
        end do

        ! Parse "Key: Value" format
        colon_pos = index(header_line, ':')
        if (colon_pos > 1) then
            key = trim(header_line(1:colon_pos-1))
            value = trim(adjustl(header_line(colon_pos+1:)))
            ! Remove trailing CR/LF
            i = len_trim(value)
            do while (i > 0 .and. (value(i:i) == char(13) .or. value(i:i) == char(10)))
                i = i - 1
            end do
            if (i > 0) then
                value = value(1:i)
                call header_buffer%headers%add(key, value)
            end if
        end if
    end function header_callback

    !> @brief Prepare curl handle for request
    function prepare_curl(url, timeout_ms) result(handle)
        character(len=*), intent(in) :: url
        integer, intent(in), optional :: timeout_ms
        type(c_ptr) :: handle
        integer(c_int) :: rc
        character(len=:), allocatable, target :: url_c
        integer :: actual_timeout

        actual_timeout = DEFAULT_TIMEOUT_MS
        if (present(timeout_ms)) actual_timeout = timeout_ms

        ! Reset buffers
        if (allocated(response_buffer%data)) deallocate(response_buffer%data)
        response_buffer%length = 0
        call header_buffer%headers%clear()

        ! Create handle
        handle = curl_easy_init()
        if (.not. c_associated(handle)) return

        ! Set URL
        url_c = url // c_null_char
        rc = curl_easy_setopt_ptr(handle, CURLOPT_URL, c_loc(url_c))

        ! Set callbacks
        rc = curl_easy_setopt_funptr(handle, CURLOPT_WRITEFUNCTION, &
            c_funloc(write_callback))
        rc = curl_easy_setopt_funptr(handle, CURLOPT_HEADERFUNCTION, &
            c_funloc(header_callback))

        ! Set timeout
        rc = curl_easy_setopt_long(handle, CURLOPT_TIMEOUT_MS, &
            int(actual_timeout, c_long))

        ! Follow redirects
        rc = curl_easy_setopt_long(handle, CURLOPT_FOLLOWLOCATION, 1_c_long)
    end function prepare_curl

    !> @brief Set custom headers on curl handle
    subroutine set_headers(handle, headers, slist)
        type(c_ptr), intent(in) :: handle
        type(ds_headers_t), intent(in) :: headers
        type(c_ptr), intent(out) :: slist

        character(len=:), allocatable :: header_str
        integer :: i, rc

        slist = c_null_ptr

        if (headers%count == 0) return

        do i = 1, headers%count
            header_str = trim(headers%items(i)%key) // ": " // &
                trim(headers%items(i)%value) // c_null_char
            slist = curl_slist_append(slist, header_str)
        end do

        rc = curl_easy_setopt_ptr(handle, CURLOPT_HTTPHEADER, slist)
    end subroutine set_headers

    !> @brief Execute request and get response
    subroutine execute_request(handle, response, slist)
        type(c_ptr), intent(in) :: handle
        type(http_response_t), intent(out) :: response
        type(c_ptr), intent(inout) :: slist

        integer(c_int) :: rc
        integer(c_long) :: status_code

        rc = curl_easy_perform(handle)

        if (rc == CURLE_OK) then
            rc = curl_easy_getinfo_long(handle, CURLINFO_RESPONSE_CODE, status_code)
            response%status = int(status_code)
            if (allocated(response_buffer%data)) then
                response%body = response_buffer%data
            else
                response%body = ""
            end if
            response%headers = header_buffer%headers
        else
            response%status = 0  ! Network error
            response%body = ""
        end if

        ! Cleanup
        if (c_associated(slist)) call curl_slist_free_all(slist)
        call curl_easy_cleanup(handle)
    end subroutine execute_request

    !> @brief Perform HTTP GET request
    function http_get(url, headers, timeout_ms) result(response)
        character(len=*), intent(in) :: url
        type(ds_headers_t), intent(in), optional :: headers
        integer, intent(in), optional :: timeout_ms
        type(http_response_t) :: response

        type(c_ptr) :: handle, slist
        type(ds_headers_t) :: empty_headers

        handle = prepare_curl(url, timeout_ms)
        if (.not. c_associated(handle)) then
            response%status = 0
            return
        end if

        if (present(headers)) then
            call set_headers(handle, headers, slist)
        else
            call set_headers(handle, empty_headers, slist)
        end if

        call execute_request(handle, response, slist)
    end function http_get

    !> @brief Perform HTTP POST request
    function http_post(url, body, headers, timeout_ms) result(response)
        character(len=*), intent(in) :: url
        character(len=*), intent(in) :: body
        type(ds_headers_t), intent(in), optional :: headers
        integer, intent(in), optional :: timeout_ms
        type(http_response_t) :: response

        type(c_ptr) :: handle, slist
        type(ds_headers_t) :: empty_headers
        character(len=:), allocatable, target :: body_c
        integer(c_int) :: rc

        handle = prepare_curl(url, timeout_ms)
        if (.not. c_associated(handle)) then
            response%status = 0
            return
        end if

        ! Set POST method
        rc = curl_easy_setopt_long(handle, CURLOPT_POST, 1_c_long)

        ! Set body
        body_c = body // c_null_char
        rc = curl_easy_setopt_ptr(handle, CURLOPT_POSTFIELDS, c_loc(body_c))
        rc = curl_easy_setopt_long(handle, CURLOPT_POSTFIELDSIZE, &
            int(len(body), c_long))

        if (present(headers)) then
            call set_headers(handle, headers, slist)
        else
            call set_headers(handle, empty_headers, slist)
        end if

        call execute_request(handle, response, slist)
    end function http_post

    !> @brief Perform HTTP PUT request
    function http_put(url, body, headers, timeout_ms) result(response)
        character(len=*), intent(in) :: url
        character(len=*), intent(in), optional :: body
        type(ds_headers_t), intent(in), optional :: headers
        integer, intent(in), optional :: timeout_ms
        type(http_response_t) :: response

        type(c_ptr) :: handle, slist
        type(ds_headers_t) :: empty_headers
        character(len=4), target :: method_c
        character(len=:), allocatable, target :: body_c
        integer(c_int) :: rc

        handle = prepare_curl(url, timeout_ms)
        if (.not. c_associated(handle)) then
            response%status = 0
            return
        end if

        ! Set PUT method
        method_c = 'PUT' // c_null_char
        rc = curl_easy_setopt_ptr(handle, CURLOPT_CUSTOMREQUEST, c_loc(method_c))

        ! Set body if provided
        if (present(body)) then
            body_c = body // c_null_char
            rc = curl_easy_setopt_ptr(handle, CURLOPT_POSTFIELDS, c_loc(body_c))
            rc = curl_easy_setopt_long(handle, CURLOPT_POSTFIELDSIZE, &
                int(len(body), c_long))
        end if

        if (present(headers)) then
            call set_headers(handle, headers, slist)
        else
            call set_headers(handle, empty_headers, slist)
        end if

        call execute_request(handle, response, slist)
    end function http_put

    !> @brief Perform HTTP DELETE request
    function http_delete(url, headers, timeout_ms) result(response)
        character(len=*), intent(in) :: url
        type(ds_headers_t), intent(in), optional :: headers
        integer, intent(in), optional :: timeout_ms
        type(http_response_t) :: response

        type(c_ptr) :: handle, slist
        type(ds_headers_t) :: empty_headers
        character(len=7), target :: method_c
        integer(c_int) :: rc

        handle = prepare_curl(url, timeout_ms)
        if (.not. c_associated(handle)) then
            response%status = 0
            return
        end if

        ! Set DELETE method
        method_c = 'DELETE' // c_null_char
        rc = curl_easy_setopt_ptr(handle, CURLOPT_CUSTOMREQUEST, c_loc(method_c))

        if (present(headers)) then
            call set_headers(handle, headers, slist)
        else
            call set_headers(handle, empty_headers, slist)
        end if

        call execute_request(handle, response, slist)
    end function http_delete

    !> @brief Perform HTTP HEAD request
    function http_head(url, headers, timeout_ms) result(response)
        character(len=*), intent(in) :: url
        type(ds_headers_t), intent(in), optional :: headers
        integer, intent(in), optional :: timeout_ms
        type(http_response_t) :: response

        type(c_ptr) :: handle, slist
        type(ds_headers_t) :: empty_headers
        integer(c_int) :: rc

        handle = prepare_curl(url, timeout_ms)
        if (.not. c_associated(handle)) then
            response%status = 0
            return
        end if

        ! Set HEAD (no body)
        rc = curl_easy_setopt_long(handle, CURLOPT_NOBODY, 1_c_long)

        if (present(headers)) then
            call set_headers(handle, headers, slist)
        else
            call set_headers(handle, empty_headers, slist)
        end if

        call execute_request(handle, response, slist)
    end function http_head

end module ds_http
