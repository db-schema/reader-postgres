# DbSchema::Reader::Postgres

DbSchema::Reader::Postgres is a library for reading the database
structure from PostgreSQL.

## Installation

Add this line to your application's Gemfile:

``` ruby
gem 'db_schema-reader-postgres'
```

And then execute:

``` sh
$ bundle
```
Or install it yourself as:

``` ruby
$ gem install db_schema-reader-postgres
```

## Usage

First you need a Sequel connection object with `:pg_enum` and `:pg_array`
Sequel extensions enabled; once you have that object just pass it to
the `.read_schema` method to get full database schema definition:

``` ruby
connection = Sequel.connect(adapter: 'postgres', database: 'db_schema_test').tap do |db|
  db.extension :pg_enum
  db.extension :pg_array
end

DbSchema::Reader::Postgres.read_schema(connection)
# => #<DbSchema::Definitions::Schema ...>
```

Other useful methods are `.read_tables`, `.read_table`, `.read_enums` & `.read_extensions`;
they return definitions of respective parts of the database schema:

``` ruby
DbSchema::Reader::Postgres.read_tables(connection)
# => [#<DbSchema::Definitions::Table ...>, #<DbSchema::Definitions::Table ...>, ...]

DbSchema::Reader::Postgres.read_table(:users, connection)
# => #<DbSchema::Definitions::Table name=:users ...>

DbSchema::Reader::Postgres.read_enums(connection)
# => [#<DbSchema::Definitions::Enum ...>, #<DbSchema::Definitions::Enum ...>, ...]

DbSchema::Reader::Postgres.read_extensions(connection)
# => [#<DbSchema::Definitions::Extension ...>, #<DbSchema::Definitions::Extension ...>, ...]
```

DbSchema::Reader::Postgres emits objects of classes from
[DbSchema::Definitions](https://github.com/db-schema/definitions).
Read [here](https://github.com/db-schema/core/wiki/Schema-analysis-DSL)
how to analyze the schema and all of it's parts.

## Development

After checking out the repo, run `bin/setup` to install dependencies.
Then, run `rake spec` to run the tests. You can also run `bin/console`
for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.
To release a new version, update the version number in `version.rb`,
and then run `bundle exec rake release`, which will create a git tag
for the version, push git commits and tags, and push the `.gem` file
to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub
at [db-schema/reader-postgres](https://github.com/db-schema/reader-postgres).
This project is intended to be a safe, welcoming space for collaboration,
and contributors are expected to adhere to the
[Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of
the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the DbSchema::Definitions project’s codebases,
issue trackers, chat rooms and mailing lists is expected to follow
the [code of conduct](https://github.com/db-schema/reader-postgres/blob/master/CODE_OF_CONDUCT.md).
