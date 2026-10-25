//! encoding_rs's side of xenoglyph's encoding interop and benchmark.
//!
//! `digests`: for each encoding, the SHA-256 of what decoding each input of a
//! fixed set gives (without BOM handling, errors as U+FFFD, each output
//! followed by a 0xFF byte, which UTF-8 never holds), and of what encoding
//! every scalar value, in order, as one stream gives (unmappables as HTML
//! references). `src/testing/encoding_test.zig` builds the same inputs and
//! must reach the same digests.
//!
//! `bench`: bench/encoding.zig's rows, the same texts, timed.
use encoding_rs::Encoding;
use sha2::{Digest, Sha256};
use std::time::Instant;

/// Every encoding of the standard, in xenoglyph's `Encoding` order.
const NAMES: [&str; 40] = [
    "UTF-8", "IBM866", "ISO-8859-2", "ISO-8859-3", "ISO-8859-4", "ISO-8859-5", "ISO-8859-6",
    "ISO-8859-7", "ISO-8859-8", "ISO-8859-8-I", "ISO-8859-10", "ISO-8859-13", "ISO-8859-14",
    "ISO-8859-15", "ISO-8859-16", "KOI8-R", "KOI8-U", "macintosh", "windows-874",
    "windows-1250", "windows-1251", "windows-1252", "windows-1253", "windows-1254",
    "windows-1255", "windows-1256", "windows-1257", "windows-1258", "x-mac-cyrillic", "GBK",
    "gb18030", "Big5", "EUC-JP", "ISO-2022-JP", "Shift_JIS", "EUC-KR", "replacement",
    "UTF-16BE", "UTF-16LE", "x-user-defined",
];

/// Calls `f` with each decoding input for an encoding: every input of one
/// and two bytes for all, and the longer ones each kind of decoder reads.
fn inputs(name: &str, mut f: impl FnMut(&[u8])) {
    for a in 0..=255u8 {
        f(&[a]);
    }
    let single = !matches!(
        name,
        "UTF-8" | "GBK" | "gb18030" | "Big5" | "EUC-JP" | "ISO-2022-JP" | "Shift_JIS" | "EUC-KR" | "UTF-16BE" | "UTF-16LE"
    );
    if single {
        return;
    }
    for a in 0..=255u8 {
        for b in 0..=255u8 {
            f(&[a, b]);
        }
    }
    match name {
        "UTF-8" => {
            for a in 0xe0..=0xefu8 {
                for b in 0..=255u8 {
                    for c in 0..=255u8 {
                        f(&[a, b, c]);
                    }
                }
            }
            for a in 0xf0..=0xf4u8 {
                for b in 0..=255u8 {
                    for c in 0..=255u8 {
                        for d in [0x41u8, 0x80, 0x8f, 0x90, 0xbf, 0xc0] {
                            f(&[a, b, c, d]);
                        }
                    }
                }
            }
        }
        "GBK" | "gb18030" => {
            for a in 0x81..=0xfeu8 {
                for b in 0x30..=0x39u8 {
                    for c in 0x81..=0xfeu8 {
                        for d in 0x30..=0x39u8 {
                            f(&[a, b, c, d]);
                        }
                    }
                    for c in 0..=255u8 {
                        f(&[a, b, c]);
                    }
                }
            }
        }
        "EUC-JP" => {
            for b in 0..=255u8 {
                for c in 0..=255u8 {
                    f(&[0x8f, b, c]);
                }
            }
        }
        "ISO-2022-JP" => {
            let escapes: [&[u8]; 6] = [b"\x1b(B", b"\x1b(J", b"\x1b(I", b"\x1b$@", b"\x1b$B", b"\x1b$("];
            for e in escapes {
                for b in 0..=255u8 {
                    let mut v = e.to_vec();
                    v.push(b);
                    f(&v);
                    for c in 0..=255u8 {
                        let mut v = e.to_vec();
                        v.extend_from_slice(&[b, c]);
                        f(&v);
                    }
                }
                // Two escapes in a row, and one at the end.
                for e2 in escapes {
                    let mut v = e.to_vec();
                    v.extend_from_slice(e2);
                    f(&v);
                    v.push(b'a');
                    f(&v);
                }
            }
            for b in 0..=255u8 {
                for c in 0..=255u8 {
                    f(&[0x1b, b, c]);
                }
            }
        }
        "UTF-16BE" | "UTF-16LE" => {
            let be = name == "UTF-16BE";
            for lead in [0xd800u16, 0xdab5, 0xdbff, 0xdc00] {
                for unit in 0..=0xffffu16 {
                    let (l, u) = if be { (lead.to_be_bytes(), unit.to_be_bytes()) } else { (lead.to_le_bytes(), unit.to_le_bytes()) };
                    f(&[l[0], l[1], u[0], u[1]]);
                }
                for b in 0..=255u8 {
                    let l = if be { lead.to_be_bytes() } else { lead.to_le_bytes() };
                    f(&[l[0], l[1], b]);
                }
            }
        }
        _ => {}
    }
}

