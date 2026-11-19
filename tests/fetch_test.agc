## scripts/fetch.agc against a local server that redirects and then serves the whole file (the way Hugging Face and
## its CDN do): the download follows the redirect (absolute, relative or a loop) and checks the sha256; a failed fetch leaves what was there. `agentica test` runs it from the repo root; it needs no network.

import Fetch from "../scripts/fetch"
import HTTP from "std/http"

SCRIPT = "scripts/fetch.agc"
TIMEOUT_MS = 120_000

ALPHABET = Bytes.from_list((0...256).to_a).unwrap!()
MEBIBYTE = Bytes.concat((0...4096).map do |_| ALPHABET end)

## Several MiB, so the download streams, and not a whole number of them.
DATA = Bytes.concat((0...4).map do |_| MEBIBYTE end) + "tail of the file".bytes

struct Ran
  code: Int
  stdout: String
  stderr: String
end

def serve(request: HTTP.Request) -> Result[HTTP.Response]
  case request.path
    "/Org/Repo/resolve/main/m.gguf" -> ok(redirect("/cdn/m.gguf"))
    "/Org/Rel/resolve/main/m.gguf" -> ok(redirect("files/m.gguf"))
    "/Org/Loop/resolve/main/m.gguf" -> ok(redirect(request.path))
    "/cdn/m.gguf" -> ok(whole(request))
    "/Org/Rel/resolve/main/files/m.gguf" -> ok(whole(request))
    _ -> ok(HTTP.Response(status: 404, headers: [], body: "".bytes))
  end
end

def redirect(location: String) -> HTTP.Response
  HTTP.Response(status: 302, headers: [HTTP.Header(name: "Location", value: location)], body: "".bytes)
end

def whole(request: HTTP.Request) -> HTTP.Response
  body = DATA
  if request.method == "HEAD"
    body = "".bytes
  end

  HTTP.Response(status: 200, headers: [], body: body)
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
  HTTP.shutdown(server)
  result
end

## Runs `fetch.agc ARGS` in `dir` with the given environment.
def run_fetch(dir: String, args: List[String], env: Map[String, String]) -> Result[Ran]
  script = try Path.real(SCRIPT)
  agentica = System.env("AGENTICA").unwrap_or("agentica")
  process = try Process.spawn_captured(
    agentica,
    [script] + args,
    Process.Options(timeout_ms: TIMEOUT_MS, chdir: dir, env: env),
  )

  code = try Process.wait(process, TIMEOUT_MS)
  out = try Process.output(process, TIMEOUT_MS)
  Process.close(process)
  ok(Ran(code: code, stdout: out.stdout, stderr: out.stderr))
end

## `fetch.agc model REPO m.gguf SHA256` against the server on `port` (with a slash after the endpoint).
def fetch(dir: String, port: Int, repo: String, sha256: String) -> Result[Ran]
  run_fetch(dir, ["model", repo, "m.gguf", sha256], {"HF_ENDPOINT": "http://127.0.0.1:#{port}/"})
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

## A failed fetch: exit 1, the message in stderr and no file left (not even a hidden `.agc-part`).
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

def test_the_model_is_downloaded_through_the_redirect_and_checked() -> Result[Void] = downloaded("Repo")

def test_a_relative_location_is_followed() -> Result[Void] = downloaded("Rel")

def test_a_wrong_sha256_fails_and_leaves_no_file() -> Result[Void]
  refused("Repo", "0" * 64, "does not match the sha256 digest")
end

def test_a_redirect_loop_fails() -> Result[Void]
  refused("Loop", OpenSSL.Digest.sha256_hexdigest(DATA), "too many redirects")
end

