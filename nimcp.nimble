# Package
version       = "0.10.0"
author        = "Göran Krampe"
description   = "Easy-to-use Model Context Protocol (MCP) server library for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.2.4"
requires "https://github.com/gokr/mummyx"
requires "taskpools"

import strformat, os, strutils

# Tasks
task docs, "Generate documentation":
  exec "nim doc --project --index:on --git.url:https://github.com/gokr/nimcp --git.commit:main --outdir:docs src/nimcp.nim"

task test, "Run all tests":
  exec "nimble install -d"
  exec "testament --colors:on pattern 'tests/test_*.nim'"

task examples, "Check that all examples compile":
  echo "🔧 Checking all examples compile properly..."
  
  var failed: seq[string] = @[]
  var passed: seq[string] = @[]
  
  # Find all .nim files in examples directory
  for file in walkDirRec("examples/"):
    if file.endsWith(".nim"):
      let exampleName = file.replace("examples/", "").replace(".nim", "")
      echo fmt"📝 Checking {exampleName}..."
      
      try:
        exec fmt"nim check {file}"
        echo fmt"✅ {exampleName} - OK"
        passed.add(exampleName)
      except:
        echo fmt"❌ {exampleName} - FAILED"
        failed.add(exampleName)
  
  echo ""
  echo "========================================="
  echo "Examples Compilation Summary"
  echo "========================================="
  echo fmt"✅ Passed: {passed.len}"
  for p in passed:
    echo fmt"   ✓ {p}"
  
  if failed.len > 0:
    echo fmt"❌ Failed: {failed.len}"
    for f in failed:
      echo fmt"   ✗ {f}"
    echo ""
    echo "Some examples failed to compile!"
    quit(1)
  else:
    echo ""
    echo "🎉 All examples compile successfully!"


