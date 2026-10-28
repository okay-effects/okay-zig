# Four languages, the same lanes (2026-10-28)

okay-goose, okay-zig, okay-rust and Scala (okay-core's kernel) on one laptop (Apple silicon), n = 1000, µs per run
(so ns per step), the mean of two rounds. Goose, Zig and Rust: a second of warm-up, five rounds of a second, each run
holding JMH's lock (okay-rust's `scripts/withlock.py`), the two rounds alternating the languages; Scala: JMH, 3 warm-up
iterations and 5 of a second, one fork. Load 1.6–2.4. Each answer through an opaque value (`black_box`, `opaque_`,
`bench/opaque.h`), checked before timing.

| lane | Goose `resumable fn` | Zig `ok.resumable` | Rust `#[resumable]` | Scala machine | Zig machine | Rust machine |
|---|---|---|---|---|---|---|
| every path of a choice among 1000 | 0.40 | 0.36 | **0.25** | 13.0 | 29.4 | 100.4 |
| a deep handler taking the rest at each of 1000 steps | **0.24** | 0.39 | 0.57 | 9.8 | 23.0 | 37.7 |
| a generator of 1000 values, summed | **0.24** | 0.38 | 0.30 | 17.8 | 30.3 | — |

| lane | Goose (a context) | Zig (a context) | Rust `okay::typed` | Scala |
|---|---|---|---|---|
| 1000 values told, kept | **0.13** | 0.93 | 1.08 | 9.0 |

- The first three are the rest of a program taken more than once (or at each step): Goose's and Rust's state
  machines are generated (okgc, a proc macro), Zig's are written by hand; the machines interpret a program as data.
- Rust's machine: okay-machine's `kernel` bench (`choose`, `general`, `writer`: 9.8 for the writer); it has no
  multi-shot generator lane. Its binds are `Rc<dyn Fn>` closures and its values `Box<dyn Any>`: an allocation and an
  indirect call a step, where Zig's machine keeps values of 16 bytes in place and reuses nodes from free lists, and
  Scala's allocates in the JVM's young generation, its calls compiled by the JIT.
- Scala's lanes are okay-core's `KernelBenchmark` (`choose`, `general`, `generate`, `writer`): the same programs in
  shape — its generator is pulled through okay-core's `Emit.generate`, its choice collects every value.
- The writer: Goose's array grows by a bump of the data stack and never moves; Zig's and Rust's lists reallocate.

Commands: `okgc build bench/lanes.okg -o lanes --include bench/opaque.h` (okay-goose); `zig build lanes
-Doptimize=ReleaseFast` (okay-zig); `cargo bench -p okay-resumable --bench lanes`, `cargo bench -p okay-machine --bench
kernel -- T:writer` (okay-rust); `sbt "coreJVM/Jmh/run -wi 3 -i 5 -w 1 -r 1 -f 1 .*KernelBenchmark.(choose|general|
generate|writer)$"` (okay-core).

## Why a machine at all

The state machines are fast because the program is known when it is compiled: its stops, its variables, the handlers
around it. The machine runs a program that is DATA, so it does what a compiled state machine cannot:

- programs made at run time — read from a configuration, a user's workflow, an agent's plan — and run, stepped,
  inspected or sent over the wire one operation at a time;
- handlers chosen and nested at run time, in any order: okay-kernel's TCK is a thousand random programs with
  handlers nested at random, and it runs on the machines;
- the whole of the control: `shift0`/reset, answer-type modification, interceptors that keep the row, a rest that is
  a value of data to print, audit, store or send;
- the specification: one reference semantics, a reference interpreter and the TCK digest, that every fast path is
  checked against.

The fast paths are the compiled cases of the same semantics: contexts for the effects answered at once, the language's
errors for the ones never resumed, resumable state machines for the ones resumed many times — and the machine for
everything else, and as the yardstick.
