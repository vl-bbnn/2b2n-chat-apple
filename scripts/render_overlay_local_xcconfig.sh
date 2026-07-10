#!/bin/sh

set -eu

config_path="Config/Overlay.local.xcconfig"

setting() {
    name="$1"
    fallback="${2:-}"
    value="$(printenv "$name" || true)"
    if [ -z "$value" ] && [ -f "$config_path" ]; then
        value="$(sed -n "s/^${name}[[:space:]]*=[[:space:]]*//p" "$config_path" | tail -n 1)"
    fi
    if [ -z "$value" ]; then
        value="$fallback"
    fi
    printf '%s\n' "$value"
}

base_bundle_identifier="$(setting OVERLAY_BASE_BUNDLE_IDENTIFIER)"
development_team="$(setting OVERLAY_DEVELOPMENT_TEAM)"

if [ -z "$base_bundle_identifier" ] || [ -z "$development_team" ]; then
    echo "Skipping overlay local config: OVERLAY_BASE_BUNDLE_IDENTIFIER and OVERLAY_DEVELOPMENT_TEAM are required." >&2
    exit 0
fi

app_display_name="$(setting OVERLAY_APP_DISPLAY_NAME "Element X Dev")"
production_app_name="$(setting OVERLAY_PRODUCTION_APP_NAME "Element")"
appicon_name="$(setting OVERLAY_APPICON_NAME "AppIcon")"
provisioning_profile_specifier="$(setting OVERLAY_PROVISIONING_PROFILE_SPECIFIER)"
aps_environment="$(setting OVERLAY_APS_ENVIRONMENT "development")"
app_group_identifier="$(setting OVERLAY_APP_GROUP_IDENTIFIER "group.${base_bundle_identifier}")"
classic_app_group_identifier="$(setting OVERLAY_CLASSIC_APP_GROUP_IDENTIFIER "group.${base_bundle_identifier}.classic")"
classic_app_keychain_service_identifier="$(setting OVERLAY_CLASSIC_APP_KEYCHAIN_SERVICE_IDENTIFIER "im.vector.app.encryption-manager-service")"
classic_app_keychain_access_group_identifier="$(setting OVERLAY_CLASSIC_APP_KEYCHAIN_ACCESS_GROUP_IDENTIFIER "\$(OVERLAY_DEVELOPMENT_TEAM).${base_bundle_identifier}.classic")"
classic_app_deep_link_url="$(setting OVERLAY_CLASSIC_APP_DEEP_LINK_URL "element://open")"
associated_applink_domain="$(setting OVERLAY_ASSOCIATED_APPLINK_DOMAIN "example.com")"
associated_web_credentials_domain="$(setting OVERLAY_ASSOCIATED_WEB_CREDENTIALS_DOMAIN "$associated_applink_domain")"

mkdir -p "$(dirname "$config_path")"

cat > "$config_path" <<EOF
OVERLAY_APP_DISPLAY_NAME = $app_display_name
OVERLAY_PRODUCTION_APP_NAME = $production_app_name
OVERLAY_APPICON_NAME = $appicon_name
OVERLAY_BASE_BUNDLE_IDENTIFIER = $base_bundle_identifier
OVERLAY_DEVELOPMENT_TEAM = $development_team
OVERLAY_PROVISIONING_PROFILE_SPECIFIER = $provisioning_profile_specifier
OVERLAY_APS_ENVIRONMENT = $aps_environment
OVERLAY_APP_GROUP_IDENTIFIER = $app_group_identifier
OVERLAY_CLASSIC_APP_GROUP_IDENTIFIER = $classic_app_group_identifier
OVERLAY_CLASSIC_APP_KEYCHAIN_SERVICE_IDENTIFIER = $classic_app_keychain_service_identifier
OVERLAY_CLASSIC_APP_KEYCHAIN_ACCESS_GROUP_IDENTIFIER = $classic_app_keychain_access_group_identifier
OVERLAY_CLASSIC_APP_DEEP_LINK_URL = $classic_app_deep_link_url
OVERLAY_ASSOCIATED_APPLINK_DOMAIN = $associated_applink_domain
OVERLAY_ASSOCIATED_WEB_CREDENTIALS_DOMAIN = $associated_web_credentials_domain
EOF
