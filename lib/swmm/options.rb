# frozen_string_literal: true

module Swmm
  # Values of the [OPTIONS] the report prints back (Report#analysis_options), as constants (a typo is a NameError when
  # the code loads). Written out so editors can complete them; the spec keeps them equal to what the input accepts.
  #
  #   report.analysis_options[:flow_routing] == Swmm::Options::FlowRouting::DYNWAVE
  #   output.flow_units == Swmm::Options::FlowUnits::LPS
  #   model[:options][:surcharge_method] = Swmm::Options::SurchargeMethod::SLOT
  module Options
    # also OutputFile#flow_units
    module FlowUnits
      CFS = "CFS"
      GPM = "GPM"
      MGD = "MGD"
      CMS = "CMS"
      LPS = "LPS"
      MLD = "MLD"
    end

    module FlowRouting
      NONE = "NONE"
      STEADY = "STEADY"
      KINWAVE = "KINWAVE"
      DYNWAVE = "DYNWAVE"
    end

    module SurchargeMethod
      EXTRAN = "EXTRAN"
      SLOT = "SLOT"
    end
  end
end
