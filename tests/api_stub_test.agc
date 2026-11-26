## The routes on a stub engine, in this process: an engine's refusal reaches the client with the status of its fault (a
## `Fault.Client` is a 400, a `Fault.Internal` a 500), plain or streamed. No model, no server process.

import Api from "../src/llama_server_web/api"
import Bond from "pkg/bond/bond"
import Cases from "api_cases"
import Contract from "../src/llama_server/contract"
import HTTP from "std/http"

## The stub reads the first token of the prompt: 1 is a request's own fault, anything else the engine's.
CLIENT_PROMPT = 1
INTERNAL_PROMPT = 2

def test_a_refusal_has_the_status_of_its_fault() -> Result[Void]
  requests: Channel[Contract.GenRequest] = Channel.new(16)
  engine = Task.spawn(&refuse_all, requests)
  handle = Contract.Handle(
    model_name: "stub",
    n_ctx: 64,
    requests: requests,
    prompt: ->(messages: List[Contract.Message]) { stub_prompt(messages) },
  )

  server = try Bond.start_with(Api.app(Api.new_api(handle)), "127.0.0.1", 0, HTTP.ServerOptions())
  port = Bond.local_port(server)
  checked = statuses(port)
  Bond.stop(server)
  Task.cancel(engine)
  checked
end

def statuses(port: Int) -> Result[Void]
  client = [Cases.Message(role: "user", content: "client")]
  internal = [Cases.Message(role: "user", content: "internal")]
  try Test.eq(try Cases.status_of(Cases.post(port, client, {})), 400)
  try Test.eq(try Cases.status_of(Cases.post(port, internal, {})), 500)
  try Test.eq(try Cases.status_of(Cases.stream(port, client, {})), 400)
  Test.eq(try Cases.status_of(Cases.stream(port, internal, {})), 500)
end

def stub_prompt(messages: List[Contract.Message]) -> Result[List[Int]]
  return ok([CLIENT_PROMPT]) if messages[0].content == "client"

  ok([INTERNAL_PROMPT])
end

def refuse_all(requests: Channel[Contract.GenRequest]) -> Void
  while true
    case requests.recv(100)
      ok(request) ->
        fault = Contract.Fault.Internal
        if request.prompt[0] == CLIENT_PROMPT
          fault = Contract.Fault.Client
        end

        _ = request.reply.send(Contract.refusal("stub refusal", fault), 0)
      error(_) -> nil
    end
  end
end
