!> @file ds_sse.f90
!> @brief Server-Sent Events (SSE) parser for Durable Streams
!>
!> This module provides parsing functionality for Server-Sent Events
!> as used by the Durable Streams protocol in live=sse mode.
!>
!> SSE Format:
!>   event: <event-type>
!>   data: <data-line>
!>   (blank line signals end of event)
!>
!> Durable Streams uses two event types:
!>   - data: actual stream data
!>   - control: metadata (offset, cursor, upToDate)
!>
!> @author Fortran Durable Streams Team
!> @date 2026

module ds_sse
    use ds_types
    use ds_constants
    use json_module
    implicit none
    private

    !> SSE event types
    integer, parameter, public :: SSE_EVENT_UNKNOWN = 0
    integer, parameter, public :: SSE_EVENT_DATA = 1
    integer, parameter, public :: SSE_EVENT_CONTROL = 2

    !> Parsed SSE event
    type, public :: sse_event_t
        integer :: event_type = SSE_EVENT_UNKNOWN
        character(len=:), allocatable :: data           !< For data events
        character(len=:), allocatable :: offset         !< From control events
        character(len=:), allocatable :: cursor         !< From control events
        logical :: up_to_date = .false.                 !< From control events
    end type sse_event_t

    !> SSE parser state
    type, public :: sse_parser_t
        character(len=:), allocatable :: buffer         !< Accumulated data
        character(len=:), allocatable :: current_event  !< Current event type
        character(len=:), allocatable :: current_data   !< Current data accumulator
    contains
        procedure :: init => parser_init
        procedure :: feed => parser_feed
        procedure :: reset => parser_reset
    end type sse_parser_t

    public :: sse_parse_events
    public :: sse_parse_control_event

