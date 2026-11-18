## Fetches what the project does not commit, from the repo root:
##
##   agentica scripts/fetch.agc llama     the prebuilt CPU llama.cpp release into native/linux
##   agentica scripts/fetch.agc headers   llama.h and the headers it includes into deps/headers
##   agentica scripts/fetch.agc model [REPO FILE SHA256]   a GGUF model from Hugging Face into deps/
##   agentica scripts/fetch.agc all       the three, with the default model
##
## The release is the one of scripts/llama-release (the build tag and the sha256 of its Linux x86_64 archive). A
## download follows redirects, and nothing takes its final name before its sha256 is checked. Each step skips what it
## already has. HF_ENDPOINT (as for the Hugging Face tools) replaces https://huggingface.co. It does not import the bindings, so it runs before the libraries that the manifest names exist.

import Archive from "std/archive"
import HTTP from "std/http"
import Regex from "std/regex"

DEFAULT_REPO = "Qwen/Qwen2.5-0.5B-Instruct-GGUF"
DEFAULT_MODEL = "qwen2.5-0.5b-instruct-q4_k_m.gguf"
DEFAULT_MODEL_SHA256 = "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"

RELEASE_FILE = "scripts/llama-release"
LIBRARIES = "native/linux"
HEADERS = "deps/headers"
DOWNLOADS = "deps"

TOOL_TIMEOUT_MS = 30_000
ATTEMPTS = 3
MAX_REDIRECTS = 5
DOWNLOAD_TIMEOUT_MS = 1_800_000
CHUNK_BYTES = 33_554_432
WRITE_BYTES = 1_048_576

HEADER_FILES = [
  "include/llama.h",
  "ggml/include/ggml.h",
  "ggml/include/ggml-alloc.h",
  "ggml/include/ggml-backend.h",
  "ggml/include/ggml-cpu.h",
  "ggml/include/ggml-opt.h",
  "ggml/include/gguf.h",
]

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

struct Release
  tag: String
  sha256: String
end

def main() -> Void
  case run(System.args())
    ok(_) -> puts("done")
    error(e) ->
      IO.warn("fetch: #{e.message}")
      System.exit(1)
  end
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

def read_release() -> Result[Release]
  words = (try File.read_text(RELEASE_FILE)).strip().split(" ")
  return error("#{RELEASE_FILE} is `TAG SHA256`") if words.size != 2

  ok(Release(tag: words[0], sha256: words[1]))
end

# --- the release

def fetch_llama() -> Result[Void]
  release = try read_release()
  return already("already fetched: #{LIBRARIES}") if current?(LIBRARIES, release.tag)

  archive = "#{DOWNLOADS}/llama-#{release.tag}-bin-ubuntu-x64.tar.gz"
  url = (
    "https://github.com/ggml-org/llama.cpp/releases/download/#{release.tag}/llama-#{release.tag}-bin-ubuntu-x64.tar.gz"
  )

  try Dir.mkdir(DOWNLOADS)
  try download(url, archive)
  checked = verify(archive, release.sha256)
  installed = case checked
    ok(_) -> install_release(archive, release.tag)
    error(e) -> error(e.message)
  end

  _ = Path.remove(archive)
  installed
end

## The archive is extracted next to the libraries, then each file moves under its soname.
def install_release(archive: String, tag: String) -> Result[Void]
  scratch = "#{DOWNLOADS}/llama-#{tag}"
  _ = Path.remove(scratch)
  _ = Path.remove(LIBRARIES)
  members = RELEASE_MEMBERS.map do |m| "llama-#{tag}/#{m}" end
  try Archive.extract_tar(archive, members, scratch)
  try Dir.mkdir(LIBRARIES)
  for name in RELEASE_MEMBERS
    try Path.rename("#{scratch}/llama-#{tag}/#{name}", "#{LIBRARIES}/#{soname(name)}")
  end

  try File.write_text("#{LIBRARIES}/TAG", tag)
  _ = Path.remove(scratch)
  executable("#{LIBRARIES}/llama-server")
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

