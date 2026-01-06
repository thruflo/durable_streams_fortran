# Durable Streams Client Implementation - Technical Analysis

## Overview

This document provides a detailed technical analysis of the TypeScript Durable Streams client implementation from https://github.com/durable-streams/durable-streams/tree/main/packages/client

**Source Files Analyzed:**
- index.ts (public API exports)
- types.ts (type definitions)
- stream.ts (DurableStream class)
- stream-api.ts (stream() function)
- fetch.ts (HTTP operations with retry)
- sse.ts (Server-Sent Events parsing)
- error.ts (error classes)
- response.ts (StreamResponse implementation)
- constants.ts (protocol constants)
- utils.ts (utility functions)
- asyncIterableReadableStream.ts (async iterator polyfill)

---

## 1. Client API Design and Interface

### Two-Tier API Architecture

The client provides two complementary APIs targeting different use cases:

#### A. `stream()` Function - Read-Only API

**Purpose:** Lightweight, fetch-like interface for read-only consumption

**Signature:**
```typescript
async function stream<TJson = unknown>(options: StreamOptions): Promise<StreamResponse<TJson>>
```

**Design Characteristics:**
- Stateless function call (no handle management)
- Returns a StreamResponse object for consuming data
- Automatic retry logic with configurable error handlers
- Single responsibility: reading from streams

**Example Usage:**
```typescript
const res = await stream<MyType>({
  url: 'https://api.example.com/stream/123',
  offset: '0_0',
  live: 'auto',
  headers: { Authorization: 'Bearer token' }
})
const items = await res.json()
```

#### B. `DurableStream` Class - Read/Write API

**Purpose:** Reusable handle for read/write operations

**Design Pattern:**
- Lightweight handle (not a persistent connection)
- Static factory methods for lifecycle management
- Instance methods for operations on existing streams

**Static Methods:**
```typescript
class DurableStream {
  // Create new stream
  static async create(options: DurableStreamCreateOptions): Promise<DurableStream>

  // Connect to existing stream
  static async connect(options: DurableStreamConnectOptions): Promise<DurableStream>

  // Get metadata without creating handle
  static async head(options: DurableStreamHeadOptions): Promise<DurableStreamMetadata>

  // Delete stream
  static async delete(options: DurableStreamDeleteOptions): Promise<void>
}
```

**Instance Methods:**
```typescript
// Write operations
async append(payload: DurableStreamPayload, options?: DurableStreamAppendOptions): Promise<void>
async appendStream(stream: ReadableStream | AsyncIterable, options?: DurableStreamAppendStreamOptions): Promise<void>
writable(options?: DurableStreamWritableOptions): WritableStream

// Read operations
stream<TJson = unknown>(options?: DurableStreamStreamOptions): Promise<StreamResponse<TJson>>
```

### StreamResponse Interface

**Core Design:** Provides three consumption patterns for maximum flexibility

```typescript
interface StreamResponse<TJson = unknown> {
  // 1. Promise-based accumulators (fetch all data)
  body(): Promise<Uint8Array>
  json(): Promise<TJson[]>
  text(): Promise<string>

  // 2. Stream-based APIs (native ReadableStream)
  bodyStream(): ReadableStream<ByteChunk>
  jsonStream(): ReadableStream<JsonBatch<TJson>>
  textStream(): ReadableStream<TextChunk>

  // 3. Subscriber callbacks (async iterator pattern)
  subscribeJson(callback: (batch: JsonBatch<TJson>) => MaybePromise<void>): Promise<void>
  subscribeBytes(callback: (chunk: ByteChunk) => MaybePromise<void>): Promise<void>
  subscribeText(callback: (chunk: TextChunk) => MaybePromise<void>): Promise<void>

  // State and control
  offset: string
  cursor?: string
  upToDate: boolean
  closed: Promise<void>
  cancel(): void
}
```

**Key Design Decisions:**

1. **Single Consumption Enforcement:** The implementation prevents multiple consumption patterns on the same response via `#ensureNoConsumption()` guard
2. **Lazy Evaluation:** All consumption methods work off the same internal `ReadableStream<Response>` that's created once
3. **Metadata Tracking:** offset, cursor, and upToDate are extracted from response headers and updated throughout the session

### Dynamic Headers and Parameters

**Pattern:** Support both static values and async functions

```typescript
type HeadersRecord = Record<string, string | (() => MaybePromise<string>)>
type ParamsRecord = Record<string, string | undefined | (() => MaybePromise<string | undefined>)>
```

**Rationale:** Functions are called **for each request**, enabling:
- Token refresh between requests
- Dynamic authentication
- Per-request parameter computation

**Implementation (from utils.ts):**
```typescript
async function resolveHeaders(headers?: HeadersRecord): Promise<Record<string, string>> {
  if (!headers) return {}
  const resolved: Record<string, string> = {}
  for (const [key, value] of Object.entries(headers)) {
    resolved[key] = typeof value === 'function' ? await value() : value
  }
  return resolved
}
```

---

## 2. Protocol Operations Implementation

### HTTP Method Mapping

The protocol uses standard HTTP methods with specific semantics:

