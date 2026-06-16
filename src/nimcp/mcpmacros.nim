## Powerful macros for easy MCP server creation

import macros, json, tables, options, strutils, typetraits
import types, server, protocol

# Helper to convert Nim types to JSON schema types
proc nimTypeToJsonSchema(nimType: NimNode): JsonNode =
  case nimType.kind:
  of nnkIdent:
    case $nimType:
    of "int", "int8", "int16", "int32", "int64":
      result = newJObject()
      result["type"] = newJString("integer")
    of "uint", "uint8", "uint16", "uint32", "uint64":
      result = newJObject()
      result["type"] = newJString("integer")
      result["minimum"] = newJInt(0)
    of "float", "float32", "float64":
      result = newJObject()
      result["type"] = newJString("number")
    of "string":
      result = newJObject()
      result["type"] = newJString("string")
    of "bool":
      result = newJObject()
      result["type"] = newJString("boolean")
    else:
      result = newJObject()
      result["type"] = newJString("string")  # Default fallback
  of nnkBracketExpr:
    if nimType[0].kind == nnkIdent and $nimType[0] == "seq":
      result = newJObject()
      result["type"] = newJString("array")
      result["items"] = nimTypeToJsonSchema(nimType[1])
    else:
      result = newJObject()
      result["type"] = newJString("string")  # Default fallback
  else:
    result = newJObject()
    result["type"] = newJString("string")  # Default fallback

proc isIdentifier(s: string): bool =
  if s.len == 0 or not (s[0] in {'a'..'z', 'A'..'Z', '_'}):
    return false
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      return false
  return true

proc paramLineNames(line: string): seq[string] =
  ## If `line` is a parameter description line ("- name: ..." or
  ## "- a, b, c: ..."), return the parameter names, else empty.
  if not line.startsWith("-"):
    return @[]
  let parts = line[1..^1].split(":", 1)
  if parts.len != 2:
    return @[]
  var names: seq[string] = @[]
  for name in parts[0].split(","):
    let clean = name.strip()
    if not clean.isIdentifier():
      return @[]
    names.add(clean)
  return names

# Extract documentation and parameter descriptions from proc node
proc extractDocComments(procNode: NimNode): (string, Table[string, string]) =
  var descriptionLines: seq[string] = @[]
  var paramDescriptions = initTable[string, string]()
  # Names from the most recent "- name:" line; continuation lines (indented
  # prose that follows) append to these params' descriptions.
  var currentParams: seq[string] = @[]

  # Look for doc comments in the proc body (they appear as the first statements)
  let body = procNode[^1]  # Last element is the body
  if body.kind == nnkStmtList and body.len > 0:
    for stmt in body:
      if stmt.kind == nnkCommentStmt:
        for line in stmt.strVal.strip().splitLines():
          let cleanLine = line.strip()
          let names = paramLineNames(cleanLine)
          if names.len > 0:
            currentParams = names
            let desc = cleanLine[1..^1].split(":", 1)[1].strip()
            for name in names:
              paramDescriptions[name] = desc
          elif cleanLine == "":
            currentParams = @[]
            if descriptionLines.len > 0:
              descriptionLines.add("")
          elif currentParams.len > 0:
            for name in currentParams:
              paramDescriptions[name] = paramDescriptions[name] & " " & cleanLine
          else:
            descriptionLines.add(cleanLine)
        break  # Only process the first comment block

  return (descriptionLines.join("\n").strip(), paramDescriptions)

proc defaultValueToJson(node: NimNode): JsonNode =
  ## Compile-time default value → JSON, for literal defaults only.
  ## Returns nil for expressions that can't be represented.
  case node.kind:
  of nnkIntLit..nnkUInt64Lit:
    newJInt(node.intVal.int)
  of nnkFloatLit..nnkFloat64Lit:
    newJFloat(node.floatVal)
  of nnkStrLit..nnkTripleStrLit:
    newJString(node.strVal)
  of nnkIdent:
    case $node:
    of "true": newJBool(true)
    of "false": newJBool(false)
    else: nil
  of nnkPrefix:
    if node.len == 2 and $node[0] == "-":
      let inner = defaultValueToJson(node[1])
      if inner == nil: nil
      elif inner.kind == JInt: newJInt(-inner.getInt)
      elif inner.kind == JFloat: newJFloat(-inner.getFloat)
      else: nil
    else:
      nil
  else:
    nil

