require 'oauth'
require 'yaml'
require 'json'

require_relative 'tumblr'

class OpenStruct
  def to_json(*args, **opts)
    @table.to_json(*args, **opts)
  end
end

TUMBLR = Tumblr.new
TUMBLR.posts(:ferronickel, tag: 'looking glasses', notes_info: true).each do |post|
  notes = post.notes
  replies = notes.filter {|n| n.type == "reply" }.reverse
  reblogs = notes.filter {|n| n.type == "reblog" }

  replies.each_cons(2) do |prev, reply|
    response_to = reply.formatting.filter {|f| f.type == "mention" }.first
    next if response_to.nil?

    if prev.blog_name == response_to.blog.name
      (prev.replies ||= []) << reply
      reply.is_response = true
      next
    end

    matching_reblog = reblogs.filter {|r| r.timestamp <= reply.timestamp && r.blog_name == response_to.blog.name }.last
    if !matching_reblog.nil?
      (matching_reblog.replies ||= []) << reply
      reply.is_response = true
      next
    end
  end

  reblogs.each do |reblog|
    fetched_post = TumblrLite::post(reblog.blog_name, reblog.post_id)
    reblog.tags = fetched_post.tags unless fetched_post.nil?
    reblog.private = fetched_post.nil?
  end

  File::write "_site/#{post.id_string}.json", post.to_json

  # def printnote note, depth=0
  #   puts "#{"\t" * depth}#{note.blog_name}: #{note.reply_text} #{(note.tags || []).map{|tag| "#" + tag}.join(' ')}"
  #   (note.replies || []).each do |reply|
  #     printnote reply, depth+1
  #   end
  # end

  # notes.sort_by(&:timestamp).each do |note|
  #   next if note.is_response
  #   next unless ["reply", "reblog"].include? note.type
  #   next if note.type == "reblog" && (note.tags || []).empty? && (note.replies || []).empty?
  #   printnote note
  # end
end

STDOUT.puts "#{TUMBLR.instance_variable_get(:'@request_counter')} requests."