def test_a_stale_model_is_replaced() -> Result[Void]
  sha256 = OpenSSL.Digest.sha256_hexdigest(DATA)
  with_server do |port|
    with_dir("stale") do |dir|
      try Dir.mkdir(try Path.join([dir, "deps"]))
      try File.write_text(try Path.join([dir, "deps", "m.gguf"]), "truncated")
      ran = try fetch(dir, port, "Org/Repo", sha256)
      try Test.eq(ran.code, 0)
      try Test.eq(try deps(dir), ["m.gguf"])
      Test.eq(OpenSSL.Digest.hexencode(try File.sha256(try Path.join([dir, "deps", "m.gguf"]))), sha256)
    end
  end
end

def test_a_missing_file_is_not_retried() -> Result[Void]
  with_server do |port|
    with_dir("missing") do |dir|
      ran = try fetch(dir, port, "Org/Missing", "0" * 64)
      try Test.eq(ran.code, 1)
      try Test.assert(ran.stderr.include?("HTTP 404"), ran.stderr)
      Test.assert(!ran.stderr.include?("trying again"), ran.stderr)
    end
  end
end

def test_only_a_transient_failure_is_retried() -> Result[Void]
  for message in [
    "network: connection failed\n  host: h",
    "network: end of input",
    "network: TLS handshake failed",
    "http: truncated HTTP body",
    "http://h/f: HTTP 503",
  ]
    try Test.assert(Fetch.transient?(message), message)
  end

  for message in [
    "http://h/f: HTTP 404",
    "http://h/f: HTTP 407",
    "http: proxy refused the CONNECT",
    "network: proxy connect failed",
    "http://h/f: a redirect with no Location",
  ]
    try Test.assert(!Fetch.transient?(message), message)
  end

  ok()
end

def test_a_redirect_never_leaves_https() -> Result[Void]
  try Test.assert(Fetch.downgrade?("https://a.test/x", "http://a.test/x"), "https to http")
  try Test.assert(!Fetch.downgrade?("https://a.test/x", "https://b.test/x"), "https to https")
  Test.assert(!Fetch.downgrade?("http://a.test/x", "http://b.test/x"), "http to http")
end

def test_a_location_is_resolved_against_the_url() -> Result[Void]
  base = "https://a.test/dir/file?x=1#top"
  try Test.eq(Fetch.absolute(base, "https://b.test/p"), "https://b.test/p")
  try Test.eq(Fetch.absolute(base, "//b.test/p"), "https://b.test/p")
  try Test.eq(Fetch.absolute(base, "/p?y=2"), "https://a.test/p?y=2")
  try Test.eq(Fetch.absolute(base, "other"), "https://a.test/dir/other")
  Test.eq(Fetch.absolute("http://a.test", "other"), "http://a.test/other")
end

def archive_answer(bytes: Bytes, request: HTTP.Request) -> Result[HTTP.Response]
  if request.path.start_with?("/tTest/") and request.path.end_with?(".tar.gz")
    return ok(HTTP.Response(status: 200, headers: [], body: bytes))
  end

  ok(HTTP.Response(status: 404, headers: [], body: "".bytes))
end

## An archive of one file that is not a member of the release.
def make_archive(dir: String) -> Result[String]
  work = try Path.join([dir, "work"])
  try Dir.mkdir(try Path.join([work, "llama-tTest"]))
  try File.write_text(try Path.join([work, "llama-tTest", "other.txt"]), "not a library")
  archive = try Path.join([dir, "release.tar.gz"])
  tar = try Process.spawn_captured("tar", ["-czf", archive, "-C", work, "llama-tTest"])
  code = try Process.wait(tar, TIMEOUT_MS)
  Process.close(tar)
  return error("tar failed") if code != 0

  ok(archive)
end

