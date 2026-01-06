# Conformance Tests Analysis

## Test Framework Overview

The conformance test suite is **language-agnostic**, using:
- Node.js test runner + subprocess adapters
- JSON-line protocol over stdin/stdout
- YAML-based test case definitions
- 60+ individual test cases across 18 test files

## Required Client Interface

The client must implement a command-line adapter communicating via JSON over stdin/stdout.

### Command Types (Input via stdin)

```json
{"type":"init","serverUrl":"http://localhost:3000"}
{"type":"create","path":"/stream","contentType":"text/plain","ttlSeconds":3600}
{"type":"append","path":"/stream","data":"hello","seq":1}
{"type":"read","path":"/stream","offset":"0","live":"long-poll","timeoutMs":5000}
{"type":"head","path":"/stream"}
{"type":"delete","path":"/stream"}
{"type":"shutdown"}
```

### Response Format (Output via stdout)

```json
{"type":"create","success":true,"status":201,"offset":"0"}
{"type":"read","success":true,"status":200,"chunks":[{"offset":"0","data":"hello"}],"upToDate":true}
{"type":"error","success":false,"commandType":"append","status":404,"errorCode":"NOT_FOUND","message":"Stream not found"}
```

### Required Operations

1. **init** - Initialize client with server URL
2. **create** - Create new stream
3. **append** - Append data to stream
4. **read** - Read from stream (with offset, live mode options)
5. **head** - Get stream metadata
6. **delete** - Delete stream
7. **shutdown** - Clean shutdown

### Init Response (Capabilities)

```json
{
  "type": "init",
  "success": true,
  "clientName": "fortran-durable-streams",
  "features": {
    "sse": true,
    "longpoll": true,
    "batching": false,
    "retry": true,
    "dynamicHeaders": false
  }
}
```

## Test Categories

### Producer Tests (Stream Creation & Writing)

| Test File | Test Count | Key Tests |
|-----------|------------|-----------|
| create-stream.yaml | 6 | Basic creation, content-type, idempotency, TTL |
| append-data.yaml | 7 | Text, binary, unicode, empty payload rejection |
| sequence-ordering.yaml | 6 | Sequence ordering, conflict detection |
| error-handling.yaml | 6 | 404 handling, deletion behavior |

### Consumer Tests (Stream Reading)

| Test File | Test Count | Key Tests |
|-----------|------------|-----------|
| read-catchup.yaml | 8 | Empty stream, multiple chunks, resume |
| read-longpoll.yaml | 5 | Wait for data, timeout, resume |
| read-sse.yaml | 10 | SSE events, unicode separators |
| offset-handling.yaml | 8 | Offset semantics, "-1" handling |
| offset-resumption.yaml | 6 | Monotonic offsets, exact resumption |
| message-ordering.yaml | 6 | Sequential ordering preservation |
| error-handling.yaml | 6 | Invalid offsets, non-existent streams |

### Lifecycle Tests

| Test File | Test Count | Key Tests |
|-----------|------------|-----------|
| stream-lifecycle.yaml | 6 | Full lifecycle, reconnection |
| headers-params.yaml | 7 | Custom headers on all operations |

## Standard Error Codes

```
NETWORK_ERROR    - Connection failed
TIMEOUT          - Operation timed out
CONFLICT         - Stream exists or sequence mismatch (409)
NOT_FOUND        - Stream missing (404)
SEQUENCE_CONFLICT - Sequence number too low (409)
INVALID_OFFSET   - Malformed offset (400)
UNEXPECTED_STATUS - Unexpected HTTP status
PARSE_ERROR      - Response parsing failed
INTERNAL_ERROR   - Client internal error
NOT_SUPPORTED    - Feature not implemented
```

## Key Behavioral Requirements

### Offset Handling
- Treat offsets as **opaque strings**
- Must be **monotonically increasing**
- Support **byte-exact resumption** (no gaps, no duplicates)
- Offset "-1" means "read from beginning"

### Sequence Numbers
- Optional but when used, must be monotonically increasing
- Non-consecutive sequences allowed (1, 10, 100)
- Server returns 409 SEQUENCE_CONFLICT on out-of-order

### Live Reading Modes
- **none**: Catch-up only, returns when up-to-date
- **long-poll**: Waits for new data, returns on timeout or data
- **sse**: Server-Sent Events stream, continuous connection

### Data Encoding
- Text data sent as UTF-8 strings
- Binary data sent as base64-encoded strings
- Must preserve all Unicode including separators (U+0085, U+2028, U+2029)

## Feature Flags

The client reports capabilities in init response:
- `sse`: Server-Sent Events support (10 tests)
- `longpoll`: Long-polling support (5 tests)
- `batching`: Automatic write batching (4 tests)
- `retry`: Automatic retry logic (7 tests)
- `dynamicHeaders`: Per-request dynamic headers (4 tests)

Tests requiring unsupported features are skipped.

## Core Tests (Must Pass)

These tests run regardless of feature flags:
- All create-stream tests
- All append-data tests (except batching)
- All sequence-ordering tests
- All error-handling tests
- read-catchup tests
- offset-handling tests
- offset-resumption tests
- message-ordering tests (basic)
- stream-lifecycle tests
- headers-params tests

**Estimated core tests: ~45 tests**
