## Fetches what the project does not commit, from the repo root:
##
##   agentica scripts/fetch.agc llama     the prebuilt CPU llama.cpp release into native/linux
##   agentica scripts/fetch.agc headers   llama.h and the headers it includes into deps/headers
##   agentica scripts/fetch.agc model [REPO FILE SHA256]   a GGUF model from Hugging Face into deps/
##   agentica scripts/fetch.agc all       the three, with the default model
##
## The release is the one of scripts/llama-release: the build tag and the sha256 of its Linux x86_64 archive, then
## the sha256 of each header. The default model is the one of scripts/model. A download follows redirects (never from
## https to http), and nothing takes its final name before its sha256 is checked. Each step skips what it already has.
## HF_ENDPOINT (as for the Hugging Face tools) replaces https://huggingface.co. It does not import the bindings, so it
## runs before the libraries that the manifest names exist.

import Archive from "std/archive"
import HTTP from "std/http"
import Regex from "std/regex"

def main() -> Void
  case run(System.args())
    ok(_) -> puts("done")
    error(e) ->
      IO.warn("fetch: #{e.message}")
      System.exit(1)
  end
end

private

RELEASE_FILE = "scripts/llama-release"
MODEL_FILE = "scripts/model"
LIBRARIES = "native/linux"
HEADERS = "deps/headers"
DOWNLOADS = "deps"

TOOL_TIMEOUT_MS = 30_000
ATTEMPTS = 3
MAX_REDIRECTS = 5
PIECE_TIMEOUT_MS = 600_000
READ_TIMEOUT_MS = 60_000
CHUNK_BYTES = 33_554_432
WRITE_BYTES = 1_048_576

# The files of the release that the server and `llama-server` (the benchmark) use. The archive tells nothing about
# what it holds, so a release with other files needs this list changed: the extraction fails on a missing one. The
# versioned libraries are renamed to their soname (`libllama.so.1.0.0` is `libllama.so.1`), which the loader looks for.
RELEASE_MEMBERS = [
  "llama-server",
  "libllama-server-impl.so",
  "libllama-common.so.1.0.0",
  "libmtmd.so.1.0.0",
  "libllama.so.1.0.0",
  "libggml.so.1.0.0",
  "libggml-base.so.1.0.0",
  "libggml-cpu-alderlake.so",
  "libggml-cpu-cannonlake.so",
  "libggml-cpu-cascadelake.so",
  "libggml-cpu-cooperlake.so",
  "libggml-cpu-haswell.so",
  "libggml-cpu-icelake.so",
  "libggml-cpu-ivybridge.so",
  "libggml-cpu-piledriver.so",
  "libggml-cpu-sandybridge.so",
  "libggml-cpu-sapphirerapids.so",
  "libggml-cpu-skylakex.so",
  "libggml-cpu-sse42.so",
  "libggml-cpu-x64.so",
  "libggml-cpu-zen4.so",
]

## A file and the sha256 it must have.
struct Pin
  name: String
  sha256: String
end

struct Release
  tag: String
  archive: Pin
  headers: List[Pin]
end

def run(args: List[String]) -> Result[Void]
  return error("usage: agentica scripts/fetch.agc llama | headers | model [REPO FILE SHA256] | all") if args.empty?

  case args[0]
    "llama" -> fetch_llama()
    "headers" -> fetch_headers()
    "model" -> fetch_model(args.drop(1))
    "all" -> fetch_all()
    _ -> error("unknown step #{args[0]}: llama, headers, model or all")
  end
end

def fetch_all() -> Result[Void]
  try fetch_llama()
  try fetch_headers()
  fetch_model([])
end

## `scripts/llama-release`: `TAG ARCHIVE_SHA256`, then a `PATH SHA256` line for each header.
def read_release() -> Result[Release]
  lines = (try File.read_text(RELEASE_FILE)).split("\n").select do |l| l.strip() != "" end
  first = lines.first.split(" ")
  return error("#{RELEASE_FILE}: the first line is `TAG SHA256`") if first.size != 2

  pins: List[Pin] = []
  for line in lines.drop(1)
    words = line.split(" ")
    return error("#{RELEASE_FILE}: `#{line}` is not `PATH SHA256`") if words.size != 2

    pins = pins.push(Pin(name: words[0], sha256: words[1]))
  end

  ok(
    Release(
      tag: first[0],
      archive: Pin(name: "llama-#{first[0]}-bin-ubuntu-x64.tar.gz", sha256: first[1]),
      headers: pins,
    ),
  )
end

# --- the release

