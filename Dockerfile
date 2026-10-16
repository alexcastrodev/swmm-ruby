# Runs the suite on Linux, building libswmm5 from the EPA sources with `rake swmm:build`:
#   docker build -t swmm-ruby . && docker run --rm swmm-ruby
# Two stages: compiler, cmake and the gems' C extensions stay in the first one; the final image is slim Ruby + the results.

FROM ruby:4.0.7 AS build
ENV BUNDLE_WITHOUT=development:test
RUN apt-get update && apt-get install -y --no-install-recommends cmake && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# each step only depends on the files it copies, so code changes do not rebuild the library or reinstall the gems
COPY Rakefile ./
RUN rake swmm:build
COPY Gemfile swmm-ruby.gemspec ./
COPY lib/swmm/version.rb lib/swmm/version.rb
RUN bundle install

FROM ruby:4.0.7-slim
ENV BUNDLE_WITHOUT=development:test
# the OpenMP runtime libswmm5 links against; without it the engine does not load and the tests skip
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app/vendor ./vendor
COPY --from=build /app/Gemfile.lock ./
COPY . .
CMD ["bundle", "exec", "rake", "test"]
