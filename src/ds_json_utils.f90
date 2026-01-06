!> @file ds_json_utils.f90
!> @brief JSON utilities for Durable Streams
!>
!> This module provides JSON parsing and generation utilities using the
!> json-fortran library. It handles serialization/deserialization of
!> protocol messages and conformance test adapter communication.
!>
!> @author Fortran Durable Streams Team
!> @date 2026

module ds_json_utils
    use json_module
    use ds_types
    use ds_constants
    implicit none
    private

    public :: json_parse_command
    public :: json_build_response
    public :: json_build_init_response
    public :: json_build_create_response
    public :: json_build_append_response
    public :: json_build_read_response
    public :: json_build_head_response
    public :: json_build_delete_response
    public :: json_build_error_response
    public :: json_escape_string
    public :: json_get_string
    public :: json_get_integer
    public :: json_get_boolean

    !> Command type enumeration
    integer, parameter, public :: CMD_UNKNOWN = 0
    integer, parameter, public :: CMD_INIT = 1
    integer, parameter, public :: CMD_CREATE = 2
    integer, parameter, public :: CMD_APPEND = 3
    integer, parameter, public :: CMD_READ = 4
    integer, parameter, public :: CMD_HEAD = 5
    integer, parameter, public :: CMD_DELETE = 6
    integer, parameter, public :: CMD_SHUTDOWN = 7

    !> Parsed command structure
    type, public :: ds_command_t
        integer :: cmd_type = CMD_UNKNOWN
        character(len=:), allocatable :: server_url        !< For init
        character(len=:), allocatable :: path              !< Stream path
        character(len=:), allocatable :: content_type      !< Content type
        character(len=:), allocatable :: data              !< Data payload
        character(len=:), allocatable :: offset            !< Read offset
        character(len=:), allocatable :: live              !< Live mode
        integer :: timeout_ms = 0                          !< Timeout
        integer(8) :: ttl_seconds = -1                     !< TTL
        integer(8) :: seq = -1                             !< Sequence number
        type(ds_headers_t) :: headers                      !< Custom headers
    end type ds_command_t