def fetch_llama() -> Result[Void]
  release = try read_release()
  return already("already fetched: #{LIBRARIES}") if current?(LIBRARIES, release.tag)

  try Dir.mkdir(DOWNLOADS)
  archive = "#{DOWNLOADS}/#{release.archive.name}"
  url = "https://github.com/ggml-org/llama.cpp/releases/download/#{release.tag}/#{release.archive.name}"
  installed = case download_checked(url, archive, release.archive.sha256)
    ok(_) -> install_release(archive, release.tag)
    error(e) -> error(e.message)
  end

  _ = Path.remove(archive)
  installed
end

## The archive is extracted into a scratch folder first, so a failure leaves the libraries that are there.
def install_release(archive: String, tag: String) -> Result[Void]
  scratch = "#{DOWNLOADS}/llama-#{tag}"
  _ = Path.remove(scratch)
  members = RELEASE_MEMBERS.map do |m| "llama-#{tag}/#{m}" end
  try cleaning(Archive.extract_tar(archive, members, scratch), scratch)
  _ = Path.remove(LIBRARIES)
  try Dir.mkdir(LIBRARIES)
  for name in RELEASE_MEMBERS
    try Path.rename("#{scratch}/llama-#{tag}/#{name}", "#{LIBRARIES}/#{soname(name)}")
  end

  _ = Path.remove(scratch)
  try executable("#{LIBRARIES}/llama-server")
  File.write_text("#{LIBRARIES}/TAG", tag)
end

## The extraction writes private files without the execute bit, and Agentica has no chmod.
def executable(path: String) -> Result[Void]
  process = try Process.spawn_captured("chmod", ["u+x", path])
  code = try Process.wait(process, TOOL_TIMEOUT_MS)
  Process.close(process)
  return error("chmod u+x #{path} failed") if code != 0

  ok()
end

def soname(file: String) -> String = Regex.replace(file, /(\.so\.\d+)\.\d+\.\d+$/, "$1").unwrap_or(file)

# --- the headers

## The headers go into a folder of their own, which takes the place of the old one when all of them are checked.
def fetch_headers() -> Result[Void]
  release = try read_release()
  return already("already fetched: #{HEADERS}") if current?(HEADERS, release.tag)

  stage = "#{HEADERS}.new"
  _ = Path.remove(stage)
  try cleaning(stage_headers(release, stage), stage)
  _ = Path.remove(HEADERS)
  Path.rename(stage, HEADERS)
end

def stage_headers(release: Release, stage: String) -> Result[Void]
  try Dir.mkdir(stage)
  for pin in release.headers
    url = "https://raw.githubusercontent.com/ggml-org/llama.cpp/#{release.tag}/#{pin.name}"
    try download_checked(url, "#{stage}/#{pin.name.split("/").last}", pin.sha256)
  end

  File.write_text("#{stage}/TAG", release.tag)
end

# --- the model

def fetch_model(args: List[String]) -> Result[Void]
  return error("usage: agentica scripts/fetch.agc model [REPO FILE SHA256]") if args.size != 0 and args.size != 3

  words = args
  if args.empty?
    words = (try File.read_text(MODEL_FILE)).strip().split(" ")
    return error("#{MODEL_FILE} is `REPO FILE SHA256`") if words.size != 3
  end

  repo = words[0]
  file = words[1]
  sha256 = words[2].downcase()
  return error("SHA256 must be 64 hex characters") if !Regex.match?(sha256, /^[0-9a-f]{64}$/)

  out = "#{DOWNLOADS}/#{file.split("/").last}"
  return already("already fetched: #{out}") if has_sha256?(out, sha256)

  try Dir.mkdir(DOWNLOADS)
  endpoint = Regex.replace(System.env("HF_ENDPOINT").unwrap_or("https://huggingface.co"), /\/+$/, "").unwrap!
  url = "#{endpoint}/#{repo}/resolve/main/#{file}"
  puts("fetching #{url}")
  partial = "#{out}.part"
  try download_checked(url, partial, sha256)
  Path.rename(partial, out)
end

def already(text: String) -> Result[Void]
  puts(text)
  ok()
end

# --- shared

## Whether the folder was filled for the tag.
def current?(dir: String, tag: String) -> Bool
  case File.read_text("#{dir}/TAG")
    ok(text) -> text.strip() == tag
    error(_) -> false
  end
end

def has_sha256?(path: String, sha256: String) -> Bool
  case File.sha256(path)
    ok(digest) -> OpenSSL.Digest.hexencode(digest) == sha256
    error(_) -> false
  end
end

## `result`, and the path removed when it is an error.
def cleaning[T](result: Result[T], path: String) -> Result[T]
  if !result.ok?
    _ = Path.remove(path)
  end

  result
end

def verify(path: String, sha256: String) -> Result[Void]
  digest = try File.sha256(path)
  actual = OpenSSL.Digest.hexencode(digest)
  return error("#{path}: sha256 is #{actual}, expected #{sha256}") if actual != sha256

  puts("#{path}: sha256 ok")
  ok()
end