contains

    !> @brief Initialize parser
    subroutine parser_init(this)
        class(sse_parser_t), intent(inout) :: this
        this%buffer = ""
        this%current_event = ""
        this%current_data = ""
    end subroutine parser_init

    !> @brief Reset parser state
    subroutine parser_reset(this)
        class(sse_parser_t), intent(inout) :: this
        if (allocated(this%buffer)) deallocate(this%buffer)
        if (allocated(this%current_event)) deallocate(this%current_event)
        if (allocated(this%current_data)) deallocate(this%current_data)
        this%buffer = ""
        this%current_event = ""
        this%current_data = ""
    end subroutine parser_reset

    !> @brief Feed data to parser and get events
    subroutine parser_feed(this, data, events, event_count)
        class(sse_parser_t), intent(inout) :: this
        character(len=*), intent(in) :: data
        type(sse_event_t), allocatable, intent(out) :: events(:)
        integer, intent(out) :: event_count

        call sse_parse_events(data, events, event_count)
    end subroutine parser_feed

    !> @brief Parse SSE events from raw data
    !>
    !> Parses Server-Sent Events format and extracts individual events.
    !> Handles multi-line data and blank line event boundaries.
    !>
    !> @param data Raw SSE data
    !> @param events Output array of parsed events
    !> @param event_count Number of events parsed
    subroutine sse_parse_events(data, events, event_count)
        character(len=*), intent(in) :: data
        type(sse_event_t), allocatable, intent(out) :: events(:)
        integer, intent(out) :: event_count

        character(len=:), allocatable :: current_event_type
        character(len=:), allocatable :: current_data
        type(sse_event_t), allocatable :: temp_events(:)
        integer :: i, line_start, line_end, n
        character(len=:), allocatable :: line
        integer :: max_events

        event_count = 0
        max_events = 100
        allocate(temp_events(max_events))
        current_event_type = ""
        current_data = ""

        n = len(data)
        line_start = 1

        do while (line_start <= n)
            ! Find end of line
            line_end = line_start
            do while (line_end <= n)
                if (data(line_end:line_end) == char(10)) exit
                line_end = line_end + 1
            end do

            ! Extract line (strip CR if present)
            if (line_end > line_start) then
                if (data(line_end-1:line_end-1) == char(13)) then
                    line = data(line_start:line_end-2)
                else
                    line = data(line_start:line_end-1)
                end if
            else
                line = ""
            end if

            ! Process line
            if (len(line) == 0) then
                ! Blank line - emit event if we have data
                if (len_trim(current_event_type) > 0 .and. len_trim(current_data) > 0) then
                    event_count = event_count + 1
                    if (event_count > max_events) then
                        ! Expand array
                        call expand_events(temp_events, max_events)
                    end if

                    call create_event(current_event_type, current_data, &
                        temp_events(event_count))
                end if
                current_event_type = ""
                current_data = ""

            else if (starts_with(line, "event:")) then
                ! Event type line
                current_event_type = trim(adjustl(line(7:)))

            else if (starts_with(line, "data:")) then
                ! Data line
                if (len(line) > 5) then
                    ! Strip optional leading space after "data:"
                    if (line(6:6) == " ") then
                        if (len_trim(current_data) > 0) then
                            current_data = current_data // char(10) // line(7:)
                        else
                            current_data = line(7:)
                        end if
                    else
                        if (len_trim(current_data) > 0) then
                            current_data = current_data // char(10) // line(6:)
                        else
                            current_data = line(6:)
                        end if
                    end if
                end if

            else if (starts_with(line, ":")) then
                ! Comment line - ignore
                continue

            else if (starts_with(line, "id:")) then
                ! ID line - ignore for now
                continue

            else if (starts_with(line, "retry:")) then
                ! Retry line - ignore for now
                continue
            end if

            line_start = line_end + 1
        end do

        ! Handle final event if buffer ends without blank line
        if (len_trim(current_event_type) > 0 .and. len_trim(current_data) > 0) then
            event_count = event_count + 1
            if (event_count > max_events) then
                call expand_events(temp_events, max_events)
            end if
            call create_event(current_event_type, current_data, &
                temp_events(event_count))
        end if

        ! Copy to output
        if (event_count > 0) then
            allocate(events(event_count))
            events = temp_events(1:event_count)
        else
            allocate(events(0))
        end if
    end subroutine sse_parse_events

    !> @brief Create event from type and data
    subroutine create_event(event_type, data, event)
        character(len=*), intent(in) :: event_type, data
        type(sse_event_t), intent(out) :: event

        select case (trim(event_type))
            case ("data")
                event%event_type = SSE_EVENT_DATA
                event%data = data

            case ("control")
                event%event_type = SSE_EVENT_CONTROL
                call sse_parse_control_event(data, event)

            case default
                event%event_type = SSE_EVENT_UNKNOWN
                event%data = data
        end select
    end subroutine create_event

    !> @brief Parse control event JSON data
    !>
    !> Control events contain JSON with stream metadata:
    !> {"streamNextOffset": "...", "streamCursor": "...", "upToDate": true}
    !>
    !> @param data JSON string
    !> @param event Output event with parsed fields
    subroutine sse_parse_control_event(data, event)
        character(len=*), intent(in) :: data
        type(sse_event_t), intent(inout) :: event

        type(json_file) :: json
        logical :: found

        call json%initialize()
        call json%deserialize(data)

        if (json%failed()) then
            call json%destroy()
            return
        end if

        ! Parse fields (using camelCase as per protocol spec)
        call json%get('streamNextOffset', event%offset, found)
        call json%get('streamCursor', event%cursor, found)
        call json%get('upToDate', event%up_to_date, found)

        call json%destroy()
    end subroutine sse_parse_control_event

    !> @brief Check if string starts with prefix
    function starts_with(str, prefix) result(yes)
        character(len=*), intent(in) :: str, prefix
        logical :: yes
        integer :: n
        n = len(prefix)
        if (len(str) >= n) then
            yes = str(1:n) == prefix
        else
            yes = .false.
        end if
    end function starts_with

    !> @brief Expand events array
    subroutine expand_events(events, max_size)
        type(sse_event_t), allocatable, intent(inout) :: events(:)
        integer, intent(inout) :: max_size
        type(sse_event_t), allocatable :: temp(:)

        allocate(temp(max_size * 2))
        temp(1:max_size) = events
        call move_alloc(temp, events)
        max_size = max_size * 2
    end subroutine expand_events

end module ds_sse
