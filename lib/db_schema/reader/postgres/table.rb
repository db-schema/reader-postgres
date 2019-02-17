module DbSchema
  module Reader
    class Postgres
      class Table
        SERIAL_TYPES = {
          smallint: :smallserial,
          integer:  :serial,
          bigint:   :bigserial
        }.freeze

        DEFAULT_VALUE = /\A(
          ('(?<date>\d{4}-\d{2}-\d{2})'::date)
            |
          ('(?<time>\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}([+-]\d{2})?)'::timestamp)
            |
          ('(?<string>.*)')
            |
          (?<float>\d+\.\d+)
            |
          (?<integer>\d+)
            |
          (?<boolean>true|false)
        )/x

        FKEY_ACTIONS = {
          a: :no_action,
          r: :restrict,
          c: :cascade,
          n: :set_null,
          d: :set_default
        }.freeze

        attr_reader :table_name, :fields_data, :indexes_data, :checks_data, :fkeys_data

        def initialize(table_name, fields_data, indexes_data, checks_data, fkeys_data)
          @table_name   = table_name
          @fields_data  = fields_data
          @indexes_data = indexes_data
          @checks_data  = checks_data
          @fkeys_data   = fkeys_data
        end

        def definition
          Definitions::Table.new(
            table_name,
            fields:       fields,
            indexes:      indexes,
            checks:       checks,
            foreign_keys: foreign_keys
          )
        end

        def fields
          fields_data.map do |field_data|
            build_field(field_data)
          end
        end

        def indexes
          indexes_data.map do |index_data|
            build_index(index_data)
          end.sort_by(&:name)
        end

        def checks
          checks_data.map do |check_data|
            Definitions::CheckConstraint.new(
              name:      check_data[:name].to_sym,
              condition: check_data[:condition]
            )
          end
        end

        def foreign_keys
          fkeys_data.map do |foreign_key_data|
            build_foreign_key(foreign_key_data)
          end
        end

      private
        def build_field(data)
          type = data[:type].to_sym.downcase
          if type == :'user-defined'
            type = data[:custom_type_name].to_sym
          end

          serial_type = SERIAL_TYPES[type]

          nullable = (data[:null] != 'NO')

          if data[:is_identity] == 'YES'
            type     = serial_type
            nullable = true
            default  = nil
          elsif !data[:default].nil?
            serial_field_default = "nextval('#{table_name}_#{data[:name]}_seq'::regclass)"

            if !serial_type.nil? && !nullable && data[:default] == serial_field_default
              type     = serial_type
              nullable = true
              default  = nil
            else
              default = if match = DEFAULT_VALUE.match(data[:default])
                if match[:date]
                  Date.parse(match[:date])
                elsif match[:time]
                  Time.parse(match[:time])
                elsif match[:string]
                  match[:string]
                elsif match[:integer]
                  match[:integer].to_i
                elsif match[:float]
                  match[:float].to_f
                elsif match[:boolean]
                  match[:boolean] == 'true'
                end
              else
                data[:default].to_sym
              end
            end
          end

          options = case type
          when :character, :'character varying', :bit, :'bit varying'
            rename_keys(
              filter_by_keys(data, :char_length),
              char_length: :length
            )
          when :numeric
            rename_keys(
              filter_by_keys(data, :num_precision, :num_scale),
              num_precision: :precision,
              num_scale: :scale
            )
          when :interval
            rename_keys(
              filter_by_keys(data, :dt_precision, :interval_type),
              dt_precision: :precision
            ) do |attributes|
              if interval_type = attributes.delete(:interval_type)
                attributes[:fields] = interval_type.gsub(/\(\d\)/, '').downcase.to_sym
              end
            end
          when :array
            rename_keys(
              filter_by_keys(data, :element_type, :element_custom_type_name)
            ) do |attributes|
              attributes[:element_type] = if attributes[:element_type] == 'USER-DEFINED'
                attributes[:element_custom_type_name]
              else
                attributes[:element_type]
              end.to_sym
            end
          else
            {}
          end

          Definitions::Field.build(
            data[:name].to_sym,
            type,
            null:    nullable,
            default: default,
            **options
          )
        end

        def build_index(data)
          columns = data[:columns].zip(data[:index_options]).map do |column, order_options|
            options = case order_options
            when 0
              {}
            when 3
              { order: :desc }
            when 2
              { nulls: :first }
            when 1
              { order: :desc, nulls: :last }
            end

            if column.is_a?(String)
              DbSchema::Definitions::Index::Expression.new(column, **options)
            else
              DbSchema::Definitions::Index::TableField.new(column, **options)
            end
          end

          Definitions::Index.new(
            name:      data[:name].to_sym,
            columns:   columns,
            unique:    data[:unique],
            primary:   data[:primary],
            type:      data[:index_type].to_sym,
            condition: data[:condition]
          )
        end

        def build_foreign_key(data)
          Definitions::ForeignKey.new(
            name:       data[:name].to_sym,
            fields:     data[:fields],
            table:      data[:referenced].to_sym,
            keys:       data[:keys],
            on_update:  FKEY_ACTIONS.fetch(data[:on_update].to_sym),
            on_delete:  FKEY_ACTIONS.fetch(data[:on_delete].to_sym),
            deferrable: data[:deferrable]
          )
        end

        # TODO: replace following methods with Transproc
        def rename_keys(hash, mapping = {})
          hash.reduce({}) do |final_hash, (key, value)|
            new_key = mapping.fetch(key, key)
            final_hash.merge(new_key => value)
          end.tap do |final_hash|
            yield(final_hash) if block_given?
          end
        end

        def filter_by_keys(hash, *needed_keys)
          hash.reduce({}) do |final_hash, (key, value)|
            if needed_keys.include?(key)
              final_hash.merge(key => value)
            else
              final_hash
            end
          end
        end
      end
    end
  end
end
