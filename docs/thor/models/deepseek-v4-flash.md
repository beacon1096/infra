# DeepSeek-v4 Flash: feasibility review

[Thor overview](../../thor.md)

Status: source review only; this recipe has not been deployed or benchmarked
on Thor. Reviewed deployment revision:
`fdcd538fbf95fb15b2d6850db9613d22b2c889b8`.

## Capacity and kernel constraints

The DeepSeek single-Spark recipe has two additional constraints. It uses a
REAP-K216 expert-pruned model with EXL3/Trellis quantization, rather than merely
quantizing the complete original model. Its default launch requires about
114.3 GiB of free memory, leaving little room for a desktop on this device.
The build also explicitly targets SM120/SM121-family kernels, including
`CUTE_DSL_ARCH=sm_121a`; changing a Torch architecture flag alone is not evidence
that its sparse attention and quantized expert kernels support Thor's SM110.
It is therefore a porting project before it is a model-download experiment.

## External comparison

The author's adaptation report gives approximately 70 tokens/s for DeepSeek
using two machines. This is not a comparable single-Thor result.
[Flash Next](qwen3.8-flash-next.md) was selected for the local deployment
experiments first.

## References

- [DeepSeek-v4 Flash single-Spark deployment at the reviewed revision](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark/tree/fdcd538fbf95fb15b2d6850db9613d22b2c889b8)
- [DeepSeek Spark checkpoint and disk requirements](https://huggingface.co/0xSero/deepseek-v4-flash-0731-spark)
- [DeepSeek Spark runtime Dockerfile and architecture targets](https://github.com/0xSero/deepseek-v4-flash-0731-spark-sparkinfer/blob/main/Dockerfile)
- [Author's DFlash2 single-stream 125–133 TPS report](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/) — external result, not a local measurement.
