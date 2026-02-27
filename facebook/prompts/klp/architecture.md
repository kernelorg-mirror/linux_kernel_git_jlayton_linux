# KLP Architecture

## Core Files

| File | Purpose |
|------|---------|
| `kernel/livepatch/core.c` | Main entry: `klp_enable_patch()`, sysfs, symbol resolution via kallsyms, module coming/going hooks, NOP management for atomic replace |
| `kernel/livepatch/patch.c` | ftrace integration: `klp_ftrace_handler()`, `klp_ops` / `func_stack` management |
| `kernel/livepatch/transition.c` | Consistency model: per-task transitions, stack checking, scheduler hooks, fake signals |
| `kernel/livepatch/shadow.c` | Shadow variables: RCU-protected hash table (4096 buckets) for attaching data to existing objects |
| `kernel/livepatch/state.c` | System state tracking: version compatibility between cumulative patches |
| `include/linux/livepatch.h` | Public API: all structs and exported functions |
| `include/linux/livepatch_sched.h` | Scheduler hook: `klp_sched_try_switch()` guarded by static key |
| `kernel/module/livepatch.c` | Module loader: ELF preservation, `.klp.rela.*` relocations, `MODULE_INFO(livepatch, "Y")` check |

## Key Data Structures

```c
struct klp_func {
    const char *old_name;       // function to patch
    void *new_func;             // replacement function
    unsigned long old_sympos;   // disambiguate duplicate symbols (0 = unique)
    // internal: old_func, kobj, node, stack_node, old_size, new_size, nop, patched, transition
};

struct klp_object {
    const char *name;           // module name, or NULL for vmlinux
    struct klp_func *funcs;     // NULL-terminated array of functions to patch
    struct klp_callbacks callbacks;  // pre/post patch/unpatch hooks
};

struct klp_patch {
    struct module *mod;         // the livepatch module itself
    struct klp_object *objs;    // NULL-terminated array of objects
    struct klp_state *states;   // system state tracking (optional)
    bool replace;               // true = atomic replace (supersede all prior patches)
};
```

## Consistency Model

KLP uses a hybrid model (kGraft per-task + kpatch stack-trace). During a
transition, each task individually switches from old to new code:

1. **Returning to userspace** -- `klp_update_patch_state()` in idle/return path
2. **Stack checking** -- sleeping tasks checked via `stack_trace_save_tsk_reliable()`; transition occurs if no patched functions on stack
3. **Scheduler hook** -- CPU-bound kthreads transition during context switches via `klp_sched_try_switch()` (static key `klp_sched_try_switch_key`, only active during transitions)
4. **fork()** -- children inherit parent's `TIF_PATCH_PENDING` and `patch_state` via `klp_copy_process()`
5. **Fake signals** -- sent every 15 seconds (`SIGNALS_TIMEOUT`) to stuck tasks
6. **Force** -- admin writes 1 to `/sys/kernel/livepatch/<patch>/force` (permanently disables rmmod)

## ftrace Handler Flow (`klp_ftrace_handler` in patch.c)

```
1. Get klp_ops from ftrace_ops via container_of
2. Read top func from ops->func_stack (RCU-protected)
3. If func->transition:
   a. Read current->patch_state
   b. If UNPATCHED: walk to previous func on stack (or return to original)
   c. If PATCHED: use this func
4. If func->nop: return (use original code)
5. Otherwise: set instruction pointer to func->new_func
```

Each patched function gets an `ftrace_ops` with flags:
- `FTRACE_OPS_FL_DYNAMIC` -- dynamically allocated
- `FTRACE_OPS_FL_IPMODIFY` -- modifies instruction pointer (conflicts with kretprobes)
- `FTRACE_OPS_FL_PERMANENT` -- cannot be unregistered while any task may use it

## Atomic Replace

When `patch->replace = true`, the new patch supersedes ALL active patches.
KLP generates NOP functions for functions patched by old patches but not
covered by the new one, reverting them to original code. This is the
recommended mode for cumulative patches.

## ELF Format Requirements

- Relocation sections named `.klp.rela.<objname>.<secname>` resolved at load time via kallsyms
- Symbols with `SHN_LIVEPATCH` section index use `.klp.sym.<objname>.<symname>,<sympos>` naming
- `MODULE_INFO(livepatch, "Y")` modinfo attribute is required
- `kpatch-build` handles all of this automatically

See `Documentation/livepatch/module-elf-format.rst` for full spec.

## Subsystem Integration Points

| Subsystem | Integration |
|-----------|------------|
| ftrace | Primary mechanism; `klp_ftrace_handler` redirects calls |
| Module loader | `klp_module_coming()`/`klp_module_going()` hooks; ELF metadata preservation |
| Scheduler | `klp_sched_try_switch()` called from `__schedule()` during transitions |
| fork | `klp_copy_process()` called from `copy_process()` |
| kallsyms | `klp_find_object_symbol()` resolves function addresses at patch-enable time |
| RCU | `func_stack` uses RCU lists; shadow vars use RCU hash tables |
| Stacktrace | `stack_trace_save_tsk_reliable()` requires `CONFIG_HAVE_RELIABLE_STACKTRACE` (objtool on x86_64) |
