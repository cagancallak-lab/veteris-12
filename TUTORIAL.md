# Veteris for iOS 12 — build and install tutorial

This repository is a port of [victorlobe/Veteris](https://github.com/victorlobe/Veteris)
to **arm64 / iOS 12**. The upstream 4.0.3 binary is 32-bit armv7 only, so iOS 12
cannot launch it; everything here rebuilds the app for arm64.

Everything runs from Windows: you push the repo, GitHub Actions builds on a
macOS runner, and you install the result on the device through Cydia.

---

## 0. What you need

- A GitHub account and this repository (`cagancallak-lab/veteris-12`).
- Git for Windows (already used below).
- A jailbroken iOS 12 device with Cydia or Sileo.
- [AppSync Unified](https://cydia.akemi.ai/) on the device (needed to install
  downloaded IPAs).
- No Mac required — the build runs on a GitHub-hosted `macos-14` runner.

---

## 1. Push the port to GitHub (Windows)

The working tree in `veteris-src` already has `origin` pointing at your repo and
a `main` branch with the port commits.

```powershell
cd C:\Users\HP\Documents\deepseek-harness\default-workspace\veteris-src
git push -u origin main
```

Git Credential Manager opens a browser window the first time; sign in to
`cagancallak-lab`.

If push fails with `schannel: AcquireCredentialsHandle failed`, use the OpenSSL
backend for this one command:

```powershell
git -c http.sslBackend=openssl push -u origin main
```

A push to `main` starts the `ios12-arm64` workflow automatically.

---

## 2. Build the .deb

1. Open <https://github.com/cagancallak-lab/veteris-12/actions>.
2. Select **ios12-arm64** → **Run workflow** if it did not start by itself.
3. The first run takes roughly 20–40 minutes: it downloads and cross-builds
   OpenSSL 1.1.1w and curl 7.77.0 for arm64, then compiles Veteris.
4. When the run is green, open it and download the **veteris-ios12-arm64**
   artifact. It contains:
   - `Veteris-v4.0.3.deb` — install this on the device;
   - `Veteris.app` — the raw bundle, if you prefer `scp`.

The workflow also produces a Cydia repository (`repo/`) and publishes it to the
`gh-pages` branch.

---

## 3. Turn on the Cydia repository (GitHub Pages)

Do this once, after the first successful build (the `gh-pages` branch only
exists then):

1. Repository **Settings → Pages**.
2. **Build and deployment → Source: Deploy from a branch**.
3. Branch: **gh-pages**, folder: **/ (root)** → **Save**.
4. Wait 1–2 minutes, then check:

   <https://cagancallak-lab.github.io/veteris-12/>

   You should see the landing page, and
   <https://cagancallak-lab.github.io/veteris-12/Packages> should list
   `Package: com.victorlobe.veteris`.

---

## 4. Install with Cydia

1. Open Cydia → **Sources** → **Edit** → **Add**.
2. Enter:

   ```
   https://cagancallak-lab.github.io/veteris-12/
   ```

3. Add the source and refresh.
4. Search for **Veteris** → **Install** → **Confirm**.
5. Respring when Cydia asks.

### Alternative: install the .deb directly

- **Filza**: copy `Veteris-v4.0.3.deb` to the device, tap it, choose **Install**.
- **SSH / NewTerm**:

  ```sh
  dpkg -i Veteris-v4.0.3.deb
  uicache -a
  killall SpringBoard
  ```

---

## 5. First run checklist

1. Launch **Veteris**.
2. Open a category and an app page — the catalog should load over HTTPS.
3. Download an IPA and let it install; approve any prompt.
4. If installation fails, confirm **AppSync Unified** is installed.
5. The **Crack** tab is intentionally empty on arm64: Clutch's cracker only
   understands 32-bit Mach-O binaries.

Background downloads use iOS background tasks; the old helper daemon
(`com.victorlobe.veterishelper`) is no longer a dependency and is not required.

---

## 6. What was optimized for iOS 12

- **arm64 rebuild** with `-miphoneos-version-min=12.0` (the only way to run at
  all on iOS 12).
- **Release build**: `FINALPACKAGE=1` removes download-debug logging and debug
  strings; `-O3` comes from the existing SConstruct release flags.
- **Dependencies rebuilt for arm64**: OpenSSL 1.1.1w + curl 7.77.0 (the
  in-repo `libs/*.a` are armv7-only), vendored mbedTLS/KSCrash/nanopb compiled
  for arm64.
- **Helper dependency removed** from `deb-stuff/control` (`firmware (>= 12.0)`
  only) so Cydia does not try to install a 32-bit daemon package.
- **Clutch crack engine disabled** on arm64 (it rewrites 32-bit `mach_header`
  and `LC_SEGMENT` structures).
- **`-stdlib=libc++`** (Xcode 10+ no longer ships libstdc++).

Details, evidence and remaining device-test risks: [PORTING-IOS12.md](PORTING-IOS12.md).

---

## 7. Troubleshooting

**The workflow fails while building OpenSSL or curl.**
Open the failing step. This is the most likely first-run failure; the exact
error text is enough to fix it. Common causes: the runner's Xcode min deployment
target, or `--with-zlib` not finding the SDK's zlib.

**The workflow fails at link time.**
A modern SDK may not ship `MobileInstallation.tbd` or `AppSupport.tbd` in
`PrivateFrameworks`. The fallback (drop the `-framework` flag and resolve the
symbol with `dlsym`) is described in PORTING-IOS12.md §3.4.

**Cydia says "Did not find repository".**
Pages is not enabled yet, the branch is not `gh-pages`, or the URL is missing a
trailing slash.

**The app installs but does not launch.**
Check the crash log in `/var/mobile/Library/Logs/CrashReporter/` or run
`idevicesyslog`. Most likely causes: signing/entitlements on iOS 12, or a
missing private framework at runtime.

**IPAs download but fail to install.**
Install AppSync Unified from <https://cydia.akemi.ai/>, then retry.

---

## 8. Rebuilding later

Push any change to `main`, or run the workflow manually. Dependency builds are
cached by the workflow (key: OpenSSL 1.1.1w / curl 7.77.0), so later runs take
only a few minutes.
