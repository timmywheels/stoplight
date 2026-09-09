Stale check runs no longer turn a green PR red.

A PR that GitHub showed as passing — approved, in the merge queue — could read red in Stoplight, listing the same failed check seven times.

Two bugs in the same query:

- **Stale runs were counted.** A commit keeps every check run that ever reported on it, so re-running a workflow leaves the old failed run attached. All of them went into the verdict, and one stale failure outvoted the passing re-run. Stoplight now keeps only the newest run per workflow and check name. Two workflows that define a job with the same name stay separate, because those are genuinely different checks.
- **Stoplight read the oldest 100 checks.** On a commit with more than a hundred runs, that window is stale by definition. It now reads the newest hundred.

Six new tests cover the case, including six stale failures plus a passing re-run reading green.
