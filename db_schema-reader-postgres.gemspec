lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'db_schema/reader/postgres/version'

Gem::Specification.new do |spec|
  spec.name          = 'db_schema-reader-postgres'
  spec.version       = DbSchema::Reader::Postgres::VERSION
  spec.authors       = ['Vsevolod Romashov']
  spec.email         = ['7@7vn.ru']

  spec.summary       = 'Database schema reader for PostgreSQL'
  spec.description   = 'A database structure reader for PostgreSQL with support for tables, fields, indexes, foreign keys, check constraints, enum types and extensions.'
  spec.homepage      = 'https://github.com/db-schema/reader-postgres'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^spec/}) }
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'sequel'
  spec.add_runtime_dependency 'pg'
  spec.add_runtime_dependency 'db_schema-definitions', '= 0.2.rc1'

  spec.add_development_dependency 'bundler', '~> 1.16'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'pry'
  spec.add_development_dependency 'awesome_print', '~> 1.7'

  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'guard-rspec'
  spec.add_development_dependency 'terminal-notifier'
  spec.add_development_dependency 'terminal-notifier-guard'
end
