# Pooling the Firecracker jail: investigated, measured, rejected (#328)

**Status.** The jail pool was designed, implemented, and measured. It cuts restore latency by a
reproducible ~1.6 ms and **loses ~9% throughput at the 64-slot operating point** (§8), so it is not
being merged. What ships from this work is the **phase split** (§2) — the instrument that localised
the cost to the jailer and then caught the regression.

This note is the record, kept so nobody re-runs it. §1-§4 describe the design as built and the
decisions behind it, in the past tense: **none of that code is in the tree.** The implementation is
preserved on `archive/328-jail-pool-regression` and in PR #332's history if it is ever revisited.

Everything below was measured on `srv-r16b14s16`, jailer v1.17.0, host otherwise idle.

## 1. The premise, re-measured

The handoff note reports that reusing a jail directory halves the pre-socket window (8275 us cold
against 4025/4008 us reused) from three sequential runs at one `--id`. Reuse does help, but not by
that much and not for the reason implied, and it does not work at all in the form described.

Four arms, n=20 each, **shuffled and interleaved**, timing jailer spawn to the API socket being a
socket, with the previous VMM reaped and the socket file deleted before every timed run:

| arm   | jail state                                          | median      | vs cold  |
| ----- | --------------------------------------------------- | ----------- | -------- |
| A     | cold, nothing exists                                | 4831 us     | —        |
| B     | `root/` + `root/run/` pre-created                   | 4685 us     | -3%      |
| **C** | **reuse, `dev/` wiped, `root/firecracker` kept**    | **3228 us** | **-33%** |
| D     | reuse, `dev/` wiped, `root/firecracker` deleted too | 4591 us     | -5%      |

### Correction 1 — `--id` reuse fails outright unless `root/dev/` is wiped

A second jailer run at the same `--id` against an intact jail exits non-zero:

```
Failed to create /dev/net/tun via mknod inside the jail: File exists (os error 17)
Error: MknodDev(Os { code: 17, ... }, "/dev/net/tun")
```

"The jailer reuses an existing jail directory" is only true after the device nodes are removed.
Wiping `dev/` is therefore a **correctness requirement** of the pool, not a hygiene choice, and the
four `mknod`s are re-paid on every reuse.

### Correction 2 — the note's 4025 us was very likely its own leftover socket

Reuse is worth -33%, not -50%, and the two reused attempts landing within 17 us of each other
(4025, 4008) is the signature of measuring something that was already present. Run 1's Firecracker
holds its API socket until killed, and a timer that waits for "the socket to be bound" is satisfied
instantly by it. This is precisely the failure `fcJailOccupied` exists to refuse, and its comment
already spells it out: `waitForUnixSocket` **dials**, so "a leaked VMM's live listener reads as this
restore's own socket coming up". Every arm above deletes the socket and reaps the VMM first.

### Correction 3 — our baseline is arm B, so the prize is -31%

`Restore` already `MkdirAll`s `jailRoot/run` and hardlinks six files in before the jailer starts, so
the jail directory always exists in production. Arm B measures that shape and it is within noise of
cold (-3%): **pre-creating the jail buys nothing**. The pool's real gain is C against B, 3228 us
against 4685 us, **-31%** of the pre-socket window.

### Correction 4 — the jailer re-copies the binary regardless; the saving is block allocation

C against D isolates the entire effect to `root/firecracker` (3.6 MiB). But the jailer does **not**
skip the copy on reuse — planting tampered content at that path and running again restored the
original md5 at the same inode, and a reused jail whose previous VMM still has it mapped fails with
`Text file busy`. So the jailer opens it for writing every single run, and what reuse avoids is
_allocating_ 3.6 MiB of fresh blocks, not the write.

Two consequences, and they point in opposite directions:

- **For isolation, this is good news**: a tenant's tampering of that file is destroyed by the next
  jailer run, unconditionally.
- **For the ceiling, this is bad news**: pooling _mitigates_ the copy rather than removing it. Only
  #328's option 2 (bypassing the jailer) eliminates it. Pooling is still the right next step — it is
  ~31% for a well-understood change with a proven precedent — but it should not be described as
  removing the per-VM exec-file cost.

## 2. Where the pre-socket time actually goes

`/proc/<pid>/comm` flips `jailer` -> `firecracker` at the jailed `execve`, and because the jailer
`execve`s rather than forking, `cmd.Process.Pid` is the same pid throughout. n=8, cold:

| boundary                        | median from spawn |
| ------------------------------- | ----------------- |
| jail directory appears          | 1.55 ms           |
| `firecracker.pid` appears       | 4.66 ms           |
| **`comm` flips -> firecracker** | **4.86 ms**       |
| API socket bound                | 5.23 ms           |

