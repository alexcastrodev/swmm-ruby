# frozen_string_literal: true

module Swmm
  # libswmm5 could not be loaded (see Swmm::Engine.library_candidates).
  class LibraryNotFound < Error; end
end
