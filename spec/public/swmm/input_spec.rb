require_relative '../../swmm_helper'

RSpec.describe Swmm::Input do
  def inp(**sections) = described_class.new(sections).to_inp

  def errors(**sections) = described_class.validate(sections).to_h { [it[:path], it[:message]] }

  it 'gives rows their defaults, rejects blanks in names and quotes them in labels' do
    expect(errors(junctions: [{ name: 'Poço 1', elevation: 10 }])).to eq('junctions[0].name' => 'must not contain blanks')
    expect(inp(tags: [{ type: 'Node', name: 'J1', tag: 'up stream' }])).to include(%(Node J1 "up stream"))
    expect(inp(conduits: [{ name: 'C', from_node: 'A', to_node: 'B', length: 5, roughness: 0.01, in_offset: 0, out_offset: 0 }]))
      .to include('C A B 5 0.01 0 0 0 0')
  end

  it 'normalises values to SWMM syntax' do
    text = inp(options: { flow_units: 'lps', start_date: '2026-03-24', end_time: '01:30', report_step: 900, allow_ponding: true },
               outfalls: [{ name: 'O', elevation: 1, type: 'free', gated: false }])
    expect(text).to include('FLOW_UNITS           LPS')
    expect(text).to include('START_DATE           03/24/2026')
    expect(text).to include('REPORT_STEP          0:15:00')
    expect(text).to include('ALLOW_PONDING        YES')
    expect(text).to include('O 1 FREE NO')
  end

  it 'handles columns that depend on another column' do
    expect(inp(outfalls: [{ name: 'O', elevation: 1, type: 'FIXED', stage_data: 2.5 }])).to include('O 1 FIXED 2.5 NO')
    expect(errors(outfalls: [{ name: 'O', elevation: 1, type: 'FIXED' }])).to eq('outfalls[0].stage_data' => 'is required')
    expect(errors(outfalls: [{ name: 'O', elevation: 1, type: 'FREE', stage_data: 1 }]).keys).to eq(['outfalls[0].stage_data'])
  end

  it 'reports every violation with its path' do
    found = errors(options: { flow_units: 'GALLONS', nope: 1 }, junctions: [{ name: '', elevation: 'x', extra: 1 }, 'not a row'],
                   patterns: [{ name: 'P', type: 'HOURLY', factors: [1] }], bogus: [])
    expect(found.keys.sort).to eq(['input.bogus', 'junctions[0].elevation', 'junctions[0].extra', 'junctions[0].name', 'junctions[1]',
                                   'options.flow_units', 'options.nope', 'patterns[0].factors'])
    expect { described_class.new(junctions: [{ name: 'J' }]) }.to raise_error(Swmm::InvalidInput)
  end

  it 'does not let optional columns be skipped over' do
    row = { subcatchment: 'S', aquifer: 'A', node: 'N', surface_elevation: 1, a1: 0, b1: 0, a2: 0, b2: 0, a3: 0, fixed_depth: 0 }
    expect(inp(groundwater: [row])).to include('S A N 1 0 0 0 0 0 0 *')
    expect(errors(groundwater: [row.merge(water_table_elevation: 3)])['groundwater[0].water_table_elevation']).to include('bottom_elevation')
  end

  it 'takes Hashes for keyword sections' do
    text = inp(evaporation: { monthly: (1..12).to_a, dry_only: true }, temperature: { file: ['clima.dat', '2020-01-01', 'C'], windspeed_file: true },
               report: { input: false, nodes: %w[A B], links: 'ALL' })
    expect(text).to include('MONTHLY 1 2 3 4 5 6 7 8 9 10 11 12')
    expect(text).to include('DRY_ONLY YES')
    expect(text).to include('FILE clima.dat 01/01/2020 C')
    expect(text).to include('WINDSPEED FILE')
    expect(text).to include("INPUT NO\nNODES A B\nLINKS ALL")
    expect(errors(evaporation: { monthly: [1, 2] })).not_to be_empty, 'wrong value count'
  end

  it 'writes multi-line objects' do
    text = inp(timeseries: [{ name: 'T', points: [['2026-03-24 10:00', 1], [0.5, 2]] }, { name: 'F', file: 'data.dat' }],
               curves: [{ name: 'C', type: 'pump1', points: [[0, 0], [1, 5]] }],
               transects: [{ name: 'T1', n_left: 0.05, n_right: 0.05, n_channel: 0.03, x_left: 1, x_right: 9,
                             stations: (0..9).map { [it, it * 2] } }])
    expect(text).to include("T 03/24/2026 10:00 1\nT 0.5 2")
    expect(text).to include('F FILE data.dat')
    expect(text).to include("C PUMP1 0 0\nC 1 5")
    expect(text).to include("NC 0.05 0.05 0.03\nX1 T1 10 1 9 0 0 0 1 1\nGR 0 0 1 2")
    expect(text.scan(/^GR /).size).to eq(2), '10 stations wrap onto 2 GR lines'
  end

  it 'turns rule Hashes into control rules' do
    text = inp(controls: [{ name: 'R1', if: ['NODE J DEPTH > 1', 'AND LINK C FLOW < 2'], then: ['PUMP P STATUS = ON'], priority: 2 }, 'VARIABLE x = NODE J DEPTH'])
    expect(text).to include("RULE R1\n  IF NODE J DEPTH > 1\n  AND LINK C FLOW < 2\n  THEN PUMP P STATUS = ON\n  PRIORITY 2")
    expect(text).to include('VARIABLE x = NODE J DEPTH')
  end

  it 'passes raw Array rows through and respects the engine token limit' do
    expect(inp(junctions: [['J', 1, '*', true]])).to include('J 1 * YES')
    expect(errors(junctions: [Array.new(41) { 'x' }]).keys).to eq(['junctions[0]'])
  end

  it 'takes a JSON document as a valid input' do
    Dir.mktmpdir do |dir|
      model = SwmmFixtures.full(dir)
      from_json = JSON.parse(JSON.generate(model)) # string keys at every level, times as strings
      expect(described_class.validate(from_json)).to be_empty
      expect(described_class.new(from_json.merge('timeseries' => [])).to_inp.lines.size).to eq(described_class.new(model.merge(timeseries: [])).to_inp.lines.size)
    end
  end

  it 'documents every section in Schema.describe' do
    doc = Swmm::Schema.describe
    Swmm::Schema::SECTIONS.each_key { expect(doc).to include("## `#{it}`") }
  end
end
