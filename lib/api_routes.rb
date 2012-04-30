# API to allow for a RESTful interface to Barkeep.
require "time"

require "lib/api"

class Barkeep < Sinatra::Base
  include Api

  # API routes that don't require authentication
  AUTHENTICATION_WHITELIST_ROUTES = ["/api/commits/"]
  # API routes that require admin
  ADMIN_ROUTES = ["/api/add_repo"]
  # How out of date an API call may be before it is rejected
  ALLOWED_API_STALENESS_MINUTES = 5

  before "/api/*" do
    next if AUTHENTICATION_WHITELIST_ROUTES.any? { |route| request.path =~ /^#{route}/ }
    api_key = params[:api_key]
    halt 400, "No API key provided." unless api_key
    user = User[:api_key => api_key]
    halt 400, "Bad API key provided." unless user
    halt 400, "No timestamp in API request." unless params[:timestamp]
    halt 400, "Bad timestamp." unless params[:timestamp] =~ /^\d+$/
    timestamp = Time.at(params[:timestamp].to_i) rescue Time.at(0)
    staleness = (Time.now.to_i - timestamp.to_i) / 60.0
    if staleness < 0
      halt 400, "Bad timestamp."
    elsif staleness > ALLOWED_API_STALENESS_MINUTES
      halt 400, "Timestamp too stale."
    end
    halt 400, "No signature given." unless params[:signature]
    unless Api.generate_request_signature(request, user.api_secret) == params[:signature]
      halt 400, "Bad signature."
    end
    if ADMIN_ROUTES.any? { |route| request.path =~ /^#{route}/ }
      halt 400, "Admin only." unless user.admin?
    end
    self.current_user = user
  end

  post "/api/add_repo" do
    halt 400, "'url' is required." if (params[:url] || "").strip.empty?
    begin
      add_repo params[:url]
    rescue RuntimeError => e
      halt 400, e.message
    end
    [204, "Repo #{repo_name} is scheduled to be cloned."]
  end

  # TODO(caleb): If you include lots of shas, you will end up with a very large GET request. Apparently many
  # servers/proxies may not handle GETs over some limit 4k, 8k, ... Experiment with requesting lots of shas,
  # and put a warning in the documentation. We may have to make this a POST if this is an issue.
  get "/api/commits/:repo_name/:shas" do
    shas = params[:shas].split(",")
    fields = params[:fields] ? params[:fields].split(",") : nil
    commits = {}
    shas.each do |sha|
      begin
        commit = Commit.prefix_match params[:repo_name], sha
      rescue RuntimeError => e
        halt 404, { :message => e.message }.to_json
      end
      approver = commit.approved? ? commit.approved_by_user : nil
      commit_data = {
        :approved => commit.approved?,
        :approved_by => commit.approved? ? "#{approver.name} <#{approver.email}>" : nil,
        :approved_at => commit.approved? ? commit.approved_at.to_i : nil,
        :comment_count => commit.comment_count,
        :link => "http://#{BARKEEP_HOSTNAME}/commits/#{params[:repo_name]}/#{commit.sha}"
      }
      commit_data.select! { |key, value| fields.include? key.to_s } if fields
      commits[commit.sha] = commit_data
    end
    content_type :json
    commits.to_json
  end
end
