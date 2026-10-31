# Release Bundle contract

The fork publishes a **Release Bundle** per Build: everything a consumer needs
to link a Ruby from `libruby-static.a`, plus a statement of what the Build ran.

One rule decides every clause below. **The fork states facts; the consumer
interprets them.** Every field in a bundle is something the Build machine
observed. Nothing in it is a claim about the machine that downloads it, and
nothing in it is rewritten to suit one.

**Version 1.** Numbering restarts here. Four earlier drafts carried the
numbers v1 through v4; no bundle was ever cut under any of them and no
consumer ever implemented one. A version means something once an artifact
declares it, and until then it is a heading. Every bundle states the version
it was cut under in `manifest.contract_version` (4.9), and edits to this
document arrive in batches, so that each version costs a consumer one fixture
rather than one per edit.

---

## 1. Publication

**1.1** One bundle per Build, published as a GitHub release on the `release`
branch of `graial/ruby.wasm`. The branch is permanent: `main` carries exactly
the patch set currently under review upstream, and the workflow, the extractor
and this document are not part of it.

**1.2** An ordinary release, never a pre-release. GitHub's latest-release
endpoint skips pre-releases, and a consumer resolving `latest` would resolve
nothing.

**1.3** Tag is Build name, date, ordinal, the ordinal always present:

```
3.3-wasm32-unknown-icp-minimal-20260911.1
```

Asset: `ruby-3.3-wasm32-unknown-icp-minimal-lib-20260911.1.tar.gz`. The
ordinal carries uniqueness and nothing else; a suffix that exists only
sometimes is a suffix whose absence means something, and publish time is not
when to decide what.

**1.4** A sibling asset `<asset>.sha256` carries the tarball's own sha256, so
a download can be checked rather than described.

**1.5** The tarball unpacks to exactly one top-level directory named for the
asset stem. A consumer is expected to use `--strip-components=1` into a fixed
destination, so the varying stem never reaches a path anyone writes down.

**1.6** `latest` points at the one Build the fork supports as a default. A
second Build publishes with `--latest=false` (`gh release create`, or
`make_latest: false` on the REST endpoint), flipped deliberately if the
supported default changes.

**1.7** Assets and tags are immutable and are never deleted. A correction is a
new tag. A superseded release stays published: a consumer records a resolved
tag, and a deleted tag resolves to nothing — the same failure immutability
guards against, arrived at from the other side.

**1.8** A release body carries no authority. Nothing hashes it, nothing parses
it, no tool reads it. It may be edited, and an appended supersession notice
naming the replacing tag is the expected use. It must never be the only place
a fact about a bundle appears.

---

## 2. Layout

```
<stem>/
  manifest.yml
  hashes.txt
  link.raw.txt
  link.paths.txt
  compile.raw.txt
  compile.paths.txt
  build/          <- mirrors the Build tree's relative layout
  prefix/         <- the install prefix, its own root
  wasi-vfs/libwasi_vfs.a
```

**2.1** `build/` holds exactly these four members at exactly these paths, and
nothing else:

| Path in bundle | Named by the link recipe |
| --- | --- |
| `build/libruby-static.a` | yes, via `-L.` and `-lruby-static` — symlink, see 2.3 |
| `build/ext/extinit.o` | yes |
| `build/enc/libenc.a` | no |
| `build/enc/libtrans.a` | no |

Placement follows the Build tree's relative layout so that a reference recipe
is readable against the bundle it ships with: a reader meeting `ext/extinit.o`
on the link line finds it at `build/ext/extinit.o` without being told a
mapping. A consumer working from the link recipe is expected to change
directory into `build/` rather than rewrite the relative tokens, which is what
lets `-L.` and `-lruby-static` be inherited unchanged.

**It follows that layout; it does not copy the Build tree.** `build/` is
populated by naming its members, never by copying a directory and excluding
things — a directory populated by exclusion describes whatever the Build tree
happened to contain that day, and 6.6's both-directions hash check then
asserts over a set nobody chose.

The layout resolves the relative paths a consumer needs, not every relative
path on the link line. `main.o` is deliberately absent, because a consumer
substitutes its own translation unit for it (7.7), and `ruby` is the output
and nobody's input. A claim that every relative path resolves would be false
on both, and would invite a reader to treat a missing `build/main.o` as a
defect.

