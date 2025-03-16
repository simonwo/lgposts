require 'yaml'
require 'json'
require 'uri'
require 'nokogiri'

require_relative 'tumblr'

class OpenStruct
  def to_json(*args, **opts)
    @table.to_json(*args, **opts)
  end
end

def extract_post_id url
  URI::parse(url).path.split("/").select {|path| path =~ /^\d+$/ }.first
end

PAGE_SIZE = 50
MAX_PAGES = 50

TUMBLR = Tumblr.new

def archive post
  if post.note_count / PAGE_SIZE > MAX_PAGES
    puts "::warning::Skipping #{post.id_string} because it has too many notes (#{post.note_count})"
    return
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
  post.retrieved = Time.now.to_i
  File::write post_filename(post.id_string), post.to_json
end

def post_filename post_id
  "_site/#{post_id.to_s}.json"
end

# (18d picked so that we aren't updating posts on the same day we are likely to
# be downloading new ones, as new posts either come out on multiples of 7 or 10
# days).
POST_MAX_AGE_DAYS = 18

# Encodes the caching policy, which is:
# - new posts (age <= 48hrs) are always updated as any edits to posts or reblogs
#   are likely to happen whilst they are young
# - older posts (48hrs < age) are updated:
#   - if we retrieved more than 48hrs ago and their number of notes has changed
#   - or at a minimum every so many days, so that edits to old posts are
#     eventually picked up
#
# Doing this allows us to skip retrieving posts altogether more than one every
# two days, as we can compute most of this from the existing archived post.
def needs_update post_id, post=nil
  # New post never cached
  unless File.exist? post_filename(post_id)
    STDOUT.puts "\tPost #{post_id} never archived."
    return true
  end
  old_post = JSON.parse(File.read(post_filename(post_id)), object_class: OpenStruct)

  # More than post maximum age days old
  retrieved = Time.at old_post.retrieved
  unless retrieved.to_datetime.next_day(POST_MAX_AGE_DAYS) > Time.now.to_datetime
    STDOUT.puts "\tArchive of #{post_id} is more than #{POST_MAX_AGE_DAYS}d old."
    return true
  end

  # Young post gets updated
  young_post = Time.at(old_post.timestamp).to_datetime.next_day(2) > Time.now.to_datetime
  if young_post
    STDOUT.puts "\tPost #{post_id} is young."
    return true
  end

  # All other posts only checked for new notes every 2 days
  checked_recently = retrieved.to_datetime.next_day(2) > Time.now.to_datetime
  unless checked_recently
    post ||= TUMBLR.post(:ferronickel, post_id)
    if old_post.note_count != post.note_count
      STDOUT.puts "\tPost #{post_id} has different note count to archive."
      return true
    end
  end

  return false
end

if __FILE__ == $0
  post_ids = Set.new
  unless ARGV.empty?
    post_ids.merge ARGV
  else
    masterposts = ['771054699653791744', '748691921631952896']
    masterposts.each do |post_id|
      masterpost = TUMBLR.post(:ferronickel, post_id)
      links = Nokogiri::parse("<html>" + masterpost.body + "</html>").css('a[href^="https://www.tumblr.com"]').map {|a| a.attribute("href").value }
      post_ids.merge links.map &method(:extract_post_id)
    end

    # Get all the posts tagged with #looking glasses and #ferrousart, which
    # catches most of them but misses some early ones, and also pull the
    # #runetober 2022 posts as well
    [
      ['looking glasses'],
      ['runetober', 'ferrousart'],
    ].each do |tagset|
      TUMBLR.posts(:ferronickel, tag: tagset).each do |post|
        post_ids -= [post.id_string]
        if needs_update(post.id_string, post)
          archive post
        end
      end
    end
  end

  # Now get any links from the masterpost that we didn't archive
  post_ids.each do |id|
    if needs_update(id)
      archive TUMBLR.post(:ferronickel, id)
    end
  end

  STDOUT.puts "#{TUMBLR.instance_variable_get(:'@request_counter')} requests."
end
