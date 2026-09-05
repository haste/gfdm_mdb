defmodule GfdmMdb.XmlTest do
  use ExUnit.Case, async: true
  alias GfdmMdb.{Database, Fixture}

  for version <- 1..6 do
    test "XML version #{version} is detected and preserves Unicode and record values" do
      database = Fixture.database(203, unquote(version))
      text = "日本語 & <tag> \"quoted\"\r\n"
      song = Map.put(hd(database.songs), "title_name", text)

      song =
        if unquote(version) > 1 do
          Map.put(song, "modern_movie_disp_id", -1)
        else
          song
        end

      database = %{database | songs: [song]}
      assert {:ok, xml} = GfdmMdb.encode(database)
      assert String.contains?(xml, "&amp;")
      assert {:ok, ^database} = GfdmMdb.decode(xml)
    end
  end

  test "empty XML needs an explicit schema hint" do
    database = Database.new(203, 4)

    assert {:ok, xml} = GfdmMdb.encode(database)
    assert {:error, %{code: :schema_hint}} = GfdmMdb.decode(xml)
    assert {:ok, ^database} = GfdmMdb.decode(xml, schema_version: 4)
  end

  test "XML record sizes are required wire header values" do
    assert {:ok, xml} = GfdmMdb.encode(Fixture.database(203, 6))

    for {field, size} <- [{"record_sz", 300}, {"course_sz", 40}] do
      changed =
        String.replace(xml, "<#{field} __type=\"s16\">#{size}", "<#{field} __type=\"s16\">1")

      assert {:error, %{code: :header, path: path}} = GfdmMdb.decode(changed)
      assert path == "native.header." <> String.replace_suffix(field, "_sz", "_size")
    end
  end

  test "rejects mixed schemas, invalid annotations, duplicate fields, hierarchy and counts" do
    assert {:ok, xml} = GfdmMdb.encode(Fixture.database(203, 6))

    invalids = [
      String.replace(xml, "<is_classic_seq __type=\"u8\">0</is_classic_seq>", ""),
      String.replace(xml, "__count=\"15\"", "__count=\"14\""),
      Regex.replace(~r/(<xg_diff_list[^>]+>)[^<]+/, xml, "\\g{1}0"),
      String.replace(xml, "<b_long __type=\"bool\">0", "<b_long __type=\"bool\">2"),
      String.replace(xml, "<bpm __type=\"u16\">120", "<bpm __type=\"s16\">120"),
      String.replace(xml, "<bpm __type=\"u16\">120", "<bpm __type=\"u16\">65536"),
      String.replace(xml, "<bpm __type=\"u16\">120", "<bpm extra=\"x\" __type=\"u16\">120"),
      String.replace(xml, "<mdb>", "<mdb xmlns=\"example\">"),
      String.replace(xml, "<header>", "<unexpected>"),
      String.replace(xml, "<record_nr __type=\"s16\">1", "<record_nr __type=\"s16\">2"),
      String.replace(
        xml,
        "<bpm __type=\"u16\">120</bpm>",
        "<bpm __type=\"u16\">120</bpm><bpm __type=\"u16\">120</bpm>"
      ),
      String.replace(xml, ~s(__type="u16"), ~s(__type="u16" __type="u16")),
      String.replace(xml, ~s(__type="u16"), ~s(__type="s16" __type="u16")),
      String.replace(xml, ~s(__type="u16"), ~s(__type="u16" __type="s16")),
      String.replace(xml, ~s(__count="128"), ~s(__count="128" __count="128")),
      xml <> "<extra/>",
      xml <> <<255>>,
      String.replace(xml, "</mdb>", "")
    ]

    for invalid <- invalids do
      assert({:error, _error} = GfdmMdb.decode(invalid))
    end

    assert {:ok, v1} = GfdmMdb.encode(Fixture.database(203, 1))
    [_, song] = Regex.run(~r/(<mdb_data>.*?<\/mdb_data>)/s, v1)
    mixed = String.replace(xml, "<mdb_course>", song <> "<mdb_course>", global: false)
    assert {:error, _error} = GfdmMdb.decode(mixed)
    assert {:error, _error} = GfdmMdb.decode(xml, schema_version: 1)
  end

  test "custom entity references fail with or without a declaration" do
    assert {:ok, xml} = GfdmMdb.encode(Fixture.database(203, 6))

    for declaration <- ["", ~s(<!DOCTYPE mdb [<!ENTITY title "Expanded">]>)] do
      invalid =
        xml
        |> String.replace("<mdb>", declaration <> "<mdb>")
        |> String.replace(
          ~s(<title_name __type="str"></title_name>),
          ~s(<title_name __type="str">&title;</title_name>)
        )

      assert {:error, %{code: :xml, message: message}} = GfdmMdb.decode(invalid)
      assert message =~ "&title;"
    end
  end

  test "predefined and numeric entities decode while escaped entity names stay literal" do
    assert {:ok, xml} = GfdmMdb.encode(Fixture.database(203, 6))

    xml =
      String.replace(
        xml,
        ~s(<title_name __type="str"></title_name>),
        ~s(<title_name __type="str">&lt;&gt;&amp;&apos;&quot;&#65;&#x42;&amp;title;</title_name>)
      )

    assert {:ok, database} = GfdmMdb.decode(xml)
    assert hd(database.songs)["title_name"] == ~s(<>&'"AB&title;)
    assert {:ok, bytes} = GfdmMdb.encode(database)
    assert {:ok, ^database} = GfdmMdb.decode(bytes)
  end

  test "comments are ignored and CDATA preserves literal text" do
    database = Fixture.database(203, 6)
    assert {:ok, xml} = GfdmMdb.encode(database)

    commented = String.replace(xml, "<mdb>", "<!-- Music database -->\n<mdb>")
    assert {:ok, ^database} = GfdmMdb.decode(commented)

    text = ~s(<tag> "text" &amp; &title;)

    cdata =
      String.replace(
        xml,
        ~s(<title_name __type="str"></title_name>),
        ~s(<title_name __type="str"><![CDATA[#{text}]]></title_name>)
      )

    assert %{database: expected, errors: []} =
             Database.edit(database, 1120, %{"title_name" => text})

    assert {:ok, ^expected} = GfdmMdb.decode(cdata)
  end
end
