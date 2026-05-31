## MCP Stdio Transport implementation using taskpools for concurrent request processing
##
## This module provides the stdio transport implementation for MCP servers.
## It handles JSON-RPC communication over stdin/stdout with concurrent request processing.

import json, locks, options
import std/[monotimes, times, os]
import taskpools, cpuinfo
import types, protocol, server, composed_server, logging

type 
  StdioTransport* = ref object
    ## Stdio transport implementation for MCP servers
    taskpool: Taskpool
    stdoutLock: Lock
    mcpTransport: McpTransport  # Persistent transport object

proc newStdioTransport*(numThreads: int = 0): StdioTransport =
  ## Args:
  ##   numThreads: Number of worker threads (0 = auto-detect)
  new(result)
  let threads = if numThreads > 0: numThreads else: countProcessors()
  result.taskpool = Taskpool.new(numThreads = threads)
  initLock(result.stdoutLock)
  result.mcpTransport = McpTransport(kind: tkStdio, capabilities: {})

proc safeEcho(transport: StdioTransport, msg: string) =
  ## Thread-safe output handling
  withLock transport.stdoutLock:
    echo msg
    stdout.flushFile()

# Request processing task for taskpools
proc processRequestTask[T](transport: ptr StdioTransport, server: ptr T, requestLine: string) {.gcsafe.} =
  var requestId: JsonRpcId = JsonRpcId(kind: jridString, str: "")
  try:
    let request = parseJsonRpcMessage(requestLine)
    if request.id.isSome():
      requestId = request.id.get
    if not request.id.isSome():
      # Use persistent transport object for notifications
      server[].handleNotification(transport[].mcpTransport, request)
    else:
      let response = server[].handleRequest(request)
      transport[].safeEcho($response)
  except Exception as e:
    let errorResponse = createJsonRpcError(requestId, ParseError, "Parse error: " & e.msg)
    transport[].safeEcho($(%errorResponse))


proc processRequestTask(transport: StdioTransport, server: McpServer, line: string) {.gcsafe.} =
  ## Had to extract this proc to avoid segfaults with taskpools and generics
  transport.taskpool.spawn processRequestTask[McpServer](addr transport, addr server, line)

proc handleLine[T: ComposedServer | McpServer](server: T, line: string) =
  ## Parse and handle one JSON-RPC line, echoing the response on stdout.
  var requestId: JsonRpcId = JsonRpcId(kind: jridString, str: "")
  try:
    let request = parseJsonRpcMessage(line)
    if request.id.isSome():
      requestId = request.id.get
    if not request.id.isSome():
      discard  # notification, no response
    else:
      let mcpTransport =
        McpTransport(kind: tkStdio, capabilities: {tcUnicast})
      echo $server.handleRequest(mcpTransport, request)
  except Exception as e:
    echo $(%createJsonRpcError(requestId, ParseError, "Parse error: " & e.msg))

# stdin is read on a dedicated thread so the main loop can do periodic work
# (the `idle` callback) between requests. Lines arrive on this channel; an
# empty string is the EOF sentinel.
var stdinChannel: Channel[string]

proc stdinReader() {.thread.} =
  while true:
    try:
      stdinChannel.send(stdin.readLine())
    except IOError, EOFError:
      stdinChannel.send("")  # signal EOF
      break

# Main stdio transport serving procedure
proc serve*[T: ComposedServer | McpServer](
    transport: StdioTransport, server: T,
    idle: proc() = nil, idleMs = 200,
) =
  ## Serve the MCP server with stdio transport. If `idle` is supplied it is
  ## called every ~`idleMs` between requests, letting the server do periodic
  ## background work (heartbeats, polling) on the main thread.
  server.logger.redirectToStderr()
  server.logger.info("Stdio transport started")

  if idle == nil:
    # Plain blocking loop — unchanged behavior for request-only servers.
    while true:
      try:
        let line = stdin.readLine()
        if line.len > 0:
          server.handleLine(line)
      except EOFError:
        break
      except Exception:
        break
    return

  stdinChannel.open()
  var reader: Thread[void]
  createThread(reader, stdinReader)
  var lastIdle = getMonoTime()
  var sawEof = false
  while not sawEof:
    let (gotLine, line) = stdinChannel.tryRecv()
    if gotLine:
      if line.len == 0:
        sawEof = true  # reader hit EOF
      else:
        server.handleLine(line)
    else:
      let now = getMonoTime()
      if (now - lastIdle).inMilliseconds >= idleMs:
        idle()
        lastIdle = now
      sleep 10

proc sendNotificationToSession*(transport: StdioTransport, sessionId: string, notificationType: string, data: JsonNode) {.gcsafe.} =
  ## Send MCP notification to session (for Stdio transport, there's only one session)
  ## The sessionId parameter is ignored as Stdio has only one client
  let notification = %*{
    "jsonrpc": "2.0",
    "method": "notifications/message",
    "params": %*{
      "type": notificationType,
      "data": data
    }
  }
  transport.safeEcho($notification)

