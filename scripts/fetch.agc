## Fetches what the project does not commit, from the repo root:
##
##   agentica scripts/fetch.agc llama [--variant vulkan]   the prebuilt llama.cpp release (CPU, or with the Vulkan
##                                        backend for a GPU) into native/linux
##   agentica scripts/fetch.agc headers   llama.h and the headers it includes into deps/headers
##   agentica scripts/fetch.agc model [REPO FILE SHA256]   a GGUF model from Hugging Face into deps/
##   agentica scripts/fetch.agc all       the three, with the CPU release and the default model
##
## The release is the one of scripts/llama-release: the build tag and the sha256 of its Linux x86_64 archive, the
## sha256 of the archive of each other variant, then the sha256 of each header. The default model is the one of
## scripts/model. A download follows redirects (never from https to http), and nothing takes its final name before
## its sha256 is checked: the body goes to a hidden `.agc-part` file (`HTTP.download`), then to a scratch name beside
## the target, and replaces the target only when its status and its sha256 are right. A fetch that was killed can leave
## one of those files; the next one removes them. Each step skips what it already has. HF_ENDPOINT (as for the Hugging
## Face tools) replaces https://huggingface.co, and LLAMA_RELEASES the folder of the release downloads on GitHub (both
## are for tests). It does not import the bindings, so it runs before the libraries that the manifest names exist.

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

## Whether a redirect from `from` to `to` leaves https for another scheme.
def downgrade?(from: String, to: String) -> Bool
  from.downcase().start_with?("https:") and !to.downcase().start_with?("https:")
end

## Whether a failure may pass: a network or protocol failure, or a 5xx. A refusal (a 404, a bad redirect, a
## proxy that refuses) will not. A TLS failure is retried even when it is a permanent one (a bad certificate); the
## attempts bound it.
def transient?(message: String) -> Bool
  message.include?(": HTTP 5") or TRANSIENT.any? do |m| message.start_with?(m) end
end

private

RELEASE_FILE = "scripts/llama-release"
RELEASES = "https://github.com/ggml-org/llama.cpp/releases/download"
MODEL_FILE = "scripts/model"
LIBRARIES = "native/linux"
HEADERS = "deps/headers"
DOWNLOADS = "deps"

TOOL_TIMEOUT_MS = 30_000
ATTEMPTS = 3
MAX_REDIRECTS = 5
READ_TIMEOUT_MS = 60_000
DOWNLOAD_TIMEOUT_MS = 7_200_000
MAX_DOWNLOAD_BYTES = 2_147_483_648
# `HTTP.download` keeps at most this many characters of the name of the file in the name of its hidden file.
PART_NAME_CHARS = 32

