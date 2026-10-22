# hls_proxy_player_example

An **Android TV NAS player** that consumes the [`hls_proxy_player`](../) library.

It lets you watch your own NAS content on an Android TV **without a media server**: point it at
your NAS over FTP (or paste any `m3u8` URL) and it plays, with all AES-128 decryption and
segment merging happening locally on the device.

## Build

```bash
flutter pub get
# Android TV (armeabi-v7a, e.g. VIDAA / older TVs)
flutter build apk --target-platform android-arm --release --flavor tv
# Phone (arm64)
flutter build apk --target-platform android-arm64 --release --flavor phone
```

See the [root README](../README.md) for usage and architecture details.
