class CreateSchedules < ActiveRecord::Migration[7.2]
  def change
    create_table :schedules do |t|
      t.string :original_filename
      t.string :upload_type
      t.string :string
      t.jsonb :shifts
      t.text :raw_text

      t.timestamps
    end
  end
end