**2.2** `prefix/` is the install prefix unaltered. Its source is the
`usr/local/` subtree of the Build tree's staging directory, not the staging
directory itself: a configure with no `--prefix` defaults to `/usr/local` and
reproduces that under staging. So `prefix/lib/libruby-static.a` and
`prefix/lib/ruby/$RUBY_API/$ARCH/rbconfig.rb` are the paths that hold.

A consumer finds `rbconfig.rb` by globbing `prefix/lib/ruby/*/*/rbconfig.rb`
under a must-match-exactly-once rule. Both components are globbed; the arch
component is `wasm32-wasi` even for the icp Build, and is not a value to
hardcode.

**2.3** The archive is `prefix/lib/libruby-static.a`, and `manifest.archive`
names it, so a consumer is told rather than choosing between two candidates.
`build/libruby-static.a` is a relative symlink to it.

- The tarball preserves symlinks. No `--dereference`.
- `hashes.txt` lists `build/libruby-static.a` carrying its target's hash.
- No symlink in the bundle resolves outside the top-level directory.

**2.4** A member is *mirrored* into `build/` — appearing there as well as at
its own home — only where a recipe names it by a path relative to the Build
tree root. That is why the archive appears twice and by symlink, and why the
generated `ruby/config.h` does not appear at all. This governs mirroring only.
It says nothing about which members ship.

**2.5 A bundle tree is assembled once, into a directory that did not exist.**
Assembling over an existing tree merges rather than replaces: a member from an
earlier attempt survives, and 6.6 then passes, because `hashes.txt` is
generated from whatever is present. That is 2.1's populated-by-exclusion
hazard by a second route, and the set is again one nobody chose.

A producer that finds the destination present stops, rather than reusing it or
clearing it. Clearing is indistinguishable from a partial clear that failed
halfway.

---

## 3. Members

**3.1** The install prefix, and four objects that live outside it:
`ext/extinit.o`, `enc/libenc.a`, `enc/libtrans.a`, `libwasi_vfs.a`. The one
property all four share is that the install prefix does not contain them.

The install prefix alone cannot link a Ruby, which is why the bundle exists,
and that claim rests on `ext/extinit.o` alone: it is generated at link time,
never installed, and named by the link recipe. The other three are facts about
the Build tree — see 3.2 and 3.3.

**3.2** `libwasi_vfs.a` ships because CRuby's link line names it. A consumer
may have good reason not to link it; that is the consumer's interpretation and
does not travel back across the boundary. The `wasi_vfs` path key is required
regardless, since the token is in the verbatim recipe, and a declared key
whose file is absent is a bundle failing its own coverage rule to suit one
downstream reading.

**3.3** `enc/libenc.a` and `enc/libtrans.a` ship, and the reference link line
for a `minimal` Build names neither, nor does `ext/extinit.o` reference them,
and `make ruby` completes without them. **The member list is not the set of
archives the link requires.** They are facts about the Build tree and
provision for a `full` Build; whether any given downstream link needs them is
for that link to establish.

Whether the member list is constant across Builds is open. The table in 2.1
was derived from one `minimal` Build, and a `full` link recipe may name
objects outside the prefix that it does not hold.

---

## 4. Build Manifest — `manifest.yml`

```yaml
contract_version: 1
build_name: 3.3-wasm32-unknown-icp-minimal
fork_commit: <40-hex>
capture: manual                  # or: workflow
archive: prefix/lib/libruby-static.a
transcript_cwd: /…/build/wasm32-unknown-icp/ruby-3.3-…-minimal

tools:
  wasi_sdk: "22.0"
  binaryen: "wasm-opt version 108 (version_108)"
  wasi_vfs: "0.6.2"
  cc_wrapper_sha256: <64-hex>

path_keys:
  wasi_sdk_path: { kind: root,  value: /…/toolchain/wasi-sdk-22.0,  accounted: tools.wasi_sdk }
  ruby_src:      { kind: root,  value: /…/checkouts/3.3,            accounted: null }
  cc_wrapper:    { kind: token, value: /…/3.3/tool/wasm-clangw,     accounted: tools.cc_wrapper_sha256 }
  wasi_vfs:      { kind: token, value: /…/0.6.2/libwasi_vfs.a,      accounted: wasi-vfs/libwasi_vfs.a }
  wasm_opt:      { kind: token, value: /…/binaryen/bin/wasm-opt,    accounted: tools.binaryen }
```

