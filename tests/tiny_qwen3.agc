## A tiny random Qwen3 as a Hugging Face folder (`config.json`, `model.safetensors`, `tokenizer.json`), for the tests of
## `server_ml.agc`: the same weights every time, and a tokenizer that holds the 256 byte tokens, so any text encodes.
##
## `agentica tests/tiny_qwen3.agc DIR [stop]` writes the folder `DIR`; with `stop` it is a model whose greedy answer is
## `<|im_end|>` at once (its final norm is zero, so every logit ties, and `<|im_end|>` is the first id). It is a program of its own because writing the weights on
## the reference backend takes more steps than a test has.
##
## The output head gives the printable ASCII tokens (32 to 126) logits far above the rest, which stay at 0: whatever
## the weights do, greedy or sampled text is whole ASCII, so a stream has no broken character.

import SafetensorsWrite from "pkg/hub/safetensors_write"
import Tensor from "pkg/tensor/tensor"

## The positions the model accepts: the context of a server on it.
MAX_POSITIONS = 512

HIDDEN = 16
LAYERS = 2
HEADS = 4
KV_HEADS = 2
HEAD_DIM = 8
INTERMEDIATE = 32
BYTES = 256
## `<|endoftext|>`, `<|im_start|>` and `<|im_end|>` after the bytes.
VOCAB = 259
MODULUS = 2147483647

def main() -> Void
  args = System.args()
  if args.size < 1 or args.size > 2 or (args.size == 2 and args[1] != "stop")
    IO.warn("usage: agentica tests/tiny_qwen3.agc DIR [stop]")
    System.exit(2)
  end

  written = write(args[0], args.size == 2)
  if !written.ok?
    IO.warn("tiny_qwen3: #{written.message}")
    System.exit(1)
  end
end

## Writes the model folder `dir` (made if needed).
def write(dir: String, stops_at_once: Bool) -> Result[Void]
  try Dir.mkdir(dir)
  try File.write_text("#{dir}/config.json", config())
  try File.write_text("#{dir}/tokenizer.json", try tokenizer(stops_at_once))
  SafetensorsWrite.write("#{dir}/model.safetensors", try weights(stops_at_once))
end

private

PRE_TOKENIZER = (
  "{\"type\":\"Sequence\",\"pretokenizers\":[{\"type\":\"Split\",\"pattern\":{\"Regex\":\"(?i:'s|'t|'re|'ve|'m|'ll|'d)|" +
  "[^\\\\r\\\\n\\\\p{L}\\\\p{N}]?\\\\p{L}+|\\\\p{N}| ?[^\\\\s\\\\p{L}\\\\p{N}]+[\\\\r\\\\n]*|\\\\s*[\\\\r\\\\n]+|\\\\s+(?!\\\\S)|\\\\s+\"}," +
  "\"behavior\":\"Isolated\",\"invert\":false},{\"type\":\"ByteLevel\",\"add_prefix_space\":false,\"trim_offsets\":true," +
  "\"use_regex\":false}]}"
)

struct Weights
  seed: Int
  tensors: Map[String, Tensor.Tensor]
end

def config() -> String
  JSON.encode(
    JSON.object({
      "model_type": JSON.from("qwen3"),
      "hidden_act": JSON.from("silu"),
      "hidden_size": JSON.from(HIDDEN),
      "num_hidden_layers": JSON.from(LAYERS),
      "num_attention_heads": JSON.from(HEADS),
      "num_key_value_heads": JSON.from(KV_HEADS),
      "head_dim": JSON.from(HEAD_DIM),
      "intermediate_size": JSON.from(INTERMEDIATE),
      "vocab_size": JSON.from(VOCAB),
      "max_position_embeddings": JSON.from(MAX_POSITIONS),
      "rms_norm_eps": JSON.from(0.000001),
      "rope_theta": JSON.from(1000000.0),
      "tie_word_embeddings": JSON.from(false),
      "attention_bias": JSON.from(false),
      "use_sliding_window": JSON.from(false),
    }),
  )
end

# --- the tokenizer

## The byte tokens come first, then the three added ones; with `stops_at_once` the added ones come first, with
## `<|im_end|>` the id 0.
def tokenizer(stops_at_once: Bool) -> Result[String]
  first_byte = 0
  first_added = BYTES
  added = ["<|endoftext|>", "<|im_start|>", "<|im_end|>"]
  if stops_at_once
    first_byte = 3
    first_added = 0
    added = ["<|im_end|>", "<|endoftext|>", "<|im_start|>"]
  end

  vocab: Map[String, Int] = {}
  for b in 0...BYTES
    vocab = vocab.put(byte_char(b), first_byte + b)
  end

  entries = added.map do |t| added_entry(first_added + added.index(t).unwrap_or(0), t) end
  ok(
    "{\"version\":\"1.0\",\"truncation\":null,\"padding\":null,\"added_tokens\":[#{entries.join(",")}]," +
    "\"normalizer\":{\"type\":\"NFC\"},\"pre_tokenizer\":#{PRE_TOKENIZER}," +
    "\"post_processor\":{\"type\":\"ByteLevel\",\"add_prefix_space\":true,\"trim_offsets\":false,\"use_regex\":true}," +
    "\"decoder\":{\"type\":\"ByteLevel\",\"add_prefix_space\":true,\"trim_offsets\":true,\"use_regex\":true}," +
    "\"model\":{\"type\":\"BPE\",\"dropout\":null,\"unk_token\":null,\"continuing_subword_prefix\":null," +
    "\"end_of_word_suffix\":null,\"fuse_unk\":false,\"byte_fallback\":false,\"ignore_merges\":false," +
    "\"vocab\":#{JSON.encode(vocab)},\"merges\":[]}}",
  )
