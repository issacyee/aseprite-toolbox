#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
# shellcheck source=tools/aseprite/versions.env
source "$repo_root/tools/aseprite/versions.env"

usage() {
  cat <<'HELP'
Usage:
  bash tools/aseprite/build.sh resolve [options]
  bash tools/aseprite/build.sh build --target TARGET [options]

Commands:
  resolve  Validate versions/target and print the GitHub Actions matrix as JSON.
  build    Download, build, package, then smoke-test the extracted ZIP on this host.

Options:
  --target TARGET            all (resolve only), windows-x64, linux-x64,
                             macos-arm64, or macos-x64
  --aseprite-version TAG     Override ASEPRITE_VERSION in versions.env
  --skia-version TAG         Override SKIA_VERSION in versions.env
  -h, --help                Show this help

Build dependencies: Bash, Git, curl, CMake, Ninja, and the native C++ toolchain.
Windows requires Git Bash with an initialized MSVC x64 environment.
HELP
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '[aseprite] %s\n' "$*" >&2; }

command_name=${1:---help}
case "$command_name" in
  -h|--help) usage; exit 0 ;;
  resolve|build) shift ;;
  *) die "Unknown command: $command_name (use --help)" ;;
esac

target=all
aseprite_version=$ASEPRITE_VERSION
skia_version=$SKIA_VERSION
while (($#)); do
  case "$1" in
    --target|--aseprite-version|--skia-version)
      if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
        die "Missing value for $1"
      fi
      case "$1" in
        --target) target=$2 ;;
        --aseprite-version) aseprite_version=$2 ;;
        --skia-version) skia_version=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# tag 用于 URL、路径、Shell 输出或 JSON 前，先限制其格式。
[[ "$aseprite_version" =~ ^v[0-9]+(\.[0-9]+){1,3}(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]] \
  || die "Invalid Aseprite version tag: $aseprite_version"
[[ "$skia_version" =~ ^m[0-9]+-[a-f0-9]+$ ]] || die "Invalid Skia version tag: $skia_version"
case "$target" in
  all|windows-x64|linux-x64|macos-arm64|macos-x64) ;;
  *) die "Unknown target: $target" ;;
esac

matrix_entry() {
  local entry_target=$1 runner
  case "$entry_target" in
    windows-x64) runner=windows-2022 ;;
    linux-x64) runner=ubuntu-24.04 ;;
    macos-arm64) runner=macos-15 ;;
    macos-x64) runner=macos-15-intel ;;
  esac
  printf '{"target":"%s","runner":"%s"}' "$entry_target" "$runner"
}

if [[ "$command_name" == resolve ]]; then
  printf '{"aseprite_version":"%s","skia_version":"%s","matrix":{"include":[' \
    "$aseprite_version" "$skia_version"
  if [[ "$target" == all ]]; then
    separator=
    for entry in windows-x64 linux-x64 macos-arm64 macos-x64; do
      printf '%s' "$separator"
      matrix_entry "$entry"
      separator=,
    done
  else
    matrix_entry "$target"
  fi
  printf ']}}\n'
  exit 0
fi

[[ "$target" != all ]] || die 'build needs a single --target; use the workflow to build all targets'
host_os=$(uname -s)
host_arch=$(uname -m)
case "$host_os:$host_arch:$target" in
  MINGW*:x86_64:windows-x64|MSYS*:x86_64:windows-x64|CYGWIN*:x86_64:windows-x64) ;;
  Linux:x86_64:linux-x64|Darwin:arm64:macos-arm64|Darwin:x86_64:macos-x64) ;;
  *) die "Target $target cannot be built on $host_os/$host_arch; native builds are required" ;;
esac
for dependency in git curl cmake ninja; do
  command -v "$dependency" >/dev/null || die "Missing dependency: $dependency"
done
if [[ "$target" == windows-x64 ]]; then
  command -v cl.exe >/dev/null || die 'Initialize an MSVC x64 developer environment before starting Git Bash'