**4.1 Tool versions, never URLs or install methods.** A version is a fact
about the Build; acquisition is a fact about the consuming machine, which the
fork does not know.

Only tools the Build actually ran appear. A tool a consumer needs for its own
later stages is a fact about that consumer's pipeline, not about this Build,
and the fork can only transcribe a number someone chose elsewhere — a field
that looks like its neighbours while being different in kind.

The three are not equally load-bearing. **wasi-sdk must match the archive** or
CRuby fails inside `ruby_setup` naming nothing. Binaryen changes the module's
shape. wasi-vfs is stated because `libwasi_vfs.a` ships and its version is
otherwise recoverable only by reading it out of a path by shape.

**4.2 `cc_wrapper_sha256` is not a version.** A consumer that ships its own
copy of `tool/wasm-clangw` rather than depending on a CRuby checkout has no
other way to notice the two diverging. The wrapper shadows `PATH` and execs,
so a change to what it shadows is silent.

**4.3 `fork_commit` requires a tracked-clean checkout.** A commit recorded
from a modified tree names a tree nobody has. The fork asserts
`git status --porcelain --untracked-files=no` is empty and stops otherwise.
Untracked files are not a modification of the commit and do not stop a bundle.

There is no dirty flag. A published bundle is permanent under 1.7, and
provenance that cannot be reproduced is not worth recording; stopping is the
cheaper failure.

**4.4 `build_name` is provenance and a check.** A consumer should fail when a
resolved bundle's `build_name` disagrees with the Build it expects. `latest`
moving to a different Build is a failure every assertion in section 6 passes
and every hash survives.

**4.5 `capture: workflow | manual`** records who invoked the extractor and the
assertion steps, and nothing else. `manual` means section 6 was applied by
hand, over a tracked-clean tree, to the same standard, with the same shipped
extractor (5.6) — a weaker guarantee about the applying, not about what was
applied.

**4.6 `transcript_cwd` is provenance, not a key.** It states the working
directory the captures were taken in, which is a fact about the Build machine
and the same kind of statement as `fork_commit` and `build_name`. Deriving it
from `build_name` would be an inference, and that the two agree is something
to observe rather than assume.

It is not a path key because it matches nothing. The paths it would once have
resolved — `-L.`, `main.o`, `ext/extinit.o`, `-lruby-static` — are relative,
stay relative, and are handled by 2.1's change of directory. A key that
matches nothing and is read by no assertion is a key in name only.

6.0 reads it as the Build tree root, which is what it is.

**4.7 Path keys carry `kind`, `value` and `accounted`.** A path key declares
what an absolute path in a reference recipe *is* — which of two paths sharing
a prefix is a toolchain, which is a source checkout, which is a build product.
That is a fact only the Build machine holds.

`accounted` names *how* the bundle accounts for what the key names, and is one
of three forms:

- **`tools.<key>`** — the bundle states a fact about it in `tools:`. A fact,
  not necessarily a version: 4.2 establishes that `cc_wrapper_sha256` is
  precisely not a version and is still a statement the bundle makes about that
  path.
- **a bundle-relative member path** — the bundle carries it.
- **`null`** — the bundle accounts for it in neither way. The path exists on
  the Build machine and the bundle says nothing further about it.

A reference rather than a boolean, because a boolean leaves the *relation*
unstated and unstateable. `wasi_sdk_path` is accounted by `tools.wasi_sdk`,
`cc_wrapper` by `tools.cc_wrapper_sha256`, `wasm_opt` by `tools.binaryen` —
name minus a suffix, name plus a suffix, and no lexical relation at all. Any
check over a boolean would carry a hand-maintained table mapping key names to
the things that account for them, living in code, where 5.6 has the contract
state what the code means rather than the code hold what the contract does
not. A key added without a table row would pass by not being looked at.

That the reference duplicates something sections 2, 3 and 4.1 already fix is
the point rather than the objection. `manifest.archive` does the same and 2.3
gives the reason: a consumer is told rather than left choosing. Unchecked
duplication rots; duplication a section 6 assertion resolves on every
publication is a cross-check.

