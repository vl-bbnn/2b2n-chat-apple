# Local Overlay Configuration

This fork keeps Apple team IDs, bundle IDs, app groups and associated domains
out of tracked project files.

Tracked files:

- `Config/Overlay.defaults.xcconfig` contains non-private placeholder defaults.
- `Config/Overlay.xcconfig` includes defaults and then optionally includes
  `Config/Overlay.local.xcconfig`.
- `Config/Overlay.local.example.xcconfig` documents local values.
- `Config/Overlay.dev.xcconfig` is used by the `ElementX Dev` scheme and
  optionally includes `Config/Overlay.dev.local.xcconfig`.
- `Config/Overlay.dev.local.example.xcconfig` documents dev local values.

Ignored local files:

- `Config/Overlay.local.xcconfig`
- `Config/Overlay.dev.local.xcconfig`

Generate the local file from environment variables:

```sh
OVERLAY_BASE_BUNDLE_IDENTIFIER=dev.example.elementx \
OVERLAY_DEVELOPMENT_TEAM=ABCDE12345 \
OVERLAY_APPICON_NAME=AppIcon \
OVERLAY_CODE_SIGN_IDENTITY="Apple Development" \
OVERLAY_APS_ENVIRONMENT=development \
OVERLAY_APP_GROUP_IDENTIFIER=group.dev.example.elementx \
OVERLAY_ASSOCIATED_APPLINK_DOMAIN=example.com \
OVERLAY_ASSOCIATED_WEB_CREDENTIALS_DOMAIN=example.com \
scripts/render_overlay_local_xcconfig.sh
```

Then regenerate the Xcode project:

```sh
xcodegen
```

Required values for device signing:

- `OVERLAY_BASE_BUNDLE_IDENTIFIER`
- `OVERLAY_DEVELOPMENT_TEAM`

Useful optional values:

- `OVERLAY_APP_DISPLAY_NAME`
- `OVERLAY_PRODUCTION_APP_NAME`
- `OVERLAY_APPICON_NAME`
- `OVERLAY_CODE_SIGN_IDENTITY`
- `OVERLAY_PROVISIONING_PROFILE_SPECIFIER`
- `OVERLAY_APS_ENVIRONMENT`
- `OVERLAY_APP_GROUP_IDENTIFIER`
- `OVERLAY_CLASSIC_APP_GROUP_IDENTIFIER`
- `OVERLAY_CLASSIC_APP_KEYCHAIN_SERVICE_IDENTIFIER`
- `OVERLAY_CLASSIC_APP_KEYCHAIN_ACCESS_GROUP_IDENTIFIER`
- `OVERLAY_CLASSIC_APP_DEEP_LINK_URL`
- `OVERLAY_ASSOCIATED_APPLINK_DOMAIN`
- `OVERLAY_ASSOCIATED_WEB_CREDENTIALS_DOMAIN`

Apple Developer capabilities needed for device signing:

- Main app ID: Push Notifications, Associated Domains, App Groups, Keychain
  Sharing and Communication Notifications.
- Notification service extension app ID (`<base bundle id>.nse`): App Groups
  and Keychain Sharing.
- Share extension app ID (`<base bundle id>.shareextension`): App Groups and
  Keychain Sharing.

Do not commit `Config/Overlay.local.xcconfig`,
`Config/Overlay.dev.local.xcconfig` or real signing assets.
