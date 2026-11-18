## scripts/fetch.agc `model`, against a local server that redirects and serves byte ranges (the way Hugging Face and
## its CDN do): the download follows the redirect (absolute, relative or a loop), takes the file in pieces and checks its
## sha256. `agentica test` runs
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
    "/Org/Repo/resolve/main/m.gguf" -> ok(redirect("/cdn/m.gguf"))
    "/Org/Rel/resolve/main/m.gguf" -> ok(redirect("pieces/m.gguf"))
    "/Org/Loop/resolve/main/m.gguf" -> ok(redirect(request.path))
    "/Org/Plain/resolve/main/m.gguf" -> ok(HTTP.Response(status: 200, headers: [], body: DATA))
    "/cdn/m.gguf" -> ok(ranged(request))
    "/Org/Rel/resolve/main/pieces/m.gguf" -> ok(ranged(request))
    _ -> ok(HTTP.Response(status: 404, headers: [], body: "".bytes))
  end
end

def redirect(location: String) -> HTTP.Response
  HTTP.Response(status: 302, headers: [HTTP.Header(name: "Location", value: location)], body: "".bytes)
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

## Runs `body` with a folder of its own, which is removed after it, whatever the result.
def with_dir(name: String, body: Fn[String, Result[Void]]) -> Result[Void]
  base = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([base, "fetch-test-#{System.pid()}-#{name}"])
  try Path.remove(dir)
  try Dir.mkdir(dir)
  result = body.call(dir)
  _ = Path.remove(dir)
  result
end

## Runs `body` with the port of a local server, which is closed after it.
def with_server(body: Fn[Int, Result[Void]]) -> Result[Void]
  server = try HTTP.serve("127.0.0.1", 0, HTTP.app(&serve, 1024))
  result = body.call(HTTP.local_port(server))
  HTTP.close_server(server)
  result
end

## Runs `fetch.agc model REPO m.gguf SHA256` in `dir`, against the server on `port` (with a slash after the endpoint).
def fetch(dir: String, port: Int, repo: String, sha256: String) -> Result[Ran]
  script = try Path.real(SCRIPT)
  agentica = System.env("AGENTICA").unwrap_or("agentica")
  endpoint = "http://127.0.0.1:#{port}/"
  options = Process.Options(timeout_ms: TIMEOUT_MS, chdir: dir, env: {"HF_ENDPOINT": endpoint})
  process = try Process.spawn_captured(agentica, [script, "model", repo, "m.gguf", sha256], options)
  code = try Process.wait(process, TIMEOUT_MS)
  out = try Process.output(process, TIMEOUT_MS)
  Process.close(process)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

def deps(dir: String) -> Result[List[String]] = Dir.list(try Path.join([dir, "deps"]))

def downloaded(repo: String) -> Result[Void]
  sha256 = OpenSSL.Digest.sha256_hexdigest(DATA)
  with_server do |port|
    with_dir(repo) do |dir|
      first = try fetch(dir, port, "Org/#{repo}", sha256)
      again = try fetch(dir, port, "Org/#{repo}", sha256)
      try Test.eq(first.code, 0)
      try Test.eq(try deps(dir), ["m.gguf"])
      try Test.eq(OpenSSL.Digest.hexencode(try File.sha256(try Path.join([dir, "deps", "m.gguf"]))), sha256)
      try Test.eq(again.code, 0)
      Test.assert(again.stdout.include?("already fetched"), again.stdout)
    end
  end
end

## A failed fetch: exit 1, the message in stderr and no file left (not even a `.part`).
def refused(repo: String, sha256: String, message: String) -> Result[Void]
  with_server do |port|
    with_dir(repo) do |dir|
      ran = try fetch(dir, port, "Org/#{repo}", sha256)
      try Test.eq(ran.code, 1)
      try Test.eq(try deps(dir), [])
      Test.assert(ran.stderr.include?(message), ran.stderr)
    end
  end
end

def test_the_model_is_downloaded_through_the_redirect_in_pieces_and_checked() -> Result[Void] = downloaded("Repo")

def test_a_relative_location_is_followed() -> Result[Void] = downloaded("Rel")

def test_a_wrong_sha256_fails_and_leaves_no_file() -> Result[Void]
  refused("Repo", "0" * 64, "sha256 is " + OpenSSL.Digest.sha256_hexdigest(DATA))
end

def test_a_redirect_loop_fails() -> Result[Void]
  refused("Loop", OpenSSL.Digest.sha256_hexdigest(DATA), "too many redirects")
end

def test_a_server_that_ignores_range_fails_with_a_hint() -> Result[Void]
  refused("Plain", OpenSSL.Digest.sha256_hexdigest(DATA), "the server ignores Range")
end
