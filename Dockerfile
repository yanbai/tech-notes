# Local preview with the same Jekyll and plugin versions as GitHub Pages.
#   docker build -t yefengzhai-blog .
#   docker run --rm -it -p 4000:4000 -v "$PWD":/site yefengzhai-blog
FROM ruby:3.3

# Keep the Gemfile (and the Gemfile.lock bundler writes) inside the image,
# so nothing is written into the mounted repo.
ENV BUNDLE_GEMFILE=/deps/Gemfile
COPY Gemfile /deps/Gemfile
RUN bundle install

WORKDIR /site
EXPOSE 4000

# --force_polling: file change events don't cross a macOS bind mount.
CMD ["bundle", "exec", "jekyll", "serve", "--host", "0.0.0.0", "--force_polling"]
