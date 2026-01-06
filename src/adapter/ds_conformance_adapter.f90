!> @file ds_conformance_adapter.f90
!> @brief Conformance test adapter for Durable Streams
!>
!> This program provides the command-line interface required by the
!> Durable Streams conformance test suite. It reads JSON commands from
!> stdin and writes JSON responses to stdout.
!>
!> The adapter implements the following command protocol:
!> - init: Initialize client with server URL
!> - create: Create a new stream
!> - append: Append data to a stream
!> - read: Read from a stream
!> - head: Get stream metadata
!> - delete: Delete a stream
!> - shutdown: Clean shutdown
!>
!> @author Fortran Durable Streams Team
!> @date 2026

program ds_conformance_adapter
    use durable_streams
    use ds_types
    use ds_constants
    use ds_json_utils
    use ds_error
    use, intrinsic :: iso_fortran_env, only: input_unit, output_unit, error_unit
    implicit none

    character(len=65536) :: line
    type(ds_command_t) :: cmd
    integer :: iostat, ierr
    logical :: running

    running = .true.

    ! Main command loop
    do while (running)
        ! Read command from stdin
        read(input_unit, '(A)', iostat=iostat) line
        if (iostat /= 0) exit

        ! Skip empty lines
        if (len_trim(line) == 0) cycle

        ! Parse JSON command
        call json_parse_command(trim(line), cmd, ierr)
        if (ierr /= 0) then
            call write_parse_error()
            cycle
        end if

        ! Dispatch command
        select case (cmd%cmd_type)
            case (CMD_INIT)
                call handle_init(cmd)

            case (CMD_CREATE)
                call handle_create(cmd)

            case (CMD_APPEND)
                call handle_append(cmd)

            case (CMD_READ)
                call handle_read(cmd)

            case (CMD_HEAD)
                call handle_head(cmd)

            case (CMD_DELETE)
                call handle_delete(cmd)

            case (CMD_SHUTDOWN)
                call handle_shutdown()
                running = .false.

            case default
                call write_unknown_command()
        end select
    end do

    ! Cleanup
    call ds_finalize()

