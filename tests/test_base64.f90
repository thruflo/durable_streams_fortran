!> @file test_base64.f90
!> @brief Unit tests for base64 encoding/decoding

program test_base64
    use ds_base64
    implicit none

    integer :: pass_count, fail_count

    pass_count = 0
    fail_count = 0

    call test_encode_empty()
    call test_encode_simple()
    call test_encode_padding()
    call test_decode_simple()
    call test_roundtrip()

    print '(A)', "================================"
    print '(A,I0,A,I0)', "Base64 Tests: ", pass_count, " passed, ", fail_count, " failed"

    if (fail_count > 0) stop 1

contains

    subroutine test_encode_empty()
        character(len=:), allocatable :: result
        result = base64_encode("")
        if (result == "") then
            print '(A)', "PASS: encode empty string"
            pass_count = pass_count + 1
        else
            print '(A)', "FAIL: encode empty string"
            fail_count = fail_count + 1
        end if
    end subroutine

    subroutine test_encode_simple()
        character(len=:), allocatable :: result
        result = base64_encode("Hello")
        if (result == "SGVsbG8=") then
            print '(A)', "PASS: encode 'Hello'"
            pass_count = pass_count + 1
        else
            print '(A,A)', "FAIL: encode 'Hello', got: ", result
            fail_count = fail_count + 1
        end if
    end subroutine

    subroutine test_encode_padding()
        character(len=:), allocatable :: r1, r2, r3
        logical :: ok

        r1 = base64_encode("a")    ! 1 byte -> 2 padding
        r2 = base64_encode("ab")   ! 2 bytes -> 1 padding
        r3 = base64_encode("abc")  ! 3 bytes -> no padding

        ok = .true.
        if (r1 /= "YQ==") ok = .false.
        if (r2 /= "YWI=") ok = .false.
        if (r3 /= "YWJj") ok = .false.

        if (ok) then
            print '(A)', "PASS: padding variations"
            pass_count = pass_count + 1
        else
            print '(A)', "FAIL: padding variations"
            fail_count = fail_count + 1
        end if
    end subroutine

    subroutine test_decode_simple()
        character(len=:), allocatable :: result
        result = base64_decode("SGVsbG8=")
        if (result == "Hello") then
            print '(A)', "PASS: decode 'SGVsbG8='"
            pass_count = pass_count + 1
        else
            print '(A,A)', "FAIL: decode 'SGVsbG8=', got: ", result
            fail_count = fail_count + 1
        end if
    end subroutine

    subroutine test_roundtrip()
        character(len=*), parameter :: test_strings(5) = [ &
            "Hello, World!   ", &
            "Fortran Forever!", &
            "1234567890      ", &
            "Special: @#$%^& ", &
            "Unicode test    " ]
        character(len=:), allocatable :: encoded, decoded
        integer :: i
        logical :: ok

        ok = .true.
        do i = 1, size(test_strings)
            encoded = base64_encode(trim(test_strings(i)))
            decoded = base64_decode(encoded)
            if (decoded /= trim(test_strings(i))) then
                ok = .false.
                print '(A,A)', "  Failed on: ", trim(test_strings(i))
            end if
        end do

        if (ok) then
            print '(A)', "PASS: roundtrip encoding"
            pass_count = pass_count + 1
        else
            print '(A)', "FAIL: roundtrip encoding"
            fail_count = fail_count + 1
        end if
    end subroutine

end program test_base64
