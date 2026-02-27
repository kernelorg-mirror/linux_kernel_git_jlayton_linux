# kpatch-build Patch Authoring Guide

Based on the upstream [kpatch patch author guide](https://github.com/dynup/kpatch/blob/master/doc/patch-author-guide.md).

**A successful kpatch-build does NOT mean the patch is safe to apply.**
Every patch must be analyzed by a human kernel expert who understands
the patch, the affected code, and how they relate to live patching.

## Cumulative Patches (Patch Upgrades)

Always use cumulative patches that are supersets of previous patches.
kpatch-build enables the `replace` flag by default (atomic replace),
so the kernel loads the new patch and unloads all prior patches in one
transition. Use `-R|--non-replace` to disable if needed.

## Data Structure Changes

kpatch patches functions, not data. Data structure changes require rework.

### Strategy 1: Change the code that uses the structure

Instead of modifying a data structure (e.g., adding an entry to a function
pointer array), modify the code that accesses it to handle the new case inline:

```c
/* Instead of adding to svm_exit_handlers[], check explicitly: */
if (exit_code == SVM_EXIT_EXCP_BASE + AC_VECTOR)
    return ac_interception(svm);
return svm_exit_handlers[exit_code](svm);
```

This is safer because the data structure may be in use by unpatched tasks.

### Strategy 2: Use shadow variables

Use `klp_shadow_alloc/get/free` to attach new data to existing objects.
See `writing-patches.md` for API details.

Shadow variables can also distinguish pre-patch vs post-patch object
instances to apply different semantics:

```c
/* New instances (post-patch) have shadow var -- use new semantic */
if (klp_shadow_get(ctx, MY_SHADOW_ID))
    atomic_dec(&ctx->counter);

/* Old instances (pre-patch) lack shadow var -- use old semantic */
if (!klp_shadow_get(ctx, MY_SHADOW_ID))
    atomic_sub(avail, &ctx->counter);
```

### Strategy 3: Use callbacks

Use `KPATCH_PRE_PATCH_CALLBACK` / `KPATCH_POST_UNPATCH_CALLBACK` macros
(from `kpatch-macros.h`) to modify global state in-place:

```c
#include "kpatch-macros.h"

static bool kpatch_write = false;
static int my_pre_patch(patch_object *obj)
{
    if (some_global_var == OLD_VALUE) {
        some_global_var = NEW_VALUE;
        kpatch_write = true;
    }
    return 0;
}
static void my_post_unpatch(patch_object *obj)
{
    if (kpatch_write && some_global_var == NEW_VALUE)
        some_global_var = OLD_VALUE;
}
KPATCH_PRE_PATCH_CALLBACK(my_pre_patch);
KPATCH_POST_UNPATCH_CALLBACK(my_post_unpatch);
```

Callback pairing: `pre_patch` pairs with `post_unpatch`, `post_patch`
pairs with `pre_unpatch`.

Spinlocks and sleeping locks may be used in callbacks.

## Init Code Changes

Code in `__init` functions or module/device init may have already run
before the patch was applied. You may need a pre-patch callback to detect
this and force the desired state. Some hardware init changes are
inherently incompatible with live patching.

## Header File Changes

- If data structures are changed in headers, see "Data Structure Changes" above
- If a function prototype changes, ensure it's not exported (would break OOT modules)
- Header changes often trigger full kernel rebuilds, slowing kpatch-build significantly
- **Workaround**: move new macros/defines directly into the `.c` file instead of the header

## Unexpected Changed Functions

kpatch-build may report unexpected function changes. Common causes and fixes:

| Cause | Fix |
|-------|-----|
| Changed function was inlined into callers | Unavoidable; all callers will also change |
| Function was inlined before but not after patch | Add `__always_inline` to force inlining |
| Function only inlined after patch | Add `noinline` to prevent it |
| GCC stopped applying `.constprop`/`.isra` optimization | Copy function with new name, call the copy |
| `__LINE__` macro changes due to moved lines | Add new functions at bottom of file, or hardcode original line numbers |

## Static Local Variables

Removing references to static locals will fail. Static locals are global
(outlive function scope) and must be correlated between old/new functions.

**Workaround**: retain a non-functional reference to the static local in
the patched function, ensuring the compiler doesn't optimize it away.

## Code Removal

kpatch can only add new functions and redirect existing ones. "Removed"
functions remain as dead code. To replace a function:

1. Define a new function (e.g., `foo_v2`)
2. Patch callers to call the new function
3. The original function remains but is never called

## "Once" Macros (`printk_once`, `pr_warn_once`, etc.)

These add static locals to `.data..read_mostly`, which kpatch-build
disallows. **Workaround**: implement "once" logic manually:

```c
static bool print_once;
if (!print_once) {
    print_once = true;
    pr_warn("...");
}
```

## `inline` Implies `notrace`

The kernel's `inline` macro includes `notrace`, which removes the
fentry/mcount hook needed by ftrace/kpatch. If the compiler doesn't
actually inline the function, kpatch-build will error:

```
function __tcp_mtu_to_mss has no fentry/mcount call, unable to patch
```

**Fix**: use `__always_inline` to force inlining.

## Jump Labels and Static Keys

- **Static key defined in vmlinux**: jump labels work (Linux 5.8+)
- **Static key defined in a module**: jump labels are NOT supported

When unsupported, kpatch-build errors:
```
Found a jump label at foo()+0x10a, using key bar, which is defined in a module.
```

**Fix**: replace `static_branch_likely()` / `static_branch_unlikely()` /
`static_key_true()` / `static_key_false()` with `static_key_enabled()`.

## Static Calls

Same module-boundary limitation as jump labels.

**Fix**: replace `static_call()` with `KPATCH_STATIC_CALL()` (from
`kpatch-macros.h`).

## Sibling Calls (Tail Call Optimization)

GCC tail-call optimizations can break calling conventions across module
boundaries (mainly PowerPC).

**Fix**: add `__attribute__((optimize("-fno-optimize-sibling-calls")))` to
the function definition.

## Exported Symbol Versioning (`CONFIG_MODVERSIONS`)

kpatch-build compares Module.symvers between original and patched builds.
CRC changes are reported as:
```
ERROR: Version disagreement for symbol <symbol>
```

### False positives

Adding a new `#include` can change a symbol's type graph without changing
the ABI (e.g., fully defining a previously opaque struct).

**Avoidance**: add `#include` sparingly. Extract needed definitions
directly into the `.c` file. If unavoidable, wrap in `#ifndef __GENKSYMS__`.

### Real ABI changes

Cannot safely change exported function ABIs without breaking OOT modules.

## System Calls

Patching syscalls typically fails because `__do_sys##name()` is inlined
(and therefore `notrace`).

**Fix**: `#include "kpatch-syscall.h"` and use `KPATCH_SYSCALL_DEFINEn()`
instead of `SYSCALL_DEFINEn()`.

## Symbol Namespaces

Built-in code doesn't need explicit namespace imports, but kpatch modules do.
If modpost errors on namespace imports:
```
ERROR: modpost: module livepatch-test uses symbol foo from namespace BAR
```

**Fix**: add `MODULE_IMPORT_NS("BAR")` to the patch source.

## Cross Compilation

Build the livepatch in the same environment as the target kernel.

```bash
# GCC cross compile
CROSS_COMPILE=aarch64- kpatch-build ...

# Clang/LLVM cross compile
TARGET_ARCH=aarch64 kpatch-build ...
```
