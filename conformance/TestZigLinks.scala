package okay.rust

import java.nio.file.{Files, Path, Paths}
import okay.foreign.{ForeignWorker, WireConformance}

/**
 * okay-zig's worker against okay's ONE conformance body (`WireConformance`), over a child process's pipes and IN THIS
 * PROCESS through FFM. Lives in okay-zig (`conformance/`); run from okay's `okay-rust` JVM tests, which have FFM — in
 * a clone of okay, so okay's own tree is not touched:
 *
 *   okay-zig$ zig build worker -Doptimize=ReleaseSafe
 *   $ git clone --local ~/work/my/okay /tmp/okay-conf && cd /tmp/okay-conf
 *   $ cp ~/work/my/okay-zig/conformance/TestZigLinks.scala okay-rust/.jvm/src/test/scala/okay/rust/
 *   $ sbt "set every Test / testOptions := Seq(Tests.Argument(TestFrameworks.MUnit, \"--include-tags=Live\"))" \
 *         "okayRustJVM/testOnly okay.rust.TestZig*"
 *
 * The conformance tests are tagged `Live`, which okay's build excludes by default: hence the `set`.
 *
 * The worker's directory is OKAY_ZIG, by default ~/work/my/okay-zig. Programs as data and direct style (each call a
 * task of the worker's Io, waiting while the host works); no streams (a muxed worker's): those tests are skipped.
 */
object ZigWorker:
  val dir: Path = Paths.get(sys.env.getOrElse("OKAY_ZIG", sys.props("user.home") + "/work/my/okay-zig"))
  val binary: Path = dir.resolve("zig-out/bin/zig-worker")
  val library: Path = dir.resolve("zig-out/lib").resolve(NativeLib.fileName("okay-zig-worker"))

/** (Zig, pipes), JSON */
class TestZigPipes extends WireConformance:
  override def munitIgnore: Boolean = !Files.isExecutable(ZigWorker.binary)
  lazy val engine: ForeignWorker = ForeignWorker.speaking(Seq(ZigWorker.binary.toString))
  override def afterAll(): Unit = if !munitIgnore then engine.close()

  test("the hello: a Zig worker, on JSON lines") {
    assertEquals(engine.pythonVersion, "zig")
    assertEquals(engine.wire, "json/none")
  }

/** (Zig, FFM): the same worker in this process, a library of okay's C ABI */
class TestZigFfm extends WireConformance:
  override def munitIgnore: Boolean = !Files.exists(ZigWorker.library)
  lazy val engine: ForeignWorker = ForeignWorker.inProcess(ZigWorker.library)
  override def afterAll(): Unit = if !munitIgnore then engine.close()

  test("in-process: a Zig worker, on JSON, no compression") {
    assertEquals(engine.pythonVersion, "zig")
    assert(engine.wire.startsWith("json/none"), engine.wire)
  }
