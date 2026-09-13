# MDB format

MDB stores GuitarFreaks and DrumMania song metadata and courses. Integers are
little-endian. Records are packed without alignment or padding between fields.

| Release | Virtual path | Storage | Format | Song stride |
|---|---|---|---:|---:|
| V4 | `/data/product/music/mdb.bin` | Raw | `0x64` | 188 bytes |
| V5 | `/data/product/music/mdb.bin` | Raw | `0x65` | 192 bytes |
| V6 to V8 | `/data/product/music/mdbe.bin` | MDBE | `0x66` | 192 bytes |
| XG1 | `/data/product/music/mdbe_xg.bin` | MDBE | `0xca` | 232 bytes |

MDBE applies to the complete file.

## File layout

```text
0x0000                                            Header
0x0040                                            Song table
0x0040 + record_nr × song_stride                   Course table
0x0040 + record_nr × song_stride + course_nr × 40   EOF
```

Select `song_stride` by format, not `record_sz`. Courses occupy 40 bytes
regardless of `course_sz`.

## Header

| Offset | Type | Field | Notes |
|---:|---|---|---|
| `0x00` | 8 bytes | `id` | ASCII `GF/DMmdb` |
| `0x08` | `s32` | `format` | |
| `0x0c` | `u32` | `chksum` | Unused |
| `0x10` | `u16` | `header_sz` | 64 |
| `0x12` | `u16` | `record_sz` | Legacy size of 188 |
| `0x14` | `u16` | `record_nr` | Song count |
| `0x16` | `u16` | `course_nr` | Course count |
| `0x18` | `u16` | `course_sz` | Legacy size of 36 |
| `0x1a` | 38 bytes | `reserved` | |

Preserve checksum, legacy size fields, and reserved bytes when rebuilding.

## V4 to V8 song records

The first 188 bytes are shared by formats `0x64`, `0x65`, and `0x66`:

| Offset | Type | Field | Notes |
|---:|---|---|---|
| `0x00` | `s32` | `music_id` | |
| `0x04` | `u8[4][4]` | `classics_diff_list` | Guitar, bass, open-pick, drums |
| `0x14` | `u8` | `seq_flag` | Sequence-presence and session flags |
| `0x15` | `u8` | `pad_diff` | Reserved |
| `0x16` | `u8[2]` | `contain_stat` | GF/DM catalog status: 0 absent, 1 new, 2 existing, 3 revived |
| `0x18` | `u8[2]` | `first_classic_ver` | GF/DM classic-series introduction/version values |
| `0x1a` | `u8` | `b_long` | Boolean long-version marker |
| `0x1b` | `u8` | `b_eemall` | Boolean e-Amusement/eemall marker |
| `0x1c` | `u16` | `bpm` | Fixed BPM, or minimum BPM when `bpm2` is nonzero |
| `0x1e` | `u16` | `bpm2` | Maximum BPM, or zero for a single displayed BPM |
| `0x20` | 16 bytes | `title_ascii` | UTF-8 title with NUL termination and zero padding |
| `0x30` | `u16` | `order_ascii` | ASCII-title sort key |
| `0x32` | `u16` | `order_kana` | Kana sort key |
| `0x34` | `u8` | `category_kana` | |
| `0x35` | `u8[2]` | `secret` | GF/DM secret or unlock flags |
| `0x37` | `u8` | `b_session` | Enables the session sequence-availability path |
| `0x38` | `u8` | `speed` | Unknown |
| `0x39` | `u8` | `life` | Gameplay percentage factor |
| `0x3a` | `s8` | `gf_ofst` | |
| `0x3b` | `s8` | `dm_ofst` | |
| `0x3c` | `u8[4][4][8]` | `chart_list` | Instrument × difficulty × metric |

V4 ends at offset `0xbc`. V5 to V8 append four bytes:

| Offset | Type | Field | Notes |
|---:|---|---|---|
| `0xbc` | `u8` | `origin` | Version category |
| `0xbd` | `u8` | `music_type` | |
| `0xbe` | `u8` | `genre` | |
| `0xbf` | `u8` | `is_remaster` | Boolean |

Treat V5's last three tail bytes as reserved.

DrumMania replaces zero `life` with 70 and calculates
`life × chart_chip_count / 100`.

## XG1 song records

Fields shared with V4 to V8 retain their meanings.

