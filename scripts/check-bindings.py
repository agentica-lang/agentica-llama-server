#!/usr/bin/env python3
"""Checks the `extern` blocks of src/llama_server/llama.agc against the llama.cpp headers of deps/headers.

A wrong struct field list or a wrong signature is undefined behavior, so for every bound struct it compares the
field names, their order and their C types, and for every bound function that it exists with the same number of
parameters and the same types, and that a resource is the pointer its `free:` function takes. Unless
--skip-sizes, it also compiles a C program against the headers: the sizeof of each struct, as the C compiler gives
it, must be Native.size_of of Agentica (scripts/struct_sizes.agc), and the sizes that the helpers of llama.agc
assume (the constants at its end, the widths of the batch arrays) must be the C ones.

Needs scripts/fetch-headers.sh (and scripts/fetch-llama.sh for the sizes). Python standard library only.
"""
import argparse
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Agentica struct name -> C struct name.
STRUCTS = {
    "ModelParams": "llama_model_params",
    "ContextParams": "llama_context_params",
    "Batch": "llama_batch",
    "SamplerChainParams": "llama_sampler_chain_params",
}

# Agentica resource name -> the C struct its pointer points to.
RESOURCES = {
    "Model": "llama_model",
    "Context": "llama_context",
    "Sampler": "llama_sampler",
}

# C scalar type -> the Agentica types that lay out the same.
SCALARS = {
    "bool": {"C.Bool"},
    "char": {"C.Int8"},
    "int8_t": {"C.Int8"},
    "uint8_t": {"C.UInt8"},
    "int16_t": {"C.Int16"},
    "uint16_t": {"C.UInt16"},
    "int": {"C.Int32"},
    "int32_t": {"C.Int32"},
    "uint32_t": {"C.UInt32"},
    "int64_t": {"C.Int64"},
    "uint64_t": {"C.UInt64"},
    "size_t": {"C.Int64", "C.UInt64"},
    "float": {"C.Float"},
    "double": {"C.Double"},
    "void": {"Void"},
}

API_MACRO = re.compile(r"\b[A-Z]+_API\b")


def read_headers(header_dir):
    text = ""
    for name in sorted(os.listdir(header_dir)):
        if name.endswith(".h"):
            with open(os.path.join(header_dir, name), encoding="utf-8") as f:
                text += f.read() + "\n"
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"\\\n", " ", text)
    text = re.sub(r"^\s*#[^\n]*$", "", text, flags=re.M)
    return API_MACRO.sub(" ", text)


class Unsupported(Exception):
    """Something the check cannot read or run: reported as a failure, not as a crash."""


