# frozen_string_literal: true
require "spec_helper"

describe GraphQL::Schema::Directive do
  class MultiWord < GraphQL::Schema::Directive
  end

  it "uses a downcased class name" do
    assert_equal "multiWord", MultiWord.graphql_name
  end

  module DirectiveTest
    class Secret < GraphQL::Schema::Directive
      argument :top_secret, Boolean
      locations(FIELD_DEFINITION, ARGUMENT_DEFINITION)
    end

    class Thing < GraphQL::Schema::Object
      field :name, String, null: false do
        directive Secret, top_secret: true
        argument :nickname, Boolean, required: false do
          directive Secret, top_secret: false
        end
      end
    end
  end

  it "can be added to schema definitions" do
    field = DirectiveTest::Thing.fields.values.first

    assert_equal [DirectiveTest::Secret], field.directives.map(&:class)
    assert_equal [field], field.directives.map(&:owner)
    assert_equal [true], field.directives.map{ |d| d.arguments[:top_secret] }

    argument = field.arguments.values.first
    assert_equal [DirectiveTest::Secret], argument.directives.map(&:class)
    assert_equal [argument], argument.directives.map(&:owner)
    assert_equal [false], argument.directives.map{ |d| d.arguments[:top_secret] }
  end

  it "raises an error when added to the wrong thing" do
    err = assert_raises ArgumentError do
      Class.new(GraphQL::Schema::Object) do
        graphql_name "Stuff"
        directive DirectiveTest::Secret
      end
    end

    expected_message = "Directive `@secret` can't be attached to Stuff because OBJECT isn't included in its locations (FIELD_DEFINITION, ARGUMENT_DEFINITION).