contains

    !> @brief Parse JSON command from stdin line
    subroutine json_parse_command(json_str, cmd, ierr)
        character(len=*), intent(in) :: json_str
        type(ds_command_t), intent(out) :: cmd
        integer, intent(out) :: ierr

        type(json_file) :: json
        character(len=:), allocatable :: cmd_type, str_val
        integer :: int_val
        logical :: found

        ierr = 0
        cmd%cmd_type = CMD_UNKNOWN

        call json%initialize()
        call json%deserialize(json_str)

        if (json%failed()) then
            ierr = 1
            call json%destroy()
            return
        end if

        ! Get command type
        call json%get('type', cmd_type, found)
        if (.not. found) then
            ierr = 2
            call json%destroy()
            return
        end if

        ! Map command type
        select case (trim(cmd_type))
            case ('init')
                cmd%cmd_type = CMD_INIT
                call json%get('serverUrl', cmd%server_url, found)

            case ('create')
                cmd%cmd_type = CMD_CREATE
                call json%get('path', cmd%path, found)
                call json%get('contentType', str_val, found)
                if (found) cmd%content_type = str_val
                call json%get('ttlSeconds', int_val, found)
                if (found) cmd%ttl_seconds = int(int_val, 8)
                call json%get('data', str_val, found)
                if (found) cmd%data = str_val

            case ('append')
                cmd%cmd_type = CMD_APPEND
                call json%get('path', cmd%path, found)
                call json%get('data', cmd%data, found)
                call json%get('seq', int_val, found)
                if (found) cmd%seq = int(int_val, 8)

            case ('read')
                cmd%cmd_type = CMD_READ
                call json%get('path', cmd%path, found)
                call json%get('offset', cmd%offset, found)
                call json%get('live', cmd%live, found)
                call json%get('timeoutMs', cmd%timeout_ms, found)

            case ('head')
                cmd%cmd_type = CMD_HEAD
                call json%get('path', cmd%path, found)

            case ('delete')
                cmd%cmd_type = CMD_DELETE
                call json%get('path', cmd%path, found)

            case ('shutdown')
                cmd%cmd_type = CMD_SHUTDOWN

            case default
                cmd%cmd_type = CMD_UNKNOWN
        end select

        ! Parse custom headers if present
        call parse_headers_from_json(json, cmd%headers)

        call json%destroy()
    end subroutine json_parse_command

    !> @brief Parse headers object from JSON
    subroutine parse_headers_from_json(json, headers)
        type(json_file), intent(inout) :: json
        type(ds_headers_t), intent(out) :: headers

        type(json_core) :: jc
        type(json_value), pointer :: p, headers_obj, child
        character(len=:), allocatable :: key, val
        integer :: i, n
        logical :: found

        call json%get('headers', headers_obj, found)
        if (.not. found) return

        call jc%initialize()
        call jc%info(headers_obj, n_children=n)

        do i = 1, n
            call jc%get_child(headers_obj, i, child, found)
            if (found) then
                call jc%info(child, name=key)
                call jc%get(child, val)
                call headers%add(key, val)
            end if
        end do
    end subroutine parse_headers_from_json

    !> @brief Build init response JSON
    function json_build_init_response(caps) result(json_str)
        type(ds_capabilities_t), intent(in) :: caps
        character(len=:), allocatable :: json_str

        json_str = '{"type":"init","success":true,' // &
            '"clientName":"' // DS_CLIENT_NAME // '",' // &
            '"clientVersion":"' // DS_CLIENT_VERSION // '",' // &
            '"features":{' // &
            '"sse":' // logical_to_json(caps%sse) // ',' // &
            '"longpoll":' // logical_to_json(caps%longpoll) // ',' // &
            '"batching":' // logical_to_json(caps%batching) // ',' // &
            '"retry":' // logical_to_json(caps%retry) // ',' // &
            '"dynamicHeaders":' // logical_to_json(caps%dynamic_headers) // &
            '}}'
    end function json_build_init_response

    !> @brief Build create response JSON
    function json_build_create_response(result) result(json_str)
        type(ds_create_result_t), intent(in) :: result
        character(len=:), allocatable :: json_str
        character(len=10) :: status_str

        write(status_str, '(I0)') result%status

        if (result%success) then
            json_str = '{"type":"create","success":true,"status":' // &
                trim(status_str) // ',"offset":"' // &
                json_escape_string(result%offset) // '"}'
        else
            json_str = json_build_error_response('create', result%status, &
                result%error_code, result%message)
        end if
    end function json_build_create_response

    !> @brief Build append response JSON
    function json_build_append_response(result) result(json_str)
        type(ds_append_result_t), intent(in) :: result
        character(len=:), allocatable :: json_str
        character(len=10) :: status_str

        write(status_str, '(I0)') result%status

        if (result%success) then
            json_str = '{"type":"append","success":true,"status":' // &
                trim(status_str) // ',"offset":"' // &
                json_escape_string(result%offset) // '"}'
        else
            json_str = json_build_error_response('append', result%status, &
                result%error_code, result%message)
        end if
    end function json_build_append_response

    !> @brief Build read response JSON
    function json_build_read_response(result) result(json_str)
        type(ds_read_result_t), intent(in) :: result
        character(len=:), allocatable :: json_str, chunks_str
        character(len=10) :: status_str
        integer :: i

        write(status_str, '(I0)') result%status

        if (result%success) then
            ! Build chunks array
            chunks_str = '['
            do i = 1, result%chunk_count
                if (i > 1) chunks_str = chunks_str // ','
                chunks_str = chunks_str // '{"offset":"' // &
                    json_escape_string(result%chunks(i)%offset) // '","data":"' // &
                    json_escape_string(result%chunks(i)%data) // '"}'
            end do
            chunks_str = chunks_str // ']'

            json_str = '{"type":"read","success":true,"status":' // &
                trim(status_str) // ',"chunks":' // chunks_str // &
                ',"upToDate":' // logical_to_json(result%up_to_date) // '}'
        else
            json_str = json_build_error_response('read', result%status, &
                result%error_code, result%message)
        end if
    end function json_build_read_response

    !> @brief Build head response JSON
    function json_build_head_response(result) result(json_str)
        type(ds_head_result_t), intent(in) :: result
        character(len=:), allocatable :: json_str
        character(len=10) :: status_str

        write(status_str, '(I0)') result%status

        if (result%success) then
            json_str = '{"type":"head","success":true,"status":' // &
                trim(status_str) // ',"offset":"' // &
                json_escape_string(result%offset) // '"'

            if (allocated(result%content_type)) then
                json_str = json_str // ',"contentType":"' // &
                    json_escape_string(result%content_type) // '"'
            end if

            json_str = json_str // '}'
        else
            json_str = json_build_error_response('head', result%status, &
                result%error_code, result%message)
        end if
    end function json_build_head_response

    !> @brief Build delete response JSON
    function json_build_delete_response(result) result(json_str)
        type(ds_delete_result_t), intent(in) :: result
        character(len=:), allocatable :: json_str
        character(len=10) :: status_str

        write(status_str, '(I0)') result%status

        if (result%success) then
            json_str = '{"type":"delete","success":true,"status":' // &
                trim(status_str) // '}'
        else
            json_str = json_build_error_response('delete', result%status, &
                result%error_code, result%message)
        end if
    end function json_build_delete_response

    !> @brief Build error response JSON
    function json_build_error_response(cmd_type, status, error_code, message) result(json_str)
        character(len=*), intent(in) :: cmd_type, error_code
        integer, intent(in) :: status
        character(len=*), intent(in), optional :: message
        character(len=:), allocatable :: json_str
        character(len=10) :: status_str

        write(status_str, '(I0)') status

        json_str = '{"type":"error","success":false,"commandType":"' // &
            trim(cmd_type) // '","status":' // trim(status_str) // &
            ',"errorCode":"' // trim(error_code) // '"'

        if (present(message) .and. len_trim(message) > 0) then
            json_str = json_str // ',"message":"' // &
                json_escape_string(message) // '"'
        end if

        json_str = json_str // '}'
    end function json_build_error_response

    !> @brief Build generic JSON response
    function json_build_response(cmd_type, success, status) result(json_str)
        character(len=*), intent(in) :: cmd_type
        logical, intent(in) :: success
        integer, intent(in) :: status
        character(len=:), allocatable :: json_str
        character(len=10) :: status_str

        write(status_str, '(I0)') status

        json_str = '{"type":"' // trim(cmd_type) // &
            '","success":' // logical_to_json(success) // &
            ',"status":' // trim(status_str) // '}'
    end function json_build_response

    !> @brief Escape string for JSON
    function json_escape_string(str) result(escaped)
        character(len=*), intent(in) :: str
        character(len=:), allocatable :: escaped
        integer :: i, j, n
        character(len=1) :: ch

        if (.not. allocated(str) .or. len(str) == 0) then
            escaped = ""
            return
        end if

        n = len(str)
        allocate(character(len=n*6) :: escaped)  ! Worst case: all \uXXXX

        j = 1
        do i = 1, n
            ch = str(i:i)
            select case (ch)
                case ('"')
                    escaped(j:j+1) = '\"'
                    j = j + 2
                case ('\')
                    escaped(j:j+1) = '\\'
                    j = j + 2
                case (char(8))  ! Backspace
                    escaped(j:j+1) = '\b'
                    j = j + 2
                case (char(12)) ! Form feed
                    escaped(j:j+1) = '\f'
                    j = j + 2
                case (char(10)) ! Newline
                    escaped(j:j+1) = '\n'
                    j = j + 2
                case (char(13)) ! Carriage return
                    escaped(j:j+1) = '\r'
                    j = j + 2
                case (char(9))  ! Tab
                    escaped(j:j+1) = '\t'
                    j = j + 2
                case default
                    if (ichar(ch) < 32) then
                        ! Control characters as \uXXXX
                        write(escaped(j:j+5), '(A2,Z4.4)') '\u', ichar(ch)
                        j = j + 6
                    else
                        escaped(j:j) = ch
                        j = j + 1
                    end if
            end select
        end do

        escaped = escaped(1:j-1)
    end function json_escape_string

    !> @brief Convert logical to JSON boolean string
    function logical_to_json(val) result(str)
        logical, intent(in) :: val
        character(len=:), allocatable :: str
        if (val) then
            str = 'true'
        else
            str = 'false'
        end if
    end function logical_to_json

    !> @brief Get string value from JSON
    subroutine json_get_string(json, key, value, found)
        type(json_file), intent(inout) :: json
        character(len=*), intent(in) :: key
        character(len=:), allocatable, intent(out) :: value
        logical, intent(out) :: found
        call json%get(key, value, found)
    end subroutine json_get_string

    !> @brief Get integer value from JSON
    subroutine json_get_integer(json, key, value, found)
        type(json_file), intent(inout) :: json
        character(len=*), intent(in) :: key
        integer, intent(out) :: value
        logical, intent(out) :: found
        call json%get(key, value, found)
    end subroutine json_get_integer

    !> @brief Get boolean value from JSON
    subroutine json_get_boolean(json, key, value, found)
        type(json_file), intent(inout) :: json
        character(len=*), intent(in) :: key
        logical, intent(out) :: value
        logical, intent(out) :: found
        call json%get(key, value, found)
    end subroutine json_get_boolean

end module ds_json_utils