| Operation | HTTP Method | Implementation | Purpose |
|-----------|-------------|----------------|---------|
| Create Stream | POST | `DurableStream.create()` | Initialize new stream with metadata |
| Write Data | POST | `append()`, `appendStream()` | Append data to stream |
| Read Data | GET | `stream()`, `DurableStream.stream()` | Fetch stream data |
| Get Metadata | HEAD | `DurableStream.head()` | Retrieve stream info without data |
| Delete Stream | DELETE | `DurableStream.delete()` | Remove stream |

### POST Implementation (Create & Append)

**Create Stream (DurableStream.create):**

```typescript
static async create(options: DurableStreamCreateOptions): Promise<DurableStream> {
  validateOptions(options)

  const response = await fetchWithConsumedBody(options.fetch || fetch, options.url, {
    method: 'POST',
    headers: {
      ...await resolveHeaders(options.headers),
      ...(options.contentType ? { 'Content-Type': options.contentType } : {}),
      ...(options.ttlSeconds ? { [STREAM_TTL_HEADER]: options.ttlSeconds.toString() } : {}),
      ...(options.expiresAt ? { [STREAM_EXPIRES_AT_HEADER]: options.expiresAt } : {})
    },
    body: encodeBody(options.initialData, options.contentType),
    signal: options.signal
  })

  if (!response.ok) {
    throw await FetchError.fromResponse(response)
  }

  return new DurableStream({ url: options.url, fetch: options.fetch, headers: options.headers })
}
```

**Key Features:**
- Sets Content-Type header
- Supports TTL via `x-electric-stream-ttl` or `x-electric-stream-expires-at` headers
- Can include initial data in creation request
- Returns handle after successful creation

**Append Operations with Batching:**

The client implements sophisticated batching using the `fastq` library:

```typescript
class DurableStream {
  #queue?: fastq.queueAsPromised<AppendTask, void>

  async append(payload: DurableStreamPayload, options?: DurableStreamAppendOptions): Promise<void> {
    if (options?.batch !== false && !this.#queue) {
      this.#queue = fastq.promise(this.#processBatch.bind(this), 1)
    }

    if (options?.batch === false || !this.#queue) {
      return this.#doAppend([payload], options)
    }

    return this.#queue.push({ payload, options })
  }

  async #processBatch(task: AppendTask): Promise<void> {
    const batch = [task.payload]

    // Drain queue while POST is in-flight
    while (this.#queue && this.#queue.length() > 0) {
      const next = this.#queue.shift()
      if (next) batch.push(next.value.payload)
    }

    return this.#doAppend(batch, task.options)
  }

  async #doAppend(payloads: DurableStreamPayload[], options?: DurableStreamAppendOptions): Promise<void> {
    const body = payloads.length === 1
      ? encodeBody(payloads[0], this.#contentType)
      : encodeBody(payloads, 'application/json')

    const response = await fetchWithConsumedBody(this.#fetch, this.#url, {
      method: 'POST',
      headers: {
        ...await resolveHeaders(this.#headers),
        'Content-Type': payloads.length === 1 ? this.#contentType : 'application/json',
        ...(options?.seq !== undefined ? { [STREAM_SEQ_HEADER]: options.seq.toString() } : {})
      },
      body,
      signal: options?.signal
    })

    if (!response.ok) {
      throw await DurableStreamError.fromResponse(response)
    }
  }
}
```

**Batching Strategy:**
1. When `append()` is called with batching enabled (default), task goes to queue
2. Queue processor (`#processBatch`) drains all pending items while POST is in-flight
3. Multiple payloads are combined into single JSON array
4. Significantly improves throughput for high-frequency writes

**Sequence Numbers:**
- Optional `seq` parameter in append options
- Sent via `x-electric-stream-seq` header
- Enables optimistic concurrency control
- Server rejects if sequence doesn't match expected value

### GET Implementation (Read Operations)

**Core Implementation (from stream-api.ts):**

