# frozen_string_literal: true

module Swmm
  # Names of the variables the .out saves, as constants for Element#[] and Collection#frames (a typo is a NameError
  # when the code loads instead of an UnknownObject at run time): the same Symbols Collection#variables gives. Written
  # out so editors can complete them; the spec keeps them equal. Pollutants (:"quality:<name>") are per model and have
  # no constant.
  #
  #   result.links["C1"][Swmm::Variables::Links::FLOW]
  module Variables
    module Subcatchments
      RAINFALL = :rainfall
      SNOW_DEPTH = :snow_depth
      EVAPORATION = :evaporation
      INFILTRATION = :infiltration
      RUNOFF = :runoff
      GW_FLOW = :gw_flow
      GW_ELEVATION = :gw_elevation
      SOIL_MOISTURE = :soil_moisture
    end

    module Nodes
      DEPTH = :depth
      HEAD = :head
      VOLUME = :volume
      LATERAL_INFLOW = :lateral_inflow
      TOTAL_INFLOW = :total_inflow
      OVERFLOW = :overflow
    end

    module Links
      FLOW = :flow
      DEPTH = :depth
      VELOCITY = :velocity
      VOLUME = :volume
      CAPACITY = :capacity
    end

    module System
      AIR_TEMPERATURE = :air_temperature
      RAINFALL = :rainfall
      SNOW_DEPTH = :snow_depth
      INFILTRATION = :infiltration
      RUNOFF = :runoff
      DRY_WEATHER_INFLOW = :dry_weather_inflow
      GROUNDWATER_INFLOW = :groundwater_inflow
      RDII_INFLOW = :rdii_inflow
      DIRECT_INFLOW = :direct_inflow
      TOTAL_INFLOW = :total_inflow
      FLOODING = :flooding
      OUTFLOW = :outflow
      STORAGE = :storage
      EVAPORATION = :evaporation
      POTENTIAL_ET = :potential_et
    end
  end
end