## A new file with the body of `url`, once its sha256 is right; a failure leaves no file.
def download_checked(url: String, path: String, sha256: String) -> Result[Void]
  try cleaning(attempt(url, path, ATTEMPTS), path)
  cleaning(verify(path, sha256), path)
end

def attempt(url: String, path: String, left: Int) -> Result[Void]
  _ = Path.remove(path)
  done = get(url, path)
  return done if done.ok? or left <= 1

  IO.warn("fetch: #{done.message}, trying again")
  attempt(url, path, left - 1)
end

def get(url: String, path: String) -> Result[Void]
  client = try HTTP.client(
    HTTP.ClientOptions(timeout_ms: PIECE_TIMEOUT_MS, read_timeout_ms: READ_TIMEOUT_MS, max_body_bytes: CHUNK_BYTES),
  )

  done = copy(client, url, path)
  HTTP.close_client(client)
  done
end

def copy(client: HTTP.Client, url: String, path: String) -> Result[Void]
  final = try resolve(client, url, MAX_REDIRECTS)
  try File.write_text(path, "")
  file = try File.open(path, "append")
  done = copy_from(client, final, file, 0)
  _ = File.close(file)
  done
end

## The URL after the redirects: a request for one byte follows them without downloading the file.
def resolve(client: HTTP.Client, url: String, hops: Int) -> Result[String]
  return error("#{url}: too many redirects") if hops < 0

  response = try ranged(client, url, 0, 0)
  return ok(url) if response.status == 200 or response.status == 206
  return error("#{url}: HTTP #{response.status}") if ![301, 302, 303, 307, 308].include?(response.status)

  places = HTTP.header_values(response.headers, "location")
  return error("#{url}: a redirect with no Location") if places.empty?

  target = absolute(url, places[0])
  if url.downcase().start_with?("https:") and !target.downcase().start_with?("https:")
    return error("#{url}: a redirect to #{target}, not https")
  end

  resolve(client, target, hops - 1)
end

## A file in pieces of CHUNK_BYTES, because the client keeps a body in memory (64 MiB at most) and `HTTP.download`
## writes 256 MiB at most, less than a model.
def copy_from(client: HTTP.Client, url: String, file: File.Handle, offset: Int) -> Result[Void]
  response = try ranged(client, url, offset, offset + CHUNK_BYTES - 1)
  if response.status == 200 and offset != 0
    return error("#{url}: the server ignores Range (the whole file came at offset #{offset})")
  end

  try write_all(file, response.body)
  return ok() if response.status == 200

  return error("#{url}: HTTP #{response.status}") if response.status != 206

  ends = try Regex.match(try content_range(response), /\/(\d+)$/)
  total = try ends.groups[1].text.to_i
  next_offset = offset + response.body.size
  return ok() if next_offset >= total
  return error("#{url}: an empty piece at #{offset}") if response.body.empty?

  copy_from(client, url, file, next_offset)
end

def content_range(response: HTTP.Response) -> Result[String]
  values = HTTP.header_values(response.headers, "content-range")
  return error("a partial response with no Content-Range") if values.empty?

  ok(values[0])
end

## A server that ignores Range answers 200 with the whole file, which the client refuses over CHUNK_BYTES.
def ranged(client: HTTP.Client, url: String, first: Int, last: Int) -> Result[HTTP.Response]
  headers = [HTTP.Header(name: "range", value: "bytes=#{first}-#{last}")]
  response = HTTP.request(client, "GET", url, "".bytes, headers)
  if !response.ok? and response.message.include?("max_body_bytes")
    return error("#{url}: #{response.message} (the server ignores Range)")
  end

  response
end

## File.write_bytes takes 1 MiB at most.
def write_all(file: File.Handle, body: Bytes) -> Result[Void]
  start = 0
  while start < body.size
    try File.write_bytes(file, body.slice(start, [WRITE_BYTES, body.size - start].min.unwrap!()))
    start = start + WRITE_BYTES
  end

  ok()
end

## The URL that a Location means from `url`: absolute, protocol-relative (`//host/p`), a path (`/p`) or relative to the
## folder of the URL's path. Dot segments are not resolved.
def absolute(url: String, location: String) -> String
  return location if Regex.match?(location, /^https?:\/\//i)

  scheme = url.split(":")[0]
  return "#{scheme}:#{location}" if location.start_with?("//")

  origin = Regex.match(url, /^https?:\/\/[^\/?#]+/).unwrap!.text
  return "#{origin}#{location}" if location.start_with?("/")

  path = Regex.replace(url.slice(origin.length, url.length - origin.length), /[?#].*$/, "").unwrap!
  folder = Regex.replace(path, /[^\/]*$/, "").unwrap!
  return "#{origin}/#{location}" if folder.empty?

  "#{origin}#{folder}#{location}"
end
