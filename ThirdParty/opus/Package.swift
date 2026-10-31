// swift-tools-version: 6.0
import PackageDescription

// libopus 1.5.2, vendored unmodified from the official Xiph release tarball
// (https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz, sha256
// 65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1;
// BSD-3-Clause style licence in Sources/COpus/COPYING). `vendor.sh`
// re-creates Sources/COpus from that tarball and documents the pruning.
//
// Build: the portable float path (no SIMD / fixed-point variants), no
// dnn/ features (Deep PLC, DRED, OSCE are opt-in and never enabled), stack
// scratch through alloca (`USE_ALLOCA`), so encode / decode never touch the
// heap after the encoder / decoder state is created.
let package = Package(
    name: "opus",
    platforms: [
        .macOS("15.0"),
        .iOS(.v18),
    ],
    products: [
        .library(name: "COpus", targets: ["COpus"]),
    ],
    targets: [
        .target(
            name: "COpus",
            path: "Sources/COpus",
            exclude: ["COPYING", "AUTHORS"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("src"),
                .define("OPUS_BUILD"),
                .define("USE_ALLOCA"),
                .define("HAVE_LRINTF"),
                .define("HAVE_LRINT"),
                .define("PACKAGE_VERSION", to: "\"1.5.2\""),
                // Always optimized, also in Debug app builds: the decoder runs
                // on the audio render thread, and libopus at -O0 is several
                // times slower (it warns about exactly that).
                // -Wno-shorten-64-to-32: one benign implicit long → opus_int32
                // conversion in upstream src/extensions.c (pointer difference
                // of a packet bounded to 1275 bytes); the vendored sources stay
                // byte-identical to the tarball instead.
                .unsafeFlags(["-O2", "-Wno-shorten-64-to-32"]),
            ]
        ),
    ]
)