The field states a property of *this bundle*, not of the machine that
downloads it. Whether a consumer could obtain a CRuby checkout by other means
is not the fork's to say, and saying it would be the guess at an unseen
environment this document's opening rule forbids.

**4.8 One key per distinct thing a path names, not one per upstream
directory.** Every absolute path in the recipes sits under the fork's `build/`
directory, which makes a single declared root look sufficient. It is not:
those paths name unrelated things — a separately fetched toolchain, a source
checkout, a file the bundle carries. No single root is true of more than one
of them, and collapsing them forces a consumer to re-split by path shape,
which is reverse engineering the roots from the paths.

**4.9 `contract_version` states the version of this document the bundle was
cut under.** An integer, required, and never inferred.

It is a fact the Build machine observed about its own process: it names no
tool the Build never ran, makes no claim about the consuming machine, and
cannot rot, because it describes a permanent artifact. It is closer in kind to
`fork_commit` than to anything 4.1 refuses.

Without it, a disagreement between a consumer's extraction and a published
path trace is ambiguous between "the consumer's reading of 5.3 is wrong" and
"this capture predates an amendment that changed 5.3" — and that ambiguity
lands on whoever is debugging a refused bundle, who is the person least placed
to resolve it.

It may not be published in the release body instead. 1.8 forbids a release
body being the only place a fact about a bundle appears.

---

## 5. Reference recipes

**5.1** Verbatim command lines from `make -n`, published so a consumer can
reproduce the Build's own link and compile decisions rather than reassembling
them. No rewriting, no reformatting, no trimming.

- **`link.raw.txt`** — the recipe producing `-o ruby`, followed by the
  `wasm-opt` line after it.
- **`compile.raw.txt`** — the recipe producing `-o main.o`.

`main.o` rather than `ext/extinit.o`: it is built from srcdir with the
standard flags and is the nearest analogue to a consumer's own translation
unit, where `extinit.c` is generated and may pick up rules of its own.

The `wasm-opt` line is captured as make emitted it, **including make's
trailing `; :`**, which is make's construction and not part of the command. It
writes in place (`-o ruby ruby`) and carries
`--pass-arg=asyncify-ignore-imports` twice, once from `wasmoptflags` and once
added by the build. Path extraction over that line must survive the `;` and
the bare `:` as words.

**5.2 Both recipes are published on the same terms.** Neither is abridged,
annotated, or marked as more usable than the other. Coverage is a property of
keys (6.2) and is asserted over both recipes together (6.3); usability is a
judgement, and judgement is what this boundary keeps out.

An earlier version declared `compile.raw.txt` non-substitutable, on the
grounds that its include paths carry `ruby_src`, which the bundle does not
account for. That was a statement about a consumer that rewrote recipes into
its own paths. A consumer that instead recognises
`-I/…/checkouts/3.3/include` as the source checkout's include directory needs
nothing resolved at all, so the compile recipe is as comparable as the link
recipe — and withholding it from that treatment withheld exactly what 5.1
captures it for: `-fvisibility=hidden`, which configure never writes to
`configure_args`, and the three `WASM_*_STACK_BUFFER_SIZE` defines, which live
in `XCFLAGS` where nothing downstream reads them.

Stating usability per-file would also leave the link recipe silently
mis-described the day a second checkout path appears on it.

**5.3 Extraction is defined over embedded paths, not shell words.** The
compile recipe's absolute paths sit inside words: `-I/…/include` is one shell
word beginning `-I`. So within each shell word, take every **anchored**
`/`-initial substring; those are the paths keys match against.

- `kind: token` matches a complete embedded path, exactly and in full.
- `kind: root` matches a leading prefix of an embedded path.

A shell word is delimited by unquoted whitespace; within it, an embedded path
runs from `/` to the next `"`, `'`, or end of word.

**A `/` begins an embedded path only where it is anchored**: where it is the
first character of the word, where the character before it is one of `=` `,`
`:` `>` `<` `"` `'`, or where everything before it in the word is an option
name — one or more dashes followed by letters only.

Without the anchor the rule is unusable rather than merely imprecise.
`ext/extinit.o` is a word on every link recipe; its maximal `/`-initial
substring is `/extinit.o`; no key covers that; and 6.2 would stop every
capture ever taken. `-I.ext/include/wasm32-wasi` on the compile recipe fails
the same way.