end

def added_entry(id: Int, content: String) -> String
  (
    "{\"id\":#{id},\"content\":#{JSON.encode(content)},\"single_word\":false,\"lstrip\":false,\"rstrip\":false," +
    "\"normalized\":false,\"special\":true}"
  )
end

## The character that byte-level BPE writes for a byte (GPT-2's table): a printable byte is itself, the others come
## after U+0100 in the order of their values.
def byte_char(b: Int) -> String
  return String.from_code(b) if (b >= 33 and b <= 126) or (b >= 161 and b <= 172) or b >= 174

  shifted = 0
  for lower in 0...b
    if not ((lower >= 33 and lower <= 126) or (lower >= 161 and lower <= 172) or lower >= 174)
      shifted += 1
    end
  end

  String.from_code(256 + shifted)
end

# --- the weights

def weights(zero_norm: Bool) -> Result[Map[String, Tensor.Tensor]]
  w = Weights(seed: 1, tensors: {})
  w = try add(w, "model.embed_tokens.weight", [VOCAB, HIDDEN], 0.0, 0.5)
  for i in 0...LAYERS
    p = "model.layers.#{i}"
    w = try add(w, "#{p}.input_layernorm.weight", [HIDDEN], 1.0, 0.2)
    w = try add(w, "#{p}.post_attention_layernorm.weight", [HIDDEN], 1.0, 0.2)
    w = try add(w, "#{p}.self_attn.q_proj.weight", [HEADS * HEAD_DIM, HIDDEN], 0.0, 0.5)
    w = try add(w, "#{p}.self_attn.k_proj.weight", [KV_HEADS * HEAD_DIM, HIDDEN], 0.0, 0.5)
    w = try add(w, "#{p}.self_attn.v_proj.weight", [KV_HEADS * HEAD_DIM, HIDDEN], 0.0, 0.5)
    w = try add(w, "#{p}.self_attn.o_proj.weight", [HIDDEN, HEADS * HEAD_DIM], 0.0, 0.5)
    w = try add(w, "#{p}.self_attn.q_norm.weight", [HEAD_DIM], 1.0, 0.2)
    w = try add(w, "#{p}.self_attn.k_norm.weight", [HEAD_DIM], 1.0, 0.2)
    w = try add(w, "#{p}.mlp.gate_proj.weight", [INTERMEDIATE, HIDDEN], 0.0, 0.5)
    w = try add(w, "#{p}.mlp.up_proj.weight", [INTERMEDIATE, HIDDEN], 0.0, 0.5)
    w = try add(w, "#{p}.mlp.down_proj.weight", [HIDDEN, INTERMEDIATE], 0.0, 0.5)
  end

  if zero_norm
    w = try add(w, "model.norm.weight", [HIDDEN], 0.0, 0.0)
  else
    w = try add(w, "model.norm.weight", [HIDDEN], 1.0, 0.2)
  end

  w = try add_head(w)
  ok(w.tensors)
end

def add(w: Weights, name: String, shape: List[Int], center: Float, spread: Float) -> Result[Weights]
  count = shape.reduce(1) do |n, d| n * d end
  values: List[Tensor.Values] = []
  state = w.seed
  for _ in 0...count
    state = (state * 48271) % MODULUS
    values = values.push(Tensor.Values.Float(center + ((2.0 * state.to_f) / MODULUS.to_f - 1.0) * spread))
  end

  tensor = try Tensor.from_list(values, shape, Tensor.Dtype.F32, Tensor.Backend.Reference)
  ok(Weights(seed: state, tensors: w.tensors.put(name, tensor)))
end

## The rows of the printable ASCII tokens are large, the others are zero.
def add_head(w: Weights) -> Result[Weights]
  values: List[Tensor.Values] = []
  state = w.seed
  for id in 0...VOCAB
    for _ in 0...HIDDEN
      state = (state * 48271) % MODULUS
      v = 0.0
      if id >= 32 and id <= 126
        v = ((2.0 * state.to_f) / MODULUS.to_f - 1.0) * 8.0
      end

      values = values.push(Tensor.Values.Float(v))
    end
  end

  tensor = try Tensor.from_list(values, [VOCAB, HIDDEN], Tensor.Dtype.F32, Tensor.Backend.Reference)
  ok(Weights(seed: state, tensors: w.tensors.put("lm_head.weight", tensor)))
end
