require_relative '../../swmm_helper'

# Swmm::Input.parse / read: .inp text -> the contract Hash, without the engine.
RSpec.describe Swmm::Input, '.parse' do
  # As the GUI writes a model: ;; headers, inline comments, CRLF, a BOM, lower-case and padded section names, tabs,
  # quoted labels, short rows, dated and elapsed time series, continuation lines.
  let(:gui) do
    <<~INP.gsub("\n", "\r\n").prepend("\uFEFF")
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
  end

  let(:parsed) { described_class.parse(gui) }

  it 'reads rows by the section columns' do
    expect(parsed[:junctions]).to eq([{ name: 'J1', elevation: 120.757, max_depth: 4.213, init_depth: 0, surcharge_depth: 0, ponded_area: 0 },
                                      { name: 'J2', elevation: 119.5 }]), 'comments, tabs and short rows'
    expect(parsed[:outfalls]).to eq([{ name: 'O1', elevation: 106.743, type: 'FREE', gated: false }]), 'inactive columns take no token'
    expect(parsed[:xsections].last).to eq(link: 'C2', shape: 'RECT_OPEN', geom1: 1, geom2: 2)
    expect(parsed[:dwf]).to eq([{ node: 'J1', constituent: 'FLOW', average: 0.5, patterns: ['', '', '', ''] }]), 'quoted blanks'
    expect(parsed[:labels]).to eq([{ x: 10, y: 20, text: 'Main trunk' }])
    expect(parsed[:coordinates]).to eq([{ node: 'J1', x: -13_156.768, y: 206_267.671 }])
  end

  it 'reads options typed' do
    expect(parsed[:options]).to eq({ flow_units: 'LPS', flow_routing: 'DYNWAVE', start_date: Date.new(2026, 3, 23), start_time: '08:00:00',
                                     report_start_date: Date.new(2026, 3, 23), report_start_time: '8:30:00', report_step: Swmm::TimeStep.new(300),
                                     routing_step: Swmm::TimeStep.new(30), allow_ponding: false, variable_step: 0.75 }), 'decimal hours become a clock'
  end

  it 'reads the title without comments' do
    expect(parsed[:title]).to eq(['North network'])
  end

  it 'reads time series as the engine does' do
    q1, q2, q3 = parsed[:timeseries]
    expect(q1[:points]).to eq([['03/23/2026 15:00', 0.88], ['03/23/2026 16:00', 1.17], ['03/23/2026 17:30', 1.5], ['03/24/2026 0:15:00', 2]]),
                           'a date holds for the next times of the series; several entries per line'
    expect(q2).to eq({ name: 'Q2', points: [[0, 0], [1.5, 10]] }), 'elapsed hours'
    expect(q3).to eq(name: 'Q3', file: 'C:\\data\\rain gauge.dat')
  end

  it 'reads curves and patterns over several lines' do
    expect(parsed[:curves]).to eq([{ name: 'P1', type: 'PUMP1', points: [[0, 1], [1, 2], [2, 3]] }])
    expect(parsed[:patterns]).to eq([{ name: 'D1', type: 'DAILY', factors: [1.0, 1.0, 1.0, 1.0, 1.2, 1.2, 0.8] }])
  end

  it 'reads the report, the map and the backdrop' do
    expect(parsed[:report]).to eq({ input: false, nodes: %w[J1 J2 O1], links: 'ALL' }), 'ids of every NODES line'
    expect(parsed[:map]).to eq(dimensions: { values: [-20_181.53, 200_591.646, -10_895.126, 208_707.123] }, units: { value: 'NONE' })
    expect(parsed[:backdrop]).to eq(file: { path: 'C:\\Users\\a\\Desktop\\b2.jpg' })
  end

  it 'writes back what it reads' do
    inp = described_class.new(parsed).to_inp
    expect(described_class.new(described_class.parse(inp)).to_inp).to eq(inp), 'the file it writes reads back to the same file (defaults written)'
    expect(described_class.parse(inp)[:junctions].last).to eq(name: 'J2', elevation: 119.5, max_depth: 0, init_depth: 0, surcharge_depth: 0, ponded_area: 0)
    expect(inp).to include('REPORT_START_TIME    8:30:00')
    expect(inp).to include(%(Q3 FILE "C:\\data\\rain gauge.dat"))
  end

  it 'round-trips the whole contract' do
    Dir.mktmpdir do |dir|
      inp = described_class.new(SwmmFixtures.full(dir)).to_inp
      read = described_class.parse(inp)
      again = described_class.new(read).to_inp
      expect(again.lines.map(&:rstrip).reject(&:empty?)).to eq(inp.lines.map(&:rstrip).reject(&:empty?)), 'every section, line by line'
      expect(described_class.parse(again)).to eq(read)
      expect(read.keys.sort).to eq(SwmmFixtures.full(dir).keys.sort), 'every section of the contract fixture'
    end
  end

  it 'keeps a row that does not fit its columns as tokens' do
    text = "[JUNCTIONS]\nJ1 10 3 0 0 0 99\nJ2 high\n[CONDUITS]\nC1 J1 J2 100\n"
    data = described_class.parse(text)
    expect(data[:junctions]).to eq([%w[J1 10 3 0 0 0 99], %w[J2 high]]), 'a token too many, a value of another type'
    expect(data[:conduits]).to eq([%w[C1 J1 J2 100]]), 'a required column missing'
    expect(described_class.new(data).to_inp).to include('J1 10 3 0 0 0 99'), 'written as given'
  end

  it 'only reads the sections asked for' do
    data = described_class.parse("#{gui}\n[MYSECTION]\nwhatever\n", only: %i[junctions coordinates])
    expect(data.keys).to eq(%i[junctions coordinates]), 'unknown sections are not read either'
    expect(described_class.parse(gui, only: [:storage])).to eq({}), 'a section the file does not have'
    expect { described_class.parse(gui, only: [:pipes]) }.to raise_error(ArgumentError)
  end

  it 'raises, with every line, for what the contract cannot hold' do
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
    expect { described_class.parse(text) }.to raise_error(Swmm::InvalidInput) { |error|
      expect(error.errors.map { it[:path] }).to eq(['options.FLOW_UNIT (line 3)', 'options.start_date (line 4)', '[PIPES] (line 5)',
                                                    'timeseries.T1 (line 8)', 'report.LID (line 10)'])
    }
  end

  it 'reads Windows-1252 text' do
    text = "[TITLE]\nRede de \xE1guas pluviais\n".b
    expect(described_class.parse(text)[:title]).to eq(['Rede de águas pluviais'])
  end

  it 'takes a path in read' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'model.inp')
      File.binwrite(path, gui)
      expect(described_class.read(path)).to eq(parsed)
      expect(described_class.read(path, only: [:junctions])).to eq(parsed.slice(:junctions))
    end
  end

  # The engine runs a model read back exactly as it runs the file.
  context 'with the engine', :libswmm5 do
    it 'gives the same results for a model read back' do
      Dir.mktmpdir do |dir|
        model = SwmmFixtures.full(dir)
        path = File.join(dir, 'full.inp')
        described_class.new(model).write(path)
        ran = Swmm.run(path)
        again = Swmm.run(described_class.read(path))
        expect(ran).to be_ok, ran.error.inspect
        expect(again.to_h.except(:files)).to eq(ran.to_h.except(:files))
      end
    end
  end
end