Use `locations(OBJECT)` to update this directive's definition, or remove it from Stuff.
"

    assert_equal expected_message, err.message
  end

  it "validates arguments" do
    err = assert_raises ArgumentError do
      GraphQL::Schema::Field.from_options(
        name: :something,
        type: String,
        null: false,
        owner: DirectiveTest::Thing,
        directives: { DirectiveTest::Secret => {} }
      )
    end

    assert_equal "@secret.topSecret is required, but no value was given", err.message

    err2 = assert_raises ArgumentError do
      GraphQL::Schema::Field.from_options(
        name: :something,
        type: String,
        null: false,
        owner: DirectiveTest::Thing,
        directives: { DirectiveTest::Secret => { top_secret: 12.5 } }
      )
    end

    assert_equal "@secret.topSecret is required, but no value was given", err2.message
  end

  module RuntimeDirectiveTest
    class CountFields < GraphQL::Schema::Directive
      locations(FIELD, FRAGMENT_SPREAD, INLINE_FRAGMENT)

      def self.resolve(obj, args, ctx)
        path = ctx[:current_path]
        result = nil
        ctx.dataloader.run_isolated do
          result = yield
          GraphQL::Execution::Interpreter::Resolve.resolve_all([result], ctx.dataloader)
        end

        ctx[:count_fields] ||= Hash.new { |h, k| h[k] = [] }
        field_count = result.respond_to?(:graphql_result_data) ? result.graphql_result_data.size : 1
        ctx[:count_fields][path] << field_count
        nil # this does nothing
      end
    end

    class Thing < GraphQL::Schema::Object
      field :name, String, null: false
    end

    module HasThings
      include GraphQL::Schema::Interface
      field :thing, Thing, null: false, extras: [:ast_node]

      def thing(ast_node:)
        context[:name_resolved_count] ||= 0
        context[:name_resolved_count] += 1
        { name: ast_node.alias || ast_node.name }
      end

      field :lazy_thing, Thing, null: false, extras: [:ast_node]
      def lazy_thing(ast_node:)
        -> { thing(ast_node: ast_node) }
      end

      field :dataloaded_thing, Thing, null: false, extras: [:ast_node]
      def dataloaded_thing(ast_node:)
        dataloader.with(ThingSource).load(ast_node.alias || ast_node.name)
      end
    end

    Thing.implements(HasThings)

    class Query < GraphQL::Schema::Object
      implements HasThings
    end

    class ThingSource < GraphQL::Dataloader::Source
      def fetch(names)
        names.map { |n| { name: n } }
      end
    end

    class Schema < GraphQL::Schema
      query(Query)
      directive(CountFields)
      lazy_resolve(Proc, :call)
      use GraphQL::Dataloader
    end
  end

  describe "runtime directives" do
    it "works with fragment spreads, inline fragments, and fields" do
      query_str = <<-GRAPHQL
      {
        t1: dataloadedThing {
          t1n: name @countFields
        }
        ... @countFields {
          t2: thing { t2n: name }
          t3: thing { t3n: name }
        }

        t3: thing { t3n: name }

        t4: lazyThing {
          ...Thing @countFields
        }

        t5: thing {
          n5: name
          t5d: dataloadedThing {
            t5dl: lazyThing { t5dln: name @countFields }
          }
        }
      }

      fragment Thing on Thing {
        n1: name
        n2: name
        n3: name
      }
      GRAPHQL

      res = RuntimeDirectiveTest::Schema.execute(query_str)
      expected_data = {
        "t1" => {
          "t1n" => "t1",
        },
        "t2"=>{"t2n"=>"t2"},
        "t3"=>{"t3n"=>"t3"},
        "t4" => {
          "n1" => "t4",
          "n2" => "t4",
          "n3" => "t4",
        },
        "t5"=>{"n5"=>"t5", "t5d"=>{"t5dl"=>{"t5dln"=>"t5dl"}}},
      }
      assert_equal expected_data, res["data"]

      expected_counts = {
        ["t1", "t1n"] => [1],
        [] => [2],
        ["t4"] => [3],
        ["t5", "t5d", "t5dl", "t5dln"] => [1],
      }
      assert_equal expected_counts, res.context[:count_fields]
    end

    it "runs things twice when they're in with-directive and without-directive parts of the query" do
      query_str = <<-GRAPHQL
      {
        t1: thing { name }      # name_resolved_count = 1
        t2: thing { name }      # name_resolved_count = 2

        ... @countFields {
          t1: thing { name }    # name_resolved_count = 3
          t3: thing { name }    # name_resolved_count = 4
        }

        t3: thing { name }      # name_resolved_count = 5
        ... {
          t2: thing { name @countFields } # This is merged back into `t2` above
        }
      }
      GRAPHQL
      res = RuntimeDirectiveTest::Schema.execute(query_str)
      expected_data = { "t1" => { "name" => "t1"}, "t2" => { "name" => "t2" }, "t3" => { "name" => "t3" } }
      assert_equal expected_data, res["data"]

      expected_counts = {
        [] => [2],
        ["t2", "name"] => [1],
       }
      assert_equal expected_counts, res.context[:count_fields]
      assert_equal 5, res.context[:name_resolved_count]
    end
  end

  describe "raising an error from an argument" do
    class DirectiveErrorSchema < GraphQL::Schema
      class MyDirective < GraphQL::Schema::Directive
        locations GraphQL::Schema::Directive::QUERY, GraphQL::Schema::Directive::FIELD

        argument :input, String, prepare: ->(input, ctx) {
          raise GraphQL::ExecutionError, "invalid argument"
        }
      end

      class QueryType < GraphQL::Schema::Object
        field :hello, String, null: false

        def hello
          "Hello World!"
        end
      end
      query QueryType

      directive MyDirective
    end

    it "halts execution and adds an error to the error key" do
      result = DirectiveErrorSchema.execute(<<-GQL)
      query @myDirective(input: "hi") {
        hello
      }
      GQL

      assert_equal({}, result["data"])
      assert_equal ["invalid argument"], result["errors"].map { |e| e["message"] }
      assert_equal [[{"line"=>1, "column"=>13}]], result["errors"].map { |e| e["locations"] }

      result2 = DirectiveErrorSchema.execute(<<-GQL)
      query {
        hello
        hello2: hello @myDirective(input: "hi")
      }
      GQL

      assert_equal({ "hello" => "Hello World!" }, result2["data"])
      assert_equal ["invalid argument"], result2["errors"].map { |e| e["message"] }
      assert_equal [[{"line"=>3, "column"=>23}]], result2["errors"].map { |e| e["locations"] }
    end
  end

  describe ".resolve_each" do
    class ResolveEachSchema < GraphQL::Schema
      class FilterByIndex < GraphQL::Schema::Directive
        locations FIELD
        argument :select, String

        def self.resolve_each(object, args, context)
          if context[:current_path].last.public_send(args[:select])
            yield
          else
            # Don't send a value
          end
        end

        def self.resolve(obj, args, ctx)
          value = yield
          value.values.compact!
          value
        end
      end

      class Query < GraphQL::Schema::Object
        field :numbers, [Integer]
        def numbers
          [0,1,2,3,4,5]
        end
      end

      query(Query)
      directive(FilterByIndex)
    end

    it "is called for each item in a list during enumeration" do
      res = ResolveEachSchema.execute("{ numbers @filterByIndex(select: \"even?\")}")
      assert_equal [0,2,4], res["data"]["numbers"]
      res = ResolveEachSchema.execute("{ numbers @filterByIndex(select: \"odd?\")}")
      assert_equal [1,3,5], res["data"]["numbers"]
    end
  end
end