The option-name clause separates `-I/opt/include`, where the path is the
option's argument, from `-I.ext/include`, where there is no path at all. The
discriminating character is the `.`, which an option name cannot contain and a
relative prefix in these recipes always does. `ext/extinit.o` fails a
different clause: it carries no leading dash, so nothing before its separator
is an option name.

**The anchor set is an enumeration and is the weakest clause in this
document.** It was derived from the shapes CRuby's recipes are known to carry
rather than from a captured transcript. Everywhere else in section 5, being
wrong is loud — an unclassifiable word stops the release. Here it is quiet: a
word carrying an absolute path the anchors do not admit yields no path, and a
shed path is what 6.2 and 6.3 exist to catch only when some *other* key was
supposed to cover it. Any addition to the anchor set is a version.

**The terminator applies before maximality. A quote ends a path and is never
inside one.** So `-DFOO="/a/b"` yields `/a/b` and the release proceeds. Read
the other way round — maximal substring first, terminator checked afterwards —
it yields `/a/b"`, and a correct bundle stops on a punctuation mark. A clause
that can never fire is an invitation to the wrong reading, which is why the
earlier stop rule's "or a quote character" is struck rather than kept
defensively.

**A path containing whitespace is unsupported and stops the release** rather
than being guessed at. `-DFOO="/a b/c"` is one shell word, the path runs to
the closing quote as `/a b/c`, and such a path can be neither matched against
a key nor reassembled.

**A path containing a character that anchors without terminating stops the
release** — that is `=` `,` `:` `>` `<`, the anchor set less the two quotes.
Each of them can sit inside an extracted value, because a path runs past it to
the end of the word, and nothing in the word says whether it separates two
paths or belongs to a filename.

`-Wl,--whole-archive,/a/lib.a,--no-whole-archive` is the shape that matters.
The value is `/a/lib.a,--no-whole-archive`: a path and a linker flag in one
string, which a root key matches by prefix, so 6.2 passes and a consumer reads
one path where the Build named an archive and a flag.
`-fdebug-prefix-map=/a=/b` is the same defect on `=`, and
`-Wl,-rpath,/a/b:/c/d` on `:`.

Neither reading is guessed at, because both are quiet. Making these characters
terminators would silently truncate a filename containing one; leaving them
ordinary silently overruns. Stopping costs nothing on a recipe whose paths end
at word boundaries, and on one where they do not it produces the shape rather
than a theory about it.

The rule is stated for the class rather than per character deliberately. It was
first written for the colon, which is the least likely member; a clause per
character would have needed a fifth version to reach the comma, and the
argument was never about which character it was.

All five stay in the anchor set. On `-DX="/a":/b` the character before `/b` is
the colon and not the quote, so removing it would drop that path silently — and
removing an anchor does nothing about the overrun, which comes from the
terminator set.

**The likely resolution, once a capture exists, is that the anchor set and the
terminator set become the same set.** That produces correct results on every
shape anyone has yet constructed. It is not adopted here because it is a guess
in the quiet direction, and no transcript has been read.

**A line that does not tokenize stops the release.** An unbalanced quote is
not a word-splitting problem to be worked around. Quote-aware splitting is a
precondition of this rule rather than a refinement of it: an implementation
that splits on raw whitespace can detect neither the whitespace stop nor an
unbalanced quote, because both are properties of a tokenisation it never
performs.

**5.4 Two passes, tokens first.** Token keys apply first, matching complete
paths exactly; root keys then apply as prefixes to what remains.
Order-independence holds by construction rather than because one machine's
directories happened not to nest. A token key living under a root key is the
expected shape: one file out of a checkout is accounted for while the checkout
itself is not.

**5.5 The fork publishes the path trace it asserted over.**
`link.paths.txt` and `compile.paths.txt` hold the extracted absolute paths of
their recipes: **a multiset in positional order** — one line per occurrence,
in the order the extractor walks the recipe, left to right. The fork does not
sort, dedupe or canonicalise; deduping is a transformation and 5.1 forbids
transforming a capture. A consumer extracts independently and should compare
as an ordered sequence — same elements, same order, same length.

This costs nothing to produce, since 6.2 already computes the trace, and a
disagreement between two extractions is the failure it exists to make loud.

