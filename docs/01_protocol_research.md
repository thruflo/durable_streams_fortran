# Durable Streams Protocol Research Summary

## Overview

Durable Streams is an HTTP-based protocol for creating and managing append-only byte streams. It provides a minimal interface designed for applications requiring ordered, replayable data sequences - perfect for AI applications, event sourcing, and real-time data pipelines.

## Core Stream Properties

1. **Durability**: Data persists after acknowledgment until deletion or expiration
2. **Position Immutability**: Bytes at specific positions never change; only appends occur
3. **Ordering**: Bytes maintain strict offset-based ordering
4. **Content Type**: Each stream has a declared MIME type set during creation

## HTTP Operations

### 1. Create Stream (PUT)
- Establishes a new stream at a specified URL
- Headers: `Content-Type`, `Stream-TTL`, `Stream-Expires-At`
- Response: 201 Created, 200 OK (idempotent), 409 Conflict

### 2. Append to Stream (POST)
- Adds bytes to stream's end
- Required: `Content-Type` must match stream's type
- Optional: `Stream-Seq` for sequence ordering
- Response: 204 No Content, 400 Bad Request (empty body), 409 Conflict

### 3. Delete Stream (DELETE)
- Removes stream and all data
- Response: 204 No Content, 404 Not Found

### 4. Stream Metadata (HEAD)
- Queries existence and metadata without data transfer
- Response Headers: `Content-Type`, `Stream-Next-Offset`, `Stream-TTL`, `Stream-Expires-At`

### 5. Read Stream - Catch-up (GET)
- Retrieves bytes from specified offset
- Query: `offset` (default: stream beginning)
- Response Headers: `Stream-Next-Offset`, `Stream-Up-To-Date`, `ETag`, `Stream-Cursor`

### 6. Read Stream - Long-poll (GET)
- Waits for new data if none available
- Query: `offset` (required), `live=long-poll`
- Response: 200 OK (data), 204 No Content (timeout)

### 7. Read Stream - Server-Sent Events (GET)
- Continuous streaming via SSE protocol
- Query: `offset` (required), `live=sse`
- Valid only for `text/*` or `application/json` streams
- Events: `data` (actual content), `control` (metadata)

## Offset System

- **Opaque**: Clients must not interpret internal structure
- **Lexicographically Sortable**: Comparison determines relative position
- **Persistent**: Remain valid throughout stream lifetime
- **Unique & Strictly Increasing**: Each position has exactly one offset
- **Sentinel Value**: `-1` represents stream beginning

## JSON Content Type Semantics

- **Message Flattening**: Arrays in POST bodies flatten one level
- **Empty Array Rejection**: Servers reject `[]` with 400 Bad Request
- **Response Format**: GET responses return JSON array of all messages

## Protocol Headers

### Request Headers
| Header | Purpose |
|--------|---------|
| `Stream-TTL` | Relative time-to-live in seconds |
| `Stream-Expires-At` | Absolute RFC 3339 expiration timestamp |
| `Stream-Seq` | Monotonic writer sequence number |

### Response Headers
| Header | Purpose |
|--------|---------|
| `Stream-Next-Offset` | Next read position |
| `Stream-Cursor` | CDN collapsing support |
| `Stream-Up-To-Date` | Boolean indicating catch-up complete |

## Error Handling

### HTTP Status Codes
- `200 OK`: Success with body
- `201 Created`: Stream created
- `204 No Content`: Success, no body
- `400 Bad Request`: Invalid request
- `404 Not Found`: Stream doesn't exist
- `409 Conflict`: Sequence mismatch or stream exists
- `429 Too Many Requests`: Rate limited
- `503 Service Unavailable`: Server busy

### Retry Strategy
- Retry on: 429, 503, 5xx errors
- Don't retry on: 4xx (except 429)
- Use exponential backoff with jitter
- Respect `Retry-After` header

## Key Implementation Insights

1. **Offsets are opaque** - never parse them, store and pass through
2. **Sequence numbers** - optional but enable concurrency control
3. **Batching** - combine multiple appends into single POST for efficiency
4. **SSE fallback** - track connection health, fall back to long-poll if unstable
5. **Idempotency** - CREATE is idempotent, returns 200 on subsequent calls