fi

native_path() {
  if [[ "$target" == windows-x64 ]]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

mkdir -p "$repo_root/.work/aseprite" "$repo_root/dist"
# 每次使用新目录，避免重建时混入旧的目标文件或安装包。
work_dir=$(mktemp -d "$repo_root/.work/aseprite/$target.XXXXXX")
source_dir=$work_dir/source
skia_dir=$work_dir/skia
build_dir=$work_dir/build
package_dir=$work_dir/package
verify_dir=$work_dir/extracted
archive=$repo_root/dist/Aseprite-$aseprite_version-$target.zip
mkdir -p "$skia_dir" "$package_dir" "$verify_dir"
log "Work directory: $work_dir"

log "Downloading Aseprite $aseprite_version and submodules"
git clone --branch "$aseprite_version" --depth 1 --recurse-submodules --shallow-submodules \
  https://github.com/aseprite/aseprite.git "$source_dir"
# --branch 也接受分支名，因此必须核实精确 tag，确保构建元数据可追溯。
git -C "$source_dir" describe --exact-match --tags HEAD | grep -Fx -- "$aseprite_version" >/dev/null \
  || die "Source checkout does not match tag $aseprite_version"
required_skia=$(tr -d '\r\n' < "$source_dir/laf/misc/skia-tag.txt")
[[ "$required_skia" == "$skia_version" ]] \
  || die "Aseprite $aseprite_version requires Skia $required_skia; selected $skia_version. Update versions.env or --skia-version."

case "$target" in
  windows-x64) skia_platform=Windows; skia_arch=x64; skia_library=skia.lib ;;
  linux-x64) skia_platform=Linux; skia_arch=x64; skia_library=libskia.a ;;
  macos-arm64) skia_platform=macOS; skia_arch=arm64; skia_library=libskia.a ;;
  macos-x64) skia_platform=macOS; skia_arch=x64; skia_library=libskia.a ;;
esac
skia_asset=Skia-$skia_platform-Release-$skia_arch.zip
log "Downloading $skia_asset ($skia_version)"
curl --fail --location --retry 3 --output "$work_dir/skia.zip" \
  "https://github.com/aseprite/skia/releases/download/$skia_version/$skia_asset"
(cd "$skia_dir" && cmake -E tar xf "$(native_path "$work_dir/skia.zip")")
skia_library_dir=$skia_dir/out/Release-$skia_arch
[[ -f "$skia_library_dir/$skia_library" ]] || die 'Skia archive is missing the expected native library'

cmake_args=(
  -S "$(native_path "$source_dir")" -B "$(native_path "$build_dir")" -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  # CMake 4 移除了部分随附依赖仍在声明的旧策略。
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DENABLE_TESTS=OFF -DENABLE_SCRIPTING=ON -DENABLE_CCACHE=OFF
  -DLAF_BACKEND=skia -DOPENSSL_USE_STATIC_LIBS=ON
  "-DSKIA_DIR=$(native_path "$skia_dir")"
  "-DSKIA_LIBRARY_DIR=$(native_path "$skia_library_dir")"
  "-DSKIA_LIBRARY=$(native_path "$skia_library_dir/$skia_library")"
)
case "$target" in
  linux-x64)
    export CC=clang CXX=clang++
    cmake_args+=(-DCMAKE_CXX_FLAGS=-stdlib=libstdc++ -DCMAKE_EXE_LINKER_FLAGS=-stdlib=libstdc++) ;;
  macos-arm64|macos-x64)
    if [[ "$target" == macos-arm64 ]]; then
      cmake_args+=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DPNG_ARM_NEON=on)
    else
      cmake_args+=(-DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=10.14)
    fi
    cmake_args+=("-DCMAKE_OSX_SYSROOT=$(xcrun --sdk macosx --show-sdk-path)") ;;
