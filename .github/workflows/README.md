# GitHub Actions Secrets (macOS Signing + Notarization)

This repo uses GitHub Actions to archive, sign, and notarize the app. Set the following secrets in
`Settings -> Secrets and variables -> Actions`.

## 1) Developer ID Application certificate (.p12)

Create/export a **Developer ID Application** certificate from your keychain, then base64 it.

```bash
# Export your Developer ID Application certificate to a .p12 first.
base64 -i /path/to/DeveloperIDApplication.p12 | pbcopy
```

Create secrets:

- `MACOS_CERTIFICATE_P12_BASE64`: base64 output of the .p12
- `MACOS_CERTIFICATE_PASSWORD`: password used when exporting the .p12

Note: For GitHub releases (outside the Mac App Store), you want a **Developer ID Application**
certificate. Apple Distribution is for the Mac App Store.

## 2) App Store Connect API key (notarytool)

Create the API key in App Store Connect:

1. App Store Connect -> Users and Access -> Keys -> "+"
2. Choose a name and role (Developer is sufficient for notarization)
3. Download the `.p8` file and note the **Key ID** and **Issuer ID**

Create secrets:

- `APPSTORE_CONNECT_API_KEY_ID`: the Key ID (10 characters)
- `APPSTORE_CONNECT_API_ISSUER_ID`: the Issuer ID (UUID)
- `APPSTORE_CONNECT_API_PRIVATE_KEY`: contents of the `.p8` file

```bash
cat /path/to/AuthKey_XXXXXXXXXX.p8 | pbcopy
```
