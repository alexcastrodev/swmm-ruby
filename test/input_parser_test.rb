# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Swmm::Input.parse / read: .inp text -> the contract Hash, without the engine.
class InputParserTest < Minitest::Test
  # As the GUI writes a model: ;; headers, inline comments, CRLF, a BOM, lower-case and padded section names, tabs,
  # quoted labels, short rows, dated and elapsed time series, continuation lines.
  GUI = <<~INP.gsub("\n", "\r\n").prepend("\uFEFF")
    [TITLE]
    ;;Project Title/Notes
    North network

    [OPTIONS]
    ;;Option             Value
    FLOW_UNITS           LPS
    flow_routing         dynwave
    START_DATE           03/23/2026
    START_TIME           08:00:00
    REPORT_START_DATE    03/23/2026
    REPORT_START_TIME    8.5
    REPORT_STEP          00:05:00
    ROUTING_STEP         0:00:30
    ALLOW_PONDING        NO
    VARIABLE_STEP        0.75

    [junctions]
    ;;Name           Elevation  MaxDepth   InitDepth  SurDepth   Aponded
    ;;-------------- ---------- ---------- ---------- ---------- ----------
    J1               120.757    4.213      0          0          0         ; upstream
    J2\t119.5
    [ OUTFALLS ]
    O1               106.743    FREE                        NO

    [CONDUITS]
    C1               J1               J2               23.800     0.013      0          0          0          0
    C2               J2               O1               10         0.013      0          0

    [XSECTIONS]
    C1               CIRCULAR     0.3000           0          0          0          1
    C2               RECT_OPEN    1                2

    [INFLOWS]
    J1               FLOW             Q1               FLOW     1.0      1.0

    [DWF]
    J1               FLOW             0.5              "" "" "" ""

    [TIMESERIES]
    ;;Name           Date       Time       Value
    Q1               03/23/2026 15:00      0.88
    Q1                          16:00      1.17
    Q1               17:30 1.5 03/24/2026 0.25 2
    Q2               0 0 1.5 10
    Q3               FILE "C:\\data\\rain gauge.dat"

    [CURVES]
    P1               PUMP1        0      1
    P1                            1      2      2      3

    [PATTERNS]
    D1               DAILY        1.0  1.0  1.0  1.0
    D1                            1.2  1.2  0.8

    [REPORT]
    INPUT      NO
    NODES      J1 J2
    NODES      O1
    LINKS ALL

    [LABELS]
    10 20 "Main trunk"

    [MAP]
    DIMENSIONS -20181.530 200591.646 -10895.126 208707.123
    Units      None

    [BACKDROP]
    FILE       "C:\\Users\\a\\Desktop\\b2.jpg"

    [COORDINATES]
    J1               -13156.768         206267.671
  INP

  def parsed = @parsed ||= Swmm::Input.parse(GUI)

  def test_reads_rows_by_the_section_columns
    assert_equal [{ name: "J1", elevation: 120.757, max_depth: 4.213, init_depth: 0, surcharge_depth: 0, ponded_area: 0 },
                  { name: "J2", elevation: 119.5 }], parsed[:junctions], "comments, tabs and short rows"
    assert_equal [{ name: "O1", elevation: 106.743, type: "FREE", gated: false }], parsed[:outfalls], "inactive columns take no token"
    assert_equal({ link: "C2", shape: "RECT_OPEN", geom1: 1, geom2: 2 }, parsed[:xsections].last)
    assert_equal [{ node: "J1", constituent: "FLOW", average: 0.5, patterns: ["", "", "", ""] }], parsed[:dwf], "quoted blanks"
    assert_equal [{ x: 10, y: 20, text: "Main trunk" }], parsed[:labels]
    assert_equal [{ node: "J1", x: -13_156.768, y: 206_267.671 }], parsed[:coordinates]
  end

  def test_reads_options_typed
    assert_equal({ flow_units: "LPS", flow_routing: "DYNWAVE", start_date: Date.new(2026, 3, 23), start_time: "08:00:00",
                   report_start_date: Date.new(2026, 3, 23), report_start_time: "8:30:00", report_step: "00:05:00",
                   routing_step: "0:00:30", allow_ponding: false, variable_step: 0.75 }, parsed[:options], "decimal hours become a clock")
  end

  def test_reads_the_title_without_comments
    assert_equal ["North network"], parsed[:title]
  end

  def test_reads_time_series_as_the_engine_does
    q1, q2, q3 = parsed[:timeseries]
    assert_equal [["03/23/2026 15:00", 0.88], ["03/23/2026 16:00", 1.17], ["03/23/2026 17:30", 1.5], ["03/24/2026 0:15:00", 2]],
                 q1[:points], "a date holds for the next times of the series; several entries per line"
    assert_equal({ name: "Q2", points: [[0, 0], [1.5, 10]] }, q2, "elapsed hours")
    assert_equal({ name: "Q3", file: "C:\\data\\rain gauge.dat" }, q3)
  end

  def test_reads_curves_and_patterns_over_several_lines
    assert_equal [{ name: "P1", type: "PUMP1", points: [[0, 1], [1, 2], [2, 3]] }], parsed[:curves]
    assert_equal [{ name: "D1", type: "DAILY", factors: [1.0, 1.0, 1.0, 1.0, 1.2, 1.2, 0.8] }], parsed[:patterns]
  end

  def test_reads_report_map_and_backdrop
    assert_equal({ input: false, nodes: %w[J1 J2 O1], links: "ALL" }, parsed[:report], "ids of every NODES line")
    assert_equal({ dimensions: { values: [-20_181.53, 200_591.646, -10_895.126, 208_707.123] }, units: { value: "NONE" } }, parsed[:map])
    assert_equal({ file: { path: "C:\\Users\\a\\Desktop\\b2.jpg" } }, parsed[:backdrop])
  end

  def test_what_it_reads_writes_back
    inp = Swmm::Input.new(parsed).to_inp
    assert_equal inp, Swmm::Input.new(Swmm::Input.parse(inp)).to_inp, "the file it writes reads back to the same file (defaults written)"
    assert_equal({ name: "J2", elevation: 119.5, max_depth: 0, init_depth: 0, surcharge_depth: 0, ponded_area: 0 }, Swmm::Input.parse(inp)[:junctions].last)
    assert_includes inp, "REPORT_START_TIME    8:30:00"
    assert_includes inp, %(Q3 FILE "C:\\data\\rain gauge.dat")
  end

  def test_the_whole_contract_round_trips
    Dir.mktmpdir do |dir|
      inp = Swmm::Input.new(Fixtures.full(dir)).to_inp
      parsed = Swmm::Input.parse(inp)
      again = Swmm::Input.new(parsed).to_inp
      assert_equal inp.lines.map(&:rstrip).reject(&:empty?), again.lines.map(&:rstrip).reject(&:empty?), "every section, line by line"
      assert_equal parsed, Swmm::Input.parse(again)
      assert_equal Fixtures.full(dir).keys.sort, parsed.keys.sort, "every section of the contract fixture"
    end
  end

  def test_a_row_that_does_not_fit_its_columns_is_kept_as_tokens
    text = "[JUNCTIONS]\nJ1 10 3 0 0 0 99\nJ2 high\n[CONDUITS]\nC1 J1 J2 100\n"
    data = Swmm::Input.parse(text)
    assert_equal [%w[J1 10 3 0 0 0 99], %w[J2 high]], data[:junctions], "a token too many, a value of another type"
    assert_equal [%w[C1 J1 J2 100]], data[:conduits], "a required column missing"
    assert_includes Swmm::Input.new(data).to_inp, "J1 10 3 0 0 0 99", "written as given"
  end

  def test_only_reads_the_sections_asked_for
    data = Swmm::Input.parse("#{GUI}\n[MYSECTION]\nwhatever\n", only: %i[junctions coordinates])
    assert_equal %i[junctions coordinates], data.keys, "unknown sections are not read either"
    assert_equal({}, Swmm::Input.parse(GUI, only: [:storage]), "a section the file does not have")
    assert_raises(ArgumentError) { Swmm::Input.parse(GUI, only: [:pipes]) }
  end

  def test_what_the_contract_cannot_hold_raises_with_every_line
    text = <<~INP
      [OPTIONS]
      FLOW_UNITS LPS
      FLOW_UNIT LPS
      START_DATE 2026-03-23
      [PIPES]
      P1 1 2
      [TIMESERIES]
      T1 0 1 2
      [REPORT]
      LID L1 S1 out.txt
    INP
    error = assert_raises(Swmm::InvalidInput) { Swmm::Input.parse(text) }
    assert_equal ["options.FLOW_UNIT (line 3)", "options.start_date (line 4)", "[PIPES] (line 5)", "timeseries.T1 (line 8)",
                  "report.LID (line 10)"], error.errors.map { _1[:path] }
  end

  def test_reads_windows_1252_text
    text = "[TITLE]\nRede de \xE1guas pluviais\n".b
    assert_equal ["Rede de águas pluviais"], Swmm::Input.parse(text)[:title]
  end

  def test_read_takes_a_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, "model.inp")
      File.binwrite(path, GUI)
      assert_equal parsed, Swmm::Input.read(path)
      assert_equal parsed.slice(:junctions), Swmm::Input.read(path, only: [:junctions])
    end
  end
end

# The engine runs a model read back exactly as it runs the file.
class InputParserEngineTest < Minitest::Test
  include NeedsEngine

  def test_a_model_read_back_gives_the_same_results
    Dir.mktmpdir do |dir|
      model = Fixtures.full(dir)
      path = File.join(dir, "full.inp")
      Swmm::Input.new(model).write(path)
      ran = Swmm.run(path)
      again = Swmm.run(Swmm::Input.read(path))
      assert ran.ok?, ran.error.inspect
      assert_equal ran.to_h.except(:files), again.to_h.except(:files)
    end
  end
end
