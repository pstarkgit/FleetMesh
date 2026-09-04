# Fleet protocol v1

The fleet folder contains only:

```text
Device Sync/
├── fleet-manifest.json
└── machines/
    ├── <random-machine-id>.json
    └── ...
```

`fleet-manifest.json` is the desired baseline. The app seeds it once from the
first observed Mac when no manifest exists. Every later replacement is an
explicit in-app action.

Each machine owns exactly one snapshot file. Its stable ID is a random UUID
stored in local Application Support; it is not derived from a serial number,
hardware UUID, account, or hostname.

## Data classification

Allowed:

- human-readable machine name and local hostname
- Mac model identifier, architecture, macOS version/build
- product version, build, installed revision, and configuration fingerprint
- theme filenames and aggregate SHA-256 fingerprint
- whether a known source checkout has uncommitted work

Forbidden:

- serial number, platform UUID, provisioning UDID, MAC address
- username or absolute home/source paths
- raw settings, prompts, transcripts, databases, logs, or theme contents
- credentials, cookies, OAuth material, tokens, certificates, or Keychain data

All writes use atomic replacement. Readers validate `schemaVersion`, decode
each machine independently, and return per-file issues instead of treating a
partial read as an empty healthy fleet.

Component IDs have lifecycle semantics. Readers ignore retired IDs such as
`meshclaw-themes`; active replacements use new IDs (`kiro-crew` and
`kiro-crew-themes`) so historical evidence is never misrepresented as current
Kiro Crew state.
