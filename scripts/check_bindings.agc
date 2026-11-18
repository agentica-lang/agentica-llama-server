## Checks the `extern` blocks of src/llama_server/llama.agc against the llama.cpp headers of deps/headers.
##
## A wrong struct field list or a wrong signature is undefined behavior, so for every bound struct it compares the
## field names, their order and their C types, and for every bound function that it exists with the same number of
## parameters and the same types, and that a resource is the pointer its `free:` function takes. Unless
## --skip-sizes, it also compiles a C program against the headers: the sizeof of each struct, as the C compiler gives
## it, must be Native.size_of of Agentica, and the sizes that the helpers of llama.agc assume (the constants at its
## end, the widths of the batch arrays) must be the C ones.
##
## agentica scripts/check_bindings.agc [--headers DIR] [--source FILE] [--skip-sizes]
##
## Needs `agentica scripts/fetch.agc headers` and, for the sizes, a C compiler (cc). Exit 0 when the bindings match, 1 when not.

import Llama from "../src/llama_server/llama"
import OP from "std/option_parser"
import Regex from "std/regex"
import {Kind, Opt} from "std/option_parser"

# Agentica struct name -> C struct name.
STRUCTS = {
  "ModelParams": "llama_model_params",
  "ContextParams": "llama_context_params",
  "Batch": "llama_batch",
  "SamplerChainParams": "llama_sampler_chain_params",
}

# Agentica resource name -> the C struct its pointer points to.
RESOURCES = {"Model": "llama_model", "Context": "llama_context", "Sampler": "llama_sampler"}

# C scalar type -> the Agentica types that lay out the same.
SCALARS = {
  "bool": ["C.Bool"],
  "char": ["C.Int8"],
  "int8_t": ["C.Int8"],
  "uint8_t": ["C.UInt8"],
  "int16_t": ["C.Int16"],
  "uint16_t": ["C.UInt16"],
  "int": ["C.Int32"],
  "int32_t": ["C.Int32"],
  "uint32_t": ["C.UInt32"],
  "int64_t": ["C.Int64"],
  "uint64_t": ["C.UInt64"],
  "size_t": ["C.Int64", "C.UInt64"],
  "float": ["C.Float"],
  "double": ["C.Double"],
  "void": ["Void"],
}

# What `unsigned` and `unsigned X` mean.
UNSIGNED = {"": "C.UInt32", "int": "C.UInt32", "char": "C.UInt8", "short": "C.UInt16"}

# What the C program prints besides the struct sizes: name and C expression.
PROBES = [
  ["chat_message_bytes", "sizeof(llama_chat_message)"],
  ["pointer_bytes", "sizeof(void *)"],
  ["chat_message_content_offset", "offsetof(llama_chat_message, content)"],
  ["token_bytes", "sizeof(llama_token)"],
  ["batch_token_bytes", "sizeof(*((llama_batch *)0)->token)"],
  ["batch_pos_bytes", "sizeof(*((llama_batch *)0)->pos)"],
  ["batch_n_seq_id_bytes", "sizeof(*((llama_batch *)0)->n_seq_id)"],
  ["batch_seq_id_cell_bytes", "sizeof(**((llama_batch *)0)->seq_id)"],
  ["batch_seq_id_slot_bytes", "sizeof(*((llama_batch *)0)->seq_id)"],
  ["batch_logits_bytes", "sizeof(*((llama_batch *)0)->logits)"],
]

TOOL_TIMEOUT_MS = 120_000

struct Options
  headers: String
  source: String
  skip_sizes: Bool
end

## How a C type is bound: tag "ptr" (name: what it points to), "struct" (name) or "scalar" (types: the Agentica types).
struct CType
  tag: String
  name: String
  types: List[String]
end

struct Field
  name: String
  ctype: String
end

struct Signature
  result: String
  params: List[String]
end

struct Binding
  name: String
  signature: Signature
end

struct Header
  typedefs: Map[String, String]
  enums: List[String]
  signatures: Map[String, Signature]
  text: String
end

struct Blocks
  structs: Map[String, List[Field]]
  resources: Map[String, String]
  functions: Map[String, Signature]
  constants: Map[String, Int]
