## 2025-02-19 - Database Parallelization
**Learning:** `Future.wait` is a powerful tool for IO-bound operations when the underlying storage supports concurrency or when waiting on multiple async results. Even with single-threaded Dart, awaiting sequentially sums up the latencies.
**Action:** Always check for `for (var x in list) await f(x)` patterns and consider `Future.wait` if operations are independent.
