## Runs the Agentica server and llama-server one after the other on the same model and settings, and prints the medians
## as a Markdown table.
##
## Each server starts under a systemd scope with a memory cap, is warmed up, then each concurrency runs `--reps`
## times. The processes are the ones that this program started, and it stops exactly those. Run it from the repo root:
##
## agentica bench/run_all.agc [--quick] [--only NAME] [--threads N] [--concurrency 1,4,16] [--stream] [--out FILE] ...
##
## It writes the JSON of every run to `--out` (bench/results/latest.json); `agentica bench/run_all.agc --help` lists the
## options.

import Client from "client"
import OP from "std/option_parser"
import Regex from "std/regex"
import {Kind, Opt} from "std/option_parser"

def main() -> Void
  parsed = OP.run!(parse(System.args()))
  options = options_of(parsed)
  started = Time.monotonic_ms()
  done = run(options)
  if !done.ok?
    IO.warn("run_all: #{done.message}")
    System.exit(1)
  end

  puts("took #{(Time.monotonic_ms() - started) / 1000} s")
end

private

MODEL = "deps/qwen2.5-0.5b-instruct-q4_k_m.gguf"
LLAMA_SERVER = "native/linux/llama-server"
SCOPE = ["--user", "--scope", "-q", "-p", "MemoryMax=6G", "-p", "MemorySwapMax=0", "--"]
CLOCK_TICKS = 100

struct Options
  quick: Bool
  agentica: String
  only: Optional[String]
  order: List[String]
  threads: Int
  ctx: Int
  slots: Int
  concurrencies: List[Int]
  reps: Int
  max_tokens: Int
  max_load: Float
  patience: Int
  max_load_during: Float
  attempts: Int
  stream: Bool
  port: Int
  out: String
end

struct Server
  name: String
  port: Int
  url: String
  extra: Map[String, JSON.Value]
  process: Process
  pid: Int
end

## What the report holds of one server.
struct ServerResult
  runs: Map[String, List[Client.RunResult]]
  rss_idle_mb: Float
  texts: Map[String, String]
  batched_same: Optional[Int]
  rss_peak_mb: Float
  rss_end_mb: Float
end

struct Report
  threads: Int
  ctx: Int
  slots: Int
  max_tokens: Int
  reps: Int
  stream: Bool
  quick: Bool
  max_load: Float
  max_load_during: Float
  results: Map[String, ServerResult]
end

struct Jiffies
  busy: Int
  total: Int
end

def parse(args: List[String]) -> Result[OP.Parsed]
  parser = OP.new(
    "agentica bench/run_all.agc",
    "The Agentica server and llama-server on the same model and settings, medians as a Markdown table",
    [],
    [
      Opt(
        name: "quick",
        kind: Kind.Flag,
        help: "a whole run in under 3 minutes: 4 threads, streaming, 32 tokens, 2 reps, fewer requests",
      ),
      Opt(name: "agentica", default: "agentica"),
      Opt(name: "only", choices: ["agentica", "llama-server"]),
      Opt(name: "order", default: "agentica,llama-server"),
      Opt(name: "threads", kind: Kind.Int, help: "default: nproc (4 with --quick)"),
      Opt(name: "ctx", kind: Kind.Int, default: "8192"),
      Opt(name: "slots", kind: Kind.Int, default: "8"),
      Opt(name: "concurrency", default: "1,4,16"),
      Opt(name: "reps", kind: Kind.Int, help: "default: 3 (2 with --quick)"),
      Opt(name: "max-tokens", kind: Kind.Int, help: "default: 64 (32 with --quick)"),
      Opt(
        name: "max-load",
        kind: Kind.Float,
        default: "1000000000.0",
        help: "wait until the neighbours use fewer cores than this",
      ),
      Opt(name: "patience", kind: Kind.Int, default: "600", help: "seconds to wait for a quiet machine per run"),
      Opt(
        name: "max-load-during",
        kind: Kind.Float,
        default: "1000000000.0",
        help: "redo a run when the neighbours used more cores than this while it ran",
      ),
      Opt(name: "attempts", kind: Kind.Int, default: "1", help: "tries per run for --max-load-during"),
      Opt(
        name: "stream",
        kind: Kind.Flag,
        help: "every request says \"stream\": true; adds time to first token",
      ),
      Opt(name: "port", kind: Kind.Int, default: "8123"),
      Opt(name: "out", default: "bench/results/latest.json"),
    ],
  )
  OP.parse(parser, args)
end

