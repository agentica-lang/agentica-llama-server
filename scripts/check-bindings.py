#!/usr/bin/env python3
"""Checks the `extern` blocks of src/llama_server/llama.agc against the llama.cpp headers of deps/headers.

A wrong struct field list or a wrong signature is undefined behavior, so for every bound struct it compares the
field names, their order and their C types, and for every bound function that it exists with the same number of
parameters and the same types. Unless --skip-sizes, it also compares sizeof of each struct, as the C compiler
gives it, with Native.size_of of Agentica (scripts/struct_sizes.agc).

Needs scripts/fetch-headers.sh (and scripts/fetch-llama.sh for the sizes). Python standard library only.
"""
import argparse
import difflib
import os
import re
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
        """The Agentica types a C type may be bound as, or the name of a struct passed by value."""
        words = [w for w in re.findall(r"[A-Za-z_]\w*|\*|\(", ctype) if w != "const"]
        if "*" in words or "(" in words:
            return {"C.Pointer", "C.String", "resource"}
        is_struct = "struct" in words
        words = [w for w in words if w not in ("struct", "enum")]
        base = words[-1]
        if base in self.enums or "enum" in ctype.split():
            return {"C.Int32"}
        if base in self.typedefs and not is_struct:
            return self.kind(self.typedefs[base])
        if base in SCALARS:
            return SCALARS[base]
        return {"struct:" + base}

    def struct_fields(self, name):
        m = re.search(r"\bstruct\s+" + name + r"\s*\{([^}]*)\}", self.text)
        if not m:
            return None
        fields = []
        for decl in m.group(1).split(";"):
            decl = " ".join(decl.split())
            if not decl:
                continue
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


def accepts(header, ctype, agc_type, resources):
    kinds = header.kind(ctype)
    if any(k.startswith("struct:") for k in kinds):
        return agc_type in {STRUCTS_BY_C.get(k[len("struct:"):]) for k in kinds}
    if "resource" in kinds:
        return agc_type in kinds or agc_type in resources
    return agc_type in kinds


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
        fits = [n == gn and accepts(header, c, gt, resources) for (n, c), (gn, gt) in zip(want, got)]
        if len(want) != len(got) or not all(fits):
            shown = [f"{n}: {c}" for n, c in want]
            diff = "\n".join(difflib.unified_diff(
                shown, [f"{n}: {t}" for n, t in got], f"{c_name} (header)", f"{agc_name} (llama.agc)", lineterm=""))
            errors.append(f"struct {agc_name} ({c_name}) differs:\n{diff}")
    for name, free in resources.items():
        functions.setdefault(free, ([name], "Void"))
    for name, (params, ret) in sorted(functions.items()):
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
            if not accepts(header, c, a, resources):
                errors.append(f"{name} parameter {i}: header has `{c}`, llama.agc has `{a}`")
        if not accepts(header, c_ret, ret, resources):
            errors.append(f"{name} result: header has `{c_ret}`, llama.agc has `{ret}`")
    return errors


def check_sizes(header_dir, agentica):
    c_source = '#include "llama.h"\n#include <stdio.h>\nint main(void) {\n' + "".join(
        f'  printf("{a} %zu\\n", sizeof(struct {c}));\n' for a, c in STRUCTS.items()) + "  return 0;\n}\n"
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
        src, exe = os.path.join(tmp, "sizes.c"), os.path.join(tmp, "sizes")
        with open(src, "w") as f:
            f.write(c_source)
        subprocess.run(["cc", "-std=c11", "-I", header_dir, src, "-o", exe], check=True)
        c_sizes = subprocess.run([exe], check=True, capture_output=True, text=True).stdout.split("\n")
    run = subprocess.run([agentica, os.path.join(ROOT, "scripts", "struct_sizes.agc")], cwd=ROOT,
                         capture_output=True, text=True)
    if run.returncode != 0:
        return [f"scripts/struct_sizes.agc failed:\n{run.stdout}{run.stderr}"]
    a_sizes = run.stdout.split("\n")
    if sorted(c_sizes) != sorted(a_sizes):
        return ["sizeof differs:\n" + "\n".join(difflib.unified_diff(
            sorted(c_sizes), sorted(a_sizes), "C sizeof (header)", "Native.size_of (Agentica)", lineterm=""))]
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
    header = Header(read_headers(args.headers))
    structs, resources, functions = read_blocks(args.source)
    errors = check(header, structs, resources, functions)
    if not errors and not args.skip_sizes:
        errors = check_sizes(args.headers, args.agentica)
    if errors:
        print("bindings do not match the headers:", file=sys.stderr)
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"bindings ok: {len(structs)} structs, {len(functions)} functions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
