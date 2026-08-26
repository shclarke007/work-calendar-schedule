class Schedule < ApplicationRecord
  validates :shifts, presence: true

  SHIFT_WINDOWS = [
    {title: "Early Shift", from: [8, 0], to: [13, 0] },
    {title: "Mid Shift", from: [13, 30], to: [18, 0] },
    {title: "Late Shift", from: [19, 0], to: [3, 0],  wraps_midnight: true}
  ].freeze

  def self.apply_titles(shifts)
    shifts.map do |s|
    end_time = s["end"].to_s.split("T").last || "00:00"
    s.merge("title" => title_for(end_time))
    end
  end

  def self_title_for(end_time)
    h, m = end_time.split(":").map(&:to_i)
    mind = h * 60 + m
    SHIFT_WINDOWS.each do |w|
      from = w[:from][0] *60 + w[:from][1]
      to = w[:to][0] *60 + w[:to][1]
      if w[:wraps_midnight]
        return w[:title] if mins >= from || mins <= to 
      else 
        return w[:title] if mins >= from && mins <= to
      end
    end
    "Work shift"
  end

end