class Header:
    def __init__(self, text):
        self.text = text
        self.typedefs = {}
        self.enums = set(re.findall(r"\benum\s+(\w+)\s*\{", text))
        for m in re.finditer(r"\btypedef\s+enum\s*\w*\s*\{[^}]*\}\s*(\w+)\s*;", text):
            self.enums.add(m.group(1))
        for m in re.finditer(r"\btypedef\s+([^;{}()]+?)\s+(\w+)\s*;", text):
            self.typedefs[m.group(2)] = m.group(1)
        for m in re.finditer(r"\btypedef\s+[^;{}]*?\(\s*\*\s*(\w+)\s*\)\s*\([^;]*\)\s*;", text):
            self.typedefs[m.group(1)] = "void *"

    def kind(self, ctype):
        """How a C type is bound: ("ptr", pointee or None, is_char), ("struct", name) or ("scalar", Agentica types)."""
        words = [w for w in re.findall(r"[A-Za-z_]\w*|\*|\(", ctype) if w != "const"]
        if "(" in words:
            return ("ptr", None, False)
        stars = words.count("*")
        is_struct = "struct" in words
        words = [w for w in words if w not in ("struct", "enum", "*")]
        if "enum" in ctype.split():
            return ("scalar", {"C.Int32"})
        if "unsigned" in words:
            rest = [w for w in words if w != "unsigned"]
            width = {"": "C.UInt32", "int": "C.UInt32", "char": "C.UInt8", "short": "C.UInt16"}.get(" ".join(rest))
            if width is None or stars:
                raise Unsupported(f"unsupported C type `{ctype}`")
            return ("scalar", {width})
        base = words[-1]
        if base in ("long", "short", "signed"):
            raise Unsupported(f"unsupported C type `{ctype}`")
        if stars:
            return ("ptr", base, base == "char")
        if base in self.enums:
            return ("scalar", {"C.Int32"})
        if base in self.typedefs and not is_struct:
            return self.kind(self.typedefs[base])
        if base in SCALARS:
            return ("scalar", SCALARS[base])
        return ("struct", base)

    def struct_fields(self, name):
        m = re.search(r"\bstruct\s+" + name + r"\s*\{", self.text)
        if not m:
            return None
        depth, i = 1, m.end()
        while depth:
            depth += {"{": 1, "}": -1}.get(self.text[i], 0)
            i += 1
        body = self.text[m.end():i - 1]
        if "{" in body:
            raise Unsupported(f"unsupported field in {name}: a nested struct, union or enum")
        fields = []
        for decl in body.split(";"):
            decl = " ".join(decl.split())
            if not decl:
                continue
            if any(c in decl for c in "([:,"):
                raise Unsupported(f"unsupported field `{decl}` in {name}: a function pointer, array, bitfield or "
                                  "several declarators")
            fm = re.match(r"(.*?)\s*(\w+)$", decl)
            fields.append((fm.group(2), fm.group(1)))
        return fields

    def function(self, name):
        for m in re.finditer(r"\b" + name + r"\s*\(", self.text):
            start = max(self.text.rfind(c, 0, m.start()) for c in ";{}") + 1
            end = self.text.find(";", m.end())
            close = self.text.rfind(")", m.end(), end)
            if end < 0 or close < 0 or "{" in self.text[m.end():end]:
                continue
            ret = self.text[start:m.start()].strip()
            if not ret or re.match(r"return\b", ret) or any(c in ret for c in "=(,"):
                continue
            return ret, [param_type(p) for p in split_params(self.text[m.end():close])]
        return None


def split_params(text):
    text = " ".join(text.split())
    if text in ("", "void"):
        return []
    out, depth, current = [], 0, ""
    for c in text:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == "," and depth == 0:
            out.append(current.strip())
            current = ""
        else:
            current += c
    out.append(current.strip())
    return out


def param_type(param):
    if "(" in param:
        return param
    m = re.match(r"(.*?[\s*])(\w+)$", param)
    if m and m.group(1).strip() not in ("", "struct", "enum", "const", "unsigned"):
        return m.group(1).strip()
    return param


def read_blocks(path):
    """The structs, resources and functions of every `extern "lib"` block of the file."""
    structs, resources, functions = {}, {}, {}
    block, struct, signature = False, None, ""
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for line in lines:
        code = line.split("##")[0].rstrip()
        if re.match(r'extern\s+"', code):
            block = True
        elif block and code == "end":
            block = False
        elif block and struct is not None:
            if code.strip() == "end":
                struct = None
            elif code.strip():
                name, ctype = [s.strip() for s in code.split(":")]
                structs[struct].append((name, ctype))
        elif block and re.match(r"\s+struct\s+\w+$", code):
            struct = code.split()[1]
            structs[struct] = []
        elif block and re.match(r"\s+resource\s+\w+", code):
            m = re.match(r"\s+resource\s+(\w+),\s*free:\s*(\w+)", code)
            resources[m.group(1)] = m.group(2)
        elif block and (signature or re.match(r"\s+(compute\s+)?def\s", code)):
            signature += " " + code.strip()
            if signature.count("(") == signature.count(")") and "->" in signature:
                m = re.search(r"def\s+(\w+)\((.*)\)\s*->\s*(.+)$", signature)
                params = [p.split(":", 1)[1].strip() for p in split_params(m.group(2))]
                functions[m.group(1)] = (params, m.group(3).strip())
                signature = ""
    return structs, resources, functions


STRUCTS_BY_C = {c: a for a, c in STRUCTS.items()}


