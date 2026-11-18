## Prints the size of each bound struct as Agentica computes it, for scripts/check-bindings.py.

import Llama from "../src/llama_server/llama"

def main() -> Void
  puts("ModelParams #{Native.size_of(Llama.ModelParams)}")
  puts("ContextParams #{Native.size_of(Llama.ContextParams)}")
  puts("Batch #{Native.size_of(Llama.Batch)}")
  puts("SamplerChainParams #{Native.size_of(Llama.SamplerChainParams)}")
end
