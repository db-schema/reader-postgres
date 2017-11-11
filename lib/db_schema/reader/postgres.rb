require 'db_schema/definitions'
require_relative 'postgres/table'
require_relative 'postgres/version'

module DbSchema
  module Reader
    class Postgres
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