So **`jailer_setup` is 93% of the pre-socket window and `fc_bind` is 7%** (0.37 ms). That
independently corroborates #328's 82-85% strace split by a different method, and is the stronger
form of it: Firecracker binds in well under a millisecond.

It also settles the note's open question about which observable marks the boundary. `comm` is not a
proxy — it _is_ the `execve`. Of the two proxies the note floats, `firecracker.pid` is 0.20 ms early
(the jailer writes it just before `execve`) and the jail directory is useless at 1.55 ms, i.e. 68%
of the window too early.

## 3. The residue decision (settled, and NOT shipped — see §8)

The rest of this section and §4 describe the pool that was built and measured. They are kept because
anyone retrying this has to answer the same questions, and because two of the answers are security
findings that outlive the change. No `jailPool` exists in the tree.

**A pooled jail is a directory the previous VM had write access to.** The jail root is
`drwx------` owned by `--uid/--gid`, and every VM on the host runs as that same uid — but each VMM
is `pivot_root`ed into its own jail, so an idle jail is unreachable by another tenant. The exposure
is strictly _sequential_: what tenant N leaves behind, tenant N+1 inherits.

### 3.1 What the note asks, answered

**"Does the workspace/rootfs image live inside the jail?"** — Yes, and the note's own caveat applies:
`Restore` hardlinks `workspace.img` from the run's `WorkspaceDir` into `jailRoot`, and hardlinks the
five golden-snapshot components (`vmstate`, `memfile`, `kernel`, `rootfs`, `agent`) alongside it.
Tenant data is inside the jail, so the shell is not the only thing that matters.

This makes `workspace.img` a **must-delete**, for a reason beyond residue: `detachWorkspace`'s
comment already records that "the jail hardlink keeps it alive", and today `Destroy`'s
`os.RemoveAll(jailRoot)` is what drops that link. A pooled jail that retains it pins the previous
run's inode past the tombstone `RemoveAll`, which is a disk leak and quietly defeats the isolation
property that machinery exists to provide.

**"How is clean verified rather than assumed?"** — By a directory listing against an allowlist that
fails closed, exactly as `cgroupPool` refuses a cgroup with a live process in it. Anything
unrecognised means the jail is not reused: `RemoveAll` it and count a leak.

**"What must be removed, and what may persist?"**

| path                                                      | policy                            | why                                                                                                                                                                      |
| --------------------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `firecracker`                                             | **keep**, behind an `lstat` check | the whole -31%; see 3.2                                                                                                                                                  |
| `dev/` and its four nodes                                 | **delete**                        | not optional — jailer `EEXIST`s otherwise (correction 1)                                                                                                                 |
| `workspace.img`                                           | **delete**                        | tenant data, and keeping it pins the previous run's inode                                                                                                                |
| `vmstate`, `memfile`, `kernel`, `rootfs`, `agent`         | **delete**                        | `Restore` relinks these unconditionally; keeping them would risk a stale hardlink surviving a golden-snapshot rebuild, which fails _open_ into restoring an old snapshot |
| `run/`                                                    | keep the directory, empty it      | jailer creates it `0700`; the socket inside is residue                                                                                                                   |
| `firecracker.pid`, `vsock.sock`, `run/firecracker.socket` | **delete**                        | per-VM residue                                                                                                                                                           |
| anything else                                             | **refuse the jail**               | fail closed                                                                                                                                                              |

Deleting the six hardlinks rather than keeping them is deliberate: it leaves `Restore`'s prep path
completely unchanged, so the pool's blast radius is the jailer's work only. Prep is 0.62 ms and not
the target.

### 3.2 Why `firecracker` may persist, and what the check has to be

This is the only file allowed to survive a tenant, and it is an **executable the next tenant's
jailer opens as root, before it drops privileges**. Two attacks were tested rather than reasoned
about:

- **Symlink.** Replacing `root/firecracker` with a symlink to a file outside the jail would make the
  jailer's own write a root-privileged arbitrary-file-overwrite primitive. It is **not** exploitable:
  the jailer opens that path `O_NOFOLLOW`, so a planted symlink gives
  `Symbolic link loop (os error 40)`, the jailer exits, and the canary target was verified byte-for-byte
  intact. The pool inherits this for free.
- **Hardlink.** `O_NOFOLLOW` does not stop a hardlink, and the jail _contains hardlinks to the golden
  snapshot_ that our own prep put there. A compromised VMM could `link("/memfile", "/firecracker")`,
  and the next jailer run would then write 3.6 MiB of the Firecracker binary into the shared golden
  `memfile` — corrupting the snapshot every VM on the host restores from. This one is real and is why
  the check is not optional.

