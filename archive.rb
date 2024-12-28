require 'oauth'
require 'yaml'
require 'json'

require_relative 'tumblr'

class OpenStruct
  def to_json(*args, **opts)
    @table.to_json(*args, **opts)
  end
end

PAGE_SIZE = 50

TUMBLR = Tumblr.new
TUMBLR.posts(:ferronickel, tag: ['looking glasses', 'ferrousart'], sort: :asc).each do |post|
  next unless ARGV.empty? || ARGV.include?(post.id_string)

  if post.note_count / PAGE_SIZE > 10
    puts "::warning:: Skipping #{post.id_string} because it has too many notes (#{post.note_count})"
    next
  end

  reblogs = TUMBLR.notes(post.blog_name, post.id, :reblogs_with_tags).filter {|note| note.type == "reblog" }
  conversation = TUMBLR.notes(post.blog_name, post.id, :conversation)
  replies = conversation.filter {|note| note.type == "reply" }
  all_notes = nil

  conversation.filter {|note| note.type == "reblog" }.each do |note|
    found_reblog = reblogs.filter {|reblog| reblog.post_id == note.post_id }.first
    found_reblog.table.update(note.table)
  end

  replies.each do |reply|
    response_to = reply.formatting.filter {|f| f.type == "mention" }.first
    next if response_to.nil?

    post_filter = Proc.new {|r| r.timestamp < reply.timestamp && r.blog_name == response_to.blog.name }
    prev = replies.sort_by(&:timestamp).select(&post_filter).last
    unless prev.nil?
      (prev.replies ||= []) << reply
      reply.is_response = true
      next
    end

    matching_reblog = reblogs.sort_by(&:timestamp).select(&post_filter).last
    unless matching_reblog.nil?
      (matching_reblog.replies ||= []) << reply
      reply.is_response = true
      next
    end
  end

  reblogs.each do |reblog|
    reblog.url = "https://www.tumblr.com/blog/view/#{reblog.blog_name}/#{reblog.post_id}"

    if [reblog.tags, reblog.reblog_parent_post_id].any?(&:nil?)
      fetched_post = TumblrLite::post(reblog.blog_name, reblog.post_id)
      reblog.private = fetched_post.nil?
      next if reblog.private

      reblog.tags = fetched_post.tags
      reblog.url = fetched_post.url
      reblog.reblog_parent_post_id = extract_post_id(fetched_post.send(:"reblogged-from-url"))
    end

    # If the reblog has added text, we might not have all of it, so let's get it
    # Calling post(..., notes_info: true) / notes(..., mode: :reblogs_with_tags)
    # seems to return a limited summary of the added text (with no indication
    # that anything is missing ofc), so we know added_text is present, we just
    # don't know how much of it is really there.
    unless reblog.added_text.nil?
      unless reblog.private
        # The post itself obviously has the full text, but if the post is
        # private this call will fail, so skip it if we already know that
        full_post = TUMBLR.post(reblog.blog_name, reblog.post_id)
        unless full_post.nil?
          reblog.added_text = full_post.reblog.comment
        end
      end

      if full_post.nil?
        reblog.private = true
        # If a private note has added text, for some reason we can get the most
        # text if we call :all. So lets do that once only for this post.
        all_notes ||= TUMBLR.notes(post.blog_name, post.id, :all)
        full_post = all_notes.filter {|note| note.post_id == reblog.post_id }.first
        reblog.added_text = full_post.added_text
      end
    end

    reply_to = if reblog.reblog_parent_post_id.nil?
      # If the reblog is private, we have no way of knowing who it was really
      # reblogging. So as above, we'll assume that it was the most recent reblog
      # from the named blog.
      reblogs.filter {|r| r.timestamp < reblog.timestamp && r.blog_name == reblog.reblog_parent_blog_name }.last
    else
      reblogs.filter {|n| n.post_id == reblog.reblog_parent_post_id }.first
    end
    next if reply_to.nil?

    (reply_to.replies ||= []) << reblog
    reblog.is_response = true
  end

  post.notes = []
  post.notes.concat(reblogs)
  post.notes.concat(conversation.filter {|note| note.type == "reply"})
  post.notes.sort_by!(&:timestamp)
  File::write "_site/#{post.id_string}.json", post.to_json
end

STDOUT.puts "#{TUMBLR.instance_variable_get(:'@request_counter')} requests."