## An explicit value always wins; only an omitted one takes the default of its mode.
def options_of(p: OP.Parsed) -> Options
  quick = OP.flag(p, "quick")
  concurrencies = (OP.string(p, "concurrency").split(",")).map do |c| c.strip().to_i!() end
  Options(
    quick: quick,
    agentica: OP.string(p, "agentica"),
    only: OP.optional_string(p, "only"),
    order: OP.string(p, "order").split(","),
    threads: OP.optional_int(p, "threads").unwrap_or(quick_or(quick, 4, cpu_count())),
    ctx: OP.int(p, "ctx"),
    slots: OP.int(p, "slots"),
    concurrencies: concurrencies,
    reps: OP.optional_int(p, "reps").unwrap_or(quick_or(quick, 2, 3)),
    max_tokens: OP.optional_int(p, "max-tokens").unwrap_or(quick_or(quick, 32, 64)),
    max_load: OP.float(p, "max-load"),
    patience: quick_or(quick, [OP.int(p, "patience"), 10].min.unwrap!(), OP.int(p, "patience")),
    max_load_during: OP.float(p, "max-load-during"),
    attempts: quick_or(quick, 1, OP.int(p, "attempts")),
    stream: quick or OP.flag(p, "stream"),
    port: OP.int(p, "port"),
    out: OP.string(p, "out"),
  )
end

def quick_or(quick: Bool, when_quick: Int, otherwise: Int) -> Int
  return when_quick if quick

  otherwise
end

def run(options: Options) -> Result[Void]
  folder = Regex.replace(options.out, /\/[^\/]*$/, "").unwrap!
  try Dir.mkdir(folder)
  servers = try start_all(options, folder)
  measured = bench(options, servers)
  for s in servers
    Process.close(s.process)
  end

  results = try measured
  report = Report(
    threads: options.threads,
    ctx: options.ctx,
    slots: options.slots,
    max_tokens: options.max_tokens,
    reps: options.reps,
    stream: options.stream,
    quick: options.quick,
    max_load: options.max_load,
    max_load_during: options.max_load_during,
    results: results,
  )
  try File.write_text(options.out, JSON.encode(report))
  puts(table(results))
  ok()
end

# --- the servers

def start_all(options: Options, folder: String) -> Result[List[Server]]
  servers: List[Server] = []
  for i in 0...options.order.size
    name = options.order[i]
    next if options.only.some? and options.only.unwrap!() != name

    started = start(options, name, options.port + i, folder)
    if !started.ok?
      for s in servers
        Process.close(s.process)
      end

      return error(started.message)
    end

    servers = servers.push(started.unwrap!)
  end

  ok(servers)
end

## The command of each server, on the same settings.
def command(options: Options, name: String, port: Int) -> Result[List[String]]
  threads = options.threads.to_s
  slots = options.slots.to_s
  ctx = options.ctx.to_s
  case name
    "agentica" ->
      ok(
        [
          options.agentica, "server.agc", "--port", port.to_s, "--threads", threads, "--ctx", ctx, "--parallel", slots,
          "--batch", "2048",
        ],
      )
    "llama-server" ->
      ok(
        [
          LLAMA_SERVER, "-m", MODEL, "--host", "127.0.0.1", "--port", port.to_s, "-t", threads, "-tb", threads, "-c", ctx,
          "-np", slots, "-b", "2048", "-ub", "512", "--no-webui", "--no-cache-prompt", "-cram", "0", "--no-warmup",
        ],
      )
    _ -> error("unknown server #{name}: agentica or llama-server")
  end
end

def start(options: Options, name: String, port: Int, folder: String) -> Result[Server]
  words = try command(options, name, port)
  log = try Path.join([folder, "#{name}.log"])
  process = try Process.spawn("systemd-run", SCOPE + words, Process.Options(timeout_ms: 3_600_000, out: log, err: log))
  # `systemd-run --scope` execs the command: the child of this program is the server itself.
  pid = try find_pid(port)
  extra = {}
  if name == "llama-server"
    extra = {"cache_prompt": JSON.from(false)}
  end

  ok(Server(name: name, port: port, url: "http://127.0.0.1:#{port}", extra: extra, process: process, pid: pid))
end

## The child of this program that was started with `--port PORT` (Agentica has no `Process.pid`).
def find_pid(port: Int) -> Result[Int]
  needle = String.from_code(0) + port.to_s + String.from_code(0)
  for _ in 0...100
    for name in try Dir.list("/proc")
      continue if !Regex.match?(name, /^\d+$/)

      stat = File.read_text("/proc/#{name}/stat")
      cmdline = File.read_text("/proc/#{name}/cmdline")
      if stat.ok? and cmdline.ok? and parent_of(stat.unwrap!) == System.pid() and cmdline.unwrap!.include?(needle)
        return ok(name.to_i!())
      end
    end

    Task.sleep(50)
  end

  error("the process of the server on port #{port} was not found")