```typescript
async function streamInternal<TJson>(options: StreamOptions, onError?: StreamErrorHandler): Promise<StreamResponse<TJson>> {
  validateOptions(options)

  const controller = new AbortController()
  const chained = chainAborter(controller, options.signal)

  // Resolve initial request parameters
  const url = new URL(options.url)
  const params = await resolveParams(options.params)
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) url.searchParams.set(key, value)
  }

  // Set offset for reading
  if (options.offset !== undefined) {
    url.searchParams.set(OFFSET_QUERY_PARAM, options.offset)
  }

  // First request
  const fetch = createFetchWithBackoff(
    options.fetch || globalThis.fetch,
    options.backoff
  )

  const headers = await resolveHeaders(options.headers)
  let response = await fetch(url.toString(), {
    method: 'GET',
    headers,
    signal: controller.signal
  })

  if (!response.ok) {
    await handleErrorResponse(response)
  }

  // Extract metadata from response headers
  const offset = response.headers.get(STREAM_OFFSET_HEADER) || '-1'
  const cursor = response.headers.get(STREAM_CURSOR_HEADER) || undefined
  const upToDate = response.headers.get(STREAM_UP_TO_DATE_HEADER) === 'true'
  const contentType = response.headers.get('content-type') || ''
  const jsonMode = contentType.includes('application/json')

  // Determine live mode
  const live = options.live ?? false

  // Create fetchNext function for subsequent requests
  const fetchNext = async (): Promise<Response> => {
    const nextUrl = new URL(options.url)
    const params = await resolveParams(options.params)
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined) nextUrl.searchParams.set(key, value)
    }

    nextUrl.searchParams.set(OFFSET_QUERY_PARAM, currentOffset)

    if (live === 'long-poll') {
      nextUrl.searchParams.set(LIVE_QUERY_PARAM, 'long-poll')
    } else if (live === 'sse') {
      nextUrl.searchParams.set(LIVE_QUERY_PARAM, 'sse')
    } else if (live === 'auto' || live === true) {
      nextUrl.searchParams.set(LIVE_QUERY_PARAM, 'auto')
    }

    const headers = await resolveHeaders(options.headers)
    return fetch(nextUrl.toString(), {
      method: 'GET',
      headers,
      signal: controller.signal
    })
  }

  // SSE handling if needed
  let startSSE: (() => Promise<Response>) | undefined
  if (live === 'sse' || live === 'auto' || live === true) {
    startSSE = async (): Promise<Response> => {
      // Similar to fetchNext but ensures SSE mode
      // ...
    }
  }

  return new StreamResponseImpl(response, controller, chained, fetchNext, startSSE, options.sseResilience, jsonMode)
}
```

**Query Parameters:**
- `offset`: Specifies starting position (via `OFFSET_QUERY_PARAM`)
- `live`: Controls streaming mode (`long-poll`, `sse`, `auto`)
- `cursor`: Optional cursor for CDN collapsing

**Response Headers:**
- `x-electric-stream-offset`: Next offset to read from
- `x-electric-stream-cursor`: Optional cursor value
- `x-electric-stream-up-to-date`: Boolean indicating if at stream end
- `content-type`: Determines JSON vs binary mode

### HEAD Implementation (Metadata Only)

```typescript
static async head(options: DurableStreamHeadOptions): Promise<DurableStreamMetadata> {
  validateOptions(options)

  const response = await fetchWithConsumedBody(options.fetch || fetch, options.url, {
    method: 'HEAD',
    headers: await resolveHeaders(options.headers),
    signal: options.signal
  })

  if (!response.ok) {
    throw await FetchError.fromResponse(response)
  }

  return {
    offset: response.headers.get(STREAM_OFFSET_HEADER) || '-1',
    cursor: response.headers.get(STREAM_CURSOR_HEADER) || undefined,
    upToDate: response.headers.get(STREAM_UP_TO_DATE_HEADER) === 'true',
    contentType: response.headers.get('content-type') || undefined
  }
}
```

**Use Cases:**
- Check if stream exists
- Get current offset without reading data
- Verify stream is up-to-date

### DELETE Implementation

```typescript
static async delete(options: DurableStreamDeleteOptions): Promise<void> {
  validateOptions(options)

  const response = await fetchWithConsumedBody(options.fetch || fetch, options.url, {
    method: 'DELETE',
    headers: await resolveHeaders(options.headers),
    signal: options.signal
  })

  if (!response.ok) {
    throw await FetchError.fromResponse(response)
  }
}
```

---

## 3. Streaming Implementation (Long-Poll, SSE)

### Streaming Architecture

The client supports three live modes:
1. **long-poll**: Server holds request until new data or timeout
2. **sse**: Server-Sent Events for real-time streaming
3. **auto**: Client chooses best mode (tries SSE, falls back to long-poll)

### Long-Polling Implementation

**Pattern:** Continuous GET requests with server-side hold

```typescript
// In StreamResponseImpl
async #createResponseStream(): Promise<ReadableStream<Response>> {
  return new ReadableStream<Response>({
    start: async (controller) => {
      try {
        let currentResponse = this.#initialResponse

        while (true) {
          // Enqueue current response
          controller.enqueue(currentResponse)

          // Extract metadata
          const upToDate = currentResponse.headers.get(STREAM_UP_TO_DATE_HEADER) === 'true'
          this.#offset = currentResponse.headers.get(STREAM_OFFSET_HEADER) || this.#offset
          this.#cursor = currentResponse.headers.get(STREAM_CURSOR_HEADER) || undefined
          this.#upToDate = upToDate

          // If up-to-date and not in live mode, we're done
          if (upToDate && !this.#fetchNext) {
            controller.close()
            return
          }

          // If up-to-date but in live mode, fetch next (server will hold)
          if (upToDate && this.#fetchNext) {
            currentResponse = await this.#fetchNext()
            continue
          }

          // More data available, fetch immediately
          if (!upToDate && this.#fetchNext) {
            currentResponse = await this.#fetchNext()
            continue
          }

          // No more data and no live mode
          controller.close()
          return
        }
      } catch (error) {
        controller.error(error)
      }
    }
  })
}
```

**Flow:**
1. Make GET request with `?live=long-poll`
2. Server holds connection until:
   - New data arrives
   - Timeout reached (returns current state with `up-to-date: true`)
3. Client receives response, extracts data and metadata
4. If `up-to-date: false`, more data is available - fetch immediately
5. If `up-to-date: true` in live mode, make new request (server holds again)

