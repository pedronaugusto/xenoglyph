# Rivals

C harnesses running xenoglyph's bench rows through the rivals, by hand,
never by CI, with the rivals' sources outside the repository:

```
git clone --depth 1 --branch v3.0.0 https://github.com/Tehreer/SheenBidi.git $SHEEN
cc -O2 -DSB_CONFIG_UNITY -I$SHEEN/Headers -I$SHEEN/Source $SHEEN/Source/SheenBidi.c \
  bench/rivals/bidi.c -I$(brew --prefix icu4c)/include -L$(brew --prefix icu4c)/lib -licuuc \
  -o bidi-rivals && ./bidi-rivals
```

`bidi.c` is `bench/bidi.zig`'s rows (the same paragraphs, from
`sentences.inc`, and line ends) through SheenBidi 3.0.0 and ICU4C's ubidi.

`encoding_rs/` is a Cargo project on encoding_rs 0.8.42 (Cargo.lock
committed). `cargo run --release -- digests > ../../ucd/whatwg/encoding_rs/digests.txt`
writes the interop digests the suite checks: per encoding, every input of one
and two bytes and the longer ones each decoder reads, decoded without BOM
handling, and every scalar value encoded as one stream with HTML references.
