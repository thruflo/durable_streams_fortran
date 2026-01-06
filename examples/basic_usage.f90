!> @file basic_usage.f90
!> @brief Basic usage example for Fortran Durable Streams client
!>
!> This example demonstrates the fundamental operations of the Durable
!> Streams client: creating streams, appending data, reading data, and
!> cleanup.
!>
!> @author Fortran Durable Streams Team
!> @date 2026

program basic_usage
    use durable_streams
    use, intrinsic :: iso_fortran_env, only: output_unit
    implicit none

    ! Result types
    type(ds_create_result_t) :: create_res
    type(ds_append_result_t) :: append_res
    type(ds_read_result_t) :: read_res
    type(ds_head_result_t) :: head_res
    type(ds_delete_result_t) :: delete_res

    integer :: ierr, i
    character(len=*), parameter :: SERVER_URL = "http://localhost:4437"
    character(len=*), parameter :: STREAM_PATH = "/example/basic-stream"

    print '(A)', "================================"
    print '(A)', " Fortran Durable Streams Client"
    print '(A)', "   Basic Usage Example"
    print '(A)', "================================"
    print '(A)', ""

    ! Initialize the client
    print '(A)', "1. Initializing client..."
    call ds_initialize(SERVER_URL, ierr)
    if (ierr /= 0) then
        print '(A)', "ERROR: Failed to initialize client"
        stop 1
    end if
    print '(A,A)', "   Connected to: ", SERVER_URL

    ! Create a new stream
    print '(A)', ""
    print '(A)', "2. Creating stream..."
    create_res = ds_create(STREAM_PATH, CT_JSON)
    if (create_res%success) then
        print '(A,A)', "   Stream created at: ", STREAM_PATH
        print '(A,A)', "   Initial offset: ", create_res%offset
    else
        print '(A,I0,A,A)', "   Status: ", create_res%status, " - ", create_res%error_code
    end if

    ! Append some data
    print '(A)', ""
    print '(A)', "3. Appending data..."

    append_res = ds_append(STREAM_PATH, '{"event":"hello","message":"Hello from Fortran!"}')
    if (append_res%success) then
        print '(A,A)', "   First append offset: ", append_res%offset
    end if

    append_res = ds_append(STREAM_PATH, '{"event":"status","value":42}')
    if (append_res%success) then
        print '(A,A)', "   Second append offset: ", append_res%offset
    end if

    append_res = ds_append(STREAM_PATH, '{"event":"goodbye","message":"Farewell!"}')
    if (append_res%success) then
        print '(A,A)', "   Third append offset: ", append_res%offset
    end if

    ! Get stream metadata
    print '(A)', ""
    print '(A)', "4. Getting stream metadata..."
    head_res = ds_head(STREAM_PATH)
    if (head_res%success) then
        print '(A,A)', "   Current offset: ", head_res%offset
        print '(A,A)', "   Content type: ", head_res%content_type
    end if

    ! Read all data from the beginning
    print '(A)', ""
    print '(A)', "5. Reading all data from beginning..."
    read_res = ds_read(STREAM_PATH, OFFSET_BEGINNING)
    if (read_res%success) then
        print '(A,I0,A)', "   Received ", read_res%chunk_count, " chunk(s)"
        do i = 1, read_res%chunk_count
            print '(A,I0,A,A)', "   Chunk ", i, ": ", &
                trim(read_res%chunks(i)%data)
        end do
        print '(A,L1)', "   Up to date: ", read_res%up_to_date
        print '(A,A)', "   Next offset: ", read_res%next_offset
    else
        print '(A,A)', "   Error: ", read_res%error_code
    end if

    ! Delete the stream
    print '(A)', ""
    print '(A)', "6. Deleting stream..."
    delete_res = ds_delete(STREAM_PATH)
    if (delete_res%success) then
        print '(A)', "   Stream deleted successfully"
    else
        print '(A,A)', "   Error: ", delete_res%error_code
    end if

    ! Cleanup
    print '(A)', ""
    print '(A)', "7. Cleaning up..."
    call ds_finalize()
    print '(A)', "   Client shutdown complete"

    print '(A)', ""
    print '(A)', "================================"
    print '(A)', " Example completed successfully!"
    print '(A)', "================================"

end program basic_usage
