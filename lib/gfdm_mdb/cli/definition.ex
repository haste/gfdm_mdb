defmodule GfdmMdb.Cli.Definition do
  @moduledoc "Command specifications shared by argparse parsing and help."

  @options [
    output: %{short: ?o, help: "Write to FILE."},
    json: %{action: {:store, true}, help: "Print console reports as JSON, including failures."},
    force: %{action: {:store, true}, help: "Replace an existing output file."},
    dry_run: %{action: {:store, true}, help: "Preview without writing a file."},
    in_place: %{action: {:store, true}, help: "Replace the input file."},
    input_schema_version: %{
      type: {:integer, Enum.to_list(1..6)},
      help: "Specify the input XML schema (1 to 6). Required for empty XML."
    },
    output_format: %{
      type: {:atom, [:binary, :xml, :json]},
      help: "Set the database file format. Otherwise use its extension."
    },
    encrypted: %{
      action: {:store, true},
      help: "Enable MDBE. --no-encrypted disables it. Defaults to source encryption."
    },
    identity: %{help: "Set the release identity. Requires JSON output."},
    records: %{action: {:store, true}, help: "List records."},
    id: %{type: :integer, help: "Select a record by ID."},
    kind: %{
      type: {:atom, [:songs, :courses]},
      help: "Defaults to songs, or both when using inspect --records."
    },
    strict: %{action: {:store, true}, help: "Treat warnings as verification failures."},
    target: %{
      type: {:binary, ~w(100 101 102 202 203:1 203:2 203:3 203:4 203:5 203:6)},
      help: "Convert to 100, 101, 102, 202, or 203:1 through 203:6."
    },
    defaults: %{help: "Fill missing song fields from JSON during conversion."},
    overrides: %{help: "Read per-song conversion overrides."},
    allow_loss: %{
      action: {:store, true},
      help: "Allow conversion to remove fields. Missing values still need defaults."
    },
    record: %{help: "Read a new record from JSON."},
    new_id: %{type: :integer, help: "Assign the cloned record's ID."},
    patch: %{help: "Read record changes from JSON."},
    set: %{action: :append, help: "Assign a field or dotted object path. Applied in order."},
    keys: %{help: "Read complete sort keys from JSON."},
    select: %{
      type: {:atom, [:title, :artist, :both]},
      help: "Select ranks to rebuild. Defaults to title."
    },
    use_stored_keys: %{
      action: {:store, true},
      help: "Use stored strings where ASCII sort keys are missing."
    },
    clear_missing_kana: %{
      action: {:store, true},
      help: "Clear existing kana ranks where no kana key is supplied."
    }
  ]
  @options Map.new(@options, fn {name, option} ->
             defaults = %{
               name: name,
               long: String.to_charlist("-" <> String.replace(Atom.to_string(name), "_", "-")),
               type: if(option[:action] == {:store, true}, do: :boolean, else: :binary)
             }

             {name, Map.merge(defaults, option)}
           end)

  @common [:json, :dry_run, :input_schema_version, :output_format, :encrypted, :identity]
  @destinations %{
    none: [],
    in_place: [:output, :force, :in_place]
  }
  @commands [
    inspect: %{
      output: :none,
      about: "Inspect database metadata or records.",
      options: [:json, :records, :id, :kind, :input_schema_version],
      notes: "Choose --records or --id. --kind requires one of them."
    },
    verify: %{
      output: :none,
      about: "Validate records and report compatibility warnings.",
      options: [:json, :strict, :input_schema_version],
      notes: "Reports the first structural error. Assets are not inspected."
    },
    convert: %{
      about: "Convert database encoding or schema.",
      options: @common ++ [:target, :defaults, :overrides, :allow_loss],
      notes:
        "Use --output database.json for editable JSON. Rebuild with a native output file.\n\n--defaults, --overrides, and --allow-loss require --target."
    },
    add: %{
      about: "Add a record from JSON.",
      options: @common ++ [:record, :kind],
      required: [:record],
      notes:
        "Use inspect INPUT --id ID --json to extract an existing record. The record must contain every field required by the schema."
    },
    clone: %{
      about: "Clone a record with a new ID.",
      options: @common ++ [:id, :new_id, :patch, :set, :kind],
      required: [:id, :new_id],
      notes: "A patched ID must match --new-id."
    },
    edit: %{
      about: "Edit selected record fields.",
      options: @common ++ [:id, :patch, :set, :kind],
      required: [:id],
      notes: "Requires --patch or --set. Unchanged values are reported."
    },
    remove: %{
      about: "Remove a record by ID.",
      options: @common ++ [:id, :kind],
      required: [:id]
    },
    reindex: %{
      about: "Rebuild sort ranks from supplied keys.",
      options: @common ++ [:keys, :select, :use_stored_keys, :clear_missing_kana],
      notes:
        "Kana keys require category codes. Clearing stored kana ranks requires --clear-missing-kana. Defaults to --select title."
    }
  ]
  @commands Map.new(@commands, fn {name, definition} ->
              definition = Map.put_new(definition, :output, :in_place)

              {Atom.to_string(name),
               Map.update!(
                 definition,
                 :options,
                 &(&1 ++ Map.fetch!(@destinations, definition.output))
               )}
            end)

  @spec command(String.t()) :: map()
  def command(name), do: Map.fetch!(@commands, name)

  @spec cli(boolean(), String.t() | nil) :: map()
  def cli(required \\ true, help_command \\ nil) do
    %{
      help: "Use gfdm_mdb COMMAND --help for options. Use --json for machine-readable reports.",
      commands:
        Map.new(@commands, fn {name, definition} ->
          {String.to_charlist(name), command(name, definition, required, help_command)}
        end)
    }
  end

  ###
  ### Helpers
  ###

  defp command(name, definition, required, help_command) do
    input = %{
      name: :input,
      type: :binary,
      nargs: :list,
      action: :extend,
      required: required,
      help: {"INPUT", ["Input database."]}
    }

    help = %{
      name: :help,
      long: ~c"-help",
      short: ?h,
      action: {:store, true},
      help: {"[--help]", ["Show help for this command."]}
    }

    options =
      Enum.flat_map(definition.options, &option(&1, Map.get(definition, :required, []), required))

    # Treat arguments after -- as file paths, even if they start with a dash.
    trailing = Map.merge(input, %{long: ~c"-", nargs: :all, required: false, help: :hidden})

    %{
      arguments: [input, trailing, help | options],
      help:
        if name == help_command do
          Enum.join(
            [
              definition.about,
              Map.get(definition, :notes, ""),
              output_help(definition.output)
            ],
            "\n\n"
          )
        else
          definition.about
        end
    }
  end

  defp option(name, required, enforce) do
    option = Map.fetch!(@options, name) |> Map.put(:required, enforce and name in required)

    if name == :encrypted do
      [option, %{option | long: ~c"-no" ++ option.long, action: {:store, false}, help: :hidden}]
    else
      [option]
    end
  end

  defp output_help(:in_place),
    do:
      "Requires --output unless --dry-run or --in-place is used. In-place writes retain input encoding unless explicitly converted."

  defp output_help(:none), do: ""
end
