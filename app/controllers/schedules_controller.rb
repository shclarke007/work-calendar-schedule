require "anthropic"
require "base64"
require "csv"

class SchedulesController < ApplicationController
  def index
    @schedules = Schedule.order(created_at: :desc).limit(20)
  end

  def show
    @schedule = Schedule.find(params[:id])
  end

  def create
    file = params[:file]
    return render json: { error: "No file provided" }, status: 422 unless file

    if csv?(file)
      shifts = parse_csv(file.read)
    else
      shifts = analyse_image(file)
    end

    shifts = Schedule.apply_titles(shifts)

    @schedule = Schedule.create!(
      original_filename: file.original_filename,
      upload_type: csv?(file) ? "csv" : "image",
      shifts: shifts
    )

    render json: { id: @schedule.id, shifts: shifts }
  rescue Faraday::Error => e
    render json: { error: anthropic_error_message(e) }, status: 422
  rescue => e
    Rails.logger.error("#{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}")
    render json: { error: e.message }, status: 422
  end

  def export
    @schedule = Schedule.find(params[:id])
    params_format = params[:format] || "ics"

    # Allow edits passed from the frontend
    shifts = params[:shifts] ? JSON.parse(params[:shifts]) : @schedule.shifts

    if params_format == "csv"
      send_data build_csv(shifts), filename: "work-schedule.csv",
      type: "text/csv"
    else
      send_data build_ics(shifts), filename: "work-schedule.ics",
      type: "text/calendar"
    end
  end

  def destroy
    Schedule.find(params[:id]).destroy
    redirect_to root_path, notice: "Schedule deleted"
  end

  private

  def csv?(file)
    file.content_type == "text/csv" || file.original_filename.end_with?(".csv")
  end

  def analyse_image(file)
    b64 = Base64.strict_encode64(file.read)
    mime = file.content_type

    client = Anthropic::Client.new(access_token: ENV["ANTHROPIC_API_KEY"], log_errors: true)
    response = client.messages(
      parameters: {
        model: "claude-sonnet-4-6",
        max_tokens: 1000,
        messages: [ {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: mime, data: b64 } },
            { type: "text", text: <<~PROMPT }
              Analyse this work schedule image and extract all shifts.
              Return only a valid JSON array - no markdown, no explanation.
              Each object must have:
              - "title": string (shift type if visible, else "work shift")
              - "start": "YYYY-MM-DDTHH:MM" (24hr)
              - "end": "YYYY-MM-DDTHH:MM" (24hr)
              If no year is shown, use the next upcoming date from today (#{Date.today}).
              Default times if missing: 09:00-17:00.
              Do NOT include days off or blank entries. Return [] if none found.
            PROMPT
          ]
        } ]
      }
    )
    text = Array(response["content"]).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
    json = text[/\[[\s\S]*\]/] || text.gsub(/```json|```/, "").strip
    JSON.parse(json)
  end

  def anthropic_error_message(error)
    body = error.response&.[](:body)
    message = if body.is_a?(Hash)
      body.dig("error", "message") || body.to_json
    else
      body.presence
    end
    Rails.logger.error("Anthropic error: #{message || error.message}")
    message.presence || error.message
  end

  def parse_csv(text)
    rows = CSV.parse(text, headers: true)
    headers = rows.headers.map { |h| [ h.to_s.strip.downcase ] }

    find = ->(keys) { keys.map { |k| headers[k] }.compact.first }

    title_col = find.call(%w[subject title])
    start_date_col = find.call(%w[start\ date startdate])
    start_time_col = find.call(%w[start\ time starttime])
    end_date_col = find.call(%w[end\ date enddate])
    end_time_col = find.call(%w[end\ time endtime])

    rows.filter_map do |row|
      sd = parse_date(row[start_date_col])
      ed = parse_date(row[end_date_col]) || sd
      st = parse_time(row[start_time_col]) || "09:00"
      et = parse_time(row[end_time_col]) || "17:00"
      next unless sd

       {
        "title" => row[title_col]&.strip || "Work Shift",
        "start" => "#{sd}T#{st}",
        "end"   => "#{ed}T#{et}"
      }
    end
  end

  def parse_date(str)
    return nil unless str.present?
    if str.include?("/")
      m, d, y = str.split("/")
      "#{y}-#{m.rjust(2, '0')}-#{d.rjust(2, '0')}"
    else
      str.strip
    end
  rescue
    nil
  end

  def parse_time(str)
    return nil unless str.present?
    if str.match?(/AM|PM/i)
      t = Time.parse(str)
      t.strftime("%H:%M")
    else
      str.strip[0..4]
    end
  rescue
    nil
  end

  def build_ics(shifts)
    lines = %w[BEGIN:VCALENDAR VERSION:2.0 PRODID:-//
    WorkScheduleApp//EN CALSCALE:GEORGIAN METHOD:PUBLISH]
    shifts.each_with_index do |shift, index|
      start_date = shift["start"].gsub(/[-:T]/, "").insert(8, "T")[0..14] + "00"
      end_date = shift["end"].gsub(/[-:T]/, "").insert(8, "T")[0..14] + "00"
      title = shift["title"].to_s.gsub(/[\\;,]/) { |c| "\\#{c}" }
      now = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      lines += [ "BEGIN:VEVENT", "DTSTART:#{start_dt}", "DTEND:#{end_dt}",
      "SUMMARY:#{title}", "UID:ws-#{i}-#{Time.now.to_i}@app",
      "DTSTAMP:#{now}", "END:VEVENT" ]
    end
    (lines << "END:VCALENDAR").join("\r\n")
  end

  def build_csv
    CSV.generate do |csv|
      csv << [ "Subject", "Start Date", "Start Time", "End Date", "End Time", "All Day Event" ]
      shifts.each do |s|
        sd, st = s["start"].split("T")
        ed, et = s["end"].split("T")
        csv << [ s["title"] || "Work Shift", sd, st, ed, et, "False" ]
      end
    end
  end
end
