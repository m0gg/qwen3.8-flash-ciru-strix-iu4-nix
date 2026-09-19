{
  description = "qwen3.8-flash-ciru-strix-iu4-nix: CIRU runtime v4.4.1 + ROCm 10.0.0 (TheRock wheels) for Qwen3.8-Flash-CIRU-STRIX-IU4 on gfx1151 (AMD Strix Halo)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      lib = nixpkgs.lib;

      rocmVersion = "10.0.0";
      gpuTarget = "gfx1151"; # Strix Halo iGPU (Radeon 8060S family); distinct from RDNA4 dGPUs (gfx1201).
      ciruVersion = "4.4.1";

      # --- TheRock ROCm 10 SDK wheels (index: https://stable.repo.amd.com/rocm/whl-next) ---
      # Hashes verified 2026-09-14.
      whlIndex = "https://stable.repo.amd.com/rocm/whl-next";
      fetchWhl =
        { name, sha256 }:
        pkgs.fetchurl {
          url = "${whlIndex}/${name}";
          sha256 = sha256;
        };

      develWheel = fetchWhl {
        name = "rocm-sdk-devel/rocm_sdk_devel-10.0.0-py3-none-linux_x86_64.whl";
        sha256 = "867f06bfe06fc26cfbcd5c30cc9ba88d8b4de86345c3295a3885bfd963346086";
      };
      libsWheel = fetchWhl {
        name = "rocm-sdk-libraries/rocm_sdk_libraries-10.0.0-py3-none-linux_x86_64.whl";
        sha256 = "bbe83a550cb8ceeb306abf6d57df6617857a1b19384549526db2ec81a4374e57";
      };
      devWheel = fetchWhl {
        name = "rocm-sdk-device-gfx1151/rocm_sdk_device_gfx1151-10.0.0-py3-none-linux_x86_64.whl";
        sha256 = "ec705df531e523777a5cd47b2dfadb2272935927c46c122effb11fcdcedb73d0";
      };
      coreWheel = fetchWhl {
        name = "rocm-sdk-core/rocm_sdk_core-10.0.0-py3-none-linux_x86_64.whl";
        sha256 = "3bf4a72d11aa2a4ee1e90572c73630f937d38c1b7af4dda45b483b54655138a7";
      };

      # Reproduce `rocm-sdk init` deterministically without a Python venv:
      # the SDK root is the unpacked devel wheel (bin/, include/, lib/,
      # lib/cmake/{hip,hipblas,rocblas}, lib/rocm_sysdeps, lib/llvm), with the
      # device wheel's gfx1151 kpacks + hipblaslt kernels merged into lib/.
      # This matches the tested NixOS payload layout (ROCM_ROOT tree).
      rocmSdk = pkgs.stdenv.mkDerivation {
        name = "rocm-sdk-${rocmVersion}-${gpuTarget}";
        src = develWheel;
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.unzip pkgs.gzip pkgs.python3 ];
        dontConfigure = true;
        dontInstall = true;
        develWhlFile = "${develWheel}";
        libsWhlFile = "${libsWheel}";
        devWhlFile = "${devWheel}";
        coreWhlFile = "${coreWheel}";
        gpuTargetEnv = "${gpuTarget}";
        buildPhase = ''
          set -e
          mkdir -p "$out" work
          # Devel wheel: SDK payload lives in rocm_sdk_devel/_devel.tar
          unzip -q -d work/devel "$develWhlFile" rocm_sdk_devel/_devel.tar
          tar -xf work/devel/rocm_sdk_devel/_devel.tar -C "$out"
          # Core wheel: base runtime tree (devel has ~3000 relative symlinks into
          # ../_rocm_sdk_core; must be extracted before the libs overlay)
          python3 - "$coreWhlFile" "$out" <<'PY'
import zipfile, os, sys, stat
whl, out = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(whl)
for info in z.infolist():
    name = info.filename
    dest = os.path.join(out, name)
    mode_full = info.external_attr >> 16
    if stat.S_ISDIR(mode_full):
        os.makedirs(dest, exist_ok=True)
    elif stat.S_ISLNK(mode_full):
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        os.symlink(info.linkname, dest)
    else:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with z.open(info) as f:
            data = f.read()
        with open(dest, "wb") as o:
            o.write(data)
        perm = mode_full & 0o777
        if perm:
            os.chmod(dest, perm)
PY
          chmod -R u+w "$out"
          test -d "$out/_rocm_sdk_core"
          test -f "$out/_rocm_sdk_core/.info/version"
          # Libraries wheel: runtime .so + hipblaslt Tensile data
          unzip -q -o -d work/libs "$libsWhlFile"
          cp -a work/libs/_rocm_sdk_libraries "$out"/
          # Device wheel: gfx1151 kpacks, Tensile kernels, ext data + the
          # .devel_links reconcile map used by `rocm-sdk init`
          unzip -q -o -d work/dev "$devWhlFile"
          cp -a work/dev/_rocm_sdk_libraries "$out"/
          chmod -R u+w "$out"
          # Replicate `rocm-sdk init` reconcile: create the symlinks listed in
          # .devel_links/gfx1151.json inside _rocm_sdk_devel, pointing into
          # _rocm_sdk_libraries. This makes the gfx1151 Tensile data reachable
          # from the SDK root (matches the verified working venv layout).
          python3 - "$out" "$devWhlFile" "$gpuTargetEnv" <<'PY'
import zipfile, os, sys, json
out, whl, gpu = sys.argv[1], sys.argv[2], sys.argv[3]
z = zipfile.ZipFile(whl)
raw = z.read(f"_rocm_sdk_libraries/.devel_links/{gpu}.json")
spec = json.loads(raw)
root = os.path.join(out, "_rocm_sdk_devel")
n = 0
for link in spec["links"]:
    rel = link["relpath"]
    tgt = link["target"]
    dest = os.path.join(root, rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.islink(dest) or os.path.exists(dest):
        continue
    os.symlink(tgt, dest)
    n += 1
print(f"reconciled {n} gfx1151 symlinks into _rocm_sdk_devel")
PY
          # Drop the one known-harmless dangling amdsmi symlink so stdenv's
          # noBrokenSymlinks (fixupPhase) passes. amdsmi is not used by the
          # llama build or server; the real .so lives in lib/.
          A="$out/_rocm_sdk_devel/share/amd_smi/amdsmi"
          if [ -L "$A/libamd_smi.so" ] && [ ! -e "$A/libamd_smi.so" ]; then
            rm -f "$A/libamd_smi.so"
          fi
          chmod -R u+w "$out"

          # Sanity checks (postBuild is NOT a stdenv phase, so put them here).
          R="$out/_rocm_sdk_devel"
          test -x "$R/bin/amdclang++"
          test -f "$R/lib/cmake/hip/hip-config.cmake"
          test -f "$R/lib/cmake/hipblas/hipblas-config.cmake"
          test -f "$R/lib/cmake/rocblas/rocblas-config.cmake"
          test -d "$R/lib/rocm_sysdeps"
          test -d "$R/lib/llvm/lib"
          # gfx1151 Tensile data reachable from the SDK root (via reconcile):
          test -d "$R/lib/hipblaslt/library/gfx1151"
          test -f "$R/.kpack/blas_lib_gfx1151.kpack"
          # No dangling symlinks anywhere (the reconcile links must resolve).
          broken=$(find "$out" -type l ! -exec test -e "{}" \; -print | wc -l)
          if [ "$broken" -ne 0 ]; then
            echo "ERROR: $broken dangling symlinks in $out" >&2
            find "$out" -type l ! -exec test -e "{}" \; -print | head -5
            exit 1
          fi
          echo "rocm-sdk-${rocmVersion}-${gpuTarget} assembled"
        '';
      };

      # --- CIRU runtime v4.4.1 ---
      # Uses the published, qualified NixOS/gfx1151 payload from the HF repo.
      # It bundles the inference binaries plus the pinned pwilkin HIP/ROCr
      # (commit 7dda3ac6) under runtime/hip and runtime/rocr, which the
      # v4.4 launcher requires before model load. The payload's own RUNPATHs
      # point at the builder host's paths, so the binaries are repointed to
      # the store and the run script exports the full LD_LIBRARY_PATH.
      # Verified 2026-09-18: all 26 binary hashes match binary-identity.json
      # and the complete ldd set resolves against the TheRock SDK above plus
      # gcc-15.2 libstdc++ (the toolchain the payload was built with).
      ciruPayload = pkgs.fetchurl {
        url = "https://huggingface.co/jcbtc/Qwen3.8-Flash-CIRU-STRIX-IU4/resolve/main/runtime/v4.4.1/ciru-runtime-v4.4.1-nixos-gfx1151.tar.gz";
        sha256 = "56c0c44f1dd708e9abcc3603924ac002bc534d7c66cafc6758d05e662a0c3f38";
      };

      # Distinct (non-symlink) binaries and their sha256 from the v4.4.1
      # binary-identity.json receipt. Checked before patchelf rewrites RPATHs.
      ciruBinaryHashes = [
        "llama-server d043c046f911680bef100c711cf825a06e457ad2b163abcc5f30e19dc3e5074d"
        "llama-bench 38c47483355c5513f62689212dbbb21bf8e9b8120acfb5bae09418919117c174"
        "libllama.so.0.4.0 cf1233a616ed082658ff45612f5ac2e16011cbb0d651d110cb60eccc5fd35517"
        "libllama-common.so.0.4.0 e02dcf7c39cbfb2cf3f87180c800663e152e570c7247421cab481bf8453fe948"
        "libllama-server-impl.so 9512847e3bce1fb83035030f8d58c4740a6391597a145fc94220e85e748e38ef"
        "libllama-bench-impl.so 73bc9ba833d55ef859878c7adbdad2c4980dc0c5a5a57ad92577cd277b5da1c6"
        "libggml.so.0.23.0 4d061b0caf4179de131e31d2666b770441500036e155cfc820a889931bfa6280"
        "libggml-hip.so.0.23.0 346547c8930a41f46b72d2c8a54268cac1ee38bd0833db6be9974db95301754d"
        "libggml-base.so.0.23.0 988ca6568cda24be818894aae84c3efe1c7f6968fbc1fdb98688b68a5f93318d"
        "libggml-cpu.so.0.23.0 5498beba4fea384bd87908b019eab01a2e28db0bc60e302a66ddd93489d08afe"
        "libmtmd.so.0.4.0 f2bd014813584ccbe026f3bf98f56a5358c9ba48d59957d2eb8596d160981c50"
      ];

      ciruRuntime = pkgs.stdenv.mkDerivation {
        name = "ciru-runtime-${ciruVersion}-${gpuTarget}";
        src = ciruPayload;
        dontUnpack = true;
        dontConfigure = true;
        dontInstall = true;
        nativeBuildInputs = [ pkgs.patchelf pkgs.gzip pkgs.coreutils ];
        buildPhase = ''
          set -e
          payload=ciru-runtime-v${ciruVersion}-nixos-${gpuTarget}
          mkdir -p work
          tar -xzf $src -C work
          cp -a "work/$payload" "$out"
          chmod -R u+w "$out"

          # Every distinct binary must match the release receipt.
          while read -r name sha; do
            f="$out/bin/$name"
            test -f "$f" || { echo "missing binary: $name" >&2; exit 1; }
            actual=$(sha256sum "$f" | cut -d' ' -f1)
            if [ "$actual" != "$sha" ]; then
              echo "hash mismatch: $name ($actual != $sha)" >&2
              exit 1
            fi
          done <<EOF
          ${lib.concatStringsSep "\n" ciruBinaryHashes}
          EOF

          # Pinned pwilkin HIP/ROCr runtime the v4.4 launcher requires.
          test -f "$out/runtime/hip/lib/libamdhip64.so"
          test -f "$out/runtime/rocr/lib/libhsa-runtime64.so"

          # Same identity checks the launcher performs before model load.
          grep -aFq "Qwen4Exp MTP image position" "$out/bin/libllama-common.so.0.4.0" \
            || { echo "common library lacks the v4.4.1 vision/MTP fix" >&2; exit 1; }
          for m in flash_attn_index_mask_clear flash_attn_index_mask_set flash_attn_index_mask_empty; do
            grep -aFq "$m" "$out/bin/libggml-hip.so.0.23.0" \
              || { echo "HIP library lacks the indexed-attention correction: $m" >&2; exit 1; }
          done

          # Repoint RUNPATHs into the store so the payload's server/library
          # set is self-contained. The launcher prepends these same dirs via
          # LD_LIBRARY_PATH; gcc lib is covered there, not here.
          for f in "$out"/bin/*; do
            if ! [ -L "$f" ]; then
              patchelf --set-rpath "$out/bin" "$f"
            fi
          done

          # Pinned pwilkin ROCr is gfx1151-native; any HSA_OVERRIDE_GFX_VERSION
          # value breaks HIP device enumeration with it. The qualified server's
          # environment has the variable absent entirely, but the shipped
          # profile forces 11.5.1 via a :- default. Strip the line.
          sed -i '/^HSA_OVERRIDE_GFX_VERSION=/d' "$out/profiles/strix-halo-production.env"

          # Launcher assets must be present.
          test -f "$out/ui/index.html"
          test -x "$out/scripts/ciru/run-server.sh"
          test -f "$out/profiles/strix-halo-production.env"

          broken=$(find "$out" -type l ! -exec test -e "{}" \; -print | wc -l)
          if [ "$broken" -ne 0 ]; then
            echo "ERROR: $broken dangling symlinks in $out" >&2
            exit 1
          fi
          echo "ciru-runtime-${ciruVersion}-${gpuTarget} verified"
        '';
      };

      # --- Model artifacts (~127 GiB + 900 MiB projector) ---
      # Too large for the Nix store; exposed as a download/verify helper that
      # writes to MODEL_DIR (default ./model). Uses the huggingface_hub CLI
      # (resumable downloads) and verifies each file against the repo's
      # checksums afterwards. Checksums from the repo.
      hfRepo = "jcbtc/Qwen3.8-Flash-CIRU-STRIX-IU4";
      hfCli = "${pkgs.python3Packages.huggingface-hub}/bin/hf";
      modelFiles = [
        {
          path = "Qwen3.8-Flash-CIRU-STRIX-IU4.gguf";
          sha256 = "c0ea11e4e24d0f909720b6c4e7462aa1e6fbf5e0f6acc796063f2aed4cf46ed0";
        }
        {
          path = "ple/ple.payload.bin";
          sha256 = "687fc742efb6888c6cd7cf9c80cb4b1ac8cb4707b9409c206699c43363e239b2";
        }
        {
          path = "ple/ple.manifest.json";
          sha256 = "eb7404ce5ef056729452df10ee888e0c300cd0459121444be3313c51788cc171";
        }
        {
          path = "ple/ple.scale.bf16";
          sha256 = "c7c58bd6007672362da2106fdbfaf9f50629e4bdf8598169c598027394ef9791";
        }
        {
          path = "mtp/Qwen3.8-Flash-CIRU-STRIX-IU4-MTP-Q8_0.gguf";
          sha256 = "e6743badef1f2619fcb5addfa4344a2a3368cb75214735117e3af80c70b80642";
        }
        # v4.4.1 vision projector (used with --vision).
        {
          path = "vision/mmproj-Qwen3.8-Flash-F16.mmproj";
          sha256 = "db643482521c722ff1074afd5018c060ef6ce9b828421c7cfc27b2f235c2569b";
        }
      ];
      downloadModel =
        let
          perFile =
            f:
            ''
              rel="${f.path}"
              if echo "${f.sha256}  $MODEL_DIR/$rel" | sha256sum -c - >/dev/null 2>&1; then
                echo "up to date: $rel"
              else
                echo "fetching $rel"
                ${hfCli} download "${hfRepo}" "$rel" --local-dir "$MODEL_DIR"
                echo "${f.sha256}  $MODEL_DIR/$rel" | sha256sum -c -
              fi
            '';
        in
        pkgs.writeScriptBin "download-qwen38-ciru-model"
        ''
          #!/usr/bin/env bash
          set -euo pipefail
          if [ "$#" -ge 1 ]; then MODEL_DIR="$1"; else MODEL_DIR="$PWD/model"; fi
          echo "Downloading model into $MODEL_DIR"
          mkdir -p "$MODEL_DIR"
          ${lib.concatStringsSep "\n" (lib.map perFile modelFiles)}
          echo "All model files present and verified."
        '';

      # gcc's libstdc++: the payload was built with GNU 15.2.0 and needs the
      # matching C++ runtime at load time.
      gccLib = "${pkgs.stdenv.cc.cc.lib}/lib";

      runServer =
        {
          port ? "8080",
          modelDir ? "\${PWD}/model",
          enableVision ? "1",
        }:
        pkgs.writeScript "run-server" ''
          #!/usr/bin/env bash
          set -euo pipefail
          export MODEL_DIR="''${MODEL_DIR:-${modelDir}}"
          export RUNTIME_DIR="${ciruRuntime}"
          export CIRU_RUNTIME_ROOT="${ciruRuntime}/runtime"
          export ROCM_ROOT="${rocmSdk}/_rocm_sdk_devel"
          export ENABLE_VISION="''${ENABLE_VISION:-${enableVision}}"
          # The pinned pwilkin ROCr is gfx1151-native; any HSA_OVERRIDE value
          # (the profile default is 11.5.1) breaks device enumeration with it.
          # Export empty so the profile's :- fallback keeps it off.
          export HSA_OVERRIDE_GFX_VERSION="''${HSA_OVERRIDE_GFX_VERSION:-}"
          export GGML_HIP_ENABLE_UNIFIED_MEMORY="''${GGML_HIP_ENABLE_UNIFIED_MEMORY:-1}"
          extra="''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          # Pinned HIP/ROCr first; TheRock's own copies as fallback for
          # environments where the PM4 runtime cannot open /dev/kfd.
          export LD_LIBRARY_PATH="$CIRU_RUNTIME_ROOT/hip/lib:$CIRU_RUNTIME_ROOT/rocr/lib:${gccLib}:${rocmSdk}/_rocm_sdk_devel/lib:${rocmSdk}/_rocm_sdk_devel/lib/rocm_sysdeps/lib:${rocmSdk}/_rocm_sdk_devel/lib/llvm/lib:${rocmSdk}/_rocm_sdk_core/lib$extra"
          export MODEL_VARIANT=IU4
          exec bash "$RUNTIME_DIR/scripts/ciru/run-server.sh" --port "''${PORT:-${port}}" "$@"
        '';

    in
    {
      packages.${system} = rec {
        default = run-server;
        rocm-sdk = rocmSdk;
        ciru-runtime = ciruRuntime;
        download-model = downloadModel;
        run-server = runServer { };
      };
      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}";
      };
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.cmake
          pkgs.ninja
          pkgs.gcc
          pkgs.openssl
          pkgs.unzip
          pkgs.gzip
          pkgs.curl
          pkgs.coreutils
          pkgs.python3
          pkgs.patchelf
        ];
      };
    };
}
