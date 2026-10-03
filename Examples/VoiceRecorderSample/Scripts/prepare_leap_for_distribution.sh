#!/bin/sh
set -e

APP_FRAMEWORKS_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
LEAP_FRAMEWORK="${APP_FRAMEWORKS_DIR}/LeapSDK.framework"
LEAP_BINARY="${LEAP_FRAMEWORK}/LeapSDK"
LEAP_NESTED_FRAMEWORKS="${LEAP_FRAMEWORK}/Frameworks"
TARGET_MINIMUM_OS="${IPHONEOS_DEPLOYMENT_TARGET:-}"

code_signing_enabled() {
  [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] &&
    [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ] &&
    [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] &&
    [ "${CODE_SIGNING_REQUIRED:-YES}" != "NO" ]
}

framework_bundle_identifier() {
  framework="$1"
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${framework}/Info.plist" 2>/dev/null || true
}

sign_framework() {
  framework="$1"
  identifier="${2:-}"

  if [ ! -d "${framework}" ]; then
    return 0
  fi

  if ! code_signing_enabled; then
    echo "Skipping framework signing for ${framework}: code signing disabled."
    return 0
  fi

  if [ -z "${identifier}" ]; then
    identifier="$(framework_bundle_identifier "${framework}")"
  fi

  if [ -n "${identifier}" ]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
      --identifier "${identifier}" \
      --timestamp=none \
      --generate-entitlement-der \
      "${framework}"
  else
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
      --timestamp=none \
      --generate-entitlement-der \
      "${framework}"
  fi
}

set_framework_minimum_os() {
  framework="$1"
  info_plist="${framework}/Info.plist"

  if [ -z "${TARGET_MINIMUM_OS}" ] || [ ! -f "${info_plist}" ]; then
    return 0
  fi

  /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion ${TARGET_MINIMUM_OS}" "${info_plist}" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string ${TARGET_MINIMUM_OS}" "${info_plist}"
}

set_framework_minimum_os "${APP_FRAMEWORKS_DIR}/onnxruntime.framework"
sign_framework "${APP_FRAMEWORKS_DIR}/onnxruntime.framework"

if [ ! -d "${LEAP_NESTED_FRAMEWORKS}" ]; then
  exit 0
fi

patch_dependency() {
  binary="$1"
  old_path="$2"
  new_path="$3"

  if [ -f "${binary}" ]; then
    /usr/bin/install_name_tool -change "${old_path}" "${new_path}" "${binary}" || true
  fi
}

runtime_bundle_identifier() {
  framework="$1"
  binary_name="$(/usr/bin/basename "${framework}" .framework)"
  bundle_suffix="$(printf "%s" "${binary_name}" | /usr/bin/tr "_" "-")"

  printf "dev.wildedge.leap-runtime.%s" "${bundle_suffix}"
}

wrap_dylib_as_framework() {
  dylib_name="$1"
  binary_name="${dylib_name%.dylib}"
  source_binary="${LEAP_NESTED_FRAMEWORKS}/${dylib_name}"
  framework_dir="${APP_FRAMEWORKS_DIR}/${binary_name}.framework"
  framework_binary="${framework_dir}/${binary_name}"

  if [ ! -f "${source_binary}" ]; then
    return 0
  fi

  /bin/rm -rf "${framework_dir}"
  /bin/mkdir -p "${framework_dir}"
  /bin/mv "${source_binary}" "${framework_binary}"
  /bin/chmod 755 "${framework_binary}" || true

  bundle_suffix="$(printf "%s" "${binary_name}" | /usr/bin/tr "_" "-")"
  cat > "${framework_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${binary_name}</string>
	<key>CFBundleIdentifier</key>
	<string>dev.wildedge.leap-runtime.${bundle_suffix}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${binary_name}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>${IPHONEOS_DEPLOYMENT_TARGET:-17.0}</string>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>arm64</string>
	</array>
</dict>
</plist>
EOF

  /usr/bin/install_name_tool -id "@rpath/${binary_name}.framework/${binary_name}" "${framework_binary}" || true
}

wrap_dylib_as_framework "libinference_engine_llamacpp_backend.dylib"
wrap_dylib_as_framework "libinference_engine.dylib"
wrap_dylib_as_framework "libie_zip.dylib"

patch_dependency "${LEAP_BINARY}" "@rpath/libinference_engine.dylib" \
  "@rpath/libinference_engine.framework/libinference_engine"
patch_dependency "${LEAP_BINARY}" "@rpath/libinference_engine_llamacpp_backend.dylib" \
  "@rpath/libinference_engine_llamacpp_backend.framework/libinference_engine_llamacpp_backend"
patch_dependency "${LEAP_BINARY}" "@rpath/libie_zip.dylib" \
  "@rpath/libie_zip.framework/libie_zip"

patch_dependency "${APP_FRAMEWORKS_DIR}/libinference_engine.framework/libinference_engine" \
  "@rpath/libinference_engine_llamacpp_backend.dylib" \
  "@rpath/libinference_engine_llamacpp_backend.framework/libinference_engine_llamacpp_backend"
patch_dependency "${APP_FRAMEWORKS_DIR}/libinference_engine.framework/libinference_engine" \
  "@rpath/inference_engine_llamacpp_backend.framework/inference_engine_llamacpp_backend" \
  "@rpath/libinference_engine_llamacpp_backend.framework/libinference_engine_llamacpp_backend"

/bin/rm -rf "${LEAP_NESTED_FRAMEWORKS}"

for framework in \
  "${APP_FRAMEWORKS_DIR}/libinference_engine_llamacpp_backend.framework" \
  "${APP_FRAMEWORKS_DIR}/libinference_engine.framework" \
  "${APP_FRAMEWORKS_DIR}/libie_zip.framework"
do
  if [ -d "${framework}" ]; then
    bundle_identifier="$(runtime_bundle_identifier "${framework}")"
    sign_framework "${framework}" "${bundle_identifier}"
  fi
done

sign_framework "${LEAP_FRAMEWORK}"
