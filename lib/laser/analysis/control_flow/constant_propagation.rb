module Laser
  module SexpAnalysis
    module ControlFlow
      INAPPLICABLE = PlaceholderObject.new('INAPPLICABLE')

      # Sparse Conditional Constant Propagation: Wegman and Zadeck
      # Love those IBMers
      # Using Morgan's implementation though.
      module ConstantPropagation
        attr_reader :constants

        # Only public method: mutably turns the CFG into a constant-propagated
        # one. Each binding will have a value assigned to it afterward: either
        # the constant, as a Ruby object (or a proxy to one), UNDEFINED, or VARYING.
        def perform_constant_propagation(opts={})
          opts = {:fixed_methods => {}}.merge(opts)
          
          initialize_constant_propagation(opts)
          visited = Set.new
          worklist = Set.new
          blocklist = Set[self.enter]
          while worklist.any? || blocklist.any?
            while worklist.any?
              constant_propagation_for_instruction(
                  worklist.pop, blocklist, worklist)
            end
            while blocklist.any?
              constant_propagation_for_block(
                  blocklist.pop, visited, blocklist, worklist)
            end
          end
          teardown_constant_propagation
          @constants = find_remaining_constants
        end

      private

        def find_remaining_constants
          result = {}
          all_variables.select do |variable|
            variable.value != VARYING && variable.value != UNDEFINED
          end.each do |constant|
            result[constant] = constant.value
          end
          result
        end

        # Initializes the variables, formals, and edges for constant propagation.
        # Morgan, p. 201
        def initialize_constant_propagation(opts)
          @constants.clear
          # value cells for :call nodes that discard their argument.
          @cp_private_cells = Hash.new do |h, k|
            h[k] = Bindings::TemporaryBinding.new(k.hash.to_s, UNDEFINED)
            h[k].inferred_type = nil
            h[k]
          end
          all_variables.each do |temp|
            temp.bind! UNDEFINED
            temp.inferred_type = nil
          end
          vertices.each do |block|
            block.successors.each do |succ|
              block.remove_flag(succ, ControlFlowGraph::EDGE_EXECUTABLE)
            end
          end
          @_cp_fixed_methods = opts[:fixed_methods]
        end

        def teardown_constant_propagation
          @cp_private_cells.clear
        end

        def cp_cell_for(instruction)
          @cp_private_cells[instruction]
        end

        # Simulates a block. As we know, phi nodes execute simultaneously
        # and immediately upon block entry, so first we check phi nodes to
        # see if they form a constant. This happens unconditionally, as
        # phi nodes must be checked repeatedly.
        #
        # Then, if the block hasn't been visited before, simulate the normal
        # instructions, and mark it so it is not visited again.
        #
        # Morgan, p.200
        def constant_propagation_for_block(block, visited, blocklist, worklist)
          block.phi_nodes.each do |phi_node|
            constant_propagation_for_instruction(
                phi_node, blocklist, worklist)
          end
          if visited.add?(block)
            block.natural_instructions.each do |instruction|
              constant_propagation_for_instruction(
                  instruction, blocklist, worklist)
            end
            if block.fall_through_block?
              block.successors.each do |succ|
                constant_propagation_consider_edge block, succ, blocklist
              end
            end
          end
        end
        private :constant_propagation_for_block

        def constant_propagation_for_instruction(instruction, blocklist, worklist)
          return if instruction.type != :phi && instruction.block.executed_predecessors.empty?
          Laser.debug_p(instruction)
          block = instruction.block
          case instruction.type
          when :branch
            constant_propagation_for_branch(instruction, blocklist)
          when :jump, :raise, :return
            succ = block.real_successors.first
            constant_propagation_consider_edge block, succ, blocklist
          when :resume
            block.successors.each do |succ|
              constant_propagation_consider_edge block, succ, blocklist
            end
          when :call
            changed, raised = constant_propagation_for_call instruction
            if changed
              if instruction[1] && instruction[1].value != UNDEFINED
                add_target_uses_to_worklist instruction, worklist
              end
            end
            if raised != instruction.raise_type && instruction == block.last
              instruction.raise_type = raised
              successors = case raised
                           when :unknown then []
                           when Frequency::MAYBE then block.successors
                           when Frequency::NEVER then block.normal_successors
                           when Frequency::ALWAYS then block.abnormal_successors
                           end
              successors.each do |succ|
                constant_propagation_consider_edge block, succ, blocklist
              end
            end
          when :call_vararg
            if constant_propagation_evaluate(instruction)
              add_target_uses_to_worklist instruction, worklist
            end
            block.successors.each do |succ|
              constant_propagation_consider_edge block, succ, blocklist
            end
          else
            if constant_propagation_evaluate(instruction)
              add_target_uses_to_worklist instruction, worklist
            end
          end
        end

        def add_target_uses_to_worklist(instruction, worklist)
          instruction.explicit_targets.each do |target|
            target.uses.each do |use|
              worklist.add? use
            end
          end
        end
        
        # Examines the branch for newly executable edges, and adds them to
        # the blocklist.
        def constant_propagation_for_branch(instruction, blocklist)
          block = instruction.block
          executable_successors = constant_propagation_branch_successors(instruction)
          executable_successors.each do |succ|
            constant_propagation_consider_edge block, succ, blocklist
          end
        end
        
        def constant_propagation_branch_successors(instruction)
          condition = instruction[1]
          case condition.value
          when VARYING
            if Types.overlap?(condition.expr_type, Types::FALSY)
              instruction.block.real_successors
            else
              [instruction.true_successor]
            end
          when UNDEFINED then []
          when nil, false then [instruction.false_successor]
          else [instruction.true_successor]
          end
        end

        def constant_propagation_consider_edge(block, succ, blocklist)
          if !is_executable?(block, succ) && !is_fake?(block, succ)
            add_flag(block, succ, ControlFlowGraph::EDGE_EXECUTABLE)
            blocklist << succ
          end
        end

        def constant_propagation_for_call(instruction)
          target = instruction[1] || cp_cell_for(instruction)
          original = target.value
          old_type = target.inferred_type
          receiver, method_name, *args = instruction[2..-1]

          opts = Hash === args.last ? args.pop : {}
          components = [receiver, *args]
          special_result, special_type, special_raised = apply_special_case(receiver, method_name, *args)
          if special_result != INAPPLICABLE
            new_value = special_result
            new_type = special_type
            raised = special_raised
          elsif components.any? { |arg| arg.value == UNDEFINED }
            # cannot evaluate unless all args and receiver are defined
            return [false, :unknown]
          else
            # check purity
            methods = instruction.possible_methods
            # Require precise resolution
            method = methods.size == 1 ? methods.first : nil
            if methods.empty?
              new_value = UNDEFINED
              new_type = Types::TOP
              raised = Frequency::ALWAYS
            elsif method && (@_cp_fixed_methods.has_key?(method))
              result = @_cp_fixed_methods[method]
              new_value = result
              new_type = Utilities.type_for(result)
              raised = Frequency::NEVER
            elsif components.any? { |arg| arg.value == VARYING }
              new_value = VARYING
              if components.all? { |arg| arg.value != UNDEFINED }
                new_type, raised = infer_type_and_raising(instruction, methods, receiver, method_name, args)
              else
                new_type = Types::TOP
                raised = Frequency::MAYBE
              end
            # All components constant, and never evaluated before.
            elsif original == UNDEFINED && (!opts || !opts[:block])
              if method && (method.pure || allow_impure_method?(method))
                real_receiver = receiver.value
                begin
                  if method.builtin
                    result = real_receiver.send(method_name, *args.map(&:value))
                  else
                    result = method.simulate_with_args(real_receiver, args.map(&:value), nil, {mutation: true})
                  end
                  new_value = result
                  new_type = Utilities.type_for(result)
                  raised = Frequency::NEVER
                rescue BasicObject => err
                  # any exception caught - this is an extremely unsafe rescue handler - means my
                  # simulation *MUST NOT* raise or I will conflate user-level raises
                  # with my own
                  new_value = UNDEFINED
                  new_type = Types::TOP
                  raised = Frequency::ALWAYS
                end
              else
                new_value = VARYING
                new_type, raised = infer_type_and_raising(instruction, methods, receiver, method_name, args)
              end
            else
              # all components constant, nothing changed, shouldn't happen, but okay
              new_value = original
              new_type = old_type
              raised = instruction.raise_type
            end
            # At this point, we should prune raise edges!
          end
          if original != new_value
            target.bind! new_value
            changed = true
          end
          if old_type != new_type
            target.inferred_type = new_type
            changed = true
          end
          [changed, raised]
        end

        def infer_type_and_raising(instruction, methods, receiver, method_name, args)
          begin
            type = return_types_for_normal_call(receiver, method_name, args)
          rescue TypeError => err
            type = Types::TOP
            raised = Frequency::ALWAYS
            instruction.node.add_error(NoMatchingTypeSignature.new(
                "No method named #{method_name} with matching types was found", instruction.node))
          else
            raised = raiseability_for_instruction(instruction, methods)
          end
          [type, raised]
        end

        def raiseability_for_instruction(instruction, methods)
          fails_privacy = Frequency::NEVER
          if methods.size > 0 && !instruction.ignore_privacy
            public_methods = instruction.possible_public_methods
            if public_methods.size.zero?
              fails_privacy = Frequency::ALWAYS
            elsif public_methods.size != methods.size
              fails_privacy = Frequency::MAYBE
            else
              fails_privacy = Frequency::NEVER
            end
          end
          raised = methods.empty? ? Frequency::ALWAYS : methods.map(&:raise_type).max
          [fails_privacy, raised].max
        end

        def return_types_for_normal_call(receiver, method, args)
          method_name = method
          possible_dispatches = receiver.expr_type.member_types.map do |type|
            [type, type.matching_methods(method)]
          end
          result = Set.new
          if args.empty?
            cartesian = [ [] ]
          else
            cartesian_parts = args.map(&:expr_type).map(&:member_types).map(&:to_a)
            cartesian = cartesian_parts[0].product(*cartesian_parts[1..-1])
          end
          possible_dispatches.each do |self_type, methods|
            result |= methods.map do |method|
              cartesian.map do |type_list|
                begin
                  method.return_type_for_types(self_type, type_list, Types::NILCLASS)
                rescue TypeError => err
                  Laser.debug_puts("Invalid argument types found.")
                  nil
                end
              end.compact
            end.flatten
          end
          if result.empty?
            raise TypeError.new("No methods named #{method_name} with matching types were found.")
          end
          Types::UnionType.new(result)
        end

        # Evaluates the instruction, and if the constant value is lowered,
        # then return true. Otherwise, return false.
        def constant_propagation_evaluate(instruction)
          target = instruction[1] || cp_cell_for(instruction)
          original = target.value
          old_type = target.inferred_type
          changed = false
          case instruction.type
          when :assign
            rhs = instruction[2]
            if Bindings::Base === rhs
              # temporary <- temporary
              new_value = rhs.value
              new_type = rhs.inferred_type
            else
              # temporary <- constant
              new_value = rhs
              new_type = Utilities.type_for(rhs)
            end
          when :phi
            components = instruction[2..-1]
            if components.any? { |var| var.value == VARYING }
              new_value = VARYING
              new_type  = Types::TOP
            else
              possible_values = components.map(&:value).uniq - [UNDEFINED]
              if possible_values == []
                new_value = UNDEFINED
                new_type  = nil
              elsif possible_values.size == 1
                new_value = possible_values.first
                new_type  = Utilities.type_for(new_value)
              else
                new_value = VARYING
                new_type  = Types::UnionType.new(components.map(&:inferred_type).compact.uniq)
              end
            end
          when :call_vararg, :super, :super_vararg
            new_value = VARYING
            new_type = Types::TOP
          when :return, :raise
            return false  # not applicable
          end
          if original != new_value
            target.bind! new_value
            changed = true
          end
          if old_type != new_type
            target.inferred_type = new_type
            changed = true
          end
          changed
        end
        
        def is_numeric?(temp)
          temp.value != UNDEFINED && Types.subtype?(temp.inferred_type, 
                                              Types::ClassType.new('Numeric', :covariant))
        end
        
        def uses_method?(temp, method)
          temp.value != UNDEFINED && temp.expr_type.matching_methods(method.name) == [method]
        end
        
        # TODO(adgar): Add typechecking. Forealz.
        def apply_special_case(receiver, method_name, *args)
          if method_name == :*
            # 0 * n == 0
            # n * 0 == 0
            if (receiver.value == 0 && is_numeric?(args.first)) ||
               (args.first.value == 0 && is_numeric?(receiver))
              return [0, Types::FIXNUM, Frequency::NEVER]
            elsif (args.first.value == 0 &&
                   uses_method?(receiver, ClassRegistry['String'].instance_method('*')))
              return ['', Types::STRING, Frequency::NEVER]
            elsif (args.first.value == 0 &&
                   uses_method?(receiver, ClassRegistry['Array'].instance_method('*')))
              return [[], Types::ARRAY, Frequency::NEVER]
            end
          elsif method_name == :**
            # n ** 0 == 1
            if args.first.value == 0 && is_numeric?(receiver)
              return [1, Types::FIXNUM, Frequency::NEVER]
            # 1 ** n == 1
            elsif receiver.value == 1 && is_numeric?(args.first)
              return [1, Types::FIXNUM, Frequency::NEVER]
            end
          elsif method_name == :===
            if LaserModule === receiver.value && args.first != UNDEFINED
              instance_type = args.first.expr_type
              module_type = Types::ClassType.new(receiver.value.path, :covariant)
              result = Types.subtype?(instance_type, module_type)
              if result
                return [true, Types::TRUECLASS, Frequency::NEVER]
              elsif !(Types.overlap?(instance_type, module_type))
                return [false, Types::FALSECLASS, Frequency::NEVER]
              end
            end
          elsif receiver == ClassRegistry['Laser#Magic'].binding
            magic_result, magic_type, magic_raises = cp_magic(method_name, *args)
            if magic_result != INAPPLICABLE
              return [magic_result, magic_type, magic_raises]
            end
          end
          [INAPPLICABLE, Frequency::MAYBE]
        end
        
        def allow_impure_method?(method)
          method == ClassRegistry['Module'].instance_method('const_get')
        end
        
        def cp_magic(method_name, *args)
          case method_name
          when :current_self
            return [VARYING, real_self_type, Frequency::NEVER]
          when :current_argument
            return [VARYING, real_formal_type(args[0].value), Frequency::NEVER]
          when :current_argument_range
            return [VARYING, Types::ARRAY, Frequency::NEVER]
          when :current_arity
            return [VARYING, Types::FIXNUM, Frequency::NEVER]
          when :get_global
            global = Scope::GlobalScope.lookup(args[0].value)
            return [VARYING, global.expr_type, Frequency::NEVER]
          when :set_global
            if args[1] != UNDEFINED
              global = Scope::GlobalScope.lookup(args[0].value)
              unless Types.subtype?(args[1].expr_type, global.expr_type)
                global.inferred_type = Types::UnionType.new([args[1].expr_type, global.expr_type])
              end
              return [VARYING, global.expr_type, Frequency::NEVER]
            end
          end
          [INAPPLICABLE, nil, Frequency::MAYBE]
        end
      end  # ConstantPropagation
    end  # ControlFlow
  end  # SexpAnalysis
end  #
