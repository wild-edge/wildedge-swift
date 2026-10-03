#!/usr/bin/env bash
set -euo pipefail

LLAMA_CPP_TAG="${LLAMA_CPP_TAG:-b9360}"
IOS_MIN_OS_VERSION="${IOS_MIN_OS_VERSION:-18.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_DIR="${APP_DIR}/Packages/LlamaSwiftMultimodal"
OUTPUT_DIR="${LLAMA_MULTIMODAL_OUTPUT_DIR:-${PACKAGE_DIR}/Artifacts}"
OUTPUT_XCFRAMEWORK="${OUTPUT_DIR}/llama.xcframework"
BUILD_ROOT="${LLAMA_MULTIMODAL_BUILD_DIR:-${APP_DIR}/.build/llama-multimodal}"
SOURCE_ROOT="${LLAMA_CPP_SOURCE_DIR:-${BUILD_ROOT}/src/llama.cpp-${LLAMA_CPP_TAG}}"

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"

check_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: $1 is required" >&2
        exit 1
    fi
}

check_tool curl
check_tool cmake
check_tool xcrun

download_source_if_needed() {
    if [[ -d "${SOURCE_ROOT}" ]]; then
        return
    fi

    local src_parent="${BUILD_ROOT}/src"
    local zip_path="${BUILD_ROOT}/llama.cpp-${LLAMA_CPP_TAG}.zip"
    mkdir -p "${src_parent}"

    if [[ ! -f "${zip_path}" ]]; then
        curl -L \
            -o "${zip_path}" \
            "https://github.com/ggml-org/llama.cpp/archive/refs/tags/${LLAMA_CPP_TAG}.zip"
    fi

    ditto -x -k "${zip_path}" "${src_parent}"
}

configure_slice() {
    local build_dir="$1"
    local sdk="$2"
    local archs="$3"
    local platform="$4"

    cmake -B "${build_dir}" -G Xcode \
        -DCMAKE_C_COMPILER="$(xcrun --sdk "${sdk}" --find clang)" \
        -DCMAKE_CXX_COMPILER="$(xcrun --sdk "${sdk}" --find clang++)" \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
        -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_BUILD_COMMON=ON \
        -DLLAMA_BUILD_TOOLS=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        -DLLAMA_BUILD_APP=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_BLAS_DEFAULT=ON \
        -DGGML_METAL_USE_BF16=ON \
        -DGGML_NATIVE=OFF \
        -DGGML_OPENMP=OFF \
        -DLLAMA_OPENSSL=OFF \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="${sdk}" \
        -DCMAKE_OSX_ARCHITECTURES="${archs}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_MIN_OS_VERSION}" \
        -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="${platform}" \
        -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
        -S "${SOURCE_ROOT}"
}

build_slice() {
    local build_dir="$1"
    cmake --build "${build_dir}" --config Release --target mtmd llama -- -quiet
}

copy_headers_and_modulemap() {
    local framework_dir="$1"

    mkdir -p "${framework_dir}/Headers" "${framework_dir}/Modules"

    cp "${SOURCE_ROOT}/include/llama.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/ggml/include/ggml.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/ggml/include/ggml-opt.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/ggml/include/ggml-alloc.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/ggml/include/ggml-backend.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/ggml/include/ggml-metal.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/ggml/include/ggml-cpu.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/ggml/include/ggml-blas.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/ggml/include/gguf.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/tools/mtmd/mtmd.h" "${framework_dir}/Headers/"
    cp "${SOURCE_ROOT}/tools/mtmd/mtmd-helper.h" "${framework_dir}/Headers/"

    cat > "${framework_dir}/Modules/module.modulemap" <<'EOF'
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"
    header "mtmd.h"
    header "mtmd-helper.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF
}

write_info_plist() {
    local framework_dir="$1"
    local platform_name="$2"
    local supported_platform="$3"

    cat > "${framework_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama.multimodal</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>${LLAMA_CPP_TAG}</string>
    <key>MinimumOSVersion</key>
    <string>${IOS_MIN_OS_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platform}</string>
    </array>
    <key>DTPlatformName</key>
    <string>${platform_name}</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
</dict>
</plist>
EOF
}

combine_slice() {
    local build_dir="$1"
    local release_dir="$2"
    local sdk="$3"
    local min_version_flag="$4"
    local platform_name="$5"
    local supported_platform="$6"
    local output_dir="${build_dir}/framework"
    local framework_dir="${output_dir}/llama.framework"
    local temp_dir="${build_dir}/combine"

    mkdir -p "${temp_dir}" "${framework_dir}"
    copy_headers_and_modulemap "${framework_dir}"
    write_info_plist "${framework_dir}" "${platform_name}" "${supported_platform}"

    local libs=(
        "${build_dir}/tools/mtmd/${release_dir}/libmtmd.a"
        "${build_dir}/src/${release_dir}/libllama.a"
        "${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
    )

    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}"
    xcrun --sdk "${sdk}" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk "${sdk}" --show-sdk-path)" \
        -arch arm64 \
        "${min_version_flag}" \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation \
        -framework Metal \
        -framework Accelerate \
        -install_name "@rpath/llama.framework/llama" \
        -o "${framework_dir}/llama"
}

download_source_if_needed

DEVICE_BUILD_DIR="${BUILD_ROOT}/build-ios-device"
SIM_BUILD_DIR="${BUILD_ROOT}/build-ios-simulator"

configure_slice "${DEVICE_BUILD_DIR}" iphoneos arm64 iphoneos
build_slice "${DEVICE_BUILD_DIR}"
combine_slice "${DEVICE_BUILD_DIR}" Release-iphoneos iphoneos "-mios-version-min=${IOS_MIN_OS_VERSION}" iphoneos iPhoneOS

configure_slice "${SIM_BUILD_DIR}" iphonesimulator arm64 iphonesimulator
build_slice "${SIM_BUILD_DIR}"
combine_slice "${SIM_BUILD_DIR}" Release-iphonesimulator iphonesimulator "-mios-simulator-version-min=${IOS_MIN_OS_VERSION}" iphonesimulator iPhoneSimulator

mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_XCFRAMEWORK}"
xcrun xcodebuild -create-xcframework \
    -framework "${DEVICE_BUILD_DIR}/framework/llama.framework" \
    -framework "${SIM_BUILD_DIR}/framework/llama.framework" \
    -output "${OUTPUT_XCFRAMEWORK}"

echo "Built ${OUTPUT_XCFRAMEWORK}"
