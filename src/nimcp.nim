## NimCP - Easy Model Context Protocol (MCP) server implementation for Nim
## 
## This module provides a high-level, macro-based API for creating MCP servers
## that integrate seamlessly with LLM applications.

import nimcp/[types, protocol, server, mcpmacros, mummy_transport, websocket_transport, sse_transport, stdio_transport, context, schema, resource_templates, logging, cli]

export types, server, protocol, mummy_transport, websocket_transport, sse_transport, stdio_transport, context, schema, resource_templates, cli
# Log-level names (info/debug/warn/...) collide with the host app's logger
# (e.g. chronicles). Keep the logging types/config but not the bare emitters.
export logging except trace, debug, info, warn, error, fatal
export mcpmacros.mcpServer, mcpmacros.mcpTool, mcpmacros.mcpResource, mcpmacros.mcpPrompt