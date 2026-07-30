# docs/

| File | What it is | Read it when |
|---|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Full system report: every container, what it does, how to inspect it, and the decisions behind each one — with the alternatives that were rejected and why | You want to understand or evaluate the design |
| [`TRAPS.md`](TRAPS.md) | Upstream behaviours that cost real time, grouped by component | You are about to change something and want to know what will bite |

The root [`README.md`](../README.md) is the short version: what this is, how to
run it, and the demo script.

## Why TRAPS.md is a document and not a comment block

Almost every entry shares one property: **it fails in a way that looks like
something else.** A healthy container serving a broken query. A plausible-looking
number that is 2.37× too high. An authentication error that has nothing to do with
the password. None of them produce a stack trace at the point of the mistake, so
none of them are discoverable by reading the code that caused them.

Inline comments carry the constraint and its consequence at the point of use;
this file carries the full account. When you find a new one, put it here and
leave a two-line marker at the code.

**Do not delete a comment describing a failure that presents as success** without
first confirming the fact is recorded here.
