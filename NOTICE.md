# Notices

This repository contains only Nix packaging (a flake and helper scripts) for
running Qwen3.8-Flash-CIRU-STRIX-IU4 on AMD Strix Halo (gfx1151) systems.
The flake code itself is MIT-licensed (see `LICENSE`). It fetches third-party
artifacts at build time; those remain under their own licenses:

## Runtime

The CIRU runtime payload (`runtime/v4.4.1/ciru-runtime-v4.4.1-nixos-gfx1151.tar.gz`)
is published at <https://github.com/ciru-ai/Qwen3.8-Flash-CIRU-STRIX-IU4>.
It is based on llama.cpp and retains the MIT license and third-party notices
of its components (see the runtime repo's `THIRD_PARTY_NOTICES.md`).

## Model

The model artifacts (main GGUF, PLE files, MTP draft, vision projector) are
published at <https://huggingface.co/jcbtc/Qwen3.8-Flash-CIRU-STRIX-IU4> and
are distributed under the Qwen Community License 1.0. They are downloaded by
`nix run .#download-model` into a local directory and are NOT redistributed
by this repository.

## ROCm SDK

The ROCm 10.0.0 SDK is assembled from AMD's TheRock wheels published at
<https://stable.repo.amd.com/rocm/whl-next>, each under AMD's own open-source
licensing. The bundled pinned HIP/ROCr runtime (pwilkin, commit 7dda3ac6)
ships inside the CIRU payload under its upstream license.

## Trademarks and affiliation

Qwen and AMD names and logos belong to their respective owners. CIRU is an
independent community research project and is not sponsored or endorsed by
Qwen or AMD. This repository is an unofficial packaging of the above and is
not affiliated with Qwen, AMD, or CIRU.