end

def parent_of(stat: String) -> Int
  fields = after_name(stat)
  fields[1].to_i!()
end

## The fields of a /proc/PID/stat line after the command name: state, ppid, ... (utime and stime are 11 and 12).
def after_name(stat: String) -> List[String]
  tail = Regex.replace(stat, /^.*\)\s*/, "").unwrap!
  tail.split(" ")
end

def wait_ready(server: Server, timeout_s: Int) -> Result[Void]
  for _ in 0...(timeout_s * 1000 / 300)
    exited = Process.wait(server.process, 1)
    return error("#{server.name} exited early with #{exited.unwrap!}") if exited.ok?

    health = HTTP.get_response("#{server.url}/health", HTTP.ClientOptions(timeout_ms: 2000))
    return ok() if health.ok? and health.unwrap!.status == 200

    Task.sleep(300)
  end

  error("#{server.name} not ready")
end

# --- /proc

def status_kb(pid: Int, field: String) -> Int
  text = File.read_text("/proc/#{pid}/status").unwrap_or("")
  for line in text.split("\n")
    if line.start_with?("#{field}:")
      return line.slice(field.length + 1, line.length - field.length - 1).strip().split(" ")[0].to_i!()
    end
  end

  0
end

def system_jiffies() -> Jiffies
  line = File.read_text("/proc/stat").unwrap_or("cpu").split("\n")[0]
  fields = line.split(" ").drop(1).select do |f| f != "" end
  numbers = fields.map do |f| f.to_i!() end
  total = numbers.reduce(0) do |a, n| a + n end
  Jiffies(busy: total - numbers[3] - numbers[4], total: total)
end

## User plus system jiffies of one process, with its threads (`self` for this program).
def process_jiffies(pid: String) -> Int
  fields = after_name(File.read_text("/proc/#{pid}/stat").unwrap_or(") S"))
  return 0 if fields.size < 13

  fields[11].to_i!() + fields[12].to_i!()
end

def cpu_count() -> Int
  lines = File.read_text("/proc/stat").unwrap_or("").split("\n")
  count = lines.count do |l| Regex.match?(l, /^cpu\d+ /) end
  [count, 1].max.unwrap!()
end

# --- the machine is shared

## Cores the machine uses over a short window. Called while both servers are idle, so it is the neighbours.
def busy_cores(window_ms: Int) -> Float
  before = system_jiffies()
  Task.sleep(window_ms)
  after = system_jiffies()
  (after.busy - before.busy).to_f() / [1, after.total - before.total].max.unwrap!().to_f() * cpu_count().to_f()
end

## Waits until the neighbours use fewer than `max_busy` cores, at most `patience_s`. The busy cores are recorded with
## every run, quiet or not.
def wait_quiet(max_busy: Float, patience_s: Int, window_ms: Int) -> Float
  deadline = Time.monotonic_ms() + patience_s * 1000
  busy = busy_cores(window_ms)
  while busy > max_busy and Time.monotonic_ms() < deadline
    busy = busy_cores(window_ms)
  end

  busy
end

## One client run, plus the cores the *neighbours* used during it: the machine's busy cores over the run, minus what the
## server and this client process used. A check before the run does not see a neighbour that starts during it.
def run_measured(server: Server, options: Options, concurrency: Int, total: Int) -> Result[Client.RunResult]
  before = system_jiffies()
  server_before = process_jiffies(server.pid.to_s)
  client_before = process_jiffies("self")
  settings = Client.Settings(
    url: server.url,
    concurrency: concurrency,
    total: total,
    max_tokens: options.max_tokens,
    extra: server.extra,
    stream: options.stream,
  )
  result = try Client.run(settings)
  after = system_jiffies()
  own = (process_jiffies(server.pid.to_s) - server_before) + (process_jiffies("self") - client_before)
  window = [1, after.total - before.total].max.unwrap!().to_f()
  neighbours = [0.0, (after.busy - before.busy - own).to_f() / window * cpu_count().to_f()].max.unwrap!()
  ok(result.with(neighbour_cores_during: JSON.Field.Value(neighbours)))
end

# --- the benchmark

