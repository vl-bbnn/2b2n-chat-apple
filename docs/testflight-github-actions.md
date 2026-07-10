# GitHub Actions TestFlight Setup

The `TestFlight` workflow builds the iOS app with overlay bundle IDs and uploads
the exported IPA to App Store Connect. Signing is automatic by default:
`xcodebuild` uses an App Store Connect API key with `-allowProvisioningUpdates`.
If automatic signing cannot create or reuse the required signing assets, the
workflow can optionally import a local certificate and provisioning profiles
from GitHub secrets.

## Apple Developer Setup

Create explicit identifiers:

- `BASE_BUNDLE_ID`
- `BASE_BUNDLE_ID.nse`
- `BASE_BUNDLE_ID.shareextension`

Enable these capabilities:

- Main app: Push Notifications, Associated Domains, App Groups, Keychain
  Sharing, Communication Notifications.
- NSE: App Groups, Keychain Sharing.
- Share Extension: App Groups, Keychain Sharing.

Create an App Store Connect app for `BASE_BUNDLE_ID`. It does not need to be
published to use TestFlight.

The workflow can create or refresh signing assets automatically, but the App IDs
and their capabilities must exist first.

## GitHub Variables

Run from the iOS repository:

```sh
gh variable set OVERLAY_APP_DISPLAY_NAME --body "Element X Dev"
gh variable set OVERLAY_PRODUCTION_APP_NAME --body "Element"
gh variable set OVERLAY_BASE_BUNDLE_IDENTIFIER --body "BASE_BUNDLE_ID"
gh variable set OVERLAY_DEVELOPMENT_TEAM --body "TEAMID1234"
gh variable set OVERLAY_CODE_SIGN_IDENTITY --body "Apple Distribution"
gh variable set OVERLAY_APS_ENVIRONMENT --body "production"
gh variable set OVERLAY_APP_GROUP_IDENTIFIER --body "group.BASE_BUNDLE_ID"
gh variable set OVERLAY_CLASSIC_APP_GROUP_IDENTIFIER --body "group.BASE_BUNDLE_ID.classic"
gh variable set OVERLAY_CLASSIC_APP_KEYCHAIN_SERVICE_IDENTIFIER --body "im.vector.app.encryption-manager-service"
gh variable set OVERLAY_CLASSIC_APP_KEYCHAIN_ACCESS_GROUP_IDENTIFIER --body "TEAMID1234.BASE_BUNDLE_ID.classic"
gh variable set OVERLAY_CLASSIC_APP_DEEP_LINK_URL --body "element://open"
gh variable set OVERLAY_ASSOCIATED_APPLINK_DOMAIN --body "example.com"
gh variable set OVERLAY_ASSOCIATED_WEB_CREDENTIALS_DOMAIN --body "example.com"
```

`BASE_BUNDLE_ID` is the real iOS bundle id, for example `org.example.chat`.
Do not reuse the Android-only application id here if it differs from the iOS
identifier configured in Apple Developer.

## GitHub Secrets

Create an App Store Connect API key with App Manager access, then set:

```sh
gh secret set APP_STORE_CONNECT_API_KEY_ID --body "KEYID12345"
gh secret set APP_STORE_CONNECT_ISSUER_ID --body "00000000-0000-0000-0000-000000000000"
gh secret set APP_STORE_CONNECT_API_KEY_P8 < AuthKey_KEYID12345.p8
```

## Optional Local Signing Assets

Use this only when App Store Connect automatic signing is not enough, for
example when CI cannot create another Apple Development certificate.

```sh
gh variable set ENABLE_LOCAL_SIGNING_ASSETS --body "true"

base64 -i Certificates.p12 | gh secret set BUILD_CERTIFICATE_BASE64
gh secret set P12_PASSWORD --body "p12-password"
gh secret set KEYCHAIN_PASSWORD --body "temporary-ci-keychain-password"

mkdir -p /tmp/elementx-profiles
cp /path/to/*.mobileprovision /tmp/elementx-profiles/
tar -czf /tmp/elementx-profiles.tar.gz -C /tmp/elementx-profiles .
base64 -i /tmp/elementx-profiles.tar.gz | gh secret set APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64
```

The archive should contain the profiles needed by:

- `BASE_BUNDLE_ID`
- `BASE_BUNDLE_ID.nse`
- `BASE_BUNDLE_ID.shareextension`

## Disable Local Signing Assets

If you return to pure automatic/cloud signing, remove the local signing override:

```sh
gh variable delete ENABLE_LOCAL_SIGNING_ASSETS || true
gh variable delete OVERLAY_MAIN_PROVISIONING_PROFILE_SPECIFIER || true
gh variable delete OVERLAY_NSE_PROVISIONING_PROFILE_SPECIFIER || true
gh variable delete OVERLAY_SHARE_EXTENSION_PROVISIONING_PROFILE_SPECIFIER || true
gh variable delete OVERLAY_PROVISIONING_PROFILE_SPECIFIER || true
gh variable delete TESTFLIGHT_SIGNING_STYLE || true

gh secret delete BUILD_CERTIFICATE_BASE64 || true
gh secret delete P12_PASSWORD || true
gh secret delete KEYCHAIN_PASSWORD || true
gh secret delete APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64 || true
```

## First Upload

Run the `TestFlight` workflow manually from GitHub Actions.

If upload succeeds but the build is not immediately testable, finish the
encryption/compliance prompts in App Store Connect. Publishing to the App Store
is not required for TestFlight.
