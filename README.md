## Furry Player

WIP

### Runtime master key

- Runtime entrypoints now support `FURRY_MASTER_KEY_HEX` for injecting a 32-byte master key as 64 hex characters.
- If this variable is absent, the project still falls back to the built-in development key for compatibility.
- Production deployments should always set `FURRY_MASTER_KEY_HEX` explicitly.
