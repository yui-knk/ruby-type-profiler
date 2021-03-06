module TypeProfiler
  class MethodDef
    include Utils::StructuralEquality

    def do_send(state, flags, recv, mid, args, blk, lenv, genv, scratch, &ctn)
      if ctn
        do_send_core(state, flags, recv, mid, args, blk, lenv, genv, scratch, &ctn)
      else
        do_send_core(state, flags, recv, mid, args, blk, lenv, genv, scratch) do |ret_ty, lenv, genv|
          nlenv, ret_ty, = lenv.deploy_type(ret_ty, 0)
          nlenv = nlenv.push(ret_ty).next
          State.new(nlenv, genv)
        end
      end
    end
  end

  class ISeqMethodDef < MethodDef
    def initialize(iseq, cref, singleton)
      @iseq = iseq
      @cref = cref
      @singleton = singleton
    end

    def do_send_core(state, flags, recv, mid, args, blk, lenv, genv, scratch, &ctn)
      recv = recv.strip_local_info(lenv)
      args = args.map {|arg| arg.strip_local_info(lenv) }
      # XXX: need to translate arguments to parameters
      argc = @iseq.args[:lead_num]
      if argc && argc != args.size
        scratch.error(state, "wrong number of arguments (given #{ args.size }, expected #{ argc })")
        return []
      end

      case
      when blk.eql?(Type::Instance.new(Type::Builtin[:nil]))
      when blk.eql?(Type::Any.new)
      when blk.strip_local_info(lenv).is_a?(Type::ISeqProc) # TODO: TypedProc
      else
        scratch.error(state, "wrong argument type #{ blk.screen_name(genv) } (expected Proc)")
        blk = Type::Any.new
      end

      ctx = Context.new(@iseq, @cref, Signature.new(recv, @singleton, mid, args, blk))
      locals = args + [Type::Instance.new(Type::Builtin[:nil])] * (@iseq.locals.size - args.size)
      locals[@iseq.args[:block_start]] = blk if @iseq.args[:block_start]

      nlenv = LocalEnv.new(ctx, 0, [nil] * locals.size, [], {}, nil)
      id = 0
      locals.each_with_index do |ty, idx|
        nlenv, ty, id = nlenv.deploy_type(ty, id)
        nlenv = nlenv.local_update(idx, 0, ty)
      end

      # XXX: need to jump option argument
      state = State.new(nlenv, genv)

      scratch.add_callsite!(nlenv.ctx, lenv, genv, &ctn)

      return [state]
    end
  end

  class TypedMethodDef < MethodDef
    def initialize(sigs) # sigs: Array<[Signature, (return)Type]>
      @sigs = sigs
    end

    def do_send_core(state, _flags, recv, mid, args, blk, lenv, genv, scratch, &ctn)
      @sigs.each do |sig, ret_ty|
        recv = recv.strip_local_info(lenv)
        args = args.map {|arg| arg.strip_local_info(lenv) }
        dummy_ctx = Context.new(nil, nil, Signature.new(recv, nil, mid, args, blk))
        dummy_lenv = LocalEnv.new(dummy_ctx, -1, [], [], {}, nil)
        # XXX: check blk type
        next if args.size != sig.arg_tys.size
        next unless args.zip(sig.arg_tys).all? {|ty1, ty2| ty1.consistent?(ty2) }
        scratch.add_callsite!(dummy_ctx, lenv, genv, &ctn)
        if sig.blk_ty.is_a?(Type::TypedProc)
          args = sig.blk_ty.arg_tys
          blk_nil = Type::Instance.new(Type::Builtin[:nil]) # XXX: support block to block?
          # XXX: do_invoke_block expects caller's lenv
          return State.do_invoke_block(false, blk, args, blk_nil, dummy_lenv, genv, scratch) do |_ret_ty, _lenv, genv|
            # XXX: check the return type from the block
            # sig.blk_ty.ret_ty.eql?(_ret_ty) ???
            scratch.add_return_type!(dummy_ctx, ret_ty, genv)
            nil
          end
        end
        scratch.add_return_type!(dummy_ctx, ret_ty, genv)
        #states << ctn[ret_ty, lenv, genv]
        return []
      end

      scratch.error(state, "failed to resolve overload: #{ recv.screen_name(genv) }##{ mid }")
      return []
    end
  end

  class CustomMethodDef < MethodDef
    def initialize(impl)
      @impl = impl
    end

    def do_send_core(state, flags, recv, mid, args, blk, lenv, genv, scratch, &ctn)
      # XXX: ctn?
      @impl[state, flags, recv, mid, args, blk, lenv, genv, scratch]
    end
  end


  class ClassDef
    include Utils::StructuralEquality

    def initialize(name, superclass, consts, methods, singleton_methods)
      @superclass = superclass
      @name = name
      @consts = consts
      @methods = methods
      @singleton_methods = singleton_methods
    end

    def get_constant(name)
      @consts[name] || Type::Any.new # XXX: warn?
    end

    def add_constant(name, ty)
      ClassDef.new(@name, @superclass, @consts.merge({ name => ty }), @methods, @singleton_methods)
    end

    def get_method(mid)
      @methods[mid]
    end

    def add_method(mid, mdef)
      ClassDef.new(@name, @superclass, @consts, @methods.merge({ mid => mdef }), @singleton_methods)
    end

    def get_singleton_method(mid)
      @singleton_methods[mid]# || @superclass&.get_singleton_method(mid)
    end

    def add_singleton_method(mid, mdef)
      ClassDef.new(@name, @superclass, @consts, @methods, @singleton_methods.merge({ mid => mdef }))
    end

    attr_reader :name, :superclass
  end
end
