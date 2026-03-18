# Scheduler Patch — Technical Analysis

## Objective

Extend `fo_scheduler`'s host selection to support **per-agent-type host groups**
so that Kubernetes deployments can direct heavyweight agents (e.g. `nomos`,
`monk`) to high-CPU worker pods while routing lightweight agents (e.g.
`copyright`, `ojo`) to smaller pods. Today `get_host()` returns the next host
with free capacity from a single round-robin queue — it has no concept of agent
type.

---

## Relevant Source Files

All paths relative to `src/scheduler/agent/`:

| File          | Key Symbols                                                 | Role                                                                   |
| ------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------- |
| `host.h`      | `host_t` struct                                             | Defines host data: `name`, `address`, `agent_dir`, `max`, `running`    |
| `host.c`      | `host_init()`, `host_insert()`, `get_host()`                | Creates hosts from `[HOSTS]`, round-robin selection                    |
| `scheduler.h` | `scheduler_t` — `host_list` (GTree), `host_queue` (GList)   | Top-level state; hosts stored here                                     |
| `scheduler.c` | Config parser (~line 900), `scheduler_update()` (~line 506) | Parses `[HOSTS]`, calls `get_host()` during job dispatch               |
| `agent.c`     | `agent_create_thread()` (~line 726–780)                     | Forks + `execv(ssh, host->address, ...)` for remote hosts              |
| `job.h`       | `job_t` — `required_host`, `agent_type`                     | Job metadata; `required_host` already supports pinning to a named host |

---

## Current Host Selection Logic

### `host_t` struct (`host.h`)

```c
typedef struct {
  char* name;       // "fossology-workers-0"
  char* address;    // "fossology-workers-0.fossology-workers.fossology.svc.cluster.local"
  char* agent_dir;  // "/usr/local/etc/fossology"
  int   max;        // max concurrent agents
  int   running;    // current load
} host_t;
```

No field for agent affinity, labels, or group membership.

### `get_host()` (`host.c`, line 144)

```c
host_t* get_host(GList** queue, uint8_t num)
{
  GList*  curr = NULL;
  host_t* ret  = NULL;

  for (curr = *queue; curr != NULL; curr = curr->next) {
    ret = curr->data;
    if (ret->max - ret->running >= num)
      break;
  }
  if (curr == NULL) return NULL;

  // move selected host to end → round-robin
  *queue = g_list_remove(*queue, ret);
  *queue = g_list_append(*queue, ret);
  return ret;
}
```

**Key observation:** `get_host()` takes a `GList**` (the single global
`scheduler->host_queue`) and an integer slot count. It does not receive or
consider the agent type of the job being dispatched.

### `scheduler_update()` — dispatch loop (`scheduler.c`, ~line 506)

```c
// the generic case, this can run anywhere, find a place
else if ((host = get_host(&(scheduler->host_queue), 1)) == NULL)
{
  job = NULL;
  break;
}
```

Note: a `required_host` mechanism already exists (line ~488) for pinning a job
to a specific named host via `jq_host` in the DB. Our enhancement generalises
this from "pin to one host" to "pin to a group of hosts by agent type."

### Agent spawning (`agent.c`, ~line 765)

```c
args[0] = "/usr/bin/ssh";
args[1] = agent->host->address;
args[2] = buffer;  // AGENT_BINARY with flags
args[3] = agent->owner->jq_cmd_args;
args[4] = NULL;
execv(args[0], args);
```

This is the actual SSH dispatch. No changes needed here — the host already
carries the correct `address` by the time we reach this point.

---

## Proposed Changes

### 1. Extend `host_t` with a `tags` field (`host.h`)

```c
typedef struct {
  char* name;
  char* address;
  char* agent_dir;
  int   max;
  int   running;
  char** tags;      // NEW — NULL-terminated array of tag strings
  int    n_tags;    // NEW — number of tags
} host_t;
```

### 2. New config syntax in `fossology.conf`

Backward-compatible extension — the existing 3-field syntax still works:

```ini
[HOSTS]
; existing format (no tags → host goes in default group)
worker-0 = worker-0.dns.local /usr/local/etc/fossology 4

; new format — pipe-separated tag list after slot count
worker-heavy-0 = worker-heavy-0.dns.local /usr/local/etc/fossology 8 | nomos monk
worker-light-0 = worker-light-0.dns.local /usr/local/etc/fossology 4 | copyright ojo
```

### 3. Modify config parser (`scheduler.c`, ~line 910)

After `sscanf(tmp, "%s %s %d", addbuf, dirbuf, &max)`, check for a `|`
separator. If present, parse trailing tokens as tags and pass them to
`host_init()`.

### 4. Build per-tag host queues in `scheduler_t`

```c
// scheduler.h — add to scheduler_t:
GHashTable* host_queues;  // NEW — maps tag (char*) → GList* of host_t*
```

On startup, after `host_insert()`, also insert each host into every tag queue
it belongs to. Hosts with no tags go into a `"_default"` queue.

### 5. Extend `get_host()` signature

```c
// Option A — add a tag parameter:
host_t* get_host(GList** queue, uint8_t num);           // current
host_t* get_host_for(scheduler_t* s, const char* agent_type, uint8_t num); // new

// get_host_for() looks up the tag queue for agent_type.
// If no queue matches, falls back to the default queue.
// Internally still uses round-robin within the selected queue.
```

### 6. Update `scheduler_update()` dispatch call

```c
// Before:
else if ((host = get_host(&(scheduler->host_queue), 1)) == NULL)

// After:
else if ((host = get_host_for(scheduler, job->agent_type, 1)) == NULL)
```

### 7. Memory management

- `host_destroy()` must free `tags` array.
- `scheduler_destroy()` must free `host_queues` hash table.

---

## Backward Compatibility

- Existing `[HOSTS]` lines without `|` are parsed identically to today.
- Hosts with no tags enter the default queue, which is the fallback for any
  agent type not explicitly mapped. Behaviour is identical to current code when
  no tags are configured.
- The `required_host` pinning mechanism is unaffected (it bypasses `get_host()`
  entirely).

## Testing Strategy

1. **Unit tests** — extend `src/scheduler/agent_tests/` with:
   - Parse tagged and untagged `[HOSTS]` lines
   - `get_host_for()` returns host from correct tag queue
   - Fallback to default queue when tag has no dedicated hosts
2. **Integration** — smoke test on the kind cluster with two worker groups
   (`heavy`, `light`) and verify nomos runs only on heavy workers.

---

## References

- `src/scheduler/agent/host.h` — `host_t` struct definition
- `src/scheduler/agent/host.c` — `host_init()`, `get_host()`, `host_insert()`
- `src/scheduler/agent/scheduler.c` — config parsing (~line 900), `scheduler_update()` (~line 506)
- `src/scheduler/agent/agent.c` — SSH dispatch (`agent_create_thread()` ~line 726)
- `src/scheduler/agent/job.h` — `required_host` field (line 54)
