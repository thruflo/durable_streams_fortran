!> @file test_json.f90
!> @brief Unit tests for JSON utilities

program test_json
    use ds_json_utils
    use ds_types
    use ds_constants
    implicit none

    integer :: pass_count, fail_count

    pass_count = 0
    fail_count = 0

    call test_escape_simple()
    call test_escape_special()
    call test_build_init_response()
    call test_build_error_response()

    print '(A)', "================================"
    print '(A,I0,A,I0)', "JSON Tests: ", pass_count, " passed, ", fail_count, " failed"

    if (fail_count > 0) stop 1

contains

    subroutine test_escape_simple()
        character(len=:), allocatable :: result
        result = json_escape_string("Hello World")
        if (result == "Hello World") then
            print '(A)', "PASS: escape simple string"
            pass_count = pass_count + 1
        else
            print '(A,A)', "FAIL: escape simple string, got: ", result
            fail_count = fail_count + 1
        end if
    end subroutine

    subroutine test_escape_special()
        character(len=:), allocatable :: result
        result = json_escape_string('Say "Hello"')
        if (index(result, '\"') > 0) then
            print '(A)', "PASS: escape quotes"
            pass_count = pass_count + 1
        else
            print '(A,A)', "FAIL: escape quotes, got: ", result
            fail_count = fail_count + 1
        end if
    end subroutine

    subroutine test_build_init_response()
        type(ds_capabilities_t) :: caps
        character(len=:), allocatable :: result

        caps%sse = .true.
        caps%longpoll = .true.
        caps%batching = .false.
        caps%retry = .true.
        caps%dynamic_headers = .false.

        result = json_build_init_response(caps)

        if (index(result, '"success":true') > 0 .and. &
            index(result, '"clientName"') > 0) then
            print '(A)', "PASS: build init response"
            pass_count = pass_count + 1
        else
            print '(A)', "FAIL: build init response"
            fail_count = fail_count + 1
        end if
    end subroutine

    subroutine test_build_error_response()
        character(len=:), allocatable :: result

        result = json_build_error_response("create", 404, "NOT_FOUND", "Stream not found")

        if (index(result, '"success":false') > 0 .and. &
            index(result, '"errorCode":"NOT_FOUND"') > 0) then
            print '(A)', "PASS: build error response"
            pass_count = pass_count + 1
        else
            print '(A)', "FAIL: build error response"
            fail_count = fail_count + 1
        end if
    end subroutine

end program test_json