## Runs the servers alternately, rep by rep, so a noisy machine hurts both the same. `--quick` keeps the run under 3
## minutes: a short warm-up, 4 prompts for the identity check, no batched check, a 1 s window for the neighbour check
## and fewer requests per run.
def bench(options: Options, servers: List[Server]) -> Result[Map[String, ServerResult]]
  for s in servers
    try wait_ready(s, 120)
  end

  results: Map[String, ServerResult] = {}
  for s in servers
    results = results.put(s.name, try warm_up(options, s))
  end

  for c in options.concurrencies
    total = run_size(options, c)
    for s in servers
      results = results.put(s.name, add_runs(results[s.name], c.to_s, []))
    end

    for rep in 0...options.reps
      order = servers
      if rep % 2 == 1
        order = servers.reverse
      end

      for s in order
        best = try attempts(options, s, c, total, rep)
        results = results.put(s.name, add_runs(results[s.name], c.to_s, [best]))
      end
    end
  end

  ok(
    results.keys.reduce({}) do |acc, name|
      server = servers.find do |s| s.name == name end
      acc.put(name, finish(results[name], server.unwrap!))
    end,
  )
end

def run_size(options: Options, concurrency: Int) -> Int
  return [concurrency, [16, [4, 2 * concurrency].max.unwrap!()].min.unwrap!()].max.unwrap!() if options.quick

  [16, 4 * concurrency].max.unwrap!()
end

def add_runs(result: ServerResult, key: String, runs: List[Client.RunResult]) -> ServerResult
  result.with(runs: result.runs.put(key, result.runs.get(key, []) + runs))
end

def finish(result: ServerResult, server: Server) -> ServerResult
  result.with(
    rss_peak_mb: status_kb(server.pid, "VmHWM").to_f() / 1024.0,
    rss_end_mb: status_kb(server.pid, "VmRSS").to_f() / 1024.0,
  )
end

def client_run(options: Options, s: Server, concurrency: Int, total: Int, texts: Bool) -> Result[Client.RunResult]
  Client.run(
    Client.Settings(
      url: s.url,
      concurrency: concurrency,
      total: total,
      max_tokens: options.max_tokens,
      extra: s.extra,
      keep_texts: texts,
      stream: options.stream,
    ),
  )
end

def texts_of(run: Client.RunResult) -> Map[String, String]
  case run.texts
    JSON.Field.Value(t) -> t
    _ -> {}
  end
end

## Weights paged in, buffers sized; then the answers of one prompt at a time and, side by side, of 8 at once.
def warm_up(options: Options, s: Server) -> Result[ServerResult]
  empty = ServerResult(
    runs: {},
    rss_idle_mb: status_kb(s.pid, "VmRSS").to_f() / 1024.0,
    texts: {},
    batched_same: none,
    rss_peak_mb: 0.0,
    rss_end_mb: 0.0,
  )
  if options.quick
    first = try client_run(options, s, 1, 4, true)
    second = try client_run(options, s, 4, 4, false)
    if first.failures > 0 or second.failures > 0
      return error("#{s.name}: a warm-up request failed: #{failure_of(first, second)}")
    end

    return ok(empty.with(texts: texts_of(first)))
  end

  _ = try client_run(options, s, 4, 16, false)
  _ = try client_run(options, s, 1, 2, false)
  texts = texts_of(try client_run(options, s, 1, 8, true))
  batched = texts_of(try client_run(options, s, 8, 8, true))
  # The same prompts decoded side by side must give the same greedy answers as one at a time.
  same = (texts.keys.select do |k| batched.get(k, "") == texts[k] end).size
  ok(empty.with(texts: texts, batched_same: some(same)))
end

def failure_of(first: Client.RunResult, second: Client.RunResult) -> String
  case first.first_failure
    JSON.Field.Value(m) -> m
    _ ->
      case second.first_failure
        JSON.Field.Value(m) -> m
        _ -> ""
      end
  end
end

def neighbours_of(run: Client.RunResult) -> Float
  case run.neighbour_cores_during
    JSON.Field.Value(n) -> n
    _ -> 0.0
  end
end

def ttft_of(run: Client.RunResult) -> Float
  case run.ttft_p50_s
    JSON.Field.Value(t) -> t
    _ -> 0.0
  end
end

