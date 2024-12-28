require 'oauth'
require 'json'
require 'ostruct'
require 'open-uri'
require 'timeout_cache'

TOKEN_FILE = './.token.yml'

def protect &block
  attempts = 0
  begin
    attempts += 1
    block.call
  rescue Net::HTTPError => error
    case error.response
    when Net::HTTPTooManyRequests
      STDERR.puts "\tBack off for #{5 ** attempts}s"
      sleep (5 ** attempts)
      retry
    when Net::HTTPNotFound
      nil
    else raise error
    end
  end
end

CACHE = TimeoutCache.new

class Tumblr
  def initialize
    @request_counter = 0
  end

  def posts blog, **params
    protect { get_pages('v2', 'blog', blog, 'posts', **params).flat_map(&:posts) }
  end

  def post blog, id, **params
    raise ArgumentError, 'ID must be provided' if id.nil? || id.to_s.empty?
    protect { get('v2', 'blog', blog, 'posts', id: id, **params).posts.first }
  end

  def notes blog, id, mode
    protect { get_pages('v2', 'blog', blog, 'notes', id: id, mode: mode).flat_map(&:notes) }
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
    params.to_a.each do |key, value|
      case value
      when Array
        value.each_with_index {|v, i| params["#{key}[#{i}]"] = v }
        params.delete key
      end
    end
    uri.query = URI.encode_www_form params
    STDOUT.puts "GET #{uri.to_s}"

    cached = CACHE.get(uri)
    return cached unless cached.nil?

    @request_counter += 1
    response = client.request(:get, uri.to_s)
    parsed = JSON::parse response.read_body, object_class: OpenStruct
    if parsed.meta.status >= 400
      raise Net::HTTPError.new(
        ["#{parsed.meta.status} #{parsed.meta.msg}.", *parsed.errors.map(&:detail)].join(" "),
        Net::HTTPResponse::CODE_TO_OBJ[parsed.meta.status.to_s].new(response.http_version, parsed.meta.status, parsed.meta.msg),
      )
    end

    CACHE.set(uri, parsed.response, time: 15 * 60)
    parsed.response
  end

  def get_pages *path, **params
    Enumerator.new do |yielder|
      loop do
        res = get(*path, **params)
        yielder << res
        break if res._links.nil? || res._links.next.nil?
        params = res._links.next.query_params.to_h
      end
    end
  end
end

HEADER = 'var tumblr_api_read = '
FOOTER = ';'

class TumblrLite
  class << self
    def post blog, id
      raise ArgumentError, 'Blog name must be provided' if blog.nil? || blog.empty?
      raise ArgumentError, 'ID must be provided' if id.nil? || id.to_s.empty?

      protect do
        begin
          url = "https://#{blog}.tumblr.com/api/read/json?id=#{id}"
          STDOUT.puts "GET #{url}"
          URI.open(url) do |res|
            json = res.read[HEADER.size...-(FOOTER.size + 1)]
            JSON::parse(json, object_class: OpenStruct).posts.first
          end
        rescue OpenURI::HTTPError => error
          raise Net::HTTPError.new(
            error.message,
            Net::HTTPResponse::CODE_TO_OBJ[error.message[0...3]].new(nil, error.message[0...3], error.message[5..]),
          )
        end
      end
    end
  end
end