/// Every scalar value, in order, as UTF-8.
fn scalars() -> String {
    (0..=0x10ffffu32).filter_map(char::from_u32).collect()
}

fn hex(d: &[u8]) -> String {
    d.iter().map(|b| format!("{b:02x}")).collect()
}

fn digests() {
    let all = scalars();
    println!("# Written by bench/rivals/encoding_rs (`cargo run --release -- digests`) with encoding_rs 0.8.42.");
    println!("# Each encoding: the SHA-256 of its decoding inputs decoded, and of every scalar encoded");
    println!("# (\"-\" for an encoding with no encoder); src/testing/encoding_test.zig reaches the same.");
    for name in NAMES {
        let enc = Encoding::for_label(name.as_bytes()).unwrap();
        let mut decoded = Sha256::new();
        inputs(name, |bytes| {
            let (text, _) = enc.decode_without_bom_handling(bytes);
            decoded.update(text.as_bytes());
            decoded.update([0xff]);
        });
        // Only an encoding that is its own output encoding has an encoder.
        let encoded = if enc.output_encoding() == enc {
            let (bytes, _, _) = enc.encode(&all);
            hex(&Sha256::digest(&bytes))
        } else {
            "-".to_string()
        };
        println!("{name} {} {encoded}", hex(&decoded.finalize()));
    }
}

/// Text for the benchmark rows, from the files bench/encoding.zig reads.
fn texts() -> Vec<(&'static str, String)> {
    let dir = std::env::args().nth(2).unwrap_or_else(|| "../../texts".to_string());
    ["latin", "cyrillic", "cjk"]
        .iter()
        .map(|k| (*k, std::fs::read_to_string(format!("{dir}/{k}.txt")).expect("bench text")))
        .collect()
}

fn time(label: &str, bytes: usize, mut f: impl FnMut()) {
    // The best of ten rounds of enough calls to take about 50 ms.
    let start = Instant::now();
    let mut calls = 0u64;
    while start.elapsed().as_millis() < 50 {
        f();
        calls += 1;
    }
    let mut best = f64::MAX;
    for _ in 0..10 {
        let t = Instant::now();
        for _ in 0..calls {
            f();
        }
        best = best.min(t.elapsed().as_nanos() as f64 / calls as f64);
    }
    println!("{label} {:.1} us {:.0} MB/s", best / 1000.0, bytes as f64 / best * 1000.0);
}

fn bench() {
    let rows: [(&str, &[&str]); 3] = [
        ("latin", &["windows-1252", "ISO-8859-2", "UTF-16LE"]),
        ("cyrillic", &["windows-1251", "KOI8-R", "UTF-16LE"]),
        ("cjk", &["Shift_JIS", "EUC-JP", "ISO-2022-JP", "gb18030", "Big5", "EUC-KR", "UTF-16LE"]),
    ];
    let texts = texts();
    for (kind, names) in rows {
        let text = &texts.iter().find(|t| t.0 == kind).unwrap().1;
        for name in names {
            let enc = Encoding::for_label(name.as_bytes()).unwrap();
            let bytes: Vec<u8> = if enc == encoding_rs::UTF_16LE {
                text.encode_utf16().flat_map(|u| u.to_le_bytes()).collect()
            } else {
                enc.encode(text).0.into_owned()
            };
            let mut decoder = enc.new_decoder_without_bom_handling();
            let mut out = String::with_capacity(decoder.max_utf8_buffer_length(bytes.len()).unwrap());
            time(&format!("decode {kind} {name}"), bytes.len(), || {
                out.clear();
                let mut d = enc.new_decoder_without_bom_handling();
                let _ = d.decode_to_string(&bytes, &mut out, true);
                std::hint::black_box(&out);
            });
            let _ = &mut decoder;
            if enc.output_encoding() == enc {
                let mut buf = Vec::with_capacity(bytes.len() * 2 + 64);
                time(&format!("encode {kind} {name}"), text.len(), || {
                    buf.clear();
                    let mut e = enc.new_encoder();
                    let _ = e.encode_from_utf8_to_vec(text, &mut buf, true);
                    std::hint::black_box(&buf);
                });
            }
        }
    }
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("digests") => digests(),
        Some("bench") => bench(),
        Some("encoded") => {
            let name = std::env::args().nth(2).unwrap();
            let all = scalars();
            let (bytes, _, _) = Encoding::for_label(name.as_bytes()).unwrap().encode(&all);
            use std::io::Write;
            std::io::stdout().write_all(&bytes).unwrap();
        }
        _ => eprintln!("usage: xenoglyph-rival-encoding-rs digests | bench [texts dir]"),
    }
}