### Server-Sent Events (SSE) Implementation

**SSE Protocol:** Dedicated event stream with real-time updates

**Event Types (from sse.ts):**
```typescript
interface SSEDataEvent {
  type: 'data'
  data: string
}

interface SSEControlEvent {
  type: 'control'
  streamNextOffset: string
  streamCursor?: string
  upToDate?: boolean
}
```

**SSE Parser (from sse.ts):**

```typescript
async function* parseSSEStream(stream: ReadableStream<Uint8Array>): AsyncGenerator<SSEDataEvent | SSEControlEvent> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()

  try {
    let buffer = ''
    let eventType = ''
    let eventData = ''

    while (true) {
      const { done, value } = await reader.read()

      if (done) {
        // Process remaining buffer
        if (buffer) {
          const lines = buffer.split('\n')
          for (const line of lines) {
            if (line === '') {
              // Emit event
              if (eventType && eventData) {
                yield createEvent(eventType, eventData)
                eventType = ''
                eventData = ''
              }
            } else if (line.startsWith('event:')) {
              eventType = line.slice(6).trim()
            } else if (line.startsWith('data:')) {
              // Strip optional leading space per SSE spec
              const data = line.slice(5)
              eventData += (data.startsWith(' ') ? data.slice(1) : data) + '\n'
            }
          }
        }
        break
      }

      buffer += decoder.decode(value, { stream: true })

      // Process complete lines
      const lines = buffer.split('\n')
      buffer = lines.pop() || ''

      for (const line of lines) {
        if (line === '') {
          // Empty line signals event completion
          if (eventType && eventData) {
            // Remove trailing newline
            eventData = eventData.slice(0, -1)

            if (eventType === 'control') {
              try {
                const parsed = JSON.parse(eventData)
                yield { type: 'control', ...parsed }
              } catch {
                // Invalid control event, skip
              }
            } else if (eventType === 'data') {
              yield { type: 'data', data: eventData }
            }

            eventType = ''
            eventData = ''
          }
        } else if (line.startsWith('event:')) {
          eventType = line.slice(6).trim()
        } else if (line.startsWith('data:')) {
          const data = line.slice(5)
          eventData += (data.startsWith(' ') ? data.slice(1) : data) + '\n'
        }
      }
    }
  } finally {
    reader.releaseLock()
  }
}
```

**SSE Stream Processing (in StreamResponseImpl):**

```typescript
async #processSSEStream(sseResponse: Response): Promise<ReadableStream<Response>> {
  if (!sseResponse.body) {
    throw new Error('SSE response has no body')
  }

  return new ReadableStream<Response>({
    start: async (controller) => {
      try {
        const sseStream = parseSSEStream(sseResponse.body!)

        for await (const event of sseStream) {
          if (event.type === 'control') {
            // Update metadata from control events
            this.#offset = event.streamNextOffset
            this.#cursor = event.streamCursor
            this.#upToDate = event.upToDate ?? false
          } else if (event.type === 'data') {
            // Create mock Response with data
            const response = new Response(event.data, {
              headers: {
                'content-type': 'application/json',
                [STREAM_OFFSET_HEADER]: this.#offset,
                [STREAM_CURSOR_HEADER]: this.#cursor || '',
                [STREAM_UP_TO_DATE_HEADER]: this.#upToDate ? 'true' : 'false'
              }
            })
            controller.enqueue(response)
          }
        }

        controller.close()
      } catch (error) {
        controller.error(error)
      }
    }
  })
}
```

**SSE Flow:**
1. Make GET request with `?live=sse`
2. Server responds with `content-type: text/event-stream`
3. Connection remains open, server pushes events:
   - `control` events: Update offset, cursor, upToDate status
   - `data` events: Actual stream data
4. Client parses SSE protocol and yields data chunks

### SSE Resilience and Fallback

**Problem:** SSE connections may fail or be unstable

**Solution:** Automatic fallback to long-polling

```typescript
interface SSEResilienceOptions {
  minConnectionDuration?: number  // Default: 10000ms
  maxShortConnections?: number     // Default: 3
}

class StreamResponseImpl {
  #sseShortConnectionCount = 0
  #sseConnectionStart?: number

  async #handleSSEResilience(sseResponse: Response): Promise<void> {
    this.#sseConnectionStart = Date.now()

    try {
      await this.#processSSEStream(sseResponse)
    } finally {
      const connectionDuration = Date.now() - this.#sseConnectionStart
      const minDuration = this.#sseResilience?.minConnectionDuration ?? 10000

      if (connectionDuration < minDuration) {
        this.#sseShortConnectionCount++

        const maxShort = this.#sseResilience?.maxShortConnections ?? 3
        if (this.#sseShortConnectionCount >= maxShort) {
          // Too many short connections, fall back to long-polling
          this.#startSSE = undefined
          console.warn('SSE connections unstable, falling back to long-polling')
        }
      } else {
        // Connection was stable, reset counter
        this.#sseShortConnectionCount = 0
      }
    }
  }
}
```

**Resilience Strategy:**
1. Track connection duration for each SSE session
2. If connection terminates before `minConnectionDuration` (default: 10s), increment counter
3. After `maxShortConnections` (default: 3) short connections, disable SSE
4. Fall back to long-polling for remaining session
5. Reset counter on stable connections