The check, run before a jail rejoins the free list, is a single `lstat`:

- `S_ISREG` — not a symlink (defence in depth behind `O_NOFOLLOW`), and not a FIFO, which the
  jailer's write would block on forever.
- **`st_nlink == 1`** — the load-bearing one; this is what the hardlink attack trips.
- `st_size` equal to the configured `FirecrackerBin`, and `st_uid` equal to `--uid`.

Content is deliberately _not_ hashed: the jailer overwrites it unconditionally (correction 4), so
content cannot survive, and hashing 3.6 MiB per restore would cost more than the 1.46 ms the whole
change saves. What must be guaranteed is the _inode's_ identity, not its bytes.

A jail failing any of these is removed and counted, never repaired in place — the same posture as
`cgroupPool.release`, and for the same reason: "cannot tell" is not "clean".

### 3.3 Release happens after `cmd.Wait`, not before

A reused jail fails with `Text file busy` while the previous VMM still has the exec file mapped, so
the jail may only be returned once `Destroy`'s `cmd.Wait` has reaped it. This mirrors the ordering
`cgroupPool` already needs and is not an extra constraint on the call sites.

## 4. Naming: a separate id namespace (as built; not shipped)

Reuse is keyed on `--id`, because that is what determines the chroot path
(`<chroot-base>/firecracker/<id>/root`). So pooling the jail means pooling the id — and VM ids must
stay monotonic. `cgroup.go`'s naming authority states why: a live VMM holding a jail id is what the
collision guard refuses on, and a reused name "would stop corresponding to VM `vm-3` and the two
namespaces would drift silently".

So the pool allocates its own `jail-<n>` namespace, handed to `--id`, while `vm-<n>` stays monotonic
and stays the VM's identity in logs, the sweep and the collision guard — the same split #319 made for
`pool-<n>`, for the same reason. `--id` is also Firecracker's instance identifier, which appears only
in its own log output; the launcher sends that to `io.Discard`.

One consequence to handle rather than inherit: a restarted worker mints `jail-0` again and may find a
leftover directory from a previous incarnation. The mint path therefore applies the same allowlist as
the pop path instead of trusting the directory, which also tightens today's behaviour — `Restore`
currently tolerates a pre-existing jail with a best-effort `os.Remove` of six known names and no
statement about anything else.

## 5. What was expected, and how it was checked

The saving is 1.46 ms of a 4.69 ms pre-socket window at low load, out of a restore whose pre-socket
portion is 72-85%. Order of magnitude, that is **~25% off a restore** — worth having, and smaller
than a reading of the handoff note alone would predict.