esac
log 'Configuring and building Release with Lua scripting'
cmake "${cmake_args[@]}"
cmake --build "$(native_path "$build_dir")" --target aseprite --parallel

# macOS 的 bin/aseprite 和 bin/data 是指向应用包内部的绝对符号链接。
# 复制完整应用包，避免产物中的链接仍指向构建机器。
if [[ "$target" == macos-* ]]; then
  cp -R "$build_dir/bin/Aseprite.app" "$package_dir/"
  executable_relative=Aseprite.app/Contents/MacOS/aseprite
  data_relative=Aseprite.app/Contents/Resources/data
else
  executable_relative=aseprite
  [[ "$target" != windows-x64 ]] || executable_relative=aseprite.exe
  cp "$build_dir/bin/$executable_relative" "$package_dir/"
  cp -R "$build_dir/bin/data" "$package_dir/"
  data_relative=data
  # 保留原生构建在可执行文件旁生成的运行库。
  shopt -s nullglob
  runtime_libraries=("$build_dir/bin/"*.dll "$build_dir/bin/"*.so "$build_dir/bin/"*.so.*)
  if ((${#runtime_libraries[@]})); then cp -L "${runtime_libraries[@]}" "$package_dir/"; fi
fi
portable_config=$(dirname "$package_dir/$executable_relative")/aseprite.ini
printf '# Aseprite 便携配置\n' > "$portable_config"
{
  printf 'aseprite_version=%s\n' "$aseprite_version"
  printf 'aseprite_commit=%s\n' "$(git -C "$source_dir" rev-parse HEAD)"
  printf 'skia_version=%s\n' "$skia_version"
  printf 'target=%s\nbuild_type=Release\nscripting=ON\n' "$target"
  printf 'toolbox_commit=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
  printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'workflow_run=%s\n' "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-local}"
} > "$package_dir/build-info.txt"

# 解压后的安装包通过全部检查后，才输出最终 ZIP。
candidate_archive=$work_dir/Aseprite-$aseprite_version-$target.zip
(cd "$package_dir" && cmake -E tar cf "$(native_path "$candidate_archive")" --format=zip .)
(cd "$verify_dir" && cmake -E tar xf "$(native_path "$candidate_archive")")
executable=$verify_dir/$executable_relative
[[ -x "$executable" && -f "$verify_dir/$data_relative/gui.xml" ]] \
  || die 'Extracted archive is missing its executable, execute permission, or data/gui.xml'
reported_version=$("$executable" --version)
[[ "$reported_version" == "Aseprite ${aseprite_version#v}"* ]] \
  || die "Unexpected packaged version: $reported_version"
cat > "$work_dir/smoke.lua" <<'LUA'
assert(not app.isUIAvailable, "Smoke test must run in batch mode")
local sprite = Sprite(2, 2, ColorMode.RGB)
sprite:saveAs(app.params["output"])
sprite:close()
LUA
log "Testing extracted package: $reported_version"
"$executable" --batch --script-param "output=$(native_path "$work_dir/smoke.png")" \
  --script "$(native_path "$work_dir/smoke.lua")"
[[ -s "$work_dir/smoke.png" ]] || die 'Packaged Lua runtime did not export the smoke-test PNG'
# 使用解压产物中的运行时验证扩展的真实图像和事件 API。
# Lua 测试会跳过低于扩展兼容基线的版本。
log 'Testing timelapse recording with the extracted Lua runtime'
"$executable" --batch --script-param "output=$(native_path "$work_dir/timelapse")" \
  --script "$(native_path "$repo_root/tests/timelapse/aseprite.lua")"
if [[ ! -s "$work_dir/timelapse/result.json" ]] \
  || ! grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$work_dir/timelapse/result.json"; then
  die 'Packaged Lua runtime did not pass the timelapse integration test'
fi
cp "$candidate_archive" "$archive"
log "Verified ZIP: $archive"
