!> @file ds_constants.f90
!> @brief Protocol constants for Durable Streams
!>
!> This module defines all the HTTP headers, query parameters, and other
!> constants used by the Durable Streams protocol. These follow the official
!> protocol specification at https://github.com/durable-streams/durable-streams
!>
!> @author Fortran Durable Streams Team
!> @date 2026

module ds_constants
    implicit none
    private

    ! Protocol version
    character(len=*), parameter, public :: DS_PROTOCOL_VERSION = "1.0"
    character(len=*), parameter, public :: DS_CLIENT_NAME = "fortran-durable-streams"
    character(len=*), parameter, public :: DS_CLIENT_VERSION = "1.0.0"

    ! HTTP Request Headers
    character(len=*), parameter, public :: HDR_STREAM_TTL = "Stream-TTL"
    character(len=*), parameter, public :: HDR_STREAM_EXPIRES_AT = "Stream-Expires-At"
    character(len=*), parameter, public :: HDR_STREAM_SEQ = "Stream-Seq"
    character(len=*), parameter, public :: HDR_CONTENT_TYPE = "Content-Type"

    ! HTTP Response Headers
    character(len=*), parameter, public :: HDR_STREAM_NEXT_OFFSET = "Stream-Next-Offset"
    character(len=*), parameter, public :: HDR_STREAM_CURSOR = "Stream-Cursor"
    character(len=*), parameter, public :: HDR_STREAM_UP_TO_DATE = "Stream-Up-To-Date"
    character(len=*), parameter, public :: HDR_ETAG = "ETag"
    character(len=*), parameter, public :: HDR_CACHE_CONTROL = "Cache-Control"

    ! Query Parameters
    character(len=*), parameter, public :: PARAM_OFFSET = "offset"
    character(len=*), parameter, public :: PARAM_LIVE = "live"
    character(len=*), parameter, public :: PARAM_CURSOR = "cursor"

    ! Live mode values
    character(len=*), parameter, public :: LIVE_NONE = "none"
    character(len=*), parameter, public :: LIVE_LONG_POLL = "long-poll"
    character(len=*), parameter, public :: LIVE_SSE = "sse"

    ! Default content types
    character(len=*), parameter, public :: CT_JSON = "application/json"
    character(len=*), parameter, public :: CT_TEXT = "text/plain"
    character(len=*), parameter, public :: CT_BINARY = "application/octet-stream"
    character(len=*), parameter, public :: CT_EVENT_STREAM = "text/event-stream"

    ! Special offset value
    character(len=*), parameter, public :: OFFSET_BEGINNING = "-1"

    ! HTTP Status Codes
    integer, parameter, public :: HTTP_OK = 200
    integer, parameter, public :: HTTP_CREATED = 201
    integer, parameter, public :: HTTP_NO_CONTENT = 204
    integer, parameter, public :: HTTP_NOT_MODIFIED = 304
    integer, parameter, public :: HTTP_BAD_REQUEST = 400
    integer, parameter, public :: HTTP_UNAUTHORIZED = 401
    integer, parameter, public :: HTTP_FORBIDDEN = 403
    integer, parameter, public :: HTTP_NOT_FOUND = 404
    integer, parameter, public :: HTTP_METHOD_NOT_ALLOWED = 405
    integer, parameter, public :: HTTP_CONFLICT = 409
    integer, parameter, public :: HTTP_GONE = 410
    integer, parameter, public :: HTTP_PAYLOAD_TOO_LARGE = 413
    integer, parameter, public :: HTTP_TOO_MANY_REQUESTS = 429
    integer, parameter, public :: HTTP_INTERNAL_ERROR = 500
    integer, parameter, public :: HTTP_SERVICE_UNAVAILABLE = 503

    ! Error codes (string constants for conformance test compatibility)
    character(len=*), parameter, public :: ERR_CODE_NONE = ""
    character(len=*), parameter, public :: ERR_CODE_NETWORK = "NETWORK_ERROR"
    character(len=*), parameter, public :: ERR_CODE_TIMEOUT = "TIMEOUT"
    character(len=*), parameter, public :: ERR_CODE_NOT_FOUND = "NOT_FOUND"
    character(len=*), parameter, public :: ERR_CODE_CONFLICT = "CONFLICT"
    character(len=*), parameter, public :: ERR_CODE_SEQUENCE = "SEQUENCE_CONFLICT"
    character(len=*), parameter, public :: ERR_CODE_INVALID_OFFSET = "INVALID_OFFSET"
    character(len=*), parameter, public :: ERR_CODE_PARSE = "PARSE_ERROR"
    character(len=*), parameter, public :: ERR_CODE_INTERNAL = "INTERNAL_ERROR"
    character(len=*), parameter, public :: ERR_CODE_NOT_SUPPORTED = "NOT_SUPPORTED"
    character(len=*), parameter, public :: ERR_CODE_BAD_REQUEST = "BAD_REQUEST"
    character(len=*), parameter, public :: ERR_CODE_UNEXPECTED = "UNEXPECTED_STATUS"

    ! Timeouts (milliseconds)
    integer, parameter, public :: DEFAULT_TIMEOUT_MS = 30000
    integer, parameter, public :: DEFAULT_LONGPOLL_TIMEOUT_MS = 60000

    ! Buffer sizes
    integer, parameter, public :: MAX_HEADER_SIZE = 8192
    integer, parameter, public :: MAX_URL_SIZE = 4096
    integer, parameter, public :: MAX_OFFSET_SIZE = 256
    integer, parameter, public :: MAX_ERROR_MSG_SIZE = 1024
    integer, parameter, public :: READ_BUFFER_SIZE = 65536

end module ds_constants