end

struct Ran
  code: Int
  stdout: String
  stderr: String
end

def main() -> Void
  parsed = parse(System.args())
  options = OP.run!(parsed)
  case run(options)
    ok(errors) ->
      if errors.empty?
        puts("bindings ok")
      else
        IO.warn("bindings do not match the headers:")
        IO.warn(errors.join("\n"))
        System.exit(1)
      end

    error(e) ->
      IO.warn("bindings not checked: #{e.message}")
      System.exit(2)
  end
end

def parse(args: List[String]) -> Result[Options]
  parser = OP.new(
    "agentica scripts/check_bindings.agc",
    "Checks the bindings of llama.agc against the llama.cpp headers",
    [],
    [
      Opt(
        name: "headers",
        metavar: "DIR",
        default: "deps/headers",
        help: "the folder `scripts/fetch.agc headers` fills",
      ),
      Opt(name: "source", metavar: "FILE", default: "src/llama_server/llama.agc", help: "the bindings"),
      Opt(name: "skip-sizes", kind: Kind.Flag, help: "skip the C compiler and the sizes"),
    ],
  )

  parsed = try OP.parse(parser, args)
  ok(
    Options(
      headers: OP.string(parsed, "headers"),
      source: OP.string(parsed, "source"),
      skip_sizes: OP.flag(parsed, "skip-sizes"),
    ),
  )
end

## The mismatches, one text each; an error when something cannot be read or run.
def run(options: Options) -> Result[List[String]]
  header = try read_header(options.headers)
  blocks = try read_blocks(options.source)
  errors = check_structs(header, blocks) + check_functions(header, blocks)
  return ok(errors) if options.skip_sizes

  sizes = try check_sizes(options.headers, blocks.constants)
  ok(errors + sizes)
end

# --- the headers

def read_header(dir: String) -> Result[Header]
  names = try Dir.list(dir)
  return error("no llama.h in #{dir}: run agentica scripts/fetch.agc headers") if !names.include?("llama.h")

  texts: List[String] = []
  headers = names.select do |n| n.end_with?(".h") end
  for name in headers
    texts = texts.push(try File.read_text(try Path.join([dir, name])))
  end

  text = try clean(texts.join("\n"))
  chunks = text.split(";")
  ok(
    Header(
      typedefs: chunks.reduce({}) do |acc, c| add_typedef(acc, c) end,
      enums: chunks.flat_map do |c| enum_typedef(c) end,
      signatures: chunks.reduce({}) do |acc, c| add_signature(acc, c) end,
      text: text,
    ),
  )
end

