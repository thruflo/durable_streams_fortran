!> @file ds_error.f90
!> @brief Error handling utilities for Durable Streams
!>
!> This module provides error handling and mapping from HTTP status codes
!> to semantic error codes used by the conformance test suite.
!>
!> @author Fortran Durable Streams Team
!> @date 2026

module ds_error
    use ds_constants
    implicit none
    private

    public :: http_status_to_error_code
    public :: is_retryable_status
    public :: is_success_status
    public :: format_error_message

contains

    !> @brief Convert HTTP status code to error code string
    !>
    !> Maps HTTP status codes to the semantic error codes expected by
    !> the Durable Streams conformance test suite.
    !>
    !> @param status HTTP status code
    !> @return Error code string (empty string for success)
    function http_status_to_error_code(status) result(code)
        integer, intent(in) :: status
        character(len=:), allocatable :: code

        select case (status)
            case (200:299)
                code = ERR_CODE_NONE
            case (HTTP_BAD_REQUEST)
                code = ERR_CODE_BAD_REQUEST
            case (HTTP_NOT_FOUND)
                code = ERR_CODE_NOT_FOUND
            case (HTTP_CONFLICT)
                code = ERR_CODE_CONFLICT
            case (HTTP_GONE)
                code = ERR_CODE_NOT_FOUND
            case (HTTP_TOO_MANY_REQUESTS)
                code = ERR_CODE_TIMEOUT
            case (HTTP_SERVICE_UNAVAILABLE)
                code = ERR_CODE_TIMEOUT
            case (0)
                code = ERR_CODE_NETWORK
            case default
                code = ERR_CODE_UNEXPECTED
        end select
    end function http_status_to_error_code

    !> @brief Check if HTTP status is retryable
    !>
    !> According to the protocol spec, 429 and 5xx errors should be retried
    !> with exponential backoff.
    !>
    !> @param status HTTP status code
    !> @return True if the error should be retried
    function is_retryable_status(status) result(retryable)
        integer, intent(in) :: status
        logical :: retryable

        select case (status)
            case (HTTP_TOO_MANY_REQUESTS)
                retryable = .true.
            case (500:599)
                retryable = .true.
            case (0)  ! Network error
                retryable = .true.
            case default
                retryable = .false.
        end select
    end function is_retryable_status

    !> @brief Check if HTTP status indicates success
    !>
    !> @param status HTTP status code
    !> @return True if successful (2xx status)
    function is_success_status(status) result(success)
        integer, intent(in) :: status
        logical :: success
        success = (status >= 200 .and. status < 300)
    end function is_success_status

    !> @brief Format an error message with status and details
    !>
    !> @param status HTTP status code
    !> @param error_code Error code string
    !> @param details Additional details
    !> @return Formatted error message
    function format_error_message(status, error_code, details) result(message)
        integer, intent(in) :: status
        character(len=*), intent(in) :: error_code
        character(len=*), intent(in), optional :: details
        character(len=:), allocatable :: message
        character(len=10) :: status_str

        write(status_str, '(I0)') status

        if (present(details) .and. len_trim(details) > 0) then
            message = "HTTP " // trim(status_str) // " (" // trim(error_code) // "): " // trim(details)
        else
            message = "HTTP " // trim(status_str) // " (" // trim(error_code) // ")"
        end if
    end function format_error_message

end module ds_error