### Auto Mode

**Behavior:** Client tries SSE first, server decides if supported

```typescript
// Client requests auto mode
nextUrl.searchParams.set(LIVE_QUERY_PARAM, 'auto')

// Server responses:
// - If SSE supported: Returns text/event-stream
// - If SSE not supported: Returns application/json with long-poll behavior
```

**Detection:**
```typescript
if (response.headers.get('content-type')?.includes('text/event-stream')) {
  // Use SSE processing
  return this.#processSSEStream(response)
} else {
  // Use long-poll processing
  return this.#createResponseStream()
}
```

---

## 4. Error Handling Patterns

### Error Class Hierarchy

```typescript
// Base HTTP error
class FetchError extends Error {
  readonly status: number
  readonly statusText: string
  readonly headers: Headers
  readonly body: string | Record<string, unknown> | null

  static async fromResponse(response: Response): Promise<FetchError> {
    const contentType = response.headers.get('content-type') || ''
    let body: string | Record<string, unknown> | null = null

    if (contentType.includes('application/json')) {
      try {
        body = await response.json()
      } catch {
        body = await response.text()
      }
    } else {
      body = await response.text()
    }

    return new FetchError(
      `HTTP ${response.status}: ${response.statusText}`,
      response.status,
      response.statusText,
      response.headers,
      body
    )
  }
}

// Retry abort error
class FetchBackoffAbortError extends Error {
  constructor() {
    super('Fetch with backoff was aborted')
    this.name = 'FetchBackoffAbortError'
  }
}

// Protocol-level error with semantic codes
class DurableStreamError extends Error {
  readonly code: DurableStreamErrorCode
  readonly status?: number
  readonly details?: unknown

  static async fromResponse(response: Response): Promise<DurableStreamError> {
    const fetchError = await FetchError.fromResponse(response)
    return new DurableStreamError(fetchError.message, this.#mapStatusToCode(fetchError.status), fetchError.status, fetchError.body)
  }

  static #mapStatusToCode(status: number): DurableStreamErrorCode {
    switch (status) {
      case 400: return 'BAD_REQUEST'
      case 401: return 'UNAUTHORIZED'
      case 403: return 'FORBIDDEN'
      case 404: return 'NOT_FOUND'
      case 409: return 'CONFLICT_SEQ'
      case 429: return 'RATE_LIMITED'
      case 503: return 'BUSY'
      default: return 'UNKNOWN'
    }
  }
}

type DurableStreamErrorCode =
  | 'BAD_REQUEST'
  | 'UNAUTHORIZED'
  | 'FORBIDDEN'
  | 'NOT_FOUND'
  | 'CONFLICT_SEQ'
  | 'RATE_LIMITED'
  | 'BUSY'
  | 'UNKNOWN'
```

### Retry Logic with Exponential Backoff

**Implementation (from fetch.ts):**

```typescript
interface BackoffOptions {
  initialDelay?: number      // Default: 1000ms
  maxDelay?: number          // Default: 30000ms
  multiplier?: number        // Default: 2
  maxRetries?: number        // Default: Infinity
  onRetry?: (attempt: number, delay: number, error: Error) => void
  onGiveUp?: (error: Error) => void
  debug?: boolean
}

function createFetchWithBackoff(
  fetch: typeof globalThis.fetch,
  options?: BackoffOptions
): typeof globalThis.fetch {
  return async (input, init) => {
    const initialDelay = options?.initialDelay ?? 1000
    const maxDelay = options?.maxDelay ?? 30000
    const multiplier = options?.multiplier ?? 2
    const maxRetries = options?.maxRetries ?? Infinity

    let attempt = 0
    let delay = initialDelay

    while (true) {
      try {
        const response = await fetch(input, init)

        // Success or non-retryable error
        if (response.ok || (response.status < 500 && response.status !== 429)) {
          return response
        }

        // Retryable error (429, 503, etc.)
        attempt++

        if (attempt >= maxRetries) {
          options?.onGiveUp?.(new Error(`Max retries (${maxRetries}) exceeded`))
          return response
        }

        // Parse Retry-After header
        const retryAfter = parseRetryAfterHeader(response.headers.get('retry-after'))
        const backoffDelay = Math.min(delay, maxDelay)
        const actualDelay = Math.max(retryAfter ?? 0, backoffDelay)

        // Full jitter
        const jitteredDelay = Math.random() * actualDelay

        options?.onRetry?.(attempt, jitteredDelay, new Error(`HTTP ${response.status}`))

        if (options?.debug) {
          console.log(`Retry attempt ${attempt} after ${jitteredDelay}ms`)
        }

        await new Promise(resolve => setTimeout(resolve, jitteredDelay))

        delay *= multiplier

      } catch (error) {
        if (init?.signal?.aborted) {
          throw new FetchBackoffAbortError()
        }

        attempt++

        if (attempt >= maxRetries) {
          options?.onGiveUp?.(error as Error)
          throw error
        }

        const backoffDelay = Math.min(delay, maxDelay)
        const jitteredDelay = Math.random() * backoffDelay

        options?.onRetry?.(attempt, jitteredDelay, error as Error)

        await new Promise(resolve => setTimeout(resolve, jitteredDelay))

        delay *= multiplier
      }
    }
  }
}

function parseRetryAfterHeader(value: string | null): number | null {
  if (!value) return null

  // Try as seconds
  const seconds = parseInt(value, 10)
  if (!isNaN(seconds)) {
    // Clamp to reasonable bounds (0-300 seconds)
    return Math.max(0, Math.min(seconds * 1000, 300000))
  }

  // Try as HTTP date
  try {
    const date = new Date(value)
    const delay = date.getTime() - Date.now()
    // Clamp to reasonable bounds
    return Math.max(0, Math.min(delay, 300000))
  } catch {
    return null
  }
}
```

