# perf-replay — request-graph benchmarks against a real Jellyfin

The app can't run off a Mac, but most of what makes a screen slow to fill is
**which requests it sends, and in what order**. These scripts replay each
screen's request graph — the exact query shapes and the same parallel /
sequential structure as the Swift code — against a real Jellyfin server,
through a URLSession-like pool (6 keep-alive connections per host) with an
injected round-trip time (2 ms ≈ LAN, 60 ms ≈ remote server).

Each `scen_*.py` holds a `before` and an `after` graph, so a change is
measured, not assumed. Results of the 2026-10-14 pass are in the rules files
(`docs/rules/home.md`, `media-library.md`, `media-detail.md`).

```bash
export BENCH_DIR=/tmp/jf-bench          # media, config, token, user id
./setup-server.sh                        # docker: 800 films (20-actor NFOs), 25 series × 30 episodes, seeded user state
python3 endpoints.py                     # server time + gzip size of each app query
python3 scen_detail.py                   # fiche: movie / series / episode
python3 scen_library.py                  # library tab open + grid pagination
python3 scen_home.py                     # Home phase 1 (+ the rejected "split recently added" variant)
python3 scen_cold.py                     # cold launch (TCP + TLS per new connection) + snapshot size
```

Limits: it measures network + server time only — not SwiftUI rendering,
JSON decoding on the device, or image decoding. The library is synthetic
(generated artwork compresses differently from real posters), and the server
is one 10.11 container sharing the machine's CPU with the client.