| Offset | Type | Field | Notes |
|---:|---|---|---|
| `0x00` | `s32` | `music_id` | |
| `0x04` | `u8[4][4]` | `classics_diff_list` | |
| `0x14` | `u16[3][5]` | `xg_diff_list` | Guitar, drums, bass |
| `0x32` | `u16` | `pad_diff` | |
| `0x34` | `u16` | `seq_flag` | |
| `0x36` | `u16` | `xg_seq_flag` | XG sequence-presence and session flags |
| `0x38` | `u8[2]` | `contain_stat` | |
| `0x3a` | `u8[2]` | `first_ver` | GF/DM introduction versions, distinct from `first_classic_ver` |
| `0x3c` | `u8` | `b_long` | |
| `0x3d` | `u8` | `b_eemall` | |
| `0x3e` | `u16` | `bpm` | |
| `0x40` | `u16` | `bpm2` | |
| `0x42` | 16 bytes | `title_ascii` | |
| `0x52` | `u16` | `order_ascii` | |
| `0x54` | `u16` | `order_kana` | |
| `0x56` | `u8` | `category_kana` | |
| `0x57` | `u8[2]` | `secret` | |
| `0x59` | `u8[2]` | `xg_secret` | XG GF/DM secret or unlock flags |
| `0x5b` | `u8` | `b_session` | |
| `0x5c` | `u8` | `xg_b_session` | Enables the XG session path |
| `0x5d` | `u8` | `speed` | |
| `0x5e` | `u8` | `life` | |
| `0x5f` | `s8` | `gf_ofst` | |
| `0x60` | `s8` | `dm_ofst` | |
| `0x61` | `u8[4][4][8]` | `chart_list` | |
| `0xe1` | `u8` | `origin` | |
| `0xe2` | `u8` | `music_type` | |
| `0xe3` | `u8` | `genre` | |
| `0xe4` | `u8` | `xg_active_effect_type` | Gameplay effect type |
| `0xe5` | `u8` | `xg_movie_disp_type` | |
| `0xe6` | `u8` | `xg_movie_disp_id` | |
| `0xe7` | `u8` | `is_remaster` | |

## Difficulties and chart metrics

Each classic group has an internal slot at index 0 for special records, then
`BASIC`, `ADVANCED`, and `EXTREME` at 1 to 3. Zero generally means an unavailable
chart.

Each XG group has an internal slot at index 0, then `NOVICE`, `REGULAR`,
`EXPERT`, and `MASTER` at 1 to 4. Ratings use hundredths (`150` displays as `1.50`).

`chart_list[instrument][difficulty][metric]` follows classic ordering. Each
eight-byte block has six metrics and two reserved bytes. Metric meanings are
unknown. Chart metrics do not determine availability.

## Sequence flags

| Bit | `seq_flag` | `xg_seq_flag` |
|---:|---|---|
| 0 | Guitar | Guitar |
| 1 | Bass | Bass |
| 2 | Open-pick | Reserved, unused or unknown |
| 3 | Drums | Drums |
| 4 | DrumMania session path | DrumMania XG session path |
| 5 | GuitarFreaks session path | GuitarFreaks XG session path |
| 6 | Reserved, unused or unknown | Reserved, unused or unknown |

Session paths also depend on `b_session` or `xg_b_session`. Preserve undefined
bits when rebuilding.

## Titles

Read `title_ascii` within its field and stop at the first NUL. Author at most
15 UTF-8 bytes with NUL termination and zero padding.
Preserve all 16 raw bytes when editing existing fields.

The title field appears to support fullwidth UTF-8 characters. For example,
`WHITE ｔORNADO` contains a three-byte fullwidth `ｔ`:

```text
57 48 49 54 45 20 ef bd 94 4f 52 4e 41 44 4f 00
```

## Course records

All formats use this course layout:

| Offset | Type | Field | Notes |
|---:|---|---|---|
| `0x00` | `s32` | `course_id` | |
| `0x04` | `u32` | `course_flag` | Bit 0 marks a present course |
| `0x08` | `s32[4]` | `music_id` | Component songs |
| `0x18` | `u8[4][4]` | `classics_diff_list` | |

Preserve the remaining `course_flag` bits when rebuilding.

## MDBE cipher

The key bytes are:

```text
32 2b 2e 35 38 3e 3b 2e 41
```

For plaintext position `i`, let `r = i mod 9`. The one-byte mask is:

```text
mask(i) = (r + 16 × (i mod 8) + (key[r] XOR (127 - r))) AND 0xff
```

For a file of length `n`, encryption and decryption use the same mask indexed
by plaintext position:

```text
stored[n - 1 - i] = plain[i] XOR mask(i)
```

The transform is not symmetric.

Try plaintext first, then MDBE decryption if layout validation fails. Format
numbers alone do not determine encryption.
