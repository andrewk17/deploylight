# Contributing to Deploylight

Pull requests are welcome. Run `swift test` before you open one.

## Signing and notarization

Release builds are code-signed and notarized so macOS opens them without a Gatekeeper warning. To build one you need:

- an Apple Developer account
- a Developer ID Application certificate installed
- an App Store Connect API key for notarization

Set up the API key once:

```bash
mkdir -p ~/.private_keys
# Download the .p8 file from https://appstoreconnect.apple.com/access/api
# and move it to ~/.private_keys/

# Add to ~/.zshrc:
export APPLE_API_KEY_ID="your-key-id"
export APPLE_API_ISSUER="your-issuer-id"
export APPLE_API_KEY_PATH="$HOME/.private_keys/AuthKey_XXXXXXXXXX.p8"
```

Then build:

```bash
./Scripts/package-app.sh
```

The script signs the app with your Developer ID certificate, submits it to Apple's notary service, staples the ticket and verifies the signature. Without notarization credentials it still signs the app and skips notarization.

## Screenshots

The menu and Preferences pictures in the README and on the website are drawn by the app's own code with example deployments, so they stay in step with the app. On a Mac with Google Chrome installed, regenerate them with:

```bash
./Scripts/render-site-art.sh
```

It writes to `docs/img`. It also writes `build/site-art/github-social-preview.png`, which is uploaded by hand under the repository's Settings → Social preview.

## Website

The landing page in `docs/` is served by a Cloudflare assets Worker at
[deploylight.andrewkim.me](https://deploylight.andrewkim.me/). The former
`deploylight.akim.workers.dev` address redirects permanently to the same path
and query on the custom domain.

For local checks, source this repo's personal `.env.cloudflare.local` before
using Wrangler and pass `--env-file .env.cloudflare.local` explicitly:

```bash
set -a && source .env.cloudflare.local && set +a
pnpm dlx wrangler@4.162.0 deploy --dry-run --env-file .env.cloudflare.local
pnpm dlx wrangler@4.162.0 dev --local --env-file .env.cloudflare.local
```

The old `vercel-deployment-menu-bar.vercel.app` redirect isn't configured in the
current repo or its retained branches. The deleted historical `vercel.json`
only configured static hosting. In the Vercel project that owns that domain,
change the permanent redirect's destination to `https://deploylight.andrewkim.me/`,
keeping its path and query forwarding. This is a separate dashboard change;
this repo's Worker cannot change it.