## A run during which the neighbours used more than `max_load_during` cores is thrown away and redone, up to `attempts`
## times; then the quietest attempt stays. The thrown-away ones are kept in the JSON.
def attempts(options: Options, s: Server, concurrency: Int, total: Int, rep: Int) -> Result[Client.RunResult]
  window = 4000
  if options.quick
    window = 1000
  end

  tried: List[Client.RunResult] = []
  for attempt in 0...options.attempts
    before = wait_quiet(options.max_load, options.patience, window)
    run = (try run_measured(s, options, concurrency, total)).with(busy_cores_before: JSON.Field.Value(before))
    tried = tried.push(run)
    puts(
      format(
        "%s c=%d rep=%d try=%d: %.1f tok/s, ttft p50 %.2f s, neighbours %.1f cores before, %.1f during",
        s.name, concurrency, rep, attempt, run.gen_tok_per_s, ttft_of(run), before, neighbours_of(run),
      ),
    )
    IO.flush()
    break if neighbours_of(run) <= options.max_load_during
  end

  chosen = tried.size - 1
  if neighbours_of(tried[chosen]) > options.max_load_during
    for i in 0...tried.size
      if neighbours_of(tried[i]) < neighbours_of(tried[chosen])
        chosen = i
      end
    end
  end

  dropped: List[Client.Discarded] = []
  for i in 0...tried.size
    if i != chosen
      dropped = dropped.push(
        Client.Discarded(gen_tok_per_s: tried[i].gen_tok_per_s, neighbour_cores_during: neighbours_of(tried[i])),
      )
    end
  end

  ok(tried[chosen].with(attempts: JSON.Field.Value(tried.size), discarded: JSON.Field.Value(dropped)))
end

# --- the table

def median(values: List[Float]) -> Float
  sorted = values.sort
  middle = sorted.size / 2
  return sorted[middle] if sorted.size % 2 == 1

  (sorted[middle - 1] + sorted[middle]) / 2.0
end

def column(runs: List[Client.RunResult], pick: Fn[Client.RunResult, Float]) -> Float = median(runs.map(pick))

def table(results: Map[String, ServerResult]) -> String
  streaming = results.keys.any? do |n|
    results[n].runs.keys.any? do |c|
      results[n].runs[c].any? do |r| r.ttft_p50_s != JSON.Field.Absent end
    end
  end

  ttft_head = ""
  ttft_rule = ""
  if streaming
    ttft_head = " ttft p50 s | ttft p95 s |"
    ttft_rule = "---|---|"
  end

  lines = [
    "| server | conc | req/s | gen tok/s | p50 s | p95 s |#{ttft_head} failed |",
    "|---|---|---|---|---|---|---|#{ttft_rule}",
  ]
  for name in results.keys
    for c in results[name].runs.keys
      lines = lines.push(row(name, c, results[name].runs[c], streaming))
    end
  end

  lines = lines + ["", "| server | RSS idle MB | RSS peak MB | RSS end MB |", "|---|---|---|---|"]
  for name in results.keys
    data = results[name]
    lines = lines.push(format("| %s | %.0f | %.0f | %.0f |", name, data.rss_idle_mb, data.rss_peak_mb, data.rss_end_mb))
  end

  lines = lines + [""] + identity_lines(results)
  lines.join("\n")
end

def row(name: String, c: String, runs: List[Client.RunResult], streaming: Bool) -> String
  cells = [
    name,
    c,
    format("%.2f", column(runs) do |r| r.req_per_s end),
    format("%.1f", column(runs) do |r| r.gen_tok_per_s end),
    format("%.2f", column(runs) do |r| r.p50_s end),
    format("%.2f", column(runs) do |r| r.p95_s end),
  ]
  if streaming
    cells = cells + [
      format("%.2f", column(runs) do |r| ttft_of(r) end),
      format("%.2f", column(runs) do |r| ttft_p95_of(r) end),
    ]
  end

  failed = runs.reduce(0) do |acc, r| acc + r.failures end
  cells = cells.push(failed.to_s)
  "| #{cells.join(" | ")} |"
end

def ttft_p95_of(run: Client.RunResult) -> Float
  case run.ttft_p95_s
    JSON.Field.Value(t) -> t
    _ -> 0.0
  end
end

def identity_lines(results: Map[String, ServerResult]) -> List[String]
  lines: List[String] = []
  for name in results.keys
    if results[name].batched_same.some?
      lines = lines.push(
        "#{name}: #{results[name].batched_same.unwrap!()} of 8 answers at concurrency 8 equal the ones at concurrency 1.",
      )
    end
  end

  names = results.keys
  if names.size == 2
    a = results[names[0]].texts
    b = results[names[1]].texts
    same = (a.keys.select do |k| a[k] == b.get(k, "") end).size
    lines = lines + ["", "Greedy answers identical between servers: #{same} of #{a.size} prompts."]
  end

  lines
end
