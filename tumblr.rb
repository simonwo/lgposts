require 'oauth'
require 'json'
require 'ostruct'
require 'open-uri'

TOKEN_FILE = './.token.yml'

class Tumblr
  def initialize
    @request_counter = 0
  end

  def posts blog, **params
    get_pages('v2', 'blog', blog, 'posts', **params).flat_map(&:posts)
  end

  def post blog, id, **params
    get('v2', 'blog', blog, 'posts', id: id, **params).posts.first
  end

  def notes blog, id, mode
    get_pages('v2', 'blog', blog, 'notes', id: id, mode: mode).flat_map(&:notes)
  end

  private
  def client
    @client ||= OAuth::Consumer.new(
      ENV['TUMBLR_CLIENT_KEY'],
      ENV['TUMBLR_SECRET_KEY'],
      site: 'https://api.tumblr.com',
    )
  end

  def get *path, **params
    uri = URI::parse("/" + path.join('/'))
    uri.query = URI.encode_www_form params
    STDOUT.puts "GET #{uri.to_s}"

    @request_counter += 1
    response = client.request(:get, uri.to_s)
    parsed = JSON::parse response.read_body, object_class: OpenStruct
    raise "#{parsed.meta.status} #{parsed.meta.msg}: #{parsed.errors.map(&:detail).join('; ')}" if parsed.meta.status > 400

    parsed.response
  end

  def get_pages *path, **params
    acc = []

    loop do
      res = get(*path, **params)
      acc << res
      break if res._links.nil? || res._links.next.nil?
      params = res._links.next.query_params.to_h
    end

    acc
  end
end

HEADER = 'var tumblr_api_read = '
FOOTER = ';'

class TumblrLite
  class << self
    def post blog, id
      attempts = 0
      url = "https://#{blog}.tumblr.com/api/read/json?id=#{id}"

      begin
        attempts += 1
        STDOUT.puts "GET #{url}"
        URI.open(url) do |res|
          json = res.read[HEADER.size...-(FOOTER.size + 1)]
          JSON::parse(json, object_class: OpenStruct).posts.first
        end
      rescue OpenURI::HTTPError => e
        case e.to_s
        when "429 Too Many Requests"
          STDOUT.puts "\tBack off for #{5 ** attempts}s"
          sleep (5 ** attempts)
          retry
        when "404 Not Found"
          nil
        end
      end
    end
  end
end
