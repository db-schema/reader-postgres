require 'db_schema/definitions'
require_relative 'postgres/table'
require_relative 'postgres/version'

module DbSchema
  module Reader
    class Postgres
      COLUMN_NAMES_QUERY = <<-SQL.freeze
   SELECT c.table_name,
          c.column_name AS name,
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
      SQL

      CONSTRAINTS_QUERY = <<-SQL.freeze
SELECT relname AS table_name,
       conname AS name,
       pg_get_expr(conbin, conrelid, true) AS condition
  FROM pg_constraint, pg_class
 WHERE conrelid = pg_class.oid
   AND contype = 'c'
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
        connection.tables.map do |table_name|
          read_table(table_name)
        end
      end

      def read_table(table_name)
        Table.new(connection, table_name).read
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
    end
  end
end
