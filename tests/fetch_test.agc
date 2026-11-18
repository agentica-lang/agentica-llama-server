## scripts/fetch.agc `model`, against a local server that redirects and serves byte ranges (the way Hugging Face and
## its CDN do): the download follows the redirect, takes the file in pieces and checks its sha256. `agentica test` runs
## it from the repo root; it needs no network and fetches nothing else.

import HTTP from "std/http"
import Regex from "std/regex"

SCRIPT = "scripts/fetch.agc"
TIMEOUT_MS = 120_000

ALPHABET = Bytes.from_list((0...256).to_a).unwrap!()
MEBIBYTE = Bytes.concat((0...4096).map do |_| ALPHABET end)

## More than one piece of the download (32 MiB), and not a whole number of them.
DATA = Bytes.concat((0...34).map do |_| MEBIBYTE end) + "tail of the file".bytes

struct Ran
  code: Int
  stdout: String
  stderr: String
end

def serve(request: HTTP.Request) -> Result[HTTP.Response]
  case request.path
    "/Org/Repo/resolve/main/m.gguf" ->
      ok(HTTP.Response(status: 302, headers: [HTTP.Header(name: "Location", value: "/cdn/m.gguf")], body: "".bytes))
    "/cdn/m.gguf" -> ok(ranged(request))
    _ -> ok(HTTP.Response(status: 404, headers: [], body: "".bytes))
  end
end

def ranged(request: HTTP.Request) -> HTTP.Response
  wanted = HTTP.header_values(request.headers, "range")
  return HTTP.Response(status: 200, headers: [], body: DATA) if wanted.empty?

  found = Regex.match(wanted[0], /bytes=(\d+)-(\d+)/).unwrap!
  first = found.groups[1].text.to_i.unwrap!()
  last = [found.groups[2].text.to_i.unwrap!(), DATA.size - 1].min.unwrap!()
  range = "bytes #{first}-#{last}/#{DATA.size}"
  HTTP.Response(
    status: 206,
    headers: [HTTP.Header(name: "Content-Range", value: range)],
    body: DATA.slice(first, last - first + 1),
  )
end

def scratch(name: String) -> Result[String]
  base = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([base, "fetch-test-#{System.pid()}-#{name}"])
  try Path.remove(dir)
  try Dir.mkdir(dir)
  ok(dir)
end

## Runs `fetch.agc model Org/Repo m.gguf SHA256` in `dir`, against the server on `port`.
def fetch(dir: String, port: Int, sha256: String) -> Result[Ran]
  script = try Path.real(SCRIPT)
  agentica = System.env("AGENTICA").unwrap_or("agentica")
  options = Process.Options(timeout_ms: TIMEOUT_MS, chdir: dir, env: {"HF_ENDPOINT": "http://127.0.0.1:#{port}"})
  process = try Process.spawn_captured(agentica, [script, "model", "Org/Repo", "m.gguf", sha256], options)
  code = try Process.wait(process, TIMEOUT_MS)
  out = try Process.output(process, TIMEOUT_MS)
  Process.close(process)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

def test_the_model_is_downloaded_through_the_redirect_in_pieces_and_checked() -> Result[Void]
  server = try HTTP.serve("127.0.0.1", 0, HTTP.app(&serve, 1024))
  port = HTTP.local_port(server)
  dir = try scratch("ok")
  sha256 = OpenSSL.Digest.sha256_hexdigest(DATA)
  first = try fetch(dir, port, sha256)
  again = try fetch(dir, port, sha256)
  HTTP.close_server(server)
  try Test.eq(first.code, 0)
  try Test.eq(try Dir.list(try Path.join([dir, "deps"])), ["m.gguf"])
  try Test.eq(OpenSSL.Digest.hexencode(try File.sha256(try Path.join([dir, "deps", "m.gguf"]))), sha256)
  try Test.eq(again.code, 0)
  _ = Path.remove(dir)
  Test.assert(again.stdout.include?("already fetched"), again.stdout)
end

def test_a_wrong_sha256_fails_and_leaves_no_file() -> Result[Void]
  server = try HTTP.serve("127.0.0.1", 0, HTTP.app(&serve, 1024))
  dir = try scratch("wrong")
  ran = try fetch(dir, HTTP.local_port(server), "0" * 64)
  HTTP.close_server(server)
  try Test.eq(ran.code, 1)
  try Test.eq(try Dir.list(try Path.join([dir, "deps"])), [])
  _ = Path.remove(dir)
  Test.assert(ran.stderr.include?("sha256 is " + OpenSSL.Digest.sha256_hexdigest(DATA)), ran.stderr)
end