**Retry Strategy:**
1. Retry on 429 (rate limited), 503 (busy), and network errors
2. Don't retry on 4xx errors (except 429) or 2xx/3xx
3. Exponential backoff with full jitter to prevent thundering herd
4. Respect server's `Retry-After` header
5. Configurable max retries (default: infinite)
6. Abort signal support

### User-Defined Error Handlers

**Pattern:** Allow users to provide custom retry logic

```typescript
type StreamErrorHandler = (error: Error) => MaybePromise<{
  headers?: HeadersRecord
  params?: ParamsRecord
} | undefined>

// Usage in stream() function
export async function stream<TJson = unknown>(options: StreamOptions): Promise<StreamResponse<TJson>> {
  let attempt = 0

  while (true) {
    try {
      return await streamInternal<TJson>(options)
    } catch (error) {
      if (error instanceof FetchBackoffAbortError) {
        throw error
      }

      if (options.onError) {
        const result = await options.onError(error as Error)

        if (result === undefined) {
          // Propagate error
          throw error
        }

        // Retry with new headers/params
        options = {
          ...options,
          headers: { ...options.headers, ...result.headers },
          params: { ...options.params, ...result.params }
        }

        attempt++
        continue
      }

      throw error
    }
  }
}
```

**Use Cases:**
- Token refresh on 401 errors
- Retry with different parameters
- Custom logging and metrics
- Circuit breaker patterns

### Context-Aware Error Messages

```typescript
async function handleErrorResponse(response: Response): Promise<never> {
  const error = await DurableStreamError.fromResponse(response)

  // Add context to error messages
  if (response.status === 404) {
    throw new DurableStreamError(
      'Stream not found. Use DurableStream.create() to create it first.',
      'NOT_FOUND',
      404,
      error.details
    )
  }

  if (response.status === 409) {
    const bodyText = typeof error.details === 'string' ? error.details : JSON.stringify(error.details)
    if (bodyText.includes('already exists')) {
      throw new DurableStreamError(
        'Stream already exists. Use DurableStream.connect() instead of create().',
        'CONFLICT_SEQ',
        409,
        error.details
      )
    } else {
      throw new DurableStreamError(
        'Sequence number conflict. Another writer may have modified the stream.',
        'CONFLICT_SEQ',
        409,
        error.details
      )
    }
  }

  if (response.status === 400) {
    throw new DurableStreamError(
      'Bad request. Check your request parameters and payload.',
      'BAD_REQUEST',
      400,
      error.details
    )
  }

  throw error
}
```

### Graceful Cancellation

**AbortSignal Support:**

```typescript
// Chaining abort signals
function chainAborter(controller: AbortController, source?: AbortSignal): () => void {
  if (!source) return () => {}

  const onAbort = () => controller.abort()

  if (source.aborted) {
    controller.abort()
  } else {
    source.addEventListener('abort', onAbort)
  }

  return () => source.removeEventListener('abort', onAbort)
}

// Usage in streaming
class StreamResponseImpl {
  cancel(): void {
    this.#controller.abort()
  }

  get closed(): Promise<void> {
    return this.#closed
  }
}
```

---

## 5. State Management

### Offset-Based State Model

**Core Concept:** Stream position is tracked via opaque offset tokens

**Offset Format:** `"<read-seq>_<byte-offset>"` (but treated as opaque by client)

**Special Values:**
- `"-1"`: Beginning of stream
- Undefined: Not yet known

**State Flow:**

```typescript
class StreamResponseImpl {
  #offset: string           // Current stream position
  #cursor?: string         // Optional CDN cursor
  #upToDate: boolean       // At end of stream?

  // Updated from response headers
  #getMetadataFromResponse(response: Response): { offset: string; cursor?: string; upToDate: boolean } {
    return {
      offset: response.headers.get(STREAM_OFFSET_HEADER) || this.#offset,
      cursor: response.headers.get(STREAM_CURSOR_HEADER) || undefined,
      upToDate: response.headers.get(STREAM_UP_TO_DATE_HEADER) === 'true'
    }
  }

  // Public accessors
  get offset(): string {
    return this.#offset
  }

  get cursor(): string | undefined {
    return this.#cursor
  }

  get upToDate(): boolean {
    return this.#upToDate
  }
}
```

**Resumable Reads:**

