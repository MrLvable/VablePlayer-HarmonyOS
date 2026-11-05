# libsmb2 6.2 · arm64 dependency

Only `arm64-v8a/libsmb2.so` is imported into this app. The old wrapper HAR and its `libc++_shared.so` are **not** added as app dependencies; the app keeps its existing native C++ runtime.

| Material | Identity |
|---|---|
| Original public release | [isaced/libsmb2-ohos v0.2.0](https://github.com/isaced/libsmb2-ohos/releases/tag/v0.2.0) |
| Wrapper release commit | `2b9404dab3906e23323077988157bf4808b805a3` |
| Original HAR | 1,165,539 bytes; SHA256 `cf8a36ec323867e39cff0968b48d45917ca98a507506dad2f067b206a0ee5d83` (research workspace only) |
| Imported libsmb2.so | 266,800 bytes; SHA256 `02b042413c0dd13c724046068b714e31d9cf60463c157b4b0a0745bdac68e212` |
| Upstream source tag | [sahlberg/libsmb2 libsmb2-6.2](https://github.com/sahlberg/libsmb2/tree/libsmb2-6.2) |
| Included upstream source archive | [sources/libsmb2-6.2.tar.gz](sources/libsmb2-6.2.tar.gz), 259,518 bytes; SHA256 `8e1f9efc6b2e0f6546f0fe121ac0ddf4fc2f0908ae5a6bd1f185be7c9e0bcbb3` |

The dependency is LGPL-2.1-or-later: retain [COPYING](COPYING) and [full LGPL 2.1](LICENCE-LGPL-2.1.txt), the included source, original attribution and build material. Internal components/examples have the notices retained in the source archive. This statement covers the dependency; it is not a claim that every transitive binary or publication requirement has already been audited.

`build/HPKBUILD` pins upstream6.2 and uses the OpenHarmony Lycium CMake toolchain. The release build copies `libsmb2.so.1` as `libsmb2.so`, using `build/patch-soname.py` to normalize SONAME for Harmony packaging. `build/build-native.sh` is the original wrapper build recipe, kept as provenance; it expects the wrapper repository/Lycium layout. The bundled headers/recipe were compared against the release tag. [File manifest](SOURCE-BINARY-MANIFEST.json) records downloaded material, not the app's generated `libnas_smb.so`.

The app's separate read-only NAPI module lives in `entry/src/main/cpp/smb`, links dynamically to this library, and does not reuse the released wrapper's whole-file `readFile` implementation. To rebuild this native dependency, unpack the included source and apply the pinned HPKBUILD/SONAME recipe using a compatible Harmony SDK; rebuild the app NAPI module through its CMake target. Native rebuild/toolchain reproducibility and changed-library relinking should be rechecked for distribution; no device testing was performed while the user paused their phone.
