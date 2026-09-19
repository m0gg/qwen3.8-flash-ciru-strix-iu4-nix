# qwen3.8-flash-ciru-strix-iu4-nix

Nix flake to run [Qwen3.8-Flash-CIRU-STRIX-IU4](https://huggingface.co/jcbtc/Qwen3.8-Flash-CIRU-STRIX-IU4)
on AMD Strix Halo (gfx1151) machines with Nix/NixOS.

> [!WARNING]
> **This project was sloped together by AI.** The flake, its build phases, and
> its docs were written largely by language models during an overnight
> debugging session. They work — hashes, identity greps, and device
> enumeration all pass on the reference hardware — but read before you trust,
> and file issues if you find AI-shaped holes.

Assembles a self-contained inference stack from pinned, hash-verified upstream
artifacts (nothing is redistributed here — see [NOTICE.md](NOTICE.md)):

| Component | Source |
| --- | --- |
| ROCm 10.0.0 SDK | AMD TheRock wheels (`rocm_sdk_devel/core/libraries/device-gfx1151`), reassembled into a `rocm-sdk init`-equivalent tree |
| CIRU runtime v4.4.1 | qualified `nixos-gfx1151` payload from the [CIRU runtime repo](https://github.com/ciru-ai/Qwen3.8-Flash-CIRU-STRIX-IU4), including pinned pwilkin HIP/ROCr |
| Model weights (~127 GiB + projector) | [HF repo](https://huggingface.co/jcbtc/Qwen3.8-Flash-CIRU-STRIX-IU4) via the `hf` CLI (resumable), then sha256-verified per file (kept out of the Nix store) |

## Usage

```bash
# 1. Fetch and checksum-verify the model into ./model (large!)
nix run .#download-model

# 2. Start the server on port 8080
nix run .
```

Overrides (all optional, env-based):

```bash
MODEL_DIR=/path/to/models PORT=9090 nix run .
ENABLE_VISION=0 nix run .      # text-only
```

Packages: `default` / `run-server` (the launch wrapper), `ciru-runtime` (the
patched runtime payload), `rocm-sdk`, `download-model`. The build embeds the
vendor's binary-identity checks (sha256 receipt + launcher marker greps) as
build phases, so a wrong or tampered artifact fails at build time, not at
server start.

## Requirements

- x86_64-linux, AMD Strix Halo iGPU (gfx1151) with access to `/dev/kfd`
- ~140 GiB free disk for the model artifacts
- The pinned pwilkin ROCr is gfx1151-native: do **not** set
  `HSA_OVERRIDE_GFX_VERSION`; the wrapper keeps it unset on purpose.

## License

The flake code is MIT ([LICENSE](LICENSE)). Fetched artifacts remain under
their own licenses (Qwen Community License 1.0 for the model, MIT +
third-party notices for the runtime) — see [NOTICE.md](NOTICE.md).
