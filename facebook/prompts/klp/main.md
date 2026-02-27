# Kernel Live Patching (KLP)

KLP patches running kernels without rebooting. It uses ftrace to redirect
function calls at runtime. Patches are delivered as kernel modules.

## How It Works

1. A livepatch module defines replacement functions via `struct klp_func`
2. On `klp_enable_patch()`, KLP registers ftrace handlers on target functions
3. The consistency model transitions tasks one-by-one from old to new code
4. Tasks switch when returning to userspace, during context switches, or
   when their stack is clean of patched functions

## Key Locations

| What | Where |
|------|-------|
| Core subsystem | `kernel/livepatch/` (core.c, patch.c, transition.c, shadow.c, state.c) |
| Public API | `include/linux/livepatch.h` |
| Module loader integration | `kernel/module/livepatch.c` |
| Meta build pipeline | `facebook/bzl/klp.bzl` |
| RPM spec | `facebook/build/klp.spec` |
| Upstream docs | `Documentation/livepatch/` |
| Selftests | `tools/testing/selftests/livepatch/` |
| Sample modules | `samples/livepatch/` |

## Sysfs Interface

```
/sys/kernel/livepatch/<patch>/
  enabled      (RW)  0/1 to disable/re-enable
  transition   (RO)  1 during active transition
  force        (WO)  write 1 to force (DANGEROUS: permanently disables rmmod)
  replace      (RO)  1 if atomic replace
  stack_order  (RO)  stacking order
```

## Kconfig

`LIVEPATCH` requires: `DYNAMIC_FTRACE_WITH_REGS` or `DYNAMIC_FTRACE_WITH_ARGS`,
`MODULES`, `SYSFS`, `KALLSYMS_ALL`, `HAVE_LIVEPATCH` (x86_64, powerpc, s390),
`!TRIM_UNUSED_KSYMS`.

## Common Gotchas

- Cannot patch inlined or `__init` functions
- Transition stalls if patched function is on any task's stack
- `force` permanently disables module unload
- Duplicate symbol names require correct `old_sympos`
- LTO/PGO builds need profile data for reproducible kpatch-build output

## Detail Files

Load these from `facebook/prompts/klp/` as needed:

- `architecture.md` -- KLP internals, consistency model, ftrace handler, data structures
- `meta-build.md` -- Meta build pipeline, Buck2, kpatch-build, RPM packaging
- `patch-authoring-guide.md` -- kpatch-build pitfalls, data structure workarounds, jump labels, sibling calls, symbol versioning
- `rewriting-patches.md` -- Tricks for rewriting upstream patches to be livepatch-compatible
