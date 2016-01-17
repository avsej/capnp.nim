import macros, strutils, capnp/util

type PointerFlag* {.pure.} = enum
  none, text

template kindMatches(obj, v): expr =
  when v is bool:
    v
  else:
    obj.kind == v

template capnpUnpackScalarMember*(name, fieldOffset, fieldDefault, condition) =
  if kindMatches(result, condition):
    if offset + fieldOffset + sizeof(name) > self.buffer.len:
      name = fieldDefault
    else:
      name = self.unpackScalar(offset + fieldOffset, type(name), fieldDefault)

template capnpPackScalarMember*(name, fieldOffset, fieldDefault, condition) =
  if kindMatches(obj, condition):
    packScalar(scalarBuffer, fieldOffset, name, fieldDefault)

template capnpUnpackPointerMember*(name, pointerIndex, flag, condition) =
  if kindMatches(result, condition):
    name = nil
    if pointerIndex < pointerCount:
      let realOffset = offset + pointerIndex * 8 + dataLength
      if realOffset + 8 <= self.buffer.len:
        when flag == PointerFlag.text:
          name = self.unpackText(realOffset, type(name))
        else:
          name = self.unpackPointer(realOffset, type(name))

template capnpPreparePack*() =
  trimWords(scalarBuffer, minDataSize * 8)
  if buffer != nil:
    buffer.insertAt(dataOffset, scalarBuffer)
  var pointers {.inject.}: seq[bool] = @[]

template capnpPreparePackPointer*(name, offset, condition) =
  if kindMatches(value, condition):
    if name != nil and pointers.len <= offset:
      pointers.setLen offset + 1

template capnpPreparePackFinish*() =
  let pointerOffset {.inject.} = dataOffset + scalarBuffer.len
  if buffer != nil:
    buffer.insertAt(pointerOffset, newZeroString(pointers.len * 8))

template capnpPackPointer*(name, offset, flag, condition): stmt =
  if buffer != nil and kindMatches(value, condition):
    when flag == PointerFlag.text:
      packText(buffer, pointerOffset + offset * 8, name)
    else:
      packPointer(buffer, pointerOffset + offset * 8, name)

template capnpPackFinish*(): stmt =
  assert((scalarBuffer.len mod 8) == 0, "")
  return (tuple[dataSize: int, pointerCount: int])((scalarBuffer.len div 8, pointers.len))

proc newComplexDotExpr(a: NimNode, b: NimNode): NimNode {.compileTime.} =
  var b = b
  var a = a
  while b.kind == nnkDotExpr:
    a = newDotExpr(a, b[0])
    b = b[1]
  return newDotExpr(a, b)

proc makeUnpacker(typename: NimNode, scalars: NimNode, pointers: NimNode, bitfields: NimNode): NimNode {.compiletime.} =
  # capnpUnpackStructImpl is generic to delay instantiation
  result = parseStmt("""proc capnpUnpackStructImpl*[T: XXX](self: Unpacker, offset: int, dataLength: int, pointerCount: int, typ: typedesc[T]): T =
  new(result)""")

  result[0][2][0][1] = typeName # replace XXX
  #result.treeRepr.echo
  var body = result[0][^1]
  let resultId = newIdentNode($"result")

  for p in scalars:
    let name = p[0]
    let offset = p[1]
    let default = p[2]
    let condition = p[3]
    body.add(newCall(!"capnpUnpackScalarMember", newComplexDotExpr(resultId, name), offset, default, condition))

  for p in pointers:
    let name = p[0]
    let offset = p[1]
    let flag = p[2]
    let condition = p[3]
    body.add(newCall(!"capnpUnpackPointerMember", newComplexDotExpr(resultId, name), offset, flag, condition))

proc makePacker(typename: NimNode, scalars: NimNode, pointers: NimNode, bitfields: NimNode): NimNode {.compiletime.} =
  result = parseStmt("""proc capnpPackStructImpl*[T: XXX](buffer: var string, value: T, dataOffset: int, minDataSize=0): tuple[dataSize: int, pointerCount: int] =
  var scalarBuffer = newZeroString(max(@[0]))""")

  result[0][2][0][1] = typeName # replace XXX
  let body = result[0][6]
  let sizesList = body[0][0][2][1][1][1]
  let valueId = newIdentNode($"value")

  for p in scalars:
    let name = p[0]
    let offset = p[1]
    sizesList.add(newCall(newIdentNode($"+"),  newCall(newIdentNode($"capnpSizeof"), newComplexDotExpr(valueId, name)), offset))

  for p in bitfields:
    let name = p[0]
    let offset = p[1]
    sizesList.add(newLit((offset.intVal + 7) div 8))

  for p in scalars:
    let name = p[0]
    let offset = p[1]
    let default = p[2]
    let condition = p[3]

    body.add(newCall(!"capnpPackScalarMember", newComplexDotExpr(valueId, name), offset, default, condition))

  body.add(newCall(!"capnpPreparePack"))

  for p in pointers:
    let name = p[0]
    let offset = p[1]
    let condition = p[3]

    body.add(newCall(!"capnpPreparePackPointer", newComplexDotExpr(valueId, name), offset, condition))

  body.add(newCall(!"capnpPreparePackFinish"))

  for p in pointers:
    let name = p[0]
    let offset = p[1]
    let flag = p[2]
    let condition = p[3]

    body.add(newCall(!"capnpPackPointer", newComplexDotExpr(valueId, name), offset, flag, condition))

  body.add(parseStmt("capnpPackFinish()"))

macro makeStructCoders*(typeName, scalars, pointers, bitfields): stmt =
  newNimNode(nnkStmtList)
    .add(makeUnpacker(typeName, scalars, pointers, bitfields))
    .add(makePacker(typeName, scalars, pointers, bitfields))
