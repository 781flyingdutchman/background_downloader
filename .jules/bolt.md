## 2025-02-19 - Database Parallelization
**Learning:** `Future.wait` is a powerful tool for IO-bound operations when the underlying storage supports concurrency or when waiting on multiple async results. Even with single-threaded Dart, awaiting sequentially sums up the latencies.
**Action:** Always check for `for (var x in list) await f(x)` patterns and consider `Future.wait` if operations are independent.

## 2025-02-20 - Object Allocation in Hot Paths
**Learning:** Frequent instantiation of objects like `Random` or `List` (in `Task.split`) in constructors or frequent methods adds up.
**Action:** Use `static final` or `const` for invariant data and shared instances.

## 2025-02-24 - Async I/O in Dart
**Learning:** Using synchronous I/O methods (like `openSync`, `readIntoSync`) inside `Future`-returning functions creates a false sense of concurrency. It still blocks the main isolate.
**Action:** Always use asynchronous counterparts (`open`, `readInto` with `await`) in Dart, especially in libraries intended for UI apps (Flutter).
