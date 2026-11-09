# v3 capture fixtures

Real transcripts and tables from the two v3 Builds. Both were built at the
Reserved path `/home/shared/external/ladder/main`, from a fresh clone of
`main` `c1f2061863135008871e44a22372e6a7246991d1` (tree
`79884773c810891cea9e1863cb4005fd63cbb4f1`), with `rake
build:3.3-wasm32-unknown-icp-{minimal,full}`. They were gathered on 8 November
2026 by the fixture run sheet (ADR-0069). `context.txt` has the tool versions.

The Build machine keeps local time in its hardware clock, so every timestamp
here, including those in `context.txt`, runs 8 hours ahead of true UTC. Only
comparisons between them are meaningful.

| File | What it is |
| --- | --- |
| `copy.build-ext-n.out` | stdout of `make -n build-ext`, run in a `cp -a` Capture copy |
| `copy.main-n.out` | stdout of `make -n -W main.c main.o` in the copy |
| `tree.main-n.out` | the same command in the real Build tree |
| `ext_extinit.c` | the tree's `ext/extinit.c` (`full` only; `minimal` has none) |
| `inputs.list` | every `.o`/`.a` in the tree, the outside `-L` roots and `libwasi_vfs.a` |
| `inputs-init-all.nm` | `<file>\t<llvm-nm --defined-only line>` for each `Init_` definition in those, with every symbol type |
| `ruby.function-map.gz` | the Build's own `wasm-opt ruby --print-function-map`, gzipped, otherwise verbatim |
| `tree-mtimes.txt` | `stat -c '%y  %n'` of the hashed files |
| `tree-{before,after}.sha256` | sha256 of every `.o`, `.a`, `ruby` and `ext/extinit.c`, before and after the capture |
| `counts.txt` | the gathering sheet's own report |

The real trees were byte-identical before and after: 189 files for `minimal`
and 294 for `full`.

They are kept here, and not on the Build machine, because the folder holding
the previous run's fixtures was lost.