**5.6 One extractor, and 5.3 states what it means.** The fork ships a single
extractor on the `release` branch, and every bundle is cut with it however it
was invoked — which is what makes 4.5's `manual` a weaker guarantee about the
applying and not about what was applied. 5.3 is the statement of what that
code means rather than a second specification of it, and a second fork-side
implementation would make 5.5's comparison compare the fork with itself.

The extractor is a reader, not an assertion. A word it cannot classify under
5.3 is a *reading* failure, upstream of every check in section 6, all of which
take a complete trace as input and judge it. So it emits nothing on stdout,
exits non-zero, and names the offending word with its line and character
position. It does not emit a partial trace alongside a warning: 6.2 consumes
that output, and a partial trace flowing into a coverage assertion is how a
path gets shed quietly.

---

## 6. What the fork asserts before publishing

**6.0 Preconditions on the Build tree.**

- **`make ruby` has completed.** `ext/extinit.o` is generated at link time and
  does not exist until it has, and a bundle cannot ship a member the Build
  never produced. A printed recipe is not a completed link.
- `<transcript_cwd>/ruby` exists and is newer than `main.o` and
  `ext/extinit.o`.
- The checkout is tracked-clean, per 4.3.

**6.1 Selection, by stated pattern, each matching exactly once.**

| Artifact | Pattern | Source |
| --- | --- | --- |
| link recipe | `-o ruby$` | `make -n ruby` |
| `wasm-opt` line | `bin/wasm-opt ` | `make -n ruby` |
| compile recipe | `-o main\.o ` | `make -n -W main.c main.o` |

The link pattern is anchored because the `wasm-opt` line also contains
`-o ruby`; unanchored it matches twice and stops a correct release. "Matches
exactly once" is not a rule until the pattern is named.

Zero or two matches stops the release. A warm tree emits no compile line for
`main.o`, so the capture has to make it out of date: `-W main.c` asks what
follows from `main.c` having just changed. `-B` also works and produces a
byte-identical recipe, and is not used, because it forces every prerequisite
recursively — six hundred lines of unrelated build activity for the pattern to
be right about, where `-W` produces two. A rule that must match exactly once
means more over a small transcript than a large one.

A selected recipe must be a single physical line; a backslash continuation
stops the release rather than being joined.

Counting and capturing read one transcript, not two. `make -n` reads the tree
as it stands, so a count taken from one invocation does not describe the line
published from another.

Selecting by a rule that must match once is stating a fact. Selecting a line
that looked right is a judgement, and judgement is the thing this boundary
exists to keep out.

**6.2 Coverage and non-ambiguity, over embedded paths per 5.3.**

- Every absolute embedded path in a selected recipe starts with a declared
  key.
- No root key is a prefix of another root key. The prefix clause binds among
  roots only, since tokens are matched in full and applied first.
- No two token keys share a value.
- No token key equals a root key.
- Every key's `accounted` reference resolves: a `tools.<key>` reference names
  a key present in `tools:`, and a member path names a path listed in
  `hashes.txt`. A key claiming the bundle accounts for it where the bundle
  does not is a claim nothing else would catch.

Resolving a member reference reads `hashes.txt`, so that bullet alone is
checked after assembly and 6.6, where the rest of 6.2 reads only the recipes
and the manifest. Section 6's clauses are numbered, not ordered, and this is
the one dependency among them.

**Every assertion in this section reads the manifest as the bundle carries
it.** A key set transcribed twice is two key sets, and the assertions will
validate the copy that does not ship. 5.5 says the same thing about path
traces, which is why traces have never had this failure.

The first bullet is also what catches a Build-tree path appearing absolutely.
`transcript_cwd` is not a key (4.6), so such a path starts with no declared
key and stops the release — which is the loud failure, and the signal to
declare a key for it.

**6.3 Every declared key matches at least once across the selected recipes
taken together.**

Across the recipes together, because some keys appear only in one of them; per
recipe, this stops a correct release.

A key matching nothing is a stale declaration after a Build change, or a typo
in a `value` that silently sheds the path it was meant to cover. The rule
carries no exemption: an entry that has to be excused from it is provenance
rather than a key, and belongs at the manifest's top level.

**6.4 `link.raw.txt` contains no path carrying a key with `accounted: null`.**

