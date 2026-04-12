## Furry Player

WIP

### Runtime master key

- Runtime entrypoints now support `FURRY_MASTER_KEY_HEX` for injecting a 32-byte master key as 64 hex characters.
- If this variable is absent, the project still falls back to the built-in development key for compatibility.
- Setting `FURRY_REQUIRE_MASTER_KEY=1` forces runtime entrypoints to reject the built-in fallback.
- Production deployments should always set `FURRY_MASTER_KEY_HEX` explicitly.
