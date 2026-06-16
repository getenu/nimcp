import unittest
import json
import options
import tables
import strutils
import ../src/nimcp/mcpmacros
import ../src/nimcp/types
import ../src/nimcp/server
import ../src/nimcp/cli

let testServer = mcpServer("cli-test", "1.0.0"):
  mcpTool:
    proc greet(name: string, count: int = 1, shout: bool = false): string =
      ## Greet someone by name.
      ## Repeats the greeting `count` times.
      ## - name: who to greet, spans
      ##   multiple lines
      ## - count: how many times
      ## - shout: uppercase the greeting
      var greeting = "hello " & name
      if shout:
        greeting = greeting.toUpperAscii()
      var lines: seq[string] = @[]
      for _ in 1..count:
        lines.add(greeting)
      return lines.join("\n")

  mcpTool:
    proc frame(x, y, z: float, distance: float = 30.0): string =
      ## Frame a position.
      ## - x, y, z: target position
      ## - distance: how far away (default 30)
      return "framed " & $x & "," & $y & "," & $z & " from " & $distance

  mcpTool:
    proc fail(message: string): string =
      ## Always returns an error string.
      return "Error: " & message

test "multi-line descriptions and multi-name param docs are extracted":
  let greet = testServer.tools["greet"]
  check greet.description.get == "Greet someone by name.\nRepeats the greeting `count` times."
  let props = greet.inputSchema["properties"]
  check props["name"]["description"].getStr == "who to greet, spans multiple lines"
  check props["shout"]["description"].getStr == "uppercase the greeting"

  let frameProps = testServer.tools["frame"].inputSchema["properties"]
  for p in ["x", "y", "z"]:
    check frameProps[p]["description"].getStr == "target position"

test "literal defaults land in the schema":
  let props = testServer.tools["greet"].inputSchema["properties"]
  check props["count"]["default"].getInt == 1
  check props["shout"]["default"].getBool == false
  check not props["name"].hasKey("default")
  let frameProps = testServer.tools["frame"].inputSchema["properties"]
  check frameProps["distance"]["default"].getFloat == 30.0

test "help text lists tools":
  let help = testServer.helpText("prog")
  check "Usage: prog <tool>" in help
  check "greet" in help
  check "Greet someone by name." in help

test "tool help shows flags, requirements and defaults":
  let help = testServer.toolHelpText("greet", "prog")
  check "--name <string>" in help
  check "(required)" in help
  check "(default: 1)" in help
  check "Repeats the greeting" in help

test "dispatch runs a tool with coerced args and defaults":
  check testServer.dispatchCli(@["greet", "--name", "world"], "prog") == 0
  check testServer.dispatchCli(
    @["greet", "--name", "world", "--count", "2", "--shout"], "prog") == 0
  check testServer.dispatchCli(
    @["frame", "--x", "1.5", "--y=2", "--z", "-3", "--distance", "10"], "prog") == 0

test "usage errors exit 2":
  check testServer.dispatchCli(@["nope"], "prog") == 2
  check testServer.dispatchCli(@["greet"], "prog") == 2
  check testServer.dispatchCli(@["greet", "--name", "a", "--bogus", "b"], "prog") == 2
  check testServer.dispatchCli(@["greet", "--name", "a", "--count", "x"], "prog") == 2

test "help requests exit 0":
  check testServer.dispatchCli(@[], "prog") == 0
  check testServer.dispatchCli(@["--help"], "prog") == 0
  check testServer.dispatchCli(@["greet", "--help"], "prog") == 0

test "setup hook runs only before a real tool call and can abort":
  var setupCalls = 0
  let failSetup = proc(): bool {.gcsafe.} =
    setupCalls += 1
    false
  check testServer.dispatchCli(@["greet", "--help"], "prog", setup = failSetup) == 0
  check testServer.dispatchCli(@["greet"], "prog", setup = failSetup) == 2
  check setupCalls == 0
  check testServer.dispatchCli(@["greet", "--name", "a"], "prog", setup = failSetup) == 1
  check setupCalls == 1
  let okSetup = proc(): bool {.gcsafe.} = true
  check testServer.dispatchCli(@["greet", "--name", "a"], "prog", setup = okSetup) == 0

test "failure check maps domain errors to exit 1":
  let isError = proc(text: string): bool {.gcsafe.} = text.startsWith("Error")
  check testServer.dispatchCli(@["fail", "--message", "boom"], "prog", isError) == 1
  check testServer.dispatchCli(@["greet", "--name", "ok"], "prog", isError) == 0
