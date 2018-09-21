# frozen_string_literal: true

module GraphQL
  module Execution
    class Interpreter
      # The center of execution state.
      # It's mutable as a performance consideration.
      #
      # @see dup It can be "branched" to create a divergent, parallel execution state.
      class Trace
        extend Forwardable
        def_delegators :query, :schema, :context
        attr_reader :query, :path, :objects, :result, :types, :lazies, :parent_trace

        def initialize(query:)
          # shared by the parent and all children:
          @query = query
          @debug = query.context[:debug_interpreter]
          @result = {}
          @parent_trace = nil
          @lazies = []
          @types_at_paths = Hash.new { |h, k| h[k] = {} }
          # Dup'd when the parent forks:
          @path = []
          @objects = []
          @types = []
        end

        def final_value
          if @result[:__completely_nulled]
            nil
          else
            @result
          end
        end

        # Copy bits of state that should be independent:
        # - @path, @objects, @types
        # Leave in place those that can be shared:
        # - @query, @result, @lazies
        def initialize_copy(original_trace)
          super
          @parent_trace = original_trace
          @path = @path.dup
          @objects = @objects.dup
          @types = @types.dup
        end

        def with_path(part)
          @path << part
          r = yield
          @path.pop
          r
        end

        def with_type(type)
          @types << type
          # TODO this seems janky
          set_type_at_path(type)
          r = yield
          @types.pop
          r
        end

        def with_object(obj)
          @objects << obj
          r = yield
          @objects.pop
          r
        end

        def inspect
          <<-TRACE
Path: #{@path.join(", ")}
Objects: #{@objects.map(&:inspect).join(",")}
Types: #{@types.map(&:inspect).join(",")}
Result: #{@result.inspect}
TRACE
        end

        # TODO delegate to a collector which does as it pleases with patches
        def write(value)
          if @result[:__completely_nulled]
            nil
          else
            res = @result ||= {}
            write_into_result(res, @path, value)
          end
        end

        def write_into_result(result, path, value, propagating_nil: false)
          if value.nil? && type_at(path).kind.non_null?
            # This nil is invalid, try writing it at the previous spot
            propagate_path = path[0..-2]
            debug "propagating_nil at #{path} (#{type_at(path).inspect})"
            if propagate_path.empty?
              # TODO this is a hack, but we need
              # some way for child traces to communicate
              # this to the parent.
              @result[:__completely_nulled] = true
            else
              write_into_result(result, propagate_path, value, propagating_nil: true)
            end
          else
            write_target = result
            path.each_with_index do |path_part, idx|
              next_part = path[idx + 1]
              if next_part.nil?
                debug "writing: (#{result.object_id}) #{path} -> #{value.inspect} (#{type_at(path).inspect})"
                if write_target[path_part].nil? || (propagating_nil)
                  write_target[path_part] = value
                else
                  raise "Invariant: Duplicate write to #{path} (previous: #{write_target[path_part].inspect}, new: #{value.inspect})"
                end
              else
                write_target = write_target.fetch(path_part, :__unset)
                if write_target.nil?
                  # TODO how can we _halt_ execution when this happens?
                  # rather than calculating the value but failing to write it,
                  # can we just not resolve those lazy things?
                  debug "Breaking #{path} on propagated `nil`"
                  break
                end
              end
            end
          end
          debug result.inspect
          nil
        end

        def after_lazy(obj)
          if schema.lazy?(obj)
            # Dup it now so that `path` etc are correct
            next_trace = self.dup
            next_trace.debug "Forked at #{next_trace.path} from #{trace_id} (#{obj.inspect})"
            @lazies << GraphQL::Execution::Lazy.new do
              next_trace.debug "Resumed at #{next_trace.path} #{obj.inspect}"
              method_name = schema.lazy_method_name(obj)
              begin
                inner_obj = obj.public_send(method_name)
                next_trace.after_lazy(inner_obj) do |really_next_trace, really_inner_obj|

                  yield(really_next_trace, really_inner_obj)
                end
              rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError => err
                yield(next_trace, err)
              end
            end
          else
            yield(self, obj)
          end
        end

        def arguments(arg_owner, ast_node)
          kwarg_arguments = {}
          ast_node.arguments.each do |arg|
            arg_defn = arg_owner.arguments[arg.name]
            # TODO not this
            catch(:skip) do
              value = arg_to_value(arg_defn.type, arg.value)
              kwarg_arguments[arg_defn.keyword] = value
            end
          end
          arg_owner.arguments.each do |name, arg_defn|
            if arg_defn.default_value? && !kwarg_arguments.key?(arg_defn.keyword)
              kwarg_arguments[arg_defn.keyword] = arg_defn.default_value
            end
          end
          kwarg_arguments
        end

        def arg_to_value(arg_defn, ast_value)
          if ast_value.is_a?(GraphQL::Language::Nodes::VariableIdentifier)
            # If it's not here, it will get added later
            if query.variables.key?(ast_value.name)
              query.variables[ast_value.name]
            else
              throw :skip
            end
          elsif arg_defn.is_a?(GraphQL::Schema::NonNull)
            arg_to_value(arg_defn.of_type, ast_value)
          elsif arg_defn.is_a?(GraphQL::Schema::List)
            # Treat a single value like a list
            arg_value = Array(ast_value)
            arg_value.map do |inner_v|
              arg_to_value(arg_defn.of_type, inner_v)
            end
          elsif arg_defn.is_a?(Class) && arg_defn < GraphQL::Schema::InputObject
            args = arguments(arg_defn, ast_value)
            # TODO still track defaults_used?
            arg_defn.new(ruby_kwargs: args, context: context, defaults_used: nil)
          else
            flat_value = flatten_ast_value(ast_value)
            arg_defn.coerce_input(flat_value, context)
          end
        end

        def flatten_ast_value(v)
          case v
          when GraphQL::Language::Nodes::Enum
            v.name
          when GraphQL::Language::Nodes::InputObject
            h = {}
            v.arguments.each do |arg|
              h[arg.name] = flatten_ast_value(arg.value)
            end
            h
          when Array
            v.map { |v2| flatten_ast_value(v2) }
          when GraphQL::Language::Nodes::VariableIdentifier
            flatten_ast_value(query.variables[v.name])
          else
            v
          end
        end

        def trace_id
          if @parent_trace
            "#{@parent_trace.trace_id}/#{object_id - @parent_trace.object_id}"
          else
            "0"
          end
        end

        def debug(str)
          @debug && (puts "[T#{trace_id}] #{str}")
        end

        # TODO this is kind of a hack.
        # To propagate nulls, we have to know what the field type was
        # at previous parts of the response.
        # This hash matches the response
        def type_at(path)
          t = @types_at_paths
          path.each do |part|
            if part.is_a?(Integer)
              part = 0
            end
            t = t[part] || (raise("Invariant: #{part.inspect} not found in #{t}"))
          end
          t = t[:__type]
          t
        end

        def set_type_at_path(type)
          if type.is_a?(GraphQL::Schema::LateBoundType)
            # TODO need a general way for handling these in the interpreter,
            # since they aren't removed during the cache-building stage.
            type = schema.types[type.name]
          end

          types = @types_at_paths
          @path.each do |part|
            if part.is_a?(Integer)
              part = 0
            end

            types = types[part] ||= {}
          end
          # Use this magic key so that the hash contains:
          # - string keys for nested fields
          # - :__type for the object type of a selection
          types[:__type] ||= type
          nil
        end
      end
    end
  end
end