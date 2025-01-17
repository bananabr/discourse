# frozen_string_literal: true

class ThemeSettingsManager
  attr_reader :name, :theme, :default

  def self.types
    ThemeSetting.types
  end

  def self.cast_row_value(row)
    type_name = self.types.invert[row.data_type].downcase.capitalize
    klass = "ThemeSettingsManager::#{type_name}".constantize
    klass.cast(row.value)
  end

  def self.create(name, default, type, theme, opts = {})
    type_name = self.types.invert[type].downcase.capitalize
    klass = "ThemeSettingsManager::#{type_name}".constantize
    klass.new(name, default, theme, opts)
  end

  def self.cast(value)
    value
  end

  def initialize(name, default, theme, opts = {})
    @name = name.to_sym
    @default = default
    @theme = theme
    @opts = opts
    @types = self.class.types
  end

  def value
    has_record? ? db_record.value : default
  end

  def type_name
    self.class.name.demodulize.downcase.to_sym
  end

  def type
    @types[type_name]
  end

  def description
    @opts[:description] # Old method of specifying description. Is now overridden by locale file
  end

  def requests_refresh?
    @opts[:refresh]
  end

  def value=(new_value)
    ensure_is_valid_value!(new_value)

    record = has_record? ? db_record : create_record!
    record.value = new_value.to_s
    record.save!
    record.value
  end

  def db_record
    # theme.theme_settings will already be preloaded, so it is better to use
    # `find` on an array, rather than make a round trip to the database
    theme.theme_settings.to_a.find do |i|
      i.name.to_s == @name.to_s && i.data_type.to_s == type.to_s
    end
  end

  def has_record?
    db_record.present?
  end

  def create_record!
    record = ThemeSetting.new(name: @name, data_type: type, theme: @theme)
    record.save!
    record
  end

  def is_valid_value?(new_value)
    true
  end

  def invalid_value_error_message
    name = type == @types[:integer] || type == @types[:float] ? "number" : type_name
    primary_key = "themes.settings_errors.#{name}_value_not_valid"

    secondary_key = primary_key
    secondary_key += "_min" if has_min?
    secondary_key += "_max" if has_max?

    translation = I18n.t(primary_key)
    return translation if secondary_key == primary_key

    translation += " #{I18n.t(secondary_key, min: @opts[:min], max: @opts[:max])}"
    translation
  end

  def ensure_is_valid_value!(new_value)
    unless is_valid_value?(new_value)
      raise Discourse::InvalidParameters.new invalid_value_error_message
    end
  end

  def has_min?
    min = @opts[:min]
    (min.is_a?(::Integer) || min.is_a?(::Float)) && min != -::Float::INFINITY
  end

  def has_max?
    max = @opts[:max]
    (max.is_a?(::Integer) || max.is_a?(::Float)) && max != ::Float::INFINITY
  end

  class Objects < self
    def value
      has_record? ? db_record.json_value : default.map!(&:deep_stringify_keys)
    end

    def value=(objects)
      # TODO: Validate the objects against the schema

      record = has_record? ? db_record : create_record!
      record.json_value = objects
      record.save!
      record.json_value
    end
  end

  class List < self
    def list_type
      @opts[:list_type]
    end
  end

  class String < self
    def is_valid_value?(new_value)
      (@opts[:min]..@opts[:max]).include? new_value.to_s.length
    end

    def textarea
      @opts[:textarea]
    end

    def json_schema
      begin
        JSON.parse(@opts[:json_schema])
      rescue StandardError
        false
      end
    end
  end

  class Bool < self
    def self.cast(value)
      [true, "true"].include?(value)
    end

    def value
      self.class.cast(super)
    end

    def value=(new_value)
      new_value = (self.class.cast(new_value)).to_s
      super(new_value)
    end
  end

  class Integer < self
    def self.cast(value)
      value.to_i
    end

    def value
      self.class.cast(super)
    end

    def value=(new_value)
      super(self.class.cast(new_value))
    end

    def is_valid_value?(new_value)
      (@opts[:min]..@opts[:max]).include? new_value.to_i
    end
  end

  class Float < self
    def self.cast(value)
      value.to_f
    end

    def value
      self.class.cast(super)
    end

    def value=(new_value)
      super(self.class.cast(new_value))
    end

    def is_valid_value?(new_value)
      (@opts[:min]..@opts[:max]).include? new_value.to_f
    end
  end

  class Enum < self
    def value
      val = super
      match = choices.find { |choice| choice == val || choice.to_s == val }
      match || val
    end

    def is_valid_value?(new_value)
      choices.include?(new_value) || choices.map(&:to_s).include?(new_value)
    end

    def choices
      @opts[:choices]
    end
  end

  class Upload < self
    def value
      has_record? ? cdn_url(db_record.value) : default
    end

    def default
      upload_id = default_upload_id
      return if upload_id.blank?

      cdn_url(upload_id)
    end

    def value=(new_value)
      if new_value.present?
        if new_value == default
          new_value = default_upload_id
        else
          upload = ::Upload.find_by(url: new_value)
          new_value = upload.id if upload.present?
        end
      end

      super(new_value)
    end

    private

    def cdn_url(upload_id)
      return if upload_id.blank?

      upload = ::Upload.find_by_id(upload_id.to_i)
      return if upload.blank?

      Discourse.store.cdn_url(upload.url)
    end

    def default_upload_id
      theme_field =
        theme.theme_fields.find_by(name: @default, type_id: ThemeField.types[:theme_upload_var])
      return if theme_field.blank?

      theme_field.upload_id
    end
  end
end
