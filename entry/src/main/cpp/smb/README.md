# SMB read-only native boundary

API: `listDirectory(options,path)`, `stat`, `openRead` → persistent session, `readAt(session,offset,length,requestId)`, `cancelRead`, `close`. Paths are share-relative; host/share/user/domain/password are separate runtime arguments. Only SMB2/3 via libsmb2 is used. No credentials are embedded in a media URL or native error text.

Native IO runs in NAPI worker tasks. A playback session owns a connected libsmb2 context and read-only file handle; its IO is serialized by a mutex. `readAt` accepts safe integer offsets and1..1MiB, uses real `smb2_pread` in ≤64KiB wire chunks, clamps at the real fstat size, and never reserves the full file size. EOF returns an empty buffer; failure rejects. Directory lists fail explicitly above10,000 entries rather than silently truncating. At most8 sessions/32 pending reads are admitted.

`cancelRead` sets an atomic flag. `close` removes/marks the session synchronously, then waits on a worker for any current bounded IO before closing the fd/context. Cancellation is observed between reads; an already-blocked SMB network call can take its configured8-second timeout. Contexts are never destroyed from another thread during IO. These limits are not a claim of instantaneous socket interruption or verified weak-network throughput.

ArkTS `SmbRangeBridge` creates a per-playback server bound only to127.0.0.1, ephemeral port, random192-bit token path, GET/HEAD and single byte Range. It admits2 clients, reads256KiB then awaits each socket write, supports offset seeks and suffix ranges, rejects malformed/multi/unsafe ranges, and closes/cancels late work by generation. Retained bridge payload is bounded to small chunks (roughly within2MiB including native→ArkTS copies); allocator/OS/SDK buffers and MPV's own cache are separate. There is no whole-file cache or predownload in this path.

`SmbAdapter.getPlaybackInfo` returns a loopback URL, explicit empty headers and a `release` callback. The owner must retain/release it after stopping native playback, including errors, switches and exit. Router parameters cannot carry functions; the main source-lease layer owns that handoff/TTL. No permanent global HTTP service or URL table is created here.

`SmbCatalog` returns real Folder/Video/File entries and true file size. It does not invent titles, episode indices, posters or remote favorites. Favorites/history are delegated to `DirectCatalogBase`/`LocalSourceState`. Recursive search is bounded to128 directories/5,000 playable files and fails with a visible message above that scope. Latest-film metadata is explicitly unsupported; browse the source directory. Symlinks/unknown native types are not followed.

Verification: `tests/validate-smb-direct.cjs` exercises actual ArkTS methods with controlled native/socket bindings. These checks do not prove SMB server authentication, decoder behavior, seek throughput or device acceptance. Build the native module through the integrated CMake/HAP target and validate with an isolated SMB service on the target device. Current execution scope is recorded in [VALIDATION](../../../../../docs/VALIDATION.md).

Bridge `readBytes` counts completed returned buffers, not SMB transport overhead or bytes discarded by a cancelled native call; it is not an exact network counter.

Dependency identity, source archive, LGPL text and build recipe: [vendor/libsmb2-6.2](../../../../../vendor/libsmb2-6.2/README.md).