contains

    !> @brief Handle init command
    subroutine handle_init(cmd)
        type(ds_command_t), intent(in) :: cmd
        type(ds_capabilities_t) :: caps
        character(len=:), allocatable :: response
        integer :: ierr

        if (.not. allocated(cmd%server_url)) then
            call write_error("init", 0, ERR_CODE_BAD_REQUEST, "Missing serverUrl")
            return
        end if

        call ds_initialize(cmd%server_url, ierr)
        if (ierr /= 0) then
            call write_error("init", 0, ERR_CODE_INTERNAL, "Failed to initialize client")
            return
        end if

        caps = ds_get_capabilities()
        response = json_build_init_response(caps)
        call write_response(response)
    end subroutine handle_init

    !> @brief Handle create command
    subroutine handle_create(cmd)
        type(ds_command_t), intent(in) :: cmd
        type(ds_create_result_t) :: res
        character(len=:), allocatable :: response
        character(len=:), allocatable :: ct
        integer(8) :: ttl

        if (.not. allocated(cmd%path)) then
            call write_error("create", 0, ERR_CODE_BAD_REQUEST, "Missing path")
            return
        end if

        ! Set content type
        if (allocated(cmd%content_type)) then
            ct = cmd%content_type
        else
            ct = CT_JSON
        end if

        ! Set TTL
        ttl = cmd%ttl_seconds

        ! Create stream
        if (allocated(cmd%data) .and. len(cmd%data) > 0) then
            res = ds_create(cmd%path, ct, ttl, cmd%data, cmd%headers)
        else if (ttl > 0) then
            res = ds_create(cmd%path, ct, ttl, headers=cmd%headers)
        else
            res = ds_create(cmd%path, ct, headers=cmd%headers)
        end if

        response = json_build_create_response(res)
        call write_response(response)
    end subroutine handle_create

    !> @brief Handle append command
    subroutine handle_append(cmd)
        type(ds_command_t), intent(in) :: cmd
        type(ds_append_result_t) :: res
        character(len=:), allocatable :: response

        if (.not. allocated(cmd%path)) then
            call write_error("append", 0, ERR_CODE_BAD_REQUEST, "Missing path")
            return
        end if

        if (.not. allocated(cmd%data)) then
            call write_error("append", HTTP_BAD_REQUEST, ERR_CODE_BAD_REQUEST, &
                "Missing data")
            return
        end if

        ! Append data
        if (cmd%seq >= 0) then
            res = ds_append(cmd%path, cmd%data, cmd%seq, cmd%headers)
        else
            res = ds_append(cmd%path, cmd%data, headers=cmd%headers)
        end if

        response = json_build_append_response(res)
        call write_response(response)
    end subroutine handle_append

    !> @brief Handle read command
    subroutine handle_read(cmd)
        type(ds_command_t), intent(in) :: cmd
        type(ds_read_result_t) :: res
        character(len=:), allocatable :: response
        character(len=:), allocatable :: offset, live
        integer :: timeout

        if (.not. allocated(cmd%path)) then
            call write_error("read", 0, ERR_CODE_BAD_REQUEST, "Missing path")
            return
        end if

        ! Set offset
        if (allocated(cmd%offset)) then
            offset = cmd%offset
        else
            offset = OFFSET_BEGINNING
        end if

        ! Set live mode
        if (allocated(cmd%live)) then
            live = cmd%live
        else
            live = LIVE_NONE
        end if

        ! Set timeout
        if (cmd%timeout_ms > 0) then
            timeout = cmd%timeout_ms
        else
            timeout = DEFAULT_LONGPOLL_TIMEOUT_MS
        end if

        ! Read from stream
        res = ds_read(cmd%path, offset, live, timeout, cmd%headers)

        response = json_build_read_response(res)
        call write_response(response)
    end subroutine handle_read

    !> @brief Handle head command
    subroutine handle_head(cmd)
        type(ds_command_t), intent(in) :: cmd
        type(ds_head_result_t) :: res
        character(len=:), allocatable :: response

        if (.not. allocated(cmd%path)) then
            call write_error("head", 0, ERR_CODE_BAD_REQUEST, "Missing path")
            return
        end if

        res = ds_head(cmd%path, cmd%headers)

        response = json_build_head_response(res)
        call write_response(response)
    end subroutine handle_head

    !> @brief Handle delete command
    subroutine handle_delete(cmd)
        type(ds_command_t), intent(in) :: cmd
        type(ds_delete_result_t) :: res
        character(len=:), allocatable :: response

        if (.not. allocated(cmd%path)) then
            call write_error("delete", 0, ERR_CODE_BAD_REQUEST, "Missing path")
            return
        end if

        res = ds_delete(cmd%path, cmd%headers)

        response = json_build_delete_response(res)
        call write_response(response)
    end subroutine handle_delete

    !> @brief Handle shutdown command
    subroutine handle_shutdown()
        character(len=:), allocatable :: response
        response = '{"type":"shutdown","success":true}'
        call write_response(response)
    end subroutine handle_shutdown

    !> @brief Write JSON response to stdout
    subroutine write_response(response)
        character(len=*), intent(in) :: response
        write(output_unit, '(A)') trim(response)
        flush(output_unit)
    end subroutine write_response

    !> @brief Write error response
    subroutine write_error(cmd_type, status, error_code, message)
        character(len=*), intent(in) :: cmd_type, error_code
        integer, intent(in) :: status
        character(len=*), intent(in), optional :: message
        character(len=:), allocatable :: response

        if (present(message)) then
            response = json_build_error_response(cmd_type, status, error_code, message)
        else
            response = json_build_error_response(cmd_type, status, error_code)
        end if
        call write_response(response)
    end subroutine write_error

    !> @brief Write parse error response
    subroutine write_parse_error()
        call write_error("unknown", 0, ERR_CODE_PARSE, "Failed to parse JSON command")
    end subroutine write_parse_error

    !> @brief Write unknown command error
    subroutine write_unknown_command()
        call write_error("unknown", 0, ERR_CODE_NOT_SUPPORTED, "Unknown command type")
    end subroutine write_unknown_command

end program ds_conformance_adapter
