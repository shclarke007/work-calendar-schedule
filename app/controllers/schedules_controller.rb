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
    return render json: {error: "No file provided" }, status: 422 unless file
    
    if csv?(file)
      shifts = parse_csv(file.read)
    else
      shifts = analyse_image(file)
    end

    shifts = Schedule.apply_title(shifts)

    @schedule = Schedule.create!(
      original_filename: file.original_filename,
      upload_type: csv?(file) ? "csv" : "image",
      shifts: shifts
    )

    render json: { id: @schedule.id, shifts: shifts }
  rescue => e
    render json: { error: e.message }, status: 422
  end

  def export

  end

  private 
  
  def analyse_image(file)
    b64 = Base64.strict_encode64(file.read)
    mime = file.content_type

    client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
    response = client.message(
      model: "claude-sonnet-4-6",
      max_tokens: 1000, 
      messages: [{
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
      }]
    )
    text = response.content.select { |b| b.type == "text" }.map(&:text).join
    JSON.parse(text.gsub(/```json|```/,"").strip)
  end

  def parse_csv(text)
    rows = CSV.parse(text, headers: true)
    headers = rows.headers.map { |h| [h.to_s.strip.downcase]}

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


end
