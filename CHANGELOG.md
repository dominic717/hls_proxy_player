# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-22

### Added
- **`hls_proxy_player` reusable Flutter library** — the self-contained kernel:
  - `local_proxy`: local HTTP proxy that exposes NAS/FTP content as a standard `m3u8`.
  - `merger`: downloads segments, decrypts AES-128 on the fly, concatenates to one clear stream.
  - `ftp_source`: minimal PASV FTP client + NAS directory parsing (`_map.txt`).
  - `http_fetch`: standard HTTP fetcher; accepts self-signed certs **only on private LAN ranges**.
  - `crypto_util` / `policy` / `priority` / `dbg`: AES-128-CBC helpers, tunable runtime policy, task priority queue, debug logging.
- **Example Android TV NAS player app** (`example/`): play any `m3u8` URL directly, or stream your own NAS (FTP) content **without a media server** (no Plex / Jellyfin / Emby). Includes settings page for NAS/FTP credentials, FTP library browser, and a TV-remote + touch compatible player UI.
- **Compliance by design**: no site scraping, no private-key extraction, no WAF/TLS-fingerprint bypass, no hard-coded credentials. All config lives in a local `local_config.json` that is never committed.
- `flutter analyze` is clean (0 issues) for both the library and the example app.

[1.0.0]: https://github.com/dominic717/hls_proxy_player/releases/tag/v1.0.0