```typescript
// Read from beginning
const res1 = await stream({ url, offset: '-1' })

// Save offset
const items1 = await res1.json()
const savedOffset = res1.offset

// Later: resume from saved offset
const res2 = await stream({ url, offset: savedOffset })
const items2 = await res2.json()
```

### Stream Lifecycle State

**DurableStream Handle State:**

```typescript
class DurableStream {
  readonly #url: string
  readonly #fetch: typeof fetch
  readonly #headers?: HeadersRecord
  readonly #contentType: string = 'application/json'
  #queue?: fastq.queueAsPromised<AppendTask, void>

  // Lifecycle
  static async create()    // Creates stream, returns handle
  static async connect()   // Connects to existing, returns handle
  static async delete()    // Deletes stream, no handle

  // Handle is reusable
  async append()           // Stateless write
  async stream()           // New read session each call
}
```

**Key Design:**
- Handles are lightweight (just URL + options)
- No persistent connection state
- Each operation is independent
- Batching queue is transient state for optimization

### Session State (StreamResponse)

**StreamResponse Lifecycle:**

```typescript
class StreamResponseImpl {
  // Immutable configuration
  readonly #initialResponse: Response
  readonly #controller: AbortController
  readonly #fetchNext?: () => Promise<Response>
  readonly #startSSE?: () => Promise<Response>

  // Mutable state
  #offset: string
  #cursor?: string
  #upToDate: boolean
  #consumed = false
  #responseStream?: ReadableStream<Response>
  #closed: Promise<void>
  #sseShortConnectionCount = 0

  // State transitions
  #ensureNoConsumption(): void {
    if (this.#consumed) {
      throw new Error('StreamResponse has already been consumed')
    }
    this.#consumed = true
  }

  // Cleanup
  cancel(): void {
    this.#controller.abort()
    this.#resolveClose()
  }
}
```

**State Invariants:**
1. Single consumption: Once a consumption method is called, no other can be used
2. Offset monotonicity: Offset only moves forward
3. upToDate finality: Once true (in non-live mode), stream is done
4. Cancellation idempotency: Multiple cancel() calls are safe

### Batching Queue State

**Queue Management:**

```typescript
interface AppendTask {
  payload: DurableStreamPayload
  options?: DurableStreamAppendOptions
}

class DurableStream {
  #queue?: fastq.queueAsPromised<AppendTask, void>

  async append(payload: DurableStreamPayload, options?: DurableStreamAppendOptions): Promise<void> {
    // Lazy queue creation
    if (options?.batch !== false && !this.#queue) {
      this.#queue = fastq.promise(this.#processBatch.bind(this), 1)
    }

    // Queue or direct
    if (options?.batch === false || !this.#queue) {
      return this.#doAppend([payload], options)
    }

    return this.#queue.push({ payload, options })
  }

  async #processBatch(task: AppendTask): Promise<void> {
    const batch = [task.payload]

    // Drain queue atomically
    while (this.#queue && this.#queue.length() > 0) {
      const next = this.#queue.shift()
      if (next) batch.push(next.value.payload)
    }

    return this.#doAppend(batch, task.options)
  }
}
```

**Queue State Transitions:**
1. No queue: Direct POST
2. Queue created on first append() call
3. Items enqueued while POST in flight
4. Batch processor drains queue atomically
5. Combined POST sent with all batched items

### Connection State (SSE Resilience)

**SSE Health Tracking:**

```typescript
class StreamResponseImpl {
  #sseShortConnectionCount = 0
  #sseConnectionStart?: number
  #startSSE?: () => Promise<Response>  // Undefined = SSE disabled

  async #handleSSE(): Promise<void> {
    this.#sseConnectionStart = Date.now()

    try {
      await this.#processSSEStream(response)
    } finally {
      const duration = Date.now() - this.#sseConnectionStart

      if (duration < (this.#sseResilience?.minConnectionDuration ?? 10000)) {
        this.#sseShortConnectionCount++

        if (this.#sseShortConnectionCount >= (this.#sseResilience?.maxShortConnections ?? 3)) {
          this.#startSSE = undefined  // Disable SSE
        }
      } else {
        this.#sseShortConnectionCount = 0  // Reset on stable connection
      }
    }
  }
}
```

**State Machine:**
```
SSE Enabled ──short connection──> Increment Counter
     │                                      │
     │                                      ├──count < max──> SSE Enabled
     │                                      │
     │                                      └──count >= max──> SSE Disabled (Long-Poll)
     │
     └──stable connection (>10s)──> Reset Counter
```

---

## Key Implementation Patterns Summary

### 1. Dual API Design
- **Read-only:** Lightweight `stream()` function
- **Read-write:** `DurableStream` class with handles
- Both share common `StreamResponse` for consumption

### 2. Progressive Enhancement
- Start with simple GET requests
- Add live mode for real-time
- Try SSE, fallback to long-poll
- Automatic resilience management

### 3. Separation of Concerns
- **fetch.ts:** Transport layer with retry
- **sse.ts:** Protocol parsing
- **response.ts:** Consumption patterns
- **stream.ts:** High-level operations
- **error.ts:** Error handling
- **utils.ts:** Common utilities

