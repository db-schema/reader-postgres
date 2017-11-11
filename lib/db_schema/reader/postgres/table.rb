module DbSchema
  module Reader
    class Postgres
      class Table
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

        COLUMN_NAMES_QUERY = <<-SQL.freeze
   SELECT c.column_name AS name,
          c.ordinal_position AS pos,
          c.column_default AS default,
          c.is_nullable AS null,
          c.data_type AS type,
          c.udt_name AS custom_type_name,
          c.character_maximum_length AS char_length,
          c.numeric_precision AS num_precision,
          c.numeric_scale AS num_scale,
          c.datetime_precision AS dt_precision,
          c.interval_type,
          e.data_type AS element_type,
          e.udt_name AS element_custom_type_name
     FROM information_schema.columns AS c
LEFT JOIN information_schema.element_types AS e
       ON e.object_catalog = c.table_catalog
      AND e.object_schema = c.table_schema
      AND e.object_name = c.table_name
      AND e.object_type = 'TABLE'
      AND e.collection_type_identifier = c.dtd_identifier
    WHERE c.table_schema = 'public'
      AND c.table_name = ?
        SQL

        CONSTRAINTS_QUERY = <<-SQL.freeze
SELECT conname AS name,
       pg_get_expr(conbin, conrelid, true) AS condition
  FROM pg_constraint, pg_class
 WHERE conrelid = pg_class.oid
   AND relname = ?
   AND contype = 'c'
        SQL

        INDEXES_QUERY = <<-SQL.freeze
   SELECT relname AS name,
          indkey AS column_positions,
          indisunique AS unique,
          indoption AS index_options,
          pg_get_expr(indpred, indrelid, true) AS condition,
          amname AS index_type,
          indexrelid AS index_oid
     FROM pg_class, pg_index
LEFT JOIN pg_opclass
       ON pg_opclass.oid = ANY(pg_index.indclass::int[])
LEFT JOIN pg_am
       ON pg_am.oid = pg_opclass.opcmethod
    WHERE pg_class.oid = pg_index.indexrelid
      AND pg_class.oid IN (
     SELECT indexrelid
       FROM pg_index, pg_class
      WHERE pg_class.relname = ?
        AND pg_class.oid = pg_index.indrelid
        AND indisprimary != 't'
)
  GROUP BY name, column_positions, indisunique, index_options, condition, index_type, index_oid
        SQL

        EXPRESSION_INDEXES_QUERY = <<-SQL.freeze
    WITH index_ids AS (SELECT unnest(?) AS index_id),
         elements AS (SELECT unnest(?) AS element)
  SELECT index_id,
         array_agg(pg_get_indexdef(index_id, element, 't')) AS definitions
    FROM index_ids, elements
GROUP BY index_id;
        SQL

        attr_reader :connection, :table_name

        def initialize(connection, table_name)
          @connection = connection
          @table_name = table_name
        end

        def read
          primary_key_name = connection.primary_key(table_name)

          fields = columns_data.map do |column_data|
            build_field(column_data, primary_key: column_data[:name] == primary_key_name)
          end

          indexes = indexes_data.map do |index_data|
            Definitions::Index.new(index_data)
          end.sort_by(&:name)

          foreign_keys = connection.foreign_key_list(table_name).map do |foreign_key_data|
            build_foreign_key(foreign_key_data)
          end

          checks = connection[CONSTRAINTS_QUERY, table_name.to_s].map do |check_data|
            Definitions::CheckConstraint.new(
              name:      check_data[:name].to_sym,
              condition: check_data[:condition]
            )
          end

          Definitions::Table.new(
            table_name,
            fields:       fields,
            indexes:      indexes,
            checks:       checks,
            foreign_keys: foreign_keys
          )
        end

      private
        def columns_data
          @columns_data ||= connection[COLUMN_NAMES_QUERY, table_name.to_s]
        end

        def indexes_data
          column_names = columns_data.reduce({}) do |names, column|
            names.merge(column[:pos] => column[:name].to_sym)
          end

          indexes_data     = connection[INDEXES_QUERY, table_name.to_s].to_a
          expressions_data = index_expressions_data(indexes_data)

          indexes_data.map do |index|
            positions = index[:column_positions].split(' ').map(&:to_i)
            options   = index[:index_options].split(' ').map(&:to_i)

            columns = positions.zip(options).map do |column_position, column_order_options|
              options = case column_order_options
              when 0
                {}
              when 3
                { order: :desc }
              when 2
                { nulls: :first }
              when 1
                { order: :desc, nulls: :last }
              end

              if column_position.zero?
                expression = expressions_data.fetch(index[:index_oid]).shift
                DbSchema::Definitions::Index::Expression.new(expression, **options)
              else
                DbSchema::Definitions::Index::TableField.new(column_names.fetch(column_position), **options)
              end
            end

            {
              name:      index[:name].to_sym,
              columns:   columns,
              unique:    index[:unique],
              type:      index[:index_type].to_sym,
              condition: index[:condition]
            }
          end
        end

        def index_expressions_data(indexes_data)
          all_positions, max_position = {}, 0

          indexes_data.each do |index_data|
            positions = index_data[:column_positions].split(' ').map(&:to_i)
            expression_positions = positions.each_index.select { |i| positions[i].zero? }

            if expression_positions.any?
              all_positions[index_data[:index_oid]] = expression_positions
              max_position = [max_position, expression_positions.max].max
            end
          end

          if all_positions.any?
            connection[
              EXPRESSION_INDEXES_QUERY,
              Sequel.pg_array(all_positions.keys),
              Sequel.pg_array((1..max_position.succ).to_a)
            ].each_with_object({}) do |index_data, indexes_data|
              index_id = index_data[:index_id]
              expressions = all_positions[index_id].map { |pos| index_data[:definitions][pos] }

              indexes_data[index_id] = expressions
            end
          else
            {}
          end
        end

        def build_field(data, primary_key: false)
          type = data[:type].to_sym.downcase
          if type == :'user-defined'
            type = data[:custom_type_name].to_sym
          end

          nullable = (data[:null] != 'NO')

          unless primary_key || data[:default].nil?
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
            primary_key: primary_key,
            null:        nullable,
            default:     default,
            **options
          )
        end

        def build_foreign_key(data)
          keys = if data[:key] == [primary_key_for(data[:table])]
            [] # this foreign key references a primary key
          else
            data[:key]
          end

          Definitions::ForeignKey.new(
            name:       data[:name],
            fields:     data[:columns],
            table:      data[:table],
            keys:       keys,
            on_delete:  data[:on_delete],
            on_update:  data[:on_update],
            deferrable: data[:deferrable]
          )
        end

        def primary_key_for(table_name)
          if pkey = connection.primary_key(table_name)
            pkey.to_sym
          end
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
