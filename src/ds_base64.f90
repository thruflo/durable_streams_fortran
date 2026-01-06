!> @file ds_base64.f90
!> @brief Base64 encoding/decoding for binary data
!>
!> This module provides base64 encoding and decoding routines for handling
!> binary data in the Durable Streams protocol. Binary data is transmitted
!> as base64-encoded strings in the conformance test adapter.
!>
!> @author Fortran Durable Streams Team
!> @date 2026

module ds_base64
    use, intrinsic :: iso_fortran_env, only: int8
    implicit none
    private

    ! Base64 alphabet
    character(len=64), parameter :: B64_ALPHABET = &
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    public :: base64_encode
    public :: base64_decode
    public :: is_base64_string

contains

    !> @brief Encode bytes to base64 string
    !>
    !> @param input Input bytes
    !> @return Base64-encoded string
    function base64_encode(input) result(output)
        character(len=*), intent(in) :: input
        character(len=:), allocatable :: output
        integer :: i, j, n, pad, outlen
        integer :: a, b, c, triple
        character(len=4) :: quad

        n = len(input)
        if (n == 0) then
            output = ""
            return
        end if

        ! Calculate output length (4 chars per 3 input bytes, rounded up)
        outlen = ((n + 2) / 3) * 4
        allocate(character(len=outlen) :: output)

        j = 1
        do i = 1, n, 3
            ! Get up to 3 bytes
            a = ichar(input(i:i))

            if (i + 1 <= n) then
                b = ichar(input(i+1:i+1))
            else
                b = 0
            end if

            if (i + 2 <= n) then
                c = ichar(input(i+2:i+2))
            else
                c = 0
            end if

            ! Combine into 24-bit value
            triple = ior(ior(ishft(a, 16), ishft(b, 8)), c)

            ! Extract 4 6-bit values
            quad(1:1) = B64_ALPHABET(iand(ishft(triple, -18), 63) + 1:iand(ishft(triple, -18), 63) + 1)
            quad(2:2) = B64_ALPHABET(iand(ishft(triple, -12), 63) + 1:iand(ishft(triple, -12), 63) + 1)
            quad(3:3) = B64_ALPHABET(iand(ishft(triple, -6), 63) + 1:iand(ishft(triple, -6), 63) + 1)
            quad(4:4) = B64_ALPHABET(iand(triple, 63) + 1:iand(triple, 63) + 1)

            output(j:j+3) = quad
            j = j + 4
        end do

        ! Add padding
        pad = mod(n, 3)
        if (pad == 1) then
            output(outlen-1:outlen) = "=="
        else if (pad == 2) then
            output(outlen:outlen) = "="
        end if
    end function base64_encode

    !> @brief Decode base64 string to bytes
    !>
    !> @param input Base64-encoded string
    !> @return Decoded bytes as string
    function base64_decode(input) result(output)
        character(len=*), intent(in) :: input
        character(len=:), allocatable :: output
        integer :: i, j, n, outlen, pad
        integer :: a, b, c, d, triple
        character(len=1) :: ch

        n = len_trim(input)
        if (n == 0) then
            output = ""
            return
        end if

        ! Count padding
        pad = 0
        if (n >= 1 .and. input(n:n) == "=") pad = pad + 1
        if (n >= 2 .and. input(n-1:n-1) == "=") pad = pad + 1

        ! Calculate output length
        outlen = (n / 4) * 3 - pad
        allocate(character(len=outlen) :: output)

        j = 1
        do i = 1, n, 4
            if (i + 3 > n) exit

            ! Decode 4 base64 characters
            a = decode_char(input(i:i))
            b = decode_char(input(i+1:i+1))
            c = decode_char(input(i+2:i+2))
            d = decode_char(input(i+3:i+3))

            ! Combine into 24-bit value
            triple = ior(ior(ior(ishft(a, 18), ishft(b, 12)), ishft(c, 6)), d)

            ! Extract 3 bytes
            if (j <= outlen) then
                output(j:j) = char(iand(ishft(triple, -16), 255))
                j = j + 1
            end if
            if (j <= outlen) then
                output(j:j) = char(iand(ishft(triple, -8), 255))
                j = j + 1
            end if
            if (j <= outlen) then
                output(j:j) = char(iand(triple, 255))
                j = j + 1
            end if
        end do
    end function base64_decode

    !> @brief Decode single base64 character
    function decode_char(ch) result(val)
        character(len=1), intent(in) :: ch
        integer :: val, idx

        idx = index(B64_ALPHABET, ch)
        if (idx > 0) then
            val = idx - 1
        else if (ch == "=") then
            val = 0
        else
            val = 0
        end if
    end function decode_char

    !> @brief Check if string is valid base64
    !>
    !> @param str String to check
    !> @return True if valid base64
    function is_base64_string(str) result(valid)
        character(len=*), intent(in) :: str
        logical :: valid
        integer :: i, n
        character(len=1) :: ch

        valid = .true.
        n = len_trim(str)

        ! Length must be multiple of 4
        if (mod(n, 4) /= 0) then
            valid = .false.
            return
        end if

        ! Check each character
        do i = 1, n
            ch = str(i:i)
            if (index(B64_ALPHABET, ch) == 0 .and. ch /= "=") then
                valid = .false.
                return
            end if
            ! Padding only allowed at end
            if (ch == "=" .and. i < n - 1) then
                valid = .false.
                return
            end if
        end do
    end function is_base64_string

end module ds_base64
