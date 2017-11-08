require 'db_schema/definitions'
require_relative 'postgres/table'
require_relative 'postgres/version'

module DbSchema
  module Reader
    module Postgres
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

      class << self
        def read_schema(connection)
          Definitions::Schema.new(
            tables:     read_tables(connection),
            enums:      read_enums(connection),
            extensions: read_extensions(connection)
          )
        end

        def read_tables(connection)
          connection.tables.map do |table_name|
            read_table(table_name, connection)
          end
        end

        def read_table(table_name, connection)
          Table.new(connection, table_name).read
        end

        def read_enums(connection)
          connection[ENUMS_QUERY].map do |enum_data|
            Definitions::Enum.new(enum_data[:name].to_sym, enum_data[:values].map(&:to_sym))
          end
        end

        def read_extensions(connection)
          connection[EXTENSIONS_QUERY].map do |extension_data|
            Definitions::Extension.new(extension_data[:extname].to_sym)
          end
        end
      end
    end
  end
end
