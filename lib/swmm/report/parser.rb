# frozen_string_literal: true

module Swmm
  class Report
    # Behind Swmm::Report: reads what the engine says about the run from the text of a .rpt. Needs neither the engine
    # nor the .out.
    class Parser
      BANNER = 'STORM WATER MANAGEMENT MODEL' # first lines of every report the engine writes ("EPA ..." or "OWA ...")
      US_FLOW_UNITS = %w[CFS GPM MGD].freeze
      # the report's flood volumes are 10^6 ltr (SI) or 10^6 gal (US): to the volume unit of Collection#units, m3 / ft3
      FLOOD_VOLUME = { si: 1000.0, us: 133_680.555_6 }.freeze
      # "  J1   1.76   103.07   0  01:00   0.354   0.000": node, hours flooded, max rate, days hr:min of the max, volume,
      # max ponded depth (the "Node Flooding Summary" of SWMM 5.2)
      FLOODING_ROW = /\A\s*(\S+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\d+):(\d+)\s+([\d.]+)\s+([\d.]+)\s*\z/

      attr_reader :text

      # +text+: contents of a .rpt, in any encoding (read as UTF-8, invalid bytes replaced). Blank when the engine wrote
      # none; then every reader answers as for a run that printed nothing.
      def initialize(text)
        text = String.try_convert(text) or raise TypeError, "the .rpt contents must be a String, got #{text.class}"
        @text = text.dup.force_encoding(Encoding::UTF_8).scrub.freeze
      end

      def swmm? = text.include?(BANNER)

      # "Build 5.2.4" in the EPA banner, "VERSION v5.2.1" in the OWA one; nil when the report has neither
      def version = text[/Build (\d+\.\d+\.\d+)/, 1] || text[/VERSION v?(\d+\.\d+\.\d+)/, 1]

      # Input errors (2xx, with their line context) make the engine return 200, which the report never prints.
      def error_code
        codes = text.scan(/^\s*ERROR (\d+):/).flatten.map(&:to_i)
        codes.any? { it.between?(200, 299) } ? 200 : codes.first.to_i
      end

      def error_message(code = error_code)
        text[/^\s*(ERROR #{code}:.*)$/, 1]&.strip || (code == 200 ? 'ERROR 200: one or more errors in input file.' : "ERROR #{code}")
      end

      # "ERROR 209: undefined object X at line 14 of [CONDUIT] section:" is followed by the offending input line
      def error_details
        lines = text.lines.map(&:strip)
        lines.each_with_index.filter_map do |l, i|
          next unless l.start_with?('ERROR')

          l.end_with?(':') && lines[i + 1] ? "#{l} #{lines[i + 1]}" : l
        end
      end

      # nil | { code:, message:, details: } as the report prints it (the engine's own code, when known, may differ: see
      # Result#error, which prefers the one the .out saved)
      def error
        code = error_code
        code.zero? ? nil : { code: code, message: error_message(code), details: error_details }
      end

      def ok? = error.nil?

      def warnings = @warnings ||= text.scan(/^\s*WARNING \d+:.*$/).map(&:strip)

      # Like swmm_getMassBalErr: quality is the pollutant error with the largest absolute value (signed). From the
      # "Continuity Error (%)" lines (3 decimals; a block the report does not print is 0.0); nil when the run failed.
      def continuity
        return if error_code.nonzero?

        @continuity ||= {
          runoff: continuity_error('Runoff Quantity Continuity'), flow_routing: continuity_error('Flow Routing Continuity'),
          quality: continuity_error('Quality Routing Continuity')
        }
      end

      # "Highest Flow Instability Indexes" lists "  Link C1 (12)" (or "All links are stable."); the section stops at the next banner.
      def flow_instability
        @flow_instability ||= begin
          section = text[/Highest Flow Instability Indexes\s*\*+\n(.*?)(?=^\s*\*|\z)/m, 1].to_s
          section.scan(/^\s*Link (.+?) \((\d+)\)\s*$/).to_h { |id, turns| [id, turns.to_i] }
        end
      end

      # What the report prints of the run under "Analysis Options"; nil for what it does not print (a run that failed on
      # its input stops before them; the routing ones only with Flow Routing on, surcharge_method only for DYNWAVE).
      # Dates are UTC (SWMM dates carry no zone); report_step and routing_step are TimeSteps ("5.00 sec" is 5 s);
      # variable_step true/false ("YES"/"NO": the .inp's factor is not printed).
      def analysis_options
        @analysis_options ||= begin
          step = text[/^\s*Report Time Step \.+ (\d+:\d+:\d+)\s*$/, 1]
          routing = text[/^\s*Routing Time Step \.+ ([\d.]+) sec/, 1]
          variable = option('Variable Time Step')
          {
            flow_units: option('Flow Units'), start_time: time_of('Starting Date'), end_time: time_of('Ending Date'),
            report_step: step && TimeStep.parse(step),
            flow_routing: option('Flow Routing Method'), surcharge_method: option('Surcharge Method'),
            routing_step: routing && TimeStep.parse(routing),
            variable_step: variable && variable == 'YES'
          }
        end
      end

      # The "Node Flooding Summary": one row per node that flooded (water left the network there), [] when none did or
      # the report has no such table (a run that failed).
      #   { node: "J1", hours: 1.76, max_rate: 103.07, max_elapsed: 3600, max_time: Time, volume: 354.0, max_ponded_depth: 0.0 }
      # max_rate in the flow units; volume in m3 / ft3; max_ponded_depth in m / ft; max_elapsed: seconds from the report
      # start, as the report counts; max_time: +start+ + max_elapsed, nil without a +start+ (the report does not print
      # its own: Result#report_start finds it in the .out). The report keeps 2 decimals of the rate and resolves volumes
      # to 1 m3 / 133.7 ft3.
      def node_flooding(start: nil)
        (@node_flooding ||= flooding_rows).map do |node, hours, rate, elapsed, volume, depth|
          { node: node, hours: hours, max_rate: rate, max_elapsed: elapsed, max_time: start && (start + elapsed),
            volume: volume, max_ponded_depth: depth }
        end
      end

      private

      # "  Flow Routing Method ...... DYNWAVE" => "DYNWAVE"
      def option(label) = text[/^\s*#{label} \.+ (\S+)/, 1]

      def continuity_error(title)
        text[/#{title}.*?Continuity Error \(%\) \.+([^\n]*)/m, 1].to_s.split.map(&:to_f).max_by(&:abs) || 0.0
      end

      # "  Starting Date ............ 03/24/2026 00:00:00" as a UTC Time: the engine always writes M/D/Y (swmm_open sets it)
      def time_of(label)
        m = text.match(%r{^\s*#{label} \.+ (\d+)/(\d+)/(\d+) (\d+):(\d+):(\d+)\s*$})
        m && Time.utc(m[3].to_i, m[1].to_i, m[2].to_i, m[4].to_i, m[5].to_i, m[6].to_i)
      rescue ArgumentError # out of range: not a date the engine wrote
        nil
      end

      def flooding_rows
        section = text[/Node Flooding Summary\s*\*+\R(.*?)(?=^\s*\*{5,}|\z)/m, 1].to_s
        factor = FLOOD_VOLUME.fetch(US_FLOW_UNITS.include?(analysis_options[:flow_units]) ? :us : :si)
        section.each_line.filter_map do |line|
          node, hours, rate, days, hour, minute, volume, depth = line.match(FLOODING_ROW)&.captures
          next unless node

          elapsed = (days.to_i * 86_400) + (hour.to_i * 3600) + (minute.to_i * 60)
          [node, hours.to_f, rate.to_f, elapsed, (volume.to_f * factor).round(3), depth.to_f].freeze
        end.freeze
      end
    end
  end
end
