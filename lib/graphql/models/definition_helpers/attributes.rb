module GraphQL
  module Models
    module DefinitionHelpers
      def self.type_to_graphql_type(type)
        case type
        when :boolean
          types.Boolean
        when :integer
          types.Int
        when :float
          types.Float
        when :daterange, :tsrange
          types[!types.String]
        else
          resolved = ScalarTypes.registered_type(type) || types.String
          resolved.is_a?(Proc) ? resolved.call : resolved
        end
      end

      def self.get_column(model_type, name)
        col = model_type.columns.detect { |c| c.name == name.to_s }
        raise ArgumentError.new("The attribute #{name} wasn't found on model #{model_type.name}.") unless col

        if model_type.graphql_enum_types.include?(name)
          graphql_type = model_type.graphql_enum_types[name]
        else
          graphql_type = type_to_graphql_type(col.type)
        end

        if col.array
          graphql_type = types[graphql_type]
        end

        return OpenStruct.new({
          is_range: /range\z/ === col.type.to_s,
          camel_name: name.to_s.camelize(:lower).to_sym,
          graphql_type: graphql_type
        })
      end

      def self.range_to_graphql(value)
        return nil unless value

        begin
          [value.first, value.last_included]
        rescue TypeError
          [value.first, value.last]
        end
      end

      # Adds a field to the graph type which is resolved by accessing an attribute on the model. Traverses
      # across has_one associations specified in the path. The resolver returns a promise.
      # @param graph_type The GraphQL::ObjectType that the field is being added to
      # @param model_type The class object for the model that defines the attribute
      # @param path The associations (in order) that need to be loaded, starting from the graph_type's model
      # @param attribute The name of the attribute that is accessed on the target model_type
      def self.define_attribute(graph_type, model_type, path, attribute, options)
        graph_model_type = graph_type.instance_variable_get(:@model_type)

        column = get_column(model_type, attribute)
        field_name = options[:name] || column.camel_name

        DefinitionHelpers.register_field_metadata(graph_model_type, field_name, {
          macro: :attr,
          macro_type: :attribute,
          type_proc: -> { column.graphql_type },
          path: path,
          attribute: attribute,
          options: options
        })

        graph_type.fields[field_name.to_s] = GraphQL::Field.define do
          name field_name.to_s
          type column.graphql_type
          description options[:description] if options.include?(:description)
          deprecation_reason options[:deprecation_reason] if options.include?(:deprecation_reason)

          resolve -> (base_model, args, context) do
            DefinitionHelpers.load_and_traverse(base_model, path, context).then do |model|
              next nil unless model

              if column.is_range
                DefinitionHelpers.range_to_graphql(model.public_send(attribute))
              else
                if model_type.graphql_resolvers.include?(attribute)
                  resolve_proc = model_type.graphql_resolvers[attribute]
                  model.instance_exec(&resolve_proc)
                else
                  model.public_send(attribute)
                end
              end
            end
          end
        end
      end
    end
  end
end