def pointee(header, ctype):
    """The struct a single pointer in ctype points to, through typedefs, or None."""
    kind = header.kind(ctype)
    if kind[0] == "ptr":
        return kind[1]
    base = re.findall(r"[A-Za-z_]\w*", ctype)[-1]
    return pointee(header, header.typedefs[base]) if base in header.typedefs else None


def accepts(header, ctype, agc_type):
    kind = header.kind(ctype)
    if kind[0] == "struct":
        return agc_type == STRUCTS_BY_C.get(kind[1])
    if kind[0] == "ptr" and agc_type in RESOURCES:
        return pointee(header, ctype) == RESOURCES[agc_type]
    if kind[0] == "ptr":
        return agc_type == "C.Pointer" or (agc_type == "C.String" and kind[2])
    return agc_type in kind[1]


def check(header, structs, resources, functions):
    errors = []
    for agc_name, c_name in STRUCTS.items():
        want = header.struct_fields(c_name)
        if want is None:
            errors.append(f"struct {c_name} is not in the headers")
            continue
        if agc_name not in structs:
            errors.append(f"struct {agc_name} ({c_name}) is not in llama.agc")
            continue
        got = structs[agc_name]
        fits = [n == gn and accepts(header, c, gt) for (n, c), (gn, gt) in zip(want, got)]
        if len(want) != len(got) or not all(fits):
            shown = [f"{n}: {c}" for n, c in want]
            diff = "\n".join(difflib.unified_diff(
                shown, [f"{n}: {t}" for n, t in got], f"{c_name} (header)", f"{agc_name} (llama.agc)", lineterm=""))
            errors.append(f"struct {agc_name} ({c_name}) differs:\n{diff}")
    for name in resources:
        if name not in RESOURCES:
            errors.append(f"resource {name} has no C struct: add it to RESOURCES of check-bindings.py")
    bound = sorted(functions.items()) + [(f, ([r], "Void")) for r, f in sorted(resources.items())]
    for name, (params, ret) in bound:
        found = header.function(name)
        if found is None:
            errors.append(f"{name} is not in the headers")
            continue
        c_ret, c_params = found
        if len(c_params) != len(params):
            errors.append(f"{name}: header takes {len(c_params)} parameters ({', '.join(c_params)}), "
                          f"llama.agc {len(params)} ({', '.join(params)})")
            continue
        for i, (c, a) in enumerate(zip(c_params, params), 1):
            if not accepts(header, c, a):
                errors.append(f"{name} parameter {i}: header has `{c}`, llama.agc has `{a}`")
        if not accepts(header, c_ret, ret):
            errors.append(f"{name} result: header has `{c_ret}`, llama.agc has `{ret}`")
    return errors


C_PROBES = [
    ("chat_message_bytes", "sizeof(llama_chat_message)"),
    ("pointer_bytes", "sizeof(void *)"),
    ("chat_message_content_offset", "offsetof(llama_chat_message, content)"),
    ("token_bytes", "sizeof(llama_token)"),
    ("batch_token_bytes", "sizeof(*((llama_batch *)0)->token)"),
    ("batch_pos_bytes", "sizeof(*((llama_batch *)0)->pos)"),
    ("batch_n_seq_id_bytes", "sizeof(*((llama_batch *)0)->n_seq_id)"),
    ("batch_seq_id_cell_bytes", "sizeof(**((llama_batch *)0)->seq_id)"),
    ("batch_seq_id_slot_bytes", "sizeof(*((llama_batch *)0)->seq_id)"),
    ("batch_logits_bytes", "sizeof(*((llama_batch *)0)->logits)"),
]


def run_c(header_dir):
    """The sizes of the C compiler: one `name value` line per struct and per probe."""
    cc = shutil.which("cc")
    if cc is None:
        raise Unsupported("needs a C compiler (cc) to compare the sizes; or use --skip-sizes")
    lines = [f'  printf("{a} %zu\\n", sizeof(struct {c}));' for a, c in STRUCTS.items()]
    lines += [f'  printf("{name} %zu\\n", (size_t)({expr}));' for name, expr in C_PROBES]
    source = '#include "llama.h"\n#include <stddef.h>\n#include <stdio.h>\nint main(void) {\n' \
        + "\n".join(lines) + "\n  return 0;\n}\n"
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
        src, exe = os.path.join(tmp, "sizes.c"), os.path.join(tmp, "sizes")
        with open(src, "w") as f:
            f.write(source)
        built = subprocess.run([cc, "-std=c11", "-I", header_dir, src, "-o", exe], capture_output=True, text=True)
        if built.returncode != 0:
            raise Unsupported(f"the C compiler failed on the headers:\n{built.stderr}")
        out = subprocess.run([exe], check=True, capture_output=True, text=True).stdout
    return {k: int(v) for k, v in (line.split() for line in out.splitlines())}


