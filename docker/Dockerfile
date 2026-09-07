# Development image for running Redmine 6.1.2 and its test suite locally.
# Not a production image. The source tree is bind-mounted at /redmine by compose.yaml;
# gems live in the image (BUNDLE_PATH), so the mount does not hide them.
FROM ruby:3.3

ENV RAILS_ENV=development \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    LANG=C.UTF-8

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential libpq-dev postgresql-client \
      git imagemagick ghostscript gsfonts \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /redmine

# The Gemfile reads config/database.yml to decide which DB adapter gems to install,
# so the container's database config must exist before `bundle install`.
COPY Gemfile ./
COPY docker/database.yml config/database.yml
RUN bundle install

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000
ENTRYPOINT ["entrypoint.sh"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