def fetch_headers() -> Result[Void]
  release = try read_release()
  return already("already fetched: #{HEADERS}") if current?(HEADERS, release.tag)

  _ = Path.remove(HEADERS)
  try Dir.mkdir(HEADERS)
  for file in HEADER_FILES
    name = file.split("/").last
    try download("https://raw.githubusercontent.com/ggml-org/llama.cpp/#{release.tag}/#{file}", "#{HEADERS}/#{name}")
  end

  File.write_text("#{HEADERS}/TAG", release.tag)
end

# --- the model

def fetch_model(args: List[String]) -> Result[Void]
  return error("usage: agentica scripts/fetch.agc model [REPO FILE SHA256]") if args.size != 0 and args.size != 3

  words = if_empty(args)
  repo = words[0]
  file = words[1]
  sha256 = words[2].downcase()
  return error("SHA256 must be 64 hex characters") if !Regex.match?(sha256, /^[0-9a-f]{64}$/)

  out = "#{DOWNLOADS}/#{file.split("/").last}"
  return already("already fetched: #{out}") if has_sha256?(out, sha256)

  try Dir.mkdir(DOWNLOADS)
  partial = "#{out}.part"
  endpoint = System.env("HF_ENDPOINT").unwrap_or("https://huggingface.co")
  url = "#{endpoint}/#{repo}/resolve/main/#{file}"
  puts("fetching #{url}")
  try download(url, partial)
  checked = verify(partial, sha256)
  if !checked.ok?
    _ = Path.remove(partial)
    return checked
  end

  _ = Path.remove(out)
  Path.rename(partial, out)
end

def already(text: String) -> Result[Void]
  puts(text)
  ok()
end

## The words of `model`, the defaults when there are none.
def if_empty(args: List[String]) -> List[String]
  return [DEFAULT_REPO, DEFAULT_MODEL, DEFAULT_MODEL_SHA256] if args.empty?

  args
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

def verify(path: String, sha256: String) -> Result[Void]
  digest = try File.sha256(path)
  actual = OpenSSL.Digest.hexencode(digest)
  return error("#{path}: sha256 is #{actual}, expected #{sha256}") if actual != sha256

  puts("#{path}: sha256 ok")
  ok()
end

## A GET into a new file, with a few attempts.
def download(url: String, path: String) -> Result[Void] = attempt(url, path, ATTEMPTS)

def attempt(url: String, path: String, left: Int) -> Result[Void]
  _ = Path.remove(path)
  done = get(url, path)
  return done if done.ok? or left <= 1

  IO.warn("fetch: #{done.message}, trying again")
  attempt(url, path, left - 1)
end

def get(url: String, path: String) -> Result[Void]
  client = try HTTP.client(
    HTTP.ClientOptions(
      timeout_ms: DOWNLOAD_TIMEOUT_MS,
      read_timeout_ms: DOWNLOAD_TIMEOUT_MS,
      max_body_bytes: CHUNK_BYTES,
    ),
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

  resolve(client, absolute(url, places[0]), hops - 1)
end

## A file in pieces of CHUNK_BYTES, because the client keeps a body in memory (64 MiB at most) and `HTTP.download`
## writes 256 MiB at most, less than a model.
def copy_from(client: HTTP.Client, url: String, file: File.Handle, offset: Int) -> Result[Void]
  response = try ranged(client, url, offset, offset + CHUNK_BYTES - 1)
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

def ranged(client: HTTP.Client, url: String, first: Int, last: Int) -> Result[HTTP.Response]
  HTTP.request(client, "GET", url, "".bytes, [HTTP.Header(name: "range", value: "bytes=#{first}-#{last}")])
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

## A Location may be a path on the same host.
def absolute(url: String, location: String) -> String
  return location if location.start_with?("http")

  origin = Regex.match(url, /^https?:\/\/[^\/]+/).unwrap!.text
  "#{origin}#{location}"
end
