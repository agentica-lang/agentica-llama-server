## bench/run_all.agc without a model: `--help` runs from any folder, and the repo root is the parent of the folder of
## the program. `agentica test` runs it from the repo root; it needs no network and no libraries.

import RunAll from "../bench/run_all"

PROGRAM = "bench/run_all.agc"
TIMEOUT_MS = 120_000

def test_the_help_runs_from_another_folder_and_lists_root() -> Result[Void]
  program = try Path.real(PROGRAM)
  base = System.env("TMPDIR").unwrap_or("/tmp")
  agentica = System.env("AGENTICA").unwrap_or("agentica")
  process = try Process.spawn_captured(
    agentica,
    [program, "--help"],
    Process.Options(timeout_ms: TIMEOUT_MS, chdir: base),
  )

  code = try Process.wait(process, TIMEOUT_MS)
  out = try Process.output(process, TIMEOUT_MS)
  Process.close(process)
  try Test.eq(code, 0)
  Test.assert((out.stdout + out.stderr).include?("--root"), out.stdout)
end

def test_the_root_is_the_parent_of_the_folder_of_the_program() -> Result[Void]
  try Test.eq(RunAll.root_of("/home/a/llama-server/bench/run_all.agc"), ok("/home/a/llama-server"))
  try Test.eq(RunAll.root_of("/repo/bench/run_all.agc"), ok("/repo"))
  try Test.eq(RunAll.root_of("/bench/run_all.agc"), ok("/"))
  Test.eq(RunAll.root_of("bench/run_all.agc"), ok("."))
end

def test_a_program_outside_a_bench_folder_has_no_root() -> Result[Void]
  for program in ["/tmp/x.agcb", "/run_all.agcb", "run_all.agcb", "/repo/scripts/run_all.agc"]
    try Test.assert(!RunAll.root_of(program).ok?, program)
  end

  Test.assert(RunAll.root_of("/tmp/x.agcb").message.include?("--root"), "the error says to pass --root")
end