def read_constants(path):
    with open(path, encoding="utf-8") as f:
        return {k: int(v) for k, v in re.findall(r"^([A-Z_]+) = (\d+)$", f.read(), flags=re.M)}


def check_helpers(c, constants):
    """What the helpers of llama.agc assume about C memory: they write 4-byte integers into the token, position,
    sequence count and sequence id arrays, one byte per logits flag, and pointers of 8 bytes."""
    expected = [
        ("pointer_bytes", constants.get("POINTER_BYTES"), "POINTER_BYTES"),
        ("chat_message_bytes", constants.get("CHAT_MESSAGE_BYTES"), "CHAT_MESSAGE_BYTES"),
        ("chat_message_content_offset", constants.get("POINTER_BYTES"), "POINTER_BYTES (the content pointer)"),
        ("token_bytes", constants.get("BYTES_PER_TOKEN"), "BYTES_PER_TOKEN"),
        ("batch_token_bytes", 4, "put_array_of_int32 of the tokens"),
        ("batch_pos_bytes", 4, "put_array_of_int32 of the positions"),
        ("batch_n_seq_id_bytes", 4, "put_array_of_int32 of the sequence counts"),
        ("batch_seq_id_cell_bytes", 4, "put_int32 of the sequence id"),
        ("batch_seq_id_slot_bytes", constants.get("POINTER_BYTES"), "POINTER_BYTES (the seq_id cells)"),
        ("batch_logits_bytes", 1, "put_bytes of the logits flags"),
    ]
    return [f"{name}: C has {c[name]}, llama.agc assumes {want} ({why})"
            for name, want, why in expected if c[name] != want]


def check_sizes(header_dir, source, agentica):
    c = run_c(header_dir)
    errors = check_helpers(c, read_constants(source))
    if errors:
        return errors
    try:
        run = subprocess.run([agentica, os.path.join(ROOT, "scripts", "struct_sizes.agc")], cwd=ROOT,
                             capture_output=True, text=True)
    except FileNotFoundError:
        raise Unsupported(f"{agentica} not found: set AGENTICA, or use --skip-sizes")
    if run.returncode != 0:
        return [f"scripts/struct_sizes.agc failed:\n{run.stdout}{run.stderr}"]
    want = sorted(f"{a} {c[a]}" for a in STRUCTS)
    got = sorted(run.stdout.split("\n")[:-1])
    if want != got:
        return ["sizeof differs:\n" + "\n".join(difflib.unified_diff(
            want, got, "C sizeof (header)", "Native.size_of (Agentica)", lineterm=""))]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--headers", default=os.path.join(ROOT, "deps", "headers"))
    parser.add_argument("--source", default=os.path.join(ROOT, "src", "llama_server", "llama.agc"))
    parser.add_argument("--skip-sizes", action="store_true")
    parser.add_argument("--agentica", default=os.environ.get("AGENTICA", "agentica"))
    args = parser.parse_args()

    if not os.path.isfile(os.path.join(args.headers, "llama.h")):
        print(f"no llama.h in {args.headers}: run scripts/fetch-headers.sh", file=sys.stderr)
        return 2
    try:
        header = Header(read_headers(args.headers))
        structs, resources, functions = read_blocks(args.source)
        errors = check(header, structs, resources, functions)
        if not errors and not args.skip_sizes:
            errors = check_sizes(args.headers, args.source, args.agentica)
    except Unsupported as e:
        errors = [str(e)]
    if errors:
        print("bindings do not match the headers:", file=sys.stderr)
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"bindings ok: {len(structs)} structs, {len(functions)} functions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
