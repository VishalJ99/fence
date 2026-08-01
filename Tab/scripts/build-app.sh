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
signing_mode=${TAB_SIGNING_MODE:-adhoc}
development_team=${TAB_DEVELOPMENT_TEAM:-L5YX8CH3F5}

if [[ ${signing_mode} == development ]]; then
  /usr/bin/xcodebuild \
    -project "${tab_root}/Tab.xcodeproj" \
    -scheme Tab \
    -configuration "${configuration}" \
    -derivedDataPath "${derived_data_path}" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="${development_team}" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGNING_ALLOWED=YES \
    build
else
  /usr/bin/xcodebuild \
    -project "${tab_root}/Tab.xcodeproj" \
    -scheme Tab \
    -configuration "${configuration}" \
    -derivedDataPath "${derived_data_path}" \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

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

if [[ ${signing_mode} != development ]]; then
  codesign_args=(--force --sign "${signing_identity}" --entitlements "${tab_root}/Resources/Tab.entitlements")
  if [[ ${signing_identity} != - ]]; then
    codesign_args+=(--options runtime --timestamp)
  fi
  /usr/bin/codesign "${codesign_args[@]}" "${output_app}"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "${output_app}"

print "Built ${output_app}"