Such a path means the capture's link recipe depends on something the bundle
does not account for. The fork is the only party that can say which key
matched and which did not, so the diagnosis belongs here — where the
information is — rather than downstream, where the same path surfaces only as
a mismatch against a reference with nothing to fill it. A consumer's own check
would see the symptom; this sees the cause. The producer can check one line.

**6.5 The captures and the shipped prefix describe the same Build.** The four
`_WASI_EMULATED_*` defines, the three `WASM_*_STACK_BUFFER_SIZE` values and
the wasi-sdk path in `compile.raw.txt` agree with `configure_args` in the
shipped `rbconfig.rb`.

`make -n` reads the tree as it stands now, while the prefix was produced
earlier. A bundle whose recipes describe a configuration the archive did not
come from is the silent-when-wrong class the bundle exists to close, one layer
out.

**6.6 `hashes.txt`** is `sha256sum` format — `<hash>  <path>`, one per line,
paths relative to the top-level directory, sorted by path. It covers every
member including `manifest.yml`, both recipes, both path traces and the
symlink of 2.3, and excludes only itself. `hashes.txt` is covered transitively
by 1.4.

Standard format because a consumer should be able to check both directions
with tools nobody had to write.

**6.7 No assertion in this section is satisfied by a pipeline's exit status.**
A `grep` after a `make` reports the `grep`, and a `sha256sum -c` piped into a
filter reports the filter. Every check names what it examined and fails on
that, because a swallowed exit status is the defect this bundle exists one
layer up to prevent.

---

## 7. What a consumer can expect

**7.1 What the bundle gives you.** Enough to link a Ruby without a CRuby
checkout, a Build tree, or the toolchain that produced the archive: the
archive and headers, the objects outside the prefix, the exact link and
compile lines CRuby used, the declared keys that name what each absolute path
in them is, and the tool versions to fetch.

**7.2 Verify in both directions.** Every member in `hashes.txt` present and
matching, and every file present listed. A stray editor backup or a
half-copied member should fail the fetch rather than travel onward. Check that
`build/libruby-static.a` is a symlink resolving inside the top-level
directory: `sha256sum -c` follows symlinks, so a second real copy of the
archive passes the hash check identically.

**7.3 The wasi-sdk must be the one the archive was compiled with.** Linking
against a different one resolves every symbol, links, instantiates, and then
fails deep inside `ruby_setup` with `TypeError: wrong argument type false
(expected Class)`, naming nothing. Its version is in the manifest and is
cross-checkable against `configure_args` in the shipped `rbconfig.rb`.

**7.4 Binaryen's version is checkable against nothing.** Its install path
carries no version where wasi-sdk's does, and `configure_args` does not carry
it either. The manifest states what `wasm-opt --version` printed; a consumer
parsing a fetchable tag out of that line is interpreting, and should fail
loudly rather than fetch the wrong Binaryen.

**7.5 The member list is not a link requirement** — 3.3.

**7.6 Both recipes are evidence, and neither carries a claim about
applicability** — 5.2. The compile recipe's flags are CRuby's for CRuby's
`main.c`, and a consumer's translation unit is not `main.c`; the link recipe
is CRuby's for a command module, and a consumer may be linking something else.
Deciding which decisions transfer is interpretation and therefore the
consumer's. The fork ships the evidence and makes no claim about its
applicability — which is better served by a consumer that compares against it
and fails loudly than by one that reads it and may not look.

**7.7 The reference link line is a reference, not a template.** A consumer
substituting its own object for `main.o` is making one edit of several — it
may also drop `libwasi_vfs.a`, add archives, add per-symbol export flags, or
link a reactor where CRuby linked a command. "Everything else is preserved" is
true about preservation and false about the line being otherwise untouched.

**7.8 `accounted: null` is not a warning.** It says the bundle carries neither
the thing nor a statement about it, and nothing more. It is not
a claim that the thing is unavailable, unsupported or unsafe to depend on;
what a consumer can obtain elsewhere is the consumer's own knowledge.

**7.9 Where `capture: manual`, no job asserted anything** — 4.5. Section 6's
checks are as good as the hand that applied them. The extractor is the same
either way (5.6).

**7.10 A release body may say anything, or nothing** — 1.8.

**7.11 A bundle declares the contract version it was cut under** — 4.9. A
consumer implementing more than one version should say which it implements; a
consumer implementing one should refuse the rest rather than guess.