### 4. Composable Fetch Middleware
```typescript
const baseFetch = options.fetch || globalThis.fetch
const fetchWithBackoff = createFetchWithBackoff(baseFetch, backoffOptions)
const fetchWithConsumedBody = createFetchWithConsumedBody(fetchWithBackoff)
```

### 5. TypeScript Generics for Type Safety
```typescript
const res = await stream<MyType>({ url })
const items: MyType[] = await res.json()  // Type-safe
```

### 6. Polyfill Pattern for Compatibility
```typescript
// Safari doesn't support async iteration on ReadableStream
const iterableStream = asAsyncIterableReadableStream(stream)
for await (const chunk of iterableStream) {
  // Works in all browsers
}
```

### 7. Single Responsibility Classes
- `DurableStream`: Stream handle operations
- `StreamResponseImpl`: Consumption session
- `FetchError`, `DurableStreamError`: Error types
- Each class has clear, focused purpose

### 8. Functional Utilities
- Pure functions for transformation
- Async-aware helpers (`resolveHeaders`, `resolveParams`)
- Composable building blocks

---

## Protocol Constants Reference

```typescript
// Response Headers
const STREAM_OFFSET_HEADER = 'x-electric-stream-offset'
const STREAM_CURSOR_HEADER = 'x-electric-stream-cursor'
const STREAM_UP_TO_DATE_HEADER = 'x-electric-stream-up-to-date'

// Request Headers
const STREAM_SEQ_HEADER = 'x-electric-stream-seq'
const STREAM_TTL_HEADER = 'x-electric-stream-ttl'
const STREAM_EXPIRES_AT_HEADER = 'x-electric-stream-expires-at'

// Query Parameters
const OFFSET_QUERY_PARAM = 'offset'
const LIVE_QUERY_PARAM = 'live'
const CURSOR_QUERY_PARAM = 'cursor'

// SSE Event Fields
const SSE_OFFSET_FIELD = 'streamNextOffset'
const SSE_CURSOR_FIELD = 'streamCursor'
const SSE_UP_TO_DATE_FIELD = 'upToDate'
```

---

## Design Principles Observed

1. **Simplicity First:** Basic usage is straightforward, advanced features are opt-in
2. **Type Safety:** Full TypeScript support with generics
3. **Robustness:** Automatic retry, fallback, and error recovery
4. **Flexibility:** Multiple consumption patterns, custom fetch clients, dynamic headers
5. **Performance:** Automatic batching, streaming, backpressure support
6. **Browser Compatibility:** Polyfills for Safari, works with fetch API
7. **Testability:** Dependency injection (custom fetch), clear interfaces
8. **Observability:** Callbacks for retry events, debug logging, error details
9. **Standards Compliance:** Uses fetch API, ReadableStream, async iterators, SSE protocol
10. **Minimal Dependencies:** Only `fastq` for batching queue

---

## Recommendations for Fortran Implementation

Based on this analysis, here are key patterns to adapt:

### 1. Dual API Approach
- Provide both functional and OOP interfaces
- `durable_stream_read()` for simple cases
- `type(durable_stream)` for read/write operations

### 2. Offset-Based Resumption
- Treat offsets as opaque strings
- Store in state, pass in subsequent requests
- Never parse or construct offset values

### 3. Streaming Modes
- Implement long-polling first (simpler)
- Add SSE support later if needed
- Auto mode: try SSE, fall back to long-poll

### 4. Error Handling
- Map HTTP status codes to semantic error types
- Implement exponential backoff with jitter
- Respect Retry-After headers
- Provide user error handlers for custom logic

### 5. Batching
- Queue writes during in-flight POST
- Combine into JSON array
- Configurable (allow disabling)

### 6. State Management
- Session state: offset, cursor, upToDate
- Handle state: URL, headers, options
- Queue state: pending writes
- Connection state: SSE health

### 7. Type Safety
- Use Fortran's type system
- Generic procedures where applicable
- Clear interfaces and contracts

### 8. Testing Considerations
- Allow custom HTTP client (dependency injection)
- Mock responses for unit tests
- Test retry logic with failing requests
- Test SSE fallback scenarios

---

## File Organization Map

```
client/
├── src/
│   ├── index.ts              # Public API exports
│   ├── types.ts              # Type definitions
│   ├── constants.ts          # Protocol constants
│   ├── stream-api.ts         # stream() function
│   ├── stream.ts             # DurableStream class
│   ├── response.ts           # StreamResponse implementation
│   ├── fetch.ts              # HTTP utilities with retry
│   ├── sse.ts                # SSE parsing
│   ├── error.ts              # Error classes
│   ├── utils.ts              # Helper functions
│   └── asyncIterableReadableStream.ts  # Polyfill
└── test/                     # Test files
```

---

## Conclusion

The Durable Streams TypeScript client is a well-architected implementation demonstrating:

- **Clean API design** with progressive complexity
- **Robust streaming** with multiple modes and automatic fallback
- **Sophisticated error handling** with retry logic and custom handlers
- **Efficient state management** using offset-based resumption
- **Performance optimizations** through batching and streaming
- **High compatibility** with polyfills and standards compliance

These patterns provide excellent guidance for implementing a Fortran client that maintains protocol compatibility while leveraging Fortran's strengths in performance and type safety.
