# .gitattributes / .editorconfig Sample

Minimal configuration pair that prevents most of this skill's problem
classes from entering a new repository at all. This repository uses the
same settings on itself.

## .gitattributes

```gitattributes
* text=auto eol=lf
*.ps1 text eol=lf
*.md text eol=lf
*.yml text eol=lf
*.yaml text eol=lf
```

What it buys you:

- `text=auto eol=lf` — git normalizes line endings to LF in the object
  database *and* in the working tree on checkout, so CRLF cannot creep in
  through clones on Windows regardless of each contributor's
  `core.autocrlf`.
- The explicit per-extension lines pin the intent for the file types this
  skill cares about most, and keep working even if someone later narrows
  the catch-all rule.

What it cannot do:

- `.gitattributes` has no concept of BOMs. The UTF-8-without-BOM rule (and
  the PowerShell 5.1 BOM exception for `.ps1`) still needs the byte-level
  checks from [inspection one-liners](inspection-one-liners.md).
- It does not retroactively fix already-committed CRLF content; that is a
  deliberate, separate migration (out of this skill's scope).

## .editorconfig

```editorconfig
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 4

[*.{md,yml,yaml}]
indent_size = 2

[Makefile]
indent_style = tab
```

What it buys you:

- Editors that honor EditorConfig write UTF-8 + LF + no trailing
  whitespace *at edit time*, before git or CI ever see the file.
- `insert_final_newline` keeps `git diff` clean of
  `\ No newline at end of file` noise.

Notes and deliberate choices:

- `trim_trailing_whitespace = true` applies to Markdown here too. Markdown's
  two-trailing-spaces hard line break conflicts with a no-trailing-whitespace
  convention; use a backslash at end of line (CommonMark hard break) or
  `<br>` instead. If your repository relies on two-space breaks, add
  `[*.md]` with `trim_trailing_whitespace = false` — and accept that
  `git diff --check` will then warn about those lines.
- `charset = utf-8` means "UTF-8 without BOM" in EditorConfig terms
  (`utf-8-bom` is the BOM variant). If a `.ps1` must keep its BOM for
  Windows PowerShell 5.1, add:

  ```editorconfig
  [legacy-script.ps1]
  charset = utf-8-bom
  ```

  Repeat an exact section for each additional Windows PowerShell 5.1 script.
  Do not replace that allowlist with a blanket `[*.ps1]` or
  `[scripts/*.ps1]` rule: either wildcard forces BOMs onto scripts that only
  ever run under `pwsh` 7, where they are unnecessary. This repository
  dogfoods that rule with four exact script sections, and its readiness
  validator rejects missing, duplicate, broader BOM, and later non-BOM
  assignments that would cancel an exact exception.
- The `[Makefile]` section exists because TAB is syntax there; it also
  documents why control-character scans must exclude such files.

## Adopting in an existing repository

Adding these files changes nothing retroactively. New checkouts and new
edits follow the rules; existing committed CRLF or BOM content stays until
explicitly normalized (per changed file, behind the strict-decode guard —
see [guarded normalization](guarded-normalization.md)). Do not pair the
`.gitattributes` change with a same-commit bulk renormalization
(`git add --renormalize .`) unless the whole team has agreed to absorb the
one-time large diff.
