# frozen_string_literal: true

module Swmm
  # A model as Swmm::Input.read / .parse give it: the contract Hash (keys = lowercase [SECTION] names), so everything a
  # Hash does still works (model[:options].merge!(...), Swmm.run(model), Swmm::Input.new(model)), plus what it holds:
  #
  #   model = Swmm::Input.read("model.inp")
  #   model.count_nodes            # { "JUNCTION" => 605, "OUTFALL" => 1, "STORAGE" => 3 } (types it has none of left out)
  #   model.total_nodes            # 609
  #   model.count_links_pump       # 1 (one type; 0 when it has none)
  #
  # Every object of the model: the .out saves only those [REPORT] lists (OutputFile has the same methods for those).
  # A Hash of your own becomes one with Swmm::Model[hash] (keys may be Symbols or Strings).
  class Model < Hash
    # the section of each node / link type, in the order of OutputFile::TYPES
    NODE_SECTIONS = { "JUNCTION" => :junctions, "OUTFALL" => :outfalls, "STORAGE" => :storage, "DIVIDER" => :dividers }.freeze
    LINK_SECTIONS = { "CONDUIT" => :conduits, "PUMP" => :pumps, "ORIFICE" => :orifices, "WEIR" => :weirs, "OUTLET" => :outlets }.freeze

    def count_nodes = count_sections(NODE_SECTIONS)
    def count_links = count_sections(LINK_SECTIONS)

    def count_nodes_junction = rows(:junctions)
    def count_nodes_outfall = rows(:outfalls)
    def count_nodes_storage = rows(:storage)
    def count_nodes_divider = rows(:dividers)
    def count_links_conduit = rows(:conduits)
    def count_links_pump = rows(:pumps)
    def count_links_orifice = rows(:orifices)
    def count_links_weir = rows(:weirs)
    def count_links_outlet = rows(:outlets)

    def total_nodes = count_nodes.values.sum
    def total_links = count_links.values.sum
    def total_subcatchments = rows(:subcatchments)
    def total_pollutants = rows(:pollutants)

    private

    def count_sections(sections) = sections.filter_map { |type, name| [type, rows(name)] if rows(name).positive? }.to_h

    # rows of a section (a raw Array row counts too)
    def rows(name) = Array(fetch(name) { self[name.to_s] }).size
  end
end