## Runs `fetch.agc llama ARGS` in `dir` against a release (CPU and Vulkan archives of the same bytes) whose archive has
## no member of the release, with old libraries in place. Returns the folder of the libraries.
def fetch_llama_from_bad_archive(dir: String, args: List[String], stamp: String) -> Result[Ran]
  archive = try make_archive(dir)
  bytes = try File.open(archive) do |f| File.read_bytes(f, 1_048_576) end
  sha256 = OpenSSL.Digest.hexencode(try File.sha256(archive))
  try Dir.mkdir(try Path.join([dir, "scripts"]))
  try File.write_text(try Path.join([dir, "scripts", "llama-release"]), "tTest #{sha256}\nvulkan #{sha256}\n")
  libraries = try Path.join([dir, "native", "linux"])
  try Dir.mkdir(libraries)
  try File.write_text(try Path.join([libraries, "TAG"]), stamp)
  try File.write_text(try Path.join([libraries, "libllama.so.1"]), "kept")
  server = try HTTP.serve("127.0.0.1", 0, HTTP.app(->(request) { archive_answer(bytes, request) }, 1024))
  ran = run_fetch(dir, ["llama"] + args, {"LLAMA_RELEASES": "http://127.0.0.1:#{HTTP.local_port(server)}"})
  HTTP.shutdown(server)
  ran
end

def old_libraries_are_there(dir: String, stamp: String) -> Result[Void]
  libraries = try Path.join([dir, "native", "linux"])
  try Test.eq(try Dir.list(libraries), ["TAG", "libllama.so.1"])
  try Test.eq(try File.read_text(try Path.join([libraries, "TAG"])), stamp)
  Test.eq(try Dir.list(try Path.join([dir, "native"])), ["linux"])
end

def test_a_failed_extraction_keeps_the_libraries_that_are_there() -> Result[Void]
  with_dir("extract") do |dir|
    ran = try fetch_llama_from_bad_archive(dir, [], "old")
    try Test.eq(ran.code, 1)
    try Test.assert(ran.stdout.include?("ubuntu-x64.tar.gz: sha256 ok"), ran.stdout)
    try Test.eq(try deps(dir), [])
    old_libraries_are_there(dir, "old")
  end
end

def test_the_vulkan_variant_takes_the_vulkan_archive() -> Result[Void]
  with_dir("vulkan") do |dir|
    ran = try fetch_llama_from_bad_archive(dir, ["--variant", "vulkan"], "old")
    try Test.eq(ran.code, 1)
    try Test.assert(ran.stdout.include?("ubuntu-vulkan-x64.tar.gz: sha256 ok"), ran.stdout)
    try Test.eq(try deps(dir), [])
    old_libraries_are_there(dir, "old")
  end
end

def test_an_unknown_variant_is_refused() -> Result[Void]
  with_dir("variant") do |dir|
    ran = try fetch_llama_from_bad_archive(dir, ["--variant=cuda"], "old")
    try Test.eq(ran.code, 1)
    try Test.assert(ran.stderr.include?("unknown variant cuda: cpu, vulkan"), ran.stderr)
    old_libraries_are_there(dir, "old")
  end
end

## The TAG of the libraries says the release and the variant: the bare tag is the CPU build, `tag variant` another.
def test_the_tag_says_which_build_is_there() -> Result[Void]
  try with_dir("stamp-vulkan") do |dir|
    ran = try fetch_llama_from_bad_archive(dir, ["--variant", "vulkan"], "tTest")
    try Test.assert(ran.stdout.include?("ubuntu-vulkan-x64.tar.gz: sha256 ok"), ran.stdout)
    Test.eq(ran.code, 1)
  end

  try with_dir("stamp-cpu") do |dir|
    ran = try fetch_llama_from_bad_archive(dir, [], "tTest vulkan")
    try Test.assert(ran.stdout.include?("ubuntu-x64.tar.gz: sha256 ok"), ran.stdout)
    Test.eq(ran.code, 1)
  end

  with_dir("stamp-same") do |dir|
    ran = try fetch_llama_from_bad_archive(dir, [], "tTest")
    try Test.eq(ran.code, 0)
    Test.assert(ran.stdout.include?("already fetched"), ran.stdout)
  end
end
