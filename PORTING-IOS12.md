# Porting Veteris to iOS 12 (arm64)

Status: **arm64 build works on CI; device runtime untested.** The shipped app is
32-bit; iOS 12 cannot run it at all. This document records the evidence, the
changes made in this tree, and the verification steps.

The current build ([run 42404479578](https://github.com/cagancallak-lab/veteris-12/actions/runs/42404479578))
produces a thin **arm64** executable and a `Veteris-v4.0.3.deb` with
`Depends: firmware (>= 12.0)`. The Cydia repository is published at
<https://cagancallak-lab.github.io/veteris-12/>.

## 1. Why a "port" is required

The 4.0.3 release (`com.victorlobe.veteris_4.0.3_iphoneos-arm.deb`, SHA-256
`abe71dac…ba9f7b`) contains `Applications/Veteris.app/Veteris`, a **thin
32-bit armv7 Mach-O**:

```
$ python tools/macho_info.py Veteris
thin cputype=12 (arm) subtype=9 (armv7) bits=32 filetype=2 ncmds=32 sizeofcmds=3896
```

`filetype=2` is `MH_EXECUTE`; there is no arm64 slice in the fat header (there
is no fat header). The built `Info.plist` also declares
`UIRequiredDeviceCapabilities = [armv7]`.

iOS 11 removed 32-bit app support and iOS 12 is 64-bit only, so the kernel
refuses to exec this binary. No Cydia tweak, AppSync version, or IPA patch can
change that: the fix is an **arm64 rebuild**, not a binary patch.

## 2. What this tree changes

| File | Change |
| --- | --- |
| `SConstruct` | `arch=armv7` or `arch=arm64` (default `armv7`), per-arch deployment target (`5.0` / `12.0`), iPhoneOS SDK auto-detected through `xcrun` when `SDKROOT` is not given, `-stdlib=libc++` (Xcode 10+ dropped libstdc++). |
| `Veteris/SConscript` | Static libraries are selected from `libs/<arch>/`; an arm64 build fails early with an actionable message when `libs/arm64/` is missing instead of silently linking armv7 objects. |
| `Veteris/Veteris-Info.plist` | Removed the `armv7` device requirement so the same plist works for either slice. |
| `Veteris/Clutch/ApplicationLister.m` | On arm64, `get_crackable_apps_list()` returns `nil`: Clutch's cracker rewrites `struct mach_header`/`LC_SEGMENT` (32-bit) and would misparse 64-bit binaries. |

The armv7 build is unchanged when no arguments are passed:

```
scons                 # same as before: armv7, iOS 5.0, libs/
scons arch=arm64      # iOS 12.0, libs/arm64/, xcbuild/Veteris
```

## 3. Remaining blockers

### 3.1 arm64 libcurl / OpenSSL (required before the linker will succeed)

`libs/libcurl.a`, `libs/libssl.a` and `libs/libcrypto.a` are armv7-only. The app
does not call OpenSSL directly; it only uses libcurl (BBHTTP) and the vendored
mbedTLS (YZArchiveTLSDownloader). Two options:

1. **Rebuild both for arm64** (matches current behaviour, keeps
   `CURLOPT_CAINFO_BLOB` certificate pinning). Sketch:

   ```sh
   SDK=$(xcrun --sdk iphoneos --show-sdk-path)
   MIN=12.0
   CROSS_TOP=$(xcode-select -p)/Platforms/iPhoneOS.platform/Developer
   CROSS_SDK=iPhoneOS.sdk

   # OpenSSL 1.1.1w
   ./Configure ios64-cross no-shared no-tests no-legacy --prefix="$PWD/out"
   make -j"$(sysctl -n hw.ncpu)" && make install_sw

   # curl 7.77.0 (matches the vendored headers in ./curl)
   CC="clang -arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN" \
   ./configure --host=arm-apple-darwin --with-ssl="$PWD/openssl-1.1.1w/out" \
       --disable-shared --enable-static --disable-ldap \
       --without-libidn2 --without-librtmp --with-zlib="$SDK/usr"
   make -j"$(sysctl -n hw.ncpu)"

   mkdir -p libs/arm64
   cp lib/.libs/libcurl.a libs/arm64/
   cp openssl-1.1.1w/out/lib/libssl.a openssl-1.1.1w/out/lib/libcrypto.a libs/arm64/
   ```

2. **Link the system libcurl** (`/usr/lib/libcurl.dylib`). Smaller, but iOS 12's
   libcurl predates `CURLOPT_CAINFO_BLOB`, so certificate pinning would have to
   fall back to `CURLOPT_CAINFO` (write the CA to a temp file) or be dropped.

### 3.2 VeterisHelper

`deb-stuff/control` hard-depends on `com.victorlobe.veterishelper`, a separate
binary package that is not in this repository. If it is a 32-bit daemon it will
not start on iOS 12 either. The app degrades gracefully without it: every
`CPDistributedMessagingCenter` call returns `nil`, `setBackgroundWorkActive:`
reports `keepAlive = NO`, and the queue falls back to normal iOS background
handling (`YZQueueReactor.m`). For an iOS 12 build, consider dropping the hard
`Depends:` or rebuilding the helper.

### 3.3 Clutch / Crack tab

Only `ApplicationLister` (installed-app listing) is arm64-safe. The cracker
itself (`Clutch/Binary.m`, `Clutch/Cracker.m`) is 32-bit Mach-O code. The guard
above makes the Crack tab empty on arm64; a real port of that feature is a
separate project (arm64 header parsing, code-signature stripping, arm64e).

### 3.4 Private API and entitlement review on iOS 12

- Installs use `LSApplicationWorkspace -installApplication:withOptions:error:`
  on iOS 8+; `MobileInstallationInstall` is only called below iOS 8, so it is
  dead code on iOS 12. AppSync Unified is still required.
- `AppSupport/CPDistributedMessagingCenter`, `MobileCoreServices/LSApplicationWorkspace`
  and the `com.apple.private.mobileinstall.allowedSPI` entitlement must be
  verified on a real iOS 12 device.
- `ent.xml` has no `platform-application` entitlement. That is how the current
  build ships and it works on iOS 5–7; whether iOS 12's `amfid`/sandbox accepts
  it for `/Applications` is a device-test question.

Link-time unknowns to watch on a modern SDK (fix only if the linker complains):

- `-framework MobileInstallation` needs `MobileInstallation.tbd` in the SDK's
  `PrivateFrameworks`. `MobileInstallationInstall` is only called in the
  `< 8.0` branch, so if the stub is gone, drop `-framework MobileInstallation`
  and the two `-Wl,-U,_MobileInstallation*` flags and resolve the symbol with
  `dlsym` (the pattern already used by `ApplicationLister`).
- `-framework AppSupport` needs `AppSupport.tbd`. If it is missing, the helper
  messaging in `YZQueueReactor` can be stubbed out; the app already tolerates a
  missing helper.

## 4. Building on macOS (Apple Silicon)

Target environment: macOS 15+, Xcode 16 (iOS 18 SDK). Xcode 12+ dropped armv7,
so this branch is **arm64 only**; keeping the iOS 5 slice needs Xcode 11.3 or
older and is out of scope. Xcode 16 still accepts
`-miphoneos-version-min=12.0` (see the
[Apple forum thread](https://developer.apple.com/forums/thread/777027)); if a
future Xcode raises the minimum, install Xcode 16 alongside it.

```sh
brew install scons ldid dpkg
chmod +x scripts/build-ios12.sh
./scripts/build-ios12.sh
```

The script:

1. checks Xcode, the iPhoneOS SDK, `scons`, `ldid` and `dpkg-deb`;
2. builds OpenSSL 1.1.1w and curl 7.77.0 for arm64 into `build/deps/prefix`
   (skipped when `SKIP_DEPS=1` or when the libs already exist);
3. copies `libssl.a`, `libcrypto.a`, `libcurl.a` into `libs/arm64/`;
4. runs `scons arch=arm64 min_version=12.0 app`, then `deb`;
5. prints `lipo -info`, the `LC_VERSION_MIN_IPHONEOS` value and the artifact
   paths.

Manual equivalent:

```sh
scons -j"$(sysctl -n hw.ncpu)" arch=arm64 min_version=12.0 app
```

`scons` with no target only links the unsigned `xcbuild/Veteris`; the `app`
alias copies the `ldid`-signed `xcbuild/Veteris.signed` into
`xcbuild/Veteris.app`. `scons deb` now also runs on macOS when `dpkg-deb` is
installed (the `deb` target is no longer Linux-only).

A fat binary that also keeps iOS 5 support would have to be linked twice and
`lipo`-ed; that requires an Xcode that can still target armv7:

```sh
scons arch=armv7 && cp xcbuild/Veteris /tmp/Veteris.armv7
scons arch=arm64 && cp xcbuild/Veteris /tmp/Veteris.arm64
lipo -create /tmp/Veteris.armv7 /tmp/Veteris.arm64 -output xcbuild/Veteris
ldid -SVeteris/ent.xml xcbuild/Veteris
```

`Veteris/ent.xml` is applied by `scons` after linking. `ldid` is looked up on
`PATH` first; the in-repo `ldid-2.1.5-amd64` is a Linux binary and must not be
used on macOS (`brew install ldid`).

## 5. Verification checklist (device)

1. `lipo -info Applications/Veteris.app/Veteris` → `arm64` (or `armv7 arm64`).
2. `otool -l … | grep -A3 LC_VERSION_MIN_IPHONEOS` → `12.0` for the arm64 slice.
3. Install the `.deb`, `uicache`, launch on iOS 12.x.
4. Browse catalog, open an app page, download an IPA, install it (AppSync
   installed), verify the queue and the Updates tab.
5. Confirm the Crack tab stays empty and does not crash.

## 6. What is verified here, and what is not

Verified:

- Upstream 4.0.3 is thin armv7 (Mach-O header parse + REA `open_binary`
  reporting `format=mach-o, architecture=arm`), so iOS 12 cannot run it.
- `scripts/build-ios12.sh` runs end-to-end on GitHub's `macos-15` runner
  (Xcode 16.4, iOS 18.5 SDK): OpenSSL 1.1.1w + curl 7.77.0 cross-built for
  arm64, app compiled, linked against the local private-framework stubs,
  signed with `ldid`, packaged with `dpkg-deb`.
- The produced `Veteris.app/Veteris` is a thin **arm64** 64-bit `MH_EXECUTE`
  (`cputype=16777228`, `bits=64`).
- The produced `.deb` control says `Depends: firmware (>= 12.0)` and
  `Version: 4.0.3`.
- The Cydia repository is live: `Packages` returns HTTP 200 and
  `debs/com.victorlobe.veteris_4.0.3_iphoneos-arm.deb` downloads with the
  advertised size.

**Not verified:** launching and using the app on an iOS 12 device (signing
acceptance, private frameworks at runtime, networking, IPA installation).
Those need the actual device; see the checklist above.