# Generate JSON schema from proc parameters with descriptions.
# `firstParam` is 1 for regular tools (skip the implicit result) and 2 for
# context-aware tools (also skip the McpRequestContext parameter).
proc generateInputSchema(params: NimNode, paramDescs: Table[string, string], firstParam: int): JsonNode =
  var properties = newJObject()
  var required = newJArray()

  for i in firstParam..<params.len:
    let param = params[i]
    if param.kind == nnkIdentDefs:
      let paramType = param[^2]  # Type is second to last
      for j in 0..<param.len-2:  # All except type and default value
        let paramName = $param[j]
        if paramName != "":
          var prop = nimTypeToJsonSchema(paramType)
          if paramName in paramDescs:
            prop["description"] = newJString(paramDescs[paramName])
          # A param with a default value is optional — the dispatcher fills it in
          # when the caller omits it. Only default-less params are required.
          if param[^1].kind == nnkEmpty:
            required.add(newJString(paramName))
          else:
            let defaultJson = defaultValueToJson(param[^1])
            if defaultJson != nil:
              prop["default"] = defaultJson
          properties[paramName] = prop

  result = newJObject()
  result["type"] = newJString("object")
  result["properties"] = properties
  result["required"] = required


# Advanced macro for introspecting proc signatures and auto-generating tools
# Supports both regular tools and context-aware tools with automatic detection
macro mcpTool*(procDef: untyped): untyped =
  # Handle both direct proc def and block containing proc def
  var actualProcDef: NimNode
  if procDef.kind == nnkStmtList and procDef.len > 0 and procDef[0].kind == nnkProcDef:
    actualProcDef = procDef[0]
  elif procDef.kind == nnkProcDef:
    actualProcDef = procDef
  else:
    error("Expected a proc definition", procDef)
  
  let procName = actualProcDef[0]
  let params = actualProcDef[3]  # Parameters
  
  # Extract tool name from proc name
  let toolName = $procName
  
  # Extract doc comments from the proc definition
  let (description, paramDescs) = extractDocComments(actualProcDef)
  let finalDescription = if description.len > 0: description else: "Auto-generated tool: " & toolName
  
  # Check if this is a context-aware tool by examining first parameter
  var isContextAware = false
  var contextParamName = ""
  if params.len > 1:  # Has parameters beyond return type
    let firstParam = params[1]
    if firstParam.kind == nnkIdentDefs and firstParam.len >= 2:
      let paramType = firstParam[^2]
      if paramType.kind == nnkIdent and $paramType == "McpRequestContext":
        isContextAware = true
        contextParamName = $firstParam[0]
  
  # Generate input schema from parameters (skip context parameter for schema)
  let inputSchema = generateInputSchema(params, paramDescs, firstParam = if isContextAware: 2 else: 1)
  
  # Generate the wrapper proc name to avoid conflicts
  let wrapperName = ident("tool_" & toolName & "_wrapper")
  
  # Convert the compile-time schema to a runtime string representation
  let schemaStr = $inputSchema
  
  result = newStmtList()
  
  # Create the tool definition with unique name
  let toolIdent = ident("tool_" & toolName)
  result.add(quote do:
    let `toolIdent` = McpTool(
      name: `toolName`,
      description: some(`finalDescription`),
      inputSchema: parseJson(`schemaStr`)
    )
  )
  
  # Build wrapper procedure - different signature for context-aware vs regular tools
  if isContextAware:
    # Context-aware wrapper: proc(ctx: McpRequestContext, jsonArgs: JsonNode): McpToolResult
    let ctxParam = newIdentDefs(ident("ctx"), bindSym("McpRequestContext"))
    let jsonArgsParam = newIdentDefs(ident("jsonArgs"), bindSym("JsonNode"))
    let returnType = bindSym("McpToolResult")
    
    # Generate argument extractions (skip context parameter)
    var argExtractions = newSeq[NimNode]()
    argExtractions.add(ident("ctx"))  # Add context as first argument
    
    for i in 2..<params.len:  # Skip result and context params
      let param = params[i]
      if param.kind == nnkIdentDefs:
        let paramType = param[^2]
        let defaultVal = param[^1]  # nnkEmpty when the param has no default
        for j in 0..<param.len-2:
          let paramName = $param[j]
          if paramName != "":
            let paramNameLit = newLit(paramName)
            let jsonArgsIdent = ident("jsonArgs")
            var extraction = case $paramType:
              of "int", "int8", "int16", "int32", "int64":
                newCall(bindSym("getInt"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              of "uint", "uint8", "uint16", "uint32", "uint64":
                newCall(bindSym("getInt"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              of "float", "float32", "float64":
                newCall(bindSym("getFloat"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              of "string":
                newCall(bindSym("getStr"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              of "bool":
                newCall(bindSym("getBool"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              else:
                newCall(bindSym("getStr"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
            if defaultVal.kind != nnkEmpty:
              # Optional param: honor the proc's default when the key is absent
              # (matches the schema, which only lists default-less params as
              # required).
              extraction = nnkIfExpr.newTree(
                nnkElifExpr.newTree(
                  newCall(bindSym("hasKey"), jsonArgsIdent, paramNameLit),
                  extraction),
                nnkElseExpr.newTree(defaultVal.copyNimTree))
            argExtractions.add(extraction)

    # Build the function call and wrapper body
    let functionCall = newCall(procName, argExtractions)
    let resultAssign = newLetStmt(ident("functionResult"), functionCall)
    let returnStmt = nnkReturnStmt.newTree(
      nnkObjConstr.newTree(
        bindSym("McpToolResult"),
        nnkExprColonExpr.newTree(
          ident("content"),
          newCall(bindSym("@"), newNimNode(nnkBracket).add(
            newCall(bindSym("createTextContent"), newCall(bindSym("$"), ident("functionResult")))
          ))
        )
      )
    )
    
    let wrapperBody = newStmtList(resultAssign, returnStmt)
    let wrapperProc = newProc(
      wrapperName,
      [returnType, ctxParam, jsonArgsParam],
      wrapperBody,
      nnkProcDef
    )
    # Add required pragmas for McpToolHandlerWithContext
    wrapperProc[4] = nnkPragma.newTree(ident("gcsafe"), ident("closure"))
    
    result.add(wrapperProc)
    
    # Add the original function definition first so it's available when the wrapper is compiled
    result.insert(1, actualProcDef)
    
    # Register the context-aware tool - will be injected into the server instance
    result.add(quote do:
      mcpServerInstance.registerToolWithContext(`toolIdent`, `wrapperName`)
    )
  else:
    # Regular wrapper: proc(jsonArgs: JsonNode): McpToolResult
    let jsonArgsParam = newIdentDefs(ident("jsonArgs"), bindSym("JsonNode"))
    let returnType = bindSym("McpToolResult")
    
    # Generate argument extractions
    var argExtractions = newSeq[NimNode]()
    for i in 1..<params.len:
      let param = params[i]
      if param.kind == nnkIdentDefs:
        let paramType = param[^2]
        let defaultVal = param[^1]  # nnkEmpty when the param has no default
        for j in 0..<param.len-2:
          let paramName = $param[j]
          if paramName != "":
            let paramNameLit = newLit(paramName)
            let jsonArgsIdent = ident("jsonArgs")
            var extraction = case $paramType:
              of "int", "int8", "int16", "int32", "int64":
                newCall(bindSym("getInt"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              of "uint", "uint8", "uint16", "uint32", "uint64":
                newCall(bindSym("getInt"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              of "float", "float32", "float64":
                newCall(bindSym("getFloat"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              of "string":
                newCall(bindSym("getStr"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              of "bool":
                newCall(bindSym("getBool"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
              else:
                newCall(bindSym("getStr"), newCall(bindSym("[]"), jsonArgsIdent, paramNameLit))
            if defaultVal.kind != nnkEmpty:
              # Optional param: honor the proc's default when the key is absent
              # (matches the schema, which only lists default-less params as
              # required).
              extraction = nnkIfExpr.newTree(
                nnkElifExpr.newTree(
                  newCall(bindSym("hasKey"), jsonArgsIdent, paramNameLit),
                  extraction),
                nnkElseExpr.newTree(defaultVal.copyNimTree))
            argExtractions.add(extraction)

    # Build the function call and wrapper body
    let functionCall = newCall(procName, argExtractions)
    let resultAssign = newLetStmt(ident("functionResult"), functionCall)
    let returnStmt = nnkReturnStmt.newTree(
      nnkObjConstr.newTree(
        bindSym("McpToolResult"),
        nnkExprColonExpr.newTree(
          ident("content"),
          newCall(bindSym("@"), newNimNode(nnkBracket).add(
            newCall(bindSym("createTextContent"), newCall(bindSym("$"), ident("functionResult")))
          ))
        )
      )
    )
    
    let wrapperBody = newStmtList(resultAssign, returnStmt)
    let wrapperProc = newProc(
      wrapperName,
      [returnType, jsonArgsParam],
      wrapperBody,
      nnkProcDef
    )
    # Add required pragmas for McpToolHandler
    wrapperProc[4] = nnkPragma.newTree(ident("gcsafe"), ident("closure"))
    
    result.add(wrapperProc)
    
    # Add the original function definition first so it's available when the wrapper is compiled
    result.insert(1, actualProcDef)
    
    # Register the regular tool - will be injected into the server instance
    result.add(quote do:
      mcpServerInstance.registerTool(`toolIdent`, `wrapperName`)
    )

# Server creation macro that returns a composable McpServer instance
macro mcpServer*(name: string, version: string, body: untyped): untyped =
  ## Create an MCP server with automatic tool registration from the body
  ## Returns a McpServer instance that can be composed with other servers
  
  # Wrap everything in a block to create isolated scope
  result = nnkBlockStmt.newTree(
    newEmptyNode(),  # No block label
    nnkStmtList.newTree(
      # Create the server instance
      nnkLetSection.newTree(
        nnkIdentDefs.newTree(
          ident("mcpServerInstance"),
          newEmptyNode(),
          newCall("newMcpServer", name, version)
        )
      ),
      # Add the body (which will contain mcpTool registrations)
      body,
      # Return the server instance
      ident("mcpServerInstance")
    )
  )


# Simple resource registration template  
template mcpResource*(uri: string, name: string, description: string, handler: untyped): untyped =
  let resource = McpResource(
    uri: uri,
    name: name,
    description: some(description)
  )
  
  proc resourceHandler(uriParam: string): McpResourceContents =
    let content = handler(uriParam)
    return McpResourceContents(
      uri: uriParam,
      content: @[createTextContent(content)]
    )
  
  mcpServerInstance.registerResource(resource, resourceHandler)

# Simple prompt registration template
template mcpPrompt*(name: string, description: string, arguments: seq[McpPromptArgument], handler: untyped): untyped =
  let prompt = McpPrompt(
    name: name,
    description: some(description),
    arguments: arguments
  )
  
  proc promptHandler(nameParam: string, args: Table[string, JsonNode]): McpGetPromptResult =
    let messages = handler(nameParam, args)
    return McpGetPromptResult(messages: messages)
  
  mcpServerInstance.registerPrompt(prompt, promptHandler)