# The messages of a failure that is retried. The TLS ones may be permanent (a certificate), which costs the attempts.
TRANSIENT = [
  "network: connection failed",
  "network: operation timed out",
  "network: host not found",
  "network: TLS connect failed",
  "network: TLS handshake failed",
  "network: end of input",
  "http: connection failed",
  "http: connection closed before the response was complete",
  "http: truncated HTTP body",
  "http: the connection is closed",
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

# What the Vulkan build adds. The GPU backend is a library that ggml loads from the same folder.
VULKAN_MEMBERS = ["libggml-vulkan.so"]

## A file and the sha256 it must have.
struct Pin
  name: String
  sha256: String
end

## The archives by variant (`cpu`, `vulkan`) and the headers of a release.
struct Release
  tag: String
  archives: Map[String, String]
  headers: List[Pin]
end

def run(args: List[String]) -> Result[Void]
  if args.empty?
    return error(
      "usage: agentica scripts/fetch.agc llama [--variant vulkan] | headers | model [REPO FILE SHA256] | all",
    )
  end

  case args[0]
    "llama" -> fetch_llama(args.drop(1))
    "headers" -> fetch_headers()
    "model" -> fetch_model(args.drop(1))
    "all" -> fetch_all(args.drop(1))
    _ -> error("unknown step #{args[0]}: llama, headers, model or all")
  end
end

def fetch_all(args: List[String]) -> Result[Void]
  try fetch_llama(args)
  try fetch_headers()
  fetch_model([])
end

## `scripts/llama-release`: `TAG ARCHIVE_SHA256`, a `VARIANT ARCHIVE_SHA256` line for each other variant, then a
## `PATH SHA256` line for each header.
def read_release() -> Result[Release]
  lines = (try File.read_text(RELEASE_FILE)).split("\n").select do |l| l.strip() != "" end
  return error("#{RELEASE_FILE} is empty") if lines.empty?

  first = lines.first.split(" ")
  return error("#{RELEASE_FILE}: the first line is `TAG SHA256`") if first.size != 2

  pins: List[Pin] = []
  archives = {"cpu": first[1]}
  for line in lines.drop(1)
    words = line.split(" ")
    return error("#{RELEASE_FILE}: `#{line}` is not `PATH SHA256`") if words.size != 2

    if words[0].include?("/")
      pins = pins.push(Pin(name: words[0], sha256: words[1]))
    else
      return error("#{RELEASE_FILE}: `#{line}`: cpu is the first line") if words[0] == "cpu"
      return error("#{RELEASE_FILE}: `#{line}`: variant #{words[0]} twice") if archives.key?(words[0])

      archives = archives.put(words[0], words[1])
    end
  end

  ok(Release(tag: first[0], archives: archives, headers: pins))
end

# --- the release

def fetch_llama(args: List[String]) -> Result[Void]
  release = try read_release()
  variant = try variant_of(args, release)
  stamp = release.tag
  if variant != "cpu"
    stamp = "#{release.tag} #{variant}"
  end

  return already("already fetched: #{LIBRARIES}") if current?(LIBRARIES, stamp)

  platform = "ubuntu-x64"
  members = RELEASE_MEMBERS
  if variant == "vulkan"
    platform = "ubuntu-vulkan-x64"
    members = RELEASE_MEMBERS + VULKAN_MEMBERS
  end

  name = "llama-#{release.tag}-bin-#{platform}.tar.gz"
  try Dir.mkdir(DOWNLOADS)
  archive = "#{DOWNLOADS}/#{name}"
  releases = Regex.replace(System.env("LLAMA_RELEASES").unwrap_or(RELEASES), /\/+$/, "").unwrap!
  url = "#{releases}/#{release.tag}/#{name}"
  installed = case download_checked(url, archive, release.archives[variant])
    ok(_) -> install_release(archive, release.tag, members, stamp)
    error(e) -> error(e.message)
  end

  _ = Path.remove(archive)
  installed
end

## `--variant NAME` (or `--variant=NAME`) of the words after `llama`: `cpu` when there is none.
def variant_of(args: List[String], release: Release) -> Result[String]
  variant = "cpu"
  if args.size == 2 and args[0] == "--variant"
    variant = args[1]
  elsif args.size == 1 and args[0].start_with?("--variant=")
    variant = args[0].slice(10, args[0].length - 10)
  elsif !args.empty?
    return error("usage: agentica scripts/fetch.agc llama [--variant NAME]")
  end

  return error("unknown variant #{variant}: #{release.archives.keys.join(", ")}") if !release.archives.key?(variant)

  ok(variant)
end

## The archive is extracted into a scratch folder and the libraries are put together in a new one, which takes the
## place of the old libraries last, so a failure leaves the libraries that are there.
def install_release(archive: String, tag: String, members: List[String], stamp: String) -> Result[Void]
  scratch = "#{DOWNLOADS}/llama-#{tag}"
  fresh = "#{LIBRARIES}.new"
  _ = Path.remove(scratch)
  _ = Path.remove(fresh)
  built = build_libraries(archive, tag, members, scratch, fresh)
  _ = Path.remove(scratch)
  try cleaning(built, fresh)
  try File.write_text("#{fresh}/TAG", stamp)
  _ = Path.remove(LIBRARIES)
  Path.rename(fresh, LIBRARIES)
end

def build_libraries(
  archive: String,
  tag: String,
  members: List[String],
  scratch: String,
  fresh: String,
) -> Result[Void]
  paths = members.map do |m| "llama-#{tag}/#{m}" end
  try Archive.extract_tar(archive, paths, scratch)
  try Dir.mkdir(fresh)
  for name in members
    try Path.rename("#{scratch}/llama-#{tag}/#{name}", "#{fresh}/#{soname(name)}")
  end

  executable("#{fresh}/llama-server")
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
  download_checked(url, out, sha256)
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

## A new file with the body of `url`, once its status and sha256 are right; a failure leaves the file that was there.
def download_checked(url: String, path: String, sha256: String) -> Result[Void]
  scratch = "#{path}.download"
  remove_leftovers(scratch)
  done = attempt(url, scratch, sha256, ATTEMPTS)
  if done.ok?
    done = Path.replace(scratch, path)
  end

  _ = Path.remove(scratch)
  try done
  puts("#{path}: sha256 ok")
  ok()
end

## The scratch file and the hidden files of a download of it that was killed (`.NAME.HEX.agc-part`).
def remove_leftovers(scratch: String) -> Void
  _ = Path.remove(scratch)
  parts = scratch.split("/")
  name = parts.last
  folder = parts.take(parts.size - 1).join("/")
  prefix = ".#{name.slice(0, [name.length, PART_NAME_CHARS].min.unwrap!())}."
  entries: List[String] = Dir.list(folder).unwrap_or([])
  for entry in entries
    if entry.start_with?(prefix) and entry.end_with?(".agc-part")
      _ = Path.remove("#{folder}/#{entry}")
    end
  end
end

def attempt(url: String, scratch: String, sha256: String, left: Int) -> Result[Void]
  done = get(url, scratch, sha256)
  return done if done.ok? or left <= 1 or !transient?(done.message)

  IO.warn("fetch: #{done.message}, trying again")
  attempt(url, scratch, sha256, left - 1)
end

def get(url: String, scratch: String, sha256: String) -> Result[Void]
  client = try HTTP.client(HTTP.ClientOptions(read_timeout_ms: READ_TIMEOUT_MS))
  done = copy(client, url, scratch, sha256)
  HTTP.close_client(client)
  done
end

## `HTTP.download` writes the body of a 404 or a 503 as it does any other, so the status is checked before the digest:
## the digest of an error page would hide the failure and a 5xx would not be retried.
def copy(client: HTTP.Client, url: String, scratch: String, sha256: String) -> Result[Void]
  final = try resolve(client, url, MAX_REDIRECTS)
  options = HTTP.DownloadOptions(timeout_ms: some(DOWNLOAD_TIMEOUT_MS), max_total_bytes: some(MAX_DOWNLOAD_BYTES))
  saved = try HTTP.download(client, final, scratch, options)
  return error("#{final}: HTTP #{saved.status}") if saved.status >= 300
  return error("#{final}: the body does not match the sha256 digest") if !has_sha256?(scratch, sha256)

  ok()
end

## The URL after the redirects, which `HTTP.download` does not follow: a HEAD request follows them without a body. Any
## other answer, a 405 or a 403 as well, ends it: the download then says what the GET gets.
def resolve(client: HTTP.Client, url: String, hops: Int) -> Result[String]
  return error("#{url}: too many redirects") if hops < 0

  response = try HTTP.request(client, "HEAD", url, "".bytes)
  return ok(url) if ![301, 302, 303, 307, 308].include?(response.status)

  places = HTTP.header_values(response.headers, "location")
  return error("#{url}: a redirect with no Location") if places.empty?

  target = absolute(url, places[0])
  return error("#{url}: a redirect to #{target}, not https") if downgrade?(url, target)

  resolve(client, target, hops - 1)
end
