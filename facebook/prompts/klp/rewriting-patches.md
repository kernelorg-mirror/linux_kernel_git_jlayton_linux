# Rewriting Patches for Livepatch Compatibility

When a patch fails kpatch-build or produces too many changed functions, it
needs to be rewritten with equivalent logic that is more livepatch-friendly.
The goal: same bug fix, minimal diff footprint, no data structure changes.

## General Principles

- **Patch functions, not data.** kpatch-build works by replacing entire
  functions. Any change that isn't a function body change needs rework.
- **Minimize the blast radius.** Fewer changed functions = simpler KLP module
  and less risk. Every extra changed function is another transition point.
- **Keep the same file.** Adding code to new files or moving code between
  files creates unnecessary complexity.

## Tricks

### 1. Inline the fix into the calling function

If the upstream patch modifies a small helper that gets inlined everywhere,
don't patch the helper. Instead, add the fix logic directly in the caller(s)
that matter:

```c
/* Instead of patching a widely-inlined helper: */
/* Add the check directly where it's needed: */
if (folio_test_swapcache(folio) && !folio_test_anon(folio))
    extra_refs++;
```

### 2. Avoid header file changes

Header changes can trigger recompilation of hundreds of files, causing
massive thinlto diffs with LTO kernels.

- Move new `#define` / `enum` values directly into the `.c` file
- Move new `static inline` functions into the `.c` file as `static`
- If a header change is unavoidable, wrap it in `#ifndef __GENKSYMS__`
  to avoid exported symbol CRC changes

### 3. Replace a `static inline` header function with a per-file copy

If the upstream patch fixes a `static inline` function in a header, don't
modify the header. Instead, create a standalone copy of the **fixed**
function (with a new name) in each `.c` file that calls it, and update
call sites to use the copy. This avoids recompiling every file that
includes the header.

