# pterodactyl-resonite

Pterodactyl / Pelican egg & Docker image for Resonite maintained & used by Voxel Bone Cloud.

## Multiple instances

Set the **Instances** variable to a comma-separated list (e.g. `main,events`) to run several
headless instances in one server. Leave it empty for the original single-instance behaviour.

All instances share one Resonite install and one set of mods. Each instance gets:

- `Config/<name>.json`, created from `Config/Config.json` on first start if missing. Edit it to
  give each instance a unique session name and its own port(s).
- `Data/<name>` and `Cache/<name>` (passed as `-DataPath` / `-CachePath`)
- `Logs/<name>/` (the `-Logs` argument in the startup command is rewritten per instance)
- a `[name]` prefix on its console output

Add an extra allocation to the server for every additional port the instances need.

### Console commands

| Input                | Goes to                    |
| -------------------- | -------------------------- |
| `@events <command>`  | the `events` instance      |
| `@all <command>`     | every instance             |
| `shutdown` / `exit`  | every instance             |
| anything else        | the first instance listed  |

Set `INSTANCE_STAGGER` (seconds, default 5) in the environment to change the delay between instance starts.

### Watchdog (optional)

Set **Instance Watchdog Timeout** (`WATCHDOG_TIMEOUT`, seconds) to a value above 0 to start each
instance with `-Watchdog Watchdogs/<name>.txt`. If that file stops updating for longer than the
timeout while the process is still running, the instance is asked to `shutdown`, killed after 10
seconds if it doesn't stop, and started again. Other instances are not affected.

- `WATCHDOG_GRACE` (environment, default 300) is how many seconds after (re)start to wait before checking.
- Instances that exit on their own, or are stopped with `@name shutdown`, are not restarted.
- If the watchdog file is never written (e.g. the headless ignores the argument), the check is
  disabled for that instance with a log message instead of restarting in a loop.
- The Resonite wiki documents `-Watchdog` for the desktop client; confirm it is written by your
  headless build (watch the file's modification time) before relying on it.
