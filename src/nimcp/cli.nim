## CLI front-end for an McpServer: every registered tool becomes a
## subcommand whose flags derive from the tool's input schema. This gives
## any nimcp server a scriptable fallback interface alongside the MCP
## transports — one-shot calls that don't need a connected MCP client.
##
## Runs single-threaded before any transport is started, so it reads the
## server's tool tables directly.

import std/[json, options, strutils, tables, algorithm, wordwrap]
import types, server

type
  CliFailureCheck* = proc(text: string): bool {.gcsafe.}
    ## Optional domain-level error detection: when the tool call succeeds at
    ## the protocol level but the output text represents a failure (e.g. an
    ## "Error: ..." string), return true to map it to a non-zero exit code.
  CliSetup* = proc(): bool {.gcsafe.}
    ## Optional hook run after argument validation, right before the tool is
    ## invoked — connect to a backend here so help and usage errors work
    ## without one. Return false (after reporting why on stderr) to abort.

proc sortedToolNames(server: McpServer): seq[string] =
  result = getRegisteredToolNames(server)
  result.sort()

proc firstLine(s: string): string =
  s.splitLines()[0]

proc indented(text: string, prefix: string): string =
  var lines: seq[string] = @[]
  for line in text.splitLines():
    lines.add(if line.len > 0: prefix & line else: line)
  lines.join("\n")

proc flagType(prop: JsonNode): string =
  if prop.hasKey("type"): prop["type"].getStr("string") else: "string"

proc isRequired(tool: McpTool, name: string): bool =
  if tool.inputSchema.hasKey("required"):
    for r in tool.inputSchema["required"]:
      if r.getStr() == name:
        return true
  return false

proc toolListText*(server: McpServer): string =
  ## One line per tool: name + first line of its description.
  var lines: seq[string] = @[]
  var width = 0
  let names = server.sortedToolNames()
  for name in names:
    width = max(width, name.len)
  for name in names:
    let tool = server.tools[name]
    let desc = if tool.description.isSome: tool.description.get.firstLine() else: ""
    lines.add("  " & name.alignLeft(width + 2) & desc)
  lines.join("\n")

proc helpText*(server: McpServer, prog: string): string =
  result = "Usage: " & prog & " <tool> [--param value ...]\n"
  result.add("       " & prog & " <tool> --help\n\n")
  result.add("Tools:\n")
  result.add(server.toolListText())

proc toolHelpText*(server: McpServer, name: string, prog: string): string =
  let tool = server.tools[name]
  let properties = tool.inputSchema["properties"]

  var usage = "Usage: " & prog & " " & name
  var optionLines: seq[string] = @[]
  for propName, prop in properties.pairs:
    let required = tool.isRequired(propName)
    let flag = "--" & propName & " <" & prop.flagType() & ">"
    usage.add(if required: " " & flag else: " [" & flag & "]")
    var line = "  " & flag
    if required:
      line.add("  (required)")
    elif prop.hasKey("default"):
      line.add("  (default: " & $prop["default"] & ")")
    if prop.hasKey("description"):
      let desc = prop["description"].getStr()
      line.add("\n" & indented(desc.wrapWords(72), "      "))
    optionLines.add(line)

  result = usage & "\n"
  if tool.description.isSome:
    result.add("\n" & tool.description.get & "\n")
  if optionLines.len > 0:
    result.add("\nOptions:\n")
    result.add(optionLines.join("\n"))

proc coerceValue(value: string, kind: string): JsonNode =
  case kind:
  of "integer": %value.parseInt()
  of "number": %value.parseFloat()
  of "boolean": %value.parseBool()
  of "array", "object": value.parseJson()
  else: %value

proc parseToolArgs(tool: McpTool, args: seq[string], errors: var seq[string]): JsonNode =
  let properties = tool.inputSchema["properties"]
  result = newJObject()
  var i = 0
  while i < args.len:
    let token = args[i]
    if not token.startsWith("--"):
      errors.add("Unexpected argument: " & token)
      return
    var name = token[2..^1]
    var value = ""
    var hasValue = false
    if "=" in name:
      let parts = name.split("=", 1)
      name = parts[0]
      value = parts[1]
      hasValue = true
    if not properties.hasKey(name):
      errors.add("Unknown option: --" & name)
      return
    let kind = properties[name].flagType()
    if not hasValue:
      if kind == "boolean":
        # Bare flag means true; consume an explicit true/false if present.
        if i + 1 < args.len and args[i + 1] in ["true", "false"]:
          i += 1
          value = args[i]
        else:
          value = "true"
      elif i + 1 < args.len:
        i += 1
        value = args[i]
      else:
        errors.add("Missing value for --" & name)
        return
    try:
      result[name] = coerceValue(value, kind)
    except ValueError, JsonParsingError:
      errors.add("Invalid " & kind & " for --" & name & ": " & value)
      return
    i += 1

  if tool.inputSchema.hasKey("required"):
    for r in tool.inputSchema["required"]:
      if not result.hasKey(r.getStr()):
        errors.add("Missing required option: --" & r.getStr())

proc dispatchCli*(
    server: McpServer, args: seq[string], prog: string,
    failure: CliFailureCheck = nil, setup: CliSetup = nil,
): int =
  ## Run one tool call from command-line arguments and print the result.
  ## Returns the process exit code: 0 on success, 1 when the tool fails
  ## (exception or `failure` matches the output), 2 on usage errors.
  if args.len == 0 or args[0] in ["help", "--help", "-h"]:
    echo server.helpText(prog)
    return 0

  let name = args[0]
  if name notin server.tools:
    stderr.writeLine("Unknown tool: " & name & "\n")
    stderr.writeLine(server.helpText(prog))
    return 2

  if "--help" in args[1..^1] or "-h" in args[1..^1]:
    echo server.toolHelpText(name, prog)
    return 0

  var errors: seq[string] = @[]
  let toolArgs = parseToolArgs(server.tools[name], args[1..^1], errors)
  if errors.len > 0:
    for e in errors:
      stderr.writeLine(e)
    stderr.writeLine("\n" & server.toolHelpText(name, prog))
    return 2

  if setup != nil and not setup():
    return 1

  var response: JsonNode
  try:
    response = server.handleToolsCall(%*{"name": name, "arguments": toolArgs})
  except CatchableError as e:
    stderr.writeLine("Error: " & e.msg)
    return 1

  var textOutput: seq[string] = @[]
  for content in response["content"]:
    if content["type"].getStr() == "text":
      textOutput.add(content["text"].getStr())
      echo content["text"].getStr()
    else:
      echo $content

  if failure != nil and failure(textOutput.join("\n")):
    return 1
  return 0
