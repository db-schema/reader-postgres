require 'db_schema/definitions'
require_relative 'postgres/table'
require_relative 'postgres/version'

module DbSchema
  module Reader
    class Postgres
      TABLES_QUERY = <<-SQL.freeze
SELECT table_name
  FROM information_schema.tables
 WHERE table_type = 'BASE TABLE'
   AND table_schema = 'public'
      SQL

      COLUMNS_QUERY = <<-SQL.freeze
   SELECT c.table_name,
          c.column_name AS name,
          c.ordinal_position AS pos,
          c.column_default AS default,
          c.is_nullable AS null,
          c.data_type AS type,
          c.is_identity,
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
      SQL

      INDEXES_QUERY = <<-SQL.freeze
   SELECT table_rel.relname AS table_name,
          pg_class.relname AS name,
          indkey AS column_positions,
          indisprimary AS primary,
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
     JOIN pg_class AS table_rel
       ON table_rel.oid = pg_index.indrelid
     JOIN pg_namespace
       ON pg_namespace.oid = table_rel.relnamespace
    WHERE pg_class.oid = pg_index.indexrelid
      AND pg_namespace.nspname = 'public'
 GROUP BY table_name, name, column_positions, indisprimary, indisunique, index_options, condition, index_type, index_oid
      SQL

      EXPRESSION_INDEXES_QUERY = <<-SQL.freeze
    WITH index_ids AS (SELECT unnest(?) AS index_id),
         elements AS (SELECT unnest(?) AS element)
  SELECT index_id,
         array_agg(pg_get_indexdef(index_id, element, 't')) AS definitions
    FROM index_ids, elements
GROUP BY index_id;
      SQL

      CONSTRAINTS_QUERY = <<-SQL.freeze
   SELECT owner_table.relname AS table_name,
          constr.conname AS name,
          pg_get_expr(conbin, conrelid, true) AS condition,
          referenced_table.relname AS referenced,
          conkey,
          confkey,
          confupdtype AS on_update,
          confdeltype AS on_delete,
          condeferrable AS deferrable,
          constr.contype AS type
     FROM pg_constraint AS constr
     JOIN pg_class AS owner_table
       ON owner_table.oid = constr.conrelid
LEFT JOIN pg_class AS referenced_table
       ON referenced_table.oid = constr.confrelid
    WHERE contype IN ('c', 'f');
      SQL

      ENUMS_QUERY = <<-SQL.freeze
  SELECT t.typname AS name,
         array_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
    FROM pg_enum AS e
    JOIN pg_type AS t
      ON t.oid = e.enumtypid
GROUP BY name
      SQL

      EXTENSIONS_QUERY = <<-SQL.freeze
SELECT extname
  FROM pg_extension
 WHERE extname != 'plpgsql'
      SQL

      attr_reader :connection

      def initialize(connection)
        @connection = connection
      end

      def read_schema
        Definitions::Schema.new(
          tables:     read_tables,
          enums:      read_enums,
          extensions: read_extensions
        )
      end

      def read_tables
        checks_data, foreign_keys_data = constraints_data

        table_names.map do |table_name|
          Table.new(
            table_name.to_sym,
            columns_data[table_name],
            indexes_data[table_name],
            checks_data[table_name],
            foreign_keys_data[table_name]
          ).definition
        end
      end

      def read_enums
        connection[ENUMS_QUERY].map do |enum_data|
          Definitions::Enum.new(enum_data[:name].to_sym, enum_data[:values].map(&:to_sym))
        end
      end

      def read_extensions
        connection[EXTENSIONS_QUERY].map do |extension_data|
          Definitions::Extension.new(extension_data[:extname].to_sym)
        end
      end

    private
      def table_names
        @table_names ||= connection[TABLES_QUERY].to_a.map { |row| row[:table_name] }
      end

      def columns_data
        @columns_data ||= connection[COLUMNS_QUERY].to_a.group_by do |column|
          column[:table_name]
        end
      end

      def indexes_data
        @indexes_data ||= begin
          raw_data = connection[INDEXES_QUERY].map do |index_data|
            index_data.merge(
              column_positions: index_data[:column_positions].split(' ').map(&:to_i),
              index_options:    index_data[:index_options].split(' ').map(&:to_i)
            )
          end

          expressions_data = index_expressions_data(raw_data)

          raw_data.map do |index_data|
            columns = index_data[:column_positions].map do |position|
              if position.zero?
                expressions_data.fetch(index_data[:index_oid]).shift
              else
                get_field_name(index_data[:table_name], position)
              end
            end

            index_data.delete(:index_oid)
            index_data.delete(:column_positions)
            index_data.merge(columns: columns)
          end.group_by { |index| index[:table_name] }.tap { |h| h.default = [] }
        end
      end

      def index_expressions_data(indexes_data)
        all_positions, max_position = {}, 0

        indexes_data.each do |index_data|
          positions = index_data[:column_positions]
          expression_positions = positions.each_index.select do |i|
            positions[i].zero?
          end

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

      def constraints_data
        checks       = Hash.new { |h, k| h[k] = [] }
        foreign_keys = Hash.new { |h, k| h[k] = [] }

        connection[CONSTRAINTS_QUERY].each do |constraint|
          case constraint[:type]
          when 'c'
            checks[constraint[:table_name]] << {
              name:      constraint[:name],
              condition: constraint[:condition]
            }
          when 'f'
            fields = constraint[:conkey].map do |position|
              get_field_name(constraint[:table_name], position)
            end

            keys = constraint[:confkey].map do |position|
              get_field_name(constraint[:referenced], position)
            end

            pkey = indexes_data.fetch(constraint[:referenced]).find { |index| index[:primary] }
            keys = [] if !pkey.nil? && keys == pkey.fetch(:columns) # this foreign key references a primary key

            foreign_keys[constraint[:table_name]] << {
              name:       constraint[:name],
              referenced: constraint[:referenced],
              fields:     fields,
              keys:       keys,
              on_update:  constraint[:on_update],
              on_delete:  constraint[:on_delete],
              deferrable: constraint[:deferrable]
            }
          else
            raise "Unknown constraint type #{constraint[:type].inspect}"
          end
        end

        [checks, foreign_keys]
      end

      def get_field_name(table, position)
        columns_data.fetch(table).find do |column|
          column[:pos] == position
        end.fetch(:name).to_sym
      end
    end
  end
end
