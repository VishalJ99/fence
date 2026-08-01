#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
tab_root=${script_dir:h}
repo_root=${tab_root:h}
configuration=${TAB_CONFIGURATION:-Debug}
derived_data_path=${TAB_DERIVED_DATA_PATH:-${repo_root}/build/TabDerivedData}
output_dir=${tab_root}/dist
output_app=${output_dir}/Tab.app
signing_identity=${TAB_CODE_SIGN_IDENTITY:--}

/usr/bin/xcodebuild \
  -project "${tab_root}/Tab.xcodeproj" \
  -scheme Tab \
  -configuration "${configuration}" \
  -derivedDataPath "${derived_data_path}" \
  CODE_SIGNING_ALLOWED=NO \
  build

source_app=${derived_data_path}/Build/Products/${configuration}/Tab.app
if [[ ! -d ${source_app} ]]; then
  print -u2 "Expected build output was not found: ${source_app}"
  exit 1
fi

/bin/mkdir -p "${output_dir}"
if [[ -e ${output_app} ]]; then
  /bin/rm -rf "${output_app}"
fi
/usr/bin/ditto "${source_app}" "${output_app}"

codesign_args=(--force --sign "${signing_identity}" --entitlements "${tab_root}/Resources/Tab.entitlements")
if [[ ${signing_identity} != - ]]; then
  codesign_args+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${codesign_args[@]}" "${output_app}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${output_app}"

print "Built ${output_app}"