Two things get reported, because one number cannot stand for both (#328's own caution):

- **The floor**, at low load, where the 1.46 ms was measured.
- **The slope**, which nothing above addresses: `sockwait` runs 9.78 ms at c=8 rising to 22.31 ms at
  c=64. A change that halves the floor and leaves the slope untouched is still a win, but a different
  one, and the new `jailer_setup`/`fc_bind` split is what will say which half moved.

All figures above are out-of-harness, so they size the change rather than confirm it. The in-harness
numbers came from the phase split landing first, which is why it was task 1 and not task 3 — and
§7 then measured the component while §8 measured the throughput, which is where the two diverged.

## 6. Dead ends, kept so they are not re-run

Carried from #328 with its evidence, plus one of our own:

- **`--no-api` / `--config-file`** — the config schema is a fresh-boot config and a `snapshot` key is
  silently ignored. Snapshot restore is API-only in v1.17.0, and we need the API twice anyway
  (`PUT /snapshot/load`, then `PATCH /vm {state: Resumed}`, because standbys are left paused).
- **Telling the jailer to skip a `mknod`** — `jailer --help` on v1.17.0 exposes no device-node control;
  the four are hardcoded.
- **Skipping the jailer entirely** (#328 option 2) — deprioritised, not rejected, and correction 4
  raises its value: it is the only option that removes the 3.6 MiB copy rather than mitigating it.
  Revisit if pooling underdelivers.
- **Putting `ChrootBase` on tmpfs**, which would make the copy pure page cache — blocked by
  `checkDeviceSharing`: `Restore` hardlinks the golden snapshot and the workspace image into the jail,
  and `hardlink(2)` cannot cross devices, so the jail must share a filesystem with both.

Refs #328, #319, #307, #274. Supersedes the reuse figures in #328's third comment, and supersedes
its recommendation to pool the jail.

## 7. Measured in-harness: the saving is a fixed ~1.64 ms, not a percentage

Driven by `vmpoolctl` against the real launcher on `srv-r16b14s16`, comparing a binary built from
upstream `main` ("base") against this branch ("pool"). Arms are **interleaved and order-swapped per
rep**, so host drift lands on both equally, and caches are deliberately not dropped so both arms
share cache state. `sockwait_us` is the comparison field because it exists in both builds — which is
why §1's phase split kept it.

Significance is a 20,000-iteration permutation test on the median difference: the distributions are
heavy-tailed and overlap at the quartiles, so a median difference needs a test rather than an eye.

**Floor — one driver, n = 123 base / 126 pool over 3 interleaved reps:**

| field                   | base  | pool  | delta                | perm p |
| ----------------------- | ----- | ----- | -------------------- | ------ |
| `sockwait_us`           | 16680 | 15048 | **−1632 us (−9.8%)** | 0.0150 |
| restore `total_us`      | 19226 | 17445 | −1781 us (−9.3%)     | 0.0123 |
| `loadsnap_us` (control) | 2023  | 1994  | −28 us (−1.4%)       | 0.3161 |
| `prep_us` (control)     | 188   | 182   | −6 us (−2.9%)        | 0.3214 |

**Under load — 8 concurrent drivers, n = 425 / 430 over 2 interleaved reps:**

| field                   | base  | pool | delta                 | perm p |
| ----------------------- | ----- | ---- | --------------------- | ------ |
| `sockwait_us`           | 8413  | 6769 | **−1644 us (−19.5%)** | 0.0002 |
| restore `total_us`      | 11623 | 9861 | −1762 us (−15.2%)     | 0.0016 |
| `loadsnap_us` (control) | 2022  | 2035 | +13 us (+0.6%)        | 0.5311 |

### What this says

**The saving is a constant.** −1632 us at one driver, −1644 us at eight, and −1457 us out-of-harness
in §1: three independent measurements, agreeing within 12%, of a fixed per-restore cost removed. The
percentage differs only because the denominator does. So the honest headline is **~1.6 ms per
restore**, and any percentage quoted must name the load it was measured at.

**It moves the floor, not the slope.** That was the question §5 said one number could not answer, and
the answer is the less exciting of the two: the load-dependent component of `sockwait` is untouched.
Base's own curve reproduces #328's U-shape closely — 16.68 ms at one driver against that issue's
16.73 ms at c=1, and 8.41 ms at eight against its 9.78 ms at c=8 — so `sockwait` still minimises
near c=8 and still rises toward idle, with the pool's curve simply shifted down. Whatever causes the
rise at low load is not the chroot, and remains unexplained.

**The split holds in-harness.** `jailer_setup` is **93.7%** of `sockwait`; `fc_bind`'s median is
46 us. Firecracker is not the cost, measured now by the instrument rather than by strace.

**A bonus on the teardown side.** `removeall_us` — which now measures the release rather than an
`os.RemoveAll` — falls from 996 us to 308 us, −69%, while `wait_us` is unchanged at +0.7%. Not
counted in the headline, since it was not what the change was for.

Reuse rates were 93% (floor) and 89% (loaded); the misses are the initial mints for the standby
depth. `nr_dying_descendants` grew by 37 over ~850 VMs and no cgroups were left under the slice, so
pooling the jail did not reintroduce the accumulation #319 removed.

### Three limitations, stated rather than buried

1. **The loaded arm is 8 separate single-key drivers, not one pool serving 8 keys.** The Firecracker
   launcher sets `SerializesExecsPerRun = true`, so one workspace key structurally cannot produce
   concurrent restores. Each driver therefore needed its own `SH_CHROOT_BASE` _and_ its own
   `SH_PARENT_CGROUP` — the first because two jail pools would otherwise both mint `jail-0` into one
   directory, the second because one driver's startup orphan sweep would reclaim another's live VMs.
   It is a faithful proxy for concurrent restore pressure, not for one pool under eight keys.
2. **`fc_bind` is right-censored.** The boundary and the socket share one poll loop capped at 1 ms,
   so when both become visible in the same iteration `fc_bind` reads ~0. It is an upper bound on
   Firecracker's share and a lower bound on `jailer_setup`'s, which strengthens the conclusion rather
   than weakening it.
3. **The delegation that is easy to miss.** A per-driver parent cgroup needs `+memory` written to its
   `cgroup.subtree_control`, or `cgroupPool` creates `pool-<n>` directories with no `memory.max` to
   write and every restore fails `EPERM`. Both arms failed identically on the first attempt, which is
   the useful shape: a setup fault hits both, a regression hits one.

### The rig caught a bug no unit test could

Shipping this with `--id req.ID` while deriving `jailRoot` from the pooled id produced a silent,
expensive failure: the jailer built a **complete, working jail** at `vm-1` — device nodes, API
socket, pid file, exec copy, all present — while `waitForUnixSocket` watched `jail-0`, and the
restore died 5 s later as "API socket never appeared", pointing at Firecracker rather than at the id.
No unit test could see it because none spawns a real jailer. The fix extracted
`firecrackerJailerArgs` and `firecrackerJailRoot` so both the argv and the watched directory derive
from one id, and `TestJailerArgsCarryThePooledJailIdNotTheVMId` pins it.

## 8. Throughput: the pool is a ~9% REGRESSION at the operating point

§7 measured the component and got it right. It was still the wrong thing to conclude from, and this
section is the correction: **a faster restore did not make the pool faster.**

Measured with a throwaway driver built from identical source against each `internal/vmpool`, driving
one workspace key per concurrent slot (the launcher sets `SerializesExecsPerRun = true`, so one key
cannot produce concurrent Execs). Arms interleaved and order-swapped per rep.

| slots  | base Exec/s (per rep) | pool Exec/s (per rep) | median delta |
| ------ | --------------------- | --------------------- | ------------ |
| **64** | 559.5 / 556.5 / 552.3 | 522.0 / 497.1 / 505.1 | **−9.24%**   |
| 8      | 115.4 / 114.9 / 112.8 | 117.6 / 115.2 / 115.7 | +0.70%       |

The 64-slot reps do not overlap, so this is not noise. At 8 slots the two arms are indistinguishable.

### The mechanism: elided writes become real ones

Instrumented re-run at 64 slots, `/proc/diskstats` and `/proc/stat` deltas across the timed window:

| arm  | Exec/s        | bytes written to disk per Exec | host CPU      |
| ---- | ------------- | ------------------------------ | ------------- |
| base | 534.1 / 549.0 | 0.16 / 0.12 MiB                | 42.9% / 42.0% |
| pool | 507.8 / 499.1 | 0.29 / 0.30 MiB                | 47.2% / 47.9% |

**The pool writes ~2.1x more to disk and burns ~12% more CPU.** The cause is correction 4 turned
around: the jailer rewrites the 3.6 MiB exec copy on every run either way, but

- **base creates a fresh file and `Destroy` unlinks it ~30 ms later**, so most of those dirty pages
  are dropped before writeback ever reaches them. Only 0.12-0.16 MiB per Exec survives to disk.
- **the pool keeps the file and the jailer overwrites it in place**, which cannot be elided. The
  dirty pages belong to a file that still exists, so writeback has to do them.

Not creating a file you are about to delete is cheaper than reusing one. The pool's whole saving was
keeping that file, so the saving and the cost are the same decision, and at a sustained 550
restores/s the cost is larger.

### Why the component measurement could not see this

A per-restore latency measurement times the restore's own clock. Avoided block allocation lands on
that clock, which is why §1 and §7 both measured it cleanly and consistently at ~1.6 ms. Writeback
does not: it is asynchronous, done by kernel threads, charged to nobody's restore, and only becomes
visible as a _rate_ under sustained load. So the instrument was correct and the inference from it was
wrong, in a way no amount of care with the same instrument would have caught.

This is the second time in this issue that a latency measurement pointed the wrong way — the first
was #328's own `sockwait` attribution. The lesson is the same both times: **a component measurement
is not a throughput claim**, and on this change the two have opposite signs.

### Recommendation

**Do not merge the jail pool.** It is a measured regression at the operating point, the mechanism is
understood, and there is no cheap fix:

- Keeping the jail but deleting the exec copy (§1 arm D) is not a fallback: it was −94 us, i.e. noise.
  The binary was the only thing worth pooling and the binary is what costs the throughput.
- Putting `ChrootBase` on tmpfs would make the write cheap, but `checkDeviceSharing` forbids it: the
  golden snapshot and the workspace image are hardlinked into the jail and `hardlink(2)` cannot cross
  devices.
- Hardlinking the jail's exec copy to the real binary would have the jailer write _through_ it into
  `/usr/local/bin/firecracker`, which is the attack `verifyExec` exists to refuse.

**Do merge the phase split**, which is what this PR now contains. It is independently correct, it is
what localised the cost to the jailer in the first place, and it is what caught this. `jailer_setup`
at 93.7% of `sockwait` stands.

**#328's remaining lever is option 2, and this strengthens the case for it.** Bypassing the jailer
avoids the 3.6 MiB copy outright rather than relocating it, so it removes both the allocation _and_
the writeback. Pooling could only ever move that cost around, which is exactly what it did.
