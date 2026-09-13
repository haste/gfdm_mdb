# GFDM MDB

GFDM MDB is a command-line tool for inspecting, editing, and converting
GuitarFreaks, DrumMania, and GITADORA music databases.

Supports binary MDB/MDBE `100`, `101`, `102`, and `202`, typed XML `203`
versions 1 to 6, and editable JSON.

See [MDB format](MDB_FORMAT.md) for the binary layouts, field meanings, and
MDBE cipher.

## Download

Download the latest standalone executable from the
[GitHub Releases page](https://github.com/haste/gfdm_mdb/releases/latest):

- [Linux x86-64](https://github.com/haste/gfdm_mdb/releases/latest/download/gfdm_mdb_linux_x86_64)
- [Windows x86-64](https://github.com/haste/gfdm_mdb/releases/latest/download/gfdm_mdb_windows_x86_64.exe)

## Commands

```text
gfdm_mdb inspect INPUT [--records | --id ID] [options]
gfdm_mdb verify INPUT [options]
gfdm_mdb convert INPUT --output FILE [options]
gfdm_mdb add INPUT --record FILE --output FILE
gfdm_mdb clone INPUT --id ID --new-id ID --output FILE [options]
gfdm_mdb edit INPUT --id ID --output FILE [options]
gfdm_mdb remove INPUT --id ID --output FILE
gfdm_mdb reindex INPUT --output FILE [options]
```

```sh
gfdm_mdb inspect mdbe.bin --records
gfdm_mdb verify mdbe.bin
```

Export to editable JSON and rebuild the native file:

```sh
gfdm_mdb convert mdbe.bin --output database.json
# Edit database.json before rebuilding.
gfdm_mdb convert database.json --output rebuilt.bin
```

```sh
gfdm_mdb edit mdbe.bin --id 1120 --set 'title_ascii=New title' \
  --set 'bpm=150' --output edited.bin
gfdm_mdb clone mdbe.bin --id 1120 --new-id 5000 --output cloned.bin
```

Use `--kind courses` for course records. Edit and clone accept `--patch FILE`
or repeatable `--set field=value` options.

Use `--dry-run` to preview changes, `--in-place` to update the input directly,
and `--force` to replace an existing output file. `--json` prints console reports
as JSON. Run `gfdm_mdb COMMAND --help` for all options.

## Formats

Input format and encryption are detected automatically. Output follows the
`.json`, `.xml`, or `.bin` extension. Binary encryption is preserved through JSON.
Keep the `native` metadata when editing JSON.

Changing schemas requires `--target`, such as `--target 203:5`. Use `--dry-run`
to check required values before converting.

## Development

The repository uses mise for its pinned Elixir, Erlang, and Zig toolchain:

```sh
mise install
mise exec -- mix deps.get
mise run check
```

Run the CLI from source with `mix gfdm_mdb --help`. Build standalone executables
with `mise run release` (Linux x86-64) or `mise run release-windows` (Windows
x86-64). Outputs are `burrito_out/gfdm_mdb_linux_x86_64` and
`burrito_out/gfdm_mdb_windows_x86_64.exe`.