Place the copy at the **bottom** of the file (see trick #7) with a
forward declaration near the first call site:

```c
/* Near the first call site, replacing a blank line: */
static int folio_expected_ref_count_fixup(const struct folio *folio);

/* ... call sites use folio_expected_ref_count_fixup() ... */

/* At the very bottom of the file: */
/*
 * Livepatch-friendly copy of the fixed folio_expected_ref_count().
 * Avoids modifying the inline in include/linux/mm.h.
 */
static int folio_expected_ref_count_fixup(const struct folio *folio)
{
    /* full fixed logic here, not a wrapper around the buggy original */
}
```

Key points:
- The copy should contain the **full fixed logic**, not wrap the buggy original
- Add the copy to **every** `.c` file that calls the original
- Use a distinct name (e.g., `_fixup` suffix) to avoid conflicts
- Use `static` not `static inline` (forward-declaring without a body
  defeats inlining; see trick #7)

### 4. Avoid data structure changes

If the upstream patch adds a field to a struct, rewrite to avoid it:

- **Use existing fields differently** (e.g., repurpose a flags bit)
- **Compute the value on the fly** instead of storing it
- **Use shadow variables** (`klp_shadow_alloc/get`) if new per-object
  data is truly needed
- **Add the check in the code path** rather than in the data structure

### 5. Avoid changing arrays, tables, and function pointer tables

These are data, not functions. Instead, add explicit checks in the code
that reads the table:

```c
/* Instead of adding to a dispatch table: */
/* Check explicitly before the table lookup: */
if (exit_code == NEW_CASE)
    return new_handler(args);
return table[exit_code](args);
```

### 6. Control inlining explicitly

Unexpected inlining changes cause extra functions to appear in the diff.

- Add `noinline` to functions that should NOT be inlined (prevents the
  patched version from being inlined when the original wasn't)
- Add `__always_inline` to functions that SHOULD be inlined (prevents
  the patched version from becoming a standalone function)
- If a function gains/loses a `.constprop` or `.isra` suffix, copy it
  with a new name and call the copy instead

### 7. Preserve `__LINE__` values

Many macros expand to include `__LINE__` indirectly: `WARN_ON_ONCE()`,
`BUG_ON()`, `VM_BUG_ON()`, `VM_WARN_ON()`, `lockdep_assert_held()`, etc.
Inserting or removing lines anywhere in a file shifts `__LINE__` for all
code below, causing kpatch-build to see those functions as changed even
though their logic is identical.

- **Always add new functions at the bottom of the file** -- nothing below
  them means no `__LINE__` shift for existing code. Add a forward
  declaration near the first call site, replacing a blank line so the
  net line count doesn't change. Drop `inline` from the definition
  (forward-declaring a `static inline` without a body defeats inlining)
- **The forward declaration must be at file scope** -- the blank line
  you replace must be between function definitions (at the top level),
  NOT inside a function body. Placing a `static` forward declaration
  inside a function is a C error. If no file-scope blank line exists
  near the first call site, look for one just before the enclosing
  function definition
- **For changed functions, compensate for added lines** by removing blank
  lines *within* the changed function(s) to keep the total line count the
  same. Good candidates are blank lines after variable declarations or
  before/after code blocks inside the function. This keeps `__LINE__`
  stable for all code below the patched function.
- **Prefer removing blank lines outside the changed functions** over
  modifying function logic to save lines (e.g., dropping intermediate
  variables or calling helpers twice). Good candidates are blank lines
  between function definitions, after `#ifdef` directives, or between
  the patched function and its neighbors. This preserves the upstream
  patch logic more faithfully while still achieving net zero line change.
- **Drop upstream comments added by the patch** if more lines need to be
  saved. Multi-line explanatory comments added by the upstream patch are
  cosmetic and can be removed without changing fix semantics. This is
  often enough to close the remaining line gap after removing blank lines.
- As a last resort, hardcode the original line number if necessary

### 8. Replace "once" macros

`pr_warn_once()`, `printk_once()`, etc. create static locals in
`.data..read_mostly` which kpatch-build rejects.

```c
/* Replace pr_warn_once("msg") with: */
static bool warned;
if (!warned) {
    warned = true;
    pr_warn("msg");
}
```

### 9. Keep static local variables referenced

If the rewritten patch removes a reference to a static local, kpatch-build
can't correlate it between old and new. Keep a dummy reference:

```c
/* Retain reference to prevent correlation failure: */
(void)static_var;
```

### 10. Use callbacks for global state changes

If the fix requires changing a global variable's initial value or state,
use `KPATCH_PRE_PATCH_CALLBACK` to modify it at patch time rather than
changing init code.

### 11. Split compound patches

If an upstream patch changes multiple subsystems or files, split it into
the minimal subset needed for the fix. Only include the hunks that
actually fix the bug. Documentation changes, cleanup, and refactoring
can be dropped.

### 12. Fix ALL callers of the patched function

When rewriting an inline function fix as a per-file wrapper, apply the
wrapper at every call site across every file -- not just the ones on
the critical path where the bug was observed. Missing a call site leaves
an inconsistency that can cause subtle bugs elsewhere.

**Always use `git grep` to find every caller.** Search against the
**baseline tag**, not the working tree (which may already have your edits
and hide the original call sites). For example:
```bash
git grep -n 'folio_expected_ref_count' v6.16-fbk2-rc4 -- '*.c'
```

Callers may exist in unexpected places (e.g., `fs/jfs/`, `mm/khugepaged.c`)
beyond the obvious subsystem (`mm/migrate.c`). Each `.c` file that calls
the function needs its own copy of the fixup function and updated call sites.

### 13. Avoid touching functions with jump labels or static calls

If the patched function uses `static_branch_likely()` etc. and the
static key is defined in a module, replace with `static_key_enabled()`.
Same for `static_call()` → `KPATCH_STATIC_CALL()`.

### 14. Watch for LTO thinlto partition issues

With `CONFIG_LTO_CLANG=y`, even small changes can cause hundreds of
thinlto partitions to differ. Strategies:

- Ensure PGO profile data matches exactly (same `vmlinux.profdata`)
- Minimize the number of changed translation units
- Avoid changes that alter function call graphs (LTO cross-module
  optimization can cascade)

### 15. Warn about cross-function state contract changes

When a patch moves a responsibility (e.g., a refcount put, a lock
release, a flag update) from function A to function B — where A
initiates work and B is the completion/interrupt handler — this creates
a **transition-safety risk**. The livepatch cannot guarantee both
functions switch atomically for in-flight operations:

- **Old A + New B**: B performs an operation (e.g., `folio_put()`) on a
  reference that old A never held → use-after-free / refcount underflow.
- **New A + Old B**: A acquires a reference that old B never releases →
  resource leak.

This pattern compiles and builds as a KLP just fine, but it can cause
problems when applied to a system with active traffic in the affected
code path.

**Action**: Do NOT fail the build. Instead, **warn the user** about the
mismatch so they can decide whether the risk is acceptable and/or run
targeted tests before deploying. The warning should identify which
functions have the contract change and what the mismatch scenarios are.

Example (fuse readahead UAF fix):
- `fuse_readahead` switches from `readahead_folio()` (drops ref) to
  `__readahead_folio()` (holds ref)
- `fuse_readpages_end` adds `folio_put()` to drop the ref on completion
- During transition, old `fuse_readahead` + new `fuse_readpages_end`
  causes an extra `folio_put()` on a ref that was already dropped

### 16. Replace uaccess functions on hardened x86_64 kernels

On x86_64 hardened kernels, `access_ok()` uses `runtime_const_ptr(USER_PTR_MAX)`
(from `arch/x86/include/asm/uaccess_64.h`), which generates entries in a
`.runtime_ptr_USER_PTR_MAX` section. `create-diff-object` does **not** support
this section type, so any changed or new function that calls `copy_from_user()`,
`copy_to_user()`, `copy_struct_to_user()`, `clear_user()`, `put_user()`, or
`get_user()` will fail the hardened build:

```
ERROR: changed section .relaruntime_ptr_USER_PTR_MAX not selected for inclusion
```

This only affects x86_64 **hardened** flavor. Regular and aarch64 builds are
not affected (the generic `runtime_const_ptr(sym)` fallback is a plain variable
dereference with no special section).

**Fix**: replace the standard uaccess calls with `__` prefixed variants
directly in the patched function. The `__` variants skip `access_ok()` and
do not reference `runtime_const_ptr(USER_PTR_MAX)`:

| Standard function | KLP-safe alternative |
|---|---|
| `copy_from_user()` | `__copy_from_user()` |
| `copy_to_user()` | `__copy_to_user()` |
| `clear_user()` | `__clear_user()` |
| `copy_struct_to_user()` | Open-code with `__copy_to_user()` + `__clear_user()` |

SMAP (Supervisor Mode Access Prevention) is enabled on hardened kernels and
provides hardware-level protection against invalid user accesses regardless
of the `access_ok()` check, so skipping it is safe.

**In-place replacement works.** Even when the original (unpatched) function
already has `copy_from_user`/`copy_struct_to_user` calls that generate
runtime_ptr entries, replacing them with `__` variants directly in the
patched function succeeds -- `create-diff-object` handles the removal of
runtime_ptr entries from a changed function correctly. There is no need
to create a separate `_klp` copy of the function just to avoid touching
the runtime_ptr section. Simply edit the function in place and swap the
uaccess calls.

**Open-coding `copy_struct_to_user()`** -- `copy_struct_to_user` is a
`static __always_inline` in `include/linux/uaccess.h` that calls
`copy_to_user()` + `clear_user()`. Replace it with equivalent logic using
the `__` variants:

```c
/* Replace: copy_struct_to_user(&kinfo, sizeof(kinfo), uinfo, usize) */
/* With: */
{
    size_t size = min(sizeof(kinfo), usize);
    size_t rest = max(sizeof(kinfo), usize) - size;

    if (usize > sizeof(kinfo)) {
        if (__clear_user(((void __user *)uinfo) + size, rest))
            return -EFAULT;
    }
    if (__copy_to_user(uinfo, &kinfo, size))
        return -EFAULT;
}
```

**`__LINE__` impact**: the open-coded `copy_struct_to_user` replacement
adds lines compared to the original single-line call. Compensate by
shortening or removing comments within the patched function to maintain
net-zero line change (see trick #7).

### 17. `__free()` cleanup annotations work with kpatch-build (x86_64 only)

Upstream patches increasingly use `__free(put_task)`, `__free(kfree)`, and
similar `__attribute__((cleanup))` annotations to fix resource leaks. These
annotations **do work** with kpatch-build and ThinLTO on x86_64 -- the
compiler generates cleanup calls that produce detectable code changes.

**Warning (aarch64):** `__free()` annotations can cause `create-diff-object`
failures on aarch64 LTO builds with errors like `symbol changed sections:
.Ltmp<N>`. The cleanup code generation interacts with ThinLTO partitioning
differently on aarch64, causing symbols to land in different ELF sections
between original and patched builds.

**Fix:** replace `__free()` with explicit resource-release calls at each
return path. For example, replace `__free(put_task)` with explicit
`put_task_struct(task)` calls before each `return`. This avoids the cleanup
attribute while preserving the same fix semantics. Apply this rewrite to the
shared source tree (it works on all architectures, not just aarch64).

When the patched function is `static` with a single caller, ThinLTO will
typically inline it. The `.ko` will contain the **caller** rather than
the patched function itself. This is expected.

**Always verify** the function (or its caller) appears in the `.ko`:
```bash
nm klp-out/<arch>-<flavor>/*.ko | grep '<function_name>'
```

## Workflow

1. `git cherry-pick -x <commit-hash>` to preserve author and record the
   original hash
2. Rewrite the patch in the working tree using the tricks above
3. `git commit --amend` to update the cherry-picked commit with the
   rewritten changes (author and `cherry picked from` line are preserved).
   **Add a `[KLP: ...]` annotation** at the bottom of the commit message
   (after the `cherry picked from` line) explaining what was rewritten
   and why, so reviewers can clearly see the patch was modified for
   livepatch compatibility. Example:
   ```
   (cherry picked from commit 6a765878d1fbd3007455bbe14c7bc89cd2aa282b)
   [KLP: rewritten to preserve __LINE__ -- removed blank lines and comments
    in m_start()/m_next() for net-zero line change]
   ```
4. Try building with kpatch-build
5. Read the errors -- identify which functions changed unexpectedly
6. Apply more tricks to minimize changed functions
7. Verify the rewritten patch has the same fix semantics
8. Rebuild and iterate until kpatch-build succeeds
