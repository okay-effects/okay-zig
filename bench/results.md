# Four languages, the same lanes (2026-10-28)

okay-goose, okay-zig, okay-rust and Scala (okay-core's kernel) on one laptop (Apple silicon), n = 1000, µs per run
(so ns per step), the mean of two rounds. Goose, Zig and Rust: a second of warm-up, five rounds of a second, each run
holding JMH's lock (okay-rust's `scripts/withlock.py`), the two rounds alternating the languages; Scala: JMH, 3 warm-up
iterations and 5 of a second, one fork. Load 1.6–2.4. Each answer through an opaque value (`black_box`, `opaque_`,
`bench/opaque.h`), checked before timing.

| lane | Goose `resumable fn` | Zig `ok.resumable` | Rust `#[resumable]` | Zig CEK machine | Scala CEK machine |
|---|---|---|---|---|---|
| every path of a choice among 1000 | 0.40 | 0.36 | **0.25** | 29.4 | 13.0 |
| a deep handler taking the rest at each of 1000 steps | **0.24** | 0.39 | 0.57 | 23.0 | 9.8 |
| a generator of 1000 values, summed | **0.24** | 0.38 | 0.30 | 30.3 | 17.8 |

| lane | Goose (a context) | Zig (a context) | Rust `okay::typed` | Scala |
|---|---|---|---|---|
| 1000 values told, kept | **0.13** | 0.93 | 1.08 | 9.0 |

- The first three are the rest of a program taken more than once (or at each step): Goose's and Rust's state
  machines are generated (okgc, a proc macro), Zig's are written by hand; the machines interpret a program as data.
- Scala's lanes are okay-core's `KernelBenchmark` (`choose`, `general`, `generate`, `writer`): the same programs in
  shape — its generator is pulled through okay-core's `Emit.generate`, its choice collects every value.
- The writer: Goose's array grows by a bump of the data stack and never moves; Zig's and Rust's lists reallocate.

Commands: `okgc build bench/lanes.okg -o lanes --include bench/opaque.h` (okay-goose); `zig build lanes
-Doptimize=ReleaseFast` (okay-zig); `cargo bench -p okay-resumable --bench lanes`, `cargo bench -p okay-machine --bench
kernel -- T:writer` (okay-rust); `sbt "coreJVM/Jmh/run -wi 3 -i 5 -w 1 -r 1 -f 1 .*KernelBenchmark.(choose|general|
generate|writer)$"` (okay-core).