## The text without comments, preprocessor lines and the API macros, on one line.
def clean(raw: String) -> Result[String]
  a = try Regex.replace(raw, /\/\*.*?\*\//m, " ")
  b = try Regex.replace(a, /\/\/[^\n]*/, "")
  c = try Regex.replace(b, /\\\n/, " ")
  d = try Regex.replace(c, /(?m)^[ \t]*#[^\n]*/, "")
  e = try Regex.replace(d, /\b[A-Z]+_API\b/, " ")
  Regex.replace(e, /\s+/, " ")
end

## The part of a chunk (the text between two `;`) after its last `{` or `}`: where a declaration starts.
def declaration(chunk: String) -> String
  case Regex.replace(chunk, /^.*[{}]/, "")
    ok(tail) -> tail.strip()
    error(_) -> chunk.strip()
  end
end

def add_typedef(known: Map[String, String], chunk: String) -> Map[String, String]
  text = declaration(chunk)
  if Regex.match?(text, /^typedef\b.*\(\s*\*\s*\w+\s*\)\s*\(/)
    name = Regex.match(text, /\(\s*\*\s*(\w+)\s*\)/)
    return known.put(name.unwrap!.groups[1].text, "void *")
  end

  case Regex.match(text, /^typedef\s+([^(){}]+?)\s+(\w+)$/)
    ok(m) -> known.put(m.groups[2].text, m.groups[1].text)
    error(_) -> known
  end
end

def enum_typedef(chunk: String) -> List[String]
  case Regex.match(chunk, /typedef enum[^{]*\{[^}]*\}\s*(\w+)$/)
    ok(m) -> [m.groups[1].text]
    error(_) -> []
  end
end

## A function declaration is a chunk with a return type before its name; `return g(1)` in an inline body is not one.
def add_signature(known: Map[String, Signature], chunk: String) -> Map[String, Signature]
  text = declaration(chunk)
  return known if text.start_with?("typedef")

  case Regex.match(text, /^([^()=,]*[\s*])(\w+)\s*\((.*)\)$/)
    error(_) -> known
    ok(m) ->
      result = m.groups[1].text.strip()
      name = m.groups[2].text
      if result.empty? or result.start_with?("return") or known.key?(name)
        known
      else
        known.put(name, Signature(result: result, params: split_params(m.groups[3].text).map do |p| param_type(p) end))
      end
  end
end

## The parameters of a C prototype or an Agentica signature, split at the commas outside parentheses.
def split_params(text: String) -> List[String]
  clean_text = text.strip()
  return [] if clean_text == "" or clean_text == "void"

  parts: List[String] = []
  current: List[String] = []
  depth = 0
  for c in clean_text.split("")
    if c == "("
      depth = depth + 1
    elsif c == ")"
      depth = depth - 1
    end

    if c == "," and depth == 0
      parts = parts.push(current.join("").strip())
      current = []
    else
      current = current.push(c)
    end
  end

  parts.push(current.join("").strip())
end

## The type of a C parameter: the declaration without its name.
def param_type(param: String) -> String
  return param if param.include?("(")

  case Regex.match(param, /^(.*[\s*])(\w+)$/)
    ok(m) ->
      type = m.groups[1].text.strip()
      name = m.groups[2].text
      return param if ["", "struct", "enum", "const"].include?(type)
      return param if type == "unsigned" and ["int", "char", "short", "long"].include?(name)

      type
    error(_) -> param
  end
end

## The fields of `struct NAME { ... }`; a field the check cannot read is an error.
def struct_fields(header: Header, name: String) -> Result[List[Field]]
  pattern = try Regex.compile("\\bstruct " + name + " \\{([^}]*)\\}")
  found = Regex.match(header.text, pattern)
  return error("struct #{name} is not in the headers") if !found.ok?

  body = found.unwrap!.groups[1].text
  return error("unsupported field in #{name}: a nested struct, union or enum") if body.include?("{")

  fields: List[Field] = []
  for part in body.split(";")
    decl = part.strip()
    next if decl.empty?

    if Regex.match?(decl, /[(\[:,]/)
      return error(
        "unsupported field `#{decl}` in #{name}: a function pointer, array, bitfield or several declarators",
      )
    end

    m = try Regex.match(decl, /^(.*?)\s*(\w+)$/)
    fields = fields.push(Field(name: m.groups[2].text, ctype: m.groups[1].text))
  end

  ok(fields)
end

# --- C types

def kind(header: Header, ctype: String) -> Result[CType]
  found = Regex.find_all(ctype, /[A-Za-z_]\w*|\*|\(/).map do |m| m.text end
  words = found.select do |w| w != "const" end
  stars = words.count do |w| w == "*" end
  names = words.select do |w| !["struct", "enum", "*"].include?(w) end
  return ok(CType(tag: "ptr", name: "", types: [])) if words.include?("(")
  return error("unsupported C type `#{ctype}`") if names.empty?

  if names.include?("unsigned")
    rest = names.select do |w| w != "unsigned" end
    width = UNSIGNED.get(rest.join(" "))
    return error("unsupported C type `#{ctype}`") if width.none? or stars > 0

    return ok(CType(tag: "scalar", name: "", types: [width.unwrap!]))
  end

  base = names.last
  return error("unsupported C type `#{ctype}`") if ["long", "short", "signed"].include?(base)
  return ok(CType(tag: "ptr", name: base, types: [])) if stars > 0
  if words.include?("enum") or header.enums.include?(base)
    return ok(CType(tag: "scalar", name: "", types: ["C.Int32"]))
  end

  case header.typedefs.get(base)
    some(target) if !words.include?("struct") -> kind(header, target)
    _ ->
      case SCALARS.get(base)
        some(types) -> ok(CType(tag: "scalar", name: "", types: types))
        none -> ok(CType(tag: "struct", name: base, types: []))
      end
  end
end

## The struct that a pointer type points to, through typedefs; "" when it is not a plain pointer.
def pointee(header: Header, ctype: String) -> String
  case kind(header, ctype)
    error(_) -> ""
    ok(k) if k.tag == "ptr" -> k.name
    ok(_) ->
      found = Regex.find_all(ctype, /[A-Za-z_]\w*/).map do |m| m.text end
      base = found.last
      case header.typedefs.get(base)
        some(target) -> pointee(header, target)
        none -> ""
      end
  end
end

## Whether the Agentica type `agc` can be the binding of the C type.
def accepts(header: Header, ctype: String, agc: String) -> Result[Bool]
  k = try kind(header, ctype)
  return ok(agc == struct_of(k.name)) if k.tag == "struct"

  if k.tag == "ptr"
    resource = RESOURCES.get(agc)
    return ok(resource.unwrap! == pointee(header, ctype)) if resource.some?

    return ok(agc == "C.Pointer" or (agc == "C.String" and k.name == "char"))
  end

  ok(k.types.include?(agc))
end

## The Agentica name of a C struct passed by value, or "".
def struct_of(c_name: String) -> String
  names = STRUCTS.keys.select do |a| STRUCTS[a] == c_name end
  return "" if names.empty?

  names.first
end

# --- llama.agc

def read_blocks(path: String) -> Result[Blocks]
  lines = (try File.read_text(path)).split("\n")
  blocks = Blocks(structs: {}, resources: {}, functions: {}, constants: {})
  in_block = false
  struct_name = ""
  signature: List[String] = []
  for raw in lines
    code = raw.split("#").first
    stripped = code.strip()
    if Regex.match?(stripped, /^extern\s+"/)
      in_block = true
    elsif in_block and code == "end"
      in_block = false
    elsif in_block and struct_name != ""
      if stripped == "end"
        struct_name = ""
      elsif stripped != ""
        parts = stripped.split(":")
        field = Field(name: parts[0].strip(), ctype: parts[1].strip())
        blocks = blocks.with(structs: blocks.structs.put(struct_name, blocks.structs.get(struct_name, []).push(field)))
      end
    elsif in_block and Regex.match?(stripped, /^struct\s+\w+$/)
      struct_name = stripped.split(" ")[1]
      blocks = blocks.with(structs: blocks.structs.put(struct_name, []))
    elsif in_block and Regex.match?(stripped, /^resource\s+\w+/)
      m = try Regex.match(stripped, /resource\s+(\w+),\s*free:\s*(\w+)/)
      blocks = blocks.with(resources: blocks.resources.put(m.groups[1].text, m.groups[2].text))
    elsif in_block and (!signature.empty? or Regex.match?(stripped, /^(compute\s+)?def\s/))
      signature = signature.push(stripped)
      text = signature.join(" ")
      if balanced?(text) and text.include?("->")
        m = try Regex.match(text, /def\s+(\w+)\((.*)\)\s*->\s*(.+)$/)
        params = split_params(m.groups[2].text).map do |p| p.split(":")[1].strip() end
        blocks = blocks.with(
          functions: blocks.functions.put(
            m.groups[1].text,
            Signature(result: m.groups[3].text.strip(), params: params),
          ),
        )

        signature = []
      end
    elsif Regex.match?(stripped, /^[A-Z_]+ = \d+$/)
      m = try Regex.match(stripped, /^([A-Z_]+) = (\d+)$/)
      blocks = blocks.with(constants: blocks.constants.put(m.groups[1].text, try m.groups[2].text.to_i))
    end
  end

  ok(blocks)
end

def balanced?(text: String) -> Bool = text.split("(").size == text.split(")").size

# --- the comparison

def check_structs(header: Header, blocks: Blocks) -> List[String]
  errors = STRUCTS.keys.flat_map do |agc| check_struct(header, blocks, agc, STRUCTS[agc]) end
  unknown = blocks.resources.keys.select do |r| !RESOURCES.key?(r) end
  errors + unknown.map do |r| "resource #{r} has no C struct: add it to RESOURCES of check_bindings.agc" end
end

def check_struct(header: Header, blocks: Blocks, agc: String, c_name: String) -> List[String]
  title = "struct #{agc} (#{c_name})"
  case struct_fields(header, c_name)
    error(e) -> [e.message]
    ok(wanted) ->
      case blocks.structs.get(agc)
        none -> ["#{title} is not in llama.agc"]
        some(got) -> compare_fields(header, title, wanted, got)
      end
  end
end

def compare_fields(header: Header, title: String, wanted: List[Field], got: List[Field]) -> List[String]
  want_names = wanted.map do |f| f.name end
  got_names = got.map do |f| f.name end
  lacking = want_names.select do |n| !got_names.include?(n) end
  surplus = got_names.select do |n| !want_names.include?(n) end
  missing = lacking.map do |n| "#{title}: #{n} is missing from llama.agc" end
  extra = surplus.map do |n| "#{title}: #{n} is not in the header" end
  common_want = want_names.select do |n| got_names.include?(n) end
  common_got = got_names.select do |n| want_names.include?(n) end
  order: List[String] = []
  for i in 0...common_want.size
    if order.empty? and common_want[i] != common_got[i]
      order = [
        "#{title}: the order differs at field #{i + 1}: the header has #{common_want[i]}, llama.agc #{common_got[i]}",
      ]
    end
  end

  types: List[String] = []
  for f in wanted
    match = got.find do |g| g.name == f.name end
    case match
      error(_) -> types = types
      ok(g) -> types = types + field_error(header, title, f, g)
    end
  end

  missing + extra + order + types
end

def field_error(header: Header, title: String, wanted: Field, got: Field) -> List[String]
  case accepts(header, wanted.ctype, got.ctype)
    ok(fits) if fits -> []
    ok(_) -> ["#{title}: #{wanted.name}: the header has `#{wanted.ctype}`, llama.agc `#{got.ctype}`"]
    error(e) -> ["#{title}: #{wanted.name}: #{e.message}"]
  end
end

def check_functions(header: Header, blocks: Blocks) -> List[String]
  bound = blocks.functions.keys.map do |name| Binding(name: name, signature: blocks.functions[name]) end
  frees = blocks.resources.keys.map do |r|
    Binding(name: blocks.resources[r], signature: Signature(result: "Void", params: [r]))
  end

  (bound + frees).flat_map do |b| check_function(header, b.name, b.signature) end
end

def check_function(header: Header, name: String, got: Signature) -> List[String]
  case header.signatures.get(name)
    none -> ["#{name} is not in the headers"]
    some(wanted) if wanted.params.size != got.params.size ->
      [
        "#{name}: the header takes #{wanted.params.size} parameters (#{wanted.params.join(", ")}), llama.agc #{got.params.size} (#{got.params.join(", ")})",
      ]
    some(wanted) ->
      params = (0...got.params.size).flat_map do |i|
        param_error(header, "#{name} parameter #{i + 1}", wanted.params[i], got.params[i])
      end

      params + param_error(header, "#{name} result", wanted.result, got.result)
  end
end

def param_error(header: Header, label: String, ctype: String, agc: String) -> List[String]
  case accepts(header, ctype, agc)
    ok(fits) if fits -> []
    ok(_) -> ["#{label}: the header has `#{ctype}`, llama.agc `#{agc}`"]
    error(e) -> ["#{label}: #{e.message}"]
  end
end

# --- the sizes

## The sizes the helpers of llama.agc assume about C memory: 4-byte integers in the token, position, sequence count and
## sequence id arrays, one byte per logits flag, and pointers of 8 bytes.
def helper_sizes(constants: Map[String, Int]) -> List[List[String]]
  pointer = constants.get("POINTER_BYTES", 0)
  [
    ["pointer_bytes", pointer.to_s, "POINTER_BYTES"],
    ["chat_message_bytes", constants.get("CHAT_MESSAGE_BYTES", 0).to_s, "CHAT_MESSAGE_BYTES"],
    ["chat_message_content_offset", pointer.to_s, "POINTER_BYTES, the content pointer"],
    ["token_bytes", constants.get("BYTES_PER_TOKEN", 0).to_s, "BYTES_PER_TOKEN"],
    ["batch_token_bytes", "4", "put_array_of_int32 of the tokens"],
    ["batch_pos_bytes", "4", "put_array_of_int32 of the positions"],
    ["batch_n_seq_id_bytes", "4", "put_array_of_int32 of the sequence counts"],
    ["batch_seq_id_cell_bytes", "4", "put_int32 of the sequence id"],
    ["batch_seq_id_slot_bytes", pointer.to_s, "POINTER_BYTES, the seq_id cells"],
    ["batch_logits_bytes", "1", "put_bytes of the logits flags"],
  ]
end

## What Agentica says each bound struct weighs.
def agentica_sizes() -> Map[String, Int]
  {
    "ModelParams": Native.size_of(Llama.ModelParams),
    "ContextParams": Native.size_of(Llama.ContextParams),
    "Batch": Native.size_of(Llama.Batch),
    "SamplerChainParams": Native.size_of(Llama.SamplerChainParams),
  }
end

def check_sizes(headers: String, constants: Map[String, Int]) -> Result[List[String]]
  c = try c_sizes(headers)
  helpers = helper_sizes(constants).flat_map do |row| helper_error(c, row) end
  agentica = agentica_sizes()
  structs = STRUCTS.keys.flat_map do |name| struct_size_error(c, agentica, name) end
  ok(helpers + structs)
end

def helper_error(c: Map[String, Int], row: List[String]) -> List[String]
  actual = c.get(row[0], -1)
  return [] if actual.to_s == row[1]

  ["#{row[0]}: C has #{actual}, llama.agc assumes #{row[1]} (#{row[2]})"]
end

def struct_size_error(c: Map[String, Int], agentica: Map[String, Int], name: String) -> List[String]
  return [] if c.get(name, -1) == agentica.get(name, -2)

  ["sizeof #{name}: the C compiler says #{c.get(name, -1)}, Native.size_of says #{agentica.get(name, -2)}"]
end

## The sizes of the C compiler: the program prints one `name value` line per struct and per probe.
def c_sizes(headers: String) -> Result[Map[String, Int]]
  tmp = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([tmp, "check-bindings-#{System.pid()}"])
  try Dir.mkdir_private(dir)
  sizes = compile_and_run(headers, dir)
  _ = Path.remove(dir)
  sizes
end

def compile_and_run(headers: String, dir: String) -> Result[Map[String, Int]]
  source = try Path.join([dir, "sizes.c"])
  program = try Path.join([dir, "sizes"])
  try File.write_text(source, c_source())
  compiled = run_tool("cc", ["-std=c11", "-I", headers, source, "-o", program])
  if !compiled.ok?
    return error("needs a C compiler (cc) to compare the sizes, or use --skip-sizes: #{compiled.message}")
  end

  built = compiled.unwrap!
  return error("the C compiler failed on the headers:\n#{built.stderr}") if built.code != 0

  ran = try run_tool(program, [])
  return error("the sizes program failed:\n#{ran.stderr}") if ran.code != 0

  lines = ran.stdout.split("\n").select do |l| l != "" end
  ok(
    lines.reduce({}) do |acc, l|
      parts = l.split(" ")
      acc.put(parts[0], parts[1].to_i!)
    end,
  )
end

def c_source() -> String
  structs = STRUCTS.keys.map do |a| "  printf(\"#{a} %zu\\n\", sizeof(struct #{STRUCTS[a]}));" end
  probes = PROBES.map do |p| "  printf(\"#{p[0]} %zu\\n\", (size_t)(#{p[1]}));" end
  header = "#include \"llama.h\"\n#include <stddef.h>\n#include <stdio.h>\nint main(void) {\n"
  header + (structs + probes).join("\n") + "\n  return 0;\n}\n"
end

def run_tool(command: String, args: List[String]) -> Result[Ran]
  process = try Process.spawn_captured(command, args, Process.Options(timeout_ms: TOOL_TIMEOUT_MS))
  code = try Process.wait(process, TOOL_TIMEOUT_MS)
  out = try Process.output(process, TOOL_TIMEOUT_MS)
  Process.close(process)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end
