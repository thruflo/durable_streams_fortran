!> @file streaming_read.f90
!> @brief Streaming read example for Fortran Durable Streams client
!>
!> This example demonstrates real-time streaming using long-poll mode,
!> showing how to continuously read new data as it arrives.
!>
!> @author Fortran Durable Streams Team
!> @date 2026

program streaming_read
    use durable_streams
    use, intrinsic :: iso_fortran_env, only: output_unit
    implicit none

    type(ds_create_result_t) :: create_res
    type(ds_read_result_t) :: read_res
    type(ds_delete_result_t) :: delete_res

    integer :: ierr, i, poll_count
    character(len=:), allocatable :: current_offset
    character(len=*), parameter :: SERVER_URL = "http://localhost:4437"
    character(len=*), parameter :: STREAM_PATH = "/example/streaming-demo"

    print '(A)', "================================"
    print '(A)', " Streaming Read Example"
    print '(A)', "================================"
    print '(A)', ""

    ! Initialize
    print '(A)', "Initializing client..."
    call ds_initialize(SERVER_URL, ierr)
    if (ierr /= 0) then
        print '(A)', "ERROR: Failed to initialize"
        stop 1
    end if

    ! Create stream
    print '(A)', "Creating stream..."
    create_res = ds_create(STREAM_PATH, CT_TEXT)
    if (.not. create_res%success) then
        print '(A,A)', "ERROR: ", create_res%error_code
        stop 1
    end if

    print '(A)', ""
    print '(A)', "Starting long-poll reader..."
    print '(A)', "(In another terminal, append data to the stream)"
    print '(A)', "(Press Ctrl+C to stop)"
    print '(A)', ""

    ! Initialize offset
    current_offset = OFFSET_BEGINNING
    poll_count = 0

    ! Long-poll loop
    do while (poll_count < 10)  ! Limit for demo
        poll_count = poll_count + 1

        print '(A,I0,A,A)', "Poll #", poll_count, " from offset: ", current_offset

        ! Long-poll read with 5 second timeout
        read_res = ds_read(STREAM_PATH, current_offset, LIVE_LONG_POLL, 5000)

        if (read_res%success) then
            if (read_res%chunk_count > 0) then
                print '(A,I0,A)', "  Received ", read_res%chunk_count, " chunk(s):"
                do i = 1, read_res%chunk_count
                    print '(A,A)', "    -> ", trim(read_res%chunks(i)%data)
                end do
            else
                print '(A)', "  (no new data - timeout)"
            end if

            ! Update offset for next read
            if (allocated(read_res%next_offset)) then
                current_offset = read_res%next_offset
            end if

            print '(A,L1)', "  Up to date: ", read_res%up_to_date

        else
            print '(A,A)', "  Error: ", read_res%error_code
            exit
        end if

        print '(A)', ""
    end do

    ! Cleanup
    print '(A)', "Cleaning up..."
    delete_res = ds_delete(STREAM_PATH)
    call ds_finalize()

    print '(A)', "Done!"

end program streaming_read
