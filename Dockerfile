# Runs the suite on Linux, building libswmm5 from the EPA sources with `rake swmm:build`:
#   docker build -t swmm-ruby . && docker run --rm swmm-ruby
FROM ruby:4.0.7

RUN apt-get update && apt-get install -y --no-install-recommends build-essential cmake git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# the library first: it only depends on the Rakefile, so code changes do not rebuild it (SWMM_VERSION=v5.2.4 by default)
COPY Rakefile ./
RUN rake swmm:build

COPY . .
RUN BUNDLE_WITHOUT=development:test bundle config set --local without development:test && bundle install

CMD ["bundle", "exec", "rake", "test"]
