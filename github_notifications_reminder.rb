require 'httparty'
require 'json'
require 'date'

class GithubNotificationsReminder
  def perform
    return unless token && ENV['SLACK_GITHUB_NOTIFICATIONS_REMINDER_WEBHOOK_URL']

    data = fetch_github_pull_requests(token)

    return if data.nil?

    blocks = process_pull_requests(data)

    send_slack_notification(blocks)
  end

  private

  def fetch_github_pull_requests(token)
    base_url = ENV['GITHUB_BASE_URL_API']

    return unless base_url

    begin
      response = HTTParty.get(base_url, headers: headers)
      if response.code != 200
        raise "Error: #{response.code}"
      end

      JSON.parse(response.body)
    rescue StandardError => e
      raise "Error fetching GitHub pull requests: #{e.message}"
    end
  end

  def process_pull_requests(data)
    blocks = []

    data.each do |pull_request|
      is_draft = pull_request['draft']

      if !is_draft && within_three_weeks_ago?(pull_request['created_at'], pull_request['updated_at'])
        id = pull_request['number']
        author = pull_request['user']['login']
        url = "#{ENV['GITHUB_PULL_REQUEST_URL']}#{id}"
        sha = pull_request['head']['sha']

        truncated_title = truncated_pr_title(pull_request['title'].upcase)

        button_text = generate_button_text(pull_request, get_pr_status_ci(sha))

        block = generate_slack_block(id, url, truncated_title, author, button_text)
        blocks << block
      end
    end

    blocks
  end

  def get_pr_status_ci(sha)
    ci_status_url = "#{ENV['GITHUB_CI_STATUS_URL']}#{sha}/status"

    begin
      ci_status_response = HTTParty.get(ci_status_url, headers: headers)

      raise if ci_status_response.code != 200

      ci_status_data = JSON.parse(ci_status_response.body)
      ci_status_state = ci_status_data['state']

      "#{ci_status_state == 'success' ? ':white_check_mark:' : ':x:'}"
    rescue StandardError => e
      raise "Error fetching CI status: #{e.message}"
    end
  end

  def truncated_pr_title(string)
    max_length = 43

    string.length > max_length ? "#{string[0, max_length - 3]}.." : string
  end

  def within_three_weeks_ago?(created_at, updated_at)
    three_weeks_ago = Date.today - 21

    Date.parse(created_at) >= three_weeks_ago || Date.parse(updated_at) >= three_weeks_ago
  end

  def generate_button_text(pull_request, build_status)
    labels = pull_request['labels']
    has_migration_label = labels.any? { |label| label['name'].include?('migration') }

    if has_migration_label
      "CI: #{build_status} | MI/ENV: :warn_zip:"
    else
      "CI: #{build_status}"
    end
  end

  def generate_slack_block(id, url, truncated_title, author, button_text)
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: "• <#{url}|#{truncated_title}> *_by: #{author}_*"
      },
      accessory: {
        type: "button",
        text: {
          type: "plain_text",
          text: button_text,
          emoji: true
        },
        value: "click_me_#{id}",
        url: url,
        action_id: "button-action"
      }
    }
  end

  def send_slack_notification(blocks)
    payload = {
      blocks: [
        {
          type: "header",
          text: {
            type: "plain_text",
            text: "Existem #{blocks.length} PRs abertos :sunglasses:",
            emoji: true
          }
        },
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: "_Intervalo: #{(Date.today - 21).strftime("%d/%m/%Y")} - #{Date.today.strftime("%d/%m/%Y")} (21 dias)_"
          }
        },
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: "*Labels:* _ Migrations/Envs:_ :warn_zip: | _Semaphore CI:_ :white_check_mark: or :x:",
          }
        },
        {
          type: "divider"
        },
        *blocks
      ]
    }

    begin
      response = HTTParty.post(ENV['SLACK_GITHUB_NOTIFICATIONS_REMINDER_WEBHOOK_URL'], headers: headers, body: payload.to_json)

      raise "Error sending message to Slack: #{response.code}" if response.code != 200
    rescue StandardError => e
      raise "Error sending Slack notification: #{e.message}"
    end
  end

  def headers
    {
      'Authorization' => "Bearer #{token}",
      'User-Agent' => 'SmartSystem',
      'Accept' => 'application/vnd.github.v3+json'
    }
  end

  def token
    ENV['GITHUB_TOKEN']
  end
end

GithubNotificationsReminder.new.perform
puts "Executado"
